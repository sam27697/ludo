// Proof of C-325 rules 2 and 3: the one VerifyRollsButton sits behind both
// doors the app already has a key for. On this tree lib/src/
// verify_rolls_button.dart does not exist yet, so every case below is red
// on that missing name and on game-screen-verify-button /
// home-last-game-check still resolving to the pre-325 widgets (a bare
// TextButton and an InkWell), not on a mistake in this file's own code.
//
// The end card is mounted the way test/end_card_test.dart's own
// _connectTo/_mount do: a real RoomController over a FakeTransport
// (test/net/fake_transport.dart, read-only), copied rather than imported,
// per this project's standing rule never to import across test files. The
// room snapshot lands state FINISHED on the very first reply (docs/
// PROTOCOL.md section 10: the decoder checks no cross-field game-state
// coherence, only types), with verify_url set directly on that snapshot
// the way RoomSnapshot.fromJson documents a snapshot "that happens to
// carry the same key" is read -- so this file never has to script a whole
// game through rolled/moved/game_over to reach the end card.
//
// Home is mounted the way test/last_game_home_test.dart's own rule 3/4
// group seeds it: SessionMemory.recordLastGame directly into
// SharedPreferences, then HomeScreen with an injected fixed clock. Its
// controllerFactory is never called in that case (no tap ever reaches
// Create or Join), so it is a stub that would throw if it ever were.
//
// C-325 rule 4 (the stat words) has no file of its own in order 326's
// file list: test/end_card_test.dart and test/end_card_labels_fit_test
// .dart are both restricted there to only the lines order 326 section 4
// names, and no third new test file is on that list. Rule 4's own matrix
// (en 0/1/2, ar 0/1/2/11, read per tile) is proved here instead, next to
// the end-card harness this file already needed for rule 2. Flagged in
// ORDER-326-REPORT.md as the ambiguity it is.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:ludo_client/src/session_memory.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;
import 'package:ludo_client/src/verify_rolls_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _verifyKey = Key('game-screen-verify-button');
const Key _homeLastGameCheckKey = Key('home-last-game-check');

// --- end-card half: a real RoomController landing straight on FINISHED ----

const String _testUrl = 'wss://verify-door-wiring-test.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'verify-door-wiring-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

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

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

/// A FINISHED room snapshot, verify_url included directly on the
/// snapshot (RoomSnapshot.fromJson's own "client-only" field, read off
/// any room json that carries the key, not only off a game_over frame).
Map<String, Object?> _finishedRoomJson({
  required int winner,
  required String verifyUrl,
}) => <String, Object?>{
  'code': 'VDOORW',
  'state': 'FINISHED',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': 'verify-door-wiring-game',
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ],
  'turn': null,
  'winner': winner,
  'verify_url': verifyUrl,
  'seq': 1,
};

Widget _gameScreenHarness(
  RoomController controller, {
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: GameScreen(controller: controller),
  );
}

/// Connects a fresh controller directly onto a FINISHED room carrying
/// [verifyUrl], mySeat always 0, and mounts GameScreen over it. No
/// rolled/moved/game_over scripting: the first reply to create_room is
/// the finished snapshot itself.
Future<RoomController> _mountFinishedEndCard(
  WidgetTester tester, {
  required int winner,
  required String verifyUrl,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
  );
  addTearDown(controller.dispose);

  final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _finishedRoomJson(winner: winner, verifyUrl: verifyUrl),
    ),
  );
  await created;

  await tester.pumpWidget(_gameScreenHarness(controller));
  await tester.pump();
  // _Celebration's burst is bounded at 1200ms; one pump runs it out so no
  // ticker is left pending at tear-down.
  await tester.pump(const Duration(milliseconds: 1200));
  // Landing straight on FINISHED still fires GameScreen's own game_log
  // fetch (test/last_game_home_test.dart's own comment on the same
  // point); this transport never answers it, so its 10s request timeout
  // is flushed here rather than left pending at tear-down.
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  return controller;
}

// --- home half: a seeded LastGame, no network at all ----------------------

RoomController _unusedControllerFactory() => RoomController(
  serverUrl: Uri.parse(_testUrl),
  connect: (Uri url) async {
    throw UnimplementedError(
      'verify_door_wiring_test: the home-last-game-check case never taps '
      'Create or Join, so controllerFactory must never be called',
    );
  },
);

Widget _homeScreenApp({
  required DateTime Function() clock,
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _unusedControllerFactory,
      clock: clock,
    ),
  );
}

// --- rule 4 half: EndCard mounted directly with a controlled GameStats ----
// (end_card_labels_fit_test.dart's own _harness pattern, copied rather
// than imported.)

Widget _endCardHarness({required Locale locale, required GameStats stats}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SingleChildScrollView(
        child: EndCard(
          mySeat: 0,
          winnerSeat: 0,
          winnerName: 'Sam',
          seatColors: LudoColors.seats,
          stats: stats,
          verifyUrl: 'https://verify-door-wiring-test.invalid/verify',
          onVerify: () {},
          onNewTable: () {},
          onRematch: () {},
        ),
      ),
    ),
  );
}

Future<void> _pumpEndCard(WidgetTester tester, Widget harness) async {
  await tester.pumpWidget(harness);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1200));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('rule 2: the end card\'s own verify button is a VerifyRollsButton', () {
    testWidgets('game-screen-verify-button resolves to VerifyRollsButton', (
      tester,
    ) async {
      await _mountFinishedEndCard(
        tester,
        winner: 0,
        verifyUrl: 'https://verify-door-wiring-test.invalid/verify/door',
      );
      final Finder keyed = find.byKey(_verifyKey);
      expect(
        keyed,
        findsOneWidget,
        reason: 'fixture is broken: game-screen-verify-button must mount',
      );
      // Mutation this catches: the key left on an inner TextButton (or
      // any other wrapper) instead of moved onto the VerifyRollsButton
      // instance itself, which the contract requires so every existing
      // test finding this key still finds a tappable control, now of
      // the one contract-named type.
      expect(
        tester.widget(keyed),
        isA<VerifyRollsButton>(),
        reason:
            'game-screen-verify-button must resolve to a VerifyRollsButton; '
            'got ${tester.widget(keyed).runtimeType}',
      );
    });
  });

  group('rule 3: home\'s own verify check is the same VerifyRollsButton', () {
    testWidgets('home-last-game-check resolves to VerifyRollsButton', (
      tester,
    ) async {
      final DateTime fixedNow = DateTime.utc(2026, 10, 12, 12, 0, 0);
      await SessionMemory.recordLastGame(
        LastGame(
          gameId: 'g-verify-door-wiring',
          verifyUrl: 'https://verify-door-wiring-test.invalid/verify/home',
          finishedAt: fixedNow.subtract(const Duration(days: 1)),
          won: true,
        ),
      );
      await tester.pumpWidget(_homeScreenApp(clock: () => fixedNow));
      await tester.pumpAndSettle();

      final Finder keyed = find.byKey(_homeLastGameCheckKey);
      expect(
        keyed,
        findsOneWidget,
        reason: 'fixture is broken: home-last-game-check must mount',
      );
      // Mutation this catches: C-322's own InkWell kept as the tap
      // target instead of being replaced by VerifyRollsButton, which
      // would leave home's door looking different from the game
      // screen's, exactly what C-325 rule 1 exists to end.
      expect(
        tester.widget(keyed),
        isA<VerifyRollsButton>(),
        reason:
            'home-last-game-check must resolve to a VerifyRollsButton; '
            'got ${tester.widget(keyed).runtimeType}',
      );
    });
  });

  group('rule 4: stat words agree with their own tile\'s count', () {
    Future<void> expectTileWord(
      WidgetTester tester,
      String keyName,
      String word,
    ) async {
      expect(
        find.descendant(
          of: find.byKey(Key(keyName)),
          matching: find.text(word),
        ),
        findsOneWidget,
        reason: 'end-card-stat tile "$keyName" must show the word "$word"',
      );
    }

    GameStats stats(int count) => GameStats(
      rolls: count,
      sixes: count,
      capturesMade: count,
      timesCaptured: 0,
      tokensHome: count,
      complete: true,
    );

    testWidgets('en count 1: roll, six, capture, home', (tester) async {
      await _pumpEndCard(
        tester,
        _endCardHarness(locale: const Locale('en'), stats: stats(1)),
      );
      // Mutation this catches: the ICU =1 branch written as the plural
      // ("rolls" instead of "roll"), which =1 and other identical would
      // hide on every count except exactly one.
      await expectTileWord(tester, 'end-card-stat-rolls', 'roll');
      await expectTileWord(tester, 'end-card-stat-sixes', 'six');
      await expectTileWord(tester, 'end-card-stat-captures', 'capture');
      await expectTileWord(tester, 'end-card-stat-home', 'home');
    });

    testWidgets('en count 2: rolls, sixes, captures, home', (tester) async {
      await _pumpEndCard(
        tester,
        _endCardHarness(locale: const Locale('en'), stats: stats(2)),
      );
      // Mutation this catches: the "other" branch narrowed to a literal
      // count instead of ICU's real default (for example "=2" standing
      // in for "other"), which would pass this one case while failing
      // every other count above one.
      await expectTileWord(tester, 'end-card-stat-rolls', 'rolls');
      await expectTileWord(tester, 'end-card-stat-sixes', 'sixes');
      await expectTileWord(tester, 'end-card-stat-captures', 'captures');
      await expectTileWord(tester, 'end-card-stat-home', 'home');
    });

    testWidgets('en count 0 reads the plural', (tester) async {
      await _pumpEndCard(
        tester,
        _endCardHarness(locale: const Locale('en'), stats: stats(0)),
      );
      // Mutation this catches: =1 written loosely enough to also catch
      // 0 (for example a `count <= 1` branch instead of ICU's exact
      // =1), which would show the singular on a game with no rolls,
      // sixes or captures at all.
      await expectTileWord(tester, 'end-card-stat-rolls', 'rolls');
      await expectTileWord(tester, 'end-card-stat-sixes', 'sixes');
      await expectTileWord(tester, 'end-card-stat-captures', 'captures');
      await expectTileWord(tester, 'end-card-stat-home', 'home');
    });

    for (final int count in const <int>[0, 1, 2, 11]) {
      testWidgets(
        'ar count $count: the definite forms, invariant across every count',
        (tester) async {
          await _pumpEndCard(
            tester,
            _endCardHarness(locale: const Locale('ar'), stats: stats(count)),
          );
          // Mutation this catches: the Arabic forms left as (or swapped
          // back to) the indefinite plural C-325 replaces (رميات/ستّات/
          // ضربات instead of الرميات/الستّات/الضربات), or an =1/=2
          // branch added to a message the contract specifies as
          // other-only, which would only show at this one count.
          await expectTileWord(tester, 'end-card-stat-rolls', 'الرميات');
          await expectTileWord(tester, 'end-card-stat-sixes', 'الستّات');
          await expectTileWord(tester, 'end-card-stat-captures', 'الضربات');
          await expectTileWord(tester, 'end-card-stat-home', 'في البيت');
        },
      );
    }
  });
}
