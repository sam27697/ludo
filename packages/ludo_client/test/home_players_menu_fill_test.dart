// Proof for order 527 (work/ludo/orders/527-players-menu-fill.md), the fill
// behind the selected entry of home's player-count menu. Written from the
// order text, against no implementation of it.
//
// The rule is about what is painted, not about which widget paints it, so the
// cases read pixels: the whole view is captured with the menu route open and
// a handful of points are sampled inside each entry's rect, clear of every
// glyph. The current entry must be one flat LudoColors.paperWashTop from edge
// to edge (no Theme.highlightColor band behind a shorter patch); the other
// two must show the menu's own LudoColors.paperElevated.
//
// Pixel tolerance: none. The fills are opaque flat colours and every sample is
// at least 3 dp from a glyph, an edge or a corner, so antialiasing never
// reaches a sample point; any difference at all is a different paint.
//
// The surface is 390 x 844 dp at devicePixelRatio 2.0, so a sample at logical
// (x, y) is read at physical (2x, 2y) and a wrong logical/physical mapping
// shows up as a wrong colour rather than being hidden by a ratio of 1.
//
// Ambiguities, reported rather than invented around:
//
//   1. "The gap between the check slot and the numeral" is located from the
//      check icon's rect and the nearest painted neighbour (the figures or the
//      numeral) on the side that faces the content. When that gap is under
//      4 dp wide there is nothing clear to sample, the point is left out and
//      the case still has the six edge points; it is never faked. The same x
//      is then sampled on the other two entries, where it must be paper.
//   2. The menu clips its entries to a rounded border, so an edge point of the
//      first or last entry that falls in the clipped corner (outside the
//      border's radius, kRadiusControl) is left out. Entries in the middle
//      keep all six edge points and the others at least four.
//   3. The edge points are taken at the entry's rect (the Key's render box),
//      which the order treats as the row. If an implementation keys a box
//      narrower than the item area the three rects would differ in width;
//      one case compares them so that shows up as its own failure.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/player_count_icon.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _playersButtonKey = Key('home-players-button');
Key _optionKey(int n) => Key('home-players-option-$n');

const Size _phone = Size(390, 844);
const double _ratio = 2.0;
const List<int> _counts = <int>[2, 3, 4];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

// --- harness ----------------------------------------------------------------

RoomController _controllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-players-menu-fill-test.invalid/ws'),
    connect: (Uri url) async => FakeTransport(),
  );
}

Widget _homeApp(Locale locale) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _controllerFactory,
    ),
  );
}

/// What a failing case prints so it can be rerun: nothing here is random, so
/// the scenario, locale, count and surface are the whole seed.
String _repro(String scenario, Locale locale, int current) {
  return 'Reproduce: scenario "$scenario", locale ${locale.languageCode}, '
      'current count $current, surface ${_phone.width.toInt()}x'
      '${_phone.height.toInt()} dp at ratio $_ratio, flutter test '
      'test/home_players_menu_fill_test.dart --plain-name "$scenario". '
      'No random input is involved.';
}

/// Mounts home, sets the count to [current] by selecting it the way a player
/// does, and reopens the menu. The default count is 4, so 4 is also picked
/// through a round trip to make it a real selection.
Future<void> _mountWithCurrent(
  WidgetTester tester,
  Locale locale,
  int current,
  String repro,
) async {
  tester.view.physicalSize = _phone * _ratio;
  tester.view.devicePixelRatio = _ratio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_homeApp(locale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
  if (current != 4) {
    await _openMenu(tester, repro);
    await _pick(tester, current, repro);
  } else {
    await _openMenu(tester, repro);
    await _pick(tester, 2, repro);
    await _openMenu(tester, repro);
    await _pick(tester, 4, repro);
  }
  await _openMenu(tester, repro);
}

Future<void> _openMenu(WidgetTester tester, String repro) async {
  await tester.ensureVisible(find.byKey(_playersButtonKey));
  await tester.tap(find.byKey(_playersButtonKey));
  await tester.pumpAndSettle();
  for (final int n in _counts) {
    expect(
      find.byKey(_optionKey(n)),
      findsOneWidget,
      reason:
          'expected home-players-option-$n on screen after tapping '
          'home-players-button; the menu did not show it. $repro',
    );
  }
}

Future<void> _pick(WidgetTester tester, int n, String repro) async {
  await tester.tap(find.byKey(_optionKey(n)));
  await tester.pumpAndSettle();
  for (final int m in _counts) {
    expect(
      find.byKey(_optionKey(m), skipOffstage: false),
      findsNothing,
      reason:
          'expected the menu to close after picking option $n; '
          'home-players-option-$m is still in the tree. $repro',
    );
  }
}

/// The numeral the app paints for [n] in the current locale, exactly as
/// `formatDecimal` renders it (Arabic-Indic digits in ar).
String _numeral(WidgetTester tester, int n) {
  final BuildContext context = tester.element(find.byType(Scaffold).first);
  return MaterialLocalizations.of(context).formatDecimal(n);
}

String _stripSpace(String s) => s.replaceAll(RegExp('[\\s ‎‏]'), '');

// --- pixels -----------------------------------------------------------------

/// The whole view as rgba bytes, one physical pixel per entry.
Future<ByteData> _rgba(WidgetTester tester) async {
  RenderObject root = tester.renderObject(find.byType(Scaffold).first);
  while (root.parent != null) {
    root = root.parent!;
  }
  final OffsetLayer layer = root.debugLayer! as OffsetLayer;
  final Size size = tester.view.physicalSize;
  final ui.Image image = (await tester.runAsync(
    () => layer.toImage(Offset.zero & size, pixelRatio: 1.0),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return data!;
}

/// The colour at the logical point [p], read from the physical pixel it maps
/// to.
Color _pixelAt(ByteData data, Size physical, Offset p) {
  final int x = (p.dx * _ratio).floor();
  final int y = (p.dy * _ratio).floor();
  expect(
    x >= 0 && y >= 0 && x < physical.width && y < physical.height,
    isTrue,
    reason:
        'fixture is broken: sample point $p maps to physical ($x, $y), '
        'outside the ${physical.width.toInt()}x${physical.height.toInt()} '
        'capture',
  );
  final int i = (y * physical.width.toInt() + x) * 4;
  return Color.fromARGB(
    data.getUint8(i + 3),
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// The x (logical) in the gap between the check slot and the content that
/// follows it, or null when no gap of at least 4 dp can be located.
double? _checkGapX(WidgetTester tester, int current) {
  final Finder option = find.byKey(_optionKey(current));
  final Finder check = find.descendant(
    of: option,
    matching: find.byIcon(Icons.check_rounded),
  );
  if (check.evaluate().length != 1) {
    return null;
  }
  final Rect checkRect = tester.getRect(check);
  final TextDirection direction = Directionality.of(tester.element(option));
  final List<Rect> neighbours = <Rect>[
    for (final Finder f in <Finder>[
      find.descendant(of: option, matching: find.byType(PlayerCountIcon)),
      find.descendant(
        of: option,
        matching: find.text(_numeral(tester, current)),
      ),
    ])
      if (f.evaluate().length == 1) tester.getRect(f),
  ];
  double? best;
  double bestGap = double.infinity;
  for (final Rect n in neighbours) {
    final double from = direction == TextDirection.ltr
        ? checkRect.right
        : n.right;
    final double to = direction == TextDirection.ltr ? n.left : checkRect.left;
    final double gap = to - from;
    if (gap >= 4 && gap < bestGap) {
      bestGap = gap;
      best = from + gap / 2;
    }
  }
  return best;
}

/// The rect of the menu's own surface: the outermost Material above the
/// entries (nothing else between the route and the menu provides one).
Rect _menuRect(WidgetTester tester, int n) {
  final Finder materials = find.ancestor(
    of: find.byKey(_optionKey(n)),
    matching: find.byType(Material),
  );
  expect(
    materials,
    findsWidgets,
    reason: 'fixture is broken: home-players-option-$n has no Material above',
  );
  final Rect menu = tester.getRect(materials.last);
  expect(
    menu.contains(tester.getRect(find.byKey(_optionKey(n))).center),
    isTrue,
    reason: 'fixture is broken: the menu surface $menu misses option $n',
  );
  return menu;
}

/// Named sample points inside [rect]: both edges at the vertical centre, 3 dp
/// below the top and 3 dp above the bottom, each 3 dp in from the edge. A
/// point that falls outside the menu's own rounded corner (radius
/// kRadiusControl, less 1.5 dp for the felt border and antialiasing) is not
/// the entry's to fill, so it is left out; only the first entry's top corners
/// and the last entry's bottom corners can be affected.
Map<String, Offset> _edgePoints(Rect rect, Rect menu) {
  const double inset = 3;
  final RRect surface = RRect.fromRectAndRadius(
    menu,
    const Radius.circular(kRadiusControl),
  ).deflate(1.5);
  final Map<String, Offset> all = <String, Offset>{
    'left edge, centre': Offset(rect.left + inset, rect.center.dy),
    'right edge, centre': Offset(rect.right - inset, rect.center.dy),
    'left edge, top': Offset(rect.left + inset, rect.top + inset),
    'right edge, top': Offset(rect.right - inset, rect.top + inset),
    'left edge, bottom': Offset(rect.left + inset, rect.bottom - inset),
    'right edge, bottom': Offset(rect.right - inset, rect.bottom - inset),
  };
  final Map<String, Offset> kept = <String, Offset>{
    for (final MapEntry<String, Offset> e in all.entries)
      if (surface.contains(e.value)) e.key: e.value,
  };
  expect(
    kept.length >= 4,
    isTrue,
    reason:
        'fixture is broken: only ${kept.keys.toList()} of the edge points '
        'of $rect lie inside the menu surface $menu',
  );
  return kept;
}

/// One line per sample that is not [expected]; empty when all match.
List<String> _mismatches(
  ByteData data,
  Size physical,
  Map<String, Offset> points,
  Color expected,
) {
  final List<String> out = <String>[];
  points.forEach((String name, Offset p) {
    final Color got = _pixelAt(data, physical, p);
    if (got.toARGB32() != expected.toARGB32()) {
      out.add(
        '$name at (${p.dx.toStringAsFixed(1)}, ${p.dy.toStringAsFixed(1)}) '
        'is ${_hex(got)}',
      );
    }
  });
  return out;
}

/// [testWidgets] with a semantics handle held for the whole body.
void _semTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final Locale locale in _locales) {
    final String lc = locale.languageCode;
    for (final int current in _counts) {
      group('players menu fill, $lc, current $current', () {
        testWidgets('the current entry is one flat paperWashTop across its '
            'whole row', (tester) async {
          const String name = 'selected row one colour';
          final String repro = _repro(name, locale, current);
          await _mountWithCurrent(tester, locale, current, repro);

          final Rect rect = tester.getRect(find.byKey(_optionKey(current)));
          final Map<String, Offset> points = _edgePoints(
            rect,
            _menuRect(tester, current),
          );
          final double? gapX = _checkGapX(tester, current);
          if (gapX != null) {
            points['check gap, centre'] = Offset(gapX, rect.center.dy);
            points['check gap, top'] = Offset(gapX, rect.top + 3);
          }
          final ByteData data = await _rgba(tester);
          final List<String> bad = _mismatches(
            data,
            tester.view.physicalSize,
            points,
            LudoColors.paperWashTop,
          );
          expect(
            bad,
            isEmpty,
            reason:
                'expected all ${points.length} samples inside '
                'home-players-option-$current (rect $rect) to be '
                'paperWashTop ${_hex(LudoColors.paperWashTop)}; '
                '${bad.length} differ: $bad. $repro',
          );
        });

        testWidgets('the three entries are the same width, so the fill spans '
            'the item area for every count', (tester) async {
          const String name = 'entries share one width';
          final String repro = _repro(name, locale, current);
          await _mountWithCurrent(tester, locale, current, repro);

          final Map<int, Rect> rects = <int, Rect>{
            for (final int n in _counts)
              n: tester.getRect(find.byKey(_optionKey(n))),
          };
          for (final int n in _counts) {
            expect(
              rects[n]!.left,
              closeTo(rects[current]!.left, 0.01),
              reason:
                  'expected option $n to start where option $current starts; '
                  'rects $rects. $repro',
            );
            expect(
              rects[n]!.right,
              closeTo(rects[current]!.right, 0.01),
              reason:
                  'expected option $n to end where option $current ends; '
                  'rects $rects. $repro',
            );
          }
        });

        testWidgets('the other entries carry no fill, only the menu '
            'paperElevated', (tester) async {
          const String name = 'other rows no fill';
          final String repro = _repro(name, locale, current);
          await _mountWithCurrent(tester, locale, current, repro);

          final double? gapX = _checkGapX(tester, current);
          final ByteData data = await _rgba(tester);
          for (final int n in _counts.where((int c) => c != current)) {
            final Rect rect = tester.getRect(find.byKey(_optionKey(n)));
            final Map<String, Offset> points = _edgePoints(
              rect,
              _menuRect(tester, n),
            );
            if (gapX != null) {
              points['check slot gap, centre'] = Offset(gapX, rect.center.dy);
              points['check slot gap, top'] = Offset(gapX, rect.top + 3);
            }
            final List<String> bad = _mismatches(
              data,
              tester.view.physicalSize,
              points,
              LudoColors.paperElevated,
            );
            expect(
              bad,
              isEmpty,
              reason:
                  'expected all ${points.length} samples inside '
                  'home-players-option-$n (rect $rect, not the current '
                  'count) to be the menu background paperElevated '
                  '${_hex(LudoColors.paperElevated)}; ${bad.length} differ: '
                  '$bad. $repro',
            );
          }
        });

        testWidgets('the check glyph is in the current entry only', (
          tester,
        ) async {
          const String name = 'check on current only';
          final String repro = _repro(name, locale, current);
          await _mountWithCurrent(tester, locale, current, repro);

          expect(
            find.byIcon(Icons.check_rounded),
            findsOneWidget,
            reason:
                'expected exactly one Icons.check_rounded with the menu '
                'open; found ${find.byIcon(Icons.check_rounded).evaluate().length}. '
                '$repro',
          );
          for (final int n in _counts) {
            expect(
              find.descendant(
                of: find.byKey(_optionKey(n)),
                matching: find.byIcon(Icons.check_rounded),
              ),
              n == current ? findsOneWidget : findsNothing,
              reason:
                  'expected the check glyph ${n == current ? 'inside' : 'not '
                            'inside'} home-players-option-$n '
                  '(${n == current ? 'the current' : 'not the current'} '
                  'count). $repro',
            );
          }
        });

        _semTest('only the current entry reports selected', (tester) async {
          const String name = 'selected semantics';
          final String repro = _repro(name, locale, current);
          await _mountWithCurrent(tester, locale, current, repro);

          for (final int n in _counts) {
            final ui.Tristate selected = tester
                .getSemantics(find.byKey(_optionKey(n)))
                .flagsCollection
                .isSelected;
            if (n == current) {
              expect(
                selected,
                ui.Tristate.isTrue,
                reason:
                    'expected home-players-option-$n (the current count) to '
                    'report selected; its isSelected is $selected. $repro',
              );
            } else {
              expect(
                selected,
                isNot(ui.Tristate.isTrue),
                reason:
                    'expected home-players-option-$n (not the current count) '
                    'not to report selected; its isSelected is $selected. '
                    '$repro',
              );
            }
          }
        });

        testWidgets('picking another count closes the menu and the control '
            'shows the new numeral', (tester) async {
          const String name = 'pick another count';
          final String repro = _repro(name, locale, current);
          await _mountWithCurrent(tester, locale, current, repro);

          for (final int next in _counts.where((int c) => c != current)) {
            if (find.byKey(_optionKey(next)).evaluate().isEmpty) {
              await _openMenu(tester, repro);
            }
            await _pick(tester, next, repro);
            final String expected = _numeral(tester, next);
            final List<String> painted = <String>[
              for (final Text t in tester.widgetList<Text>(
                find.descendant(
                  of: find.byKey(_playersButtonKey),
                  matching: find.byType(Text),
                ),
              ))
                _stripSpace(t.data ?? ''),
            ];
            expect(
              painted,
              contains(expected),
              reason:
                  'expected home-players-button to show the numeral '
                  '"$expected" (formatDecimal of $next) after picking $next; '
                  'its texts are $painted. $repro',
            );
            expect(
              tester
                  .widget<PlayerCountIcon>(
                    find.descendant(
                      of: find.byKey(_playersButtonKey),
                      matching: find.byType(PlayerCountIcon),
                    ),
                  )
                  .count,
              next,
              reason:
                  'expected the control icon to show $next figures after '
                  'picking $next. $repro',
            );
          }
        });
      });
    }
  }
}
