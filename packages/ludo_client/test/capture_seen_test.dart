// Proof for C-588 (X154): a capture between two other seats is heard, and
// every capture line names the other party. Written from the contract's text
// (work/ludo/orders/588-capture-between-others-named.md, D1 to D4) and from
// docs/PROTOCOL.md section 12.2 for the `moved` fields.
//
// Four layers, cheapest first:
//   1. cuesForFrame, pure: who hears what for a capture (D2).
//   2. PlatformFeedbackService over a mock channel: captureSeen is a sound
//      and never a haptic (D1).
//   3. The arb files: the three new keys, their placeholders, and the two
//      old keys kept as the fallback (D3).
//   4. A real GameScreen over a real RoomController on FakeTransport, with
//      the real PlatformFeedbackService behind a mock channel and the
//      accessibility channel recorded: sound only at the landing, never a
//      haptic, one named line per capture (D2, D3, D4).
//
// FeedbackCue.captureSeen and the three getters do not exist on a tree
// without the implementation, so this file never names them: the cue is
// looked up by name inside a test body, and the expected lines are built
// here from the contract's own template text (the arb is checked against
// the same templates in layer 3). That keeps the file compiling on the base,
// where the cases that encode today's behaviour stay green and the cases
// that encode the new rule fail on their own assertion.
//
// Every screen case names its scenario and carries the frames and pumps that
// led to the failure (Scn.why), so a red case replays from its message.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart' show kTokenStepDuration;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:path/path.dart' as p;

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const String _id = 'AAAAAAAA';

FeedbackCue get _seen => FeedbackCue.values.byName('captureSeen');

// --- the contract's texts (D3), the one place they are written here ----------

const String _enOtherNamed = "You captured {name}'s token";
const String _enMeNamed = '{name} captured your token';
const String _enSeen = "{capturer} captured {victim}'s token";
const String _arOtherNamed = 'ضربت قطعة {name}';
const String _arMeNamed = 'ضُربت قطعتك. الضربة من {name}';
const String _arSeen = 'ضُربت قطعة {victim}. الضربة من {capturer}';

// The old unnamed lines, kept in the arb as the fallback (D3).
const String _enOtherUnnamed = 'You captured a token';
const String _enMeUnnamed = 'Your token was captured';

String _fill(String template, Map<String, String> values) {
  String out = template;
  values.forEach((String key, String value) {
    out = out.replaceAll('{$key}', value);
  });
  return out;
}

Frame _frame(String type, Map<String, Object?> data) =>
    Frame(type: type, id: _id, data: data);

Frame _moved({
  required Object? seat,
  Object? captured = _absent,
  int from = 5,
  int to = 10,
}) => _frame('moved', <String, Object?>{
  'seat': ?(seat == _absent ? null : seat),
  'token': 0,
  'from': from,
  'to': to,
  if (captured != _absent) 'captured': captured,
  'extra_roll': false,
});

const Object _absent = Object();

List<Object?> _victims(List<int> seats) => <Object?>[
  for (final int seat in seats) <String, Object?>{'seat': seat, 'token': 1},
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // Layer 1: cuesForFrame (D2).
  // ==========================================================================
  group('D2: cuesForFrame for a capture, every seat pairing', () {
    // mySeat x mover x victim over four seats: the role decides the cue.
    for (final int me in <int>[0, 1, 2, 3]) {
      for (final int mover in <int>[0, 1, 2, 3]) {
        for (final int victim in <int>[0, 1, 2, 3]) {
          if (victim == mover) {
            continue;
          }
          final String role = mover == me
              ? 'I capture'
              : victim == me
              ? 'I am captured'
              : 'a third seat is captured';
          test('me $me, seat $mover captures seat $victim: $role', () {
            final Frame frame = _moved(
              seat: mover,
              captured: _victims(<int>[victim]),
            );
            final List<FeedbackCue> expected = mover == me
                ? <FeedbackCue>[FeedbackCue.capturedOther]
                : victim == me
                ? <FeedbackCue>[FeedbackCue.capturedMe]
                : <FeedbackCue>[_seen];
            expect(
              cuesForFrame(frame, mySeat: me),
              equals(expected),
              reason:
                  'scenario: mySeat $me, mover $mover, victim $victim '
                  '($role). Expected $expected (D2: a capture that is not '
                  'mine and not of me answers [captureSeen]; the other two '
                  'rows are unchanged). frame.data=${frame.data}',
            );
          });
        }
      }
    }

    test('two tokens of one third seat in one move give one captureSeen', () {
      final Frame frame = _moved(seat: 0, captured: _victims(<int>[2, 2]));
      expect(
        cuesForFrame(frame, mySeat: 1),
        equals(<FeedbackCue>[_seen]),
        reason:
            'scenario: me 1, seat 0 takes two seat-2 tokens at once; D2 '
            'answers one cue per frame. frame.data=${frame.data}',
      );
    });

    test('two third seats captured in one move give one captureSeen', () {
      final Frame frame = _moved(seat: 0, captured: _victims(<int>[2, 3]));
      expect(
        cuesForFrame(frame, mySeat: 1),
        equals(<FeedbackCue>[_seen]),
        reason:
            'scenario: me 1, seat 0 takes a seat-2 and a seat-3 token at '
            'once; D2 answers one cue per frame. frame.data=${frame.data}',
      );
    });

    test('a capture of me among others is capturedMe alone, never also '
        'captureSeen', () {
      for (final List<int> order in <List<int>>[
        <int>[2, 1],
        <int>[1, 2],
      ]) {
        final Frame frame = _moved(seat: 0, captured: _victims(order));
        expect(
          cuesForFrame(frame, mySeat: 1),
          equals(<FeedbackCue>[FeedbackCue.capturedMe]),
          reason:
              'scenario: me 1, seat 0 captures seats $order in one move; '
              'a frame that hits me is mine to feel, exactly [capturedMe]. '
              'frame.data=${frame.data}',
        );
      }
    });

    test('my capture that lands home is still capturedOther then home', () {
      final Frame frame = _moved(
        seat: 1,
        captured: _victims(<int>[2]),
        from: 50,
        to: 57,
      );
      expect(
        cuesForFrame(frame, mySeat: 1),
        equals(<FeedbackCue>[FeedbackCue.capturedOther, FeedbackCue.home]),
        reason: 'D4: my own rows do not change. frame.data=${frame.data}',
      );
    });

    test('another seat\'s capture-free move is still silent', () {
      final Frame frame = _moved(seat: 0, captured: <Object?>[]);
      expect(
        cuesForFrame(frame, mySeat: 1),
        equals(const <FeedbackCue>[]),
        reason: 'D4, doctrine section 3: no cue for others\' routine moves',
      );
    });
  });

  group('D2: a spectator (mySeat null)', () {
    for (final (int mover, List<int> victims) in <(int, List<int>)>[
      (0, <int>[1]),
      (1, <int>[0]),
      (2, <int>[3]),
      (3, <int>[0, 1]),
    ]) {
      test('seat $mover captures $victims: [captureSeen]', () {
        final Frame frame = _moved(seat: mover, captured: _victims(victims));
        expect(
          cuesForFrame(frame, mySeat: null),
          equals(<FeedbackCue>[_seen]),
          reason:
              'scenario: spectator, mover $mover, victims $victims. '
              'Expected [captureSeen] (D2). frame.data=${frame.data}',
        );
      });
    }

    test('a capture-free move is []', () {
      final Frame frame = _moved(seat: 2, captured: <Object?>[]);
      expect(
        cuesForFrame(frame, mySeat: null),
        equals(const <FeedbackCue>[]),
        reason: 'D2: only a capture changes for a spectator',
      );
    });

    test('every other frame type is still []', () {
      final List<Frame> frames = <Frame>[
        _frame('turn', <String, Object?>{'seat': 0, 'deadline_ms': 45000}),
        _frame('rolled', <String, Object?>{
          'seat': 0,
          'value': 4,
          'legal': <int>[0],
          'deadline_ms': 1000,
          'k': 1,
          'reveal': 'a' * 64,
        }),
        _frame('game_over', <String, Object?>{
          'winner': 0,
          'verify_url': 'https://ludo.provefair.app/v/abc123',
        }),
        _frame('turn_passed', <String, Object?>{
          'seat': 0,
          'reason': 'no_legal_move',
        }),
      ];
      for (final Frame frame in frames) {
        expect(
          cuesForFrame(frame, mySeat: null),
          equals(const <FeedbackCue>[]),
          reason:
              'D2: "only this case changes" for a null seat; '
              '${frame.type} ${frame.data} must stay []',
        );
      }
    });
  });

  group('D2: a malformed captured answers [] and never throws', () {
    final Map<String, Object?> cases = <String, Object?>{
      'absent': _absent,
      'a String': 'oops',
      'a Map': <String, Object?>{'seat': 2, 'token': 1},
      'an int': 2,
      'null': null,
      'a seat that is a String': <Object?>[
        <String, Object?>{'seat': '2', 'token': 1},
      ],
      'a seat that is a double': <Object?>[
        <String, Object?>{'seat': 2.5, 'token': 1},
      ],
      'a seat that is null': <Object?>[
        <String, Object?>{'seat': null, 'token': 1},
      ],
      'one good entry and one mistyped seat': <Object?>[
        <String, Object?>{'seat': 2, 'token': 1},
        <String, Object?>{'seat': 'x', 'token': 0},
      ],
    };
    for (final int? me in <int?>[1, null]) {
      for (final MapEntry<String, Object?> entry in cases.entries) {
        test('captured ${entry.key}, mySeat $me', () {
          final Frame frame = _moved(seat: 0, captured: entry.value);
          List<FeedbackCue>? cues;
          expect(
            () => cues = cuesForFrame(frame, mySeat: me),
            returnsNormally,
            reason:
                'scenario: captured ${entry.key}, mySeat $me; the derivation '
                'must not throw. frame.data=${frame.data}',
          );
          expect(
            cues,
            equals(const <FeedbackCue>[]),
            reason:
                'scenario: captured ${entry.key}, mySeat $me. Expected [] '
                '(D2: malformed captured is silent), got $cues. '
                'frame.data=${frame.data}',
          );
        });
      }
    }

    for (final int? me in <int?>[1, null]) {
      test('no mover seat at all, mySeat $me: []', () {
        final Frame absent = _moved(
          seat: _absent,
          captured: _victims(<int>[2]),
        );
        final Frame typed = _moved(seat: '0', captured: _victims(<int>[2]));
        expect(
          cuesForFrame(absent, mySeat: me),
          equals(const <FeedbackCue>[]),
          reason:
              'a moved frame with no mover cannot be a capture by anyone; '
              'frame.data=${absent.data}',
        );
        expect(
          cuesForFrame(typed, mySeat: me),
          equals(const <FeedbackCue>[]),
          reason:
              'a moved frame whose seat is a String is malformed; '
              'frame.data=${typed.data}',
        );
      });
    }

    test('an empty captured list is [] for another seat\'s move, mySeat '
        'null as well', () {
      final Frame frame = _moved(seat: 0, captured: <Object?>[]);
      expect(cuesForFrame(frame, mySeat: 1), isEmpty);
      expect(cuesForFrame(frame, mySeat: null), isEmpty);
    });
  });

  // ==========================================================================
  // Layer 2: the service (D1).
  // ==========================================================================
  group('D1: captureSeen is a sound and never a haptic', () {
    const MethodChannel channel = MethodChannel('app.fayad.ludo/feedback');

    List<String> record() {
      final List<String> calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add('${call.method}:${(call.arguments as Map)['id']}');
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      return calls;
    }

    for (final (bool haptics, bool sound, List<String> expected)
        in <(bool, bool, List<String>)>[
          (true, true, <String>['sound:capture_seen']),
          (false, true, <String>['sound:capture_seen']),
          (true, false, <String>[]),
          (false, false, <String>[]),
        ]) {
      test('haptics $haptics, sound $sound: $expected', () async {
        final List<String> calls = record();
        final PlatformFeedbackService service = PlatformFeedbackService(
          FeedbackSettings.forTest(haptics: haptics, sound: sound),
          channel,
        );
        addTearDown(service.dispose);

        service.play(_seen);
        await pumpEventQueue();

        expect(
          calls,
          equals(expected),
          reason:
              'scenario: play(captureSeen) with haptics $haptics, sound '
              '$sound. Expected $expected (D1: sound only, gated on the '
              'sound switch, never a haptic), got $calls',
        );
      });
    }

    test('five plays in one instant make five sounds: not throttled', () async {
      final List<String> calls = record();
      final PlatformFeedbackService service = PlatformFeedbackService(
        FeedbackSettings.forTest(),
        channel,
      );
      addTearDown(service.dispose);

      for (int i = 0; i < 5; i++) {
        service.play(_seen);
      }
      await pumpEventQueue();

      expect(
        calls,
        equals(List<String>.filled(5, 'sound:capture_seen')),
        reason:
            'only step is throttled; five captures are five sounds, and '
            'none is a haptic. got $calls',
      );
    });

    test(
      'the id is on the wire as capture_seen and no other cue shares it',
      () {
        expect(_seen.id, 'capture_seen');
        expect(
          FeedbackCue.values.where((FeedbackCue c) => c.id == 'capture_seen'),
          hasLength(1),
        );
      },
    );
  });

  // ==========================================================================
  // Layer 3: the arb files (D3).
  // ==========================================================================
  group('D3: the arb carries the three new lines and keeps the old two', () {
    // The raw text is compared: gen-l10n prints a doubled apostrophe as two,
    // so the arb carries the single one the screen is meant to show.
    Map<String, Object?> arb(String lang) {
      final File file = File(p.join('lib', 'l10n', 'app_$lang.arb'));
      if (!file.existsSync()) {
        fail(
          'run flutter test from the ludo_client package root; '
          '${file.path} is not under ${Directory.current.path}',
        );
      }
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }

    final Map<String, (String, String, List<String>)> keys =
        <String, (String, String, List<String>)>{
          'announceCapturedOtherNamed': (
            _enOtherNamed,
            _arOtherNamed,
            <String>['name'],
          ),
          'announceCapturedMeNamed': (_enMeNamed, _arMeNamed, <String>['name']),
          'announceCaptureSeen': (
            _enSeen,
            _arSeen,
            <String>['capturer', 'victim'],
          ),
        };

    for (final MapEntry<String, (String, String, List<String>)> entry
        in keys.entries) {
      test('${entry.key}: en and ar text, placeholders, @ metadata', () {
        final Map<String, Object?> en = arb('en');
        final Map<String, Object?> ar = arb('ar');
        expect(
          en.containsKey(entry.key),
          isTrue,
          reason: 'app_en.arb must define ${entry.key} (D3)',
        );
        expect(
          en[entry.key],
          entry.value.$1,
          reason: 'app_en.arb ${entry.key} must read "${entry.value.$1}"',
        );
        expect(
          ar.containsKey(entry.key),
          isTrue,
          reason: 'app_ar.arb must define ${entry.key} (D3)',
        );
        expect(
          ar[entry.key],
          entry.value.$2,
          reason: 'app_ar.arb ${entry.key} must read "${entry.value.$2}"',
        );
        final Object? meta = en['@${entry.key}'];
        expect(
          meta,
          isA<Map<String, Object?>>(),
          reason: 'app_en.arb must carry @${entry.key} metadata (D3)',
        );
        final Object? placeholders =
            (meta! as Map<String, Object?>)['placeholders'];
        expect(
          placeholders,
          isA<Map<String, Object?>>(),
          reason: '@${entry.key} must declare its placeholders (D3)',
        );
        expect(
          (placeholders! as Map<String, Object?>).keys.toList()..sort(),
          equals(List<String>.of(entry.value.$3)..sort()),
          reason:
              '@${entry.key} placeholders must be exactly ${entry.value.$3}',
        );
      });
    }

    test('the old unnamed keys stay, unchanged, as the fallback', () {
      final Map<String, Object?> en = arb('en');
      final Map<String, Object?> ar = arb('ar');
      expect(en['announceCapturedOther'], _enOtherUnnamed);
      expect(en['announceCapturedMe'], _enMeUnnamed);
      expect(ar['announceCapturedOther'], 'ضربت قطعة');
      expect(ar['announceCapturedMe'], 'ضُربت قطعتك');
    });
  });

  // ==========================================================================
  // Layer 4: a real GameScreen (D1 to D4).
  // ==========================================================================
  group('GameScreen: three seats, I am seat 1, seat 0 captures seat 2', () {
    testWidgets('capture_seen sounds once, only after the token lands, and '
        'never buzzes', (tester) async {
      final _Table t = await _sit(
        tester,
        'D2 landing hold',
        me: 1,
        seats: _trio(<int, List<int>>{0: _moverTokens, 2: _victimTokens}),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2]);
        expect(
          t.sounds('capture_seen'),
          isEmpty,
          reason: t.s.why('no capture_seen sound on the frame itself'),
        );
        expect(
          t.cueIds,
          isEmpty,
          reason: t.s.why('no cue at all on the frame'),
        );

        await t.squares(5);
        expect(
          t.sounds('capture_seen'),
          isEmpty,
          reason: t.s.why('5 of 6 squares walked: still held'),
        );

        await t.squares(1);
        expect(
          t.sounds('capture_seen'),
          hasLength(1),
          reason: t.s.why(
            'the sixth square landed: exactly one capture_seen sound '
            '(sounds so far: ${t.allSounds})',
          ),
        );
        expect(
          t.cueIds,
          equals(<String>['capture_seen']),
          reason: t.s.why('the only cue I hear is captureSeen'),
        );

        await t.s.pump(const Duration(seconds: 3));
        expect(
          t.sounds('capture_seen'),
          hasLength(1),
          reason: t.s.why('the fallback timer must not play it a second time'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('no haptic of any kind reaches the third seat', (tester) async {
      final _Table t = await _sit(
        tester,
        'D1 and D4 no haptic for C',
        me: 1,
        seats: _trio(<int, List<int>>{0: _moverTokens, 2: _victimTokens}),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2]);
        await t.squares(6);
        await t.s.pump(const Duration(seconds: 3));
        expect(
          t.haptics,
          isEmpty,
          reason: t.s.why(
            'doctrine section 3: no haptic for another seat\'s routine '
            'move or a capture between others (haptics: ${t.haptics})',
          ),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('exactly one line, at the landing, naming both seats', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 captureSeen line',
        me: 1,
        seats: _trio(<int, List<int>>{0: _moverTokens, 2: _victimTokens}),
      );
      try {
        final String line = _fill(_enSeen, <String, String>{
          'capturer': 'Ann',
          'victim': 'Cara',
        });
        await t.capture(mover: 0, victims: <int>[2]);
        expect(
          t.said,
          isEmpty,
          reason: t.s.why('nothing is said on the frame, before the landing'),
        );
        await t.squares(5);
        expect(t.said, isEmpty, reason: t.s.why('5 of 6 squares: still held'));
        await t.squares(1);
        expect(
          t.said,
          equals(<String>[line]),
          reason: t.s.why(
            'exactly one announcement "$line" when the token lands; '
            'said: ${t.said}',
          ),
        );
        await t.s.pump(const Duration(seconds: 3));
        expect(
          t.said,
          equals(<String>[line]),
          reason: t.s.why('still one line after the fallback window'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('Arabic: the same line in Arabic with both names, RTL', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 captureSeen line, ar',
        me: 1,
        locale: const Locale('ar'),
        seats: _trio(<int, List<int>>{0: _moverTokens, 2: _victimTokens}),
      );
      try {
        final String line = _fill(_arSeen, <String, String>{
          'capturer': 'Ann',
          'victim': 'Cara',
        });
        await t.capture(mover: 0, victims: <int>[2]);
        await t.squares(6);
        expect(
          t.said,
          equals(<String>[line]),
          reason: t.s.why('one Arabic announcement "$line"; said: ${t.said}'),
        );
        expect(
          t.saidDirections.single,
          TextDirection.rtl.index,
          reason: t.s.why('an Arabic announcement carries RTL'),
        );
        expect(
          t.sounds('capture_seen'),
          hasLength(1),
          reason: t.s.why('the sound does not depend on the language'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('sound switch off: the line is still said, nothing sounds', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 line independent of the sound switch',
        me: 1,
        sound: false,
        seats: _trio(<int, List<int>>{0: _moverTokens, 2: _victimTokens}),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2]);
        await t.squares(6);
        expect(
          t.allSounds,
          isEmpty,
          reason: t.s.why('sound off: no channel call at all'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enSeen, <String, String>{
              'capturer': 'Ann',
              'victim': 'Cara',
            }),
          ]),
          reason: t.s.why('the announcement does not hang on the sound switch'),
        );
      } finally {
        await t.release();
      }
    });
  });

  group('GameScreen: the other two roles at a three-seat table', () {
    testWidgets('I am captured: capturedMe alone, named, no captureSeen', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 capturedMe at three seats',
        me: 1,
        seats: _trio(<int, List<int>>{0: _moverTokens, 1: _victimTokens}),
      );
      try {
        await t.capture(mover: 0, victims: <int>[1]);
        await t.squares(6);
        expect(
          t.cueIds,
          equals(<String>['captured_me']),
          reason: t.s.why('I feel the capture of me, not the heard one'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enMeNamed, <String, String>{'name': 'Ann'}),
          ]),
          reason: t.s.why('one line naming the mover; said: ${t.said}'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('I capture: capturedOther alone, naming the victim', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 capturedOther at three seats',
        me: 1,
        seats: _trio(<int, List<int>>{1: _moverTokens, 2: _victimTokens}),
      );
      try {
        await t.capture(mover: 1, victims: <int>[2]);
        await t.squares(6);
        expect(
          t.cueIds,
          equals(<String>['captured_other']),
          reason: t.s.why('my own capture, no captureSeen beside it'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enOtherNamed, <String, String>{'name': 'Cara'}),
          ]),
          reason: t.s.why('one line naming the victim; said: ${t.said}'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('Arabic: the named lines for my capture and for mine taken', (
      tester,
    ) async {
      final _Table mine = await _sit(
        tester,
        'D3 ar capturedOther',
        me: 1,
        locale: const Locale('ar'),
        seats: _trio(<int, List<int>>{1: _moverTokens, 2: _victimTokens}),
      );
      try {
        await mine.capture(mover: 1, victims: <int>[2]);
        await mine.squares(6);
        expect(
          mine.said,
          equals(<String>[
            _fill(_arOtherNamed, <String, String>{'name': 'Cara'}),
          ]),
          reason: mine.s.why('ar: I captured Cara; said: ${mine.said}'),
        );
      } finally {
        await mine.release();
      }
    });

    testWidgets('Arabic: the named line when I am the one captured', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 ar capturedMe',
        me: 1,
        locale: const Locale('ar'),
        seats: _trio(<int, List<int>>{0: _moverTokens, 1: _victimTokens}),
      );
      try {
        await t.capture(mover: 0, victims: <int>[1]);
        await t.squares(6);
        expect(
          t.said,
          equals(<String>[
            _fill(_arMeNamed, <String, String>{'name': 'Ann'}),
          ]),
          reason: t.s.why('ar: Ann captured me; said: ${t.said}'),
        );
        expect(t.saidDirections.single, TextDirection.rtl.index);
      } finally {
        await t.release();
      }
    });
  });

  group('GameScreen: two seats', () {
    testWidgets('I capture: the line names the victim', (tester) async {
      final _Table t = await _sit(
        tester,
        'D3 two seats, I capture',
        me: 0,
        players: 2,
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Sam', tokens: _moverTokens),
          seatJson(1, name: 'Bob', tokens: _victimTokens),
        ],
      );
      try {
        await t.capture(mover: 0, victims: <int>[1]);
        await t.squares(6);
        expect(
          t.said,
          equals(<String>[
            _fill(_enOtherNamed, <String, String>{'name': 'Bob'}),
          ]),
          reason: t.s.why('"You captured Bob\'s token"; said: ${t.said}'),
        );
        expect(
          t.sounds('capture_seen'),
          isEmpty,
          reason: t.s.why('my own capture is not the heard-by-others cue'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('I am captured: the line names the mover', (tester) async {
      final _Table t = await _sit(
        tester,
        'D3 two seats, I am captured',
        me: 0,
        players: 2,
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Sam', tokens: _victimTokens),
          seatJson(1, name: 'Bob', tokens: _moverTokens),
        ],
      );
      try {
        await t.capture(mover: 1, victims: <int>[0]);
        await t.squares(6);
        expect(
          t.said,
          equals(<String>[
            _fill(_enMeNamed, <String, String>{'name': 'Bob'}),
          ]),
          reason: t.s.why('"Bob captured your token"; said: ${t.said}'),
        );
        expect(
          t.sounds('capture_seen'),
          isEmpty,
          reason: t.s.why('a capture of me is captured_me, not capture_seen'),
        );
      } finally {
        await t.release();
      }
    });
  });

  group('GameScreen: names come from the banner\'s map', () {
    testWidgets('two seats called Ann: the second reads "Ann 2"', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 duplicate names',
        me: 1,
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Ann', tokens: _moverTokens),
          seatJson(1, name: 'Sam', tokens: kYard),
          seatJson(2, name: 'Ann', tokens: _victimTokens),
        ],
      );
      try {
        await t.capture(mover: 0, victims: <int>[2]);
        await t.squares(6);
        expect(
          t.said,
          equals(<String>[
            _fill(_enSeen, <String, String>{
              'capturer': 'Ann',
              'victim': 'Ann 2',
            }),
          ]),
          reason: t.s.why(
            'seatDisplayNames numbers the second holder; the line must use '
            'the same label the banner draws. said: ${t.said}',
          ),
        );
      } finally {
        await t.release();
      }
    });
  });

  group('GameScreen: captured[0] is the victim named', () {
    testWidgets('four seats, seat 0 takes seat 2 and seat 3 at once: one '
        'sound, one line naming seat 2', (tester) async {
      final _Table t = await _sit(
        tester,
        'D3 victim is captured[0]',
        me: 1,
        players: 4,
        seats: quadSeats(
          mySeat: 1,
          tokens: <int, List<int>>{
            0: _moverTokens,
            2: _victimTokens,
            3: _victimTokens,
          },
        ),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2, 3]);
        await t.squares(6);
        expect(
          t.sounds('capture_seen'),
          hasLength(1),
          reason: t.s.why('one move, one sound, however many victims'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enSeen, <String, String>{
              'capturer': 'Ann',
              'victim': 'Cara',
            }),
          ]),
          reason: t.s.why('one line naming captured[0]; said: ${t.said}'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('four seats, seat 0 takes seat 2 and me: I am told I was '
        'captured, once, by Ann', (tester) async {
      final _Table t = await _sit(
        tester,
        'D2 a frame that hits me is mine',
        me: 1,
        players: 4,
        seats: quadSeats(
          mySeat: 1,
          tokens: <int, List<int>>{
            0: _moverTokens,
            1: _victimTokens,
            2: _victimTokens,
          },
        ),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2, 1]);
        await t.squares(6);
        expect(
          t.cueIds,
          equals(<String>['captured_me']),
          reason: t.s.why('capturedMe alone, no capture_seen beside it'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enMeNamed, <String, String>{'name': 'Ann'}),
          ]),
          reason: t.s.why('one line, the capture of me; said: ${t.said}'),
        );
      } finally {
        await t.release();
      }
    });
  });

  group('GameScreen: once per capture', () {
    testWidgets('two captures in a row make two sounds and two lines, in '
        'order', (tester) async {
      final _Table t = await _sit(
        tester,
        'D3 two captures',
        me: 1,
        seats: _trio(<int, List<int>>{
          0: _moverTokens,
          2: <int>[10, -1, 48, -1],
        }),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2]);
        await t.squares(6);
        await t.s.pump(const Duration(seconds: 3));
        await t.capture(
          mover: 2,
          victims: <int>[0],
          token: 0,
          from: 10,
          to: 13,
        );
        await t.squares(3);
        await t.s.pump(const Duration(seconds: 3));
        expect(
          t.sounds('capture_seen'),
          hasLength(2),
          reason: t.s.why('one sound per capture; sounds: ${t.allSounds}'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enSeen, <String, String>{
              'capturer': 'Ann',
              'victim': 'Cara',
            }),
            _fill(_enSeen, <String, String>{
              'capturer': 'Cara',
              'victim': 'Ann',
            }),
          ]),
          reason: t.s.why('two lines, first capture first; said: ${t.said}'),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('a move with no capture says nothing and sounds nothing', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D4 plain move of another seat',
        me: 1,
        seats: _trio(<int, List<int>>{0: _moverTokens}),
      );
      try {
        await t.capture(mover: 0, victims: const <int>[]);
        await t.squares(6);
        await t.s.pump(const Duration(seconds: 3));
        expect(
          t.allSounds,
          isEmpty,
          reason: t.s.why('no sound: ${t.allSounds}'),
        );
        expect(t.said, isEmpty, reason: t.s.why('no line: ${t.said}'));
      } finally {
        await t.release();
      }
    });
  });

  group('GameScreen: a name that cannot be resolved (D3 fallback)', () {
    testWidgets('my capture of a seat not in the room: the old unnamed line', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D3 fallback capturedOther',
        me: 0,
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Sam', tokens: kYard),
          seatJson(1, name: 'Bob', tokens: kYard),
        ],
      );
      try {
        await t.capture(mover: 0, victims: <int>[2], from: 5, to: 5);
        await t.s.pump(const Duration(seconds: 1));
        expect(
          t.said,
          equals(<String>[_enOtherUnnamed]),
          reason: t.s.why(
            'victim seat 2 is not in room.seats: announceCapturedOther '
            '("$_enOtherUnnamed"); said: ${t.said}',
          ),
        );
      } finally {
        await t.release();
      }
    });

    testWidgets('a capture of me by a seat not in the room: the old unnamed '
        'line', (tester) async {
      final _Table t = await _sit(
        tester,
        'D3 fallback capturedMe',
        me: 1,
        seats: <Map<String, Object?>>[
          seatJson(1, name: 'Sam', tokens: kYard),
          seatJson(2, name: 'Cara', tokens: kYard),
        ],
      );
      try {
        await t.capture(mover: 0, victims: <int>[1], from: 5, to: 5);
        await t.s.pump(const Duration(seconds: 1));
        expect(
          t.said,
          equals(<String>[_enMeUnnamed]),
          reason: t.s.why(
            'mover seat 0 is not in room.seats: announceCapturedMe '
            '("$_enMeUnnamed"); said: ${t.said}',
          ),
        );
      } finally {
        await t.release();
      }
    });

    for (final (String label, List<int> present) in <(String, List<int>)>[
      ('the mover is unknown', <int>[1, 2]),
      ('the victim is unknown', <int>[0, 1]),
    ]) {
      testWidgets('captureSeen, $label: still heard, nothing announced', (
        tester,
      ) async {
        final _Table t = await _sit(
          tester,
          'D3 fallback captureSeen ($label)',
          me: 1,
          seats: <Map<String, Object?>>[
            for (final int seat in present)
              seatJson(seat, name: seat == 1 ? 'Sam' : 'Other$seat'),
          ],
        );
        try {
          await t.capture(mover: 0, victims: <int>[2], from: 5, to: 5);
          await t.s.pump(const Duration(seconds: 1));
          expect(
            t.said,
            isEmpty,
            reason: t.s.why(
              'D3: a captureSeen whose name cannot be resolved announces '
              'nothing; said: ${t.said}',
            ),
          );
          expect(
            t.sounds('capture_seen'),
            hasLength(1),
            reason: t.s.why(
              'the sound is the cue, not the line; it still plays once '
              '(sounds: ${t.allSounds})',
            ),
          );
        } finally {
          await t.release();
        }
      });
    }
  });

  group('GameScreen: no travel, no hold (from == to)', () {
    testWidgets('capture_seen and its line arrive with the frame, once', (
      tester,
    ) async {
      final _Table t = await _sit(
        tester,
        'D2 immediate path',
        me: 1,
        seats: _trio(<int, List<int>>{0: _moverTokens, 2: _victimTokens}),
      );
      try {
        await t.capture(mover: 0, victims: <int>[2], from: 5, to: 5);
        await t.s.pump(const Duration(seconds: 3));
        expect(
          t.sounds('capture_seen'),
          hasLength(1),
          reason: t.s.why('one sound; sounds: ${t.allSounds}'),
        );
        expect(
          t.said,
          equals(<String>[
            _fill(_enSeen, <String, String>{
              'capturer': 'Ann',
              'victim': 'Cara',
            }),
          ]),
          reason: t.s.why('one line; said: ${t.said}'),
        );
      } finally {
        await t.release();
      }
    });
  });
}

// --- the screen fixture --------------------------------------------------------

const List<int> _moverTokens = <int>[3, -1, -1, -1];
const List<int> _victimTokens = <int>[-1, -1, 48, -1];
const Map<int, String> _names = <int, String>{0: 'Ann', 1: 'Sam', 2: 'Cara'};

List<Map<String, Object?>> _trio(Map<int, List<int>> tokens) =>
    <Map<String, Object?>>[
      for (int seat = 0; seat < 3; seat++)
        seatJson(seat, name: _names[seat]!, tokens: tokens[seat] ?? kYard),
    ];

/// Forwards each cue to the recording fake (cue order) and to the real
/// platform service (the channel calls a phone would receive).
class _Tee implements FeedbackService {
  _Tee(this.recording, this.platform);

  final RecordingFeedback recording;
  final PlatformFeedbackService platform;

  @override
  void play(FeedbackCue cue) {
    recording.play(cue);
    platform.play(cue);
  }
}

class _Table {
  _Table(this.s, this.platform, this._channelCalls, this._said, this._dirs);

  final Scn s;
  final PlatformFeedbackService platform;
  final List<MethodCall> _channelCalls;
  final List<String> _said;
  final List<int> _dirs;

  List<String> get said => List<String>.of(_said);
  List<int> get saidDirections => List<int>.of(_dirs);

  /// The cues played so far, by wire id. The step ticks of my own token and
  /// the gloat (D4: unchanged, and heard 250 ms after it shows) are left
  /// out; they are other rows of the table and other tests prove them.
  List<String> get cueIds => <String>[
    for (final FeedbackCue c in s.drive.feedback.recorded)
      if (c != FeedbackCue.step && c != FeedbackCue.gloat) c.id,
  ];

  List<String> get allSounds => <String>[
    for (final MethodCall c in _channelCalls)
      if (c.method == 'sound') (c.arguments as Map)['id']! as String,
  ];

  List<String> sounds(String id) =>
      allSounds.where((String s) => s == id).toList();

  List<String> get haptics => <String>[
    for (final MethodCall c in _channelCalls)
      if (c.method == 'haptic') (c.arguments as Map)['id']! as String,
  ];

  Future<void> capture({
    required int mover,
    required List<int> victims,
    int token = 0,
    int from = 3,
    int to = 9,
  }) async {
    await s.push(
      'moved',
      movedFrame(
        mover,
        token,
        from,
        to,
        captured: <Map<String, int>>[
          for (final int seat in victims)
            <String, int>{'seat': seat, 'token': 2},
        ],
      ),
    );
    await tester.pump();
  }

  WidgetTester get tester => s.tester;

  Future<void> squares(int count) async {
    for (int i = 0; i < count; i++) {
      await s.pump(kTokenStepDuration);
    }
    await tester.pump();
  }

  Future<void> release() async {
    platform.dispose();
    await releaseGame(tester, s.drive);
  }
}

Future<_Table> _sit(
  WidgetTester tester,
  String name, {
  required int me,
  required List<Map<String, Object?>> seats,
  int players = 3,
  Locale locale = const Locale('en'),
  bool sound = true,
}) async {
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: null,
    seats: seats,
    mySeat: me,
    players: players,
  );
  const MethodChannel channel = MethodChannel('app.fayad.ludo/feedback');
  final List<MethodCall> channelCalls = <MethodCall>[];
  final List<String> said = <String>[];
  final List<int> dirs = <int>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
    channelCalls.add(call);
    return null;
  });
  messenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        said.add(data['message'] as String);
        dirs.add(data['textDirection'] as int);
      }
      return null;
    },
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    );
  });
  final PlatformFeedbackService platform = PlatformFeedbackService(
    FeedbackSettings.forTest(sound: sound),
    channel,
  );
  await tester.pumpWidget(
    rollTrayHarness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(sound: sound),
        service: _Tee(drive.feedback, platform),
        child: GameScreen(controller: drive.controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Table(Scn(name, tester, drive), platform, channelCalls, said, dirs);
}
