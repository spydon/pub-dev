// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show json;
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:googleapis/iamcredentials/v1.dart' as iam_credentials;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'package:retry/retry.dart';

import '../shared/email.dart';
import '../shared/exceptions.dart';

final _logger = Logger('pub.email');
final _simpleUrlRegExp = RegExp(r'https?://(.+)');

/// Sets the active [EmailSender].
void registerEmailSender(EmailSender value) =>
    ss.register(#_email_sender, value);

/// The active [EmailSender].
EmailSender get emailSender => ss.lookup(#_email_sender) as EmailSender;

abstract class EmailSender {
  /// Indicates if a previous send failed with a service-related transient issue,
  /// and we should wait a bit until the next try.
  bool get shouldBackoff;

  Future<void> sendMessage(EmailMessage message);
}

EmailSender createGmailRelaySender(
  String serviceAccountEmail,
  http.Client authClient,
) =>
    _GmailSmtpRelay(
      serviceAccountEmail,
      authClient,
    );

class _LoggingEmailSender implements EmailSender {
  @override
  bool get shouldBackoff => false;

  @override
  Future<void> sendMessage(EmailMessage message) async {
    final debugHeader = '(${message.subject}) '
        'from ${message.from} '
        'to ${message.recipients.join(', ')}';

    final urls = _simpleUrlRegExp
        .allMatches(message.bodyText)
        .map((e) => e.group(0))
        .toList();
    _logger.info('Not sending email (SMTP not configured): '
        '$debugHeader${urls.map((e) => '\n$e').join('')}');
  }
}

final loggingEmailSender = _LoggingEmailSender();

Message _toMessage(EmailMessage input) {
  input.verifyLocalMessageId();
  return Message()
    ..headers = {'Message-ID': '<${input.localMessageId}@pub.dev>'}
    ..from = _toAddress(input.from)
    ..recipients = input.recipients.map(_toAddress).toList()
    ..subject = input.subject
    ..text = input.bodyText;
}

Address? _toAddress(EmailAddress? input) =>
    input == null ? null : Address(input.email, input.name);

/// Send emails through the gmail SMTP relay.
///
/// This sends emails through the [gmail SMTP relay][1].
/// Using the [SASL XOAUTH2][2] for authentication.
///
/// Hence, this assumes that the [gmail SMTP relay][1] has been abled by the
/// _GSuite administrator_, and that it's been configured to:
///
///  * Be authenticated by any GSuite user,
///  * Allow outgoing email from any registered GSuite user, and,
///  * Require TLS.
///
/// However, as the server is running with a _service account_, we do not
/// readily have an `access_token` with the scope `https://mail.google.com/`
/// for some GSuite user account.
///
/// To over come this, we require a [_serviceAccountEmail] which:
///
///  * The service account running this server is allowed to create tokens for.
///  * Is configured for [domain-wide delegation][3] with the
///    `https://mail.google.com/` scope on the given GSuite.
///
/// This class then creates a JWT impersonating the sender and
/// signed by [_serviceAccountEmail] (using [signJwt API][4]). It then exchanges
/// this JWT for an `access_token` using [OAuth 2 for service accounts][4].
///
/// [1]: https://support.google.com/a/answer/176600?hl=en
/// [2]: https://developers.google.com/gmail/imap/xoauth2-protocol#the_sasl_xoauth2_mechanism
/// [3]: https://developers.google.com/identity/protocols/oauth2/service-account
/// [4]: https://cloud.google.com/iam/docs/reference/credentials/rest/v1/projects.serviceAccounts/signJwt
class _GmailSmtpRelay implements EmailSender {
  static final _googleOauth2TokenUrl =
      Uri.parse('https://oauth2.googleapis.com/token');
  static const _scopes = ['https://mail.google.com/'];

  final String _serviceAccountEmail;
  final http.Client _authClient;

  final _connectionsBySender = <String, Future<_GmailConnection>>{};
  final _forceReconnectSenders = <String>{};

  DateTime _accessTokenRefreshed = DateTime(0);
  DateTime _backoffUntil = DateTime(0);
  Future<String>? _accessToken;

  _GmailSmtpRelay(
    this._serviceAccountEmail,
    this._authClient,
  );

  @override
  bool get shouldBackoff => clock.now().isBefore(_backoffUntil);

  @override
  Future<void> sendMessage(EmailMessage message) async {
    final debugHeader = '(${message.subject}) '
        'from ${message.from} '
        'to ${message.recipients.join(', ')}';
    _logger.info('Sending email: $debugHeader...');
    final sender = message.from.email;
    try {
      await retry(
        () async {
          final c = await _getConnection(sender);
          try {
            await c.connection.send(_toMessage(message));
          } finally {
            c.trackSentEmail(message.recipients.length);
          }
        },
        retryIf: (e) =>
            e is TimeoutException ||
            e is IOException ||
            e is SmtpClientCommunicationException ||
            e is SmtpNoGreetingException,
        delayFactor: Duration(seconds: 2),
        maxAttempts: 2,
        onRetry: (_) {
          _forceReconnectSenders.add(sender);
        },
      );
    } on SmtpMessageValidationException catch (e, st) {
      _logger.info('Sending email failed: $debugHeader.', e, st);
      throw EmailSenderException.invalid();
    } on SmtpClientAuthenticationException catch (e, st) {
      _logger.shout('Sending email failed due to invalid auth: $e', e, st);
      _backoffUntil = clock.now().add(Duration(minutes: 2));
      _forceReconnectSenders.add(sender);
      _accessToken = null;
      throw EmailSenderException.failed();
    } on MailerException catch (e, st) {
      _logger.warning('Sending email failed: $debugHeader.', e, st);
      throw EmailSenderException.failed();
    }
  }

  Future<_GmailConnection> _getConnection(String sender) async {
    final connectionFuture = _connectionsBySender[sender];
    final old = connectionFuture == null ? null : await connectionFuture;
    final forceReconnect = _forceReconnectSenders.remove(sender);
    if (!forceReconnect && old != null && !old.isExpired) {
      return old;
    }
    final newConnectionFuture = Future.microtask(() async {
      if (old != null) {
        try {
          await old.connection.close();
        } catch (e, st) {
          _logger.warning('Unable to close SMTP connection.', e, st);
        }
      }
      return _GmailConnection(
        PersistentConnection(
          await _getSmtpServer(sender),
          timeout: Duration(seconds: 15),
        ),
      );
    });
    _connectionsBySender[sender] = newConnectionFuture;
    return newConnectionFuture;
  }

  Future<SmtpServer> _getSmtpServer(String sender) async {
    final maxAge = clock.now().subtract(Duration(minutes: 20));
    if (_accessToken == null || _accessTokenRefreshed.isBefore(maxAge)) {
      _accessToken = _createAccessToken(sender);
      _accessTokenRefreshed = clock.now();
    }

    // For documentation see:
    // https://support.google.com/a/answer/176600?hl=en
    return gmailRelaySaslXoauth2(sender, await _accessToken!);
  }

  /// Create an access_token for [sender] using the
  /// [_serviceAccountEmail] configured for _domain-wide delegation_ following:
  /// https://developers.google.com/identity/protocols/oauth2/service-account
  Future<String> _createAccessToken(String sender) async {
    final iam = iam_credentials.IAMCredentialsApi(_authClient);
    final iat = clock.now().toUtc().millisecondsSinceEpoch ~/ 1000 - 20;
    iam_credentials.SignJwtResponse jwtResponse;
    try {
      jwtResponse = await retry(() => iam.projects.serviceAccounts.signJwt(
            iam_credentials.SignJwtRequest()
              ..payload = json.encode({
                'iss': _serviceAccountEmail,
                'scope': _scopes.join(' '),
                'aud': _googleOauth2TokenUrl.toString(),
                'exp': iat + 3600,
                'iat': iat,
                'sub': sender,
              }),
            'projects/-/serviceAccounts/$_serviceAccountEmail',
          ));
    } on Exception catch (e, st) {
      _logger.severe(
        'Signing JWT for sending email failed, '
        'iam.projects.serviceAccounts.signJwt() threw',
        e,
        st,
      );
      throw SmtpClientAuthenticationException(
        'Failed to obtain signed JWT from iam.projects.serviceAccounts.signJwt',
      );
    }

    final client = http.Client();
    try {
      // Send a POST request with:
      // Content-Type: application/x-www-form-urlencoded; charset=utf-8
      return await retry(() async {
        final r = await client.post(_googleOauth2TokenUrl, body: {
          'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          'assertion': jwtResponse.signedJwt,
        });
        if (r.statusCode != 200) {
          throw SmtpClientAuthenticationException(
            'statusCode=${r.statusCode} from $_googleOauth2TokenUrl '
            'while trying exchange JWT for access_token',
          );
        }
        return json.decode(r.body)['access_token'] as String;
      });
    } finally {
      client.close();
    }
  }
}

class _GmailConnection {
  final DateTime created;
  final PersistentConnection connection;
  DateTime _lastUsed;
  var _sentCount = 0;

  _GmailConnection(this.connection)
      : created = clock.now(),
        _lastUsed = clock.now();

  void trackSentEmail(int count) {
    _sentCount += count;
    _lastUsed = clock.now();
  }

  bool get isExpired {
    // There is a 100-recipient limit per SMTP transaction for smtp-relay.gmail.com.
    // Exceeding this limit results in an error message. To send messages to
    // additional recipients, start another transaction (new SMTP connection or RSET command).
    if (_sentCount > 90) {
      return true;
    }
    final age = clock.now().difference(created);
    if (age > Duration(minutes: 5)) {
      return true;
    }
    final idle = clock.now().difference(_lastUsed);
    if (idle > Duration(seconds: 25)) {
      return true;
    }
    return false;
  }
}
