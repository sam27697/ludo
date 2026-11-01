// Screen proof for C-520 D1 and D2: the device keeps the whole quick-message
// cadence, and a resting control says for how long. Written from
// work/ludo/orders/C-520-sweep36-refusals.md alone; the implementation (order
// 521) was being written in another tree and has not been read.
//
// A real GameScreen over a real RoomController on FakeTransport, every state
// a decoded wire frame (support/end_card_chat_harness.dart over
// c468_harness.dart and roll_tray_harness.dart). Time is driven by pumping
// the harness's fake clock: Scn.pump advances `tester.pump(duration)` and
// keeps the total in Scn.clockMs, and every instant below is a reading of
// that clock. Nothing waits on real time and nothing sleeps. The surface is
// 360x800 at pixel ratio 1.
//
// The ack is the server's own `emote` copy carrying `re` (EndGame.answerEmote),
// which is what completes RoomController.sendEmote with true. A refusal is the
// server's `error` reply to the same request (errorReplyFrame).
//
// "Resting" is read three ways, none of which needs the implementation's
// internals: the chat icon drawn at 38 % of its ready opacity (the way
// quick_chat_sheet_test.dart reads it), a reply chip drawn at 38 % (chipAlpha),
// and the key `game-chat-rest-ring`. The ring's colour and drain are read from
// pixels: dark-teal pixels (LudoColors.inkMuted) around the 48 dp box, counted
// outside the icon's own area.
//
// This file does not compile on a tree without the ARB getter chatResting
// (C-520 D2); that is the expected failing arm on the base. Where a case needs
// nothing else new it fails on the base only because the ring is not there and
// the cadence is the bare 3000 ms of quick_chat.dart:31.
//
// Every failure reason starts with the scenario name and ends with the frames
// and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - "Device clock instants" is not pinned to an API. The rest is driven here
//     by the harness's fake clock, which only moves Timers and
//     package:clock. A screen that reads DateTime.now() would see no time pass
//     under tester.pump and the sixty second cases cannot go green; that would
//     be the screen's choice of clock, not a wrong test.
//   - The ring's stroke width, radius and shape (circle or rounded square) are
//     not stated, so the drain is read as a count of ink pixels outside the
//     icon area, with wide bands: about half at half time, strictly less at
//     each later reading, and still some at 2700 ms.
//   - The hint is read from the SemanticsNode of the keyed control
//     (`game-chat-button`, `end-card-reply-<id>`). A hint carried by a node
//     that does not merge into the keyed one would not be seen.
//   - "A ready control carries no hint" is read as: the node's hint does not
//     contain the chatResting text.
//   - The refusal while not connected: the reconnect UI owns that state, so
//     the case reads "no new invalidTap, no ring, and a ready button after the
//     resume".

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/room_controller.dart' show RoomPhase;
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _ringKey = Key('game-chat-rest-ring');

/// chatResting, typed out from the contract's table on purpose.
const String _hintEn = 'Available again in a moment';
const String _hintAr = 'بترجع بعد لحظات';

/// The ids the sheet offers, used in turn so ten sends are ten different taps.
const List<String> _ids = <String>[
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
];

// ---------------------------------------------------------------------
// Reading the screen.
// ---------------------------------------------------------------------

Finder _button() => find.byKey(kChatButtonKey);

/// The chat icon's drawn opacity: every Opacity / FadeTransition above it
/// times its own colour alpha.
double _iconAlpha(WidgetTester tester) {
  final Finder icon = find.descendant(
    of: _button(),
    matching: find.byIcon(Icons.chat_bubble_outline_rounded),
  );
  expect(icon, findsOneWidget, reason: 'the chat icon is in the button');
  final Element element = tester.element(icon);
  final Icon widget = element.widget as Icon;
  final IconThemeData theme = IconTheme.of(element);
  double alpha = (widget.color ?? theme.color)?.a ?? 1.0;
  alpha *= theme.opacity ?? 1.0;
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

/// Every Opacity above [element], multiplied.
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

String _hintOf(WidgetTester tester, Key key) =>
    tester.getSemantics(find.byKey(key)).hint;

/// What TalkBack reads first: the node's label, or for an IconButton the
/// tooltip it carries in place of one.
String _labelOf(WidgetTester tester, Key key) {
  final SemanticsNode node = tester.getSemantics(find.byKey(key));
  return node.label.isNotEmpty ? node.label : node.tooltip;
}

/// Dark-teal (LudoColors.inkMuted) pixels in the ring's rect, outside the
/// 36 dp square at the button's centre where the icon is drawn. Reads the
/// whole screen from the top-most repaint boundary, at ratio 1.
Future<int> _ringInk(EndGame g, String when) async {
  final WidgetTester tester = g.tester;
  expect(
    find.byKey(_ringKey),
    findsOneWidget,
    reason: g.why('game-chat-rest-ring is on screen to be read $when'),
  );
  final Rect rect = tester.getRect(find.byKey(_ringKey));
  final Offset centre = tester.getCenter(_button());
  RenderRepaintBoundary? top;
  RenderObject? walker = tester.renderObject(find.byKey(_ringKey));
  while (walker != null) {
    if (walker is RenderRepaintBoundary) {
      top = walker;
    }
    walker = walker.parent;
  }
  final RenderRepaintBoundary boundary = top!;
  final ui.Image? image = await tester.runAsync<ui.Image>(
    () => boundary.toImage(),
  );
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final Offset origin = boundary.localToGlobal(Offset.zero);
  const Color ink = LudoColors.inkMuted;
  final int inkR = (ink.r * 255).round();
  final int inkG = (ink.g * 255).round();
  final int inkB = (ink.b * 255).round();
  int count = 0;
  for (int y = rect.top.floor() - 1; y <= rect.bottom.ceil() + 1; y++) {
    for (int x = rect.left.floor() - 1; x <= rect.right.ceil() + 1; x++) {
      if ((x + 0.5 - centre.dx).abs() < 18 &&
          (y + 0.5 - centre.dy).abs() < 18) {
        continue;
      }
      final int lx = x - origin.dx.floor();
      final int ly = y - origin.dy.floor();
      if (lx < 0 || ly < 0 || lx >= image!.width || ly >= image.height) {
        continue;
      }
      final int i = (ly * image.width + lx) * 4;
      if ((data!.getUint8(i) - inkR).abs() <= 24 &&
          (data.getUint8(i + 1) - inkG).abs() <= 24 &&
          (data.getUint8(i + 2) - inkB).abs() <= 24 &&
          data.getUint8(i + 3) == 255) {
        count += 1;
      }
    }
  }
  image!.dispose();
  return count;
}

// ---------------------------------------------------------------------
// Driving the screen.
// ---------------------------------------------------------------------

/// Pumps to the absolute fake-clock reading [ms]: 100 ms frames while far,
/// 5 ms frames for the last 200 ms, so a boundary is known to within 5 ms and
/// the replay line carries two pump entries, not thousands.
Future<void> _goTo(EndGame g, int ms) async {
  final int far = ms - 200 - g.s.clockMs;
  if (far > 0) {
    await g.s.pump(
      Duration(milliseconds: far),
      step: const Duration(milliseconds: 100),
    );
  }
  final int near = ms - g.s.clockMs;
  if (near > 0) {
    await g.s.pump(Duration(milliseconds: near), step: kC468Fine);
  }
}

/// Opens the sheet from the header button and taps the chip [id]; returns the
/// id of the `emote` request that went out.
Future<String> _pick(EndGame g, String id) async {
  final int before = g.sentCount;
  g.s.steps.add('tap game-chat-button, pick $id');
  await g.tester.tap(_button());
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 400));
  expect(
    find.byKey(kSheetKey),
    findsOneWidget,
    reason: g.why('the sheet opens to send $id'),
  );
  await g.tester.ensureVisible(find.byKey(sheetChipKey(id)));
  await g.tester.tap(find.byKey(sheetChipKey(id)));
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 400));
  return requestIdOf(
    g.drive.transport.sentRaw
        .skip(before)
        .singleWhere((String t) => frameType(t) == 'emote'),
  );
}

/// Picks [id] from the sheet and has the server copy come back; returns the
/// fake-clock reading (ms) of the ack.
Future<int> _sendAcked(EndGame g, String id) async {
  final String request = await _pick(g, id);
  g.s.steps.add('ack $request');
  await g.emote(g.me, id, re: request);
  return g.s.clockMs;
}

/// Ten acks as far apart as the server allows (3000 ms) plus a margin;
/// returns the ten ack readings, oldest first.
Future<List<int>> _tenAcks(EndGame g) async {
  final List<int> acks = <int>[];
  for (int i = 0; i < 10; i++) {
    if (acks.isNotEmpty) {
      await _goTo(g, acks.last + 3050);
    }
    acks.add(await _sendAcked(g, _ids[i]));
  }
  return acks;
}

/// The button state, as the contract defines it.
class _Chat {
  _Chat(this.g) : ready = _iconAlpha(g.tester);

  final EndGame g;
  final double ready;

  void expectResting(String when) {
    expect(
      _iconAlpha(g.tester) / ready,
      closeTo(0.38, 0.03),
      reason: g.why('the chat button is drawn at 38 % $when'),
    );
    expect(
      find.byKey(_ringKey),
      findsOneWidget,
      reason: g.why('game-chat-rest-ring is on screen $when'),
    );
  }

  void expectReady(String when) {
    expect(
      _iconAlpha(g.tester) / ready,
      closeTo(1.0, 0.03),
      reason: g.why('the chat button is drawn at full opacity $when'),
    );
    expect(
      find.byKey(_ringKey),
      findsNothing,
      reason: g.why('game-chat-rest-ring is gone $when'),
    );
  }

  /// A tap on the button now: nothing opens, nothing is sent, one invalidTap.
  Future<void> expectTapRefused(String when) async {
    final int cues = g.s.count(FeedbackCue.invalidTap);
    final int sent = g.sentCount;
    g.s.steps.add('tap game-chat-button $when');
    await g.tester.tap(_button());
    await g.tester.pump();
    await g.s.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(kSheetKey),
      findsNothing,
      reason: g.why('a tap on the resting button opens no sheet $when'),
    );
    expect(
      g.s.count(FeedbackCue.invalidTap),
      cues + 1,
      reason: g.why('a tap on the resting button plays invalidTap once $when'),
    );
    expect(
      g.sentCount,
      sent,
      reason: g.why('a tap on the resting button sends nothing $when'),
    );
  }

  /// A tap on the button now opens the sheet and plays nothing; closes it.
  Future<void> expectTapOpens(String when) async {
    final int cues = g.s.count(FeedbackCue.invalidTap);
    g.s.steps.add('tap game-chat-button $when');
    await g.tester.tap(_button());
    await g.tester.pump();
    await g.s.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(kSheetKey),
      findsOneWidget,
      reason: g.why('a ready button opens the sheet $when'),
    );
    expect(
      g.s.count(FeedbackCue.invalidTap),
      cues,
      reason: g.why('an open tap plays no invalidTap $when'),
    );
  }
}

void main() {
  setUpAll(loadAppFonts);

  // -------------------------------------------------------------------
  // D2 and D1: one ack.
  // -------------------------------------------------------------------
  testWidgets('one ack rests the button with the ring for 3000 ms, then '
      'it is ready and the ring is gone', (tester) async {
    final EndGame g = await openPlaying(tester, 'D1 one ack');
    try {
      final _Chat chat = _Chat(g);
      chat.expectReady('before any send');
      final int ack = await _sendAcked(g, 'hi');
      chat.expectResting('on the ack');
      await _goTo(g, ack + 1000);
      chat.expectResting('1000 ms after the ack');
      await _goTo(g, ack + 2900);
      chat.expectResting('2900 ms after the ack');
      await _goTo(g, ack + 3100);
      chat.expectReady('3100 ms after the ack');
      await chat.expectTapOpens('3100 ms after the ack');
    } finally {
      await g.done();
    }
  });

  testWidgets('the ring is a separate layer around the 48 dp box, at full '
      'opacity, not inside the faded button', (tester) async {
    final EndGame g = await openPlaying(tester, 'D2 ring geometry');
    try {
      await _sendAcked(g, 'hi');
      final Finder ring = find.byKey(_ringKey);
      expect(ring, findsOneWidget, reason: g.why('the ring is on screen'));
      expect(
        find.descendant(of: _button(), matching: ring),
        findsNothing,
        reason: g.why(
          'the ring is not inside game-chat-button, whose 38 % opacity would '
          'fade it',
        ),
      );
      expect(
        _opacityAbove(g.tester.element(ring)),
        closeTo(1.0, 1e-9),
        reason: g.why('no Opacity above the ring: it is drawn at full opacity'),
      );
      final Rect box = g.tester.getRect(_button());
      final Rect around = g.tester.getRect(ring);
      expect(
        around.center.dx,
        closeTo(box.center.dx, 1.0),
        reason: g.why('ring $around is centred on the button $box (x)'),
      );
      expect(
        around.center.dy,
        closeTo(box.center.dy, 1.0),
        reason: g.why('ring $around is centred on the button $box (y)'),
      );
      expect(
        around.width,
        greaterThanOrEqualTo(48.0 - 0.5),
        reason: g.why('ring $around goes around the 48 dp box ($box) (width)'),
      );
      expect(
        around.height,
        greaterThanOrEqualTo(48.0 - 0.5),
        reason: g.why('ring $around goes around the 48 dp box ($box) (height)'),
      );
    } finally {
      await g.done();
    }
  });

  testWidgets('the ring is drawn in inkMuted, full when the rest starts, '
      'draining to nothing while the button rests', (tester) async {
    final EndGame g = await openPlaying(tester, 'D2 ring drain');
    try {
      final int ack = await _sendAcked(g, 'hi');
      final int full = await _ringInk(g, 'on the ack');
      expect(
        full,
        greaterThan(0),
        reason: g.why(
          'ink-coloured (0xFF3D5F5A) pixels around the button on the ack, '
          'found $full',
        ),
      );
      await _goTo(g, ack + 1500);
      final int half = await _ringInk(g, 'at 1500 ms');
      expect(
        half / full,
        inInclusiveRange(0.3, 0.7),
        reason: g.why(
          'about half the arc is left at half the rest: $half of $full '
          'ink pixels at ack + 1500 ms',
        ),
      );
      await _goTo(g, ack + 2700);
      final int last = await _ringInk(g, 'at 2700 ms');
      expect(
        last,
        allOf(greaterThan(0), lessThan(half)),
        reason: g.why(
          'a sliver is left at 2700 ms and it is less than at 1500 ms: '
          '$last, then $half, started at $full',
        ),
      );
      expect(
        find.byKey(_ringKey),
        findsOneWidget,
        reason: g.why('the ring is still there at 2700 ms'),
      );
    } finally {
      await g.done();
    }
  });

  testWidgets('a tap on the resting button opens no sheet, sends nothing and '
      'plays invalidTap once; it does not extend the rest', (tester) async {
    final EndGame g = await openPlaying(tester, 'D3 resting tap');
    try {
      final _Chat chat = _Chat(g);
      final int ack = await _sendAcked(g, 'oops');
      await _goTo(g, ack + 600);
      chat.expectResting('600 ms after the ack');
      await chat.expectTapRefused('600 ms after the ack');
      await _goTo(g, ack + 2000);
      chat.expectResting('2000 ms after the ack, after a refused tap');
      await chat.expectTapRefused('2000 ms after the ack');
      await _goTo(g, ack + 3100);
      chat.expectReady('3100 ms after the ack, taps did not extend the rest');
    } finally {
      await g.done();
    }
  });

  testWidgets('someone else\'s emote neither rests the button nor shows the '
      'ring', (tester) async {
    final EndGame g = await openPlaying(tester, 'D1 others', players: 4);
    try {
      final _Chat chat = _Chat(g);
      await g.emote(2, 'hi');
      await g.emote(3, 'oops');
      await g.s.pump(const Duration(milliseconds: 100));
      chat.expectReady('after two other seats spoke');
    } finally {
      await g.done();
    }
  });

  // -------------------------------------------------------------------
  // D1: the minute.
  // -------------------------------------------------------------------
  testWidgets('ten acks inside a minute keep the button resting past 3 s '
      'until the tenth newest is 60 s old', (tester) async {
    final EndGame g = await openPlaying(tester, 'D1 ten acks');
    try {
      final _Chat chat = _Chat(g);
      final List<int> acks = await _tenAcks(g);
      expect(
        acks.last - acks.first,
        lessThan(60000),
        reason: g.why('fixture: the ten acks fit inside a minute: $acks'),
      );
      chat.expectResting('on the tenth ack');
      await _goTo(g, acks.last + 3100);
      chat.expectResting('3100 ms after the tenth ack, past the 3 s rest');
      await chat.expectTapRefused('3100 ms after the tenth ack');
      await _goTo(g, acks.first + 45000);
      chat.expectResting('45 s after the first ack');
      await _goTo(g, acks.first + 59950);
      chat.expectResting('50 ms before the first ack is 60 s old (acks $acks)');
      await _goTo(g, acks.first + 60050);
      chat.expectReady('50 ms after the first ack is 60 s old (acks $acks)');
      await chat.expectTapOpens('50 ms after the first ack is 60 s old');
    } finally {
      await g.done();
    }
  });

  testWidgets('nine acks inside a minute rest only 3000 ms after the last', (
    tester,
  ) async {
    final EndGame g = await openPlaying(tester, 'D1 nine acks');
    try {
      final _Chat chat = _Chat(g);
      final List<int> acks = <int>[];
      for (int i = 0; i < 9; i++) {
        if (acks.isNotEmpty) {
          await _goTo(g, acks.last + 3050);
        }
        acks.add(await _sendAcked(g, _ids[i]));
      }
      chat.expectResting('on the ninth ack');
      await _goTo(g, acks.last + 3100);
      chat.expectReady('3100 ms after the ninth ack (acks $acks)');
    } finally {
      await g.done();
    }
  });

  testWidgets('the ten-ack rest carries onto the end card: the chips are '
      'dimmed until the tenth newest is 60 s old, and no ring is drawn', (
    tester,
  ) async {
    final EndGame g = await openPlaying(tester, 'D1 ten acks, then the card');
    try {
      final List<int> acks = await _tenAcks(g);
      await _goTo(g, acks.last + 3200);
      await g.gameOver(1);
      await g.s.pump(const Duration(milliseconds: 100));
      expect(
        replyIds(tester),
        kLoserReplies,
        reason: g.why('fixture: the loser card has its chips'),
      );
      for (final String id in kLoserReplies) {
        expect(
          chipAlphaOf(g, id),
          closeTo(0.38, 0.03),
          reason: g.why(
            'chip $id is dimmed on the card, 3.3 s after the tenth ack '
            '(acks $acks)',
          ),
        );
      }
      expect(
        find.byKey(_ringKey),
        findsNothing,
        reason: g.why('the chips get no ring'),
      );
      await _goTo(g, acks.first + 59950);
      expect(
        chipAlphaOf(g, 'good_game'),
        closeTo(0.38, 0.03),
        reason: g.why('still dimmed 50 ms before 60 s (acks $acks)'),
      );
      await _goTo(g, acks.first + 60050);
      for (final String id in kLoserReplies) {
        expect(
          chipAlphaOf(g, id),
          closeTo(1.0, 0.03),
          reason: g.why('chip $id is live 50 ms after 60 s (acks $acks)'),
        );
      }
    } finally {
      await g.done();
    }
  });

  // -------------------------------------------------------------------
  // D1: the server stays the judge.
  // -------------------------------------------------------------------
  testWidgets('a RATE_LIMITED refusal while connected plays invalidTap once, '
      'shows the ring and rests 3000 ms from the refusal', (tester) async {
    final EndGame g = await openPlaying(tester, 'D1 refused');
    try {
      final _Chat chat = _Chat(g);
      final String request = await _pick(g, 'revenge');
      chat.expectReady('while the request is pending');
      await g.s.pump(const Duration(milliseconds: 1000));
      final int cues = g.s.count(FeedbackCue.invalidTap);
      final int sent = g.sentCount;
      g.s.steps.add('error RATE_LIMITED re=$request');
      await pushRaw(
        g.tester,
        g.drive,
        errorReplyFrame(re: request, code: 'RATE_LIMITED'),
      );
      final int refused = g.s.clockMs;
      await g.s.pump(const Duration(milliseconds: 20));
      expect(
        g.drive.controller.phase,
        RoomPhase.connected,
        reason: g.why('fixture: a refused emote leaves the screen connected'),
      );
      expect(
        g.s.count(FeedbackCue.invalidTap),
        cues + 1,
        reason: g.why('the refusal plays invalidTap exactly once'),
      );
      expect(
        g.sentCount,
        sent,
        reason: g.why('the refusal sends nothing, no retry'),
      );
      chat.expectResting('after the refusal');
      expect(
        chatLineSeats(tester),
        isEmpty,
        reason: g.why('a refused message shows no line'),
      );
      await _goTo(g, refused + 2900);
      chat.expectResting('2900 ms after the refusal');
      await _goTo(g, refused + 3100);
      chat.expectReady('3100 ms after the refusal');
      await chat.expectTapOpens('3100 ms after the refusal');
      expect(
        g.s.count(FeedbackCue.invalidTap),
        cues + 1,
        reason: g.why('and no cue beyond the refusal\'s one'),
      );
    } finally {
      await g.done();
    }
  });

  testWidgets('a refusal after an ack rests from the refusal, not from the '
      'ack', (tester) async {
    final EndGame g = await openPlaying(tester, 'D1 refused after ack');
    try {
      final _Chat chat = _Chat(g);
      final int ack = await _sendAcked(g, 'hi');
      await _goTo(g, ack + 3100);
      chat.expectReady('3100 ms after the ack');
      final String request = await _pick(g, 'nice');
      g.s.steps.add('error RATE_LIMITED re=$request');
      await pushRaw(
        g.tester,
        g.drive,
        errorReplyFrame(re: request, code: 'RATE_LIMITED'),
      );
      final int refused = g.s.clockMs;
      await g.s.pump(const Duration(milliseconds: 20));
      chat.expectResting('on the refusal');
      await _goTo(g, refused + 2900);
      chat.expectResting('2900 ms after the refusal');
      await _goTo(g, refused + 3100);
      chat.expectReady('3100 ms after the refusal');
    } finally {
      await g.done();
    }
  });

  testWidgets('a send that fails because the socket dropped does nothing '
      'new: no invalidTap, no ring, and the button is ready after the '
      'resume', (tester) async {
    final EndGame g = await openPlaying(tester, 'D1 dropped mid-send');
    try {
      final _Chat chat = _Chat(g);
      await _pick(g, 'hi');
      final int cues = g.s.count(FeedbackCue.invalidTap);
      g.s.steps.add('far side closes');
      g.drive.transport.endFromFarSide();
      await g.tester.pump();
      await g.s.pump(const Duration(milliseconds: 200));
      expect(
        g.drive.controller.phase,
        isNot(RoomPhase.connected),
        reason: g.why('fixture: the controller noticed the drop'),
      );
      expect(
        g.s.count(FeedbackCue.invalidTap),
        cues,
        reason: g.why(
          'the failed send happened while not connected: the reconnect UI '
          'owns that state, no invalidTap',
        ),
      );
      expect(
        find.byKey(_ringKey),
        findsNothing,
        reason: g.why('no ring for a send that failed while not connected'),
      );
      final FakeTransport next = FakeTransport();
      g.drive.enqueueTransport(next);
      final Future<void> reconnect = g.drive.controller.reconnect();
      await g.tester.runAsync(() => pumpEventQueue());
      await g.tester.pump();
      final String id = requestIdOf(
        next.sentRaw.lastWhere((String t) => frameType(t) == 'resume'),
      );
      g.s.steps.add('resume answered');
      next.pushText(
        roomReplyFrame(
          re: id,
          seats: g.seats,
          turn: awaitRollTurn(1),
          seq: g.drive.lastSeq + 1,
        ),
      );
      await reconnect;
      await g.tester.pump();
      await g.s.pump(const Duration(milliseconds: 100));
      expect(
        g.drive.controller.phase,
        RoomPhase.connected,
        reason: g.why('fixture: the resume landed'),
      );
      chat.expectReady('after the resume');
      expect(
        g.s.count(FeedbackCue.invalidTap),
        cues,
        reason: g.why('still no invalidTap after the resume'),
      );
    } finally {
      await g.done();
    }
  });

  // -------------------------------------------------------------------
  // D2: reduced motion.
  // -------------------------------------------------------------------
  testWidgets('with animations off the ring is still there at 2.5 s and gone '
      'at 3.1 s', (tester) async {
    final EndGame g = await openPlaying(
      tester,
      'D2 reduced motion',
      reduced: true,
    );
    try {
      final _Chat chat = _Chat(g);
      final int ack = await _sendAcked(g, 'hi');
      chat.expectResting('on the ack, animations off');
      await _goTo(g, ack + 1000);
      chat.expectResting('1000 ms after the ack, animations off');
      await _goTo(g, ack + 2500);
      chat.expectResting('2500 ms after the ack, animations off');
      await _goTo(g, ack + 3100);
      chat.expectReady('3100 ms after the ack, animations off');
    } finally {
      await g.done();
    }
  });

  // -------------------------------------------------------------------
  // D2: TalkBack.
  // -------------------------------------------------------------------
  for (final (Locale, String) row in const <(Locale, String)>[
    (Locale('en'), _hintEn),
    (Locale('ar'), _hintAr),
  ]) {
    final Locale locale = row.$1;
    final String hint = row.$2;

    testWidgets('the ARB has chatResting as the contract gives it '
        '(${locale.languageCode})', (tester) async {
      final AppLocalizations loc = await AppLocalizations.delegate.load(locale);
      expect(
        loc.chatResting,
        hint,
        reason: 'C-520 D2, chatResting in ${locale.languageCode}',
      );
    });

    testWidgets('the resting chat button carries the hint after its usual '
        'label; a ready one carries none (${locale.languageCode})', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final EndGame g = await openPlaying(
        tester,
        'D2 button hint ${locale.languageCode}',
        locale: locale,
      );
      try {
        final String label = _labelOf(tester, kChatButtonKey);
        expect(label, isNotEmpty, reason: g.why('fixture: the button speaks'));
        expect(
          _hintOf(tester, kChatButtonKey),
          isNot(contains(hint)),
          reason: g.why('a ready button has no chatResting hint'),
        );
        final int ack = await _sendAcked(g, 'hi');
        expect(
          _hintOf(tester, kChatButtonKey),
          hint,
          reason: g.why('the resting button\'s hint is chatResting'),
        );
        expect(
          _labelOf(tester, kChatButtonKey),
          label,
          reason: g.why('the label is the usual one, the hint comes after it'),
        );
        await _goTo(g, ack + 2900);
        expect(
          _hintOf(tester, kChatButtonKey),
          hint,
          reason: g.why('still the hint at 2900 ms'),
        );
        await _goTo(g, ack + 3100);
        expect(
          _hintOf(tester, kChatButtonKey),
          isNot(contains(hint)),
          reason: g.why('the hint is gone when the button is ready'),
        );
        expect(
          _labelOf(tester, kChatButtonKey),
          label,
          reason: g.why('and the label is unchanged'),
        );
      } finally {
        await g.done();
        handle.dispose();
      }
    });

    testWidgets('every resting end card chip carries the hint after its '
        'usual label; a ready one carries none (${locale.languageCode})', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final EndGame g = await openFinished(
        tester,
        'D2 chip hint ${locale.languageCode}',
        locale: locale,
      );
      try {
        final Map<String, String> labels = <String, String>{
          for (final String id in kLoserReplies)
            id: _labelOf(tester, replyKey(id)),
        };
        for (final String id in kLoserReplies) {
          expect(
            labels[id],
            endLine(id, ar: locale.languageCode == 'ar'),
            reason: g.why('fixture: chip $id speaks its line'),
          );
          expect(
            _hintOf(tester, replyKey(id)),
            isNot(contains(hint)),
            reason: g.why('a ready chip $id has no chatResting hint'),
          );
        }
        final int before = g.sentCount;
        await tapReply(g, 'good_game');
        await g.answerEmote(before, id: 'good_game');
        await g.at(600);
        for (final String id in kLoserReplies) {
          expect(
            _hintOf(tester, replyKey(id)),
            hint,
            reason: g.why('resting chip $id carries chatResting'),
          );
          expect(
            _labelOf(tester, replyKey(id)),
            labels[id],
            reason: g.why('resting chip $id keeps its usual label'),
          );
        }
        await g.at(3100);
        for (final String id in kLoserReplies) {
          expect(
            _hintOf(tester, replyKey(id)),
            isNot(contains(hint)),
            reason: g.why('chip $id is ready again: no hint'),
          );
        }
      } finally {
        await g.done();
        handle.dispose();
      }
    });
  }

  testWidgets('a chip send refused by RATE_LIMITED plays invalidTap once and '
      'rests the chips 3000 ms, with no ring on the card', (tester) async {
    final EndGame g = await openFinished(tester, 'D1 card refused');
    try {
      final int before = g.sentCount;
      await tapReply(g, 'revenge');
      final String request = requestIdOf(
        g.drive.transport.sentRaw
            .skip(before)
            .singleWhere((String t) => frameType(t) == 'emote'),
      );
      final int cues = g.s.count(FeedbackCue.invalidTap);
      g.s.steps.add('error RATE_LIMITED re=$request');
      await pushRaw(
        g.tester,
        g.drive,
        errorReplyFrame(re: request, code: 'RATE_LIMITED'),
      );
      final int refused = g.s.clockMs;
      await g.s.pump(const Duration(milliseconds: 20));
      expect(
        g.s.count(FeedbackCue.invalidTap),
        cues + 1,
        reason: g.why('the card send refused: invalidTap once'),
      );
      for (final String id in kLoserReplies) {
        expect(
          chipAlphaOf(g, id),
          closeTo(0.38, 0.03),
          reason: g.why('chip $id rests after the refusal'),
        );
      }
      expect(
        find.byKey(_ringKey),
        findsNothing,
        reason: g.why('the chips get no ring'),
      );
      await _goTo(g, refused + 2900);
      expect(
        chipAlphaOf(g, 'good_game'),
        closeTo(0.38, 0.03),
        reason: g.why('still resting 2900 ms after the refusal'),
      );
      await _goTo(g, refused + 3100);
      for (final String id in kLoserReplies) {
        expect(
          chipAlphaOf(g, id),
          closeTo(1.0, 0.03),
          reason: g.why('chip $id is live 3100 ms after the refusal'),
        );
      }
    } finally {
      await g.done();
    }
  });
}
