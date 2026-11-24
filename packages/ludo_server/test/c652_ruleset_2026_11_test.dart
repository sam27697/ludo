// Order C-652t: the proof of docs/PROTOCOL.md section 28, the ruleset of
// 2026-11-15 (yard release, places played out, an absent seat removed), in
// the list rule 6 of that section gives.
//
// Written from the section, from docs/ENGINE_API.md sections 11 and 12 and
// from docs/VERIFY.md section 1 only. Everything runs over real sockets
// against a real WireServer with a fake clock, or against bin/server.dart as
// a real child process for the environment switch.
//
// How RULESET is injected. Section 28 rule 1 reads RULESET once, from the
// server environment, and the room takes it at create_room. In process, the
// only seam the sibling suites use for a server setting (MIN_CLIENT_BUILD in
// c634_client_build_test.dart) is a constructor argument, so the injection
// here is a named `ruleset` argument with the environment's own string value
// ('2026-10' or '2026-11'), tried on RoomRegistry first (the room is created
// there) and on WireServer second. The call goes through Function.apply so
// this file compiles whatever the constructors look like; when neither takes
// the argument every 2026-11 case fails with a message saying so, which is
// the report the order asks for. The environment path itself is proved
// separately against the real process (group "the switch, real process").
//
// Board and dice. No production hook is used anywhere. A position the dice
// would take hours to reach (a seat one step from home, a drought of nine,
// an opponent block on an entry square) is built by rewriting the room's
// engine state through the registry between frames, the pattern of
// rematch_test.dart and c649_rematch_chain_test.dart. Faces that matter are
// steered with the existing offline search (support/dice_oracle.dart and
// support/scripted_bytes.dart), so the whole run is deterministic: a failure
// names its scenario, and the scenario name is the whole reproduction. No
// test sleeps; every wait is on a frame, a socket close or a ping/pong
// barrier.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';
import 'support/pre_copies.dart';

typedef Frame = Map<String, Object?>;

const String _v26 = '2026-11';
const String _v25 = '2026-10';

const String _lineEn =
    'No 6 for 10 rolls with every piece at home: one piece comes out (rule 11r)';
const String _lineAr =
    'ما طلع 6 بعشر رميات وكل القطع بالبيت: بتطلع قطعة وحدة (القاعدة 11r)';

Map<String, Object?> _d(Frame frame) => frame['d']! as Map<String, Object?>;

List<Object?> _types(List<Frame> frames) =>
    <Object?>[for (final Frame f in frames) f['t']];

List<Frame> _ofType(List<Frame> frames, String type) => <Frame>[
      for (final Frame f in frames)
        if (f['t'] == type) f
    ];

Object? _canon(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final String k in keys) k: _canon(value[k])};
  }
  if (value is List) {
    return <Object?>[for (final Object? v in value) _canon(v)];
  }
  return value;
}

/// Key-order independent JSON, so two maps compare by content.
String _j(Object? value) => jsonEncode(_canon(value));

// ---------------------------------------------------------------------------
// The fixture: one server, one fake clock, every failure with its scenario.
// ---------------------------------------------------------------------------

class _Steer {
  _Steer._(this.description, this.secret, this.gameId, this.clientSeeds);

  final String description;
  final List<int> secret;
  final String gameId;
  final String clientSeeds;

  Random random() => ScriptedBytesRandom(buildScript(secret: secret));

  static final Map<String, _Steer> _cache = <String, _Steer>{};

  /// A secret whose first faces are exactly [wanted].
  static _Steer faces(List<int> wanted) {
    return _cache.putIfAbsent('faces:${_j(wanted)}', () {
      final String gameId = _predictedGameId();
      final SteeredSecret s = findSecretForFaces(
        wanted: wanted,
        gameId: gameId,
        clientSeeds: _seedsFor2,
      );
      return _Steer._(
        'steered so that rolls 1..${wanted.length} are $wanted',
        s.secret,
        gameId,
        _seedsFor2,
      );
    });
  }

  /// A secret whose first [count] faces are all different from 6.
  static _Steer noSix(int count) {
    return _cache.putIfAbsent('nosix:$count', () {
      final String gameId = _predictedGameId();
      for (int i = 0; i < 20000; i++) {
        final List<int> secret = candidateSecretAt(i);
        final List<int> faces = facesFor(
          secret,
          gameId: gameId,
          clientSeeds: _seedsFor2,
          count: count,
        );
        if (faces.every((int f) => f != 6)) {
          return _Steer._(
            'steered so that rolls 1..$count are never 6 '
            '(candidate $i, faces $faces)',
            secret,
            gameId,
            _seedsFor2,
          );
        }
      }
      throw StateError('no candidate gave $count rolls without a 6');
    });
  }
}

const String _seedsFor2 = '0:seed-s0|2:seed-s2';

String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

class _Fixture {
  _Fixture._(this.scenario, this.ruleset, this.steer);

  final String scenario;
  final String? ruleset;
  final _Steer? steer;

  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 15));

  /// The rate limiter has its own clock so that the one-second message
  /// ceiling never depends on the game clock a scenario is driving.
  final FakeClock limiterClock = FakeClock(DateTime.utc(2026, 11, 15));

  late final RoomRegistry registry;
  late final WireServer server;
  final List<WireTestClient> clients = <WireTestClient>[];
  String injection = 'none (ruleset absent)';

  static Future<_Fixture> start(
    String scenario, {
    String? ruleset,
    _Steer? steer,
  }) async {
    final _Fixture fx = _Fixture._(scenario, ruleset, steer);
    final Random rnd = steer?.random() ?? Random.secure();
    final List<String> notes = <String>[];
    RoomRegistry? registry;
    WireServer? server;
    if (ruleset == null) {
      registry = RoomRegistry(clock: fx.clock, secure: rnd);
    } else {
      try {
        registry =
            Function.apply(RoomRegistry.new, <Object?>[], <Symbol, Object?>{
          #clock: fx.clock,
          #secure: rnd,
          #ruleset: ruleset,
        }) as RoomRegistry;
        fx.injection = 'RoomRegistry(ruleset: "$ruleset")';
      } on Object catch (error) {
        notes.add('RoomRegistry(ruleset:) refused: ${error.runtimeType}');
      }
    }
    registry ??= RoomRegistry(clock: fx.clock, secure: rnd);
    final RateLimiter limiter = RateLimiter(clock: fx.limiterClock);
    if (ruleset != null && fx.injection == 'none (ruleset absent)') {
      try {
        server = Function.apply(WireServer.new, <Object?>[], <Symbol, Object?>{
          #registry: registry,
          #rateLimiter: limiter,
          #clock: fx.clock,
          #automaticTurnExpiry: false,
          #ruleset: ruleset,
        }) as WireServer;
        fx.injection = 'WireServer(ruleset: "$ruleset")';
      } on Object catch (error) {
        notes.add('WireServer(ruleset:) refused: ${error.runtimeType}');
      }
      if (server == null) {
        throw TestFailure(
          'scenario=$scenario: cannot inject RULESET="$ruleset" in process. '
          'Neither RoomRegistry nor WireServer takes a named argument '
          '`ruleset` (a String holding the environment value). Tried: '
          '${notes.join('; ')}. Section 28 rule 1 puts the switch in the '
          'server environment, read once at start; the in-process seam is '
          'the missing production piece.',
        );
      }
    }
    server ??= WireServer(
      registry: registry,
      rateLimiter: limiter,
      clock: fx.clock,
      automaticTurnExpiry: false,
    );
    fx.registry = registry;
    fx.server = server;
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    return fx;
  }

  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Future<WireTestClient> connect() async {
    final WireTestClient c = await WireTestClient.connect(wsUri);
    clients.add(c);
    return c;
  }

  /// Sends one message after moving the limiter's own clock a little, so the
  /// per-second ceiling never trips in a long scenario.
  String send(WireTestClient c, String type, Map<String, Object?> data) {
    limiterClock.advance(const Duration(milliseconds: 1100));
    return c.send(type, data);
  }

  /// Sends without moving the limiter clock (the rate-limit case only).
  String sendBurst(WireTestClient c, String type, Map<String, Object?> data) {
    return c.send(type, data);
  }

  Future<void> close() async {
    for (final WireTestClient c in clients) {
      try {
        await c.close();
      } on Object {
        // already closed by the server
      }
    }
    await server.close();
  }

  String get reproduce => 'scenario="$scenario" '
      '(${steer?.description ?? 'dice not steered'}; injection: $injection; '
      'rerun: dart test test/c652_ruleset_2026_11_test.dart '
      '--plain-name "$scenario")';

  Never fail(String what, {Object? expected, Object? actual}) {
    throw TestFailure(
      '$what | expected: ${expected is String ? expected : _j(expected)} | '
      'actual: ${actual is String ? actual : _j(actual)} | $reproduce',
    );
  }

  void eq(Object? actual, Object? expected, String what) {
    if (_j(actual) != _j(expected)) {
      fail(what, expected: expected, actual: actual);
    }
  }

  void ok(bool condition, String what, [Object? actual]) {
    if (!condition) {
      fail(what, expected: 'true', actual: actual ?? 'false');
    }
  }

  void absent(Map<String, Object?> d, String key, String what) {
    if (d.containsKey(key)) {
      fail('$what: key "$key" must be absent',
          expected: 'no "$key"', actual: d);
    }
  }
}

Future<void> _withFixture(
  String scenario,
  Future<void> Function(_Fixture fx) body, {
  String? ruleset = _v26,
  _Steer? steer,
}) async {
  final _Fixture fx = await _Fixture.start(
    scenario,
    ruleset: ruleset,
    steer: steer,
  );
  try {
    await body(fx);
  } finally {
    await fx.close();
  }
}

/// Reads off [c] until its ping is answered: every frame the server wrote to
/// this socket before it handled the ping, in order, the pong left out.
Future<List<Frame>> _flush(_Fixture fx, WireTestClient c) async {
  final String id = fx.send(c, 'ping', <String, Object?>{});
  final List<Frame> out = <Frame>[];
  while (true) {
    final Frame f = await c.next(timeout: const Duration(seconds: 5));
    if (f['t'] == 'pong' && f['re'] == id) {
      return out;
    }
    out.add(f);
  }
}

class _Seat {
  _Seat(this.seat, this.token, this.client);

  final int seat;
  final String token;
  WireTestClient client;
  bool up = true;
}

class _Table {
  _Table(this.fx, this.code, this.seats, this.createFrame);

  final _Fixture fx;
  final String code;
  final Map<int, _Seat> seats;
  final Frame createFrame;
  String? gameId;

  WireTestClient c(int seat) => seats[seat]!.client;
  String token(int seat) => seats[seat]!.token;
  Room get room => fx.registry.lookup(code)!;
  List<int> get numbers => (seats.keys.toList()..sort());

  /// Flushes every connected seat, the [first] one first (the sender, whose
  /// pong proves its message was handled before anyone else is asked).
  Future<Map<int, List<Frame>>> syncAll({int? first}) async {
    final Map<int, List<Frame>> out = <int, List<Frame>>{};
    final List<int> order = <int>[
      if (first != null && seats[first]!.up) first,
      for (final int s in numbers)
        if (s != first && seats[s]!.up) s,
    ];
    for (final int s in order) {
      out[s] = await _flush(fx, c(s));
    }
    return out;
  }

  /// One client message from [seat], then every frame the room produced.
  Future<Map<int, List<Frame>>> step(
    int seat,
    String type,
    Map<String, Object?> data,
  ) async {
    fx.send(c(seat), type, data);
    return syncAll(first: seat);
  }
}

Future<_Table> _openTable(
  _Fixture fx, {
  int players = 2,
  bool seeds = false,
  Map<String, Object?>? rules,
}) async {
  final Map<int, _Seat> seats = <int, _Seat>{};
  final WireTestClient host = await fx.connect();
  fx.send(host, 'create_room', <String, Object?>{
    'name': 'Host',
    'players': players,
    if (rules != null) 'rules': rules,
  });
  final Frame sa = await host.next();
  final Frame room = await host.next();
  if (sa['t'] != 'seat_assigned' || room['t'] != 'room') {
    fx.fail(
      'create_room is answered by seat_assigned then room',
      expected: <String>['seat_assigned', 'room'],
      actual: <Object?>[sa['t'], room['t'], _d(sa), _d(room)],
    );
  }
  seats[_d(sa)['seat']! as int] =
      _Seat(_d(sa)['seat']! as int, _d(sa)['seat_token']! as String, host);
  final String code = _d(room)['code']! as String;
  for (int i = 1; i < players; i++) {
    final WireTestClient g = await fx.connect();
    fx.send(g, 'join_room', <String, Object?>{
      'install': 'testinstall-00000001',
      'code': code,
      'name': 'Guest$i'
    });
    final Frame gsa = await g.next();
    final Frame groom = await g.next();
    if (gsa['t'] != 'seat_assigned' || groom['t'] != 'room') {
      fx.fail(
        'join_room is answered by seat_assigned then room',
        expected: <String>['seat_assigned', 'room'],
        actual: <Object?>[gsa['t'], groom['t'], _d(gsa)],
      );
    }
    final int seat = _d(gsa)['seat']! as int;
    for (final _Seat other in seats.values) {
      await receiveType(other.client, 'player_joined');
    }
    seats[seat] = _Seat(seat, _d(gsa)['seat_token']! as String, g);
  }
  final _Table t = _Table(fx, code, seats, room);
  if (seeds) {
    for (final int s in t.numbers) {
      fx.send(t.c(s), 'set_seed', <String, Object?>{'client_seed': 'seed-s$s'});
      for (final int o in t.numbers) {
        await receiveType(t.c(o), 'seat_seed');
      }
    }
  }
  return t;
}

/// start_game from the host; reads every seat up to its opening turn.
Future<Map<int, List<Frame>>> _startGame(_Table t) async {
  final int host = t.numbers.first;
  t.fx.send(t.c(host), 'start_game', <String, Object?>{});
  final Map<int, List<Frame>> out = <int, List<Frame>>{};
  for (final int s in t.numbers) {
    out[s] = await drainUntil(
      t.c(s),
      'turn',
      maxFrames: 12,
      perFrame: const Duration(seconds: 3),
    );
  }
  final Frame gs = _ofType(out[host]!, 'game_started').single;
  t.gameId = _d(gs)['game_id']! as String;
  final _Steer? steer = t.fx.steer;
  if (steer != null) {
    t.fx.eq(
      t.gameId,
      steer.gameId,
      'the steering search predicted game_id from the registry draw order; '
      'a different game_id means the draws before start_game changed and '
      'the steered faces no longer apply',
    );
  }
  return out;
}

void _force(
  _Table t, {
  int? currentSeat,
  String? phase,
  List<int>? queue,
  Map<int, List<int>>? tokens,
  List<int>? drought,
  bool? releaseOwed,
  bool? blocks,
  int? sixes,
}) {
  final Room room = t.room;
  final Map<String, Object?> json = room.game!.toJson();
  if (currentSeat != null) {
    json['currentSeat'] = currentSeat;
  }
  if (phase != null) {
    json['phase'] = phase;
  }
  if (queue != null) {
    json['queue'] = queue;
  }
  if (tokens != null) {
    final List<Object?> rows = json['tokens']! as List<Object?>;
    tokens.forEach((int seat, List<int> row) => rows[seat] = row);
  }
  if (drought != null) {
    json['drought'] = drought;
  }
  if (releaseOwed != null) {
    json['releaseOwed'] = releaseOwed;
  }
  if (blocks != null) {
    final Map<String, Object?> config = json['config']! as Map<String, Object?>;
    (config['rules']! as Map<String, Object?>)['blocks'] = blocks;
  }
  if (sixes != null) {
    json['sixes'] = sixes;
  }
  room.game = engine.GameState.fromJson(json);
  room.turnSegmentStartedAt = t.fx.clock.now;
}

/// Restarts the running segment at the fake clock's present, so a sweep that
/// is about to prove something about absence never also expires a turn.
void _freshSegment(_Table t) {
  t.room.turnSegmentStartedAt = t.fx.clock.now;
}

Future<Map<String, Object?>> _resume(_Table t, int seat) async {
  final WireTestClient c = await t.fx.connect();
  t.fx.send(c, 'resume', <String, Object?>{
    'code': t.code,
    'seat_token': t.token(seat),
  });
  final Frame sa = await c.next();
  final Frame room = await c.next();
  t.fx.ok(
    sa['t'] == 'seat_assigned' && room['t'] == 'room',
    'resume is answered by seat_assigned then room',
    <Object?>[sa['t'], room['t'], _d(sa)],
  );
  t.seats[seat]!.client = c;
  t.seats[seat]!.up = true;
  return _d(room);
}

Future<List<Frame>> _untilPresence(
  _Table t,
  WireTestClient c,
  int seat,
  bool connected,
) async {
  final List<Frame> seen = <Frame>[];
  for (int i = 0; i < 12; i++) {
    final Frame f = await c.next(timeout: const Duration(seconds: 5));
    seen.add(f);
    if (f['t'] == 'presence' &&
        _d(f)['seat'] == seat &&
        _d(f)['connected'] == connected) {
      return seen;
    }
  }
  t.fx.fail('a presence frame for seat $seat connected=$connected',
      expected: 'presence', actual: seen);
}

/// Closes [seat]'s socket and waits until every other connected seat has
/// been told. Returns the presence frame the others saw.
Future<Frame> _drop(_Table t, int seat) async {
  final _Seat s = t.seats[seat]!;
  s.up = false;
  await s.client.close();
  Frame? presence;
  for (final _Seat o in t.seats.values) {
    if (o.up) {
      final List<Frame> seen = await _untilPresence(t, o.client, seat, false);
      presence = seen.last;
    }
  }
  return presence!;
}

Future<Map<String, Object?>> _get(_Fixture fx, String path) async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest req = await http.getUrl(Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: fx.server.port,
      path: path.split('?').first,
      query: path.contains('?') ? path.split('?').last : null,
    ));
    final HttpClientResponse res = await req.close();
    final String body = await utf8.decodeStream(res);
    return <String, Object?>{'status': res.statusCode, 'body': body};
  } finally {
    http.close(force: true);
  }
}

Future<Map<String, Object?>> _record(_Table t) async {
  final Map<String, Object?> res = await _get(t.fx, '/v/${t.gameId}.json');
  t.fx.eq(
      res['status'], 200, 'the verify record of game ${t.gameId} is stored');
  return jsonDecode(res['body']! as String) as Map<String, Object?>;
}

/// The `error` code of [frame], failing with the scenario otherwise.
String _code(_Fixture fx, Frame frame, String what) {
  fx.ok(frame['t'] == 'error', '$what must be answered by an error frame',
      <Object?>[frame['t'], frame['d']]);
  return _d(frame)['code']! as String;
}

void _expectError(
  _Fixture fx,
  List<Frame> frames,
  String code,
  String what,
) {
  fx.eq(_types(frames), <String>['error'], '$what: exactly one frame');
  fx.eq(_code(fx, frames.single, what), code, '$what: error code');
}

/// Closes the sockets of every seat in [seats] and waits, on the room's own
/// seat table, until the server has noticed each one. For the cases where
/// nobody is left connected to read a presence frame.
Future<void> _dropMany(_Table t, List<int> seats) async {
  for (final int seat in seats) {
    t.seats[seat]!.up = false;
    await t.seats[seat]!.client.close();
  }
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final bool allDown = seats.every((int seat) =>
        !t.room.seats.singleWhere((Seat s) => s.seat == seat).connected);
    if (allDown) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      t.fx.fail('the server noticed the closed sockets of seats $seats',
          expected: 'connected=false for every one', actual: 'still up');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Start of the table row that holds [reveal], -1 when it is in no open row
/// (the record is embedded in the page too, outside any row).
int _openRowStart(String body, String reveal) {
  for (int from = 0;;) {
    final int hit = body.indexOf(reveal, from);
    if (hit < 0) {
      return -1;
    }
    if (body.lastIndexOf('<tr', hit) > body.lastIndexOf('</tr>', hit)) {
      return body.lastIndexOf('<tr', hit);
    }
    from = hit + 1;
  }
}

// ---------------------------------------------------------------------------
// Positions.
// ---------------------------------------------------------------------------

/// seat on turn, awaiting a move on [face], with [seat] one step short of
/// home: moving token 3 by [face] brings the fourth token home.
void _forceFinishingMove(_Table t, int seat, {int face = 3}) {
  _force(
    t,
    currentSeat: seat,
    phase: 'awaitMove',
    queue: <int>[face],
    tokens: <int, List<int>>{
      seat: <int>[57, 57, 57, 57 - face],
    },
    releaseOwed: t.room.game!.config.rules.yardRelease ? false : null,
    sixes: 0,
  );
}

// ---------------------------------------------------------------------------
// Real process helpers (the switch).
// ---------------------------------------------------------------------------

Future<Directory> _packageRoot() async {
  final Uri? libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:ludo_server/ludo_server.dart'),
  );
  if (libUri == null) {
    throw TestFailure('could not resolve package:ludo_server to a file URI');
  }
  return File.fromUri(libUri).parent.parent;
}

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

Future<int> _freePort() async {
  final ServerSocket probe =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
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
// Frame-level checks that several cases share.
// ---------------------------------------------------------------------------

void _expectSameOnEverySeat(
  _Fixture fx,
  Map<int, List<Frame>> frames,
  String what,
) {
  final List<int> seatsRead = frames.keys.toList();
  final int n = frames[seatsRead.first]!.length;
  for (int i = 0; i < n; i++) {
    if (frames.values.any((List<Frame> l) => l.length != n)) {
      break;
    }
    final Frame f0 = frames[seatsRead.first]![i];
    expectPreOnRollerOnly(
        f0['t']! as String,
        <(int?, Map<String, Object?>)>[
          for (final int seat in seatsRead) (seat, _d(frames[seat]![i])),
        ],
        '$what, frame $i');
  }
  List<Object?>? first;
  frames.forEach((int seat, List<Frame> list) {
    final List<Object?> shape = <Object?>[
      for (final Frame f in list) <Object?>[f['t'], dWithoutPre(f)],
    ];
    if (first == null) {
      first = shape;
    } else {
      fx.eq(
          shape,
          first,
          '$what: seat $seat must see the frames every other '
          'seat saw, same type, same data, same seq');
    }
  });
}

void _expectReEchoed(
  _Fixture fx,
  Map<int, List<Frame>> frames,
  int sender,
  String id,
  String type,
) {
  frames.forEach((int seat, List<Frame> list) {
    for (final Frame f in list) {
      if (f['t'] != type) {
        continue;
      }
      if (seat == sender) {
        fx.eq(f['re'], id, 'the sender\'s copy of "$type" carries re');
      } else {
        fx.ok(!f.containsKey('re'),
            'the copy of "$type" other seats get carries no re', f);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// The release played to the end, shared by several cases.
// ---------------------------------------------------------------------------

/// A steered 2-seat 2026-11 game in which seat 0 rolls a release on roll 19
/// (ten consecutive non-6 rolls with every token in the yard). Plays rolls
/// 1..18 over the wire, checking each, and returns the frames every seat saw
/// for roll 19.
Future<Map<int, List<Frame>>> _playToRelease(_Table t) async {
  final _Fixture fx = t.fx;
  for (int k = 1; k <= 18; k++) {
    final int actor = k.isOdd ? 0 : 2;
    final int other = k.isOdd ? 2 : 0;
    final String id = fx.send(t.c(actor), 'roll', <String, Object?>{});
    final Map<int, List<Frame>> frames = await t.syncAll(first: actor);
    for (final int seat in <int>[0, 2]) {
      fx.eq(
          _types(frames[seat]!),
          <String>['rolled', 'turn_passed', 'turn'],
          'roll $k (non-6, every token in the yard) by seat $actor, seen by '
          'seat $seat');
    }
    final Map<String, Object?> rolled = _d(frames[actor]!.first);
    fx.eq(rolled['k'], k, 'roll $k: k');
    fx.eq(rolled['seat'], actor, 'roll $k: seat');
    fx.eq(rolled['legal'], <int>[], 'roll $k: legal');
    fx.absent(rolled, 'release', 'roll $k is not a release roll');
    fx.eq(_d(frames[actor]!.last)['seat'], other, 'roll $k: next seat');
    _expectReEchoed(fx, frames, actor, id, 'rolled');
    if (k == 4) {
      final Map<String, Object?> snap = await _resume(t, 0);
      final List<Object?> seats = snap['seats']! as List<Object?>;
      fx.eq(
        <Object?>[
          for (final Object? s in seats)
            (s! as Map<String, Object?>)['drought'],
        ],
        <int>[2, 2],
        'rule 9r in the snapshot after 4 rolls: seat 0 rolled k=1,3 and '
        'seat 2 rolled k=2,4, each without a 6 and with every token home',
      );
      await t.syncAll();
    }
  }
  fx.send(t.c(0), 'roll', <String, Object?>{});
  return t.syncAll(first: 0);
}

/// docs/PROTOCOL.md section 35 item 3: [seat] was on turn in await_roll and
/// had been sent a `pre`. Before its retire the server publishes that roll as
/// the timer would: one or more `rolled` for [seat] with `by: "timer"` (a six
/// owes another roll on the same seat), then the frames of each step. Returns
/// the index of `seat_retired` for [seat] in [got]. The face is not steered,
/// so the step frames between are checked by kind, not by count.
int _expectForcedRollFirst(
    _Fixture fx, List<Frame> got, int seat, String reason, String what) {
  final List<String> seen = <String>[
    for (final Frame f in got) '${f['t']}:${_d(f)['seat']}',
  ];
  fx.ok(got.isNotEmpty && got.first['t'] == 'rolled',
      '$what: section 35 item 3: the shown roll is published first', seen);
  final int r = got.indexWhere(
      (Frame f) => f['t'] == 'seat_retired' && _d(f)['seat'] == seat);
  fx.ok(
      r > 0, '$what: seat_retired for seat $seat after the forced roll', seen);
  fx.eq(_d(got[r])['reason'], reason, '$what: seat_retired.reason');
  for (final Frame f in got.sublist(0, r)) {
    final String t = '${f['t']}';
    fx.ok(
        <String>{'rolled', 'turn_passed', 'turn'}.contains(t),
        '$what: only the frames of the forced step come before the retire',
        seen);
    if (t == 'rolled') {
      fx.eq(_d(f)['seat'], seat, '$what: the forced roll is seat $seat\'s');
      fx.eq(_d(f)['by'], 'timer',
          '$what: section 35 item 3: taken as the timer would, by "timer"');
    }
  }
  final int seq0 = _d(got.first)['seq']! as int;
  fx.eq(
      <Object?>[for (final Frame f in got) _d(f)['seq']],
      <Object?>[for (int i = 0; i < got.length; i++) seq0 + i],
      '$what: seq strictly +1 each');
  return r;
}

void main() {
  // =========================================================================
  // Rule 1: the switch, in process
  // =========================================================================
  group('rule 1: a room takes the server ruleset at create_room', () {
    for (final String? ruleset in <String?>[null, _v25]) {
      test(
          'S1: ruleset ${ruleset ?? 'absent'}: no ruleset key, no drought, '
          'no placings, engine config unchanged', () async {
        final String name = 'S1 ruleset ${ruleset ?? 'absent'}';
        await _withFixture(name, (_Fixture fx) async {
          final _Table t = await _openTable(fx, players: 2);
          final Map<String, Object?> lobby = _d(t.createFrame);
          fx.eq(
            (lobby['rules']! as Map<String, Object?>).keys.toList()..sort(),
            <String>['blocks', 'capture_bonus', 'turn_seconds'],
            'section 28 rule 1: under 2026-10 the snapshot rules keep exactly '
            'their old keys (no "ruleset")',
          );
          for (final String key in <String>['placings', 'retired']) {
            fx.absent(lobby, key, 'a 2026-10 snapshot');
          }
          for (final Object? s in lobby['seats']! as List<Object?>) {
            fx.absent(
                s! as Map<String, Object?>, 'drought', 'a 2026-10 seat object');
          }
          await _startGame(t);
          final engine.RulesConfig rules = t.room.game!.config.rules;
          fx.eq(
            <bool>[
              rules.rollQueue,
              rules.homeBonus,
              rules.blocks,
              rules.yardRelease,
              rules.playOut,
            ],
            <bool>[true, true, false, false, false],
            'engine config under 2026-10: rollQueue and homeBonus on as '
            'today, blocks, yardRelease and playOut off',
          );
        }, ruleset: ruleset);
      });
    }

    test(
        'S2: ruleset 2026-11: snapshot rules.ruleset, drought 0 on every '
        'seat, placings and retired empty, engine yardRelease and playOut on',
        () async {
      await _withFixture('S2 2026-11 snapshot and config', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        final Map<String, Object?> lobby = _d(t.createFrame);
        fx.eq(
          (lobby['rules']! as Map<String, Object?>).keys.toList()..sort(),
          <String>['blocks', 'capture_bonus', 'ruleset', 'turn_seconds'],
          'rules in the create_room answer',
        );
        fx.eq((lobby['rules']! as Map<String, Object?>)['ruleset'], _v26,
            'rules.ruleset in the create_room answer');
        fx.eq((lobby['rules']! as Map<String, Object?>)['blocks'], false,
            'blocks stays false');
        fx.eq(lobby['placings'], <int>[], 'LOBBY snapshot placings');
        fx.eq(lobby['retired'], <int>[], 'LOBBY snapshot retired');
        await _startGame(t);
        final engine.RulesConfig rules = t.room.game!.config.rules;
        fx.eq(
          <bool>[
            rules.rollQueue,
            rules.homeBonus,
            rules.blocks,
            rules.yardRelease,
            rules.playOut,
          ],
          <bool>[true, true, false, true, true],
          'engine config of a 2026-11 game: yardRelease and playOut on, '
          'with rollQueue and homeBonus, blocks off',
        );
        final Map<String, Object?> snap = await _resume(t, 1);
        fx.eq((snap['rules']! as Map<String, Object?>)['ruleset'], _v26,
            'rules.ruleset in a PLAYING snapshot');
        fx.eq(snap['placings'], <int>[], 'PLAYING snapshot placings');
        fx.eq(snap['retired'], <int>[], 'PLAYING snapshot retired');
        for (final Object? s in snap['seats']! as List<Object?>) {
          final Map<String, Object?> seat = s! as Map<String, Object?>;
          fx.eq(seat['drought'], 0,
              'seat ${seat['seat']} drought at the start of a game');
        }
      });
    });

    test('S3: a client cannot pick the ruleset: rules.ruleset is BAD_FIELD',
        () async {
      for (final String? ruleset in <String?>[null, _v26]) {
        await _withFixture('S3 rules.ruleset on ${ruleset ?? 'absent'} server',
            (_Fixture fx) async {
          final WireTestClient c = await fx.connect();
          fx.send(c, 'create_room', <String, Object?>{
            'name': 'Host',
            'players': 2,
            'rules': <String, Object?>{'ruleset': _v25},
          });
          final Frame reply = await c.next();
          fx.eq(
              _code(fx, reply, 'create_room with rules.ruleset'),
              'BAD_FIELD',
              'section 13.4: a rules key other than the three is BAD_FIELD, '
                  'so a 2026-10 room cannot be asked for on any server');
          fx.eq(fx.registry.roomCount, 0, 'no room was created');
        }, ruleset: ruleset);
      }
    });

    test('S4: a rematch keeps the ruleset and the engine toggles', () async {
      await _withFixture('S4 rematch keeps 2026-11', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        _forceFinishingMove(t, 0);
        await t.step(0, 'move', <String, Object?>{'token': 3});
        fx.eq(t.room.state.name, RoomState.finished.name, 'the game ended');
        t.fx.send(t.c(0), 'rematch', <String, Object?>{});
        await t.syncAll(first: 0);
        fx.send(t.c(2), 'rematch', <String, Object?>{});
        for (final int s in <int>[2, 0]) {
          await drainUntil(t.c(s), 'turn',
              maxFrames: 14, perFrame: const Duration(seconds: 3));
        }
        fx.eq(t.room.state.name, RoomState.playing.name, 'the rematch started');
        final engine.RulesConfig rules = t.room.game!.config.rules;
        fx.eq(<bool>[rules.yardRelease, rules.playOut, rules.rollQueue],
            <bool>[true, true, true], 'engine toggles of the second game');
        final Map<String, Object?> snap = await _resume(t, 0);
        fx.eq((snap['rules']! as Map<String, Object?>)['ruleset'], _v26,
            'rules.ruleset after a rematch');
        fx.eq(snap['placings'], <int>[], 'second game placings');
        fx.eq(snap['retired'], <int>[], 'second game retired');
        for (final Object? s in snap['seats']! as List<Object?>) {
          fx.eq((s! as Map<String, Object?>)['drought'], 0,
              'second game drought');
        }
      });
    });
  });

  group('rule 1: the switch, real process (RULESET in the environment)', () {
    test('P1: a value that is not 2026-10 or 2026-11 stops the start',
        () async {
      final Directory root = await _packageRoot();
      for (final String bad in <String>['abc', '2026-13', '2026-11x']) {
        final int port = await _freePort();
        final Process process = await Process.start(
          Platform.resolvedExecutable,
          <String>['run', 'bin/server.dart'],
          workingDirectory: root.path,
          environment: _childEnvironment(<String, String>{
            'RULESET': bad,
            'PORT': '$port',
          }),
          includeParentEnvironment: false,
        );
        final Future<String> err =
            process.stderr.transform(utf8.decoder).join();
        final Future<String> out =
            process.stdout.transform(utf8.decoder).join();
        int? code;
        try {
          code = await process.exitCode.timeout(const Duration(seconds: 90));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          fail('RULESET="$bad" PORT=$port: bin/server.dart did not exit '
              'within 90 s; section 28 rule 1 says it stops at start');
        }
        final String errText = await err;
        final String outText = await out;
        expect(code, isNot(0),
            reason: 'RULESET="$bad" PORT=$port: expected a non-zero exit, '
                'got $code. stderr: $errText stdout: $outText');
        expect(errText, contains('RULESET'),
            reason: 'RULESET="$bad" PORT=$port: a line on stderr naming the '
                'variable. stderr: "$errText" stdout: "$outText"');
        expect(await _isListening(port), isFalse,
            reason: 'RULESET="$bad" PORT=$port: the port must never open');
      }
    }, timeout: const Timeout(Duration(seconds: 420)));

    for (final String? value in <String?>[null, '', _v25, _v26]) {
      test(
          'P2: RULESET=${jsonEncode(value)} starts and creates a room of '
          'that ruleset', () async {
        final Directory root = await _packageRoot();
        final int port = await _freePort();
        final Process process = await Process.start(
          Platform.resolvedExecutable,
          <String>['run', 'bin/server.dart'],
          workingDirectory: root.path,
          environment: _childEnvironment(<String, String>{
            if (value != null) 'RULESET': value,
            'PORT': '$port',
          }),
          includeParentEnvironment: false,
        );
        final StringBuffer out = StringBuffer();
        final StringBuffer err = StringBuffer();
        process.stdout.transform(utf8.decoder).listen(out.write);
        process.stderr.transform(utf8.decoder).listen(err.write);
        WireTestClient? client;
        try {
          bool exited = false;
          unawaited(process.exitCode.then((int _) => exited = true));
          final DateTime deadline =
              DateTime.now().add(const Duration(seconds: 90));
          while (!await _isListening(port)) {
            if (exited || DateTime.now().isAfter(deadline)) {
              fail('RULESET=${jsonEncode(value)} PORT=$port: the server did '
                  'not come up (exited=$exited). stderr: $err stdout: $out');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          client = await WireTestClient.connect(
            Uri(scheme: 'ws', host: '127.0.0.1', port: port, path: '/'),
          );
          client.send('create_room', <String, Object?>{
            'name': 'Proc',
            'players': 2,
          });
          await client.next();
          final Frame room = await client.next();
          expect(room['t'], 'room',
              reason: 'RULESET=${jsonEncode(value)}: create_room answered '
                  '${room['t']}: ${room['d']}');
          final Map<String, Object?> rules =
              _d(room)['rules']! as Map<String, Object?>;
          if (value == _v26) {
            expect(rules['ruleset'], _v26,
                reason: 'RULESET=2026-11: rules.ruleset in the snapshot; '
                    'got $rules');
          } else {
            expect(rules.containsKey('ruleset'), isFalse,
                reason: 'RULESET=${jsonEncode(value)} means 2026-10: the '
                    'rules.ruleset key must be absent; got $rules');
          }
        } finally {
          await client?.close();
          process.kill(ProcessSignal.sigterm);
          await process.exitCode.timeout(const Duration(seconds: 20),
              onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return process.exitCode;
          });
        }
      }, timeout: const Timeout(Duration(seconds: 240)));
    }
  });

  // =========================================================================
  // Rule 2: the yard release on the wire
  // =========================================================================
  group('rule 2: the yard release', () {
    test(
        'R1: ten non-6 rolls with every token in the yard: rolled release '
        'true with the releasable legal, then move with a face is '
        'ILLEGAL_MOVE, without one moved release true then turn', () async {
      final _Steer steer = _Steer.noSix(19);
      await _withFixture('R1 ten rolls to a release', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        final Map<int, List<Frame>> frames = await _playToRelease(t);
        for (final int seat in <int>[0, 2]) {
          fx.eq(
              _types(frames[seat]!),
              <String>['rolled'],
              'roll 19, the tenth for seat 0: a release leaves a move '
              'pending, so one rolled and nothing after it (seat $seat)');
        }
        final Map<String, Object?> rolled = _d(frames[0]!.single);
        final int face = rolled['value']! as int;
        fx.ok(face >= 1 && face <= 5, 'the drawn face is not a 6', rolled);
        fx.eq(rolled['k'], 19, 'k of the releasing roll');
        fx.eq(rolled['release'], true, 'rolled.release');
        fx.eq(rolled['legal'], <int>[0, 1, 2, 3],
            'legal is the releasable tokens, ascending');
        fx.eq(rolled['queue'], <int>[face],
            'queue holds the drawn face (section 21.1)');
        fx.absent(rolled, 'legal_by_face', 'a release roll');
        fx.eq(rolled['deadline_ms'], 45000, 'a full segment starts');

        // The snapshot of a release owed.
        fx.clock.advance(const Duration(seconds: 5));
        final Map<String, Object?> snap = await _resume(t, 2);
        final Map<String, Object?> turn = snap['turn']! as Map<String, Object?>;
        fx.eq(turn['seat'], 0, 'snapshot turn.seat');
        fx.eq(turn['phase'], 'await_move', 'snapshot turn.phase');
        fx.eq(turn['release'], true, 'snapshot turn.release');
        fx.eq(turn['legal'], <int>[0, 1, 2, 3], 'snapshot turn.legal');
        fx.eq(turn['queue'], <int>[face], 'snapshot turn.queue');
        fx.absent(turn, 'value', 'the snapshot turn of a release owed');
        fx.absent(turn, 'legal_by_face', 'the snapshot turn of a release owed');
        fx.eq(turn['deadline_ms'], 40000,
            'the segment restarted on the releasing rolled, 5 s ago');
        final List<Object?> seats = snap['seats']! as List<Object?>;
        fx.eq(
          <Object?>[
            for (final Object? s in seats)
              (s! as Map<String, Object?>)['drought'],
          ],
          <int>[0, 9],
          'drought: seat 0 back to 0 by the release (rule 11r), seat 2 at 9 '
          'after nine rolls',
        );
        await t.syncAll();

        // A face with a release owed is an illegal move, whatever it is.
        for (final int badFace in <int>[face, face == 1 ? 2 : 1, 6]) {
          final Map<int, List<Frame>> r = await t
              .step(0, 'move', <String, Object?>{'token': 0, 'face': badFace});
          _expectError(fx, r[0]!, 'ILLEGAL_MOVE',
              'move with face $badFace while a release is owed');
          fx.eq(r[2]!, <Frame>[], 'a rejected move tells nobody else');
        }
        // roll while a release is owed: a move is pending.
        final Map<int, List<Frame>> wrong =
            await t.step(0, 'roll', <String, Object?>{});
        _expectError(
            fx, wrong[0]!, 'WRONG_PHASE', 'roll while a release is owed');

        final int seqBefore = rolled['seq']! as int;
        final String id =
            fx.send(t.c(0), 'move', <String, Object?>{'token': 2});
        final Map<int, List<Frame>> moved = await t.syncAll(first: 0);
        for (final int seat in <int>[0, 2]) {
          fx.eq(
              _types(moved[seat]!),
              <String>['moved', 'turn'],
              'the release move then the same seat in await_move (the '
              'queued face $face has a legal move for the released token), '
              'seen by seat $seat');
        }
        final Map<String, Object?> m = _d(moved[0]!.first);
        fx.eq(m['seat'], 0, 'moved.seat');
        fx.eq(m['token'], 2, 'moved.token');
        fx.eq(m['from'], -1, 'moved.from');
        fx.eq(m['to'], 0, 'moved.to');
        fx.eq(m['captured'], <Object?>[], 'moved.captured');
        fx.eq(m['extra_roll'], false, 'moved.extra_roll');
        fx.eq(m['release'], true, 'moved.release');
        fx.absent(m, 'face', 'the moved frame of a release');
        fx.eq(m['seq'], seqBefore + 1, 'moved.seq follows rolled.seq');
        _expectReEchoed(fx, moved, 0, id, 'moved');
        final Map<String, Object?> next = _d(moved[0]!.last);
        fx.eq(next['seat'], 0, 'turn.seat after the release');
        fx.eq(next['phase'], 'await_move', 'turn.phase after the release');
        fx.eq(next['queue'], <int>[face], 'the face stays in the queue');
        fx.eq(next['deadline_ms'], 45000,
            'the release moved leaves a face to spend: segment restarts');
        fx.eq(next['seq'], seqBefore + 2, 'turn.seq');
        fx.absent(next, 'release', 'the turn after the release is spent');
      }, steer: steer);
    });

    test(
        'R2: the release leaves the queued face with no legal move: moved '
        'release true, turn_passed no_legal_move, turn for the next seat',
        () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('R2 release then a dead face', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        // Seat 2 holds a block on square 3: the released token at square 0
        // would have to land on it with the face 3. Blocks are a toggle of
        // the engine config; a room made through create_room never has them
        // on, so the position turns the toggle on in the forced state.
        _force(
          t,
          drought: <int>[9, 0, 0, 0],
          blocks: true,
          tokens: <int, List<int>>{
            2: <int>[29, 29, -1, -1],
          },
        );
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled = _d(r[0]!.single);
        fx.eq(rolled['release'], true, 'the tenth non-6 grants a release');
        fx.eq(rolled['legal'], <int>[0, 1, 2, 3], 'releasable tokens');
        final Map<int, List<Frame>> moved =
            await t.step(0, 'move', <String, Object?>{'token': 1});
        for (final int seat in <int>[0, 2]) {
          fx.eq(_types(moved[seat]!), <String>['moved', 'turn_passed', 'turn'],
              'seat $seat: the face 3 is blocked for the released token');
        }
        fx.eq(_d(moved[0]![0])['release'], true, 'moved.release');
        fx.eq(_d(moved[0]![0])['to'], 0, 'moved.to');
        fx.eq(_d(moved[0]![1])['reason'], 'no_legal_move', 'turn_passed');
        fx.eq(_d(moved[0]![2])['seat'], 2, 'turn for the next seat');
        fx.eq(_d(moved[0]![2])['phase'], 'await_roll', 'turn.phase');
      }, steer: steer);
    });

    test(
        'R3: the lapse (rule 14r): rolled release true legal [] then '
        'turn_passed no_legal_move and turn for the next seat; the record '
        'lists the lapse in releases', () async {
      final _Steer steer = _Steer.faces(<int>[4]);
      await _withFixture('R3 lapse', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        // Seat 2 holds a block on seat 0's entry square (progress 26 is
        // square 0). The engine only honours blocks when the toggle is on,
        // and a room made by create_room has it off (RULES rule 21), so the
        // forced position turns it on: the lapse is otherwise unreachable.
        _force(
          t,
          drought: <int>[9, 0, 0, 0],
          blocks: true,
          tokens: <int, List<int>>{
            2: <int>[26, 26, -1, -1],
          },
        );
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        for (final int seat in <int>[0, 2]) {
          fx.eq(_types(r[seat]!), <String>['rolled', 'turn_passed', 'turn'],
              'a lapse passes the turn like any pass (seat $seat)');
        }
        final Map<String, Object?> rolled = _d(r[0]!.first);
        fx.eq(rolled['release'], true, 'rolled.release on a lapse');
        fx.eq(rolled['legal'], <int>[], 'rolled.legal on a lapse');
        fx.eq(rolled['value'], 4, 'the drawn face is still recorded');
        fx.eq(
            rolled['queue'],
            <int>[],
            'section 21.3 rule 3: the queue is [] when the roll passed the '
            'turn');
        fx.eq(_d(r[0]![1])['reason'], 'no_legal_move', 'turn_passed.reason');
        fx.eq(_d(r[0]![1])['seat'], 0, 'turn_passed.seat');
        fx.eq(_d(r[0]![2])['seat'], 2, 'turn.seat');
        final Map<String, Object?> snap = await _resume(t, 2);
        final List<Object?> seats = snap['seats']! as List<Object?>;
        fx.eq((seats[0]! as Map<String, Object?>)['drought'], 0,
            'the drought starts again from 0 after a lapse (rule 14r)');

        // End the game and read the record.
        _force(t,
            currentSeat: 2,
            phase: 'awaitMove',
            queue: <int>[3],
            tokens: {
              0: <int>[-1, -1, -1, -1],
              2: <int>[57, 57, 57, 54],
            },
            releaseOwed: false,
            blocks: false);
        await t.step(2, 'move', <String, Object?>{'token': 3});
        final Map<String, Object?> rec = await _record(t);
        fx.eq(rec['releases'], <int>[1],
            'the lapse is a roll that granted a release: releases = [1]');
        fx.eq(rec['ruleset'], _v26, 'record.ruleset');
      }, steer: steer);
    });

    test(
        'R4: the timer spends a release on the lowest releasable token; the '
        'segment restarts on the releasing rolled', () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('R4 timer spends the release', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        fx.clock.advance(const Duration(seconds: 20));
        _force(t, drought: <int>[9, 0, 0, 0]);
        // _force restarted the segment; take the 20 s back so the roll
        // really arrives late in a segment.
        t.room.turnSegmentStartedAt =
            fx.clock.now.subtract(const Duration(seconds: 20));
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled = _d(r[0]!.single);
        fx.eq(rolled['release'], true, 'a release is granted');
        fx.eq(rolled['deadline_ms'], 45000,
            'the releasing rolled restarts the segment (20 s had run)');
        fx.clock.advance(const Duration(milliseconds: 44999));
        fx.server.runTurnExpiryOnce();
        fx.eq(<Frame>[for (final f in (await t.syncAll()).values) ...f],
            <Frame>[], '44 999 ms into the segment: the timer does not act');
        fx.clock.advance(const Duration(milliseconds: 1));
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> after = await t.syncAll();
        for (final int seat in <int>[0, 2]) {
          fx.eq(
              _types(after[seat]!),
              <String>['moved', 'turn'],
              'the timer spends the release then the face has a move '
              '(seat $seat)');
        }
        final Map<String, Object?> m = _d(after[0]!.first);
        fx.eq(m['by'], 'timer', 'moved.by');
        fx.eq(m['release'], true, 'moved.release');
        fx.eq(m['token'], 0, 'the lowest releasable token');
        fx.eq(m['from'], -1, 'moved.from');
        fx.eq(m['to'], 0, 'moved.to');
        fx.eq(m['captured'], <Object?>[], 'moved.captured');
        fx.eq(m['extra_roll'], false, 'moved.extra_roll');
        fx.absent(m, 'face', 'a release moved frame');
        fx.ok(!after[0]!.first.containsKey('re'),
            'a timer step answers no request', after[0]!.first);
        fx.eq(_d(after[0]!.last)['seat'], 0, 'turn.seat');
        fx.eq(_d(after[0]!.last)['deadline_ms'], 45000,
            'the release moved leaves a face: the segment restarts');
      }, steer: steer);
    });

    test('R5: the timer picks the lowest token that can be released', () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('R5 timer lowest releasable', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        _force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        // Token 0 is on the board in this forced position, so the
        // releasable tokens are 1, 2 and 3.
        _force(t, tokens: <int, List<int>>{
          0: <int>[5, -1, -1, -1],
        });
        fx.clock.advance(const Duration(seconds: 45));
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> after = await t.syncAll();
        final Frame moved = _ofType(after[2]!, 'moved').single;
        fx.eq(_d(moved)['token'], 1, 'the lowest releasable token is 1');
        fx.eq(_d(moved)['release'], true, 'moved.release');
        fx.eq(_d(moved)['by'], 'timer', 'moved.by');
      }, steer: steer);
    });

    test(
        'R6: a token that cannot be released is ILLEGAL_MOVE and the '
        'release stays owed', () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('R6 token not releasable', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        _force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        _force(t, tokens: <int, List<int>>{
          0: <int>[5, -1, -1, -1],
        });
        final Map<int, List<Frame>> bad =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        _expectError(fx, bad[0]!, 'ILLEGAL_MOVE',
            'a token on the track is not releasable');
        fx.eq(bad[2]!, <Frame>[], 'nobody else is told');
        final Map<int, List<Frame>> good =
            await t.step(0, 'move', <String, Object?>{'token': 1});
        fx.eq(_d(_ofType(good[0]!, 'moved').single)['release'], true,
            'the release is still owed after a rejected move');
      }, steer: steer);
    });

    test(
        'R7: the verify record gains ruleset, releases, placings, retired; '
        'the page shows one line next to each release roll', () async {
      final _Steer steer = _Steer.noSix(19);
      await _withFixture('R7 record and page', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        final Map<int, List<Frame>> frames = await _playToRelease(t);
        final int face = _d(frames[0]!.single)['value']! as int;
        await t.step(0, 'move', <String, Object?>{'token': 0});
        _force(t,
            currentSeat: 0,
            phase: 'awaitMove',
            queue: <int>[face],
            tokens: <int, List<int>>{
              0: <int>[57, 57, 57, 57 - face],
            },
            releaseOwed: false);
        final Map<int, List<Frame>> end =
            await t.step(0, 'move', <String, Object?>{'token': 3});
        fx.eq(_types(end[2]!), <String>['moved', 'game_over'],
            'a finishing move in a 2-seat game ends the game');
        final Map<String, Object?> rec = await _record(t);
        fx.eq(rec['ruleset'], _v26, 'record.ruleset');
        fx.eq(rec['releases'], <int>[19],
            'releases lists the roll numbers that granted a release');
        fx.eq(rec['placings'], <int>[0, 2], 'record.placings');
        fx.eq(rec['retired'], <int>[], 'record.retired');
        fx.eq(rec['winner'], 0, 'record.winner is placings[0]');
        final List<Object?> rolls = rec['rolls']! as List<Object?>;
        fx.eq(rolls.length, 19, 'the fair draw of every roll is unchanged');

        final String id = t.gameId!;
        for (final Map<String, String> page in <Map<String, String>>[
          <String, String>{'q': '?lang=en', 'line': _lineEn},
          <String, String>{'q': '?lang=ar', 'line': _lineAr},
        ]) {
          final Map<String, Object?> res = await _get(fx, '/v/$id${page['q']}');
          final String body = res['body']! as String;
          final String line = page['line']!;
          fx.eq(res['status'], 200, 'the page ${page['q']}');
          fx.eq(
              RegExp(RegExp.escape(line)).allMatches(body).length,
              1,
              'the page ${page['q']} shows the release line once, for the '
              'one release roll');
          final String reveal19 =
              (rolls[18]! as Map<String, Object?>)['reveal']! as String;
          // The record is embedded in the page too, so take the occurrence
          // of the reveal that sits inside an open table row.
          int at = -1;
          for (int from = 0;;) {
            final int hit = body.indexOf(reveal19, from);
            if (hit < 0) {
              break;
            }
            if (body.lastIndexOf('<tr', hit) > body.lastIndexOf('</tr>', hit)) {
              at = hit;
              break;
            }
            from = hit + 1;
          }
          fx.ok(at > 0, 'the page lists roll 19 in a table row');
          final int row19 = body.lastIndexOf('<tr', at);
          final int endTable = body.indexOf('</table>', at);
          final int lineAt = body.indexOf(line);
          fx.ok(
              lineAt > row19 && lineAt < endTable,
              'the line sits with roll 19 (after its row starts, before the '
              'table ends), not with an earlier roll',
              <String, Object?>{
                'row19': row19,
                'line': lineAt,
                'end': endTable
              });
        }
      }, steer: steer);
    });

    test('R8: a game with no release has releases [] and no page line',
        () async {
      await _withFixture('R8 record without a release', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        _forceFinishingMove(t, 0);
        await t.step(0, 'move', <String, Object?>{'token': 3});
        final Map<String, Object?> rec = await _record(t);
        fx.eq(rec['releases'], <int>[], 'releases is present and empty');
        fx.eq(rec['ruleset'], _v26, 'record.ruleset');
        for (final String lang in <String>['en', 'ar']) {
          final Map<String, Object?> res =
              await _get(fx, '/v/${t.gameId}?lang=$lang');
          final String body = res['body']! as String;
          fx.ok(!body.contains('11r'),
              'the $lang page shows no release line without a release');
        }
      });
    });

    test(
        'R9: two releases in one game: releases ascending, the page shows '
        'one line each, next to its own roll and not the roll between',
        () async {
      final _Steer steer = _Steer.faces(<int>[3, 4, 5]);
      await _withFixture('R9 two releases', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        _force(t, drought: <int>[9, 0, 0, 0]);
        // Roll 1, seat 0: a release, spent, then the queued 3 is played.
        final Map<int, List<Frame>> r1 =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(_d(r1[0]!.single)['release'], true, 'roll 1 grants a release');
        await t.step(0, 'move', <String, Object?>{'token': 0});
        final Map<int, List<Frame>> f1 =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        fx.eq(_types(f1[2]!), <String>['moved', 'turn'], 'the face is played');
        fx.eq(_d(f1[2]!.last)['seat'], 2, 'the turn goes to seat 2');
        // Roll 2, seat 2: a plain non-6 with every token in the yard.
        final Map<int, List<Frame>> r2 =
            await t.step(2, 'roll', <String, Object?>{});
        fx.eq(_types(r2[0]!), <String>['rolled', 'turn_passed', 'turn'],
            'roll 2 is no release (the drought is 0)');
        fx.absent(_d(r2[0]!.first), 'release', 'roll 2');
        // Roll 3, seat 0 again, every token back in the yard, drought 9.
        _force(t, drought: <int>[
          9,
          0,
          1,
          0
        ], tokens: <int, List<int>>{
          0: <int>[-1, -1, -1, -1],
        });
        final Map<int, List<Frame>> r3 =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(_d(r3[0]!.single)['release'], true, 'roll 3 grants a release');
        fx.eq(_d(r3[0]!.single)['k'], 3, 'it is roll 3');
        await t.step(0, 'move', <String, Object?>{'token': 1});
        await t.step(0, 'move', <String, Object?>{'token': 1});
        _forceFinishingMove(t, 2);
        final Map<int, List<Frame>> end =
            await t.step(2, 'move', <String, Object?>{'token': 3});
        fx.eq(_types(end[0]!), <String>['moved', 'game_over'], 'the game ends');
        final Map<String, Object?> rec = await _record(t);
        fx.eq(rec['releases'], <int>[1, 3],
            'releases: the roll numbers that granted one, ascending');
        fx.eq(rec['placings'], <int>[2, 0], 'record.placings');
        final List<Object?> rolls = rec['rolls']! as List<Object?>;
        fx.eq(rolls.length, 3, 'three rolls were drawn');
        for (final Map<String, String> page in <Map<String, String>>[
          <String, String>{'q': '?lang=en', 'line': _lineEn},
          <String, String>{'q': '?lang=ar', 'line': _lineAr},
        ]) {
          final Map<String, Object?> res =
              await _get(fx, '/v/${t.gameId}${page['q']}');
          final String body = res['body']! as String;
          final String line = page['line']!;
          final List<int> starts = <int>[
            for (final Object? r in rolls)
              _openRowStart(
                  body, (r! as Map<String, Object?>)['reveal']! as String),
          ];
          fx.ok(
              starts.every((int s) => s > 0) &&
                  starts[0] < starts[1] &&
                  starts[1] < starts[2],
              'the ${page['q']} page lists the three rolls in rows, in order',
              starts);
          final List<int> owners = <int>[];
          for (int from = 0;;) {
            final int hit = body.indexOf(line, from);
            if (hit < 0) {
              break;
            }
            owners.add(starts.lastIndexWhere((int s) => s <= hit) + 1);
            from = hit + 1;
          }
          fx.eq(
              owners,
              <int>[1, 3],
              'the ${page['q']} page: one release line per release roll, '
              'each after the row of its own roll and before the next one '
              '(roll number each line belongs to)');
        }
      }, steer: steer);
    });

    test(
        'R10: a release owed is the seat\'s alone; once spent a face is '
        'allowed again', () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('R10 release is the seat\'s alone',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        _force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        final Map<int, List<Frame>> roll2 =
            await t.step(2, 'roll', <String, Object?>{});
        _expectError(fx, roll2[2]!, 'NOT_YOUR_TURN',
            'roll by the other seat while a release is owed');
        final Map<int, List<Frame>> move2 =
            await t.step(2, 'move', <String, Object?>{'token': 0});
        _expectError(fx, move2[2]!, 'NOT_YOUR_TURN',
            'move by the other seat while a release is owed');
        fx.eq(roll2[0]! + move2[0]!, <Frame>[],
            'the seat that owes the release is told nothing of it');
        await t.step(0, 'move', <String, Object?>{'token': 1});
        final Map<int, List<Frame>> played =
            await t.step(0, 'move', <String, Object?>{'token': 1, 'face': 3});
        fx.eq(_types(played[2]!), <String>['moved', 'turn'],
            'with the release spent the queued face is played as ever');
        final Map<String, Object?> m = _d(played[2]!.first);
        fx.eq(<Object?>[m['token'], m['from'], m['to'], m['face']],
            <int>[1, 0, 3, 3], 'moved by the face');
        fx.absent(m, 'release', 'the moved frame of an ordinary move');
        fx.eq(_d(played[2]!.last)['seat'], 2, 'the turn goes on');
      }, steer: steer);
    });

    test(
        'R11: a face sent with a release owed: ILLEGAL_MOVE for any integer, '
        'BAD_FIELD when it is not one (ruling of 2026-11-16)', () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('R11 face with a release owed', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        _force(t, drought: <int>[9, 0, 0, 0]);
        await t.step(0, 'roll', <String, Object?>{});
        for (final int face in <int>[0, 9, -1, 1, 3, 6, 7]) {
          final Map<int, List<Frame>> r = await t
              .step(0, 'move', <String, Object?>{'token': 0, 'face': face});
          _expectError(fx, r[0]!, 'ILLEGAL_MOVE',
              'move with the integer face $face while a release is owed');
          fx.eq(r[2]!, <Frame>[], 'a rejected move tells nobody else');
        }
        for (final Object bad in <Object>['3', 1.5, true]) {
          final Map<int, List<Frame>> r = await t
              .step(0, 'move', <String, Object?>{'token': 0, 'face': bad});
          _expectError(
              fx,
              r[0]!,
              'BAD_FIELD',
              'move with the non-integer face ${_j(bad)} while a release is '
                  'owed');
        }
        final Map<int, List<Frame>> ok =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        fx.eq(_d(_ofType(ok[0]!, 'moved').single)['release'], true,
            'the release was still owed after every rejection');
      }, steer: steer);
    });

    test(
        'N1: a roll with a token on the board carries no release and keeps '
        'legal_by_face', () async {
      final _Steer steer = _Steer.faces(<int>[3]);
      await _withFixture('N1 ordinary roll under 2026-11', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        _force(t, tokens: <int, List<int>>{
          0: <int>[5, -1, -1, -1],
        });
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(_types(r[2]!), <String>['rolled'], 'a move is pending');
        final Map<String, Object?> rolled = _d(r[2]!.single);
        fx.absent(rolled, 'release', 'an ordinary rolled');
        fx.eq(rolled['legal'], <int>[0], 'legal');
        fx.eq(rolled['queue'], <int>[3], 'queue');
        fx.eq(
            rolled['legal_by_face'],
            <Object?>[
              <String, Object?>{
                'face': 3,
                'tokens': <int>[0],
              },
            ],
            'legal_by_face is still sent when no release is owed');
        final Map<String, Object?> snap = await _resume(t, 2);
        final Map<String, Object?> turn = snap['turn']! as Map<String, Object?>;
        fx.absent(turn, 'release', 'a snapshot turn with no release owed');
      }, steer: steer);
    });
  });

  // =========================================================================
  // Rule 3: places on the wire
  // =========================================================================
  group('rule 3: places', () {
    test(
        'P3: three seats, one finishes: moved, seat_finished, turn for the '
        'next playing seat; play goes on; the finished seat is told '
        'everything and cannot act; the game ends with game_over placings '
        'of three and no second seat_finished', () async {
      await _withFixture('P3 three seats one finishes', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _forceFinishingMove(t, 0);
        final String id =
            fx.send(t.c(0), 'move', <String, Object?>{'token': 3});
        final Map<int, List<Frame>> r = await t.syncAll(first: 0);
        for (final int seat in <int>[0, 1, 2]) {
          fx.eq(_types(r[seat]!), <String>['moved', 'seat_finished', 'turn'],
              'seat $seat: the fourth token home, the place, the next turn');
        }
        final Map<String, Object?> sf = _d(r[0]![1]);
        fx.eq(sf['seat'], 0, 'seat_finished.seat');
        fx.eq(sf['place'], 1, 'seat_finished.place');
        fx.eq(_d(r[0]!.first)['extra_roll'], false,
            'the finishing move owes no roll (rule 33p)');
        fx.eq(_d(r[0]!.last)['seat'], 1, 'turn.seat is the next playing seat');
        fx.eq(sf['seq'], (_d(r[0]!.first)['seq']! as int) + 1,
            'seat_finished.seq follows moved.seq');
        fx.eq(_d(r[0]!.last)['seq'], (sf['seq']! as int) + 1, 'turn.seq');
        _expectSameOnEverySeat(fx, r, 'the finishing move');
        _expectReEchoed(fx, r, 0, id, 'moved');
        fx.ok(!r[0]![1].containsKey('re') || r[0]![1]['re'] == id,
            'seat_finished is a push', r[0]![1]);

        // The finished seat cannot act.
        final Map<int, List<Frame>> roll0 =
            await t.step(0, 'roll', <String, Object?>{});
        _expectError(
            fx, roll0[0]!, 'NOT_YOUR_TURN', 'roll from a finished seat');
        final Map<int, List<Frame>> move0 =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        _expectError(
            fx, move0[0]!, 'NOT_YOUR_TURN', 'move from a finished seat');

        // Play goes on, and seat 0 still receives every frame.
        final Map<int, List<Frame>> roll1 =
            await t.step(1, 'roll', <String, Object?>{});
        fx.ok(_ofType(roll1[0]!, 'rolled').length == 1,
            'the finished seat receives the next roll', roll1[0]);
        _expectSameOnEverySeat(fx, roll1, 'seat 1 rolls');

        final Map<String, Object?> snap = await _resume(t, 2);
        fx.eq(snap['placings'], <int>[0], 'snapshot placings');
        fx.eq(snap['retired'], <int>[], 'snapshot retired');
        fx.ok((snap['turn']! as Map<String, Object?>)['seat'] != 0,
            'a finished seat is never turn.seat', snap['turn']);
        fx.eq(snap['state'], 'PLAYING', 'the game goes on');

        // The second seat finishes: the game ends, no seat_finished.
        _force(t,
            currentSeat: 1,
            phase: 'awaitMove',
            queue: <int>[3],
            tokens: <int, List<int>>{
              1: <int>[57, 57, 57, 54],
            },
            releaseOwed: false,
            sixes: 0);
        await t.syncAll();
        final Map<int, List<Frame>> end =
            await t.step(1, 'move', <String, Object?>{'token': 3});
        for (final int seat in <int>[0, 1, 2]) {
          fx.eq(
              _types(end[seat]!),
              <String>['moved', 'game_over'],
              'seat $seat: when the move ends the game there is no '
              'seat_finished and no turn');
        }
        final Map<String, Object?> over = _d(end[0]!.last);
        fx.eq(over['placings'], <int>[0, 1, 2],
            'game_over.placings: the last seat standing included');
        fx.eq(over['retired'], <int>[], 'game_over.retired');
        fx.eq(over['winner'], 0, 'winner is placings[0]');
        final Map<String, Object?> fin = await _resume(t, 0);
        fx.eq(fin['state'], 'FINISHED', 'the room is FINISHED');
        fx.eq(fin['placings'], <int>[0, 1, 2], 'FINISHED snapshot placings');
        fx.eq(fin['winner'], 0, 'FINISHED snapshot winner');
        final Map<String, Object?> rec = await _record(t);
        fx.eq(rec['placings'], <int>[0, 1, 2], 'record.placings');
        fx.eq(rec['retired'], <int>[], 'record.retired');
      });
    });

    test(
        'P4: two seats end exactly as under 2026-10 plus placings and '
        'retired', () async {
      final Map<String, List<Frame>> byRuleset = <String, List<Frame>>{};
      for (final String ruleset in <String>[_v25, _v26]) {
        await _withFixture('P4 two seats $ruleset', (_Fixture fx) async {
          final _Table t = await _openTable(fx, players: 2);
          await _startGame(t);
          _forceFinishingMove(t, 0);
          final Map<int, List<Frame>> end =
              await t.step(0, 'move', <String, Object?>{'token': 3});
          fx.eq(_types(end[2]!), <String>['moved', 'game_over'],
              'a two-seat finish under $ruleset');
          byRuleset[ruleset] = end[2]!;
        }, ruleset: ruleset);
      }
      final _Fixture shell = await _Fixture.start('P4 compare', ruleset: null);
      try {
        shell.eq(_d(byRuleset[_v26]![0]), _d(byRuleset[_v25]![0]),
            'the moved frame of the finishing move is byte-identical');
        final Map<String, Object?> old = _d(byRuleset[_v25]![1]);
        final Map<String, Object?> now = _d(byRuleset[_v26]![1]);
        shell.absent(old, 'placings', 'a 2026-10 game_over');
        shell.absent(old, 'retired', 'a 2026-10 game_over');
        final Map<String, Object?> trimmed = Map<String, Object?>.of(now)
          ..remove('placings')
          ..remove('retired');
        shell.eq(
            trimmed.keys.toList()..sort(),
            old.keys.toList()..sort(),
            'game_over keys under 2026-11 are the old keys plus placings '
            'and retired');
        shell.eq(now['winner'], 0, 'winner');
        shell.eq(now['placings'], <int>[0, 2], 'placings with two seats');
        shell.eq(now['retired'], <int>[], 'retired');
        shell.eq(now['seq'], old['seq'], 'seq');
      } finally {
        await shell.close();
      }
    });

    test(
        'P5: a finished seat that leaves is answered with presence and '
        'nothing in the game changes; one that drops for over 120 s is never '
        'retired', () async {
      await _withFixture('P5 finished seat leaves and drops',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _forceFinishingMove(t, 0);
        await t.step(0, 'move', <String, Object?>{'token': 3});

        final String id = fx.send(t.c(0), 'leave_room', <String, Object?>{});
        final Map<int, List<Frame>> r = await t.syncAll(first: 0);
        fx.eq(_types(r[0]!), <String>['presence'],
            'section 4: the leaver is answered by presence');
        fx.eq(r[0]!.single['re'], id, 'the leaver\'s presence carries re');
        fx.eq(_d(r[0]!.single)['seat'], 0, 'presence.seat');
        fx.eq(_d(r[0]!.single)['connected'], false, 'presence.connected');
        fx.eq(_types(r[1]!), <String>['presence'], 'seat 1 is told');
        fx.eq(_types(r[2]!), <String>['presence'], 'seat 2 is told');

        // 121 s without a socket: a finished seat is never retired.
        t.seats[0]!.up = false;
        for (int i = 0; i < 4; i++) {
          fx.clock.advance(const Duration(seconds: 31));
          _freshSegment(t);
          fx.server.runTurnExpiryOnce();
          final Map<int, List<Frame>> quiet = await t.syncAll();
          fx.eq(<Frame>[for (final List<Frame> l in quiet.values) ...l],
              <Frame>[], 'sweep ${i + 1} at ${31 * (i + 1)} s: nothing');
        }
        final Map<String, Object?> snap = await _resume(t, 1);
        fx.eq(snap['retired'], <int>[], 'a finished seat is not retired');
        fx.eq(snap['placings'], <int>[0], 'its place stands');
      });
    });

    test(
        'P6: a finished seat is skipped in the turn order: after the seat '
        'before it, the turn goes to the next playing seat', () async {
      await _withFixture('P6 finished seat skipped', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _forceFinishingMove(t, 0);
        await t.step(0, 'move', <String, Object?>{'token': 3});
        _force(t,
            currentSeat: 2,
            phase: 'awaitMove',
            queue: <int>[1],
            tokens: <int, List<int>>{
              2: <int>[57, 57, 57, 54],
            },
            releaseOwed: false,
            sixes: 0);
        await t.syncAll();
        final Map<int, List<Frame>> r =
            await t.step(2, 'move', <String, Object?>{'token': 3});
        for (final int seat in <int>[0, 1, 2]) {
          fx.eq(_types(r[seat]!), <String>['moved', 'turn'],
              'seat $seat: no extra roll, so the turn moves on');
          fx.eq(_d(r[seat]!.last)['seat'], 1,
              'seat $seat: the turn skips the finished seat 0');
          fx.eq(_d(r[seat]!.last)['phase'], 'await_roll', 'turn.phase');
          fx.eq(_d(r[seat]!.last)['deadline_ms'], 45000, 'turn.deadline_ms');
        }
      });
    });

    test(
        'P7: a finished seat that is dropped and resumes sees its place in '
        'the snapshot and still cannot act', () async {
      await _withFixture('P7 finished seat resumes', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _forceFinishingMove(t, 0);
        await t.step(0, 'move', <String, Object?>{'token': 3});
        await _drop(t, 0);
        await t.syncAll();
        final Map<String, Object?> snap = await _resume(t, 0);
        fx.eq(snap['placings'], <int>[0], 'its place after the resume');
        fx.eq(snap['retired'], <int>[], 'it is not retired');
        fx.ok((snap['turn']! as Map<String, Object?>)['seat'] != 0,
            'a finished seat is never turn.seat', snap['turn']);
        for (final String type in <String>['roll', 'move']) {
          fx.send(
              t.c(0),
              type,
              type == 'move'
                  ? <String, Object?>{'token': 0}
                  : <String, Object?>{});
          final List<Frame> got = await _flush(fx, t.c(0));
          _expectError(fx, got, 'NOT_YOUR_TURN', '$type from a finished seat');
        }
      });
    });
  });

  // =========================================================================
  // Rule 4: retiring a seat
  // =========================================================================
  group('rule 4: left', () {
    test(
        'L1: leave_room from a playing seat that is not on turn: '
        'seat_retired left, re to the leaver, play goes on', () async {
      await _withFixture('L1 leave, three seats', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _force(t, tokens: <int, List<int>>{
          2: <int>[5, 20, 57, -1],
        });
        final int before = t.room.seq;
        final String id = fx.send(t.c(2), 'leave_room', <String, Object?>{});
        final Frame own = await t.c(2).next();
        fx.eq(
            own['t'], 'seat_retired', 'the leaver is answered by seat_retired');
        fx.eq(own['re'], id, 'the leaver\'s copy carries re');
        fx.eq(_d(own)['seat'], 2, 'seat_retired.seat');
        fx.eq(_d(own)['reason'], 'left', 'seat_retired.reason');
        fx.eq(_d(own)['host_seat'], 0, 'seat_retired.host_seat');
        fx.eq(_d(own)['seq'], before + 1, 'seat_retired.seq');
        t.seats[2]!.up = false;
        for (final int seat in <int>[0, 1]) {
          final List<Frame> got = await _flush(fx, t.c(seat));
          fx.eq(
              _types(got),
              <String>['seat_retired'],
              'seat $seat: seat_retired and nothing more (the seat was not '
              'to act)');
          fx.eq(_d(got.single), _d(own), 'same data for everyone');
          fx.ok(!got.single.containsKey('re'), 'others get no re', got.single);
        }
        final Map<int, List<Frame>> roll =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(_ofType(roll[1]!, 'rolled').length, 1,
            'play goes on with the two seats left');
        final Map<String, Object?> snap = await _resume(t, 1);
        fx.eq(snap['retired'], <int>[2], 'snapshot retired');
        final Map<String, Object?> seat2 = (snap['seats']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((Map<String, Object?> s) => s['seat'] == 2);
        fx.eq(
            seat2['tokens'],
            <int>[-1, -1, 57, -1],
            'a retired seat stays seated with its tokens as the engine left '
            'them: off the board to the yard, home tokens stay home');

        // A retired seat may resume and watch; it never acts.
        final Map<String, Object?> watch = await _resume(t, 2);
        fx.eq(watch['retired'], <int>[2], 'the retired seat resumes');
        for (final String type in <String>['roll', 'move']) {
          fx.send(
              t.c(2),
              type,
              type == 'move'
                  ? <String, Object?>{'token': 0}
                  : <String, Object?>{});
          final List<Frame> got = await _flush(fx, t.c(2));
          _expectError(fx, got, 'NOT_YOUR_TURN', '$type from a retired seat');
        }
      });
    });

    test(
        'L2: the host leaves on its own turn: seat_retired with the new '
        'host_seat, then turn for the next playing seat', () async {
      await _withFixture('L2 host leaves on turn', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        // Seat 0 holds the pre of its opening turn (section 35 item 1), so
        // its leave publishes that roll first (item 3).
        final String id = fx.send(t.c(0), 'leave_room', <String, Object?>{});
        final List<Frame> mine = await _flush(fx, t.c(0));
        final Frame own = mine.firstWhere((Frame f) => f['t'] == 'seat_retired',
            orElse: () => fx.fail('leaver answered by seat_retired',
                actual: _types(mine)));
        fx.eq(own['re'], id, 're');
        fx.eq(_d(own)['reason'], 'left', 'reason');
        fx.eq(_d(own)['host_seat'], 1,
            'the host left: host_seat becomes the lowest seat still playing');
        t.seats[0]!.up = false;
        for (final int seat in <int>[1, 2]) {
          final List<Frame> got = await _flush(fx, t.c(seat));
          final int r =
              _expectForcedRollFirst(fx, got, 0, 'left', 'L2 seat $seat');
          fx.eq(_d(got[r])['host_seat'], 1, 'seat_retired.host_seat');
          final Frame last = got.lastWhere((Frame f) => f['t'] == 'turn',
              orElse: () => fx.fail('seat $seat: a turn for seat 1',
                  actual: _types(got)));
          fx.eq(_d(last)['seat'], 1, 'turn.seat');
          fx.eq(_d(last)['phase'], 'await_roll', 'turn.phase');
          fx.eq(_d(last)['deadline_ms'], 45000, 'turn.deadline_ms');
          fx.ok(got.length - r <= 2,
              'after the retire at most the turn for seat 1', _types(got));
        }
        fx.eq(_types(mine).where((Object? x) => x == 'seat_retired').length, 1,
            'the leaver gets one seat_retired');
        final Map<String, Object?> snap = await _resume(t, 2);
        fx.eq(snap['host_seat'], 1, 'snapshot host_seat');
      });
    });

    test(
        'L3: with two seats the leaver is retired and the other wins: '
        'seat_retired, game_over, then player_left for the retired seat',
        () async {
      await _withFixture('L3 leave, two seats', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        final String id = fx.send(t.c(2), 'leave_room', <String, Object?>{});
        final Frame own = await t.c(2).next();
        fx.eq(own['t'], 'seat_retired', 'leaver answered by seat_retired');
        fx.eq(own['re'], id, 're');
        t.seats[2]!.up = false;
        final List<Frame> got = await _flush(fx, t.c(0));
        fx.eq(_types(got), <String>['seat_retired', 'game_over', 'player_left'],
            'seat_retired, game_over, then the retired seat is freed');
        final int seq = _d(got[0])['seq']! as int;
        fx.eq(_d(got[0])['reason'], 'left', 'reason');
        fx.eq(_d(got[1])['winner'], 0, 'the other seat wins');
        fx.eq(_d(got[1])['placings'], <int>[0],
            'the last seat standing takes first place');
        fx.eq(_d(got[1])['retired'], <int>[2], 'retired');
        fx.eq(_d(got[1])['seq'], seq + 1, 'game_over.seq');
        fx.eq(_d(got[2])['seat'], 2, 'player_left.seat');
        fx.eq(_d(got[2])['host_seat'], 0, 'player_left.host_seat');
        fx.eq(_d(got[2])['seq'], seq + 2, 'player_left.seq, its own');
        final Map<String, Object?> snap = await _resume(t, 0);
        fx.eq(snap['state'], 'FINISHED', 'the room is FINISHED');
        fx.eq(
            (snap['seats']! as List<Object?>)
                .cast<Map<String, Object?>>()
                .map((Map<String, Object?> s) => s['seat'])
                .toList(),
            <int>[0],
            'the freed seat is gone from seats');
        final WireTestClient stale = await fx.connect();
        fx.send(stale, 'resume', <String, Object?>{
          'code': t.code,
          'seat_token': t.token(2),
        });
        fx.eq(_code(fx, await stale.next(), 'resume of a freed seat'),
            'BAD_SEAT_TOKEN', 'the freed seat\'s token names no seat');
        final Map<String, Object?> rec = await _record(t);
        fx.eq(rec['placings'], <int>[0], 'record.placings');
        fx.eq(rec['retired'], <int>[2], 'record.retired');
      });
    });

    test(
        'L4: the host retires: host_seat is the lowest seat still playing, '
        'not the lowest connected one', () async {
      await _withFixture('L4 host leaves, seat 1 finished',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 4);
        await _startGame(t);
        _forceFinishingMove(t, 1);
        await t.step(1, 'move', <String, Object?>{'token': 3});
        final String id = fx.send(t.c(0), 'leave_room', <String, Object?>{});
        final Frame own = await t.c(0).next();
        fx.eq(own['t'], 'seat_retired', 'the host is answered by seat_retired');
        fx.eq(own['re'], id, 're');
        fx.eq(
            _d(own)['host_seat'],
            2,
            'seat 1 is connected but finished; seat 2 is the lowest seat '
            'still playing');
        t.seats[0]!.up = false;
        for (final int seat in <int>[1, 2, 3]) {
          final List<Frame> got = await _flush(fx, t.c(seat));
          fx.eq(_types(got), <String>['seat_retired'],
              'seat $seat: seat 2 is on turn, nothing more');
          fx.eq(_d(got.single)['host_seat'], 2, 'seat $seat host_seat');
        }
        final Map<String, Object?> snap = await _resume(t, 3);
        fx.eq(snap['host_seat'], 2, 'snapshot host_seat');
        fx.eq(snap['placings'], <int>[1], 'placings');
        fx.eq(snap['retired'], <int>[0], 'retired');
      });
    });

    test(
        'L5: a seat that leaves in the middle of its move: seat_retired, '
        'then await_roll for the next playing seat on a full segment',
        () async {
      await _withFixture('L5 leave while a move is pending',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _force(t,
            currentSeat: 1,
            phase: 'awaitMove',
            queue: <int>[3],
            tokens: <int, List<int>>{
              1: <int>[10, -1, -1, -1],
            },
            releaseOwed: false,
            sixes: 0);
        fx.clock.advance(const Duration(seconds: 30));
        fx.send(t.c(1), 'leave_room', <String, Object?>{});
        final Frame own = await t.c(1).next();
        fx.eq(own['t'], 'seat_retired', 'the leaver is answered');
        t.seats[1]!.up = false;
        for (final int seat in <int>[0, 2]) {
          final List<Frame> got = await _flush(fx, t.c(seat));
          fx.eq(_types(got), <String>['seat_retired', 'turn'],
              'seat $seat: the retired seat was to act');
          fx.eq(_d(got.last)['seat'], 2, 'turn.seat');
          fx.eq(_d(got.last)['phase'], 'await_roll', 'turn.phase');
          fx.eq(_d(got.last)['deadline_ms'], 45000,
              'a new turn starts a full segment, not what was left');
          fx.eq(_d(got.last)['queue'], <int>[], 'the leaver\'s faces are gone');
        }
        final Map<String, Object?> snap = await _resume(t, 0);
        final Map<String, Object?> seat1 = (snap['seats']! as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((Map<String, Object?> s) => s['seat'] == 1);
        fx.eq(seat1['tokens'], <int>[-1, -1, -1, -1],
            'the token on the board went back to the yard');
      });
    });
  });

  group('rule 4: absent', () {
    test(
        'A1: a dropped seat is retired at 120 000 ms and not at 119 999 ms '
        '(three seats)', () async {
      await _withFixture('A1 absent 120 s', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        fx.clock.advance(const Duration(seconds: 60));
        final Frame presence = await _drop(t, 2);
        final int seq = _d(presence)['seq']! as int;
        await t.syncAll();
        fx.clock.advance(const Duration(milliseconds: 119999));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> early = await t.syncAll();
        fx.eq(<Frame>[for (final List<Frame> l in early.values) ...l],
            <Frame>[], 'at 119 999 ms the seat is still in the game');
        fx.clock.advance(const Duration(milliseconds: 1));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> due = await t.syncAll();
        for (final int seat in <int>[0, 1]) {
          fx.eq(_types(due[seat]!), <String>['seat_retired'],
              'seat $seat at 120 000 ms');
          fx.eq(
              _d(due[seat]!.single),
              <String, Object?>{
                'seat': 2,
                'reason': 'absent',
                'host_seat': 0,
                'seq': seq + 1,
              },
              'seat_retired data');
          fx.ok(!due[seat]!.single.containsKey('re'),
              'a sweep answers no request', due[seat]);
        }
        final Map<String, Object?> snap = await _resume(t, 1);
        fx.eq(snap['retired'], <int>[2], 'snapshot retired');
        fx.eq(
            (snap['seats']! as List<Object?>)
                .cast<Map<String, Object?>>()
                .singleWhere(
                    (Map<String, Object?> s) => s['seat'] == 2)['connected'],
            false,
            'a retired seat stays in seats, connected as it is');
      });
    });

    test(
        'A2: a resume at 119 s resets the count; a later drop starts a new '
        'one', () async {
      await _withFixture('A2 resume resets the absent count',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 119));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        fx.eq(<Frame>[for (final f in (await t.syncAll()).values) ...f],
            <Frame>[], 'at 119 s nothing happens');
        await _resume(t, 2);
        final Map<int, List<Frame>> back = await t.syncAll();
        fx.eq(_types(back[0]!), <String>['presence'],
            'the others are told the seat is back');
        fx.clock.advance(const Duration(seconds: 2));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        fx.eq(
            <Frame>[for (final f in (await t.syncAll()).values) ...f],
            <Frame>[],
            'at 121 s after the first drop the seat is connected: '
            'nothing happens');
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(milliseconds: 119999));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        fx.eq(
            <Frame>[for (final f in (await t.syncAll()).values) ...f],
            <Frame>[],
            '119 999 ms after the second drop: the first drop no '
            'longer counts');
        fx.clock.advance(const Duration(milliseconds: 1));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> due = await t.syncAll();
        fx.eq(_types(due[0]!), <String>['seat_retired'],
            '120 000 ms after the second drop');
        fx.eq(_d(due[0]!.single)['reason'], 'absent', 'reason');
      });
    });

    test(
        'A3: the absent seat is the host and on turn: host_seat moves to '
        'the lowest playing seat, then turn for the next playing seat',
        () async {
      await _withFixture('A3 absent host on turn', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 0);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> due = await t.syncAll();
        // Seat 0 was sent the pre of its opening turn before it dropped
        // (section 35 items 3 and 7(a)): that roll is published first.
        for (final int seat in <int>[1, 2]) {
          final List<Frame> got = due[seat]!;
          final int r =
              _expectForcedRollFirst(fx, got, 0, 'absent', 'A3 seat $seat');
          fx.eq(_d(got[r])['host_seat'], 1,
              'seat_retired.host_seat after the change');
          final Frame last = got.lastWhere((Frame f) => f['t'] == 'turn',
              orElse: () => fx.fail('seat $seat: a turn for seat 1',
                  actual: _types(got)));
          fx.eq(_d(last)['seat'], 1, 'turn.seat');
          fx.eq(_d(last)['phase'], 'await_roll', 'turn.phase');
          fx.ok(got.length - r <= 2,
              'after the retire at most the turn for seat 1', _types(got));
        }
      });
    });

    test('A4: with two seats the absent one is retired and the other wins',
        () async {
      await _withFixture('A4 absent, two seats', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> due = await t.syncAll();
        fx.eq(
            _types(due[0]!),
            <String>['seat_retired', 'game_over', 'player_left'],
            'the absent seat is retired, the game ends, the seat is freed');
        fx.eq(_d(due[0]![1])['winner'], 0, 'winner');
        fx.eq(_d(due[0]![1])['placings'], <int>[0], 'placings');
        fx.eq(_d(due[0]![1])['retired'], <int>[2], 'retired');
      });
    });

    test('A5: under 2026-10 a seat gone for two minutes is never retired',
        () async {
      await _withFixture('A5 old ruleset absent seat', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 125));
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> after = await t.syncAll();
        for (final List<Frame> frames in after.values) {
          fx.ok(_ofType(frames, 'seat_retired').isEmpty,
              'section 28 applies to 2026-11 rooms only', frames);
        }
        final WireTestClient c = t.c(0);
        fx.send(c, 'leave_room', <String, Object?>{});
        final List<Frame> r = await _flush(fx, c);
        fx.eq(_types(r), <String>['presence'],
            'under 2026-10 leave_room in PLAYING is answered by presence');
      }, ruleset: _v25);
    });

    test(
        'A6: two seats gone for the same 120 s: both retired in one sweep, '
        'one game_over, one player_left each, in retirement order', () async {
      await _withFixture('A6 two absent seats', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 1);
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final List<Frame> got = (await t.syncAll())[0]!;
        fx.eq(
            _types(got),
            <String>[
              'seat_retired',
              'seat_retired',
              'game_over',
              'player_left',
              'player_left',
            ],
            'both seats retired, the game ends once, both seats freed');
        final List<int> order = <int>[
          _d(got[0])['seat']! as int,
          _d(got[1])['seat']! as int,
        ];
        fx.eq(<int>[...order]..sort(), <int>[1, 2], 'the two seats');
        fx.eq(<Object?>[_d(got[0])['reason'], _d(got[1])['reason']],
            <String>['absent', 'absent'], 'reasons');
        fx.eq(_d(got[2])['retired'], order,
            'game_over.retired is in retirement order');
        fx.eq(_d(got[2])['placings'], <int>[0], 'placings');
        fx.eq(_d(got[2])['winner'], 0, 'winner');
        fx.eq(<Object?>[_d(got[3])['seat'], _d(got[4])['seat']], order,
            'player_left follows the retirement order');
        final int seq = _d(got[0])['seq']! as int;
        fx.eq(<Object?>[for (final Frame f in got) _d(f)['seq']],
            <int>[seq, seq + 1, seq + 2, seq + 3, seq + 4], 'seq, one each');
        final int after = t.room.seq;
        fx.clock.advance(const Duration(seconds: 130));
        fx.server.runTurnExpiryOnce();
        fx.eq(<Frame>[for (final f in (await t.syncAll()).values) ...f],
            <Frame>[], 'a later sweep adds nothing to a finished game');
        fx.eq(t.room.seq, after, 'no frame was numbered');
      });
    });

    test(
        'A7: both seats of a two-seat game gone for 120 s: one is retired, '
        'the other takes the place and is never retired', () async {
      await _withFixture('A7 both seats absent', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        await _dropMany(t, <int>[0, 2]);
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        fx.eq(t.room.state.name, RoomState.finished.name,
            'the first retirement ends the game');
        final List<int> placings = t.room.game!.placings;
        final List<int> retired = t.room.game!.retired;
        fx.eq(placings.length, 1, 'one placing');
        fx.eq(retired.length, 1, 'one retired seat, not two');
        fx.eq(<int>[...placings, ...retired]..sort(), <int>[0, 2],
            'every seat is either placed or retired');
        final int after = t.room.seq;
        fx.clock.advance(const Duration(seconds: 130));
        fx.server.runTurnExpiryOnce();
        fx.eq(t.room.seq, after, 'a later sweep retires nobody else');
        fx.eq(t.room.game!.retired, retired, 'the retired list is unchanged');
      });
    });

    test(
        'A8: a retired absent seat that comes back and drops again is not '
        'retired a second time', () async {
      await _withFixture('A8 retired seat drops again', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        await t.syncAll();
        final Map<String, Object?> back = await _resume(t, 2);
        fx.eq(back['retired'], <int>[2], 'it comes back to watch');
        await t.syncAll();
        await _drop(t, 2);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 300));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        fx.eq(<Frame>[for (final f in (await t.syncAll()).values) ...f],
            <Frame>[], 'nothing happens: the seat is already retired');
        fx.eq(t.room.game!.retired, <int>[2], 'retired is unchanged');
      });
    });

    test(
        'A9: two seats gone past 120 s, the first on turn, in one sweep: '
        'seat_retired, the turn the engine gives, seat_retired, the next '
        'playing seat\'s turn, each with the next seq', () async {
      await _withFixture('A9 two absent seats, four seats',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 4);
        await _startGame(t);
        await _drop(t, 0);
        fx.clock.advance(const Duration(seconds: 1));
        await _drop(t, 1);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final Map<int, List<Frame>> due = await t.syncAll();
        for (final int seat in <int>[2, 3]) {
          final List<Frame> got = due[seat]!;
          final List<String> seen = <String>[
            for (final Frame f in got) '${f['t']}:${_d(f)['seat']}',
          ];
          // Seat 0 was sent its opening pre before it dropped: that roll is
          // published first (section 35 item 3). Seat 1's socket was down for
          // the whole of any turn it got here, so it was never sent a pre and
          // is retired with no roll taken (item 7(a)).
          final int r0 =
              _expectForcedRollFirst(fx, got, 0, 'absent', 'A9 seat $seat');
          fx.eq(_d(got[r0])['host_seat'], 1,
              'the host was retired: the lowest seat still playing');
          final int r1 = got.indexWhere(
              (Frame f) => f['t'] == 'seat_retired' && _d(f)['seat'] == 1);
          fx.ok(r1 > r0, 'seat $seat: seat 1 is retired after seat 0', seen);
          fx.eq(_d(got[r1])['reason'], 'absent', 'second reason');
          fx.eq(_d(got[r1])['host_seat'], 2, 'the host again: seat 2');
          fx.ok(
              !got.any((Frame f) => f['t'] == 'rolled' && _d(f)['seat'] == 1),
              'seat $seat: no roll is taken for seat 1, never sent a pre',
              seen);
          fx.eq(got.last['t'], 'turn', 'seat $seat: the last frame');
          fx.eq(_d(got.last)['seat'], 2, 'the last turn');
          fx.eq(_d(got.last)['phase'], 'await_roll', 'its phase');
          fx.eq(_d(got.last)['deadline_ms'], 45000, 'a connected seat, 45 s');
          fx.eq(got.length, r1 + 2, 'seat $seat: the turn follows at once');
        }
        fx.eq(t.room.game!.retired, <int>[0, 1], 'retirement order');
      });
    });

    test(
        'A10: two of three seats gone past 120 s in one sweep: game_over '
        'closes it, no turn frame in phase finished is ever sent', () async {
      await _withFixture('A10 two absent seats, three seats',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 0);
        fx.clock.advance(const Duration(seconds: 1));
        await _drop(t, 1);
        await t.syncAll();
        fx.clock.advance(const Duration(seconds: 120));
        _freshSegment(t);
        fx.server.runTurnExpiryOnce();
        final List<Frame> got = (await t.syncAll())[2]!;
        fx.eq(<Object?>[
          for (final Frame f in _ofType(got, 'turn'))
            if (_d(f)['phase'] == 'finished') _d(f),
        ], <Object?>[],
            'a game that has ended never gets a turn in phase finished');
        // Seat 0's shown roll is published first (section 35 item 3); seat
        // 1 was never sent a pre and gets no roll (item 7(a)).
        final int r0 = _expectForcedRollFirst(fx, got, 0, 'absent', 'A10');
        final int n = got.length;
        fx.eq(
            _types(got).sublist(n - 4),
            <String>['seat_retired', 'game_over', 'player_left', 'player_left'],
            'retire 1 (one playing seat left), game_over, both retired seats '
            'freed');
        fx.eq(_d(got[n - 4])['seat'], 1, 'the second retire is seat 1');
        fx.ok(r0 < n - 4, 'seat 0 is retired before seat 1', _types(got));
        fx.ok(!got.any((Frame f) => f['t'] == 'rolled' && _d(f)['seat'] == 1),
            'no roll is taken for seat 1, never sent a pre', _types(got));
        fx.eq(_d(got[n - 3])['placings'], <int>[2], 'placings');
        fx.eq(_d(got[n - 3])['retired'], <int>[0, 1], 'retired');
        fx.eq(_d(got[n - 3])['winner'], 2, 'winner');
        fx.eq(<Object?>[_d(got[n - 2])['seat'], _d(got[n - 1])['seat']],
            <int>[0, 1], 'player_left in retirement order');
      });
    });
  });

  group('rule 4: kick', () {
    test(
        'K1: a host kicks a dropped seat: seat_retired kicked, re to the '
        'host', () async {
      await _withFixture('K1 kick accepted', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        await _drop(t, 2);
        await t.syncAll();
        final String id = fx.send(t.c(0), 'kick', <String, Object?>{'seat': 2});
        final Map<int, List<Frame>> r = await t.syncAll(first: 0);
        for (final int seat in <int>[0, 1]) {
          fx.eq(_types(r[seat]!), <String>['seat_retired'], 'seat $seat');
          fx.eq(_d(r[seat]!.single)['seat'], 2, 'seat_retired.seat');
          fx.eq(_d(r[seat]!.single)['reason'], 'kicked', 'reason');
          fx.eq(_d(r[seat]!.single)['host_seat'], 0, 'host_seat');
        }
        fx.eq(r[0]!.single['re'], id, 'the host\'s copy carries re');
        fx.ok(!r[1]!.single.containsKey('re'), 'others get no re', r[1]);
        final Map<String, Object?> snap = await _resume(t, 1);
        fx.eq(snap['retired'], <int>[2], 'snapshot retired');
      });
    });

    test('K2: kick errors, in the stated order', () async {
      await _withFixture('K2 kick error order', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        // LOBBY (section 31 item 11 e3): NOT_HOST, then BAD_FIELD.
        fx.send(t.c(1), 'kick', <String, Object?>{'seat': 'x'});
        _expectError(fx, await _flush(fx, t.c(1)), 'NOT_HOST',
            'a non-host kick in LOBBY with a bad payload');
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 'x'});
        _expectError(fx, await _flush(fx, t.c(0)), 'BAD_FIELD',
            'a host kick in LOBBY with a bad payload');
        await _startGame(t);
        // PLAYING.
        fx.send(t.c(1), 'kick', <String, Object?>{'seat': 'x'});
        _expectError(fx, await _flush(fx, t.c(1)), 'NOT_HOST',
            'a non-host kick in PLAYING with a bad payload');
        for (final Map<String, Object?> bad in <Map<String, Object?>>[
          <String, Object?>{},
          <String, Object?>{'seat': 'x'},
          <String, Object?>{'seat': 4},
          <String, Object?>{'seat': -1},
          <String, Object?>{'seat': 1.5},
          <String, Object?>{'seat': null},
          <String, Object?>{'seat': true},
          <String, Object?>{'seat': 2, 'extra': 1},
        ]) {
          fx.send(t.c(0), 'kick', bad);
          _expectError(fx, await _flush(fx, t.c(0)), 'BAD_FIELD',
              'kick ${_j(bad)} by the host in PLAYING');
        }
        // A seat that is not in the game at all.
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 3});
        _expectError(fx, await _flush(fx, t.c(0)), 'ILLEGAL_MOVE',
            'kick of a seat that is not a playing seat');
        // Section 33 item 8: the host's own seat is ILLEGAL_MOVE (NOT_ABSENT
        // is no longer sent).
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 0});
        _expectError(fx, await _flush(fx, t.c(0)), 'ILLEGAL_MOVE',
            'kick of the host\'s own seat');
        // A retired seat whose socket is still up is not a playing seat.
        fx.send(t.c(2), 'leave_room', <String, Object?>{});
        await t.c(2).next();
        t.seats[2]!.up = false;
        await t.syncAll();
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 2});
        _expectError(fx, await _flush(fx, t.c(0)), 'ILLEGAL_MOVE',
            'kick of a retired seat');
        final Map<int, List<Frame>> quiet = await t.syncAll();
        fx.eq(<Frame>[for (final List<Frame> l in quiet.values) ...l],
            <Frame>[], 'no rejected kick changed or announced anything');
        // Section 33 item 8: a playing seat whose socket is up is kicked.
        final String id = fx.send(t.c(0), 'kick', <String, Object?>{'seat': 1});
        final List<Frame> host = await _flush(fx, t.c(0));
        fx.eq(host.first['t'], 'seat_retired',
            'kick of connected seat 1 is accepted');
        fx.eq(_d(host.first)['seat'], 1, 'seat_retired.seat');
        fx.eq(_d(host.first)['reason'], 'kicked', 'seat_retired.reason');
        fx.eq(host.first['re'], id, 'the host\'s copy carries re');
        fx.eq(
            _types(await _flush(fx, t.c(1))),
            <String>['seat_retired', 'kicked'],
            'the kicked socket gets seat_retired then kicked');
      });
    });

    test(
        'K3: kick of a finished seat is ILLEGAL_MOVE; kick in FINISHED is '
        'refused', () async {
      await _withFixture('K3 kick finished seat', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        _forceFinishingMove(t, 1);
        await t.step(1, 'move', <String, Object?>{'token': 3});
        await _drop(t, 1);
        await t.syncAll();
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 1});
        _expectError(fx, await _flush(fx, t.c(0)), 'ILLEGAL_MOVE',
            'kick of a finished seat whose socket is down');
        // End the game, then kick: the room is not PLAYING.
        _force(t,
            currentSeat: 2,
            phase: 'awaitMove',
            queue: <int>[3],
            tokens: <int, List<int>>{
              2: <int>[57, 57, 57, 54],
            },
            releaseOwed: false);
        await t.step(2, 'move', <String, Object?>{'token': 3});
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 1});
        final List<Frame> r = await _flush(fx, t.c(0));
        fx.eq(_types(r), <String>['error'], 'kick in FINISHED');
        fx.ok(
            <String>['WRONG_PHASE', 'GAME_OVER']
                .contains(_code(fx, r.single, 'kick in FINISHED')),
            'section 28: state not PLAYING is WRONG_PHASE (section 19.2 would '
            'make it GAME_OVER; the section does not say which wins)',
            r);
      });
    });

    test('K4: kick counts against the per-socket message limit', () async {
      await _withFixture('K4 kick rate limit', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        fx.limiterClock.advance(const Duration(seconds: 5));
        final List<Frame> seen = <Frame>[];
        for (int i = 0; i < 31; i++) {
          fx.sendBurst(t.c(0), 'kick', <String, Object?>{'seat': 0});
        }
        for (int i = 0; i < 31; i++) {
          seen.add(await t.c(0).next());
        }
        fx.eq(
            <Object?>[for (final Frame f in seen.take(30)) _d(f)['code']],
            List<String>.filled(30, 'ILLEGAL_MOVE'),
            'the first 30 kicks in the second reach the handler');
        fx.eq(_d(seen.last)['code'], 'RATE_LIMITED',
            'the 31st message in one second');
      });
    });
  });

  group('rule 4: the end of a game frees the retired seats', () {
    test(
        'E1: one player_left per retired seat, in retirement order, each '
        'with its own seq, after game_over', () async {
      await _withFixture('E1 retired seats freed in order',
          (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 3);
        await _startGame(t);
        fx.send(t.c(2), 'leave_room', <String, Object?>{});
        await t.c(2).next();
        t.seats[2]!.up = false;
        await t.syncAll();
        await _drop(t, 1);
        await t.syncAll();
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 1});
        final List<Frame> got = await _flush(fx, t.c(0));
        fx.eq(
            _types(got),
            <String>[
              'seat_retired',
              'game_over',
              'player_left',
              'player_left',
            ],
            'the second retirement leaves one seat standing');
        final int seq = _d(got[0])['seq']! as int;
        fx.eq(_d(got[0])['reason'], 'kicked', 'reason');
        fx.eq(_d(got[1])['placings'], <int>[0], 'placings');
        fx.eq(_d(got[1])['retired'], <int>[2, 1],
            'retired is in retirement order, not seat order');
        fx.eq(_d(got[1])['winner'], 0, 'winner');
        fx.eq(<Object?>[_d(got[2])['seat'], _d(got[3])['seat']], <int>[2, 1],
            'player_left follows the retirement order');
        fx.eq(<Object?>[
          _d(got[1])['seq'],
          _d(got[2])['seq'],
          _d(got[3])['seq'],
        ], <int>[
          seq + 1,
          seq + 2,
          seq + 3
        ], 'each frame has its own seq');
        fx.eq(<Object?>[_d(got[2])['host_seat'], _d(got[3])['host_seat']],
            <int>[0, 0], 'player_left.host_seat');
        final Map<String, Object?> snap = await _resume(t, 0);
        fx.eq(
            (snap['seats']! as List<Object?>)
                .cast<Map<String, Object?>>()
                .map((Map<String, Object?> s) => s['seat'])
                .toList(),
            <int>[0],
            'both retired seats are freed');
        // A rematch follows section 16 with the seat that is left.
        fx.send(t.c(0), 'rematch', <String, Object?>{});
        final List<Frame> rm = await _flush(fx, t.c(0));
        final Frame room = _ofType(rm, 'room').single;
        fx.eq(_d(room)['state'], 'LOBBY', 'a rematch LOBBY opens');
        fx.eq((_d(room)['rules']! as Map<String, Object?>)['ruleset'], _v26,
            'the rematch room keeps its ruleset');
        fx.eq((_d(room)['seats']! as List<Object?>).length, 1, 'seats left');
      });
    });
  });

  // =========================================================================
  // Not on the 2026-10 wire
  // =========================================================================
  group('2026-10 stays as it was', () {
    test(
        'C1: under 2026-10 no frame carries a new key and a finish ends the '
        'game as today', () async {
      final _Steer steer = _Steer.faces(<int>[4]);
      await _withFixture('C1 2026-10 frames', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2, seeds: true);
        await _startGame(t);
        final Map<int, List<Frame>> r =
            await t.step(0, 'roll', <String, Object?>{});
        final Map<String, Object?> rolled = _d(r[0]!.first);
        for (final String key in <String>[
          'release',
        ]) {
          fx.absent(rolled, key, 'a 2026-10 rolled');
        }
        fx.eq(_types(r[0]!), <String>['rolled', 'turn_passed', 'turn'],
            'a non-6 with every token in the yard passes as today');
        _force(t, currentSeat: 2, phase: 'awaitMove', queue: <int>[
          3
        ], tokens: <int, List<int>>{
          2: <int>[57, 57, 57, 54],
        });
        final Map<int, List<Frame>> end =
            await t.step(2, 'move', <String, Object?>{'token': 3});
        fx.eq(_types(end[0]!), <String>['moved', 'game_over'],
            'a 2026-10 finish');
        for (final String key in <String>['placings', 'retired']) {
          fx.absent(_d(end[0]!.last), key, 'a 2026-10 game_over');
        }
        fx.absent(_d(end[0]!.first), 'release', 'a 2026-10 moved');
        final Map<String, Object?> rec = await _record(t);
        for (final String key in <String>[
          'ruleset',
          'releases',
          'placings',
          'retired',
        ]) {
          fx.absent(rec, key, 'a 2026-10 verify record');
        }
      }, ruleset: _v25, steer: steer);
    });

    test(
        'C2: under 2026-10 a PLAYING snapshot has no drought, placings, '
        'retired or ruleset, and kick is an unknown message', () async {
      await _withFixture('C2 2026-10 snapshot and kick', (_Fixture fx) async {
        final _Table t = await _openTable(fx, players: 2);
        await _startGame(t);
        final Map<String, Object?> snap = await _resume(t, 2);
        for (final String key in <String>['placings', 'retired']) {
          fx.absent(snap, key, 'a 2026-10 PLAYING snapshot');
        }
        fx.absent(snap['rules']! as Map<String, Object?>, 'ruleset',
            'a 2026-10 PLAYING snapshot rules');
        for (final Object? s in snap['seats']! as List<Object?>) {
          fx.absent(s! as Map<String, Object?>, 'drought',
              'a 2026-10 PLAYING seat object');
        }
        final Map<String, Object?> turn = snap['turn']! as Map<String, Object?>;
        fx.absent(turn, 'release', 'a 2026-10 snapshot turn');
        await t.syncAll();
        fx.send(t.c(0), 'kick', <String, Object?>{'seat': 2});
        _expectError(fx, await _flush(fx, t.c(0)), 'BAD_TYPE',
            'kick on a 2026-10 server: section 3, an unknown type is BAD_TYPE');
      }, ruleset: _v25);
    });
  });
}
