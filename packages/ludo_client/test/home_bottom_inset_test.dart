// Home bottom-inset conformance suite, work order 195, paired with work
// order 196 (the fix, a different worker, same round, disjoint files).
//
// Device-smoke run 36222804345 (API 36, edge-to-edge, gesture navigation)
// watched the system gesture pill draw over the "Join Room" label after a
// room link scrolled Join Room to the bottom of the home viewport.
// home_screen.dart has no SafeArea; the lobby and game screens already do.
// The shared contract (both orders): HomeScreen keeps its content out of
// the bottom system inset the way LobbyScreen and GameScreen already do,
// whether the last control on screen got there from a link's scroll or
// from a player dragging the home scroll view to its end by hand, and the
// felt backdrop still fills the whole view regardless -- the inset must
// keep content off the gesture bar, not leave a bare strip under it.
//
// Written against lib/src/home_screen.dart as it stands before order 196:
// FeltBackdrop's child is a bare SingleChildScrollView with no SafeArea
// anywhere in the tree. IN-LINK, IN-END and IN-AR are therefore expected to
// fail here, on the bottom-inset bound, each with a reason naming its own
// case id. IN-BACKDROP and IN-ZERO are expected to pass here already, and
// must keep passing after order 196 lands: IN-BACKDROP is what catches a
// fix that insets the backdrop itself instead of only the content inside
// it, and IN-ZERO is what catches a fix that changes today's zero-inset
// behaviour (order 194's scroll-into-view) instead of leaving it alone.
//
// Every case in this file mounts HomeScreen the same way
// test/home_link_scroll_test.dart does (linkStream injected); the fake
// link-stream-opener class and the code-field readers below are copied
// from that file rather than imported, per this order's own file list.
// That file's fake initial-link-reader class is not copied here: every
// case in this file delivers its link (if any) on the warm-start path, so
// a cold-start fake would sit in this file unused, and an unused private
// class fails `dart analyze` (unused_element) -- see this file's own
// report for the full note.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/theme.dart' show FeltBackdrop;

// --- fixed test surface and inset ------------------------------------------

const Size _kSurfaceSize = Size(360, 420);
const double _kSurfaceDevicePixelRatio = 1.0;

/// The bottom system view padding this whole file measures against: a
/// gesture-navigation pill under an edge-to-edge app, per this order's own
/// device-smoke run. Zero padding (IN-ZERO) must change nothing from
/// today's behaviour.
const double _kBottomInset = 48;

/// Sets the surface every case in this file mounts at, and the bottom view
/// padding under test, then registers the reset every case needs: a view
/// reset is not a timer (standing lesson 9 does not apply to it), so one
/// `addTearDown(tester.view.reset)` per case is enough.
void _useInsetSurface(WidgetTester tester, {required double bottomInset}) {
  tester.view.physicalSize = _kSurfaceSize;
  tester.view.devicePixelRatio = _kSurfaceDevicePixelRatio;
  if (bottomInset > 0) {
    final FakeViewPadding inset = FakeViewPadding(bottom: bottomInset);
    tester.view.padding = inset;
    tester.view.viewPadding = inset;
  }
  addTearDown(tester.view.reset);
}

double _viewHeight(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio;

/// Settles the tree after a link has been delivered, or after a drag has
/// been released, giving any ticker-driven animation real elapsed frames to
/// run.
///
/// A single long pump does not do this: a [Ticker] measures elapsed time
/// from its own first frame, whether that ticker drives
/// [Scrollable.ensureVisible]'s post-frame scroll (IN-LINK, IN-AR) or the
/// ballistic simulation a released drag hands to the scroll position
/// (IN-END). Either way, the pump that starts the ticker is that ticker's
/// first frame, at zero elapsed time, no matter how long that one pump's
/// own duration is (standing lesson 36). Ten 100 ms pumps after the initial
/// pump give it ten frames to advance across instead, well past either a
/// 300 ms ease-out or a fling's settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

// --- shared fixtures, copied from test/home_link_scroll_test.dart, --------
// --- not imported -----------------------------------------------------------

/// A [LinkStreamOpener] backed by a broadcast [StreamController], so a test
/// can push a warm-start link onto the exact stream HomeScreen already
/// subscribed to.
class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  Stream<Uri> call() => _controller.stream;

  void add(Uri uri) => _controller.add(uri);
}

/// Pumps [HomeScreen] the same way [LudoApp] assembles one (same
/// localizationsDelegates and supportedLocales), with a substitutable
/// [linkStream] and, for IN-AR, a forced [locale].
Widget _homeScreenApp({
  LinkStreamOpener linkStream = noLinkStream,
  Locale? locale,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(onToggleLocale: () {}, linkStream: linkStream),
  );
}

TextField _codeField(WidgetTester tester) {
  return tester.widget<TextField>(find.byKey(const Key('room-code-field')));
}

String _codeFieldText(WidgetTester tester) =>
    _codeField(tester).controller!.text;

/// A well-formed link on this app's own host, shaped `/r/<code>`.
Uri _roomLink(String code) => Uri.parse('https://$kAppLinkHost/r/$code');

/// The home screen's own scroll view, found by walking up from
/// room-code-field to its nearest ancestor [Scrollable] -- the same lookup
/// test/home_link_scroll_test.dart uses to find that scroll view's
/// [ScrollPosition], copied here to find the [Scrollable] widget itself so
/// IN-END can drag it directly rather than guess at it by type (a guess
/// that would also catch a TextField's own internal horizontal-scrolling
/// Scrollable, since more than one exists in this tree).
Scrollable _homeScrollable(WidgetTester tester) {
  final BuildContext context = tester.element(
    find.byKey(const Key('room-code-field')),
  );
  return Scrollable.of(context).widget;
}

// --- fixture and bound assertions -------------------------------------------

/// The fixture check every IN-LINK / IN-END / IN-AR case runs before
/// asserting its bound: the bottom inset under test must really be in
/// effect, read via [MediaQuery.paddingOf] from the [Scaffold]'s own
/// context (above anything HomeScreen's body might do with it), or the
/// case that follows measures nothing.
void _expectInsetInEffect(
  WidgetTester tester,
  String caseId,
  double bottomInset,
) {
  final BuildContext context = tester.element(find.byType(Scaffold));
  final double actual = MediaQuery.paddingOf(context).bottom;
  expect(
    actual,
    bottomInset,
    reason:
        '$caseId fixture check: MediaQuery.paddingOf read from the '
        "Scaffold's context must report bottom padding $bottomInset before "
        'this case can measure anything about the inset; got $actual. '
        'tester.view.padding and tester.view.viewPadding must both carry '
        'FakeViewPadding(bottom: $bottomInset) at devicePixelRatio '
        '$_kSurfaceDevicePixelRatio on a $_kSurfaceSize surface.',
  );
}

/// Asserts [key]'s widget bottom lies at or above the inset boundary
/// (`view height - bottomInset`), the way [LobbyScreen] and [GameScreen]'s
/// own [SafeArea] already keeps their own last controls off the bottom
/// system inset.
void _expectBottomWithinInset(
  WidgetTester tester, {
  required Key key,
  required String caseId,
  required String elementLabel,
  required double bottomInset,
}) {
  final Rect rect = tester.getRect(find.byKey(key));
  final double viewHeight = _viewHeight(tester);
  final double bound = viewHeight - bottomInset;
  expect(
    rect.bottom,
    lessThanOrEqualTo(bound),
    reason:
        '$caseId: expected $elementLabel bottom <= $bound (view height '
        '$viewHeight minus bottom inset $bottomInset), the way LobbyScreen '
        "and GameScreen's own SafeArea already keeps their last controls "
        'off the system gesture inset; got rect $rect. Reproduce at surface '
        '$_kSurfaceSize, devicePixelRatio $_kSurfaceDevicePixelRatio, bottom '
        'inset $bottomInset.',
  );
}

void main() {
  testWidgets(
    'IN-LINK: a warm valid link keeps join-room-button out of a 48px bottom '
    'inset',
    (tester) async {
      _useInsetSurface(tester, bottomInset: _kBottomInset);
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();

      _expectInsetInEffect(tester, 'IN-LINK', _kBottomInset);

      opener.add(_roomLink('H4XR9T'));
      await _settle(tester);

      expect(
        _codeFieldText(tester),
        'H4XR9T',
        reason:
            'IN-LINK fixture: the warm-start link must still have '
            'pre-filled the code field before this case can measure '
            "whether join-room-button also stayed out of the inset",
      );
      _expectBottomWithinInset(
        tester,
        key: const Key('join-room-button'),
        caseId: 'IN-LINK',
        elementLabel: 'join-room-button',
        bottomInset: _kBottomInset,
      );
    },
  );

  testWidgets(
    'IN-END: dragging home to its end keeps the last control out of a 48px '
    'bottom inset',
    (tester) async {
      _useInsetSurface(tester, bottomInset: _kBottomInset);

      await tester.pumpWidget(_homeScreenApp());
      await tester.pump();

      _expectInsetInEffect(tester, 'IN-END', _kBottomInset);

      // Read: with no link delivered and no platform storage available in
      // a widget test (SessionMemory.load's own documented empty-snapshot
      // fallback), _recentCodes stays empty and the seat-rejoin chip never
      // appears, so the KeyedSubtree wrapping join-room-button is the last
      // control the Column in home_screen.dart's build renders. A large
      // negative dy drags the scroll view past its max scroll extent, so
      // the physics settle at the end regardless of exactly how far short
      // of that a single drag falls.
      await tester.drag(
        find.byWidget(_homeScrollable(tester)),
        const Offset(0, -10000),
      );
      await _settle(tester);

      _expectBottomWithinInset(
        tester,
        key: const Key('join-room-button'),
        caseId: 'IN-END',
        elementLabel:
            'join-room-button (the last control home_screen.dart renders '
            'with no recent codes stored)',
        bottomInset: _kBottomInset,
      );
    },
  );

  testWidgets(
    'IN-BACKDROP: FeltBackdrop still fills the whole view with a 48px '
    'bottom inset',
    (tester) async {
      _useInsetSurface(tester, bottomInset: _kBottomInset);

      await tester.pumpWidget(_homeScreenApp());
      await tester.pump();

      final Rect rect = tester.getRect(find.byType(FeltBackdrop));
      final double viewHeight = _viewHeight(tester);
      expect(
        rect.bottom,
        viewHeight,
        reason:
            'IN-BACKDROP: FeltBackdrop must still fill the whole view '
            '(bottom == $viewHeight) with a bottom inset in effect -- '
            'keeping content out of the inset must not leave a bare strip '
            'of unfilled view under the gesture bar; got rect $rect against '
            'a view $viewHeight logical pixels tall.',
      );
    },
  );

  testWidgets(
    "IN-ZERO: a warm valid link keeps join-room-button in view with no "
    "inset (today's behaviour)",
    (tester) async {
      _useInsetSurface(tester, bottomInset: 0);
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();

      opener.add(_roomLink('H4XR9T'));
      await _settle(tester);

      expect(
        _codeFieldText(tester),
        'H4XR9T',
        reason:
            'IN-ZERO fixture: the warm-start link must still have '
            'pre-filled the code field before this case can measure '
            "whether join-room-button stayed in view",
      );
      _expectBottomWithinInset(
        tester,
        key: const Key('join-room-button'),
        caseId: 'IN-ZERO',
        elementLabel: 'join-room-button',
        bottomInset: 0,
      );
    },
  );

  testWidgets('IN-AR: IN-LINK in Locale(ar)', (tester) async {
    _useInsetSurface(tester, bottomInset: _kBottomInset);
    final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

    await tester.pumpWidget(
      _homeScreenApp(linkStream: opener.call, locale: const Locale('ar')),
    );
    await tester.pump();

    _expectInsetInEffect(tester, 'IN-AR', _kBottomInset);

    opener.add(_roomLink('H4XR9T'));
    await _settle(tester);

    expect(
      _codeFieldText(tester),
      'H4XR9T',
      reason:
          'IN-AR fixture: the warm-start link must still have pre-filled '
          'the code field in the Arabic locale before this case can '
          "measure whether join-room-button also stayed out of the inset",
    );
    _expectBottomWithinInset(
      tester,
      key: const Key('join-room-button'),
      caseId: 'IN-AR',
      elementLabel: 'join-room-button',
      bottomInset: _kBottomInset,
    );
  });
}
