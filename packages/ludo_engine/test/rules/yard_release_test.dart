// docs/RULES.md section 3.2b (rules 9r to 15r) and docs/ENGINE_API.md
// section 11: the yard release. A seat whose four tokens are all in the yard
// and who rolls ten non-6 in a row brings one token out, as if it had rolled
// an exceptional 6, and keeps the face it drew.
//
// Written from the two documents only. Where the engine is exercised it is
// through package:ludo_engine/ludo_engine.dart alone. Every state is reached
// one of two ways, and each case says which:
//
//   play      newGame, then intentions applied one by one;
//   hand      GameState.fromJson of a hand-written map. Section 11.2 lists
//             every rejection fromJson owes, and a state outside that list is
//             a state the document accepts.
//
// The fixtures in test/support cannot spell yardRelease, drought or
// releaseOwed, so this file carries its own JSON builder, in the key order
// section 8, 10.2 and 11.2 fix.
//
// Every failure message carries the scenario name and the intentions applied
// so far, which is everything needed to replay it. The random games at the
// bottom carry their seed in the test name and in every message.

import 'dart:convert';
import 'dart:io';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/splitmix64.dart';

// ---------------------------------------------------------------------------
// Event and intention rendering, so sequences compare as plain strings.
// ---------------------------------------------------------------------------

String _event(GameEvent e) => switch (e) {
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
    };

List<String> _events(List<GameEvent> events) =>
    events.map(_event).toList(growable: false);

String _rolled(int seat, int value, List<int> legal) =>
    'Rolled($seat,$value,$legal)';

String _intention(Intention i) => switch (i) {
      RollIntention() => 'roll(seat ${i.seat}, face ${i.face})',
      MoveIntention() =>
        'move(seat ${i.seat}, token ${i.token}, face ${i.face})',
      RetireIntention() => 'retire(seat ${i.seat})',
    };

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const List<int> _two = <int>[0, 2];
const List<int> _yardRow = <int>[-1, -1, -1, -1];

/// A hand-written state as the section 8, 10.2 and 11.2 JSON map, keys in
/// the documented order. The rejection cases edit a copy of it.
Map<String, Object?> _handJson({
  List<int> seats = _two,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  List<int> queue = const <int>[],
  int sixes = 0,
  List<int> drought = const <int>[0, 0, 0, 0],
  bool releaseOwed = false,
  bool blocks = true,
  bool homeBonus = false,
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
      },
      'seed': seed,
    },
    'tokens': List<List<int>>.generate(
      4,
      (seat) => List<int>.of(tokens[seat] ?? _yardRow),
    ),
    'currentSeat': currentSeat,
    'phase': phase,
    'roll': null,
    'queue': queue,
    'sixes': sixes,
    'drought': drought,
    'releaseOwed': releaseOwed,
    'winner': winner,
    'seq': seq,
    'rngState': rngState,
  };
}

GameState _hand({
  List<int> seats = _two,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int currentSeat = 0,
  String phase = 'awaitRoll',
  List<int> queue = const <int>[],
  int sixes = 0,
  List<int> drought = const <int>[0, 0, 0, 0],
  bool releaseOwed = false,
  bool blocks = true,
  bool homeBonus = false,
}) {
  return GameState.fromJson(
    _handJson(
      seats: seats,
      tokens: tokens,
      currentSeat: currentSeat,
      phase: phase,
      queue: queue,
      sixes: sixes,
      drought: drought,
      releaseOwed: releaseOwed,
      blocks: blocks,
      homeBonus: homeBonus,
    ),
  );
}

GameConfig _config({
  List<int> seats = _two,
  bool blocks = true,
  bool homeBonus = false,
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
    ),
    seed: seed,
  );
}

/// A deep, mutable copy of a JSON map.
Map<String, Object?> _copy(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

Map<String, Object?> _rulesOf(Map<String, Object?> json) =>
    (json['config']! as Map<String, Object?>)['rules']! as Map<String, Object?>;

/// Applies intentions and remembers them, so that every assertion can say
/// which scenario and which intentions led to it.
class _Run {
  _Run(this.name, this.state);

  final String name;
  GameState state;
  List<GameEvent> last = const <GameEvent>[];
  final List<String> log = <String>[];

  String get trace => 'scenario "$name", intentions so far: '
      '${log.isEmpty ? '(none)' : log.join('; ')}';

  /// Applies [intention] and returns the rendered events. A rejection of an
  /// intention the scenario expects to be legal fails here, with the trace.
  List<String> play(Intention intention) {
    final result = apply(state, intention);
    log.add(_intention(intention));
    switch (result) {
      case Applied(state: final next, events: final events):
        state = next;
        last = events;
        return _events(events);
      case Rejected(error: final error):
        fail(
          'expected ${_intention(intention)} to be accepted, got '
          'Rejected(${error.name}). $trace',
        );
    }
  }

  List<String> roll(int seat, int face) => play(RollIntention(seat, face));

  List<String> move(int seat, int token, {int? face}) =>
      play(MoveIntention(seat, token, face: face));

  /// The error [intention] is refused with; the run's state is untouched.
  EngineError? refused(Intention intention) {
    final result = apply(state, intention);
    return result is Rejected ? result.error : null;
  }
}

/// Face drawn for the i-th non-6 roll of a scenario, 1..5.
int _face(int i) => (i % 5) + 1;

void _expectDrought(_Run run, List<int> want, String when) {
  expect(
    run.state.drought,
    equals(want),
    reason: 'expected drought $want $when; got ${run.state.drought}. '
        '${run.trace}',
  );
}

void _expectNoRelease(_Run run, List<String> events, String when) {
  expect(
    events.any((e) => e.startsWith('YardReleased')),
    isFalse,
    reason: 'expected no YardReleased $when; events were $events. '
        '${run.trace}',
  );
}

/// Two seats, both stuck in the yard from the start of play: [rounds] full
/// rounds (seat 0 then seat 2) of non-6 faces. Returns nothing; asserts the
/// pass and the count after each roll.
void _stuckRounds(_Run run, int rounds, {int firstRound = 1}) {
  for (var r = firstRound; r < firstRound + rounds; r++) {
    final f0 = _face(r);
    final e0 = run.roll(0, f0);
    expect(
      e0,
      equals(_passEvents(0, f0, 2)),
      reason: 'round $r, seat 0 rolled $f0 with all four in the yard: '
          'expected the turn to pass; got $e0. ${run.trace}',
    );
    _expectDrought(run, <int>[r, 0, r - 1, 0], 'after seat 0 roll $r');
    final f2 = _face(r + 2);
    final e2 = run.roll(2, f2);
    expect(
      e2,
      equals(_passEvents(2, f2, 0)),
      reason: 'round $r, seat 2 rolled $f2 with all four in the yard: '
          'expected the turn to pass; got $e2. ${run.trace}',
    );
    _expectDrought(run, <int>[r, 0, r, 0], 'after seat 2 roll $r');
  }
}

List<String> _passEvents(int seat, int face, int next) => <String>[
      _rolled(seat, face, const <int>[]),
      'TurnEnded($seat,noLegalMove)',
      'TurnBegan($next)',
    ];

// ---------------------------------------------------------------------------
// Corpus access for the "off means identical bytes" proof.
// ---------------------------------------------------------------------------

const String _corpusPath = 'test/golden/corpus.jsonl';

List<Map<String, Object?>> _corpusRecords() {
  final file = File(_corpusPath);
  if (!file.existsSync()) {
    fail('golden corpus not found at $_corpusPath (cwd ${Directory.current})');
  }
  final records = <Map<String, Object?>>[];
  for (final line in file.readAsLinesSync()) {
    if (line.trim().isEmpty) {
      continue;
    }
    records.add(jsonDecode(line) as Map<String, Object?>);
  }
  if (records.isEmpty) {
    fail('golden corpus at $_corpusPath has no records');
  }
  return records;
}

/// FNV-1a 64 over UTF-8, hand-copied from docs/ENGINE_API.md section 8, so
/// the proof does not lean on the engine's own `stateHash`.
String _fnv(String text) {
  var h = 0xCBF29CE484222325;
  for (final b in utf8.encode(text)) {
    h = h ^ b;
    h = h * 0x00000100000001B3;
  }
  final high = (h >>> 32).toRadixString(16).padLeft(8, '0');
  final low = (h & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '$high$low';
}

// ---------------------------------------------------------------------------
// The cases.
// ---------------------------------------------------------------------------

void main() {
  group('Y1 (play): nine non-6 rolls in the yard never release', () {
    test(
      'two stuck seats, nine rounds: drought counts 1..9, the turn passes '
      'each time, no YardReleased',
      () {
        final run = _Run('Y1 two stuck seats, 9 rounds', newGame(_config()));
        expect(run.state.drought, equals(<int>[0, 0, 0, 0]));
        expect(run.state.releaseOwed, isFalse);
        _stuckRounds(run, 9);
        expect(run.state.currentSeat, 0);
        expect(run.state.phase, GamePhase.awaitRoll);
        expect(run.state.releaseOwed, isFalse);
        expect(run.state.queue, isEmpty);
        expect(run.state.seq, 18);
      },
    );
  });

  group('Y2 (play): the tenth non-6 releases, and keeps its face', () {
    for (var face = 1; face <= 5; face++) {
      test('tenth roll is a $face', () {
        final run = _Run('Y2 tenth roll $face', newGame(_config()));
        _stuckRounds(run, 9);
        final seqBefore = run.state.seq;

        final events = run.roll(0, face);
        expect(
          events,
          equals(<String>[
            _rolled(0, face, const <int>[0, 1, 2, 3]),
            'YardReleased(0)',
          ]),
          reason: 'expected Rolled then YardReleased and nothing else; '
              'got $events. ${run.trace}',
        );
        final s = run.state;
        expect(s.releaseOwed, isTrue, reason: run.trace);
        expect(s.phase, GamePhase.awaitMove, reason: run.trace);
        expect(s.currentSeat, 0, reason: run.trace);
        expect(s.queue, equals(<int>[face]),
            reason: 'the drawn face stays queued and no 6 is added '
                '(rule 12r, 15r). ${run.trace}');
        expect(s.sixes, 0, reason: run.trace);
        expect(s.roll, isNull, reason: run.trace);
        expect(s.drought[0], 0,
            reason: 'drought returns to 0 on the release (rule 11r). '
                '${run.trace}');
        expect(s.drought[2], 9,
            reason: 'the other seat keeps its own count. ${run.trace}');
        expect(s.seq, seqBefore + 1, reason: run.trace);
        expect(legalTokens(s), equals(<int>[0, 1, 2, 3]), reason: run.trace);
        expect(legalByFace(s), isEmpty,
            reason: 'while a release is owed legalByFace is empty (11.4). '
                '${run.trace}');
        expect(defaultFace(s), isNull,
            reason: 'while a release is owed defaultFace is null (11.4). '
                '${run.trace}');
        expect(s.tokens[0], equals(_yardRow),
            reason: 'nothing has moved yet. ${run.trace}');
      });
    }
  });

  group('Y3 (play): spending the release, then the kept face', () {
    for (final styleName in <String>['face omitted', 'face given']) {
      test('release on token 2, then the face spent ($styleName)', () {
        final run = _Run('Y3 $styleName', newGame(_config()));
        _stuckRounds(run, 9);
        run.roll(0, 4);

        final moved = run.move(0, 2);
        expect(
          moved,
          equals(<String>['Moved(0,2,-1->0)']),
          reason: 'the release is one Moved and nothing else: no ExtraRoll, '
              'no TurnBegan, no capture. got $moved. ${run.trace}',
        );
        var s = run.state;
        expect(s.tokens[0], equals(<int>[-1, -1, 0, -1]), reason: run.trace);
        expect(s.releaseOwed, isFalse, reason: run.trace);
        expect(s.phase, GamePhase.awaitMove, reason: run.trace);
        expect(s.currentSeat, 0, reason: run.trace);
        expect(s.queue, equals(<int>[4]), reason: run.trace);
        expect(s.sixes, 0, reason: run.trace);
        expect(
            legalByFace(s),
            equals(<int, List<int>>{
              4: <int>[2],
            }),
            reason: 'the kept face moves only the released token. '
                '${run.trace}');
        expect(defaultFace(s), 4, reason: run.trace);
        expect(legalTokens(s), equals(<int>[2]), reason: run.trace);

        final spent = styleName == 'face given'
            ? run.move(0, 2, face: 4)
            : run.move(0, 2);
        expect(
          spent,
          equals(<String>['Moved(0,2,0->4)', 'TurnBegan(2)']),
          reason: 'the kept face is spent normally and the turn then passes. '
              'got $spent. ${run.trace}',
        );
        s = run.state;
        expect(s.tokens[0], equals(<int>[-1, -1, 4, -1]), reason: run.trace);
        expect(s.currentSeat, 2, reason: run.trace);
        expect(s.phase, GamePhase.awaitRoll, reason: run.trace);
        expect(s.queue, isEmpty, reason: run.trace);
        expect(s.sixes, 0, reason: run.trace);
        expect(s.releaseOwed, isFalse, reason: run.trace);
        expect(s.drought[2], 9,
            reason: 'a seat change never touches another seat\'s drought. '
                '${run.trace}');
      });
    }

    test(
      'hand: a kept face with no legal move (opponent block ahead of the '
      'entry square) lapses after the release: TurnEnded(noLegalMove)',
      () {
        // Seat 2 holds a block on absolute square 2: progress 28 is
        // (26 + 28) % 52 = 2. Seat 0's entry square, 0, is clear, so the
        // release is legal; the kept 3 would cross the block.
        final run = _Run(
          'Y3b hand, block on square 2, drought [9,0,0,0], face 3',
          _hand(
            tokens: const <int, List<int>>{
              2: <int>[28, 28, -1, -1],
            },
            drought: const <int>[9, 0, 0, 0],
          ),
        );
        final rolled = run.roll(0, 3);
        expect(
            rolled,
            equals(<String>[
              _rolled(0, 3, const <int>[0, 1, 2, 3]),
              'YardReleased(0)'
            ]),
            reason: run.trace);
        final moved = run.move(0, 0);
        expect(
          moved,
          equals(<String>[
            'Moved(0,0,-1->0)',
            'TurnEnded(0,noLegalMove)',
            'TurnBegan(2)',
          ]),
          reason: 'rule 13r: no queued face has a legal move, so rule 13q '
              'passes the turn. got $moved. ${run.trace}',
        );
        final s = run.state;
        expect(s.tokens[0], equals(<int>[0, -1, -1, -1]), reason: run.trace);
        expect(s.queue, isEmpty, reason: run.trace);
        expect(s.currentSeat, 2, reason: run.trace);
        expect(s.phase, GamePhase.awaitRoll, reason: run.trace);
        expect(s.sixes, 0, reason: run.trace);
        expect(s.releaseOwed, isFalse, reason: run.trace);
      },
    );
  });

  group('Y4: refusals while a release is owed', () {
    GameState owed() {
      final run = _Run('Y4 owed', newGame(_config()));
      _stuckRounds(run, 9);
      run.roll(0, 4);
      return run.state;
    }

    test(
        'play: a face given is illegalMove, for the queued face, a 6, and '
        'values outside 1..6', () {
      final run = _Run('Y4 owed, faces', owed());
      for (final face in <int>[4, 6, 1, 0, 7, -1]) {
        expect(
          run.refused(MoveIntention(0, 1, face: face)),
          EngineError.illegalMove,
          reason: 'expected illegalMove for move(token 1, face $face) while '
              'a release is owed (11.4). Scenario Y4: nine stuck rounds, '
              'then seat 0 rolls 4.',
        );
      }
    });

    test(
        'play: a token that does not exist is noSuchToken, the phase and '
        'seat checks still come first', () {
      final run = _Run('Y4 owed, ladder', owed());
      expect(run.refused(const MoveIntention(0, 4)), EngineError.noSuchToken,
          reason: 'Scenario Y4 owed, token 4');
      expect(run.refused(const MoveIntention(0, -1)), EngineError.noSuchToken,
          reason: 'Scenario Y4 owed, token -1');
      expect(run.refused(const RollIntention(0, 3)), EngineError.wrongPhase,
          reason: 'a roll while a release is owed. Scenario Y4 owed');
      expect(run.refused(const MoveIntention(2, 0)), EngineError.notYourTurn,
          reason: 'the other seat moving. Scenario Y4 owed');
      expect(run.refused(const MoveIntention(1, 0)), EngineError.seatNotInPlay,
          reason: 'a seat not in the game. Scenario Y4 owed');
    });

    test('hand: a token that is not in the yard is not releasable', () {
      // Section 11.2 does not forbid releaseOwed with a token on the track,
      // so this state is one fromJson must accept; 11.4 makes only the
      // releasable tokens (those in the yard) legal.
      final run = _Run(
        'Y4 hand, releaseOwed with token 0 at progress 10',
        _hand(
          tokens: const <int, List<int>>{
            0: <int>[10, -1, -1, -1],
          },
          phase: 'awaitMove',
          queue: const <int>[3],
          releaseOwed: true,
        ),
      );
      expect(legalTokens(run.state), equals(<int>[1, 2, 3]),
          reason: 'only yard tokens are releasable. ${run.trace}');
      expect(run.refused(const MoveIntention(0, 0)), EngineError.illegalMove,
          reason: 'token 0 is on the track, not releasable. ${run.trace}');
      expect(run.refused(const MoveIntention(0, 0, face: 3)),
          EngineError.illegalMove,
          reason: 'a face is refused while a release is owed. ${run.trace}');
      expect(run.move(0, 1), equals(<String>['Moved(0,1,-1->0)']),
          reason: run.trace);
    });

    test('play: the same refusals do not change the state', () {
      final s = owed();
      final before = stateHash(s);
      final json = jsonEncode(s.toJson());
      expect(apply(s, const MoveIntention(0, 1, face: 4)), isA<Rejected>());
      expect(apply(s, const MoveIntention(0, 9)), isA<Rejected>());
      expect(stateHash(s), before);
      expect(jsonEncode(s.toJson()), json);
    });
  });

  group('Y5: a 6 anywhere in the run resets the count', () {
    test(
      'play: nine non-6, a 6 (token out), captured back to the yard, then '
      'ten more non-6 are needed',
      () {
        // Seat 2 owns one token the whole game, so it never counts. It is
        // walked from progress 17 by nine single steps to progress 26
        // (absolute square 0), one per round, and later captures seat 0's
        // token on absolute square 2 with a 2.
        final run = _Run(
          'Y5 play: 9 non-6, a 6, capture, then count to 10',
          _hand(
            tokens: const <int, List<int>>{
              2: <int>[17, -1, -1, -1],
            },
          ),
        );
        for (var i = 1; i <= 9; i++) {
          final f = _face(i);
          final e0 = run.roll(0, f);
          expect(e0, equals(_passEvents(0, f, 2)),
              reason: 'round $i: seat 0 rolled $f with every token in the '
                  'yard. ${run.trace}');
          _expectDrought(run, <int>[i, 0, 0, 0], 'after seat 0 roll $i');
          expect(
              run.roll(2, 1),
              equals(<String>[
                _rolled(2, 1, const <int>[0]),
              ]),
              reason: run.trace);
          expect(
              run.move(2, 0),
              equals(<String>[
                'Moved(2,0,${16 + i}->${17 + i})',
                'TurnBegan(0)',
              ]),
              reason: run.trace);
        }
        _expectDrought(run, <int>[9, 0, 0, 0], 'after nine non-6 rolls');
        expect(run.state.tokens[2][0], 26, reason: run.trace);

        // The 6: the drought is cleared and the seat rolls again at once.
        final sixEvents = run.roll(0, 6);
        expect(
            sixEvents,
            equals(<String>[
              _rolled(0, 6, const <int>[]),
              'ExtraRoll(0)',
            ]),
            reason: run.trace);
        expect(run.state.drought[0], 0,
            reason: 'a 6 sets the drought to 0 (rule 10r). ${run.trace}');
        expect(
            run.roll(0, 2),
            equals(<String>[
              _rolled(0, 2, const <int>[0, 1, 2, 3]),
            ]),
            reason: run.trace);
        expect(run.state.queue, equals(<int>[6, 2]), reason: run.trace);
        expect(run.state.releaseOwed, isFalse,
            reason: 'a real 6 is on the queue, nothing is owed. '
                '${run.trace}');
        expect(run.move(0, 0, face: 6), equals(<String>['Moved(0,0,-1->0)']),
            reason: run.trace);
        expect(run.move(0, 0, face: 2),
            equals(<String>['Moved(0,0,0->2)', 'TurnBegan(2)']),
            reason: run.trace);
        _expectDrought(run, <int>[0, 0, 0, 0],
            'once seat 0 has a token on the track (rule 9r)');

        // Seat 2 captures it: progress 26 + 2 = 28 is absolute square 2.
        expect(
            run.roll(2, 2),
            equals(<String>[
              _rolled(2, 2, const <int>[0]),
            ]),
            reason: run.trace);
        expect(
            run.move(2, 0),
            equals(<String>[
              'Moved(2,0,26->28)',
              'Captured(0,0 by 2,0)',
              'ExtraRoll(2)',
            ]),
            reason: run.trace);
        expect(run.state.tokens[0], equals(_yardRow), reason: run.trace);
        _expectDrought(run, <int>[0, 0, 0, 0],
            'after the capture (11.4: counting starts with the next roll)');
        expect(
            run.roll(2, 1),
            equals(<String>[
              _rolled(2, 1, const <int>[0]),
            ]),
            reason: run.trace);
        expect(
            run.move(2, 0),
            equals(<String>[
              'Moved(2,0,28->29)',
              'TurnBegan(0)',
            ]),
            reason: run.trace);

        // Ten more are needed: nine do nothing, the tenth releases.
        for (var i = 1; i <= 9; i++) {
          final f = _face(i + 3);
          final events = run.roll(0, f);
          _expectNoRelease(run, events, 'on non-6 roll $i after the capture');
          expect(events, equals(_passEvents(0, f, 2)),
              reason: 'non-6 roll $i after the capture should pass the turn. '
                  '${run.trace}');
          _expectDrought(
              run, <int>[i, 0, 0, 0], 'after non-6 roll $i since the capture');
          run.roll(2, 1);
          run.move(2, 0);
        }
        final tenth = run.roll(0, 5);
        expect(
            tenth,
            equals(<String>[
              _rolled(0, 5, const <int>[0, 1, 2, 3]),
              'YardReleased(0)',
            ]),
            reason: 'the tenth non-6 roll since the capture must release. '
                '${run.trace}');
      },
    );

    test(
      'hand: a token on the track captured back to the yard leaves the '
      'drought at 0; ten more non-6 are needed',
      () {
        // Seat 0 token 0 on square 2 (progress 2), seat 2 token on square 0
        // (progress 26) about to capture it with a 2. Seat 2 never counts.
        final run = _Run(
          'Y5b hand: capture of the last token, then count to 10',
          _hand(
            tokens: const <int, List<int>>{
              0: <int>[2, -1, -1, -1],
              2: <int>[26, -1, -1, -1],
            },
            currentSeat: 2,
          ),
        );
        run.roll(2, 2);
        expect(
            run.move(2, 0),
            equals(<String>[
              'Moved(2,0,26->28)',
              'Captured(0,0 by 2,0)',
              'ExtraRoll(2)',
            ]),
            reason: run.trace);
        run.roll(2, 1);
        run.move(2, 0);
        _expectDrought(run, <int>[0, 0, 0, 0], 'after the capture');
        for (var i = 1; i <= 9; i++) {
          final events = run.roll(0, _face(i));
          _expectNoRelease(run, events, 'on non-6 roll $i after the capture');
          _expectDrought(run, <int>[i, 0, 0, 0], 'after non-6 roll $i');
          run.roll(2, 1);
          run.move(2, 0);
        }
        expect(run.roll(0, 3), contains('YardReleased(0)'),
            reason: 'the tenth non-6 after the capture releases. '
                '${run.trace}');
      },
    );

    test('hand: a 6 at drought 9 is not a release, it clears the count', () {
      final run = _Run(
        'Y5c hand: drought 9 then a 6',
        _hand(drought: const <int>[9, 0, 0, 0]),
      );
      final events = run.roll(0, 6);
      expect(
          events,
          equals(<String>[
            _rolled(0, 6, const <int>[]),
            'ExtraRoll(0)',
          ]),
          reason: run.trace);
      expect(run.state.drought[0], 0, reason: run.trace);
      expect(run.state.releaseOwed, isFalse, reason: run.trace);
      expect(run.state.queue, equals(<int>[6]), reason: run.trace);
      expect(run.state.sixes, 1, reason: run.trace);
    });

    test(
      'hand: a non-6 at drought 9 by a seat that has a token on the track '
      'clears the count instead of releasing',
      () {
        final run = _Run(
          'Y5d hand: drought 9, token 0 on the track, face 3',
          _hand(
            tokens: const <int, List<int>>{
              0: <int>[10, -1, -1, -1],
            },
            drought: const <int>[9, 0, 0, 0],
          ),
        );
        final events = run.roll(0, 3);
        _expectNoRelease(run, events, 'for a seat with a token on the track');
        expect(
            events,
            equals(<String>[
              _rolled(0, 3, const <int>[0])
            ]),
            reason: run.trace);
        expect(run.state.drought[0], 0, reason: run.trace);
        expect(run.state.releaseOwed, isFalse, reason: run.trace);
      },
    );
  });

  group('Y6: a seat with a token not in the yard never counts', () {
    for (final progress in <int>[57, 56]) {
      test(
        'hand: one token at progress $progress, three in the yard: twenty '
        'rounds of non-6, no drought, no release',
        () {
          // Faces 2..5 cannot move a token at 56 or 57, so the turn passes
          // on every roll for both seats.
          final run = _Run(
            'Y6 hand: [$progress,-1,-1,-1] for both seats, 20 rounds',
            _hand(
              tokens: <int, List<int>>{
                0: <int>[progress, -1, -1, -1],
                2: <int>[progress, -1, -1, -1],
              },
            ),
          );
          for (var r = 1; r <= 20; r++) {
            final f0 = (r % 4) + 2;
            final e0 = run.roll(0, f0);
            expect(e0, equals(_passEvents(0, f0, 2)),
                reason: 'round $r seat 0: expected a plain pass. '
                    '${run.trace}');
            _expectDrought(run, <int>[0, 0, 0, 0], 'after seat 0 roll $r');
            final f2 = ((r + 1) % 4) + 2;
            final e2 = run.roll(2, f2);
            expect(e2, equals(_passEvents(2, f2, 0)),
                reason: 'round $r seat 2: expected a plain pass. '
                    '${run.trace}');
            _expectDrought(run, <int>[0, 0, 0, 0], 'after seat 2 roll $r');
          }
          expect(run.state.releaseOwed, isFalse, reason: run.trace);
        },
      );
    }
  });

  group('Y7: counts carry across turns and belong to one seat', () {
    test(
      'play: both seats stuck from the start; seat 0 releases on its own '
      'tenth, seat 2 on its own tenth, neither count disturbs the other',
      () {
        final run = _Run('Y7 play, both stuck', newGame(_config()));
        _stuckRounds(run, 9);

        expect(
            run.roll(0, 3),
            equals(<String>[
              _rolled(0, 3, const <int>[0, 1, 2, 3]),
              'YardReleased(0)',
            ]),
            reason: run.trace);
        expect(run.move(0, 0), equals(<String>['Moved(0,0,-1->0)']),
            reason: run.trace);
        expect(
            run.move(0, 0),
            equals(<String>[
              'Moved(0,0,0->3)',
              'TurnBegan(2)',
            ]),
            reason: run.trace);
        _expectDrought(run, <int>[0, 0, 9, 0],
            'after seat 0 spent its release and its face');

        expect(
            run.roll(2, 5),
            equals(<String>[
              _rolled(2, 5, const <int>[0, 1, 2, 3]),
              'YardReleased(2)',
            ]),
            reason: 'seat 2 releases on its own tenth. ${run.trace}');
        _expectDrought(run, <int>[0, 0, 0, 0], 'after seat 2 released');
        expect(run.state.currentSeat, 2, reason: run.trace);
        expect(run.state.releaseOwed, isTrue, reason: run.trace);
        expect(run.move(2, 3), equals(<String>['Moved(2,3,-1->0)']),
            reason: run.trace);
        expect(
            run.move(2, 3),
            equals(<String>[
              'Moved(2,3,0->5)',
              'TurnBegan(0)',
            ]),
            reason: run.trace);
      },
    );

    test(
      'hand: offset counts [4,0,7,0]: seat 2 reaches ten first, seat 0 '
      'later on its own tenth',
      () {
        final run = _Run(
          'Y7b hand: drought [4,0,7,0]',
          _hand(drought: const <int>[4, 0, 7, 0]),
        );
        // seat 0 -> 5, seat 2 -> 8, seat 0 -> 6, seat 2 -> 9, seat 0 -> 7
        run.roll(0, 1);
        _expectDrought(run, <int>[5, 0, 7, 0], 'after seat 0 roll');
        run.roll(2, 2);
        _expectDrought(run, <int>[5, 0, 8, 0], 'after seat 2 roll');
        run.roll(0, 3);
        _expectDrought(run, <int>[6, 0, 8, 0], 'after seat 0 roll');
        run.roll(2, 4);
        _expectDrought(run, <int>[6, 0, 9, 0], 'after seat 2 roll');
        run.roll(0, 5);
        _expectDrought(run, <int>[7, 0, 9, 0], 'after seat 0 roll');

        // seat 2's tenth
        final tenth = run.roll(2, 2);
        expect(
            tenth,
            equals(<String>[
              _rolled(2, 2, const <int>[0, 1, 2, 3]),
              'YardReleased(2)',
            ]),
            reason: run.trace);
        _expectDrought(run, <int>[7, 0, 0, 0], 'after seat 2 released');
        run.move(2, 0);
        expect(
            run.move(2, 0),
            equals(<String>[
              'Moved(2,0,0->2)',
              'TurnBegan(0)',
            ]),
            reason: run.trace);

        // seat 0 continues from 7 and releases on the third roll more
        for (var expected = 8; expected <= 9; expected++) {
          final f = _face(expected);
          final events = run.roll(0, f);
          _expectNoRelease(run, events, 'at seat 0 count $expected');
          _expectDrought(
              run, <int>[expected, 0, 0, 0], 'after seat 0 reached $expected');
          // Seat 2 has a token on the track now: its roll moves it.
          run.roll(2, 1);
          run.move(2, 0);
          _expectDrought(run, <int>[expected, 0, 0, 0],
              'seat 2 rolling must not touch seat 0');
        }
        expect(
            run.roll(0, 4),
            equals(<String>[
              _rolled(0, 4, const <int>[0, 1, 2, 3]),
              'YardReleased(0)',
            ]),
            reason: 'seat 0 releases on its own tenth. ${run.trace}');
      },
    );
  });

  group('Y8 (hand): rule 14r, no token can be released', () {
    // Seat 2 holds two tokens on progress 26, which is absolute square 0:
    // a block on seat 0's entry square. Seat 0 is at drought 9.
    Map<int, List<int>> blocked() => const <int, List<int>>{
          2: <int>[26, 26, -1, -1],
        };

    test('the release lapses: YardReleased, TurnEnded, TurnBegan, drought 0',
        () {
      final run = _Run(
        'Y8 hand: block on the entry square, blocks on, drought [9,0,0,0]',
        _hand(tokens: blocked(), drought: const <int>[9, 0, 0, 0]),
      );
      final events = run.roll(0, 3);
      expect(
          events,
          equals(<String>[
            _rolled(0, 3, const <int>[]),
            'YardReleased(0)',
            'TurnEnded(0,noLegalMove)',
            'TurnBegan(2)',
          ]),
          reason: run.trace);
      final s = run.state;
      expect(s.drought[0], 0,
          reason: 'the drought starts again from 0 (rule 14r). ${run.trace}');
      expect(s.releaseOwed, isFalse, reason: run.trace);
      expect(s.currentSeat, 2, reason: run.trace);
      expect(s.phase, GamePhase.awaitRoll, reason: run.trace);
      expect(s.queue, isEmpty, reason: run.trace);
      expect(s.sixes, 0, reason: run.trace);
      expect(s.tokens[0], equals(_yardRow), reason: run.trace);
    });

    test('after the lapse the count starts again at 1', () {
      final run = _Run(
        'Y8b hand: lapse, then seat 0 rolls again',
        _hand(tokens: blocked(), drought: const <int>[9, 0, 0, 0]),
      );
      run.roll(0, 3);
      // Seat 2 breaks its own block by moving one token.
      run.roll(2, 1);
      run.move(2, 0);
      final events = run.roll(0, 4);
      _expectNoRelease(run, events, 'on the first roll after a lapse');
      _expectDrought(
          run,
          <int>[1, 0, 0, 0],
          'after the first roll since '
          'the lapse');
    });

    test('contrast: with blocks off the same position releases normally', () {
      final run = _Run(
        'Y8c hand: same position, blocks off',
        _hand(
          tokens: blocked(),
          drought: const <int>[9, 0, 0, 0],
          blocks: false,
        ),
      );
      final events = run.roll(0, 3);
      expect(
          events,
          equals(<String>[
            _rolled(0, 3, const <int>[0, 1, 2, 3]),
            'YardReleased(0)',
          ]),
          reason: run.trace);
      expect(run.state.releaseOwed, isTrue, reason: run.trace);
      expect(run.move(0, 0), equals(<String>['Moved(0,0,-1->0)']),
          reason: 'the entry square is safe, so nothing is captured. '
              '${run.trace}');
    });

    test('a single opponent token on the entry square does not block', () {
      final run = _Run(
        'Y8d hand: one opponent token on the entry square, blocks on',
        _hand(
          tokens: const <int, List<int>>{
            2: <int>[26, -1, -1, -1],
          },
          drought: const <int>[9, 0, 0, 0],
        ),
      );
      final events = run.roll(0, 2);
      expect(
          events,
          equals(<String>[
            _rolled(0, 2, const <int>[0, 1, 2, 3]),
            'YardReleased(0)',
          ]),
          reason: run.trace);
      expect(run.move(0, 3), equals(<String>['Moved(0,3,-1->0)']),
          reason: 'safe square: both tokens stand, nothing captured. '
              '${run.trace}');
      expect(run.state.tokens[2][0], 26, reason: run.trace);
    });
  });

  group('Y9: sixes and the release', () {
    test(
      'hand: three 6s void the turn and the drought stays 0, so ten more '
      'non-6 are needed afterwards',
      () {
        final run = _Run(
          'Y9 hand: drought 9, then 6 6 6',
          _hand(
            tokens: const <int, List<int>>{
              2: <int>[57, -1, -1, -1],
            },
            drought: const <int>[9, 0, 0, 0],
          ),
        );
        expect(
            run.roll(0, 6),
            equals(<String>[
              _rolled(0, 6, const <int>[]),
              'ExtraRoll(0)',
            ]),
            reason: run.trace);
        _expectDrought(run, <int>[0, 0, 0, 0], 'after the first 6');
        expect(
            run.roll(0, 6),
            equals(<String>[
              _rolled(0, 6, const <int>[]),
              'ExtraRoll(0)',
            ]),
            reason: run.trace);
        expect(run.state.sixes, 2, reason: run.trace);
        final third = run.roll(0, 6);
        expect(
            third,
            equals(<String>[
              _rolled(0, 6, const <int>[]),
              'TurnEnded(0,threeSixes)',
              'TurnBegan(2)',
            ]),
            reason: run.trace);
        final s = run.state;
        expect(s.queue, isEmpty, reason: run.trace);
        expect(s.sixes, 0, reason: run.trace);
        expect(s.releaseOwed, isFalse, reason: run.trace);
        _expectDrought(run, <int>[0, 0, 0, 0], 'after the voided turn');

        // Nine non-6 rolls for seat 0 do not release.
        for (var i = 1; i <= 9; i++) {
          run.roll(2, 3);
          final events = run.roll(0, _face(i));
          _expectNoRelease(run, events, 'on non-6 roll $i after the void');
          _expectDrought(run, <int>[i, 0, 0, 0], 'after non-6 roll $i');
        }
        run.roll(2, 3);
        expect(run.roll(0, 2), contains('YardReleased(0)'),
            reason: 'the tenth releases. ${run.trace}');
      },
    );

    test(
      'hand: the release is not a 6: sixes stays 0 through the release '
      'roll and the release move, and the queue never holds a 6',
      () {
        final run = _Run(
          'Y9b hand: drought 9, face 4, release then the face',
          _hand(
            tokens: const <int, List<int>>{
              2: <int>[57, -1, -1, -1],
            },
            drought: const <int>[9, 0, 0, 0],
          ),
        );
        run.roll(0, 4);
        expect(run.state.sixes, 0, reason: run.trace);
        expect(run.state.queue, equals(<int>[4]), reason: run.trace);
        final moved = run.move(0, 0);
        expect(moved.any((e) => e.startsWith('ExtraRoll')), isFalse,
            reason: 'a release grants no extra roll. got $moved. '
                '${run.trace}');
        expect(run.state.sixes, 0, reason: run.trace);
        expect(run.state.phase, GamePhase.awaitMove, reason: run.trace);
      },
    );

    test(
      'hand: after a release and a capture with the kept face, a 6 then a 6 '
      'is still two 6s, not three: the release did not count',
      () {
        // Seat 2's single token sits on square 4 (progress 30), not safe.
        // Seat 0 releases, spends the kept 4 on the released token and
        // captures; the capture owes a roll; 6, 6 and a non-6 follow.
        final run = _Run(
          'Y9c hand: release, capture with the kept face, then 6 6 3',
          _hand(
            tokens: const <int, List<int>>{
              2: <int>[30, -1, -1, -1],
            },
            drought: const <int>[9, 0, 0, 0],
          ),
        );
        run.roll(0, 4);
        run.move(0, 0);
        expect(
            run.move(0, 0),
            equals(<String>[
              'Moved(0,0,0->4)',
              'Captured(2,0 by 0,0)',
              'ExtraRoll(0)',
            ]),
            reason: run.trace);
        expect(
            run.roll(0, 6),
            equals(<String>[
              _rolled(0, 6, const <int>[]),
              'ExtraRoll(0)',
            ]),
            reason: run.trace);
        expect(
            run.roll(0, 6),
            equals(<String>[
              _rolled(0, 6, const <int>[]),
              'ExtraRoll(0)',
            ]),
            reason: 'two 6s after a release are two 6s. ${run.trace}');
        expect(run.state.sixes, 2, reason: run.trace);
      },
    );
  });

  group('Y10: serialisation', () {
    test(
      'off: every legacy and rollQueue corpus state is byte-identical to its '
      'pre-toggle form, at every step',
      () {
        var checked = 0;
        var rollQueueRecords = 0;
        for (final record in _corpusRecords()) {
          final rules = record['rules']! as Map<String, Object?>;
          if (rules['yardRelease'] == true) {
            continue; // corpus records for the toggle belong to later orders
          }
          final rollQueue = rules['rollQueue'] == true;
          if (rollQueue) {
            rollQueueRecords++;
          }
          final config = GameConfig(
            seats: (record['seats']! as List<Object?>).cast<int>(),
            rules: RulesConfig(
              blocks: rules['blocks']! as bool,
              captureBonus: rules['captureBonus']! as bool,
              rollQueue: rollQueue,
              homeBonus: rules['homeBonus'] == true,
            ),
            seed: record['seed']! as int,
          );
          final name = record['name']! as String;
          var state = newGame(config);
          final intentions = record['intentions']! as List<Object?>;
          for (var i = 0; i < intentions.length; i++) {
            final raw = intentions[i]! as Map<String, Object?>;
            final Intention intention = raw['t'] == 'roll'
                ? RollIntention(raw['seat']! as int, raw['face']! as int)
                : MoveIntention(
                    raw['seat']! as int,
                    raw['token']! as int,
                    face: raw['face'] as int?,
                  );
            final result = apply(state, intention);
            if (result is! Applied) {
              fail('corpus record "$name" intention $i ($raw) rejected: '
                  '$result');
            }
            state = result.state;
            final text = jsonEncode(state.toJson());
            for (final key in <String>[
              'yardRelease',
              'drought',
              'releaseOwed',
            ]) {
              expect(text.contains('"$key"'), isFalse,
                  reason: 'with yardRelease off the key "$key" must be '
                      'absent. record "$name", after intention $i. '
                      'text: $text');
            }
            expect(state.drought, equals(<int>[0, 0, 0, 0]),
                reason: 'record "$name", after intention $i');
            expect(state.releaseOwed, isFalse,
                reason: 'record "$name", after intention $i');
            checked++;
          }
          final finalText = jsonEncode(state.toJson());
          expect(_fnv(finalText), record['finalHash'],
              reason: 'record "$name": FNV-1a of the canonical text must '
                  'still equal the recorded finalHash. text: $finalText');
          expect(stateHash(state), record['finalHash'],
              reason: 'record "$name": stateHash drifted');
          expect(
            (state.toJson()).keys.toList(),
            equals(<String>[
              'config',
              'tokens',
              'currentSeat',
              'phase',
              'roll',
              if (rollQueue) 'queue',
              'sixes',
              'winner',
              'seq',
              'rngState',
            ]),
            reason: 'record "$name": key order',
          );
        }
        expect(rollQueueRecords, greaterThan(0),
            reason: 'the corpus must hold rollQueue records for this proof');
        expect(checked, greaterThan(0));
      },
    );

    test('on: exact text and key order of a new game', () {
      final state = newGame(_config(seed: 7));
      final tokens = '[[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1],'
          '[-1,-1,-1,-1]]';
      final expected = '{"config":{"seats":[0,2],"rules":{"blocks":true,'
          '"captureBonus":true,"rollQueue":true,"yardRelease":true},'
          '"seed":7},"tokens":$tokens,"currentSeat":0,'
          '"phase":"awaitRoll","roll":null,"queue":[],"sixes":0,'
          '"drought":[0,0,0,0],"releaseOwed":false,"winner":null,'
          '"seq":0,"rngState":7}';
      expect(jsonEncode(state.toJson()), expected,
          reason: 'canonical text of newGame with rollQueue and '
              'yardRelease, seed 7');
      expect(stateHash(state), _fnv(expected),
          reason: 'stateHash is FNV-1a over exactly that text');
    });

    test(
        'on: rules key order is blocks, captureBonus, rollQueue, homeBonus, '
        'yardRelease', () {
      final state = newGame(_config(homeBonus: true));
      final rules = _rulesOf(Map<String, Object?>.from(state.toJson()));
      expect(
        rules.keys.toList(),
        equals(<String>[
          'blocks',
          'captureBonus',
          'rollQueue',
          'homeBonus',
          'yardRelease',
        ]),
      );
      expect(rules['yardRelease'], isTrue);
      final keys = state.toJson().keys.toList();
      expect(
        keys,
        equals(<String>[
          'config',
          'tokens',
          'currentSeat',
          'phase',
          'roll',
          'queue',
          'sixes',
          'drought',
          'releaseOwed',
          'winner',
          'seq',
          'rngState',
        ]),
      );
    });

    test('on: drought and releaseOwed sit right after sixes, values kept', () {
      final state = _hand(
        phase: 'awaitMove',
        queue: const <int>[3],
        drought: const <int>[0, 0, 9, 0],
        releaseOwed: true,
        tokens: const <int, List<int>>{
          2: <int>[-1, -1, -1, -1],
        },
      );
      final json = state.toJson();
      expect(json['drought'], equals(<int>[0, 0, 9, 0]));
      expect(json['releaseOwed'], isTrue);
      final keys = json.keys.toList();
      expect(keys.indexOf('drought'), keys.indexOf('sixes') + 1);
      expect(keys.indexOf('releaseOwed'), keys.indexOf('drought') + 1);
      expect(keys.indexOf('winner'), keys.indexOf('releaseOwed') + 1);
    });

    test('on: round trip through toJson and fromJson, text and equality', () {
      final states = <String, GameState>{
        'new game': newGame(_config()),
        'drought [3,0,9,0]': _hand(drought: const <int>[3, 0, 9, 0]),
        'release owed': _hand(
          phase: 'awaitMove',
          queue: const <int>[5],
          releaseOwed: true,
          drought: const <int>[0, 0, 4, 0],
        ),
        'homeBonus too':
            _hand(homeBonus: true, drought: const <int>[1, 2, 3, 4]),
      };
      states.forEach((name, state) {
        final text = jsonEncode(state.toJson());
        final back = GameState.fromJson(
          jsonDecode(text) as Map<String, Object?>,
        );
        expect(back, equals(state), reason: 'round trip of "$name"');
        expect(jsonEncode(back.toJson()), text,
            reason: 'round trip text of "$name"');
        expect(stateHash(back), stateHash(state),
            reason: 'round trip hash of "$name"');
        expect(back.hashCode, state.hashCode);
      });
    });

    test(
        'on: states that differ only in drought or releaseOwed are not '
        'equal and hash differently', () {
      final a = _hand(drought: const <int>[3, 0, 0, 0]);
      final b = _hand(drought: const <int>[4, 0, 0, 0]);
      expect(a == b, isFalse);
      expect(stateHash(a), isNot(stateHash(b)));
      final c = _hand(
        phase: 'awaitMove',
        queue: const <int>[3],
        releaseOwed: true,
      );
      final d = _hand(phase: 'awaitMove', queue: const <int>[3]);
      expect(c == d, isFalse);
      expect(stateHash(c), isNot(stateHash(d)));
    });

    test('RulesConfig: yardRelease defaults off and takes part in equality',
        () {
      expect(const RulesConfig().yardRelease, isFalse);
      expect(
        const RulesConfig(rollQueue: true, yardRelease: true),
        isNot(const RulesConfig(rollQueue: true)),
      );
      expect(
        const RulesConfig(rollQueue: true, yardRelease: true),
        equals(const RulesConfig(rollQueue: true, yardRelease: true)),
      );
      expect(
        const RulesConfig(rollQueue: true, yardRelease: true).hashCode,
        const RulesConfig(rollQueue: true, yardRelease: true).hashCode,
      );
    });

    group('fromJson rejections (11.2), one case each', () {
      Map<String, Object?> base() => _copy(
            _handJson(
              phase: 'awaitMove',
              queue: const <int>[3],
              releaseOwed: true,
              drought: const <int>[0, 0, 0, 0],
            ),
          );

      test(
          'control: the unmodified base is accepted, and so are the edges '
          'drought 0 and drought 9', () {
        expect(() => GameState.fromJson(base()), returnsNormally);
        final nine = base()..['drought'] = <int>[9, 9, 9, 9];
        expect(() => GameState.fromJson(nine), returnsNormally,
            reason: 'a count of 9 is the largest the document allows');
      });

      test('explicit yardRelease: false', () {
        final json = base();
        _rulesOf(json)['yardRelease'] = false;
        json
          ..remove('drought')
          ..remove('releaseOwed');
        expect(() => GameState.fromJson(json), throwsFormatException,
            reason: 'an explicit false would give one state two '
                'serialisations');
      });

      test('yardRelease without rollQueue', () {
        final json = base();
        _rulesOf(json).remove('rollQueue');
        json.remove('queue');
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('a drought key on a state whose rules lack yardRelease', () {
        final json = base();
        _rulesOf(json).remove('yardRelease');
        json.remove('releaseOwed');
        json['phase'] = 'awaitRoll';
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('a releaseOwed key on a state whose rules lack yardRelease', () {
        final json = base();
        _rulesOf(json).remove('yardRelease');
        json.remove('drought');
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('drought missing while yardRelease is on', () {
        final json = base()..remove('drought');
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('releaseOwed missing while yardRelease is on', () {
        final json = base()..remove('releaseOwed');
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('drought of length 3', () {
        final json = base()..['drought'] = <int>[0, 0, 0];
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('drought of length 5', () {
        final json = base()..['drought'] = <int>[0, 0, 0, 0, 0];
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('a negative count', () {
        final json = base()..['drought'] = <int>[0, -1, 0, 0];
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('a count of 10', () {
        final json = base()..['drought'] = <int>[0, 0, 10, 0];
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('releaseOwed true in awaitRoll', () {
        final json = base()
          ..['phase'] = 'awaitRoll'
          ..['queue'] = <int>[];
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test('releaseOwed true in finished', () {
        final json = base()
          ..['phase'] = 'finished'
          ..['queue'] = <int>[]
          ..['winner'] = 0
          ..['tokens'] = <List<int>>[
            <int>[57, 57, 57, 57],
            _yardRow,
            _yardRow,
            _yardRow,
          ];
        expect(() => GameState.fromJson(json), throwsFormatException);
      });

      test(
          'control: the same finished state with releaseOwed false is '
          'accepted', () {
        final json = base()
          ..['phase'] = 'finished'
          ..['queue'] = <int>[]
          ..['winner'] = 0
          ..['releaseOwed'] = false
          ..['tokens'] = <List<int>>[
            <int>[57, 57, 57, 57],
            _yardRow,
            _yardRow,
            _yardRow,
          ];
        expect(() => GameState.fromJson(json), returnsNormally);
      });
    });
  });

  group('Y11: newGame configuration', () {
    test('yardRelease without rollQueue throws ArgumentError', () {
      expect(
        () => newGame(
          GameConfig(
            seats: _two,
            rules: const RulesConfig(yardRelease: true),
            seed: 1,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('yardRelease without rollQueue throws for every seat count', () {
      for (final seats in <List<int>>[
        <int>[0, 2],
        <int>[0, 1, 2],
        <int>[0, 1, 2, 3],
      ]) {
        expect(
          () => newGame(
            GameConfig(
              seats: seats,
              rules: const RulesConfig(yardRelease: true, homeBonus: true),
              seed: 3,
            ),
          ),
          throwsArgumentError,
          reason: 'seats $seats',
        );
      }
    });

    test('yardRelease with rollQueue is accepted and starts clean', () {
      final s = newGame(_config());
      expect(s.drought, equals(<int>[0, 0, 0, 0]));
      expect(s.releaseOwed, isFalse);
      expect(s.config.rules.yardRelease, isTrue);
      expect(s.queue, isEmpty);
      expect(s.phase, GamePhase.awaitRoll);
    });

    test('a malformed seat list is still an ArgumentError', () {
      expect(
        () => newGame(
          GameConfig(
            seats: const <int>[2, 0],
            rules: const RulesConfig(rollQueue: true, yardRelease: true),
            seed: 1,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('yardRelease off with rollQueue off is the plain old game', () {
      final s = newGame(GameConfig(seats: _two, seed: 1));
      expect(s.drought, equals(<int>[0, 0, 0, 0]));
      expect(s.releaseOwed, isFalse);
    });
  });

  group('Y12: determinism', () {
    List<Intention> script() {
      final out = <Intention>[];
      for (var r = 1; r <= 9; r++) {
        out
          ..add(RollIntention(0, _face(r)))
          ..add(RollIntention(2, _face(r + 2)));
      }
      out
        ..add(const RollIntention(0, 3)) // seat 0's tenth
        ..add(const MoveIntention(0, 1))
        ..add(const MoveIntention(0, 1, face: 3))
        ..add(const RollIntention(2, 4)) // seat 2's tenth
        ..add(const MoveIntention(2, 0))
        ..add(const MoveIntention(2, 0, face: 4))
        ..add(const RollIntention(0, 6))
        ..add(const RollIntention(0, 2))
        ..add(const MoveIntention(0, 1, face: 2))
        ..add(const MoveIntention(0, 2, face: 6))
        ..add(const RollIntention(2, 5))
        ..add(const MoveIntention(2, 0));
      return out;
    }

    List<String> hashes(List<Intention> intentions, {GameState? from}) {
      var state = from ?? newGame(_config(seed: 99));
      final out = <String>[];
      for (final i in intentions) {
        final r = apply(state, i);
        if (r is! Applied) {
          fail('scenario Y12 script: ${_intention(i)} rejected with $r');
        }
        state = r.state;
        out.add(stateHash(state));
      }
      return out;
    }

    test('the same intention list twice gives the same hash at every step', () {
      final a = hashes(script());
      final b = hashes(script());
      expect(a, equals(b), reason: 'scenario Y12 script, seed 99');
      expect(a.toSet().length, greaterThan(20),
          reason: 'sanity: states along the script are not all one hash');
    });

    test('the script really contains two releases', () {
      var state = newGame(_config(seed: 99));
      var releases = 0;
      for (final i in script()) {
        final r = apply(state, i) as Applied;
        releases += r.events.whereType<YardReleased>().length;
        state = r.state;
      }
      expect(releases, 2, reason: 'scenario Y12 script, seed 99');
    });

    test('a snapshot through JSON in the middle replays to the same end', () {
      final intentions = script();
      final whole = hashes(intentions);
      for (final cut in <int>[3, 18, 19, 20, 21, 24]) {
        var state = newGame(_config(seed: 99));
        for (final i in intentions.take(cut)) {
          state = (apply(state, i) as Applied).state;
        }
        final restored = GameState.fromJson(
          jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
        );
        expect(restored, equals(state),
            reason: 'snapshot after $cut intentions of the Y12 script');
        final tail = hashes(intentions.skip(cut).toList(), from: restored);
        expect(tail, equals(whole.skip(cut).toList()),
            reason: 'scenario Y12 script, snapshot after $cut intentions');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Random games against an oracle written from rules 9r to 11r.
  // -------------------------------------------------------------------------

  group('Y13: random games against an oracle of rules 9r-11r', () {
    var releases = 0;

    for (var seed = 1; seed <= 60; seed++) {
      test('seed $seed', () {
        final result = _playRandom(seed);
        releases += result.releases;
        final again = _playRandom(seed);
        expect(again.hashes, equals(result.hashes),
            reason: 'seed $seed: the same game replayed gave different '
                'hashes (rule 36)');
      });
    }

    test('the random games exercised releases and lapses', () {
      expect(releases, greaterThan(20),
          reason: 'sixty seeded games produced only $releases releases; '
              'the dice bias or the oracle is not reaching rule 11r');
    });
  });
}

// ---------------------------------------------------------------------------
// The random driver and its oracle.
// ---------------------------------------------------------------------------

class _Outcome {
  _Outcome(this.hashes, this.releases, this.lapses);
  final List<String> hashes;
  final int releases;
  final int lapses;
}

class _Rand {
  _Rand(this._state);
  int _state;

  int next(int bound) {
    final (s, z) = splitMix64Next(_state);
    _state = s;
    return (z >>> 33) % bound;
  }
}

_Outcome _playRandom(int seed) {
  final rand = _Rand(seed * 7919 + 13);
  final seatSets = <List<int>>[
    <int>[0, 2],
    <int>[0, 1, 2],
    <int>[0, 1, 2, 3],
  ];
  final seats = seatSets[seed % 3];
  final config = _config(
    seats: seats,
    blocks: seed % 2 == 0,
    homeBonus: seed % 5 == 0,
    seed: seed,
  );
  var state = newGame(config);
  final counts = <int>[0, 0, 0, 0];
  final log = <String>[];
  final hashes = <String>[];
  var releases = 0;
  var lapses = 0;

  String where() => 'seed $seed (seats $seats, blocks ${seed % 2 == 0}, '
      'homeBonus ${seed % 5 == 0}); intentions: ${log.join('; ')}';

  for (var step = 0; step < 700 && !isTerminal(state); step++) {
    final Intention intention;
    if (state.phase == GamePhase.awaitRoll) {
      final face = rand.next(100) < 8 ? 6 : 1 + rand.next(5);
      intention = RollIntention(state.currentSeat, face);
    } else if (state.releaseOwed) {
      intention = MoveIntention(state.currentSeat, legalTokens(state).first);
    } else {
      final byFace = legalByFace(state);
      final faces = byFace.keys.toList();
      final face = faces[rand.next(faces.length)];
      final tokens = byFace[face]!;
      final token = tokens[rand.next(tokens.length)];
      intention = MoveIntention(
        state.currentSeat,
        token,
        face: face == defaultFace(state) && rand.next(2) == 0 ? null : face,
      );
    }
    log.add(_intention(intention));

    final before = state;
    final result = apply(before, intention);
    if (result is! Applied) {
      fail('expected the engine to accept ${_intention(intention)} '
          '(legal by construction), got $result. ${where()}');
    }
    state = result.state;
    final events = result.events;
    final text = _events(events);
    hashes.add(stateHash(state));

    // Oracle for the drought, from rules 9r to 11r.
    var expectRelease = false;
    if (intention is RollIntention) {
      final s = intention.seat;
      final allYard = before.tokens[s].every((p) => p == -1);
      if (intention.face == 6) {
        counts[s] = 0;
      } else if (allYard) {
        counts[s] += 1;
        if (counts[s] == 10) {
          expectRelease = true;
          counts[s] = 0;
        }
      } else {
        counts[s] = 0;
      }
    }
    for (final s in seats) {
      if (state.tokens[s].any((p) => p != -1)) {
        counts[s] = 0; // rule 9r: a token off the yard means drought 0
      }
    }
    final released = events.any((e) => e is YardReleased);
    expect(released, expectRelease,
        reason: 'expected YardReleased=$expectRelease after '
            '${_intention(intention)}, events $text. ${where()}');
    expect(state.drought, equals(counts),
        reason: 'expected drought $counts after ${_intention(intention)}, '
            'got ${state.drought}. ${where()}');

    // Structural invariants.
    expect(state.seq, before.seq + 1, reason: 'seq. ${where()}');
    for (var s = 0; s < 4; s++) {
      expect(state.drought[s], inInclusiveRange(0, 9),
          reason: 'drought range. ${where()}');
      if (!seats.contains(s)) {
        expect(state.drought[s], 0,
            reason: 'an empty seat keeps drought 0. ${where()}');
      }
    }
    if (state.releaseOwed) {
      expect(state.phase, GamePhase.awaitMove,
          reason: 'releaseOwed outside awaitMove. ${where()}');
      expect(state.sixes, 0, reason: 'sixes at a release. ${where()}');
      expect(state.tokens[state.currentSeat].every((p) => p == -1), isTrue,
          reason: 'a release is owed to a seat with a token out. ${where()}');
      expect(legalByFace(state), isEmpty, reason: 'legalByFace. ${where()}');
      expect(defaultFace(state), isNull, reason: 'defaultFace. ${where()}');
      expect(legalTokens(state), isNotEmpty,
          reason: 'owed with nothing releasable. ${where()}');
      expect(state.queue.isNotEmpty && state.queue.last != 6, isTrue,
          reason: 'the kept face is the last queued, never a 6. ${where()}');
    }
    if (released) {
      releases++;
      expect(text[1], 'YardReleased(${intention.seat})',
          reason: 'YardReleased must follow Rolled directly. $text '
              '${where()}');
      expect(events.first, isA<Rolled>(), reason: where());
      if (state.releaseOwed) {
        final rolled = events.first as Rolled;
        expect(rolled.legal, equals(legalTokens(state)),
            reason: 'Rolled.legal is the releasable tokens. ${where()}');
        expect(rolled.value, (intention as RollIntention).face,
            reason: 'the fair face is recorded as rolled. ${where()}');
        expect(events.length, 2, reason: 'events $text. ${where()}');
      } else {
        lapses++;
        expect(
            text.sublist(2),
            equals(<String>[
              'TurnEnded(${intention.seat},noLegalMove)',
              'TurnBegan(${state.currentSeat})',
            ]),
            reason: 'a lapse passes the turn. ${where()}');
        expect(state.queue, isEmpty, reason: where());
        expect(state.phase, GamePhase.awaitRoll, reason: where());
      }
    }
    if (intention is MoveIntention && before.releaseOwed) {
      expect(text.first, 'Moved(${intention.seat},${intention.token},-1->0)',
          reason: 'the release moves a token from the yard to the entry '
              'square. ${where()}');
      expect(events.any((e) => e is ExtraRoll), isFalse,
          reason: 'a release move grants no extra roll. ${where()}');
      expect(events.any((e) => e is Captured), isFalse,
          reason: 'the entry square is safe. ${where()}');
    }

    // The JSON form always round-trips.
    final back = GameState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
    );
    expect(back, equals(state), reason: 'round trip. ${where()}');
  }
  return _Outcome(hashes, releases, lapses);
}
