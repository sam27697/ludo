// C-708t: my die shows its face at the tap (docs/PROTOCOL.md section 35 items
// 1, 5, 6 and 7 (e), work/ludo/orders/708-pre-roll-and-kick-client.md "The
// design" and the run 169 additions). Written from the order and the contract
// before the implementation exists.
//
// A real GameScreen over a real RoomController on FakeTransport, driven by
// decoded wire frames shaped as the server sends them (test/support/
// roll_tray_harness.dart). Nothing is mocked but the socket and the feedback
// service, which records every FeedbackCue the screen plays.
//
// What a row reads:
//   - the face on my die: `game-die-face-N` under `game-die`, and
//     `game-die-tumbling` while the throw is in the air (the way
//     test/c653_own_roll_hold_test.dart reads it);
//   - the legal marks: `board-legal-ring-0-<token>`; the no-move mark:
//     `game-die-no-move-mark`;
//   - what was sent: the `t` of every frame on the fake socket, in order;
//   - feedback: the recorded cues, printed as their wire ids.
//
// The tumble minimum is `kThrowTumble` (lib/src/die_cube.dart), the one
// minimum the app already uses for a throw. Time is the test clock only,
// pumped in explicit steps of at most 16 ms (5 ms around a landing); never
// pumpAndSettle. "+N ms" in a failure line counts from the tap under test.
//
// Rows whose subject is the net layer (PreRoll parsing, RoomController.pre,
// RoomController.resync) reach the order's fixed names through `dynamic`, so
// this file compiles on a base that does not have them yet and each such row
// fails with a line naming the missing member instead.
//
// No seed: every row is a fixed list of frames. A failure line names the row,
// the locale, the clock, what was expected, what was observed, every frame
// pushed and every frame sent, which is the whole reproduction. Rerun one row:
//   cd packages/ludo_client && flock /tmp/ludo-suite.lock flutter test \
//     test/c708_pre_roll_test.dart --plain-name '<row name>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/die_cube.dart' show kThrowTumble;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart' show poseOf;
import 'support/roll_tray_harness.dart';

const String _file = 'test/c708_pre_roll_test.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

const int _me = 0;
const int _opp = 1;

/// Two tokens out, two in the yard: a 4 moves token 0 or 1, so no single
/// legal token arms the auto-move.
const List<int> _openTokens = <int>[10, 20, -1, -1];
const List<int> _yard = <int>[-1, -1, -1, -1];

const Key _tumblingKey = Key('game-die-tumbling');
const Key _noAnswerKey = Key('game-die-no-answer');

int get _tumbleMs => kThrowTumble.inMilliseconds;

// --- wire shapes -------------------------------------------------------------

/// Section 35 item 1: the `d` of the `rolled` that would follow, without
/// `seq`, `reveal`, `deadline_ms` and `by`.
Map<String, Object?> _pre({
  int seat = _me,
  required int value,
  required List<int> legal,
  int k = 1,
  required List<int> queue,
  List<Map<String, Object?>>? legalByFace,
  bool? release,
  bool? offer,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'k': k,
  'queue': queue,
  'legal_by_face': ?legalByFace,
  'release': ?release,
  'offer': ?offer,
};

/// A 4 with tokens 0 and 1 legal (section 21.1 shape).
Map<String, Object?> _preCanMove({int seat = _me}) => _pre(
  seat: seat,
  value: 4,
  legal: const <int>[0, 1],
  queue: const <int>[4],
  legalByFace: <Map<String, Object?>>[
    faceLegal(4, const <int>[0, 1]),
  ],
);

/// A 3 with every token in the yard: the roll voids the turn.
Map<String, Object?> _preNoMove() =>
    _pre(value: 3, legal: const <int>[], queue: const <int>[]);

/// The `rolled` broadcast for [pre]: the same fields plus `deadline_ms` and
/// `reveal` (section 35 item 2: field for field equal to the `pre`).
Map<String, Object?> _rolledOf(Map<String, Object?> pre) => <String, Object?>{
  ...pre,
  'deadline_ms': rollTrayDeadlineMs,
  'reveal': rollTrayReveal,
};

/// My snapshot turn in await_roll, with [pre] when given.
Map<String, Object?> _myRollTurn({Map<String, Object?>? pre}) =>
    <String, Object?>{
      ...turnJson(seat: _me, phase: 'await_roll', k: 0, queue: const <int>[]),
      'pre': ?pre,
    };

/// A pushed `turn` frame in await_roll for [seat], with [pre] and [graceMs].
Map<String, Object?> _turnFrame(
  int seat, {
  Map<String, Object?>? pre,
  int? graceMs,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': rollTrayDeadlineMs,
  'queue': const <int>[],
  'grace_ms': ?graceMs,
  'pre': ?pre,
};

int _wireIdSeq = 0;

String _wire(String type, Map<String, Object?> data, {String? re}) {
  _wireIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c708t-pre-${_wireIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

/// A two-seat PLAYING snapshot, seat 0 me ("Sam"), seat 1 "Bob". [ruleset]
/// adds `rules.ruleset` and the section 28 keys the way a 2026-11 room
/// sends them.
Map<String, Object?> _roomJson({
  required Map<String, Object?>? turn,
  required List<int> mine,
  required List<int> theirs,
  String? ruleset,
  int seq = 1,
}) {
  final bool on = ruleset != null;
  Map<String, Object?> seat(int s, String name, List<int> tokens) =>
      <String, Object?>{
        'seat': s,
        'name': name,
        'connected': true,
        'tokens': tokens,
        'client_seed': null,
        'seed_origin': null,
        'drought': ?(on ? 0 : null),
      };
  return <String, Object?>{
    'code': 'K7M2QP',
    'state': 'PLAYING',
    'host_seat': 0,
    'players': 2,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
      'ruleset': ?ruleset,
    },
    'chain_commit': 'a' * 64,
    'chain_index': 0,
    'game_id': null,
    'client_seeds': null,
    'seats': <Map<String, Object?>>[
      seat(_me, 'Sam', mine),
      seat(_opp, 'Bob', theirs),
    ],
    'turn': turn,
    'winner': null,
    'seq': seq,
    'placings': ?(on ? <int>[] : null),
    'retired': ?(on ? <int>[] : null),
  };
}

// --- one mounted table -------------------------------------------------------

class _T {
  _T(this.tester, this.drive, this.name, this.locale, this.mounted);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String name;
  final Locale locale;

  /// What the table was mounted on, for the failure line.
  final String mounted;
  final List<String> pushed = <String>[];

  /// Fake ms pumped since the mount, and the clock at the tap under test.
  int now = 0;
  int? tapAt;

  int get sinceTap => tapAt == null ? -1 : now - tapAt!;

  FakeTransport get transport => drive.transport;
  RoomController get controller => drive.controller;

  // --- what is on screen ---------------------------------------------------

  Finder get _die => find.byKey(bigDieKey);

  List<int> get faces => <int>[
    for (int v = 1; v <= 6; v++)
      if (find
          .descendant(of: _die, matching: find.byKey(bigFaceKey(v)))
          .evaluate()
          .isNotEmpty)
        v,
  ];

  bool get tumbling => find
      .descendant(of: _die, matching: find.byKey(_tumblingKey))
      .evaluate()
      .isNotEmpty;

  List<int> get rings => ringedTokens(tester);

  bool get noMoveMark => find.byKey(noMoveMarkKey).evaluate().isNotEmpty;

  List<String> get sentTypes => sentTypesSince(transport, 0);

  int sent(String type) => sentTypes.where((String t) => t == type).length;

  List<String> get cueIds => <String>[
    for (final FeedbackCue c in drive.feedback.recorded) c.id,
  ];

  int cue(FeedbackCue c) => cueCount(drive.feedback, c);

  String get observed =>
      'die faces $faces, tumbling $tumbling, legal rings $rings, no-move '
      'mark $noMoveMark, cues $cueIds, sent $sentTypes, phase '
      '${controller.phase}, errorCode ${controller.errorCode}';

  String why(String expected) =>
      'C-708t "$name" [${locale.languageCode}] at ${now}ms since the mount, '
      '${tapAt == null ? 'no tap yet' : '+${sinceTap}ms since the tap'}: '
      'expected $expected; observed $observed. Mounted on $mounted. Frames '
      'pushed in order (@ms since the mount): '
      '${pushed.isEmpty ? '<none>' : pushed.join(' -> ')}. Fixed frames, no '
      'seed; rerun: cd packages/ludo_client && flock /tmp/ludo-suite.lock '
      "flutter test $_file --plain-name '$name'";

  // --- driving -------------------------------------------------------------

  Future<void> push(String type, Map<String, Object?> data) async {
    pushed.add('$type ${jsonEncode(data)} @${now}ms');
    await drive.push(tester, type, data);
  }

  /// Pumps [ms] in steps of at most [step], calling [each] after every step.
  Future<void> advance(int ms, {int step = 16, void Function()? each}) async {
    int left = ms;
    while (left > 0) {
      final int d = left < step ? left : step;
      await tester.pump(Duration(milliseconds: d));
      now += d;
      left -= d;
      each?.call();
    }
  }

  /// Pumps until [ms] since the tap.
  Future<void> advanceToSinceTap(
    int ms, {
    int step = 16,
    void Function()? each,
  }) => advance(ms - sinceTap, step: step, each: each);

  /// A tap on my die; returns the `roll` frames it put on the wire before
  /// any time passed.
  Future<int> tapDie({bool mark = true}) async {
    final int before = sent('roll');
    if (mark) {
      tapAt = now;
    }
    pushed.add('<tap game-die @${now}ms>');
    await tester.tap(_die, warnIfMissed: false);
    await tester.pump();
    return sent('roll') - before;
  }

  /// A tap on my token [token]; returns the `move` frames it sent at once.
  Future<int> tapToken(int token) async {
    final int before = movesSince(transport, 0).length;
    pushed.add('<tap board-token-hit-0-$token @${now}ms>');
    await tester.tap(find.byKey(tokenHitKey(_me, token)), warnIfMissed: false);
    await tester.pump();
    return movesSince(transport, 0).length - before;
  }

  /// The id of the last `resume` this client sent.
  String lastResumeId() => requestIdOf(
    transport.sentRaw.lastWhere((String s) => frameType(s) == 'resume'),
  );

  // --- assertions ----------------------------------------------------------

  void expectInAir(String step) {
    expect(
      faces,
      isEmpty,
      reason: why('$step: no face on my die before the tumble minimum'),
    );
    expect(
      tumbling,
      isTrue,
      reason: why('$step: my die tumbling (game-die-tumbling)'),
    );
    expect(
      rings,
      isEmpty,
      reason: why('$step: no legal ring before the die lands'),
    );
    expect(
      noMoveMark,
      isFalse,
      reason: why('$step: no no-move mark before the die lands'),
    );
  }

  void expectLanded(String step, int face, List<int> legal) {
    expect(faces, <int>[
      face,
    ], reason: why('$step: my die resting on exactly game-die-face-$face'));
    expect(
      tumbling,
      isFalse,
      reason: why('$step: my die no longer tumbling once it has landed'),
    );
    expect(
      rings,
      legal,
      reason: why('$step: the legal rings on exactly tokens $legal'),
    );
  }

  /// Section 35 item 7 (e): a mismatch is resolved silently.
  void expectNoError(String step) {
    expect(
      controller.errorCode,
      isNull,
      reason: why('$step: no error code on the controller'),
    );
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: why('$step: the controller still connected'),
    );
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: why('$step: no error snack bar'),
    );
    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: why('$step: no error dialog'),
    );
    expect(
      find.byKey(_noAnswerKey),
      findsNothing,
      reason: why('$step: no "no answer" line on the die'),
    );
  }
}

/// Connects seat 0 on [room] the way the harness's connectPlaying does, but
/// with a snapshot built here (so a row can carry `rules.ruleset`).
Future<RollTrayDrive> _connect(
  WidgetTester tester,
  Map<String, Object?> room,
) async {
  final FakeTransport transport = FakeTransport();
  final List<FakeTransport> later = <FakeTransport>[];
  bool first = true;
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c708t-pre.invalid/ws'),
    connect: (Uri url) async {
      if (first) {
        first = false;
        return transport as WireTransport;
      }
      if (later.isEmpty) {
        throw StateError('c708t: no transport queued for a second connect');
      }
      return later.removeAt(0);
    },
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _wire('seat_assigned', <String, Object?>{
      'seat': _me,
      'seat_token': 'tok-$_me',
    }),
  );
  transport.pushText(_wire('room', room, re: id));
  await created;
  return RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: later.add,
  );
}

typedef _Body = Future<void> Function(_T t);

/// Mounts GameScreen for seat 0 on a snapshot whose turn is [turn], runs
/// [body], and releases the screen and the controller whatever happens.
Future<void> _run(
  WidgetTester tester, {
  required String name,
  required Locale locale,
  required Map<String, Object?>? turn,
  List<int> mine = _openTokens,
  List<int> theirs = _yard,
  String? ruleset,
  required _Body body,
}) async {
  phoneSurfaceTall(tester);
  final Map<String, Object?> room = _roomJson(
    turn: turn,
    mine: mine,
    theirs: theirs,
    ruleset: ruleset,
  );
  final RollTrayDrive drive = await _connect(tester, room);
  await mountGame(tester, drive, locale: locale);
  final _T t = _T(
    tester,
    drive,
    name,
    locale,
    'turn ${jsonEncode(turn)}, my tokens $mine, theirs $theirs, ruleset '
    '${ruleset ?? 'absent'}',
  );
  try {
    await body(t);
  } finally {
    await releaseGame(tester, drive);
  }
}

/// 412 x 892 dp at 2.625, the phone the other screen rows use.
void phoneSurfaceTall(WidgetTester tester) {
  tester.view.physicalSize = const Size(412 * 2.625, 892 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Declares one widget row per locale; the row name ends in `[en]` / `[ar]`.
void _row(String row, Future<void> Function(WidgetTester, Locale, String) b) {
  for (final Locale l in _locales) {
    final String name = '$row [${l.languageCode}]';
    testWidgets(name, (WidgetTester tester) => b(tester, l, name));
  }
}

/// Reads a member the order names (C-708 net layer) through `dynamic`; a
/// base without it fails the row with a line that says which member.
T _named<T>(String member, String why, T Function() read) {
  try {
    return read();
  } on NoSuchMethodError catch (e) {
    fail(
      'expected $member to exist (order 708, "Net layer, names fixed"), it '
      'does not on this tree: $e. $why',
    );
  }
}

/// The tap, the tumble sampled every 5 ms up to one step short of the
/// minimum, then the landing at exactly the minimum.
Future<void> _tapAndLand(
  _T t, {
  required int face,
  required List<int> legal,
  required FeedbackCue landingCue,
  required FeedbackCue otherCue,
}) async {
  final int landingBefore = t.cue(landingCue);
  final int otherBefore = t.cue(otherCue);
  final int pushedBefore = t.pushed.length;
  final int sentRoll = await t.tapDie();
  expect(
    sentRoll,
    1,
    reason: t.why('exactly one `roll` on the wire at the tap, sent $sentRoll'),
  );
  t.expectInAir('right after the tap');
  await t.advanceToSinceTap(
    _tumbleMs - 5,
    step: 5,
    each: () {
      t.expectInAir('during the tumble (sampled every 5 ms)');
      expect(
        t.cue(landingCue) - landingBefore,
        0,
        reason: t.why('no ${landingCue.id} before the die lands'),
      );
    },
  );
  await t.advanceToSinceTap(_tumbleMs, step: 5);
  expect(
    t.pushed.length - pushedBefore,
    1,
    reason: t.why('no frame delivered between the tap and the landing'),
  );
  t.expectLanded('at exactly the tumble minimum (${_tumbleMs}ms)', face, legal);
  expect(
    t.cue(landingCue) - landingBefore,
    1,
    reason: t.why('${landingCue.id} exactly once at the landing, from `pre`'),
  );
  expect(
    t.cue(otherCue) - otherBefore,
    0,
    reason: t.why('no ${otherCue.id} for this landing'),
  );
}

void main() {
  // ===========================================================================
  // PreRoll on the wire (net layer, the order's fixed names)
  // ===========================================================================
  group('PreRoll parsing', () {
    testWidgets('a pushed turn frame carries pre on the turn object and '
        'RoomController.pre', (tester) async {
      final RollTrayDrive drive = await _connect(
        tester,
        _roomJson(
          turn: turnJson(seat: _opp, phase: 'await_roll', k: 0),
          mine: _openTokens,
          theirs: _yard,
        ),
      );
      const String why =
          'C-708t "PreRoll parsing: turn frame" (no widget). Frames: room '
          '(opponent to roll, k 0), then turn {seat 0, await_roll, pre {seat '
          '0, value 4, legal [0,1], k 1, queue [4], legal_by_face [{4,[0,1]}]}}.'
          ' rerun: flock /tmp/ludo-suite.lock flutter test $_file '
          "--plain-name 'a pushed turn frame carries pre'";
      try {
        await drive.push(tester, 'turn', _turnFrame(_me, pre: _preCanMove()));
        final dynamic turn = drive.controller.room!.turn;
        final dynamic onTurn = _named('TurnState.pre', why, () => turn.pre);
        final dynamic held = _named(
          'RoomController.pre',
          why,
          () => (drive.controller as dynamic).pre,
        );
        for (final (String where, dynamic pre) in <(String, dynamic)>[
          ('turn.pre', onTurn),
          ('RoomController.pre', held),
        ]) {
          expect(
            pre,
            isNotNull,
            reason: '$where is null after the frame. $why',
          );
          expect(
            pre.runtimeType.toString(),
            'PreRoll',
            reason: '$where is a ${pre.runtimeType}, expected PreRoll. $why',
          );
          expect(pre.value, 4, reason: '$where.value. $why');
          expect(pre.legal, <int>[0, 1], reason: '$where.legal. $why');
          expect(pre.k, 1, reason: '$where.k. $why');
          expect(pre.queue, <int>[4], reason: '$where.queue. $why');
          final List<String> byFace = <String>[
            for (final dynamic f in pre.legalByFace as List<dynamic>)
              '${f.face}:${f.tokens}',
          ];
          expect(byFace, <String>[
            '4:[0, 1]',
          ], reason: '$where.legalByFace. $why');
          expect(pre.release, isFalse, reason: '$where.release. $why');
          expect(pre.offer, isFalse, reason: '$where.offer absent. $why');
        }
      } finally {
        drive.controller.dispose();
      }
    });

    testWidgets('a snapshot turn carries pre, with release and offer', (
      tester,
    ) async {
      final Map<String, Object?> pre = _pre(
        value: 6,
        legal: const <int>[0, 1],
        queue: const <int>[6],
        release: true,
        offer: true,
      );
      const String why =
          'C-708t "PreRoll parsing: snapshot" (no widget). Snapshot turn '
          '{seat 0, await_roll, k 0, pre {value 6, legal [0,1], k 1, queue '
          '[6], release true, offer true}}. rerun: flock /tmp/ludo-suite.lock '
          "flutter test $_file --plain-name 'a snapshot turn carries pre'";
      final RoomSnapshot room = RoomSnapshot.fromJson(
        _roomJson(
          turn: _myRollTurn(pre: pre),
          mine: _openTokens,
          theirs: _yard,
          ruleset: '2026-12',
        ),
      );
      final dynamic turn = room.turn;
      final dynamic parsed = _named('TurnState.pre', why, () => turn.pre);
      expect(parsed, isNotNull, reason: 'turn.pre is null. $why');
      expect(parsed.value, 6, reason: 'pre.value. $why');
      expect(parsed.legal, <int>[0, 1], reason: 'pre.legal. $why');
      expect(parsed.k, 1, reason: 'pre.k. $why');
      expect(parsed.queue, <int>[6], reason: 'pre.queue. $why');
      expect(parsed.release, isTrue, reason: 'pre.release. $why');
      expect(
        parsed.offer,
        isTrue,
        reason: 'pre.offer, carried as `rolled` parsing carries it. $why',
      );
      expect(
        parsed.legalByFace,
        isNull,
        reason: 'pre.legalByFace null when the wire has none. $why',
      );
    });

    testWidgets('no pre on the wire: turn.pre and RoomController.pre are '
        'null', (tester) async {
      final RollTrayDrive drive = await _connect(
        tester,
        _roomJson(turn: _myRollTurn(), mine: _openTokens, theirs: _yard),
      );
      const String why =
          'C-708t "PreRoll parsing: absent" (no widget). Snapshot turn {seat '
          '0, await_roll, k 0} with no pre. rerun: flock /tmp/ludo-suite.lock '
          "flutter test $_file --plain-name 'no pre on the wire'";
      try {
        final dynamic turn = drive.controller.room!.turn;
        expect(
          _named('TurnState.pre', why, () => turn.pre),
          isNull,
          reason: 'turn.pre. $why',
        );
        expect(
          _named(
            'RoomController.pre',
            why,
            () => (drive.controller as dynamic).pre,
          ),
          isNull,
          reason: 'RoomController.pre. $why',
        );
      } finally {
        drive.controller.dispose();
      }
    });

    testWidgets('RoomController.pre is null for another seat\'s turn even '
        'when the frame carries one', (tester) async {
      final RollTrayDrive drive = await _connect(
        tester,
        _roomJson(
          turn: turnJson(
            seat: _me,
            phase: 'await_move',
            k: 0,
            value: 6,
            legal: const <int>[0],
            queue: const <int>[6],
          ),
          mine: _openTokens,
          theirs: _yard,
        ),
      );
      const String why =
          'C-708t "PreRoll parsing: other seat" (no widget). A turn frame for '
          'seat 1 carrying pre {seat 1, value 4} (never sent by a correct '
          'server, section 35 item 1). rerun: flock /tmp/ludo-suite.lock '
          "flutter test $_file --plain-name 'RoomController.pre is null for "
          "another seat'";
      try {
        await drive.push(
          tester,
          'turn',
          _turnFrame(_opp, pre: _preCanMove(seat: _opp)),
        );
        expect(
          _named(
            'RoomController.pre',
            why,
            () => (drive.controller as dynamic).pre,
          ),
          isNull,
          reason: 'RoomController.pre must be null off my turn. $why',
        );
      } finally {
        drive.controller.dispose();
      }
    });

    testWidgets('RoomController.pre is cleared when the rolled for its k '
        'arrives', (tester) async {
      final RollTrayDrive drive = await _connect(
        tester,
        _roomJson(
          turn: _myRollTurn(pre: _preCanMove()),
          mine: _openTokens,
          theirs: _yard,
        ),
      );
      const String why =
          'C-708t "PreRoll parsing: cleared" (no widget). Snapshot with my '
          'pre (k 1), then the equal rolled k 1. rerun: flock '
          "/tmp/ludo-suite.lock flutter test $_file --plain-name "
          "'RoomController.pre is cleared'";
      try {
        final dynamic before = _named(
          'RoomController.pre',
          why,
          () => (drive.controller as dynamic).pre,
        );
        expect(
          before,
          isNotNull,
          reason: 'pre in hand from the snapshot. $why',
        );
        await drive.push(tester, 'rolled', _rolledOf(_preCanMove()));
        expect(
          (drive.controller as dynamic).pre,
          isNull,
          reason: 'pre still held after the rolled for k 1. $why',
        );
      } finally {
        drive.controller.dispose();
      }
    });

    testWidgets('RoomController.pre is cleared when the turn moves on', (
      tester,
    ) async {
      final RollTrayDrive drive = await _connect(
        tester,
        _roomJson(
          turn: _myRollTurn(pre: _preNoMove()),
          mine: _yard,
          theirs: _yard,
        ),
      );
      const String why =
          'C-708t "PreRoll parsing: turn moves on" (no widget). Snapshot with '
          'my pre (k 1), then turn_passed (my seat, timeout) and the next '
          'seat\'s turn, no rolled. rerun: flock /tmp/ludo-suite.lock flutter '
          "test $_file --plain-name 'RoomController.pre is cleared when the "
          "turn moves on'";
      try {
        expect(
          _named(
            'RoomController.pre',
            why,
            () => (drive.controller as dynamic).pre,
          ),
          isNotNull,
          reason: 'pre in hand from the snapshot. $why',
        );
        await drive.push(tester, 'turn_passed', <String, Object?>{
          'seat': _me,
          'reason': 'timeout',
        });
        await drive.push(tester, 'turn', _turnFrame(_opp));
        expect(
          (drive.controller as dynamic).pre,
          isNull,
          reason: 'pre still held after the turn passed to seat 1. $why',
        );
      } finally {
        drive.controller.dispose();
      }
    });
  });

  // ===========================================================================
  // The tap with a pre in hand
  // ===========================================================================
  group('tap with pre', () {
    _row('roll sent at the tap; the die lands on pre.value at exactly the '
        'tumble minimum with no frame delivered; can_move once', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(pre: _preCanMove()),
        body: (t) async {
          await _tapAndLand(
            t,
            face: 4,
            legal: const <int>[0, 1],
            landingCue: FeedbackCue.canMove,
            otherCue: FeedbackCue.noMove,
          );
          await t.advance(1000);
          expect(
            t.cue(FeedbackCue.canMove),
            1,
            reason: t.why('can_move still exactly once 1 s after the landing'),
          );
          t.expectLanded('1 s after the landing, still no frame', 4, <int>[
            0,
            1,
          ]);
          expect(t.sent('roll'), 1, reason: t.why('one roll in all'));
        },
      );
    });

    _row('the same through a pushed turn frame carrying pre', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: turnJson(seat: _opp, phase: 'await_roll', k: 0),
        body: (t) async {
          await t.push('turn', _turnFrame(_me, pre: _preCanMove()));
          await t.advance(200);
          await _tapAndLand(
            t,
            face: 4,
            legal: const <int>[0, 1],
            landingCue: FeedbackCue.canMove,
            otherCue: FeedbackCue.noMove,
          );
        },
      );
    });

    _row('no legal move in pre: no_move once at the landing with the no-move '
        'mark', (tester, locale, name) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        mine: _yard,
        turn: _myRollTurn(pre: _preNoMove()),
        body: (t) async {
          await _tapAndLand(
            t,
            face: 3,
            legal: const <int>[],
            landingCue: FeedbackCue.noMove,
            otherCue: FeedbackCue.canMove,
          );
          expect(
            t.noMoveMark,
            isTrue,
            reason: t.why('the no-move mark on my die at the landing'),
          );
        },
      );
    });

    _row('the late rolled repaints nothing and fires no second feedback id', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(pre: _preCanMove()),
        body: (t) async {
          await _tapAndLand(
            t,
            face: 4,
            legal: const <int>[0, 1],
            landingCue: FeedbackCue.canMove,
            otherCue: FeedbackCue.noMove,
          );
          await t.advanceToSinceTap(1100);
          final List<String> cuesBefore = t.cueIds;
          final ({double scale, double degrees}) pose = poseOf(
            tester,
            find.descendant(
              of: find.byKey(bigDieKey),
              matching: find.byKey(bigFaceKey(4)),
            ),
          );
          await t.push('rolled', _rolledOf(_preCanMove()));
          for (final int at in <int>[0, 50, 150, 300, 600, 1000]) {
            await t.advanceToSinceTap(1100 + at);
            t.expectLanded('+${at}ms after the late rolled', 4, <int>[0, 1]);
            final ({double scale, double degrees}) now = poseOf(
              tester,
              find.descendant(
                of: find.byKey(bigDieKey),
                matching: find.byKey(bigFaceKey(4)),
              ),
            );
            expect(
              (now.scale - pose.scale).abs() < 0.001 &&
                  (now.degrees - pose.degrees).abs() < 0.01,
              isTrue,
              reason: t.why(
                '+${at}ms after the late rolled: the face drawn as before it '
                '(scale ${pose.scale}, ${pose.degrees} deg), drawn at scale '
                '${now.scale}, ${now.degrees} deg: no second landing pop',
              ),
            );
          }
          expect(
            t.cueIds,
            cuesBefore,
            reason: t.why(
              'no feedback id at all for the late rolled (before it: '
              '$cuesBefore)',
            ),
          );
          expect(
            t.sent('resume'),
            0,
            reason: t.why('no resync for a rolled equal to the pre'),
          );
        },
      );
    });

    _row('the late rolled of a no-move roll and the turn_passed and turn '
        'behind it fire no second no_move', (tester, locale, name) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        mine: _yard,
        turn: _myRollTurn(pre: _preNoMove()),
        body: (t) async {
          await _tapAndLand(
            t,
            face: 3,
            legal: const <int>[],
            landingCue: FeedbackCue.noMove,
            otherCue: FeedbackCue.canMove,
          );
          await t.advanceToSinceTap(900);
          await t.push('rolled', _rolledOf(_preNoMove()));
          await t.push('turn_passed', <String, Object?>{
            'seat': _me,
            'reason': 'no_legal_move',
          });
          await t.push('turn', _turnFrame(_opp));
          await t.advance(2000);
          expect(
            t.cue(FeedbackCue.noMove),
            1,
            reason: t.why('no_move exactly once in all, at the landing'),
          );
          expect(
            t.cue(FeedbackCue.canMove),
            0,
            reason: t.why('no can_move for a roll with no legal move'),
          );
          expect(
            t.sent('resume'),
            0,
            reason: t.why('no resync for a rolled equal to the pre'),
          );
        },
      );
    });

    _row(
      'a rolled that arrives inside the tumble does not land the die early',
      (tester, locale, name) async {
        await _run(
          tester,
          name: name,
          locale: locale,
          turn: _myRollTurn(pre: _preCanMove()),
          body: (t) async {
            expect(await t.tapDie(), 1, reason: t.why('one roll at the tap'));
            await t.advanceToSinceTap(200, step: 5);
            t.expectInAir('+200ms, before the early rolled');
            await t.push('rolled', _rolledOf(_preCanMove()));
            await t.advanceToSinceTap(
              _tumbleMs - 5,
              step: 5,
              each: () => t.expectInAir(
                'after an early rolled, still inside the tumble minimum',
              ),
            );
            await t.advanceToSinceTap(_tumbleMs, step: 5);
            t.expectLanded('at the tumble minimum', 4, <int>[0, 1]);
            await t.advance(1000);
            expect(
              t.cue(FeedbackCue.canMove),
              1,
              reason: t.why('can_move exactly once'),
            );
          },
        );
      },
    );

    _row('a second tap inside the tumble sends no second roll and lands once', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(pre: _preCanMove()),
        body: (t) async {
          expect(await t.tapDie(), 1, reason: t.why('one roll at the tap'));
          await t.advanceToSinceTap(100, step: 5);
          final int again = await t.tapDie(mark: false);
          expect(
            again,
            0,
            reason: t.why('no roll for a tap while the die is in the air'),
          );
          await t.advanceToSinceTap(_tumbleMs - 5, step: 5);
          t.expectInAir('the second tap did not restart or end the tumble');
          await t.advanceToSinceTap(_tumbleMs, step: 5);
          t.expectLanded('at the tumble minimum of the first tap', 4, <int>[
            0,
            1,
          ]);
          await t.advance(1000);
          expect(
            t.cue(FeedbackCue.canMove),
            1,
            reason: t.why('can_move exactly once'),
          );
          expect(t.sent('roll'), 1, reason: t.why('one roll in all'));
        },
      );
    });
  });

  // ===========================================================================
  // A token after the landing
  // ===========================================================================
  group('token after the landing', () {
    _row('a token tapped after the landing sends move at once, before '
        'rolled has arrived, right after the roll', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(pre: _preCanMove()),
        body: (t) async {
          await _tapAndLand(
            t,
            face: 4,
            legal: const <int>[0, 1],
            landingCue: FeedbackCue.canMove,
            otherCue: FeedbackCue.noMove,
          );
          await t.advance(100);
          final int moves = await t.tapToken(0);
          expect(
            moves,
            1,
            reason: t.why('one `move` on the wire at the token tap'),
          );
          final Map<String, Object?> move = movesSince(t.transport, 0).single;
          expect(
            move['token'],
            0,
            reason: t.why('the move names token 0, sent $move'),
          );
          expect(
            move['face'] == null || move['face'] == 4,
            isTrue,
            reason: t.why('the move spends the 4 or names no face, sent $move'),
          );
          final List<String> order = <String>[
            for (final String s in t.sentTypes)
              if (s == 'roll' || s == 'move') s,
          ];
          expect(order, <String>[
            'roll',
            'move',
          ], reason: t.why('`move` right after `roll` on the same socket'));
        },
      );
    });

    _row('a token tapped inside the tumble sends nothing', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(pre: _preCanMove()),
        body: (t) async {
          expect(await t.tapDie(), 1, reason: t.why('one roll at the tap'));
          await t.advanceToSinceTap(300, step: 5);
          final int moves = await t.tapToken(0);
          expect(
            moves,
            0,
            reason: t.why('no `move` for a token tapped before the face shows'),
          );
        },
      );
    });
  });

  // ===========================================================================
  // A rolled that differs from the pre
  // ===========================================================================
  group('mismatch', () {
    final List<(String, Map<String, Object?>, Map<String, Object?>)> cases =
        <(String, Map<String, Object?>, Map<String, Object?>)>[
          (
            'value',
            _pre(
              value: 5,
              legal: const <int>[0, 1],
              queue: const <int>[5],
              legalByFace: <Map<String, Object?>>[
                faceLegal(5, const <int>[0, 1]),
              ],
            ),
            <String, Object?>{
              ...turnJson(
                seat: _me,
                phase: 'await_move',
                k: 1,
                value: 5,
                legal: const <int>[0, 1],
                queue: const <int>[5],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(5, const <int>[0, 1]),
                ],
              ),
            },
          ),
          (
            'legal',
            _pre(
              value: 4,
              legal: const <int>[0],
              queue: const <int>[4],
              legalByFace: <Map<String, Object?>>[
                faceLegal(4, const <int>[0]),
              ],
            ),
            turnJson(
              seat: _me,
              phase: 'await_move',
              k: 1,
              value: 4,
              legal: const <int>[0],
              queue: const <int>[4],
              legalByFace: <Map<String, Object?>>[
                faceLegal(4, const <int>[0]),
              ],
            ),
          ),
          (
            'queue',
            _pre(
              value: 4,
              legal: const <int>[0, 1],
              queue: const <int>[6, 4],
              legalByFace: <Map<String, Object?>>[
                faceLegal(6, const <int>[0, 1, 2, 3]),
                faceLegal(4, const <int>[0, 1]),
              ],
            ),
            turnJson(
              seat: _me,
              phase: 'await_move',
              k: 1,
              value: 4,
              legal: const <int>[0, 1],
              queue: const <int>[6, 4],
              legalByFace: <Map<String, Object?>>[
                faceLegal(6, const <int>[0, 1, 2, 3]),
                faceLegal(4, const <int>[0, 1]),
              ],
            ),
          ),
        ];
    for (final (
          String field,
          Map<String, Object?> truth,
          Map<String, Object?> resumed,
        )
        in cases) {
      _row('a rolled whose $field differs from the pre: exactly one resync, '
          'no error shown', (tester, locale, name) async {
        await _run(
          tester,
          name: name,
          locale: locale,
          turn: _myRollTurn(pre: _preCanMove()),
          body: (t) async {
            // The landing itself is the other rows' subject; this row reads
            // only what the differing rolled causes.
            expect(await t.tapDie(), 1, reason: t.why('one roll at the tap'));
            await t.advanceToSinceTap(1000);
            await t.push('rolled', _rolledOf(truth));
            await t.advance(500);
            expect(
              t.sent('resume'),
              1,
              reason: t.why(
                'exactly one resync (`resume` on the open socket) for a '
                'rolled whose $field differs from the pre',
              ),
            );
            t.expectNoError('while the resync is out');
            final String id = t.lastResumeId();
            t.pushed.add('room (resume reply) turn ${jsonEncode(resumed)}');
            t.transport.pushText(
              roomReplyFrame(
                re: id,
                seats: twoSeats(mine: _openTokens),
                turn: resumed,
                seq: t.drive.lastSeq,
              ),
            );
            await tester.pump();
            await tester.pump();
            await t.advance(1000);
            expect(
              t.sent('resume'),
              1,
              reason: t.why('still one resync after it was answered'),
            );
            t.expectNoError('after the resync');
            if (field == 'value') {
              expect(t.faces, <int>[
                5,
              ], reason: t.why('the die shows the rolled face 5, the truth'));
            }
          },
        );
      });
    }
  });

  // ===========================================================================
  // No pre in hand: today's die
  // ===========================================================================
  group('no pre', () {
    _row('the die tumbles past the minimum and lands on rolled when it '
        'arrives', (tester, locale, name) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(),
        body: (t) async {
          expect(await t.tapDie(), 1, reason: t.why('one roll at the tap'));
          await t.advanceToSinceTap(
            1500,
            each: () {
              t.expectInAir('no pre, no rolled yet');
              expect(
                t.cue(FeedbackCue.canMove),
                0,
                reason: t.why('no can_move before rolled'),
              );
            },
          );
          await t.push('rolled', _rolledOf(_preCanMove()));
          t.expectLanded('in the frame rolled arrived in', 4, <int>[0, 1]);
          await t.advance(500);
          expect(
            t.cue(FeedbackCue.canMove),
            1,
            reason: t.why('can_move exactly once, from rolled'),
          );
        },
      );
    });

    _row('a rolled inside the tumble minimum lands the die when it arrives', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        turn: _myRollTurn(),
        body: (t) async {
          expect(await t.tapDie(), 1, reason: t.why('one roll at the tap'));
          await t.advanceToSinceTap(100, step: 5);
          t.expectInAir('no pre, +100ms');
          await t.push('rolled', _rolledOf(_preCanMove()));
          t.expectLanded('in the frame rolled arrived in', 4, <int>[0, 1]);
        },
      );
    });
  });

  // ===========================================================================
  // Section 29's grace gate with a pre in hand
  // ===========================================================================
  group('grace gate', () {
    _row('an early tap is refused with a pre in hand and starts no landing', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        ruleset: '2026-11',
        turn: turnJson(seat: _opp, phase: 'await_roll', k: 0),
        body: (t) async {
          await t.push(
            'turn',
            _turnFrame(_me, pre: _preCanMove(), graceMs: 1500),
          );
          await t.advance(100, step: 10);
          final int cuesBefore = t.drive.feedback.recorded.length;
          final int sentRoll = await t.tapDie();
          expect(
            sentRoll,
            0,
            reason: t.why('no roll for a tap 100 ms into the grace'),
          );
          final List<String> added = <String>[
            for (final FeedbackCue c in t.drive.feedback.recorded.skip(
              cuesBefore,
            ))
              c.id,
          ];
          expect(added, <String>[
            FeedbackCue.invalidTap.id,
          ], reason: t.why('exactly the invalid-tap cue for the refused tap'));
          await t.advanceToSinceTap(_tumbleMs + 100, step: 10);
          expect(
            t.faces,
            isEmpty,
            reason: t.why('the refused tap must not land the die on the pre'),
          );
          expect(
            t.cue(FeedbackCue.canMove),
            0,
            reason: t.why('no can_move from a refused tap'),
          );
          expect(t.sent('roll'), 0, reason: t.why('still no roll'));
        },
      );
    });

    _row('after the gate opens a tap lands on the pre', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        ruleset: '2026-11',
        turn: turnJson(seat: _opp, phase: 'await_roll', k: 0),
        body: (t) async {
          await t.push(
            'turn',
            _turnFrame(_me, pre: _preCanMove(), graceMs: 1500),
          );
          int waited = 0;
          while (t.cue(FeedbackCue.yourTurn) == 0 && waited < 1600) {
            await t.advance(10, step: 10);
            waited += 10;
          }
          expect(
            t.cue(FeedbackCue.yourTurn),
            1,
            reason: t.why('the gate open (your_turn once) within grace_ms'),
          );
          await _tapAndLand(
            t,
            face: 4,
            legal: const <int>[0, 1],
            landingCue: FeedbackCue.canMove,
            otherCue: FeedbackCue.noMove,
          );
        },
      );
    });
  });

  // ===========================================================================
  // Opponents' dice
  // ===========================================================================
  group('opponent die', () {
    _row('an opponent die lands on rolled, never on a pre a frame carried', (
      tester,
      locale,
      name,
    ) async {
      await _run(
        tester,
        name: name,
        locale: locale,
        theirs: const <int>[10, -1, -1, -1],
        // A pre for seat 1 is never sent to me (section 35 item 1); a
        // snapshot that carries one anyway must change nothing.
        turn: <String, Object?>{
          ...turnJson(seat: _opp, phase: 'await_roll', k: 0),
          'pre': _pre(
            seat: _opp,
            value: 5,
            legal: const <int>[0],
            queue: const <int>[5],
            legalByFace: <Map<String, Object?>>[
              faceLegal(5, const <int>[0]),
            ],
          ),
        },
        body: (t) async {
          final Set<String> seen = <String>{};
          void look() {
            for (int f = 1; f <= 6; f++) {
              if (tester.any(find.byKey(opponentThrowLandedKey(_opp, f)))) {
                seen.add('opponent-throw-landed-$_opp-$f');
              }
              if (tester.any(find.byKey(seatDieFaceKey(_opp, f)))) {
                seen.add('board-seat-die-face-$_opp-$f');
              }
            }
          }

          await t.advance(1500, each: look);
          expect(
            seen.where((String k) => k.endsWith('-5')),
            isEmpty,
            reason: t.why('no face 5 for seat 1 before its rolled, saw $seen'),
          );
          expect(
            tester.any(find.byKey(opponentThrowKey(_opp))),
            isFalse,
            reason: t.why('no throw for seat 1 before its rolled'),
          );
          await t.push(
            'rolled',
            _rolledOf(
              _pre(
                seat: _opp,
                value: 2,
                legal: const <int>[0],
                queue: const <int>[2],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(2, const <int>[0]),
                ],
              ),
            ),
          );
          seen.clear();
          await t.advance(_tumbleMs + 300, each: look);
          expect(
            seen.contains('opponent-throw-landed-$_opp-2'),
            isTrue,
            reason: t.why('seat 1\'s throw landed on its rolled 2, saw $seen'),
          );
          expect(
            seen.where((String k) => k.endsWith('-5')),
            isEmpty,
            reason: t.why('never face 5 for seat 1, saw $seen'),
          );
        },
      );
    });
  });
}
