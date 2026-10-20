// Tests for work/ludo/orders/C-408-ring-waits-for-the-token.md decision 8
// (added run 99, the master's read of order 412's diff): the unique-legal
// hold's wait for a travelling leg is bounded by a ceiling. 412 learns "the
// held token is still walking" from a count kept on GameScreen
// (_markLegTravelling / _markLegLanded, keyed the same way board.dart keys
// its own override map): +1 per `moved` frame with `from != to` reaching
// `widget.controller.frames`, -1 per the board's own `onMoveLanded` for
// that seat/token, cleared by a snap (`_onBoardTravelReset`). Every frame
// reaches the screen (via `RoomController.frames`, forwarded unconditionally
// ahead of the reducer) before the controller decides whether to apply it,
// and the board animates token DIFFS between builds, not frames -- so a
// counted leg can exist that the board never lands: two `moved` frames of
// one token arriving in a single build with a net advance of 1 to 6
// (board.dart lines 593-603's own `moverDiffs` test, read before this file
// was written: `newP - oldP` between 1 and 6 inclusive, with the rest of
// the diffs empty,
// is classified as exactly one travelling `_Move`, so two separate `moved`
// frames that land on that net span make the board animate it as a single
// leg and call `onMoveLanded` exactly once, leaving the count stuck above
// zero forever), or a `moved` the controller refuses (seq not `room.seq +
// 1`) followed by a resync whose snapshot leaves that token where it was
// (the controller's own `frames` stream forwards every pushed frame to the
// screen unconditionally, ahead of the reducer's seq check --
// room_controller.dart:907-928 -- so the refused frame still reaches
// `_markLegTravelling` even though the board's `tokens` never moves for
// it). D8's rule: arming the ceiling when the wait starts, computed from
// the legs counted at that moment: (sum of every counted leg, all seats) x
// (6 x the step duration in force + the capture flight duration in force) +
// 250ms. If neither a landing with no further leg counted, nor a snap, has
// started the 1500ms hold by the ceiling, the ceiling starts it and zeroes
// the held token's leg count.
//
// Written from work/ludo/orders/C-408-ring-waits-for-the-token.md alone,
// decisions 7 and 8 above all, plus docs/PROTOCOL.md section 21 for the
// frame shapes a queued decision carries. The fix is order 414, in
// parallel; it is not built on this base (d59bf79), which carries D1-D7
// only (no ceiling exists anywhere in game_screen.dart on this tree), so
// cases 1 and 3 below are expected to fail here, and are red for that
// reason: on this base the hold waits forever once a leg is ever counted
// that the board never lands, exactly as D8 describes before its own fix.
//
// GameScreen is driven the same way test/hold_after_walk_test.dart and
// test/play_surface_automove_test.dart drive RoomController: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only, not edited here). Every helper below is copied from those
// files' pattern, not imported -- this file is free-standing. The 1500ms
// hold, every token walk, and the ceiling's own wait are all advanced on
// flutter_test's fake clock through bounded `tester.pump(duration)` steps;
// nothing here uses `pumpAndSettle` (board.dart's legal ring pulses forever
// once it is on screen) or a real Timer.
//
// The coalescing a real server's "phone with the screen off" scenario
// needs (D8's own example: "a capture and its bonus leg") is built here,
// case 1 and case 6, from two ordinary (non-capturing) queued leg moves of
// one roll-queue decision instead of a capture-and-bonus-roll pair: the
// capture-bonus path (docs/PROTOCOL.md 21.3 ruling 4's "move, a roll owed"
// row) needs a second `rolled` round trip between the two legs, and
// board.dart lines 593-621's own diff classification
// (`moverDiffs.length == 1`, `newP - oldP` in 1..6, and the rest of the
// diffs either empty or exactly one capture) does not care whether the net
// span came from a capture or an
// ordinary double-face queue -- both are "two `moved` frames of my token 0
// ... net advance 1 to 6" exactly as D8's own wording asks for, and the
// plain queue needs no second roll round trip. This is a deliberate choice,
// not an oversight; see the report for this order for the full reasoning.
//
// Every assertion below reads `transport.sentRaw` (what actually went out
// on the wire) or a widget key already on screen (the glow key the board
// itself draws, or the automove-glow's presence/absence as the proof that a
// travel truly played out continuously rather than landing early or
// snapping); nothing here reaches into GameScreenState's private fields.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart'
    show
        kCaptureFlightDuration,
        kCaptureFlightDurationReduced,
        kTokenStepDuration,
        kTokenStepDurationReduced;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://hold-walk-ceiling-test.invalid/ws';
const Duration _frame = Duration(milliseconds: 16);
const Duration _hold = Duration(milliseconds: 1500);

Key _glowKey(int seat, int index) => Key('board-automove-glow-$seat-$index');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'hold-walk-ceiling-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

String _frameText({
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
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
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
/// the frame, which would silently break every scenario but case 2, whose
/// whole point is that exact mismatch).
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

/// Mounts at a realistic phone size (test/hold_after_walk_test.dart's own
/// choice), not the default test surface: the roll-queue's face tray is UI
/// this file's cases drive (`legal_by_face` is always set once the hold
/// arms), and on the default test surface that tray sits close enough to
/// the board to confuse a tap -- not that this file taps anything, but the
/// tray's own layout can otherwise shift where the glow key's hit-tested
/// ancestor sits.
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
/// seat 0's tokens set to [seat0Tokens]. No `rolled` frame is modelled
/// here: every case below pushes its own `moved` / `turn` frames directly,
/// which is all `RoomController`'s reducers (room_controller.dart:1408-
/// 1489 for `moved`, 1002-1021 for the `room` a resume reply decodes
/// through) actually require.
Future<(RoomController, FakeTransport)> _connectSeat0(
  WidgetTester tester, {
  List<int> seat0Tokens = const <int>[2, -1, -1, -1],
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
    _frameText(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frameText(
      type: 'room',
      re: id,
      data: _roomJson(
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: seat0Tokens),
          _seatJson(1, name: 'Bob'),
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

List<String> _movesSince(FakeTransport transport, int sentBefore) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((s) => _typeOf(s) == 'move')
      .toList();
}

/// The D8 ceiling, computed exactly as the contract's own words give it:
/// "(sum of every counted leg, all seats) x (6 x the step duration in
/// force + the capture flight duration in force) + 250 ms". [legs] is the
/// leg count this test built the scenario to hold at the moment the wait
/// starts (the only seat and token in play below is seat 0's token 0, so
/// "all seats" is just that one count here). Every factor is a named
/// constant read off board.dart, never a bare number.
Duration _ceiling(int legs, {bool reduced = false}) {
  final Duration step = reduced
      ? kTokenStepDurationReduced
      : kTokenStepDuration;
  final Duration captureFlight = reduced
      ? kCaptureFlightDurationReduced
      : kCaptureFlightDuration;
  return step * 6 * legs +
      captureFlight * legs +
      const Duration(milliseconds: 250);
}

/// Pushes the two `moved` frames (and the `turn` between them the queue
/// requires, docs/PROTOCOL.md 21.3 ruling 4's "move, faces left that can
/// move" row) that make up one roll-queue decision's two legs, landing a
/// net advance of [fromProgress] to [toProgress] for seat 0's token 0, then
/// the final `turn` that arms the unique-legal hold for [armedFace]. Every
/// one of these four frames is pushed with zero `tester.pump` calls between
/// them -- the only way to make GameScreen (and, through it, LudoBoard)
/// rebuild exactly once for the whole batch, since a test driver can only
/// ever draw a frame inside a `pump` call. That single rebuild hands
/// LudoBoard an `oldWidget.tokens` from before either leg and a
/// `widget.tokens` from after both, which is what makes board.dart's own
/// diff classification (board.dart:593-603, read before this file was
/// written) treat the whole net span as one travelling `_Move` -- the
/// coalescing D8 is about. [legFace1] and [legFace2] must sum to
/// `toProgress - fromProgress` for the two queued faces to actually
/// describe that span.
Future<int> _armAfterCoalescedLegs(
  WidgetTester tester,
  FakeTransport transport,
  _Seq seq, {
  required int fromProgress,
  required int toProgress,
  required int legFace1,
  required int legFace2,
  required int armedFace,
  required int k,
}) async {
  final int midProgress = fromProgress + legFace1;
  expect(
    midProgress + legFace2,
    toProgress,
    reason:
        'fixture is broken: legFace1 ($legFace1) + legFace2 ($legFace2) '
        'must span fromProgress ($fromProgress) to toProgress ($toProgress)',
  );
  final int sentAtArm = transport.sentRaw.length;
  transport.pushText(
    _frameText(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': fromProgress,
        'to': midProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
        'face': legFace1,
        'seq': seq.next(),
      },
    ),
  );
  transport.pushText(
    _frameText(
      type: 'turn',
      data: <String, Object?>{
        'seat': 0,
        'phase': 'await_move',
        'deadline_ms': 45000,
        'queue': <int>[legFace2],
        'value': legFace2,
        'legal': const <int>[0],
        'legal_by_face': <Map<String, Object?>>[
          _faceLegal(legFace2, const <int>[0]),
        ],
        'k': k,
        'seq': seq.next(),
      },
    ),
  );
  transport.pushText(
    _frameText(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': midProgress,
        'to': toProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
        'face': legFace2,
        'seq': seq.next(),
      },
    ),
  );
  transport.pushText(
    _frameText(
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
        'k': k,
        'seq': seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  return sentAtArm;
}

/// Answers a sent `move` with a zero-travel `moved` (from == to): resolves
/// the pending `RoomConnection.move` request without starting a second
/// board travel a test case would then have to drain too.
Future<void> _completeMoveZeroTravel(
  WidgetTester tester,
  FakeTransport transport,
  _Seq seq,
  String moveText, {
  required int token,
  required int atProgress,
}) async {
  transport.pushText(
    _frameText(
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
  // Case 1: a counted leg the board never lands (coalesced).
  // ==========================================================================
  group('case 1 (D8): two moved frames coalesce into one leg the board '
      'never lands', () {
    testWidgets(
      'the glow still appears; exactly one move is sent no later than '
      'ceiling + 1500ms + one frame, and not before the glow has been '
      'visible for 1500ms',
      (tester) async {
        final (controller, transport) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[1, -1, -1, -1],
        );
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        // Scenario: token 0's roll queue is [1, 4] (sum 5, net progress
        // 1 -> 6). Both legs, and the `turn` between them the queue
        // requires, reach the screen before any build (zero `pump` calls
        // between the four pushes in `_armAfterCoalescedLegs`): a real
        // server could send exactly this to a phone with its screen off,
        // which is why D8 exists.
        const int fromProgress = 1;
        const int toProgress = 6;
        const int legFace1 = 1;
        const int legFace2 = 4;
        const int armedFace = 6;
        final int sentAtArm = await _armAfterCoalescedLegs(
          tester,
          transport,
          seq,
          fromProgress: fromProgress,
          toProgress: toProgress,
          legFace1: legFace1,
          legFace2: legFace2,
          armedFace: armedFace,
          k: 0,
        );
        const int midProgress = fromProgress + legFace1;

        expect(
          controller.room!.seats[0].tokens[0],
          toProgress,
          reason:
              'fixture is broken: both legs must have been reduced into '
              'room state in one batch before the first build; truth for '
              'token 0 must already read $toProgress',
        );

        // First assert (the case's own requirement): the board really
        // holds a leg it never lands, not one it has already landed
        // (early, because the second `moved` frame never reduced into
        // truth) and not one it snapped past (because the diff was
        // rejected by board.dart's own classification, which would show
        // the glow almost at once instead of after a full continuous
        // travel). A single `_Move` over the whole 5-square net span
        // (progress 2, 3, 4, 5, 6) takes 5 * kTokenStepDuration to land;
        // one frame short of that, the glow must still be absent.
        final Duration singleLegLanding = kTokenStepDuration * 5;
        await tester.pump(singleLegLanding - _frame);
        expect(
          find.byKey(_glowKey(0, 0)),
          findsNothing,
          reason:
              'scenario: token 0 progress $fromProgress -> $toProgress via '
              'queued faces $legFace1 then $legFace2, delivered as two '
              '`moved` frames in one build; at '
              '${(singleLegLanding - _frame).inMilliseconds}ms (one frame '
              'short of the single 5-step travel landing), '
              'board-automove-glow-0-0 must still be absent -- if it is '
              'already present, the board landed or snapped this leg '
              'early and the case does not hold a leg the board never '
              'lands',
        );
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason:
              'fixture is broken: no move must have been sent yet at '
              '${(singleLegLanding - _frame).inMilliseconds}ms',
        );

        // Just past that single travel's own landing: the glow comes up
        // (board.dart D2), because the disc has reached the truth board.
        // dart now holds for it (6) -- this is the leg the board actually
        // plays and lands, on top of which the *second* counted leg (the
        // one `_markLegTravelling` counted for the first `moved` frame,
        // whose own landing the board's single combined `_Move` never
        // separately reports) is what keeps the hold waiting forever
        // below.
        await tester.pump(_frame * 2);
        expect(
          find.byKey(_glowKey(0, 0)),
          findsOneWidget,
          reason:
              'scenario: token 0 progress $fromProgress -> $toProgress; at '
              '${(singleLegLanding + _frame).inMilliseconds}ms the single '
              'board travel has landed and board-automove-glow-0-0 must '
              'be on screen (C-408 D2)',
        );

        // D8's own ceiling, computed from the legs counted when the wait
        // started: two `moved` frames of token 0 were counted
        // (_markLegTravelling fires once per frame, independent of how
        // many the board coalesces into one `_Move`), so legs = 2.
        final Duration ceiling = _ceiling(2);
        final Duration elapsedSoFar = singleLegLanding + _frame * 2;

        // Not before the glow has been visible for 1500ms: at exactly
        // glow-visible + 1500ms (which is well before the ceiling, since
        // the ceiling only matters when the glow is never seen at all),
        // nothing must have been sent, because this scenario's glow *is*
        // visible (the board truly lands the combined leg) and this
        // assertion only guards against the hold firing too early.
        final Duration glowPlus1500 = singleLegLanding + _frame * 2 + _hold;
        if (glowPlus1500 > elapsedSoFar) {
          await tester.pump(glowPlus1500 - elapsedSoFar);
        }

        // Bound the wait at ceiling + 1500ms + one frame (the point D8
        // promises a move by), plus 3000ms of slack the order asks for so
        // a red run reports exactly what (if anything) went out instead
        // of just timing out silently.
        final Duration dueBy = ceiling + _hold + _frame;
        final Duration reportBound =
            ceiling + const Duration(milliseconds: 3000);
        final Duration elapsedAtGlowPlus1500 = glowPlus1500 > elapsedSoFar
            ? glowPlus1500
            : elapsedSoFar;
        final Duration stepToDueBy = dueBy - elapsedAtGlowPlus1500;
        if (stepToDueBy > Duration.zero) {
          await tester.pump(stepToDueBy - _frame);
        }
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason:
              'C-408 D8: no move for token 0 must be sent before ceiling '
              '(${ceiling.inMilliseconds}ms, from 2 counted legs) + 1500ms '
              '+ one frame = ${dueBy.inMilliseconds}ms after the turn '
              'state that armed this hold; checked one frame short of '
              'that bound',
        );

        await tester.pump(reportBound - (dueBy - _frame));
        final List<String> moves = _movesSince(transport, sentAtArm);
        expect(
          moves,
          hasLength(1),
          reason:
              'C-408 D8: exactly one move for token 0 (face $armedFace) '
              'must have been sent by ceiling '
              '(${ceiling.inMilliseconds}ms, from 2 counted legs) + '
              '1500ms + one frame = ${dueBy.inMilliseconds}ms after the '
              'turn state that armed this hold -- scenario: queued legs '
              'progress $fromProgress -[face $legFace1]-> $midProgress '
              '-[face $legFace2]-> $toProgress, armed for face $armedFace. '
              'Checked at ${reportBound.inMilliseconds}ms (ceiling + '
              '3000ms); sentRaw after arming carries ${moves.length} move '
              'frame(s): $moves. Red on d59bf79 means the ceiling this '
              'contract describes does not exist anywhere in '
              'game_screen.dart on this tree: _markLegTravelling counted '
              'both legs (2), nothing ever counted a landing for the '
              'second one (the board only ever played one combined '
              '`_Move` and called onMoveLanded once), and no ceiling '
              'timer exists to notice and recover -- the hold waits '
              'forever, exactly as D8 describes before its own fix '
              '(order 414).',
        );
        if (moves.isNotEmpty) {
          expect(_dataOf(moves.single), <String, Object?>{
            'token': 0,
            'face': armedFace,
          });
          await _completeMoveZeroTravel(
            tester,
            transport,
            seq,
            moves.single,
            token: 0,
            atProgress: toProgress,
          );
        }
      },
    );
  });

  // ==========================================================================
  // Case 2: a refused frame (seq mismatch) followed by a resync.
  // ==========================================================================
  group('case 2 (D8): a refused moved frame, then a resync that leaves the '
      'token where it was', () {
    testWidgets(
      'the refused frame still counts as a travelling leg on the screen; '
      'the resync never lands it; the hold still ceilings out',
      (tester) async {
        final (controller, transport) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[2, -1, -1, -1],
        );
        await _mount(tester, controller);

        final int roomSeqBefore = controller.room!.seq;
        final int sentAtArm = transport.sentRaw.length;

        // A `moved` of token 0 whose seq is far ahead of room.seq + 1: a
        // real gap (a frame this socket missed), not a replay -- the
        // refusal path room_controller.dart:1446-1449 takes before it
        // ever touches `seats`. This still reaches the screen's own
        // `frames` listener (room_controller.dart:926-928, run ahead of
        // the reducer, unconditionally) and so still counts as a
        // travelling leg there, even though the reducer never applies it.
        transport.pushText(
          _frameText(
            type: 'moved',
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 2,
              'to': 6,
              'captured': const <Object?>[],
              'extra_roll': false,
              'face': 4,
              'seq': roomSeqBefore + 9,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.hasDesynced,
          isTrue,
          reason:
              'fixture is broken: a moved whose seq is not room.seq + 1 '
              'must set hasDesynced and start a resync',
        );
        expect(
          controller.room!.seats[0].tokens[0],
          2,
          reason:
              'fixture is broken: the refused moved frame must not have '
              'moved token 0 at all; truth must still read 2',
        );

        final List<String> resumeRaw = transport.sentRaw
            .skip(sentAtArm)
            .where((String raw) => _typeOf(raw) == 'resume')
            .toList();
        expect(
          resumeRaw,
          hasLength(1),
          reason:
              'fixture is broken: the seq gap must have started exactly '
              'one resume on the current connection; sentRaw carries '
              '${resumeRaw.length}',
        );

        // Answer the resume with a snapshot that leaves token 0 exactly
        // where it was before the refused frame -- D8's own "a resync
        // whose snapshot leaves that token where it was".
        transport.pushText(
          _frameText(
            type: 'room',
            re: _idOf(resumeRaw.single),
            data: _roomJson(
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam', tokens: const <int>[2, -1, -1, -1]),
                _seatJson(1, name: 'Bob'),
              ],
              turn: _turnJson(
                seat: 0,
                phase: 'await_roll',
                deadlineMs: 45000,
                k: 0,
              ),
              seq: roomSeqBefore + 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        // Reseeded from the room's real seq after the resume reply
        // replaced it wholesale, so every frame pushed from here on
        // carries the next genuinely valid seq.
        final _Seq seq = _Seq(controller.room!.seq);

        expect(
          controller.hasDesynced,
          isFalse,
          reason: 'fixture is broken: the resume reply must clear hasDesynced',
        );
        expect(
          controller.room!.seats[0].tokens[0],
          2,
          reason:
              'fixture is broken: the resync snapshot must still read '
              'token 0 at progress 2, unmoved',
        );

        // Now the turn state that makes token 0 the unique legal token.
        // It is already at rest (truth 2 is where the board has drawn it
        // the whole time -- the refused frame never changed anything the
        // board saw), so the glow should come up at once, the same D1/D2
        // guard case 4 pins directly.
        transport.pushText(
          _frameText(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'phase': 'await_move',
              'deadline_ms': 45000,
              'queue': <int>[5],
              'value': 5,
              'legal': const <int>[0],
              'legal_by_face': <Map<String, Object?>>[
                _faceLegal(5, const <int>[0]),
              ],
              'k': 0,
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
              'fixture is broken: token 0 is at rest at its mount truth '
              '(progress 2), so board-automove-glow-0-0 must be visible '
              'as soon as the unique-legal turn state arrives',
        );

        // D8's ceiling from this case's own leg count: the refused frame
        // counted exactly one travelling leg (_markLegTravelling fires
        // once per `moved` frame reaching the screen, regardless of
        // whether the reducer ever applies it), and nothing has landed or
        // snapped it away since (the resync's snapshot left the token
        // exactly where it was, not where the refused frame claimed).
        final Duration ceiling = _ceiling(1);
        final Duration dueBy = ceiling + _hold + _frame;
        final Duration reportBound =
            ceiling + const Duration(milliseconds: 3000);

        await tester.pump(dueBy - _frame);
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason:
              'C-408 D8: no move for token 0 must be sent before ceiling '
              '(${ceiling.inMilliseconds}ms, from 1 counted leg -- the '
              'refused frame) + 1500ms + one frame = '
              '${dueBy.inMilliseconds}ms after the turn state',
        );

        await tester.pump(reportBound - (dueBy - _frame));
        final List<String> moves = _movesSince(transport, sentAtArm);
        expect(
          moves,
          hasLength(1),
          reason:
              'C-408 D8: exactly one move for token 0 (face 5) must have '
              'been sent by ceiling (${ceiling.inMilliseconds}ms, 1 '
              'counted leg) + 1500ms + one frame = '
              '${dueBy.inMilliseconds}ms after the turn state -- '
              'scenario: a moved of token 0 refused (seq room.seq + 9), '
              'resync snapshot leaves it at progress 2, then armed for '
              'face 5. Checked at ${reportBound.inMilliseconds}ms '
              '(ceiling + 3000ms); sentRaw after arming carries '
              '${moves.length} move frame(s): $moves.',
        );
        if (moves.isNotEmpty) {
          expect(_dataOf(moves.single), <String, Object?>{
            'token': 0,
            'face': 5,
          });
          await _completeMoveZeroTravel(
            tester,
            transport,
            seq,
            moves.single,
            token: 0,
            atProgress: 2,
          );
        }
      },
    );
  });

  // ==========================================================================
  // Case 3: the next hold is not poisoned by a ceiling that already fired.
  // ==========================================================================
  group('case 3 (D8): a later hold of the same token, after the ceiling, '
      'is not poisoned', () {
    testWidgets(
      'the move for the next unique-legal decision is sent 1500ms (plus '
      'at most one frame) after its own turn state',
      (tester) async {
        final (controller, transport) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[1, -1, -1, -1],
        );
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        const int fromProgress = 1;
        const int toProgress = 6;
        const int legFace1 = 1;
        const int legFace2 = 4;
        const int armedFace1 = 6;
        // The first arm's own sentAtArm offset is not needed here: this
        // case only asserts on what is sent after the *second* turn state
        // below, never on the first (unresolved) decision's own send
        // window, which case 1 already covers.
        await _armAfterCoalescedLegs(
          tester,
          transport,
          seq,
          fromProgress: fromProgress,
          toProgress: toProgress,
          legFace1: legFace1,
          legFace2: legFace2,
          armedFace: armedFace1,
          k: 0,
        );

        // Run past case 1's own ceiling + 1500ms + one frame -- the point
        // at which, per D8, the first hold's move should already have
        // gone out and the leg count should already have been zeroed.
        final Duration ceiling1 = _ceiling(2);
        await tester.pump(ceiling1 + _hold + _frame * 2);

        // The turn state that makes token 0 the unique legal token again,
        // for a new decision (a new queue under the same k), while it is
        // at rest: the board's own travel for the combined leg above
        // landed long before this point (5 steps at kTokenStepDuration,
        // well under the ceiling), so the disc is sitting still at
        // progress 6 already.
        const int armedFace2 = 3;
        transport.pushText(
          _frameText(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'phase': 'await_move',
              'deadline_ms': 45000,
              'queue': <int>[armedFace2],
              'value': armedFace2,
              'legal': const <int>[0],
              'legal_by_face': <Map<String, Object?>>[
                _faceLegal(armedFace2, const <int>[0]),
              ],
              'k': 0,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        final int sentAtSecondArm = transport.sentRaw.length;

        expect(
          find.byKey(_glowKey(0, 0)),
          findsOneWidget,
          reason:
              'fixture is broken: token 0 is at rest at progress '
              '$toProgress (the earlier combined travel landed long '
              'before this point), so board-automove-glow-0-0 must be '
              'visible as soon as this second unique-legal turn state '
              'arrives',
        );

        await tester.pump(_hold - _frame);
        expect(
          _movesSince(transport, sentAtSecondArm),
          isEmpty,
          reason:
              'guard: at 1484ms (one frame short of 1500ms) after the '
              'second turn state, no move must have been sent yet',
        );

        await tester.pump(_frame * 2);
        final List<String> moves = _movesSince(transport, sentAtSecondArm);
        expect(
          moves,
          hasLength(1),
          reason:
              'C-408 D8: the next hold of token 0, armed after case 1\'s '
              'own ceiling + 1500ms + one frame has already passed, must '
              'not be poisoned by the earlier stuck leg count -- its move '
              '(face $armedFace2) must be sent 1500ms (plus at most one '
              'frame) after its own turn state, not blocked by a leg '
              'count the first ceiling should already have zeroed. '
              'sentRaw since this second turn state carries ${moves.length} '
              'move frame(s): $moves. Red on d59bf79 means the first '
              'hold\'s move never actually went out (there is no ceiling '
              'to zero the leg count), so this second decision is still '
              'reading a travelling-leg count of 1 from the first, never '
              'cleared, and `_syncAutoMove` defers it exactly the way it '
              'deferred the first.',
        );
        if (moves.isNotEmpty) {
          expect(_dataOf(moves.single), <String, Object?>{
            'token': 0,
            'face': armedFace2,
          });
        }
      },
    );
  });

  // ==========================================================================
  // Case 4 (guard): a real walk still waits for its landing, D7 unchanged.
  // ==========================================================================
  group('case 4 (guard, D7 unchanged): a real walk still waits for its '
      'landing, not the ceiling', () {
    testWidgets('the move is sent 1500ms after the landing, not at the '
        'ceiling and not before', (tester) async {
      final (controller, transport) = await _connectSeat0(tester);
      await _mount(tester, controller);
      final _Seq seq = _Seq(1);

      // One ordinary `moved` of token 0 (progress 2 -> 6, 4 squares),
      // then the turn state that arms the hold, exactly D7's own case:
      // the walk really plays, lands once, and onMoveLanded fires for it
      // -- the leg count this file is about never even gets involved
      // beyond the ordinary D7 path.
      // A face distinct from the walk's own face (4), so the sent move's
      // payload cannot be mistaken for an echo of the moved frame.
      const int armedFace = 5;
      final int sentAtArm = transport.sentRaw.length;
      transport.pushText(
        _frameText(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 2,
            'to': 6,
            'captured': const <Object?>[],
            'extra_roll': false,
            'face': 4,
            'seq': seq.next(),
          },
        ),
      );
      transport.pushText(
        _frameText(
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
            'k': 0,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      final Duration landing = kTokenStepDuration * 4;
      // D8's ceiling, if it mattered here, from this scenario's own leg
      // count (1 counted leg -- the single ordinary moved frame): it must
      // not matter, because D8 itself promises "every walk the board
      // really plays lands before its ceiling".
      final Duration ceiling = _ceiling(1);
      expect(
        landing < ceiling,
        isTrue,
        reason:
            'fixture check: this guard only means something if the real '
            'landing (${landing.inMilliseconds}ms) comes well before the '
            'ceiling (${ceiling.inMilliseconds}ms) it is meant to show is '
            'irrelevant here',
      );

      await tester.pump(landing - _frame);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsNothing,
        reason:
            'scenario: token 0 walks progress 2 -> 6 (landing '
            '${landing.inMilliseconds}ms); at '
            '${(landing - _frame).inMilliseconds}ms, still mid-walk, '
            'board-automove-glow-0-0 must not exist (C-408 D1)',
      );
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason: 'fixture is broken: no move must exist before the walk lands',
      );

      await tester.pump(_frame * 2);
      expect(
        find.byKey(_glowKey(0, 0)),
        findsOneWidget,
        reason:
            'scenario: token 0 walks progress 2 -> 6; at '
            '${(landing + _frame).inMilliseconds}ms the walk has landed '
            'and board-automove-glow-0-0 must be on screen (C-408 D2)',
      );

      final Duration elapsedSoFar = landing + _frame * 2;
      final Duration target = landing + _hold - _frame;
      await tester.pump(target - elapsedSoFar);
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'guard (D7 unchanged): at '
            '${target.inMilliseconds}ms (one frame short of landing + '
            '1500ms), no move must have been sent yet -- and in '
            'particular not at the ceiling '
            '(${ceiling.inMilliseconds}ms), which this real walk never '
            'needs',
      );

      await tester.pump(_frame * 2);
      final List<String> moves = _movesSince(transport, sentAtArm);
      expect(
        moves,
        hasLength(1),
        reason:
            'guard (D7 unchanged): exactly one move must be sent at '
            'landing (${landing.inMilliseconds}ms) + 1500ms, not at the '
            'ceiling (${ceiling.inMilliseconds}ms) and not before; '
            'sentRaw carries ${moves.length} move frame(s)',
      );
      expect(_dataOf(moves.single), <String, Object?>{
        'token': 0,
        'face': armedFace,
      });

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
  // Case 5: dropping the decision during the ceiling wait.
  // ==========================================================================
  group('case 5 (D8): the decision is dropped while the ceiling is still '
      'waiting', () {
    testWidgets(
      'nothing is ever sent for the dropped decision, through ceiling + '
      '3000ms',
      (tester) async {
        final (controller, transport) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[1, -1, -1, -1],
        );
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        const int fromProgress = 1;
        const int toProgress = 6;
        const int legFace1 = 1;
        const int legFace2 = 4;
        const int armedFace = 6;
        final int sentAtArm = await _armAfterCoalescedLegs(
          tester,
          transport,
          seq,
          fromProgress: fromProgress,
          toProgress: toProgress,
          legFace1: legFace1,
          legFace2: legFace2,
          armedFace: armedFace,
          k: 0,
        );

        // Shortly after arming (well before the ceiling, computed from
        // this scenario's own 2 counted legs), a new turn state for seat
        // 1 arrives and hands the decision away before the ceiling ever
        // fires.
        final Duration ceiling = _ceiling(2);
        await tester.pump(const Duration(milliseconds: 50));
        transport.pushText(
          _frameText(
            type: 'turn',
            data: <String, Object?>{
              'seat': 1,
              'phase': 'await_roll',
              'deadline_ms': 45000,
              'queue': const <int>[],
              'k': 1,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // Run through ceiling + 3000ms. Nothing must ever be sent for the
        // dropped decision (token 0, face $armedFace).
        await tester.pump(
          ceiling +
              const Duration(milliseconds: 3000) -
              const Duration(milliseconds: 50),
        );
        final List<String> moves = _movesSince(transport, sentAtArm);
        expect(
          moves,
          isEmpty,
          reason:
              'scenario: token 0 progress $fromProgress -> $toProgress '
              '(queued legs $legFace1 then $legFace2), armed for face '
              '$armedFace, then at 50ms the turn moves to seat 1 before '
              'the ceiling (${ceiling.inMilliseconds}ms) ever fires; '
              'nothing must ever be sent for the dropped decision -- '
              'sentRaw carries ${moves.length} move frame(s): $moves',
        );
      },
    );
  });

  // ==========================================================================
  // Case 6 (D8): reduced motion, the ceiling's own durations shorten too.
  // ==========================================================================
  group('case 6 (D8): reduced motion, case 1 with the reduced durations', () {
    testWidgets(
      'the same coalesced-leg scenario under disableAnimations, ceiling '
      'computed from the Reduced pair',
      (tester) async {
        final (controller, transport) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[1, -1, -1, -1],
        );
        await _mount(tester, controller, disableAnimations: true);
        final _Seq seq = _Seq(1);

        const int fromProgress = 1;
        const int toProgress = 6;
        const int legFace1 = 1;
        const int legFace2 = 4;
        const int armedFace = 6;
        final int sentAtArm = await _armAfterCoalescedLegs(
          tester,
          transport,
          seq,
          fromProgress: fromProgress,
          toProgress: toProgress,
          legFace1: legFace1,
          legFace2: legFace2,
          armedFace: armedFace,
          k: 0,
        );

        expect(
          controller.room!.seats[0].tokens[0],
          toProgress,
          reason:
              'fixture is broken: both legs must have been reduced into '
              'room state in one batch before the first build',
        );

        // The combined leg's single `_Move` now takes 5 *
        // kTokenStepDurationReduced to land.
        final Duration singleLegLanding = kTokenStepDurationReduced * 5;
        await tester.pump(singleLegLanding - _frame);
        expect(
          find.byKey(_glowKey(0, 0)),
          findsNothing,
          reason:
              'scenario (reduced motion): at '
              '${(singleLegLanding - _frame).inMilliseconds}ms (one frame '
              'short of the single 5-step reduced-duration travel '
              'landing), board-automove-glow-0-0 must still be absent',
        );

        await tester.pump(_frame * 2);
        expect(
          find.byKey(_glowKey(0, 0)),
          findsOneWidget,
          reason:
              'scenario (reduced motion): at '
              '${(singleLegLanding + _frame).inMilliseconds}ms the single '
              'board travel has landed and board-automove-glow-0-0 must '
              'be on screen',
        );

        // The ceiling under disableAnimations uses the Reduced pair: 2
        // counted legs x (6 * kTokenStepDurationReduced +
        // kCaptureFlightDurationReduced) + 250ms.
        final Duration ceiling = _ceiling(2, reduced: true);
        final Duration dueBy = ceiling + _hold + _frame;
        final Duration reportBound =
            ceiling + const Duration(milliseconds: 3000);
        final Duration elapsedSoFar = singleLegLanding + _frame * 2;

        final Duration stepToDueBy = dueBy - elapsedSoFar;
        if (stepToDueBy > Duration.zero) {
          await tester.pump(stepToDueBy - _frame);
        }
        expect(
          _movesSince(transport, sentAtArm),
          isEmpty,
          reason:
              'C-408 D8 (reduced motion): no move for token 0 must be '
              'sent before ceiling (${ceiling.inMilliseconds}ms, reduced '
              'pair, 2 counted legs) + 1500ms + one frame = '
              '${dueBy.inMilliseconds}ms after the turn state',
        );

        await tester.pump(reportBound - (dueBy - _frame));
        final List<String> moves = _movesSince(transport, sentAtArm);
        expect(
          moves,
          hasLength(1),
          reason:
              'C-408 D8 (reduced motion): exactly one move for token 0 '
              '(face $armedFace) must have been sent by ceiling '
              '(${ceiling.inMilliseconds}ms, reduced pair, 2 counted '
              'legs) + 1500ms + one frame = ${dueBy.inMilliseconds}ms '
              'after the turn state. Checked at '
              '${reportBound.inMilliseconds}ms (ceiling + 3000ms); '
              'sentRaw after arming carries ${moves.length} move '
              'frame(s): $moves.',
        );
        if (moves.isNotEmpty) {
          expect(_dataOf(moves.single), <String, Object?>{
            'token': 0,
            'face': armedFace,
          });
          await _completeMoveZeroTravel(
            tester,
            transport,
            seq,
            moves.single,
            token: 0,
            atProgress: toProgress,
          );
        }
      },
    );
  });
}
