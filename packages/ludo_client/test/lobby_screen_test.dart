// Conformance tests for lib/src/lobby_screen.dart's LobbyScreen, written
// from work/ludo/orders/081-lobby-screen-tests.md's frozen declaration block
// and its twelve numbered behaviour rules, against no implementation of
// lobby_screen.dart the author of this file has read. lobby_screen.dart and
// lib/src/server_config.dart do not exist on the branch this file was
// written on: a second worker is writing them, blind, from the same frozen
// block, at the same time. This file cannot compile, let alone pass, on
// this branch; that is expected and is recorded in the work order itself.
//
// LobbyScreen is exercised as a black box at the wire level, the same way
// test/net/room_controller_test.dart exercises RoomController: a real
// RoomController is built over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here) and a small connector double copied from that
// file's own idiom, and every claim about what the screen sent is checked by
// decoding FakeTransport.sentRaw, never by trusting that "a request was
// issued". No mock of RoomController appears anywhere in this file: a fake
// of the thing under proof would prove nothing, and RoomController's own
// suite (order 074) already passes.
//
// Ambiguities found while writing this file, reported rather than invented
// around (standing rule: "Ambiguity is reported, never invented around"):
//
//   1. RoomPhase.idle cannot be observed as a live LobbyScreen render.
//      RoomController.createRoom/joinRoom (already implemented, order 074,
//      merged before this order started) sets phase to RoomPhase.connecting
//      synchronously, before the first `await`, the instant it is called.
//      Rule 1 requires LobbyScreen's initState to call that method directly
//      (not deferred, not awaited), so by the time the very first `build()`
//      runs, in the same synchronous mount call Flutter makes before ever
//      returning control to the test, phase has already left idle. This
//      holds regardless of how the implementer writes initState, as long as
//      rule 1 is honoured literally. The tests below for "idle or
//      connecting" therefore assert `anyOf(RoomPhase.idle, RoomPhase.
//      connecting)` on the controller and check the one render rule 3 says
//      both values share, rather than claiming to have proven a render that
//      is, in fact, unreachable in the widget's own initState-driven
//      lifecycle. This should be checked against whatever the implementer
//      also concluded.
//
//   2. Reaching RoomPhase.failed or RoomPhase.idle by handing LobbyScreen an
//      already-non-idle controller does not work: createRoom/joinRoom's own
//      gate is `phase == idle || phase == failed`, so mounting a fresh
//      LobbyScreen onto a controller already in one of those two phases
//      would make initState's own request re-fire and immediately (again
//      synchronously) move the controller to connecting before the first
//      build, corrupting the very phase the test meant to observe. Every
//      phase in this file is therefore reached by mounting a screen once,
//      on a fresh idle controller, and driving that same controller's own
//      request to the desired outcome afterwards; RoomPhase.failed is
//      reached by pushing an `error` reply to the request initState itself
//      issued, never by pre-seeding a controller.
//
//   3. Rules 10, 11 and 12 (home screen wiring, the name field, the players
//      selector) are part of the frozen declaration block but describe
//      home_screen.dart, not lobby_screen.dart, and this order's file list
//      is exactly lobby_screen_test.dart plus an optional fixtures file,
//      "nothing else". They are not covered here; presumably another order
//      owns home_screen_test.dart.
//
//   4. test/net/fake_transport.dart fit without modification: it is the
//      WireTransport fake the connection suite already uses, and this file
//      drives RoomController the same way room_controller_test.dart does.
//      No second fixture file was needed, so lobby_fixtures.dart was not
//      created.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring test/net/room_controller_test.dart ------

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
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
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

// --- a TransportConnector test double, copied from room_controller_test's --
// --- own idiom rather than imported: it is not exported by that file, and
// --- that file is not on this order's file list to modify. -----------------

/// Hands out queued [FakeTransport]s, one per call, in order. [rejectNextWith]
/// makes exactly the next call reject instead, to exercise the
/// connector-rejects path without touching any transport at all.
class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];
  Object? _rejectNextWith;

  void enqueue(FakeTransport transport) => _queue.add(transport);

  void rejectNextWith(Object error) => _rejectNextWith = error;

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_rejectNextWith != null) {
      final Object error = _rejectNextWith!;
      _rejectNextWith = null;
      throw error;
    }
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

// --- widget harness ----------------------------------------------------

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
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

/// Every key rule 3 says exactly one of must be present at a time, in a
/// fixed order so a failure message reads the same way every time.
const List<String> _phaseKeys = <String>[
  'lobby-connecting',
  'lobby-error',
  'lobby-closed',
];

/// Asserts that among the three phase-body keys other than [expected],
/// nothing is present, and that the connected body's own top-level marker
/// (lobby-room-code) is present only if [expected] is null (meaning: the
/// connected body is the one expected to be showing). Rule 3: "Exactly one
/// of these four bodies is in the tree at any moment".
void _expectExclusivePhase(WidgetTester tester, {required String? expected}) {
  for (final key in _phaseKeys) {
    final matcher = key == expected ? findsOneWidget : findsNothing;
    expect(
      find.byKey(Key(key)),
      matcher,
      reason:
          'rule 3: expected exactly one phase body in the tree; '
          'looking for Key($key), wanted showing=${key == expected}',
    );
  }
  final connectedShowing = expected == null;
  expect(
    find.byKey(const Key('lobby-room-code')),
    connectedShowing ? findsOneWidget : findsNothing,
    reason:
        'rule 3: the connected body (lobby-room-code) should be showing '
        'iff no other phase body is expected; expected=$expected',
  );
}

void _expectDesyncBanner(WidgetTester tester, {required bool present}) {
  expect(
    find.byKey(const Key('lobby-desync-banner')),
    present ? findsOneWidget : findsNothing,
    reason:
        'rule 5: lobby-desync-banner must be present exactly when '
        'controller.hasDesynced is true, additively, regardless of which '
        'phase body is also showing; expected present=$present',
  );
}

// --- scenario driving ----------------------------------------------------

/// Mounts [screen], waits for the request rule 1 says initState must issue,
/// and returns the raw sent message's id so a reply can target it with `re`.
/// Fails loudly, naming what was expected, if no message ever reaches the
/// transport: a silent hang here would otherwise look like every later
/// assertion failing for an unrelated reason.
Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_harness(screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'rule 1: expected LobbyScreen.initState to have sent exactly one '
        'request to the transport by now (createRoom or joinRoom); '
        'sentRaw is empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
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

Future<void> _resolveFailed(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  String code = 'ROOM_FULL',
  String message = '',
}) async {
  transport.pushText(
    _frame(
      type: 'error',
      re: requestId,
      data: <String, Object?>{'code': code, 'message': message},
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // --- Rule 6: lobbyErrorMessage, pure, no widget pumped. -----------------
  group('rule 6: lobbyErrorMessage maps the table verbatim', () {
    final table = <String?, String Function(AppLocalizations)>{
      'NO_SUCH_ROOM': (loc) => loc.lobbyErrorNoSuchRoom,
      'ROOM_FULL': (loc) => loc.lobbyErrorRoomFull,
      'ROOM_STARTED': (loc) => loc.lobbyErrorRoomStarted,
      'RATE_LIMITED': (loc) => loc.lobbyErrorRateLimited,
      'transport': (loc) => loc.lobbyErrorTransport,
      null: (loc) => loc.lobbyErrorGeneric,
      'TOTALLY_UNKNOWN_CODE': (loc) => loc.lobbyErrorGeneric,
      '': (loc) => loc.lobbyErrorGeneric,
    };

    for (final locale in <Locale>[const Locale('en'), const Locale('ar')]) {
      for (final entry in table.entries) {
        test('locale ${locale.languageCode}: code ${entry.key ?? 'null'} maps '
            'to the rule 6 row', () {
          final loc = lookupAppLocalizations(locale);
          final result = lobbyErrorMessage(loc, entry.key);
          final expected = entry.value(loc);
          expect(
            result,
            expected,
            reason:
                'lobbyErrorMessage(loc, ${entry.key ?? 'null'}) in locale '
                '${locale.languageCode} should equal "$expected" per rule '
                '6\'s table; got "$result"',
          );
        });
      }
    }

    test("rule 6: case is not normalised -- 'Transport' (mixed case) falls "
        'through to the generic message, not the transport-specific one', () {
      final loc = lookupAppLocalizations(const Locale('en'));
      expect(
        lobbyErrorMessage(loc, 'Transport'),
        loc.lobbyErrorGeneric,
        reason:
            "rule 6 pins case-sensitivity explicitly: 'Transport' must "
            "not match the lower-case 'transport' row and must fall "
            'through to lobbyErrorGeneric',
      );
    });
  });

  // --- Rule 3: phase rendering is exclusive. ------------------------------
  group('rule 3: phase rendering is exclusive', () {
    testWidgets(
      'idle-or-connecting: pumped before the initState request resolves, '
      'shows lobby-connecting with a spinner and loc.lobbyConnecting, and '
      'nothing else',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        // Disposed explicitly at the end of this body rather than via
        // addTearDown: the request initState issued (rule 1) is
        // deliberately left unresolved here so the connecting phase can be
        // observed, and flutter_test's own invariant check for pending
        // timers runs before addTearDown callbacks fire (see round 2
        // defect 2), so an addTearDown-only disposal would fail this test
        // on a live request timer that has nothing to do with the
        // assertions below.

        await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );

        // See the top-of-file note on ambiguity 1: RoomController's own,
        // already-implemented synchronous transition means this is
        // RoomPhase.connecting by the time control returns here in every
        // implementation that follows rule 1 literally, but the assertion
        // is written to accept idle too rather than assume that.
        expect(
          controller.phase,
          anyOf(RoomPhase.idle, RoomPhase.connecting),
          reason:
              'expected the controller to still be idle or connecting '
              'immediately after mount, before any reply was pushed; got '
              '${controller.phase}',
        );

        _expectExclusivePhase(tester, expected: 'lobby-connecting');
        _expectDesyncBanner(tester, present: false);

        final context = tester.element(find.byType(LobbyScreen));
        final loc = AppLocalizations.of(context);
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-connecting')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
          reason:
              'rule 3: lobby-connecting must contain a '
              'CircularProgressIndicator',
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-connecting')),
            matching: find.text(loc.lobbyConnecting),
          ),
          findsOneWidget,
          reason:
              'rule 3: lobby-connecting must contain Text(loc.'
              'lobbyConnecting), which reads "${loc.lobbyConnecting}"',
        );

        controller.dispose();
      },
    );

    testWidgets('connected: shows the connected body and nothing else', (
      tester,
    ) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
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

      expect(controller.phase, RoomPhase.connected);
      _expectExclusivePhase(tester, expected: null);
      _expectDesyncBanner(tester, present: false);
    });

    testWidgets('failed: shows lobby-error with the mapped message and a retry '
        'button, and nothing else', (tester) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
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

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'ROOM_FULL');
      _expectExclusivePhase(tester, expected: 'lobby-error');
      _expectDesyncBanner(tester, present: false);

      final context = tester.element(find.byType(LobbyScreen));
      final loc = AppLocalizations.of(context);
      final expectedText = lobbyErrorMessage(loc, controller.errorCode);
      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-error')),
          matching: find.text(expectedText),
        ),
        findsOneWidget,
        reason:
            'rule 3: lobby-error must contain a Text whose data is '
            'exactly lobbyErrorMessage(loc, controller.errorCode) == '
            '"$expectedText" for errorCode ROOM_FULL',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-error')),
          matching: find.byKey(const Key('lobby-retry-button')),
        ),
        findsOneWidget,
        reason:
            'rule 3: lobby-error must contain a button keyed '
            'lobby-retry-button',
      );
    });

    testWidgets(
      'closed: shows lobby-closed with loc.lobbyConnectionLost and a '
      'reconnect button that calls controller.reconnect(), and nothing else',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
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

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();

        expect(controller.phase, RoomPhase.closed);
        _expectExclusivePhase(tester, expected: 'lobby-closed');
        _expectDesyncBanner(tester, present: false);

        final context = tester.element(find.byType(LobbyScreen));
        final loc = AppLocalizations.of(context);
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-closed')),
            matching: find.text(loc.lobbyConnectionLost),
          ),
          findsOneWidget,
          reason:
              'rule 3: lobby-closed must contain Text(loc.'
              'lobbyConnectionLost), which reads '
              '"${loc.lobbyConnectionLost}"',
        );

        // The room and seat token are cached (RoomController rule 5), so
        // reconnect() is legal from RoomPhase.closed; queue a transport for
        // it and tap the button.
        final resumeTransport = FakeTransport();
        connector.enqueue(resumeTransport);
        await tester.tap(find.byKey(const Key('lobby-reconnect-button')));
        await tester.pump();

        expect(
          connector.calls,
          hasLength(2),
          reason:
              'rule 3: tapping lobby-reconnect-button must call '
              'controller.reconnect(), which opens a second transport; '
              'expected exactly 2 connect() calls total (initial + '
              'reconnect), got ${connector.calls.length}',
        );

        // Resolve the resume request the tap armed, so addTearDown's
        // dispose does not race flutter_test's pending-timer invariant
        // check against a request that was never answered (round 2
        // defect 2). The reply itself is not the point of this test; the
        // assertion above already covers the tap's behaviour.
        final resumeId = _idOf(resumeTransport.sentRaw.last);
        expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
        await _resolveConnected(
          tester,
          resumeTransport,
          resumeId,
          seatForThisClient: 0,
        );
      },
    );
  });

  // --- Rule 5: the desync banner is additive, not a fifth phase. ---------
  group('rule 5: desync banner is additive', () {
    testWidgets(
      'connected, then closed, then connecting-again, then failed, all '
      'while hasDesynced stays true throughout: the banner is present in '
      'every one of those phases',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          seq: 1,
        );
        _expectDesyncBanner(tester, present: false);

        // A lobby delta (presence) whose seq is not room.seq + 1 sets
        // hasDesynced, per RoomController rule 8. Target the host seat,
        // which is already present in the default single-seat room.
        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 9},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.hasDesynced, isTrue);
        expect(
          controller.phase,
          RoomPhase.connected,
          reason: 'the desync must not have changed the phase by itself',
        );
        _expectExclusivePhase(tester, expected: null);
        _expectDesyncBanner(tester, present: true);
        final context1 = tester.element(find.byType(LobbyScreen));
        final loc1 = AppLocalizations.of(context1);
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-desync-banner')),
            matching: find.text(loc1.lobbyDesynced),
          ),
          findsOneWidget,
          reason:
              'rule 5: the banner must contain Text(loc.lobbyDesynced), '
              'which reads "${loc1.lobbyDesynced}"',
        );

        // Drop the transport: phase becomes closed, hasDesynced is
        // untouched by that path (only a successful reconnect clears it).
        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(controller.phase, RoomPhase.closed);
        expect(controller.hasDesynced, isTrue);
        _expectExclusivePhase(tester, expected: 'lobby-closed');
        _expectDesyncBanner(tester, present: true);
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-desync-banner')),
            matching: find.byKey(const Key('lobby-resync-button')),
          ),
          findsOneWidget,
          reason:
              'rule 5: the banner must contain a button keyed '
              'lobby-resync-button',
        );

        // Tap resync: it must call controller.reconnect(), moving the
        // controller to connecting (synchronously, same reasoning as
        // ambiguity 1) while hasDesynced is still true, and open a new
        // transport that will be made to fail so the failed+desynced
        // combination can be observed too.
        final resumeTransport = FakeTransport();
        connector.enqueue(resumeTransport);
        await tester.tap(find.byKey(const Key('lobby-resync-button')));
        await tester.pump();

        expect(
          controller.phase,
          RoomPhase.connecting,
          reason:
              'rule 5: tapping lobby-resync-button must call '
              'controller.reconnect(), which moves phase to connecting',
        );
        expect(controller.hasDesynced, isTrue);
        _expectExclusivePhase(tester, expected: 'lobby-connecting');
        _expectDesyncBanner(tester, present: true);

        // Fail the resume: an error reply lands the controller in failed,
        // with hasDesynced still untouched (only success clears it).
        await tester.pump();
        final resumeId = _idOf(resumeTransport.sentRaw.last);
        expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
        resumeTransport.pushText(
          _frame(
            type: 'error',
            re: resumeId,
            data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.phase, RoomPhase.failed);
        expect(controller.hasDesynced, isTrue);
        _expectExclusivePhase(tester, expected: 'lobby-error');
        _expectDesyncBanner(tester, present: true);
      },
    );
  });

  // --- Rule 4: the connected body. ----------------------------------------
  group('rule 4: the connected body', () {
    testWidgets(
      'lobby-room-code is a Text whose data is exactly the room code, no '
      'label, no prefix',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          code: 'ABC234',
        );

        final textWidget = tester.widget<Text>(
          find.byKey(const Key('lobby-room-code')),
        );
        expect(
          textWidget.data,
          'ABC234',
          reason:
              'rule 4: lobby-room-code must be a Text whose data is '
              'exactly controller.room!.code, "ABC234", with no label, '
              'prefix or extra characters; got "${textWidget.data}"',
        );
      },
    );

    testWidgets(
      'lobby-copy-link-button copies kRoomLinkBase + code to the clipboard '
      'and shows the lobbyLinkCopied snackbar',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final clipboardCalls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              clipboardCalls.add(args['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          code: 'ABC234',
        );

        await tester.tap(find.byKey(const Key('lobby-copy-link-button')));
        await tester.pump();

        expect(
          clipboardCalls,
          <String>['https://ludo.provefair.app/r/ABC234'],
          reason:
              'rule 4: lobby-copy-link-button must call Clipboard.setData '
              'with exactly kRoomLinkBase + code == '
              '"https://ludo.provefair.app/r/ABC234"; the button that '
              'shows a snackbar without copying anything must fail this, '
              'so an empty list here means nothing was copied at all',
        );

        final context = tester.element(find.byType(LobbyScreen));
        final loc = AppLocalizations.of(context);
        expect(
          find.widgetWithText(SnackBar, loc.lobbyLinkCopied),
          findsOneWidget,
          reason:
              'rule 4: a SnackBar containing Text(loc.lobbyLinkCopied) '
              'must show after the link is copied',
        );
      },
    );

    testWidgets(
      'lobby-copy-code-button copies the bare code to the clipboard and '
      'shows the lobbyLinkCopied snackbar',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final clipboardCalls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              clipboardCalls.add(args['text'] as String);
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          code: 'ABC234',
        );

        await tester.tap(find.byKey(const Key('lobby-copy-code-button')));
        await tester.pump();

        expect(
          clipboardCalls,
          <String>['ABC234'],
          reason:
              'rule 4: lobby-copy-code-button must call Clipboard.setData '
              'with exactly the bare code "ABC234", not the full link and '
              'not empty',
        );

        final context = tester.element(find.byType(LobbyScreen));
        final loc = AppLocalizations.of(context);
        expect(
          find.widgetWithText(SnackBar, loc.lobbyLinkCopied),
          findsOneWidget,
          reason:
              'rule 4: the same lobbyLinkCopied snackbar text is used for '
              'both copy buttons',
        );
      },
    );

    testWidgets(
      'seat rows are keyed by the seat integer, not by list index, for a '
      'sparse, non-contiguous, out-of-order seats list',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        // Deliberately not [0,1,2,3] and deliberately not in seat order:
        // list index 0 holds seat 3's data, list index 1 holds seat 0's.
        // A widget that keys rows by list index instead of the seat field
        // would key list-index-0 as lobby-seat-0 and put Zara's name under
        // it; this test fails exactly that off-by-one.
        final seats = <Map<String, Object?>>[
          _seatJson(3, name: 'Zara', connected: true),
          _seatJson(0, name: 'Amir', connected: true),
        ];

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Amir',
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
          seats: seats,
        );

        expect(
          find.byKey(const Key('lobby-seat-0')),
          findsOneWidget,
          reason: 'expected a row keyed lobby-seat-0 for the seat-0 entry',
        );
        expect(
          find.byKey(const Key('lobby-seat-3')),
          findsOneWidget,
          reason: 'expected a row keyed lobby-seat-3 for the seat-3 entry',
        );
        expect(
          find.byKey(const Key('lobby-seat-1')),
          findsNothing,
          reason: 'seat 1 is absent from room.seats and must not get a row',
        );
        expect(
          find.byKey(const Key('lobby-seat-2')),
          findsNothing,
          reason: 'seat 2 is absent from room.seats and must not get a row',
        );

        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-seat-3')),
            matching: find.text('Zara'),
          ),
          findsOneWidget,
          reason:
              'rule 4: lobby-seat-3 must contain the name of the entry '
              'whose seat field is 3 ("Zara"), regardless of that entry '
              'being first in the list',
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-seat-0')),
            matching: find.text('Amir'),
          ),
          findsOneWidget,
          reason:
              'rule 4: lobby-seat-0 must contain the name of the entry '
              'whose seat field is 0 ("Amir"), regardless of that entry '
              'being second in the list',
        );

        // The list is not re-sorted: seat 3's row (list index 0) should
        // render above seat 0's row (list index 1) in a lobby seat list,
        // which is the ordinary vertical layout for "who is in the room".
        // If this fails because the layout is genuinely not vertical, that
        // is a real finding to report, not a reason to delete the check.
        final seat3Top = tester.getTopLeft(
          find.byKey(const Key('lobby-seat-3')),
        );
        final seat0Top = tester.getTopLeft(
          find.byKey(const Key('lobby-seat-0')),
        );
        expect(
          seat3Top.dy,
          lessThan(seat0Top.dy),
          reason:
              'rule 4: seat rows must render in list order, not sorted by '
              'seat number; the seats list here is [seat 3, seat 0], so '
              'seat 3\'s row should sit above seat 0\'s row',
        );
      },
    );

    testWidgets('a seat name in Arabic script renders exactly, unescaped', (
      tester,
    ) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      const arabicName = 'أحمد';
      final seats = <Map<String, Object?>>[
        _seatJson(0, name: arabicName, connected: true),
      ];

      final id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: arabicName,
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        seats: seats,
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-seat-0')),
          matching: find.text(arabicName),
        ),
        findsOneWidget,
        reason:
            'rule 4: the seat-0 row must show the Arabic name "$arabicName" '
            'exactly, unescaped and unmangled',
      );
    });

    testWidgets(
      'lobby-waiting shows loc.lobbyWaitingForPlayers(occupied, total)',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Amir', connected: true),
          _seatJson(1, name: 'Sam', connected: true),
        ];

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Amir',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          players: 4,
          seats: seats,
        );

        final context = tester.element(find.byType(LobbyScreen));
        final loc = AppLocalizations.of(context);
        final expectedText = loc.lobbyWaitingForPlayers(2, 4);
        final waitingText = tester.widget<Text>(
          find.byKey(const Key('lobby-waiting')),
        );
        expect(
          waitingText.data,
          expectedText,
          reason:
              'rule 4: lobby-waiting must be a Text of '
              'loc.lobbyWaitingForPlayers'
              '(controller.room!.seats.length, controller.room!.players) '
              '== loc.lobbyWaitingForPlayers(2, 4) == "$expectedText" for '
              'a 2-of-4 room; got "${waitingText.data}". The key is on the '
              'Text itself per the frozen declaration, so find.descendant '
              '(which excludes its own root) can never match here.',
        );
      },
    );

    testWidgets(
      'isHost false with a full room: lobby-start-button is absent, not '
      'present and disabled',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = List<Map<String, Object?>>.generate(
          4,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.join,
            code: 'ABC234',
            playerName: 'p1',
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
          seats: seats,
        );

        expect(controller.isHost, isFalse);
        expect(
          controller.room!.seats.length,
          controller.room!.players,
          reason: 'test setup: the room must be full for this scenario',
        );
        expect(
          find.byKey(const Key('lobby-start-button')),
          findsNothing,
          reason:
              'rule 4: when isHost is false there must be no widget keyed '
              'lobby-start-button anywhere in the tree, not a disabled one, '
              'even with a full room',
        );
      },
    );

    testWidgets(
      'isHost true with the room one seat short of full: start button '
      'present, onPressed is null',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = List<Map<String, Object?>>.generate(
          3,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );

        final id = await _mountAndCaptureRequest(
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
          seats: seats,
        );

        expect(controller.isHost, isTrue);
        expect(controller.room!.seats.length, 3);
        expect(controller.room!.players, 4);

        final finder = find.byKey(const Key('lobby-start-button'));
        expect(
          finder,
          findsOneWidget,
          reason:
              'rule 4: isHost is true, so lobby-start-button must be '
              'present even though the room is not full',
        );
        final button = tester.widget<ElevatedButton>(finder);
        expect(
          button.onPressed,
          isNull,
          reason:
              'rule 4: with 3 of 4 seats filled, onPressed must be null so '
              'the button is visibly disabled until the room is full',
        );
      },
    );

    testWidgets(
      'isHost true with a full room: start button present, tapping it '
      'reaches controller.startGame (a start_game request is sent)',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final seats = List<Map<String, Object?>>.generate(
          4,
          (i) => _seatJson(i, name: 'p$i', connected: true),
        );

        final id = await _mountAndCaptureRequest(
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
          seats: seats,
        );

        expect(controller.isHost, isTrue);
        expect(controller.room!.seats.length, controller.room!.players);

        final finder = find.byKey(const Key('lobby-start-button'));
        expect(finder, findsOneWidget);
        final button = tester.widget<ElevatedButton>(finder);
        expect(
          button.onPressed,
          isNotNull,
          reason:
              'rule 4: with a full room, onPressed must be non-null so the '
              'button is enabled',
        );

        final beforeCount = transport.sentRaw.length;
        await tester.tap(finder);
        await tester.pump();

        expect(
          transport.sentRaw.length,
          greaterThan(beforeCount),
          reason:
              'tapping lobby-start-button must send a new request over '
              'the wire (controller.startGame -> connection.startGame -> '
              "a 'start_game' frame); nothing new was sent",
        );
        final sentTypes = transport.sentRaw
            .skip(beforeCount)
            .map(_typeOf)
            .toList();
        expect(
          sentTypes,
          contains('start_game'),
          reason:
              'rule 4: tapping lobby-start-button must reach '
              "controller.startGame, which sends a 'start_game' request; "
              'the new messages sent were $sentTypes',
        );

        // Resolve the start_game request the tap armed (a plain frame, per
        // RoomController's own contract, not a room snapshot), so
        // addTearDown's dispose does not race flutter_test's pending-timer
        // invariant against a request the assertions above already
        // exercised (round 2 defect 2).
        final startId = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'game_started',
            re: startId,
            data: <String, Object?>{
              'turn': 0,
              'game_id': 'a' * 16,
              'client_seeds': '0:seed',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
      },
    );
  });

  // --- Rule 1: initState issues exactly one request, ever. ---------------
  group('rule 1: initState issues exactly one request', () {
    testWidgets(
      'LobbyAction.create calls createRoom(name:, players:) exactly once, '
      'and rebuilding the same screen does not re-issue it',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final screen = LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 3,
        );
        await _mountAndCaptureRequest(tester, screen, transport);

        final createMessages = transport.sentRaw
            .where((s) => _typeOf(s) == 'create_room')
            .toList();
        expect(
          createMessages,
          hasLength(1),
          reason:
              'rule 1: exactly one create_room request expected after '
              'mount, got ${createMessages.length}',
        );
        final sentData = _dataOf(createMessages.single);
        expect(sentData['name'], 'Sam');
        expect(sentData['players'], 3);

        // Rebuild the same widget (same controller, same configuration) by
        // pumping it again: Flutter updates the existing element in place
        // (didUpdateWidget), it does not remount and does not call
        // initState a second time.
        await tester.pumpWidget(_harness(screen));
        await tester.pump();
        await tester.pump();

        final createMessagesAfterRebuild = transport.sentRaw
            .where((s) => _typeOf(s) == 'create_room')
            .toList();
        expect(
          createMessagesAfterRebuild,
          hasLength(1),
          reason:
              'rule 1: initState must issue its request exactly once ever, '
              'not once per build; after an explicit rebuild there are '
              'still ${createMessagesAfterRebuild.length} create_room '
              'messages total, expected 1',
        );

        // Resolve the create_room request initState issued, so addTearDown's
        // dispose does not race flutter_test's pending-timer invariant
        // (round 2 defect 2). The reply's content is not the point of this
        // test; the assertions above already cover initState's behaviour.
        await _resolveConnected(
          tester,
          transport,
          _idOf(createMessagesAfterRebuild.single),
          seatForThisClient: 0,
        );
      },
    );

    testWidgets('LobbyAction.join calls joinRoom(code:, name:) exactly once', (
      tester,
    ) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ZZZZZZ',
          playerName: 'Riri',
        ),
        transport,
      );

      final joinMessages = transport.sentRaw
          .where((s) => _typeOf(s) == 'join_room')
          .toList();
      expect(
        joinMessages,
        hasLength(1),
        reason:
            'rule 1: exactly one join_room request expected after mount, '
            'got ${joinMessages.length}',
      );
      final sentData = _dataOf(joinMessages.single);
      expect(sentData['code'], 'ZZZZZZ');
      expect(sentData['name'], 'Riri');

      // Resolve the join_room request initState issued, so addTearDown's
      // dispose does not race flutter_test's pending-timer invariant
      // (round 2 defect 2).
      await _resolveConnected(
        tester,
        transport,
        _idOf(joinMessages.single),
        seatForThisClient: 0,
      );
    });
  });

  // --- Rule 2: the screen never disposes the controller. ------------------
  group('rule 2: the screen does not dispose the controller', () {
    testWidgets(
      'after the screen is removed from the tree, the controller is still '
      'usable: addListener does not throw',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);

        final id = await _mountAndCaptureRequest(
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

        // Remove the screen from the tree entirely, forcing State.dispose.
        await tester.pumpWidget(_harness(const SizedBox.shrink()));
        await tester.pump();

        expect(
          () => controller.addListener(() {}),
          returnsNormally,
          reason:
              'rule 2: LobbyScreen must never dispose a controller it did '
              'not create; a disposed ChangeNotifier throws on '
              'addListener, so this call throwing would mean the screen '
              'disposed the controller when it was removed from the tree',
        );
        expect(
          controller.phase,
          RoomPhase.connected,
          reason:
              'the controller must still hold its state after the screen '
              'is gone',
        );
        controller.dispose();
      },
    );
  });

  // --- Rule 7: the retry button re-issues the same request. ---------------
  group('rule 7: lobby-retry-button re-issues the same request', () {
    testWidgets(
      'after a failed create, tapping retry sends a second create_room '
      'with the same name and players',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 2,
          ),
          transport,
        );
        await _resolveFailed(tester, transport, id, code: 'RATE_LIMITED');
        expect(controller.phase, RoomPhase.failed);

        final retryTransport = FakeTransport();
        connector.enqueue(retryTransport);
        await tester.tap(find.byKey(const Key('lobby-retry-button')));
        await tester.pump();

        expect(
          connector.calls,
          hasLength(2),
          reason:
              'rule 7: tapping retry must open a fresh connection and '
              're-issue the request; expected 2 connect() calls total',
        );
        final createMessages = retryTransport.sentRaw
            .where((s) => _typeOf(s) == 'create_room')
            .toList();
        expect(
          createMessages,
          hasLength(1),
          reason:
              'rule 7: the retry must send exactly one create_room on the '
              'new transport',
        );
        final sentData = _dataOf(createMessages.single);
        expect(
          sentData,
          <String, Object?>{'name': 'Sam', 'players': 2},
          reason:
              'rule 7: retry must re-issue the same request with the same '
              'arguments initState issued; got $sentData',
        );

        // Resolve the retry's request, so addTearDown's dispose does not
        // race flutter_test's pending-timer invariant (round 2 defect 2).
        await _resolveConnected(
          tester,
          retryTransport,
          _idOf(createMessages.single),
          seatForThisClient: 0,
        );
      },
    );

    testWidgets(
      'after a failed join, tapping retry sends a second join_room with '
      'the same code and name',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.join,
            code: 'K7M2QP',
            playerName: 'Riri',
          ),
          transport,
        );
        await _resolveFailed(tester, transport, id, code: 'NO_SUCH_ROOM');
        expect(controller.phase, RoomPhase.failed);

        final retryTransport = FakeTransport();
        connector.enqueue(retryTransport);
        await tester.tap(find.byKey(const Key('lobby-retry-button')));
        await tester.pump();

        final joinMessages = retryTransport.sentRaw
            .where((s) => _typeOf(s) == 'join_room')
            .toList();
        expect(joinMessages, hasLength(1));
        final sentData = _dataOf(joinMessages.single);
        expect(
          sentData,
          <String, Object?>{'code': 'K7M2QP', 'name': 'Riri'},
          reason:
              'rule 7: retry after a failed join must resend the same '
              'code and name; got $sentData',
        );

        // Resolve the retry's request, so addTearDown's dispose does not
        // race flutter_test's pending-timer invariant (round 2 defect 2).
        await _resolveConnected(
          tester,
          retryTransport,
          _idOf(joinMessages.single),
          seatForThisClient: 0,
        );
      },
    );
  });

  // --- Rule 8/9: every string is localised; Arabic and RTL. --------------
  group('Arabic and RTL', () {
    testWidgets('pumped in Locale(ar), Directionality resolves to rtl and the '
        'connecting body shows the Arabic string, not the English one', (
      tester,
    ) async {
      final connector = _Connector();
      final transport = FakeTransport();
      connector.enqueue(transport);
      final controller = _newController(connector);
      addTearDown(controller.dispose);

      final id = await _mountAndCaptureRequest(
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

      final context = tester.element(find.byType(LobbyScreen));
      expect(
        Directionality.of(context),
        TextDirection.rtl,
        reason:
            'pumping LobbyScreen in Locale(ar) must resolve '
            'Directionality to rtl',
      );

      final locAr = lookupAppLocalizations(const Locale('ar'));
      final locEn = lookupAppLocalizations(const Locale('en'));
      expect(
        locAr.lobbyConnecting,
        isNot(locEn.lobbyConnecting),
        reason:
            'test sanity: app_en.arb and app_ar.arb must give different '
            'strings for lobbyConnecting, or this test cannot tell the '
            'two locales apart',
      );
      expect(
        find.text(locAr.lobbyConnecting),
        findsOneWidget,
        reason:
            'rule 8: the Arabic string for lobbyConnecting must be on '
            'screen when the locale is ar; got neither the Arabic nor '
            'possibly the English string instead',
      );
      expect(
        find.text(locEn.lobbyConnecting),
        findsNothing,
        reason:
            'the English lobbyConnecting string must not be on screen '
            'when the app locale is Arabic',
      );

      // Resolve the request initState issued, so addTearDown's dispose
      // does not race flutter_test's pending-timer invariant (round 2
      // defect 2). The reply's content is not the point of this test;
      // the assertions above already cover the connecting-phase body.
      await _resolveConnected(tester, transport, id, seatForThisClient: 0);
    });

    testWidgets(
      'pumped in Locale(ar), the connected body shows Arabic strings for '
      'lobby-waiting and the desync banner',
      (tester) async {
        final connector = _Connector();
        final transport = FakeTransport();
        connector.enqueue(transport);
        final controller = _newController(connector);
        addTearDown(controller.dispose);

        final id = await _mountAndCaptureRequest(
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
        final seats = <Map<String, Object?>>[
          _seatJson(0, name: 'سام', connected: true),
        ];
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          players: 4,
          seats: seats,
        );

        final locAr = lookupAppLocalizations(const Locale('ar'));
        final waitingTextAr = tester.widget<Text>(
          find.byKey(const Key('lobby-waiting')),
        );
        expect(
          waitingTextAr.data,
          locAr.lobbyWaitingForPlayers(1, 4),
          reason:
              'rule 8/4: lobby-waiting must be a Text of the Arabic '
              'lobbyWaitingForPlayers string when the locale is ar; got '
              '"${waitingTextAr.data}". The key is on the Text itself per '
              'the frozen declaration, so find.descendant (which excludes '
              'its own root) can never match here.',
        );

        // Force a desync and check the banner text too.
        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 9},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-desync-banner')),
            matching: find.text(locAr.lobbyDesynced),
          ),
          findsOneWidget,
          reason:
              'rule 8/5: the desync banner must show the Arabic '
              'lobbyDesynced string when the locale is ar',
        );

        // The gapped presence above did more than set hasDesynced: per
        // order 098's frozen declaration (F0), a gap now also makes the
        // controller send a background "resume" on this same, already-open
        // transport. flutter_test checks for a pending Timer immediately
        // after this body ends, before addTearDown runs, so that resume's
        // outstanding request timer has to be resolved here, not in
        // tear-down. Answer it with a room snapshot -- resolving is the
        // stronger proof for a test whose remaining assertions are about
        // what the Arabic strings say next, and it is what a real server
        // would eventually do.
        final resumeId = _idOf(transport.sentRaw.last);
        expect(
          _typeOf(transport.sentRaw.last),
          'resume',
          reason:
              'fixture is broken: the gapped presence above must have '
              'sent a resume as its last request on this transport',
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: resumeId,
            data: _roomJson(
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'سام', connected: false),
              ],
              seq: 9,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
      },
    );
  });
}
