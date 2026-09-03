// Boots the real app and proves it reaches its first screen -- not that the
// APK installed, that the Dart side is running and HomeScreen's own widgets
// are on screen -- in both supported locales, with no unhandled framework
// exception along the way. This is the smoke device-smoke.yml drives; see
// that workflow for what runs it, on what platform, and why.
//
// Deliberately does not tap Create Room or Join Room. Both push a RoomRoute
// built from widget.controllerFactory, which defaults to
// defaultRoomControllerFactory (lib/src/server_config.dart): a real socket to
// kDefaultServerUrl, wss://ludo.provefair.app -- the production server. An
// emulator in a CI runner reaching either button would create a real room
// there every time this workflow runs. Order 112 is explicit that room
// creation over the network is out of scope for this order; the client's net
// stack reaching a real server is already proved by tool/wire_smoke.dart
// against staging, and duplicating that here would mean this workflow writes
// to production. Reaching RoomScreen (and the RTL layout it would also need
// proving) is exactly what integration_test/screenshots_test.dart already
// covers by going through Join Room's purely local code-validation path; this
// test does not need to repeat that to satisfy what order 112 asks for, which
// stops at HomeScreen in both locales.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app launches, reaches HomeScreen, in both locales, with '
      'no unhandled framework exception', (tester) async {
    // FlutterError's default onError prints to the console and, under a
    // plain `flutter test`, that print is intercepted by the test framework
    // and fails the enclosing test as a side effect. That side effect is not
    // something this order is willing to rely on: `flutter drive` on a real
    // device is exactly the path a crash-on-start has never been run
    // through in this repository (see order 112's own goal section), and an
    // assumption about how a different binding happens to behave is not a
    // check. Capturing every FlutterErrorDetails here and asserting the list
    // is empty at the end is the explicit assertion order 112 asks for by
    // name, in place of relying on the test happening to fail on its own.
    final List<FlutterErrorDetails> caughtErrors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? previousOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      caughtErrors.add(details);
      // Still forward to whatever handler was installed before this one
      // (by default, the one that dumps to the console), so a failure here
      // is also visible in the emulator's own logcat, not only in
      // caughtErrors below.
      previousOnError?.call(details);
    };

    try {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      await _expectHomeScreenOn(tester, localeName: 'en');
      expect(
        Directionality.of(tester.element(find.byType(HomeScreen))),
        TextDirection.ltr,
        reason: 'expected the English layout to be left-to-right',
      );

      // Toggle to Arabic through the same button a player taps, not by
      // constructing LudoApp with initialLocale: the toggle itself
      // (app.dart's _toggleLocale, wired through onToggleLocale) is part of
      // what order 112 asks to be proven live, not just that Arabic
      // strings exist in the bundle.
      await tester.tap(find.byKey(const Key('locale-toggle-button')));
      await tester.pumpAndSettle();

      await _expectHomeScreenOn(tester, localeName: 'ar');
      expect(
        Directionality.of(tester.element(find.byType(HomeScreen))),
        TextDirection.rtl,
        reason:
            'expected the Arabic layout to be right-to-left after the '
            'locale toggle',
      );
    } finally {
      // Restored unconditionally so a failure inside the try block does not
      // leave a test-local handler installed past the end of this test.
      FlutterError.onError = previousOnError;
    }

    // The explicit assertion order 112 asks for: not "the test did not
    // throw", but a checked, empty list of every framework exception caught
    // anywhere during launch or the locale toggle. reason lists what was
    // caught so a failure here does not have to be re-run to be read.
    expect(
      caughtErrors,
      isEmpty,
      reason:
          'expected no unhandled framework exception during launch or the '
          'locale toggle; caught ${caughtErrors.length}: '
          '${caughtErrors.map((d) => d.exceptionAsString()).join('; ')}',
    );
  });
}

/// Asserts HomeScreen is on screen, in the locale named by [localeName]
/// ('en' or 'ar'), and that the widgets a player would actually use are
/// present -- not just the screen's type, which a build that rendered an
/// empty Scaffold under the same widget type would still satisfy.
Future<void> _expectHomeScreenOn(
  WidgetTester tester, {
  required String localeName,
}) async {
  final homeFinder = find.byType(HomeScreen);
  expect(
    homeFinder,
    findsOneWidget,
    reason:
        'expected HomeScreen on screen; the app either crashed on start, '
        'never got past a splash/loading state, or the locale toggle left '
        'it somewhere else',
  );

  final loc = AppLocalizations.of(tester.element(homeFinder));
  expect(
    loc.localeName,
    localeName,
    reason:
        'expected the home screen locale to be "$localeName", it was '
        '"${loc.localeName}"',
  );

  // The controls a player reaches for first. Present in both locales; a
  // localisation gap that dropped one of these under Arabic specifically
  // would otherwise pass a check that stopped at findsOneWidget on
  // HomeScreen's own type.
  expect(
    find.byKey(const Key('home-name-field')),
    findsOneWidget,
    reason: 'HomeScreen is on screen but its name field is not ($localeName)',
  );
  expect(
    find.byKey(const Key('create-room-button')),
    findsOneWidget,
    reason:
        'HomeScreen is on screen but its Create Room button is not '
        '($localeName)',
  );
  expect(
    find.byKey(const Key('room-code-field')),
    findsOneWidget,
    reason:
        'HomeScreen is on screen but its room-code field is not '
        '($localeName)',
  );
  expect(
    find.byKey(const Key('join-room-button')),
    findsOneWidget,
    reason:
        'HomeScreen is on screen but its Join Room button is not '
        '($localeName)',
  );
}
