// Widget tests for contract C-322 rules 2-5: HomeScreen writes LastGame
// the moment it observes a finished game (not on leave), shows
// home-last-game once the route pops back to Home, hides it past the
// 90-day window, and its tap target only ever talks to the url_launcher
// plugin.
//
// HomeScreen, RoomController, LobbyScreen and GameScreen are driven the
// same way test/leave_table_end_card_test.dart and
// test/game_screen_new_room_button_test.dart drive them: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only), with the connector/frame/room-json helpers and the
// url_launcher method-channel spy copied from those files and from
// test/game_verify_card_test.dart rather than imported, per this order's
// own instruction. One mount per case.
//
// LastGame, SessionMemory.recordLastGame, the lastGame field, HomeScreen's
// clock parameter and AppLocalizations.homeLastGame do not exist on this
// tree: contract C-322's implementation (order 322) lands in lib/ in
// parallel, in a tree this file's author has not opened. Every case below
// is red on those missing names, not on a mistake in this file's own
// code.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://last-game-home-test.invalid/ws';

const Key _createKey = Key('create-room-button');
const Key _appbarLeaveKey = Key('game-screen-appbar-leave');
const Key _homeLastGameKey = Key('home-last-game');
const Key _homeLastGameCheckKey = Key('home-last-game-check');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'last-game-home-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
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
  String code = 'LG3HOM',
  required String state,
  int hostSeat = 0,
  int players = 2,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  Map<String, Object?>? rematch,
  required int seq,
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
  'game_id': gameId,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'rematch': ?rematch,
  'seq': seq,
};

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
}

Widget _homeScreenApp(
  RoomControllerFactory controllerFactory, {
  DateTime Function()? clock,
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
      controllerFactory: controllerFactory,
      clock: clock,
    ),
  );
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// RoomConnection's request timeout is ten seconds. Advance past it so a
/// leave_room this test never answers does not leave a pending timer for
/// flutter_test to fail the tear-down over.
Future<void> _flushOutstandingRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

/// Answers every open `leave_room` on [transports] with a `player_left`
/// naming seat 0, the same stand-in test/game_screen_new_room_button_test
/// .dart's own helper uses: leave()'s request only cares that some frame
/// answers its id, not the type.
void _answerOpenLeaveRooms(List<FakeTransport> transports) {
  for (final FakeTransport transport in transports) {
    if (transport.isClosed) {
      continue;
    }
    for (final String raw in transport.sentRaw) {
      if (_typeOf(raw) != 'leave_room') {
        continue;
      }
      transport.pushText(
        _frame(
          type: 'player_left',
          re: _idOf(raw),
          data: <String, Object?>{'seat': 0, 'seq': 99},
        ),
      );
    }
  }
}

// --- url_launcher method channel spy, copied from
// --- test/game_verify_card_test.dart's own ---------------------------------

const List<String> _urlLauncherChannels = <String>[
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/url_launcher_macos',
  'plugins.flutter.io/url_launcher_linux',
  'plugins.flutter.io/url_launcher_windows',
  'plugins.flutter.io/url_launcher_web',
  'plugins.flutter.io/url_launcher_android',
  'plugins.flutter.io/url_launcher_ios',
];

List<MethodCall> _listenUrlLaunches(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> handler(MethodCall call) async {
    calls.add(call);
    return true;
  }

  for (final String name in _urlLauncherChannels) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return calls;
}

bool _containsUrl(Object? value, String url) {
  if (value is String) {
    return value.contains(url);
  }
  if (value is Map) {
    return value.values.any((Object? item) => _containsUrl(item, url));
  }
  if (value is Iterable) {
    return value.any((Object? item) => _containsUrl(item, url));
  }
  return false;
}

bool _launched(List<MethodCall> calls, String url) {
  return calls.any(
    (MethodCall call) =>
        _containsUrl(call.arguments, url) || call.method.contains(url),
  );
}

// --- blob scanning, copied from test/leave_table_end_card_test.dart's own --

void _writeBlob(StringBuffer out, String? value) {
  if (value != null && value.trim().isNotEmpty) {
    out.writeln(value);
  }
}

void _walkSemantics(SemanticsNode node, StringBuffer out) {
  _writeBlob(out, node.label);
  _writeBlob(out, node.value);
  _writeBlob(out, node.hint);
  _writeBlob(out, node.tooltip);
  node.visitChildren((SemanticsNode child) {
    _walkSemantics(child, out);
    return true;
  });
}

String _blobUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  final Finder descendants = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget _) => true),
  );
  for (final Element element in <Element>[
    tester.element(root),
    ...descendants.evaluate(),
  ]) {
    final Widget widget = element.widget;
    if (widget is Text) {
      _writeBlob(out, widget.data);
      _writeBlob(out, widget.textSpan?.toPlainText());
    } else if (widget is RichText) {
      _writeBlob(out, widget.text.toPlainText());
    } else if (widget is Semantics) {
      _writeBlob(out, widget.properties.label);
      _writeBlob(out, widget.properties.value);
      _writeBlob(out, widget.properties.hint);
    }
  }
  try {
    _walkSemantics(tester.getSemantics(root), out);
  } catch (_) {
    // No semantics node; text descendants above still count.
  }
  return out.toString();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(HomeScreen)));

// --- rule 2/3 fixture: create from Home into a PLAYING room, then push a
// --- `game_over` frame, the contract's own literal path --------------------

/// Creates from a freshly pumped HomeScreen, lands this device on seat 0 of
/// a PLAYING room carrying [gameId], and returns the factory so the caller
/// can keep pushing frames on `factory.transports.single`.
Future<_RecordingControllerFactory> _createPlayingFromHome(
  WidgetTester tester, {
  required String gameId,
  List<Map<String, Object?>>? seats,
  DateTime Function()? clock,
}) async {
  final _RecordingControllerFactory factory = _RecordingControllerFactory();
  await tester.pumpWidget(_homeScreenApp(factory.call, clock: clock));
  await tester.pumpAndSettle();

  await _tapAndAwaitPushedRoute(tester, _createKey);
  expect(
    factory.controllers,
    hasLength(1),
    reason: 'fixture is broken: Create Room must build exactly one controller',
  );
  final FakeTransport transport = factory.transports.single;
  final List<String> createMessages = transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'create_room')
      .toList();
  expect(
    createMessages,
    hasLength(1),
    reason:
        'fixture is broken: expected one create_room; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-last-game-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: _idOf(createMessages.single),
      data: _roomJson(
        state: 'PLAYING',
        gameId: gameId,
        seats:
            seats ??
            <Map<String, Object?>>[
              _seatJson(0, name: 'Sam'),
              _seatJson(1, name: 'Bob'),
            ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    factory.controllers.single.room!.state,
    RoomState.playing,
    reason: 'fixture is broken: the create_room reply must land PLAYING',
  );
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason:
        'fixture is broken: a PLAYING room must latch RoomRoute onto '
        'GameScreen',
  );
  return factory;
}

Future<void> _pushGameOver(
  WidgetTester tester,
  FakeTransport transport, {
  required int winner,
  required Object? verifyUrl,
  required int seq,
}) async {
  final Map<String, Object?> data = <String, Object?>{
    'winner': winner,
    'seq': seq,
  };
  if (verifyUrl != null) {
    data['verify_url'] = verifyUrl;
  }
  transport.pushText(_frame(type: 'game_over', data: data));
  await tester.pump();
  await tester.pump();
}

Future<void> _pushRoom(
  WidgetTester tester,
  FakeTransport transport,
  Map<String, Object?> room,
) async {
  transport.pushText(_frame(type: 'room', data: room));
  await tester.pump();
  await tester.pump();
}

/// Taps game-screen-appbar-leave, lets the pop settle, then answers the
/// leave_room request it fires so leave() resolves and no 10s timer is left
/// pending at tear-down.
Future<void> _leaveBackToHome(
  WidgetTester tester,
  List<FakeTransport> transports,
) async {
  await tester.tap(find.byKey(_appbarLeaveKey));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  expect(
    find.byType(GameScreen),
    findsNothing,
    reason: 'fixture is broken: leaving a finished game must pop GameScreen',
  );
  _answerOpenLeaveRooms(transports);
  await tester.pump();
  await _flushOutstandingRequestTimeout(tester);
}

Future<LastGame?> _loadLastGame() async =>
    (await SessionMemory.load()).lastGame;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('rule 2: written the moment a finished game is observed', () {
    for (final int winnerSeat in <int>[0, 1]) {
      final bool thisSeatWon = winnerSeat == 0;
      testWidgets(
        'create into a game that reaches FINISHED with game_over carrying '
        'verify_url, this seat ${thisSeatWon ? "wins" : "loses"}: storage '
        'holds the game id, url and won=$thisSeatWon before the leave tap, '
        'and home-last-game shows once the route pops',
        (tester) async {
          const String gameId = 'g-rule2-win-lose';
          const String verifyUrl = 'https://provefair.app/v/g-rule2-win-lose';
          final _RecordingControllerFactory factory =
              await _createPlayingFromHome(tester, gameId: gameId);
          final FakeTransport transport = factory.transports.single;

          await _pushGameOver(
            tester,
            transport,
            winner: winnerSeat,
            verifyUrl: verifyUrl,
            seq: 2,
          );
          expect(
            factory.controllers.single.room!.state,
            RoomState.finished,
            reason: 'fixture is broken: game_over must finish the room',
          );

          // Mutation this catches: writing LastGame from
          // _retireOwnedController (the leave path) instead of from
          // _onOwnedControllerChanged (the observation path) -- this check
          // runs before the leave tap below, while GameScreen is still the
          // mounted route, so a leave-triggered write would still read
          // null here.
          final LastGame? beforeLeave = await _loadLastGame();
          expect(
            beforeLeave,
            isNotNull,
            reason:
                'LastGame must already be in storage the moment the '
                'finished snapshot is observed, before the player ever '
                'taps leave',
          );
          expect(beforeLeave!.gameId, gameId);
          expect(beforeLeave.verifyUrl, verifyUrl);
          // Mutation this catches: won computed from the host seat or
          // from room.winner's seat 0 literally, instead of comparing
          // against this controller's own seat.
          expect(
            beforeLeave.won,
            thisSeatWon,
            reason:
                'won must be winner($winnerSeat) == this seat (0); got '
                '${beforeLeave.won}',
          );

          await _leaveBackToHome(tester, factory.transports);

          final Finder entry = find.byKey(_homeLastGameKey);
          expect(
            entry,
            findsOneWidget,
            reason:
                'home-last-game must be shown as soon as the route pops '
                'back to Home, without a fresh load triggered by the pop',
          );

          final LastGame? afterLeave = await _loadLastGame();
          expect(
            afterLeave,
            beforeLeave,
            reason: 'leaving must not rewrite the record',
          );
        },
      );
    }

    testWidgets('a game_over whose verify_url is ftp:// writes nothing', (
      tester,
    ) async {
      const String gameId = 'g-rule2-ftp';
      final _RecordingControllerFactory factory = await _createPlayingFromHome(
        tester,
        gameId: gameId,
      );
      final FakeTransport transport = factory.transports.single;

      await _pushGameOver(
        tester,
        transport,
        winner: 0,
        verifyUrl: 'ftp://provefair.app/v/g-rule2-ftp',
        seq: 2,
      );
      expect(
        factory.controllers.single.room!.state,
        RoomState.finished,
        reason:
            'fixture is broken: the frame is well-formed on the wire '
            'even though the scheme fails HomeScreen\'s own gate',
      );

      // Mutation this catches: the write gate checking only that
      // verifyUrl is non-empty, never its scheme, which would write an
      // ftp:// link url_launcher's externalApplication mode was never
      // meant to open from Home.
      final LastGame? stored = await _loadLastGame();
      expect(
        stored,
        isNull,
        reason: 'an ftp:// verify_url must never be written; got $stored',
      );

      await _leaveBackToHome(tester, factory.transports);
      expect(
        find.byKey(_homeLastGameKey),
        findsNothing,
        reason: 'with nothing written, home-last-game must not show',
      );
    });

    testWidgets('a game_over whose verify_url is empty writes nothing', (
      tester,
    ) async {
      const String gameId = 'g-rule2-empty';
      final _RecordingControllerFactory factory = await _createPlayingFromHome(
        tester,
        gameId: gameId,
      );
      final FakeTransport transport = factory.transports.single;

      await _pushGameOver(tester, transport, winner: 0, verifyUrl: '', seq: 2);
      expect(
        factory.controllers.single.room!.state,
        RoomState.finished,
        reason:
            'fixture is broken: an empty string is still a well-formed '
            'verify_url on the wire',
      );

      // Mutation this catches: the write gate treating an empty string
      // the same as a present URL because it only checks `!= null`.
      final LastGame? stored = await _loadLastGame();
      expect(
        stored,
        isNull,
        reason: 'an empty verify_url must never be written; got $stored',
      );

      await _leaveBackToHome(tester, factory.transports);
      expect(find.byKey(_homeLastGameKey), findsNothing);
    });
  });

  group('rule 2: a rematch overwrites the stored game', () {
    testWidgets('the first game finishes, a rematch starts and finishes with a '
        'different game id: storage holds the second game, not the first', (
      tester,
    ) async {
      const String gameIdA = 'g-rematch-a';
      const String verifyUrlA = 'https://provefair.app/v/g-rematch-a';
      const String gameIdB = 'g-rematch-b';
      const String verifyUrlB = 'https://provefair.app/v/g-rematch-b';

      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ];
      final _RecordingControllerFactory factory = await _createPlayingFromHome(
        tester,
        gameId: gameIdA,
        seats: seats,
      );
      final FakeTransport transport = factory.transports.single;

      await _pushGameOver(
        tester,
        transport,
        winner: 0,
        verifyUrl: verifyUrlA,
        seq: 2,
      );
      expect((await _loadLastGame())?.gameId, gameIdA, reason: 'fixture');

      await _pushRoom(
        tester,
        transport,
        _roomJson(
          state: 'LOBBY',
          seats: seats,
          gameId: null,
          rematch: <String, Object?>{
            'by': 0,
            'ready': <int>[0],
          },
          seq: 3,
        ),
      );
      // Mutation this catches: the rematch LOBBY (gameId null, F taken
      // from lastFinished per rule 2) being mistaken for a brand new
      // game and clearing or rewriting the record with nothing, rather
      // than leaving game A's write untouched until B actually finishes.
      expect(
        (await _loadLastGame())?.gameId,
        gameIdA,
        reason: 'a rematch LOBBY alone must not disturb the stored record',
      );

      await _pushRoom(
        tester,
        transport,
        _roomJson(
          state: 'PLAYING',
          seats: seats,
          gameId: gameIdB,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
          seq: 4,
        ),
      );
      await _pushGameOver(
        tester,
        transport,
        winner: 1,
        verifyUrl: verifyUrlB,
        seq: 5,
      );
      expect(
        factory.controllers.single.room!.state,
        RoomState.finished,
        reason: 'fixture is broken: the rematch\'s own game_over must finish',
      );

      // Mutation this catches: the "differs from the last one this
      // screen wrote" check comparing against the LOBBY's gameId (null)
      // instead of against the id this screen actually last wrote (A),
      // which would make this comparison true for the wrong reason, or
      // false forever once any LOBBY with gameId null had been seen.
      final LastGame? stored = await _loadLastGame();
      expect(
        stored?.gameId,
        gameIdB,
        reason:
            'the rematch\'s own finish must overwrite game A with B; '
            'got $stored',
      );
      expect(stored?.verifyUrl, verifyUrlB);
      expect(
        stored?.won,
        false,
        reason:
            'game B: winner is seat 1, this seat is 0, so won must be '
            'false',
      );

      // Game B's game_log fetch is still in flight; leaving drains its
      // request timer the way every other case here ends.
      await _leaveBackToHome(tester, factory.transports);
    });
  });

  group('rule 3/4: the window and the card\'s copy', () {
    final DateTime fixedNow = DateTime.utc(2026, 10, 12, 12, 0, 0);

    Future<void> seedLastGame({
      required Duration finishedAgo,
      String gameId = 'g-window',
      String verifyUrl = 'https://provefair.app/v/g-window',
      bool won = true,
    }) async {
      await SessionMemory.recordLastGame(
        LastGame(
          gameId: gameId,
          verifyUrl: verifyUrl,
          finishedAt: fixedNow.subtract(finishedAgo),
          won: won,
        ),
      );
    }

    for (final Locale locale in <Locale>[
      const Locale('en'),
      const Locale('ar'),
    ]) {
      testWidgets(
        '${locale.languageCode}: finished 89 days ago shows home-last-game '
        'with homeLastGame and endFairCheck, at least 48dp tall',
        (tester) async {
          await seedLastGame(finishedAgo: const Duration(days: 89));
          final _RecordingControllerFactory factory =
              _RecordingControllerFactory();
          await tester.pumpWidget(
            _homeScreenApp(factory.call, clock: () => fixedNow, locale: locale),
          );
          await tester.pumpAndSettle();

          final Finder entry = find.byKey(_homeLastGameKey);
          // Mutation this catches: the window check comparing finishedAt
          // alone against 90 days from the wrong reference point (for
          // example DateTime.now() instead of the injected clock), which
          // a real device clock would usually still pass by accident but
          // this fixed fake clock will not.
          expect(
            entry,
            findsOneWidget,
            reason:
                'a game finished 89 days ago, inside the 90-day window, '
                'must show home-last-game',
          );

          final AppLocalizations loc = _locOf(tester);
          final String blob = _blobUnder(tester, entry);
          // Mutation this catches: the card painting a hardcoded English
          // literal instead of AppLocalizations.homeLastGame, which would
          // read identically in both locales instead of switching with
          // loc.homeLastGame.
          expect(
            blob.contains(loc.homeLastGame),
            isTrue,
            reason:
                '${locale.languageCode}: home-last-game must read '
                'homeLastGame == "${loc.homeLastGame}"; blob was "$blob"',
          );
          expect(
            blob.contains(loc.endFairCheck),
            isTrue,
            reason:
                '${locale.languageCode}: the tap target must be labelled '
                'endFairCheck == "${loc.endFairCheck}"; blob was "$blob"',
          );

          final Finder check = find.byKey(_homeLastGameCheckKey);
          expect(
            check,
            findsOneWidget,
            reason: 'home-last-game-check must exist inside home-last-game',
          );
          final Size size = tester.getSize(check);
          // Mutation this catches: a tap target under 48 logical pixels
          // tall (for example a bare Text wrapped directly in a
          // GestureDetector with no minimum-size constraint), measured
          // here from the actual render size rather than trusted from a
          // declared constant.
          expect(
            size.height,
            greaterThanOrEqualTo(48.0),
            reason:
                'home-last-game-check must be at least 48dp tall; measured '
                '${size.height}',
          );
        },
      );
    }

    testWidgets('finished 91 days ago: home-last-game is not shown', (
      tester,
    ) async {
      await seedLastGame(finishedAgo: const Duration(days: 91));
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(
        _homeScreenApp(factory.call, clock: () => fixedNow),
      );
      await tester.pumpAndSettle();

      // Mutation this catches: the 90-day window compared with the
      // comparison flipped (showing only entries OLDER than 90 days
      // instead of hiding them), which this case alone would catch even
      // though the companion 89-day case above would still pass it.
      expect(
        find.byKey(_homeLastGameKey),
        findsNothing,
        reason:
            'a game finished 91 days ago, past the 90-day window, must '
            'not show home-last-game',
      );
    });

    testWidgets('no stored LastGame: home-last-game is not shown', (
      tester,
    ) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(
        _homeScreenApp(factory.call, clock: () => fixedNow),
      );
      await tester.pumpAndSettle();

      // Mutation this catches: a default/sentinel LastGame shown when
      // SessionMemory has never recorded one at all.
      expect(
        find.byKey(_homeLastGameKey),
        findsNothing,
        reason: 'with no LastGame ever recorded, home-last-game must not show',
      );
    });
  });

  group('rule 5: the tap only ever talks to url_launcher', () {
    testWidgets(
      'tapping home-last-game-check launches the stored url exactly once '
      'and never builds a RoomController',
      (tester) async {
        const String url = 'https://provefair.app/v/g-tap-launch';
        final DateTime fixedNow = DateTime.utc(2026, 10, 12, 12, 0, 0);
        await SessionMemory.recordLastGame(
          LastGame(
            gameId: 'g-tap-launch',
            verifyUrl: url,
            finishedAt: fixedNow.subtract(const Duration(days: 1)),
            won: true,
          ),
        );
        final _RecordingControllerFactory factory =
            _RecordingControllerFactory();
        await tester.pumpWidget(
          _homeScreenApp(factory.call, clock: () => fixedNow),
        );
        await tester.pumpAndSettle();

        final List<MethodCall> launches = _listenUrlLaunches(tester);
        final Finder check = find.byKey(_homeLastGameCheckKey);
        expect(check, findsOneWidget, reason: 'fixture is broken');
        await tester.ensureVisible(check);
        await tester.tap(check);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Mutation this catches: the tap opening a RoomController/room
        // instead of (or in addition to) the url_launcher channel -- P10's
        // "the proof is reachable only from one screen" broken the other
        // way, by giving the home card a second way to open a table.
        expect(
          _launched(launches, url),
          isTrue,
          reason:
              'tapping home-last-game-check must open $url externally; '
              'calls were $launches',
        );
        expect(
          launches,
          hasLength(1),
          reason:
              'exactly one url_launcher call, not a double-fire; calls '
              'were $launches',
        );
        expect(
          factory.transports,
          isEmpty,
          reason:
              'tapping home-last-game-check must never build a '
              'RoomController or send a frame on any transport; factory '
              'recorded ${factory.transports.length} transport(s)',
        );
      },
    );
  });
}
