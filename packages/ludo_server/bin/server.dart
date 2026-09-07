// The running server. No TLS here -- a reverse proxy terminates it, and that
// is a deploy order's business, not this one's.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';

const int _defaultPort = 8080;

/// The entry point. Everything the process does lives in [_run], and this
/// wrapper's job is to make sure that an asynchronous error escaping from
/// anywhere inside it *after the server is already listening* -- the
/// turn-expiry sweep is the one that is known to have escaped before, but a
/// `runZonedGuarded` at this one seam catches every other future room's
/// worth of them too -- prints loudly and lets the process carry on holding
/// every other room in memory rather than dying with all of them. Loud
/// means the error and the full stack, never a bare message, because a
/// backstop that hides what it caught is worse than no backstop.
///
/// A failure during startup -- anything up to and including the socket
/// being bound and listening -- is a different failure and is deliberately
/// not left to this backstop: it is caught inside [_run] itself and exits
/// the process non-zero, same as before this backstop existed. See the
/// comment at that `try` for why.
void main() {
  runZonedGuarded(() {
    unawaited(_run());
  }, (Object error, StackTrace stack) {
    stderr.writeln('unhandled $error\n$stack');
  });
}

Future<void> _run() async {
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

  // Startup is everything up to and including the socket being bound and
  // listening. `server.start` is also where the housekeeping and
  // turn-expiry `Timer.periodic`s are created, and a `Timer` runs its
  // callback in whatever zone was current when it was created -- so this
  // call has to stay inside the `runZonedGuarded` zone `main` opened, or
  // an error escaping one of those timers later would run in the root
  // zone instead of ours and this backstop would never see it.
  //
  // A failure here (address already in use, permission denied, and so on)
  // is caught right here rather than left to reach the zone's error
  // handler above: `_run` is started with `unawaited`, so an uncaught
  // error from it is exactly what that handler is for, and letting a bind
  // failure fall into it would print the error and then let the process
  // carry on with no socket open, which is the defect this guards
  // against. `exit(255)` is used instead of setting `exitCode` and
  // returning, because nothing else is keeping the isolate's event loop
  // alive yet at this point (the shutdown completer and the SIGTERM
  // listener are both set up further down) and an explicit exit says so
  // rather than relying on a drain that may or may not happen to occur.
  // The container restart policy and the deploy check read this exit
  // code, so it has to stay non-zero: a server that could not bind must
  // not report a clean exit.
  try {
    await server.start(address: InternetAddress.anyIPv4, port: port);
  } catch (error, stack) {
    stderr.writeln('Unhandled exception:\n$error\n$stack');
    exit(255);
  }
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
