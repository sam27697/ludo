// Widget tests for the home room-code field after a whole-string paste.
//
// Join already sends a normalised code (spaces and dashes stripped, upper
// case). These tests require the field itself to show that 6-character
// form before Join is tapped. enterText inserts the whole decorated string
// in one editing update, the same way a paste replaces the field.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');

const String _normalized = 'AB23CD';

class _PasteCase {
  const _PasteCase(this.description, this.raw);

  final String description;
  final String raw;
}

const List<_PasteCase> _pasteCases = <_PasteCase>[
  _PasteCase('spaces, dashes and lower case "ab2- 3cd"', 'ab2- 3cd'),
  _PasteCase('spaces "AB 23 CD"', 'AB 23 CD'),
  _PasteCase('dashes and lower case "ab2-3cd"', 'ab2-3cd'),
];

RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://room-code-normalize-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'room_code_normalize_test.dart: this connector must never open a '
        'real or fake transport; these tests never tap Join or Create',
      );
    },
  );
}

class _NavigatorProbe extends NavigatorObserver {
  int pushCount = 0;
  int popCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

Widget _homeScreenApp({required _NavigatorProbe observer}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: <NavigatorObserver>[observer],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _neverConnectsControllerFactory,
    ),
  );
}

String _displayedCode(WidgetTester tester) {
  expect(find.byKey(_codeKey), findsOneWidget);
  final EditableText editable = tester.widget<EditableText>(
    find.descendant(
      of: find.byKey(_codeKey),
      matching: find.byType(EditableText),
    ),
  );
  return editable.controller.value.text;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('pasting a decorated code shows the normalized 6-char uppercase form '
      'before Join is tapped', () {
    for (final _PasteCase testCase in _pasteCases) {
      testWidgets(testCase.description, (tester) async {
        final _NavigatorProbe observer = _NavigatorProbe();
        await tester.pumpWidget(_homeScreenApp(observer: observer));
        await tester.pumpAndSettle();

        expect(
          _displayedCode(tester),
          isEmpty,
          reason:
              'fixture is broken: room-code-field must start empty so a '
              'leftover value cannot masquerade as a normalised paste',
        );

        final int pushesBeforePaste = observer.pushCount;
        final int popsBeforePaste = observer.popCount;

        await tester.enterText(find.byKey(_codeKey), testCase.raw);
        await tester.pump();

        expect(
          _displayedCode(tester),
          _normalized,
          reason:
              'after pasting "${testCase.raw}" into room-code-field, the '
              'field must show the normalised 6-character uppercase code '
              '"$_normalized" before Join is tapped; submit-time '
              'normalisation of the same string is not enough',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason: 'pasting a code must not navigate; Join stays the next tap',
        );
        expect(
          observer.pushCount,
          pushesBeforePaste,
          reason:
              'pasting a code must not push a route; pushes went from '
              '$pushesBeforePaste to ${observer.pushCount}',
        );
        expect(
          observer.popCount,
          popsBeforePaste,
          reason: 'pasting a code must not pop a route',
        );
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason: 'Join must remain on Home after the paste',
        );
      });
    }
  });
}
