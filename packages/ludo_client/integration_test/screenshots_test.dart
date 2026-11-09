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
// screen sits in a connecting state whose waiting-line mark turns, and its
// ticker reschedules a frame forever. pumpAndSettle() never returns
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
//   37-game-large-en.png      game board mid-game, English, system text
//                             scale 2.0, the host's turn
//   38-game-large-ar.png      same board, Arabic, system text scale 2.0,
//                             another seat's turn
//   39-lobby-large-en.png     the host's lobby, English, system text
//                             scale 2.0
//   40-end-loser-large-ar.png the loser's end card, Arabic, system text
//                             scale 2.0
//   99-home-plain-en.png      home, English, default state, top of the list
//   100-home-plain-ar.png     home, Arabic, default state, top of the list
//   101-home-players-menu-en.png  home, English, the players menu open
//   102-home-players-menu-ar.png  home, Arabic, the players menu open
//   103-home-join-shown-en.png    home, English, six characters typed, Join
//                                 shown
//   104-home-large-text-ar.png    home, Arabic, system text scale 2.0,
//                                 scrolled to the players row
//   105-game-muted-ar.png     game header, Arabic, after one tap on the
//                             sound toggle (crossed speaker)
//   106-refusal-die-my-turn-en.png  game, English, the die refused on my own
//                             turn under the legal-token halo
//   107-home-room-closed-host-en.png  home, English, the host's room closed
//   108-home-room-closed-guest-ar.png home, Arabic, a guest's room closed
//   109-lobby-link-gone-first-time-ar.png  lobby error, Arabic, a first-time
//                             link join into a room that is gone
//   110-lobby-room-started-en.png  lobby error, English, room not taking
//                             players
//   111-game-connection-lost-ar.png  game, Arabic, connection-lost card
//   112-end-resumed-no-rolls-en.png  end card, English, reached by a resume
//   113-end-lose-zero-ar.png  loser's end card, Arabic, every count at zero
//                             but the rolls, so only the rolls tile shows
//   115-lobby-error-transport-en.png  lobby error card, English, a typed join
//                             that never reached the server (Retry filled)
//   116-lobby-error-link-gone-ar.png  lobby error card, Arabic, a link join
//                             into a room that is gone (Back to home filled)
//   118-end-lose-some-zero-en.png  loser's end card, English, rolls and sixes
//                             tiles only
//   119-lobby-same-names-en.png  host lobby, English, seats 0 and 2 both
//                             "Player", seat 1 "Karim": Player, Karim,
//                             Player 2
//   120-game-same-names-ar.png  game, Arabic, seats 0 and 2 both the default
//                             name: the board chips read the name and the
//                             name plus the numeral 2
//   121-end-same-names-en.png  loser's end card, English, seat 2 (the second
//                             "Player") won: the title names "Player 2"
//   122-game-seat-moved-en.png  game, English, the takeover card after an
//                             unsolicited BAD_SEAT_TOKEN and the close
//   123-game-seat-moved-ar.png  game, Arabic, the same takeover card
//   124-lobby-seat-moved-ar.png  lobby holding a room, Arabic, the takeover
//                             card over the stale gathering
//   125-game-reconnecting-slow-en.png  game, English, the reconnecting row
//                             after the slow line has appeared
//   126-game-reconnecting-slow-ar.png  game, Arabic, the same slow row
//   127-game-catching-up-ar.png  game, Arabic, the desync banner reading
//                             "updating the table"
//   128-game-time-up-en.png   game, English, my turn with the count at zero:
//                             the turning hourglass in the ring, no digits
//   129-game-time-up-ar.png   game, Arabic, the same hourglass
//   130-lobby-resyncing-en.png  lobby holding a room, English, the desync
//                             banner with a resync out on the live socket:
//                             Resync disabled, its mark turning
//   131-lobby-resyncing-ar.png  lobby, Arabic, the same banner
//   132-lobby-connecting-large-text-en.png  lobby connecting body, English,
//                             system text scale 2.0, the slow line showing
//   133-lobby-connecting-large-text-ar.png  lobby connecting body, Arabic,
//                             the same
//   (114 stays unused: dropped in run 124, a 360 x 640 surface hung the
//   emulator. 117, the lobby closed card with no room held, is not built:
//   the controller cannot be left in that state by any frame sequence.)
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
import 'dart:io' show Platform, SocketException;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/board.dart' show LudoBoard;
import 'package:ludo_client/src/board_geometry.dart' show cellFor;
import 'package:ludo_client/src/chat_bubble.dart' show kChatMinDwell;
import 'package:ludo_client/src/die_cube.dart' show BoardThrownDie;
import 'package:ludo_client/src/end_card.dart' show EndCard;
import 'package:ludo_client/src/feedback.dart'
    show FeedbackCue, FeedbackScope, FeedbackService, FeedbackSettings;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart'
    show RoomSnapshot, RoomState, SeatState;
import 'package:ludo_client/src/room_code.dart'
    show isValidRoomCode, normalizeRoomCode, roomCodeLength;
import 'package:ludo_client/src/seat_mark.dart' show SeatMark;
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart'
    show LastGame, SeatRecord, SessionMemory;
import 'package:ludo_client/src/theme.dart' show LudoColors;
import 'package:ludo_client/src/verify_rolls_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/net/fake_transport.dart';
import 'fixtures/real_games_fixture.dart' show realGamesJson;

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
  String? gameId,
  String? clientSeeds,
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
  'client_seeds': clientSeeds,
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
/// LobbyScreen's connecting body draws a waiting-line mark whose
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

/// Taps Create Room on the home screen. Under a system text scale above 1.0
/// the plain home (C-523) is taller than this rig's 800 x 600 view and
/// Create sits below the fold (measured at scale 2.0: centre y 622), so a
/// player would scroll to it; this scrolls to it first. At scale 1.0 nothing
/// is scrolled, and a Create left below the fold still fails the tap.
/// Home only, so the pumpAndSettle is safe.
Future<void> _tapCreateRoom(WidgetTester tester) async {
  const Key createKey = Key('create-room-button');
  if (tester.platformDispatcher.textScaleFactor > 1.0) {
    await tester.ensureVisible(find.byKey(createKey));
    await tester.pumpAndSettle();
  }
  await _tapAndAwaitPushedRoute(tester, createKey);
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

/// Order 567: every `takeScreenshot` in this file goes through here. [frames]
/// real-duration pumps (see _pumpRealDurationFrames) run after the caller's
/// last assertion and right before the shot, so the platform surface has
/// painted frames of the tree the capture just asserted. With `frames: 0` the
/// shot follows the caller's last pump directly, and after bare pump() calls
/// that photographs the surface one push behind: capture 06 did, and the
/// offline line was missing in CI runs 39903965012, 40064732859, 41232160665,
/// 41581381415 and 41898558485.
///
/// The default 30 is _pumpRealDurationFrames's own, the value 10 and 11 use.
/// A capture that already ends in its own real-duration pumps with no tree
/// change after them passes `frames: 0` and keeps that settle; a capture
/// whose state expires on a timer passes a count that ends well inside the
/// hold. Those, with the hold and the margin each leaves:
///   - 04, 37, 38: since order 573 the last moved push lands seat 1 token 1 on
///     progress 44, absolute square 5 (entry 13), which no other token holds, so
///     the C-384 pair pill (kSafeCueHold 1400 ms + kSafeCueFade 200 ms) no
///     longer arms. Before that the push landed on progress 45, absolute 6, seat
///     0's square, and the pill showed from about 100 ms to about 1600 ms after
///     the push. [untilGone] stays: it finds nothing to wait for and returns at
///     once, and it would still wait out a pill if one ever armed again.
///   - 15, 16, 76-78: no-move notice, _noMoveHold 1500 ms; own 10 frames
///     (320 ms), about 1100 ms left; frames: 0.
///   - 134, 135: no-move notice (three sixes), _noMoveHold 1500 ms, armed by
///     the third `rolled`; the turn_passed and turn behind it land with no
///     real-time gap, so, as in 15 and 16, own 10 frames (320 ms), about
///     1100 ms left; frames: 0.
///   - 136-138: watcher dead-roll line and badge, _noMoveHold 1500 ms, armed
///     by the `turn_passed` that lands with its `rolled`; own 10 frames (320
///     ms), about 1100 ms left, asserted under 1200 ms by wall time; frames: 0.
///   - 139, 140: countdown digits at 10, one second per value; the wait loop
///     exits within a frame of the tick, 6 frames (about 190 ms) follow,
///     about 800 ms left in that second; frames: 0.
///   - 51, 52: timer-played-other notice, _timerPlayedOtherHold 2500 ms; own
///     12 frames (_trayShotFrames), about 2000 ms left; frames: 0.
///   - 17, 18, 69, 70: capture gloat, kCaptureGloatLife 1600 ms, full opacity
///     for the first 1350 ms. Order 578: the replay returns 400 to 460 ms after
///     the walk lands and 6 own frames follow; the shot is 720 to 800 ms after
///     landing under flutter-tester, asserted under 1100 ms and at opacity 1.0
///     immediately before it; frames: 0.
///   - 73, 74: hint glow, _kHintGlow 800 ms; own 300 ms of pumps after the
///     tap, about 500 ms left; frames: 0.
///   - 81-88, 91, 92: chat bubble and end-card line, kChatBubbleLife
///     2500 ms; the 300 or 400 ms hold after the push is one pump, so 12
///     frames (about 600 ms) follow it, about 1400 ms left.
///   - 89, 90: countdown digits, one second per value; the wait loop exits
///     within a frame of the tick, 6 frames (about 300 ms) follow it, about
///     600 ms left.
///   - 95, 96: chat rest ring, 3000 ms; own 31 frames (992 ms), the shot
///     shows the ring part drained; frames: 0.
///   - 97, 98, 106: refusal mark, kRefusalMarkLife 300 ms, shot 96 ms after
///     the tap, about 200 ms left. No settle fits inside that, so these keep
///     frames: 0 and still photograph straight after their last pump.
Future<void> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name, {
  int frames = 30,
  Finder? untilGone,
  int maxExtraFrames = 60,
  Duration frame = const Duration(milliseconds: 32),
}) async {
  await _pumpRealDurationFrames(tester, frameCount: frames, frame: frame);
  var extraFrames = 0;
  while (untilGone != null && untilGone.evaluate().isNotEmpty) {
    if (extraFrames >= maxExtraFrames) {
      throw TestFailure(
        'capture $name: expected ${untilGone.describeMatch(Plurality.one)} '
        'to have left the tree before the shot, it was still there after '
        '$frames settle '
        'frames plus $maxExtraFrames more of $frame each. Reproduce with '
        '`flutter test integration_test/screenshots_test.dart --plain-name '
        '"$name"` on the test that owns this capture.',
      );
    }
    await tester.pump(frame);
    extraFrames += 1;
  }
  await binding.takeScreenshot(name);
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

  // Amended for C-254 (order 255, item 3): a seat card's own sub-keys
  // (`lobby-seat-<n>-token`, `lobby-seat-<n>-you`, `lobby-seat-<n>-host`)
  // and the open-seat placeholder keys (`lobby-seat-open-<i>`) also start
  // with "lobby-seat-", so a bare `startsWith` would overcount once C-254
  // lands; match only the card's own key, `lobby-seat-<digits>`.
  final RegExp seatCardKeyPattern = RegExp(r'^lobby-seat-\d+$');
  final seatFinders = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        seatCardKeyPattern.hasMatch((widget.key! as ValueKey<String>).value),
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

  // On a device SharedPreferences persist between captures, so the game an
  // earlier capture played leaves a fresh session.seat and session.seatSavedAt
  // behind, and under C-447 D3 Home resumes such a record on its own before
  // the next capture looks at it. Every capture starts with no seat record.
  // Only these two keys go; every capture still seeds the rest of its store.
  setUp(() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('session.seat');
    await prefs.remove('session.seatSavedAt');
  });

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
    await _capture(binding, tester, '01-home-en', frames: 0);

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
    await _capture(binding, tester, '02-home-ar', frames: 0);

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

    await _capture(binding, tester, '03-lobby-en', frames: 0);

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
    pushMoved(seat: 1, token: 1, from: -1, to: 44);
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
    await _capture(
      binding,
      tester,
      '04-game-en',
      untilGone: _keysStartingWith('board-safe-cue-'),
    );

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

    await _capture(binding, tester, '06-game-offline-en', frames: 30);
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
    // Join is in the tree only once the field holds a full code (C-523 D3);
    // let its entry finish before the tap. Home only, so this settles.
    await tester.pumpAndSettle();
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
        data: <String, Object?>{'seat': 2, 'seat_token': 'tok-shot-joiner'},
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
            _seatJson(2, name: joinerName),
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
    pushMoved(seat: 2, token: 0, from: -1, to: 15);
    await tester.pump();
    pushMoved(seat: 2, token: 1, from: -1, to: 40);
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
    await _capture(binding, tester, '05-game-ar', frames: 30);

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
      controller.room!.seats
          .firstWhere((SeatState s) => s.seat == offlineSeat07)
          .connected,
      isFalse,
      reason:
          'capture 07 pushed presence {seat: $offlineSeat07, connected: '
          'false}; expected the seat $offlineSeat07 entry of '
          'controller.room!.seats ("$offlineSeatName07") to read '
          'disconnected before the capture fires, got connected='
          '${controller.room!.seats.firstWhere((SeatState s) => s.seat == offlineSeat07).connected}',
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

    await _capture(binding, tester, '07-game-offline-ar', frames: 30);
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
    // C-449 D5: a record with no saved time (the legacy shape, C-447 D2), so
    // the button shows and Home does not resume on its own. A record written
    // through SessionMemory.recordSeat now carries a fresh saved time and
    // would be resumed before this capture could be taken.
    await _seedSeatWithoutSavedTime(
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
    await _capture(binding, tester, '08-home-rejoin-en', frames: 0);

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
    await _capture(binding, tester, '09-home-rejoin-ar', frames: 0);

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
            _seatJson(2, name: 'Karim'),
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
    // C-282 rule 1: the last table stays in view, dimmed and untappable,
    // under the connection-lost card.
    expect(
      find.descendant(
        of: find.byKey(const Key('game-screen-stale-table')),
        matching: find.byKey(const Key('game-screen-board')),
      ),
      findsOneWidget,
      reason:
          'capture 10: expected game-screen-board inside '
          'game-screen-stale-table immediately before the capture',
    );
    expect(
      find.byKey(const Key('game-screen-reconnect-button')),
      findsNothing,
      reason:
          'capture 10: C-282 rule 2d, no Reconnect button while the '
          'automatic retry is pending',
    );

    await _capture(binding, tester, '10-game-reconnecting-en', frames: 0);
  });

  // ==========================================================================
  // 11: order 180's R1 reconnecting line, on LobbyScreen, in Arabic. Reached
  // the same way test/reconnecting_line_test.dart's R1-AR case reaches it: a
  // real host lobby, connected, then dropped, with a non-empty auto-reconnect
  // schedule so the lobby-closed card shows lobby-reconnecting the instant
  // the drop lands, over the gathering kept inside lobby-stale-room.
  // LobbyScreen is mounted first, on a fresh idle controller, and
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
    // C-284 rule 1: the gathering stays, dimmed, under the card. The
    // old column assertions expected these two keys gone.
    expect(
      find.descendant(
        of: find.byKey(const Key('lobby-stale-room')),
        matching: find.byKey(const Key('lobby-room-code')),
      ),
      findsOneWidget,
      reason:
          'capture 11: expected lobby-room-code inside lobby-stale-room '
          'immediately before the capture',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('lobby-stale-room')),
        matching: find.byKey(const Key('lobby-copy-code-button')),
      ),
      findsOneWidget,
      reason:
          'capture 11: expected lobby-copy-code-button inside '
          'lobby-stale-room immediately before the capture',
    );
    expect(
      find.byKey(const Key('lobby-reconnect-button')),
      findsNothing,
      reason:
          'capture 11: no Reconnect button while the automatic retry is '
          'pending',
    );

    await _capture(binding, tester, '11-lobby-reconnecting-ar', frames: 0);
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
    // Join is in the tree only once the field holds a full code (C-523 D3);
    // let its entry finish before the tap. Home only, so this settles.
    await tester.pumpAndSettle();
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

    await _capture(binding, tester, '12-lobby-guest-full-ar', frames: 0);
  });

  // ==========================================================================
  // 14: the host's "start with N" button in a lobby that is not full
  // (lobby-start-with-present-button, lobby_screen.dart), which no capture
  // before this one shows: capture 03 is a full room. One mount, one flow,
  // Arabic throughout (standing lesson 35): the same route capture 12 walks
  // -- HomeScreen -> RoomRoute -> LobbyScreen -- stopped short of ever
  // tapping Start.
  //
  // Capture 13 (Home's open players disclosure with the Capture bonus card
  // switched off) went with C-523 D1 and D2: neither the disclosure nor the
  // card exists. Capture 14 keeps its number. Home can no longer turn
  // Capture bonus off, so the create_room frame now carries it on (D1); the
  // fake server's room reply still says off, which is what a room an older
  // client created looks like, and D6 shows the "off" chip for exactly that
  // room and no house-rules line (D6).
  // ==========================================================================
  testWidgets('capture 14-lobby-host-start-with-ar', (tester) async {
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
          'capture 14: expected no home-rejoin-button on a freshly mounted '
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
          'capture 14: expected home-name-field to have lost focus right '
          'after FocusManager.instance.primaryFocus?.unfocus() above, so no '
          'text cursor handle is painted under it in the screenshot; it '
          'still has focus',
    );
    expect(
      tester.widget<EditableText>(nameFieldEditableFinder).controller.text,
      hostName,
      reason:
          'capture 14: expected home-name-field to still read "$hostName" '
          'right after the unfocus above; the create_room assertions below '
          'depend on the typed name surviving the unfocus',
    );

    // Order 207 step 4: the Create button of a plain home must be on screen
    // without scrolling; a create-room-button left below the fold is a
    // finding for the master, not something this test scrolls around.
    _expectRectInsideView(
      tester,
      find.byKey(const Key('create-room-button')),
      label: 'create-room-button',
      context: 'on the plain home before capture 14',
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

    // Order 207 step 5: the rules reaching the wire, not only the widget --
    // read straight off the create_room frame this client actually sent
    // (test/net/fake_transport.dart's sentRaw), the same idiom _idOf/_typeOf
    // already read frames with above.
    final Map<String, Object?> createData =
        _decode(createMessages.single)['d']! as Map<String, Object?>;
    final Map<String, Object?> sentRules =
        createData['rules']! as Map<String, Object?>;
    expect(
      sentRules.containsKey('blocks'),
      isFalse,
      reason:
          'C-356: RoomToggles.toJson (net/connection.dart) never carries '
          'blocks any more; expected no blocks key inside rules, frame '
          'data was $createData',
    );
    expect(
      sentRules['capture_bonus'],
      isTrue,
      reason:
          'C-523 D1: expected the create_room frame\'s rules.capture_bonus '
          'to be true, home has no rule control left to turn it off; frame '
          'data was $createData',
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
          'capture 14 fixture is broken: "$roomCode" must be a '
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
    // the fake server's own answer for this capture -- blocks false (C-356:
    // the server now creates every room with blocks off, regardless of what
    // the client asked), capture_bonus false (the answer for a room an older
    // client created, C-523 D6; this client asked for true above),
    // turn_seconds 90 -- host_seat 0, players 4, and two seats taken (this
    // host, and Karim at seat 1).
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
      'capture_bonus': false,
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

    await _capture(binding, tester, '14-lobby-host-start-with-ar', frames: 0);
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
  // room uses (there at seats 0 and 1 of three; here, in a room of two, at
  // seats 0 and 2), reused here and through capture 22 below so the
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
        data: <String, Object?>{'seat': 2, 'name': 'Karim', 'seq': 2},
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
        data: <String, Object?>{'seat': 2, 'deadline_ms': 45000, 'seq': 5},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.turn!.seat,
      2,
      reason:
          'capture 15 pushed a turn frame naming seat 2 (Karim) right '
          'after my own no-move rolled; expected '
          'controller.room!.turn!.seat to read 2 immediately after both '
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
      expectedText: loc15.gameNoMoveNeedSix,
    );

    // "captured about 300 ms later" (the order's own words): 10 real
    // frames of 32ms each, reusing _pumpRealDurationFrames's own real-time
    // mechanism with a shorter count than its 30-frame default, because
    // this capture is specifically about the hold still standing partway
    // through its 1500ms life, not fresh off the rolled or long after it.
    await _pumpRealDurationFrames(tester, frameCount: 10);

    expect(
      controller.room!.turn!.seat,
      2,
      reason:
          'capture 15: after the ~300ms settle, expected '
          'controller.room!.turn!.seat to still read 2 (Karim) '
          'immediately before the capture, got '
          '${controller.room!.turn!.seat}',
    );
    _expectNoMoveVisible(
      tester,
      loc: loc15,
      momentDescription:
          'after the ~300ms settle, immediately before capture 15',
      expectedText: loc15.gameNoMoveNeedSix,
    );

    await _capture(binding, tester, '15-game-no-move-en', frames: 0);
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
        data: <String, Object?>{'seat': 2, 'name': 'Karim', 'seq': 2},
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
        data: <String, Object?>{'seat': 2, 'deadline_ms': 45000, 'seq': 5},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.turn!.seat,
      2,
      reason:
          'capture 16 pushed a turn frame naming seat 2 (Karim) right '
          'after my own no-move rolled; expected '
          'controller.room!.turn!.seat to read 2 immediately after both '
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
      expectedText: loc16.gameNoMoveNeedSix,
    );

    await _pumpRealDurationFrames(tester, frameCount: 10);

    expect(
      controller.room!.turn!.seat,
      2,
      reason:
          'capture 16: after the ~300ms settle, expected '
          'controller.room!.turn!.seat to still read 2 (Karim) '
          'immediately before the capture, got '
          '${controller.room!.turn!.seat}',
    );
    _expectNoMoveVisible(
      tester,
      loc: loc16,
      momentDescription:
          'after the ~300ms settle, immediately before capture 16',
      expectedText: loc16.gameNoMoveNeedSix,
    );

    await _capture(binding, tester, '16-game-no-move-ar', frames: 0);
  });

  // ==========================================================================
  // 17, 18: order 240's (X14) capture frame -- an opponent token sent home
  // by my own `moved`. Order 578: the frame is a real one. `_replayRealGameToCapture`
  // plays the recorded game host_wins_1 from the host's view (seat 0, Priya)
  // up to the first capture seat 0 makes, pushes that `moved` alone so the
  // board walks it square by square and the struck token flies home, then the
  // frames behind it through the next `turn`. The mover's square, the struck
  // token and the seat on turn are read off the recorded frames; the shot is
  // taken a fraction of a second after landing, while the gloat is whole.
  //
  // Order 570: the capturing `moved` carries `extra_roll: true`, because a
  // capture grants another roll (docs/PROTOCOL.md 12.2), and the server
  // sends a `turn` for the same seat in `await_roll` right behind it
  // (21.3.4), so the frame under test is the one a player sees: the banner
  // says "You captured. Roll again." (loc.gameRollAgainCapture), asserted
  // before the shot. Asserted off controller.room -- the same RoomController
  // GameScreen renders from -- not a hand-built snapshot: the struck token
  // reads -1 (back in its yard) there.
  // ==========================================================================
  testWidgets('capture 17-game-capture-en', (tester) async {
    await _shootCaptureRollAgain(
      tester,
      binding,
      shotName: '17-game-capture-en',
      locale: const Locale('en'),
    );
  });

  // ==========================================================================
  // 18: capture 17's own Arabic twin, mounted directly in Arabic the same
  // way capture 16 is.
  // ==========================================================================
  testWidgets('capture 18-game-capture-ar', (tester) async {
    await _shootCaptureRollAgain(
      tester,
      binding,
      shotName: '18-game-capture-ar',
      locale: const Locale('ar'),
    );
  });

  // ==========================================================================
  // 134, 135: the three-sixes no-move frame. My seat rolls 6, 6, 6 in a row;
  // the first two owe a roll each and queue without a move in between, the
  // third is still sent as a `rolled` and the server then ends the turn with
  // `turn_passed` `reason: "three_sixes"` and a `turn` for the next seat
  // (docs/PROTOCOL.md 12.1 and 21.3.4, packages/ludo_server/test/
  // roll_queue_wire_test.dart W8). The client reads the third six off the
  // queue it saw (game_screen.dart `_isThirdSix`), so the notice is
  // loc.gameNoMoveThreeSixes, not the need-six line 15 and 16 show; asserted
  // before the shot. Mounted the way 15 and 16 are: 134 through HomeScreen
  // in English, 135 directly in Arabic. Taken about 300 ms into the 1500 ms
  // hold, as 15 and 16 are.
  // ==========================================================================
  testWidgets('capture 134-game-three-sixes-en', (tester) async {
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
    const String roomCode = 'SIX134';

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
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-134'},
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
        data: <String, Object?>{'seat': 2, 'name': 'Karim', 'seq': 2},
      ),
    );
    await tester.pump();

    await _expectLobbyScreen(
      tester,
      localeName: 'en',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton134 = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton134,
      findsOneWidget,
      reason: 'the host, seat 0, must see a Start button once seated',
    );
    await tester.tap(startButton134);
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

    final AppLocalizations loc134 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc134.localeName,
      'en',
      reason: 'capture 134 fixture is broken: this case must be in English',
    );

    // Seat 0 (Priya, me) rolls 6, 6, 6; the server ends the turn on the
    // third and hands it to seat 2 (Karim).
    final int lastSeq = await _pushThreeSixesRun(tester, transport, 4);

    _expectThreeSixesNotice(
      tester,
      controller: controller,
      captureName: '134-game-three-sixes-en',
      expected: loc134.gameNoMoveThreeSixes,
      expectedSeq: lastSeq,
      momentDescription:
          'immediately after the third rolled, turn_passed and the next '
          'turn landed, before the ~300ms settle',
    );

    // About 300 ms in, as 15 and 16 do: the hold still standing partway
    // through its 1500 ms.
    await _pumpRealDurationFrames(tester, frameCount: 10);

    _expectThreeSixesNotice(
      tester,
      controller: controller,
      captureName: '134-game-three-sixes-en',
      expected: loc134.gameNoMoveThreeSixes,
      expectedSeq: lastSeq,
      momentDescription:
          'after the ~300ms settle, immediately before capture 134',
    );

    await _capture(binding, tester, '134-game-three-sixes-en', frames: 0);
  });

  // ==========================================================================
  // 135: capture 134's own Arabic twin, mounted directly in Arabic the way
  // capture 16 is.
  // ==========================================================================
  testWidgets('capture 135-game-three-sixes-ar', (tester) async {
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
    const String roomCode = 'SIX135';

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
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-135'},
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
        data: <String, Object?>{'seat': 2, 'name': 'Karim', 'seq': 2},
      ),
    );
    await tester.pump();

    await _expectLobbyScreen(
      tester,
      localeName: 'ar',
      code: roomCode,
      expectedSeatCount: 2,
    );

    final Finder startButton135 = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton135,
      findsOneWidget,
      reason: 'the host, seat 0, must see a Start button once seated',
    );
    await tester.tap(startButton135);
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
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason: 'RoomRoute must latch onto GameScreen and never go back',
    );

    final AppLocalizations loc135 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc135.localeName,
      'ar',
      reason: 'capture 135 fixture is broken: this case must be in Arabic',
    );

    // Seat 0 (Priya, me) rolls 6, 6, 6; the server ends the turn on the
    // third and hands it to seat 2 (Karim).
    final int lastSeq = await _pushThreeSixesRun(tester, transport, 4);

    _expectThreeSixesNotice(
      tester,
      controller: controller,
      captureName: '135-game-three-sixes-ar',
      expected: loc135.gameNoMoveThreeSixes,
      expectedSeq: lastSeq,
      momentDescription:
          'immediately after the third rolled, turn_passed and the next '
          'turn landed, before the ~300ms settle',
    );

    // About 300 ms in, as 15 and 16 do: the hold still standing partway
    // through its 1500 ms.
    await _pumpRealDurationFrames(tester, frameCount: 10);

    _expectThreeSixesNotice(
      tester,
      controller: controller,
      captureName: '135-game-three-sixes-ar',
      expected: loc135.gameNoMoveThreeSixes,
      expectedSeq: lastSeq,
      momentDescription:
          'after the ~300ms settle, immediately before capture 135',
    );

    await _capture(binding, tester, '135-game-three-sixes-ar', frames: 0);
  });

  // ==========================================================================
  // 136-140: order 587 (C-586 D1-D7). Emulator frames from recorded real games
  // (`real_games.json`), never a typed frame. 136-138 are a watcher meeting
  // another seat's dead roll: the recorded `rolled` with no legal move and the
  // `turn_passed` behind it land together, and inside the 1500 ms hold the
  // line under the die names the seat (`game-no-move-other-notice`) and that
  // seat's die wears the red X (`board-seat-die-dead-<seat>`). 139 and 140 are
  // the last ten seconds of a recorded turn, read in real time until the
  // digits show 10: the ring and digits sit under
  // `game-header-countdown-warning`. 139 is seat 0's own turn (red ring on a
  // red seat, the case colour alone cannot tell), 140 is a watcher on seat 0's
  // turn. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 136-watcher-dead-roll-en', (tester) async {
    await _shootWatcherDeadRoll(
      tester,
      binding,
      shotName: '136-watcher-dead-roll-en',
      locale: const Locale('en'),
      gameName: 'host_wins_1',
      viewerSeat: 0,
      bySeat: 2,
    );
  });

  testWidgets('capture 137-watcher-dead-roll-ar', (tester) async {
    await _shootWatcherDeadRoll(
      tester,
      binding,
      shotName: '137-watcher-dead-roll-ar',
      locale: const Locale('ar'),
      gameName: 'guest_wins_1',
      viewerSeat: 2,
      bySeat: 0,
    );
  });

  testWidgets('capture 138-watcher-dead-roll-four-en', (tester) async {
    await _shootWatcherDeadRoll(
      tester,
      binding,
      shotName: '138-watcher-dead-roll-four-en',
      locale: const Locale('en'),
      gameName: 'four_seats_1',
      viewerSeat: 1,
    );
  });

  testWidgets('capture 139-countdown-warning-seat0-en', (tester) async {
    await _shootCountdownWarning(
      tester,
      binding,
      shotName: '139-countdown-warning-seat0-en',
      locale: const Locale('en'),
      gameName: 'host_wins_1',
      viewerSeat: 0,
      turnSeat: 0,
    );
  });

  testWidgets('capture 140-countdown-warning-watch-ar', (tester) async {
    await _shootCountdownWarning(
      tester,
      binding,
      shotName: '140-countdown-warning-watch-ar',
      locale: const Locale('ar'),
      gameName: 'guest_wins_1',
      viewerSeat: 2,
      turnSeat: 0,
    );
  });

  // ==========================================================================
  // 141-145: order 593 (C-590 next seat, C-591 rematch start warning).
  // Emulator frames from the recorded four-seat game four_seats_1, never a
  // typed frame. 141-143 are a watcher at a table of four whose seat plays
  // next: 141 (en) seat 1 while seat 0 waits to roll, 142 (ar) seat 1 while
  // seat 0 has an extra roll, 143 (en) seat 1 while seat 2 waits to roll, so
  // seat 3 is the next pip and the banner is the plain waiting line. 144 and
  // 145 play the game to its end and put a rematch LOBBY on top of it the way
  // capture 24 does: 144 (en) as the host, who sees who sits out above Start
  // with N; 145 (ar) as seat 1, who is not in yet and is told the next game
  // can start without them. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 141-you-are-next-four-en', (tester) async {
    await _shootNextSeat(
      tester,
      binding,
      shotName: '141-you-are-next-four-en',
      locale: const Locale('en'),
      viewerSeat: 1,
      turnSeat: 0,
      nextSeat: 1,
      extraRoll: false,
      expectedLine: (AppLocalizations loc, String turnName) =>
          loc.gameYouAreNextAfter(turnName),
    );
  });

  testWidgets('capture 142-you-are-next-four-ar', (tester) async {
    await _shootNextSeat(
      tester,
      binding,
      shotName: '142-you-are-next-four-ar',
      locale: const Locale('ar'),
      viewerSeat: 1,
      turnSeat: 0,
      nextSeat: 1,
      extraRoll: true,
      expectedLine: (AppLocalizations loc, String turnName) =>
          loc.gameYouAreNextGoesAgain(turnName),
    );
  });

  testWidgets('capture 143-next-pip-watcher-four-en', (tester) async {
    await _shootNextSeat(
      tester,
      binding,
      shotName: '143-next-pip-watcher-four-en',
      locale: const Locale('en'),
      viewerSeat: 1,
      turnSeat: 2,
      nextSeat: 3,
      extraRoll: false,
      expectedLine: (AppLocalizations loc, String turnName) =>
          loc.gameWaitingForPlayer(turnName),
    );
  });

  testWidgets('capture 144-rematch-sits-out-en', (tester) async {
    await _shootRematchWarning(
      tester,
      binding,
      shotName: '144-rematch-sits-out-en',
      locale: const Locale('en'),
      viewerSeat: 0,
      readySeats: const <int>[0, 2],
    );
  });

  testWidgets('capture 145-rematch-may-start-ar', (tester) async {
    await _shootRematchWarning(
      tester,
      binding,
      shotName: '145-rematch-may-start-ar',
      locale: const Locale('ar'),
      viewerSeat: 1,
      readySeats: const <int>[0, 2],
    );
  });

  // ==========================================================================
  // 146a, 146, 147: order 594 (C-592 D2). The recorded four-seat game
  // four_seats_1 as seat 3 (Tariq, a guest) to its `game_over`, then a rematch
  // LOBBY built the way 144 and 145 build one. 146a is the card seat 3 sees
  // while the host (seat 0) and seat 1 are in and it is not yet: the C-591 line
  // on the real screen. 146 and 147 go on: seat 3 taps Play again (ready 0, 1,
  // 3), seat 2 never does, and the host starts as docs/PROTOCOL.md 16.4 orders
  // it: `player_left` for seat 2, `seat_assigned` moving this device from seat
  // 3 to seat 2, the re-seating `room`, then `game_started` and the first
  // `turn`. The shot is inside the 4000 ms hold of the seat-moved notice and
  // after the entrance veil has gone. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 146a-may-start-before-move-en', (tester) async {
    await _shootSeatMoved(
      tester,
      binding,
      shotName: '146a-may-start-before-move-en',
      locale: const Locale('en'),
      toTheStart: false,
    );
  });

  testWidgets('capture 146-seat-moved-en', (tester) async {
    await _shootSeatMoved(
      tester,
      binding,
      shotName: '146-seat-moved-en',
      locale: const Locale('en'),
      toTheStart: true,
    );
  });

  testWidgets('capture 147-seat-moved-ar', (tester) async {
    await _shootSeatMoved(
      tester,
      binding,
      shotName: '147-seat-moved-ar',
      locale: const Locale('ar'),
      toTheStart: true,
    );
  });

  // ==========================================================================
  // 148, 149, 149a: order 602 (C-599 D5). The host's four-seat lobby, host
  // seated alone, then `player_joined` for seat 1 (Karim) with the next seq:
  // the shot is about 150 ms after the push, the card mid-entrance with its
  // glow on and the "joined" line under the grid. 149 is the same in Arabic;
  // 149a follows a second join (seat 2, Lina) 150 ms after it. The device
  // wears a FeedbackScope over a recording service, so the cue is asserted
  // too. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 148-friend-joined-en', (tester) async {
    await _shootFriendJoined(
      tester,
      binding,
      locale: const Locale('en'),
      roomCode: 'FJ148E',
      seatToken: 'tok-shot-148',
      joins: const <(int, String, String)>[
        (1, 'Karim', '148-friend-joined-en'),
      ],
    );
  });

  testWidgets('capture 149-friend-joined-ar', (tester) async {
    await _shootFriendJoined(
      tester,
      binding,
      locale: const Locale('ar'),
      roomCode: 'FJ149A',
      seatToken: 'tok-shot-149',
      joins: const <(int, String, String)>[
        (1, 'Karim', '149-friend-joined-ar'),
        (2, 'Lina', '149a-friend-joined-second-ar'),
      ],
    );
  });

  // ==========================================================================
  // 150, 151: order 602 (C-601 D2). The recorded four-seat game four_seats_1
  // replayed to its `game_over` (viewer seat 3 in English, seat 1 in Arabic),
  // then the finished screen scrolled until the roll history is whole on
  // screen: three rows, each with its seat's mark and name before the
  // `k: face` text. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 150-roll-history-seats-en', (tester) async {
    await _shootRollHistorySeats(
      tester,
      binding,
      shotName: '150-roll-history-seats-en',
      locale: const Locale('en'),
      viewerSeat: 3,
    );
  });

  testWidgets('capture 151-roll-history-seats-ar', (tester) async {
    await _shootRollHistorySeats(
      tester,
      binding,
      shotName: '151-roll-history-seats-ar',
      locale: const Locale('ar'),
      viewerSeat: 1,
    );
  });

  // ==========================================================================
  // 152: order 602 (C-600 D2). The recorded game four_seats_1, viewer seat 2,
  // replayed to the first moment tokens of three different seats stand on one
  // main-track cell (found at run time from the recorded `moved` frames), on
  // a 360 dp wide surface where the harness can set one. Bodies live at the
  // bottom of the file.
  // ==========================================================================
  testWidgets('capture 152-shared-cell-three-seats-en', (tester) async {
    await _shootSharedCellThreeSeats(
      tester,
      binding,
      shotName: '152-shared-cell-three-seats-en',
      locale: const Locale('en'),
      viewerSeat: 2,
    );
  });

  // ==========================================================================
  // 19, 20: order 240's (X14) winner's end view. `game_over` names my own
  // seat (0, Priya) as `winner`. No `turn` frame follows a `game_over`
  // (docs/PROTOCOL.md section 13's own last line); `_reduceGameOver`
  // carries the current turn forward into `TurnPhase.finished`, exactly
  // as sections 14.1/14.2 require. Before that push, `_replayRealGame`
  // plays the recorded game host_wins_1 from the host's view (seat 0) on this
  // same transport, so the four stat tiles are this seat's own rolls, sixes,
  // captures and tokens home in that game, read from the fixture's `counts`.
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

    // Seat 0 (Priya), the host, in the recorded game host_wins_1: the device
    // types Priya, taps Create, taps Start, and every recorded frame follows.
    addTearDown(() {
      for (final RoomController c in factory.controllers) {
        c.dispose();
      }
    });
    final _RealReplay replay19 = await _replayRealGame(
      tester,
      factory,
      capture: 'capture 19-end-winner-en',
      gameName: 'host_wins_1',
      seat: 0,
      localeName: 'en',
    );
    final RoomController controller = replay19.controller;

    // My own seat (0, Priya) is named winner by the recorded game_over.
    replay19.pushGameOver();
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc19 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc19.endWinTitle,
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc19.endWinTitle,
      momentDescription:
          'after the post-game-over settle, immediately before capture 19',
    );
    // The four tiles show the fixture's counts for this device's seat in
    // the recorded game, read at run time; a count of 0 means the tile is
    // absent (C-533 D3).
    _expectEndCardStatTiles(
      tester,
      rolls: replay19.counts.rolls,
      sixes: replay19.counts.sixes,
      captures: replay19.counts.captures,
      home: replay19.counts.home,
      momentDescription:
          'after the post-game-over settle, immediately before capture 19 '
          '(${replay19.describe}; ${replay19.counts})',
    );

    await _capture(binding, tester, '19-end-winner-en', frames: 0);
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

    // Seat 0 (Priya), the host, in the recorded game host_wins_1, as capture 19.
    addTearDown(() {
      for (final RoomController c in factory.controllers) {
        c.dispose();
      }
    });
    final _RealReplay replay20 = await _replayRealGame(
      tester,
      factory,
      capture: 'capture 20-end-winner-ar',
      gameName: 'host_wins_1',
      seat: 0,
      localeName: 'ar',
    );
    final RoomController controller = replay20.controller;

    // My own seat (0, Priya) is named winner by the recorded game_over.
    replay20.pushGameOver();
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
      expectedText: loc20.endWinTitle,
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc20.endWinTitle,
      momentDescription:
          'after the post-game-over settle, immediately before capture 20',
    );
    // The four tiles show the fixture's counts for this device's seat in
    // the recorded game, read at run time; a count of 0 means the tile is
    // absent (C-533 D3).
    _expectEndCardStatTiles(
      tester,
      rolls: replay20.counts.rolls,
      sixes: replay20.counts.sixes,
      captures: replay20.counts.captures,
      home: replay20.counts.home,
      momentDescription:
          'after the post-game-over settle, immediately before capture 20 '
          '(${replay20.describe}; ${replay20.counts})',
    );

    await _capture(binding, tester, '20-end-winner-ar', frames: 0);
  });

  // ==========================================================================
  // 21, 22: order 240's (X14) loser's end view. `game_over` names the
  // other seat (1, Karim) as `winner`, so the lose title is what this
  // capture is evidence for: `loc.endLoseTitle(seatState.name)`, looked up
  // from this tree's own AppLocalizations and the opponent's own name off
  // controller.room, not hardcoded here. The device is seat 0 in the recorded
  // game guest_wins_1, which Karim (seat 2) wins; the card's four tiles are
  // Priya's own fixture counts for that game, not Karim's.
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

    // Seat 0 (Priya), the host, in the recorded game guest_wins_1: Karim (seat 2)
    // wins it.
    addTearDown(() {
      for (final RoomController c in factory.controllers) {
        c.dispose();
      }
    });
    final _RealReplay replay21 = await _replayRealGame(
      tester,
      factory,
      capture: 'capture 21-end-loser-en',
      gameName: 'guest_wins_1',
      seat: 0,
      localeName: 'en',
    );
    final RoomController controller = replay21.controller;

    // The other seat (2, Karim) is named winner by the recorded game_over.
    replay21.pushGameOver();
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc21 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 2,
      expectedText: loc21.endLoseTitle('Karim'),
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 2,
      expectedText: loc21.endLoseTitle('Karim'),
      momentDescription:
          'after the post-game-over settle, immediately before capture 21',
    );
    // The four tiles show the fixture's counts for this device's seat in
    // the recorded game, read at run time; a count of 0 means the tile is
    // absent (C-533 D3).
    _expectEndCardStatTiles(
      tester,
      rolls: replay21.counts.rolls,
      sixes: replay21.counts.sixes,
      captures: replay21.counts.captures,
      home: replay21.counts.home,
      momentDescription:
          'after the post-game-over settle, immediately before capture 21 '
          '(${replay21.describe}; ${replay21.counts})',
    );

    await _capture(binding, tester, '21-end-loser-en', frames: 0);
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

    // Seat 0 (Priya), the host, in the recorded game guest_wins_1, as capture 21.
    addTearDown(() {
      for (final RoomController c in factory.controllers) {
        c.dispose();
      }
    });
    final _RealReplay replay22 = await _replayRealGame(
      tester,
      factory,
      capture: 'capture 22-end-loser-ar',
      gameName: 'guest_wins_1',
      seat: 0,
      localeName: 'ar',
    );
    final RoomController controller = replay22.controller;

    // The other seat (2, Karim) is named winner by the recorded game_over.
    replay22.pushGameOver();
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
      expectedWinner: 2,
      expectedText: loc22.endLoseTitle('Karim'),
      momentDescription:
          'immediately after the game_over push landed, before the '
          'post-game-over settle',
    );

    await _pumpRealDurationFrames(tester);

    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 2,
      expectedText: loc22.endLoseTitle('Karim'),
      momentDescription:
          'after the post-game-over settle, immediately before capture 22',
    );
    // The four tiles show the fixture's counts for this device's seat in
    // the recorded game, read at run time; a count of 0 means the tile is
    // absent (C-533 D3).
    _expectEndCardStatTiles(
      tester,
      rolls: replay22.counts.rolls,
      sixes: replay22.counts.sixes,
      captures: replay22.counts.captures,
      home: replay22.counts.home,
      momentDescription:
          'after the post-game-over settle, immediately before capture 22 '
          '(${replay22.describe}; ${replay22.counts})',
    );

    await _capture(binding, tester, '22-end-loser-ar', frames: 0);
  });

  // ==========================================================================
  // 23: order 247's (C-246) rematch ask -- a `room` LOBBY with `rematch`
  // naming the other seat arrives while my own end card is up. Karim joins
  // Priya's room at seat 2, not the host; Priya wins the first game; then
  // Priya's own `rematch` request lands as an unprompted push naming seat
  // 0 in `by` with only seat 0 in `ready` (docs/PROTOCOL.md section
  // 16.6/16.7, C-246 rule 4's "rematch LOBBY, my seat NOT in ready" case).
  // Before that `game_over`, `_replayRealGame` plays the recorded game
  // host_wins_1 (the game captures 19 and 20 play) from the view of seat 2.
  // This device is seat 2, so the tiles are Karim's own fixture counts for
  // that game, not Priya's.
  // ==========================================================================
  testWidgets('capture 23-rematch-ask-en', (tester) async {
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

    // Seat 2 (Karim), a guest who joins by the recorded code, in the recorded
    // game host_wins_1, which Priya (seat 0) wins.
    addTearDown(() {
      for (final RoomController c in factory.controllers) {
        c.dispose();
      }
    });
    final _RealReplay replay23 = await _replayRealGame(
      tester,
      factory,
      capture: 'capture 23-rematch-ask-en',
      gameName: 'host_wins_1',
      seat: 2,
      localeName: 'en',
    );
    final RoomController controller = replay23.controller;
    final FakeTransport transport = replay23.transport;
    final String hostName = replay23.game.nameOf(0);
    final String joinerName = replay23.game.nameOf(2);
    final String roomCode = replay23.roomCode;
    final int gameOverSeq23 = replay23.gameOverSeq;
    // The screen has absorbed every recorded frame before game_over. What it
    // counted from them must be the fixture's counts for this seat.
    final int scriptRolls23 = _scriptedRolls(controller, 2);
    final int scriptHome23 = _scriptedHome(controller, 2);
    expect(
      scriptRolls23,
      replay23.counts.rolls,
      reason:
          'capture 23: rolls the screen counted from the replayed frames '
          'must equal the fixture\'s counts (${replay23.describe})',
    );
    expect(
      scriptHome23,
      replay23.counts.home,
      reason:
          'capture 23: tokens home on the replayed board must equal the '
          'fixture\'s counts (${replay23.describe})',
    );

    // Priya (seat 0) wins the first game; I (seat 2, Karim) lose.
    replay23.pushGameOver();
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc23 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc23.endLoseTitle(hostName),
      momentDescription:
          'immediately after the game_over push landed, before Priya\'s '
          'own rematch ask arrives',
    );
    expect(
      find.byKey(const Key('end-card-lose')),
      findsOneWidget,
      reason:
          'capture 23 fixture is broken: seat 2 (Karim) must see the '
          'loser card before the rematch ask can be shown on top of it',
    );

    // Priya's own `rematch` lands as an unprompted push: a room LOBBY
    // naming seat 0 in `by`, with only seat 0 in `ready` -- I have not
    // answered yet.
    transport.pushText(
      _frame(
        type: 'room',
        data: <String, Object?>{
          ..._roomJson(
            code: roomCode,
            state: 'LOBBY',
            hostSeat: 0,
            players: 2,
            seats: <Map<String, Object?>>[
              _seatJson(0, name: hostName),
              _seatJson(2, name: joinerName),
            ],
            seq: gameOverSeq23 + 1,
          ),
          'rematch': <String, Object?>{
            'by': 0,
            'ready': <int>[0],
          },
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason:
          'C-246 rule 2: the rematch LOBBY stays on GameScreen, the route '
          'never goes back to the lobby screen',
    );
    final Finder askFinder23 = find.byKey(const Key('end-card-rematch-ask'));
    expect(
      askFinder23,
      findsOneWidget,
      reason:
          'expected end-card-rematch-ask on screen: seat 2 (Karim) is not '
          'yet in rematch.ready {0}',
    );
    expect(
      find.byKey(const Key('end-card-rematch-waiting')),
      findsNothing,
      reason:
          'end-card-rematch-waiting must not show before seat 2 has '
          'accepted',
    );

    await _pumpRealDurationFrames(tester);

    expect(
      find.byKey(const Key('end-card-rematch-ask')),
      findsOneWidget,
      reason:
          'capture 23: after the post-rematch-push settle, expected '
          'end-card-rematch-ask still on screen immediately before the '
          'capture',
    );
    _expectScriptedEndCardTiles(
      tester,
      capture: 'capture 23',
      rolls: replay23.counts.rolls,
      home: replay23.counts.home,
    );

    await _capture(binding, tester, '23-rematch-ask-en', frames: 0);
  });

  // ==========================================================================
  // 24: order 247's (C-246) rematch waiting line -- Priya (seat 0, the
  // host) taps her own end card's Rematch button and the server's reply
  // puts her alone in `rematch.ready`; Karim (seat 2) has not answered yet
  // (C-246 rule 4's "rematch LOBBY, my seat in ready" case), in Arabic.
  // Before `game_over`, `_replayRealGame` plays the recorded game host_wins_1
  // (the game captures 19 and 20 play) from the host's view. This device is
  // seat 0, so the tiles are Priya's own fixture counts for that game,
  // including her tokens home.
  // ==========================================================================
  testWidgets('capture 24-rematch-waiting-ar', (tester) async {
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

    // Seat 0 (Priya), the host, in the recorded game host_wins_1, which she wins.
    addTearDown(() {
      for (final RoomController c in factory.controllers) {
        c.dispose();
      }
    });
    final _RealReplay replay24 = await _replayRealGame(
      tester,
      factory,
      capture: 'capture 24-rematch-waiting-ar',
      gameName: 'host_wins_1',
      seat: 0,
      localeName: 'ar',
    );
    final RoomController controller = replay24.controller;
    final FakeTransport transport = replay24.transport;
    final String hostName = replay24.game.nameOf(0);
    final String roomCode = replay24.roomCode;
    final int gameOverSeq24 = replay24.gameOverSeq;
    // The screen has absorbed every recorded frame before game_over. What it
    // counted from them must be the fixture's counts for this seat.
    final int scriptRolls24 = _scriptedRolls(controller, 0);
    final int scriptHome24 = _scriptedHome(controller, 0);
    expect(
      scriptRolls24,
      replay24.counts.rolls,
      reason:
          'capture 24: rolls the screen counted from the replayed frames '
          'must equal the fixture\'s counts (${replay24.describe})',
    );
    expect(
      scriptHome24,
      replay24.counts.home,
      reason:
          'capture 24: tokens home on the replayed board must equal the '
          'fixture\'s counts (${replay24.describe})',
    );

    // My own seat (0, Priya) is named winner by the recorded game_over.
    replay24.pushGameOver();
    await tester.pump();
    await tester.pump();

    final AppLocalizations loc24 = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc24.localeName,
      'ar',
      reason: 'capture 24 fixture is broken: this case must be in Arabic',
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 0,
      expectedText: loc24.endWinTitle,
      momentDescription:
          'immediately after the game_over push landed, before Priya taps '
          'her own end-card-rematch',
    );

    final Finder rematchFinder24 = find.byKey(const Key('end-card-rematch'));
    expect(
      rematchFinder24,
      findsOneWidget,
      reason:
          'capture 24 fixture is broken: end-card-rematch must be on a '
          'finished end card before it can be tapped',
    );
    await tester.tap(rematchFinder24);
    await tester.pump();

    final List<String> rematchMessages24 = transport.sentRaw
        .where((s) => _typeOf(s) == 'rematch')
        .toList();
    expect(
      rematchMessages24,
      hasLength(1),
      reason:
          'tapping end-card-rematch must send exactly one rematch frame; '
          'sent ${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String rematchReqId24 = _idOf(rematchMessages24.single);

    // The server's reply: Priya's own seat (0) is now in ready; Karim (2)
    // has not answered.
    transport.pushText(
      _frame(
        type: 'room',
        re: rematchReqId24,
        data: <String, Object?>{
          ..._roomJson(
            code: roomCode,
            state: 'LOBBY',
            hostSeat: 0,
            players: 2,
            seats: <Map<String, Object?>>[
              _seatJson(0, name: hostName),
              _seatJson(2, name: 'Karim'),
            ],
            seq: gameOverSeq24 + 1,
          ),
          'rematch': <String, Object?>{
            'by': 0,
            'ready': <int>[0],
          },
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason:
          'C-246 rule 2: the rematch LOBBY stays on GameScreen, the route '
          'never goes back to the lobby screen',
    );
    final Finder waitingFinder24 = find.byKey(
      const Key('end-card-rematch-waiting'),
    );
    expect(
      waitingFinder24,
      findsOneWidget,
      reason:
          'expected end-card-rematch-waiting on screen: Priya\'s own seat '
          '(0) is in rematch.ready',
    );
    expect(
      find.byKey(const Key('end-card-rematch')),
      findsNothing,
      reason: 'end-card-rematch must not render once Priya is ready',
    );
    expect(
      find.byKey(const Key('end-card-ready-0')),
      findsOneWidget,
      reason: 'end-card-ready-0 must exist for occupied seat 0',
    );
    expect(
      find.byKey(const Key('end-card-ready-2')),
      findsOneWidget,
      reason: 'end-card-ready-2 must exist for occupied seat 2',
    );

    await _pumpRealDurationFrames(tester);

    expect(
      find.byKey(const Key('end-card-rematch-waiting')),
      findsOneWidget,
      reason:
          'capture 24: after the post-rematch-reply settle, expected '
          'end-card-rematch-waiting still on screen immediately before '
          'the capture',
    );
    _expectScriptedEndCardTiles(
      tester,
      capture: 'capture 24',
      rolls: replay24.counts.rolls,
      home: replay24.counts.home,
    );

    await _capture(binding, tester, '24-rematch-waiting-ar', frames: 0);
  });

  // ==========================================================================
  // 25, 26: order 309, replayed from a recorded game by order 580. The
  // device is seat 0 (Priya) in guest_wins_1, which Karim (seat 2) wins, and
  // it loses as in captures 21 and 22. The recorded frames reach it
  // verbatim up to the first turn handed to seat 2 at or after the middle of
  // the view, and the socket drops the way capture 10 drops one. The
  // controller reconnects on a second transport and sends resume; the
  // answer is the room folded from the recorded frames up to the winner's
  // last turn, so its seq is ahead of the last frame this client saw and the
  // rolls between are a hole. Karim's last roll and move then arrive live
  // (the roll thrown, the walk landed), and the recorded game_over follows,
  // so the local transcript cannot fill the stat tiles. The client asks for
  // game_log; the rig answers with the recorded parts, and the capture is the
  // end card after that answer, its four tiles Priya's fixture counts.
  // ==========================================================================
  testWidgets('capture 25-end-reconnect-loser-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ReconnectCaptureFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'en');

    await _captureReconnectLoser(
      tester,
      binding,
      factory: factory,
      localeName: 'en',
      shotName: '25-end-reconnect-loser-en',
    );
  });

  // 26: capture 25's Arabic twin, mounted directly in Arabic the same way
  // capture 22 is.
  testWidgets('capture 26-end-reconnect-loser-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    final factory = _ReconnectCaptureFactory();
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: const Locale('ar'),
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: 'ar');

    await _captureReconnectLoser(
      tester,
      binding,
      factory: factory,
      localeName: 'ar',
      shotName: '26-end-reconnect-loser-ar',
    );
  });

  // ==========================================================================
  // 27, 28: contract C-316 rule 2 (departed seats on the end card). A 3-seat
  // game finishes; this device is seat 1 (Karim) and loses, with seat 0
  // (Priya) winning. Seat 2 (Lina) then leaves: player_left naming seat 2,
  // followed by the room frame with seat 2 removed. end-card-left shows
  // endLeft with Lina's name, Play again stays visible, and the verify
  // button remains shown.
  // ==========================================================================
  testWidgets('capture 27-end-friend-left-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureFriendLeft(
      tester,
      binding,
      locale: const Locale('en'),
      roomCode: 'SHOT27',
      verifyUrl: 'https://verify.example.invalid/shot27',
      shotName: '27-end-friend-left-en',
    );
  });

  // 28: capture 27's Arabic twin, mounted directly in Arabic.
  testWidgets('capture 28-end-friend-left-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureFriendLeft(
      tester,
      binding,
      locale: const Locale('ar'),
      roomCode: 'SHOT28',
      verifyUrl: 'https://verify.example.invalid/shot28',
      shotName: '28-end-friend-left-ar',
    );
  });

  // ==========================================================================
  // 29: contract C-316 rule 2. A 2-seat game finishes; this device is seat
  // 1 (Karim) and loses, with seat 0 (Priya) winning. Seat 0 then leaves:
  // player_left naming seat 0, followed by the room frame leaving only this
  // device. end-card-left reads endEveryoneLeft, Play again is gone, and
  // New table is shown as primary.
  // ==========================================================================
  testWidgets('capture 29-end-everyone-left-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureEveryoneLeft(
      tester,
      binding,
      locale: const Locale('en'),
      roomCode: 'SHOT29',
      verifyUrl: 'https://verify.example.invalid/shot29',
      shotName: '29-end-everyone-left-en',
    );
  });

  // ==========================================================================
  // 30, 31: contract C-316 rule 4 (offline on the end card). A 2-seat game
  // (seats 0 and 2) finishes; this device is seat 2 (Karim) and loses. The transport drops
  // from the far side with automatic reconnect not yet fired. The end card
  // stays up showing end-card-offline, no connection-lost card is shown, and
  // the verify button remains shown and hit-testable.
  // ==========================================================================
  testWidgets('capture 30-end-offline-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureEndOffline(
      tester,
      binding,
      locale: const Locale('ar'),
      roomCode: 'SHOT30',
      verifyUrl: 'https://verify.example.invalid/shot30',
      shotName: '30-end-offline-ar',
    );
  });

  // 31: capture 30's English twin.
  testWidgets('capture 31-end-offline-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureEndOffline(
      tester,
      binding,
      locale: const Locale('en'),
      roomCode: 'SHOT31',
      verifyUrl: 'https://verify.example.invalid/shot31',
      shotName: '31-end-offline-en',
    );
  });

  // ==========================================================================
  // 32: contract C-316 rule 3 (removed by a forced start). This device is in
  // a rematch LOBBY on GameScreen after a finished game, and receives
  // player_left naming its own seat. The route pops back to HomeScreen, which
  // displays home-removed-notice. Captured on HomeScreen in Arabic.
  // ==========================================================================
  testWidgets('capture 32-home-removed-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureHomeRemoved(
      tester,
      binding,
      locale: const Locale('ar'),
      roomCode: 'SHOT32',
      shotName: '32-home-removed-ar',
    );
  });

  // ==========================================================================
  // 61, 62: contract C-449 D5 (the Home notice reads as news). Home after a
  // refused resume (C-447 D4): a legacy seat record (no saved time) shows
  // the Back to game button, a tap on it is answered NO_SUCH_ROOM, the
  // lobby route pops, and Home shows home-game-gone-notice in its card. The
  // same rig as capture 32 (FakeTransport under a real RoomController,
  // frames pushed by hand), reached through a resume instead of a forced
  // start.
  // ==========================================================================
  testWidgets('capture 61-home-game-gone-en', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureHomeGameGone(
      tester,
      binding,
      locale: const Locale('en'),
      roomCode: 'GKQ6ZA',
      shotName: '61-home-game-gone-en',
    );
  });

  testWidgets('capture 62-home-game-gone-ar', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    await _captureHomeGameGone(
      tester,
      binding,
      locale: const Locale('ar'),
      roomCode: 'GKQ7ZA',
      shotName: '62-home-game-gone-ar',
    );
  });

  // ==========================================================================
  // 33, 34: contract C-322 (the last game's verify link on home). Fresh
  // store seeded with last-create defaults (a name and 4 seats, so the
  // last-table chip shows), two recent codes through recordSuccessfulJoin,
  // and recordLastGame with a game finished 2 hours ago. Scrolled with
  // tester.ensureVisible so home-last-game is fully on screen, in English
  // and Arabic.
  // ==========================================================================
  testWidgets('capture 33-home-last-game-en, 34-home-last-game-ar', (
    tester,
  ) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    await (await SharedPreferences.getInstance()).clear();

    const String hostName = 'Priya';
    const int hostSeats = 4;
    await SessionMemory.recordSuccessfulCreate(
      name: hostName,
      seats: hostSeats,
    );
    await SessionMemory.recordSuccessfulJoin('PLAY42');
    await SessionMemory.recordSuccessfulJoin('K7M2QP');

    const String gameId = 'g-shot33-home';
    final DateTime finishedAt = DateTime.now().subtract(
      const Duration(hours: 2),
    );
    await SessionMemory.recordLastGame(
      LastGame(
        gameId: gameId,
        verifyUrl: 'https://provefair.app/v/$gameId',
        finishedAt: finishedAt,
        won: false,
      ),
    );

    final factory = _ScreenshotControllerFactory();
    await tester.pumpWidget(
      _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();

    final Finder homeLastGameFinder = find.byKey(const Key('home-last-game'));
    await tester.ensureVisible(homeLastGameFinder);
    await tester.pumpAndSettle();

    final AppLocalizations enHomeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    final String enLastGameText = enHomeLoc.homeLastGame;
    await _settleForScreenshot(
      tester,
      find.text(enLastGameText),
      'the English homeLastGame text ("$enLastGameText") laid out on the '
      'home screen before capture 33',
    );
    await _expectHomeScreen(tester, localeName: 'en');
    expect(
      homeLastGameFinder,
      findsOneWidget,
      reason:
          'capture 33-home-last-game-en: expected home-last-game on screen '
          'before the shot',
    );
    expect(
      find.byKey(const Key('home-last-game-check')),
      findsOneWidget,
      reason:
          'capture 33-home-last-game-en: expected home-last-game-check on '
          'screen before the shot',
    );
    expect(
      find.text(enLastGameText),
      findsOneWidget,
      reason:
          'capture 33-home-last-game-en: expected homeLastGame '
          '("$enLastGameText") text on screen before the shot',
    );
    await _capture(binding, tester, '33-home-last-game-en', frames: 0);

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(homeLastGameFinder);
    await tester.pumpAndSettle();

    final AppLocalizations arHomeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    final String arLastGameText = arHomeLoc.homeLastGame;
    await _settleForScreenshot(
      tester,
      find.text(arLastGameText),
      'the Arabic homeLastGame text ("$arLastGameText") laid out on the '
      'home screen after the locale toggle, before capture 34',
    );
    await _expectHomeScreen(tester, localeName: 'ar');
    expect(
      homeLastGameFinder,
      findsOneWidget,
      reason:
          'capture 34-home-last-game-ar: expected home-last-game on screen '
          'before the shot',
    );
    expect(
      find.byKey(const Key('home-last-game-check')),
      findsOneWidget,
      reason:
          'capture 34-home-last-game-ar: expected home-last-game-check on '
          'screen before the shot',
    );
    expect(
      find.text(arLastGameText),
      findsOneWidget,
      reason:
          'capture 34-home-last-game-ar: expected homeLastGame '
          '("$arLastGameText") text on screen before the shot',
    );
    await _capture(binding, tester, '34-home-last-game-ar', frames: 0);
  });

  // ==========================================================================
  // 37-40: order 342, follow-up to X48 (C-339, order 339). C-339 proved the
  // game screen holds system text scale 1.3 and 2.0 in
  // test/large_text_fit_test.dart, but that file mounts GameScreen directly
  // over a hand-held RoomController, never through this rig's own
  // HomeScreen -> RoomRoute -> LobbyScreen -> RoomRoute (latched) ->
  // GameScreen route, and it never touches LobbyScreen or the end card at
  // all. These four captures put the large-text game screen, the
  // large-text lobby and the large-text end card in front of the master
  // for the first time, staged the way captures 03/04/22 already are (same
  // harness, _stubScreenshotChannel, convertFlutterSurfaceToImage, cleared
  // SharedPreferences, the same bounded-pump idioms in place of
  // pumpAndSettle past the point a ticker has mounted), the only
  // differences being system text scale 2.0 for the whole case and two
  // renamed seats throughout: the host is Karim12345, the seat beside them
  // is Samantha12 -- both 10 characters, both accepted by the server's
  // 1-24 character limit (packages/ludo_server/lib/src/registry.dart:
  // 411-412), the same pair test/large_text_fit_test.dart itself uses for
  // X48.
  //
  // System text scale 2.0 is set once, through the test platform
  // dispatcher (tester.platformDispatcher.textScaleFactorTestValue), per
  // the order -- not a hand-made MediaQuery wrapped around the app.
  // Measured below (capture 37's own scale assertion) to actually reach
  // the mounted tree's MediaQuery.textScalerOf before relying on it for
  // the rest of the case. Cleared explicitly in the body, right after the
  // last capture, and again in addTearDown as a backstop if the body
  // throws first.
  //
  // Each of the four captures below mounts its own HomeScreen and its own
  // RoomController (through a fresh _ScreenshotControllerFactory), the way
  // every other multi-capture block in this file mounts one continuous
  // flow per testWidgets -- except here the four flows are independent
  // (different screens, alternating locales), so each one's controller is
  // retired with an explicit dispose() in a finally block, immediately
  // after that capture's own screenshot, the same "this screen created it,
  // this screen retires it" rule home_screen.dart's own _createRoom
  // follows -- rather than deferred to this test's own addTearDown, which
  // runs once, after all four, and only for whichever controller is still
  // live when the body throws.
  //
  // Capture 39 ("the same two names seated") is staged with exactly two
  // seats full (players: 2), not capture 03's own three: capture 03 seats
  // a third joiner (Lina) the order's own wording for 39 never mentions,
  // and "the same two names seated" reads as a closed list of exactly the
  // two names this block uses, not a partial rename of capture 03's three
  // seats. Flagged here and in the final report as a judgement call on an
  // order that could be read either way, not invented around silently.
  // ==========================================================================
  testWidgets('capture 37-40 large text', (tester) async {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();

    // The whole case runs at this scale; cleared explicitly below, before
    // the case ends, and again here through addTearDown as a backstop if
    // an assertion throws first.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const String hostName = 'Karim12345';
    const String otherName = 'Samantha12';

    // The same five moved pushes capture 04 sends, reused for both 37 and
    // 38 so each shows tokens spread around the track instead of the
    // opening position. [transport] and [seq] are explicit per call, not
    // closed over, so this is safe to call across two different fixtures.
    void pushMoved(
      FakeTransport transport, {
      required int seat,
      required int token,
      required int from,
      required int to,
      required int seq,
    }) {
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

    // ------------------------------------------------------------------
    // 37: game screen, English, host's turn. Staged like capture 04: host
    // seat 0, three seated, the same five pushed moves.
    // ------------------------------------------------------------------
    await (await SharedPreferences.getInstance()).clear();
    final factory37 = _ScreenshotControllerFactory();
    RoomController? controller37;
    try {
      await tester.pumpWidget(
        _ScreenshotHarness(controllerFactory: factory37.call),
      );
      await tester.pumpAndSettle();
      await _expectHomeScreen(tester, localeName: 'en');

      const String roomCode37 = 'SHOT37';
      await tester.enterText(
        find.byKey(const Key('home-name-field')),
        hostName,
      );
      await _tapCreateRoom(tester);

      expect(
        factory37.controllers,
        hasLength(1),
        reason:
            'capture 37: tapping Create Room must build exactly one '
            'controller through the injected controllerFactory '
            '(home_screen.dart)',
      );
      controller37 = factory37.controllers.single;
      final FakeTransport transport37 = factory37.transports.single;

      final List<String> createMessages37 = transport37.sentRaw
          .where((s) => _typeOf(s) == 'create_room')
          .toList();
      expect(
        createMessages37,
        hasLength(1),
        reason:
            'capture 37: expected LobbyScreen.initState, reached through '
            'RoomRoute, to have sent exactly one create_room request; '
            'sent ${transport37.sentRaw.map(_typeOf).toList()}',
      );
      final String createId37 = _idOf(createMessages37.single);

      transport37.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-37'},
        ),
      );
      transport37.pushText(
        _frame(
          type: 'room',
          re: createId37,
          data: _roomJson(
            code: roomCode37,
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
        'capture 37: LobbyScreen after the create_room reply carrying '
        'code "$roomCode37"',
      );

      transport37.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 1, 'name': otherName, 'seq': 2},
        ),
      );
      await tester.pump();
      transport37.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 2, 'name': 'Lina', 'seq': 3},
        ),
      );
      await tester.pump();

      await _expectLobbyScreen(
        tester,
        localeName: 'en',
        code: roomCode37,
        expectedSeatCount: 3,
      );

      final Finder startButton37 = find.byKey(const Key('lobby-start-button'));
      expect(
        startButton37,
        findsOneWidget,
        reason:
            'capture 37: the host, seat 0, must see a Start button once '
            'seated',
      );
      // At system text scale 2.0 the lobby's SingleChildScrollView can
      // grow past the viewport, carrying lobby-start-button off the
      // visible frame; scroll it fully into view (Scrollable.ensureVisible
      // defaults to an instant jump, no animation to wait out) before
      // tapping, the same way this file's own capture 33/34 block scrolls
      // home-last-game into view.
      await tester.ensureVisible(startButton37);
      await tester.pump();
      await tester.tap(startButton37);
      await tester.pump();
      final List<String> startMessages37 = transport37.sentRaw
          .where((s) => _typeOf(s) == 'start_game')
          .toList();
      expect(
        startMessages37,
        hasLength(1),
        reason:
            'capture 37: tapping lobby-start-button must send exactly '
            'one start_game',
      );
      final String startId37 = _idOf(startMessages37.single);

      transport37.pushText(
        _frame(
          type: 'game_started',
          re: startId37,
          data: <String, Object?>{
            'turn': 0,
            'game_id': 'p' * 16,
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
        'capture 37: GameScreen after the game_started push answering '
        'start_game',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason:
            'capture 37: RoomRoute must latch onto GameScreen and never '
            'go back',
      );

      pushMoved(transport37, seat: 0, token: 0, from: -1, to: 6, seq: 5);
      await tester.pump();
      pushMoved(transport37, seat: 0, token: 1, from: -1, to: 19, seq: 6);
      await tester.pump();
      pushMoved(transport37, seat: 1, token: 0, from: -1, to: 12, seq: 7);
      await tester.pump();
      pushMoved(transport37, seat: 2, token: 0, from: -1, to: 30, seq: 8);
      await tester.pump();
      pushMoved(transport37, seat: 1, token: 1, from: -1, to: 44, seq: 9);
      await tester.pump();

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('game-screen-board')),
        'capture 37: the game board after the mid-game moved pushes',
      );

      await _expectGameScreenMidGame(
        tester,
        localeName: 'en',
        controller: controller37,
      );
      expect(
        controller37.room!.turn!.seat,
        0,
        reason:
            'capture 37: fixture must leave the turn on seat 0 (the '
            'host, $hostName) straight from the game_started push above; '
            'got seat ${controller37.room!.turn!.seat}',
      );

      final Finder banner37 = find.byKey(const Key('game-screen-turn-banner'));
      expect(
        banner37,
        findsOneWidget,
        reason:
            'capture 37: expected game-screen-turn-banner on screen '
            'before the shot',
      );
      final double scaledTen37 = MediaQuery.textScalerOf(
        tester.element(banner37),
      ).scale(10);
      expect(
        scaledTen37,
        20.0,
        reason:
            'capture 37: expected MediaQuery.textScalerOf at '
            'game-screen-turn-banner to scale 10 to 20 under '
            'tester.platformDispatcher.textScaleFactorTestValue = 2.0, '
            'got $scaledTen37 -- if this is not 20.0, the test platform '
            'dispatcher setter is not reaching this tree\'s own '
            'MediaQuery.textScalerOf',
      );
      expect(
        find.byKey(const Key('board-seat-you')),
        findsOneWidget,
        reason:
            'capture 37: expected board-seat-you on screen before the '
            'shot',
      );

      await _capture(
        binding,
        tester,
        '37-game-large-en',
        untilGone: _keysStartingWith('board-safe-cue-'),
      );
    } finally {
      controller37?.dispose();
    }

    // ------------------------------------------------------------------
    // 38: capture 37's Arabic twin, another seat's turn (seat 1,
    // $otherName) so the banner reads the waiting line.
    // ------------------------------------------------------------------
    await (await SharedPreferences.getInstance()).clear();
    final factory38 = _ScreenshotControllerFactory();
    RoomController? controller38;
    try {
      await tester.pumpWidget(
        _reconnectingCaptureHarness(
          HomeScreen(controllerFactory: factory38.call, onToggleLocale: () {}),
          locale: const Locale('ar'),
        ),
      );
      await tester.pumpAndSettle();
      await _expectHomeScreen(tester, localeName: 'ar');

      const String roomCode38 = 'SHOT38';
      await tester.enterText(
        find.byKey(const Key('home-name-field')),
        hostName,
      );
      await _tapCreateRoom(tester);

      expect(
        factory38.controllers,
        hasLength(1),
        reason:
            'capture 38: tapping Create Room must build exactly one '
            'controller through the injected controllerFactory '
            '(home_screen.dart)',
      );
      controller38 = factory38.controllers.single;
      final FakeTransport transport38 = factory38.transports.single;

      final List<String> createMessages38 = transport38.sentRaw
          .where((s) => _typeOf(s) == 'create_room')
          .toList();
      expect(
        createMessages38,
        hasLength(1),
        reason:
            'capture 38: expected LobbyScreen.initState, reached through '
            'RoomRoute, to have sent exactly one create_room request; '
            'sent ${transport38.sentRaw.map(_typeOf).toList()}',
      );
      final String createId38 = _idOf(createMessages38.single);

      transport38.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-38'},
        ),
      );
      transport38.pushText(
        _frame(
          type: 'room',
          re: createId38,
          data: _roomJson(
            code: roomCode38,
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
        'capture 38: LobbyScreen after the create_room reply carrying '
        'code "$roomCode38"',
      );

      transport38.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 1, 'name': otherName, 'seq': 2},
        ),
      );
      await tester.pump();
      transport38.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 2, 'name': 'Lina', 'seq': 3},
        ),
      );
      await tester.pump();

      await _expectLobbyScreen(
        tester,
        localeName: 'ar',
        code: roomCode38,
        expectedSeatCount: 3,
      );

      final Finder startButton38 = find.byKey(const Key('lobby-start-button'));
      expect(
        startButton38,
        findsOneWidget,
        reason:
            'capture 38: the host, seat 0, must see a Start button once '
            'seated',
      );
      // See capture 37's own matching comment: scroll lobby-start-button
      // into view before tapping it.
      await tester.ensureVisible(startButton38);
      await tester.pump();
      await tester.tap(startButton38);
      await tester.pump();
      final List<String> startMessages38 = transport38.sentRaw
          .where((s) => _typeOf(s) == 'start_game')
          .toList();
      expect(
        startMessages38,
        hasLength(1),
        reason:
            'capture 38: tapping lobby-start-button must send exactly '
            'one start_game',
      );
      final String startId38 = _idOf(startMessages38.single);

      transport38.pushText(
        _frame(
          type: 'game_started',
          re: startId38,
          data: <String, Object?>{
            'turn': 0,
            'game_id': 'q' * 16,
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
        'capture 38: GameScreen after the game_started push answering '
        'start_game',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason:
            'capture 38: RoomRoute must latch onto GameScreen and never '
            'go back',
      );

      pushMoved(transport38, seat: 0, token: 0, from: -1, to: 6, seq: 5);
      await tester.pump();
      pushMoved(transport38, seat: 0, token: 1, from: -1, to: 19, seq: 6);
      await tester.pump();
      pushMoved(transport38, seat: 1, token: 0, from: -1, to: 12, seq: 7);
      await tester.pump();
      pushMoved(transport38, seat: 2, token: 0, from: -1, to: 30, seq: 8);
      await tester.pump();
      pushMoved(transport38, seat: 1, token: 1, from: -1, to: 44, seq: 9);
      await tester.pump();

      await _pumpUntilFound(
        tester,
        find.byKey(const Key('game-screen-board')),
        'capture 38: the game board after the mid-game moved pushes',
      );

      await _expectGameScreenMidGame(
        tester,
        localeName: 'ar',
        controller: controller38,
      );

      transport38.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{'seat': 1, 'deadline_ms': 45000, 'seq': 10},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        controller38.room!.turn!.seat,
        1,
        reason:
            'capture 38: pushed a turn frame naming seat 1 ($otherName); '
            'expected controller.room!.turn!.seat to read 1 before the '
            'shot, got ${controller38.room!.turn!.seat}',
      );

      final AppLocalizations arGameLoc38 = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      final String expectedBanner38 = arGameLoc38.gameWaitingForPlayer(
        otherName,
      );
      final Text bannerText38 = tester.widget<Text>(
        find.byKey(const Key('game-screen-turn-banner')),
      );
      expect(
        bannerText38.data,
        expectedBanner38,
        reason:
            'capture 38: expected game-screen-turn-banner to read the '
            'waiting-for-$otherName string ("$expectedBanner38") before '
            'the shot, got "${bannerText38.data}"',
      );

      await _capture(
        binding,
        tester,
        '38-game-large-ar',
        untilGone: _keysStartingWith('board-safe-cue-'),
      );
    } finally {
      controller38?.dispose();
    }

    // ------------------------------------------------------------------
    // 39: the host's lobby, English. Staged the way capture 03 stages a
    // lobby -- a real server-issued code, real joined players, no bare
    // pumpAndSettle once LobbyScreen has mounted -- with exactly the two
    // names this block uses throughout and no third, unnamed joiner (see
    // this block's own header comment above for why).
    // ------------------------------------------------------------------
    await (await SharedPreferences.getInstance()).clear();
    final factory39 = _ScreenshotControllerFactory();
    RoomController? controller39;
    try {
      await tester.pumpWidget(
        _ScreenshotHarness(controllerFactory: factory39.call),
      );
      await tester.pumpAndSettle();
      await _expectHomeScreen(tester, localeName: 'en');

      const String roomCode39 = 'SHOT39';
      await tester.enterText(
        find.byKey(const Key('home-name-field')),
        hostName,
      );
      await _tapCreateRoom(tester);

      expect(
        factory39.controllers,
        hasLength(1),
        reason:
            'capture 39: tapping Create Room must build exactly one '
            'controller through the injected controllerFactory '
            '(home_screen.dart)',
      );
      controller39 = factory39.controllers.single;
      final FakeTransport transport39 = factory39.transports.single;

      final List<String> createMessages39 = transport39.sentRaw
          .where((s) => _typeOf(s) == 'create_room')
          .toList();
      expect(
        createMessages39,
        hasLength(1),
        reason:
            'capture 39: expected LobbyScreen.initState, reached through '
            'RoomRoute, to have sent exactly one create_room request; '
            'sent ${transport39.sentRaw.map(_typeOf).toList()}',
      );
      final String createId39 = _idOf(createMessages39.single);

      transport39.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-39'},
        ),
      );
      transport39.pushText(
        _frame(
          type: 'room',
          re: createId39,
          data: _roomJson(
            code: roomCode39,
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
        'capture 39: LobbyScreen after the create_room reply carrying '
        'code "$roomCode39"',
      );

      transport39.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': 2, 'name': otherName, 'seq': 2},
        ),
      );
      await tester.pump();

      await _expectLobbyScreen(
        tester,
        localeName: 'en',
        code: roomCode39,
        expectedSeatCount: 2,
      );

      // Same audit as capture 03: no bare pumpAndSettle past this point
      // (LobbyScreen's connecting-state ticker never settles), so the
      // frame is held open for real wall time instead, then everything
      // the capture depends on is re-read immediately before the shot.
      await _pumpRealDurationFrames(tester);

      await _expectLobbyScreen(
        tester,
        localeName: 'en',
        code: roomCode39,
        expectedSeatCount: 2,
      );
      final AppLocalizations settledLobbyLoc39 = AppLocalizations.of(
        tester.element(find.byType(LobbyScreen)),
      );
      final Finder settledStartButton39 = find.byKey(
        const Key('lobby-start-button'),
      );
      expect(
        settledStartButton39,
        findsOneWidget,
        reason:
            'capture 39: after the post-join settle, expected the '
            'host\'s Start button still on screen immediately before '
            'the shot',
      );
      final ElevatedButton settledStartWidget39 = tester.widget<ElevatedButton>(
        settledStartButton39,
      );
      final Text settledStartLabel39 = settledStartWidget39.child! as Text;
      expect(
        settledStartLabel39.data,
        settledLobbyLoc39.lobbyStartButton,
        reason:
            'capture 39: after the post-join settle, the room is full '
            '(2 of 2 seats joined) so expected lobby-start-button\'s '
            'label to still read loc.lobbyStartButton '
            '("${settledLobbyLoc39.lobbyStartButton}"), got '
            '"${settledStartLabel39.data}"',
      );

      await _capture(binding, tester, '39-lobby-large-en', frames: 0);
    } finally {
      controller39?.dispose();
    }

    // ------------------------------------------------------------------
    // 40: capture 22's own Arabic end card, replayed from the same recorded
    // game and view (guest_wins_1, seat 0: Priya loses to Karim), at this
    // block's system text scale 2.0. The frames name Priya and Karim, so the
    // block's long names do not reach this card.
    // ------------------------------------------------------------------
    await (await SharedPreferences.getInstance()).clear();
    final factory40 = _ScreenshotControllerFactory();
    try {
      await tester.pumpWidget(
        _reconnectingCaptureHarness(
          HomeScreen(controllerFactory: factory40.call, onToggleLocale: () {}),
          locale: const Locale('ar'),
        ),
      );
      await tester.pumpAndSettle();
      await _expectHomeScreen(tester, localeName: 'ar');

      // Seat 0 (Priya), the host, in the recorded game guest_wins_1, as
      // capture 22: Karim (seat 2) wins it. The device types the recorded
      // names, so this card names Priya and Karim, not the long pair the
      // rest of this block uses.
      final _RealReplay replay40 = await _replayRealGame(
        tester,
        factory40,
        capture: 'capture 37-40 large text',
        gameName: 'guest_wins_1',
        seat: 0,
        localeName: 'ar',
      );
      final RoomController controller40 = replay40.controller;
      final String winnerName40 = replay40.game.nameOf(2);

      // The other seat (2) is named winner by the recorded game_over.
      replay40.pushGameOver();
      await tester.pump();
      await tester.pump();

      final AppLocalizations loc40 = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        loc40.localeName,
        'ar',
        reason: 'capture 40 fixture is broken: this case must be in Arabic',
      );
      _expectGameOverWinnerText(
        tester,
        controller: controller40,
        expectedWinner: 2,
        expectedText: loc40.endLoseTitle(winnerName40),
        momentDescription:
            'capture 40: immediately after the game_over push landed, '
            'before the post-game-over settle',
      );

      await _pumpRealDurationFrames(tester);

      _expectGameOverWinnerText(
        tester,
        controller: controller40,
        expectedWinner: 2,
        expectedText: loc40.endLoseTitle(winnerName40),
        momentDescription:
            'capture 40: after the post-game-over settle, immediately '
            'before the shot',
      );
      // The four tiles show the fixture's counts for this device's seat in
      // the recorded game, read at run time; a count of 0 means the tile is
      // absent (C-533 D3).
      _expectEndCardStatTiles(
        tester,
        rolls: replay40.counts.rolls,
        sixes: replay40.counts.sixes,
        captures: replay40.counts.captures,
        home: replay40.counts.home,
        momentDescription:
            'capture 40: after the post-game-over settle, immediately '
            'before the shot '
            '(${replay40.describe}; ${replay40.counts})',
      );

      await _capture(binding, tester, '40-end-loser-large-ar', frames: 0);
    } finally {
      for (final RoomController c in factory40.controllers) {
        c.dispose();
      }
    }

    // The whole case's own scale, cleared here, in the body, before the
    // case ends -- not only in the addTearDown registered above.
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  // ==========================================================================
  // 41-44: order 369. Emulator frames of the roll tray. Same route as
  // captures 15 and 16, over FakeTransport. Queue frames are copied from
  // test/roll_tray_test.dart; this file cannot import test/. Bodies live
  // at the bottom of the file. No pumpAndSettle once GameScreen is up.
  // ==========================================================================
  testWidgets('capture 41-game-tray-en', (tester) async {
    await _shootLiveTray(
      tester,
      binding,
      shotName: '41-game-tray-en',
      locale: const Locale('en'),
      roomCode: 'SHOT41',
      gameId: 's' * 16,
      seatToken: 'tok-shot-41',
    );
  });

  testWidgets('capture 42-game-tray-ar', (tester) async {
    await _shootLiveTray(
      tester,
      binding,
      shotName: '42-game-tray-ar',
      locale: const Locale('ar'),
      roomCode: 'SHOT42',
      gameId: 't' * 16,
      seatToken: 'tok-shot-42',
    );
  });

  testWidgets('capture 43-game-tray-pick-en', (tester) async {
    await _shootPickedTray(
      tester,
      binding,
      shotName: '43-game-tray-pick-en',
      locale: const Locale('en'),
      roomCode: 'SHOT43',
      gameId: 'u' * 16,
      seatToken: 'tok-shot-43',
    );
  });

  testWidgets('capture 63-game-tray-pick-ar', (tester) async {
    await _shootPickedTray(
      tester,
      binding,
      shotName: '63-game-tray-pick-ar',
      locale: const Locale('ar'),
      roomCode: 'SHOT63',
      gameId: 'j' * 16,
      seatToken: 'tok-shot-63',
    );
  });

  testWidgets('capture 44-game-tray-dead-ar', (tester) async {
    await _shootDeadTray(tester, binding);
  });

  // ==========================================================================
  // 45-48: order 375. One 2-player room, seats [0, 2], from each seat, in
  // each locale. Seat 0 to roll. Each seat's token 0 is in its yard and
  // its token 1 is on the track. The yard quarters are asserted immediately
  // before the shot. Bodies live at the bottom of the file. No
  // pumpAndSettle once GameScreen is up.
  // ==========================================================================
  testWidgets('capture 45-view-seat0-en', (tester) async {
    await _shootViewerBoard(
      tester,
      binding,
      shotName: '45-view-seat0-en',
      locale: const Locale('en'),
      mySeat: 0,
      roomCode: 'SHOT45',
      gameId: 'w' * 16,
      seatToken: 'tok-shot-45',
    );
  });

  testWidgets('capture 46-view-seat2-en', (tester) async {
    await _shootViewerBoard(
      tester,
      binding,
      shotName: '46-view-seat2-en',
      locale: const Locale('en'),
      mySeat: 2,
      roomCode: 'VW46EN',
      gameId: 'x' * 16,
      seatToken: 'tok-shot-46',
    );
  });

  testWidgets('capture 47-view-seat0-ar', (tester) async {
    await _shootViewerBoard(
      tester,
      binding,
      shotName: '47-view-seat0-ar',
      locale: const Locale('ar'),
      mySeat: 0,
      roomCode: 'SHOT47',
      gameId: 'y' * 16,
      seatToken: 'tok-shot-47',
    );
  });

  testWidgets('capture 48-view-seat2-ar', (tester) async {
    await _shootViewerBoard(
      tester,
      binding,
      shotName: '48-view-seat2-ar',
      locale: const Locale('ar'),
      mySeat: 2,
      roomCode: 'VW48AR',
      gameId: 'z' * 16,
      seatToken: 'tok-shot-48',
    );
  });

  // ==========================================================================
  // 49-52: order 431. Emulator frames of C-426's two timer-played notices
  // (work/ludo/orders/C-426-timer-played-says-so.md, D3-D5, D9). Same route
  // as captures 41-42: a GameScreen over FakeTransport, no server, no
  // pumpAndSettle once GameScreen is up. Frame shapes are copied by hand
  // from test/timer_played_notice_test.dart (read-only). Bodies live at the
  // bottom of the file.
  // ==========================================================================
  testWidgets('capture 49-timer-played-mine-en', (tester) async {
    await _shootTimerPlayedMine(
      tester,
      binding,
      shotName: '49-timer-played-mine-en',
      locale: const Locale('en'),
      roomCode: 'SHOT49',
      gameId: 'k' * 16,
      seatToken: 'tok-shot-49',
    );
  });

  testWidgets('capture 50-timer-played-mine-ar', (tester) async {
    await _shootTimerPlayedMine(
      tester,
      binding,
      shotName: '50-timer-played-mine-ar',
      locale: const Locale('ar'),
      roomCode: 'SHOT50',
      gameId: 'l' * 16,
      seatToken: 'tok-shot-50',
    );
  });

  testWidgets('capture 51-timer-played-other-en', (tester) async {
    await _shootTimerPlayedOther(
      tester,
      binding,
      shotName: '51-timer-played-other-en',
      locale: const Locale('en'),
      roomCode: 'SHOT51',
      gameId: 'm' * 16,
      seatToken: 'tok-shot-51',
    );
  });

  testWidgets('capture 52-timer-played-other-ar', (tester) async {
    await _shootTimerPlayedOther(
      tester,
      binding,
      shotName: '52-timer-played-other-ar',
      locale: const Locale('ar'),
      roomCode: 'SHOT52',
      gameId: 'n' * 16,
      seatToken: 'tok-shot-52',
    );
  });

  // ==========================================================================
  // 64-68: order 467. Emulator frames of each seat's die at its own side of
  // the board (C-465). Same route as captures 45-48 and 41-44: a GameScreen
  // over FakeTransport, frames copied by hand into this file, no server, no
  // pumpAndSettle once GameScreen is up. Bodies live at the bottom of the
  // file.
  // ==========================================================================
  testWidgets('capture 64-seat-die-seat0-en', (tester) async {
    await _shootSeatDieTwoSeats(
      tester,
      binding,
      shotName: '64-seat-die-seat0-en',
      locale: const Locale('en'),
      mySeat: 0,
      rollerSeat: 2,
      face: 5,
      roomCode: 'SD64EN',
      gameId: '1' * 16,
      seatToken: 'tok-shot-64',
    );
  });

  testWidgets('capture 65-seat-die-seat2-ar', (tester) async {
    await _shootSeatDieTwoSeats(
      tester,
      binding,
      shotName: '65-seat-die-seat2-ar',
      locale: const Locale('ar'),
      mySeat: 2,
      rollerSeat: 0,
      face: 4,
      roomCode: 'SD65AR',
      gameId: '2' * 16,
      seatToken: 'tok-shot-65',
    );
  });

  testWidgets('capture 66-seat-die-four-en', (tester) async {
    await _shootSeatDieFourSeats(
      tester,
      binding,
      shotName: '66-seat-die-four-en',
      locale: const Locale('en'),
      roomCode: 'SD66EN',
      gameId: '3' * 16,
      seatToken: 'tok-shot-66',
    );
  });

  testWidgets('capture 67-seat-die-four-ar', (tester) async {
    await _shootSeatDieFourSeats(
      tester,
      binding,
      shotName: '67-seat-die-four-ar',
      locale: const Locale('ar'),
      roomCode: 'SD67AR',
      gameId: '4' * 16,
      seatToken: 'tok-shot-67',
    );
  });

  testWidgets('capture 68-seat-die-large-en', (tester) async {
    await _shootSeatDieTwoSeats(
      tester,
      binding,
      shotName: '68-seat-die-large-en',
      locale: const Locale('en'),
      mySeat: 0,
      rollerSeat: 2,
      face: 5,
      roomCode: 'SD68EN',
      gameId: '5' * 16,
      seatToken: 'tok-shot-68',
      textScale: 2.0,
    );
  });

  // ==========================================================================
  // 69-71: order 470. Emulator frames of the capture gloat and the faded idle
  // die (C-468 D5, D7). Same route as captures 64-68: a GameScreen over
  // FakeTransport, no server, no pumpAndSettle once GameScreen is up. Bodies
  // live at the bottom of the file. Order 578: 69 and 70 replay a capture of
  // a recorded real game (`_replayRealGameToCapture`) instead of frames typed
  // by hand. 69 is guest_wins_1 from the host's view (seat 0, Priya): seat 2
  // captures, so this device is the captured seat. 70 is host_wins_1's second
  // capture: seat 0 captures, so this device is the capturer. 71 is unchanged.
  // ==========================================================================
  testWidgets('capture 69-gloat-captured-en', (tester) async {
    await _shootCaptureGloat(
      tester,
      binding,
      shotName: '69-gloat-captured-en',
      locale: const Locale('en'),
      gameName: 'guest_wins_1',
      moverSeat: 2,
      ordinal: 1,
    );
  });

  testWidgets('capture 70-gloat-capturer-ar', (tester) async {
    await _shootCaptureGloat(
      tester,
      binding,
      shotName: '70-gloat-capturer-ar',
      locale: const Locale('ar'),
      gameName: 'host_wins_1',
      moverSeat: 0,
      ordinal: 2,
    );
  });

  testWidgets('capture 71-idle-die-faded-en', (tester) async {
    await _shootIdleDieFaded(
      tester,
      binding,
      shotName: '71-idle-die-faded-en',
      locale: const Locale('en'),
      roomCode: 'ID71EN',
      gameId: '8' * 16,
      seatToken: 'tok-shot-71',
    );
  });

  // ==========================================================================
  // 72-75: order 473. Emulator frames of the one-time move hint (C-471 D3,
  // D4). Same route as captures 64-71: a GameScreen over FakeTransport, frames
  // copied by hand into this file, no server, no pumpAndSettle once GameScreen
  // is up. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 72-hint-ready-en', (tester) async {
    await _shootHintReady(
      tester,
      binding,
      shotName: '72-hint-ready-en',
      locale: const Locale('en'),
      roomCode: 'HN72EN',
      gameId: 'a' * 16,
      seatToken: 'tok-shot-72',
    );
  });

  testWidgets('capture 73-hint-shown-ar', (tester) async {
    await _shootHintShown(
      tester,
      binding,
      shotName: '73-hint-shown-ar',
      locale: const Locale('ar'),
      roomCode: 'HN73AR',
      gameId: 'b' * 16,
      seatToken: 'tok-shot-73',
    );
  });

  testWidgets('capture 74-hint-queue-en', (tester) async {
    await _shootHintQueue(
      tester,
      binding,
      shotName: '74-hint-queue-en',
      locale: const Locale('en'),
      roomCode: 'HN74EN',
      gameId: 'c' * 16,
      seatToken: 'tok-shot-74',
    );
  });

  testWidgets('capture 75-hint-used-ar-large', (tester) async {
    await _shootHintUsedLarge(
      tester,
      binding,
      shotName: '75-hint-used-ar-large',
      locale: const Locale('ar'),
      roomCode: 'HN75AR',
      gameId: 'd' * 16,
      seatToken: 'tok-shot-75',
    );
  });

  // ==========================================================================
  // 76-78: order 476. Emulator frames for the no-move reason lines (C-474 D1,
  // D2). Same route as captures 15 and 16: a GameScreen over FakeTransport,
  // frames copied by hand into this file, no server, no pumpAndSettle once
  // GameScreen is up. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 76-no-move-need-six-en', (tester) async {
    await _shootNoMoveReason(
      tester,
      binding,
      shotName: '76-no-move-need-six-en',
      locale: const Locale('en'),
      roomCode: 'NM76EN',
      gameId: 'e' * 16,
      seatToken: 'tok-shot-76',
      rollValue: 3,
      needExact: false,
    );
  });

  testWidgets('capture 77-no-move-need-six-ar', (tester) async {
    await _shootNoMoveReason(
      tester,
      binding,
      shotName: '77-no-move-need-six-ar',
      locale: const Locale('ar'),
      roomCode: 'NM77AR',
      gameId: 'f' * 16,
      seatToken: 'tok-shot-77',
      rollValue: 3,
      needExact: false,
    );
  });

  testWidgets('capture 78-no-move-need-exact-en', (tester) async {
    await _shootNoMoveReason(
      tester,
      binding,
      shotName: '78-no-move-need-exact-en',
      locale: const Locale('en'),
      roomCode: 'NM78EN',
      gameId: '0' * 16,
      seatToken: 'tok-shot-78',
      rollValue: 4,
      needExact: true,
    );
  });

  // ==========================================================================
  // 79-83: order 482. Emulator frames of the quick messages (C-478 D5.2,
  // D5.4): the sheet and the bubbles on the board. Same route as captures
  // 76-78: a GameScreen over FakeTransport, frames copied by hand into this
  // file, no server, no pumpAndSettle once GameScreen is up. Since order 504
  // captures 81-83 assert C-500's placement: one line, the newest, in the
  // header band. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 79-chat-sheet-en', (tester) async {
    await _shootChatSheet(
      tester,
      binding,
      shotName: '79-chat-sheet-en',
      locale: const Locale('en'),
      roomCode: 'QC79EN',
      gameId: '1' * 16,
      seatToken: 'tok-shot-79',
    );
  });

  testWidgets('capture 80-chat-sheet-ar', (tester) async {
    await _shootChatSheet(
      tester,
      binding,
      shotName: '80-chat-sheet-ar',
      locale: const Locale('ar'),
      roomCode: 'QC80AR',
      gameId: '2' * 16,
      seatToken: 'tok-shot-80',
    );
  });

  testWidgets('capture 81-chat-bubbles-en', (tester) async {
    await _shootChatBubbles(
      tester,
      binding,
      shotName: '81-chat-bubbles-en',
      locale: const Locale('en'),
      roomCode: 'QC81EN',
      gameId: '3' * 16,
      seatToken: 'tok-shot-81',
    );
  });

  testWidgets('capture 82-chat-bubbles-ar', (tester) async {
    await _shootChatBubbles(
      tester,
      binding,
      shotName: '82-chat-bubbles-ar',
      locale: const Locale('ar'),
      roomCode: 'QC82AR',
      gameId: '4' * 16,
      seatToken: 'tok-shot-82',
    );
  });

  testWidgets('capture 83-chat-bubbles-ar-large-text', (tester) async {
    await _shootChatBubblesLarge(
      tester,
      binding,
      shotName: '83-chat-bubbles-ar-large-text',
      locale: const Locale('ar'),
      roomCode: 'QC83AR',
      gameId: '5' * 16,
      seatToken: 'tok-shot-83',
    );
  });

  // ==========================================================================
  // 84-87: order 489 (C-485 D7), re-pointed by order 497 to C-492. Emulator
  // frames of the end card's replies and lines: a FINISHED room reached
  // through a real GameScreen over FakeTransport the way captures 21 and 22
  // reach theirs (order 582: a recorded game, replayed from the home screen
  // to its own `game_over`), then `emote` pushes with no `re` the way
  // captures 81-83 inject them. Since C-492 the line is one bubble, the
  // newest, drawn in the header band. No server, no pumpAndSettle once
  // GameScreen is up. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 84-end-lose-chat-en', (tester) async {
    await _shootEndCardChat(
      tester,
      binding,
      shotName: '84-end-lose-chat-en',
      locale: const Locale('en'),
      gameName: 'guest_wins_1',
      viewerSeat: 0,
      fourSeats: false,
      winnerSeat: 2,
      emotes: const <(int, String)>[(2, 'ha_ha')],
      expectedReplies: const <String>['good_game', 'revenge', 'lucky'],
    );
  });

  testWidgets('capture 85-end-lose-chat-ar', (tester) async {
    await _shootEndCardChat(
      tester,
      binding,
      shotName: '85-end-lose-chat-ar',
      locale: const Locale('ar'),
      gameName: 'guest_wins_1',
      viewerSeat: 0,
      fourSeats: false,
      winnerSeat: 2,
      emotes: const <(int, String)>[(2, 'ha_ha')],
      expectedReplies: const <String>['good_game', 'revenge', 'lucky'],
    );
  });

  testWidgets('capture 86-end-win-chat-en', (tester) async {
    await _shootEndCardChat(
      tester,
      binding,
      shotName: '86-end-win-chat-en',
      locale: const Locale('en'),
      gameName: 'four_seats_1',
      viewerSeat: 1,
      fourSeats: true,
      winnerSeat: 1,
      emotes: const <(int, String)>[(0, 'good_game'), (3, 'lucky')],
      expectedReplies: const <String>['good_game', 'ha_ha'],
    );
  });

  testWidgets('capture 87-end-lose-chat-ar-large-text', (tester) async {
    await _shootEndCardChat(
      tester,
      binding,
      shotName: '87-end-lose-chat-ar-large-text',
      locale: const Locale('ar'),
      gameName: 'guest_wins_1',
      viewerSeat: 0,
      fourSeats: false,
      winnerSeat: 2,
      emotes: const <(int, String)>[(2, 'revenge')],
      expectedReplies: const <String>['good_game', 'revenge', 'lucky'],
      textScale: 2.0,
      expectNameDroppedOnPhone: false,
    );
  });

  // ==========================================================================
  // 88-90: order 497 (C-492 D2, C-495 D3). Capture 88 is the end card's
  // replace rule: seat 2's line, one dwell (C-596 D1) later my own (the
  // server's copy of it arrives as an `emote` push like anyone's), and only
  // mine is left. Captures
  // 89 and 90 are an opponent on a 10 s segment at 8 s and at 2 s left: a
  // PLAYING room reached the way 79-83 reach theirs, then a `room` push whose
  // turn carries `segment_ms`, then real time until the digits read the
  // target. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 88-end-chat-replace-en', (tester) async {
    await _shootEndCardChat(
      tester,
      binding,
      shotName: '88-end-chat-replace-en',
      locale: const Locale('en'),
      gameName: 'host_wins_1',
      viewerSeat: 0,
      fourSeats: false,
      winnerSeat: 0,
      emotes: const <(int, String)>[(2, 'good_game'), (0, 'ha_ha')],
      expectedReplies: const <String>['good_game', 'ha_ha'],
    );
  });

  testWidgets('capture 89-away-ring-8s-en', (tester) async {
    await _shootAwayRing(
      tester,
      binding,
      shotName: '89-away-ring-8s-en',
      locale: const Locale('en'),
      secondsLeft: 8,
      roomCode: 'AW89EN',
      gameId: 'b' * 16,
      seatToken: 'tok-shot-89',
    );
  });

  testWidgets('capture 90-away-ring-2s-ar', (tester) async {
    await _shootAwayRing(
      tester,
      binding,
      shotName: '90-away-ring-2s-ar',
      locale: const Locale('ar'),
      secondsLeft: 2,
      roomCode: 'AW90AR',
      gameId: 'c' * 16,
      seatToken: 'tok-shot-90',
    );
  });

  // ==========================================================================
  // 91-92: order 504 (C-500 D1, D4). The worst board for a quick message: my
  // turn in await_move with a 6 rolled and all four of my tokens in the yard,
  // so four legal rings, then seat 2 sends `revenge`. The line must sit in the
  // header band and cover no ring. 91 is English at text scale 1.0, 92 is
  // Arabic at 2.0. A four-seat GameScreen over FakeTransport reached the way
  // 79-83 reach theirs, no pumpAndSettle once it is up. Body lives at the
  // bottom of the file.
  // ==========================================================================
  testWidgets('capture 91-chat-my-six-en', (tester) async {
    await _shootChatMySix(
      tester,
      binding,
      shotName: '91-chat-my-six-en',
      locale: const Locale('en'),
      roomCode: 'QC91EN',
      gameId: 'd' * 16,
      seatToken: 'tok-shot-91',
    );
  });

  testWidgets('capture 92-chat-my-six-ar-large-text', (tester) async {
    await _shootChatMySix(
      tester,
      binding,
      shotName: '92-chat-my-six-ar-large-text',
      locale: const Locale('ar'),
      roomCode: 'QC92AR',
      gameId: 'e' * 16,
      seatToken: 'tok-shot-92',
      textScale: 2.0,
    );
  });

  // ==========================================================================
  // 93-94: order 513 (C-511 D3). The compact tray: my turn in await_move on
  // the queue [3, 6, 6, 2, 6, 6, 4] (the longest queue 12q lets a turn
  // build, four distinct faces) with the hint ready, so the tray has to fit
  // in the band the hint leaves beside the die. 93 is English at text scale
  // 1.0, 94 is Arabic at 2.0. Captures 43 and 63 carry the same
  // die-row-clear-of-the-hint check. Body lives with the capture 43 body at
  // the bottom of the file.
  // ==========================================================================
  testWidgets('capture 93-game-tray-compact-en', (tester) async {
    await _shootCompactTray(
      tester,
      binding,
      shotName: '93-game-tray-compact-en',
      locale: const Locale('en'),
      roomCode: 'TC93EN',
      gameId: '93' * 8,
      seatToken: 'tok-shot-93',
    );
  });

  testWidgets('capture 94-game-tray-compact-ar-large-text', (tester) async {
    await _shootCompactTray(
      tester,
      binding,
      shotName: '94-game-tray-compact-ar-large-text',
      locale: const Locale('ar'),
      roomCode: 'TC94AR',
      gameId: '94' * 8,
      seatToken: 'tok-shot-94',
      textScale: 2.0,
    );
  });

  // ==========================================================================
  // 95-98: order 520 (C-520 D2, D3). 95 and 96 are the chat button resting
  // about a second after an acknowledged send, with the ring part drained
  // (en, ar). 97 and 98 are a refused tap with animations off, captured
  // inside the 300 ms the RefusalMark lives: a token with no legal move (en)
  // and the die on the other seat's turn (ar). Bodies live at the bottom of
  // the file.
  // ==========================================================================
  testWidgets('capture 95-chat-resting-en', (tester) async {
    await _shootChatResting(
      tester,
      binding,
      shotName: '95-chat-resting-en',
      locale: const Locale('en'),
      roomCode: 'CR95EN',
      gameId: '95' * 8,
      seatToken: 'tok-shot-95',
    );
  });

  testWidgets('capture 96-chat-resting-ar', (tester) async {
    await _shootChatResting(
      tester,
      binding,
      shotName: '96-chat-resting-ar',
      locale: const Locale('ar'),
      roomCode: 'CR96AR',
      gameId: '96' * 8,
      seatToken: 'tok-shot-96',
    );
  });

  testWidgets('capture 97-refusal-token-reduced-en', (tester) async {
    await _shootRefusalReduced(
      tester,
      binding,
      shotName: '97-refusal-token-reduced-en',
      locale: const Locale('en'),
      roomCode: 'RF97EN',
      gameId: '97' * 8,
      seatToken: 'tok-shot-97',
      refuseDie: false,
    );
  });

  testWidgets('capture 98-refusal-die-reduced-ar', (tester) async {
    await _shootRefusalReduced(
      tester,
      binding,
      shotName: '98-refusal-die-reduced-ar',
      locale: const Locale('ar'),
      roomCode: 'RF98AR',
      gameId: '98' * 8,
      seatToken: 'tok-shot-98',
      refuseDie: true,
    );
  });

  // ==========================================================================
  // 99-105: order 526 (C-523). The plain home and the one sound switch. 99
  // and 100 are home in its default state, top of the list; 101 and 102 have
  // the players menu open over home-players-button; 103 has six characters
  // typed so Join is in the tree; 104 is Arabic at system text scale 2.0,
  // scrolled so the players row is on screen; 105 is the game header after
  // one tap on game-sound-toggle. Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 99-home-plain-en', (tester) async {
    await _shootHomePlain(
      tester,
      binding,
      shotName: '99-home-plain-en',
      locale: const Locale('en'),
    );
  });

  testWidgets('capture 100-home-plain-ar', (tester) async {
    await _shootHomePlain(
      tester,
      binding,
      shotName: '100-home-plain-ar',
      locale: const Locale('ar'),
    );
  });

  testWidgets('capture 101-home-players-menu-en', (tester) async {
    await _shootHomePlayersMenu(
      tester,
      binding,
      shotName: '101-home-players-menu-en',
      locale: const Locale('en'),
    );
  });

  testWidgets('capture 102-home-players-menu-ar', (tester) async {
    await _shootHomePlayersMenu(
      tester,
      binding,
      shotName: '102-home-players-menu-ar',
      locale: const Locale('ar'),
    );
  });

  testWidgets('capture 103-home-join-shown-en', (tester) async {
    await _shootHomeJoinShown(
      tester,
      binding,
      shotName: '103-home-join-shown-en',
      locale: const Locale('en'),
    );
  });

  testWidgets('capture 104-home-large-text-ar', (tester) async {
    await _shootHomeLargeText(
      tester,
      binding,
      shotName: '104-home-large-text-ar',
      locale: const Locale('ar'),
    );
  });

  testWidgets('capture 105-game-muted-ar', (tester) async {
    await _shootGameMuted(
      tester,
      binding,
      shotName: '105-game-muted-ar',
      locale: const Locale('ar'),
      roomCode: 'SM105A',
      gameId: '105' * 5 + '1',
      seatToken: 'tok-shot-105',
    );
  });

  // ==========================================================================
  // 106-113: order 531 (C-529 and A1). 106 is the die refused on my own turn
  // (the residue from run 122); 107 and 108 are home after a lobby whose room
  // closed under it; 109 and 110 are the lobby error body of a join that
  // cannot succeed; 111 is the connection-lost card in a PLAYING game; 112 is
  // the end card reached by a resume; 113 is a real loser's end card with
  // every tile at zero (X120). Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 106-refusal-die-my-turn-en', (tester) async {
    await _shootRefusalDieMyTurn(
      tester,
      binding,
      shotName: '106-refusal-die-my-turn-en',
      locale: const Locale('en'),
      roomCode: 'RD6M3E',
      gameId: '106' * 5 + '1',
      seatToken: 'tok-shot-106',
    );
  });

  testWidgets('capture 107-home-room-closed-host-en', (tester) async {
    await _shootHomeRoomClosed(
      tester,
      binding,
      shotName: '107-home-room-closed-host-en',
      locale: const Locale('en'),
      roomCode: 'HC4K7E',
      seatToken: 'tok-shot-107',
      host: true,
    );
  });

  testWidgets('capture 108-home-room-closed-guest-ar', (tester) async {
    await _shootHomeRoomClosed(
      tester,
      binding,
      shotName: '108-home-room-closed-guest-ar',
      locale: const Locale('ar'),
      roomCode: 'HG5M8A',
      seatToken: 'tok-shot-108',
      host: false,
    );
  });

  testWidgets('capture 109-lobby-link-gone-first-time-ar', (tester) async {
    await _shootLobbyJoinRefused(
      tester,
      binding,
      shotName: '109-lobby-link-gone-first-time-ar',
      locale: const Locale('ar'),
      code: 'LK9M3P',
      fromLink: true,
      errorCode: 'NO_SUCH_ROOM',
    );
  });

  testWidgets('capture 110-lobby-room-started-en', (tester) async {
    await _shootLobbyJoinRefused(
      tester,
      binding,
      shotName: '110-lobby-room-started-en',
      locale: const Locale('en'),
      code: 'RS2N6Q',
      fromLink: false,
      errorCode: 'ROOM_STARTED',
    );
  });

  testWidgets('capture 111-game-connection-lost-ar', (tester) async {
    await _shootGameConnectionLost(
      tester,
      binding,
      shotName: '111-game-connection-lost-ar',
      locale: const Locale('ar'),
      roomCode: 'CL8P4A',
      gameId: '111' * 5 + '1',
      seatToken: 'tok-shot-111',
    );
  });

  testWidgets('capture 112-end-resumed-no-rolls-en', (tester) async {
    await _shootEndResumedNoRolls(
      tester,
      binding,
      shotName: '112-end-resumed-no-rolls-en',
      locale: const Locale('en'),
      roomCode: 'EN6R3W',
      gameId: '112' * 5 + '1',
      seatToken: 'tok-shot-112',
    );
  });

  testWidgets('capture 113-end-lose-zero-ar', (tester) async {
    await _shootEndLoseZero(
      tester,
      binding,
      shotName: '113-end-lose-zero-ar',
      locale: const Locale('ar'),
      roomCode: 'ZR5T9A',
      gameId: '113' * 5 + '1',
      seatToken: 'tok-shot-113',
    );
  });

  testWidgets('capture 115-lobby-error-transport-en', (tester) async {
    await _shootLobbyJoinTransport(
      tester,
      binding,
      shotName: '115-lobby-error-transport-en',
      locale: const Locale('en'),
      code: 'TP5N8K',
    );
  });

  testWidgets('capture 116-lobby-error-link-gone-ar', (tester) async {
    await _shootLobbyJoinRefused(
      tester,
      binding,
      shotName: '116-lobby-error-link-gone-ar',
      locale: const Locale('ar'),
      code: 'LG6W4B',
      fromLink: true,
      errorCode: 'NO_SUCH_ROOM',
    );
  });

  testWidgets('capture 118-end-lose-some-zero-en', (tester) async {
    await _shootEndLoseSomeZero(
      tester,
      binding,
      shotName: '118-end-lose-some-zero-en',
      locale: const Locale('en'),
      roomCode: 'LS9R2A',
      gameId: '118' * 5 + '1',
      seatToken: 'tok-shot-118',
    );
  });

  // ==========================================================================
  // 119-121: order 538 (C-536). Two seats that carry the same name are told
  // apart: 119 is the host's three-seat lobby, 120 an Arabic game's board
  // chips, 121 the end card of a game the second "Player" won. Bodies live at
  // the bottom of the file.
  // ==========================================================================
  testWidgets('capture 119-lobby-same-names-en', (tester) async {
    await _shootLobbySameNames(
      tester,
      binding,
      shotName: '119-lobby-same-names-en',
      locale: const Locale('en'),
      roomCode: 'SN9L3E',
      seatToken: 'tok-shot-119',
    );
  });

  testWidgets('capture 120-game-same-names-ar', (tester) async {
    await _shootGameSameNames(
      tester,
      binding,
      shotName: '120-game-same-names-ar',
      locale: const Locale('ar'),
      roomCode: 'SN2G4A',
      gameId: '120' * 5 + '1',
      seatToken: 'tok-shot-120',
    );
  });

  testWidgets('capture 121-end-same-names-en', (tester) async {
    await _shootEndSameNames(
      tester,
      binding,
      shotName: '121-end-same-names-en',
      locale: const Locale('en'),
      roomCode: 'SN1E5W',
      gameId: '121' * 5 + '1',
      seatToken: 'tok-shot-121',
    );
  });

  // ==========================================================================
  // 122-127: orders 547 and 549 (C-547, C-549). 122-124 are the takeover card
  // on the game and on a lobby holding a room, 125-126 the reconnecting row
  // once the slow line has appeared, 127 the game's catching-up banner.
  // Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 122-game-seat-moved-en', (tester) async {
    await _shootGameSeatMoved(
      tester,
      binding,
      shotName: '122-game-seat-moved-en',
      locale: const Locale('en'),
      roomCode: 'SM2E4A',
      seatToken: 'tok-shot-122',
    );
  });

  testWidgets('capture 123-game-seat-moved-ar', (tester) async {
    await _shootGameSeatMoved(
      tester,
      binding,
      shotName: '123-game-seat-moved-ar',
      locale: const Locale('ar'),
      roomCode: 'SM3A5K',
      seatToken: 'tok-shot-123',
    );
  });

  testWidgets('capture 124-lobby-seat-moved-ar', (tester) async {
    await _shootLobbySeatMoved(
      tester,
      binding,
      shotName: '124-lobby-seat-moved-ar',
      locale: const Locale('ar'),
      roomCode: 'SM4L6W',
      seatToken: 'tok-shot-124',
    );
  });

  testWidgets('capture 125-game-reconnecting-slow-en', (tester) async {
    await _shootGameReconnectingSlow(
      tester,
      binding,
      shotName: '125-game-reconnecting-slow-en',
      locale: const Locale('en'),
      roomCode: 'RS5E7A',
      seatToken: 'tok-shot-125',
    );
  });

  testWidgets('capture 126-game-reconnecting-slow-ar', (tester) async {
    await _shootGameReconnectingSlow(
      tester,
      binding,
      shotName: '126-game-reconnecting-slow-ar',
      locale: const Locale('ar'),
      roomCode: 'RS6A8K',
      seatToken: 'tok-shot-126',
    );
  });

  testWidgets('capture 127-game-catching-up-ar', (tester) async {
    await _shootGameCatchingUp(
      tester,
      binding,
      shotName: '127-game-catching-up-ar',
      locale: const Locale('ar'),
      roomCode: 'CU7A9W',
    );
  });

  // ==========================================================================
  // 128-133: order 559 (C-554 D1, C-555 D1 and D2), order 564 (C-560 D4).
  // 128-129 are the game's countdown at zero, 130-131 the lobby's desync
  // banner with a resync out on the live socket, 132-133 the lobby's
  // connecting body at text scale 2.0.
  // Bodies live at the bottom of the file.
  // ==========================================================================
  testWidgets('capture 128-game-time-up-en', (tester) async {
    await _shootGameTimeUp(
      tester,
      binding,
      shotName: '128-game-time-up-en',
      locale: const Locale('en'),
      roomCode: 'TU8E1A',
      seatToken: 'tok-shot-128',
    );
  });

  testWidgets('capture 129-game-time-up-ar', (tester) async {
    await _shootGameTimeUp(
      tester,
      binding,
      shotName: '129-game-time-up-ar',
      locale: const Locale('ar'),
      roomCode: 'TU9A2K',
      seatToken: 'tok-shot-129',
    );
  });

  testWidgets('capture 130-lobby-resyncing-en', (tester) async {
    await _shootLobbyResyncing(
      tester,
      binding,
      shotName: '130-lobby-resyncing-en',
      locale: const Locale('en'),
      roomCode: 'RY0E3W',
      seatToken: 'tok-shot-130',
    );
  });

  testWidgets('capture 131-lobby-resyncing-ar', (tester) async {
    await _shootLobbyResyncing(
      tester,
      binding,
      shotName: '131-lobby-resyncing-ar',
      locale: const Locale('ar'),
      roomCode: 'RY1A4L',
      seatToken: 'tok-shot-131',
    );
  });

  testWidgets('capture 132-lobby-connecting-large-text-en', (tester) async {
    await _shootLobbyConnectingLarge(
      tester,
      binding,
      shotName: '132-lobby-connecting-large-text-en',
      locale: const Locale('en'),
    );
  });

  testWidgets('capture 133-lobby-connecting-large-text-ar', (tester) async {
    await _shootLobbyConnectingLarge(
      tester,
      binding,
      shotName: '133-lobby-connecting-large-text-ar',
      locale: const Locale('ar'),
    );
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

/// Order 207, capture 14 (and 99, 100): asserts [finder]'s rect lies entirely
/// inside the current view (no scrolling attempted, in any capture). On
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

/// Order 207, capture 14, amended for C-274 and, in this group, for C-356
/// (run 90, order 357, the 10-15 rule ruling): asserts the host's not-full
/// lobby view. [controller].isHost true, lobby-waiting present and reading
/// the app_ar.arb lobbyWaitingForPlayers "=2 of 4" literal, lobby-start-button
/// absent, lobby-start-with-present-button present, enabled, and reading the
/// app_ar.arb lobbyStartWithPresent "=2" literal, lobby-rule-blocks and
/// lobby-rule-blocks-chip both absent outright (C-356: gone, not merely
/// re-labelled), lobby-rule-capture-bonus reading its own app_ar.arb literal
/// for the off state (quoted here, not looked up through AppLocalizations,
/// per the order -- this capture's room carries capture_bonus: false, the
/// reply for a room an older client created, C-523 D6), lobby-house-rules
/// absent (C-523 D6), and lobby-leave-button's rect inside the view. Two lobby-seat-*
/// rows are asserted by the caller's own
/// _expectLobbyScreen(expectedSeatCount: 2) immediately before each call
/// here, not repeated inside this helper. [momentDescription] names which of
/// the two calls (before or after the post-room-reply settle) failed.
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

  const String expectedWaitingText = 'بانتظار اللاعبين (2 من 4)';
  final Finder waitingFinder = find.byKey(const Key('lobby-waiting'));
  expect(
    waitingFinder,
    findsOneWidget,
    reason:
        'capture 14 ($momentDescription): expected lobby-waiting on '
        'screen for the host in a room that is not full (2 of 4 seats '
        'joined)',
  );
  final Text waitingText = tester.widget<Text>(waitingFinder);
  expect(
    waitingText.data,
    expectedWaitingText,
    reason:
        'capture 14 ($momentDescription): expected lobby-waiting\'s Text '
        'to read the app_ar.arb lobbyWaitingForPlayers "=2 of 4" literal '
        '"$expectedWaitingText", got "${waitingText.data}"',
  );
  expect(
    find.byKey(const Key('lobby-start-button')),
    findsNothing,
    reason:
        'capture 14 ($momentDescription): the room is not full (2 of 4 '
        'seats joined), so expected no lobby-start-button',
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

  expect(
    find.byKey(const Key('lobby-rule-blocks')),
    findsNothing,
    reason:
        'capture 14 ($momentDescription): C-356: lobby-rule-blocks must '
        'not exist, even though the fake server\'s room reply still '
        'carries rules.blocks: false on the wire',
  );
  expect(
    find.byKey(const Key('lobby-rule-blocks-chip')),
    findsNothing,
    reason:
        'capture 14 ($momentDescription): C-356: lobby-rule-blocks-chip '
        'must not exist either',
  );

  const String expectedRuleCaptureBonusText = 'مكافأة الأكل: معطّلة';
  final Text ruleCaptureBonusText = tester.widget<Text>(
    find.byKey(const Key('lobby-rule-capture-bonus')),
  );
  expect(
    ruleCaptureBonusText.data,
    expectedRuleCaptureBonusText,
    reason:
        'capture 14 ($momentDescription): expected '
        'lobby-rule-capture-bonus\'s Text to read the app_ar.arb '
        'lobbyRuleCaptureBonusOff literal "$expectedRuleCaptureBonusText" '
        '(the fake server\'s room reply carries rules.capture_bonus: '
        'false, the answer for a room an older client created), got '
        '"${ruleCaptureBonusText.data}"',
  );

  expect(
    find.byKey(const Key('lobby-house-rules')),
    findsNothing,
    reason:
        'capture 14 ($momentDescription): C-523 D6: lobby-house-rules is '
        'removed, the lobby no longer repeats the rules',
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

/// Order 240, captures 15 and 16; order 476, captures 76-78 (C-474 D1):
/// asserts PR #87's no-move beat (C-236 rule 4, game_screen.dart's
/// `_armNoMoveHold`, armed by a `rolled` for my seat with an empty `legal`) is
/// still showing both its die mark (`game-die-no-move-mark`) and its text
/// notice (`game-no-move-notice`), and that the notice's own `Text` reads
/// [expectedText] (defaulting to `loc.gameNoMoveNeedSix` for all-in-yard
/// boards). [momentDescription] names which of the two calls (before or after
/// the ~300ms settle) failed.
void _expectNoMoveVisible(
  WidgetTester tester, {
  required AppLocalizations loc,
  required String momentDescription,
  String? expectedText,
}) {
  final String expected = expectedText ?? loc.gameNoMoveNeedSix;
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
    expected,
    reason:
        'capture 15/16 ($momentDescription): expected '
        'game-no-move-notice\'s Text to read "$expected", got '
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

/// Order 570, captures 17 and 18: after my own capturing `moved`
/// (`extra_roll: true`) and the same-seat `turn` the server sends behind it,
/// the seat on turn is [seat], mine, awaiting a roll (the caller reads it off
/// the recorded `turn` frame, order 578), and the turn banner reads
/// [expected], the capture extra-roll line of the capture's locale (the
/// caller passes `loc.gameRollAgainCapture`, never a literal).
/// [momentDescription] names which of the two calls (before or after the
/// post-move settle) failed.
void _expectCaptureRollAgain(
  WidgetTester tester, {
  required RoomController controller,
  required int seat,
  required String captureName,
  required String expected,
  required String momentDescription,
}) {
  final String reproduce =
      'Fixed frames, no seed: `flutter test '
      'integration_test/screenshots_test.dart -d flutter-tester '
      '--plain-name "capture $captureName"`';
  final turn = controller.room?.turn;
  expect(
    turn == null ? null : (turn.seat, turn.phase.name),
    (seat, 'awaitRoll'),
    reason:
        'capture $captureName ($momentDescription): expected the turn on '
        'my seat $seat in await_roll after the capturing moved and the '
        'same-seat turn frame, got '
        '${turn == null ? 'no turn' : 'seat ${turn.seat} ${turn.phase.name}'}. '
        '$reproduce',
  );
  final Finder bannerFinder = find.byKey(const Key('game-screen-turn-banner'));
  expect(
    bannerFinder,
    findsOneWidget,
    reason:
        'capture $captureName ($momentDescription): expected '
        'game-screen-turn-banner on screen. $reproduce',
  );
  final Text banner = tester.widget<Text>(bannerFinder);
  expect(
    banner.data,
    expected,
    reason:
        'capture $captureName ($momentDescription): expected the turn '
        'banner to read the capture extra-roll line "$expected" '
        '(gameRollAgainCapture), got "${banner.data}". A capture is a roll '
        'owed, so the banner after it is never the plain turn line. '
        '$reproduce',
  );
}

/// Order 570, captures 134 and 135: the whole frame run the server sends
/// when my seat (0) rolls three sixes in a row, from `seq` [firstSeq] on,
/// and the next seat's `turn` behind it. docs/PROTOCOL.md 12.1 and 21.3.4:
/// a 6 that owes a roll is `rolled` (`legal: []`, `queue: [6]`) then `turn`
/// for the same seat in `await_roll`; the second the same with `[6, 6]`;
/// the third `rolled` is still sent first, carries `queue: []`, and is
/// followed by `turn_passed` with `reason: "three_sixes"`, then `turn` for
/// the next seat. Each push is followed by the pump pair the tray captures
/// use, and nothing else, so the whole run lands in a few milliseconds of
/// real time and the no-move hold (armed by the third `rolled`) is still
/// at the start of its 1500 ms when it returns. Returns the last `seq`.
Future<int> _pushThreeSixesRun(
  WidgetTester tester,
  FakeTransport transport,
  int firstSeq,
) async {
  int seq = firstSeq - 1;
  for (final (int k, List<int> queue) in <(int, List<int>)>[
    (1, <int>[6]),
    (2, <int>[6, 6]),
  ]) {
    seq = await _pushTraySeq(
      tester,
      transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': k,
        'reveal': _trayReveal,
        'queue': queue,
      },
    );
    seq = await _pushTraySeq(
      tester,
      transport,
      seq,
      type: 'turn',
      data: <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': _trayDeadlineMs,
        'queue': queue,
      },
    );
  }
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'rolled',
    data: <String, Object?>{
      'seat': 0,
      'value': 6,
      'legal': <int>[],
      'deadline_ms': _trayDeadlineMs,
      'k': 3,
      'reveal': _trayReveal,
      'queue': <int>[],
    },
  );
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'turn_passed',
    data: <String, Object?>{'seat': 0, 'reason': 'three_sixes'},
  );
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'turn',
    data: <String, Object?>{
      'seat': 2,
      'phase': 'await_roll',
      'deadline_ms': _trayDeadlineMs,
      'queue': <int>[],
    },
  );
  return seq;
}

/// Order 570, captures 134 and 135: the no-move die mark is up and the
/// notice's own `Text` reads [expected], the three-sixes line of the
/// capture's locale (the caller passes `loc.gameNoMoveThreeSixes`), not the
/// plain, need-six or need-exact line. [momentDescription] names which of
/// the two calls (before or after the settle) failed.
void _expectThreeSixesNotice(
  WidgetTester tester, {
  required RoomController controller,
  required String captureName,
  required String expected,
  required int expectedSeq,
  required String momentDescription,
}) {
  final String reproduce =
      'Fixed frames, no seed: `flutter test '
      'integration_test/screenshots_test.dart -d flutter-tester '
      '--plain-name "capture $captureName"`';
  expect(
    controller.room!.seq,
    expectedSeq,
    reason:
        'capture $captureName ($momentDescription): a pushed frame was '
        'dropped; room seq is ${controller.room!.seq}, last push was '
        '$expectedSeq. $reproduce',
  );
  final List<Frame> run = controller.gameTranscript;
  expect(
    <String>[for (final Frame f in run) f.type],
    <String>[
      'game_started',
      'rolled',
      'turn',
      'rolled',
      'turn',
      'rolled',
      'turn_passed',
      'turn',
    ],
    reason:
        'capture $captureName ($momentDescription): expected the frames the '
        'server sends for three sixes in a row (docs/PROTOCOL.md 12.1, '
        '21.3.4): two sixes each followed by a same-seat turn, the third '
        'rolled, turn_passed, then the next seat\'s turn. $reproduce',
  );
  final Frame passed = run.singleWhere((Frame f) => f.type == 'turn_passed');
  expect(
    passed.data['reason'],
    'three_sixes',
    reason:
        'capture $captureName ($momentDescription): expected turn_passed to '
        'carry reason "three_sixes", got "${passed.data['reason']}". '
        '$reproduce',
  );
  expect(
    controller.room!.turn!.seat,
    2,
    reason:
        'capture $captureName ($momentDescription): expected the turn on '
        'seat 2 (Karim) after turn_passed three_sixes and the next turn '
        'frame, got seat ${controller.room!.turn!.seat}. $reproduce',
  );
  expect(
    find.byKey(const Key('game-die-no-move-mark')),
    findsOneWidget,
    reason:
        'capture $captureName ($momentDescription): expected '
        'game-die-no-move-mark on screen. $reproduce',
  );
  final Finder noticeFinder = find.byKey(const Key('game-no-move-notice'));
  expect(
    noticeFinder,
    findsOneWidget,
    reason:
        'capture $captureName ($momentDescription): expected '
        'game-no-move-notice on screen. $reproduce',
  );
  final Text notice = tester.widget<Text>(noticeFinder);
  expect(
    notice.data,
    expected,
    reason:
        'capture $captureName ($momentDescription): expected the no-move '
        'notice to read the three-sixes line "$expected" '
        '(gameNoMoveThreeSixes), got "${notice.data}". $reproduce',
  );
}

/// 64 lowercase hex. The client does not read `reveal`
/// (room_controller.dart `_reduceRolled`: not required, not stored).
/// Same shape as integration_test/motion_test.dart.
String _endCardReveal(int k) => k.toRadixString(16).padLeft(64, '0');

// motion_test.dart's `_deadlineMs`. A `rolled` or `turn` without it is
// ignored by the reducer, and the next seq then looks like a gap.
const int _endCardDeadlineMs = 45000;

List<int> _endCardTokens(RoomController controller, int seat) {
  final SeatState seatState = controller.room!.seats.firstWhere(
    (SeatState s) => s.seat == seat,
    orElse: () => throw TestFailure(
      'end-card script: seat $seat absent from controller.room!.seats',
    ),
  );
  return seatState.tokens;
}

/// Rolls [seat] made in the game `_replayRealGame` just replayed, counted
/// from `rolled` frames on [controller]'s transcript. Captures 23 and 24
/// check it against the fixture's `rolls` for that seat before the tile is
/// read.
int _scriptedRolls(RoomController controller, int seat) {
  var rolls = 0;
  for (final Frame frame in controller.gameTranscript) {
    if (frame.type != 'rolled') {
      continue;
    }
    if (frame.data['seat'] == seat) {
      rolls++;
    }
  }
  return rolls;
}

/// Tokens on 57 for [seat] in the room `_replayRealGame` just left.
/// Captures 23 and 24 check it against the fixture's `home` for that seat
/// before the tile is read. Read it before `game_over`: that push does not
/// move tokens, and the rematch LOBBY after it replaces the live room's
/// seats.
int _scriptedHome(RoomController controller, int seat) {
  var home = 0;
  for (final int progress in _endCardTokens(controller, seat)) {
    if (progress == 57) {
      home++;
    }
  }
  return home;
}

/// Captures 23 and 24, immediately before the shot: the rolls tile shows
/// [rolls], which the recorded game left non-zero, and the home tile shows
/// [home], the device seat's tokens on 57 at the end of that game. Both come
/// from the fixture's `counts`. A [home] of 0 means the home tile is absent
/// (C-533 D3).
void _expectScriptedEndCardTiles(
  WidgetTester tester, {
  required String capture,
  required int rolls,
  required int home,
}) {
  expect(
    rolls,
    greaterThan(0),
    reason: '$capture: the fixture\'s rolls for this seat must be non-zero',
  );
  _expectScriptedEndCardCount(
    tester,
    capture: capture,
    keyName: 'end-card-stat-rolls',
    count: rolls,
  );
  _expectScriptedEndCardCount(
    tester,
    capture: capture,
    keyName: 'end-card-stat-home',
    count: home,
  );
}

void _expectScriptedEndCardCount(
  WidgetTester tester, {
  required String capture,
  required String keyName,
  required int count,
}) {
  _expectStatTileForCount(
    tester,
    keyName: keyName,
    count: count,
    context: '$capture, before the shot, the fixture\'s count',
  );
}

// --- captures 19-24 and 40: a recorded real game, replayed -----------------

/// The two recorded games, decoded once from the Dart copy of
/// `real_games.json` (integration_test/fixtures/real_games_fixture.dart, the
/// file that packages/ludo_server/tool/wrap_real_games_fixture.dart writes).
final Map<String, Object?> _realGamesFixture =
    jsonDecode(realGamesJson) as Map<String, Object?>;

/// The four numbers an end card's stat tiles read, for one seat of one
/// recorded game, taken from the fixture's `counts` at run time.
class _RealStatCounts {
  const _RealStatCounts({
    required this.rolls,
    required this.sixes,
    required this.captures,
    required this.home,
  });

  final int rolls;
  final int sixes;
  final int captures;
  final int home;

  @override
  String toString() =>
      'rolls $rolls, sixes $sixes, captures $captures, home $home';
}

/// One game of the fixture, read through the schema of
/// work/ludo/orders/574-real-game-recorder.md.
class _RealGame {
  _RealGame(this.json);

  final Map<String, Object?> json;

  String get name => json['name']! as String;
  int get winner => json['winner']! as int;
  int get playerCount => json['players']! as int;

  String nameOf(int seat) =>
      (json['names']! as Map<String, Object?>)['$seat']! as String;

  /// Every frame the socket of [seat] received, verbatim, in arrival order,
  /// through `game_over`.
  List<Map<String, Object?>> view(int seat) => <Map<String, Object?>>[
    for (final Object? f
        in (json['views']! as Map<String, Object?>)['$seat']! as List<Object?>)
      f! as Map<String, Object?>,
  ];

  List<int> finalTokens(int seat) => <int>[
    for (final Object? t
        in (json['final_tokens']! as Map<String, Object?>)['$seat']!
            as List<Object?>)
      t! as int,
  ];

  _RealStatCounts counts(int seat) {
    final Map<String, Object?> c =
        (json['counts']! as Map<String, Object?>)['$seat']!
            as Map<String, Object?>;
    return _RealStatCounts(
      rolls: c['rolls']! as int,
      sixes: c['sixes']! as int,
      captures: c['captures_made']! as int,
      home: c['home']! as int,
    );
  }
}

_RealGame _realGame(String name) {
  final List<Object?> games = _realGamesFixture['games']! as List<Object?>;
  for (final Object? g in games) {
    final _RealGame game = _RealGame(g! as Map<String, Object?>);
    if (game.name == name) {
      return game;
    }
  }
  throw TestFailure(
    'real_games.json holds no game named "$name"; it holds '
    '${<String>[for (final Object? g in games) (g! as Map<String, Object?>)['name']! as String]}. '
    'A re-record that renames games needs the captures moved with it.',
  );
}

/// The one rewrite a replayed frame is allowed: its `re`. A recorded `re`
/// that answers a request this device really sent (create or join, and
/// `start_game` on the host) is swapped for that request's id; every other
/// `re` answers a request the device never sent (the recorder's own
/// set_seed, and the roll and move requests the replay plays for it) and is
/// dropped. A frame without `re` is encoded as it was recorded.
class _ReplayRe {
  _ReplayRe();

  /// Recorded request id -> the id this device's request carried.
  final Map<String, String> deviceIds = <String, String>{};

  int pushed = 0;
  int rewritten = 0;
  int dropped = 0;
  final Map<String, int> droppedByType = <String, int>{};

  String wire(Map<String, Object?> frame) {
    pushed += 1;
    final Object? re = frame['re'];
    if (re == null) {
      return jsonEncode(frame);
    }
    final String? id = deviceIds[re];
    if (id != null) {
      rewritten += 1;
      return jsonEncode(<String, Object?>{...frame, 're': id});
    }
    dropped += 1;
    final String type = frame['t']! as String;
    droppedByType[type] = (droppedByType[type] ?? 0) + 1;
    return jsonEncode(<String, Object?>{...frame}..remove('re'));
  }
}

/// A recorded game, replayed up to the frame before its `game_over`.
class _RealReplay {
  _RealReplay({
    required this.capture,
    required this.game,
    required this.seat,
    required this.controller,
    required this.transport,
    required this.roomCode,
    required this.counts,
    required this.re,
    required this.gameOver,
  });

  final String capture;
  final _RealGame game;
  final int seat;
  final RoomController controller;
  final FakeTransport transport;
  final String roomCode;

  /// The fixture's `counts` for [seat]: the numbers the end card must show.
  final _RealStatCounts counts;
  final _ReplayRe re;

  /// The recorded `game_over`, the only frame not yet pushed.
  final Map<String, Object?> gameOver;

  /// Pushes the recorded `game_over` (its `re` handled like any other).
  void pushGameOver() => transport.pushText(re.wire(gameOver));

  /// The recorded `game_over`'s own `seq`.
  int get gameOverSeq =>
      (gameOver['d']! as Map<String, Object?>)['seq']! as int;

  /// For a failure message: which recorded view this device was.
  String get describe =>
      'fixture game "${game.name}", view of seat $seat; reproduce with '
      '`flutter test integration_test/screenshots_test.dart -d flutter-tester '
      '--plain-name "$capture"`';
}

/// The state [_enterRealGame] hands on: the recorded view, the cursor into it,
/// and the device's controller and transport.
class _RealEntry {
  _RealEntry({
    required this.where,
    required this.game,
    required this.seat,
    required this.view,
    required this.controller,
    required this.transport,
    required this.roomCode,
    required this.isHost,
    required this.re,
    required this.next,
    required this.firstPushToAbsorbed,
  });

  final String where;
  final _RealGame game;
  final int seat;
  final List<Map<String, Object?>> view;
  final RoomController controller;
  final FakeTransport transport;
  final String roomCode;
  final bool isHost;
  final _ReplayRe re;
  final Stopwatch firstPushToAbsorbed;

  /// Index in [view] of the next frame to push.
  int next;

  /// Pushes the next recorded frame of [view] verbatim (see [_ReplayRe]).
  void push() => transport.pushText(re.wire(view[next++]));
}

/// The part of every replay up to the first game frame: the device's own
/// entry (recorded name, Create or Join with the recorded code, Start for the
/// host), then the recorded frames through `game_started`, one by one, and the
/// board mounted. Returns with the view's cursor on the first frame after
/// `game_started`. Shared by [_replayRealGame] and
/// [_replayRealGameToCapture]; the checks of the recorded view and the
/// device's own requests are the same for both.
///
/// [seatAllBeforeStart] is for a host at a table of more than two: the
/// recorded host `room` frame holds only the host, so every `player_joined`
/// that follows is pushed before the lobby is checked and Start is tapped.
/// The default keeps the one-join entry of a two-seat game.
Future<_RealEntry> _enterRealGame(
  WidgetTester tester,
  _ScreenshotControllerFactory factory, {
  required String capture,
  required String gameName,
  required int seat,
  required String localeName,
  bool seatAllBeforeStart = false,
}) async {
  final _RealGame game = _realGame(gameName);
  final List<Map<String, Object?>> view = game.view(seat);
  final String where =
      '$capture: replay of fixture game "$gameName", view of seat $seat. '
      'Reproduce with `flutter test integration_test/screenshots_test.dart '
      '-d flutter-tester --plain-name "$capture"`';

  expect(
    view.map((Map<String, Object?> f) => f['t']).take(2).toList(),
    <String>['seat_assigned', 'room'],
    reason: '$where: a recorded view must open with seat_assigned and room',
  );
  expect(
    (view[0]['d']! as Map<String, Object?>)['seat'],
    seat,
    reason: '$where: the first frame must assign the seat this device plays',
  );
  expect(
    view.last['t'],
    'game_over',
    reason: '$where: a recorded view must end with game_over',
  );
  final Map<String, Object?> roomData = view[1]['d']! as Map<String, Object?>;
  final String roomCode = roomData['code']! as String;
  final bool isHost = roomData['host_seat'] == seat;
  final String playerName = game.nameOf(seat);
  final int seatCount = (roomData['players']! as int) == game.playerCount
      ? game.playerCount
      : -1;
  expect(
    seatCount,
    isNot(-1),
    reason: '$where: room.players disagrees with the game record',
  );
  expect(
    view[1]['re'],
    isA<String>(),
    reason: '$where: the opening room frame must answer a request',
  );

  // The device's own entry: its recorded name, then Create or Join.
  await tester.enterText(find.byKey(const Key('home-name-field')), playerName);
  if (isHost) {
    await _tapCreateRoom(tester);
  } else {
    expect(
      isValidRoomCode(roomCode),
      isTrue,
      reason: '$where: the recorded room code "$roomCode" is not typeable',
    );
    await tester.enterText(find.byKey(const Key('room-code-field')), roomCode);
    // Join is in the tree only once the field holds a full code (C-523 D3).
    await tester.pumpAndSettle();
    await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));
  }

  expect(factory.controllers, hasLength(1), reason: '$where: one controller');
  final RoomController controller = factory.controllers.single;
  final FakeTransport transport = factory.transports.single;

  final String openType = isHost ? 'create_room' : 'join_room';
  final List<String> opening = transport.sentRaw
      .where((String s) => _typeOf(s) == openType)
      .toList();
  expect(
    opening,
    hasLength(1),
    reason:
        '$where: expected exactly one $openType from the lobby; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  final Map<String, Object?> openData =
      _decode(opening.single)['d']! as Map<String, Object?>;
  expect(
    openData['name'],
    playerName,
    reason: '$where: the request must carry the recorded name',
  );
  if (!isHost) {
    expect(
      openData['code'],
      roomCode,
      reason: '$where: the join must carry the recorded room code',
    );
  }

  final _ReplayRe re = _ReplayRe();
  re.deviceIds[view[1]['re']! as String] = _idOf(opening.single);

  var next = 0;
  void push() => transport.pushText(re.wire(view[next++]));

  final Stopwatch firstPushToAbsorbed = Stopwatch()..start();
  push(); // seat_assigned
  push(); // room, answering the create or join
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byType(LobbyScreen),
    '$where: LobbyScreen after the room frame carrying code "$roomCode"',
  );

  if (isHost) {
    expect(
      view[next]['t'],
      'player_joined',
      reason: '$where: the host view must show the guest joining next',
    );
    push();
    while (seatAllBeforeStart && view[next]['t'] == 'player_joined') {
      push();
    }
    await tester.pump();
  }
  await _expectLobbyScreen(
    tester,
    localeName: localeName,
    code: roomCode,
    // A guest's lobby holds the seats its recorded `room` lists; seats that
    // join after it (a four-seat game) arrive as later `player_joined`s.
    expectedSeatCount: isHost
        ? seatCount
        : (roomData['seats']! as List<Object?>).length,
  );

  if (isHost) {
    final Finder startButton = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton,
      findsOneWidget,
      reason: '$where: the host must see a Start button once seated',
    );
    if (tester.platformDispatcher.textScaleFactor > 1.0) {
      // Under a larger system text scale Start sits below the fold, as a
      // player would scroll to it.
      await tester.ensureVisible(startButton);
      await tester.pump();
    }
    await tester.tap(startButton);
    await tester.pump();
    final List<String> starts = transport.sentRaw
        .where((String s) => _typeOf(s) == 'start_game')
        .toList();
    expect(
      starts,
      hasLength(1),
      reason: '$where: tapping Start must send exactly one start_game',
    );
    final Map<String, Object?> started = view.firstWhere(
      (Map<String, Object?> f) => f['t'] == 'game_started',
    );
    expect(
      started['re'],
      isA<String>(),
      reason: '$where: the host view\'s game_started must answer start_game',
    );
    re.deviceIds[started['re']! as String] = _idOf(starts.single);
  }

  // From here the recorded server speaks: seat seeds, then game_started.
  while (view[next]['t'] != 'game_started') {
    push();
  }
  push(); // game_started
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byType(GameScreen),
    '$where: GameScreen after the game_started push',
  );
  expect(
    find.byType(LobbyScreen),
    findsNothing,
    reason: '$where: RoomRoute must latch onto GameScreen and never go back',
  );

  return _RealEntry(
    where: where,
    game: game,
    seat: seat,
    view: view,
    controller: controller,
    transport: transport,
    roomCode: roomCode,
    isHost: isHost,
    re: re,
    next: next,
    firstPushToAbsorbed: firstPushToAbsorbed,
  );
}

/// Drives a capture the way a real player meets it, from the device's home
/// screen to the last frame before `game_over`, from the recorded [seat]'s
/// view of the fixture game [gameName]: the name typed is the name recorded
/// for that seat; Create (the host) or Join with the recorded room code (a
/// guest) is tapped; then the view's frames are pushed verbatim, in order,
/// with the device's own tap where a real client must make it (Start, for
/// the host, once the recorded `player_joined` has put the second seat in the
/// lobby). The only rewrite is `re` (see [_ReplayRe]). The frames from the
/// first `seat_seed` through `game_started` go in one by one, then the board
/// is mounted, then every frame up to the one before `game_over` goes in as
/// one burst, as the hand-typed script did before order 576, and two pumps
/// let the screen absorb it. The caller pushes `game_over` with
/// [_RealReplay.pushGameOver] and keeps its own post-`game_over` asserts.
///
/// The home screen must already be on screen in [localeName] (the caller's
/// [_expectHomeScreen]). [capture] is only for the failure messages.
/// [seatAllBeforeStart] is [_enterRealGame]'s.
Future<_RealReplay> _replayRealGame(
  WidgetTester tester,
  _ScreenshotControllerFactory factory, {
  required String capture,
  required String gameName,
  required int seat,
  required String localeName,
  bool seatAllBeforeStart = false,
}) async {
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: gameName,
    seat: seat,
    localeName: localeName,
    seatAllBeforeStart: seatAllBeforeStart,
  );
  final String where = entry.where;
  final _RealGame game = entry.game;
  final List<Map<String, Object?>> view = entry.view;
  final RoomController controller = entry.controller;
  final FakeTransport transport = entry.transport;
  final String roomCode = entry.roomCode;
  final bool isHost = entry.isHost;
  final _ReplayRe re = entry.re;
  final Stopwatch firstPushToAbsorbed = entry.firstPushToAbsorbed;
  void push() => entry.push();

  // The game itself, up to the frame before game_over, in one burst.
  final int gameOverIndex = view.length - 1;
  while (entry.next < gameOverIndex) {
    push();
  }
  await tester.pump();
  await tester.pump();

  final int lastSeq =
      (view[gameOverIndex - 1]['d']! as Map<String, Object?>)['seq']! as int;
  expect(
    controller.hasDesynced,
    isFalse,
    reason:
        '$where: seq gap (room seq ${controller.room?.seq}, last pushed '
        'seq $lastSeq)',
  );
  expect(
    controller.room?.seq,
    lastSeq,
    reason: '$where: the controller must have absorbed every frame',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: '$where: the replay must still be in play before game_over',
  );
  for (final int s in <int>[0, 2]) {
    expect(
      _endCardTokens(controller, s),
      game.finalTokens(s),
      reason:
          '$where: seat $s tokens after the last frame before game_over '
          'must be the recorded final_tokens',
    );
  }
  expect(
    transport.sentRaw.map(_typeOf).toList(),
    isHost ? <String>['create_room', 'start_game'] : <String>['join_room'],
    reason:
        '$where: the device must have sent only its own lobby requests; the '
        'replay plays every roll and move for it',
  );

  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "$gameName" from seat $seat: '
    '${re.pushed} frames pushed before game_over, ${re.rewritten} re '
    'rewritten to this device\'s request ids, ${re.dropped} re dropped '
    '${re.droppedByType}; ${firstPushToAbsorbed.elapsedMilliseconds} ms from '
    'the first push to the last pre-game_over frame absorbed',
  );

  return _RealReplay(
    capture: capture,
    game: game,
    seat: seat,
    controller: controller,
    transport: transport,
    roomCode: roomCode,
    counts: game.counts(seat),
    re: re,
    gameOver: view[gameOverIndex],
  );
}

/// One capturing `moved` of a recorded view, found at run time, and the
/// frames around it: [turnIndex] is the first `turn` after it. Every number a
/// capture asserts about the capture is read off these frames.
class _RealCaptureFrame {
  _RealCaptureFrame({
    required this.index,
    required this.turnIndex,
    required this.moved,
    required this.turn,
  });

  /// Index of the `moved` in the recorded view of the device's seat.
  final int index;

  /// Index of the first `turn` after it in the same view.
  final int turnIndex;

  final Map<String, Object?> moved;
  final Map<String, Object?> turn;

  Map<String, Object?> get _movedData => moved['d']! as Map<String, Object?>;
  Map<String, Object?> get _struck =>
      (_movedData['captured']! as List<Object?>).single!
          as Map<String, Object?>;

  int get moverSeat => _movedData['seat']! as int;
  int get moverToken => _movedData['token']! as int;
  int get from => _movedData['from']! as int;
  int get to => _movedData['to']! as int;
  int get face => _movedData['face']! as int;
  int get capturedSeat => _struck['seat']! as int;
  int get capturedToken => _struck['token']! as int;
  int get turnSeat => (turn['d']! as Map<String, Object?>)['seat']! as int;

  @override
  String toString() =>
      'view index $index: seat $moverSeat token $moverToken $from to $to '
      'face $face, struck seat $capturedSeat token $capturedToken, next turn '
      'at index $turnIndex for seat $turnSeat';
}

/// The [ordinal]th (1-based) capturing `moved` made by [moverSeat] in the
/// recorded [view] of [viewSeat], found by scanning the frames. The
/// recorder's own `events` list is the cross-check: it must name the same
/// frame, or the fixture and its index disagree.
_RealCaptureFrame _locateRealCapture(
  _RealGame game,
  List<Map<String, Object?>> view,
  int viewSeat, {
  required int moverSeat,
  required int ordinal,
  required String where,
}) {
  var seen = 0;
  int? index;
  for (var i = 0; i < view.length; i++) {
    final Map<String, Object?> frame = view[i];
    if (frame['t'] != 'moved') {
      continue;
    }
    final Map<String, Object?> d = frame['d']! as Map<String, Object?>;
    if (d['seat'] != moverSeat || (d['captured']! as List<Object?>).isEmpty) {
      continue;
    }
    seen++;
    if (seen == ordinal) {
      index = i;
      break;
    }
  }
  if (index == null) {
    throw TestFailure(
      '$where: expected capture number $ordinal by seat $moverSeat in the '
      'recorded view, found only $seen',
    );
  }
  final List<Object?> events = <Object?>[
    for (final Object? e in game.json['events']! as List<Object?>)
      if ((e! as Map<String, Object?>)['kind'] == 'capture' &&
          (e as Map<String, Object?>)['by'] == moverSeat)
        e,
  ];
  final Object? recorded = ordinal <= events.length
      ? (((events[ordinal - 1]! as Map<String, Object?>)['view_index']!
            as Map<String, Object?>)['$viewSeat'])
      : null;
  if (recorded != index) {
    throw TestFailure(
      '$where: the scan found capture $ordinal by seat $moverSeat at view '
      'index $index but the recorder\'s events say $recorded',
    );
  }
  final Map<String, Object?> moved = view[index];
  final Map<String, Object?> movedData = moved['d']! as Map<String, Object?>;
  if ((movedData['captured']! as List<Object?>).length != 1 ||
      movedData['extra_roll'] != true) {
    throw TestFailure(
      '$where: expected one struck token and extra_roll true on the '
      'capturing moved at view index $index, got $movedData',
    );
  }
  var turnIndex = index + 1;
  while (turnIndex < view.length && view[turnIndex]['t'] != 'turn') {
    turnIndex++;
  }
  if (turnIndex >= view.length) {
    throw TestFailure('$where: no turn frame after view index $index');
  }
  final _RealCaptureFrame found = _RealCaptureFrame(
    index: index,
    turnIndex: turnIndex,
    moved: moved,
    turn: view[turnIndex],
  );
  if (found.turnSeat != moverSeat) {
    throw TestFailure(
      '$where: a capture grants the mover another roll, but the next turn '
      'frame ($found) is not the mover\'s',
    );
  }
  return found;
}

/// The progress the recorded frames of [view] before index [before] leave
/// [seat]'s [token] at: the `to` of its last `moved`, or -1 once a `moved`
/// has struck it (and for a token no frame has moved).
int _recordedProgress(
  List<Map<String, Object?>> view,
  int before,
  int seat,
  int token,
) {
  var progress = -1;
  for (var i = 0; i < before; i++) {
    if (view[i]['t'] != 'moved') {
      continue;
    }
    final Map<String, Object?> d = view[i]['d']! as Map<String, Object?>;
    if (d['seat'] == seat && d['token'] == token) {
      progress = d['to']! as int;
    }
    for (final Object? c in d['captured']! as List<Object?>) {
      final Map<String, Object?> struck = c! as Map<String, Object?>;
      if (struck['seat'] == seat && struck['token'] == token) {
        progress = -1;
      }
    }
  }
  return progress;
}

/// A recorded game replayed to a capture and one turn past it.
class _RealCaptureReplay {
  _RealCaptureReplay({
    required this.capture,
    required this.entry,
    required this.found,
    required this.sinceLanding,
  });

  final String capture;
  final _RealEntry entry;
  final _RealCaptureFrame found;

  /// Wall time since the capturing walk landed (the struck token's flight
  /// home was first seen), which is when the gloat starts.
  final Stopwatch sinceLanding;

  RoomController get controller => entry.controller;
  FakeTransport get transport => entry.transport;

  /// For a failure message: which recorded capture this device is on.
  String get describe =>
      'fixture game "${entry.game.name}", view of seat ${entry.seat}, capture '
      '${found.toString()}; reproduce with `flutter test '
      'integration_test/screenshots_test.dart -d flutter-tester --plain-name '
      '"$capture"`';
}

/// Pumps in 50 ms steps until the struck token's flight home is on the board
/// (the capturing walk has landed) and then until it is gone. Returns a
/// stopwatch started when the flight was first seen, which is when the gloat
/// begins. Bounded: a walk that never lands fails with [where].
Future<Stopwatch> _pumpThroughCaptureWalk(
  WidgetTester tester, {
  required _RealCaptureFrame found,
  required String where,
}) async {
  final Finder flight = find.byKey(
    Key('board-capture-flight-${found.capturedSeat}-${found.capturedToken}'),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  var steps = 0;
  while (flight.evaluate().isEmpty) {
    if (steps++ >= 60) {
      throw TestFailure(
        '$where: expected the capturing walk to land and the struck token '
        '(seat ${found.capturedSeat} token ${found.capturedToken}) to start '
        'its flight home within 3 s of the capturing moved, saw no '
        'board-capture-flight key; the board snapped or never moved it',
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  final Stopwatch sinceLanding = Stopwatch()..start();
  steps = 0;
  while (flight.evaluate().isNotEmpty) {
    if (steps++ >= 40) {
      throw TestFailure(
        '$where: the struck token\'s flight home was still on the board 2 s '
        'after it began',
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  return sinceLanding;
}

/// What waiting for the queued thrown dice cost: pumps, test-clock and wall
/// milliseconds, and how many distinct throws were seen on the board.
class _ThrowDrain {
  _ThrowDrain({
    required this.pumps,
    required this.clockMs,
    required this.wallMs,
    required this.throwsSeen,
    required this.queuedAtStart,
  });

  final int pumps;
  final int clockMs;
  final int wallMs;
  final int throwsSeen;
  final int queuedAtStart;

  String get describe =>
      '$pumps pumps, $clockMs ms on the test clock, $wallMs ms wall time, '
      '$throwsSeen throws seen on the board, $queuedAtStart recentRolls '
      'entries newer than the die showing at the start';
}

/// How many thrown dice the board shows, with the face of each.
List<BoardThrownDie> _thrownDice(WidgetTester tester) => tester
    .widgetList<BoardThrownDie>(find.byType(BoardThrownDie))
    .toList(growable: false);

/// The throw queue lives in the game screen's state, so its length cannot be
/// read: this counts the `recentRolls` entries newer than the die showing, an
/// upper bound (the device's own rolls are never thrown).
int _rollsNewerThanShownDie(RoomController controller, BoardThrownDie? die) {
  final Key? key = die?.key;
  if (key is! ValueKey<int>) {
    return 0;
  }
  final List<(int k, int face)> rolls =
      controller.room?.recentRolls ?? const <(int k, int face)>[];
  return rolls.where(((int k, int face) r) => r.$1 > key.value).length;
}

/// Pumps in 50 ms steps until no [BoardThrownDie] is in the tree, and until it
/// stays absent for two consecutive pumps (the queue hands the next throw on
/// in the pump after one ends). Bounded by 60 s of wall time: a queue that
/// needs longer fails with its drain rate rather than being cut short.
Future<_ThrowDrain> _pumpUntilThrownDiceGone(
  WidgetTester tester,
  RoomController controller, {
  required String capture,
  required String where,
  int maxWallMs = 60000,
}) async {
  final Stopwatch wall = Stopwatch()..start();
  final Set<int> seen = <int>{};
  final int queuedAtStart = _rollsNewerThanShownDie(
    controller,
    _thrownDice(tester).isEmpty ? null : _thrownDice(tester).first,
  );
  var pumps = 0;
  var absent = 0;
  while (absent < 2) {
    final List<BoardThrownDie> dice = _thrownDice(tester);
    if (dice.isEmpty) {
      absent++;
    } else {
      absent = 0;
      for (final BoardThrownDie die in dice) {
        final Key? key = die.key;
        if (key is ValueKey<int>) {
          seen.add(key.value);
        }
      }
      if (wall.elapsedMilliseconds >= maxWallMs) {
        final String showing = dice
            .map((BoardThrownDie d) => 'seat ${d.seat} face ${d.face}')
            .join(', ');
        final double perSecond = pumps == 0 ? 0 : seen.length / (pumps * 0.05);
        throw TestFailure(
          '$capture: expected every queued thrown die to be gone within '
          '${maxWallMs ~/ 1000} s of wall time before the capturing moved, '
          'but a thrown die ($showing) was still up after $pumps pumps '
          '(${pumps * 50} ms on the test clock); ${seen.length} throws seen '
          'so far (${perSecond.toStringAsFixed(2)} per test-clock second), '
          '${_rollsNewerThanShownDie(controller, dice.first)} recentRolls '
          'entries newer than the die showing; $where',
        );
      }
    }
    await tester.pump(const Duration(milliseconds: 50));
    pumps++;
  }
  return _ThrowDrain(
    pumps: pumps,
    clockMs: pumps * 50,
    wallMs: wall.elapsedMilliseconds,
    throwsSeen: seen.length,
    queuedAtStart: queuedAtStart,
  );
}

/// Drives a capture the way [_replayRealGame] does (home screen, recorded
/// name, Create or Join with the recorded code, Start for the host, the `re`
/// rule), then stops at a capture of the recorded game: every frame before
/// the [ordinal]th capturing `moved` made by [moverSeat] is pushed and
/// absorbed, the `moved` is pushed alone and the board walks it for real (the
/// walk lands, the struck token flies home, the gloat starts at landing), and
/// then the frames behind it are pushed up to and including the next `turn`.
/// Nothing in any frame changes except `re`. The capture is located in the
/// fixture at run time, never by a typed index.
Future<_RealCaptureReplay> _replayRealGameToCapture(
  WidgetTester tester,
  _ScreenshotControllerFactory factory, {
  required String capture,
  required String gameName,
  required int seat,
  required int moverSeat,
  required int ordinal,
  required String localeName,
}) async {
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: gameName,
    seat: seat,
    localeName: localeName,
  );
  final _RealCaptureFrame found = _locateRealCapture(
    entry.game,
    entry.view,
    seat,
    moverSeat: moverSeat,
    ordinal: ordinal,
    where: entry.where,
  );
  final String where = '${entry.where}; capture $found';
  final RoomController controller = entry.controller;
  final List<String> lobbyRequests = entry.isHost
      ? <String>['create_room', 'start_game']
      : <String>['join_room'];

  // The burst stops short of the roll the capture spends, and the throws it
  // queued land first. The capture's own roll then comes in about as long
  // before the walk as a player takes to tap, so its turn's countdown has
  // not been running through the whole drain when the shot is taken.
  var captureRoll = found.index - 1;
  while (captureRoll > entry.next && entry.view[captureRoll]['t'] != 'rolled') {
    captureRoll--;
  }
  while (entry.next < captureRoll) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; before the capture roll',
  );

  while (entry.next < found.index) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();

  int seqOf(int index) =>
      (entry.view[index]['d']! as Map<String, Object?>)['seq']! as int;
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap before the capturing moved',
  );
  expect(
    controller.room?.seq,
    seqOf(found.index - 1),
    reason: '$where: the controller must have absorbed every frame before it',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: '$where: the replay must be in play at the capture',
  );
  expect(
    _endCardTokens(controller, found.moverSeat)[found.moverToken],
    found.from,
    reason:
        '$where: before the capturing moved, expected the mover\'s token on '
        '${found.from}',
  );
  final int struckAt = _recordedProgress(
    entry.view,
    found.index,
    found.capturedSeat,
    found.capturedToken,
  );
  expect(
    struckAt,
    isNot(-1),
    reason:
        '$where: the recorded frames before the capturing moved leave the '
        'struck token in its yard, so there is nothing to send home',
  );
  expect(
    _endCardTokens(controller, found.capturedSeat)[found.capturedToken],
    struckAt,
    reason:
        '$where: before the capturing moved, expected the struck token (seat '
        '${found.capturedSeat} token ${found.capturedToken}) on $struckAt, '
        'where the recorded frames before it left it',
  );
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: before the capturing moved the device must have sent only '
        'its own lobby requests',
  );

  // A gloat still up from an earlier capture in the frames just absorbed
  // would be taken for this capture's, so it runs out first.
  final Finder anyGloat = find.byWidgetPredicate(
    (Widget w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('capture-gloat-'),
  );
  var gloatSteps = 0;
  while (anyGloat.evaluate().isNotEmpty) {
    if (gloatSteps++ >= 60) {
      throw TestFailure(
        '$where: a gloat from an earlier frame was still up 3 s after the '
        'frames before the capture were absorbed',
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: waiting out an earlier gloat, the device must still have '
        'sent only its own lobby requests (no held move may fire)',
  );

  // Every throw the burst queued has landed and gone before the capture: in a
  // real game the capturer taps the move long after the last die rested. A
  // thrown die still up would paint over the gloat.
  final _ThrowDrain drain = await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: where,
  );
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: waiting out the queued throws, the device must still have '
        'sent only its own lobby requests (no held move may fire)',
  );

  // The capture alone, walked for real.
  entry.push();
  final Stopwatch sinceLanding = await _pumpThroughCaptureWalk(
    tester,
    found: found,
    where: where,
  );

  // The frames behind it, through the next turn.
  while (entry.next <= found.turnIndex) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap after the capturing moved',
  );
  expect(
    controller.room?.seq,
    seqOf(found.turnIndex),
    reason: '$where: the controller must have absorbed the turn frame',
  );
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: the device must have sent only its own lobby requests; the '
        'replay plays every roll and move for it',
  );

  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "$gameName" from seat $seat to '
    'capture $ordinal by seat $moverSeat ($found): ${entry.re.pushed} frames '
    'pushed, ${entry.re.rewritten} re rewritten to this device\'s request '
    'ids, ${entry.re.dropped} re dropped ${entry.re.droppedByType}; the '
    'replay returns ${sinceLanding.elapsedMilliseconds} ms after landing; '
    'queued throws needed ${drain.describe}',
  );

  return _RealCaptureReplay(
    capture: capture,
    entry: entry,
    found: found,
    sinceLanding: sinceLanding,
  );
}

/// The painted opacity of the capture gloat on [seat]'s yard: the `Opacity`
/// that `CaptureGloat` wraps its face in, read off the tree. Fails if the
/// gloat is absent.
double _gloatOpacity(WidgetTester tester, int seat, String where) {
  final Finder gloat = find.byKey(Key('capture-gloat-$seat'));
  expect(
    gloat,
    findsOneWidget,
    reason: '$where: expected capture-gloat-$seat in the tree',
  );
  final Finder opacity = find.descendant(
    of: gloat,
    matching: find.byType(Opacity),
  );
  expect(
    opacity,
    findsOneWidget,
    reason: '$where: expected one Opacity under capture-gloat-$seat',
  );
  return tester.widget<Opacity>(opacity).opacity;
}

/// Immediately before the shot: `capture-gloat-<capturer seat>` is in the tree
/// and the `Opacity` its face paints with reads 1.0. A gloat that has begun to
/// fade is the old fault (the store frame caught it leaving), so a failure
/// names the gloat's age. Returns the opacity read.
double _expectGloatAtFullOpacity(
  WidgetTester tester,
  _RealCaptureReplay replay,
  String momentDescription,
) {
  final int seat = replay.found.moverSeat;
  final int ageMs = replay.sinceLanding.elapsedMilliseconds;
  expect(
    ageMs,
    lessThan(_captureShotMaxAgeMs),
    reason:
        '${replay.capture} ($momentDescription): expected the shot within '
        '$_captureShotMaxAgeMs ms of the capturing walk landing, got $ageMs '
        'ms by wall time; the gloat holds full opacity for 1350 ms and is '
        'gone at 1600 ms, so a slower device must shorten '
        '_captureShotSettleFrames. ${replay.describe}',
  );
  final List<BoardThrownDie> dice = _thrownDice(tester);
  expect(
    dice,
    isEmpty,
    reason:
        '${replay.capture} ($momentDescription): expected no BoardThrownDie '
        'on the board at the shot (it paints over the gloat), found '
        '${dice.map((BoardThrownDie d) => 'seat ${d.seat} face ${d.face}').join(', ')}; '
        'the capture itself is face ${replay.found.face}. ${replay.describe}',
  );
  final double opacity = _gloatOpacity(
    tester,
    seat,
    '${replay.capture} ($momentDescription)',
  );
  expect(
    opacity,
    1.0,
    reason:
        '${replay.capture} ($momentDescription): expected the Opacity under '
        'capture-gloat-$seat to read 1.0, got $opacity; the gloat is '
        '${replay.sinceLanding.elapsedMilliseconds} ms old by wall time '
        '(it holds full opacity for 1350 ms and is gone at 1600 ms). '
        '${replay.describe}',
  );
  // ignore: avoid_print
  print(
    'screenshots_test: ${replay.capture} gloat opacity $opacity at '
    '$momentDescription, ${replay.sinceLanding.elapsedMilliseconds} ms after '
    'landing',
  );
  return opacity;
}

/// Captures 19-22 and 40: each stat tile with a positive count is on screen
/// and shows it; a tile whose count is 0 is absent (C-533 D3). Callers pass
/// the fixture's `counts` for the device's seat in the recorded game they
/// replayed, read at run time (see [_RealReplay.counts]), never typed.
void _expectEndCardStatTiles(
  WidgetTester tester, {
  required int rolls,
  required int sixes,
  required int captures,
  required int home,
  required String momentDescription,
}) {
  _expectOneEndCardStat(
    tester,
    keyName: 'end-card-stat-rolls',
    count: rolls,
    momentDescription: momentDescription,
  );
  _expectOneEndCardStat(
    tester,
    keyName: 'end-card-stat-sixes',
    count: sixes,
    momentDescription: momentDescription,
  );
  _expectOneEndCardStat(
    tester,
    keyName: 'end-card-stat-captures',
    count: captures,
    momentDescription: momentDescription,
  );
  _expectOneEndCardStat(
    tester,
    keyName: 'end-card-stat-home',
    count: home,
    momentDescription: momentDescription,
  );
}

void _expectOneEndCardStat(
  WidgetTester tester, {
  required String keyName,
  required int count,
  required String momentDescription,
}) {
  _expectStatTileForCount(
    tester,
    keyName: keyName,
    count: count,
    context: 'capture 19/20/21/22/40 ($momentDescription)',
  );
}

/// C-533 D3 for one tile: a count above 0 puts [keyName] on screen reading
/// that number, a count of 0 leaves the tile out of the tree altogether,
/// offstage included.
void _expectStatTileForCount(
  WidgetTester tester, {
  required String keyName,
  required int count,
  required String context,
}) {
  if (count == 0) {
    expect(
      find.byKey(Key(keyName), skipOffstage: false),
      findsNothing,
      reason:
          '$context: C-533 D3, $keyName counts 0 so the tile must be '
          'absent, it is in the tree',
    );
    return;
  }
  final Finder tile = find.byKey(Key(keyName));
  expect(
    tile,
    findsOneWidget,
    reason: '$context: expected $keyName on screen for a count of $count',
  );
  expect(
    find.descendant(of: tile, matching: find.text('$count')),
    findsOneWidget,
    reason: '$context: expected $keyName to show $count',
  );
}

/// Order 240, captures 19 through 22: asserts [controller].room reports
/// `RoomState.finished` with `winner == expectedWinner`, and that
/// `game-screen-winner`'s own `Text` reads [expectedText] -- the caller's
/// own `AppLocalizations.endWinTitle` or
/// `AppLocalizations.endLoseTitle(name)` lookup, never hardcoded
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
  // The lose title is a Text.rich (the winner's name in the winner's seat
  // colour), so Text.data is null there; read the span's plain text too.
  final Text winnerText = tester.widget<Text>(winnerFinder);
  final String? shown = winnerText.data ?? winnerText.textSpan?.toPlainText();
  expect(
    shown,
    expectedText,
    reason:
        'capture 19/20/21/22 ($momentDescription): expected '
        'game-screen-winner\'s Text to read "$expectedText", got '
        '"$shown"',
  );
}

// --- captures 25 and 26: end card after a mid-game reconnect -------------

/// HomeScreen's factory for captures 25 and 26. Every `connect` builds a
/// new transport, so the automatic reconnect after a drop is a second
/// socket rather than the one [endFromFarSide] already closed.
///
/// The first delay is short enough that the real-time pumps below reach
/// it. Capture 10 keeps a five-minute delay so its settle does not
/// reconnect; this capture has to reconnect, and then has to sit still
/// for its own settle, so the second delay stays at five minutes and is
/// only armed if the first attempt fails.
class _ReconnectCaptureFactory extends _ScreenshotControllerFactory {
  static const List<Duration> delays = <Duration>[
    Duration(milliseconds: 50),
    Duration(minutes: 5),
  ];

  @override
  RoomController call() {
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
      autoReconnectDelays: delays,
    );
    controllers.add(created);
    return created;
  }
}

List<String> _sentOfType(FakeTransport transport, String type) =>
    transport.sentRaw.where((String raw) => _typeOf(raw) == type).toList();

/// Real-duration pumps until [ready] is true. Throws naming [description]
/// if [maxPumps] elapses first. The same bounded substitute for
/// pumpAndSettle that [_pumpUntilFound] is, for a condition that is not a
/// finder.
Future<void> _pumpUntilReady(
  WidgetTester tester,
  bool Function() ready,
  String description, {
  int maxPumps = 100,
  Duration frame = const Duration(milliseconds: 32),
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (ready()) {
      return;
    }
    await tester.pump(frame);
  }
  throw TestFailure(
    'timed out after $maxPumps pumps of $frame each waiting for: '
    '$description',
  );
}

List<int> _recordedInts(Object? list) => <int>[
  for (final Object? v in list! as List<Object?>) v! as int,
];

/// The room a recorded view leaves behind when its frames are folded in
/// order: tokens from `moved` and its `captured`, the turn from `turn`,
/// `rolled`, `moved` and `turn_passed`, the seq from the last frame that
/// carries one, the timer-step count from section 23 of docs/PROTOCOL.md.
class _FoldedRoom {
  _FoldedRoom({
    required this.tokens,
    required this.seq,
    required this.timerSteps,
    required this.turnSeat,
    required this.phase,
    required this.queue,
    required this.k,
    required this.deadlineMs,
  });

  final Map<int, List<int>> tokens;
  final int seq;
  final Map<int, int> timerSteps;
  final int turnSeat;
  final String phase;
  final List<int> queue;
  final int k;
  final int deadlineMs;

  int home(int seat) => tokens[seat]!.where((int p) => p == 57).length;

  /// Squares [seat] has left to bring all four tokens home, counted here
  /// from the folded tokens (a yard token needs 58: a six, then 57).
  int stepsLeft(int seat) =>
      tokens[seat]!.fold(0, (int sum, int p) => sum + (p == -1 ? 58 : 57 - p));
}

/// Folds `view[0 .. before - 1]` into a [_FoldedRoom] for [seats].
_FoldedRoom _foldRecordedView(
  List<Map<String, Object?>> view, {
  required int before,
  required List<int> seats,
}) {
  final Map<int, List<int>> tokens = <int, List<int>>{
    for (final int s in seats) s: <int>[-1, -1, -1, -1],
  };
  final Map<int, int> timerSteps = <int, int>{for (final int s in seats) s: 0};
  var seq = 0;
  var turnSeat = -1;
  var phase = 'await_roll';
  var queue = <int>[];
  var k = 0;
  var deadlineMs = -1;
  for (var i = 0; i < before; i++) {
    final String type = view[i]['t']! as String;
    final Map<String, Object?> d = view[i]['d']! as Map<String, Object?>;
    final Object? frameSeq = d['seq'];
    if (frameSeq is int) {
      seq = frameSeq;
    }
    switch (type) {
      case 'turn':
        turnSeat = d['seat']! as int;
        phase = d['phase']! as String;
        queue = _recordedInts(d['queue']);
        deadlineMs = d['deadline_ms']! as int;
      case 'rolled':
        final int seat = d['seat']! as int;
        turnSeat = seat;
        k = d['k']! as int;
        deadlineMs = d['deadline_ms']! as int;
        queue = _recordedInts(d['queue']);
        phase = (d['legal']! as List<Object?>).isEmpty
            ? 'await_roll'
            : 'await_move';
        timerSteps[seat] = d['by'] == 'timer' ? timerSteps[seat]! + 1 : 0;
      case 'moved':
        final int seat = d['seat']! as int;
        turnSeat = seat;
        tokens[seat]![d['token']! as int] = d['to']! as int;
        for (final Object? c in d['captured']! as List<Object?>) {
          final Map<String, Object?> struck = c! as Map<String, Object?>;
          tokens[struck['seat']! as int]![struck['token']! as int] = -1;
        }
        queue.remove(d['face']! as int);
        phase = 'await_roll';
        timerSteps[seat] = d['by'] == 'timer' ? timerSteps[seat]! + 1 : 0;
      case 'turn_passed':
        queue = <int>[];
        phase = 'await_roll';
    }
  }
  return _FoldedRoom(
    tokens: tokens,
    seq: seq,
    timerSteps: timerSteps,
    turnSeat: turnSeat,
    phase: phase,
    queue: queue,
    k: k,
    deadlineMs: deadlineMs,
  );
}

/// Where a recorded view drops: the first `turn` frame that hands the turn
/// to the other seat at an index at or after half the view's length.
int _locateReconnectDrop(
  List<Map<String, Object?>> view, {
  required int deviceSeat,
  required String where,
}) {
  for (var i = 0; i < view.length; i++) {
    if (i * 2 < view.length || view[i]['t'] != 'turn') {
      continue;
    }
    final Map<String, Object?> d = view[i]['d']! as Map<String, Object?>;
    if (d['seat'] != deviceSeat) {
      return i;
    }
  }
  throw TestFailure(
    '$where: expected a turn frame for the other seat at or after view '
    'index ${view.length ~/ 2}, found none',
  );
}

/// The resume point of captures 25 and 26: the index of the last `turn`
/// frame before the view's `game_over`. The turn must hand the dice to
/// [winner], at least one frame must follow it before `game_over`, and every
/// frame in between must belong to the winner's seat, so what is pushed live
/// after the snapshot is the winner's finish and nothing else.
int _locateWinnersLastTurn(
  List<Map<String, Object?>> view, {
  required int winner,
  required String where,
}) {
  final int gameOverIndex = view.length - 1;
  if (view[gameOverIndex]['t'] != 'game_over') {
    throw TestFailure(
      '$where: expected the last frame of the view to be game_over, got '
      '"${view[gameOverIndex]['t']}"',
    );
  }
  var last = -1;
  for (var i = 0; i < gameOverIndex; i++) {
    if (view[i]['t'] == 'turn') {
      last = i;
    }
  }
  if (last == -1) {
    throw TestFailure('$where: expected a turn frame before game_over, none');
  }
  final Object? turnSeat = (view[last]['d']! as Map<String, Object?>)['seat'];
  if (turnSeat != winner) {
    throw TestFailure(
      '$where: expected the last turn (view index $last) to hand the dice to '
      'the winner, seat $winner, got seat $turnSeat',
    );
  }
  if (last + 1 >= gameOverIndex) {
    throw TestFailure(
      '$where: expected at least one frame between the winner\'s last turn '
      '(view index $last) and game_over, none',
    );
  }
  for (var i = last + 1; i < gameOverIndex; i++) {
    final Object? seat = (view[i]['d']! as Map<String, Object?>)['seat'];
    if (seat != winner) {
      throw TestFailure(
        '$where: expected every frame after the last turn to belong to the '
        'winner, seat $winner, but view[$i] (${view[i]['t']}) has seat '
        '$seat',
      );
    }
  }
  return last;
}

/// The room snapshot the server would answer a `resume` with at the winner's
/// last `turn`, the room [folded] holds: the winner to roll, nothing queued.
/// Everything but the fields below is the recorded lobby snapshot (view
/// index 1) as received: code, host seat, player count, rules, chain
/// commitment and index, rematch. Game id and seeds come from `game_started`
/// and `seat_seed`; seats' tokens, the turn (seat, phase, `deadline_ms`, `k`,
/// queue), seq and timer steps from [folded]. Three fields come from neither
/// the fixture nor the fold: `state` (PLAYING, the room is mid-game), the
/// top-level `winner` (null, the game is not over) and the seats' `connected`
/// (true; the view holds no `presence`).
Map<String, Object?> _recordedResumeSnapshot(
  _RealEntry entry,
  _FoldedRoom folded,
) {
  final Map<String, Object?> lobby =
      entry.view[1]['d']! as Map<String, Object?>;
  final Map<String, Object?> started =
      entry.view.firstWhere(
            (Map<String, Object?> f) => f['t'] == 'game_started',
          )['d']!
          as Map<String, Object?>;
  expect(
    started['game_id'],
    entry.game.json['game_id'],
    reason: '${entry.where}: game_started disagrees with the game record',
  );
  expect(
    folded.phase,
    'await_roll',
    reason:
        '${entry.where}: the fold leaves the turn in ${folded.phase}; only '
        'await_roll has a snapshot the fold can build from the recording',
  );
  expect(
    folded.queue,
    isEmpty,
    reason:
        '${entry.where}: faces ${folded.queue} are left to spend in the '
        'folded room, so the turn would stay with seat ${folded.turnSeat}; '
        'the fold cannot say which legal moves they have',
  );
  final Map<int, Map<String, Object?>> seeds = <int, Map<String, Object?>>{
    for (final Map<String, Object?> f in entry.view)
      if (f['t'] == 'seat_seed')
        (f['d']! as Map<String, Object?>)['seat']! as int:
            f['d']! as Map<String, Object?>,
  };
  return <String, Object?>{
    ...lobby,
    'state': 'PLAYING',
    'game_id': started['game_id'],
    'client_seeds': started['client_seeds'],
    'seats': <Map<String, Object?>>[
      for (final int seat in _recordedInts(entry.game.json['seats']))
        <String, Object?>{
          'seat': seat,
          'name': entry.game.nameOf(seat),
          'connected': true,
          'tokens': folded.tokens[seat],
          'client_seed': seeds[seat]!['client_seed'],
          'seed_origin': seeds[seat]!['origin'],
          'timer_steps': folded.timerSteps[seat],
        },
    ],
    'turn': <String, Object?>{
      'seat': folded.turnSeat,
      'phase': folded.phase,
      'deadline_ms': folded.deadlineMs,
      'k': folded.k,
      'queue': folded.queue,
    },
    'winner': null,
    'seq': folded.seq,
  };
}

/// The bytes of one `game_log` part as a whole encoded frame, measured the
/// way the server measures it: packages/ludo_server/lib/src/connection.dart
/// `_measurePartBytes` (~1217-1235). The envelope carries `re` set to the
/// request id and a 22-character placeholder message id, keys in the order
/// `encodeEnvelope` writes them (v, t, id, d, re).
int _measureGameLogPartBytes({
  required String gameId,
  required int part,
  required int parts,
  required List<Map<String, Object?>> frames,
  required String requestId,
}) {
  const String placeholderId = '0123456789012345678901';
  return utf8
      .encode(
        jsonEncode(<String, Object?>{
          'v': 1,
          't': 'game_log',
          'id': placeholderId,
          'd': <String, Object?>{
            'game_id': gameId,
            'part': part,
            'parts': parts,
            'frames': frames,
          },
          're': requestId,
        }),
      )
      .length;
}

/// One greedy pass at a fixed [targetParts]: packages/ludo_server/lib/src/
/// connection.dart `_packGameLog` (~1165-1215). Each entry joins the current
/// chunk if the part, measured as a whole frame with the part number and
/// [targetParts] it would carry, stays within [maxFrameBytes]; otherwise the
/// chunk closes and the entry opens the next one. Null when one entry alone
/// does not fit.
List<List<Map<String, Object?>>>? _packGameLogPass({
  required List<Map<String, Object?>> entries,
  required String gameId,
  required String requestId,
  required int targetParts,
}) {
  final List<List<Map<String, Object?>>> chunks =
      <List<Map<String, Object?>>>[];
  List<Map<String, Object?>> currentChunk = <Map<String, Object?>>[];
  int currentPart = 1;
  for (final Map<String, Object?> entry in entries) {
    final int bytes = _measureGameLogPartBytes(
      gameId: gameId,
      part: currentPart,
      parts: targetParts,
      frames: <Map<String, Object?>>[...currentChunk, entry],
      requestId: requestId,
    );
    if (bytes <= maxFrameBytes) {
      currentChunk.add(entry);
    } else {
      if (currentChunk.isEmpty) {
        return null;
      }
      chunks.add(currentChunk);
      currentChunk = <Map<String, Object?>>[entry];
      currentPart++;
      final int singleBytes = _measureGameLogPartBytes(
        gameId: gameId,
        part: currentPart,
        parts: targetParts,
        frames: currentChunk,
        requestId: requestId,
      );
      if (singleBytes > maxFrameBytes) {
        return null;
      }
    }
  }
  if (currentChunk.isNotEmpty) {
    chunks.add(currentChunk);
  }
  return chunks;
}

/// The parts the server cuts [entries] into for [requestId]: connection.dart
/// `_publishGameLog` (~1086-1117). The target part count starts at 1 and
/// follows the count each pass produces, at most ten passes, until a pass
/// yields the count it was aimed at.
List<List<Map<String, Object?>>> _packGameLogForRequest({
  required List<Map<String, Object?>> entries,
  required String gameId,
  required String requestId,
  required String where,
}) {
  if (entries.isEmpty) {
    return <List<Map<String, Object?>>>[<Map<String, Object?>>[]];
  }
  var targetParts = 1;
  List<List<Map<String, Object?>>>? packed;
  for (var i = 0; i < 10; i++) {
    packed = _packGameLogPass(
      entries: entries,
      gameId: gameId,
      requestId: requestId,
      targetParts: targetParts,
    );
    if (packed == null || packed.length == targetParts) {
      break;
    }
    targetParts = packed.length;
  }
  if (packed == null) {
    throw TestFailure(
      '$where: the server\'s packing rule cannot fit a recorded game_log '
      'entry in one part for request id "$requestId"',
    );
  }
  return packed;
}

/// The `game_log` answer as served: the parts pushed, each decoded from the
/// exact string that went onto the transport, in order.
class _ServedGameLog {
  _ServedGameLog(this.recordedParts, this.texts)
    : parts = <Map<String, Object?>>[
        for (final String text in texts) _decode(text),
      ];

  final int recordedParts;

  /// The strings pushed onto the transport, as pushed. FakeTransport records
  /// what the engine sends, not what the test pushes in, so they are kept
  /// here.
  final List<String> texts;
  final List<Map<String, Object?>> parts;

  /// The largest pushed part, in UTF-8 bytes.
  int get maxPartBytes => texts.fold(0, (int most, String t) {
    final int size = utf8.encode(t).length;
    return size > most ? size : most;
  });

  List<Map<String, Object?>> get frames => <Map<String, Object?>>[
    for (final Map<String, Object?> part in parts)
      for (final Object? f
          in (part['d']! as Map<String, Object?>)['frames']! as List<Object?>)
        f! as Map<String, Object?>,
  ];
}

/// Answers a `game_log` request with the recorded game's log: the inner
/// frames of the recorded parts, concatenated in recorded order and not
/// changed, packed into parts by the server's rule for [requestId]
/// ([_packGameLogForRequest]), each part a fresh 22-character message id with
/// `re` set to [requestId] and the recorded `game_id`. Parts are per request,
/// so the recorded part boundaries (cut under the recorder's own short ids)
/// are not served. Fails if a part is over [maxFrameBytes] encoded or if the
/// served inner frames are not the recorded ones. Both checks read the strings
/// pushed onto the transport: the size is the pushed text's UTF-8 length, and
/// the inner frames are decoded from those same strings.
_ServedGameLog _pushRecordedGameLog(
  FakeTransport transport, {
  required String requestId,
  required List<Map<String, Object?>> recordedParts,
  required String where,
}) {
  final List<Map<String, Object?>> recorded = <Map<String, Object?>>[
    for (final Map<String, Object?> part in recordedParts)
      for (final Object? f
          in (part['d']! as Map<String, Object?>)['frames']! as List<Object?>)
        f! as Map<String, Object?>,
  ];
  final String gameId =
      (recordedParts.first['d']! as Map<String, Object?>)['game_id']! as String;
  final List<List<Map<String, Object?>>> chunks = _packGameLogForRequest(
    entries: recorded,
    gameId: gameId,
    requestId: requestId,
    where: where,
  );
  final List<String> pushedTexts = <String>[];
  for (var p = 0; p < chunks.length; p++) {
    final Map<String, Object?> part = <String, Object?>{
      'v': 1,
      't': 'game_log',
      'id': 'shot-gl-${(p + 1).toString().padLeft(14, '0')}',
      'd': <String, Object?>{
        'game_id': gameId,
        'part': p + 1,
        'parts': chunks.length,
        'frames': chunks[p],
      },
      're': requestId,
    };
    final String text = jsonEncode(part);
    final int size = utf8.encode(text).length;
    expect(
      size,
      lessThanOrEqualTo(maxFrameBytes),
      reason:
          '$where: served game_log part ${p + 1} of ${chunks.length} encoded '
          'to $size bytes with re "$requestId", over the $maxFrameBytes '
          'limit; the client would drop it',
    );
    pushedTexts.add(text);
    transport.pushText(text);
  }
  final _ServedGameLog log = _ServedGameLog(recordedParts.length, pushedTexts);
  expect(
    log.frames,
    recorded,
    reason:
        '$where: the served inner frames must be the recorded inner frames, '
        'in order, unchanged (${log.frames.length} served, ${recorded.length} '
        'recorded)',
  );
  return log;
}

/// The near-finish line the lose card reads for [stepsLeft] squares: the
/// "only N squares" line at or under [kNearFinishSquares], else the plain
/// nudge.
String _expectedLoseLine(AppLocalizations loc, int stepsLeft) =>
    stepsLeft <= kNearFinishSquares
    ? loc.endLoseNear(stepsLeft)
    : loc.endLoseNudge;

void _expectLoseLine(
  WidgetTester tester, {
  required String expected,
  required String momentDescription,
}) {
  final Finder line = find.byKey(const Key('end-card-lose-line'));
  expect(
    line,
    findsOneWidget,
    reason: '$momentDescription: expected end-card-lose-line on screen',
  );
  expect(
    tester.widget<Text>(line).data,
    expected,
    reason:
        '$momentDescription: expected the lose line to read "$expected" '
        '(endLoseNear at or under $kNearFinishSquares squares, endLoseNudge '
        'above)',
  );
}

/// Captures 25 and 26, from a home screen already on screen. [shotName] is
/// the screenshot file name without the `.png`.
///
/// The device is seat 0 (Priya) in the recorded game guest_wins_1 and enters
/// it through [_enterRealGame]. The view's frames reach it verbatim through
/// the first `turn` that hands the turn to seat 2 at or after the middle of
/// the view; there the socket drops. The resume answer is the room at the
/// winner's last `turn` ([_locateWinnersLastTurn]), built by folding the
/// recorded frames up to it ([_recordedResumeSnapshot]): the winner to roll,
/// the rolls between the drop and that turn missed. The winner's last
/// `rolled` and `moved` then arrive live, the roll thrown and the walk landed,
/// and the recorded `game_over` follows them. The recorded `game_log` parts
/// answer the client's request.
Future<void> _captureReconnectLoser(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required _ReconnectCaptureFactory factory,
  required String localeName,
  required String shotName,
}) async {
  final String capture = 'capture $shotName';
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: 'guest_wins_1',
    seat: 0,
    localeName: localeName,
  );
  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final String where = entry.where;
  final RoomController controller = entry.controller;
  final FakeTransport first = entry.transport;
  final _RealGame game = entry.game;
  final List<Map<String, Object?>> view = entry.view;
  final List<int> seats = _recordedInts(game.json['seats']);
  final int gameOverIndex = view.length - 1;
  final int winner = game.winner;
  final _RealStatCounts counts = game.counts(entry.seat);
  expect(
    entry.isHost,
    isTrue,
    reason: '$where: the device is the host of the recorded room',
  );
  expect(
    winner,
    isNot(entry.seat),
    reason: '$where: the device must be the loser of the recorded game',
  );

  // The live part: through the turn that hands the dice to the winner.
  final int dropIndex = _locateReconnectDrop(
    view,
    deviceSeat: entry.seat,
    where: where,
  );
  expect(
    view[dropIndex + 1]['t'],
    'rolled',
    reason:
        '$where: the frame after the drop at view index $dropIndex must be '
        'a rolled, so the hole is at least one rolled',
  );
  final int dropSeq =
      (view[dropIndex]['d']! as Map<String, Object?>)['seq']! as int;
  while (entry.next <= dropIndex) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();

  final _FoldedRoom atDrop = _foldRecordedView(
    view,
    before: dropIndex + 1,
    seats: seats,
  );
  expect(
    controller.hasDesynced,
    isFalse,
    reason:
        '$where: the live prefix must stay in seq (room seq '
        '${controller.room?.seq}, drop at view index $dropIndex)',
  );
  expect(controller.room?.state, RoomState.playing, reason: where);
  expect(controller.room?.seq, dropSeq, reason: where);
  for (final int s in seats) {
    expect(
      _endCardTokens(controller, s),
      atDrop.tokens[s],
      reason:
          '$where: seat $s tokens after the live prefix must be the fold of '
          'the recorded frames through view index $dropIndex',
    );
  }
  expect(first.sentRaw.map(_typeOf).toList(), <String>[
    'create_room',
    'start_game',
  ], reason: '$where: the live prefix must send only the lobby requests');
  final int rePushedLive = entry.re.pushed;
  final int reDroppedLive = entry.re.dropped;

  // The same drop capture 10 uses. The short reconnect delay then opens
  // the second transport on its own; nothing here calls reconnect().
  first.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    first.isClosed,
    isTrue,
    reason: '$shotName: the first transport must actually have dropped',
  );

  await _pumpUntilReady(
    tester,
    () =>
        factory.transports.length >= 2 &&
        factory.transports.last.sentRaw.any(
          (String raw) => _typeOf(raw) == 'resume',
        ),
    'a second transport with resume on it',
  );

  expect(
    factory.transports,
    hasLength(2),
    reason:
        '$shotName: the factory must have built a second transport for '
        'the reconnect, got ${factory.transports.length}',
  );
  final FakeTransport live = factory.transports.last;
  expect(
    _typeOf(live.sentRaw.first),
    'resume',
    reason: '$shotName: the new transport\'s first frame must be resume',
  );
  final String resumeId = _idOf(live.sentRaw.first);

  // The room just before game_over, folded from the recorded frames. It
  // is not the resume snapshot (the server never holds that room); it is
  // what the card reads its near-finish line and final tokens from.
  final _FoldedRoom beforeOver = _foldRecordedView(
    view,
    before: gameOverIndex,
    seats: seats,
  );
  for (final int s in seats) {
    expect(
      beforeOver.tokens[s],
      game.finalTokens(s),
      reason:
          '$where: the fold of every frame before game_over must leave seat '
          '$s on the recorded final_tokens',
    );
  }
  expect(
    beforeOver.home(entry.seat),
    counts.home,
    reason: '$where: tokens on 57 in the fold disagree with the fixture home',
  );

  // The resume point is the winner's last turn: the room a server holds
  // while the winner is about to make the move that ends the game.
  final int resumeIndex = _locateWinnersLastTurn(
    view,
    winner: winner,
    where: where,
  );
  var holeRolls = 0;
  for (var i = dropIndex + 1; i < resumeIndex; i++) {
    if (view[i]['t'] == 'rolled') {
      holeRolls++;
    }
  }
  expect(
    holeRolls,
    greaterThan(0),
    reason:
        '$where: expected at least one rolled strictly between the drop at '
        'view index $dropIndex and the resume turn at $resumeIndex, so the '
        'local transcript has a hole; found none',
  );
  final _FoldedRoom atResume = _foldRecordedView(
    view,
    before: resumeIndex + 1,
    seats: seats,
  );
  final int resumeSeq =
      (view[resumeIndex]['d']! as Map<String, Object?>)['seq']! as int;
  expect(
    atResume.seq,
    resumeSeq,
    reason: '$where: the fold must end on the seq of view[$resumeIndex]',
  );
  expect(
    atResume.turnSeat,
    winner,
    reason:
        '$where: the resume room must hand the dice to the winner (seat '
        '$winner), got seat ${atResume.turnSeat}',
  );
  var lastRolledK = -1;
  for (var i = resumeIndex - 1; i >= 0 && lastRolledK == -1; i--) {
    if (view[i]['t'] == 'rolled') {
      lastRolledK = (view[i]['d']! as Map<String, Object?>)['k']! as int;
    }
  }
  expect(
    atResume.k,
    lastRolledK,
    reason:
        '$where: the resume room\'s k must be the k of the last rolled '
        'before view index $resumeIndex (section 11: the game-wide roll '
        'number)',
  );
  expect(
    resumeSeq,
    greaterThan(dropSeq + 1),
    reason:
        '$shotName: the resume snapshot seq must be ahead of the last '
        'frame the client saw, with room for that rolled',
  );
  final Map<String, Object?> snapshot = _recordedResumeSnapshot(
    entry,
    atResume,
  );
  live.pushText(_frame(type: 'room', re: resumeId, data: snapshot));
  await tester.pump();
  await tester.pump();

  expect(controller.phase, RoomPhase.connected);
  expect(controller.hasDesynced, isFalse);
  expect(controller.room?.seq, resumeSeq);
  expect(controller.room?.state, RoomState.playing);
  for (final int s in seats) {
    expect(
      _endCardTokens(controller, s),
      atResume.tokens[s],
      reason: '$where: seat $s tokens after the resume snapshot',
    );
  }
  expect(
    _sentOfType(live, 'game_log'),
    isEmpty,
    reason: '$shotName: game_log is not asked before game_over',
  );

  // The finish is live: the winner's last roll and move, then game_over,
  // each pushed as recorded (only `re` changes) with real time between
  // them, so the roll is thrown and the walk lands before the card.
  final Map<String, int> liveByType = <String, int>{};
  var liveSeq = resumeSeq;
  var throwsSeen = 0;
  for (var i = resumeIndex + 1; i < gameOverIndex; i++) {
    final Map<String, Object?> frame = view[i];
    final String type = frame['t']! as String;
    final Map<String, Object?> d = frame['d']! as Map<String, Object?>;
    expect(
      d['seq'],
      liveSeq + 1,
      reason:
          '$where: live frame view[$i] ($type) must follow seq $liveSeq in '
          'the recorded order',
    );
    liveSeq = d['seq']! as int;
    live.pushText(entry.re.wire(frame));
    liveByType[type] = (liveByType[type] ?? 0) + 1;
    await tester.pump();
    await tester.pump();
    if (type == 'rolled') {
      final _ThrowDrain drain = await _pumpUntilThrownDiceGone(
        tester,
        controller,
        capture: capture,
        where: '$where; the winner\'s live roll at view index $i',
      );
      throwsSeen += drain.throwsSeen;
    } else if (type == 'moved') {
      final int moverSeat = d['seat']! as int;
      final int moverToken = d['token']! as int;
      final int to = d['to']! as int;
      if (to == 57) {
        await _pumpUntilFound(
          tester,
          find.byKey(Key('board-home-burst-$moverSeat-$moverToken')),
          'the winner\'s walk to land at home (seat $moverSeat token '
          '$moverToken, view index $i)',
        );
      } else {
        await _pumpRealDurationFrames(tester, frameCount: 12);
      }
    }
    expect(
      controller.hasDesynced,
      isFalse,
      reason:
          '$where: seq gap after live frame view[$i] ($type, seq $liveSeq); '
          'the room is at seq ${controller.room?.seq}',
    );
    expect(
      controller.room?.seq,
      liveSeq,
      reason: '$where: the controller must have absorbed view[$i] ($type)',
    );
    expect(
      _sentOfType(live, 'game_log'),
      isEmpty,
      reason:
          '$shotName: game_log must not be asked before game_over is pushed '
          '(after live frame view[$i], $type)',
    );
  }
  expect(
    liveByType.keys,
    contains('moved'),
    reason:
        '$where: the live finish must include the winner\'s last moved, got '
        '$liveByType',
  );
  final Map<String, Object?> gameOver = view[gameOverIndex];
  expect(
    (gameOver['d']! as Map<String, Object?>)['seq'],
    liveSeq + 1,
    reason:
        '$where: the recorded game_over must follow the last live frame\'s '
        'seq $liveSeq',
  );
  live.pushText(entry.re.wire(gameOver));

  final int homeBefore = beforeOver.home(entry.seat);
  expect(
    homeBefore,
    greaterThan(0),
    reason:
        '$where: the device must have a token home for the card to read '
        'its home tile before the game_log answer',
  );
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('end-card-stat-home')),
    'end-card-stat-home after game_over, before the game_log answer',
  );
  for (final int s in seats) {
    expect(
      _endCardTokens(controller, s),
      game.finalTokens(s),
      reason:
          '$where: after game_over seat $s tokens must be the recorded '
          'final_tokens',
    );
  }

  // The hole is still open: the rolled frames between the drop and the
  // resume turn never reached this client, so only the home tile (read from
  // the tokens) is on the card. The game_log request may already be on the
  // wire. It is not answered until after this read.
  expect(
    find.byKey(const Key('end-card-lose')),
    findsOneWidget,
    reason: '$shotName: the lose card must be up before game_log is answered',
  );
  expect(find.byKey(const Key('end-card-stat-home')), findsOneWidget);
  expect(
    find.byKey(const Key('end-card-stat-rolls')),
    findsNothing,
    reason:
        '$shotName: end-card-stat-rolls must stay absent until game_log '
        'is answered (the local transcript has a hole)',
  );
  expect(find.byKey(const Key('end-card-stat-sixes')), findsNothing);
  expect(find.byKey(const Key('end-card-stat-captures')), findsNothing);

  final GameStats localStats = computeGameStats(
    frames: controller.gameTranscript,
    seat: entry.seat,
    finalTokens: _endCardTokens(controller, entry.seat),
  );
  expect(
    localStats.complete,
    isFalse,
    reason:
        '$shotName: the transcript must be incomplete after the hole, '
        'got $localStats',
  );

  // The request is sent from the game_over notify, which has already
  // run. A few more real frames cover a post-frame callback that sends
  // it one frame later. Not finding one is not a throw here: the tile
  // assertion below is what goes red, and it names the count.
  for (var i = 0; i < 10 && _sentOfType(live, 'game_log').isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }

  final List<Map<String, Object?>> recordedParts = <Map<String, Object?>>[
    for (final Object? p in game.json['game_log']! as List<Object?>)
      p! as Map<String, Object?>,
  ];
  final List<String> logs = _sentOfType(live, 'game_log');
  _ServedGameLog? servedLog;
  if (logs.length == 1) {
    expect(
      _decode(logs.single)['d'],
      isEmpty,
      reason: '$shotName: game_log is sent as {}',
    );
    servedLog = _pushRecordedGameLog(
      live,
      requestId: _idOf(logs.single),
      recordedParts: recordedParts,
      where: where,
    );
    await tester.pump();
    await tester.pump();
  }

  expect(
    servedLog,
    isNotNull,
    reason:
        '$shotName: expected exactly one game_log request after game_over to '
        'answer, sent ${live.sentRaw.map(_typeOf).toList()}',
  );
  final int partsServed = servedLog!.parts.length;
  final GameStats served = computeGameStats(
    frames: <Frame>[
      for (final Map<String, Object?> f in servedLog.frames)
        Frame(
          type: f['t']! as String,
          id: 'log-entry',
          data: f['d']! as Map<String, Object?>,
        ),
    ],
    seat: entry.seat,
    finalTokens: _endCardTokens(controller, entry.seat),
  );
  expect(
    served.complete,
    isTrue,
    reason:
        '$shotName: the served game_log must be a complete seq from '
        'game_started to game_over, got $served',
  );
  expect(
    (served.rolls, served.sixes, served.capturesMade, served.tokensHome),
    (counts.rolls, counts.sixes, counts.captures, counts.home),
    reason:
        '$where: the recorded game_log counts (rolls, sixes, captures, home) '
        'disagree with the fixture counts ${counts.toString()}',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(loc.localeName, localeName);
  final String winnerName = game.nameOf(winner);
  final String loseLine = _expectedLoseLine(
    loc,
    beforeOver.stepsLeft(entry.seat),
  );
  _expectGameOverWinnerText(
    tester,
    controller: controller,
    expectedWinner: winner,
    expectedText: loc.endLoseTitle(winnerName),
    momentDescription:
        'after the game_log answer, before the settle ($shotName)',
  );
  _expectLoseLine(
    tester,
    expected: loseLine,
    momentDescription:
        'after the game_log answer, before the settle ($shotName)',
  );
  _expectEndCardStatTiles(
    tester,
    rolls: counts.rolls,
    sixes: counts.sixes,
    captures: counts.captures,
    home: counts.home,
    momentDescription:
        'after the game_log answer, before the settle ($shotName; '
        '${entry.game.name} seat ${entry.seat}, $counts)',
  );

  expect(
    _sentOfType(live, 'game_log'),
    hasLength(1),
    reason:
        '$shotName: exactly one game_log after game_over, on the live '
        'transport; sent ${live.sentRaw.map(_typeOf).toList()}',
  );
  expect(
    _sentOfType(first, 'game_log'),
    isEmpty,
    reason: '$shotName: game_log must not have gone out on the dropped socket',
  );

  await _pumpRealDurationFrames(tester);

  _expectGameOverWinnerText(
    tester,
    controller: controller,
    expectedWinner: winner,
    expectedText: loc.endLoseTitle(winnerName),
    momentDescription:
        'after the post-game-log settle, immediately before $shotName',
  );
  _expectLoseLine(
    tester,
    expected: loseLine,
    momentDescription:
        'after the post-game-log settle, immediately before $shotName',
  );
  _expectEndCardStatTiles(
    tester,
    rolls: counts.rolls,
    sixes: counts.sixes,
    captures: counts.captures,
    home: counts.home,
    momentDescription:
        'after the post-game-log settle, immediately before $shotName '
        '(${entry.game.name} seat ${entry.seat}, $counts)',
  );
  expect(find.byKey(const Key('end-card-lose')), findsOneWidget);

  // ignore: avoid_print
  print(
    'screenshots_test: $capture reconnect of "${game.name}" seat '
    '${entry.seat}: drop after view index $dropIndex (seq $dropSeq) of '
    '${view.length} frames, $holeRolls rolled in the hole, resume turn at '
    'view index $resumeIndex (seq $resumeSeq), snapshot tokens '
    '${<String, Object?>{for (final int s in seats) 'seat $s': atResume.tokens[s]}}, '
    'turn seat ${atResume.turnSeat} ${atResume.phase} k ${atResume.k} '
    'deadline_ms ${atResume.deadlineMs} queue ${atResume.queue}, '
    '${gameOverIndex - resumeIndex - 1} live frames $liveByType plus '
    'game_over seq ${liveSeq + 1}, $throwsSeen thrown dice seen on the '
    'board, ${recordedParts.length} game_log parts recorded, $partsServed '
    'served (re-packed for the request id), max part '
    '${servedLog.maxPartBytes} of $maxFrameBytes bytes; tiles $counts, steps '
    'left ${beforeOver.stepsLeft(entry.seat)}, lose line "$loseLine"; re: '
    '$rePushedLive recorded frames pushed before the drop, '
    '${entry.re.pushed} in all, '
    '${entry.re.rewritten} rewritten to this device\'s ids, '
    '${entry.re.dropped} dropped ${entry.re.droppedByType} ($reDroppedLive '
    'before the drop); the resume room answers the resume id, '
    '$partsServed game_log parts carry the request id',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

// --- captures 27 through 32: C-316 end card and home screen states ---------

Map<String, Object?> _finishedTurnJson() => const <String, Object?>{
  'seat': 0,
  'phase': 'finished',
  'deadline_ms': 0,
  'k': 8,
};

/// Captures 27 and 28: 3-seat FINISHED game, seat 1 lost, seat 2 leaves.
Future<void> _captureFriendLeft(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Locale locale,
  required String roomCode,
  required String verifyUrl,
  required String shotName,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
  );
  addTearDown(controller.dispose);

  final Future<void> createFuture = controller.createRoom(
    name: 'Karim',
    players: 3,
  );
  await tester.pump();
  await tester.pump();

  final List<String> createMessages = _sentOfType(transport, 'create_room');
  expect(
    createMessages,
    hasLength(1),
    reason: '$shotName: createRoom must have sent create_room',
  );
  final String createId = _idOf(createMessages.single);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: const <String, Object?>{'seat': 1, 'seat_token': 'tok-shot-karim'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        code: roomCode,
        state: 'PLAYING',
        hostSeat: 0,
        players: 3,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
          _seatJson(1, name: 'Karim'),
          _seatJson(2, name: 'Lina'),
        ],
        turn: const <String, Object?>{
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

  // Unsolicited room push into FINISHED, populating lastFinished.
  transport.pushText(
    _frame(
      type: 'room',
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'FINISHED',
          hostSeat: 0,
          players: 3,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
            _seatJson(1, name: 'Karim'),
            _seatJson(2, name: 'Lina'),
          ],
          turn: _finishedTurnJson(),
          winner: 0,
          seq: 2,
        ),
        'verify_url': verifyUrl,
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      GameScreen(controller: controller),
      locale: locale,
    ),
  );
  await tester.pump();

  // Seat 2 (Lina) leaves: player_left naming seat 2, then room update.
  transport.pushText(
    _frame(
      type: 'player_left',
      data: const <String, Object?>{'seat': 2, 'host_seat': 0, 'seq': 3},
    ),
  );
  await tester.pump();

  transport.pushText(
    _frame(
      type: 'room',
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'FINISHED',
          hostSeat: 0,
          players: 3,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
            _seatJson(1, name: 'Karim'),
          ],
          turn: _finishedTurnJson(),
          winner: 0,
          seq: 4,
        ),
        'verify_url': verifyUrl,
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  _expectFriendLeftState(
    tester,
    controller: controller,
    departedName: 'Lina',
    shotName: shotName,
    momentDescription: 'before settle',
  );

  await _pumpRealDurationFrames(tester);

  _expectFriendLeftState(
    tester,
    controller: controller,
    departedName: 'Lina',
    shotName: shotName,
    momentDescription: 'after settle',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

void _expectFriendLeftState(
  WidgetTester tester, {
  required RoomController controller,
  required String departedName,
  required String shotName,
  required String momentDescription,
}) {
  expect(
    controller.room?.state,
    RoomState.finished,
    reason: '$shotName ($momentDescription): room must be finished',
  );
  expect(controller.room?.seats.map((SeatState s) => s.seat).toList(), <int>[
    0,
    1,
  ], reason: '$shotName ($momentDescription): seat 2 must be gone from room');
  expect(
    controller.lastFinished?.seats.map((SeatState s) => s.seat).toList(),
    <int>[0, 1, 2],
    reason:
        '$shotName ($momentDescription): lastFinished must keep all 3 seats',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );

  final Finder leftFinder = find.byKey(const Key('end-card-left'));
  expect(
    leftFinder,
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-left must be shown',
  );
  final Text leftText = tester.widget<Text>(leftFinder);
  final String expectedLeft = loc.endLeft(departedName);
  expect(
    leftText.data,
    expectedLeft,
    reason:
        '$shotName ($momentDescription): end-card-left must read '
        '"$expectedLeft", got "${leftText.data}"',
  );

  final Finder rematchFinder = find.byKey(const Key('end-card-rematch'));
  expect(
    rematchFinder,
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-rematch must be shown',
  );
  final Widget rematchWidget = tester.widget(rematchFinder);
  final VoidCallback? onRematchPressed = rematchWidget is ButtonStyleButton
      ? rematchWidget.onPressed
      : null;
  expect(
    onRematchPressed,
    isNotNull,
    reason: '$shotName ($momentDescription): Play again must be enabled',
  );

  final Finder verifyFinder = find.byKey(
    const Key('game-screen-verify-button'),
  );
  expect(
    verifyFinder,
    findsOneWidget,
    reason:
        '$shotName ($momentDescription): game-screen-verify-button must show',
  );
  expect(
    find.byKey(const Key('end-card-lose')),
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-lose must be shown',
  );
}

/// Capture 29: 2-seat FINISHED game (seats 0 and 2), seat 2 lost, seat 0
/// leaves.
Future<void> _captureEveryoneLeft(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Locale locale,
  required String roomCode,
  required String verifyUrl,
  required String shotName,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
  );
  addTearDown(controller.dispose);

  final Future<void> createFuture = controller.createRoom(
    name: 'Karim',
    players: 2,
  );
  await tester.pump();
  await tester.pump();

  final List<String> createMessages = _sentOfType(transport, 'create_room');
  expect(
    createMessages,
    hasLength(1),
    reason: '$shotName: createRoom must have sent create_room',
  );
  final String createId = _idOf(createMessages.single);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: const <String, Object?>{'seat': 2, 'seat_token': 'tok-shot-karim'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        code: roomCode,
        state: 'PLAYING',
        hostSeat: 0,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
          _seatJson(2, name: 'Karim'),
        ],
        turn: const <String, Object?>{
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

  // Unsolicited room push into FINISHED, populating lastFinished.
  transport.pushText(
    _frame(
      type: 'room',
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'FINISHED',
          hostSeat: 0,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
            _seatJson(2, name: 'Karim'),
          ],
          turn: _finishedTurnJson(),
          winner: 0,
          seq: 2,
        ),
        'verify_url': verifyUrl,
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      GameScreen(controller: controller),
      locale: locale,
    ),
  );
  await tester.pump();

  // Seat 0 (Priya) leaves: player_left naming seat 0, host_seat becomes 2.
  transport.pushText(
    _frame(
      type: 'player_left',
      data: const <String, Object?>{'seat': 0, 'host_seat': 2, 'seq': 3},
    ),
  );
  await tester.pump();

  transport.pushText(
    _frame(
      type: 'room',
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'FINISHED',
          hostSeat: 2,
          players: 2,
          seats: <Map<String, Object?>>[_seatJson(2, name: 'Karim')],
          turn: _finishedTurnJson(),
          winner: 0,
          seq: 4,
        ),
        'verify_url': verifyUrl,
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  _expectEveryoneLeftState(
    tester,
    controller: controller,
    shotName: shotName,
    momentDescription: 'before settle',
  );

  await _pumpRealDurationFrames(tester);

  _expectEveryoneLeftState(
    tester,
    controller: controller,
    shotName: shotName,
    momentDescription: 'after settle',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

void _expectEveryoneLeftState(
  WidgetTester tester, {
  required RoomController controller,
  required String shotName,
  required String momentDescription,
}) {
  expect(
    controller.room?.state,
    RoomState.finished,
    reason: '$shotName ($momentDescription): room must be finished',
  );
  expect(controller.room?.seats.map((SeatState s) => s.seat).toList(), <int>[
    2,
  ], reason: '$shotName ($momentDescription): only seat 2 must remain');
  expect(
    controller.lastFinished?.seats.map((SeatState s) => s.seat).toList(),
    <int>[0, 2],
    reason: '$shotName ($momentDescription): lastFinished must keep both seats',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );

  final Finder leftFinder = find.byKey(const Key('end-card-left'));
  expect(
    leftFinder,
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-left must be shown',
  );
  final Text leftText = tester.widget<Text>(leftFinder);
  expect(
    leftText.data,
    loc.endEveryoneLeft,
    reason:
        '$shotName ($momentDescription): end-card-left must read '
        'endEveryoneLeft ("${loc.endEveryoneLeft}"), got "${leftText.data}"',
  );

  expect(
    find.byKey(const Key('end-card-rematch')),
    findsNothing,
    reason: '$shotName ($momentDescription): no rematch button when alone',
  );

  final Finder newRoomFinder = find.byKey(
    const Key('game-screen-new-room-button'),
  );
  expect(
    newRoomFinder,
    findsOneWidget,
    reason: '$shotName ($momentDescription): game-screen-new-room-button shown',
  );
  final Widget newRoomWidget = tester.widget(newRoomFinder);
  expect(
    newRoomWidget is ElevatedButton,
    isTrue,
    reason:
        '$shotName ($momentDescription): New table button must be primary '
        '(ElevatedButton), got ${newRoomWidget.runtimeType}',
  );

  expect(
    find.byKey(const Key('game-screen-verify-button')),
    findsOneWidget,
    reason: '$shotName ($momentDescription): verify button must be shown',
  );
  expect(
    find.byKey(const Key('end-card-lose')),
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-lose must be shown',
  );
}

/// Captures 30 and 31: 2-seat FINISHED game (seats 0 and 2), lost, transport
/// drops offline.
Future<void> _captureEndOffline(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Locale locale,
  required String roomCode,
  required String verifyUrl,
  required String shotName,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
    autoReconnectDelays: const <Duration>[
      Duration(minutes: 5),
      Duration(minutes: 5),
    ],
  );
  addTearDown(controller.dispose);

  final Future<void> createFuture = controller.createRoom(
    name: 'Karim',
    players: 2,
  );
  await tester.pump();
  await tester.pump();

  final List<String> createMessages = _sentOfType(transport, 'create_room');
  expect(
    createMessages,
    hasLength(1),
    reason: '$shotName: createRoom must have sent create_room',
  );
  final String createId = _idOf(createMessages.single);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: const <String, Object?>{'seat': 2, 'seat_token': 'tok-shot-karim'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        code: roomCode,
        state: 'PLAYING',
        hostSeat: 0,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
          _seatJson(2, name: 'Karim'),
        ],
        turn: const <String, Object?>{
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

  transport.pushText(
    _frame(
      type: 'room',
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'FINISHED',
          hostSeat: 0,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
            _seatJson(2, name: 'Karim'),
          ],
          turn: _finishedTurnJson(),
          winner: 0,
          seq: 2,
        ),
        'verify_url': verifyUrl,
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      GameScreen(controller: controller),
      locale: locale,
    ),
  );
  await tester.pump();

  // Socket drops from far side.
  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();

  _expectEndOfflineState(
    tester,
    controller: controller,
    shotName: shotName,
    momentDescription: 'before settle',
  );

  await _pumpRealDurationFrames(tester);

  _expectEndOfflineState(
    tester,
    controller: controller,
    shotName: shotName,
    momentDescription: 'after settle',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

void _expectEndOfflineState(
  WidgetTester tester, {
  required RoomController controller,
  required String shotName,
  required String momentDescription,
}) {
  expect(
    controller.phase,
    RoomPhase.closed,
    reason: '$shotName ($momentDescription): controller phase must be closed',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );

  final Finder offlineFinder = find.byKey(const Key('end-card-offline'));
  expect(
    offlineFinder,
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-offline must be shown',
  );
  final Text offlineText = tester.widget<Text>(offlineFinder);
  expect(
    offlineText.data,
    loc.endOffline,
    reason:
        '$shotName ($momentDescription): end-card-offline must read '
        'endOffline ("${loc.endOffline}"), got "${offlineText.data}"',
  );

  expect(
    find.byKey(const Key('game-screen-connection-lost')),
    findsNothing,
    reason:
        '$shotName ($momentDescription): game-screen-connection-lost '
        'must not be shown on the end card offline',
  );
  expect(
    find.byKey(const Key('game-screen-stale-table')),
    findsNothing,
    reason:
        '$shotName ($momentDescription): game-screen-stale-table '
        'must not be shown on the end card offline',
  );

  final Finder verifyFinder = find.byKey(
    const Key('game-screen-verify-button'),
  );
  expect(
    verifyFinder,
    findsOneWidget,
    reason:
        '$shotName ($momentDescription): game-screen-verify-button must show',
  );
  final Widget verifyWidget = tester.widget(verifyFinder);
  final VoidCallback? onVerifyPressed = switch (verifyWidget) {
    ButtonStyleButton() => verifyWidget.onPressed,
    VerifyRollsButton() => verifyWidget.onPressed,
    _ => null,
  };
  expect(
    onVerifyPressed,
    isNotNull,
    reason:
        '$shotName ($momentDescription): verify button must be hit-testable',
  );

  expect(
    find.byKey(const Key('end-card-lose')),
    findsOneWidget,
    reason: '$shotName ($momentDescription): end-card-lose must be shown',
  );
}

/// Capture 32: rematch LOBBY, removed by forced start, HomeScreen notice.
Future<void> _captureHomeRemoved(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Locale locale,
  required String roomCode,
  required String shotName,
}) async {
  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

  expect(
    factory.controllers,
    hasLength(1),
    reason: '$shotName: tapping Create Room must build exactly one controller',
  );
  final FakeTransport transport = factory.transports.single;
  // No addTearDown(controller.dispose) here, unlike the captures above:
  // the removal pops GameScreen with GameScreenResult.removed and
  // HomeScreen retires and disposes the controller itself (order 080
  // rule 2), so a second dispose at teardown would assert.

  final List<String> createMessages = _sentOfType(transport, 'create_room');
  expect(
    createMessages,
    hasLength(1),
    reason: '$shotName: create_room must have been sent',
  );
  final String createId = _idOf(createMessages.single);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: const <String, Object?>{'seat': 0, 'seat_token': 'tok-shot-priya'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'FINISHED',
          hostSeat: 0,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 57, 57]),
            _seatJson(2, name: 'Karim'),
          ],
          turn: _finishedTurnJson(),
          winner: 0,
          seq: 1,
        ),
        'verify_url': 'https://verify.example.invalid/shot32',
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: '$shotName: FINISHED reply must latch GameScreen',
  );

  // Server pushes rematch LOBBY frame.
  transport.pushText(
    _frame(
      type: 'room',
      data: <String, Object?>{
        ..._roomJson(
          code: roomCode,
          state: 'LOBBY',
          hostSeat: 0,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya'),
            _seatJson(2, name: 'Karim'),
          ],
          seq: 2,
        ),
        'rematch': const <String, Object?>{
          'by': 2,
          'ready': <int>[2],
        },
      },
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: '$shotName: rematch LOBBY stays on GameScreen',
  );

  // player_left naming seat 0 (this client) arrives.
  transport.pushText(
    _frame(
      type: 'player_left',
      data: const <String, Object?>{'seat': 0, 'host_seat': 2, 'seq': 3},
    ),
  );

  // Allow the route pop transition to finish.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Answer leave_room if HomeScreen's retirement sent it.
  final List<String> leaveMessages = _sentOfType(transport, 'leave_room');
  if (leaveMessages.isNotEmpty) {
    transport.pushText(
      _frame(
        type: 'player_left',
        re: _idOf(leaveMessages.single),
        data: const <String, Object?>{'seat': 0, 'host_seat': 2, 'seq': 4},
      ),
    );
    await tester.pump();
  }

  _expectHomeRemovedState(
    tester,
    locale: locale,
    shotName: shotName,
    momentDescription: 'before settle',
  );

  await _pumpRealDurationFrames(tester);

  _expectHomeRemovedState(
    tester,
    locale: locale,
    shotName: shotName,
    momentDescription: 'after settle',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

void _expectHomeRemovedState(
  WidgetTester tester, {
  required Locale locale,
  required String shotName,
  required String momentDescription,
}) {
  expect(
    find.byType(GameScreen),
    findsNothing,
    reason:
        '$shotName ($momentDescription): GameScreen must have popped after '
        'removal',
  );
  expect(
    find.byType(HomeScreen),
    findsOneWidget,
    reason: '$shotName ($momentDescription): HomeScreen must be on screen',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(HomeScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$shotName ($momentDescription): expected locale '
        '"${locale.languageCode}", got "${loc.localeName}"',
  );

  final Finder noticeFinder = find.byKey(const Key('home-removed-notice'));
  expect(
    noticeFinder,
    findsOneWidget,
    reason:
        '$shotName ($momentDescription): home-removed-notice must be shown '
        'on HomeScreen',
  );
  final Text noticeText = tester.widget<Text>(noticeFinder);
  expect(
    noticeText.data,
    loc.homeRemovedNotice,
    reason:
        '$shotName ($momentDescription): home-removed-notice must read '
        'homeRemovedNotice ("${loc.homeRemovedNotice}"), got '
        '"${noticeText.data}"',
  );
}

/// Writes [record] as `session.seat` alone (exactly `[code, seat, seatToken]`)
/// and removes `session.seatSavedAt`: the record v1.18.0 and older wrote, which
/// C-447 D2 keeps and shows as the button without ever resuming on its own.
Future<void> _seedSeatWithoutSavedTime(SeatRecord record) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.remove('session.seatSavedAt');
  await prefs.setStringList('session.seat', <String>[
    record.code,
    record.seat.toString(),
    record.seatToken,
  ]);
}

/// Captures 61 and 62: Home after a refused resume (C-447 D4), the notice in
/// its card (C-449 D1).
Future<void> _captureHomeGameGone(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Locale locale,
  required String roomCode,
  required String shotName,
}) async {
  await _seedSeatWithoutSavedTime(
    SeatRecord(code: roomCode, seat: 0, seatToken: 'tok-$shotName'),
  );

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  expect(
    find.byKey(const Key('home-rejoin-button')),
    findsOneWidget,
    reason:
        '$shotName: the seat record without a saved time must show '
        'home-rejoin-button and must not resume on its own',
  );
  expect(
    factory.controllers,
    isEmpty,
    reason: '$shotName: nothing may have started a resume before the tap',
  );

  await tester.ensureVisible(find.byKey(const Key('home-rejoin-button')));
  await _tapAndAwaitPushedRoute(tester, const Key('home-rejoin-button'));

  expect(
    factory.controllers,
    hasLength(1),
    reason: '$shotName: tapping the button must build exactly one controller',
  );
  final FakeTransport transport = factory.transports.single;
  final List<String> resumeMessages = _sentOfType(transport, 'resume');
  expect(
    resumeMessages,
    hasLength(1),
    reason: '$shotName: resume must have been sent',
  );

  // The server has reaped the room: PROTOCOL section 3.
  transport.pushText(
    _frame(
      type: 'error',
      re: _idOf(resumeMessages.single),
      data: const <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
    ),
  );
  await tester.pump();
  await tester.pump();

  // Allow the route pop transition to finish.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  // Answer leave_room if HomeScreen's retirement sent it, as capture 32 does.
  final List<String> leaveMessages = _sentOfType(transport, 'leave_room');
  if (leaveMessages.isNotEmpty) {
    transport.pushText(
      _frame(
        type: 'player_left',
        re: _idOf(leaveMessages.single),
        data: const <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 2},
      ),
    );
    await tester.pump();
  }

  _expectHomeGameGoneState(
    tester,
    locale: locale,
    shotName: shotName,
    momentDescription: 'before settle',
  );

  await _pumpRealDurationFrames(tester);

  _expectHomeGameGoneState(
    tester,
    locale: locale,
    shotName: shotName,
    momentDescription: 'after settle',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

void _expectHomeGameGoneState(
  WidgetTester tester, {
  required Locale locale,
  required String shotName,
  required String momentDescription,
}) {
  expect(
    find.byType(LobbyScreen),
    findsNothing,
    reason:
        '$shotName ($momentDescription): the lobby route must have popped '
        'after the refused resume',
  );
  expect(
    find.byKey(const Key('lobby-error')),
    findsNothing,
    reason:
        '$shotName ($momentDescription): a refused resume must not render '
        'lobby-error',
  );
  expect(
    find.byType(HomeScreen),
    findsOneWidget,
    reason: '$shotName ($momentDescription): HomeScreen must be on screen',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(HomeScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$shotName ($momentDescription): expected locale '
        '"${locale.languageCode}", got "${loc.localeName}"',
  );

  expect(
    find.byKey(const Key('home-notice')),
    findsOneWidget,
    reason: '$shotName ($momentDescription): home-notice must be shown',
  );
  final Finder noticeFinder = find.byKey(const Key('home-game-gone-notice'));
  expect(
    noticeFinder,
    findsOneWidget,
    reason:
        '$shotName ($momentDescription): home-game-gone-notice must be '
        'shown on HomeScreen',
  );
  final Text noticeText = tester.widget<Text>(noticeFinder);
  expect(
    noticeText.data,
    loc.homeGameGoneNotice,
    reason:
        '$shotName ($momentDescription): home-game-gone-notice must read '
        'homeGameGoneNotice ("${loc.homeGameGoneNotice}"), got '
        '"${noticeText.data}"',
  );
  expect(
    find.byKey(const Key('home-removed-notice')),
    findsNothing,
    reason:
        '$shotName ($momentDescription): only one notice may be up, and it '
        'is the game-gone one',
  );
}

// --- order 369: captures 41-44 ---------------------------------------------
//
// The 2-player room is seated [0, 2], the seats the server gives two
// players (ludo_server registry _seatIndicesFor). My seat stays 0. The
// opponent is seat 2.
//
// After GameScreen mounts, each pushed frame is followed by two pumps so
// the screen's frame listener sees that frame's reduced turn before the
// next push (the listener runs as a microtask, the reducer runs first).
// A new tray die starts at opacity 0 and fades for 220ms, so the shot
// waits [_trayShotFrames] real frames after the photographed state is in
// the tree: 12 x 32ms is past that fade and past a two-square token step
// (140ms a step), and still inside the 1500ms no-move hold capture 44
// keeps on screen. pumpAndSettle is not used here. GameScreen's countdown
// ticker never settles.

const int _trayDeadlineMs = 45000;

const int _trayShotFrames = 12;

const String _trayReveal =
    'abcdef0123456789abcdef0123456789'
    'abcdef0123456789abcdef0123456789';

const List<Map<String, Object?>> _traySixAndThreeLegal = <Map<String, Object?>>[
  <String, Object?>{
    'face': 6,
    'tokens': <int>[0, 1, 2, 3],
  },
  <String, Object?>{
    'face': 3,
    'tokens': <int>[0],
  },
];

/// Every face of order 513's seven-face queue [3, 6, 6, 2, 6, 6, 4] can
/// move token 0 (on square 0); the 6 can also leave the yard.
const List<Map<String, Object?>> _trayAllFacesLegal = <Map<String, Object?>>[
  <String, Object?>{
    'face': 3,
    'tokens': <int>[0],
  },
  <String, Object?>{
    'face': 6,
    'tokens': <int>[0, 1, 2, 3],
  },
  <String, Object?>{
    'face': 2,
    'tokens': <int>[0],
  },
  <String, Object?>{
    'face': 4,
    'tokens': <int>[0],
  },
];

class _OpenedTrayGame {
  _OpenedTrayGame({
    required this.controller,
    required this.transport,
    required this.seq,
  });

  final RoomController controller;
  final FakeTransport transport;
  final int seq;
}

Future<void> _releaseTrayGame(
  WidgetTester tester,
  RoomController? controller,
) async {
  if (controller == null) {
    return;
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

/// Home, lobby, start, GameScreen. Returns with room seq at 3, seats
/// [0, 2], seat 0's turn, every token still in its yard. Caller disposes
/// [controller].
Future<_OpenedTrayGame> _openHostGame(
  WidgetTester tester, {
  required String capture,
  required String roomCode,
  required Locale locale,
  required String gameId,
  required String seatToken,
  FeedbackSettings? feedbackSettings,
  FeedbackService? feedbackService,
  String hostName = 'Priya',
  String opponentName = 'Karim',
}) async {
  final _ScreenshotControllerFactory trayFactory =
      _ScreenshotControllerFactory();
  try {
    Widget home;
    if (locale.languageCode == 'ar') {
      home = _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: trayFactory.call, onToggleLocale: () {}),
        locale: locale,
      );
    } else {
      home = _ScreenshotHarness(controllerFactory: trayFactory.call);
    }
    // The harnesses carry no FeedbackScope, and without one the sound
    // toggle flips a throwaway settings object nothing listens to. A caller
    // that wants to see the toggle move passes its own pair, above the
    // MaterialApp the way app.dart puts them.
    if (feedbackSettings != null && feedbackService != null) {
      home = FeedbackScope(
        settings: feedbackSettings,
        service: feedbackService,
        child: home,
      );
    }
    await tester.pumpWidget(home);
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapCreateRoom(tester);

    expect(
      trayFactory.controllers,
      hasLength(1),
      reason:
          'capture $capture: tapping Create Room must build exactly one '
          'controller',
    );
    final RoomController controller = trayFactory.controllers.single;
    final FakeTransport transport = trayFactory.transports.single;

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(
      createMessages,
      hasLength(1),
      reason:
          'capture $capture: expected one create_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
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
      'capture $capture: LobbyScreen after the create_room reply carrying '
      'code "$roomCode"',
    );

    transport.pushText(
      _frame(
        type: 'player_joined',
        data: <String, Object?>{'seat': 2, 'name': opponentName, 'seq': 2},
      ),
    );
    await tester.pump();

    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 2,
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      <int>[0, 2],
      reason:
          'capture $capture: a 2-player room is seated at [0, 2], got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );

    final Finder startButton = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton,
      findsOneWidget,
      reason:
          'capture $capture: the host, seat 0, must see a Start button '
          'once seated',
    );
    await tester.tap(startButton);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(
      startMessages,
      hasLength(1),
      reason: 'capture $capture: tapping Start must send one start_game',
    );
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': gameId,
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
      'capture $capture: GameScreen after game_started',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason:
          'capture $capture: RoomRoute must latch onto GameScreen and '
          'never go back',
    );
    expect(
      controller.room!.seq,
      3,
      reason: 'capture $capture: game_started must land at seq 3',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $capture: this device is seat 0',
    );

    return _OpenedTrayGame(
      controller: controller,
      transport: transport,
      seq: 3,
    );
  } catch (_) {
    for (final RoomController created in trayFactory.controllers) {
      await _releaseTrayGame(tester, created);
    }
    rethrow;
  }
}

Future<int> _pushTraySeq(
  WidgetTester tester,
  FakeTransport transport,
  int seq, {
  required String type,
  required Map<String, Object?> data,
}) async {
  final int next = seq + 1;
  transport.pushText(
    _frame(type: type, data: <String, Object?>{...data, 'seq': next}),
  );
  await tester.pump();
  await tester.pump();
  return next;
}

Future<int> _pushMyMoved(
  WidgetTester tester,
  FakeTransport transport,
  int seq, {
  required int from,
  required int to,
  int? face,
}) {
  return _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'moved',
    data: <String, Object?>{
      'seat': 0,
      'token': 0,
      'from': from,
      'to': to,
      'captured': <Object?>[],
      'extra_roll': false,
      'face': ?face,
    },
  );
}

/// Case 1's rolls: 6, then 6, then [finalValue]. The last `rolled` is the
/// move-pending frame (no `turn` after it) and carries [finalQueue].
Future<int> _pushSixSixThen(
  WidgetTester tester,
  FakeTransport transport,
  int seq, {
  required int finalValue,
  required List<int> finalQueue,
  required List<Map<String, Object?>> legalByFace,
}) async {
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'rolled',
    data: <String, Object?>{
      'seat': 0,
      'value': 6,
      'legal': <int>[],
      'deadline_ms': _trayDeadlineMs,
      'k': 1,
      'reveal': _trayReveal,
      'queue': <int>[6],
    },
  );
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'turn',
    data: <String, Object?>{
      'seat': 0,
      'phase': 'await_roll',
      'deadline_ms': _trayDeadlineMs,
      'queue': <int>[6],
    },
  );
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'rolled',
    data: <String, Object?>{
      'seat': 0,
      'value': 6,
      'legal': <int>[],
      'deadline_ms': _trayDeadlineMs,
      'k': 2,
      'reveal': _trayReveal,
      'queue': <int>[6, 6],
    },
  );
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'turn',
    data: <String, Object?>{
      'seat': 0,
      'phase': 'await_roll',
      'deadline_ms': _trayDeadlineMs,
      'queue': <int>[6, 6],
    },
  );
  seq = await _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'rolled',
    data: <String, Object?>{
      'seat': 0,
      'value': finalValue,
      'legal': <int>[0, 1, 2, 3],
      'deadline_ms': _trayDeadlineMs,
      'k': 3,
      'reveal': _trayReveal,
      'queue': finalQueue,
      'legal_by_face': legalByFace,
    },
  );
  return seq;
}

void _expectKey(
  WidgetTester tester,
  Key key, {
  required bool present,
  required String reason,
}) {
  expect(
    find.byKey(key),
    present ? findsOneWidget : findsNothing,
    reason: reason,
  );
}

void _expectChildKey(
  WidgetTester tester,
  Key parent,
  Key child,
  String reason,
) {
  expect(
    find.descendant(of: find.byKey(parent), matching: find.byKey(child)),
    findsOneWidget,
    reason: reason,
  );
}

void _expectTrayBesideDie(
  WidgetTester tester, {
  required bool onTheRight,
  required String reason,
}) {
  final Rect die = tester.getRect(find.byKey(const Key('game-die')));
  final Rect tray = tester.getRect(find.byKey(const Key('game-roll-tray')));
  expect(
    tray.center.dx,
    onTheRight ? greaterThan(die.center.dx) : lessThan(die.center.dx),
    reason: reason,
  );
  expect(
    (tray.center.dy - die.center.dy).abs(),
    lessThan(36),
    reason: '$reason, on the big die\'s row',
  );
}

String _viewText(WidgetTester tester) {
  final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
  return '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} dp';
}

/// C-420 D3/D5 as C-511 D3 keeps them for every mode the tray can be in
/// (natural, grouped, compact): the count each tile reads out in its
/// TalkBack label adds up to the queue length. A tile with no count
/// suffix stands for one face. The tile keys stay `game-roll-tray-die-<i>`
/// with `i` the queue index of the group's first member, so only those
/// indices are probed, never one tile per queue entry.
Future<void> _expectTrayCountsSum(
  WidgetTester tester, {
  required int queueLength,
  required Locale locale,
  required String shotName,
  required String scenario,
}) async {
  final SemanticsHandle semantics = tester.ensureSemantics();
  try {
    await tester.pump();
    final RegExp suffix = locale.languageCode == 'ar'
        ? RegExp(r'، العدد (\d+)$')
        : RegExp(r', (\d+) of them$');
    final List<int> indices = <int>[
      for (int i = 0; i < queueLength; i++)
        if (find.byKey(Key('game-roll-tray-die-$i')).evaluate().isNotEmpty) i,
    ];
    final List<String> labels = <String>[
      for (final int i in indices)
        tester.getSemantics(find.byKey(Key('game-roll-tray-die-$i'))).label,
    ];
    final List<int> counts = <int>[
      for (final String label in labels)
        suffix.firstMatch(label) == null
            ? 1
            : int.parse(suffix.firstMatch(label)!.group(1)!),
    ];
    final int sum = counts.fold(0, (int a, int b) => a + b);
    expect(
      sum,
      queueLength,
      reason:
          'capture $shotName ($scenario): C-420 D5 / C-511 D3, the tile '
          'counts read from the TalkBack labels must sum to the queue '
          'length $queueLength; tiles at queue indices $indices read '
          '$labels, counts $counts, sum $sum',
    );
  } finally {
    semantics.dispose();
  }
}

/// C-511 D1: nothing in the die row sits under the hint control. The die,
/// its no-move mark when it is up, and the tray each stay clear of the
/// `game-hint-button` rect. The hint must be on screen for the check to
/// mean anything, so its absence is a failure of its own.
void _expectDieRowClearOfHint(
  WidgetTester tester, {
  required String shotName,
  required String scenario,
}) {
  final Finder hintFinder = find.byKey(const Key('game-hint-button'));
  expect(
    hintFinder,
    findsOneWidget,
    reason:
        'capture $shotName ($scenario): C-511 D1, game-hint-button must be '
        'on screen for the die row to be measured against it',
  );
  final Rect hint = tester.getRect(hintFinder);
  final Rect die = tester.getRect(find.byKey(const Key('game-die')));
  final Finder markFinder = find.byKey(const Key('game-die-no-move-mark'));
  final Rect? mark = markFinder.evaluate().isEmpty
      ? null
      : tester.getRect(markFinder);
  final Rect tray = tester.getRect(find.byKey(const Key('game-roll-tray')));
  final List<String> hits = <String>[
    if (die.overlaps(hint)) 'game-die',
    if (mark != null && mark.overlaps(hint)) 'game-die-no-move-mark',
    if (tray.overlaps(hint)) 'game-roll-tray',
  ];
  expect(
    hits,
    isEmpty,
    reason:
        'capture $shotName ($scenario): C-511 D1, nothing in the die row '
        'may intersect game-hint-button ${_rectText(hint)}; '
        'intersecting: $hits; game-die ${_rectText(die)}, '
        'game-die-no-move-mark ${mark == null ? 'absent' : _rectText(mark)}, '
        'game-roll-tray ${_rectText(tray)}',
  );
}

int _progressOf(RoomController controller, int seat, int token) {
  for (final SeatState seatState in controller.room!.seats) {
    if (seatState.seat == seat) {
      return seatState.tokens[token];
    }
  }
  throw TestFailure('seat $seat is not in the room');
}

/// Captures 41 and 42. My turn, queue [6, 6, 3] after the third roll,
/// token 0 on square 0 so both the 6 and the 3 are live, the big die on
/// the thrown 3 (C-462 D7), rings on all four of my tokens.
Future<void> _shootLiveTray(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushMyMoved(
      tester,
      opened.transport,
      opened.seq,
      from: -1,
      to: 0,
    );
    expect(
      _progressOf(controller, 0, 0),
      0,
      reason:
          'capture $shotName: token 0 must sit on square 0 before the rolls',
    );
    seq = await _pushSixSixThen(
      tester,
      opened.transport,
      seq,
      finalValue: 3,
      finalQueue: const <int>[6, 6, 3],
      legalByFace: _traySixAndThreeLegal,
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: the turn stays mine');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: the third roll leaves a move pending',
    );
    expect(
      turn.queue,
      <int>[6, 6, 3],
      reason: 'capture $shotName: the queue after the third roll is [6, 6, 3]',
    );
    expect(
      _progressOf(controller, 0, 0),
      0,
      reason: 'capture $shotName: token 0 is still on square 0',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('game-roll-tray'),
      present: true,
      reason: 'capture $shotName: K1 game-roll-tray',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-0'),
      const Key('game-roll-tray-face-0-6'),
      'capture $shotName: K2 die 0 draws 6',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-dead-0'),
      present: false,
      reason: 'capture $shotName: K3 die 0 is not dead',
    );
    // C-511 D3: the tray may be grouped at this size, and then die 1 does
    // not exist (the group keeps its first member's index). The two 6s
    // are checked by the count sum below instead.
    await _expectTrayCountsSum(
      tester,
      queueLength: 3,
      locale: locale,
      shotName: shotName,
      scenario: 'queue [6, 6, 3], ${_viewText(tester)}',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-dead-1'),
      present: false,
      reason: 'capture $shotName: K3 die 1 is live',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-2'),
      const Key('game-roll-tray-face-2-3'),
      'capture $shotName: K2 die 2 draws 3',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-dead-2'),
      present: false,
      reason: 'capture $shotName: K3 the 3 is live',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-die-3'),
      present: false,
      reason: 'capture $shotName: the tray holds three dice',
    );
    _expectKey(
      tester,
      const Key('game-die-face-3'),
      present: true,
      reason: 'capture $shotName: C-462 D7 the big die shows turn.value 3',
    );
    _expectKey(
      tester,
      const Key('game-die-face-6'),
      present: false,
      reason: 'capture $shotName: the big die is not showing 6',
    );
    for (final int token in <int>[0, 1, 2, 3]) {
      _expectKey(
        tester,
        Key('board-legal-ring-0-$token'),
        present: true,
        reason: 'capture $shotName: K7 the default 6 rings token $token',
      );
    }
    _expectTrayBesideDie(
      tester,
      onTheRight: locale.languageCode == 'en',
      reason:
          'capture $shotName: K1 the tray sits after the big die in '
          'reading order',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Captures 43 and 63. Same three rolls as 41, plus a dead 2 on the end of
/// the queue (cases 4 and 12 leave a 2 out of legal_by_face), then a tap on
/// token 0 (`board-token-hit-0-0`). Both the 6 and the 3 can move token 0,
/// so the face picker opens on token 0 (C-462 D2, D4).
Future<void> _shootPickedTray(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushMyMoved(
      tester,
      opened.transport,
      opened.seq,
      from: -1,
      to: 0,
    );
    seq = await _pushSixSixThen(
      tester,
      opened.transport,
      seq,
      finalValue: 3,
      finalQueue: const <int>[6, 6, 3, 2],
      legalByFace: _traySixAndThreeLegal,
    );

    _expectKey(
      tester,
      const Key('board-legal-ring-0-1'),
      present: true,
      reason: 'capture $shotName: the 6 rings token 1 before the tap',
    );
    _expectKey(
      tester,
      const Key('board-face-picker'),
      present: false,
      reason: 'capture $shotName: the picker is closed before the tap',
    );

    final Finder tokenZero = find.byKey(const Key('board-token-hit-0-0'));
    expect(
      tokenZero,
      findsOneWidget,
      reason: 'capture $shotName: board-token-hit-0-0 is on the board',
    );
    final int sentBefore = opened.transport.sentRaw.length;
    await tester.tap(tokenZero, warnIfMissed: false);
    await tester.pump();
    expect(
      opened.transport.sentRaw.length,
      sentBefore,
      reason: 'capture $shotName: C-462 D2 tapping token 0 sends nothing',
    );
    _expectKey(
      tester,
      const Key('board-face-picker'),
      present: true,
      reason: 'capture $shotName: C-462 D4 board-face-picker opens on token 0',
    );
    _expectChildKey(
      tester,
      const Key('board-face-picker'),
      const Key('board-face-picker-option-6'),
      'capture $shotName: C-462 D4 option 6 is in the picker',
    );
    _expectChildKey(
      tester,
      const Key('board-face-picker'),
      const Key('board-face-picker-option-3'),
      'capture $shotName: C-462 D4 option 3 is in the picker',
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: the turn stays mine');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: the pick does not leave awaitMove',
    );
    expect(turn.queue, <int>[
      6,
      6,
      3,
      2,
    ], reason: 'capture $shotName: the queue is [6, 6, 3, 2]');
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('board-face-picker'),
      present: true,
      reason: 'capture $shotName: C-462 D4 board-face-picker stays open',
    );
    _expectChildKey(
      tester,
      const Key('board-face-picker'),
      const Key('board-face-picker-option-6'),
      'capture $shotName: C-462 D4 option 6 stays in the picker',
    );
    _expectChildKey(
      tester,
      const Key('board-face-picker'),
      const Key('board-face-picker-option-3'),
      'capture $shotName: C-462 D4 option 3 stays in the picker',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray'),
      present: true,
      reason: 'capture $shotName: K1 game-roll-tray',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-0'),
      const Key('game-roll-tray-face-0-6'),
      'capture $shotName: K2 die 0 still draws 6',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-dead-0'),
      present: false,
      reason: 'capture $shotName: K3 die 0 is live',
    );
    // C-511 D3: grouped or compact, die 1 does not exist (the group keeps
    // its first member's index). The two 6s are checked by the count sum.
    await _expectTrayCountsSum(
      tester,
      queueLength: 4,
      locale: locale,
      shotName: shotName,
      scenario: 'queue [6, 6, 3, 2], ${_viewText(tester)}',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-dead-1'),
      present: false,
      reason: 'capture $shotName: K3 die 1 is live',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-2'),
      const Key('game-roll-tray-face-2-3'),
      'capture $shotName: K2 die 2 draws the live 3',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-dead-2'),
      present: false,
      reason: 'capture $shotName: K3 the 3 is not dead',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-3'),
      const Key('game-roll-tray-face-3-2'),
      'capture $shotName: K2 die 3 draws the dead 2',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-3'),
      const Key('game-roll-tray-dead-3'),
      'capture $shotName: K3 game-roll-tray-dead-3 marks the 2',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-die-4'),
      present: false,
      reason: 'capture $shotName: the tray holds four dice',
    );
    _expectKey(
      tester,
      const Key('game-die-face-3'),
      present: true,
      reason: 'capture $shotName: C-462 D7 the big die shows turn.value 3',
    );
    _expectKey(
      tester,
      const Key('game-die-face-6'),
      present: false,
      reason: 'capture $shotName: the big die is not showing 6',
    );
    for (final int token in <int>[0, 1, 2, 3]) {
      _expectKey(
        tester,
        Key('board-legal-ring-0-$token'),
        present: true,
        reason: 'capture $shotName: C-462 D1 the union rings token $token',
      );
    }
    _expectTrayBesideDie(
      tester,
      onTheRight: locale.languageCode == 'en',
      reason:
          'capture $shotName: K1 the tray sits after the big die in '
          'reading order',
    );
    _expectDieRowClearOfHint(
      tester,
      shotName: shotName,
      scenario: 'queue [6, 6, 3, 2], ${_viewText(tester)}',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Captures 93 and 94 (order 513, C-511 D3). My turn, `await_move`, queue
/// [3, 6, 6, 2, 6, 6, 4] with every face legal for at least one token and
/// the hint `ready`. Grouped, that is 6x4, 3, 2, 4: wider than the band the
/// hint leaves beside the die on a phone, so the tray scales down as one
/// piece. Which mode the tray is in is not asserted (it follows the size);
/// what holds in every mode is the count sum, the first-member keys, and a
/// die row clear of the hint. With [textScale] the system scale is set the
/// way capture 75 sets it.
Future<void> _shootCompactTray(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
  double? textScale,
}) async {
  const List<int> queue = <int>[3, 6, 6, 2, 6, 6, 4];
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  if (textScale != null) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  } else {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushMyMoved(
      tester,
      opened.transport,
      opened.seq,
      from: -1,
      to: 0,
    );
    seq = await _pushSixSixThen(
      tester,
      opened.transport,
      seq,
      finalValue: 4,
      finalQueue: queue,
      legalByFace: _trayAllFacesLegal,
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final String scenario =
        'queue $queue, ${locale.languageCode}, '
        'text scale ${textScale ?? 1.0}, ${_viewText(tester)}';
    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName ($scenario): a pushed frame was dropped; room '
          'seq is ${controller.room!.seq}, last push was $seq',
    );
    expect(
      turn.seat,
      0,
      reason: 'capture $shotName ($scenario): the turn stays mine',
    );
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName ($scenario): the last roll leaves a move',
    );
    expect(
      turn.queue,
      queue,
      reason: 'capture $shotName ($scenario): the queue is $queue',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    if (textScale != null) {
      final Finder banner = find.byKey(const Key('game-screen-turn-banner'));
      expect(
        banner,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): game-screen-turn-banner must be '
            'on screen',
      );
      final double scaledTen = MediaQuery.textScalerOf(tester.element(banner))
          .scale(10);
      expect(
        scaledTen,
        10.0 * textScale,
        reason:
            'capture $shotName ($scenario): expected MediaQuery.textScalerOf '
            'at game-screen-turn-banner to scale 10 to ${10.0 * textScale}, '
            'got $scaledTen',
      );
    }

    _expectKey(
      tester,
      const Key('game-hint-ready'),
      present: true,
      reason:
          'capture $shotName ($scenario): C-471 D3, game-hint-ready must be '
          'shown',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray'),
      present: true,
      reason: 'capture $shotName ($scenario): K1 game-roll-tray',
    );
    // The first member of each distinct face keeps its queue index in every
    // mode (C-420 D2): 3 at 0, 6 at 1, 2 at 3, 4 at 6.
    for (final (int index, int face) in <(int, int)>[
      (0, 3),
      (1, 6),
      (3, 2),
      (6, 4),
    ]) {
      _expectChildKey(
        tester,
        Key('game-roll-tray-die-$index'),
        Key('game-roll-tray-face-$index-$face'),
        'capture $shotName ($scenario): K2 the first $face is die $index',
      );
    }
    for (int index = 0; index < queue.length; index++) {
      _expectKey(
        tester,
        Key('game-roll-tray-dead-$index'),
        present: false,
        reason:
            'capture $shotName ($scenario): K3 every face is legal, so '
            'no tile is dead',
      );
    }
    _expectKey(
      tester,
      const Key('game-die-face-4'),
      present: true,
      reason:
          'capture $shotName ($scenario): C-462 D7 the big die shows '
          'turn.value 4',
    );
    await _expectTrayCountsSum(
      tester,
      queueLength: queue.length,
      locale: locale,
      shotName: shotName,
      scenario: scenario,
    );
    _expectTrayBesideDie(
      tester,
      onTheRight: locale.languageCode == 'en',
      reason:
          'capture $shotName ($scenario): K1 the tray sits after the big '
          'die in reading order',
    );
    _expectDieRowClearOfHint(tester, shotName: shotName, scenario: scenario);

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
    if (textScale != null) {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  }
}

/// Capture 44. Case 6, Arabic, my own seat. Queue [3, 2, 1] with only the
/// 2 live, then moved face 2, turn_passed no_legal_move, turn to seat 2.
/// The tray keeps the unspent 3 and 1, both dead. The big die holds the
/// last of those, face 1, under the red X, with the no-move line.
Future<void> _shootDeadTray(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  const String shotName = '44-game-tray-dead-ar';
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: 'SHOT44',
      locale: const Locale('ar'),
      gameId: 'v' * 16,
      seatToken: 'tok-shot-44',
    );
    controller = opened.controller;

    // -1 to 10 is not a step the board animates, so the token snaps onto
    // square 10. The killing moved then walks 10 to 12, matching case 6.
    int seq = await _pushMyMoved(
      tester,
      opened.transport,
      opened.seq,
      from: -1,
      to: 10,
    );
    expect(
      _progressOf(controller, 0, 0),
      10,
      reason:
          'capture $shotName: token 0 must sit on square 10 before the move',
    );

    // One live face and one token would auto-move after 1500ms. The
    // killing moved follows on the next pumps, before that hold fires.
    // A turn frame carries k forward; it does not read k. After
    // game_started, k stays 0. Case 6's dead faces do not depend on k.
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': _trayDeadlineMs,
        'queue': <int>[3, 2, 1],
        'value': 2,
        'legal': <int>[0],
        'legal_by_face': <Map<String, Object?>>[
          <String, Object?>{
            'face': 2,
            'tokens': <int>[0],
          },
        ],
      },
    );
    seq = await _pushMyMoved(
      tester,
      opened.transport,
      seq,
      from: 10,
      to: 12,
      face: 2,
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn_passed',
      data: <String, Object?>{'seat': 0, 'reason': 'no_legal_move'},
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{
        'seat': 2,
        'phase': 'await_roll',
        'deadline_ms': _trayDeadlineMs,
        'queue': <int>[],
      },
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName: this device is still my seat',
    );
    expect(
      turn.seat,
      2,
      reason: 'capture $shotName: the turn has passed to seat 2',
    );
    expect(
      turn.phaseName,
      'awaitRoll',
      reason: 'capture $shotName: seat 2 is waiting to roll',
    );
    expect(
      turn.queue,
      <int>[],
      reason: 'capture $shotName: the live turn queue is empty',
    );
    expect(
      _progressOf(controller, 0, 0),
      12,
      reason: 'capture $shotName: the spent 2 landed token 0 on square 12',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      'ar',
      reason: 'capture $shotName: expected locale ar, got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('game-die-no-move-mark'),
      present: true,
      reason: 'capture $shotName: K9 the red X is on the big die',
    );
    final Finder notice = find.byKey(const Key('game-no-move-notice'));
    expect(
      notice,
      findsOneWidget,
      reason: 'capture $shotName: K9 game-no-move-notice',
    );
    expect(
      tester.widget<Text>(notice).data,
      loc.gameNoMove,
      reason:
          'capture $shotName: K9 the no-move line reads gameNoMove '
          '("${loc.gameNoMove}"), got '
          '"${tester.widget<Text>(notice).data}"',
    );
    _expectKey(
      tester,
      const Key('game-die-face-1'),
      present: true,
      reason: 'capture $shotName: K9 the big die shows the last dead face, 1',
    );
    _expectKey(
      tester,
      const Key('game-die-face-2'),
      present: false,
      reason: 'capture $shotName: the big die is not still showing the spent 2',
    );
    _expectKey(
      tester,
      const Key('game-die-face-3'),
      present: false,
      reason: 'capture $shotName: the big die is not showing the first dead 3',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray'),
      present: true,
      reason: 'capture $shotName: K9 the tray of dead faces is up',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-0'),
      const Key('game-roll-tray-face-0-3'),
      'capture $shotName: K9 die 0 draws the unspent 3',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-0'),
      const Key('game-roll-tray-dead-0'),
      'capture $shotName: K9 game-roll-tray-dead-0 marks the 3',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-1'),
      const Key('game-roll-tray-face-1-1'),
      'capture $shotName: K9 die 1 draws the unspent 1',
    );
    _expectChildKey(
      tester,
      const Key('game-roll-tray-die-1'),
      const Key('game-roll-tray-dead-1'),
      'capture $shotName: K9 game-roll-tray-dead-1 marks the 1',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray-die-2'),
      present: false,
      reason: 'capture $shotName: K9 the spent 2 is gone from the tray',
    );
    _expectTrayBesideDie(
      tester,
      onTheRight: false,
      reason:
          'capture $shotName: K1 in Arabic the tray sits to the left of '
          'the big die',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// The bits of [TurnState] these captures assert, without importing the
/// enum. `phase.name` is `awaitMove` or `awaitRoll`.
class TurnStateSnapshot {
  TurnStateSnapshot(this.seat, this.phaseName, this.queue);

  final int seat;
  final String phaseName;
  final List<int> queue;
}

TurnStateSnapshot _turnOf(RoomController controller) {
  final turn = controller.room!.turn!;
  return TurnStateSnapshot(turn.seat, turn.phase.name, turn.queue);
}

// --- order 375: captures 45-48 ---------------------------------------------
//
// One room, two seats. The server seats a 2-player room at [0, 2]. Each
// capture replays that room: token 0 of each seat in the yard, token 1 of
// each seat on the main track, seat 0 to roll. 45 and 47 sit at seat 0,
// 46 and 48 at seat 2. The quarter check is copied from
// test/board_view_rotation_test.dart (hit key, then token key; quarters of
// Key('ludo-board')). This file cannot import test/. pumpAndSettle is not
// used once GameScreen is up.

/// Main-track progress (0..51) of token 1 in captures 45-48. Leaving the
/// yard for square 0 is the one step the board animates; any other square
/// from -1 snaps, so the shot shows the token already on the track.
const int _viewerTrackProgress = 8;

Finder _tokenFinder(int seat, int tokenIndex) {
  final Finder hit = find.byKey(Key('board-token-hit-$seat-$tokenIndex'));
  if (hit.evaluate().isNotEmpty) {
    return hit;
  }
  return find.byKey(Key('token-$seat-$tokenIndex'));
}

bool _inBottomLeftQuarter(Offset point, Rect board) =>
    point.dx >= board.left &&
    point.dx < board.center.dx &&
    point.dy > board.center.dy &&
    point.dy <= board.bottom;

bool _inTopRightQuarter(Offset point, Rect board) =>
    point.dx > board.center.dx &&
    point.dx <= board.right &&
    point.dy >= board.top &&
    point.dy < board.center.dy;

String _offsetText(Offset point) =>
    '(dx: ${point.dx.toStringAsFixed(1)}, dy: ${point.dy.toStringAsFixed(1)})';

String _rectText(Rect rect) =>
    '(left: ${rect.left.toStringAsFixed(1)}, '
    'top: ${rect.top.toStringAsFixed(1)}, '
    'right: ${rect.right.toStringAsFixed(1)}, '
    'bottom: ${rect.bottom.toStringAsFixed(1)})';

/// A `moved` for any seat. [_pushMyMoved] is seat 0 token 0, which captures
/// 41-44 still use. Token placement here is not a spent face.
Future<int> _pushSeatMoved(
  WidgetTester tester,
  FakeTransport transport,
  int seq, {
  required int seat,
  required int token,
  required int from,
  required int to,
}) {
  return _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'moved',
    data: <String, Object?>{
      'seat': seat,
      'token': token,
      'from': from,
      'to': to,
      'captured': <Object?>[],
      'extra_roll': false,
    },
  );
}

/// Join Priya's room as Karim, seat 2. The room reply already holds both
/// seats, so there is no player_joined. Returns at seq 2, seat 0 to roll,
/// every token still in its yard. Caller disposes [controller].
Future<_OpenedTrayGame> _openGuestSeat(
  WidgetTester tester, {
  required String capture,
  required String roomCode,
  required Locale locale,
  required String gameId,
  required String seatToken,
}) async {
  expect(
    isValidRoomCode(normalizeRoomCode(roomCode)),
    isTrue,
    reason:
        'capture $capture fixture is broken: "$roomCode" must be a '
        'syntactically valid room code (room_code.dart\'s '
        'roomCodeAlphabet) or HomeScreen._joinRoom sets '
        'homeRoomCodeInvalid and returns before building a controller',
  );

  final _ScreenshotControllerFactory viewerFactory =
      _ScreenshotControllerFactory();
  try {
    final Widget home;
    if (locale.languageCode == 'ar') {
      home = _reconnectingCaptureHarness(
        HomeScreen(
          controllerFactory: viewerFactory.call,
          onToggleLocale: () {},
        ),
        locale: locale,
      );
    } else {
      home = _ScreenshotHarness(controllerFactory: viewerFactory.call);
    }
    await tester.pumpWidget(home);
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    const String hostName = 'Priya';
    const String guestName = 'Karim';
    await tester.enterText(find.byKey(const Key('home-name-field')), guestName);
    await tester.enterText(find.byKey(const Key('room-code-field')), roomCode);
    // Join is in the tree only once the field holds a full code (C-523 D3);
    // let its entry finish before the tap. Home only, so this settles.
    await tester.pumpAndSettle();
    await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

    expect(
      viewerFactory.controllers,
      hasLength(1),
      reason:
          'capture $capture: tapping Join Room must build exactly one '
          'controller',
    );
    final RoomController controller = viewerFactory.controllers.single;
    final FakeTransport transport = viewerFactory.transports.single;

    final List<String> joinMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'join_room')
        .toList();
    expect(
      joinMessages,
      hasLength(1),
      reason:
          'capture $capture: expected one join_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String joinId = _idOf(joinMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 2, 'seat_token': seatToken},
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
            _seatJson(0, name: hostName),
            _seatJson(2, name: guestName),
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
      'capture $capture: LobbyScreen after the join_room reply carrying '
      'code "$roomCode"',
    );
    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 2,
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      <int>[0, 2],
      reason:
          'capture $capture: a 2-player room is seated at [0, 2], got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );
    expect(
      controller.seat,
      2,
      reason: 'capture $capture: this device is seat 2',
    );

    transport.pushText(
      _frame(
        type: 'game_started',
        data: <String, Object?>{
          'turn': 0,
          'game_id': gameId,
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
      'capture $capture: GameScreen after game_started',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason:
          'capture $capture: RoomRoute must latch onto GameScreen and '
          'never go back',
    );
    expect(
      controller.room!.seq,
      2,
      reason: 'capture $capture: game_started must land at seq 2',
    );

    return _OpenedTrayGame(
      controller: controller,
      transport: transport,
      seq: 2,
    );
  } catch (_) {
    for (final RoomController created in viewerFactory.controllers) {
      await _releaseTrayGame(tester, created);
    }
    rethrow;
  }
}

/// Captures 45-48. Same room from [mySeat]: seats [0, 2], token 0 of each
/// seat in the yard, token 1 of each seat at [_viewerTrackProgress], seat 0
/// awaiting a roll.
Future<void> _shootViewerBoard(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int mySeat,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  expect(
    mySeat == 0 || mySeat == 2,
    isTrue,
    reason: 'capture $shotName: mySeat must be 0 or 2, got $mySeat',
  );

  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = mySeat == 0
        ? await _openHostGame(
            tester,
            capture: shotName,
            roomCode: roomCode,
            locale: locale,
            gameId: gameId,
            seatToken: seatToken,
          )
        : await _openGuestSeat(
            tester,
            capture: shotName,
            roomCode: roomCode,
            locale: locale,
            gameId: gameId,
            seatToken: seatToken,
          );
    controller = opened.controller;
    int seq = await _pushSeatMoved(
      tester,
      opened.transport,
      opened.seq,
      seat: 0,
      token: 1,
      from: -1,
      to: _viewerTrackProgress,
    );
    seq = await _pushSeatMoved(
      tester,
      opened.transport,
      seq,
      seat: 2,
      token: 1,
      from: -1,
      to: _viewerTrackProgress,
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      <int>[0, 2],
      reason:
          'capture $shotName: the photographed room is seated at [0, 2], '
          'got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );
    expect(
      controller.seat,
      mySeat,
      reason: 'capture $shotName: this device is seat $mySeat',
    );
    expect(
      <int>[
        _progressOf(controller, 0, 0),
        _progressOf(controller, 0, 1),
        _progressOf(controller, 0, 2),
        _progressOf(controller, 0, 3),
      ],
      <int>[-1, _viewerTrackProgress, -1, -1],
      reason:
          'capture $shotName: seat 0 keeps token 0 in the yard and token '
          '1 on the track',
    );
    expect(
      <int>[
        _progressOf(controller, 2, 0),
        _progressOf(controller, 2, 1),
        _progressOf(controller, 2, 2),
        _progressOf(controller, 2, 3),
      ],
      <int>[-1, _viewerTrackProgress, -1, -1],
      reason:
          'capture $shotName: seat 2 keeps token 0 in the yard and token '
          '1 on the track',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: it is seat 0\'s turn');
    expect(
      turn.phaseName,
      'awaitRoll',
      reason: 'capture $shotName: seat 0 is waiting to roll',
    );
    expect(
      turn.queue,
      <int>[],
      reason: 'capture $shotName: awaiting a roll, the queue is empty',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    final Finder boardFinder = find.byKey(const Key('ludo-board'));
    expect(
      boardFinder,
      findsOneWidget,
      reason: 'capture $shotName: ludo-board must be on screen',
    );
    final Rect boardRect = tester.getRect(boardFinder);
    final int opponentSeat = mySeat == 0 ? 2 : 0;

    final Finder viewerToken = _tokenFinder(mySeat, 0);
    expect(
      viewerToken,
      findsOneWidget,
      reason:
          'capture $shotName: viewer seat $mySeat token 0 must be in '
          'the tree',
    );
    final Offset viewerCenter = tester.getCenter(viewerToken);
    expect(
      _inBottomLeftQuarter(viewerCenter, boardRect),
      isTrue,
      reason:
          'capture $shotName: viewer seat $mySeat token 0 centre '
          '${_offsetText(viewerCenter)} must lie in the bottom-left '
          'quarter of ludo-board ${_rectText(boardRect)}',
    );

    final Finder opponentToken = _tokenFinder(opponentSeat, 0);
    expect(
      opponentToken,
      findsOneWidget,
      reason:
          'capture $shotName: opponent seat $opponentSeat token 0 must '
          'be in the tree',
    );
    final Offset opponentCenter = tester.getCenter(opponentToken);
    expect(
      _inTopRightQuarter(opponentCenter, boardRect),
      isTrue,
      reason:
          'capture $shotName: opponent seat $opponentSeat token 0 centre '
          '${_offsetText(opponentCenter)} must lie in the top-right '
          'quarter of ludo-board ${_rectText(boardRect)}',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// --- order 431: captures 49-52 ---------------------------------------------
//
// C-426's two timer-played notices (work/ludo/orders/
// C-426-timer-played-says-so.md, D3-D5, D9): `game-timer-played-notice`
// (D3, my own seat) and `game-timer-played-other-notice` (D4, another
// present and connected seat). Every pushed `rolled` / `moved` / `turn` /
// `turn_passed` shape below is copied by hand from
// test/timer_played_notice_test.dart (read-only, not imported -- this file
// cannot import test/), the same C2/C5/C6 fixtures that prove D3/D4/D5 there.
//
// The order's own prose names the opponent "seat 1" throughout this section.
// A real 2-player room is never seated that way: `_seatIndicesFor` (ludo_
// server/lib/src/registry.dart:1701) returns `[0, 2]` for `players: 2`, the
// same pair every other 2-seat capture in this file already uses (see the
// order-369 and order-375 header comments above, and `_openHostGame` /
// `_openGuestSeat`'s own hardcoded seat 2). Seat 1 only exists in a 3- or
// 4-player room. Since the order's own Goal section requires "frames must
// be ones the server could send," and a `players: 2` room naming seat 1
// would not be, every capture below reads the order's "seat 1" as "the
// other seat" and uses the real seat index, 2.

/// Captures 49 and 50. Host-only flow (opponent's name does not matter for
/// D3): [_openHostGame], seats [0, 2], my seat 0. My own `rolled` carries
/// `by: timer` with an empty `legal` ("a face with no legal move is fine",
/// the order's own words); `turn_passed` (no_legal_move) and `turn` (seat 2)
/// then hand the turn to the opponent. `game-timer-played-notice` must still
/// be on screen -- D3's "does NOT clear when my next turn begins" reads a
/// fortiori onto another seat's turn beginning, since nothing in D3 names
/// that as a clearing event either.
Future<void> _shootTimerPlayedMine(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = opened.seq;

    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
        'by': 'timer',
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn_passed',
      data: <String, Object?>{'seat': 0, 'reason': 'no_legal_move'},
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{'seat': 2, 'deadline_ms': _trayDeadlineMs},
    );

    // The timer's roll had no legal move, so the no-move line holds the
    // slot first (C-426 D5 priority) for `_noMoveHold`, 1500 ms; the
    // timer-played line is due once it ends. 60 frames of 32 ms clear it.
    await _pumpRealDurationFrames(tester, frameCount: 60);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      turn.seat,
      2,
      reason:
          'capture $shotName: the turn must have passed to seat 2 (the '
          'only other seat a real 2-player room seats), so seat 2\'s turn '
          'is what the shot shows',
    );
    expect(
      turn.phaseName,
      'awaitRoll',
      reason: 'capture $shotName: seat 2 is waiting to roll',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('game-timer-played-notice'),
      present: true,
      reason:
          'capture $shotName: C-426 D3, game-timer-played-notice must be '
          'on screen -- the timer played my own seat\'s rolled, and the '
          'notice stays up once the turn has passed to seat 2',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Host flow with the opponent's name fixed to "Rana" (D4's notice names
/// the other seat, so the name matters here, unlike [_shootTimerPlayedMine]).
/// A full copy of [_openHostGame]'s own steps rather than a shared call,
/// since that function's own `player_joined` name ("Karim") is not a
/// parameter and this order's files list allows only additions to this
/// file, never a changed line in an existing one. Returns with room seq at
/// 3, seats [0, 2], seat 0's turn, every token still in its yard, the same
/// state [_openHostGame] returns.
Future<_OpenedTrayGame> _openHostGameNamedOpponent(
  WidgetTester tester, {
  required String capture,
  required String roomCode,
  required Locale locale,
  required String gameId,
  required String seatToken,
  required String opponentName,
}) async {
  final _ScreenshotControllerFactory trayFactory =
      _ScreenshotControllerFactory();
  try {
    final Widget home;
    if (locale.languageCode == 'ar') {
      home = _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: trayFactory.call, onToggleLocale: () {}),
        locale: locale,
      );
    } else {
      home = _ScreenshotHarness(controllerFactory: trayFactory.call);
    }
    await tester.pumpWidget(home);
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    const String hostName = 'Priya';
    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(
      trayFactory.controllers,
      hasLength(1),
      reason:
          'capture $capture: tapping Create Room must build exactly one '
          'controller',
    );
    final RoomController controller = trayFactory.controllers.single;
    final FakeTransport transport = trayFactory.transports.single;

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(
      createMessages,
      hasLength(1),
      reason:
          'capture $capture: expected one create_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
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
      'capture $capture: LobbyScreen after the create_room reply carrying '
      'code "$roomCode"',
    );

    transport.pushText(
      _frame(
        type: 'player_joined',
        data: <String, Object?>{'seat': 2, 'name': opponentName, 'seq': 2},
      ),
    );
    await tester.pump();

    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 2,
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      <int>[0, 2],
      reason:
          'capture $capture: a 2-player room is seated at [0, 2], got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );

    final Finder startButton = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton,
      findsOneWidget,
      reason:
          'capture $capture: the host, seat 0, must see a Start button '
          'once seated',
    );
    await tester.tap(startButton);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(
      startMessages,
      hasLength(1),
      reason: 'capture $capture: tapping Start must send one start_game',
    );
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': gameId,
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
      'capture $capture: GameScreen after game_started',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason:
          'capture $capture: RoomRoute must latch onto GameScreen and '
          'never go back',
    );
    expect(
      controller.room!.seq,
      3,
      reason: 'capture $capture: game_started must land at seq 3',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $capture: this device is seat 0',
    );

    return _OpenedTrayGame(
      controller: controller,
      transport: transport,
      seq: 3,
    );
  } catch (_) {
    for (final RoomController created in trayFactory.controllers) {
      await _releaseTrayGame(tester, created);
    }
    rethrow;
  }
}

/// Captures 51 and 52. [_openHostGameNamedOpponent] with the opponent named
/// Rana, present and connected (`player_joined` always arrives with
/// `connected: true`, `room_controller.dart:1057`). Seat 0's own empty-legal
/// roll hands the turn to seat 2 (the same no-legal-move hand-off
/// [_shootTimerPlayedMine] uses, carrying no `by` here -- it is an ordinary
/// roll, not the timer's), then Rana's own `rolled` carries `by: timer` with
/// a legal move still pending ("whatever frames the rules require next":
/// a legal roll needs no further frame to reach a stable, photographable
/// state). `game-timer-played-other-notice` is shot inside its 2500ms hold
/// (D4), well within the dozen bounded pumps every other live capture here
/// already uses.
Future<void> _shootTimerPlayedOther(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  const String opponentName = 'Rana';
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGameNamedOpponent(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
      opponentName: opponentName,
    );
    controller = opened.controller;
    int seq = opened.seq;

    // Seat 0's own turn ends with no legal move (no `by`: this is my own
    // ordinary roll, not a timer step), handing the turn to seat 2.
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 1,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn_passed',
      data: <String, Object?>{'seat': 0, 'reason': 'no_legal_move'},
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{'seat': 2, 'deadline_ms': _trayDeadlineMs},
    );

    // Rana's (seat 2) own rolled carries by: timer, with a legal move
    // still pending -- the move itself is out of scope for this capture.
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 2,
        'value': 4,
        'legal': <int>[0],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
        'by': 'timer',
      },
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      turn.seat,
      2,
      reason: 'capture $shotName: it is seat 2 (Rana)\'s turn',
    );
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: Rana\'s timer roll leaves a move pending',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    final Finder otherNotice = find.byKey(
      const Key('game-timer-played-other-notice'),
    );
    expect(
      otherNotice,
      findsOneWidget,
      reason:
          'capture $shotName: C-426 D4, game-timer-played-other-notice '
          'must be on screen -- Rana (seat 2), present and connected, had '
          'her roll played by the timer',
    );
    final Text otherNoticeText = tester.widget<Text>(otherNotice);
    expect(
      otherNoticeText.data,
      contains(opponentName),
      reason:
          'capture $shotName: D4, the other-seat notice must name the '
          'seat ("$opponentName"); read "${otherNoticeText.data}"',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// --- order 467: captures 64-68 (C-465) -------------------------------------
//
// Emulator frames of each seat's die at its own side of the board (C-465).
// Same harness as captures 45-48 and 41-44: GameScreen over FakeTransport,
// frames copied by hand into this file, no server, no pumpAndSettle once
// GameScreen is up.

Future<void> _pumpUntilThrowGone(
  WidgetTester tester, {
  required int seat,
  required String shotName,
}) async {
  // Start the throw ticker on its first frame, then step in 50 ms increments
  // until every throw has left the tree (at most 6 s, 120 frames).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  // Throws play one after another across seats, so a seat's throw can
  // still be queued behind another seat's while its own overlay is
  // absent. Wait until no seat's throw is up for three steps.
  final Finder throwFinder = find.byKey(Key('opponent-throw-$seat'));
  bool anyThrowUp() {
    for (int s = 0; s < 4; s++) {
      if (find.byKey(Key('opponent-throw-$s')).evaluate().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  int goneSteps = 0;
  for (int step = 0; step < 120; step++) {
    goneSteps = anyThrowUp() ? 0 : goneSteps + 1;
    if (goneSteps >= 3) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    throwFinder,
    findsNothing,
    reason:
        'capture $shotName: C-465 D3, opponent-throw-$seat must finish and '
        'leave the tree within 6 s',
  );
}

/// Captures 64, 65, and 68. Two seats [0, 2], viewer at [mySeat], opponent at
/// [rollerSeat]. [rollerSeat] holds the turn and rolls [face]. The throw plays
/// out until `opponent-throw-$rollerSeat` leaves the tree, leaving
/// `board-seat-die-face-$rollerSeat-$face` in the top-right yard and the big
/// die below the board idle (`game-die-idle-art`).
Future<void> _shootSeatDieTwoSeats(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int mySeat,
  required int rollerSeat,
  required int face,
  required String roomCode,
  required String gameId,
  required String seatToken,
  double? textScale,
}) async {
  expect(
    (mySeat == 0 && rollerSeat == 2) || (mySeat == 2 && rollerSeat == 0),
    isTrue,
    reason:
        'capture $shotName: [mySeat, rollerSeat] must be [0, 2] or [2, 0], '
        'got [$mySeat, $rollerSeat]',
  );

  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  if (textScale != null) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  } else {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = mySeat == 0
        ? await _openHostGame(
            tester,
            capture: shotName,
            roomCode: roomCode,
            locale: locale,
            gameId: gameId,
            seatToken: seatToken,
          )
        : await _openGuestSeat(
            tester,
            capture: shotName,
            roomCode: roomCode,
            locale: locale,
            gameId: gameId,
            seatToken: seatToken,
          );
    controller = opened.controller;
    int seq = opened.seq;

    if (rollerSeat != 0) {
      seq = await _pushTraySeq(
        tester,
        opened.transport,
        seq,
        type: 'turn',
        data: <String, Object?>{
          'seat': rollerSeat,
          'deadline_ms': _trayDeadlineMs,
        },
      );
    }

    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': rollerSeat,
        'value': face,
        'legal': <int>[0],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
      },
    );

    await _pumpUntilThrowGone(tester, seat: rollerSeat, shotName: shotName);
    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      mySeat,
      reason: 'capture $shotName: viewer seat must be $mySeat',
    );
    expect(
      turn.seat,
      rollerSeat,
      reason: 'capture $shotName: it is seat $rollerSeat\'s turn',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    if (textScale != null) {
      final Finder banner = find.byKey(const Key('game-screen-turn-banner'));
      expect(
        banner,
        findsOneWidget,
        reason: 'capture $shotName: game-screen-turn-banner must be on screen',
      );
      final double scaledTen = MediaQuery.textScalerOf(tester.element(banner))
          .scale(10);
      expect(
        scaledTen,
        10.0 * textScale,
        reason:
            'capture $shotName: expected MediaQuery.textScalerOf at '
            'game-screen-turn-banner to scale 10 to ${10.0 * textScale}, '
            'got $scaledTen',
      );
    }

    _expectKey(
      tester,
      Key('board-seat-die-$rollerSeat'),
      present: true,
      reason:
          'capture $shotName: C-465 D2, board-seat-die-$rollerSeat must be '
          'on the board',
    );
    _expectKey(
      tester,
      Key('board-seat-die-face-$rollerSeat-$face'),
      present: true,
      reason:
          'capture $shotName: C-465 D2, '
          'board-seat-die-face-$rollerSeat-$face must show rolled face $face',
    );
    _expectKey(
      tester,
      Key('board-seat-die-$mySeat'),
      present: false,
      reason:
          'capture $shotName: C-465 D2, viewer seat $mySeat never draws a '
          'board-seat-die',
    );
    _expectKey(
      tester,
      const Key('game-die-idle-art'),
      present: true,
      reason:
          'capture $shotName: C-465 D1, the big die below the board is mine '
          'alone and stays on game-die-idle-art during seat $rollerSeat\'s '
          'turn',
    );
    _expectKey(
      tester,
      Key('game-die-face-$face'),
      present: false,
      reason:
          'capture $shotName: C-465 D1, the big die must not show seat '
          '$rollerSeat\'s face $face',
    );

    final Finder boardFinder = find.byKey(const Key('ludo-board'));
    expect(
      boardFinder,
      findsOneWidget,
      reason: 'capture $shotName: ludo-board must be on screen',
    );
    // The keyed board can be wider than the square it paints (large
    // text); measure the square, centred, as the board draws it.
    final Rect boardWidget = tester.getRect(boardFinder);
    final double boardSide = boardWidget.width < boardWidget.height
        ? boardWidget.width
        : boardWidget.height;
    final Rect boardRect = Rect.fromCenter(
      center: boardWidget.center,
      width: boardSide,
      height: boardSide,
    );
    final Finder seatDieFinder = find.byKey(Key('board-seat-die-$rollerSeat'));
    final Rect seatDieRect = tester.getRect(seatDieFinder);
    expect(
      _inTopRightQuarter(seatDieRect.center, boardRect),
      isTrue,
      reason:
          'capture $shotName: C-465 D2, seat $rollerSeat\'s die centre '
          '${_offsetText(seatDieRect.center)} must lie in the top-right '
          'yard quadrant of ludo-board ${_rectText(boardRect)}',
    );
    final double cellSize = boardRect.width / 15.0;
    final Rect topRightYard = Rect.fromLTWH(
      boardRect.left + 9.0 * cellSize,
      boardRect.top,
      6.0 * cellSize,
      6.0 * cellSize,
    );
    expect(
      seatDieRect.left >= topRightYard.left &&
          seatDieRect.top >= topRightYard.top &&
          seatDieRect.right <= topRightYard.right &&
          seatDieRect.bottom <= topRightYard.bottom,
      isTrue,
      reason:
          'capture $shotName: C-465 D2, seat $rollerSeat\'s die rect '
          '${_rectText(seatDieRect)} must sit inside seat $rollerSeat\'s '
          '6x6 yard quadrant ${_rectText(topRightYard)}',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
    if (textScale != null) {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  }
}

/// Joins a 4-seat room `[0, 1, 2, 3]` as Karim at seat 1 and starts the game
/// at seq 2 with seat 0 to roll. Caller disposes [controller].
Future<_OpenedTrayGame> _openFourSeatGuestGame(
  WidgetTester tester, {
  required String capture,
  required String roomCode,
  required Locale locale,
  required String gameId,
  required String seatToken,
}) async {
  expect(
    isValidRoomCode(normalizeRoomCode(roomCode)),
    isTrue,
    reason: 'capture $capture: "$roomCode" must be a valid room code',
  );

  final _ScreenshotControllerFactory viewerFactory =
      _ScreenshotControllerFactory();
  try {
    final Widget home;
    if (locale.languageCode == 'ar') {
      home = _reconnectingCaptureHarness(
        HomeScreen(
          controllerFactory: viewerFactory.call,
          onToggleLocale: () {},
        ),
        locale: locale,
      );
    } else {
      home = _ScreenshotHarness(controllerFactory: viewerFactory.call);
    }
    await tester.pumpWidget(home);
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    await tester.enterText(find.byKey(const Key('home-name-field')), 'Karim');
    await tester.enterText(find.byKey(const Key('room-code-field')), roomCode);
    // Join is in the tree only once the field holds a full code (C-523 D3);
    // let its entry finish before the tap. Home only, so this settles.
    await tester.pumpAndSettle();
    await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

    expect(
      viewerFactory.controllers,
      hasLength(1),
      reason:
          'capture $capture: tapping Join Room must build exactly one '
          'controller',
    );
    final RoomController controller = viewerFactory.controllers.single;
    final FakeTransport transport = viewerFactory.transports.single;

    final List<String> joinMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'join_room')
        .toList();
    expect(
      joinMessages,
      hasLength(1),
      reason: 'capture $capture: expected one join_room',
    );
    final String joinId = _idOf(joinMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 1, 'seat_token': seatToken},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: joinId,
        data: _roomJson(
          code: roomCode,
          players: 4,
          hostSeat: 0,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya'),
            _seatJson(1, name: 'Karim'),
            _seatJson(2, name: 'Lina'),
            _seatJson(3, name: 'Tariq'),
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
      'capture $capture: LobbyScreen after join_room reply',
    );
    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 4,
    );
    expect(
      controller.seat,
      1,
      reason: 'capture $capture: viewer device is seat 1',
    );

    transport.pushText(
      _frame(
        type: 'game_started',
        data: <String, Object?>{
          'turn': 0,
          'game_id': gameId,
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
      'capture $capture: GameScreen after game_started',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason: 'capture $capture: RoomRoute must latch onto GameScreen',
    );

    return _OpenedTrayGame(
      controller: controller,
      transport: transport,
      seq: 2,
    );
  } catch (_) {
    for (final RoomController created in viewerFactory.controllers) {
      await _releaseTrayGame(tester, created);
    }
    rethrow;
  }
}

/// Captures 66 and 67. Four seats `[0, 1, 2, 3]`, viewer seat 1. Seats 0 and 2
/// have each rolled once earlier (seat 0 rolled 2, seat 2 rolled 5), and seat
/// 3 now holds the turn on the roll queue `[6, 3]` in `awaitMove` with
/// `legal_by_face` for both faces (copied from `_shootLiveTray`).
Future<void> _shootSeatDieFourSeats(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openFourSeatGuestGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = opened.seq;

    // Place seat 3's token 0 on square 0 so both 6 and 3 are legal when seat 3
    // rolls [6, 3], matching _shootLiveTray.
    seq = await _pushSeatMoved(
      tester,
      opened.transport,
      seq,
      seat: 3,
      token: 0,
      from: -1,
      to: 0,
    );

    // Seat 0 rolls 2 while holding the turn, then the turn moves on to seat 2.
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 2,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn_passed',
      data: <String, Object?>{'seat': 0, 'reason': 'no_legal_move'},
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{'seat': 2, 'deadline_ms': _trayDeadlineMs},
    );

    // Seat 2 rolls 5 while holding the turn, then the turn moves on to seat 3.
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 2,
        'value': 5,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': 2,
        'reveal': _trayReveal,
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn_passed',
      data: <String, Object?>{'seat': 2, 'reason': 'no_legal_move'},
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{'seat': 3, 'deadline_ms': _trayDeadlineMs},
    );

    // Seat 3 rolls 6 then 3 onto the roll queue [6, 3], awaiting a move with
    // legal_by_face for both faces (shape copied from _shootLiveTray).
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 3,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': 3,
        'reveal': _trayReveal,
        'queue': <int>[6],
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{
        'seat': 3,
        'phase': 'await_roll',
        'deadline_ms': _trayDeadlineMs,
        'queue': <int>[6],
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 3,
        'value': 3,
        'legal': <int>[0, 1, 2, 3],
        'deadline_ms': _trayDeadlineMs,
        'k': 4,
        'reveal': _trayReveal,
        'queue': <int>[6, 3],
        'legal_by_face': _traySixAndThreeLegal,
      },
    );

    await _pumpUntilThrowGone(tester, seat: 3, shotName: shotName);
    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      1,
      reason: 'capture $shotName: viewer seat must be 1',
    );
    expect(turn.seat, 3, reason: 'capture $shotName: seat 3 holds the turn');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: seat 3 is in awaitMove on queue [6, 3]',
    );
    expect(turn.queue, <int>[
      6,
      3,
    ], reason: 'capture $shotName: seat 3 queue is [6, 3]');
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    // Three opponent seat dice on the board (seats 0, 2, 3) and none for
    // viewer seat 1.
    _expectKey(
      tester,
      const Key('board-seat-die-0'),
      present: true,
      reason: 'capture $shotName: C-465 D2, seat 0 die is on the board',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-face-0-2'),
      present: true,
      reason: 'capture $shotName: C-465 D2, seat 0 die shows its last roll 2',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-2'),
      present: true,
      reason: 'capture $shotName: C-465 D2, seat 2 die is on the board',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-face-2-5'),
      present: true,
      reason: 'capture $shotName: C-465 D2, seat 2 die shows its last roll 5',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-3'),
      present: true,
      reason: 'capture $shotName: C-465 D2, seat 3 die is on the board',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-face-3-3'),
      present: true,
      reason: 'capture $shotName: C-465 D2, seat 3 die shows turn.value 3',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-1'),
      present: false,
      reason: 'capture $shotName: C-465 D2, viewer seat 1 has no board die',
    );

    // Seat 3's roll record [6, 3] sits on the board at seat 3's yard, and
    // nothing is under the board at game-roll-tray.
    _expectKey(
      tester,
      const Key('board-seat-record-3'),
      present: true,
      reason:
          'capture $shotName: C-465 D4, seat 3\'s roll record [6, 3] sits '
          'at board-seat-record-3',
    );
    _expectChildKey(
      tester,
      const Key('board-seat-record-3'),
      const Key('game-roll-tray-face-0-6'),
      'capture $shotName: C-465 D4, record tile 0 shows 6',
    );
    _expectChildKey(
      tester,
      const Key('board-seat-record-3'),
      const Key('game-roll-tray-face-1-3'),
      'capture $shotName: C-465 D4, record tile 1 shows 3',
    );
    _expectKey(
      tester,
      const Key('game-roll-tray'),
      present: false,
      reason:
          'capture $shotName: C-465 D4, game-roll-tray is absent when '
          'another seat holds the turn',
    );
    _expectKey(
      tester,
      const Key('game-die-idle-art'),
      present: true,
      reason:
          'capture $shotName: C-465 D1, the big die below the board stays '
          'idle in viewer seat 1\'s colour',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// --- order 578: captures 17, 18, 69 and 70 replay a recorded capture --------
//
// The four captures photograph a capture of the recorded real games in
// integration_test/fixtures/real_games.json, through `_replayRealGameToCapture`.
// The capturing `moved` is walked by the board, the struck token flies home
// and the gloat starts at landing; the shot is taken `_captureShotSettleFrames`
// pumps later, 720 to 800 ms after landing, inside the gloat's 1350 ms at full
// opacity (C-468 D5, kCaptureGloatLife 1600 ms).

/// Real-duration pumps (32 ms each) between the replay's last frame and the
/// shot. The replay returns 400 to 460 ms after landing; these end well inside
/// the 1350 ms the gloat holds full opacity for.
const int _captureShotSettleFrames = 6;

/// Wall time after landing by which the shot must be taken; checked right
/// before it, so a device too slow for [_captureShotSettleFrames] fails with
/// the measured age instead of photographing a fading gloat.
const int _captureShotMaxAgeMs = 1100;

/// The home screen the replay starts from, in [locale]: Arabic is mounted
/// directly through HomeScreen the way captures 16 and 20 are.
Widget _replayHome(_ScreenshotControllerFactory factory, Locale locale) {
  if (locale.languageCode == 'ar') {
    return _reconnectingCaptureHarness(
      HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
      locale: locale,
    );
  }
  return _ScreenshotHarness(controllerFactory: factory.call);
}

/// Captures 17 and 18. The device is seat 0 (Priya, the host) of the recorded
/// game host_wins_1 and the capturer of its first capture. After the replay
/// the banner reads the capture roll-again line, the mover's token sits on
/// the recorded `to` and the struck token is back in its yard, all read off
/// the recorded frames.
Future<void> _shootCaptureRollAgain(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final _RealCaptureReplay replay = await _replayRealGameToCapture(
    tester,
    factory,
    capture: 'capture $shotName',
    gameName: 'host_wins_1',
    seat: 0,
    moverSeat: 0,
    ordinal: 1,
    localeName: locale.languageCode,
  );
  final RoomController controller = replay.controller;
  final _RealCaptureFrame found = replay.found;

  await _pumpUntilFound(
    tester,
    find.byKey(const Key('game-screen-board')),
    'the game board after the capturing moved push',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason: 'capture $shotName fixture is broken: wrong locale',
  );

  void expectCaptureMoment(String moment) {
    _expectCaptureRollAgain(
      tester,
      controller: controller,
      seat: found.turnSeat,
      captureName: shotName,
      expected: loc.gameRollAgainCapture,
      momentDescription: moment,
    );
    expect(
      _endCardTokens(controller, found.moverSeat)[found.moverToken],
      found.to,
      reason:
          'capture $shotName ($moment): expected my token (seat '
          '${found.moverSeat}, token ${found.moverToken}) to read '
          '${found.to} in controller.room!.seats after my own moved landed, '
          'got ${_endCardTokens(controller, found.moverSeat)[found.moverToken]}. '
          '${replay.describe}',
    );
    _expectCapturedTokenHome(
      tester,
      controller: controller,
      capturedSeat: found.capturedSeat,
      capturedToken: found.capturedToken,
      momentDescription: moment,
    );
  }

  expectCaptureMoment(
    'immediately after the capturing moved and the same-seat turn landed, '
    'before the post-move settle',
  );

  await _pumpRealDurationFrames(tester, frameCount: _captureShotSettleFrames);

  expectCaptureMoment(
    'after the post-move settle, immediately before capture $shotName',
  );
  _expectGloatAtFullOpacity(
    tester,
    replay,
    'immediately before capture $shotName',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

/// Captures 69 and 70. Two seats `[0, 2]`, the device at seat 0 (Priya, the
/// host) in the recorded game [gameName]; the [ordinal]th capture made by
/// [moverSeat] is walked for real. Seat 0 is the capturer in 70 and the
/// captured seat in 69. Everything numeric is read off the recorded frames.
Future<void> _shootCaptureGloat(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String gameName,
  required int moverSeat,
  required int ordinal,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final _RealCaptureReplay replay = await _replayRealGameToCapture(
    tester,
    factory,
    capture: 'capture $shotName',
    gameName: gameName,
    seat: 0,
    moverSeat: moverSeat,
    ordinal: ordinal,
    localeName: locale.languageCode,
  );
  final RoomController controller = replay.controller;
  final _RealCaptureFrame found = replay.found;
  final int capturerSeat = found.moverSeat;
  final int capturedSeat = found.capturedSeat;
  final int capturedToken = found.capturedToken;

  await _pumpRealDurationFrames(tester, frameCount: _captureShotSettleFrames);

  expect(
    controller.room!.seq,
    (replay.entry.view[found.turnIndex]['d']! as Map<String, Object?>)['seq'],
    reason:
        'capture $shotName: a pushed frame was dropped; room seq is '
        '${controller.room!.seq}. ${replay.describe}',
  );
  expect(
    controller.seat,
    0,
    reason: 'capture $shotName: viewer seat must be 0',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        'capture $shotName: expected locale ${locale.languageCode}, '
        'got ${loc.localeName}',
  );

  _expectKey(
    tester,
    Key('capture-gloat-$capturerSeat'),
    present: true,
    reason:
        'capture $shotName: C-468 D5, capture-gloat-$capturerSeat must '
        'still be on the board after the walk, the flight and the settle. '
        '${replay.describe}',
  );
  expect(
    _progressOf(controller, capturerSeat, found.moverToken),
    found.to,
    reason:
        'capture $shotName: capturer seat $capturerSeat token '
        '${found.moverToken} must read ${found.to} in controller.room. '
        '${replay.describe}',
  );
  _expectCapturedTokenHome(
    tester,
    controller: controller,
    capturedSeat: capturedSeat,
    capturedToken: capturedToken,
    momentDescription: 'after the walk, the flight and the settle',
  );
  _expectKey(
    tester,
    Key('board-capture-flight-$capturedSeat-$capturedToken'),
    present: false,
    reason:
        'capture $shotName: captured token flight must have finished '
        'before the shot. ${replay.describe}',
  );

  final Finder boardFinder = find.byKey(const Key('ludo-board'));
  expect(
    boardFinder,
    findsOneWidget,
    reason: 'capture $shotName: ludo-board must be on screen',
  );
  final Rect boardWidget = tester.getRect(boardFinder);
  final double boardSide = boardWidget.width < boardWidget.height
      ? boardWidget.width
      : boardWidget.height;
  final Rect boardRect = Rect.fromCenter(
    center: boardWidget.center,
    width: boardSide,
    height: boardSide,
  );

  final Finder capturedTokenFinder = _tokenFinder(capturedSeat, capturedToken);
  expect(
    capturedTokenFinder,
    findsOneWidget,
    reason:
        'capture $shotName: captured seat $capturedSeat token '
        '$capturedToken must be in the tree',
  );
  final Offset capturedTokenCenter = tester.getCenter(capturedTokenFinder);
  final bool inCapturedYard = capturedSeat == 0
      ? _inBottomLeftQuarter(capturedTokenCenter, boardRect)
      : _inTopRightQuarter(capturedTokenCenter, boardRect);
  expect(
    inCapturedYard,
    isTrue,
    reason:
        'capture $shotName: captured seat $capturedSeat token '
        '$capturedToken centre ${_offsetText(capturedTokenCenter)} must lie '
        'in its yard quadrant of ludo-board ${_rectText(boardRect)}',
  );

  final Finder gloatFinder = find.byKey(Key('capture-gloat-$capturerSeat'));
  final Offset gloatCenter = tester.getCenter(gloatFinder);
  final bool inCapturerYard = capturerSeat == 0
      ? _inBottomLeftQuarter(gloatCenter, boardRect)
      : _inTopRightQuarter(gloatCenter, boardRect);
  expect(
    inCapturerYard,
    isTrue,
    reason:
        'capture $shotName: C-468 D5.2, capture-gloat-$capturerSeat '
        'centre ${_offsetText(gloatCenter)} must lie in seat '
        '$capturerSeat\'s yard quadrant of ludo-board '
        '${_rectText(boardRect)}',
  );

  _expectGloatAtFullOpacity(
    tester,
    replay,
    'immediately before capture $shotName',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

/// Capture 71. Two seats `[0, 2]`, viewer seat 0, English. Seat 2 holds the
/// turn and has not rolled. Asserts the nearest `Opacity` ancestor of the art
/// under `game-die` has opacity 0.45 (C-468 D7).
Future<void> _shootIdleDieFaded(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = opened.seq;

    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{'seat': 2, 'deadline_ms': _trayDeadlineMs},
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName: viewer seat must be 0',
    );
    expect(turn.seat, 2, reason: 'capture $shotName: seat 2 holds the turn');
    expect(
      turn.phaseName,
      'awaitRoll',
      reason: 'capture $shotName: seat 2 has not rolled',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('game-die'),
      present: true,
      reason: 'capture $shotName: game-die must be on screen',
    );
    _expectKey(
      tester,
      const Key('game-die-idle-art'),
      present: true,
      reason:
          'capture $shotName: C-468 D7, the big die under the board is '
          'idle (game-die-idle-art) on seat 2\'s turn',
    );
    _expectKey(
      tester,
      const Key('board-seat-die-2'),
      present: true,
      reason: 'capture $shotName: C-465 D2, board-seat-die-2 is on the board',
    );

    final Finder dieArtFinder = find.descendant(
      of: find.byKey(const Key('game-die')),
      matching: find.byKey(const Key('game-die-idle-art')),
    );
    expect(
      dieArtFinder,
      findsOneWidget,
      reason:
          'capture $shotName: game-die-idle-art must be a descendant of '
          'game-die',
    );
    final Finder artPaintFinder = find.descendant(
      of: dieArtFinder,
      matching: find.byType(CustomPaint),
    );
    expect(
      artPaintFinder,
      findsOneWidget,
      reason: 'capture $shotName: game-die-idle-art must wrap a CustomPaint',
    );
    final Finder opacityFinder = find.ancestor(
      of: artPaintFinder,
      matching: find.byType(Opacity),
    );
    expect(
      opacityFinder,
      findsWidgets,
      reason:
          'capture $shotName: C-468 D7, the art under game-die must have '
          'an Opacity ancestor',
    );
    final Opacity nearestOpacity = tester.widget<Opacity>(opacityFinder.first);
    expect(
      nearestOpacity.opacity,
      0.45,
      reason:
          'capture $shotName: C-468 D7, the nearest Opacity ancestor of '
          'the art under game-die must have opacity 0.45 while another '
          'seat holds the turn, got ${nearestOpacity.opacity}',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// --- order 473: captures 72-75 (C-471) -------------------------------------
//
// Emulator frames of the one-time move hint control (C-471 D3) and board
// marker (C-471 D4). Same harness as captures 64-71 and 41-44: GameScreen
// over FakeTransport, frames copied by hand into this file, no server, no
// pumpAndSettle once GameScreen is up.

Future<void> _pumpBounded300ms(WidgetTester tester) async {
  // Start any newly mounted ticker on its first frame, then advance 300 ms in
  // six bounded 50 ms steps.
  await tester.pump();
  for (int step = 0; step < 6; step++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Places seat 0 token 0 on progress 10 (absolute square 10) and seat 2
/// token 0 on progress 42 (absolute square 16, six squares ahead of seat 0's
/// token 0 and not safe). Both snap from -1 without step animation.
Future<int> _pushHintBoardTokens(
  WidgetTester tester,
  RoomController controller,
  FakeTransport transport,
  int seq, {
  required String shotName,
}) async {
  seq = await _pushSeatMoved(
    tester,
    transport,
    seq,
    seat: 0,
    token: 0,
    from: -1,
    to: 10,
  );
  seq = await _pushSeatMoved(
    tester,
    transport,
    seq,
    seat: 2,
    token: 0,
    from: -1,
    to: 42,
  );
  expect(
    <int>[
      _progressOf(controller, 0, 0),
      _progressOf(controller, 0, 1),
      _progressOf(controller, 0, 2),
      _progressOf(controller, 0, 3),
    ],
    <int>[10, -1, -1, -1],
    reason: 'capture $shotName: seat 0 tokens must be [10, -1, -1, -1]',
  );
  expect(
    <int>[
      _progressOf(controller, 2, 0),
      _progressOf(controller, 2, 1),
      _progressOf(controller, 2, 2),
      _progressOf(controller, 2, 3),
    ],
    <int>[42, -1, -1, -1],
    reason: 'capture $shotName: seat 2 tokens must be [42, -1, -1, -1]',
  );
  return seq;
}

Future<int> _pushHintSingleRollSix(
  WidgetTester tester,
  FakeTransport transport,
  int seq,
) {
  return _pushTraySeq(
    tester,
    transport,
    seq,
    type: 'rolled',
    data: <String, Object?>{
      'seat': 0,
      'value': 6,
      'legal': <int>[0, 1, 2, 3],
      'deadline_ms': _trayDeadlineMs,
      'k': 1,
      'reveal': _trayReveal,
    },
  );
}

/// Capture 72. Two seats `[0, 2]`, viewer seat 0, English. Seat 0 rolled 6
/// with legal `[0, 1, 2, 3]` (two distinct choices: token 0 at 10 and yard
/// tokens 1..3 at -1). Asserts `game-hint-ready` before the shot (C-471 D3).
Future<void> _shootHintReady(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushHintBoardTokens(
      tester,
      controller,
      opened.transport,
      opened.seq,
      shotName: shotName,
    );
    seq = await _pushHintSingleRollSix(tester, opened.transport, seq);

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName: viewer seat must be 0',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: seat 0 holds the turn');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: seat 0 is in awaitMove after rolling 6',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('game-hint-button'),
      present: true,
      reason: 'capture $shotName: C-471 D3, game-hint-button must be shown',
    );
    _expectKey(
      tester,
      const Key('game-hint-ready'),
      present: true,
      reason: 'capture $shotName: C-471 D3, game-hint-ready must be shown',
    );
    _expectKey(
      tester,
      const Key('game-hint-waiting'),
      present: false,
      reason: 'capture $shotName: C-471 D3, game-hint-waiting must be absent',
    );
    _expectKey(
      tester,
      const Key('game-hint-used'),
      present: false,
      reason: 'capture $shotName: C-471 D3, game-hint-used must be absent',
    );
    _expectKey(
      tester,
      const Key('board-hint-0'),
      present: false,
      reason:
          'capture $shotName: C-471 D4, board-hint-0 must not show before '
          'tapping game-hint-button',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Capture 73. Same state as capture 72 in Arabic, then taps
/// `game-hint-button`, pumps 300 ms in bounded steps, and asserts
/// `board-hint-0`, no `board-hint-face-6`, and `game-hint-used` (C-471 D3, D4).
Future<void> _shootHintShown(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushHintBoardTokens(
      tester,
      controller,
      opened.transport,
      opened.seq,
      shotName: shotName,
    );
    seq = await _pushHintSingleRollSix(tester, opened.transport, seq);

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    _expectKey(
      tester,
      const Key('game-hint-button'),
      present: true,
      reason: 'capture $shotName: C-471 D3, game-hint-button must be shown',
    );
    _expectKey(
      tester,
      const Key('game-hint-ready'),
      present: true,
      reason:
          'capture $shotName: C-471 D3, game-hint-ready must be shown before '
          'the tap',
    );

    await tester.tap(find.byKey(const Key('game-hint-button')));
    await _pumpBounded300ms(tester);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName: viewer seat must be 0',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: seat 0 holds the turn');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: tapping hint does not leave awaitMove',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('board-hint-0'),
      present: true,
      reason:
          'capture $shotName: C-471 D4, board-hint-0 must mark token 0 '
          '(capturing seat 2 token 0 on square 16)',
    );
    _expectKey(
      tester,
      const Key('board-hint-face-6'),
      present: false,
      reason:
          'capture $shotName: C-471 D4, board-hint-face-6 must be absent '
          'when only one face is playable',
    );
    _expectKey(
      tester,
      const Key('game-hint-used'),
      present: true,
      reason:
          'capture $shotName: C-471 D3, game-hint-used must be shown after '
          'spending the hint',
    );
    _expectKey(
      tester,
      const Key('game-hint-ready'),
      present: false,
      reason:
          'capture $shotName: C-471 D3, game-hint-ready must be gone after '
          'spending the hint',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Capture 74. English, roll queue `[6, 3]` with `legal_by_face`
/// `[{face: 6, tokens: [0, 1, 2, 3]}, {face: 3, tokens: [0]}]`. Taps
/// `game-hint-button`, pumps 300 ms, asserts `board-hint-0` and
/// `board-hint-face-6`, then taps token 0 (`board-token-hit-0-0`) to open the
/// face picker, pumps 300 ms, and asserts `board-face-picker` and
/// `board-face-picker-hinted-6` before the shot (C-471 D3, D4).
Future<void> _shootHintQueue(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushHintBoardTokens(
      tester,
      controller,
      opened.transport,
      opened.seq,
      shotName: shotName,
    );

    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
        'queue': <int>[6],
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'turn',
      data: <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': _trayDeadlineMs,
        'queue': <int>[6],
      },
    );
    seq = await _pushTraySeq(
      tester,
      opened.transport,
      seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 3,
        'legal': <int>[0, 1, 2, 3],
        'deadline_ms': _trayDeadlineMs,
        'k': 2,
        'reveal': _trayReveal,
        'queue': <int>[6, 3],
        'legal_by_face': _traySixAndThreeLegal,
      },
    );

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    _expectKey(
      tester,
      const Key('game-hint-button'),
      present: true,
      reason: 'capture $shotName: C-471 D3, game-hint-button must be shown',
    );
    _expectKey(
      tester,
      const Key('game-hint-ready'),
      present: true,
      reason:
          'capture $shotName: C-471 D3, game-hint-ready must be shown before '
          'the tap',
    );

    await tester.tap(find.byKey(const Key('game-hint-button')));
    await _pumpBounded300ms(tester);

    _expectKey(
      tester,
      const Key('board-hint-0'),
      present: true,
      reason:
          'capture $shotName: C-471 D4, board-hint-0 must mark token 0 '
          'after tapping game-hint-button',
    );
    _expectKey(
      tester,
      const Key('board-hint-face-6'),
      present: true,
      reason:
          'capture $shotName: C-471 D4, board-hint-face-6 must show face 6 '
          'when two faces are playable',
    );
    _expectKey(
      tester,
      const Key('game-hint-used'),
      present: true,
      reason:
          'capture $shotName: C-471 D3, game-hint-used must be shown after '
          'tapping game-hint-button',
    );

    final Finder tokenZero = find.byKey(const Key('board-token-hit-0-0'));
    expect(
      tokenZero,
      findsOneWidget,
      reason: 'capture $shotName: board-token-hit-0-0 must be on the board',
    );
    final int sentBefore = opened.transport.sentRaw.length;
    await tester.tap(tokenZero, warnIfMissed: false);
    await _pumpBounded300ms(tester);

    expect(
      opened.transport.sentRaw.length,
      sentBefore,
      reason: 'capture $shotName: C-462 D2, tapping token 0 sends nothing',
    );

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName: viewer seat must be 0',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: seat 0 holds the turn');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: seat 0 remains in awaitMove',
    );
    expect(turn.queue, <int>[
      6,
      3,
    ], reason: 'capture $shotName: the roll queue is [6, 3]');
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    _expectKey(
      tester,
      const Key('board-hint-0'),
      present: true,
      reason:
          'capture $shotName: C-471 D4, board-hint-0 stays up while the '
          'face picker is open',
    );
    _expectKey(
      tester,
      const Key('board-hint-face-6'),
      present: true,
      reason:
          'capture $shotName: C-471 D4, board-hint-face-6 stays up while '
          'the face picker is open',
    );
    _expectKey(
      tester,
      const Key('board-face-picker'),
      present: true,
      reason:
          'capture $shotName: C-462 D4, board-face-picker must open on '
          'token 0',
    );
    _expectKey(
      tester,
      const Key('board-face-picker-hinted-6'),
      present: true,
      reason:
          'capture $shotName: C-471 D4, board-face-picker-hinted-6 must '
          'wrap face option 6 in the open picker',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Capture 75. Arabic, system text scale 2.0, the capture 72 state, with
/// `session.hintUsedGame` pre-seeded to [gameId] before mounting. Asserts
/// `game-hint-used` and no `board-hint-0` before the shot (C-471 D3, D5).
Future<void> _shootHintUsedLarge(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  SharedPreferences.setMockInitialValues(<String, Object>{
    'session.hintUsedGame': gameId,
  });
  tester.platformDispatcher.textScaleFactorTestValue = 2.0;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    int seq = await _pushHintBoardTokens(
      tester,
      controller,
      opened.transport,
      opened.seq,
      shotName: shotName,
    );
    seq = await _pushHintSingleRollSix(tester, opened.transport, seq);

    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: a pushed frame was dropped; room seq is '
          '${controller.room!.seq}, last push was $seq',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName: viewer seat must be 0',
    );
    expect(turn.seat, 0, reason: 'capture $shotName: seat 0 holds the turn');
    expect(
      turn.phaseName,
      'awaitMove',
      reason: 'capture $shotName: seat 0 is in awaitMove after rolling 6',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    final Finder banner = find.byKey(const Key('game-screen-turn-banner'));
    expect(
      banner,
      findsOneWidget,
      reason: 'capture $shotName: game-screen-turn-banner must be on screen',
    );
    final double scaledTen = MediaQuery.textScalerOf(tester.element(banner))
        .scale(10);
    expect(
      scaledTen,
      20.0,
      reason:
          'capture $shotName: expected MediaQuery.textScalerOf at '
          'game-screen-turn-banner to scale 10 to 20.0, got $scaledTen',
    );

    _expectKey(
      tester,
      const Key('game-hint-button'),
      present: true,
      reason: 'capture $shotName: C-471 D3, game-hint-button must be shown',
    );
    _expectKey(
      tester,
      const Key('game-hint-used'),
      present: true,
      reason:
          'capture $shotName: C-471 D3/D5, game-hint-used must be shown '
          'when session.hintUsedGame matches gameId',
    );
    _expectKey(
      tester,
      const Key('game-hint-ready'),
      present: false,
      reason:
          'capture $shotName: C-471 D3/D5, game-hint-ready must be absent '
          'when the hint was already used in this game',
    );
    _expectKey(
      tester,
      const Key('game-hint-waiting'),
      present: false,
      reason:
          'capture $shotName: C-471 D3/D5, game-hint-waiting must be absent '
          'when the hint was already used in this game',
    );
    _expectKey(
      tester,
      const Key('board-hint-0'),
      present: false,
      reason:
          'capture $shotName: C-471 D4/D5, board-hint-0 must not be shown '
          'on a fresh turn after the hint was spent earlier in the game',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await (await SharedPreferences.getInstance()).clear();
  }
}

// ============================================================================
// Order 476 (captures 76-78): no-move reason lines (C-474 D1, D2).
// ============================================================================

/// Captures 76-78 (order 476, C-474 D1, D2). Two seats `[0, 2]`, viewer seat 0.
/// When [needExact] is false (captures 76 and 77), all four of seat 0's tokens
/// stay in the yard (`[-1, -1, -1, -1]`) and seat 0 rolls [rollValue] (`3`)
/// with an empty `legal`, arming `loc.gameNoMoveNeedSix`. When [needExact] is
/// true (capture 78), seat 0's tokens are placed at `[55, 57, 57, 57]` and
/// seat 0 rolls [rollValue] (`4`) with an empty `legal`, arming
/// `loc.gameNoMoveNeedExact`.
Future<void> _shootNoMoveReason(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
  required int rollValue,
  required bool needExact,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    final FakeTransport transport = opened.transport;
    int seq = opened.seq;

    if (needExact) {
      seq = await _pushSeatMoved(
        tester,
        transport,
        seq,
        seat: 0,
        token: 0,
        from: -1,
        to: 55,
      );
      for (int token = 1; token <= 3; token++) {
        seq = await _pushSeatMoved(
          tester,
          transport,
          seq,
          seat: 0,
          token: token,
          from: -1,
          to: 57,
        );
      }
    }

    final List<int> expectedTokens = needExact
        ? <int>[55, 57, 57, 57]
        : <int>[-1, -1, -1, -1];
    expect(
      <int>[
        _progressOf(controller, 0, 0),
        _progressOf(controller, 0, 1),
        _progressOf(controller, 0, 2),
        _progressOf(controller, 0, 3),
      ],
      expectedTokens,
      reason: 'capture $shotName: seat 0 tokens must be $expectedTokens',
    );

    final int rolledSeq = seq + 1;
    final int turnSeq = seq + 2;
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': rollValue,
          'legal': <int>[],
          'deadline_ms': 41000,
          'k': 1,
          'seq': rolledSeq,
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': 2,
          'deadline_ms': 45000,
          'seq': turnSeq,
        },
      ),
    );
    seq = turnSeq;
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName: expected room seq $seq after rolled/turn pair, '
          'got ${controller.room!.seq}',
    );
    expect(
      controller.room!.turn!.seat,
      2,
      reason:
          'capture $shotName: expected turn seat 2 (Karim) immediately after '
          'the rolled/turn pair landed, got ${controller.room!.turn!.seat}',
    );

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, '
          'got ${loc.localeName}',
    );

    final String expectedLine = needExact
        ? loc.gameNoMoveNeedExact
        : loc.gameNoMoveNeedSix;
    _expectNoMoveVisible(
      tester,
      loc: loc,
      momentDescription:
          'immediately after the rolled/turn pair landed, before the '
          '~300ms settle',
      expectedText: expectedLine,
    );

    await _pumpRealDurationFrames(tester, frameCount: 10);

    expect(
      controller.room!.turn!.seat,
      2,
      reason:
          'capture $shotName: after the ~300ms settle, expected turn seat 2 '
          '(Karim) immediately before the capture, got '
          '${controller.room!.turn!.seat}',
    );
    _expectNoMoveVisible(
      tester,
      loc: loc,
      momentDescription:
          'after the ~300ms settle, immediately before capture $shotName',
      expectedText: expectedLine,
    );
    _expectKey(
      tester,
      Key('game-die-face-$rollValue'),
      present: true,
      reason:
          'capture $shotName: C-474 D1, the big die must show face $rollValue',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('game-no-move-notice'))).data,
      expectedLine,
      reason:
          'capture $shotName: C-474 D1/D2, game-no-move-notice must read '
          '"$expectedLine"',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// ============================================================================
// Order 482 (captures 79-83): quick messages (C-478 D5.2, D5.4).
// ============================================================================

/// The twelve presets of C-478 D3, quoted here and not looked up through
/// AppLocalizations, so a wrong ARB line fails the capture instead of being
/// photographed. Ids in the sheet's order.
const List<String> _chatIds = <String>[
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
  'no_way',
  'good_game',
];

const Map<String, String> _chatLinesEn = <String, String>{
  'hi': 'Hi all',
  'good_luck': 'Good luck',
  'your_move': 'Come on, your move!',
  'nice': 'Nice move',
  'lucky': 'So lucky!',
  'oops': 'Oops',
  'ha_ha': 'Ha ha ha',
  'revenge': 'I\'ll get you back',
  'coming': 'Run, I\'m coming!',
  'back_home': 'Back home you go',
  'no_way': 'No way!',
  'good_game': 'Good game',
};

const Map<String, String> _chatLinesAr = <String, String>{
  'hi': 'مرحبا يا جماعة',
  'good_luck': 'بالتوفيق',
  'your_move': 'يلا، دورك!',
  'nice': 'حلوة منك',
  'lucky': 'شو هالحظ!',
  'oops': 'أوبس',
  'ha_ha': 'هههههه',
  'revenge': 'رح ردّلك ياها',
  'coming': 'اهرب، جايّك!',
  'back_home': 'عالبيت يا حلو',
  'no_way': 'مستحيل!',
  'good_game': 'لعبة حلوة',
};

/// Held after the emote pushes land: past the 160 ms pop-in, well inside
/// the 2500 ms bubble life (C-478 D5.4).
const Duration _chatShotPump = Duration(milliseconds: 400);

/// Host flow for a 4-seat room `[0, 1, 2, 3]`, viewer seat 0 (Priya, the
/// host). Same steps as [_openHostGame] with three joins instead of one.
/// Returns with room seq at 5, seat 0's turn, every token still in its
/// yard. Caller disposes [controller].
Future<_OpenedTrayGame> _openFourSeatHostGame(
  WidgetTester tester, {
  required String capture,
  required String roomCode,
  required Locale locale,
  required String gameId,
  required String seatToken,
}) async {
  final _ScreenshotControllerFactory hostFactory =
      _ScreenshotControllerFactory();
  try {
    final Widget home;
    if (locale.languageCode == 'ar') {
      home = _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: hostFactory.call, onToggleLocale: () {}),
        locale: locale,
      );
    } else {
      home = _ScreenshotHarness(controllerFactory: hostFactory.call);
    }
    await tester.pumpWidget(home);
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    const String hostName = 'Priya';
    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));

    expect(
      hostFactory.controllers,
      hasLength(1),
      reason:
          'capture $capture: tapping Create Room must build exactly one '
          'controller',
    );
    final RoomController controller = hostFactory.controllers.single;
    final FakeTransport transport = hostFactory.transports.single;

    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(
      createMessages,
      hasLength(1),
      reason:
          'capture $capture: expected one create_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 4,
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
      'capture $capture: LobbyScreen after the create_room reply carrying '
      'code "$roomCode"',
    );

    const List<String> guestNames = <String>['Karim', 'Lina', 'Tariq'];
    for (int i = 0; i < guestNames.length; i++) {
      transport.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{
            'seat': i + 1,
            'name': guestNames[i],
            'seq': i + 2,
          },
        ),
      );
      await tester.pump();
    }

    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 4,
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      <int>[0, 1, 2, 3],
      reason:
          'capture $capture: a 4-player room is seated at [0, 1, 2, 3], got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );

    final Finder startButton = find.byKey(const Key('lobby-start-button'));
    expect(
      startButton,
      findsOneWidget,
      reason:
          'capture $capture: the host, seat 0, must see a Start button '
          'once seated',
    );
    await tester.tap(startButton);
    await tester.pump();
    final List<String> startMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'start_game')
        .toList();
    expect(
      startMessages,
      hasLength(1),
      reason: 'capture $capture: tapping Start must send one start_game',
    );
    final String startId = _idOf(startMessages.single);

    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': gameId,
          'client_seeds': '0:seed',
          'seq': 5,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(GameScreen),
      'capture $capture: GameScreen after game_started',
    );
    expect(
      find.byType(LobbyScreen),
      findsNothing,
      reason:
          'capture $capture: RoomRoute must latch onto GameScreen and '
          'never go back',
    );
    expect(
      controller.room!.seq,
      5,
      reason: 'capture $capture: game_started must land at seq 5',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $capture: this device is seat 0',
    );

    return _OpenedTrayGame(
      controller: controller,
      transport: transport,
      seq: 5,
    );
  } catch (_) {
    for (final RoomController created in hostFactory.controllers) {
      await _releaseTrayGame(tester, created);
    }
    rethrow;
  }
}

/// A server `emote` push as C-478 D1 sends it to the other sockets: `seat`
/// and `emote`, no `re`, no `seq`.
Future<void> _pushEmote(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required String emote,
}) async {
  transport.pushText(
    _frame(
      type: 'emote',
      data: <String, Object?>{'seat': seat, 'emote': emote},
    ),
  );
  await tester.pump();
}

/// Margin on top of [kChatMinDwell] before the next push: the dwell runs from
/// the frame that shows a line, which can land a frame after its push.
const Duration _chatDwellMargin = Duration(milliseconds: 160);

/// Lets the line that is up have its C-596 D1 dwell, in real-duration frames,
/// so the next push is shown at once and not queued behind it.
Future<void> _letChatLineDwell(WidgetTester tester) => _pumpRealDurationFrames(
  tester,
  frameCount: ((kChatMinDwell + _chatDwellMargin).inMilliseconds / 32).ceil(),
);

/// The ambient text scale the chat bubble stops at (C-596 D4).
const double _kChatBubbleMaxScale = 1.3;

/// The header row: the widest ancestor of the leave button whose height is
/// the 48 dp row, in [WidgetTester.getRect]'s coordinate space.
Rect _chatHeaderRow(WidgetTester tester) {
  final RenderBox leave = tester.renderObject<RenderBox>(
    find.byKey(const Key('game-screen-appbar-leave')),
  );
  RenderBox? row;
  RenderObject? walker = leave;
  while (walker != null) {
    if (walker is RenderBox && (walker.size.height - 48).abs() <= 0.5) {
      if (row == null || walker.size.width > row.size.width) {
        row = walker;
      }
    }
    walker = walker.parent;
  }
  expect(
    row,
    isNotNull,
    reason: 'a 48 dp ancestor of game-screen-appbar-leave',
  );
  return row!.localToGlobal(Offset.zero) & row.size;
}

/// C-596 D4: at a large text scale the bubble [bubble] still lies inside the
/// 48 dp header row, edges included.
void _expectChatInsideHeaderRow(
  WidgetTester tester,
  Rect bubble, {
  required int seat,
  required String shotName,
  required String scenario,
}) {
  final Rect row = _chatHeaderRow(tester);
  const double eps = 0.5;
  expect(
    bubble.left >= row.left - eps &&
        bubble.right <= row.right + eps &&
        bubble.top >= row.top - eps &&
        bubble.bottom <= row.bottom + eps,
    isTrue,
    reason:
        'capture $shotName ($scenario): C-596 D4, end-card-chat-$seat '
        '($bubble) must lie inside the 48 dp header row ($row)',
  );
}

/// What a capture of the quick messages needs on screen before the shot:
/// the room PLAYING, this device on [viewerSeat], the locale named, and the
/// turn on seat 0 awaiting a roll.
void _expectChatFixture(
  WidgetTester tester,
  RoomController controller, {
  required String shotName,
  required String scenario,
  required Locale locale,
  required List<int> seats,
}) {
  expect(
    controller.room!.state,
    RoomState.playing,
    reason:
        'capture $shotName ($scenario): the room must be PLAYING, got '
        '${controller.room!.state}',
  );
  expect(
    controller.room!.seats.map((SeatState s) => s.seat).toList(),
    seats,
    reason:
        'capture $shotName ($scenario): expected seats $seats, got '
        '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
  );
  expect(
    controller.seat,
    0,
    reason: 'capture $shotName ($scenario): viewer seat must be 0',
  );
  final TurnStateSnapshot turn = _turnOf(controller);
  expect(
    <Object>[turn.seat, turn.phaseName],
    <Object>[0, 'awaitRoll'],
    reason:
        'capture $shotName ($scenario): expected seat 0 awaiting a roll, got '
        'seat ${turn.seat} in ${turn.phaseName}',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        'capture $shotName ($scenario): expected locale '
        '${locale.languageCode}, got ${loc.localeName}',
  );
}

/// Captures 79 and 80 (order 482, C-478 D5.2). Two seats `[0, 2]`, viewer
/// seat 0, PLAYING, seat 0 awaiting a roll. Taps `game-chat-button` and
/// shoots the open sheet: all twelve chips and the mute switch.
Future<void> _shootChatSheet(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String scenario =
      'room $roomCode, game $gameId, locale '
      '${locale.languageCode}';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: <int>[0, 2],
    );

    final Finder chatButton = find.byKey(const Key('game-chat-button'));
    expect(
      chatButton,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-478 D5.1, game-chat-button must '
          'be in the header while PLAYING and seated',
    );
    expect(
      find.byKey(const Key('quick-chat-sheet')),
      findsNothing,
      reason:
          'capture $shotName ($scenario): the sheet must be closed before '
          'the tap',
    );
    await tester.tap(chatButton);
    await tester.pump();
    await _pumpRealDurationFrames(tester, frameCount: 12);

    final Map<String, String> lines = locale.languageCode == 'ar'
        ? _chatLinesAr
        : _chatLinesEn;
    expect(
      find.byKey(const Key('quick-chat-sheet')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-478 D5.2, tapping '
          'game-chat-button must open quick-chat-sheet',
    );
    for (final String id in _chatIds) {
      final Finder chip = find.byKey(Key('quick-chat-$id'));
      expect(
        chip,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): C-478 D5.2, the sheet must hold '
            'the chip quick-chat-$id',
      );
      expect(
        find.descendant(of: chip, matching: find.text(lines[id]!)),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): C-478 D3, quick-chat-$id must '
            'read "${lines[id]}"',
      );
    }
    expect(
      find.byKey(const Key('quick-chat-mute')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-478 D5.2, the sheet must hold '
          'the quick-chat-mute switch',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Every widget keyed with a `ValueKey<String>` that starts with [prefix].
Finder _keysStartingWith(String prefix) => find.byWidgetPredicate((Widget w) {
  final Key? key = w.key;
  return key is ValueKey<String> && key.value.startsWith(prefix);
});

/// Asserts the one quick-message line C-500 D1 allows is up: only
/// `end-card-chat-<seat>` of [seats] is on screen, inside the header layer
/// `end-card-chat-lines`, and it shows [line] (C-500 D5 may drop the name, so
/// the name is not asserted). No `chat-bubble-*` or `board-chat-*` key exists
/// anywhere (C-500 D6), and the bubble's rect intersects none of the leave
/// button, the chat button, the sound toggle, the board and the turn
/// banner (C-500 D4, P3). Plain rect intersection, edges that only touch do
/// not count. Returns the bubble's rect.
Rect _expectHeaderChat(
  WidgetTester tester, {
  required int seat,
  required List<int> seats,
  required String line,
  required String shotName,
  required String scenario,
}) {
  final Finder layer = find.byKey(const Key('end-card-chat-lines'));
  expect(
    layer,
    findsOneWidget,
    reason:
        'capture $shotName ($scenario): C-500 D7, the header layer '
        'end-card-chat-lines must be on screen',
  );
  final Finder bubble = find.byKey(Key('end-card-chat-$seat'));
  expect(
    bubble,
    findsOneWidget,
    reason:
        'capture $shotName ($scenario): C-500 D1, the newest line, from '
        'seat $seat, must show end-card-chat-$seat',
  );
  expect(
    find.descendant(of: layer, matching: bubble),
    findsOneWidget,
    reason:
        'capture $shotName ($scenario): C-500 D7, end-card-chat-$seat must '
        'sit inside end-card-chat-lines',
  );
  for (final int other in seats) {
    if (other == seat) {
      continue;
    }
    expect(
      find.byKey(Key('end-card-chat-$other')),
      findsNothing,
      reason:
          'capture $shotName ($scenario): C-500 D1, the newest line is '
          "seat $seat's, so end-card-chat-$other must not be on screen",
    );
  }
  final String shown = _plainTextUnder(tester, bubble);
  expect(
    shown.contains(line),
    isTrue,
    reason:
        'capture $shotName ($scenario): C-478 D3, end-card-chat-$seat must '
        'read "$line", got "$shown"',
  );
  for (final String prefix in const <String>['chat-bubble-', 'board-chat-']) {
    expect(
      _keysStartingWith(prefix),
      findsNothing,
      reason:
          'capture $shotName ($scenario): C-500 D6, no key starting '
          '"$prefix" may exist, the board holds no chat layer',
    );
  }

  final Rect rect = tester.getRect(bubble);
  for (final String keyName in const <String>[
    'game-screen-appbar-leave',
    'game-chat-button',
    'game-sound-toggle',
    'ludo-board',
    'game-screen-turn-banner',
  ]) {
    final Finder other = find.byKey(Key(keyName));
    expect(
      other,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-500 D4, $keyName must be on '
          'screen to be measured against end-card-chat-$seat',
    );
    final Rect otherRect = tester.getRect(other);
    expect(
      rect.overlaps(otherRect),
      isFalse,
      reason:
          'capture $shotName ($scenario): C-500 D4, end-card-chat-$seat '
          '($rect) must not intersect $keyName ($otherRect)',
    );
  }
  return rect;
}

/// Captures 81 and 82 (order 482, C-478 D5.4, re-pointed by order 504 to
/// C-500). Four seats `[0, 1, 2, 3]`, viewer seat 0, PLAYING. Three `emote`
/// pushes land with no `re`: seat 2 `revenge`, seat 1 `ha_ha`, seat 0
/// `good_luck`. The shot is taken 400 ms after the last push, inside the
/// 2500 ms bubble life. One line is up, the newest (seat 0's), in the header
/// band, and it covers nothing the player needs.
Future<void> _shootChatBubbles(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String scenario =
      'room $roomCode, game $gameId, locale '
      '${locale.languageCode}';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openFourSeatHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: <int>[0, 1, 2, 3],
    );
    for (final int seat in <int>[0, 1, 2, 3]) {
      expect(
        find.byKey(Key('end-card-chat-$seat')),
        findsNothing,
        reason:
            'capture $shotName ($scenario): no line may be up before the '
            'emote pushes, but end-card-chat-$seat is',
      );
    }

    // C-596 D1: a line up for less than the dwell is not replaced, so each
    // line has its dwell before the next one is pushed and the newest is up
    // when the shot is taken.
    await _pushEmote(tester, opened.transport, seat: 2, emote: 'revenge');
    await _letChatLineDwell(tester);
    await _pushEmote(tester, opened.transport, seat: 1, emote: 'ha_ha');
    await _letChatLineDwell(tester);
    await _pushEmote(tester, opened.transport, seat: 0, emote: 'good_luck');
    await tester.pump(_chatShotPump);

    final Map<String, String> lines = locale.languageCode == 'ar'
        ? _chatLinesAr
        : _chatLinesEn;
    _expectHeaderChat(
      tester,
      seat: 0,
      seats: <int>[0, 1, 2, 3],
      line: lines['good_luck']!,
      shotName: shotName,
      scenario: scenario,
    );

    await _capture(binding, tester, shotName, frames: 12);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Capture 83 (order 482, C-478 D5.4, re-pointed by order 504 to C-500). Two
/// seats `[0, 2]`, viewer seat 0, Arabic, system text scale 2.0 the way
/// captures 37-40 set it. Seat 2 sends `your_move`, seat 0 sends `coming`;
/// the shot is taken 400 ms after the last push, with seat 0's line the only
/// one up.
Future<void> _shootChatBubblesLarge(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.textScaleFactorTestValue = 2.0;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final String scenario =
      'room $roomCode, game $gameId, locale '
      '${locale.languageCode}, text scale 2.0';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: <int>[0, 2],
    );
    final Finder banner = find.byKey(const Key('game-screen-turn-banner'));
    expect(
      banner,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): game-screen-turn-banner must be '
          'on screen',
    );
    final double scaledTen = MediaQuery.textScalerOf(tester.element(banner))
        .scale(10);
    expect(
      scaledTen,
      20.0,
      reason:
          'capture $shotName ($scenario): expected MediaQuery.textScalerOf '
          'at game-screen-turn-banner to scale 10 to 20.0, got $scaledTen',
    );

    // C-596 D1: seat 2's line has its dwell before seat 0's is pushed.
    await _pushEmote(tester, opened.transport, seat: 2, emote: 'your_move');
    await _letChatLineDwell(tester);
    await _pushEmote(tester, opened.transport, seat: 0, emote: 'coming');
    await tester.pump(_chatShotPump);

    final Rect bubble = _expectHeaderChat(
      tester,
      seat: 0,
      seats: <int>[0, 2],
      line: _chatLinesAr['coming']!,
      shotName: shotName,
      scenario: scenario,
    );
    // C-596 D4: the bubble's text is clamped at 1.3, so at 2.0 it still lies
    // inside the 48 dp header row.
    _expectChatInsideHeaderRow(
      tester,
      bubble,
      seat: 0,
      shotName: shotName,
      scenario: scenario,
    );

    await _capture(binding, tester, shotName, frames: 12);
  } finally {
    await _releaseTrayGame(tester, controller);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

// ============================================================================
// Order 489 (captures 84-87): the end card's replies and lines (C-485 D5.1,
// D5.2, D7), re-pointed by order 497 to C-492 (one line, the newest, in the
// header band) and extended with capture 88; captures 89 and 90 are C-495's
// short clock ring.
// ============================================================================

/// Every `Text` and `RichText` under [root] flattened to one string, so a
/// bubble that paints its name and its line as two spans reads as one.
String _plainTextUnder(WidgetTester tester, Finder root) {
  final StringBuffer out = StringBuffer();
  for (final Element element
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    out.write((element.widget as RichText).text.toPlainText());
  }
  return out.toString();
}

/// Logical width under which a surface counts as a phone for the pinned
/// name drop in [_expectEndCardChat] (the Material compact breakpoint).
const double _kPhoneWidth = 600;

/// Asserts `end-card-chat-<seat>` is on screen and obeys C-500 D5: it shows
/// [line] whole on one line (no ellipsis), it shows [name] before it exactly
/// when "name: line" fits one line in the bubble's own text width, and its
/// live region label is `chatSaid(name, line)` either way. The fit is decided
/// from the painted text, not from a per-capture expectation: the bubble's
/// plain text either starts with the name or is the line alone, and when the
/// name was dropped the same two strings are laid out again here, in the
/// bubble's own style, text scale and width, to prove they really do not fit.
/// The width is the bubble's max width less the chrome the bubble measures for
/// itself (its own size minus its text's). The replay uses the line's weight
/// for the name, the narrowest the name can be, so a drop is only accepted when
/// even that does not fit. With [expectNameDroppedOnPhone] set the answer is also
/// pinned, but only on a phone-wide surface (logical width under [_kPhoneWidth]):
/// capture 87, text scale 2.0 in Arabic, keeps the name at 360 dp (C-596 D4
/// lays the bubble out at 1.3, so "name: line" fits the 224 dp), while the
/// headless tester's wider default surface can hold "name: line" in the 320 dp
/// cap, and there the consistency checks above are the whole assertion.
/// Returns true when the name is shown.
bool _expectEndCardChat(
  WidgetTester tester, {
  required int seat,
  required String name,
  required String line,
  required String shotName,
  required String scenario,
  bool? expectNameDroppedOnPhone,
}) {
  final Finder bubble = find.byKey(Key('end-card-chat-$seat'));
  expect(
    bubble,
    findsOneWidget,
    reason:
        'capture $shotName ($scenario): C-492 D2, the newest emote, from '
        'seat $seat, in FINISHED must show end-card-chat-$seat',
  );
  final String shown = _plainTextUnder(tester, bubble);
  final bool nameShown = shown.startsWith(name);
  expect(
    shown,
    nameShown ? '$name: $line' : line,
    reason:
        'capture $shotName ($scenario): C-500 D5, end-card-chat-$seat must '
        'read the line "$line" whole, with or without "$name: " before it, '
        'got "$shown"',
  );

  final Finder paragraph = find.descendant(
    of: bubble,
    matching: find.byType(RichText),
  );
  expect(
    paragraph,
    findsOneWidget,
    reason:
        'capture $shotName ($scenario): C-500 D5, end-card-chat-$seat must '
        'paint one paragraph, found ${paragraph.evaluate().length}',
  );
  final RenderParagraph rendered = tester.renderObject<RenderParagraph>(
    paragraph,
  );
  expect(
    rendered.didExceedMaxLines,
    isFalse,
    reason:
        'capture $shotName ($scenario): C-500 D5, the text of '
        'end-card-chat-$seat must fit its one line with no ellipsis, but '
        '"$shown" overflowed',
  );
  expect(
    rendered.size.height,
    lessThan(2 * rendered.getMinIntrinsicHeight(double.infinity)),
    reason:
        'capture $shotName ($scenario): C-500 D5, end-card-chat-$seat must '
        'be one line, its paragraph is ${rendered.size.height} dp tall',
  );

  final Element element = tester.element(bubble);
  final double maxWidth = tester
      .widget<ConstrainedBox>(
        find
            .descendant(of: bubble, matching: find.byType(ConstrainedBox))
            .first,
      )
      .constraints
      .maxWidth;
  final double chrome = tester.getSize(bubble).width - rendered.size.width;
  final double textWidth = maxWidth - chrome;

  final TextSpan root = rendered.text as TextSpan;
  TextSpan? lineSpan;
  root.visitChildren((InlineSpan span) {
    if (span is TextSpan && span.text == line) {
      lineSpan = span;
    }
    return true;
  });
  expect(
    lineSpan,
    isNotNull,
    reason:
        'capture $shotName ($scenario): C-500 D5, no span of '
        'end-card-chat-$seat carries the line "$line"',
  );
  // The bubble lays its text out at the ambient scale clamped to 1.3 (C-596
  // D4), so the replay does too.
  final TextPainter painter = TextPainter(
    text: TextSpan(
      style: root.style,
      children: <InlineSpan>[
        TextSpan(text: '$name: ', style: lineSpan!.style),
        lineSpan!,
      ],
    ),
    textDirection: Directionality.of(element),
    textScaler: MediaQuery.textScalerOf(element)
        .clamp(maxScaleFactor: _kChatBubbleMaxScale),
    locale: Localizations.maybeLocaleOf(element),
    maxLines: 1,
    ellipsis: '\u2026',
  )..layout(maxWidth: textWidth);
  final bool wouldFit = !painter.didExceedMaxLines;
  painter.text = TextSpan(
    style: root.style,
    children: <InlineSpan>[
      TextSpan(text: '$name: ', style: lineSpan!.style),
      lineSpan!,
    ],
  );
  painter
    ..maxLines = null
    ..ellipsis = null
    ..layout();
  final double wanted = painter.width;
  painter.dispose();
  if (nameShown) {
    expect(
      wouldFit,
      isTrue,
      reason:
          'capture $shotName ($scenario): C-500 D5, the name is shown in '
          'end-card-chat-$seat but "$name: $line" does not fit '
          '$textWidth dp',
    );
  } else {
    expect(
      wouldFit,
      isFalse,
      reason:
          'capture $shotName ($scenario): C-500 D5, the name was dropped '
          'from end-card-chat-$seat but "$name: $line" fits $textWidth dp '
          '(laid out at $wanted dp)',
    );
  }
  final double surfaceWidth =
      tester.view.physicalSize.width / tester.view.devicePixelRatio;
  if (expectNameDroppedOnPhone != null && surfaceWidth < _kPhoneWidth) {
    expect(
      !nameShown,
      expectNameDroppedOnPhone,
      reason:
          'capture $shotName ($scenario): C-500 D5, expected the name to '
          'be ${expectNameDroppedOnPhone ? 'dropped' : 'kept'} in '
          'end-card-chat-$seat on a $surfaceWidth dp wide surface, got '
          '"$shown" in a text width of $textWidth dp',
    );
  }

  final AppLocalizations loc = AppLocalizations.of(element);
  final SemanticsHandle semantics = tester.ensureSemantics();
  try {
    expect(
      tester.getSemantics(bubble).label,
      loc.chatSaid(name, line),
      reason:
          'capture $shotName ($scenario): C-500 D5, the live region label of '
          'end-card-chat-$seat must be chatSaid("$name", "$line") whether or '
          'not the name is drawn',
    );
  } finally {
    semantics.dispose();
  }
  // What this run measured, for the record: the name is shown or dropped by
  // the width of the surface the run has.
  // ignore: avoid_print
  print(
    'capture $shotName ($scenario): end-card-chat-$seat on a $surfaceWidth '
    'dp surface, text width $textWidth dp, "$name: $line" needs $wanted dp, '
    'name '
    '${nameShown ? 'shown' : 'dropped'}',
  );
  return nameShown;
}

/// Asserts the bubble `end-card-chat-<seat>` sits clear of the three things
/// C-492 D1 keeps it off: the winner's title and the header's two buttons.
/// Plain rect intersection (edges that only touch do not count), read after
/// the pop and the layout are done.
void _expectChatClearOfHeader(
  WidgetTester tester, {
  required int seat,
  required String shotName,
  required String scenario,
}) {
  final Rect bubble = tester.getRect(find.byKey(Key('end-card-chat-$seat')));
  for (final String keyName in const <String>[
    'game-screen-winner',
    'game-screen-appbar-leave',
    'game-sound-toggle',
  ]) {
    final Finder other = find.byKey(Key(keyName));
    expect(
      other,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-492 D1, $keyName must be on '
          'screen to be measured against end-card-chat-$seat',
    );
    final Rect otherRect = tester.getRect(other);
    expect(
      bubble.overlaps(otherRect),
      isFalse,
      reason:
          'capture $shotName ($scenario): C-492 D1, end-card-chat-$seat '
          '($bubble) must not intersect $keyName ($otherRect)',
    );
  }
}

/// Captures 84-88 (order 489, C-485 D5.1, D5.2, D7; order 582 for the game).
/// A room walked to FINISHED the way a player meets it: [_replayRealGame]
/// plays the recorded game [gameName] from the home screen as [viewerSeat],
/// then the recorded `game_over` (seat [winnerSeat] wins, which must be the
/// fixture's winner) lands. Room code, game id, seat token and verify URL are
/// the recorded ones. After the end card has settled its four stat tiles are
/// asserted from the fixture's `counts` for [viewerSeat], then the [emotes]
/// land as pushes with no `re`, in order, a C-596 D1 dwell apart, and the shot
/// is taken 400 ms after the last. Before the shot the card's variant, the one
/// line that is up (the newest, C-492 D2, with no bubble of any other seat),
/// its place clear of the title and the header's buttons, the reply chips and
/// the board's tokens (every seat on the recorded `final_tokens`) are
/// asserted. The line is read under C-500 D5 (the name only when it fits);
/// [expectNameDroppedOnPhone] pins that answer for a capture whose text scale
/// forces it. [fourSeats] only names the seats and names the old fixture's
/// players had, which the recorded game must still carry.
Future<void> _shootEndCardChat(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String gameName,
  required int viewerSeat,
  required bool fourSeats,
  required int winnerSeat,
  required List<(int, String)> emotes,
  required List<String> expectedReplies,
  double? textScale,
  bool? expectNameDroppedOnPhone,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  if (textScale == null) {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  } else {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final _RealGame game = _realGame(gameName);
  final String scenario =
      'fixture game "$gameName", viewer seat $viewerSeat, locale '
      '${locale.languageCode}'
      '${textScale == null ? '' : ', text scale $textScale'}, winner seat '
      '$winnerSeat';
  final List<int> seats = fourSeats ? <int>[0, 1, 2, 3] : <int>[0, 2];
  final Map<int, String> names = fourSeats
      ? const <int, String>{0: 'Priya', 1: 'Karim', 2: 'Lina', 3: 'Tariq'}
      : const <int, String>{0: 'Priya', 2: 'Karim'};
  expect(
    <Object?>[
      game.json['seats'],
      game.winner,
      <int, String>{for (final int s in seats) s: game.nameOf(s)},
    ],
    <Object?>[seats, winnerSeat, names],
    reason:
        'capture $shotName ($scenario): the recorded game must seat $seats, '
        'be won by seat $winnerSeat and name its players $names, the names '
        'this capture\'s emote lines were written for',
  );
  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  try {
    await tester.pumpWidget(
      locale.languageCode == 'ar'
          ? _reconnectingCaptureHarness(
              HomeScreen(
                controllerFactory: factory.call,
                onToggleLocale: () {},
              ),
              locale: locale,
            )
          : _ScreenshotHarness(controllerFactory: factory.call),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    final _RealReplay replay = await _replayRealGame(
      tester,
      factory,
      capture: 'capture $shotName',
      gameName: gameName,
      seat: viewerSeat,
      localeName: locale.languageCode,
    );
    final RoomController controller = replay.controller;
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      seats,
      reason:
          'capture $shotName ($scenario): expected seats $seats, got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );

    replay.pushGameOver();
    await tester.pump();
    await tester.pump();
    await _pumpRealDurationFrames(tester);

    expect(
      <Object?>[controller.room?.state, controller.room?.winner],
      <Object?>[RoomState.finished, winnerSeat],
      reason:
          'capture $shotName ($scenario): expected the room FINISHED with '
          'winner $winnerSeat, got ${controller.room?.state} with winner '
          '${controller.room?.winner}',
    );
    expect(
      controller.seat,
      viewerSeat,
      reason: 'capture $shotName ($scenario): viewer seat must be $viewerSeat',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    if (textScale != null) {
      final double scaledTen = MediaQuery.textScalerOf(
        tester.element(find.byType(GameScreen)),
      ).scale(10);
      expect(
        scaledTen,
        10 * textScale,
        reason:
            'capture $shotName ($scenario): expected MediaQuery.textScalerOf '
            'to scale 10 to ${10 * textScale}, got $scaledTen',
      );
    }

    final bool iWon = winnerSeat == viewerSeat;
    expect(
      find.byKey(Key(iWon ? 'end-card-win' : 'end-card-lose')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-243, the card must be the '
          '${iWon ? 'winner' : 'loser'} variant',
    );
    expect(
      find.byKey(Key(iWon ? 'end-card-lose' : 'end-card-win')),
      findsNothing,
      reason:
          'capture $shotName ($scenario): C-243, the card must not also be '
          'the ${iWon ? 'loser' : 'winner'} variant',
    );
    final Finder winnerTitle = find.byKey(const Key('game-screen-winner'));
    expect(
      winnerTitle,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): expected game-screen-winner',
    );
    final Text winnerText = tester.widget<Text>(winnerTitle);
    final String? shownTitle =
        winnerText.data ?? winnerText.textSpan?.toPlainText();
    final String expectedTitle = iWon
        ? loc.endWinTitle
        : loc.endLoseTitle(names[winnerSeat]!);
    expect(
      shownTitle,
      expectedTitle,
      reason:
          'capture $shotName ($scenario): expected the card title '
          '"$expectedTitle", got "$shownTitle"',
    );
    // The four tiles show the fixture's counts for the viewer's seat in the
    // recorded game, read at run time; a count of 0 means the tile is absent
    // (C-533 D3).
    _expectEndCardStatTiles(
      tester,
      rolls: replay.counts.rolls,
      sixes: replay.counts.sixes,
      captures: replay.counts.captures,
      home: replay.counts.home,
      momentDescription:
          'capture $shotName: after the post-game-over settle, before the '
          'emotes (${replay.describe}; ${replay.counts})',
    );

    for (final int seat in seats) {
      expect(
        find.byKey(Key('end-card-chat-$seat')),
        findsNothing,
        reason:
            'capture $shotName ($scenario): C-485 D6.1, no line may be up '
            'before the emote pushes, but end-card-chat-$seat is',
      );
    }
    final Finder replies = find.byKey(const Key('end-card-quick-replies'));
    expect(
      replies,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-485 D5.1, a seated viewer on a '
          'live card must see end-card-quick-replies',
    );

    final Map<String, String> lines = locale.languageCode == 'ar'
        ? _chatLinesAr
        : _chatLinesEn;
    for (int i = 0; i < emotes.length; i++) {
      if (i > 0) {
        // C-596 D1: the line up has its dwell before the next is pushed.
        await _letChatLineDwell(tester);
      }
      await _pushEmote(
        tester,
        replay.transport,
        seat: emotes[i].$1,
        emote: emotes[i].$2,
      );
    }
    await tester.pump(_chatShotPump);

    // C-492 D2: one line at a time, the newest. Every other seat's bubble,
    // the older emotes' included, is gone by now (the replaced line's fade
    // is 250 ms, shorter than the pump above).
    final (int newestSeat, String newestEmote) = emotes.last;
    _expectEndCardChat(
      tester,
      seat: newestSeat,
      name: names[newestSeat]!,
      line: lines[newestEmote]!,
      shotName: shotName,
      scenario: scenario,
      expectNameDroppedOnPhone: expectNameDroppedOnPhone,
    );
    for (final int seat in seats) {
      if (seat == newestSeat) {
        continue;
      }
      expect(
        find.byKey(Key('end-card-chat-$seat')),
        findsNothing,
        reason:
            'capture $shotName ($scenario): C-492 D2, the newest line is '
            "seat $newestSeat's, so end-card-chat-$seat must not be on screen",
      );
    }
    expect(
      find.byKey(const Key('end-card-chat-lines')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-492 D4, the header layer '
          'end-card-chat-lines must be on screen',
    );
    _expectChatClearOfHeader(
      tester,
      seat: newestSeat,
      shotName: shotName,
      scenario: scenario,
    );
    if (textScale != null) {
      // C-596 D4: the bubble's text is clamped at 1.3, so at a large text
      // scale it still lies inside the 48 dp header row.
      _expectChatInsideHeaderRow(
        tester,
        tester.getRect(find.byKey(Key('end-card-chat-$newestSeat'))),
        seat: newestSeat,
        shotName: shotName,
        scenario: scenario,
      );
    }

    final List<String> shownReplies = tester
        .widgetList(
          find.descendant(
            of: replies,
            matching: find.byWidgetPredicate((Widget w) {
              final Key? key = w.key;
              return key is ValueKey<String> &&
                  key.value.startsWith('end-card-reply-');
            }),
          ),
        )
        .map((Widget w) => (w.key! as ValueKey<String>).value)
        .toList();
    expect(
      shownReplies,
      <String>[for (final String id in expectedReplies) 'end-card-reply-$id'],
      reason:
          'capture $shotName ($scenario): C-485 D5.1, the card must offer '
          'exactly $expectedReplies in order, got $shownReplies',
    );
    for (final String id in expectedReplies) {
      expect(
        find.descendant(
          of: find.byKey(Key('end-card-reply-$id')),
          matching: find.text(lines[id]!),
        ),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): C-478 D3, end-card-reply-$id '
            'must read "${lines[id]}"',
      );
    }

    // The board behind the card is the recorded game's last position: every
    // seat's four tokens are the fixture's `final_tokens`.
    final LudoBoard board = tester.widget<LudoBoard>(
      find.byKey(const Key('game-screen-board')),
    );
    for (final int seat in seats) {
      expect(
        board.tokens[seat],
        game.finalTokens(seat),
        reason:
            'capture $shotName ($scenario): the board must show seat $seat '
            'on the recorded final_tokens ${game.finalTokens(seat)}, it '
            'shows ${board.tokens[seat]}',
      );
    }

    await _capture(binding, tester, shotName, frames: 12);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
    if (textScale != null) {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  }
}

// ============================================================================
// Order 504 (captures 91 and 92): the quick message on a board full of rings
// (C-500 D1, D4).
// ============================================================================

/// Held after seat 2's `emote` lands in captures 91 and 92.
const Duration _chatMySixPump = Duration(milliseconds: 300);

/// Captures 91 and 92 (order 504, C-500). Four seats `[0, 1, 2, 3]`, viewer
/// seat 0, PLAYING. Seat 0 rolls a 6 with legal `[0, 1, 2, 3]` and every
/// token still in its yard, so the turn is `awaitMove` and the board rings
/// four tokens. Seat 2 then sends `revenge` and 300 ms are pumped. Before the
/// shot the four `board-legal-ring-0-*` keys are asserted on screen and none
/// of their rects may intersect the bubble, which is the newest line in the
/// header band and clear of the header's buttons, the board and the turn
/// banner. With [textScale] the system scale is set the way capture 83 sets
/// it.
Future<void> _shootChatMySix(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
  double? textScale,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  if (textScale == null) {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  } else {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}'
      '${textScale == null ? '' : ', text scale $textScale'}';
  const List<int> seats = <int>[0, 1, 2, 3];
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openFourSeatHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: seats,
    );
    if (textScale != null) {
      final double scaledTen = MediaQuery.textScalerOf(
        tester.element(find.byType(GameScreen)),
      ).scale(10);
      expect(
        scaledTen,
        10 * textScale,
        reason:
            'capture $shotName ($scenario): expected MediaQuery.textScalerOf '
            'to scale 10 to ${10 * textScale}, got $scaledTen',
      );
    }

    final int seq = await _pushTraySeq(
      tester,
      opened.transport,
      opened.seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[0, 1, 2, 3],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
      },
    );
    await _pumpRealDurationFrames(tester, frameCount: _trayShotFrames);

    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName ($scenario): a pushed frame was dropped; room '
          'seq is ${controller.room!.seq}, last push was $seq',
    );
    expect(
      <Object>[turn.seat, turn.phaseName],
      <Object>[0, 'awaitMove'],
      reason:
          'capture $shotName ($scenario): expected seat 0 in awaitMove '
          'after rolling 6, got seat ${turn.seat} in ${turn.phaseName}',
    );
    expect(
      <int>[
        for (int token = 0; token < 4; token++)
          _progressOf(controller, 0, token),
      ],
      <int>[-1, -1, -1, -1],
      reason:
          'capture $shotName ($scenario): all four of seat 0\'s tokens must '
          'be in the yard',
    );
    for (final int token in <int>[0, 1, 2, 3]) {
      expect(
        find.byKey(Key('board-legal-ring-0-$token')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): the 6 must ring yard token '
            '$token before the line arrives',
      );
    }
    for (final int seat in seats) {
      expect(
        find.byKey(Key('end-card-chat-$seat')),
        findsNothing,
        reason:
            'capture $shotName ($scenario): no line may be up before the '
            'emote push, but end-card-chat-$seat is',
      );
    }

    await _pushEmote(tester, opened.transport, seat: 2, emote: 'revenge');
    await tester.pump(_chatMySixPump);

    final Map<String, String> lines = locale.languageCode == 'ar'
        ? _chatLinesAr
        : _chatLinesEn;
    final Rect bubble = _expectHeaderChat(
      tester,
      seat: 2,
      seats: seats,
      line: lines['revenge']!,
      shotName: shotName,
      scenario: scenario,
    );

    final Finder rings = _keysStartingWith('board-legal-ring-');
    expect(
      rings,
      findsNWidgets(4),
      reason:
          'capture $shotName ($scenario): expected four board-legal-ring-* '
          'keys on screen with the line up, found ${rings.evaluate().length}',
    );
    for (final Element ring in rings.evaluate()) {
      final Rect ringRect = tester.getRect(find.byWidget(ring.widget));
      expect(
        bubble.overlaps(ringRect),
        isFalse,
        reason:
            'capture $shotName ($scenario): C-500 D1, end-card-chat-2 '
            '($bubble) must not intersect ${ring.widget.key} ($ringRect)',
      );
    }

    await _capture(binding, tester, shotName, frames: 12);
  } finally {
    await _releaseTrayGame(tester, controller);
    if (textScale != null) {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  }
}

// ============================================================================
// Order 497 (captures 89 and 90): the countdown ring on a short clock
// (C-495 D3).
// ============================================================================

/// Captures 89 and 90 (order 497, C-495 D3). Two seats `[0, 2]`, viewer seat
/// 0, PLAYING, seat 2 on turn in `await_roll`. The room reaches PLAYING the
/// way 79-83 reach theirs, then an unsolicited `room` push carries the turn
/// of an away seat: `segment_ms` 10000 and `deadline_ms` 10000. Real time is
/// pumped, frame by frame and bounded, until the digits read [secondsLeft];
/// then the digits, the ring's fraction and its colour are asserted and the
/// shot is taken. At 8 s left the ring is 0.8 full in the seat's colour; at
/// 2 s left it is 0.2 full and `LudoColors.error`.
Future<void> _shootAwayRing(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int secondsLeft,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  const int segmentMs = 10000;
  final bool expectRed = secondsLeft <= 3;
  final double expectedFraction = secondsLeft / (segmentMs ~/ 1000);
  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}, '
      'segment ${segmentMs}ms, target $secondsLeft s left';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;

    opened.transport.pushText(
      _frame(
        type: 'room',
        data: _roomJson(
          code: roomCode,
          state: 'PLAYING',
          hostSeat: 0,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya'),
            _seatJson(2, name: 'Karim', connected: false),
          ],
          turn: const <String, Object?>{
            'seat': 2,
            'phase': 'await_roll',
            'deadline_ms': segmentMs,
            'segment_ms': segmentMs,
            'k': 0,
          },
          gameId: gameId,
          clientSeeds: '0:seed',
          seq: opened.seq + 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.room!.seq,
      opened.seq + 1,
      reason:
          'capture $shotName ($scenario): expected room seq '
          '${opened.seq + 1} after the snapshot push, got '
          '${controller.room!.seq}',
    );
    expect(
      controller.room!.state,
      RoomState.playing,
      reason:
          'capture $shotName ($scenario): the room must be PLAYING, got '
          '${controller.room!.state}',
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.seat).toList(),
      <int>[0, 2],
      reason:
          'capture $shotName ($scenario): expected seats [0, 2], got '
          '${controller.room!.seats.map((SeatState s) => s.seat).toList()}',
    );
    expect(
      controller.seat,
      0,
      reason: 'capture $shotName ($scenario): viewer seat must be 0',
    );
    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      <Object>[turn.seat, turn.phaseName],
      <Object>[2, 'awaitRoll'],
      reason:
          'capture $shotName ($scenario): expected seat 2 awaiting a roll, '
          'got seat ${turn.seat} in ${turn.phaseName}',
    );
    expect(
      <Object?>[
        controller.room!.turn!.segmentMs,
        controller.room!.turn!.deadlineMs,
      ],
      <Object?>[segmentMs, segmentMs],
      reason:
          'capture $shotName ($scenario): C-495 D1, expected the turn to '
          'carry segment_ms $segmentMs and deadline_ms $segmentMs, got '
          'segmentMs ${controller.room!.turn!.segmentMs}, deadlineMs '
          '${controller.room!.turn!.deadlineMs}',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );

    // Only a disconnected seat is ever on a 10 s clock (PROTOCOL.md section
    // 26), so the screen must be showing its offline notice.
    expect(
      find.byKey(const Key('game-screen-turn-seat-offline')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): seat 2 is on turn and disconnected, '
          'so game-screen-turn-seat-offline must be on screen',
    );
    final Finder digits = find.byKey(const Key('game-screen-turn-countdown'));
    final Finder ring = find.byKey(const Key('game-header-countdown-ring'));
    expect(
      digits,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): expected the countdown digits',
    );
    expect(
      ring,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): expected the countdown ring',
    );

    String shownDigits() {
      final Text text = tester.widget<Text>(digits);
      return text.data ?? text.textSpan?.toPlainText() ?? '';
    }

    // The ring starts full on a fresh 10 s segment: against the 45 s turn
    // length it would open at 10/45, which is the glitch C-495 removes.
    final String openingDigits = shownDigits();
    expect(
      openingDigits,
      loc.gameTurnCountdownDigits(segmentMs ~/ 1000),
      reason:
          'capture $shotName ($scenario): expected the countdown to open at '
          '${segmentMs ~/ 1000}, got "$openingDigits"',
    );
    final dynamic openingRing = tester.widget(ring);
    expect(
      openingRing.remainingFraction as double,
      closeTo(1.0, 1e-9),
      reason:
          'capture $shotName ($scenario): C-495 D3, a fresh ${segmentMs}ms '
          'segment must draw the ring full, got '
          '${openingRing.remainingFraction}',
    );

    // Real time, frame by frame, until the digits read the target. Bounded:
    // the segment's own length plus a margin, so a timer that never ticks
    // fails with what it last showed instead of hanging the job.
    final String targetDigits = loc.gameTurnCountdownDigits(secondsLeft);
    final Stopwatch waited = Stopwatch()..start();
    final Duration limit = Duration(milliseconds: segmentMs + 5000);
    while (shownDigits() != targetDigits && waited.elapsed < limit) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      shownDigits(),
      targetDigits,
      reason:
          'capture $shotName ($scenario): expected the countdown digits to '
          'read "$targetDigits" within ${limit.inSeconds} s, last read '
          '"${shownDigits()}" after ${waited.elapsedMilliseconds} ms',
    );

    final dynamic shownRing = tester.widget(ring);
    final double fraction = shownRing.remainingFraction as double;
    final Color color = shownRing.color as Color;
    expect(
      fraction,
      closeTo(expectedFraction, 1e-9),
      reason:
          'capture $shotName ($scenario): C-495 D3, at $secondsLeft s left '
          'of a ${segmentMs}ms segment the ring fraction must be '
          '$expectedFraction, got $fraction',
    );
    if (expectRed) {
      expect(
        color,
        LudoColors.error,
        reason:
            'capture $shotName ($scenario): C-495 D3, at $secondsLeft s '
            'left of a ${segmentMs}ms segment the ring must be '
            'LudoColors.error, got $color',
      );
    } else {
      expect(
        color,
        isNot(LudoColors.error),
        reason:
            'capture $shotName ($scenario): C-495 D3, at $secondsLeft s '
            'left of a ${segmentMs}ms segment the ring must keep the '
            "seat's colour, got LudoColors.error",
      );
    }

    await _capture(binding, tester, shotName, frames: 6);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// ============================================================================
// Order 520 (captures 95-98): a resting control says for how long, and a
// refused tap is felt with animations off (C-520 D2, D3).
// ============================================================================

const Key _chatRestRingKey = Key('game-chat-rest-ring');

/// Every `RefusalMark` on screen. Found by type name so this file compiles on
/// a tree that does not have lib/src/refusal_mark.dart yet; the captures then
/// fail on their own assertions instead of breaking every other capture here.
Finder _refusalMarks() => find.byWidgetPredicate(
  (Widget w) => w.runtimeType.toString() == 'RefusalMark',
);

/// Captures 95 and 96 (order 520, C-520 D2). Two seats `[0, 2]`, viewer seat
/// 0, PLAYING. Taps `game-chat-button`, picks `hi`, and has the server's copy
/// of the message come back (an `emote` carrying `re`, which is what
/// acknowledges the send). The shot is taken 992 ms after that copy: the
/// button rests at 38 % and `game-chat-rest-ring` is on screen, about a third
/// drained.
Future<void> _shootChatResting(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String scenario =
      'room $roomCode, game $gameId, locale '
      '${locale.languageCode}';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: <int>[0, 2],
    );
    expect(
      find.byKey(_chatRestRingKey),
      findsNothing,
      reason:
          'capture $shotName ($scenario): C-520 D2, no ring while the '
          'button is ready',
    );

    final int sentBefore = opened.transport.sentRaw.length;
    await tester.tap(find.byKey(const Key('game-chat-button')));
    await tester.pump();
    await _pumpRealDurationFrames(tester, frameCount: 12);
    expect(
      find.byKey(const Key('quick-chat-sheet')),
      findsOneWidget,
      reason: 'capture $shotName ($scenario): the sheet must be open to pick',
    );
    await tester.tap(find.byKey(const Key('quick-chat-hi')));
    await tester.pump();
    await _pumpRealDurationFrames(tester, frameCount: 12);

    final List<String> emotes = opened.transport.sentRaw
        .skip(sentBefore)
        .where((String s) => _typeOf(s) == 'emote')
        .toList();
    expect(
      emotes,
      hasLength(1),
      reason:
          'capture $shotName ($scenario): picking hi must send one emote, '
          'sent ${opened.transport.sentRaw.skip(sentBefore).map(_typeOf).toList()}',
    );
    opened.transport.pushText(
      _frame(
        type: 'emote',
        re: _idOf(emotes.single),
        data: <String, Object?>{'seat': 0, 'emote': 'hi'},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(_chatRestRingKey),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-520 D2, the server copy '
          'acknowledged the send, so game-chat-rest-ring must be on screen',
    );

    // 31 frames of 32 ms: 992 ms after the copy, the ring part drained.
    await _pumpRealDurationFrames(tester, frameCount: 31);
    expect(
      find.byKey(_chatRestRingKey),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-520 D2, the rest lasts 3000 ms, '
          'so the ring must still be on screen at 992 ms',
    );
    expect(
      find.byKey(const Key('quick-chat-sheet')),
      findsNothing,
      reason: 'capture $shotName ($scenario): the sheet closed after the pick',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Captures 97 and 98 (order 520, C-520 D3). Animations off, the way Android's
/// "remove animations" reaches `MediaQuery.disableAnimationsOf`. Two seats
/// `[0, 2]`, viewer seat 0, PLAYING. With [refuseDie] false seat 0 rolls a 6
/// with legal `[0, 1]`, every token in its yard, and the tap goes to token 2
/// (`board-token-hit-0-2`), which has no legal move. With [refuseDie] true the
/// turn passes to seat 2 awaiting a roll and the tap goes to `game-die`. The
/// shot is taken 96 ms after the tap, inside the 300 ms: exactly one
/// RefusalMark is on screen and its rect contains the tapped object's centre.
Future<void> _shootRefusalReduced(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
  required bool refuseDie,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  final String scenario =
      'room $roomCode, game $gameId, locale '
      '${locale.languageCode}, animations off';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: <int>[0, 2],
    );
    expect(
      MediaQuery.disableAnimationsOf(tester.element(find.byType(GameScreen))),
      isTrue,
      reason:
          'capture $shotName ($scenario): the screen must read '
          'disableAnimations as true',
    );

    final Finder target;
    if (refuseDie) {
      final int seq = await _pushTraySeq(
        tester,
        opened.transport,
        opened.seq,
        type: 'turn',
        data: <String, Object?>{
          'seat': 2,
          'phase': 'await_roll',
          'deadline_ms': _trayDeadlineMs,
          'queue': <int>[],
        },
      );
      await _pumpRealDurationFrames(tester, frameCount: 4);
      final TurnStateSnapshot turn = _turnOf(controller);
      expect(
        controller.room!.seq,
        seq,
        reason:
            'capture $shotName ($scenario): a pushed frame was dropped; room '
            'seq is ${controller.room!.seq}, last push was $seq',
      );
      expect(
        <Object>[turn.seat, turn.phaseName],
        <Object>[2, 'awaitRoll'],
        reason:
            'capture $shotName ($scenario): expected seat 2 awaiting a roll '
            'so the die is not mine, got seat ${turn.seat} in '
            '${turn.phaseName}',
      );
      target = find.byKey(const Key('game-die'));
    } else {
      final int seq = await _pushTraySeq(
        tester,
        opened.transport,
        opened.seq,
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 6,
          'legal': <int>[0, 1],
          'deadline_ms': _trayDeadlineMs,
          'k': 1,
          'reveal': _trayReveal,
        },
      );
      await _pumpRealDurationFrames(tester, frameCount: 4);
      final TurnStateSnapshot turn = _turnOf(controller);
      expect(
        controller.room!.seq,
        seq,
        reason:
            'capture $shotName ($scenario): a pushed frame was dropped; room '
            'seq is ${controller.room!.seq}, last push was $seq',
      );
      expect(
        <Object>[turn.seat, turn.phaseName],
        <Object>[0, 'awaitMove'],
        reason:
            'capture $shotName ($scenario): expected seat 0 in awaitMove '
            'after rolling 6, got seat ${turn.seat} in ${turn.phaseName}',
      );
      for (final int token in <int>[0, 1]) {
        expect(
          find.byKey(Key('board-legal-ring-0-$token')),
          findsOneWidget,
          reason:
              'capture $shotName ($scenario): token $token must carry a '
              'legal ring',
        );
      }
      for (final int token in <int>[2, 3]) {
        expect(
          find.byKey(Key('board-legal-ring-0-$token')),
          findsNothing,
          reason:
              'capture $shotName ($scenario): token $token has no legal '
              'move and must carry no ring',
        );
      }
      target = find.byKey(const Key('board-token-hit-0-2'));
    }
    expect(
      target,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): the refused object is on screen',
    );
    expect(
      _refusalMarks(),
      findsNothing,
      reason: 'capture $shotName ($scenario): no mark before the tap',
    );

    final Offset centre = tester.getCenter(target);
    await tester.tap(target, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 96));

    expect(
      _refusalMarks(),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-520 D3, exactly one RefusalMark '
          '96 ms after a refused tap with animations off',
    );
    final Rect mark = tester.getRect(_refusalMarks());
    expect(
      mark.contains(centre),
      isTrue,
      reason:
          'capture $shotName ($scenario): C-520 D3, the mark $mark must '
          'cover the tapped object, whose centre is $centre',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
  }
}

// --- order 526: the plain home and the one sound switch (C-523) -------------

const String _plainTaglineEn =
    'Every roll can be checked: independent random rolls, open source code.';
const String _plainTaglineAr =
    'كل رمية يمكن التحقق منها: رميات عشوائية مستقلة وكود مفتوح المصدر.';
const String _playersQuestionEn = 'How many players?';
const String _playersQuestionAr = 'كم لاعب؟';

/// Keys C-523 removes from home (D1, D2, D7). None may be in the tree in any
/// plain-home capture, offstage included.
const List<String> _removedHomeKeys = <String>[
  'home-players-disclosure',
  'home-players-selector',
  'home-rule-capture-bonus',
  'home-house-rules',
  'home-settings-button',
  'feedback-settings-sheet',
  'feedback-settings-haptics',
  'feedback-settings-sound',
];

/// The icons D2 lets stand for "a check glyph" on the selected option; the
/// contract names the role, not the IconData.
const List<IconData> _menuCheckIcons = <IconData>[
  Icons.check,
  Icons.check_rounded,
  Icons.check_circle,
  Icons.check_circle_rounded,
  Icons.check_circle_outline,
  Icons.check_circle_outline_rounded,
  Icons.done,
  Icons.done_rounded,
];

/// Records what the game asked the feedback service to play, so a capture
/// can say what a tap on the sound toggle did and did not play.
class _CueLog implements FeedbackService {
  final List<FeedbackCue> played = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    played.add(cue);
  }
}

/// Home mounted directly in [locale], clean store, no seat record, system
/// text scale 1.0 or [textScale]. Home only, so the trailing pumpAndSettle
/// in _settleForScreenshot is safe (no LobbyScreen ticker exists yet).
Future<void> _mountPlainHome(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  double? textScale,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  if (textScale != null) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(HomeScreen)),
  );
  await _settleForScreenshot(
    tester,
    find.text(loc.homeCreateRoomButton),
    'capture $shotName: the ${locale.languageCode} Create Room button label '
    '("${loc.homeCreateRoomButton}") laid out on the home screen',
  );
  expect(
    find.byKey(const Key('home-rejoin-button')),
    findsNothing,
    reason:
        'capture $shotName: expected no home-rejoin-button on a home '
        'mounted after clearing SharedPreferences; found one, so a seat '
        'record survived the clear',
  );
}

void _expectAtLeast48(WidgetTester tester, Finder finder, String label) {
  final Size size = tester.getSize(finder);
  expect(
    size.width,
    greaterThanOrEqualTo(48.0),
    reason:
        '$label must be at least 48 dp wide (C-523 D2/D7), is ${size.width}',
  );
  expect(
    size.height,
    greaterThanOrEqualTo(48.0),
    reason:
        '$label must be at least 48 dp high (C-523 D2/D7), is ${size.height}',
  );
}

/// What a plain home says in every capture 99-104: no removed key, the one
/// painted "players" being the row's label (en), the D5 tagline, the
/// players control showing 4 by default at 48 x 48 or more, the sound
/// toggle showing the speaker on at 48 x 48 or more, and Join only when
/// [joinShown].
void _expectPlainHome(
  WidgetTester tester, {
  required String shotName,
  required Locale locale,
  bool joinShown = false,
}) {
  final bool en = locale.languageCode == 'en';
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(HomeScreen)),
  );

  for (final String key in _removedHomeKeys) {
    expect(
      find.byKey(Key(key), skipOffstage: false),
      findsNothing,
      reason:
          'capture $shotName: C-523 removes the key "$key" from home; it is '
          'still in the tree',
    );
  }

  final String question = en ? _playersQuestionEn : _playersQuestionAr;
  expect(
    loc.homePlayersQuestion,
    question,
    reason:
        'capture $shotName: C-523 D9 homePlayersQuestion for '
        '${locale.languageCode} is "$question", the arb says '
        '"${loc.homePlayersQuestion}"',
  );
  expect(
    find.text(question, skipOffstage: false),
    findsOneWidget,
    reason:
        'capture $shotName: expected the row label "$question" painted '
        'exactly once on home (C-523 D2, A1)',
  );
  if (en) {
    expect(
      find.textContaining('players', skipOffstage: false),
      findsOneWidget,
      reason:
          'capture $shotName: C-523 D2/A1, the only painted "players" on '
          'home is the row label "$question"; found '
          '${find.textContaining('players', skipOffstage: false).evaluate().length}',
    );
  } else {
    for (final String word in const <String>['لاعبين', 'لاعبان']) {
      expect(
        find.textContaining(word, skipOffstage: false),
        findsNothing,
        reason:
            'capture $shotName: C-523 D2, "$word" is not painted anywhere '
            'on home',
      );
    }
  }
  expect(
    find.text(en ? _plainTaglineEn : _plainTaglineAr, skipOffstage: false),
    findsOneWidget,
    reason:
        'capture $shotName: expected the D5 tagline '
        '"${en ? _plainTaglineEn : _plainTaglineAr}" on home',
  );

  final Finder players = find.byKey(
    const Key('home-players-button'),
    skipOffstage: false,
  );
  expect(
    players,
    findsOneWidget,
    reason: 'capture $shotName: expected home-players-button on home (D2)',
  );
  _expectAtLeast48(tester, players, 'capture $shotName: home-players-button');
  final List<String> shown = tester
      .widgetList<Text>(
        find.descendant(
          of: players,
          matching: find.byType(Text, skipOffstage: false),
        ),
      )
      .map((Text t) => (t.data ?? t.textSpan?.toPlainText() ?? '').trim())
      .toList();
  expect(
    shown.any(const <String>['4', '٤'].contains),
    isTrue,
    reason:
        'capture $shotName: C-523 D2, home-players-button reads 4 by '
        'default; the Text under it read $shown',
  );

  final Finder sound = find.byKey(
    const Key('home-sound-toggle'),
    skipOffstage: false,
  );
  expect(
    sound,
    findsOneWidget,
    reason: 'capture $shotName: expected home-sound-toggle on home (D7)',
  );
  _expectAtLeast48(tester, sound, 'capture $shotName: home-sound-toggle');
  expect(
    find.descendant(
      of: sound,
      matching: find.byIcon(Icons.volume_up_rounded, skipOffstage: false),
    ),
    findsOneWidget,
    reason:
        'capture $shotName: a fresh store is not muted, so home-sound-toggle '
        'shows Icons.volume_up_rounded (D7, D8)',
  );

  expect(
    find.byKey(const Key('join-room-button'), skipOffstage: false),
    joinShown ? findsOneWidget : findsNothing,
    reason:
        'capture $shotName: C-523 D3, join-room-button is in the tree only '
        'with a full-length code in the field; expected it '
        '${joinShown ? 'present' : 'absent'}',
  );
}

/// 99, 100: default state, the list at its top.
Future<void> _shootHomePlain(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
}) async {
  await _mountPlainHome(tester, binding, shotName: shotName, locale: locale);

  final ScrollableState? scroll = Scrollable.maybeOf(
    tester.element(find.byKey(const Key('home-name-field'))),
  );
  expect(
    scroll,
    isNotNull,
    reason:
        'capture $shotName: expected home-name-field inside the home scroll '
        'view',
  );
  expect(
    scroll!.position.pixels,
    0.0,
    reason:
        'capture $shotName: expected the home list at its top, it sits at '
        '${scroll.position.pixels}',
  );

  _expectPlainHome(tester, shotName: shotName, locale: locale);
  for (final (String key, String label) in const <(String, String)>[
    ('home-players-button', 'home-players-button'),
    ('home-sound-toggle', 'home-sound-toggle'),
    ('create-room-button', 'create-room-button'),
  ]) {
    _expectRectInsideView(
      tester,
      find.byKey(Key(key)),
      label: label,
      context: 'on the plain home before capture $shotName',
    );
  }
  await _capture(binding, tester, shotName, frames: 0);
}

/// 101, 102: the players menu open over home-players-button, 4 selected.
Future<void> _shootHomePlayersMenu(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
}) async {
  await _mountPlainHome(tester, binding, shotName: shotName, locale: locale);

  await tester.tap(find.byKey(const Key('home-players-button')));
  await tester.pump();
  for (final int n in const <int>[2, 3, 4]) {
    await _pumpUntilFound(
      tester,
      find.byKey(Key('home-players-option-$n')),
      'capture $shotName: home-players-option-$n after a tap on '
      'home-players-button',
    );
  }
  await _settleForScreenshot(
    tester,
    find.byKey(const Key('home-players-option-4')),
    'capture $shotName: home-players-option-4 laid out in the open menu',
  );

  _expectPlainHome(tester, shotName: shotName, locale: locale);
  for (final int n in const <int>[2, 3, 4]) {
    final Finder option = find.byKey(Key('home-players-option-$n'));
    expect(
      option,
      findsOneWidget,
      reason:
          'capture $shotName: expected home-players-option-$n in the open '
          'menu (C-523 D2)',
    );
    _expectRectInsideView(
      tester,
      option,
      label: 'home-players-option-$n',
      context: 'in the open players menu before capture $shotName',
    );
    final Finder check = find.descendant(
      of: option,
      matching: find.byWidgetPredicate(
        (Widget w) => w is Icon && _menuCheckIcons.contains(w.icon),
      ),
    );
    expect(
      check,
      n == 4 ? findsOneWidget : findsNothing,
      reason:
          'capture $shotName: C-523 D2, the current count (4) carries a '
          'check glyph and no other option does; home-players-option-$n '
          '${n == 4 ? 'has none' : 'has one'}',
    );
  }
  await _capture(binding, tester, shotName, frames: 0);
}

/// 103: six characters typed, Join in the tree.
Future<void> _shootHomeJoinShown(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
}) async {
  await _mountPlainHome(tester, binding, shotName: shotName, locale: locale);

  const String code = 'K7M2QP';
  expect(
    normalizeRoomCode(code).length,
    roomCodeLength,
    reason:
        'capture $shotName fixture is broken: "$code" must be '
        '$roomCodeLength characters once normalised',
  );
  expect(
    find.byKey(const Key('join-room-button'), skipOffstage: false),
    findsNothing,
    reason:
        'capture $shotName: C-523 D3, join-room-button is absent before a '
        'code is typed',
  );

  await tester.enterText(find.byKey(const Key('room-code-field')), code);
  await tester.pumpAndSettle();
  // A store screenshot with the caret handle up shows the typing, not the
  // screen; take focus off the field the way capture 14 does for the name.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.ensureVisible(find.byKey(const Key('join-room-button')));
  await _settleForScreenshot(
    tester,
    find.byKey(const Key('join-room-button')),
    'capture $shotName: join-room-button laid out after six characters',
  );

  _expectPlainHome(tester, shotName: shotName, locale: locale, joinShown: true);
  final Finder field = find.descendant(
    of: find.byKey(const Key('room-code-field')),
    matching: find.byType(EditableText),
  );
  expect(
    tester.widget<EditableText>(field).controller.text,
    code,
    reason:
        'capture $shotName: expected room-code-field to still read "$code" '
        'before the shot',
  );
  expect(
    find.text('6 characters, letters and numbers', skipOffstage: false),
    findsNothing,
    reason: 'capture $shotName: C-523 D3, the field has no helper text',
  );
  _expectRectInsideView(
    tester,
    find.byKey(const Key('room-code-field')),
    label: 'room-code-field',
    context: 'with Join shown before capture $shotName',
  );
  _expectRectInsideView(
    tester,
    find.byKey(const Key('join-room-button')),
    label: 'join-room-button',
    context: 'with Join shown before capture $shotName',
  );
  await _capture(binding, tester, shotName, frames: 0);
}

/// 104: system text scale 2.0, the players row scrolled onto the screen.
Future<void> _shootHomeLargeText(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
}) async {
  await _mountPlainHome(
    tester,
    binding,
    shotName: shotName,
    locale: locale,
    textScale: 2.0,
  );

  final double scaledTen = MediaQuery.textScalerOf(
    tester.element(find.byType(HomeScreen)),
  ).scale(10);
  expect(
    scaledTen,
    20.0,
    reason:
        'capture $shotName: expected MediaQuery.textScalerOf at HomeScreen '
        'to scale 10 to 20 under '
        'tester.platformDispatcher.textScaleFactorTestValue = 2.0, got '
        '$scaledTen',
  );

  await tester.ensureVisible(find.byKey(const Key('home-players-button')));
  await tester.pumpAndSettle();

  expect(
    tester.takeException(),
    isNull,
    reason:
        'capture $shotName: home laid out at text scale 2.0 without a '
        'layout exception (${_viewText(tester)})',
  );
  _expectPlainHome(tester, shotName: shotName, locale: locale);
  _expectRectInsideView(
    tester,
    find.byKey(const Key('home-players-button')),
    label: 'home-players-button',
    context: 'at text scale 2.0 before capture $shotName',
  );
  final Finder label = find.text(
    locale.languageCode == 'en' ? _playersQuestionEn : _playersQuestionAr,
  );
  _expectRectInsideView(
    tester,
    label,
    label: 'the players question',
    context: 'at text scale 2.0 before capture $shotName',
  );
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(label);
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason:
        'capture $shotName: the players question is clipped at text scale '
        '2.0 (${_viewText(tester)}); it exceeds its line limit',
  );
  await _capture(binding, tester, shotName, frames: 0);
}

/// 105: the game header after one tap on game-sound-toggle.
Future<void> _shootGameMuted(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final FeedbackSettings settings = FeedbackSettings.forTest();
  final _CueLog cues = _CueLog();
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
      feedbackSettings: settings,
      feedbackService: cues,
    );
    controller = opened.controller;

    final Finder toggle = find.byKey(const Key('game-sound-toggle'));
    expect(
      toggle,
      findsOneWidget,
      reason: 'capture $shotName: expected game-sound-toggle in the header',
    );
    _expectAtLeast48(tester, toggle, 'capture $shotName: game-sound-toggle');
    expect(
      find.descendant(
        of: toggle,
        matching: find.byIcon(Icons.volume_up_rounded),
      ),
      findsOneWidget,
      reason:
          'capture $shotName: before the tap the game is not muted, so '
          'game-sound-toggle shows Icons.volume_up_rounded (D7)',
    );
    expect(
      settings.muted,
      isFalse,
      reason: 'capture $shotName: fixture is broken, settings start muted',
    );
    final int cuesBefore = cues.played.length;

    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
    await _pumpRealDurationFrames(tester);

    expect(
      settings.haptics,
      isFalse,
      reason: 'capture $shotName: one tap mutes, haptics must read false (D7)',
    );
    expect(
      settings.sound,
      isFalse,
      reason: 'capture $shotName: one tap mutes, sound must read false (D7)',
    );
    expect(
      cues.played.length,
      cuesBefore,
      reason:
          'capture $shotName: C-523 D7, turning sound off plays nothing; '
          'cues played after the tap: '
          '${cues.played.sublist(cuesBefore)}',
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.byIcon(Icons.volume_off_rounded),
      ),
      findsOneWidget,
      reason:
          'capture $shotName: after one tap game-sound-toggle shows the '
          'crossed speaker, Icons.volume_off_rounded (D7)',
    );
    expect(
      find.descendant(
        of: toggle,
        matching: find.byIcon(Icons.volume_up_rounded),
      ),
      findsNothing,
      reason:
          'capture $shotName: after one tap game-sound-toggle no longer '
          'shows Icons.volume_up_rounded',
    );
    expect(
      find.byKey(const Key('game-settings-button')),
      findsNothing,
      reason: 'capture $shotName: C-523 D7 removes game-settings-button',
    );
    _expectRectInsideView(
      tester,
      toggle,
      label: 'game-sound-toggle',
      context: 'in the game header before capture $shotName',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName: expected locale ${locale.languageCode}, got '
          '${loc.localeName}',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// --- order 531: dead rooms, first launch and the refused die (C-529) --------

const String _closedHostEn =
    'Your room closed while you were away. Create a new one and send the new '
    'link.';
const String _closedGuestAr =
    'أُغلقت الغرفة أثناء غيابك. اطلب من صديقك رابطاً جديداً.';
const String _roomStartedEn = 'That room is no longer taking players.';
const String _roomStartedAr = 'هذه الغرفة لم تعد تستقبل لاعبين.';
const String _backHomeEn = 'Back to home';
const String _backHomeAr = 'العودة إلى الرئيسية';
const String _serverWords = 'seat token does not match a live seat';

Map<String, Object?> _dataOfSent(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

/// A [RoomController] that remembers whether [dispose] has run. Home retires
/// the controllers it owns when a route pops, and a ChangeNotifier refuses a
/// second dispose.
class _ShotController extends RoomController {
  _ShotController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

/// Hands out a fresh controller per call, and a fresh [FakeTransport] on
/// every connect any of them makes, so a Reconnect after a drop is answered
/// on its own socket. No automatic reconnect: the Reconnect button is what
/// the player taps.
class _ShotFactory {
  final List<_ShotController> controllers = <_ShotController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  /// True: every connect is refused the way an unreachable server refuses
  /// it, so the controller fails with `transport` and no frame is ever sent.
  bool refuseConnects = false;

  /// Connects asked for, refused ones included.
  int connectAttempts = 0;

  RoomController call() {
    final _ShotController created = _ShotController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async {
        connectAttempts += 1;
        if (refuseConnects) {
          throw const SocketException('connection refused');
        }
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
    controllers.add(created);
    return created;
  }

  FakeTransport get last => transports.last;

  /// Every frame of [type] sent on any transport, in order.
  List<String> sent(String type) => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (_typeOf(s) == type) s,
  ];

  List<String> get allTypes => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw) _typeOf(s),
  ];

  /// Answers every leave_room still open, the way capture 61 does, so a
  /// retired controller is not left waiting on its ten second timeout.
  Future<void> answerLeaves(WidgetTester tester) async {
    for (final FakeTransport transport in transports) {
      if (transport.isClosed) {
        continue;
      }
      for (final String leave in _sentOfType(transport, 'leave_room')) {
        transport.pushText(
          _frame(
            type: 'player_left',
            re: _idOf(leave),
            data: const <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': 2},
          ),
        );
      }
    }
    await tester.pump();
  }

  void disposeAll() {
    for (final _ShotController controller in controllers) {
      if (!controller.wasDisposed) {
        controller.dispose();
      }
    }
  }
}

/// Unmounts the tree so no listener outlives its controller, then disposes
/// whatever Home did not already retire.
Future<void> _finishShot(WidgetTester tester, _ShotFactory factory) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  factory.disposeAll();
  await tester.pump();
}

/// Clean store, no seat record, system text scale 1.0, then HomeScreen mounted
/// in [locale] on [factory]. [coldLink] is delivered as the link the app was
/// opened with. Home only, so the trailing pumpAndSettle is safe (no
/// LobbyScreen ticker exists yet).
Future<void> _mountShotHome(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required _ShotFactory factory,
  Uri? coldLink,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      HomeScreen(
        controllerFactory: factory.call,
        onToggleLocale: () {},
        initialLinkReader: () async => coldLink,
      ),
      locale: locale,
    ),
  );
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);
  expect(
    find.byKey(const Key('home-rejoin-button')),
    findsNothing,
    reason:
        'capture $shotName: expected no home-rejoin-button on a home '
        'mounted after clearing SharedPreferences; found one, so a seat '
        'record survived the clear',
  );
}

/// Types [code] into the code field, waits for Join to be in the tree and
/// taps it, as a player does.
Future<void> _typeCodeAndJoin(
  WidgetTester tester, {
  required String code,
  required String shotName,
}) async {
  await tester.enterText(find.byKey(const Key('room-code-field')), code);
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byKey(const Key('join-room-button')),
    'capture $shotName: join-room-button after "$code" was typed',
  );
  // Join arrives inside a 200 ms AnimatedSize; let it reach its final rect.
  await _pumpRealDurationFrames(tester, frameCount: 8);
  await tester.ensureVisible(find.byKey(const Key('join-room-button')));
  await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));
}

/// 106 (order 531). The die refused on my own turn: two seats `[0, 2]`,
/// viewer seat 0, animations off, seat 0 has rolled a 6 with legal `[0, 1]`
/// (capture 97's setup), and the tap goes to `game-die`, which has nothing to
/// roll. The shot is taken 96 ms after the tap, inside the 300 ms window:
/// exactly one RefusalMark is on screen, its rect contains the die's centre,
/// and tokens 0 and 1 still carry their legal rings, so the mark reads under
/// the halo. No `roll` request went out.
Future<void> _shootRefusalDieMyTurn(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}, '
      'animations off, seat 0 rolled 6 legal [0, 1], tap on game-die';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);

    _expectChatFixture(
      tester,
      controller,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      seats: <int>[0, 2],
    );
    expect(
      MediaQuery.disableAnimationsOf(tester.element(find.byType(GameScreen))),
      isTrue,
      reason:
          'capture $shotName ($scenario): the screen must read '
          'disableAnimations as true',
    );

    final int seq = await _pushTraySeq(
      tester,
      opened.transport,
      opened.seq,
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[0, 1],
        'deadline_ms': _trayDeadlineMs,
        'k': 1,
        'reveal': _trayReveal,
      },
    );
    await _pumpRealDurationFrames(tester, frameCount: 4);
    final TurnStateSnapshot turn = _turnOf(controller);
    expect(
      controller.room!.seq,
      seq,
      reason:
          'capture $shotName ($scenario): a pushed frame was dropped; room '
          'seq is ${controller.room!.seq}, last push was $seq',
    );
    expect(
      <Object>[turn.seat, turn.phaseName],
      <Object>[0, 'awaitMove'],
      reason:
          'capture $shotName ($scenario): expected seat 0 in awaitMove '
          'after rolling 6, got seat ${turn.seat} in ${turn.phaseName}',
    );
    for (final int token in <int>[0, 1]) {
      expect(
        find.byKey(Key('board-legal-ring-0-$token')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): token $token must carry a '
            'legal ring',
      );
    }

    final Finder die = find.byKey(const Key('game-die'));
    expect(
      die,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): the die is on screen',
    );
    expect(
      _refusalMarks(),
      findsNothing,
      reason: 'capture $shotName ($scenario): no mark before the tap',
    );
    final int rollsBefore = _sentOfType(opened.transport, 'roll').length;

    final Offset centre = tester.getCenter(die);
    await tester.tap(die, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 96));

    expect(
      _refusalMarks(),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): C-520 D3, exactly one RefusalMark '
          '96 ms after a refused tap on my own die with animations off',
    );
    final Rect mark = tester.getRect(_refusalMarks());
    expect(
      mark.contains(centre),
      isTrue,
      reason:
          'capture $shotName ($scenario): the mark $mark must cover the '
          'die, whose centre is $centre',
    );
    for (final int token in <int>[0, 1]) {
      expect(
        find.byKey(Key('board-legal-ring-0-$token')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario): the legal ring on token $token '
            'must still be up under the mark',
      );
    }
    expect(
      _sentOfType(opened.transport, 'roll').length,
      rollsBefore,
      reason:
          'capture $shotName ($scenario): a refused tap sends nothing; '
          'sent ${opened.transport.sentRaw.map(_typeOf).toList()}',
    );

    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
  }
}

/// 107, 108 (order 531, C-529 D3). A create ([host] true) or join lobby that
/// held a two-seat room, the socket dropped, Reconnect tapped, and the resume
/// answered `NO_SUCH_ROOM`. The route goes home and shows
/// `home-room-closed-notice` with the host line or the guest line, in the
/// card above Create. No lobby-error, no Retry, no second create_room.
Future<void> _shootHomeRoomClosed(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
  required bool host,
}) async {
  final bool en = locale.languageCode == 'en';
  final String expected = host
      ? (en
            ? _closedHostEn
            : 'أُغلقت غرفتك أثناء غيابك. أنشئ غرفة جديدة وأرسل الرابط '
                  'الجديد.')
      : (en
            ? 'That room closed while you were away. Ask your friend for a '
                  'new link.'
            : _closedGuestAr);
  final String scenario =
      '${host ? 'create' : 'join'} lobby for room $roomCode, locale '
      '${locale.languageCode}, socket drop, Reconnect, resume answered '
      'NO_SUCH_ROOM';
  final _ShotFactory factory = _ShotFactory();
  try {
    await _mountShotHome(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      factory: factory,
    );

    await tester.enterText(
      find.byKey(const Key('home-name-field')),
      host ? 'Priya' : 'Karim',
    );
    final String request = host ? 'create_room' : 'join_room';
    if (host) {
      await _tapCreateRoom(tester);
    } else {
      await _typeCodeAndJoin(tester, code: roomCode, shotName: shotName);
    }
    expect(
      factory.controllers,
      hasLength(1),
      reason:
          'capture $shotName ($scenario): the tap must build exactly one '
          'controller',
    );
    expect(
      factory.sent(request),
      hasLength(1),
      reason:
          'capture $shotName ($scenario): expected one $request, sent '
          '${factory.allTypes}',
    );
    final FakeTransport first = factory.transports.single;
    first.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': host ? 0 : 2, 'seat_token': seatToken},
      ),
    );
    first.pushText(
      _frame(
        type: 'room',
        re: _idOf(factory.sent(request).single),
        data: _roomJson(
          code: roomCode,
          players: 2,
          hostSeat: 0,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Priya'),
            _seatJson(2, name: 'Karim'),
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
      'capture $shotName ($scenario): LobbyScreen after the $request reply',
    );
    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 2,
    );
    final RoomController controller = factory.controllers.single;
    expect(
      <Object>[controller.phase, controller.isHost],
      <Object>[RoomPhase.connected, host],
      reason:
          'capture $shotName ($scenario): expected a connected controller '
          'with isHost $host, got phase ${controller.phase}, isHost '
          '${controller.isHost}, error ${controller.errorCode}',
    );

    first.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.closed,
      reason:
          'capture $shotName ($scenario): the far side vanishing must '
          'close the phase, got ${controller.phase}',
    );
    final Finder reconnect = find.byKey(const Key('lobby-reconnect-button'));
    expect(
      reconnect,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): the dropped lobby must offer '
          'Reconnect (${_viewText(tester)})',
    );
    await tester.ensureVisible(reconnect);
    await tester.tap(reconnect);
    await tester.pump();
    await _pumpUntilReady(
      tester,
      () =>
          factory.transports.length == 2 &&
          _sentOfType(factory.last, 'resume').length == 1,
      'capture $shotName ($scenario): one resume on a second transport '
      'after Reconnect; transports ${factory.transports.length}, sent '
      '${factory.allTypes}',
    );
    final int createsBefore = factory.sent('create_room').length;

    factory.last.pushText(
      _frame(
        type: 'error',
        re: _idOf(_sentOfType(factory.last, 'resume').single),
        data: const <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
      ),
    );
    await tester.pump();
    await _pumpUntilReady(
      tester,
      () => find.byType(LobbyScreen, skipOffstage: false).evaluate().isEmpty,
      'capture $shotName ($scenario): the lobby route popped to Home',
    );
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('home-room-closed-notice')),
      'capture $shotName ($scenario): home-room-closed-notice on Home',
    );
    await factory.answerLeaves(tester);
    await _pumpRealDurationFrames(tester);

    expect(
      find.byKey(const Key('lobby-error'), skipOffstage: false),
      findsNothing,
      reason: 'capture $shotName ($scenario): lobby-error must never show',
    );
    expect(
      find.byKey(const Key('lobby-retry-button'), skipOffstage: false),
      findsNothing,
      reason: 'capture $shotName ($scenario): no Retry',
    );
    expect(
      factory.sent('create_room'),
      hasLength(createsBefore),
      reason:
          'capture $shotName ($scenario): no path may create a room the '
          'player did not ask for; sent ${factory.allTypes}',
    );
    expect(
      find.byKey(const Key('home-game-gone-notice'), skipOffstage: false),
      findsNothing,
      reason: 'capture $shotName ($scenario): only the closed notice shows',
    );
    expect(
      find.byKey(const Key('home-removed-notice'), skipOffstage: false),
      findsNothing,
      reason: 'capture $shotName ($scenario): only the closed notice shows',
    );
    expect(
      find.byKey(const Key('home-notice')),
      findsOneWidget,
      reason: 'capture $shotName ($scenario): the notice sits in its card',
    );
    final Finder notice = find.byKey(const Key('home-room-closed-notice'));
    expect(
      notice,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): home-room-closed-notice shows',
    );
    expect(
      tester.widget<Text>(notice).data,
      expected,
      reason:
          'capture $shotName ($scenario): the ${host ? 'host' : 'guest'} '
          'line must read "$expected", it reads '
          '"${tester.widget<Text>(notice).data}"',
    );
    expect(
      tester.getTopLeft(notice).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('create-room-button'))).dy,
      ),
      reason:
          'capture $shotName ($scenario): the notice takes the slot above '
          'create-room-button',
    );
    _expectRectInsideView(
      tester,
      notice,
      label: 'home-room-closed-notice',
      context: 'on Home before capture $shotName',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _finishShot(tester, factory);
  }
}

/// 109, 110 (order 531, C-529 D4). A first-time player's Join answered with
/// [errorCode]: the lobby's error body, no `lobby-retry-button`, and
/// `lobby-leave-button` reading "Back to home" because this lobby never held
/// a seat. [fromLink] true delivers [code] as a cold room link on a first
/// launch, so the Join tap carries the link and the line is the link wording;
/// false types the code, so the line is the typed one.
Future<void> _shootLobbyJoinRefused(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String code,
  required bool fromLink,
  required String errorCode,
}) async {
  final bool en = locale.languageCode == 'en';
  final String scenario =
      '${fromLink ? 'link-filled' : 'typed'} code $code, locale '
      '${locale.languageCode}, join answered $errorCode';
  final _ShotFactory factory = _ShotFactory();
  try {
    await _mountShotHome(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      factory: factory,
      coldLink: fromLink
          ? Uri.parse('https://ludo.provefair.app/r/$code')
          : null,
    );
    if (fromLink) {
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('join-room-button')),
        'capture $shotName ($scenario): join-room-button once the cold '
        'link filled the code field',
      );
      await _pumpRealDurationFrames(tester, frameCount: 8);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-code-field')))
            .controller!
            .text,
        code,
        reason:
            'capture $shotName ($scenario): the link must fill the code '
            'field',
      );
      expect(
        factory.controllers,
        isEmpty,
        reason:
            'capture $shotName ($scenario): a first-time player is never '
            'joined by the link alone; a controller was built',
      );
      await tester.ensureVisible(find.byKey(const Key('join-room-button')));
      await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));
    } else {
      await _typeCodeAndJoin(tester, code: code, shotName: shotName);
    }

    expect(
      factory.sent('join_room'),
      hasLength(1),
      reason:
          'capture $shotName ($scenario): expected one join_room, sent '
          '${factory.allTypes}',
    );
    final String joinRaw = factory.sent('join_room').single;
    expect(
      _dataOfSent(joinRaw)['code'],
      code,
      reason:
          'capture $shotName ($scenario): join_room must carry "$code", it '
          'carries ${_dataOfSent(joinRaw)}',
    );
    factory.last.pushText(
      _frame(
        type: 'error',
        re: _idOf(joinRaw),
        data: <String, Object?>{'code': errorCode, 'message': ''},
      ),
    );
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('lobby-error')),
      'capture $shotName ($scenario): lobby-error after the refused join',
    );
    await _pumpRealDurationFrames(tester);

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(LobbyScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    final Finder error = find.byKey(const Key('lobby-error'));
    final String line;
    if (fromLink) {
      line = loc.lobbyErrorLinkRoomGone;
      expect(
        line,
        isNotEmpty,
        reason:
            'capture $shotName ($scenario): the link line must be written '
            'out in ${locale.languageCode}',
      );
      expect(
        line,
        isNot(loc.lobbyErrorNoSuchRoom),
        reason:
            'capture $shotName ($scenario): the link line must not be the '
            'typed-code line "${loc.lobbyErrorNoSuchRoom}"',
      );
    } else {
      line = en ? _roomStartedEn : _roomStartedAr;
    }
    expect(
      find.descendant(of: error, matching: find.text(line)),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): lobby-error must read "$line"; '
          'the texts on screen are ${_viewText(tester)}',
    );
    expect(
      find.byKey(const Key('lobby-retry-button'), skipOffstage: false),
      findsNothing,
      reason:
          'capture $shotName ($scenario): $errorCode can never succeed on '
          'a retry, so lobby-retry-button must be absent',
    );
    final Finder leave = find.byKey(const Key('lobby-leave-button'));
    expect(
      leave,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): lobby-leave-button is on screen',
    );
    final String leaveText = en ? _backHomeEn : _backHomeAr;
    expect(
      find.descendant(of: leave, matching: find.text(leaveText)),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): lobby-leave-button must read '
          '"$leaveText" (no seat was ever held); the texts on screen are '
          '${_viewText(tester)}',
    );
    _expectRectInsideView(
      tester,
      leave,
      label: 'lobby-leave-button',
      context: 'in the lobby error body before capture $shotName',
    );
    _expectLobbyErrorCard(
      tester,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      icon: errorCode == 'NO_SUCH_ROOM'
          ? Icons.link_off_rounded
          : Icons.info_outline_rounded,
      line: line,
      retry: false,
      leaveText: leaveText,
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _finishShot(tester, factory);
  }
}

/// C-533 D2 for the lobby error body, read in the tree before the shot: the
/// card sits on the felt inside `lobby-error`, carries [icon] and [line], and
/// holds exactly one filled button. With [retry] that button is
/// `lobby-retry-button` and `lobby-leave-button` is the outlined one under
/// it; without, `lobby-leave-button` is the filled one and nothing is
/// outlined. Both tap targets are at least 48 dp and the direction is the
/// locale's own.
void _expectLobbyErrorCard(
  WidgetTester tester, {
  required String shotName,
  required String scenario,
  required Locale locale,
  required IconData icon,
  required String line,
  required bool retry,
  required String leaveText,
}) {
  final String who = 'capture $shotName ($scenario)';
  final Finder error = find.byKey(const Key('lobby-error'));
  final Finder card = find.byKey(const Key('lobby-error-card'));
  expect(
    find.descendant(of: error, matching: card),
    findsOneWidget,
    reason:
        '$who: C-533 D2, lobby-error-card must be the card inside '
        'lobby-error; the texts on screen are ${_viewText(tester)}',
  );
  final Widget cardWidget = tester.widget(card);
  expect(
    cardWidget,
    isA<Material>(),
    reason:
        '$who: lobby-error-card must be a Material, it is '
        '${cardWidget.runtimeType}',
  );
  final Material material = cardWidget as Material;
  expect(
    <Object?>[material.color, material.elevation],
    <Object?>[LudoColors.paperElevated, 6.0],
    reason:
        '$who: the card takes the game screen\'s connection-lost shape, '
        'paperElevated at elevation 6; it reads color ${material.color}, '
        'elevation ${material.elevation}',
  );
  expect(
    tester.getSize(card).width,
    lessThanOrEqualTo(320),
    reason:
        '$who: the card is at most 320 dp wide, it is '
        '${tester.getSize(card).width.toStringAsFixed(1)}',
  );
  _expectRectInsideView(
    tester,
    card,
    label: 'lobby-error-card',
    context: 'in the lobby error body before capture $shotName',
  );
  expect(
    Directionality.of(tester.element(card)),
    locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
    reason: '$who: the card must lay out in the locale\'s own direction',
  );

  final Finder iconFinder = find.descendant(
    of: card,
    matching: find.byIcon(icon),
  );
  expect(
    iconFinder,
    findsOneWidget,
    reason: '$who: the card must carry the $icon icon on top',
  );
  expect(
    tester.widget<Icon>(iconFinder).size,
    32,
    reason: '$who: the icon is 32 dp',
  );
  expect(
    find.descendant(of: card, matching: find.byType(Icon)),
    findsOneWidget,
    reason: '$who: the card carries the one icon and no other',
  );
  expect(
    find.descendant(of: card, matching: find.text(line)),
    findsOneWidget,
    reason:
        '$who: the card must read "$line"; the texts on screen are '
        '${_viewText(tester)}',
  );

  final Finder leave = find.descendant(
    of: card,
    matching: find.byKey(const Key('lobby-leave-button')),
  );
  expect(
    leave,
    findsOneWidget,
    reason: '$who: lobby-leave-button must sit inside the card',
  );
  expect(
    find.descendant(of: leave, matching: find.text(leaveText)),
    findsOneWidget,
    reason: '$who: lobby-leave-button must read "$leaveText"',
  );
  expect(
    find.descendant(of: card, matching: find.byType(ElevatedButton)),
    findsOneWidget,
    reason: '$who: C-533 D2, exactly one filled button in the card',
  );
  final Finder retryButton = find.descendant(
    of: card,
    matching: find.byKey(const Key('lobby-retry-button')),
  );
  if (retry) {
    expect(
      retryButton,
      findsOneWidget,
      reason: '$who: a retryable failure must show lobby-retry-button',
    );
    expect(
      tester.widget(retryButton),
      isA<ElevatedButton>(),
      reason:
          '$who: Retry is the filled button, it is '
          '${tester.widget(retryButton).runtimeType}',
    );
    expect(
      tester.widget(leave),
      isA<OutlinedButton>(),
      reason:
          '$who: with Retry shown, lobby-leave-button is outlined, it is '
          '${tester.widget(leave).runtimeType}',
    );
    expect(
      find.descendant(of: card, matching: find.byType(OutlinedButton)),
      findsOneWidget,
      reason: '$who: one outlined button, the way out',
    );
    expect(
      tester.getTopLeft(retryButton).dy,
      lessThan(tester.getTopLeft(leave).dy),
      reason: '$who: Retry sits above the way out',
    );
  } else {
    expect(
      retryButton,
      findsNothing,
      reason: '$who: this failure can never succeed on a retry',
    );
    expect(
      tester.widget(leave),
      isA<ElevatedButton>(),
      reason:
          '$who: without Retry, lobby-leave-button is the filled button, it '
          'is ${tester.widget(leave).runtimeType}',
    );
    expect(
      find.descendant(of: card, matching: find.byType(OutlinedButton)),
      findsNothing,
      reason: '$who: nothing outlined remains when the way out is filled',
    );
  }
  final List<(String, Finder)> targets = <(String, Finder)>[
    if (retry) ('lobby-retry-button', retryButton),
    ('lobby-leave-button', leave),
  ];
  for (final (String name, Finder button) in targets) {
    final Size size = tester.getSize(button);
    expect(
      <bool>[size.width >= 48, size.height >= 48],
      <bool>[true, true],
      reason:
          '$who: a tap target is at least 48 x 48 dp, $name is '
          '${size.width.toStringAsFixed(1)} x '
          '${size.height.toStringAsFixed(1)}',
    );
  }
}

/// 115 (order 535, C-533 D2). A typed join whose connection is refused: the
/// controller fails with `transport` before any frame is sent, the lobby
/// shows its error card, Retry is the filled button and Back to home the
/// outlined one under it.
Future<void> _shootLobbyJoinTransport(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String code,
}) async {
  final String scenario =
      'typed code $code, locale ${locale.languageCode}, connect refused';
  final _ShotFactory factory = _ShotFactory()..refuseConnects = true;
  try {
    await _mountShotHome(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      factory: factory,
    );
    await _typeCodeAndJoin(tester, code: code, shotName: shotName);
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('lobby-error')),
      'capture $shotName ($scenario): lobby-error after the refused connect',
    );
    await _pumpRealDurationFrames(tester);

    expect(
      <Object?>[
        factory.controllers.length,
        factory.controllers.single.phase,
        factory.controllers.single.errorCode,
      ],
      <Object?>[1, RoomPhase.failed, 'transport'],
      reason:
          'capture $shotName ($scenario): fixture: the controller must be '
          'failed with transport, it holds '
          '${factory.controllers.map((c) => '${c.phase}/${c.errorCode}').toList()}',
    );
    expect(
      <Object?>[factory.connectAttempts, factory.allTypes],
      <Object?>[1, <String>[]],
      reason:
          'capture $shotName ($scenario): one refused connect and no frame '
          'sent; connects ${factory.connectAttempts}, sent '
          '${factory.allTypes}',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(LobbyScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    expect(
      loc.lobbyErrorTransport,
      isNotEmpty,
      reason:
          'capture $shotName ($scenario): the transport line must be '
          'written out in ${locale.languageCode}',
    );
    _expectLobbyErrorCard(
      tester,
      shotName: shotName,
      scenario: scenario,
      locale: locale,
      icon: Icons.wifi_off_rounded,
      line: loc.lobbyErrorTransport,
      retry: true,
      leaveText: loc.lobbyBackToHomeButton,
    );
    expect(
      find.byKey(const Key('lobby-closed'), skipOffstage: false),
      findsNothing,
      reason: 'capture $shotName ($scenario): only the error card is built',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _finishShot(tester, factory);
  }
}

/// 111 (order 531, C-529 D5). A PLAYING game, seat 0 to roll, the die tapped,
/// and the roll answered `INTERNAL` with the server's English message. The
/// connection-lost card shows with the Arabic title; the server's words and
/// the English title are nowhere in the tree and `game-screen-error-message`
/// is absent. This still used `BAD_SEAT_TOKEN` until C-540 D1: a game route
/// whose controller fails with it now goes home, so the fixture answers a code
/// that maps to the same generic line and stays on the game route.
Future<void> _shootGameConnectionLost(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  const String genericCode = 'INTERNAL';
  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}, roll '
      'answered $genericCode "$_serverWords"';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester, frameCount: 4);
    expect(
      controller.room!.state,
      RoomState.playing,
      reason:
          'capture $shotName ($scenario): the room must be PLAYING before '
          'the failure, got ${controller.room!.state}',
    );

    final Finder die = find.byKey(const Key('game-die'));
    expect(
      die,
      findsOneWidget,
      reason: 'capture $shotName ($scenario): the die is on screen',
    );
    await tester.tap(die);
    await tester.pump();
    final List<String> rolls = _sentOfType(opened.transport, 'roll');
    expect(
      rolls,
      hasLength(1),
      reason:
          'capture $shotName ($scenario): the tap on my own die must send '
          'one roll, sent ${opened.transport.sentRaw.map(_typeOf).toList()}',
    );
    opened.transport.pushText(
      _frame(
        type: 'error',
        re: _idOf(rolls.single),
        data: const <String, Object?>{
          'code': genericCode,
          'message': _serverWords,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('game-screen-connection-lost')),
      'capture $shotName ($scenario): the connection-lost card',
    );
    await _pumpRealDurationFrames(tester, frameCount: 8);

    expect(
      <Object?>[
        controller.phase,
        controller.errorCode,
        controller.errorMessage,
      ],
      <Object?>[RoomPhase.failed, genericCode, _serverWords],
      reason:
          'capture $shotName ($scenario): fixture: the controller must hold '
          'the failure with the server\'s message in hand',
    );
    expect(
      controller.room!.state,
      RoomState.playing,
      reason:
          'capture $shotName ($scenario): the failure leaves the room '
          'PLAYING, got ${controller.room!.state}',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    final AppLocalizations english = await AppLocalizations.delegate.load(
      const Locale('en'),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('game-screen-connection-lost')),
        matching: find.text(loc.lobbyConnectionLost),
      ),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): the card must carry its title in '
          '${locale.languageCode}: "${loc.lobbyConnectionLost}"; the texts '
          'on screen are ${_viewText(tester)}',
    );
    for (final String englishText in <String>[
      english.lobbyConnectionLost,
      english.lobbyReconnectButton,
      english.gameLeaveButton,
    ]) {
      expect(
        find.text(englishText, skipOffstage: false),
        findsNothing,
        reason:
            'capture $shotName ($scenario): English text "$englishText" is '
            'on a ${locale.languageCode} screen; the texts on screen are '
            '${_viewText(tester)}',
      );
    }
    expect(
      find.textContaining(_serverWords, skipOffstage: false),
      findsNothing,
      reason:
          'capture $shotName ($scenario): the server\'s own words must be '
          'rendered nowhere; the texts on screen are ${_viewText(tester)}',
    );
    expect(
      find.byKey(const Key('game-screen-error-message'), skipOffstage: false),
      findsNothing,
      reason:
          'capture $shotName ($scenario): $genericCode maps to the '
          'generic line, so game-screen-error-message and its gap are absent',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 112 (order 531, C-529 D6). A seat record with no saved time, the Back to
/// game button on Home tapped, and the resume answered with a FINISHED room.
/// The snapshot carries no rolls, so the end card shows neither the roll
/// heading nor the empty line. The verify link stays.
Future<void> _shootEndResumedNoRolls(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}, '
      'FINISHED snapshot from a resume, no rolls seen';
  final _ShotFactory factory = _ShotFactory();
  try {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();
    await (await SharedPreferences.getInstance()).clear();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await _seedSeatWithoutSavedTime(
      SeatRecord(code: roomCode, seat: 0, seatToken: seatToken),
    );

    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: locale,
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);
    expect(
      find.byKey(const Key('home-rejoin-button')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): the seat record without a saved '
          'time must show home-rejoin-button',
    );
    await tester.ensureVisible(find.byKey(const Key('home-rejoin-button')));
    await _tapAndAwaitPushedRoute(tester, const Key('home-rejoin-button'));

    expect(
      factory.sent('resume'),
      hasLength(1),
      reason:
          'capture $shotName ($scenario): the tap must send one resume, sent '
          '${factory.allTypes}',
    );
    final FakeTransport transport = factory.last;
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(factory.sent('resume').single),
        data: <String, Object?>{
          ..._roomJson(
            code: roomCode,
            state: 'FINISHED',
            players: 2,
            hostSeat: 0,
            gameId: gameId,
            clientSeeds: '0:seed|2:seed',
            winner: 2,
            turn: const <String, Object?>{
              'seat': 2,
              'phase': 'finished',
              'deadline_ms': 0,
              'k': 8,
            },
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Priya', tokens: const <int>[57, 57, 12, -1]),
              _seatJson(2, name: 'Karim', tokens: const <int>[57, 57, 57, 57]),
            ],
            seq: 9,
          ),
          'verify_url': 'https://verify.example.invalid/shot112',
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byType(GameScreen),
      'capture $shotName ($scenario): GameScreen after the resume reply',
    );
    await _pumpRealDurationFrames(tester, frameCount: 8);
    // The end card asks for the game log; nothing here is in it.
    for (final String raw in _sentOfType(transport, 'game_log')) {
      transport.pushText(
        _frame(
          type: 'error',
          re: _idOf(raw),
          data: const <String, Object?>{
            'code': 'RATE_LIMITED',
            'message': 'game_log',
          },
        ),
      );
    }
    await tester.pump();
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byType(EndCard),
      'capture $shotName ($scenario): the end card from the FINISHED '
      'snapshot',
    );
    await _pumpRealDurationFrames(tester);

    final RoomController controller = factory.controllers.single;
    expect(
      <Object?>[controller.room!.state, controller.room!.winner],
      <Object?>[RoomState.finished, 2],
      reason:
          'capture $shotName ($scenario): the snapshot must land FINISHED '
          'with winner 2, got ${controller.room!.state}, winner '
          '${controller.room!.winner}',
    );
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    expect(
      find.byKey(const Key('end-card-lose')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): expected the loser card; the '
          'texts on screen are ${_viewText(tester)}',
    );
    expect(
      find.text(loc.gameRollHistoryHeading, skipOffstage: false),
      findsNothing,
      reason:
          'capture $shotName ($scenario): C-529 D6, "'
          '${loc.gameRollHistoryHeading}" heads a block with nothing to list',
    );
    expect(
      find.text(loc.gameRollHistoryEmpty, skipOffstage: false),
      findsNothing,
      reason:
          'capture $shotName ($scenario): C-529 D6, "'
          '${loc.gameRollHistoryEmpty}" is false of a game that was played',
    );
    expect(
      find.byType(VerifyRollsButton),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): the verify link stays the way to '
          'the rolls',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _finishShot(tester, factory);
  }
}

/// Plays the two-seat game capture 113 photographs, from `game_started` at
/// [gameStartedSeq], on [transport]. Seat 0 (this device) rolls 2, 5 and 3
/// and none of them can move: no six, no capture, nothing home. Seat 2
/// (Karim) enters on a 6 and takes all four tokens to 57. Every frame is
/// pushed before the two pumps, as the end-card replay does, and `seq` is
/// continuous so the stats stay complete. Returns the seq `game_over` must
/// carry.
Future<int> _playLoseZeroScript(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller, {
  required int gameStartedSeq,
}) async {
  expect(
    controller.room?.seq,
    gameStartedSeq,
    reason:
        'zero-stats script: room seq is ${controller.room?.seq}, expected '
        '$gameStartedSeq',
  );
  var seq = gameStartedSeq;
  var k = 0;

  void rolled(int seat, int face, List<int> legal) {
    k += 1;
    seq += 1;
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': seat,
          'value': face,
          'legal': legal,
          'deadline_ms': _endCardDeadlineMs,
          'k': k,
          'reveal': _endCardReveal(k),
          'seq': seq,
        },
      ),
    );
  }

  void moved(int token, int from, int to, {required bool extra}) {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'moved',
        data: <String, Object?>{
          'seat': 2,
          'token': token,
          'from': from,
          'to': to,
          'captured': <Object?>[],
          'extra_roll': extra,
          'seq': seq,
        },
      ),
    );
  }

  void turn(int seat) {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': seat,
          'deadline_ms': _endCardDeadlineMs,
          'seq': seq,
        },
      ),
    );
  }

  rolled(0, 2, const <int>[]);
  turn(2);
  rolled(2, 6, const <int>[0]);
  moved(0, -1, 0, extra: true);
  turn(2);
  rolled(2, 4, const <int>[0]);
  moved(0, 0, 4, extra: false);
  turn(0);
  rolled(0, 5, const <int>[]);
  turn(2);
  rolled(2, 1, const <int>[1]);
  moved(1, -1, 57, extra: false);
  turn(0);
  rolled(0, 3, const <int>[]);
  turn(2);
  rolled(2, 1, const <int>[2]);
  moved(2, -1, 57, extra: false);
  turn(2);
  rolled(2, 1, const <int>[3]);
  moved(3, -1, 57, extra: false);
  turn(2);
  rolled(2, 1, const <int>[0]);
  moved(0, 4, 57, extra: false);

  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason:
        'zero-stats script: seq gap (room seq ${controller.room?.seq}, last '
        'pushed seq $seq)',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: 'zero-stats script must still be in play when it returns',
  );
  expect(
    <List<int>>[_endCardTokens(controller, 0), _endCardTokens(controller, 2)],
    <List<int>>[
      <int>[-1, -1, -1, -1],
      <int>[57, 57, 57, 57],
    ],
    reason:
        'zero-stats script: seat 0 must still have every token in its yard '
        'and seat 2 every token home, got '
        '${_endCardTokens(controller, 0)} and ${_endCardTokens(controller, 2)}',
  );
  return seq + 1;
}

/// 113 (order 531, X120). A real loser's end card: seat 0 played the whole
/// game on this device, so the stats are complete, and rolled 2, 5 and 3. The
/// counts are 3 rolls, 0 sixes, 0 captures and 0 tokens home, so under C-533
/// D3 only the rolls tile is on the card.
Future<void> _shootEndLoseZero(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}, seat 0 '
      'rolled 2, 5, 3, seat 2 won';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    final int gameOverSeq = await _playLoseZeroScript(
      tester,
      opened.transport,
      controller,
      gameStartedSeq: opened.seq,
    );
    opened.transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 2,
          'verify_url': 'https://verify.example.invalid/shot113',
          'seq': gameOverSeq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpRealDurationFrames(tester);

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 2,
      expectedText: loc.endLoseTitle('Karim'),
      momentDescription: 'capture $shotName ($scenario), before the shot',
    );
    expect(
      controller.hasDesynced,
      isFalse,
      reason: 'capture $shotName ($scenario): a seq gap makes the stats gap',
    );
    _expectEndCardStatTiles(
      tester,
      rolls: 3,
      sixes: 0,
      captures: 0,
      home: 0,
      momentDescription: 'capture $shotName ($scenario), before the shot',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Plays the nine-roll game capture 118 photographs, from `game_started` at
/// [gameStartedSeq], on [transport]. Seat 0 (this device) rolls 2, 6, 3, 5,
/// 4, 6, 2, 1 and 3: two sixes, each one entering a token, no capture, and
/// its two tokens end on squares 12 and 6, so nothing is home. Seat 2
/// (Karim) takes all four tokens to 57 and wins. Every frame is pushed
/// before the two pumps and `seq` is continuous, so the stats stay
/// complete. Returns the seq `game_over` must carry.
Future<int> _playLoseSomeScript(
  WidgetTester tester,
  FakeTransport transport,
  RoomController controller, {
  required int gameStartedSeq,
}) async {
  expect(
    controller.room?.seq,
    gameStartedSeq,
    reason:
        'some-zero script: room seq is ${controller.room?.seq}, expected '
        '$gameStartedSeq',
  );
  var seq = gameStartedSeq;
  var k = 0;

  void rolled(int seat, int face, List<int> legal) {
    k += 1;
    seq += 1;
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': seat,
          'value': face,
          'legal': legal,
          'deadline_ms': _endCardDeadlineMs,
          'k': k,
          'reveal': _endCardReveal(k),
          'seq': seq,
        },
      ),
    );
  }

  void moved(int seat, int token, int from, int to, {required bool extra}) {
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
          'extra_roll': extra,
          'seq': seq,
        },
      ),
    );
  }

  void turn(int seat) {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': seat,
          'deadline_ms': _endCardDeadlineMs,
          'seq': seq,
        },
      ),
    );
  }

  void play(
    int seat,
    int face,
    int token,
    int from,
    int to, {
    bool extra = false,
    int? turnSeat,
  }) {
    rolled(seat, face, <int>[token]);
    moved(seat, token, from, to, extra: extra);
    if (turnSeat != null) {
      turn(turnSeat);
    }
  }

  rolled(0, 2, const <int>[]);
  turn(2);
  play(2, 6, 0, -1, 0, extra: true, turnSeat: 2);
  play(2, 4, 0, 0, 4, turnSeat: 0);
  play(0, 6, 0, -1, 0, extra: true, turnSeat: 0);
  play(0, 3, 0, 0, 3, turnSeat: 2);
  play(2, 1, 1, -1, 57, turnSeat: 0);
  play(0, 5, 0, 3, 8, turnSeat: 2);
  play(2, 1, 2, -1, 57, turnSeat: 0);
  play(0, 4, 0, 8, 12, turnSeat: 2);
  play(2, 1, 3, -1, 57, turnSeat: 0);
  play(0, 6, 1, -1, 0, extra: true, turnSeat: 0);
  play(0, 2, 1, 0, 2, turnSeat: 2);
  play(2, 3, 0, 4, 7, turnSeat: 0);
  play(0, 1, 1, 2, 3, turnSeat: 2);
  play(2, 2, 0, 7, 9, turnSeat: 0);
  play(0, 3, 1, 3, 6, turnSeat: 2);
  play(2, 1, 0, 9, 57);

  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason:
        'some-zero script: seq gap (room seq ${controller.room?.seq}, last '
        'pushed seq $seq)',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: 'some-zero script must still be in play when it returns',
  );
  expect(
    <List<int>>[_endCardTokens(controller, 0), _endCardTokens(controller, 2)],
    <List<int>>[
      <int>[12, 6, -1, -1],
      <int>[57, 57, 57, 57],
    ],
    reason:
        'some-zero script: seat 0 must hold squares 12 and 6 with two '
        'tokens in its yard and seat 2 every token home, got '
        '${_endCardTokens(controller, 0)} and ${_endCardTokens(controller, 2)}',
  );
  return seq + 1;
}

/// 118 (order 535, X120). A real loser's end card with complete stats: seat 0
/// played the whole game on this device and rolled nine times, two of them
/// sixes, captured nothing and has no token home. Under C-533 D3 the card
/// shows the rolls and sixes tiles and neither of the other two.
Future<void> _shootEndLoseSomeZero(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String scenario =
      'room $roomCode, game $gameId, locale ${locale.languageCode}, seat 0 '
      'rolled 9 with two sixes, no capture, none home, seat 2 won';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
    );
    controller = opened.controller;
    final int gameOverSeq = await _playLoseSomeScript(
      tester,
      opened.transport,
      controller,
      gameStartedSeq: opened.seq,
    );
    opened.transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 2,
          'verify_url': 'https://verify.example.invalid/shot118',
          'seq': gameOverSeq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpRealDurationFrames(tester);

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          'capture $shotName ($scenario): expected locale '
          '${locale.languageCode}, got ${loc.localeName}',
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 2,
      expectedText: loc.endLoseTitle('Karim'),
      momentDescription: 'capture $shotName ($scenario), before the shot',
    );
    expect(
      controller.hasDesynced,
      isFalse,
      reason: 'capture $shotName ($scenario): a seq gap makes the stats gap',
    );
    final GameStats stats = computeGameStats(
      frames: controller.gameTranscript,
      seat: 0,
      finalTokens: _endCardTokens(controller, 0),
    );
    expect(
      <Object?>[
        stats.complete,
        stats.rolls,
        stats.sixes,
        stats.capturesMade,
        stats.tokensHome,
      ],
      <Object?>[true, 9, 2, 0, 0],
      reason:
          'capture $shotName ($scenario): fixture: the device transcript '
          'must hold complete stats of 9 rolls, 2 sixes, 0 captures, 0 '
          'home, it computes $stats',
    );
    _expectEndCardStatTiles(
      tester,
      rolls: 9,
      sixes: 2,
      captures: 0,
      home: 0,
      momentDescription: 'capture $shotName ($scenario), before the shot',
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

// --- captures 119-121: seats that share a name (order 538, C-536) ----------

/// The default name a first-timer is given, which two strangers can both be
/// holding when they sit down.
String _defaultPlayerName(Locale locale) =>
    locale.languageCode == 'ar' ? 'لاعب' : 'Player';

/// Every string a `Text` under [root] draws, in tree order.
List<String> _textsOf(WidgetTester tester, Finder root) => <String>[
  for (final Text t in tester.widgetList<Text>(
    find.descendant(of: root, matching: find.byType(Text)),
  ))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

/// Asserts that [root] draws [label] exactly, and that none of the strings in
/// [notShown] stands on its own among its texts.
void _expectNameLabel(
  WidgetTester tester,
  Finder root, {
  required String label,
  List<String> notShown = const <String>[],
  required String what,
  required String scenario,
}) {
  expect(
    root,
    findsOneWidget,
    reason: '$scenario: expected $what on screen, found none or several',
  );
  final List<String> texts = _textsOf(tester, root);
  expect(
    texts,
    contains(label),
    reason: '$scenario: expected $what to read "$label", it shows $texts',
  );
  for (final String other in notShown) {
    expect(
      texts,
      isNot(contains(other)),
      reason:
          '$scenario: expected $what to read "$label" and not "$other", '
          'it shows $texts',
    );
  }
}

/// 119 (order 538, C-536). The host's lobby with three seats: seats 0 and 2
/// both joined as the default name, seat 1 as Karim. The cards read the name,
/// "Karim" and the name with the numeral 2.
Future<void> _shootLobbySameNames(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String player = _defaultPlayerName(locale);
  final String scenario =
      'capture $shotName (room $roomCode, locale ${locale.languageCode}, '
      'seats 0 and 2 "$player", seat 1 "Karim")';
  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  RoomController? controller;
  try {
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
        locale: locale,
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    await tester.enterText(find.byKey(const Key('home-name-field')), player);
    await _tapCreateRoom(tester);

    expect(
      factory.controllers,
      hasLength(1),
      reason:
          '$scenario: tapping Create Room must build exactly one controller',
    );
    controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    final List<String> createMessages = transport.sentRaw
        .where((s) => _typeOf(s) == 'create_room')
        .toList();
    expect(
      createMessages,
      hasLength(1),
      reason:
          '$scenario: expected one create_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );
    final String createId = _idOf(createMessages.single);

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
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
          seats: <Map<String, Object?>>[_seatJson(0, name: player)],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byType(LobbyScreen),
      '$scenario: LobbyScreen after the create_room reply',
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
        data: <String, Object?>{'seat': 2, 'name': player, 'seq': 3},
      ),
    );
    await tester.pump();
    await _pumpRealDurationFrames(tester);

    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 3,
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.name).toList(),
      <String>[player, 'Karim', player],
      reason:
          '$scenario: fixture: the server sent the same name for seats 0 '
          'and 2, got ${controller.room!.seats.map((SeatState s) => s.name)}',
    );
    final MaterialLocalizations material = MaterialLocalizations.of(
      tester.element(find.byType(LobbyScreen)),
    );
    final String second = '$player ${material.formatDecimal(2)}';
    _expectNameLabel(
      tester,
      find.byKey(const Key('lobby-seat-0')),
      label: player,
      notShown: <String>[second],
      what: 'lobby-seat-0',
      scenario: scenario,
    );
    _expectNameLabel(
      tester,
      find.byKey(const Key('lobby-seat-1')),
      label: 'Karim',
      notShown: <String>[player, second],
      what: 'lobby-seat-1',
      scenario: scenario,
    );
    _expectNameLabel(
      tester,
      find.byKey(const Key('lobby-seat-2')),
      label: second,
      notShown: <String>[player],
      what: 'lobby-seat-2',
      scenario: scenario,
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 120 (order 538, C-536). A game in progress, Arabic, seats 0 and 2 both the
/// default name. The board chip of seat 0 reads the name, the chip of seat 2
/// reads the name, a space and the numeral the framework draws for 2 in this
/// locale, read here from MaterialLocalizations.
Future<void> _shootGameSameNames(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String player = _defaultPlayerName(locale);
  final String scenario =
      'capture $shotName (room $roomCode, game $gameId, locale '
      '${locale.languageCode}, seats 0 and 2 "$player")';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
      hostName: player,
      opponentName: player,
    );
    controller = opened.controller;
    await _pumpRealDurationFrames(tester);

    await _expectGameScreenBoard(
      tester,
      controller: controller,
      localeName: locale.languageCode,
      scenario: scenario,
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.name).toList(),
      <String>[player, player],
      reason:
          '$scenario: fixture: the server sent the same name for seats 0 '
          'and 2, got ${controller.room!.seats.map((SeatState s) => s.name)}',
    );
    final MaterialLocalizations material = MaterialLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    final String second = '$player ${material.formatDecimal(2)}';
    _expectNameLabel(
      tester,
      find.byKey(const Key('board-seat-name-0')),
      label: player,
      notShown: <String>[second],
      what: 'board-seat-name-0',
      scenario: scenario,
    );
    _expectNameLabel(
      tester,
      find.byKey(const Key('board-seat-name-2')),
      label: second,
      notShown: <String>[player],
      what: 'board-seat-name-2',
      scenario: scenario,
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Asserts the game screen is up in [localeName] with the board drawn and the
/// room still playing. [_expectGameScreenMidGame] also wants five tokens out
/// of their yards, which the opening position 120 photographs does not have.
Future<void> _expectGameScreenBoard(
  WidgetTester tester, {
  required RoomController controller,
  required String localeName,
  required String scenario,
}) async {
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: '$scenario: expected the game screen on screen',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    localeName,
    reason:
        '$scenario: expected the game screen locale "$localeName", got '
        '"${loc.localeName}"',
  );
  expect(
    find.byKey(const Key('game-screen-board')),
    findsOneWidget,
    reason: '$scenario: expected the board on screen',
  );
  expect(
    controller.room!.state,
    RoomState.playing,
    reason:
        '$scenario: fixture: the room must be playing, got '
        '${controller.room!.state}',
  );
}

/// 121 (order 538, C-536). The loser's end card for seat 0 when seat 2 won and
/// both seats carry the default name: the title names the winner with the
/// numeral 2, so the card does not say that "Player" took it.
Future<void> _shootEndSameNames(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String gameId,
  required String seatToken,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String player = _defaultPlayerName(locale);
  final String scenario =
      'capture $shotName (room $roomCode, game $gameId, locale '
      '${locale.languageCode}, seats 0 and 2 "$player", seat 2 won)';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openHostGame(
      tester,
      capture: shotName,
      roomCode: roomCode,
      locale: locale,
      gameId: gameId,
      seatToken: seatToken,
      hostName: player,
      opponentName: player,
    );
    controller = opened.controller;
    final int gameOverSeq = await _playLoseZeroScript(
      tester,
      opened.transport,
      controller,
      gameStartedSeq: opened.seq,
    );
    opened.transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 2,
          'verify_url': 'https://verify.example.invalid/shot121',
          'seq': gameOverSeq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpRealDurationFrames(tester);

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(
      loc.localeName,
      locale.languageCode,
      reason:
          '$scenario: expected locale ${locale.languageCode}, got '
          '${loc.localeName}',
    );
    expect(
      controller.room!.seats.map((SeatState s) => s.name).toList(),
      <String>[player, player],
      reason:
          '$scenario: fixture: the server sent the same name for seats 0 '
          'and 2, got ${controller.room!.seats.map((SeatState s) => s.name)}',
    );
    final MaterialLocalizations material = MaterialLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    _expectGameOverWinnerText(
      tester,
      controller: controller,
      expectedWinner: 2,
      expectedText: loc.endLoseTitle('$player ${material.formatDecimal(2)}'),
      momentDescription: scenario,
    );
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// A PLAYING game on a bare GameScreen, built the way capture 10 builds its
/// own: a real RoomController on a FakeTransport, a create reply carrying a
/// PLAYING room, no route in front of it. A null [seatToken] sends no
/// `seat_assigned`, so a later seq gap sets `hasDesynced` without sending a
/// resume and leaves no request timer running. Caller releases it with
/// _releaseTrayGame.
Future<_OpenedTrayGame> _openBareGame(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String? seatToken,
  List<Duration> autoReconnectDelays = const <Duration>[],
  int deadlineMs = 45000,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async => transport,
    autoReconnectDelays: autoReconnectDelays,
  );
  final Future<void> createFuture = controller.createRoom(
    name: 'Priya',
    players: 2,
  );
  await tester.pump();
  await tester.pump();
  final String createId = _idOf(transport.sentRaw.last);
  if (seatToken != null) {
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
      ),
    );
  }
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        code: roomCode,
        state: 'PLAYING',
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Priya'),
          _seatJson(2, name: 'Karim'),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': deadlineMs,
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
        'capture $shotName: fixture is broken, the create reply must land '
        'connected, room $roomCode, got ${controller.phase}',
  );
  await tester.pumpWidget(
    _reconnectingCaptureHarness(
      GameScreen(controller: controller),
      locale: locale,
    ),
  );
  await tester.pump();
  await _pumpRealDurationFrames(tester, frameCount: 4);
  return _OpenedTrayGame(controller: controller, transport: transport, seq: 1);
}

/// Pushes the frame the server sends a displaced socket (an `error` with no
/// `re`, code BAD_SEAT_TOKEN) and then ends the link. The fake transport
/// carries no close code, so the 4004 that follows the frame on the wire is
/// the end of the stream here.
Future<void> _takeSeatOver(WidgetTester tester, FakeTransport transport) async {
  transport.pushText(
    _frame(
      type: 'error',
      data: const <String, Object?>{
        'code': 'BAD_SEAT_TOKEN',
        'message': _serverWords,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
}

/// 122 and 123 (order 552, C-547 D2). A PLAYING game, then the server's
/// unsolicited BAD_SEAT_TOKEN and the close. The card keeps the connection-lost
/// Key, says `seatMovedLine`, and offers Leave alone: no Reconnect, no
/// reconnecting row, no wifi-off icon.
Future<void> _shootGameSeatMoved(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
}) async {
  final String scenario =
      'room $roomCode, locale ${locale.languageCode}, unsolicited '
      'BAD_SEAT_TOKEN then a far-side close';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openBareGame(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      roomCode: roomCode,
      seatToken: seatToken,
    );
    controller = opened.controller;
    await _takeSeatOver(tester, opened.transport);

    void expectCard(String moment) {
      expect(
        <Object?>[controller!.seatTakenOver, controller.phase],
        <Object?>[true, RoomPhase.closed],
        reason:
            'capture $shotName ($scenario) $moment: expected seatTakenOver '
            'true and phase closed, got ${controller.seatTakenOver}, '
            '${controller.phase}',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      expect(
        find.byKey(const Key('game-screen-connection-lost')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'game-screen-connection-lost on screen; the texts on screen are '
            '${_viewText(tester)}',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('game-screen-connection-lost')),
          matching: find.text(loc.seatMovedLine),
        ),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the card must say '
            '"${loc.seatMovedLine}"',
      );
      expect(
        find.text(loc.lobbyConnectionLost, skipOffstage: false),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: the plain title "'
            '${loc.lobbyConnectionLost}" is a false reason here',
      );
      expect(
        find.byKey(const Key('game-screen-leave-button')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: Leave is the one action',
      );
      for (final String gone in <String>[
        'game-screen-reconnect-button',
        'game-screen-reconnecting',
        'game-screen-error-message',
      ]) {
        expect(
          find.byKey(Key(gone), skipOffstage: false),
          findsNothing,
          reason:
              'capture $shotName ($scenario) $moment: $gone must not be '
              'drawn on the takeover card',
        );
      }
      expect(
        find.byIcon(Icons.phonelink_rounded),
        findsOneWidget,
        reason: 'capture $shotName ($scenario) $moment: the takeover icon',
      );
      expect(
        find.byIcon(Icons.wifi_off_rounded),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: the wifi-off icon belongs '
            'to the plain card',
      );
    }

    expectCard('right after the close');
    await _pumpRealDurationFrames(tester);
    expectCard('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 124 (order 552, C-547 D2 and A1). A host lobby holding its room, then the
/// same takeover. The gathering stays dimmed under the card; the card's Leave
/// carries `lobby-seat-moved-leave` and the header's corner close keeps
/// `lobby-leave-button`, one widget each.
Future<void> _shootLobbySeatMoved(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
}) async {
  final String scenario =
      'room $roomCode, locale ${locale.languageCode}, unsolicited '
      'BAD_SEAT_TOKEN then a far-side close';
  RoomController? controller;
  try {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();
    await (await SharedPreferences.getInstance()).clear();
    tester.platformDispatcher.clearTextScaleFactorTestValue();

    final FakeTransport transport = FakeTransport();
    controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Dee',
          players: 4,
        ),
        locale: locale,
      ),
    );
    await tester.pump();
    expect(
      transport.sentRaw,
      isNotEmpty,
      reason:
          'capture $shotName ($scenario): fixture is broken, '
          'LobbyScreen.initState must have sent create_room',
    );
    final String createId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
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
          'capture $shotName ($scenario): fixture is broken, the create '
          'reply must land connected, got ${controller.phase}',
    );

    await _takeSeatOver(tester, transport);

    void expectCard(String moment) {
      expect(
        <Object?>[controller!.seatTakenOver, controller.phase],
        <Object?>[true, RoomPhase.closed],
        reason:
            'capture $shotName ($scenario) $moment: expected seatTakenOver '
            'true and phase closed, got ${controller.seatTakenOver}, '
            '${controller.phase}',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(LobbyScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      expect(
        find.byKey(const Key('lobby-closed')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected lobby-closed '
            'on screen; the texts on screen are ${_viewText(tester)}',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-closed')),
          matching: find.text(loc.seatMovedLine),
        ),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the card must say '
            '"${loc.seatMovedLine}"',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-stale-room')),
          matching: find.byKey(const Key('lobby-room-code')),
        ),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the held room $roomCode '
            'must stay under the card inside lobby-stale-room',
      );
      expect(
        find.byKey(const Key('lobby-seat-moved-leave')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the card\'s Leave must '
            'carry lobby-seat-moved-leave',
      );
      expect(
        find.byKey(const Key('lobby-leave-button')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the header close alone '
            'carries lobby-leave-button',
      );
      for (final String gone in <String>[
        'lobby-reconnect-button',
        'lobby-reconnecting',
      ]) {
        expect(
          find.byKey(Key(gone), skipOffstage: false),
          findsNothing,
          reason:
              'capture $shotName ($scenario) $moment: $gone must not be '
              'drawn on the takeover card',
        );
      }
      expect(
        find.byIcon(Icons.wifi_off_rounded),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: the wifi-off icon belongs '
            'to the plain card',
      );
    }

    expectCard('right after the close');
    await _pumpRealDurationFrames(tester);
    expectCard('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 125 and 126 (order 552, C-549 D1). The capture 10 fixture, held open past
/// the slow-line threshold. The automatic attempt is five minutes away, so the
/// reconnecting row stays up for the whole wait. Every pump is a fixed 100 ms
/// frame: the turning mark never lets pumpAndSettle return.
Future<void> _shootGameReconnectingSlow(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
}) async {
  final String scenario =
      'room $roomCode, locale ${locale.languageCode}, transport dropped, '
      'automatic attempt 5 minutes out, 4.5 s of frames pumped';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openBareGame(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      roomCode: roomCode,
      seatToken: seatToken,
      autoReconnectDelays: const <Duration>[
        Duration(minutes: 5),
        Duration(minutes: 5),
      ],
    );
    controller = opened.controller;
    opened.transport.endFromFarSide();
    await tester.pump();
    await tester.pump();

    expect(
      <Object?>[controller.phase, controller.autoReconnectPending],
      <Object?>[RoomPhase.closed, true],
      reason:
          'capture $shotName ($scenario): fixture is broken, the drop must '
          'leave phase closed with an automatic attempt pending, got '
          '${controller.phase}, ${controller.autoReconnectPending}',
    );
    expect(
      find.byKey(const Key('game-screen-reconnecting')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): expected game-screen-reconnecting '
          'on screen when the row first appears',
    );
    expect(
      find.byKey(const Key('waiting-line-slow')),
      findsNothing,
      reason:
          'capture $shotName ($scenario): the slow line must not be drawn '
          'the moment the row first appears',
    );

    // 45 frames of 100 ms is the 4.5 s of fixture time; the finder wait
    // after it covers a timer that fires on the frame boundary.
    await _pumpRealDurationFrames(
      tester,
      frameCount: 45,
      frame: const Duration(milliseconds: 100),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('waiting-line-slow')),
      'capture $shotName ($scenario): waiting-line-slow after 4.5 s',
      maxPumps: 20,
      frame: const Duration(milliseconds: 100),
    );

    void expectSlowRow(String moment) {
      expect(
        <Object?>[controller!.phase, controller.autoReconnectPending],
        <Object?>[RoomPhase.closed, true],
        reason:
            'capture $shotName ($scenario) $moment: expected phase closed '
            'with the automatic attempt still pending, got '
            '${controller.phase}, ${controller.autoReconnectPending}; the '
            'sequence gave up or fired during the wait',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      expect(
        find.byKey(const Key('game-screen-connection-lost')),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'game-screen-connection-lost on screen',
      );
      final Finder row = find.byKey(const Key('game-screen-reconnecting'));
      expect(
        row,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'game-screen-reconnecting on screen',
      );
      expect(
        tester.widget<Text>(row).data,
        loc.lobbyReconnecting,
        reason:
            'capture $shotName ($scenario) $moment: the row must read '
            '"${loc.lobbyReconnecting}"',
      );
      final Finder slow = find.byKey(const Key('waiting-line-slow'));
      expect(
        slow,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'waiting-line-slow on screen after 4.5 s; the texts on screen '
            'are ${_viewText(tester)}',
      );
      expect(
        tester.widget<Text>(slow).data,
        loc.connectionSlowLine,
        reason:
            'capture $shotName ($scenario) $moment: the slow line must read '
            '"${loc.connectionSlowLine}"',
      );
      expect(
        find.byKey(const Key('game-screen-reconnect-button')),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: no Reconnect button '
            'while the automatic attempt is pending',
      );
    }

    expectSlowRow('after 4.5 s');
    await _pumpRealDurationFrames(tester);
    expectSlowRow('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 127 (order 552, C-549 D4). A PLAYING game whose next push skips seq 999:
/// the controller sets `hasDesynced` and the game screen's banner speaks
/// `gameCatchingUp`, not the lobby's resync wording. No seat token is
/// cached, so no resume goes out and no request timer is left running.
Future<void> _shootGameCatchingUp(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
}) async {
  final String scenario =
      'room $roomCode, locale ${locale.languageCode}, a presence push at '
      'seq 999 over a room at seq 1, no seat token';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openBareGame(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      roomCode: roomCode,
      seatToken: null,
    );
    controller = opened.controller;
    opened.transport.pushText(
      _frame(
        type: 'presence',
        data: const <String, Object?>{
          'seat': 2,
          'connected': false,
          'seq': 999,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    void expectBanner(String moment) {
      expect(
        controller!.hasDesynced,
        isTrue,
        reason:
            'capture $shotName ($scenario) $moment: the seq gap must leave '
            'hasDesynced true',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      final Finder banner = find.byKey(const Key('game-screen-desync-banner'));
      expect(
        banner,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'game-screen-desync-banner on screen; the texts on screen are '
            '${_viewText(tester)}',
      );
      expect(
        tester.widget<Text>(banner).data,
        loc.gameCatchingUp,
        reason:
            'capture $shotName ($scenario) $moment: the banner must read '
            '"${loc.gameCatchingUp}"',
      );
      expect(
        find.text(loc.lobbyDesynced, skipOffstage: false),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: the lobby wording "'
            '${loc.lobbyDesynced}" does not belong on the game screen',
      );
    }

    expectBanner('right after the gap');
    await _pumpRealDurationFrames(tester);
    expectBanner('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 128 and 129 (order 559, C-554 D1). A PLAYING game resumed into seat 0's
/// turn with `deadline_ms` 0: the count is at zero from the first frame, so
/// the ring keeps its error colour and the hourglass stands where the digits
/// were. The hourglass turns for as long as the count is zero, so nothing here
/// settles: every pump is a fixed frame.
Future<void> _shootGameTimeUp(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
}) async {
  final String scenario =
      'room $roomCode, locale ${locale.languageCode}, seat 0 to roll with '
      'deadline_ms 0';
  RoomController? controller;
  try {
    final _OpenedTrayGame opened = await _openBareGame(
      tester,
      binding,
      shotName: shotName,
      locale: locale,
      roomCode: roomCode,
      seatToken: seatToken,
      deadlineMs: 0,
    );
    controller = opened.controller;

    void expectTimeUp(String moment) {
      expect(
        <Object?>[
          controller!.seat,
          controller.room?.turn?.seat,
          controller.room?.turn?.deadlineMs,
        ],
        <Object?>[0, 0, 0],
        reason:
            'capture $shotName ($scenario) $moment: fixture is broken, '
            'expected this device (seat 0) to hold the turn with 0 ms left, '
            'got seat ${controller.seat}, turn ${controller.room?.turn?.seat}, '
            'deadline ${controller.room?.turn?.deadlineMs}',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      expect(
        find.byKey(const Key('game-screen-board')),
        findsOneWidget,
        reason: 'capture $shotName ($scenario) $moment: expected the board',
      );
      final Finder hourglass = find.byKey(const Key('game-screen-turn-timeup'));
      expect(
        hourglass,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'game-screen-turn-timeup in the ring; the texts on screen are '
            '${_viewText(tester)}',
      );
      expect(
        find.byKey(const Key('game-screen-turn-countdown')),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: the digits must be gone '
            'at zero',
      );
      final Icon icon = tester.widget<Icon>(hourglass);
      expect(
        <Object?>[icon.icon, icon.color],
        <Object?>[Icons.hourglass_bottom_rounded, LudoColors.error],
        reason:
            'capture $shotName ($scenario) $moment: expected the hourglass '
            'in LudoColors.error, got ${icon.icon}, ${icon.color}',
      );
      expect(
        find.byKey(const Key('game-header-countdown-ring')),
        findsOneWidget,
        reason: 'capture $shotName ($scenario) $moment: expected the ring',
      );
      expect(
        tester
            .widget<Semantics>(
              find.byKey(const Key('game-header-countdown-semantics')),
            )
            .properties
            .label,
        loc.gameTurnTimeUp,
        reason:
            'capture $shotName ($scenario) $moment: the countdown label must '
            'read "${loc.gameTurnTimeUp}"',
      );
    }

    expectTimeUp('right after the mount');
    double turned() => tester
        .widget<Transform>(
          find
              .ancestor(
                of: find.byKey(const Key('game-screen-turn-timeup')),
                matching: find.byType(Transform),
              )
              .first,
        )
        .transform
        .storage[0];
    final double before = turned();
    await _pumpRealDurationFrames(
      tester,
      frameCount: 3,
      frame: const Duration(milliseconds: 100),
    );
    // This job's emulator runs with animations removed, which is C-554 D1's
    // still hourglass; the motion jobs run with them on.
    final bool reduced = MediaQuery.disableAnimationsOf(
      tester.element(find.byKey(const Key('game-screen-turn-timeup'))),
    );
    expect(
      turned() != before,
      !reduced,
      reason:
          'capture $shotName ($scenario): the hourglass must turn, and stand '
          'still with animations removed (reduced $reduced); its rotation '
          'was $before and is ${turned()} after 300 ms of frames',
    );
    await _pumpRealDurationFrames(tester);
    expectTimeUp('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// 130 and 131 (order 559, C-555 D1 and D2). A host lobby holding its room.
/// A presence push skips to seq 999 and the controller sends a resume that
/// nobody answers; once the request times out on the live socket the banner
/// stays and the Resync button takes taps again. The capture is of the tap
/// after that: `controller.resync()` out on the same socket, a second resume
/// unanswered, the button disabled and its mark turning. The wait for the
/// timeout is a condition, not a sleep, and nothing settles while the mark
/// turns.
Future<void> _shootLobbyResyncing(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String roomCode,
  required String seatToken,
}) async {
  final String scenario =
      'room $roomCode, locale ${locale.languageCode}, a presence push at '
      'seq 999 over a room at seq 1, the first resume left unanswered until '
      'it times out, then one tap on Resync';
  RoomController? controller;
  FakeTransport? transport;
  try {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();
    await (await SharedPreferences.getInstance()).clear();
    tester.platformDispatcher.clearTextScaleFactorTestValue();

    transport = FakeTransport();
    final FakeTransport socket = transport;
    controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => socket,
    );
    final RoomController held = controller;
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        LobbyScreen(
          controller: held,
          action: LobbyAction.create,
          playerName: 'Dee',
          players: 4,
        ),
        locale: locale,
      ),
    );
    await tester.pump();
    expect(
      socket.sentRaw,
      isNotEmpty,
      reason:
          'capture $shotName ($scenario): fixture is broken, '
          'LobbyScreen.initState must have sent create_room',
    );
    final String createId = _idOf(socket.sentRaw.last);
    socket.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
      ),
    );
    socket.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: roomCode,
          players: 4,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Dee')],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      held.phase,
      RoomPhase.connected,
      reason:
          'capture $shotName ($scenario): fixture is broken, the create '
          'reply must land connected, got ${held.phase}',
    );

    int resumesSent() =>
        socket.sentRaw.where((String s) => _typeOf(s) == 'resume').length;

    socket.pushText(
      _frame(
        type: 'presence',
        data: const <String, Object?>{'seat': 0, 'connected': true, 'seq': 999},
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      <Object?>[held.hasDesynced, held.isResyncing, resumesSent()],
      <Object?>[true, true, 1],
      reason:
          'capture $shotName ($scenario): fixture is broken, the seq gap '
          'must leave hasDesynced true with one resume out, got '
          '${held.hasDesynced}, ${held.isResyncing}, ${resumesSent()} resumes',
    );

    // The resume goes unanswered. The request times out after its own ten
    // seconds on a socket that stays open: the banner stays, the controller
    // stops resyncing, and the phase stays connected.
    var waited = 0;
    while (held.isResyncing) {
      if (waited >= 130) {
        throw TestFailure(
          'capture $shotName ($scenario): the first resume was still in '
          'flight after $waited frames of 100 ms; the request timeout never '
          'settled it',
        );
      }
      await tester.pump(const Duration(milliseconds: 100));
      waited += 1;
    }
    expect(
      <Object?>[held.phase, held.hasDesynced, held.isResyncing],
      <Object?>[RoomPhase.connected, true, false],
      reason:
          'capture $shotName ($scenario): a resume that timed out on a live '
          'socket must leave phase connected and hasDesynced true with no '
          'resync in flight, got ${held.phase}, ${held.hasDesynced}, '
          '${held.isResyncing}',
    );

    final Finder button = find.byKey(const Key('lobby-resync-button'));
    expect(
      button,
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): expected lobby-resync-button '
          'after the first resume failed',
    );
    expect(
      tester.widget<OutlinedButton>(button).onPressed,
      isNotNull,
      reason:
          'capture $shotName ($scenario): C-555 D2, the button must take '
          'taps again once the resync failed without a verdict',
    );

    await tester.tap(button);
    await tester.pump();
    await tester.pump();

    final RotationTransition mark = tester.widget<RotationTransition>(
      find.descendant(of: button, matching: find.byType(RotationTransition)),
    );
    void expectResyncing(String moment) {
      expect(
        <Object?>[held.phase, held.hasDesynced, held.isResyncing],
        <Object?>[RoomPhase.connected, true, true],
        reason:
            'capture $shotName ($scenario) $moment: expected controller.'
            'resync() in flight on the live socket, got ${held.phase}, '
            '${held.hasDesynced}, ${held.isResyncing}',
      );
      expect(
        resumesSent(),
        2,
        reason:
            'capture $shotName ($scenario) $moment: the tap must send one '
            'more resume on the same socket, ${resumesSent()} sent in all',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(LobbyScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      final Finder banner = find.byKey(const Key('lobby-desync-banner'));
      expect(
        banner,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'lobby-desync-banner on screen; the texts on screen are '
            '${_viewText(tester)}',
      );
      expect(
        find.descendant(of: banner, matching: find.text(loc.lobbyDesynced)),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the banner must read '
            '"${loc.lobbyDesynced}"',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-resync-button')),
          matching: find.text(loc.lobbyResyncButton),
        ),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: the button must read '
            '"${loc.lobbyResyncButton}"',
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('lobby-resync-button')),
            )
            .onPressed,
        isNull,
        reason:
            'capture $shotName ($scenario) $moment: C-555 D2, the button '
            'must not take a tap while a resync is out',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('lobby-resync-button')),
          matching: find.byIcon(Icons.sync),
        ),
        findsOneWidget,
        reason: 'capture $shotName ($scenario) $moment: expected Icons.sync',
      );
      expect(
        mark.turns.isAnimating || mark.turns.value != 0,
        !_animationsRemoved(tester),
        reason:
            'capture $shotName ($scenario) $moment: the mark must turn, and '
            'stand still with animations removed '
            '(reduced ${_animationsRemoved(tester)}); its animation is '
            '${mark.turns.status} at ${mark.turns.value}',
      );
    }

    expectResyncing('right after the tap');
    final double turnedAt = mark.turns.value;
    await _pumpRealDurationFrames(
      tester,
      frameCount: 3,
      frame: const Duration(milliseconds: 100),
    );
    expect(
      mark.turns.value != turnedAt,
      !_animationsRemoved(tester),
      reason:
          'capture $shotName ($scenario): the sync mark must move between '
          'frames, and stand still with animations removed '
          '(reduced ${_animationsRemoved(tester)}); it was $turnedAt and is '
          '${mark.turns.value} after 300 ms',
    );
    await _pumpRealDurationFrames(tester);
    expectResyncing('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    // The second resume is still out; ending the socket fails it and cancels
    // its timer before the controller goes.
    transport?.endFromFarSide();
    await tester.pump();
    await _releaseTrayGame(tester, controller);
  }
}

/// 132 and 133 (order 559, C-549 D3 under large text; order 564, C-560 D4).
/// The lobby's connecting body before any reply: the `lobby-connecting-line`
/// with its one `waiting-line-mark` (no CircularProgressIndicator), the side
/// margin, "Connecting to the room..." and, after 4.5 s of frames, the slow
/// line, all at text scale 2.0. The mark turns, so nothing settles; the
/// frames are fixed 100 ms pumps. 133 is the same capture in Arabic, laid out
/// right to left.
Future<void> _shootLobbyConnectingLarge(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
}) async {
  final String scenario =
      'locale ${locale.languageCode}, create_room sent and unanswered, '
      'text scale 2.0, 4.5 s of frames pumped';
  RoomController? controller;
  try {
    binding.testTextInput.register();
    _stubScreenshotChannel(tester);
    await binding.convertFlutterSurfaceToImage();
    await (await SharedPreferences.getInstance()).clear();
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final FakeTransport transport = FakeTransport();
    controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    final RoomController held = controller;
    await tester.pumpWidget(
      _reconnectingCaptureHarness(
        LobbyScreen(
          controller: held,
          action: LobbyAction.create,
          playerName: 'Dee',
          players: 4,
        ),
        locale: locale,
      ),
    );
    await tester.pump();
    expect(
      transport.sentRaw.map(_typeOf).toList(),
      contains('create_room'),
      reason:
          'capture $shotName ($scenario): fixture is broken, '
          'LobbyScreen.initState must have sent create_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );

    expect(
      find.byKey(const Key('lobby-connecting')),
      findsOneWidget,
      reason:
          'capture $shotName ($scenario): expected lobby-connecting on '
          'screen when the lobby first mounts',
    );
    expect(
      find.byKey(const Key('waiting-line-slow')),
      findsNothing,
      reason:
          'capture $shotName ($scenario): the slow line must not be drawn '
          'the moment the body first appears',
    );

    // 45 frames of 100 ms is the 4.5 s of fixture time; the finder wait
    // after it covers a timer that fires on the frame boundary. The create
    // request's own ten seconds are far enough off to stay unanswered.
    await _pumpRealDurationFrames(
      tester,
      frameCount: 45,
      frame: const Duration(milliseconds: 100),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('waiting-line-slow')),
      'capture $shotName ($scenario): waiting-line-slow after 4.5 s',
      maxPumps: 20,
      frame: const Duration(milliseconds: 100),
    );

    void expectConnecting(String moment) {
      expect(
        <Object?>[held.room == null, held.phase],
        <Object?>[true, RoomPhase.connecting],
        reason:
            'capture $shotName ($scenario) $moment: expected no room and '
            'phase connecting, got room ${held.room?.code}, ${held.phase}',
      );
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(LobbyScreen)),
      );
      expect(
        loc.localeName,
        locale.languageCode,
        reason:
            'capture $shotName ($scenario) $moment: expected locale '
            '${locale.languageCode}, got ${loc.localeName}',
      );
      final Finder body = find.byKey(const Key('lobby-connecting'));
      expect(
        body,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'lobby-connecting on screen; the texts on screen are '
            '${_viewText(tester)}',
      );
      expect(
        find.descendant(
          of: body,
          matching: find.byKey(const Key('waiting-line-mark')),
        ),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected exactly one '
            'waiting-line-mark under lobby-connecting (C-560 D4)',
      );
      expect(
        find.descendant(
          of: body,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
        reason:
            'capture $shotName ($scenario) $moment: the spinner was removed '
            'by C-560 D4, found one under lobby-connecting',
      );
      final Finder line = find.byKey(const Key('lobby-connecting-line'));
      expect(
        find.descendant(of: body, matching: line),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'lobby-connecting-line under lobby-connecting; the texts on '
            'screen are ${_viewText(tester)}',
      );
      expect(
        find.descendant(of: line, matching: find.text(loc.lobbyConnecting)),
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: lobby-connecting-line '
            'must read "${loc.lobbyConnecting}"',
      );
      expect(
        Directionality.of(tester.element(body)),
        locale.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        reason:
            'capture $shotName ($scenario) $moment: the body must lay out in '
            'the locale\'s own direction',
      );
      final Finder slow = find.byKey(const Key('waiting-line-slow'));
      expect(
        slow,
        findsOneWidget,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'waiting-line-slow on screen after 4.5 s; the texts on screen '
            'are ${_viewText(tester)}',
      );
      expect(
        tester.widget<Text>(slow).data,
        loc.connectionSlowLine,
        reason:
            'capture $shotName ($scenario) $moment: the slow line must read '
            '"${loc.connectionSlowLine}"',
      );
      final double scaledTen = MediaQuery.textScalerOf(tester.element(body))
          .scale(10);
      expect(
        scaledTen,
        20.0,
        reason:
            'capture $shotName ($scenario) $moment: expected '
            'MediaQuery.textScalerOf at lobby-connecting to scale 10 to 20 '
            'under textScaleFactorTestValue = 2.0, got $scaledTen',
      );
    }

    expectConnecting('after 4.5 s');
    await _pumpRealDurationFrames(tester);
    expectConnecting('after the settle, before the capture');
    await _capture(binding, tester, shotName, frames: 0);
  } finally {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    await _releaseTrayGame(tester, controller);
  }
}

/// Whether the lobby resync captures run with the system's animations
/// removed (this job's emulator does; C-555 D2 then keeps the mark still).
bool _animationsRemoved(WidgetTester tester) => MediaQuery.disableAnimationsOf(
  tester.element(find.byKey(const Key('lobby-resync-button'))),
);

// ============================================================================
// Order 587 (captures 136-140): C-586 from recorded real games.
// ============================================================================

/// One dead roll of a recorded view, found at run time. [index] is the
/// `turn_passed` the recorder's `events` name for the viewer, [rolledIndex]
/// the `rolled` right before it and [turnIndex] the `turn` before that. The
/// face is single because that `turn` carried an empty queue: the client's
/// dead list is the queue the seat held plus the face just rolled
/// (`_resolveDeadCandidate`), here exactly [face].
class _RealDeadRoll {
  _RealDeadRoll({
    required this.eventOrdinal,
    required this.index,
    required this.rolledIndex,
    required this.turnIndex,
    required this.seat,
    required this.face,
    required this.skipped,
  });

  /// Position in the game's `events` list (all kinds, from 0).
  final int eventOrdinal;
  final int index;
  final int rolledIndex;
  final int turnIndex;
  final int seat;
  final int face;

  /// `no_legal_move` events by a seat that qualified on seat but whose
  /// frames are not a single-face roll straight off an empty queue, as
  /// "ordinal: reason", for the report.
  final List<String> skipped;

  @override
  String toString() =>
      'event $eventOrdinal, view index $index (rolled $rolledIndex, turn '
      '$turnIndex): seat $seat rolled $face with no legal move';
}

/// The first `no_legal_move` event of the recorded game that another seat
/// than [viewSeat] made ([bySeat] pins which, null takes any) whose frames in
/// the viewer's [view] are a single-face dead roll: a `turn` of that seat in
/// `await_roll` with an empty queue, the `rolled` with no `legal` and an empty
/// `queue`, the `turn_passed` with reason `no_legal_move`. The recorder's
/// `view_index` for the viewer names the `turn_passed`; the frames are read to
/// confirm it, never trusted.
_RealDeadRoll _locateRealDeadRoll(
  _RealGame game,
  List<Map<String, Object?>> view,
  int viewSeat, {
  required int? bySeat,
  required String where,
}) {
  final List<Object?> events = game.json['events']! as List<Object?>;
  final List<String> skipped = <String>[];
  for (var ordinal = 0; ordinal < events.length; ordinal++) {
    final Map<String, Object?> event = events[ordinal]! as Map<String, Object?>;
    final int seat = event['seat']! as int;
    if (event['kind'] != 'no_legal_move' ||
        seat == viewSeat ||
        (bySeat != null && seat != bySeat)) {
      continue;
    }
    final int index =
        (event['view_index']! as Map<String, Object?>)['$viewSeat']! as int;
    if (index < 2) {
      skipped.add('$ordinal: view index $index too early');
      continue;
    }
    Map<String, Object?> dataOf(int i) => view[i]['d']! as Map<String, Object?>;
    final bool passed =
        view[index]['t'] == 'turn_passed' &&
        dataOf(index)['seat'] == seat &&
        dataOf(index)['reason'] == 'no_legal_move';
    final bool rolled =
        view[index - 1]['t'] == 'rolled' &&
        dataOf(index - 1)['seat'] == seat &&
        (dataOf(index - 1)['legal']! as List<Object?>).isEmpty &&
        (dataOf(index - 1)['queue']! as List<Object?>).isEmpty;
    final bool turn =
        view[index - 2]['t'] == 'turn' &&
        dataOf(index - 2)['seat'] == seat &&
        dataOf(index - 2)['phase'] == 'await_roll' &&
        (dataOf(index - 2)['queue']! as List<Object?>).isEmpty;
    if (!passed || !rolled || !turn) {
      skipped.add(
        '$ordinal: frames at $index are not turn, rolled, turn_passed of '
        'seat $seat with empty queues (passed $passed, rolled $rolled, turn '
        '$turn)',
      );
      continue;
    }
    return _RealDeadRoll(
      eventOrdinal: ordinal,
      index: index,
      rolledIndex: index - 1,
      turnIndex: index - 2,
      seat: seat,
      face: dataOf(index - 1)['value']! as int,
      skipped: skipped,
    );
  }
  throw TestFailure(
    '$where: expected a single-face no_legal_move by '
    '${bySeat == null ? 'another seat' : 'seat $bySeat'} in the recorded '
    'events, found none (skipped $skipped)',
  );
}

/// The first `turn` of [turnSeat] in `await_roll` with an empty queue that
/// comes after the first `moved` of the view, so the board shows a game under
/// way and not four yards. Returns its index in [view].
int _locateRealAwaitRollTurn(
  List<Map<String, Object?>> view,
  int turnSeat, {
  required String where,
}) {
  final int firstMoved = view.indexWhere(
    (Map<String, Object?> f) => f['t'] == 'moved',
  );
  for (var i = firstMoved + 1; firstMoved != -1 && i < view.length; i++) {
    if (view[i]['t'] != 'turn') {
      continue;
    }
    final Map<String, Object?> d = view[i]['d']! as Map<String, Object?>;
    if (d['seat'] == turnSeat &&
        d['phase'] == 'await_roll' &&
        (d['queue']! as List<Object?>).isEmpty) {
      return i;
    }
  }
  throw TestFailure(
    '$where: expected a turn of seat $turnSeat in await_roll with an empty '
    'queue after the first moved of the recorded view, found none',
  );
}

/// The plain text of the `Text` at or under [finder].
String _textUnder(WidgetTester tester, Finder finder) {
  final Widget widget = tester.widget(finder);
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  final Finder inner = find.descendant(of: finder, matching: find.byType(Text));
  final Text text = tester.widget<Text>(inner.first);
  return text.data ?? text.textSpan?.toPlainText() ?? '';
}

/// Captures 136-138 (order 587, C-586 D1-D3; order 589t, C-589 D1). The device
/// is [viewerSeat] of the recorded game [gameName]; the first single-face
/// `no_legal_move` of [bySeat] (any other seat when null) is replayed: every
/// frame before its `rolled` goes in as one burst, the queued throws land,
/// then the `rolled` and the `turn_passed` behind it go in together, as the
/// server sends them. While the rolling seat's thrown die is in the air
/// nothing tells the watcher what the roll meant: straight after the push the
/// line, every badge and the viewer's own notice are absent. From the die's
/// landing (the seat die shows the face) the line under the die names the seat
/// and the seat's die wears the badge, for the 1500 ms hold measured from
/// that landing; the shot is taken inside 1200 ms of it.
Future<void> _shootWatcherDeadRoll(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String gameName,
  required int viewerSeat,
  int? bySeat,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final String capture = 'capture $shotName';
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: gameName,
    seat: viewerSeat,
    localeName: locale.languageCode,
  );
  final RoomController controller = entry.controller;
  final _RealDeadRoll found = _locateRealDeadRoll(
    entry.game,
    entry.view,
    viewerSeat,
    bySeat: bySeat,
    where: entry.where,
  );
  final String where = '${entry.where}; dead roll: $found';
  final List<String> lobbyRequests = entry.isHost
      ? <String>['create_room', 'start_game']
      : <String>['join_room'];
  int seqOf(int index) =>
      (entry.view[index]['d']! as Map<String, Object?>)['seq']! as int;

  // Everything before the roll in one burst, then the throws it queued land
  // and any hold they armed runs out, so the hold under test is the roll's.
  while (entry.next < found.rolledIndex) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; before the dead roll',
  );
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap before the dead roll',
  );
  expect(
    controller.room?.seq,
    seqOf(found.rolledIndex - 1),
    reason: '$where: the controller must have absorbed every frame before it',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: '$where: the replay must be in play at the dead roll',
  );

  // The roll and the pass behind it, together.
  final Stopwatch sincePush = Stopwatch()..start();
  while (entry.next <= found.index) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap after the dead roll',
  );
  expect(
    controller.room?.seq,
    seqOf(found.index),
    reason: '$where: the controller must have absorbed the turn_passed',
  );
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: the device must have sent only its own lobby requests; the '
        'replay plays every roll and move for it',
  );
  expect(
    controller.seat,
    viewerSeat,
    reason: '$where: viewer seat must be $viewerSeat',
  );
  expect(
    found.seat,
    isNot(viewerSeat),
    reason: '$where: the dead roll must be another seat\'s',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$where: expected locale ${locale.languageCode}, got ${loc.localeName}',
  );

  final String seatName = entry.game.nameOf(found.seat);
  final String expectedLine = loc.gameNoMoveOther(seatName);
  final List<int> seats = <int>[
    for (final SeatState s in controller.room!.seats) s.seat,
  ];
  // The absence of every other seat's badge and of the viewer's own notice
  // hold throughout; the line and the rolling seat's badge wait for the
  // landing (C-589 D1).
  void expectWatcherLine(String moment) {
    final Finder notice = find.byKey(const Key('game-no-move-other-notice'));
    expect(
      notice,
      findsOneWidget,
      reason:
          '$capture ($moment): C-586 D3, expected game-no-move-other-notice '
          'on screen for seat ${found.seat}\'s dead roll of ${found.face}, '
          'the line "$expectedLine". $where',
    );
    expect(
      _textUnder(tester, notice),
      expectedLine,
      reason:
          '$capture ($moment): C-586 D3, expected game-no-move-other-notice '
          'to read "$expectedLine" ($seatName, seat ${found.seat}). $where',
    );
    for (final int other in seats.where((int s) => s != found.seat)) {
      expect(
        find.byKey(Key('board-seat-die-dead-$other')),
        findsNothing,
        reason:
            '$capture ($moment): C-586 D2, only seat ${found.seat} rolled, '
            'so board-seat-die-dead-$other must not exist. $where',
      );
    }
    expect(
      find.byKey(const Key('game-no-move-notice')),
      findsNothing,
      reason:
          '$capture ($moment): C-586 D3, game-no-move-notice is the viewer\'s '
          'own line and seat ${found.seat} is not the viewer. $where',
    );
  }

  // C-589 D1: the dead roll's die is still in the air, so the watcher is told
  // nothing yet and no seat wears a badge.
  void expectWatcherNothingYet(String moment) {
    expect(
      find.byKey(Key('board-seat-die-face-${found.seat}-${found.face}')),
      findsNothing,
      reason:
          '$capture ($moment): fixture, seat ${found.seat}\'s die must still '
          'be in the air (no board-seat-die-face-${found.seat}-${found.face}) '
          'for the absence below to mean anything. $where',
    );
    expect(
      find.byKey(const Key('game-no-move-other-notice')),
      findsNothing,
      reason:
          '$capture ($moment): C-589 D1, expected game-no-move-other-notice '
          'ABSENT while seat ${found.seat}\'s die of ${found.face} is in the '
          'air; the line "$expectedLine" must wait for the landing. $where',
    );
    for (final int any in seats) {
      expect(
        find.byKey(Key('board-seat-die-dead-$any')),
        findsNothing,
        reason:
            '$capture ($moment): C-589 D1, expected no board-seat-die-dead-'
            '$any while the die is in the air. $where',
      );
    }
    expect(
      find.byKey(const Key('game-no-move-notice')),
      findsNothing,
      reason:
          '$capture ($moment): C-589 D1, game-no-move-notice is the viewer\'s '
          'own line and seat ${found.seat} is not the viewer. $where',
    );
  }

  void expectWatcherView(String moment) {
    expectWatcherLine(moment);
    expect(
      find.byKey(Key('board-seat-die-dead-${found.seat}')),
      findsOneWidget,
      reason:
          '$capture ($moment): C-586 D2, expected board-seat-die-dead-'
          '${found.seat} on seat ${found.seat}\'s die for a single dead face '
          '${found.face}. $where',
    );
  }

  // The hurried throw takes about 250 ms, so a device that draws a frame every
  // 700 ms has landed the die before the first check. The seat die's face is
  // already on the board then and "nothing yet" cannot mean anything: skip it
  // and say so. The pre-landing property is proven frame by frame in
  // watcher_dead_roll_test.dart (C-589 (a)); everything from the landing on
  // runs in both branches.
  final Finder landedFace = find.byKey(
    Key('board-seat-die-face-${found.seat}-${found.face}'),
  );
  int landedAtMs = -1;
  if (landedFace.evaluate().isEmpty) {
    expectWatcherNothingYet('straight after the roll and the pass');
  } else {
    // The landing was not seen: this first sighting is the time taken, so the
    // age checked below can read short by up to that much on such a device.
    landedAtMs = sincePush.elapsedMilliseconds;
    // ignore: avoid_print
    print(
      'screenshots_test: $capture seat ${found.seat}\'s die had landed before '
      'the first frame was checked, $landedAtMs ms after the push; skipping '
      'the in-the-air check, the landing checks still run. $where',
    );
  }

  // The turn_passed hurries the dead roll's thrown die and the seat die stays
  // back until the throw has landed (C-465 D2). The landing is the frame on
  // which the seat die shows the face; each pump is timed from before it ran,
  // so the landing time taken is never later than the real one and the age
  // checked below is never short. Nothing may show before it.
  while (landedAtMs < 0) {
    final int before = sincePush.elapsedMilliseconds;
    if (before >= 10000) {
      fail(
        '$capture: expected seat ${found.seat}\'s die to land (the seat die '
        'shows ${found.face}) within 10 s of the roll, still in the air after '
        '$before ms. $where',
      );
    }
    await tester.pump(const Duration(milliseconds: 16));
    if (landedFace.evaluate().isNotEmpty) {
      landedAtMs = before;
    } else {
      expectWatcherNothingYet('in the air, $before ms after the push');
    }
  }
  expectWatcherView('at the landing, $landedAtMs ms after the push');

  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; waiting for the dead roll\'s die to leave the board',
  );
  expectWatcherView(
    'after the thrown die left, ${sincePush.elapsedMilliseconds - landedAtMs} '
    'ms after the landing',
  );

  // A few real-duration frames so the surface has painted the landed view.
  await _pumpRealDurationFrames(tester, frameCount: 4);
  expectWatcherView('immediately before the shot');
  final int ageMs = sincePush.elapsedMilliseconds - landedAtMs;
  expect(
    ageMs,
    lessThan(1200),
    reason:
        '$capture: expected the shot within 1200 ms of the landing, got '
        '$ageMs ms by wall time; the hold is 1500 ms from the landing. $where',
  );
  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "$gameName" from seat $viewerSeat '
    'to $found; skipped events ${found.skipped}; landed at $landedAtMs ms '
    'after the push, shot $ageMs ms after the landing; ${entry.re.pushed} '
    'frames pushed',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

/// Captures 139 and 140 (order 587, C-586 D6). The device is [viewerSeat] of
/// the recorded game [gameName]; the first `turn` of [turnSeat] in
/// `await_roll` after the game is under way is pushed on its own (everything
/// before it first, the throws landed) and the recorded clock, 45 s, runs in
/// real time until the digits read 10. At the start the warning wrapper is
/// absent; at 10 it exists, the ring and the digits sit under it and the
/// digits read 10 or less. The wait is bounded by the recorded deadline.
Future<void> _shootCountdownWarning(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required String gameName,
  required int viewerSeat,
  required int turnSeat,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final String capture = 'capture $shotName';
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: gameName,
    seat: viewerSeat,
    localeName: locale.languageCode,
  );
  final RoomController controller = entry.controller;
  final int turnIndex = _locateRealAwaitRollTurn(
    entry.view,
    turnSeat,
    where: entry.where,
  );
  final Map<String, Object?> turnData =
      entry.view[turnIndex]['d']! as Map<String, Object?>;
  final int recordedDeadlineMs = turnData['deadline_ms']! as int;
  final int recordedSeconds = (recordedDeadlineMs + 999) ~/ 1000;
  final String where =
      '${entry.where}; turn of seat $turnSeat in await_roll at view index '
      '$turnIndex, deadline_ms $recordedDeadlineMs';
  final List<String> lobbyRequests = entry.isHost
      ? <String>['create_room', 'start_game']
      : <String>['join_room'];
  int seqOf(int index) =>
      (entry.view[index]['d']! as Map<String, Object?>)['seq']! as int;
  expect(
    recordedSeconds,
    greaterThan(10),
    reason:
        '$where: the recorded turn must start with more than 10 s on the '
        'clock for the last 10 s to be reached in real time',
  );

  // Everything before the turn in one burst, the throws landed, then the turn
  // alone, so its clock starts with the recorded whole segment.
  while (entry.next < turnIndex) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; before the turn',
  );
  expect(
    controller.room?.seq,
    seqOf(turnIndex - 1),
    reason: '$where: the controller must have absorbed every frame before it',
  );
  entry.push();
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap after the turn',
  );
  expect(
    controller.room?.seq,
    seqOf(turnIndex),
    reason: '$where: the controller must have absorbed the turn frame',
  );
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: the device must have sent only its own lobby requests; the '
        'replay plays every roll and move for it',
  );
  expect(
    controller.seat,
    viewerSeat,
    reason: '$where: viewer seat must be $viewerSeat',
  );
  final TurnStateSnapshot turn = _turnOf(controller);
  expect(
    <Object>[turn.seat, turn.phaseName],
    <Object>[turnSeat, 'awaitRoll'],
    reason:
        '$where: expected seat $turnSeat awaiting a roll, got seat '
        '${turn.seat} in ${turn.phaseName}',
  );
  expect(
    controller.room!.turn!.deadlineMs,
    recordedDeadlineMs,
    reason: '$where: the turn must carry the recorded deadline_ms',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$where: expected locale ${locale.languageCode}, got ${loc.localeName}',
  );

  final Finder digits = find.byKey(const Key('game-screen-turn-countdown'));
  final Finder ring = find.byKey(const Key('game-header-countdown-ring'));
  final Finder warning = find.byKey(const Key('game-header-countdown-warning'));
  String shownDigits() => _textUnder(tester, digits);
  int? shownSeconds() {
    final String shown = shownDigits();
    for (var n = 0; n <= recordedSeconds; n++) {
      if (loc.gameTurnCountdownDigits(n) == shown) {
        return n;
      }
    }
    return null;
  }

  expect(
    digits,
    findsOneWidget,
    reason: '$capture: expected the countdown digits. $where',
  );
  expect(
    ring,
    findsOneWidget,
    reason: '$capture: expected the countdown ring. $where',
  );
  expect(
    shownDigits(),
    loc.gameTurnCountdownDigits(recordedSeconds),
    reason:
        '$capture: expected the clock to open at the recorded '
        '$recordedSeconds, got "${shownDigits()}". $where',
  );
  expect(
    warning,
    findsNothing,
    reason:
        '$capture: C-586 D6, game-header-countdown-warning must not exist '
        'with $recordedSeconds s left. $where',
  );

  // Real time, frame by frame, until the digits read 10. Bounded by the
  // recorded segment plus a margin, so a clock that never ticks fails with
  // what it last showed.
  final String targetDigits = loc.gameTurnCountdownDigits(10);
  final Stopwatch waited = Stopwatch()..start();
  final Duration limit = Duration(milliseconds: recordedDeadlineMs + 5000);
  while (shownDigits() != targetDigits && waited.elapsed < limit) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    shownDigits(),
    targetDigits,
    reason:
        '$capture: expected the digits to read "$targetDigits" within '
        '${limit.inSeconds} s, last read "${shownDigits()}" after '
        '${waited.elapsedMilliseconds} ms. $where',
  );

  void expectWarning(String moment) {
    final int? seconds = shownSeconds();
    expect(
      seconds != null && seconds <= 10,
      isTrue,
      reason:
          '$capture ($moment): expected the digits to read 10 or less, got '
          '"${shownDigits()}". $where',
    );
    expect(
      warning,
      findsOneWidget,
      reason:
          '$capture ($moment): C-586 D6, expected '
          'game-header-countdown-warning with $seconds s left on seat '
          '$turnSeat\'s turn. $where',
    );
    expect(
      find.descendant(of: warning, matching: ring),
      findsOneWidget,
      reason:
          '$capture ($moment): C-586 D6, expected game-header-countdown-ring '
          'under game-header-countdown-warning. $where',
    );
    expect(
      find.descendant(of: warning, matching: digits),
      findsOneWidget,
      reason:
          '$capture ($moment): C-586 D6, expected game-screen-turn-countdown '
          'under game-header-countdown-warning. $where',
    );
  }

  expectWarning('digits at 10');

  // About 300 ms into the beat, as 89 and 90 do after their tick.
  await _pumpRealDurationFrames(tester, frameCount: 6);
  expectWarning('after the ~190ms settle, immediately before the shot');
  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "$gameName" from seat $viewerSeat '
    'to the turn of seat $turnSeat at view index $turnIndex; the clock took '
    '${waited.elapsedMilliseconds} ms from $recordedSeconds to 10; '
    '${entry.re.pushed} frames pushed',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

/// The first `turn` of [turnSeat] in `await_roll` after the first `moved` of
/// [view] that follows an extra roll the seat earned: a `rolled` six of the
/// same seat that left a roll owed (a non-empty `queue`), or a `moved` of the
/// same seat with `extra_roll` true that struck a token or reached home.
/// Returns the index of that `turn` and the cause (`six`, `capture` or
/// `home`); the cause frame is the one right before it.
(int turnIndex, String cause) _locateRealExtraRollTurn(
  List<Map<String, Object?>> view,
  int turnSeat, {
  required String where,
}) {
  final int firstMoved = view.indexWhere(
    (Map<String, Object?> f) => f['t'] == 'moved',
  );
  for (var i = firstMoved + 1; firstMoved != -1 && i < view.length; i++) {
    if (view[i]['t'] != 'turn') {
      continue;
    }
    final Map<String, Object?> d = view[i]['d']! as Map<String, Object?>;
    if (d['seat'] != turnSeat || d['phase'] != 'await_roll') {
      continue;
    }
    final Map<String, Object?> before = view[i - 1];
    final Map<String, Object?> b = before['d']! as Map<String, Object?>;
    if (b['seat'] != turnSeat) {
      continue;
    }
    if (before['t'] == 'rolled' &&
        b['value'] == 6 &&
        (b['queue']! as List<Object?>).isNotEmpty) {
      return (i, 'six');
    }
    if (before['t'] == 'moved' && b['extra_roll'] == true) {
      if ((b['captured']! as List<Object?>).isNotEmpty) {
        return (i, 'capture');
      }
      if (b['to'] == 57) {
        return (i, 'home');
      }
    }
  }
  throw TestFailure(
    '$where: expected a turn of seat $turnSeat in await_roll right behind an '
    'extra roll (a six, a capture or a token home) of that seat after the '
    'first moved of the recorded view, found none',
  );
}

/// Captures 141-143 (order 593, C-590 D2 and D3). The device is [viewerSeat]
/// of the recorded game four_seats_1 and enters it as a guest. The recorded
/// `turn` of [turnSeat] in `await_roll` (the first one after the game is under
/// way; for [extraRoll] the first one right behind a six, a capture or a token
/// home of that seat) is pushed with the roll that earned it, everything before
/// it first in one burst with the throws landed. Then the banner reads the line
/// [expectedLine] builds for the seat on turn, the strip's turn pip holds that
/// seat's pip and the ringed next pip holds [nextSeat]'s.
Future<void> _shootNextSeat(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int viewerSeat,
  required int turnSeat,
  required int nextSeat,
  required bool extraRoll,
  required String Function(AppLocalizations loc, String turnName) expectedLine,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final String capture = 'capture $shotName';
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: 'four_seats_1',
    seat: viewerSeat,
    localeName: locale.languageCode,
  );
  final RoomController controller = entry.controller;
  expect(
    entry.isHost,
    isFalse,
    reason: '${entry.where}: the viewer of $shotName is a guest',
  );

  // The fixture's own seat order says who plays after [turnSeat].
  final List<int> order = <int>[
    for (final Object? s in entry.game.json['seats']! as List<Object?>)
      s! as int,
  ]..sort();
  expect(
    order[(order.indexOf(turnSeat) + 1) % order.length],
    nextSeat,
    reason:
        '${entry.where}: the recorded seats $order put seat '
        '${order[(order.indexOf(turnSeat) + 1) % order.length]} after seat '
        '$turnSeat, the capture was ordered with seat $nextSeat',
  );

  final int turnIndex;
  final String cause;
  if (extraRoll) {
    (turnIndex, cause) = _locateRealExtraRollTurn(
      entry.view,
      turnSeat,
      where: entry.where,
    );
  } else {
    turnIndex = _locateRealAwaitRollTurn(
      entry.view,
      turnSeat,
      where: entry.where,
    );
    cause = 'none';
  }
  // The frame that earned the extra roll goes in with the turn, as the server
  // sends them; everything before goes in as one burst.
  final int burstEnd = extraRoll ? turnIndex - 1 : turnIndex;
  final String where =
      '${entry.where}; turn of seat $turnSeat in await_roll at view index '
      '$turnIndex (extra roll cause: $cause)';
  final List<String> lobbyRequests = <String>['join_room'];
  int seqOf(int index) =>
      (entry.view[index]['d']! as Map<String, Object?>)['seq']! as int;

  while (entry.next < burstEnd) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; before the turn',
  );
  expect(
    controller.room?.seq,
    seqOf(burstEnd - 1),
    reason: '$where: the controller must have absorbed every frame before it',
  );
  while (entry.next <= turnIndex) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap after the turn',
  );
  expect(
    controller.room?.seq,
    seqOf(turnIndex),
    reason: '$where: the controller must have absorbed the turn frame',
  );
  expect(
    entry.transport.sentRaw.map(_typeOf).toList(),
    lobbyRequests,
    reason:
        '$where: the device must have sent only its own lobby requests; the '
        'replay plays every roll and move for it',
  );
  expect(
    controller.seat,
    viewerSeat,
    reason: '$where: viewer seat must be $viewerSeat',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: '$where: the replay must be in play',
  );
  final TurnStateSnapshot turn = _turnOf(controller);
  expect(
    <Object>[turn.seat, turn.phaseName],
    <Object>[turnSeat, 'awaitRoll'],
    reason:
        '$where: expected seat $turnSeat awaiting a roll, got seat '
        '${turn.seat} in ${turn.phaseName}',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$where: expected locale ${locale.languageCode}, got ${loc.localeName}',
  );

  // The thrown dice leave the board; the banner holds the line it had until
  // the roll that earned the turn has landed, so wait for the expected line
  // on a bounded condition and name what was on screen if it never comes.
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; waiting for the last thrown die to leave the board',
  );
  final String turnName = entry.game.nameOf(turnSeat);
  final String expected = expectedLine(loc, turnName);
  final Finder banner = find.byKey(const Key('game-screen-turn-banner'));
  String shownBanner() =>
      banner.evaluate().isEmpty ? '(no banner)' : _textUnder(tester, banner);
  final Stopwatch waited = Stopwatch()..start();
  while (shownBanner() != expected && waited.elapsedMilliseconds < 10000) {
    await tester.pump(const Duration(milliseconds: 50));
  }

  void expectNextSeatView(String moment) {
    expect(
      shownBanner(),
      expected,
      reason:
          '$capture ($moment): expected game-screen-turn-banner to read '
          '"$expected" (seat $viewerSeat watching seat $turnSeat '
          '($turnName), seat $nextSeat plays next), it reads '
          '"${shownBanner()}" after ${waited.elapsedMilliseconds} ms. $where',
    );
    final Finder nextPip = find.byKey(const Key('game-seat-pip-next'));
    expect(
      nextPip,
      findsOneWidget,
      reason:
          '$capture ($moment): C-590 D2, expected game-seat-pip-next on the '
          'strip. $where',
    );
    expect(
      find.descendant(
        of: nextPip,
        matching: find.byKey(Key('game-seat-pip-$nextSeat')),
      ),
      findsOneWidget,
      reason:
          '$capture ($moment): C-590 D2, expected game-seat-pip-next to '
          'contain game-seat-pip-$nextSeat. $where',
    );
    final Finder turnPip = find.byKey(const Key('game-seat-pip-turn'));
    expect(
      turnPip,
      findsOneWidget,
      reason:
          '$capture ($moment): expected game-seat-pip-turn on the strip. '
          '$where',
    );
    expect(
      find.descendant(
        of: turnPip,
        matching: find.byKey(Key('game-seat-pip-$turnSeat')),
      ),
      findsOneWidget,
      reason:
          '$capture ($moment): expected game-seat-pip-turn to contain '
          'game-seat-pip-$turnSeat. $where',
    );
  }

  expectNextSeatView('after the turn landed');
  await _pumpRealDurationFrames(tester, frameCount: 6);
  expectNextSeatView('after the ~190ms settle, immediately before the shot');
  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "four_seats_1" from seat $viewerSeat '
    'to the turn of seat $turnSeat at view index $turnIndex (extra roll '
    'cause: $cause); banner "${shownBanner()}", next seat $nextSeat; '
    '${entry.re.pushed} frames pushed',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

/// Captures 144 and 145 (order 593, C-591 D2 and D3). The device is
/// [viewerSeat] of the recorded game four_seats_1; the recorded frames play
/// through `game_over`, then the rematch LOBBY is built the way capture 24
/// builds one: the host's own tap on Play again when the device is the host
/// (the server's reply puts the host alone in `rematch.ready`), the host's
/// unprompted `room` push when it is not, and then one more `room` push with
/// [readySeats] in `ready`. The LOBBY frames are protocol frames after the
/// recorded game, not edits of a recorded one.
///
/// A host device sees `end-card-rematch-sits-out` naming the seats not in
/// `ready` in seat order, above `end-card-rematch-start`. A guest device that
/// is not in `ready` sees `end-card-rematch-may-start` above
/// `end-card-rematch`.
Future<void> _shootRematchWarning(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int viewerSeat,
  required List<int> readySeats,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final String capture = 'capture $shotName';
  final _RealReplay replay = await _replayRealGame(
    tester,
    factory,
    capture: capture,
    gameName: 'four_seats_1',
    seat: viewerSeat,
    localeName: locale.languageCode,
    seatAllBeforeStart: true,
  );
  final RoomController controller = replay.controller;
  final FakeTransport transport = replay.transport;
  final _RealGame game = replay.game;
  final String where = replay.describe;
  final int hostSeat =
      (game.view(viewerSeat)[1]['d']! as Map<String, Object?>)['host_seat']!
          as int;
  final bool viewerIsHost = hostSeat == viewerSeat;
  final List<int> seats = <int>[
    for (final Object? s in game.json['seats']! as List<Object?>) s! as int,
  ]..sort();
  expect(
    seats,
    hasLength(4),
    reason: '$where: the rematch frames need the four seated seats',
  );
  expect(
    readySeats.first,
    hostSeat,
    reason: '$where: the first seat in ready is the host (seat $hostSeat)',
  );
  expect(
    readySeats.toSet().length,
    2,
    reason:
        '$where: the host and exactly one other seat are in; got $readySeats',
  );
  expect(
    readySeats.contains(viewerSeat),
    viewerIsHost,
    reason:
        '$where: only the host device is in ready; viewer seat $viewerSeat, '
        'host seat $hostSeat, ready $readySeats',
  );
  expect(
    _scriptedRolls(controller, viewerSeat),
    replay.counts.rolls,
    reason: '$capture: rolls counted from the replayed frames ($where)',
  );
  expect(
    _scriptedHome(controller, viewerSeat),
    replay.counts.home,
    reason: '$capture: tokens home on the replayed board ($where)',
  );

  replay.pushGameOver();
  await tester.pump();
  await tester.pump();
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$capture: expected locale ${locale.languageCode}, got '
        '${loc.localeName}',
  );
  expect(
    controller.room?.state,
    RoomState.finished,
    reason: '$capture: game_over must finish the room. $where',
  );
  expect(
    controller.room?.winner,
    game.winner,
    reason: '$capture: the recorded winner is seat ${game.winner}. $where',
  );

  Map<String, Object?> rematchRoom(int seq, List<int> ready) =>
      <String, Object?>{
        ..._roomJson(
          code: replay.roomCode,
          state: 'LOBBY',
          hostSeat: hostSeat,
          players: seats.length,
          seats: <Map<String, Object?>>[
            for (final int s in seats) _seatJson(s, name: game.nameOf(s)),
          ],
          seq: seq,
        ),
        'rematch': <String, Object?>{'by': hostSeat, 'ready': ready},
      };

  // The host asks for the rematch itself; a guest meets the host's ask as an
  // unprompted push.
  int seq = replay.gameOverSeq + 1;
  if (viewerIsHost) {
    final Finder ask = find.byKey(const Key('end-card-rematch'));
    expect(
      ask,
      findsOneWidget,
      reason: '$capture: end-card-rematch must be on the finished card. $where',
    );
    await tester.tap(ask);
    await tester.pump();
    final List<String> rematches = transport.sentRaw
        .where((String s) => _typeOf(s) == 'rematch')
        .toList();
    expect(
      rematches,
      hasLength(1),
      reason:
          '$capture: tapping end-card-rematch must send exactly one rematch '
          'frame; sent ${transport.sentRaw.map(_typeOf).toList()}. $where',
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(rematches.single),
        data: rematchRoom(seq, <int>[hostSeat]),
      ),
    );
  } else {
    transport.pushText(
      _frame(type: 'room', data: rematchRoom(seq, <int>[hostSeat])),
    );
  }
  await tester.pump();
  await tester.pump();
  seq += 1;
  transport.pushText(_frame(type: 'room', data: rematchRoom(seq, readySeats)));
  await tester.pump();
  await tester.pump();

  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$capture: seq gap in the rematch frames. $where',
  );
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: '$capture: the rematch LOBBY stays on GameScreen. $where',
  );
  expect(
    controller.room?.state,
    RoomState.lobby,
    reason: '$capture: the rematch frames put the room in LOBBY. $where',
  );
  expect(
    controller.room?.rematch?.ready,
    unorderedEquals(readySeats),
    reason: '$capture: rematch.ready after the pushes. $where',
  );
  for (final int s in seats) {
    expect(
      find.byKey(Key('end-card-ready-$s')),
      findsOneWidget,
      reason: '$capture: end-card-ready-$s for occupied seat $s. $where',
    );
  }
  await _pumpRealDurationFrames(tester);

  double topOf(String key) => tester.getRect(find.byKey(Key(key))).top;
  double bottomOf(String key) => tester.getRect(find.byKey(Key(key))).bottom;

  if (viewerIsHost) {
    final List<String> sitOut = <String>[
      for (final int s in seats)
        if (!readySeats.contains(s)) game.nameOf(s),
    ];
    final String expected = loc.endRematchSitsOut(sitOut.join(', '));
    expect(
      find.byKey(const Key('end-card-rematch-start')),
      findsOneWidget,
      reason:
          '$capture: the host with $readySeats in must be offered Start '
          '(end-card-rematch-start). $where',
    );
    final Finder line = find.byKey(const Key('end-card-rematch-sits-out'));
    expect(
      line,
      findsOneWidget,
      reason:
          '$capture: C-591 D3, expected end-card-rematch-sits-out naming '
          '$sitOut above the host\'s Start. $where',
    );
    expect(
      _textUnder(tester, line),
      expected,
      reason:
          '$capture: C-591 D3, expected end-card-rematch-sits-out to read '
          '"$expected" (seats not in $readySeats, in seat order). $where',
    );
    expect(
      bottomOf('end-card-rematch-sits-out'),
      lessThanOrEqualTo(topOf('end-card-rematch-start')),
      reason:
          '$capture: C-591 D3, expected end-card-rematch-sits-out above '
          'end-card-rematch-start; line bottom '
          '${bottomOf('end-card-rematch-sits-out')}, Start top '
          '${topOf('end-card-rematch-start')}. $where',
    );
    expect(
      find.byKey(const Key('end-card-rematch-may-start')),
      findsNothing,
      reason:
          '$capture: the host is in, the may-start line is for a seat that '
          'is not. $where',
    );
  } else {
    expect(
      find.byKey(const Key('end-card-rematch')),
      findsOneWidget,
      reason:
          '$capture: seat $viewerSeat is not in $readySeats, so Play again '
          '(end-card-rematch) must be on the card. $where',
    );
    final Finder line = find.byKey(const Key('end-card-rematch-may-start'));
    expect(
      line,
      findsOneWidget,
      reason:
          '$capture: C-591 D2, expected end-card-rematch-may-start for seat '
          '$viewerSeat while the host (seat $hostSeat) and one more are in '
          '$readySeats. $where',
    );
    expect(
      _textUnder(tester, line),
      loc.endRematchMayStartWithout,
      reason:
          '$capture: C-591 D2, expected end-card-rematch-may-start to read '
          '"${loc.endRematchMayStartWithout}". $where',
    );
    expect(
      bottomOf('end-card-rematch-may-start'),
      lessThanOrEqualTo(topOf('end-card-rematch')),
      reason:
          '$capture: C-591 D2, expected end-card-rematch-may-start above '
          'end-card-rematch; line bottom '
          '${bottomOf('end-card-rematch-may-start')}, Play again top '
          '${topOf('end-card-rematch')}. $where',
    );
    expect(
      find.byKey(const Key('end-card-rematch-sits-out')),
      findsNothing,
      reason: '$capture: the sits-out line is the host\'s. $where',
    );
  }
  _expectScriptedEndCardTiles(
    tester,
    capture: capture,
    rolls: replay.counts.rolls,
    home: replay.counts.home,
  );
  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "four_seats_1" from seat $viewerSeat '
    '(host seat $hostSeat) to game_over, then a rematch LOBBY with ready '
    '$readySeats; ${replay.re.pushed} recorded frames pushed',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

/// Captures 146a, 146 and 147 (order 594, C-592 D2 and C-591). The device is
/// seat 3 of the recorded game four_seats_1, a guest; the recorded frames play
/// through `game_over`. The rematch LOBBY then grows by protocol frames the way
/// captures 144 and 145 build one: the host (seat 0) is in, then seat 1. The
/// card the device sees there carries `end-card-rematch-may-start` above Play
/// again (C-591 D2): with [toTheStart] false that is the shot (146a).
///
/// With [toTheStart] the device taps Play again (the server's reply puts it in
/// `ready` after seats 0 and 1), seat 2 never answers, and the host starts the
/// game with three: `player_left` for seat 2, `seat_assigned` moving the device
/// from seat 3 to seat 2, the re-seating `room`, `game_started` and the first
/// `turn`. The seat-moved notice (`game-seat-moved-notice`) reads
/// `gameSeatMoved('yellow')` (seat 2's colour), holds seat 2's `SeatMark`, and
/// the device's own yard is seat 2's; the shot is inside the 4000 ms hold,
/// after the entrance veil has gone.
Future<void> _shootSeatMoved(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required bool toTheStart,
}) async {
  const int viewerSeat = 3;
  const int sitsOutSeat = 2;
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);

  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  final String capture = 'capture $shotName';
  final _RealReplay replay = await _replayRealGame(
    tester,
    factory,
    capture: capture,
    gameName: 'four_seats_1',
    seat: viewerSeat,
    localeName: locale.languageCode,
  );
  final RoomController controller = replay.controller;
  final FakeTransport transport = replay.transport;
  final _RealGame game = replay.game;
  final String where = replay.describe;
  final int hostSeat =
      (game.view(viewerSeat)[1]['d']! as Map<String, Object?>)['host_seat']!
          as int;
  final List<int> seats = <int>[
    for (final Object? s in game.json['seats']! as List<Object?>) s! as int,
  ]..sort();
  expect(
    <Object>[hostSeat, seats],
    <Object>[
      0,
      <int>[0, 1, 2, 3],
    ],
    reason: '$where: the capture needs host 0 at a table of four',
  );
  expect(
    controller.seat,
    viewerSeat,
    reason: '$where: the device plays seat $viewerSeat',
  );
  final int framesBeforeOver = replay.re.pushed;

  replay.pushGameOver();
  await tester.pump();
  await tester.pump();
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$capture: expected locale ${locale.languageCode}, got '
        '${loc.localeName}',
  );
  expect(
    controller.room?.state,
    RoomState.finished,
    reason: '$capture: game_over must finish the room. $where',
  );

  // Protocol frames after the recorded game, never edits of a recorded one.
  int seq = replay.gameOverSeq;
  Map<String, Object?> lobbyRoom(
    List<int> present,
    List<int> ready, {
    int by = 0,
    int? moveSeatOf,
    int? moveSeatTo,
  }) {
    seq += 1;
    return <String, Object?>{
      ..._roomJson(
        code: replay.roomCode,
        state: 'LOBBY',
        hostSeat: by,
        players: present.length,
        seats: <Map<String, Object?>>[
          for (final int s in present)
            _seatJson(s == moveSeatOf ? moveSeatTo! : s, name: game.nameOf(s)),
        ],
        seq: seq,
      ),
      'chain_index': 1,
      'rematch': <String, Object?>{'by': by, 'ready': ready},
    };
  }

  // The host asks, then seat 1 is in: the device is not, and the host and one
  // more could start without it.
  transport.pushText(_frame(type: 'room', data: lobbyRoom(seats, <int>[0])));
  await tester.pump();
  await tester.pump();
  transport.pushText(_frame(type: 'room', data: lobbyRoom(seats, <int>[0, 1])));
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$capture: seq gap in the rematch frames. $where',
  );
  expect(
    controller.room?.rematch?.ready,
    unorderedEquals(<int>[0, 1]),
    reason: '$capture: rematch.ready before the device answers. $where',
  );
  await _pumpRealDurationFrames(tester);

  final Finder mayStart = find.byKey(const Key('end-card-rematch-may-start'));
  expect(
    mayStart,
    findsOneWidget,
    reason:
        '$capture: C-591 D2, expected end-card-rematch-may-start for seat '
        '$viewerSeat while the host (seat $hostSeat) and seat 1 are in. '
        '$where',
  );
  expect(
    _textUnder(tester, mayStart),
    loc.endRematchMayStartWithout,
    reason:
        '$capture: C-591 D2, expected end-card-rematch-may-start to read '
        '"${loc.endRematchMayStartWithout}". $where',
  );
  final Finder playAgain = find.byKey(const Key('end-card-rematch'));
  expect(
    playAgain,
    findsOneWidget,
    reason: '$capture: Play again must be on the card. $where',
  );
  expect(
    tester.getRect(mayStart).bottom,
    lessThanOrEqualTo(tester.getRect(playAgain).top),
    reason:
        '$capture: C-591 D2, expected end-card-rematch-may-start above '
        'end-card-rematch. $where',
  );
  if (!toTheStart) {
    // ignore: avoid_print
    print(
      'screenshots_test: $capture replays "four_seats_1" from seat '
      '$viewerSeat: $framesBeforeOver recorded frames before game_over, then '
      'game_over and ${seq - replay.gameOverSeq} frames after it (rematch '
      'rooms with ready [0], [0, 1])',
    );
    await _capture(binding, tester, shotName, frames: 0);
    return;
  }

  // The device answers: Play again, and the reply puts it in ready.
  await tester.tap(playAgain);
  await tester.pump();
  final List<String> rematches = transport.sentRaw
      .where((String s) => _typeOf(s) == 'rematch')
      .toList();
  expect(
    rematches,
    hasLength(1),
    reason:
        '$capture: tapping end-card-rematch must send exactly one rematch '
        'frame; sent ${transport.sentRaw.map(_typeOf).toList()}. $where',
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: _idOf(rematches.single),
      data: lobbyRoom(seats, <int>[0, 1, viewerSeat]),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.room?.rematch?.ready,
    unorderedEquals(<int>[0, 1, viewerSeat]),
    reason: '$capture: the reply must put the device in ready. $where',
  );
  expect(
    find.byKey(const Key('end-card-rematch-waiting')),
    findsOneWidget,
    reason: '$capture: the device is in, the waiting line shows. $where',
  );
  expect(
    controller.seatMovedFrom,
    isNull,
    reason: '$capture: no move has happened yet. $where',
  );

  // The host starts with the three who answered (docs/PROTOCOL.md 16.4).
  final List<int> staying = <int>[0, 1, viewerSeat];
  seq += 1;
  transport.pushText(
    _frame(
      type: 'player_left',
      data: <String, Object?>{'seat': sitsOutSeat, 'seq': seq},
    ),
  );
  await tester.pump();
  await tester.pump();
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': sitsOutSeat, 'seat_token': 'tok-moved'},
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.seat,
    sitsOutSeat,
    reason: '$capture: seat_assigned moves the device to seat $sitsOutSeat',
  );
  expect(
    controller.seatMovedFrom,
    viewerSeat,
    reason:
        '$capture: C-592 D1, the controller must remember the move from seat '
        '$viewerSeat. $where',
  );
  transport.pushText(
    _frame(
      type: 'room',
      data: lobbyRoom(
        staying,
        <int>[0, 1, viewerSeat],
        moveSeatOf: viewerSeat,
        moveSeatTo: sitsOutSeat,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$capture: seq gap in the re-seating frames. $where',
  );

  final Stopwatch sinceArrival = Stopwatch()..start();
  const String newGameId = 'b2b2b2b2b2b2b2b2';
  seq += 1;
  transport.pushText(
    _frame(
      type: 'game_started',
      data: <String, Object?>{
        'turn': 0,
        'game_id': newGameId,
        'client_seeds': '0:seed',
        'seq': seq,
      },
    ),
  );
  seq += 1;
  transport.pushText(
    _frame(
      type: 'turn',
      data: <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': 45000,
        'queue': <int>[],
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$capture: seq gap in the start order. $where',
  );
  expect(
    controller.room?.state,
    RoomState.playing,
    reason: '$capture: the start order must put the room in play. $where',
  );
  expect(
    <Object?>[controller.seat, controller.room?.seats.length],
    <Object?>[sitsOutSeat, 3],
    reason: '$capture: seat 2 of a table of three after the start. $where',
  );

  // The entrance veil runs first; the notice is up behind it and outlives it.
  final Finder veil = find.byKey(const Key('game-table-entrance-layer'));
  while (veil.evaluate().isNotEmpty) {
    if (sinceArrival.elapsedMilliseconds > 3000) {
      fail(
        '$capture: expected the entrance veil to be gone within 3000 ms of '
        'the start order, still there after '
        '${sinceArrival.elapsedMilliseconds} ms. $where',
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
  await _pumpRealDurationFrames(tester, frameCount: 4);

  final String expectedLine = loc.gameSeatMoved('yellow');
  final Finder notice = find.byKey(const Key('game-seat-moved-notice'));
  expect(
    notice,
    findsOneWidget,
    reason:
        '$capture: C-592 D2, expected game-seat-moved-notice on screen '
        '${sinceArrival.elapsedMilliseconds} ms after the start order and '
        'after the veil, within its 4000 ms hold. $where',
  );
  final Finder noticeText = find.descendant(
    of: notice,
    matching: find.byType(Text),
  );
  expect(
    noticeText,
    findsOneWidget,
    reason: '$capture: the notice holds exactly one Text. $where',
  );
  final Text text = tester.widget<Text>(noticeText);
  expect(
    text.data ?? text.textSpan?.toPlainText(),
    expectedLine,
    reason:
        '$capture: C-592 D2, expected game-seat-moved-notice to read '
        '"$expectedLine" (seat 2 is yellow). $where',
  );
  final Finder mark = find.descendant(
    of: notice,
    matching: find.byType(SeatMark),
  );
  expect(
    mark,
    findsOneWidget,
    reason: '$capture: the notice holds one SeatMark. $where',
  );
  expect(
    tester.widget<SeatMark>(mark).seat,
    sitsOutSeat,
    reason: '$capture: the SeatMark is for the new seat $sitsOutSeat. $where',
  );
  expect(
    controller.seatMovedFrom,
    isNull,
    reason: '$capture: the arrival must clear the remembered move. $where',
  );

  // This device's own yard is seat 2's.
  final Finder yard = find.byKey(const Key('board-my-yard'));
  expect(
    yard,
    findsOneWidget,
    reason: '$capture: expected board-my-yard on the board. $where',
  );
  final BoxDecoration ring =
      tester
              .widget<DecoratedBox>(
                find.descendant(of: yard, matching: find.byType(DecoratedBox)),
              )
              .decoration
          as BoxDecoration;
  expect(
    ring.border,
    Border.all(color: LudoColors.seats[sitsOutSeat], width: 3),
    reason:
        '$capture: expected board-my-yard to ring seat $sitsOutSeat\'s '
        'colour. $where',
  );

  final int ageMs = sinceArrival.elapsedMilliseconds;
  expect(
    ageMs,
    lessThan(3000),
    reason:
        '$capture: expected the shot within 3000 ms of the start order (the '
        'hold is 4000 ms), got $ageMs ms by wall time. $where',
  );
  // seat_assigned carries no seq, so it is the one frame not counted in seq.
  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "four_seats_1" from seat '
    '$viewerSeat: $framesBeforeOver recorded frames before game_over, then '
    'game_over and ${seq - replay.gameOverSeq + 1} frames after it (rooms '
    'with ready [0], [0, 1], [0, 1, 3], player_left 2, seat_assigned 2, the '
    're-seating room, game_started, turn); notice "$expectedLine", shot '
    '$ageMs ms after the start order',
  );

  await _capture(binding, tester, shotName, frames: 0);
}

// ============================================================================
// Order 602: gate frames for C-599 (148, 149, 149a), C-601 (150, 151) and
// C-600 (152).
// ============================================================================

/// Wall milliseconds after a `player_joined` push at which captures 148, 149
/// and 149a are taken: the card's 320 ms entrance is under way, the 1200 ms
/// glow is bright and the 2500 ms line is up.
const int _friendShotAfterMs = 150;

/// The latest a friend-joined shot may be taken, still inside the 320 ms
/// entrance (C-599 D5a); checked right before the shot.
const int _friendShotLatestMs = 290;

/// The same under reduced motion, where the glow is held at full strength for
/// 1200 ms instead: the shot must be inside that hold.
const int _friendShotLatestReducedMs = 1100;

/// Captures 148, 149 and 149a (order 602, C-599 D5). The device creates a
/// room of four as the host and sits alone; each of [joins] (seat, name, shot)
/// is then a `player_joined` pushed with the next `seq`, and the shot is taken
/// about [_friendShotAfterMs] ms after it. The app is wrapped in a
/// [FeedbackScope] over a recording service, the way app.dart puts the scope
/// above the routes, so the one `friend_joined` cue per join is asserted too.
/// At the shot: the new seat's card has its glow on in the seat's colour, the
/// seats already at the table have neither glow nor scale, and
/// `lobby-friend-joined-line` reads `lobbyFriendJoined(name)` with that
/// seat's painted `SeatMark` at its start. The card itself is asserted for the
/// branch the lobby takes, read from `MediaQuery.disableAnimationsOf`: with
/// motion it is mid-entrance (scale from 0.9 up to, not yet, 1.0) and the shot
/// is inside the 320 ms entrance; with animations removed (the screenshots
/// job's emulator) its scale is exactly 1.0 and the shot is inside the 1200 ms
/// hold of the glow. Which branch ran is printed.
Future<void> _shootFriendJoined(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required Locale locale,
  required String roomCode,
  required String seatToken,
  required List<(int seat, String name, String shotName)> joins,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final String host = _defaultPlayerName(locale);
  final String scenario =
      'capture ${joins.first.$3} (room $roomCode, locale '
      '${locale.languageCode}, host "$host" alone at a table of four, joins '
      '${[for (final j in joins) 'seat ${j.$1} "${j.$2}"']}); reproduce with '
      '`flutter test integration_test/screenshots_test.dart -d flutter-tester '
      '--plain-name "capture ${joins.first.$3}"`';
  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  final _CueLog cues = _CueLog();
  final FeedbackSettings settings = FeedbackSettings.forTest();
  addTearDown(settings.dispose);
  RoomController? controller;
  try {
    await tester.pumpWidget(
      FeedbackScope(
        settings: settings,
        service: cues,
        child: _reconnectingCaptureHarness(
          HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
          locale: locale,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _expectHomeScreen(tester, localeName: locale.languageCode);

    await tester.enterText(find.byKey(const Key('home-name-field')), host);
    await _tapCreateRoom(tester);

    expect(
      factory.controllers,
      hasLength(1),
      reason:
          '$scenario: tapping Create Room must build exactly one controller',
    );
    controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    final List<String> createMessages = transport.sentRaw
        .where((String s) => _typeOf(s) == 'create_room')
        .toList();
    expect(
      createMessages,
      hasLength(1),
      reason:
          '$scenario: expected one create_room, sent '
          '${transport.sentRaw.map(_typeOf).toList()}',
    );

    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': seatToken},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(createMessages.single),
        data: _roomJson(
          code: roomCode,
          players: 4,
          hostSeat: 0,
          seats: <Map<String, Object?>>[_seatJson(0, name: host)],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpUntilFound(
      tester,
      find.byType(LobbyScreen),
      '$scenario: LobbyScreen after the create_room reply',
    );
    await _pumpRealDurationFrames(tester, frameCount: 6);
    await _expectLobbyScreen(
      tester,
      localeName: locale.languageCode,
      code: roomCode,
      expectedSeatCount: 1,
    );
    expect(
      controller.room?.state,
      RoomState.lobby,
      reason: '$scenario: the room must be in its lobby before the first join',
    );
    expect(
      cues.played,
      isEmpty,
      reason:
          '$scenario: no cue may play before a friend sits down, got '
          '${cues.played}',
    );

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(LobbyScreen)),
    );
    final List<int> seated = <int>[0];
    int seq = 1;
    int joinNumber = 0;
    for (final (int seat, String name, String shotName) in joins) {
      joinNumber += 1;
      seq += 1;
      final String step = '$scenario; join $joinNumber, seat $seat "$name"';
      final Stopwatch sincePush = Stopwatch()..start();
      transport.pushText(
        _frame(
          type: 'player_joined',
          data: <String, Object?>{'seat': seat, 'name': name, 'seq': seq},
        ),
      );
      await tester.pump();
      while (sincePush.elapsedMilliseconds < _friendShotAfterMs) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final int ageMs = sincePush.elapsedMilliseconds;
      seated.add(seat);

      expect(
        controller.hasDesynced,
        isFalse,
        reason: '$step: seq gap, room seq ${controller.room?.seq}, pushed $seq',
      );
      await _expectLobbyScreen(
        tester,
        localeName: locale.languageCode,
        code: roomCode,
        expectedSeatCount: seated.length,
      );
      // The screenshots job boots its emulator with animations removed, the
      // motion jobs do not: the card is asserted for the branch the lobby
      // itself takes (C-599 D5a), read from its own context.
      final bool reduced = MediaQuery.disableAnimationsOf(
        tester.element(find.byType(LobbyScreen)),
      );
      final int latestMs = reduced
          ? _friendShotLatestReducedMs
          : _friendShotLatestMs;
      expect(
        ageMs,
        lessThanOrEqualTo(latestMs),
        reason: reduced
            ? '$step: expected the shot within $latestMs ms of the push (the '
                  'held glow lasts 1200 ms), got $ageMs ms by wall time'
            : '$step: expected the shot within $latestMs ms of the push (the '
                  'entrance lasts 320 ms), got $ageMs ms by wall time',
      );

      // Sound and touch: one friend_joined per join, nothing else.
      expect(
        cues.played,
        List<FeedbackCue>.filled(joinNumber, FeedbackCue.friendJoined),
        reason:
            '$step: C-599 D4, expected exactly $joinNumber friend_joined '
            'cue(s) through the feedback service, got ${cues.played}',
      );

      // The line: the newest name, the seat's painted mark at its start.
      final Finder line = find.byKey(const Key('lobby-friend-joined-line'));
      expect(
        line,
        findsOneWidget,
        reason:
            '$step: C-599 D5b, expected lobby-friend-joined-line $ageMs ms '
            'after the join',
      );
      final String expectedLine = loc.lobbyFriendJoined(name);
      final Finder lineText = find.descendant(
        of: line,
        matching: find.byType(Text),
      );
      expect(
        lineText,
        findsOneWidget,
        reason: '$step: the line holds exactly one Text',
      );
      expect(
        _textUnder(tester, lineText),
        expectedLine,
        reason:
            '$step: C-599 D5b, expected the line to read "$expectedLine", '
            'got "${_textUnder(tester, lineText)}"',
      );
      for (final (int otherSeat, String otherName, String _) in joins) {
        if (otherSeat != seat) {
          expect(
            _textUnder(tester, lineText),
            isNot(contains(otherName)),
            reason:
                '$step: the line names the newest join only, but it reads '
                '"${_textUnder(tester, lineText)}"',
          );
        }
      }
      final Finder lineMark = find.descendant(
        of: line,
        matching: find.byType(SeatMark),
      );
      expect(
        lineMark,
        findsOneWidget,
        reason: '$step: C-599 D5b, expected one SeatMark in the line',
      );
      expect(
        tester.widget<SeatMark>(lineMark).seat,
        seat,
        reason: '$step: the line\'s SeatMark must be seat $seat\'s',
      );
      expect(
        find.descendant(
          of: lineMark,
          matching: find.byWidgetPredicate(
            (Widget w) => w is CustomPaint && w.painter != null,
          ),
        ),
        findsOneWidget,
        reason:
            '$step: the SeatMark in the line must paint its shape (10 dp is '
            'over the 6 dp floor), but it drew the empty fallback',
      );
      final Rect markRect = tester.getRect(lineMark);
      final Rect textRect = tester.getRect(lineText);
      final bool rtl = locale.languageCode == 'ar';
      expect(
        rtl ? markRect.left >= textRect.right : markRect.right <= textRect.left,
        isTrue,
        reason:
            '$step: C-599 D5b, the mark sits at the line\'s start, '
            '${rtl ? 'right of' : 'left of'} the text; mark $markRect, text '
            '$textRect',
      );
      expect(
        tester.getRect(line).top,
        greaterThanOrEqualTo(
          tester.getRect(find.byKey(Key('lobby-seat-$seat'))).bottom,
        ),
        reason: '$step: the line sits under the seat grid, not over a card',
      );

      // The card: mid-entrance with the glow on; seats already there are not.
      final ScaleTransition entrance = tester.widget<ScaleTransition>(
        find.byKey(Key('lobby-seat-$seat-entrance')),
      );
      if (reduced) {
        expect(
          entrance.scale.value,
          1.0,
          reason:
              '$step: C-599 D5a, under reduced motion the card appears at '
              'once with no scale, expected exactly 1.0 $ageMs ms after the '
              'join, got ${entrance.scale.value}',
        );
      } else {
        expect(
          entrance.scale.value,
          allOf(greaterThanOrEqualTo(0.9), lessThan(1.0)),
          reason:
              '$step: C-599 D5a, expected the card mid-entrance (scale from '
              '0.9 up to 1.0, not yet there) $ageMs ms after the join, got '
              '${entrance.scale.value}',
        );
      }
      expect(
        find.byKey(Key('lobby-seat-$seat-glow')),
        findsOneWidget,
        reason:
            '$step: C-599 D5a, expected the glow on the new card $ageMs ms '
            'after the join',
      );
      final DecoratedBox glow = tester.widget<DecoratedBox>(
        find.byKey(Key('lobby-seat-$seat-glow')),
      );
      final BoxDecoration glowDecoration = glow.decoration as BoxDecoration;
      expect(
        glowDecoration.boxShadow!.single.color.toARGB32() & 0x00FFFFFF,
        LudoColors.seats[seat].toARGB32() & 0x00FFFFFF,
        reason: '$step: the glow carries seat $seat\'s colour',
      );
      expect(
        find.byKey(const Key('lobby-seat-0-glow')),
        findsNothing,
        reason: '$step: the host was seated at the first build, no glow',
      );
      expect(
        tester
            .widget<ScaleTransition>(
              find.byKey(const Key('lobby-seat-0-entrance')),
            )
            .scale
            .value,
        1.0,
        reason: '$step: the host\'s card never animates',
      );
      _expectNameLabel(
        tester,
        find.byKey(Key('lobby-seat-$seat')),
        label: name,
        what: 'lobby-seat-$seat',
        scenario: step,
      );

      // ignore: avoid_print
      print(
        'screenshots_test: $step: ${reduced ? 'reduced motion (disableAnimations '
                  'true): card at once, glow held' : 'full motion: card mid-entrance'}, '
        'shot $ageMs ms after the push, card scale '
        '${entrance.scale.value.toStringAsFixed(3)}, glow on, line '
        '"$expectedLine", cues ${cues.played.map((FeedbackCue c) => c.name).toList()}',
      );
      await _capture(binding, tester, shotName, frames: 0);
    }
  } finally {
    await _releaseTrayGame(tester, controller);
  }
}

/// Captures 150 and 151 (order 602, C-601 D2). The recorded four-seat game
/// four_seats_1 replayed from [viewerSeat]'s view to its `game_over`; the
/// finished screen is then scrolled until `game-screen-roll-history` lies
/// whole inside the scroll viewport. The three rows are read off the
/// fixture's last three `rolled` frames (their `k`, `value` and `seat`): the
/// controller must hold the same rolls and seats, and the history must draw,
/// per row and in order, the seat's painted `SeatMark`, its label (`seatYou`
/// for the viewer) and `gameRollHistoryEntry(k, face)`, with the row's
/// semantics label `gameRollHistoryEntrySpoken(k, name, face)`. The mark sits
/// at the row's start: left of the name in English, right of it in Arabic.
Future<void> _shootRollHistorySeats(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int viewerSeat,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);
  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });

  final String capture = 'capture $shotName';
  final _RealReplay replay = await _replayRealGame(
    tester,
    factory,
    capture: capture,
    gameName: 'four_seats_1',
    seat: viewerSeat,
    localeName: locale.languageCode,
  );
  final RoomController controller = replay.controller;
  final _RealGame game = replay.game;
  final String where = replay.describe;

  // The last three rolls of the recorded game, from its own frames.
  final List<Map<String, Object?>> view = game.view(viewerSeat);
  final List<Map<String, Object?>> rolledFrames = <Map<String, Object?>>[
    for (final Map<String, Object?> f in view)
      if (f['t'] == 'rolled') f,
  ];
  expect(
    rolledFrames.length,
    greaterThanOrEqualTo(3),
    reason: '$where: the recorded view holds fewer than three rolls',
  );
  final List<(int k, int face, int seat)> lastRolls = <(int, int, int)>[
    for (final Map<String, Object?> f in rolledFrames.sublist(
      rolledFrames.length - 3,
    ))
      (
        (f['d']! as Map<String, Object?>)['k']! as int,
        (f['d']! as Map<String, Object?>)['value']! as int,
        (f['d']! as Map<String, Object?>)['seat']! as int,
      ),
  ];
  final Map<int, String> names = <int, String>{
    for (final int s in <int>[0, 1, 2, 3]) s: game.nameOf(s),
  };
  expect(
    names.values.toSet(),
    hasLength(4),
    reason:
        '$where: the four recorded names must be distinct for the history '
        'labels to be the names themselves, got $names',
  );

  replay.pushGameOver();
  await tester.pump();
  await tester.pump();
  await _pumpRealDurationFrames(tester);

  expect(
    controller.room?.state,
    RoomState.finished,
    reason: '$capture: game_over must finish the room. $where',
  );
  expect(
    <Object?>[
      for (final (int k, int face) r in controller.room!.recentRolls)
        (r.$1, r.$2),
    ],
    <Object?>[
      for (final (int k, int face, int seat) r in lastRolls) (r.$1, r.$2),
    ],
    reason:
        '$capture: the controller must hold the last three recorded rolls '
        '(k, face). $where',
  );
  expect(
    controller.room!.recentRollSeats,
    <int>[for (final (int k, int face, int seat) r in lastRolls) r.$3],
    reason:
        '$capture: C-601 D1, recentRollSeats must hold the seats that rolled '
        'the last three recorded rolls, in order. $where',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(
    loc.localeName,
    locale.languageCode,
    reason:
        '$capture: expected locale ${locale.languageCode}, got '
        '${loc.localeName}',
  );
  final Finder history = find.byKey(const Key('game-screen-roll-history'));
  expect(
    history,
    findsOneWidget,
    reason:
        '$capture: expected game-screen-roll-history on the finished '
        'screen. $where',
  );

  // Scroll until the whole block is inside the scroll viewport.
  await Scrollable.ensureVisible(tester.element(history), alignment: 0.5);
  await _pumpRealDurationFrames(tester, frameCount: 6);
  final ScrollableState scrollable = Scrollable.of(tester.element(history));
  final RenderBox viewportBox =
      scrollable.context.findRenderObject()! as RenderBox;
  final Rect viewport =
      viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
  final Rect block = tester.getRect(history);
  expect(
    block.top >= viewport.top && block.bottom <= viewport.bottom,
    isTrue,
    reason:
        '$capture: expected game-screen-roll-history whole inside the scroll '
        'viewport after scrolling, block top ${block.top.toStringAsFixed(1)} '
        'bottom ${block.bottom.toStringAsFixed(1)}, viewport top '
        '${viewport.top.toStringAsFixed(1)} bottom '
        '${viewport.bottom.toStringAsFixed(1)}. $where',
  );

  // Three rows, each: the seat's painted mark, its label, the roll text.
  final Finder marks = find.descendant(
    of: history,
    matching: find.byType(SeatMark),
  );
  expect(
    marks,
    findsNWidgets(3),
    reason:
        '$capture: C-601 D2, expected three SeatMarks (one per row) in the '
        'roll history, found ${marks.evaluate().length}. $where',
  );
  expect(
    <int>[for (final SeatMark m in tester.widgetList<SeatMark>(marks)) m.seat],
    <int>[for (final (int k, int face, int seat) r in lastRolls) r.$3],
    reason:
        '$capture: C-601 D2, the three marks must be the seats of the last '
        'three rolls, in roll order. $where',
  );
  expect(
    find.descendant(
      of: marks,
      matching: find.byWidgetPredicate(
        (Widget w) => w is CustomPaint && w.painter != null,
      ),
    ),
    findsNWidgets(3),
    reason:
        '$capture: C-601 D2, every row\'s SeatMark must paint its shape '
        '(16 dp or a 14 dp mark on its disc is over the 6 dp floor). $where',
  );
  final List<String> expectedTexts = <String>[
    loc.gameRollHistoryHeading,
    for (final (int k, int face, int seat) r in lastRolls) ...<String>[
      r.$3 == viewerSeat ? loc.seatYou : names[r.$3]!,
      loc.gameRollHistoryEntry(r.$1, r.$2),
    ],
  ];
  expect(
    _textsOf(tester, history),
    expectedTexts,
    reason:
        '$capture: C-601 D2, expected the heading, then per row the seat '
        'label ("${loc.seatYou}" for seat $viewerSeat) and the unchanged '
        'gameRollHistoryEntry(k, face) text. $where',
  );
  final bool rtl = locale.languageCode == 'ar';
  final List<Rect> markRects = <Rect>[
    for (final Element e in marks.evaluate())
      tester.getRect(find.byWidget(e.widget)),
  ];
  for (int i = 0; i < 3; i++) {
    final String name = lastRolls[i].$3 == viewerSeat
        ? loc.seatYou
        : names[lastRolls[i].$3]!;
    final Rect nameRect = tester.getRect(
      find.descendant(of: history, matching: find.text(name)).at(0),
    );
    expect(
      rtl
          ? markRects[i].left >= nameRect.right
          : markRects[i].right <= nameRect.left,
      isTrue,
      reason:
          '$capture: C-601 D2, row ${i + 1} mark ${markRects[i]} must sit '
          '${rtl ? 'right' : 'left'} of its name "$name" $nameRect (the '
          'row mirrors under Directionality). $where',
    );
    if (i > 0) {
      expect(
        markRects[i].top,
        greaterThan(markRects[i - 1].top),
        reason: '$capture: the rows run top to bottom in roll order. $where',
      );
    }
  }

  // One semantics node per row, spoken as one line.
  final SemanticsHandle semantics = tester.ensureSemantics();
  try {
    await tester.pump();
    for (final (int k, int face, int seat) r in lastRolls) {
      final String name = r.$3 == viewerSeat ? loc.seatYou : names[r.$3]!;
      expect(
        find.bySemanticsLabel(loc.gameRollHistoryEntrySpoken(r.$1, name, r.$2)),
        findsOneWidget,
        reason:
            '$capture: C-601 D2, expected one semantics node labelled '
            '"${loc.gameRollHistoryEntrySpoken(r.$1, name, r.$2)}". $where',
      );
    }
  } finally {
    semantics.dispose();
  }

  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "four_seats_1" from seat $viewerSeat '
    'to game_over; last three rolls (k, face, seat) $lastRolls; labels '
    '${expectedTexts.skip(1).toList()}',
  );
  await _capture(binding, tester, shotName, frames: 12);
}

/// The wall time capture 152 allows the queued throws to land. The moment it
/// shows is the 198th roll of the recorded game; every roll of another seat
/// before it is thrown on the board in turn, about 2.6 throws a second, so the
/// backlog of that burst takes far longer than the 60 s the early-game
/// captures need.
const int _sharedCellDrainMaxMs = 300000;

/// One moment of a recorded game at which tokens of [seatCount] or more
/// different seats stand on one main-track cell, found from the `moved`
/// frames alone.
class _SharedCellMoment {
  _SharedCellMoment({
    required this.index,
    required this.seq,
    required this.rollK,
    required this.absolute,
    required this.occupants,
  });

  /// Index of the `moved` that completes the cell, in the viewer's view.
  final int index;

  /// That `moved`'s own `seq`.
  final int seq;

  /// `k` of the last `rolled` before it (the roll index of the moment).
  final int rollK;

  /// The cell's absolute main-track square (RULES.md 1.2).
  final int absolute;

  /// Every token on the cell: (seat, token, progress).
  final List<(int seat, int token, int progress)> occupants;

  @override
  String toString() =>
      'roll k $rollK, the moved at view index $index (seq $seq), absolute '
      'square $absolute holding $occupants';
}

/// The first `moved` after which at least [seatCount] different seats have
/// tokens on one main-track cell with at most four tokens in all (so the
/// board draws them in the 0.5-cell shared slots). The positions are folded
/// from the `moved` frames (a `captured` entry sends a token to its yard) and
/// the fold is checked against the fixture's `final_tokens`, so a wrong
/// reading of the frames fails here and not as a missing moment.
_SharedCellMoment _locateSharedCell(
  _RealGame game,
  List<Map<String, Object?>> view, {
  required int seatCount,
  required String where,
}) {
  final Map<(int, int), int> position = <(int, int), int>{
    for (final Object? s in game.json['seats']! as List<Object?>)
      for (int t = 0; t < 4; t++) (s! as int, t): -1,
  };
  _SharedCellMoment? found;
  int rollK = -1;
  for (int i = 0; i < view.length; i++) {
    final Map<String, Object?> frame = view[i];
    final Map<String, Object?> d = frame['d']! as Map<String, Object?>;
    if (frame['t'] == 'rolled') {
      rollK = d['k']! as int;
      continue;
    }
    if (frame['t'] != 'moved') {
      continue;
    }
    position[(d['seat']! as int, d['token']! as int)] = d['to']! as int;
    for (final Object? c in d['captured']! as List<Object?>) {
      final Map<String, Object?> struck = c! as Map<String, Object?>;
      position[(struck['seat']! as int, struck['token']! as int)] = -1;
    }
    if (found != null) {
      continue;
    }
    final Map<int, List<(int, int, int)>> byCell =
        <int, List<(int, int, int)>>{};
    position.forEach(((int, int) key, int progress) {
      if (progress >= 0 && progress <= 51) {
        byCell
            .putIfAbsent(
              (13 * key.$1 + progress) % 52,
              () => <(int, int, int)>[],
            )
            .add((key.$1, key.$2, progress));
      }
    });
    byCell.forEach((int absolute, List<(int, int, int)> occupants) {
      if (found == null &&
          occupants.length <= 4 &&
          occupants.map(((int, int, int) o) => o.$1).toSet().length >=
              seatCount) {
        found = _SharedCellMoment(
          index: i,
          seq: d['seq']! as int,
          rollK: rollK,
          absolute: absolute,
          occupants: occupants,
        );
      }
    });
  }
  for (final Object? s in game.json['seats']! as List<Object?>) {
    expect(
      <int>[for (int t = 0; t < 4; t++) position[(s! as int, t)]!],
      game.finalTokens(s as int),
      reason:
          '$where: folding the recorded moved frames must end on the '
          'fixture\'s final_tokens for seat $s; the fold is wrong',
    );
  }
  if (found == null) {
    throw TestFailure(
      '$where: no moment of the recorded game has tokens of $seatCount '
      'seats on one main-track cell (at most four tokens in all); report it '
      'and skip the capture, never fake one',
    );
  }
  return found!;
}

/// Capture 152 (order 602, C-600 D2). The recorded game four_seats_1 from
/// [viewerSeat]'s view, replayed up to the first moment tokens of three
/// different seats share one main-track cell ([_locateSharedCell]), the
/// capturing roll's throw landed and the move walked. On a 360 dp wide surface
/// where the harness can set one (not on a real Android device, whose own
/// size stands; run 124 found an emulator hangs on a forced 360 x 640
/// surface). Asserted: the three discs of that cell are drawn at 0.5 of a
/// cell, within one cell of each other, and each carries a `SeatMark` of its
/// own seat sized 0.62 of the disc, at least 6 dp, painting a `CustomPaint`.
Future<void> _shootSharedCellThreeSeats(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding, {
  required String shotName,
  required Locale locale,
  required int viewerSeat,
}) async {
  binding.testTextInput.register();
  _stubScreenshotChannel(tester);
  await binding.convertFlutterSurfaceToImage();
  await (await SharedPreferences.getInstance()).clear();
  tester.platformDispatcher.clearTextScaleFactorTestValue();

  final bool realDevice = !kIsWeb && Platform.isAndroid;
  if (!realDevice) {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final _ScreenshotControllerFactory factory = _ScreenshotControllerFactory();
  await tester.pumpWidget(_replayHome(factory, locale));
  await tester.pumpAndSettle();
  await _expectHomeScreen(tester, localeName: locale.languageCode);
  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });

  final String capture = 'capture $shotName';
  final _RealEntry entry = await _enterRealGame(
    tester,
    factory,
    capture: capture,
    gameName: 'four_seats_1',
    seat: viewerSeat,
    localeName: locale.languageCode,
  );
  final RoomController controller = entry.controller;
  final _SharedCellMoment moment = _locateSharedCell(
    entry.game,
    entry.view,
    seatCount: 3,
    where: entry.where,
  );
  final String where = '${entry.where}; moment $moment';
  expect(
    <Object?>{
      for (final (int seat, int token, int progress) o in moment.occupants)
        cellFor(seat: o.$1, progress: o.$3, tokenIndex: o.$2),
    },
    hasLength(1),
    reason:
        '$where: the board geometry must put every occupant in one cell, but '
        'the absolute-square arithmetic of RULES.md 1.2 says they share one',
  );

  // The burst stops short of the roll that leads to the moment, the throws
  // queued land, then that roll goes in and lands, and the move is walked.
  var rollAt = moment.index - 1;
  while (rollAt > entry.next && entry.view[rollAt]['t'] != 'rolled') {
    rollAt--;
  }
  while (entry.next < rollAt) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; before the roll',
    maxWallMs: _sharedCellDrainMaxMs,
  );
  while (entry.next < moment.index) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  await _pumpUntilThrownDiceGone(
    tester,
    controller,
    capture: capture,
    where: '$where; the roll',
    maxWallMs: _sharedCellDrainMaxMs,
  );
  var turnAt = moment.index + 1;
  while (entry.view[turnAt]['t'] != 'turn') {
    turnAt++;
  }
  while (entry.next <= turnAt) {
    entry.push();
  }
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isFalse,
    reason: '$where: seq gap in the replayed frames',
  );
  expect(
    controller.room?.seq,
    (entry.view[turnAt]['d']! as Map<String, Object?>)['seq'],
    reason: '$where: the controller must have absorbed the turn after the move',
  );
  expect(entry.transport.sentRaw.map(_typeOf).toList(), <String>[
    'join_room',
  ], reason: '$where: the device must have sent only its own join');

  // The truth the board is handed holds the three seats on the cell.
  final LudoBoard board = tester.widget<LudoBoard>(
    find.byKey(const Key('game-screen-board')),
  );
  for (final (int seat, int token, int progress) o in moment.occupants) {
    expect(
      board.tokens[o.$1]![o.$2],
      o.$3,
      reason:
          '$where: the board must hold seat ${o.$1} token ${o.$2} on '
          'progress ${o.$3}, it holds ${board.tokens[o.$1]}',
    );
  }

  // Wait for the walk to land: every disc on the cell takes its shared slot.
  final Finder boardFinder = find.byKey(const Key('game-screen-board'));
  Finder discOf(int seat, int token) => find.descendant(
    of: find.byKey(Key('token-$seat-$token')),
    matching: find.byType(DecoratedBox),
  );
  double cellSize() => tester.getSize(boardFinder).width / 15;
  bool shared() {
    for (final (int seat, int token, int progress) o in moment.occupants) {
      final Finder disc = discOf(o.$1, o.$2);
      if (disc.evaluate().isEmpty ||
          (tester.getSize(disc).width - cellSize() * 0.5).abs() > 0.6) {
        return false;
      }
    }
    return true;
  }

  // The landing settles over a few frames (the mover's disc is seen in the
  // shared slot, then back on the fan, then in the slot for good), so the
  // slots must hold for six pumps in a row.
  final Stopwatch waited = Stopwatch()..start();
  int held = 0;
  while (held < 6) {
    if (waited.elapsedMilliseconds > 4000) {
      fail(
        '$where: expected the three discs on the cell to hold their 0.5-cell '
        'shared slots for six frames within 4000 ms of the moved, not so '
        'after ${waited.elapsedMilliseconds} ms (cell ${cellSize()} dp)',
      );
    }
    held = shared() ? held + 1 : 0;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    _thrownDice(tester),
    isEmpty,
    reason: '$where: no thrown die may be on the board at the shot',
  );

  final double cell = cellSize();
  final Size surface = tester.view.physicalSize / tester.view.devicePixelRatio;
  if (!realDevice) {
    expect(
      surface.width,
      360,
      reason: '$where: the surface was meant to be 360 dp wide',
    );
  }
  final List<Offset> centres = <Offset>[];
  final List<String> readings = <String>[];
  for (final (int seat, int token, int progress) o in moment.occupants) {
    final Finder disc = discOf(o.$1, o.$2);
    final double diameter = tester.getSize(disc).width;
    expect(
      diameter,
      closeTo(cell * 0.5, 0.6),
      reason:
          '$where: seat ${o.$1} token ${o.$2} must be drawn in the shared '
          'slot, 0.5 of the ${cell.toStringAsFixed(2)} dp cell, got '
          '$diameter dp',
    );
    final Finder markFinder = find.descendant(
      of: find.byKey(Key('token-${o.$1}-${o.$2}')),
      matching: find.byType(SeatMark),
    );
    expect(
      markFinder,
      findsOneWidget,
      reason: '$where: seat ${o.$1} token ${o.$2} must carry one SeatMark',
    );
    final SeatMark mark = tester.widget<SeatMark>(markFinder);
    expect(
      mark.seat,
      o.$1,
      reason:
          '$where: the mark on seat ${o.$1}\'s disc is seat ${mark.seat}\'s',
    );
    expect(
      mark.size,
      closeTo(diameter * 0.62, 0.01),
      reason:
          '$where: C-600 D2, the mark on a shared disc of $diameter dp must '
          'be 0.62 of it (${diameter * 0.62}), got ${mark.size}',
    );
    expect(
      mark.size,
      greaterThanOrEqualTo(6),
      reason:
          '$where: C-600 D2, the mark on seat ${o.$1}\'s shared disc must '
          'clear the 6 dp floor, got ${mark.size} dp (board '
          '${tester.getSize(boardFinder).width} dp wide)',
    );
    expect(
      find.descendant(
        of: markFinder,
        matching: find.byWidgetPredicate(
          (Widget w) => w is CustomPaint && w.painter != null,
        ),
      ),
      findsOneWidget,
      reason:
          '$where: C-600 D2, the mark on seat ${o.$1}\'s disc must be a '
          'painted CustomPaint, not the empty fallback (mark ${mark.size} dp)',
    );
    centres.add(tester.getCenter(disc));
    readings.add(
      'seat ${o.$1} token ${o.$2}: disc ${diameter.toStringAsFixed(2)} dp, '
      'mark ${mark.size.toStringAsFixed(2)} dp',
    );
  }
  for (int a = 0; a < centres.length; a++) {
    for (int b = a + 1; b < centres.length; b++) {
      expect(
        (centres[a] - centres[b]).distance,
        allOf(greaterThan(0), lessThan(cell)),
        reason:
            '$where: discs $a and $b must sit on one cell, in different '
            'slots; centres ${centres[a]} and ${centres[b]}, cell $cell dp',
      );
    }
  }

  // ignore: avoid_print
  print(
    'screenshots_test: $capture replays "four_seats_1" from seat $viewerSeat '
    'to $moment; surface ${surface.width} x ${surface.height} dp'
    '${realDevice ? ' (a real device, its own size)' : ' (set by the harness)'}'
    ', board ${tester.getSize(boardFinder).width} dp, cell '
    '${cell.toStringAsFixed(2)} dp; ${readings.join('; ')}',
  );
  await _capture(binding, tester, shotName, frames: 6);
}
