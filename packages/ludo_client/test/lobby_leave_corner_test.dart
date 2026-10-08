// Conformance tests for order 263's contract C-262 ("the lobby's Leave
// moves to the corner", work/ludo/orders/C-262-lobby-leave-corner.md), rules
// 3 and 5, and rule 1's tap behaviour, written against that contract's own
// text, not against lib/src/lobby_screen.dart as it stands on this branch.
// On this branch's base commit (caf4142, run 72) the connected lobby's
// lobby-leave-button is still the old full-width OutlinedButton at the
// bottom of the body (the C-254 seat cards pushed it below the fold in a
// 360 x 616 view, CI capture 14's own failure), so every case below is
// expected to fail, each for the reason it names, and not on anything else.
//
// LobbyScreen is driven the way test/lobby_connected_leave_test.dart does:
// a real RoomController over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here) and a small connector double copied from that
// shared idiom, never a mock of RoomController. Every helper below --
// _Connector, _frame, _roomJson, _seatJson, _twoOfFourSeats, _newController,
// _localizations, _mountAndCaptureRequest, _resolveConnected and
// _PopObserver -- is copied by hand from lobby_connected_leave_test.dart's
// own copy, per this order's instruction to never import across test files.
//
// Fixture for every case: a host lobby, 4 players, 2 of 4 seated, so
// lobby-waiting shows the count and lobby-start-with-present-button shows
// enabled reading "Start with 2". C-274 rule 6 measures lobby-waiting where
// C-262 rule 5 measured the disabled lobby-start-button. The rect bounds
// are the same.

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

const Key _leaveKey = Key('lobby-leave-button');
const Key _waitingKey = Key('lobby-waiting');
const Key _startWithKey = Key('lobby-start-with-present-button');
const Key _openLobbyKey = Key('open-lobby');

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom -----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'leave-corner-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// A 2-of-4 room: seat 0 (the host) and seat 1, both filled. Not full, so
/// lobby-start-with-present-button shows for the host.
List<Map<String, Object?>> _twoOfFourSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Host'),
  _seatJson(1, name: 'Guest'),
];

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

/// Copied from test/lobby_connected_leave_test.dart's own copy rather than
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
        'by now; sentRaw is empty',
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

/// Mounts the host lobby, 4 players, 2 of 4 seated, directly as the home of
/// a MaterialApp (no push-route scaffold, no scrolling action by the test)
/// at the given [size] and [locale]. Returns the controller so the caller
/// can dispose it; the caller owns tearing down the view size too, per
/// lesson 35's one mount per case.
Future<RoomController> _mountHostNotFullAtSize(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

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
    locale: locale,
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

  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture check: the rig must reach RoomPhase.connected before any '
        'rule 5 or rule 3 case can be asserted; got ${controller.phase}',
  );
  expect(
    find.byKey(_startWithKey),
    findsOneWidget,
    reason:
        'fixture check: this scenario (host, 4 players, 2 of 4 seated) '
        'must show lobby-start-with-present-button; a failure here means '
        'the rig never reached the intended state, which is a broken '
        'scenario, not the contract under test',
  );

  return controller;
}

/// C-274 rule 6, keeping C-262 rule 5's bounds: lobby-leave-button,
/// lobby-waiting and lobby-start-with-present-button each found once, each
/// rect entirely inside [size], with no scrolling performed by this helper.
void _expectLeaveWaitingAndStartWithFit(
  WidgetTester tester, {
  required Size size,
  required String caseLabel,
}) {
  for (final Key key in <Key>[_leaveKey, _waitingKey, _startWithKey]) {
    final Finder finder = find.byKey(key);
    expect(
      finder,
      findsOneWidget,
      reason:
          '$caseLabel: expected Key($key) found exactly once (contract '
          'C-262 rule 5, C-274 rule 6)',
    );
    final Rect rect = tester.getRect(finder);
    final bool insideView =
        rect.left >= 0 &&
        rect.top >= 0 &&
        rect.right <= size.width &&
        rect.bottom <= size.height;
    expect(
      insideView,
      isTrue,
      reason:
          '$caseLabel: expected Key($key)\'s rect $rect to lie entirely '
          'inside the $size view without scrolling (contract C-262 rule '
          '5, C-274 rule 6); this helper never scrolls, so a widget '
          'outside the view here is a real finding, not something to '
          'work around',
    );
  }
}

void main() {
  // --- rule 5: fits at both sizes, both locales, no scrolling. -------------
  testWidgets('rule 5: 360x616 en -- lobby-leave-button, lobby-waiting and '
      'lobby-start-with-present-button each fit inside the view', (
    WidgetTester tester,
  ) async {
    const Size size = Size(360, 616);
    await _mountHostNotFullAtSize(
      tester,
      size: size,
      locale: const Locale('en'),
    );
    _expectLeaveWaitingAndStartWithFit(
      tester,
      size: size,
      caseLabel: 'rule 5 (360x616 en)',
    );
  });

  testWidgets('rule 5: 360x616 ar -- lobby-leave-button, lobby-waiting and '
      'lobby-start-with-present-button each fit inside the view', (
    WidgetTester tester,
  ) async {
    const Size size = Size(360, 616);
    await _mountHostNotFullAtSize(
      tester,
      size: size,
      locale: const Locale('ar'),
    );
    _expectLeaveWaitingAndStartWithFit(
      tester,
      size: size,
      caseLabel: 'rule 5 (360x616 ar)',
    );
  });

  testWidgets('rule 5: 800x600 en -- lobby-leave-button, lobby-waiting and '
      'lobby-start-with-present-button each fit inside the view', (
    WidgetTester tester,
  ) async {
    const Size size = Size(800, 600);
    await _mountHostNotFullAtSize(
      tester,
      size: size,
      locale: const Locale('en'),
    );
    _expectLeaveWaitingAndStartWithFit(
      tester,
      size: size,
      caseLabel: 'rule 5 (800x600 en)',
    );
  });

  testWidgets('rule 5: 800x600 ar -- lobby-leave-button, lobby-waiting and '
      'lobby-start-with-present-button each fit inside the view', (
    WidgetTester tester,
  ) async {
    const Size size = Size(800, 600);
    await _mountHostNotFullAtSize(
      tester,
      size: size,
      locale: const Locale('ar'),
    );
    _expectLeaveWaitingAndStartWithFit(
      tester,
      size: size,
      caseLabel: 'rule 5 (800x600 ar)',
    );
  });

  // --- rule 3: exactly one lobby-leave-button, no stray OutlinedButton. ----
  testWidgets(
    'rule 3: exactly one lobby-leave-button, and no OutlinedButton anywhere '
    'carries a loc.gameLeaveButton Text',
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

      expect(
        controller.phase,
        RoomPhase.connected,
        reason:
            'fixture check: the rig must reach RoomPhase.connected before '
            'rule 3 can be asserted; got ${controller.phase}',
      );
      expect(
        find.byKey(_startWithKey),
        findsOneWidget,
        reason:
            'fixture check: this scenario (host, 4 players, 2 of 4 seated) '
            'must show lobby-start-with-present-button; a failure here '
            'means the rig never reached the intended state',
      );

      expect(
        find.byKey(_leaveKey),
        findsOneWidget,
        reason:
            'rule 3: exactly one widget keyed lobby-leave-button must exist '
            'in the connected lobby (contract C-262 rule 3)',
      );

      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(
        find.descendant(
          of: find.byType(OutlinedButton),
          matching: find.text(loc.gameLeaveButton),
        ),
        findsNothing,
        reason:
            'rule 3: no OutlinedButton anywhere in the connected lobby may '
            'carry a loc.gameLeaveButton Text descendant, which reads '
            '"${loc.gameLeaveButton}" (contract C-262 rule 3: the bottom '
            'OutlinedButton goes)',
      );
    },
  );

  // --- rule 1: tapping lobby-leave-button does what Leave always did. ------
  // Copied from lobby_connected_leave_test.dart's L-TAP-H idiom: a
  // push-route scaffold with an open-lobby button and a _PopObserver, so
  // tapping lobby-leave-button is proven to pop the pushed LobbyScreen
  // route, exactly as the old OutlinedButton's _leaveLobby already did.
  testWidgets(
    'rule 1: tapping lobby-leave-button in the connected lobby pops the '
    'lobby route, as the old button did',
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

        expect(
          controller.phase,
          RoomPhase.connected,
          reason:
              'fixture check: the rig must reach RoomPhase.connected before '
              'rule 1\'s tap can be asserted; got ${controller.phase}',
        );
        expect(
          find.byKey(_startWithKey),
          findsOneWidget,
          reason:
              'fixture check: this scenario (host, 4 players, 2 of 4 '
              'seated) must show lobby-start-with-present-button',
        );

        final Finder leaveFinder = find.byKey(_leaveKey);
        expect(
          leaveFinder,
          findsOneWidget,
          reason:
              'rule 1: the connected body must contain a widget keyed '
              'lobby-leave-button to tap (contract C-262 rule 1)',
        );

        await tester.tap(leaveFinder);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          observer.popCount,
          1,
          reason:
              'rule 1: tapping lobby-leave-button in the connected lobby '
              'must pop the lobby route, exactly as the old OutlinedButton '
              'did; didPop count was ${observer.popCount} (contract C-262 '
              'rule 1)',
        );
        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'rule 1: after tapping lobby-leave-button, LobbyScreen must '
              'no longer be in the tree',
        );
        expect(find.byKey(_openLobbyKey), findsOneWidget);
      } finally {
        controller.dispose();
      }
    },
  );
}
