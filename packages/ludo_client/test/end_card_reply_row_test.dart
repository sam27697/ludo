// Screen proof for C-498 (order 499): the end card's reply chips stay on one
// row when a tighter chip buys it (X97). Written from
// work/ludo/orders/C-498 alone; the reply row's implementation in
// end_card.dart was being written in another tree and has not been read.
//
// The expected branch of decision 3 is computed here, per case, from chips
// measured alone: a SpeechChip mounted with unbounded width, compact false
// and true, in the same locale, theme, fonts and text scale as the card it
// is compared with. N is the normal widths plus kSpace2 per gap, C the
// compact widths plus kSpace1 per gap, W the max width the keyed Wrap was
// laid out with. No width is typed in. Every failure reason starts with the
// scenario, then the size, locale, scale and the measured numbers.
//
// Fonts: the app fonts are loaded the way test/end_card_large_text_test.dart
// loads them (Poppins and Noto Sans Arabic from the bundle), because under
// the test fallback font every width is the same fixed advance and the
// branch would mean nothing. The helpers are copied, not imported.
//
// Surface: a logical size at pixel ratio 3 with no insets, 360 x 616 unless a
// case says otherwise. Rects are read in logical units.
//
// Cases that need SpeechChip(compact: true) do not compile on a tree that
// has no `compact` parameter; that is the only thing in this file that does
// not.
//
// Ambiguities in the contract, reported and not invented around:
//   - "360x616 at dpr 3" is read as a 360 x 616 logical view, so the physical
//     view is 1080 x 1848.
//   - The text says W is the LayoutBuilder's maxWidth. The cases read it off
//     the keyed Wrap's own incoming constraints, which is that value when the
//     Wrap sits directly under the builder. The docked cases also check it
//     against the 360 less two kSpace4 the contract quotes.
//   - The contract does not say what the row does when N <= W is false and
//     C <= W is true for the winner or the plain card. The cases take the
//     measured branch for whichever card is mounted.
//   - "Above the top of end-card-rematch-ask" alone is too weak to see X97:
//     the dock sits below the scroll's viewport, so a chip can end above the
//     ask and still be cut by the viewport's lower edge. The docked case
//     also requires every chip inside the viewport, which is the reading of
//     "no scroll needed" the contract's reason (P5) gives.
//   - "Wrapping exactly as today" is read as: normal chips, kSpace2 between,
//     greedy runs, each run broken where the next chip no longer fits W.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/chat_bubble.dart';
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _askKey = Key('end-card-rematch-ask');

const Size _phone = Size(360, 616);

const double _eps = 0.01;

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

/// [logical] dp at pixel ratio 3, no insets.
void _surface(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewInsets = FakeViewPadding.zero;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewInsets();
  });
}

double _step(double v, int by) {
  final ByteData bytes = ByteData(8)..setFloat64(0, v);
  bytes.setInt64(0, bytes.getInt64(0) + by);
  return bytes.getFloat64(0);
}

double _nextUp(double v) => _step(v, 1);

double _nextDown(double v) => _step(v, -1);

/// The one place a chip is built for measuring.
Widget _chip(String line, {required bool compact}) =>
    SpeechChip(line: line, onTap: () {}, compact: compact);

List<String> _linesFor(List<String> ids, {required bool ar}) => <String>[
  for (final String id in ids) endLine(id, ar: ar),
];

/// The chips of decision 3 measured alone, one per line, normal and compact.
class _Alone {
  _Alone(this.normal, this.compact);

  final List<double> normal;
  final List<double> compact;

  double get n => _sum(normal) + kSpace2 * (normal.length - 1);

  double get c => _sum(compact) + kSpace1 * (compact.length - 1);

  static double _sum(List<double> v) =>
      v.fold(0.0, (double a, double b) => a + b);
}

enum _Branch { normal, compact, wrap }

/// Decision 3, as written.
_Branch _branchOf(_Alone alone, double w) {
  if (alone.n <= w) {
    return _Branch.normal;
  }
  if (alone.c <= w) {
    return _Branch.compact;
  }
  return _Branch.wrap;
}

/// Mounts each line as a SpeechChip with unbounded width, normal and compact,
/// in the given locale and scale, and reads the widths. Replaces whatever
/// tree is mounted.
Future<_Alone> _measure(
  WidgetTester tester,
  List<String> lines, {
  required Locale locale,
  required double textScale,
}) async {
  Widget row(String tag, int i, bool compact) => UnconstrainedBox(
    alignment: AlignmentDirectional.centerStart,
    child: KeyedSubtree(
      key: ValueKey<String>('alone-$tag-$i'),
      child: _chip(lines[i], compact: compact),
    ),
  );
  await tester.pumpWidget(
    rollTrayHarness(
      Scaffold(
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (int i = 0; i < lines.length; i++) row('n', i, false),
              for (int i = 0; i < lines.length; i++) row('c', i, true),
            ],
          ),
        ),
      ),
      locale: locale,
      textScale: textScale,
    ),
  );
  await tester.pump();
  double width(String tag, int i) =>
      tester.getSize(find.byKey(ValueKey<String>('alone-$tag-$i'))).width;
  return _Alone(
    <double>[for (int i = 0; i < lines.length; i++) width('n', i)],
    <double>[for (int i = 0; i < lines.length; i++) width('c', i)],
  );
}

/// An EndCard in an EndCardFrame, the way the finished body mounts it, laid
/// out [width] wide inside a [size] view.
Widget _cardTree({
  required Size size,
  double? width,
  EndKind kind = EndKind.loser,
  List<String>? replies,
  void Function(String id)? onReply,
  bool disabled = false,
  bool cooling = false,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) => rollTrayHarness(
  FeedbackScope(
    settings: FeedbackSettings.forTest(),
    service: RecordingFeedback(),
    child: Scaffold(
      body: Align(
        alignment: AlignmentDirectional.topStart,
        child: SizedBox(
          width: width ?? size.width,
          height: size.height,
          child: EndCardFrame(
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
              quickReplies: replies ?? _idsFor(kind),
              onQuickReply: disabled ? null : (onReply ?? (String id) {}),
              quickReplyCooling: cooling,
            ),
            trailing: const SizedBox(height: 300),
          ),
        ),
      ),
    ),
  ),
  locale: locale,
  textScale: textScale,
);

List<String> _idsFor(EndKind kind) => switch (kind) {
  EndKind.winner => kWinnerReplies,
  EndKind.loser => kLoserReplies,
  EndKind.ended => kEndedReplies,
};

Future<void> _pumpCard(WidgetTester tester, Widget tree) async {
  await tester.pumpWidget(tree);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The max width the keyed Wrap was laid out with.
double _widthGiven(WidgetTester tester) {
  final RenderObject ro = tester.renderObject(find.byKey(kQuickRepliesKey));
  return (ro as RenderBox).constraints.maxWidth;
}

String _f(double v) => v.toStringAsFixed(2);

String _nums(_Alone a, double w) =>
    'N=${_f(a.n)} (${a.normal.map(_f).join('+')}+${kSpace2}x${a.normal.length - 1}) '
    'C=${_f(a.c)} (${a.compact.map(_f).join('+')}+${kSpace1}x${a.compact.length - 1}) '
    'W=${_f(w)} -> ${_branchOf(a, w).name}';

/// Chip ids in reading order: row by row from the top, along the row in the
/// text direction.
List<String> _readingOrder(
  WidgetTester tester,
  List<String> ids,
  TextDirection dir,
) {
  final List<String> sorted = List<String>.of(ids);
  sorted.sort((String a, String b) {
    final Rect ra = tester.getRect(find.byKey(replyKey(a)));
    final Rect rb = tester.getRect(find.byKey(replyKey(b)));
    if ((ra.top - rb.top).abs() > 0.5) {
      return ra.top.compareTo(rb.top);
    }
    return dir == TextDirection.ltr
        ? ra.left.compareTo(rb.left)
        : rb.right.compareTo(ra.right);
  });
  return sorted;
}

/// Run lengths the greedy Wrap rule gives [widths] at [spacing] in [w].
List<int> _greedyRuns(List<double> widths, double spacing, double w) {
  final List<int> runs = <int>[];
  double used = 0;
  int count = 0;
  for (final double chip in widths) {
    if (count > 0 && used + spacing + chip > w + 0.001) {
      runs.add(count);
      used = 0;
      count = 0;
    }
    used += (count > 0 ? spacing : 0) + chip;
    count += 1;
  }
  if (count > 0) {
    runs.add(count);
  }
  return runs;
}

/// Checks the mounted row against decision 3 for the branch it computes from
/// [alone] and the width the Wrap was given. Returns the branch.
_Branch _expectRow(
  WidgetTester tester, {
  required String scenario,
  required List<String> ids,
  required _Alone alone,
  required Size size,
  required Locale locale,
  required double textScale,
  _Branch? mustBe,
}) {
  final double w = _widthGiven(tester);
  final _Branch branch = _branchOf(alone, w);
  final bool rtl = locale.languageCode == 'ar';
  final TextDirection dir = rtl ? TextDirection.rtl : TextDirection.ltr;
  final String head =
      '$scenario | ${size.width.toStringAsFixed(0)}x'
      '${size.height.toStringAsFixed(0)} dp ${locale.languageCode} '
      'x$textScale | ${_nums(alone, w)}';

  if (mustBe != null) {
    expect(
      branch,
      mustBe,
      reason:
          '$head | fixture: the measured chips must put this case in the '
          '${mustBe.name} branch',
    );
  }

  final double spacing = branch == _Branch.compact ? kSpace1 : kSpace2;
  final List<double> expectedWidths = branch == _Branch.compact
      ? alone.compact
      : alone.normal;
  final List<Rect> rects = <Rect>[
    for (final String id in ids) tester.getRect(find.byKey(replyKey(id))),
  ];
  final String got =
      'chips ${rects.map((Rect r) => '[${_f(r.left)}..${_f(r.right)} top ${_f(r.top)} h ${_f(r.height)}]').join(' ')}';
  if (branch != _Branch.wrap) {
    final bool oneTop = rects.every(
      (Rect r) => (r.top - rects.first.top).abs() <= 0.5,
    );
    expect(
      oneTop,
      isTrue,
      reason: '$head | one row in the ${branch.name} branch, $got',
    );
  }
  for (int i = 0; i < ids.length; i++) {
    expect(
      rects[i].width,
      closeTo(expectedWidths[i], _eps),
      reason:
          '$head | ${ids[i]} is ${branch == _Branch.compact ? 'compact' : 'normal'} '
          'width ${_f(expectedWidths[i])}, $got',
    );
    expect(
      rects[i].height,
      greaterThanOrEqualTo(48.0 - _eps),
      reason: '$head | ${ids[i]} is at least 48 dp tall, $got',
    );
    expect(
      rects[i].left,
      greaterThanOrEqualTo(-_eps),
      reason: '$head | ${ids[i]} starts inside the view, $got',
    );
    expect(
      rects[i].right,
      lessThanOrEqualTo(size.width + _eps),
      reason: '$head | ${ids[i]} ends inside the view, $got',
    );
  }

  final Map<int, List<String>> rows = <int, List<String>>{};
  final List<double> tops = <double>[];
  for (int i = 0; i < ids.length; i++) {
    final int row = tops.indexWhere(
      (double t) => (t - rects[i].top).abs() < 0.5,
    );
    if (row == -1) {
      tops.add(rects[i].top);
      rows[tops.length - 1] = <String>[ids[i]];
    } else {
      rows[row]!.add(ids[i]);
    }
  }

  if (branch == _Branch.wrap) {
    final List<String> order = _readingOrder(tester, ids, dir);
    expect(
      order,
      ids,
      reason: '$head | the wrapped chips read in the order handed in, $got',
    );
    final List<int> runs = <int>[
      for (final List<String> r in rows.values) r.length,
    ];
    final List<int> readingRuns = <int>[];
    final List<double> sortedTops = List<double>.of(tops)..sort();
    for (final double t in sortedTops) {
      readingRuns.add(
        ids
            .where(
              (String id) =>
                  (tester.getRect(find.byKey(replyKey(id))).top - t).abs() <
                  0.5,
            )
            .length,
      );
    }
    expect(
      readingRuns,
      _greedyRuns(alone.normal, kSpace2, w),
      reason:
          '$head | the wrap branch breaks runs where the next normal chip no '
          'longer fits (greedy, kSpace2), $got (runs by top: $runs)',
    );
    expect(
      sortedTops.length,
      greaterThan(1),
      reason: '$head | the wrap branch needs more than one row, $got',
    );
  } else {
    expect(
      tops.length,
      1,
      reason: '$head | one row in the ${branch.name} branch, $got',
    );
    expect(
      _readingOrder(tester, ids, dir),
      ids,
      reason:
          '$head | left to right (right to left in ar) in the order handed in, $got',
    );
    for (int i = 0; i + 1 < ids.length; i++) {
      final Rect a = rects[i];
      final Rect b = rects[i + 1];
      final double gap = rtl ? a.left - b.right : b.left - a.right;
      expect(
        gap,
        closeTo(spacing, _eps),
        reason:
            '$head | gap between ${ids[i]} and ${ids[i + 1]} is '
            '${spacing.toStringAsFixed(0)}, $got',
      );
    }
    final double left = rects
        .map((Rect r) => r.left)
        .reduce((double a, double b) => a < b ? a : b);
    final double right = rects
        .map((Rect r) => r.right)
        .reduce((double a, double b) => a > b ? a : b);
    final Rect box = tester.getRect(find.byKey(kQuickRepliesKey));
    expect(
      (left + right) / 2,
      closeTo((box.left + box.right) / 2, 0.5),
      reason:
          '$head | the row is centred in its Wrap ${box.left}..${box.right}, $got',
    );
  }
  final Widget wrap = tester.widget(find.byKey(kQuickRepliesKey));
  expect(
    wrap,
    isA<Wrap>(),
    reason:
        '$head | end-card-quick-replies is the Wrap itself, got ${wrap.runtimeType}',
  );
  final Wrap w0 = wrap as Wrap;
  expect(
    w0.spacing,
    spacing,
    reason: '$head | Wrap.spacing in the ${branch.name} branch',
  );
  expect(
    w0.runSpacing,
    kSpace2,
    reason: '$head | Wrap.runSpacing in the ${branch.name} branch',
  );
  expect(
    w0.alignment,
    WrapAlignment.center,
    reason: '$head | Wrap.alignment in the ${branch.name} branch',
  );
  expect(
    replyIds(tester),
    ids,
    reason: '$head | the chips are the ids handed in, in order',
  );

  return branch;
}

/// True when a hit test at the centre of [chip] reaches [chip]'s render
/// object or one below it.
bool _centreReaches(WidgetTester tester, Finder chip) {
  final RenderObject target = tester.renderObject(chip);
  final Offset at = tester.getCenter(chip);
  final HitTestResult result = HitTestResult();
  tester.binding.hitTestInView(result, at, tester.view.viewId);
  for (final HitTestEntry entry in result.path) {
    if (entry.target is! RenderObject) {
      continue;
    }
    RenderObject? r = entry.target as RenderObject;
    while (r != null) {
      if (identical(r, target)) {
        return true;
      }
      r = r.parent;
    }
  }
  return false;
}

String _chipsList(WidgetTester tester, List<String> ids) => ids
    .map((String id) => '$id ${tester.getRect(find.byKey(replyKey(id)))}')
    .join(', ');

/// Opens a finished loser game (a rematch ask docked when [ask]) on the
/// game screen at [size], measures the chips alone first.
Future<(EndGame, _Alone)> _openLoser(
  WidgetTester tester,
  String name, {
  required Size size,
  required bool ask,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  EndKind kind = EndKind.loser,
}) async {
  _surface(tester, size);
  final _Alone alone = await _measure(
    tester,
    _linesFor(_idsFor(kind), ar: locale.languageCode == 'ar'),
    locale: locale,
    textScale: textScale,
  );
  final EndGame g = await openFinished(
    tester,
    name,
    kind: kind,
    locale: locale,
    textScale: textScale,
    size: size,
    names: <int, String>{1: 'Priya'},
  );
  _surface(tester, size);
  await tester.pump();
  if (ask) {
    await g.rematchLobby(by: 1);
    await g.s.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(_askKey),
      findsOneWidget,
      reason: g.why('fixture: the rematch ask is docked'),
    );
  }
  return (g, alone);
}

void main() {
  setUpAll(_loadAppFonts);

  // -------------------------------------------------------------------
  // The loser's three at 360 x 616: the frame 23 case.
  // -------------------------------------------------------------------
  group('loser, 360 x 616, en 1.0', () {
    testWidgets('direct: the compact branch, one row, gap kSpace1', (
      tester,
    ) async {
      _surface(tester, _phone);
      final List<String> ids = kLoserReplies;
      final _Alone alone = await _measure(
        tester,
        _linesFor(ids, ar: false),
        locale: const Locale('en'),
        textScale: 1.0,
      );
      await _pumpCard(tester, _cardTree(size: _phone));
      _expectRow(
        tester,
        scenario: 'direct loser 360x616',
        ids: ids,
        alone: alone,
        size: _phone,
        locale: const Locale('en'),
        textScale: 1.0,
        mustBe: _Branch.compact,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('direct: every chip is its own width, the same top, the '
        'compact padding is 2 x kSpace1 narrower than the normal', (
      tester,
    ) async {
      _surface(tester, _phone);
      final List<String> ids = kLoserReplies;
      final _Alone alone = await _measure(
        tester,
        _linesFor(ids, ar: false),
        locale: const Locale('en'),
        textScale: 1.0,
      );
      for (int i = 0; i < ids.length; i++) {
        expect(
          alone.normal[i] - alone.compact[i],
          closeTo(2 * kSpace1, _eps),
          reason:
              'compact chip ${ids[i]}: start and end padding kSpace2 instead '
              'of kSpace3 narrows the chip by ${2 * kSpace1}; normal '
              '${_f(alone.normal[i])} compact ${_f(alone.compact[i])}',
        );
      }
    });

    testWidgets('game screen, no ask: the same row', (tester) async {
      final (EndGame g, _Alone alone) = await _openLoser(
        tester,
        'game screen loser 360x616 no ask',
        size: _phone,
        ask: false,
      );
      try {
        final double w = _widthGiven(tester);
        expect(
          w,
          _phone.width - 2 * kSpace4,
          reason: g.why(
            'the chips get the view less the scroll\'s two kSpace4, '
            'got ${_f(w)}',
          ),
        );
        _expectRow(
          tester,
          scenario: g.s.name,
          ids: kLoserReplies,
          alone: alone,
          size: _phone,
          locale: const Locale('en'),
          textScale: 1.0,
          mustBe: _Branch.compact,
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('game screen, rematch ask docked: the same row', (
      tester,
    ) async {
      final (EndGame g, _Alone alone) = await _openLoser(
        tester,
        'game screen loser 360x616 rematch ask',
        size: _phone,
        ask: true,
      );
      try {
        _expectRow(
          tester,
          scenario: g.s.name,
          ids: kLoserReplies,
          alone: alone,
          size: _phone,
          locale: const Locale('en'),
          textScale: 1.0,
          mustBe: _Branch.compact,
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('game screen, rematch ask docked: every chip above the ask '
        'and every centre reaches its chip', (tester) async {
      final (EndGame g, _) = await _openLoser(
        tester,
        'game screen loser 360x616 rematch ask clear',
        size: _phone,
        ask: true,
      );
      try {
        final Finder scrollable = find.ancestor(
          of: find.byKey(kQuickRepliesKey),
          matching: find.byType(Scrollable),
        );
        expect(
          scrollable,
          findsWidgets,
          reason: g.why('fixture: the chips sit in a scroll'),
        );
        final ScrollableState scroll = tester.state<ScrollableState>(
          scrollable.first,
        );
        expect(
          scroll.position.pixels,
          0.0,
          reason: g.why('fixture: the scroll is at its start'),
        );
        final double askTop = tester.getRect(find.byKey(_askKey)).top;
        for (final String id in kLoserReplies) {
          final Rect r = tester.getRect(find.byKey(replyKey(id)));
          expect(
            r.bottom,
            lessThanOrEqualTo(askTop + _eps),
            reason: g.why(
              'chip $id bottom ${_f(r.bottom)} is above the top of '
              'end-card-rematch-ask ${_f(askTop)} with the scroll at 0 '
              '(${_chipsList(tester, kLoserReplies)})',
            ),
          );
          final Rect port = tester.getRect(scrollable.first);
          expect(
            r.bottom,
            lessThanOrEqualTo(port.bottom + _eps),
            reason: g.why(
              'chip $id bottom ${_f(r.bottom)} is inside the scroll viewport '
              '${port.top}..${port.bottom}, not cut at its lower edge (the '
              'dock sits below the viewport, so a chip past it is clipped '
              'and needs a scroll first), ask top ${_f(askTop)}',
            ),
          );
          expect(
            _centreReaches(tester, find.byKey(replyKey(id))),
            isTrue,
            reason: g.why(
              'a hit test at the centre of chip $id ${tester.getCenter(find.byKey(replyKey(id)))} '
              'reaches that chip, ask top ${_f(askTop)}',
            ),
          );
        }
      } finally {
        await g.done();
      }
    });

    for (final String id in kLoserReplies) {
      testWidgets('game screen, rematch ask docked: a tap on $id sends '
          'its emote with no scroll', (tester) async {
        final (EndGame g, _) = await _openLoser(
          tester,
          'game screen loser 360x616 rematch ask tap $id',
          size: _phone,
          ask: true,
        );
        try {
          final int before = g.sentCount;
          g.s.steps.add('tap end-card-reply-$id at its centre, no scroll');
          await tester.tap(find.byKey(replyKey(id)));
          await tester.pump();
          await g.s.pump(const Duration(milliseconds: 100));
          expect(
            g.emotesSent(before).map((Map<String, Object?> f) => f['d']),
            <Object?>[
              <String, Object?>{'emote': id},
            ],
            reason: g.why(
              'one emote $id goes out from the tap (chips '
              '${_chipsList(tester, kLoserReplies)})',
            ),
          );
        } finally {
          await g.done();
        }
      });
    }
  });

  // -------------------------------------------------------------------
  // Other widths, locales and scales.
  // -------------------------------------------------------------------
  group('the other branches', () {
    testWidgets('loser at 411 dp en: the normal branch, gap kSpace2', (
      tester,
    ) async {
      const Size size = Size(411, 616);
      final (EndGame g, _Alone alone) = await _openLoser(
        tester,
        'game screen loser 411x616 no ask',
        size: size,
        ask: false,
      );
      try {
        _expectRow(
          tester,
          scenario: g.s.name,
          ids: kLoserReplies,
          alone: alone,
          size: size,
          locale: const Locale('en'),
          textScale: 1.0,
          mustBe: _Branch.normal,
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('loser at 411 dp en, direct: the normal branch', (
      tester,
    ) async {
      const Size size = Size(411, 616);
      _surface(tester, size);
      final _Alone alone = await _measure(
        tester,
        _linesFor(kLoserReplies, ar: false),
        locale: const Locale('en'),
        textScale: 1.0,
      );
      await _pumpCard(tester, _cardTree(size: size));
      _expectRow(
        tester,
        scenario: 'direct loser 411x616',
        ids: kLoserReplies,
        alone: alone,
        size: size,
        locale: const Locale('en'),
        textScale: 1.0,
        mustBe: _Branch.normal,
      );
    });

    testWidgets('loser at 360 dp ar: whatever the measured branch says, '
        'one row, the first chip on the right', (tester) async {
      const Locale ar = Locale('ar');
      _surface(tester, _phone);
      final _Alone alone = await _measure(
        tester,
        _linesFor(kLoserReplies, ar: true),
        locale: ar,
        textScale: 1.0,
      );
      await _pumpCard(tester, _cardTree(size: _phone, locale: ar));
      final _Branch branch = _expectRow(
        tester,
        scenario: 'direct loser 360x616 ar',
        ids: kLoserReplies,
        alone: alone,
        size: _phone,
        locale: ar,
        textScale: 1.0,
      );
      expect(
        branch,
        isNot(_Branch.wrap),
        reason:
            'direct loser 360x616 ar | frame 22 fits one row, measured '
            '${_nums(alone, _widthGiven(tester))}',
      );
      expect(
        Directionality.of(tester.element(find.byKey(kQuickRepliesKey))),
        TextDirection.rtl,
        reason: 'direct loser 360x616 ar | the row is right to left',
      );
      expect(
        tester.getRect(find.byKey(replyKey(kLoserReplies.first))).right,
        greaterThan(
          tester.getRect(find.byKey(replyKey(kLoserReplies.last))).right,
        ),
        reason:
            'direct loser 360x616 ar | the first chip is on the right: '
            '${_chipsList(tester, kLoserReplies)}',
      );
    });

    testWidgets('loser at 360 dp ar on the game screen with the ask: one '
        'row above the ask', (tester) async {
      const Locale ar = Locale('ar');
      final (EndGame g, _Alone alone) = await _openLoser(
        tester,
        'game screen loser 360x616 ar rematch ask',
        size: _phone,
        ask: true,
        locale: ar,
      );
      try {
        final _Branch branch = _expectRow(
          tester,
          scenario: g.s.name,
          ids: kLoserReplies,
          alone: alone,
          size: _phone,
          locale: ar,
          textScale: 1.0,
        );
        expect(
          branch,
          isNot(_Branch.wrap),
          reason: g.why(
            'frame 22 fits one row, ${_nums(alone, _widthGiven(tester))}',
          ),
        );
        final double askTop = tester.getRect(find.byKey(_askKey)).top;
        for (final String id in kLoserReplies) {
          expect(
            tester.getRect(find.byKey(replyKey(id))).bottom,
            lessThanOrEqualTo(askTop + _eps),
            reason: g.why(
              'ar chip $id is above the ask top ${_f(askTop)}: '
              '${_chipsList(tester, kLoserReplies)}',
            ),
          );
        }
      } finally {
        await g.done();
      }
    });

    testWidgets('loser at 360 dp en 1.3 text: the wrap branch, normal '
        'chips, more than one row', (tester) async {
      _surface(tester, _phone);
      final _Alone alone = await _measure(
        tester,
        _linesFor(kLoserReplies, ar: false),
        locale: const Locale('en'),
        textScale: 1.3,
      );
      await _pumpCard(tester, _cardTree(size: _phone, textScale: 1.3));
      _expectRow(
        tester,
        scenario: 'direct loser 360x616 1.3x text',
        ids: kLoserReplies,
        alone: alone,
        size: _phone,
        locale: const Locale('en'),
        textScale: 1.3,
        mustBe: _Branch.wrap,
      );
      expect(tester.takeException(), isNull);
    });

    for (final (String, Size, Locale) c in <(String, Size, Locale)>[
      ('360 en', _phone, const Locale('en')),
      ('411 en', const Size(411, 616), const Locale('en')),
      ('360 ar', _phone, const Locale('ar')),
    ]) {
      for (final EndKind kind in const <EndKind>[
        EndKind.winner,
        EndKind.ended,
      ]) {
        testWidgets('${kind.name} at ${c.$1}: never compact while N <= W', (
          tester,
        ) async {
          final bool ar = c.$3.languageCode == 'ar';
          _surface(tester, c.$2);
          final _Alone alone = await _measure(
            tester,
            _linesFor(_idsFor(kind), ar: ar),
            locale: c.$3,
            textScale: 1.0,
          );
          await _pumpCard(
            tester,
            _cardTree(size: c.$2, kind: kind, locale: c.$3),
          );
          _expectRow(
            tester,
            scenario: 'direct ${kind.name} ${c.$1}',
            ids: _idsFor(kind),
            alone: alone,
            size: c.$2,
            locale: c.$3,
            textScale: 1.0,
            mustBe: _Branch.normal,
          );
        });
      }
    }
  });

  // -------------------------------------------------------------------
  // The thresholds, one dp either side. W is set through the width of the
  // frame, and read back from the Wrap before the branch is computed.
  // -------------------------------------------------------------------
  group('the thresholds of decision 3', () {
    Future<void> at(
      WidgetTester tester, {
      required String name,
      required double Function(_Alone) target,
      required double delta,
      required _Branch expected,
    }) async {
      // A view wider than any target, or the frame is clamped to it.
      const Size view = Size(500, 616);
      _surface(tester, view);
      final _Alone alone = await _measure(
        tester,
        _linesFor(kLoserReplies, ar: false),
        locale: const Locale('en'),
        textScale: 1.0,
      );
      // The frame takes some padding off the width it is given; find how
      // much with a probe, then ask for the width that leaves exactly the
      // target. Float noise is walked off by a few ulps.
      await _pumpCard(tester, _cardTree(size: view, width: 360));
      final double pad = 360 - _widthGiven(tester);
      final double want = target(alone) + delta;
      double got = double.nan;
      double width = want + pad;
      for (int i = 0; i < 8 && got != want; i++) {
        await _pumpCard(tester, _cardTree(size: view, width: width));
        got = _widthGiven(tester);
        if (got < want) {
          width = _nextUp(width);
        } else if (got > want) {
          width = _nextDown(width);
        }
      }
      expect(
        got,
        want,
        reason:
            '$name | fixture: the Wrap was given ${got.toStringAsFixed(6)}, '
            'wanted ${want.toStringAsFixed(6)} (frame width $width, pad $pad)',
      );
      _expectRow(
        tester,
        scenario: name,
        ids: kLoserReplies,
        alone: alone,
        size: Size(width, _phone.height),
        locale: const Locale('en'),
        textScale: 1.0,
        mustBe: expected,
      );
    }

    testWidgets('W == N exactly: normal', (tester) async {
      await at(
        tester,
        name: 'W == N',
        target: (_Alone a) => a.n,
        delta: 0,
        expected: _Branch.normal,
      );
    });

    testWidgets('W == N - 1: compact', (tester) async {
      await at(
        tester,
        name: 'W == N - 1',
        target: (_Alone a) => a.n,
        delta: -1,
        expected: _Branch.compact,
      );
    });

    testWidgets('W == N + 1: normal', (tester) async {
      await at(
        tester,
        name: 'W == N + 1',
        target: (_Alone a) => a.n,
        delta: 1,
        expected: _Branch.normal,
      );
    });

    testWidgets('W == C exactly: compact', (tester) async {
      await at(
        tester,
        name: 'W == C',
        target: (_Alone a) => a.c,
        delta: 0,
        expected: _Branch.compact,
      );
    });

    testWidgets('W == C - 1: wrap', (tester) async {
      await at(
        tester,
        name: 'W == C - 1',
        target: (_Alone a) => a.c,
        delta: -1,
        expected: _Branch.wrap,
      );
    });
  });

  // -------------------------------------------------------------------
  // The chips are still the same chips in every branch.
  // -------------------------------------------------------------------
  group('behaviour does not depend on the branch', () {
    for (final (String, Size, double) c in <(String, Size, double)>[
      ('compact 360', _phone, 1.0),
      ('normal 411', const Size(411, 616), 1.0),
      ('wrap 360 1.3x', _phone, 1.3),
    ]) {
      testWidgets('${c.$1}: each chip calls onQuickReply once with its id', (
        tester,
      ) async {
        _surface(tester, c.$2);
        final List<String> calls = <String>[];
        await _pumpCard(
          tester,
          _cardTree(size: c.$2, textScale: c.$3, onReply: calls.add),
        );
        for (final String id in kLoserReplies) {
          calls.clear();
          await tester.ensureVisible(find.byKey(replyKey(id)));
          await tester.tap(find.byKey(replyKey(id)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            calls,
            <String>[id],
            reason:
                '${c.$1} (${c.$2.width.toStringAsFixed(0)} dp, ${c.$3}x): a '
                'tap on $id calls once with $id, got $calls',
          );
        }
      });
    }

    for (final (String, bool, bool) c in <(String, bool, bool)>[
      ('cooling', true, false),
      ('disabled', false, true),
    ]) {
      testWidgets('${c.$1}: same branch and same geometry as ready', (
        tester,
      ) async {
        _surface(tester, _phone);
        final _Alone alone = await _measure(
          tester,
          _linesFor(kLoserReplies, ar: false),
          locale: const Locale('en'),
          textScale: 1.0,
        );
        await _pumpCard(tester, _cardTree(size: _phone));
        final List<Rect> ready = <Rect>[
          for (final String id in kLoserReplies)
            tester.getRect(find.byKey(replyKey(id))),
        ];
        await _pumpCard(
          tester,
          _cardTree(size: _phone, cooling: c.$2, disabled: c.$3),
        );
        _expectRow(
          tester,
          scenario: 'direct loser 360x616 ${c.$1}',
          ids: kLoserReplies,
          alone: alone,
          size: _phone,
          locale: const Locale('en'),
          textScale: 1.0,
          mustBe: _Branch.compact,
        );
        final List<Rect> now = <Rect>[
          for (final String id in kLoserReplies)
            tester.getRect(find.byKey(replyKey(id))),
        ];
        expect(
          now,
          ready,
          reason:
              'direct loser 360x616 ${c.$1} | the chips do not move or '
              'resize between ready $ready and ${c.$1} $now',
        );
      });
    }
  });

  // -------------------------------------------------------------------
  // The quick messages sheet never sets the flag.
  // -------------------------------------------------------------------
  group('the quick messages sheet', () {
    for (final (String, Locale) c in <(String, Locale)>[
      ('en', const Locale('en')),
      ('ar', const Locale('ar')),
    ]) {
      testWidgets('${c.$1}: its chips keep the normal padding', (tester) async {
        _surface(tester, _phone);
        final EndGame g = await openPlaying(
          tester,
          'sheet chips ${c.$1} 360x616',
          locale: c.$2,
          size: _phone,
        );
        _surface(tester, _phone);
        try {
          g.s.steps.add('open the quick messages sheet');
          await tester.tap(find.byKey(kChatButtonKey));
          await tester.pump();
          await g.s.pump(const Duration(milliseconds: 400));
          expect(
            find.byKey(kSheetKey),
            findsOneWidget,
            reason: g.why('fixture: the sheet is open'),
          );
          final List<Element> chips = find
              .byWidgetPredicate((Widget w) {
                final Key? key = w.key;
                return key is ValueKey<String> &&
                    key.value.startsWith('quick-chat-') &&
                    key.value != 'quick-chat-sheet' &&
                    key.value != 'quick-chat-mute';
              })
              .evaluate()
              .toList();
          expect(
            chips,
            isNotEmpty,
            reason: g.why('fixture: the sheet has preset chips'),
          );
          final List<String> lines = <String>[];
          final List<double> widths = <double>[];
          for (final Element e in chips) {
            final Finder f = find.byWidget(e.widget);
            lines.add(textUnder(tester, f));
            widths.add(tester.getSize(f).width);
          }
          final _Alone alone = await _measure(
            tester,
            lines,
            locale: c.$2,
            textScale: 1.0,
          );
          for (int i = 0; i < lines.length; i++) {
            expect(
              widths[i],
              closeTo(alone.normal[i], _eps),
              reason: g.why(
                'sheet chip "${lines[i]}" is ${_f(widths[i])} wide, the '
                'normal chip measured alone is ${_f(alone.normal[i])} '
                '(compact would be ${_f(alone.compact[i])})',
              ),
            );
          }
        } finally {
          await g.done();
        }
      });
    }
  });
}
