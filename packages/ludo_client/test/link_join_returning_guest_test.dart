// Proof for contract C-394 (work/ludo/orders/C-394-returning-guest-link.md):
// a player who has only ever joined our rooms, never created one, still
// gets a one-tap link once a join has remembered their name.
//
// Mounts HomeScreen exactly the way test/link_join_test.dart does for the
// link-driven cases (fake initial link reader, fake link stream, recording
// navigator observer, controller factory over test/net/fake_transport.dart),
// and the way test/home_session_memory_test.dart and test/home_rejoin_test.dart
// do for the cases that drive a real create or join to a connected lobby.
// Every helper below is this file's own copy, written against those files'
// approach, not an import from any of them.
//
// On the base this file was written against (ffe63fd), SessionMemory.record
// SuccessfulJoin takes only a room code and never touches session.lastName,
// and HomeScreen's link gate (_decideLinkAction) and its name-field restore
// both key off hasLastTable (a stored name AND a stored seat count), not off
// a stored name alone. Decisions 1, 2 and 3 of C-394 are red here for that
// reason. Decisions 4, 5 and 6 are pinned green, except where this file's own
// run turned up a finding; see the cases below for exactly which.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _chipKey = Key('home-last-table-chip');
const Key _aboveHomeKey = Key('above-home-probe');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _playersButtonKey = Key('home-players-button');
const Key _lobbyRoomCodeKey = Key('lobby-room-code');

const String _testUrl = 'wss://link-join-returning-guest-test.invalid/ws';

const String _namePrefsKey = 'session.lastName';
const String _seatsPrefsKey = 'session.lastSeats';
const String _seatPrefsKey = 'session.seat';
const String _codesPrefsKey = 'session.recentCodes';

const String _linkCode = 'AB23CD';

Uri _validLink(String code) => Uri.parse('https://ludo.provefair.app/r/$code');

Uri _invalidCodeLink() => Uri.parse('https://ludo.provefair.app/r/AB0234');

List<String> _storedSeat(
  String code, {
  required int seat,
  required String token,
}) => <String>[code, seat.toString(), token];

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'returning-guest-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// Hands out a fresh [RoomController] wired to a fresh [FakeTransport] on
/// every call, remembering both in call order. Shared by every case in this
/// file: the link-driven ones and the ones that drive a real create or join.
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

  void disposeAll() {
    final List<RoomController> pending = List<RoomController>.of(controllers);
    controllers.clear();
    for (final RoomController controller in pending) {
      controller.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Link-driven harness, copied by hand from test/link_join_test.dart.
// ---------------------------------------------------------------------------

/// An [InitialLinkReader] held open until [complete], unless [immediate]
/// is set, in which case [call] returns that uri already completed.
class _FakeInitialLinkReader {
  _FakeInitialLinkReader({this.immediate});

  final Uri? immediate;
  final Completer<Uri?> _completer = Completer<Uri?>();

  Future<Uri?> call() {
    if (immediate != null) {
      return Future<Uri?>.value(immediate);
    }
    return _completer.future;
  }

  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }
}

/// A [LinkStreamOpener] backed by a broadcast controller, matching the one
/// in test/link_join_test.dart. [add] delivers to the current listener
/// synchronously.
class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  Stream<Uri> call() => _controller.stream;

  void add(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();
}

/// Records push, pop, replace and remove, the same shape
/// test/link_join_test.dart's own recorder uses.
class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;
  int popCount = 0;
  int replaceCount = 0;
  int removeCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    replaceCount += 1;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removeCount += 1;
  }
}

class _Mount {
  _Mount({
    required this.factory,
    required this.reader,
    required this.opener,
    required this.observer,
  });

  final _RecordingControllerFactory factory;
  final _FakeInitialLinkReader reader;
  final _FakeLinkStreamOpener opener;
  final _RecordingNavigatorObserver observer;
}

_Mount _prepareLink(WidgetTester tester, {Uri? immediateLink}) {
  final _RecordingControllerFactory factory = _RecordingControllerFactory();
  final _FakeInitialLinkReader reader = _FakeInitialLinkReader(
    immediate: immediateLink,
  );
  final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
  final _RecordingNavigatorObserver observer = _RecordingNavigatorObserver();
  addTearDown(factory.disposeAll);
  addTearDown(opener.close);
  if (immediateLink == null) {
    addTearDown(() => reader.complete(null));
  }
  return _Mount(
    factory: factory,
    reader: reader,
    opener: opener,
    observer: observer,
  );
}

Widget _linkHomeApp(_Mount mount) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: <NavigatorObserver>[mount.observer],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: mount.factory.call,
      initialLinkReader: mount.reader.call,
      linkStream: mount.opener.call,
    ),
  );
}

Future<void> _pumpLinkHome(WidgetTester tester, _Mount mount) async {
  await tester.pumpWidget(_linkHomeApp(mount));
  await tester.pumpAndSettle();
}

/// The push lands one frame after the link's setState, and that route's
/// first frame is offstage. Pump through the first onstage frame. Bounded on
/// purpose: once LobbyScreen is up, its connecting indicator never settles.
Future<void> _pumpAfterLink(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _fieldText(WidgetTester tester, Key key, {bool skipOffstage = true}) {
  final TextField field = tester.widget<TextField>(
    find.byKey(key, skipOffstage: skipOffstage),
  );
  expect(
    field.controller,
    isNotNull,
    reason: 'fixture is broken: $key has no controller attached',
  );
  return field.controller!.text;
}

String? _codeFieldError(WidgetTester tester, {bool skipOffstage = true}) {
  return tester
      .widget<TextField>(find.byKey(_codeKey, skipOffstage: skipOffstage))
      .decoration
      ?.errorText;
}

LobbyScreen _lobby(WidgetTester tester) {
  final Finder finder = find.byType(LobbyScreen);
  expect(
    finder,
    findsOneWidget,
    reason:
        'the one pushed route must be a LobbyScreen (the connecting view of '
        'RoomRoute); found ${finder.evaluate().length}',
  );
  return tester.widget<LobbyScreen>(finder);
}

/// Fires an unanswered join or resume timeout while the tree is still
/// mounted, unmounts so LobbyScreen can drop its listener, then disposes the
/// controller. Copied from test/link_join_test.dart's own helper of the same
/// name.
Future<void> _disposeControllers(
  WidgetTester tester,
  _RecordingControllerFactory factory,
) async {
  if (factory.controllers.isEmpty) {
    return;
  }
  final bool connecting = factory.controllers.any(
    (RoomController controller) => controller.phase == RoomPhase.connecting,
  );
  if (connecting) {
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  factory.disposeAll();
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Create/join-to-connected harness, copied by hand from
// test/home_session_memory_test.dart and test/home_rejoin_test.dart.
// ---------------------------------------------------------------------------

Widget _plainHomeApp(
  RoomControllerFactory controllerFactory, {
  Locale? locale,
}) {
  return MaterialApp(
    locale: locale,
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

AppLocalizations _loc(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(Scaffold)));
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  // Join enters with a full code (C-523 D3), through a 200 ms AnimatedSize at
  // most: let it reach its final rect before the tap.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _popPushedRoute(WidgetTester tester, Finder topRouteFinder) async {
  final BuildContext context = tester.element(topRouteFinder);
  Navigator.of(context).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Advances the clock past RoomConnection's ten-second request timeout and
/// pumps once more, so a request this fixture deliberately never answers
/// (leave_room, on a controller this file pops away from without replying)
/// does not leave a Timer pending when the test ends.
Future<void> _flushAnyOutstandingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

/// Lets an unawaited SessionMemory write finish before the caller reads the
/// store back. Matches the allowance test/home_rejoin_test.dart's own
/// `_letStoreWriteSettle` makes.
Future<void> _letStoreWriteSettle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Opens the players menu (C-523 D2) and picks [count].
Future<void> _selectPlayers(WidgetTester tester, int count) async {
  await tester.ensureVisible(find.byKey(_playersButtonKey));
  await tester.tap(find.byKey(_playersButtonKey));
  await tester.pumpAndSettle();
  expect(
    find.byKey(Key('home-players-option-$count')),
    findsOneWidget,
    reason:
        'fixture is broken: tapping home-players-button must open '
        'home-players-option-$count',
  );
  await tester.tap(find.byKey(Key('home-players-option-$count')));
  await tester.pumpAndSettle();
}

/// Types [name] and [seats], taps Create, and answers the wire so the create
/// lands on a connected lobby. Returns the sent create_room frame's name, for
/// callers that want to assert the store against what was actually sent
/// rather than a hardcoded literal. The transport is read from [factory]
/// only after the tap: tapping Create is what calls
/// `widget.controllerFactory()` and so is what creates it.
Future<String> _completeSuccessfulCreate(
  WidgetTester tester,
  _RecordingControllerFactory factory, {
  required String name,
  required int seats,
}) async {
  await tester.enterText(find.byKey(_nameKey), name);
  await tester.pump();
  await _selectPlayers(tester, seats);
  await _tapAndAwaitPushedRoute(tester, _createKey);

  final FakeTransport transport = factory.transports.last;
  final List<String> createMessages = transport.sentRaw
      .where((String sent) => _typeOf(sent) == 'create_room')
      .toList();
  expect(
    createMessages,
    hasLength(1),
    reason:
        'fixture is broken: tapping create-room-button must send exactly '
        'one create_room; sent ${transport.sentRaw.map(_typeOf).toList()}',
  );
  final String sentName = _dataOf(createMessages.single)['name']! as String;
  final String createId = _idOf(createMessages.single);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-create-0'},
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
        seats: <Map<String, Object?>>[_seatJson(0, name: sentName)],
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(_lobbyRoomCodeKey),
    findsOneWidget,
    reason:
        'fixture is broken: a seat_assigned + room reply to create_room '
        'must land on a connected lobby before this helper returns',
  );
  await _letStoreWriteSettle(tester);
  return sentName;
}

/// Types [name] and [code] into the still-mounted Home, taps Join, and
/// answers the wire so the join lands on a connected lobby. Returns the sent
/// join_room frame's name, for callers that want to assert the store against
/// what was actually sent rather than a hardcoded literal. The transport is
/// read from [factory] only after the tap: tapping Join is what calls
/// `widget.controllerFactory()` and so is what creates it.
Future<String> _completeSuccessfulJoin(
  WidgetTester tester,
  _RecordingControllerFactory factory, {
  String? name,
  required String code,
  required int seat,
  required String seatToken,
}) async {
  if (name != null) {
    await tester.enterText(find.byKey(_nameKey), name);
    await tester.pump();
  }
  await tester.enterText(find.byKey(_codeKey), code);
  await _tapAndAwaitPushedRoute(tester, _joinKey);

  final FakeTransport transport = factory.transports.last;
  final List<String> joinMessages = transport.sentRaw
      .where((String sent) => _typeOf(sent) == 'join_room')
      .toList();
  expect(
    joinMessages,
    hasLength(1),
    reason:
        'fixture is broken: tapping join-room-button must send exactly one '
        'join_room; sent ${transport.sentRaw.map(_typeOf).toList()}',
  );
  final String sentName = _dataOf(joinMessages.single)['name']! as String;
  final String joinId = _idOf(joinMessages.single);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': seat, 'seat_token': seatToken},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: joinId,
      data: _roomJson(
        code: code,
        players: 4,
        hostSeat: 0,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Host'),
          if (seat != 0) _seatJson(seat, name: sentName),
        ],
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(_lobbyRoomCodeKey),
    findsOneWidget,
    reason:
        'fixture is broken: a seat_assigned + room reply to join_room must '
        'land on a connected lobby before this helper returns',
  );
  await _letStoreWriteSettle(tester);
  return sentName;
}

Future<Map<String, Object?>> _rawPrefs() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final Map<String, Object?> out = <String, Object?>{};
  for (final String key in prefs.getKeys()) {
    out[key] = prefs.get(key);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // -- Decisions 1 and 2: a join remembers the name, and Home fills it back
  // in on its own, whether or not a seat count is also stored. -------------

  testWidgets(
    'decisions 1 & 2: a join with a typed name shows it after a relaunch, '
    'and writes no seat count',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(factory.disposeAll);

      await tester.pumpWidget(_plainHomeApp(factory.call));
      await tester.pumpAndSettle();

      await _completeSuccessfulJoin(
        tester,
        factory,
        name: 'Nour',
        code: 'AB23CD',
        seat: 2,
        seatToken: 'tok-d12-001',
      );

      // C-447 D7: the join wrote a fresh seat record; without its saved time
      // it is a legacy record, so the relaunch stays on Home as asserted.
      await (await SharedPreferences.getInstance()).remove(
        'session.seatSavedAt',
      );

      // A new MaterialApp key drops the old Navigator, so the next pump is a
      // relaunch over the same prefs store, not a pop back to this mount.
      await tester.pumpWidget(
        MaterialApp(
          key: const ValueKey<String>('relaunch'),
          supportedLocales: appSupportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: HomeScreen(
            onToggleLocale: () {},
            controllerFactory: factory.call,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(
        _fieldText(tester, _nameKey),
        'Nour',
        reason:
            'decision 2: after a join as "Nour" and a relaunch, '
            'home-name-field must show "Nour" without retyping, whether or '
            'not a seat count is also stored; got '
            '"${_fieldText(tester, _nameKey)}"',
      );

      final Map<String, Object?> prefs = await _rawPrefs();
      expect(
        prefs[_namePrefsKey],
        'Nour',
        reason:
            'decision 1: a successful join must write session.lastName as '
            '"Nour", the value sent on the wire; got '
            '${prefs[_namePrefsKey]}',
      );
      expect(
        prefs.containsKey(_seatsPrefsKey),
        isFalse,
        reason:
            'decision 1: a join must never write or clear session.lastSeats '
            '(it started absent here and must stay absent); prefs holds '
            '${prefs[_seatsPrefsKey]}',
      );
    },
  );

  testWidgets(
    'decision 1 (en): a join with the name left blank stores the resolved '
    'default the wire carried, not a hardcoded literal',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(factory.disposeAll);

      await tester.pumpWidget(_plainHomeApp(factory.call));
      await tester.pumpAndSettle();

      // No enterText on home-name-field: the player never typed a name, so
      // whatever Home's own localised default already shows is what Join
      // resolves and sends.
      final String sentName = await _completeSuccessfulJoin(
        tester,
        factory,
        code: 'AB23CD',
        seat: 2,
        seatToken: 'tok-d1-blank-en',
      );

      final Map<String, Object?> prefs = await _rawPrefs();
      expect(
        prefs[_namePrefsKey],
        sentName,
        reason:
            'decision 1: a join with no typed name must store the resolved '
            'default "$sentName" the join_room frame actually carried, not '
            'leave session.lastName unset and not store a different, '
            'hardcoded literal; prefs holds ${prefs[_namePrefsKey]}',
      );
    },
  );

  testWidgets(
    'decision 1 (ar): a join with the name left blank stores the resolved '
    'default the wire carried, not a hardcoded literal',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      addTearDown(factory.disposeAll);

      await tester.pumpWidget(
        _plainHomeApp(factory.call, locale: const Locale('ar')),
      );
      await tester.pumpAndSettle();

      final AppLocalizations loc = _loc(tester);
      expect(
        loc.localeName,
        'ar',
        reason: 'fixture is broken: this case must be in Arabic',
      );

      final String sentName = await _completeSuccessfulJoin(
        tester,
        factory,
        code: 'AB23CD',
        seat: 2,
        seatToken: 'tok-d1-blank-ar',
      );

      final Map<String, Object?> prefs = await _rawPrefs();
      expect(
        prefs[_namePrefsKey],
        sentName,
        reason:
            'decision 1 in Arabic: a join with no typed name must store the '
            'resolved default "$sentName" the join_room frame actually '
            'carried (Arabic\'s own default, not the English literal '
            '"Player"); prefs holds ${prefs[_namePrefsKey]}',
      );
    },
  );

  testWidgets(
    'decision 1: a join after a create updates the name but never clears '
    'the stored seat count',
    (tester) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();

      await tester.pumpWidget(_plainHomeApp(factory.call));
      await tester.pumpAndSettle();

      await _completeSuccessfulCreate(tester, factory, name: 'Sam', seats: 4);

      await _popPushedRoute(tester, find.byType(LobbyScreen));
      await _flushAnyOutstandingRequestTimeout(tester);
      await _letStoreWriteSettle(tester);

      final Map<String, Object?> afterCreate = await _rawPrefs();
      expect(
        afterCreate[_namePrefsKey],
        'Sam',
        reason:
            'fixture is broken: a successful create must have stored '
            'session.lastName as "Sam" before this test moves on to the '
            'join; got ${afterCreate[_namePrefsKey]}',
      );
      expect(
        afterCreate[_seatsPrefsKey],
        4,
        reason:
            'fixture is broken: a successful create must have stored '
            'session.lastSeats as 4 before this test moves on to the join; '
            'got ${afterCreate[_seatsPrefsKey]}',
      );

      await _completeSuccessfulJoin(
        tester,
        factory,
        name: 'Nour',
        code: 'ZY98XW',
        seat: 1,
        seatToken: 'tok-d1-after-create',
      );
      addTearDown(() => factory.controllers[1].dispose());

      final Map<String, Object?> afterJoin = await _rawPrefs();
      expect(
        afterJoin[_namePrefsKey],
        'Nour',
        reason:
            'decision 1: a join as "Nour" after a create as "Sam" must '
            'overwrite session.lastName to "Nour"; still holds '
            '${afterJoin[_namePrefsKey]}',
      );
      expect(
        afterJoin[_seatsPrefsKey],
        4,
        reason:
            'decision 1: a join must never clear or change the seat count a '
            'previous create stored; session.lastSeats must still read 4; '
            'got ${afterJoin[_seatsPrefsKey]}',
      );
    },
  );

  // -- Decisions 2 and 3: a stored name alone makes the player "known" for -
  // the link gate and fills the name field, but does not show the -----------
  // last-table chip. --------------------------------------------------------

  testWidgets(
    'decisions 2 & 3: a stored name only, no seats -- a valid cold link '
    'pushes once and joins with the stored name, with no last-table chip',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: 'Nour',
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);

      expect(
        _fieldText(tester, _nameKey),
        'Nour',
        reason:
            'decision 2: a stored name with no stored seats must still '
            'fill home-name-field; got "${_fieldText(tester, _nameKey)}"',
      );
      expect(
        find.byKey(_chipKey),
        findsNothing,
        reason:
            'decision 2: hasLastTable needs a seat count too, so a '
            'name-only player must not see home-last-table-chip',
      );

      final int pushesBefore = mount.observer.pushCount;
      mount.reader.complete(_validLink(_linkCode));
      await _pumpAfterLink(tester);

      expect(
        mount.observer.pushCount,
        pushesBefore + 1,
        reason:
            'decision 3: a known player is one with a stored, non-empty '
            'name; a valid link for a name-only player must push exactly '
            'one route (pushCount ${mount.observer.pushCount}, before '
            '$pushesBefore)',
      );
      expect(mount.observer.popCount, 0);
      expect(mount.observer.replaceCount, 0);
      expect(mount.observer.removeCount, 0);

      final FakeTransport transport = mount.factory.transports.single;
      expect(
        transport.sentRaw.map(_typeOf).toList(),
        <String>['join_room'],
        reason:
            'decision 3: a name-only known player\'s valid link must send '
            'exactly one join_room; sent '
            '${transport.sentRaw.map(_typeOf).toList()}',
      );
      expect(
        _dataOf(transport.sentRaw.single),
        <String, Object?>{'code': _linkCode, 'name': 'Nour'},
        reason:
            'decision 3: that join_room must carry the link code '
            '"$_linkCode" and the stored name "Nour"; sent '
            '${_dataOf(transport.sentRaw.single)}',
      );
      await _disposeControllers(tester, mount.factory);
    },
  );

  testWidgets(
    'decisions 2 & 3: a stored name only, no seats -- a valid warm link '
    'pushes once and joins with the stored name, with no last-table chip',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: 'Nour',
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);
      expect(find.byKey(_chipKey), findsNothing);

      mount.reader.complete(null);
      await tester.pump();

      final int pushesBefore = mount.observer.pushCount;
      mount.opener.add(_validLink(_linkCode));
      await _pumpAfterLink(tester);

      expect(
        mount.observer.pushCount,
        pushesBefore + 1,
        reason:
            'decision 3: a known player is one with a stored, non-empty '
            'name; a valid warm link for a name-only player must push '
            'exactly one route (pushCount ${mount.observer.pushCount}, '
            'before $pushesBefore)',
      );
      final FakeTransport transport = mount.factory.transports.single;
      expect(
        _dataOf(transport.sentRaw.single),
        <String, Object?>{'code': _linkCode, 'name': 'Nour'},
        reason:
            'decision 3: the warm link\'s join_room must carry the link '
            'code "$_linkCode" and the stored name "Nour"; sent '
            '${_dataOf(transport.sentRaw.single)}',
      );
      await _disposeControllers(tester, mount.factory);
    },
  );

  // -- Decision 4: a stored seat for the link's own code rejoins with -----
  // resume whether or not a name is stored. -------------------------------

  testWidgets(
    'decision 4: a stored seat for the link\'s own code resumes even when '
    'no name is stored',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _seatPrefsKey: _storedSeat(_linkCode, seat: 2, token: 'tok-d4-001'),
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);

      final int pushesBefore = mount.observer.pushCount;
      mount.reader.complete(_validLink(_linkCode));
      await _pumpAfterLink(tester);

      expect(
        mount.observer.pushCount,
        pushesBefore + 1,
        reason:
            'decision 4: a stored seat for the link\'s own code must rejoin '
            'with resume whether or not a name is stored -- "resume needs '
            'no name" -- so this must push exactly one route even though '
            'no name is stored here (pushCount ${mount.observer.pushCount}, '
            'before $pushesBefore); if this is 0, the link gate is still '
            'keying off hasLastTable (name AND seats) instead of checking '
            'the seat record on its own',
      );
      expect(mount.observer.popCount, 0);
      expect(mount.observer.replaceCount, 0);
      expect(mount.observer.removeCount, 0);

      final LobbyScreen lobby = _lobby(tester);
      expect(
        lobby.action,
        LobbyAction.resume,
        reason:
            'decision 4: the pushed route must be a resume, not a join, for '
            'a stored seat matching the link\'s own code',
      );
      expect(
        lobby.resume,
        SeatRecord(code: _linkCode, seat: 2, seatToken: 'tok-d4-001'),
      );
      final FakeTransport transport = mount.factory.transports.single;
      expect(
        transport.sentRaw.map(_typeOf).toList(),
        <String>['resume'],
        reason:
            'decision 4: a seat record for the link code must send resume, '
            'not join_room; sent ${transport.sentRaw.map(_typeOf).toList()}',
      );
      expect(
        _dataOf(transport.sentRaw.single),
        <String, Object?>{'code': _linkCode, 'seat_token': 'tok-d4-001'},
        reason:
            'decision 4: resume must carry the stored code and seat token '
            'verbatim; sent ${_dataOf(transport.sentRaw.single)}',
      );
      await _disposeControllers(tester, mount.factory);
    },
  );

  // -- Decision 5: everything else in C-296 stands, for a stored-name-only
  // player too. --------------------------------------------------------

  testWidgets(
    'decision 5: a link arriving while another route is above home still '
    'only fills, with just a stored name',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: 'Nour',
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);

      final BuildContext homeContext = tester.element(find.byType(HomeScreen));
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: _aboveHomeKey),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_aboveHomeKey), findsOneWidget);

      final int pushesBefore = mount.observer.pushCount;
      mount.opener.add(_validLink(_linkCode));
      await tester.pump();

      expect(
        _fieldText(tester, _codeKey, skipOffstage: false),
        _linkCode,
        reason:
            'decision 5: a link while another route sits above home must '
            'still fill room-code-field, even for a stored-name-only player',
      );
      expect(
        find.byKey(_aboveHomeKey),
        findsOneWidget,
        reason:
            'decision 5: a link while another route is above home must '
            'never pull the player out of that route',
      );
      expect(
        mount.observer.pushCount,
        pushesBefore,
        reason:
            'decision 5: no new route must be pushed while another route '
            'is above home (pushCount ${mount.observer.pushCount}, before '
            '$pushesBefore)',
      );
      expect(find.byType(LobbyScreen), findsNothing);
      expect(mount.factory.controllers, isEmpty);
    },
  );

  testWidgets(
    'decision 5: an invalid code link still shows the error and pushes '
    'nothing, with just a stored name',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: 'Nour',
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);

      final int pushesBefore = mount.observer.pushCount;
      mount.reader.complete(_invalidCodeLink());
      await tester.pump();
      await tester.pump();

      expect(
        _fieldText(tester, _codeKey),
        isEmpty,
        reason:
            'decision 5: an invalid code must never land in room-code-field, '
            'even for a stored-name-only player',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(HomeScreen)),
      );
      expect(
        _codeFieldError(tester),
        loc.homeRoomCodeInvalid,
        reason:
            'decision 5: an invalid code link must show the invalid-code '
            'error',
      );
      expect(
        mount.observer.pushCount,
        pushesBefore,
        reason:
            'decision 5: an invalid code link must push nothing '
            '(pushCount ${mount.observer.pushCount}, before $pushesBefore)',
      );
      expect(find.byType(LobbyScreen), findsNothing);
      expect(mount.factory.controllers, isEmpty);
    },
  );

  testWidgets(
    'decision 5: a second link while the first join is in flight starts '
    'only one join, with just a stored name',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: 'Nour',
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);

      mount.reader.complete(null);
      await tester.pump();
      // The observer counts Home's own initial route as a push, so the
      // guard is measured as a delta, the way every other link case here
      // measures it.
      final int pushesBefore = mount.observer.pushCount;

      mount.opener.add(_validLink(_linkCode));
      // Deliberately no pump between the two links: the second must land
      // while the first join is still in flight (RoomController.connect has
      // not resolved, because nothing has answered the FakeTransport yet).
      mount.opener.add(_validLink(_linkCode));
      await _pumpAfterLink(tester);

      expect(
        mount.factory.controllers,
        hasLength(1),
        reason:
            'decision 5: a second link landing while the first join is '
            'still in flight must not build a second controller -- a '
            'name-only known player\'s own first link must have started '
            'exactly one join -- built '
            '${mount.factory.controllers.length}; if this is 0, no join '
            'started at all, which is decision 3 (the "known" gate still '
            'keying off hasLastTable) and not this guard; if this is 2, '
            'the in-flight guard itself let a duplicate through',
      );
      expect(
        mount.observer.pushCount,
        pushesBefore + 1,
        reason:
            'decision 5: exactly one route must have been pushed despite '
            'two links landing back to back; pushCount '
            '${mount.observer.pushCount}, before $pushesBefore',
      );
      await _disposeControllers(tester, mount.factory);
    },
  );

  // -- Decision 6: recent codes with no stored name are not enough to make
  // a player known. --------------------------------------------------------

  testWidgets(
    'decision 6: recent codes with no stored name is still first-time for '
    'the link',
    (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _codesPrefsKey: <String>['ZY98XW', 'QW34ER'],
      });
      final _Mount mount = _prepareLink(tester);
      await _pumpLinkHome(tester, mount);

      final int pushesBefore = mount.observer.pushCount;
      mount.reader.complete(_validLink(_linkCode));
      await tester.pump();

      expect(
        _fieldText(tester, _codeKey),
        _linkCode,
        reason:
            'decision 6: a valid link must still fill room-code-field for '
            'a player whose only memory is recent join codes, no name',
      );
      expect(
        _codeFieldError(tester),
        isNull,
        reason: 'decision 6: a valid code must not show the invalid-code error',
      );
      expect(
        mount.observer.pushCount,
        pushesBefore,
        reason:
            'decision 6: recent codes with no stored name are not enough '
            'to be a known player; the link must push nothing '
            '(pushCount ${mount.observer.pushCount}, before $pushesBefore)',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'decision 6: no LobbyScreen must appear',
      );
      expect(
        mount.factory.controllers,
        isEmpty,
        reason:
            'decision 6: no controller, and so no frame, must be sent for '
            'this link',
      );
    },
  );
}
