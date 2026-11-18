// docs/ENGINE_API.md section 13.2: serialisation of the shared release.
// `sharedRelease` is written in `rules` after `yardRelease`, only when true;
// `banked` and `releaseOffered` are written in that order right after
// `releaseOwed`, only when `sharedRelease` is true. fromJson() reads them
// absent as [0,0,0,0] / false and owes the rejections listed there.
//
// Written from the document only; states come from test/support. Every
// failure message names the case. Nothing here reads lib/.

import 'dart:convert';

import 'package:ludo_engine/ludo_engine.dart';
import 'package:test/test.dart';

import '../support/shared_release_support.dart';

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

const String _tokens = '[[-1,-1,-1,-1],[-1,-1,-1,-1],[-1,-1,-1,-1],'
    '[-1,-1,-1,-1]]';

void main() {
  group('J1: the exact text', () {
    test('on: a new game, seed 7', () {
      final state = newGame(sharedConfig(seed: 7));
      final expected = '{"config":{"seats":[0,2],"rules":{"blocks":true,'
          '"captureBonus":true,"rollQueue":true,"yardRelease":true,'
          '"sharedRelease":true},"seed":7},"tokens":$_tokens,'
          '"currentSeat":0,"phase":"awaitRoll","roll":null,"queue":[],'
          '"sixes":0,"drought":[0,0,0,0],"releaseOwed":false,'
          '"banked":[0,0,0,0],"releaseOffered":false,"winner":null,'
          '"seq":0,"rngState":7}';
      expect(jsonEncode(state.toJson()), expected,
          reason: 'canonical text of newGame with sharedRelease, seed 7');
      expect(stateHash(state), _fnv(expected),
          reason: 'stateHash is FNV-1a over exactly that text');
    });

    test('on: an offered state, banked counts kept', () {
      final state = hand(
        phase: 'awaitMove',
        queue: const <int>[3],
        drought: const <int>[9, 0, 0, 0],
        releaseOwed: true,
        banked: const <int>[0, 0, 2, 0],
        releaseOffered: true,
      );
      final expected = '{"config":{"seats":[0,2],"rules":{"blocks":true,'
          '"captureBonus":true,"rollQueue":true,"yardRelease":true,'
          '"sharedRelease":true},"seed":1},"tokens":$_tokens,'
          '"currentSeat":0,"phase":"awaitMove","roll":null,"queue":[3],'
          '"sixes":0,"drought":[9,0,0,0],"releaseOwed":true,'
          '"banked":[0,0,2,0],"releaseOffered":true,"winner":null,'
          '"seq":0,"rngState":1}';
      expect(jsonEncode(state.toJson()), expected);
      expect(stateHash(state), _fnv(expected));
    });

    test(
        'rules key order: blocks, captureBonus, rollQueue, homeBonus, '
        'yardRelease, sharedRelease', () {
      final state = newGame(sharedConfig(homeBonus: true));
      final rules = rulesOf(Map<String, Object?>.from(state.toJson()));
      expect(
        rules.keys.toList(),
        equals(<String>[
          'blocks',
          'captureBonus',
          'rollQueue',
          'homeBonus',
          'yardRelease',
          'sharedRelease',
        ]),
      );
      expect(rules['sharedRelease'], isTrue);
    });

    test('state key order: banked and releaseOffered right after releaseOwed',
        () {
      final keys = newGame(sharedConfig()).toJson().keys.toList();
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
          'banked',
          'releaseOffered',
          'winner',
          'seq',
          'rngState',
        ]),
      );
    });

    test('values after a take are written as the engine state holds them', () {
      final run = Run('J1 take', offeredHand(banked: const <int>[0, 0, 1, 0]));
      run.move(0, 2);
      final json = run.state.toJson();
      expect(json['banked'], equals(<int>[0, 0, 0, 0]),
          reason: 'the next seat\'s count moved into its queue. ${run.trace}');
      expect(json['queue'], equals(<int>[6, 6]), reason: run.trace);
      expect(json['releaseOffered'], isFalse, reason: run.trace);
      expect(json['releaseOwed'], isFalse, reason: run.trace);
    });
  });

  group('J2: off means the same bytes as before', () {
    test('yardRelease on, sharedRelease off: no new key anywhere', () {
      final state = newGame(GameConfig(
        seats: twoSeats,
        rules: const RulesConfig(rollQueue: true, yardRelease: true),
        seed: 7,
      ));
      final expected = '{"config":{"seats":[0,2],"rules":{"blocks":true,'
          '"captureBonus":true,"rollQueue":true,"yardRelease":true},'
          '"seed":7},"tokens":$_tokens,"currentSeat":0,'
          '"phase":"awaitRoll","roll":null,"queue":[],"sixes":0,'
          '"drought":[0,0,0,0],"releaseOwed":false,"winner":null,'
          '"seq":0,"rngState":7}';
      expect(jsonEncode(state.toJson()), expected);
      expect(stateHash(state), _fnv(expected),
          reason: 'a sharedRelease-off state must hash exactly as before');
    });

    test('rollQueue only and legacy: no new key anywhere', () {
      final queueOnly = newGame(GameConfig(
        seats: twoSeats,
        rules: const RulesConfig(rollQueue: true),
        seed: 7,
      ));
      final legacy = newGame(GameConfig(seats: twoSeats, seed: 7));
      for (final s in <GameState>[queueOnly, legacy]) {
        final text = jsonEncode(s.toJson());
        for (final key in <String>[
          'sharedRelease',
          'banked',
          'releaseOffered'
        ]) {
          expect(text.contains('"$key"'), isFalse, reason: 'text: $text');
        }
        expect(s.banked, equals(zeros));
        expect(s.releaseOffered, isFalse);
      }
      expect(
        jsonEncode(legacy.toJson()),
        '{"config":{"seats":[0,2],"rules":{"blocks":true,'
        '"captureBonus":true},"seed":7},"tokens":$_tokens,'
        '"currentSeat":0,"phase":"awaitRoll","roll":null,"sixes":0,'
        '"winner":null,"seq":0,"rngState":7}',
      );
    });

    test('a yardRelease state without the new keys reads them as defaults', () {
      final json = copyJson(handJson());
      rulesOf(json).remove('sharedRelease');
      json
        ..remove('banked')
        ..remove('releaseOffered');
      final state = GameState.fromJson(json);
      expect(state.banked, equals(zeros));
      expect(state.releaseOffered, isFalse);
      expect(state.config.rules.sharedRelease, isFalse);
      expect(jsonEncode(state.toJson()).contains('"banked"'), isFalse);
    });

    test('every state of a long off game is free of the new keys', () {
      var state = newGame(GameConfig(
        seats: twoSeats,
        rules: const RulesConfig(rollQueue: true, yardRelease: true),
        seed: 5,
      ));
      for (var r = 1; r <= 9; r++) {
        for (final seat in twoSeats) {
          state =
              (apply(state, RollIntention(seat, face5(r))) as Applied).state;
          final text = jsonEncode(state.toJson());
          expect(text.contains('"banked"') || text.contains('"releaseOffered"'),
              isFalse,
              reason: 'round $r seat $seat, seed 5, text: $text');
        }
      }
    });
  });

  group('J3: round trip', () {
    test('toJson then fromJson restores equal, hash-equal states', () {
      final states = <String, GameState>{
        'new game': newGame(sharedConfig()),
        'new game, four seats': newGame(sharedConfig(seats: fourSeats)),
        'banked [0,3,1,2]':
            hand(seats: fourSeats, banked: const <int>[0, 3, 1, 2]),
        'queue of banked sixes': hand(currentSeat: 2, queue: const <int>[6, 6]),
        'offered': offeredHand(),
        'offered, banked owed': offeredHand(banked: const <int>[0, 0, 3, 0]),
        'homeBonus too': hand(homeBonus: true, banked: const <int>[0, 0, 1, 0]),
        'playOut too': hand(
            seats: threeSeats, playOut: true, banked: const <int>[0, 1, 0, 0]),
      };
      states.forEach((name, state) {
        final text = jsonEncode(state.toJson());
        final back =
            GameState.fromJson(jsonDecode(text) as Map<String, Object?>);
        expect(back, equals(state), reason: 'round trip of "$name"');
        expect(jsonEncode(back.toJson()), text,
            reason: 'round trip text of "$name"');
        expect(stateHash(back), stateHash(state),
            reason: 'round trip hash of "$name"');
        expect(back.hashCode, state.hashCode, reason: '"$name"');
        expect(back.banked, equals(state.banked), reason: '"$name"');
        expect(back.releaseOffered, state.releaseOffered, reason: '"$name"');
      });
    });

    test('states that differ only in banked or releaseOffered are not equal',
        () {
      final a = hand(banked: const <int>[0, 0, 1, 0]);
      final b = hand(banked: const <int>[0, 0, 2, 0]);
      final c = hand(banked: const <int>[0, 0, 0, 0]);
      expect(a == b, isFalse);
      expect(a == c, isFalse);
      expect(stateHash(a), isNot(stateHash(b)));
      expect(stateHash(a), isNot(stateHash(c)));
      final owedOnly = hand(
        phase: 'awaitMove',
        queue: const <int>[3],
        drought: const <int>[9, 0, 0, 0],
        releaseOwed: true,
      );
      final offered = hand(
        phase: 'awaitMove',
        queue: const <int>[3],
        drought: const <int>[9, 0, 0, 0],
        releaseOwed: true,
        releaseOffered: true,
      );
      expect(owedOnly == offered, isFalse);
      expect(stateHash(owedOnly), isNot(stateHash(offered)));
    });

    test('a state reached by play round-trips at every step', () {
      final run = Run('J3 play', newGame(sharedConfig(seed: 11)));
      void check(String when) {
        final text = jsonEncode(run.state.toJson());
        final back =
            GameState.fromJson(jsonDecode(text) as Map<String, Object?>);
        expect(back, equals(run.state), reason: '$when. ${run.trace}');
        expect(stateHash(back), stateHash(run.state),
            reason: '$when. ${run.trace}');
      }

      stuckRounds(run, twoSeats, 9);
      check('after nine rounds');
      run.roll(0, 4);
      check('offered');
      run.move(0, 1);
      check('after the take, banked six queued');
      run.roll(2, 3);
      check('after the banked six and a roll');
    });
  });

  group('J4: fromJson rejections (13.2), one case each', () {
    Map<String, Object?> base() => copyJson(handJson(
          phase: 'awaitMove',
          queue: const <int>[3],
          releaseOwed: true,
          releaseOffered: true,
          drought: const <int>[9, 0, 0, 0],
        ));

    test('control: the unmodified base is accepted, and so are the edges', () {
      expect(() => GameState.fromJson(base()), returnsNormally);
      final edge = base()..['banked'] = <int>[0, 3, 3, 3];
      expect(() => GameState.fromJson(edge), returnsNormally,
          reason: 'a count of 3 is the largest the document allows');
      final idle = base()
        ..['phase'] = 'awaitRoll'
        ..['queue'] = <int>[]
        ..['releaseOwed'] = false
        ..['releaseOffered'] = false;
      expect(() => GameState.fromJson(idle), returnsNormally);
    });

    test('explicit sharedRelease: false', () {
      final json = base();
      rulesOf(json)['sharedRelease'] = false;
      json
        ..remove('banked')
        ..remove('releaseOffered');
      json['releaseOwed'] = false;
      json['phase'] = 'awaitRoll';
      json['queue'] = <int>[];
      expect(() => GameState.fromJson(json), throwsFormatException,
          reason: 'an explicit false gives one state two serialisations');
    });

    test('sharedRelease without yardRelease', () {
      final json = base();
      rulesOf(json).remove('yardRelease');
      json
        ..remove('drought')
        ..remove('releaseOwed')
        ..['releaseOffered'] = false
        ..['phase'] = 'awaitRoll'
        ..['queue'] = <int>[];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('sharedRelease without rollQueue', () {
      final json = base();
      rulesOf(json).remove('rollQueue');
      json
        ..remove('queue')
        ..['phase'] = 'awaitRoll'
        ..['releaseOwed'] = false
        ..['releaseOffered'] = false;
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('a banked key on a state whose rules lack sharedRelease', () {
      final json = base();
      rulesOf(json).remove('sharedRelease');
      json
        ..remove('releaseOffered')
        ..['banked'] = <int>[0, 0, 1, 0];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('a releaseOffered key on a state whose rules lack sharedRelease', () {
      final json = base();
      rulesOf(json).remove('sharedRelease');
      json
        ..remove('banked')
        ..['releaseOffered'] = false;
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('banked missing while sharedRelease is on', () {
      final json = base()..remove('banked');
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('releaseOffered missing while sharedRelease is on', () {
      final json = base()..remove('releaseOffered');
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('banked of length 3', () {
      final json = base()..['banked'] = <int>[0, 0, 0];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('banked of length 5', () {
      final json = base()..['banked'] = <int>[0, 0, 0, 0, 0];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('banked of length 0', () {
      final json = base()..['banked'] = <int>[];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('a negative count', () {
      final json = base()..['banked'] = <int>[0, -1, 0, 0];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('a count of 4', () {
      final json = base()..['banked'] = <int>[0, 0, 4, 0];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('a count of 100', () {
      final json = base()..['banked'] = <int>[100, 0, 0, 0];
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('releaseOffered true without releaseOwed', () {
      final json = base()..['releaseOwed'] = false;
      expect(() => GameState.fromJson(json), throwsFormatException);
    });

    test('releaseOffered true in awaitRoll (so releaseOwed is not set)', () {
      final json = base()
        ..['phase'] = 'awaitRoll'
        ..['queue'] = <int>[]
        ..['releaseOwed'] = false;
      expect(() => GameState.fromJson(json), throwsFormatException);
    });
  });
}
