// C-686t: the home join field and the typed-code join of docs/PROTOCOL.md
// section 32 (items 1, 4 and 6), driven through a real HomeScreen over a real
// RoomController on FakeTransport.
//
// What is pinned:
//   - the field shows the canonical text as the player types: `l` shows `1`,
//     `o` shows `0`, spaces and dashes vanish, lower case goes up, and the
//     field caps at 6 symbols
//   - Join is present and enabled for 1 to 6 symbols, and absent or disabled
//     for an empty field; seven typed symbols leave six and Join enabled
//   - a tap on Join at 1 symbol and at 6 symbols sends `join_room` with that
//     canonical code and with `install`, even when no install id was stored
//     yet (the join waits for the id and always carries it)
//   - a valid short code leaves no error text under the field
//
// Names assumed (none are new keys: all exist on the tree today):
// room-code-field, join-room-button, home-name-field.
//
// Replay: flutter test test/c686_home_code_field_test.dart --plain-name '<id>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');
final RegExp _installShape = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
const String _installA = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;

class _Rig {
  _Rig(this.id, this.tester);

  final String id;
  final WidgetTester tester;
  final List<FakeTransport> transports = <FakeTransport>[];

  String get why =>
      'scenario "$id"; frames sent '
      '${transports.map((FakeTransport t) => t.sentRaw.map(_typeOf).toList()).toList()}. '
      "reproduce: flutter test test/c686_home_code_field_test.dart "
      "--plain-name '$id'";

  static Future<_Rig> open(
    WidgetTester tester,
    String id, {
    Map<String, Object> prefs = const <String, Object>{'install_id': _installA},
    Locale locale = const Locale('en'),
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final _Rig rig = _Rig(id, tester);
    RoomController factory() => RoomController(
      serverUrl: Uri.parse('wss://c686-code-field.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport t = FakeTransport();
        rig.transports.add(t);
        return t as WireTransport;
      },
      autoReconnectDelays: const <Duration>[],
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: HomeScreen(onToggleLocale: () {}, controllerFactory: factory),
      ),
    );
    await tester.pump();
    await tester.pump();
    return rig;
  }

  Future<void> type(String text) async {
    await tester.enterText(find.byKey(_codeKey), text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  String get shown =>
      tester.widget<TextField>(find.byKey(_codeKey)).controller!.text;

  String? get errorText =>
      tester.widget<TextField>(find.byKey(_codeKey)).decoration?.errorText;

  /// null when Join is not in the tree, else whether it can be pressed.
  bool? get joinEnabled {
    final Finder join = find.byKey(_joinKey);
    if (join.evaluate().isEmpty) {
      return null;
    }
    final Widget w = tester.widget(join);
    if (w is ButtonStyleButton) {
      return w.onPressed != null;
    }
    final Finder inner = find.descendant(
      of: join,
      matching: find.byWidgetPredicate((Widget x) => x is ButtonStyleButton),
    );
    if (inner.evaluate().isEmpty) {
      return true;
    }
    return (tester.widget(inner.first) as ButtonStyleButton).onPressed != null;
  }

  /// Pops every route above Home, as a player pressing back out of the lobby
  /// would, so a second join can be typed on the same mounted app.
  Future<void> backToHome() async {
    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    nav.popUntil((Route<dynamic> route) => route.isFirst);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(_codeKey),
      findsOneWidget,
      reason: 'expected the Home code field after backing out. $why',
    );
  }

  Future<Map<String, Object?>> tapJoinAndReadFrame() async {
    final int before = transports.length;
    expect(
      find.byKey(_joinKey),
      findsOneWidget,
      reason:
          'expected join-room-button for the code "$shown" before tapping it. '
          '$why',
    );
    await tester.ensureVisible(find.byKey(_joinKey));
    await tester.pump();
    await tester.tap(find.byKey(_joinKey));
    await tester.pump();
    for (int i = 0; i < 30 && !_sentJoin(before); i += 1) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      _sentJoin(before),
      isTrue,
      reason: 'expected a join_room frame after tapping Join. $why',
    );
    final String raw = transports
        .sublist(before)
        .expand((FakeTransport t) => t.sentRaw)
        .firstWhere((String r) => _typeOf(r) == 'join_room');
    return _decode(raw)['d']! as Map<String, Object?>;
  }

  /// A join_room on a transport opened after the first [before] ones.
  bool _sentJoin(int before) => transports
      .sublist(before)
      .any(
        (FakeTransport t) =>
            t.sentRaw.any((String r) => _typeOf(r) == 'join_room'),
      );

  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 12));
  }
}

void main() {
  group('the field shows canonical text', () {
    const List<(String, String)> rows = <(String, String)>[
      ('l', '1'),
      ('L', '1'),
      ('i', '1'),
      ('o', '0'),
      ('O', '0'),
      ('k7m2qp', 'K7M2QP'),
      ('k7-m2 qp', 'K7M2QP'),
      ('ab-l', 'AB1'),
      ('looi', '1001'),
    ];
    for (final (String typed, String shown) in rows) {
      testWidgets('typing "$typed" shows "$shown"', (tester) async {
        final _Rig r = await _Rig.open(tester, 'shows $typed');
        await r.type(typed);
        expect(
          r.shown,
          shown,
          reason:
              'expected the field to show "$shown" after typing "$typed", '
              'saw "${r.shown}". ${r.why}',
        );
      });
    }

    testWidgets('typing one character at a time folds as it goes', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'shows keystrokes');
      String typed = '';
      for (final (String ch, String expected) in <(String, String)>[
        ('l', '1'),
        ('o', '10'),
        ('k', '10K'),
        ('-', '10K'),
        (' ', '10K'),
        ('i', '10K1'),
      ]) {
        typed += ch;
        await r.type(typed);
        expect(
          r.shown,
          expected,
          reason:
              'expected "$expected" after typing "$typed" key by key, saw '
              '"${r.shown}". ${r.why}',
        );
      }
    });

    testWidgets('seven symbols leave six, and the first six stay', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'caps at six');
      await r.type('ABCDEFG');
      expect(
        r.shown,
        'ABCDEF',
        reason:
            'expected the field to cap at 6 symbols (first six kept), saw '
            '"${r.shown}". ${r.why}',
      );
      expect(r.joinEnabled, isTrue, reason: 'Join enabled at 6. ${r.why}');
    });

    testWidgets('a long run with folds caps at six canonical symbols', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'caps after fold');
      await r.type('l-o-i-k-7-m-2-q-p');
      expect(
        r.shown,
        '101K7M',
        reason:
            'expected the canonical first six symbols of the folded text, '
            'saw "${r.shown}". ${r.why}',
      );
    });
  });

  group('Join follows the length', () {
    testWidgets('Join is absent or disabled for an empty field', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'join at 0');
      expect(
        r.joinEnabled,
        anyOf(isNull, isFalse),
        reason: 'expected no usable Join at 0 symbols. ${r.why}',
      );
    });

    testWidgets('Join is absent or disabled again after clearing', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'join cleared');
      await r.type('K');
      expect(r.joinEnabled, isTrue, reason: 'Join enabled at 1. ${r.why}');
      await r.type('');
      expect(
        r.joinEnabled,
        anyOf(isNull, isFalse),
        reason: 'expected no usable Join after clearing. ${r.why}',
      );
    });

    testWidgets('Join is not usable for whitespace and dashes only', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'join blank');
      await r.type(' - - ');
      expect(
        r.joinEnabled,
        anyOf(isNull, isFalse),
        reason: 'expected no usable Join for blanks. ${r.why}',
      );
    });

    for (final String code in <String>[
      '0',
      'K',
      'K7',
      'K7M',
      'K7M2',
      'K7M2Q',
      'K7M2QP',
    ]) {
      testWidgets('Join is enabled at ${code.length} symbol(s) "$code"', (
        tester,
      ) async {
        final _Rig r = await _Rig.open(tester, 'join at ${code.length}');
        await r.type(code);
        expect(
          r.joinEnabled,
          isTrue,
          reason:
              'expected Join present and enabled at ${code.length} '
              'symbol(s), saw ${r.joinEnabled}. ${r.why}',
        );
        expect(
          r.errorText,
          isNull,
          reason: 'expected no error text for the valid "$code". ${r.why}',
        );
      });
    }
  });

  group('the join frame', () {
    testWidgets('one symbol: join_room carries code "7" and install', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'frame one symbol');
      await r.type('7');
      final Map<String, Object?> d = await r.tapJoinAndReadFrame();
      expect(d['code'], '7', reason: 'expected code "7" in d=$d. ${r.why}');
      expect(
        d['install'],
        _installA,
        reason: 'expected the stored install in d=$d. ${r.why}',
      );
      expect(d.containsKey('link'), isFalse, reason: 'no link. ${r.why}');
      await r.finish();
    });

    testWidgets('typed "l" joins as code "1"', (tester) async {
      final _Rig r = await _Rig.open(tester, 'frame l is 1');
      await r.type('l');
      final Map<String, Object?> d = await r.tapJoinAndReadFrame();
      expect(
        d['code'],
        '1',
        reason: 'expected the canonical code "1" on the wire, d=$d. ${r.why}',
      );
      await r.finish();
    });

    testWidgets('six symbols: join_room carries the code and install', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'frame six symbols');
      await r.type('k7-m2 qp');
      final Map<String, Object?> d = await r.tapJoinAndReadFrame();
      expect(d['code'], 'K7M2QP', reason: 'expected K7M2QP, d=$d. ${r.why}');
      expect(d['install'], _installA, reason: 'expected install. ${r.why}');
      await r.finish();
    });

    testWidgets('no stored install: the join still carries a made one', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(
        tester,
        'frame install made',
        prefs: const <String, Object>{},
      );
      await r.type('Z');
      final Map<String, Object?> d = await r.tapJoinAndReadFrame();
      final Object? install = d['install'];
      expect(
        install is String && _installShape.hasMatch(install),
        isTrue,
        reason:
            'expected install of 16..64 chars [A-Za-z0-9_-] on a code join '
            'with nothing stored; saw $install in d=$d. ${r.why}',
      );
      final SharedPreferences prefs = await tester.runAsync(
        SharedPreferences.getInstance,
      ) as SharedPreferences;
      expect(
        prefs.getString('install_id'),
        install,
        reason: 'the install sent must be the one stored. ${r.why}',
      );
      await r.finish();
    });

    testWidgets('two code joins from one phone carry the same install', (
      tester,
    ) async {
      final _Rig r = await _Rig.open(
        tester,
        'frame install stable',
        prefs: const <String, Object>{},
      );
      await r.type('Z');
      final Map<String, Object?> first = await r.tapJoinAndReadFrame();
      await r.backToHome();
      await r.type('Y');
      final Map<String, Object?> second = await r.tapJoinAndReadFrame();
      expect(
        r.transports,
        hasLength(2),
        reason: 'expected a second transport for the second join. ${r.why}',
      );
      expect(
        second['install'],
        first['install'],
        reason:
            'expected one install across two joins, saw '
            '${first['install']} then ${second['install']}. ${r.why}',
      );
      await r.finish();
    });
  });
}
