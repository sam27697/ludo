// The socket layer proper: the `shelf` pipeline, the WebSocket upgrade, the
// `RoomHub` implementation `connection.dart` declares and depends on, client
// IP extraction (including the trusted-proxy rule for a forwarded header),
// and the once-a-minute housekeeping timer that drives both
// `RoomRegistry.reap()` and `RateLimiter.prune()`. Nothing here touches room
// state directly; it only wires sockets to `Connection` and `Connection` to
// the registry, exactly the split `connection.dart`'s own header comment
// describes.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'clock.dart';
import 'connection.dart';
import 'rate_limit.dart';
import 'registry.dart';

/// How often the housekeeping timer fires: `RoomRegistry.reap()` and
/// `RateLimiter.prune()` both run on this cadence. `docs/PROTOCOL.md` does
/// not pin an exact number; the work order asks for "around once a minute"
/// and this is that.
const Duration housekeepingInterval = Duration(minutes: 1);

/// The header a reverse proxy is expected to set with the real client
/// address. Only trusted when the immediate peer address is in the
/// configured proxy list.
const String forwardedForHeader = 'x-forwarded-for';

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
  })  : _random = random ?? Random.secure(),
        _trustedProxies = trustedProxies,
        _hub = _ConnectionHub();

  final RoomRegistry registry;
  final RateLimiter rateLimiter;
  final Clock clock;
  final Random _random;

  /// Addresses (as `InternetAddress.address` strings) allowed to set
  /// [forwardedForHeader] and be believed. Empty by default: with no
  /// configured proxy, every connection's IP is the immediate TCP peer
  /// address and any `X-Forwarded-For` header an untrusted client sends is
  /// ignored outright, never inspected at all.
  final Set<String> _trustedProxies;

  final _ConnectionHub _hub;

  HttpServer? _httpServer;
  Timer? _housekeeping;

  /// Starts listening. [address] is anything `HttpServer.bind` accepts
  /// (`InternetAddress` or a host string); [port] `0` binds an ephemeral
  /// port, readable back afterwards from [port].
  Future<void> start({required Object address, required int port}) async {
    final shelf.Handler handler = (shelf.Request request) {
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
