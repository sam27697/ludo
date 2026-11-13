// Pins `docs/PROTOCOL.md` section 27 (an app too old for the server is told
// to update), every server bullet of rule 9, plus the rules 2 to 5 and 8 the
// bullets lean on.
//
// Written from the section text and the names work order 634 pins
// (`clientBuildHeader`, `parseClientBuildHeader`, `parseMinClientBuild`,
// `WireServer(minClientBuild:)`, `ProtocolError.updateRequired`,
// `closeCodeUpdateRequired`), not from a reading of any implementation.
//
// Every wire case opens a real `dart:io` WebSocket against a real, running
// `WireServer` with the `Ludo-Client-Build` header on the upgrade request, so
// the header travels over a real HTTP upgrade. The two cases at the bottom
// start `bin/server.dart` itself as a child process, because the start-up
// refusal of a bad `MIN_CLIENT_BUILD` (rule 3) lives only there.
//
// Reproducing a failure: nothing here is random. Each failure message names
// the scenario (the test's own label, the minimum the server ran with and
// the header the socket sent). Re-run the one test with
// `dart test test/c634_client_build_test.dart -n '<test name>'`.
//
// Log lines are read by running the whole scenario, server included, inside a
// `Zone` whose `print` is captured, the same idiom `turn_expiry_log_test.dart`
// uses.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ludo_server/ludo_server.dart';
import 'package:ludo_server/src/connection.dart' show closeCodeUpdateRequired;
import 'package:stream_channel/stream_channel.dart' show StreamChannelMixin;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The header as the app spells it on the wire (rule 1). Deliberately a
/// literal here, and not `clientBuildHeader`, so the wire cases do not
/// depend on the constant the parse cases check.
const String _header = 'Ludo-Client-Build';

/// How long any single wait on a real socket may take before the case is
/// called failed. A liveness bound on a condition, never a pause.
const Duration _bound = Duration(seconds: 5);

// ---------------------------------------------------------------------------
// Rule 2: reading the header.
// ---------------------------------------------------------------------------

/// One row of the rule 2 table: a header value (null is "no header at all")
/// and the build it must read as.
class _HeaderRow {
  const _HeaderRow(this.label, this.value, this.build);

  final String label;
  final String? value;
  final int build;
}

/// The twelve rows rule 9 names, in the order it names them.
const List<_HeaderRow> _ruleNineHeaderRows = <_HeaderRow>[
  _HeaderRow('absent', null, 0),
  _HeaderRow('empty', '', 0),
  _HeaderRow('"0"', '0', 0),
  _HeaderRow('"1"', '1', 1),
  _HeaderRow('"0007" (leading zeros allowed)', '0007', 7),
  _HeaderRow('" 42 " (surrounding whitespace trimmed)', ' 42 ', 42),
  _HeaderRow('"999999999" (nine digits)', '999999999', 999999999),
  _HeaderRow('"1000000000" (ten digits)', '1000000000', 0),
  _HeaderRow('"-5" (a sign)', '-5', 0),
  _HeaderRow('"4.2" (a decimal point)', '4.2', 0),
  _HeaderRow('"12,13" (comma-joined values)', '12,13', 0),
  _HeaderRow('"abc"', 'abc', 0),
];

/// Rows the rule 2 sentence implies but the rule 9 list does not name.
const List<_HeaderRow> _impliedHeaderRows = <_HeaderRow>[
  _HeaderRow('"+5" (a plus sign)', '+5', 0),
  _HeaderRow('"000000000" (nine digits, value 0)', '000000000', 0),
  _HeaderRow('"00000001" (eight digits with leading zeros)', '00000001', 1),
  _HeaderRow('"000000007" (nine digits with leading zeros)', '000000007', 7),
  _HeaderRow(
    '"0000000007" (ten digits even though the value is small)',
    '0000000007',
    0,
  ),
  _HeaderRow('"4294967296" (ten digits, past 32 bits)', '4294967296', 0),
  _HeaderRow('whitespace only', '   ', 0),
  _HeaderRow('tab-padded value', '\t7\t', 7),
  _HeaderRow('"7 8" (inner whitespace)', '7 8', 0),
  _HeaderRow('"0x10"', '0x10', 0),
  _HeaderRow('"1e3"', '1e3', 0),
  _HeaderRow('"12,"', '12,', 0),
  _HeaderRow('"12, 13"', '12, 13', 0),
  _HeaderRow('Arabic-Indic digits (not ASCII)', '٥٦', 0),
  _HeaderRow('fullwidth digits (not ASCII)', '５６', 0),
  _HeaderRow('"560" is read as itself', '560', 560),
];

// ---------------------------------------------------------------------------
// A small real-socket client and a server fixture.
// ---------------------------------------------------------------------------

/// A WebSocket client that keeps every frame it ever received, hands them out
/// in arrival order through [next], and reports how and when it closed.
class _Client {
  _Client._(this.label, this.socket) {
    socket.listen(
      _onData,
      onDone: () {
        if (!_done.isCompleted) {
          _done.complete();
        }
        _wakeAll();
      },
      onError: (Object error, StackTrace stack) {
        if (!_done.isCompleted) {
          _done.complete();
        }
        _wakeAll();
      },
    );
  }

  /// What a failure message calls this socket: its header, as sent.
  final String label;
  final WebSocket socket;

  /// Every decoded frame this socket has received, consumed or not.
  final List<Map<String, Object?>> all = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _unread = <Map<String, Object?>>[];
  final List<Completer<void>> _waiters = <Completer<void>>[];
  final Completer<void> _done = Completer<void>();
  int _ids = 0;

  void _onData(Object? raw) {
    Map<String, Object?> frame;
    try {
      frame = jsonDecode(raw! as String) as Map<String, Object?>;
    } on Object {
      frame = <String, Object?>{'_undecodable': '$raw'};
    }
    all.add(frame);
    _unread.add(frame);
    _wakeAll();
  }

  void _wakeAll() {
    final List<Completer<void>> waiting = List<Completer<void>>.of(_waiters);
    _waiters.clear();
    for (final Completer<void> w in waiting) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
  }

  bool get isDone => _done.isCompleted;

  /// Sends one well-formed envelope and returns the id it carried.
  String send(String type, Map<String, Object?> data) {
    final String id = 'c634-msg-${++_ids}-$label'
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .padRight(8, '_');
    socket.add(
      jsonEncode(<String, Object?>{'v': 1, 't': type, 'id': id, 'd': data}),
    );
    return id;
  }

  /// The next unread frame, or a failure naming [what] when none arrives
  /// within [_bound] or the socket closes first.
  Future<Map<String, Object?>> next(String what) async {
    final DateTime deadline = DateTime.now().add(_bound);
    while (_unread.isEmpty) {
      if (_done.isCompleted) {
        throw TestFailure(
          'expected $what on socket "$label" but it closed first with code '
          '${socket.closeCode}; frames it did receive: $all',
        );
      }
      final Duration left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TestFailure(
          'expected $what on socket "$label" within $_bound and none '
          'arrived; frames it did receive: $all',
        );
      }
      final Completer<void> waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future.timeout(left, onTimeout: () {});
    }
    return _unread.removeAt(0);
  }

  /// Reads frames until one of type [type] arrives, returning it. Any frame
  /// of an unlisted type (a `seat_assigned` ahead of its `room`) is skipped.
  Future<Map<String, Object?>> nextOfType(
    Set<String> types,
    String what,
  ) async {
    while (true) {
      final Map<String, Object?> frame = await next(what);
      if (types.contains(frame['t'])) {
        return frame;
      }
    }
  }

  /// Waits until the socket has closed and returns its close code. Fails
  /// after [_bound].
  Future<int?> closed() async {
    try {
      await _done.future.timeout(_bound);
    } on TimeoutException {
      throw TestFailure(
        'expected socket "$label" to be closed by the server within $_bound '
        'and it was still open; frames received: $all',
      );
    }
    return socket.closeCode;
  }

  Future<void> dispose() async {
    if (socket.readyState == WebSocket.open) {
      await socket.close();
    }
  }
}

/// What a successful create or join yields.
class _Seated {
  _Seated(this.code, this.seat, this.token);

  final String code;
  final int seat;
  final String token;
}

/// One running server for one scenario, with its print output captured.
class _Fixture {
  _Fixture(this.scenario, {this.minClientBuild}) {
    clock = FakeClock(DateTime.utc(2026, 11, 13));
    registry = RoomRegistry(clock: clock, secure: Random.secure());
    rateLimiter = RateLimiter(clock: clock);
    final int? min = minClientBuild;
    server = min == null
        ? WireServer(
            registry: registry,
            rateLimiter: rateLimiter,
            clock: clock,
            automaticTurnExpiry: false,
          )
        : WireServer(
            registry: registry,
            rateLimiter: rateLimiter,
            clock: clock,
            automaticTurnExpiry: false,
            minClientBuild: min,
          );
  }

  final String scenario;
  final int? minClientBuild;
  late final FakeClock clock;
  late final RoomRegistry registry;
  late final RateLimiter rateLimiter;
  late final WireServer server;
  final List<_Client> clients = <_Client>[];

  /// Every line the scenario printed, server included.
  final List<String> lines = <String>[];

  Future<void> start() =>
      server.start(address: InternetAddress.loopbackIPv4, port: 0);

  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Uri httpUri(String path) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);

  /// Dials the server with [build] as the `Ludo-Client-Build` header, or with
  /// no such header when [build] is null. [extra] adds further headers.
  Future<_Client> dial(String? build, {Map<String, String>? extra}) async {
    final Map<String, String> headers = <String, String>{
      if (build != null) _header: build,
      ...?extra,
    };
    final WebSocket socket = await WebSocket.connect(
      wsUri.toString(),
      headers: headers,
    ).timeout(_bound);
    final _Client client = _Client._(
      build == null ? 'no-header' : 'build=$build',
      socket,
    );
    clients.add(client);
    return client;
  }

  /// Dials with [headerLines] sent exactly as given, one header line each,
  /// names in the case written (a second line of the same name stays a
  /// second line). `WebSocket.connect` lower-cases names and cannot repeat
  /// one, so this does the upgrade by hand.
  Future<_Client> dialRaw(
    List<MapEntry<String, String>> headerLines,
    String label,
  ) async {
    final HttpClient http = HttpClient();
    final HttpClientRequest request = await http
        .getUrl(Uri(scheme: 'http', host: '127.0.0.1', port: server.port))
        .timeout(_bound);
    request.headers
      ..set('Connection', 'Upgrade')
      ..set('Upgrade', 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set(
        'Sec-WebSocket-Key',
        base64Encode(Uint8List.fromList(List<int>.generate(16, (int i) => i))),
      );
    for (final MapEntry<String, String> line in headerLines) {
      request.headers.add(line.key, line.value, preserveHeaderCase: true);
    }
    final HttpClientResponse response = await request.close().timeout(_bound);
    if (response.statusCode != 101) {
      fail(
        'expected the upgrade ($label) to be accepted with 101 and got '
        '${response.statusCode}',
      );
    }
    final Socket raw = await response.detachSocket();
    http.close();
    final _Client client = _Client._(
      label,
      WebSocket.fromUpgradedSocket(raw, serverSide: false),
    );
    clients.add(client);
    return client;
  }

  /// The `connect build=` lines captured so far, in order.
  List<String> get connectLines => lines
      .where((String l) => l.trimRight().startsWith('connect build='))
      .toList();

  String get _context => 'scenario="$scenario", server minClientBuild='
      '${minClientBuild ?? 'default'}, captured print lines: $lines';

  /// Fails with [message] plus the scenario and the captured lines.
  Never fail(String message) => throw TestFailure('$message ($_context)');

  Future<void> close() async {
    for (final _Client c in clients) {
      await c.dispose();
    }
    await server.close();
  }
}

/// Runs [body] against a fresh [_Fixture] started inside a `Zone` that
/// captures every `print`, so lines the server prints while handling a
/// socket land in `fixture.lines`. Always closes the server.
Future<void> _scenario(
  String scenario,
  int? minClientBuild,
  Future<void> Function(_Fixture f) body,
) async {
  late _Fixture fixture;
  Object? failure;
  StackTrace? failureStack;
  await runZoned(
    () async {
      fixture = _Fixture(scenario, minClientBuild: minClientBuild);
      await fixture.start();
      try {
        await body(fixture);
      } on Object catch (error, stack) {
        failure = error;
        failureStack = stack;
      } finally {
        await fixture.close();
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        fixture.lines.add(line);
      },
    ),
  );
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
}

/// Sends `create_room` on [c] and reads until the answer. Returns the seat
/// the host took. Fails when the answer is an error.
Future<_Seated> _create(_Fixture f, _Client c, {int players = 2}) async {
  c.send('create_room', <String, Object?>{'name': 'Host', 'players': players});
  return _readSeated(f, c, 'the room answering create_room');
}

Future<_Seated> _join(_Fixture f, _Client c, String code) async {
  c.send('join_room', <String, Object?>{'code': code, 'name': 'Guest'});
  return _readSeated(f, c, 'the room answering join_room');
}

Future<_Seated> _resume(
  _Fixture f,
  _Client c,
  String code,
  String token,
) async {
  c.send('resume', <String, Object?>{'code': code, 'seat_token': token});
  return _readSeated(f, c, 'the room answering resume');
}

/// Reads `seat_assigned` then `room` (section 5), or fails on an `error`.
Future<_Seated> _readSeated(_Fixture f, _Client c, String what) async {
  int? seat;
  String? token;
  while (true) {
    final Map<String, Object?> frame = await c.nextOfType(<String>{
      'seat_assigned',
      'room',
      'error',
    }, what);
    final Map<String, Object?> d = frame['d']! as Map<String, Object?>;
    switch (frame['t']) {
      case 'seat_assigned':
        seat = d['seat']! as int;
        token = d['seat_token']! as String;
      case 'room':
        if (seat == null || token == null) {
          f.fail(
            'expected seat_assigned before $what on socket "${c.label}" '
            'and got the room first: $frame',
          );
        }
        return _Seated(d['code']! as String, seat, token);
      default:
        f.fail(
          'expected $what on socket "${c.label}" and got an error '
          'instead: $frame',
        );
    }
  }
}

/// The single `UPDATE_REQUIRED` check every refusal case shares: exactly one
/// frame, shaped as rule 4 says, then close code 4005.
Future<void> _expectRefused(_Fixture f, _Client c, {required int min}) async {
  final int? code = await c.closed();
  expect(
    c.all,
    hasLength(1),
    reason: 'rule 4: a refused socket gets exactly one frame. Socket '
        '"${c.label}" got ${c.all.length}: ${c.all}. ${f._context}',
  );
  final Map<String, Object?> frame = c.all.single;
  expect(
    frame.keys.toSet(),
    <String>{'v', 't', 'id', 'd'},
    reason: 'rule 4: the frame carries v, t, id, d and no re. Got $frame. '
        '${f._context}',
  );
  expect(frame['v'], 1, reason: 'envelope v. Got $frame. ${f._context}');
  expect(frame['t'], 'error', reason: 'frame type. Got $frame. ${f._context}');
  expect(
    frame['id'],
    isA<String>().having(isWellFormedMessageId, 'is a well-formed id', isTrue),
    reason: 'the server id must be a well-formed message id. Got $frame. '
        '${f._context}',
  );
  final Object? d = frame['d'];
  expect(
    d,
    isA<Map<String, Object?>>(),
    reason: 'd must be an object. Got $frame. ${f._context}',
  );
  final Map<String, Object?> data = d! as Map<String, Object?>;
  expect(
      data.keys.toSet(),
      <String>{
        'code',
        'message',
        'min_build',
      },
      reason:
          'rule 4: d is code, message, min_build. Got $data. ${f._context}');
  expect(
    data['code'],
    'UPDATE_REQUIRED',
    reason: 'error code. Got $data. ${f._context}',
  );
  expect(
    data['min_build'],
    min,
    reason: 'min_build must be the server minimum $min as a JSON integer. '
        'Got $data. ${f._context}',
  );
  expect(
    data['message'],
    isA<String>().having((String s) => s.isNotEmpty, 'non-empty', isTrue),
    reason: 'message is a text. Got $data. ${f._context}',
  );
  expect(
    code,
    4005,
    reason: 'rule 4 and section 7.1: close code 4005 after the frame. Socket '
        '"${c.label}" closed with $code. ${f._context}',
  );
}

/// Polls [condition] until it holds or [_bound] passes. A condition wait,
/// not a fixed pause.
Future<void> _until(bool Function() condition, String what, _Fixture f) async {
  final DateTime deadline = DateTime.now().add(_bound);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      f.fail('expected $what within $_bound and it never held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

// ---------------------------------------------------------------------------
// Running bin/server.dart as a child process.
// ---------------------------------------------------------------------------

/// The package directory `bin/server.dart` lives in, resolved from the
/// package URI so it is the same whether `dart test` runs here or from the
/// repository root, as `bin/ludo-verify.sh` and CI run it.
Future<Directory> _packageRoot() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (libUri == null) {
    throw TestFailure(
      'could not resolve package:ludo_server/ludo_server.dart to a file URI; '
      'cannot locate bin/server.dart',
    );
  }
  final Directory dir = File.fromUri(libUri).parent.parent;
  if (!File('${dir.path}/bin/server.dart').existsSync()) {
    throw TestFailure('no bin/server.dart under ${dir.path}');
  }
  return dir;
}

/// An environment with only what `dart run` needs plus [extra]. The parent
/// environment is never inherited, so no CTL_ variable or LUDO_ setting of
/// the machine running the suite reaches the child.
Map<String, String> _childEnvironment(Map<String, String> extra) {
  final Map<String, String> parent = Platform.environment;
  return <String, String>{
    for (final String key in <String>[
      'PATH',
      'HOME',
      'PUB_CACHE',
      'TMPDIR',
      'XDG_CONFIG_HOME',
      'XDG_CACHE_HOME',
    ])
      if (parent[key] != null) key: parent[key]!,
    ...extra,
  };
}

/// A TCP port nothing is listening on right now.
Future<int> _freePort() async {
  final ServerSocket probe = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = probe.port;
  await probe.close();
  return port;
}

Future<bool> _isListening(int port) async {
  try {
    final Socket s = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 1),
    );
    s.destroy();
    return true;
  } on SocketException {
    return false;
  } on TimeoutException {
    return false;
  }
}

// ---------------------------------------------------------------------------
// An in-memory socket for driving one Connection directly, with no network.
// ---------------------------------------------------------------------------

/// The sending half of [_MemoryChannel]: records every text frame written and
/// every close, in order.
class _MemorySink implements WebSocketSink {
  final List<Object?> sent = <Object?>[];
  final List<({int? code, String? reason})> closes =
      <({int? code, String? reason})>[];
  final Completer<void> _done = Completer<void>();

  @override
  void add(Object? data) => sent.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closes.add((code: closeCode, reason: closeReason));
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;
}

/// A [WebSocketChannel] whose peer is the test: nothing crosses a network, so
/// the order frames reach `Connection.handleFrame` is exactly the order the
/// test calls it in.
class _MemoryChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  final _MemorySink _sink = _MemorySink();
  final StreamController<Object?> _inbound = StreamController<Object?>();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream => _inbound.stream;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => _sink.closes.isEmpty ? null : _sink.closes.last.code;

  @override
  String? get closeReason =>
      _sink.closes.isEmpty ? null : _sink.closes.last.reason;

  @override
  Future<void> get ready => Future<void>.value();

  /// Every frame the server side wrote, decoded.
  List<Map<String, Object?>> get received => _sink.sent
      .map((Object? raw) => jsonDecode(raw! as String) as Map<String, Object?>)
      .toList();
}

/// A hub that remembers every call and delivers nothing, so a frame that
/// reaches a handler shows up as an attach or a broadcast.
class _RecordingHub implements RoomHub {
  final List<String> calls = <String>[];

  @override
  Connection? attach({required String code, required Connection conn}) {
    calls.add('attach $code');
    return null;
  }

  @override
  void detach(Connection conn) => calls.add('detach');

  @override
  void broadcast({
    required String code,
    required String type,
    required Map<String, Object?> data,
    Connection? exceptConn,
  }) =>
      calls.add('broadcast $code $type');

  @override
  void sendToSeatToken({
    required String code,
    required String seatToken,
    required String type,
    required Map<String, Object?> data,
  }) =>
      calls.add('sendToSeatToken $code $type');

  @override
  Connection? detachSeatToken({
    required String code,
    required String seatToken,
  }) {
    calls.add('detachSeatToken $code');
    return null;
  }
}

/// Everything one in-memory scenario shares, built the way the socket layer
/// builds a connection: one registry, one rate limiter, one hub, one
/// connection. The random source is seeded, so a failure names a seed that
/// reproduces it.
class _Bench {
  _Bench(this.scenario, {required int clientBuild}) {
    clock = FakeClock(DateTime.utc(2026, 11, 13));
    registry = RoomRegistry(clock: clock, secure: Random(seed));
    rateLimiter = RateLimiter(clock: clock);
    conn = Connection(
      channel: channel,
      ip: ip,
      registry: registry,
      rateLimiter: rateLimiter,
      clock: clock,
      hub: hub,
      random: Random(seed),
      clientBuild: clientBuild,
    );
  }

  static const int seed = 634;
  static const String ip = '203.0.113.34';

  final String scenario;
  final _MemoryChannel channel = _MemoryChannel();
  final _RecordingHub hub = _RecordingHub();
  late final FakeClock clock;
  late final RoomRegistry registry;
  late final RateLimiter rateLimiter;
  late final Connection conn;
  int _ids = 0;

  String get context => 'scenario="$scenario", seed=$seed, ip=$ip, '
      'frames received by the peer: ${channel.received}, hub calls: '
      '${hub.calls}, rooms: ${registry.roomCount}';

  /// A well-formed envelope as the text the wire carries.
  String frame(String type, Map<String, Object?> data) => jsonEncode(
        <String, Object?>{
          'v': 1,
          't': type,
          'id': 'c634-unit-${(++_ids).toString().padLeft(4, '0')}',
          'd': data,
        },
      );

  /// A room that exists before the connection under test does anything,
  /// hosted by somebody else.
  CreateOk liveRoom() {
    final CreateResult result = registry.createRoom(
      name: 'Host',
      players: 2,
      rules: const RulesConfig(),
    );
    if (result is! CreateOk) {
      throw TestFailure('the live room could not be made: $result ($context)');
    }
    return result;
  }
}

/// Runs [body] with `print` captured and returns the lines it printed.
Future<List<String>> _captureLines(Future<void> Function() body) async {
  final List<String> lines = <String>[];
  Object? failure;
  StackTrace? failureStack;
  await runZoned(
    () async {
      try {
        await body();
      } on Object catch (error, stack) {
        failure = error;
        failureStack = stack;
      }
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        lines.add(line);
      },
    ),
  );
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
  return lines;
}

void main() {
  group('names the work order pins', () {
    test('N1: the header constant is the lower-case rule 1 name', () {
      expect(clientBuildHeader, 'ludo-client-build');
    });

    test('N2: ProtocolError.updateRequired is UPDATE_REQUIRED on the wire', () {
      expect(wireErrorCode(ProtocolError.updateRequired), 'UPDATE_REQUIRED');
    });

    test('N3: closeCodeUpdateRequired is 4005 (section 7.1)', () {
      expect(closeCodeUpdateRequired, 4005);
    });

    test('N4: a negative minClientBuild is refused at construction', () {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 13));
      expect(
        () => WireServer(
          registry: RoomRegistry(clock: clock, secure: Random.secure()),
          rateLimiter: RateLimiter(clock: clock),
          clock: clock,
          automaticTurnExpiry: false,
          minClientBuild: -1,
        ),
        anyOf(throwsArgumentError, throwsA(isA<AssertionError>())),
        reason: 'work order 634: a negative minimum asserts or throws '
            'ArgumentError',
      );
    });
  });

  group('rule 2: parseClientBuildHeader', () {
    for (final _HeaderRow row in <_HeaderRow>[
      ..._ruleNineHeaderRows,
      ..._impliedHeaderRows,
    ]) {
      test('P: ${row.label} reads as build ${row.build}', () {
        expect(
          parseClientBuildHeader(row.value),
          row.build,
          reason: 'rule 2 table: header value ${jsonEncode(row.value)} must '
              'read as build ${row.build}',
        );
      });
    }

    test('P: a very long value, and one with a NUL, never throw', () {
      expect(parseClientBuildHeader('9' * 10000), 0);
      expect(parseClientBuildHeader('1' * 4096 + ' '), 0);
      expect(parseClientBuildHeader('5\u0000'), 0);
      expect(parseClientBuildHeader('\u0000'), 0);
    });
  });

  group('rule 3: parseMinClientBuild', () {
    const Map<String?, int> accepted = <String?, int>{
      null: 0,
      '': 0,
      '0': 0,
      '560': 560,
      '0007': 7,
      '999999999': 999999999,
      ' 560 ': 560,
    };
    accepted.forEach((String? raw, int minimum) {
      test('Q: ${jsonEncode(raw)} is accepted as $minimum', () {
        expect(
          parseMinClientBuild(raw),
          minimum,
          reason: 'rule 3: MIN_CLIENT_BUILD=${jsonEncode(raw)} means '
              '$minimum (absent and empty mean 0)',
        );
      });
    });

    const List<String> refused = <String>[
      'abc',
      '-1',
      '5.5',
      '+5',
      '1000000000',
      '12,13',
      '0x10',
      '1e3',
      '5 6',
      '٥٦',
    ];
    for (final String raw in refused) {
      test('Q: ${jsonEncode(raw)} is refused with a FormatException', () {
        expect(
          () => parseMinClientBuild(raw),
          throwsFormatException,
          reason: 'rule 3: a MIN_CLIENT_BUILD that is present and not '
              '[0-9]{1,9} after trimming stops the server at start, so the '
              'parse must throw FormatException for ${jsonEncode(raw)}',
        );
      });
    }
  });

  group('rule 9: minimum 0 turns the check off', () {
    test('Z1: a socket with no header creates a room as today', () async {
      await _scenario('Z1 minimum 0, no header, create_room', 0, (
        _Fixture f,
      ) async {
        final _Client c = await f.dial(null);
        final _Seated seated = await _create(f, c);
        expect(seated.seat, 0, reason: 'the host takes the first seat');
        expect(
          f.registry.roomCount,
          1,
          reason: 'the room must exist. ${f._context}',
        );
      });
    });

    test('Z2: no minClientBuild argument at all behaves as 0', () async {
      await _scenario('Z2 default constructor, no header, create_room', null, (
        _Fixture f,
      ) async {
        final _Client c = await f.dial(null);
        await _create(f, c);
        expect(f.registry.roomCount, 1, reason: f._context);
      });
    });

    test(
      'Z3: any header, junk included, is let through at minimum 0',
      () async {
        await _scenario('Z3 minimum 0, headers 0 / abc / 1 / 999999999', 0, (
          _Fixture f,
        ) async {
          for (final String value in <String>['0', 'abc', '1', '999999999']) {
            final _Client c = await f.dial(value);
            await _create(f, c);
          }
          expect(f.registry.roomCount, 4, reason: f._context);
        });
      },
    );

    test(
      'Z4: minimum 0 logs the build of each socket and never a refusal',
      () async {
        await _scenario('Z4 minimum 0, no header then 7 then abc', 0, (
          _Fixture f,
        ) async {
          await _create(f, await f.dial(null));
          await _create(f, await f.dial('7'));
          await _create(f, await f.dial('abc'));
          expect(
            f.connectLines.map((String l) => l.trim()).toList(),
            <String>['connect build=0', 'connect build=7', 'connect build=0'],
            reason: 'rule 5: one "connect build=<n>" line per accepted socket, '
                'in order, junk header reading as 0. ${f._context}',
          );
          expect(
            f.lines.where((String l) => l.contains('UPDATE_REQUIRED')),
            isEmpty,
            reason: 'minimum 0 never refuses. ${f._context}',
          );
        });
      },
    );
  });

  group('rule 9: minimum N, sockets at or above N play as today', () {
    const int n = 560;

    test('Y1: build N and build N+1 create and join a room', () async {
      await _scenario('Y1 minimum $n, headers $n and ${n + 1}', n, (
        _Fixture f,
      ) async {
        final _Client host = await f.dial('$n');
        final _Seated hosted = await _create(f, host);
        final _Client guest = await f.dial('${n + 1}');
        final _Seated joined = await _join(f, guest, hosted.code);
        expect(joined.code, hosted.code, reason: f._context);
        expect(joined.seat, isNot(hosted.seat),
            reason: 'the guest takes a seat of its own. ${f._context}');
        expect(
          host.isDone,
          isFalse,
          reason: 'the host socket must stay open. ${f._context}',
        );
        expect(
          guest.isDone,
          isFalse,
          reason: 'the guest socket must stay open. ${f._context}',
        );
      });
    });

    test('Y2: resume works for build N and for a build above N', () async {
      await _scenario('Y2 minimum $n, resume at $n and ${n + 7}', n, (
        _Fixture f,
      ) async {
        final _Client first = await f.dial('$n');
        final _Seated seated = await _create(f, first);
        await first.dispose();
        await first.closed();

        final _Client again = await f.dial('${n + 7}');
        final _Seated resumed = await _resume(
          f,
          again,
          seated.code,
          seated.token,
        );
        expect(resumed.seat, seated.seat, reason: f._context);
        expect(resumed.token, seated.token, reason: f._context);
      });
    });

    test('Y3: header case does not matter and zeros are allowed', () async {
      await _scenario('Y3 minimum $n, headers LUDO-CLIENT-BUILD: 00560', n, (
        _Fixture f,
      ) async {
        final _Client c = await f.dialRaw(<MapEntry<String, String>>[
          const MapEntry<String, String>('LUDO-CLIENT-BUILD', '00560'),
        ], 'LUDO-CLIENT-BUILD: 00560');
        await _create(f, c);
        expect(
            f.connectLines.map((String l) => l.trim()).toList(),
            <String>[
              'connect build=560',
            ],
            reason: f._context);
      });
    });

    test(
      'Y4: a minimum of 1 admits build 1 and refuses a missing header',
      () async {
        await _scenario('Y4 minimum 1, header 1 and no header', 1, (
          _Fixture f,
        ) async {
          await _create(f, await f.dial('1'));
          final _Client refused = await f.dial(null);
          await _expectRefused(f, refused, min: 1);
        });
      },
    );

    test('Y5: a minimum of 999999999 splits at its own boundary', () async {
      await _scenario(
        'Y5 minimum 999999999, headers 999999999 / 999999998',
        999999999,
        (_Fixture f) async {
          await _create(f, await f.dial('999999999'));
          final _Client refused = await f.dial('999999998');
          await _expectRefused(f, refused, min: 999999999);
        },
      );
    });
  });

  group('rule 9: minimum N, sockets below N are told to update', () {
    const int n = 560;

    /// Header values, and why each reads as below 560.
    const Map<String, String?> belowMinimum = <String, String?>{
      'no header': null,
      'build N-1': '559',
      'build 1': '1',
      'build 0': '0',
      'empty header': '',
      'junk header': 'abc',
      'signed header that looks big': '-5600',
      'plus-signed header that looks big': '+560',
      'comma-joined values that look big': '560,561',
      'ten digits that look big': '1000000000',
      'decimal that looks big': '560.0',
    };
    belowMinimum.forEach((String why, String? value) {
      test(
          'X1: $why gets one UPDATE_REQUIRED frame then close 4005 and a '
          'create_room sent at once creates nothing', () async {
        await _scenario(
          'X1 minimum $n, header ${jsonEncode(value)} ($why), create_room '
          'sent straight after the upgrade',
          n,
          (_Fixture f) async {
            final _Client c = await f.dial(value);
            c.send('create_room', <String, Object?>{
              'name': 'Late',
              'players': 2,
            });
            await _expectRefused(f, c, min: n);
            expect(
              f.registry.roomCount,
              0,
              reason: 'rule 4: a create_room on a refused socket creates no '
                  'room. ${f._context}',
            );
          },
        );
      });
    });

    test(
      'X2: the frame arrives although the client never sent anything',
      () async {
        await _scenario('X2 minimum $n, no header, client silent', n, (
          _Fixture f,
        ) async {
          final _Client c = await f.dial(null);
          final Map<String, Object?> frame = await c.next('the refusal frame');
          expect(
            (frame['d']! as Map<String, Object?>)['code'],
            'UPDATE_REQUIRED',
            reason: 'rule 4: the frame is sent before any inbound frame is '
                'read. Got $frame. ${f._context}',
          );
          await _expectRefused(f, c, min: n);
        });
      },
    );

    test('X3: min_build is the server minimum, not the socket build', () async {
      await _scenario('X3 minimum 777, header 5', 777, (_Fixture f) async {
        final _Client c = await f.dial('5');
        await _expectRefused(f, c, min: 777);
      });
    });

    test(
      'X4: a refused socket gets no answer to join_room or resume either',
      () async {
        await _scenario(
          'X4 minimum $n, refused socket sends join_room and '
          'resume with a live room code and token',
          n,
          (_Fixture f) async {
            final _Client host = await f.dial('$n');
            final _Seated hosted = await _create(f, host);
            final _Client refused = await f.dial('${n - 1}');
            refused.send('join_room', <String, Object?>{
              'code': hosted.code,
              'name': 'Sneak',
            });
            refused.send('resume', <String, Object?>{
              'code': hosted.code,
              'seat_token': hosted.token,
            });
            await _expectRefused(f, refused, min: n);
            expect(
              host.isDone,
              isFalse,
              reason: 'the refused resume must not take the host seat over '
                  '(section 7.1 close 4004 on the live socket). Host frames: '
                  '${host.all}. ${f._context}',
            );
            expect(f.registry.roomCount, 1, reason: f._context);
            expect(
              f.registry.lookup(hosted.code)!.seats,
              hasLength(1),
              reason:
                  'the refused join_room must not seat anyone. ${f._context}',
            );
          },
        );
      },
    );

    test('X5: resume is refused below the minimum (rule 7)', () async {
      await _scenario(
        'X5 minimum $n, resume at ${n - 1} after a game at $n',
        n,
        (_Fixture f) async {
          final _Client first = await f.dial('$n');
          final _Seated seated = await _create(f, first);
          await first.dispose();
          await first.closed();

          final _Client old = await f.dial('${n - 1}');
          old.send('resume', <String, Object?>{
            'code': seated.code,
            'seat_token': seated.token,
          });
          await _expectRefused(f, old, min: n);

          final _Client current = await f.dial('$n');
          final _Seated resumed = await _resume(
            f,
            current,
            seated.code,
            seated.token,
          );
          expect(resumed.seat, seated.seat, reason: f._context);
        },
      );
    });

    test(
      'X6: frames that are not valid envelopes are not answered either',
      () async {
        await _scenario(
          'X6 minimum $n, no header, then text that is not JSON, a binary '
          'frame, v 2 and a frame over 8192 bytes',
          n,
          (_Fixture f) async {
            final _Client c = await f.dial(null);
            c.socket
              ..add('this is not json')
              ..add(<int>[1, 2, 3])
              ..add(
                jsonEncode(<String, Object?>{
                  'v': 2,
                  't': 'ping',
                  'id': 'c634-version-two',
                  'd': <String, Object?>{},
                }),
              )
              ..add(
                jsonEncode(<String, Object?>{
                  'v': 1,
                  't': 'create_room',
                  'id': 'c634-oversize-frame',
                  'd': <String, Object?>{'name': 'x' * 9000, 'players': 2},
                }),
              );
            await _expectRefused(f, c, min: n);
          },
        );
      },
    );

    test(
      'X10: two header lines read as comma-joined values, so build 0',
      () async {
        await _scenario(
          'X10 minimum $n, two Ludo-Client-Build lines, 560 and '
          '561',
          n,
          (_Fixture f) async {
            final _Client c = await f.dialRaw(<MapEntry<String, String>>[
              const MapEntry<String, String>(_header, '560'),
              const MapEntry<String, String>(_header, '561'),
            ], 'two header lines');
            await _expectRefused(f, c, min: n);
            expect(
                f.connectLines,
                <String>[
                  'connect build=0',
                ],
                reason: 'rule 2: several values are build 0. ${f._context}');
          },
        );
      },
    );

    test(
      'X7: a flood on a refused socket counts against no rate limit',
      () async {
        await _scenario(
          'X7 minimum $n, refused socket sends 70 frames (6 create_room, '
          '25 join_room, then pings), then a good socket from the same IP '
          'creates 5 rooms and joins one',
          n,
          (_Fixture f) async {
            final _Client refused = await f.dial(null);
            for (int i = 0; i < 6; i++) {
              refused.send('create_room', <String, Object?>{
                'name': 'Spam',
                'players': 2,
              });
            }
            for (int i = 0; i < 25; i++) {
              refused.send('join_room', <String, Object?>{
                'code': 'ABCDEF',
                'name': 'Spam',
              });
            }
            for (int i = 0; i < 39; i++) {
              refused.send('ping', <String, Object?>{});
            }
            await _expectRefused(f, refused, min: n);
            expect(f.registry.roomCount, 0, reason: f._context);

            final _Client good = await f.dial('$n');
            String? firstCode;
            for (int i = 1; i <= 5; i++) {
              final _Seated seated = await _create(f, good);
              firstCode ??= seated.code;
            }
            expect(
              f.registry.roomCount,
              5,
              reason: 'rule 4: the refused socket used none of the 5 '
                  'create_room attempts the IP gets per hour. ${f._context}',
            );
            final _Client joiner = await f.dial('$n');
            await _join(f, joiner, firstCode!);
          },
        );
      },
    );

    test(
      'X8: five refused sockets at once each get their own one frame',
      () async {
        await _scenario(
          'X8 minimum $n, five sockets dialled together with no '
          'header, 1, 2, 3, 559',
          n,
          (_Fixture f) async {
            final List<String?> headers = <String?>[null, '1', '2', '3', '559'];
            final List<_Client> clients = await Future.wait(
              headers.map<Future<_Client>>(f.dial),
            );
            for (final _Client c in clients) {
              c.send('create_room', <String, Object?>{
                'name': 'Late',
                'players': 2,
              });
            }
            for (final _Client c in clients) {
              await _expectRefused(f, c, min: n);
            }
            expect(f.registry.roomCount, 0, reason: f._context);
            expect(
              f.lines.where(
                (String l) => l.contains('outcome=UPDATE_REQUIRED'),
              ),
              hasLength(5),
              reason:
                  'rule 4: one refusal line per refused socket. ${f._context}',
            );
          },
        );
      },
    );

    test(
      'X9: refused sockets that hang up at once leave the server serving',
      () async {
        await _scenario(
          'X9 minimum $n, ten refused sockets destroyed right '
          'after the upgrade, then a good socket',
          n,
          (_Fixture f) async {
            final List<_Client> clients = await Future.wait(
              List<int>.generate(
                10,
                (int i) => i,
              ).map<Future<_Client>>((int i) => f.dial(null)),
            );
            for (final _Client c in clients) {
              c.send('create_room', <String, Object?>{
                'name': 'Gone',
                'players': 2,
              });
              c.socket.close();
            }
            await _until(
              () => f.connectLines.length >= 10,
              'ten connect lines for the ten sockets that hung up',
              f,
            );
            final _Client good = await f.dial('$n');
            await _create(f, good);
            expect(
              f.registry.roomCount,
              1,
              reason:
                  'only the good socket may have made a room. ${f._context}',
            );
          },
        );
      },
    );
  });

  group('rules 4, 5: the log lines', () {
    const int n = 560;

    test(
      'L1: a refused socket logs connect then the refusal line, exactly',
      () async {
        await _scenario('L1 minimum $n, header 559', n, (_Fixture f) async {
          final _Client c = await f.dial('559');
          await _expectRefused(f, c, min: n);
          await _until(
            () => f.lines.any(
              (String l) => l.contains('outcome=UPDATE_REQUIRED'),
            ),
            'the refusal line',
            f,
          );
          final List<String> relevant = f.lines
              .map((String l) => l.trim())
              .where(
                (String l) =>
                    l.startsWith('connect build=') ||
                    l.contains('outcome=UPDATE_REQUIRED'),
              )
              .toList();
          expect(
            relevant,
            <String>[
              'connect build=559',
              'room=- type=- id=- seat=- outcome=UPDATE_REQUIRED build=559',
            ],
            reason: 'rule 5 then rule 4: the connect line comes first and '
                'nothing else is logged about the socket. ${f._context}',
          );
        });
      },
    );

    test('L2: a socket with no header logs build=0 on both lines', () async {
      await _scenario('L2 minimum $n, no header', n, (_Fixture f) async {
        final _Client c = await f.dial(null);
        await _expectRefused(f, c, min: n);
        await _until(
          () =>
              f.lines.any((String l) => l.contains('outcome=UPDATE_REQUIRED')),
          'the refusal line',
          f,
        );
        expect(
          f.lines.map((String l) => l.trim()),
          containsAllInOrder(<String>[
            'connect build=0',
            'room=- type=- id=- seat=- outcome=UPDATE_REQUIRED build=0',
          ]),
          reason: f._context,
        );
      });
    });

    test('L3: the refusal logs the socket build, not the minimum', () async {
      await _scenario('L3 minimum 900, header 0042', 900, (_Fixture f) async {
        final _Client c = await f.dial('0042');
        await _expectRefused(f, c, min: 900);
        await _until(
          () =>
              f.lines.any((String l) => l.contains('outcome=UPDATE_REQUIRED')),
          'the refusal line',
          f,
        );
        expect(
          f.lines.map((String l) => l.trim()),
          containsAllInOrder(<String>[
            'connect build=42',
            'room=- type=- id=- seat=- outcome=UPDATE_REQUIRED build=42',
          ]),
          reason: f._context,
        );
      });
    });

    test(
      'L4: frames sent on a refused socket leave no per-frame log line',
      () async {
        await _scenario('L4 minimum $n, no header, create_room sent', n, (
          _Fixture f,
        ) async {
          final _Client c = await f.dial(null);
          c.send('create_room', <String, Object?>{
            'name': 'Late',
            'players': 2,
          });
          c.send('join_room', <String, Object?>{'code': 'ABCDEF', 'name': 'L'});
          await _expectRefused(f, c, min: n);
          await _until(
            () => f.lines.any(
              (String l) => l.contains('outcome=UPDATE_REQUIRED'),
            ),
            'the refusal line',
            f,
          );
          expect(
            f.lines.where(
              (String l) =>
                  l.contains('type=create_room') ||
                  l.contains('type=join_room'),
            ),
            isEmpty,
            reason: 'rule 4: nothing sent on the refused socket is processed, '
                'so nothing is logged as handled. ${f._context}',
          );
        });
      },
    );

    test(
        'L5: one connect line per accepted socket, in order, nothing else '
        'on it', () async {
      await _scenario('L5 minimum $n, headers 560 / none / 561 / 12,13', n, (
        _Fixture f,
      ) async {
        await _create(f, await f.dial('$n'));
        await _expectRefused(f, await f.dial(null), min: n);
        await _create(f, await f.dial('561'));
        await _expectRefused(f, await f.dial('12,13'), min: n);
        expect(
          f.connectLines,
          <String>[
            'connect build=560',
            'connect build=0',
            'connect build=561',
            'connect build=0',
          ],
          reason: 'rule 5: exactly "connect build=<build>", no address, '
              'code or name, one per socket. ${f._context}',
        );
      });
    });

    test(
      'L6: the connect line precedes the first handled line on its socket',
      () async {
        await _scenario('L6 minimum 0, header 9, create_room', 0, (
          _Fixture f,
        ) async {
          await _create(f, await f.dial('9'));
          final int connect = f.lines.indexWhere(
            (String l) => l.trim() == 'connect build=9',
          );
          final int handled = f.lines.indexWhere(
            (String l) => l.contains('type=create_room'),
          );
          expect(
            connect,
            isNonNegative,
            reason: 'the connect line is missing. ${f._context}',
          );
          expect(
            handled,
            isNonNegative,
            reason: 'the existing create_room line is missing, so the print '
                'capture is not seeing the server. ${f._context}',
          );
          expect(
            connect,
            lessThan(handled),
            reason: 'rule 5: before anything else happens on the socket. '
                '${f._context}',
          );
        });
      },
    );
  });

  group('rule 8: what does not change', () {
    const int n = 560;

    test(
      'U1: plain HTTP pages are never refused and log no connect line',
      () async {
        await _scenario(
          'U1 minimum $n, GET /health and /privacy, no header',
          n,
          (_Fixture f) async {
            final HttpClient http = HttpClient();
            addTearDown(() => http.close(force: true));
            for (final String path in <String>['/health', '/privacy']) {
              final HttpClientRequest request = await http.getUrl(
                f.httpUri(path),
              );
              final HttpClientResponse response = await request.close();
              final String body = await utf8.decodeStream(response);
              expect(
                response.statusCode,
                200,
                reason: 'GET $path is not an upgrade and must not be refused. '
                    'Got ${response.statusCode}. ${f._context}',
              );
              if (path == '/health') {
                expect(
                  body,
                  isNot(contains('560')),
                  reason: 'rule 8: /health reports no configuration value. '
                      'Body: $body',
                );
                expect(
                  body.toLowerCase(),
                  isNot(contains('min')),
                  reason: 'rule 8: /health does not report the minimum. '
                      'Body: $body',
                );
              }
            }
            expect(
              f.connectLines,
              isEmpty,
              reason: 'rule 5 counts upgrades only. ${f._context}',
            );
          },
        );
      },
    );

    test(
        'U2: a refused socket does not stop a later good one on the same '
        'server', () async {
      await _scenario('U2 minimum $n, refused then good', n, (
        _Fixture f,
      ) async {
        await _expectRefused(f, await f.dial('1'), min: n);
        final _Seated seated = await _create(f, await f.dial('$n'));
        expect(seated.seat, 0, reason: f._context);
        expect(f.registry.roomCount, 1, reason: f._context);
      });
    });
  });

  group('rule 4: a refused connection drops every frame (no network)', () {
    const int n = 600;

    test(
      'D1: create_room, join_room, resume and 70 more frames after the '
      'refusal change nothing and are never answered',
      () async {
        final _Bench b = _Bench(
          'D1 build 559 refused at minimum $n, create_room, join_room, '
          'resume, then 6 create_room / 25 join_room / 39 ping',
          clientBuild: 559,
        );
        final CreateOk live = b.liveRoom();
        final String code = live.room.code;
        final String hostToken = live.seat.seatToken;
        final List<String> lines = await _captureLines(() async {
          await b.conn.refuseUpdateRequired(minBuild: n);

          await b.conn.handleFrame(
            b.frame('create_room', <String, Object?>{
              'name': 'Late',
              'players': 2,
            }),
          );
          await b.conn.handleFrame(
            b.frame('join_room', <String, Object?>{
              'code': code,
              'name': 'Sneak',
            }),
          );
          await b.conn.handleFrame(
            b.frame('resume', <String, Object?>{
              'code': code,
              'seat_token': hostToken,
            }),
          );
          for (int i = 0; i < 6; i++) {
            await b.conn.handleFrame(
              b.frame('create_room', <String, Object?>{
                'name': 'Spam',
                'players': 2,
              }),
            );
          }
          for (int i = 0; i < 25; i++) {
            await b.conn.handleFrame(
              b.frame('join_room', <String, Object?>{
                'code': code,
                'name': 'Spam',
              }),
            );
          }
          for (int i = 0; i < 39; i++) {
            await b.conn.handleFrame(b.frame('ping', <String, Object?>{}));
          }
        });

        expect(
          b.registry.roomCount,
          1,
          reason: 'rule 4: no create_room on a refused connection makes a '
              'room; only the live room made before it may exist. '
              '${b.context}',
        );
        expect(
          b.registry.lookup(code)!.seats,
          hasLength(1),
          reason: 'rule 4: the join_room on a refused connection seats '
              'nobody, so the live room keeps its one seat. ${b.context}',
        );
        expect(
          b.registry.lookup(code)!.seats.single.seatToken,
          hostToken,
          reason: 'the live room still holds its original seat. ${b.context}',
        );
        expect(
          b.hub.calls,
          isEmpty,
          reason: 'rule 4: nothing a refused connection sends may attach it '
              'to a room or broadcast to one. ${b.context}',
        );
        expect(
          b.channel.received,
          hasLength(1),
          reason: 'rule 4: the only frame the peer ever gets is the one '
              'UPDATE_REQUIRED error. ${b.context}',
        );
        final Map<String, Object?> only = b.channel.received.single;
        expect(only['t'], 'error', reason: 'got $only. ${b.context}');
        expect(
          only.containsKey('re'),
          isFalse,
          reason: 'rule 4: the refusal answers nothing, so it has no re. '
              'got $only. ${b.context}',
        );
        final Map<String, Object?> d = only['d']! as Map<String, Object?>;
        expect(d['code'], 'UPDATE_REQUIRED', reason: '$d. ${b.context}');
        expect(d['min_build'], n, reason: '$d. ${b.context}');
        expect(
          b.channel._sink.closes,
          hasLength(1),
          reason: 'the connection is closed once, by the refusal. '
              '${b.context}',
        );
        expect(
          b.channel._sink.closes.single.code,
          closeCodeUpdateRequired,
          reason: 'close code 4005. ${b.context}',
        );
        expect(
          lines.map((String l) => l.trim()).toList(),
          <String>[
            'room=- type=- id=- seat=- outcome=UPDATE_REQUIRED build=559',
          ],
          reason: 'rule 4: the refusal is the only line logged; nothing '
              'sent afterwards is logged as handled. ${b.context}',
        );

        for (int i = 1; i <= 5; i++) {
          expect(
            b.rateLimiter.recordCreateRoom(_Bench.ip),
            isTrue,
            reason: 'rule 4: the refused connection used none of the 5 '
                'create_room attempts its IP gets per hour, so attempt $i '
                'must still be admitted. ${b.context}',
          );
        }
        for (int i = 1; i <= 20; i++) {
          expect(
            b.rateLimiter.recordJoinOrResume(_Bench.ip),
            isTrue,
            reason: 'rule 4: the refused connection used none of the 20 '
                'join or resume attempts its IP gets, so attempt $i must '
                'still be admitted. ${b.context}',
          );
        }
        expect(
          b.rateLimiter.recordMessage(b.conn),
          MessageRateOutcome.allowed,
          reason: 'rule 4: the refused connection counted no message against '
              'its own per-second window. ${b.context}',
        );
      },
    );

    test(
      'D2: frames that are not valid envelopes are dropped without an '
      'error frame or a second close',
      () async {
        final _Bench b = _Bench(
          'D2 build 0 refused at minimum $n, text that is not JSON, binary, '
          'v 2 and a frame over $maxFrameBytes bytes',
          clientBuild: 0,
        );
        final List<String> lines = await _captureLines(() async {
          await b.conn.refuseUpdateRequired(minBuild: n);
          await b.conn.handleFrame('this is not json');
          await b.conn.handleFrame(<int>[1, 2, 3]);
          await b.conn.handleFrame(
            jsonEncode(<String, Object?>{
              'v': 2,
              't': 'ping',
              'id': 'c634-unit-v2-frame',
              'd': <String, Object?>{},
            }),
          );
          await b.conn.handleFrame(
            b.frame('create_room', <String, Object?>{
              'name': 'x' * (maxFrameBytes + 1),
              'players': 2,
            }),
          );
        });
        expect(
          b.channel.received,
          hasLength(1),
          reason: 'rule 4: a malformed frame on a refused connection is '
              'dropped, not answered with BAD_FIELD, TOO_LARGE or '
              'PROTOCOL_VERSION. ${b.context}',
        );
        expect(
          b.channel._sink.closes,
          hasLength(1),
          reason: 'rule 4: no second close (4001 or 4002) follows the '
              '4005. Closes: ${b.channel._sink.closes}. ${b.context}',
        );
        expect(
          b.channel._sink.closes.single.code,
          closeCodeUpdateRequired,
          reason: b.context,
        );
        expect(
          lines,
          hasLength(1),
          reason: 'only the refusal line is logged. Lines: $lines. '
              '${b.context}',
        );
      },
    );

    test(
      'D3: control, the same create_room and join_room on a connection that '
      'was not refused are handled',
      () async {
        final _Bench b = _Bench(
          'D3 build 600 not refused, create_room then join_room',
          clientBuild: 600,
        );
        final CreateOk live = b.liveRoom();
        await _captureLines(() async {
          await b.conn.handleFrame(
            b.frame('create_room', <String, Object?>{
              'name': 'Fine',
              'players': 2,
            }),
          );
          await b.conn.handleFrame(
            b.frame('join_room', <String, Object?>{
              'code': live.room.code,
              'name': 'Guest',
            }),
          );
        });
        expect(
          b.registry.roomCount,
          2,
          reason: 'the frames used by D1 are valid: on an ordinary '
              'connection create_room makes a room. ${b.context}',
        );
        expect(
          b.channel.received.map((Map<String, Object?> f) => f['t']),
          contains('seat_assigned'),
          reason: 'an ordinary connection is answered. ${b.context}',
        );
      },
    );
  });

  group('rule 3: bin/server.dart as a real process', () {
    test(
        'S1: a bad MIN_CLIENT_BUILD stops the start with rc 64 before the '
        'port opens', () async {
      final Directory root = await _packageRoot();
      for (final String bad in <String>['abc', '-1', '5.5']) {
        final int port = await _freePort();
        final Process process = await Process.start(
          Platform.resolvedExecutable,
          <String>['run', 'bin/server.dart'],
          workingDirectory: root.path,
          environment: _childEnvironment(<String, String>{
            'MIN_CLIENT_BUILD': bad,
            'PORT': '$port',
          }),
          includeParentEnvironment: false,
        );
        final Future<String> stderrText =
            process.stderr.transform(utf8.decoder).join();
        final Future<String> stdoutText =
            process.stdout.transform(utf8.decoder).join();
        int? exitCode;
        try {
          exitCode = await process.exitCode.timeout(
            const Duration(seconds: 90),
          );
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          fail(
            'MIN_CLIENT_BUILD=$bad PORT=$port: bin/server.dart did not '
            'exit within 90 s; rule 3 says it stops at start',
          );
        }
        final String err = await stderrText;
        final String out = await stdoutText;
        expect(
          exitCode,
          64,
          reason: 'MIN_CLIENT_BUILD=$bad PORT=$port: expected exit code 64, '
              'got $exitCode. stderr: $err stdout: $out',
        );
        expect(
          err,
          contains('MIN_CLIENT_BUILD'),
          reason: 'MIN_CLIENT_BUILD=$bad PORT=$port: rule 3 wants a line on '
              'stderr naming the variable. stderr: "$err" stdout: "$out"',
        );
        expect(
          await _isListening(port),
          isFalse,
          reason: 'MIN_CLIENT_BUILD=$bad PORT=$port: the port must never '
              'have opened',
        );
      }
    }, timeout: const Timeout(Duration(seconds: 360)));

    for (final String? minimum in <String?>['560', '', null]) {
      test(
        'S2: MIN_CLIENT_BUILD=${jsonEncode(minimum)} starts, and a no-header '
        'socket is ${minimum == '560' ? 'refused' : 'served'}',
        () async {
          final Directory root = await _packageRoot();
          final int port = await _freePort();
          final Process process = await Process.start(
            Platform.resolvedExecutable,
            <String>['run', 'bin/server.dart'],
            workingDirectory: root.path,
            environment: _childEnvironment(<String, String>{
              if (minimum != null) 'MIN_CLIENT_BUILD': minimum,
              'PORT': '$port',
            }),
            includeParentEnvironment: false,
          );
          final StringBuffer out = StringBuffer();
          final StringBuffer err = StringBuffer();
          process.stdout.transform(utf8.decoder).listen(out.write);
          process.stderr.transform(utf8.decoder).listen(err.write);
          final List<_Client> clients = <_Client>[];
          try {
            final DateTime deadline = DateTime.now().add(
              const Duration(seconds: 90),
            );
            bool exited = false;
            unawaited(process.exitCode.then((int _) => exited = true));
            while (!await _isListening(port)) {
              if (exited) {
                fail(
                  'MIN_CLIENT_BUILD=${jsonEncode(minimum)} PORT=$port: the '
                  'server exited before listening. stderr: $err stdout: $out',
                );
              }
              if (DateTime.now().isAfter(deadline)) {
                fail(
                  'MIN_CLIENT_BUILD=${jsonEncode(minimum)} PORT=$port: the '
                  'server was not listening within 90 s. stderr: $err',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            final Uri uri = Uri(
              scheme: 'ws',
              host: '127.0.0.1',
              port: port,
              path: '/',
            );
            final WebSocket socket = await WebSocket.connect(uri.toString());
            final _Client noHeader = _Client._('no-header', socket);
            clients.add(noHeader);
            noHeader.send('create_room', <String, Object?>{
              'name': 'Proc',
              'players': 2,
            });
            if (minimum == '560') {
              final Map<String, Object?> frame = await noHeader.next(
                'the refusal frame',
              );
              final Map<String, Object?> d =
                  frame['d']! as Map<String, Object?>;
              expect(
                d['code'],
                'UPDATE_REQUIRED',
                reason: 'MIN_CLIENT_BUILD=560, no header: got $frame',
              );
              expect(d['min_build'], 560, reason: 'got $frame');
              expect(
                await noHeader.closed(),
                4005,
                reason: 'frames: ${noHeader.all}',
              );

              final WebSocket okSocket = await WebSocket.connect(
                uri.toString(),
                headers: <String, String>{_header: '560'},
              );
              final _Client ok = _Client._('build=560', okSocket);
              clients.add(ok);
              ok.send('create_room', <String, Object?>{
                'name': 'Proc',
                'players': 2,
              });
              final Map<String, Object?> room = await ok.nextOfType(<String>{
                'room',
                'error',
              }, 'a room');
              expect(
                room['t'],
                'room',
                reason: 'MIN_CLIENT_BUILD=560, header 560 must play: $room',
              );
            } else {
              final Map<String, Object?> room = await noHeader.nextOfType(
                <String>{'room', 'error'},
                'a room',
              );
              expect(
                room['t'],
                'room',
                reason: 'MIN_CLIENT_BUILD=${jsonEncode(minimum)} means the '
                    'check is off, so a no-header socket creates a room: '
                    '$room',
              );
            }
            expect(
              out.toString(),
              contains('connect build=0'),
              reason: 'rule 5: the process logs the connect line on stdout. '
                  'stdout: $out',
            );
          } finally {
            for (final _Client c in clients) {
              await c.dispose();
            }
            process.kill(ProcessSignal.sigterm);
            await process.exitCode.timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                process.kill(ProcessSignal.sigkill);
                return process.exitCode;
              },
            );
          }
        },
        timeout: const Timeout(Duration(seconds: 240)),
      );
    }
  });
}
