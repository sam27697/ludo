// Screen proofs for contract C-660 (work/ludo/orders/660-turn-markers-follow-gate.md,
// items M1 to M5, on top of C-657 G1 to G8): while the X192 gate is shut no seat
// holds the turn, on any marker the screen draws or says, and everything that
// names the new seat switches in the frame the gate opens. Written from the
// contract alone; the implementation does not exist when this file is written.
//
// A real GameScreen over a real RoomController on FakeTransport, every state a
// decoded wire frame shaped as the server sends it under 2026-11 (the harness
// and frame builders follow test/c657_turn_gate_test.dart). Nothing is mocked
// but the socket and the feedback service, which is the recording one from
// test/support/roll_tray_harness.dart.
//
// How each thing is read:
//   - "turnSeat": the `turnSeat` argument of the one LudoBoard in the tree,
//     `tester.widget<LudoBoard>(find.byType(LudoBoard)).turnSeat`.
//   - "the yard glow": a widget keyed `board-turn-yard-<seat>`, which the board
//     draws exactly while `turnSeat == seat` (lib/src/board.dart, the yard
//     layer). The seat name chip highlight keys on the same argument and has no
//     key of its own; turnSeat null covers it.
//   - "my-turn styling": the header chip (`game-header-chip`) carries a border
//     only on my own turn, and the banner text (`game-screen-turn-banner`) is
//     bold only on my own turn. Either one counts as styling.
//   - "the banner": the text of `game-screen-turn-banner`, compared with the
//     localized strings (gameYouAreNextAfter, gameWaitingForPlayer,
//     gameYourTurnRoll, ...) read from the screen's own AppLocalizations.
//   - "the banner colour": the fill of `game-header-chip-dot`, which is the
//     seat colour the header row is drawn in.
//   - "rings": `ringedTokens` of test/support/roll_tray_harness.dart (the
//     `board-legal-ring-0-<token>` keys), the way test/c656_ruleset_screen_test.dart
//     reads them. Every ringed table here has me on seat 0.
//   - "your_turn has fired": the count of FeedbackCue.yourTurn on the recording
//     service after the mount, as in c657.
//   - "a spoken line": a message sent through SemanticsService.sendAnnouncement,
//     captured off a mock handler on SystemChannels.accessibility the way
//     test/c612_first_turn_next_test.dart does.
//
// Time is the test binding's clock, moved only by tester.pump(duration) in
// steps of 10 ms, never pumpAndSettle against a live countdown. "+N ms" is
// counted from the arrival of the frame under test. Every 10 ms step of a
// gated stretch runs the whole marker check, so "in the same frame the gate
// opens" is read as: on the first step where your_turn (or the opponent die's
// full opacity) shows, every other marker already shows the new seat, and on
// every earlier step none does. There is no seed: every case is a fixed list of
// frames. A failure line names the case, the locale, the motion mode, the
// ruleset, the step in ms since the arrival, what was expected, what was
// observed, and every frame pushed so far, which is the whole reproduction.
// Rerun one case with
//
//   flock /tmp/ludo-suite.lock flutter test test/c660_turn_markers_gate_test.dart \
//     --plain-name '<case name>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/board.dart' show LudoBoard;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart' show GameScreen;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const String _ruleset = '2026-11';

/// One pump. Every moment below is known to within this.
const int _stepMs = 10;

/// One frame of slack for "open by T".
const int _frameMs = 16;

const int _budgetMs = 45000;

/// The two-seat table of c657: me on seat 0, Bob on seat 2.
const int _me = 0;
const int _opp = 2;

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _chipKey = Key('game-header-chip');
const Key _chipDotKey = Key('game-header-chip-dot');

const String _yardGlowPrefix = 'board-turn-yard-';

// --- wire frames, shaped as the server sends them -------------------------------

int _idSeq = 0;

String _wire(String type, Map<String, Object?> data, {String? re}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c660t-srv-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

/// One seat of a table: its number, its name and its four token progresses.
class _P {
  const _P(this.seat, this.name, this.tokens);

  final int seat;
  final String name;
  final List<int> tokens;
}

Map<String, Object?> _seatJson(_P p, {required bool ruleset}) =>
    <String, Object?>{
      'seat': p.seat,
      'name': p.name,
      'connected': true,
      'tokens': p.tokens,
      'client_seed': null,
      'seed_origin': null,
      'drought': ?(ruleset ? 0 : null),
    };

Map<String, Object?> _roomJson({
  required String? ruleset,
  required Map<String, Object?>? turn,
  required List<_P> seats,
  int seq = 1,
  String state = 'PLAYING',
  Map<String, Object?>? rematch,
}) {
  final bool on = ruleset != null;
  return <String, Object?>{
    'code': 'K7M2QP',
    'state': state,
    'host_seat': 0,
    'players': seats.length,
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
      for (final _P p in seats) _seatJson(p, ruleset: on),
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

/// The pushed `turn` frame for an `await_roll` turn; `grace_ms` as section 29
/// rule 3 puts it when the turn passed under 2026-11.
Map<String, Object?> _turnFrame(int seat, {int? grace}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': _budgetMs,
  'queue': <int>[],
  'grace_ms': ?grace,
};

/// The pushed `turn` frame for an `await_move` turn, as in c655 N5
/// (turn-grace-await-move). A yard release (PROTOCOL 28 rule 2) has no `value`,
/// the releasable tokens in `legal`, and `release: true`.
Map<String, Object?> _moveTurn(
  int seat, {
  required List<int> legal,
  required int face,
  required int grace,
  bool release = false,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_move',
  'deadline_ms': _budgetMs,
  'k': 1,
  'value': ?(release ? null : face),
  'legal': legal,
  'queue': <int>[face],
  'release': ?(release ? true : null),
  'grace_ms': grace,
};

/// My token 0 stands where the opponent's token 0 lands: its progress 16 is
/// square 42 of the track, which is my progress 42.
const List<int> _mineCapturable = <int>[42, 5, 20, -1];
const List<int> _mineOpen = <int>[10, 5, 20, -1];
const List<int> _mineYard = <int>[-1, -1, -1, -1];
const List<int> _theirsAtTen = <int>[10, -1, -1, -1];

List<_P> _pair(List<int> mine, List<int> theirs) => <_P>[
  _P(_me, 'Sam', mine),
  _P(_opp, 'Bob', theirs),
];

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

// --- the plan of one case ---------------------------------------------------------

typedef _Line = String Function(AppLocalizations loc);

/// What the markers must say once the gate opens and while it is shut.
class _Plan {
  const _Plan({
    required this.newSeat,
    required this.prevSeat,
    this.shutBanner,
    this.openBanner,
    this.openByCue = true,
    this.pulse = true,
  });

  /// The seat the `turn` frame names.
  final int newSeat;

  /// The seat whose turn just ended; null on a mount, where no turn ended
  /// on this screen (the contract names no colour for that case).
  final int? prevSeat;

  /// The exact banner while shut; null reads only that no action is named.
  final _Line? shutBanner;

  /// The exact banner once open; null reads nothing.
  final _Line? openBanner;

  /// Opening is read off `your_turn` (my seat) when true, off the die's pulse
  /// when false (a mount inside a grace plays no cue, C-442 D4').
  final bool openByCue;

  /// Whether my die pulses once open: only on an await_roll turn, an
  /// await_move turn has no roll to invite.
  final bool pulse;
}

// --- one mounted table ------------------------------------------------------------

class _G {
  _G({
    required this.tester,
    required this.drive,
    required this.scenario,
    required this.locale,
    required this.reduced,
    required this.ruleset,
    required this.me,
    required this.plan,
    required this.spoken,
  }) : transports = <FakeTransport>[drive.transport];

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;
  final Locale locale;
  final bool reduced;
  final String? ruleset;
  final int me;
  final _Plan? plan;
  final List<FakeTransport> transports;
  final List<String> frames = <String>[];

  /// Every line sent through SemanticsService.sendAnnouncement, in order.
  final List<String> spoken;

  int now = 0;
  int t0 = 0;
  int baseYours = 0;

  int get rel => now - t0;
  void mark() => t0 = now;

  String get motion => reduced ? 'reduced-motion' : 'full-motion';

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  int get yours => cueCount(drive.feedback, FeedbackCue.yourTurn) - baseYours;

  List<String> get cueIds => <String>[
    for (final FeedbackCue c in drive.feedback.recorded) c.id,
  ];

  // --- reads ---

  int? get turnSeat {
    final Finder f = find.byType(LudoBoard);
    expect(
      f,
      findsOneWidget,
      reason: 'fixture: exactly one LudoBoard in the tree to read turnSeat off',
    );
    return tester.widget<LudoBoard>(f).turnSeat;
  }

  String? get banner {
    final Finder f = find.byKey(_bannerKey);
    return tester.any(f) ? tester.widget<Text>(f).data : null;
  }

  bool get chipBordered {
    final Finder f = find.byKey(_chipKey);
    if (!tester.any(f)) {
      return false;
    }
    final BoxDecoration d =
        tester.widget<DecoratedBox>(f).decoration as BoxDecoration;
    return d.border != null;
  }

  bool get bannerBold {
    final Finder f = find.byKey(_bannerKey);
    return tester.any(f) &&
        tester.widget<Text>(f).style?.fontWeight == FontWeight.w700;
  }

  /// Either signal of the header's my-turn styling.
  bool get myTurnStyled => chipBordered || bannerBold;

  Color? get chipColour {
    final Finder f = find.byKey(_chipDotKey);
    if (!tester.any(f)) {
      return null;
    }
    final BoxDecoration d =
        tester.widget<DecoratedBox>(f).decoration as BoxDecoration;
    return d.color;
  }

  List<int> get yardGlows => <int>[
    for (int seat = 0; seat < 4; seat++)
      if (tester.any(find.byKey(Key('$_yardGlowPrefix$seat')))) seat,
  ];

  bool get pulsing => find
      .descendant(
        of: find.byKey(bigDieKey),
        matching: find.byKey(const Key('game-die-pulse')),
      )
      .evaluate()
      .isNotEmpty;

  double dieOpacity(int seat) => _opacityOf(tester, seatDieKey(seat));

  List<Map<String, Object?>> get moves => <Map<String, Object?>>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (frameType(s) == 'move') frameData(s),
  ];

  int get rolls => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (frameType(s) == 'roll') s,
  ].length;

  int spokenCount(String line) => spoken.where((String s) => s == line).length;

  /// The gate has opened: my seat's `your_turn` has fired (or the die pulses,
  /// when the plan reads the pulse), or another seat's die is at full opacity.
  bool get isOpen {
    final _Plan p = plan!;
    if (p.newSeat == me) {
      return p.openByCue ? yours > 0 : pulsing;
    }
    return dieOpacity(p.newSeat) >= 0.99;
  }

  String get observed {
    final StringBuffer b = StringBuffer()
      ..write('turnSeat ${turnSeat ?? 'null'}, banner "${banner ?? 'n/a'}", ')
      ..write('chip border $chipBordered, banner bold $bannerBold, ')
      ..write('chip colour ${chipColour ?? 'n/a'}, ')
      ..write('yard glows $yardGlows, rings ${ringedTokens(tester)}, ')
      ..write('your_turn fired $yours time(s), die pulse $pulsing, ')
      ..write('moves sent ${moves.length}, rolls sent $rolls, ')
      ..write('spoken $spoken, cues $cueIds');
    return b.toString();
  }

  String why(String step, String expected) =>
      'C-660t "$scenario" [${locale.languageCode}, $motion, ruleset '
      '${ruleset ?? 'absent'}] at +${rel}ms ($step): expected $expected; '
      'observed $observed. Frames pushed (@ms since the mark): '
      '${frames.isEmpty ? '<none>' : frames.join(' -> ')}. Fixed frames, no '
      'seed: rerun with flock /tmp/ludo-suite.lock flutter test '
      "test/c660_turn_markers_gate_test.dart --plain-name '$scenario'.";

  // --- driving ---

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

  /// Pumps to [ms] with the whole marker check at every step.
  Future<void> advanceSampled(int ms, String step, {void Function()? also}) =>
      advanceTo(
        ms,
        each: () {
          sample('$step (sampled)');
          also?.call();
        },
      );

  /// Pumps with the marker check until the gate is seen open or [limitMs] has
  /// passed; returns the ms at which it was seen open, or null.
  Future<int?> advanceUntilOpen(
    int limitMs,
    String step, {
    void Function()? also,
    bool check = true,
  }) async {
    while (rel < limitMs) {
      await advanceTo(rel + _stepMs);
      if (check) {
        sample('$step (sampled)');
      }
      also?.call();
      if (isOpen) {
        return rel;
      }
    }
    return null;
  }

  // --- the marker checks ---

  /// The marker check of one step: shut markers while the gate is shut, open
  /// markers from the first step it shows open.
  void sample(String step) {
    if (isOpen) {
      expectOpenMarkers(step);
    } else {
      expectShutMarkers(step);
    }
  }

  static const List<String> _actionLines = <String>[
    'gameYourTurnRoll',
    'gameYourTurnMove',
    'gameAutoMoving',
    'gameYourTurnStale',
    'gameYourTurnTimeUp',
    'gameRollAgainSix',
    'gameRollAgainCapture',
    'gameRollAgainHome',
  ];

  List<String> _actionTexts(AppLocalizations l) => <String>[
    l.gameYourTurnRoll,
    l.gameYourTurnMove,
    l.gameAutoMoving,
    l.gameYourTurnStale,
    l.gameYourTurnTimeUp,
    l.gameRollAgainSix,
    l.gameRollAgainCapture,
    l.gameRollAgainHome,
  ];

  /// M2 and M3: no seat holds the turn.
  void expectShutMarkers(String step) {
    final _Plan p = plan!;
    expect(
      turnSeat,
      isNull,
      reason: why(
        step,
        'LudoBoard.turnSeat null while the gate is shut (no seat holds the '
        'turn; the new seat is ${p.newSeat})',
      ),
    );
    expect(
      yardGlows,
      isEmpty,
      reason: why(step, 'no yard turn glow on any seat while the gate is shut'),
    );
    expect(
      ringedTokens(tester),
      isEmpty,
      reason: why(step, 'no legal ring on any token while the gate is shut'),
    );
    expect(
      myTurnStyled,
      isFalse,
      reason: why(
        step,
        'no my-turn styling (chip border, bold banner) while the gate is shut',
      ),
    );
    expect(
      yours,
      0,
      reason: why(step, 'no your_turn while the gate is shut, fired $yours'),
    );
    final String? text = banner;
    expect(
      _actionTexts(loc),
      isNot(contains(text)),
      reason: why(
        step,
        'a banner that names no action ($_actionLines) while the gate is '
        'shut, got "$text"',
      ),
    );
    final _Line? want = p.shutBanner;
    if (want != null) {
      expect(
        text,
        want(loc),
        reason: why(step, 'the banner "${want(loc)}" while the gate is shut'),
      );
    }
    final int? prev = p.prevSeat;
    if (p.newSeat == me && prev != null) {
      expect(
        chipColour,
        LudoColors.seats[prev],
        reason: why(
          step,
          'the banner drawn in the colour of seat ${p.prevSeat}, the seat '
          'whose turn just ended, not in my own',
        ),
      );
    }
  }

  /// M5: the new seat everywhere, in the same step.
  void expectOpenMarkers(String step) {
    final _Plan p = plan!;
    expect(
      turnSeat,
      p.newSeat,
      reason: why(
        step,
        'LudoBoard.turnSeat ${p.newSeat} in the step the gate opens',
      ),
    );
    expect(
      yardGlows,
      <int>[p.newSeat],
      reason: why(
        step,
        'the yard turn glow on seat ${p.newSeat} only, in the step the gate '
        'opens',
      ),
    );
    expect(
      myTurnStyled,
      p.newSeat == me,
      reason: why(
        step,
        p.newSeat == me
            ? 'my-turn styling on in the step the gate opens'
            : 'no my-turn styling on another seat\'s turn',
      ),
    );
    final _Line? want = p.openBanner;
    if (want != null) {
      expect(
        banner,
        want(loc),
        reason: why(step, 'the banner "${want(loc)}" in the step it opens'),
      );
    }
    if (p.newSeat == me) {
      expect(
        chipColour,
        LudoColors.seats[me],
        reason: why(step, 'the header drawn in my seat colour once open'),
      );
      if (p.openByCue) {
        expect(
          yours,
          1,
          reason: why(step, 'your_turn fired exactly once at the opening'),
        );
        if (!reduced && p.pulse) {
          expect(
            pulsing,
            isTrue,
            reason: why(step, 'my die pulsing in the step the gate opens'),
          );
        }
      }
    }
  }

  // --- taps ---

  Future<int> tapDie() async {
    final int before = rolls;
    await tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
    await tester.pump();
    return rolls - before;
  }

  /// A tap on token [token] of seat 0: the moves it put on the wire and the
  /// cue ids it added.
  Future<(List<Map<String, Object?>>, List<String>)> tapToken(int token) async {
    final Finder f = find.byKey(tokenHitKey(0, token));
    expect(
      tester.any(f),
      isTrue,
      reason: why('tap on token $token', 'a hit target for token $token'),
    );
    final int movesBefore = moves.length;
    final int cuesBefore = drive.feedback.recorded.length;
    await tester.tap(f, warnIfMissed: false);
    await tester.pump();
    return (
      moves.skip(movesBefore).toList(),
      <String>[
        for (final FeedbackCue c in drive.feedback.recorded.skip(cuesBefore))
          c.id,
      ],
    );
  }
}

/// The opacity a seat die paints at: the product of every Opacity,
/// AnimatedOpacity and FadeTransition on the key's own element and above it,
/// up to the LudoBoard. Copied from test/seat_die_test.dart (_opacityOf), as
/// c657 does.
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

/// Connects, mounts GameScreen for [me] on [turn], settles one second (the
/// mount's own cues land) and takes the baseline the case counts from.
Future<_G> _open(
  WidgetTester tester, {
  required String scenario,
  required Map<String, Object?> turn,
  required List<_P> seats,
  int me = _me,
  _Plan? plan,
  Locale locale = _en,
  bool reduced = false,
  String? ruleset = _ruleset,
  bool settle = true,
}) async {
  phoneSurface(tester);
  final List<String> spoken = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        spoken.add(data['message'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c660t.invalid/ws'),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: seats.length,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _wire('seat_assigned', <String, Object?>{
      'seat': me,
      'seat_token': 'tok-$me',
    }),
  );
  transport.pushText(
    _wire(
      'room',
      _roomJson(ruleset: ruleset, turn: turn, seats: seats),
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
    me: me,
    plan: plan,
    spoken: spoken,
  );
  if (settle) {
    await tester.pump(const Duration(seconds: 1));
  }
  g.baseYours = cueCount(drive.feedback, FeedbackCue.yourTurn);
  g.mark();
  return g;
}

typedef _Body = Future<void> Function(_G g);

/// One testWidgets named C-660t plus the case name and the locale. The screen
/// and the controller are released whatever [body] does.
void _case(
  String name,
  _Body body, {
  required Map<String, Object?> turn,
  required List<_P> seats,
  int me = _me,
  _Plan? plan,
  Locale locale = _en,
  bool reduced = false,
  String? ruleset = _ruleset,
  bool settle = true,
}) {
  final String full = 'C-660t $name [${locale.languageCode}]';
  testWidgets(full, (WidgetTester tester) async {
    final _G g = await _open(
      tester,
      scenario: full,
      turn: turn,
      seats: seats,
      me: me,
      plan: plan,
      locale: locale,
      reduced: reduced,
      ruleset: ruleset,
      settle: settle,
    );
    try {
      await body(g);
    } finally {
      await releaseGame(g.tester, g.drive);
    }
  });
}

/// The opponent's capture of my token 0 over six squares, then the turn to my
/// seat with grace_ms 1700 (the server's own figure for that move).
Future<void> _captureThenMyTurn(_G g, {int grace = 1700}) async {
  g.mark();
  await g.push('moved', _oppWalk(10, 16, capture: true));
  await g.push('turn', _turnFrame(_me, grace: grace));
}

String _bobNext(AppLocalizations l) => l.gameYouAreNextAfter('Bob');
String _waitBob(AppLocalizations l) => l.gameWaitingForPlayer('Bob');
String _rollLine(AppLocalizations l) => l.gameYourTurnRoll;
String _moveLine(AppLocalizations l) => l.gameYourTurnMove;

const _Plan _myTurnAfterBob = _Plan(
  newSeat: _me,
  prevSeat: _opp,
  shutBanner: _bobNext,
  openBanner: _rollLine,
);

void main() {
  // ============================================================================
  // 1. M2, M3, M5: the contract's own example, a six-square capture, grace 1700.
  // ============================================================================
  _case(
    '1 opponent captures my token, turn to me with grace_ms 1700: turnSeat '
    'null, "You\'re next, after Bob" and no my-turn styling at +100 and +1100; '
    'everything switches in the step your_turn fires',
    (_G g) async {
      await _captureThenMyTurn(g);
      g.sample('the frames just arrived');
      await g.advanceSampled(100, 'to +100 ms');
      g.expectShutMarkers('+100 ms');
      await g.advanceSampled(1100, 'to +1100 ms');
      g.expectShutMarkers('+1100 ms');
      final int? at = await g.advanceUntilOpen(1700 + _frameMs, 'to 1700 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '1700 ms plus one frame',
          'the gate open by grace_ms (1700), never later',
        ),
      );
      g.expectOpenMarkers('the step your_turn fired');
      await g.advanceSampled(g.rel + 3000, 'after the opening');
      expect(
        g.yours,
        1,
        reason: g.why('3 s after the opening', 'your_turn still exactly once'),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    seats: _pair(_mineCapturable, _theirsAtTen),
    plan: _myTurnAfterBob,
  );

  // ============================================================================
  // 2. M2, M5: the other side, I move and the turn passes to the opponent.
  // ============================================================================
  _case(
    '2 my four-square move passes the turn to Bob with grace_ms 1060: on my '
    'phone turnSeat is null until the opening, then Bob; my banner never names '
    'an action',
    (_G g) async {
      g.mark();
      await g.push('moved', movedFrame(_me, 0, 10, 14));
      await g.push('turn', _turnFrame(_opp, grace: 1060));
      g.sample('the frames just arrived');
      await g.advanceSampled(300, 'to +300 ms');
      g.expectShutMarkers('+300 ms');
      await g.advanceSampled(900, 'to +900 ms');
      g.expectShutMarkers('+900 ms');
      final int? at = await g.advanceUntilOpen(1060 + _frameMs, 'to 1060 ms');
      expect(
        at,
        isNotNull,
        reason: g.why(
          '1060 ms plus one frame',
          'the opponent die at full opacity by grace_ms (1060)',
        ),
      );
      g.expectOpenMarkers('the step the opponent die lights');
      await g.advanceSampled(g.rel + 2000, 'after the opening');
    },
    turn: _awaitMove(_me, 4, const <int>[0]),
    seats: _pair(_mineOpen, _theirsAtTen),
    plan: const _Plan(
      newSeat: _opp,
      prevSeat: _me,
      shutBanner: _waitBob,
      openBanner: _waitBob,
    ),
  );

  // ============================================================================
  // 3. M2, M4, M5: an await_move turn for my seat behind a shut gate.
  // ============================================================================
  _case(
    '3a await_move turn to my seat, grace_ms 1060: no ring on my tokens while '
    'shut, a token tap sends no move and gives what a non-legal token gives, '
    'after the opening the rings are up and a tap sends one move',
    (_G g) async {
      g.mark();
      await g.push('moved', _oppWalk(10, 14));
      await g.push(
        'turn',
        _moveTurn(_me, legal: const <int>[0, 1], face: 3, grace: 1060),
      );
      g.sample('the frames just arrived');
      await g.advanceSampled(300, 'to +300 ms');
      final (List<Map<String, Object?>> shutMoves, List<String> shutCues) =
          await g.tapToken(0);
      g.expectShutMarkers('after a tap on token 0 while shut');
      expect(
        shutMoves,
        isEmpty,
        reason: g.why(
          'a tap on token 0 at +300 ms',
          'no move on the wire from a tap while the gate is shut, sent '
              '$shutMoves',
        ),
      );
      await g.advanceSampled(900, 'to +900 ms');
      final (_, List<String> shutCues2) = await g.tapToken(1);
      expect(
        shutCues2,
        shutCues,
        reason: g.why(
          'a second shut tap at +900 ms',
          'the same cues as the first shut tap ($shutCues)',
        ),
      );
      final int? at = await g.advanceUntilOpen(1060 + _frameMs, 'to 1060 ms');
      expect(
        at,
        isNotNull,
        reason: g.why('1060 ms plus one frame', 'the gate open by grace_ms'),
      );
      g.expectOpenMarkers('the opening');
      expect(ringedTokens(g.tester), <int>[
        0,
        1,
      ], reason: g.why('the opening', 'rings on the legal tokens 0 and 1'));
      final (List<Map<String, Object?>> noMoves, List<String> nonLegalCues) =
          await g.tapToken(2);
      expect(
        noMoves,
        isEmpty,
        reason: g.why('a tap on token 2, not legal', 'no move'),
      );
      expect(
        nonLegalCues,
        <String>[FeedbackCue.invalidTap.id],
        reason: g.why(
          'a tap on token 2, not legal, after the opening',
          'fixture: today\'s cue for a non-legal token is exactly invalid_tap',
        ),
      );
      expect(
        shutCues,
        nonLegalCues,
        reason: g.why(
          'the shut taps',
          'the cues a non-legal token gives today ($nonLegalCues), no new id; '
              'the shut tap gave $shutCues',
        ),
      );
      await g.tapToken(0);
      await g.advanceTo(g.rel + 400);
      expect(
        g.moves,
        hasLength(1),
        reason: g.why(
          'a tap on a ringed token',
          'exactly one move on the wire',
        ),
      );
      expect(
        g.moves.single['token'],
        0,
        reason: g.why('a tap on token 0', 'the move names token 0'),
      );
    },
    turn: _awaitMove(_opp, 4, const <int>[0]),
    seats: _pair(_mineOpen, _theirsAtTen),
    plan: const _Plan(
      newSeat: _me,
      prevSeat: _opp,
      shutBanner: _bobNext,
      openBanner: _moveLine,
      pulse: false,
    ),
  );

  _case(
    '3b yard release turn to my seat (all my tokens in the yard, release, '
    'grace_ms 1060): no ring while shut, a tap on a releasable token sends no '
    'move, after the opening the rings are on tokens 1 and 3 and a tap on 3 '
    'sends one move without a face',
    (_G g) async {
      g.mark();
      await g.push('moved', _oppWalk(10, 14));
      await g.push(
        'turn',
        _moveTurn(
          _me,
          legal: const <int>[1, 3],
          face: 4,
          grace: 1060,
          release: true,
        ),
      );
      g.sample('the frames just arrived');
      await g.advanceSampled(300, 'to +300 ms');
      final (List<Map<String, Object?>> shutMoves, List<String> shutCues) =
          await g.tapToken(3);
      g.expectShutMarkers('after a tap on token 3 while shut');
      expect(
        shutMoves,
        isEmpty,
        reason: g.why(
          'a tap on the releasable token 3 at +300 ms',
          'no move while the gate is shut, sent $shutMoves',
        ),
      );
      await g.advanceSampled(800, 'to +800 ms');
      final int? at = await g.advanceUntilOpen(1060 + _frameMs, 'to 1060 ms');
      expect(
        at,
        isNotNull,
        reason: g.why('1060 ms plus one frame', 'the gate open by grace_ms'),
      );
      g.expectOpenMarkers('the opening');
      expect(
        ringedTokens(g.tester),
        <int>[1, 3],
        reason: g.why('the opening', 'rings on the releasable tokens 1 and 3'),
      );
      final (_, List<String> nonLegalCues) = await g.tapToken(0);
      expect(
        shutCues,
        nonLegalCues,
        reason: g.why(
          'the shut tap on token 3',
          'the cues a non-legal token gives today ($nonLegalCues); the shut '
              'tap gave $shutCues',
        ),
      );
      await g.tapToken(3);
      await g.advanceTo(g.rel + 400);
      expect(
        g.moves,
        hasLength(1),
        reason: g.why('a tap on a ringed yard token', 'exactly one move'),
      );
      expect(
        g.moves.single['token'],
        3,
        reason: g.why('the move', 'it names token 3'),
      );
      expect(
        g.moves.single.containsKey('face'),
        isFalse,
        reason: g.why('the release move', 'no face on the move (PROTOCOL 28)'),
      );
    },
    turn: _awaitMove(_opp, 4, const <int>[0]),
    seats: _pair(_mineYard, _theirsAtTen),
    plan: const _Plan(
      newSeat: _me,
      prevSeat: _opp,
      shutBanner: _bobNext,
      openBanner: _moveLine,
      pulse: false,
    ),
  );

  _case(
    '3c C-417 auto-move: one legal token on an await_move turn behind a shut '
    'gate, grace_ms 1700: no move is sent before the opening plus the 1500 ms '
    'hold, exactly one after',
    (_G g) async {
      g.mark();
      await g.push('moved', _oppWalk(10, 16, capture: true));
      await g.push(
        'turn',
        _moveTurn(_me, legal: const <int>[1], face: 3, grace: 1700),
      );
      g.sample('the frames just arrived');
      final int? at = await g.advanceUntilOpen(
        1700 + _frameMs,
        'to 1700 ms',
        also: () => expect(
          g.moves,
          isEmpty,
          reason: g.why(
            'while the gate is shut',
            'no auto-move sent before the opening (the hold starts at the '
                'opening)',
          ),
        ),
      );
      expect(
        at,
        isNotNull,
        reason: g.why('1700 ms plus one frame', 'the gate open by grace_ms'),
      );
      final int opened = g.rel;
      await g.advanceSampled(
        opened + 1500 - 60,
        'inside the hold',
        also: () => expect(
          g.moves,
          isEmpty,
          reason: g.why(
            'inside the hold (opened at +$opened ms)',
            'no auto-move earlier than 1500 ms after the opening',
          ),
        ),
      );
      await g.advanceSampled(opened + 1500 + 400, 'past the hold');
      expect(
        g.moves,
        hasLength(1),
        reason: g.why(
          'opening +1900 ms (opened at +$opened ms)',
          'exactly one auto-move, sent by the hold that started at the opening',
        ),
      );
      expect(
        g.moves.single['token'],
        1,
        reason: g.why('the auto-move', 'it moves the one legal token, 1'),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    seats: _pair(_mineCapturable, _theirsAtTen),
    plan: const _Plan(
      newSeat: _me,
      prevSeat: _opp,
      shutBanner: _bobNext,
      openBanner: null,
      pulse: false,
    ),
  );

  // ============================================================================
  // 4. M3 in Arabic: the contract's own words.
  // ============================================================================
  _case(
    '4 arabic, case 1: the banner reads «أنت التالي بعد Bob» while shut and the '
    'Arabic roll line once open',
    (_G g) async {
      await _captureThenMyTurn(g);
      g.sample('the frames just arrived');
      await g.advanceSampled(100, 'to +100 ms');
      expect(
        g.banner,
        contains('أنت التالي بعد'),
        reason: g.why('+100 ms', 'the banner «أنت التالي بعد Bob» while shut'),
      );
      expect(
        g.banner,
        contains('Bob'),
        reason: g.why('+100 ms', 'the banner naming Bob, who just moved'),
      );
      await g.advanceSampled(1100, 'to +1100 ms');
      expect(
        g.banner,
        contains('أنت التالي بعد'),
        reason: g.why('+1100 ms', 'the banner «أنت التالي بعد Bob» still'),
      );
      final int? at = await g.advanceUntilOpen(1700 + _frameMs, 'to 1700 ms');
      expect(
        at,
        isNotNull,
        reason: g.why('1700 ms plus one frame', 'the gate open by grace_ms'),
      );
      expect(
        g.banner,
        contains('دورك. ارمِ النرد.'),
        reason: g.why(
          'the opening',
          'the Arabic roll line «دورك. ارمِ النرد.»',
        ),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    seats: _pair(_mineCapturable, _theirsAtTen),
    plan: _myTurnAfterBob,
    locale: _ar,
  );

  // ============================================================================
  // 5. M2: I am neither the previous seat nor the new one.
  // ============================================================================
  Future<void> thirdSeatBody(_G g, {required int grace}) async {
    g.mark();
    await g.push('moved', movedFrame(0, 0, 10, 14));
    await g.push('turn', _turnFrame(1, grace: grace));
    g.sample('the frames just arrived');
    await g.advanceSampled(300, 'to +300 ms');
    g.expectShutMarkers('+300 ms');
    await g.advanceSampled(grace - 160, 'late in the grace');
    g.expectShutMarkers('late in the grace');
    final int? at = await g.advanceUntilOpen(grace + _frameMs, 'to the grace');
    expect(
      at,
      isNotNull,
      reason: g.why('${grace + _frameMs} ms', 'the gate open by grace_ms'),
    );
    g.expectOpenMarkers('the step seat 1\'s die lights');
    expect(
      g.turnSeat,
      1,
      reason: g.why('the opening', 'turnSeat on the new seat, 1'),
    );
    await g.advanceSampled(g.rel + 1500, 'after the opening');
  }

  _case(
    '5a three seats, I am seat 2 (next after the new seat 1): turnSeat null '
    'while shut, seat 1 after the opening, banner today\'s line throughout',
    (_G g) => thirdSeatBody(g, grace: 1060),
    turn: _awaitRoll(0),
    seats: const <_P>[
      _P(0, 'Ann', <int>[10, -1, -1, -1]),
      _P(1, 'Bob', _mineYard),
      _P(2, 'Sam', _mineYard),
    ],
    me: 2,
    plan: const _Plan(
      newSeat: 1,
      prevSeat: 0,
      shutBanner: _bobNext,
      openBanner: _bobNext,
    ),
  );

  _case(
    '5b four seats, I am seat 3 (neither previous 0, new 1 nor next 2): '
    'turnSeat null while shut, seat 1 after the opening',
    (_G g) => thirdSeatBody(g, grace: 1060),
    turn: _awaitRoll(0),
    seats: const <_P>[
      _P(0, 'Ann', <int>[10, -1, -1, -1]),
      _P(1, 'Bob', _mineYard),
      _P(2, 'Cara', _mineYard),
      _P(3, 'Sam', _mineYard),
    ],
    me: 3,
    plan: const _Plan(
      newSeat: 1,
      prevSeat: 0,
      shutBanner: _waitBob,
      openBanner: _waitBob,
    ),
  );

  // ============================================================================
  // 6. M1: outside a 2026-11 gate everything follows the frame at once.
  // ============================================================================
  _case(
    '6a 2026-10 room: capture then my turn, a frame carrying grace_ms 1700 is '
    'ignored: turnSeat is my seat at once, banner is the roll line, my-turn '
    'styling is on',
    (_G g) async {
      await _captureThenMyTurn(g);
      for (final int ms in <int>[0, 100, 600, 1200, 1800]) {
        await g.advanceTo(ms);
        expect(
          g.turnSeat,
          _me,
          reason: g.why('+$ms ms', 'turnSeat my seat at once, no gate'),
        );
        expect(
          g.banner,
          g.loc.gameYourTurnRoll,
          reason: g.why('+$ms ms', 'the roll line at once, no gate'),
        );
        expect(
          g.myTurnStyled,
          isTrue,
          reason: g.why('+$ms ms', 'my-turn styling on at once'),
        );
        expect(g.yardGlows, <int>[
          _me,
        ], reason: g.why('+$ms ms', 'the yard glow on my seat at once'));
      }
      expect(
        g.yours,
        1,
        reason: g.why('+1800 ms', 'your_turn fired once, at once'),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    seats: _pair(_mineCapturable, _theirsAtTen),
    ruleset: null,
  );

  _case(
    '6b 2026-10 room: my move then the opponent\'s turn with grace_ms 1060 on '
    'the frame: turnSeat is the opponent at once',
    (_G g) async {
      g.mark();
      await g.push('moved', movedFrame(_me, 0, 10, 14));
      await g.push('turn', _turnFrame(_opp, grace: 1060));
      for (final int ms in <int>[0, 200, 900]) {
        await g.advanceTo(ms);
        expect(
          g.turnSeat,
          _opp,
          reason: g.why('+$ms ms', 'turnSeat the opponent at once, no gate'),
        );
        expect(
          g.myTurnStyled,
          isFalse,
          reason: g.why('+$ms ms', 'no my-turn styling on his turn'),
        );
      }
    },
    turn: _awaitMove(_me, 4, const <int>[0]),
    seats: _pair(_mineOpen, _theirsAtTen),
    ruleset: null,
  );

  _case(
    '6c 2026-10 room, await_move turn to my seat after the opponent\'s move: '
    'rings at once, a tap on a legal token sends one move, a tap on a '
    'non-legal one sends none (the baseline the gated case compares with)',
    (_G g) async {
      g.mark();
      await g.push('moved', _oppWalk(10, 14));
      await g.push('turn', <String, Object?>{
        'seat': _me,
        'phase': 'await_move',
        'deadline_ms': _budgetMs,
        'k': 1,
        'value': 3,
        'legal': <int>[0, 1],
        'queue': <int>[3],
        'grace_ms': 1060,
      });
      await g.advanceTo(100);
      expect(ringedTokens(g.tester), <int>[
        0,
        1,
      ], reason: g.why('+100 ms', 'rings on tokens 0 and 1 at once'));
      expect(
        g.turnSeat,
        _me,
        reason: g.why('+100 ms', 'turnSeat my seat at once'),
      );
      final (List<Map<String, Object?>> none, List<String> cues) = await g
          .tapToken(2);
      expect(
        none,
        isEmpty,
        reason: g.why('a tap on non-legal token 2', 'no move'),
      );
      expect(
        cues,
        <String>[FeedbackCue.invalidTap.id],
        reason: g.why(
          'a tap on non-legal token 2',
          'today\'s cue for a non-legal token is exactly invalid_tap',
        ),
      );
      await g.tapToken(0);
      await g.advanceTo(g.rel + 400);
      expect(
        g.moves,
        hasLength(1),
        reason: g.why('a tap on a ringed token', 'exactly one move'),
      );
    },
    turn: _awaitMove(_opp, 4, const <int>[0]),
    seats: _pair(_mineOpen, _theirsAtTen),
    ruleset: null,
  );

  // ============================================================================
  // 7. M1: a same-seat turn and the first turn of a game are not gated.
  // ============================================================================
  _case(
    '7a same-seat turn in 2026-11 (my extra roll after a six): turnSeat stays '
    'my seat at every step, no my-turn styling is ever dropped',
    (_G g) async {
      expect(
        g.turnSeat,
        _me,
        reason: g.why('before the frames', 'fixture: turnSeat my seat'),
      );
      void mine() {
        expect(
          g.turnSeat,
          _me,
          reason: g.why('a step', 'turnSeat my seat throughout, no gate'),
        );
        expect(
          g.myTurnStyled,
          isTrue,
          reason: g.why('a step', 'my-turn styling on throughout'),
        );
      }

      g.mark();
      await g.push('moved', movedFrame(_me, 0, 10, 16, extraRoll: true));
      mine();
      await g.push('turn', _turnFrame(_me));
      mine();
      await g.advanceTo(2500, each: mine);
      expect(
        g.yours,
        1,
        reason: g.why('2500 ms', 'your_turn once at once for the owed roll'),
      );
    },
    turn: _awaitMove(_me, 6, const <int>[0]),
    seats: _pair(_mineOpen, _theirsAtTen),
  );

  testWidgets('C-660t 7b the first turn after game_started (a rematch) is not '
      'gated: turnSeat is my seat at once even though the last turn named '
      'another seat [en]', (WidgetTester tester) async {
    const String name =
        'C-660t 7b the first turn after game_started (a rematch) is not '
        'gated: turnSeat is my seat at once even though the last turn named '
        'another seat [en]';
    final List<_P> yard = <_P>[
      const _P(_me, 'Sam', _mineYard),
      const _P(_opp, 'Bob', _mineYard),
    ];
    final _G g = await _open(
      tester,
      scenario: name,
      turn: _awaitRoll(_opp),
      seats: yard,
    );
    try {
      await g.push('game_over', <String, Object?>{
        'winner': _opp,
        'verify_url': 'https://c660t.invalid/verify/1',
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
          seats: yard,
          state: 'LOBBY',
          rematch: <String, Object?>{
            'by': _me,
            'ready': <int>[_me],
          },
        ),
      );
      await g.push('game_started', <String, Object?>{
        'turn': _me,
        'game_id': 'c660t-game-two',
        'client_seeds': '0:sam-seed|2:bob-seed',
      });
      g.baseYours = cueCount(g.drive.feedback, FeedbackCue.yourTurn);
      g.mark();
      await g.push('turn', _turnFrame(_me));
      expect(
        g.turnSeat,
        _me,
        reason: g.why(
          'the first turn arrived',
          'turnSeat my seat at once, no gate on the first turn of a game',
        ),
      );
      expect(
        g.banner,
        g.loc.gameYourTurnRoll,
        reason: g.why('the first turn arrived', 'the roll line at once'),
      );
      expect(
        g.yours,
        1,
        reason: g.why('the first turn arrived', 'your_turn at once'),
      );
    } finally {
      await releaseGame(tester, g.drive);
    }
  });

  // ============================================================================
  // 8. M5: spoken announcements at the opening and once.
  // ============================================================================
  _case(
    '8a the screen\'s one spoken line for my turn (the your_turn cue\'s line) '
    'is not spoken while the gate is shut and is spoken once at the opening',
    (_G g) async {
      final String line = g.loc.gameYourTurnStale;
      await _captureThenMyTurn(g);
      expect(
        g.spokenCount(line),
        0,
        reason: g.why('the frames just arrived', 'the turn line not spoken'),
      );
      final int? at = await g.advanceUntilOpen(
        1700 + _frameMs,
        'to 1700 ms',
        check: false,
        also: () {
          if (g.yours == 0) {
            expect(
              g.spokenCount(line),
              0,
              reason: g.why(
                'while shut',
                'the turn line "$line" not spoken before the opening',
              ),
            );
          }
        },
      );
      expect(
        at,
        isNotNull,
        reason: g.why('1700 ms plus one frame', 'the gate open by grace_ms'),
      );
      await g.advanceTo(g.rel + 3000);
      expect(
        g.spokenCount(line),
        1,
        reason: g.why(
          'after the opening',
          'the turn line "$line" spoken exactly once',
        ),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    seats: _pair(_mineCapturable, _theirsAtTen),
    plan: _myTurnAfterBob,
  );

  _case(
    '8b three seats, the turn passes to seat 1 and I am seat 2: "You\'re next" '
    'is not spoken while the gate is shut, is spoken by the opening and once',
    (_G g) async {
      final String line = g.loc.gameYouAreNextAnnounce;
      expect(
        g.spokenCount(line),
        0,
        reason: g.why('the mount', 'fixture: nothing spoken yet'),
      );
      g.mark();
      await g.push('moved', movedFrame(0, 0, 10, 14));
      await g.push('turn', _turnFrame(1, grace: 1060));
      expect(
        g.spokenCount(line),
        0,
        reason: g.why(
          'the frames just arrived',
          '"$line" not spoken while the gate is shut',
        ),
      );
      final int? at = await g.advanceUntilOpen(
        1060 + _frameMs,
        'to 1060 ms',
        check: false,
        also: () {
          if (!g.isOpen) {
            expect(
              g.spokenCount(line),
              0,
              reason: g.why(
                'while shut',
                '"$line" not spoken before the opening',
              ),
            );
          }
        },
      );
      expect(
        at,
        isNotNull,
        reason: g.why('1060 ms plus one frame', 'the gate open by grace_ms'),
      );
      await g.advanceTo(g.rel + 2 * _frameMs);
      expect(
        g.spokenCount(line),
        1,
        reason: g.why(
          'two frames after the opening',
          '"$line" spoken at the opening',
        ),
      );
      await g.advanceTo(g.rel + 3000);
      expect(
        g.spokenCount(line),
        1,
        reason: g.why('3 s later', '"$line" spoken once, not again'),
      );
    },
    turn: _awaitRoll(0),
    seats: const <_P>[
      _P(0, 'Ann', <int>[10, -1, -1, -1]),
      _P(1, 'Bob', _mineYard),
      _P(2, 'Sam', _mineYard),
    ],
    me: 2,
    plan: const _Plan(
      newSeat: 1,
      prevSeat: 0,
      shutBanner: _bobNext,
      openBanner: _bobNext,
    ),
  );

  // ============================================================================
  // 9. C-657 G7 and M5: a rolled for my seat inside a shut gate opens it at once.
  // ============================================================================
  _case(
    '9 a rolled for my seat 300 ms into a shut gate: the gate opens at once and '
    'turnSeat, rings and banner switch to me in that same step',
    (_G g) async {
      await _captureThenMyTurn(g);
      await g.advanceSampled(250, 'before the rolled');
      g.expectShutMarkers('+250 ms');
      await g.advanceSampled(300, 'to the rolled');
      await g.push('rolled', rolledFrame(_me, 4, 1, legal: const <int>[1, 2]));
      await g.advanceTo(g.rel + _frameMs);
      expect(
        g.turnSeat,
        _me,
        reason: g.why(
          'the rolled arrived',
          'turnSeat my seat: the rolled ended the gate',
        ),
      );
      expect(ringedTokens(g.tester), <int>[
        1,
        2,
      ], reason: g.why('the rolled arrived', 'rings on the legal tokens 1, 2'));
      expect(
        g.myTurnStyled,
        isTrue,
        reason: g.why('the rolled arrived', 'my-turn styling on'),
      );
      expect(
        g.banner,
        isNot(g.loc.gameYouAreNextAfter('Bob')),
        reason: g.why('the rolled arrived', 'no "next after" line any more'),
      );
      await g.advanceTo(1700 + 300);
      expect(
        g.turnSeat,
        _me,
        reason: g.why('past the old gate time', 'turnSeat still my seat'),
      );
      expect(
        g.yours,
        1,
        reason: g.why('past the old gate time', 'your_turn exactly once'),
      );
    },
    turn: _awaitMove(_opp, 6, const <int>[0]),
    seats: _pair(_mineCapturable, _theirsAtTen),
    plan: _myTurnAfterBob,
  );

  // ============================================================================
  // 10. M2: a resume inside a grace (C-657 G6).
  // ============================================================================
  _case(
    '10 relaunch: a mount over a snapshot whose turn is mine with grace_ms 660: '
    'turnSeat null and no my-turn styling inside the grace, my seat once it '
    'has run out',
    (_G g) async {
      await g.advanceSampled(300, 'to +300 ms');
      g.expectShutMarkers('+300 ms');
      await g.advanceSampled(600, 'to +600 ms');
      g.expectShutMarkers('+600 ms');
      final int? at = await g.advanceUntilOpen(660 + _frameMs, 'to 660 ms');
      expect(
        at,
        isNotNull,
        reason: g.why('660 ms plus one frame', 'the gate open (pulse) by 660'),
      );
      g.expectOpenMarkers('the opening');
      await g.advanceSampled(g.rel + 1500, 'after the opening');
    },
    turn: <String, Object?>{
      'seat': _me,
      'phase': 'await_roll',
      'deadline_ms': _budgetMs,
      'k': 3,
      'grace_ms': 660,
    },
    seats: _pair(_mineOpen, _theirsAtTen),
    plan: const _Plan(
      newSeat: _me,
      prevSeat: null,
      openBanner: _rollLine,
      openByCue: false,
    ),
    settle: false,
  );

  // ============================================================================
  // 11. M5 under reduced motion: (a) opens it before grace_ms.
  // ============================================================================
  _case(
    '11 reduced motion, four-square walk, grace_ms 1060: the gate opens by (a) '
    'before grace_ms and every marker switches in that step',
    (_G g) async {
      g.mark();
      await g.push('moved', _oppWalk(10, 14));
      await g.push('turn', _turnFrame(_me, grace: 1060));
      g.sample('the frames just arrived');
      final int? at = await g.advanceUntilOpen(1060 + _frameMs, 'to 1060 ms');
      expect(
        at,
        isNotNull,
        reason: g.why('1060 ms plus one frame', 'the gate open by grace_ms'),
      );
      g.expectOpenMarkers('the opening');
      await g.advanceSampled(g.rel + 1500, 'after the opening');
    },
    turn: _awaitMove(_opp, 4, const <int>[0]),
    seats: _pair(_mineOpen, _theirsAtTen),
    plan: _myTurnAfterBob,
    reduced: true,
  );
}
