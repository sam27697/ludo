// Home text contrast under the neon underfelt arcade-night theme. Mounts
// HomeScreen with buildNeonUnderfeltTheme and asserts Flutter's
// textContrastGuideline. Also requires the theme's paper to read as deep
// void (not Bold mint paper) so a mint alias cannot satisfy the gate.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/theme.dart';

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-neon-contrast-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_neon_underfelt_contrast_test.dart: connector must never '
        'open a transport',
      );
    },
  );
}

void main() {
  testWidgets(
    'home text meets textContrastGuideline under neon underfelt theme',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ThemeData neonTheme = buildNeonUnderfeltTheme();
      final LudoBrand? brand = neonTheme.extension<LudoBrand>();
      expect(
        brand,
        isNotNull,
        reason: 'buildNeonUnderfeltTheme must register LudoBrand',
      );
      expect(
        brand!.paper,
        isNot(LudoColors.paper),
        reason:
            'neon underfelt paper must diverge from Bold mint '
            '(${LudoColors.paper}); got ${brand.paper}',
      );
      expect(
        ThemeData.estimateBrightnessForColor(brand.paper),
        Brightness.dark,
        reason: 'neon underfelt paper must read as deep void (dark)',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: neonTheme,
          locale: const Locale('en'),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: HomeScreen(
            onToggleLocale: () {},
            controllerFactory: _neverConnectsControllerFactory,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(HomeScreen),
        findsOneWidget,
        reason: 'fixture must mount HomeScreen under neon underfelt theme',
      );
      expect(
        find.byKey(const Key('create-room-button')),
        findsOneWidget,
        reason: 'home primary actions must be on screen for contrast scan',
      );

      await expectLater(tester, meetsGuideline(textContrastGuideline));
    },
  );
}
