// Home chrome for C-276: no title bar, the locale toggle in the body's top
// end corner, and the closed players disclosure carrying a tune icon.
//
// HomeScreen is mounted the way test/locale_toggle_contrast_test.dart
// mounts it (LudoApp, one mount per case). Nothing here names a type
// C-276 adds, so the file compiles against the old home.
//
// Corner bounds, from the contract, at 360 x 800: the toggle's top edge
// within kSpace2 + 1 of the safe area top, its end edge within kSpace2 + 1
// of the view's end edge (right in en, left in ar), size at least 48 x 48,
// and not inside the SingleChildScrollView.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/theme.dart' show kSpace2;

const Size _phone = Size(360, 800);
const Key _localeKey = Key('locale-toggle-button');
const Key _disclosureKey = Key('home-players-disclosure');

void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String _formatRect(Rect rect) =>
    'left=${rect.left.toStringAsFixed(1)} '
    'top=${rect.top.toStringAsFixed(1)} '
    'right=${rect.right.toStringAsFixed(1)} '
    'bottom=${rect.bottom.toStringAsFixed(1)}';

void _expectNoAppBar(WidgetTester tester, String localeName) {
  expect(
    find.descendant(of: find.byType(HomeScreen), matching: find.byType(AppBar)),
    findsNothing,
    reason: 'HomeScreen must build no AppBar ($localeName)',
  );
}

/// Top edge within [kSpace2] + 1 of the safe area top, end edge within
/// [kSpace2] + 1 of the view's end edge, at least 48 x 48, and not a
/// descendant of the home [SingleChildScrollView].
void _expectLocaleCorner(WidgetTester tester, String localeName) {
  final Finder toggle = find.byKey(_localeKey);
  expect(
    toggle,
    findsOneWidget,
    reason:
        '$localeName fixture: locale-toggle-button must be on screen '
        'before its corner can be measured',
  );

  final Rect rect = tester.getRect(toggle);
  final BuildContext context = tester.element(toggle);
  final double safeTop = MediaQuery.paddingOf(context).top;
  final double viewWidth =
      tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final bool ltr = Directionality.of(context) == TextDirection.ltr;
  final double endGap = ltr ? viewWidth - rect.right : rect.left;
  final double topGap = (rect.top - safeTop).abs();

  expect(
    topGap,
    lessThanOrEqualTo(kSpace2 + 1),
    reason:
        '$localeName: locale-toggle-button top must be within '
        '${kSpace2 + 1} of the safe area top $safeTop; '
        'top gap was $topGap, rect ${_formatRect(rect)}',
  );
  expect(
    endGap,
    lessThanOrEqualTo(kSpace2 + 1),
    reason:
        '$localeName: locale-toggle-button end edge must be within '
        '${kSpace2 + 1} of the view end '
        '(${ltr ? 'right' : 'left'}); end gap was $endGap, '
        'rect ${_formatRect(rect)}, view width $viewWidth',
  );
  expect(
    rect.width,
    greaterThanOrEqualTo(48),
    reason:
        '$localeName: locale-toggle-button width must be at least 48; '
        'rect ${_formatRect(rect)}',
  );
  expect(
    rect.height,
    greaterThanOrEqualTo(48),
    reason:
        '$localeName: locale-toggle-button height must be at least 48; '
        'rect ${_formatRect(rect)}',
  );
  expect(
    find.ancestor(of: toggle, matching: find.byType(SingleChildScrollView)),
    findsNothing,
    reason:
        '$localeName: locale-toggle-button must sit outside the '
        'SingleChildScrollView so it never scrolls away',
  );
}

void main() {
  testWidgets('en: HomeScreen builds no AppBar', (tester) async {
    _usePhone(tester);
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    expect(
      find.byType(HomeScreen),
      findsOneWidget,
      reason: 'en fixture: LudoApp must mount one HomeScreen',
    );
    _expectNoAppBar(tester, 'en');
  });

  testWidgets('ar: HomeScreen builds no AppBar', (tester) async {
    _usePhone(tester);
    await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
    await tester.pumpAndSettle();

    expect(
      find.byType(HomeScreen),
      findsOneWidget,
      reason: 'ar fixture: LudoApp must mount one HomeScreen',
    );
    expect(
      Directionality.of(tester.element(find.byType(HomeScreen))),
      TextDirection.rtl,
      reason: 'ar fixture: HomeScreen must be rtl',
    );
    _expectNoAppBar(tester, 'ar');
  });

  testWidgets(
    'en: locale toggle sits at the top end corner, at least 48 by 48, '
    'outside the scroll view',
    (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      _expectLocaleCorner(tester, 'en');
    },
  );

  testWidgets(
    'ar: locale toggle sits at the top end corner, at least 48 by 48, '
    'outside the scroll view',
    (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const LudoApp(initialLocale: Locale('ar')));
      await tester.pumpAndSettle();

      expect(
        Directionality.of(tester.element(find.byType(HomeScreen))),
        TextDirection.rtl,
        reason: 'ar fixture: the end edge is the left edge only when rtl',
      );
      _expectLocaleCorner(tester, 'ar');
    },
  );

  testWidgets('closed disclosure shows Icons.tune and the text '
      '"4 players, standard rules"', (tester) async {
    _usePhone(tester);
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    final Finder disclosure = find.byKey(_disclosureKey);
    expect(
      disclosure,
      findsOneWidget,
      reason:
          'fixture: home-players-disclosure must be on screen while '
          'the players selector is closed',
    );
    expect(
      find.descendant(of: disclosure, matching: find.byIcon(Icons.tune)),
      findsOneWidget,
      reason: 'home-players-disclosure must contain a leading Icons.tune',
    );
    expect(
      find.descendant(
        of: disclosure,
        matching: find.text('4 players, standard rules'),
      ),
      findsOneWidget,
      reason:
          'home-players-disclosure must still show the text '
          '"4 players, standard rules"',
    );
  });
}
