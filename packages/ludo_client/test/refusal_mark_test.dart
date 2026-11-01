// Screen proof for C-520 D3: every refused tap is seen, with motion on or
// off. Written from work/ludo/orders/C-520-sweep36-refusals.md alone; the
// implementation (order 521) was being written in another tree and has not
// been read.
//
// The five refused objects: the die when it is not my turn, a token with no
// legal move, the hint control when it is spent or not my turn, the resting
// chat button, and a resting end card reply chip. Under
// `MediaQuery.disableAnimationsOf` each refused tap shows exactly one
// `RefusalMark` over the tapped object for 300 ms and then removes it; with
// motion on none is ever shown; a legal tap never shows one.
//
// A real GameScreen over a real RoomController on FakeTransport, every state
// a decoded wire frame. Time is the widget test's fake clock, driven by
// `tester.pump(duration)` (the way hint_control_test.dart and the end card
// tests drive it). Instants below are measured from the frame the tap was
// flushed on. The surface is 360x800 at pixel ratio 1. Reduced motion is
// `disableAnimations` on the MediaQuery the harness wraps the app in
// (mountGame's `disableAnimations`).
//
// This file does not compile on a tree without lib/src/refusal_mark.dart
// (RefusalMark, C-520 D3); that is the expected failing arm on the base. On
// the base the motion-off cases would fail anyway because no mark is shown at
// all (die: game_die.dart:248, token: board.dart:2693, hint:
// hint_button.dart:304, chip: end_card.dart:1051, chat button:
// game_screen.dart:1392 plays the cue and nothing else).
//
// Every failure reason starts with the scenario name and ends with the frames
// and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - "Covers the object's painted bounds" is checked only as the order
//     asks: the mark's rect contains the tapped object's centre. The object's
//     centre is the centre of its keyed widget (`game-die`,
//     `board-token-hit-0-0`, `game-hint-button`, `game-chat-button`,
//     `end-card-reply-revenge`).
//   - "Restarts it" is read as: the mark ends 300 ms after the latest refused
//     tap, so a second tap at 200 ms ends it at 500 ms. It is asserted present
//     at 450 ms and absent at 560 ms.
//   - "Does not move, fade or scale" is read as: the same rect at 0 and 250
//     ms, and no Opacity above it below 1.
//   - The chat button's motion-on shake is read as a visible horizontal
//     displacement of the keyed button inside the 300 ms (more than 1 dp at
//     some 25 ms sample) that is back at rest by 350 ms. The amplitude itself
//     is not pinned beyond that.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/refusal_mark.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const String _game1 = 'game-0001';

/// Seat 1 is Bob in twoSeats(); seat 2 is Bob in pairSeats().
const List<int> _bob = <int>[1, -1, -1, -1];

/// One mounted scenario: the object to refuse, how to let go of the screen,
/// and the pumps and taps run so far.
class _Ctx {
  _Ctx(this.name, this.tester, this.target, this.release);

  final String name;
  final WidgetTester tester;
  final Finder target;
  final Future<void> Function() release;
  final List<String> steps = <String>[];

  String why(String expected) =>
      '$name | expected: $expected | marks on screen: $marks | replay: '
      '${steps.join(' > ')}';

  int get marks => find.byType(RefusalMark).evaluate().length;

  Offset get centre => tester.getCenter(target);

  Future<void> tap() async {
    steps.add('tap');
    await tester.tap(target, warnIfMissed: false);
    await tester.pump();
  }

  Future<void> pump(int ms) async {
    steps.add('pump ${ms}ms');
    await tester.pump(Duration(milliseconds: ms));
  }

  void expectMarks(int count, String when) {
    expect(marks, count, reason: why('$count RefusalMark $when'));
  }

  /// The one mark, after checking there is exactly one.
  Rect markRect(String when) {
    expectMarks(1, when);
    return tester.getRect(find.byType(RefusalMark));
  }
}

String _mode(bool reduced) => reduced ? 'motion off' : 'motion on';

double _opacityAbove(Element element) {
  double alpha = 1.0;
  element.visitAncestorElements((Element e) {
    if (e is RenderObjectElement) {
      final RenderObject r = e.renderObject;
      if (r is RenderOpacity) {
        alpha *= r.opacity;
      } else if (r is RenderAnimatedOpacity) {
        alpha *= r.opacity.value;
      }
    }
    return true;
  });
  return alpha;
}

/// Lets the screen's storage read finish, then a few frames (as
/// hint_control_test.dart's flush does).
Future<void> _flush(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// ---------------------------------------------------------------------
// The fixtures: one per refused object.
// ---------------------------------------------------------------------

typedef _Open = Future<_Ctx> Function(WidgetTester tester, bool reduced);

/// The die, on Bob's turn.
Future<_Ctx> _openDie(WidgetTester tester, bool reduced) async {
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: awaitRollTurn(2),
    seats: pairSeats(mySeat: 0),
  );
  await mountGame(tester, drive, disableAnimations: reduced);
  return _Ctx(
    'die, not my turn, ${_mode(reduced)}',
    tester,
    find.byKey(bigDieKey),
    () => releaseGame(tester, drive),
  );
}

/// Token 0, with no legal move: my await_move, value 4, legal tokens 1 and 2.
Future<_Ctx> _openToken(WidgetTester tester, bool reduced) async {
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turnJson(
      seat: 0,
      phase: 'await_move',
      k: 1,
      value: 4,
      legal: const <int>[1, 2],
    ),
    seats: twoSeats(mine: const <int>[3, 10, 20, 30]),
  );
  await mountGame(tester, drive, disableAnimations: reduced);
  await tester.pump(const Duration(milliseconds: 100));
  final _Ctx ctx = _Ctx(
    'token with no legal move, ${_mode(reduced)}',
    tester,
    find.byKey(tokenHitKey(0, 0)),
    () => releaseGame(tester, drive),
  );
  expect(ringedTokens(tester), <int>[
    1,
    2,
  ], reason: ctx.why('fixture: tokens 1 and 2 are ringed, token 0 is not'));
  return ctx;
}

/// A hint control that is waiting: Bob to roll.
Future<_Ctx> _openHintNotMyTurn(WidgetTester tester, bool reduced) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turnJson(seat: 1, phase: 'await_roll', k: 2, queue: const <int>[]),
    seats: twoSeats(mine: const <int>[16, 18, -1, -1], other: _bob),
    gameId: _game1,
  );
  await mountGame(tester, drive, disableAnimations: reduced);
  await _flush(tester);
  final _Ctx ctx = _Ctx(
    'hint, not my turn, ${_mode(reduced)}',
    tester,
    find.byKey(hintButtonKey),
    () => releaseGame(tester, drive),
  );
  expect(
    find.byKey(hintWaitingKey),
    findsOneWidget,
    reason: ctx.why('fixture: the hint is waiting'),
  );
  return ctx;
}

/// A hint control that is spent: my await_move, the game's id already stored.
Future<_Ctx> _openHintSpent(WidgetTester tester, bool reduced) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    hintUsedPrefsKey: _game1,
  });
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turnJson(seat: 0, phase: 'await_move', k: 2, value: 5, legal: [0, 1]),
    seats: twoSeats(mine: const <int>[16, 18, -1, -1], other: _bob),
    gameId: _game1,
  );
  await mountGame(tester, drive, disableAnimations: reduced);
  await _flush(tester);
  final _Ctx ctx = _Ctx(
    'hint, spent, ${_mode(reduced)}',
    tester,
    find.byKey(hintButtonKey),
    () => releaseGame(tester, drive),
  );
  expect(
    find.byKey(hintUsedKey),
    findsOneWidget,
    reason: ctx.why('fixture: the hint is spent'),
  );
  return ctx;
}

/// Opens the sheet, picks [id] and has the server copy come back.
Future<void> _sendAcked(EndGame g, String id) async {
  final int before = g.sentCount;
  g.s.steps.add('tap game-chat-button, pick $id');
  await g.tester.tap(find.byKey(kChatButtonKey));
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 400));
  await g.tester.tap(find.byKey(sheetChipKey(id)));
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 400));
  await g.answerEmote(before, id: id);
}

/// The chat button, 300 ms after an ack: resting.
Future<_Ctx> _openChatButton(WidgetTester tester, bool reduced) async {
  final EndGame g = await openPlaying(
    tester,
    'chat button, resting, ${_mode(reduced)}',
    reduced: reduced,
  );
  await _sendAcked(g, 'hi');
  await g.s.pump(const Duration(milliseconds: 300));
  return _Ctx(g.s.name, tester, find.byKey(kChatButtonKey), g.done);
}

/// A reply chip on the loser card, 300 ms after an ack: resting.
Future<_Ctx> _openChip(WidgetTester tester, bool reduced) async {
  final EndGame g = await openFinished(
    tester,
    'end card reply chip, resting, ${_mode(reduced)}',
    reduced: reduced,
  );
  final int before = g.sentCount;
  await tapReply(g, 'good_game');
  await g.answerEmote(before, id: 'good_game');
  await g.s.pump(const Duration(milliseconds: 300));
  return _Ctx(g.s.name, tester, find.byKey(replyKey('revenge')), g.done);
}

const List<(String, _Open)> _refused = <(String, _Open)>[
  ('the die when it is not my turn', _openDie),
  ('a token with no legal move', _openToken),
  ('the hint when it is not my turn', _openHintNotMyTurn),
  ('the hint when it is spent', _openHintSpent),
  ('the resting chat button', _openChatButton),
  ('a resting end card reply chip', _openChip),
];

void main() {
  setUpAll(loadAppFonts);

  // -------------------------------------------------------------------
  // Motion off: the mark.
  // -------------------------------------------------------------------
  for (final (String, _Open) row in _refused) {
    testWidgets('motion off: a refused tap on ${row.$1} shows exactly one '
        'RefusalMark over it, present at 250 ms, absent at 350 ms', (
      tester,
    ) async {
      final _Ctx c = await row.$2(tester, true);
      try {
        final Offset centre = c.centre;
        c.expectMarks(0, 'before the tap');
        await c.tap();
        final Rect first = c.markRect('on the frame of the tap');
        expect(
          first.contains(centre),
          isTrue,
          reason: c.why(
            'the mark $first contains the tapped object\'s centre $centre',
          ),
        );
        await c.pump(250);
        final Rect later = c.markRect('at 250 ms');
        expect(
          later.contains(centre),
          isTrue,
          reason: c.why('at 250 ms the mark $later contains the centre'),
        );
        for (final (String, double, double) edge in <(String, double, double)>[
          ('left', first.left, later.left),
          ('top', first.top, later.top),
          ('right', first.right, later.right),
          ('bottom', first.bottom, later.bottom),
        ]) {
          expect(
            edge.$3,
            closeTo(edge.$2, 0.01),
            reason: c.why(
              'the mark does not move or scale: its ${edge.$1} edge was '
              '${edge.$2} and is ${edge.$3} at 250 ms',
            ),
          );
        }
        expect(
          _opacityAbove(tester.element(find.byType(RefusalMark))),
          closeTo(1.0, 1e-9),
          reason: c.why('the mark does not fade: no Opacity above it'),
        );
        await c.pump(100);
        c.expectMarks(0, 'at 350 ms');
        await c.pump(1000);
        c.expectMarks(0, 'at 1450 ms, and it does not come back');
        expect(tester.takeException(), isNull, reason: c.why('nothing thrown'));
      } finally {
        await c.release();
      }
    });

    testWidgets('motion off: a second refused tap on ${row.$1} at 200 ms '
        'restarts the mark, still exactly one, present at 450 ms', (
      tester,
    ) async {
      final _Ctx c = await row.$2(tester, true);
      try {
        await c.tap();
        c.expectMarks(1, 'after the first tap');
        await c.pump(200);
        c.expectMarks(1, 'at 200 ms, before the second tap');
        await c.tap();
        c.expectMarks(1, 'on the second tap: never more than one');
        await c.pump(250);
        final Rect rect = c.markRect('at 450 ms, 250 ms after the second tap');
        expect(
          rect.contains(c.centre),
          isTrue,
          reason: c.why('the restarted mark $rect contains the centre'),
        );
        await c.pump(110);
        c.expectMarks(0, 'at 560 ms, 360 ms after the second tap');
      } finally {
        await c.release();
      }
    });

    testWidgets('motion on: a refused tap on ${row.$1} shows no RefusalMark '
        'at any time', (tester) async {
      final _Ctx c = await row.$2(tester, false);
      try {
        await c.tap();
        c.expectMarks(0, 'on the frame of the tap');
        for (int i = 0; i < 14; i++) {
          await c.pump(25);
          c.expectMarks(0, 'at ${25 * (i + 1)} ms');
        }
        await c.tap();
        await c.pump(100);
        c.expectMarks(0, 'after a second refused tap');
        expect(tester.takeException(), isNull, reason: c.why('nothing thrown'));
      } finally {
        await c.release();
      }
    });
  }

  // -------------------------------------------------------------------
  // Legal taps never show one.
  // -------------------------------------------------------------------
  for (final bool reduced in const <bool>[true, false]) {
    testWidgets('${_mode(reduced)}: a legal tap on the die on my turn shows '
        'no RefusalMark', (tester) async {
      phoneSurface(tester);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: awaitRollTurn(0),
        seats: pairSeats(mySeat: 0),
      );
      await mountGame(tester, drive, disableAnimations: reduced);
      final _Ctx c = _Ctx(
        'die, my turn, ${_mode(reduced)}',
        tester,
        find.byKey(bigDieKey),
        () => releaseGame(tester, drive),
      );
      try {
        final int sent = drive.transport.sentRaw.length;
        await c.tap();
        expect(
          sentTypesSince(drive.transport, sent),
          contains('roll'),
          reason: c.why('fixture: the tap was a legal roll, a roll went out'),
        );
        for (final int ms in const <int>[0, 100, 150]) {
          await c.pump(ms);
          c.expectMarks(0, 'a legal die tap, after $ms more ms');
        }
      } finally {
        await c.release();
      }
    });

    testWidgets('${_mode(reduced)}: a legal tap on a ringed token shows no '
        'RefusalMark', (tester) async {
      final _Ctx c = await _openToken(tester, reduced);
      try {
        final Finder legal = find.byKey(tokenHitKey(0, 1));
        final _Ctx onLegal = _Ctx(
          'ringed token 1, ${_mode(reduced)}',
          tester,
          legal,
          c.release,
        );
        await onLegal.tap();
        for (final int ms in const <int>[0, 100, 150]) {
          await onLegal.pump(ms);
          onLegal.expectMarks(0, 'a legal token tap, after $ms more ms');
        }
      } finally {
        await c.release();
      }
    });

    testWidgets('${_mode(reduced)}: a tap on a ready hint spends it and '
        'shows no RefusalMark', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      phoneSurface(tester);
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 2,
          value: 5,
          legal: const <int>[0, 1],
        ),
        seats: twoSeats(mine: const <int>[16, 18, -1, -1], other: _bob),
        gameId: _game1,
      );
      await mountGame(tester, drive, disableAnimations: reduced);
      await _flush(tester);
      final _Ctx c = _Ctx(
        'hint, ready, ${_mode(reduced)}',
        tester,
        find.byKey(hintButtonKey),
        () => releaseGame(tester, drive),
      );
      try {
        expect(
          find.byKey(hintReadyKey),
          findsOneWidget,
          reason: c.why('fixture: the hint is ready'),
        );
        await c.tap();
        for (final int ms in const <int>[0, 100, 150]) {
          await c.pump(ms);
          c.expectMarks(0, 'a legal hint tap, after $ms more ms');
        }
        expect(
          find.byKey(hintUsedKey),
          findsOneWidget,
          reason: c.why('fixture: the tap spent the hint, so it was legal'),
        );
      } finally {
        await c.release();
      }
    });
  }

  testWidgets('a legal tap on the chat button when it is ready shows no '
      'RefusalMark with motion off', (tester) async {
    final EndGame g = await openPlaying(
      tester,
      'chat button, ready, motion off',
      reduced: true,
    );
    final _Ctx c = _Ctx(g.s.name, tester, find.byKey(kChatButtonKey), g.done);
    try {
      await c.tap();
      await c.pump(100);
      expect(
        find.byKey(kSheetKey),
        findsOneWidget,
        reason: c.why('fixture: the tap was legal, the sheet opened'),
      );
      c.expectMarks(0, 'a legal chat button tap');
    } finally {
      await c.release();
    }
  });

  // -------------------------------------------------------------------
  // Motion on: the chat button gains the hint's shake.
  // -------------------------------------------------------------------
  testWidgets('motion on: a refused tap on the resting chat button shakes it '
      'for 300 ms and it is back at rest by 350 ms', (tester) async {
    final _Ctx c = await _openChatButton(tester, false);
    try {
      final double rest = tester.getCenter(c.target).dx;
      await c.tap();
      double widest = (tester.getCenter(c.target).dx - rest).abs();
      for (int i = 0; i < 12; i++) {
        await c.pump(25);
        widest = widest < (tester.getCenter(c.target).dx - rest).abs()
            ? (tester.getCenter(c.target).dx - rest).abs()
            : widest;
      }
      expect(
        widest,
        greaterThan(1.0),
        reason: c.why(
          'the button moved sideways during the 300 ms; the widest '
          'displacement from $rest was $widest dp',
        ),
      );
      await c.pump(50);
      expect(
        tester.getCenter(c.target).dx,
        closeTo(rest, 0.01),
        reason: c.why('back at rest ($rest) by 350 ms'),
      );
    } finally {
      await c.release();
    }
  });

  testWidgets('motion off: a refused tap on the resting chat button does not '
      'move it', (tester) async {
    final _Ctx c = await _openChatButton(tester, true);
    try {
      final Offset rest = tester.getCenter(c.target);
      await c.tap();
      for (int i = 0; i < 12; i++) {
        await c.pump(25);
        expect(
          tester.getCenter(c.target),
          rest,
          reason: c.why('the button stays put, the mark carries the refusal'),
        );
      }
    } finally {
      await c.release();
    }
  });

  testWidgets('invalidTap is played once per refused tap on the resting chat '
      'button, with motion on and off', (tester) async {
    for (final bool reduced in const <bool>[false, true]) {
      final EndGame g = await openPlaying(
        tester,
        'invalidTap count, ${_mode(reduced)}',
        reduced: reduced,
      );
      try {
        await _sendAcked(g, 'hi');
        await g.s.pump(const Duration(milliseconds: 300));
        final int cues = g.s.count(FeedbackCue.invalidTap);
        await tester.tap(find.byKey(kChatButtonKey));
        await tester.pump();
        await g.s.pump(const Duration(milliseconds: 50));
        expect(
          g.s.count(FeedbackCue.invalidTap),
          cues + 1,
          reason: g.why(
            'one invalidTap for one refused tap, ${_mode(reduced)}',
          ),
        );
      } finally {
        await g.done();
      }
    }
  });
}
