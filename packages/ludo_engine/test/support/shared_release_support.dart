// Shared helpers for the sharedRelease suites: docs/RULES.md section 3.2c
// (rules 16s to 20s) and docs/ENGINE_API.md section 13.
//
// Everything here talks to the engine only through
// package:ludo_engine/ludo_engine.dart and builds states only through
// GameState.fromJson, in the key order sections 8, 10.2, 11.2, 12.2 and 13.2
// fix. Nothing here reads lib/.

import 'dart:convert';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Rendering, so event sequences compare as plain strings.
// ---------------------------------------------------------------------------

String renderEvent(GameEvent e) => switch (e) {
      Rolled() => 'Rolled(${e.seat},${e.value},${e.legal})',
      Moved() => 'Moved(${e.seat},${e.token},${e.from}->${e.to})',
      Captured() => 'Captured(${e.seat},${e.token} by ${e.by},${e.byToken})',
      TokenHome() => 'TokenHome(${e.seat},${e.token})',
      ExtraRoll() => 'ExtraRoll(${e.seat})',
      TurnEnded() => 'TurnEnded(${e.seat},${e.reason.name})',
      TurnBegan() => 'TurnBegan(${e.seat})',
      GameWon() => 'GameWon(${e.seat})',
      YardReleased() => 'YardReleased(${e.seat})',
      SeatFinished() => 'SeatFinished(${e.seat},${e.place})',
      SeatRetired() => 'SeatRetired(${e.seat})',
      ReleaseDeclined() => 'ReleaseDeclined(${e.seat})',
      SixesBanked() => 'SixesBanked(${e.seats})',
      SixesQueued() => 'SixesQueued(${e.seat},${e.count})',
    };

List<String> renderEvents(List<GameEvent> events) =>
    events.map(renderEvent).toList(growable: false);

String renderIntention(Intention i) => switch (i) {
      RollIntention() => 'roll(seat ${i.seat}, face ${i.face})',
      MoveIntention() =>
        'move(seat ${i.seat}, token ${i.token}, face ${i.face})',
      RetireIntention() => 'retire(seat ${i.seat})',
      DeclineIntention() => 'decline(seat ${i.seat})',
    };

String rolled(int seat, int value, List<int> legal) =>
    'Rolled($seat,$value,$legal)';

// ---------------------------------------------------------------------------
// Configuration and hand-written states.
// ---------------------------------------------------------------------------

const List<int> twoSeats = <int>[0, 2];
const List<int> threeSeats = <int>[0, 1, 2];
const List<int> fourSeats = <int>[0, 1, 2, 3];
const List<int> yardRow = <int>[-1, -1, -1, -1];
const List<int> zeros = <int>[0, 0, 0, 0];

GameConfig sharedConfig({
  List<int> seats = twoSeats,
  bool blocks = true,
  bool homeBonus = false,
  bool playOut = false,
  int seed = 1,
}) {
  return GameConfig(
    seats: seats,
    rules: RulesConfig(
      blocks: blocks,
      captureBonus: true,
      rollQueue: true,
      homeBonus: homeBonus,
      yardRelease: true,
      sharedRelease: true,
      playOut: playOut,
    ),
    seed: seed,
  );
}

/// A hand-written state as the JSON map, keys in the documented order.
Map<String, Object?> handJson({
  List<int> seats = twoSeats,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  List<int> queue = const <int>[],
  int sixes = 0,
  List<int> drought = zeros,
  bool releaseOwed = false,
  List<int> banked = zeros,
  bool releaseOffered = false,
  bool blocks = true,
  bool homeBonus = false,
  bool playOut = false,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  int? winner,
  int seq = 0,
  int seed = 1,
  int rngState = 1,
}) {
  return <String, Object?>{
    'config': <String, Object?>{
      'seats': seats,
      'rules': <String, Object?>{
        'blocks': blocks,
        'captureBonus': true,
        'rollQueue': true,
        if (homeBonus) 'homeBonus': true,
        'yardRelease': true,
        'sharedRelease': true,
        if (playOut) 'playOut': true,
      },
      'seed': seed,
    },
    'tokens': List<List<int>>.generate(
      4,
      (seat) => List<int>.of(tokens[seat] ?? yardRow),
    ),
    'currentSeat': currentSeat,
    'phase': phase,
    'roll': null,
    'queue': queue,
    'sixes': sixes,
    'drought': drought,
    'releaseOwed': releaseOwed,
    'banked': banked,
    'releaseOffered': releaseOffered,
    'winner': winner,
    if (playOut) 'placings': placings,
    if (playOut) 'retired': retired,
    'seq': seq,
    'rngState': rngState,
  };
}

GameState hand({
  List<int> seats = twoSeats,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  List<int> queue = const <int>[],
  int sixes = 0,
  List<int> drought = zeros,
  bool releaseOwed = false,
  List<int> banked = zeros,
  bool releaseOffered = false,
  bool blocks = true,
  bool homeBonus = false,
  bool playOut = false,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
}) {
  return GameState.fromJson(
    handJson(
      seats: seats,
      tokens: tokens,
      currentSeat: currentSeat,
      phase: phase,
      queue: queue,
      sixes: sixes,
      drought: drought,
      releaseOwed: releaseOwed,
      banked: banked,
      releaseOffered: releaseOffered,
      blocks: blocks,
      homeBonus: homeBonus,
      playOut: playOut,
      placings: placings,
      retired: retired,
    ),
  );
}

/// A state with the release on offer to [seat]: every token of [seat] in the
/// yard, the drawn face [face] queued, drought 9.
GameState offeredHand({
  List<int> seats = twoSeats,
  int seat = 0,
  int face = 3,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  List<int> banked = zeros,
  List<int>? drought,
  bool blocks = true,
}) {
  final d = List<int>.of(drought ?? zeros)..[seat] = 9;
  return hand(
    seats: seats,
    tokens: tokens,
    currentSeat: seat,
    phase: 'awaitMove',
    queue: <int>[face],
    drought: d,
    releaseOwed: true,
    banked: banked,
    releaseOffered: true,
    blocks: blocks,
  );
}

Map<String, Object?> copyJson(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

Map<String, Object?> rulesOf(Map<String, Object?> json) =>
    (json['config']! as Map<String, Object?>)['rules']! as Map<String, Object?>;

// ---------------------------------------------------------------------------
// A run: applies intentions, remembers them, and says how to reproduce.
// ---------------------------------------------------------------------------

class Run {
  Run(this.name, this.state);

  final String name;
  GameState state;
  final List<String> log = <String>[];

  String get trace => 'scenario "$name" (seed ${state.config.seed}), '
      'intentions so far: ${log.isEmpty ? '(none)' : log.join('; ')}';

  List<String> play(Intention intention) {
    final result = apply(state, intention);
    log.add(renderIntention(intention));
    switch (result) {
      case Applied(state: final next, events: final events):
        state = next;
        return renderEvents(events);
      case Rejected(error: final error):
        fail('expected ${renderIntention(intention)} to be accepted, got '
            'Rejected(${error.name}). $trace');
    }
  }

  List<String> roll(int seat, int face) => play(RollIntention(seat, face));

  List<String> move(int seat, int token, {int? face}) =>
      play(MoveIntention(seat, token, face: face));

  List<String> decline(int seat) => play(DeclineIntention(seat));

  /// The error [intention] is refused with, or null when it is accepted. The
  /// run's state is untouched either way.
  EngineError? refused(Intention intention) {
    final result = apply(state, intention);
    return result is Rejected ? result.error : null;
  }
}

/// Face of the i-th non-6 roll of a scenario, 1..5.
int face5(int i) => (i % 5) + 1;

List<String> passEvents(int seat, int face, int next) => <String>[
      rolled(seat, face, const <int>[]),
      'TurnEnded($seat,noLegalMove)',
      'TurnBegan($next)',
    ];

/// Every seat of [seats] is stuck in the yard from the start of play;
/// [rounds] full rounds of non-6 faces are rolled in seat order. After nine
/// rounds every seat has drought 9 and the first seat is about to roll its
/// tenth non-6.
void stuckRounds(Run run, List<int> seats, int rounds) {
  for (var r = 1; r <= rounds; r++) {
    for (var k = 0; k < seats.length; k++) {
      final seat = seats[k];
      final next = seats[(k + 1) % seats.length];
      final f = face5(r + 2 * k);
      final events = run.roll(seat, f);
      expect(events, equals(passEvents(seat, f, next)),
          reason: 'round $r, seat $seat rolled $f with every token in the '
              'yard: expected a plain pass; got $events. ${run.trace}');
    }
  }
}

/// Table of the seats other than [seat], ascending.
List<int> others(List<int> seats, int seat) =>
    seats.where((s) => s != seat).toList(growable: false);

/// The next seat after [seat] in [seats], cyclically.
int nextOf(List<int> seats, int seat) =>
    seats[(seats.indexOf(seat) + 1) % seats.length];
