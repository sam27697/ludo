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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/src/app.dart';

/// The code typed into the join field for both room captures. Six
/// characters from the room-code alphabet; see the file header for why this
/// value and not another one.
const _screenshotRoomCode = 'K7M4PQ';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture the store-listing screenshots', (tester) async {
    // Android only, and a no-op everywhere else: swaps the Flutter surface
    // for an image view so the screenshot below captures pixels the
    // platform's normal surface compositing would otherwise miss.
    await binding.convertFlutterSurfaceToImage();

    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();
    await _settleForScreenshot(tester);
    await binding.takeScreenshot('01-home-en');

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    await _settleForScreenshot(tester);
    await binding.takeScreenshot('02-home-ar');

    await _joinRoom(tester, _screenshotRoomCode);
    await _settleForScreenshot(tester);
    await binding.takeScreenshot('03-room-ar');

    // Back to the (still Arabic) home screen, toggle the locale to English,
    // then join a room again to land on an English room screen. The AppBar
    // back button here is the one MaterialPageRoute supplies automatically
    // (see room_screen.dart); it carries no key, so it is found by widget
    // type, which works under either locale, unlike a tooltip lookup.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();

    await _joinRoom(tester, _screenshotRoomCode);
    await _settleForScreenshot(tester);
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
/// still be attached to. See the report for what could not be confirmed
/// without a device.
Future<void> _joinRoom(WidgetTester tester, String code) async {
  final fieldFinder = find.byKey(const Key('room-code-field'));
  await tester.tap(fieldFinder);
  await tester.pumpAndSettle();
  await tester.enterText(fieldFinder, code);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('join-room-button')));
  await tester.pumpAndSettle();
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
