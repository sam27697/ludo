// Recording script for one two-seat game, Priya (seat 0, the host) against
// Karim (seat 2). A two-player room is seated [0, 2]. The locale comes
// from MOTION_LOCALE, the seat this device plays from MOTION_SEAT (0 or
// 2). Order 289 records the screen; this file only plays the game and
// holds still, in real time, through each animation.
// It asserts the facts that keep that script honest, not pixels.
//
// The game plays to a winner. Seat 2 captures seat 0, then seat 0
// captures seat 2, and one of seat 0's tokens reaches home on a move
// that earns another roll before the winning move. Faces, queues and
// legal sets were accepted by package:ludo_engine for seats [0, 2]
// with blocks off, capture bonus, home bonus and the roll queue, and
// every recorded step matched a fresh replay of that engine.
//
// The harness and the frame builders started as copies of
// integration_test/screenshots_test.dart. Helpers there are private.
// Nothing here takes a screenshot.
//
// pumpAndSettle is used once, on the home screen, before Create Room
// can mount LobbyScreen. After that every pump is bounded: LobbyScreen's
// progress indicator and the pulsing die never settle.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/board.dart'
    show kCaptureFlightDuration, kTokenStepDuration;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState, TurnPhase;
import 'package:ludo_client/src/room_code.dart' show isValidRoomCode;
import 'package:ludo_client/src/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/net/fake_transport.dart';

const String _testUrl = 'wss://motion-test.invalid/ws';

// 16 lowercase hex characters, the width room.dart documents for game_id.
const String _gameId = 'mvt288mvt288mvt2';

// Seat seeds joined the way room.dart builds client_seeds: `seat:seed`
// in ascending seat order, separated by `|`.
const String _clientSeeds = '0:srvseedseat0|2:srvseedseat2';

const String _roomCode = 'MVTN88';

const int _deadlineMs = 45000;

int _serverIdSeq = 0;

String _nextServerId() {
  _serverIdSeq += 1;
  return 'motion-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _roomJson({
  required String code,
  String state = 'LOBBY',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  required int seq,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    // Live rooms publish blocks off (PROTOCOL section 4, 2026-10-15).
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _MotionControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }
}

class _MotionHarness extends StatefulWidget {
  const _MotionHarness({required this.controllerFactory});

  final RoomControllerFactory controllerFactory;

  @override
  State<_MotionHarness> createState() => _MotionHarnessState();
}

const String _motionLocale = String.fromEnvironment(
  'MOTION_LOCALE',
  defaultValue: 'en',
);

// Which seat the device plays. '0' (default) is the host, Priya, who
// creates the room. '2' is Karim, the joiner. A two-player room has no
// seat 1. Parsed in the test body, not here, so an out-of-range value
// fails through fail(...) rather than a bare throw before the binding
// exists.
const String _motionSeatRaw = String.fromEnvironment(
  'MOTION_SEAT',
  defaultValue: '0',
);

class _MotionHarnessState extends State<_MotionHarness> {
  Locale _locale = const Locale(_motionLocale);

  void _toggleLocale() {
    setState(() {
      _locale = _locale.languageCode == 'en'
          ? const Locale('ar')
          : const Locale('en');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(),
      locale: _locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(
        onToggleLocale: _toggleLocale,
        controllerFactory: widget.controllerFactory,
      ),
    );
  }
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder,
  String description, {
  int maxPumps = 200,
  Duration frame = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(frame);
  }
  throw TestFailure(
    'timed out after $maxPumps pumps of $frame each waiting for: '
    '$description',
  );
}

/// Real-time frames. LiveTestWidgetsFlutterBinding.pump waits on a real
/// timer, so the clock and the animation timers advance together.
Future<void> _pumpRealDurationFrames(
  WidgetTester tester, {
  required int frameCount,
  Duration frame = const Duration(milliseconds: 32),
}) async {
  for (var i = 0; i < frameCount; i++) {
    await tester.pump(frame);
  }
}

Future<void> _holdFor(WidgetTester tester, Duration total) async {
  final Stopwatch watch = Stopwatch()..start();
  while (watch.elapsed < total) {
    final Duration left = total - watch.elapsed;
    final Duration slice = left < const Duration(milliseconds: 32)
        ? left
        : const Duration(milliseconds: 32);
    await tester.pump(slice);
  }
}

Future<void> _holdUntil(
  WidgetTester tester,
  Stopwatch watch,
  Duration mark,
) async {
  while (watch.elapsed < mark) {
    final Duration left = mark - watch.elapsed;
    final Duration slice = left < const Duration(milliseconds: 32)
        ? left
        : const Duration(milliseconds: 32);
    await tester.pump(slice);
  }
}

/// 64 lowercase hex. The client does not read `reveal`
/// (room_controller.dart `_reduceRolled`: not required, not stored).
/// The shape is protocol section 11: 64 lowercase hex characters, one
/// per roll, distinct per `k`.
String _reveal(int k) => k.toRadixString(16).padLeft(64, '0');

void _motion(String name) => debugPrint('MOTION $name');

int _nextSeat(int seat) => seat == 0 ? 2 : 0;

Map<String, Object?> _openingTurn(int seq) => <String, Object?>{
  'seat': 0,
  'phase': 'await_roll',
  'queue': <int>[],
  'deadline_ms': _deadlineMs,
  'seq': seq,
};

sealed class _Step {
  const _Step();
}

class _RollStep extends _Step {
  const _RollStep({
    required this.face,
    required this.queue,
    required this.legal,
    this.legalByFace,
    this.passTo,
    this.passReason,
    this.rollAgain = false,
    this.longWatch = false,
    this.play = false,
    this.noMoveBeat = false,
    this.showBonus = false,
  });

  final int face;

  /// Queue after this roll, as `rolled.queue`. Empty when the roll passes.
  final List<int> queue;
  final List<int> legal;
  final List<Map<String, Object?>>? legalByFace;

  /// Set when the roll passes the turn. The next seat.
  final int? passTo;
  final String? passReason;

  /// A 6 that owes another roll: `turn` for the same seat, `await_roll`.
  final bool rollAgain;

  /// One of the three opponent rolls held for the thrown-die gap.
  final bool longWatch;

  /// This seat's device taps the die. The other seat only watches.
  final bool play;

  /// The one tapped roll that leaves only a dead face.
  final bool noMoveBeat;

  /// The roll earned by a token arriving home.
  final bool showBonus;
}

class _MoveStep extends _Step {
  const _MoveStep({
    required this.token,
    required this.face,
    required this.from,
    required this.to,
    required this.steps,
    this.pickTrayIndex,
    this.play = false,
    this.captured = const <(int, int)>[],
    this.extraRoll = false,
    this.wins = false,
    this.deadPass = false,
    this.stayQueue,
    this.stayValue,
    this.stayLegal,
    this.stayLegalByFace,
    this.passTo,
  });

  final int token;
  final int face;
  final int from;
  final int to;

  /// Board steps. One for a yard exit, otherwise `to - from`.
  final int steps;

  /// Tray die to tap before the token, when this face is not the default.
  final int? pickTrayIndex;

  /// This seat's device taps the token.
  final bool play;

  /// Captured `(seat, token)` pairs. Empty when the landing captures nothing.
  final List<(int, int)> captured;

  /// Capture, or a non-winning home: the same seat owes another roll.
  final bool extraRoll;

  /// Last token home. `game_over` follows and no `turn` does.
  final bool wins;

  /// Every face still queued is dead: `turn_passed`, then the next seat.
  final bool deadPass;

  /// Queue left for the same seat. Null when the turn passes or the game ends.
  /// Empty when [extraRoll] leaves nothing queued.
  final List<int>? stayQueue;
  final int? stayValue;
  final List<int>? stayLegal;
  final List<Map<String, Object?>>? stayLegalByFace;
  final int? passTo;
}

class _Turn {
  const _Turn(this.seat, this.steps);

  final int seat;
  final List<_Step> steps;
}

// Seat 0 opens. Each seat taps its one dead roll, and later its one
// queued 6, 6, 3, spending the 3 (tray index 2) before a 6. Setup and
// the march are pushed with no tap. `longWatch` marks the three rolls
// the other seat holds still for.

const List<_Turn> _script = <_Turn>[
  _Turn(0, <_Step>[
    _RollStep(
      face: 5,
      queue: <int>[],
      legal: <int>[],
      passTo: 2,
      passReason: 'no_legal_move',
      play: true,
      noMoveBeat: true,
    ),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
      play: true,
      noMoveBeat: true,
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: -1,
      to: 0,
      steps: 1,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 0,
      to: 6,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[0],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 5, from: 6, to: 11, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 2,
      queue: <int>[6, 2],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: -1,
      to: 0,
      steps: 1,
      stayQueue: <int>[2],
      stayValue: 2,
      stayLegal: <int>[0],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 2,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 2, from: 0, to: 2, steps: 2, passTo: 0),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 4,
      queue: <int>[6, 6, 4],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 4,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 11,
      to: 17,
      steps: 6,
      stayQueue: <int>[6, 4],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 4,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 17,
      to: 23,
      steps: 6,
      stayQueue: <int>[4],
      stayValue: 4,
      stayLegal: <int>[0],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 4,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 4, from: 23, to: 27, steps: 4, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 6,
      queue: <int>[6],
      legal: <int>[],
      rollAgain: true,
      longWatch: true,
      play: true,
    ),
    _RollStep(
      face: 6,
      queue: <int>[6, 6],
      legal: <int>[],
      rollAgain: true,
      longWatch: true,
      play: true,
    ),
    _RollStep(
      face: 3,
      queue: <int>[6, 6, 3],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 3,
          'tokens': <int>[0],
        },
      ],
      longWatch: true,
      play: true,
    ),
    _MoveStep(
      token: 0,
      face: 3,
      from: 2,
      to: 5,
      steps: 3,
      pickTrayIndex: 2,
      play: true,
      stayQueue: <int>[6, 6],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 5,
      to: 11,
      steps: 6,
      play: true,
      stayQueue: <int>[6],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 11,
      to: 17,
      steps: 6,
      play: true,
      passTo: 0,
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: -1,
      to: 0,
      steps: 1,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0, 1],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: 0,
      to: 6,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[0, 1],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0, 1],
        },
      ],
    ),
    _MoveStep(token: 1, face: 5, from: 6, to: 11, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 4,
      queue: <int>[6, 4],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 4,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 4,
      from: 17,
      to: 21,
      steps: 4,
      stayQueue: <int>[6],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
      ],
    ),
    _MoveStep(token: 1, face: 6, from: -1, to: 0, steps: 1, passTo: 0),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0, 1],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: -1,
      to: 0,
      steps: 1,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0, 1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: 0,
      to: 6,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[0, 1, 2],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0, 1, 2],
        },
      ],
    ),
    _MoveStep(token: 2, face: 5, from: 6, to: 11, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 1,
      queue: <int>[1],
      legal: <int>[0, 1],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 1,
          'tokens': <int>[0, 1],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 1,
      from: 0,
      to: 1,
      steps: 1,
      captured: <(int, int)>[(0, 0)],
      extraRoll: true,
      stayQueue: <int>[],
    ),
    _RollStep(
      face: 1,
      queue: <int>[1],
      legal: <int>[0, 1],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 1,
          'tokens': <int>[0, 1],
        },
      ],
    ),
    _MoveStep(token: 1, face: 1, from: 1, to: 2, steps: 1, passTo: 0),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: 11,
      to: 17,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: 17,
      to: 23,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[1, 2],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 5,
      from: 23,
      to: 28,
      steps: 5,
      captured: <(int, int)>[(2, 1)],
      extraRoll: true,
      stayQueue: <int>[],
    ),
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: 28,
      to: 34,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: 34,
      to: 40,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[1, 2],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(token: 1, face: 5, from: 40, to: 45, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 1,
      queue: <int>[1],
      legal: <int>[0],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 1,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 1, from: 21, to: 22, steps: 1, passTo: 0),
  ]),
  _Turn(0, <_Step>[
    _RollStep(
      face: 3,
      queue: <int>[3],
      legal: <int>[1, 2],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 3,
          'tokens': <int>[1, 2],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 3,
      from: 45,
      to: 48,
      steps: 3,
      captured: <(int, int)>[(2, 0)],
      extraRoll: true,
      stayQueue: <int>[],
    ),
    _RollStep(
      face: 6,
      queue: <int>[6],
      legal: <int>[],
      rollAgain: true,
      longWatch: true,
      play: true,
    ),
    _RollStep(
      face: 6,
      queue: <int>[6, 6],
      legal: <int>[],
      rollAgain: true,
      longWatch: true,
      play: true,
    ),
    _RollStep(
      face: 3,
      queue: <int>[6, 6, 3],
      legal: <int>[0, 1, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
        <String, Object?>{
          'face': 3,
          'tokens': <int>[1, 2],
        },
      ],
      longWatch: true,
      play: true,
    ),
    _MoveStep(
      token: 1,
      face: 3,
      from: 48,
      to: 51,
      steps: 3,
      pickTrayIndex: 2,
      play: true,
      stayQueue: <int>[6, 6],
      stayValue: 6,
      stayLegal: <int>[0, 1, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 1, 2, 3],
        },
      ],
    ),
    _MoveStep(
      token: 1,
      face: 6,
      from: 51,
      to: 57,
      steps: 6,
      play: true,
      extraRoll: true,
      stayQueue: <int>[6],
    ),
    _RollStep(
      face: 5,
      queue: <int>[6, 5],
      legal: <int>[0, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
      play: true,
      showBonus: true,
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: 11,
      to: 17,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[2],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(token: 2, face: 5, from: 17, to: 22, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: 22,
      to: 28,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: 28,
      to: 34,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[2],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(token: 2, face: 5, from: 34, to: 39, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 2, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: 39,
      to: 45,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 2, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 2, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 6,
      from: 45,
      to: 51,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[2],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(token: 2, face: 5, from: 51, to: 56, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 1,
      queue: <int>[6, 6, 1],
      legal: <int>[0, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 1,
          'tokens': <int>[2],
        },
      ],
    ),
    _MoveStep(
      token: 2,
      face: 1,
      from: 56,
      to: 57,
      steps: 1,
      extraRoll: true,
      stayQueue: <int>[6, 6],
    ),
    _RollStep(
      face: 1,
      queue: <int>[6, 6, 1],
      legal: <int>[0, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
      ],
      play: true,
      showBonus: true,
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: -1,
      to: 0,
      steps: 1,
      stayQueue: <int>[6, 1],
      stayValue: 6,
      stayLegal: <int>[0, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 1,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 0,
      to: 6,
      steps: 6,
      stayQueue: <int>[1],
      stayValue: 1,
      stayLegal: <int>[0],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 1,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 1, from: 6, to: 7, steps: 1, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 7,
      to: 13,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 13,
      to: 19,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[0],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 5, from: 19, to: 24, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 24,
      to: 30,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 30,
      to: 36,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[0],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(token: 0, face: 5, from: 36, to: 41, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[0, 3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 41,
      to: 47,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[0, 3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 6,
      from: 47,
      to: 53,
      steps: 6,
      deadPass: true,
      passTo: 2,
    ),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 4,
      queue: <int>[6, 6, 4],
      legal: <int>[3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 4,
          'tokens': <int>[0],
        },
      ],
    ),
    _MoveStep(
      token: 0,
      face: 4,
      from: 53,
      to: 57,
      steps: 4,
      extraRoll: true,
      stayQueue: <int>[6, 6],
    ),
    _RollStep(
      face: 1,
      queue: <int>[6, 6, 1],
      legal: <int>[3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
      ],
      play: true,
      showBonus: true,
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: -1,
      to: 0,
      steps: 1,
      stayQueue: <int>[6, 1],
      stayValue: 6,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 1,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 0,
      to: 6,
      steps: 6,
      stayQueue: <int>[1],
      stayValue: 1,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 1,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(token: 3, face: 1, from: 6, to: 7, steps: 1, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 7,
      to: 13,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 13,
      to: 19,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(token: 3, face: 5, from: 19, to: 24, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 24,
      to: 30,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 30,
      to: 36,
      steps: 6,
      stayQueue: <int>[5],
      stayValue: 5,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(token: 3, face: 5, from: 36, to: 41, steps: 5, passTo: 2),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(face: 6, queue: <int>[6], legal: <int>[], rollAgain: true),
    _RollStep(face: 6, queue: <int>[6, 6], legal: <int>[], rollAgain: true),
    _RollStep(
      face: 5,
      queue: <int>[6, 6, 5],
      legal: <int>[3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 41,
      to: 47,
      steps: 6,
      stayQueue: <int>[6, 5],
      stayValue: 6,
      stayLegal: <int>[3],
      stayLegalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[3],
        },
        <String, Object?>{
          'face': 5,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(
      token: 3,
      face: 6,
      from: 47,
      to: 53,
      steps: 6,
      deadPass: true,
      passTo: 2,
    ),
  ]),
  _Turn(2, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[],
      legal: <int>[],
      passTo: 0,
      passReason: 'no_legal_move',
    ),
  ]),
  _Turn(0, <_Step>[
    _RollStep(
      face: 4,
      queue: <int>[4],
      legal: <int>[3],
      legalByFace: <Map<String, Object?>>[
        <String, Object?>{
          'face': 4,
          'tokens': <int>[3],
        },
      ],
    ),
    _MoveStep(token: 3, face: 4, from: 53, to: 57, steps: 4, wins: true),
  ]),
];

bool _sixThenAnotherRoll(List<_Step> steps, int index) {
  final _Step step = steps[index];
  return step is _RollStep &&
      step.face == 6 &&
      index + 1 < steps.length &&
      steps[index + 1] is _RollStep;
}

int _scriptRolls(int seat) {
  var n = 0;
  for (final _Turn turn in _script) {
    if (turn.seat != seat) {
      continue;
    }
    for (final _Step step in turn.steps) {
      if (step is _RollStep) {
        n += 1;
      }
    }
  }
  return n;
}

void _expectScript(List<_Turn> turns) {
  expect(turns, isNotEmpty);
  for (var i = 0; i < turns.length; i++) {
    expect(turns[i].seat, i.isEven ? 0 : 2, reason: 'turn $i');
  }
  final List<List<int>> tokens = <List<int>>[
    for (var seat = 0; seat < 4; seat++) <int>[-1, -1, -1, -1],
  ];
  var rolls = 0;
  var moves = 0;
  final List<(int, List<(int, int)>)> captures = <(int, List<(int, int)>)>[];
  var homes = 0;
  _MoveStep? winning;
  for (final _Turn turn in turns) {
    final List<_Step> steps = turn.steps;
    for (var i = 0; i < steps.length; i++) {
      final _Step step = steps[i];
      if (step is _RollStep) {
        rolls += 1;
        expect(step.passTo != null && step.rollAgain, isFalse);
        if (step.passTo != null) {
          expect(step.passTo, _nextSeat(turn.seat));
          expect(step.queue, isEmpty);
          expect(step.legal, isEmpty);
          expect(step.legalByFace, isNull);
          expect(step.passReason, 'no_legal_move');
        } else if (step.rollAgain) {
          expect(step.face, 6);
          expect(step.legal, isEmpty);
          expect(step.legalByFace, isNull);
          expect(step.queue, isNotEmpty);
        } else {
          expect(step.legalByFace, isNotNull);
          expect(step.legal, isNotEmpty);
          expect(step.queue, isNotEmpty);
        }
        if (step.noMoveBeat) {
          expect(step.passTo, isNotNull);
          expect(step.play, isTrue);
        }
      } else if (step is _MoveStep) {
        moves += 1;
        final int boardSteps = step.from < 0 ? 1 : step.to - step.from;
        expect(step.steps, boardSteps, reason: 'seat ${turn.seat}');
        expect(tokens[turn.seat][step.token], step.from);
        tokens[turn.seat][step.token] = step.to;
        for (final (int capSeat, int capToken) in step.captured) {
          expect(tokens[capSeat][capToken], greaterThanOrEqualTo(0));
          tokens[capSeat][capToken] = -1;
        }
        if (step.captured.isNotEmpty) {
          captures.add((turn.seat, step.captured));
        }
        if (step.to == 57 && step.extraRoll && !step.wins) {
          homes += 1;
        }
        final int endings = <bool>[
          step.wins,
          step.extraRoll,
          step.deadPass,
        ].where((bool flag) => flag).length;
        expect(endings, lessThan(2), reason: 'seat ${turn.seat}');
        final bool ended = endings == 1;
        if (step.wins) {
          expect(winning, isNull);
          winning = step;
          expect(turn.seat, 0);
          expect(step.to, 57);
          expect(step.passTo, isNull);
          expect(step.stayQueue, isNull);
        } else if (step.extraRoll) {
          expect(step.stayQueue, isNotNull);
          expect(step.passTo, isNull);
        } else if (step.deadPass) {
          expect(step.passTo, _nextSeat(turn.seat));
          expect(step.stayQueue, isNull);
        } else if (step.stayQueue != null) {
          expect(step.passTo, isNull);
          expect(step.stayValue, isNotNull);
          expect(step.stayLegal, isNotNull);
          expect(step.stayLegalByFace, isNotNull);
        } else {
          expect(step.passTo, _nextSeat(turn.seat));
        }
        if (step.pickTrayIndex != null) {
          expect(step.play, isTrue);
        }
        expect(ended || step.stayQueue != null || step.passTo != null, isTrue);
      }
    }
  }
  expect(rolls, 79);
  expect(moves, 64);
  expect(tokens[0], <int>[57, 57, 57, 57]);
  expect(tokens[2], <int>[-1, -1, -1, -1]);
  expect(winning, isNotNull);
  expect(homes, greaterThanOrEqualTo(1));
  expect(captures, isNotEmpty);
  expect(captures.first.$1, 2, reason: 'seat 2 captures seat 0 first');
  expect(captures.first.$2.any((pair) => pair.$1 == 0), isTrue);
  expect(
    captures
        .skip(1)
        .any((entry) => entry.$1 == 0 && entry.$2.any((pair) => pair.$1 == 2)),
    isTrue,
    reason: 'seat 0 later captures seat 2',
  );
  for (final int seat in <int>[0, 2]) {
    final List<_Turn> mine = turns
        .where((_Turn turn) => turn.seat == seat)
        .toList();
    final List<_RollStep> noMoves = <_RollStep>[
      for (final _Turn turn in mine)
        for (final _Step step in turn.steps)
          if (step is _RollStep && step.noMoveBeat) step,
    ];
    expect(noMoves, hasLength(1), reason: 'seat $seat owes one dead roll');
    var queued = 0;
    var longWatch = 0;
    var longSixThenRoll = false;
    for (final _Turn turn in mine) {
      final List<_Step> steps = turn.steps;
      for (var i = 0; i < steps.length; i++) {
        final _Step step = steps[i];
        if (step is _RollStep && step.longWatch) {
          longWatch += 1;
          if (_sixThenAnotherRoll(steps, i)) {
            longSixThenRoll = true;
            expect((steps[i + 1] as _RollStep).longWatch, isTrue);
          }
        }
      }
      for (var i = 0; i + 2 < steps.length; i++) {
        final _Step a = steps[i];
        final _Step b = steps[i + 1];
        final _Step c = steps[i + 2];
        if (a is! _RollStep || b is! _RollStep || c is! _RollStep) {
          continue;
        }
        if (a.face != 6 || b.face != 6 || c.face != 3) {
          continue;
        }
        final List<_MoveStep> spent = <_MoveStep>[
          for (final _Step later in steps.skip(i + 3))
            if (later is _MoveStep) later,
        ];
        if (spent.length < 2 || spent[0].face != 3 || spent[1].face != 6) {
          continue;
        }
        queued += 1;
        expect(spent[0].pickTrayIndex, 2);
        expect(a.longWatch, isTrue);
        expect(b.longWatch, isTrue);
        expect(c.longWatch, isTrue);
        expect(a.play, isTrue);
        expect(b.play, isTrue);
        expect(c.play, isTrue);
      }
    }
    expect(queued, 1, reason: 'seat $seat owes one 6, 6, 3 turn');
    expect(longWatch, 3, reason: 'seat $seat names three watched rolls');
    expect(
      longSixThenRoll,
      isTrue,
      reason: 'seat $seat watches a 6 followed at once by another roll',
    );
    final List<_RollStep> watched = <_RollStep>[
      for (final _Turn turn in turns)
        if (turn.seat != seat)
          for (final _Step step in turn.steps)
            if (step is _RollStep) step,
    ];
    expect(watched.length, greaterThanOrEqualTo(3));
    expect(
      watched.where((_RollStep step) => step.longWatch).length,
      3,
      reason: 'seat $seat watches exactly three named opponent rolls',
    );
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records one two-seat game with motion on', (tester) async {
    final int? parsedSeat = int.tryParse(_motionSeatRaw);
    if (parsedSeat != 0 && parsedSeat != 2) {
      fail('MOTION_SEAT must be "0" or "2"; got "$_motionSeatRaw"');
    }
    final int deviceSeat = parsedSeat!;
    _expectScript(_script);

    if (tester
        .binding
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations) {
      fail(
        'animations are disabled on this device; the recording would show '
        'reduced motion',
      );
    }
    _motion('start');

    binding.testTextInput.register();
    await (await SharedPreferences.getInstance()).clear();

    final _MotionControllerFactory factory = _MotionControllerFactory();
    await tester.pumpWidget(_MotionHarness(controllerFactory: factory.call));
    // Home only. LobbyScreen is not on the tree yet.
    await tester.pumpAndSettle();

    final Stopwatch elapsed = Stopwatch()..start();

    _motion('1 lobby');
    expect(find.byType(HomeScreen), findsOneWidget);
    final AppLocalizations homeLoc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    expect(homeLoc.localeName, _motionLocale);

    if (deviceSeat == 0) {
      await _runHostSeat0(tester, factory, homeLoc, elapsed);
    } else {
      await _runJoinerSeat2(tester, factory, homeLoc, elapsed);
    }
  });
}

/// MOTION_SEAT=0. Priya creates the room, starts the game, and plays seat 0.
Future<void> _runHostSeat0(
  WidgetTester tester,
  _MotionControllerFactory factory,
  AppLocalizations homeLoc,
  Stopwatch elapsed,
) async {
  const String hostName = 'Priya';
  await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
  await tester.tap(find.byKey(const Key('home-players-disclosure')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  final Finder selector = find.byKey(const Key('home-players-selector'));
  expect(selector, findsOneWidget);
  await tester.tap(
    find.descendant(of: selector, matching: find.text(homeLoc.homePlayersTwo)),
  );
  await tester.pump();

  await _tapAndAwaitPushedRoute(tester, const Key('create-room-button'));
  expect(factory.controllers, hasLength(1));
  final RoomController controller = factory.controllers.single;
  final FakeTransport transport = factory.transports.single;
  addTearDown(controller.dispose);

  final List<String> createMessages = transport.sentRaw
      .where((String s) => _typeOf(s) == 'create_room')
      .toList();
  expect(createMessages, hasLength(1));
  final Map<String, Object?> createData = _dataOf(createMessages.single);
  expect(createData['name'], hostName);
  expect(createData['players'], 2);
  expect(createData['rules'], <String, Object?>{'capture_bonus': true});
  expect(isValidRoomCode(_roomCode), isTrue);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-motion-288'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: _idOf(createMessages.single),
      data: _roomJson(
        code: _roomCode,
        players: 2,
        hostSeat: 0,
        seats: <Map<String, Object?>>[_seatJson(0, name: hostName)],
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byType(LobbyScreen),
    'LobbyScreen after create_room',
  );

  transport.pushText(
    _frame(
      type: 'player_joined',
      data: <String, Object?>{'seat': 2, 'name': 'Karim', 'seq': 2},
    ),
  );
  await tester.pump();
  expect(find.byKey(const Key('lobby-room-code')), findsOneWidget);
  expect(
    tester.widget<Text>(find.byKey(const Key('lobby-room-code'))).data,
    _roomCode,
  );
  expect(find.byKey(const Key('lobby-seat-0')), findsOneWidget);
  expect(find.byKey(const Key('lobby-seat-2')), findsOneWidget);
  expect(find.byKey(const Key('lobby-seat-1')), findsNothing);
  expect(controller.room!.seats.map((seat) => seat.seat).toList(), <int>[0, 2]);

  final Finder startButton = find.byKey(const Key('lobby-start-button'));
  expect(startButton, findsOneWidget);
  await tester.tap(startButton);
  await tester.pump();
  final List<String> startMessages = transport.sentRaw
      .where((String s) => _typeOf(s) == 'start_game')
      .toList();
  expect(startMessages, hasLength(1));
  final String startId = _idOf(startMessages.single);

  // Protocol 13.1: server seeds, then game_started, then a standalone
  // turn at the next seq. The host's copies of game_started and turn
  // carry re. seat_seed does not. Section 21.3: the opening turn carries
  // phase and an empty queue.
  transport.pushText(
    _frame(
      type: 'seat_seed',
      data: <String, Object?>{
        'seat': 0,
        'client_seed': 'srvseedseat0',
        'origin': 'server',
        'seq': 3,
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'seat_seed',
      data: <String, Object?>{
        'seat': 2,
        'client_seed': 'srvseedseat2',
        'origin': 'server',
        'seq': 4,
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'game_started',
      re: startId,
      data: <String, Object?>{
        'turn': 0,
        'game_id': _gameId,
        'client_seeds': _clientSeeds,
        'seq': 5,
      },
    ),
  );
  transport.pushText(_frame(type: 'turn', re: startId, data: _openingTurn(6)));
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byType(GameScreen),
    'GameScreen after game_started',
  );
  expect(find.byType(LobbyScreen), findsNothing);
  expect(controller.room!.state, RoomState.playing);
  expect(controller.room!.turn!.seat, 0);
  expect(controller.room!.turn!.phase, TurnPhase.awaitRoll);
  expect(controller.room!.turn!.queue, isEmpty);
  expect(controller.hasDesynced, isFalse);

  await _holdFor(tester, const Duration(seconds: 2));

  _motion('2 turn pulse');
  expect(find.byKey(const Key('game-die-pulse')), findsOneWidget);
  expect(controller.room!.turn!.seat, 0);
  expect(controller.room!.turn!.phase, TurnPhase.awaitRoll);
  final int sentAtPulse = transport.sentRaw.length;
  await _holdFor(tester, const Duration(seconds: 3));
  expect(find.byKey(const Key('game-die-pulse')), findsOneWidget);
  expect(
    transport.sentRaw
        .skip(sentAtPulse)
        .where((String s) => _typeOf(s) == 'roll'),
    isEmpty,
  );

  final _Playback playback = _Playback(
    tester: tester,
    transport: transport,
    controller: controller,
    deviceSeat: 0,
    startSeq: 6,
  );
  await playback.playAll(_script);
  expect(controller.room!.state, RoomState.finished);
  expect(controller.room!.winner, 0);
  expect(controller.hasDesynced, isFalse);
  expect(
    controller.room!.seats.firstWhere((seat) => seat.seat == 0).tokens,
    <int>[57, 57, 57, 57],
  );
  playback.expectSent();
  final Finder winner = find.byKey(const Key('game-screen-winner'));
  expect(winner, findsOneWidget);
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  final Text winnerText = tester.widget<Text>(winner);
  final String? shown = winnerText.data ?? winnerText.textSpan?.toPlainText();
  expect(shown, loc.endWinTitle);
  _motion('7 done');

  debugPrint('motion elapsed ${elapsed.elapsed.inMilliseconds}ms');
  // record_motion.sh records in 170s screenrecord chunks and fails the job
  // when the game spills into a second one. The recorder starts when the
  // app process appears, 6 to 10s before this stopwatch on the CI emulator
  // (run 38972919163: 140.4s of video for 131.3s of script), so 150s keeps
  // the game inside the first chunk with room to spare.
  expect(
    elapsed.elapsed,
    lessThan(const Duration(seconds: 150)),
    reason:
        'the script took ${elapsed.elapsed.inMilliseconds}ms after the '
        'app was up; the limit is 150s',
  );
}

/// MOTION_SEAT=2. Karim joins by code. Priya (seat 0, the host) is played
/// by the server. Karim plays seat 2.
Future<void> _runJoinerSeat2(
  WidgetTester tester,
  _MotionControllerFactory factory,
  AppLocalizations homeLoc,
  Stopwatch elapsed,
) async {
  const String hostName = 'Priya';
  const String joinerName = 'Karim';

  await tester.enterText(find.byKey(const Key('home-name-field')), joinerName);
  await tester.enterText(find.byKey(const Key('room-code-field')), _roomCode);
  await _tapAndAwaitPushedRoute(tester, const Key('join-room-button'));

  expect(factory.controllers, hasLength(1));
  final RoomController controller = factory.controllers.single;
  final FakeTransport transport = factory.transports.single;
  addTearDown(controller.dispose);

  final List<String> joinMessages = transport.sentRaw
      .where((String s) => _typeOf(s) == 'join_room')
      .toList();
  expect(
    joinMessages,
    hasLength(1),
    reason:
        'expected LobbyScreen.initState, reached through RoomRoute, to '
        'have sent exactly one join_room request; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  final Map<String, Object?> joinData = _dataOf(joinMessages.single);
  expect(joinData['name'], joinerName);
  expect(joinData['code'], _roomCode);
  final String joinId = _idOf(joinMessages.single);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 2, 'seat_token': 'tok-motion-karim'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: joinId,
      data: _roomJson(
        code: _roomCode,
        players: 2,
        hostSeat: 0,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: hostName),
          _seatJson(2, name: joinerName),
        ],
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byType(LobbyScreen),
    'LobbyScreen after the join_room reply carrying code "$_roomCode"',
  );

  expect(find.byKey(const Key('lobby-room-code')), findsOneWidget);
  expect(
    tester.widget<Text>(find.byKey(const Key('lobby-room-code'))).data,
    _roomCode,
  );
  expect(find.byKey(const Key('lobby-seat-0')), findsOneWidget);
  expect(find.byKey(const Key('lobby-seat-2')), findsOneWidget);
  expect(find.byKey(const Key('lobby-seat-1')), findsNothing);
  expect(controller.room!.seats.map((seat) => seat.seat).toList(), <int>[0, 2]);

  // The joiner's lobby, held on screen before the host starts the game.
  await _holdFor(tester, const Duration(seconds: 2));

  // Protocol 13.1, from the non-host side: server seeds, then
  // game_started, then a standalone turn, none of it carrying `re`.
  // This client never sent start_game. The opening turn carries phase
  // and an empty queue (section 21.3).
  transport.pushText(
    _frame(
      type: 'seat_seed',
      data: <String, Object?>{
        'seat': 0,
        'client_seed': 'srvseedseat0',
        'origin': 'server',
        'seq': 2,
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'seat_seed',
      data: <String, Object?>{
        'seat': 2,
        'client_seed': 'srvseedseat2',
        'origin': 'server',
        'seq': 3,
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'game_started',
      data: <String, Object?>{
        'turn': 0,
        'game_id': _gameId,
        'client_seeds': _clientSeeds,
        'seq': 4,
      },
    ),
  );
  transport.pushText(_frame(type: 'turn', data: _openingTurn(5)));
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(
    tester,
    find.byType(GameScreen),
    'GameScreen after the unprompted game_started push',
  );
  expect(
    find.byType(LobbyScreen),
    findsNothing,
    reason: 'RoomRoute must latch onto GameScreen and never go back',
  );

  final List<String> startMessages = transport.sentRaw
      .where((String s) => _typeOf(s) == 'start_game')
      .toList();
  expect(
    startMessages,
    isEmpty,
    reason:
        'the joiner must never send start_game; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );

  expect(controller.room!.state, RoomState.playing);
  expect(controller.room!.turn!.seat, 0);
  expect(controller.room!.turn!.phase, TurnPhase.awaitRoll);
  expect(controller.room!.turn!.queue, isEmpty);
  expect(controller.hasDesynced, isFalse);

  _motion('2 turn pulse');
  // It is Priya's turn, not Karim's: no pulse on this device's die, and
  // the device sends nothing while it waits.
  expect(find.byKey(const Key('game-die-pulse')), findsNothing);
  expect(controller.room!.turn!.seat, 0);
  expect(controller.room!.turn!.phase, TurnPhase.awaitRoll);
  final int sentAtPulse = transport.sentRaw.length;
  await _holdFor(tester, const Duration(seconds: 2));
  expect(find.byKey(const Key('game-die-pulse')), findsNothing);
  expect(
    transport.sentRaw
        .skip(sentAtPulse)
        .where((String s) => _typeOf(s) == 'roll' || _typeOf(s) == 'move'),
    isEmpty,
  );

  final _Playback playback = _Playback(
    tester: tester,
    transport: transport,
    controller: controller,
    deviceSeat: 2,
    startSeq: 5,
  );
  await playback.playAll(_script);
  expect(controller.room!.state, RoomState.finished);
  expect(controller.room!.winner, 0);
  expect(controller.hasDesynced, isFalse);
  playback.expectSent();

  await _pumpUntilFound(
    tester,
    find.byKey(const Key('end-card-lose')),
    'end-card-lose after game_over',
  );

  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  final Finder winnerTitle = find.byKey(const Key('game-screen-winner'));
  expect(winnerTitle, findsOneWidget);
  final Text winnerText = tester.widget<Text>(winnerTitle);
  final String? shown = winnerText.data ?? winnerText.textSpan?.toPlainText();
  expect(
    shown,
    loc.endLoseTitle(hostName),
    reason:
        'game-screen-winner must show endLoseTitle($hostName) on a loss; '
        'got "$shown"',
  );
  expect(find.byKey(const Key('end-card-lose-line')), findsOneWidget);

  final int seatRolls = _scriptRolls(2);
  final Finder rollsTile = find.byKey(const Key('end-card-stat-rolls'));
  expect(rollsTile, findsOneWidget);
  expect(
    find.descendant(of: rollsTile, matching: find.text('$seatRolls')),
    findsOneWidget,
    reason:
        'end-card-stat-rolls must show $seatRolls, the count of seat-2 '
        'rolls in the script',
  );

  expect(find.byKey(const Key('game-screen-verify-button')), findsOneWidget);

  // The loser's card, held so the recording shows it settled.
  await _holdFor(tester, const Duration(seconds: 6));
  expect(find.byKey(const Key('end-card-lose')), findsOneWidget);
  _motion('7 done');

  debugPrint('motion elapsed ${elapsed.elapsed.inMilliseconds}ms');
  // record_motion.sh records in 170s screenrecord chunks and fails the job
  // when the game spills into a second one. The recorder starts when the
  // app process appears, 6 to 10s before this stopwatch on the CI emulator
  // (run 38972919163: 140.4s of video for 131.3s of script), so 150s keeps
  // the game inside the first chunk with room to spare.
  expect(
    elapsed.elapsed,
    lessThan(const Duration(seconds: 150)),
    reason:
        'the script took ${elapsed.elapsed.inMilliseconds}ms after the '
        'app was up; the limit is 150s',
  );
}

class _Playback {
  _Playback({
    required this.tester,
    required this.transport,
    required this.controller,
    required this.deviceSeat,
    required int startSeq,
  }) : _seq = startSeq;

  final WidgetTester tester;
  final FakeTransport transport;
  final RoomController controller;

  /// 0 (Priya) or 2 (Karim).
  final int deviceSeat;

  int _seq;
  int _k = 0;

  int _nextSeq() {
    _seq += 1;
    return _seq;
  }

  List<int> _tokens(int seat) {
    return controller.room!.seats
        .firstWhere((seatState) => seatState.seat == seat)
        .tokens;
  }

  Future<void> _push(
    String type,
    Map<String, Object?> data, {
    String? re,
  }) async {
    if (type == 'rolled') {
      expect(data.containsKey('queue'), isTrue, reason: 'rolled carries queue');
      expect(data.containsKey('legal'), isTrue);
      // `legal` is a List<int>. List is invariant, so `as List<Object?>` throws.
      final bool moveOwed = (data['legal']! as List).isNotEmpty;
      expect(
        data.containsKey('legal_by_face'),
        moveOwed ? isTrue : isFalse,
        reason: 'legal_by_face rides on rolled only when a move is owed',
      );
    }
    transport.pushText(
      _frame(
        type: type,
        re: re,
        data: <String, Object?>{...data, 'seq': _nextSeq()},
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Map<String, Object?> _rolledData(_RollStep step, int seat, int k) {
    return <String, Object?>{
      'seat': seat,
      'value': step.face,
      'legal': step.legal,
      'deadline_ms': _deadlineMs,
      'k': k,
      'reveal': _reveal(k),
      'queue': step.queue,
      'legal_by_face': ?step.legalByFace,
    };
  }

  Map<String, Object?> _turnData({
    required int seat,
    required String phase,
    required List<int> queue,
    int? value,
    List<int>? legal,
    List<Map<String, Object?>>? legalByFace,
  }) {
    return <String, Object?>{
      'seat': seat,
      'deadline_ms': _deadlineMs,
      'phase': phase,
      'queue': queue,
      'value': ?value,
      'legal': ?legal,
      'legal_by_face': ?legalByFace,
    };
  }

  Future<String> _tapDie() async {
    final int before = transport.sentRaw.length;
    await tester.tap(find.byKey(const Key('game-die')));
    await tester.pump();
    expect(
      find.byKey(const Key('game-die-tumbling')),
      findsOneWidget,
      reason: 'tapping the die must start the tumble',
    );
    await _pumpRealDurationFrames(tester, frameCount: 20);
    return _singleSent(before, 'roll');
  }

  Future<String> _tapToken(int token, int face) async {
    final int before = transport.sentRaw.length;
    // The keyed Semantics node sits under the painted token, so the
    // center of the finder hits that token. The sent index is the check.
    await tester.tap(
      find.byKey(Key('board-token-hit-$deviceSeat-$token')),
      warnIfMissed: false,
    );
    await tester.pump();
    final String raw = _sentSince(before, 'move').single;
    final String id = _idOf(raw);
    final Map<String, Object?> data = _dataOf(raw);
    expect(data['token'], token);
    expect(
      data.containsKey('face'),
      isTrue,
      reason: 'a move under the roll queue carries face',
    );
    expect(data['face'], face);
    return id;
  }

  List<String> _sentSince(int before, String type) {
    return transport.sentRaw
        .skip(before)
        .where((String text) => _typeOf(text) == type)
        .toList();
  }

  String _singleSent(int before, String type) {
    final List<String> found = _sentSince(before, type);
    expect(
      found,
      hasLength(1),
      reason: 'expected one $type, found ${found.length}',
    );
    return _idOf(found.single);
  }

  Future<void> _holdTravel(_MoveStep step) async {
    var milliseconds = step.steps * kTokenStepDuration.inMilliseconds + 120;
    if (step.captured.isNotEmpty) {
      // The flight starts after the mover's last step.
      milliseconds += kCaptureFlightDuration.inMilliseconds + 500;
    }
    if (step.to == 57) {
      milliseconds += 400;
    }
    await _holdFor(tester, Duration(milliseconds: milliseconds));
  }

  bool _showsTray({required List<int> queue, required bool awaitRoll}) {
    return queue.length >= 2 || (awaitRoll && queue.isNotEmpty);
  }

  Set<int> _liveFaces(List<Map<String, Object?>>? legalByFace) {
    if (legalByFace == null) {
      return const <int>{};
    }
    return <int>{
      for (final Map<String, Object?> entry in legalByFace)
        entry['face']! as int,
    };
  }

  List<int> _tokensForFace(List<Map<String, Object?>> legalByFace, int face) {
    for (final Map<String, Object?> entry in legalByFace) {
      if (entry['face'] == face) {
        return List<int>.from(entry['tokens']! as List);
      }
    }
    return const <int>[];
  }

  void _expectRings(int seat, List<int> tokens) {
    for (var token = 0; token < 4; token++) {
      expect(
        find.byKey(Key('board-legal-ring-$seat-$token')),
        tokens.contains(token) ? findsOneWidget : findsNothing,
        reason: 'seat $seat token $token',
      );
    }
  }

  void _expectChild(Key parent, Key child, {required bool present}) {
    expect(
      find.descendant(of: find.byKey(parent), matching: find.byKey(child)),
      present ? findsOneWidget : findsNothing,
    );
  }

  /// Tray, selected die and dead die, from the queue the wire just set.
  /// [selectedFace] overrides the default after a tray tap.
  void _expectTray({
    required int seat,
    required List<int> queue,
    required bool awaitRoll,
    required bool mine,
    List<Map<String, Object?>>? legalByFace,
    int? selectedFace,
  }) {
    final bool show = _showsTray(queue: queue, awaitRoll: awaitRoll);
    expect(
      find.byKey(const Key('game-roll-tray')),
      show ? findsOneWidget : findsNothing,
      reason: 'tray when a queue is owed, queue $queue awaitRoll $awaitRoll',
    );
    // A single remaining face in await_move hides the tray and still rings
    // that face's tokens. Rings follow the selected face, not the tray.
    final int? face = awaitRoll
        ? null
        : (selectedFace ??
              (legalByFace == null || legalByFace.isEmpty
                  ? null
                  : legalByFace.first['face']! as int));
    if (show) {
      final Set<int> live = _liveFaces(legalByFace);
      var selectedTaken = false;
      for (var i = 0; i < queue.length; i++) {
        final Key die = Key('game-roll-tray-die-$i');
        expect(find.byKey(die), findsOneWidget);
        final bool selected = !awaitRoll && !selectedTaken && queue[i] == face;
        if (selected) {
          selectedTaken = true;
        }
        final bool dead =
            !awaitRoll && legalByFace != null && !live.contains(queue[i]);
        _expectChild(die, Key('game-roll-tray-selected-$i'), present: selected);
        _expectChild(die, Key('game-roll-tray-dead-$i'), present: dead);
      }
      expect(
        find.byKey(Key('game-roll-tray-die-${queue.length}')),
        findsNothing,
      );
    }
    if (mine) {
      if (!awaitRoll && face != null && legalByFace != null) {
        _expectRings(seat, _tokensForFace(legalByFace, face));
      } else {
        _expectRings(seat, const <int>[]);
      }
    }
  }

  void _expectModel({
    required int seat,
    required TurnPhase phase,
    required List<int> queue,
    int? value,
    List<Map<String, Object?>>? legalByFace,
  }) {
    expect(controller.hasDesynced, isFalse);
    expect(controller.room!.turn!.seat, seat);
    expect(controller.room!.turn!.phase, phase);
    expect(controller.room!.turn!.queue, queue);
    expect(controller.room!.turn!.value, value);
    final got = controller.room!.turn!.legalByFace;
    if (legalByFace == null) {
      expect(got, isNull);
      return;
    }
    expect(got, isNotNull);
    expect(got!.map((entry) => entry.face).toList(), <int>[
      for (final Map<String, Object?> entry in legalByFace)
        entry['face']! as int,
    ]);
    for (var i = 0; i < legalByFace.length; i++) {
      expect(got[i].tokens, List<int>.from(legalByFace[i]['tokens']! as List));
    }
  }

  void _expectNoMove() {
    expect(find.byKey(const Key('game-die-no-move-mark')), findsOneWidget);
    final Finder notice = find.byKey(const Key('game-no-move-notice'));
    expect(notice, findsOneWidget);
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(tester.widget<Text>(notice).data, loc.gameNoMove);
  }

  void _expectFrom(int seat, _MoveStep step) {
    expect(
      _tokens(seat)[step.token],
      step.from,
      reason:
          'seat $seat token ${step.token} is ${_tokens(seat)[step.token]}, '
          'next move starts at ${step.from}',
    );
  }

  Future<void> playAll(List<_Turn> turns) async {
    for (final _Turn turn in turns) {
      final bool mine = turn.seat == deviceSeat;
      final int before = transport.sentRaw.length;
      expect(
        controller.hasDesynced,
        isFalse,
        reason: 'before seat ${turn.seat}',
      );
      for (final _Step step in turn.steps) {
        switch (step) {
          case _RollStep():
            await _playRoll(turn.seat, step, mine: mine);
          case _MoveStep():
            await _playMove(turn.seat, step, mine: mine);
        }
      }
      if (!mine) {
        expect(
          transport.sentRaw
              .skip(before)
              .where(
                (String text) =>
                    _typeOf(text) == 'roll' || _typeOf(text) == 'move',
              ),
          isEmpty,
          reason: 'device sent on seat ${turn.seat}\'s turn',
        );
      }
    }
  }

  Future<void> _watchOpponentRoll(_RollStep step) async {
    if (step.longWatch) {
      // The thrown die of contract C-377 plays in this gap once it lands on this branch's base.
      await _holdFor(tester, const Duration(milliseconds: 1600));
      return;
    }
    await _holdFor(tester, const Duration(milliseconds: 120));
  }

  Future<void> _playRoll(int seat, _RollStep step, {required bool mine}) async {
    final bool act = mine && step.play;
    final String? re = act ? await _tapDie() : null;
    _k += 1;
    final int k = _k;
    await _push('rolled', _rolledData(step, seat, k), re: re);
    final bool awaitRoll = step.rollAgain || step.passTo != null;
    _expectModel(
      seat: seat,
      phase: awaitRoll ? TurnPhase.awaitRoll : TurnPhase.awaitMove,
      queue: step.queue,
      value: step.face,
      legalByFace: step.legalByFace,
    );
    _expectTray(
      seat: seat,
      queue: step.queue,
      awaitRoll: awaitRoll,
      mine: mine,
      legalByFace: step.legalByFace,
    );
    if (!mine) {
      await _watchOpponentRoll(step);
    }
    if (step.passTo != null) {
      if (mine && step.noMoveBeat) {
        _motion('3 no move');
        _expectNoMove();
      }
      await _push('turn_passed', <String, Object?>{
        'seat': seat,
        'reason': step.passReason ?? 'no_legal_move',
      }, re: re);
      await _push(
        'turn',
        _turnData(
          seat: step.passTo!,
          phase: 'await_roll',
          queue: const <int>[],
        ),
        re: re,
      );
      if (mine && step.noMoveBeat) {
        await _holdFor(tester, const Duration(milliseconds: 1000));
        _expectNoMove();
      }
      return;
    }
    if (step.rollAgain) {
      if (act) {
        await _holdFor(tester, const Duration(milliseconds: 1000));
      }
      await _push(
        'turn',
        _turnData(seat: seat, phase: 'await_roll', queue: step.queue),
        re: re,
      );
      _expectModel(
        seat: seat,
        phase: TurnPhase.awaitRoll,
        queue: step.queue,
        value: null,
      );
      _expectTray(seat: seat, queue: step.queue, awaitRoll: true, mine: mine);
      return;
    }
    if (act) {
      final bool dead = step.queue.any(
        (int face) => !_liveFaces(step.legalByFace).contains(face),
      );
      _motion(
        step.showBonus ? '6 home roll' : (dead ? '4 dead face' : '5 queue'),
      );
      await _holdFor(
        tester,
        Duration(milliseconds: step.showBonus ? 800 : 700),
      );
    }
  }

  Future<void> _playMove(int seat, _MoveStep step, {required bool mine}) async {
    _expectFrom(seat, step);
    String? re;
    final bool act = mine && step.play;
    if (mine && step.pickTrayIndex != null) {
      expect(step.play, isTrue, reason: 'a tray pick is this seat\'s own move');
      _motion('6 pick');
      final int index = step.pickTrayIndex!;
      final int before = transport.sentRaw.length;
      final Finder die = find.byKey(Key('game-roll-tray-die-$index'));
      await tester.ensureVisible(die);
      await tester.pump();
      await tester.tap(die);
      await tester.pump();
      expect(
        transport.sentRaw.length,
        before,
        reason: 'picking a tray die sends nothing',
      );
      _expectTray(
        seat: seat,
        queue: controller.room!.turn!.queue,
        awaitRoll: false,
        mine: true,
        legalByFace: _legalByFaceRaw(),
        selectedFace: step.face,
      );
      await _holdFor(tester, const Duration(milliseconds: 800));
    }
    if (act) {
      re = await _tapToken(step.token, step.face);
    }
    final List<Map<String, Object?>> captured = <Map<String, Object?>>[
      for (final (int capSeat, int capToken) in step.captured)
        <String, Object?>{'seat': capSeat, 'token': capToken},
    ];
    if (step.wins) {
      expect(seat, 0);
      expect(step.to, 57);
      final Stopwatch hold = Stopwatch()..start();
      await _push('moved', <String, Object?>{
        'seat': seat,
        'token': step.token,
        'from': step.from,
        'to': step.to,
        'captured': captured,
        'extra_roll': false,
        'face': step.face,
      }, re: re);
      await _push('game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'https://provefair.app/v/$_gameId',
      }, re: re);
      expect(controller.room!.state, RoomState.finished);
      expect(controller.room!.winner, 0);
      expect(_tokens(0), <int>[57, 57, 57, 57]);
      expect(_tokens(2), <int>[-1, -1, -1, -1]);
      if (deviceSeat != 0) {
        return;
      }
      _motion('8 win');
      await _holdUntil(tester, hold, const Duration(milliseconds: 120));
      expect(controller.room!.state, RoomState.finished);
      expect(controller.room!.winner, 0);
      expect(controller.hasDesynced, isFalse);
      expect(_tokens(0), <int>[57, 57, 57, 57]);
      expect(find.byKey(const Key('game-screen-board')), findsOneWidget);
      expect(find.byKey(const Key('game-screen-winner')), findsNothing);
      await _holdUntil(tester, hold, const Duration(seconds: 6));
      final Finder winner = find.byKey(const Key('game-screen-winner'));
      expect(winner, findsOneWidget);
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(GameScreen)),
      );
      final Text winnerText = tester.widget<Text>(winner);
      final String? shown =
          winnerText.data ?? winnerText.textSpan?.toPlainText();
      expect(shown, loc.endWinTitle);
      return;
    }
    await _push('moved', <String, Object?>{
      'seat': seat,
      'token': step.token,
      'from': step.from,
      'to': step.to,
      'captured': captured,
      'extra_roll': step.extraRoll,
      'face': step.face,
    }, re: re);
    if (step.extraRoll) {
      final List<int> queue = step.stayQueue!;
      await _push(
        'turn',
        _turnData(seat: seat, phase: 'await_roll', queue: queue),
        re: re,
      );
      _expectModel(
        seat: seat,
        phase: TurnPhase.awaitRoll,
        queue: queue,
        value: null,
      );
      _expectTray(seat: seat, queue: queue, awaitRoll: true, mine: mine);
    } else if (step.deadPass) {
      await _push('turn_passed', <String, Object?>{
        'seat': seat,
        'reason': 'no_legal_move',
      }, re: re);
      await _push(
        'turn',
        _turnData(
          seat: step.passTo!,
          phase: 'await_roll',
          queue: const <int>[],
        ),
        re: re,
      );
    } else if (step.stayQueue != null) {
      await _push(
        'turn',
        _turnData(
          seat: seat,
          phase: 'await_move',
          queue: step.stayQueue!,
          value: step.stayValue,
          legal: step.stayLegal,
          legalByFace: step.stayLegalByFace,
        ),
        re: re,
      );
      _expectModel(
        seat: seat,
        phase: TurnPhase.awaitMove,
        queue: step.stayQueue!,
        value: step.stayValue,
        legalByFace: step.stayLegalByFace,
      );
      _expectTray(
        seat: seat,
        queue: step.stayQueue!,
        awaitRoll: false,
        mine: mine,
        legalByFace: step.stayLegalByFace,
      );
    } else {
      await _push(
        'turn',
        _turnData(
          seat: step.passTo!,
          phase: 'await_roll',
          queue: const <int>[],
        ),
        re: re,
      );
    }
    await tester.pump();
    expect(_tokens(seat)[step.token], step.to);
    for (final (int capSeat, int capToken) in step.captured) {
      expect(_tokens(capSeat)[capToken], -1);
    }
    if (step.captured.isNotEmpty) {
      _motion('5 captured');
    }
    if (step.to == 57) {
      _motion('6 home');
    }
    await _holdTravel(step);
  }

  List<Map<String, Object?>>? _legalByFaceRaw() {
    final byFace = controller.room!.turn!.legalByFace;
    if (byFace == null) {
      return null;
    }
    return <Map<String, Object?>>[
      for (final entry in byFace)
        <String, Object?>{'face': entry.face, 'tokens': entry.tokens},
    ];
  }

  void expectSent() {
    var rollCount = 0;
    var moveCount = 0;
    for (final _Turn turn in _script) {
      if (turn.seat != deviceSeat) {
        continue;
      }
      for (final _Step step in turn.steps) {
        if (step is _RollStep && step.play) {
          rollCount += 1;
        } else if (step is _MoveStep && step.play) {
          moveCount += 1;
        }
      }
    }
    final List<String> rolls = transport.sentRaw
        .where((String text) => _typeOf(text) == 'roll')
        .toList();
    final List<String> moves = transport.sentRaw
        .where((String text) => _typeOf(text) == 'move')
        .toList();
    expect(rolls, hasLength(rollCount));
    expect(moves, hasLength(moveCount));
    for (final String text in moves) {
      final Map<String, Object?> data = _dataOf(text);
      expect(
        data.containsKey('face'),
        isTrue,
        reason: 'every move this device sends carries face',
      );
      final Object? face = data['face'];
      expect(face, isA<int>());
      expect(face, inInclusiveRange(1, 6));
    }
  }
}
