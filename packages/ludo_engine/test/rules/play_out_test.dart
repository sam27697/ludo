// docs/RULES.md section 5.1 (rules 33p-39p) and docs/ENGINE_API.md section
// 12: the places are played out, and the server may retire a seat.
//
// Written from the two documents only, against the names the contract gives:
// RulesConfig.playOut, GameState.placings, GameState.retired, RetireIntention,
// SeatFinished, SeatRetired, plus the section 11 names (yardRelease,
// drought, releaseOwed, YardReleased) where a case combines both toggles.
//
// How the positions are reached, per group:
//   * P1-P4, P5-P7, P8, P10: hand-written states through GameState.fromJson,
//     because every field of the state is defined by the documents. Seats
//     that finished carry four tokens at 57, retired seats four tokens in
//     the yard, exactly as the contract leaves them. The first move of a
//     chain is applied from such a state; later steps are real apply calls.
//   * P9: newGame, applied states, and literal JSON text.
//   * S1, S2: states built from a seed, then random play and random
//     retirements with every documented invariant checked after each step.
//     A failure names the seed; the same seed rebuilds the same game.
//
// Every failure message carries a scenario label and the full state JSON
// before the intention that failed, or the soak seed, so it can be rebuilt
// by hand through GameState.fromJson.
//
// Event lists are compared as strings such as 'Moved(0,3,52,57)' so a
// mismatch prints the expected list and the actual list side by side.

import 'dart:convert';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/splitmix64.dart';

// ---------------------------------------------------------------------------
// Fixture building

const List<int> _yardRow = <int>[-1, -1, -1, -1];
const List<int> _homeRow = <int>[57, 57, 57, 57];

/// The documented JSON of a state, keys in the order of ENGINE_API sections
/// 8, 10.2, 11.2 and 12.2. Optional keys are written only when their toggle
/// is on, as the documents say, so a state whose toggle is off is the
/// pre-toggle byte shape.
Map<String, Object?> _stateJson({
  required List<int> seats,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  int? roll,
  bool rollQueue = true,
  List<int> queue = const <int>[],
  int sixes = 0,
  bool blocks = true,
  bool captureBonus = true,
  bool homeBonus = false,
  bool yardRelease = false,
  List<int> drought = const <int>[0, 0, 0, 0],
  bool releaseOwed = false,
  bool playOut = true,
  int? winner,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  int seq = 0,
  int seed = 1,
  int rngState = 1,
}) {
  final rules = <String, Object?>{
    'blocks': blocks,
    'captureBonus': captureBonus,
    if (rollQueue) 'rollQueue': true,
    if (homeBonus) 'homeBonus': true,
    if (yardRelease) 'yardRelease': true,
    if (playOut) 'playOut': true,
  };
  return <String, Object?>{
    'config': <String, Object?>{
      'seats': List<int>.of(seats),
      'rules': rules,
      'seed': seed,
    },
    'tokens': List<List<int>>.generate(
      4,
      (s) => List<int>.of(tokens[s] ?? _yardRow),
    ),
    'currentSeat': currentSeat,
    'phase': phase,
    'roll': roll,
    if (rollQueue) 'queue': List<int>.of(queue),
    'sixes': sixes,
    if (yardRelease) 'drought': List<int>.of(drought),
    if (yardRelease) 'releaseOwed': releaseOwed,
    'winner': winner,
    if (playOut) 'placings': List<int>.of(placings),
    if (playOut) 'retired': List<int>.of(retired),
    'seq': seq,
    'rngState': rngState,
  };
}

GameState _state({
  required List<int> seats,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  int? roll,
  bool rollQueue = true,
  List<int> queue = const <int>[],
  int sixes = 0,
  bool blocks = true,
  bool captureBonus = true,
  bool homeBonus = false,
  bool yardRelease = false,
  List<int> drought = const <int>[0, 0, 0, 0],
  bool releaseOwed = false,
  bool playOut = true,
  int? winner,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  int seq = 0,
}) {
  return GameState.fromJson(
    _stateJson(
      seats: seats,
      tokens: tokens,
      currentSeat: currentSeat,
      phase: phase,
      roll: roll,
      rollQueue: rollQueue,
      queue: queue,
      sixes: sixes,
      blocks: blocks,
      captureBonus: captureBonus,
      homeBonus: homeBonus,
      yardRelease: yardRelease,
      drought: drought,
      releaseOwed: releaseOwed,
      playOut: playOut,
      winner: winner,
      placings: placings,
      retired: retired,
      seq: seq,
    ),
  );
}

/// An awaitMove state holding [face] (and [more] faces behind it) for
/// [currentSeat]. With [rq] false the face is `state.roll`; with [rq] true it
/// is the queue and `roll` is null, as section 10.1 says.
GameState _awaitMove({
  required bool rq,
  required List<int> seats,
  required Map<int, List<int>> tokens,
  required int face,
  List<int> more = const <int>[],
  int currentSeat = 0,
  int sixes = 0,
  bool homeBonus = false,
  bool blocks = true,
  bool captureBonus = true,
  bool playOut = true,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
}) {
  return _state(
    seats: seats,
    tokens: tokens,
    currentSeat: currentSeat,
    phase: 'awaitMove',
    rollQueue: rq,
    roll: rq ? null : face,
    queue: rq ? <int>[face, ...more] : const <int>[],
    sixes: sixes,
    homeBonus: homeBonus,
    blocks: blocks,
    captureBonus: captureBonus,
    playOut: playOut,
    placings: placings,
    retired: retired,
  );
}

// ---------------------------------------------------------------------------
// Reading results

String _sig(GameEvent e) {
  if (e is Rolled) return 'Rolled(${e.seat},${e.value})';
  if (e is Moved) return 'Moved(${e.seat},${e.token},${e.from},${e.to})';
  if (e is Captured) {
    return 'Captured(${e.seat},${e.token},${e.by},${e.byToken})';
  }
  if (e is TokenHome) return 'TokenHome(${e.seat},${e.token})';
  if (e is ExtraRoll) return 'ExtraRoll(${e.seat})';
  if (e is TurnEnded) return 'TurnEnded(${e.seat},${e.reason.name})';
  if (e is TurnBegan) return 'TurnBegan(${e.seat})';
  if (e is GameWon) return 'GameWon(${e.seat})';
  if (e is SeatFinished) return 'SeatFinished(${e.seat},${e.place})';
  if (e is SeatRetired) return 'SeatRetired(${e.seat})';
  if (e is YardReleased) return 'YardReleased(${e.seat})';
  return e.toString();
}

String _iSig(Intention i) {
  if (i is RollIntention) return 'Roll(${i.seat},${i.face})';
  if (i is MoveIntention) return 'Move(${i.seat},${i.token},face: ${i.face})';
  if (i is RetireIntention) return 'Retire(${i.seat})';
  return i.toString();
}

String _dump(GameState s) => jsonEncode(s.toJson());

Applied _apply(String sc, GameState s, Intention i) {
  final r = apply(s, i);
  if (r is Applied) return r;
  fail(
    '[$sc] expected ${_iSig(i)} to be Applied but it was '
    'Rejected(${(r as Rejected).error.name}); state before: ${_dump(s)}',
  );
}

void _expectEvents(String sc, Applied a, List<String> want) {
  expect(
    a.events.map(_sig).toList(),
    equals(want),
    reason: '[$sc] expected events $want; state after: ${_dump(a.state)}',
  );
}

void _expectRejected(String sc, GameState s, Intention i, EngineError want) {
  final beforeJson = _dump(s);
  final beforeHash = stateHash(s);
  final r = apply(s, i);
  if (r is! Rejected) {
    fail(
      '[$sc] expected ${_iSig(i)} to be Rejected(${want.name}) but it '
      'was Applied with events ${(r as Applied).events.map(_sig).toList()}; '
      'state before: $beforeJson',
    );
  }
  expect(
    r.error,
    want,
    reason: '[$sc] expected Rejected(${want.name}) for ${_iSig(i)}, got '
        'Rejected(${r.error.name}); state: $beforeJson',
  );
  expect(
    _dump(s),
    beforeJson,
    reason: '[$sc] a rejection must leave the state untouched',
  );
  expect(stateHash(s), beforeHash, reason: '[$sc] hash moved on a rejection');
}

void _expectState(
  String sc,
  GameState s, {
  required int currentSeat,
  required GamePhase phase,
  required int? winner,
  List<int>? queue,
  int? sixes,
  List<int>? placings,
  List<int>? retired,
  int? seq,
  bool? releaseOwed,
  bool rollNull = false,
}) {
  final why = '[$sc] state: ${_dump(s)}';
  expect(s.currentSeat, currentSeat, reason: '$why (currentSeat)');
  expect(s.phase, phase, reason: '$why (phase)');
  expect(s.winner, winner, reason: '$why (winner)');
  if (queue != null) expect(s.queue, queue, reason: '$why (queue)');
  if (sixes != null) expect(s.sixes, sixes, reason: '$why (sixes)');
  if (placings != null) {
    expect(s.placings, placings, reason: '$why (placings)');
  }
  if (retired != null) expect(s.retired, retired, reason: '$why (retired)');
  if (seq != null) expect(s.seq, seq, reason: '$why (seq)');
  if (releaseOwed != null) {
    expect(s.releaseOwed, releaseOwed, reason: '$why (releaseOwed)');
  }
  if (rollNull) expect(s.roll, isNull, reason: '$why (roll)');
  expect(
    isTerminal(s),
    phase == GamePhase.finished,
    reason: '$why (isTerminal)',
  );
}

// ---------------------------------------------------------------------------
// A deterministic chooser for the driven games

class _Gen {
  _Gen(this._s);
  int _s;
  int below(int n) {
    final (ns, z) = splitMix64Next(_s);
    _s = ns;
    return (z >>> 33) % n;
  }
}

/// The next ordinary intention of the seat to act: roll when a roll is owed,
/// otherwise spend a release, or a random queued face on a random legal
/// token. Uses only the public queries.
Intention _nextIntention(GameState s, _Gen g) {
  final seat = s.currentSeat;
  if (s.phase == GamePhase.awaitRoll) {
    return RollIntention(seat, 1 + g.below(6));
  }
  if (s.config.rules.yardRelease && s.releaseOwed) {
    final t = legalTokens(s);
    return MoveIntention(seat, t[g.below(t.length)]);
  }
  if (s.config.rules.rollQueue) {
    final by = legalByFace(s);
    final faces = by.keys.toList();
    final f = faces[g.below(faces.length)];
    final toks = by[f]!;
    return MoveIntention(seat, toks[g.below(toks.length)], face: f);
  }
  final t = legalTokens(s);
  return MoveIntention(seat, t[g.below(t.length)]);
}

bool _playing(GameState s, int seat) =>
    s.config.seats.contains(seat) &&
    !s.placings.contains(seat) &&
    !s.retired.contains(seat);

/// The next playing seat after [from] in `config.seats`, cyclically
/// (ENGINE_API 12.1), judged against [s].
int _nextPlaying(GameState s, int from) {
  final seats = s.config.seats;
  final at = seats.indexOf(from);
  for (var k = 1; k <= seats.length; k++) {
    final c = seats[(at + k) % seats.length];
    if (_playing(s, c)) return c;
  }
  return -1;
}

String _fnvHex(String text) {
  var h = 0xCBF29CE484222325;
  for (final b in utf8.encode(text)) {
    h ^= b;
    h *= 0x00000100000001B3;
  }
  final hi = ((h >>> 32) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  final lo = (h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '$hi$lo';
}

Map<String, Object?> _deep(Map<String, Object?> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, Object?>;

Map<String, Object?> _rulesOf(Map<String, Object?> json) =>
    (json['config'] as Map<String, Object?>)['rules'] as Map<String, Object?>;

// ---------------------------------------------------------------------------
// The soak

class _Tally {
  int finishedEvents = 0;
  int retiredEvents = 0;
  int games = 0;
  int retireEnded = 0;
  int retireActing = 0;
}

void _checkStep(
  String where,
  GameState before,
  Intention i,
  Applied a,
  _Tally tally,
) {
  final after = a.state;
  final ev = a.events;
  final sigs = ev.map(_sig).toList();
  final why = '$where events=$sigs after=${_dump(after)}';
  final seats = after.config.seats;

  expect(after.seq, before.seq + 1, reason: '$why (seq)');

  // The two lists.
  for (final p in after.placings) {
    expect(seats.contains(p), isTrue, reason: '$why (placings seat in config)');
  }
  for (final r in after.retired) {
    expect(seats.contains(r), isTrue, reason: '$why (retired seat in config)');
  }
  expect(
    after.placings.toSet().length,
    after.placings.length,
    reason: '$why (placings unique)',
  );
  expect(
    after.retired.toSet().length,
    after.retired.length,
    reason: '$why (retired unique)',
  );
  expect(
    after.placings.toSet().intersection(after.retired.toSet()),
    isEmpty,
    reason: '$why (a seat in both lists)',
  );
  expect(
    after.placings.sublist(0, before.placings.length),
    before.placings,
    reason: '$why (placings only grow at the end)',
  );
  expect(
    after.retired.sublist(0, before.retired.length),
    before.retired,
    reason: '$why (retired only grows at the end)',
  );

  // SeatFinished events are exactly the new placings, numbered from 1.
  final fin = ev.whereType<SeatFinished>().toList();
  expect(
    after.placings.sublist(before.placings.length),
    fin.map((e) => e.seat).toList(),
    reason: '$why (SeatFinished events vs new placings)',
  );
  for (var k = 0; k < fin.length; k++) {
    expect(
      fin[k].place,
      before.placings.length + k + 1,
      reason: '$why (place number of SeatFinished #$k)',
    );
  }
  tally.finishedEvents += fin.length;

  final rets = ev.whereType<SeatRetired>().toList();
  expect(
    after.retired.sublist(before.retired.length),
    rets.map((e) => e.seat).toList(),
    reason: '$why (SeatRetired events vs new retired)',
  );
  tally.retiredEvents += rets.length;

  // A retired seat's tokens: home stays home, everything else is the yard.
  for (final r in after.retired) {
    for (var t = 0; t < 4; t++) {
      final was = before.retired.contains(r) ? before.tokens[r][t] : null;
      final v = after.tokens[r][t];
      expect(
        v == -1 || v == 57,
        isTrue,
        reason: '$why (retired seat $r token $t is $v)',
      );
      if (was != null) expect(v, was, reason: '$why (retired token moved)');
    }
  }

  // A finishing move gives no bonus.
  if (i is MoveIntention && fin.isNotEmpty) {
    expect(
      ev.whereType<ExtraRoll>(),
      isEmpty,
      reason: '$why (bonus on a move that finished a seat)',
    );
    expect(after.queue, isEmpty, reason: '$why (queue after a finish)');
    expect(after.sixes, 0, reason: '$why (sixes after a finish)');
  }

  if (after.phase == GamePhase.finished) {
    tally.games++;
    expect(isTerminal(after), isTrue, reason: '$why (isTerminal)');
    expect(
      after.placings.length + after.retired.length,
      seats.length,
      reason: '$why (every seat is placed or retired at the end)',
    );
    expect(
      after.winner,
      after.placings.isEmpty ? null : after.placings.first,
      reason: '$why (winner is the first place)',
    );
    final won = ev.whereType<GameWon>().toList();
    expect(
      won.length,
      after.winner == null ? 0 : 1,
      reason: '$why (GameWon count)',
    );
    if (won.isNotEmpty) {
      expect(
        sigs.last,
        'GameWon(${after.winner})',
        reason: '$why (GameWon must be last)',
      );
    }
    expect(after.queue, isEmpty, reason: '$why (queue at the end)');
    expect(
      ev.whereType<TurnBegan>(),
      isEmpty,
      reason: '$why (TurnBegan on the move that ends the game)',
    );
  } else {
    expect(after.winner, isNull, reason: '$why (winner before the end)');
    expect(ev.whereType<GameWon>(), isEmpty, reason: '$why (early GameWon)');
    final playing = seats.where((s) => _playing(after, s)).toList();
    expect(
      playing.length >= 2,
      isTrue,
      reason: '$why (a running game has two playing seats)',
    );
    expect(
      _playing(after, after.currentSeat),
      isTrue,
      reason: '$why (currentSeat is not playing)',
    );
    for (final b in ev.whereType<TurnBegan>()) {
      expect(b.seat, after.currentSeat, reason: '$why (TurnBegan seat)');
      expect(
        b.seat,
        _nextPlaying(after, before.currentSeat),
        reason: '$why (TurnBegan is not the next playing seat)',
      );
    }
  }

  if (i is RetireIntention) {
    final r = i.seat;
    for (var t = 0; t < 4; t++) {
      final b = before.tokens[r][t];
      expect(
        after.tokens[r][t],
        b == 57 ? 57 : -1,
        reason: '$why (retired token $t)',
      );
    }
    for (final s in seats) {
      if (s != r) {
        expect(
          after.tokens[s],
          before.tokens[s],
          reason: '$why (retire touched seat $s)',
        );
      }
    }
    expect(sigs.first, 'SeatRetired($r)', reason: '$why (first event)');
    if (after.phase != GamePhase.finished) {
      if (r == before.currentSeat) {
        tally.retireActing++;
        expect(
            sigs,
            [
              'SeatRetired($r)',
              'TurnBegan(${after.currentSeat})',
            ],
            reason: '$why (acting seat retired)');
        expect(after.phase, GamePhase.awaitRoll, reason: '$why (phase)');
        expect(after.queue, isEmpty, reason: '$why (queue)');
        expect(after.sixes, 0, reason: '$why (sixes)');
        expect(after.roll, isNull, reason: '$why (roll)');
        expect(after.releaseOwed, isFalse, reason: '$why (releaseOwed)');
      } else {
        expect(sigs, ['SeatRetired($r)'], reason: '$why (other seat retired)');
        expect(after.currentSeat, before.currentSeat, reason: '$why (seat)');
        expect(after.phase, before.phase, reason: '$why (phase)');
        expect(after.queue, before.queue, reason: '$why (queue)');
        expect(after.roll, before.roll, reason: '$why (roll)');
        expect(after.sixes, before.sixes, reason: '$why (sixes)');
        expect(
          after.releaseOwed,
          before.releaseOwed,
          reason: '$why (releaseOwed)',
        );
      }
    } else {
      tally.retireEnded++;
    }
  } else {
    expect(
      after.retired,
      before.retired,
      reason: '$why (a move or roll changed retired)',
    );
  }

  // Serialisation survives every step.
  final back = GameState.fromJson(
    jsonDecode(jsonEncode(after.toJson())) as Map<String, Object?>,
  );
  expect(back, after, reason: '$why (round trip)');
  expect(_dump(back), _dump(after), reason: '$why (round trip bytes)');
}

void _soak(int seed, {required bool yard, required _Tally tally}) {
  final g = _Gen(seed * 7919 + 13);
  final seatCount = 2 + g.below(3);
  final seats = seatCount == 2
      ? <int>[0, 2]
      : seatCount == 3
          ? <int>[0, 1, 2]
          : <int>[0, 1, 2, 3];
  final rq = yard ? true : g.below(2) == 0;
  final hb = g.below(2) == 0;
  final blocks = g.below(2) == 0;
  final cb = g.below(4) != 0;
  final tokens = <int, List<int>>{};
  for (final s in seats) {
    final allYard = yard && g.below(2) == 0;
    final row = List<int>.generate(
      4,
      (_) => allYard ? -1 : (g.below(10) < 7 ? 30 + g.below(28) : -1),
    );
    if (row.every((p) => p == 57)) row[0] = 52;
    tokens[s] = row;
  }
  final start = _state(
    seats: seats,
    tokens: tokens,
    currentSeat: seats.first,
    rollQueue: rq,
    homeBonus: hb,
    blocks: blocks,
    captureBonus: cb,
    yardRelease: yard,
  );
  final ctx = 'soak seed=$seed yard=$yard seats=$seats rollQueue=$rq '
      'homeBonus=$hb blocks=$blocks captureBonus=$cb '
      'start=${_dump(start)}';

  var s = start;
  final played = <Intention>[];
  for (var step = 0; step < 4000 && !isTerminal(s); step++) {
    final Intention i =
        g.below(40) == 0 ? RetireIntention(g.below(4)) : _nextIntention(s, g);
    final where = '$ctx step=$step intention=${_iSig(i)} '
        'before=${_dump(s)}';
    if (i is RetireIntention) {
      final EngineError? want = !seats.contains(i.seat)
          ? EngineError.seatNotInPlay
          : !_playing(s, i.seat)
              ? EngineError.illegalMove
              : null;
      final r = apply(s, i);
      if (want != null) {
        expect(r, isA<Rejected>(), reason: '$where (expected ${want.name})');
        expect((r as Rejected).error, want, reason: where);
        continue;
      }
      expect(r, isA<Applied>(), reason: '$where (expected Applied)');
    }
    final r = apply(s, i);
    expect(r, isA<Applied>(), reason: '$where (ordinary intention refused)');
    final a = r as Applied;
    played.add(i);
    _checkStep(where, s, i, a, tally);
    s = a.state;
  }

  // Same intentions, same bytes.
  var replay = start;
  for (final i in played) {
    replay = (apply(replay, i) as Applied).state;
  }
  expect(
    stateHash(replay),
    stateHash(s),
    reason: '$ctx (replaying ${played.length} intentions)',
  );
  expect(_dump(replay), _dump(s), reason: '$ctx (replay bytes)');
}

// ---------------------------------------------------------------------------

void main() {
  group('P1: a seat that finishes leaves the turn order (rule 33p, 35p)', () {
    for (final rq in const <bool>[true, false]) {
      test(
        'P1.1 [rollQueue=$rq] four seats: seat 0 finishes and takes place 1',
        () {
          final sc = 'P1.1 rollQueue=$rq';
          final s = _awaitMove(
            rq: rq,
            seats: fourPlayerSeats,
            tokens: const {
              0: <int>[57, 57, 57, 52],
              1: <int>[10, -1, -1, -1],
              2: <int>[20, -1, -1, -1],
              3: <int>[30, -1, -1, -1],
            },
            face: 5,
          );
          final a = _apply(sc, s, const MoveIntention(0, 3));
          _expectEvents(sc, a, <String>[
            'Moved(0,3,52,57)',
            'TokenHome(0,3)',
            'SeatFinished(0,1)',
            'TurnBegan(1)',
          ]);
          _expectState(
            sc,
            a.state,
            currentSeat: 1,
            phase: GamePhase.awaitRoll,
            winner: null,
            queue: const <int>[],
            sixes: 0,
            placings: const <int>[0],
            retired: const <int>[],
            seq: 1,
            rollNull: true,
          );
          expect(
              a.state.tokens[0],
              const <int>[
                57,
                57,
                57,
                57,
              ],
              reason: '[$sc] the finished seat keeps its tokens at home');
        },
      );

      test(
        'P1.2 [rollQueue=$rq] seat 0 is never on turn again over many rounds '
        '(seeds 1..8)',
        () {
          for (var seed = 1; seed <= 8; seed++) {
            final sc = 'P1.2 rollQueue=$rq seed=$seed';
            final g = _Gen(seed * 104729);
            var s = _awaitMove(
              rq: rq,
              seats: fourPlayerSeats,
              tokens: const {
                0: <int>[57, 57, 57, 52],
                1: <int>[10, -1, -1, -1],
                2: <int>[20, -1, -1, -1],
                3: <int>[30, -1, -1, -1],
              },
              face: 5,
            );
            s = _apply(sc, s, const MoveIntention(0, 3)).state;
            var turns = 0;
            final seen = <int>{};
            for (var step = 0; step < 600 && !isTerminal(s); step++) {
              final i = _nextIntention(s, g);
              final a = _apply('$sc step=$step', s, i);
              expect(
                i.seat,
                isNot(0),
                reason: '[$sc step=$step] seat 0 was asked to act; '
                    'state: ${_dump(s)}',
              );
              for (final e in a.events) {
                final sig = _sig(e);
                expect(
                  sig.startsWith('Rolled(0,') ||
                      sig.startsWith('Moved(0,') ||
                      sig == 'TurnBegan(0)' ||
                      sig == 'ExtraRoll(0)',
                  isFalse,
                  reason: '[$sc step=$step] seat 0 appears in event $sig',
                );
                if (e is TurnBegan) {
                  turns++;
                  seen.add(e.seat);
                }
              }
              if (!isTerminal(a.state)) {
                expect(
                  a.state.currentSeat,
                  isNot(0),
                  reason: '[$sc step=$step] currentSeat returned to the '
                      'finished seat; state: ${_dump(a.state)}',
                );
                expect(
                  a.state.placings.first,
                  0,
                  reason: '[$sc step=$step] place 1 moved',
                );
              }
              s = a.state;
            }
            expect(
              turns >= 12,
              isTrue,
              reason: '[$sc] only $turns turns began; the scenario is too '
                  'short to prove anything',
            );
            expect(
              seen,
              containsAll(<int>[1, 2, 3]),
              reason: '[$sc] not every playing seat got a turn: $seen',
            );
          }
        },
      );
    }

    test(
        'P1.3 a finished seat is skipped when the turn passes, wrapping '
        'included', () {
      // Seat 3 passes with seat 0 finished: wraps to 1.
      final wrap = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: _homeRow,
          1: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        },
        currentSeat: 3,
        placings: const <int>[0],
      );
      final w = _apply('P1.3 wrap', wrap, const RollIntention(3, 2));
      _expectEvents('P1.3 wrap', w, <String>[
        'Rolled(3,2)',
        'TurnEnded(3,noLegalMove)',
        'TurnBegan(1)',
      ]);
      // Seat 0 passes with seat 1 finished: 2, not 1.
      final mid = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[-1, -1, -1, -1],
          1: _homeRow,
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        currentSeat: 0,
        placings: const <int>[1],
      );
      final m = _apply('P1.3 mid', mid, const RollIntention(0, 2));
      _expectEvents('P1.3 mid', m, <String>[
        'Rolled(0,2)',
        'TurnEnded(0,noLegalMove)',
        'TurnBegan(2)',
      ]);
      // A move that ends the turn skips the finished seat too.
      final mv = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[5, -1, -1, -1],
          1: _homeRow,
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 2,
        placings: const <int>[1],
      );
      final x = _apply('P1.3 move', mv, const MoveIntention(0, 0));
      _expectEvents('P1.3 move', x, <String>['Moved(0,0,5,7)', 'TurnBegan(2)']);
    });

    test(
        'P1.4 a finished seat cannot act: any roll or move by it is '
        'notYourTurn', () {
      final s = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: _homeRow,
          1: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        currentSeat: 1,
        placings: const <int>[0],
      );
      _expectRejected(
        'P1.4 roll',
        s,
        const RollIntention(0, 3),
        EngineError.notYourTurn,
      );
      _expectRejected(
        'P1.4 move',
        s,
        const MoveIntention(0, 0),
        EngineError.notYourTurn,
      );
    });
  });

  group('P2: places 2, 3 and the last seat (rule 33p, 36p, 37p, 38p)', () {
    for (final rq in const <bool>[true, false]) {
      test(
          'P2.1 [rollQueue=$rq] seats 0, 1, 2 finish in turn, seat 3 takes '
          'place 4 in the same apply, winner is seat 0', () {
        const sc0 = 'P2.1';
        final sc = '$sc0 rollQueue=$rq';
        const ready = <int>[57, 57, 57, 52];
        var s = _awaitMove(
          rq: rq,
          seats: fourPlayerSeats,
          tokens: const {
            0: ready,
            1: ready,
            2: ready,
            3: <int>[10, -1, -1, -1],
          },
          face: 5,
        );
        var a = _apply('$sc seat 0', s, const MoveIntention(0, 3));
        _expectEvents('$sc seat 0', a, <String>[
          'Moved(0,3,52,57)',
          'TokenHome(0,3)',
          'SeatFinished(0,1)',
          'TurnBegan(1)',
        ]);
        s = a.state;

        a = _apply('$sc seat 1 roll', s, const RollIntention(1, 5));
        _expectEvents('$sc seat 1 roll', a, <String>['Rolled(1,5)']);
        s = a.state;
        a = _apply('$sc seat 1 move', s, const MoveIntention(1, 3));
        _expectEvents('$sc seat 1 move', a, <String>[
          'Moved(1,3,52,57)',
          'TokenHome(1,3)',
          'SeatFinished(1,2)',
          'TurnBegan(2)',
        ]);
        expect(
            a.state.placings,
            const <int>[
              0,
              1,
            ],
            reason: '[$sc] placings after the second finish');
        expect(a.state.winner, isNull, reason: '[$sc] early winner');
        expect(isTerminal(a.state), isFalse, reason: '[$sc] early end');
        s = a.state;

        a = _apply('$sc seat 2 roll', s, const RollIntention(2, 5));
        s = a.state;
        a = _apply('$sc seat 2 move', s, const MoveIntention(2, 3));
        _expectEvents('$sc seat 2 move', a, <String>[
          'Moved(2,3,52,57)',
          'TokenHome(2,3)',
          'SeatFinished(2,3)',
          'SeatFinished(3,4)',
          'GameWon(0)',
        ]);
        _expectState(
          sc,
          a.state,
          currentSeat: a.state.currentSeat,
          phase: GamePhase.finished,
          winner: 0,
          queue: const <int>[],
          placings: const <int>[0, 1, 2, 3],
          retired: const <int>[],
          seq: 5,
          rollNull: true,
        );
        expect(isTerminal(a.state), isTrue, reason: '[$sc] not terminal');
        for (final i in <Intention>[
          const RollIntention(3, 2),
          const MoveIntention(3, 0),
          const RetireIntention(3),
          const RollIntention(0, 2),
        ]) {
          _expectRejected(
            '$sc after the end ${_iSig(i)}',
            a.state,
            i,
            EngineError.gameFinished,
          );
        }
      });
    }

    test(
        'P2.2 the winner is the first finisher, not the lowest or the last '
        'seat: seats 0..2, seat 2 first, seat 1 second, seat 0 left', () {
      const ready = <int>[57, 57, 57, 52];
      var s = _awaitMove(
        rq: true,
        seats: const <int>[0, 1, 2],
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: ready,
          2: ready,
        },
        face: 5,
        currentSeat: 2,
      );
      var a = _apply('P2.2 seat 2', s, const MoveIntention(2, 3));
      _expectEvents('P2.2 seat 2', a, <String>[
        'Moved(2,3,52,57)',
        'TokenHome(2,3)',
        'SeatFinished(2,1)',
        'TurnBegan(0)',
      ]);
      s = a.state;
      a = _apply('P2.2 seat 0 roll', s, const RollIntention(0, 3));
      s = a.state;
      a = _apply('P2.2 seat 0 move', s, const MoveIntention(0, 0));
      _expectEvents('P2.2 seat 0 move', a, <String>[
        'Moved(0,0,10,13)',
        'TurnBegan(1)',
      ]);
      s = a.state;
      a = _apply('P2.2 seat 1 roll', s, const RollIntention(1, 5));
      s = a.state;
      a = _apply('P2.2 seat 1 move', s, const MoveIntention(1, 3));
      _expectEvents('P2.2 seat 1 move', a, <String>[
        'Moved(1,3,52,57)',
        'TokenHome(1,3)',
        'SeatFinished(1,2)',
        'SeatFinished(0,3)',
        'GameWon(2)',
      ]);
      _expectState(
        'P2.2',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 2,
        placings: const <int>[2, 1, 0],
        retired: const <int>[],
      );
    });

    test(
        'P2.3 with three playing seats a finish leaves two and the game '
        'goes on', () {
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: <int>[57, 57, 57, 52],
          2: <int>[20, -1, -1, -1],
          3: _homeRow,
        },
        face: 5,
        currentSeat: 1,
        placings: const <int>[3],
      );
      final a = _apply('P2.3', s, const MoveIntention(1, 3));
      _expectEvents('P2.3', a, <String>[
        'Moved(1,3,52,57)',
        'TokenHome(1,3)',
        'SeatFinished(1,2)',
        'TurnBegan(2)',
      ]);
      _expectState(
        'P2.3',
        a.state,
        currentSeat: 2,
        phase: GamePhase.awaitRoll,
        winner: null,
        placings: const <int>[3, 1],
      );
    });
  });

  group('P3: two seats (rule 39p)', () {
    for (final rq in const <bool>[true, false]) {
      for (final hb in const <bool>[false, true]) {
        test(
          'P3.1 [rollQueue=$rq homeBonus=$hb] seat 0 home first: '
          'SeatFinished(0,1), SeatFinished(2,2), GameWon(0), in that order',
          () {
            final sc = 'P3.1 rollQueue=$rq homeBonus=$hb';
            final s = _awaitMove(
              rq: rq,
              seats: twoPlayerSeats,
              tokens: const {
                0: <int>[57, 57, 57, 52],
                2: <int>[10, -1, -1, -1],
              },
              face: 5,
              homeBonus: hb,
            );
            final a = _apply(sc, s, const MoveIntention(0, 3));
            _expectEvents(sc, a, <String>[
              'Moved(0,3,52,57)',
              'TokenHome(0,3)',
              'SeatFinished(0,1)',
              'SeatFinished(2,2)',
              'GameWon(0)',
            ]);
            _expectState(
              sc,
              a.state,
              currentSeat: a.state.currentSeat,
              phase: GamePhase.finished,
              winner: 0,
              queue: const <int>[],
              placings: const <int>[0, 2],
              retired: const <int>[],
              seq: 1,
              rollNull: true,
            );
          },
        );
      }
    }

    test('P3.2 seat 2 home first: places are [2, 0] and the winner is 2', () {
      final s = _awaitMove(
        rq: true,
        seats: twoPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: <int>[57, 57, 57, 52],
        },
        face: 5,
        currentSeat: 2,
      );
      final a = _apply('P3.2', s, const MoveIntention(2, 3));
      _expectEvents('P3.2', a, <String>[
        'Moved(2,3,52,57)',
        'TokenHome(2,3)',
        'SeatFinished(2,1)',
        'SeatFinished(0,2)',
        'GameWon(2)',
      ]);
      _expectState(
        'P3.2',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 2,
        placings: const <int>[2, 0],
      );
    });

    test(
        'P3.3 rule 39p: with two seats a player sees the old ending plus '
        'the two place events, and nothing else differs', () {
      for (final rq in const <bool>[true, false]) {
        final sc = 'P3.3 rollQueue=$rq';
        const tokens = <int, List<int>>{
          0: <int>[57, 57, 57, 52],
          2: <int>[10, -1, -1, -1],
        };
        final off = _awaitMove(
          rq: rq,
          seats: twoPlayerSeats,
          tokens: tokens,
          face: 5,
          playOut: false,
        );
        final on = _awaitMove(
          rq: rq,
          seats: twoPlayerSeats,
          tokens: tokens,
          face: 5,
        );
        final aOff = _apply('$sc off', off, const MoveIntention(0, 3));
        final aOn = _apply('$sc on', on, const MoveIntention(0, 3));
        _expectEvents('$sc off', aOff, <String>[
          'Moved(0,3,52,57)',
          'TokenHome(0,3)',
          'GameWon(0)',
        ]);
        expect(
          aOn.events
              .map(_sig)
              .where((e) => !e.startsWith('SeatFinished'))
              .toList(),
          aOff.events.map(_sig).toList(),
          reason: '[$sc] events differ beyond the two SeatFinished',
        );
        expect(aOn.state.tokens, aOff.state.tokens, reason: '[$sc] tokens');
        expect(aOn.state.winner, aOff.state.winner, reason: '[$sc] winner');
        expect(aOn.state.phase, aOff.state.phase, reason: '[$sc] phase');
        expect(aOn.state.seq, aOff.state.seq, reason: '[$sc] seq');
        expect(aOn.state.queue, aOff.state.queue, reason: '[$sc] queue');
        expect(
          aOff.state.placings,
          isEmpty,
          reason: '[$sc] placings must stay empty with playOut off',
        );
        expect(
          aOff.state.retired,
          isEmpty,
          reason: '[$sc] retired must stay empty with playOut off',
        );
      }
    });
  });

  group('P4: no bonus for the move that finishes a seat (rule 33p)', () {
    test(
        'P4.1 homeBonus on, rollQueue on, faces 3 and 2 still queued: no '
        'ExtraRoll, queue discarded, next seat', () {
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[57, 57, 57, 52],
          1: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 5,
        more: const <int>[3, 2],
        homeBonus: true,
      );
      expect(s.queue, const <int>[5, 3, 2], reason: 'fixture');
      final a = _apply('P4.1', s, const MoveIntention(0, 3, face: 5));
      _expectEvents('P4.1', a, <String>[
        'Moved(0,3,52,57)',
        'TokenHome(0,3)',
        'SeatFinished(0,1)',
        'TurnBegan(1)',
      ]);
      _expectState(
        'P4.1',
        a.state,
        currentSeat: 1,
        phase: GamePhase.awaitRoll,
        winner: null,
        queue: const <int>[],
        sixes: 0,
        rollNull: true,
      );
    });

    test(
        'P4.2 homeBonus on, rollQueue on: the spent face is a 6 and a 4 '
        'is behind it; still no bonus and the 4 is discarded', () {
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[57, 57, 57, 51],
          1: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 6,
        more: const <int>[4],
        homeBonus: true,
      );
      final a = _apply('P4.2', s, const MoveIntention(0, 3, face: 6));
      _expectEvents('P4.2', a, <String>[
        'Moved(0,3,51,57)',
        'TokenHome(0,3)',
        'SeatFinished(0,1)',
        'TurnBegan(1)',
      ]);
      expect(a.state.queue, isEmpty, reason: '[P4.2] queue not discarded');
    });

    test(
        'P4.3 rollQueue off, homeBonus on, a 6 brings the fourth token '
        'home with sixes at 1: no ExtraRoll (rule 12 would owe one), sixes '
        'is 0 for the next seat', () {
      final s = _awaitMove(
        rq: false,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[57, 57, 57, 51],
          1: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 6,
        sixes: 1,
        homeBonus: true,
      );
      final a = _apply('P4.3', s, const MoveIntention(0, 3));
      _expectEvents('P4.3', a, <String>[
        'Moved(0,3,51,57)',
        'TokenHome(0,3)',
        'SeatFinished(0,1)',
        'TurnBegan(1)',
      ]);
      _expectState(
        'P4.3',
        a.state,
        currentSeat: 1,
        phase: GamePhase.awaitRoll,
        winner: null,
        sixes: 0,
        rollNull: true,
      );
    });

    for (final rq in const <bool>[true, false]) {
      test(
          'P4.4 [rollQueue=$rq] control: the third token home still earns the '
          'home bonus with playOut on; only the finishing move loses it', () {
        final sc = 'P4.4 rollQueue=$rq';
        final s = _awaitMove(
          rq: rq,
          seats: fourPlayerSeats,
          tokens: const {
            0: <int>[57, 57, 52, -1],
            1: <int>[10, -1, -1, -1],
            2: <int>[20, -1, -1, -1],
            3: <int>[30, -1, -1, -1],
          },
          face: 5,
          homeBonus: true,
        );
        final a = _apply(sc, s, const MoveIntention(0, 2));
        _expectEvents(sc, a, <String>[
          'Moved(0,2,52,57)',
          'TokenHome(0,2)',
          'ExtraRoll(0)',
        ]);
        _expectState(
          sc,
          a.state,
          currentSeat: 0,
          phase: GamePhase.awaitRoll,
          winner: null,
          placings: const <int>[],
        );
      });
    }
  });

  group('P5: retiring the seat to act (rule 34p, ENGINE_API 12.4)', () {
    test(
        'P5.1 awaitMove with queue [4,2]: tokens not at 57 go to -1, the '
        'one at 57 stays, SeatRetired then TurnBegan(1), queue emptied', () {
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, 57, -1, 54],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 4,
        more: const <int>[2],
        sixes: 0,
      );
      final a = _apply('P5.1', s, const RetireIntention(0));
      _expectEvents('P5.1', a, <String>['SeatRetired(0)', 'TurnBegan(1)']);
      expect(
          a.state.tokens[0],
          const <int>[
            -1,
            57,
            -1,
            -1,
          ],
          reason: '[P5.1] tokens of the retired seat: ${_dump(a.state)}');
      expect(
        a.state.tokens[1],
        s.tokens[1],
        reason: '[P5.1] another seat changed',
      );
      _expectState(
        'P5.1',
        a.state,
        currentSeat: 1,
        phase: GamePhase.awaitRoll,
        winner: null,
        queue: const <int>[],
        sixes: 0,
        placings: const <int>[],
        retired: const <int>[0],
        seq: 1,
        rollNull: true,
      );
    });

    test(
        'P5.2 rollQueue off, roll 6 held with sixes 1: roll cleared, '
        'sixes 0, next seat', () {
      final s = _awaitMove(
        rq: false,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, 52, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 6,
        sixes: 1,
      );
      final a = _apply('P5.2', s, const RetireIntention(0));
      _expectEvents('P5.2', a, <String>['SeatRetired(0)', 'TurnBegan(1)']);
      expect(a.state.tokens[0], _yardRow, reason: '[P5.2] tokens');
      _expectState(
        'P5.2',
        a.state,
        currentSeat: 1,
        phase: GamePhase.awaitRoll,
        winner: null,
        sixes: 0,
        retired: const <int>[0],
        rollNull: true,
      );
    });

    test(
        'P5.3 awaitRoll holding a queued 6 with sixes 1 (a roll is owed): '
        'the queue is discarded and the next seat begins', () {
      final s = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        currentSeat: 0,
        queue: const <int>[6],
        sixes: 1,
      );
      final a = _apply('P5.3', s, const RetireIntention(0));
      _expectEvents('P5.3', a, <String>['SeatRetired(0)', 'TurnBegan(1)']);
      _expectState(
        'P5.3',
        a.state,
        currentSeat: 1,
        phase: GamePhase.awaitRoll,
        winner: null,
        queue: const <int>[],
        sixes: 0,
        retired: const <int>[0],
      );
    });

    test('P5.4 the next seat skips a finished seat, and wraps', () {
      final skip = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: _homeRow,
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 3,
        placings: const <int>[1],
      );
      final a = _apply('P5.4 skip', skip, const RetireIntention(0));
      _expectEvents('P5.4 skip', a, <String>['SeatRetired(0)', 'TurnBegan(2)']);

      final wrap = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: _homeRow,
          1: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 3,
        currentSeat: 3,
        placings: const <int>[0],
      );
      final b = _apply('P5.4 wrap', wrap, const RetireIntention(3));
      _expectEvents('P5.4 wrap', b, <String>['SeatRetired(3)', 'TurnBegan(1)']);
    });

    test(
      'P5.5 the retired seat, once out, cannot roll or move: notYourTurn',
      () {
        final s = _awaitMove(
          rq: true,
          seats: fourPlayerSeats,
          tokens: const {
            0: <int>[10, -1, -1, -1],
            1: <int>[3, -1, -1, -1],
            2: <int>[20, -1, -1, -1],
            3: <int>[30, -1, -1, -1],
          },
          face: 4,
        );
        final after = _apply('P5.5', s, const RetireIntention(0)).state;
        _expectRejected(
          'P5.5 roll',
          after,
          const RollIntention(0, 3),
          EngineError.notYourTurn,
        );
        _expectRejected(
          'P5.5 move',
          after,
          const MoveIntention(0, 0),
          EngineError.notYourTurn,
        );
      },
    );
  });

  group('P6: retiring a seat that is not to act (rule 34p)', () {
    for (final rq in const <bool>[true, false]) {
      test(
          'P6.1 [rollQueue=$rq] the acting seat keeps phase, queue, roll and '
          'sixes; only the retired seat and the lists change', () {
        final sc = 'P6.1 rollQueue=$rq';
        final s = _awaitMove(
          rq: rq,
          seats: fourPlayerSeats,
          tokens: const {
            0: <int>[42, -1, -1, -1],
            1: <int>[3, -1, -1, -1],
            2: <int>[20, 57, 54, 9],
            3: <int>[30, -1, -1, -1],
          },
          face: 4,
          more: const <int>[6],
          sixes: 0,
        );
        final a = _apply(sc, s, const RetireIntention(2));
        _expectEvents(sc, a, <String>['SeatRetired(2)']);
        final want = _deep(s.toJson());
        (want['tokens'] as List<Object?>)[2] = <int>[-1, 57, -1, -1];
        want['retired'] = <int>[2];
        want['seq'] = 1;
        expect(
          _dump(a.state),
          jsonEncode(want),
          reason: '[$sc] only tokens[2], retired and seq may change; '
              'before: ${_dump(s)}',
        );
      });
    }

    test(
        'P6.2 the retired seat is skipped from then on: passes, three '
        'sixes and moves all go 1 -> 3 -> 0 -> 1', () {
      var s = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[-1, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        },
        currentSeat: 1,
      );
      s = _apply('P6.2 retire', s, const RetireIntention(2)).state;
      var a = _apply('P6.2 s1', s, const RollIntention(1, 3));
      _expectEvents('P6.2 s1', a, <String>[
        'Rolled(1,3)',
        'TurnEnded(1,noLegalMove)',
        'TurnBegan(3)',
      ]);
      a = _apply('P6.2 s3', a.state, const RollIntention(3, 3));
      _expectEvents('P6.2 s3', a, <String>[
        'Rolled(3,3)',
        'TurnEnded(3,noLegalMove)',
        'TurnBegan(0)',
      ]);
      a = _apply('P6.2 s0', a.state, const RollIntention(0, 3));
      _expectEvents('P6.2 s0', a, <String>[
        'Rolled(0,3)',
        'TurnEnded(0,noLegalMove)',
        'TurnBegan(1)',
      ]);

      // Three sixes in the queue mode: the forfeit passes to seat 3, not 2.
      a = _apply('P6.2 6a', a.state, const RollIntention(1, 6));
      a = _apply('P6.2 6b', a.state, const RollIntention(1, 6));
      a = _apply('P6.2 6c', a.state, const RollIntention(1, 6));
      _expectEvents('P6.2 6c', a, <String>[
        'Rolled(1,6)',
        'TurnEnded(1,threeSixes)',
        'TurnBegan(3)',
      ]);
    });

    test(
        'P6.3 its token cannot be captured: the same move captures before '
        'the retirement and captures nothing after it', () {
      // Seat 2 progress 20 stands on absolute (26 + 20) % 52 = 46, not safe.
      // Seat 0 progress 42 plus 4 lands on 46.
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[42, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 4,
      );
      final control = _apply('P6.3 control', s, const MoveIntention(0, 0));
      _expectEvents('P6.3 control', control, <String>[
        'Moved(0,0,42,46)',
        'Captured(2,0,0,0)',
        'ExtraRoll(0)',
      ]);

      final retired = _apply('P6.3 retire', s, const RetireIntention(2)).state;
      final a = _apply('P6.3 move', retired, const MoveIntention(0, 0));
      _expectEvents('P6.3 move', a, <String>[
        'Moved(0,0,42,46)',
        'TurnBegan(1)',
      ]);
      expect(
        a.state.tokens[2],
        _yardRow,
        reason: '[P6.3] the retired seat stayed in the yard',
      );
    });

    test(
        'P6.4 its pair no longer blocks (blocks on): a move that crosses '
        'and lands on its old square is illegal before, legal after', () {
      // Seat 2 pair at progress 18, absolute 44. Seat 0 token 0 at 42 plus
      // 4 crosses 44 and lands on 46. Token 1 at 5 gives the seat a legal
      // move so the state is a real awaitMove.
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[42, 5, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[18, 18, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 4,
      );
      expect(
          legalTokens(s),
          const <int>[
            1,
          ],
          reason: 'fixture: the pair must block token 0; state ${_dump(s)}');
      _expectRejected(
        'P6.4 before',
        s,
        const MoveIntention(0, 0),
        EngineError.illegalMove,
      );

      final retired = _apply('P6.4 retire', s, const RetireIntention(2)).state;
      expect(
        legalTokens(retired),
        const <int>[0, 1],
        reason: '[P6.4] the pair still blocks after retirement; '
            'state: ${_dump(retired)}',
      );
      final a = _apply('P6.4 move', retired, const MoveIntention(0, 0));
      _expectEvents('P6.4 move', a, <String>[
        'Moved(0,0,42,46)',
        'TurnBegan(1)',
      ]);
    });

    test(
        'P6.5 a track token and a home-column token of the retired seat '
        'both go to the yard', () {
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[8, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[34, 55, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 5,
      );
      final r = _apply('P6.5 retire', s, const RetireIntention(2)).state;
      expect(
        r.tokens[2],
        _yardRow,
        reason: '[P6.5] a track token and a column token both go to -1; '
            'state: ${_dump(r)}',
      );
    });
  });

  group('P7: down to one playing seat (rule 36p, 37p)', () {
    test(
        'P7.1 two seats, nobody finished, the other seat retires: the '
        'acting seat takes place 1 and the game ends', () {
      final s = _awaitMove(
        rq: true,
        seats: twoPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: <int>[20, 57, -1, -1],
        },
        face: 4,
      );
      final a = _apply('P7.1', s, const RetireIntention(2));
      _expectEvents('P7.1', a, <String>[
        'SeatRetired(2)',
        'SeatFinished(0,1)',
        'GameWon(0)',
      ]);
      _expectState(
        'P7.1',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 0,
        queue: const <int>[],
        placings: const <int>[0],
        retired: const <int>[2],
        seq: 1,
        rollNull: true,
      );
      expect(
          a.state.tokens[2],
          const <int>[
            -1,
            57,
            -1,
            -1,
          ],
          reason: '[P7.1] tokens of the retired seat');
    });

    test(
        'P7.2 two seats, the acting seat retires: the other seat takes '
        'place 1 and wins', () {
      final s = _awaitMove(
        rq: true,
        seats: twoPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
        },
        face: 4,
      );
      final a = _apply('P7.2', s, const RetireIntention(0));
      _expectEvents('P7.2', a, <String>[
        'SeatRetired(0)',
        'SeatFinished(2,1)',
        'GameWon(2)',
      ]);
      _expectState(
        'P7.2',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 2,
        placings: const <int>[2],
        retired: const <int>[0],
      );
    });

    test(
        'P7.3 one seat already finished: the last seat takes place 2 and '
        'the winner is the first finisher, whoever retires', () {
      final base = _awaitMove(
        rq: true,
        seats: const <int>[0, 1, 2],
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: _homeRow,
          2: <int>[20, -1, -1, -1],
        },
        face: 4,
        placings: const <int>[1],
      );
      // The acting seat 0 retires: seat 2 is last.
      final a = _apply('P7.3 acting', base, const RetireIntention(0));
      _expectEvents('P7.3 acting', a, <String>[
        'SeatRetired(0)',
        'SeatFinished(2,2)',
        'GameWon(1)',
      ]);
      _expectState(
        'P7.3 acting',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 1,
        placings: const <int>[1, 2],
        retired: const <int>[0],
      );
      // Seat 2 retires instead: seat 0 is last and acts.
      final b = _apply('P7.3 other', base, const RetireIntention(2));
      _expectEvents('P7.3 other', b, <String>[
        'SeatRetired(2)',
        'SeatFinished(0,2)',
        'GameWon(1)',
      ]);
      _expectState(
        'P7.3 other',
        b.state,
        currentSeat: b.state.currentSeat,
        phase: GamePhase.finished,
        winner: 1,
        placings: const <int>[1, 0],
        retired: const <int>[2],
      );
    });

    test(
        'P7.4 four seats retire one at a time: retirement order is kept, '
        'the game ends on the third, the survivor is place 1', () {
      var s = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        currentSeat: 0,
      );
      var a = _apply('P7.4 r1', s, const RetireIntention(1));
      _expectEvents('P7.4 r1', a, <String>['SeatRetired(1)']);
      s = a.state;
      a = _apply('P7.4 r3', s, const RetireIntention(3));
      _expectEvents('P7.4 r3', a, <String>['SeatRetired(3)']);
      s = a.state;
      expect(isTerminal(s), isFalse, reason: '[P7.4] ended with two left');
      a = _apply('P7.4 r2', s, const RetireIntention(2));
      _expectEvents('P7.4 r2', a, <String>[
        'SeatRetired(2)',
        'SeatFinished(0,1)',
        'GameWon(0)',
      ]);
      _expectState(
        'P7.4',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 0,
        placings: const <int>[0],
        retired: const <int>[1, 3, 2],
        seq: 3,
      );
    });

    test(
        'P7.5 UNREACHABLE STATE, hand-built: a running state with one '
        'playing seat and nobody placed; retiring it ends the game with no '
        'winner and no GameWon', () {
      final s = _state(
        seats: twoPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          2: _yardRow,
        },
        currentSeat: 0,
        retired: const <int>[2],
      );
      final a = _apply('P7.5', s, const RetireIntention(0));
      _expectEvents('P7.5', a, <String>['SeatRetired(0)']);
      _expectState(
        'P7.5',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: null,
        queue: const <int>[],
        placings: const <int>[],
        retired: const <int>[2, 0],
      );
      expect(isTerminal(a.state), isTrue, reason: '[P7.5] not terminal');
      _expectRejected(
        'P7.5 after',
        a.state,
        const RollIntention(0, 3),
        EngineError.gameFinished,
      );
      final back = GameState.fromJson(
        jsonDecode(_dump(a.state)) as Map<String, Object?>,
      );
      expect(_dump(back), _dump(a.state), reason: '[P7.5] round trip');
    });

    test(
        'P7.6 UNREACHABLE STATE, hand-built: one seat finished, one '
        'retired, the last playing seat retires: winner is the first '
        'place, GameWon is emitted', () {
      final s = _state(
        seats: const <int>[0, 1, 2],
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: _homeRow,
          2: _yardRow,
        },
        currentSeat: 0,
        placings: const <int>[1],
        retired: const <int>[2],
      );
      final a = _apply('P7.6', s, const RetireIntention(0));
      _expectEvents('P7.6', a, <String>['SeatRetired(0)', 'GameWon(1)']);
      _expectState(
        'P7.6',
        a.state,
        currentSeat: a.state.currentSeat,
        phase: GamePhase.finished,
        winner: 1,
        placings: const <int>[1],
        retired: const <int>[2, 0],
      );
    });
  });

  group('P8: rejections of RetireIntention, in the order of 12.4', () {
    GameState running() => _awaitMove(
          rq: true,
          seats: twoPlayerSeats,
          tokens: const {
            0: <int>[10, -1, -1, -1],
            2: <int>[20, -1, -1, -1],
          },
          face: 4,
        );
    GameState off() => _awaitMove(
          rq: true,
          seats: twoPlayerSeats,
          tokens: const {
            0: <int>[10, -1, -1, -1],
            2: <int>[20, -1, -1, -1],
          },
          face: 4,
          playOut: false,
        );
    GameState finishedOn() => _state(
          seats: twoPlayerSeats,
          tokens: const {
            0: _homeRow,
            2: <int>[10, -1, -1, -1],
          },
          phase: 'finished',
          winner: 0,
          placings: const <int>[0, 2],
        );

    test(
        'P8.1 finished game: gameFinished, even for a seat not in the '
        'config and even with playOut off', () {
      _expectRejected(
        'P8.1 in config',
        finishedOn(),
        const RetireIntention(2),
        EngineError.gameFinished,
      );
      _expectRejected(
        'P8.1 not in config',
        finishedOn(),
        const RetireIntention(1),
        EngineError.gameFinished,
      );
      final finishedOff = _state(
        seats: twoPlayerSeats,
        tokens: const {
          0: _homeRow,
          2: <int>[10, -1, -1, -1],
        },
        phase: 'finished',
        winner: 0,
        playOut: false,
      );
      _expectRejected(
        'P8.1 playOut off',
        finishedOff,
        const RetireIntention(2),
        EngineError.gameFinished,
      );
      _expectRejected(
        'P8.1 playOut off, not in config',
        finishedOff,
        const RetireIntention(3),
        EngineError.gameFinished,
      );
    });

    test(
        'P8.2 playOut off, game running: wrongPhase, ahead of the seat '
        'check', () {
      _expectRejected(
        'P8.2 acting seat',
        off(),
        const RetireIntention(0),
        EngineError.wrongPhase,
      );
      _expectRejected(
        'P8.2 other seat',
        off(),
        const RetireIntention(2),
        EngineError.wrongPhase,
      );
      _expectRejected(
        'P8.2 seat not in config',
        off(),
        const RetireIntention(1),
        EngineError.wrongPhase,
      );
      final fresh = newGame(
        GameConfig(
          seats: const <int>[0, 1, 2],
          rules: const RulesConfig(rollQueue: true),
          seed: 5,
        ),
      );
      _expectRejected(
        'P8.2 newGame',
        fresh,
        const RetireIntention(1),
        EngineError.wrongPhase,
      );
      final legacy = newGame(GameConfig(seats: const <int>[0, 2], seed: 5));
      _expectRejected(
        'P8.2 legacy newGame',
        legacy,
        const RetireIntention(2),
        EngineError.wrongPhase,
      );
    });

    test('P8.3 playOut on, seat not in config: seatNotInPlay', () {
      for (final seat in const <int>[1, 3, -1, 4, 99]) {
        _expectRejected(
          'P8.3 seat $seat',
          running(),
          RetireIntention(seat),
          EngineError.seatNotInPlay,
        );
      }
    });

    test('P8.4 seat already finished or already retired: illegalMove', () {
      final withFinished = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: _homeRow,
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 4,
        placings: const <int>[1],
      );
      _expectRejected(
        'P8.4 finished',
        withFinished,
        const RetireIntention(1),
        EngineError.illegalMove,
      );
      final once = _apply('P8.4 first', withFinished, const RetireIntention(3));
      _expectEvents('P8.4 first', once, <String>['SeatRetired(3)']);
      _expectRejected(
        'P8.4 replayed',
        once.state,
        const RetireIntention(3),
        EngineError.illegalMove,
      );
      _expectRejected(
        'P8.4 finished after a retire',
        once.state,
        const RetireIntention(1),
        EngineError.illegalMove,
      );
    });

    test('P8.5 replaying the retirement that ended the game: gameFinished', () {
      final ended = _apply('P8.5', running(), const RetireIntention(2)).state;
      _expectRejected(
        'P8.5 replay',
        ended,
        const RetireIntention(2),
        EngineError.gameFinished,
      );
      _expectRejected(
        'P8.5 winner',
        ended,
        const RetireIntention(0),
        EngineError.gameFinished,
      );
    });

    test(
        'P8.6 accepted in awaitRoll and awaitMove, from any seat, with no '
        'turn check', () {
      final awaitRoll = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        currentSeat: 1,
      );
      for (final seat in fourPlayerSeats) {
        final a = _apply(
          'P8.6 awaitRoll seat $seat',
          awaitRoll,
          RetireIntention(seat),
        );
        expect(
          a.events.map(_sig).first,
          'SeatRetired($seat)',
          reason: '[P8.6 awaitRoll seat $seat] first event',
        );
      }
      final awaitMove = _awaitMove(
        rq: false,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 4,
        currentSeat: 1,
      );
      for (final seat in fourPlayerSeats) {
        final a = _apply(
          'P8.6 awaitMove seat $seat',
          awaitMove,
          RetireIntention(seat),
        );
        expect(
          a.events.map(_sig).first,
          'SeatRetired($seat)',
          reason: '[P8.6 awaitMove seat $seat] first event',
        );
      }
    });

    test(
        'P8.7 a retirement leaves seed, rngState and config alone and '
        'bumps seq by one, as a move does', () {
      final a = _apply('P8.7', running(), const RetireIntention(2));
      expect(a.state.seq, running().seq + 1, reason: '[P8.7] seq');
      expect(a.state.rngState, running().rngState, reason: '[P8.7] rngState');
      expect(a.state.config, running().config, reason: '[P8.7] config');
    });

    test(
        'P8.8 the ordinary rejections still apply with playOut on: the '
        'wrong phase and the third-party move', () {
      _expectRejected(
        'P8.8 roll in awaitMove',
        running(),
        const RollIntention(0, 3),
        EngineError.wrongPhase,
      );
      _expectRejected(
        'P8.8 seat not in config',
        running(),
        const RollIntention(1, 3),
        EngineError.seatNotInPlay,
      );
      _expectRejected(
        'P8.8 not your turn',
        running(),
        const MoveIntention(2, 0),
        EngineError.notYourTurn,
      );
    });
  });

  group('P9: serialisation', () {
    test(
        'P9.1 playOut off: the bytes are those of a state built before the '
        'toggle, and placings and retired read as empty', () {
      final legacy = newGame(GameConfig(seats: const <int>[0, 2], seed: 7));
      expect(
        _dump(legacy),
        '{"config":{"seats":[0,2],"rules":{"blocks":true,'
        '"captureBonus":true},"seed":7},"tokens":[[-1,-1,-1,-1],'
        '[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1]],"currentSeat":0,'
        '"phase":"awaitRoll","roll":null,"sixes":0,"winner":null,'
        '"seq":0,"rngState":7}',
        reason: '[P9.1 legacy newGame] bytes changed with playOut off',
      );
      expect(legacy.placings, isEmpty);
      expect(legacy.retired, isEmpty);
      expect(
        stateHash(legacy),
        _fnvHex(_dump(legacy)),
        reason: '[P9.1] hash is not FNV-1a of the canonical text',
      );

      final queue = newGame(
        GameConfig(
          seats: const <int>[0, 1, 2],
          rules: const RulesConfig(rollQueue: true, homeBonus: true),
          seed: 9,
        ),
      );
      expect(
        _dump(queue),
        '{"config":{"seats":[0,1,2],"rules":{"blocks":true,'
        '"captureBonus":true,"rollQueue":true,"homeBonus":true},"seed":9},'
        '"tokens":[[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1],'
        '[-1,-1,-1,-1]],"currentSeat":0,"phase":"awaitRoll","roll":null,'
        '"queue":[],"sixes":0,"winner":null,"seq":0,"rngState":9}',
        reason: '[P9.1 queue newGame] bytes changed with playOut off',
      );
      expect(queue.placings, isEmpty);
      expect(queue.retired, isEmpty);

      // A pre-toggle JSON text survives fromJson and toJson unchanged.
      final text = _dump(queue);
      final back = GameState.fromJson(jsonDecode(text) as Map<String, Object?>);
      expect(_dump(back), text, reason: '[P9.1] pre-toggle round trip');
    });

    test(
        'P9.2 playOut off: a finishing move is still the old ending, and '
        'the state never grows the new keys while playing a whole game', () {
      final s = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[57, 57, 57, 52],
          1: <int>[10, -1, -1, -1],
        },
        face: 5,
        playOut: false,
      );
      final a = _apply('P9.2', s, const MoveIntention(0, 3));
      _expectEvents('P9.2', a, <String>[
        'Moved(0,3,52,57)',
        'TokenHome(0,3)',
        'GameWon(0)',
      ]);
      expect(a.state.winner, 0, reason: '[P9.2] winner');
      expect(a.state.placings, isEmpty, reason: '[P9.2] placings');
      expect(a.state.retired, isEmpty, reason: '[P9.2] retired');
      final json = a.state.toJson();
      expect(
        json.containsKey('placings'),
        isFalse,
        reason: '[P9.2] placings written with playOut off',
      );
      expect(
        json.containsKey('retired'),
        isFalse,
        reason: '[P9.2] retired written with playOut off',
      );
      expect(
        _rulesOf(json).containsKey('playOut'),
        isFalse,
        reason: '[P9.2] playOut written when false',
      );
    });

    test(
        'P9.3 playOut on: newGame writes playOut last in rules and '
        'placings, retired right after winner', () {
      final g = newGame(
        GameConfig(
          seats: const <int>[0, 2],
          rules: const RulesConfig(playOut: true),
          seed: 7,
        ),
      );
      expect(
        _dump(g),
        '{"config":{"seats":[0,2],"rules":{"blocks":true,'
        '"captureBonus":true,"playOut":true},"seed":7},"tokens":'
        '[[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1]],'
        '"currentSeat":0,"phase":"awaitRoll","roll":null,"sixes":0,'
        '"winner":null,"placings":[],"retired":[],"seq":0,"rngState":7}',
        reason: '[P9.3] playOut without rollQueue',
      );
      expect(g.placings, isEmpty);
      expect(g.retired, isEmpty);
      expect(g.winner, isNull);

      final all = newGame(
        GameConfig(
          seats: const <int>[0, 1, 2, 3],
          rules: const RulesConfig(
            rollQueue: true,
            homeBonus: true,
            yardRelease: true,
            playOut: true,
          ),
          seed: 11,
        ),
      );
      expect(
        _dump(all),
        '{"config":{"seats":[0,1,2,3],"rules":{"blocks":true,'
        '"captureBonus":true,"rollQueue":true,"homeBonus":true,'
        '"yardRelease":true,"playOut":true},"seed":11},"tokens":'
        '[[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1]],'
        '"currentSeat":0,"phase":"awaitRoll","roll":null,"queue":[],'
        '"sixes":0,"drought":[0,0,0,0],"releaseOwed":false,"winner":null,'
        '"placings":[],"retired":[],"seq":0,"rngState":11}',
        reason: '[P9.3] every toggle on',
      );
      expect(
        stateHash(all),
        _fnvHex(_dump(all)),
        reason: '[P9.3] hash is not FNV-1a of the canonical text',
      );

      final noYard = newGame(
        GameConfig(
          seats: const <int>[0, 1, 2],
          rules: const RulesConfig(
            rollQueue: true,
            homeBonus: true,
            playOut: true,
          ),
          seed: 3,
        ),
      );
      expect(
        jsonEncode(_rulesOf(noYard.toJson())),
        '{"blocks":true,"captureBonus":true,"rollQueue":true,'
        '"homeBonus":true,"playOut":true}',
        reason: '[P9.3] playOut goes after homeBonus when yardRelease is '
            'absent',
      );
    });

    test(
        'P9.4 a played state: key order is winner, placings, retired, seq, '
        'and a round trip is byte-identical', () {
      final s = _awaitMove(
        rq: true,
        seats: twoPlayerSeats,
        tokens: const {
          0: <int>[57, 57, 57, 52],
          2: <int>[10, -1, -1, -1],
        },
        face: 5,
      );
      final a = _apply('P9.4', s, const MoveIntention(0, 3));
      final json = a.state.toJson();
      expect(
          json.keys.toList(),
          <String>[
            'config',
            'tokens',
            'currentSeat',
            'phase',
            'roll',
            'queue',
            'sixes',
            'winner',
            'placings',
            'retired',
            'seq',
            'rngState',
          ],
          reason: '[P9.4] key order; state ${_dump(a.state)}');
      expect(json['placings'], const <int>[0, 2], reason: '[P9.4] placings');
      expect(json['retired'], const <int>[], reason: '[P9.4] retired');
      expect(json['winner'], 0, reason: '[P9.4] winner');
      expect(json['phase'], 'finished', reason: '[P9.4] phase');
      final back = GameState.fromJson(
        jsonDecode(_dump(a.state)) as Map<String, Object?>,
      );
      expect(back, a.state, reason: '[P9.4] round trip equality');
      expect(_dump(back), _dump(a.state), reason: '[P9.4] round trip bytes');
      expect(stateHash(back), stateHash(a.state), reason: '[P9.4] hash');

      // A retirement serialises its order.
      final r = _awaitMove(
        rq: true,
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[10, -1, -1, -1],
          1: <int>[3, -1, -1, -1],
          2: <int>[20, -1, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        face: 4,
      );
      var x = _apply('P9.4 r3', r, const RetireIntention(3)).state;
      x = _apply('P9.4 r1', x, const RetireIntention(1)).state;
      expect(
          x.toJson()['retired'],
          const <int>[
            3,
            1,
          ],
          reason: '[P9.4] retired order; state ${_dump(x)}');
      expect(x.retired, const <int>[3, 1], reason: '[P9.4] getter');
    });

    test(
        'P9.5 the hash tells apart states that differ only in placings or '
        'retired', () {
      final a = _state(
        seats: fourPlayerSeats,
        tokens: const {0: _homeRow, 1: _homeRow},
        currentSeat: 2,
        placings: const <int>[0, 1],
      );
      final b = _state(
        seats: fourPlayerSeats,
        tokens: const {0: _homeRow, 1: _homeRow},
        currentSeat: 2,
        placings: const <int>[1, 0],
      );
      expect(
        stateHash(a),
        isNot(stateHash(b)),
        reason: '[P9.5] place order not in the hash',
      );
      expect(a == b, isFalse, reason: '[P9.5] equality ignores the order');
      final c = _state(
        seats: fourPlayerSeats,
        tokens: const {0: _yardRow, 1: _yardRow},
        currentSeat: 2,
        retired: const <int>[0, 1],
      );
      final d = _state(
        seats: fourPlayerSeats,
        tokens: const {0: _yardRow, 1: _yardRow},
        currentSeat: 2,
        retired: const <int>[1, 0],
      );
      expect(
        stateHash(c),
        isNot(stateHash(d)),
        reason: '[P9.5] retirement order not in the hash',
      );
    });

    test(
        'P9.6 RulesConfig: playOut defaults off and takes part in '
        'equality and hashCode', () {
      expect(const RulesConfig().playOut, isFalse, reason: '[P9.6] default');
      expect(const RulesConfig(playOut: true).playOut, isTrue);
      expect(
        const RulesConfig(playOut: true) == const RulesConfig(),
        isFalse,
        reason: '[P9.6] equality',
      );
      expect(
        const RulesConfig(playOut: true),
        const RulesConfig(playOut: true),
      );
      expect(
        const RulesConfig(playOut: true).hashCode,
        const RulesConfig(playOut: true).hashCode,
      );
    });

    Map<String, Object?> onJson({
      List<int> placings = const <int>[],
      List<int> retired = const <int>[],
      String phase = 'awaitRoll',
      int? winner,
      Map<int, List<int>> tokens = const <int, List<int>>{},
    }) =>
        _stateJson(
          seats: const <int>[0, 1, 2],
          tokens: tokens,
          currentSeat: 2,
          phase: phase,
          winner: winner,
          placings: placings,
          retired: retired,
        );

    void rejects(String sc, Map<String, Object?> json) {
      expect(
        () => GameState.fromJson(json),
        throwsFormatException,
        reason:
            '[$sc] fromJson must throw FormatException for ${jsonEncode(json)}',
      );
    }

    test(
        'P9.7 fromJson reads absent placings and retired as empty and '
        'accepts a well-formed on-state', () {
      final j = onJson();
      final s = GameState.fromJson(j);
      expect(s.placings, isEmpty);
      expect(s.retired, isEmpty);
      final ok = GameState.fromJson(
        onJson(
          placings: const <int>[0, 1],
          tokens: const {0: _homeRow, 1: _homeRow},
        ),
      );
      expect(ok.placings, const <int>[0, 1], reason: '[P9.7] placings');
      final r = GameState.fromJson(
        onJson(retired: const <int>[1], tokens: const {1: _yardRow}),
      );
      expect(r.retired, const <int>[1], reason: '[P9.7] retired');
    });

    test('P9.8 fromJson: an explicit playOut false is rejected', () {
      final j = _deep(_stateJson(seats: const <int>[0, 1, 2], playOut: false));
      _rulesOf(j)['playOut'] = false;
      rejects('P9.8 false without keys', j);
      final k = _deep(onJson());
      _rulesOf(k)['playOut'] = false;
      rejects('P9.8 false with keys', k);
    });

    test(
        'P9.9 fromJson: placings or retired on a state whose rules lack '
        'playOut', () {
      for (final key in const <String>['placings', 'retired']) {
        final j = _deep(
          _stateJson(seats: const <int>[0, 1, 2], playOut: false),
        );
        j[key] = <int>[];
        rejects('P9.9 $key empty', j);
        final k = _deep(
          _stateJson(
            seats: const <int>[0, 1, 2],
            playOut: false,
            tokens: const {0: _homeRow},
          ),
        );
        k[key] = <int>[0];
        rejects('P9.9 $key non-empty', k);
      }
    });

    test('P9.10 fromJson: either key missing when playOut is true', () {
      for (final key in const <String>['placings', 'retired']) {
        final j = _deep(onJson());
        j.remove(key);
        rejects('P9.10 missing $key', j);
      }
    });

    test('P9.11 fromJson: a seat not in config.seats', () {
      rejects('P9.11 placings', onJson(placings: const <int>[3]));
      rejects('P9.11 retired', onJson(retired: const <int>[3]));
      rejects('P9.11 negative', onJson(retired: const <int>[-1]));
    });

    test('P9.12 fromJson: a seat in both lists, or twice in one', () {
      rejects(
        'P9.12 both',
        onJson(
          placings: const <int>[1],
          retired: const <int>[1],
          tokens: const {1: _homeRow},
        ),
      );
      rejects(
        'P9.12 placings twice',
        onJson(placings: const <int>[1, 1], tokens: const {1: _homeRow}),
      );
      rejects('P9.12 retired twice', onJson(retired: const <int>[2, 2]));
    });

    test('P9.13 fromJson: winner set while the phase is not finished', () {
      for (final phase in const <String>['awaitRoll', 'awaitMove']) {
        rejects(
          'P9.13 $phase',
          onJson(
            phase: phase,
            winner: 0,
            placings: const <int>[0],
            tokens: const {0: _homeRow},
          ),
        );
      }
    });

    test(
        'P9.14 fromJson: a finished state whose winner is not the first '
        'place; and the two shapes that are accepted', () {
      rejects(
        'P9.14 winner is the second place',
        onJson(
          phase: 'finished',
          winner: 1,
          placings: const <int>[0, 1, 2],
          tokens: const {0: _homeRow, 1: _homeRow, 2: _homeRow},
        ),
      );
      rejects(
        'P9.14 winner null with places',
        onJson(
          phase: 'finished',
          winner: null,
          placings: const <int>[0, 1, 2],
          tokens: const {0: _homeRow, 1: _homeRow, 2: _homeRow},
        ),
      );
      final ok = GameState.fromJson(
        onJson(
          phase: 'finished',
          winner: 0,
          placings: const <int>[0, 1, 2],
          tokens: const {0: _homeRow, 1: _homeRow, 2: _homeRow},
        ),
      );
      expect(ok.winner, 0, reason: '[P9.14] well-formed finished state');
      expect(isTerminal(ok), isTrue);
      final none = GameState.fromJson(
        onJson(phase: 'finished', winner: null, retired: const <int>[0, 1, 2]),
      );
      expect(
        none.winner,
        isNull,
        reason: '[P9.14] a finished state with no places and no winner '
            '(rule 36p, none left) must load',
      );
    });

    test(
        'P9.15 newGame: playOut needs nothing else, yardRelease without '
        'rollQueue still throws', () {
      expect(
        () => newGame(
          GameConfig(
            seats: const <int>[0, 2],
            rules: const RulesConfig(playOut: true),
            seed: 1,
          ),
        ),
        returnsNormally,
        reason: '[P9.15] playOut alone is a valid config',
      );
      expect(
        () => newGame(
          GameConfig(
            seats: const <int>[0, 2],
            rules: const RulesConfig(yardRelease: true, playOut: true),
            seed: 1,
          ),
        ),
        throwsArgumentError,
        reason: '[P9.15] yardRelease without rollQueue is malformed',
      );
    });
  });

  group('P10: with yardRelease on as well (ENGINE_API 11 and 12)', () {
    GameState nine({
      List<int> retired = const <int>[],
      int currentSeat = 0,
      Map<int, List<int>> tokens = const <int, List<int>>{},
      bool blocks = true,
    }) =>
        _state(
          seats: fourPlayerSeats,
          tokens: tokens,
          currentSeat: currentSeat,
          yardRelease: true,
          drought: const <int>[9, 0, 0, 0],
          blocks: blocks,
          retired: retired,
        );

    test(
        'P10.1 the acting seat holds a release and is retired: the '
        'release is gone, the next seat begins, the roll cycle is normal', () {
      final s = nine();
      var a = _apply('P10.1 tenth', s, const RollIntention(0, 3));
      _expectEvents('P10.1 tenth', a, <String>[
        'Rolled(0,3)',
        'YardReleased(0)',
      ]);
      expect(
        a.state.releaseOwed,
        isTrue,
        reason: '[P10.1] fixture: a release must be owed',
      );
      final rolled = a.events.whereType<Rolled>().single;
      expect(
          rolled.legal,
          const <int>[
            0,
            1,
            2,
            3,
          ],
          reason: '[P10.1] Rolled.legal of the releasing roll');

      a = _apply('P10.1 retire', a.state, const RetireIntention(0));
      _expectEvents('P10.1 retire', a, <String>[
        'SeatRetired(0)',
        'TurnBegan(1)',
      ]);
      _expectState(
        'P10.1',
        a.state,
        currentSeat: 1,
        phase: GamePhase.awaitRoll,
        winner: null,
        queue: const <int>[],
        sixes: 0,
        retired: const <int>[0],
        releaseOwed: false,
        rollNull: true,
      );
      expect(
        legalTokens(a.state),
        isEmpty,
        reason: '[P10.1] a release is still being offered',
      );
      expect(defaultFace(a.state), isNull, reason: '[P10.1] defaultFace');
      _expectRejected(
        'P10.1 old release spent',
        a.state,
        const MoveIntention(0, 0),
        EngineError.notYourTurn,
      );

      final next = _apply('P10.1 next', a.state, const RollIntention(1, 3));
      _expectEvents('P10.1 next', next, <String>[
        'Rolled(1,3)',
        'TurnEnded(1,noLegalMove)',
        'TurnBegan(2)',
      ]);
      expect(next.state.releaseOwed, isFalse, reason: '[P10.1] flag leaked');
    });

    test(
        'P10.2 another seat is retired while the acting seat holds a '
        'release: the release stays and can still be spent', () {
      var a = _apply('P10.2 tenth', nine(), const RollIntention(0, 3));
      a = _apply('P10.2 retire', a.state, const RetireIntention(2));
      _expectEvents('P10.2 retire', a, <String>['SeatRetired(2)']);
      _expectState(
        'P10.2',
        a.state,
        currentSeat: 0,
        phase: GamePhase.awaitMove,
        winner: null,
        queue: const <int>[3],
        retired: const <int>[2],
        releaseOwed: true,
      );
      expect(
          legalTokens(a.state),
          const <int>[
            0,
            1,
            2,
            3,
          ],
          reason: '[P10.2] releasable tokens after another seat retired');
      final spent = _apply('P10.2 spend', a.state, const MoveIntention(0, 1));
      _expectEvents('P10.2 spend', spent, <String>['Moved(0,1,-1,0)']);
      expect(spent.state.releaseOwed, isFalse, reason: '[P10.2] release');
    });

    test(
        'P10.3 rule 14r with a retired seat in between: the lapse passes '
        'the turn to the next playing seat, skipping the retired one', () {
      // Seat 2 holds a pair on seat 0's entry square (absolute 0 is seat
      // 2's progress 26), so no token of seat 0 can be released. Seat 1
      // is retired, so the turn goes to 2.
      final s = nine(
        retired: const <int>[1],
        tokens: const {
          2: <int>[26, 26, -1, -1],
        },
      );
      final a = _apply('P10.3', s, const RollIntention(0, 3));
      _expectEvents('P10.3', a, <String>[
        'Rolled(0,3)',
        'YardReleased(0)',
        'TurnEnded(0,noLegalMove)',
        'TurnBegan(2)',
      ]);
      _expectState(
        'P10.3',
        a.state,
        currentSeat: 2,
        phase: GamePhase.awaitRoll,
        winner: null,
        queue: const <int>[],
        sixes: 0,
        releaseOwed: false,
      );
      expect(a.state.drought[0], 0, reason: '[P10.3] drought restarts');
    });

    test(
        'P10.4 spending the release and then the drawn face: a retire '
        'between the two discards the face as well', () {
      var a = _apply('P10.4 tenth', nine(), const RollIntention(0, 3));
      a = _apply('P10.4 spend', a.state, const MoveIntention(0, 0));
      _expectEvents('P10.4 spend', a, <String>['Moved(0,0,-1,0)']);
      expect(a.state.queue, const <int>[3], reason: '[P10.4] queue');
      expect(a.state.phase, GamePhase.awaitMove, reason: '[P10.4] phase');
      final r = _apply('P10.4 retire', a.state, const RetireIntention(0));
      _expectEvents('P10.4 retire', r, <String>[
        'SeatRetired(0)',
        'TurnBegan(1)',
      ]);
      expect(r.state.queue, isEmpty, reason: '[P10.4] queue not discarded');
      expect(
        r.state.tokens[0],
        _yardRow,
        reason: '[P10.4] the released token returned to the yard',
      );
    });
  });

  group('S: determinism and the soak', () {
    test(
        'S1 the same intention list, including a retirement, gives the '
        'same hash and bytes twice', () {
      final start = _state(
        seats: fourPlayerSeats,
        tokens: const {
          0: <int>[57, 57, 57, 52],
          1: <int>[10, 40, -1, -1],
          2: <int>[20, 45, -1, -1],
          3: <int>[30, -1, -1, -1],
        },
        currentSeat: 0,
        homeBonus: true,
      );
      const list = <Intention>[
        RollIntention(0, 5),
        MoveIntention(0, 3, face: 5),
        RollIntention(1, 4),
        MoveIntention(1, 1, face: 4),
        RetireIntention(3),
        RollIntention(2, 2),
        MoveIntention(2, 1, face: 2),
        RollIntention(1, 6),
        RollIntention(1, 3),
        RetireIntention(2),
      ];
      GameState run() {
        var s = start;
        for (final i in list) {
          s = _apply('S1 ${_iSig(i)}', s, i).state;
        }
        return s;
      }

      final a = run();
      final b = run();
      expect(stateHash(a), stateHash(b), reason: '[S1] hash');
      expect(_dump(a), _dump(b), reason: '[S1] bytes');
      expect(a, b, reason: '[S1] equality');
      expect(isTerminal(a), isTrue, reason: '[S1] final state: ${_dump(a)}');
    });

    test(
        'S2 soak, playOut on, yardRelease off, seeds 0..299: every '
        'documented invariant after every step', () {
      final tally = _Tally();
      for (var seed = 0; seed < 300; seed++) {
        _soak(seed, yard: false, tally: tally);
      }
      expect(
        tally.finishedEvents > 0,
        isTrue,
        reason: '[S2] no seat ever finished in 300 games: ${tally.games}',
      );
      expect(tally.retiredEvents > 0, isTrue, reason: '[S2] no retirement');
      expect(
        tally.retireActing > 0,
        isTrue,
        reason: '[S2] no acting seat was ever retired',
      );
      expect(
        tally.games > 100,
        isTrue,
        reason: '[S2] only ${tally.games} games ended',
      );
    });

    test('S3 soak, playOut on, yardRelease on, seeds 0..299', () {
      final tally = _Tally();
      for (var seed = 0; seed < 300; seed++) {
        _soak(seed, yard: true, tally: tally);
      }
      expect(tally.retiredEvents > 0, isTrue, reason: '[S3] no retirement');
      expect(
        tally.games > 100,
        isTrue,
        reason: '[S3] only ${tally.games} games ended',
      );
    });
  });
}
