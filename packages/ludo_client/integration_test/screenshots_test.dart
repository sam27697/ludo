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
import 'package:ludo_client/src/net/snapshot.dart'
    show RoomSnapshot, RoomState, SeatState;
import 'package:ludo_client/src/room_code.dart'
    show isValidRoomCode, normalizeRoomCode;
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart'
    show SeatRecord, SessionMemory;
import 'package:shared_preferences/shared_preferences.dart';

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

/// Order 181's settle for captures 10 and 11: [frameCount] real-duration
/// pumps of [frame] each, and nothing else -- no readiness finder, no
/// pumpAndSettle. Both captures photograph a screen `LobbyScreen` or
/// `GameScreen` has already mounted, each holding a ticker that runs
/// forever once mounted (file header), so, unlike _settleForScreenshot
/// above, this helper cannot end in a pumpAndSettle() without hanging.
///
/// The same real-time gap _settleForScreenshot's own doc comment describes
/// between the widget tree and the platform surface applies here: this is
/// the bounded, ticker-safe way to hold the frame open for the compositor
/// before `takeScreenshot`, real wall time under
/// `LiveTestWidgetsFlutterBinding.pump(duration)`, not the instantly
/// advanced fake clock a plain `WidgetTester` runs on.
///
/// The default 30 pumps of 32ms matches _settleForScreenshot's own
/// `minRealFrames`/`frame` defaults. Callers of this helper must first have
/// raised the fixture's `autoReconnectDelays` far past that wall-clock
/// length: a short delay (the 1s/2s pair captures 10 and 11 use for their
/// own fixture assertions) can fire its first automatic attempt during
/// this wait, which dials `connect` again and moves the screen off the
/// very state being held open for the capture.
Future<void> _pumpRealDurationFrames(
  WidgetTester tester, {
  int frameCount = 30,
  Duration frame = const Duration(milliseconds: 32),
}) async {
  for (var i = 0; i < frameCount; i++) {
    await tester.pump(frame);
  }
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

    // This is the first capture of the whole run, taken right after
    // convertFlutterSurfaceToImage() has swapped the surface -- the
    // coldest moment of the run, and exactly the shape
    // _settleForScreenshot's own doc comment describes. The pumpAndSettle
    // above only proves the framework stopped scheduling frames; it says
    // nothing about whether the platform surface has actually received a
    // painted frame, which is what left this capture blank before.
    final AppLocalizations enHomeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    await _settleForScreenshot(
      tester,
      find.text(enHomeLoc.homeCreateRoomButton),
      'the English Create Room button label '
      '("${enHomeLoc.homeCreateRoomButton}") laid out on the home screen '
      'before the first capture',
    );
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
    // Audited against the same "no bare pumpAndSettle proves pixels"
    // question 01-home-en failed: _pumpUntilFound above already waited on
    // find.byType(LobbyScreen) by name, and _expectLobbyScreen just above
    // reads the room code and counts the joined seats straight off the
    // mounted tree. That was treated as proof enough for the screenshot
    // below; it was not. CI runs 36180008997 (run 56) and 36220278224 (run
    // 57) both produced 03-lobby-en.png showing only Priya's seat and
    // "Waiting for players (1 of 3)" even though the tree above was
    // already right -- the platform surface was a frame behind it (see
    // _pumpRealDurationFrames's own doc comment). _settleForScreenshot
    // itself is still not used here: its last line is an unconditional
    // pumpAndSettle() (see its own doc comment, "Safe here and only for
    // this capture"), and by this point LobbyScreen has mounted the
    // connecting-state ticker the file header describes, which that
    // pumpAndSettle would chase forever. Hold the frame open for real wall
    // time instead, then re-read everything the capture depends on
    // immediately before takeScreenshot, so the assertions describe the
    // frame actually photographed.
    await _pumpRealDurationFrames(tester);

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 3,
    );
    final AppLocalizations settledLobbyLoc = AppLocalizations.of(
      tester.element(find.byType(LobbyScreen)),
    );
    final Finder settledStartButton = find.byKey(
      const Key('lobby-start-button'),
    );
    expect(
      settledStartButton,
      findsOneWidget,
      reason:
          'capture 03: after the post-join settle, expected the host\'s '
          'Start button still on screen immediately before the capture',
    );
    final ElevatedButton settledStartWidget = tester.widget<ElevatedButton>(
      settledStartButton,
    );
    final Text settledStartLabel = settledStartWidget.child! as Text;
    expect(
      settledStartLabel.data,
      settledLobbyLoc.lobbyStartButton,
      reason:
          'capture 03: after the post-join settle, the room is full (3 of '
          '3 seats joined) so expected lobby-start-button\'s label to '
          'still read loc.lobbyStartButton '
          '("${settledLobbyLoc.lobbyStartButton}"), got '
          '"${settledStartLabel.data}"',
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

    // Same audit as 03-lobby-en above: no bare pumpAndSettle gates this
    // capture. _pumpUntilFound waited on find.byKey('game-screen-board') by
    // name, and _expectGameScreenMidGame just above reads
    // controller.room.state and the actual token positions off the same
    // RoomController GameScreen renders from. _settleForScreenshot is not
    // used here for the same reason it is not used for 03-lobby-en: its
    // trailing pumpAndSettle() would chase GameScreen's own ticker forever
    // once GameScreen has mounted.
    await _expectGameScreenMidGame(
      tester,
      localeName: 'en',
      controller: controller,
    );
    await binding.takeScreenshot('04-game-en');

    // ==========================================================================
    // 06: continuing this same room and this same controller (per the
    // order: "continue it, do not restart it"). The local seat here is 0
    // (Priya, the host who created this room above); the turn hands to
    // seat 1 (Karim), and seat 1's socket then drops, so the offline line
    // renders next to the turn banner it explains, in English.
    //
    // seq stands at 9 here (game_started pushed seq 4, then five pushMoved
    // pushes brought it to 9, both above), so the two pushes below carry
    // seq 10 and seq 11 to stay contiguous with RoomController's own gap
    // check (_reduceTurn and _reducePresence, room_controller.dart): a seq
    // that is not exactly room.seq + 1 is silently treated as a resync
    // trigger rather than an applied update, and this capture would fire
    // over a screen that never moved.
    //
    // No bare pumpAndSettle gates this capture, same audit as
    // 03-lobby-en, 04-game-en and 05-game-ar above: GameScreen has already
    // mounted its own countdown ticker, so pumpAndSettle would chase it
    // forever. Each push below is followed by the same two tester.pump()
    // calls this file already uses after its 'room' and 'game_started'
    // pushes, and the state that push produced is asserted directly off
    // controller.room and the mounted tree before the screenshot fires.
    // ==========================================================================
    seq += 1;
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{'seat': 1, 'deadline_ms': 45000, 'seq': seq},
      ),
    );
    await tester.pump();
    await tester.pump();

    seq += 1;
    transport.pushText(
      _frame(
        type: 'presence',
        data: <String, Object?>{'seat': 1, 'connected': false, 'seq': seq},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.turn!.seat,
      1,
      reason:
          'capture 06 pushed a turn frame naming seat 1 (Karim); expected '
          'controller.room!.turn!.seat to read 1 before the capture '
          'fires, got ${controller.room!.turn!.seat}',
    );
    expect(
      controller.room!.seats[1].connected,
      isFalse,
      reason:
          'capture 06 pushed presence {seat: 1, connected: false}; '
          'expected controller.room!.seats[1] (Karim) to read '
          'disconnected before the capture fires, got connected='
          '${controller.room!.seats[1].connected}',
    );

    final Finder offlineFinder06 = find.byKey(
      const Key('game-screen-turn-seat-offline'),
    );
    expect(
      offlineFinder06,
      findsOneWidget,
      reason:
          'expected game-screen-turn-seat-offline in the tree once the '
          'turn is on seat 1 and seat 1 is disconnected '
          '(game_screen.dart _offlineTurnSeat); found something else, or '
          'more than one',
    );

    final AppLocalizations enGameLoc06 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    final String expectedOfflineText06 = enGameLoc06.gameSeatOffline('Karim');
    final Text offlineText06 = tester.widget<Text>(offlineFinder06);
    expect(
      offlineText06.data,
      expectedOfflineText06,
      reason:
          'expected game-screen-turn-seat-offline\'s Text.data to equal '
          'this tree\'s own AppLocalizations.gameSeatOffline("Karim") '
          '("$expectedOfflineText06"), got "${offlineText06.data}"',
    );

    final String expectedBannerText06 = enGameLoc06.gameWaitingForPlayer(
      'Karim',
    );
    final Text bannerText06 = tester.widget<Text>(
      find.byKey(const Key('game-screen-turn-banner')),
    );
    expect(
      bannerText06.data,
      expectedBannerText06,
      reason:
          'expected game-screen-turn-banner to still read the '
          'waiting-for-Karim string ("$expectedBannerText06") alongside '
          'the offline line, so the capture shows the pair a player '
          'actually sees; got "${bannerText06.data}"',
    );

    await binding.takeScreenshot('06-game-offline-en');
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

    // Same audit as 03-lobby-en and 04-game-en above: no bare
    // pumpAndSettle gates this capture, _pumpUntilFound and
    // _expectGameScreenMidGame already verify the named content is on
    // screen, and _settleForScreenshot is not used for the same reason:
    // GameScreen has mounted its ticker by this point and
    // _settleForScreenshot's trailing pumpAndSettle() would chase it
    // forever.
    await _expectGameScreenMidGame(
      tester,
      localeName: 'ar',
      controller: controller,
    );
    await binding.takeScreenshot('05-game-ar');

    // ==========================================================================
    // 07: continuing this same room and this same controller. This is the
    // Arabic value of gameSeatOffline's first time rendering: order 163's
    // verdict named that gap, order 164 closed it in a widget test, and
    // this closes it on the same RTL layout and font shaping the store
    // listing actually ships.
    //
    // This test's own local seat is not assumed here -- read at runtime
    // from controller.seat -- and the seat the turn hands to and then
    // drops is whichever other seat is actually present in
    // controller.room!.seats.
    // ==========================================================================
    final int localSeat07 = controller.seat!;
    final SeatState offlineSeatState07 = controller.room!.seats.firstWhere(
      (SeatState s) => s.seat != localSeat07,
      orElse: () => throw TestFailure(
        'capture 07 needs a seated seat other than the local seat '
        '($localSeat07) in controller.room!.seats to hand the turn to '
        'and disconnect; seats present: '
        '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
      ),
    );
    final int offlineSeat07 = offlineSeatState07.seat;
    final String offlineSeatName07 = offlineSeatState07.name;

    // Read, not assumed, per the order: controller.seat is $localSeat07
    // here (this test's own join_room flow was assigned that seat above,
    // by the server's seat_assigned push), and the seat picked to hand
    // the turn to and disconnect is seat $offlineSeat07
    // ("$offlineSeatName07"), the only entry in controller.room!.seats
    // other than the local seat. Printed once, plainly, so a later
    // reader does not have to re-derive it from the pushes below.
    // ignore: avoid_print
    print(
      'screenshots_test: capture 07 read controller.seat as '
      '$localSeat07 and picked seat $offlineSeat07 '
      '("$offlineSeatName07") -- the only other seated seat in '
      'controller.room!.seats -- to hand the turn to and disconnect',
    );

    // seq stands at 7 here (game_started pushed seq 2, then five
    // pushMoved pushes brought it to 7, both above), so the two pushes
    // below carry seq 8 and seq 9 to stay contiguous with
    // RoomController's own gap check (_reduceTurn and _reducePresence,
    // room_controller.dart), same reasoning as capture 06 above.
    seq += 1;
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': offlineSeat07,
          'deadline_ms': 45000,
          'seq': seq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    seq += 1;
    transport.pushText(
      _frame(
        type: 'presence',
        data: <String, Object?>{
          'seat': offlineSeat07,
          'connected': false,
          'seq': seq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.turn!.seat,
      offlineSeat07,
      reason:
          'capture 07 pushed a turn frame naming seat $offlineSeat07 '
          '("$offlineSeatName07", the seat picked above as the only seat '
          'other than the local seat $localSeat07); expected '
          'controller.room!.turn!.seat to read $offlineSeat07 before the '
          'capture fires, got ${controller.room!.turn!.seat}',
    );
    expect(
      controller.room!.seats[offlineSeat07].connected,
      isFalse,
      reason:
          'capture 07 pushed presence {seat: $offlineSeat07, connected: '
          'false}; expected controller.room!.seats[$offlineSeat07] '
          '("$offlineSeatName07") to read disconnected before the '
          'capture fires, got connected='
          '${controller.room!.seats[offlineSeat07].connected}',
    );

    final Finder offlineFinder07 = find.byKey(
      const Key('game-screen-turn-seat-offline'),
    );
    expect(
      offlineFinder07,
      findsOneWidget,
      reason:
          'expected game-screen-turn-seat-offline in the tree once the '
          'turn is on seat $offlineSeat07 ("$offlineSeatName07") and '
          'that seat is disconnected (game_screen.dart '
          '_offlineTurnSeat); found something else, or more than one',
    );

    final AppLocalizations arGameLoc07 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    final String expectedOfflineText07 = arGameLoc07.gameSeatOffline(
      offlineSeatName07,
    );
    final Text offlineText07 = tester.widget<Text>(offlineFinder07);
    // This is the assertion that proves the Arabic value of
    // gameSeatOffline is what is on the Arabic screen: an equality
    // against the tree's own AppLocalizations lookup, not a contains or
    // a non-empty check.
    expect(
      offlineText07.data,
      expectedOfflineText07,
      reason:
          'expected game-screen-turn-seat-offline\'s Text.data to equal '
          'this tree\'s own AppLocalizations.gameSeatOffline'
          '("$offlineSeatName07") ("$expectedOfflineText07"), got '
          '"${offlineText07.data}"',
    );

    final String expectedBannerText07 = arGameLoc07.gameWaitingForPlayer(
      offlineSeatName07,
    );
    final Text bannerText07 = tester.widget<Text>(
      find.byKey(const Key('game-screen-turn-banner')),
    );
    expect(
      bannerText07.data,
      expectedBannerText07,
      reason:
          'expected game-screen-turn-banner to still read the '
          'waiting-for-$offlineSeatName07 string '
          '("$expectedBannerText07") alongside the offline line, so the '
          'capture shows the pair a player actually sees; got '
          '"${bannerText07.data}"',
    );

    await binding.takeScreenshot('07-game-offline-ar');
  });

  // ==========================================================================
  // 08, 09: order 175's H3 rejoin button, in both locales. Written directly
  // through SessionMemory.recordSeat -- the same store home_screen.dart
  // itself writes to (order 172's S3, order 175's H1) -- rather than
  // reached by driving a create or join flow, because what these two
  // capture is the button a *relaunch* shows: a fresh HomeScreen reading a
  // record that was already on the device when it mounted, not a button
  // this same widget tree happened to write for itself a moment earlier.
  // Order 176: "do not tap the button in the drive" -- neither capture below
  // pushes a route; both stay on HomeScreen throughout.
  // ==========================================================================
  testWidgets('capture 08-home-rejoin-en, 09-home-rejoin-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    const String rejoinCode = 'K7M2QP';
    await SessionMemory.recordSeat(
      const SeatRecord(code: rejoinCode, seat: 0, seatToken: 'tok-shot-rejoin'),
    );

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    // Safe here and only here, same as 01-home-en above: nothing has
    // tapped Create Room, Join Room or home-rejoin-button yet, so no
    // pushed route and no runaway ticker for pumpAndSettle to chase.
    await tester.pumpAndSettle();

    final AppLocalizations enHomeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    final String enRejoinLabel = enHomeLoc.homeRejoinButton(rejoinCode);
    await _settleForScreenshot(
      tester,
      find.text(enRejoinLabel),
      'the English home-rejoin-button label ("$enRejoinLabel") laid out on '
      'the home screen before capture 08, after SessionMemory.recordSeat '
      'wrote a record for code "$rejoinCode"',
    );
    await _expectHomeScreen(tester, localeName: 'en');
    expect(
      find.byKey(const Key('home-rejoin-button')),
      findsOneWidget,
      reason:
          'expected home-rejoin-button on screen before capture 08; a '
          'fresh HomeScreen must read back the seat record '
          '(code "$rejoinCode") SessionMemory.recordSeat wrote before this '
          'harness was ever pumped',
    );
    await binding.takeScreenshot('08-home-rejoin-en');

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    // Same shape as 02-home-ar above: a toggle immediately followed by a
    // screenshot, with nothing else to give a native platform compositor
    // more real time. See _settleForScreenshot's own doc comment.
    final AppLocalizations arHomeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    final String arRejoinLabel = arHomeLoc.homeRejoinButton(rejoinCode);
    await _settleForScreenshot(
      tester,
      find.text(arRejoinLabel),
      'the Arabic home-rejoin-button label ("$arRejoinLabel") laid out on '
      'the home screen after the locale toggle, before capture 09',
    );
    await _expectHomeScreen(tester, localeName: 'ar');
    expect(
      find.byKey(const Key('home-rejoin-button')),
      findsOneWidget,
      reason:
          'expected home-rejoin-button still on screen after the locale '
          'toggle, before capture 09',
    );
    await binding.takeScreenshot('09-home-rejoin-ar');

    await SessionMemory.clearSeat();
  });

  // ==========================================================================
  // 10: order 180's R2 reconnecting line, on GameScreen, in English. Reached
  // by dropping a real transport under a real RoomController mid-game, with a
  // non-empty auto-reconnect schedule so autoReconnectPending reads true the
  // instant the drop lands, the same mechanism
  // test/reconnecting_line_test.dart's R2 case drives against the widget
  // directly. Mounted here through _reconnectingCaptureHarness rather than
  // through HomeScreen -> RoomRoute: unlike 03/04/05 above, this capture is
  // not a step on the route a player taps through, it is a state the app
  // reaches on its own while already on the game screen, so there is no tap
  // sequence for it to be a step of.
  // ==========================================================================
  testWidgets('capture 10-game-reconnecting-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    final FakeTransport transport = FakeTransport();
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
      // Order 181: raised from [1s, 2s] to keep the first automatic
      // reconnect attempt from firing during the real-duration settle
      // below, which runs about a second of wall time (see
      // _pumpRealDurationFrames's own doc comment and the file's capture
      // 10/11 fixtures). Five minutes is far past that.
      autoReconnectDelays: const <Duration>[
        Duration(minutes: 5),
        Duration(minutes: 5),
      ],
    );
    addTearDown(controller.dispose);

    final Future<void> createFuture = controller.createRoom(
      name: 'Priya',
      players: 2,
    );
    await tester.pump();
    await tester.pump();
    final String createId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-10'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: 'SHOT10',
          state: 'PLAYING',
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya'),
            _seatJson(1, name: 'Karim'),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
          seq: 1,
        ),
      ),
    );
    await createFuture;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'capture 10 fixture is broken: the create reply must land '
          'connected before the drop below',
    );

    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        GameScreen(controller: controller),
        locale: const Locale('en'),
      ),
    );
    await tester.pump();

    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();

    expect(
      controller.phase,
      RoomPhase.closed,
      reason:
          'capture 10 fixture is broken: the transport drop must close '
          'the phase before this capture fires',
    );
    expect(
      controller.autoReconnectPending,
      isTrue,
      reason:
          'capture 10 fixture is broken: a non-empty autoReconnectDelays '
          'drop must leave a pending automatic attempt before this capture '
          'fires',
    );

    expect(
      find.byKey(const Key('game-screen-connection-lost')),
      findsOneWidget,
      reason:
          'expected game-screen-connection-lost on screen before capture 10',
    );
    final Finder reconnectingFinder = find.byKey(
      const Key('game-screen-reconnecting'),
    );
    expect(
      reconnectingFinder,
      findsOneWidget,
      reason: 'expected game-screen-reconnecting on screen before capture 10',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    final Text reconnectingText = tester.widget<Text>(reconnectingFinder);
    expect(
      reconnectingText.data,
      loc.lobbyReconnecting,
      reason:
          'expected game-screen-reconnecting\'s text to read this tree\'s '
          'own AppLocalizations.lobbyReconnecting ("${loc.lobbyReconnecting}'
          '") before capture 10, got "${reconnectingText.data}"',
    );

    // Order 181: the assertions above read the tree two bare pump()s after
    // the drop, before the platform compositor has had any real time to
    // catch up (see _pumpRealDurationFrames's own doc comment and the file
    // header). Hold the frame open for real wall time, then re-read
    // everything the capture depends on immediately before takeScreenshot,
    // so the assertions describe the frame actually photographed.
    await _pumpRealDurationFrames(tester);

    expect(
      controller.phase,
      RoomPhase.closed,
      reason:
          'capture 10: after the post-drop settle, expected '
          'controller.phase to still read RoomPhase.closed immediately '
          'before the capture, got ${controller.phase}',
    );
    expect(
      controller.autoReconnectPending,
      isTrue,
      reason:
          'capture 10: after the post-drop settle, expected '
          'controller.autoReconnectPending to still read true immediately '
          'before the capture, got false -- an automatic attempt may have '
          'fired during the wait',
    );
    expect(
      find.byKey(const Key('game-screen-connection-lost')),
      findsOneWidget,
      reason:
          'capture 10: after the post-drop settle, expected '
          'game-screen-connection-lost still on screen immediately before '
          'the capture',
    );
    final Finder settledReconnectingFinder10 = find.byKey(
      const Key('game-screen-reconnecting'),
    );
    expect(
      settledReconnectingFinder10,
      findsOneWidget,
      reason:
          'capture 10: after the post-drop settle, expected '
          'game-screen-reconnecting still on screen immediately before the '
          'capture',
    );
    final Text settledReconnectingText10 = tester.widget<Text>(
      settledReconnectingFinder10,
    );
    expect(
      settledReconnectingText10.data,
      loc.lobbyReconnecting,
      reason:
          'capture 10: after the post-drop settle, expected '
          'game-screen-reconnecting\'s text to still read this tree\'s own '
          'AppLocalizations.lobbyReconnecting ("${loc.lobbyReconnecting}"), '
          'got "${settledReconnectingText10.data}"',
    );
    expect(
      find.byKey(const Key('game-screen-board')),
      findsNothing,
      reason:
          'capture 10: game_screen.dart\'s _connectionLostBody, the body '
          'this phase builds, never constructs game-screen-board -- only '
          '_playingBody and _gameOverBody do -- so expected it absent '
          'immediately before the capture, found it present',
    );

    await binding.takeScreenshot('10-game-reconnecting-en');
  });

  // ==========================================================================
  // 11: order 180's R1 reconnecting line, on LobbyScreen, in Arabic. Reached
  // the same way test/reconnecting_line_test.dart's R1-AR case reaches it: a
  // real host lobby, connected, then dropped, with a non-empty auto-reconnect
  // schedule so lobby-closed shows lobby-reconnecting the instant the drop
  // lands. LobbyScreen is mounted first, on a fresh idle controller, and
  // driven to connected by its own initState request -- the same order
  // test/lobby_screen_test.dart's own suite uses throughout, and the reason
  // is the same here: handing LobbyScreen an already-connected controller
  // would make initState's own create_room request re-fire.
  // ==========================================================================
  testWidgets('capture 11-lobby-reconnecting-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    final FakeTransport transport = FakeTransport();
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
      // Order 181: raised from [1s, 2s] for the same reason as capture 10
      // above -- the real-duration settle below runs about a second of
      // wall time, and a short delay could fire its first automatic
      // attempt inside that wait.
      autoReconnectDelays: const <Duration>[
        Duration(minutes: 5),
        Duration(minutes: 5),
      ],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Dee',
          players: 4,
        ),
        locale: const Locale('ar'),
      ),
    );
    await tester.pump();

    expect(
      transport.sentRaw,
      isNotEmpty,
      reason:
          'capture 11 fixture is broken: LobbyScreen.initState must '
          'have sent create_room by now',
    );
    final String createId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-11'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: 'SHOT11',
          players: 4,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Dee')],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connected,
      reason:
          'capture 11 fixture is broken: the create reply must land '
          'connected before the drop below',
    );

    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();

    expect(
      controller.phase,
      RoomPhase.closed,
      reason:
          'capture 11 fixture is broken: the transport drop must close '
          'the phase before this capture fires',
    );
    expect(
      controller.autoReconnectPending,
      isTrue,
      reason:
          'capture 11 fixture is broken: a non-empty autoReconnectDelays '
          'drop must leave a pending automatic attempt before this capture '
          'fires',
    );

    expect(
      find.byKey(const Key('lobby-closed')),
      findsOneWidget,
      reason: 'expected lobby-closed on screen before capture 11',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(LobbyScreen)),
    );
    expect(
      loc.localeName,
      'ar',
      reason: 'capture 11 fixture is broken: this case must be in Arabic',
    );
    final Finder reconnectingFinder = find.byKey(
      const Key('lobby-reconnecting'),
    );
    expect(
      reconnectingFinder,
      findsOneWidget,
      reason: 'expected lobby-reconnecting on screen before capture 11',
    );
    final Text reconnectingText = tester.widget<Text>(reconnectingFinder);
    expect(
      reconnectingText.data,
      loc.lobbyReconnecting,
      reason:
          'expected lobby-reconnecting\'s text to read this tree\'s own '
          'AppLocalizations.lobbyReconnecting ("${loc.lobbyReconnecting}") '
          'before capture 11, got "${reconnectingText.data}"',
    );

    // Order 181: the assertions above read the tree two bare pump()s after
    // the drop, before the platform compositor has had any real time to
    // catch up (see _pumpRealDurationFrames's own doc comment and the file
    // header). CI run 36098947846 on c9addaa produced
    // 11-lobby-reconnecting-ar.png showing the connected gathering lobby
    // from before the drop even though every one of the assertions above
    // passed. Hold the frame open for real wall time, then re-read
    // everything the capture depends on immediately before takeScreenshot,
    // so the assertions describe the frame actually photographed.
    await _pumpRealDurationFrames(tester);

    expect(
      controller.phase,
      RoomPhase.closed,
      reason:
          'capture 11: after the post-drop settle, expected '
          'controller.phase to still read RoomPhase.closed immediately '
          'before the capture, got ${controller.phase}',
    );
    expect(
      controller.autoReconnectPending,
      isTrue,
      reason:
          'capture 11: after the post-drop settle, expected '
          'controller.autoReconnectPending to still read true immediately '
          'before the capture, got false -- an automatic attempt may have '
          'fired during the wait',
    );
    expect(
      find.byKey(const Key('lobby-closed')),
      findsOneWidget,
      reason:
          'capture 11: after the post-drop settle, expected lobby-closed '
          'still on screen immediately before the capture',
    );
    final Finder settledReconnectingFinder11 = find.byKey(
      const Key('lobby-reconnecting'),
    );
    expect(
      settledReconnectingFinder11,
      findsOneWidget,
      reason:
          'capture 11: after the post-drop settle, expected '
          'lobby-reconnecting still on screen immediately before the '
          'capture',
    );
    final Text settledReconnectingText11 = tester.widget<Text>(
      settledReconnectingFinder11,
    );
    expect(
      settledReconnectingText11.data,
      loc.lobbyReconnecting,
      reason:
          'capture 11: after the post-drop settle, expected '
          'lobby-reconnecting\'s text to still read this tree\'s own '
          'AppLocalizations.lobbyReconnecting ("${loc.lobbyReconnecting}"), '
          'got "${settledReconnectingText11.data}"',
    );
    expect(
      find.byKey(const Key('lobby-room-code')),
      findsNothing,
      reason:
          'capture 11: lobby_screen.dart\'s _closedBody, the body this '
          'phase builds, never constructs lobby-room-code -- only '
          '_connectedBody does -- so expected it absent (the gathering '
          'body must be gone) immediately before the capture, found it '
          'present',
    );
    expect(
      find.byKey(const Key('lobby-copy-code-button')),
      findsNothing,
      reason:
          'capture 11: lobby_screen.dart\'s _closedBody, the body this '
          'phase builds, never constructs lobby-copy-code-button -- only '
          '_connectedBody does -- so expected it absent (the gathering '
          'body must be gone) immediately before the capture, found it '
          'present',
    );

    await binding.takeScreenshot('11-lobby-reconnecting-ar');
  });

  // ==========================================================================
  // 12: a guest, not the host, sitting in a full lobby, in Arabic. Every
  // capture above that shows LobbyScreen shows the host's own view (03, the
  // create side of 05/07's flow through capture 05's join, and 11); nobody
  // has ever pointed a camera at what the other two seats in a full room
  // actually see once they are not the one who can press Start. Reached the
  // way capture 05 reaches a joined LobbyScreen -- HomeScreen's own Join
  // Room button, not a hand-built LobbyScreen -- because the guest-specific
  // body this capture is about (no lobby-start-button, the
  // waiting-for-host line, lobby-leave-button) is _connectedBody's own
  // branch on controller.isHost, and the only way to reach it as a player
  // actually would is a real join_room round trip, not a widget built
  // in-place with an assumed seat.
  //
  // The Arabic locale is handed to the harness directly, the way capture 11
  // hands it to _reconnectingCaptureHarness, rather than reached by tapping
  // locale-toggle-button twice from HomeScreen's own English default the way
  // 01-04's and 05's captures do -- HomeScreen has no parameter for a
  // starting locale of its own, so _reconnectingCaptureHarness's existing
  // `locale` argument is reused unchanged, with HomeScreen standing in for
  // the bare child every other user of that harness (10, 11) has passed it.
  // ==========================================================================
  testWidgets('capture 12-lobby-guest-full-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    // Safe here and only here, same as 01-home-en and 08/09 above: nothing
    // has tapped Join Room yet, so LobbyScreen has not mounted and there is
    // no runaway ticker for pumpAndSettle to chase.
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    const String joinerName = 'Omar';
    // Drawn only from room_code.dart's roomCodeAlphabet ('0', 'O', '1' and
    // 'I' are all excluded): HomeScreen._joinRoom sets homeRoomCodeInvalid
    // and returns before building a controller for any code that fails
    // isValidRoomCode, so a code drawn carelessly here never reaches a
    // controller, let alone the server.
    const String roomCode = 'GST4ZQ';

    expect(
      isValidRoomCode(normalizeRoomCode(roomCode)),
      isTrue,
      reason:
          'capture 12 fixture is broken: "$roomCode" must be a '
          'syntactically valid room code (room_code.dart\'s '
          'roomCodeAlphabet) or HomeScreen._joinRoom (home_screen.dart) '
          'sets homeRoomCodeInvalid and returns before building a '
          'controller, and the tap below never reaches LobbyScreen at all',
    );

    await tester.enterText(
      find.byKey(const Key('home-name-field')),
      joinerName,
    );
    await tester.enterText(find.byKey(const Key('room-code-field')), roomCode);
    await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

    expect(
      factory.controllers,
      hasLength(1),
      reason:
          'tapping Join Room must build exactly one controller through '
          'the injected controllerFactory (home_screen.dart)',
    );
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

    // Seat 1: a guest, not the host at seat 0. host_seat 0 and three seats
    // filled out of three (Karim the host, this joiner, Lina) is what makes
    // the room full and this client the guest capture 12 is about.
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 1, 'seat_token': 'tok-shot-12'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: joinId,
        data: _roomJson(
          code: roomCode,
          players: 3,
          hostSeat: 0,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Karim'),
            _seatJson(1, name: joinerName),
            _seatJson(2, name: 'Lina'),
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

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 3,
    );

    expect(
      controller.isHost,
      isFalse,
      reason:
          'capture 12 fixture is broken: this joiner sits at seat 1 while '
          'the pushed room names seat 0 (Karim) host_seat; expected '
          'controller.isHost to read false, got true',
    );

    expect(
      find.byKey(const Key('lobby-start-button')),
      findsNothing,
      reason:
          'expected no lobby-start-button for a guest: lobby_screen.dart\'s '
          '_connectedBody only builds lobby-start-button when '
          'controller.isHost is true, and capture 12\'s controller.isHost '
          'is false',
    );

    const String expectedWaitingText = 'بانتظار المضيف لبدء اللعبة';
    final Finder waitingFinder = find.byKey(const Key('lobby-waiting'));
    expect(
      waitingFinder,
      findsOneWidget,
      reason:
          'expected lobby-waiting on screen for a guest in a full lobby '
          '(lobby_screen.dart\'s _connectedBody, the !controller.isHost '
          'branch)',
    );
    final Text waitingText = tester.widget<Text>(waitingFinder);
    expect(
      waitingText.data,
      expectedWaitingText,
      reason:
          'expected lobby-waiting\'s Text to read the literal '
          '"$expectedWaitingText" for a guest in a full room (order 189), '
          'got "${waitingText.data}"',
    );

    final Finder leaveFinder = find.byKey(const Key('lobby-leave-button'));
    expect(
      leaveFinder,
      findsOneWidget,
      reason:
          'expected lobby-leave-button on screen for a guest in a full '
          'lobby (order 189: the connected lobby\'s own way out)',
    );
    final Rect leaveRect = tester.getRect(leaveFinder);
    final Size viewSize =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    final bool leaveButtonInsideView =
        leaveRect.left >= 0 &&
        leaveRect.top >= 0 &&
        leaveRect.right <= viewSize.width &&
        leaveRect.bottom <= viewSize.height;
    expect(
      leaveButtonInsideView,
      isTrue,
      reason:
          'expected lobby-leave-button\'s rect $leaveRect to lie entirely '
          'inside the view $viewSize on this device (seat "$joinerName", '
          'room "$roomCode"); this test does not scroll to bring it into '
          'view, so a button below the fold here is a real finding for the '
          'master, not something to work around',
    );

    // Settle the way capture 11 does before its own takeScreenshot:
    // LobbyScreen has already mounted the connecting-state ticker the file
    // header describes, so no pumpAndSettle from here on, only bounded
    // real-duration pumps to give the platform compositor time to catch up
    // (see _pumpRealDurationFrames's own doc comment and the comment above
    // capture 03's takeScreenshot for why a bare pumpAndSettle is not safe
    // past this point).
    await _pumpRealDurationFrames(tester);

    // Capture 11 re-reads everything it depends on immediately before its
    // own takeScreenshot, after this same real-duration settle, because run
    // 36098947846 on c9addaa showed the settle alone can let a stale frame
    // reach the screenshot even though every assertion taken beforehand
    // passed. Re-assert the two things this capture is actually about --
    // the waiting-for-host literal and the leave button's position -- so
    // the frame this photographs is the frame just described, not the one
    // from before the wait.
    final Finder settledWaitingFinder12 = find.byKey(
      const Key('lobby-waiting'),
    );
    expect(
      settledWaitingFinder12,
      findsOneWidget,
      reason:
          'capture 12: after the post-join settle, expected lobby-waiting '
          'still on screen immediately before the capture',
    );
    final Text settledWaitingText12 = tester.widget<Text>(
      settledWaitingFinder12,
    );
    expect(
      settledWaitingText12.data,
      expectedWaitingText,
      reason:
          'capture 12: after the post-join settle, expected '
          'lobby-waiting\'s Text to still read the literal '
          '"$expectedWaitingText" immediately before the capture, got '
          '"${settledWaitingText12.data}"',
    );
    final Finder settledLeaveFinder12 = find.byKey(
      const Key('lobby-leave-button'),
    );
    expect(
      settledLeaveFinder12,
      findsOneWidget,
      reason:
          'capture 12: after the post-join settle, expected '
          'lobby-leave-button still on screen immediately before the '
          'capture',
    );
    final Rect settledLeaveRect12 = tester.getRect(settledLeaveFinder12);
    final bool settledLeaveButtonInsideView12 =
        settledLeaveRect12.left >= 0 &&
        settledLeaveRect12.top >= 0 &&
        settledLeaveRect12.right <= viewSize.width &&
        settledLeaveRect12.bottom <= viewSize.height;
    expect(
      settledLeaveButtonInsideView12,
      isTrue,
      reason:
          'capture 12: after the post-join settle, expected '
          'lobby-leave-button\'s rect $settledLeaveRect12 to still lie '
          'entirely inside the view $viewSize immediately before the '
          'capture (seat "$joinerName", room "$roomCode"); this test does '
          'not scroll to bring it into view, so a button below the fold '
          'here is a real finding for the master, not something to work '
          'around',
    );

    await binding.takeScreenshot('12-lobby-guest-full-ar');
  });

  // ==========================================================================
  // 13, 14: order 207's two screen changes PR #75 shipped that nobody had
  // looked at on a device (standing lesson 28) -- Home's open players
  // disclosure (home-players-disclosure, home-rule-blocks,
  // home-rule-capture-bonus, home_screen.dart around lines 830-900), and the
  // host's "start with N" button in a lobby that is not full
  // (lobby-start-with-present-button, lobby-rule-blocks,
  // lobby-rule-capture-bonus, lobby_screen.dart around lines 395-452).
  // Captures 01 and 02 show the disclosure closed; capture 03 is a full
  // room, so lobby-start-with-present-button never appears in any capture
  // before this one. One mount, one flow, Arabic throughout (standing
  // lesson 35): the same route capture 12 walks -- HomeScreen -> RoomRoute
  // -> LobbyScreen -- stopped short of ever tapping Start.
  // ==========================================================================
  testWidgets('capture 13-home-rules-ar, 14-lobby-host-start-with-ar', (
    tester,
  ) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    // Before pumpWidget: every capture ahead of this one in the same suite
    // run shares this app's SharedPreferences store, and captures 01 and 12
    // both write to it (recordSuccessfulCreate's last-table chip,
    // SessionMemory.recordSeat's seat record through
    // home_screen.dart's _onOwnedControllerChanged). Without clearing it
    // here, the fresh HomeScreen this case is about to mount would read
    // back an earlier capture's rejoin button and last-table chip instead
    // of the clean Home the order asks for.
    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    // Mounted exactly the way capture 12 mounts HomeScreen: directly in
    // Arabic through _reconnectingCaptureHarness's own `locale` argument,
    // not by tapping locale-toggle-button twice from HomeScreen's English
    // default the way 01-04's and 05's captures do.
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    // Safe here and only here, same as 01-home-en, 08/09 and 12 above:
    // nothing has tapped Create Room yet, so LobbyScreen has not mounted and
    // there is no runaway ticker for pumpAndSettle to chase.
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    expect(
      find.byKey(const Key('home-rejoin-button')),
      findsNothing,
      reason:
          'capture 13: expected no home-rejoin-button on a freshly mounted '
          'HomeScreen after clearing SharedPreferences above; found one, so '
          'a SessionMemory seat record from an earlier capture in this '
          'suite run (written through home_screen.dart\'s '
          '_onOwnedControllerChanged / SessionMemory.recordSeat) survived '
          'the clear',
    );

    const String hostName = 'Huda';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);

    // A player typing on a real keyboard does not leave the text cursor
    // handle showing once done, and this is a store screenshot: take focus
    // off the name field before anything else in this capture happens.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    final Finder nameFieldEditableFinder = find.descendant(
      of: find.byKey(const Key('home-name-field')),
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(nameFieldEditableFinder).focusNode.hasFocus,
      isFalse,
      reason:
          'capture 13: expected home-name-field to have lost focus right '
          'after FocusManager.instance.primaryFocus?.unfocus() above, so no '
          'text cursor handle is painted under it in the screenshot; it '
          'still has focus',
    );
    expect(
      tester.widget<EditableText>(nameFieldEditableFinder).controller.text,
      hostName,
      reason:
          'capture 13: expected home-name-field to still read "$hostName" '
          'right after the unfocus above; the create_room assertions below '
          'depend on the typed name surviving the unfocus',
    );

    // Open the players disclosure: home-players-selector and the two
    // SwitchListTiles mount, both starting on (home_screen.dart's own
    // _rulesBlocks/_rulesCaptureBonus defaults).
    await tester.tap(find.byKey(const Key('home-players-disclosure')));
    await tester.pump();

    // One tap on home-rule-blocks: off. home-rule-capture-bonus is never
    // touched, so it stays on -- one switch in each state on the picture,
    // per the order.
    await tester.tap(find.byKey(const Key('home-rule-blocks')));
    await tester.pump();

    _expectHomeRulesOpen(
      tester,
      blocksExpected: false,
      captureBonusExpected: true,
      momentDescription:
          'immediately after the home-rule-blocks tap, before the '
          'screenshot settle',
    );

    // Home has no LobbyScreen yet (nothing has tapped Create Room), so
    // _settleForScreenshot's own trailing pumpAndSettle() is safe here, the
    // same reasoning 01-home-en and 08/09-home-rejoin rely on above.
    final Finder rulesSettledFinder = find.byWidgetPredicate(
      (Widget widget) =>
          widget is SwitchListTile &&
          widget.key == const Key('home-rule-blocks') &&
          widget.value == false,
    );
    await _settleForScreenshot(
      tester,
      rulesSettledFinder,
      'home-rule-blocks reading off (SwitchListTile.value == false) after '
      'the tap, before capture 13',
    );

    _expectHomeRulesOpen(
      tester,
      blocksExpected: false,
      captureBonusExpected: true,
      momentDescription:
          'after the screenshot settle, immediately before capture 13',
    );

    expect(
      tester.widget<EditableText>(nameFieldEditableFinder).focusNode.hasFocus,
      isFalse,
      reason:
          'capture 13: expected home-name-field to still have no focus '
          'immediately before the screenshot, so no text cursor handle is '
          'painted under it; it has focus again',
    );

    await binding.takeScreenshot('13-home-rules-ar');

    // Order 207 step 4: after the screenshot, so the picture exists either
    // way -- a create-room-button left below the fold with the rules open
    // is a finding for the master, not something this test scrolls around.
    _expectRectInsideView(
      tester,
      find.byKey(const Key('create-room-button')),
      label: 'create-room-button',
      context:
          'with the home rules open (home-rule-blocks off, '
          'home-rule-capture-bonus on)',
    );

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

    // Order 207 step 5: the switch reaching the wire, not only the widget --
    // read straight off the create_room frame this client actually sent
    // (test/net/fake_transport.dart's sentRaw), the same idiom _idOf/_typeOf
    // already read frames with above.
    final Map<String, Object?> createData =
        _decode(createMessages.single)['d']! as Map<String, Object?>;
    final Map<String, Object?> sentRules =
        createData['rules']! as Map<String, Object?>;
    expect(
      sentRules['blocks'],
      isFalse,
      reason:
          'expected the create_room frame\'s rules.blocks to be false '
          'after the home-rule-blocks tap; frame data was $createData',
    );
    expect(
      sentRules['capture_bonus'],
      isTrue,
      reason:
          'expected the create_room frame\'s rules.capture_bonus to still '
          'be true (home-rule-capture-bonus was never tapped); frame data '
          'was $createData',
    );
    expect(
      sentRules.containsKey('turn_seconds'),
      isFalse,
      reason:
          'RoomToggles.toJson (net/connection.dart) never carries '
          'turn_seconds; expected no turn_seconds key inside rules, frame '
          'data was $createData',
    );

    // Order 207 step 6: a room code drawn only from roomCodeAlphabet
    // (room_code.dart) -- the same fixture-broken guard capture 12 uses
    // above, applied here for the same reason: a code that fails
    // isValidRoomCode never reaches a controller at all, and the tap above
    // would already have failed to push LobbyScreen if this were wrong.
    const String roomCode = 'STRTW2';
    expect(
      isValidRoomCode(normalizeRoomCode(roomCode)),
      isTrue,
      reason:
          'capture 13/14 fixture is broken: "$roomCode" must be a '
          'syntactically valid room code (room_code.dart\'s '
          'roomCodeAlphabet)',
    );

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-13'},
      ),
    );
    // _roomJson (above) hardcodes rules and may not be edited, per the
    // order: build its map, then replace the rules entry on the result with
    // the fake server's own answer for this capture -- blocks false,
    // capture_bonus true, turn_seconds 90 -- host_seat 0, players 4, and two
    // seats taken (this host, and Karim at seat 1).
    final Map<String, Object?> roomJson = _roomJson(
      code: roomCode,
      players: 4,
      hostSeat: 0,
      seats: <Map<String, Object?>>[
        _seatJson(0, name: hostName),
        _seatJson(1, name: 'Karim'),
      ],
      seq: 1,
    );
    roomJson['rules'] = <String, Object?>{
      'blocks': false,
      'capture_bonus': true,
      'turn_seconds': 90,
    };
    transport.pushText(_frame(type: 'room', re: createId, data: roomJson));
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(LobbyScreen),
      'LobbyScreen after the create_room reply carrying code "$roomCode"',
    );

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    _expectLobbyHostStartWith(
      tester,
      controller: controller,
      momentDescription:
          'immediately after the room reply, before the screenshot settle',
    );

    // Settle the way capture 12 does before its own takeScreenshot:
    // LobbyScreen has already mounted the connecting-state ticker the file
    // header describes, so no bare pumpAndSettle from here on, only bounded
    // real-duration pumps to give the platform compositor time to catch up.
    await _pumpRealDurationFrames(tester);

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    _expectLobbyHostStartWith(
      tester,
      controller: controller,
      momentDescription:
          'after the post-room-reply settle, immediately before capture 14',
    );

    await binding.takeScreenshot('14-lobby-host-start-with-ar');
  });

  // ==========================================================================
  // 15, 16: order 240's (X14) no-move frame -- my own `rolled` landing with
  // an empty `legal`, with the next seat's `turn` pushed right behind it,
  // unseparated by a pump, because the order's own table says that is the
  // shape the real server sends: both together, not `rolled` alone. PR #87's
  // no-move beat (C-236 rule 4, game_screen.dart's `_armNoMoveHold`) holds
  // `game-die-no-move-mark` and `game-no-move-notice` up for a fixed 1500ms
  // from that `rolled`, independent of whatever the turn banner does
  // underneath it in the meantime (game_die.dart's own doc comment: "the
  // mark is not delayed or hidden by the next seat's turn landing
  // underneath it") -- which is exactly the claim this capture is evidence
  // for. Captured about 300ms in, per the order, deliberately short of the
  // full 1500ms so the picture is of the hold still standing, not of it
  // freshly armed or long gone.
  //
  // Host and joiner: Priya and Karim, the same two names capture 04's own
  // room seats at 0 and 1, reused here and through capture 22 below so the
  // order's "the frames read as one game" holds across the whole new set --
  // see the standing note in this file's own return for why this, and not
  // Sam/Dee from capture 05, was the pair picked. My own seat is always
  // seat 0 (Priya, the host) in every one of 15 through 22, so "my
  // rolled"/"my moved"/"my seat won" in the order's table reads the same
  // way in every one of them.
  // ==========================================================================
  testWidgets('capture 15-game-no-move-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    // Defensive, matching capture 13 above: a fresh HomeScreen here must
    // not read back an earlier capture's rejoin or last-table record.
    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT15';

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

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-15'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton15 = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton15,
      findsOneWidget,
      reason: 'the host, seat 0, must see a Start button once seated',
    );
    await tester.tap(startButton15);
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
          'game_id': 'a' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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

    // My seat (0, Priya) rolls with no legal move; the next seat's turn is
    // pushed right behind it, with no pump in between, matching the
    // order's own "the real server sends both together".
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 5,
          'legal': <int>[],
          'deadline_ms': 41000,
          'k': 1,
          'seq': 4,
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{'seat': 1, 'deadline_ms': 45000, 'seq': 5},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.turn!.seat,
      1,
      reason:
          'capture 15 pushed a turn frame naming seat 1 (Karim) right '
          'after my own no-move rolled; expected '
          'controller.room!.turn!.seat to read 1 immediately after both '
          'frames land, got ${controller.room!.turn!.seat}',
    );

    final AppLocalizations loc15 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectNoMoveVisible(
      tester,
      loc: loc15,
      momentDescription:
          'immediately after the rolled/turn pair landed, before the '
          '~300ms settle',
    );

    // "captured about 300 ms later" (the order's own words): 10 real
    // frames of 32ms each, reusing _pumpRealDurationFrames's own real-time
    // mechanism with a shorter count than its 30-frame default, because
    // this capture is specifically about the hold still standing partway
    // through its 1500ms life, not fresh off the rolled or long after it.
    await _pumpRealDurationFrames(tester, frameCount: 10);

    expect(
      controller.room!.turn!.seat,
      1,
      reason:
          'capture 15: after the ~300ms settle, expected '
          'controller.room!.turn!.seat to still read 1 (Karim) '
          'immediately before the capture, got '
          '${controller.room!.turn!.seat}',
    );
    _expectNoMoveVisible(
      tester,
      loc: loc15,
      momentDescription:
          'after the ~300ms settle, immediately before capture 15',
    );

    await binding.takeScreenshot('15-game-no-move-en');
  });

  // ==========================================================================
  // 16: capture 15's own Arabic twin. Mounted the way captures 12 and 13
  // mount HomeScreen directly in Arabic -- through
  // _reconnectingCaptureHarness's own `locale` argument -- rather than by
  // tapping locale-toggle-button twice from HomeScreen's English default,
  // because there is no locale toggle once GameScreen is on screen, and a
  // second pumpWidget mid-case would break "one mount per case" (lesson in
  // this order's own acceptance list).
  // ==========================================================================
  testWidgets('capture 16-game-no-move-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT16';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
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

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-16'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton16 = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton16,
      findsOneWidget,
      reason: 'the host, seat 0, must see a Start button once seated',
    );
    await tester.tap(startButton16);
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
          'game_id': 'b' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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

    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 5,
          'legal': <int>[],
          'deadline_ms': 41000,
          'k': 1,
          'seq': 4,
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{'seat': 1, 'deadline_ms': 45000, 'seq': 5},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.turn!.seat,
      1,
      reason:
          'capture 16 pushed a turn frame naming seat 1 (Karim) right '
          'after my own no-move rolled; expected '
          'controller.room!.turn!.seat to read 1 immediately after both '
          'frames land, got ${controller.room!.turn!.seat}',
    );

    final AppLocalizations loc16 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc16.localeName,
      'ar',
      reason: 'capture 16 fixture is broken: this case must be in Arabic',
    );
    _expectNoMoveVisible(
      tester,
      loc: loc16,
      momentDescription:
          'immediately after the rolled/turn pair landed, before the '
          '~300ms settle',
    );

    await _pumpRealDurationFrames(tester, frameCount: 10);

    expect(
      controller.room!.turn!.seat,
      1,
      reason:
          'capture 16: after the ~300ms settle, expected '
          'controller.room!.turn!.seat to still read 1 (Karim) '
          'immediately before the capture, got '
          '${controller.room!.turn!.seat}',
    );
    _expectNoMoveVisible(
      tester,
      loc: loc16,
      momentDescription:
          'after the ~300ms settle, immediately before capture 16',
    );

    await binding.takeScreenshot('16-game-no-move-ar');
  });

  // ==========================================================================
  // 17, 18: order 240's (X14) capture frame -- an opponent token sent home
  // by my own `moved`. Karim's token (seat 1) is placed on the board by a
  // scene-setting `moved` first (the same idiom captures 04/05 already use
  // to populate a board before the frame actually under test), then my own
  // roll names that same square legal, and my own `moved` lands on it,
  // naming seat 1's token in `captured`. Asserted, per the order, off
  // controller.room -- the same RoomController GameScreen renders from --
  // not a hand-built snapshot: the captured token reads -1 (back in its
  // yard) there.
  // ==========================================================================
  testWidgets('capture 17-game-capture-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT17';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(createMessages, hasLength(1));
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-17'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton17 = find.byKey(const Key('lobby-start-button'));
    expect(startButton17, findsOneWidget);
    await tester.tap(startButton17);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(startMessages, hasLength(1));
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'c' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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
    expect(find.byType(LobbyScreen), findsNothing);

    // Scene-setting: Karim's token (seat 1, token 0) already sitting on
    // square 10, the same idiom captures 04/05 use to populate a board
    // before the frame under test, not the frame this capture is about.
    transport.pushText(
      _frame(
        type: 'moved',
        data: <String, Object?>{
          'seat': 1,
          'token': 0,
          'from': -1,
          'to': 10,
          'captured': <Object?>[],
          'extra_roll': false,
          'seq': 4,
        },
      ),
    );
    await tester.pump();

    // Proof the scene-setting push above actually left the yard: without
    // this, a captured token reading -1 later would be indistinguishable
    // from one that was never moved out of _seatJson's own -1 default in
    // the first place, and the capture assertion below would pass for the
    // wrong reason.
    expect(
      controller.room!.seats[1].tokens[0],
      10,
      reason:
          'capture 17 fixture is broken: expected Karim\'s token (seat 1, '
          'token 0) to read 10 in controller.room!.seats after the '
          'scene-setting moved landed, got '
          '${controller.room!.seats[1].tokens[0]} -- if this reads -1 the '
          'capture assertion below would prove nothing, since -1 is also '
          'that token\'s starting value',
    );

    // My own roll (seat 0) names token 0 legal.
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 6,
          'legal': <int>[0],
          'deadline_ms': 40000,
          'k': 1,
          'seq': 5,
        },
      ),
    );
    await tester.pump();

    // My own moved (seat 0, token 0) lands on square 10, capturing Karim's
    // token there.
    transport.pushText(
      _frame(
        type: 'moved',
        data: <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': -1,
          'to': 10,
          'captured': <Object?>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
          'extra_roll': false,
          'seq': 6,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byKey(const Key('game-screen-board')),
      'the game board after the capturing moved push',
    );

    expect(
      controller.room!.seats[0].tokens[0],
      10,
      reason:
          'capture 17 fixture is broken: expected my own token (seat 0, '
          'token 0) to read 10 in controller.room!.seats after my own '
          'moved landed, got ${controller.room!.seats[0].tokens[0]}',
    );
    _expectCapturedTokenHome(
      tester,
      controller: controller,
      capturedSeat: 1,
      capturedToken: 0,
      momentDescription:
          'immediately after my own moved landed, before the post-move '
          'settle',
    );

    // Same audit as every mid-game capture above: hold the frame open for
    // real wall time before re-reading everything this capture depends on.
    await _pumpRealDurationFrames(tester);

    expect(
      controller.room!.seats[0].tokens[0],
      10,
      reason:
          'capture 17: after the post-move settle, expected my own token '
          '(seat 0, token 0) to still read 10 immediately before the '
          'capture, got ${controller.room!.seats[0].tokens[0]}',
    );
    _expectCapturedTokenHome(
      tester,
      controller: controller,
      capturedSeat: 1,
      capturedToken: 0,
      momentDescription:
          'after the post-move settle, immediately before capture 17',
    );

    await binding.takeScreenshot('17-game-capture-en');
  });

  // ==========================================================================
  // 18: capture 17's own Arabic twin, mounted directly in Arabic the same
  // way capture 16 is.
  // ==========================================================================
  testWidgets('capture 18-game-capture-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT18';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(createMessages, hasLength(1));
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-18'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton18 = find.byKey(const Key('lobby-start-button'));
    expect(startButton18, findsOneWidget);
    await tester.tap(startButton18);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(startMessages, hasLength(1));
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'd' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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
    expect(find.byType(LobbyScreen), findsNothing);

    transport.pushText(
      _frame(
        type: 'moved',
        data: <String, Object?>{
          'seat': 1,
          'token': 0,
          'from': -1,
          'to': 10,
          'captured': <Object?>[],
          'extra_roll': false,
          'seq': 4,
        },
      ),
    );
    await tester.pump();

    // Proof the scene-setting push above actually left the yard: without
    // this, a captured token reading -1 later would be indistinguishable
    // from one that was never moved out of _seatJson's own -1 default in
    // the first place, and the capture assertion below would pass for the
    // wrong reason.
    expect(
      controller.room!.seats[1].tokens[0],
      10,
      reason:
          'capture 18 fixture is broken: expected Karim\'s token (seat 1, '
          'token 0) to read 10 in controller.room!.seats after the '
          'scene-setting moved landed, got '
          '${controller.room!.seats[1].tokens[0]} -- if this reads -1 the '
          'capture assertion below would prove nothing, since -1 is also '
          'that token\'s starting value',
    );

    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 6,
          'legal': <int>[0],
          'deadline_ms': 40000,
          'k': 1,
          'seq': 5,
        },
      ),
    );
    await tester.pump();

    transport.pushText(
      _frame(
        type: 'moved',
        data: <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': -1,
          'to': 10,
          'captured': <Object?>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
          'extra_roll': false,
          'seq': 6,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byKey(const Key('game-screen-board')),
      'the game board after the capturing moved push',
    );

    final AppLocalizations loc18 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc18.localeName,
      'ar',
      reason: 'capture 18 fixture is broken: this case must be in Arabic',
    );
    _expectCapturedTokenHome(
      tester,
      controller: controller,
      capturedSeat: 1,
      capturedToken: 0,
      momentDescription:
          'immediately after my own moved landed, before the post-move '
          'settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectCapturedTokenHome(
      tester,
      controller: controller,
      capturedSeat: 1,
      capturedToken: 0,
      momentDescription:
          'after the post-move settle, immediately before capture 18',
    );

    await binding.takeScreenshot('18-game-capture-ar');
  });

  // ==========================================================================
  // 19, 20: order 240's (X14) winner's end view -- `game_over` naming my own
  // seat (0, Priya) as `winner`. No `turn` frame follows a `game_over`
  // (docs/PROTOCOL.md section 13's own last line), so this fixture pushes
  // none; the `turn` `game_started` already set is what
  // `room_controller.dart`'s own `_reduceGameOver` carries forward into
  // `TurnPhase.finished`, exactly as sections 14.1/14.2 require.
  // ==========================================================================
  testWidgets('capture 19-end-winner-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT19';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(createMessages, hasLength(1));
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-19'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton19 = find.byKey(const Key('lobby-start-button'));
    expect(startButton19, findsOneWidget);
    await tester.tap(startButton19);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(startMessages, hasLength(1));
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'e' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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
    expect(find.byType(LobbyScreen), findsNothing);

    // My own seat (0, Priya) is named winner.
    transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 0,
          'verify_url': 'https://verify.example.invalid/shot19',
          'seq': 4,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc19 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc19.gameOverYouWin,
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc19.gameOverYouWin,
      momentDescription:
          'after the post-game-over settle, immediately before capture 19',
    );

    await binding.takeScreenshot('19-end-winner-en');
  });

  // ==========================================================================
  // 20: capture 19's own Arabic twin, mounted directly in Arabic the same
  // way capture 16 is.
  // ==========================================================================
  testWidgets('capture 20-end-winner-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT20';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(createMessages, hasLength(1));
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-20'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton20 = find.byKey(const Key('lobby-start-button'));
    expect(startButton20, findsOneWidget);
    await tester.tap(startButton20);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(startMessages, hasLength(1));
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'f' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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
    expect(find.byType(LobbyScreen), findsNothing);

    transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 0,
          'verify_url': 'https://verify.example.invalid/shot20',
          'seq': 4,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc20 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc20.localeName,
      'ar',
      reason: 'capture 20 fixture is broken: this case must be in Arabic',
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc20.gameOverYouWin,
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc20.gameOverYouWin,
      momentDescription:
          'after the post-game-over settle, immediately before capture 20',
    );

    await binding.takeScreenshot('20-end-winner-ar');
  });

  // ==========================================================================
  // 21, 22: order 240's (X14) loser's end view -- `game_over` naming the
  // other seat (1, Karim) as `winner`, so `_winnerText`'s second branch
  // (game_screen.dart) is what this capture is evidence for:
  // `loc.gameOverPlayerWins(seatState.name)`, looked up from this tree's own
  // AppLocalizations and the opponent's own name off controller.room, not
  // hardcoded here.
  // ==========================================================================
  testWidgets('capture 21-end-loser-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT21';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(createMessages, hasLength(1));
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-21'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton21 = find.byKey(const Key('lobby-start-button'));
    expect(startButton21, findsOneWidget);
    await tester.tap(startButton21);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(startMessages, hasLength(1));
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'g' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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
    expect(find.byType(LobbyScreen), findsNothing);

    // The other seat (1, Karim) is named winner.
    transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 1,
          'verify_url': 'https://verify.example.invalid/shot21',
          'seq': 4,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc21 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 1,
      expectedText: loc21.gameOverPlayerWins('Karim'),
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 1,
      expectedText: loc21.gameOverPlayerWins('Karim'),
      momentDescription:
          'after the post-game-over settle, immediately before capture 21',
    );

    await binding.takeScreenshot('21-end-loser-en');
  });

  // ==========================================================================
  // 22: capture 21's own Arabic twin, mounted directly in Arabic the same
  // way capture 16 is.
  // ==========================================================================
  testWidgets('capture 22-end-loser-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    const String hostName = 'Priya';
    const String roomCode = 'SHOT22';

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(createMessages, hasLength(1));
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-22'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 2,
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

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton22 = find.byKey(const Key('lobby-start-button'));
    expect(startButton22, findsOneWidget);
    await tester.tap(startButton22);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(startMessages, hasLength(1));
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'h' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
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
    expect(find.byType(LobbyScreen), findsNothing);

    transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 1,
          'verify_url': 'https://verify.example.invalid/shot22',
          'seq': 4,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc22 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc22.localeName,
      'ar',
      reason: 'capture 22 fixture is broken: this case must be in Arabic',
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 1,
      expectedText: loc22.gameOverPlayerWins('Karim'),
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 1,
      expectedText: loc22.gameOverPlayerWins('Karim'),
      momentDescription:
          'after the post-game-over settle, immediately before capture 22',
    );

    await binding.takeScreenshot('22-end-loser-ar');
  });
}

/// A bare MaterialApp around [child] alone -- the same scaffolding
/// [_ScreenshotHarness] assembles around HomeScreen (same theme, same
/// supportedLocales, same localizationsDelegates), but with no HomeScreen and
/// no locale toggle, for the two captures above that photograph GameScreen
/// and LobbyScreen directly rather than a step reached by tapping through
/// HomeScreen.
Widget _reconnectingCaptureHarness(Widget child, {required Locale locale}) {
  return MaterialApp(
    theme: buildAppTheme(),
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

/// Order 207, capture 13: asserts home-players-selector and the two
/// SwitchListTiles it opens alongside are on screen, that
/// home-rule-blocks.value reads [blocksExpected] and
/// home-rule-capture-bonus.value reads [captureBonusExpected], and that
/// each tile's title reads its own literal straight out of app_ar.arb
/// (homeRuleBlocks, homeRuleCaptureBonus) -- quoted here, not looked up
/// through AppLocalizations, per the order. [momentDescription] names which
/// of the two calls (before or after the screenshot settle) failed, so a
/// failure does not have to be re-run to know which one it was.
void _expectHomeRulesOpen(
  WidgetTester tester, {
  required bool blocksExpected,
  required bool captureBonusExpected,
  required String momentDescription,
}) {
  expect(
    find.byKey(const Key('home-players-selector')),
    findsOneWidget,
    reason:
        'capture 13 ($momentDescription): expected home-players-selector '
        'on screen once the players disclosure is open',
  );

  final Finder blocksFinder = find.byKey(const Key('home-rule-blocks'));
  expect(
    blocksFinder,
    findsOneWidget,
    reason:
        'capture 13 ($momentDescription): expected home-rule-blocks on '
        'screen once the players disclosure is open',
  );
  final SwitchListTile blocksTile = tester.widget<SwitchListTile>(blocksFinder);
  expect(
    blocksTile.value,
    blocksExpected,
    reason:
        'capture 13 ($momentDescription): expected home-rule-blocks\'s '
        'SwitchListTile.value to be $blocksExpected, got '
        '${blocksTile.value}',
  );
  const String expectedBlocksTitle = 'الحواجز';
  final Text blocksTitle = blocksTile.title! as Text;
  expect(
    blocksTitle.data,
    expectedBlocksTitle,
    reason:
        'capture 13 ($momentDescription): expected home-rule-blocks\'s '
        'title to read the app_ar.arb homeRuleBlocks literal '
        '"$expectedBlocksTitle", got "${blocksTitle.data}"',
  );

  final Finder captureBonusFinder = find.byKey(
    const Key('home-rule-capture-bonus'),
  );
  expect(
    captureBonusFinder,
    findsOneWidget,
    reason:
        'capture 13 ($momentDescription): expected '
        'home-rule-capture-bonus on screen once the players disclosure is '
        'open',
  );
  final SwitchListTile captureBonusTile = tester.widget<SwitchListTile>(
    captureBonusFinder,
  );
  expect(
    captureBonusTile.value,
    captureBonusExpected,
    reason:
        'capture 13 ($momentDescription): expected '
        'home-rule-capture-bonus\'s SwitchListTile.value to be '
        '$captureBonusExpected, got ${captureBonusTile.value}',
  );
  const String expectedCaptureBonusTitle = 'مكافأة الأكل';
  final Text captureBonusTitle = captureBonusTile.title! as Text;
  expect(
    captureBonusTitle.data,
    expectedCaptureBonusTitle,
    reason:
        'capture 13 ($momentDescription): expected '
        'home-rule-capture-bonus\'s title to read the app_ar.arb '
        'homeRuleCaptureBonus literal "$expectedCaptureBonusTitle", got '
        '"${captureBonusTitle.data}"',
  );
}

/// Order 207, captures 13 and 14: asserts [finder]'s rect lies entirely
/// inside the current view (no scrolling attempted, in either capture). On
/// failure the reason names [label], says it is off screen, and gives both
/// rects -- [label]'s own and the view's -- so a widget left below the fold
/// on some device is a reproducible finding for the master, not something
/// this test papers over by scrolling. Both rects are formatted by hand
/// (left/top/right/bottom, fixed to one decimal) rather than through Rect's
/// own toString: run 61 (order 207's RETURN 1) found the device build
/// strips dart:ui's toString, so a failure there printed "its rect Instance
/// of 'Rect' does not lie entirely inside the view Instance of 'Rect'" --
/// unreadable, and useless as a reproduction.
void _expectRectInsideView(
  WidgetTester tester,
  Finder finder, {
  required String label,
  required String context,
}) {
  final Rect rect = tester.getRect(finder);
  final Size viewSize = tester.view.physicalSize / tester.view.devicePixelRatio;
  final Rect viewRect = Rect.fromLTWH(0, 0, viewSize.width, viewSize.height);
  final bool insideView =
      rect.left >= viewRect.left &&
      rect.top >= viewRect.top &&
      rect.right <= viewRect.right &&
      rect.bottom <= viewRect.bottom;
  // left/top/right/bottom formatted by hand, one decimal each, rather than
  // through Rect's own toString: run 61 (order 207's RETURN 1) showed the
  // device build strips dart:ui's toString, so this same failure printed
  // "its rect Instance of 'Rect' does not lie entirely inside the view
  // Instance of 'Rect'" there -- unreadable, and no reproduction at all.
  final String rectText =
      '(left: ${rect.left.toStringAsFixed(1)}, top: '
      '${rect.top.toStringAsFixed(1)}, right: '
      '${rect.right.toStringAsFixed(1)}, bottom: '
      '${rect.bottom.toStringAsFixed(1)})';
  final String viewRectText =
      '(left: ${viewRect.left.toStringAsFixed(1)}, top: '
      '${viewRect.top.toStringAsFixed(1)}, right: '
      '${viewRect.right.toStringAsFixed(1)}, bottom: '
      '${viewRect.bottom.toStringAsFixed(1)})';
  expect(
    insideView,
    isTrue,
    reason:
        '$label is off screen $context: its rect $rectText does not lie '
        'entirely inside the view $viewRectText; this test does not scroll '
        'to bring it into view, so this is a real finding for the master, '
        'not something to work around',
  );
}

/// Order 207, capture 14: asserts the host's not-full-lobby view --
/// [controller].isHost true, lobby-start-button present and disabled,
/// lobby-start-with-present-button present, enabled, and reading the
/// app_ar.arb lobbyStartWithPresent "=2" literal, lobby-rule-blocks and
/// lobby-rule-capture-bonus reading their own app_ar.arb literals (quoted
/// here, not looked up through AppLocalizations, per the order), and
/// lobby-leave-button's rect inside the view. Two lobby-seat-* rows are
/// asserted by the caller's own _expectLobbyScreen(expectedSeatCount: 2)
/// immediately before each call here, not repeated inside this helper.
/// [momentDescription] names which of the two calls (before or after the
/// post-room-reply settle) failed.
void _expectLobbyHostStartWith(
  WidgetTester tester, {
  required RoomController controller,
  required String momentDescription,
}) {
  expect(
    controller.isHost,
    isTrue,
    reason:
        'capture 14 ($momentDescription): expected controller.isHost to '
        'read true -- this client created the room and was seated at '
        'host_seat 0 -- got false',
  );

  final Finder startFinder = find.byKey(const Key('lobby-start-button'));
  expect(
    startFinder,
    findsOneWidget,
    reason:
        'capture 14 ($momentDescription): expected lobby-start-button on '
        'screen for the host',
  );
  final ElevatedButton startWidget = tester.widget<ElevatedButton>(startFinder);
  expect(
    startWidget.onPressed,
    isNull,
    reason:
        'capture 14 ($momentDescription): the room is not full (2 of 4 '
        'seats joined), so expected lobby-start-button disabled '
        '(onPressed null), got a non-null callback',
  );

  final Finder startWithFinder = find.byKey(
    const Key('lobby-start-with-present-button'),
  );
  expect(
    startWithFinder,
    findsOneWidget,
    reason:
        'capture 14 ($momentDescription): expected '
        'lobby-start-with-present-button on screen for the host in a room '
        'that is not full with at least 2 seated (lobby_screen.dart '
        '_connectedBody)',
  );
  final ElevatedButton startWithWidget = tester.widget<ElevatedButton>(
    startWithFinder,
  );
  expect(
    startWithWidget.onPressed,
    isNotNull,
    reason:
        'capture 14 ($momentDescription): expected '
        'lobby-start-with-present-button enabled (onPressed non-null); '
        'nothing has tapped it, so _startWithPresentInFlight should still '
        'be false',
  );
  const String expectedStartWithText = 'ابدأ بلاعبَين';
  final Text startWithText = startWithWidget.child! as Text;
  expect(
    startWithText.data,
    expectedStartWithText,
    reason:
        'capture 14 ($momentDescription): expected '
        'lobby-start-with-present-button\'s Text to read the app_ar.arb '
        'lobbyStartWithPresent "=2" literal "$expectedStartWithText" for '
        '2 seated, got "${startWithText.data}"',
  );

  const String expectedRuleBlocksText = 'الحواجز: معطّلة';
  final Text ruleBlocksText = tester.widget<Text>(
    find.byKey(const Key('lobby-rule-blocks')),
  );
  expect(
    ruleBlocksText.data,
    expectedRuleBlocksText,
    reason:
        'capture 14 ($momentDescription): expected lobby-rule-blocks\'s '
        'Text to read the app_ar.arb lobbyRuleBlocksOff literal '
        '"$expectedRuleBlocksText" (the fake server\'s room reply carries '
        'rules.blocks: false), got "${ruleBlocksText.data}"',
  );

  const String expectedRuleCaptureBonusText = 'مكافأة الأكل: مفعّلة';
  final Text ruleCaptureBonusText = tester.widget<Text>(
    find.byKey(const Key('lobby-rule-capture-bonus')),
  );
  expect(
    ruleCaptureBonusText.data,
    expectedRuleCaptureBonusText,
    reason:
        'capture 14 ($momentDescription): expected '
        'lobby-rule-capture-bonus\'s Text to read the app_ar.arb '
        'lobbyRuleCaptureBonusOn literal "$expectedRuleCaptureBonusText" '
        '(the fake server\'s room reply carries rules.capture_bonus: '
        'true), got "${ruleCaptureBonusText.data}"',
  );

  _expectRectInsideView(
    tester,
    find.byKey(const Key('lobby-leave-button')),
    label: 'lobby-leave-button',
    context:
        'in the host\'s not-full lobby with lobby-start-with-present-button '
        'showing ($momentDescription)',
  );
}

/// Order 240, captures 15 and 16: asserts PR #87's no-move beat (C-236 rule
/// 4, game_screen.dart's `_armNoMoveHold`, armed by a `rolled` for my seat
/// with an empty `legal`) is still showing both its die mark
/// (`game-die-no-move-mark`) and its text notice (`game-no-move-notice`),
/// and that the notice's own `Text` reads this tree's own
/// `AppLocalizations.gameNoMove` -- looked up, not hardcoded, so a future
/// change to either ARB file is what this assertion tracks, not a frozen
/// copy of today's string. [momentDescription] names which of the two
/// calls (before or after the ~300ms settle) failed, so a failure does not
/// have to be re-run to know which one it was.
void _expectNoMoveVisible(
  WidgetTester tester, {
  required AppLocalizations loc,
  required String momentDescription,
}) {
  expect(
    find.byKey(const Key('game-die-no-move-mark')),
    findsOneWidget,
    reason:
        'capture 15/16 ($momentDescription): expected '
        'game-die-no-move-mark on screen',
  );
  final Finder noticeFinder = find.byKey(const Key('game-no-move-notice'));
  expect(
    noticeFinder,
    findsOneWidget,
    reason:
        'capture 15/16 ($momentDescription): expected '
        'game-no-move-notice on screen',
  );
  final Text noticeText = tester.widget<Text>(noticeFinder);
  expect(
    noticeText.data,
    loc.gameNoMove,
    reason:
        'capture 15/16 ($momentDescription): expected '
        'game-no-move-notice\'s Text to read this tree\'s own '
        'AppLocalizations.gameNoMove ("${loc.gameNoMove}"), got '
        '"${noticeText.data}"',
  );
}

/// Order 240, captures 17 and 18: asserts the opponent token this
/// capture's own `moved` push sent home reads `-1` (back in its yard) in
/// [controller].room -- the same `RoomController` `GameScreen` renders
/// from, not a hand-built snapshot, per the order's own wording ("the
/// captured token is back in its yard in the snapshot the screen holds").
/// [momentDescription] names which of the two calls (before or after the
/// post-move settle) failed.
void _expectCapturedTokenHome(
  WidgetTester tester, {
  required RoomController controller,
  required int capturedSeat,
  required int capturedToken,
  required String momentDescription,
}) {
  final SeatState seatState = controller.room!.seats.firstWhere(
    (SeatState s) => s.seat == capturedSeat,
    orElse: () => throw TestFailure(
      'capture 17/18 ($momentDescription): seat $capturedSeat absent from '
      'controller.room!.seats, so the captured-token assertion below '
      'cannot run',
    ),
  );
  expect(
    seatState.tokens[capturedToken],
    -1,
    reason:
        'capture 17/18 ($momentDescription): expected the captured token '
        '(seat $capturedSeat, token $capturedToken) to read -1 (back in '
        'its yard) in controller.room!.seats -- the same RoomController '
        'GameScreen renders from -- got ${seatState.tokens[capturedToken]}',
  );
}

/// Order 240, captures 19 through 22: asserts [controller].room reports
/// `RoomState.finished` with `winner == expectedWinner`, and that
/// `game-screen-winner`'s own `Text` reads [expectedText] -- the caller's
/// own `AppLocalizations.gameOverYouWin` or
/// `AppLocalizations.gameOverPlayerWins(name)` lookup, never hardcoded
/// here. [momentDescription] names which of the two calls (before or after
/// the post-game-over settle) failed.
void _expectGameOverWinnerText(
  WidgetTester tester, {
  required RoomController controller,
  required int expectedWinner,
  required String expectedText,
  required String momentDescription,
}) {
  expect(
    controller.room?.state,
    RoomState.finished,
    reason:
        'capture 19/20/21/22 ($momentDescription): expected '
        'controller.room!.state to read RoomState.finished, got '
        '${controller.room?.state}',
  );
  expect(
    controller.room?.winner,
    expectedWinner,
    reason:
        'capture 19/20/21/22 ($momentDescription): expected '
        'controller.room!.winner to read $expectedWinner, got '
        '${controller.room?.winner}',
  );
  final Finder winnerFinder = find.byKey(const Key('game-screen-winner'));
  expect(
    winnerFinder,
    findsOneWidget,
    reason:
        'capture 19/20/21/22 ($momentDescription): expected '
        'game-screen-winner on screen',
  );
  final Text winnerText = tester.widget<Text>(winnerFinder);
  expect(
    winnerText.data,
    expectedText,
    reason:
        'capture 19/20/21/22 ($momentDescription): expected '
        'game-screen-winner\'s Text to read "$expectedText", got '
        '"${winnerText.data}"',
  );
}
