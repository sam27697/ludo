// Home entrance motion: duration must come from the theme motion token, and
// reduced-motion users must skip the enter animation.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/theme.dart';

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-motion-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_motion_test.dart: connector must never open a transport',
      );
    },
  );
}

Widget _harness({bool disableAnimations = false}) {
  return MaterialApp(
    theme: buildAppTheme(),
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(disableAnimations: disableAnimations),
        child: child!,
      );
    },
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
  );
}

/// Walks a [FadeTransition] opacity animation up to the home enter controller.
AnimationController _homeEnterController(WidgetTester tester) {
  final Finder fades = find.descendant(
    of: find.byType(HomeScreen),
    matching: find.byType(FadeTransition),
  );
  expect(
    fades,
    findsWidgets,
    reason: 'HomeScreen entrance must expose FadeTransition widgets',
  );
  final FadeTransition fade = tester.widget<FadeTransition>(fades.first);
  Animation<double>? current = fade.opacity;
  while (current != null && current is! AnimationController) {
    if (current is CurvedAnimation) {
      current = current.parent;
      continue;
    }
    if (current is ProxyAnimation) {
      current = current.parent;
      continue;
    }
    fail('could not resolve AnimationController from ${current.runtimeType}');
  }
  expect(current, isA<AnimationController>());
  return current! as AnimationController;
}

void main() {
  testWidgets(
    'home enter duration equals theme motionLong and is at most 500ms',
    (WidgetTester tester) async {
      await tester.pumpWidget(_harness());
      await tester.pump();

      final BuildContext context = tester.element(find.byType(HomeScreen));
      final LudoBrand? brand = Theme.of(context).extension<LudoBrand>();
      expect(
        brand,
        isNotNull,
        reason: 'buildAppTheme must expose LudoBrand with motionLong',
      );
      final Duration motionLong = brand!.motionLong;

      final AnimationController enter = _homeEnterController(tester);
      expect(
        enter.duration,
        equals(motionLong),
        reason:
            'HomeScreen AnimationController.duration must equal '
            'Theme.of(context).extension<LudoBrand>()!.motionLong',
      );
      expect(
        enter.duration!.inMilliseconds,
        lessThanOrEqualTo(500),
        reason: 'home enter duration must be ≤ 500ms',
      );
    },
  );

  testWidgets(
    'home enter jumps to completed within 50ms when animations are disabled',
    (WidgetTester tester) async {
      await tester.pumpWidget(_harness(disableAnimations: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final AnimationController enter = _homeEnterController(tester);
      expect(
        enter.status,
        equals(AnimationStatus.completed),
        reason:
            'when MediaQuery.disableAnimationsOf is true, home enter must '
            'reach completed within 50ms',
      );
      expect(
        enter.value,
        equals(1.0),
        reason: 'reduced-motion home enter must finish at value 1.0',
      );
    },
  );

  testWidgets('home still shows DieMark and Create/Join after enter', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1000));

    expect(
      find.byType(DieMark),
      findsWidgets,
      reason: 'HomeScreen must paint DieMark after enter',
    );
    expect(
      find.byKey(const Key('create-room-button')),
      findsOneWidget,
      reason: 'Create Room must remain after enter',
    );
    expect(
      find.byKey(const Key('join-room-button')),
      findsOneWidget,
      reason: 'Join Room must remain after enter',
    );
  });
}
