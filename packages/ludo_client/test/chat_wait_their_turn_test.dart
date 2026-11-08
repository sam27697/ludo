// Screen proof for C-596 (order 596t): at a busy table a quick message that
// arrives while another is still inside its minimum dwell waits its turn
// instead of replacing it. Written from the C-596 contract alone; the
// implementation (order 596) was being written in another tree and has not
// been read. The only new symbol of that contract is kChatMinDwell, and this
// file does not name it: the dwell is the literal 1200 ms of D1 (_dwellMs
// below), so every case that does not need the new behaviour compiles and
// runs on the base.
//
// A real GameScreen over a real RoomController on FakeTransport, every state
// a decoded wire frame, fake time from the pump. Four seats, I am seat 0,
// PLAYING, on a 360x800 surface at pixel ratio 1 unless a case names another
// size. The app fonts are loaded for the whole file, so every width is a
// real one.
//
// Time is read off a trace. A _Run pumps the screen a few milliseconds at a
// time and, after each pump, records which `end-card-chat-<seat>` is up and
// the serial and seat of the board's chatPop. A line is a run of samples that
// share one (seat, serial); when it started and ended is read off the
// samples, in milliseconds after the run's origin (the first emote of the
// case). Around every edge the case names (1200 ms and its multiples by
// default) the pump steps 1 ms, so "1199 ms" and "1200 ms" are exact.
//
// There is no random input: the scenario name that starts every failure
// message, with the frames and pumps listed at its end, is the whole
// reproduction. A case replays by running it alone with
// `flutter test test/chat_wait_their_turn_test.dart --plain-name '<name>'`.
//
// Ambiguities in the contract, reported and not invented around:
//   - D3 "skipped exactly as _chatLineOf already skips an unknown seat" does
//     not say whether the skipped line still holds the screen for a dwell or
//     hands over at once. Not asserted.
//   - Where muting while my own line waits behind another seat's line puts my
//     line on screen (at the mute, or when the dwell of the dropped line
//     would have ended) is not stated. Case (f) asserts only that it shows,
//     and that no other seat's line does.
//   - Case (j) reads "the bubble stays inside the band" as the bubble's rect
//     lying in the 48 dp header row, found as the widest 48 dp-tall ancestor
//     of game-screen-appbar-leave, exactly as quick_chat_board_test.dart
//     finds it.
//   - Case (j) reads D4 as: at any ambient scale above 1.3 the bubble is the
//     size it has at 1.3, width as well as height.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/quick_chat.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

/// kChatMinDwell (C-596 D1), as the literal the contract gives.
const int _dwellMs = 1200;

/// kChatBubbleLife, as the literal of chat_bubble.dart.
const int _lifeMs = 2500;

const Key _chatButton = Key('game-chat-button');
const Key _muteKey = Key('quick-chat-mute');
const Key _sheetKey = Key('quick-chat-sheet');
const Key _leaveKey = Key('game-screen-appbar-leave');

const String _linePrefix = 'end-card-chat-';

Key lineKey(int seat) => Key('$_linePrefix$seat');

Key chipPopKey(int seat) => Key('board-chip-pop-$seat');

/// The header row's own height.
const double _rowDp = 48;

/// The bubble's own chrome: a 2 dp border and 8 dp of padding a side.
const double _chrome = 2 * (2 + 8);

/// C-492 D6 and C-500 D4: the start inset, and the end inset while the row
/// carries the chat button.
const double _inset = kSpace2 + _rowDp + kSpace1;
const double _insetWithChat = _inset + _rowDp + kSpace1;

Finder anyLine() => find.byWidgetPredicate((Widget w) {
  final Key? key = w.key;
  return key is ValueKey<String> &&
      key.value.startsWith(_linePrefix) &&
      int.tryParse(key.value.substring(_linePrefix.length)) != null;
});

/// The seats whose `end-card-chat-<seat>` is on screen, ascending.
List<int> lineSeats() => <int>[
  for (final Element e in anyLine().evaluate())
    int.parse(
      (e.widget.key! as ValueKey<String>).value.substring(_linePrefix.length),
    ),
]..sort();

/// All the text painted under [root], joined with nothing between spans.
String textUnder(Finder root) => <String>[
  for (final Element e
      in find.descendant(of: root, matching: find.byType(RichText)).evaluate())
    (e.widget as RichText).text.toPlainText(),
].join();

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

// ---------------------------------------------------------------------
// The fixture.
// ---------------------------------------------------------------------

class _Fix {
  _Fix(this.s, this.locale);

  final Scn s;
  final Locale locale;

  WidgetTester get tester => s.tester;

  /// Clock reading of the last [emoteNow], the zero of [at].
  int zero = 0;

  Future<void> emoteNow(Object? seat, Object? id) async {
    await s.pushEmote(seat, id);
    zero = s.clockMs;
  }

  Future<void> at(int ms) async {
    final int target = zero + ms;
    if (target > s.clockMs) {
      await s.pump(Duration(milliseconds: target - s.clockMs));
    }
  }

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byKey(_leaveKey)));

  /// The preset's text in this fixture's language, from AppLocalizations.
  String text(String id) => quickChatLine(loc, id)!;

  /// The board's chatPop, null when none is passed or no board is mounted.
  BoardChatPop? get pop {
    final Finder board = find.byType(LudoBoard);
    if (board.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<LudoBoard>(board).chatPop;
  }

  Future<void> done() => releaseGame(tester, s.drive);
}

Future<_Fix> _fix(
  WidgetTester tester,
  String name, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  Size size = const Size(360, 800),
  List<Map<String, Object?>>? seats,
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = size;
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: awaitRollTurn(2),
    seats: seats ?? quadSeats(mySeat: 0),
    mySeat: 0,
    players: 4,
  );
  await mountGame(tester, drive, locale: locale, textScale: textScale);
  return _Fix(Scn(name, tester, drive), locale);
}

// ---------------------------------------------------------------------
// The trace.
// ---------------------------------------------------------------------

typedef _Sample = ({
  int t,
  List<int> seats,
  String text,
  int? popSeat,
  int? popSerial,
});

/// One line as the trace saw it: from [start] (first sample it was up in) to
/// [end] (first sample it was gone in, or the last sample when it was still
/// up at the end of the trace).
typedef _Shown = ({int seat, String text, int? serial, int start, int end});

class _Run {
  _Run(this.f, {this.edges = const <int>[1200, 2400, 3600]})
    : origin = f.s.clockMs;

  final _Fix f;

  /// The moments after the origin that are stepped 1 ms either side of.
  final List<int> edges;

  /// Clock reading of the zero of this run.
  final int origin;

  final List<_Sample> samples = <_Sample>[];

  /// Called after every sample on which a line is up.
  Future<void> Function()? probe;

  int get now => f.s.clockMs - origin;

  bool _fine(int t) => edges.any((int e) => t >= e - 10 && t < e + 10);

  Future<void> _sample() async {
    final List<int> seats = lineSeats();
    final BoardChatPop? pop = f.pop;
    samples.add((
      t: now,
      seats: seats,
      text: seats.length == 1
          ? textUnder(find.byKey(lineKey(seats.first)))
          : '',
      popSeat: pop?.seat,
      popSerial: pop?.serial,
    ));
    if (seats.isNotEmpty && probe != null) {
      await probe!();
    }
  }

  /// Pumps up to [ms] after the origin, sampling after every pump.
  Future<void> runTo(int ms) async {
    f.s.steps.add('run to ${ms}ms');
    while (now < ms) {
      final int step = _fine(now) ? 1 : math.min(10, ms - now);
      await f.tester.pump(Duration(milliseconds: step));
      f.s.clockMs += step;
      await _sample();
    }
  }

  /// The emote frame of [seat] [id] lands at [atMs] after the origin.
  Future<void> emote(int atMs, Object? seat, Object? id) async {
    await runTo(atMs);
    await f.s.pushEmote(seat, id);
    await _sample();
  }

  List<_Shown> shown() {
    final List<_Shown> out = <_Shown>[];
    ({int seat, String text, int? serial, int start})? open;
    String? openKey;
    void close(int end) {
      if (open != null) {
        out.add((
          seat: open!.seat,
          text: open!.text,
          serial: open!.serial,
          start: open!.start,
          end: end,
        ));
        open = null;
        openKey = null;
      }
    }

    for (final _Sample s in samples) {
      final String? key = s.seats.isEmpty
          ? null
          : '${s.seats.join(',')}|${s.popSerial}|${s.text}';
      if (key != openKey) {
        close(s.t);
        if (key != null) {
          open = (
            seat: s.seats.first,
            text: s.text,
            serial: s.popSerial,
            start: s.t,
          );
          openKey = key;
        }
      }
    }
    close(samples.isEmpty ? 0 : samples.last.t);
    return out;
  }

  /// What is up now: the seats on screen and the text of the first.
  List<int> get upSeats => lineSeats();
}

String _fmt(List<_Shown> runs) => runs.isEmpty
    ? '(nothing was ever shown)'
    : runs
          .map(
            (_Shown r) =>
                'seat ${r.seat} "${r.text}" ${r.start}-${r.end} ms '
                '(serial ${r.serial})',
          )
          .join(' | ');

/// The lines shown, in order, are [order] (seat, preset id).
void _expectOrder(_Fix f, _Run run, List<(int, String)> order, String what) {
  final List<_Shown> runs = run.shown();
  expect(
    <int>[for (final _Shown r in runs) r.seat],
    <int>[for (final (int, String) o in order) o.$1],
    reason: f.s.why(
      '$what: lines shown in the order of seats '
      '${<int>[for (final (int, String) o in order) o.$1]}, trace: '
      '${_fmt(runs)}',
    ),
  );
  for (int i = 0; i < runs.length; i++) {
    expect(
      runs[i].text,
      contains(f.text(order[i].$2)),
      reason: f.s.why(
        '$what: shown line $i (seat ${runs[i].seat}) says '
        '"${f.text(order[i].$2)}", trace: ${_fmt(runs)}',
      ),
    );
  }
}

/// Every shown line but the last stayed up for at least the dwell.
void _expectDwells(_Fix f, List<_Shown> runs, String what) {
  for (int i = 0; i < runs.length - 1; i++) {
    expect(
      runs[i].end - runs[i].start,
      greaterThanOrEqualTo(_dwellMs),
      reason: f.s.why(
        '$what: seat ${runs[i].seat}\'s line (shown $i) keeps the screen for '
        'at least $_dwellMs ms, trace: ${_fmt(runs)}',
      ),
    );
  }
}

void _expectStarts(_Fix f, List<_Shown> runs, List<int> starts, String what) {
  expect(
    <int>[for (final _Shown r in runs) r.start],
    starts,
    reason: f.s.why(
      '$what: lines start at $starts ms after the first arrival, trace: '
      '${_fmt(runs)}',
    ),
  );
}

void _expectUp(_Fix f, int seat, String id, String what) {
  expect(
    lineSeats(),
    <int>[seat],
    reason: f.s.why(
      '$what: only end-card-chat-$seat is up (up: ${lineSeats()})',
    ),
  );
  expect(
    textUnder(find.byKey(lineKey(seat))),
    contains(f.text(id)),
    reason: f.s.why('$what: end-card-chat-$seat says "${f.text(id)}"'),
  );
}

void _expectNone(_Fix f, String what) {
  expect(
    lineSeats(),
    isEmpty,
    reason: f.s.why('$what: no end-card-chat-<seat> (up: ${lineSeats()})'),
  );
}

// ---------------------------------------------------------------------
// The sheet.
// ---------------------------------------------------------------------

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
/// the 48 dp row, in the space of [WidgetTester.getRect].
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

/// The span the bubble is centred in, between the start inset and the end
/// inset (which carries the chat button as well). In ar the start side is
/// the right.
Rect _span(WidgetTester tester, Rect row, {required bool ar}) {
  final bool chat = tester.any(find.byKey(_chatButton));
  final double start = _inset;
  final double end = chat ? _insetWithChat : _inset;
  return Rect.fromLTRB(
    row.left + (ar ? end : start),
    row.top,
    row.right - (ar ? start : end),
    row.bottom,
  );
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

/// The scale of `board-chip-pop-<seat>`, read off the Transform itself.
double _chipScale(_Fix f, int seat, String what) {
  final Finder pop = find.byKey(chipPopKey(seat));
  expect(
    pop,
    findsOneWidget,
    reason: f.s.why('$what: board-chip-pop-$seat is on the board'),
  );
  final Widget widget = f.tester.widget(pop);
  expect(
    widget,
    isA<Transform>(),
    reason: f.s.why('$what: board-chip-pop-$seat is a Transform'),
  );
  return (widget as Transform).transform.storage[0];
}

// ---------------------------------------------------------------------
// (j) measurements.
// ---------------------------------------------------------------------

typedef _Measured = ({Rect bubble, Rect row});

/// The bubble of seat 2 for every preset, at [scale] in [locale], measured
/// 400 ms after each arrives (the pop is over) and 1300 ms apart (every line
/// has had its dwell, so each replaces the one before at once).
Future<Map<String, _Measured>> _measureAll(
  WidgetTester tester,
  Locale locale,
  double scale,
) async {
  final _Fix f = await _fix(
    tester,
    'j measure ${locale.languageCode} x$scale',
    locale: locale,
    textScale: scale,
  );
  final Map<String, _Measured> out = <String, _Measured>{};
  try {
    for (final String id in kQuickChatIds) {
      await f.emoteNow(2, id);
      await f.at(400);
      expect(lineSeats(), <int>[
        2,
      ], reason: f.s.why('j: $id is up at 400 ms (up: ${lineSeats()})'));
      out[id] = (
        bubble: tester.getRect(find.byKey(lineKey(2))),
        row: _headerRow(tester),
      );
      await f.at(_dwellMs + 100);
    }
    expect(tester.takeException(), isNull, reason: f.s.why('j: no overflow'));
  } finally {
    await f.done();
  }
  return out;
}

/// (width, height) of seat 2's bubble ("Cara" is its name in this fixture)
/// at text scale 1.0 for each preset, in dp, measured on the base 6ef05b1
/// (this branch, before any implementation) by _measureAll: the rect of the
/// `end-card-chat-2` key 400 ms after the arrival, at 360x800, pixel ratio 1,
/// the app fonts loaded, each width and height printed to two decimals from
/// a run of the 1.0 case below with a print added. Every height is 32.00:
/// one 14 px line, 6 dp of padding twice, a 2 dp border twice. Measured, not
/// guessed; D4 says nothing changes at 1.0.
const Map<String, Map<String, (double, double)>> _baseSizeAt1 =
    <String, Map<String, (double, double)>>{
      'en': <String, (double, double)>{
        'hi': (93.91, 32.00),
        'good_luck': (130.87, 32.00),
        'your_move': (169.14, 32.00),
        'nice': (134.76, 32.00),
        'lucky': (122.72, 32.00),
        'oops': (96.49, 32.00),
        'ha_ha': (123.81, 32.00),
        'revenge': (169.98, 32.00),
        'coming': (177.56, 32.00),
        'back_home': (148.78, 32.00),
        'no_way': (116.27, 32.00),
        'good_game': (144.10, 32.00),
      },
      'ar': <String, (double, double)>{
        'hi': (138.47, 32.00),
        'good_luck': (105.32, 32.00),
        'your_move': (114.59, 32.00),
        'nice': (112.64, 32.00),
        'lucky': (121.24, 32.00),
        'oops': (90.30, 32.00),
        'ha_ha': (102.45, 32.00),
        'revenge': (128.89, 32.00),
        'coming': (132.17, 32.00),
        'back_home': (133.89, 32.00),
        'no_way': (112.54, 32.00),
        'good_game': (110.12, 32.00),
      },
    };

void main() {
  setUpAll(_loadAppFonts);

  // -------------------------------------------------------------------
  // (a) A line inside the dwell of the one up waits.
  // -------------------------------------------------------------------
  testWidgets('a. seat 1 speaks, seat 2 300 ms later: seat 1 is up at 1199 ms, '
      'seat 2 at 1200 ms', (tester) async {
    final _Fix f = await _fix(tester, 'a waits');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      _expectUp(f, 1, 'good_luck', 'on arrival, nothing before it');
      await run.emote(300, 2, 'hi');
      _expectUp(f, 1, 'good_luck', 'seat 2 spoke inside the dwell (300 ms)');
      await run.runTo(1199);
      _expectUp(f, 1, 'good_luck', 'at 1199 ms');
      await run.runTo(1200);
      _expectUp(f, 2, 'hi', 'at 1200 ms');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('a. the line that waited gets its own full life: up at 2600 ms '
      'when seat 1\'s own timer has run out, up until 3690 ms, gone by '
      '3710 ms', (tester) async {
    final _Fix f = await _fix(tester, 'a2 full life');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(300, 2, 'hi');
      await run.runTo(1200);
      _expectUp(f, 2, 'hi', 'handed over at 1200 ms');
      await run.runTo(2490);
      _expectUp(f, 2, 'hi', 'at 2490 ms, where seat 1\'s life would end');
      await run.runTo(2600);
      _expectUp(f, 2, 'hi', 'at 2600 ms, seat 1\'s old timer does not take it');
      await run.runTo(1200 + _lifeMs - 10);
      _expectUp(f, 2, 'hi', 'at 3690 ms, a full life from the hand-over');
      await run.runTo(1200 + _lifeMs + 10);
      _expectNone(f, 'a full life after the hand-over, then gone');
      await run.runTo(1200 + _lifeMs + 3000);
      _expectNone(f, 'and nothing comes back');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // (b) Order and dwell.
  // -------------------------------------------------------------------
  testWidgets('b. seat 1, then 2 and 3 inside its dwell: shown 1, 2, 3, each '
      'at least 1200 ms, seat 3 up by 2400 ms', (tester) async {
    final _Fix f = await _fix(tester, 'b order');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(200, 3, 'nice');
      await run.runTo(2400 + 100);
      final List<_Shown> runs = run.shown();
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'hi'),
        (3, 'nice'),
      ], 'three seats inside one dwell');
      _expectDwells(f, runs, 'three seats');
      expect(
        runs.last.start,
        lessThanOrEqualTo(2400),
        reason: f.s.why('seat 3 is up by 2400 ms, trace: ${_fmt(runs)}'),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('b. all four seats, mine last: shown 1, 2, 3, 0 at 0, 1200, '
      '2400, 3600 ms; mine keeps a full life', (tester) async {
    final _Fix f = await _fix(tester, 'b2 four seats');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(200, 3, 'nice');
      await run.emote(300, 0, 'oops');
      await run.runTo(3600 + _lifeMs + 200);
      final List<_Shown> runs = run.shown();
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'hi'),
        (3, 'nice'),
        (0, 'oops'),
      ], 'four seats, mine waits like the others');
      _expectStarts(f, runs, <int>[0, 1200, 2400, 3600], 'four seats');
      expect(
        runs.last.end,
        inInclusiveRange(3600 + _lifeMs - 10, 3600 + _lifeMs + 30),
        reason: f.s.why(
          'mine has a full life from its hand-over, trace: ${_fmt(runs)}',
        ),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('b. a line that comes 100 ms into a handed-over line\'s dwell '
      'waits for that dwell: seat 3 at 1300 ms is up at 2400 ms', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'b3 dwell of a handed-over line');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(1300, 3, 'nice');
      await run.runTo(2400 + 100);
      final List<_Shown> runs = run.shown();
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'hi'),
        (3, 'nice'),
      ], 'a late third line');
      _expectStarts(f, runs, <int>[0, 1200, 2400], 'a late third line');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('b. a line that comes after a handed-over line has had its '
      'dwell replaces it at once: seat 3 at 2500 ms', (tester) async {
    final _Fix f = await _fix(tester, 'b4 handed-over line aged');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(2500, 3, 'nice');
      await run.runTo(2600);
      final List<_Shown> runs = run.shown();
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'hi'),
        (3, 'nice'),
      ], 'an aged handed-over line');
      _expectStarts(f, runs, <int>[0, 1200, 2500], 'an aged handed-over line');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // (c) One waiting line per seat.
  // -------------------------------------------------------------------
  testWidgets('c. seat 2 speaks twice while waiting: the order after seat 1 '
      'is 3 then 2 (its second line), its first line is never shown', (
    tester,
  ) async {
    final _Fix f = await _fix(tester, 'c requeue');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(200, 3, 'nice');
      await run.emote(300, 2, 'oops');
      await run.runTo(2400 + 400);
      final List<_Shown> runs = run.shown();
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (3, 'nice'),
        (2, 'oops'),
      ], 'seat 2\'s second line moves to the back');
      _expectDwells(f, runs, 'requeue');
      for (final _Shown r in runs) {
        expect(
          r.text,
          isNot(contains(f.text('hi'))),
          reason: f.s.why(
            'seat 2\'s first line "${f.text('hi')}" is never shown, trace: '
            '${_fmt(runs)}',
          ),
        );
      }
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('c. seat 2 alone waits twice: one line of seat 2 is ever shown, '
      'the newer', (tester) async {
    final _Fix f = await _fix(tester, 'c2 requeue alone');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(200, 2, 'oops');
      await run.runTo(1200 + _lifeMs + 3000);
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'oops'),
      ], 'seat 2 replaced its own waiting line');
      _expectStarts(f, run.shown(), <int>[0, 1200], 'one line of seat 2');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // (d) and (e): today's behaviour, unchanged.
  // -------------------------------------------------------------------
  testWidgets('d. a line after the one up has had 1500 ms replaces it at '
      'once', (tester) async {
    final _Fix f = await _fix(tester, 'd replaces at once');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(1500, 2, 'hi');
      _expectUp(f, 2, 'hi', 'on the frame it landed, 1500 ms after seat 1');
      await run.runTo(1500 + 600);
      final List<_Shown> runs = run.shown();
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'hi'),
      ], 'an aged line is replaced');
      _expectStarts(f, runs, <int>[0, 1500], 'replaced at once');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('d. a line at exactly 1200 ms is not made to wait: the line '
      'up has been up for the dwell', (tester) async {
    final _Fix f = await _fix(tester, 'd2 boundary');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(1200, 2, 'hi');
      _expectUp(f, 2, 'hi', 'on the frame it landed, exactly 1200 ms later');
      await run.runTo(1200 + 600);
      _expectStarts(f, run.shown(), <int>[0, 1200], 'boundary');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('d. the line that replaced at once has its own dwell: seat 3 at '
      '1700 ms waits until 2700 ms', (tester) async {
    final _Fix f = await _fix(tester, 'd3 own dwell');
    try {
      final _Run run = _Run(f, edges: const <int>[1200, 2400, 2700]);
      await run.emote(0, 1, 'good_luck');
      await run.emote(1500, 2, 'hi');
      await run.emote(1700, 3, 'nice');
      await run.runTo(2700 + 100);
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
        (2, 'hi'),
        (3, 'nice'),
      ], 'seat 3 behind a line that replaced at once');
      _expectStarts(f, run.shown(), <int>[0, 1500, 2700], 'own dwell');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('e. nothing waits: a lone line is up at 2490 ms and gone at '
      '2510 ms, and stays gone', (tester) async {
    final _Fix f = await _fix(tester, 'e lone line');
    try {
      _expectNone(f, 'fixture, before any emote');
      await f.emoteNow(2, 'hi');
      _expectUp(f, 2, 'hi', 'on the frame the emote landed');
      for (final int ms in const <int>[300, 1000, 1200, 2000, 2490]) {
        await f.at(ms);
        _expectUp(f, 2, 'hi', 'still up at $ms ms');
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

  testWidgets('e. frames that are not lines wait for nothing: bad id, bad '
      'seat, wrong types inside the dwell show nothing later', (tester) async {
    final _Fix f = await _fix(tester, 'e2 bad frames');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(300, 2, 'nope');
      await run.emote(310, 9, 'hi');
      await run.emote(320, 2, 5);
      await run.emote(330, '2', 'hi');
      await run.emote(340, null, 'hi');
      await run.emote(350, -1, 'hi');
      await run.runTo(1200 + _lifeMs + 3000);
      _expectOrder(f, run, <(int, String)>[
        (1, 'good_luck'),
      ], 'bad frames are never queued');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // (f) Mute.
  // -------------------------------------------------------------------
  testWidgets('f. mute on while seat 2 waits behind seat 1: neither is shown '
      'after; my own waiting line still shows', (tester) async {
    final _Fix f = await _fix(tester, 'f mute');
    try {
      final _Run before = _Run(f);
      await before.emote(0, 1, 'good_luck');
      await before.emote(100, 2, 'hi');
      await before.emote(150, 0, 'oops');
      await before.runTo(200);
      _expectUp(f, 1, 'good_luck', 'fixture: seat 1 is up, seat 2 and I wait');
      await _toggleMute(f);
      final _Run after = _Run(f);
      await after.runTo(_lifeMs + 4000);
      final List<_Shown> runs = after.shown();
      expect(
        <int>[for (final _Shown r in runs) r.seat],
        <int>[0],
        reason: f.s.why(
          'after muting only my own line is shown, trace: ${_fmt(runs)}',
        ),
      );
      expect(
        runs.single.text,
        contains(f.text('oops')),
        reason: f.s.why('my line says "${f.text('oops')}": ${_fmt(runs)}'),
      );
      expect(await _muteIsOn(f), isTrue, reason: f.s.why('fixture: muted'));
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('f. mute on, then off: the lines dropped by the mute do not '
      'come back, a new line shows', (tester) async {
    final _Fix f = await _fix(tester, 'f2 mute then unmute');
    try {
      final _Run before = _Run(f);
      await before.emote(0, 1, 'good_luck');
      await before.emote(100, 2, 'hi');
      await before.emote(200, 3, 'nice');
      await before.runTo(250);
      await _toggleMute(f);
      await _toggleMute(f);
      expect(await _muteIsOn(f), isFalse, reason: f.s.why('fixture: unmuted'));
      final _Run after = _Run(f);
      await after.runTo(_lifeMs + 4000);
      expect(
        after.shown(),
        isEmpty,
        reason: f.s.why(
          'no line dropped by the mute is shown after unmuting, trace: '
          '${_fmt(after.shown())}',
        ),
      );
      await f.emoteNow(2, 'oops');
      _expectUp(f, 2, 'oops', 'a new line after unmuting shows at once');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // (g) Clearing.
  // -------------------------------------------------------------------
  testWidgets('g. a resync while lines wait: nothing is shown afterwards, a '
      'new line shows at once', (tester) async {
    final _Fix f = await _fix(tester, 'g resync');
    try {
      final _Run before = _Run(f);
      await before.emote(0, 1, 'good_luck');
      await before.emote(100, 2, 'hi');
      await before.emote(200, 3, 'nice');
      await before.runTo(300);
      _expectUp(f, 1, 'good_luck', 'fixture: seat 1 is up, 2 and 3 wait');
      final int sent = f.s.drive.transport.sentRaw.length;
      f.s.drive.lastSeq += 4;
      await f.s.push('turn', turnFrame(3));
      final List<String> types = sentTypesSince(f.s.drive.transport, sent);
      expect(
        types,
        contains('resume'),
        reason: f.s.why('fixture: a seq gap starts a resync, sent $types'),
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
      final _Run after = _Run(f);
      await after.runTo(_dwellMs + _lifeMs + 3000);
      expect(
        after.shown(),
        isEmpty,
        reason: f.s.why(
          'the resync emptied the waiting list, so nothing is shown, trace: '
          '${_fmt(after.shown())}',
        ),
      );
      await f.emoteNow(2, 'oops');
      _expectUp(f, 2, 'oops', 'after the resync a new line shows at once');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('g. a new game while lines wait: nothing is shown afterwards, a '
      'new line shows at once', (tester) async {
    final _Fix f = await _fix(tester, 'g2 new game');
    try {
      await f.s.push('game_over', gameOverFrame(1));
      await f.s.pump(const Duration(milliseconds: 100));
      await f.s.push('room', <String, Object?>{
        ...roomData(
          seats: quadSeats(mySeat: 0),
          state: 'LOBBY',
          winner: null,
          players: 4,
        ),
        'rematch': <String, Object?>{
          'by': 2,
          'ready': <int>[2],
        },
      });
      await f.s.pump(const Duration(milliseconds: 100));
      final _Run before = _Run(f);
      await before.emote(0, 1, 'good_luck');
      await before.emote(100, 2, 'hi');
      await before.emote(200, 3, 'nice');
      await before.runTo(300);
      _expectUp(f, 1, 'good_luck', 'fixture: seat 1 is up in the lobby');
      await f.s.push('game_started', <String, Object?>{
        'turn': 2,
        'game_id': 'c596-game-2',
        'client_seeds': 'a,b,c,d',
      });
      await f.s.push('turn', turnFrame(2));
      await f.s.pump(const Duration(milliseconds: 50));
      final _Run after = _Run(f);
      await after.runTo(_dwellMs + _lifeMs + 3000);
      expect(
        after.shown(),
        isEmpty,
        reason: f.s.why(
          'the new game emptied the waiting list, so nothing is shown, '
          'trace: ${_fmt(after.shown())}',
        ),
      );
      await f.emoteNow(2, 'oops');
      _expectUp(f, 2, 'oops', 'in the new game a new line shows at once');
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  testWidgets('g. leaving the screen with lines waiting leaves no timer and '
      'throws nothing', (tester) async {
    final _Fix f = await _fix(tester, 'g3 dispose');
    final _Run run = _Run(f);
    await run.emote(0, 1, 'good_luck');
    await run.emote(100, 2, 'hi');
    await run.emote(200, 3, 'nice');
    await run.runTo(300);
    _expectUp(f, 1, 'good_luck', 'fixture: seat 1 is up, 2 and 3 wait');
    await f.done();
    await tester.pump(const Duration(milliseconds: 5000));
    expect(
      tester.takeException(),
      isNull,
      reason: f.s.why('a hand-over after dispose throws nothing'),
    );
  });

  // -------------------------------------------------------------------
  // (h) The board chip pops once per shown line.
  // -------------------------------------------------------------------
  testWidgets('h. each shown line pops its own seat\'s chip, a waiting line '
      'pops nothing, the serial changes per shown line', (tester) async {
    final _Fix f = await _fix(tester, 'h pops');
    try {
      final _Run run = _Run(f);
      await run.emote(0, 1, 'good_luck');
      await run.emote(100, 2, 'hi');
      await run.emote(200, 3, 'nice');
      expect(
        <Object?>[f.pop?.seat, f.pop?.serial != null],
        <Object?>[1, true],
        reason: f.s.why('seat 1 popped on arrival, 2 and 3 did not'),
      );
      final int firstSerial = f.pop!.serial;
      await run.runTo(1199);
      expect(
        f.pop?.serial,
        firstSerial,
        reason: f.s.why('at 1199 ms no waiting line has popped'),
      );
      expect(
        _chipScale(f, 2, 'at 1199 ms, seat 2 waiting'),
        closeTo(1.0, 1e-6),
        reason: f.s.why('a waiting line does not pop its chip'),
      );
      await run.runTo(1200 + 120);
      expect(
        f.pop?.seat,
        2,
        reason: f.s.why('at 1200 ms seat 2\'s line is shown and pops seat 2'),
      );
      final int secondSerial = f.pop!.serial;
      expect(
        secondSerial,
        isNot(firstSerial),
        reason: f.s.why('seat 2\'s line has a new serial'),
      );
      expect(
        _chipScale(f, 2, 'at 1320 ms'),
        greaterThan(1.1),
        reason: f.s.why('seat 2\'s chip is popping 120 ms after its hand-over'),
      );
      await run.runTo(2399);
      expect(
        f.pop?.serial,
        secondSerial,
        reason: f.s.why('at 2399 ms seat 3 has not popped yet'),
      );
      await run.runTo(2400 + 120);
      expect(
        f.pop?.seat,
        3,
        reason: f.s.why('at 2400 ms seat 3\'s line is shown and pops seat 3'),
      );
      final int thirdSerial = f.pop!.serial;
      expect(
        <int>{firstSerial, secondSerial, thirdSerial}.length,
        3,
        reason: f.s.why(
          'three shown lines, three serials: $firstSerial, $secondSerial, '
          '$thirdSerial',
        ),
      );
      expect(
        _chipScale(f, 3, 'at 2520 ms'),
        greaterThan(1.1),
        reason: f.s.why('seat 3\'s chip is popping 120 ms after its hand-over'),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await f.done();
    }
  });

  // -------------------------------------------------------------------
  // (i) TalkBack.
  // -------------------------------------------------------------------
  for (final bool ar in const <bool>[false, true]) {
    testWidgets('i. ${ar ? 'ar' : 'en'}: each shown line is a live region '
        'labelled chatSaid(name, line); a dropped line never appears', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final _Fix f = await _fix(
        tester,
        'i semantics ${ar ? 'ar' : 'en'}',
        locale: Locale(ar ? 'ar' : 'en'),
      );
      try {
        final Map<int, String> names = <int, String>{
          for (final int seat in const <int>[1, 2, 3]) seat: kNames[seat]!,
        };
        String said(int seat, String id) =>
            f.loc.chatSaid(names[seat]!, f.text(id));
        final Set<String> labels = <String>{};
        final Set<String> notLive = <String>{};
        final _Run run = _Run(f);
        run.probe = () async {
          final int seat = lineSeats().first;
          final SemanticsNode node = tester.getSemantics(
            find.byKey(lineKey(seat)),
          );
          labels.add(node.label);
          if (!node.flagsCollection.isLiveRegion) {
            notLive.add(node.label);
          }
        };
        await run.emote(0, 1, 'good_luck');
        await run.emote(100, 2, 'hi');
        await run.emote(200, 3, 'nice');
        await run.emote(300, 2, 'oops');
        await run.runTo(2400 + 400);
        expect(
          labels,
          <String>{said(1, 'good_luck'), said(3, 'nice'), said(2, 'oops')},
          reason: f.s.why(
            'the labels seen are exactly chatSaid for seat 1, seat 3 and '
            'seat 2\'s second line; seat 2\'s first line "${said(2, 'hi')}" '
            'never appears. Saw $labels',
          ),
        );
        expect(
          notLive,
          isEmpty,
          reason: f.s.why('every shown line is a live region; not: $notLive'),
        );
      } finally {
        handle.dispose();
        await f.done();
      }
    });
  }

  // -------------------------------------------------------------------
  // (j) The bubble stays inside the band.
  // -------------------------------------------------------------------
  for (final bool ar in const <bool>[false, true]) {
    final Locale locale = Locale(ar ? 'ar' : 'en');

    testWidgets('j. ${ar ? 'ar' : 'en'}: at text scale 2.0 every preset\'s '
        'bubble lies inside the 48 dp header row', (tester) async {
      final Map<String, _Measured> at2 = await _measureAll(tester, locale, 2.0);
      for (final MapEntry<String, _Measured> e in at2.entries) {
        final Rect b = e.value.bubble;
        final Rect row = e.value.row;
        expect(
          b.top,
          greaterThanOrEqualTo(row.top - 0.01),
          reason:
              'j ${locale.languageCode} x2.0 ${e.key}: bubble top ${b.top} '
              'is not above the row top ${row.top} (bubble $b, row $row)',
        );
        expect(
          b.bottom,
          lessThanOrEqualTo(row.bottom + 0.01),
          reason:
              'j ${locale.languageCode} x2.0 ${e.key}: bubble bottom '
              '${b.bottom} is not above the row bottom ${row.bottom} '
              '(bubble $b, row $row)',
        );
      }
    });

    testWidgets('j. ${ar ? 'ar' : 'en'}: the bubble at 2.0 and at 3.0 is the '
        'size it has at 1.3, the clamp', (tester) async {
      final Map<String, _Measured> at13 = await _measureAll(
        tester,
        locale,
        1.3,
      );
      for (final double scale in const <double>[2.0, 3.0]) {
        final Map<String, _Measured> atMore = await _measureAll(
          tester,
          locale,
          scale,
        );
        for (final String id in kQuickChatIds) {
          final Size want = at13[id]!.bubble.size;
          final Size got = atMore[id]!.bubble.size;
          expect(
            got.height,
            closeTo(want.height, 0.05),
            reason:
                'j ${locale.languageCode} $id: bubble height at x$scale is '
                '${got.height}, expected the ${want.height} it has at 1.3',
          );
          expect(
            got.width,
            closeTo(want.width, 0.05),
            reason:
                'j ${locale.languageCode} $id: bubble width at x$scale is '
                '${got.width}, expected the ${want.width} it has at 1.3',
          );
        }
      }
    });

    testWidgets('j. ${ar ? 'ar' : 'en'}: at text scale 1.0 every bubble is '
        'the size it has on the base', (tester) async {
      final Map<String, _Measured> at1 = await _measureAll(tester, locale, 1.0);
      final Map<String, (double, double)> base =
          _baseSizeAt1[locale.languageCode]!;
      expect(
        base.keys.toSet(),
        kQuickChatIds.toSet(),
        reason: 'j: the base table names every preset',
      );
      for (final String id in kQuickChatIds) {
        final Size got = at1[id]!.bubble.size;
        expect(
          got.width,
          closeTo(base[id]!.$1, 0.05),
          reason:
              'j ${locale.languageCode} $id: bubble width at x1.0 is '
              '${got.width}, expected the ${base[id]!.$1} measured on the base',
        );
        expect(
          got.height,
          closeTo(base[id]!.$2, 0.05),
          reason:
              'j ${locale.languageCode} $id: bubble height at x1.0 is '
              '${got.height}, expected the ${base[id]!.$2} measured on the '
              'base',
        );
      }
    });
  }

  testWidgets('j. the name-first fit is measured at the clamped scale: at '
      '2.0 a name that fits at 1.3 is kept, one that does not is dropped', (
    tester,
  ) async {
    const List<String> names = <String>['Jo', 'Marianne', 'Alexandra Maria'];
    List<Map<String, Object?>> seatsOf() => <Map<String, Object?>>[
      seatJson(0, name: 'Sam'),
      for (int i = 0; i < names.length; i++) seatJson(i + 1, name: names[i]),
    ];
    // The two styles are the same at every scale; read them where 'Jo: Hi
    // all' surely fits.
    final _Fix probe = await _fix(tester, 'j fit styles', seats: seatsOf());
    final TextStyle nameStyle;
    final TextStyle lineStyle;
    try {
      await probe.emoteNow(1, 'hi');
      await probe.at(400);
      nameStyle = _styleOf(tester, find.byKey(lineKey(1)), 'Jo');
      lineStyle = _styleOf(tester, find.byKey(lineKey(1)), probe.text('hi'));
    } finally {
      await probe.done();
    }
    final _Fix f = await _fix(
      tester,
      'j fit at 2.0',
      textScale: 2.0,
      seats: seatsOf(),
    );
    try {
      final TextScaler clamped = const TextScaler.linear(2.0)
          .clamp(maxScaleFactor: 1.3);
      const TextScaler raw = TextScaler.linear(2.0);
      final String line = f.text('hi');
      int keptOnlyByClamp = 0;
      for (int i = 0; i < names.length; i++) {
        final int seat = i + 1;
        await f.emoteNow(seat, 'hi');
        await f.at(400);
        final Rect row = _headerRow(tester);
        final double maxWidth = math.min(
          320,
          _span(tester, row, ar: false).width,
        );
        final double avail = maxWidth - _chrome;
        final double atClamp =
            _width('${names[i]}: ', nameStyle, clamped) +
            _width(line, lineStyle, clamped);
        final double atRaw =
            _width('${names[i]}: ', nameStyle, raw) +
            _width(line, lineStyle, raw);
        final String text = textUnder(find.byKey(lineKey(seat)));
        if (atClamp <= avail - 16) {
          if (atRaw > avail) {
            keptOnlyByClamp += 1;
          }
          expect(
            text,
            contains('${names[i]}: '),
            reason: f.s.why(
              'seat $seat "${names[i]}": name and line need $atClamp dp at '
              'the clamped scale, inside $avail dp: the name is kept (at '
              'the raw 2.0 scale it would need $atRaw dp), reads "$text"',
            ),
          );
        } else if (atClamp >= avail) {
          expect(
            text,
            isNot(contains(names[i])),
            reason: f.s.why(
              'seat $seat "${names[i]}": name and line need $atClamp dp at '
              'the clamped scale, over $avail dp: the line alone, reads '
              '"$text"',
            ),
          );
        }
        await f.at(_dwellMs + 100);
      }
      expect(
        keptOnlyByClamp,
        greaterThan(0),
        reason: f.s.why(
          'fixture: some name must fit at 1.3 and not at 2.0 for this to '
          'tell the clamp from no clamp',
        ),
      );
    } finally {
      await f.done();
    }
  });
}
