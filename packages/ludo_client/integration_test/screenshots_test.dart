// Drives the app to the three screens the Play Console listing needs and
// captures a PNG of each one. Run on a real (or emulated) Android device
// with `flutter drive --driver=test_driver/integration_test.dart
// --target=integration_test/screenshots_test.dart`; the driver adaptor in
// test_driver/integration_test.dart is what turns the bytes captured here
// into files on disk.
//
// Every screen this test reaches is reachable with no server running: the
// home screen and the room screen it navigates to are both pure client-side
// widgets (see lib/src/home_screen.dart and lib/src/room_screen.dart). The
// room screen is reached through Join Room, which validates the typed code
// against the local room-code shape (lib/src/room_code.dart) and navigates
// without ever talking to a server, so there is still nothing here for a
// screenshot run to connect to.
//
// The room captures go through Join Room rather than Create Room so that
// the room screen they photograph carries a real code: Create Room can only
// ever show the "no code assigned" state, because a code otherwise comes
// from the server and this build has none. K7M4PQ is the code typed into
// the room-code field for both room captures; it is checked against
// isValidRoomCode and roomCodeLength in room_code_test.dart's own alphabet
// test, not just assumed here.
//
// File names carry both the screen and the language, in capture order, so
// the artifact is self-describing without opening every image:
//   01-home-en.png  home screen, English, left-to-right
//   02-home-ar.png  home screen, Arabic, right-to-left
//   03-room-ar.png  room screen, reached from the Arabic home screen by
//                   typing K7M4PQ into the join field
//   04-room-en.png  room screen, reached back through the English home
//                   screen, again by typing K7M4PQ into the join field
//
// Two workflow runs (33183494414, 33185182659) each produced a
// `03-room-ar.png` that was not a room screen at all: the join silently
// failed, home_screen.dart's own validation caught the resulting empty
// field and stayed on the home screen with an error message, and nothing
// downstream noticed. Every capture below is now preceded by an assertion
// that names the screen (and, for the room, the code) it expects to find,
// specifically so a repeat of that failure throws instead of getting
// photographed and called a success. See `_expectHomeScreen` and
// `_expectRoomScreen`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/room_screen.dart';

/// The code typed into the join field for both room captures. Six
/// characters from the room-code alphabet; see the file header for why this
/// value and not another one.
const _screenshotRoomCode = 'K7M4PQ';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture the store-listing screenshots', (tester) async {
    // Without this, text typed by _joinRoom below never reaches the field
    // on a real device, and the two room captures silently photograph a
    // validation error on the home screen instead. Full argument in the
    // report; the short version:
    //
    // IntegrationTestWidgetsFlutterBinding.registerTestTextInput is
    // hardcoded false (package:integration_test/integration_test.dart:99),
    // specifically so a real IME attaches instead of the fake one --
    // useful for tests that want to exercise a real keyboard, useless here.
    // Because of that, TestWidgetsFlutterBinding.reset() never calls
    // testTextInput.register() (flutter_test/lib/src/binding.dart:1133-1135),
    // so tester.testTextInput is never installed as the mock handler for
    // SystemChannels.textInput. When the room-code field is tapped, its
    // TextInputConnection.attach still runs (text_input.dart:2644-2647) and
    // still calls TextInput.setClient, but that call now goes to the real
    // platform channel and a real IME attaches, not to
    // flutter_test/lib/src/test_text_input.dart's TestTextInput, so
    // TestTextInput's `_client` field (test_text_input.dart:84) is never
    // populated from a real TextInput.setClient the way
    // _handleTextInputCall would populate it (test_text_input.dart:135-137)
    // if it were registered.
    //
    // tester.enterText calls testTextInput.enterText, which sends a
    // synthetic `TextInputClient.updateEditingState` platform message
    // tagged with `_client ?? -1` (test_text_input.dart:186-220) -- so, on
    // this binding, always -1. The framework's real dispatch
    // (text_input.dart:2159 onward) checks that tag against the id of the
    // connection actually attached (text_input.dart:2240-2241) and drops
    // the message if it does not match. The one exception is a hardcoded
    // "-1 always matches" escape hatch for exactly this situation
    // (text_input.dart:2244-2256) -- but it is wrapped in `assert(() {
    // ... }())`, and `--enable-asserts` is only in the compiler flags
    // flutter_tools builds for BuildMode.debug, not for BuildMode.profile
    // or BuildMode.release
    // (flutter_tools/lib/src/compile.dart:192-220). This workflow drives
    // with `flutter drive --profile` (screenshots.yml), so that assert
    // body never runs, `debugAllowAnyway` stays false, and the update is
    // dropped every time. (It is not dropped under a plain `flutter test`
    // run of this same file, because `flutter test` runs with assertions
    // enabled regardless of build mode -- which is why round 1's headless
    // reproduction of this exact sequence found the text where it expected
    // it, and a real device did not.)
    //
    // Registering the fake explicitly, here, before anything taps the
    // field, sidesteps all of that: TestTextInput.register() (called by
    // this line, test_text_input.dart:64-65) is not conditioned on
    // registerTestTextInput -- that flag only controls whether the binding
    // calls it *for* you. Once it is registered, TextInput.setClient goes
    // to TestTextInput's own handler instead of a real IME, `_client` gets
    // set to the real connection id every time, and enterText's messages
    // carry a client id that matches. No real keyboard ever attaches, so
    // there is nothing left on screen for a screenshot to catch mid-IME
    // either.
    binding.testTextInput.register();

    // Android only, and a no-op everywhere else: swaps the Flutter surface
    // for an image view so the screenshot below captures pixels the
    // platform's normal surface compositing would otherwise miss.
    await binding.convertFlutterSurfaceToImage();

    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();
    await _settleForScreenshot(tester);
    await _expectHomeScreen(tester, localeName: 'en');
    await binding.takeScreenshot('01-home-en');

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    await _settleForScreenshot(tester);
    await _expectHomeScreen(tester, localeName: 'ar');
    await binding.takeScreenshot('02-home-ar');

    await _joinRoom(tester, _screenshotRoomCode);
    await _settleForScreenshot(tester);
    await _expectRoomScreen(
      tester,
      localeName: 'ar',
      code: _screenshotRoomCode,
    );
    await binding.takeScreenshot('03-room-ar');

    // Back to the (still Arabic) home screen, toggle the locale to English,
    // then join a room again to land on an English room screen.
    //
    // This used to be `tester.tap(find.byType(BackButton))`, on the theory
    // that the AppBar's automatically-implied back button is a BackButton
    // (room_screen.dart sets neither `leading` nor
    // `automaticallyImplyLeading: false`, and home_screen.dart pushes the
    // route with a plain MaterialPageRoute, so AppBar's own logic --
    // packages/flutter/lib/src/material/app_bar.dart, `_AppBarState.build`,
    // pinned Flutter 3.47.1 -- does build `leading = const BackButton()`
    // whenever there is no custom leading and the route has an active route
    // below it). That reasoning holds under `flutter test`: a headless
    // reproduction of this exact sequence (locale toggle, then Join Room,
    // landing on the Arabic room screen) finds exactly one BackButton at
    // this point. It nonetheless found zero widgets on the real device this
    // workflow runs against (workflow run 33183494414), which uses
    // IntegrationTestWidgetsFlutterBinding on a real emulator rather than
    // the fake-clock binding `flutter test` uses; nothing in this repo
    // explains that divergence, and it cannot be reproduced in this
    // container, which has no Android SDK or emulator.
    //
    // Rather than chase a binding-specific timing difference that can only
    // be diagnosed on a device, this drives the pop directly through the
    // Navigator instead of tapping whatever widget Material happens to
    // render as the back affordance. It is the same call any back
    // affordance (button, gesture, hardware key) ends up making, so it
    // reaches the same home screen without depending on a widget lookup
    // that has already been proven fragile once. (The other option the
    // order allowed -- pumping LudoApp() a second time instead of navigating
    // back at all -- was tried and rejected: WidgetsBinding.attachRootWidget
    // reuses the existing root Element rather than discarding it
    // (packages/flutter/lib/src/widgets/binding.dart, `attachToBuildOwner`),
    // so LudoApp's State, and the NavigatorState nested inside it, survive
    // the second pumpWidget call. A headless reproduction confirmed this
    // directly: pumping LudoApp() again from the room screen left the room
    // screen on screen, not the home screen.)
    Navigator.of(tester.element(find.byType(RoomScreen))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    await _joinRoom(tester, _screenshotRoomCode);
    await _settleForScreenshot(tester);
    await _expectRoomScreen(
      tester,
      localeName: 'en',
      code: _screenshotRoomCode,
    );
    await binding.takeScreenshot('04-room-en');
  });
}

/// Taps the room-code field, types [code] into it, then taps Join Room.
/// Typing requires the field to hold focus first, so the field is tapped
/// before entry and the tree is settled after both the tap and the entry.
/// The room screen the tap on Join Room lands on is a new route entirely
/// (see home_screen.dart), which disposes this field and its focus node, so
/// no explicit unfocus is done here before the capture that follows this
/// call: there is nothing left on screen afterward that a keyboard could
/// still be attached to.
///
/// Checks, before tapping Join Room, that the field actually holds [code].
/// This is the assertion that would have caught both prior failures:
/// without it, a silently-dropped `enterText` (see the comment above
/// `binding.testTextInput.register()` in `main`) leaves the field empty,
/// home_screen.dart's own validation rejects the empty text, and the run
/// never navigates anywhere -- it just sits on the home screen with an
/// error message, which is exactly what `03-room-ar.png` turned out to be
/// in workflow runs 33183494414 and 33185182659.
Future<void> _joinRoom(WidgetTester tester, String code) async {
  final fieldFinder = find.byKey(const Key('room-code-field'));
  await tester.tap(fieldFinder);
  await tester.pumpAndSettle();
  await tester.enterText(fieldFinder, code);
  await tester.pumpAndSettle();

  final typed = tester.widget<TextField>(fieldFinder).controller!.text;
  expect(
    typed,
    code,
    reason:
        'the room-code field holds "$typed", not "$code" -- enterText did '
        'not reach the controller, so tapping Join Room now would either '
        'fail local validation or join the wrong room. See the comment '
        'above binding.testTextInput.register() in main() for why this '
        'happens and how it is avoided.',
  );

  await tester.tap(find.byKey(const Key('join-room-button')));
  await tester.pumpAndSettle();
}

/// Asserts the home screen is on screen, in the locale named by
/// [localeName] ('en' or 'ar'), before a home-screen capture is taken.
Future<void> _expectHomeScreen(
  WidgetTester tester, {
  required String localeName,
}) async {
  final homeFinder = find.byType(HomeScreen);
  expect(
    homeFinder,
    findsOneWidget,
    reason:
        'expected the home screen on screen; found something else, or '
        'more than one',
  );

  final loc = AppLocalizations.of(tester.element(homeFinder));
  expect(
    loc.localeName,
    localeName,
    reason:
        'expected the home screen locale to be "$localeName", it was '
        '"${loc.localeName}" -- the locale toggle did not take effect',
  );
}

/// Asserts the room screen is on screen, in the locale named by
/// [localeName], showing [code] as its room code, before a room-screen
/// capture is taken. Checking the displayed code (not just the widget
/// type) is what would have caught the home screen being mistaken for a
/// room screen in workflow runs 33183494414 and 33185182659: both stayed
/// on HomeScreen, so a check that stopped at `findsOneWidget` on
/// `RoomScreen` would never have run in the first place, but a build that
/// somehow reached RoomScreen without carrying the code through (a
/// regression this test cannot rule out any other way) would still be
/// caught here.
Future<void> _expectRoomScreen(
  WidgetTester tester, {
  required String localeName,
  required String code,
}) async {
  final roomFinder = find.byType(RoomScreen);
  expect(
    roomFinder,
    findsOneWidget,
    reason:
        'expected the room screen on screen; found something else, or '
        'more than one. If the join silently failed, this is where it '
        'first becomes visible: home_screen.dart never navigates on '
        'invalid input, so the app is still on HomeScreen here',
  );

  final loc = AppLocalizations.of(tester.element(roomFinder));
  expect(
    loc.localeName,
    localeName,
    reason:
        'expected the room screen locale to be "$localeName", it was '
        '"${loc.localeName}"',
  );

  final codeText = tester.widget<Text>(
    find.byKey(const Key('room-screen-code')),
  );
  expect(
    codeText.data,
    loc.roomScreenCodeLabel(code),
    reason:
        'expected the room screen to show the code "$code", it showed '
        '"${codeText.data}" -- the join did not carry the typed code '
        'through to the room screen',
  );
}

// `pumpAndSettle()` only proves the framework's widget tree has stopped
// scheduling frames; it says nothing about whether the platform surface
// that `convertFlutterSurfaceToImage()` swapped in has actually been handed
// that composited frame yet. In a profile (AOT) build the two were observed
// to fall out of step, so the screenshot after each action showed the
// screen the *previous* action had produced. Pumping a handful of explicit,
// real-duration frames forces further compositing to occur on the test
// clock, and the trailing `pumpAndSettle()` drains anything those frames
// scheduled, before the surface is read back.
Future<void> _settleForScreenshot(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}
