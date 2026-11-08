// C-591, order 591t. Proves the contract of work/ludo/orders/591-rematch-
// start-warning.md (D1 to D4) on EndCard itself: the seat that is not in yet
// is told, above Play again, that the next game can start without it (key
// end-card-rematch-may-start); the host who can start now is told, above the
// Start-with-N button, who will be left out (key end-card-rematch-sits-out);
// neither line shows anywhere else.
//
// Written from the contract, not from the implementation. The harness is the
// one of test/end_card_ready_row_test.dart (same EndCard construction, same
// RematchState, same fonts, same one bounded celebration pump); the opacity
// reader is the one of test/c555_test.dart.
//
// This file does not compile on a tree without the optional EndCard.hostSeat
// parameter of D1: every case that passes hostSeat is a compile error there,
// which is the whole file. The expected texts are written out here from the
// contract's wording ("The next game can start without you", "Not in the next
// game: {names}" and the Arabic pair) and, in the cases that read it, also
// compared with the generated getter, so a wrong arb entry and a wrong card
// are told apart.
//
// Points the contract leaves open, and what this file does about them:
//
//   1. Which widget carries the key. The tests read the text from the keyed
//      widget or from the one Text under it, the rect from the keyed widget,
//      and look for the live region on the keyed widget, above it, or below
//      it.
//   2. "Body style with FontWeight.w600, colour stays the theme's, no red":
//      the file asserts w600 on the painted text and that the colour is
//      neither the theme's error colour nor red-dominant. It does not pin a
//      font size, the contract names none.
//   3. "Centred": the keyed rect's centre is the Play again button's centre,
//      and a line as wide as the card must also say TextAlign.center.
//
// Every case is deterministic (no timers beyond the one bounded celebration
// pump, no randomness); the scenario label in each failure message is the
// whole recipe to reproduce it.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RematchState;
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace2, kSpace4;

const Key _mayStartKey = Key('end-card-rematch-may-start');
const Key _sitsOutKey = Key('end-card-rematch-sits-out');
const Key _playAgainKey = Key('end-card-rematch');
const Key _startKey = Key('end-card-rematch-start');
const Key _askKey = Key('end-card-rematch-ask');
const Key _newTableKey = Key('game-screen-new-room-button');

const String _mayStartEn = 'The next game can start without you';
const String _mayStartAr = 'قد تبدأ الجولة التالية دونك';

const GameStats _stats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: true,
);

const Map<int, String> _names4 = <int, String>{
  0: 'Ana',
  1: 'Bilal',
  2: 'Carla',
  3: 'Dmitri',
};

const Map<int, String> _namesAr = <int, String>{
  0: 'ليلى',
  1: 'كريم',
  2: 'سامي',
  3: 'نادين',
};

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
  final FontLoader arabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    arabic.addFont(rootBundle.load(asset));
  }
  await arabic.load();
}

/// Counts what the card's callbacks were asked to do.
class _Taps {
  int rematch = 0;
  int start = 0;
}

/// One end card scenario. [ready] non-null puts a rematch lobby on the card.
class _Scenario {
  const _Scenario({
    required this.label,
    required this.occupied,
    required this.mySeat,
    this.hostSeat,
    this.ready,
    this.names = _names4,
    this.isHost = false,
    this.rematchByDeparted = false,
    this.rematchGone = false,
    this.everyoneLeft = false,
    this.isOffline = false,
    this.locale = const Locale('en'),
    this.textScale = 1.0,
    this.width = 390,
    this.height = 4000,
  });

  final String label;
  final List<int> occupied;
  final int mySeat;
  final int? hostSeat;
  final List<int>? ready;
  final Map<int, String> names;
  final bool isHost;
  final bool rematchByDeparted;
  final bool rematchGone;
  final bool everyoneLeft;
  final bool isOffline;
  final Locale locale;
  final double textScale;
  final double width;
  final double height;

  bool get isAr => locale.languageCode == 'ar';

  String get mayStartText => isAr ? _mayStartAr : _mayStartEn;

  Widget card(_Taps taps, {List<int>? readyOverride}) {
    final List<int>? r = readyOverride ?? ready;
    return EndCard(
      mySeat: mySeat,
      winnerSeat: (mySeat + 1) % 4,
      winnerName: 'Winner',
      seatColors: LudoColors.seats,
      stats: _stats,
      verifyUrl: 'https://rematch-start-warning.invalid/verify',
      onVerify: () {},
      onNewTable: () {},
      rematch: r == null ? null : RematchState(by: 0, ready: r),
      rematchByName: r == null || rematchByDeparted
          ? null
          : (names[0] ?? 'Starter'),
      rematchByDeparted: rematchByDeparted,
      occupiedSeats: occupied,
      rematchGone: rematchGone,
      everyoneLeft: everyoneLeft,
      isOffline: isOffline,
      isHost: isHost,
      hostSeat: hostSeat,
      onRematch: () => taps.rematch++,
      onStartReady: isHost ? () => taps.start++ : null,
      seatNames: names,
    );
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Scenario s,
  _Taps taps, {
  ValueListenable<List<int>?>? readyFeed,
}) async {
  tester.view.physicalSize = Size(s.width, s.height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final Widget body = readyFeed == null
      ? s.card(taps)
      : ValueListenableBuilder<List<int>?>(
          valueListenable: readyFeed,
          builder: (BuildContext context, List<int>? value, Widget? _) =>
              s.card(taps, readyOverride: value),
        );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      locale: s.locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(textScaler: TextScaler.linear(s.textScale)),
          child: child!,
        );
      },
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(kSpace4),
          child: body,
        ),
      ),
    ),
  );
  await tester.pump();
  // The celebration runs 1200 ms; one bounded pump plays it out.
  await tester.pump(const Duration(milliseconds: 1200));
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold)));

/// The painted text of the line behind [key]: the keyed widget itself or the
/// one Text under it.
String _textOf(WidgetTester tester, Key key, String label) {
  final Finder texts = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Text),
    matchRoot: true,
  );
  expect(
    texts,
    findsOneWidget,
    reason: '$label: expected exactly one Text at or under $key',
  );
  final Text t = tester.widget<Text>(texts);
  return t.data ?? t.textSpan?.toPlainText() ?? '';
}

void _expectAbsent(WidgetTester tester, Key key, _Scenario s) {
  expect(
    find.byKey(key),
    findsNothing,
    reason:
        '${s.label}: expected no $key (the contract shows it only in its own '
        'condition), but it is on the card',
  );
  expect(
    tester.takeException(),
    isNull,
    reason: '${s.label}: the card must build without an exception',
  );
}

void _expectDirectlyAbove(
  WidgetTester tester,
  Key line,
  Key button,
  _Scenario s,
) {
  final Rect l = tester.getRect(find.byKey(line));
  final Rect b = tester.getRect(find.byKey(button));
  expect(
    l.bottom,
    lessThanOrEqualTo(b.top + 0.5),
    reason:
        '${s.label}: $line must sit above $button; line=$l button=$b '
        '(bottom ${l.bottom} is not above top ${b.top})',
  );
  expect(
    b.top - l.bottom,
    closeTo(kSpace2, 0.5),
    reason:
        '${s.label}: expected kSpace2 ($kSpace2 dp) between $line and '
        '$button, found ${b.top - l.bottom}; line=$l button=$b',
  );
}

void _expectCentred(WidgetTester tester, Key line, Key button, _Scenario s) {
  final Rect l = tester.getRect(find.byKey(line));
  final Rect b = tester.getRect(find.byKey(button));
  expect(
    (l.center.dx - b.center.dx).abs(),
    lessThanOrEqualTo(1.0),
    reason:
        '${s.label}: $line must be centred on the card; line centre '
        '${l.center.dx}, button centre ${b.center.dx}',
  );
  if (l.width >= b.width - 1) {
    final Finder texts = find.descendant(
      of: find.byKey(line),
      matching: find.byType(Text),
      matchRoot: true,
    );
    expect(
      tester.widget<Text>(texts).textAlign,
      TextAlign.center,
      reason:
          '${s.label}: $line is as wide as the card, so its text must be '
          'aligned to the centre',
    );
  }
}

Finder _liveRegion() => find.byWidgetPredicate(
  (Widget w) => w is Semantics && w.properties.liveRegion == true,
);

bool _hasLiveRegion(Finder line) {
  return find
          .ancestor(of: line, matching: _liveRegion(), matchRoot: true)
          .evaluate()
          .isNotEmpty ||
      find.descendant(of: line, matching: _liveRegion()).evaluate().isNotEmpty;
}

// --- opacity, measured (the reader of test/c555_test.dart) ------------------

double _selfFactor(RenderObject node) {
  if (node is RenderOpacity) {
    return node.opacity;
  }
  if (node is RenderAnimatedOpacity) {
    return node.opacity.value;
  }
  return 1.0;
}

double _lowestBelow(RenderObject node, double above) {
  final double here = above * _selfFactor(node);
  double lowest = here;
  node.visitChildren((RenderObject child) {
    lowest = math.min(lowest, _lowestBelow(child, here));
  });
  return lowest;
}

/// How visible [finder] is: every opacity above it times the lowest product
/// below it. 1.0 is fully drawn.
double _opacityOf(WidgetTester tester, Finder finder) {
  final RenderObject node = tester.renderObject(finder);
  double above = 1.0;
  RenderObject? up = node.parent;
  while (up != null) {
    above *= _selfFactor(up);
    up = up.parent;
  }
  return _lowestBelow(node, above);
}

// --- the scenarios ----------------------------------------------------------

/// The (a) setup: three occupied, host 0, me 2 not ready, ready [0,1].
_Scenario _a({
  String label = 'a: seats [0,1,2], host 0, me 2, ready [0,1], ask path',
  int? hostSeat = 0,
  List<int> ready = const <int>[0, 1],
  List<int> occupied = const <int>[0, 1, 2],
  int mySeat = 2,
  bool rematchByDeparted = false,
  bool rematchGone = false,
  bool everyoneLeft = false,
  bool isOffline = false,
  Locale locale = const Locale('en'),
  Map<int, String> names = _names4,
  double textScale = 1.0,
  double width = 390,
  double height = 4000,
}) {
  return _Scenario(
    label: label,
    occupied: occupied,
    mySeat: mySeat,
    hostSeat: hostSeat,
    ready: ready,
    names: names,
    rematchByDeparted: rematchByDeparted,
    rematchGone: rematchGone,
    everyoneLeft: everyoneLeft,
    isOffline: isOffline,
    locale: locale,
    textScale: textScale,
    width: width,
    height: height,
  );
}

/// The (g) setup: four occupied, host 0 = me, ready [0,2].
_Scenario _g({
  String label = 'g: seats [0,1,2,3], host 0 = me, ready [0,2]',
  List<int> occupied = const <int>[0, 1, 2, 3],
  List<int> ready = const <int>[0, 2],
  Map<int, String> names = _names4,
  bool isHost = true,
  int? hostSeat = 0,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  double width = 390,
  double height = 4000,
}) {
  return _Scenario(
    label: label,
    occupied: occupied,
    mySeat: 0,
    hostSeat: hostSeat,
    ready: ready,
    names: names,
    isHost: isHost,
    locale: locale,
    textScale: textScale,
    width: width,
    height: height,
  );
}

void main() {
  setUpAll(_loadAppFonts);

  group('(a) the seat that is not in yet is warned, ask path', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(),
      _a(
        label: 'a: seats [0,1,2,3], host 0, me 3, ready [0,1,2], 3 of 4 in',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 3,
        ready: const <int>[0, 1, 2],
      ),
      _a(
        label: 'a: seats [1,2,3], host 3, me 1, ready [3,2] (host not seat 0)',
        occupied: const <int>[1, 2, 3],
        mySeat: 1,
        hostSeat: 3,
        ready: const <int>[3, 2],
      ),
      _a(
        label: 'a: ar, seats [0,1,2], host 0, me 2, ready [0,1]',
        locale: const Locale('ar'),
        names: _namesAr,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        final _Taps taps = _Taps();
        await _mount(tester, s, taps);
        expect(
          find.byKey(_askKey),
          findsOneWidget,
          reason: '${s.label}: fixture: the ask path shows the ask line',
        );
        expect(
          find.byKey(_mayStartKey),
          findsOneWidget,
          reason:
              '${s.label}: expected end-card-rematch-may-start (host '
              '${s.hostSeat} is in ready ${s.ready}, ${s.ready!.length} '
              'ready), found none',
        );
        expect(_textOf(tester, _mayStartKey, s.label), s.mayStartText);
        expect(
          _textOf(tester, _mayStartKey, s.label),
          _loc(tester).endRematchMayStartWithout,
          reason: '${s.label}: the line reads endRematchMayStartWithout',
        );
        _expectDirectlyAbove(tester, _mayStartKey, _playAgainKey, s);
        _expectCentred(tester, _mayStartKey, _playAgainKey, s);

        // Play again stays the primary action, above New table.
        final Rect play = tester.getRect(find.byKey(_playAgainKey));
        final Rect newTable = tester.getRect(find.byKey(_newTableKey));
        expect(
          newTable.top,
          greaterThanOrEqualTo(play.bottom - 0.5),
          reason:
              '${s.label}: Play again must stay above New table; '
              'play=$play newTable=$newTable',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${s.label}: no exception',
        );
      });
    }
  });

  group('(b) the same on the hideAsk path', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(
        label: 'b: seats [0,1,2], host 0, me 2, ready [0,1], rematchByDeparted',
        rematchByDeparted: true,
      ),
      _a(
        label:
            'b: ar, seats [0,1,2], host 0, me 2, ready [0,1], '
            'rematchByDeparted',
        rematchByDeparted: true,
        locale: const Locale('ar'),
        names: _namesAr,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        expect(
          find.byKey(_askKey),
          findsNothing,
          reason: '${s.label}: fixture: the hideAsk path has no ask line',
        );
        expect(
          find.byKey(_mayStartKey),
          findsOneWidget,
          reason:
              '${s.label}: expected end-card-rematch-may-start on the '
              'hideAsk path too, found none',
        );
        expect(_textOf(tester, _mayStartKey, s.label), s.mayStartText);
        _expectDirectlyAbove(tester, _mayStartKey, _playAgainKey, s);
        _expectCentred(tester, _mayStartKey, _playAgainKey, s);
      });
    }
  });

  group('(c) host not ready: absent', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(
        label: 'c: seats [0,1,2,3], host 0 not ready, me 3, ready [1,2]',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 3,
        ready: const <int>[1, 2],
      ),
      _a(
        label: 'c: same, hideAsk path',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 3,
        ready: const <int>[1, 2],
        rematchByDeparted: true,
      ),
      _a(
        label:
            'c: seats [0,1,2], host 0 not ready, me 2, ready [1,3] '
            '(a ready seat that is not seated)',
        ready: const <int>[1, 3],
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        _expectAbsent(tester, _mayStartKey, s);
        expect(
          find.byKey(_playAgainKey),
          findsOneWidget,
          reason: '${s.label}: Play again is still there',
        );
      });
    }
  });

  group('(d) only the host ready: absent', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(
        label: 'd: seats [0,1,2], host 0, me 2, ready [0]',
        ready: const <int>[0],
      ),
      _a(
        label: 'd: same, hideAsk path',
        ready: const <int>[0],
        rematchByDeparted: true,
      ),
      _a(
        label: 'd: two seats [0,1], host 0, me 1, ready [0]',
        occupied: const <int>[0, 1],
        mySeat: 1,
        ready: const <int>[0],
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        _expectAbsent(tester, _mayStartKey, s);
      });
    }
  });

  group('(e) hostSeat omitted: absent, every branch as today', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(label: 'e: the (a) setup with hostSeat null', hostSeat: null),
      _a(
        label: 'e: the (b) setup with hostSeat null',
        hostSeat: null,
        rematchByDeparted: true,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        _expectAbsent(tester, _mayStartKey, s);
        expect(
          find.byKey(_playAgainKey),
          findsOneWidget,
          reason: '${s.label}: Play again is still there',
        );
        final Rect play = tester.getRect(find.byKey(_playAgainKey));
        final Rect newTable = tester.getRect(find.byKey(_newTableKey));
        expect(
          newTable.top - play.bottom,
          closeTo(kSpace2, 0.5),
          reason:
              '${s.label}: with hostSeat null New table sits kSpace2 under '
              'Play again as today; play=$play newTable=$newTable',
        );
      });
    }
  });

  group('(f) I am ready: the waiting branch has no may-start line', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(
        label: 'f: seats [0,1,2], host 0, me 2 ready, ready [0,2], not host',
        ready: const <int>[0, 2],
      ),
      _a(
        label: 'f: seats [0,1,2], host 0, me 2 ready, ready [0,1,2]',
        ready: const <int>[0, 1, 2],
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        expect(
          find.byKey(const Key('end-card-rematch-waiting')),
          findsOneWidget,
          reason: '${s.label}: fixture: the waiting branch is up',
        );
        _expectAbsent(tester, _mayStartKey, s);
        _expectAbsent(tester, _sitsOutKey, s);
        expect(
          find.byKey(_startKey),
          findsNothing,
          reason: '${s.label}: a non-host never gets Start',
        );
      });
    }
  });

  group('(g) the host sees who sits out, in seat order', () {
    testWidgets('en: four occupied, host 0 = me, ready [0,2]', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g();
      final _Taps taps = _Taps();
      await _mount(tester, s, taps);
      expect(
        find.byKey(_startKey),
        findsOneWidget,
        reason: '${s.label}: fixture: the host card offers Start',
      );
      expect(
        find.byKey(_sitsOutKey),
        findsOneWidget,
        reason:
            '${s.label}: expected end-card-rematch-sits-out above Start '
            '(seats 1 and 3 are not ready), found none',
      );
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Bilal, Dmitri',
        reason: '${s.label}: names of seats 1 and 3, ascending',
      );
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        _loc(tester).endRematchSitsOut('Bilal, Dmitri'),
        reason: '${s.label}: the line reads endRematchSitsOut(names)',
      );
      _expectDirectlyAbove(tester, _sitsOutKey, _startKey, s);
      _expectCentred(tester, _sitsOutKey, _startKey, s);
      expect(
        find.byKey(_mayStartKey),
        findsNothing,
        reason: '${s.label}: the host card has no may-start line',
      );
    });

    testWidgets('seat order is ascending whatever order occupiedSeats has', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'g: occupied handed in as [3,2,1,0], host 0 = me, ready [2,0]',
        occupied: const <int>[3, 2, 1, 0],
        ready: const <int>[2, 0],
      );
      await _mount(tester, s, _Taps());
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Bilal, Dmitri',
        reason: '${s.label}: ascending seat order, not list order',
      );
    });

    testWidgets('one seat out is named alone, no separator', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'g: four occupied, host 0 = me, ready [0,1,3], seat 2 out',
        ready: const <int>[0, 1, 3],
      );
      await _mount(tester, s, _Taps());
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Carla',
        reason: '${s.label}: only seat 2 is out',
      );
    });

    testWidgets('three seats, ready [0,1]: seat 2 named', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'g: seats [0,1,2], host 0 = me, ready [0,1]',
        occupied: const <int>[0, 1, 2],
        ready: const <int>[0, 1],
      );
      await _mount(tester, s, _Taps());
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Carla',
        reason: '${s.label}: only seat 2 is out',
      );
    });

    testWidgets('a seat with no seatNames entry is skipped', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'g: four occupied, ready [0,2], names only for 0,1,2',
        names: const <int, String>{0: 'Ana', 1: 'Bilal', 2: 'Carla'},
      );
      await _mount(tester, s, _Taps());
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Bilal',
        reason: '${s.label}: seat 3 has no name and is not named',
      );
      expect(tester.takeException(), isNull, reason: s.label);
    });

    testWidgets('no seat left to name: no line, Start still offered', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'g: four occupied, ready [0,2], names only for 0 and 2',
        names: const <int, String>{0: 'Ana', 2: 'Carla'},
      );
      await _mount(tester, s, _Taps());
      expect(
        find.byKey(_startKey),
        findsOneWidget,
        reason: '${s.label}: fixture: Start is offered',
      );
      _expectAbsent(tester, _sitsOutKey, s);
    });

    testWidgets('the list shrinks when a seat gets ready', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(label: 'g: ready [0,2] then [0,2,1]');
      final ValueNotifier<List<int>?> feed = ValueNotifier<List<int>?>(
        const <int>[0, 2],
      );
      addTearDown(feed.dispose);
      await _mount(tester, s, _Taps(), readyFeed: feed);
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Bilal, Dmitri',
      );
      feed.value = const <int>[0, 2, 1];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'Not in the next game: Dmitri',
        reason: '${s.label}: after seat 1 is in, only seat 3 is out',
      );
    });
  });

  group('(h) the host line in Arabic', () {
    testWidgets('ar: separator is the Arabic comma, text is the ar string', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'h: ar, four occupied, host 0 = me, ready [0,2]',
        locale: const Locale('ar'),
        names: _namesAr,
      );
      await _mount(tester, s, _Taps());
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        'خارج الجولة التالية: كريم، نادين',
        reason: '${s.label}: seats 1 and 3, joined with "، "',
      );
      expect(
        _textOf(tester, _sitsOutKey, s.label),
        _loc(tester).endRematchSitsOut('كريم، نادين'),
        reason: '${s.label}: the line reads endRematchSitsOut(names)',
      );
      _expectDirectlyAbove(tester, _sitsOutKey, _startKey, s);
    });
  });

  group('(i) everyone ready, or Start not offered: no sits-out line', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _g(
        label: 'i: four occupied, host 0 = me, all four ready',
        ready: const <int>[0, 1, 2, 3],
      ),
      _g(
        label: 'i: three occupied, host 0 = me, all three ready',
        occupied: const <int>[0, 1, 2],
        ready: const <int>[0, 1, 2],
      ),
      _g(
        label: 'i: four occupied, host 0 = me, only me ready',
        ready: const <int>[0],
      ),
      _g(
        label: 'i: four occupied, ready [0,2], but not the host',
        isHost: false,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        expect(
          find.byKey(_startKey),
          findsNothing,
          reason: '${s.label}: fixture: no Start button',
        );
        _expectAbsent(tester, _sitsOutKey, s);
        _expectAbsent(tester, _mayStartKey, s);
      });
    }
  });

  group('(j) other branches: no may-start line', () {
    final List<_Scenario> scenarios = <_Scenario>[
      _a(label: 'j: rematchGone with the (a) setup', rematchGone: true),
      _a(label: 'j: everyoneLeft with the (a) setup', everyoneLeft: true),
      _a(label: 'j: isOffline with the (a) setup', isOffline: true),
      _a(
        label: 'j: rematchGone with the (b) setup',
        rematchGone: true,
        rematchByDeparted: true,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s, _Taps());
        _expectAbsent(tester, _mayStartKey, s);
        _expectAbsent(tester, _sitsOutKey, s);
      });
    }

    testWidgets('j: no rematch open at all, hostSeat given', (
      WidgetTester tester,
    ) async {
      const _Scenario s = _Scenario(
        label: 'j: no rematch lobby, seats [0,1,2], host 0, me 2',
        occupied: <int>[0, 1, 2],
        mySeat: 2,
        hostSeat: 0,
      );
      await _mount(tester, s, _Taps());
      _expectAbsent(tester, _mayStartKey, s);
      _expectAbsent(tester, _sitsOutKey, s);
    });
  });

  group('(k) both lines are live regions', () {
    testWidgets('may-start, ask path', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        final _Scenario s = _a(label: 'k: the (a) setup');
        await _mount(tester, s, _Taps());
        expect(
          _hasLiveRegion(find.byKey(_mayStartKey)),
          isTrue,
          reason:
              '${s.label}: expected a Semantics with properties.liveRegion '
              'true around end-card-rematch-may-start, found none',
        );
        expect(
          tester.getSemantics(find.byKey(_mayStartKey)),
          isSemantics(isLiveRegion: true, label: _mayStartEn),
          reason: '${s.label}: the semantics node must be a live region',
        );
      } finally {
        handle.dispose();
      }
    });

    testWidgets('may-start, hideAsk path', (WidgetTester tester) async {
      final _Scenario s = _a(
        label: 'k: the (b) setup',
        rematchByDeparted: true,
      );
      await _mount(tester, s, _Taps());
      expect(
        _hasLiveRegion(find.byKey(_mayStartKey)),
        isTrue,
        reason:
            '${s.label}: expected a Semantics with properties.liveRegion '
            'true around end-card-rematch-may-start, found none',
      );
    });

    testWidgets('sits-out', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        final _Scenario s = _g(label: 'k: the (g) setup');
        await _mount(tester, s, _Taps());
        expect(
          _hasLiveRegion(find.byKey(_sitsOutKey)),
          isTrue,
          reason:
              '${s.label}: expected a Semantics with properties.liveRegion '
              'true around end-card-rematch-sits-out, found none',
        );
        expect(
          tester.getSemantics(find.byKey(_sitsOutKey)),
          isSemantics(
            isLiveRegion: true,
            label: 'Not in the next game: Bilal, Dmitri',
          ),
          reason: '${s.label}: the semantics node must be a live region',
        );
      } finally {
        handle.dispose();
      }
    });
  });

  group('style: a heads-up in the card voice, no red', () {
    testWidgets('may-start is w600 and not the error colour', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _a(label: 'style: the (a) setup');
      await _mount(tester, s, _Taps());
      final Finder paragraph = find.descendant(
        of: find.byKey(_mayStartKey),
        matching: find.byType(RichText),
        matchRoot: true,
      );
      expect(paragraph, findsOneWidget, reason: s.label);
      final RichText rich = tester.widget<RichText>(paragraph);
      final TextStyle? style = rich.text.style;
      expect(
        style?.fontWeight,
        FontWeight.w600,
        reason: '${s.label}: the line is body style with FontWeight.w600',
      );
      final ThemeData theme = Theme.of(tester.element(find.byType(Scaffold)));
      final Color? color = style?.color;
      if (color != null) {
        expect(
          color,
          isNot(theme.colorScheme.error),
          reason: '${s.label}: a heads-up is never the error colour',
        );
        expect(
          color.r > 0.7 && color.g < 0.4 && color.b < 0.4,
          isFalse,
          reason: '${s.label}: the colour $color reads as red',
        );
      }
    });
  });

  group('(l) 360 x 640, text scale 2.0: no exception, buttons reachable', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets('${locale.languageCode}: (a) Play again taps through', (
        WidgetTester tester,
      ) async {
        final _Scenario s = _a(
          label: 'l: (a) setup, ${locale.languageCode}, 360x640, scale 2.0',
          locale: locale,
          names: locale.languageCode == 'ar' ? _namesAr : _names4,
          textScale: 2.0,
          width: 360,
          height: 640,
        );
        final _Taps taps = _Taps();
        await _mount(tester, s, taps);
        expect(
          tester.takeException(),
          isNull,
          reason: '${s.label}: no overflow or layout exception allowed',
        );
        expect(
          find.byKey(_mayStartKey),
          findsOneWidget,
          reason: '${s.label}: the line is on the card',
        );
        await tester.ensureVisible(find.byKey(_playAgainKey));
        await tester.pump();
        await tester.tap(find.byKey(_playAgainKey));
        await tester.pump();
        expect(
          taps.rematch,
          1,
          reason:
              '${s.label}: tapping end-card-rematch must call onRematch once',
        );
        expect(tester.takeException(), isNull, reason: s.label);
      });

      testWidgets('${locale.languageCode}: (g) Start taps through', (
        WidgetTester tester,
      ) async {
        final _Scenario s = _g(
          label: 'l: (g) setup, ${locale.languageCode}, 360x640, scale 2.0',
          locale: locale,
          names: locale.languageCode == 'ar' ? _namesAr : _names4,
          textScale: 2.0,
          width: 360,
          height: 640,
        );
        final _Taps taps = _Taps();
        await _mount(tester, s, taps);
        expect(
          tester.takeException(),
          isNull,
          reason: '${s.label}: no overflow or layout exception allowed',
        );
        expect(
          find.byKey(_sitsOutKey),
          findsOneWidget,
          reason: '${s.label}: the line is on the card',
        );
        await tester.ensureVisible(find.byKey(_startKey));
        await tester.pump();
        await tester.tap(find.byKey(_startKey));
        await tester.pump();
        expect(
          taps.start,
          1,
          reason:
              '${s.label}: tapping end-card-rematch-start must call '
              'onStartReady once',
        );
        expect(tester.takeException(), isNull, reason: s.label);
      });
    }

    testWidgets('long names at scale 2.0 wrap the sits-out line', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _g(
        label: 'l: (g) setup, 20-char names, 360x640, scale 2.0',
        names: const <int, String>{
          0: 'Alexandria0000000000',
          1: 'Bartholomew000000000',
          2: 'Christopherson000000',
          3: 'Dimitrios0000000000x',
        },
        textScale: 2.0,
        width: 360,
        height: 640,
      );
      await _mount(tester, s, _Taps());
      expect(
        tester.takeException(),
        isNull,
        reason: '${s.label}: the long line must wrap, not overflow',
      );
      final Rect line = tester.getRect(find.byKey(_sitsOutKey));
      expect(
        line.right,
        lessThanOrEqualTo(360 + 0.5),
        reason: '${s.label}: line $line runs past the 360 dp screen',
      );
      expect(
        line.left,
        greaterThanOrEqualTo(-0.5),
        reason: '${s.label}: line $line starts left of the screen',
      );
    });
  });

  group('(m) a line that appears on a card already up fades in', () {
    testWidgets('may-start: ready [0] to [0,1] fades over 200 ms', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _a(label: 'm: (a) setup, ready [0] then [0,1]');
      final ValueNotifier<List<int>?> feed = ValueNotifier<List<int>?>(
        const <int>[0],
      );
      addTearDown(feed.dispose);
      await _mount(tester, s, _Taps(), readyFeed: feed);
      expect(
        find.byKey(_mayStartKey),
        findsNothing,
        reason: '${s.label}: fixture: only the host is in, no line yet',
      );

      feed.value = const <int>[0, 1];
      await tester.pump();
      expect(
        find.byKey(_mayStartKey),
        findsOneWidget,
        reason: '${s.label}: the line must appear once seat 1 is in',
      );
      await tester.pump(const Duration(milliseconds: 50));
      final double at50 = _opacityOf(tester, find.byKey(_mayStartKey));
      await tester.pump(const Duration(milliseconds: 200));
      final double at250 = _opacityOf(tester, find.byKey(_mayStartKey));
      expect(
        at50,
        lessThan(1.0),
        reason:
            '${s.label}: the line must still be fading at 50 ms; opacity '
            '$at50',
      );
      expect(
        at250,
        closeTo(1.0, 1e-6),
        reason: '${s.label}: the line must be fully drawn at 250 ms; $at250',
      );

      // A line already on screen is never re-faded.
      feed.value = const <int>[0, 1];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        _opacityOf(tester, find.byKey(_mayStartKey)),
        closeTo(1.0, 1e-6),
        reason: '${s.label}: a rebuild must not fade the line again',
      );
      expect(tester.takeException(), isNull, reason: s.label);
    });

    testWidgets('may-start: not faded on the card\'s first frame', (
      WidgetTester tester,
    ) async {
      final _Scenario s = _a(label: 'm: (a) setup on the first frame');
      tester.view.physicalSize = Size(s.width, s.height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: appSupportedLocales,
          home: Scaffold(body: SingleChildScrollView(child: s.card(_Taps()))),
        ),
      );
      expect(
        find.byKey(_mayStartKey),
        findsOneWidget,
        reason: '${s.label}: the line is on the first frame',
      );
      expect(
        _opacityOf(tester, find.byKey(_mayStartKey)),
        closeTo(1.0, 1e-6),
        reason: '${s.label}: nothing fades on a card\'s first frame',
      );
    });
  });
}
