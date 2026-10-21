// Conformance tests for work/ludo/orders/C-422-every-play-tap-answers.md's
// T6-T10: a legal token tap plays `tap` once and lifts the tapped token, in
// the same frame, through the one feedback service; the hold's own commit
// plays no `tap`; an illegal tap is unchanged. Written from that contract's
// text alone (run 102, order 422); order 423 builds D1-D5 in a tree this
// file's author has not read, so nothing below is read off 423's code.
//
// Base: origin/main bddc551. On this tree `FeedbackCue` has its ten C-225
// values and no `tap`; `_onDieTap` and the token-tap callback in
// game_screen.dart never call the feedback service for a tap
// acknowledgement; `board.dart` has no `sentToken` parameter and builds no
// `board-token-lifted-*` widget. Every case below that exercises D1-D5 is
// therefore expected to fail its own assertion (an empty or wrong recorded
// list, a missing lifted key), never to fail by refusing to compile.
//
// That last clause is deliberate, not incidental: T10 must stay green on
// this base (the order's own acceptance note), and T10 lives in this same
// file as T6-T9. Naming the enum member `FeedbackCue.tap` directly anywhere
// in this file -- it does not exist on this base -- would fail the whole
// file to load (verified: an undefined enum member is a compile-time
// error, and `dart test`/`flutter test` cannot run any other test in a
// file that fails to load), which would drag T10 down with it for a reason
// that has nothing to do with T10's own claim. So every comparison below
// that needs to name the `tap` cue compares by its wire id string, `'tap'`
// (`cue.id`, never `FeedbackCue.tap`), the same id C-422 D1 names for it.
// `FeedbackCue.invalidTap` (T10's only cue) is an existing member and is
// named directly as usual.
//
// GameScreen is driven the way test/feedback_wiring_test.dart drives it: a
// real RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only), with a FeedbackScope carrying a recording fake above it.
// `_FakeFeedbackService`, `_connectAndMount`, `_seatJson` and `_turnJson`
// are copied by hand from that file's own helpers of the same names, per
// this project's standing instruction never to import across test files.
// The unique-legal hold (T9) is driven the way
// test/automove_says_so_test.dart drives it: a `turn` frame naming exactly
// one legal token arms the hold, and `kAutoMoveHold` (board.dart's own
// public 1500ms constant, already landed on this base) is pumped past to
// let it commit.
//
// Every move this file sends is answered (a `moved` reply or a rejected-
// intention `error` reply) before its test body ends, so no pending 10s
// request-timeout Timer (connection.dart) survives the test -- the same
// discipline test/automove_says_so_test.dart's own comments name. One mount
// per case; no pumpAndSettle (the legal ring pulses forever while a token
// is legal).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart' show kAutoMoveHold;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://play-tap-ack-test.invalid/ws';

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');
Key _liftKey(int seat, int index) => Key('board-token-lifted-$seat-$index');

/// Any widget keyed `board-legal-ring-*`, under any seat or token --
/// C-422 D4's own claim is "no board-legal-ring-* ... for any token of
/// mine", not only the tapped one, so this finder deliberately does not
/// name a seat or token.
final Finder _anyLegalRingFinder = find.byWidgetPredicate((Widget widget) {
  final Key? key = widget.key;
  return key is ValueKey<String> && key.value.startsWith('board-legal-ring-');
});

// --- server-side id generation for pushed frames ----------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'play-tap-ack-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

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

/// Every `move` frame sent after [sentBefore], decoded. Copied from
/// test/automove_says_so_test.dart's own `_movesSince`.
List<String> _movesSince(FakeTransport transport, int sentBefore) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((String s) => _typeOf(s) == 'move')
      .toList();
}

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot ---------------
// Copied by hand from test/feedback_wiring_test.dart's own helpers of the
// same names.

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
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
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
  'winner': null,
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

/// Connects a fresh controller and lands it directly on the given [turn],
/// mySeat always 0. Copied from test/feedback_wiring_test.dart's own
/// `_connectTo`.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required Map<String, Object?> turn,
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
      data: _roomJson(seats: seats, turn: turn),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(disableAnimations: disableAnimations),
        child: child!,
      );
    },
    home: child,
  );
}

/// Records every cue GameScreen asks the service to play, in call order.
/// Copied from test/feedback_wiring_test.dart's own `_FakeFeedbackService`.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Connects a fresh controller, mounts GameScreen over a fresh fake
/// feedback service, and hands both plus the transport back. Copied from
/// test/feedback_wiring_test.dart's own `_connectAndMount`, with a
/// realistic phone size (test/automove_says_so_test.dart's and
/// test/hold_after_walk_test.dart's own reasoning: on the default,
/// unrealistically small test surface a `tester.tap` aimed at a token's
/// hit rect can land on the roll tray instead).
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _connectAndMount(
  WidgetTester tester, {
  required Map<String, Object?> turn,
  required List<Map<String, Object?>> seats,
  bool disableAnimations = false,
  Size size = const Size(390, 844),
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    turn: turn,
    seats: seats,
  );
  addTearDown(controller.dispose);
  final _FakeFeedbackService fake = _FakeFeedbackService();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: fake,
        child: GameScreen(controller: controller),
      ),
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  return (controller, transport, fake);
}

/// Answers [moveText] (a sent `move` frame, decoded for its `token`) with a
/// zero-travel `moved` reply so the request's own 10s timeout Timer clears
/// before the test body ends. Copied from
/// test/automove_says_so_test.dart's own `_completeMoveZeroTravel`, folded
/// to this file's one caller shape (`from == to == atProgress`).
Future<void> _resolveMoveZeroTravel(
  WidgetTester tester,
  FakeTransport transport,
  String moveText, {
  required int seat,
  required int token,
  required int atProgress,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      re: _idOf(moveText),
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': atProgress,
        'to': atProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Answers [moveText] with a rejected-intention `error` reply -- one of
/// order 170's own four race codes (NOT_YOUR_TURN, WRONG_PHASE,
/// ILLEGAL_MOVE, GAME_OVER) -- the shape
/// test/net/room_controller_rejected_intention_test.dart's own E-M1..E-M4
/// cases push to prove a rejected intention leaves the connection (and the
/// room's own legality) exactly as it was, never closing it and never
/// setting an error code. `ILLEGAL_MOVE` is picked here as the one most
/// descriptive of a genuine refusal of this exact move.
Future<void> _rejectMove(
  WidgetTester tester,
  FakeTransport transport,
  String moveText,
) async {
  transport.pushText(
    _frame(
      type: 'error',
      re: _idOf(moveText),
      data: <String, Object?>{
        'code': 'ILLEGAL_MOVE',
        'message': 'race: ILLEGAL_MOVE',
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // ==========================================================================
  // T6: a legal tap sends one move and plays `tap` once, before any server
  // frame; a second tap before any reply sends and plays nothing further.
  // ==========================================================================
  testWidgets(
    'T6: a legal token tap sends exactly one move and records exactly one '
    'tap after a single pump, before any server frame; a second tap before '
    'any reply still leaves exactly one move and one tap',
    (WidgetTester tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (
        _,
        FakeTransport transport,
        _FakeFeedbackService fake,
      ) = await _connectAndMount(
        tester,
        seats: seats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 4,
          legal: const <int>[0, 1],
        ),
      );

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_hitKey(0, 0)));
      await tester.pump();

      final List<String> movesAfterFirstTap = _movesSince(
        transport,
        sentBefore,
      );
      expect(
        movesAfterFirstTap,
        hasLength(1),
        reason:
            'C-422 D3: a legal token tap that sends must put exactly one '
            'move on the wire; got ${movesAfterFirstTap.length} after a '
            'single pump, before any server frame',
      );
      expect(
        fake.recorded.map((FeedbackCue c) => c.id),
        equals(const <String>['tap']),
        reason:
            'C-422 D3: a legal token tap that sends must play the tap cue '
            '(wire id "tap") exactly once, after a single pump and before '
            'any server frame; recorded ids '
            '${fake.recorded.map((FeedbackCue c) => c.id).toList()}',
      );

      final String moveText = movesAfterFirstTap.single;

      // A second tap while the guard still holds (no reply has landed
      // yet): still one move, still one tap (C-422 D3's own "a second tap
      // while the guard holds plays nothing and sends nothing").
      await tester.tap(find.byKey(_hitKey(0, 0)));
      await tester.pump();

      expect(
        _movesSince(transport, sentBefore),
        hasLength(1),
        reason:
            'C-422 D3: a second tap before any reply must send no further '
            'move; sentRaw carries '
            '${_movesSince(transport, sentBefore).length}',
      );
      expect(
        fake.recorded.map((FeedbackCue c) => c.id),
        equals(const <String>['tap']),
        reason:
            'C-422 D3: a second tap before any reply must play no further '
            'tap cue; recorded ids '
            '${fake.recorded.map((FeedbackCue c) => c.id).toList()}',
      );

      await _resolveMoveZeroTravel(
        tester,
        transport,
        moveText,
        seat: 0,
        token: 0,
        atProgress: 3,
      );
    },
  );

  // ==========================================================================
  // T7: the lift appears in the same frame as the tap, moves no hit rect,
  // and hides every legal ring of mine; it drops on `moved`, and
  // separately drops (with the rings back) on a refusal.
  // ==========================================================================
  group('T7: the lift', () {
    /// Connects, mounts, and taps token 0 of a two-legal-token await_move
    /// (tokens 0 and 1 both legal, both at rest), returning everything a
    /// case needs to check the lift and to resolve the move afterwards.
    /// One mount per *test*, not per call: each of this group's two cases
    /// calls this once, from its own testWidgets body.
    // Returns (controller, transport, fake, the sent move's raw text, the
    // tapped token's hit rect as it was just before the tap).
    Future<(RoomController, FakeTransport, _FakeFeedbackService, String, Rect)>
    armAndTap(WidgetTester tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (
        RoomController controller,
        FakeTransport transport,
        _FakeFeedbackService fake,
      ) = await _connectAndMount(
        tester,
        seats: seats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 4,
          legal: const <int>[0, 1],
        ),
      );

      final Rect hitRectBeforeTap = tester.getRect(find.byKey(_hitKey(0, 0)));
      expect(
        _anyLegalRingFinder,
        findsWidgets,
        reason:
            'fixture is broken: with two legal tokens at rest, at least '
            'one board-legal-ring-* must be on screen before the tap',
      );

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_hitKey(0, 0)));
      await tester.pump();

      final List<String> moves = _movesSince(transport, sentBefore);
      expect(
        moves,
        hasLength(1),
        reason:
            'fixture is broken: the tap on a legal token must send exactly '
            'one move; got ${moves.length}',
      );

      return (controller, transport, fake, moves.single, hitRectBeforeTap);
    }

    testWidgets('after the tap and one pump: board-token-lifted-0-0 exists, no '
        'board-legal-ring-* exists, and the hit rect is unchanged; then the '
        "server's moved for that token clears the lift", (
      WidgetTester tester,
    ) async {
      final (
        _,
        FakeTransport transport,
        _,
        String moveText,
        Rect hitRectBeforeTap,
      ) = await armAndTap(
        tester,
      );

      expect(
        find.byKey(_liftKey(0, 0)),
        findsOneWidget,
        reason:
            'C-422 D4: after a legal tap on token 0 and one pump, '
            'board-token-lifted-0-0 must exist',
      );
      expect(
        _anyLegalRingFinder,
        findsNothing,
        reason:
            'C-422 D4: while sentToken is non-null, no board-legal-ring-* '
            'may be built for any token of mine, including token 1, '
            'which is still legal but not the one tapped',
      );
      final Rect hitRectAfterTap = tester.getRect(find.byKey(_hitKey(0, 0)));
      expect(
        hitRectAfterTap,
        hitRectBeforeTap,
        reason:
            'C-422 D4: the lift must change no hit target; '
            'board-token-hit-0-0 must be the same rect it was before the '
            'tap. before=$hitRectBeforeTap after=$hitRectAfterTap',
      );

      await _resolveMoveZeroTravel(
        tester,
        transport,
        moveText,
        seat: 0,
        token: 0,
        atProgress: 3,
      );

      expect(
        find.byKey(_liftKey(0, 0)),
        findsNothing,
        reason:
            "C-422 D4: once the server's moved for the tapped token "
            'arrives, board-token-lifted-0-0 must be gone',
      );
    });

    testWidgets(
      'a refusal (error reply to the move) clears the lift and brings the '
      'legal rings back',
      (WidgetTester tester) async {
        final (_, FakeTransport transport, _, String moveText, _) =
            await armAndTap(tester);

        expect(
          find.byKey(_liftKey(0, 0)),
          findsOneWidget,
          reason:
              'fixture is broken: the lift must be present right after the '
              'tap, before the refusal below',
        );

        await _rejectMove(tester, transport, moveText);

        expect(
          find.byKey(_liftKey(0, 0)),
          findsNothing,
          reason:
              'C-422 D4: once the move call finishes in a refusal, '
              'board-token-lifted-0-0 must be gone',
        );
        expect(
          _anyLegalRingFinder,
          findsWidgets,
          reason:
              'C-422 D4: once the move call finishes in a refusal, the '
              'rings come back on whatever is still legal; both token 0 '
              'and token 1 are still legal (the server refused, it did '
              'not change the legal set), so at least one ring must be '
              'back',
        );
      },
    );
  });

  // ==========================================================================
  // T8: the same lift, on the first frame, under reduced motion.
  // ==========================================================================
  testWidgets(
    'T8: under MediaQuery.disableAnimations, board-token-lifted-0-0 exists '
    'on the first frame after the tap',
    (WidgetTester tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (_, FakeTransport transport, _) = await _connectAndMount(
        tester,
        seats: seats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 4,
          legal: const <int>[0, 1],
        ),
        disableAnimations: true,
      );

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_hitKey(0, 0)));
      await tester.pump();

      final List<String> moves = _movesSince(transport, sentBefore);
      expect(
        moves,
        hasLength(1),
        reason:
            'fixture is broken: the tap on a legal token must send exactly '
            'one move; got ${moves.length}',
      );
      expect(
        find.byKey(_liftKey(0, 0)),
        findsOneWidget,
        reason:
            'C-422 D5: under MediaQuery.disableAnimations the lift must be '
            'present on the first frame after the tap, the same single '
            'pump every other case in this file uses',
      );

      await _resolveMoveZeroTravel(
        tester,
        transport,
        moves.single,
        seat: 0,
        token: 0,
        atProgress: 3,
      );
    },
  );

  // ==========================================================================
  // T9: the unique-legal hold's own commit plays no tap, but still lifts
  // the token it moves.
  // ==========================================================================
  testWidgets(
    'T9: the held unique-legal move commits after kAutoMoveHold with one '
    'move on the wire, zero tap recorded, and the lift key present',
    (WidgetTester tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (
        _,
        FakeTransport transport,
        _FakeFeedbackService fake,
      ) = await _connectAndMount(
        tester,
        seats: seats,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 5,
          legal: const <int>[0],
        ),
      );
      // One more pump, matching test/automove_says_so_test.dart's own
      // comment that the glow (and the hold timer it starts) exists "right
      // after arming, on the first frame the glow subtree is built".
      await tester.pump();

      final int sentBefore = transport.sentRaw.length;

      await tester.pump(kAutoMoveHold + const Duration(milliseconds: 100));

      final List<String> moves = _movesSince(transport, sentBefore);
      expect(
        moves,
        hasLength(1),
        reason:
            "C-422 D3: the hold's own commit must still send exactly one "
            'move once kAutoMoveHold elapses; got ${moves.length}',
      );
      expect(
        fake.recorded.map((FeedbackCue c) => c.id),
        isEmpty,
        reason:
            'C-422 D3: "the unique-legal hold\'s own commit plays no tap: '
            'the player did not tap" -- the commit must record zero cues '
            'with the wire id "tap"; recorded ids '
            '${fake.recorded.map((FeedbackCue c) => c.id).toList()}',
      );
      expect(
        find.byKey(_liftKey(0, 0)),
        findsOneWidget,
        reason:
            'C-422 D4: sentToken is set by _sendMove whenever it sends, '
            '"the tap path and hold path alike"; the lift key must be '
            'present once the held move has sent',
      );

      await _resolveMoveZeroTravel(
        tester,
        transport,
        moves.single,
        seat: 0,
        token: 0,
        atProgress: 3,
      );
    },
  );

  // ==========================================================================
  // T10: unchanged -- an illegal tap still records exactly one invalid_tap,
  // never a tap, and never a lift.
  // ==========================================================================
  testWidgets('T10: a tap on an illegal token of mine records exactly one '
      'invalid_tap, no tap, and no lift', (WidgetTester tester) async {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
      _seatJson(1, name: 'Bob'),
    ];
    final (
      _,
      FakeTransport transport,
      _FakeFeedbackService fake,
    ) = await _connectAndMount(
      tester,
      seats: seats,
      turn: _turnJson(
        seat: 0,
        phase: 'await_move',
        deadlineMs: 45000,
        k: 1,
        value: 4,
        legal: const <int>[1],
      ),
    );

    final int sentBefore = transport.sentRaw.length;
    await tester.tap(find.byKey(_hitKey(0, 0)));
    await tester.pump();

    expect(
      transport.sentRaw.length,
      sentBefore,
      reason:
          'a tap on an illegal token of mine must send no move; the '
          'wire grew by ${transport.sentRaw.length - sentBefore} '
          'message(s)',
    );
    expect(
      fake.recorded,
      equals(<FeedbackCue>[FeedbackCue.invalidTap]),
      reason:
          'C-422 D6 (unchanged): a tap on an illegal token of mine must '
          'record exactly one invalidTap and never the tap cue; '
          'recorded ${fake.recorded}',
    );
    expect(
      find.byKey(_liftKey(0, 0)),
      findsNothing,
      reason:
          'an illegal tap must never lift the token it was aimed at; '
          'board-token-lifted-0-0 must be absent',
    );
  });
}
