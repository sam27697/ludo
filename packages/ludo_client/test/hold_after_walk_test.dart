// Tests for work/ludo/orders/C-408-ring-waits-for-the-token.md decision 7
// (added run 98, RESPEC after order 409's motion run): the unique-legal
// auto-move hold counts its 1500ms from the moment the held token's glow is
// actually visible, not from the moment the turn state that armed the hold
// arrived. When the held token is still walking (a roll-queue leg still
// playing out on the board) at the moment the hold arms, the 1500ms must
// start at that walk's landing, not at arming time.
//
// Written from work/ludo/orders/C-408-ring-waits-for-the-token.md alone,
// decision 7 above all, plus docs/PROTOCOL.md section 21 (the roll queue on
// the wire) for the frame shapes a queued decision actually carries. The fix
// is order 412 (lib/src/game_screen.dart's `_syncAutoMove`); it is not built
// in this tree yet, so cases 1 and 2 below are expected to fail here.
//
// GameScreen is driven the same way test/play_surface_automove_test.dart
// drives RoomController: a real RoomController sits over a FakeTransport
// (test/net/fake_transport.dart, read-only, not edited here). Every helper
// below is copied from that file's pattern, not imported from it -- this
// file is free-standing. The 1500ms hold, and every token walk, is advanced
// on flutter_test's fake clock through bounded `tester.pump(duration)`
// steps; nothing here uses `pumpAndSettle` (board.dart's legal ring pulses
// forever once it is on screen) and nothing here uses a real Timer or a real
// delay.
//
// Every assertion below reads `transport.sentRaw` (what actually went out
// on the wire) or a widget key already on screen (the glow key the board
// itself draws); nothing here reaches into GameScreenState's private fields.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart'
    show kTokenStepDuration, kTokenStepDurationReduced;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://hold-after-walk-test.invalid/ws';

Key _glowKey(int seat, int index) => Key('board-automove-glow-$seat-$index');
Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'hold-after-walk-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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
  'winner': null,
  'seq': seq,
};

Map<String, Object?> _faceLegal(int face, List<int> tokens) =>
    <String, Object?>{'face': face, 'tokens': tokens};

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

/// A plain mutable counter for the room's `seq`, so every pushed frame below
/// can carry the next value without each test hand-tracking an int (a
/// mismatch here makes RoomController begin a resync instead of applying
/// the frame, which would silently break the scenario rather than fail
/// loudly, so getting this right matters).
class _Seq {
  _Seq(this.value);
  int value;
  int next() {
    value += 1;
    return value;
  }
}

Widget _harness(Widget child, {bool disableAnimations = false}) {
  final Widget body = disableAnimations
      ? Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child,
          ),
        )
      : child;
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: body,
  );
}

/// Mounts at a realistic phone size (test/end_card_test.dart's own choice
/// for GameScreen), not the default test surface: the roll-queue's face
/// tray is UI `play_surface_automove_test.dart` never renders (its
/// `legalByFace` is always null), and on the default (unrealistically
/// small) test surface that tray row sits close enough to the board that a
/// `tester.tap` aimed at a token's own hit rect can land on the tray
/// instead, a real overflow this size avoids.
Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  bool disableAnimations = false,
  Size size = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: controller),
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
}

/// Connects seat 0 of a two-seat room straight into `await_roll` at k=0,
/// seat 0's tokens set to [seat0Tokens] and seat 1's (Bob's) tokens set to
/// [seat1Tokens] -- the latter defaults to every token still in the yard,
/// and only case 2 (D7) below gives Bob a lone token on the main track, the
/// one its capture needs. No `rolled` frame is modelled here: every case
/// below pushes its own `moved` / `turn` frames directly, which is all
/// `RoomController`'s reducers (room_controller.dart:1408-1491,
/// 1260-1315) actually require -- a `moved` only needs a non-null
/// `room.turn` to reset, and a `turn` only needs the named seat to be
/// seated.
Future<(RoomController, FakeTransport)> _connectSeat0(
  WidgetTester tester, {
  List<int> seat0Tokens = const <int>[2, -1, -1, -1],
  List<int> seat1Tokens = const <int>[-1, -1, -1, -1],
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
      data: _roomJson(
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: seat0Tokens),
          _seatJson(1, name: 'Bob', tokens: seat1Tokens),
        ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
        seq: 1,
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

/// Pushes the `moved` leg that starts token 0's walk, then the `turn` frame
/// (same seat, await_move, same k, a new queue) that makes token 0 the
/// unique legal token for [armedFace] -- docs/PROTOCOL.md section 21.3
/// ruling 4's "move, faces left that can move" row: `moved`, `turn` (same
/// seat, await_move). Both frames are pushed back to back with zero fake-
/// clock time between them, which is the most extreme (and so the clearest)
/// case of "the turn state arrives before the walk lands": the walk has
/// not even taken its first step yet.
Future<void> _startWalkAndArm(
  WidgetTester tester,
  FakeTransport transport,
  _Seq seq, {
  required int fromProgress,
  required int toProgress,
  required int movedFace,
  required int armedFace,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': fromProgress,
        'to': toProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
        'face': movedFace,
        'seq': seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  transport.pushText(
    _frame(
      type: 'turn',
      data: <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': 45000,
        'queue': <int>[armedFace],
        'value': armedFace,
        'legal': const <int>[0],
        'legal_by_face': <Map<String, Object?>>[
          _faceLegal(armedFace, const <int>[0]),
        ],
        'seq': seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

List<String> _movesSince(FakeTransport transport, int sentBefore) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((s) => _typeOf(s) == 'move')
      .toList();
}

/// Answers a sent `move` with a zero-travel `moved` (from == to): this
/// resolves the pending `RoomConnection.move` request (so no 10s request-
/// timeout Timer is left pending when the test ends) without starting a
/// second board travel a test case would then have to drain too.
Future<void> _completeMoveZeroTravel(
  WidgetTester tester,
  FakeTransport transport,
  _Seq seq,
  String moveText, {
  required int token,
  required int atProgress,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      re: _idOf(moveText),
      data: <String, Object?>{
        'seat': 0,
        'token': token,
        'from': atProgress,
        'to': atProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
        'seq': seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // ==========================================================================
  // Case 1: the held token is walking when the hold arms.
  // ==========================================================================
  group('case 1 (D7): the held token is walking when the hold arms', () {
    testWidgets('no move at 1500ms after the turn state; the glow appears when the '
        'walk lands; exactly one move is sent 1500ms after the landing, not '
        'before', (tester) async {
      final (controller, transport) = await _connectSeat0(tester);
      await _mount(tester, controller);
      final _Seq seq = _Seq(1);

      // The roll queue held [6, 4] (rule 10q: the 6 rolls again at once;
      // rule 11q: the 4 is non-six and ends the rolling); the player
      // spends the 4 first (11q: spending order is the player's choice),
      // so token 0 walks 4 squares (progress 2 -> 6: steps 3, 4, 5, 6) and
      // the turn frame that follows makes it the unique legal token for
      // the one face still queued, the 6, arriving with zero fake-clock
      // time elapsed -- the walk has not taken even its first step when
      // the hold arms.
      final int sentAtArm = transport.sentRaw.length;
      await _startWalkAndArm(
        tester,
        transport,
        seq,
        fromProgress: 2,
        toProgress: 6,
        movedFace: 4,
        armedFace: 6,
      );

      final Duration landing = kTokenStepDuration * 4;
      const Duration hold = Duration(milliseconds: 1500);
      const Duration frame = Duration(milliseconds: 16);

      // Shortly before landing: still walking, no glow, nothing sent.
      await tester.pump(landing - frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: token 0 walks progress 2 -> 6 (landing ${landing.inMilliseconds}ms); '
            'at ${(landing - frame).inMilliseconds}ms, still mid-walk, '
            'board-automove-glow-0-0 must not exist (C-408 D1)',
      );
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'scenario: token 0 walks progress 2 -> 6; at '
            '${(landing - frame).inMilliseconds}ms (before landing), no '
            'move must have been sent yet',
      );

      // Just past landing: the glow is on screen.
      await tester.pump(frame * 2);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsOneWidget,
        reason:
            'scenario: token 0 walks progress 2 -> 6; at '
            '${(landing + frame).inMilliseconds}ms, the walk has landed '
            'and board-automove-glow-0-0 must be on screen (C-408 D2)',
      );

      // At exactly 1500ms after the turn state armed the hold (the old
      // reference point): nothing must have been sent, because D7 moves
      // the reference point to the landing, which is still ahead of this
      // instant having had 1500ms since it, not since arming.
      final Duration elapsedSoFar = landing + frame;
      await tester.pump(hold - elapsedSoFar);
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'C-408 D7: the hold must count its 1500ms from the walk\'s '
            'landing, not from the turn state that armed it; at exactly '
            '1500ms after the turn state (armed with zero elapsed time '
            'before the walk\'s first step), no move for token 0 must '
            'have been sent yet -- scenario: progress 2 -> 6, armed face '
            '6, landing at ${landing.inMilliseconds}ms. Red on cd75a15 '
            'means _syncAutoMove armed the 1500ms timer at turn-arrival '
            'time instead of at the board\'s landing callback.',
      );

      // Just before landing + 1500ms: still nothing sent ("not before").
      final Duration elapsedNow = hold;
      final Duration target = landing + hold - frame;
      await tester.pump(target - elapsedNow);
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'scenario: progress 2 -> 6, armed face 6, landing at '
            '${landing.inMilliseconds}ms; at '
            '${target.inMilliseconds}ms (one frame before landing + '
            '1500ms), no move must have been sent yet',
      );

      // Just after landing + 1500ms: exactly one move, the right face.
      await tester.pump(frame * 2);
      final List<String> moves = _movesSince(transport, sentAtArm);
      expect(
        moves,
        hasLength(1),
        reason:
            'scenario: progress 2 -> 6, armed face 6, landing at '
            '${landing.inMilliseconds}ms; at '
            '${(landing + hold + frame).inMilliseconds}ms (one frame '
            'after landing + 1500ms), exactly one move must have been '
            'sent; sentRaw carries ${moves.length}',
      );
      expect(_dataOf(moves.single), <String, Object?>{'token': 0, 'face': 6});

      // Nothing further arrives afterward.
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        _movesSince(transport, sentAtArm),
        hasLength(1),
        reason: 'no second move must follow the one the hold already sent',
      );

      await _completeMoveZeroTravel(
        tester,
        transport,
        seq,
        moves.single,
        token: 0,
        atProgress: 6,
      );
    });
  });

  // ==========================================================================
  // Case 2: a long walk (longer than 1500ms), built from what the board
  // really animates and from a queue a real game can hold.
  //
  // Rule 10q/11q cap what a roll queue can look like at the start of a
  // turn's rolling: a 6 reappends and rolls again at once, a non-six ends
  // the rolling, and three sixes in a row void the turn outright. So a
  // queue of three legs, all spent before any bonus, can be at most two
  // sixes and one non-six -- never three sixes. This scenario rolls 6, 6,
  // 5 (two sixes, then the 5 that ends the rolling) and spends them in
  // that order: leg 1 and leg 2 are both 6 squares (face 6, no capture,
  // C-252 rule 2's own per-leg cap of `1 <= new - old <= 6`), and leg 3 is
  // 5 squares (face 5) landing token 0 on Bob's (seat 1) lone token on the
  // main track -- a capture, which rule 11/32 (replayed as 12q under the
  // queue, `captureBonus` on, set in `_roomJson`'s own `rules`) grants a
  // bonus roll for. That roll is a face in 1..6 (armedFace below); once
  // rolled it is the one face left in the queue, and it is the face the
  // hold arms for -- the only way this file can reach a long walk followed
  // by an armed face without inventing a face or a queue shape rule 10q/11q
  // forbid.
  //
  // The capturing leg's own capture-flight animation
  // (`kCaptureFlightDuration`, board.dart) does not extend the walk this
  // hold measures: board.dart's `_onMoveArrived` calls
  // `widget.onMoveLanded` (this screen's `_onBoardMoveLanded`, C-408 D7's
  // only source for "has this leg landed") before it starts the captured
  // token's flight home, and only the flight's own completion, not this
  // screen, advances the board's internal queue to whatever leg (if any)
  // comes after. So the capture adds nothing to the timings below; they
  // are pure step-duration arithmetic, exactly as a non-capturing leg 3
  // would have given.
  //
  // Why three legs, not two: a step already ticking keeps the duration it
  // was given when scheduled (board.dart's `_scheduleNextStep`); only a
  // step scheduled while something else waits in `_queue` runs at half
  // duration. Pushing all three `moved` legs back to back, with zero
  // fake-clock time elapsed before any of leg 1's steps fire (the same
  // "most extreme, clearest case" pattern `_startWalkAndArm` already uses
  // for a single leg), gives:
  //   - leg 1 step 1: scheduled the instant leg 1 starts, before leg 2 or
  //     3 are even pushed -- full duration. Leg 1's remaining 5 steps:
  //     scheduled with leg 2 (and leg 3) already queued -- half duration.
  //   - leg 2: dequeued once leg 1 lands; leg 3 is still queued behind it,
  //     so all 6 of leg 2's own steps schedule at half duration.
  //   - leg 3: dequeued once leg 2 lands; nothing is left queued (the
  //     bonus face is only an armed decision, not a travelling move, until
  //     the hold or a tap sends it), so all 5 of leg 3's own steps
  //     schedule at full duration -- this is also the walk's real landing,
  //     the first moment the token is drawn at its truth again.
  // leg 1 (full + 5 half) + leg 2 (6 half, still hurried by leg 3 behind
  // it) + leg 3 (5 full, nothing left to hurry it) = 490ms + 420ms + 700ms
  // = 1610ms, longer than the 1500ms hold.
  group('case 2 (D7): a long walk, longer than 1500ms', () {
    testWidgets('nothing is sent while the glow has never been visible', (
      tester,
    ) async {
      final (controller, transport) = await _connectSeat0(
        tester,
        // Bob's lone token, at progress 6 (absolute square (13 + 6) mod 52
        // = 19, not one of the eight safe squares rule 1.3 names), is
        // exactly where leg 3 below lands token 0: progress 14 -> 19.
        seat1Tokens: const <int>[6, -1, -1, -1],
      );
      await _mount(tester, controller);
      final _Seq seq = _Seq(1);

      const int leg1Squares = 6;
      const int leg1Face = 6;
      const int leg2Squares = 6;
      const int leg2Face = 6;
      const int leg3Squares = 5;
      const int leg3Face = 5;
      const int armedFace = 3;
      final Duration half = Duration(
        microseconds: kTokenStepDuration.inMicroseconds ~/ 2,
      );
      final Duration leg1Duration =
          kTokenStepDuration + half * (leg1Squares - 1);
      final Duration leg2Duration = half * leg2Squares;
      final Duration leg3Duration = kTokenStepDuration * leg3Squares;
      final Duration leg1Landing = leg1Duration;
      final Duration leg2Landing = leg1Landing + leg2Duration;
      final Duration landing = leg2Landing + leg3Duration;
      const Duration hold = Duration(milliseconds: 1500);
      const Duration frame = Duration(milliseconds: 16);

      expect(
        landing > hold,
        isTrue,
        reason:
            'fixture is broken: this case requires a walk longer than '
            '${hold.inMilliseconds}ms; queued legs of $leg1Squares '
            '(face $leg1Face), $leg2Squares (face $leg2Face) and '
            '$leg3Squares (face $leg3Face, capturing) squares give leg 1 '
            '${leg1Duration.inMilliseconds}ms + leg 2 '
            '${leg2Duration.inMilliseconds}ms + leg 3 '
            '${leg3Duration.inMilliseconds}ms = '
            '${landing.inMilliseconds}ms total',
      );

      // Tracks fake-clock time actually elapsed since the arm (t = 0,
      // below), so every `pump` below advances by exactly the delta to
      // its named target and nothing drifts from a stale running total.
      Duration elapsed = Duration.zero;
      Future<void> advanceTo(Duration target) async {
        final Duration delta = target - elapsed;
        await tester.pump(delta);
        elapsed = target;
      }

      final int sentAtArm = transport.sentRaw.length;

      // Leg 1: 6, no capture, the queue (6, 6, 5) still has two faces left.
      const int leg1From = 2;
      const int leg1To = leg1From + leg1Squares;
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': leg1From,
            'to': leg1To,
            'captured': const <Object?>[],
            'extra_roll': false,
            'face': leg1Face,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // Leg 2: 6, no capture, the queue (6, 5) still has one face left.
      const int leg2From = leg1To;
      const int leg2To = leg2From + leg2Squares;
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': leg2From,
            'to': leg2To,
            'captured': const <Object?>[],
            'extra_roll': false,
            'face': leg2Face,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // Leg 3: 5, captures Bob's lone token (progress 6 for seat 1, the
      // same absolute square token 0 lands on), the last of the (6, 6, 5)
      // queue, and grants the bonus roll rule 12q owes: `extra_roll: true`,
      // `queue` is now empty on the engine side (docs/PROTOCOL.md 21.3
      // rule 3), so the `turn` that follows is `await_roll`, not
      // `await_move` -- section 21.3 rule 4's "move, a roll owed" row.
      const int leg3From = leg2To;
      const int leg3To = leg3From + leg3Squares;
      final int finalProgress = leg3To;
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': leg3From,
            'to': leg3To,
            'captured': const <Object?>[
              <String, Object?>{'seat': 1, 'token': 0},
            ],
            'extra_roll': true,
            'face': leg3Face,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // The roll owed by the capture: section 21.3 rule 4's "move, a roll
      // owed" row, same seat, `await_roll`, the now-empty queue.
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'queue': const <int>[],
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // The bonus roll itself: section 21.3 rule 4's "roll, a move
      // pending" row sends only `rolled` (no further `turn`), carrying the
      // queue (now just the bonus face) and `legal_by_face` -- this is the
      // decision under test, naming token 0 the unique legal token for
      // the one face the bonus roll gave, once all three already-spent
      // legs above have queued on the board.
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': armedFace,
            'legal': const <int>[0],
            'deadline_ms': 45000,
            'k': 4,
            'reveal': 'e' * 64,
            'queue': <int>[armedFace],
            'legal_by_face': <Map<String, Object?>>[
              _faceLegal(armedFace, const <int>[0]),
            ],
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // Just before leg 1 lands: mid-walk, no glow, nothing sent.
      await advanceTo(leg1Landing - frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: token 0 walks progress 2 -> $finalProgress in 3 '
            'queued legs ($leg1Squares, $leg2Squares, $leg3Squares squares; '
            'leg 1 lands at ${leg1Landing.inMilliseconds}ms); at '
            '${elapsed.inMilliseconds}ms, before even leg 1 lands, '
            'board-automove-glow-0-0 must not exist (C-408 D1)',
      );
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'scenario: 3 queued legs, leg 1 landing at '
            '${leg1Landing.inMilliseconds}ms; at ${elapsed.inMilliseconds}ms '
            'no move must have been sent yet',
      );

      // Just past leg 1's landing: still no glow -- a second leg is
      // already queued behind it (C-408 D6: no ring until the last
      // queued leg ends), the walk's own truth is already at
      // $finalProgress, far ahead of where leg 1 only lands.
      await advanceTo(leg1Landing + frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: 3 queued legs; at ${elapsed.inMilliseconds}ms leg '
            '1 has landed but legs 2 and 3 are still queued behind it -- '
            'board-automove-glow-0-0 must still be absent (C-408 D6: no '
            'ring until the last queued leg ends)',
      );

      // Just before leg 2 lands: still mid-walk.
      await advanceTo(leg2Landing - frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: 3 queued legs, leg 2 landing at '
            '${leg2Landing.inMilliseconds}ms; at ${elapsed.inMilliseconds}ms, '
            'before leg 2 lands, board-automove-glow-0-0 must not exist',
      );

      // Just past leg 2's landing: still no glow -- leg 3 is the last
      // queued leg and has not landed yet.
      await advanceTo(leg2Landing + frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: 3 queued legs; at ${elapsed.inMilliseconds}ms leg '
            '2 has landed but leg 3 (the last queued leg) has not -- '
            'board-automove-glow-0-0 must still be absent',
      );

      // At 1500ms after the turn state armed the hold: the walk is still
      // going (leg 3 lands at ${landing.inMilliseconds}ms), so the glow
      // has never been visible, and nothing must have been sent.
      await advanceTo(hold);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: 3 queued legs, walk landing (leg 3) at '
            '${landing.inMilliseconds}ms; at ${elapsed.inMilliseconds}ms, '
            'board-automove-glow-0-0 must still be absent, the walk not '
            'having landed yet',
      );
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'C-408 D7: nothing must be sent while the glow has never '
            'been visible; scenario: 3 queued legs, walk landing at '
            '${landing.inMilliseconds}ms, checked at '
            '${elapsed.inMilliseconds}ms (1500ms after the turn state '
            'armed the hold). Red on cd75a15 means a move for token 0 '
            'already went out before the walk ever landed -- exactly '
            'the P3 violation C-408 D7 names ("the token moved by '
            'itself without warning").',
      );

      // Just before the walk's real landing (leg 3): still nothing.
      await advanceTo(landing - frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: 3 queued legs, walk landing at '
            '${landing.inMilliseconds}ms; at ${elapsed.inMilliseconds}ms, '
            'one frame short of landing, board-automove-glow-0-0 must '
            'not exist',
      );

      // Just past the walk's real landing: the glow is now visible.
      await advanceTo(landing + frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsOneWidget,
        reason:
            'scenario: 3 queued legs; at ${elapsed.inMilliseconds}ms the '
            'walk has fully landed (all 3 queued legs played) and '
            'board-automove-glow-0-0 must be on screen',
      );

      // Just before landing + 1500ms: still nothing sent.
      await advanceTo(landing + hold - frame);
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'scenario: 3 queued legs, landing at '
            '${landing.inMilliseconds}ms; at ${elapsed.inMilliseconds}ms '
            '(one frame before landing + 1500ms), no move must have '
            'been sent yet',
      );

      // Just after landing + 1500ms: exactly one move, the right face.
      await advanceTo(landing + hold + frame);
      final List<String> moves = _movesSince(transport, sentAtArm);
      expect(
        moves,
        hasLength(1),
        reason:
            'scenario: 3 queued legs, landing at '
            '${landing.inMilliseconds}ms; at ${elapsed.inMilliseconds}ms '
            '(one frame after landing + 1500ms), exactly one move must '
            'have been sent; sentRaw carries ${moves.length}',
      );
      expect(_dataOf(moves.single), <String, Object?>{
        'token': 0,
        'face': armedFace,
      });

      // Nothing further arrives afterward.
      await advanceTo(elapsed + const Duration(milliseconds: 500));
      expect(
        _movesSince(transport, sentAtArm),
        hasLength(1),
        reason: 'no second move must follow the one the hold already sent',
      );

      await _completeMoveZeroTravel(
        tester,
        transport,
        seq,
        moves.single,
        token: 0,
        atProgress: finalProgress,
      );
    });
  });

  // ==========================================================================
  // Case 3 (guard): not walking, the unique legal token is at rest when the
  // turn state arrives. This is today's rule, unchanged by D7.
  // ==========================================================================
  group('case 3 (guard): not walking, the hold counts from the turn state', () {
    testWidgets('the move is sent at 1500ms from the turn state, as today', (
      tester,
    ) async {
      final (controller, transport) = await _connectSeat0(tester);
      await _mount(tester, controller);
      final _Seq seq = _Seq(1);

      // No queue, no prior `moved`: the plain C-223 unique-legal roll,
      // token 0 already at rest at progress 2 (its mount truth).
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 0,
            'phase': 'await_move',
            'deadline_ms': 45000,
            'value': 5,
            'legal': const <int>[0],
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(_glowKey(0, 0)),
        findsOneWidget,
        reason:
            'fixture is broken: token 0 is not walking (truth already at '
            'progress 2 from mount), so board-automove-glow-0-0 must be '
            'visible as soon as the unique-legal turn state arrives',
      );

      final int sentAtArm = transport.sentRaw.length;
      await tester.pump(const Duration(milliseconds: 1484));
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'guard: at 1484ms (one frame short of 1500ms) after the '
            'turn state, no move must have been sent yet',
      );

      await tester.pump(const Duration(milliseconds: 32));
      final List<String> moves = _movesSince(transport, sentAtArm);
      expect(
        moves,
        hasLength(1),
        reason:
            'guard: token 0 at rest, turn state arrived with no queue; '
            'exactly one move must be sent 1500ms after the turn state, '
            'as today -- sentRaw carries ${moves.length} move frame(s)',
      );
      expect(_dataOf(moves.single), <String, Object?>{'token': 0});

      await _completeMoveZeroTravel(
        tester,
        transport,
        seq,
        moves.single,
        token: 0,
        atProgress: 2,
      );
    });
  });

  // ==========================================================================
  // Case 4: a tap sends once at once, during the walk and during the hold.
  // ==========================================================================
  group('case 4 (D7): a tap sends once at once, and nothing more later', () {
    testWidgets(
      'a tap during the walk sends once at once; the hold sends nothing '
      'further',
      (tester) async {
        final (controller, transport) = await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        final int sentAtArm = transport.sentRaw.length;
        await _startWalkAndArm(
          tester,
          transport,
          seq,
          fromProgress: 2,
          toProgress: 6,
          movedFace: 4,
          armedFace: 6,
        );

        // Mid-walk (landing is at 560ms): the glow is not up yet, but the
        // hit target still follows truth (C-408 D4, unchanged) and a tap
        // must send immediately through `_sendMove`, the same path a tap
        // always uses.
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.byKey(_glowKey(0, 0)),
          findsNothing,
          reason:
              'fixture is broken: at 200ms into a 560ms walk the glow must '
              'still be hidden (C-408 D1)',
        );
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason: 'fixture is broken: no move must exist yet at 200ms',
        );

        await tester.tap(find.byKey(_hitKey(0, 0)));
        await tester.pump();

        final List<String> movesRightAfterTap = _movesSince(
          transport,
          sentAtArm,
        );
        expect(
          movesRightAfterTap,
          hasLength(1),
          reason:
              'a tap on token 0 mid-walk (200ms into a 560ms walk, progress '
              '2 -> 6) must send exactly one move at once',
        );
        expect(_dataOf(movesRightAfterTap.single), <String, Object?>{
          'token': 0,
          'face': 6,
        });

        await _completeMoveZeroTravel(
          tester,
          transport,
          seq,
          movesRightAfterTap.single,
          token: 0,
          atProgress: 6,
        );

        // Let the walk finish landing, and run well past where either the
        // old (turn-arrival) or the new (landing) 1500ms reference point
        // would have fired. The manual tap must have cancelled the hold
        // outright; nothing further is sent.
        await tester.pump(const Duration(milliseconds: 2200));
        expect(
          _movesSince(transport, sentAtArm),
          hasLength(1),
          reason:
              'after the manual tap already sent the move, neither the '
              'turn-arrival nor the landing-based 1500ms timer must send a '
              'second one',
        );
      },
    );

    testWidgets(
      'a tap during the visible hold sends once at once; nothing more '
      'follows',
      (tester) async {
        final (controller, transport) = await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        final int sentAtArm = transport.sentRaw.length;
        await _startWalkAndArm(
          tester,
          transport,
          seq,
          fromProgress: 2,
          toProgress: 6,
          movedFace: 4,
          armedFace: 6,
        );

        // Past landing (560ms) by a comfortable margin, well before
        // landing + 1500ms (2060ms): the glow is visible and the hold is
        // waiting.
        await tester.pump(const Duration(milliseconds: 900));
        expect(
          find.byKey(_glowKey(0, 0)),
          findsOneWidget,
          reason:
              'fixture is broken: at 900ms the walk (landing 560ms) must '
              'already have landed, so board-automove-glow-0-0 must be '
              'visible',
        );
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason:
              'fixture is broken: at 900ms (well before landing + 1500ms '
              '= 2060ms) no move must exist yet',
        );

        // Once the legal ring (board-legal-ring-0-0, 1.7x the token's own
        // size) is on screen, flutter_test's own hit-test probe at this
        // key's geometric centre reports the roll tray's button as the
        // frontmost render object there (both sit in the same on-screen
        // region once the queue's face tray is showing) and warns; the
        // board's own opaque GestureDetector is still in that hit chain
        // underneath, and the very next assertion (exactly one move, for
        // the right token and face, immediately after this call) is what
        // actually proves the tap reached `_resolveTap`, not the tray.
        await tester.tap(find.byKey(_hitKey(0, 0)), warnIfMissed: false);
        await tester.pump();

        final List<String> movesRightAfterTap = _movesSince(
          transport,
          sentAtArm,
        );
        expect(
          movesRightAfterTap,
          hasLength(1),
          reason:
              'a tap on token 0 during the visible hold (900ms, landing '
              'was at 560ms) must send exactly one move at once',
        );
        expect(_dataOf(movesRightAfterTap.single), <String, Object?>{
          'token': 0,
          'face': 6,
        });

        await _completeMoveZeroTravel(
          tester,
          transport,
          seq,
          movesRightAfterTap.single,
          token: 0,
          atProgress: 6,
        );

        await tester.pump(const Duration(milliseconds: 1500));
        expect(
          _movesSince(transport, sentAtArm),
          hasLength(1),
          reason:
              'after the manual tap already sent the move during the '
              'visible hold, the landing-based 1500ms timer must not send '
              'a second one',
        );
      },
    );
  });

  // ==========================================================================
  // Case 5: the decision changes while the hold waits for the landing.
  // ==========================================================================
  group('case 5 (D7): the decision changes while the hold waits for the '
      'landing', () {
    testWidgets(
      'a turn naming another seat drops the decision; nothing is ever '
      'sent for it, before or after the landing',
      (tester) async {
        final (controller, transport) = await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        final int sentAtArm = transport.sentRaw.length;
        await _startWalkAndArm(
          tester,
          transport,
          seq,
          fromProgress: 2,
          toProgress: 6,
          movedFace: 4,
          armedFace: 6,
        );

        // Mid-walk (landing is at 560ms), the decision is handed away to
        // seat 1 before the walk ever lands.
        await tester.pump(const Duration(milliseconds: 200));
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 1,
              'phase': 'await_roll',
              'deadline_ms': 45000,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // Run past the walk's own landing (560ms total elapsed) and past
        // both the old (turn-arrival) and the new (landing) 1500ms
        // reference points, so the walk's own board animation finishes
        // too (nothing is left mid-travel when the test ends).
        await tester.pump(const Duration(milliseconds: 2200));
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason:
              'scenario: token 0 walks progress 2 -> 6 (landing 560ms), '
              'armed for face 6 at turn-arrival, then at 200ms the turn '
              'moves to seat 1 before the walk lands; nothing must ever '
              'be sent for the dropped decision (token 0, face 6), '
              'before or after the landing -- sentRaw carries '
              '${_movesSince(transport, sentAtArm).length} move frame(s)',
        );
      },
    );

    testWidgets(
      'a new queue for the same seat drops the decision; nothing is ever '
      'sent for it, before or after the landing',
      (tester) async {
        final (controller, transport) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[2, -1, -1, -1],
        );
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        final int sentAtArm = transport.sentRaw.length;
        await _startWalkAndArm(
          tester,
          transport,
          seq,
          fromProgress: 2,
          toProgress: 6,
          movedFace: 4,
          armedFace: 6,
        );

        // Mid-walk, the same seat gets a fresh queue naming a different
        // token (token 1, at rest in the yard) as the new unique legal
        // one for face 3 -- "a new queue" under the same k drops the
        // earlier decision outright (game_screen.dart:1566-1569's own
        // doc comment).
        await tester.pump(const Duration(milliseconds: 200));
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'phase': 'await_move',
              'deadline_ms': 45000,
              'queue': <int>[3],
              'value': 3,
              'legal': const <int>[1],
              'legal_by_face': <Map<String, Object?>>[
                _faceLegal(3, const <int>[1]),
              ],
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // The new decision (token 1, at rest) is unaffected by D7 -- it
        // is not walking -- and fires at its own arm time + 1500ms,
        // 1500ms after the queue swap (200ms in). Run well past both
        // that and the original walk's landing (560ms) plus the old
        // 1500ms-from-first-arm reference point, draining every timer
        // before the test ends.
        await tester.pump(const Duration(milliseconds: 1700));

        final List<String> moves = _movesSince(transport, sentAtArm);
        for (final String moveText in moves) {
          expect(
            _dataOf(moveText)['token'],
            isNot(0),
            reason:
                'scenario: token 0 walks progress 2 -> 6 (landing '
                '560ms), armed for face 6 at turn-arrival; at 200ms a '
                'new queue for the same seat (face 3, token 1) drops '
                'that decision; a move for token 0 / face 6 must never '
                'be sent, before or after the landing, but sentRaw '
                'carries one: $moveText',
          );
        }
        expect(
          moves,
          hasLength(1),
          reason:
              'fixture check: exactly one move is expected overall here, '
              'the re-armed decision for token 1 / face 3 (at rest, '
              'unaffected by D7); sentRaw carries ${moves.length} move '
              'frame(s): $moves',
        );
        expect(_dataOf(moves.single), <String, Object?>{'token': 1, 'face': 3});

        await _completeMoveZeroTravel(
          tester,
          transport,
          seq,
          moves.single,
          token: 1,
          atProgress: -1,
        );
      },
    );
  });

  // ==========================================================================
  // Case 6: reduced motion. The walk is shorter, the rule is the same.
  // ==========================================================================
  group('case 6 (D7): reduced motion, the walk is shorter', () {
    testWidgets('the hold still counts its 1500ms from the (shorter) landing', (
      tester,
    ) async {
      final (controller, transport) = await _connectSeat0(tester);
      await _mount(tester, controller, disableAnimations: true);
      final _Seq seq = _Seq(1);

      final int sentAtArm = transport.sentRaw.length;
      await _startWalkAndArm(
        tester,
        transport,
        seq,
        fromProgress: 2,
        toProgress: 6,
        movedFace: 4,
        armedFace: 6,
      );

      final Duration landing = kTokenStepDurationReduced * 4;
      const Duration hold = Duration(milliseconds: 1500);
      const Duration frame = Duration(milliseconds: 16);

      // Just past the (short) landing: the glow is up.
      await tester.pump(landing + frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsOneWidget,
        reason:
            'scenario (reduced motion): token 0 walks progress 2 -> 6 at '
            '${kTokenStepDurationReduced.inMilliseconds}ms/step, landing '
            'at ${landing.inMilliseconds}ms; board-automove-glow-0-0 '
            'must be visible by ${(landing + frame).inMilliseconds}ms',
      );

      // Just before landing + 1500ms: nothing sent yet.
      final Duration target = landing + hold - frame;
      await tester.pump(target - (landing + frame));
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'scenario (reduced motion): landing at '
            '${landing.inMilliseconds}ms; at '
            '${target.inMilliseconds}ms (one frame before landing + '
            '1500ms) no move must have been sent yet',
      );

      // Just after landing + 1500ms: exactly one move, the right face.
      await tester.pump(frame * 2);
      final List<String> moves = _movesSince(transport, sentAtArm);
      expect(
        moves,
        hasLength(1),
        reason:
            'scenario (reduced motion): landing at '
            '${landing.inMilliseconds}ms; at '
            '${(landing + hold + frame).inMilliseconds}ms exactly one '
            'move must have been sent; sentRaw carries ${moves.length}',
      );
      expect(_dataOf(moves.single), <String, Object?>{'token': 0, 'face': 6});

      await _completeMoveZeroTravel(
        tester,
        transport,
        seq,
        moves.single,
        token: 0,
        atProgress: 6,
      );
    });
  });
}
