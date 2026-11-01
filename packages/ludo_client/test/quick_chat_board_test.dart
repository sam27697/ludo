// Screen proof for C-500 (order 502): a quick message received on the board
// screen is drawn in the header band, one line at a time, and the speaker's
// name chip pops. Rewrites the C-478 D6 board bubble file against C-500
// decisions 1 to 8 (C-492 stands for everything C-500 does not change).
// Written from those contracts alone; the implementation (order 501) was
// being written in another tree and has not been read.
//
// A real GameScreen over a real RoomController on FakeTransport, every state
// a decoded wire frame, fake time from the pump. Time is measured from the
// frame the `emote` push was flushed on. The surface is 360x800 at pixel
// ratio 1 unless a case names another size, so a logical pixel is a device
// pixel. The app fonts are loaded for the whole file (as
// end_card_large_text_test.dart does), so every width below is a real one.
//
// The header layer is `end-card-chat-lines` and the one bubble in it
// `end-card-chat-<seat>` on every body (C-500 D7). The header row is the
// widest 48 dp-tall ancestor of game-screen-appbar-leave.
//
// This file does not compile on a tree without LudoBoard.chatPop and
// BoardChatPop (C-500 D6); that is the expected failing arm on the base.
// Where a case needs nothing of the new API it fails on the base only
// because the bubble is still drawn on the board.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - C-500 names the board `Board`; the class in board.dart is LudoBoard,
//     and that is what these cases read `chatPop` from and construct.
//   - The key `board-chip-pop-<seat>` is read as being on the Transform
//     itself ("wrapped in a Transform.scale keyed"), present for every seat
//     in play at scale 1.0 when not popping, and also under
//     `disableAnimations` (where only the scale stays at 1.0).
//   - "Exactly 1.0 by 300 ms" is read to 1e-6: a tween that ends on a
//     rounding of 1.15 + (1.0 - 1.15) is exactly 1.0 to the eye and to
//     the pixel.
//   - In ar the inset on the start side (60 dp, the leave button) is on
//     the right and the 112 dp end side (chat and sound) on the left.
//   - The decision 5 fit rule is checked from the real text, with the
//     bubble's chrome (2 dp border, 8 dp padding) read as 20 dp and a band
//     either side of the boundary where no verdict is asserted: below the
//     band the name must be there, above it the name must be gone.
//   - A spectator seeing lines, and the inset on a header row with no chat
//     button on the PLAYING body, are not asserted: C-500 D2 and D4 do not
//     name a spectator.
//   - Two `emote` frames flushed in one pump: the later frame is the newer.
//   - The held end is reached by a winning move still walking when
//     `game_over` lands (C-270).

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/net/room_controller.dart' show RoomPhase;
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

const int _lifeMs = 2500;

const Key _chatButton = Key('game-chat-button');
const Key _muteKey = Key('quick-chat-mute');
const Key _sheetKey = Key('quick-chat-sheet');
const Key _layerKey = Key('end-card-chat-lines');
const Key _leaveKey = Key('game-screen-appbar-leave');
const Key _soundKey = Key('game-sound-toggle');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _winnerKey = Key('game-screen-winner');

Key lineKey(int seat) => Key('end-card-chat-$seat');

Key chipPopKey(int seat) => Key('board-chip-pop-$seat');

Key nameChipKey(int seat) => Key('board-seat-name-$seat');

const String _linePrefix = 'end-card-chat-';

/// The keys C-500 D6 removes from the board.
const List<String> _boardChatKeys = <String>[
  'board-chat-layer',
  'board-chat-slot-',
  'chat-bubble-',
];

/// C-492 D6: `kSpace2 + 48 + kSpace1`; C-500 D4 adds `48 + kSpace1` on the
/// end side while the row carries the chat button.
const double _rowDp = 48;
const double _inset = kSpace2 + _rowDp + kSpace1;
const double _insetWithChat = _inset + _rowDp + kSpace1;

/// The bubble's own chrome: a 2 dp border and 8 dp of padding a side.
const double _chrome = 2 * (2 + 8);

Finder anyLine() => find.byWidgetPredicate((Widget w) {
  final Key? key = w.key;
  return key is ValueKey<String> &&
      key.value.startsWith(_linePrefix) &&
      int.tryParse(key.value.substring(_linePrefix.length)) != null;
});

/// The seats whose `end-card-chat-<seat>` is on screen, ascending. The layer
/// `end-card-chat-lines` shares the prefix and is not a line.
List<int> lineSeats(WidgetTester tester) => <int>[
  for (final Element e in anyLine().evaluate())
    int.parse(
      (e.widget.key! as ValueKey<String>).value.substring(_linePrefix.length),
    ),
]..sort();

/// Every key still on screen that C-500 D6 removed from the board.
List<String> boardChatKeysOnScreen(WidgetTester tester) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        _boardChatKeys.any((String p) => key.value.startsWith(p));
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value,
];

/// All the text painted under [root], joined with nothing between spans.
String textUnder(WidgetTester tester, Finder root) {
  final Finder rich = find.descendant(
    of: root,
    matching: find.byType(RichText),
  );
  return <String>[
    for (final Element e in rich.evaluate())
      (e.widget as RichText).text.toPlainText(),
  ].join();
}

/// Every Opacity / FadeTransition above the first text under [root],
/// multiplied.
double alphaUnder(WidgetTester tester, Finder root) {
  final Finder rich = find.descendant(
    of: root,
    matching: find.byType(RichText),
  );
  double alpha = 1.0;
  tester.element(rich.first).visitAncestorElements((Element e) {
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

/// Width of the first text under [root] after every transform above it: the
/// scale of a pop-in shows up here.
double textWidthUnder(WidgetTester tester, Finder root) => tester
    .getRect(find.descendant(of: root, matching: find.byType(RichText)).first)
    .width;

/// (text, resolved style) for the leaves of [span].
List<(String, TextStyle)> spanLeaves(InlineSpan span, [TextStyle? parent]) {
  if (span is! TextSpan) {
    return const <(String, TextStyle)>[];
  }
  final TextStyle style = (parent ?? const TextStyle()).merge(span.style);
  return <(String, TextStyle)>[
    if (span.text != null) (span.text!, style),
    for (final InlineSpan child in span.children ?? const <InlineSpan>[])
      ...spanLeaves(child, style),
  ];
}

Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();
  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

class _Fix {
  _Fix(this.s, this.me, this.ar);

  final Scn s;
  final int me;
  final bool ar;

  WidgetTester get tester => s.tester;

  /// Clock reading of the last emote push, the zero of the line's life.
  int zero = 0;

  Future<void> emote(Object? seat, Object? id, {String? re}) async {
    await s.pushEmote(seat, id, re: re);
    zero = s.clockMs;
  }

  Future<void> at(int ms) async {
    final int target = zero + ms;
    if (target > s.clockMs) {
      await s.pump(Duration(milliseconds: target - s.clockMs));
    }
  }

  List<int> get seats => lineSeats(tester);

  void requireLine(int seat) {
    expect(
      find.byKey(lineKey(seat)),
      findsOneWidget,
      reason: s.why('end-card-chat-$seat is on screen (on screen: $seats)'),
    );
  }

  String textOf(int seat) {
    requireLine(seat);
    return textUnder(tester, find.byKey(lineKey(seat)));
  }

  Rect rectOf(int seat) {
    requireLine(seat);
    return tester.getRect(find.byKey(lineKey(seat)));
  }

  /// The seat of `LudoBoard.chatPop`, null when none is passed.
  int? get popSeat =>
      tester.widget<LudoBoard>(find.byType(LudoBoard)).chatPop?.seat;

  /// The serial of `LudoBoard.chatPop`, null when none is passed.
  int? get popSerial =>
      tester.widget<LudoBoard>(find.byType(LudoBoard)).chatPop?.serial;

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
  Size size = const Size(360, 800),
  Map<String, Object?>? turn,
  List<Map<String, Object?>>? seats,
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = size;
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
  return _Fix(Scn(name, tester, drive), me, locale.languageCode == 'ar');
}

/// My turn with a 6 and all four yard tokens ringed (C-500 "Tests").
Map<String, Object?> _sixTurn() => turnJson(
  seat: 0,
  phase: 'await_move',
  k: 1,
  value: 6,
  legal: const <int>[0, 1, 2, 3],
  queue: const <int>[6],
  legalByFace: <Map<String, Object?>>[
    faceLegal(6, const <int>[0, 1, 2, 3]),
  ],
);

String _lineOf(String id, {required bool ar}) {
  for (final (String, String, String) row in kLines) {
    if (row.$1 == id) {
      return ar ? row.$3 : row.$2;
    }
  }
  throw ArgumentError(id);
}

/// One line is up, from [seat], carrying [line]; the layer holds only it.
void _expectOnly(_Fix f, int seat, String line, String what) {
  expect(
    f.seats,
    <int>[seat],
    reason: f.s.why('$what: only end-card-chat-$seat (on screen: ${f.seats})'),
  );
  expect(
    f.textOf(seat),
    contains(line),
    reason: f.s.why(
      '$what: end-card-chat-$seat says "$line", reads '
      '"${f.textOf(seat)}"',
    ),
  );
  expect(
    find.byKey(_layerKey),
    findsOneWidget,
    reason: f.s.why('$what: the line sits in end-card-chat-lines'),
  );
}

void _expectNone(_Fix f, String what) {
  expect(
    f.seats,
    isEmpty,
    reason: f.s.why('$what: no end-card-chat-<seat> (on screen: ${f.seats})'),
  );
}

void _expectNoBoardChatKeys(_Fix f, String what) {
  expect(
    boardChatKeysOnScreen(f.tester),
    isEmpty,
    reason: f.s.why(
      '$what: no board-chat-layer, board-chat-slot-* or chat-bubble-* '
      '(on screen: ${boardChatKeysOnScreen(f.tester)})',
    ),
  );
}

/// Opens the sheet from the header button, flips the mute switch and closes
/// the sheet by its barrier.
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

// ---------------------------------------------------------------------
// Geometry.
// ---------------------------------------------------------------------

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

/// C-500 D4: the span the bubble is centred in, between the start inset (the
/// leave button side) and the end inset (the chat button as well, while the
/// row carries it). In ar the start side is the right.
Rect _span(WidgetTester tester, Rect row, {required bool ar}) {
  final bool chat = tester.any(find.byKey(_chatButton));
  final double start = _inset;
  final double end = chat ? _insetWithChat : _inset;
  final double left = ar ? end : start;
  final double right = ar ? start : end;
  return Rect.fromLTRB(row.left + left, row.top, row.right - right, row.bottom);
}

/// C-492 D6 vertical rule: centred in the row when it fits, top-aligned
/// when taller.
void _expectTop(_Fix f, Rect bubble, Rect row) {
  final double expectedTop =
      row.top + math.max(0, (_rowDp - bubble.height) / 2);
  expect(
    bubble.top,
    closeTo(expectedTop, 0.5),
    reason: f.s.why(
      'the bubble top follows the row: bubble $bubble, row $row, wanted '
      'top $expectedTop',
    ),
  );
}

/// One line tall, stated so that it separates one line from two. The Arabic
/// presets differ by about 1 dp in one-line height (the reference "oops" is
/// 53.0 dp, "good_luck" 52.0 dp) while a second line adds about 40 dp: so
/// the bubble is under 1.5 lines and within 3 dp of the reference line.
void _expectOneLineTall(_Fix f, String id, Rect bubble, double oneLine) {
  expect(
    bubble.height,
    lessThan(oneLine * 1.5),
    reason: f.s.why(
      '$id: one line tall, under 1.5 lines: the reference one line is '
      '$oneLine dp, two lines would be about ${oneLine + 40} dp, this '
      'bubble is ${bubble.height} dp ($bubble)',
    ),
  );
  expect(
    bubble.height,
    closeTo(oneLine, 3),
    reason: f.s.why(
      '$id: one line tall, within 3 dp of the reference line: one line '
      'is $oneLine dp (presets differ by about 1 dp), this bubble is '
      '${bubble.height} dp ($bubble)',
    ),
  );
}

void _expectInSpan(_Fix f, Rect bubble, Rect span, double maxWidth) {
  expect(
    bubble.left,
    greaterThanOrEqualTo(span.left - 0.5),
    reason: f.s.why('bubble $bubble inside the span $span on the left'),
  );
  expect(
    bubble.right,
    lessThanOrEqualTo(span.right + 0.5),
    reason: f.s.why('bubble $bubble inside the span $span on the right'),
  );
  expect(
    bubble.width,
    lessThanOrEqualTo(maxWidth + 0.5),
    reason: f.s.why('bubble ${bubble.width} dp wide, max $maxWidth dp'),
  );
}

void _expectClearOf(_Fix f, Rect bubble, Key key) {
  expect(find.byKey(key), findsOneWidget, reason: f.s.why('$key is on screen'));
  final Rect other = f.tester.getRect(find.byKey(key));
  expect(
    bubble.overlaps(other),
    isFalse,
    reason: f.s.why('bubble $bubble does not meet $key $other'),
  );
}

/// (key, rect) of every widget whose string key matches [re].
List<(String, Rect)> _rectsMatching(WidgetTester tester, RegExp re) =>
    <(String, Rect)>[
      for (final Element e in find.byWidgetPredicate((Widget w) {
        final Key? key = w.key;
        return key is ValueKey<String> && re.hasMatch(key.value);
      }).evaluate())
        (
          (e.widget.key! as ValueKey<String>).value,
          tester.getRect(find.byKey(e.widget.key!)),
        ),
    ];

void _expectClearOfAll(
  _Fix f,
  Rect bubble,
  List<(String, Rect)> things,
  String what,
) {
  expect(
    things,
    isNotEmpty,
    reason: f.s.why('fixture: $what are on screen to be covered'),
  );
  for (final (String, Rect) thing in things) {
    expect(
      bubble.overlaps(thing.$2),
      isFalse,
      reason: f.s.why('bubble $bubble covers $what ${thing.$1} ${thing.$2}'),
    );
  }
}

/// The pixels of the whole screen, read at logical points (the surface is
/// ratio 1): the top-most repaint boundary above [anchor].
class _Pixels {
  _Pixels(this.image, this.data, this.origin);

  final ui.Image image;
  final ByteData data;
  final Offset origin;

  static Future<_Pixels> of(WidgetTester tester, Finder anchor) async {
    RenderRepaintBoundary? top;
    RenderObject? walker = tester.renderObject(anchor);
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

/// Width of [text] set in [style] on one line at [scaler].
double _width(String text, TextStyle style, TextScaler scaler) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}

/// The resolved style of the span that carries [needle] under [root].
TextStyle _styleOf(WidgetTester tester, Finder root, String needle) {
  final RichText rich = tester.widget<RichText>(
    find.descendant(of: root, matching: find.byType(RichText)).first,
  );
  final List<(String, TextStyle)> leaves = spanLeaves(rich.text);
  final int at = leaves.indexWhere(
    ((String, TextStyle) l) => l.$1.contains(needle),
  );
  expect(at, isNonNegative, reason: 'a span carries "$needle": $leaves');
  return leaves[at].$2;
}

// ---------------------------------------------------------------------
// The chip pop.
// ---------------------------------------------------------------------

/// The scale of `board-chip-pop-<seat>`, read off the Transform itself.
double _scaleOf(WidgetTester tester, int seat, String why) {
  final Finder pop = find.byKey(chipPopKey(seat));
  expect(
    pop,
    findsOneWidget,
    reason:
        '$why | expected: board-chip-pop-$seat is on screen at scale 1.0 '
        'when not popping',
  );
  final Widget widget = tester.widget(pop);
  expect(
    widget,
    isA<Transform>(),
    reason:
        '$why | expected: board-chip-pop-$seat is a Transform, got '
        '${widget.runtimeType}',
  );
  final Matrix4 m = (widget as Transform).transform;
  expect(
    m.storage[5],
    closeTo(m.storage[0], 1e-9),
    reason:
        '$why | expected: a uniform scale, got x ${m.storage[0]} y '
        '${m.storage[5]}',
  );
  return m.storage[0];
}

/// The painted rect of the subtree under [root] in global coordinates, after
/// every transform on the way: the union of each render box's bounds.
Rect _paintedRect(WidgetTester tester, Finder root) {
  Rect? painted;
  void visit(RenderObject object) {
    if (object is RenderBox && object.hasSize) {
      final Rect box = MatrixUtils.transformRect(
        object.getTransformTo(null),
        Offset.zero & object.size,
      );
      painted = painted == null ? box : painted!.expandToInclude(box);
    }
    object.visitChildren(visit);
  }

  visit(tester.renderObject(root));
  return painted!;
}

typedef _PopSample = ({int t, double scale});

/// Samples seat [seat]'s chip every 5 ms from the last emote's first frame
/// to [to] ms.
Future<List<_PopSample>> _popTrace(_Fix f, int seat, {int to = 320}) async {
  final List<_PopSample> trace = <_PopSample>[];
  while (f.s.clockMs - f.zero <= to) {
    trace.add((
      t: f.s.clockMs - f.zero,
      scale: _scaleOf(f.tester, seat, f.s.why('chip $seat pop trace')),
    ));
    await f.s.pump(kC468Fine, step: kC468Fine);
  }
  return trace;
}

void _expectPop(_Fix f, List<_PopSample> trace, int seat) {
  final String sum =
      'chip $seat: first ${trace.first}, ${trace.length} samples';
  expect(trace.first.t, 0, reason: f.s.why('sampled from the first frame'));
  expect(
    trace.first.scale,
    closeTo(1.0, 0.02),
    reason: f.s.why('the pop starts at 1.0; $sum'),
  );
  final _PopSample at120 = trace.firstWhere((_PopSample e) => e.t >= 120);
  expect(
    at120.scale,
    greaterThan(1.1),
    reason: f.s.why('above 1.1 at 120 ms; sample $at120, $sum'),
  );
  for (final _PopSample e in trace) {
    expect(
      e.scale,
      inInclusiveRange(1.0 - 1e-6, 1.15 + 1e-3),
      reason: f.s.why('the pop stays between 1.0 and 1.15; sample $e'),
    );
  }
  for (final _PopSample e in trace.where((_PopSample e) => e.t >= 300)) {
    expect(
      e.scale,
      closeTo(1.0, 1e-6),
      reason: f.s.why('exactly 1.0 by 300 ms; sample $e'),
    );
  }
}

Widget _directBoard({
  required BoardChatPop? pop,
  List<int> seats = const <int>[0, 1, 2, 3],
  bool reduced = false,
}) {
  final Widget board = LudoBoard(
    tokens: <int, List<int>>{
      for (final int seat in seats) seat: const <int>[-1, -1, -1, -1],
    },
    seatsInPlay: seats,
    mySeat: 0,
    seatNames: <int, String>{for (final int seat in seats) seat: 'P$seat'},
    chatPop: pop,
  );
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 400,
          child: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: board,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(_loadAppFonts);

  // -------------------------------------------------------------------
  // Showing, timing, replacing (C-500 D1, kept in intent from C-478 D6
  // item 4, now one line in the header layer).
  // -------------------------------------------------------------------
  testWidgets('1. an emote from seat 2 shows end-card-chat-2 with the line, '
      'present at 2490 ms, gone at 2510 ms', (tester) async {
    final _Fix f = await _fix(tester, 'item 1 life');
    try {
      _expectNone(f, 'fixture, before any emote');
      await f.emote(2, 'hi');
      _expectOnly(f, 2, 'Hi all', 'on the frame the emote landed');
      for (final int ms in const <int>[300, 1000, 2000, 2490]) {
        await f.at(ms);
        _expectOnly(f, 2, 'Hi all', 'still up at $ms ms after the emote');
      }
      await f.at(2510);
      _expectNone(f, 'gone after $_lifeMs ms');
      await f.s.pump(const Duration(milliseconds: 3000));
      _expectNone(f, 'it does not come back');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('1. a second emote from seat 2 at 1000 ms replaces the first '
      'and restarts its life: up at 3000 ms, gone by 3500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'item 1 restart');
    try {
      await f.emote(2, 'hi');
      await f.at(1000);
      await f.emote(2, 'oops');
      _expectOnly(f, 2, 'Oops', 'the new line replaced the old');
      expect(
        f.textOf(2),
        isNot(contains('Hi all')),
        reason: f.s.why('the old text is gone'),
      );
      // f.zero is now the second push; the first would have died at +1500.
      await f.at(1600);
      _expectOnly(f, 2, 'Oops', 'up where the first would be gone');
      await f.at(2490);
      _expectOnly(f, 2, 'Oops', 'up at 3490 ms overall');
      await f.at(2510);
      _expectNone(f, 'gone $_lifeMs ms after the second emote');
    } finally {
      await f.done();
    }
  });

  testWidgets('1. the replacement is measured from its own push, so the '
      'first one\'s timer cannot take it down', (tester) async {
    final _Fix f = await _fix(tester, 'item 1 stale timer');
    try {
      await f.emote(2, 'hi');
      await f.at(2400);
      await f.emote(2, 'nice');
      await f.s.pump(const Duration(milliseconds: 200));
      _expectOnly(f, 2, 'Nice move', 'past the first line\'s 2500 ms');
    } finally {
      await f.done();
    }
  });

  testWidgets('1. seats 1 and 2 one second apart: the newest replaces, one '
      'line, and the first one\'s timer cannot take the second down', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 1 two seats', players: 4);
    try {
      await f.emote(1, 'good_luck');
      _expectOnly(f, 1, 'Good luck', 'seat 1 speaks first');
      await f.s.pump(const Duration(milliseconds: 1000));
      final int first = f.zero;
      await f.emote(2, 'ha_ha');
      _expectOnly(f, 2, 'Ha ha ha', 'seat 2 replaces seat 1');
      expect(
        f.seats,
        isNot(contains(1)),
        reason: f.s.why('seat 1\'s line is gone, not stacked'),
      );
      // Seat 1's own life would end at first + 2500.
      await f.s.pump(Duration(milliseconds: first + 2510 - f.s.clockMs));
      _expectOnly(f, 2, 'Ha ha ha', 'past the first line\'s own 2500 ms');
      await f.at(2490);
      _expectOnly(f, 2, 'Ha ha ha', 'up at 2490 ms after its own push');
      await f.at(2510);
      _expectNone(f, 'gone 2500 ms after its own push');
    } finally {
      await f.done();
    }
  });

  testWidgets('1. four seats in one burst: only the last one pushed is up, '
      'whichever seat number it carries', (tester) async {
    final _Fix f = await _fix(tester, 'item 1 four seats', players: 4);
    try {
      for (final int seat in const <int>[2, 0, 3, 1]) {
        await f.emote(seat, 'hi');
      }
      _expectOnly(f, 1, 'Hi all', 'the newest of 2, 0, 3, 1 is seat 1');
      await f.at(2490);
      _expectOnly(f, 1, 'Hi all', 'and it lives its own 2500 ms');
      await f.at(2510);
      _expectNone(f, 'and then nothing is left behind');
    } finally {
      await f.done();
    }
  });

  testWidgets('1. the same frame replayed is a new line: one bubble, nothing '
      'thrown, and its life runs from the replay', (tester) async {
    final _Fix f = await _fix(tester, 'item 1 replay');
    try {
      await f.emote(2, 'oops');
      await f.at(1500);
      await f.emote(2, 'oops');
      _expectOnly(f, 2, 'Oops', 'after the replay');
      await f.at(2490);
      _expectOnly(f, 2, 'Oops', 'up 2490 ms after the replay');
      await f.at(2510);
      _expectNone(f, 'gone 2500 ms after the replay');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  for (final bool ar in const <bool>[false, true]) {
    testWidgets(
      '1/8. each of the twelve ids shows its ${ar ? 'Arabic' : 'English'} '
      'line (one replacing the next)',
      (tester) async {
        final _Fix f = await _fix(
          tester,
          'item 1/8 lines ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
        );
        try {
          for (final (String, String, String) row in kLines) {
            await f.emote(2, row.$1);
            final String want = ar ? row.$3 : row.$2;
            _expectOnly(f, 2, want, 'emote ${row.$1}');
            await f.s.pump(const Duration(milliseconds: 100));
          }
        } finally {
          await f.done();
        }
      },
    );
  }

  testWidgets('1. an emote makes no sound and no haptic', (tester) async {
    final _Fix f = await _fix(tester, 'item 8 silent');
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

  testWidgets('1. an emote frame does not disturb the state frames around '
      'it: no resume, and the next turn lands', (tester) async {
    final _Fix f = await _fix(tester, 'item 1 no seq');
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
  // Muted (C-500 D2).
  // -------------------------------------------------------------------
  testWidgets('2. muted: another seat\'s line does not show, mine does', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 2 muted', players: 4);
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
      _expectNone(f, 'no line from seats 1, 2, 3 while muted');
      await f.emote(0, 'oops');
      _expectOnly(f, 0, 'Oops', 'my own line (seat 0) shows while muted');
    } finally {
      await f.done();
    }
  });

  testWidgets('2. muted from a seat that is not seat 0: my seat is the one '
      'that stays', (tester) async {
    final _Fix f = await _fix(tester, 'item 2 muted as seat 2', me: 2);
    try {
      await _toggleMute(f);
      await f.emote(0, 'hi');
      _expectNone(f, 'seat 0 hidden, I am 2');
      await f.emote(2, 'hi');
      _expectOnly(f, 2, 'Hi all', 'mine (seat 2) shows');
    } finally {
      await f.done();
    }
  });

  testWidgets('2. unmuting brings the next line back', (tester) async {
    final _Fix f = await _fix(tester, 'item 2 unmute');
    try {
      await _toggleMute(f);
      await f.emote(2, 'hi');
      _expectNone(f, 'hidden while muted');
      await _toggleMute(f);
      expect(await _muteIsOn(f), isFalse, reason: f.s.why('fixture: unmuted'));
      await f.emote(2, 'good_game');
      _expectOnly(f, 2, 'Good game', 'shows after unmuting');
    } finally {
      await f.done();
    }
  });

  testWidgets('2. the switch keeps its state when the sheet is opened again', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 2 switch memory');
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

  testWidgets('2. a hidden line never removes the line that is up and does '
      'not restart it', (tester) async {
    final _Fix f = await _fix(tester, 'item 2 hidden keeps mine', players: 4);
    try {
      await _toggleMute(f);
      await f.emote(0, 'oops');
      final int mine = f.zero;
      await f.s.pump(const Duration(milliseconds: 1000));
      await f.emote(1, 'nice');
      _expectOnly(f, 0, 'Oops', 'seat 1 is hidden, my line stays');
      expect(
        f.textOf(0),
        isNot(contains('Nice move')),
        reason: f.s.why('seat 1\'s text is not on screen'),
      );
      await f.s.pump(Duration(milliseconds: mine + 2490 - f.s.clockMs));
      _expectOnly(f, 0, 'Oops', 'mine at its own 2490 ms');
      await f.s.pump(const Duration(milliseconds: 20));
      _expectNone(f, 'mine is gone at its own 2500 ms, not restarted');
    } finally {
      await f.done();
    }
  });

  testWidgets('2. turning mute on takes down another seat\'s line that is '
      'up', (tester) async {
    final _Fix f = await _fix(tester, 'item 2 mute takes down', players: 4);
    try {
      await f.emote(2, 'hi');
      _expectOnly(f, 2, 'Hi all', 'fixture: seat 2\'s line is up');
      await _toggleMute(f);
      _expectNone(f, 'mute on removed seat 2\'s line');
      await f.s.pump(const Duration(milliseconds: 3000));
      _expectNone(f, 'and it did not come back');
    } finally {
      await f.done();
    }
  });

  testWidgets('2. turning mute on leaves my own line up', (tester) async {
    final _Fix f = await _fix(tester, 'item 2 mute keeps mine', players: 4);
    try {
      await f.emote(0, 'oops');
      _expectOnly(f, 0, 'Oops', 'fixture: my line is up');
      await _toggleMute(f);
      _expectOnly(f, 0, 'Oops', 'mute on does not touch mine');
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // What is not a line (kept from item 6).
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
    testWidgets('2. ${bad.$1}: no line, no pop and no exception', (
      tester,
    ) async {
      final _Fix f = await _fix(tester, 'item 2 ${bad.$1}');
      try {
        await f.emote(bad.$2, bad.$3);
        await f.s.pump(const Duration(milliseconds: 300));
        _expectNone(f, '${bad.$1} shows nothing');
        expect(
          f.popSerial,
          isNull,
          reason: f.s.why('${bad.$1} hands the board no chatPop'),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: f.s.why('and throws nothing'),
        );
        await f.emote(2, 'hi');
        _expectOnly(f, 2, 'Hi all', 'a good emote afterwards still shows');
      } finally {
        await f.done();
      }
    });
  }

  testWidgets('2. a bad emote does not remove the good line already up, and '
      'does not pop', (tester) async {
    final _Fix f = await _fix(tester, 'item 2 bad after good');
    try {
      await f.emote(2, 'hi');
      final int? serial = f.popSerial;
      expect(serial, isNotNull, reason: f.s.why('fixture: the pop is passed'));
      await f.emote(2, 'nope');
      _expectOnly(f, 2, 'Hi all', 'seat 2 keeps its line');
      await f.emote(9, 'oops');
      _expectOnly(f, 2, 'Hi all', 'a bad seat changes nothing');
      expect(
        f.popSerial,
        serial,
        reason: f.s.why('neither bad frame is a new serial'),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Clearing (C-500 D3).
  // -------------------------------------------------------------------
  testWidgets('3. a resync (a seq gap answered by a snapshot) clears the '
      'line', (tester) async {
    final _Fix f = await _fix(tester, 'clear on resync', players: 4);
    try {
      await f.emote(2, 'nice');
      _expectOnly(f, 2, 'Nice move', 'fixture: a line is up');
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
      _expectNone(f, 'the resync cleared the line');
      await f.emote(2, 'oops');
      _expectOnly(f, 2, 'Oops', 'new lines still work after');
    } finally {
      await f.done();
    }
  });

  testWidgets('3. a resume after a dropped socket clears the line', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'clear on resume', players: 4);
    try {
      await f.emote(3, 'nice');
      _expectOnly(f, 3, 'Nice move', 'fixture: a line is up');
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
      _expectNone(f, 'the resume cleared the line');
    } finally {
      await f.done();
    }
  });

  testWidgets('3. the room going PLAYING to FINISHED does not clear the line: '
      'it is still up on the end card and gone at its own 2500 ms', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 3 game over', players: 4);
    try {
      await f.emote(2, 'nice');
      _expectOnly(f, 2, 'Nice move', 'fixture: the line is up in PLAYING');
      await f.s.pump(const Duration(milliseconds: 500));
      await f.s.push('game_over', gameOverFrame(1));
      await f.s.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(_winnerKey),
        findsOneWidget,
        reason: f.s.why('fixture: the end card is the body'),
      );
      _expectOnly(f, 2, 'Nice move', 'game_over did not clear it');
      await f.at(2490);
      _expectOnly(f, 2, 'Nice move', 'still up on the card at 2490 ms');
      await f.at(2510);
      _expectNone(f, 'gone at its own 2500 ms, not at game_over');
      await f.s.pump(const Duration(milliseconds: 3000));
      _expectNone(f, 'and none came back');
    } finally {
      await f.done();
    }
  });

  testWidgets('3. a line pushed on the end card is the same layer and the '
      'same life', (tester) async {
    final _Fix f = await _fix(tester, 'item 3 line after game over');
    try {
      await f.s.push('game_over', gameOverFrame(2));
      await f.s.pump(const Duration(milliseconds: 100));
      await f.emote(2, 'good_game');
      _expectOnly(f, 2, 'Good game', 'on the end card');
      await f.at(2490);
      _expectOnly(f, 2, 'Good game', 'up at 2490 ms');
      await f.at(2510);
      _expectNone(f, 'gone at 2500 ms');
    } finally {
      await f.done();
    }
  });

  testWidgets('3. the held end (the board still shown in FINISHED) shows the '
      'line, and it survives into the end card', (tester) async {
    final _Fix f = await _fix(
      tester,
      'item 3 held end',
      seats: pairSeats(mySeat: 0, mine: const <int>[51, -1, -1, -1]),
    );
    try {
      await f.s.push('moved', movedFrame(0, 0, 51, 57));
      await f.s.push('game_over', gameOverFrame(0));
      expect(
        find.byKey(bigDieKey),
        findsOneWidget,
        reason: f.s.why('fixture: the board is still the body (held end)'),
      );
      expect(
        find.byKey(_winnerKey),
        findsNothing,
        reason: f.s.why('fixture: the end card is not up yet'),
      );
      await f.emote(2, 'good_game');
      await f.s.pump(const Duration(milliseconds: 200));
      _expectOnly(f, 2, 'Good game', 'on the held end');
      _expectNoBoardChatKeys(f, 'the held end');
      while (find.byKey(_winnerKey).evaluate().isEmpty &&
          f.s.clockMs - f.zero < 6000) {
        await f.s.pump(const Duration(milliseconds: 50));
      }
      final int cardAt = f.s.clockMs - f.zero;
      expect(
        find.byKey(_winnerKey),
        findsOneWidget,
        reason: f.s.why('fixture: the end card came up'),
      );
      expect(
        cardAt,
        lessThan(2400),
        reason: f.s.why(
          'fixture: the card came up at $cardAt ms, inside the line\'s life',
        ),
      );
      _expectOnly(f, 2, 'Good game', 'the same line on the end card');
      await f.at(2510);
      _expectNone(f, 'gone at its own 2500 ms');
    } finally {
      await f.done();
    }
  });

  testWidgets('3. a rematch lobby shows a line, and the rematch starting '
      'clears it', (tester) async {
    final _Fix f = await _fix(tester, 'item 3 rematch');
    try {
      await f.s.push('game_over', gameOverFrame(2));
      await f.s.pump(const Duration(milliseconds: 100));
      await f.s.push('room', <String, Object?>{
        ...roomData(seats: pairSeats(mySeat: 0), state: 'LOBBY', winner: null),
        'rematch': <String, Object?>{
          'by': 2,
          'ready': <int>[2],
        },
      });
      await f.s.pump(const Duration(milliseconds: 100));
      await f.emote(2, 'hi');
      _expectOnly(f, 2, 'Hi all', 'in a rematch lobby');
      await f.s.pump(const Duration(milliseconds: 300));
      await f.s.push('game_started', <String, Object?>{
        'turn': 2,
        'game_id': 'c500-game-2',
        'client_seeds': 'a,b',
      });
      await f.s.push('turn', turnFrame(2));
      await f.s.pump(const Duration(milliseconds: 50));
      _expectNone(f, 'the rematch\'s game_started cleared it');
      await f.emote(2, 'oops');
      _expectOnly(f, 2, 'Oops', 'a new line works in the rematch game');
    } finally {
      await f.done();
    }
  });

  testWidgets('3. leaving the screen with a line up leaves no timer behind', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'item 3 dispose');
    await f.emote(2, 'good_game');
    _expectOnly(f, 2, 'Good game', 'fixture: a line is up with 2500 ms to go');
    await f.done();
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------
  // Place (C-500 D4): the header band, between the insets.
  // -------------------------------------------------------------------
  for (final bool ar in const <bool>[false, true]) {
    for (final double width in const <double>[360, 411]) {
      testWidgets(
        'place: ${width.toInt()} dp, ${ar ? 'ar' : 'en'}: a short line is '
        'centred in the span between the insets, vertically in the row',
        (tester) async {
          expect(_insetWithChat, 112);
          final _Fix f = await _fix(
            tester,
            'place $width ${ar ? 'ar' : 'en'}',
            locale: Locale(ar ? 'ar' : 'en'),
            size: Size(width, width == 411 ? 891 : 800),
          );
          try {
            expect(
              find.byKey(_chatButton),
              findsOneWidget,
              reason: f.s.why('fixture: the row carries the chat button'),
            );
            await f.emote(2, 'oops');
            await f.at(400);
            final Rect row = _headerRow(tester);
            final Rect span = _span(tester, row, ar: ar);
            final Rect bubble = f.rectOf(2);
            final double maxWidth = math.min(320, span.width);
            _expectInSpan(f, bubble, span, maxWidth);
            expect(
              bubble.center.dx,
              closeTo(span.center.dx, 1),
              reason: f.s.why(
                'centred in the span, not on the row: bubble $bubble, '
                'span $span, row $row',
              ),
            );
            _expectTop(f, bubble, row);
            expect(
              bubble.bottom,
              lessThanOrEqualTo(row.bottom + 0.5),
              reason: f.s.why('at text scale 1.0 the bubble stays in the row'),
            );
            _expectClearOf(f, bubble, _leaveKey);
            _expectClearOf(f, bubble, _chatButton);
            _expectClearOf(f, bubble, _soundKey);
          } finally {
            await f.done();
          }
        },
      );
    }
  }

  // (width, ar, whether some preset must be too long for the span): the
  // Arabic presets are all short enough for the 188 dp span of a 360 dp
  // screen at 2.0 text, so the ellipsis rule is exercised there on a 320 dp
  // screen (148 dp span) instead.
  for (final (double, bool, bool) setup in const <(double, bool, bool)>[
    (360, false, true),
    (360, true, false),
    (320, false, true),
    (320, true, true),
  ]) {
    final double width = setup.$1;
    final bool ar = setup.$2;
    final bool mustEllipsize = setup.$3;
    testWidgets(
      'place: ${width.toInt()} x 640 at 2.0 text, ${ar ? 'ar' : 'en'}: '
      'every preset stays inside the span, one line tall, ellipsis when it '
      'does not fit, top by the row rule, and never meets a button',
      (tester) async {
        final _Fix f = await _fix(
          tester,
          'place 2x $width ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
          textScale: 2.0,
          size: Size(width, 640),
        );
        try {
          await f.emote(2, 'oops');
          await f.at(400);
          final Rect row = _headerRow(tester);
          final Rect span = _span(tester, row, ar: ar);
          final double maxWidth = math.min(320, span.width);
          final double oneLine = f.rectOf(2).height;
          final TextScaler scaler = MediaQuery.textScalerOf(
            tester.element(find.byKey(lineKey(2))),
          );
          int decisiveLong = 0;
          for (final (String, String, String) row3 in kLines) {
            await f.emote(2, row3.$1);
            await f.at(400);
            final String line = ar ? row3.$3 : row3.$2;
            final Rect bubble = f.rectOf(2);
            _expectInSpan(f, bubble, span, maxWidth);
            _expectTop(f, bubble, row);
            _expectOneLineTall(f, row3.$1, bubble, oneLine);
            _expectClearOf(f, bubble, _leaveKey);
            _expectClearOf(f, bubble, _chatButton);
            _expectClearOf(f, bubble, _soundKey);
            final TextStyle style = _styleOf(
              tester,
              find.byKey(lineKey(2)),
              line,
            );
            final double need = _width(line, style, scaler) + _chrome;
            if (need >= maxWidth + 8) {
              decisiveLong += 1;
              expect(
                bubble.width,
                closeTo(maxWidth, 1),
                reason: f.s.why(
                  '${row3.$1} needs $need dp, more than the $maxWidth dp '
                  'max: it takes the max and ellipsizes, bubble $bubble',
                ),
              );
              final RichText rich = tester.widget<RichText>(
                find
                    .descendant(
                      of: find.byKey(lineKey(2)),
                      matching: find.byType(RichText),
                    )
                    .first,
              );
              expect(rich.maxLines, 1, reason: f.s.why('${row3.$1}: one line'));
              expect(
                rich.overflow,
                TextOverflow.ellipsis,
                reason: f.s.why('${row3.$1}: ellipsis'),
              );
            }
          }
          if (mustEllipsize) {
            expect(
              decisiveLong,
              greaterThan(0),
              reason: f.s.why(
                'fixture: at least one preset is too long for $maxWidth dp '
                'at 2.0 text, or the ellipsis rule is never exercised',
              ),
            );
          }
          expect(
            tester.takeException(),
            isNull,
            reason: f.s.why('no overflow'),
          );
        } finally {
          await f.done();
        }
      },
    );
  }

  testWidgets('place: at 2.0 text a bubble taller than the row paints down '
      'over the body, above it (not under it)', (tester) async {
    final _Fix f = await _fix(
      tester,
      'place over the body',
      textScale: 2.0,
      size: const Size(360, 640),
    );
    try {
      await f.emote(2, 'oops');
      await f.at(400);
      final Rect row = _headerRow(tester);
      final Rect bubble = f.rectOf(2);
      expect(
        bubble.height,
        greaterThan(_rowDp),
        reason: f.s.why(
          'fixture: at 2.0 the bubble $bubble is taller than '
          'the 48 dp row $row',
        ),
      );
      expect(
        bubble.bottom,
        greaterThan(row.bottom),
        reason: f.s.why('it paints down over the body'),
      );
      final _Pixels px = await _Pixels.of(tester, find.byKey(lineKey(2)));
      final Color border = LudoColors.seats[2];
      final Color read = px.at(bubble.center.dx, bubble.bottom - 1);
      expect(
        _near(read, border, 10),
        isTrue,
        reason: f.s.why(
          'the bottom border of $bubble, below the row (bottom '
          '${row.bottom}), is the seat colour $border, read $read: the '
          'layer is above the whole screen column',
        ),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('place: the line takes no layout space: the board, the die, '
      'the banner and the three buttons stay put', (tester) async {
    final _Fix f = await _fix(tester, 'no space', turn: _sixTurn());
    try {
      final Rect row = _headerRow(tester);
      final Map<String, Rect> before = <String, Rect>{
        'board': tester.getRect(find.byKey(boardKey)),
        'die': tester.getRect(find.byKey(bigDieKey)),
        'banner': tester.getRect(find.byKey(_bannerKey)),
        'leave': tester.getRect(find.byKey(_leaveKey)),
        'chat': tester.getRect(find.byKey(_chatButton)),
        'sound': tester.getRect(find.byKey(_soundKey)),
      };
      await f.emote(2, 'revenge');
      await f.at(400);
      expect(f.seats, <int>[2], reason: f.s.why('fixture: the line is up'));
      expect(_headerRow(tester), row, reason: f.s.why('the header row moved'));
      final Map<String, Rect> after = <String, Rect>{
        'board': tester.getRect(find.byKey(boardKey)),
        'die': tester.getRect(find.byKey(bigDieKey)),
        'banner': tester.getRect(find.byKey(_bannerKey)),
        'leave': tester.getRect(find.byKey(_leaveKey)),
        'chat': tester.getRect(find.byKey(_chatButton)),
        'sound': tester.getRect(find.byKey(_soundKey)),
      };
      expect(
        after,
        before,
        reason: f.s.why('nothing moved when the line came up'),
      );
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // What the player needs is never covered (C-500 "Tests").
  // -------------------------------------------------------------------
  final RegExp tokenKey = RegExp(r'^token-\d-\d$');
  final RegExp seatDieKeys = RegExp(r'^board-seat-die-\d$');
  final RegExp ringKeys = RegExp(r'^board-legal-ring-\d-\d$');

  for (final bool ar in const <bool>[false, true]) {
    testWidgets(
      'need: 360 x 640 at 1.0, ${ar ? 'ar' : 'en'}, my turn with a 6 and '
      'four ringed yard tokens: the line covers no ring, token, seat die, '
      'the board or the turn banner',
      (tester) async {
        final _Fix f = await _fix(
          tester,
          'need 1x ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
          size: const Size(360, 640),
          turn: _sixTurn(),
        );
        try {
          expect(ringedTokens(tester), <int>[
            0,
            1,
            2,
            3,
          ], reason: f.s.why('fixture: four ringed yard tokens'));
          for (final String id in const <String>[
            'revenge',
            'your_move',
            'oops',
          ]) {
            await f.emote(2, id);
            await f.at(400);
            final Rect bubble = f.rectOf(2);
            _expectClearOfAll(
              f,
              bubble,
              _rectsMatching(tester, ringKeys),
              'legal rings',
            );
            _expectClearOfAll(
              f,
              bubble,
              _rectsMatching(tester, tokenKey),
              'tokens',
            );
            _expectClearOfAll(
              f,
              bubble,
              _rectsMatching(tester, seatDieKeys),
              'seat dice',
            );
            expect(
              bubble.overlaps(boardSquare(tester)),
              isFalse,
              reason: f.s.why(
                '$id: bubble $bubble covers the board ${boardSquare(tester)}',
              ),
            );
            _expectClearOf(f, bubble, _bannerKey);
            expect(ringedTokens(tester), <int>[
              0,
              1,
              2,
              3,
            ], reason: f.s.why('$id: the rings are still there'));
          }
        } finally {
          await f.done();
        }
      },
    );

    testWidgets(
      'need: 360 x 640 at 2.0, ${ar ? 'ar' : 'en'}, the same turn: the '
      'line covers none of the board\'s tokens or dice',
      (tester) async {
        final _Fix f = await _fix(
          tester,
          'need 2x ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
          size: const Size(360, 640),
          textScale: 2.0,
          turn: _sixTurn(),
        );
        try {
          expect(ringedTokens(tester), <int>[
            0,
            1,
            2,
            3,
          ], reason: f.s.why('fixture: four ringed yard tokens'));
          for (final String id in const <String>['revenge', 'oops']) {
            await f.emote(2, id);
            await f.at(400);
            final Rect bubble = f.rectOf(2);
            _expectClearOfAll(
              f,
              bubble,
              _rectsMatching(tester, tokenKey),
              'tokens',
            );
            _expectClearOfAll(
              f,
              bubble,
              _rectsMatching(tester, seatDieKeys),
              'seat dice',
            );
          }
          expect(
            tester.takeException(),
            isNull,
            reason: f.s.why('no overflow'),
          );
        } finally {
          await f.done();
        }
      },
    );

    testWidgets(
      'need: ${ar ? 'ar' : 'en'}, an opponent\'s die showing a 4 in its '
      'yard stays uncovered for the whole life of the line',
      (tester) async {
        final _Fix f = await _fix(
          tester,
          'need opponent die ${ar ? 'ar' : 'en'}',
          locale: Locale(ar ? 'ar' : 'en'),
          size: const Size(360, 640),
          seats: pairSeats(mySeat: 0, opponent: const <int>[8, -1, -1, -1]),
        );
        try {
          await f.s.push('turn', turnFrame(2));
          await f.s.push(
            'rolled',
            rolledFrame(2, 4, 1, legal: const <int>[0], queue: const <int>[4]),
          );
          int waited = 0;
          while (find.byKey(seatDieFaceKey(2, 4)).evaluate().isEmpty &&
              waited < 3000) {
            await f.s.pump(const Duration(milliseconds: 50));
            waited += 50;
          }
          expect(
            find.byKey(seatDieFaceKey(2, 4)),
            findsOneWidget,
            reason: f.s.why(
              'fixture: seat 2\'s die shows a 4 in its yard after $waited ms',
            ),
          );
          await f.emote(2, 'revenge');
          for (final int ms in const <int>[0, 300, 1200, 2400]) {
            await f.at(ms);
            final Rect bubble = f.rectOf(2);
            expect(
              bubble.overlaps(tester.getRect(find.byKey(seatDieKey(2)))),
              isFalse,
              reason: f.s.why(
                'at $ms ms the bubble $bubble covers the die of seat 2 '
                '${tester.getRect(find.byKey(seatDieKey(2)))}',
              ),
            );
            _expectClearOfAll(
              f,
              bubble,
              _rectsMatching(tester, tokenKey),
              'tokens',
            );
          }
        } finally {
          await f.done();
        }
      },
    );
  }

  for (final bool ar in const <bool>[false, true]) {
    for (final double width in const <double>[360, 411]) {
      testWidgets(
        'need: ${width.toInt()} dp, ${ar ? 'ar' : 'en'}: the line never '
        'meets the leave, chat or sound button, short or long, at 1.0 '
        'and 2.0',
        (tester) async {
          for (final double scale in const <double>[1.0, 2.0]) {
            final _Fix f = await _fix(
              tester,
              'buttons $width ${ar ? 'ar' : 'en'} x$scale',
              locale: Locale(ar ? 'ar' : 'en'),
              textScale: scale,
              size: Size(width, width == 411 ? 891 : 640),
            );
            try {
              for (final (String, String, String) row in kLines) {
                await f.emote(2, row.$1);
                await f.at(400);
                final Rect bubble = f.rectOf(2);
                _expectClearOf(f, bubble, _leaveKey);
                _expectClearOf(f, bubble, _chatButton);
                _expectClearOf(f, bubble, _soundKey);
              }
            } finally {
              await f.done();
            }
          }
        },
      );
    }
  }

  testWidgets('need: a tap on a ringed token still moves it with a line up, '
      'and a hit on the bubble reaches nothing inside it', (tester) async {
    final _Fix f = await _fix(tester, 'taps', turn: _sixTurn());
    try {
      await f.emote(2, 'revenge');
      await f.at(400);
      f.requireLine(2);
      final RenderObject bubbleBox = tester.renderObject(
        find.byKey(lineKey(2)),
      );
      final Offset at = tester.getCenter(find.byKey(lineKey(2)));
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
        reason: f.s.why(
          'a hit at the bubble centre $at reached ${inside.length} render '
          'objects inside the bubble',
        ),
      );
      final int sent = f.s.drive.transport.sentRaw.length;
      await tester.tap(find.byKey(tokenHitKey(0, 1)), warnIfMissed: false);
      await tester.pump();
      f.s.steps.add('tap board-token-hit-0-1');
      final List<Map<String, Object?>> moves = movesSince(
        f.s.drive.transport,
        sent,
      );
      expect(moves, hasLength(1), reason: f.s.why('the tap sent one move'));
      expect(moves.single['token'], 1, reason: f.s.why('and named token 1'));
    } finally {
      await f.done();
    }
  });

  // The cases that pinned the board bubble's layer against the gloat, the
  // thrown die, the face picker and the safe cue now say the line covers
  // none of them.
  testWidgets('need: a line covers neither the capture gloat nor the thrown '
      'die', (tester) async {
    final _Fix f = await _fix(
      tester,
      'clear of gloat and throw',
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
      await f.at(400);
      _expectClearOf(f, f.rectOf(2), gloatKey(2));
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
      expect(f.seats, <int>[2], reason: f.s.why('fixture: the line is up'));
      _expectClearOf(f, f.rectOf(2), opponentThrowKey(2));
    } finally {
      await f.done();
    }
  });

  testWidgets('need: a line covers no face picker option', (tester) async {
    final _Fix f = await _fix(
      tester,
      'clear of face picker',
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
      expect(f.seats, <int>[1], reason: f.s.why('fixture: the line is up'));
      _expectClearOf(f, f.rectOf(1), facePickerKey);
    } finally {
      await f.done();
    }
  });

  testWidgets('need: a line covers no safe cue star', (tester) async {
    final _Fix f = await _fix(
      tester,
      'clear of safe cue',
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
      expect(f.seats, <int>[1], reason: f.s.why('fixture: the line is up'));
      _expectClearOf(f, f.rectOf(1), star);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // No board chat keys (C-500 D6).
  // -------------------------------------------------------------------
  for (final bool ar in const <bool>[false, true]) {
    testWidgets('board: ${ar ? 'ar' : 'en'}: no board-chat-layer, '
        'board-chat-slot-* or chat-bubble-* anywhere, with or without a '
        'line, a burst, mute or the end card', (tester) async {
      final _Fix f = await _fix(
        tester,
        'no board keys ${ar ? 'ar' : 'en'}',
        locale: Locale(ar ? 'ar' : 'en'),
        players: 4,
      );
      try {
        _expectNoBoardChatKeys(f, 'before any line');
        for (final int seat in const <int>[1, 2, 3, 0]) {
          await f.emote(seat, 'nice');
          await f.s.pump(const Duration(milliseconds: 20));
          _expectNoBoardChatKeys(f, 'a line from seat $seat');
        }
        await f.at(400);
        _expectNoBoardChatKeys(f, 'the line, settled');
        await _toggleMute(f);
        await f.emote(1, 'hi');
        _expectNoBoardChatKeys(f, 'muted, a hidden line');
        await f.emote(0, 'oops');
        _expectNoBoardChatKeys(f, 'muted, my own line');
        await f.s.push('game_over', gameOverFrame(2));
        await f.s.pump(const Duration(milliseconds: 100));
        _expectNoBoardChatKeys(f, 'on the end card with my line up');
        await f.at(2600);
        _expectNoBoardChatKeys(f, 'after the line ends');
      } finally {
        await f.done();
      }
    });
  }

  testWidgets('board: at 2.0 text on 360 x 640 there is no board chat key '
      'either', (tester) async {
    final _Fix f = await _fix(
      tester,
      'no board keys 2x',
      textScale: 2.0,
      size: const Size(360, 640),
      turn: _sixTurn(),
    );
    try {
      await f.emote(2, 'revenge');
      await f.at(400);
      _expectNoBoardChatKeys(f, 'at 2.0 with a line up');
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // Fit (C-500 D5): name then line, or the line alone, measured.
  // -------------------------------------------------------------------
  for (final bool ar in const <bool>[false, true]) {
    for (final (double, List<String>) setup in <(double, List<String>)>[
      (360, <String>['i' * 20, 'W' * 12, 'Jo']),
      (411, <String>['i' * 20, 'W' * 18, 'Jo']),
    ]) {
      testWidgets(
        'fit: ${setup.$1.toInt()} dp, ${ar ? 'ar' : 'en'}: the name is '
        'dropped when name and line do not fit and kept when they do, by '
        'measured width and not by character count; the label is always '
        'chatSaid',
        (tester) async {
          final SemanticsHandle handle = tester.ensureSemantics();
          final double width = setup.$1;
          final List<String> names = setup.$2;
          final _Fix f = await _fix(
            tester,
            'fit $width ${ar ? 'ar' : 'en'}',
            locale: Locale(ar ? 'ar' : 'en'),
            players: 4,
            size: Size(width, width == 411 ? 891 : 800),
            seats: <Map<String, Object?>>[
              seatJson(0, name: 'Sam'),
              seatJson(1, name: names[0]),
              seatJson(2, name: names[1]),
              seatJson(3, name: names[2]),
            ],
          );
          try {
            final String line = _lineOf('good_game', ar: ar);
            await f.emote(3, 'good_game');
            await f.at(400);
            f.requireLine(3);
            final Rect row = _headerRow(tester);
            final Rect span = _span(tester, row, ar: ar);
            final double maxWidth = math.min(320, span.width);
            final TextScaler scaler = MediaQuery.textScalerOf(
              tester.element(find.byKey(lineKey(3))),
            );
            final TextStyle nameStyle = _styleOf(
              tester,
              find.byKey(lineKey(3)),
              'Jo',
            );
            final TextStyle lineStyle = _styleOf(
              tester,
              find.byKey(lineKey(3)),
              line,
            );
            final double lineWidth = _width(line, lineStyle, scaler);
            int kept = 0;
            int dropped = 0;
            for (int i = 0; i < 3; i++) {
              final int seat = i + 1;
              final String name = names[i];
              await f.emote(seat, 'good_game');
              await f.at(400);
              final double total = _width(name, nameStyle, scaler) + lineWidth;
              final String text = f.textOf(seat);
              expect(
                text,
                contains(line),
                reason: f.s.why(
                  'seat $seat: the line is always there: "$text"',
                ),
              );
              if (total <= maxWidth - _chrome - 16) {
                kept += 1;
                expect(
                  text,
                  contains(name),
                  reason: f.s.why(
                    'seat $seat: name and line need $total dp, well inside '
                    '${maxWidth - _chrome} dp: the name is kept, reads "$text"',
                  ),
                );
                expect(
                  text.indexOf(name),
                  lessThan(text.lastIndexOf(line)),
                  reason: f.s.why('seat $seat: the name comes first'),
                );
              } else if (total >= maxWidth) {
                dropped += 1;
                expect(
                  text,
                  isNot(contains(name)),
                  reason: f.s.why(
                    'seat $seat: name and line need $total dp, more than '
                    '$maxWidth dp: the line alone, reads "$text"',
                  ),
                );
              }
              expect(
                f.rectOf(seat).width,
                lessThanOrEqualTo(maxWidth + 0.5),
                reason: f.s.why('seat $seat: inside the max width $maxWidth'),
              );
              final SemanticsNode node = tester.getSemantics(
                find.byKey(lineKey(seat)),
              );
              expect(
                node.label,
                '$name: $line',
                reason: f.s.why(
                  'seat $seat: the label is chatSaid(name, line)',
                ),
              );
              expect(
                node.flagsCollection.isLiveRegion,
                isTrue,
                reason: f.s.why('seat $seat: the line is a live region'),
              );
            }
            expect(
              kept,
              greaterThan(0),
              reason: f.s.why(
                'fixture: at least one name must fit by measure ($kept kept, '
                '$dropped dropped)',
              ),
            );
            expect(
              dropped,
              greaterThan(0),
              reason: f.s.why(
                'fixture: at least one name must not fit by measure ($kept '
                'kept, $dropped dropped)',
              ),
            );
          } finally {
            handle.dispose();
            await f.done();
          }
        },
      );
    }
  }

  // -------------------------------------------------------------------
  // The chip pop (C-500 D6).
  // -------------------------------------------------------------------
  testWidgets('pop: every seat in play has board-chip-pop-<seat> at exactly '
      '1.0 before anyone speaks, and it wraps that seat\'s name chip', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'pop at rest', players: 4);
    try {
      for (int seat = 0; seat < 4; seat++) {
        expect(
          _scaleOf(tester, seat, f.s.why('at rest')),
          1.0,
          reason: f.s.why('seat $seat rests at 1.0'),
        );
        expect(
          find.descendant(
            of: find.byKey(chipPopKey(seat)),
            matching: find.byKey(nameChipKey(seat)),
          ),
          findsOneWidget,
          reason: f.s.why('board-chip-pop-$seat wraps board-seat-name-$seat'),
        );
      }
    } finally {
      await f.done();
    }
  });

  testWidgets('pop: the speaker\'s chip is above 1.1 at 120 ms and exactly '
      '1.0 by 300 ms, and stays 1.0 to the end of the line; the other chips '
      'never move', (tester) async {
    final _Fix f = await _fix(tester, 'pop trace', players: 4);
    try {
      await f.emote(2, 'hi');
      final List<_PopSample> trace = await _popTrace(f, 2, to: 320);
      _expectPop(f, trace, 2);
      for (final int seat in const <int>[0, 1, 3]) {
        expect(
          _scaleOf(tester, seat, f.s.why('another seat')),
          1.0,
          reason: f.s.why('seat $seat did not pop for seat 2'),
        );
      }
      for (final int ms in const <int>[800, 1500, 2490]) {
        await f.at(ms);
        expect(
          _scaleOf(tester, 2, f.s.why('late')),
          closeTo(1.0, 1e-6),
          reason: f.s.why('once only: seat 2 is at 1.0 at $ms ms'),
        );
      }
    } finally {
      await f.done();
    }
  });

  testWidgets('pop: a second line pops again, and a line from another seat '
      'pops its own chip and not the first', (tester) async {
    final _Fix f = await _fix(tester, 'pop again', players: 4);
    try {
      await f.emote(1, 'hi');
      _expectPop(f, await _popTrace(f, 1, to: 320), 1);
      await f.s.pump(const Duration(milliseconds: 700));
      await f.emote(1, 'nice');
      _expectPop(f, await _popTrace(f, 1, to: 320), 1);
      await f.s.pump(const Duration(milliseconds: 300));
      await f.emote(3, 'oops');
      _expectPop(f, await _popTrace(f, 3, to: 320), 3);
      expect(
        _scaleOf(tester, 1, f.s.why('first speaker')),
        1.0,
        reason: f.s.why('seat 1 rests while seat 3 spoke'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('pop: my own chip pops, from the server\'s copy only: my send '
      'alone shows nothing and pops nothing', (tester) async {
    final _Fix f = await _fix(tester, 'pop mine');
    try {
      final int sent = f.s.drive.transport.sentRaw.length;
      await f.tester.tap(find.byKey(_chatButton));
      await f.tester.pump();
      await f.s.pump(const Duration(milliseconds: 400));
      await f.tester.tap(find.byKey(const Key('quick-chat-hi')));
      await f.tester.pump();
      await f.s.pump(const Duration(milliseconds: 400));
      if (find.byKey(_sheetKey).evaluate().isNotEmpty) {
        await f.tester.tapAt(const Offset(180, 20));
        await f.tester.pump();
        await f.s.pump(const Duration(milliseconds: 400));
      }
      final List<Map<String, Object?>> sentEmotes = emotesSince(
        f.s.drive.transport,
        sent,
      );
      expect(
        sentEmotes,
        hasLength(1),
        reason: f.s.why('fixture: the tap sent one emote request'),
      );
      final String request = sentEmotes.single['id']! as String;
      await f.s.pump(const Duration(milliseconds: 600));
      _expectNone(f, 'my request alone, before the server\'s copy');
      expect(
        _scaleOf(tester, 0, f.s.why('before the copy')),
        1.0,
        reason: f.s.why('my chip has not popped'),
      );
      expect(f.popSerial, isNull, reason: f.s.why('no chatPop yet'));
      await f.emote(0, 'hi', re: request);
      _expectOnly(f, 0, 'Hi all', 'the server\'s copy of my line');
      _expectPop(f, await _popTrace(f, 0, to: 320), 0);
    } finally {
      await f.done();
    }
  });

  testWidgets('pop: a hidden line (muted) pops nothing; my own line still '
      'pops', (tester) async {
    final _Fix f = await _fix(tester, 'pop muted', players: 4);
    try {
      await _toggleMute(f);
      await f.emote(2, 'hi');
      final List<_PopSample> quiet = await _popTrace(f, 2, to: 320);
      for (final _PopSample e in quiet) {
        expect(
          e.scale,
          closeTo(1.0, 1e-6),
          reason: f.s.why('a hidden line does not pop seat 2; sample $e'),
        );
      }
      expect(
        f.popSerial,
        isNull,
        reason: f.s.why('no chatPop for a hidden line'),
      );
      await f.emote(0, 'oops');
      _expectPop(f, await _popTrace(f, 0, to: 320), 0);
    } finally {
      await f.done();
    }
  });

  testWidgets('pop: reduced motion, every chip is 1.0 throughout and the '
      'line is up from the first frame', (tester) async {
    final _Fix f = await _fix(tester, 'pop reduced', players: 4, reduced: true);
    try {
      await f.emote(2, 'hi');
      _expectOnly(f, 2, 'Hi all', 'on the first frame under disableAnimations');
      while (f.s.clockMs - f.zero <= 600) {
        for (int seat = 0; seat < 4; seat++) {
          expect(
            _scaleOf(tester, seat, f.s.why('reduced motion')),
            1.0,
            reason: f.s.why(
              'chip $seat is 1.0 at ${f.s.clockMs - f.zero} ms under '
              'disableAnimations',
            ),
          );
        }
        await f.s.pump(const Duration(milliseconds: 16));
      }
      expect(
        f.popSeat,
        2,
        reason: f.s.why('the pop is still handed to the board'),
      );
    } finally {
      await f.done();
    }
  });

  testWidgets('pop: GameScreen hands the board the speaker and a new serial '
      'per shown line, and nothing for a hidden one', (tester) async {
    final _Fix f = await _fix(tester, 'pop seam', players: 4);
    try {
      expect(f.popSerial, isNull, reason: f.s.why('no chatPop at rest'));
      await f.emote(2, 'hi');
      expect(f.popSeat, 2, reason: f.s.why('chatPop names the speaker'));
      final int first = f.popSerial!;
      await f.s.pump(const Duration(milliseconds: 1000));
      expect(
        f.popSerial,
        first,
        reason: f.s.why('the serial holds while the line is up'),
      );
      await f.emote(2, 'nice');
      final int second = f.popSerial!;
      expect(
        second,
        isNot(first),
        reason: f.s.why('a second line from the same seat is a new serial'),
      );
      await f.emote(3, 'oops');
      expect(f.popSeat, 3, reason: f.s.why('chatPop follows the newest'));
      expect(
        f.popSerial,
        isNot(second),
        reason: f.s.why('and carries its own serial'),
      );
    } finally {
      await f.done();
    }
  });

  // C-500 D6 as amended in run 117: the chip is flush on the board's outer
  // edge and the board clips, so the pill grows inward: its painted rect is
  // inside the board's and its outer edge stays on the board's edge.
  for (final bool ar in const <bool>[false, true]) {
    for (final bool topEdge in const <bool>[true, false]) {
      final String edge = topEdge ? 'top' : 'bottom';
      testWidgets('pop: 360 x 640, ${ar ? 'ar' : 'en'}, a $edge-edge seat: the '
          'painted chip is inside the board and its outer edge stays on the '
          'board\'s $edge edge from 0 to 300 ms, at 120 ms included', (
        tester,
      ) async {
        final _Fix f = await _fix(
          tester,
          'pop inward $edge ${ar ? 'ar' : 'en'}',
          players: 4,
          locale: Locale(ar ? 'ar' : 'en'),
          size: const Size(360, 640),
        );
        try {
          // The board is the square the chips sit on; the LudoBoard widget
          // is taller than it by the room it leaves round the square.
          final Rect board = boardSquare(tester);
          final Map<int, Rect> rest = <int, Rect>{
            for (int seat = 0; seat < 4; seat++)
              seat: _paintedRect(tester, find.byKey(chipPopKey(seat))),
          };
          final List<int> onEdge = <int>[
            for (final MapEntry<int, Rect> e in rest.entries)
              if (topEdge
                  ? (e.value.top - board.top).abs() <= 0.5
                  : (e.value.bottom - board.bottom).abs() <= 0.5)
                e.key,
          ];
          expect(
            onEdge,
            isNotEmpty,
            reason: f.s.why(
              'fixture: some seat\'s chip rests flush on the board\'s '
              '$edge edge (C-500 D6: the chip sits flush on the outer '
              'edge); board $board, chips at rest $rest',
            ),
          );
          final int seat = onEdge.first;
          final Rect resting = rest[seat]!;
          await f.emote(seat, 'hi');
          for (final int ms in const <int>[0, 60, 120, 180, 240, 300]) {
            await f.at(ms);
            final Rect painted = _paintedRect(
              tester,
              find.byKey(chipPopKey(seat)),
            );
            final String at =
                'seat $seat at $ms ms into the pop: painted chip $painted '
                '(at rest $resting), board $board, scale '
                '${_scaleOf(tester, seat, f.s.why('read the scale'))}';
            expect(
              painted.left,
              greaterThanOrEqualTo(board.left - 0.5),
              reason: f.s.why('the chip is inside the board on the left: $at'),
            );
            expect(
              painted.right,
              lessThanOrEqualTo(board.right + 0.5),
              reason: f.s.why('the chip is inside the board on the right: $at'),
            );
            expect(
              painted.top,
              greaterThanOrEqualTo(board.top - 0.5),
              reason: f.s.why('the chip is inside the board at the top: $at'),
            );
            expect(
              painted.bottom,
              lessThanOrEqualTo(board.bottom + 0.5),
              reason: f.s.why(
                'the chip is inside the board at the bottom: $at',
              ),
            );
            expect(
              topEdge ? painted.top : painted.bottom,
              closeTo(topEdge ? board.top : board.bottom, 0.5),
              reason: f.s.why(
                'the chip\'s outer edge stays on the board\'s $edge edge '
                '(the pop is anchored there and grows inward): $at',
              ),
            );
            if (ms == 120) {
              expect(
                painted.height,
                greaterThan(resting.height + 1),
                reason: f.s.why(
                  'fixture: the chip is really popped at 120 ms, taller '
                  'than at rest: $at',
                ),
              );
            }
          }
        } finally {
          await f.done();
        }
      });
    }
  }

  group('pop on a bare LudoBoard', () {
    Future<List<_PopSample>> trace(
      WidgetTester tester,
      int seat, {
      int to = 320,
    }) async {
      final List<_PopSample> out = <_PopSample>[];
      for (int t = 0; t <= to; t += 5) {
        out.add((
          t: t,
          scale: _scaleOf(tester, seat, 'bare board, chip $seat at $t ms'),
        ));
        await tester.pump(const Duration(milliseconds: 5));
      }
      return out;
    }

    testWidgets('a new serial scales that seat\'s chip 1.0 to above 1.1 at '
        '120 ms and back to 1.0 by 300 ms, once', (tester) async {
      await tester.pumpWidget(_directBoard(pop: null));
      await tester.pump();
      expect(_scaleOf(tester, 2, 'no chatPop'), 1.0);
      await tester.pumpWidget(
        _directBoard(pop: BoardChatPop(seat: 2, serial: 1)),
      );
      final List<_PopSample> t2 = await trace(tester, 2, to: 700);
      expect(t2.first.scale, closeTo(1.0, 0.02), reason: 'starts at 1.0');
      expect(
        t2.firstWhere((_PopSample e) => e.t >= 120).scale,
        greaterThan(1.1),
        reason: 'serial 1 on seat 2: above 1.1 at 120 ms, got $t2',
      );
      for (final _PopSample e in t2.where((_PopSample e) => e.t >= 300)) {
        expect(
          e.scale,
          closeTo(1.0, 1e-6),
          reason: 'serial 1 on seat 2: exactly 1.0 by 300 ms, sample $e',
        );
      }
      for (final int other in const <int>[0, 1, 3]) {
        expect(
          _scaleOf(tester, other, 'other chip'),
          1.0,
          reason: 'seat $other did not pop for seat 2',
        );
      }
    });

    testWidgets('the same serial on a rebuild does not pop again; a new '
        'serial does, on the same seat and on another', (tester) async {
      await tester.pumpWidget(_directBoard(pop: null));
      await tester.pumpWidget(
        _directBoard(pop: BoardChatPop(seat: 2, serial: 1)),
      );
      await trace(tester, 2, to: 700);
      await tester.pumpWidget(
        _directBoard(pop: BoardChatPop(seat: 2, serial: 1)),
      );
      final List<_PopSample> same = await trace(tester, 2, to: 320);
      for (final _PopSample e in same) {
        expect(
          e.scale,
          closeTo(1.0, 1e-6),
          reason: 'the same serial 1 rebuilt: no second pop, sample $e',
        );
      }
      await tester.pumpWidget(
        _directBoard(pop: BoardChatPop(seat: 2, serial: 2)),
      );
      final List<_PopSample> next = await trace(tester, 2, to: 320);
      expect(
        next.firstWhere((_PopSample e) => e.t >= 120).scale,
        greaterThan(1.1),
        reason: 'serial 2 on seat 2 pops again, got $next',
      );
      await trace(tester, 2, to: 400);
      await tester.pumpWidget(
        _directBoard(pop: BoardChatPop(seat: 3, serial: 3)),
      );
      final List<_PopSample> other = await trace(tester, 3, to: 320);
      expect(
        other.firstWhere((_PopSample e) => e.t >= 120).scale,
        greaterThan(1.1),
        reason: 'serial 3 on seat 3 pops seat 3, got $other',
      );
      expect(
        _scaleOf(tester, 2, 'first speaker'),
        closeTo(1.0, 1e-6),
        reason: 'seat 2 rests once seat 3 has popped',
      );
    });

    testWidgets('a pop for a seat that is not in play throws nothing and '
        'scales nothing', (tester) async {
      await tester.pumpWidget(
        _directBoard(pop: null, seats: const <int>[0, 2]),
      );
      await tester.pumpWidget(
        _directBoard(
          pop: BoardChatPop(seat: 1, serial: 1),
          seats: const <int>[0, 2],
        ),
      );
      for (int t = 0; t <= 320; t += 20) {
        for (final int seat in const <int>[0, 2]) {
          expect(
            _scaleOf(tester, seat, 'seat 1 is not in play'),
            1.0,
            reason: 'chip $seat at $t ms is untouched by a pop for seat 1',
          );
        }
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('under disableAnimations a new serial scales nothing', (
      tester,
    ) async {
      await tester.pumpWidget(_directBoard(pop: null, reduced: true));
      await tester.pumpWidget(
        _directBoard(pop: BoardChatPop(seat: 2, serial: 1), reduced: true),
      );
      for (int t = 0; t <= 600; t += 16) {
        expect(
          _scaleOf(tester, 2, 'reduced motion'),
          1.0,
          reason: 'chip 2 is 1.0 at $t ms under disableAnimations',
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
    });
  });

  // -------------------------------------------------------------------
  // Look, motion, semantics: C-492 D3 on the header line, kept in intent
  // from the board bubble's own look, motion and semantics cases.
  // -------------------------------------------------------------------
  for (final int seat in const <int>[1, 3]) {
    testWidgets('look: seat $seat\'s line has a 2 dp border in the seat '
        'colour, a paperElevated fill, rounded corners and no tail', (
      tester,
    ) async {
      final _Fix f = await _fix(tester, 'look seat $seat', players: 4);
      try {
        await f.emote(seat, 'oops');
        await f.at(400);
        f.requireLine(seat);
        final Finder bubble = find.byKey(lineKey(seat));
        final _Pixels px = await _Pixels.of(tester, bubble);
        final Rect r = tester.getRect(bubble);
        final Color border = LudoColors.seats[seat];
        final double mid = r.center.dy;
        expect(
          _near(px.at(r.left + 1, mid), border, 8),
          isTrue,
          reason: f.s.why(
            'the left border is the seat colour $border, read '
            '${px.at(r.left + 1, mid)}',
          ),
        );
        expect(
          _near(px.at(r.right - 1, mid), border, 8),
          isTrue,
          reason: f.s.why('the right border is the seat colour'),
        );
        expect(
          _near(px.at(r.center.dx, r.top + 1), border, 8),
          isTrue,
          reason: f.s.why('the top border is the seat colour'),
        );
        expect(
          _near(px.at(r.center.dx, r.bottom - 1), border, 8),
          isTrue,
          reason: f.s.why('the bottom border is the seat colour: no tail'),
        );
        expect(
          _near(px.at(r.left + 4, mid), LudoColors.paperElevated, 8),
          isTrue,
          reason: f.s.why(
            '4 dp in is the paperElevated fill, so the border is 2 dp, read '
            '${px.at(r.left + 4, mid)}',
          ),
        );
        expect(
          _near(px.at(r.left + 0.5, r.top + 0.5), border, 8),
          isFalse,
          reason: f.s.why('the corner pixel is not border: rounded corners'),
        );
      } finally {
        await f.done();
      }
    });
  }

  testWidgets('look: the name in w700, then the line in w500, labelLarge, '
      'one line with an ellipsis', (tester) async {
    final _Fix f = await _fix(tester, 'look text', players: 4);
    try {
      await f.emote(0, 'oops');
      await f.at(400);
      f.requireLine(0);
      final Finder bubble = find.byKey(lineKey(0));
      final RichText rich = tester.widget<RichText>(
        find.descendant(of: bubble, matching: find.byType(RichText)).first,
      );
      final List<(String, TextStyle)> leaves = spanLeaves(rich.text);
      final int nameAt = leaves.indexWhere(
        ((String, TextStyle) l) => l.$1.contains('Sam'),
      );
      final int lineAt = leaves.indexWhere(
        ((String, TextStyle) l) => l.$1.contains('Oops'),
      );
      expect(
        nameAt,
        isNonNegative,
        reason: f.s.why('a short name and a short line show both: $leaves'),
      );
      expect(lineAt, isNonNegative, reason: f.s.why('a span has the line'));
      expect(nameAt, lessThan(lineAt), reason: f.s.why('the name comes first'));
      expect(
        leaves[nameAt].$2.fontWeight,
        FontWeight.w700,
        reason: f.s.why('name w700'),
      );
      expect(
        leaves[lineAt].$2.fontWeight,
        FontWeight.w500,
        reason: f.s.why('line w500'),
      );
      final double label = Theme.of(tester.element(bubble))
          .textTheme
          .labelLarge!
          .fontSize!;
      expect(
        leaves[lineAt].$2.fontSize,
        label,
        reason: f.s.why('labelLarge size'),
      );
      expect(rich.maxLines, 1, reason: f.s.why('one line'));
      expect(rich.overflow, TextOverflow.ellipsis, reason: f.s.why('ellipsis'));
    } finally {
      await f.done();
    }
  });

  testWidgets('motion: scale 0.6 to 1.0 in 160 ms, full opacity to 2250 ms, '
      'fades out over the last 250 ms, gone at 2500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'motion');
    try {
      await f.emote(2, 'good_game');
      await f.at(400);
      f.requireLine(2);
      final double base = textWidthUnder(tester, find.byKey(lineKey(2)));
      await f.s.pump(const Duration(milliseconds: 3000));
      _expectNone(f, 'fixture: the first run ended');
      await f.emote(2, 'good_game');
      final List<({int t, double scale, double alpha})> trace =
          <({int t, double scale, double alpha})>[];
      while (f.s.clockMs - f.zero <= 2495 && f.seats.isNotEmpty) {
        trace.add((
          t: f.s.clockMs - f.zero,
          scale: textWidthUnder(tester, find.byKey(lineKey(2))) / base,
          alpha: alphaUnder(tester, find.byKey(lineKey(2))),
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
        reason: f.s.why('half way through the fade it is half gone; $mid'),
      );
      expect(
        trace.last.alpha,
        lessThan(0.15),
        reason: f.s.why('nearly gone at the end of the fade; $sum'),
      );
      await f.at(2510);
      _expectNone(f, 'gone at 2500 ms');
    } finally {
      await f.done();
    }
  });

  testWidgets('motion: reduced, the line is at full size and opacity from '
      'the first frame to the end and is removed at 2500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'motion reduced', reduced: true);
    try {
      await f.emote(2, 'good_game');
      f.requireLine(2);
      final double first = textWidthUnder(tester, find.byKey(lineKey(2)));
      await f.at(400);
      final double settled = textWidthUnder(tester, find.byKey(lineKey(2)));
      expect(
        first,
        closeTo(settled, 0.5),
        reason: f.s.why('first frame is already full size: $first vs $settled'),
      );
      while (f.s.clockMs - f.zero < 2490) {
        expect(
          textWidthUnder(tester, find.byKey(lineKey(2))),
          closeTo(settled, 0.5),
          reason: f.s.why('no scale at ${f.s.clockMs - f.zero} ms'),
        );
        expect(
          alphaUnder(tester, find.byKey(lineKey(2))),
          closeTo(1.0, 0.01),
          reason: f.s.why('full opacity at ${f.s.clockMs - f.zero} ms'),
        );
        final int left = 2490 - (f.s.clockMs - f.zero);
        await f.s.pump(Duration(milliseconds: left < 100 ? left : 100));
      }
      _expectOnly(f, 2, 'Good game', 'present at 2490 ms');
      await f.at(2510);
      _expectNone(f, 'removed at 2500 ms');
    } finally {
      await f.done();
    }
  });

  for (final bool ar in const <bool>[false, true]) {
    testWidgets('semantics: ${ar ? 'ar' : 'en'}: the line is a live region '
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
        f.requireLine(2);
        final SemanticsNode node = tester.getSemantics(find.byKey(lineKey(2)));
        expect(
          node.label,
          'Cara: ${_lineOf('revenge', ar: ar)}',
          reason: f.s.why('label is chatSaid(name, line)'),
        );
        expect(
          node.flagsCollection.isLiveRegion,
          isTrue,
          reason: f.s.why('the line is a live region'),
        );
      } finally {
        handle.dispose();
        await f.done();
      }
    });
  }
}
