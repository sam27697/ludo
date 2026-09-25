// Widget proof of order 179's contract L1, L2, R1, R2, R3
// (work/ludo/orders/179-reconnecting-line-and-lobby-retry.md), driven the
// same way test/lobby_screen_test.dart and
// test/game_screen_connection_lost_test.dart drive their screens: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here) and a small connector double copied from that
// idiom, never a hand-built fake of RoomController itself. Every state this
// file reaches -- a socket drop landing the controller in RoomPhase.closed,
// an automatic reconnect attempt failing at the connector or at the server,
// a held-open attempt still in flight -- is reached by driving the real
// controller through a real transport, the way a player's phone does it,
// never by poking a private field.
//
// Order 177's N1 (room_controller.dart: every place that sets
// _reconnectTimer notifies whenever autoReconnectPending actually changes)
// is read but not depended on for most cases here: L1, L2, R1, R2, R3 all
// give the widget tree a chance to rebuild through an independent
// notification anyway (a phase change), so they would still pass even if
// N1 alone were missing. R-P is written specifically to fail without N1;
// see its own comment for the reasoning and what was and was not measured.
//
// Ambiguities found while writing this file, reported rather than invented
// around:
//
//   1. L-2 duplication. work/ludo/orders/180's own text asks whether L-2
//      duplicates test/lobby_screen_test.dart:720-742. That existing case
//      also lands RoomPhase.failed with controller.room set and errorCode
//      NO_SUCH_ROOM, but reaches it by tapping lobby-resync-button after a
//      seq-gap desync -- a *manual* reconnect the player initiated. L-2
//      below reaches the identical (failed, room set, NO_SUCH_ROOM) state
//      by a different path: an *automatic* reconnect attempt, fired by the
//      auto-reconnect timer after an ordinary drop, with no desync and no
//      tap anywhere in the case. Both paths run through the same L2 branch
//      in lobby_screen.dart (retryableFailure is false either way), so L-2
//      is not proving new branch coverage of the widget, but it is proving
//      that the automatic-reconnect path -- the one this whole file is
//      about -- lands on the correct body too, which lobby_screen_test.dart
//      never exercises (nothing in that file ever passes a non-empty
//      autoReconnectDelays to RoomController). Kept for that reason.
//
//   2. R-P and N1. This case is built so that, reasoning from the source
//      (room_controller.dart's _openAndAttach and _scheduleNextAttempt), it
//      would fail if _scheduleNextAttempt's own notifyListeners() call (the
//      one order 177 added) were removed: the drop handler's own notify for
//      the RoomPhase.closed transition fires *before* _startSequence sets
//      the timer, so with that later notify gone, nothing would mark the
//      widget dirty while autoReconnectPending flips to true, and the short,
//      bounded pumps below (well under the scheduled delay, so the timer
//      itself never fires and produces some other notify) would never
//      trigger a rebuild that could show game-screen-reconnecting. This
//      order's file list forbids touching lib/, so this was reasoned from
//      the source, not measured by reverting N1 and watching this case turn
//      red; that revert-and-watch step is left to whoever reviews this
//      against the source, as the order asks.
//
// Standing lessons this file follows throughout: no pumpAndSettle once
// LobbyScreen or GameScreen is mounted (LobbyScreen's connecting state and
// GameScreen's countdown both hold a ticker that reschedules a frame
// forever); no pumpEventQueue() inside a testWidgets body (only bounded
// pump()/pump(duration) calls); one pumpWidget per case; a controller with
// a still-pending reconnect timer at the point a case's own assertions are
// done is disposed explicitly in the body, not left to addTearDown, because
// flutter_test's own pending-timer check runs before addTearDown callbacks
// fire (test/lobby_screen_test.dart's own "idle-or-connecting" case
// documents and relies on the same ordering).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://order-180-test.invalid/ws';

/// A short, distinctive schedule most cases in this file share, the same
/// idiom test/net/room_controller_auto_reconnect_test.dart and
/// test/net/room_controller_pending_notify_test.dart use: two entries are
/// enough to prove both "one attempt failed, another is pending" (L-1, L-2,
/// R1, R2, R3, R-P) and "the whole schedule exhausted" (R2-X).
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'r180-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites' own idiom -----------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

/// A server push or reply, encoded exactly as Frame.decode expects.
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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot --------------

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  String state = 'LOBBY',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
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
  'seats':
      seats ??
      <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam', connected: true)],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double, copied from the sibling suites' own
// idiom (test/lobby_screen_test.dart's _Connector, test/home_rejoin_test.
// dart's _FlakyThenOkConnector) rather than imported: neither file exports
// one, and neither is on this order's file list to modify. This one adds a
// third mode neither sibling needs: [enqueueHold], a connect() call that
// never resolves on its own, for R3's "attempt held in flight" case. -------

class _Connector {
  final List<Completer<WireTransport>?> _rejectQueue =
      <Completer<WireTransport>?>[];
  final List<FakeTransport?> _transportQueue = <FakeTransport?>[];
  final List<bool> _rejectFlags = <bool>[];
  final List<Uri> calls = <Uri>[];

  /// The next connect() call returns [transport].
  void enqueue(FakeTransport transport) {
    _transportQueue.add(transport);
    _rejectFlags.add(false);
    _rejectQueue.add(null);
  }

  /// The next connect() call rejects, standing in for a transport that
  /// would not open (the shape _openAndAttach maps to errorCode
  /// 'transport').
  void enqueueReject() {
    _transportQueue.add(null);
    _rejectFlags.add(true);
    _rejectQueue.add(null);
  }

  /// The next connect() call returns a Future that never completes on its
  /// own; the caller holds the returned [Completer] and decides when (and
  /// with which transport) it resolves.
  Completer<WireTransport> enqueueHold() {
    final Completer<WireTransport> completer = Completer<WireTransport>();
    _transportQueue.add(null);
    _rejectFlags.add(false);
    _rejectQueue.add(completer);
    return completer;
  }

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_transportQueue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued '
        '(no transport, no reject, no hold); the test scenario is broken, '
        'not the code under test',
      );
    }
    final FakeTransport? transport = _transportQueue.removeAt(0);
    final bool reject = _rejectFlags.removeAt(0);
    final Completer<WireTransport>? hold = _rejectQueue.removeAt(0);
    if (reject) {
      throw StateError(
        '_Connector: connect() call #${calls.length} rejected by the test '
        'scenario, standing in for a transport that would not open',
      );
    }
    if (hold != null) {
      return hold.future;
    }
    return transport!;
  }
}

// --- widget harnesses --------------------------------------------------

Widget _lobbyHarness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

/// Mounts a fresh LobbyAction.create LobbyScreen over [controller] and
/// [transport], waits for the create_room request rule 1 says initState
/// must issue, and returns its id so a reply can target it with `re`.
/// Mirrors test/lobby_screen_test.dart's own _mountAndCaptureRequest:
/// mounting on a fresh idle controller is the only way this codebase's own
/// tests reach RoomPhase.connected/closed/failed correctly (see that file's
/// own ambiguity 2), so every case below that needs a lobby follows the same
/// order -- mount first, then drive the controller's own request to
/// connected, then act on it -- rather than connecting a controller first
/// and mounting LobbyScreen on top of it.
Future<String> _mountLobbyCreate(
  WidgetTester tester,
  RoomController controller,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
  String playerName = 'Sam',
  int players = 4,
}) async {
  await tester.pumpWidget(
    _lobbyHarness(
      LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: playerName,
        players: players,
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture is broken: LobbyScreen.initState must have sent '
        'create_room by now; sentRaw is empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveLobbyConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = 'ABC234',
  int players = 4,
  int hostSeat = 0,
  List<Map<String, Object?>>? seats,
  int seq = 1,
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
        players: players,
        hostSeat: hostSeat,
        seats: seats,
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Drives a fresh controller through createRoom to RoomPhase.connected with
/// a RoomState.playing snapshot, without ever mounting a screen -- the same
/// order test/game_screen_connection_lost_test.dart's own _connectPlaying
/// drives its controller in, since GameScreen (unlike LobbyScreen) has no
/// initState request of its own to race against a pre-seeded phase.
Future<RoomController> _connectPlayingGame(
  WidgetTester tester,
  _Connector connector,
  FakeTransport transport, {
  List<Duration> autoReconnectDelays = const <Duration>[],
  int mySeat = 0,
  int players = 2,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) async {
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
  );

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
  );
  await tester.pump();
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: 'PLAYING',
        players: players,
        seats: seats,
        turn: turn,
        seq: seq,
      ),
    ),
  );
  await future;
  return controller;
}

Widget _gameHarness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mountGame(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _gameHarness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

void main() {
  final List<Map<String, Object?>> midGameSeats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];
  Map<String, Object?> midGameTurn() =>
      _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0);

  // ==========================================================================
  // L-1
  // ==========================================================================
  testWidgets(
    'L-1: host lobby, transport drops, the first automatic attempt fails at '
    'the connector with errorCode transport -> lobby-closed (not lobby-error, '
    'not lobby-retry-button); tapping lobby-reconnect-button opens a new '
    'transport whose first frame is resume carrying the room code and seat '
    'token, and no create_room is ever sent again on any transport',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
        autoReconnectDelays: _delays,
      );

      final String createId = await _mountLobbyCreate(
        tester,
        controller,
        transportA,
      );
      expect(_typeOf(transportA.sentRaw.last), 'create_room');
      await _resolveLobbyConnected(
        tester,
        transportA,
        createId,
        seatForThisClient: 0,
        code: 'ABC234',
      );
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture is broken: the create reply must land connected',
      );

      // Arm the connector's next call (the automatic attempt the drop below
      // schedules) to reject, standing in for the phone still being
      // offline when that attempt runs.
      connector.enqueueReject();
      transportA.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the drop must land the phase closed',
      );

      // Fire the scheduled automatic attempt: it opens against the
      // connector, which was armed above to reject.
      await tester.pump(_delays[0]);
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason:
            'L1: the first automatic attempt failing at the connector must '
            'land RoomPhase.failed',
      );
      expect(
        controller.room,
        isNotNull,
        reason: 'L1 is gated on controller.room staying set',
      );
      expect(
        controller.errorCode,
        'transport',
        reason:
            'L1 fixture check: a connector rejection maps to errorCode '
            '"transport" (room_controller.dart _openAndAttach); a reason '
            'text of "the connector rejected the attempt" would be the '
            'shape a real dropped phone produces',
      );

      expect(
        find.byKey(const Key('lobby-closed')),
        findsOneWidget,
        reason:
            'L1: failed + room set + errorCode "transport" (retryable) '
            'must render the same body as RoomPhase.closed, not lobby-error',
      );
      expect(
        find.byKey(const Key('lobby-error')),
        findsNothing,
        reason: 'L1: lobby-error must be absent for a retryable failed state',
      );
      expect(
        find.byKey(const Key('lobby-retry-button')),
        findsNothing,
        reason:
            'L1: lobby-retry-button must be absent for a retryable failed '
            'state -- that button re-creates the room, which would strand '
            'the friends already waiting in the old one',
      );

      // Tap reconnect: the next transport's first frame must be resume,
      // carrying the cached room code and seat token, never create_room.
      final FakeTransport transportB = FakeTransport();
      connector.enqueue(transportB);
      await tester.tap(find.byKey(const Key('lobby-reconnect-button')));
      await tester.pump();
      await tester.pump();

      expect(
        transportB.sentRaw,
        isNotEmpty,
        reason:
            'L1: tapping lobby-reconnect-button must open a new transport '
            'and send a request on it',
      );
      expect(
        _typeOf(transportB.sentRaw.first),
        'resume',
        reason:
            'L1: the reconnect tap must send resume, not '
            '"${_typeOf(transportB.sentRaw.first)}"',
      );
      final Map<String, Object?> resumeData = _dataOf(transportB.sentRaw.first);
      expect(
        resumeData,
        <String, Object?>{'code': 'ABC234', 'seat_token': 'tok-0'},
        reason:
            'L1: resume must carry the room code and seat token this '
            'controller cached from the original create; got $resumeData',
      );

      final List<String> allSent = <String>[
        ...transportA.sentRaw,
        ...transportB.sentRaw,
      ];
      final int createCount = allSent
          .where((String s) => _typeOf(s) == 'create_room')
          .length;
      expect(
        createCount,
        1,
        reason:
            'L1: create_room must never be sent again after the first; '
            'found $createCount create_room frames across both transports',
      );

      // Resolve the resume so no request timer is left pending.
      final String resumeId = _idOf(transportB.sentRaw.first);
      transportB.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(code: 'ABC234', seq: 1),
        ),
      );
      await tester.pump();
      await tester.pump();

      controller.dispose();
    },
  );

  // ==========================================================================
  // L-2
  // ==========================================================================
  testWidgets(
    'L-2 (control): the same room, an *automatic* reconnect attempt answered '
    'NO_SUCH_ROOM with the room set -> lobby-error, not lobby-closed (see '
    'this file\'s header comment, ambiguity 1, for how this differs from '
    'test/lobby_screen_test.dart:720-742)',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
        autoReconnectDelays: _delays,
      );

      final String createId = await _mountLobbyCreate(
        tester,
        controller,
        transportA,
      );
      await _resolveLobbyConnected(
        tester,
        transportA,
        createId,
        seatForThisClient: 0,
        code: 'ABC234',
      );
      expect(controller.phase, RoomPhase.connected);

      // The automatic attempt's connector call succeeds this time; the
      // failure this case pins comes from the server's own reply to resume,
      // not from the transport.
      final FakeTransport transportB = FakeTransport();
      connector.enqueue(transportB);
      transportA.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);

      await tester.pump(_delays[0]);
      await tester.pump();
      await tester.pump();

      expect(
        transportB.sentRaw,
        isNotEmpty,
        reason:
            'fixture is broken: the automatic attempt must have opened '
            'transportB and sent resume on it by now',
      );
      expect(_typeOf(transportB.sentRaw.last), 'resume');
      final String resumeId = _idOf(transportB.sentRaw.last);
      transportB.pushText(
        _frame(
          type: 'error',
          re: resumeId,
          data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.failed,
        reason: 'L2 fixture: NO_SUCH_ROOM on the automatic resume must fail',
      );
      expect(controller.room, isNotNull, reason: 'L2 is gated on room set');
      expect(controller.errorCode, 'NO_SUCH_ROOM');

      expect(
        find.byKey(const Key('lobby-error')),
        findsOneWidget,
        reason:
            'L2: a non-retryable code (NO_SUCH_ROOM) with room set must '
            'render lobby-error, exactly as every other failed state does',
      );
      expect(
        find.byKey(const Key('lobby-closed')),
        findsNothing,
        reason: 'L2: lobby-closed must be absent for a non-retryable failure',
      );
      expect(
        find.byKey(const Key('lobby-retry-button')),
        findsOneWidget,
        reason: 'L2: lobby-error must carry lobby-retry-button',
      );

      // No pending timer: NO_SUCH_ROOM is not retryable, so
      // _afterReconnectAttemptFailure ends the sequence without scheduling
      // another attempt.
      expect(controller.autoReconnectPending, isFalse);
      controller.dispose();
    },
  );

  // ==========================================================================
  // R1-EN / R1-AR
  // ==========================================================================
  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    testWidgets(
      'R1-${locale.languageCode == 'en' ? 'EN' : 'AR'}: lobby dropped with '
      'autoReconnectPending true shows lobby-reconnecting with the exact '
      'lobbyReconnecting string of locale "${locale.languageCode}", looked '
      'up from AppLocalizations',
      (tester) async {
        final _Connector connector = _Connector();
        final FakeTransport transportA = FakeTransport();
        connector.enqueue(transportA);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
          autoReconnectDelays: _delays,
        );

        final String createId = await _mountLobbyCreate(
          tester,
          controller,
          transportA,
          locale: locale,
        );
        await _resolveLobbyConnected(
          tester,
          transportA,
          createId,
          seatForThisClient: 0,
        );
        expect(controller.phase, RoomPhase.connected);

        transportA.endFromFarSide();
        await tester.pump();
        await tester.pump();

        expect(controller.phase, RoomPhase.closed);
        expect(
          controller.autoReconnectPending,
          isTrue,
          reason:
              'fixture is broken: a non-empty autoReconnectDelays drop '
              'must leave a scheduled automatic attempt, so '
              'autoReconnectPending must read true right after the drop',
        );

        expect(find.byKey(const Key('lobby-closed')), findsOneWidget);
        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byType(LobbyScreen)),
        );
        expect(
          loc.localeName,
          locale.languageCode,
          reason: 'fixture is broken: wrong locale resolved',
        );
        final Finder reconnectingFinder = find.byKey(
          const Key('lobby-reconnecting'),
        );
        expect(
          reconnectingFinder,
          findsOneWidget,
          reason:
              'R1: lobby-reconnecting must be present while '
              'autoReconnectPending is true',
        );
        final Text reconnectingText = tester.widget<Text>(reconnectingFinder);
        expect(
          reconnectingText.data,
          loc.lobbyReconnecting,
          reason:
              'R1: lobby-reconnecting\'s text must be exactly this tree\'s '
              'own AppLocalizations.lobbyReconnecting ("${loc.lobbyReconnecting}'
              '"), not a literal copied from the ARB file; got '
              '"${reconnectingText.data}"',
        );

        // A reconnect timer is still armed (not yet fired): dispose
        // explicitly here rather than via addTearDown, matching
        // test/lobby_screen_test.dart's own "idle-or-connecting" case,
        // because flutter_test's pending-timer invariant runs before
        // addTearDown callbacks fire.
        controller.dispose();
      },
    );
  }

  // ==========================================================================
  // R1-N
  // ==========================================================================
  testWidgets(
    'R1-N (control): lobby dropped with autoReconnectDelays empty shows '
    'lobby-closed with lobby-reconnecting absent',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
        // autoReconnectDelays defaults to <Duration>[], the explicit point
        // of this control.
      );
      addTearDown(controller.dispose);

      final String createId = await _mountLobbyCreate(
        tester,
        controller,
        transportA,
      );
      await _resolveLobbyConnected(
        tester,
        transportA,
        createId,
        seatForThisClient: 0,
      );
      expect(controller.phase, RoomPhase.connected);

      transportA.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'R1-N fixture: an empty autoReconnectDelays must never start a '
            'sequence, so autoReconnectPending must stay false',
      );

      expect(find.byKey(const Key('lobby-closed')), findsOneWidget);
      expect(
        find.byKey(const Key('lobby-reconnecting')),
        findsNothing,
        reason: 'R1-N: lobby-reconnecting must be absent when pending is false',
      );
    },
  );

  // ==========================================================================
  // R2
  // ==========================================================================
  testWidgets(
    'R2: a game in progress, the transport closes with autoReconnectPending '
    'true -> game-screen-connection-lost present and game-screen-reconnecting '
    'inside it, showing lobbyReconnecting',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);

      final RoomController controller = await _connectPlayingGame(
        tester,
        connector,
        transportA,
        autoReconnectDelays: _delays,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      await _mountGame(tester, controller);
      expect(controller.phase, RoomPhase.connected);

      transportA.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the drop must close the phase',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: a non-empty autoReconnectDelays drop must '
            'leave a scheduled automatic attempt',
      );

      final Finder connectionLostFinder = find.byKey(
        const Key('game-screen-connection-lost'),
      );
      expect(connectionLostFinder, findsOneWidget);
      final Finder reconnectingFinder = find.byKey(
        const Key('game-screen-reconnecting'),
      );
      expect(
        reconnectingFinder,
        findsOneWidget,
        reason:
            'R2: game-screen-reconnecting must be present while '
            'autoReconnectPending is true',
      );
      expect(
        find.descendant(of: connectionLostFinder, matching: reconnectingFinder),
        findsOneWidget,
        reason:
            'R2: game-screen-reconnecting must sit inside the '
            'connection-lost body',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      final Text reconnectingText = tester.widget<Text>(reconnectingFinder);
      expect(
        reconnectingText.data,
        loc.lobbyReconnecting,
        reason:
            'R2: game-screen-reconnecting\'s text must be exactly this '
            'tree\'s own AppLocalizations.lobbyReconnecting '
            '("${loc.lobbyReconnecting}"); got "${reconnectingText.data}"',
      );

      // A reconnect timer is still armed: dispose explicitly (see R1's own
      // comment for why addTearDown alone is not enough here).
      controller.dispose();
    },
  );

  // ==========================================================================
  // R2-X
  // ==========================================================================
  testWidgets(
    'R2-X (control): a game in progress, every automatic attempt in the '
    'whole schedule failing at the connector, exhausts the sequence -> '
    'game-screen-connection-lost present, game-screen-reconnecting absent',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);
      // Every attempt in _delays (two entries) fails at the connector.
      connector.enqueueReject();
      connector.enqueueReject();

      final RoomController controller = await _connectPlayingGame(
        tester,
        connector,
        transportA,
        autoReconnectDelays: _delays,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      await _mountGame(tester, controller);

      transportA.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);

      // First scheduled attempt fires and fails at the connector.
      await tester.pump(_delays[0]);
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: one retryable failure of two scheduled '
            'must still have a next attempt pending',
      );

      // Second (last) scheduled attempt fires and also fails at the
      // connector, exhausting the schedule.
      await tester.pump(_delays[1]);
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'transport');
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason:
            'R2-X fixture: both scheduled attempts have now failed, '
            'exhausting _delays; autoReconnectPending must read false',
      );

      expect(
        find.byKey(const Key('game-screen-connection-lost')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('game-screen-reconnecting')),
        findsNothing,
        reason:
            'R2-X: game-screen-reconnecting must be absent once the '
            'schedule is exhausted',
      );

      controller.dispose();
    },
  );

  // ==========================================================================
  // R3
  // ==========================================================================
  testWidgets(
    'R3: a game in progress, dropped, the scheduled attempt held in flight '
    'at the connector -> phase connecting, game-screen-reconnecting-banner '
    'present, the board (game-screen-board) still rendered, '
    'game-screen-connection-lost absent; completing the resume with a valid '
    'room reply removes the banner',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);

      final RoomController controller = await _connectPlayingGame(
        tester,
        connector,
        transportA,
        autoReconnectDelays: _delays,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      await _mountGame(tester, controller);

      // Hold the connector open for the automatic attempt the drop below
      // schedules: connect() will be called, but its Future is not
      // completed until this case completes it explicitly.
      final Completer<WireTransport> hold = connector.enqueueHold();

      transportA.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);

      await tester.pump(_delays[0]);
      await tester.pump();
      await tester.pump();

      expect(
        controller.phase,
        RoomPhase.connecting,
        reason:
            'R3: the timer firing into a connector call that has not '
            'resolved yet must leave the phase at connecting',
      );

      final Finder bannerFinder = find.byKey(
        const Key('game-screen-reconnecting-banner'),
      );
      expect(
        bannerFinder,
        findsOneWidget,
        reason:
            'R3: game-screen-reconnecting-banner must be present while '
            'phase is connecting with room still set',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      final Text bannerText = tester.widget<Text>(bannerFinder);
      expect(bannerText.data, loc.lobbyReconnecting);

      // game-screen-board is the key _playingBody alone renders (see
      // game_screen.dart _playingBody / LudoBoard): the connection-lost
      // branch that game-screen-connection-lost belongs to renders no
      // board at all (test/game_screen_connection_lost_test.dart's own C1
      // pins that board is absent there). Its presence here is exactly
      // what proves this is still the last known playing board, not a
      // connection-lost placeholder, underneath the banner.
      expect(
        find.byKey(const Key('game-screen-board')),
        findsOneWidget,
        reason:
            'R3: the last known board must still be rendered while an '
            'automatic attempt is in flight',
      );
      expect(
        find.byKey(const Key('game-screen-connection-lost')),
        findsNothing,
        reason:
            'R3: game-screen-connection-lost must be absent while phase is '
            'connecting, not failed or closed',
      );

      // Complete the held connector call with a fresh transport, then
      // answer the resume it sends with a valid room reply.
      final FakeTransport transportB = FakeTransport();
      hold.complete(transportB);
      await tester.pump();
      await tester.pump();

      expect(
        transportB.sentRaw,
        isNotEmpty,
        reason:
            'fixture is broken: the attempt must send resume once the '
            'connector resolves',
      );
      expect(_typeOf(transportB.sentRaw.last), 'resume');
      final String resumeId = _idOf(transportB.sentRaw.last);
      transportB.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(
            state: 'PLAYING',
            players: 2,
            seats: midGameSeats,
            turn: midGameTurn(),
            seq: 1,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.phase, RoomPhase.connected);
      expect(
        find.byKey(const Key('game-screen-reconnecting-banner')),
        findsNothing,
        reason: 'R3: the banner must be gone once the resume succeeds',
      );

      controller.dispose();
    },
  );

  // ==========================================================================
  // R-P
  // ==========================================================================
  testWidgets(
    'R-P: from a connected game, dropping the transport and advancing with '
    'only tester.pump calls (no setState, no second pumpWidget, no direct '
    'poke of the widget) is enough for game-screen-reconnecting to appear',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transportA = FakeTransport();
      connector.enqueue(transportA);

      final RoomController controller = await _connectPlayingGame(
        tester,
        connector,
        transportA,
        autoReconnectDelays: _delays,
        seats: midGameSeats,
        turn: midGameTurn(),
      );
      await _mountGame(tester, controller);
      expect(controller.phase, RoomPhase.connected);

      // Nothing below this line touches the widget or the controller
      // except transport.endFromFarSide() (the socket dying, not a widget
      // action) and tester.pump() (advancing frames). No setState, no
      // second pumpWidget, no reading or writing a private field.
      transportA.endFromFarSide();

      // Deliberately short, bounded pumps, well under _delays[0] (1s), so
      // the scheduled automatic attempt itself never fires and produces a
      // notify of its own -- see this file's header comment, ambiguity 2:
      // the only notification carrying autoReconnectPending's true value
      // into this window is _scheduleNextAttempt's own (order 177's N1).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));

      expect(
        controller.phase,
        RoomPhase.closed,
        reason: 'fixture is broken: the drop must close the phase',
      );
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: a non-empty autoReconnectDelays drop must '
            'leave a scheduled automatic attempt pending',
      );

      expect(
        find.byKey(const Key('game-screen-reconnecting')),
        findsOneWidget,
        reason:
            'R-P: game-screen-reconnecting must be on screen after nothing '
            'but tester.pump() calls following the drop; a red here with '
            'autoReconnectPending already true above would mean the '
            'controller changed state without ever telling this widget',
      );

      // A reconnect timer is still armed: dispose explicitly (see R1's own
      // comment for why addTearDown alone is not enough here).
      controller.dispose();
    },
  );
}
