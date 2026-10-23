// Order 439, `docs/PROTOCOL.md` section 24 (a dead link is noticed), client
// half: the real [WsTransport] against a local dart:io WebSocket server that
// sends no ping of its own, reached through a black-hole TCP proxy.
//
// The proxy forwards bytes both ways until `blackHole()` is called, then
// reads and discards everything in both directions without closing either
// side. To the transport that is a phone whose network silently died: the
// TCP connection still looks established and nothing is ever answered. Only a
// ping of its own that goes unanswered can reveal it.
//
// Plain `test`, no widgets, real sockets on the loopback interface, real
// clock. There is no seed: every scenario is deterministic apart from timing,
// and a failure message names the scenario (C1 to C4) and the interval used.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/net/ws_transport.dart';

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
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _BlackHoleProxy._(server, targetPort);
  }

  int get port => _server.port;

  /// Bytes carried client to server and server to client while the proxy was
  /// still forwarding.
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
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _targetPort,
      );
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

/// A WebSocket server that echoes every text frame and sends no ping of its
/// own (dart:io's `pingInterval` is left at its default, null). It still
/// answers pings with pongs, as every conforming WebSocket does.
class _EchoServer {
  _EchoServer._(this._http) {
    _http.listen((HttpRequest request) async {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen(
        (Object? message) => socket.add(message),
        onError: (Object _) {},
        cancelOnError: true,
      );
    });
  }

  final HttpServer _http;
  final List<WebSocket> _sockets = <WebSocket>[];

  static Future<_EchoServer> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return _EchoServer._(http);
  }

  int get port => _http.port;

  /// Called after the proxy is destroyed, so no close handshake can hang on
  /// a black-holed peer.
  Future<void> close() async {
    for (final WebSocket socket in _sockets) {
      await socket.close().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    await _http.close(force: true);
  }
}

/// Every text frame a transport delivers, with waiters.
class _Inbox {
  _Inbox(WireTransport transport) {
    transport.incoming.listen((String text) {
      received.add(text);
      for (final void Function() listener in List<void Function()>.of(
        _listeners,
      )) {
        listener();
      }
    }, onError: (Object _) {});
  }

  final List<String> received = <String>[];
  final List<void Function()> _listeners = <void Function()>[];

  /// The next text frame past the [from]-th, or null after [within].
  Future<String?> waitForFrame(int from, {required Duration within}) {
    if (received.length > from) {
      return Future<String?>.value(received[from]);
    }
    final Completer<String?> completer = Completer<String?>();
    late final void Function() listener;
    listener = () {
      if (received.length > from && !completer.isCompleted) {
        completer.complete(received[from]);
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
}

/// Completes with true when [future] completes, or false after [within].
Future<bool> _completesWithin(Future<void> future, Duration within) {
  final Completer<bool> completer = Completer<bool>();
  final Timer timer = Timer(within, () {
    if (!completer.isCompleted) {
      completer.complete(false);
    }
  });
  future.then((_) {
    if (!completer.isCompleted) {
      completer.complete(true);
    }
  });
  return completer.future.whenComplete(timer.cancel);
}

Future<void> _roundTrip(
  WireTransport transport,
  _Inbox inbox,
  String text,
  String scenario,
) async {
  final int before = inbox.received.length;
  transport.send(text);
  final String? echoed = await inbox.waitForFrame(
    before,
    within: const Duration(seconds: 3),
  );
  expect(
    echoed,
    text,
    reason:
        '$scenario: expected the text frame "$text" to be echoed back '
        'within 3s; got $echoed (frames received: ${inbox.received})',
  );
}

void main() {
  group('C1 and C2: a transport behind the proxy', () {
    test('C1: a transport behind a black hole completes done within 1000 ms '
        'of the black hole', () async {
      const String name = 'C1 (pingInterval=200ms, bound=1000ms)';
      final _EchoServer server = await _EchoServer.start();
      final _BlackHoleProxy proxy = await _BlackHoleProxy.start(server.port);
      WireTransport? opened;
      try {
        final WireTransport transport = opened = await connectWsTransport(
          Uri.parse('ws://127.0.0.1:${proxy.port}/'),
          pingInterval: _interval,
        );
        final _Inbox inbox = _Inbox(transport);
        await _roundTrip(transport, inbox, 'hello', name);

        bool done = false;
        unawaited(transport.done.then((_) => done = true));
        proxy.blackHole();
        final Stopwatch sinceBlackHole = Stopwatch()..start();
        final bool completed = await _completesWithin(transport.done, _bound);
        final Duration latency = sinceBlackHole.elapsed;
        expect(
          completed,
          isTrue,
          reason:
              '$name: expected transport.done to complete within $_bound '
              'of the black hole (docs/PROTOCOL.md section 24 rule 3: a '
              'missed pong closes the socket within two intervals) and it '
              'was still pending. done=$done',
        );
        // ignore: avoid_print
        print(
          'C1 measured latency: ${latency.inMilliseconds} ms from the '
          'black hole to transport.done',
        );
      } finally {
        await opened?.close();
        await proxy.close();
        await server.close();
      }
    });

    test('C2: with pongs flowing, done stays pending over 1000 ms (five '
        'intervals) and a text frame still round-trips', () async {
      const String name = 'C2 (pingInterval=200ms, window=1000ms)';
      final _EchoServer server = await _EchoServer.start();
      final _BlackHoleProxy proxy = await _BlackHoleProxy.start(server.port);
      WireTransport? opened;
      try {
        final WireTransport transport = opened = await connectWsTransport(
          Uri.parse('ws://127.0.0.1:${proxy.port}/'),
          pingInterval: _interval,
        );
        final _Inbox inbox = _Inbox(transport);
        await _roundTrip(transport, inbox, 'hello', name);

        final int toServerBefore = proxy.bytesToServer;
        final int fromServerBefore = proxy.bytesFromServer;
        final bool completed = await _completesWithin(transport.done, _bound);
        expect(
          completed,
          isFalse,
          reason:
              '$name: expected transport.done to stay pending over '
              '$_bound while the peer answered every ping (section 24 rule '
              '5), but it completed',
        );
        // The control is only meaningful if the keepalive actually ran: the
        // transport must have sent control frames (bytes with no text frame
        // sent) and the server must have answered them.
        expect(
          proxy.bytesToServer - toServerBefore,
          greaterThan(0),
          reason:
              '$name: expected the transport to send at least one ping '
              'over $_bound and no bytes left it',
        );
        expect(
          proxy.bytesFromServer - fromServerBefore,
          greaterThan(0),
          reason:
              '$name: expected the server to answer with at least one '
              'pong over $_bound and no bytes came back',
        );
        await _roundTrip(transport, inbox, 'still here', name);
      } finally {
        await opened?.close();
        await proxy.close();
        await server.close();
      }
    });
  });

  group('C3: connecting is bounded', () {
    test('C3: a listener that accepts TCP and never answers fails the connect '
        'within 1500 ms and leaves no socket open', () async {
      const String name = 'C3 (connectTimeout=300ms, bound=1500ms)';
      const Duration connectTimeout = Duration(milliseconds: 300);
      const Duration bound = Duration(milliseconds: 1500);
      final ServerSocket listener = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final List<Socket> accepted = <Socket>[];
      final Completer<void> peerClosed = Completer<void>();
      listener.listen((Socket socket) {
        accepted.add(socket);
        socket.listen(
          (List<int> _) {},
          onDone: () {
            if (!peerClosed.isCompleted) {
              peerClosed.complete();
            }
          },
          onError: (Object _) {
            if (!peerClosed.isCompleted) {
              peerClosed.complete();
            }
          },
          cancelOnError: true,
        );
      });
      WireTransport? opened;
      try {
        final Stopwatch clock = Stopwatch()..start();
        final Completer<Object?> outcome = Completer<Object?>();
        connectWsTransport(
          Uri.parse('ws://127.0.0.1:${listener.port}/'),
          connectTimeout: connectTimeout,
        ).then(
          (WireTransport t) {
            opened = t;
            if (!outcome.isCompleted) {
              outcome.complete(t);
            }
          },
          onError: (Object error) {
            if (!outcome.isCompleted) {
              outcome.complete(error);
            }
          },
        );
        final Object? result = await outcome.future.timeout(
          bound,
          onTimeout: () => throw TestFailure(
            '$name: expected connectWsTransport to complete with an error '
            'within $bound and it was still pending (no timeout applied to '
            'the connect; docs/PROTOCOL.md section 24 rule 4)',
          ),
        );
        final Duration failedAfter = clock.elapsed;
        expect(
          result is WireTransport,
          isFalse,
          reason:
              '$name: expected an error, got a transport that was never '
              'answered',
        );
        expect(
          failedAfter,
          greaterThanOrEqualTo(const Duration(milliseconds: 250)),
          reason:
              '$name: expected the connect to fail because the '
              '$connectTimeout timeout elapsed, but it failed after '
              '${failedAfter.inMilliseconds}ms with $result',
        );

        final bool closed = await _completesWithin(peerClosed.future, bound);
        expect(
          closed,
          isTrue,
          reason:
              '$name: expected the listener to see the client socket '
              'closed within $bound after the connect failed (no socket '
              'left open, section 24 rule 4) and it stayed open',
        );
        // ignore: avoid_print
        print(
          'C3 measured: connect failed after '
          '${failedAfter.inMilliseconds} ms; listener saw the socket '
          'close ${(clock.elapsed - failedAfter).inMilliseconds} ms later',
        );
      } finally {
        await opened?.close();
        for (final Socket socket in accepted) {
          socket.destroy();
        }
        await listener.close();
      }
    });
  });

  group('C4: the constants', () {
    test('kKeepaliveInterval and kConnectTimeout are both 10 seconds', () {
      expect(
        kKeepaliveInterval,
        const Duration(seconds: 10),
        reason:
            'C4: section 24 rule 1 says a ping every 10 seconds; got '
            '$kKeepaliveInterval',
      );
      expect(
        kConnectTimeout,
        const Duration(seconds: 10),
        reason:
            'C4: section 24 rule 4 says a connect is abandoned after 10 '
            'seconds; got $kConnectTimeout',
      );
    });
  });
}
