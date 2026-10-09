// Recording script for one two-seat game, Priya (seat 0) against Karim
// (seat 1), in English. Order 289 records the screen; this file only
// plays the game and holds still, in real time, through each animation.
// It asserts the facts that keep that script honest, not pixels.
//
// The harness, the controller factory and the frame builders are copied
// from integration_test/screenshots_test.dart (captures 15, 17 and 19).
// Helpers there are private. Nothing here takes a screenshot.
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
const String _clientSeeds = '0:srvseedseat0|1:srvseedseat1';

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
    'blocks': true,
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

class _MotionHarnessState extends State<_MotionHarness> {
  Locale _locale = const Locale('en');

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

/// 64 lowercase hex. The client stores `reveal` and does not check it
/// (room_controller.dart `_reduceRolled`). The shape is protocol section
/// 11: 64 lowercase hex characters, one per roll, distinct per `k`.
String _reveal(int k) => k.toRadixString(16).padLeft(64, '0');

void _motion(String name) => debugPrint('MOTION $name');

// The engine log this recording plays. Faces, legal sets, captures and
// the win were accepted by package:ludo_engine for seats [0, 1] with
// blocks and capture bonus on. Square count of every MOVE `steps` is 260.
const String _actionLog = '''
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 SETUP exit 0
MOVE seat=0 token=0 from=-1 to=0 captured=[] extra=true won=false steps=1 tag=move 0 token 0 SETUP exit 0
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 SETUP exit 1
MOVE seat=0 token=1 from=-1 to=0 captured=[] extra=true won=false steps=1 tag=move 0 token 1 SETUP exit 1
ROLL seat=0 face=5 legal=[0,1] tag=roll 0 face 5 STEP3
MOVE seat=0 token=0 from=0 to=5 captured=[] extra=false won=false steps=5 tag=move 0 token 0 STEP4
TURN seat=1 tag=move 0 token 0 STEP4
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 SETUP karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 SETUP karim pass
TURN seat=0 tag=roll 1 face 5 SETUP karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 SETUP park
MOVE seat=0 token=0 from=5 to=11 captured=[] extra=true won=false steps=6 tag=move 0 token 0 SETUP park
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 SETUP park
MOVE seat=0 token=0 from=11 to=17 captured=[] extra=true won=false steps=6 tag=move 0 token 0 SETUP park
ROLL seat=0 face=5 legal=[0,1] tag=roll 0 face 5 SETUP park aside
MOVE seat=0 token=1 from=0 to=5 captured=[] extra=false won=false steps=5 tag=move 0 token 1 SETUP park aside
TURN seat=1 tag=move 0 token 1 SETUP park aside
ROLL seat=1 face=6 legal=[0,1,2,3] tag=roll 1 face 6 SETUP karim exit
MOVE seat=1 token=0 from=-1 to=0 captured=[] extra=true won=false steps=1 tag=move 1 token 0 SETUP karim exit
ROLL seat=1 face=4 legal=[0] tag=roll 1 face 4 STEP5
MOVE seat=1 token=0 from=0 to=4 captured=[{0,0}] extra=true won=false steps=4 tag=move 1 token 0 STEP5 capture
ROLL seat=1 face=5 legal=[0] tag=roll 1 face 5 SETUP karim after capture
MOVE seat=1 token=0 from=4 to=9 captured=[] extra=false won=false steps=5 tag=move 1 token 0 SETUP karim after capture
TURN seat=0 tag=move 1 token 0 SETUP karim after capture
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 SETUP approach capture
MOVE seat=0 token=1 from=5 to=11 captured=[] extra=true won=false steps=6 tag=move 0 token 1 SETUP approach capture
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 SETUP approach capture
MOVE seat=0 token=1 from=11 to=17 captured=[] extra=true won=false steps=6 tag=move 0 token 1 SETUP approach capture
ROLL seat=0 face=5 legal=[1] tag=roll 0 face 5 STEP6
MOVE seat=0 token=1 from=17 to=22 captured=[{1,0}] extra=true won=false steps=5 tag=move 0 token 1 STEP6 capture
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=-1 to=0 captured=[] extra=true won=false steps=1 tag=move 0 token 0 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=-1 to=0 captured=[] extra=true won=false steps=1 tag=move 0 token 2 MARCH
ROLL seat=0 face=5 legal=[0,1,2] tag=roll 0 face 5 MARCH
MOVE seat=0 token=0 from=0 to=5 captured=[] extra=false won=false steps=5 tag=move 0 token 0 MARCH
TURN seat=1 tag=move 0 token 0 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=3 from=-1 to=0 captured=[] extra=true won=false steps=1 tag=move 0 token 3 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=0 to=6 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=3 from=0 to=5 captured=[] extra=false won=false steps=5 tag=move 0 token 3 MARCH
TURN seat=1 tag=move 0 token 3 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=5 to=11 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=6 to=12 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=3 from=5 to=10 captured=[] extra=false won=false steps=5 tag=move 0 token 3 MARCH
TURN seat=1 tag=move 0 token 3 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=11 to=17 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=12 to=18 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=3 from=10 to=15 captured=[] extra=false won=false steps=5 tag=move 0 token 3 MARCH
TURN seat=1 tag=move 0 token 3 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=17 to=23 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=18 to=24 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=3 from=15 to=20 captured=[] extra=false won=false steps=5 tag=move 0 token 3 MARCH
TURN seat=1 tag=move 0 token 3 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=1 from=22 to=28 captured=[] extra=true won=false steps=6 tag=move 0 token 1 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=23 to=29 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=2 from=24 to=29 captured=[] extra=false won=false steps=5 tag=move 0 token 2 MARCH
TURN seat=1 tag=move 0 token 2 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=3 from=20 to=26 captured=[] extra=true won=false steps=6 tag=move 0 token 3 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=1 from=28 to=34 captured=[] extra=true won=false steps=6 tag=move 0 token 1 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=0 from=29 to=34 captured=[] extra=false won=false steps=5 tag=move 0 token 0 MARCH
TURN seat=1 tag=move 0 token 0 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=29 to=35 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=3 from=26 to=32 captured=[] extra=true won=false steps=6 tag=move 0 token 3 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=0 from=34 to=39 captured=[] extra=false won=false steps=5 tag=move 0 token 0 MARCH
TURN seat=1 tag=move 0 token 0 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=1 from=34 to=40 captured=[] extra=true won=false steps=6 tag=move 0 token 1 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=35 to=41 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=3 from=32 to=37 captured=[] extra=false won=false steps=5 tag=move 0 token 3 MARCH
TURN seat=1 tag=move 0 token 3 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=39 to=45 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=1 from=40 to=46 captured=[] extra=true won=false steps=6 tag=move 0 token 1 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=2 from=41 to=46 captured=[] extra=false won=false steps=5 tag=move 0 token 2 MARCH
TURN seat=1 tag=move 0 token 2 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=3 from=37 to=43 captured=[] extra=true won=false steps=6 tag=move 0 token 3 MARCH
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=45 to=51 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=5 legal=[0,1,2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=1 from=46 to=51 captured=[] extra=false won=false steps=5 tag=move 0 token 1 MARCH
TURN seat=1 tag=move 0 token 1 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[0,1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=0 from=51 to=57 captured=[] extra=true won=false steps=6 tag=move 0 token 0 MARCH
ROLL seat=0 face=6 legal=[1,2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=1 from=51 to=57 captured=[] extra=true won=false steps=6 tag=move 0 token 1 MARCH
ROLL seat=0 face=5 legal=[2,3] tag=roll 0 face 5 MARCH
MOVE seat=0 token=2 from=46 to=51 captured=[] extra=false won=false steps=5 tag=move 0 token 2 MARCH
TURN seat=1 tag=move 0 token 2 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=6 legal=[2,3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=2 from=51 to=57 captured=[] extra=true won=false steps=6 tag=move 0 token 2 MARCH
ROLL seat=0 face=6 legal=[3] tag=roll 0 face 6 MARCH
MOVE seat=0 token=3 from=43 to=49 captured=[] extra=true won=false steps=6 tag=move 0 token 3 MARCH
ROLL seat=0 face=4 legal=[3] tag=roll 0 face 4 MARCH
MOVE seat=0 token=3 from=49 to=53 captured=[] extra=false won=false steps=4 tag=move 0 token 3 MARCH
TURN seat=1 tag=move 0 token 3 MARCH
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 MARCH karim pass
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 MARCH karim pass
TURN seat=0 tag=roll 1 face 5 MARCH karim pass
ROLL seat=0 face=5 legal=[] tag=roll 0 face 5 STEP7
PASS seat=0 reason=noLegalMove tag=roll 0 face 5 STEP7
TURN seat=1 tag=roll 0 face 5 STEP7
ROLL seat=1 face=5 legal=[] tag=roll 1 face 5 SETUP karim before win
PASS seat=1 reason=noLegalMove tag=roll 1 face 5 SETUP karim before win
TURN seat=0 tag=roll 1 face 5 SETUP karim before win
ROLL seat=0 face=4 legal=[3] tag=roll 0 face 4 STEP8
MOVE seat=0 token=3 from=53 to=57 captured=[] extra=false won=true steps=4 tag=move 0 token 3 STEP8 win
''';

sealed class _Line {
  const _Line(this.tag);
  final String tag;
}

class _Roll extends _Line {
  const _Roll(this.seat, this.face, this.legal, String tag) : super(tag);
  final int seat;
  final int face;
  final List<int> legal;
}

class _Move extends _Line {
  const _Move(
    this.seat,
    this.token,
    this.from,
    this.to,
    this.captured,
    this.extra,
    this.won,
    this.steps,
    String tag,
  ) : super(tag);
  final int seat;
  final int token;
  final int from;
  final int to;
  final List<(int, int)> captured;
  final bool extra;
  final bool won;
  final int steps;
}

class _Pass extends _Line {
  const _Pass(this.seat, this.reason, String tag) : super(tag);
  final int seat;
  final String reason;
}

class _Turn extends _Line {
  const _Turn(this.seat, String tag) : super(tag);
  final int seat;
}

final RegExp _rollPattern = RegExp(
  r'^ROLL seat=(\d+) face=(\d+) legal=\[([^\]]*)\] tag=(.*)$',
);
final RegExp _movePattern = RegExp(
  r'^MOVE seat=(\d+) token=(\d+) from=(-?\d+) to=(-?\d+) '
  r'captured=\[(.*)\] extra=(true|false) won=(true|false) '
  r'steps=(\d+) tag=(.*)$',
);
final RegExp _passPattern = RegExp(r'^PASS seat=(\d+) reason=(\w+) tag=(.*)$');
final RegExp _turnPattern = RegExp(r'^TURN seat=(\d+) tag=(.*)$');
final RegExp _capturedPair = RegExp(r'\{(\d+),(\d+)\}');

List<_Line> _parseLog(String log) {
  final List<_Line> lines = <_Line>[];
  for (final String raw in log.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    final RegExpMatch? roll = _rollPattern.firstMatch(line);
    if (roll != null) {
      final String legalText = roll.group(3)!;
      final List<int> legal = legalText.isEmpty
          ? <int>[]
          : legalText.split(',').map(int.parse).toList();
      lines.add(
        _Roll(
          int.parse(roll.group(1)!),
          int.parse(roll.group(2)!),
          legal,
          roll.group(4)!,
        ),
      );
      continue;
    }
    final RegExpMatch? move = _movePattern.firstMatch(line);
    if (move != null) {
      final List<(int, int)> captured = <(int, int)>[
        for (final RegExpMatch pair in _capturedPair.allMatches(move.group(5)!))
          (int.parse(pair.group(1)!), int.parse(pair.group(2)!)),
      ];
      lines.add(
        _Move(
          int.parse(move.group(1)!),
          int.parse(move.group(2)!),
          int.parse(move.group(3)!),
          int.parse(move.group(4)!),
          captured,
          move.group(6) == 'true',
          move.group(7) == 'true',
          int.parse(move.group(8)!),
          move.group(9)!,
        ),
      );
      continue;
    }
    final RegExpMatch? pass = _passPattern.firstMatch(line);
    if (pass != null) {
      lines.add(
        _Pass(int.parse(pass.group(1)!), pass.group(2)!, pass.group(3)!),
      );
      continue;
    }
    final RegExpMatch? turn = _turnPattern.firstMatch(line);
    if (turn != null) {
      lines.add(_Turn(int.parse(turn.group(1)!), turn.group(2)!));
      continue;
    }
    throw TestFailure('motion log line did not parse: $line');
  }
  return lines;
}

List<({_Roll roll, List<_Line> rest})> _groupRolls(List<_Line> lines) {
  final List<({_Roll roll, List<_Line> rest})> groups =
      <({_Roll roll, List<_Line> rest})>[];
  for (var i = 0; i < lines.length; i++) {
    final _Line line = lines[i];
    if (line is! _Roll) {
      throw TestFailure('motion log left a ${line.runtimeType} outside a roll');
    }
    final List<_Line> rest = <_Line>[];
    while (i + 1 < lines.length && lines[i + 1] is! _Roll) {
      i += 1;
      rest.add(lines[i]);
    }
    groups.add((roll: line, rest: rest));
  }
  return groups;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('records one two-seat game with motion on', (tester) async {
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

    final List<_Line> lines = _parseLog(_actionLog);
    expect(lines, hasLength(168));
    final List<_Move> moves = <_Move>[
      for (final _Line line in lines)
        if (line is _Move) line,
    ];
    expect(moves, hasLength(52));
    expect(moves.fold<int>(0, (int sum, _Move move) => sum + move.steps), 260);
    final List<({_Roll roll, List<_Line> rest})> groups = _groupRolls(lines);

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
    expect(homeLoc.localeName, 'en');

    const String hostName = 'Priya';
    await tester.enterText(find.byKey(const Key('home-name-field')), hostName);
    await tester.tap(find.byKey(const Key('home-players-disclosure')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final Finder selector = find.byKey(const Key('home-players-selector'));
    expect(selector, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: selector,
        matching: find.text(homeLoc.homePlayersTwo),
      ),
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
    expect(createData['rules'], <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
    });
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
        data: <String, Object?>{'seat': 1, 'name': 'Karim', 'seq': 2},
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('lobby-room-code')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('lobby-room-code'))).data,
      _roomCode,
    );
    expect(find.byKey(const Key('lobby-seat-0')), findsOneWidget);
    expect(find.byKey(const Key('lobby-seat-1')), findsOneWidget);

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
    // carry re. seat_seed does not.
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
          'seat': 1,
          'client_seed': 'srvseedseat1',
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
    transport.pushText(
      _frame(
        type: 'turn',
        re: startId,
        data: <String, Object?>{
          'seat': 0,
          'deadline_ms': _deadlineMs,
          'seq': 6,
        },
      ),
    );
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
    );
    for (final ({_Roll roll, List<_Line> rest}) group in groups) {
      await playback.play(group.roll, group.rest);
    }

    expect(controller.room!.state, RoomState.finished);
    expect(controller.room!.winner, 0);
    expect(controller.hasDesynced, isFalse);
    debugPrint('motion elapsed ${elapsed.elapsed.inMilliseconds}ms');
    expect(
      elapsed.elapsed,
      lessThan(const Duration(seconds: 120)),
      reason:
          'the script took ${elapsed.elapsed.inMilliseconds}ms after the '
          'app was up; the limit is 120s',
    );
  });
}

class _Playback {
  _Playback({
    required this.tester,
    required this.transport,
    required this.controller,
  });

  final WidgetTester tester;
  final FakeTransport transport;
  final RoomController controller;

  int _seq = 6;
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

  void _expectInSync(String where) {
    expect(
      controller.hasDesynced,
      isFalse,
      reason: 'seq gap before $where (room seq ${controller.room?.seq})',
    );
  }

  void _expectFrom(_Move move) {
    _expectInSync('move ${move.tag}');
    expect(
      _tokens(move.seat)[move.token],
      move.from,
      reason:
          'seat ${move.seat} token ${move.token} is '
          '${_tokens(move.seat)[move.token]}, next move starts at '
          '${move.from} (${move.tag})',
    );
  }

  void _pushRolled(_Roll roll, {String? re}) {
    _k += 1;
    transport.pushText(
      _frame(
        type: 'rolled',
        re: re,
        data: <String, Object?>{
          'seat': roll.seat,
          'value': roll.face,
          'legal': roll.legal,
          'deadline_ms': _deadlineMs,
          'k': _k,
          'reveal': _reveal(_k),
          'seq': _nextSeq(),
        },
      ),
    );
  }

  void _pushMoved(_Move move, {String? re}) {
    transport.pushText(
      _frame(
        type: 'moved',
        re: re,
        data: <String, Object?>{
          'seat': move.seat,
          'token': move.token,
          'from': move.from,
          'to': move.to,
          'captured': <Object?>[
            for (final (int seat, int token) in move.captured)
              <String, Object?>{'seat': seat, 'token': token},
          ],
          'extra_roll': move.extra,
          'seq': _nextSeq(),
        },
      ),
    );
  }

  void _pushPassed(int seat, {String? re}) {
    transport.pushText(
      _frame(
        type: 'turn_passed',
        re: re,
        data: <String, Object?>{
          'seat': seat,
          'reason': 'no_legal_move',
          'seq': _nextSeq(),
        },
      ),
    );
  }

  void _pushTurn(int seat, {String? re}) {
    transport.pushText(
      _frame(
        type: 'turn',
        re: re,
        data: <String, Object?>{
          'seat': seat,
          'deadline_ms': _deadlineMs,
          'seq': _nextSeq(),
        },
      ),
    );
  }

  void _pushGameOver({String? re}) {
    transport.pushText(
      _frame(
        type: 'game_over',
        re: re,
        data: <String, Object?>{
          'winner': 0,
          'verify_url': 'https://provefair.app/v/$_gameId',
          'seq': _nextSeq(),
        },
      ),
    );
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

  Future<String> _tapToken(int token) async {
    final int before = transport.sentRaw.length;
    // The keyed Semantics node sits under the painted token, so the
    // center of the finder hits that token. The sent index is the check.
    await tester.tap(
      find.byKey(Key('board-token-hit-0-$token')),
      warnIfMissed: false,
    );
    await tester.pump();
    final String id = _singleSent(before, 'move');
    expect(_dataOf(_sentSince(before, 'move').single)['token'], token);
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

  Future<void> _holdTravel(_Move move) async {
    var milliseconds = move.steps * kTokenStepDuration.inMilliseconds + 120;
    if (move.captured.isNotEmpty) {
      milliseconds += kCaptureFlightDuration.inMilliseconds + 80;
    }
    await _holdFor(tester, Duration(milliseconds: milliseconds));
  }

  Future<void> play(_Roll roll, List<_Line> rest) async {
    _Move? move;
    _Pass? pass;
    _Turn? turn;
    for (final _Line line in rest) {
      if (line is _Move) {
        expect(move, isNull, reason: 'two moves under one roll (${roll.tag})');
        move = line;
      } else if (line is _Pass) {
        pass = line;
      } else if (line is _Turn) {
        turn = line;
      }
    }
    expect(
      pass == null || move == null,
      isTrue,
      reason: 'a roll cannot both move and pass (${roll.tag})',
    );

    if (roll.tag.contains('STEP3')) {
      _motion('3 roll');
      await _step3(roll, move!);
      _motion('4 move');
      await _step4(move, turn!);
      return;
    }
    if (roll.tag.contains('STEP5')) {
      _motion('5 captured');
      await _step5(roll, move!);
      return;
    }
    if (roll.tag.contains('STEP6')) {
      _motion('6 capture');
      await _step6(roll, move!);
      return;
    }
    if (roll.tag.contains('STEP7')) {
      _motion('7 no move');
      await _step7(roll, pass!, turn!);
      return;
    }
    if (roll.tag.contains('STEP8')) {
      _motion('8 win');
      await _step8(roll, move!);
      return;
    }
    await _server(roll, move, pass, turn);
  }

  Future<void> _step3(_Roll roll, _Move move) async {
    final Stopwatch hold = Stopwatch()..start();
    final int before = transport.sentRaw.length;
    await tester.tap(find.byKey(const Key('game-die')));
    await tester.pump();
    expect(find.byKey(const Key('game-die-tumbling')), findsOneWidget);
    await _holdUntil(tester, hold, const Duration(milliseconds: 640));
    final String rollId = _singleSent(before, 'roll');
    _pushRolled(roll, re: rollId);
    await tester.pump();

    expect(controller.room!.turn!.phase, TurnPhase.awaitMove);
    expect(controller.room!.turn!.value, roll.face);
    expect(roll.legal.length, greaterThanOrEqualTo(2));
    expect(roll.legal.contains(move.token), isTrue);
    expect(
      roll.legal.any((int token) => _tokens(roll.seat)[token] >= 0),
      isTrue,
      reason: 'at least one legal token is already on the track',
    );
    expect(move.from, greaterThanOrEqualTo(0));
    expect(move.to - move.from, greaterThanOrEqualTo(4));
    for (final int token in roll.legal) {
      expect(
        find.byKey(Key('board-legal-ring-${roll.seat}-$token')),
        findsOneWidget,
      );
    }
    await _holdUntil(tester, hold, const Duration(seconds: 3));
    expect(_sentSince(before, 'move'), isEmpty);
    _expectFrom(move);
  }

  Future<void> _step4(_Move move, _Turn turn) async {
    final String moveId = await _tapToken(move.token);
    _pushMoved(move, re: moveId);
    _pushTurn(turn.seat, re: moveId);
    await tester.pump();
    expect(_tokens(move.seat)[move.token], move.to);
    expect(controller.room!.turn!.seat, turn.seat);
    expect(controller.room!.turn!.phase, TurnPhase.awaitRoll);
    await _holdFor(tester, const Duration(seconds: 3));
  }

  Future<void> _step5(_Roll roll, _Move move) async {
    _expectFrom(move);
    expect(move.captured, isNotEmpty);
    final Stopwatch hold = Stopwatch()..start();
    _pushRolled(roll);
    await tester.pump();
    await _holdUntil(tester, hold, const Duration(milliseconds: 400));
    _pushMoved(move);
    // Capture grants the extra roll. Protocol 12.2 still sends `turn`
    // for the same seat. The log has no TURN line on this beat; the
    // next roll is Karim's.
    expect(move.extra, isTrue);
    _pushTurn(roll.seat);
    await tester.pump();
    for (final (int seat, int token) in move.captured) {
      expect(_tokens(seat)[token], -1);
    }
    expect(_tokens(move.seat)[move.token], move.to);
    await _holdUntil(tester, hold, const Duration(seconds: 4));
  }

  Future<void> _step6(_Roll roll, _Move move) async {
    _expectFrom(move);
    expect(roll.legal, <int>[move.token]);
    expect(move.captured, isNotEmpty);
    final String rollId = await _tapDie();
    _pushRolled(roll, re: rollId);
    await tester.pump();
    // One legal token arms a 1500ms auto-move. Tap before that fires.
    final String moveId = await _tapToken(move.token);
    _pushMoved(move, re: moveId);
    expect(move.extra, isTrue);
    _pushTurn(roll.seat, re: moveId);
    await tester.pump();
    for (final (int seat, int token) in move.captured) {
      expect(seat, 1);
      expect(_tokens(seat)[token], -1);
    }
    expect(_tokens(move.seat)[move.token], move.to);
    await _holdFor(tester, const Duration(seconds: 4));
  }

  Future<void> _step7(_Roll roll, _Pass pass, _Turn turn) async {
    _expectInSync('no move');
    expect(_tokens(0), <int>[57, 57, 57, 53]);
    expect(_tokens(1), <int>[-1, -1, -1, -1]);
    expect(controller.room!.turn!.seat, 0);
    expect(controller.room!.turn!.phase, TurnPhase.awaitRoll);
    // Capture 15's face. Protocol 12.1 also sends turn_passed, which
    // that capture left out; the reducer accepts it and the mark stays.
    expect(roll.face, 5);
    expect(roll.legal, isEmpty);
    expect(pass.reason, 'noLegalMove');

    final String rollId = await _tapDie();
    _pushRolled(roll, re: rollId);
    _pushPassed(roll.seat, re: rollId);
    _pushTurn(turn.seat, re: rollId);
    await tester.pump();
    await tester.pump();

    expect(controller.room!.turn!.seat, turn.seat);
    expect(find.byKey(const Key('game-die-no-move-mark')), findsOneWidget);
    final Finder notice = find.byKey(const Key('game-no-move-notice'));
    expect(notice, findsOneWidget);
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    expect(tester.widget<Text>(notice).data, loc.gameNoMove);
    await _holdFor(tester, const Duration(seconds: 4));
  }

  Future<void> _step8(_Roll roll, _Move move) async {
    _expectFrom(move);
    expect(move.won, isTrue);
    expect(move.to, 57);
    expect(move.to - move.from, greaterThanOrEqualTo(1));
    final String rollId = await _tapDie();
    _pushRolled(roll, re: rollId);
    await tester.pump();
    final String moveId = await _tapToken(move.token);
    final Stopwatch hold = Stopwatch()..start();
    _pushMoved(move, re: moveId);
    _pushGameOver(re: moveId);
    await tester.pump();
    await _holdUntil(tester, hold, const Duration(milliseconds: 120));
    expect(controller.room!.state, RoomState.finished);
    expect(controller.room!.winner, 0);
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
    final String? shown = winnerText.data ?? winnerText.textSpan?.toPlainText();
    expect(shown, loc.endWinTitle);
  }

  /// A turn the player did not ask for. No `re`: the same shape as a
  /// timer-played turn (buildExpiryFrames). Pushed as its own diff so
  /// the board can travel it, then held until that travel is finished
  /// and the next beat starts from an idle board.
  Future<void> _server(
    _Roll roll,
    _Move? move,
    _Pass? pass,
    _Turn? turn,
  ) async {
    _expectInSync(roll.tag);
    if (pass != null) {
      expect(pass.reason, 'noLegalMove');
      _pushRolled(roll);
      _pushPassed(roll.seat);
      _pushTurn(turn!.seat);
      await tester.pump();
      return;
    }
    final _Move played = move!;
    _expectFrom(played);
    _pushRolled(roll);
    _pushMoved(played);
    if (played.won) {
      _pushGameOver();
    } else if (turn != null) {
      _pushTurn(turn.seat);
    } else {
      expect(played.extra, isTrue, reason: played.tag);
      _pushTurn(roll.seat);
    }
    await tester.pump();
    expect(_tokens(played.seat)[played.token], played.to);
    if (!played.won) {
      await _holdTravel(played);
    }
  }
}
