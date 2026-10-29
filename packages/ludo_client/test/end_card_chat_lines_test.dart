// Screen proof for C-485 D6 items 5, 6, 7 and 8, amended by C-492 (order 494)
// and by C-500 (order 503). Written from those contracts and from C-478. The
// implementations were written in other trees and have not been read.
//
// Every case drives a real GameScreen over a real RoomController on
// FakeTransport (test/support/end_card_chat_harness.dart). State arrives as
// decoded wire frames. Time is measured from the frame the `emote` push was
// flushed on. The new widgets are reached by key only. The surface is
// 360x800 at pixel ratio 1 unless a case names another size.
//
// C-492 moves the one line into the header band and drops the EndCard
// overlay, so nothing here mounts EndCard(chatLines:). C-500 then makes that
// line the only one on every body: the board draws no bubble of its own
// (expectNoBoardChat), a line up in PLAYING is still up, same seat and text,
// on the end card and in a held end, and the room going to FINISHED does not
// clear it. The header row is the
// widest 48 dp-tall ancestor of game-screen-appbar-leave (the SizedBox under
// game-felt-edge). Geometry is that row's rect from getRect's own coordinate
// space, via the render box's localToGlobal.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
//
// Ambiguities, reported and not invented around:
//   - C-500 D4 gives the end-side inset 112 dp "when the header row carries
//     the chat button (connected and seated, as the button's own
//     condition)". C-478 D5.1 puts that button in PLAYING only (the sheet
//     test pins it absent in FINISHED and LOBBY), so the end card and
//     rematch LOBBY cases here keep C-492's 60 dp both sides. The 112 dp
//     placement is a PLAYING and held-end geometry and is proved in
//     quick_chat_board_test.dart; a carried-over line is only read by seat,
//     text and life here, not by rect while the board is the body.
//   - C-500 D3 says the PLAYING to FINISHED change does not clear the line
//     and lists what does clear it. The change to a rematch LOBBY is on
//     neither list, so no case asserts it either way (as before).
//   - D5.2 says the name is w700 and the line w500 but not what sits between
//     them; the text case requires two different spans, the name before the
//     line, and no particular separator.
//   - How the opacity is animated is not given. The measure multiplies every
//     Opacity / FadeTransition above the bubble's text. A fade done with a
//     colour alpha instead would read as 1.0 and fail the fade cases.
//   - D5.2 says "paper fill" and cites C-478 D5.4, whose amendment A1 makes
//     the fill paperElevated. The look case follows A1.
//   - The soft shadow of D5.2 is not asserted: it has no stable pixel to
//     read against the card behind it.
//   - A spectator seeing the lines is not asserted: D4 does not say.
//   - D4 does not say whether a line already up survives the LOBBY change to
//     a rematch LOBBY; the cases do not assert either way.
//   - Two emote frames pushed before one pump have no contract rule for
//     which is newer. That case asserts exactly one of the two seats, and
//     does not name which.
//   - The direct motion, reduced-motion and semantics cases duplicated the
//     GameScreen cases in group 7. Group 7 stays; the direct copies are not
//     repeated.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/net/snapshot.dart' show SeatState;
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const int _lifeMs = 2500;

/// (label, seat, id) pushes that are not a line: C-478 D5.4 by way of D4.
const List<(String, Object?, Object?)> _notALine = <(String, Object?, Object?)>[
  ('unknown id', 1, 'nope'),
  ('empty id', 1, ''),
  ('upper-case id', 1, 'HI'),
  ('the text instead of the id', 1, 'Hi all'),
  ('a padded id', 1, 'hi '),
  ('a seat that is in neither seat list', 2, 'hi'),
  ('seat out of range', 7, 'hi'),
  ('negative seat', -1, 'hi'),
  ('id of the wrong type', 1, 5),
  ('null id', 1, null),
  ('seat of the wrong type', '1', 'hi'),
  ('missing seat', null, 'hi'),
];

/// A first game's end card with a line on it: the control for the cases
/// that say "no line", which would pass on a tree that never draws any.
Future<void> _control(WidgetTester tester, String name) async {
  final EndGame c = await openFinished(tester, '$name (control)');
  try {
    await c.emote(1, 'good_game');
    _expectLine(c, 1, 'Bob', 'Good game');
  } finally {
    await c.done();
  }
}

/// The line [seat] shows: on screen, the name before the line.
void _expectLine(EndGame g, int seat, String name, String line) {
  expect(
    chatLineSeats(g.tester),
    contains(seat),
    reason: g.why('end-card-chat-$seat is on screen'),
  );
  final String text = textUnder(g.tester, find.byKey(chatLineKey(seat)));
  expect(
    text,
    contains(name),
    reason: g.why('end-card-chat-$seat names "$name", reads "$text"'),
  );
  expect(
    text,
    contains(line),
    reason: g.why('end-card-chat-$seat says "$line", reads "$text"'),
  );
  expect(
    text.indexOf(name),
    lessThan(text.lastIndexOf(line)),
    reason: g.why('the name comes before the line in "$text"'),
  );
}

void _expectNoLines(EndGame g, String what) {
  expect(
    chatLineSeats(g.tester),
    isEmpty,
    reason: g.why(
      '$what: no end-card-chat-<seat> (on screen: '
      '${chatLineSeats(g.tester)})',
    ),
  );
}

typedef _Sample = ({int t, double scale, double alpha});

/// Samples the first text of [root] every 5 ms from the first frame until
/// 2495 ms, or until it is gone. [base] is the settled width of that text.
Future<List<_Sample>> _trace(
  WidgetTester tester,
  Finder root,
  double base,
  Future<void> Function(Duration) advance,
) async {
  final List<_Sample> trace = <_Sample>[];
  int t = 0;
  while (t <= 2495 && tester.any(root)) {
    trace.add((
      t: t,
      scale: textWidthUnder(tester, root) / base,
      alpha: alphaUnder(tester, root),
    ));
    await advance(kC468Fine);
    t += kC468Fine.inMilliseconds;
  }
  return trace;
}

void _expectMotion(List<_Sample> trace, String Function(String) why) {
  final String sum =
      'first ${trace.first}, last ${trace.last}, ${trace.length} samples';
  expect(trace.first.t, 0, reason: why('sampled from the first frame'));
  expect(
    trace.first.scale,
    inInclusiveRange(0.55, 0.68),
    reason: why('starts at scale 0.6; $sum'),
  );
  expect(
    trace.firstWhere((_Sample e) => e.t >= 80).scale,
    greaterThan(trace.first.scale + 0.15),
    reason: why('grows through the entrance; $sum'),
  );
  for (final _Sample e in trace.where((_Sample e) => e.t <= 160)) {
    expect(
      e.scale,
      inInclusiveRange(0.55, 1.12),
      reason: why('entrance stays sane; sample $e'),
    );
  }
  for (final _Sample e in trace.where(
    (_Sample e) => e.t >= 175 && e.t <= 2490,
  )) {
    expect(
      e.scale,
      closeTo(1.0, 0.02),
      reason: why('full size after 160 ms; sample $e'),
    );
  }
  for (final _Sample e in trace.where((_Sample e) => e.t <= 2240)) {
    expect(
      e.alpha,
      closeTo(1.0, 0.01),
      reason: why('full opacity before the fade; sample $e'),
    );
  }
  double previous = 1.0;
  for (final _Sample e in trace.where((_Sample e) => e.t >= 2250)) {
    expect(
      e.alpha,
      lessThanOrEqualTo(previous + 0.01),
      reason: why('the fade never brightens; sample $e'),
    );
    previous = e.alpha;
  }
  final _Sample mid = trace.firstWhere((_Sample e) => e.t >= 2375);
  expect(
    mid.alpha,
    inInclusiveRange(0.15, 0.85),
    reason: why('half way through the fade it is half gone; sample $mid'),
  );
  expect(
    trace.last.alpha,
    lessThan(0.15),
    reason: why('nearly gone at the end of the fade; $sum'),
  );
}

const Key _leaveKey = Key('game-screen-appbar-leave');
const Key _settingsKey = Key('game-settings-button');
const Key _winnerKey = Key('game-screen-winner');
const Key _pipKey = Key('game-seat-pip-strip');
const Key _panelKey = Key('end-card-lose');

/// C-492 decision 6: `kSpace2 + 48 + kSpace1`.
const double _rowDp = 48;
const double _inset = kSpace2 + _rowDp + kSpace1;

/// Seat 0's name in the short-line cases, and how far under the maximum width
/// its bubble must stay.
const String _shortName = 'Jo';
const double _shortMargin = 40;

/// The header row: the widest ancestor of the leave button whose height is
/// the 48 dp row. Its rect is in the same space as [WidgetTester.getRect].
Rect _headerRow(WidgetTester tester) {
  final RenderBox leave = tester.renderObject<RenderBox>(find.byKey(_leaveKey));
  RenderBox? row;
  RenderObject? walker = leave;
  while (walker != null) {
    if (walker is RenderBox && (walker.size.height - _rowDp).abs() <= 0.5) {
      if (row == null || walker.size.width > row.size.width) {
        row = walker;
      }
    }
    walker = walker.parent;
  }
  expect(
    row,
    isNotNull,
    reason: 'a 48 dp ancestor of game-screen-appbar-leave',
  );
  return row!.localToGlobal(Offset.zero) & row.size;
}

/// The pixels of the screen, read at logical points (the surface is ratio 1).
class _Pixels {
  _Pixels(this.image, this.data, this.origin);

  final ui.Image image;
  final ByteData data;
  final Offset origin;

  static Future<_Pixels> of(WidgetTester tester, Finder anchor) async {
    final RenderObject start = tester.renderObject(anchor);
    RenderObject? walker = start;
    while (walker != null && walker is! RenderRepaintBoundary) {
      walker = walker.parent;
    }
    final RenderRepaintBoundary boundary = walker! as RenderRepaintBoundary;
    final ui.Image? image = await tester.runAsync<ui.Image>(
      () => boundary.toImage(),
    );
    final ByteData? data = await tester.runAsync<ByteData?>(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return _Pixels(image!, data!, boundary.localToGlobal(Offset.zero));
  }

  Color at(double x, double y) {
    final double lx = x - origin.dx;
    final double ly = y - origin.dy;
    final int i = (ly.floor() * image.width + lx.floor()) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }
}

bool _near(Color a, Color b, int tolerance) =>
    ((a.r - b.r).abs() * 255) <= tolerance &&
    ((a.g - b.g).abs() * 255) <= tolerance &&
    ((a.b - b.b).abs() * 255) <= tolerance;

/// True when [inner] lies inside [outer], edges included.
bool _within(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.01 &&
    inner.top >= outer.top - 0.01 &&
    inner.right <= outer.right + 0.01 &&
    inner.bottom <= outer.bottom + 0.01;

/// True when [target] is [ancestor] or sits below it in the render tree.
bool _isUnder(RenderObject target, RenderObject ancestor) {
  RenderObject? walker = target;
  while (walker != null) {
    if (identical(walker, ancestor)) {
      return true;
    }
    walker = walker.parent;
  }
  return false;
}

/// A short line in a header-band case: seat 0 gets a two-letter name and says
/// the shortest preset in either locale ("Oops", "أوبس"), so the bubble is its
/// own width. Asserts it is clearly under [maxWidth] and under the long
/// bubble [longWidth], with both measured widths in the reason.
Future<void> _expectShortIsShort(
  WidgetTester tester,
  EndGame g, {
  required bool ar,
  required double maxWidth,
  required double longWidth,
}) async {
  await g.emote(0, 'oops');
  await g.at(400);
  final Rect row = _headerRow(tester);
  final Rect short = tester.getRect(find.byKey(chatLineKey(0)));
  _expectLine(g, 0, _shortName, endLine('oops', ar: ar));
  expect(
    short.width,
    lessThan(maxWidth - _shortMargin),
    reason: g.why(
      'a short line is its own width, not the maximum: short bubble '
      '${short.width} dp, long bubble $longWidth dp, max $maxWidth dp, '
      'margin $_shortMargin dp',
    ),
  );
  expect(
    short.width,
    lessThan(longWidth - _shortMargin),
    reason: g.why(
      'the short bubble ${short.width} dp is narrower than the long one '
      '$longWidth dp by at least $_shortMargin dp',
    ),
  );
  _expectInsideInsets(g, short, row);
}

/// C-492 decision 6 at text scale 1.0: the whole bubble sits in the row,
/// centred vertically when it fits.
void _expectInRow(EndGame g, Rect bubble, Rect row) {
  final double expectedTop =
      row.top + math.max(0, (_rowDp - bubble.height) / 2);
  expect(
    bubble.top,
    closeTo(expectedTop, 0.5),
    reason: g.why('the bubble top follows the row: bubble $bubble, row $row'),
  );
  expect(
    bubble.bottom,
    lessThanOrEqualTo(row.bottom + 0.5),
    reason: g.why('at text scale 1.0 the bubble stays inside the row'),
  );
  expect(
    bubble.center.dx,
    closeTo(row.center.dx, 1),
    reason: g.why('the bubble is centred on the header row'),
  );
}

void _expectInsideInsets(EndGame g, Rect bubble, Rect row) {
  expect(
    bubble.left,
    greaterThanOrEqualTo(row.left + _inset - 0.5),
    reason: g.why(
      '$_inset dp clear of the row\'s left: bubble $bubble, row $row',
    ),
  );
  expect(
    bubble.right,
    lessThanOrEqualTo(row.right - _inset + 0.5),
    reason: g.why('$_inset dp clear of the row\'s right'),
  );
}

void _expectClearOf(EndGame g, Rect bubble, Key key) {
  expect(find.byKey(key), findsOneWidget, reason: g.why('$key is on screen'));
  final Rect other = g.tester.getRect(find.byKey(key));
  expect(
    bubble.overlaps(other),
    isFalse,
    reason: g.why('bubble $bubble does not meet $key $other'),
  );
}

void main() {
  // -------------------------------------------------------------------
  // Item 5: what shows, when.
  // -------------------------------------------------------------------
  group('5. a received line on the end card', () {
    for (final EndKind kind in <EndKind>[EndKind.winner, EndKind.loser]) {
      for (final bool ar in const <bool>[false, true]) {
        testWidgets('${kind.name} FINISHED, ${ar ? 'ar' : 'en'}: another '
            'seat\'s line shows, then mine replaces it', (tester) async {
          final EndGame g = await openFinished(
            tester,
            '5 finished ${kind.name} ${ar ? 'ar' : 'en'}',
            kind: kind,
            locale: Locale(ar ? 'ar' : 'en'),
          );
          try {
            expect(
              chatLineSeats(tester),
              isEmpty,
              reason: g.why('fixture: no line yet'),
            );
            await g.emote(1, 'good_game');
            _expectLine(g, 1, 'Bob', endLine('good_game', ar: ar));
            expect(chatLineSeats(tester), <int>[
              1,
            ], reason: g.why('one line, the other seat\'s'));
            await g.emote(0, 'ha_ha');
            expect(chatLineSeats(tester), <int>[
              0,
            ], reason: g.why('mine replaces it: one end-card-chat-*'));
            _expectLine(g, 0, 'Sam', endLine('ha_ha', ar: ar));
            expect(
              find.byKey(chatLineKey(1)),
              findsNothing,
              reason: g.why('seat 1\'s line is gone'),
            );
            expect(tester.takeException(), isNull);
          } finally {
            await g.done();
          }
        });
      }
    }

    testWidgets('a FINISHED room reached by snapshot (no game_over seen, no '
        'winner named) shows a line from the room\'s seats', (tester) async {
      final EndGame g = await openFinished(
        tester,
        '5 ended snapshot',
        kind: EndKind.ended,
      );
      try {
        expect(
          g.drive.controller.lastFinished,
          isNull,
          reason: g.why(
            'fixture: no lastFinished, the seat list is the '
            'room\'s',
          ),
        );
        await g.emote(1, 'revenge');
        _expectLine(g, 1, 'Bob', 'I\'ll get you back');
      } finally {
        await g.done();
      }
    });

    testWidgets('a rematch LOBBY shows a line too', (tester) async {
      final EndGame g = await openFinished(tester, '5 rematch lobby');
      try {
        await g.rematchLobby(by: 1);
        expect(
          find.byKey(const Key('end-card-rematch-ask')),
          findsOneWidget,
          reason: g.why('fixture: the rematch LOBBY card'),
        );
        await g.emote(1, 'good_game');
        _expectLine(g, 1, 'Bob', 'Good game');
      } finally {
        await g.done();
      }
    });

    testWidgets('a first-game LOBBY shows nothing', (tester) async {
      await _control(tester, '5 first lobby');
      final EndGame g = await openFirstLobby(tester, '5 first lobby');
      try {
        await g.emote(1, 'good_game');
        await g.emote(0, 'hi');
        await g.s.pump(const Duration(milliseconds: 300));
        _expectNoLines(g, 'first-game LOBBY');
        expectNoBoardChat(g, 'first-game LOBBY');
        expect(tester.takeException(), isNull);
      } finally {
        await g.done();
      }
    });

    testWidgets('a seat that left after the game (in lastFinished only) '
        'still says its line, with its name', (tester) async {
      final EndGame g = await openFinished(tester, '5 left seat', players: 3);
      try {
        await g.playerLeft(2);
        await g.s.pump(const Duration(milliseconds: 100));
        final List<int> live = <int>[
          for (final SeatState s in g.drive.controller.room!.seats) s.seat,
        ];
        expect(live, <int>[0, 1], reason: g.why('fixture: seat 2 has left'));
        expect(
          <int>[
            for (final SeatState s in g.drive.controller.lastFinished!.seats)
              s.seat,
          ],
          <int>[0, 1, 2],
          reason: g.why('fixture: lastFinished still holds seat 2'),
        );
        await g.emote(2, 'revenge');
        _expectLine(g, 2, 'Cara', 'I\'ll get you back');
        await g.emote(3, 'hi');
        expect(chatLineSeats(tester), <int>[
          2,
        ], reason: g.why('seat 3 never sat here: still only seat 2'));
      } finally {
        await g.done();
      }
    });

    for (final (String, Object?, Object?) bad in _notALine) {
      testWidgets('${bad.$1}: no line, no exception, and a good line after '
          'still shows', (tester) async {
        final EndGame g = await openFinished(tester, '5 bad ${bad.$1}');
        try {
          await g.emote(bad.$2, bad.$3);
          await g.s.pump(const Duration(milliseconds: 300));
          _expectNoLines(g, bad.$1);
          expect(
            tester.takeException(),
            isNull,
            reason: g.why('${bad.$1} throws nothing'),
          );
          await g.emote(1, 'good_game');
          _expectLine(g, 1, 'Bob', 'Good game');
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('a bad push does not remove the good line already up', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '5 bad after good');
      try {
        await g.emote(1, 'good_game');
        await g.emote(1, 'nope');
        await g.emote(9, 'hi');
        _expectLine(g, 1, 'Bob', 'Good game');
        expect(tester.takeException(), isNull);
      } finally {
        await g.done();
      }
    });

    testWidgets('hide the others on: another seat\'s line shows nothing, '
        'mine still shows', (tester) async {
      final EndGame g = await openPlaying(tester, '5 muted', players: 4);
      try {
        await toggleMute(g);
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('fixture: the end card is up'),
        );
        await g.emote(1, 'good_game');
        await g.emote(2, 'ha_ha');
        await g.emote(3, 'revenge');
        _expectNoLines(g, 'muted, seats 1 to 3');
        await g.emote(0, 'lucky');
        expect(chatLineSeats(tester), <int>[
          0,
        ], reason: g.why('my own line (seat 0) shows while muted'));
        _expectLine(g, 0, 'Sam', 'So lucky!');
      } finally {
        await g.done();
      }
    });

    testWidgets('hide the others on, my seat is 2: seat 0 is hidden, seat 2 '
        'stays', (tester) async {
      final EndGame g = await openPlaying(
        tester,
        '5 muted as seat 2',
        me: 2,
        players: 4,
      );
      try {
        await toggleMute(g);
        await g.gameOver(0);
        await g.s.pump(const Duration(milliseconds: 100));
        await g.emote(0, 'good_game');
        _expectNoLines(g, 'muted, seat 0 while I am 2');
        await g.emote(2, 'good_game');
        expect(chatLineSeats(tester), <int>[2], reason: g.why('mine shows'));
      } finally {
        await g.done();
      }
    });

    testWidgets('a hidden line does not remove mine, and does not restart '
        'its life', (tester) async {
      final EndGame g = await openPlaying(
        tester,
        '5 hidden keeps mine',
        players: 4,
      );
      try {
        await toggleMute(g);
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        await g.emote(0, 'lucky');
        _expectLine(g, 0, 'Sam', 'So lucky!');
        final int mineAt = g.zero;
        await g.s.pump(const Duration(milliseconds: 2000));
        await g.emote(1, 'good_game');
        expect(chatLineSeats(tester), <int>[
          0,
        ], reason: g.why('the hidden line left mine up'));
        _expectLine(g, 0, 'Sam', 'So lucky!');
        expect(
          textUnder(tester, find.byKey(chatLineKey(0))),
          isNot(contains('Good game')),
          reason: g.why('seat 1\'s line was not drawn'),
        );
        final int left = mineAt + 2510 - g.s.clockMs;
        expect(
          left,
          greaterThan(0),
          reason: g.why('fixture: mine has life left to check'),
        );
        await g.s.pump(Duration(milliseconds: left));
        _expectNoLines(
          g,
          'mine ended on the timer it started with, 510 ms after the '
          'hidden line',
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a line makes no sound and no haptic', (tester) async {
      final EndGame g = await openFinished(tester, '5 silent');
      try {
        final int before = g.drive.feedback.recorded.length;
        await g.emote(1, 'revenge');
        _expectLine(g, 1, 'Bob', 'I\'ll get you back');
        await g.s.pump(const Duration(milliseconds: 3000));
        expect(
          g.drive.feedback.recorded.sublist(before),
          isEmpty,
          reason: g.why('no FeedbackCue for an incoming line'),
        );
      } finally {
        await g.done();
      }
    });
  });

  // -------------------------------------------------------------------
  // Item 6: replacing, ordering, ending.
  // -------------------------------------------------------------------
  group('6. replace, order, expire', () {
    for (final EndKind kind in EndKind.values) {
      testWidgets('${kind.name}: a line is up at 2490 ms and gone at '
          '2510 ms', (tester) async {
        final EndGame g = await openFinished(
          tester,
          '6 life ${kind.name}',
          kind: kind,
        );
        try {
          await g.emote(1, 'good_game');
          for (final int ms in const <int>[300, 1000, 2000, 2490]) {
            await g.at(ms);
            expect(chatLineSeats(tester), <int>[
              1,
            ], reason: g.why('still up at $ms ms after the line'));
          }
          await g.at(2510);
          _expectNoLines(g, 'gone after $_lifeMs ms');
          await g.s.pump(const Duration(milliseconds: 3000));
          _expectNoLines(g, 'and it does not come back');
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('a second line from the same seat replaces the first: one '
        'end-card-chat-1, and its life restarts', (tester) async {
      final EndGame g = await openFinished(tester, '6 replace');
      try {
        await g.emote(1, 'hi');
        await g.at(1000);
        await g.emote(1, 'oops');
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('one bubble for seat 1'));
        expect(
          find.byKey(chatLineKey(1)),
          findsOneWidget,
          reason: g.why('exactly one widget with the key'),
        );
        _expectLine(g, 1, 'Bob', 'Oops');
        expect(
          textUnder(tester, find.byKey(chatLineKey(1))),
          isNot(contains('Hi all')),
          reason: g.why('the old line is gone from the bubble'),
        );
        await g.at(1600);
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('up where the first would be gone (2600 ms overall)'));
        await g.at(2490);
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('up at 3490 ms overall'));
        await g.at(2510);
        _expectNoLines(g, 'gone 2500 ms after the second line');
      } finally {
        await g.done();
      }
    });

    testWidgets('the replacement is measured from its own push, so the '
        'first one\'s timer cannot take it down', (tester) async {
      final EndGame g = await openFinished(tester, '6 stale timer');
      try {
        await g.emote(1, 'hi');
        await g.at(2400);
        await g.emote(1, 'good_game');
        await g.s.pump(const Duration(milliseconds: 200));
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('200 ms after the 2nd, past the first\'s 2500'));
        _expectLine(g, 1, 'Bob', 'Good game');
      } finally {
        await g.done();
      }
    });

    testWidgets('a replaced line restarts its fade as well: full opacity '
        '1500 ms after the replacement, fading 2300 ms after it', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '6 fade restart');
      try {
        await g.emote(1, 'hi');
        await g.at(2000);
        await g.emote(1, 'oops');
        await g.at(1500);
        expect(
          alphaUnder(tester, lineOf(g, 1)),
          closeTo(1.0, 0.01),
          reason: g.why(
            '3500 ms after the first, 1500 after the second: '
            'full opacity, not in the first\'s fade',
          ),
        );
        await g.at(2400);
        expect(
          alphaUnder(tester, lineOf(g, 1)),
          lessThan(0.9),
          reason: g.why('2400 ms after the second it is in its own fade'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a newer line from any seat replaces the one up: one '
        'end-card-chat-* , the newest', (tester) async {
      final EndGame g = await openFinished(tester, '6 one line', players: 4);
      try {
        await g.emote(2, 'hi');
        expect(chatLineSeats(tester), <int>[
          2,
        ], reason: g.why('seat 2 is the only line'));
        _expectLine(g, 2, 'Cara', 'Hi all');
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(1, 'oops');
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('seat 1 replaces seat 2'));
        _expectLine(g, 1, 'Bob', 'Oops');
        expect(
          find.byKey(chatLineKey(2)),
          findsNothing,
          reason: g.why('seat 2 is gone'),
        );
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(2, 'good_game');
        expect(chatLineSeats(tester), <int>[
          2,
        ], reason: g.why('seat 2 speaking again replaces seat 1'));
        _expectLine(g, 2, 'Cara', 'Good game');
        expect(
          textUnder(tester, find.byKey(chatLineKey(2))),
          isNot(contains('Hi all')),
          reason: g.why('the old line is gone from the bubble'),
        );
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(3, 'lucky');
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(0, 'ha_ha');
        expect(chatLineSeats(tester), <int>[
          0,
        ], reason: g.why('the newest line, seat 0, is the only one'));
        _expectLine(g, 0, 'Sam', 'Ha ha ha');
        expect(
          find.byKey(chatLineKey(3)),
          findsNothing,
          reason: g.why('seat 3 was replaced'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a line from another seat drops the one it replaces and '
        'that line\'s timer', (tester) async {
      final EndGame g = await openFinished(tester, '6 one timer', players: 4);
      try {
        await g.emote(1, 'hi');
        await g.s.pump(const Duration(milliseconds: 1000));
        final int t1 = g.zero;
        await g.emote(2, 'oops');
        expect(chatLineSeats(tester), <int>[
          2,
        ], reason: g.why('only the newer line is up'));
        _expectLine(g, 2, 'Cara', 'Oops');
        await g.s.pump(Duration(milliseconds: t1 + 2510 - g.s.clockMs));
        expect(
          chatLineSeats(tester),
          <int>[2],
          reason: g.why(
            'past seat 1\'s 2500 ms the replacement is still up: its '
            'timer was dropped',
          ),
        );
        await g.at(2510);
        _expectNoLines(g, 'seat 2 ends on its own 2500 ms');
      } finally {
        await g.done();
      }
    });

    testWidgets('two lines delivered before one pump leave one bubble', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '6 one frame', players: 4);
      try {
        g.s.steps.add('two emotes, one pump');
        g.drive.transport.pushText(emoteFrame(seat: 1, emote: 'hi'));
        g.drive.transport.pushText(emoteFrame(seat: 3, emote: 'oops'));
        await tester.pump();
        await tester.pump();
        final List<int> seats = chatLineSeats(tester);
        expect(
          seats,
          hasLength(1),
          reason: g.why(
            'one end-card-chat-* after two lines in one pump '
            '(on screen: $seats)',
          ),
        );
        expect(
          <int>[1, 3],
          contains(seats.single),
          reason: g.why('the one line is one of the two that arrived'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('the same frame replayed shows one bubble and throws '
        'nothing', (tester) async {
      final EndGame g = await openFinished(tester, '6 replayed');
      try {
        final String raw = emoteFrame(seat: 1, emote: 'good_game');
        g.s.steps.add('the same emote frame twice');
        await pushRaw(tester, g.drive, raw);
        await pushRaw(tester, g.drive, raw);
        expect(
          find.byKey(chatLineKey(1)),
          findsOneWidget,
          reason: g.why('one bubble for a replayed frame'),
        );
        expect(tester.takeException(), isNull);
        await g.s.pump(const Duration(milliseconds: 3000));
        _expectNoLines(g, 'and it ends');
      } finally {
        await g.done();
      }
    });
  });

  // -------------------------------------------------------------------
  // Item 7: motion and semantics.
  // -------------------------------------------------------------------
  group('7. motion and semantics', () {
    testWidgets('motion: scale 0.6 to 1.0 in 160 ms, full opacity to 2250 ms, '
        'fades over the last 250 ms, gone at 2500 ms', (tester) async {
      final EndGame g = await openFinished(tester, '7 motion');
      try {
        await g.emote(1, 'good_game');
        final Finder line = lineOf(g, 1);
        await g.at(400);
        final double base = textWidthUnder(tester, line);
        await g.s.pump(const Duration(milliseconds: 3000));
        _expectNoLines(g, 'fixture: the first run ended');
        await g.emote(1, 'good_game');
        final List<_Sample> trace = await _trace(
          tester,
          line,
          base,
          (Duration d) => g.s.pump(d, step: d),
        );
        _expectMotion(trace, g.why);
        await g.at(2510);
        _expectNoLines(g, 'gone at 2500 ms');
      } finally {
        await g.done();
      }
    });

    testWidgets('reduced motion: full size and full opacity from the first '
        'frame to the end, removed at 2500 ms', (tester) async {
      final EndGame g = await openFinished(tester, '7 reduced', reduced: true);
      try {
        await g.emote(1, 'good_game');
        final Finder line = lineOf(g, 1);
        final double first = textWidthUnder(tester, line);
        expect(
          alphaUnder(tester, line),
          closeTo(1.0, 0.01),
          reason: g.why('full opacity on the first frame'),
        );
        await g.at(400);
        final double settled = textWidthUnder(tester, line);
        expect(
          first,
          closeTo(settled, 0.5),
          reason: g.why('first frame is already full size: $first vs $settled'),
        );
        await g.s.pump(const Duration(milliseconds: 3000));
        await g.emote(1, 'good_game');
        while (g.s.clockMs - g.zero < 2490) {
          expect(
            textWidthUnder(tester, line),
            closeTo(settled, 0.5),
            reason: g.why('no scale at ${g.s.clockMs - g.zero} ms'),
          );
          expect(
            alphaUnder(tester, line),
            closeTo(1.0, 0.01),
            reason: g.why('full opacity at ${g.s.clockMs - g.zero} ms'),
          );
          final int left = 2490 - (g.s.clockMs - g.zero);
          await g.s.pump(Duration(milliseconds: left < 100 ? left : 100));
        }
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('present at 2490 ms'));
        await g.at(2510);
        _expectNoLines(g, 'removed at 2500 ms');
      } finally {
        await g.done();
      }
    });

    for (final bool ar in const <bool>[false, true]) {
      testWidgets('semantics ${ar ? 'ar' : 'en'}: a live region labelled '
          'chatSaid(name, line)', (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final EndGame g = await openFinished(
          tester,
          '7 semantics ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
        );
        try {
          await g.emote(1, 'good_game');
          await g.at(400);
          final SemanticsNode node = tester.getSemantics(lineOf(g, 1));
          expect(
            node.label,
            said('Bob', endLine('good_game', ar: ar)),
            reason: g.why('label is chatSaid(name, line)'),
          );
          expect(
            node.flagsCollection.isLiveRegion,
            isTrue,
            reason: g.why('the bubble is a live region'),
          );
        } finally {
          handle.dispose();
          await g.done();
        }
      });
    }
  });

  // -------------------------------------------------------------------
  // Item 8 and the other ways lines end.
  // -------------------------------------------------------------------
  group('8. what clears the lines', () {
    testWidgets('game_started (a rematch starting) clears every line: none '
        'on the next end card, none on the next board', (tester) async {
      final EndGame g = await openFinished(
        tester,
        '8 game_started',
        players: 4,
      );
      try {
        await g.emote(1, 'good_game');
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('fixture: the line is up'));
        await g.rematchLobby(by: 1);
        await g.startRematchGame(turnSeat: 1);
        await g.s.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(kChatButtonKey),
          findsOneWidget,
          reason: g.why('fixture: the next game is PLAYING'),
        );
        _expectNoLines(g, 'while the next game plays: game_started cleared it');
        expectNoBoardChat(g, 'while the next game plays');
        await g.s.pump(const Duration(milliseconds: 3000));
        _expectNoLines(g, 'and it does not come back later in the next game');
        await g.emote(2, 'oops');
        _expectLine(g, 2, 'Cara', 'Oops');
        expectNoBoardChat(g, 'a line in the next game');
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('fixture: the second game ended, its card is up'),
        );
        expect(
          chatLineSeats(tester),
          <int>[2],
          reason: g.why(
            'the second game\'s own line carried to its card, and the first '
            'game\'s line (seat 1) did not come back with it',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('game_started clears a line carried over from PLAYING too: '
        'the line is gone from the next board and its end card', (
      tester,
    ) async {
      final EndGame g = await openPlaying(tester, '8 carried then rematch');
      try {
        await g.emote(1, 'good_game');
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('fixture: the PLAYING line is on the end card'));
        await g.rematchLobby(by: 1);
        await g.startRematchGame(turnSeat: 1);
        await g.s.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(kChatButtonKey),
          findsOneWidget,
          reason: g.why('fixture: the next game is PLAYING'),
        );
        _expectNoLines(g, 'on the next board: game_started cleared it');
        expectNoBoardChat(g, 'on the next board');
      } finally {
        await g.done();
      }
    });

    for (final EndKind kind in <EndKind>[EndKind.winner, EndKind.loser]) {
      for (final bool ar in const <bool>[false, true]) {
        testWidgets('${kind.name}, ${ar ? 'ar' : 'en'}: a line up in PLAYING '
            'is still up on the end card after game_over, same seat and text, '
            'and gone at its own 2500 ms', (tester) async {
          final EndGame g = await openPlaying(
            tester,
            '8 carry ${kind.name} ${ar ? 'ar' : 'en'}',
            locale: Locale(ar ? 'ar' : 'en'),
          );
          try {
            final String text = endLine('good_game', ar: ar);
            await g.emote(1, 'good_game');
            _expectLine(g, 1, 'Bob', text);
            expect(chatLineSeats(tester), <int>[
              1,
            ], reason: g.why('fixture: one line in PLAYING'));
            expectNoBoardChat(g, 'PLAYING: the line is the header\'s');
            await g.at(1200);
            await g.gameOver(kind == EndKind.winner ? 0 : 1);
            await g.s.pump(const Duration(milliseconds: 100));
            expect(
              find.byKey(_winnerKey),
              findsOneWidget,
              reason: g.why('fixture: the end card is up'),
            );
            expect(
              chatLineSeats(tester),
              <int>[1],
              reason: g.why(
                'game_over does not clear the line: seat 1 is still the '
                'one end-card-chat-*',
              ),
            );
            _expectLine(g, 1, 'Bob', text);
            expect(
              find.byKey(kChatLinesKey),
              findsOneWidget,
              reason: g.why('the header layer is still the one layer'),
            );
            expectNoBoardChat(g, 'the end card');
            final Rect row = _headerRow(tester);
            final Rect bubble = tester.getRect(find.byKey(chatLineKey(1)));
            _expectInsideInsets(g, bubble, row);
            _expectClearOf(g, bubble, _leaveKey);
            _expectClearOf(g, bubble, _settingsKey);
            await g.at(2490);
            expect(
              chatLineSeats(tester),
              <int>[1],
              reason: g.why(
                'still up at 2490 ms from its own push, 1290 ms after '
                'the card came up',
              ),
            );
            await g.at(2510);
            _expectNoLines(
              g,
              'gone 2500 ms from its own push, not 2500 ms from the card',
            );
            await g.s.pump(const Duration(milliseconds: 3000));
            _expectNoLines(g, 'and it does not come back');
            expect(tester.takeException(), isNull);
          } finally {
            await g.done();
          }
        });
      }
    }

    testWidgets('game_over while the line is already fading (2400 ms in) '
        'leaves it to finish: up at 2490 ms, gone at 2510 ms', (tester) async {
      final EndGame g = await openPlaying(tester, '8 carry late');
      try {
        await g.emote(1, 'revenge');
        await g.at(2400);
        _expectLine(g, 1, 'Bob', 'I\'ll get you back');
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 20));
        expect(
          find.byKey(_winnerKey),
          findsOneWidget,
          reason: g.why('fixture: the end card is up'),
        );
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('game_over at 2400 ms did not take the line down'));
        await g.at(2490);
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('up at 2490 ms: not restarted, not cut early'));
        await g.at(2510);
        _expectNoLines(
          g,
          'gone at 2510 ms: game_over did not restart its life',
        );
      } finally {
        await g.done();
      }
    });

    for (final (int, String, String, String) newer
        in const <(int, String, String, String)>[
          (1, 'oops', 'Bob', 'Oops'),
          (2, 'ha_ha', 'Cara', 'Ha ha ha'),
          (0, 'lucky', 'Sam', 'So lucky!'),
        ]) {
      testWidgets('a line from PLAYING carries over, then a newer card line '
          'from seat ${newer.$1} replaces it and has its own 2500 ms', (
        tester,
      ) async {
        final EndGame g = await openPlaying(
          tester,
          '8 carry then replace ${newer.$1}',
          players: 4,
        );
        try {
          final int seat = newer.$1 == 1 ? 3 : 1;
          await g.emote(seat, 'good_game');
          await g.at(300);
          await g.gameOver(1);
          await g.s.pump(const Duration(milliseconds: 100));
          expect(chatLineSeats(tester), <int>[
            seat,
          ], reason: g.why('fixture: seat $seat\'s PLAYING line carried over'));
          await g.s.pump(const Duration(milliseconds: 1100));
          await g.emote(newer.$1, newer.$2);
          expect(
            chatLineSeats(tester),
            <int>[newer.$1],
            reason: g.why(
              'seat ${newer.$1}\'s line replaces the carried one: one '
              'end-card-chat-* and it is the newer seat\'s',
            ),
          );
          _expectLine(g, newer.$1, newer.$3, newer.$4);
          expect(
            find.byKey(chatLineKey(seat)),
            findsNothing,
            reason: g.why('the carried line of seat $seat is gone'),
          );
          expectNoBoardChat(g, 'after the replacement');
          await g.at(1100);
          expect(
            chatLineSeats(tester),
            <int>[newer.$1],
            reason: g.why(
              'past the carried line\'s own 2500 ms the newer line is '
              'still up: the old timer was dropped',
            ),
          );
          await g.at(2490);
          expect(chatLineSeats(tester), <int>[
            newer.$1,
          ], reason: g.why('the newer line is up at 2490 ms from its push'));
          await g.at(2510);
          _expectNoLines(g, 'the newer line is gone 2500 ms after its push');
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('the same seat saying a second line after game_over replaces '
        'the carried text', (tester) async {
      final EndGame g = await openPlaying(tester, '8 carry same seat');
      try {
        await g.emote(1, 'hi');
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        _expectLine(g, 1, 'Bob', 'Hi all');
        await g.emote(1, 'ha_ha');
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('one bubble for seat 1'));
        _expectLine(g, 1, 'Bob', 'Ha ha ha');
        expect(
          textUnder(tester, find.byKey(chatLineKey(1))),
          isNot(contains('Hi all')),
          reason: g.why('the carried text is gone from the bubble'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a line after game_over is the header line, not the '
        'board\'s', (tester) async {
      final EndGame g = await openPlaying(tester, '8 after game_over');
      try {
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        _expectNoLines(g, 'nobody has spoken yet');
        await g.emote(1, 'ha_ha');
        _expectLine(g, 1, 'Bob', 'Ha ha ha');
        expectNoBoardChat(g, 'a line after game_over');
      } finally {
        await g.done();
      }
    });

    testWidgets('a held end shows the line that was up in PLAYING '
        '(C-500 supersedes C-492 D8)', (tester) async {
      final EndGame g = await openHeldEnd(
        tester,
        '8 held carried',
        beforeEnd: (EndGame g) => g.emote(1, 'good_game'),
      );
      try {
        expect(
          chatLineSeats(tester),
          <int>[1],
          reason: g.why(
            'the board is held for the last piece and the PLAYING line is '
            'still up',
          ),
        );
        _expectLine(g, 1, 'Bob', 'Good game');
        expectNoBoardChat(g, 'the held end');
        await g.at(2490);
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('up at 2490 ms from its push'));
        await g.at(2510);
        _expectNoLines(g, 'gone 2500 ms from its push, held end or not');
      } finally {
        await g.done();
      }
    });

    testWidgets('a held end shows a line that arrives while the piece is '
        'still walking', (tester) async {
      final EndGame g = await openHeldEnd(tester, '8 held new line');
      try {
        await g.emote(1, 'revenge');
        expect(
          find.byKey(const Key('game-screen-winner')),
          findsNothing,
          reason: g.why('fixture: still the held board when the line lands'),
        );
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('the held end draws the line (C-492 D8 is gone)'));
        _expectLine(g, 1, 'Bob', 'I\'ll get you back');
        expectNoBoardChat(g, 'the held end');
        await g.emote(0, 'lucky');
        expect(chatLineSeats(tester), <int>[
          0,
        ], reason: g.why('a newer line in the held end replaces it'));
        _expectLine(g, 0, 'Sam', 'So lucky!');
        await g.at(2490);
        expect(chatLineSeats(tester), <int>[
          0,
        ], reason: g.why('up at 2490 ms from its push'));
        await g.at(2510);
        _expectNoLines(g, 'gone 2500 ms from its push');
      } finally {
        await g.done();
      }
    });

    testWidgets('a resync (a seq gap answered by a snapshot) clears every '
        'line', (tester) async {
      final EndGame g = await openFinished(tester, '8 resync', players: 4);
      try {
        await g.emote(1, 'hi');
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('fixture: the line is up'));
        await gapAndResync(g);
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('fixture: still the end card after the resync'),
        );
        _expectNoLines(g, 'after the resync');
        await g.emote(2, 'good_game');
        expect(chatLineSeats(tester), <int>[
          2,
        ], reason: g.why('new lines still work after'));
      } finally {
        await g.done();
      }
    });

    testWidgets('a resume after a dropped socket clears every line', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '8 resume', players: 4);
      try {
        await g.emote(1, 'hi');
        expect(chatLineSeats(tester), <int>[
          1,
        ], reason: g.why('fixture: the line is up before the drop'));
        await dropAndResume(g);
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('fixture: the end card after the resume'),
        );
        _expectNoLines(g, 'after the resume');
      } finally {
        await g.done();
      }
    });

    testWidgets('leaving the screen with a line up leaves no timer behind', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '8 dispose');
      await g.emote(1, 'good_game');
      expect(chatLineSeats(tester), <int>[
        1,
      ], reason: g.why('fixture: a line is up with 2500 ms to live'));
      await g.done();
      expect(tester.takeException(), isNull);
    });
  });

  group('fit', () {
    for (final bool ar in const <bool>[false, true]) {
      testWidgets(
        '360 x 640 at 2x text, ${ar ? 'ar' : 'en'}: the newest of four '
        'lines, no overflow, inside the screen',
        (tester) async {
          final EndGame g = await openFinished(
            tester,
            'fit ${ar ? 'ar' : 'en'}',
            players: 4,
            textScale: 2.0,
            size: const Size(360, 640),
            locale: Locale(ar ? 'ar' : 'en'),
          );
          try {
            for (final (int, String) row in const <(int, String)>[
              (1, 'revenge'),
              (2, 'good_game'),
              (3, 'lucky'),
              (0, 'ha_ha'),
            ]) {
              await g.emote(row.$1, row.$2);
            }
            await g.s.pump(const Duration(milliseconds: 300));
            expect(chatLineSeats(tester), <int>[
              0,
            ], reason: g.why('the newest line is the only one'));
            _expectLine(g, 0, 'Sam', endLine('ha_ha', ar: ar));
            final Rect r = tester.getRect(find.byKey(chatLineKey(0)));
            expect(
              r.left,
              greaterThanOrEqualTo(0.0),
              reason: g.why('bubble $r inside the screen on the left'),
            );
            expect(
              r.right,
              lessThanOrEqualTo(360.0),
              reason: g.why('bubble $r inside the screen on the right'),
            );
            expect(
              tester.takeException(),
              isNull,
              reason: g.why('no overflow'),
            );
          } finally {
            await g.done();
          }
        },
      );
    }
  });

  // -------------------------------------------------------------------
  // C-492 decisions 1, 4 and 6: the one line in the header band.
  // -------------------------------------------------------------------
  group('header band', () {
    for (final EndKind kind in <EndKind>[EndKind.winner, EndKind.loser]) {
      for (final bool ar in const <bool>[false, true]) {
        testWidgets(
          '${kind.name} at text scale 1.0, ${ar ? 'ar' : 'en'}: the line '
          'sits in the header row, clear of the buttons and the winner '
          'title',
          (tester) async {
            final EndGame g = await openFinished(
              tester,
              'band ${kind.name} ${ar ? 'ar' : 'en'}',
              kind: kind,
              locale: Locale(ar ? 'ar' : 'en'),
            );
            try {
              await g.emote(1, 'good_game');
              await g.at(400);
              final Finder line = lineOf(g, 1);
              expect(
                find.byKey(kChatLinesKey),
                findsOneWidget,
                reason: g.why('end-card-chat-lines is the header layer'),
              );
              bool underLayer = false;
              tester.element(line).visitAncestorElements((Element ancestor) {
                if (ancestor.widget.key == kChatLinesKey) {
                  underLayer = true;
                  return false;
                }
                return true;
              });
              expect(
                underLayer,
                isTrue,
                reason: g.why('the bubble is inside end-card-chat-lines'),
              );
              expect(
                tester
                    .element(find.byKey(kChatLinesKey))
                    .findAncestorWidgetOfExactType<EndCard>(),
                isNull,
                reason: g.why('the layer is not a child of EndCard'),
              );
              final Rect row = _headerRow(tester);
              final Rect bubble = tester.getRect(line);
              _expectInRow(g, bubble, row);
              _expectInsideInsets(g, bubble, row);
              _expectClearOf(g, bubble, _leaveKey);
              _expectClearOf(g, bubble, _settingsKey);
              _expectClearOf(g, bubble, _winnerKey);
            } finally {
              await g.done();
            }
          },
        );
      }
    }

    for (final bool ar in const <bool>[false, true]) {
      for (final double width in const <double>[360, 411]) {
        testWidgets(
          '${width.toInt()} dp, ${ar ? 'ar' : 'en'}: the bubble stays '
          'inside the 60 dp insets, and a long line is the max width',
          (tester) async {
            expect(_inset, 60);
            final EndGame g = await openFinished(
              tester,
              'inset $width ${ar ? 'ar' : 'en'}',
              names: <int, String>{0: _shortName, 1: 'M' * 40},
              size: Size(width, width == 411 ? 891 : 800),
              locale: Locale(ar ? 'ar' : 'en'),
            );
            try {
              await g.emote(1, 'good_game');
              await g.at(400);
              final Rect row = _headerRow(tester);
              final Rect bubble = tester.getRect(find.byKey(chatLineKey(1)));
              final double maxWidth = math.min(320, row.width - 2 * _inset);
              expect(
                bubble.width,
                closeTo(maxWidth, 1),
                reason: g.why(
                  'long line is min(320, row width - 120): bubble $bubble, '
                  'row $row, max $maxWidth',
                ),
              );
              _expectInsideInsets(g, bubble, row);
              expect(
                bubble.center.dx,
                closeTo(row.center.dx, 1),
                reason: g.why('centred on the row'),
              );
              await _expectShortIsShort(
                tester,
                g,
                ar: ar,
                maxWidth: maxWidth,
                longWidth: bubble.width,
              );
            } finally {
              await g.done();
            }
          },
        );
      }
    }

    for (final double width in const <double>[800, 300]) {
      testWidgets('a long line on a ${width.toInt()} dp screen is '
          'min(320, width - 120) wide', (tester) async {
        final EndGame g = await openFinished(
          tester,
          'width $width',
          names: <int, String>{0: _shortName, 1: 'M' * 40},
          size: Size(width, 800),
        );
        try {
          await g.emote(1, 'good_game');
          await g.at(400);
          final Rect row = _headerRow(tester);
          final Rect bubble = tester.getRect(find.byKey(chatLineKey(1)));
          final double maxWidth = math.min(320, row.width - 2 * _inset);
          expect(
            bubble.width,
            closeTo(maxWidth, 1),
            reason: g.why('bubble $bubble, row $row, max $maxWidth'),
          );
          _expectInsideInsets(g, bubble, row);
          await _expectShortIsShort(
            tester,
            g,
            ar: false,
            maxWidth: maxWidth,
            longWidth: bubble.width,
          );
        } finally {
          await g.done();
        }
      });
    }

    for (final bool ar in const <bool>[false, true]) {
      testWidgets(
        'text scale 2.0, ${ar ? 'ar' : 'en'}: one line tall, starting at '
        'the row\'s top',
        (tester) async {
          final EndGame g = await openFinished(
            tester,
            'tall ${ar ? 'ar' : 'en'}',
            players: 3,
            textScale: 2.0,
            size: const Size(360, 640),
            locale: Locale(ar ? 'ar' : 'en'),
            names: <int, String>{2: 'N' * 40},
          );
          try {
            await g.emote(1, 'hi');
            await g.at(400);
            final double short = tester
                .getRect(find.byKey(chatLineKey(1)))
                .height;
            await g.emote(2, 'good_game');
            await g.at(400);
            final Rect bubble = tester.getRect(find.byKey(chatLineKey(2)));
            expect(
              bubble.height,
              closeTo(short, 0.5),
              reason: g.why(
                'the long line is as tall as the short one: one line',
              ),
            );
            expect(
              tester.takeException(),
              isNull,
              reason: g.why('no overflow'),
            );
            final Rect row = _headerRow(tester);
            expect(
              bubble.height,
              greaterThan(_rowDp),
              reason: g.why('at 2.0 the bubble is taller than the row'),
            );
            expect(
              bubble.top,
              closeTo(row.top, 0.5),
              reason: g.why(
                'a bubble taller than the row starts at the row\'s top: '
                'bubble $bubble, row $row',
              ),
            );
            expect(
              bubble.bottom,
              greaterThan(row.bottom),
              reason: g.why('it paints down over the body'),
            );
          } finally {
            await g.done();
          }
        },
      );
    }

    testWidgets('the line stays put while the card scrolls', (tester) async {
      final EndGame g = await openFinished(
        tester,
        'scroll',
        size: const Size(360, 640),
      );
      try {
        await g.emote(1, 'good_game');
        await g.at(400);
        final Rect bubble = tester.getRect(find.byKey(chatLineKey(1)));
        final Rect panel = tester.getRect(find.byKey(_panelKey));
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -200),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final Rect panelAfter = tester.getRect(find.byKey(_panelKey));
        expect(
          panelAfter.top,
          lessThan(panel.top - 100),
          reason: g.why('fixture: the card scrolled ($panel to $panelAfter)'),
        );
        expect(
          tester.getRect(find.byKey(chatLineKey(1))),
          bubble,
          reason: g.why('the line did not scroll with the card'),
        );
        _expectInRow(
          g,
          tester.getRect(find.byKey(chatLineKey(1))),
          _headerRow(tester),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('the line takes no layout space: the row, the panel, New '
        'table and the dock stay put', (tester) async {
      final EndGame g = await openFinished(tester, 'no space');
      try {
        final Rect row = _headerRow(tester);
        final Rect panel = tester.getRect(find.byKey(_panelKey));
        final Rect table = tester.getRect(find.byKey(kNewTableKey));
        final Rect dock = tester.getRect(find.byKey(kRematchKey));
        final Rect leave = tester.getRect(find.byKey(_leaveKey));
        expect(
          find.byKey(kChatLinesKey),
          findsNothing,
          reason: g.why('fixture: no line yet, so no layer'),
        );
        await g.emote(1, 'good_game');
        await g.at(400);
        expect(find.byKey(chatLineKey(1)), findsOneWidget);
        expect(
          _headerRow(tester),
          row,
          reason: g.why('the header row did not move'),
        );
        expect(
          tester.getRect(find.byKey(_panelKey)),
          panel,
          reason: g.why('the panel did not move'),
        );
        expect(
          tester.getRect(find.byKey(kNewTableKey)),
          table,
          reason: g.why('New table did not move'),
        );
        expect(
          tester.getRect(find.byKey(kRematchKey)),
          dock,
          reason: g.why('the dock did not move'),
        );
        expect(
          tester.getRect(find.byKey(_leaveKey)),
          leave,
          reason: g.why('the leave button did not move'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('IgnorePointer: a hit on the bubble misses it, and the '
        'leave button and the pip dots under it still take taps', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, 'pointer', players: 4);
      try {
        // The strip's centre is the gap between the second and third dot, so
        // the hits go to the dot centres. First the control arm, no line up.
        final List<Key> dotKeys = <Key>[
          for (int seat = 0; seat < 4; seat++) Key('game-seat-pip-$seat'),
        ];
        bool reaches(Key key) {
          final RenderObject box = tester.renderObject(find.byKey(key));
          final HitTestResult hit = tester.hitTestOnBinding(
            tester.getCenter(find.byKey(key)),
          );
          return hit.path.any(
            (HitTestEntry e) =>
                e.target is RenderObject &&
                _isUnder(e.target as RenderObject, box),
          );
        }

        final Map<Key, bool> before = <Key, bool>{
          for (final Key key in dotKeys) key: reaches(key),
        };
        expect(
          before.values,
          everyElement(isTrue),
          reason: g.why('control arm, no line up: every pip dot takes a hit'),
        );
        await g.emote(1, 'good_game');
        await g.emote(2, 'oops');
        await g.at(400);
        final RenderObject bubbleBox = tester.renderObject(
          find.byKey(chatLineKey(2)),
        );
        final Offset at = tester.getCenter(find.byKey(chatLineKey(2)));
        final HitTestResult onBubble = tester.hitTestOnBinding(at);
        final List<HitTestTarget> inside = <HitTestTarget>[
          for (final HitTestEntry e in onBubble.path)
            if (e.target is RenderObject &&
                _isUnder(e.target as RenderObject, bubbleBox))
              e.target,
        ];
        expect(
          inside,
          isEmpty,
          reason: g.why(
            'a hit at the bubble centre $at reached ${inside.length} '
            'render objects inside the bubble',
          ),
        );
        final Rect bubble = tester.getRect(find.byKey(chatLineKey(2)));
        final List<Key> under = <Key>[
          for (final Key key in dotKeys)
            if (_within(tester.getRect(find.byKey(key)), bubble)) key,
        ];
        expect(
          bubble.overlaps(tester.getRect(find.byKey(_pipKey))),
          isTrue,
          reason: g.why('geometry: the bubble $bubble covers the pip strip'),
        );
        expect(
          under,
          isNotEmpty,
          reason: g.why(
            'geometry: at least one pip dot lies inside the bubble $bubble; '
            'dots at ${<Rect>[for (final Key key in dotKeys) tester.getRect(find.byKey(key))]}',
          ),
        );
        for (final Key key in under) {
          final Offset dotAt = tester.getCenter(find.byKey(key));
          final RenderObject dotBox = tester.renderObject(find.byKey(key));
          final HitTestResult onDot = tester.hitTestOnBinding(dotAt);
          expect(
            onDot.path.any(
              (HitTestEntry e) =>
                  e.target is RenderObject &&
                  _isUnder(e.target as RenderObject, dotBox),
            ),
            isTrue,
            reason: g.why(
              'the hit at the centre $dotAt of $key, under the bubble '
              '$bubble, reaches the dot (control arm: ${before[key]})',
            ),
          );
          expect(
            onDot.path.any(
              (HitTestEntry e) =>
                  e.target is RenderObject &&
                  _isUnder(e.target as RenderObject, bubbleBox),
            ),
            isFalse,
            reason: g.why(
              'the hit at $dotAt does not touch the bubble above it',
            ),
          );
        }
        final Offset leaveAt = tester.getCenter(find.byKey(_leaveKey));
        final HitTestResult onLeave = tester.hitTestOnBinding(leaveAt);
        final RenderObject leaveBox = tester.renderObject(
          find.byKey(_leaveKey),
        );
        final bool hitLeave = onLeave.path.any(
          (HitTestEntry e) =>
              e.target is RenderObject &&
              _isUnder(e.target as RenderObject, leaveBox),
        );
        expect(
          hitLeave,
          isTrue,
          reason: g.why('the leave button still takes the tap'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('the look: seat-colour 2 dp border, paperElevated fill, '
        'rounded corners, no tail', (tester) async {
      final EndGame g = await openFinished(tester, 'look', players: 4);
      try {
        for (final int seat in const <int>[1, 3]) {
          await g.emote(seat, 'good_game');
          await g.at(400);
          final Finder bubble = find.byKey(chatLineKey(seat));
          final _Pixels px = await _Pixels.of(tester, bubble);
          final Rect r = tester.getRect(bubble);
          final Color border = LudoColors.seats[seat];
          final double mid = r.center.dy;
          expect(
            _near(px.at(r.left + 1, mid), border, 8),
            isTrue,
            reason: g.why(
              'seat $seat: the left border is the seat colour, read '
              '${px.at(r.left + 1, mid)} at ${r.left + 1}',
            ),
          );
          expect(
            _near(px.at(r.right - 1, mid), border, 8),
            isTrue,
            reason: g.why('seat $seat: the right border is the seat colour'),
          );
          expect(
            _near(px.at(r.center.dx, r.top + 1), border, 8),
            isTrue,
            reason: g.why('seat $seat: the top border is the seat colour'),
          );
          expect(
            _near(px.at(r.center.dx, r.bottom - 1), border, 8),
            isTrue,
            reason: g.why(
              'seat $seat: the bottom border is the seat colour, so '
              'there is no tail under the middle',
            ),
          );
          expect(
            _near(px.at(r.left + 4, mid), LudoColors.paperElevated, 8),
            isTrue,
            reason: g.why(
              'seat $seat: 4 dp in is the paperElevated fill, so the '
              'border is 2 dp, read ${px.at(r.left + 4, mid)}',
            ),
          );
          expect(
            _near(px.at(r.left + 0.5, r.top + 0.5), border, 8),
            isFalse,
            reason: g.why(
              'seat $seat: the corner pixel is not border colour, so '
              'the corners are rounded',
            ),
          );
        }
      } finally {
        await g.done();
      }
    });

    testWidgets('the text: the name in w700, then the line in w500, '
        'labelLarge, one line with an ellipsis', (tester) async {
      final EndGame g = await openFinished(tester, 'weights');
      try {
        await g.emote(1, 'good_game');
        await g.at(400);
        final Finder bubble = lineOf(g, 1);
        final RichText rich = tester.widget<RichText>(
          find.descendant(of: bubble, matching: find.byType(RichText)).first,
        );
        final List<(String, TextStyle)> leaves = spanLeaves(rich.text);
        final int nameAt = leaves.indexWhere(
          ((String, TextStyle) l) => l.$1.contains('Bob'),
        );
        final int lineAt = leaves.indexWhere(
          ((String, TextStyle) l) => l.$1.contains('Good game'),
        );
        expect(
          nameAt,
          isNonNegative,
          reason: g.why('a span carries the name: $leaves'),
        );
        expect(
          lineAt,
          isNonNegative,
          reason: g.why('a span carries the line: $leaves'),
        );
        expect(
          nameAt,
          isNot(lineAt),
          reason: g.why('the name and the line are two spans: $leaves'),
        );
        expect(nameAt, lessThan(lineAt), reason: g.why('the name comes first'));
        expect(
          leaves[nameAt].$2.fontWeight,
          FontWeight.w700,
          reason: g.why('name w700'),
        );
        expect(
          leaves[lineAt].$2.fontWeight,
          FontWeight.w500,
          reason: g.why('line w500'),
        );
        final double label = Theme.of(tester.element(bubble))
            .textTheme
            .labelLarge!
            .fontSize!;
        expect(
          leaves[nameAt].$2.fontSize,
          label,
          reason: g.why('labelLarge size'),
        );
        expect(
          leaves[lineAt].$2.fontSize,
          label,
          reason: g.why('labelLarge size'),
        );
        expect(rich.maxLines, 1, reason: g.why('one line'));
        expect(rich.overflow, TextOverflow.ellipsis, reason: g.why('ellipsis'));
      } finally {
        await g.done();
      }
    });
  });
}
