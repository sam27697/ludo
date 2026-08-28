// Drives the app to the three screens the Play Console listing needs and
// captures a PNG of each one. Run on a real (or emulated) Android device
// with `flutter drive --driver=test_driver/integration_test.dart
// --target=integration_test/screenshots_test.dart`; the driver adaptor in
// test_driver/integration_test.dart is what turns the bytes captured here
// into files on disk.
//
// Every screen this test reaches is reachable with no server running: the
// home screen and the room screen it navigates to are both pure client-side
// widgets (see lib/src/home_screen.dart and lib/src/room_screen.dart), so
// there is nothing here for a screenshot run to connect to.
//
// File names carry both the screen and the language, in capture order, so
// the artifact is self-describing without opening every image:
//   01-home-en.png  home screen, English, left-to-right
//   02-home-ar.png  home screen, Arabic, right-to-left
//   03-room-ar.png  room screen, reached from the Arabic home screen
//   04-room-en.png  room screen, reached back through the English home screen

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/src/app.dart';

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

    await tester.tap(find.byKey(const Key('create-room-button')));
    await tester.pumpAndSettle();
    await _settleForScreenshot(tester);
    await binding.takeScreenshot('03-room-ar');

    // Back to the (still Arabic) home screen, toggle the locale to English,
    // then enter a room again to land on an English room screen. The AppBar
    // back button here is the one MaterialPageRoute supplies automatically
    // (see room_screen.dart); it carries no key, so it is found by widget
    // type, which works under either locale, unlike a tooltip lookup.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create-room-button')));
    await tester.pumpAndSettle();
    await _settleForScreenshot(tester);
    await binding.takeScreenshot('04-room-en');
  });
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
