// A black-box WebSocket harness for tests that speak the wire protocol of
// `docs/PROTOCOL.md` directly, against a real, running `WireServer`, rather
// than calling into `RoomRegistry` in-process. Nothing here imports a message
// type or a field name that is specific to any one message: every test that
// uses this file builds its own JSON `d` maps and reads the JSON `d` maps it
// gets back, exactly as a real client would. That is deliberate: a test built
// this way cannot pass by accident just because it happens to share a typo
// with the code it is testing.
//
// Modelled on `health_test.dart`'s own `_Harness`, which is the only other
// place in this package that starts a real `WireServer` for a test. That
// class stays private to its own file; this one is shared because more than
// one wire-level suite needs the same plumbing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

/// One running server for the lifetime of a single test: a fresh
/// [RoomRegistry], [RateLimiter] and [FakeClock], and the [WireServer] that
/// wires them to a real listening socket. `build` does not start the server;
/// call [start] once the caller is ready to connect clients to it.
class ServerHarness {
  ServerHarness._(this.clock, this.registry, this.server);

  final FakeClock clock;
  final RoomRegistry registry;
  final WireServer server;

  static ServerHarness build() {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 8, 28));
    final RoomRegistry registry =
        RoomRegistry(clock: clock, secure: Random.secure());
    final RateLimiter rateLimiter = RateLimiter(clock: clock);
    final WireServer server = WireServer(
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
    );
    return ServerHarness._(clock, registry, server);
  }

  /// Binds an ephemeral loopback port. Safe to call exactly once per
  /// instance; a second call would try to bind again and fail.
  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  /// The `ws://` root a client dials to reach this server. Only meaningful
  /// after [start] has completed.
  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Future<void> close() => server.close();
}

/// Delivers decoded frames to whichever `next()` call is waiting for one,
/// in arrival order, buffering anything that arrives with nobody waiting.
/// This is the entire ordering guarantee a test can rely on: frames are
/// handed out in the order the socket produced them, never reordered and
/// never dropped.
class _FrameQueue {
  _FrameQueue(Stream<Map<String, Object?>> source) {
    _subscription = source.listen(
      (Map<String, Object?> frame) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(frame);
        } else {
          _buffered.add(frame);
        }
      },
      onDone: () {
        _done = true;
        for (final Completer<Map<String, Object?>> completer in _waiting) {
          completer.completeError(
            StateError('socket closed before a frame arrived'),
          );
        }
        _waiting.clear();
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final Completer<Map<String, Object?>> completer in _waiting) {
          completer.completeError(error, stackTrace);
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<Map<String, Object?>> _subscription;
  final List<Map<String, Object?>> _buffered = <Map<String, Object?>>[];
  final List<Completer<Map<String, Object?>>> _waiting =
      <Completer<Map<String, Object?>>>[];
  bool _done = false;

  Future<Map<String, Object?>> next() {
    if (_buffered.isNotEmpty) {
      return Future<Map<String, Object?>>.value(_buffered.removeAt(0));
    }
    if (_done) {
      return Future<Map<String, Object?>>.error(
        StateError('socket already closed and no frame was pending'),
      );
    }
    final Completer<Map<String, Object?>> completer =
        Completer<Map<String, Object?>>();
    _waiting.add(completer);
    return completer.future;
  }

  Future<void> close() => _subscription.cancel();
}

/// A real WebSocket client speaking the envelope shape of
/// `docs/PROTOCOL.md` section 1: `{ "v": 1, "t": ..., "id": ..., "d": ... }`
/// out, the same shape plus an optional `re` in. Every message id this
/// client mints is a plain, deterministic counter, `test-msg-<n>`, well
/// inside the 8-to-64-character `[A-Za-z0-9_-]` id shape the protocol
/// requires -- there is nothing random in it, so a failure that names the
/// id is reproducible by re-running the same test.
class WireTestClient {
  WireTestClient._(this._socket, this._queue);

  final WebSocket _socket;
  final _FrameQueue _queue;
  int _idCounter = 0;

  static Future<WireTestClient> connect(Uri uri) async {
    final WebSocket socket = await WebSocket.connect(uri.toString());
    final Stream<Map<String, Object?>> decoded = socket.map(
      (Object? raw) => jsonDecode(raw! as String) as Map<String, Object?>,
    );
    return WireTestClient._(socket, _FrameQueue(decoded));
  }

  /// Sends one client-to-server frame and returns the `id` it was sent
  /// with, so a caller can assert a reply's `re` matches it.
  String send(String type, Map<String, Object?> data, {String? id}) {
    final String messageId = id ?? 'test-msg-${++_idCounter}';
    _socket.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': messageId,
      'd': data,
    }));
    return messageId;
  }

  /// The next frame this socket receives, decoded, in arrival order. Bounded
  /// by [timeout] so a frame the server never sends fails the test promptly
  /// rather than hanging the suite -- this is a liveness bound on a real
  /// socket, not a fixed sleep standing in for a condition.
  Future<Map<String, Object?>> next({
    Duration timeout = const Duration(seconds: 3),
  }) {
    return _queue.next().timeout(
          timeout,
          onTimeout: () => throw TestFailure(
            'expected another frame on this socket within $timeout and none '
            'arrived',
          ),
        );
  }

  Future<void> close() async {
    await _queue.close();
    if (_socket.readyState == WebSocket.open) {
      await _socket.close();
    }
  }
}
