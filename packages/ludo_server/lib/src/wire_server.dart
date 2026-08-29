// The socket layer proper: the `shelf` pipeline, the WebSocket upgrade, the
// `RoomHub` implementation `connection.dart` declares and depends on, client
// IP extraction (including the trusted-proxy rule for a forwarded header),
// and the once-a-minute housekeeping timer that drives both
// `RoomRegistry.reap()` and `RateLimiter.prune()`. Nothing here touches room
// state directly; it only wires sockets to `Connection` and `Connection` to
// the registry, exactly the split `connection.dart`'s own header comment
// describes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock.dart';
import 'connection.dart';
import 'link_pages.dart';
import 'privacy_page.dart';
import 'rate_limit.dart';
import 'registry.dart';
import 'room_code.dart';

/// How often the housekeeping timer fires: `RoomRegistry.reap()` and
/// `RateLimiter.prune()` both run on this cadence. `docs/PROTOCOL.md` does
/// not pin an exact number; the work order asks for "around once a minute"
/// and this is that.
const Duration housekeepingInterval = Duration(minutes: 1);

/// The header a reverse proxy is expected to set with the real client
/// address. Only trusted when the immediate peer address is in the
/// configured proxy list.
const String forwardedForHeader = 'x-forwarded-for';

/// The exact, case-sensitive path of the operational health endpoint. Not a
/// game protocol message: it is answered before the WebSocket upgrade is
/// ever attempted, and it is the only path this server treats specially.
const String _healthPath = '/health';

/// The exact, case-sensitive path of the privacy policy page. Matched
/// alongside its trailing-slash form by the same pre-upgrade check
/// [_healthPath] uses; see order 049.
const String _privacyPath = '/privacy';

/// The trailing-slash form of [_privacyPath]. A separate constant rather
/// than a computed one so both paths read as literal strings at every call
/// site.
const String _privacyPathWithSlash = '/privacy/';

/// The exact, case-sensitive path of the Digital Asset Links document.
/// Matched, like [_healthPath] and [_privacyPath], before the WebSocket
/// upgrade is ever attempted. See order 076 and `docs/RELEASE.md:139-159`:
/// the fingerprint this document carries has to be the Play App Signing
/// key's, never the upload key's.
const String _assetLinksPath = '/.well-known/assetlinks.json';

/// Matches `/r/<anything with no further slash>`, the shared-room landing
/// page. The captured group is handed to [buildRoomLandingPageHtml] only
/// after being upper-cased and checked with `isWellFormedRoomCode`; this
/// pattern alone says nothing about whether the code is well-formed.
final RegExp _roomLinkPathPattern = RegExp(r'^/r/([^/]+)$');

/// Builds the `assetlinks.json` body for [rawFingerprint], or returns null
/// when [rawFingerprint] is null, empty, or does not match
/// [appSigningFingerprintShape]. A shape mismatch is treated exactly like an
/// absent value -- served as a 404, never as the malformed value itself --
/// because a misconfigured fingerprint fails Android's verification exactly
/// as silently as an absent one does, and there is no way to tell from the
/// string alone whether it is the app signing key or, wrongly, the upload
/// key; see `docs/RELEASE.md:139-159`. The value itself is never logged.
String? _buildAssetLinksJsonOrNull(String? rawFingerprint) {
  if (rawFingerprint == null || rawFingerprint.isEmpty) {
    return null;
  }
  if (!isValidAppSigningFingerprintShape(rawFingerprint)) {
    return null;
  }
  return buildAssetLinksJson(rawFingerprint);
}

/// Owns the listening socket and everything that turns an accepted
/// connection into a [Connection]. Built once per running server; `start`
/// opens the port, `close` shuts it down along with the housekeeping timer.
class WireServer {
  WireServer({
    required this.registry,
    required this.rateLimiter,
    required this.clock,
    Random? random,
    Set<String> trustedProxies = const <String>{},
    this.version = 'dev',
    String? privacyContactEmail,
    String? appSigningSha256,
  })  : _random = random ?? Random.secure(),
        _trustedProxies = trustedProxies,
        _hub = _ConnectionHub(),
        _privacyHtml = buildPrivacyPageHtml(contactEmail: privacyContactEmail),
        _assetLinksJson = _buildAssetLinksJsonOrNull(
          // `bin/server.dart` is the entry point that reads every other
          // piece of environment-driven configuration (PORT,
          // TRUSTED_PROXIES, LUDO_VERSION, PRIVACY_CONTACT_EMAIL) and passes
          // each down as an explicit constructor argument here -- but that
          // file is out of scope for order 076, so this one value falls
          // back to reading LUDO_APP_SIGNING_SHA256 from the process
          // environment directly when no caller supplies it explicitly.
          // Every existing call site (bin/server.dart unmodified, and every
          // test harness that does not pass this argument) keeps working
          // exactly as it does today, with the fallback taking effect only
          // in the running process's own environment, read once here and
          // never again.
          appSigningSha256 ?? Platform.environment['LUDO_APP_SIGNING_SHA256'],
        );

  final RoomRegistry registry;
  final RateLimiter rateLimiter;
  final Clock clock;
  final Random _random;

  /// The build identifier reported by `GET /health`. Not otherwise used;
  /// this server does not act differently for one version than another.
  final String version;

  /// Addresses (as `InternetAddress.address` strings) allowed to set
  /// [forwardedForHeader] and be believed. Empty by default: with no
  /// configured proxy, every connection's IP is the immediate TCP peer
  /// address and any `X-Forwarded-For` header an untrusted client sends is
  /// ignored outright, never inspected at all.
  final Set<String> _trustedProxies;

  /// The complete `/privacy` document, built once from the constructor's
  /// `privacyContactEmail` argument at construction time so serving it never
  /// touches the filesystem or re-renders anything at request time.
  final String _privacyHtml;

  /// The complete `assetlinks.json` body, built once at construction time,
  /// or null when no shape-valid fingerprint was available. Null means
  /// `GET /.well-known/assetlinks.json` answers 404 with an empty body --
  /// never `[]`, which would be the different and much stronger claim that
  /// no application is associated with this domain at all.
  final String? _assetLinksJson;

  final _ConnectionHub _hub;

  HttpServer? _httpServer;
  Timer? _housekeeping;

  /// The instant [start] completed, per the injected [clock]. Null before
  /// [start] has returned, in which case reported uptime is zero.
  DateTime? _startedAt;

  /// Starts listening. [address] is anything `HttpServer.bind` accepts
  /// (`InternetAddress` or a host string); [port] `0` binds an ephemeral
  /// port, readable back afterwards from [port].
  Future<void> start({required Object address, required int port}) async {
    final shelf.Handler handler = (shelf.Request request) {
      final String path = request.requestedUri.path;
      if (path == _healthPath) {
        return _handleHealth(request);
      }
      if (path == _privacyPath || path == _privacyPathWithSlash) {
        return _handlePrivacy(request);
      }
      if (path == _assetLinksPath) {
        return _handleAssetLinks(request);
      }
      final RegExpMatch? roomLinkMatch = _roomLinkPathPattern.firstMatch(path);
      if (roomLinkMatch != null) {
        return _handleRoomLink(request, roomLinkMatch.group(1)!);
      }
      final String ip = _clientIp(request);
      final shelf.Handler upgrade = webSocketHandler((
        WebSocketChannel channel,
        String? protocol,
      ) {
        _accept(channel, ip);
      });
      return upgrade(request);
    };

    _httpServer = await shelf_io.serve(handler, address, port);
    _housekeeping = Timer.periodic(housekeepingInterval, (_) {
      _runHousekeeping();
    });
    _startedAt = clock.now;
  }

  /// The bound port. Only meaningful after [start] has completed.
  int get port => _httpServer!.port;

  /// Stops accepting new connections and cancels the housekeeping timer.
  /// `force: true` because a server answering SIGTERM is expected to go
  /// away promptly rather than wait out whatever sockets are still open.
  Future<void> close() async {
    _housekeeping?.cancel();
    _housekeeping = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  void _runHousekeeping() {
    final int reaped = registry.reap();
    if (reaped > 0) {
      // ignore: avoid_print
      print('housekeeping reaped=$reaped');
    }
    rateLimiter.prune();
  }

  void _accept(WebSocketChannel channel, String ip) {
    final Connection conn = Connection(
      channel: channel,
      ip: ip,
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
      hub: _hub,
      random: _random,
    );
    unawaited(_pump(channel, conn));
  }

  /// Reads frames off [channel] one at a time, awaiting each before the
  /// next is handled, so two frames from the same socket are never
  /// processed concurrently against the same connection's mutable seat
  /// identity. Any stream error is treated the same as an ordinary close.
  Future<void> _pump(WebSocketChannel channel, Connection conn) async {
    try {
      await for (final Object? frame in channel.stream) {
        if (frame == null) {
          continue;
        }
        await conn.handleFrame(frame);
      }
    } catch (_) {
      // A transport-level failure ends the connection exactly like a clean
      // close does; the seat survives regardless, per docs/PROTOCOL.md
      // section 8.
    } finally {
      conn.handleDisconnect();
    }
  }

  /// `GET /health` never reaches the WebSocket upgrade path: the path check
  /// in [start]'s handler runs first, always, regardless of what upgrade
  /// headers the request carries. The body is aggregate counts only -- never
  /// a room code, a seat token, a client IP, or a configuration value --
  /// because this hostname is public.
  shelf.Response _handleHealth(shelf.Request request) {
    if (request.method != 'GET') {
      return shelf.Response(405, headers: const <String, String>{
        'allow': 'GET',
      });
    }
    final Map<String, Object?> body = <String, Object?>{
      'status': 'ok',
      'version': version,
      'uptime_s': _uptimeSeconds,
      'rooms': registry.roomCount,
    };
    return shelf.Response.ok(
      jsonEncode(body),
      headers: const <String, String>{
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  }

  /// `GET /privacy` and `HEAD /privacy` (and their trailing-slash forms,
  /// which are matched identically, not redirected) never reach the
  /// WebSocket upgrade path either, for the same reason [_handleHealth]
  /// doesn't. Any other method is a `405` naming `GET` and `HEAD` in
  /// `allow`.
  shelf.Response _handlePrivacy(shelf.Request request) {
    const Map<String, String> headers = <String, String>{
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'public, max-age=3600',
    };
    switch (request.method) {
      case 'GET':
        return shelf.Response.ok(_privacyHtml, headers: headers);
      case 'HEAD':
        return shelf.Response.ok('', headers: headers);
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
    }
  }

  /// `GET /.well-known/assetlinks.json` and `HEAD` of the same, never
  /// reaching the WebSocket upgrade path either. With no shape-valid
  /// fingerprint configured, answers `404` with an empty body -- see
  /// [_assetLinksJson]'s doc comment for why that, and not `[]`, is the
  /// honest answer. Any other method is a `405` naming `GET` and `HEAD`.
  shelf.Response _handleAssetLinks(shelf.Request request) {
    switch (request.method) {
      case 'GET':
      case 'HEAD':
        final String? body = _assetLinksJson;
        if (body == null) {
          return shelf.Response(404, body: '');
        }
        const Map<String, String> headers = <String, String>{
          'content-type': 'application/json',
        };
        return shelf.Response.ok(
          request.method == 'HEAD' ? '' : body,
          headers: headers,
        );
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
    }
  }

  /// `GET /r/<CODE>` and `HEAD` of the same, never reaching the WebSocket
  /// upgrade path either. [rawCode] is whatever text matched the path
  /// pattern in [start]'s handler, upper-cased and checked against
  /// `isWellFormedRoomCode` here -- the only validation this route performs.
  /// It deliberately never asks [registry] whether a room with this code
  /// exists: a valid-shape code answers `200` whether or not the room is
  /// real, because the code is the only thing protecting a private room and
  /// a route that answered differently for a live code than a dead one
  /// would let brute-forcing codes work.
  shelf.Response _handleRoomLink(shelf.Request request, String rawCode) {
    switch (request.method) {
      case 'GET':
      case 'HEAD':
        final String code = rawCode.toUpperCase();
        if (!isWellFormedRoomCode(code)) {
          return shelf.Response.notFound('');
        }
        const Map<String, String> headers = <String, String>{
          'content-type': 'text/html; charset=utf-8',
        };
        return shelf.Response.ok(
          request.method == 'HEAD' ? '' : buildRoomLandingPageHtml(code),
          headers: headers,
        );
      default:
        return shelf.Response(405, headers: const <String, String>{
          'allow': 'GET, HEAD',
        });
    }
  }

  /// Whole seconds since [start] completed, from the injected [clock]. Zero
  /// before [start] has completed and never negative afterwards, even if the
  /// clock is a test double that has not strictly advanced.
  int get _uptimeSeconds {
    final DateTime? startedAt = _startedAt;
    if (startedAt == null) {
      return 0;
    }
    final int seconds = clock.now.difference(startedAt).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }

  /// The client's IP, section 7's rate limits being scoped by it. The
  /// immediate TCP peer address unless that peer is a configured trusted
  /// proxy, in which case the leftmost address in `X-Forwarded-For` is
  /// believed instead -- trusting that header from an arbitrary peer would
  /// let anyone forge their way around every IP-scoped limit.
  String _clientIp(shelf.Request request) {
    final HttpConnectionInfo? info =
        request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
    final String remote = info?.remoteAddress.address ?? 'unknown';
    if (!_trustedProxies.contains(remote)) {
      return remote;
    }
    final String? forwarded = request.headers[forwardedForHeader];
    if (forwarded == null || forwarded.trim().isEmpty) {
      return remote;
    }
    return forwarded.split(',').first.trim();
  }
}

/// The `RoomHub` `connection.dart` depends on. Tracks, per room code, the
/// sockets currently attached to it, and the reverse mapping so a connection
/// can find its own room on detach without `connection.dart` exposing any
/// private state for that purpose.
class _ConnectionHub implements RoomHub {
  final Map<String, Set<Connection>> _byRoom = <String, Set<Connection>>{};
  final Map<Connection, String> _roomByConnection = <Connection, String>{};

  @override
  Connection? attach({required String code, required Connection conn}) {
    final String? previousRoom = _roomByConnection[conn];
    if (previousRoom != null && previousRoom != code) {
      _removeFromRoom(previousRoom, conn);
    }

    final Set<Connection> sockets = _byRoom.putIfAbsent(
      code,
      () => <Connection>{},
    );

    Connection? displaced;
    for (final Connection other in sockets) {
      if (!identical(other, conn) &&
          other.seatToken != null &&
          other.seatToken == conn.seatToken) {
        displaced = other;
        break;
      }
    }
    if (displaced != null) {
      _removeFromRoom(code, displaced);
    }

    sockets.add(conn);
    _roomByConnection[conn] = code;
    return displaced;
  }

  @override
  void detach(Connection conn) {
    final String? code = _roomByConnection[conn];
    if (code == null) {
      return;
    }
    _removeFromRoom(code, conn);
  }

  @override
  void broadcast({
    required String code,
    required String type,
    required Map<String, Object?> data,
    Connection? exceptConn,
  }) {
    final Set<Connection>? sockets = _byRoom[code];
    if (sockets == null) {
      return;
    }
    // Copied because sendPush can, transitively, never mutate this set
    // itself, but iterating a live Set while a caller elsewhere detaches
    // from it is exactly the kind of concurrent-modification bug worth
    // paying one allocation to rule out.
    for (final Connection conn in List<Connection>.of(sockets)) {
      if (identical(conn, exceptConn)) {
        continue;
      }
      conn.sendPush(type: type, data: data);
    }
  }

  void _removeFromRoom(String code, Connection conn) {
    final Set<Connection>? sockets = _byRoom[code];
    if (sockets == null) {
      return;
    }
    sockets.remove(conn);
    _roomByConnection.remove(conn);
    if (sockets.isEmpty) {
      _byRoom.remove(code);
    }
  }
}
