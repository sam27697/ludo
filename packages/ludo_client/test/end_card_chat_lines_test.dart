// Screen proof for C-485 D6 items 5, 6, 7 and 8 (order 488): the lines other
// seats say, shown on the end card. Written from work/ludo/orders/C-485 and
// C-478 alone; the implementation (order 485) was being written in another
// tree and has not been read.
//
// Two halves. The game screen cases drive a real GameScreen over a real
// RoomController on FakeTransport (test/support/end_card_chat_harness.dart),
// every state a decoded wire frame, time measured from the frame the `emote`
// push was flushed on, and reach the new widgets by key only. The direct
// cases mount an EndCard with chatLines and EndCardChatLine; they sit between
// the BEGIN direct and END direct markers and do not compile until the
// implementation lands. The surface is 360x800 at pixel ratio 1.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - EndCardChatLine's constructor is not given. The direct cases call it
//     with the four fields as named arguments (seat, name, text, serial).
//   - D5.2 says the name is w700 and the line w500 but not what sits between
//     them; the cases require two different spans, the name before the line,
//     and no particular separator.
//   - How the opacity is animated is not given. The measure multiplies every
//     Opacity / FadeTransition above the bubble's text. A fade done with a
//     colour alpha instead would read as 1.0 and fail the fade cases.
//   - D5.2 says "paper fill" and cites C-478 D5.4, whose amendment A1 makes
//     the fill paperElevated. The look case follows A1.
//   - The soft shadow of D5.2 is not asserted: it has no stable pixel to
//     read against the card behind it.
//   - "kSpace3 from the top" is read as the top of the EndCard widget, which
//     is the top of the card's scroll area.
//   - A spectator seeing the lines is not asserted: D4 does not say.
//   - D4 does not say whether a line already up survives the LOBBY change to
//     a rematch LOBBY; the cases do not assert either way.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/chat_bubble.dart';
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

// BEGIN direct
const Key _shotKey = Key('c485-shot');

/// An EndCard in an EndCardFrame, the way the finished body mounts it, with
/// [lines] on it.
Widget _lineTree({
  required List<EndCardChatLine> lines,
  EndKind kind = EndKind.loser,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool reduced = false,
  double trailing = 300,
}) => rollTrayHarness(
  RepaintBoundary(
    key: _shotKey,
    child: Scaffold(
      body: EndCardFrame(
        card: EndCard(
          mySeat: 0,
          winnerSeat: switch (kind) {
            EndKind.winner => 0,
            EndKind.loser => 1,
            EndKind.ended => null,
          },
          winnerName: switch (kind) {
            EndKind.winner => 'Sam',
            EndKind.loser => 'Bob',
            EndKind.ended => null,
          },
          seatColors: LudoColors.seats,
          stats: null,
          verifyUrl: null,
          onVerify: () {},
          onNewTable: () {},
          onRematch: () {},
          chatLines: lines,
        ),
        trailing: SizedBox(height: trailing),
      ),
    ),
  ),
  locale: locale,
  textScale: textScale,
  disableAnimations: reduced,
);

Future<void> _mountLines(
  WidgetTester tester,
  Widget tree, {
  Size size = const Size(360, 800),
  bool settle = true,
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = size;
  await tester.pumpWidget(tree);
  if (settle) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

EndCardChatLine _line(
  int seat,
  int serial, {
  String? name,
  String text = 'Good game',
}) => EndCardChatLine(
  seat: seat,
  name: name ?? kNames[seat]!,
  text: text,
  serial: serial,
);

/// The pixels of the card, read at logical points (the surface is ratio 1).
class _Pixels {
  _Pixels(this.image, this.data);

  final ui.Image image;
  final ByteData data;

  static Future<_Pixels> of(WidgetTester tester) async {
    final RenderRepaintBoundary boundary = tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
    final ui.Image? image = await tester.runAsync<ui.Image>(
      () => boundary.toImage(),
    );
    final ByteData? data = await tester.runAsync<ByteData?>(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return _Pixels(image!, data!);
  }

  Color at(double x, double y) {
    final int i = (y.floor() * image.width + x.floor()) * 4;
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

// END direct

void main() {
  // -------------------------------------------------------------------
  // Item 5: what shows, when.
  // -------------------------------------------------------------------
  group('5. a received line on the end card', () {
    for (final EndKind kind in <EndKind>[EndKind.winner, EndKind.loser]) {
      for (final bool ar in const <bool>[false, true]) {
        testWidgets('${kind.name} FINISHED, ${ar ? 'ar' : 'en'}: a line from '
            'another seat and my own both show, named', (tester) async {
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
            await g.emote(0, 'ha_ha');
            _expectLine(g, 0, 'Sam', endLine('ha_ha', ar: ar));
            expect(chatLineSeats(tester), <int>[
              0,
              1,
            ], reason: g.why('both lines up'));
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
        expect(
          boardBubbleSeats(tester),
          isEmpty,
          reason: g.why('and no board bubble either'),
        );
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

    testWidgets('two seats show two bubbles, the older on top; a seat that '
        'speaks again goes to the bottom', (tester) async {
      final EndGame g = await openFinished(tester, '6 order', players: 4);
      try {
        await g.emote(2, 'hi');
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(1, 'oops');
        expect(chatLinesTopDown(tester), <int>[
          2,
          1,
        ], reason: g.why('seat 2 spoke first, so it is on top'));
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(2, 'good_game');
        expect(chatLinesTopDown(tester), <int>[
          1,
          2,
        ], reason: g.why('seat 2 spoke again, so it is newest, at the bottom'));
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(3, 'lucky');
        await g.s.pump(const Duration(milliseconds: 50));
        await g.emote(0, 'ha_ha');
        expect(chatLinesTopDown(tester), <int>[
          1,
          2,
          3,
          0,
        ], reason: g.why('four seats, four bubbles, oldest first'));
        _expectLine(g, 0, 'Sam', 'Ha ha ha');
        _expectLine(g, 3, 'Dan', 'So lucky!');
      } finally {
        await g.done();
      }
    });

    testWidgets('each seat\'s line ends at its own 2500 ms', (tester) async {
      final EndGame g = await openFinished(tester, '6 two lives', players: 4);
      try {
        await g.emote(1, 'hi');
        await g.s.pump(const Duration(milliseconds: 1000));
        final int t1 = g.zero;
        await g.emote(2, 'oops');
        expect(chatLineSeats(tester), <int>[1, 2], reason: g.why('both show'));
        await g.s.pump(Duration(milliseconds: t1 + 2510 - g.s.clockMs));
        expect(chatLineSeats(tester), <int>[
          2,
        ], reason: g.why('seat 1 expired at its own 2500 ms; seat 2 did not'));
        await g.at(2510);
        _expectNoLines(g, 'seat 2 expires too');
      } finally {
        await g.done();
      }
    });

    testWidgets('two lines delivered in one frame both show', (tester) async {
      final EndGame g = await openFinished(tester, '6 one frame', players: 4);
      try {
        g.s.steps.add('two emotes, one pump');
        g.drive.transport.pushText(emoteFrame(seat: 1, emote: 'hi'));
        g.drive.transport.pushText(emoteFrame(seat: 3, emote: 'oops'));
        await tester.pump();
        await tester.pump();
        expect(chatLineSeats(tester), <int>[
          1,
          3,
        ], reason: g.why('both lines from one frame'));
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
        await g.emote(2, 'revenge');
        expect(chatLineSeats(tester), <int>[
          1,
          2,
        ], reason: g.why('fixture: two lines up'));
        await g.rematchLobby(by: 1);
        await g.startRematchGame(turnSeat: 1);
        await g.s.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(kChatButtonKey),
          findsOneWidget,
          reason: g.why('fixture: the next game is PLAYING'),
        );
        _expectNoLines(g, 'while the next game plays');
        expect(
          boardBubbleSeats(tester),
          isEmpty,
          reason: g.why(
            'and the end card lines did not turn into board '
            'bubbles',
          ),
        );
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 50));
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('fixture: the second game ended, its card is up'),
        );
        _expectNoLines(g, 'on the second end card, 150 ms after the lines');
      } finally {
        await g.done();
      }
    });

    testWidgets('the PLAYING to FINISHED change clears the board bubbles '
        'and does not turn them into card lines', (tester) async {
      final EndGame g = await openPlaying(tester, '8 playing to finished');
      try {
        await g.emote(1, 'good_game');
        expect(boardBubbleSeats(tester), <int>[
          1,
        ], reason: g.why('fixture: the board bubble is up in PLAYING'));
        _expectNoLines(g, 'PLAYING: the lines are the board\'s');
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('fixture: the end card is up'),
        );
        expect(
          boardBubbleSeats(tester),
          isEmpty,
          reason: g.why('game_over cleared the board bubble'),
        );
        _expectNoLines(g, 'a PLAYING line is not an end card line');
        await g.s.pump(const Duration(milliseconds: 3000));
        _expectNoLines(g, 'and none came back');
        await g.emote(1, 'ha_ha');
        _expectLine(g, 1, 'Bob', 'Ha ha ha');
        expect(
          boardBubbleSeats(tester),
          isEmpty,
          reason: g.why(
            'a line after game_over is the card\'s, not the '
            'board\'s',
          ),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a resync (a seq gap answered by a snapshot) clears every '
        'line', (tester) async {
      final EndGame g = await openFinished(tester, '8 resync', players: 4);
      try {
        await g.emote(1, 'hi');
        await g.emote(2, 'oops');
        expect(chatLineSeats(tester), <int>[
          1,
          2,
        ], reason: g.why('fixture: two lines'));
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
        await g.emote(3, 'oops');
        expect(chatLineSeats(tester), <int>[
          1,
          3,
        ], reason: g.why('fixture: two lines up before the drop'));
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

  // -------------------------------------------------------------------
  // Fit.
  // -------------------------------------------------------------------
  group('fit', () {
    for (final bool ar in const <bool>[false, true]) {
      testWidgets('360 x 640 at 2x text, ${ar ? 'ar' : 'en'}: four lines, '
          'no overflow, each inside the screen', (tester) async {
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
            1,
            2,
            3,
          ], reason: g.why('four bubbles'));
          for (final int seat in const <int>[0, 1, 2, 3]) {
            final Rect r = tester.getRect(find.byKey(chatLineKey(seat)));
            expect(
              r.left,
              greaterThanOrEqualTo(0.0),
              reason: g.why('bubble $seat $r inside the screen on the left'),
            );
            expect(
              r.right,
              lessThanOrEqualTo(360.0),
              reason: g.why('bubble $seat $r inside the screen on the right'),
            );
          }
          expect(tester.takeException(), isNull, reason: g.why('no overflow'));
        } finally {
          await g.done();
        }
      });
    }
  });

  // BEGIN direct
  // -------------------------------------------------------------------
  // Items 5 to 7 on the widget alone.
  // -------------------------------------------------------------------
  group('direct EndCard: the lines overlay', () {
    testWidgets('a column keyed end-card-chat-lines of one bubble per seat, '
        'ordered by serial whatever order they are handed in, kSpace2 apart, '
        'kSpace3 from the top, centred', (tester) async {
      await _mountLines(
        tester,
        _lineTree(
          lines: <EndCardChatLine>[
            _line(2, 3),
            _line(0, 1),
            _line(3, 4),
            _line(1, 2),
          ],
        ),
      );
      expect(find.byKey(kChatLinesKey), findsOneWidget);
      expect(chatLineSeats(tester), <int>[0, 1, 2, 3]);
      expect(
        chatLinesTopDown(tester),
        <int>[0, 1, 2, 3],
        reason: 'oldest serial on top: serials 1, 2, 3, 4 are seats 0, 1, 2, 3',
      );
      final Rect card = tester.getRect(find.byType(EndCard));
      final List<Rect> rects = <Rect>[
        for (final int seat in chatLinesTopDown(tester))
          tester.getRect(find.byKey(chatLineKey(seat))),
      ];
      expect(
        rects.first.top - card.top,
        closeTo(kSpace3, 0.5),
        reason: 'the first bubble is kSpace3 below the top of the card',
      );
      for (int i = 1; i < rects.length; i++) {
        expect(
          rects[i].top - rects[i - 1].bottom,
          closeTo(kSpace2, 0.5),
          reason: 'bubbles ${i - 1} and $i are kSpace2 apart',
        );
      }
      for (final Rect r in rects) {
        expect(
          r.center.dx,
          closeTo(card.center.dx, 1.0),
          reason: 'each bubble is centred on the card',
        );
      }
      expect(tester.takeException(), isNull);
    });

    for (final (double, double) row in const <(double, double)>[
      (800, 320),
      (360, 320),
      (300, 268),
    ]) {
      testWidgets('a long line is ${row.$2} dp wide on a ${row.$1} dp card: '
          'the lesser of 320 and the width minus 2 x kSpace4', (tester) async {
        await _mountLines(
          tester,
          _lineTree(lines: <EndCardChatLine>[_line(1, 1, text: 'M' * 80)]),
          size: Size(row.$1, 800),
        );
        final Rect r = tester.getRect(find.byKey(chatLineKey(1)));
        expect(
          r.width,
          closeTo(row.$2, 1.0),
          reason: 'bubble $r on a ${row.$1} dp card',
        );
        await tester.pumpWidget(
          _lineTree(lines: <EndCardChatLine>[_line(1, 2, text: 'Hi')]),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.getRect(find.byKey(chatLineKey(1))).width,
          lessThan(row.$2 - 40),
          reason: 'a short line is its own width, not the maximum',
        );
      });
    }

    testWidgets('the overlay takes no layout space: the panel, New table and '
        'the dock sit where they sat without it', (tester) async {
      await _mountLines(tester, _lineTree(lines: const <EndCardChatLine>[]));
      final Rect panel = tester.getRect(find.byKey(const Key('end-card-lose')));
      final Rect table = tester.getRect(find.byKey(kNewTableKey));
      final Rect dock = tester.getRect(find.byKey(kRematchKey));
      expect(find.byKey(kChatLinesKey), findsNothing);
      await tester.pumpWidget(
        _lineTree(
          lines: <EndCardChatLine>[_line(0, 1), _line(1, 2), _line(2, 3)],
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getRect(find.byKey(const Key('end-card-lose'))),
        panel,
        reason: 'the panel did not move',
      );
      expect(
        tester.getRect(find.byKey(kNewTableKey)),
        table,
        reason: 'New table did not move',
      );
      expect(
        tester.getRect(find.byKey(kRematchKey)),
        dock,
        reason: 'the dock did not move',
      );
    });

    testWidgets('the overlay is outside the scroll: it stays put while the '
        'card scrolls', (tester) async {
      await _mountLines(
        tester,
        _lineTree(lines: <EndCardChatLine>[_line(1, 1)], trailing: 1500),
        size: const Size(360, 640),
      );
      final Rect bubble = tester.getRect(find.byKey(chatLineKey(1)));
      final Rect panel = tester.getRect(find.byKey(const Key('end-card-lose')));
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -200),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final Rect panelAfter = tester.getRect(
        find.byKey(const Key('end-card-lose')),
      );
      expect(
        panelAfter.top,
        lessThan(panel.top - 100),
        reason: 'fixture: the card scrolled ($panel to $panelAfter)',
      );
      expect(
        tester.getRect(find.byKey(chatLineKey(1))),
        bubble,
        reason: 'the bubble did not scroll with the card',
      );
    });

    testWidgets('the overlay is IgnorePointer: a hit at a bubble reaches '
        'nothing inside it', (tester) async {
      await _mountLines(
        tester,
        _lineTree(lines: <EndCardChatLine>[_line(1, 1), _line(2, 2)]),
      );
      final RenderObject root = tester.renderObject(find.byKey(kChatLinesKey));
      for (final int seat in const <int>[1, 2]) {
        final Offset at = tester.getCenter(find.byKey(chatLineKey(seat)));
        final HitTestResult result = tester.hitTestOnBinding(at);
        final List<HitTestTarget> inside = <HitTestTarget>[
          for (final HitTestEntry e in result.path)
            if (e.target is RenderObject &&
                _isUnder(e.target as RenderObject, root))
              e.target,
        ];
        expect(
          inside,
          isEmpty,
          reason:
              'a hit at the centre of bubble $seat $at reached '
              '${inside.length} render objects inside end-card-chat-lines',
        );
      }
    });

    testWidgets('the look: seat-colour 2 dp border, paperElevated fill, '
        'rounded corners, no tail', (tester) async {
      await _mountLines(
        tester,
        _lineTree(lines: <EndCardChatLine>[_line(1, 1), _line(3, 2)]),
      );
      final _Pixels px = await _Pixels.of(tester);
      for (final int seat in const <int>[1, 3]) {
        final Rect r = tester.getRect(find.byKey(chatLineKey(seat)));
        final Color border = LudoColors.seats[seat];
        final double mid = r.center.dy;
        expect(
          _near(px.at(r.left + 1, mid), border, 8),
          isTrue,
          reason:
              'seat $seat: the left border is the seat colour, read '
              '${px.at(r.left + 1, mid)} at ${r.left + 1}',
        );
        expect(
          _near(px.at(r.right - 1, mid), border, 8),
          isTrue,
          reason: 'seat $seat: the right border is the seat colour',
        );
        expect(
          _near(px.at(r.center.dx, r.top + 1), border, 8),
          isTrue,
          reason: 'seat $seat: the top border is the seat colour',
        );
        expect(
          _near(px.at(r.center.dx, r.bottom - 1), border, 8),
          isTrue,
          reason:
              'seat $seat: the bottom border is the seat colour, so '
              'there is no tail under the middle',
        );
        expect(
          _near(px.at(r.left + 4, mid), LudoColors.paperElevated, 8),
          isTrue,
          reason:
              'seat $seat: 4 dp in is the paperElevated fill, so the '
              'border is 2 dp, read ${px.at(r.left + 4, mid)}',
        );
        expect(
          _near(px.at(r.left + 0.5, r.top + 0.5), border, 8),
          isFalse,
          reason:
              'seat $seat: the corner pixel is not border colour, so '
              'the corners are rounded',
        );
      }
    });

    testWidgets('the text: the name in w700, then the line in w500, '
        'labelLarge, one line with an ellipsis', (tester) async {
      await _mountLines(
        tester,
        _lineTree(lines: <EndCardChatLine>[_line(1, 1, text: 'Good game')]),
      );
      final Finder bubble = find.byKey(chatLineKey(1));
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
      expect(nameAt, isNonNegative, reason: 'a span carries the name: $leaves');
      expect(lineAt, isNonNegative, reason: 'a span carries the line: $leaves');
      expect(
        nameAt,
        isNot(lineAt),
        reason:
            'the name and the line are two '
            'spans: $leaves',
      );
      expect(nameAt, lessThan(lineAt), reason: 'the name comes first');
      expect(
        leaves[nameAt].$2.fontWeight,
        FontWeight.w700,
        reason: 'name w700',
      );
      expect(
        leaves[lineAt].$2.fontWeight,
        FontWeight.w500,
        reason: 'line w500',
      );
      final double label = Theme.of(tester.element(bubble))
          .textTheme
          .labelLarge!
          .fontSize!;
      expect(leaves[nameAt].$2.fontSize, label, reason: 'labelLarge size');
      expect(leaves[lineAt].$2.fontSize, label, reason: 'labelLarge size');
      expect(rich.maxLines, 1, reason: 'one line');
      expect(rich.overflow, TextOverflow.ellipsis, reason: 'ellipsis');
    });

    testWidgets('a long name and a long line stay on one line at 2x text', (
      tester,
    ) async {
      await _mountLines(
        tester,
        _lineTree(
          lines: <EndCardChatLine>[_line(1, 1, text: 'Hi')],
          textScale: 2.0,
        ),
      );
      final double short = tester.getRect(find.byKey(chatLineKey(1))).height;
      await tester.pumpWidget(
        _lineTree(
          lines: <EndCardChatLine>[_line(1, 2, name: 'N' * 40, text: 'M' * 80)],
          textScale: 2.0,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.getRect(find.byKey(chatLineKey(1))).height,
        closeTo(short, 0.5),
        reason: 'the long bubble is as tall as the short one: one line',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('motion: scale 0.6 to 1.0 in 160 ms, fade over the last '
        '250 ms of the life', (tester) async {
      final Widget tree = _lineTree(lines: <EndCardChatLine>[_line(1, 1)]);
      await _mountLines(tester, tree);
      final Finder line = find.byKey(chatLineKey(1));
      final double base = textWidthUnder(tester, line);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(tree);
      final List<_Sample> trace = await _trace(
        tester,
        line,
        base,
        (Duration d) => tester.pump(d),
      );
      _expectMotion(trace, (String m) => 'direct motion: $m');
    });

    testWidgets('reduced motion: full size and opacity from the first '
        'frame', (tester) async {
      final Widget tree = _lineTree(
        lines: <EndCardChatLine>[_line(1, 1)],
        reduced: true,
      );
      await _mountLines(tester, tree, settle: false);
      final Finder line = find.byKey(chatLineKey(1));
      final double first = textWidthUnder(tester, line);
      expect(alphaUnder(tester, line), closeTo(1.0, 0.01));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        first,
        closeTo(textWidthUnder(tester, line), 0.5),
        reason: 'the first frame is already full size',
      );
      await tester.pump(const Duration(milliseconds: 2000));
      expect(
        alphaUnder(tester, line),
        closeTo(1.0, 0.01),
        reason: 'no fade under reduced motion at 2400 ms',
      );
    });

    for (final bool ar in const <bool>[false, true]) {
      testWidgets('semantics ${ar ? 'ar' : 'en'}: live region, label '
          'chatSaid(name, line)', (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        try {
          await _mountLines(
            tester,
            _lineTree(
              lines: <EndCardChatLine>[
                _line(1, 1, text: endLine('good_game', ar: ar)),
              ],
              locale: Locale(ar ? 'ar' : 'en'),
            ),
          );
          final SemanticsNode node = tester.getSemantics(
            find.byKey(chatLineKey(1)),
          );
          expect(node.label, said('Bob', endLine('good_game', ar: ar)));
          expect(node.flagsCollection.isLiveRegion, isTrue);
        } finally {
          handle.dispose();
        }
      });
    }
  });
  // END direct
}
