// Conformance tests for work/ludo/orders/C-268-landing-cues.md, written from
// that contract's own text and its "Measured on origin/main 30c77ba"
// section alone. Order 268 (lib/src/board.dart and lib/src/game_screen.dart)
// is being built in parallel by a different worker, in a tree this file's
// author has not read; every expectation below is read off the contract
// text, never off that tree's code. lib/ is not touched by this file.
//
// LudoBoard.onMoveLanded, LudoBoard.onTravelReset and
// game_screen.dart's kLandingCueFallback do not exist on origin/main
// 30c77ba, this branch's base, so this whole file fails to compile there --
// see this order's own report for the exact analyzer/compile output. That
// is the failing arm for the board-probe group below; for the GameScreen
// group the master measures the timing arm himself (these tests against
// order 268's board.dart with origin/main's game_screen.dart), since this
// worktree can only ever hold origin/main's pre-268 lib/ on both sides at
// once.
//
// --- board probe -----------------------------------------------------------
//
// Mounting follows test/token_travel_test.dart's bare-LudoBoard harness,
// copied by hand rather than imported (this project's standing instruction
// never to import across test files): a small host StatefulWidget (_Host)
// holds the tokens map and exposes a setTokens(...) hook through a
// GlobalKey, so a case can rebuild the same LudoBoard element with new
// tokens the way a screen would. Every mount passes legal: const <int>{}
// (board.dart's own pulsing ring never used here) and no case calls
// pumpAndSettle, per that file's own standing lesson.
//
// --- mounted GameScreen -----------------------------------------------------
//
// GameScreen is mounted exactly the way test/step_tick_travel_test.dart and
// test/feedback_wiring_test.dart mount it: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only), under a
// FeedbackScope carrying a fake FeedbackService that records every play
// call with no throttle of its own. The fake-transport idiom and the
// recording fake are copied by hand from those files -- the fake itself
// (feedback_wiring_test.dart's _FakeFeedbackService) is library-private, so
// it is not importable, and copying its identical text is what this
// project's own sibling files already do rather than invent a second
// design. Every room below is connected with turn: null, as in
// step_tick_travel_test.dart, so nothing here ever arms a countdown Timer
// for a bounded pump to race against.
//
// Lesson 35: one connect-and-mount per case. Lesson 36, and the standing
// rule against pumpAndSettle while a live timer runs: every wait is either
// the two-pump idiom the sibling suites use to flush a pushed frame, a
// bounded loop of tester.pump(kTokenStepDuration) (one call per square), or
// _pumpTotal below, which only ever advances the fake clock in bounded
// chunks, never in one long pump. No pumpEventQueue() is called inside a
// testWidgets body; the one pumpEventQueue() this file uses lives inside
// _connectTo's tester.runAsync(...), copied from the same sibling suites.
//
// Ambiguity found and not invented around: the contract's own test-amend
// list (order 269's file list) is conditional, for
// test/feedback_wiring_test.dart's ~line 485 case, on whether the board
// travels in that rig. It does not: the opponent seat there sits at tokens
// [-1,-1,-1,-1] by fixture default, and the frame's `from: 2` is not
// checked against that by RoomController._reduceMoved (the controller sets
// the mover's token straight to `to`), so the diff LudoBoard actually sees
// for that seat's token is old -1, new 5 -- outside both of
// _reactToTokensChange's own mover patterns (leaving-the-yard requires new
// == 0; the continuing-move pattern requires old >= 0). That diff therefore
// snaps rather than travels, and C-268 rule 2 fires onTravelReset for every
// snap, which rule 4b flushes immediately (every pending entry, oldest
// first) -- so that existing "pumps twice, expect [capturedMe]" case stays
// green unchanged under C-268, and this file does not touch it, per order
// 269's own instruction to leave it as is and say which.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

// ============================================================================
// Board probe: LudoBoard.onMoveLanded / LudoBoard.onTravelReset in
// isolation, no GameScreen involved.
// ============================================================================

const List<int> _boardSeats = <int>[0, 1, 2, 3];

Map<int, List<int>> _allInYard() => <int, List<int>>{
  for (final int seat in _boardSeats) seat: <int>[-1, -1, -1, -1],
};

/// Holds one [LudoBoard]'s `tokens` across rebuilds, copied by hand from
/// test/token_travel_test.dart's own `_Host`, extended with the two C-268
/// callbacks under test.
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.tokens,
    this.onMoveLanded,
    this.onTravelReset,
  });

  final Map<int, List<int>> tokens;
  final void Function(int seat, int token)? onMoveLanded;
  final VoidCallback? onTravelReset;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Map<int, List<int>> _tokens;

  @override
  void initState() {
    super.initState();
    _tokens = widget.tokens;
  }

  void setTokens(Map<int, List<int>> next) {
    setState(() {
      _tokens = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LudoBoard(
      tokens: _tokens,
      seatsInPlay: _boardSeats,
      legal: const <int>{},
      onMoveLanded: widget.onMoveLanded,
      onTravelReset: widget.onTravelReset,
    );
  }
}

Widget _boardHarness({
  required GlobalKey<_HostState> hostKey,
  required Map<int, List<int>> tokens,
  void Function(int seat, int token)? onMoveLanded,
  VoidCallback? onTravelReset,
}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 400,
          child: _Host(
            key: hostKey,
            tokens: tokens,
            onMoveLanded: onMoveLanded,
            onTravelReset: onTravelReset,
          ),
        ),
      ),
    ),
  );
}

// ============================================================================
// Mounted GameScreen: the held pending entry, C-268 rules 3 and 4.
// ============================================================================

const String _testUrl = 'wss://landing-cues-test.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'landing-cues-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

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
/// suites' own `_connectTo`.
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
      // countdown, and turn: null means GameScreen arms no countdown Timer
      // at all, so there is nothing of that kind for a bounded pump to
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
/// with no throttle of its own. Identical in text to
/// test/feedback_wiring_test.dart's own `_FakeFeedbackService` (library
/// private there, so not importable); copied by hand rather than built a
/// second way.
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
        'verify_url': 'https://landing-cues-test.invalid/verify/$seq',
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pushes a `player_left` frame and flushes it the same way.
Future<void> _pushPlayerLeft(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'player_left',
      data: <String, Object?>{'seat': seat, 'seq': seq},
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pumps [squares] bounded ticks of exactly [kTokenStepDuration] each,
/// never one long pump (lesson 36) -- one call per square the board's own
/// step timer is expected to cross.
Future<void> _pumpSquares(WidgetTester tester, int squares) async {
  for (var i = 0; i < squares; i++) {
    await tester.pump(kTokenStepDuration);
  }
}

/// Advances the fake clock by exactly [total], in bounded chunks of at
/// most [chunk] each -- lesson 36's "settle with several bounded pumps,
/// never one long pump" applied to a plain Duration rather than a step
/// count.
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

void main() {
  group('board probe: onMoveLanded / onTravelReset', () {
    // Kills: onMoveLanded never firing; firing for the wrong (seat, token);
    // firing before the sixth step instead of after it; firing again when
    // the captured token's own flight lands (rule 1's "never for a
    // captured token's flight").
    testWidgets(
      'a 6-square move with a capture: onMoveLanded fires exactly once, '
      'right after the sixth onTokenStep and before the capture flight '
      'ends, and never again once that flight lands',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final List<(int, int)> landed = <(int, int)>[];
        // Seat 0 progress 9 and seat 1 progress 48 are the same absolute
        // track square (entry 0 + 9 == entry 13 + 48 mod 52), the identity
        // test/token_travel_test.dart's own capture case already uses.
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, 48, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _boardHarness(
            hostKey: hostKey,
            tokens: before,
            onMoveLanded: (int seat, int token) => landed.add((seat, token)),
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[9, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        expect(
          landed,
          isEmpty,
          reason:
              'one frame after the rebuild, before any step has run, '
              'onMoveLanded must not have fired yet; got $landed',
        );

        for (var i = 0; i < 5; i++) {
          await tester.pump(kTokenStepDuration);
        }
        expect(
          landed,
          isEmpty,
          reason:
              'after 5 of the 6 squares (seat 0 token 0, progress 3 to 9), '
              'onMoveLanded must not have fired yet -- scenario: a mover '
              'with 6 squares to travel, checked one step short of the '
              'last; got $landed',
        );

        // The sixth and last step: the mover's own travel lands here, and
        // rule 1 says this is the moment onMoveLanded fires -- before the
        // captured token's flight (kCaptureFlightDuration) has had any
        // time to run at all.
        await tester.pump(kTokenStepDuration);
        expect(
          landed,
          equals(<(int, int)>[(0, 0)]),
          reason:
              'onMoveLanded must fire exactly once, naming (seat 0, token '
              '0), right after the sixth and last step of a 3-to-9 move; '
              'got $landed',
        );

        // Let the capture flight run to completion. Rule 1's "never for a
        // captured token's flight" means this must add nothing further.
        await tester.pump(kCaptureFlightDuration);
        expect(
          landed,
          equals(<(int, int)>[(0, 0)]),
          reason:
              'the captured token (seat 1, token 2) arriving home after '
              'kCaptureFlightDuration must not call onMoveLanded a second '
              'time; got $landed',
        );
      },
    );

    // Kills: onTravelReset never firing on a snap; onMoveLanded firing
    // anyway for a change that never became a move at all.
    testWidgets(
      'two seats each moving a token in the same rebuild (not a single '
      'clean move): onTravelReset fires exactly once and onMoveLanded '
      'never fires',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final List<(int, int)> landed = <(int, int)>[];
        int resets = 0;
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[5, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _boardHarness(
            hostKey: hostKey,
            tokens: before,
            onMoveLanded: (int seat, int token) => landed.add((seat, token)),
            onTravelReset: () => resets++,
          ),
        );
        await tester.pump();

        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[5, -1, -1, -1],
          1: <int>[8, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        expect(
          resets,
          1,
          reason:
              'two seats moving in the same rebuild is not a single-mover '
              'move (C-252 rule 2), so _snapToTruth must run exactly once '
              'and onTravelReset with it; got $resets resets',
        );
        expect(
          landed,
          isEmpty,
          reason:
              'a snap is not a move the board accepted, so onMoveLanded '
              'must never fire for it; got $landed',
        );
      },
    );

    // Kills: a move already playing when a snap arrives still calling
    // onMoveLanded later, once its own timer would naturally have elapsed
    // -- rule 2's own "a move dropped by a snap never calls onMoveLanded
    // afterward", the half of the rule a bare "resets fire, landed does
    // not, right at the snap" check does not reach on its own.
    testWidgets(
      'a move snapped away mid-travel never calls onMoveLanded later, even '
      'once enough time has passed for the original move to have landed',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final List<(int, int)> landed = <(int, int)>[];
        int resets = 0;
        final Map<int, List<int>> before = <int, List<int>>{
          0: <int>[3, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        };
        await tester.pumpWidget(
          _boardHarness(
            hostKey: hostKey,
            tokens: before,
            onMoveLanded: (int seat, int token) => landed.add((seat, token)),
            onTravelReset: () => resets++,
          ),
        );
        await tester.pump();

        // A clean single-mover move, 6 squares (3 to 9): starts travelling.
        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[9, -1, -1, -1],
          1: <int>[-1, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();

        // Two of the six steps run before the snap arrives.
        await tester.pump(kTokenStepDuration);
        await tester.pump(kTokenStepDuration);
        expect(
          landed,
          isEmpty,
          reason: 'fixture check: the move must still be mid-travel here',
        );

        // Two movers in the same rebuild: not a clean move, so this snaps
        // -- dropping the in-flight move (seat 0 token 0) and its timer.
        hostKey.currentState!.setTokens(<int, List<int>>{
          0: <int>[14, -1, -1, -1],
          1: <int>[0, -1, -1, -1],
          2: <int>[-1, -1, -1, -1],
          3: <int>[-1, -1, -1, -1],
        });
        await tester.pump();
        expect(
          resets,
          1,
          reason: 'the snap above must call onTravelReset exactly once',
        );
        expect(
          landed,
          isEmpty,
          reason:
              'the snap must drop the in-flight move before onMoveLanded '
              'could ever fire for it; got $landed',
        );

        // Enough further steps for the original (dropped) move to have
        // landed had its timer survived -- it must not have.
        for (var i = 0; i < 10; i++) {
          await tester.pump(kTokenStepDuration);
        }
        expect(
          landed,
          isEmpty,
          reason:
              'a move dropped by a snap must never call onMoveLanded '
              'afterward (C-268 rule 2), even once the time its own travel '
              'would have taken has long since passed; got $landed',
        );
        expect(
          resets,
          1,
          reason:
              'no further onTravelReset call is expected either, since no '
              'further tokens change was pushed; got $resets resets',
        );
      },
    );

    // A board built once and never updated holds no pending timer for
    // either callback -- the lifecycle guarantee test/token_travel_test.dart
    // already proves for onTokenStep, restated here so a leftover Timer
    // from either new callback cannot slip through unnoticed.
    testWidgets(
      'a board built once and never updated calls neither onMoveLanded nor '
      'onTravelReset, and holds no pending timer',
      (tester) async {
        final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
        final List<(int, int)> landed = <(int, int)>[];
        int resets = 0;
        await tester.pumpWidget(
          _boardHarness(
            hostKey: hostKey,
            tokens: _allInYard(),
            onMoveLanded: (int seat, int token) => landed.add((seat, token)),
            onTravelReset: () => resets++,
          ),
        );
        await tester.pump();

        expect(landed, isEmpty);
        expect(resets, 0);
        // A leftover dart:async Timer would independently fail this test
        // at teardown.
      },
    );
  });

  group('mounted GameScreen: held landing cues (C-268 rules 3 and 4)', () {
    final List<Map<String, Object?>> twoSeats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[3, -1, -1, -1]),
      _seatJson(1, name: 'Bob', tokens: const <int>[-1, -1, 48, -1]),
    ];

    // Kills: capturedOther played at frame time instead of held (rule 3);
    // capturedOther played twice, once at landing and once again by the
    // fallback timer that should have been cancelled.
    testWidgets(
      'my 6-square capture records no capturedOther before the last step, '
      'exactly one after, and the fallback timer never plays it a second '
      'time',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: twoSeats);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 3,
          to: 9,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 2},
          ],
          seq: 2,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'C-268 rule 3: capturedOther must be held, not played the '
              'instant the moved frame lands; recorded ${fake.recorded}',
        );

        await _pumpSquares(tester, 5);
        expect(
          fake.recorded,
          equals(List<FeedbackCue>.filled(5, FeedbackCue.step)),
          reason:
              'rule 6 keeps the C-259 step wiring: 5 of the 6 squares have '
              'arrived, so exactly 5 step cues must be recorded and '
              'capturedOther must still not have played; recorded '
              '${fake.recorded}',
        );

        await _pumpSquares(tester, 1);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.capturedOther,
          ]),
          reason:
              'the sixth step lands the move: onMoveLanded fires and the '
              'held capturedOther plays exactly once, after the sixth step '
              'cue; recorded ${fake.recorded}',
        );

        // Let kLandingCueFallback's own window run out from when the
        // entry was held. A cue played again here would mean the fallback
        // timer was not cancelled once the landing played it.
        await _pumpTotal(tester, kLandingCueFallback);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.capturedOther,
          ]),
          reason:
              'capturedOther must still be recorded exactly once after '
              'kLandingCueFallback has fully elapsed since it was held -- '
              'a second entry here would mean the fallback timer fired on '
              'top of the landing instead of being cancelled by it; '
              'recorded ${fake.recorded}',
        );
      },
    );

    // Kills: home played at frame time instead of held.
    testWidgets('my move to 57 records home only after the last step', (
      tester,
    ) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[52, -1, -1, -1]),
        _seatJson(1, name: 'Bob'),
      ];
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, seats: seats);

      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: 52,
        to: 57,
        seq: 2,
      );
      expect(
        fake.recorded,
        isEmpty,
        reason:
            'C-268 rule 3: home must be held, not played the instant the '
            'moved frame lands; recorded ${fake.recorded}',
      );

      // progress 52 to 57 is 5 squares: 53, 54, 55, 56, 57.
      await _pumpSquares(tester, 4);
      expect(
        fake.recorded,
        equals(List<FeedbackCue>.filled(4, FeedbackCue.step)),
        reason:
            '4 of the 5 squares have arrived; home must not have played '
            'yet; recorded ${fake.recorded}',
      );

      await _pumpSquares(tester, 1);
      expect(
        fake.recorded,
        equals(<FeedbackCue>[
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.step,
          FeedbackCue.home,
        ]),
        reason:
            'the fifth and last step lands the move on 57: home must '
            'play exactly once, right after the last step cue; recorded '
            '${fake.recorded}',
      );
    });

    // Kills: capturedMe played at frame time instead of held; a step cue
    // leaking for an opponent's own token travel.
    testWidgets(
      "an opponent's 3-square capture of me records capturedMe only after "
      'its last step, and never a step cue for either seat',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[5, -1, -1, -1]),
          _seatJson(1, name: 'Bob', tokens: const <int>[2, -1, -1, -1]),
        ];
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMoved(
          tester,
          transport,
          seat: 1,
          token: 0,
          from: 2,
          to: 5,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 0},
          ],
          seq: 2,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'C-268 rule 3: capturedMe must be held, not played the '
              'instant the moved frame lands; recorded ${fake.recorded}',
        );

        await _pumpSquares(tester, 2);
        expect(
          fake.recorded,
          isEmpty,
          reason:
              '2 of the opponent\'s 3 squares have arrived: no step cue is '
              'ever recorded for another seat\'s own token (C-259), and '
              'capturedMe must still not have played; recorded '
              '${fake.recorded}',
        );

        await _pumpSquares(tester, 1);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.capturedMe]),
          reason:
              'the third and last step lands the opponent\'s move: '
              'capturedMe must play exactly once, and no step cue must '
              'ever have been recorded for it; recorded ${fake.recorded}',
        );
      },
    );

    // Kills: win played before the held capture cue flushes on game_over
    // (rule 4c's own ordering); the held cue never flushing at all when
    // the board that would have landed it gets replaced by the end
    // screen's own board before the travel finishes.
    testWidgets(
      'a capture followed at once by game_over I won flushes capturedOther '
      'before win, each exactly once',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: twoSeats);

        // The moved frame lands but is never given any travel time at
        // all: the board behind the playing body is about to be replaced
        // by the end screen's own board before it could ever call
        // onMoveLanded for this move.
        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 3,
          to: 9,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 2},
          ],
          seq: 2,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason: 'capturedOther must still be held, not yet played',
        );

        await _pushGameOver(tester, transport, winner: 0, seq: 3);

        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.capturedOther, FeedbackCue.win]),
          reason:
              'C-268 rule 4c: a game_over frame must flush every pending '
              'entry, oldest first, before playing win or gameOver -- '
              'capturedOther must come before win, each exactly once; '
              'recorded ${fake.recorded}',
        );

        // The fallback timer armed when the entry was held must have been
        // cancelled by the rule 4c flush above, not fire again on top of
        // it.
        await _pumpTotal(tester, kLandingCueFallback);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.capturedOther, FeedbackCue.win]),
          reason:
              'nothing further must be recorded once kLandingCueFallback '
              'has elapsed since the entry was held; a repeated '
              'capturedOther here would mean the fallback timer was not '
              'cancelled by the rule 4c flush; recorded ${fake.recorded}',
        );
      },
    );

    // Kills: a held timer firing after dispose -- the realistic path is an
    // opponent leaving mid-animation, which drops the playing board (and
    // the move it was mid-travel on) straight to _waitingBody with no
    // onTravelReset call at all (LudoBoard.dispose cancels its own timer
    // but never calls onTravelReset, which only fires from _snapToTruth).
    // Rule 4e's fallback is the only thing left standing between that and
    // a lost cue.
    testWidgets('a held entry whose board is torn down mid-travel (an opponent '
        'leaving) plays at kLandingCueFallback and not before, and no timer '
        'fires after this screen itself is gone', (tester) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, seats: twoSeats);

      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: 3,
        to: 9,
        captured: <Map<String, Object?>>[
          <String, Object?>{'seat': 1, 'token': 2},
        ],
        seq: 2,
      );
      expect(
        fake.recorded,
        isEmpty,
        reason: 'capturedOther must still be held, not yet played',
      );

      // The opponent (seat 1) leaves before the board has taken even
      // its first step: room.seats drops to 1, so GameScreen's own
      // build() falls to _waitingBody and the LudoBoard that held the
      // in-flight move is torn down without ever reaching
      // _snapToTruth.
      await _pushPlayerLeft(tester, transport, seat: 1, seq: 3);
      expect(
        fake.recorded,
        isEmpty,
        reason:
            'tearing down the board this way calls neither onMoveLanded '
            'nor onTravelReset, so capturedOther must still not have '
            'played; recorded ${fake.recorded}',
      );

      await _pumpTotal(
        tester,
        kLandingCueFallback - const Duration(milliseconds: 1),
      );
      expect(
        fake.recorded,
        isEmpty,
        reason:
            'one millisecond short of kLandingCueFallback since the '
            'entry was held, capturedOther must still not have played; '
            'recorded ${fake.recorded}',
      );

      await tester.pump(const Duration(milliseconds: 1));
      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.capturedOther]),
        reason:
            'exactly at kLandingCueFallback since the entry was held, '
            'the safety net must play it, exactly once; recorded '
            '${fake.recorded}',
      );
    });

    // Kills: a held timer firing after dispose. Unlike the case above (the
    // fallback fires, then the screen is disposed), this one disposes the
    // screen while the entry is still pending and the fallback timer is
    // still armed, well before kLandingCueFallback would otherwise fire --
    // rule 5's own "Dropped, not played: pending entries and their timers
    // on ... dispose. No timer may fire after dispose."
    testWidgets(
      'disposing GameScreen while a held entry is still pending drops it: '
      'no timer fires later, and the cue never plays',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: twoSeats);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 3,
          to: 9,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 2},
          ],
          seq: 2,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason: 'capturedOther must still be held, not yet played',
        );

        // Dispose this screen entirely, well before the board would have
        // landed the move (840ms) or the fallback would have fired
        // (kLandingCueFallback), while the entry's timer is still armed.
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        // Let real time pass well beyond the fallback window. A held
        // timer surviving dispose would either throw (a setState, or a
        // BuildContext lookup, against a disposed State) or, just as much
        // a defect even without throwing, play the cue anyway -- rule 5
        // says dropped, never played, once dispose has run.
        await _pumpTotal(tester, kLandingCueFallback * 2);

        expect(
          tester.takeException(),
          isNull,
          reason:
              'no timer held by the now-disposed GameScreen may fire; a '
              'held timer surviving dispose would throw here instead',
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'rule 5 drops every pending entry and its timer on dispose: '
              'capturedOther must never play once this screen is gone, '
              'even though kLandingCueFallback has since elapsed twice '
              'over; recorded ${fake.recorded}',
        );
      },
    );
  });
}
