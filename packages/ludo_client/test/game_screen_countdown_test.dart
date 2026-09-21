// Conformance tests for the turn-countdown contract work order 141 pins
// against lib/src/game_screen.dart's GameScreen, written from the frozen
// contract text in work/ludo/orders/141-turn-countdown-proof.md alone. On
// this base commit (754fa37) GameScreen builds no widget keyed
// game-screen-turn-countdown and no widget keyed game-screen-waiting-for-
// seat anywhere: a second worker is adding both, blind, from the identical
// frozen contract, in a different worktree, and this file has not read that
// worker's change.
//
// P1, P2, P3, P4 and P7 are therefore expected to FAIL on this base commit --
// the countdown key the contract names does not exist. P5 and P6 are
// controls and are expected to PASS: they exercise paths the contract does
// not add anything new to (an absent key staying absent, a healthy own-turn
// board), so a red P5 or P6 would mean this file is not reaching the
// behaviour it claims to test, not that the contract is unmet.
//
// GameScreen is driven the same way test/game_screen_test.dart and
// test/game_screen_connection_lost_test.dart drive RoomController: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here) and a small connector double copied from that
// idiom. Every claim about the state the screen is rendering is reached by
// decoding a wire reply into a real RoomSnapshot through RoomController's
// own request path, never by constructing a RoomSnapshot by hand. Assertions
// are made on find.byKey, widget types and rendered numbers only, never on
// localized strings: the counterpart order adds new l10n keys that do not
// exist on this base commit, and referencing them would not compile.
//
// Where the countdown text sits inside whatever widget carries the
// game-screen-turn-countdown key is not pinned by the contract (only the key
// and "shows the whole seconds remaining" are). _wholeSecondsShown below
// reads the key's own widget if it is a Text, or else the first Text
// descendant under it, and pulls the first run of digits out of whatever
// string that Text carries -- so a rendered "45", "00:45" or "45s" are all
// read as 45 without this file assuming the exact template the other worker
// chose.
//
// Ambiguity found while writing this file, reported rather than invented
// around:
//
//   P6 asks for "a playing room whose turn carries no deadline_ms at all".
//   On this base commit, TurnState.deadlineMs (lib/src/net/snapshot.dart) is
//   a required, non-nullable int: SnapshotFormatException is thrown by
//   TurnState.fromJson whenever a decoded turn object's deadline_ms key is
//   missing or JSON null, and RoomConnection._asRoomSnapshot
//   (lib/src/net/connection.dart) does not catch that exception on the
//   `room` reply that completes createRoom/joinRoom/resume/setPlayers -- it
//   would fail this file's own fixture setup, not exercise GameScreen at
//   all. There is no way to drive a real, decoded RoomSnapshot into a state
//   where room.turn is a TurnState with no deadline_ms while turn itself is
//   present; the only way "the turn carries no deadline_ms at all" is
//   reachable through the real model is room.turn being null outright, since
//   then there is no TurnState object to carry any deadline at all. That
//   also matches the contract's own rule 1 phrasing literally:
//   `room.turn?.deadlineMs` on a null `room.turn` evaluates to null under
//   Dart's null-aware operator regardless of whether TurnState.deadlineMs
//   itself is nullable, so "is non-null" is false exactly when turn is null,
//   which is what rule 1 requires for the countdown to be absent. P6 below is
//   therefore driven with turn: null, the same "no turn at all" state
//   test/game_screen_test.dart's H2 branch 1 and H3.6c already reach, but
//   checked here for a different key. This should be checked against
//   whatever the implementer also concluded about deadline_ms's nullability.
//
// work/ludo/orders/143-countdown-proof-gaps.md closes three gaps an
// adversarial pre-review found in this file, confirmed by the master and
// recorded in order 141's verdict:
//
//   1. P4 is rewritten to drive two connections, on two different seats with
//      two different seat names, and require the two rendered
//      game-screen-waiting-for-seat strings to differ. The original body
//      built one scenario and only checked the text was non-empty, so its own
//      description ("proved by ... requiring the rendered text to differ")
//      described a comparison the body never made.
//   2. P8 (new) proves the countdown's periodic timer stops scheduling once
//      it reaches zero, while the widget stays mounted -- not by reading the
//      framework's own end-of-test pending-timer check, which cannot see this
//      defect: GameScreen.dispose cancels _countdownTimer unconditionally, so
//      a countdown that kept ticking after zero is swept up the instant the
//      widget is torn down, before any case relying on unmount could catch
//      it. See P8's own comment for the mechanism used instead.
//   3. P9 (new) drives a second `turn` push through the same fake_transport
//      idiom this file already uses, on a different (seat, deadlineMs) pair,
//      without unmounting, and proves both that the countdown re-anchors to
//      the new deadline and that no timer from the superseded segment is
//      still ticking alongside it.
//
// work/ludo/orders/145-waiting-line-said-once-proof.md answers a screenshot
// of the real, rendered Arabic game screen saying the waiting sentence
// twice, once as game-screen-turn-banner and once as the standalone
// game-screen-waiting-for-seat line beneath it, because _turnBannerText
// falls through to the same _waitingForSeatText call the standalone line
// also makes. game-screen-waiting-for-seat itself is also scheduled to be
// deleted from _playingBody by a second, concurrent order that this file
// does not read, so nothing below may require that key to be present; an
// assertion that requires its absence is still sound after that deletion
// and is kept:
//
//   1. P4 is retargeted from game-screen-waiting-for-seat onto
//      game-screen-turn-banner, keeping the exact shape order 143 gave it:
//      two independent connections, two differently-named seats on turn,
//      and a requirement that the two rendered strings differ.
//   2. P5 gains a first arm that reads the waiting sentence off the banner
//      while the turn is on another seat, so its own-turn arm has a real
//      rendered string to prove is absent with find.text(...), rather than
//      only proving an already-doomed key is missing.
//   3. P10 (new) is what this order exists for: with the turn on another
//      seat, the string read off game-screen-turn-banner must match exactly
//      one widget in the whole mounted tree, run in both locales because the
//      photographed defect was Arabic. It is expected to fail on this base
//      commit with two matches -- the banner and the standalone line saying
//      the identical thing.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// --- server-side id generation for pushed frames, mirroring the sibling
// suites' own idiom ----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'countdown-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring game_screen_test.dart --------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot, mirroring
// game_screen_test.dart -------------------------------------------------

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
  int? value,
  List<int>? legal,
  int? sixes,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'sixes': ?sixes,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

// --- a TransportConnector test double, copied from the sibling suites'
// idiom -------------------------------------------------------------------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

// --- driving a controller to a chosen room state, through real frames,
// mirroring game_screen_test.dart's _connectPlaying -----------------------

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
  int players = 2,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
  );
  // Standing lesson 8: pumpEventQueue() alone relies on real Timers via
  // Future.delayed, which never fire under the fake-async clock a
  // testWidgets body runs in, and hangs forever with no diagnostic.
  // tester.runAsync() steps outside the fake zone for the duration of the
  // call so the real event loop actually advances, then tester.pump()
  // brings the widget tree's own state back in sync with what that
  // unblocked. Neither step advances the fake clock the countdown itself
  // will be measured against below.
  await tester.runAsync(() => pumpEventQueue());
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
      data: _roomJson(players: players, seats: seats, turn: turn, seq: seq),
    ),
  );
  await future;
  return (controller, transport);
}

// --- widget harness, mirroring game_screen_test.dart's own ----------------

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

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _waitingForSeatKey = Key('game-screen-waiting-for-seat');
const Key _turnBannerKey = Key('game-screen-turn-banner');
const Key _boardKey = Key('game-screen-board');
const Key _rollKey = Key('game-screen-roll-button');

/// Reads whatever whole-second number the widget at [key] is showing,
/// without assuming its exact template. If the keyed widget is itself a
/// [Text], its data is used; otherwise the first [Text] descendant under it
/// is used. The first run of digits (with an optional leading '-', so a
/// clamp bug that slips out a negative number is still readable rather than
/// silently failing the parse) is parsed out and returned.
int _wholeSecondsShown(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  final Widget widget = tester.widget(finder);
  final Text text;
  if (widget is Text) {
    text = widget;
  } else {
    final Finder descendant = find.descendant(
      of: finder,
      matching: find.byType(Text),
    );
    expect(
      descendant,
      findsAtLeastNWidgets(1),
      reason:
          'the widget keyed $key is a ${widget.runtimeType}, not a '
          'Text, and carries no Text descendant to read a rendered number '
          'from',
    );
    text = tester.widget<Text>(descendant.first);
  }
  final String rendered = text.data ?? '';
  final RegExpMatch? match = RegExp(r'-?\d+').firstMatch(rendered);
  if (match == null) {
    fail(
      'the widget keyed $key rendered "$rendered", which contains '
      'no whole number to read a countdown value from',
    );
  }
  return int.parse(match.group(0)!);
}

void main() {
  final List<Map<String, Object?>> twoSeats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];

  // ==========================================================================
  // P1: the countdown renders.
  // ==========================================================================
  testWidgets('P1: a playing room whose turn carries deadline_ms 45000 renders '
      'game-screen-turn-countdown showing 45 whole seconds, checked against '
      'the deadline put on the wire, not a number the widget also computed', (
    tester,
  ) async {
    final (controller, _) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: twoSeats,
      turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
    );
    addTearDown(controller.dispose);
    expect(
      controller.room!.turn!.deadlineMs,
      45000,
      reason: 'fixture is broken: deadline_ms must be 45000 on the wire',
    );

    await _mount(tester, controller);

    expect(
      find.byKey(_countdownKey),
      findsOneWidget,
      reason:
          'P1: a playing room whose turn carries deadline_ms non-null '
          'must render exactly one widget keyed '
          'game-screen-turn-countdown; none was found',
    );
    final int shown = _wholeSecondsShown(tester, _countdownKey);
    expect(
      shown,
      45,
      reason:
          'P1: deadline_ms 45000 was put on the wire with no fake time '
          'advanced since; game-screen-turn-countdown must show 45 whole '
          'seconds, got $shown',
    );
  });

  // ==========================================================================
  // P2: it counts down.
  // ==========================================================================
  testWidgets('P2: from a 45000ms deadline, each further second of pumped time '
      'strictly decreases the rendered value', (tester) async {
    final (controller, _) = await _connectPlaying(
      tester,
      mySeat: 0,
      seats: twoSeats,
      turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
    );
    addTearDown(controller.dispose);

    await _mount(tester, controller);
    expect(
      find.byKey(_countdownKey),
      findsOneWidget,
      reason:
          'P2: game-screen-turn-countdown must be present before this '
          'case can measure it counting down',
    );

    int previous = _wholeSecondsShown(tester, _countdownKey);
    for (int elapsedSeconds = 1; elapsedSeconds <= 5; elapsedSeconds++) {
      await tester.pump(const Duration(seconds: 1));
      final int shown = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shown,
        lessThan(previous),
        reason:
            'P2: after $elapsedSeconds second(s) of pumped time past a '
            '45000ms deadline, game-screen-turn-countdown must show a '
            'smaller value than the previous $previous; got $shown, which '
            'did not decrease',
      );
      previous = shown;
    }
  });

  // ==========================================================================
  // P3: the clamp.
  // ==========================================================================
  testWidgets(
    'P3: past the deadline the rendered value is zero and never negative at '
    'any second sampled across the boundary, and stays zero once reached',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);
      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason:
            'P3: game-screen-turn-countdown must be present before this '
            'case can measure the clamp at its deadline',
      );

      // Sample every second from 1 through 50 seconds of pumped time,
      // crossing the 45000ms deadline partway through, and require that no
      // sample is ever negative -- the case requirement 2 in the contract
      // exists for.
      for (int elapsedSeconds = 1; elapsedSeconds <= 50; elapsedSeconds++) {
        await tester.pump(const Duration(seconds: 1));
        final int shown = _wholeSecondsShown(tester, _countdownKey);
        expect(
          shown,
          greaterThanOrEqualTo(0),
          reason:
              'P3: game-screen-turn-countdown must never show a negative '
              'number; at $elapsedSeconds second(s) of pumped time past a '
              '45000ms deadline, got $shown',
        );
      }
      final int shownAtFifty = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shownAtFifty,
        0,
        reason:
            'P3: with 50 seconds of pumped time against a 45000ms deadline, '
            'game-screen-turn-countdown must show exactly 0; got '
            '$shownAtFifty',
      );

      // Advance further and confirm the clamp holds rather than the
      // countdown wrapping, resetting or otherwise moving off zero.
      await tester.pump(const Duration(seconds: 10));
      final int shownAfterMore = _wholeSecondsShown(tester, _countdownKey);
      expect(
        shownAfterMore,
        0,
        reason:
            'P3: 10 further seconds of pumped time past an already-expired '
            '45000ms deadline must still show 0, not drift away from the '
            'clamp; got $shownAfterMore',
      );
    },
  );

  // ==========================================================================
  // P4: waiting for another seat, retargeted by order 145 onto
  // game-screen-turn-banner.
  // ==========================================================================
  //
  // Order 145: on the base commit this file was first written against,
  // _turnBannerText's not-my-turn branch already falls straight through to
  // the same _waitingForSeatText call the standalone game-screen-waiting-
  // for-seat line also makes, so the banner names the seat on turn exactly
  // as that standalone line did. A second, concurrent order deletes that
  // standalone line from _playingBody entirely, so nothing below may depend
  // on game-screen-waiting-for-seat being present; the shape order 143 gave
  // this case -- two independent connections, two differently-named seats
  // on turn, the two rendered strings required to differ -- is kept exactly,
  // reading both strings off game-screen-turn-banner instead. A
  // _waitingForSeatText mutated to ignore turnSeat and return a constant
  // still fails this case: on the branch both arms exercise (turn.seat !=
  // my own seat), _turnBannerText's own return value *is* that
  // _waitingForSeatText call, so a turnSeat-blind mutant renders the same
  // banner text on both arms and the isNot comparison below catches it
  // exactly as it did when the case read game-screen-waiting-for-seat. This
  // was checked, not just argued statically: a scratch copy of the whole
  // ludo_client package was made outside the repository, its
  // _waitingForSeatText body replaced with `return 'constant-mutant';`, and
  // this exact case run against that copy with --plain-name "P4" -- it
  // failed with "Expected: not 'constant-mutant', Actual: 'constant-mutant'"
  // -- and then run again against an unmodified copy of the same scratch
  // package, where it passed.
  testWidgets(
    'P4: in a playing room where the turn belongs to a seat that is not '
    'this player\'s, game-screen-turn-banner names the seat on turn, '
    'proved by mounting two separate connections that each wait for a '
    'different, differently-named seat and requiring the two rendered '
    'strings to differ, rather than asserting exact wording',
    (tester) async {
      // Arm A: the turn is on seat 1 ("Bob"), my own seat is 0.
      final (controllerBob, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controllerBob.dispose);
      expect(
        controllerBob.room!.turn!.seat,
        isNot(controllerBob.seat),
        reason: 'fixture is broken: arm A\'s turn must not belong to my seat',
      );

      await _mount(tester, controllerBob);

      expect(
        find.byKey(_turnBannerKey),
        findsOneWidget,
        reason:
            'P4: with the turn on seat 1 and my own seat 0, '
            'game-screen-turn-banner must be present; none was found',
      );
      final String textForBob = _renderedTextAt(tester, _turnBannerKey);
      expect(
        textForBob,
        isNotEmpty,
        reason:
            'P4: game-screen-turn-banner must name the seat on turn, '
            'not render an empty string',
      );

      // Arm B: the same two seats, the same two names, but the turn and my
      // own seat are swapped -- the turn is now on seat 0 ("Sam") and I sit
      // in seat 1. A second, independent connection and mount is used rather
      // than pushing a turn frame through arm A's connection, because this
      // case is about which seat is named, not about a turn transition
      // (P9 below covers that path).
      final (controllerSam, _) = await _connectPlaying(
        tester,
        mySeat: 1,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controllerSam.dispose);
      expect(
        controllerSam.room!.turn!.seat,
        isNot(controllerSam.seat),
        reason: 'fixture is broken: arm B\'s turn must not belong to my seat',
      );

      await _mount(tester, controllerSam);

      expect(
        find.byKey(_turnBannerKey),
        findsOneWidget,
        reason:
            'P4: with the turn on seat 0 and my own seat 1, '
            'game-screen-turn-banner must be present; none was found',
      );
      final String textForSam = _renderedTextAt(tester, _turnBannerKey);
      expect(
        textForSam,
        isNotEmpty,
        reason:
            'P4: game-screen-turn-banner must name the seat on turn, '
            'not render an empty string',
      );

      // The point of the case: naming a different seat must render
      // different text. A _waitingForSeatText that ignored turnSeat and
      // always returned some constant non-empty string would pass every
      // assertion above and only fail here.
      expect(
        textForSam,
        isNot(textForBob),
        reason:
            'P4: game-screen-turn-banner must name the seat actually '
            'on turn -- waiting for seat 1 ("Bob") rendered "$textForBob" '
            'and waiting for seat 0 ("Sam") rendered "$textForSam"; a '
            'rendering that ignores which seat is on turn would produce '
            'the same text for both and is exactly what this comparison '
            'is here to catch',
      );
    },
  );

  // ==========================================================================
  // P5: the control, my own turn. Strengthened by order 145.
  // ==========================================================================
  //
  // Order 145: on this file's base commit, game-screen-waiting-for-seat is
  // already absent on my own turn regardless of what the screen actually
  // says, and a second, concurrent order deletes that key from
  // _playingBody outright, so after it lands the key is absent on every
  // turn and the old assertion alone would pass no matter what the screen
  // rendered. A first arm below mounts a connection where the turn is on
  // another seat and reads the waiting sentence straight off
  // game-screen-turn-banner, with no localized string typed into this file;
  // the control arm proper then requires that exact sentence to be found
  // nowhere at all in the tree once the turn moves to my own seat, in
  // addition to the still-kept findsNothing on the doomed key.
  testWidgets(
    'P5 (control): in a playing room where the turn belongs to this player, '
    'the waiting sentence is nowhere in the tree and game-screen-waiting-'
    'for-seat is absent; the board and the roll button are present',
    (tester) async {
      // Arm A: capture the waiting sentence game-screen-turn-banner renders
      // while the turn belongs to another seat, so the control arm below has
      // a real rendered string to prove absent rather than a guess at the
      // wording.
      final (controllerWaiting, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controllerWaiting.dispose);
      expect(
        controllerWaiting.room!.turn!.seat,
        isNot(controllerWaiting.seat),
        reason:
            'fixture is broken: the capture arm\'s turn must not belong to '
            'my seat',
      );

      await _mount(tester, controllerWaiting);
      expect(
        find.byKey(_turnBannerKey),
        findsOneWidget,
        reason:
            'P5: game-screen-turn-banner must be present to read the '
            'waiting sentence from before this case can prove it absent '
            'elsewhere',
      );
      final String waitingSentence = _renderedTextAt(tester, _turnBannerKey);
      expect(
        waitingSentence,
        isNotEmpty,
        reason:
            'P5: the waiting sentence read off game-screen-turn-banner '
            'must not be an empty string',
      );

      // Arm B: the control proper -- a second, independent connection where
      // the turn belongs to this player.
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.turn!.seat,
        controller.seat,
        reason: 'fixture is broken: the turn must belong to my own seat',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_waitingForSeatKey),
        findsNothing,
        reason:
            'P5: with the turn on my own seat, game-screen-waiting-for-seat '
            'must be absent',
      );
      expect(
        find.text(waitingSentence),
        findsNothing,
        reason:
            'P5: with the turn on my own seat, the waiting sentence '
            '"$waitingSentence" (read off game-screen-turn-banner in arm A, '
            'where the turn was on seat 1) must not be found anywhere in '
            'the tree; finding it would mean the screen said the waiting '
            'sentence on my own turn, which nothing here should render',
      );
      expect(
        find.byKey(_boardKey),
        findsOneWidget,
        reason: 'P5: the board must be present on my own turn',
      );
      expect(
        find.byKey(_rollKey),
        findsOneWidget,
        reason: 'P5: the roll button must be present on my own turn',
      );
    },
  );

  // ==========================================================================
  // P6: the control, no deadline.
  // ==========================================================================
  testWidgets(
    'P6 (control): in a playing room whose turn is null -- so there is no '
    'deadline_ms at all to show, per this file\'s header comment -- '
    'game-screen-turn-countdown is absent and nothing throws',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: null,
      );
      addTearDown(controller.dispose);
      expect(
        controller.room!.turn,
        isNull,
        reason: 'fixture is broken: room.turn must be null',
      );

      await _mount(tester, controller);

      expect(
        find.byKey(_countdownKey),
        findsNothing,
        reason:
            'P6: a playing room whose turn is null must never render '
            'game-screen-turn-countdown',
      );
    },
  );

  // ==========================================================================
  // P7: no timer survives the widget.
  // ==========================================================================
  testWidgets(
    'P7: mounting a playing room with a deadline and then pumping the '
    'widget tree away must leave no periodic timer behind for '
    'flutter_test\'s own pending-timer check to catch; asserting the '
    'countdown is present first stops this case passing vacuously on a '
    'base with no countdown at all',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);

      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason:
            'P7: game-screen-turn-countdown must be present while mounted '
            'for this case to prove anything about its timer surviving '
            'disposal; a base with no countdown at all must fail here '
            'rather than pass this case for having no timer to catch',
      );

      // Pump the tree away: GameScreen (and whatever State owns the
      // countdown's Timer) is disposed. If dispose does not cancel that
      // Timer, flutter_test's own binding fails this test on its own with
      // "A Timer is still pending even after the widget tree was disposed"
      // once this body returns -- nothing here asserts on that timer
      // directly.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  // ==========================================================================
  // P8 (new, order 143 gap 2): the periodic timer stops scheduling once it
  // reaches zero, proven while the widget stays mounted.
  // ==========================================================================
  //
  // flutter_test unmounts whatever widget tree is left standing at the end of
  // every testWidgets body and only then checks for a pending Timer
  // (test/binding.dart's _runTestBody: "Unmount any remaining widgets" runs
  // before _verifyInvariants). GameScreen.dispose cancels _countdownTimer
  // unconditionally, so that automatic unmount-and-check sequence cancels and
  // hides a countdown that kept rescheduling after zero before it is ever
  // asked whether it was still scheduling anything -- P7 exercises that exact
  // sequence and cannot see this defect for that reason. Reading the rendered
  // value cannot see it either: a countdown clamped at zero every second by a
  // timer that forgot to cancel itself renders identically to one whose timer
  // is actually gone (both P3 and P7 already read the value, never whether
  // anything is still scheduled).
  //
  // What is used instead: the Text widget GameScreen builds at
  // game-screen-turn-countdown is a fresh object on every rebuild, because
  // every call to State.build reconstructs its whole return value -- Flutter
  // does not diff a build's output against the last one before replacing it.
  // Capturing that widget's identity, advancing fake time well past the
  // deadline again, and re-capturing it therefore answers "did GameScreen
  // rebuild since the last sample" directly, with no dependence on whether
  // anything about the rendered value happened to change. A rebuild only
  // happens because something called setState; nothing on this screen does
  // that once mounted except the countdown's own timer tick and a
  // RoomController frame, and this case sends neither after the deadline.
  // If the periodic tick kept re-arming after clamping to zero, that stray
  // tick calls setState every second and this identity comparison catches
  // it; if it self-cancels as requirement 4 of order 141's contract
  // requires, nothing calls setState again and the same Text instance
  // persists.
  //
  // This was checked against a mutated scratch copy of game_screen.dart, not
  // argued statically alone: lib/src/game_screen.dart was copied outside the
  // repository, its imports repointed to package:ludo_client so the copy's
  // RoomController/GameScreen types stay the exact types this file's own
  // fixtures construct, and the else branch's `_countdownTimer?.cancel();
  // _countdownTimer = null;` (the two lines order 143 names as the surviving
  // mutation) was deleted. Against the unmodified copy, the identity
  // comparison below held (same instance, case passes); against the mutated
  // copy it did not (a new instance appeared after the second advance, case
  // fails) -- measured by running both through this same fixture idiom, not
  // by reasoning about the framework's internals alone.
  testWidgets(
    'P8: game-screen-turn-countdown stops scheduling rebuilds once the '
    'countdown reaches zero, checked by identity of the rendered widget '
    'across a further advance while still mounted, not by the rendered '
    'value or by anything the end-of-test unmount-and-check could paper over',
    (tester) async {
      final (controller, _) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 3000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);
      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason:
            'P8: game-screen-turn-countdown must be present before this '
            'case can measure anything about its timer self-cancelling',
      );

      // Cross the 3000ms deadline in one bounded pump, then confirm the
      // clamp reads zero -- this much is already covered by P3 and is only
      // a sanity check here, not this case's own assertion.
      await tester.pump(const Duration(seconds: 5));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        0,
        reason:
            'P8: fixture is broken: 5 seconds of pumped time past a 3000ms '
            'deadline must already read as clamped to 0',
      );

      final Widget beforeFurtherAdvance = _renderedTextWidgetAt(
        tester,
        _countdownKey,
      );

      // Advance well past another full tick interval with nothing else
      // touching the controller or the widget tree. A self-cancelled timer
      // schedules nothing here; a leaked one fires three more times.
      await tester.pump(const Duration(seconds: 3));

      final Widget afterFurtherAdvance = _renderedTextWidgetAt(
        tester,
        _countdownKey,
      );
      expect(
        identical(afterFurtherAdvance, beforeFurtherAdvance),
        isTrue,
        reason:
            'P8: game-screen-turn-countdown must not be rebuilt by a '
            'further 3 seconds of pumped time once the countdown has '
            'already clamped to zero -- rendering the same widget instance '
            'both before and after means nothing called setState in '
            'between; a periodic timer that forgot to cancel itself at zero '
            'would call setState every further second and this case '
            'reproduces with deadlineMs: 3000, mySeat: 0, seat: 0, phase: '
            "'await_roll'",
      );
    },
  );

  // ==========================================================================
  // P9 (new, order 143 gap 3): a turn transition on a mounted widget
  // re-anchors the countdown and leaves no timer from the previous segment
  // running.
  // ==========================================================================
  //
  // No case above ever pushes a second `turn` while the widget stays
  // mounted, so _syncCountdown's "cancel the running timer before re-arming
  // for the new (seat, deadlineMs) pair" branch has never run under test.
  // Checking only that the countdown reads the new deadline is not enough:
  // _countdownRemainingSeconds is reassigned from the fresh deadline
  // unconditionally on every genuinely new (seat, deadlineMs) pair, mutation
  // or not, so a re-anchor check alone passes whether or not the previous
  // segment's timer was ever cancelled. What distinguishes the two is what
  // happens next -- if the old timer is still ticking, it goes on
  // decrementing the same shared _countdownRemainingSeconds field the new
  // timer decrements, so a fixed further advance shows a smaller number than
  // a single live timer would ever produce.
  //
  // This was checked against a mutated scratch copy, the same way as P8:
  // lib/src/game_screen.dart copied outside the repository, imports
  // repointed to package:ludo_client, and this time the
  // `_countdownTimer?.cancel();` line in _syncCountdown immediately before
  // `_countdownSeat = turn.seat;` (the line order 143 names as the surviving
  // mutation for this gap) deleted. Run through this exact fixture idiom --
  // connect on seat 1 with a 45000ms deadline, advance 40 seconds, push a
  // `turn` frame moving to seat 0 with a fresh 10000ms deadline, advance 3
  // more seconds -- the unmodified copy read 7 (10 minus 3, one timer
  // decrementing once a second); the mutated copy read 4 (10 minus 6: the
  // superseded timer, never cancelled, ticks alongside the new one and both
  // decrement the same field on every one of those 3 seconds). The
  // re-anchor check alone (the fixture reading 10 immediately after the
  // pushed frame) passed identically on both copies, which is exactly what
  // this case's own comment above says it would do and why the exact-value
  // check after a further advance is the actual assertion, not the
  // re-anchor.
  testWidgets(
    'P9: pushing a second turn frame with a different (seat, deadlineMs) '
    'pair while the widget stays mounted re-anchors game-screen-turn-'
    'countdown to the new deadline and leaves no timer from the superseded '
    'segment still decrementing it, checked by an exact further-advance '
    'value a leaked second timer cannot produce',
    (tester) async {
      final (controller, transport) = await _connectPlaying(
        tester,
        mySeat: 0,
        seats: twoSeats,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);

      await _mount(tester, controller);
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        45,
        reason:
            'P9: fixture is broken: the first segment must start at the '
            '45000ms deadline put on the wire',
      );

      // Run the first segment most of the way down, so its timer has fired
      // repeatedly and is unambiguously live before the transition arrives.
      await tester.pump(const Duration(seconds: 40));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        5,
        reason:
            'P9: fixture is broken: 40 seconds of pumped time against a '
            '45000ms deadline must read 5',
      );

      // The turn transition: a different seat, a fresh deadline, pushed as
      // a real `turn` frame through the same FakeTransport this file's
      // _connectPlaying already drives, per docs/PROTOCOL.md section 5's
      // `turn` push shape ({seat, deadline_ms, seq}) and
      // net/room_controller.dart's _reduceTurn, which requires `seq` to be
      // exactly the room's previous seq plus one.
      final int nextSeq = controller.room!.seq + 1;
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 0,
            'deadline_ms': 10000,
            'seq': nextSeq,
          },
        ),
      );
      // Two pumps: the pushed frame is delivered to RoomController through
      // FakeTransport's StreamController, which schedules delivery as a
      // microtask rather than resolving inline. The first pump flushes that
      // microtask, which runs the reducer and calls setState, which
      // schedules a frame too late for that same pump to draw; the second
      // pump draws it. game_screen_test.dart's own push-then-pump-twice
      // sites (for example its 'rolled' reply after a roll request) use the
      // identical idiom for the identical reason.
      await tester.pump();
      await tester.pump();
      expect(
        controller.room!.turn!.seat,
        0,
        reason:
            'P9: fixture is broken: the pushed turn frame must have reached '
            'RoomController and moved the turn to seat 0',
      );
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        10,
        reason:
            'P9: the re-anchor half -- immediately after a turn push '
            'carrying deadline_ms 10000, game-screen-turn-countdown must '
            'read 10, not a value derived from the superseded 45000ms '
            'deadline',
      );

      // The half that actually distinguishes a cancelled previous timer
      // from a leaked one: a further, fixed advance. One live timer takes
      // 10 down to 7 over 3 seconds; a second, superseded timer still
      // ticking alongside it decrements the same shared field on every one
      // of those 3 seconds too, landing on 4 instead.
      await tester.pump(const Duration(seconds: 3));
      final int shownAfterTransition = _wholeSecondsShown(
        tester,
        _countdownKey,
      );
      expect(
        shownAfterTransition,
        7,
        reason:
            'P9: 3 seconds of pumped time after a turn transition to a '
            '10000ms deadline must read 7 -- a single live timer '
            'decrementing once a second. Got $shownAfterTransition; a '
            'timer from the superseded 45000ms segment left running '
            'alongside the new one would decrement the same counter twice '
            'a second and read 4 here, which is what this assertion is '
            'built to catch, reproduced with the sequence: connect turn '
            'seat 1 deadlineMs 45000, advance 40s, push turn seat 0 '
            'deadlineMs 10000 seq $nextSeq, advance 3s',
      );
    },
  );

  // ==========================================================================
  // P10 (new, order 145): the waiting sentence is on screen exactly once.
  // ==========================================================================
  //
  // work/ludo/evidence/144-game-ar-duplicate-waiting-line.png shows the real
  // Arabic game screen rendering the same sentence twice, one line the
  // turn banner and one line the (now doomed) standalone waiting-for-seat
  // widget beneath it. No case above can see that: every one of them reads
  // a single named key in isolation and asks what that one widget says,
  // never what the whole mounted tree says together, so a screen that
  // repeats a sentence on two different widgets is invisible to all of
  // them.
  //
  // What this case does instead: with the turn on a seat that is not this
  // player's, read whatever string game-screen-turn-banner is actually
  // showing -- no localized string is typed into this file, the sentence
  // used for the comparison is always the one the widget itself rendered --
  // and require find.text(...) of that exact string to match exactly one
  // widget anywhere in the tree. A screen that says the sentence once
  // passes; a screen that says it twice, on the banner and on a second,
  // independent widget, fails with two matches. Run in both locales this
  // package supports, per appSupportedLocales, because the photographed
  // defect was specifically the Arabic rendering.
  for (final locale in appSupportedLocales) {
    testWidgets(
      'locale ${locale.languageCode} -- P10: with the turn on a seat that is '
      'not this player\'s, the sentence rendered by game-screen-turn-banner '
      'is found exactly once in the whole mounted tree',
      (tester) async {
        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          seats: twoSeats,
          turn: _turnJson(
            seat: 1,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.turn!.seat,
          isNot(controller.seat),
          reason:
              'locale ${locale.languageCode} -- fixture is broken: the '
              'turn must not belong to my own seat',
        );

        await _mount(tester, controller, locale: locale);

        expect(
          find.byKey(_turnBannerKey),
          findsOneWidget,
          reason:
              'locale ${locale.languageCode} -- P10: game-screen-turn-'
              'banner must be present before this case can read the '
              'sentence it renders',
        );
        final String waitingSentence = _renderedTextAt(tester, _turnBannerKey);
        expect(
          waitingSentence,
          isNotEmpty,
          reason:
              'locale ${locale.languageCode} -- P10: the sentence read '
              'off game-screen-turn-banner must not be an empty string',
        );

        final int matches = find.text(waitingSentence).evaluate().length;
        expect(
          matches,
          1,
          reason:
              'locale ${locale.languageCode} -- P10: the sentence '
              '"$waitingSentence", read off game-screen-turn-banner with '
              'the turn on seat 1 and my own seat 0, must be found on '
              'exactly one widget in the whole mounted tree; found '
              '$matches. A screen that renders it a second time on an '
              'independent widget (as game-screen-waiting-for-seat does '
              'on this commit, reproduced with the sequence: connect '
              'mySeat 0, turn seat 1, deadlineMs 45000, locale '
              '${locale.languageCode}) is exactly what this count is '
              'built to catch',
        );
      },
    );
  }
}

/// Reads the rendered text at [key] the same way [_wholeSecondsShown] locates
/// its Text, but returns the raw string rather than parsing a number out of
/// it. Used by P4, which only needs to know the rendered text is non-empty
/// and present, not what number (there is none) it carries.
String _renderedTextAt(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  final Widget widget = tester.widget(finder);
  if (widget is Text) {
    return widget.data ?? '';
  }
  final Finder descendant = find.descendant(
    of: finder,
    matching: find.byType(Text),
  );
  expect(
    descendant,
    findsAtLeastNWidgets(1),
    reason:
        'the widget keyed $key is a ${widget.runtimeType}, not a '
        'Text, and carries no Text descendant to read rendered text from',
  );
  final Text text = tester.widget<Text>(descendant.first);
  return text.data ?? '';
}

/// Locates the same Text [_wholeSecondsShown] and [_renderedTextAt] read from
/// [key], but returns the widget instance itself rather than a value parsed
/// or copied out of it. Used by P8, which needs to tell whether
/// [GameScreen] rebuilt at all between two samples -- every call to
/// State.build constructs a brand new Text object regardless of whether the
/// string it carries changed, so two samples taken across a pump with no
/// rebuild in between are the same object (`identical`), and two samples
/// taken across a pump that did rebuild are not, independently of what
/// either one renders.
Widget _renderedTextWidgetAt(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  final Widget widget = tester.widget(finder);
  if (widget is Text) {
    return widget;
  }
  final Finder descendant = find.descendant(
    of: finder,
    matching: find.byType(Text),
  );
  expect(
    descendant,
    findsAtLeastNWidgets(1),
    reason:
        'the widget keyed $key is a ${widget.runtimeType}, not a '
        'Text, and carries no Text descendant to read a widget instance '
        'from',
  );
  return tester.widget<Text>(descendant.first);
}
