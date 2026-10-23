// Order 439, `docs/PROTOCOL.md` section 24 (a dead link is noticed): a real
// `WireServer` on an ephemeral port, real WebSocket clients, and a black-hole
// TCP proxy that makes a half-open link on demand.
//
// The proxy forwards bytes both ways until `blackHole()` is called, then
// reads and discards everything in both directions without closing either
// side. To the server the peer behind the proxy is a phone whose network
// silently died: the TCP connection is still established, nothing is
// answered. Only a ping that goes unanswered can reveal it.
//
// The server is built with `keepaliveInterval` 200 ms so the bound of
// section 24 rule 3 (two intervals) is 400 ms; the tests allow 1000 ms.
//
// Every scenario here is deterministic apart from the real clock: there is
// no seed. A failure message names the scenario (K1, K2, K3), the interval,
// and the frames the observing seat saw, which is everything needed to
// re-run it.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

const Duration _interval = Duration(milliseconds: 200);
const Duration _bound = Duration(milliseconds: 1000);

/// Forwards TCP between a loopback listener and [targetPort] until
/// [blackHole] is called, then drops every byte in both directions and
/// closes nothing.
class _BlackHoleProxy {
  _BlackHoleProxy._(this._server, this._targetPort) {
    _server.listen(_onAccept);
  }

  final ServerSocket _server;
  final int _targetPort;
  final List<Socket> _sockets = <Socket>[];
  bool _holed = false;
  int _bytesToServer = 0;
  int _bytesFromServer = 0;

  static Future<_BlackHoleProxy> start(int targetPort) async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _BlackHoleProxy._(server, targetPort);
  }

  int get port => _server.port;

  /// Bytes the proxy carried from the client to the real server, and from
  /// the real server to the client, while it was still forwarding.
  int get bytesToServer => _bytesToServer;
  int get bytesFromServer => _bytesFromServer;

  /// Stops forwarding in both directions. Nothing is closed.
  void blackHole() {
    _holed = true;
  }

  Future<void> _onAccept(Socket client) async {
    _sockets.add(client);
    client.setOption(SocketOption.tcpNoDelay, true);
    final Socket upstream;
    try {
      upstream =
          await Socket.connect(InternetAddress.loopbackIPv4, _targetPort);
    } on SocketException {
      client.destroy();
      return;
    }
    _sockets.add(upstream);
    upstream.setOption(SocketOption.tcpNoDelay, true);
    client.listen(
      (List<int> data) {
        if (_holed) {
          return;
        }
        _bytesToServer += data.length;
        upstream.add(data);
      },
      onDone: () {
        if (!_holed) {
          upstream.close();
        }
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
    upstream.listen(
      (List<int> data) {
        if (_holed) {
          return;
        }
        _bytesFromServer += data.length;
        client.add(data);
      },
      onDone: () {
        if (!_holed) {
          client.close();
        }
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  /// Test cleanup: destroys every socket and the listener.
  Future<void> close() async {
    for (final Socket socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

class _Seen {
  _Seen(this.frame, this.at);

  final Map<String, Object?> frame;
  final Duration at;

  @override
  String toString() => '+${at.inMilliseconds}ms $frame';
}

/// Reads every frame a [WireTestClient] receives into a timestamped list, so
/// a test can ask "did X arrive, and when" without racing the queue. A single
/// reader is kept pending at all times; [WireTestClient.next] loses a frame
/// to an abandoned waiter if it is ever timed out and called again.
class _FrameLog {
  _FrameLog(this._client, this._clock) {
    unawaited(_pump());
  }

  final WireTestClient _client;
  final Stopwatch _clock;
  final List<_Seen> seen = <_Seen>[];
  final List<void Function()> _listeners = <void Function()>[];
  bool _stopped = false;

  Future<void> _pump() async {
    while (!_stopped) {
      final Map<String, Object?> frame;
      try {
        frame = await _client.next(timeout: const Duration(seconds: 30));
      } catch (_) {
        return;
      }
      seen.add(_Seen(frame, _clock.elapsed));
      for (final void Function() listener
          in List<void Function()>.of(_listeners)) {
        listener();
      }
    }
  }

  void stop() {
    _stopped = true;
  }

  _Seen? _find(bool Function(_Seen) test, int from) {
    for (int i = from; i < seen.length; i++) {
      if (test(seen[i])) {
        return seen[i];
      }
    }
    return null;
  }

  /// The first frame, among those already seen or arriving within [within],
  /// for which [test] holds; null when none does.
  Future<_Seen?> waitFor(
    bool Function(_Seen) test, {
    required Duration within,
  }) {
    final _Seen? already = _find(test, 0);
    if (already != null) {
      return Future<_Seen?>.value(already);
    }
    final Completer<_Seen?> completer = Completer<_Seen?>();
    late final void Function() listener;
    int scanned = seen.length;
    listener = () {
      final _Seen? hit = _find(test, scanned);
      scanned = seen.length;
      if (hit != null && !completer.isCompleted) {
        completer.complete(hit);
      }
    };
    _listeners.add(listener);
    final Timer timer = Timer(within, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });
    return completer.future.whenComplete(() {
      timer.cancel();
      _listeners.remove(listener);
    });
  }

  Future<_Seen> expectType(String type, String scenario) async {
    final _Seen? hit = await waitFor(
      (_Seen s) => s.frame['t'] == type,
      within: const Duration(seconds: 3),
    );
    if (hit == null) {
      throw TestFailure(
        '$scenario: expected a "$type" frame within 3s and none arrived; '
        'frames seen: $seen',
      );
    }
    return hit;
  }
}

bool Function(_Seen) _presenceOf(int seat, {required bool connected}) {
  return (_Seen s) {
    if (s.frame['t'] != 'presence') {
      return false;
    }
    final Map<String, Object?> d = s.frame['d']! as Map<String, Object?>;
    return d['seat'] == seat && d['connected'] == connected;
  };
}

WireServer _buildServer({Duration? keepaliveInterval}) {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 10, 23));
  return WireServer(
    registry: RoomRegistry(clock: clock, secure: Random.secure()),
    rateLimiter: RateLimiter(clock: clock),
    clock: clock,
    keepaliveInterval: keepaliveInterval,
  );
}

/// Two seats in a lobby: seat A direct, seat B through a black-hole proxy.
class _Scenario {
  _Scenario._(
    this.name,
    this.server,
    this.proxy,
    this.a,
    this.b,
    this.aLog,
    this.bLog,
    this.bSeat,
    this.clock,
  );

  final String name;
  final WireServer server;
  final _BlackHoleProxy proxy;
  final WireTestClient a;
  final WireTestClient b;
  final _FrameLog aLog;
  final _FrameLog bLog;
  final int bSeat;
  final Stopwatch clock;

  static Future<_Scenario> open(String name) async {
    final Stopwatch clock = Stopwatch()..start();
    final WireServer server = _buildServer(keepaliveInterval: _interval);
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    final _BlackHoleProxy proxy = await _BlackHoleProxy.start(server.port);
    final Uri direct = Uri(
      scheme: 'ws',
      host: '127.0.0.1',
      port: server.port,
      path: '/',
    );
    final Uri viaProxy = direct.replace(port: proxy.port);

    final WireTestClient a = await WireTestClient.connect(direct);
    final _FrameLog aLog = _FrameLog(a, clock);
    a.send('create_room', <String, Object?>{'name': 'Anna', 'players': 2});
    await aLog.expectType('seat_assigned', name);
    final _Seen roomFrame = await aLog.expectType('room', name);
    final String code =
        (roomFrame.frame['d']! as Map<String, Object?>)['code']! as String;

    final WireTestClient b = await WireTestClient.connect(viaProxy);
    final _FrameLog bLog = _FrameLog(b, clock);
    b.send('join_room', <String, Object?>{'code': code, 'name': 'Bo'});
    final _Seen bAssigned = await bLog.expectType('seat_assigned', name);
    final int bSeat =
        (bAssigned.frame['d']! as Map<String, Object?>)['seat']! as int;
    await aLog.expectType('player_joined', name);
    return _Scenario._(name, server, proxy, a, b, aLog, bLog, bSeat, clock);
  }

  Future<void> close() async {
    aLog.stop();
    bLog.stop();
    await proxy.close();
    await b.close().timeout(const Duration(seconds: 3), onTimeout: () {});
    await a.close().timeout(const Duration(seconds: 3), onTimeout: () {});
    await server.close();
  }
}

void main() {
  group('K1 and K2: presence of a seat behind the proxy', () {
    test(
        'K1: a black-holed seat is reported connected:false to the other seat '
        'within 1000 ms of the black hole, and not before it', () async {
      const String name = 'K1 (keepaliveInterval=200ms, bound=1000ms)';
      final _Scenario s = await _Scenario.open(name);
      try {
        // A healthy link first: two and a half intervals of ping and pong
        // with the proxy forwarding. Nothing may report seat B gone while
        // its pongs are flowing.
        final _Seen? early = await s.aLog.waitFor(
          _presenceOf(s.bSeat, connected: false),
          within: const Duration(milliseconds: 500),
        );
        expect(
          early,
          isNull,
          reason: '$name: expected no presence connected:false for seat '
              '${s.bSeat} before the black hole (its pongs were flowing); '
              'got $early. Frames seen by A: ${s.aLog.seen}',
        );

        s.proxy.blackHole();
        final Duration blackHoleAt = s.clock.elapsed;
        final _Seen? hit = await s.aLog.waitFor(
          _presenceOf(s.bSeat, connected: false),
          within: _bound,
        );
        expect(
          hit,
          isNotNull,
          reason: '$name: expected seat A to receive presence '
              '{seat: ${s.bSeat}, connected: false} within $_bound of the '
              'black hole (docs/PROTOCOL.md section 24 rule 3, bound 20 s at '
              'the 10 s default, two intervals) and it did not. Black hole '
              'at +${blackHoleAt.inMilliseconds}ms. Frames seen by A: '
              '${s.aLog.seen}',
        );
        final Duration latency = hit!.at - blackHoleAt;
        expect(
          latency,
          greaterThanOrEqualTo(Duration.zero),
          reason: '$name: presence connected:false for seat ${s.bSeat} '
              'arrived at +${hit.at.inMilliseconds}ms, before the black '
              'hole at +${blackHoleAt.inMilliseconds}ms. Frames seen by A: '
              '${s.aLog.seen}',
        );
        expect(
          latency,
          lessThanOrEqualTo(_bound),
          reason: '$name: presence arrived ${latency.inMilliseconds}ms after '
              'the black hole, expected at most ${_bound.inMilliseconds}ms',
        );
        // ignore: avoid_print
        print('K1 measured latency: ${latency.inMilliseconds} ms from the '
            'black hole to presence connected:false');
      } finally {
        await s.close();
      }
    });

    test(
        'K2: with pongs flowing, seat A sees no connected:false for seat B '
        'over 1000 ms (five intervals)', () async {
      const String name = 'K2 (keepaliveInterval=200ms, window=1000ms)';
      final _Scenario s = await _Scenario.open(name);
      try {
        final int toServerBefore = s.proxy.bytesToServer;
        final int fromServerBefore = s.proxy.bytesFromServer;
        final _Seen? hit = await s.aLog.waitFor(
          _presenceOf(s.bSeat, connected: false),
          within: _bound,
        );
        expect(
          hit,
          isNull,
          reason: '$name: expected no presence connected:false for seat '
              '${s.bSeat} over $_bound with no black hole (a seat is never '
              'marked not connected while its pongs arrive, section 24 rule '
              '5); got $hit. Frames seen by A: ${s.aLog.seen}',
        );
        // The control is only meaningful if the keepalive actually ran: over
        // five intervals the server must have pinged seat B (bytes from the
        // server with nobody sending a protocol message) and B's end must
        // have answered (bytes back to the server).
        expect(
          s.proxy.bytesFromServer - fromServerBefore,
          greaterThan(0),
          reason: '$name: expected the server to send seat B at least one '
              'control frame (a ping) over $_bound and it sent no bytes',
        );
        expect(
          s.proxy.bytesToServer - toServerBefore,
          greaterThan(0),
          reason: '$name: expected seat B to answer with at least one pong '
              'over $_bound and no bytes came back',
        );
        // The seat is still live: a request on its socket is still answered.
        s.b.send('ping', <String, Object?>{});
        final _Seen? pong = await s.bLog.waitFor(
          (_Seen f) => f.frame['t'] == 'pong',
          within: const Duration(seconds: 2),
        );
        expect(
          pong,
          isNotNull,
          reason: '$name: expected seat B to still be served after the '
              'control window (a protocol ping answered by a pong) and it '
              'was not. Frames seen by B: ${s.bLog.seen}',
        );
      } finally {
        await s.close();
      }
    });
  });

  group('K3: the default interval', () {
    test('defaultKeepaliveInterval is 10 seconds', () {
      expect(
        defaultKeepaliveInterval,
        const Duration(seconds: 10),
        reason: 'K3: docs/PROTOCOL.md section 24 rule 1 says every 10 '
            'seconds; got $defaultKeepaliveInterval',
      );
    });

    test('a WireServer built without the argument uses the default', () {
      final WireServer server = _buildServer();
      expect(
        server.keepaliveInterval,
        defaultKeepaliveInterval,
        reason: 'K3: a WireServer built without keepaliveInterval must use '
            'defaultKeepaliveInterval; got ${server.keepaliveInterval}',
      );
    });

    test('a WireServer built with an interval keeps it', () {
      final WireServer server = _buildServer(keepaliveInterval: _interval);
      expect(
        server.keepaliveInterval,
        _interval,
        reason: 'K3: a WireServer built with keepaliveInterval=$_interval '
            'must report it; got ${server.keepaliveInterval}',
      );
    });
  });
}
