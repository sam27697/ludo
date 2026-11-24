// Widget tests for HomeScreen session memory: after a successful create,
// a fresh HomeScreen (a relaunch) restores the typed name without
// retyping, shows no last-table chip (C-678), and still paints Create as the
// elevated action while Join stays outlined. Since C-666 D1 there is no seat
// count to restore: a create records seats 4, and an older stored count of
// 2 or 3 is read and ignored, Create sending 4 either way.
//
// Create Room builds a RoomController from widget.controllerFactory().
// These tests inject a factory wired to FakeTransport so the create can
// succeed on the wire. LobbyScreen's connecting state shows a
// CircularProgressIndicator, so these tests never call pumpAndSettle
// after a Create tap. A bounded 400ms pump covers MaterialPageRoute's
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
import 'support/home_flow.dart';

const Key _nameKey = Key('home-name-field');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _chipKey = Key('home-last-table-chip');

const String _testUrl = 'wss://home-session-memory-test.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'session-mem-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  required int players,
  required int hostSeat,
  required List<Map<String, Object?>> seats,
  required int seq,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': null,
  'winner': null,
  'seq': seq,
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

Widget _homeScreenApp(RoomControllerFactory controllerFactory, {Key? key}) {
  return MaterialApp(
    key: key,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

/// Order 701: Create opens the sheet and the friends-only tile creates the
/// room; the same bounded pumps follow as for any pushed route.
Future<void> _createAndAwaitPushedRoute(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_createKey));
  await tapCreateRoom(tester);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _nameFieldText(WidgetTester tester) {
  expect(find.byKey(_nameKey), findsOneWidget);
  return tester.widget<TextField>(find.byKey(_nameKey)).controller!.text;
}

LobbyScreen _pushedLobbyScreen(WidgetTester tester) {
  final Finder finder = find.byType(LobbyScreen);
  expect(
    finder,
    findsOneWidget,
    reason:
        'expected exactly one LobbyScreen to have been pushed; found '
        '${finder.evaluate().length}',
  );
  return tester.widget<LobbyScreen>(finder);
}

Widget _keyedButton(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget);
  return tester.widget(find.byKey(key));
}

Future<void> _completeSuccessfulCreate(
  WidgetTester tester,
  FakeTransport transport, {
  required String name,
  required int seats,
}) async {
  final List<String> createMessages = transport.sentRaw
      .where((String sent) => _typeOf(sent) == 'create_room')
      .toList();
  expect(
    createMessages,
    hasLength(1),
    reason:
        'Create Room must have sent one create_room request before this '
        'check treats the create as successful; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  expect(
    // Section 32 item 6: create_room also carries `install`; the rest of the
    // frame is unchanged.
    Map<String, Object?>.of(_dataOf(createMessages.single))..remove('install'),
    <String, Object?>{
      'name': name,
      'players': seats,
      // Order 202: Home's rule toggles, untouched, reach the wire as defaults.
      'rules': <String, Object?>{'capture_bonus': true},
    },
    reason:
        'the typed name and chosen seat count must reach the wire before '
        'the create is treated as successful',
  );
  final String createId = _idOf(createMessages.single);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-session-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        code: 'ZQ2X59',
        players: seats,
        hostSeat: 0,
        seats: <Map<String, Object?>>[_seatJson(0, name: name)],
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(const Key('lobby-room-code')),
    findsOneWidget,
    reason:
        'a successful create must land on a lobby that shows lobby-room-code',
  );
}

/// Hosts a four-seat table as [name], waits until the lobby shows the
/// server code, then pumps a brand-new HomeScreen (a process relaunch).
Future<void> _hostThenRelaunchHome(
  WidgetTester tester, {
  required String name,
}) async {
  const int seats = 4;
  final _RecordingControllerFactory factory = _RecordingControllerFactory();
  addTearDown(() {
    for (final RoomController controller in factory.controllers) {
      controller.dispose();
    }
  });

  await tester.pumpWidget(
    _homeScreenApp(factory.call, key: const ValueKey<String>('session-visit')),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byKey(_nameKey), name);
  await tester.pump();
  await _createAndAwaitPushedRoute(tester);

  expect(
    factory.transports,
    hasLength(1),
    reason: 'Create Room must build one controller for the first visit',
  );
  await _completeSuccessfulCreate(
    tester,
    factory.transports.single,
    name: name,
    seats: seats,
  );

  // Allow an async store write from the successful create to finish
  // before the next HomeScreen mounts.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  // C-447 D7: the create just wrote a fresh seat record, and a relaunch over
  // a fresh record resumes on its own. Dropping the saved time makes it a
  // legacy record, so this relaunch stays on Home as these cases assert.
  await (await SharedPreferences.getInstance()).remove('session.seatSavedAt');

  // A new MaterialApp key drops the old Navigator so this is a relaunch,
  // not a pop back to the still-mounted first HomeScreen.
  await tester.pumpWidget(
    _homeScreenApp(
      factory.call,
      key: const ValueKey<String>('session-relaunch'),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('relaunch after successful create restores last name and the '
      'recorded seats are 4, without retyping', (tester) async {
    const String hostedName = 'Priya';
    const int hostedSeats = 4;

    await _hostThenRelaunchHome(tester, name: hostedName);

    expect(
      (await SharedPreferences.getInstance()).getInt('session.lastSeats'),
      hostedSeats,
      reason:
          'a create records seats 4 in session.lastSeats (C-666 D1: the '
          'storage format is unchanged, the value is always 4)',
    );

    expect(
      find.byKey(_nameKey),
      findsOneWidget,
      reason: 'relaunch must show Home with home-name-field',
    );
    expect(
      _nameFieldText(tester),
      hostedName,
      reason:
          'after a successful create, relaunching Home must show the '
          'hosted name "$hostedName" in home-name-field without retyping; '
          'got "${_nameFieldText(tester)}"',
    );

    await _createAndAwaitPushedRoute(tester);
    final LobbyScreen pushed = _pushedLobbyScreen(tester);
    expect(
      pushed.playerName,
      hostedName,
      reason:
          'Create after relaunch, with no name retyped, must still send '
          '"$hostedName"; got "${pushed.playerName}"',
    );
    expect(
      pushed.players,
      hostedSeats,
      reason:
          'Create after relaunch must send players $hostedSeats; got '
          '${pushed.players}',
    );

    // The relaunch's own Create (above) is never answered on the wire, so
    // RoomConnection's 10 second request timeout outlives this widget tree;
    // fire it now that this test's assertions are done so flutter_test does
    // not find that timer still pending at teardown.
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  });

  testWidgets('relaunch after successful create shows no last-table chip and '
      'Create still outweighs Join', (tester) async {
    await _hostThenRelaunchHome(tester, name: 'Priya');

    expect(
      find.byKey(_chipKey, skipOffstage: false),
      findsNothing,
      reason:
          'C-678 removed the chip: even when last-table memory exists, Home '
          'must not show a widget keyed home-last-table-chip',
    );

    // Order 701: home has no room-code-field; the empty-code case is the
    // only case home can show.
    expect(
      find.byKey(_codeKey, skipOffstage: false),
      findsNothing,
      reason: 'order 701: room-code-field is not on Home',
    );

    expect(
      _keyedButton(tester, _createKey),
      isA<ElevatedButton>(),
      reason:
          'with last-table memory and an empty code field, '
          'create-room-button must still be an ElevatedButton; found '
          '${_keyedButton(tester, _createKey).runtimeType}',
    );
    expect(
      find.byKey(_joinKey, skipOffstage: false),
      findsNothing,
      reason:
          'with last-table memory and an empty code field, '
          'join-room-button must be absent (C-523 D3)',
    );
  });

  for (final int legacy in <int>[2, 3]) {
    testWidgets('a table stored by an older build with $legacy seats is read '
        'and ignored: the name shows, no chip, Create sends 4', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'session.lastName': 'Priya',
        'session.lastSeats': legacy,
      });
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(() {
        for (final RoomController controller in factory.controllers) {
          controller.dispose();
        }
      });
      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a stored seat count of $legacy must never be an error',
      );
      expect(
        find.byKey(_chipKey, skipOffstage: false),
        findsNothing,
        reason: 'C-678: the older stored table shows no home-last-table-chip',
      );
      expect(
        _nameFieldText(tester),
        'Priya',
        reason: 'the older stored table still restores the name',
      );
      expect(
        find.byKey(const Key('home-players-button'), skipOffstage: false),
        findsNothing,
        reason: 'a stored count of $legacy must not bring the control back',
      );

      await _createAndAwaitPushedRoute(tester);
      expect(
        _pushedLobbyScreen(tester).players,
        4,
        reason:
            'Create must send players 4 whatever count an older build '
            'stored ($legacy)',
      );
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
    });
  }
}
