// Screen proof for C-471 D3, D4 and D5: the one-time hint control and the
// marker it puts on the board. Written from the contract
// (work/ludo/orders/C-471), not from any implementation. GameScreen is driven
// through a real RoomController on FakeTransport; every room state arrives as
// a decoded wire frame, every `move` is read back off the transport, and the
// cues are read from the recording feedback service the other screen tests
// use.
//
// Shared boards. Seat 0 is mine, seat 1 is Bob. Squares follow RULES.md 1.1,
// (13 * seat + progress) % 52; safe squares are 0, 8, 13, 21, 26, 34, 39, 47.
//
//   A: mine [16, 18, yard, yard], Bob [1, yard x3], my await_move, k 2, value
//      5, legal [0, 1], no queue. Bob's token stands on 14. Token 0 (square
//      16, d = 2) and token 1 (square 18, d = 4) are both threatened. Token
//      0 moves to 21, safe; token 1 to 23, d = 9. Both are escapes (tier 3);
//      the greater current progress wins the tie: token 1 on 18.
//   B: A with my two tokens swapped, [18, 16, yard, yard]: the same two
//      escapes, now token 0 holds 18: hint on token 0.
//   C: mine [30, 5, yard, yard], Bob [48, yard x3], value 4, legal [0, 1].
//      Bob's token stands on (13 + 48) % 52 = 9. Token 1 moves 5 + 4 = 9, not
//      safe, exactly one other token there: a capture (tier 1). Token 0 moves
//      to 34, safe (tier 5). Hint on token 1.
//   Q: mine [16, 30, yard, yard], Bob [1, yard x3], my await_move, k 2, queue
//      [6, 3], value 6, legal_by_face {6: [0, 1, 2, 3], 3: [0, 1]}. Bob's
//      token stands on 14. (6, token 0): token 0 is threatened (d = 2) and
//      at 22 is not (d = 8): tier 3, the only tier 3 candidate. The yard
//      tokens' entries are tier 4, (3, token 0) lands on 19 (d = 5) tier 6,
//      the rest tier 5. Hint: face 6 on token 0. Token 0 is legal for both
//      faces, so a tap on it opens the face picker.
//   Q2: mine [20, 30, yard, yard], Bob [20, yard x3], the same queue. Bob's
//      token stands on 33. (3, token 1): 30 + 3 = 33, not safe, one token:
//      a capture (tier 1), the only one. Hint: face 3 on token 1. Token 1 is
//      legal for 6 and 3, so a tap on it opens the picker.
//   S: A with queue [5, 2] and legal_by_face {5: [0, 1]}: one playable face,
//      a dead 2 beside it. Hint token 1, no face numeral.

import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/roll_tray_harness.dart';

const String _game1 = 'game-0001';
const String _game2 = 'game-0002';

const List<int> _bob = <int>[1, -1, -1, -1];

/// My tokens on board Q (see the header). Every case documented as board Q
/// passes this as `mine:`; the default fixture is board A.
const List<int> _mineQ = <int>[16, 30, -1, -1];

// ---------------------------------------------------------------------------
// Boards.
// ---------------------------------------------------------------------------

Map<String, Object?> _moveTurn({
  int k = 2,
  int value = 5,
  List<int> legal = const <int>[0, 1],
}) => turnJson(seat: 0, phase: 'await_move', k: k, value: value, legal: legal);

Map<String, Object?> _queueTurn({
  int k = 2,
  int value = 6,
  List<int> queue = const <int>[6, 3],
  List<Map<String, Object?>>? byFace,
}) {
  final List<Map<String, Object?>> faces =
      byFace ??
      <Map<String, Object?>>[
        faceLegal(6, const <int>[0, 1, 2, 3]),
        faceLegal(3, const <int>[0, 1]),
      ];
  final List<int> legal = <int>[];
  for (final Map<String, Object?> entry in faces) {
    if (entry['face'] == value) {
      legal.addAll((entry['tokens']! as List<Object?>).cast<int>());
    }
  }
  return turnJson(
    seat: 0,
    phase: 'await_move',
    k: k,
    value: value,
    legal: legal,
    queue: queue,
    legalByFace: faces,
  );
}

Map<String, Object?> _rollTurn({int seat = 0, int k = 2}) =>
    turnJson(seat: seat, phase: 'await_roll', k: k, queue: const <int>[]);

// ---------------------------------------------------------------------------
// Reading the screen.
// ---------------------------------------------------------------------------

/// `absent`, `ready`, `waiting`, `used`, or `broken: ...` when the keys do not
/// say exactly one thing.
String hintState(WidgetTester tester) {
  final bool root = tester.any(find.byKey(hintButtonKey));
  final Map<String, Key> keys = <String, Key>{
    'ready': hintReadyKey,
    'waiting': hintWaitingKey,
    'used': hintUsedKey,
  };
  final List<String> inside = <String>[
    for (final MapEntry<String, Key> e in keys.entries)
      if (tester.any(
        find.descendant(
          of: find.byKey(hintButtonKey),
          matching: find.byKey(e.value),
        ),
      ))
        e.key,
  ];
  final List<String> anywhere = <String>[
    for (final MapEntry<String, Key> e in keys.entries)
      if (tester.any(find.byKey(e.value))) e.key,
  ];
  if (!root) {
    return anywhere.isEmpty
        ? 'absent'
        : 'broken: state keys $anywhere without game-hint-button';
  }
  if (inside.length != 1 || anywhere.length != 1) {
    return 'broken: game-hint-button holds $inside, tree has $anywhere';
  }
  return inside.single;
}

/// Tokens of seat 0 that carry a `board-hint-<t>` marker.
List<int> markedTokens(WidgetTester tester) => <int>[
  for (int t = 0; t < 4; t++)
    if (tester.any(find.byKey(boardHintKey(t)))) t,
];

/// Faces that carry a `board-hint-face-<f>` chip.
List<int> markedFaces(WidgetTester tester) => <int>[
  for (int f = 1; f <= 6; f++)
    if (tester.any(find.byKey(boardHintFaceKey(f)))) f,
];

/// Faces whose picker option sits inside a `board-face-picker-hinted-<f>`.
List<int> hintedPickerFaces(WidgetTester tester) => <int>[
  for (int f = 1; f <= 6; f++)
    if (tester.any(find.byKey(facePickerHintedKey(f)))) f,
];

/// Vertical top of the marker root and of every box under it, in global
/// space, so a bob anywhere in the marker's subtree shows as a change.
List<double> markerTops(WidgetTester tester, int token) {
  final Finder root = find.byKey(boardHintKey(token));
  final List<double> tops = <double>[tester.getTopLeft(root).dy];
  final Iterable<Element> below = find
      .descendant(
        of: root,
        matching: find.byWidgetPredicate((Widget widget) => true),
      )
      .evaluate();
  for (final Element element in below) {
    final RenderObject? render = element.renderObject;
    if (render is RenderBox && render.hasSize && render.attached) {
      tops.add(render.localToGlobal(Offset.zero).dy);
    }
  }
  return tops;
}

/// True when a hit test at the centre of the marker lists the marker's own
/// render object, or one below it, as a target.
bool markerIsHit(WidgetTester tester, int token) {
  final Element root = find.byKey(boardHintKey(token)).evaluate().single;
  final RenderObject? rootRender = root.renderObject;
  final Offset at = tester.getCenter(find.byKey(boardHintKey(token)));
  final HitTestResult result = HitTestResult();
  tester.binding.hitTestInView(result, at, tester.view.viewId);
  for (final HitTestEntry entry in result.path) {
    final HitTestTarget target = entry.target;
    if (target is RenderObject) {
      RenderObject? walk = target;
      while (walk != null) {
        if (identical(walk, rootRender)) {
          return true;
        }
        walk = walk.parent;
      }
    }
  }
  return false;
}

Future<String?> storedHintGame(WidgetTester tester) async {
  return tester.runAsync<String?>(() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(hintUsedPrefsKey);
  });
}

/// Lets the screen's storage read and write finish, then a few frames. The
/// legal rings and the countdown animate for ever, so nothing here settles.
Future<void> flush(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> settleFrames(WidgetTester tester) async {
  for (int i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

String _describe(RollTrayDrive drive, Map<String, Object> stored) {
  final RoomSnapshot? room = drive.controller.room;
  if (room == null) {
    return 'no room';
  }
  final TurnState? turn = room.turn;
  final SeatState? me = room.seats
      .where((SeatState s) => s.seat == 0)
      .firstOrNull;
  final String turnText = turn == null
      ? 'no turn'
      : 'turn seat ${turn.seat} ${turn.phase.name} k ${turn.k} value '
            '${turn.value} queue ${turn.queue} legal ${turn.legal} '
            'legal_by_face ${turn.legalByFace == null ? 'absent' : '{${turn.legalByFace!.map((FaceLegal f) => '${f.face}: ${f.tokens}').join(', ')}}'}';
  return 'game_id ${room.gameId}, room ${room.state.name}, my seat '
      '${drive.controller.seat}, mine ${me?.tokens}, $turnText, stored prefs '
      '$stored';
}

/// One mounted scenario with its marks, so a failure line is enough to
/// rebuild the case.
class HintCase {
  HintCase(this.tester, this.drive, this.scenario, this.stored)
    : fixture = _describe(drive, stored),
      _cuesFrom = drive.feedback.recorded.length,
      _sentFrom = drive.transport.sentRaw.length;

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;
  final Map<String, Object> stored;
  final String fixture;
  int _cuesFrom;
  int _sentFrom;

  void remark() {
    _cuesFrom = drive.feedback.recorded.length;
    _sentFrom = drive.transport.sentRaw.length;
  }

  List<FeedbackCue> get cues =>
      drive.feedback.recorded.skip(_cuesFrom).toList();

  int get framesSent => drive.transport.sentRaw.length - _sentFrom;

  List<Map<String, Object?>> get moves =>
      movesSince(drive.transport, _sentFrom);

  String get state => hintState(tester);

  String why(String expected) =>
      '$scenario: expected $expected; got hint state $state, markers '
      '${markedTokens(tester)}, face chips ${markedFaces(tester)}, cues '
      '$cues, frames sent $framesSent. Reproduce with: $fixture';

  void expectState(String expected, [String? when]) {
    expect(
      state,
      expected,
      reason: why('hint state $expected${when == null ? '' : ' $when'}'),
    );
  }

  void expectNoMarker([String? when]) {
    expect(
      markedTokens(tester),
      isEmpty,
      reason: why('no board-hint-* marker${when == null ? '' : ' $when'}'),
    );
    expect(
      markedFaces(tester),
      isEmpty,
      reason: why('no board-hint-face-* chip${when == null ? '' : ' $when'}'),
    );
  }

  void expectMarker(int token, [String? when]) {
    expect(markedTokens(tester), <int>[
      token,
    ], reason: why('exactly board-hint-$token${when == null ? '' : ' $when'}'));
  }

  Future<void> tapControl() async {
    await tester.tap(find.byKey(hintButtonKey), warnIfMissed: false);
    await tester.pump();
    await flush(tester);
    await settleFrames(tester);
  }

  Future<void> tapToken(int token) async {
    await tester.tap(find.byKey(tokenHitKey(0, token)), warnIfMissed: false);
    await tester.pump();
    await settleFrames(tester);
  }

  Future<void> pushRoom({
    required Map<String, Object?>? turn,
    String? gameId = _game1,
    List<int> mine = const <int>[16, 18, -1, -1],
    String state = 'PLAYING',
    int? winner,
  }) async {
    await drive.push(
      tester,
      'room',
      roomData(
        seats: twoSeats(mine: mine, other: _bob),
        turn: turn,
        gameId: gameId,
        state: state,
        winner: winner,
      ),
    );
    await flush(tester);
    await settleFrames(tester);
  }
}

typedef HintBody = Future<void> Function(HintCase c);

/// Registers one screen case. [turn] defaults to board A.
void hintTest(
  String name,
  HintBody body, {
  Map<String, Object?>? turn,
  List<int> mine = const <int>[16, 18, -1, -1],
  List<int> other = _bob,
  String? gameId = _game1,
  Map<String, Object> stored = const <String, Object>{},
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool disableAnimations = false,
  Size? size,
  String roomState = 'PLAYING',
  int? winner,
  bool seated = true,
  bool semantics = false,
}) {
  testWidgets(name, (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{...stored});
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    final SemanticsHandle? handle = semantics ? tester.ensureSemantics() : null;
    final RollTrayDrive drive = await connectPlaying(
      tester,
      turn: roomState == 'LOBBY' ? null : (turn ?? _moveTurn()),
      seats: twoSeats(mine: mine, other: other),
      gameId: gameId,
      state: roomState,
      winner: winner,
      sendSeatAssigned: seated,
    );
    await mountGame(
      tester,
      drive,
      locale: locale,
      textScale: textScale,
      disableAnimations: disableAnimations,
    );
    await flush(tester);
    final HintCase c = HintCase(tester, drive, name, stored);
    try {
      await body(c);
    } finally {
      handle?.dispose();
      await releaseGame(tester, drive);
    }
  });
}

SemanticsNode? _labelled(WidgetTester tester, String label) {
  final List<SemanticsNode> nodes = find.semantics
      .byPredicate((SemanticsNode node) => node.label == label)
      .evaluate()
      .toList();
  return nodes.isEmpty ? null : nodes.first;
}

String _hintishLabels(WidgetTester tester) {
  final List<String> labels = find.semantics
      .byPredicate(
        (SemanticsNode node) =>
            node.label.toLowerCase().contains('hint') ||
            node.label.contains('تلميح') ||
            node.label.contains('التلميح'),
      )
      .evaluate()
      .map((SemanticsNode node) => node.label)
      .toList();
  return labels.toString();
}

void main() {
  // =========================================================================
  // D3: when the control shows, and in which state.
  // =========================================================================
  group('D3 states', () {
    // Catches: a control that is ready out of turn or shows nothing.
    hintTest('waiting before my turn (Bob is to roll)', (HintCase c) async {
      c.expectState('waiting', 'on Bob\'s await_roll');
    }, turn: _rollTurn(seat: 1));

    hintTest('waiting during my own await-roll', (HintCase c) async {
      c.expectState('waiting', 'on my await_roll');
    }, turn: _rollTurn());

    // Catches: a hint offered where no board has been shown to choose from.
    hintTest('ready in my await-move with two different choices (board A)', (
      HintCase c,
    ) async {
      c.expectState('ready');
    });

    hintTest(
      'ready with a roll queue and two faces (board Q)',
      (HintCase c) async {
        c.expectState('ready');
      },
      turn: _queueTurn(),
      mine: _mineQ,
    );

    // Catches: ready spent on a turn with nothing to recommend (D1).
    hintTest(
      'waiting in my await-move with one choice (a single legal token)',
      (HintCase c) async {
        c.expectState('waiting', 'with legal [0] only');
      },
      turn: _moveTurn(legal: const <int>[0]),
    );

    hintTest(
      'waiting with two tokens stacked on one square (same choice)',
      (HintCase c) async {
        c.expectState('waiting', 'two tokens on progress 20, both legal for 3');
      },
      turn: _moveTurn(value: 3),
      mine: const <int>[20, 20, -1, -1],
    );

    hintTest(
      'waiting with two yard tokens legal on a 6 and nothing else',
      (HintCase c) async {
        c.expectState('waiting', 'two yard tokens, one choice under D1');
      },
      turn: _moveTurn(value: 6),
      mine: const <int>[-1, -1, 57, 57],
    );

    hintTest('absent in the lobby', (HintCase c) async {
      c.expectState('absent', 'while room.state is LOBBY');
    }, roomState: 'LOBBY');

    hintTest(
      'absent on the end card',
      (HintCase c) async {
        c.expectState('absent', 'while room.state is FINISHED');
      },
      roomState: 'FINISHED',
      winner: 1,
      turn: turnJson(seat: 0, phase: 'finished', k: 2),
    );

    hintTest('absent when I hold no seat', (HintCase c) async {
      expect(
        c.drive.controller.seat,
        isNull,
        reason: 'fixture is broken: no seat_assigned was sent',
      );
      c.expectState('absent', 'with no seat of mine');
    }, seated: false);

    // Catches: the state keys leaking outside the root, or two at once.
    hintTest('exactly one state key sits inside game-hint-button', (
      HintCase c,
    ) async {
      expect(
        find.byKey(hintButtonKey),
        findsOneWidget,
        reason: c.why('one game-hint-button'),
      );
      c.expectState('ready');
    });
  });

  // =========================================================================
  // D3: tap on ready.
  // =========================================================================
  group('D3 tap on ready', () {
    final Map<String, (Map<String, Object?>, List<int>, List<int>, int)>
    boards = <String, (Map<String, Object?>, List<int>, List<int>, int)>{
      'A': (_moveTurn(), const <int>[16, 18, -1, -1], _bob, 1),
      'B': (_moveTurn(), const <int>[18, 16, -1, -1], _bob, 0),
      'C': (
        _moveTurn(value: 4),
        const <int>[30, 5, -1, -1],
        const <int>[48, -1, -1, -1],
        1,
      ),
    };
    for (final MapEntry<
          String,
          (Map<String, Object?>, List<int>, List<int>, int)
        >
        entry
        in boards.entries) {
      // Catches: a hint that is hard-wired to one token, or that reads the
      // lowest legal index instead of the heuristic.
      hintTest(
        'board ${entry.key}: the marker lands on the token D2 picks, the '
        'control turns used, the cue is tap, the game id is stored',
        (HintCase c) async {
          c.expectNoMarker('before the tap');
          await c.tapControl();
          c.expectMarker(entry.value.$4, 'after the tap');
          c.expectState('used', 'after the tap');
          expect(c.cues, <FeedbackCue>[
            FeedbackCue.tap,
          ], reason: c.why('exactly one cue, FeedbackCue.tap'));
          expect(
            c.framesSent,
            0,
            reason: c.why('no frame sent: the hint is client-only'),
          );
          expect(
            await storedHintGame(c.tester),
            _game1,
            reason: c.why('session.hintUsedGame holds the snapshot game_id'),
          );
          expect(
            markedFaces(c.tester),
            isEmpty,
            reason: c.why('no face chip without a roll queue'),
          );
        },
        turn: entry.value.$1,
        mine: entry.value.$2,
        other: entry.value.$3,
      );
    }

    // Catches: a hint that only works in English.
    hintTest('in Arabic the tap behaves the same (board A)', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.expectMarker(1, 'after the tap');
      c.expectState('used');
      expect(c.cues, <FeedbackCue>[
        FeedbackCue.tap,
      ], reason: c.why('exactly one cue, FeedbackCue.tap'));
    }, locale: const Locale('ar'));

    // Catches: two taps in one frame spending twice (D5: the screen marks it
    // used before the write completes). The spend is the tap cue.
    hintTest('two taps in the same frame spend the hint once', (
      HintCase c,
    ) async {
      await c.tester.tap(find.byKey(hintButtonKey), warnIfMissed: false);
      await c.tester.tap(find.byKey(hintButtonKey), warnIfMissed: false);
      await c.tester.pump();
      await flush(c.tester);
      expect(
        c.cues.where((FeedbackCue cue) => cue == FeedbackCue.tap).length,
        1,
        reason: c.why('one tap cue for two taps in one frame'),
      );
      c.expectMarker(1);
      expect(
        await storedHintGame(c.tester),
        _game1,
        reason: c.why('the game id stored once'),
      );
    });

    // Catches: a marker that eats the tap meant for what is under it (D4:
    // IgnorePointer).
    hintTest('the marker is ignored by pointer hit tests', (HintCase c) async {
      await c.tapControl();
      c.expectMarker(1);
      expect(
        markerIsHit(c.tester, 1),
        isFalse,
        reason: c.why(
          'a hit test at the marker\'s centre must not list the marker',
        ),
      );
    });

    // Catches: the legal ring dropped from the hinted token (D4: the ring
    // stays as it is).
    hintTest('the hinted token keeps its legal ring', (HintCase c) async {
      await c.tapControl();
      expect(ringedTokens(c.tester), <int>[
        0,
        1,
      ], reason: c.why('rings on tokens 0 and 1 after the hint is shown'));
    });
  });

  // =========================================================================
  // D3: tap on waiting and on used.
  // =========================================================================
  group('D3 tap on waiting and used', () {
    final Map<String, Map<String, Object?>> waitingTurns =
        <String, Map<String, Object?>>{
          'Bob\'s await-roll': _rollTurn(seat: 1),
          'my await-roll': _rollTurn(),
          'one legal token': _moveTurn(legal: const <int>[0]),
        };
    for (final MapEntry<String, Map<String, Object?>> entry
        in waitingTurns.entries) {
      // Catches: a waiting control that spends the hint, stores the game, or
      // stays silent.
      hintTest('tap on waiting (${entry.key}): invalid_tap, nothing stored', (
        HintCase c,
      ) async {
        c.expectState('waiting');
        await c.tapControl();
        c.expectState('waiting', 'after the tap: nothing was spent');
        expect(c.cues, <FeedbackCue>[
          FeedbackCue.invalidTap,
        ], reason: c.why('exactly one cue, FeedbackCue.invalidTap'));
        c.expectNoMarker('after a tap on waiting');
        expect(
          await storedHintGame(c.tester),
          isNull,
          reason: c.why('nothing stored'),
        );
        expect(
          c.framesSent,
          0,
          reason: c.why('no frame sent for a refused tap'),
        );
      }, turn: entry.value);
    }

    // Catches: a used control that can be spent again, e.g. after a restart.
    hintTest('tap on used after a relaunch: invalid_tap, no marker, store '
        'unchanged', (HintCase c) async {
      c.expectState('used', 'with session.hintUsedGame equal to the game id');
      await c.tapControl();
      c.expectState('used', 'after the tap');
      expect(c.cues, <FeedbackCue>[
        FeedbackCue.invalidTap,
      ], reason: c.why('exactly one cue, FeedbackCue.invalidTap'));
      c.expectNoMarker('after a tap on used');
      expect(
        await storedHintGame(c.tester),
        _game1,
        reason: c.why('the stored id is unchanged'),
      );
    }, stored: <String, Object>{hintUsedPrefsKey: _game1});

    // Catches: a second tap in the same game that plays the tap cue again or
    // shows a second marker.
    hintTest('second tap after use: invalid_tap, the one marker stays', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.remark();
      await c.tapControl();
      c.expectState('used', 'after the second tap');
      expect(c.cues, <FeedbackCue>[
        FeedbackCue.invalidTap,
      ], reason: c.why('the second tap plays invalid_tap and nothing else'));
      c.expectMarker(1, 'still the one marker');
      expect(
        await storedHintGame(c.tester),
        _game1,
        reason: c.why('the stored id is unchanged'),
      );
    });
  });

  // =========================================================================
  // D4: how long the marker lives.
  // =========================================================================
  group('D4 lifetime', () {
    for (final (int token, String name) in <(int, String)>[
      (1, 'the hinted token'),
      (0, 'a different token'),
    ]) {
      // Catches: a marker that outlives my move, or that clears only when
      // the hinted token itself is the one played.
      hintTest('the marker clears when I tap $name (a move is sent)', (
        HintCase c,
      ) async {
        await c.tapControl();
        c.expectMarker(1, 'after the hint');
        c.remark();
        await c.tapToken(token);
        expect(
          c.moves,
          hasLength(1),
          reason: c.why('one move frame for the tap on token $token'),
        );
        expect(c.moves.single['token'], token, reason: c.why('token $token'));
        c.expectNoMarker('after my move was sent');
        c.expectState('used', 'after my move was sent');
      });
    }

    // Catches: a marker that follows the player into the opponent's turn,
    // and a used control that reverts to ready on a later turn of mine.
    hintTest('the marker clears when the turn passes to Bob; on my next turn '
        'the control is used and no marker shows', (HintCase c) async {
      await c.tapControl();
      c.expectMarker(1, 'after the hint');
      await c.pushRoom(turn: _rollTurn(seat: 1, k: 3));
      c.expectNoMarker('once the turn is Bob\'s');
      c.expectState('used', 'on Bob\'s turn');
      await c.pushRoom(turn: _moveTurn(k: 4));
      c.expectState('used', 'on a later turn of mine with choices');
      c.expectNoMarker('on a later turn of mine');
    });

    // Catches: a marker keyed on the seat alone, not on k.
    hintTest('the marker clears when the turn k changes on my own await-move', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.expectMarker(1, 'after the hint');
      await c.pushRoom(turn: _moveTurn(k: 3));
      c.expectNoMarker('after k 2 -> 3 with the same seat and phase');
      c.expectState('used');
    });

    // Catches: a resync that is not my await-move leaving the marker up.
    hintTest('the marker clears on a resync whose turn is not my await-move', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.expectMarker(1, 'after the hint');
      await c.pushRoom(turn: _rollTurn(k: 2));
      c.expectNoMarker('after a snapshot with my await_roll at the same k');
      c.expectState('used');
    });

    // Catches: a marker dropped by an unrelated snapshot, which would let a
    // routine resync swallow the one hint.
    hintTest('a resync that repeats my await-move keeps the marker', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.expectMarker(1, 'after the hint');
      await c.pushRoom(turn: _moveTurn(k: 2));
      c.expectMarker(1, 'after an identical snapshot (same seat, phase, k)');
      c.expectState('used');
    });

    // Catches: a marker left over the end card.
    hintTest('the marker and the control are gone when the game ends', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.expectMarker(1, 'after the hint');
      await c.pushRoom(
        turn: turnJson(seat: 0, phase: 'finished', k: 2),
        state: 'FINISHED',
        winner: 1,
      );
      c.expectNoMarker('on the end card');
      c.expectState('absent', 'on the end card');
    });
  });

  // =========================================================================
  // D4: the roll queue.
  // =========================================================================
  group('D4 queue', () {
    // Catches: a hint that names only a token, not the face, under a queue.
    hintTest(
      'queue: the marker carries the face chip (board Q: 6 on token 0)',
      (HintCase c) async {
        await c.tapControl();
        c.expectMarker(0, 'after the hint');
        expect(markedFaces(c.tester), <int>[
          6,
        ], reason: c.why('board-hint-face-6 and no other chip'));
      },
      turn: _queueTurn(),
      mine: _mineQ,
    );

    hintTest(
      'queue: the chip names the face, not the first queued one '
      '(board Q2: 3 on token 1)',
      (HintCase c) async {
        await c.tapControl();
        c.expectMarker(1, 'after the hint');
        expect(markedFaces(c.tester), <int>[
          3,
        ], reason: c.why('board-hint-face-3 and no other chip'));
      },
      turn: _queueTurn(),
      mine: const <int>[20, 30, -1, -1],
      other: const <int>[20, -1, -1, -1],
    );

    // Catches: the picker marking both faces, or neither, or the wrong one.
    hintTest(
      'queue: the picker on the hinted token marks the hinted face only '
      '(board Q: 6)',
      (HintCase c) async {
        await c.tapControl();
        await c.tapToken(0);
        expect(
          c.tester.any(find.byKey(facePickerKey)),
          isTrue,
          reason: c.why('the face picker open on token 0'),
        );
        expect(hintedPickerFaces(c.tester), <int>[
          6,
        ], reason: c.why('board-face-picker-hinted-6 and no other'));
        expect(
          find.descendant(
            of: find.byKey(facePickerHintedKey(6)),
            matching: find.byKey(facePickerOptionKey(6)),
          ),
          findsOneWidget,
          reason: c.why('the hinted wrapper holds board-face-picker-option-6'),
        );
        expect(pickerOptionFaces(c.tester)..sort(), <int>[
          3,
          6,
        ], reason: c.why('the picker keeps both options'));
        c.expectMarker(0, 'while the picker is open');
      },
      turn: _queueTurn(),
      mine: _mineQ,
    );

    hintTest(
      'queue: the picker marks face 3 when 3 is hinted (board Q2)',
      (HintCase c) async {
        await c.tapControl();
        await c.tapToken(1);
        expect(
          c.tester.any(find.byKey(facePickerKey)),
          isTrue,
          reason: c.why('the face picker open on token 1'),
        );
        expect(hintedPickerFaces(c.tester), <int>[
          3,
        ], reason: c.why('board-face-picker-hinted-3 and no other'));
      },
      turn: _queueTurn(),
      mine: const <int>[20, 30, -1, -1],
      other: const <int>[20, -1, -1, -1],
    );

    // Catches: a hint that changes how the picker answers a pick, and a
    // marker that survives a move made with the other face.
    hintTest(
      'queue: picking the other face sends it and clears the marker',
      (HintCase c) async {
        await c.tapControl();
        await c.tapToken(0);
        c.remark();
        await c.tester.tap(find.byKey(facePickerOptionKey(3)));
        await c.tester.pump();
        await settleFrames(c.tester);
        expect(c.moves, hasLength(1), reason: c.why('one move frame'));
        expect(c.moves.single['token'], 0, reason: c.why('token 0'));
        expect(
          c.moves.single['face'],
          3,
          reason: c.why('face 3, not the hint'),
        );
        c.expectNoMarker('after the other face was played');
        c.expectState('used');
      },
      turn: _queueTurn(),
      mine: _mineQ,
    );

    // Catches: a numeral drawn when only one face can be played, even with a
    // dead face beside it in the queue.
    hintTest(
      'one playable face (queue [5, 2], 2 dead): no face chip',
      (HintCase c) async {
        c.expectState('ready');
        await c.tapControl();
        c.expectMarker(1, 'after the hint');
        expect(
          markedFaces(c.tester),
          isEmpty,
          reason: c.why('no board-hint-face-* with one playable face'),
        );
      },
      turn: _queueTurn(
        value: 5,
        queue: const <int>[5, 2],
        byFace: <Map<String, Object?>>[
          faceLegal(5, const <int>[0, 1]),
        ],
      ),
    );

    hintTest('no queue at all: no face chip', (HintCase c) async {
      await c.tapControl();
      c.expectMarker(1, 'after the hint');
      expect(
        markedFaces(c.tester),
        isEmpty,
        reason: c.why('no board-hint-face-* without a roll queue'),
      );
    });
  });

  // =========================================================================
  // D5: used belongs to the game and survives a kill.
  // =========================================================================
  group('D5 resume', () {
    // Catches: a fresh mount that forgets the hint was spent.
    hintTest('a fresh mount with the stored id equal to the game id is used', (
      HintCase c,
    ) async {
      c.expectState('used');
      c.expectNoMarker('on a fresh mount');
    }, stored: <String, Object>{hintUsedPrefsKey: _game1});

    // Catches: a stored id that blocks every later game.
    hintTest('a fresh mount with a different stored id is ready', (
      HintCase c,
    ) async {
      c.expectState('ready');
    }, stored: <String, Object>{hintUsedPrefsKey: _game2});

    hintTest(
      'a fresh mount with a different stored id and no choices is '
      'waiting',
      (HintCase c) async {
        c.expectState('waiting');
      },
      stored: <String, Object>{hintUsedPrefsKey: _game2},
      turn: _rollTurn(),
    );

    // Catches: the hint binding to the screen, not to the game.
    hintTest('a rematch (a new game_id) after use returns it to waiting, then '
        'ready, and it can be spent again', (HintCase c) async {
      await c.tapControl();
      c.expectState('used', 'after the first spend');
      expect(
        await storedHintGame(c.tester),
        _game1,
        reason: c.why('game 1 stored'),
      );
      await c.pushRoom(turn: _rollTurn(k: 1), gameId: _game2);
      c.expectState('waiting', 'in game 2 on my await_roll');
      c.expectNoMarker('in game 2');
      await c.pushRoom(turn: _moveTurn(k: 2), gameId: _game2);
      c.expectState('ready', 'in game 2 on my await_move with choices');
      c.remark();
      await c.tapControl();
      c.expectState('used', 'after the second spend');
      c.expectMarker(1, 'after the second spend');
      expect(c.cues, <FeedbackCue>[
        FeedbackCue.tap,
      ], reason: c.why('the tap cue of the second spend'));
      expect(
        await storedHintGame(c.tester),
        _game2,
        reason: c.why('game 2 stored over game 1'),
      );
    });

    // Catches: a hint spent against no game, which a later game id could not
    // tell apart from a fresh one.
    hintTest('a PLAYING snapshot with no game_id keeps it waiting and a tap '
        'spends nothing', (HintCase c) async {
      c.expectState('waiting', 'with game_id null and two choices');
      await c.tapControl();
      c.expectState('waiting', 'after the tap');
      expect(c.cues, <FeedbackCue>[
        FeedbackCue.invalidTap,
      ], reason: c.why('exactly one cue, FeedbackCue.invalidTap'));
      c.expectNoMarker('with no game id');
      expect(
        await storedHintGame(c.tester),
        isNull,
        reason: c.why('nothing stored without a game id'),
      );
    }, gameId: null);

    hintTest('the game id arriving after a null one makes it ready', (
      HintCase c,
    ) async {
      c.expectState('waiting', 'before any game id');
      await c.pushRoom(turn: _moveTurn(k: 2), gameId: _game1);
      c.expectState('ready', 'once the snapshot carries a game id');
    }, gameId: null);
  });

  // =========================================================================
  // D3: layout. The control is an overlay on the die's row.
  // =========================================================================
  group('D3 layout', () {
    final Map<String, Size> sizes = <String, Size>{
      '390x844': const Size(390, 844),
      '360x800': const Size(360, 800),
    };
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final bool tray in const <bool>[false, true]) {
        for (final MapEntry<String, Size> size in sizes.entries) {
          final String code = locale.languageCode;
          // Catches: the control entering the centred Row and pulling the die
          // (or, with a tray, the die + gap + tray group) off the board's
          // axis. C-471 A2: without a tray the die itself is centred; with a
          // tray the row centres the union of the die's and the tray's rects.
          hintTest(
            tray
                ? 'die and tray union centre equals board centre within 1 px: '
                      '$code, with a tray, ${size.key}'
                : 'die centre equals board centre within 1 px: $code, '
                      'without a tray, ${size.key}',
            (HintCase c) async {
              c.expectState('ready');
              expect(
                c.tester.any(find.byKey(rollTrayKey)),
                tray,
                reason: c.why(
                  'fixture: the roll tray ${tray ? 'present' : 'absent'}',
                ),
              );
              final double board = c.tester.getCenter(find.byKey(boardKey)).dx;
              if (tray) {
                final Rect union = c.tester
                    .getRect(find.byKey(bigDieKey))
                    .expandToInclude(c.tester.getRect(find.byKey(rollTrayKey)));
                expect(
                  (union.center.dx - board).abs(),
                  lessThanOrEqualTo(1.0),
                  reason: c.why(
                    'centre x ${union.center.dx} of the union $union of '
                    'game-die and game-roll-tray within 1 px of '
                    'game-screen-board centre x $board (${size.key}, $code)',
                  ),
                );
              } else {
                final double die = c.tester.getCenter(find.byKey(bigDieKey)).dx;
                expect(
                  (die - board).abs(),
                  lessThanOrEqualTo(1.0),
                  reason: c.why(
                    'game-die centre x $die within 1 px of game-screen-board '
                    'centre x $board (${size.key}, $code)',
                  ),
                );
              }
            },
            turn: tray ? _queueTurn(queue: const <int>[6, 3, 2]) : _moveTurn(),
            locale: locale,
            size: size.value,
          );
        }
      }
    }

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final bool tray in const <bool>[false, true]) {
        final String code = locale.languageCode;
        // Catches: a control that lands on the die or the tray at the
        // smallest phone with the largest text, that is smaller than 48 dp,
        // on the wrong side for the reading direction, or off the die's
        // middle line.
        hintTest(
          'control clear of die and tray, 48 dp, on the leading side: $code, '
          '${tray ? 'with' : 'without'} a tray, 360x800 at text scale 2.0',
          (HintCase c) async {
            c.expectState('ready');
            final Rect control = c.tester.getRect(find.byKey(hintButtonKey));
            final Rect die = c.tester.getRect(find.byKey(bigDieKey));
            expect(
              control.width >= 48 - 1e-3 && control.height >= 48 - 1e-3,
              isTrue,
              reason: c.why(
                'game-hint-button hit size ${control.width}x${control.height} '
                'at least 48x48',
              ),
            );
            expect(
              control.overlaps(die),
              isFalse,
              reason: c.why('control $control must not overlap game-die $die'),
            );
            if (tray) {
              final Rect trayRect = c.tester.getRect(find.byKey(rollTrayKey));
              expect(
                control.overlaps(trayRect),
                isFalse,
                reason: c.why(
                  'control $control must not overlap game-roll-tray '
                  '$trayRect',
                ),
              );
            } else {
              expect(
                c.tester.any(find.byKey(rollTrayKey)),
                isFalse,
                reason: c.why('fixture: no tray in this case'),
              );
            }
            if (code == 'en') {
              expect(
                control.center.dx,
                lessThan(die.center.dx),
                reason: c.why('en: control $control left of die $die'),
              );
            } else {
              expect(
                control.center.dx,
                greaterThan(die.center.dx),
                reason: c.why('ar: control $control right of die $die'),
              );
            }
            expect(
              (control.center.dy - die.center.dy).abs(),
              lessThanOrEqualTo(1.0),
              reason: c.why(
                'control centre y ${control.center.dy} within 1 px of the '
                'die centre y ${die.center.dy}',
              ),
            );
          },
          turn: tray ? _queueTurn(queue: const <int>[6, 3, 2]) : _moveTurn(),
          locale: locale,
          size: const Size(360, 800),
          textScale: 2.0,
        );
      }
    }

    // Catches: a hit area of only the 40 dp disc.
    hintTest('the whole 48 dp target takes the tap, not only the disc', (
      HintCase c,
    ) async {
      final Rect control = c.tester.getRect(find.byKey(hintButtonKey));
      expect(
        control.width >= 48 - 1e-3 && control.height >= 48 - 1e-3,
        isTrue,
        reason: c.why('hit size ${control.width}x${control.height} >= 48x48'),
      );
      final Offset edge = control.center + Offset(control.width / 2 - 1, 0);
      await c.tester.tapAt(edge);
      await c.tester.pump();
      await flush(c.tester);
      c.expectState('used', 'after a tap 1 px inside the target\'s edge');
    }, size: const Size(390, 844));

    // Catches: the die or the tray moving when the hint is spent or the
    // marker appears (the control is an overlay; the rects do not change).
    for (final bool tray in const <bool>[false, true]) {
      hintTest(
        'die and tray keep their rects through the hint (${tray ? 'with' : 'without'} a tray)',
        (HintCase c) async {
          final Rect dieBefore = c.tester.getRect(find.byKey(bigDieKey));
          final Rect? trayBefore = tray
              ? c.tester.getRect(find.byKey(rollTrayKey))
              : null;
          await c.tapControl();
          c.expectState('used');
          expect(
            c.tester.getRect(find.byKey(bigDieKey)),
            dieBefore,
            reason: c.why('game-die rect unchanged by the hint'),
          );
          if (trayBefore != null) {
            expect(
              c.tester.getRect(find.byKey(rollTrayKey)),
              trayBefore,
              reason: c.why('game-roll-tray rect unchanged by the hint'),
            );
          }
        },
        turn: tray ? _queueTurn(queue: const <int>[6, 3, 2]) : _moveTurn(),
        size: const Size(390, 844),
      );
    }

    hintTest('the control is there in every state at the same place', (
      HintCase c,
    ) async {
      final Rect ready = c.tester.getRect(find.byKey(hintButtonKey));
      await c.tapControl();
      c.expectState('used');
      expect(
        c.tester.getRect(find.byKey(hintButtonKey)),
        ready,
        reason: c.why('control rect the same in ready and used'),
      );
    }, size: const Size(390, 844));
  });

  // =========================================================================
  // Semantics.
  // =========================================================================
  group('semantics', () {
    final Map<String, Map<String, String>> labels =
        <String, Map<String, String>>{
          'en': <String, String>{
            'ready': 'Hint: show a good move (once per game)',
            'waiting': 'Hint, once per game, on your move',
            'used': 'Hint used this game',
          },
          'ar': <String, String>{
            'ready': 'تلميح: اقترح نقلة جيدة (مرة وحدة باللعبة)',
            'waiting': 'تلميح، مرة وحدة باللعبة، وقت دورك',
            'used': 'استعملت التلميح بهاللعبة',
          },
        };
    for (final MapEntry<String, Map<String, String>> lang in labels.entries) {
      final Locale locale = Locale(lang.key);
      final Map<String, (Map<String, Object?>, Map<String, Object>)> scenes =
          <String, (Map<String, Object?>, Map<String, Object>)>{
            'ready': (_moveTurn(), const <String, Object>{}),
            'waiting': (_rollTurn(seat: 1), const <String, Object>{}),
            'used': (_moveTurn(), <String, Object>{hintUsedPrefsKey: _game1}),
          };
      for (final MapEntry<String, (Map<String, Object?>, Map<String, Object>)>
          scene
          in scenes.entries) {
        final String expected = lang.value[scene.key]!;
        // Catches: a missing, wrong or untranslated label, a control that is
        // not a button node, and a disabled state that still reports enabled
        // (or a ready one that does not).
        hintTest(
          '${lang.key} ${scene.key}: label "$expected", button, '
          '${scene.key == 'ready' ? 'enabled' : 'disabled'}',
          (HintCase c) async {
            c.expectState(scene.key);
            final SemanticsNode? node = _labelled(c.tester, expected);
            expect(
              node,
              isNotNull,
              reason: c.why(
                'a semantics node labelled exactly "$expected"; hint-like '
                'labels present: ${_hintishLabels(c.tester)}',
              ),
            );
            expect(
              node!.flagsCollection.isButton,
              isTrue,
              reason: c.why('the "$expected" node is a button'),
            );
            expect(
              node.flagsCollection.isEnabled,
              scene.key == 'ready' ? Tristate.isTrue : Tristate.isFalse,
              reason: c.why(
                'only ready reports enabled; the ${scene.key} node reports '
                '${node.flagsCollection.isEnabled}',
              ),
            );
            if (scene.key == 'ready') {
              expect(
                node.getSemanticsData().hasAction(SemanticsAction.tap),
                isTrue,
                reason: c.why('the ready node has a tap action'),
              );
            }
          },
          turn: scene.value.$1,
          stored: scene.value.$2,
          locale: locale,
          semantics: true,
        );
      }

      // Catches: a screen-reader route that does not spend the hint like the
      // tap does.
      hintTest(
        '${lang.key}: the ready node\'s tap action spends the hint',
        (HintCase c) async {
          final SemanticsNode? node = _labelled(c.tester, lang.value['ready']!);
          expect(
            node,
            isNotNull,
            reason: c.why('a node labelled "${lang.value['ready']}"'),
          );
          c.tester.semantics.performAction(
            find.semantics.byPredicate(
              (SemanticsNode n) => n.label == lang.value['ready'],
            ),
            SemanticsAction.tap,
          );
          await c.tester.pump();
          await flush(c.tester);
          c.expectState('used', 'after the semantics tap action');
          c.expectMarker(1, 'after the semantics tap action');
        },
        locale: locale,
        semantics: true,
      );
    }

    final Map<String, (String, String)> suffixes = <String, (String, String)>{
      'en': ('suggested move', 'suggested: move 6'),
      'ar': ('النقلة المقترحة', 'المقترح: حرّك 6'),
    };
    for (final MapEntry<String, (String, String)> lang in suffixes.entries) {
      final Locale locale = Locale(lang.key);
      // Catches: a marker that is only paint, with nothing for a screen
      // reader, or a suffix on the wrong token.
      hintTest(
        '${lang.key}: the hinted token\'s node carries hintTokenSuffix and no '
        'other token does',
        (HintCase c) async {
          final AppLocalizations loc = AppLocalizations.of(
            c.tester.element(find.byKey(tokenHitKey(0, 0))),
          );
          for (int t = 0; t < 2; t++) {
            expect(
              c.tester
                  .getSemantics(find.byKey(tokenHitKey(0, t)))
                  .label
                  .contains(lang.value.$1),
              isFalse,
              reason: c.why('token $t has no suffix before the hint'),
            );
          }
          await c.tapControl();
          final String hinted = c.tester
              .getSemantics(find.byKey(tokenHitKey(0, 1)))
              .label;
          final String other = c.tester
              .getSemantics(find.byKey(tokenHitKey(0, 0)))
              .label;
          expect(
            hinted.contains(loc.gameTokenButton(2)),
            isTrue,
            reason: c.why(
              'the hinted token keeps its own label "${loc.gameTokenButton(2)}"; '
              'got "$hinted"',
            ),
          );
          expect(
            hinted.contains(lang.value.$1),
            isTrue,
            reason: c.why(
              'the hinted token\'s label contains "${lang.value.$1}"; got '
              '"$hinted"',
            ),
          );
          expect(
            other.contains(lang.value.$1),
            isFalse,
            reason: c.why('token 0 is not hinted; got "$other"'),
          );
        },
        locale: locale,
        semantics: true,
      );

      hintTest(
        '${lang.key}: under a queue the hinted token\'s node carries '
        'hintTokenFaceSuffix with the face',
        (HintCase c) async {
          await c.tapControl();
          final String hinted = c.tester
              .getSemantics(find.byKey(tokenHitKey(0, 0)))
              .label;
          expect(
            hinted.contains(lang.value.$2),
            isTrue,
            reason: c.why(
              'the hinted token\'s label contains "${lang.value.$2}"; got '
              '"$hinted"',
            ),
          );
        },
        turn: _queueTurn(),
        mine: _mineQ,
        locale: locale,
        semantics: true,
      );
    }
  });

  // =========================================================================
  // Reduced motion and bobbing.
  // =========================================================================
  group('motion', () {
    // Catches: a bob that ignores MediaQuery.disableAnimations.
    hintTest('reduced motion: the marker is present and does not move', (
      HintCase c,
    ) async {
      await c.tapControl();
      c.expectMarker(1, 'under disableAnimations');
      final List<double> first = markerTops(c.tester, 1);
      await c.tester.pump(const Duration(milliseconds: 450));
      final List<double> second = markerTops(c.tester, 1);
      expect(
        second,
        orderedEquals(first),
        reason: c.why(
          'marker box tops $first then $second 450 ms later must be equal',
        ),
      );
      for (int i = 0; i < 9; i++) {
        await c.tester.pump(const Duration(milliseconds: 100));
        expect(
          markerTops(c.tester, 1),
          orderedEquals(first),
          reason: c.why('marker box tops stay $first through a full period'),
        );
      }
    }, disableAnimations: true);

    // Catches: a marker that never bobs. The bob is measured as movement of
    // any box under the keyed root over one full period.
    hintTest('normal motion: the marker bobs', (HintCase c) async {
      await c.tapControl();
      c.expectMarker(1, 'under normal motion');
      final List<List<double>> samples = <List<double>>[
        markerTops(c.tester, 1),
      ];
      for (int i = 0; i < 10; i++) {
        await c.tester.pump(const Duration(milliseconds: 100));
        samples.add(markerTops(c.tester, 1));
      }
      double widest = 0;
      for (final List<double> sample in samples) {
        expect(
          sample.length,
          samples.first.length,
          reason: c.why('the marker subtree keeps its shape while it bobs'),
        );
        for (int i = 0; i < sample.length; i++) {
          final double delta = (sample[i] - samples.first[i]).abs();
          if (delta > widest) {
            widest = delta;
          }
        }
      }
      expect(
        widest,
        greaterThan(1.0),
        reason: c.why(
          'some box under board-hint-1 moves more than 1 px over 1000 ms '
          '(the contract bobs 4 dp, period about 900 ms); widest move '
          '$widest, samples $samples',
        ),
      );
    });
  });
}
