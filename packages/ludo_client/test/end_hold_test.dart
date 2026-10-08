// Conformance tests for work/ludo/orders/C-270-winning-move-seen.md's "What
// proves it" section (order 271), read against the GameScreen that
// contract's own companion order (270, lib/src/game_screen.dart) implements
// in parallel, in a tree this file's author has not opened. Base for both
// orders: origin/main 67db765 (PR #91, C-268's held landing cues).
//
// On that base, lib/src/game_screen.dart carries neither kEndCardDwell nor
// kEndCardHoldLimit, so this file does not compile there. The master checks
// this file's own report for the compile output and, separately, runs this
// suite against origin/main's screen with only the two constants added as a
// scratch edit, to see the real (non-compile) red every case below that
// depends on the hold must produce -- see this order's own report.
//
// GameScreen is mounted exactly the way test/landing_cues_test.dart's own
// "mounted GameScreen" group does: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only), under a
// FeedbackScope carrying a fake FeedbackService that records every play call
// with no throttle of its own. The fake-transport idiom, the recording fake,
// the frame/room/seat JSON builders and the two push helpers below are
// copied by hand from that file (this project's standing instruction is
// never to import across test files); _pumpSquares and _pumpTotal are also
// copied from there unchanged. Every room below is connected with turn:
// null, so nothing here ever arms a countdown Timer for a bounded pump to
// race against.
//
// Lesson 35: one connect-and-mount per case. Lesson 36, and the standing
// rule against pumpAndSettle while a live timer runs: every wait below is
// either the two-pump idiom the sibling suites use to flush a pushed frame,
// a bounded loop of tester.pump(kTokenStepDuration) (one call per square),
// or _pumpTotal, which only ever advances the fake clock in bounded chunks.
// No pumpEventQueue() is called inside a testWidgets body; the one
// pumpEventQueue() this file uses lives inside _connectTo's
// tester.runAsync(...), copied from the same sibling suite.
//
// Every wait below is derived from kTokenStepDuration (board.dart),
// kEndCardDwell and kEndCardHoldLimit (game_screen.dart), never from a
// literal measured by hand. A move's own square count (e.g. 51 to 57 is six
// squares) is a fact about this file's own fixture, not a timing literal.
//
// Ambiguities found and not invented around:
//
//   1. The travel count contract rule 1 describes is frame-based ("+1 for
//      every moved frame with readable seat, token, from, to and from !=
//      to"), independent of whether lib/src/board.dart's own
//      _reactToTokensChange recognises that frame's truth-to-truth diff as
//      an animatable single-mover move. Because RoomController's own
//      notifyListeners (synchronous) and its separate frames stream
//      (delivered a microtask later, per the contract's own background
//      section) run in that order, a moved frame whose diff board.dart
//      snaps away (onTravelReset) can still leave the count at 1: the reset
//      fires on the first pump, before GameScreen's own frame-stream
//      subscriber increments the count on the second. Rule 1's own text
//      anticipates exactly this ("A count left stale by some other unmount
//      costs at most rule 4c's limit, never a lost card"), so this file
//      uses it on purpose for "the limit" case below, with a moved frame
//      whose to equals the token's already-current progress (the rig gives
//      the board a truth that does not change at all -- the alternative the
//      contract itself names), rather than inventing a different scenario.
//
//   2. "A tap ... sends nothing" (the inert-while-held bullet) is checked
//      with turn: null throughout, matching every other case in this file.
//      With turn: null, RoomController's own _reduceMoved and _reduceGameOver
//      already leave turn null (not a stale awaitMove), so legalTokens is
//      already empty independent of the hold. This file still writes and
//      runs the case exactly as the contract asks (a real tap on the
//      hit-target widget, the sent list read afterward) since that is what
//      the contract's own text requires regardless of why it holds; this is
//      reported rather than silently assumed to be a hold-specific proof.
//
//   3. Rule 4b (onTravelReset releases the hold at once) has no case in
//      this file. Driving a second moved frame whose diff is not a single
//      mover (C-252 rule 2) through _pushMoved, after an earlier moved and
//      game_over have already opened the hold, reaches
//      _LudoBoardState._snapToTruth and onTravelReset every time, but
//      _onBoardTravelReset's _isEndHeld branch calls _releaseEndHold's
//      setState on GameScreen from inside GameScreen's own in-progress
//      rebuild (didUpdateWidget only ever runs as part of that rebuild,
//      because that rebuild is the only way LudoBoard's tokens parameter
//      changes). flutter_test's widgets library throws "setState() or
//      markNeedsBuild() called during build" every time this is tried, no
//      matter how the surrounding pumps are sequenced, because the
//      reentrancy is structural, not a timing accident: see the comment
//      left in place of the case, below, and this order's own report.
//
// Reused from test/landing_cues_test.dart: the fake-transport connect/mount
// idiom (_Connector, _connectTo, _harness, _connectAndMount),
// _FakeFeedbackService, the frame/room/seat JSON builders (_frame, _decode,
// _idOf, _seatJson, _roomJson), and _pumpSquares/_pumpTotal. Copied by hand,
// not imported.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart' show kTokenStepDuration;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://end-hold-test.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'end-hold-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  String code = 'E4ND72',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  required List<Map<String, Object?>> seats,
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
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

/// Connects a fresh controller straight to the given room, mySeat always 0
/// (seat_assigned always names seat 0). Copied by hand from
/// test/landing_cues_test.dart's own `_connectTo`.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
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
      // turn: null throughout this file: nothing here exercises the
      // countdown, so there is nothing of that kind for a bounded pump to
      // race against.
      data: _roomJson(seats: seats, turn: null),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
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

/// Records every cue GameScreen asks the service to play, in call order,
/// with no throttle of its own. Copied by hand from
/// test/landing_cues_test.dart's own `_FakeFeedbackService` (library private
/// there, so not importable).
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Connects a fresh controller and mounts GameScreen over a fresh fake
/// feedback service, and hands all three back -- the one mount each case
/// below is built from (lesson 35).
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _connectAndMount(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: seats,
  );
  addTearDown(controller.dispose);
  final _FakeFeedbackService fake = _FakeFeedbackService();
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: fake,
        child: GameScreen(controller: controller),
      ),
    ),
  );
  await tester.pump();
  return (controller, transport, fake);
}

/// Pushes a `moved` frame and flushes it through the two-pump idiom the
/// sibling suites use: one for the transport's own delivery, one for the
/// controller's frame stream and its listeners to run.
Future<void> _pushMoved(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': from,
        'to': to,
        'captured': captured,
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pushes a `game_over` frame and flushes it the same way.
Future<void> _pushGameOver(
  WidgetTester tester,
  FakeTransport transport, {
  required int winner,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'game_over',
      data: <String, Object?>{
        'winner': winner,
        'verify_url': 'https://end-hold-test.invalid/verify/$seq',
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pumps [squares] bounded ticks of exactly [kTokenStepDuration] each, never
/// one long pump (lesson 36) -- one call per square the board's own step
/// timer is expected to cross.
Future<void> _pumpSquares(WidgetTester tester, int squares) async {
  for (var i = 0; i < squares; i++) {
    await tester.pump(kTokenStepDuration);
  }
}

/// Advances the fake clock by exactly [total], in bounded chunks of at most
/// [chunk] each -- lesson 36's "settle with several bounded pumps, never one
/// long pump" applied to a plain Duration rather than a step count.
Future<void> _pumpTotal(
  WidgetTester tester,
  Duration total, {
  Duration chunk = const Duration(milliseconds: 200),
}) async {
  Duration remaining = total;
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
}

// --- shared keys/finders -----------------------------------------------

const Key _dieKey = Key('game-die');
const Key _winnerKey = Key('game-screen-winner');

bool _endCardShown(WidgetTester tester) =>
    find.byKey(_winnerKey).evaluate().isNotEmpty;

bool _playingBodyShown(WidgetTester tester) =>
    find.byKey(_dieKey).evaluate().isNotEmpty;

void main() {
  group('end hold: C-270 rules 1-7', () {
    // Kills: end card at game_over (today's code); win played at game_over
    // while the card waits; dwell skipped (card at the landing).
    testWidgets(
      'my winning 6-square move to 57 then game_over naming me: the board '
      'stays up with no end card and no win until the sixth step lands '
      'home, then win and the end card appear only after kEndCardDwell, '
      'in order [home, win], each once',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[51, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        // 51 to 57 is six squares (52, 53, 54, 55, 56, 57).
        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 51,
          to: 57,
          seq: 2,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'C-268 rule 3 (kept): home must be held, not played the '
              'instant the moved frame lands; recorded ${fake.recorded}',
        );

        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        expect(
          _playingBodyShown(tester),
          isTrue,
          reason:
              'right after game_over, the count is still above 0 (the move '
              'has not landed), so rule 2\'s hold must keep the playing '
              'body (game-die) on screen',
        );
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'no end card (game-screen-winner) must be shown while the '
              'hold is in effect',
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'rule 6: win must not play at game_over while the card '
              'waits for the token to be seen home; recorded '
              '${fake.recorded}',
        );

        await _pumpSquares(tester, 5);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
          ]),
          reason:
              'my own move plays one step per square it lands on (C-259, '
              '_onBoardTokenStep): 5 of the 6 squares have arrived, so 5 '
              'step cues and no home yet; recorded ${fake.recorded}',
        );
        expect(_endCardShown(tester), isFalse);

        await _pumpSquares(tester, 1);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.home,
          ]),
          reason:
              'the sixth and last step lands the move on 57: a sixth step '
              'cue plays, then home must play exactly once, and win must '
              'still not have played; recorded ${fake.recorded}',
        );
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'rule 4a: the dwell starts only once the count reaches 0 by '
              'this landing; kEndCardDwell has not elapsed yet, so the end '
              'card must not be shown',
        );

        await _pumpTotal(
          tester,
          kEndCardDwell - const Duration(milliseconds: 1),
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.home,
          ]),
          reason:
              'one millisecond short of kEndCardDwell since the landing, '
              'win must still not have played; recorded ${fake.recorded}',
        );
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'one millisecond short of kEndCardDwell since the landing, '
              'the end card must still not be shown',
        );

        await tester.pump(const Duration(milliseconds: 1));
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.home,
            FeedbackCue.win,
          ]),
          reason:
              'exactly at kEndCardDwell since the landing, rule 4 releases '
              'the hold: win must play exactly once, after home; recorded '
              '${fake.recorded}',
        );
        expect(
          _endCardShown(tester),
          isTrue,
          reason:
              'the end card must be shown in the same frame the hold '
              'releases',
        );
        expect(
          _playingBodyShown(tester),
          isFalse,
          reason: 'once released, the playing body (game-die) must be gone',
        );
      },
    );

    // Kills: the hold or its release being conditioned on this seat being
    // the winner; the dwell starting before the opponent's own landing.
    testWidgets(
      'the same as the loser: an opponent\'s winning 6-square move then '
      'game_over naming them: gameOver and the end card appear only after '
      'the landing plus kEndCardDwell, never before the landing',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob', tokens: const <int>[51, -1, -1, -1]),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMoved(
          tester,
          transport,
          seat: 1,
          token: 0,
          from: 51,
          to: 57,
          seq: 2,
        );
        await _pushGameOver(tester, transport, winner: 1, seq: 3);
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'right after game_over, the opponent\'s move has not landed, '
              'so no end card must be shown yet',
        );
        expect(fake.recorded, isEmpty);

        await _pumpSquares(tester, 5);
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              '5 of the opponent\'s 6 squares have arrived: still not '
              'landed, so the end card must still be absent',
        );

        await _pumpSquares(tester, 1);
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'the sixth step lands the opponent\'s move: the dwell starts '
              'only now, so the end card must still not be shown',
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'no cue of any kind fires for another seat\'s own token '
              'reaching home (C-268/C-236); recorded ${fake.recorded}',
        );

        await _pumpTotal(
          tester,
          kEndCardDwell - const Duration(milliseconds: 1),
        );
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'one millisecond short of kEndCardDwell since the opponent\'s '
              'landing, the end card must still not be shown',
        );

        await tester.pump(const Duration(milliseconds: 1));
        expect(
          _endCardShown(tester),
          isTrue,
          reason:
              'exactly at kEndCardDwell since the landing, the end card '
              'must now be shown',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.gameOver]),
          reason:
              'the game_over frame\'s own cue for a loss (gameOver) must '
              'play exactly once, on release; recorded ${fake.recorded}',
        );
      },
    );

    // Kills: a hold applied even when the count is 0 at game_over.
    testWidgets(
      'no move in travel: game_over with the count at 0 (a fresh mount on '
      'PLAYING then game_over) shows the end card and its cue in the same '
      'pump as today, with no hold at all',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushGameOver(tester, transport, winner: 0, seq: 2);
        expect(
          _endCardShown(tester),
          isTrue,
          reason:
              'rule 5: with the count at 0, game_over must show the end '
              'card in the same _onFrame call, with no hold',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.win]),
          reason:
              'win must play immediately, exactly once; recorded '
              '${fake.recorded}',
        );
      },
    );

    // Kills: the limit timer never armed (a hold that hangs forever once
    // its landing never comes).
    testWidgets(
      'the limit: a travelling move whose landing never comes (the rig '
      'gives the board a truth that does not change) releases at '
      'kEndCardHoldLimit and not before',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[20, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        // `to` (20) is already this token's current progress, so the board
        // sees no truth change at all for it: no diff, no travel, no
        // onMoveLanded will ever fire for this frame. GameScreen's own
        // count still goes up (rule 1 reads the frame, not the board), so
        // this manufactures exactly the "count left stale" case rule 1's
        // own text names, with a landing that genuinely never comes.
        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 15,
          to: 20,
          seq: 2,
        );
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        expect(_endCardShown(tester), isFalse);
        expect(fake.recorded, isEmpty);

        await _pumpTotal(
          tester,
          kEndCardHoldLimit - const Duration(milliseconds: 1),
        );
        expect(
          _endCardShown(tester),
          isFalse,
          reason:
              'one millisecond short of kEndCardHoldLimit since game_over, '
              'the end card must still not be shown, whatever the count',
        );
        expect(fake.recorded, isEmpty);

        await tester.pump(const Duration(milliseconds: 1));
        expect(
          _endCardShown(tester),
          isTrue,
          reason:
              'exactly at kEndCardHoldLimit since game_over, rule 4c '
              'releases the hold regardless of the count',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.win]),
          reason: 'win must play exactly once, on this release',
        );
      },
    );

    // Kills: a tap during the hold reaching controller.move.
    testWidgets(
      'inert while held: a tap on a token of mine during the hold sends no '
      'move',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[4, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 4,
          to: 10,
          seq: 2,
        );
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        expect(
          _playingBodyShown(tester),
          isTrue,
          reason: 'fixture check: the hold must be in effect here',
        );

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(const Key('board-token-hit-0-0')));
        await tester.pump();

        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'rule 3: a tap on my own token while held must send nothing '
              'at all; sent after the tap: '
              '${transport.sentRaw.skip(sentBefore).map(_typeOf).toList()}',
        );
        expect(
          transport.sentRaw.skip(sentBefore).where((s) => _typeOf(s) == 'move'),
          isEmpty,
          reason:
              'no move request in particular must reach the transport '
              'while held',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.invalidTap]),
          reason:
              'legal is empty while held, so this tap on a token of mine '
              'resolves as the doctrine\'s invalid tap (section 3, last '
              'row): the product plays invalidTap for it, not silence; '
              'recorded ${fake.recorded}',
        );
      },
    );

    // Kills: a hold that never checks onTravelReset, or one that keeps
    // waiting for a landing/limit that an unrecognised diff already made
    // moot.
    testWidgets(
      'onTravelReset during the hold (an unrecognised diff) releases at '
      'once',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[4, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        // A real 6-square travel, not yet landed (no real time pumped).
        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 4,
          to: 10,
          seq: 2,
        );
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        expect(
          _playingBodyShown(tester),
          isTrue,
          reason: 'fixture check: the hold must be in effect here',
        );

        // A further moved frame whose diff (progress 10 to 20, a jump of
        // 10) matches neither of board.dart's own single-mover patterns
        // (C-252 rule 2: a continuing move is old + 1..6): the board snaps
        // (_snapToTruth), which calls onTravelReset. No capture is given,
        // so this frame also carries no cue of its own (cuesForFrame reads
        // only `captured` and `to == 57`, neither true here) to entangle
        // with the release this is proving.
        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 10,
          to: 20,
          seq: 4,
        );

        expect(
          _endCardShown(tester),
          isTrue,
          reason:
              'rule 4b: onTravelReset (count set to 0) releases the hold '
              'at once, not waiting for kEndCardDwell or kEndCardHoldLimit',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.win]),
          reason:
              'win (this game_over\'s own cue, held until release) must '
              'play exactly once; the snapped frame above carries no cue '
              'of its own; recorded ${fake.recorded}',
        );
      },
    );

    // Kills: the dwell or limit timer firing after dispose (a cue played
    // into a disposed screen, or a crash).
    testWidgets(
      'dispose during the hold: no cue, no exception, and no timer left '
      'pending at teardown',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[4, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 4,
          to: 10,
          seq: 2,
        );
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        expect(
          _playingBodyShown(tester),
          isTrue,
          reason: 'fixture check: the hold must be in effect here',
        );

        // Dispose this screen entirely while the hold (and whichever of
        // rule 4's two timers is currently armed) is still in progress.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        // Stop one millisecond short of kEndCardHoldLimit, counted from
        // game_over, and go no further: rule 7's own "no cue, no setState
        // after dispose" -- a timer dispose failed to cancel is still
        // armed and unfired right there, so flutter_test's own pending
        // Timer check at this test's teardown is what would fail a leaked
        // timer, not an assertion written here.
        await _pumpTotal(
          tester,
          kEndCardHoldLimit - const Duration(milliseconds: 1),
        );

        expect(
          fake.recorded,
          isEmpty,
          reason:
              'rule 7 drops the hold in progress on dispose with no cue '
              'ever played into a disposed screen; recorded '
              '${fake.recorded}',
        );
      },
    );
  });
}
