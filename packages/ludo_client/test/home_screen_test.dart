// HomeScreen tests, per work order 083.
//
// Order 080 replaced HomeScreen's placeholder navigation (push a bare
// RoomScreen, carrying only a code) with the real one: Create Room and Join
// Room build a RoomController from widget.controllerFactory() and push
// LobbyScreen with it. Two tests below used to assert the placeholder
// behaviour; they are migrated here to assert the arguments LobbyScreen is
// actually pushed with, taken from order 080's frozen declaration (see
// work/orders/083-home-screen-test-migration.md, rule 10), not from reading
// lib/src/home_screen.dart.
//
// The default controllerFactory (defaultRoomControllerFactory,
// lib/src/server_config.dart) opens a real WebSocket to a production
// address. A widget test must never do that, so every test below that drives
// Create Room or Join Room past its local validation supplies its own
// controllerFactory, one that never constructs any transport, real or fake:
// its connect function rejects before anything is ever opened. That is
// sufficient for what this file asserts, because everything asserted here
// is a static constructor argument on the pushed LobbyScreen (action,
// players, code, playerName), none of which depend on the controller ever
// reaching phase connected. See "no socket, ever" below for exactly how
// that claim is checked.
//
// LudoApp (lib/src/app.dart) does not expose a controllerFactory parameter,
// so the tests that need to inject one pump HomeScreen directly inside a
// minimal MaterialApp built the same way LudoApp builds one (same
// localizationsDelegates and supportedLocales), rather than through LudoApp.
// The three tests that do not touch Create Room or Join Room's controller
// path are left exactly as they were, pumping LudoApp, per the order's
// explicit instruction not to rewrite them.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';

/// A [RoomControllerFactory] that never opens a transport, real or fake.
///
/// Its `connect` function throws before constructing anything: no
/// [WireTransport], no socket, nothing that could be mistaken for one. The
/// [RoomController] built here catches that rejection the same way it
/// catches any other connector failure (rule 2 of order 074: the
/// connector's future rejecting maps to phase failed, errorCode
/// 'transport') and settles into a static error screen with no further
/// scheduled animation, which is what lets a test move past it with a
/// couple of bounded pumps instead of pumpAndSettle -- see
/// [_tapAndAwaitPushedRoute] for why pumpAndSettle is deliberately not used
/// here.
///
/// This is the one and only controller factory used anywhere in this file.
/// Nothing here ever references defaultRoomControllerFactory or
/// connectWsTransport, which is how "no test in this file opens a socket"
/// is more than an assertion: the code path that could open one is simply
/// never reachable from anything pumped below.
RoomController _neverConnectsControllerFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-screen-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_screen_test.dart: this connector must never be asked to '
        'open a real or fake transport; it exists only so RoomController '
        'has something to fail against without ever constructing one',
      );
    },
  );
}

/// Pumps [HomeScreen] directly, the way LudoApp assembles it
/// (lib/src/app.dart) but with a substitutable [controllerFactory], which
/// LudoApp itself has no parameter for.
Widget _homeScreenApp({
  RoomControllerFactory controllerFactory = _neverConnectsControllerFactory,
}) {
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
/// calling pumpAndSettle.
///
/// LobbyScreen's own connecting state (RoomPhase.idle or .connecting) shows
/// a CircularProgressIndicator, whose ticker reschedules a frame
/// indefinitely; pumpAndSettle would not return, or would eventually throw
/// a timeout error, for as long as that state is on screen, regardless of
/// how quickly _neverConnectsControllerFactory's connector rejects. A fixed
/// pump of 400ms, comfortably past MaterialPageRoute's default 300ms
/// transition, is enough to get LobbyScreen mounted; every assertion this
/// file makes on it is a static constructor argument (action, players,
/// code, playerName), not anything that depends on which RoomPhase the
/// controller has reached, so nothing here needs the tree to fully settle.
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

void main() {
  testWidgets('home screen renders and shows both actions', (tester) async {
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold));
    final loc = AppLocalizations.of(context);

    expect(find.text(loc.appTitle), findsOneWidget);
    expect(find.byKey(const Key('create-room-button')), findsOneWidget);
    expect(find.text(loc.homeCreateRoomButton), findsOneWidget);
    expect(find.byKey(const Key('join-room-button')), findsOneWidget);
    expect(find.text(loc.homeJoinRoomButton), findsOneWidget);
    expect(find.byKey(const Key('room-code-field')), findsOneWidget);
  });

  testWidgets(
    'Create Room pushes LobbyScreen with action create, players from the '
    'selector default, and no code',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

      final LobbyScreen pushed = _pushedLobbyScreen(tester);
      expect(
        pushed.action,
        LobbyAction.create,
        reason: 'Create Room must push LobbyAction.create, order 080 rule 10',
      );
      expect(
        pushed.players,
        4,
        reason: 'the players selector defaults to 4, order 080 rule 12',
      );
      expect(
        pushed.code,
        isNull,
        reason: 'a Create Room push must not carry a room code',
      );
    },
  );

  testWidgets(
    'Join Room with a valid, dictated code pushes LobbyScreen with action '
    'join and the normalised code',
    (tester) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'ab2-3cd',
      );
      await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

      final LobbyScreen pushed = _pushedLobbyScreen(tester);
      expect(
        pushed.action,
        LobbyAction.join,
        reason: 'Join Room must push LobbyAction.join, order 080 rule 10',
      );
      expect(
        pushed.code,
        'AB23CD',
        reason:
            'a code dictated with a dash and typed in lower case ("ab2-3cd") '
            'must still arrive upper-cased and stripped of the dash '
            '("AB23CD"); that normalisation is what the test this one '
            'replaces was protecting, and losing it would be a regression '
            'even though the destination screen changed',
      );
    },
  );

  testWidgets(
    'Join Room with an invalid code shows an error and does not navigate',
    (tester) async {
      await tester.pumpWidget(const LudoApp());
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      final loc = AppLocalizations.of(context);

      await tester.enterText(
        find.byKey(const Key('room-code-field')),
        'AB01CD',
      );
      await tester.tap(find.byKey(const Key('join-room-button')));
      await tester.pumpAndSettle();

      expect(find.text(loc.homeRoomCodeInvalid), findsOneWidget);
      expect(
        find.byKey(const Key('room-screen-not-implemented')),
        findsNothing,
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason:
            'an invalid code must be rejected by local validation before '
            'any controller is built and before anything is pushed',
      );
    },
  );

  testWidgets('the locale toggle switches the visible language', (
    tester,
  ) async {
    await tester.pumpWidget(const LudoApp());
    await tester.pumpAndSettle();

    expect(find.text('Create Room'), findsOneWidget);

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();

    expect(find.text('Create Room'), findsNothing);
    expect(find.text('إنشاء غرفة'), findsOneWidget);
  });

  group('the name field, order 080 rule 11', () {
    testWidgets(
      'is present, keyed home-name-field, with the localised label',
      (tester) async {
        await tester.pumpWidget(_homeScreenApp());
        await tester.pumpAndSettle();

        final context = tester.element(find.byType(Scaffold));
        final loc = AppLocalizations.of(context);

        expect(find.byKey(const Key('home-name-field')), findsOneWidget);
        expect(find.text(loc.homeNameFieldLabel), findsOneWidget);
      },
    );

    testWidgets('a typed name reaches LobbyScreen.playerName verbatim', (
      tester,
    ) async {
      await tester.pumpWidget(_homeScreenApp());
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('home-name-field')),
        'Priya',
      );
      await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

      final LobbyScreen pushed = _pushedLobbyScreen(tester);
      expect(pushed.playerName, 'Priya');
    });

    testWidgets(
      'an empty name field falls back to the localised default name, and '
      'an empty string is never passed',
      (tester) async {
        await tester.pumpWidget(_homeScreenApp());
        await tester.pumpAndSettle();

        final context = tester.element(find.byType(Scaffold));
        final String defaultName = AppLocalizations.of(
          context,
        ).homeDefaultPlayerName;
        expect(
          defaultName,
          isNotEmpty,
          reason:
              'fixture is broken: homeDefaultPlayerName itself must not be '
              'empty or this test proves nothing',
        );

        await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

        final LobbyScreen pushed = _pushedLobbyScreen(tester);
        expect(pushed.playerName, isNotEmpty);
        expect(pushed.playerName, defaultName);
      },
    );

    testWidgets(
      'a name field containing only whitespace also falls back to the '
      'localised default, not to a blank string',
      (tester) async {
        await tester.pumpWidget(_homeScreenApp());
        await tester.pumpAndSettle();

        final context = tester.element(find.byType(Scaffold));
        final String defaultName = AppLocalizations.of(
          context,
        ).homeDefaultPlayerName;

        await tester.enterText(
          find.byKey(const Key('home-name-field')),
          '   ',
        );
        await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

        final LobbyScreen pushed = _pushedLobbyScreen(tester);
        expect(
          pushed.playerName,
          defaultName,
          reason:
              'a name of only whitespace must be trimmed to empty and then '
              'fall back, the same as a genuinely empty field; got '
              '"${pushed.playerName}"',
        );
      },
    );
  });

  group('the players selector, order 080 rule 12', () {
    testWidgets(
      'is present, keyed home-players-selector, defaulting to 4',
      (tester) async {
        await tester.pumpWidget(_homeScreenApp());
        await tester.pumpAndSettle();

        final Finder selectorKey = find.byKey(
          const Key('home-players-selector'),
        );
        expect(selectorKey, findsOneWidget);

        final SegmentedButton<int> segmented = tester
            .widget<SegmentedButton<int>>(
              find.descendant(
                of: selectorKey,
                matching: find.byType(SegmentedButton<int>),
              ),
            );
        expect(
          segmented.selected,
          <int>{4},
          reason: 'the players selector must default to 4',
        );
      },
    );

    testWidgets(
      'selecting 2 and then Create Room pushes LobbyScreen.players == 2',
      (tester) async {
        await tester.pumpWidget(_homeScreenApp());
        await tester.pumpAndSettle();

        final context = tester.element(find.byType(Scaffold));
        final loc = AppLocalizations.of(context);

        await tester.tap(
          find.descendant(
            of: find.byKey(const Key('home-players-selector')),
            matching: find.text(loc.homePlayersTwo),
          ),
        );
        await tester.pumpAndSettle();

        final SegmentedButton<int> segmented = tester
            .widget<SegmentedButton<int>>(
              find.descendant(
                of: find.byKey(const Key('home-players-selector')),
                matching: find.byType(SegmentedButton<int>),
              ),
            );
        expect(
          segmented.selected,
          <int>{2},
          reason: 'fixture is broken: selecting 2 must select it before '
              'Create Room is even tapped',
        );

        await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

        final LobbyScreen pushed = _pushedLobbyScreen(tester);
        expect(
          pushed.players,
          2,
          reason: 'the chosen player count must be the one Create Room '
              'passes to LobbyScreen, not the default',
        );
      },
    );
  });
}
