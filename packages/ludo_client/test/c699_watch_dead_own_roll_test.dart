// Screen proof for work/ludo/orders/699-x220-watch-dead-yields-to-own-roll.md
// (C-699t). From the moment this device's own throw lands, no other seat's
// watcher dead line is shown: a showing line is dropped at once, a pending
// one (armed for a throw still in the air) is never shown later. The X153
// hold for a watcher who does not roll is unchanged (row D).
//
// Two seats, this device is seat 0 (Priya), the other is seat 2 (Karim). A
// GameScreen over a real RoomController on FakeTransport; every state arrives
// as a decoded wire frame. The rig is copied from watcher_dead_roll_test.dart.
//
// Rows, each in en and ar:
//   A  the line is showing when my throw arrives and lands
//   B  my throw arrives while Karim's throw is still in the air
//   C  as A with Karim's three sixes
//   D  control: no roll from me, the line holds the full 1500 ms and drops
//
// Every failure reason names the row, the locale and the times, and ends with
// the frames and pumps that led to it. The rows are deterministic, so the
// scenario is the whole reproduction; there is no seed.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/roll_tray_harness.dart';

const Duration _kFrame = Duration(milliseconds: 16);

/// The hold from the contract: `_noMoveHold`, 1500 ms.
const int _kHoldMs = 1500;

/// How long the line must stay away after my throw has landed.
const int _kQuietMs = 2000;

const Key _otherNoticeKey = Key('game-no-move-other-notice');

const List<int> _yard = <int>[-1, -1, -1, -1];

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

String _noMoveOther(Locale locale) => locale.languageCode == 'ar'
    ? 'Karim: لا حركة بهذه الرمية'
    : 'Karim: no move with this roll';

String _threeSixesOther(Locale locale) => locale.languageCode == 'ar'
    ? 'Karim: ثلاث ستّات متتالية. انتهى الدور.'
    : 'Karim: three sixes in a row. Turn over.';

class _Scn {
  _Scn(this.name, this.tester, this.drive);

  final String name;
  final WidgetTester tester;
  final RollTrayDrive drive;
  final List<String> steps = <String>[];

  /// Milliseconds pumped since the scenario began.
  int clockMs = 0;

  String why(String expected) =>
      '$name | t=${clockMs}ms | expected: $expected | '
      'replay: ${steps.join(' > ')}';

  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add('$type ${jsonEncode(data)}');
    await drive.push(tester, type, data);
  }

  Future<void> pump(int ms) async {
    steps.add('pump ${ms}ms');
    int elapsed = 0;
    while (elapsed < ms) {
      final int step = ms - elapsed < 16 ? ms - elapsed : 16;
      await tester.pump(Duration(milliseconds: step));
      elapsed += step;
      clockMs += step;
    }
  }

  /// Pumps one frame at a time until [until] holds; [each] sees every frame
  /// before that one. Returns the frames' elapsed ms, or -1 at [limitMs].
  Future<int> frames({
    required int limitMs,
    required bool Function() until,
    void Function(int ms)? each,
  }) async {
    int elapsed = 0;
    while (elapsed < limitMs) {
      await tester.pump(_kFrame);
      elapsed += 16;
      clockMs += 16;
      if (until()) {
        steps.add('frames ${elapsed}ms until the condition held');
        return elapsed;
      }
      each?.call(elapsed);
    }
    steps.add('frames ${elapsed}ms, the condition never held');
    return -1;
  }

  /// Pumps [ms] one frame at a time and runs [check] after every frame.
  Future<void> watch(int ms, void Function(int ms) check) async {
    steps.add('watch ${ms}ms');
    int elapsed = 0;
    while (elapsed < ms) {
      await tester.pump(_kFrame);
      elapsed += 16;
      clockMs += 16;
      check(elapsed);
    }
  }
}

List<Map<String, Object?>> _seats() => <Map<String, Object?>>[
  seatJson(0, name: 'Priya', tokens: const <int>[10, -1, -1, -1]),
  seatJson(2, name: 'Karim', tokens: _yard),
];

Map<String, Object?> _turnFrame(int seat, {List<int> queue = const <int>[]}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': queue,
    };

Map<String, Object?> _rolled(
  int seat,
  int value,
  int k, {
  List<int> legal = const <int>[],
  List<int> queue = const <int>[],
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': queue,
};

Future<void> _karimDead(_Scn s) async {
  await s.push('rolled', _rolled(2, 3, 1));
  await s.push('turn_passed', <String, Object?>{
    'seat': 2,
    'reason': 'no_legal_move',
  });
  await s.push('turn', _turnFrame(0));
}

Future<void> _karimThreeSixes(_Scn s) async {
  await s.push('rolled', _rolled(2, 6, 1, queue: const <int>[6]));
  await s.push('turn', _turnFrame(2, queue: const <int>[6]));
  await s.push('rolled', _rolled(2, 6, 2, queue: const <int>[6, 6]));
  await s.push('turn', _turnFrame(2, queue: const <int>[6, 6]));
  await s.push('rolled', _rolled(2, 6, 3));
  await s.push('turn_passed', <String, Object?>{
    'seat': 2,
    'reason': 'three_sixes',
  });
  await s.push('turn', _turnFrame(0));
}

/// My own throw: a 5 with token 0 legal, as the server frames it.
Future<void> _myRoll(_Scn s) async {
  await s.push('rolled', _rolled(0, 5, 1, legal: const <int>[0]));
  await s.push(
    'turn',
    turnJson(
      seat: 0,
      phase: 'await_move',
      k: 1,
      value: 5,
      legal: const <int>[0],
      queue: const <int>[5],
      legalByFace: <Map<String, Object?>>[
        faceLegal(5, const <int>[0]),
      ],
    ),
  );
}

bool _noticeUp(WidgetTester tester) => tester.any(find.byKey(_otherNoticeKey));

bool _myFaceUp(WidgetTester tester) => tester.any(
  find.descendant(
    of: find.byKey(bigDieKey),
    matching: find.byKey(bigFaceKey(5)),
  ),
);

String? _noticeText(WidgetTester tester) {
  final Finder f = find.byKey(_otherNoticeKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  final Text text = tester.widget<Text>(f);
  return text.data ?? text.textSpan?.toPlainText();
}

Future<RollTrayDrive> _mount(WidgetTester tester, Locale locale) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turnJson(seat: 2, phase: 'await_roll', k: 0, queue: const <int>[]),
    seats: _seats(),
    mySeat: 0,
    players: 2,
  );
  await mountGame(tester, drive, locale: locale);
  return drive;
}

void _expectAbsent(_Scn s, WidgetTester tester, String when) {
  expect(
    _noticeUp(tester),
    isFalse,
    reason: s.why(
      'game-no-move-other-notice absent $when, but it shows '
      '"${_noticeText(tester)}"',
    ),
  );
}

void main() {
  for (final Locale locale in _locales) {
    final String lang = locale.languageCode;

    // A: the line is showing when my throw arrives.
    testWidgets('C-699t row A ($lang): Karim dead roll line showing, my own '
        'throw lands: the line is gone at once and stays gone 2 s', (
      tester,
    ) async {
      final RollTrayDrive drive = await _mount(tester, locale);
      final _Scn s = _Scn(
        'row A, $lang, Karim dead 3 then my 5',
        tester,
        drive,
      );
      try {
        await _karimDead(s);
        final int shown = await s.frames(
          limitMs: 1500,
          until: () => _noticeUp(tester),
        );
        expect(
          shown,
          isNot(-1),
          reason: s.why('the line appears when Karim\'s die lands (fixture)'),
        );
        expect(
          _noticeText(tester),
          _noMoveOther(locale),
          reason: s.why('text'),
        );
        await s.pump(400);
        expect(
          _noticeUp(tester),
          isTrue,
          reason: s.why('fixture: the line still up 400 ms in, inside hold'),
        );
        await _myRoll(s);
        final int landed = await s.frames(
          limitMs: 3000,
          until: () => _myFaceUp(tester),
        );
        expect(
          landed,
          isNot(-1),
          reason: s.why('my throw lands: game-die-face-5 shows in game-die'),
        );
        _expectAbsent(s, tester, 'on the frame my throw landed');
        await s.watch(
          _kQuietMs,
          (int ms) => _expectAbsent(s, tester, '${ms}ms after my landing'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    // B: my throw arrives while Karim's is still in the air.
    testWidgets('C-699t row B ($lang): my own throw arrives while Karim\'s '
        'throw is in the air: his line never shows', (tester) async {
      final RollTrayDrive drive = await _mount(tester, locale);
      final _Scn s = _Scn(
        'row B, $lang, Karim dead 3 then my 5',
        tester,
        drive,
      );
      try {
        await _karimDead(s);
        expect(
          find.byKey(opponentThrowKey(2)),
          findsOneWidget,
          reason: s.why('fixture: Karim\'s throw is still in the air'),
        );
        expect(
          _noticeUp(tester),
          isFalse,
          reason: s.why('fixture: no line before his landing'),
        );
        await _myRoll(s);
        final int landed = await s.frames(
          limitMs: 3000,
          until: () => _myFaceUp(tester),
          each: (int ms) =>
              _expectAbsent(s, tester, '${ms}ms after my roll arrived'),
        );
        expect(
          landed,
          isNot(-1),
          reason: s.why('my throw lands: game-die-face-5 shows in game-die'),
        );
        _expectAbsent(s, tester, 'on the frame my throw landed');
        await s.watch(
          _kQuietMs,
          (int ms) => _expectAbsent(s, tester, '${ms}ms after my landing'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    // C: three sixes.
    testWidgets('C-699t row C ($lang): Karim three sixes line showing, my own '
        'throw lands: the line is gone at once and stays gone 2 s', (
      tester,
    ) async {
      final RollTrayDrive drive = await _mount(tester, locale);
      final _Scn s = _Scn('row C, $lang, Karim 6 6 6 then my 5', tester, drive);
      try {
        await _karimThreeSixes(s);
        final int shown = await s.frames(
          limitMs: 4000,
          until: () => _noticeUp(tester),
        );
        expect(
          shown,
          isNot(-1),
          reason: s.why('the three-sixes line appears (fixture)'),
        );
        expect(
          _noticeText(tester),
          _threeSixesOther(locale),
          reason: s.why('text'),
        );
        await s.pump(400);
        expect(
          _noticeUp(tester),
          isTrue,
          reason: s.why('fixture: the line still up 400 ms in, inside hold'),
        );
        await _myRoll(s);
        final int landed = await s.frames(
          limitMs: 3000,
          until: () => _myFaceUp(tester),
        );
        expect(
          landed,
          isNot(-1),
          reason: s.why('my throw lands: game-die-face-5 shows in game-die'),
        );
        _expectAbsent(s, tester, 'on the frame my throw landed');
        await s.watch(
          _kQuietMs,
          (int ms) => _expectAbsent(s, tester, '${ms}ms after my landing'),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });

    // D: control, X153 kept.
    testWidgets('C-699t row D ($lang): no roll from me: the line holds the '
        'full $_kHoldMs ms and then drops', (tester) async {
      final RollTrayDrive drive = await _mount(tester, locale);
      final _Scn s = _Scn(
        'row D, $lang, Karim dead 3, no roll of mine',
        tester,
        drive,
      );
      try {
        await _karimDead(s);
        final int shown = await s.frames(
          limitMs: 1500,
          until: () => _noticeUp(tester),
        );
        expect(
          shown,
          isNot(-1),
          reason: s.why('the line appears when Karim\'s die lands'),
        );
        expect(
          _noticeText(tester),
          _noMoveOther(locale),
          reason: s.why('text'),
        );
        // One frame is already behind us; the hold is measured from here.
        await s.watch(_kHoldMs - 2 * 16, (int ms) {
          expect(
            _noticeUp(tester),
            isTrue,
            reason: s.why(
              'the line is up ${ms + 16}ms after its first frame, inside the '
              '$_kHoldMs ms hold',
            ),
          );
        });
        await s.pump(3 * 16);
        expect(
          _noticeUp(tester),
          isFalse,
          reason: s.why(
            'the line is gone within one frame of the $_kHoldMs ms hold',
          ),
        );
      } finally {
        await releaseGame(tester, drive);
      }
    });
  }
}
