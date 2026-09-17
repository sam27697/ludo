// Widget tests for HomeScreen session memory: after a successful create,
// a fresh HomeScreen (a relaunch) restores the typed name and seat count
// without retyping, shows home-last-table-chip, and still paints Create
// as the elevated action while Join stays outlined.
//
// Create Room builds a RoomController from widget.controllerFactory().
// These tests inject a factory wired to FakeTransport so the create can
// succeed on the wire. LobbyScreen's connecting state shows a
// CircularProgressIndicator, so these tests never call pumpAndSettle
// after a Create tap. A bounded 400ms pump covers MaterialPageRoute's
// default 300ms transition.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';

import 'net/fake_transport.dart';

const Key _nameKey = Key('home-name-field');
const Key _selectorKey = Key('home-players-selector');
const Key _disclosureKey = Key('home-players-disclosure');
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

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

AppLocalizations _loc(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(Scaffold)));
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

Future<void> _openPlayersDisclosure(WidgetTester tester) async {
  expect(
    find.byKey(_disclosureKey),
    findsOneWidget,
    reason:
        'home-players-disclosure must be on screen so the player can '
        'open the seat-count selector',
  );
  await tester.ensureVisible(find.byKey(_disclosureKey));
  await tester.tap(find.byKey(_disclosureKey));
  await tester.pumpAndSettle();
  expect(
    find.byKey(_selectorKey),
    findsOneWidget,
    reason: 'tapping home-players-disclosure must reveal home-players-selector',
  );
}

Future<void> _selectPlayers(WidgetTester tester, int count) async {
  final AppLocalizations loc = _loc(tester);
  final String label = switch (count) {
    2 => loc.homePlayersTwo,
    3 => loc.homePlayersThree,
    4 => loc.homePlayersFour,
    _ => throw ArgumentError.value(count, 'count', 'must be 2, 3 or 4'),
  };
  await tester.ensureVisible(find.byKey(_selectorKey));
  await tester.tap(
    find.descendant(of: find.byKey(_selectorKey), matching: find.text(label)),
  );
  await tester.pump();

  final SegmentedButton<int> segmented = tester.widget<SegmentedButton<int>>(
    find.descendant(
      of: find.byKey(_selectorKey),
      matching: find.byType(SegmentedButton<int>),
    ),
  );
  expect(segmented.selected, <int>{
    count,
  }, reason: 'selecting $count must select that segment before Create Room');
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
    _dataOf(createMessages.single),
    <String, Object?>{'name': name, 'players': seats},
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

/// Hosts a two-seat table as [name], waits until the lobby shows the
/// server code, then pumps a brand-new HomeScreen (a process relaunch).
Future<void> _hostThenRelaunchHome(
  WidgetTester tester, {
  required String name,
  required int seats,
}) async {
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
  await _openPlayersDisclosure(tester);
  await _selectPlayers(tester, seats);
  await _tapAndAwaitPushedRoute(tester, _createKey);

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

/// In-memory [SharedPreferences.setMockInitialValues] for these widget
/// tests. Starts empty so Home has no last-table memory until a successful
/// create writes one; later reads see those writes in the same test.
class SharedPreferences {
  static const String _prefix = 'flutter.';
  static const MethodChannel _channel = MethodChannel(
    'plugins.flutter.io/shared_preferences',
  );

  static String _storeKey(String key) =>
      key.startsWith(_prefix) ? key : '$_prefix$key';

  static void setMockInitialValues(Map<String, Object> values) {
    final Map<String, Object> memory = <String, Object>{
      for (final MapEntry<String, Object> entry in values.entries)
        _storeKey(entry.key): entry.value,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall methodCall) async {
          final Object? raw = methodCall.arguments;
          final Map<Object?, Object?> args = raw is Map<Object?, Object?>
              ? raw
              : const <Object?, Object?>{};
          switch (methodCall.method) {
            case 'getAll':
              return memory;
            case 'getAllWithPrefix':
              final String prefix = args['prefix'] as String? ?? '';
              return <String, Object>{
                for (final MapEntry<String, Object> entry in memory.entries)
                  if (entry.key.startsWith(prefix)) entry.key: entry.value,
              };
            case 'remove':
              memory.remove(args['key']);
              return true;
            case 'clear':
              memory.clear();
              return true;
            default:
              if (methodCall.method.startsWith('set')) {
                final String? key = args['key'] as String?;
                final Object? value = args['value'];
                if (key != null && value != null) {
                  memory[key] = value;
                }
                return true;
              }
              return null;
          }
        });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('relaunch after successful create restores last name and seats '
      'without retyping', (tester) async {
    const String hostedName = 'Priya';
    const int hostedSeats = 2;

    await _hostThenRelaunchHome(tester, name: hostedName, seats: hostedSeats);

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

    await _tapAndAwaitPushedRoute(tester, _createKey);
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
          'Create after relaunch, with no seat re-pick, must still send '
          'players $hostedSeats; got ${pushed.players}',
    );
  });

  testWidgets('relaunch after successful create shows home-last-table-chip and '
      'Create still outweighs Join', (tester) async {
    await _hostThenRelaunchHome(tester, name: 'Priya', seats: 2);

    expect(
      find.byKey(_chipKey),
      findsOneWidget,
      reason:
          'when last-table memory exists, Home must show a widget keyed '
          'home-last-table-chip',
    );

    expect(
      find.byKey(_codeKey),
      findsOneWidget,
      reason: 'fixture is broken: room-code-field must be on Home',
    );
    expect(
      tester.widget<TextField>(find.byKey(_codeKey)).controller?.text,
      '',
      reason:
          'this emphasis check is the empty-code case; the relaunch must '
          'leave room-code-field empty',
    );

    expect(
      _keyedButton(tester, _createKey),
      isA<ElevatedButton>(),
      reason:
          'with home-last-table-chip visible and an empty code field, '
          'create-room-button must still be an ElevatedButton; found '
          '${_keyedButton(tester, _createKey).runtimeType}',
    );
    expect(
      _keyedButton(tester, _joinKey),
      isA<OutlinedButton>(),
      reason:
          'with home-last-table-chip visible and an empty code field, '
          'join-room-button must still be an OutlinedButton; found '
          '${_keyedButton(tester, _joinKey).runtimeType}',
    );
  });
}
