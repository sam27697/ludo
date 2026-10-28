// Screen proof for C-478 D6 items 4, 5, 6 and the bubble half of 8 (order
// 481): the speech bubbles on the board. Written from
// work/ludo/orders/C-478-quick-chat.md alone; the implementation (order
// 480) was being written in another tree and has not been read.
//
// A real GameScreen over a real RoomController on FakeTransport, every
// state a decoded wire frame, fake time from the pump. Time is measured
// from the frame the `emote` push was flushed on. The surface is 360x800 at
// pixel ratio 1, so a logical pixel is a device pixel.
//
// This file does not compile on a tree without lib/src/quick_chat.dart,
// LudoBoard.chatBubbles and the game screen's chat button; that is the
// expected failing arm on the base.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - BoardChatBubble's constructor is not given, so no test builds one;
//     the board is read through LudoBoard.chatBubbles (seat, text, serial)
//     after the screen has filled it.
//   - How the opacity is animated is not given. The measure multiplies
//     every Opacity / FadeTransition above the bubble's Text. A fade done
//     with a colour alpha instead would read as 1.0 and fail the fade case.
//   - The bubble's geometry is read off the rect of the widget keyed
//     `chat-bubble-<seat>` after the 160 ms entrance: the contract says the
//     key is on the bubble's root, tail included.
//   - Reduced motion is read as "full size and full opacity for the whole
//     life, removed at kChatBubbleLife".
//   - Malformed `emote` pushes (a number for the id, a missing seat) are
//     beyond the contract's "unknown id or seat"; they are tested to show
//     nothing and throw nothing.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/net/room_controller.dart' show RoomPhase;
import 'package:ludo_client/src/quick_chat.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const List<(String, String, String)> kLines = <(String, String, String)>[
  ('hi', 'Hi all', 'مرحبا يا جماعة'),
  ('good_luck', 'Good luck', 'بالتوفيق'),
  ('your_move', 'Come on, your move!', 'يلا، دورك!'),
  ('nice', 'Nice move', 'حلوة منك'),
  ('lucky', 'So lucky!', 'شو هالحظ!'),
  ('oops', 'Oops', 'أوبس'),
  ('ha_ha', 'Ha ha ha', 'هههههه'),
  ('revenge', 'I\'ll get you back', 'رح ردّلك ياها'),
  ('coming', 'Run, I\'m coming!', 'اهرب، جايّك!'),
  ('back_home', 'Back home you go', 'عالبيت يا حلو'),
  ('no_way', 'No way!', 'مستحيل!'),
  ('good_game', 'Good game', 'لعبة حلوة'),
];

const Key _chatButton = Key('game-chat-button');
const Key _muteKey = Key('quick-chat-mute');
const Key _sheetKey = Key('quick-chat-sheet');

Key bubbleKey(int seat) => Key('chat-bubble-$seat');

const String _bubblePrefix = 'chat-bubble-';

Finder anyBubble() => find.byWidgetPredicate((Widget w) {
  final Key? key = w.key;
  return key is ValueKey<String> && key.value.startsWith(_bubblePrefix);
});

/// The seats whose `chat-bubble-<seat>` is on screen, ascending.
List<int> bubbleSeats(WidgetTester tester) => <int>[
  for (final Element e in anyBubble().evaluate())
    int.parse(
      (e.widget.key! as ValueKey<String>).value.substring(_bubblePrefix.length),
    ),
]..sort();

String? bubbleText(WidgetTester tester, int seat) {
  final Finder text = find.descendant(
    of: find.byKey(bubbleKey(seat)),
    matching: find.byType(Text),
  );
  if (!tester.any(text)) {
    return null;
  }
  final Text widget = tester.widget<Text>(text.first);
  return widget.data ?? widget.textSpan?.toPlainText();
}

/// Every Opacity / FadeTransition above the bubble's Text, multiplied.
double alphaOf(WidgetTester tester, int seat) {
  final Finder text = find.descendant(
    of: find.byKey(bubbleKey(seat)),
    matching: find.byType(Text),
  );
  double alpha = 1.0;
  tester.element(text.first).visitAncestorElements((Element e) {
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

Rect textRect(WidgetTester tester, int seat) => tester.getRect(
  find
      .descendant(of: find.byKey(bubbleKey(seat)), matching: find.byType(Text))
      .first,
);

class _Fix {
  _Fix(this.s, this.me);

  final Scn s;
  final int me;

  Finder get board => find.byType(LudoBoard);

  List<BoardChatBubble> get onBoard =>
      tester.widget<LudoBoard>(board).chatBubbles;

  WidgetTester get tester => s.tester;

  /// Clock reading of the last emote push, the zero of the bubble's life.
  int zero = 0;

  Future<void> emote(Object? seat, Object? id) async {
    await s.pushEmote(seat, id);
    zero = s.clockMs;
  }

  Future<void> at(int ms) async {
    final int target = zero + ms;
    if (target > s.clockMs) {
      await s.pump(Duration(milliseconds: target - s.clockMs));
    }
  }

  Future<void> done() => releaseGame(tester, s.drive);
}

List<Map<String, Object?>> _seatsFor(int players, int me) =>
    players == 2 ? pairSeats(mySeat: me) : quadSeats(mySeat: me);

Future<_Fix> _fix(
  WidgetTester tester,
  String name, {
  int me = 0,
  int players = 2,
  Locale locale = const Locale('en'),
  bool reduced = false,
  double textScale = 1.0,
  Map<String, Object?>? turn,
  List<Map<String, Object?>>? seats,
}) async {
  phoneSurface(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn ?? awaitRollTurn(me == 0 ? 2 : 0),
    seats: seats ?? _seatsFor(players, me),
    mySeat: me,
    players: players,
  );
  await mountGame(
    tester,
    drive,
    locale: locale,
    textScale: textScale,
    disableAnimations: reduced,
  );
  return _Fix(Scn(name, tester, drive), me);
}

/// Opens the sheet from the header button, flips the mute switch and
/// closes the sheet by its barrier.
Future<void> _toggleMute(_Fix f) async {
  f.s.steps.add('open sheet, flip mute, close');
  await f.tester.tap(find.byKey(_chatButton));
  await f.tester.pump();
  await f.s.pump(const Duration(milliseconds: 400));
  expect(find.byKey(_sheetKey), findsOneWidget, reason: f.s.why('sheet opens'));
  final Finder keyed = find.byKey(_muteKey);
  final Finder sw = f.tester.widget(keyed) is Switch
      ? keyed
      : find.descendant(of: keyed, matching: find.byType(Switch));
  await f.tester.tap(sw);
  await f.tester.pump();
  await f.s.pump(const Duration(milliseconds: 300));
  await f.tester.tapAt(const Offset(180, 20));
  await f.tester.pump();
  await f.s.pump(const Duration(milliseconds: 400));
  expect(find.byKey(_sheetKey), findsNothing, reason: f.s.why('sheet closes'));
}

Future<bool> _muteIsOn(_Fix f) async {
  await f.tester.tap(find.byKey(_chatButton));
  await f.tester.pump();
  await f.s.pump(const Duration(milliseconds: 400));
  final Finder keyed = find.byKey(_muteKey);
  final Finder sw = f.tester.widget(keyed) is Switch
      ? keyed
      : find.descendant(of: keyed, matching: find.byType(Switch));
  final bool on = f.tester.widget<Switch>(sw).value;
  await f.tester.tapAt(const Offset(180, 20));
  await f.tester.pump();
  await f.s.pump(const Duration(milliseconds: 400));
  return on;
}

String _lineOf(String id, {required bool ar}) {
  for (final (String, String, String) row in kLines) {
    if (row.$1 == id) {
      return ar ? row.$3 : row.$2;
    }
  }
  throw ArgumentError(id);
}

/// A copy of one frame of the board's pixels, read at global points.
class _Shot {
  _Shot(this.box, this.image, this.data);

  final RenderBox box;
  final ui.Image image;
  final ByteData data;

  static Future<_Shot> of(WidgetTester tester, Finder key) async {
    RenderObject boundary = tester.renderObject(key);
    while (!boundary.isRepaintBoundary) {
      boundary = boundary.parent!;
    }
    final RenderBox box = boundary as RenderBox;
    final ui.Image? image = await tester.runAsync<ui.Image>(
      () => (box.debugLayer! as OffsetLayer).toImage(box.paintBounds),
    );
    final ByteData? data = await tester.runAsync<ByteData?>(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return _Shot(box, image!, data!);
  }

  Color at(Offset global) {
    final Offset local = box.globalToLocal(global);
    final int x = local.dx.floor();
    final int y = local.dy.floor();
    final int i = (y * image.width + x) * 4;
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

void main() {
  // -------------------------------------------------------------------
  // Item 4: showing, timing, replacing.
  // -------------------------------------------------------------------
  testWidgets('4. an emote from seat 2 shows chat-bubble-2 with the line, '
      'present at 2490 ms, gone at 2510 ms', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 life');
    try {
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('fixture: no bubble yet'),
      );
      await f.emote(2, 'hi');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('only chat-bubble-2, on the frame the emote landed'));
      expect(
        bubbleText(tester, 2),
        'Hi all',
        reason: f.s.why('the D3 line for hi'),
      );
      for (final int ms in const <int>[300, 1000, 2000, 2490]) {
        await f.at(ms);
        expect(bubbleSeats(tester), <int>[
          2,
        ], reason: f.s.why('still up at $ms ms after the emote'));
      }
      await f.at(2510);
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why(
          'gone after 2500 ms (on screen: ${bubbleSeats(tester)})',
        ),
      );
      await f.s.pump(const Duration(milliseconds: 3000));
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('it does not come back'),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('4. a second emote from seat 2 at 1000 ms replaces the first '
      'and restarts its life: up at 3000 ms, gone by 3500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 restart');
    try {
      await f.emote(2, 'hi');
      final int firstSerial = f.onBoard.single.serial;
      await f.at(1000);
      await f.emote(2, 'oops');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('one bubble for seat 2'));
      expect(
        bubbleText(tester, 2),
        'Oops',
        reason: f.s.why('the new line replaced the old'),
      );
      expect(
        f.onBoard,
        hasLength(1),
        reason: f.s.why('one entry on the board per seat'),
      );
      expect(
        f.onBoard.single.serial,
        isNot(firstSerial),
        reason: f.s.why('the replacement is a new bubble (new serial)'),
      );
      expect(f.onBoard.single.seat, 2);
      expect(f.onBoard.single.text, 'Oops');
      // f.zero is now the second push; the first would have died at +1500.
      await f.at(1600);
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('up where the first would be gone (2600 ms overall)'));
      await f.at(2000);
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('up at 3000 ms overall'));
      await f.at(2490);
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('up at 3490 ms overall'));
      await f.at(2510);
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('gone 2500 ms after the second emote'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('4. the replacement is measured from its own push, so the '
      'first one\'s timer cannot take it down', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 stale timer');
    try {
      await f.emote(2, 'hi');
      await f.at(2400);
      await f.emote(2, 'nice');
      final int base = f.zero;
      await f.s.pump(const Duration(milliseconds: 200));
      expect(
        bubbleSeats(tester),
        <int>[2],
        reason: f.s.why(
          '${f.s.clockMs - base} ms after the 2nd, past the first\'s 2500',
        ),
      );
      expect(
        bubbleText(tester, 2),
        'Nice move',
        reason: f.s.why('the second line'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('4. seats 1 and 2 at once both show, each with its own line '
      'and its own life', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 two seats', players: 4);
    try {
      await f.emote(1, 'good_luck');
      await f.s.pump(const Duration(milliseconds: 1000));
      final int t1 = f.zero;
      await f.emote(2, 'ha_ha');
      expect(bubbleSeats(tester), <int>[
        1,
        2,
      ], reason: f.s.why('both chat-bubble-1 and chat-bubble-2 show'));
      expect(
        bubbleText(tester, 1),
        'Good luck',
        reason: f.s.why('seat 1 line'),
      );
      expect(bubbleText(tester, 2), 'Ha ha ha', reason: f.s.why('seat 2 line'));
      expect(
        f.onBoard.map((BoardChatBubble b) => b.seat).toList()..sort(),
        <int>[1, 2],
      );
      expect(
        f.onBoard.map((BoardChatBubble b) => b.serial).toSet(),
        hasLength(2),
        reason: f.s.why('two bubbles, two serials'),
      );
      // Seat 1 dies at t1 + 2500, seat 2 at f.zero + 2500 = t1 + 3500.
      await f.s.pump(Duration(milliseconds: t1 + 2510 - f.s.clockMs));
      expect(
        bubbleSeats(tester),
        <int>[2],
        reason: f.s.why(
          'seat 1\'s bubble expired at its own 2500 ms; seat 2\'s did not',
        ),
      );
      await f.at(2510);
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('seat 2\'s expires too'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('4. all four seats at once show', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 four seats', players: 4);
    try {
      for (int seat = 0; seat < 4; seat++) {
        await f.emote(seat, 'hi');
      }
      expect(bubbleSeats(tester), <int>[
        0,
        1,
        2,
        3,
      ], reason: f.s.why('four bubbles'));
    } finally {
      await f.done();
    }
  });

  for (final bool ar in const <bool>[false, true]) {
    testWidgets(
      '4/8. each of the twelve ids shows its ${ar ? 'Arabic' : 'English'} '
      'line (one replacing the next)',
      (tester) async {
        final _Fix f = await _fix(
          tester,
          'item 4/8 lines ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
        );
        try {
          for (final (String, String, String) row in kLines) {
            await f.emote(2, row.$1);
            final String want = ar ? row.$3 : row.$2;
            expect(
              bubbleText(tester, 2),
              want,
              reason: f.s.why('emote ${row.$1} reads "$want"'),
            );
            expect(
              f.onBoard.single.text,
              want,
              reason: f.s.why('LudoBoard.chatBubbles text'),
            );
            await f.s.pump(const Duration(milliseconds: 100));
          }
        } finally {
          await f.done();
        }
      },
    );
  }

  testWidgets('4. an emote makes no sound and no haptic', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 silent');
    try {
      final int before = f.s.drive.feedback.recorded.length;
      await f.emote(2, 'revenge');
      await f.s.pump(const Duration(milliseconds: 3000));
      expect(
        f.s.drive.feedback.recorded.sublist(before),
        isEmpty,
        reason: f.s.why('no FeedbackCue for an incoming emote'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('4. an emote frame does not disturb the state frames around '
      'it: no resume, and the next turn lands', (tester) async {
    final _Fix f = await _fix(tester, 'item 4 no seq');
    try {
      final int sent = f.s.drive.transport.sentRaw.length;
      await f.emote(2, 'hi');
      await f.s.push('turn', turnFrame(0));
      expect(
        sentTypesSince(f.s.drive.transport, sent),
        isNot(contains('resume')),
        reason: f.s.why('an emote carries no seq and starts no resync'),
      );
      expect(
        f.s.drive.controller.room!.turn!.seat,
        0,
        reason: f.s.why('the turn push after the emote was applied'),
      );
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Item 5: muted.
  // -------------------------------------------------------------------
  testWidgets('5. muted: another seat\'s bubble does not show, mine does', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 5 muted', players: 4);
    try {
      await _toggleMute(f);
      expect(
        await _muteIsOn(f),
        isTrue,
        reason: f.s.why('fixture: muted is on'),
      );
      await f.emote(2, 'hi');
      await f.emote(1, 'nice');
      await f.emote(3, 'lucky');
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('no bubble from seats 1, 2, 3 while muted'),
      );
      await f.emote(0, 'oops');
      expect(bubbleSeats(tester), <int>[
        0,
      ], reason: f.s.why('my own bubble (seat 0) shows while muted'));
      expect(bubbleText(tester, 0), 'Oops');
      await f.s.pump(const Duration(milliseconds: 100));
      expect(f.onBoard.map((BoardChatBubble b) => b.seat), <int>[
        0,
      ], reason: f.s.why('only mine on the board'));
    } finally {
      await f.done();
    }
  });

  testWidgets('5. muted from a seat that is not seat 0: my seat is the one '
      'that stays', (tester) async {
    final _Fix f = await _fix(tester, 'item 5 muted as seat 2', me: 2);
    try {
      await _toggleMute(f);
      await f.emote(0, 'hi');
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('seat 0 hidden, I am 2'),
      );
      await f.emote(2, 'hi');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('mine (seat 2) shows'));
    } finally {
      await f.done();
    }
  });

  testWidgets('5. unmuting brings the next bubble back', (tester) async {
    final _Fix f = await _fix(tester, 'item 5 unmute');
    try {
      await _toggleMute(f);
      await f.emote(2, 'hi');
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('hidden while muted'),
      );
      await _toggleMute(f);
      expect(await _muteIsOn(f), isFalse, reason: f.s.why('fixture: unmuted'));
      await f.emote(2, 'good_game');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('shows after unmuting'));
    } finally {
      await f.done();
    }
  });

  testWidgets('5. the switch keeps its state when the sheet is opened again', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 5 switch memory');
    try {
      expect(await _muteIsOn(f), isFalse, reason: f.s.why('starts off'));
      await _toggleMute(f);
      expect(
        await _muteIsOn(f),
        isTrue,
        reason: f.s.why('the screen remembers it'),
      );
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Item 6: what is not a bubble.
  // -------------------------------------------------------------------
  for (final (String, Object?, Object?) bad
      in const <(String, Object?, Object?)>[
        ('unknown id', 2, 'nope'),
        ('empty id', 2, ''),
        ('upper-case id', 2, 'HI'),
        ('the text instead of the id', 2, 'Hi all'),
        ('a padded id', 2, 'hi '),
        ('unknown seat 1 (no such seat in a two-seat room)', 1, 'hi'),
        ('unknown seat 3', 3, 'hi'),
        ('seat out of range', 7, 'hi'),
        ('negative seat', -1, 'hi'),
        ('id of the wrong type', 2, 5),
        ('null id', 2, null),
        ('seat of the wrong type', '2', 'hi'),
        ('missing seat', null, 'hi'),
      ]) {
    testWidgets('6. ${bad.$1}: no bubble and no exception', (tester) async {
      final _Fix f = await _fix(tester, 'item 6 ${bad.$1}');
      try {
        await f.emote(bad.$2, bad.$3);
        await f.s.pump(const Duration(milliseconds: 300));
        expect(
          bubbleSeats(tester),
          isEmpty,
          reason: f.s.why(
            '${bad.$1} shows nothing (on screen: ${bubbleSeats(tester)})',
          ),
        );
        expect(f.onBoard, isEmpty, reason: f.s.why('and nothing on the board'));
        expect(
          tester.takeException(),
          isNull,
          reason: f.s.why('and throws nothing'),
        );
        await f.emote(2, 'hi');
        expect(bubbleSeats(tester), <int>[
          2,
        ], reason: f.s.why('a good emote afterwards still shows'));
      } finally {
        await f.done();
      }
    });
  }

  testWidgets('6. a bad emote does not remove the good bubble already up', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 6 bad after good');
    try {
      await f.emote(2, 'hi');
      await f.emote(2, 'nope');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('seat 2 keeps its bubble'));
      expect(
        bubbleText(tester, 2),
        'Hi all',
        reason: f.s.why('with the old line'),
      );
      await f.emote(9, 'oops');
      expect(bubbleText(tester, 2), 'Hi all');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Clearing.
  // -------------------------------------------------------------------
  testWidgets('a resync (a seq gap answered by a snapshot) clears every '
      'bubble', (tester) async {
    final _Fix f = await _fix(tester, 'clear on resync', players: 4);
    try {
      await f.emote(1, 'hi');
      await f.emote(2, 'nice');
      expect(bubbleSeats(tester), <int>[
        1,
        2,
      ], reason: f.s.why('fixture: two bubbles'));
      final int sent = f.s.drive.transport.sentRaw.length;
      f.s.drive.lastSeq += 4;
      await f.s.push('turn', turnFrame(3));
      final List<String> types = sentTypesSince(f.s.drive.transport, sent);
      expect(
        types,
        contains('resume'),
        reason: f.s.why('fixture: a gap starts a resync, sent $types'),
      );
      final String id = requestIdOf(
        f.s.drive.transport.sentRaw
            .skip(sent)
            .firstWhere((String t) => frameType(t) == 'resume'),
      );
      await pushRaw(
        tester,
        f.s.drive,
        roomReplyFrame(
          re: id,
          seats: quadSeats(mySeat: 0),
          turn: awaitRollTurn(3),
          seq: f.s.drive.lastSeq + 1,
        ),
      );
      await f.s.pump(const Duration(milliseconds: 50));
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('the resync cleared every bubble'),
      );
      await f.emote(2, 'oops');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('new bubbles still work after'));
    } finally {
      await f.done();
    }
  });

  testWidgets('a resume after a dropped socket clears every bubble', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'clear on resume', players: 4);
    try {
      await f.emote(1, 'hi');
      await f.emote(3, 'nice');
      f.s.steps.add('far side closes');
      f.s.drive.transport.endFromFarSide();
      await tester.pump();
      await f.s.pump(const Duration(milliseconds: 100));
      final FakeTransport next = FakeTransport();
      f.s.drive.enqueueTransport(next);
      final Future<void> reconnect = f.s.drive.controller.reconnect();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final String id = requestIdOf(
        next.sentRaw.lastWhere((String t) => frameType(t) == 'resume'),
      );
      next.pushText(
        roomReplyFrame(
          re: id,
          seats: quadSeats(mySeat: 0),
          turn: awaitRollTurn(1),
          seq: f.s.drive.lastSeq + 1,
        ),
      );
      await reconnect;
      await tester.pump();
      await f.s.pump(const Duration(milliseconds: 100));
      expect(
        f.s.drive.controller.phase,
        RoomPhase.connected,
        reason: f.s.why('fixture: the resume landed'),
      );
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('the resume cleared every bubble'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('the room leaving PLAYING clears every bubble', (tester) async {
    final _Fix f = await _fix(tester, 'clear on game over', players: 4);
    try {
      await f.emote(1, 'hi');
      await f.emote(2, 'nice');
      expect(bubbleSeats(tester), <int>[1, 2], reason: f.s.why('fixture'));
      await f.s.push('game_over', gameOverFrame(2));
      await f.s.pump(const Duration(milliseconds: 100));
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('game_over cleared them'),
      );
      await f.s.pump(const Duration(milliseconds: 3000));
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('and none came back'),
      );
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Place and size.
  // -------------------------------------------------------------------
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final int me in const <int>[0, 2]) {
      testWidgets('place: ${locale.languageCode}, I am seat $me: every '
          'bubble is centred on its viewed yard, tail tip one cell toward '
          'the midline, body clear of the tail side', (tester) async {
        final _Fix f = await _fix(
          tester,
          'place ${locale.languageCode} me=$me',
          me: me,
          players: 4,
          locale: locale,
        );
        try {
          for (int seat = 0; seat < 4; seat++) {
            await f.emote(seat, 'nice');
          }
          await f.s.pump(const Duration(milliseconds: 250));
          final Rect board = boardSquare(tester);
          final double cell = cellSize(tester);
          for (int seat = 0; seat < 4; seat++) {
            final Rect yard = yardQuadrantViewRect(board, seat, me);
            final Rect rect = tester.getRect(find.byKey(bubbleKey(seat)));
            final bool lower = yard.center.dy > board.center.dy;
            final double tipY = lower
                ? yard.center.dy - cell
                : yard.center.dy + cell;
            expect(
              rect.center.dx,
              closeTo(yard.center.dx, 2.0),
              reason: f.s.why(
                'seat $seat: bubble $rect centred on yard ${yard.center.dx}',
              ),
            );
            if (lower) {
              expect(
                rect.bottom,
                closeTo(tipY, 3.0),
                reason: f.s.why(
                  'seat $seat (lower half): the tail tip is ${rect.bottom}, '
                  'wanted $tipY, one cell ($cell) above the yard centre',
                ),
              );
              expect(
                rect.top,
                lessThan(tipY - 10),
                reason: f.s.why('seat $seat body is above its tail'),
              );
            } else {
              expect(
                rect.top,
                closeTo(tipY, 3.0),
                reason: f.s.why(
                  'seat $seat (upper half): the tail tip is ${rect.top}, '
                  'wanted $tipY, one cell ($cell) below the yard centre',
                ),
              );
              expect(
                rect.bottom,
                greaterThan(tipY + 10),
                reason: f.s.why('seat $seat body is below its tail'),
              );
            }
          }
        } finally {
          await f.done();
        }
      });
    }
  }

  for (final bool ar in const <bool>[false, true]) {
    testWidgets('size: ${ar ? 'ar' : 'en'}: every line fits 5 cells wide and '
        'at most two lines, at 1x and 2x text', (tester) async {
      for (final double scale in const <double>[1.0, 2.0]) {
        final _Fix f = await _fix(
          tester,
          'size ${ar ? 'ar' : 'en'} x$scale',
          locale: Locale(ar ? 'ar' : 'en'),
          textScale: scale,
        );
        try {
          final double cell = cellSize(tester);
          for (final (String, String, String) row in kLines) {
            await f.emote(2, row.$1);
            await f.s.pump(const Duration(milliseconds: 250));
            final Rect rect = tester.getRect(find.byKey(bubbleKey(2)));
            expect(
              rect.width,
              lessThanOrEqualTo(5 * cell + 0.5),
              reason: f.s.why(
                '${row.$1}: bubble ${rect.width} wide, 5 cells = ${5 * cell}',
              ),
            );
            final Finder text = find.descendant(
              of: find.byKey(bubbleKey(2)),
              matching: find.byType(Text),
            );
            final Text widget = tester.widget<Text>(text.first);
            expect(
              widget.maxLines,
              2,
              reason: f.s.why('${row.$1}: maxLines 2'),
            );
            expect(
              widget.overflow,
              TextOverflow.ellipsis,
              reason: f.s.why('${row.$1}: ellipsis'),
            );
            final Element element = tester.element(text.first);
            final TextStyle style = DefaultTextStyle.of(element).style
                .merge(widget.style);
            final TextPainter one = TextPainter(
              text: TextSpan(text: 'Hg', style: style),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(element),
            )..layout();
            final double height = tester.getSize(text.first).height;
            expect(
              height,
              lessThanOrEqualTo(2 * one.height + 1.0),
              reason: f.s.why(
                '${row.$1} at x$scale is $height tall, one line is '
                '${one.height}: at most 2 lines',
              ),
            );
            one.dispose();
          }
        } finally {
          await f.done();
        }
      }
    });
  }

  for (final (int seat, String where) in const <(int, String)>[
    (0, 'lower half: tail below the body'),
    (2, 'upper half: tail above the body'),
  ]) {
    testWidgets('look: seat $seat bubble has a 2 dp border in the seat '
        'colour and a paperElevated fill ($where)', (tester) async {
      final _Fix f = await _fix(tester, 'look seat $seat');
      try {
        await f.emote(seat, 'nice');
        await f.at(400);
        final Finder key = find.byKey(bubbleKey(seat));
        final _Shot shot = await _Shot.of(tester, key);
        final Rect text = textRect(tester, seat);
        final Rect root = tester.getRect(key);
        final Color border = LudoColors.seats[seat];
        final bool lower = seat == 0;
        final double edgeX = text.center.dx;
        bool found = false;
        final List<String> seen = <String>[];
        for (int dy = 4; dy <= 12; dy++) {
          final double y = lower ? text.top - dy : text.bottom + dy;
          final Color c = shot.at(Offset(edgeX, y));
          seen.add('$dy:${c.toARGB32().toRadixString(16)}');
          if (_near(c, border, 6)) {
            found = true;
          }
        }
        expect(
          found,
          isTrue,
          reason: f.s.why(
            'a pixel of the bubble edge in seat colour $border near the '
            '${lower ? 'top' : 'bottom'} of $root; read $seen',
          ),
        );
        final Color fill = shot.at(Offset(text.left - 4, text.center.dy));
        expect(
          _near(fill, LudoColors.paperElevated, 6),
          isTrue,
          reason: f.s.why(
            'padding pixel ${fill.toARGB32().toRadixString(16)} is the paperElevated fill',
          ),
        );
        final Text widget = tester.widget<Text>(
          find.descendant(of: key, matching: find.byType(Text)).first,
        );
        final TextStyle style = DefaultTextStyle.of(
          tester.element(
            find.descendant(of: key, matching: find.byType(Text)).first,
          ),
        ).style.merge(widget.style);
        expect(style.fontWeight, FontWeight.w700, reason: f.s.why('w700'));
        expect(style.color, LudoColors.ink, reason: f.s.why('ink'));
        expect(
          style.fontSize,
          Theme.of(tester.element(key)).textTheme.labelLarge!.fontSize,
          reason: f.s.why('labelLarge size'),
        );
      } finally {
        await f.done();
      }
    });
  }

  // -------------------------------------------------------------------
  // Layers and taps.
  // -------------------------------------------------------------------
  Element stackAbove(WidgetTester tester, Key tokenKey) {
    Element? stack;
    tester.element(find.byKey(tokenKey)).visitAncestorElements((Element a) {
      if (a.widget is Stack) {
        stack = a;
        return false;
      }
      return true;
    });
    return stack!;
  }

  testWidgets('layer: above the gloat, below the thrown die', (tester) async {
    final _Fix f = await _fix(
      tester,
      'layer gloat and throw',
      turn: awaitRollTurn(2),
      seats: <Map<String, Object?>>[
        seatJson(0, name: 'Sam', tokens: const <int>[-1, -1, 48, -1]),
        seatJson(2, name: 'Bob', tokens: kYard),
      ],
    );
    try {
      await f.s.push(
        'moved',
        movedFrame(
          2,
          0,
          3,
          9,
          captured: <Map<String, int>>[
            <String, int>{'seat': 0, 'token': 2},
          ],
        ),
      );
      await f.s.pump(const Duration(milliseconds: 48));
      expect(gloatSeats(tester), <int>[
        2,
      ], reason: f.s.why('fixture: the gloat is up'));
      await f.emote(2, 'ha_ha');
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('fixture: the bubble is up'));
      final Element stack = stackAbove(tester, const Key('token-2-0'));
      expect(
        stackSlot(tester, stack, find.byKey(bubbleKey(2))),
        greaterThan(stackSlot(tester, stack, find.byKey(gloatKey(2)))),
        reason: f.s.why('the bubble paints over the gloat'),
      );
      await f.s.push('turn', turnFrame(2));
      await f.s.push(
        'rolled',
        rolledFrame(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      expect(
        find.byKey(opponentThrowKey(2)),
        findsOneWidget,
        reason: f.s.why('fixture: the thrown die is up'),
      );
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('fixture: the bubble is still up'));
      expect(
        stackSlot(tester, stack, find.byKey(bubbleKey(2))),
        lessThan(stackSlot(tester, stack, find.byKey(opponentThrowKey(2)))),
        reason: f.s.why('the thrown die paints over the bubble'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('layer: below the face picker', (tester) async {
    final _Fix f = await _fix(
      tester,
      'layer face picker',
      players: 2,
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 2,
        value: 6,
        legal: const <int>[0, 2],
        queue: const <int>[6, 4],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 2]),
          faceLegal(4, const <int>[1, 2]),
        ],
      ),
      seats: twoSeats(mine: const <int>[1, 3, 6, -1]),
    );
    try {
      await f.emote(1, 'nice');
      await f.tester.tap(find.byKey(tokenHitKey(0, 2)), warnIfMissed: false);
      for (int i = 0; i < 14; i++) {
        await f.s.pump(const Duration(milliseconds: 16));
      }
      expect(
        find.byKey(facePickerKey),
        findsOneWidget,
        reason: f.s.why('fixture: the picker is open'),
      );
      expect(bubbleSeats(tester), <int>[
        1,
      ], reason: f.s.why('fixture: the bubble is up'));
      final Element stack = stackAbove(tester, const Key('token-1-0'));
      expect(
        stackSlot(tester, stack, find.byKey(bubbleKey(1))),
        lessThan(stackSlot(tester, stack, find.byKey(facePickerKey))),
        reason: f.s.why('the face picker paints over the bubble'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('layer: below the safe cue', (tester) async {
    final _Fix f = await _fix(
      tester,
      'layer safe cue',
      players: 2,
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 1,
        value: 4,
        legal: const <int>[0, 1],
        queue: const <int>[4],
        legalByFace: <Map<String, Object?>>[
          faceLegal(4, const <int>[0, 1]),
        ],
      ),
      seats: twoSeats(
        mine: const <int>[17, 30, -1, -1],
        other: const <int>[8, -1, -1, -1],
      ),
    );
    try {
      await f.s.push('moved', <String, Object?>{
        ...movedFrame(0, 0, 17, 21),
        'face': 4,
      });
      await f.s.push('turn', turnFrame(1));
      await f.s.pump(kTokenStepDuration * 4 + const Duration(milliseconds: 48));
      const Key star = Key('board-safe-cue-star');
      expect(
        find.byKey(star),
        findsOneWidget,
        reason: f.s.why('fixture: the safe cue is up'),
      );
      await f.emote(1, 'nice');
      expect(bubbleSeats(tester), <int>[
        1,
      ], reason: f.s.why('fixture: the bubble is up'));
      final Element stack = stackAbove(tester, const Key('token-1-0'));
      expect(
        stackSlot(tester, stack, find.byKey(bubbleKey(1))),
        lessThan(stackSlot(tester, stack, find.byKey(star))),
        reason: f.s.why('the safe cue paints over the bubble'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('taps pass through a bubble to the legal token under it', (
    tester,
  ) async {
    final _Fix f = await _fix(
      tester,
      'tap through',
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: 1,
        value: 6,
        legal: const <int>[0, 1, 2, 3],
        queue: const <int>[6],
        legalByFace: <Map<String, Object?>>[
          faceLegal(6, const <int>[0, 1, 2, 3]),
        ],
      ),
    );
    try {
      await f.emote(0, 'hi');
      await f.at(300);
      final Rect bubble = tester.getRect(find.byKey(bubbleKey(0)));
      int? token;
      Offset? point;
      for (int t = 0; t < 4; t++) {
        final Rect hit = tester.getRect(find.byKey(tokenHitKey(0, t)));
        final Rect overlap = hit.intersect(bubble);
        if (overlap.width > 2 && overlap.height > 2) {
          token = t;
          point = overlap.center;
          break;
        }
      }
      expect(
        token,
        isNotNull,
        reason: f.s.why(
          'fixture: some token hit area overlaps the bubble $bubble over my yard',
        ),
      );
      final int sent = f.s.drive.transport.sentRaw.length;
      await tester.tapAt(point!);
      await tester.pump();
      f.s.steps.add('tap token-0-$token at $point');
      final List<Map<String, Object?>> moves = movesSince(
        f.s.drive.transport,
        sent,
      );
      expect(
        moves,
        hasLength(1),
        reason: f.s.why('the tap went through the bubble'),
      );
      expect(
        moves.single['token'],
        token,
        reason: f.s.why('and named token $token'),
      );
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Motion.
  // -------------------------------------------------------------------
  testWidgets('motion: scale 0.6 to 1.0 in 160 ms, full opacity to 2250 ms, '
      'fades out over the last 250 ms, gone at 2500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'motion');
    try {
      await f.emote(2, 'good_game');
      final List<({int t, double scale, double alpha})> trace =
          <({int t, double scale, double alpha})>[];
      // Sample a settled copy first to know the full width, then restart
      // the run so the timing below is from a fresh bubble.
      await f.at(400);
      final double base = textRect(tester, 2).width;
      await f.s.pump(const Duration(milliseconds: 3000));
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('fixture: the first run ended'),
      );
      await f.emote(2, 'good_game');
      while (f.s.clockMs - f.zero <= 2495 && bubbleSeats(tester).isNotEmpty) {
        trace.add((
          t: f.s.clockMs - f.zero,
          scale: textRect(tester, 2).width / base,
          alpha: alphaOf(tester, 2),
        ));
        await f.s.pump(kC468Fine, step: kC468Fine);
      }
      final String sum =
          'first ${trace.first}, last ${trace.last}, ${trace.length} samples';
      expect(trace.first.t, 0, reason: f.s.why('sampled from the first frame'));
      expect(
        trace.first.scale,
        inInclusiveRange(0.55, 0.68),
        reason: f.s.why('starts at scale 0.6; $sum'),
      );
      expect(
        trace.firstWhere((e) => e.t >= 80).scale,
        greaterThan(trace.first.scale + 0.15),
        reason: f.s.why('grows through the entrance; $sum'),
      );
      for (final e in trace.where((e) => e.t <= 160)) {
        expect(
          e.scale,
          inInclusiveRange(0.55, 1.12),
          reason: f.s.why('entrance stays sane; sample $e'),
        );
      }
      for (final e in trace.where((e) => e.t >= 175 && e.t <= 2490)) {
        expect(
          e.scale,
          closeTo(1.0, 0.02),
          reason: f.s.why('full size after 160 ms; sample $e'),
        );
      }
      for (final e in trace.where((e) => e.t <= 2240)) {
        expect(
          e.alpha,
          closeTo(1.0, 0.01),
          reason: f.s.why('full opacity before the fade; sample $e'),
        );
      }
      double previous = 1.0;
      for (final e in trace.where((e) => e.t >= 2250)) {
        expect(
          e.alpha,
          lessThanOrEqualTo(previous + 0.01),
          reason: f.s.why('the fade never brightens; sample $e'),
        );
        previous = e.alpha;
      }
      final mid = trace.firstWhere((e) => e.t >= 2375);
      expect(
        mid.alpha,
        inInclusiveRange(0.15, 0.85),
        reason: f.s.why(
          'half way through the fade it is half gone; sample $mid',
        ),
      );
      expect(
        trace.last.alpha,
        lessThan(0.15),
        reason: f.s.why('nearly gone at the end of the fade; $sum'),
      );
      await f.at(2510);
      expect(bubbleSeats(tester), isEmpty, reason: f.s.why('gone at 2500 ms'));
    } finally {
      await f.done();
    }
  });

  testWidgets('motion: reduced, the bubble is at full size and opacity from '
      'the first frame to the end and is removed at 2500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'motion reduced', reduced: true);
    try {
      await f.emote(2, 'good_game');
      final double first = textRect(tester, 2).width;
      await f.at(400);
      final double settled = textRect(tester, 2).width;
      expect(
        first,
        closeTo(settled, 0.5),
        reason: f.s.why('first frame is already full size: $first vs $settled'),
      );
      await f.s.pump(const Duration(milliseconds: 3000));
      await f.emote(2, 'good_game');
      expect(
        textRect(tester, 2).width,
        closeTo(settled, 0.5),
        reason: f.s.why('full size on the first frame'),
      );
      // Pump to exactly 2490 ms (never past it): the bubble is removed at
      // 2500 ms, so the presence check below needs an elapsed time under it.
      while (f.s.clockMs - f.zero < 2490) {
        expect(
          textRect(tester, 2).width,
          closeTo(settled, 0.5),
          reason: f.s.why('no scale at ${f.s.clockMs - f.zero} ms'),
        );
        expect(
          alphaOf(tester, 2),
          closeTo(1.0, 0.01),
          reason: f.s.why('full opacity at ${f.s.clockMs - f.zero} ms'),
        );
        final int left = 2490 - (f.s.clockMs - f.zero);
        await f.s.pump(Duration(milliseconds: left < 100 ? left : 100));
      }
      expect(bubbleSeats(tester), <int>[
        2,
      ], reason: f.s.why('present at 2490 ms'));
      await f.at(2510);
      expect(
        bubbleSeats(tester),
        isEmpty,
        reason: f.s.why('removed at 2500 ms'),
      );
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Semantics.
  // -------------------------------------------------------------------
  for (final bool ar in const <bool>[false, true]) {
    testWidgets('semantics: ${ar ? 'ar' : 'en'}: the bubble is a live region '
        'labelled "name: line"', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _Fix f = await _fix(
        tester,
        'semantics ${ar ? 'ar' : 'en'}',
        players: 4,
        locale: Locale(ar ? 'ar' : 'en'),
      );
      try {
        await f.emote(2, 'revenge');
        await f.at(400);
        final SemanticsNode node = tester.getSemantics(
          find.byKey(bubbleKey(2)),
        );
        expect(
          node.label,
          'Cara: ${_lineOf('revenge', ar: ar)}',
          reason: f.s.why('label is chatSaid(name, line)'),
        );
        expect(
          node.flagsCollection.isLiveRegion,
          isTrue,
          reason: f.s.why('the bubble is a live region'),
        );
      } finally {
        handle.dispose();
        await f.done();
      }
    });
  }
}
