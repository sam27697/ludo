// Home rules scroll conformance suite, work order 210, paired with work
// order 209 (the fix, a different worker, same round, disjoint files).
//
// Capture 13 on the CI emulator showed a returning player open Home's
// players/rules disclosure (home-players-disclosure) with create-room-button
// already tight against the bottom of the screen: opening the two rule
// switches (home-rule-blocks, home-rule-capture-bonus) pushes Create Room
// off the bottom edge, and nothing on this base ever scrolls it back. The
// shared contract (both orders): once home-players-disclosure is tapped and
// the rules/switches are on screen, the home scroll view scrolls with
// ScrollPositionAlignmentPolicy.keepVisibleAtEnd on create-room-button --
// bottom edge to the viewport's bottom edge, within 1 logical pixel, only
// when the button is not already fully in view, instant under
// MediaQuery.disableAnimations, animated over kLinkScrollDuration
// (lib/src/home_screen.dart) otherwise.
//
// Written against lib/src/home_screen.dart as it stands on base commit
// 2e26b91: the body is one SingleChildScrollView with no controller and
// nothing that ever calls animateTo/jumpTo/ensureVisible on it from the
// rules disclosure. RS-1, RS-2, RS-3 and RS-4 are therefore expected to
// fail here, on the final in-view assertion, each with a reason naming its
// own case id. RS-5 and RS-6 are controls and are expected to pass here
// already, and must keep passing after order 209 lands.
//
// Every case in this file mounts HomeScreen the same way
// test/home_link_scroll_test.dart does (fixed surface via
// tester.view.physicalSize / devicePixelRatio with addTearDown resets, a
// multi-pump settle helper, fixture checks before the assertion that
// matters); the mounting widget and both settle/fixture helpers below are
// copied from that file's approach rather than imported, per this order's
// own file list ("copy what you need; do not import from another test").

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- fixed test surfaces ----------------------------------------------
//
// RS-1..RS-4 mount at 360x420... no: at 360x600 (devicePixelRatio 1.0).
// Measured against this HomeScreen tree at that size:
//
//   - rules closed, one settled frame: create-room-button
//     Rect(left: 24.0, top: 390.5, right: 336.0, bottom: 438.5) -- fully
//     inside a 600-tall viewport.
//   - rules open (home-players-disclosure tapped), the very next frame,
//     before any scroll: create-room-button
//     Rect(left: 24.0, top: 610.4, right: 336.0, bottom: 658.4) -- bottom
//     658.4 > 600, below the fold.
//
// The same booleans (closed: fully in view; open, prescroll: not fully in
// view) hold at this same surface once the entrance motion or the seeded
// store shift the exact numbers:
//
//   - RS-4 (MediaQuery.disableAnimations true, entrance motion already
//     settled at mount instead of mid-flight): closed
//     Rect(24.0, 373.0, 336.0, 421.0); open, prescroll
//     Rect(24.0, 578.0, 336.0, 626.0).
//   - RS-2 (seeded SharedPreferences: a stored seat record and a stored
//     last-table, which add home-rejoin-button above home-name-field and
//     home-last-table-chip below the rules): closed
//     Rect(24.0, 465.2, 336.0, 513.2); open, prescroll
//     Rect(24.0, 728.1, 336.0, 776.1).
//
// Every case below reasserts its own two rects as fixture checks rather
// than trusting this comment to still be true of whatever HomeScreen
// becomes, per this order's own requirement.
//
// RS-5 (the control surface) mounts at 360x880 (devicePixelRatio 1.0).
// Measured the same way: with the rules open and settled, create-room-button
// sits at Rect(24.0, 823.8, 336.0, 871.8) -- fully inside an 880-tall
// viewport -- while join-room-button, further down the same column, sits at
// Rect(24.0, 928.0, 336.0, 976.0), below the fold, giving the home scroll
// view a maxScrollExtent of 128.0 logical pixels: tall enough that Create
// Room never needs a scroll, short enough that the view still has one to
// give.
const Size _kSurfaceSize = Size(360, 600);
const double _kSurfaceDevicePixelRatio = 1.0;

const Size _kControlSurfaceSize = Size(360, 880);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = _kSurfaceDevicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

double _viewHeight(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio;

/// Settles the tree after the rules disclosure has been opened, giving any
/// post-frame-triggered scroll animation real elapsed frames to run.
///
/// A single long pump does not do this: a [Ticker] measures elapsed time
/// from its own first frame, and a post-frame callback that starts a scroll
/// animation only ticks for the first time on the pump after the one that
/// ran that callback. A lone `pump(const Duration(milliseconds: 500))` right
/// after the tap is therefore that animation's first frame, at zero elapsed
/// time, no matter how long the pump's own duration is. Ten 100 ms pumps
/// after the initial pump give it ten frames to advance across instead,
/// well past a 300 ms ease-out.
Future<void> _settleAfterRulesOpen(WidgetTester tester) async {
  await tester.pump();
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps [HomeScreen] the same way [LudoApp] assembles one (same
/// localizationsDelegates and supportedLocales), with a forced [locale] for
/// RS-3 and, for RS-4, [disableAnimations] to force
/// [MediaQuery.disableAnimationsOf] true above [HomeScreen] without
/// disturbing the ambient [MediaQuery] the test surface itself installs.
Widget _homeScreenApp({Locale? locale, bool disableAnimations = false}) {
  final Widget home = HomeScreen(onToggleLocale: () {});
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: disableAnimations
        ? Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: home,
            ),
          )
        : home,
  );
}

// --- viewport geometry ---------------------------------------------------

bool _fullyInView(Rect rect, double viewHeight) =>
    rect.top >= 0 && rect.bottom <= viewHeight;

/// Formats [rect] as `left/top/right/bottom`, each to one decimal place, so
/// a failure reason is legible without depending on [Rect.toString].
String _formatRect(Rect rect) =>
    'left=${rect.left.toStringAsFixed(1)} '
    'top=${rect.top.toStringAsFixed(1)} '
    'right=${rect.right.toStringAsFixed(1)} '
    'bottom=${rect.bottom.toStringAsFixed(1)}';

/// The [ScrollPosition] of the home screen's own scroll view, found by
/// walking up from room-code-field to its nearest ancestor [Scrollable].
/// Looking this up from a widget known to sit directly in that scroll
/// view's Column avoids the several other, unrelated Scrollables that live
/// further down the tree (each TextField's own EditableText owns one, for
/// its horizontal cursor scrolling).
ScrollPosition _homeScrollPosition(WidgetTester tester) {
  final BuildContext context = tester.element(
    find.byKey(const Key('room-code-field')),
  );
  return Scrollable.of(context).position;
}

/// Fixture check: create-room-button must already be fully in view before
/// the rules are opened, or the case that follows measures nothing.
void _expectCreateButtonFullyInViewClosed(WidgetTester tester, String caseId) {
  final Rect rect = tester.getRect(find.byKey(const Key('create-room-button')));
  final double viewHeight = _viewHeight(tester);
  expect(
    _fullyInView(rect, viewHeight),
    isTrue,
    reason:
        '$caseId fixture check: create-room-button must already be fully in '
        'view with the rules closed, or this case measures nothing; got '
        '${_formatRect(rect)} against a viewport '
        '${viewHeight.toStringAsFixed(1)} logical pixels tall.',
  );
}

/// Fixture check: create-room-button must not be fully in view the instant
/// the rules open, before any scroll has had a chance to run, or the case
/// measures nothing.
void _expectCreateButtonNotFullyInViewBeforeScroll(
  WidgetTester tester,
  String caseId,
) {
  final Rect rect = tester.getRect(find.byKey(const Key('create-room-button')));
  final double viewHeight = _viewHeight(tester);
  expect(
    _fullyInView(rect, viewHeight),
    isFalse,
    reason:
        '$caseId fixture check: create-room-button must not already be '
        'fully in view the instant the rules open, before any scroll; got '
        '${_formatRect(rect)} against a viewport '
        '${viewHeight.toStringAsFixed(1)} logical pixels tall. This file '
        'mounts at the size it does specifically to keep the button below '
        'the fold once the rules are open -- if lib/ has changed the '
        'default layout enough that this no longer holds, the surface '
        'needs to change, not this check removed.',
  );
}

/// The in-view assertion RS-1, RS-2 and RS-3 must reach once the home
/// scroll view has (or, on base 2e26b91, has not) reacted to the rules
/// opening: create-room-button fully inside the viewport, and its bottom
/// edge within 1 logical pixel of the viewport's own bottom edge.
void _expectCreateButtonScrolledIntoView(WidgetTester tester, String caseId) {
  final Rect rect = tester.getRect(find.byKey(const Key('create-room-button')));
  final double viewHeight = _viewHeight(tester);
  expect(
    _fullyInView(rect, viewHeight),
    isTrue,
    reason:
        '$caseId: expected create-room-button fully inside the viewport '
        '(top >= 0 and bottom <= ${viewHeight.toStringAsFixed(1)}) once the '
        'home scroll view has reacted to opening the rules; got '
        '${_formatRect(rect)}.',
  );
  final double bottomGap = (rect.bottom - viewHeight).abs();
  expect(
    bottomGap,
    lessThanOrEqualTo(1.0),
    reason:
        '$caseId: expected create-room-button\'s bottom edge within 1.0 '
        'logical pixel of the viewport bottom '
        '(${viewHeight.toStringAsFixed(1)}) once the home scroll view has '
        'reacted to opening the rules; got ${_formatRect(rect)}, '
        '|bottom - viewHeight| = ${bottomGap.toStringAsFixed(1)}.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'RS-1 (en, overflow): opening the rules scrolls create-room-button '
    'into view',
    (tester) async {
      _useSurface(tester, _kSurfaceSize);

      await tester.pumpWidget(_homeScreenApp());
      await tester.pump();

      _expectCreateButtonFullyInViewClosed(tester, 'RS-1');

      await tester.tap(find.byKey(const Key('home-players-disclosure')));
      await tester.pump();

      _expectCreateButtonNotFullyInViewBeforeScroll(tester, 'RS-1');

      await _settleAfterRulesOpen(tester);

      _expectCreateButtonScrolledIntoView(tester, 'RS-1');
    },
  );

  testWidgets(
    'RS-2 (en, returning player): a seeded rejoin button and last-table '
    'chip still leave create-room-button reachable after the scroll',
    (tester) async {
      // The exact Home the CI emulator showed in capture 13: a stored seat
      // (SeatRecord, read by lib/src/session_memory.dart into
      // SessionMemory.seatRecord) shows home-rejoin-button, and a stored
      // last successful create shows the last-table chip, both above and
      // around the controls RS-1 already exercises -- seeded the same way
      // test/home_rejoin_test.dart and test/home_session_memory_test.dart
      // seed them, by writing through SessionMemory's own static writers
      // before HomeScreen is ever mounted.
      await SessionMemory.recordSeat(
        const SeatRecord(
          code: 'K7M2QP',
          seat: 2,
          seatToken: 'tok-rs2-seed-001',
        ),
      );
      await SessionMemory.recordSuccessfulCreate(name: 'Priya', seats: 2);

      _useSurface(tester, _kSurfaceSize);

      await tester.pumpWidget(_homeScreenApp());
      await tester.pump();

      expect(
        find.byKey(const Key('home-rejoin-button')),
        findsOneWidget,
        reason:
            'RS-2 fixture check: a stored seat record must show '
            'home-rejoin-button before this case can measure anything '
            'about the rules scroll',
      );

      _expectCreateButtonFullyInViewClosed(tester, 'RS-2');

      await tester.tap(find.byKey(const Key('home-players-disclosure')));
      await tester.pump();

      _expectCreateButtonNotFullyInViewBeforeScroll(tester, 'RS-2');

      await _settleAfterRulesOpen(tester);

      _expectCreateButtonScrolledIntoView(tester, 'RS-2');
    },
  );

  testWidgets('RS-3 (ar): RS-1 in Arabic, RTL', (tester) async {
    _useSurface(tester, _kSurfaceSize);

    await tester.pumpWidget(_homeScreenApp(locale: const Locale('ar')));
    await tester.pump();

    _expectCreateButtonFullyInViewClosed(tester, 'RS-3');

    await tester.tap(find.byKey(const Key('home-players-disclosure')));
    await tester.pump();

    _expectCreateButtonNotFullyInViewBeforeScroll(tester, 'RS-3');

    await _settleAfterRulesOpen(tester);

    _expectCreateButtonScrolledIntoView(tester, 'RS-3');
  });

  testWidgets(
    'RS-4 (reduced motion): MediaQuery.disableAnimations true scrolls '
    'create-room-button into view within two pumps, with no duration',
    (tester) async {
      _useSurface(tester, _kSurfaceSize);

      await tester.pumpWidget(_homeScreenApp(disableAnimations: true));
      await tester.pump();

      _expectCreateButtonFullyInViewClosed(tester, 'RS-4');

      await tester.tap(find.byKey(const Key('home-players-disclosure')));
      // Exactly two pump() calls, no duration on either: this is what
      // separates a Duration.zero scroll (done within a couple of frames,
      // no elapsed animation time needed) from an animated one, which RS-1
      // needs a real multi-frame settle to finish.
      await tester.pump();
      await tester.pump();

      final Rect rect = tester.getRect(
        find.byKey(const Key('create-room-button')),
      );
      final double viewHeight = _viewHeight(tester);
      expect(
        _fullyInView(rect, viewHeight),
        isTrue,
        reason:
            'RS-4: expected create-room-button fully inside the viewport '
            '(top >= 0 and bottom <= ${viewHeight.toStringAsFixed(1)}) '
            'within two zero-duration pumps of opening the rules under '
            'MediaQuery.disableAnimations true; got ${_formatRect(rect)}.',
      );
    },
  );

  testWidgets(
    'RS-5 (control, no needless scroll): create-room-button already fully '
    'in view once the rules are open leaves the scroll offset unmoved',
    (tester) async {
      _useSurface(tester, _kControlSurfaceSize);

      await tester.pumpWidget(_homeScreenApp());
      await tester.pump();

      final double pixelsBeforeTap = _homeScrollPosition(tester).pixels;

      await tester.tap(find.byKey(const Key('home-players-disclosure')));
      await _settleAfterRulesOpen(tester);

      final Rect rect = tester.getRect(
        find.byKey(const Key('create-room-button')),
      );
      final double viewHeight = _viewHeight(tester);
      expect(
        _fullyInView(rect, viewHeight),
        isTrue,
        reason:
            'RS-5 fixture check: create-room-button must already be fully '
            'in view once the rules are open at this surface, or this case '
            'measures nothing; got ${_formatRect(rect)} against a viewport '
            '${viewHeight.toStringAsFixed(1)} logical pixels tall.',
      );

      final ScrollPosition position = _homeScrollPosition(tester);
      expect(
        position.maxScrollExtent,
        greaterThan(0.0),
        reason:
            'RS-5 fixture check: the home scroll view must still have '
            'scroll extent to give (maxScrollExtent > 0) once the rules '
            'are open, or this case cannot tell a scroll aimed at nothing '
            'from a home screen with nothing left to scroll; got '
            '${position.maxScrollExtent}.',
      );

      final double pixelsAfterSettle = position.pixels;
      expect(
        pixelsAfterSettle,
        pixelsBeforeTap,
        reason:
            'RS-5: the home scroll offset must be identical before opening '
            'the rules ($pixelsBeforeTap) and after ($pixelsAfterSettle), '
            'since create-room-button was already fully in view once they '
            'opened; a scroll that always aligns the button\'s bottom to '
            'the viewport bottom (alignment: 1.0, with no already-in-view '
            'guard) or a scroll aimed at the wrong widget both fail exactly '
            'this case',
      );
    },
  );

  testWidgets(
    'RS-6 (control, switches do not scroll): toggling home-rule-blocks '
    'after the rules are open does not move the home scroll offset',
    (tester) async {
      _useSurface(tester, _kSurfaceSize);

      await tester.pumpWidget(_homeScreenApp());
      await tester.pump();

      await tester.tap(find.byKey(const Key('home-players-disclosure')));
      await _settleAfterRulesOpen(tester);

      final Finder switchFinder = find.byKey(const Key('home-rule-blocks'));
      expect(
        switchFinder.hitTestable(),
        findsOneWidget,
        reason:
            'RS-6 fixture check: home-rule-blocks must be hit-testable '
            'once the rules disclosure has opened and settled, or this '
            'case cannot reach the tap it needs to measure; if RS-1\'s own '
            'settle on this base leaves the switch off screen, that is '
            'this fixture check failing, and this case is not rewritten '
            'to make it pass',
      );

      final ScrollPosition position = _homeScrollPosition(tester);
      final double pixelsBeforeSwitchTap = position.pixels;

      await tester.tap(switchFinder);
      await _settleAfterRulesOpen(tester);

      final double pixelsAfterSwitchTap = position.pixels;
      expect(
        pixelsAfterSwitchTap,
        pixelsBeforeSwitchTap,
        reason:
            'RS-6: the home scroll offset must be identical before tapping '
            'home-rule-blocks ($pixelsBeforeSwitchTap) and after '
            '($pixelsAfterSwitchTap); a rule switch is not the rules '
            'disclosure and must never trigger the create-room-button '
            'scroll',
      );

      final SwitchListTile switchTile = tester.widget<SwitchListTile>(
        switchFinder,
      );
      expect(
        switchTile.value,
        isFalse,
        reason:
            'RS-6 fixture check: tapping home-rule-blocks must flip its '
            'SwitchListTile.value to false (it defaults true), or the tap '
            'above never actually reached the switch',
      );
    },
  );
}
