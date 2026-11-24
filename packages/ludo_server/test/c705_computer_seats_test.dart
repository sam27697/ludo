// Order C-705t: docs/PROTOCOL.md section 34 items 1 to 4 and 6 (computer
// seats: the snapshot, play_computer, fill_computer and fill_ms, the pace,
// leaving, kicks, rematch, reaping and the verify record). The choice (item
// 5) is in c705_computer_choice_test.dart, which reuses the rig below.
//
// Written from the section only. Real sockets against a real WireServer on a
// loopback port, the FakeClock injected everywhere, the automatic sweeps off:
// the test moves the clock and calls the two sweeps itself
// (`server.runTurnExpiryOnce()` and `registry.runComputerSeatsOnce()`), 100
// ms at a time, the way the binary's 100 ms timer does. Nothing sleeps for a
// fixed time. "Nothing else arrived" is proved with the ping barrier of the
// c700 rig.
//
// Fixed names the implementation shares with this file: the registry takes
// `computerRandom`, a `Random Function()` called once per room; the computer
// sweep is `registry.runComputerSeatsOnce()` and reads the injected clock.
//
// Reproduction: every scenario prints its name and its seeds. The registry's
// own CSPRNG slot gets `Random(seed)` and the computer source gets
// `Random(computerSeed * 1000 + n)` for the n-th room, so a failing run is
// replayed by the command in the failure text.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/c700_harness.dart';

const String _file = 'c705_computer_seats_test.dart';

/// Section 34 item 1: the six characters.
const Map<int, String> c705Names = <int, String>{
  1: 'Zuzu',
  2: 'Nono',
  3: 'Kiko',
  4: 'Bobo',
  5: 'Tutu',
  6: 'Mimi',
};

// ---------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------

/// The c700 rig with the seeded computer source and the computer sweep.
class C705Rig extends C700Rig {
  C705Rig(super.name, {super.ruleset, this.seed = 705, int? computerSeed})
      : computerSeed = computerSeed ?? seed * 7;

  final int seed;
  final int computerSeed;
  int _roomsDrawn = 0;

  @override
  Future<void> boot() async {
    registry = RoomRegistry(
      clock: clock,
      secure: Random(seed),
      ruleset: ruleset,
      computerRandom: () => Random(computerSeed * 1000 + (++_roomsDrawn)),
    );
    server = WireServer(
      registry: registry,
      rateLimiter: RateLimiter(clock: clock),
      clock: clock,
      automaticTurnExpiry: false,
      trustedProxies: const <String>{'127.0.0.1'},
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    uri = Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');
  }

  /// Moves the fake clock by [ms] in steps of 100 ms (at most the sweep the
  /// contract allows), running both sweeps after every step.
  void step(int ms) {
    assert(ms % 100 == 0, 'step only moves whole sweeps of 100 ms');
    for (int i = 0; i < ms ~/ 100; i++) {
      clock.advance(const Duration(milliseconds: 100));
      server.runTurnExpiryOnce();
      registry.runComputerSeatsOnce();
    }
  }

  void jump(int ms) => clock.advance(Duration(milliseconds: ms));
}

void c705Scenario(
  String name,
  Future<void> Function(C705Rig r) body, {
  String ruleset = '2026-10',
  int seed = 705,
  int? computerSeed,
  Timeout? timeout,
  String file = _file,
}) {
  test(name, () async {
    final C705Rig r = C705Rig(
      name,
      ruleset: ruleset,
      seed: seed,
      computerSeed: computerSeed,
    );
    final String repro = 'scenario: "$name" ruleset=$ruleset seed=$seed '
        'computerSeed=${r.computerSeed} (fake clock, fresh IPs and installs). '
        'Reproduce with: cd packages/ludo_server && dart test test/$file -n '
        '"$name"';
    try {
      await r.boot();
      await body(r);
    } on TestFailure catch (e) {
      throw TestFailure('${e.message}\n$repro');
    } on Object catch (e, s) {
      throw TestFailure('scenario died with ${e.runtimeType}: $e\n$s\n$repro');
    } finally {
      await r.dispose();
    }
  }, timeout: timeout);
}

// ---------------------------------------------------------------------
// play_computer
// ---------------------------------------------------------------------

/// A human seat made by `play_computer`: the frames up to the opening turn.
class Game705 {
  Game705(this.c, this.id, this.start, this.startedAt);

  final C700Client c;
  final String id;
  final List<Map<String, Object?>> start;
  final DateTime startedAt;

  Map<String, Object?> _first(String t) => start.firstWhere(
        (Map<String, Object?> f) => f['t'] == t,
        orElse: () => throw TestFailure(
          'play_computer frames carry no "$t": '
          '${fdescAll(start)}',
        ),
      );

  Map<String, Object?> get roomFrame => _first('room');
  Map<String, Object?> get room => fd(roomFrame);
  int get seat => fd(_first('seat_assigned'))['seat']! as int;
  String get token => fd(_first('seat_assigned'))['seat_token']! as String;
  String get code => room['code']! as String;
  Map<String, Object?> get openingTurn => fd(start.last);

  /// The seats of the room snapshot that are computer seats.
  Set<int> get botSeats => botSeatsOf(room);
}

Set<int> botSeatsOf(Map<String, Object?> room) => <int>{
      for (final Object? s in room['seats']! as List<Object?>)
        if ((s! as Map<String, Object?>).containsKey('bot'))
          (s as Map<String, Object?>)['seat']! as int,
    };

List<Map<String, Object?>> seatMaps(Map<String, Object?> room) =>
    <Map<String, Object?>>[
      for (final Object? s in room['seats']! as List<Object?>)
        s! as Map<String, Object?>,
    ];

/// Sends `play_computer` and reads up to and including the first `turn`.
Future<Game705> playComputer(
  C705Rig r, {
  int players = 2,
  String name = 'Ann',
  String? clientSeed,
  String? ip,
  String? install,
  C700Client? on,
}) async {
  final C700Client c = on ?? await r.open(ip ?? r.freshIp(), 'pc-$name');
  final String id = c.send('play_computer', <String, Object?>{
    'name': name,
    'players': players,
    'install': install ?? r.freshInstall('pc'),
    if (clientSeed != null) 'client_seed': clientSeed,
  });
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  for (int i = 0; i < 40; i++) {
    final Map<String, Object?> f = await c.next();
    frames.add(f);
    if (f['t'] == 'error') {
      throw TestFailure(
        'play_computer {players: $players} should start a '
        'game against the computer; the server answered '
        '${fdesc(f)}',
      );
    }
    if (f['t'] == 'turn') {
      return Game705(c, id, frames, r.clock.now);
    }
  }
  throw TestFailure(
    'play_computer: no turn frame within 40 frames; saw '
    '${fdescAll(frames)}',
  );
}

// ---------------------------------------------------------------------
// The scripted human and the frame log
// ---------------------------------------------------------------------

class Frame705 {
  Frame705(this.f, this.at);

  final Map<String, Object?> f;
  final DateTime at;

  String get t => f['t']! as String;
  Map<String, Object?> get d => fd(f);
  int? get seat => d['seat'] as int?;
}

/// Plays a human seat with the simplest strategy (roll when a roll is owed,
/// move the first legal token), reading its socket with the ping barrier and
/// moving the fake clock 100 ms whenever there was nothing to answer.
class Driver {
  Driver(this.r, this.g, {this.auto = true}) {
    for (final Map<String, Object?> f in g.start) {
      log.add(Frame705(f, g.startedAt));
    }
    // The opening turn was read by playComputer; answer it when it is ours.
    _react(g.start.last);
  }

  /// Answers the latest turn frame when it is ours and nothing of ours came
  /// after it. Used after a stretch played with [auto] off.
  void catchUp() {
    for (final Frame705 fr in log.reversed) {
      if (fr.seat == g.seat && (fr.t == 'rolled' || fr.t == 'moved')) {
        return;
      }
      if (fr.t == 'turn') {
        _react(fr.f);
        return;
      }
    }
  }

  final C705Rig r;
  final Game705 g;
  bool auto;
  final List<Frame705> log = <Frame705>[];
  final List<Frame705> _queue = <Frame705>[];

  bool _react(Map<String, Object?> f) {
    if (!auto) {
      return false;
    }
    final Map<String, Object?> d = fd(f);
    if (d['seat'] != g.seat) {
      return false;
    }
    if (f['t'] == 'turn') {
      if (d['phase'] == 'await_roll') {
        g.c.send('roll', <String, Object?>{});
        return true;
      }
      final List<Object?> legal = (d['legal'] as List<Object?>?) ?? <Object?>[];
      if (d['phase'] == 'await_move' && legal.isNotEmpty) {
        g.c.send('move', <String, Object?>{'token': legal.first});
        return true;
      }
    }
    if (f['t'] == 'rolled') {
      final List<Object?> legal = (d['legal'] as List<Object?>?) ?? <Object?>[];
      if (legal.isNotEmpty) {
        g.c.send('move', <String, Object?>{'token': legal.first});
        return true;
      }
    }
    return false;
  }

  /// Runs until a frame satisfies [until] and returns it. Frames after it
  /// stay queued for the next call. [tick] false never moves the clock.
  Future<Frame705> run({
    required bool Function(Frame705 fr) until,
    required String row,
    int maxIter = 200000,
    bool tick = true,
  }) async {
    for (int i = 0; i < maxIter; i++) {
      if (_queue.isEmpty) {
        final DateTime now = r.clock.now;
        for (final Map<String, Object?> f in await g.c.sync()) {
          _queue.add(Frame705(f, now));
        }
      }
      bool acted = false;
      while (_queue.isNotEmpty) {
        final Frame705 fr = _queue.removeAt(0);
        log.add(fr);
        if (until(fr)) {
          return fr;
        }
        if (fr.t == 'error') {
          throw TestFailure(
            '$row: the scripted human received an unexpected '
            '${fdesc(fr.f)} at ${fr.at.toIso8601String()}; last frames: '
            '${fdescAll(<Map<String, Object?>>[
                  for (final Frame705 x
                      in log.reversed.take(8).toList().reversed)
                    x.f
                ])}',
          );
        }
        acted = _react(fr.f) || acted;
      }
      if (!acted && tick) {
        r.step(100);
      }
    }
    throw TestFailure(
      '$row: the condition never came within $maxIter '
      'iterations (fake time now ${r.clock.now.toIso8601String()}); last '
      'frames: ${fdescAll(<Map<String, Object?>>[
            for (final Frame705 x in log.reversed.take(10).toList().reversed)
              x.f
          ])}',
    );
  }

  /// Runs until a `turn` frame for one of [bots] is read, with the clock not
  /// moved after it. The opening turn counts.
  Future<Frame705> untilComputerTurn(Set<int> bots, String row) async {
    final Frame705 first = log.last;
    if (_queue.isEmpty && first.t == 'turn' && bots.contains(first.seat)) {
      return first;
    }
    return run(
      until: (Frame705 fr) => fr.t == 'turn' && bots.contains(fr.seat),
      row: row,
    );
  }
}

/// The pace of every computer action in [log] (item 4): the time from the
/// frame that left the seat to act, less any grace that frame carried, must be
/// in 800..1700 ms, and no computer frame carries `by`.
class PaceReport {
  final List<String> violations = <String>[];
  final List<int> elapsed = <int>[];
  int graceTurns = 0;
  int actions = 0;
}

PaceReport paceReport(List<Frame705> log, Set<int> bots) {
  final PaceReport p = PaceReport();
  final Map<int, DateTime> leftAt = <int, DateTime>{};
  final Map<int, int> grace = <int, int>{};
  for (final Frame705 fr in log) {
    final int? s = fr.seat;
    if (s == null || !bots.contains(s)) {
      continue;
    }
    if (fr.t == 'rolled' || fr.t == 'moved') {
      p.actions++;
      if (fr.d.containsKey('by')) {
        p.violations.add(
          '${fr.t} of computer seat $s carries by='
          '${fr.d['by']} (${fdesc(fr.f)})',
        );
      }
      final DateTime? from = leftAt.remove(s);
      if (from == null) {
        p.violations.add(
          '${fr.t} of computer seat $s at '
          '${fr.at.toIso8601String()} had no frame that left it to act',
        );
      } else {
        final int ms = fr.at.difference(from).inMilliseconds - (grace[s] ?? 0);
        p.elapsed.add(ms);
        if (ms < 800 || ms > 1700) {
          p.violations.add(
            '${fr.t} of computer seat $s came $ms ms after '
            'the frame that left it to act (grace ${grace[s] ?? 0} ms '
            'taken off), expected 800..1700: ${fdesc(fr.f)}',
          );
        }
      }
    }
    if (fr.t == 'turn') {
      leftAt[s] = fr.at;
      grace[s] = (fr.d['grace_ms'] as int?) ?? 0;
      if ((grace[s] ?? 0) > 0) {
        p.graceTurns++;
      }
    }
    if (fr.t == 'rolled' &&
        ((fr.d['legal'] as List<Object?>?) ?? <Object?>[]).isNotEmpty) {
      leftAt[s] = fr.at;
      grace[s] = 0;
    }
  }
  return p;
}

// ---------------------------------------------------------------------
// Forcing positions
// ---------------------------------------------------------------------

/// A position with a yard release owed to [seat] (section 28 item 2), the
/// face [face] queued.
void forceReleaseOwed(
  C705Rig r,
  String code, {
  required int seat,
  required int face,
  required Map<int, List<int>> rows,
}) {
  final Room room = r.registry.lookup(code)!;
  final Map<String, Object?> json = room.game!.toJson();
  json['currentSeat'] = seat;
  json['phase'] = 'awaitMove';
  json['queue'] = <int>[face];
  json['sixes'] = 0;
  json['releaseOwed'] = true;
  final List<Object?> tokens = json['tokens']! as List<Object?>;
  rows.forEach((int s, List<int> row) => tokens[s] = row);
  room.game = engine.GameState.fromJson(json);
  room.turnSegmentStartedAt = r.clock.now;
}

/// Puts [seat] one face from winning: tokens 0..2 home, token 3 on 56 with a
/// 1 queued. The seat's `move` of token 3 then ends the game.
void forceOneFromWin(C705Rig r, String code, int seat) {
  forceTurn(
    r,
    code,
    seat: seat,
    queue: <int>[1],
    tokens: <int, List<int>>{
      seat: <int>[57, 57, 57, 56],
    },
  );
}

/// Wins the game for the human seat of [g] and returns `game_over`.
Future<Map<String, Object?>> winNow(C705Rig r, Game705 g) async {
  forceOneFromWin(r, g.code, g.seat);
  g.c.send('move', <String, Object?>{'token': 3});
  return g.c.untilType('game_over');
}

// ---------------------------------------------------------------------
// Small readers
// ---------------------------------------------------------------------

Future<List<Map<String, Object?>>> untilTurnFrame(C700Client c) async {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (int i = 0; i < 60; i++) {
    final Map<String, Object?> f = await c.next();
    out.add(f);
    if (f['t'] == 'turn') {
      return out;
    }
    if (f['t'] == 'error') {
      return out;
    }
  }
  throw TestFailure('no turn frame within 60 frames; saw ${fdescAll(out)}');
}

Future<void> expectSilent(C700Client c, String row, String what) async {
  final List<Map<String, Object?>> extra = await c.sync();
  expect(
    extra,
    isEmpty,
    reason: '$row: expected nothing else on ${c.label} $what; got '
        '${fdescAll(extra)}',
  );
}

/// A snapshot read by resuming [h]'s seat on a fresh socket (the old socket
/// of that seat is displaced).
Future<Map<String, Object?>> snapshotOf(C705Rig r, Held h) =>
    resumeRoom(r, h.code, h.token, 'snap-${h.seat}');

void expectBotSeat(Map<String, Object?> seat, String row, {int? seatNo}) {
  final String got = jsonEncode(seat);
  expect(
    seat['via'],
    'bot',
    reason: '$row: item 1: a computer seat has via "bot"; got $got',
  );
  expect(
    seat['connected'],
    true,
    reason: '$row: item 1: a computer seat is connected: true; got $got',
  );
  expect(
    seat['bot'],
    isA<int>(),
    reason: '$row: item 1: a computer seat carries "bot": int; got $got',
  );
  final int bot = seat['bot']! as int;
  expect(
    bot >= 1 && bot <= 6,
    isTrue,
    reason: '$row: item 1: bot is 1..6; got $got',
  );
  expect(
    seat['name'],
    c705Names[bot],
    reason: '$row: item 1: the name is the English name of character $bot '
        '(${c705Names[bot]}); got $got',
  );
  if (seatNo != null) {
    expect(seat['seat'], seatNo, reason: '$row: seat number; got $got');
  }
}

void expectBotsDistinct(Map<String, Object?> room, String row) {
  final List<int> bots = <int>[
    for (final Map<String, Object?> s in seatMaps(room))
      if (s.containsKey('bot')) s['bot']! as int,
  ];
  expect(
    bots.toSet().length,
    bots.length,
    reason: '$row: item 1: characters in one room are distinct (drawn '
        'without replacement); got bot ids $bots in '
        '${jsonEncode(room['seats'])}',
  );
}

// ---------------------------------------------------------------------
// The suite
// ---------------------------------------------------------------------

void main() {
  group('section 34 item 2: play_computer', () {
    c705Scenario('PC-01 two seats: frame order, snapshot, seeds, open false', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 2);
      expect(
        ftypes(g.start),
        <String>[
          'seat_assigned',
          'room',
          'seat_seed',
          'seat_seed',
          'game_started',
          'turn',
        ],
        reason: 'PC-01: item 2 order is seat_assigned, room, every '
            'seat_seed, game_started, turn; got ${fdescAll(g.start)}',
      );
      expect(
        g.roomFrame['re'],
        g.id,
        reason: 'PC-01: the room frame answers the request (re); got '
            '${fdesc(g.roomFrame)}',
      );
      final Map<String, Object?> room = g.room;
      expect(
        room['state'],
        'LOBBY',
        reason: 'PC-01: the room frame is the LOBBY snapshot, every seat '
            'filled; got ${jsonEncode(room)}',
      );
      expect(
        room['open'],
        false,
        reason: 'PC-01: item 1: a computer room has open false; got '
            '${room['open']}',
      );
      expect(
        room['players'],
        2,
        reason: 'PC-01: players; got ${room['players']}',
      );
      expect(
          seatNumbers(room),
          <int>[
            0,
            2,
          ],
          reason: 'PC-01: two seats are 0 and 2; got ${room['seats']}');
      final Map<String, Object?> host = seatOf(room, 0);
      expect(host['via'], 'host', reason: 'PC-01: caller is host; got $host');
      expect(
        host.containsKey('bot'),
        isFalse,
        reason: 'PC-01: a human seat has no bot key; got $host',
      );
      expectBotSeat(seatOf(room, 2), 'PC-01', seatNo: 2);
      expect(room['host_seat'], 0, reason: 'PC-01: host_seat');
      expect(
        (room['rules']! as Map<String, Object?>)['turn_seconds'],
        45,
        reason: 'PC-01: default rules; got ${room['rules']}',
      );
      final List<Map<String, Object?>> seeds = <Map<String, Object?>>[
        for (final Map<String, Object?> f in g.start)
          if (f['t'] == 'seat_seed') fd(f),
      ];
      expect(
        <int>[for (final Map<String, Object?> s in seeds) s['seat']! as int]
          ..sort(),
        <int>[0, 2],
        reason: 'PC-01: one seat_seed per seat; got ${jsonEncode(seeds)}',
      );
      for (final Map<String, Object?> s in seeds) {
        expect(
          s['origin'],
          'server',
          reason: 'PC-01: with no client_seed every seed is the '
              "server's; got ${jsonEncode(s)}",
        );
      }
      expect(
        fd(g.start[4])['turn'],
        g.openingTurn['seat'],
        reason: 'PC-01: turn.seat equals game_started.turn',
      );
      final Map<String, Object?> snap = await resumeRoom(
        r,
        g.code,
        g.token,
        'pc01-snap',
      );
      expect(
        snap['state'],
        'PLAYING',
        reason: 'PC-01: the game is started; got ${snap['state']}',
      );
      expect(snap['open'], false);
    });

    c705Scenario('PC-02 four seats: three computers, distinct ids, names', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 4);
      expect(
        ftypes(g.start),
        <String>[
          'seat_assigned',
          'room',
          'seat_seed',
          'seat_seed',
          'seat_seed',
          'seat_seed',
          'game_started',
          'turn',
        ],
        reason: 'PC-02: item 2 order with four seats; got '
            '${fdescAll(g.start)}',
      );
      expect(seatNumbers(g.room), <int>[0, 1, 2, 3]);
      expect(
          g.botSeats,
          <int>{
            1,
            2,
            3,
          },
          reason: 'PC-02: seats 1, 2, 3 are computers; got ${g.room['seats']}');
      for (final int s in <int>[1, 2, 3]) {
        expectBotSeat(seatOf(g.room, s), 'PC-02', seatNo: s);
      }
      expectBotsDistinct(g.room, 'PC-02');
      expect(g.room['open'], false);
      expect(seatOf(g.room, 0).containsKey('bot'), isFalse);
    });

    c705Scenario('PC-03 client_seed is applied to the host seat only', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(
        r,
        players: 2,
        clientSeed: 'my-seed_01',
      );
      final Map<String, Object?> hostSeed = fd(
        g.start.firstWhere(
          (Map<String, Object?> f) =>
              f['t'] == 'seat_seed' && fd(f)['seat'] == 0,
        ),
      );
      expect(
        hostSeed['client_seed'],
        'my-seed_01',
        reason: 'PC-03: item 2: client_seed applied to the host seat; got '
            '${jsonEncode(hostSeed)}',
      );
      expect(
        hostSeed['origin'],
        'player',
        reason: 'PC-03: a caller-given seed has origin player; got '
            '${jsonEncode(hostSeed)}',
      );
      final Map<String, Object?> botSeed = fd(
        g.start.firstWhere(
          (Map<String, Object?> f) =>
              f['t'] == 'seat_seed' && fd(f)['seat'] == 2,
        ),
      );
      expect(
        botSeed['origin'],
        'server',
        reason: 'PC-03: item 1: the computer seed is set by the server; '
            'got ${jsonEncode(botSeed)}',
      );
      expect(botSeed['client_seed'], isNot('my-seed_01'));
      final Map<String, Object?> started = fd(
        g.start.firstWhere(
          (Map<String, Object?> f) => f['t'] == 'game_started',
        ),
      );
      expect(
        (started['client_seeds']! as String).contains('0:my-seed_01'),
        isTrue,
        reason: 'PC-03: game_started.client_seeds carries the host seed as '
            '0:my-seed_01; got ${started['client_seeds']}',
      );
    });

    final Map<String, Map<String, Object?>> bad =
        <String, Map<String, Object?>>{
      'players 3': <String, Object?>{'name': 'Ann', 'players': 3},
      'players absent': <String, Object?>{'name': 'Ann'},
      'players string': <String, Object?>{'name': 'Ann', 'players': '2'},
      'players null': <String, Object?>{'name': 'Ann', 'players': null},
      'players 0': <String, Object?>{'name': 'Ann', 'players': 0},
      'players 1': <String, Object?>{'name': 'Ann', 'players': 1},
      'players 5': <String, Object?>{'name': 'Ann', 'players': 5},
      'players true': <String, Object?>{'name': 'Ann', 'players': true},
      'name absent': <String, Object?>{'players': 2},
      'name integer': <String, Object?>{'name': 5, 'players': 2},
      'install short': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'install': 'short',
      },
      'install integer': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'install': 7,
      },
      'client_seed spaces': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'client_seed': 'bad seed!',
      },
      'client_seed empty': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'client_seed': '',
      },
      'client_seed 65 chars': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'client_seed': 'a' * 65,
      },
      'client_seed integer': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'client_seed': 5,
      },
      'unknown key': <String, Object?>{
        'name': 'Ann',
        'players': 2,
        'extra': 1,
      },
    };
    bad.forEach((String label, Map<String, Object?> payload) {
      c705Scenario('PC-04 BAD_FIELD: $label', (C705Rig r) async {
        final C700Client c = await r.open(r.freshIp(), 'bad');
        final String id = c.send('play_computer', payload);
        final Map<String, Object?> f = await c.next();
        expectError(
          f,
          'BAD_FIELD',
          'PC-04 ($label): item 2: a wrong shape is BAD_FIELD; payload '
              '${jsonEncode(payload)}',
        );
        expect(f['re'], id, reason: 'PC-04 ($label): error carries re');
        await expectSilent(c, 'PC-04 ($label)', 'after the BAD_FIELD');
        // The socket still holds no seat and no room was made for it.
        c.send('create_room', <String, Object?>{
          'name': 'Ann',
          'players': 2,
          'install': r.freshInstall('bad'),
        });
        final Map<String, Object?> sa = await c.next();
        expect(
          sa['t'],
          'seat_assigned',
          reason: 'PC-04 ($label): a rejected play_computer leaves the '
              'socket seatless; create_room then answered ${fdesc(sa)}',
        );
      });
    });

    c705Scenario(
      'PC-05 ALREADY_SEATED from a host, a guest and a computer-room seat',
      (C705Rig r) async {
        final Held h = await r.host(open: false, players: 2);
        final Dev d = r.dev('guest');
        final Held guest = await r.join(<String, Object?>{'link': h.linkId}, d);
        for (final (String who, C700Client c) in <(String, C700Client)>[
          ('a host', h.c),
          ('a guest', guest.c),
        ]) {
          final String id = c.send('play_computer', <String, Object?>{
            'name': 'Ann',
            'players': 2,
            'install': r.freshInstall('again'),
          });
          final Map<String, Object?> f = await c.untilType('error');
          expectError(
            f,
            'ALREADY_SEATED',
            'PC-05: item 2: play_computer from $who seat',
          );
          expect(f['re'], id);
        }
        final Game705 g = await playComputer(r, players: 2);
        g.c.send('play_computer', <String, Object?>{
          'name': 'Ann',
          'players': 4,
          'install': r.freshInstall('again'),
        });
        final Map<String, Object?> f = await g.c.untilType('error');
        expectError(
          f,
          'ALREADY_SEATED',
          'PC-05: item 2: play_computer from a computer-room seat',
        );
      },
    );

    c705Scenario('PC-06 a queued socket loses its ticket', (C705Rig r) async {
      final Dev d = r.dev('queued');
      final (C700Client c, String ticket) = await r.queue(d, 1, row: 'PC-06');
      expect(
        r.registry.line.tickets.length,
        1,
        reason: 'PC-06: fixture: one ticket held; ticket $ticket',
      );
      final Game705 g = await playComputer(r, on: c);
      expect(g.start, isNotEmpty);
      expect(
        r.registry.line.tickets,
        isEmpty,
        reason: 'PC-06: item 2: a ticket is dropped first; the line still '
            'holds ${r.registry.line.tickets.length}',
      );
      final Dev other = r.dev('next');
      await r.queue(other, 1, row: 'PC-06 next stranger is at the head');
    });

    c705Scenario('PC-07 an open knock is dropped first (withdrawn)', (
      C705Rig r,
    ) async {
      final Held h = await r.host(approval: true, players: 4);
      final Dev d = r.dev('knocker');
      final C700Client k = await r.open(d.ip, 'knocker');
      k.send('join_room', <String, Object?>{
        'code': h.code,
        'name': 'Knock',
        'install': d.install,
      });
      final Map<String, Object?> pending = await k.next();
      expect(
        pending['t'],
        'knock_pending',
        reason: 'PC-07: fixture: ${fdesc(pending)}',
      );
      final Map<String, Object?> knock = await h.c.untilType('knock');
      final Game705 g = await playComputer(r, on: k);
      expect(g.start, isNotEmpty);
      final Map<String, Object?> closed = await h.c.untilType('knock_closed');
      expect(fd(closed)['knock_id'], fd(knock)['knock_id']);
      expect(
        fd(closed)['outcome'],
        'withdrawn',
        reason: 'PC-07: item 2: an open knock is dropped first, closing '
            'withdrawn on the host; got ${fdesc(closed)}',
      );
    });

    c705Scenario(
      'PC-08 counts against the room creation limit like create_room',
      (C705Rig r) async {
        final String ip = r.freshIp();
        for (int i = 0; i < 3; i++) {
          await playComputer(r, ip: ip, name: 'P$i');
        }
        for (int i = 0; i < 2; i++) {
          await r.host(ip: ip, name: 'H$i');
        }
        final C700Client c = await r.open(ip, 'sixth');
        final String id = c.send('play_computer', <String, Object?>{
          'name': 'Six',
          'players': 2,
          'install': r.freshInstall('six'),
        });
        final Map<String, Object?> f = await c.next();
        expectError(
          f,
          'RATE_LIMITED',
          'PC-08: item 2: 3 play_computer + 2 create_room from one IP are '
              'five admitted creations; the sixth play_computer',
        );
        expect(f['re'], id);
        final C700Client c2 = await r.open(ip, 'sixth-create');
        c2.send('create_room', <String, Object?>{
          'name': 'Six',
          'players': 2,
          'install': r.freshInstall('six'),
        });
        expectError(
          await c2.next(),
          'RATE_LIMITED',
          'PC-08: the shared window also refuses a create_room',
        );
        final Game705 other = await playComputer(r, name: 'Else');
        expect(
          other.start,
          isNotEmpty,
          reason: 'PC-08: another IP is not limited',
        );
      },
    );

    c705Scenario('PC-09 never matchable; a code join is ROOM_STARTED', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 2);
      final Dev d = r.dev('late');
      final C700Client c = await r.open(d.ip, 'late');
      c.send('join_room', <String, Object?>{
        'code': g.code,
        'name': 'Late',
        'install': d.install,
      });
      expectError(
        await c.next(),
        'ROOM_STARTED',
        'PC-09: a code join to a started computer room',
      );
      final Dev s = r.dev('stranger');
      await r.queue(s, 1, row: 'PC-09 find_game finds no computer room');
      expect(
        r.registry.lookup(g.code)!.seats.length,
        2,
        reason: 'PC-09: the computer room gained no seat',
      );
    });

    c705Scenario('PC-10 characters: in range, distinct per room, varied', (
      C705Rig r,
    ) async {
      final List<List<int>> rooms = <List<int>>[];
      for (int i = 0; i < 10; i++) {
        final Game705 g = await playComputer(r, players: 4, name: 'R$i');
        expectBotsDistinct(g.room, 'PC-10 room $i');
        rooms.add(<int>[
          for (final Map<String, Object?> s in seatMaps(g.room))
            if (s.containsKey('bot')) s['bot']! as int,
        ]);
      }
      final Set<int> union = rooms.expand((List<int> l) => l).toSet();
      expect(
        union.length,
        greaterThanOrEqualTo(5),
        reason: 'PC-10: item 1: characters are drawn, not fixed; ten '
            '4-seat rooms gave only $union (rooms $rooms)',
      );
      expect(
        rooms.map((List<int> l) => l.join(',')).toSet().length,
        greaterThan(1),
        reason: 'PC-10: ten rooms gave the same characters in the same '
            'seats: $rooms',
      );
    });
  });

  group('section 34 item 1: the computer source is the injected one', () {
    Future<List<int>> botsOf(int seed, int computerSeed) async {
      final C705Rig r = C705Rig('seam', seed: seed, computerSeed: computerSeed);
      await r.boot();
      try {
        final Game705 g = await playComputer(r, players: 4);
        return <int>[
          for (final Map<String, Object?> s in seatMaps(g.room))
            if (s.containsKey('bot')) s['bot']! as int,
        ];
      } finally {
        await r.dispose();
      }
    }

    test(
      'PC-11 same computerRandom seed, same characters; the seed decides',
      () async {
        final List<int> a1 = await botsOf(1, 21);
        final List<int> a2 = await botsOf(2, 21);
        expect(
          a2,
          a1,
          reason: 'PC-11: item 4 (random source): two registries with the '
              'same computerRandom and different CSPRNG seeds must pick the '
              'same characters; got $a1 and $a2. Reproduce: dart test '
              'test/$_file -n "PC-11"',
        );
        final Set<String> others = <String>{
          for (final int cs in <int>[22, 23, 24, 25])
            (await botsOf(1, cs)).join(','),
        };
        others.add(a1.join(','));
        expect(
          others.length,
          greaterThan(1),
          reason: 'PC-11: five computerRandom seeds (21..25) gave one and '
              'the same assignment $a1: the characters do not come from the '
              'injected source. Reproduce: dart test test/$_file -n "PC-11"',
        );
      },
    );
  });

  group('section 34 item 3: fill_computer and fill_ms', () {
    c705Scenario(
      'FC-01 59999 ms is WRONG_PHASE, 60000 ms fills (one free seat)',
      (C705Rig r) async {
        final Held h = await r.host(open: true, players: 2);
        r.jump(59999);
        final String id0 = h.c.send('fill_computer', <String, Object?>{});
        final Map<String, Object?> e = await h.c.next();
        expectError(
          e,
          'WRONG_PHASE',
          'FC-01: item 3: 59 999 ms after creation',
        );
        expect(e['re'], id0);
        await expectSilent(h.c, 'FC-01', 'after the refusal');
        r.jump(1);
        final String id = h.c.send('fill_computer', <String, Object?>{});
        final List<Map<String, Object?>> frames = await untilTurnFrame(h.c);
        expect(
          ftypes(frames),
          <String>[
            'player_joined',
            'seat_seed',
            'seat_seed',
            'game_started',
            'turn',
          ],
          reason: 'FC-01: item 3 order with one free seat: player_joined '
              '(bot), its seat_seed, then the start (the host seat '
              'server seed), game_started, turn; got ${fdescAll(frames)}',
        );
        expect(
          frames.first['re'],
          id,
          reason: "FC-01: the host's copy of the first frame carries re; "
              'got ${fdesc(frames.first)}',
        );
        expect(fd(frames.first)['seat'], 2);
        final int bot = fd(frames.first)['bot']! as int;
        expect(
          fd(frames.first)['name'],
          c705Names[bot],
          reason: 'FC-01: player_joined name is the character name; got '
              '${fdesc(frames.first)}',
        );
        expect(
          fd(frames[1])['seat'],
          2,
          reason: 'FC-01: the computer seat seed follows its join at once',
        );
        expect(fd(frames[1])['origin'], 'server');
        for (final Map<String, Object?> f in frames.skip(1)) {
          expect(
            f['re'],
            isNull,
            reason: 'FC-01: only the first frame carries re; got ${fdesc(f)}',
          );
        }
        final Map<String, Object?> snap = await snapshotOf(r, h);
        expect(
          snap['open'],
          false,
          reason: 'FC-01: open becomes false; got ${snap['open']}',
        );
        expectBotSeat(seatOf(snap, 2), 'FC-01', seatNo: 2);
      },
    );

    c705Scenario('FC-02 a guest gets NOT_HOST', (C705Rig r) async {
      final Held h = await r.host(open: true, players: 4);
      final Held guest = await r.join(<String, Object?>{
        'link': h.linkId,
      }, r.dev('g'));
      r.jump(60000);
      final String id = guest.c.send('fill_computer', <String, Object?>{});
      final Map<String, Object?> e = await guest.c.untilType('error');
      expectError(e, 'NOT_HOST', 'FC-02: item 3: host only');
      expect(e['re'], id);
      final List<Map<String, Object?>> seen = await h.c.sync();
      expect(
        ftypes(seen),
        isNot(contains('game_started')),
        reason: 'FC-02: a refused fill started nothing; host saw '
            '${fdescAll(seen)}',
      );
    });

    c705Scenario('FC-03 a friends-only room is WRONG_PHASE', (C705Rig r) async {
      final Held h = await r.host(open: false, players: 4);
      r.jump(120000);
      h.c.send('fill_computer', <String, Object?>{});
      expectError(
        await h.c.next(),
        'WRONG_PHASE',
        'FC-03: item 3: open is false, two minutes after creation',
      );
    });

    c705Scenario('FC-04 a full room is WRONG_PHASE', (C705Rig r) async {
      final Held h = await r.host(open: true, players: 2);
      await r.join(<String, Object?>{'link': h.linkId}, r.dev('g'));
      r.jump(120000);
      h.c.send('fill_computer', <String, Object?>{});
      expectError(
        await h.untilError(),
        'WRONG_PHASE',
        'FC-04: item 3: no free seat',
      );
    });

    c705Scenario('FC-05 a room in PLAYING is WRONG_PHASE', (C705Rig r) async {
      final Held h = await r.host(open: true, players: 2);
      final Held guest = await r.join(<String, Object?>{
        'link': h.linkId,
      }, r.dev('g'));
      await r.start(h, <C700Client>[h.c, guest.c]);
      r.jump(120000);
      h.c.send('fill_computer', <String, Object?>{});
      expectError(
        await h.untilError(),
        'WRONG_PHASE',
        'FC-05: item 3: LOBBY only',
      );
    });

    c705Scenario('FC-06 a payload key is BAD_FIELD and changes nothing', (
      C705Rig r,
    ) async {
      final Held h = await r.host(open: true, players: 2);
      r.jump(60000);
      final String id = h.c.send('fill_computer', <String, Object?>{'x': 1});
      final Map<String, Object?> e = await h.c.next();
      expectError(
        e,
        'BAD_FIELD',
        'FC-06: item 3: any payload key, from the host at 60 000 ms',
      );
      expect(e['re'], id);
      expect(
        r.registry.lookup(h.code)!.seats.length,
        1,
        reason: 'FC-06: no computer seat was added by a refused fill',
      );
      h.c.send('fill_computer', <String, Object?>{});
      final List<Map<String, Object?>> frames = await untilTurnFrame(h.c);
      expect(
        frames.first['t'],
        'player_joined',
        reason: 'FC-06: the same host can then fill with {}; got '
            '${fdescAll(frames)}',
      );
    });

    c705Scenario(
      'FC-07 fill_ms counts down on the host and is absent elsewhere',
      (C705Rig r) async {
        final Held h = await r.host(open: true, players: 4);
        final Held guest = await r.join(<String, Object?>{
          'link': h.linkId,
        }, r.dev('g'));
        Future<Map<String, Object?>> hostSnap() => snapshotOf(r, h);
        Map<String, Object?> s = await hostSnap();
        expect(
          s['fill_ms'],
          60000,
          reason: "FC-07: item 3: at creation the host's fill_ms is 60000; "
              'got ${s['fill_ms']} in ${jsonEncode(s)}',
        );
        r.jump(20000);
        s = await hostSnap();
        expect(
          s['fill_ms'],
          40000,
          reason: 'FC-07: at +20 000 ms; got ${s['fill_ms']}',
        );
        r.jump(39999);
        s = await hostSnap();
        expect(
          s['fill_ms'],
          1,
          reason: 'FC-07: at +59 999 ms; got ${s['fill_ms']}',
        );
        final Map<String, Object?> g59 = await snapshotOf(r, guest);
        expect(
          g59.containsKey('fill_ms'),
          isFalse,
          reason: 'FC-07: a guest never sees fill_ms; got ${g59['fill_ms']}',
        );
        r.jump(1);
        s = await hostSnap();
        expect(
          s['fill_ms'],
          0,
          reason: 'FC-07: at +60 000 ms; got ${s['fill_ms']}',
        );
        r.jump(500000);
        s = await hostSnap();
        expect(
          s['fill_ms'],
          0,
          reason: 'FC-07: stays 0 once allowed; got ${s['fill_ms']}',
        );
      },
    );

    c705Scenario('FC-08 fill_ms is absent when no fill is possible', (
      C705Rig r,
    ) async {
      final Held control = await r.host(open: true, players: 4);
      expect((await snapshotOf(r, control))['fill_ms'], 60000,
          reason: 'FC-08: control: an open LOBBY room with a free seat does '
              'carry fill_ms on the host copy');
      final Held friends = await r.host(open: false, players: 4);
      expect(
        (await snapshotOf(r, friends)).containsKey('fill_ms'),
        isFalse,
        reason: 'FC-08: a friends-only room carries no fill_ms',
      );
      final Held full = await r.host(open: true, players: 2);
      await r.join(<String, Object?>{'link': full.linkId}, r.dev('g'));
      expect(
        (await snapshotOf(r, full)).containsKey('fill_ms'),
        isFalse,
        reason: 'FC-08: a full open room carries no fill_ms',
      );
      final Held playing = await r.host(open: true, players: 2);
      final Held pg = await r.join(<String, Object?>{
        'link': playing.linkId,
      }, r.dev('g2'));
      await r.start(playing, <C700Client>[playing.c, pg.c]);
      expect(
        (await snapshotOf(r, playing)).containsKey('fill_ms'),
        isFalse,
        reason: 'FC-08: a PLAYING room carries no fill_ms',
      );
    });

    c705Scenario(
      'FC-09 three free seats, an open knock closed full, not matchable',
      (C705Rig r) async {
        final Held h = await r.host(open: true, players: 4, approval: true);
        r.jump(50000);
        final Dev kd = r.dev('knocker');
        final C700Client k = await r.open(kd.ip, 'knocker');
        k.send('join_room', <String, Object?>{
          'code': h.code,
          'name': 'Knock',
          'install': kd.install,
        });
        expect((await k.next())['t'], 'knock_pending');
        final Map<String, Object?> knock = await h.c.untilType('knock');
        r.jump(10000);
        final String id = h.c.send('fill_computer', <String, Object?>{});
        final List<Map<String, Object?>> frames = await untilTurnFrame(h.c);
        expect(
          ftypes(frames),
          <String>[
            'knock_closed',
            'player_joined',
            'seat_seed',
            'player_joined',
            'seat_seed',
            'player_joined',
            'seat_seed',
            'seat_seed',
            'game_started',
            'turn',
          ],
          reason: 'FC-09: item 3 order: knocks close full, then each free '
              'seat lowest first (player_joined with bot, its seat_seed), '
              'then the start; got ${fdescAll(frames)}',
        );
        expect(
          frames.first['re'],
          id,
          reason: 'FC-09: the first frame of the host copy carries re',
        );
        expect(fd(frames.first)['knock_id'], fd(knock)['knock_id']);
        expect(
          fd(frames.first)['outcome'],
          'full',
          reason: 'FC-09: knock closes full; got ${fdesc(frames.first)}',
        );
        final List<int> joinedSeats = <int>[
          for (final Map<String, Object?> f in frames)
            if (f['t'] == 'player_joined') fd(f)['seat']! as int,
        ];
        expect(
            joinedSeats,
            <int>[
              1,
              2,
              3,
            ],
            reason: 'FC-09: lowest free seat first; got $joinedSeats');
        final List<int> ids = <int>[
          for (final Map<String, Object?> f in frames)
            if (f['t'] == 'player_joined') fd(f)['bot']! as int,
        ];
        expect(
          ids.toSet().length,
          3,
          reason: 'FC-09: three distinct characters; got $ids',
        );
        for (int i = 0; i < 3; i++) {
          expect(
            fd(frames[1 + 2 * i])['name'],
            c705Names[ids[i]],
            reason:
                'FC-09: player_joined name; got ${fdesc(frames[1 + 2 * i])}',
          );
          expect(
            fd(frames[2 + 2 * i])['seat'],
            joinedSeats[i],
            reason: "FC-09: each seat's seed follows its join",
          );
        }
        final Map<String, Object?> failed = await k.untilType('knock_failed');
        expect(
          fd(failed)['outcome'],
          'full',
          reason: 'FC-09: the knocker is told full; got ${fdesc(failed)}',
        );
        final Dev s = r.dev('stranger');
        await r.queue(
          s,
          1,
          row: 'FC-09: the filled room is no longer matchable',
        );
      },
    );

    c705Scenario('FC-10 the guest sees the same frames without re', (
      C705Rig r,
    ) async {
      final Held h = await r.host(open: true, players: 4);
      final Held guest = await r.join(<String, Object?>{
        'link': h.linkId,
      }, r.dev('g'));
      await h.c.sync();
      await guest.c.sync();
      r.jump(60000);
      h.c.send('fill_computer', <String, Object?>{});
      final List<Map<String, Object?>> hostFrames = await untilTurnFrame(h.c);
      final List<Map<String, Object?>> guestFrames = await untilTurnFrame(
        guest.c,
      );
      expect(
        ftypes(hostFrames),
        <String>[
          'player_joined',
          'seat_seed',
          'player_joined',
          'seat_seed',
          'seat_seed',
          'seat_seed',
          'game_started',
          'turn',
        ],
        reason: 'FC-10: two free seats, two server-seeded humans; got '
            '${fdescAll(hostFrames)}',
      );
      expect(
        ftypes(guestFrames),
        ftypes(hostFrames),
        reason: 'FC-10: the guest gets the same frames; got '
            '${fdescAll(guestFrames)}',
      );
      for (final Map<String, Object?> f in guestFrames) {
        expect(
          f['re'],
          isNull,
          reason: 'FC-10: no re on a guest copy; got ${fdesc(f)}',
        );
      }
      expect(
        <int>[
          for (final Map<String, Object?> f in guestFrames)
            if (f['t'] == 'player_joined') fd(f)['seat']! as int,
        ],
        <int>[2, 3],
      );
    });

    c705Scenario('FC-11 a rematch lobby restarts the 60 s count', (
      C705Rig r,
    ) async {
      final Held h = await r.host(open: true, players: 2);
      final Held guest = await r.join(<String, Object?>{
        'link': h.linkId,
      }, r.dev('g'));
      await r.start(h, <C700Client>[h.c, guest.c]);
      r.jump(300000);
      forceOneFromWin(r, h.code, h.seat);
      h.c.send('move', <String, Object?>{'token': 3});
      await h.c.untilType('game_over');
      h.c.send('rematch', <String, Object?>{});
      await h.c.untilType('room');
      guest.c.send('leave_room', <String, Object?>{});
      await guest.c.sync();
      await h.c.sync();
      r.jump(59999);
      h.c.send('fill_computer', <String, Object?>{});
      expectError(
        await h.untilError(),
        'WRONG_PHASE',
        'FC-11: item 3: 59 999 ms after the rematch returned the room to '
            'LOBBY (the room is 359 999 ms old)',
      );
      r.jump(1);
      h.c.send('fill_computer', <String, Object?>{});
      final List<Map<String, Object?>> frames = await untilTurnFrame(h.c);
      expect(
        frames.first['t'],
        'player_joined',
        reason: 'FC-11: allowed 60 000 ms after the rematch; got '
            '${fdescAll(frames)}',
      );
    });
  });

  group('section 34 item 4: how a computer seat plays', () {
    c705Scenario(
      'PL-01 a whole 2-seat game: pace 800..1700, no by, game_over',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 2);
        final Driver d = Driver(r, g);
        await d.run(
          until: (Frame705 f) => f.t == 'game_over',
          row: 'PL-01',
          maxIter: 400000,
        );
        final PaceReport p = paceReport(d.log, g.botSeats);
        expect(
          p.violations,
          isEmpty,
          reason: 'PL-01: item 4: every computer action waits 800..1600 ms '
              '(sweep 100 ms) and carries no by; ${p.violations.length} of '
              '${p.actions} actions broke it, first: '
              '${p.violations.take(3).join(' | ')}',
        );
        expect(
          p.actions,
          greaterThan(20),
          reason: 'PL-01: the computer played only ${p.actions} actions',
        );
        expect(
          p.elapsed.toSet().length,
          greaterThanOrEqualTo(4),
          reason: 'PL-01: item 4: the pace is drawn from 800..1600, not '
              'fixed; saw only ${p.elapsed.toSet()}',
        );
        expect(
          p.elapsed.reduce(min),
          lessThan(1000),
          reason: 'PL-01: a uniform draw over a whole game reaches the '
              'bottom of the range; shortest wait ${p.elapsed.reduce(min)}',
        );
        expect(
          p.elapsed.reduce(max),
          greaterThan(1400),
          reason: 'PL-01: a uniform draw over a whole game reaches the top '
              'of the range; longest wait ${p.elapsed.reduce(max)}',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    c705Scenario(
      'PL-02 four seats, one human and three computers, to game_over',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 4);
        final Driver d = Driver(r, g);
        await d.run(
          until: (Frame705 f) => f.t == 'game_over',
          row: 'PL-02',
          maxIter: 600000,
        );
        final PaceReport p = paceReport(d.log, g.botSeats);
        expect(
          p.violations,
          isEmpty,
          reason: 'PL-02: item 4 over three computers; ${p.violations.length} '
              'of ${p.actions} actions broke the pace, first: '
              '${p.violations.take(3).join(' | ')}',
        );
        final Set<int> actors = <int>{
          for (final Frame705 f in d.log)
            if ((f.t == 'rolled' || f.t == 'moved') &&
                g.botSeats.contains(f.seat))
              f.seat!,
        };
        expect(
          actors,
          g.botSeats,
          reason: 'PL-02: every computer seat acted; only $actors did',
        );
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );

    c705Scenario(
      'PL-03 a grace is added to the pace, never replaces it',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 2);
        final Driver d = Driver(r, g);
        await d.run(
          until: (Frame705 f) => f.t == 'game_over',
          row: 'PL-03',
          maxIter: 400000,
        );
        final PaceReport p = paceReport(d.log, g.botSeats);
        expect(
          p.graceTurns,
          greaterThan(3),
          reason: 'PL-03: fixture: a 2026-11 game must carry grace turns for '
              'the computer; saw ${p.graceTurns}',
        );
        expect(
          p.violations,
          isEmpty,
          reason: 'PL-03: item 4: the pace counts from the later of the '
              'frame and the end of the grace, so grace_ms + 800..1700 from '
              'a turn that carried a grace; ${p.violations.length} of '
              '${p.actions} broke it, first: ${p.violations.take(3).join(' | ')}',
        );
      },
      ruleset: '2026-11',
      timeout: const Timeout(Duration(minutes: 6)),
    );

    c705Scenario(
      'PL-04 the turn timer never fires for a computer seat at 45 s',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 2);
        final Driver d = Driver(r, g);
        await d.untilComputerTurn(g.botSeats, 'PL-04');
        final int bot = d.log.last.seat!;
        r.jump(46000);
        r.server.runTurnExpiryOnce();
        final List<Map<String, Object?>> after = await g.c.sync();
        for (final Map<String, Object?> f in after) {
          expect(
            fd(f).containsKey('by'),
            isFalse,
            reason: 'PL-04: item 4: the turn timer never acts for a '
                'computer seat; 46 s into its turn the timer sweep produced '
                '${fdesc(f)}',
          );
        }
        r.registry.runComputerSeatsOnce();
        final List<Map<String, Object?>> acted = await g.c.sync();
        final bool botActed = <Map<String, Object?>>[...after, ...acted].any(
          (Map<String, Object?> f) =>
              (f['t'] == 'rolled' || f['t'] == 'moved') && fd(f)['seat'] == bot,
        );
        expect(
          botActed,
          isTrue,
          reason: 'PL-04: the computer sweep acts for the seat once due; '
              'got ${fdescAll(after)} then ${fdescAll(acted)}',
        );
        for (final Map<String, Object?> f in acted) {
          expect(
            fd(f).containsKey('by'),
            isFalse,
            reason: 'PL-04: no by on a computer frame; got ${fdesc(f)}',
          );
        }
      },
    );

    c705Scenario('PL-05 a computer seat spends an owed yard release', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 2);
      final Driver d = Driver(r, g);
      await d.untilComputerTurn(g.botSeats, 'PL-05');
      final int bot = d.log.last.seat!;
      forceReleaseOwed(
        r,
        g.code,
        seat: bot,
        face: 3,
        rows: <int, List<int>>{
          bot: <int>[-1, -1, -1, -1],
          g.seat: <int>[20, -1, -1, -1],
        },
      );
      d.auto = false;
      final Frame705 moved = await d.run(
        until: (Frame705 f) => f.t == 'moved' && f.seat == bot,
        row: 'PL-05',
        maxIter: 40,
      );
      expect(
        moved.d['release'],
        true,
        reason: 'PL-05: item 4: a release owed is spent (section 28 item '
            '2: moved carries release: true); got ${fdesc(moved.f)}',
      );
      expect(
        moved.d['token'],
        0,
        reason: 'PL-05: the lowest releasable token; got ${fdesc(moved.f)}',
      );
      expect(moved.d['from'], -1);
      expect(moved.d['to'], 0);
      expect(moved.d.containsKey('by'), isFalse);
    }, ruleset: '2026-11');

    c705Scenario(
      'PL-06 no human socket: it waits; the pace restarts at the reconnect',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 2);
        final Driver d = Driver(r, g);
        await d.untilComputerTurn(g.botSeats, 'PL-06');
        final int bot = d.log.last.seat!;
        final String code = g.code;
        await g.c.close();
        await r.untilDown(code, g.seat);
        final String before = jsonEncode(
          r.registry.lookup(code)!.game!.toJson(),
        );
        r.step(5000);
        final String after = jsonEncode(
          r.registry.lookup(code)!.game!.toJson(),
        );
        expect(
          after,
          before,
          reason: 'PL-06: item 4: computer seats act only while a human '
              'socket is connected; after 5 s with none the engine state '
              'changed',
        );
        final C700Client c2 = await r.open(r.freshIp(), 'pl06-back');
        c2.send('resume', <String, Object?>{
          'code': code,
          'seat_token': g.token,
        });
        await c2.untilType('room');
        final DateTime back = r.clock.now;
        int? first;
        for (int ms = 100; ms <= 2500 && first == null; ms += 100) {
          r.step(100);
          for (final Map<String, Object?> f in await c2.sync()) {
            if ((f['t'] == 'rolled' || f['t'] == 'moved') &&
                fd(f)['seat'] == bot) {
              first ??= r.clock.now.difference(back).inMilliseconds;
            }
          }
        }
        expect(
          first,
          isNotNull,
          reason: 'PL-06: the computer never resumed within 2500 ms of the '
              'reconnect',
        );
        expect(
          first! >= 800 && first <= 1700,
          isTrue,
          reason: 'PL-06: item 4: the pace restarts from the reconnect, so '
              'the first action is 800..1700 ms after it; it came $first ms '
              'after (5 s were spent waiting before)',
        );
      },
    );

    c705Scenario(
      'PL-07 a computer seat is never retired as absent',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 4);
        r.step(200000);
        final Map<String, Object?> snap = await resumeRoom(
          r,
          g.code,
          g.token,
          'pl07',
        );
        for (final int s in g.botSeats) {
          final Map<String, Object?> seat = seatOf(snap, s);
          expect(
            seat['connected'],
            true,
            reason: 'PL-07: item 6: a computer seat is always connected; '
                'got $seat',
          );
        }
        expect(
          snap['retired'],
          isNot(anyElement(isIn(g.botSeats.toList()))),
          reason: 'PL-07: item 6: a computer seat is never retired as '
              'absent; 200 s in, retired = ${snap['retired']}',
        );
      },
      ruleset: '2026-11',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('section 34 item 6: kicks, rematch, reaping, records', () {
    c705Scenario(
      'EN-01 the host kicks a computer seat in PLAYING',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 4);
        final Driver d = Driver(r, g, auto: false);
        final String id = g.c.send('kick', <String, Object?>{'seat': 1});
        final Frame705 retired = await d.run(
          until: (Frame705 f) => f.t == 'seat_retired',
          row: 'EN-01',
          tick: false,
          maxIter: 20,
        );
        expect(retired.d['seat'], 1);
        expect(
          retired.d['reason'],
          'kicked',
          reason: 'EN-01: item 6 / section 33 item 8; got ${fdesc(retired.f)}',
        );
        expect(retired.d['host_seat'], 0);
        expect(retired.f['re'], id, reason: 'EN-01: the host copy carries re');
        d.auto = true;
        d.catchUp();
        final int mark = d.log.length;
        final DateTime from = r.clock.now;
        await d.run(
          until: (Frame705 f) => f.at.difference(from).inSeconds >= 60,
          row: 'EN-01 play on',
          maxIter: 4000,
        );
        for (final Frame705 f in d.log.skip(mark)) {
          expect(
            f.t == 'kicked',
            isFalse,
            reason: 'EN-01: a computer seat has no socket, so no kicked '
                'frame exists; got ${fdesc(f.f)}',
          );
          expect(
            (f.t == 'rolled' || f.t == 'moved' || f.t == 'turn') && f.seat == 1,
            isFalse,
            reason: 'EN-01: the kicked computer seat acted or was given the '
                'turn after seat_retired: ${fdesc(f.f)}',
          );
        }
        g.c.send('kick', <String, Object?>{'seat': 0});
        expectError(
          await d
              .run(until: (Frame705 f) => f.t == 'error', row: 'EN-01 self')
              .then((Frame705 f) => f.f),
          'ILLEGAL_MOVE',
          'EN-01: the host kicking its own seat',
        );
      },
      ruleset: '2026-11',
      timeout: const Timeout(Duration(minutes: 2)),
    );

    c705Scenario('EN-02 under 2026-10 a PLAYING kick is BAD_TYPE', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 4);
      g.c.send('kick', <String, Object?>{'seat': 1});
      expectError(
        await g.c.untilType('error'),
        'BAD_TYPE',
        'EN-02: section 33 item 8: kick is an unknown type under 2026-10',
      );
    });

    c705Scenario('EN-03 one rematch from the human restarts a computer game', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 2);
      final Map<String, Object?> over = await winNow(r, g);
      final String firstGame = fd(
        g.start.firstWhere(
          (Map<String, Object?> f) => f['t'] == 'game_started',
        ),
      )['game_id']! as String;
      expect(fd(over)['winner'], g.seat);
      final List<Map<String, Object?>> tail = await g.c.sync();
      expect(
        tail.where((Map<String, Object?> f) => f['t'] == 'player_left'),
        isEmpty,
        reason: 'EN-03: item 6: when a game ends computer seats stay '
            'seated; got ${fdescAll(tail)}',
      );
      final String id = g.c.send('rematch', <String, Object?>{});
      final List<Map<String, Object?>> frames = await untilTurnFrame(g.c);
      expect(
        frames.first['t'],
        'room',
        reason: 'EN-03: the human frame comes first; got ${fdescAll(frames)}',
      );
      expect(frames.first['re'], id);
      expect(
        ((fd(frames.first)['rematch']! as Map<String, Object?>)['ready']!
                as List<Object?>)
            .cast<int>(),
        <int>[g.seat],
        reason: 'EN-03: the human is ready first; got ${fdesc(frames.first)}',
      );
      final List<Map<String, Object?>> rooms = <Map<String, Object?>>[
        for (final Map<String, Object?> f in frames)
          if (f['t'] == 'room') f,
      ];
      expect(
        rooms.length,
        greaterThanOrEqualTo(2),
        reason: 'EN-03: the computer seat accepts at once and the room '
            'records it; got ${fdescAll(frames)}',
      );
      final List<int> lastReady = ((fd(rooms.last)['rematch']!
              as Map<String, Object?>)['ready']! as List<Object?>)
          .cast<int>()
        ..sort();
      expect(
        lastReady,
        <int>[0, 2],
        reason: 'EN-03: the last recorded acceptance has every seat ready; '
            'got ${fdesc(rooms.last)}',
      );
      final int gs = ftypes(frames).indexOf('game_started');
      expect(
        gs,
        greaterThan(ftypes(frames).lastIndexOf('room')),
        reason: 'EN-03: the game starts after the last acceptance room; '
            'got ${fdescAll(frames)}',
      );
      expect(
        fd(frames[gs])['game_id'],
        isNot(firstGame),
        reason: 'EN-03: a new game id',
      );
      final Map<String, Object?> snap = await resumeRoom(
        r,
        g.code,
        g.token,
        'en03',
      );
      expect(snap['state'], 'PLAYING');
      expect(snap['rematch'], isNull);
      expectBotSeat(seatOf(snap, 2), 'EN-03');
    });

    c705Scenario(
      'EN-04 the room is reaped at once when the only human leaves',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 4);
        g.c.send('leave_room', <String, Object?>{});
        await g.c.sync();
        expect(
          r.registry.lookup(g.code),
          isNull,
          reason: 'EN-04: item 6: a room with no human seat left is reaped '
              'at once (no reap() call made by the test)',
        );
        final C700Client c = await r.open(r.freshIp(), 'en04-late');
        c.send('resume', <String, Object?>{
          'code': g.code,
          'seat_token': g.token,
        });
        expectError(await c.next(), 'NO_SUCH_ROOM', 'EN-04: resume after reap');
      },
      ruleset: '2026-11',
    );

    c705Scenario('EN-05 reaped at once when the human leaves a finished game', (
      C705Rig r,
    ) async {
      final Game705 g = await playComputer(r, players: 2);
      await winNow(r, g);
      g.c.send('leave_room', <String, Object?>{});
      await g.c.sync();
      expect(
        r.registry.lookup(g.code),
        isNull,
        reason: 'EN-05: item 6: no human seat left after game_over and a '
            'leave_room; the room must be gone without a reap() call',
      );
    });

    c705Scenario(
      'EN-06 the verify record carries bot and the page says computer',
      (C705Rig r) async {
        final Game705 g = await playComputer(r, players: 2);
        final Map<String, Object?> over = await winNow(r, g);
        final String url = fd(over)['verify_url']! as String;
        expect(url, isNotEmpty, reason: 'EN-06: fixture: a stored record');
        final String gameId = Uri.parse(url).pathSegments.last;
        final String? json = r.registry.verifyStore.load(gameId);
        expect(json, isNotNull, reason: 'EN-06: no record stored for $gameId');
        final Map<String, Object?> rec =
            jsonDecode(json!) as Map<String, Object?>;
        final List<Map<String, Object?>> seeds = <Map<String, Object?>>[
          for (final Object? s in rec['seeds']! as List<Object?>)
            s! as Map<String, Object?>,
        ];
        final Map<String, Object?> botRow = seeds.firstWhere(
          (Map<String, Object?> s) => s['seat'] == 2,
        );
        final Map<String, Object?> humanRow = seeds.firstWhere(
          (Map<String, Object?> s) => s['seat'] == 0,
        );
        expect(
          botRow['bot'],
          seatOf(g.room, 2)['bot'],
          reason: 'EN-06: item 6: the computer seat entry carries "bot": int '
              'equal to its character; got ${jsonEncode(seeds)}',
        );
        expect(
          humanRow.containsKey('bot'),
          isFalse,
          reason: 'EN-06: a human entry has no bot; got ${jsonEncode(seeds)}',
        );

        Future<String> page(String id, String lang) async {
          final HttpClient http = HttpClient();
          try {
            final HttpClientRequest req = await http.getUrl(
              Uri(
                scheme: 'http',
                host: '127.0.0.1',
                port: r.server.port,
                path: '/v/$id',
                queryParameters: <String, String>{'lang': lang},
              ),
            );
            final HttpClientResponse res = await req.close();
            return await res.transform(utf8.decoder).join();
          } finally {
            http.close(force: true);
          }
        }

        final Map<String, Object?> plain =
            jsonDecode(json) as Map<String, Object?>;
        for (final Object? s in plain['seeds']! as List<Object?>) {
          (s! as Map<String, Object?>).remove('bot');
        }
        const String plainId = '00112233445566ff';
        expect(r.registry.verifyStore.save(plainId, jsonEncode(plain)), isTrue);
        int count(String body, String needle) =>
            needle.allMatches(body.toLowerCase()).length;
        final String enBot = await page(gameId, 'en');
        final String enPlain = await page(plainId, 'en');
        expect(
          count(enBot, 'computer'),
          greaterThan(count(enPlain, 'computer')),
          reason: 'EN-06: item 6: the page shows "computer" beside the '
              'computer seat; with the bot key it has '
              '${count(enBot, 'computer')} occurrences and without it '
              '${count(enPlain, 'computer')}',
        );
        final String arBot = await page(gameId, 'ar');
        final String arPlain = await page(plainId, 'ar');
        expect(
          arBot.allMatches('كومبيوتر').length,
          greaterThan(arPlain.allMatches('كومبيوتر').length),
          reason: 'EN-06: item 6: the Arabic page shows «كومبيوتر» beside '
              'the computer seat',
        );
      },
    );
  });
}

extension on Held {
  /// The next `error` frame on the seat's socket.
  Future<Map<String, Object?>> untilError() => c.untilType('error');
}
