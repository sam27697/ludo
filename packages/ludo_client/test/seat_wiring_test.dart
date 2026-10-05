// Conformance tests for work/ludo/orders/C-257-seat-wiring.md, written from
// that contract's text alone. Order 257 (lib/src/game_screen.dart) is not
// yet dispatched and this file's author has not read it; every expectation
// below is read off C-257's own text, never off a prior or later state of
// game_screen.dart.
//
// GameScreen is mounted the way test/feedback_wiring_test.dart and
// test/play_header_test.dart mount it: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only), under a
// FeedbackScope carrying a fake FeedbackService, since GameScreen._onFrame
// calls FeedbackScope.of(context) for every frame its own subscription sees
// regardless of what cue (if any) that frame carries. The fake-transport
// idiom (_Connector, pushText, the JSON helpers) and the harness are copied
// by hand from those two files' own copies, per their shared instruction
// never to import across test files.
//
// On base ac19bb3: LudoBoard.seatNames, .youLabel and .turnSeat are never
// given a value by game_screen.dart's first (playing) LudoBoard, SeatPipStrip
// is built with no seats: or turnSeat:, the end-view LudoBoard (the
// game_over body) carries none of seatNames/youLabel/turnSeat either, and
// LudoBoard.onTokenStep is never given a value. Every case below is
// expected red on that base for exactly one of those reasons -- a key not
// found where the rule says one must be, a key found where the rule says
// none must be, or a wired parameter reading null.
//
// loc.seatYou does not exist on this base (no AppLocalizations member of
// that name was generated here) even though C-257 rule 1 names it as the
// youLabel to pass; this file does not call it, and compares the chip's own
// "You" tag against the plain literals "You" and "أنت" instead, exactly
// as this order's own text asks, rather than against a getter that would
// fail to compile.
//
// Ambiguity found and not invented around (reported in this run's own
// delivery note, repeated here for whoever reads this file next): C-257
// rule 4's "What proves it" text describes proving the step tick by pushing
// a real `moved` frame and reading the fake feedback service's recorded
// list afterward. On this base, lib/src/feedback.dart's own _cuesForMoved
// already appends one FeedbackCue.step per square travelled for a `moved`
// frame naming my own seat, played synchronously by GameScreen._onFrame
// the instant the frame lands -- entirely independent of LudoBoard
// .onTokenStep, which game_screen.dart never gives a value on this base.
// A case that only reads the final recorded list after pushing such a
// frame would therefore already be green on ac19bb3, for a reason that has
// nothing to do with this contract's own wiring. To keep this case red for
// the reason it names, it instead reads LudoBoard.onTokenStep itself off
// the mounted widget (asserting it is non-null, which it is not on this
// base) and then, in the one GameScreen the contract's rule 4 names, calls
// that exact function the same way lib/src/board.dart's own
// _onStepElapsed does -- `widget.onTokenStep?.call(move.seat, move.token)`
// -- to prove what it does for my own seat's token and for another seat's,
// without needing the ambiguous _cuesForMoved path to run at all.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://seat-wiring-test.invalid/ws';

const Key _boardKey = Key('game-screen-board');
const Key _pipStripKey = Key('game-seat-pip-strip');

Key _seatNameKey(int seat) => Key('board-seat-name-$seat');
Key _turnYardKey(int seat) => Key('board-turn-yard-$seat');
Key _pipKey(int seat) => Key('game-seat-pip-$seat');
const Key _youKey = Key('board-seat-you');
const Key _pipTurnKey = Key('game-seat-pip-turn');

// --- server-side id generation for pushed frames, copied by hand from the
// sibling suites' own idiom ---------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'seat-wiring-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, copied by hand from the sibling suites -----------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
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
/// (seat_assigned always names seat 0). Copied by hand from the sibling
/// suites' own `_connectTo` / `_connectDirect`.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
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
      data: _roomJson(state: state, seats: seats, turn: turn, winner: winner),
    ),
  );
  await future;
  return (controller, transport);
}

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

/// Records every cue GameScreen asks the service to play, in call order.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Connects a fresh controller and mounts GameScreen over a fresh fake
/// feedback service, and hands all three back -- the one mount every case
/// below is built from.
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _connectAndMount(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
  Locale locale = const Locale('en'),
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: seats,
    state: state,
    turn: turn,
    winner: winner,
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
      locale: locale,
    ),
  );
  await tester.pump();
  return (controller, transport, fake);
}

void main() {
  // ==========================================================================
  // Rule 1: the playing board's seatNames, youLabel and turnSeat.
  // ==========================================================================
  group('Rule 1: names in the yards', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(2, name: 'Lina'),
    ];

    // Kills: game_screen.dart never passing seatNames/youLabel/turnSeat to
    // the playing LudoBoard at all (ac19bb3's own state, where none of the
    // five keys below is ever found), and a turnSeat that is set once and
    // then never re-synced to a fresh `turn` frame.
    testWidgets(
      'two-seat game (seats 0 Sam, 2 Lina, me 0): board-seat-name-0 reads '
      'Sam, board-seat-name-2 reads Lina, no chip for seat 1 or 3, exactly '
      'one board-seat-you inside seat 0\'s chip, and board-turn-yard-<s> '
      'exists exactly for the turn seat and moves when the turn passes',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectAndMount(
          tester,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );

        expect(
          find.descendant(
            of: find.byKey(_seatNameKey(0)),
            matching: find.text('Sam'),
          ),
          findsOneWidget,
          reason:
              'C-257 rule 1: board-seat-name-0 must read seat 0\'s own '
              'room.seats name ("Sam"); not found -- seatNames is likely '
              'still null on the playing LudoBoard',
        );
        expect(
          find.descendant(
            of: find.byKey(_seatNameKey(2)),
            matching: find.text('Lina'),
          ),
          findsOneWidget,
          reason:
              'C-257 rule 1: board-seat-name-2 must read seat 2\'s own '
              'room.seats name ("Lina"); not found -- seatNames is likely '
              'still null on the playing LudoBoard',
        );
        expect(
          find.byKey(_seatNameKey(1)),
          findsNothing,
          reason:
              'seat 1 is not occupied in this fixture; board-seat-name-1 '
              'must not exist',
        );
        expect(
          find.byKey(_seatNameKey(3)),
          findsNothing,
          reason:
              'seat 3 is not occupied in this fixture; board-seat-name-3 '
              'must not exist',
        );

        expect(
          find.byKey(_youKey),
          findsOneWidget,
          reason:
              'C-257 rule 1: exactly one board-seat-you must exist (mySeat '
              'is 0, which has a seatNames entry); not found -- youLabel is '
              'likely still null',
        );
        expect(
          find.descendant(
            of: find.byKey(_seatNameKey(0)),
            matching: find.byKey(_youKey),
          ),
          findsOneWidget,
          reason: 'board-seat-you must sit inside seat 0\'s own name chip',
        );
        final Text youText = tester.widget<Text>(find.byKey(_youKey));
        expect(
          youText.data,
          'You',
          reason:
              'board-seat-you must read the literal "You" under Locale(en) '
              '(loc.seatYou does not exist on this base, see this file\'s '
              'header); got "${youText.data}"',
        );

        expect(
          find.byKey(_turnYardKey(0)),
          findsOneWidget,
          reason:
              'C-257 rule 1: board-turn-yard-0 must exist while seat 0 is '
              'the current turn and the room is PLAYING; not found -- '
              'turnSeat is likely still null on the playing LudoBoard',
        );
        expect(
          find.byKey(_turnYardKey(2)),
          findsNothing,
          reason:
              'board-turn-yard-2 must not exist while the turn belongs to '
              'seat 0, not seat 2',
        );

        // The turn passes to seat 2: the glow must follow it.
        final int nextSeq = controller.room!.seq + 1;
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 2,
              'deadline_ms': 45000,
              'seq': nextSeq,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.room!.turn!.seat,
          2,
          reason:
              'fixture is broken: the turn frame pushed above must have '
              'landed on RoomController',
        );
        expect(
          find.byKey(_turnYardKey(2)),
          findsOneWidget,
          reason:
              'C-257 rule 1: board-turn-yard-2 must appear once the turn '
              'passes to seat 2',
        );
        expect(
          find.byKey(_turnYardKey(0)),
          findsNothing,
          reason:
              'board-turn-yard-0 must disappear once the turn is no longer '
              'seat 0\'s; a turnSeat set once and never re-synced would '
              'leave this behind',
        );
      },
    );

    // Kills: a youLabel hardcoded to the English word regardless of locale.
    testWidgets('under Locale(ar), board-seat-you reads the Arabic "أنت"', (
      tester,
    ) async {
      await _connectAndMount(
        tester,
        seats: seats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
        locale: const Locale('ar'),
      );

      expect(
        find.byKey(_youKey),
        findsOneWidget,
        reason:
            'C-257 rule 1: board-seat-you must exist under Locale(ar) '
            'too; not found -- youLabel is likely still null',
      );
      final Text youText = tester.widget<Text>(find.byKey(_youKey));
      expect(
        youText.data,
        'أنت',
        reason:
            'board-seat-you must read the literal Arabic "أنت" under '
            'Locale(ar) (loc.seatYou does not exist on this base, see '
            'this file\'s header); got "${youText.data}"',
      );
    });
  });

  // ==========================================================================
  // Rule 2: the pip strip.
  // ==========================================================================
  group('Rule 2: the pip strip', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(2, name: 'Lina'),
    ];

    // Kills: SeatPipStrip never given seats: (every one of the four pips
    // drawn regardless of who is seated, ac19bb3's own state) and a
    // turnSeat never synced to a later `turn` frame.
    testWidgets('exactly game-seat-pip-0 and game-seat-pip-2 are drawn; '
        'game-seat-pip-turn is the turn seat\'s and follows the turn', (
      tester,
    ) async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectAndMount(
        tester,
        seats: seats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );

      final SeatPipStrip strip = tester.widget<SeatPipStrip>(
        find.byKey(_pipStripKey),
      );
      expect(
        strip.seats,
        <int>[0, 2],
        reason:
            'C-257 rule 2: SeatPipStrip.seats must be the occupied seats '
            '[0, 2]; got ${strip.seats}',
      );
      expect(
        strip.turnSeat,
        0,
        reason:
            'C-257 rule 2: SeatPipStrip.turnSeat must be the current '
            'turn seat (0) while PLAYING; got ${strip.turnSeat}',
      );

      expect(
        find.byKey(_pipKey(0)),
        findsOneWidget,
        reason: 'game-seat-pip-0 must be drawn; seat 0 is occupied',
      );
      expect(
        find.byKey(_pipKey(2)),
        findsOneWidget,
        reason: 'game-seat-pip-2 must be drawn; seat 2 is occupied',
      );
      expect(
        find.byKey(_pipKey(1)),
        findsNothing,
        reason:
            'game-seat-pip-1 must not be drawn; seat 1 is not occupied '
            '-- SeatPipStrip is likely still given no seats: at all',
      );
      expect(
        find.byKey(_pipKey(3)),
        findsNothing,
        reason:
            'game-seat-pip-3 must not be drawn; seat 3 is not occupied '
            '-- SeatPipStrip is likely still given no seats: at all',
      );
      expect(
        find.byKey(_pipTurnKey),
        findsOneWidget,
        reason:
            'game-seat-pip-turn must exist while seat 0 is the current '
            'turn; not found -- SeatPipStrip.turnSeat is likely still '
            'null',
      );
      expect(
        find.descendant(
          of: find.byKey(_pipTurnKey),
          matching: find.byKey(_pipKey(0)),
        ),
        findsOneWidget,
        reason: 'game-seat-pip-turn must wrap seat 0\'s own pip',
      );

      final int nextSeq = controller.room!.seq + 1;
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 2,
            'deadline_ms': 45000,
            'seq': nextSeq,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(_pipTurnKey),
          matching: find.byKey(_pipKey(2)),
        ),
        findsOneWidget,
        reason:
            'once the turn passes to seat 2, game-seat-pip-turn must '
            'wrap seat 2\'s own pip',
      );
      expect(
        find.descendant(
          of: find.byKey(_pipTurnKey),
          matching: find.byKey(_pipKey(0)),
        ),
        findsNothing,
        reason:
            'once the turn passes to seat 2, game-seat-pip-turn must no '
            'longer wrap seat 0\'s pip',
      );
    });
  });

  // ==========================================================================
  // Rule 3: the end view.
  // ==========================================================================
  group('Rule 3: the end view', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(2, name: 'Lina'),
    ];

    // Kills: the end-view LudoBoard never given seatNames/youLabel at all
    // (ac19bb3's own state: the game_over body's second LudoBoard call
    // carries only tokens: and seatsInPlay:), and an end-view board that
    // carries room.turn's lingering seat through as turnSeat instead of
    // the null rule 3 asks for.
    testWidgets(
      'on game_over, the end view\'s board shows the seat names and no '
      'board-turn-yard-*',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectAndMount(
          tester,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );

        final int nextSeq = controller.room!.seq + 1;
        transport.pushText(
          _frame(
            type: 'game_over',
            data: <String, Object?>{
              'winner': 0,
              'verify_url': 'https://seat-wiring-test.invalid/verify/1',
              'seq': nextSeq,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.room!.state.name.toUpperCase(),
          'FINISHED',
          reason:
              'fixture is broken: the game_over frame pushed above must '
              'have landed on RoomController',
        );

        expect(
          find.descendant(
            of: find.byKey(_seatNameKey(0)),
            matching: find.text('Sam'),
          ),
          findsOneWidget,
          reason:
              'C-257 rule 3: the end-view board\'s board-seat-name-0 must '
              'read "Sam"; not found -- seatNames is likely still null on '
              'the end-view LudoBoard',
        );
        expect(
          find.descendant(
            of: find.byKey(_seatNameKey(2)),
            matching: find.text('Lina'),
          ),
          findsOneWidget,
          reason:
              'C-257 rule 3: the end-view board\'s board-seat-name-2 must '
              'read "Lina"; not found -- seatNames is likely still null on '
              'the end-view LudoBoard',
        );
        expect(
          find.byKey(_turnYardKey(0)),
          findsNothing,
          reason:
              'C-257 rule 3: the end view must pass turnSeat: null; '
              'board-turn-yard-0 must not exist even though room.turn still '
              'names seat 0',
        );
        expect(
          find.byKey(_turnYardKey(2)),
          findsNothing,
          reason: 'board-turn-yard-2 must not exist on the end view either',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 4: the step tick.
  // ==========================================================================
  group('Rule 4: the step tick', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[3, -1, -1, -1]),
      _seatJson(1, name: 'Bob', tokens: const <int>[10, -1, -1, -1]),
    ];

    // Kills: LudoBoard.onTokenStep never given a value at all (ac19bb3's own
    // state -- see this file's header for why a case that only reads the
    // fake service's recorded list after a real `moved` frame would not be
    // red on this base for the reason this rule names); a step of my own
    // token playing no cue, or any cue other than exactly one
    // FeedbackCue.step; and a step of another seat's token playing anything
    // at all.
    testWidgets(
      'LudoBoard.onTokenStep plays exactly one FeedbackCue.step for a step '
      'of my own token, and nothing for a step of another seat\'s',
      (tester) async {
        final (_, _, _FakeFeedbackService fake) = await _connectAndMount(
          tester,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );

        final LudoBoard board = tester.widget<LudoBoard>(find.byKey(_boardKey));
        expect(
          board.onTokenStep,
          isNotNull,
          reason:
              'C-257 rule 4: the playing LudoBoard\'s onTokenStep must be '
              'wired so a step of my own token plays FeedbackCue.step; '
              'game_screen.dart currently passes none on this base '
              '(board.onTokenStep is null)',
        );

        fake.recorded.clear();
        board.onTokenStep!(0, 0);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.step]),
          reason:
              'a step of my own seat\'s (0) token must play exactly one '
              'FeedbackCue.step through FeedbackScope.of(context); recorded '
              '${fake.recorded}',
        );

        fake.recorded.clear();
        board.onTokenStep!(1, 0);
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'a step of another seat\'s (1) token must play nothing; '
              'recorded ${fake.recorded}',
        );
      },
    );
  });
}
