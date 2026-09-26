// Home link scroll conformance suite, work order 193, paired with work
// order 194 (the fix, a different worker, same round, disjoint files).
//
// Run 57 watched a room link arrive on an Android 16 emulator: the code
// lands in the room code field, but that field sits at the bottom edge of
// the screen and Join Room is below the fold. The shared contract (both
// orders): once HomeScreen has applied a link that isAppRoomLinkUri
// accepts, cold (initialLinkReader) or warm (linkStream), the home scroll
// view must scroll so join-room-button (a valid code) or room-code-field
// (an invalid one) lies fully inside the viewport. A link that is not a
// room link at all must not move the scroll offset at all.
//
// Written against lib/src/home_screen.dart as it stands before order 194:
// the body is one SingleChildScrollView with no controller and nothing
// that ever calls animateTo/jumpTo on it. LS-COLD, LS-WARM, LS-BAD and
// LS-AR are therefore expected to fail here, on the in-view assertion,
// each with a reason naming its own case id. LS-FOREIGN is expected to
// pass here already, and must keep passing after order 194 lands: it is
// what catches a fix that scrolls on every link instead of only a room
// link's.
//
// Every case in this file mounts HomeScreen the same way
// test/home_screen_link_error_test.dart and test/home_screen_code_error_test
// .dart do (initialLinkReader / linkStream injected); the two fake-reader
// and fake-stream-opener classes below are copied from those files rather
// than imported, per this order's own file list.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';

// --- fixed test surface --------------------------------------------------
//
// The default widget-test surface (800x600 logical pixels) already shows
// join-room-button in full: measured against this same HomeScreen tree,
// pumped with no link and settled, join-room-button's rect is
// Rect.fromLTRB(224.0, 468.0, 576.0, 516.0), comfortably inside a viewport
// 600 logical pixels tall (bottom 516 <= 600). A case run at that size
// would prove nothing, per this order's own fixture-check requirement.
//
// 360x420 (devicePixelRatio 1.0) does not: measured the same way, the same
// button settles at Rect.fromLTRB(24.0, 438.0, 336.0, 486.0), 66 logical
// pixels below a viewport only 420 tall (bottom 486 > 420). That is the
// size every case in this file mounts at, and every case reasserts it with
// its own fixture check below before delivering a link, rather than
// trusting this comment to still be true of whatever HomeScreen becomes.
const Size _kSurfaceSize = Size(360, 420);
const double _kSurfaceDevicePixelRatio = 1.0;

void _useFoldedSurface(WidgetTester tester) {
  tester.view.physicalSize = _kSurfaceSize;
  tester.view.devicePixelRatio = _kSurfaceDevicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

double _viewHeight(WidgetTester tester) =>
    tester.view.physicalSize.height / tester.view.devicePixelRatio;

// --- shared fixtures, copied from test/home_screen_link_error_test.dart --
// --- and test/home_screen_code_error_test.dart, not imported --------------

/// An [InitialLinkReader] whose future is held open by a [Completer] until
/// the test completes it, so the cold-start read can be driven after the
/// first frame the same way a real platform channel response would arrive.
class _FakeInitialLinkReader {
  final Completer<Uri?> _completer = Completer<Uri?>();

  Future<Uri?> call() => _completer.future;

  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }
}

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
/// [initialLinkReader], [linkStream] and, for LS-AR, a forced [locale].
Widget _homeScreenApp({
  InitialLinkReader initialLinkReader = noInitialLink,
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
    home: HomeScreen(
      onToggleLocale: () {},
      initialLinkReader: initialLinkReader,
      linkStream: linkStream,
    ),
  );
}

TextField _codeField(WidgetTester tester) {
  return tester.widget<TextField>(find.byKey(const Key('room-code-field')));
}

String _codeFieldText(WidgetTester tester) =>
    _codeField(tester).controller!.text;

String? _codeFieldError(WidgetTester tester) =>
    _codeField(tester).decoration?.errorText;

// --- link fixtures ---------------------------------------------------------

/// A well-formed link on this app's own host, shaped `/r/<code>`.
Uri _roomLink(String code) => Uri.parse('https://$kAppLinkHost/r/$code');

/// A link shaped exactly like a room link but on a host that is not
/// [kAppLinkHost], so [isAppRoomLinkUri] returns false for it: never a room
/// link at all, as opposed to a room link with a bad code.
Uri _foreignLink(String code) => Uri.parse('https://example.com/r/$code');

// --- viewport geometry ------------------------------------------------------

bool _fullyInView(Rect rect, double viewHeight) =>
    rect.top >= 0 && rect.bottom <= viewHeight;

/// The fixture check every case in this file runs before delivering its
/// link: join-room-button must not already be fully in the viewport, or
/// the case that follows measures nothing (this order's own requirement).
void _expectButtonBelowFold(WidgetTester tester, String caseId) {
  final Rect rect = tester.getRect(find.byKey(const Key('join-room-button')));
  final double viewHeight = _viewHeight(tester);
  expect(
    _fullyInView(rect, viewHeight),
    isFalse,
    reason:
        '$caseId fixture check: join-room-button must not already be fully '
        'in view before any link is delivered, or this case measures '
        'nothing; got rect $rect against a viewport $viewHeight logical '
        'pixels tall. This file mounts at $_kSurfaceSize (devicePixelRatio '
        '$_kSurfaceDevicePixelRatio) specifically to keep the button below '
        'the fold -- if lib/ has changed the default layout enough that '
        'this no longer holds, that size needs to shrink further, not this '
        'check removed.',
  );
}

/// Asserts [key]'s widget lies fully inside the viewport once the home
/// scroll view has (or, on this base, has not) reacted to a link.
void _expectFullyInView(
  WidgetTester tester, {
  required Key key,
  required String caseId,
  required String elementLabel,
}) {
  final Rect rect = tester.getRect(find.byKey(key));
  final double viewHeight = _viewHeight(tester);
  expect(
    _fullyInView(rect, viewHeight),
    isTrue,
    reason:
        '$caseId: expected $elementLabel fully inside the viewport (top >= '
        '0 and bottom <= $viewHeight) once the home scroll view has reacted '
        'to the link; got rect $rect. Reproduce at surface $_kSurfaceSize, '
        'devicePixelRatio $_kSurfaceDevicePixelRatio.',
  );
}

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

void main() {
  testWidgets(
    'LS-COLD: a valid cold-start link scrolls join-room-button into view',
    (tester) async {
      _useFoldedSurface(tester);
      final _FakeInitialLinkReader reader = _FakeInitialLinkReader();

      await tester.pumpWidget(_homeScreenApp(initialLinkReader: reader.call));
      await tester.pump();

      _expectButtonBelowFold(tester, 'LS-COLD');

      reader.complete(_roomLink('K7M2QP'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        _codeFieldText(tester),
        'K7M2QP',
        reason:
            'LS-COLD fixture: the cold-start link must still have pre-filled '
            'the code field before this case can measure whether it also '
            'scrolled',
      );
      _expectFullyInView(
        tester,
        key: const Key('join-room-button'),
        caseId: 'LS-COLD',
        elementLabel: 'join-room-button',
      );
    },
  );

  testWidgets(
    'LS-WARM: a valid warm-start link scrolls join-room-button into view',
    (tester) async {
      _useFoldedSurface(tester);
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();

      _expectButtonBelowFold(tester, 'LS-WARM');

      opener.add(_roomLink('H4XR9T'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        _codeFieldText(tester),
        'H4XR9T',
        reason:
            'LS-WARM fixture: the warm-start link must still have pre-filled '
            'the code field before this case can measure whether it also '
            'scrolled',
      );
      _expectFullyInView(
        tester,
        key: const Key('join-room-button'),
        caseId: 'LS-WARM',
        elementLabel: 'join-room-button',
      );
    },
  );

  testWidgets(
    'LS-BAD: a room link with an invalid code scrolls room-code-field into '
    'view so the error under it can be read',
    (tester) async {
      _useFoldedSurface(tester);
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();

      _expectButtonBelowFold(tester, 'LS-BAD');

      // 0O0O0O passes isAppRoomLinkUri (right scheme, right host, right
      // path shape) but fails isValidRoomCode: both 0 and O are excluded
      // from roomCodeAlphabet, so roomCodeFromUri returns null for it and
      // the invalid-code error shows.
      opener.add(_roomLink('0O0O0O'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final BuildContext context = tester.element(find.byType(HomeScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(
        _codeFieldError(tester),
        loc.homeRoomCodeInvalid,
        reason:
            'LS-BAD fixture: a room link whose code fails isValidRoomCode '
            'must still show the invalid-code error before this case can '
            'measure whether the field was also scrolled into view',
      );
      _expectFullyInView(
        tester,
        key: const Key('room-code-field'),
        caseId: 'LS-BAD',
        elementLabel: 'room-code-field',
      );
    },
  );

  testWidgets(
    'LS-FOREIGN: a link outside this app\'s room-link space at all leaves '
    'the home scroll offset unchanged',
    (tester) async {
      _useFoldedSurface(tester);
      final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

      await tester.pumpWidget(_homeScreenApp(linkStream: opener.call));
      await tester.pump();

      _expectButtonBelowFold(tester, 'LS-FOREIGN');
      final double offsetBefore = _homeScrollPosition(tester).pixels;

      opener.add(_foreignLink('K7M2QP'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        _codeFieldText(tester),
        isEmpty,
        reason:
            'LS-FOREIGN fixture: a link whose host is not kAppLinkHost is '
            'not a room link at all and must never reach the code field',
      );
      final double offsetAfter = _homeScrollPosition(tester).pixels;
      expect(
        offsetAfter,
        offsetBefore,
        reason:
            'LS-FOREIGN: the home scroll offset must be identical before '
            '($offsetBefore) and after ($offsetAfter) a link that is not a '
            'room link at all; an implementation that scrolls on every '
            'incoming link, not only a room link\'s, fails exactly this '
            'case',
      );
    },
  );

  testWidgets('LS-AR: LS-WARM in Locale(ar)', (tester) async {
    _useFoldedSurface(tester);
    final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();

    await tester.pumpWidget(
      _homeScreenApp(linkStream: opener.call, locale: const Locale('ar')),
    );
    await tester.pump();

    _expectButtonBelowFold(tester, 'LS-AR');

    opener.add(_roomLink('H4XR9T'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      _codeFieldText(tester),
      'H4XR9T',
      reason:
          'LS-AR fixture: the warm-start link must still have pre-filled '
          'the code field in the Arabic locale before this case can measure '
          'whether it also scrolled',
    );
    _expectFullyInView(
      tester,
      key: const Key('join-room-button'),
      caseId: 'LS-AR',
      elementLabel: 'join-room-button',
    );
  });
}
