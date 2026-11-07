// C-585, order 585t. Proves the contract of work/ludo/orders/585-end-card-
// ready-row.md (D1 to D5) on EndCard itself: one chip per occupied seat with
// the key end-card-ready-<seat>, a check mark on the ready ones only, the row
// shown in the ready branch at every table size and in the ask branch only at
// three seats or more, one spoken label per chip, the seat's SeatMark under
// each chip at 12 dp or more, and a row that wraps instead of overflowing at
// text scale 2.0 in ar with four long names on a 360 dp card.
//
// Written from the contract, not from the implementation. Two points the
// contract leaves to this file:
//
//   1. The labels endRematchSeatReady / endRematchSeatWaiting are new
//      AppLocalizations getters. This file is meant to compile on a branch
//      that does not have them yet, so the expected text is built here from
//      the contract's own wording ("{name}: in", "{name}: not yet" in en,
//      "{name}: جاهز", "{name}: ليس بعد" in ar) instead of calling the
//      getters.
//   2. The "You" string. The contract names gameYouTag; that key does not
//      exist in app_en.arb. The ARB carries seatYou ("You" / "أنت"), the
//      short chip that marks the player's own seat, and this file reads that
//      one through AppLocalizations. If the implementation reuses another
//      string the own-seat cases go red and say which text they expected.
//
// "Ready = filled with a light tint, not ready = outlined" is not asserted:
// the contract gives no widget shape or colour for it. The check mark (an
// Icon from the check family) is the colour-free state signal that is.
//
// Every case is deterministic (no timers beyond the one bounded celebration
// pump, no randomness); the scenario label in each failure message is the
// whole recipe to reproduce it.

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
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4;

const Key _askKey = Key('end-card-rematch-ask');
const Key _playAgainKey = Key('end-card-rematch');
const Key _waitingKey = Key('end-card-rematch-waiting');

Key _chipKey(int seat) => Key('end-card-ready-$seat');

const GameStats _stats = GameStats(
  rolls: 50,
  sixes: 32,
  capturesMade: 1,
  timesCaptured: 0,
  tokensHome: 4,
  complete: true,
);

final Set<IconData> _checkIcons = <IconData>{
  Icons.check,
  Icons.check_rounded,
  Icons.check_sharp,
  Icons.check_outlined,
  Icons.check_circle,
  Icons.check_circle_rounded,
  Icons.check_circle_outline,
  Icons.done,
  Icons.done_rounded,
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

/// One end card scenario. [ready] non-null puts a rematch lobby on the card;
/// [mySeat] is in [ready] for the ready branch and not in it for the ask
/// branch.
class _Scenario {
  const _Scenario({
    required this.label,
    required this.occupied,
    required this.mySeat,
    this.ready,
    this.by = 0,
    this.names = const <int, String>{},
    this.locale = const Locale('en'),
    this.textScale = 1.0,
    this.width = 390,
    this.rematchGone = false,
  });

  final String label;
  final List<int> occupied;
  final int mySeat;
  final List<int>? ready;
  final int by;
  final Map<int, String> names;
  final Locale locale;
  final double textScale;
  final double width;
  final bool rematchGone;

  bool get isAr => locale.languageCode == 'ar';

  Widget card() {
    final List<int>? r = ready;
    return EndCard(
      mySeat: mySeat,
      winnerSeat: by == mySeat ? (mySeat + 1) % 4 : mySeat,
      winnerName: 'Winner',
      seatColors: LudoColors.seats,
      stats: _stats,
      verifyUrl: 'https://end-card-ready-row.invalid/verify',
      onVerify: () {},
      onNewTable: () {},
      rematch: r == null ? null : RematchState(by: by, ready: r),
      rematchByName: r == null ? null : (names[by] ?? 'Starter'),
      occupiedSeats: occupied,
      rematchGone: rematchGone,
      onRematch: () {},
      seatNames: names,
    );
  }
}

Future<void> _mount(WidgetTester tester, _Scenario s) async {
  tester.view.physicalSize = Size(s.width, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
          child: s.card(),
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

/// All chips whose key is `end-card-ready-N`, by seat.
Map<int, Finder> _chips(WidgetTester tester) {
  final Map<int, Finder> found = <int, Finder>{};
  for (int seat = 0; seat < 4; seat++) {
    final Finder f = find.byKey(_chipKey(seat));
    if (f.evaluate().isNotEmpty) {
      found[seat] = f;
    }
  }
  return found;
}

bool _hasCheck(Finder chip) {
  return find
      .descendant(
        of: chip,
        matching: find.byWidgetPredicate(
          (Widget w) => w is Icon && _checkIcons.contains(w.icon),
        ),
      )
      .evaluate()
      .isNotEmpty;
}

int _checkCount(Finder chip) {
  return find
      .descendant(
        of: chip,
        matching: find.byWidgetPredicate(
          (Widget w) => w is Icon && _checkIcons.contains(w.icon),
        ),
      )
      .evaluate()
      .length;
}

Finder _need(Map<int, Finder> chips, int seat, String label) {
  final Finder? chip = chips[seat];
  if (chip == null) {
    fail(
      '$label: expected a chip with key end-card-ready-$seat, '
      'found chips for seats ${chips.keys.toList()}',
    );
  }
  return chip;
}

String _expectedLabel(Locale locale, bool isReady, String name) {
  if (locale.languageCode == 'ar') {
    return isReady ? '$name: جاهز' : '$name: ليس بعد';
  }
  return isReady ? '$name: in' : '$name: not yet';
}

/// The text a chip must carry for [seat] in [s]: "You" for my own seat, the
/// seatNames entry otherwise, null when the seat has no entry.
String? _shownName(_Scenario s, AppLocalizations loc, int seat) {
  if (seat == s.mySeat) {
    return loc.seatYou;
  }
  return s.names[seat];
}

Future<void> _withSemantics(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  try {
    await body();
  } finally {
    handle.dispose();
  }
}

class _Sem {
  const _Sem(this.label, this.rect);
  final String label;
  final Rect rect;
}

List<_Sem> _semantics(WidgetTester tester) {
  final SemanticsNode root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final List<_Sem> out = <_Sem>[];
  void walk(SemanticsNode node, Matrix4 parent) {
    final Matrix4 global = parent.clone();
    if (node.transform != null) {
      global.multiply(node.transform!);
    }
    if (node.label.isNotEmpty) {
      out.add(_Sem(node.label, MatrixUtils.transformRect(global, node.rect)));
    }
    node.visitChildren((SemanticsNode child) {
      walk(child, global);
      return true;
    });
  }

  walk(root, Matrix4.identity());
  return out;
}

String _dumpChips(WidgetTester tester) {
  return _chips(tester).entries
      .map(
        (MapEntry<int, Finder> e) =>
            'seat ${e.key} rect=${tester.getRect(e.value)}',
      )
      .join('; ');
}

void main() {
  setUpAll(_loadAppFonts);

  const Map<int, String> names4 = <int, String>{
    0: 'Ana',
    1: 'Bilal',
    2: 'Carla',
    3: 'Dmitri',
  };

  group('(a) ready branch: one chip per occupied seat, check on ready only', () {
    final List<_Scenario> scenarios = <_Scenario>[
      const _Scenario(
        label: 'ready branch, 2 seats [0,1], me 0, ready [0]',
        occupied: <int>[0, 1],
        mySeat: 0,
        ready: <int>[0],
        names: <int, String>{0: 'Ana', 1: 'Bilal'},
      ),
      const _Scenario(
        label: 'ready branch, 2 seats [0,1], me 1, ready [1,0] (all in)',
        occupied: <int>[0, 1],
        mySeat: 1,
        ready: <int>[1, 0],
        by: 0,
        names: <int, String>{0: 'Ana', 1: 'Bilal'},
      ),
      const _Scenario(
        label: 'ready branch, 3 seats [0,2,3], me 2, ready [2]',
        occupied: <int>[0, 2, 3],
        mySeat: 2,
        ready: <int>[2],
        by: 2,
        names: names4,
      ),
      const _Scenario(
        label: 'ready branch, 4 seats, me 1, ready [1,3], by 3',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 1,
        ready: <int>[1, 3],
        by: 3,
        names: names4,
      ),
      const _Scenario(
        label: 'ready branch, 4 seats, me 0, ready [0] only',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 0,
        ready: <int>[0],
        names: names4,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s);
        final Map<int, Finder> chips = _chips(tester);
        expect(
          chips.keys.toList()..sort(),
          s.occupied,
          reason:
              '${s.label}: expected exactly one end-card-ready-<seat> chip '
              'per occupied seat ${s.occupied}, found seats '
              '${chips.keys.toList()} (${_dumpChips(tester)})',
        );
        for (final int seat in s.occupied) {
          expect(
            chips[seat],
            findsOneWidget,
            reason: '${s.label}: seat $seat must have exactly one chip',
          );
          final bool isReady = s.ready!.contains(seat);
          expect(
            _checkCount(_need(chips, seat, s.label)),
            isReady ? 1 : 0,
            reason:
                '${s.label}: seat $seat is ${isReady ? "ready" : "not ready"}'
                ', expected ${isReady ? "one check mark icon" : "no check mark"}'
                ' under end-card-ready-$seat, found ${_checkCount(_need(chips, seat, s.label))}',
          );
        }
        for (int seat = 0; seat < 4; seat++) {
          if (!s.occupied.contains(seat)) {
            expect(
              find.byKey(_chipKey(seat)),
              findsNothing,
              reason: '${s.label}: seat $seat is empty and must have no chip',
            );
          }
        }
        expect(
          find.byKey(_waitingKey),
          findsOneWidget,
          reason: '${s.label}: the ready branch keeps its waiting line (D5)',
        );
      });
    }
  });

  group('chip order follows occupiedSeats, ascending, in reading order', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets('${locale.languageCode}, 4 seats ready branch', (
        WidgetTester tester,
      ) async {
        final _Scenario s = _Scenario(
          label: '${locale.languageCode} ready branch 4 seats order',
          occupied: const <int>[0, 1, 2, 3],
          mySeat: 0,
          ready: const <int>[0],
          names: names4,
          locale: locale,
        );
        await _mount(tester, s);
        final Map<int, Finder> chips = _chips(tester);
        final bool rtl = s.isAr;
        final List<int> seats = chips.keys.toList()
          ..sort((int a, int b) {
            final Offset ca = tester.getCenter(chips[a]!);
            final Offset cb = tester.getCenter(chips[b]!);
            if ((ca.dy - cb.dy).abs() > 2) {
              return ca.dy.compareTo(cb.dy);
            }
            return rtl ? cb.dx.compareTo(ca.dx) : ca.dx.compareTo(cb.dx);
          });
        expect(
          seats,
          <int>[0, 1, 2, 3],
          reason:
              '${s.label}: expected reading order 0,1,2,3 '
              '(${rtl ? "right to left" : "left to right"}), got $seats '
              '(${_dumpChips(tester)})',
        );
      });
    }
  });

  group(
    '(b) ask branch with 3 or more seats: row between ask and Play again',
    () {
      final List<_Scenario> scenarios = <_Scenario>[
        const _Scenario(
          label: 'ask branch, 3 seats [0,1,2], me 2 not ready, ready [0,1]',
          occupied: <int>[0, 1, 2],
          mySeat: 2,
          ready: <int>[0, 1],
          names: names4,
        ),
        const _Scenario(
          label: 'ask branch, 4 seats, me 3 not ready, ready [0,1,2]',
          occupied: <int>[0, 1, 2, 3],
          mySeat: 3,
          ready: <int>[1, 0, 2],
          by: 1,
          names: names4,
        ),
        const _Scenario(
          label: 'ask branch, 3 seats [1,2,3], me 1, only the starter in',
          occupied: <int>[1, 2, 3],
          mySeat: 1,
          ready: <int>[3],
          by: 3,
          names: names4,
        ),
        const _Scenario(
          label: 'ask branch, ar, 4 seats, me 2, ready [0,1]',
          occupied: <int>[0, 1, 2, 3],
          mySeat: 2,
          ready: <int>[0, 1],
          names: names4,
          locale: Locale('ar'),
        ),
      ];
      for (final _Scenario s in scenarios) {
        testWidgets(s.label, (WidgetTester tester) async {
          await _mount(tester, s);
          expect(
            find.byKey(_askKey),
            findsOneWidget,
            reason: '${s.label}: ask',
          );
          expect(
            find.byKey(_playAgainKey),
            findsOneWidget,
            reason: '${s.label}: Play again',
          );
          final Map<int, Finder> chips = _chips(tester);
          expect(
            chips.keys.toList()..sort(),
            s.occupied,
            reason:
                '${s.label}: the row must show one chip per occupied seat '
                '${s.occupied} at ${s.occupied.length} seats, found '
                '${chips.keys.toList()}',
          );
          final Rect ask = tester.getRect(find.byKey(_askKey));
          final Rect button = tester.getRect(find.byKey(_playAgainKey));
          double top = double.infinity;
          double bottom = double.negativeInfinity;
          for (final Finder f in chips.values) {
            final Rect r = tester.getRect(f);
            top = r.top < top ? r.top : top;
            bottom = r.bottom > bottom ? r.bottom : bottom;
          }
          expect(
            top,
            greaterThanOrEqualTo(ask.bottom - 0.5),
            reason:
                '${s.label}: the row must sit below the ask line; ask=$ask '
                'row top=$top',
          );
          expect(
            bottom,
            lessThanOrEqualTo(button.top + 0.5),
            reason:
                '${s.label}: the row must sit above Play again; button=$button '
                'row bottom=$bottom',
          );
          for (final int seat in s.occupied) {
            final bool isReady = s.ready!.contains(seat);
            expect(
              _hasCheck(_need(chips, seat, s.label)),
              isReady,
              reason:
                  '${s.label}: seat $seat ${isReady ? "is" : "is not"} ready, '
                  'check mark ${isReady ? "expected" : "not expected"}',
            );
          }
        });
      }
    },
  );

  group('(c) and D3: nowhere else', () {
    final List<_Scenario> scenarios = <_Scenario>[
      const _Scenario(
        label: 'ask branch, 2 seats [0,1], me 1, ready [0]',
        occupied: <int>[0, 1],
        mySeat: 1,
        ready: <int>[0],
        names: names4,
      ),
      const _Scenario(
        label: 'ask branch, 2 seats [2,3], me 3, ready [2], ar',
        occupied: <int>[2, 3],
        mySeat: 3,
        ready: <int>[2],
        by: 2,
        names: names4,
        locale: Locale('ar'),
      ),
      const _Scenario(
        label: 'no rematch open, 4 seats',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 0,
        names: names4,
      ),
      const _Scenario(
        label: 'no rematch open, 2 seats',
        occupied: <int>[0, 1],
        mySeat: 0,
        names: names4,
      ),
      const _Scenario(
        label: 'rematch gone, 4 seats, rematch lobby still on the snapshot',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 0,
        ready: <int>[0, 1],
        names: names4,
        rematchGone: true,
      ),
      const _Scenario(
        label: 'rematch gone, 3 seats, I am not in ready',
        occupied: <int>[0, 1, 2],
        mySeat: 2,
        ready: <int>[0, 1],
        names: names4,
        rematchGone: true,
      ),
      const _Scenario(
        label: 'ask branch with no occupied seats handed in',
        occupied: <int>[],
        mySeat: 2,
        ready: <int>[0, 1],
        names: names4,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s);
        expect(
          _chips(tester),
          isEmpty,
          reason:
              '${s.label}: expected no end-card-ready-* chip, found seats '
              '${_chips(tester).keys.toList()} (${_dumpChips(tester)})',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${s.label}: the card must build without an exception',
        );
      });
    }
  });

  group('(d) one semantics label per chip', () {
    final List<_Scenario> scenarios = <_Scenario>[
      const _Scenario(
        label: 'en ready branch 4 seats me 1 ready [1,3]',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 1,
        ready: <int>[1, 3],
        by: 3,
        names: names4,
      ),
      const _Scenario(
        label: 'ar ready branch 4 seats me 1 ready [1,3]',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 1,
        ready: <int>[1, 3],
        by: 3,
        names: names4,
        locale: Locale('ar'),
      ),
      const _Scenario(
        label: 'en ask branch 3 seats me 2 ready [0,1]',
        occupied: <int>[0, 1, 2],
        mySeat: 2,
        ready: <int>[0, 1],
        names: names4,
      ),
      const _Scenario(
        label: 'ar ask branch 3 seats me 2 ready [0,1]',
        occupied: <int>[0, 1, 2],
        mySeat: 2,
        ready: <int>[0, 1],
        names: names4,
        locale: Locale('ar'),
      ),
      const _Scenario(
        label: 'en ready branch 2 seats me 0 ready [0]',
        occupied: <int>[0, 1],
        mySeat: 0,
        ready: <int>[0],
        names: names4,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _withSemantics(tester, () async {
          await _mount(tester, s);
          final AppLocalizations loc = _loc(tester);
          final List<_Sem> sems = _semantics(tester);
          final Map<int, Finder> chips = _chips(tester);
          for (final int seat in s.occupied) {
            final bool isReady = s.ready!.contains(seat);
            final String spoken = _shownName(s, loc, seat)!;
            final String want = _expectedLabel(s.locale, isReady, spoken);
            final String other = _expectedLabel(s.locale, !isReady, spoken);
            final Rect chip = tester.getRect(_need(chips, seat, s.label));

            final List<_Sem> exact = sems
                .where((_Sem n) => n.label == want)
                .toList();
            expect(
              exact.length,
              1,
              reason:
                  '${s.label}: seat $seat expected exactly one semantics node '
                  'labelled "$want", found ${exact.length}. Labels near the '
                  'chip: ${sems.where((_Sem n) => n.rect.overlaps(chip)).map((_Sem n) => '"${n.label}"').join(', ')}',
            );
            expect(
              chip.inflate(1).contains(exact.single.rect.center),
              isTrue,
              reason:
                  '${s.label}: the "$want" node must belong to chip $chip, its '
                  'rect is ${exact.single.rect}',
            );
            expect(
              sems.where((_Sem n) => n.label == other),
              isEmpty,
              reason:
                  '${s.label}: seat $seat is ${isReady ? "in" : "not in"}; '
                  'a node labelled "$other" must not exist',
            );
            final List<_Sem> inside = sems
                .where(
                  (_Sem n) =>
                      chip.inflate(1).contains(n.rect.topLeft) &&
                      chip.inflate(1).contains(n.rect.bottomRight),
                )
                .toList();
            expect(
              inside.map((_Sem n) => n.label).toList(),
              <String>[want],
              reason:
                  '${s.label}: seat $seat chip must expose one label and its '
                  'visual children (mark, check, name) must be excluded; '
                  'labelled nodes inside the chip: '
                  '${inside.map((_Sem n) => '"${n.label}"').join(', ')}',
            );
          }
        });
      });
    }

    testWidgets('a seat with no seatNames entry still speaks once', (
      WidgetTester tester,
    ) async {
      const _Scenario s = _Scenario(
        label: 'ready branch 3 seats, seatNames only for seat 0',
        occupied: <int>[0, 1, 2],
        mySeat: 0,
        ready: <int>[0],
        names: <int, String>{0: 'Ana'},
      );
      await _mount(tester, s);
      expect(
        tester.takeException(),
        isNull,
        reason: '${s.label}: a seat without a name entry must not throw',
      );
      final Map<int, Finder> chips = _chips(tester);
      expect(chips.keys.toList()..sort(), <int>[
        0,
        1,
        2,
      ], reason: '${s.label}: every occupied seat still gets a chip');
      for (final int seat in <int>[1, 2]) {
        expect(
          find.descendant(
            of: _need(chips, seat, s.label),
            matching: find.byType(SeatMark),
          ),
          findsOneWidget,
          reason: '${s.label}: seat $seat shows its mark with no name',
        );
        expect(
          _hasCheck(_need(chips, seat, s.label)),
          isFalse,
          reason: '${s.label}: seat $seat is not ready',
        );
      }
    });
  });

  group(
    '(e) the SeatMark of each seat sits under its chip at 12 dp or more',
    () {
      final List<_Scenario> scenarios = <_Scenario>[
        const _Scenario(
          label: 'ready branch 4 seats, scale 1.0',
          occupied: <int>[0, 1, 2, 3],
          mySeat: 0,
          ready: <int>[0, 2],
          names: names4,
        ),
        const _Scenario(
          label: 'ask branch 3 seats [1,2,3], scale 1.0',
          occupied: <int>[1, 2, 3],
          mySeat: 1,
          ready: <int>[3],
          by: 3,
          names: names4,
        ),
        const _Scenario(
          label: 'ready branch 2 seats, scale 1.0',
          occupied: <int>[0, 1],
          mySeat: 1,
          ready: <int>[1],
          names: names4,
        ),
        const _Scenario(
          label: 'ready branch 4 seats, ar, scale 2.0',
          occupied: <int>[0, 1, 2, 3],
          mySeat: 0,
          ready: <int>[0],
          names: names4,
          locale: Locale('ar'),
          textScale: 2.0,
          width: 360,
        ),
      ];
      for (final _Scenario s in scenarios) {
        testWidgets(s.label, (WidgetTester tester) async {
          await _mount(tester, s);
          final Map<int, Finder> chips = _chips(tester);
          for (final int seat in s.occupied) {
            final Finder mark = find.descendant(
              of: _need(chips, seat, s.label),
              matching: find.byWidgetPredicate(
                (Widget w) => w is SeatMark && w.seat == seat,
              ),
            );
            expect(
              mark,
              findsOneWidget,
              reason:
                  '${s.label}: expected one SeatMark(seat: $seat) under '
                  'end-card-ready-$seat',
            );
            final SeatMark widget = tester.widget<SeatMark>(mark);
            expect(
              widget.size,
              greaterThanOrEqualTo(12),
              reason:
                  '${s.label}: SeatMark for seat $seat is ${widget.size} dp, '
                  'expected at least 12 so the shape is drawn',
            );
            final Size drawn = tester.getSize(mark);
            expect(
              drawn.shortestSide,
              greaterThanOrEqualTo(12),
              reason: '${s.label}: SeatMark for seat $seat laid out at $drawn',
            );
            expect(
              tester
                  .getRect(_need(chips, seat, s.label))
                  .inflate(0.5)
                  .contains(tester.getRect(mark).center),
              isTrue,
              reason:
                  '${s.label}: the mark for seat $seat lies outside its chip',
            );
          }
        });
      }
    },
  );

  group('(g) names handed in through seatNames are the ones shown', () {
    testWidgets('each chip shows its own seat name; mine reads You', (
      WidgetTester tester,
    ) async {
      const _Scenario s = _Scenario(
        label: 'ready branch 4 seats me 2, distinct names',
        occupied: <int>[0, 1, 2, 3],
        mySeat: 2,
        ready: <int>[2, 0],
        by: 0,
        names: <int, String>{
          0: 'Zorana',
          1: 'Quentin',
          2: 'Myself',
          3: 'Player 2',
        },
      );
      await _mount(tester, s);
      final AppLocalizations loc = _loc(tester);
      final Map<int, Finder> chips = _chips(tester);
      for (final int seat in s.occupied) {
        final String want = seat == s.mySeat ? loc.seatYou : s.names[seat]!;
        expect(
          find.descendant(
            of: _need(chips, seat, s.label),
            matching: find.text(want),
          ),
          findsOneWidget,
          reason:
              '${s.label}: chip $seat must show "$want" (seatNames[$seat] = '
              '"${s.names[seat]}")',
        );
        for (final int other in s.occupied) {
          if (other == seat || other == s.mySeat) {
            continue;
          }
          expect(
            find.descendant(
              of: _need(chips, seat, s.label),
              matching: find.text(s.names[other]!),
            ),
            findsNothing,
            reason:
                '${s.label}: chip $seat must not show seat $other\'s name '
                '"${s.names[other]}"',
          );
        }
      }
    });

    testWidgets('ask branch shows the same names, ar included', (
      WidgetTester tester,
    ) async {
      const _Scenario s = _Scenario(
        label: 'ar ask branch 3 seats me 1',
        occupied: <int>[0, 1, 2],
        mySeat: 1,
        ready: <int>[0, 2],
        by: 0,
        names: <int, String>{0: 'ليلى', 1: 'كريم', 2: 'سامي'},
        locale: Locale('ar'),
      );
      await _mount(tester, s);
      final AppLocalizations loc = _loc(tester);
      final Map<int, Finder> chips = _chips(tester);
      for (final int seat in s.occupied) {
        final String want = seat == s.mySeat ? loc.seatYou : s.names[seat]!;
        expect(
          find.descendant(
            of: _need(chips, seat, s.label),
            matching: find.text(want),
          ),
          findsOneWidget,
          reason: '${s.label}: chip $seat must show "$want"',
        );
      }
    });

    testWidgets('a different map gives different names', (
      WidgetTester tester,
    ) async {
      const _Scenario s = _Scenario(
        label: 'ready branch 2 seats, names Rhea / Tomas',
        occupied: <int>[0, 1],
        mySeat: 0,
        ready: <int>[0],
        names: <int, String>{0: 'Rhea', 1: 'Tomas'},
      );
      await _mount(tester, s);
      expect(
        find.descendant(
          of: find.byKey(_chipKey(1)),
          matching: find.text('Tomas'),
        ),
        findsOneWidget,
        reason: '${s.label}: chip 1 must show "Tomas"',
      );
    });
  });

  group('(f) ar, text scale 2.0, 4 seats, 20-character names, 360 dp', () {
    // Five repetitions of a four-letter word: 20 characters each.
    final Map<int, String> long = <int, String>{
      0: 'أحمدأحمدأحمدأحمدأحمد',
      1: 'ليلىليلىليلىليلىليلى',
      2: 'كريمكريمكريمكريمكريم',
      3: 'ساميساميساميساميسامي',
    };
    assert(long.values.every((String n) => n.length == 20));
    final Map<int, String> longEn = <int, String>{
      0: 'Alexandria0000000000',
      1: 'Bartholomew000000000',
      2: 'Christopherson000000',
      3: 'Dimitrios0000000000x',
    };

    final List<_Scenario> scenarios = <_Scenario>[
      _Scenario(
        label: 'ar scale 2.0 ready branch, 4 seats, 20-char ar names, 360 dp',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 0,
        ready: const <int>[0, 2],
        names: long,
        locale: const Locale('ar'),
        textScale: 2.0,
        width: 360,
      ),
      _Scenario(
        label: 'ar scale 2.0 ask branch, 4 seats, 20-char ar names, 360 dp',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 3,
        ready: const <int>[0, 1],
        names: long,
        locale: const Locale('ar'),
        textScale: 2.0,
        width: 360,
      ),
      _Scenario(
        label: 'ar scale 2.0 ready branch, 4 seats, 20-char en names, 360 dp',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 1,
        ready: const <int>[1, 3, 0, 2],
        by: 3,
        names: longEn,
        locale: const Locale('ar'),
        textScale: 2.0,
        width: 360,
      ),
      _Scenario(
        label: 'en scale 2.0 ask branch, 4 seats, 20-char names, 360 dp',
        occupied: const <int>[0, 1, 2, 3],
        mySeat: 2,
        ready: const <int>[0],
        names: longEn,
        textScale: 2.0,
        width: 360,
      ),
    ];
    for (final _Scenario s in scenarios) {
      testWidgets(s.label, (WidgetTester tester) async {
        await _mount(tester, s);
        expect(
          tester.takeException(),
          isNull,
          reason: '${s.label}: no overflow or layout exception allowed',
        );
        final Map<int, Finder> chips = _chips(tester);
        expect(
          chips.keys.toList()..sort(),
          s.occupied,
          reason: '${s.label}: every occupied seat needs a chip',
        );
        final Rect screen = Rect.fromLTWH(0, 0, s.width, 4000);
        final List<Rect> rects = <Rect>[];
        for (final int seat in s.occupied) {
          final Rect r = tester.getRect(_need(chips, seat, s.label));
          rects.add(r);
          expect(
            screen.inflate(0.5).contains(r.topLeft) &&
                screen.inflate(0.5).contains(r.bottomRight),
            isTrue,
            reason:
                '${s.label}: chip $seat at $r is not fully on screen '
                '(${s.width} dp wide)',
          );
        }
        for (int i = 0; i < rects.length; i++) {
          for (int j = i + 1; j < rects.length; j++) {
            final Rect inter = rects[i].intersect(rects[j]);
            expect(
              inter.width > 0.5 && inter.height > 0.5,
              isFalse,
              reason:
                  '${s.label}: chips ${s.occupied[i]} and ${s.occupied[j]} '
                  'overlap: ${rects[i]} vs ${rects[j]}',
            );
          }
        }
      });
    }
  });
}
