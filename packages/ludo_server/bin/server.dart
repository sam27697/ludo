// The running server. No TLS here -- a reverse proxy terminates it, and that
// is a deploy order's business, not this one's.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';

const int _defaultPort = 8080;

Future<void> main() async {
  final int port =
      int.tryParse(Platform.environment['PORT'] ?? '') ?? _defaultPort;

  // Empty by default, per docs/PROTOCOL.md section 7: with nothing
  // configured, every connection's IP is the immediate TCP peer address and
  // an X-Forwarded-For header from an untrusted client is never trusted.
  final Set<String> trustedProxies =
      (Platform.environment['TRUSTED_PROXIES'] ?? '')
          .split(',')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toSet();

  // Reported by GET /health. Set by the deploy process; falls back to 'dev'
  // when unset or empty so a local run still answers with something.
  final String rawVersion = Platform.environment['LUDO_VERSION'] ?? '';
  final String version = rawVersion.isEmpty ? 'dev' : rawVersion;

  // The contact address rendered into the /privacy page's contact section.
  // Unset or empty omits that section entirely rather than shipping an
  // invented or a placeholder address; see docs on buildPrivacyPageHtml.
  final String rawPrivacyContactEmail =
      Platform.environment['PRIVACY_CONTACT_EMAIL'] ?? '';
  final String? privacyContactEmail =
      rawPrivacyContactEmail.isEmpty ? null : rawPrivacyContactEmail;

  final RoomRegistry registry = RoomRegistry(
    clock: const SystemClock(),
    secure: Random.secure(),
  );
  final RateLimiter rateLimiter = RateLimiter(clock: const SystemClock());
  final WireServer server = WireServer(
    registry: registry,
    rateLimiter: rateLimiter,
    clock: const SystemClock(),
    trustedProxies: trustedProxies,
    version: version,
    privacyContactEmail: privacyContactEmail,
  );

  await server.start(address: InternetAddress.anyIPv4, port: port);
  // ignore: avoid_print
  print('ludo_server listening on port ${server.port}');

  final Completer<void> shutdown = Completer<void>();
  StreamSubscription<ProcessSignal>? sigtermSub;
  sigtermSub = ProcessSignal.sigterm.watch().listen((ProcessSignal _) async {
    await sigtermSub?.cancel();
    await server.close();
    if (!shutdown.isCompleted) {
      shutdown.complete();
    }
  });

  await shutdown.future;
}
