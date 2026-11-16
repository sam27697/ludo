// Order C-654t: the proof of docs/PROTOCOL.md section 29, the next seat
// waits for the last move to land, in the list rule 6 of that section gives
// for the server.
//
// Written from the section only. Everything runs over real sockets against a
// real WireServer with a fake clock; no test sleeps, every wait is on a frame
// or on a ping/pong barrier, and the sweep of the turn timer is driven by hand
// (`runTurnExpiryOnce`) after the fake clock is moved.
//
// Positions. A board a game would take hours to reach is built by rewriting
// the room's engine state through the registry between frames (the pattern of
// rematch_test.dart). That rewrite never touches the segment's start or any
// other timing field, so a grace that is running is left exactly as the
// server made it. A die face that matters (a roll with no legal move, a six)
// is steered with the offline search of support/dice_oracle.dart, so every
// scenario is deterministic: a failure names its scenario, and the scenario
// name is the whole reproduction.
//
// What section 29 adds is read off the wire only: `grace_ms` on the `turn`
// frame and in the snapshot's `turn`. No production member is referenced that
// the section 28 implementation lacks.

import 'dart:io';
import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

typedef Frame = Map<String, Object?>;

const String _v26 = '2026-11';
const String _v25 = '2026-10';

/// Section 26 rule 3: the budget of a segment, and of an away seat's.
const int _budget = 45000;
const int _awayBudget = 10000;

const String _seedsFor2 = '0:seed-s0|2:seed-s2';

Map<String, Object?> _d(Frame frame) => frame['d']! as Map<String, Object?>;

List<Object?> _types(List<Frame> frames) =>
    <Object?>[for (final Frame f in frames) f['t']];

Frame? _lastOfType(List<Frame> frames, String type) {
  for (final Frame f in frames.reversed) {
    if (f['t'] == type) {
      return f;
    }
  }
  return null;
}

Frame? _firstOfType(List<Frame> frames, String type) {
  for (final Frame f in frames) {
    if (f['t'] == type) {
      return f;
    }
  }
  return null;
}

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

String _j(Object? value) => _canon(value).toString();

// ---------------------------------------------------------------------------
// Steering: a server secret whose first faces are exactly the wanted ones.
// ---------------------------------------------------------------------------

String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

class _Steer {
  _Steer._(this.description, this.secret, this.gameId);

  final String description;
  final List<int> secret;
  final String gameId;

  Random random() => ScriptedBytesRandom(buildScript(secret: secret));

  static final Map<String, _Steer> _cache = <String, _Steer>{};

  static _Steer faces(List<int> wanted) {
    return _cache.putIfAbsent('faces:$wanted', () {
      final String gameId = _predictedGameId();
      final SteeredSecret s = findSecretForFaces(
        wanted: wanted,
        gameId: gameId,
        clientSeeds: _seedsFor2,
      );
      return _Steer._(
        'dice steered so that rolls 1..${wanted.length} are $wanted',
        s.secret,
        gameId,
      );
    });
  }
}

// ---------------------------------------------------------------------------
// The fixture: one server, one fake clock, every failure names its scenario.
// ---------------------------------------------------------------------------

class _Fx {
  _Fx._(this.scenario, this.ruleset, this.steer);

  final String scenario;
  final String ruleset;
  final _Steer? steer;

  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 16));

  /// The rate limiter has its own clock, so the one-second message ceiling
  /// never depends on the game clock a scenario is driving.
  final FakeClock limiterClock = FakeClock(DateTime.utc(2026, 11, 16));

  late final RoomRegistry registry;
  late final WireServer server;
  final List<WireTestClient> clients = <WireTestClient>[];

  static Future<_Fx> start(
    String scenario, {
    required String ruleset,
    _Steer? steer,
  }) async {
    final _Fx fx = _Fx._(scenario, ruleset, steer);
    fx.registry = RoomRegistry(
      clock: fx.clock,
      secure: steer?.random() ?? Random.secure(),
      ruleset: ruleset,
    );
    fx.server = WireServer(
      registry: fx.registry,
      rateLimiter: RateLimiter(clock: fx.limiterClock),
      clock: fx.clock,
      automaticTurnExpiry: false,
    );
    await fx.server.start(address: InternetAddress.loopbackIPv4, port: 0);
    return fx;
  }

  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Future<WireTestClient> connect() async {
    final WireTestClient c = await WireTestClient.connect(wsUri);
    clients.add(c);
    return c;
  }

  String send(WireTestClient c, String type, Map<String, Object?> data) {
    limiterClock.advance(const Duration(milliseconds: 1100));
    return c.send(type, data);
  }

  /// The fake clock's present, to measure later instants from.
  DateTime mark() => clock.now;

  /// Moves the fake clock to [ms] after [from]. Never backwards.
  void advanceTo(DateTime from, int ms) {
    final Duration delta = from.add(Duration(milliseconds: ms)).difference(
          clock.now,
        );
    if (delta.isNegative) {
      throw StateError('scenario "$scenario": advanceTo($ms) is in the past');
    }
    clock.advance(delta);
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

  String get reproduce => 'scenario="$scenario" ruleset=$ruleset '
      '(${steer?.description ?? 'dice not steered'}; rerun: dart test '
      'test/c654_grace_test.dart --plain-name "$scenario")';

  Never fail(String what,
      {required Object? expected, required Object? actual}) {
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
}

/// Reads off [c] until its ping is answered: every frame the server wrote to
/// this socket before it handled the ping, in order, the pong left out.
Future<List<Frame>> _flush(_Fx fx, WireTestClient c) async {
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
  _Table(this.fx, this.code, this.seats);

  final _Fx fx;
  final String code;
  final Map<int, _Seat> seats;

  /// Every frame each seat read up to and including the opening `turn`.
  final Map<int, List<Frame>> opening = <int, List<Frame>>{};

  WireTestClient c(int seat) => seats[seat]!.client;
  String token(int seat) => seats[seat]!.token;
  Room get room => fx.registry.lookup(code)!;
  List<int> get numbers => (seats.keys.toList()..sort());
  List<int> get connected => <int>[
        for (final int s in numbers)
          if (seats[s]!.up) s
      ];

  /// Flushes every connected seat, [first] first (the sender, whose pong
  /// proves its message was handled before anyone else is asked).
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

  /// The timer's sweep, then every frame it produced.
  Future<Map<int, List<Frame>>> sweep() async {
    fx.server.runTurnExpiryOnce();
    return syncAll();
  }
}

Future<_Table> _openTable(
  _Fx fx, {
  required int players,
  required bool seeds,
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
  fx.eq(<Object?>[sa['t'], room['t']], <String>['seat_assigned', 'room'],
      'create_room is answered by seat_assigned then room');
  seats[_d(sa)['seat']! as int] =
      _Seat(_d(sa)['seat']! as int, _d(sa)['seat_token']! as String, host);
  final String code = _d(room)['code']! as String;
  for (int i = 1; i < players; i++) {
    final WireTestClient g = await fx.connect();
    fx.send(g, 'join_room', <String, Object?>{'code': code, 'name': 'G$i'});
    final Frame gsa = await g.next();
    final Frame groom = await g.next();
    fx.eq(<Object?>[gsa['t'], groom['t']], <String>['seat_assigned', 'room'],
        'join_room is answered by seat_assigned then room');
    for (final _Seat other in seats.values) {
      await receiveType(other.client, 'player_joined');
    }
    final int seat = _d(gsa)['seat']! as int;
    seats[seat] = _Seat(seat, _d(gsa)['seat_token']! as String, g);
  }
  final _Table t = _Table(fx, code, seats);
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

/// start_game from the host; every seat is read up to its opening `turn`.
Future<void> _startGame(_Table t) async {
  final int host = t.numbers.first;
  t.fx.send(t.c(host), 'start_game', <String, Object?>{});
  for (final int s in t.numbers) {
    t.opening[s] = await drainUntil(
      t.c(s),
      'turn',
      maxFrames: 12,
      perFrame: const Duration(seconds: 3),
    );
  }
  final _Steer? steer = t.fx.steer;
  if (steer != null) {
    final Frame gs = _firstOfType(t.opening[host]!, 'game_started')!;
    t.fx.eq(
      _d(gs)['game_id'],
      steer.gameId,
      'the steering search predicts game_id from the registry draw order; a '
      'different game_id means the draws before start_game changed and the '
      'steered faces no longer apply',
    );
  }
}

/// A started game. [faces] steers the first rolls (2 seats only).
void _scenario(
  String name,
  Future<void> Function(_Fx fx, _Table t) body, {
  String ruleset = _v26,
  List<int>? faces,
  int players = 2,
  Map<String, Object?>? rules,
}) {
  test(name, () async {
    final _Fx fx = await _Fx.start(
      name,
      ruleset: ruleset,
      steer: faces == null ? null : _Steer.faces(faces),
    );
    try {
      final _Table t = await _openTable(
        fx,
        players: players,
        seeds: faces != null,
        rules: rules,
      );
      await _startGame(t);
      await body(fx, t);
    } finally {
      await fx.close();
    }
  });
}

void _force(
  _Table t, {
  int? currentSeat,
  String? phase,
  List<int>? queue,
  Map<int, List<int>>? tokens,
  List<int>? drought,
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
  if (sixes != null) {
    json['sixes'] = sixes;
  }
  room.game = engine.GameState.fromJson(json);
}

/// Closes [seat]'s socket and waits until every other connected seat has
/// been told.
Future<void> _drop(_Table t, int seat) async {
  final _Seat s = t.seats[seat]!;
  s.up = false;
  await s.client.close();
  for (final _Seat o in t.seats.values) {
    if (!o.up) {
      continue;
    }
    for (int i = 0; i < 12; i++) {
      final Frame f = await o.client.next(timeout: const Duration(seconds: 5));
      if (f['t'] == 'presence' &&
          _d(f)['seat'] == seat &&
          _d(f)['connected'] == false) {
        break;
      }
      if (i == 11) {
        t.fx.fail('a presence frame for seat $seat connected=false',
            expected: 'presence', actual: f);
      }
    }
  }
}

/// A `resume` on a fresh socket: the `room` snapshot it is answered with.
Future<Map<String, Object?>> _resume(_Table t, int seat) async {
  final WireTestClient c = await t.fx.connect();
  t.fx.send(c, 'resume', <String, Object?>{
    'code': t.code,
    'seat_token': t.token(seat),
  });
  final Frame sa = await c.next();
  final Frame room = await c.next();
  t.fx.eq(<Object?>[sa['t'], room['t']], <String>['seat_assigned', 'room'],
      'resume is answered by seat_assigned then room');
  t.seats[seat]!.client = c;
  t.seats[seat]!.up = true;
  return _d(room);
}

/// The snapshot's `turn` object, taken by a `resume` of [seat], with every
/// frame that resume caused on the other sockets read and dropped.
Future<Map<String, Object?>> _snapTurn(_Table t, int seat) async {
  final Map<String, Object?> room = await _resume(t, seat);
  await t.syncAll();
  return room['turn']! as Map<String, Object?>;
}

// ---------------------------------------------------------------------------
// Checks several cases share.
// ---------------------------------------------------------------------------

/// No frame of any kind but `turn` ever carries `grace_ms` (rule 3).
void _expectGraceOnlyOnTurn(_Fx fx, Map<int, List<Frame>> frames) {
  frames.forEach((int seat, List<Frame> list) {
    for (final Frame f in list) {
      if (f['t'] != 'turn' && _d(f).containsKey('grace_ms')) {
        fx.fail(
            'rule 3: only the turn frame gains grace_ms (seat $seat read '
            'a "${f['t']}")',
            expected: 'no grace_ms',
            actual: f);
      }
    }
  });
}

/// Every seat in [seats] ends its frames with the same `turn` for [next], with
/// the full budget in `deadline_ms`, and `grace_ms` equal to [grace] (null: the
/// key is absent). [why] is the arithmetic of rule 2.
void _expectTurn(
  _Fx fx,
  Map<int, List<Frame>> frames,
  List<int> seats, {
  required int next,
  required int? grace,
  required String why,
  int budget = _budget,
  String? phase,
}) {
  _expectGraceOnlyOnTurn(fx, frames);
  Map<String, Object?>? first;
  for (final int seat in seats) {
    final Frame? turn = _lastOfType(frames[seat]!, 'turn');
    if (turn == null) {
      fx.fail('seat $seat must read a turn frame for seat $next',
          expected: 'a turn frame', actual: _types(frames[seat]!));
    }
    final Map<String, Object?> d = _d(turn);
    fx.eq(d['seat'], next, 'seat $seat: the turn passes to seat $next');
    fx.eq(d['deadline_ms'], budget,
        'rule 3: deadline_ms on the turn is the full segment budget');
    if (phase != null) {
      fx.eq(d['phase'], phase, 'seat $seat: phase of the turn');
    }
    if (grace == null) {
      if (d.containsKey('grace_ms')) {
        fx.fail('seat $seat: $why', expected: 'no grace_ms', actual: d);
      }
    } else {
      fx.eq(d['grace_ms'], grace,
          'seat $seat: grace_ms on the turn frame ($why)');
      fx.ok(d['grace_ms'] is int && (d['grace_ms']! as int) > 0,
          'rule 3: grace_ms is an int above 0', d['grace_ms']);
    }
    if (first == null) {
      first = d;
    } else {
      fx.eq(
          d,
          first,
          'seat $seat reads the same turn frame as seat '
          '${seats.first}');
    }
  }
}

/// The frames of one step by [seat], checked to be exactly [types] on [seats].
void _expectShape(
  _Fx fx,
  Map<int, List<Frame>> frames,
  List<int> seats,
  List<String> types,
  String what,
) {
  for (final int seat in seats) {
    fx.eq(_types(frames[seat]!), types, '$what: frames seat $seat read');
  }
}

/// The `moved` frame of a step, as the mover read it.
Map<String, Object?> _moved(_Fx fx, List<Frame> frames, String what) {
  final Frame? f = _firstOfType(frames, 'moved');
  if (f == null) {
    fx.fail('$what: a moved frame', expected: 'moved', actual: _types(frames));
  }
  return _d(f);
}

/// Positions. [seat0] is progress for seat 0's tokens; 2 and 1 likewise.
void _board(
  _Table t, {
  int seat = 0,
  required List<int> tokens,
  required List<int> queue,
  Map<int, List<int>> others = const <int, List<int>>{},
}) {
  _force(
    t,
    currentSeat: seat,
    phase: 'awaitMove',
    queue: queue,
    tokens: <int, List<int>>{seat: tokens, ...others},
    sixes: 0,
  );
}

/// Progress of a seat-[seat] token standing on absolute square [square].
int _progressOn(int seat, int square) {
  const List<int> entry = <int>[0, 13, 26, 39];
  return (square - entry[seat] + 52) % 52;
}

/// A timer step is a frame of [type] by the timer for [seat].
void _expectTimerStep(
  _Fx fx,
  Map<int, List<Frame>> frames,
  int seat,
  String type,
  String what,
) {
  for (final MapEntry<int, List<Frame>> e in frames.entries) {
    fx.ok(e.value.isNotEmpty,
        '$what: the timer must act and seat ${e.key} read nothing', e.value);
    final Frame f = e.value.first;
    fx.eq(f['t'], type, '$what: first frame seat ${e.key} read');
    fx.eq(_d(f)['by'], 'timer', '$what: section 22 by');
    fx.eq(_d(f)['seat'], seat, '$what: the seat the timer played for');
  }
}

void _expectSilent(_Fx fx, Map<int, List<Frame>> frames, String what) {
  frames.forEach((int seat, List<Frame> list) {
    if (list.isNotEmpty) {
      fx.fail('$what: the sweep must not act (seat $seat read frames)',
          expected: 'no frame', actual: _types(list));
    }
  });
}

/// The 4-square move of the 1060 example: seat 0's token 0 from 10 to 14.
Future<Map<int, List<Frame>>> _fourSquareMove(_Fx fx, _Table t) async {
  _board(t, tokens: <int>[10, -1, -1, -1], queue: <int>[4]);
  final Map<int, List<Frame>> frames =
      await t.step(0, 'move', <String, Object?>{'token': 0});
  _expectShape(fx, frames, t.connected, <String>['moved', 'turn'],
      'a 4-square move that passes the turn');
  final Map<String, Object?> moved =
      _moved(fx, frames[0]!, 'the 4-square move');
  fx.eq(<Object?>[moved['from'], moved['to']], <int>[10, 14],
      'the move under test is 10 to 14');
  return frames;
}

// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // Rule 2: each example gives that grace_ms on the turn frame.
  // =========================================================================
  group('rule 2: grace_ms on the turn frame that passes the turn', () {
    _scenario('E1 a 4-square move that passes the turn: 4*140 + 500 = 1060',
        (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames = await _fourSquareMove(fx, t);
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: 1060, why: '4 steps * 140 = 560, plus hold 500');
    });

    _scenario(
        'E2 a 6-square move that captures and passes: 6*140 + 360 + 500 = 1700',
        (_Fx fx, _Table t) async {
      // 10 + 6 = 16, an unsafe square; seat 2's token on it is progress 42.
      _board(t, tokens: <int>[
        10,
        -1,
        -1,
        -1
      ], queue: <int>[
        6
      ], others: <int, List<int>>{
        2: <int>[_progressOn(2, 16), -1, -1, -1],
      });
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'a 6-square capture with capture_bonus off');
      final Map<String, Object?> moved = _moved(fx, frames[0]!, 'the capture');
      fx.eq(<Object?>[moved['from'], moved['to'], moved['extra_roll']],
          <Object?>[10, 16, false], 'the capture is 10 to 16, no extra roll');
      fx.eq(
          moved['captured'],
          <Object?>[
            <String, Object?>{'seat': 2, 'token': 0}
          ],
          'seat 2 token 0 is captured');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2,
          grace: 1700,
          why: '6 steps * 140 = 840, plus capture flight 360, plus hold 500');
    }, rules: <String, Object?>{'capture_bonus': false});

    _scenario('E3 a roll with no legal move: 0 + 1500 = 1500',
        (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames =
          await t.step(0, 'roll', <String, Object?>{});
      _expectShape(fx, frames, <int>[0, 2],
          <String>['rolled', 'turn_passed', 'turn'], 'a roll with no move');
      fx.eq(_d(frames[0]!.first)['legal'], <int>[], 'the roll has no move');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: 1500, why: 'no moved frame: travel 0, hold 1500');
    }, faces: <int>[3]);

    _scenario(
        'E4 a 2-square move that leaves only dead faces: 2*140 + 1500 = 1780',
        (_Fx fx, _Table t) async {
      // 53 + 2 = 55; the queued 5 then overshoots home (55 + 5 = 60).
      _board(t, tokens: <int>[53, -1, -1, -1], queue: <int>[2, 5]);
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 0, 'face': 2});
      _expectShape(
          fx,
          frames,
          <int>[0, 2],
          <String>['moved', 'turn_passed', 'turn'],
          'a move leaving dead faces');
      fx.eq(_d(_lastOfType(frames[0]!, 'turn_passed')!)['reason'],
          'no_legal_move', 'the leftover 5 is dead');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: 1780, why: '2 steps * 140 = 280, plus hold 1500');
    });

    _scenario('E5 a retire of the seat on turn (seat_retired, turn): 0 + 500',
        (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames =
          await t.step(0, 'leave_room', <String, Object?>{});
      _expectShape(fx, frames, <int>[1, 2], <String>['seat_retired', 'turn'],
          'seat 0 leaves on its own turn');
      fx.eq(_d(frames[1]!.first)['reason'], 'left', 'the retire is a leave');
      _expectTurn(fx, frames, <int>[1, 2],
          next: 1, grace: 500, why: 'no moved frame: travel 0, hold 500');
    }, players: 3);

    _scenario('E6a a timer-played move, as any move: 4*140 + 500 = 1060',
        (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[10, -1, -1, -1], queue: <int>[4]);
      fx.advanceTo(fx.mark(), _budget);
      final Map<int, List<Frame>> frames = await t.sweep();
      _expectTimerStep(fx, frames, 0, 'moved', 'the timer plays the 4');
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'a timer-played move');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: 1060, why: '4 steps * 140 = 560, plus hold 500');
    });

    _scenario('E6b a timer-played roll with no move: 0 + 1500 = 1500',
        (_Fx fx, _Table t) async {
      fx.advanceTo(fx.mark(), _budget);
      final Map<int, List<Frame>> frames = await t.sweep();
      _expectTimerStep(fx, frames, 0, 'rolled', 'the timer rolls the 3');
      _expectShape(fx, frames, <int>[0, 2],
          <String>['rolled', 'turn_passed', 'turn'], 'a timer-played roll');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: 1500, why: 'no moved frame: travel 0, hold 1500');
    }, faces: <int>[3]);

    _scenario(
        'E7 a move that finishes a seat, play goes on (three seats): '
        '3*140 + 500 = 920', (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[57, 57, 57, 54], queue: <int>[3]);
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 3});
      _expectShape(fx, frames, <int>[0, 1, 2],
          <String>['moved', 'seat_finished', 'turn'], 'the first seat home');
      _expectTurn(fx, frames, <int>[0, 1, 2],
          next: 1,
          grace: 920,
          why: 'the last moved frame is 54 to 57, 3 steps * 140 = 420, plus '
              'hold 500');
    }, players: 3);

    for (final int face in <int>[1, 2, 3, 5, 6]) {
      _scenario(
          'E8 a $face-square move, no capture, passes the turn: '
          '$face*140 + 500 = ${face * 140 + 500}', (_Fx fx, _Table t) async {
        _board(t, tokens: <int>[10, -1, -1, -1], queue: <int>[face]);
        final Map<int, List<Frame>> frames =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
            'a $face-square move');
        _expectTurn(fx, frames, <int>[0, 2],
            next: 2,
            grace: face * 140 + 500,
            why: '$face steps * 140, plus hold 500');
      });
    }

    for (final int face in <int>[1, 2]) {
      _scenario(
          'E9 a $face-square capture that passes: '
          '$face*140 + 360 + 500 = ${face * 140 + 860}',
          (_Fx fx, _Table t) async {
        _board(t, tokens: <int>[
          10,
          -1,
          -1,
          -1
        ], queue: <int>[
          face
        ], others: <int, List<int>>{
          2: <int>[_progressOn(2, 10 + face), -1, -1, -1],
        });
        final Map<int, List<Frame>> frames =
            await t.step(0, 'move', <String, Object?>{'token': 0});
        _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
            'a $face-square capture');
        fx.eq(
            _moved(fx, frames[0]!, 'the capture')['captured'],
            <Object?>[
              <String, Object?>{'seat': 2, 'token': 0}
            ],
            'the capture happened');
        _expectTurn(fx, frames, <int>[0, 2],
            next: 2,
            grace: face * 140 + 860,
            why: '$face steps * 140, plus capture flight 360, plus hold 500');
      }, rules: <String, Object?>{'capture_bonus': false});
    }

    _scenario(
        'E10 leaving the yard on a spent 6 is 1 step, not 6: 1*140 + 500 = 640',
        (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[-1, -1, -1, -1], queue: <int>[6]);
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'a token leaves the yard on a 6');
      final Map<String, Object?> moved = _moved(fx, frames[0]!, 'the exit');
      fx.eq(<Object?>[moved['from'], moved['to']], <int>[-1, 0],
          'the move under test is -1 to 0');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2,
          grace: 640,
          why: 'from -1 counts 1 step: 140, plus hold 500');
    });

    _scenario(
        'E11 a third six with no moved frame in the step (three_sixes): '
        '0 + 1500 = 1500', (_Fx fx, _Table t) async {
      for (final int roll in <int>[1, 2]) {
        final Map<int, List<Frame>> owed =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(_d(owed[0]!.first)['value'], 6, 'roll $roll is the steered 6');
        _expectShape(fx, owed, <int>[0, 2], <String>['rolled', 'turn'],
            'six number $roll is owed, the turn stays');
        _expectTurn(fx, owed, <int>[0, 2],
            next: 0,
            grace: null,
            why: 'a six owed is a same-seat turn',
            phase: 'await_roll');
      }
      final Map<int, List<Frame>> frames =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(_d(frames[0]!.first)['value'], 6, 'roll 3 is the steered 6');
      _expectShape(
          fx,
          frames,
          <int>[0, 2],
          <String>['rolled', 'turn_passed', 'turn'],
          'the third six passes the turn');
      fx.eq(_d(_lastOfType(frames[0]!, 'turn_passed')!)['reason'],
          'three_sixes', 'the pass is the third six');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2,
          grace: 1500,
          why: 'rule 7: three_sixes with no moved in the step, travel 0, '
              'hold 1500');
    }, faces: <int>[6, 6, 6]);

    _scenario(
        'E11b a third six after an earlier capture in the same turn: the '
        'capture is another step, 0 + 1500 = 1500, not 920 + 1500',
        (_Fx fx, _Table t) async {
      // Seat 0 captures on 14 with a 4 (bonus on: it rolls again), then
      // rolls 6, 6, 6. A server that remembers the last moved frame of the
      // turn would add 4*140 + 360 to the hold.
      _force(t, tokens: <int, List<int>>{
        0: <int>[10, -1, -1, -1],
        2: <int>[_progressOn(2, 14), -1, -1, -1],
      });
      final Map<int, List<Frame>> rolled =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(_d(rolled[0]!.first)['value'], 4, 'roll 1 is the steered 4');
      final Map<int, List<Frame>> capture =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectShape(fx, capture, <int>[0, 2], <String>['moved', 'turn'],
          'the capture that owes a roll');
      fx.eq(
          _moved(fx, capture[0]!, 'the capture')['captured'],
          <Object?>[
            <String, Object?>{'seat': 2, 'token': 0}
          ],
          'the 4 captures seat 2 token 0');
      _expectTurn(fx, capture, <int>[0, 2],
          next: 0,
          grace: null,
          why: 'a capture with the bonus is a same-seat turn',
          phase: 'await_roll');
      for (final int roll in <int>[2, 3]) {
        final Map<int, List<Frame>> owed =
            await t.step(0, 'roll', <String, Object?>{});
        fx.eq(_d(owed[0]!.first)['value'], 6, 'roll $roll is the steered 6');
        _expectShape(fx, owed, <int>[0, 2], <String>['rolled', 'turn'],
            'six number ${roll - 1} is owed');
      }
      final Map<int, List<Frame>> frames =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(_d(frames[0]!.first)['value'], 6, 'roll 4 is the steered 6');
      _expectShape(
          fx,
          frames,
          <int>[0, 2],
          <String>['rolled', 'turn_passed', 'turn'],
          'the third six after the capture passes the turn');
      fx.eq(_d(_lastOfType(frames[0]!, 'turn_passed')!)['reason'],
          'three_sixes', 'the pass is the third six');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2,
          grace: 1500,
          why: 'rule 2 reads the moved frame of the step; this step has none');
    }, faces: <int>[4, 6, 6, 6]);
  });

  // =========================================================================
  // Rule 1: where no grace applies.
  // =========================================================================
  group('rule 1: a turn that is not a pass has no grace_ms', () {
    for (final String ruleset in <String>[_v26, _v25]) {
      _scenario(
          'N1 ruleset $ruleset: the first turn after game_started has no '
          'grace_ms, in the frame or the snapshot', (_Fx fx, _Table t) async {
        for (final int seat in t.numbers) {
          final Frame turn = _lastOfType(t.opening[seat]!, 'turn')!;
          fx.ok(!_d(turn).containsKey('grace_ms'),
              'seat $seat: the opening turn has no grace_ms', _d(turn));
          fx.eq(_d(turn)['deadline_ms'], _budget, 'the opening deadline_ms');
        }
        final Map<String, Object?> snap = await _snapTurn(t, 0);
        fx.ok(!snap.containsKey('grace_ms'),
            'the snapshot right after the start has no grace_ms', snap);
        fx.eq(snap['deadline_ms'], _budget, 'the snapshot deadline_ms');
      }, ruleset: ruleset);
    }

    _scenario('N2 a move that leaves a queued face: same seat, no grace_ms',
        (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[10, -1, -1, -1], queue: <int>[2, 3]);
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 0, 'face': 2});
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'a move that leaves a face');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 0,
          grace: null,
          why: 'a same-seat turn (a queued face) never has a grace',
          phase: 'await_move');
    });

    _scenario('N3 a capture with the bonus owes a roll: same seat, no grace_ms',
        (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[
        10,
        -1,
        -1,
        -1
      ], queue: <int>[
        4
      ], others: <int, List<int>>{
        2: <int>[_progressOn(2, 14), -1, -1, -1],
      });
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'a capture with the bonus');
      fx.eq(_moved(fx, frames[0]!, 'the capture')['extra_roll'], true,
          'the capture owes a roll');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 0,
          grace: null,
          why: 'an extra roll is a same-seat turn',
          phase: 'await_roll');
    });

    _scenario('N4 a token reaching home owes a roll: same seat, no grace_ms',
        (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[57, 57, 54, -1], queue: <int>[3]);
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 2});
      fx.eq(_moved(fx, frames[0]!, 'the arrival')['extra_roll'], true,
          'the arrival owes a roll');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 0,
          grace: null,
          why: 'a home arrival is a same-seat turn',
          phase: 'await_roll');
    });

    _scenario('N5 a six owes another roll: same seat, no grace_ms',
        (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(_d(frames[0]!.first)['value'], 6, 'the steered roll is a 6');
      _expectShape(
          fx, frames, <int>[0, 2], <String>['rolled', 'turn'], 'a six owed');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 0,
          grace: null,
          why: 'a six owed is a same-seat turn',
          phase: 'await_roll');
    }, faces: <int>[6]);

    _scenario(
        'N6 the release move leaves the queued face: same seat, no '
        'grace_ms', (_Fx fx, _Table t) async {
      _force(t, drought: <int>[9, 0, 0, 0]);
      final Map<int, List<Frame>> rolled =
          await t.step(0, 'roll', <String, Object?>{});
      fx.eq(_d(rolled[0]!.first)['release'], true,
          'the tenth non-6 roll with every token home grants a release');
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'the release move');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 0,
          grace: null,
          why: 'the queued face keeps the same seat on turn',
          phase: 'await_move');
    }, faces: <int>[3]);

    _scenario('N7 a move that ends the game sends no turn, so no grace_ms',
        (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[57, 57, 57, 54], queue: <int>[3]);
      final Map<int, List<Frame>> frames =
          await t.step(0, 'move', <String, Object?>{'token': 3});
      for (final int seat in <int>[0, 2]) {
        fx.ok(_firstOfType(frames[seat]!, 'game_over') != null,
            'seat $seat reads game_over', _types(frames[seat]!));
        fx.ok(
            _lastOfType(frames[seat]!, 'turn') == null,
            'no turn follows the move that ends the game',
            _types(frames[seat]!));
      }
      _expectGraceOnlyOnTurn(fx, frames);
    });

    _scenario('N8 a retire of a seat that is not on turn pushes no turn',
        (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames =
          await t.step(1, 'leave_room', <String, Object?>{});
      _expectShape(fx, frames, <int>[0, 2], <String>['seat_retired'],
          'seat 1 leaves while seat 0 is on turn');
      _expectGraceOnlyOnTurn(fx, frames);
      // The turn that follows passes over the retired seat to seat 2.
      _board(t, tokens: <int>[10, -1, -1, -1], queue: <int>[4]);
      final Map<int, List<Frame>> moved =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectTurn(fx, moved, <int>[0, 2],
          next: 2,
          grace: 1060,
          why: '4 steps * 140 = 560, plus hold 500, the retired seat skipped');
    }, players: 3);

    _scenario(
        'N8b a retire of a seat that is not on turn, 300 ms into the next '
        'seat\'s grace: no turn, the grace runs on', (_Fx fx, _Table t) async {
      _board(t, tokens: <int>[10, -1, -1, -1], queue: <int>[4]);
      final Map<int, List<Frame>> moved =
          await t.step(0, 'move', <String, Object?>{'token': 0});
      _expectTurn(fx, moved, <int>[0, 1, 2],
          next: 1, grace: 1060, why: '4 steps * 140 = 560, plus hold 500');
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 300);
      final Map<int, List<Frame>> frames =
          await t.step(2, 'leave_room', <String, Object?>{});
      _expectShape(fx, frames, <int>[0, 1], <String>['seat_retired'],
          'seat 2 leaves while seat 1 is on turn');
      _expectGraceOnlyOnTurn(fx, frames);
      fx.advanceTo(mark, 400);
      Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.eq(turn['seat'], 1, 'seat 1 is still on turn');
      fx.eq(turn['grace_ms'], 660,
          'rule 7: the running grace is untouched: 1060 - 400');
      fx.eq(turn['deadline_ms'], _budget, 'and the full budget');
      fx.advanceTo(mark, 1060 + 1000);
      turn = await _snapTurn(t, 0);
      fx.ok(!turn.containsKey('grace_ms'), 'the grace ran out at 1060', turn);
      fx.eq(turn['deadline_ms'], _budget - 1000,
          'the countdown started at the grace\'s end, not at the retire');
    }, players: 3);

    _scenario('N9 a second game after a rematch opens with no grace_ms',
        (_Fx fx, _Table t) async {
      // Seat 2 acts last in the first game, so a server that remembers who
      // acted last across games would grace seat 0's opening turn.
      _board(t, seat: 2, tokens: <int>[57, 57, 57, 54], queue: <int>[3]);
      final Map<int, List<Frame>> over =
          await t.step(2, 'move', <String, Object?>{'token': 3});
      fx.ok(_firstOfType(over[2]!, 'game_over') != null,
          'the first game ends on seat 2\'s move', _types(over[2]!));
      await t.step(0, 'rematch', <String, Object?>{});
      fx.send(t.c(2), 'rematch', <String, Object?>{});
      for (final int seat in <int>[0, 2]) {
        final List<Frame> seen = await drainUntil(
          t.c(seat),
          'turn',
          maxFrames: 12,
          perFrame: const Duration(seconds: 3),
        );
        fx.ok(
            _firstOfType(seen, 'game_started') != null,
            'seat $seat reads game_started before the opening turn',
            _types(seen));
        final Map<String, Object?> turn = _d(seen.last);
        fx.eq(turn['seat'], 0, 'the rematch opens on seat 0');
        fx.ok(!turn.containsKey('grace_ms'),
            'seat $seat: the opening turn of a rematch has no grace_ms', turn);
        fx.eq(turn['deadline_ms'], _budget, 'the opening deadline_ms');
      }
    });

    _scenario(
        'N10 ruleset $_v25: a passing turn has no grace_ms and the '
        'frames are unchanged', (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames = await _fourSquareMove(fx, t);
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: null, why: 'a 2026-10 room never has a grace');
      _expectShape(fx, frames, <int>[0, 2], <String>['moved', 'turn'],
          'frames of a 4-square move');
      fx.eq(
          _d(frames[0]!.last).keys.toList()..sort(),
          <String>['deadline_ms', 'phase', 'queue', 'seat', 'seq'],
          'the 2026-10 turn frame keeps exactly its old keys');
    }, ruleset: _v25);

    _scenario('N11 ruleset $_v25: a no-move pass has no grace_ms',
        (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames =
          await t.step(0, 'roll', <String, Object?>{});
      _expectShape(fx, frames, <int>[0, 2],
          <String>['rolled', 'turn_passed', 'turn'], 'a roll with no move');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 2, grace: null, why: 'a 2026-10 room never has a grace');
    }, ruleset: _v25, faces: <int>[3]);

    _scenario(
        'N12 ruleset $_v25: the segment expires at the budget, not later, '
        'and the snapshot has no grace_ms', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 400);
      final Map<String, Object?> snap = await _snapTurn(t, 0);
      fx.ok(!snap.containsKey('grace_ms'),
          '2026-10 snapshot 400 ms after the pass has no grace_ms', snap);
      fx.eq(snap['deadline_ms'], _budget - 400,
          'the 2026-10 countdown starts at the frame');
      fx.advanceTo(mark, _budget - 1);
      _expectSilent(fx, await t.sweep(), '2026-10 at budget - 1 ms');
      fx.advanceTo(mark, _budget);
      _expectTimerStep(
          fx, await t.sweep(), 2, 'rolled', '2026-10 at exactly the budget');
    }, ruleset: _v25);

    _scenario(
        'N13 the first turn expires at the budget exactly, no grace '
        'added', (_Fx fx, _Table t) async {
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, _budget - 1);
      _expectSilent(fx, await t.sweep(), 'opening turn at budget - 1 ms');
      fx.advanceTo(mark, _budget);
      _expectTimerStep(
          fx, await t.sweep(), 0, 'rolled', 'opening turn at the budget');
    });
  });

  // =========================================================================
  // The timer honours the grace.
  // =========================================================================
  group('rule 4: the timer starts the next seat\'s clock after the grace', () {
    _scenario(
        'T1 after a 1060 ms grace, 45 s: silent at 45000 and 46059, '
        'acts at 46060', (_Fx fx, _Table t) async {
      final Map<int, List<Frame>> frames = await _fourSquareMove(fx, t);
      fx.eq(_d(_lastOfType(frames[0]!, 'turn')!)['deadline_ms'], _budget,
          'rule 3: deadline_ms is the full budget');
      final DateTime mark = fx.mark();
      for (final int ms in <int>[0, 1000, _budget, _budget + 1059]) {
        fx.advanceTo(mark, ms);
        _expectSilent(fx, await t.sweep(), 'segment of seat 2 at +$ms ms');
      }
      fx.advanceTo(mark, _budget + 1060);
      _expectTimerStep(fx, await t.sweep(), 2, 'rolled',
          'segment of seat 2 at grace 1060 + budget 45000');
    });

    _scenario(
        'T2 after a 1500 ms grace (no move), 45 s: silent at 46499, '
        'acts at 46500', (_Fx fx, _Table t) async {
      await t.step(0, 'roll', <String, Object?>{});
      final DateTime mark = fx.mark();
      for (final int ms in <int>[_budget, _budget + 1499]) {
        fx.advanceTo(mark, ms);
        _expectSilent(fx, await t.sweep(), 'segment of seat 2 at +$ms ms');
      }
      fx.advanceTo(mark, _budget + 1500);
      _expectTimerStep(fx, await t.sweep(), 2, 'rolled',
          'segment of seat 2 at grace 1500 + budget 45000');
    }, faces: <int>[3]);

    _scenario(
        'T3 an away seat\'s 10 s segment starts after the grace too: '
        'silent at 11059, acts at 11060', (_Fx fx, _Table t) async {
      final DateTime mark = await _toAwayTurn(fx, t);
      for (final int ms in <int>[_awayBudget, _awayBudget + 1059]) {
        fx.advanceTo(mark, ms);
        _expectSilent(fx, await t.sweep(), 'away segment at +$ms ms');
      }
      fx.advanceTo(mark, _awayBudget + 1060);
      _expectTimerStep(fx, await t.sweep(), 2, 'rolled',
          'away segment at grace 1060 + budget 10000');
    }, faces: <int>[3]);

    _scenario(
        'T4 the seat on turn drops 300 ms into its grace: the grace and '
        'the budget stand', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 300);
      await _drop(t, 2);
      fx.advanceTo(mark, _budget + 1059);
      _expectSilent(
          fx,
          await t.sweep(),
          'a seat that dropped in its grace, '
          'at grace 1060 + budget 45000 - 1 ms');
      fx.advanceTo(mark, _budget + 1060);
      _expectTimerStep(fx, await t.sweep(), 2, 'rolled',
          'a seat that dropped in its grace, at grace + budget');
    });

    _scenario(
        'T5 the seat on turn resumes 400 ms into its grace: snapshot '
        'grace_ms 660, no turn pushed', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 300);
      await _drop(t, 2);
      fx.advanceTo(mark, 400);
      final Map<String, Object?> room = await _resume(t, 2);
      final Map<String, Object?> turn = room['turn']! as Map<String, Object?>;
      fx.eq(turn['grace_ms'], 660,
          'the resume answer 400 ms into a 1060 ms grace shows what is left');
      fx.eq(turn['deadline_ms'], _budget, 'and the full budget');
      final Map<int, List<Frame>> frames = await t.syncAll();
      fx.eq(
          _types(frames[0]!),
          <String>['presence'],
          'the other seat reads presence only: no turn is pushed on a resume '
          'of a seat whose segment is a full one');
    });

    // Rule 7, last bullet: section 26 rule 5 inside a grace. Seat 2 is away
    // (10 s segment) and its 1060 ms grace starts at the mark. Resuming at
    // 400 and 1059 is inside the grace; at 1060 (exactly) and 2000 it is not.
    // The restarted full segment counts from max(resume, grace end).
    for (final List<int?> c in <List<int?>>[
      <int?>[400, 660],
      <int?>[1059, 1],
      <int?>[1060, null],
      <int?>[2000, null],
    ]) {
      final int at = c[0]!;
      final int? left = c[1];
      final int expiry = max(at, 1060) + _budget;
      _scenario(
          'T6 an away seat resumes on turn $at ms into a 1060 ms grace: '
          'pushed turn ${left == null ? 'has no grace_ms' : 'grace_ms $left'}'
          ', the full segment expires at $expiry', (_Fx fx, _Table t) async {
        final DateTime mark = await _toAwayTurn(fx, t);
        fx.advanceTo(mark, at);
        final Map<String, Object?> room = await _resume(t, 2);
        final Map<int, List<Frame>> frames = await t.syncAll();
        fx.eq(_types(frames[0]!), <String>['presence', 'turn'],
            'the other seat reads presence then turn on the resume');
        fx.eq(_types(frames[2]!), <String>[],
            'the resuming socket reads neither: its room answer carries them');
        final Map<String, Object?> presence = _d(frames[0]!.first);
        fx.eq(<Object?>[presence['seat'], presence['connected']],
            <Object?>[2, true], 'the presence is the resume of seat 2');
        _expectTurn(fx, <int, List<Frame>>{0: frames[0]!}, <int>[0],
            next: 2,
            grace: left,
            why: 'rule 7: the pushed turn carries the grace left '
                '(1060 - $at), absent once the grace has run out',
            phase: 'await_roll');
        final Map<String, Object?> turn = _d(frames[0]!.last);
        fx.eq(turn['seq'], (presence['seq']! as int) + 1,
            'the pushed turn takes the next seq after the presence');
        final Map<String, Object?> snap = room['turn']! as Map<String, Object?>;
        fx.eq(snap['seat'], 2, 'the resumer\'s snapshot is on seat 2');
        fx.eq(snap['deadline_ms'], _budget,
            'the resumer\'s deadline_ms is the restarted full segment');
        fx.eq(snap['segment_ms'], _budget, 'and its segment_ms');
        if (left == null) {
          fx.ok(!snap.containsKey('grace_ms'),
              'no grace_ms in the resumer\'s snapshot after the grace', snap);
        } else {
          fx.eq(snap['grace_ms'], left, 'the resumer\'s snapshot grace left');
        }
        fx.eq(room['seq'], turn['seq'],
            'the resumer\'s room carries the seq of the pushed turn');
        // The old 10 s segment would end 10 000 ms after the grace's end.
        fx.advanceTo(mark, 1060 + _awayBudget);
        _expectSilent(fx, await t.sweep(), 'the old away segment\'s end');
        fx.advanceTo(mark, expiry - 1);
        _expectSilent(fx, await t.sweep(),
            'the restarted segment at its expiry - 1 ms ($expiry - 1)');
        fx.advanceTo(mark, expiry);
        _expectTimerStep(fx, await t.sweep(), 2, 'rolled',
            'the restarted segment at exactly $expiry ms after the frame');
      }, faces: <int>[3]);
    }

    _scenario(
        'T6b the snapshot after an away resume in the grace counts from the '
        'grace\'s end: 45000 - 1000 at 2060', (_Fx fx, _Table t) async {
      final DateTime mark = await _toAwayTurn(fx, t);
      fx.advanceTo(mark, 400);
      await _resume(t, 2);
      await t.syncAll();
      fx.advanceTo(mark, 1060 + 1000);
      final Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.ok(!turn.containsKey('grace_ms'),
          'the grace has run out, the key is absent', turn);
      fx.eq(turn['segment_ms'], _budget, 'the segment is the full one');
      fx.eq(turn['deadline_ms'], _budget - 1000,
          'rule 7: the restarted segment counts from the grace\'s end');
    }, faces: <int>[3]);
  });

  // =========================================================================
  // The snapshot.
  // =========================================================================
  group('rule 3: the snapshot during and after the grace', () {
    _scenario(
        'S1 400 ms into a 1060 ms grace: grace_ms 660, deadline_ms the '
        'full budget', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      fx.advanceTo(fx.mark(), 400);
      final Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.eq(turn['seat'], 2, 'the snapshot names the next seat');
      fx.eq(turn['grace_ms'], 660, 'grace left: 1060 - 400');
      fx.eq(turn['deadline_ms'], _budget, 'deadline_ms is the full budget');
      fx.eq(turn['segment_ms'], _budget, 'segment_ms is the budget');
    });

    _scenario(
        'S2 the grace runs out: grace_ms 1 at 1059, absent at 1060, '
        'deadline_ms counts from the grace\'s end', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 1059);
      Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.eq(turn['grace_ms'], 1, 'one millisecond of grace left at 1059');
      fx.eq(turn['deadline_ms'], _budget, 'still the full budget');
      fx.advanceTo(mark, 1060);
      turn = await _snapTurn(t, 0);
      fx.ok(!turn.containsKey('grace_ms'),
          'a grace of 0 left is absent, never 0', turn);
      fx.eq(turn['deadline_ms'], _budget, 'the countdown starts at 1060');
      fx.advanceTo(mark, 1060 + 1000);
      turn = await _snapTurn(t, 0);
      fx.ok(!turn.containsKey('grace_ms'),
          'after the grace the snapshot has no grace_ms', turn);
      fx.eq(turn['deadline_ms'], _budget - 1000,
          'deadline_ms counts down from the grace\'s end: 45000 - 1000');
    });

    _scenario(
        'S3 an away seat\'s grace: grace_ms 660 and the full 10000 '
        'budget 400 ms in', (_Fx fx, _Table t) async {
      final DateTime mark = await _toAwayTurn(fx, t);
      fx.advanceTo(mark, 400);
      final Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.eq(turn['grace_ms'], 660, 'grace left: 1060 - 400');
      fx.eq(turn['deadline_ms'], _awayBudget, 'the away budget, in full');
      fx.eq(turn['segment_ms'], _awayBudget, 'segment_ms is the away budget');
    }, faces: <int>[3]);

    _scenario(
        'S4 a snapshot after a no-move pass: grace 1500 shown, then '
        'counting', (_Fx fx, _Table t) async {
      await t.step(0, 'roll', <String, Object?>{});
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 500);
      Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.eq(turn['grace_ms'], 1000, 'grace left: 1500 - 500');
      fx.eq(turn['deadline_ms'], _budget, 'the full budget');
      fx.advanceTo(mark, 2500);
      turn = await _snapTurn(t, 0);
      fx.ok(!turn.containsKey('grace_ms'), 'grace over', turn);
      fx.eq(turn['deadline_ms'], _budget - 1000, 'counted from 1500');
    }, faces: <int>[3]);
  });

  // =========================================================================
  // Rule 4: a roll inside the grace.
  // =========================================================================
  group('rule 4: a roll during the grace', () {
    _scenario(
        'R1 a roll 200 ms into the grace is accepted and its rolled '
        'restarts the segment', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      // Seat 2 has a token on the track, so the steered 3 leaves a move.
      _force(t, tokens: <int, List<int>>{
        2: <int>[5, -1, -1, -1]
      });
      fx.advanceTo(mark, 100);
      final Map<String, Object?> before = await _snapTurn(t, 0);
      fx.eq(before['grace_ms'], 960,
          'the roll below lands inside a grace: 1060 - 100 left');
      fx.advanceTo(mark, 200);
      final String id = fx.send(t.c(2), 'roll', <String, Object?>{});
      final Map<int, List<Frame>> frames = await t.syncAll(first: 2);
      _expectShape(fx, frames, <int>[0, 2], <String>['rolled'],
          'a roll inside the grace is accepted like any other');
      final Frame rolled = frames[2]!.single;
      fx.eq(rolled['re'], id, 'the rolled answers the roll');
      fx.eq(<Object?>[_d(rolled)['seat'], _d(rolled)['value']], <int>[2, 3],
          'seat 2 rolled the steered 3');
      fx.eq(_d(rolled)['legal'], <int>[0], 'a move is pending');
      _expectGraceOnlyOnTurn(fx, frames);
      // The roll ended the grace and started a full segment at +200.
      fx.advanceTo(mark, 1200);
      final Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.ok(!turn.containsKey('grace_ms'),
          'the roll ended the grace: the snapshot has no grace_ms', turn);
      fx.eq(
          turn['deadline_ms'],
          _budget - 1000,
          'the segment restarted at the rolled (+200), so 1000 ms on it has '
          '44000 left, not the 44860 of the old one');
      fx.advanceTo(mark, 200 + _budget - 1);
      _expectSilent(fx, await t.sweep(), 'the restarted segment at -1 ms');
      fx.advanceTo(mark, 200 + _budget);
      _expectTimerStep(fx, await t.sweep(), 2, 'moved',
          'the restarted segment at exactly budget after the rolled');
    }, faces: <int>[3]);

    _scenario(
        'R2 a roll 200 ms into the grace that passes: the next seat '
        'gets its own 1500 ms grace', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 200);
      fx.send(t.c(2), 'roll', <String, Object?>{});
      final Map<int, List<Frame>> frames = await t.syncAll(first: 2);
      _expectShape(
          fx,
          frames,
          <int>[0, 2],
          <String>['rolled', 'turn_passed', 'turn'],
          'a roll with no move inside the grace');
      _expectTurn(fx, frames, <int>[0, 2],
          next: 0,
          grace: 1500,
          why: 'the roll\'s own pass: travel 0, hold 1500, never what was '
              'left of the first grace');
    }, faces: <int>[3]);

    _scenario(
        'R3 the seat that moved acts during the next seat\'s grace: '
        'NOT_YOUR_TURN and the grace is untouched', (_Fx fx, _Table t) async {
      await _fourSquareMove(fx, t);
      final DateTime mark = fx.mark();
      fx.advanceTo(mark, 100);
      for (final String type in <String>['roll', 'move']) {
        final Map<String, Object?> data = type == 'move'
            ? <String, Object?>{'token': 0}
            : <String, Object?>{};
        final Map<int, List<Frame>> frames = await t.step(0, type, data);
        fx.eq(_types(frames[0]!), <String>['error'],
            'seat 0 sends $type on seat 2\'s turn');
        fx.eq(_d(frames[0]!.single)['code'], 'NOT_YOUR_TURN',
            'the code for $type');
        fx.eq(_types(frames[2]!), <String>[], 'seat 2 reads nothing');
      }
      fx.advanceTo(mark, 400);
      final Map<String, Object?> turn = await _snapTurn(t, 0);
      fx.eq(turn['grace_ms'], 660,
          'the refused actions left the grace running: 1060 - 400');
    });
  });
}

/// The two-seat steered game up to seat 2's second turn while away, in the
/// instant seat 0's move hands it over: seat 2 drops first, plays its first
/// turn on the timer (the roll steered to 3, a pass), then seat 0 moves 4
/// squares. Returns the clock instant of the frame that gives seat 2 the
/// turn, and checks that frame's 10 000 ms budget.
Future<DateTime> _toAwayTurn(_Fx fx, _Table t) async {
  await _drop(t, 2);
  await _fourSquareMove(fx, t);
  final DateTime first = fx.mark();
  fx.advanceTo(first, _budget + 1060);
  final Map<int, List<Frame>> timer = await t.sweep();
  _expectTimerStep(
      fx, timer, 2, 'rolled', 'seat 2\'s first turn, on the timer');
  fx.eq(_types(timer[0]!), <String>['rolled', 'turn_passed', 'turn'],
      'seat 2\'s timer roll is the steered 3 and passes');
  // Seat 0's grace is over before it moves.
  fx.advanceTo(first, _budget + 1060 + 1500);
  _board(t, tokens: <int>[14, -1, -1, -1], queue: <int>[4]);
  final Map<int, List<Frame>> frames =
      await t.step(0, 'move', <String, Object?>{'token': 0});
  final Frame? turn = _lastOfType(frames[0]!, 'turn');
  fx.ok(turn != null && _d(turn)['seat'] == 2,
      'seat 0\'s move hands the turn to seat 2', _types(frames[0]!));
  fx.eq(_d(turn!)['deadline_ms'], _awayBudget,
      'section 26: seat 2 was away for a whole turn, so its segment is 10 s');
  return fx.mark();
}
