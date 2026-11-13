// Proof for contract C-635 (work/ludo/orders/634-update-required.md, order
// 635t), docs/PROTOCOL.md section 27 rule 1: the app says which build it is
// on the WebSocket upgrade request, in one header, and says nothing when it
// does not know.
//
//   Ludo-Client-Build: <decimal integer>
//
// A real dart:io HttpServer on an ephemeral loopback port records the headers
// of the upgrade request and completes the upgrade with
// WebSocketTransformer.upgrade, and connectWsTransport (the one real
// transport) is pointed at it. Nothing is faked: the header is read off the
// request the server really received.
//
// `clientBuild:` is a parameter connectWsTransport does not have on the tree
// this was written for, so this file does not compile there, by design.
//
// Cases:
//   H1.*    a build of 1 or more is sent, as plain decimal, once
//   H2.*    null, 0 and any negative build send no header at all
//   H3      the upgrade still completes and carries frames both ways with
//           the header present
//   H4      one request per connect, each carrying the build it was given
//
// There is no random input. Each failure reason names the case, what was
// expected, what the server received, and ends with the command that replays
// that one case:
//   flutter test test/c635_ws_header_test.dart --plain-name '<id>'

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/net/ws_transport.dart';

const String _header = 'ludo-client-build';
const Duration _wait = Duration(seconds: 10);

String _reproduce(String id) =>
    'reproduce: flutter test test/c635_ws_header_test.dart '
    '--plain-name "$id"';

/// One upgrade request as the server saw it.
class _Seen {
  _Seen(this.values, this.allNames, this.upgrade);

  /// Every value of the build header, in order; empty when absent.
  final List<String> values;

  /// Every header name the request carried, lower case.
  final List<String> allNames;

  /// The Upgrade header, lower case.
  final String upgrade;

  String get brief =>
      'header values $values (names: ${allNames.join(', ')}; upgrade '
      '"$upgrade")';
}

/// Accepts WebSocket upgrades and records each request. [sockets] holds every
/// accepted socket so a case can close them before it ends.
class _Recorder {
  _Recorder._(this._server);

  final HttpServer _server;
  final List<_Seen> seen = <_Seen>[];
  final List<WebSocket> sockets = <WebSocket>[];
  final List<Completer<void>> _arrivals = <Completer<void>>[];

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}/');

  static Future<_Recorder> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _Recorder recorder = _Recorder._(server);
    unawaited(recorder._serve());
    return recorder;
  }

  Future<void> _serve() async {
    await for (final HttpRequest request in _server) {
      final List<String> names = <String>[];
      request.headers.forEach((String name, List<String> values) {
        names.add(name.toLowerCase());
      });
      final List<String> values = request.headers[_header] ?? const <String>[];
      final String upgrade = (request.headers.value('upgrade') ?? '')
          .toLowerCase();
      seen.add(_Seen(List<String>.of(values), names, upgrade));
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
      } else {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      }
      for (final Completer<void> waiting in _arrivals) {
        if (!waiting.isCompleted) {
          waiting.complete();
        }
      }
      _arrivals.clear();
    }
  }

  /// Completes once [count] requests have been seen and answered.
  Future<void> untilSeen(int count) async {
    while (seen.length < count || sockets.length < count) {
      final Completer<void> next = Completer<void>();
      _arrivals.add(next);
      await next.future.timeout(_wait);
    }
  }

  Future<void> stop() async {
    for (final WebSocket socket in sockets) {
      await socket.close().timeout(_wait, onTimeout: () {});
    }
    await _server.close(force: true);
  }
}

/// Connects once with [clientBuild] and returns what the server saw.
Future<_Seen> _connectOnce(
  String id,
  int? clientBuild, {
  required void Function(_Recorder recorder, WireTransport transport) during,
}) async {
  final _Recorder recorder = await _Recorder.start();
  WireTransport? transport;
  try {
    final WireTransport link = await connectWsTransport(
      recorder.url,
      clientBuild: clientBuild,
    ).timeout(_wait);
    transport = link;
    await recorder.untilSeen(1);
    during(recorder, link);
    return recorder.seen.single;
  } finally {
    await transport?.close();
    await recorder.stop();
  }
}

void main() {
  // ------------------------------------------------------------------ H1
  for (final ({String name, int build, String wire}) row
      in <({String name, int build, String wire})>[
        (name: 'the build the contract names', build: 561, wire: '561'),
        (name: 'the smallest build, 1', build: 1, wire: '1'),
        (name: 'a two digit build', build: 42, wire: '42'),
        (name: 'a seven digit build', build: 1234567, wire: '1234567'),
        (
          name: 'the largest nine digit build',
          build: 999999999,
          wire: '999999999',
        ),
      ]) {
    test('H1: ${row.name} (${row.build}) is sent as the decimal '
        '"${row.wire}", once', () async {
      final String id = 'H1 ${row.build}';
      final _Seen seen = await _connectOnce(id, row.build, during: (_, _) {});
      expect(
        seen.values,
        <String>[row.wire],
        reason:
            '$id: expected exactly one Ludo-Client-Build header with the '
            'value "${row.wire}" (decimal, no padding, no sign); the server '
            'saw ${seen.brief}. ${_reproduce(id)}',
      );
      expect(
        seen.upgrade,
        'websocket',
        reason:
            '$id: fixture: the request the header rode on must be the '
            'WebSocket upgrade; saw ${seen.brief}. ${_reproduce(id)}',
      );
    });
  }

  // ------------------------------------------------------------------ H2
  for (final ({String name, int? build}) row in <({String name, int? build})>[
    (name: 'null (the build could not be read)', build: null),
    (name: 'zero', build: 0),
    (name: 'minus one', build: -1),
    (name: 'minus three', build: -3),
    (name: 'a large negative', build: -999999999),
  ]) {
    test('H2: ${row.name} sends no Ludo-Client-Build header', () async {
      final String id = 'H2 ${row.build}';
      final _Seen seen = await _connectOnce(id, row.build, during: (_, _) {});
      expect(
        seen.values,
        isEmpty,
        reason:
            '$id: expected no Ludo-Client-Build header for a build of '
            '${row.build}; the server saw ${seen.brief}. ${_reproduce(id)}',
      );
      expect(
        seen.allNames.where((String n) => n.contains('build')),
        isEmpty,
        reason:
            '$id: expected no header with "build" in its name under any '
            'spelling; the server saw ${seen.brief}. ${_reproduce(id)}',
      );
    });
  }

  test('H2: omitting the argument sends no header, as every existing call '
      'site does', () async {
    const String id = 'H2 omitted';
    final _Recorder recorder = await _Recorder.start();
    WireTransport? transport;
    try {
      transport = await connectWsTransport(recorder.url).timeout(_wait);
      await recorder.untilSeen(1);
      expect(
        recorder.seen.single.values,
        isEmpty,
        reason:
            '$id: expected no Ludo-Client-Build header when clientBuild is '
            'not passed; the server saw ${recorder.seen.single.brief}. '
            '${_reproduce(id)}',
      );
    } finally {
      await transport?.close();
      await recorder.stop();
    }
  });

  // ------------------------------------------------------------------ H3
  test('H3: with the header present the link still carries text both ways '
      'and closes', () async {
    const String id = 'H3';
    final _Recorder recorder = await _Recorder.start();
    WireTransport? transport;
    try {
      final WireTransport link = await connectWsTransport(
        recorder.url,
        clientBuild: 561,
      ).timeout(_wait);
      transport = link;
      await recorder.untilSeen(1);
      final WebSocket server = recorder.sockets.single;

      final Future<String> inbound = link.incoming.first.timeout(_wait);
      server.add('hello from the server');
      expect(
        await inbound,
        'hello from the server',
        reason:
            '$id: expected the server text to reach the transport; '
            '${_reproduce(id)}',
      );

      final Future<Object?> atServer = server.first.timeout(_wait);
      link.send('hello from the app');
      expect(
        await atServer,
        'hello from the app',
        reason:
            '$id: expected the app text to reach the server; '
            '${_reproduce(id)}',
      );

      final Future<void> gone = link.done.timeout(_wait);
      await server.close(4005, 'update');
      await gone;
    } finally {
      await transport?.close();
      await recorder.stop();
    }
  });

  // ------------------------------------------------------------------ H4
  test('H4: two connects, each request carries the build its own call was '
      'given', () async {
    const String id = 'H4';
    final _Recorder recorder = await _Recorder.start();
    final List<WireTransport> opened = <WireTransport>[];
    try {
      opened.add(
        await connectWsTransport(recorder.url, clientBuild: 561).timeout(_wait),
      );
      opened.add(await connectWsTransport(recorder.url).timeout(_wait));
      opened.add(
        await connectWsTransport(recorder.url, clientBuild: 600).timeout(_wait),
      );
      await recorder.untilSeen(3);
      expect(
        <List<String>>[for (final _Seen s in recorder.seen) s.values],
        <List<String>>[
          <String>['561'],
          <String>[],
          <String>['600'],
        ],
        reason:
            '$id: expected the header on the first and third request only, '
            'with each call\'s own value (no value leaking from one connect '
            'to the next); the server saw '
            '${<String>[for (final _Seen s in recorder.seen) s.brief]}. '
            '${_reproduce(id)}',
      );
    } finally {
      for (final WireTransport transport in opened) {
        await transport.close();
      }
      await recorder.stop();
    }
  });
}
