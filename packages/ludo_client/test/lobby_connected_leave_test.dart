// Conformance tests for order 187's contract (work/ludo/orders/187-prove-
// connected-lobby-leave.md): the connected gathering body of LobbyScreen
// (_connectedBody in lib/src/lobby_screen.dart) must carry a
// lobby-leave-button, the same OutlinedButton-labelled-loc.gameLeaveButton
// idiom the error and closed bodies already got from order 185/186. On this
// branch's base commit (5ce4953, PR #69) the connected body has no such
// widget at all, so every contract case below is expected to fail, each on
// that missing widget, and not on anything else. Order 189, a different
// worker on the same round, implements the widget itself; this file is
// written from order 187's own text, not from lib/src/lobby_screen.dart as
// it stands.
//
// LobbyScreen is driven the way test/lobby_screen_test.dart and
// test/lobby_leave_button_test.dart already do: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only, not edited here)
// and a small connector double copied from that shared idiom, never a mock
// of RoomController. The pop-observer harness (_PopObserver, the push-route
// scaffold with an open-lobby button) is copied from
// test/lobby_leave_button_test.dart's own copy, per this order's instruction
// to copy the helper rather than import it.
//
// Every case asserts its own fixture first -- lobby-room-code showing,
// lobby-closed and lobby-error absent, and controller.isHost matching what
// the case needs -- with a reason that says "fixture check", before ever
// touching lobby-leave-button, so a rig that never reaches the connected
// body reads as a different failure from the contract itself being unmet.
//
// Ambiguity found while writing this file, reported rather than invented
// around (standing rule: "Ambiguity is reported, never invented around"):
//
//   Order 187 states "one testWidgets per case, one mount per case"
//   (standing lesson 35) but L-POS's own text requires observing two
//   different trees: "in L-H1's tree, the leave button's top edge is below
//   the start button's bottom edge ...; in L-G1's tree it is below
//   lobby-waiting's bottom edge." A single mount cannot be both a host tree
//   and a guest tree at once, so L-POS is written here as two testWidgets,
//   each with its own single mount reproducing the L-H1 fixture or the L-G1
//   fixture respectively, rather than as one testWidgets with two mounts.
//   This should be checked against whatever order 189's own author, or the
//   master, concludes was intended.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const Key _roomCodeKey = Key('lobby-room-code');
const Key _closedKey = Key('lobby-closed');
const Key _errorKey = Key('lobby-error');
const Key _leaveKey = Key('lobby-leave-button');
const Key _startKey = Key('lobby-start-button');
const Key _waitingKey = Key('lobby-waiting');
const Key _copyLinkKey = Key('lobby-copy-link-button');
const Key _copyCodeKey = Key('lobby-copy-code-button');
const Key _openLobbyKey = Key('open-lobby');

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom -----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'connected-leave-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _seatJson(int seat, {String name = 'Sam'}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

/// A 2-of-4 room: seat 0 (the host) and seat 1, both filled. Not full.
List<Map<String, Object?>> _twoOfFourSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Host'),
  _seatJson(1, name: 'Guest'),
];

/// A 4-of-4 room: every seat filled. Full.
List<Map<String, Object?>> _fourOfFourSeats() =>
    List<Map<String, Object?>>.generate(
      4,
      (int i) => _seatJson(i, name: 'p$i'),
    );

// --- a TransportConnector test double, copied from the sibling suites' own
// --- idiom rather than imported: it is not exported by that file. ----------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

/// Copied from test/lobby_leave_button_test.dart's own copy rather than
/// imported, per this order's instruction.
class _PopObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _localizations({
  required Widget home,
  Locale locale = const Locale('en'),
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
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
    navigatorObservers: observers,
    home: home,
  );
}

Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_localizations(home: screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture check: LobbyScreen.initState must have sent create_room '
        'or join_room by now; sentRaw is empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = 'ABC234',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
}) async {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': seatForThisClient,
        'seat_token': 'tok-$seatForThisClient',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        code: code,
        hostSeat: hostSeat,
        players: players,
        seats: seats,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// The fixture check every case starts with: the connected body is showing
/// (lobby-room-code present, the other two named phase bodies absent), and
/// controller.isHost reads as [expectedIsHost]. A failure here means the rig
/// never reached the connected body, or reached it in the wrong role, which
/// is a broken scenario, not the contract under test -- hence the distinct
/// "fixture check" wording in every reason here, never a case id.
void _expectConnectedFixture(
  WidgetTester tester,
  RoomController controller, {
  required bool expectedIsHost,
}) {
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture check: the rig must reach RoomPhase.connected before any '
        'contract case can be asserted; got ${controller.phase}',
  );
  expect(
    find.byKey(_roomCodeKey),
    findsOneWidget,
    reason:
        'fixture check: lobby-room-code must be on screen (the connected '
        'body must be showing) before a contract case can be asserted',
  );
  expect(
    find.byKey(_closedKey),
    findsNothing,
    reason:
        'fixture check: lobby-closed must not be showing while the '
        'connected body is under test',
  );
  expect(
    find.byKey(_errorKey),
    findsNothing,
    reason:
        'fixture check: lobby-error must not be showing while the '
        'connected body is under test',
  );
  expect(
    controller.isHost,
    expectedIsHost,
    reason:
        'fixture check: this scenario requires controller.isHost == '
        '$expectedIsHost; got ${controller.isHost}',
  );
}

void main() {
  // --- L-H1: host, connected, room not full (2 of 4). ---------------------
  testWidgets(
    'L-H1: host, room not full: lobby-leave-button is present exactly '
    'once, is a ButtonStyleButton with a non-null onPressed, labelled '
    'loc.gameLeaveButton, and lobby-start-button is still present',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Host',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _twoOfFourSeats(),
      );

      _expectConnectedFixture(tester, controller, expectedIsHost: true);
      expect(
        controller.room!.seats.length,
        2,
        reason: 'fixture check: this scenario requires a 2-of-4 room',
      );
      expect(
        controller.room!.players,
        4,
        reason: 'fixture check: this scenario requires a 2-of-4 room',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'L-H1: the connected body must contain a widget keyed '
            'lobby-leave-button exactly once (contract L-H1, work/ludo/'
            'orders/187-prove-connected-lobby-leave.md)',
      );

      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'L-H1: lobby-leave-button must have a non-null onPressed',
      );

      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(
        find.descendant(
          of: leaveFinder,
          matching: find.text(loc.gameLeaveButton),
        ),
        findsOneWidget,
        reason:
            'L-H1: lobby-leave-button\'s label Text must equal '
            'loc.gameLeaveButton, which reads "${loc.gameLeaveButton}"',
      );
      expect(
        find.byKey(_startKey),
        findsOneWidget,
        reason: 'L-H1: lobby-start-button must still be present',
      );
    },
  );

  // --- L-H2: host, connected, room full (4 of 4). --------------------------
  testWidgets(
    'L-H2: host, room full: same as L-H1, and lobby-start-button is enabled',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'p0',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _fourOfFourSeats(),
      );

      _expectConnectedFixture(tester, controller, expectedIsHost: true);
      expect(
        controller.room!.seats.length,
        controller.room!.players,
        reason: 'fixture check: this scenario requires a full 4-of-4 room',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'L-H2: the connected body must contain a widget keyed '
            'lobby-leave-button exactly once, in a full room too (contract '
            'L-H2)',
      );

      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'L-H2: lobby-leave-button must have a non-null onPressed',
      );

      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(
        find.descendant(
          of: leaveFinder,
          matching: find.text(loc.gameLeaveButton),
        ),
        findsOneWidget,
        reason:
            'L-H2: lobby-leave-button\'s label Text must equal '
            'loc.gameLeaveButton, which reads "${loc.gameLeaveButton}"',
      );

      final Finder startFinder = find.byKey(_startKey);
      expect(
        startFinder,
        findsOneWidget,
        reason: 'L-H2: lobby-start-button must still be present',
      );
      final ElevatedButton startButton = tester.widget<ElevatedButton>(
        startFinder,
      );
      expect(
        startButton.onPressed,
        isNotNull,
        reason:
            'L-H2: with a full room, lobby-start-button must be enabled '
            '(non-null onPressed)',
      );
    },
  );

  // --- L-G1: guest, connected, room not full. ------------------------------
  testWidgets(
    'L-G1: guest, room not full: same as L-H1 except no lobby-start-button, '
    'and lobby-waiting is present',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ABC234',
          playerName: 'Guest',
        ),
        transport,
      );
      // Seat 1, host seat 0: this client is not the host.
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 1,
        hostSeat: 0,
        players: 4,
        seats: _twoOfFourSeats(),
      );

      _expectConnectedFixture(tester, controller, expectedIsHost: false);
      expect(
        controller.room!.seats.length,
        2,
        reason: 'fixture check: this scenario requires a 2-of-4 room',
      );
      expect(
        controller.room!.players,
        4,
        reason: 'fixture check: this scenario requires a 2-of-4 room',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'L-G1: the connected body must contain a widget keyed '
            'lobby-leave-button exactly once for a guest too (contract '
            'L-G1)',
      );

      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'L-G1: lobby-leave-button must have a non-null onPressed',
      );

      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(
        find.descendant(
          of: leaveFinder,
          matching: find.text(loc.gameLeaveButton),
        ),
        findsOneWidget,
        reason:
            'L-G1: lobby-leave-button\'s label Text must equal '
            'loc.gameLeaveButton, which reads "${loc.gameLeaveButton}"',
      );
      expect(
        find.byKey(_startKey),
        findsNothing,
        reason:
            'L-G1: a guest must not have lobby-start-button, present or '
            'absent-but-disabled',
      );
      expect(
        find.byKey(_waitingKey),
        findsOneWidget,
        reason: 'L-G1: lobby-waiting must be present for a guest',
      );
    },
  );

  // --- L-POS: geometry, one mount per tree (see the top-of-file ambiguity
  // note about why this is two testWidgets rather than one). ---------------
  testWidgets(
    'L-POS (host tree, the L-H1 fixture): lobby-leave-button sits below '
    'lobby-start-button and is the last control in the body',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Host',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _twoOfFourSeats(),
      );

      _expectConnectedFixture(tester, controller, expectedIsHost: true);

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'L-POS: the connected body must contain a widget keyed '
            'lobby-leave-button before its position can be measured '
            '(contract L-POS)',
      );

      await tester.ensureVisible(leaveFinder);
      await tester.pump();

      final Rect leaveRect = tester.getRect(leaveFinder);
      final Rect startRect = tester.getRect(find.byKey(_startKey));
      expect(
        leaveRect.top,
        greaterThan(startRect.bottom),
        reason:
            'L-POS: in L-H1\'s tree, lobby-leave-button\'s top edge '
            '(${leaveRect.top}) must sit below lobby-start-button\'s '
            'bottom edge (${startRect.bottom})',
      );

      // "Last control in the body": nothing else the host tree shows sits
      // lower than lobby-leave-button either, so lobby-start-button being
      // above it (just proven) is not a coincidence of one comparison.
      for (final Key otherKey in <Key>[
        _copyLinkKey,
        _copyCodeKey,
        const Key('lobby-seat-0'),
        const Key('lobby-seat-1'),
        _startKey,
      ]) {
        final Rect otherRect = tester.getRect(find.byKey(otherKey));
        expect(
          leaveRect.top,
          greaterThan(otherRect.bottom),
          reason:
              'L-POS: lobby-leave-button must be the last control in the '
              'body; its top edge (${leaveRect.top}) must sit below '
              'Key($otherKey)\'s bottom edge (${otherRect.bottom})',
        );
      }
    },
  );

  testWidgets(
    'L-POS (guest tree, the L-G1 fixture): lobby-leave-button sits below '
    'lobby-waiting and is the last control in the body',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ABC234',
          playerName: 'Guest',
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 1,
        hostSeat: 0,
        players: 4,
        seats: _twoOfFourSeats(),
      );

      _expectConnectedFixture(tester, controller, expectedIsHost: false);

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'L-POS: the connected body must contain a widget keyed '
            'lobby-leave-button before its position can be measured '
            '(contract L-POS)',
      );

      await tester.ensureVisible(leaveFinder);
      await tester.pump();

      final Rect leaveRect = tester.getRect(leaveFinder);
      final Rect waitingRect = tester.getRect(find.byKey(_waitingKey));
      expect(
        leaveRect.top,
        greaterThan(waitingRect.bottom),
        reason:
            'L-POS: in L-G1\'s tree, lobby-leave-button\'s top edge '
            '(${leaveRect.top}) must sit below lobby-waiting\'s bottom '
            'edge (${waitingRect.bottom})',
      );

      for (final Key otherKey in <Key>[
        _copyLinkKey,
        _copyCodeKey,
        const Key('lobby-seat-0'),
        const Key('lobby-seat-1'),
        _waitingKey,
      ]) {
        final Rect otherRect = tester.getRect(find.byKey(otherKey));
        expect(
          leaveRect.top,
          greaterThan(otherRect.bottom),
          reason:
              'L-POS: lobby-leave-button must be the last control in the '
              'body; its top edge (${leaveRect.top}) must sit below '
              'Key($otherKey)\'s bottom edge (${otherRect.bottom})',
        );
      }
    },
  );

  // --- L-TAP-H / L-TAP-G: tapping pops the lobby route. --------------------
  testWidgets(
    'L-TAP-H: tapping lobby-leave-button as host pops the lobby route',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      final _PopObserver observer = _PopObserver();

      try {
        await tester.pumpWidget(
          _localizations(
            observers: <NavigatorObserver>[observer],
            home: Builder(
              builder: (BuildContext context) {
                return Scaffold(
                  body: Center(
                    child: TextButton(
                      key: _openLobbyKey,
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => LobbyScreen(
                              controller: controller,
                              action: LobbyAction.create,
                              playerName: 'Host',
                              players: 4,
                            ),
                          ),
                        );
                      },
                      child: const Text('Open'),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.byKey(_openLobbyKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          transport.sentRaw,
          isNotEmpty,
          reason:
              'fixture check: pushed LobbyScreen must have issued '
              'create_room by now',
        );
        final String id = _idOf(transport.sentRaw.last);
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 4,
          seats: _twoOfFourSeats(),
        );

        _expectConnectedFixture(tester, controller, expectedIsHost: true);

        final Finder leaveFinder = find.byKey(_leaveKey);
        expect(
          leaveFinder,
          findsOneWidget,
          reason:
              'L-TAP-H: the connected body must contain a widget keyed '
              'lobby-leave-button to tap (contract L-TAP-H)',
        );

        await tester.ensureVisible(leaveFinder);
        await tester.pump();
        await tester.tap(leaveFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          observer.popCount,
          1,
          reason:
              'L-TAP-H: tapping lobby-leave-button as host must pop the '
              'lobby route; didPop count was ${observer.popCount} '
              '(contract L-TAP-H)',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'L-TAP-H: after tapping lobby-leave-button, LobbyScreen must '
              'no longer be in the tree',
        );
        expect(find.byKey(_openLobbyKey), findsOneWidget);
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets(
    'L-TAP-G: tapping lobby-leave-button as a guest pops the lobby route',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      final _PopObserver observer = _PopObserver();

      try {
        await tester.pumpWidget(
          _localizations(
            observers: <NavigatorObserver>[observer],
            home: Builder(
              builder: (BuildContext context) {
                return Scaffold(
                  body: Center(
                    child: TextButton(
                      key: _openLobbyKey,
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => LobbyScreen(
                              controller: controller,
                              action: LobbyAction.join,
                              code: 'ABC234',
                              playerName: 'Guest',
                            ),
                          ),
                        );
                      },
                      child: const Text('Open'),
                    ),
                  ),
                );
              },
            ),
          ),
        );

        await tester.tap(find.byKey(_openLobbyKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          transport.sentRaw,
          isNotEmpty,
          reason:
              'fixture check: pushed LobbyScreen must have issued '
              'join_room by now',
        );
        final String id = _idOf(transport.sentRaw.last);
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 1,
          hostSeat: 0,
          players: 4,
          seats: _twoOfFourSeats(),
        );

        _expectConnectedFixture(tester, controller, expectedIsHost: false);

        final Finder leaveFinder = find.byKey(_leaveKey);
        expect(
          leaveFinder,
          findsOneWidget,
          reason:
              'L-TAP-G: the connected body must contain a widget keyed '
              'lobby-leave-button to tap (contract L-TAP-G)',
        );

        await tester.ensureVisible(leaveFinder);
        await tester.pump();
        await tester.tap(leaveFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          observer.popCount,
          1,
          reason:
              'L-TAP-G: tapping lobby-leave-button as a guest must pop the '
              'lobby route; didPop count was ${observer.popCount} '
              '(contract L-TAP-G)',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'L-TAP-G: after tapping lobby-leave-button, LobbyScreen must '
              'no longer be in the tree',
        );
        expect(find.byKey(_openLobbyKey), findsOneWidget);
      } finally {
        controller.dispose();
      }
    },
  );

  // --- L-AR: L-G1 in Locale('ar'). ------------------------------------------
  testWidgets(
    "L-AR: L-G1 in Locale('ar') -- lobby-leave-button's label equals that "
    "tree's own loc.gameLeaveButton, and L-POS holds there too",
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      addTearDown(controller.dispose);

      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ABC234',
          playerName: 'ضيف',
        ),
        transport,
        locale: const Locale('ar'),
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 1,
        hostSeat: 0,
        players: 4,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'مضيف'),
          _seatJson(1, name: 'ضيف'),
        ],
      );

      _expectConnectedFixture(tester, controller, expectedIsHost: false);

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            "L-AR: the connected body must contain a widget keyed "
            "lobby-leave-button in Locale('ar') too (contract L-AR)",
      );

      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason: 'L-AR: lobby-leave-button must have a non-null onPressed',
      );

      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(
        find.descendant(
          of: leaveFinder,
          matching: find.text(loc.gameLeaveButton),
        ),
        findsOneWidget,
        reason:
            "L-AR: lobby-leave-button's label must equal this tree's own "
            'loc.gameLeaveButton, which reads "${loc.gameLeaveButton}"',
      );

      await tester.ensureVisible(leaveFinder);
      await tester.pump();

      final Rect leaveRect = tester.getRect(leaveFinder);
      final Rect waitingRect = tester.getRect(find.byKey(_waitingKey));
      expect(
        leaveRect.top,
        greaterThan(waitingRect.bottom),
        reason:
            "L-AR: L-POS holds in Locale('ar') too -- lobby-leave-button's "
            'top edge (${leaveRect.top}) must sit below lobby-waiting\'s '
            'bottom edge (${waitingRect.bottom}); vertical order must not '
            'flip in RTL',
      );

      for (final Key otherKey in <Key>[
        _copyLinkKey,
        _copyCodeKey,
        const Key('lobby-seat-0'),
        const Key('lobby-seat-1'),
        _waitingKey,
      ]) {
        final Rect otherRect = tester.getRect(find.byKey(otherKey));
        expect(
          leaveRect.top,
          greaterThan(otherRect.bottom),
          reason:
              "L-AR: lobby-leave-button must be the last control in the "
              'body in Locale(ar) too; its top edge (${leaveRect.top}) '
              'must sit below Key($otherKey)\'s bottom edge '
              '(${otherRect.bottom})',
        );
      }
    },
  );
}
