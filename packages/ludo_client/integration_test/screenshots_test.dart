// Captures the store-listing PNGs for the Play Console: home in both
// locales, the lobby with a real code and real joined players, and the game
// board mid-game in both locales.
//
// The earlier version of this file drove `RoomScreen`, a pure client-side
// widget that never talked to a server. `RoomScreen` is dead: nothing under
// lib/ imports it any more (home_screen.dart pushes `RoomRoute`, and
// `RoomRoute` builds `LobbyScreen` or `GameScreen`, never `RoomScreen`), so
// half the old listing showed a screen no player could ever open. This file
// walks the route a player actually takes -- HomeScreen -> RoomRoute ->
// LobbyScreen -> RoomRoute (latched) -> GameScreen -- the same route
// test/composed_play_test.dart proves, driven by real taps over a real
// `RoomController` sitting on a real `RoomConnection` sitting on
// `FakeTransport` (test/net/fake_transport.dart, read-only, not edited
// here). `LudoApp` (lib/src/app.dart) has no factory parameter of its own,
// so, exactly as composed_play_test.dart does, HomeScreen is pumped inside
// its own copy of the MaterialApp scaffolding LudoApp assembles (same
// supportedLocales, same localizationsDelegates, same theme), wired to a
// controller factory this file owns instead of the socket-opening default.
//
// Using FakeTransport here is deliberate and it is not a mockup: every
// pixel captured is the real GameScreen and the real LudoBoard rendering a
// real RoomSnapshot that arrived through the client's own decode path
// (RoomSnapshot.fromJson, by way of RoomController._reduce*). The only
// thing standing in for reality is the socket.
//
// LobbyScreen.initState fires createRoom or joinRoom synchronously and the
// screen sits in a connecting state holding a CircularProgressIndicator,
// whose ticker reschedules a frame forever. pumpAndSettle() never returns
// once LobbyScreen has mounted -- a known, repeatedly-paid-for fact in this
// project, not a guess. Every pump after the first tap that can push
// LobbyScreen or GameScreen onto the tree is therefore bounded: either a
// fixed handful of frames (following composed_play_test's own
// _tapAndAwaitPushedRoute), or _pumpUntilFound below, which pumps a capped
// number of fixed-duration frames and throws a message naming what it was
// waiting for if that cap is reached. Nothing in this file calls
// pumpAndSettle() once a tap has been made that could put LobbyScreen or
// GameScreen on screen.
//
// File names carry both the screen and the language, in capture order, so
// the artifact is self-describing without opening every image:
//   01-home-en.png   home screen, English
//   02-home-ar.png   home screen, Arabic
//   03-lobby-en.png  lobby, English, a real server-issued code and the
//                    real players who joined it
//   04-game-en.png   game board mid-game, English
//   05-game-ar.png   game board mid-game, Arabic
//
// Two workflow runs (33183494414, 33185182659) each produced a room-screen
// capture that was not a room screen at all: a silently dropped enterText
// left the code field empty, home_screen.dart's own validation caught it
// and stayed on the home screen with an error message, and nothing
// downstream noticed. Every capture below is preceded by an assertion that
// names the screen (and the code or token count it expects) it is about to
// photograph, specifically so a repeat of that failure throws instead of
// getting photographed and called a success.

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomSnapshot, RoomState;
import 'package:ludo_client/src/server_config.dart';

import '../test/net/fake_transport.dart';

const String _testUrl = 'wss://screenshots-test.invalid/ws';

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'shot-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring test/composed_play_test.dart's own ------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _roomJson({
  required String code,
  String state = 'LOBBY',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
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
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- the one seam this file is allowed to stand in for: server_config.dart's
// --- RoomControllerFactory. Hands out a fresh RoomController wired to a
// --- fresh FakeTransport on every call, remembering both in call order, the
// --- same idiom test/composed_play_test.dart's _RecordingControllerFactory
// --- and test/home_screen_test.dart's _LiveControllerFactory both use.

class _ScreenshotControllerFactory {
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

// --- widget harness. LudoApp (lib/src/app.dart) owns its own locale state
// --- and its own default, socket-opening controllerFactory, and it has no
// --- parameter to substitute either one -- so this rebuilds the same
// --- MaterialApp scaffolding LudoApp assembles (same theme, same
// --- supportedLocales, same localizationsDelegates) with a locale toggle of
// --- this file's own and a controllerFactory this file can substitute,
// --- exactly the way test/composed_play_test.dart's _homeScreenApp does
// --- (minus the toggle, which that file never exercises and this one must).

class _ScreenshotHarness extends StatefulWidget {
  const _ScreenshotHarness({required this.controllerFactory});

  final RoomControllerFactory controllerFactory;

  @override
  State<_ScreenshotHarness> createState() => _ScreenshotHarnessState();
}

class _ScreenshotHarnessState extends State<_ScreenshotHarness> {
  Locale _locale = const Locale('en');

  void _toggleLocale() {
    setState(() {
      _locale = _locale.languageCode == 'en'
          ? const Locale('ar')
          : const Locale('en');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(),
      locale: _locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(
        onToggleLocale: _toggleLocale,
        controllerFactory: widget.controllerFactory,
      ),
    );
  }
}

/// Answers the `integration_test` plugin's own method channel
/// (`plugins.flutter.io/integration_test`, the same channel
/// `IntegrationTestWidgetsFlutterBinding.takeScreenshot` calls) with an
/// empty byte list for every `captureScreenshot` call -- but only when there
/// is genuinely no plugin behind that channel to begin with.
///
/// Under `flutter drive` on a device, this channel is answered by the
/// plugin's native Android/iOS side, which is what actually turns a
/// captured frame into PNG bytes. Under plain `flutter test`, run headless
/// with no device and no native plugin behind it, nothing answers this
/// channel at all, and an unanswered platform channel call throws
/// `MissingPluginException`, not the silent no-op the file header describes
/// -- that description holds for `convertFlutterSurfaceToImage`, which
/// short-circuits before ever reaching a channel when `Platform.isAndroid`
/// is false, but not for `takeScreenshot`, which always calls the channel
/// regardless of platform. Stubbing the answer here is what makes this
/// file's own claim true: with this in place, `takeScreenshot` really is
/// inert under `flutter test`, and the run exercises every finder, every
/// tap and every assertion around it without ever producing a real image.
///
/// `setMockMethodCallHandler` does not know or care whether a device is
/// listening on the other end: once a handler is registered for a channel,
/// `TestDefaultBinaryMessenger.send` calls that handler and never reaches
/// `delegate.send`, the path to the real platform plugin
/// (flutter_test/lib/src/test_default_binary_messenger.dart:141-150, this
/// project's installed copy). So a handler registered unconditionally here
/// would answer `captureScreenshot` on a real emulator too, and every
/// screenshot `flutter drive` captures would come back as the
/// `Uint8List(0)` below instead of the Android plugin's real PNG bytes --
/// the driver adaptor would write five zero-byte files to disk, and the
/// workflow's own "confirm the screenshots exist" step only counts files,
/// so the job would go green while uploading nothing. If this guard is ever
/// deleted, that is exactly what ships to the Play Console listing.
///
/// The guard is `!kIsWeb && Platform.isAndroid`, the same condition
/// `convertFlutterSurfaceToImage` itself branches on in the installed
/// `integration_test` package
/// (toolchains/flutter/packages/integration_test/lib/src/_callback_io.dart:66,
/// `if (!Platform.isAndroid) { return; }` -- true under plain `flutter
/// test` on `flutter-tester`, which is neither web nor Android, so the stub
/// still registers there and this file's headless proof still runs;
/// false is the one case this guard exists for, a real Android device
/// under `flutter drive`, where the stub must never register.
void _stubScreenshotChannel(WidgetTester tester) {
  final bool isRealAndroidDevice = !kIsWeb && Platform.isAndroid;
  // Proof for the record, not decoration: this line is what lets the
  // headless run below show, in its own output, what the guard actually
  // evaluated to on the machine that ran it.
  // ignore: avoid_print
  print(
    'screenshots_test: _stubScreenshotChannel guard '
    '(!kIsWeb && Platform.isAndroid) evaluated to $isRealAndroidDevice '
    'on this run',
  );
  if (isRealAndroidDevice) {
    // Do not touch the channel. A real device is on the other end and the
    // real plugin must answer captureScreenshot itself.
    return;
  }

  const MethodChannel channel = MethodChannel(
    'plugins.flutter.io/integration_test',
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
    MethodCall call,
  ) async {
    if (call.method == 'captureScreenshot') {
      // Must be a Uint8List, not a plain List<int>: the standard method
      // codec decodes a generic list back as List<Object?>, and
      // takeScreenshot's own `as List<int>?` cast rejects that. A typed
      // byte buffer round-trips through the codec as itself.
      return Uint8List(0);
    }
    return null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
}

/// Taps the button at [buttonKey] and pumps just long enough for the pushed
/// MaterialPageRoute's transition to finish and the pushed route's first
/// screen to mount, without ever calling pumpAndSettle. See the file header:
/// LobbyScreen's connecting body holds a CircularProgressIndicator whose
/// ticker never settles, so pumpAndSettle here would hang. 400ms is
/// comfortably past MaterialPageRoute's default 300ms transition, the same
/// value test/composed_play_test.dart already proved sufficient for
/// LobbyScreen.initState's synchronous createRoom/joinRoom call to have put
/// its request on the wire by the time this returns.
Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps fixed, bounded 16ms frames until [finder] finds something, and
/// throws a [TestFailure] naming [description] if it never does within
/// [maxPumps] frames. The bounded replacement for pumpAndSettle everywhere
/// past the point LobbyScreen can be on screen: a screen that never settles
/// must time out with a message that says what it was waiting for, not hang
/// until the CI job is killed.
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder,
  String description, {
  int maxPumps = 200,
  Duration frame = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(frame);
  }
  throw TestFailure(
    'timed out after $maxPumps pumps of $frame each waiting for: '
    '$description',
  );
}

/// Forces real, wall-clock-duration frames -- not the fake test clock a
/// plain `WidgetTester` runs on -- before a screenshot taken right after a
/// locale toggle.
///
/// `pumpAndSettle()` proves only that the framework has stopped scheduling
/// frames; it says nothing about whether the platform surface
/// `convertFlutterSurfaceToImage()` swapped in has actually received a
/// frame painted after the toggle. Emulator run 34191276162 on `04d59e9`
/// produced `02-home-ar.png` byte-identical to `01-home-en.png` (md5
/// d5faae649370b3fe726107fc482c5df6, `ImageChops.difference(...).getbbox()`
/// -> `None`) even though `_expectHomeScreen(..., localeName: 'ar')`, which
/// reads the widget tree the same way this file's own assertions do, was
/// not at fault: the tree really had flipped to Arabic by the time the
/// screenshot ran. In a profile (AOT) build the widget tree and that
/// platform surface have been observed to fall out of step, and nothing
/// running on Flutter's fake test clock can see or wait on that gap, since
/// the surface lives entirely on the native side of the screenshot channel.
///
/// `main()` below installs `IntegrationTestWidgetsFlutterBinding`, which
/// extends `LiveTestWidgetsFlutterBinding`
/// (toolchains/flutter/packages/integration_test/lib/integration_test.dart:45-46).
/// `LiveTestWidgetsFlutterBinding.pump(duration)` schedules its next frame
/// with a real `dart:async` `Timer`
/// (toolchains/flutter/packages/flutter_test/lib/src/binding.dart:3004-3016),
/// not the deterministic fake clock a plain, non-live `WidgetTester` binding
/// advances instantly -- so every one of the pumps below is real elapsed
/// wall time for a platform compositor to actually catch up in, which is
/// the one thing this helper can offer that a wider `pumpAndSettle()`
/// cannot.
///
/// [readyFinder] is a second, independent floor: a finder for text or a
/// widget the new locale alone produces (the caller builds it from the
/// already-toggled `AppLocalizations`, not a hardcoded translated string,
/// so it cannot drift from the ARB files). It does not fix the surface
/// staleness above -- the widget tree is already correct long before the
/// platform surface is, so in the passing case this finder is satisfied on
/// the very first pump below and adds no extra wait -- it exists so that a
/// future regression that made the *widget tree itself* lag behind the
/// toggle would fail here, by name, with the reproduction in the message,
/// instead of silently taking a screenshot of the wrong tree.
Future<void> _settleForScreenshot(
  WidgetTester tester,
  Finder readyFinder,
  String description, {
  int minRealFrames = 30,
  Duration frame = const Duration(milliseconds: 32),
  int maxExtraPumps = 200,
}) async {
  for (var i = 0; i < minRealFrames; i++) {
    await tester.pump(frame);
  }
  var extraPumps = 0;
  while (readyFinder.evaluate().isEmpty) {
    if (extraPumps >= maxExtraPumps) {
      throw TestFailure(
        'after $minRealFrames real-duration pumps of $frame each to settle '
        'the platform surface, plus $maxExtraPumps more real-duration '
        'pumps of the same length waiting for the widget tree itself, '
        'still waiting for: $description',
      );
    }
    await tester.pump(frame);
    extraPumps += 1;
  }
  // Drains anything the loop above scheduled. Safe here and only for this
  // capture: the toggle happens on HomeScreen, before any tap that could
  // put LobbyScreen or GameScreen (and their runaway tickers) on screen --
  // see the file header and _tapAndAwaitPushedRoute's own doc comment for
  // why pumpAndSettle is not safe past that point.
  await tester.pumpAndSettle();
}

/// Asserts the home screen is on screen, in the locale named by
/// [localeName] ('en' or 'ar'), before a home-screen capture is taken.
Future<void> _expectHomeScreen(
  WidgetTester tester, {
  required String localeName,
}) async {
  final homeFinder = find.byType(HomeScreen);
  expect(
    homeFinder,
    findsOneWidget,
    reason:
        'expected the home screen on screen; found something else, or '
        'more than one',
  );

  final loc = AppLocalizations.of(tester.element(homeFinder));
  expect(
    loc.localeName,
    localeName,
    reason:
        'expected the home screen locale to be "$localeName", it was '
        '"${loc.localeName}" -- the locale toggle did not take effect',
  );
}

/// Asserts the lobby screen is on screen, in the locale named by
/// [localeName], showing [code] as its room code and exactly
/// [expectedSeatCount] joined seats, before the lobby capture is taken.
/// Checking the displayed code and seat count (not just the widget type) is
/// what would have caught the home screen being mistaken for a lobby in
/// workflow runs 33183494414 and 33185182659: both stayed on HomeScreen, so
/// a check that stopped at `findsOneWidget` on `LobbyScreen` would never
/// have run in the first place, but a build that somehow reached
/// LobbyScreen without carrying the server's own code and seats through (a
/// regression this test cannot rule out any other way) would still be
/// caught here.
Future<void> _expectLobbyScreen(
  WidgetTester tester, {
  required String localeName,
  required String code,
  required int expectedSeatCount,
}) async {
  final lobbyFinder = find.byType(LobbyScreen);
  expect(
    lobbyFinder,
    findsOneWidget,
    reason:
        'expected the lobby screen on screen; found something else, or '
        'more than one. If the create/join silently failed, this is where '
        'it first becomes visible: home_screen.dart never navigates on '
        'invalid input, so the app would still be on HomeScreen here',
  );

  final loc = AppLocalizations.of(tester.element(lobbyFinder));
  expect(
    loc.localeName,
    localeName,
    reason:
        'expected the lobby screen locale to be "$localeName", it was '
        '"${loc.localeName}"',
  );

  final codeText = tester.widget<Text>(
    find.byKey(const Key('lobby-room-code')),
  );
  expect(
    codeText.data,
    code,
    reason:
        'expected the lobby to show the server\'s own code "$code", it '
        'showed "${codeText.data}"',
  );

  final seatFinders = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('lobby-seat-'),
  );
  expect(
    seatFinders,
    findsNWidgets(expectedSeatCount),
    reason:
        'expected $expectedSeatCount joined seats in the lobby, found '
        '${seatFinders.evaluate().length}',
  );
}

/// Asserts the game screen is on screen, in the locale named by
/// [localeName], showing the board (not the loading spinner and not a
/// finished game), before a game capture is taken.
Future<void> _expectGameScreenMidGame(
  WidgetTester tester, {
  required String localeName,
  required RoomController controller,
}) async {
  final gameFinder = find.byType(GameScreen);
  expect(
    gameFinder,
    findsOneWidget,
    reason:
        'expected the game screen on screen; found something else, or '
        'more than one',
  );

  final loc = AppLocalizations.of(tester.element(gameFinder));
  expect(
    loc.localeName,
    localeName,
    reason:
        'expected the game screen locale to be "$localeName", it was '
        '"${loc.localeName}"',
  );

  expect(
    find.byKey(const Key('game-screen-board')),
    findsOneWidget,
    reason:
        'expected the board on screen; game-screen-board is absent when '
        'room is null, finished-with-under-2-seats, or not yet playing '
        '(game_screen.dart), none of which this fixture should have '
        'produced',
  );

  final RoomSnapshot room = controller.room!;
  expect(
    room.state,
    RoomState.playing,
    reason:
        'fixture is broken: the room must still be RoomState.playing for '
        'this capture, got ${room.state}',
  );

  final int tokensOutOfYard = room.seats
      .expand((seat) => seat.tokens)
      .where((position) => position != -1)
      .length;
  expect(
    tokensOutOfYard,
    greaterThanOrEqualTo(5),
    reason:
        'a store screenshot of an opening-position board sells nothing: '
        'expected at least 5 tokens out of their yards (progress != -1) '
        'across all seats, this fixture\'s own controller.room reports '
        '$tokensOutOfYard. This is read from the same RoomController '
        'GameScreen renders from, not asserted on a hand-built snapshot',
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ==========================================================================
  // 01, 02, 03, 04: home in both locales (with a working locale toggle,
  // proved by tapping it twice), the lobby, and the game board mid-game, all
  // walked as one continuous HomeScreen -> RoomRoute -> LobbyScreen ->
  // RoomRoute (latched) -> GameScreen route in English.
  // ==========================================================================
  testWidgets('capture 01-home-en, 02-home-ar, 03-lobby-en and 04-game-en', (
    tester,
  ) async {
    // Without this, text typed by tester.enterText below never reaches the
    // field under IntegrationTestWidgetsFlutterBinding on a real device
    // running under `flutter drive --profile`, and a capture that should
    // show a real code or a real name instead silently photographs a
    // validation error. Short version of a longer argument: `flutter
    // drive --profile` builds without --enable-asserts, and the
    // framework's own "-1 always matches" escape hatch for an
    // IntegrationTestWidgetsFlutterBinding without a registered
    // TestTextInput is wrapped in an assert body that therefore never
    // runs, so an unregistered fake drops every enterText call. Calling
    // register() here, before anything taps a field, installs the fake
    // unconditionally and sidesteps all of that.
    binding.testTextInput.register();

    // See _stubScreenshotChannel's own doc comment: without this,
    // takeScreenshot below throws MissingPluginException under plain
    // `flutter test`, which has no device and no native plugin behind this
    // channel.
    _stubScreenshotChannel(tester);

    // Android only, and a no-op everywhere else: swaps the Flutter surface
    // for an image view so the screenshot below captures pixels the
    // platform's normal surface compositing would otherwise miss.
    await binding.convertFlutterSurfaceToImage();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    // Safe here and only here: nothing has tapped Create Room or Join Room
    // yet, so LobbyScreen has not mounted and there is no runaway ticker
    // for pumpAndSettle to chase.
    await tester.pumpAndSettle();

    await _expectHomeScreen(tester, localeName: 'en');
    await binding.takeScreenshot('01-home-en');

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    // The toggle above is followed immediately by a screenshot, with
    // nothing else to naturally give a native platform compositor more
    // real time -- exactly the shape emulator run 34191276162 caught. See
    // _settleForScreenshot's own doc comment for the measurement and why a
    // wider pumpAndSettle() alone cannot see or fix that gap.
    final AppLocalizations arHomeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    await _settleForScreenshot(
      tester,
      find.text(arHomeLoc.homeCreateRoomButton),
      'the Arabic Create Room button label ("${arHomeLoc.homeCreateRoomButton}") '
      'laid out on the home screen after the locale toggle',
    );
    await _expectHomeScreen(tester, localeName: 'ar');
    await binding.takeScreenshot('02-home-ar');

    // Back to English: 03-lobby-en and 04-game-en are both English
    // captures, and this is still the home screen, so pumpAndSettle is
    // still safe here.
    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    const String hostName = 'Priya';
    const String roomCode = 'PLAY42';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(
      factory.controllers,
      hasLength(1),
      reason:
          'tapping Create Room must build exactly one controller through '
          'the injected controllerFactory (home_screen.dart)',
    );
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(
      createMessages,
      hasLength(1),
      reason:
          'expected LobbyScreen.initState, reached through RoomRoute, to '
          'have sent exactly one create_room request; sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String createId = _idOf(createMessages.single);

    // Players = 3: host plus two joiners, so "the joined players" the
    // order asks the lobby capture to show is plural without a long chain
    // of joins.
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-host'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 3,
          hostSeat: 0,
          seats: <Map<String, Object?>>[_seatJson(0, name: hostName)],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(LobbyScreen),
      'LobbyScreen after the create_room reply carrying code "$roomCode"',
    );

    transport.pushText(
      _frame(
        type: 'player_joined',
        data: <String, Object?>{'seat': 1, 'name': 'Karim', 'seq': 2},
      ),
    );
    await tester.pump();
    transport.pushText(
      _frame(
        type: 'player_joined',
        data: <String, Object?>{'seat': 2, 'name': 'Lina', 'seq': 3},
      ),
    );
    await tester.pump();

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 3,
    );
    await binding.takeScreenshot('03-lobby-en');

    final Finder startButton = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton,
      findsOneWidget,
      reason: 'the host, seat 0, must see a Start button once seated',
    );
    final ElevatedButton startWidget = tester.widget<ElevatedButton>(
      startButton,
    );
    expect(
      startWidget.onPressed,
      isNotNull,
      reason:
          'the room is full (3 of 3 seats joined) so Start must be '
          'enabled for the host',
    );

    await tester.tap(startButton);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(
      startMessages,
      hasLength(1),
      reason: 'tapping lobby-start-button must send exactly one start_game',
    );
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'e' * 16,
          'client_seeds': '0:seed',
          'seq': 4,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(GameScreen),
      'GameScreen after the game_started push answering start_game',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason: 'RoomRoute must latch onto GameScreen and never go back',
    );

    // Push several `moved` pushes -- real, server-shaped frames decoded
    // through RoomController's own path -- so the board this test
    // captures shows tokens spread around the track instead of the
    // opening position. Each of these is a bare push (`re` null), exactly
    // as the server sends a move made by any seat, not only this client's
    // own.
    int seq = 4;
    void pushMoved({
      required int seat,
      required int token,
      required int from,
      required int to,
    }) {
      seq += 1;
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': seat,
            'token': token,
            'from': from,
            'to': to,
            'captured': <Object?>[],
            'extra_roll': false,
            'seq': seq,
          },
        ),
      );
    }

    pushMoved(seat: 0, token: 0, from: -1, to: 6);
    await tester.pump();
    pushMoved(seat: 0, token: 1, from: -1, to: 19);
    await tester.pump();
    pushMoved(seat: 1, token: 0, from: -1, to: 12);
    await tester.pump();
    pushMoved(seat: 2, token: 0, from: -1, to: 30);
    await tester.pump();
    pushMoved(seat: 1, token: 1, from: -1, to: 45);
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byKey(const Key('game-screen-board')),
      'the game board after the mid-game moved pushes',
    );

    await _expectGameScreenMidGame(
      tester,
      localeName: 'en',
      controller: controller,
    );
    await binding.takeScreenshot('04-game-en');
  });

  // ==========================================================================
  // 05: the game board mid-game, in Arabic. A second, independent flow --
  // joining rather than creating, and never tapping Start, mirroring
  // test/composed_play_test.dart's C3 case where an unprompted game_started
  // push (the host starting the game) moves a non-host straight from
  // LobbyScreen to GameScreen with no tap at all -- so the widget tree from
  // the first test's Navigator and controller lifecycle never has to be
  // unwound mid-test.
  // ==========================================================================
  testWidgets('capture 05-game-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    const String joinerName = 'Dee';
    const String roomCode = 'SH2T5R';

    await tester.enterText(
      find.byKey(const Key('home-name-field')),
      joinerName,
    );
    await tester.enterText(find.byKey(const Key('room-code-field')), roomCode);
    await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> joinMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'join_room')
        .toList();
    expect(
      joinMessages,
      hasLength(1),
      reason:
          'expected LobbyScreen.initState, reached through RoomRoute, to '
          'have sent exactly one join_room request; sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String joinId = _idOf(joinMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 1, 'seat_token': 'tok-shot-joiner'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: joinId,
        data: _roomJson(
          code: roomCode,
          players: 2,
          hostSeat: 0,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: joinerName),
          ],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(LobbyScreen),
      'LobbyScreen after the join_room reply carrying code "$roomCode"',
    );

    // The host starts the game; this client never taps anything, exactly
    // like composed_play_test's C3 case for a non-host player.
    transport.pushText(
      _frame(
        type: 'game_started',
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'f' * 16,
          'client_seeds': '0:seed',
          'seq': 2,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(GameScreen),
      'GameScreen after the unprompted game_started push',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason: 'RoomRoute must latch onto GameScreen and never go back',
    );

    int seq = 2;
    void pushMoved({
      required int seat,
      required int token,
      required int from,
      required int to,
    }) {
      seq += 1;
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': seat,
            'token': token,
            'from': from,
            'to': to,
            'captured': <Object?>[],
            'extra_roll': false,
            'seq': seq,
          },
        ),
      );
    }

    pushMoved(seat: 0, token: 0, from: -1, to: 8);
    await tester.pump();
    pushMoved(seat: 0, token: 1, from: -1, to: 23);
    await tester.pump();
    pushMoved(seat: 1, token: 0, from: -1, to: 15);
    await tester.pump();
    pushMoved(seat: 1, token: 1, from: -1, to: 40);
    await tester.pump();
    pushMoved(seat: 0, token: 2, from: -1, to: 3);
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byKey(const Key('game-screen-board')),
      'the game board after the mid-game moved pushes',
    );

    await _expectGameScreenMidGame(
      tester,
      localeName: 'ar',
      controller: controller,
    );
    await binding.takeScreenshot('05-game-ar');
  });
}
