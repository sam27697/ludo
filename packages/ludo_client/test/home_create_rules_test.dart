// Widget-level conformance tests for the rules Home puts on the create_room
// wire (originally order 202's Home rule toggles, written from
// work/ludo/orders/201-prove-create-room-toggles.md).
//
// C-523 D1 removed the rule control from home: every room is created with
// const RoomToggles(), capture bonus on, and the client keeps sending the
// rules field exactly as before. The cases that drove the toggle (T1, T2,
// T5) went with it, and T7 and T8 now run with the default rules. T3 is
// unchanged. T4 and T6 stay dropped, for the C-356 reasons recorded in the
// comments below.
//
// Every case drives Create Room past its local validation, so each pumps
// HomeScreen directly with an injected controllerFactory whose
// connect function hands out a fresh FakeTransport per attempt (never a
// real WebSocket), the same fixture idiom test/home_screen_test.dart
// already uses for its own live-controller scenarios, extended here to
// hand out a new transport per connect() call rather than one fixed
// transport per controller, which is what a retry after a failed create
// needs: RoomController opens a brand new RoomConnection over the same
// connect callback on every accepted createRoom, and a FakeTransport that
// has already been closed once must never be reused as if it were still
// open.
//
// Each test's name starts with its id (T3, T7, T8), per the order.

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

import 'net/fake_transport.dart';

const Key _playersButtonKey = Key('home-players-button');
const Key _createButtonKey = Key('create-room-button');
const Key _retryButtonKey = Key('lobby-retry-button');

/// Hands out a fresh [RoomController] on every call, each wired to a
/// connector that itself hands out a fresh [FakeTransport] on every
/// connection attempt that controller makes -- not one fixed transport for
/// the controller's whole life. [controllers] and [transports] both
/// accumulate in call order across every controller and every connect
/// attempt, so a test that drives a retry (a second accepted createRoom on
/// the same controller) can tell the first attempt's transport from the
/// second's.
class _LiveControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final RoomController created = RoomController(
      serverUrl: Uri.parse('wss://home-rule-toggles-test.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
    controllers.add(created);
    return created;
  }
}

/// Pumps [HomeScreen] directly, the way LudoApp assembles it
/// (lib/src/app.dart) but with a substitutable [controllerFactory], which
/// LudoApp itself has no parameter for. Only used by T3 onward: T1 and T2
/// never tap Create or Join and pump the real [LudoApp] instead, so they
/// can also exercise its locale toggle from a single mount.
Widget _homeScreenApp({required RoomControllerFactory controllerFactory}) {
  return MaterialApp(
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

/// Taps the button at [buttonKey] and pumps just long enough for the pushed
/// route's transition to finish and LobbyScreen to be mounted, without ever
/// calling pumpAndSettle: LobbyScreen's connecting state shows a
/// CircularProgressIndicator, whose ticker reschedules a frame indefinitely,
/// which is exactly the standing lesson against pumpAndSettle once
/// LobbyScreen is on screen. A fixed pump of 400ms, comfortably past
/// MaterialPageRoute's default 300ms transition, is enough to get
/// LobbyScreen mounted and its initState's request sent.
Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
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

/// Picks [count] seats through the players menu (C-523 D2): a tap on
/// home-players-button opens it, a tap on home-players-option-$count picks
/// and closes it. Bounded pumps only: nothing here mounts a LobbyScreen yet.
Future<void> _pickPlayers(WidgetTester tester, int count) async {
  final Finder control = find.byKey(_playersButtonKey);
  expect(
    control,
    findsOneWidget,
    reason: 'home-players-button must be on screen to open the seat-count menu',
  );
  await tester.tap(control);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(Key('home-players-option-$count')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Every frame a [FakeTransport] has captured so far, decoded. Assumes every
/// entry in [FakeTransport.sentRaw] is well-formed JSON built by
/// Frame.encode, which is what the engine under test is required to send.
List<Map<String, Object?>> _decodeSent(FakeTransport transport) {
  return transport.sentRaw
      .map((String raw) => jsonDecode(raw) as Map<String, Object?>)
      .toList();
}

/// A server-side error frame, encoded exactly as Frame.decode expects.
String _serverErrorFrame({required String re, required String code}) {
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': 'error',
    'id': 'srv-error-0000001',
    're': re,
    'd': <String, Object?>{'code': code, 'message': 'room is full'},
  });
}

/// Asserts [transport] has sent exactly one frame, that it is create_room,
/// and returns its decoded `d.rules`.
Map<String, Object?> _singleCreateRoomRules(FakeTransport transport) {
  final List<Map<String, Object?>> sent = _decodeSent(transport);
  expect(
    sent,
    hasLength(1),
    reason:
        'fixture is broken: exactly one request must have been sent on '
        'this transport by now; got ${sent.map((f) => f['t']).toList()}',
  );
  expect(sent.single['t'], 'create_room');
  final Map<String, Object?> data = sent.single['d']! as Map<String, Object?>;
  return data['rules']! as Map<String, Object?>;
}

/// T3 through T8 all drive Create (and T8's Retry drives it a second time)
/// without ever answering the create_room request on the wire, so
/// RoomConnection's 10 second request timeout outlives the widget tree
/// each of those tests leaves mounted; firing it here, after the test's
/// own assertions are done, is what keeps flutter_test from finding that
/// timer still pending at teardown.
Future<void> _drainPendingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

void main() {
  testWidgets(
    'T3: tapping Create with the switch at its default sends rules with '
    'exactly capture_bonus true, no blocks key and no turn_seconds key',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      expect(
        factory.transports,
        hasLength(1),
        reason:
            'fixture is broken: Create Room must have opened exactly one '
            'transport by now',
      );
      final Map<String, Object?> rules = _singleCreateRoomRules(
        factory.transports.single,
      );
      expect(
        rules.keys.toSet(),
        <String>{'capture_bonus'},
        reason:
            'C-356: d.rules must carry exactly the key capture_bonus, '
            'never blocks and never turn_seconds; got ${rules.keys.toList()}',
      );
      expect(rules, equals(<String, Object?>{'capture_bonus': true}));

      await _drainPendingRequestTimeout(tester);
    },
  );

  // T4 ("turning Blocks off before Create sends blocks false, capture_bonus
  // true") is dropped: its only assertions were about tapping home-rule-blocks
  // and reading the resulting wire rules, and the Blocks switch no longer
  // exists for anything to tap. Collapsed into T2's absence check plus T3's
  // default-rules case; see the file header for the full note.

  // T6 ("turning both Blocks and Capture bonus off...") is dropped for the
  // same reason as T4: with only one switch left, "both off" is identical to
  // T5's "the one switch off", and keeping it would assert the same wire
  // content twice under a name that no longer describes two switches.

  testWidgets(
    'T7: the chosen player count reaches the wire: 2 players, then Create '
    'sends players 2 and the default rules',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _pickPlayers(tester, 2);
      expect(
        find.descendant(
          of: find.byKey(_playersButtonKey),
          matching: find.text('2'),
        ),
        findsOneWidget,
        reason:
            'fixture is broken: picking 2 must show 2 on home-players-button '
            'before Create Room is even tapped',
      );

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      expect(
        _pushedLobbyScreen(tester).players,
        2,
        reason: 'the chosen player count must still reach LobbyScreen',
      );

      final List<Map<String, Object?>> sent = _decodeSent(
        factory.transports.single,
      );
      expect(sent, hasLength(1));
      final Map<String, Object?> data =
          sent.single['d']! as Map<String, Object?>;
      expect(
        data['players'],
        2,
        reason: 'the wire create_room must carry players 2 as well',
      );
      final Map<String, Object?> rules = data['rules']! as Map<String, Object?>;
      expect(
        rules.containsKey('blocks'),
        isFalse,
        reason: 'C-356: no blocks key may appear on the wire, ever',
      );
      expect(
        rules['capture_bonus'],
        isTrue,
        reason:
            'C-523 D1: every room is created with capture bonus on, so the '
            'wire must read true after changing the player count',
      );

      await _drainPendingRequestTimeout(tester);
    },
  );

  testWidgets(
    'T8: Retry after a failed create resends the same rules the first '
    'attempt did',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      expect(
        factory.transports,
        hasLength(1),
        reason:
            'fixture is broken: the first Create attempt must open exactly '
            'one transport',
      );
      final FakeTransport firstTransport = factory.transports.single;
      final List<Map<String, Object?>> firstSent = _decodeSent(firstTransport);
      expect(firstSent, hasLength(1));
      expect(firstSent.single['t'], 'create_room');
      final String firstRequestId = firstSent.single['id']! as String;
      final Map<String, Object?> firstData =
          firstSent.single['d']! as Map<String, Object?>;
      final Map<String, Object?> firstRules =
          firstData['rules']! as Map<String, Object?>;
      expect(
        firstRules,
        equals(<String, Object?>{'capture_bonus': true}),
        reason:
            'fixture is broken: the first create_room must carry the '
            'default rules (C-523 D1), or this test proves nothing about '
            'Retry preserving them',
      );

      firstTransport.pushText(
        _serverErrorFrame(re: firstRequestId, code: 'ROOM_FULL'),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(_retryButtonKey),
        findsOneWidget,
        reason:
            'a create_room answered with a ROOM_FULL error must land the '
            'lobby in its error body with lobby-retry-button on screen; '
            'ROOM_FULL is not one of the auto-retryable codes and this '
            'controller never held a room, so retryableFailure in '
            'lobby_screen.dart must read false here',
      );

      await tester.tap(find.byKey(_retryButtonKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        factory.transports,
        hasLength(2),
        reason:
            'Retry must open a fresh connection the same way the first '
            'Create attempt did, not reuse the one already closed by the '
            'failed attempt',
      );
      final FakeTransport secondTransport = factory.transports[1];
      final List<Map<String, Object?>> secondSent = _decodeSent(
        secondTransport,
      );
      expect(
        secondSent,
        hasLength(1),
        reason:
            'Retry must send exactly one create_room on the fresh '
            'transport',
      );
      expect(secondSent.single['t'], 'create_room');
      final Map<String, Object?> secondData =
          secondSent.single['d']! as Map<String, Object?>;
      expect(
        secondData['rules'],
        equals(firstRules),
        reason:
            'Retry must resend exactly the same rules the first create_room '
            'attempt did; first attempt sent $firstRules, retry sent '
            '${secondData['rules']}',
      );
      expect(
        secondData['rules'],
        equals(<String, Object?>{'capture_bonus': true}),
      );

      await _drainPendingRequestTimeout(tester);
    },
  );
}
