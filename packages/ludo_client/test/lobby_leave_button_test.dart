// Conformance tests for order 186's lobby-leave-button contract (work/ludo/
// orders/185-prove-lobby-leave-button.md), written against that order's
// text, not against lib/src/lobby_screen.dart as it stands on this branch.
// LobbyScreen currently has no way out of lobby-error or lobby-closed short
// of the Android system back gesture; the game screen's equivalent body
// already solved this with game-screen-leave-button, an OutlinedButton
// labelled loc.gameLeaveButton that only pops the route. This file pins the
// lobby's own lobby-leave-button doing the same thing in both bodies.
//
// On this base commit lobby_screen.dart has no lobby-leave-button anywhere,
// so every case below is expected to fail, each on that missing widget.
//
// LobbyScreen is driven the same way test/lobby_screen_test.dart and
// test/lobby_screen_die_code_start_label_test.dart drive RoomController: a
// real RoomController sits over a FakeTransport
// (test/net/fake_transport.dart, read-only, not edited here) and a small
// connector double copied from that shared idiom, never a mock of
// RoomController. The pop-observer harness (_PopObserver, the push-route
// scaffold) is copied from lobby_screen_die_code_start_label_test.dart's
// 'connecting shows lobby-cancel-button that pops the route' case rather
// than imported, per this order's instruction to copy the helper.
//
// Every case asserts its own phase-body key (lobby-closed or lobby-error)
// findsOneWidget before asserting anything about lobby-leave-button, so a
// rig that never reaches the intended phase fails distinctly from the
// contract itself being unmet.

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

const Key _closedKey = Key('lobby-closed');
const Key _errorKey = Key('lobby-error');
const Key _leaveKey = Key('lobby-leave-button');
const Key _reconnectKey = Key('lobby-reconnect-button');
const Key _retryKey = Key('lobby-retry-button');
const Key _openLobbyKey = Key('open-lobby');

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom -----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'leave-btn-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// Copied from lobby_screen_die_code_start_label_test.dart's own copy
/// rather than imported, per this order's instruction.
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
  transport.pushText(_frame(type: 'room', re: requestId, data: _roomJson()));
  await tester.pump();
  await tester.pump();
}

Future<void> _resolveFailed(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required String code,
}) async {
  transport.pushText(
    _frame(
      type: 'error',
      re: requestId,
      data: <String, Object?>{'code': code, 'message': ''},
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'X-C1: lobby-closed carries an enabled lobby-leave-button labelled '
    'loc.gameLeaveButton, alongside lobby-reconnect-button',
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
          playerName: 'Sam',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(tester, transport, id, seatForThisClient: 0);
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture check: the rig must reach RoomPhase.connected before '
            'the transport can be dropped into lobby-closed; got '
            '${controller.phase}',
      );

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'fixture check: expected the dropped transport to land the '
            'controller in RoomPhase.closed; got ${controller.phase}',
      );
      expect(
        find.byKey(_closedKey),
        findsOneWidget,
        reason:
            'fixture check: lobby-closed must be on screen before X-C1 can '
            'be asserted; a failure here means the rig never reached '
            'lobby-closed, which is a broken scenario, not the contract '
            'under test',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'X-C1: lobby-closed must contain a widget keyed '
            'lobby-leave-button (work/ludo/orders/185-prove-lobby-leave-'
            'button.md contract X-C1)',
      );
      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason:
            'X-C1: lobby-leave-button must have a non-null onPressed '
            '(contract X-C1)',
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
            'X-C1: lobby-leave-button\'s label Text must equal '
            'loc.gameLeaveButton, which reads "${loc.gameLeaveButton}" '
            '(contract X-C1)',
      );
      expect(
        find.byKey(_reconnectKey),
        findsOneWidget,
        reason:
            'X-C1: lobby-reconnect-button must still be present alongside '
            'lobby-leave-button (contract X-C1)',
      );
    },
  );

  testWidgets(
    'X-C2: tapping lobby-leave-button in lobby-closed pops the lobby route',
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
                              playerName: 'Sam',
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
        await _resolveConnected(tester, transport, id, seatForThisClient: 0);
        expect(
          controller.phase,
          RoomPhase.connected,
          reason:
              'fixture check: the rig must reach RoomPhase.connected '
              'before the transport can be dropped into lobby-closed; got '
              '${controller.phase}',
        );

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();

        expect(
          controller.phase,
          RoomPhase.closed,
          reason:
              'fixture check: expected the dropped transport to land the '
              'controller in RoomPhase.closed; got ${controller.phase}',
        );
        expect(
          find.byKey(_closedKey),
          findsOneWidget,
          reason:
              'fixture check: lobby-closed must be on screen before X-C2 '
              'can be asserted; a failure here means the rig never '
              'reached lobby-closed, which is a broken scenario, not the '
              'contract under test',
        );

        final Finder leaveFinder = find.byKey(_leaveKey);
        expect(
          leaveFinder,
          findsOneWidget,
          reason:
              'X-C2: lobby-closed must contain a widget keyed '
              'lobby-leave-button to tap (contract X-C2)',
        );

        await tester.tap(leaveFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          observer.popCount,
          1,
          reason:
              'X-C2: tapping lobby-leave-button in lobby-closed must pop '
              'the lobby route; didPop count was ${observer.popCount} '
              '(contract X-C2)',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'X-C2: after tapping lobby-leave-button, LobbyScreen must no '
              'longer be in the tree (contract X-C2)',
        );
        expect(find.byKey(_openLobbyKey), findsOneWidget);
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets(
    'X-E1: lobby-error carries an enabled lobby-leave-button labelled '
    'loc.gameLeaveButton, alongside lobby-retry-button',
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
          playerName: 'Sam',
          players: 4,
        ),
        transport,
      );
      await _resolveFailed(tester, transport, id, code: 'ROOM_FULL');

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture check: the rig must reach RoomPhase.failed for the '
            'lobby-error body; got ${controller.phase}',
      );
      expect(
        find.byKey(_errorKey),
        findsOneWidget,
        reason:
            'fixture check: lobby-error must be on screen before X-E1 can '
            'be asserted; a failure here means the rig never reached '
            'lobby-error, which is a broken scenario, not the contract '
            'under test',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'X-E1: lobby-error must contain a widget keyed '
            'lobby-leave-button (contract X-E1)',
      );
      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason:
            'X-E1: lobby-leave-button must be enabled (non-null '
            'onPressed) (contract X-E1)',
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
            'X-E1: lobby-leave-button must be labelled loc.gameLeaveButton, '
            'which reads "${loc.gameLeaveButton}" (contract X-E1)',
      );
      expect(
        find.byKey(_retryKey),
        findsOneWidget,
        reason:
            'X-E1: lobby-retry-button must still be present alongside '
            'lobby-leave-button (contract X-E1)',
      );
    },
  );

  testWidgets('X-E2: tapping lobby-leave-button in lobby-error pops the '
      'lobby route', (WidgetTester tester) async {
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
                            playerName: 'Sam',
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
      await _resolveFailed(tester, transport, id, code: 'ROOM_FULL');

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'fixture check: the rig must reach RoomPhase.failed for the '
            'lobby-error body; got ${controller.phase}',
      );
      expect(
        find.byKey(_errorKey),
        findsOneWidget,
        reason:
            'fixture check: lobby-error must be on screen before X-E2 can '
            'be asserted; a failure here means the rig never reached '
            'lobby-error, which is a broken scenario, not the contract '
            'under test',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'X-E2: lobby-error must contain a widget keyed '
            'lobby-leave-button to tap (contract X-E2)',
      );

      await tester.tap(leaveFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        observer.popCount,
        1,
        reason:
            'X-E2: tapping lobby-leave-button in lobby-error must pop the '
            'lobby route; didPop count was ${observer.popCount} (contract '
            'X-E2)',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason:
            'X-E2: after tapping lobby-leave-button, LobbyScreen must no '
            'longer be in the tree (contract X-E2)',
      );
      expect(find.byKey(_openLobbyKey), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });

  testWidgets(
    "X-AR: X-C1 in Locale('ar') -- lobby-leave-button's label equals that "
    "tree's own loc.gameLeaveButton",
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
          playerName: 'سام',
          players: 4,
        ),
        transport,
        locale: const Locale('ar'),
      );
      await _resolveConnected(tester, transport, id, seatForThisClient: 0);
      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture check: the rig must reach RoomPhase.connected before '
            'the transport can be dropped into lobby-closed; got '
            '${controller.phase}',
      );

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason:
            'fixture check: expected the dropped transport to land the '
            'controller in RoomPhase.closed; got ${controller.phase}',
      );
      expect(
        find.byKey(_closedKey),
        findsOneWidget,
        reason:
            'fixture check: lobby-closed must be on screen before X-AR can '
            'be asserted; a failure here means the rig never reached '
            'lobby-closed, which is a broken scenario, not the contract '
            'under test',
      );

      final Finder leaveFinder = find.byKey(_leaveKey);
      expect(
        leaveFinder,
        findsOneWidget,
        reason:
            'X-AR: lobby-closed must contain a widget keyed '
            'lobby-leave-button in Locale(ar) too (contract X-AR)',
      );
      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(
        leaveFinder,
      );
      expect(
        button.onPressed,
        isNotNull,
        reason:
            'X-AR: lobby-leave-button must have a non-null onPressed '
            '(contract X-AR)',
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
            "X-AR: lobby-leave-button's label must equal this tree's own "
            'loc.gameLeaveButton, which reads "${loc.gameLeaveButton}" '
            '(contract X-AR)',
      );
      expect(
        find.byKey(_reconnectKey),
        findsOneWidget,
        reason:
            'X-AR: lobby-reconnect-button must still be present alongside '
            'lobby-leave-button (contract X-AR)',
      );
    },
  );
}
