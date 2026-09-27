// Widget-level conformance tests for order 202's Home rule toggles (Blocks,
// Capture bonus) and the rules they must put on the wire, written from the
// spec quoted verbatim in work/ludo/orders/201-prove-create-room-toggles.md
// against no implementation of the switches, RoomToggles or the new ARB
// getters this file's author has read. None of Key('home-rule-blocks'),
// Key('home-rule-capture-bonus'), RoomToggles or homeRuleBlocks/
// homeRuleCaptureBonus exists on the branch this file was written on.
//
// T1 and T2 never tap Create or Join, so they pump the real LudoApp (its
// locale toggle is what T1/T2 need to see both languages from one mount,
// per the standing "one mount per test case" rule) and never touch a real
// socket. T3-T8 all drive Create Room past its local validation, so each of
// those pumps HomeScreen directly with an injected controllerFactory whose
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
// Each test's name starts with its id (T1..T8), per the order.

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

const Key _disclosureKey = Key('home-players-disclosure');
const Key _selectorKey = Key('home-players-selector');
const Key _blocksSwitchKey = Key('home-rule-blocks');
const Key _captureSwitchKey = Key('home-rule-capture-bonus');
const Key _createButtonKey = Key('create-room-button');
const Key _localeToggleKey = Key('locale-toggle-button');
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

/// Opens the seat-count disclosure, which per the spec also reveals the two
/// rule switches underneath the selector. Fails loudly if the disclosure or
/// the selector it must reveal is not where every other test in this suite
/// expects it.
Future<void> _openPlayersDisclosure(WidgetTester tester) async {
  final Finder disclosure = find.byKey(_disclosureKey);
  expect(
    disclosure,
    findsOneWidget,
    reason:
        'home-players-disclosure must be on screen to open the '
        'selector and the rule switches under it',
  );
  await tester.ensureVisible(disclosure);
  await tester.tap(disclosure);
  await tester.pumpAndSettle();
  expect(
    find.byKey(_selectorKey),
    findsOneWidget,
    reason: 'tapping home-players-disclosure must reveal home-players-selector',
  );
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

void main() {
  testWidgets(
    'T1: disclosure closed shows neither switch, and the closed label is '
    'exactly the localised homePlayersDisclosureClosed, in English and in '
    'Arabic',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      expect(
        find.byKey(_blocksSwitchKey),
        findsNothing,
        reason:
            'the Blocks switch must not exist while the disclosure is '
            'closed',
      );
      expect(
        find.byKey(_captureSwitchKey),
        findsNothing,
        reason:
            'the Capture bonus switch must not exist while the '
            'disclosure is closed',
      );

      final AppLocalizations enLoc = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      );
      expect(
        enLoc.homePlayersDisclosureClosed,
        '4 players, standard rules',
        reason:
            'fixture is broken: order 202\'s spec pins this exact English '
            'string for homePlayersDisclosureClosed',
      );
      expect(
        find.text(enLoc.homePlayersDisclosureClosed),
        findsOneWidget,
        reason:
            'the closed disclosure must show homePlayersDisclosureClosed '
            'verbatim in English',
      );

      await tester.tap(find.byKey(_localeToggleKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(_blocksSwitchKey),
        findsNothing,
        reason:
            'the Blocks switch must still not exist after a locale '
            'toggle, with the disclosure still closed',
      );
      expect(
        find.byKey(_captureSwitchKey),
        findsNothing,
        reason:
            'the Capture bonus switch must still not exist after a '
            'locale toggle, with the disclosure still closed',
      );

      final AppLocalizations arLoc = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      );
      expect(
        arLoc.homePlayersDisclosureClosed,
        '4 لاعبين، القواعد العادية',
        reason:
            'fixture is broken: order 202\'s spec pins this exact Arabic '
            'string for homePlayersDisclosureClosed',
      );
      expect(
        find.text(arLoc.homePlayersDisclosureClosed),
        findsOneWidget,
        reason:
            'the closed disclosure must show homePlayersDisclosureClosed '
            'verbatim in Arabic',
      );
    },
  );

  testWidgets(
    'T2: disclosure opened shows both switches on by default with the '
    'localised titles, in English and in Arabic (Directionality rtl)',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      await _openPlayersDisclosure(tester);

      final Finder blocksSwitch = find.byKey(_blocksSwitchKey);
      final Finder captureSwitch = find.byKey(_captureSwitchKey);
      expect(
        blocksSwitch,
        findsOneWidget,
        reason: 'opening the disclosure must reveal home-rule-blocks',
      );
      expect(
        captureSwitch,
        findsOneWidget,
        reason: 'opening the disclosure must reveal home-rule-capture-bonus',
      );

      expect(
        tester.widget<SwitchListTile>(blocksSwitch).value,
        isTrue,
        reason: 'Blocks must be on when Home first builds',
      );
      expect(
        tester.widget<SwitchListTile>(captureSwitch).value,
        isTrue,
        reason: 'Capture bonus must be on when Home first builds',
      );

      final AppLocalizations enLoc = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      );
      expect(
        find.descendant(
          of: blocksSwitch,
          matching: find.text(enLoc.homeRuleBlocks),
        ),
        findsOneWidget,
        reason:
            'the Blocks switch title must read the localised homeRuleBlocks '
            'string in English',
      );
      expect(
        find.descendant(
          of: captureSwitch,
          matching: find.text(enLoc.homeRuleCaptureBonus),
        ),
        findsOneWidget,
        reason:
            'the Capture bonus switch title must read the localised '
            'homeRuleCaptureBonus string in English',
      );

      await tester.tap(find.byKey(_localeToggleKey));
      await tester.pumpAndSettle();

      expect(
        blocksSwitch,
        findsOneWidget,
        reason:
            'the Blocks switch must survive a locale toggle without the '
            'disclosure re-closing',
      );
      expect(
        captureSwitch,
        findsOneWidget,
        reason:
            'the Capture bonus switch must survive a locale toggle '
            'without the disclosure re-closing',
      );
      expect(
        tester.widget<SwitchListTile>(blocksSwitch).value,
        isTrue,
        reason: 'Blocks must still read on after a locale toggle alone',
      );
      expect(
        tester.widget<SwitchListTile>(captureSwitch).value,
        isTrue,
        reason: 'Capture bonus must still read on after a locale toggle alone',
      );

      final AppLocalizations arLoc = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      );
      expect(
        find.descendant(
          of: blocksSwitch,
          matching: find.text(arLoc.homeRuleBlocks),
        ),
        findsOneWidget,
        reason:
            'the Blocks switch title must read the localised homeRuleBlocks '
            'string in Arabic',
      );
      expect(
        find.descendant(
          of: captureSwitch,
          matching: find.text(arLoc.homeRuleCaptureBonus),
        ),
        findsOneWidget,
        reason:
            'the Capture bonus switch title must read the localised '
            'homeRuleCaptureBonus string in Arabic',
      );
      expect(
        Directionality.of(tester.element(blocksSwitch)),
        TextDirection.rtl,
        reason:
            'the ambient Directionality over the switches must be rtl '
            'once Arabic is the active locale',
      );
    },
  );

  testWidgets(
    'T3: tapping Create with both switches at their default sends rules '
    'with exactly blocks true and capture_bonus true, and no turn_seconds '
    'key',
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
        <String>{'blocks', 'capture_bonus'},
        reason:
            'd.rules must carry exactly the keys blocks and capture_bonus, '
            'never turn_seconds; got ${rules.keys.toList()}',
      );
      expect(
        rules,
        equals(<String, Object?>{'blocks': true, 'capture_bonus': true}),
      );
    },
  );

  testWidgets(
    'T4: turning Blocks off before Create sends blocks false, capture_bonus '
    'true',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _openPlayersDisclosure(tester);
      await tester.tap(find.byKey(_blocksSwitchKey));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byKey(_blocksSwitchKey)).value,
        isFalse,
        reason:
            'fixture is broken: tapping home-rule-blocks must turn it '
            'off before Create is even tapped',
      );

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      final Map<String, Object?> rules = _singleCreateRoomRules(
        factory.transports.single,
      );
      expect(
        rules,
        equals(<String, Object?>{'blocks': false, 'capture_bonus': true}),
      );
    },
  );

  testWidgets('T5: turning Capture bonus off before Create sends blocks true, '
      'capture_bonus false', (tester) async {
    final _LiveControllerFactory factory = _LiveControllerFactory();
    await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
    await tester.pumpAndSettle();

    await _openPlayersDisclosure(tester);
    await tester.tap(find.byKey(_captureSwitchKey));
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byKey(_captureSwitchKey)).value,
      isFalse,
      reason:
          'fixture is broken: tapping home-rule-capture-bonus must '
          'turn it off before Create is even tapped',
    );

    await _tapAndAwaitPushedRoute(tester, _createButtonKey);

    final Map<String, Object?> rules = _singleCreateRoomRules(
      factory.transports.single,
    );
    expect(
      rules,
      equals(<String, Object?>{'blocks': true, 'capture_bonus': false}),
    );
  });

  testWidgets(
    'T6: turning both Blocks and Capture bonus off before Create sends '
    'both false',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _openPlayersDisclosure(tester);
      await tester.tap(find.byKey(_blocksSwitchKey));
      await tester.pump();
      await tester.tap(find.byKey(_captureSwitchKey));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byKey(_blocksSwitchKey)).value,
        isFalse,
        reason:
            'fixture is broken: both switches must read off before '
            'Create is even tapped',
      );
      expect(
        tester.widget<SwitchListTile>(find.byKey(_captureSwitchKey)).value,
        isFalse,
        reason:
            'fixture is broken: both switches must read off before '
            'Create is even tapped',
      );

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      final Map<String, Object?> rules = _singleCreateRoomRules(
        factory.transports.single,
      );
      expect(
        rules,
        equals(<String, Object?>{'blocks': false, 'capture_bonus': false}),
      );
    },
  );

  testWidgets(
    'T7: toggles survive changing the player count: Blocks off, then 2 '
    'players, then Create sends players 2 and blocks false',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _openPlayersDisclosure(tester);
      await tester.tap(find.byKey(_blocksSwitchKey));
      await tester.pump();

      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(Scaffold)),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(_selectorKey),
          matching: find.text(loc.homePlayersTwo),
        ),
      );
      await tester.pump();
      final SegmentedButton<int> segmented = tester
          .widget<SegmentedButton<int>>(
            find.descendant(
              of: find.byKey(_selectorKey),
              matching: find.byType(SegmentedButton<int>),
            ),
          );
      expect(
        segmented.selected,
        <int>{2},
        reason:
            'fixture is broken: selecting 2 must select it before '
            'Create Room is even tapped',
      );

      await _tapAndAwaitPushedRoute(tester, _createButtonKey);

      expect(
        _pushedLobbyScreen(tester).players,
        2,
        reason:
            'the chosen player count must still reach LobbyScreen after '
            'Blocks was toggled off',
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
        rules['blocks'],
        isFalse,
        reason:
            'Blocks toggled off before Create must still read false on the '
            'wire after changing the player count',
      );
      expect(rules['capture_bonus'], isTrue);
    },
  );

  testWidgets(
    'T8: Retry after a failed create resends the same rules the first '
    'attempt did, with Blocks off going in',
    (tester) async {
      final _LiveControllerFactory factory = _LiveControllerFactory();
      await tester.pumpWidget(_homeScreenApp(controllerFactory: factory.call));
      await tester.pumpAndSettle();

      await _openPlayersDisclosure(tester);
      await tester.tap(find.byKey(_blocksSwitchKey));
      await tester.pump();

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
        equals(<String, Object?>{'blocks': false, 'capture_bonus': true}),
        reason:
            'fixture is broken: the first create_room must already carry '
            'Blocks off, or this test proves nothing about Retry '
            'preserving it',
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
        equals(<String, Object?>{'blocks': false, 'capture_bonus': true}),
      );
    },
  );
}
