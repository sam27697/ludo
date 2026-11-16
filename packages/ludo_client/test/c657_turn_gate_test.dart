// Screen proofs for contract C-657 (work/ludo/orders/657-turn-gate-client.md,
// docs/PROTOCOL.md section 29 rules 5 to 7), items G1 to G7: the next seat's
// turn starts when the last move has landed. Written from the contract alone;
// the implementation does not exist when this file is written.
//
// A real GameScreen over a real RoomController on FakeTransport, every state a
// decoded wire frame shaped as the server sends it under 2026-11 (a `turn`
// with `grace_ms` as in test/net/c655_ruleset_net_test.dart N5, a snapshot
// with `rules.ruleset` as in test/c656_ruleset_screen_test.dart). Nothing is
// mocked but the socket and the feedback service. The feedback service is the
// recording one from test/support/roll_tray_harness.dart: it keeps every
// FeedbackCue the screen asks for, in order, and failure lines print them as
// their wire ids (`your_turn`, `invalid_tap`, ...).
//
// How each thing is read:
//   - "your_turn has fired": the count of FeedbackCue.yourTurn on the
//     recording service, against the count taken after the mount.
//   - "my die pulses": a `game-die-pulse` under the big die (`game-die`), the
//     way test/play_surface_die_test.dart and test/idle_die_face_test.dart
//     read it. It is absent under reduced motion by contract of that file, so
//     the reduced-motion case reads the cue and the tap instead.
//   - "my die is tappable": a tap on `game-die` either puts one `roll` on the
//     wire or gives the invalid-tap cue; the test taps and counts both.
//   - "the opponent's die pulse": the opponent's die has no pulse widget. What
//     marks it as the seat on turn is its full opacity (0.45 off turn), read
//     off the Opacity on or above `board-seat-die-<seat>` the way
//     test/seat_die_test.dart does (_opacityOf, copied here).
//   - "the countdown ring is full and still": the `remainingFraction` of the
//     widget keyed `game-header-countdown-ring`, read through dynamic the way
//     test/countdown_segment_test.dart does. The ring ticks once a second.
//
// Time is the test binding's clock, moved only by tester.pump(duration) in
// steps of 10 ms, never pumpAndSettle against a live countdown. "+N ms" is
// counted from the arrival of the frame under test. The walk lengths come from
// the board's own public constants (kTokenStepDuration and friends), so a
// retuned step does not move these cases. There is no seed: every case is a
// fixed list of frames. A failure line names the case, the locale, the motion
// mode, the ruleset, the step in ms since the arrival, what was expected, what
// was observed, and every frame pushed so far, which is the whole
// reproduction. Rerun one case with
//
//   flock /tmp/ludo-suite.lock flutter test test/c657_turn_gate_test.dart \
//     --plain-name '<case name>'
//
// The opponent's `rolled` frame is left out of the walks on purpose: the
// contract's gate counts the board's move queue, and a throw animation in
// front of the walk is not part of it, so a `moved` straight after the
// server's turn state keeps the timeline to what G3 names.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart'
    show
        LudoBoard,
        kCaptureFlightDuration,
        kCaptureFlightDurationReduced,
        kTokenStepDuration,
        kTokenStepDurationReduced;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

/// Section 28 rule 1: the switch, as the snapshot's `rules.ruleset` says it.
const String _ruleset = '2026-11';

/// Section 29 rule 5: Sam's half second, which reduced motion never removes.
const int _halfSecondMs = 500;

/// One pump. Every moment below is known to within this.
const int _stepMs = 10;

/// One frame of slack for "open by T": a gate timer that fires at T shows its
/// effect in the frame built right after it.
const int _frameMs = 16;

const int _budgetMs = 45000;

const int _me = 0;
const int _opp = 2;

const Key _ringKey = Key('game-header-countdown-ring');
const Key _pulseKey = Key('game-die-pulse');

int _ms(Duration d) => d.inMilliseconds;

/// The mover's walk of [steps] squares, then a capture's flight home when
/// [capture], in milliseconds of fake time.
int _walkMs(int steps, {bool capture = false, bool reduced = false}) {
  final int step = _ms(
    reduced ? kTokenStepDurationReduced : kTokenStepDuration,
  );
  final int flight = _ms(
    reduced ? kCaptureFlightDurationReduced : kCaptureFlightDuration,
  );
  return steps * step + (capture ? flight : 0);
}

// --- wire frames, shaped as the server sends them -------------------------------

int _idSeq = 0;

String _wire(String type, Map<String, Object?> data, {String? re}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c657t-srv-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _seat(int seat, String name, List<int> tokens, bool on) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': tokens,
      'client_seed': null,
      'seed_origin': null,
      'drought': ?(on ? 0 : null),
    };

/// A section 6 snapshot of the two-seat table: me on seat 0, Bob on seat 2.
Map<String, Object?> _roomJson({
  required String? ruleset,
  required Map<String, Object?>? turn,
  required List<int> mine,
  required List<int> theirs,
  int seq = 1,
  String state = 'PLAYING',
  Map<String, Object?>? rematch,
}) {
  final bool on = ruleset != null;
  return <String, Object?>{
    'code': 'K7M2QP',
    'state': state,
    'host_seat': 0,
    'players': 2,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': false,
      'turn_seconds': 45,
      'ruleset': ?ruleset,
    },
    'chain_commit': 'a' * 64,
    'chain_index': 0,
    'game_id': null,
    'client_seeds': null,
    'seats': <Map<String, Object?>>[
      _seat(_me, 'Sam', mine, on),
      _seat(_opp, 'Bob', theirs, on),
    ],
    'turn': turn,
    'winner': null,
    'seq': seq,
    'placings': ?(on ? <int>[] : null),
    'retired': ?(on ? <int>[] : null),
    'rematch': ?rematch,
  };
}

Map<String, Object?> _awaitMove(
  int seat,
  int value,
  List<int> legal, {
  int k = 1,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_move',
  'deadline_ms': _budgetMs,
  'k': k,
  'value': value,
  'legal': legal,
};

Map<String, Object?> _awaitRoll(int seat, {int k = 0, int? grace}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': _budgetMs,
      'k': k,
      'grace_ms': ?grace,
    };

/// The pushed `turn` frame: `{seat, phase, deadline_ms, queue}` and, when the
/// turn passed under 2026-11, `grace_ms` (section 29 rule 3).
Map<String, Object?> _turnFrame(int seat, {int? grace}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': _budgetMs,
  'queue': <int>[],
  'grace_ms': ?grace,
};

/// My token 0 stands where the opponent's token 0 lands: its progress 16 is
/// square (26 + 16) % 52 = 42 of the track, which is my progress 42.
const List<int> _mineCapturable = <int>[42, 5, 20, -1];
const List<int> _mineOpen = <int>[10, 5, 20, -1];
const List<int> _theirsAtTen = <int>[10, -1, -1, -1];

Map<String, Object?> _oppWalk(int from, int to, {bool capture = false}) =>
    movedFrame(
      _opp,
      0,
      from,
      to,
      captured: capture
          ? <Map<String, int>>[
              <String, int>{'seat': _me, 'token': 0},
            ]
          : const <Map<String, int>>[],
    );

// --- one mounted table ------------------------------------------------------------

/// The controller, the screen, the fake clock and the log that makes a failure
/// reproducible.
class _G {
  _G({
    required this.tester,
    required this.drive,
    required this.scenario,
    required this.locale,
    required this.reduced,
    required this.ruleset,
    required this.oppTurn,
  }) : transports = <FakeTransport>[drive.transport];

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;
  final Locale locale;
  final bool reduced;
  final String? ruleset;

  /// True when the gate under test belongs to the opponent's turn: then "open"
  /// is read off the opponent's die, not off my cue.
  final bool oppTurn;
  final List<FakeTransport> transports;
  final List<String> frames = <String>[];

  int now = 0;
  int t0 = 0;

  /// `your_turn` cues already recorded when the case starts counting.
  int baseYours = 0;

  int get rel => now - t0;

  /// The moment the frame under test arrives: every "+N ms" counts from here.
  void mark() => t0 = now;

  String get motion => reduced ? 'reduced-motion' : 'full-motion';

  int get yours => cueCount(drive.feedback, FeedbackCue.yourTurn) - baseYours;

  List<String> get cueIds => <String>[
    for (final FeedbackCue c in drive.feedback.recorded) c.id,
  ];

  bool get pulsing => find
      .descendant(of: find.byKey(bigDieKey), matching: find.byKey(_pulseKey))
      .evaluate()
      .isNotEmpty;

  double? get ring {
    final Finder f = find.byKey(_ringKey);
    if (!tester.any(f)) {
      return null;
    }
    final dynamic w = tester.widget(f);
    return w.remainingFraction as double;
  }

  int get rolls => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (frameType(s) == 'roll') s,
  ].length;

  double oppDieOpacity() => _opacityOf(tester, seatDieKey(_opp));

  /// The die the player is looking at has been given its turn.
  bool get isOpen => oppTurn ? oppDieOpacity() >= 0.99 : yours > 0;

  String get observed =>
      'your_turn fired $yours time(s), die pulse $pulsing, opponent die '
      'opacity ${tester.any(find.byKey(seatDieKey(_opp))) ? oppDieOpacity().toStringAsFixed(2) : 'n/a'}, '
      'ring ${ring?.toStringAsFixed(4)}, rolls sent $rolls, cues $cueIds';

  String why(String step, String expected) =>
      'C-657t "$scenario" [${locale.languageCode}, $motion, ruleset '
      '${ruleset ?? 'absent'}] at +${rel}ms ($step): expected $expected; '
      'observed $observed. Frames pushed (@ms since the mark): '
      '${frames.isEmpty ? '<none>' : frames.join(' -> ')}. Fixed frames, no '
      'seed: rerun with flock /tmp/ludo-suite.lock flutter test '
      "test/c657_turn_gate_test.dart --plain-name '$scenario'.";

  Future<void> push(String type, Map<String, Object?> data) async {
    final String body = jsonEncode(data);
    frames.add(
      '$type ${body.length > 150 ? '${body.substring(0, 150)}...' : body}'
      '@${rel}ms',
    );
    await drive.push(tester, type, data);
  }

  /// Pumps to [ms] since the mark in 10 ms steps, calling [each] after every
  /// step.
  Future<void> advanceTo(int ms, {void Function()? each}) async {
    while (rel < ms) {
      final int step = ms - rel < _stepMs ? ms - rel : _stepMs;
      await tester.pump(Duration(milliseconds: step));
      now += step;
      each?.call();
    }
  }

  // --- what a shut gate looks like --------------------------------------------

  /// G2, the part that needs no tap: the die has not been given its turn.
  void expectShutLook(String step) {
    expect(
      yours,
      0,
      reason: why(step, 'no your_turn while the gate is shut, fired $yours'),
    );
    expect(
      pulsing,
      isFalse,
      reason: why(step, 'my die is not pulsing while the gate is shut'),
    );
    if (oppTurn) {
      expect(
        oppDieOpacity(),
        closeTo(0.45, 0.01),
        reason: why(
          step,
          'the opponent die keeps its off-turn look (opacity 0.45) while the '
          'gate is shut',
        ),
      );
    }
    final double? r = ring;
    expect(
      r,
      isNotNull,
      reason: why(step, 'the countdown ring is on screen, full'),
    );
    expect(
      r,
      closeTo(1.0, 0.0005),
      reason: why(step, 'the countdown ring drawn full and still, not ticking'),
    );
  }

  Future<int> tapDie() async {
    final int before = rolls;
    await tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
    await tester.pump();
    return rolls - before;
  }

  /// G2: a tap on my die sends no roll and gives the invalid-tap feedback and
  /// nothing else (no new feedback id).
  Future<void> expectTapRefused(String step) async {
    final int cuesBefore = drive.feedback.recorded.length;
    final int sent = await tapDie();
    final List<String> added = <String>[
      for (final FeedbackCue c in drive.feedback.recorded.skip(cuesBefore))
        c.id,
    ];
    expect(
      sent,
      0,
      reason: why(step, 'a tap on my die to send no roll, sent $sent'),
    );
    expect(
      added,
      <String>[FeedbackCue.invalidTap.id],
      reason: why(
        step,
        'exactly the invalid-tap cue ([${FeedbackCue.invalidTap.id}]) for the '
        'refused tap, got $added',
      ),
    );
  }

  /// A shut gate, looked at and tapped.
  Future<void> expectShut(String step) async {
    expectShutLook(step);
    if (!oppTurn) {
      await expectTapRefused(step);
      expectShutLook('$step, after the refused tap');
    }
  }

  /// Pumps to [ms], checking at every step that the gate is still shut.
  Future<void> advanceShutTo(int ms, String step) =>
      advanceTo(ms, each: () => expectShutLook('$step (sampled)'));

  /// Pumps until the gate has opened or [limitMs] since the mark has passed.
  /// Returns the ms since the mark at which it was seen open, or null. The
  /// gate must stay shut until then.
  Future<int?> advanceUntilOpen(int limitMs, String step) async {
    while (rel < limitMs) {
      await advanceTo(rel + _stepMs);
      if (isOpen) {
        return rel;
      }
      expectShutLook('$step (sampled)');
    }
    return null;
  }

  /// G4: at the opening, my die pulses (full motion), `your_turn` has fired
  /// exactly once, and a tap sends exactly one roll.
  Future<void> expectOpenMine(String step) async {
    expect(
      yours,
      1,
      reason: why(step, 'your_turn fired exactly once at the opening'),
    );
    if (!reduced) {
      expect(
        pulsing,
        isTrue,
        reason: why(step, 'my die pulsing (game-die-pulse) once it is open'),
      );
    }
    final int sent = await tapDie();
    expect(
      sent,
      1,
      reason: why(step, 'a tap on the open die to send exactly one roll'),
    );
  }

  /// G4 for an opponent's turn: its die is at full opacity, and no your_turn
  /// is played for a seat that is not mine.
  void expectOpenTheirs(String step) {
    expect(
      oppDieOpacity(),
      closeTo(1.0, 0.01),
      reason: why(step, 'the opponent die at full opacity once the gate opens'),
    );
    expect(
      yours,
      0,
      reason: why(step, 'no your_turn for the opponent\'s turn, got $yours'),
    );
  }

  /// G4's "once": after more time nothing fires a second time.
  Future<void> expectOnce(String step, {int more = 3000}) async {
    await advanceTo(rel + more);
    expect(
      yours,
      1,
      reason: why(step, 'your_turn still exactly once, $more ms later'),
    );
  }
}

/// The opacity a seat die paints at: the product of every Opacity,
/// AnimatedOpacity and FadeTransition on the key's own element and above it,
/// up to the LudoBoard. Copied from test/seat_die_test.dart (_opacityOf).
double _opacityOf(WidgetTester tester, Key key) {
  expect(
    find.byKey(key),
    findsOneWidget,
    reason: '$key is on the board, to read its opacity',
  );
  double product = 1.0;
  double read(Widget widget) {
    if (widget is Opacity) {
      return widget.opacity;
    }
    if (widget is AnimatedOpacity) {
      return widget.opacity;
    }
    if (widget is FadeTransition) {
      return widget.opacity.value;
    }
    return 1.0;
  }

  final Element start = tester.element(find.byKey(key));
  product *= read(start.widget);
  start.visitAncestorElements((Element ancestor) {
    if (ancestor.widget is LudoBoard) {
      return false;
    }
    product *= read(ancestor.widget);
    return true;
  });
  return product;
}

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

/// Connects, mounts GameScreen for seat 0 on [turn], settles one second (the
/// mount's own cues land) and takes the baseline the case counts from.
Future<_G> _open(
  WidgetTester tester, {
  required String scenario,
  required Map<String, Object?> turn,
  Locale locale = _en,
  bool reduced = false,
  String? ruleset = _ruleset,
  List<int> mine = _mineCapturable,
  List<int> theirs = _theirsAtTen,
  bool oppTurn = false,
  bool settle = true,
}) async {
  phoneSurface(tester);
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c657t.invalid/ws'),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _wire('seat_assigned', <String, Object?>{
      'seat': _me,
      'seat_token': 'tok-$_me',
    }),
  );
  transport.pushText(
    _wire(
      'room',
      _roomJson(ruleset: ruleset, turn: turn, mine: mine, theirs: theirs),
      re: id,
    ),
  );
  await future;
  final RollTrayDrive drive = RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: connector.enqueue,
  );
  await mountGame(tester, drive, locale: locale, disableAnimations: reduced);
  final _G g = _G(
    tester: tester,
    drive: drive,
    scenario: scenario,
    locale: locale,
    reduced: reduced,
    ruleset: ruleset,
    oppTurn: oppTurn,
  );
  if (settle) {
    await tester.pump(const Duration(seconds: 1));
  }
  g.baseYours = cueCount(drive.feedback, FeedbackCue.yourTurn);
  g.mark();
  return g;
}

typedef _Body = Future<void> Function(_G g);

/// One testWidgets per locale, named C-657t, the case name and the locale. The screen and the
/// controller are released whatever [body] does.
void _case(
  String name,
  _Body body, {
  required Map<String, Object?> turn,
  List<Locale> locales = const <Locale>[_en],
  bool reduced = false,
  String? ruleset = _ruleset,
  List<int> mine = _mineCapturable,
  List<int> theirs = _theirsAtTen,
  bool oppTurn = false,
  bool settle = true,
}) {
  for (final Locale locale in locales) {
    final String full = 'C-657t $name [${locale.languageCode}]';
    testWidgets(full, (WidgetTester tester) async {
      final _G g = await _open(
        tester,
        scenario: full,
        turn: turn,
        locale: locale,
        reduced: reduced,
        ruleset: ruleset,
        mine: mine,
        theirs: theirs,
        oppTurn: oppTurn,
        settle: settle,
      );
      try {
        await body(g);
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });
  }
}

/// The opponent's capture of my token 0 over six squares, then the turn to my
/// seat with [grace] (the server's own figure, 1700, unless a case says
/// otherwise).
Future<void> _captureThenMyTurn(_G g, {int? grace = 1700}) async {
  g.mark();
  await g.push('moved', _oppWalk(10, 16, capture: true));
  await g.push('turn', _turnFrame(_me, grace: grace));
}

void main() {
  // ============================================================================
  // 1 and 10. The contract's own example: a six-square capture, grace 1700.
  // ============================================================================
  _case(
    '1 opponent captures my token over six squares, turn to me with '
    'grace_ms 1700: shut at 500 and 1100, open once by 1700',
    (_G g) async {
      await _captureThenMyTurn(g);
      await g.advanceShutTo(500, 'before the 500 ms check');
      await g.expectShut('500 ms into the grace');
      await g.advanceShutTo(1100, 'before the 1100 ms check');
      await g.expectShut('1100 ms into the grace');
      final int? at = await g.advanceUntilOpen(1700 + _frameMs, 'to 1700 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '1700 ms plus one frame',
          'the gate open by grace_ms (1700) after the frame, never later',
        ),
      );
      await g.expectOpenMine('at the opening');
      await g.expectOnce('after the opening');
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    locales: const <Locale>[_en, _ar],
  );

  // ============================================================================
  // 2. G3 (b): never later than grace_ms.
  // ============================================================================
  _case(
    '2 grace_ms 600 after a twelve-square walk: shut at 300 and 500, open by '
    '600 plus one frame',
    (_G g) async {
      g.mark();
      await g.push('moved', _oppWalk(10, 22));
      await g.push('turn', _turnFrame(_me, grace: 600));
      await g.advanceShutTo(300, 'before the 300 ms check');
      await g.expectShut('300 ms into the grace');
      await g.advanceShutTo(500, 'before the 500 ms check');
      await g.expectShut('500 ms into the grace');
      final int? at = await g.advanceUntilOpen(600 + _frameMs, 'to 600 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '600 ms plus one frame',
          'the gate open by grace_ms (600) after the frame although the walk '
              '(${_walkMs(12)} ms) is still going',
        ),
      );
      await g.expectOpenMine('at the opening');
      await g.expectOnce('after the opening');
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    mine: _mineOpen,
  );

  // ============================================================================
  // 3. G5: reduced motion shortens (a) and never removes the 500 ms.
  // ============================================================================
  _case(
    '3 reduced motion, four-square walk, grace_ms 1060: shut 380 ms after the '
    'last step lands, open within 700 ms of it',
    (_G g) async {
      final int landed = _walkMs(4, reduced: true);
      g.mark();
      await g.push('moved', _oppWalk(10, 14));
      await g.push('turn', _turnFrame(_me, grace: 1060));
      await g.advanceShutTo(landed ~/ 2, 'during the walk');
      await g.expectShut('half way through the reduced walk');
      await g.advanceShutTo(landed + _halfSecondMs - 120, 'after the landing');
      await g.expectShut('380 ms after the last step lands at +$landed ms');
      final int limit = landed + _halfSecondMs + 200;
      final int? at = await g.advanceUntilOpen(limit, 'to the opening');
      expect(
        at,
        isNotNull,
        reason: g.why(
          'by +$limit ms',
          'the gate open within 700 ms of the last reduced step landing at '
              '+$landed ms: the reduced steps shorten (a), the 500 ms stays, '
              'and grace_ms 1060 is not what opens it',
        ),
      );
      await g.expectOpenMine('at the opening');
      await g.expectOnce('after the opening');
    },
    turn: _awaitMove(_opp, 4, const <int>[0]),
    mine: _mineOpen,
    reduced: true,
  );

  // ============================================================================
  // 4. G6: a snapshot with grace_ms.
  // ============================================================================
  testWidgets('C-657t 4a resume: a snapshot turn for my seat with grace_ms 660 '
      'opens the gate 660 ms after the snapshot arrived [en]', (
    WidgetTester tester,
  ) async {
    const String name =
        'C-657t 4a resume: a snapshot turn for my seat with grace_ms 660 '
        'opens the gate 660 ms after the snapshot arrived [en]';
    final _G g = await _open(
      tester,
      scenario: name,
      turn: _awaitMove(_opp, 4, const <int>[0]),
      mine: _mineOpen,
    );
    try {
      final FakeTransport lost = g.transports.last;
      lost.endFromFarSide();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final FakeTransport next = FakeTransport();
      g.transports.add(next);
      g.drive.enqueueTransport(next);
      unawaited(g.drive.controller.reconnect());
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(
        next.sentRaw,
        isNotEmpty,
        reason: g.why('reconnect', 'a resume request on the new transport'),
      );
      expect(
        frameType(next.sentRaw.last),
        'resume',
        reason: g.why('reconnect', 'the request sent is a resume'),
      );
      final String resumeId = requestIdOf(next.sentRaw.last);
      final Map<String, Object?> turn = <String, Object?>{
        'seat': _me,
        'phase': 'await_roll',
        'deadline_ms': _budgetMs,
        'k': 3,
        'grace_ms': 660,
      };
      g.drive.lastSeq += 1;
      g.mark();
      g.frames.add('room(resume) turn=${jsonEncode(turn)}@0ms');
      next.pushText(
        _wire(
          'room',
          _roomJson(
            ruleset: _ruleset,
            turn: turn,
            mine: _mineOpen,
            theirs: const <int>[14, -1, -1, -1],
            seq: g.drive.lastSeq,
          ),
          re: resumeId,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        g.drive.controller.phase,
        RoomPhase.connected,
        reason: g.why('resume', 'the resume answer lands the controller'),
      );
      await g.advanceShutTo(500, 'before the 500 ms check');
      await g.expectShut('500 ms after the snapshot');
      await g.advanceShutTo(640, 'before the 640 ms check');
      await g.expectShut('640 ms after the snapshot');
      final int? at = await g.advanceUntilOpen(660 + _frameMs, 'to 660 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '660 ms plus one frame',
          'the gate open grace_ms (660) after the snapshot arrived',
        ),
      );
      await g.expectOpenMine('at the opening');
      await g.expectOnce('after the opening');
    } finally {
      await releaseGame(tester, g.drive);
    }
  });

  _case(
    '4b relaunch: a mount over a snapshot whose turn carries grace_ms 660 '
    'opens the gate 660 ms after the snapshot arrived',
    (_G g) async {
      await g.advanceShutTo(500, 'before the 500 ms check');
      expect(
        g.pulsing,
        isFalse,
        reason: g.why('500 ms', 'my die not pulsing inside the grace'),
      );
      await g.expectTapRefused('500 ms after the snapshot');
      await g.advanceShutTo(640, 'before the 640 ms check');
      expect(
        g.pulsing,
        isFalse,
        reason: g.why('640 ms', 'my die not pulsing inside the grace'),
      );
      await g.advanceTo(660 + _frameMs);
      expect(
        g.pulsing,
        isTrue,
        reason: g.why('660 ms plus one frame', 'my die pulsing, gate open'),
      );
      final int sent = await g.tapDie();
      expect(
        sent,
        1,
        reason: g.why('660 ms plus one frame', 'a tap sends exactly one roll'),
      );
      expect(
        g.yours <= 1,
        isTrue,
        reason: g.why('after the opening', 'your_turn at most once'),
      );
    },
    turn: <String, Object?>{
      'seat': _me,
      'phase': 'await_roll',
      'deadline_ms': _budgetMs,
      'k': 3,
      'grace_ms': 660,
    },
    mine: _mineOpen,
    settle: false,
  );

  // ============================================================================
  // 5. The opponent's die follows the same gate.
  // ============================================================================
  _case(
    '5 my four-square move passes the turn to the opponent with grace_ms '
    '1060: its die keeps the off-turn look until the gate',
    (_G g) async {
      final int landed = _walkMs(4);
      g.mark();
      await g.push('moved', movedFrame(_me, 0, 10, 14));
      await g.push('turn', _turnFrame(_opp, grace: 1060));
      await g.advanceShutTo(landed ~/ 2, 'during my walk');
      await g.expectShut('half way through my walk');
      await g.advanceShutTo(landed + _halfSecondMs - 120, 'after my landing');
      await g.expectShut('380 ms after my last step lands at +$landed ms');
      final int? at = await g.advanceUntilOpen(1060 + _frameMs, 'to 1060 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '1060 ms plus one frame',
          'the opponent die at full opacity by grace_ms (1060)',
        ),
      );
      g.expectOpenTheirs('at the opening');
    },
    turn: _awaitMove(_me, 4, const <int>[0]),
    mine: _mineOpen,
    oppTurn: true,
  );

  // ============================================================================
  // 6. G1: no gate on a same-seat turn or on the first turn of a game.
  // ============================================================================
  _case(
    '6a same-seat turn (my extra roll after a move): no gate',
    (_G g) async {
      g.mark();
      await g.push('moved', movedFrame(_me, 0, 10, 16, extraRoll: true));
      await g.push('turn', _turnFrame(_me));
      expect(
        g.yours,
        1,
        reason: g.why(
          'the frame arrived',
          'your_turn at once for a same-seat turn (no gate)',
        ),
      );
      expect(
        g.pulsing,
        isTrue,
        reason: g.why(
          'the frame arrived',
          'my die pulsing at once for a same-seat turn',
        ),
      );
      final int sent = await g.tapDie();
      expect(
        sent,
        1,
        reason: g.why(
          'the frame arrived',
          'a tap on my die to roll at once for a same-seat turn',
        ),
      );
    },
    turn: _awaitMove(_me, 6, const <int>[0]),
    mine: _mineOpen,
  );

  testWidgets('C-657t 6b the first turn after game_started (a rematch) has no '
      'gate even when it names another seat than the last turn [en]', (
    WidgetTester tester,
  ) async {
    const String name =
        'C-657t 6b the first turn after game_started (a rematch) has no gate '
        'even when it names another seat than the last turn [en]';
    final _G g = await _open(
      tester,
      scenario: name,
      turn: _awaitRoll(_opp),
      mine: const <int>[-1, -1, -1, -1],
      theirs: const <int>[-1, -1, -1, -1],
    );
    try {
      await g.push('game_over', <String, Object?>{
        'winner': _opp,
        'verify_url': 'https://c657t.invalid/verify/1',
        'placings': <int>[_opp, _me],
        'retired': <int>[],
      });
      await tester.pump(const Duration(seconds: 6));
      g.now += 6000;
      await g.push(
        'room',
        _roomJson(
          ruleset: _ruleset,
          turn: null,
          mine: const <int>[-1, -1, -1, -1],
          theirs: const <int>[-1, -1, -1, -1],
          state: 'LOBBY',
          rematch: <String, Object?>{
            'by': _me,
            'ready': <int>[_me],
          },
        ),
      );
      await g.push('game_started', <String, Object?>{
        'turn': _me,
        'game_id': 'c657t-game-two',
        'client_seeds': '0:sam-seed|2:bob-seed',
      });
      g.baseYours = cueCount(g.drive.feedback, FeedbackCue.yourTurn);
      g.mark();
      await g.push('turn', _turnFrame(_me));
      expect(
        g.yours,
        1,
        reason: g.why(
          'the first turn arrived',
          'your_turn at once for the first turn after game_started (no gate)',
        ),
      );
      expect(
        g.ring,
        closeTo(1.0, 0.0005),
        reason: g.why('the first turn arrived', 'the ring full'),
      );
      await g.advanceTo(1100);
      expect(
        g.ring,
        closeTo(44 / 45, 0.0005),
        reason: g.why(
          '1100 ms',
          'the ring counting from the frame (44 of 45 s left), no gate',
        ),
      );
    } finally {
      await releaseGame(tester, g.drive);
    }
  });

  // ============================================================================
  // 7. G1: a 2026-10 room is today's timing, even with grace_ms on the frame.
  // ============================================================================
  _case(
    '7a 2026-10 room: capture then my turn, a frame carrying grace_ms 1700 '
    'is ignored (today\'s timing)',
    (_G g) async {
      await _captureThenMyTurn(g);
      expect(
        g.yours,
        1,
        reason: g.why('the frame arrived', 'your_turn at once, no gate'),
      );
      expect(
        g.pulsing,
        isTrue,
        reason: g.why('the frame arrived', 'my die pulsing at once'),
      );
      await g.advanceTo(500);
      final int sent = await g.tapDie();
      expect(
        sent,
        1,
        reason: g.why(
          '500 ms',
          'a tap rolls at once, no gate in a 2026-10 room',
        ),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    ruleset: null,
  );

  _case(
    '7b 2026-10 room: my move then the opponent\'s turn, grace_ms 1060 on the '
    'frame is ignored: its die is at full opacity and the ring counts from '
    'the frame',
    (_G g) async {
      g.mark();
      await g.push('moved', movedFrame(_me, 0, 10, 14));
      await g.push('turn', _turnFrame(_opp, grace: 1060));
      expect(
        g.oppDieOpacity(),
        closeTo(1.0, 0.01),
        reason: g.why('the frame arrived', 'the opponent die at full opacity'),
      );
      await g.advanceTo(1100);
      expect(
        g.ring,
        closeTo(44 / 45, 0.0005),
        reason: g.why(
          '1100 ms',
          'the ring counting from the frame (44 of 45 s left), today\'s timing',
        ),
      );
    },
    turn: _awaitMove(_me, 4, const <int>[0]),
    mine: _mineOpen,
    ruleset: null,
    oppTurn: true,
  );

  // ============================================================================
  // 8. G7: a rolled for my seat inside a shut gate opens it at once.
  // ============================================================================
  _case(
    '8 a rolled for my seat 300 ms into a shut gate opens it at once and is '
    'shown as today',
    (_G g) async {
      await _captureThenMyTurn(g);
      await g.advanceShutTo(250, 'before the rolled');
      await g.expectShut('250 ms, still in the grace');
      await g.advanceShutTo(300, 'to the rolled');
      await g.push('rolled', rolledFrame(_me, 4, 1, legal: const <int>[1, 2]));
      await g.advanceTo(g.rel + _frameMs);
      expect(
        g.yours,
        1,
        reason: g.why(
          'the rolled arrived',
          'your_turn fired once when the gate opened at once',
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(bigDieKey),
          matching: find.byKey(bigFaceKey(4)),
        ),
        findsOneWidget,
        reason: g.why('the rolled arrived', 'my die showing the 4 it rolled'),
      );
      expect(
        ringedTokens(g.tester),
        <int>[1, 2],
        reason: g.why(
          'the rolled arrived',
          'the legal tokens 1 and 2 marked on the board, as today',
        ),
      );
      expect(
        cueCount(g.drive.feedback, FeedbackCue.canMove),
        1,
        reason: g.why('the rolled arrived', 'the can_move cue once, as today'),
      );
      await g.advanceTo(1700 + 300);
      expect(
        g.yours,
        1,
        reason: g.why(
          'past the old gate time',
          'your_turn still exactly once, the old timer does not fire it again',
        ),
      );
      expect(ringedTokens(g.tester), <int>[
        1,
        2,
      ], reason: g.why('past the old gate time', 'the legal marks still up'));
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
  );

  // ============================================================================
  // 9. The countdown: full and still in the gate, counting from the opening.
  // ============================================================================
  Future<void> countdownBody(
    _G g,
    Future<void> Function() pushMove,
    int grace,
  ) async {
    g.mark();
    await pushMove();
    await g.advanceShutTo(grace - 40, 'inside the grace');
    final int? at = await g.advanceUntilOpen(grace + _frameMs, 'to the grace');
    expect(
      at,
      isNotNull,
      reason: g.why(
        '${grace + _frameMs} ms',
        'the gate open by grace_ms ($grace)',
      ),
    );
    final int opened = g.rel;
    await g.advanceTo(opened + 500);
    expect(
      g.ring,
      closeTo(1.0, 0.0005),
      reason: g.why(
        'opening +500 ms (opened at +$opened ms)',
        'the ring still full: the first second of the segment is not over',
      ),
    );
    await g.advanceTo(opened + 1500);
    expect(
      g.ring,
      closeTo(44 / 45, 0.0005),
      reason: g.why(
        'opening +1500 ms (opened at +$opened ms)',
        'the ring at 44 of 45 s: the segment counts from the opening',
      ),
    );
    await g.advanceTo(opened + 10500);
    expect(
      g.ring,
      closeTo(35 / 45, 0.0005),
      reason: g.why(
        'opening +10500 ms (opened at +$opened ms)',
        'the ring at 35 of 45 s: ten whole seconds after the opening',
      ),
    );
  }

  _case(
    '9a countdown, my turn after a four-square walk, grace_ms 1060: ring '
    'full and still until the gate, then counting from it',
    (_G g) => countdownBody(g, () async {
      await g.push('moved', _oppWalk(10, 14));
      await g.push('turn', _turnFrame(_me, grace: 1060));
    }, 1060),
    turn: _awaitMove(_opp, 4, const <int>[0]),
    mine: _mineOpen,
  );

  _case(
    '9b countdown, the opponent\'s turn after my four-square walk, grace_ms '
    '1060: ring full and still until the gate, then counting from it',
    (_G g) => countdownBody(g, () async {
      await g.push('moved', movedFrame(_me, 0, 10, 14));
      await g.push('turn', _turnFrame(_opp, grace: 1060));
    }, 1060),
    turn: _awaitMove(_me, 4, const <int>[0]),
    mine: _mineOpen,
    oppTurn: true,
  );

  // ============================================================================
  // 11. G3 (a) alone: no grace_ms on the frame.
  // ============================================================================
  _case(
    '11 a turn that passes with no grace_ms: (a) alone, shut 380 ms after the '
    'last step lands, open within 700 ms of it',
    (_G g) async {
      final int landed = _walkMs(4);
      g.mark();
      await g.push('moved', _oppWalk(10, 14));
      await g.push('turn', _turnFrame(_me));
      await g.advanceShutTo(landed ~/ 2, 'during the walk');
      await g.expectShut('half way through the walk');
      await g.advanceShutTo(landed + _halfSecondMs - 120, 'after the landing');
      await g.expectShut('380 ms after the last step lands at +$landed ms');
      final int limit = landed + _halfSecondMs + 200;
      final int? at = await g.advanceUntilOpen(limit, 'to the opening');
      expect(
        at,
        isNotNull,
        reason: g.why(
          'by +$limit ms',
          'the gate open within 700 ms of the last step landing at '
              '+$landed ms, with no grace_ms to cap it',
        ),
      );
      await g.expectOpenMine('at the opening');
      await g.expectOnce('after the opening');
    },
    turn: _awaitMove(_opp, 4, const <int>[0]),
    mine: _mineOpen,
  );

  // ============================================================================
  // 12. The screen goes away inside a gate: nothing fires afterwards.
  // ============================================================================
  testWidgets('C-657t 12 the screen is unmounted 300 ms into a shut gate: no '
      'timer outlives it and nothing fires afterwards [en]', (
    WidgetTester tester,
  ) async {
    const String name =
        'C-657t 12 the screen is unmounted 300 ms into a shut gate: no timer '
        'outlives it and nothing fires afterwards [en]';
    final _G g = await _open(
      tester,
      scenario: name,
      turn: _awaitMove(_opp, 6, const <int>[0]),
    );
    try {
      await _captureThenMyTurn(g);
      await g.advanceShutTo(300, 'before the unmount');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final int before = g.drive.feedback.recorded.length;
      await tester.pump(const Duration(seconds: 3));
      g.now += 3000;
      expect(
        g.drive.feedback.recorded.skip(before).map((FeedbackCue c) => c.id),
        isEmpty,
        reason: g.why(
          '3 s after the unmount',
          'no cue played by a screen that is gone',
        ),
      );
    } finally {
      await releaseGame(tester, g.drive);
    }
  });

  // ============================================================================
  // 13. G3 (b) against the no-move hold: the opponent's roll has no move.
  // ============================================================================
  _case(
    '13 the opponent rolls with no legal move, turn_passed, turn to me with '
    'grace_ms 1500: shut at 1100, open by 1500 plus one frame',
    (_G g) async {
      g.mark();
      await g.push('rolled', <String, Object?>{
        'seat': _opp,
        'value': 3,
        'legal': <int>[],
        'deadline_ms': _budgetMs,
        'k': 1,
        'reveal': rollTrayReveal,
        'queue': <int>[],
      });
      await g.push('turn_passed', <String, Object?>{
        'seat': _opp,
        'reason': 'no_legal_move',
      });
      await g.push('turn', _turnFrame(_me, grace: 1500));
      await g.advanceShutTo(1100, 'before the 1100 ms check');
      await g.expectShut('1100 ms into the grace');
      final int? at = await g.advanceUntilOpen(1500 + _frameMs, 'to 1500 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '1500 ms plus one frame',
          'the gate open by grace_ms (1500): the earlier of the no-move hold '
              'plus 500 (2000) and grace_ms',
        ),
      );
      await g.expectOpenMine('at the opening');
      await g.expectOnce('after the opening');
    },
    turn: _awaitRoll(_opp),
    mine: _mineOpen,
  );
}
