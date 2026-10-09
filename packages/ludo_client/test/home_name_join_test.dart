// Name plate, join divider and code slot for C-278.
//
// HomeScreen is mounted the way test/home_rule_toggles_test.dart mounts it
// when a case does not need a live socket: HomeScreen inside MaterialApp,
// with a controllerFactory whose connect throws. One mount per case.
//
// The divider copy is a literal. homeJoinDivider is not a getter on this
// base, so the test does not read it from AppLocalizations.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _rejoinKey = Key('home-rejoin-button');
const Key _dividerKey = Key('home-join-divider');

const String _dividerEn = 'or join with a code';
const String _dividerAr = 'أو انضم برمز';

const String _nameEn = 'Your name';
const String _nameAr = 'اسمك';
const String _codeLabelEn = 'Room code';
const String _codeHintEn = '6 characters, letters and numbers';

const Size _phone = Size(360, 800);

const String _rejoinCode = 'K7M2QP';
const int _rejoinSeat = 2;
const String _rejoinToken = 'tok-rejoin-seed-001';

RoomController _throwingFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-name-join-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_name_join_test: this connector must not be asked to open '
        'a transport',
      );
    },
  );
}

Widget _homeApp({Locale? locale, double textScale = 1.0}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (BuildContext context) {
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: HomeScreen(
            onToggleLocale: () {},
            controllerFactory: _throwingFactory,
          ),
        );
      },
    ),
  );
}

Future<void> _pumpHome(
  WidgetTester tester, {
  Locale? locale,
  Size? size,
  double textScale = 1.0,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(_homeApp(locale: locale, textScale: textScale));
  await tester.pumpAndSettle();
}

AppLocalizations _loc(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(HomeScreen)));
}

Finder _iconIn(Key key, IconData icon) {
  return find.descendant(of: find.byKey(key), matching: find.byIcon(icon));
}

Finder _textIn(Key key, String text) {
  return find.descendant(of: find.byKey(key), matching: find.text(text));
}

TextField _field(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: 'fixture: $key must be on screen');
  return tester.widget<TextField>(finder);
}

void _expectNamePlate(WidgetTester tester, String hint) {
  final InputDecoration? decoration = _field(tester, _nameKey).decoration;
  final List<String> problems = <String>[];
  if (decoration?.labelText != null) {
    problems.add('labelText is "${decoration?.labelText}", expected null');
  }
  if (decoration?.hintText != hint) {
    problems.add('hintText is "${decoration?.hintText}", expected "$hint"');
  }
  if (decoration?.filled != true) {
    problems.add('filled is ${decoration?.filled}, expected true');
  }
  expect(
    problems,
    isEmpty,
    reason: 'name plate ($hint): ${problems.join('; ')}',
  );
}

void _expectDivider(WidgetTester tester, String text) {
  final Finder divider = find.byKey(_dividerKey);
  expect(
    divider,
    findsOneWidget,
    reason: 'home-join-divider must be on screen for "$text"',
  );
  expect(
    find.descendant(of: divider, matching: find.text(text)),
    findsOneWidget,
    reason: 'home-join-divider must read "$text"',
  );
  final Rect gap = tester.getRect(divider);
  final Rect create = tester.getRect(find.byKey(_createKey));
  final Rect code = tester.getRect(find.byKey(_codeKey));
  expect(
    gap.top,
    greaterThanOrEqualTo(create.bottom),
    reason:
        'home-join-divider ("$text") must start at or below Create; '
        'divider top ${gap.top}, Create bottom ${create.bottom}',
  );
  expect(
    gap.bottom,
    lessThanOrEqualTo(code.top),
    reason:
        'home-join-divider ("$text") must end at or above the code '
        'field; divider bottom ${gap.bottom}, code top ${code.top}',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('en: name plate has no floating label, hints "Your name", '
      'and is filled', (WidgetTester tester) async {
    await _pumpHome(tester);

    final AppLocalizations loc = _loc(tester);
    expect(loc.localeName, 'en', reason: 'fixture: this case is English');
    expect(
      loc.homeNameFieldLabel,
      _nameEn,
      reason: 'fixture: homeNameFieldLabel must be "$_nameEn"',
    );
    _expectNamePlate(tester, loc.homeNameFieldLabel);
  });

  testWidgets('ar: name plate has no floating label, hints "اسمك", '
      'and is filled', (WidgetTester tester) async {
    await _pumpHome(tester, locale: const Locale('ar'));

    final AppLocalizations loc = _loc(tester);
    expect(loc.localeName, 'ar', reason: 'fixture: this case is Arabic');
    expect(
      loc.homeNameFieldLabel,
      _nameAr,
      reason: 'fixture: homeNameFieldLabel must be "$_nameAr"',
    );
    _expectNamePlate(tester, loc.homeNameFieldLabel);
  });

  testWidgets('typing dee shows D on the name plate', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);

    await tester.enterText(find.byKey(_nameKey), 'dee');
    await tester.pump();

    expect(
      _textIn(_nameKey, 'D'),
      findsOneWidget,
      reason: 'the name plate avatar must show "D" after typing "dee"',
    );
    expect(
      _iconIn(_nameKey, Icons.person),
      findsNothing,
      reason: 'Icons.person must leave the name plate once a name is typed',
    );
  });

  testWidgets('clearing the name plate shows Icons.person', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);

    await tester.enterText(find.byKey(_nameKey), 'dee');
    await tester.pump();
    await tester.enterText(find.byKey(_nameKey), '');
    await tester.pump();

    expect(
      _iconIn(_nameKey, Icons.person),
      findsOneWidget,
      reason: 'clearing the name plate must show Icons.person',
    );
    expect(
      _textIn(_nameKey, 'D'),
      findsNothing,
      reason: 'the avatar initial must leave once the name is cleared',
    );
  });

  testWidgets('name plate shows Icons.edit_outlined', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);

    expect(
      _iconIn(_nameKey, Icons.edit_outlined),
      findsOneWidget,
      reason: 'home-name-field must contain Icons.edit_outlined',
    );
  });

  testWidgets('name plate has a Semantics ancestor labelled "Your name"', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);

    final AppLocalizations loc = _loc(tester);
    expect(loc.localeName, 'en', reason: 'fixture: this case is English');
    expect(
      loc.homeNameFieldLabel,
      _nameEn,
      reason: 'fixture: homeNameFieldLabel must be "$_nameEn"',
    );
    expect(
      find.ancestor(
        of: find.byKey(_nameKey),
        matching: find.byWidgetPredicate(
          (Widget widget) =>
              widget is Semantics && widget.properties.label == _nameEn,
        ),
      ),
      findsOneWidget,
      reason:
          'home-name-field must have a Semantics ancestor labelled '
          '"$_nameEn"',
    );
  });

  testWidgets(
    'en: home-join-divider reads "or join with a code" between Create '
    'and the code field',
    (WidgetTester tester) async {
      await _pumpHome(tester);
      expect(
        _loc(tester).localeName,
        'en',
        reason: 'fixture: this case is English',
      );
      _expectDivider(tester, _dividerEn);
    },
  );

  testWidgets(
    'ar: home-join-divider reads "أو انضم برمز" between Create and the '
    'code field',
    (WidgetTester tester) async {
      await _pumpHome(tester, locale: const Locale('ar'));
      expect(
        _loc(tester).localeName,
        'ar',
        reason: 'fixture: this case is Arabic',
      );
      _expectDivider(tester, _dividerAr);
    },
  );

  testWidgets(
    'code slot has no floating label, hints "Room code", helps with the '
    '6-character line, and shows Icons.tag',
    (WidgetTester tester) async {
      await _pumpHome(tester);

      final AppLocalizations loc = _loc(tester);
      expect(loc.localeName, 'en', reason: 'fixture: this case is English');
      expect(
        loc.homeRoomCodeFieldLabel,
        _codeLabelEn,
        reason: 'fixture: homeRoomCodeFieldLabel must be "$_codeLabelEn"',
      );
      expect(
        loc.homeRoomCodeFieldHint,
        _codeHintEn,
        reason: 'fixture: homeRoomCodeFieldHint must be "$_codeHintEn"',
      );

      final InputDecoration? decoration = _field(tester, _codeKey).decoration;
      final List<String> problems = <String>[];
      if (decoration?.labelText != null) {
        problems.add('labelText is "${decoration?.labelText}", expected null');
      }
      if (decoration?.hintText != loc.homeRoomCodeFieldLabel) {
        problems.add(
          'hintText is "${decoration?.hintText}", expected '
          '"${loc.homeRoomCodeFieldLabel}"',
        );
      }
      if (decoration?.helperText != loc.homeRoomCodeFieldHint) {
        problems.add(
          'helperText is "${decoration?.helperText}", expected '
          '"${loc.homeRoomCodeFieldHint}"',
        );
      }
      if (_iconIn(_codeKey, Icons.tag).evaluate().isEmpty) {
        problems.add('Icons.tag is not inside room-code-field');
      }
      expect(problems, isEmpty, reason: 'code slot: ${problems.join('; ')}');
    },
  );

  testWidgets(
    'control: typing k7m2 and tapping Join still sets homeRoomCodeInvalid',
    (WidgetTester tester) async {
      await _pumpHome(tester);

      await tester.enterText(find.byKey(_codeKey), 'k7m2');
      await tester.pump();
      await tester.tap(find.byKey(_joinKey));
      await tester.pump();

      expect(
        _field(tester, _codeKey).decoration?.errorText,
        _loc(tester).homeRoomCodeInvalid,
        reason:
            'an invalid code k7m2 must still set errorText to '
            'homeRoomCodeInvalid',
      );
    },
  );

  testWidgets('create-room-button contains Icons.add_rounded', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);

    expect(
      _iconIn(_createKey, Icons.add_rounded),
      findsOneWidget,
      reason: 'create-room-button must contain Icons.add_rounded',
    );
  });

  testWidgets('join-room-button contains Icons.login_rounded', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester);

    expect(
      _iconIn(_joinKey, Icons.login_rounded),
      findsOneWidget,
      reason: 'join-room-button must contain Icons.login_rounded',
    );
  });

  testWidgets(
    'a stored seat shows Icons.play_arrow_rounded on home-rejoin-button',
    (WidgetTester tester) async {
      await SessionMemory.recordSeat(
        const SeatRecord(
          code: _rejoinCode,
          seat: _rejoinSeat,
          seatToken: _rejoinToken,
        ),
      );
      await _pumpHome(tester);

      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason:
            'fixture: a stored record for "$_rejoinCode" must show '
            'home-rejoin-button',
      );
      expect(
        _iconIn(_rejoinKey, Icons.play_arrow_rounded),
        findsOneWidget,
        reason: 'home-rejoin-button must contain Icons.play_arrow_rounded',
      );
    },
  );

  testWidgets(
    'control: an empty code keeps elevated Create and outlined Join, and '
    'a valid code swaps them',
    (WidgetTester tester) async {
      await _pumpHome(tester);

      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
        '',
        reason: 'fixture: room-code-field must start empty',
      );
      expect(
        tester.widget(find.byKey(_createKey)),
        isA<ElevatedButton>(),
        reason:
            'create-room-button must be an ElevatedButton while the code '
            'is empty; found '
            '${tester.widget(find.byKey(_createKey)).runtimeType}',
      );
      expect(
        tester.widget(find.byKey(_joinKey)),
        isA<OutlinedButton>(),
        reason:
            'join-room-button must be an OutlinedButton while the code '
            'is empty; found '
            '${tester.widget(find.byKey(_joinKey)).runtimeType}',
      );

      await tester.enterText(find.byKey(_codeKey), 'AB23CD');
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
        'AB23CD',
      );
      expect(
        tester.widget(find.byKey(_joinKey)),
        isA<ElevatedButton>(),
        reason:
            'join-room-button must be an ElevatedButton once the code '
            'is valid; found '
            '${tester.widget(find.byKey(_joinKey)).runtimeType}',
      );
      expect(
        tester.widget(find.byKey(_createKey)),
        isA<OutlinedButton>(),
        reason:
            'create-room-button must be an OutlinedButton once the code '
            'is valid; found '
            '${tester.widget(find.byKey(_createKey)).runtimeType}',
      );
    },
  );

  testWidgets(
    'ar text scale 1.3 at 360 x 800: the code error is inside the view '
    'width and nothing throws',
    (WidgetTester tester) async {
      await _pumpHome(
        tester,
        locale: const Locale('ar'),
        size: _phone,
        textScale: 1.3,
      );

      await tester.enterText(find.byKey(_codeKey), 'k7m2');
      await tester.pump();
      await tester.ensureVisible(find.byKey(_joinKey));
      await tester.tap(find.byKey(_joinKey));
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'ar text scale 1.3 at $_phone must not throw while the code '
            'error is showing',
      );

      final String errorText = _loc(tester).homeRoomCodeInvalid;
      final Finder error = find.text(errorText);
      expect(
        error,
        findsOneWidget,
        reason: 'the code error must be showing ("$errorText")',
      );

      final double viewWidth =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final Rect rect = tester.getRect(error);
      expect(
        rect.left,
        greaterThanOrEqualTo(0),
        reason:
            'the code error must start inside the view width $viewWidth; '
            'rect left ${rect.left} top ${rect.top} right ${rect.right} '
            'bottom ${rect.bottom}',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(viewWidth),
        reason:
            'the code error must end inside the view width $viewWidth; '
            'rect left ${rect.left} top ${rect.top} right ${rect.right} '
            'bottom ${rect.bottom}',
      );
    },
  );
}
