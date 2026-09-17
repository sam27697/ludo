// Widget tests for recent room-code chips under Join.
//
// After a successful join, Home must show the joined code in a list keyed
// home-recent-codes (max 3, newest first). Each chip is keyed
// home-recent-code-<CODE>. Tapping a chip fills room-code-field and does
// not navigate; Join stays the next tap.
//
// Join Room builds a RoomController from widget.controllerFactory().
// These tests inject a factory wired to FakeTransport so the join can
// succeed on the wire. LobbyScreen's connecting state shows a
// CircularProgressIndicator, so these tests never call pumpAndSettle
// after a Join tap. A bounded 400ms pump covers MaterialPageRoute's
// default 300ms transition.

import 'dart:convert';

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

import 'net/fake_transport.dart';

const Key _nameKey = Key('home-name-field');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _recentListKey = Key('home-recent-codes');
const String _recentChipKeyPrefix = 'home-recent-code-';

const String _testUrl = 'wss://recent-codes-test.invalid/ws';

const String _codeOldest = 'AB23CD';
const String _codeMid = 'K7M2QP';
const String _codeNewer = 'ZQ2X59';
const String _codeNewest = 'H4N8W3';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'recent-codes-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  required String code,
  required String joinerName,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Host'),
    _seatJson(1, name: joinerName),
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
};

class _RecordingControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }
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

Widget _homeScreenApp(
  RoomControllerFactory controllerFactory, {
  Key? key,
  NavigatorObserver? observer,
}) {
  return MaterialApp(
    key: key,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: observer == null
        ? const <NavigatorObserver>[]
        : <NavigatorObserver>[observer],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _popPushedRoute(WidgetTester tester) async {
  final BuildContext context = tester.element(find.byType(LobbyScreen));
  Navigator.of(context).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _flushAnyOutstandingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

String _codeFieldText(WidgetTester tester) {
  expect(find.byKey(_codeKey), findsOneWidget);
  return tester.widget<TextField>(find.byKey(_codeKey)).controller!.text;
}

Key _recentChipKey(String code) => Key('$_recentChipKeyPrefix$code');

List<String> _recentChipCodes(WidgetTester tester) {
  final Finder list = find.byKey(_recentListKey);
  expect(
    list,
    findsOneWidget,
    reason:
        'after a successful join, Home must show recent room-code chips '
        'in a widget keyed home-recent-codes',
  );
  final List<String> codes = <String>[];
  for (final Widget widget in tester.widgetList(
    find.descendant(
      of: list,
      matching: find.byWidgetPredicate((Widget widget) {
        final Key? key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith(_recentChipKeyPrefix);
      }),
    ),
  )) {
    final String value = (widget.key! as ValueKey<String>).value;
    codes.add(value.substring(_recentChipKeyPrefix.length));
  }
  return codes;
}

Future<void> _completeSuccessfulJoin(
  WidgetTester tester,
  FakeTransport transport, {
  required String code,
  required String name,
}) async {
  final List<String> joinMessages = transport.sentRaw
      .where((String sent) => _typeOf(sent) == 'join_room')
      .toList();
  expect(
    joinMessages,
    hasLength(1),
    reason:
        'Join Room must have sent one join_room request before this '
        'check treats the join as successful; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  expect(
    _dataOf(joinMessages.single),
    <String, Object?>{'code': code, 'name': name},
    reason:
        'the typed code and name must reach the wire before the join '
        'is treated as successful',
  );
  final String joinId = _idOf(joinMessages.single);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-recent-$code'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: joinId,
      data: _roomJson(code: code, joinerName: name),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(const Key('lobby-room-code')),
    findsOneWidget,
    reason: 'a successful join must land on a lobby that shows lobby-room-code',
  );
}

Future<void> _joinThenReturnHome(
  WidgetTester tester,
  _RecordingControllerFactory factory, {
  required String code,
  required String name,
}) async {
  await tester.enterText(find.byKey(_nameKey), name);
  await tester.pump();
  await tester.enterText(find.byKey(_codeKey), code);
  await tester.pump();
  await _tapAndAwaitPushedRoute(tester, _joinKey);

  expect(
    factory.transports,
    isNotEmpty,
    reason: 'Join Room must build a controller through the injected factory',
  );
  await _completeSuccessfulJoin(
    tester,
    factory.transports.last,
    code: code,
    name: name,
  );

  await _popPushedRoute(tester);
  await _flushAnyOutstandingRequestTimeout(tester);
  expect(
    find.byKey(_codeKey),
    findsOneWidget,
    reason: 'backing out of the lobby must return to Home with room-code-field',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'successful join then return to Home shows that code newest-first in '
    'home-recent-codes',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();

      await _joinThenReturnHome(
        tester,
        factory,
        code: _codeOldest,
        name: 'Riri',
      );

      expect(
        _recentChipCodes(tester),
        <String>[_codeOldest],
        reason:
            'after a successful join, Home must show the joined code '
            '"$_codeOldest" in home-recent-codes, newest first',
      );
      expect(find.byKey(_recentChipKey(_codeOldest)), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(_recentListKey),
          matching: find.text(_codeOldest),
        ),
        findsOneWidget,
        reason: 'the recent chip for $_codeOldest must show that code',
      );
    },
  );

  testWidgets('four successful joins keep at most three chips newest first', (
    tester,
  ) async {
    final _RecordingControllerFactory factory = _RecordingControllerFactory();
    await tester.pumpWidget(_homeScreenApp(factory.call));
    await tester.pumpAndSettle();

    const List<String> joined = <String>[
      _codeOldest,
      _codeMid,
      _codeNewer,
      _codeNewest,
    ];
    for (final String code in joined) {
      await _joinThenReturnHome(tester, factory, code: code, name: 'Riri');
    }

    expect(
      _recentChipCodes(tester),
      <String>[_codeNewest, _codeNewer, _codeMid],
      reason:
          'home-recent-codes must keep at most three codes, newest first; '
          'after joining $joined the list must be '
          '[$_codeNewest, $_codeNewer, $_codeMid]',
    );
    expect(
      find.byKey(_recentChipKey(_codeOldest)),
      findsNothing,
      reason:
          'the oldest of four successful joins ($_codeOldest) must drop '
          'off the recent list',
    );
    expect(find.byKey(_recentChipKey(_codeNewest)), findsOneWidget);
    expect(find.byKey(_recentChipKey(_codeNewer)), findsOneWidget);
    expect(find.byKey(_recentChipKey(_codeMid)), findsOneWidget);
  });

  testWidgets(
    'relaunch after successful join still shows the code in home-recent-codes',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(
        _homeScreenApp(
          factory.call,
          key: const ValueKey<String>('recent-visit'),
        ),
      );
      await tester.pumpAndSettle();

      await _joinThenReturnHome(tester, factory, code: _codeMid, name: 'Riri');

      await tester.pumpWidget(
        _homeScreenApp(
          factory.call,
          key: const ValueKey<String>('recent-relaunch'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(
        _recentChipCodes(tester),
        <String>[_codeMid],
        reason:
            'after a successful join, relaunching Home must still show '
            '"$_codeMid" in home-recent-codes without retyping',
      );
      expect(find.byKey(_recentChipKey(_codeMid)), findsOneWidget);
    },
  );

  testWidgets(
    'tapping a recent chip fills room-code-field and does not navigate',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      final _NavigatorProbe observer = _NavigatorProbe();
      await tester.pumpWidget(_homeScreenApp(factory.call, observer: observer));
      await tester.pumpAndSettle();

      await _joinThenReturnHome(
        tester,
        factory,
        code: _codeOldest,
        name: 'Riri',
      );

      expect(
        find.byKey(_recentChipKey(_codeOldest)),
        findsOneWidget,
        reason:
            'after a successful join, Home must show a tappable chip keyed '
            'home-recent-code-$_codeOldest so a tap can fill room-code-field '
            'without navigating',
      );

      await tester.enterText(find.byKey(_codeKey), '');
      await tester.pump();
      expect(
        _codeFieldText(tester),
        isEmpty,
        reason:
            'fixture is broken: the code field must be empty before the '
            'chip tap so a leftover join value cannot masquerade as a fill',
      );

      final int pushesBeforeTap = observer.pushCount;
      final int popsBeforeTap = observer.popCount;

      final Finder chip = find.byKey(_recentChipKey(_codeOldest));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        _codeFieldText(tester),
        _codeOldest,
        reason:
            'tapping home-recent-code-$_codeOldest must fill room-code-field '
            'with "$_codeOldest" and nothing else',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'tapping a recent chip must not navigate; Join is the next tap',
      );
      expect(
        observer.pushCount,
        pushesBeforeTap,
        reason:
            'tapping a recent chip must not push a route; pushes went from '
            '$pushesBeforeTap to ${observer.pushCount}',
      );
      expect(
        observer.popCount,
        popsBeforeTap,
        reason: 'tapping a recent chip must not pop a route',
      );
      expect(
        find.byKey(_joinKey),
        findsOneWidget,
        reason: 'Join must remain on Home after a recent-chip tap',
      );
    },
  );
}
