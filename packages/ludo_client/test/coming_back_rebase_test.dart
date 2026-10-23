// Order 442 -- screen tests for decisions D1-D6 of
// work/ludo/orders/C-442-coming-back-rebases-the-screen.md, written from that
// contract and from docs/PROTOCOL.md sections 8, 21, 22 and 23 only.
//
// The class under test (P10): GameScreen keeps per-turn memory that frames
// set and a snapshot never re-bases, and derives every cue from frames
// alone, so a phone that comes back (an in-app resume after a drop, or a
// relaunch) can show a stale instruction, miss a beat, or come back silent.
// "A snapshot" is a `room` frame the controller applied: the answer to
// `resume`, or the room a relaunched GameScreen mounts over.
//
// Every case mounts the real GameScreen over a real RoomController and a
// FakeTransport and feeds raw JSON frames. A two-player room is seated
// [0, 2] (PROTOCOL section 15), so the other player is seat 2 everywhere
// here; every frame is one the server could send (section 12 and 21.3 frame
// order, `by` absent on a client's own step, `timer_steps` on every snapshot
// seat). A drop is the far side ending the socket; the way back is the
// reconnect button and the server's `room` answer on a second transport.
//
// Helpers are copied by hand from test/timer_steps_resume_test.dart (mount,
// the drop and resume dance, the accessibility recorder, the fake feedback
// service), test/automove_says_so_test.dart (the unique-legal hold and its
// arc key), test/play_surface_die_test.dart (the 4 s no-answer line),
// test/roll_tray_test.dart (the dead-queue frames) and test/safe_cue_test.dart
// (the safe pill), per the project rule never to import across test files.
//
// Expected on the base commit (17119d7): every case named for a decision
// (D1a, D1b, D1c, D1d, D2, D3, D4a, D4a2, D4c, D5a, D5b, D6, D6b) is red
// because GameScreen does not do what the contract says; every case named
// "control" or "guard" is green and stays green once the contract is built,
// because it pins what the contract keeps.
//
// Hygiene: one mount per case; no pumpAndSettle (the die, the arc and the
// countdown all animate while armed); every pump is bounded; no
// pumpEventQueue outside runAsync; every request a case opens is answered
// or the controller is disposed in the body, so no timer outlives a case.
//
// Reproduce any case: cd packages/ludo_client && flutter test
// test/coming_back_rebase_test.dart --plain-name "<case name>". There is no
// randomness anywhere in this file: the scenario named in each failure
// message is the whole reproduction.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart' show cellFor, kTokenStepDuration;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://coming-back-rebase-test.invalid/ws';
const String _file = 'test/coming_back_rebase_test.dart';

const String _gameId = 'a1b2c3d4e5f60718';
const String _clientSeeds = '0:sam-seed|1:bob-seed';
const String _verifyUrl = 'https://coming-back.invalid/v/a1b2c3d4e5f60718';

/// The two seats of a two-player room (PROTOCOL section 15).
const int _me = 0;
const int _bob = 2;

const List<int> _yard = <int>[-1, -1, -1, -1];

const Key _dieKey = Key('game-die');
const Key _noAnswerKey = Key('game-die-no-answer');
const Key _noMoveMarkKey = Key('game-die-no-move-mark');
const Key _noMoveNoticeKey = Key('game-no-move-notice');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');
Key _arcKey(int seat, int index) => Key('board-automove-arc-$seat-$index');
Key _glowKey(int seat, int index) => Key('board-automove-glow-$seat-$index');

/// Any safe-landing pill (`board-safe-cue-star`, `board-safe-cue-pair`).
Finder _anySafePill() => find.byWidgetPredicate((Widget w) {
  final Key? key = w.key;
  return key is ValueKey<String> && key.value.startsWith('board-safe-cue');
});

// --- frames ---------------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'coming-back-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, String name, List<int> tokens) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': tokens,
      'client_seed': null,
      'seed_origin': null,
      'timer_steps': 0,
    };

List<Map<String, Object?>> _seats({
  List<int> mine = _yard,
  List<int> other = _yard,
}) => <Map<String, Object?>>[
  _seatJson(_me, 'Sam', mine),
  _seatJson(_bob, 'Bob', other),
];

Map<String, Object?> _roomJson({
  String state = 'PLAYING',
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  required int seq,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': _gameId,
  'client_seeds': _clientSeeds,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
  'verify_url': ?(state == 'FINISHED' ? _verifyUrl : null),
};

/// A snapshot `turn` in `await_roll` (section 6: no `value`, `legal`; section
/// 21.3 rule 2: `queue`).
Map<String, Object?> _rollTurn(
  int seat,
  int k, {
  List<int> queue = const <int>[],
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'k': k,
  'queue': queue,
};

/// A snapshot `turn` in `await_move` (section 21.3 rule 2: `value` is the
/// default face, `legal` its tokens, `legal_by_face` the faces with a legal
/// token).
Map<String, Object?> _moveTurn(
  int seat,
  int k, {
  required int value,
  required List<int> legal,
  required List<int> queue,
  required List<Map<String, Object?>> legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_move',
  'deadline_ms': 45000,
  'k': k,
  'value': value,
  'legal': legal,
  'queue': queue,
  'legal_by_face': legalByFace,
};

Map<String, Object?> _faceLegal(int face, List<int> tokens) =>
    <String, Object?>{'face': face, 'tokens': tokens};

/// The turn of a FINISHED snapshot (section 21.3 rule 2).
Map<String, Object?> _finishedTurn(int winner, int k) => <String, Object?>{
  'seat': winner,
  'phase': 'finished',
  'deadline_ms': 0,
  'k': k,
  'queue': const <int>[],
};

/// One unique legal token for me: token 0 on face 5 (C-417).
Map<String, Object?> _uniqueLegalTurn(int k) => _moveTurn(
  _me,
  k,
  value: 5,
  legal: const <int>[0],
  queue: const <int>[5],
  legalByFace: <Map<String, Object?>>[
    _faceLegal(5, const <int>[0]),
  ],
);

class _Seq {
  _Seq(this.value);
  int value;
  int next() {
    value += 1;
    return value;
  }
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

class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// One mounted game: controller, every transport used so far, the connector
/// that hands out the next one, the announcements and the cues played.
class _Rig {
  _Rig({
    required this.controller,
    required this.transport,
    required this.connector,
    required this.seq,
    required this.fake,
    required this.announcements,
  }) {
    transports.add(transport);
  }

  final RoomController controller;
  FakeTransport transport;
  final List<FakeTransport> transports = <FakeTransport>[];
  final _Connector connector;
  final _Seq seq;
  final _FakeFeedbackService fake;
  final List<String> announcements;
  bool _disposed = false;

  void disposeOnce() {
    if (!_disposed) {
      _disposed = true;
      controller.dispose();
    }
  }

  int cues(FeedbackCue cue) =>
      fake.recorded.where((FeedbackCue c) => c == cue).length;

  int told(String message) =>
      announcements.where((String m) => m == message).length;

  /// Every `move` this rig's transports ever carried, in order.
  List<Map<String, Object?>> moves() => <Map<String, Object?>>[
    for (final FakeTransport t in transports)
      for (final String raw in t.sentRaw)
        if (_typeOf(raw) == 'move') _dataOf(raw),
  ];
}

/// A case: its name (also the `--plain-name` filter) and the scenario every
/// failure message repeats, so a red run says what was expected, what
/// happened and how to run it again.
class _Case {
  const _Case(this.name, this.scenario);
  final String name;
  final String scenario;

  String why(String expected, [String? got]) =>
      'C-442 $name. Expected: $expected. '
      '${got == null ? '' : 'Got: $got. '}'
      'Scenario: $scenario. '
      'Reproduce: cd packages/ludo_client && flutter test $_file '
      '--plain-name "$name"';
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// Connects as seat 0 into [state] over [seats], installs the accessibility
/// recorder and the fake feedback service, and mounts GameScreen.
Future<_Rig> _start(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  String state = 'PLAYING',
  int? winner,
}) async {
  final List<String> announcements = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        announcements.add(data['message'] as String);
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
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _FakeFeedbackService fake = _FakeFeedbackService();
  final _Rig rig = _Rig(
    controller: controller,
    transport: transport,
    connector: connector,
    seq: _Seq(1),
    fake: fake,
    announcements: announcements,
  );
  addTearDown(rig.disposeOnce);

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String createId = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': _me, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: createId,
      data: _roomJson(
        state: state,
        seats: seats,
        turn: turn,
        winner: winner,
        seq: 1,
      ),
    ),
  );
  await future;

  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      locale: const Locale('en'),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: fake,
        child: GameScreen(controller: controller),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return rig;
}

/// Unmounts, then disposes the controller, so no timer survives the case.
Future<void> _finish(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(const SizedBox.shrink());
  rig.disposeOnce();
  await tester.pump();
}

/// Pushes one state-changing frame with the next `seq` and pumps it in.
Future<void> _push(
  WidgetTester tester,
  _Rig rig,
  String type,
  Map<String, Object?> data, {
  String? re,
}) async {
  rig.transport.pushText(
    _frame(
      type: type,
      re: re,
      data: <String, Object?>{...data, 'seq': rig.seq.next()},
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pumps [total] in [step] slices, calling [onStep] after each.
Future<void> _pumpFor(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
  void Function()? onStep,
}) async {
  Duration elapsed = Duration.zero;
  while (elapsed < total) {
    final Duration slice = total - elapsed < step ? total - elapsed : step;
    await tester.pump(slice);
    elapsed += slice;
    onStep?.call();
  }
}

/// The socket dies under the screen: the far side ends the link. The
/// controller lands `closed`, or `failed` when a request (a roll, a move)
/// was still waiting for its answer; both show the connection-lost card with
/// the reconnect button.
Future<void> _drop(
  WidgetTester tester,
  _Rig rig, {
  bool expectCard = true,
}) async {
  rig.transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    rig.controller.phase,
    anyOf(RoomPhase.closed, RoomPhase.failed),
    reason: 'setup: the far side vanishing must leave connected',
  );
  if (expectCard) {
    expect(
      find.byKey(_connectionLostKey),
      findsOneWidget,
      reason: 'setup: the connection-lost card must show after the drop',
    );
  }
}

/// The player taps reconnect and the server answers the `resume` with a
/// `room` snapshot built from the arguments.
Future<void> _resume(
  WidgetTester tester,
  _Rig rig, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  String state = 'PLAYING',
  int? winner,
  bool viaButton = true,
}) async {
  final FakeTransport next = FakeTransport();
  rig.connector.enqueue(next);
  if (viaButton) {
    await tester.tap(find.byKey(_reconnectButtonKey));
  } else {
    // A FINISHED room shows the end card, not the connection-lost card, so
    // there is no button; the controller's own reconnect is what a retry
    // calls.
    unawaited(rig.controller.reconnect());
  }
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  expect(
    next.sentRaw,
    isNotEmpty,
    reason: 'setup: reconnect must have sent a resume request',
  );
  expect(_typeOf(next.sentRaw.last), 'resume');
  final String resumeId = _idOf(next.sentRaw.last);
  rig.transport = next;
  rig.transports.add(next);
  next.pushText(
    _frame(
      type: 'room',
      re: resumeId,
      data: _roomJson(
        state: state,
        seats: seats,
        turn: turn,
        winner: winner,
        seq: rig.seq.next(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    rig.controller.phase,
    RoomPhase.connected,
    reason: 'setup: the resume answer must land the controller connected',
  );
}

/// Taps the die and returns the id of the `roll` it sent.
Future<String> _tapDie(WidgetTester tester, _Rig rig) async {
  final int before = rig.transport.sentRaw.length;
  await tester.tap(find.byKey(_dieKey));
  await tester.pump();
  final List<String> sent = rig.transport.sentRaw.skip(before).toList();
  expect(sent.map(_typeOf).toList(), <String>[
    'roll',
  ], reason: 'setup: one die tap must put exactly one roll on the wire');
  return _idOf(sent.single);
}

/// Taps my token [index] and returns the `move` request it sent.
Future<String> _tapToken(WidgetTester tester, _Rig rig, int index) async {
  final int before = rig.transport.sentRaw.length;
  await tester.tap(find.byKey(_hitKey(_me, index)), warnIfMissed: false);
  await tester.pump();
  final List<String> sent = rig.transport.sentRaw.skip(before).toList();
  expect(sent.map(_typeOf).toList(), <String>[
    'move',
  ], reason: 'setup: one token tap must put exactly one move on the wire');
  return sent.single;
}

Map<String, Object?> _rolledData({
  required int seat,
  required int value,
  required List<int> legal,
  required int k,
  required List<int> queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': 45000,
  'k': k,
  'reveal': 'c' * 64,
  'queue': queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _movedData({
  required int seat,
  required int token,
  required int from,
  required int to,
  required int face,
  bool extraRoll = false,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
}) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': from,
  'to': to,
  'captured': captured,
  'extra_roll': extraRoll,
  'face': face,
};

Map<String, Object?> _turnData(int seat) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'queue': const <int>[],
};

/// Bob's dead roll and the turn coming to me: `rolled` (no legal token),
/// `turn_passed`, `turn` for my seat (section 21.3 rule 4).
Future<void> _bobPassesToMe(
  WidgetTester tester,
  _Rig rig, {
  required int k,
}) async {
  await _push(
    tester,
    rig,
    'rolled',
    _rolledData(
      seat: _bob,
      value: 3,
      legal: const <int>[],
      k: k,
      queue: const <int>[],
    ),
  );
  await _push(tester, rig, 'turn_passed', <String, Object?>{
    'seat': _bob,
    'reason': 'no_legal_move',
  });
  await _push(tester, rig, 'turn', _turnData(_me));
}

/// Answers the `move` request [moveText] with the `moved` the server sends
/// and the `turn` that follows for [nextSeat].
Future<void> _answerMove(
  WidgetTester tester,
  _Rig rig,
  String moveText, {
  required int token,
  required int from,
  required int to,
  required int face,
  int nextSeat = _bob,
}) async {
  await _push(
    tester,
    rig,
    'moved',
    _movedData(seat: _me, token: token, from: from, to: to, face: face),
    re: _idOf(moveText),
  );
  await _push(tester, rig, 'turn', _turnData(nextSeat));
}

/// Loads the app's own Poppins and Noto Sans Arabic files, so text lays out
/// at its real width: with the default test font the die's no-answer line is
/// wider than the phone and the framework reports a layout overflow that no
/// player would see. Copied from test/automove_says_so_test.dart.
Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

void main() {
  setUpAll(_loadAppFonts);

  // ==========================================================================
  // D1: the die's no-answer line is never stale.
  // ==========================================================================
  group('D1: the no-answer line', () {
    testWidgets(
      'D1a control: no result at 6 s, the no-answer line is still shown',
      (tester) async {
        const _Case c = _Case(
          'D1a control: no result at 6 s, the no-answer line is still shown',
          'my await_roll k=0, die tapped, no rolled for 6 s, connected',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_me, 0),
        );
        try {
          final String rollId = await _tapDie(tester, rig);
          await tester.pump(const Duration(milliseconds: 4100));
          expect(
            find.byKey(_noAnswerKey),
            findsOneWidget,
            reason: c.why('the line shown at 4.1 s (fixture)'),
          );
          await tester.pump(const Duration(milliseconds: 1900));
          expect(
            find.byKey(_noAnswerKey),
            findsOneWidget,
            reason: c.why(
              'the line still shown at 6 s while my await_roll stands and '
              'the link is up (the behaviour the contract keeps)',
            ),
          );
          expect(
            rig.told(_locOf(tester).gameRollNoAnswer),
            1,
            reason: c.why('the line announced once while it stays up'),
          );
          await _push(
            tester,
            rig,
            'rolled',
            _rolledData(
              seat: _me,
              value: 2,
              legal: const <int>[0, 1],
              k: 1,
              queue: const <int>[2],
              legalByFace: <Map<String, Object?>>[
                _faceLegal(2, const <int>[0, 1]),
              ],
            ),
            re: rollId,
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D1a: the late rolled for me clears the no-answer line within one pump',
      (tester) async {
        const _Case c = _Case(
          'D1a: the late rolled for me clears the no-answer line within one '
              'pump',
          'my await_roll k=0 with two tokens out, die tapped, no answer for '
              '4.1 s (line shown), then rolled k=1 value 2 legal [0, 1] arrives '
              'on the same connection',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: const <int>[10, 20, -1, -1]),
          turn: _rollTurn(_me, 0),
        );
        try {
          final String rollId = await _tapDie(tester, rig);
          await tester.pump(const Duration(milliseconds: 4100));
          expect(
            find.byKey(_noAnswerKey),
            findsOneWidget,
            reason: c.why('the line shown after 4.1 s without an answer'),
          );
          rig.transport.pushText(
            _frame(
              type: 'rolled',
              re: rollId,
              data: <String, Object?>{
                ..._rolledData(
                  seat: _me,
                  value: 2,
                  legal: const <int>[0, 1],
                  k: 1,
                  queue: const <int>[2],
                  legalByFace: <Map<String, Object?>>[
                    _faceLegal(2, const <int>[0, 1]),
                  ],
                ),
                'seq': rig.seq.next(),
              },
            ),
          );
          await tester.pump();
          expect(
            rig.controller.room!.turn!.k,
            1,
            reason: c.why('the rolled applied (fixture)'),
          );
          expect(
            find.byKey(_noAnswerKey),
            findsNothing,
            reason: c.why(
              'game-die-no-answer gone within one pump of the roll result '
                  'arriving, the room now showing await_move',
              'the line is still on screen under a board whose die shows '
                  'the result',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D1d: a late dead roll and the turn passing clear the no-answer line',
      (tester) async {
        const _Case c = _Case(
          'D1d: a late dead roll and the turn passing clear the no-answer '
              'line',
          'my await_roll k=0, die tapped, no answer for 4.1 s (line shown), '
              'then rolled k=1 value 3 legal [] + turn_passed no_legal_move + '
              'turn for seat 2 arrive',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_me, 0),
        );
        try {
          final String rollId = await _tapDie(tester, rig);
          await tester.pump(const Duration(milliseconds: 4100));
          expect(
            find.byKey(_noAnswerKey),
            findsOneWidget,
            reason: c.why('the line shown after 4.1 s without an answer'),
          );
          await _push(
            tester,
            rig,
            'rolled',
            _rolledData(
              seat: _me,
              value: 3,
              legal: const <int>[],
              k: 1,
              queue: const <int>[],
            ),
            re: rollId,
          );
          await _push(tester, rig, 'turn_passed', <String, Object?>{
            'seat': _me,
            'reason': 'no_legal_move',
          });
          await _push(tester, rig, 'turn', _turnData(_bob));
          expect(
            rig.controller.room!.turn!.seat,
            _bob,
            reason: c.why('the turn on seat 2 (fixture)'),
          );
          expect(
            find.byKey(_noAnswerKey),
            findsNothing,
            reason: c.why(
              'the line gone once the room shows another seat on turn',
              'the line is still up on a turn that is no longer mine',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D1b: tap, drop, 4.1 s offline, resume into await_move: no line and '
      'it was never announced',
      (tester) async {
        const _Case c = _Case(
          'D1b: tap, drop, 4.1 s offline, resume into await_move: no line '
              'and it was never announced',
          'my await_roll k=0, die tapped, socket dropped at once, 4.1 s '
              'pass offline, the resume snapshot shows my await_move k=1 '
              'value 4 legal [0, 1]',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: const <int>[10, 20, -1, -1]),
          turn: _rollTurn(_me, 0),
        );
        try {
          final AppLocalizations loc = _locOf(tester);
          await _tapDie(tester, rig);
          await _drop(tester, rig);
          await tester.pump(const Duration(milliseconds: 4100));
          expect(
            rig.told(loc.gameRollNoAnswer),
            0,
            reason: c.why(
              'the line not announced to TalkBack when the 4 s timer fires '
                  'with the link down',
              'announced ${rig.told(loc.gameRollNoAnswer)} time(s)',
            ),
          );
          await _resume(
            tester,
            rig,
            seats: _seats(mine: const <int>[10, 20, -1, -1]),
            turn: _moveTurn(
              _me,
              1,
              value: 4,
              legal: const <int>[0, 1],
              queue: const <int>[4],
              legalByFace: <Map<String, Object?>>[
                _faceLegal(4, const <int>[0, 1]),
              ],
            ),
          );
          expect(
            find.byKey(_noAnswerKey),
            findsNothing,
            reason: c.why(
              'no game-die-no-answer on a snapshot in await_move',
              'the line is shown over a die that has its result',
            ),
          );
          expect(
            rig.told(loc.gameRollNoAnswer),
            0,
            reason: c.why(
              'the line never announced for a roll that did go through',
              'announced ${rig.told(loc.gameRollNoAnswer)} time(s)',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D1c: the no-answer line goes when the connection leaves connected',
      (tester) async {
        const _Case c = _Case(
          'D1c: the no-answer line goes when the connection leaves connected',
          'my await_roll k=0, die tapped, no answer for 4.1 s (line shown), '
              'then the socket drops',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_me, 0),
        );
        try {
          await _tapDie(tester, rig);
          await tester.pump(const Duration(milliseconds: 4100));
          expect(
            find.byKey(_noAnswerKey),
            findsOneWidget,
            reason: c.why('the line shown after 4.1 s without an answer'),
          );
          await _drop(tester, rig);
          expect(
            find.byKey(_noAnswerKey),
            findsNothing,
            reason: c.why(
              'the line gone while the reconnecting card owns the state',
              'the line is still in the tree beside the connection-lost '
                  'card',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ==========================================================================
  // D2: the queue memory follows the snapshot.
  // ==========================================================================
  group('D2: the queue memory', () {
    // Before the drop the screen holds my bonus roll: await_roll, k=2,
    // queue [4] (a 6 and a 4 were rolled, the 6 captured and owes a roll).
    // The roll that follows is a 1 (k=3): queue [4, 1]; only face 4 has a
    // legal token.
    const List<int> mine = <int>[10, 20, -1, -1];
    final Map<String, Object?> bonusTurn = _rollTurn(
      _me,
      2,
      queue: const <int>[4],
    );
    final Map<String, Object?> deadOneTurn = _moveTurn(
      _me,
      3,
      value: 4,
      legal: const <int>[0, 1],
      queue: const <int>[4, 1],
      legalByFace: <Map<String, Object?>>[
        _faceLegal(4, const <int>[0, 1]),
      ],
    );

    Future<void> spendTheFourAndExpectTheBeat(
      WidgetTester tester,
      _Rig rig,
      _Case c,
    ) async {
      final String move = await _tapToken(tester, rig, 0);
      expect(
        _dataOf(move)['face'],
        4,
        reason: c.why('the move spends face 4 (fixture)'),
      );
      final int noMoveBefore = rig.cues(FeedbackCue.noMove);
      await _push(
        tester,
        rig,
        'moved',
        _movedData(seat: _me, token: 0, from: 10, to: 14, face: 4),
        re: _idOf(move),
      );
      await _push(tester, rig, 'turn_passed', <String, Object?>{
        'seat': _me,
        'reason': 'no_legal_move',
      });
      await _push(tester, rig, 'turn', _turnData(_bob));
      expect(
        rig.controller.room!.turn!.seat,
        _bob,
        reason: c.why('the turn on seat 2 after the dead 1 (fixture)'),
      );
      expect(
        find.byKey(_noMoveMarkKey),
        findsOneWidget,
        reason: c.why(
          'the red mark on the die for the dead 1 (game-die-no-move-mark)',
          'no mark: the dead face was not remembered',
        ),
      );
      expect(
        find.byKey(_noMoveNoticeKey),
        findsOneWidget,
        reason: c.why(
          'the no-move line up with the mark (game-no-move-notice)',
          'no line',
        ),
      );
      expect(
        rig.cues(FeedbackCue.noMove) - noMoveBefore,
        1,
        reason: c.why(
          'the noMove cue played once for the dead 1',
          'played ${rig.cues(FeedbackCue.noMove) - noMoveBefore} time(s); '
              'cues: ${rig.fake.recorded}',
        ),
      );
      await tester.pump(const Duration(milliseconds: 1400));
      expect(
        find.byKey(_noMoveMarkKey),
        findsOneWidget,
        reason: c.why('the mark still held at 1400 ms'),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(_noMoveMarkKey),
        findsNothing,
        reason: c.why('the mark released after the 1500 ms hold'),
      );
    }

    testWidgets(
      'D2 control: live frames only, spending the 4 gives the dead 1 its '
      'no-move beat',
      (tester) async {
        const _Case c = _Case(
          'D2 control: live frames only, spending the 4 gives the dead 1 '
              'its no-move beat',
          'my bonus await_roll k=2 queue [4]; die tapped; rolled k=3 '
              'value 1 queue [4, 1] with legal_by_face only face 4; token 0 '
              'tapped; moved face 4, turn_passed no_legal_move, turn seat 2',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: mine),
          turn: bonusTurn,
        );
        try {
          final String rollId = await _tapDie(tester, rig);
          await _push(
            tester,
            rig,
            'rolled',
            _rolledData(
              seat: _me,
              value: 1,
              legal: const <int>[0, 1],
              k: 3,
              queue: const <int>[4, 1],
              legalByFace: <Map<String, Object?>>[
                _faceLegal(4, const <int>[0, 1]),
              ],
            ),
            re: rollId,
          );
          await spendTheFourAndExpectTheBeat(tester, rig, c);
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets('D2: after a resume into await_move with queue [4, 1], spending the 4 '
        'gives the dead 1 its no-move beat', (tester) async {
      const _Case c = _Case(
        'D2: after a resume into await_move with queue [4, 1], spending '
            'the 4 gives the dead 1 its no-move beat',
        'my bonus await_roll k=2 queue [4]; socket drops; the resume '
            'snapshot shows my await_move k=3 queue [4, 1] with legal_by_face '
            'only face 4; token 0 tapped; moved face 4, turn_passed '
            'no_legal_move, turn seat 2',
      );
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: mine),
        turn: bonusTurn,
      );
      try {
        await _drop(tester, rig);
        await _resume(
          tester,
          rig,
          seats: _seats(mine: mine),
          turn: deadOneTurn,
        );
        expect(rig.controller.room!.turn!.queue, <int>[
          4,
          1,
        ], reason: c.why('the snapshot applied with queue [4, 1] (fixture)'));
        await spendTheFourAndExpectTheBeat(tester, rig, c);
      } finally {
        await _finish(tester, rig);
      }
    });
  });

  // ==========================================================================
  // D3: the unique-legal hold across a drop.
  // ==========================================================================
  group('D3: the unique-legal hold', () {
    const List<int> mine = <int>[10, 20, -1, -1];

    testWidgets(
      'D3: a drop cancels the hold; the snapshot runs it again in full and '
      'one move is sent at its end',
      (tester) async {
        const _Case c = _Case(
          'D3: a drop cancels the hold; the snapshot runs it again in full '
              'and one move is sent at its end',
          'my await_move k=5 face 5, token 0 the only legal token (arc up); '
              '500 ms into the hold the socket drops; 2 s offline; the resume '
              'snapshot shows the same turn',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: mine),
          turn: _uniqueLegalTurn(5),
        );
        try {
          final AppLocalizations loc = _locOf(tester);
          expect(
            find.byKey(_arcKey(_me, 0)),
            findsOneWidget,
            reason: c.why('the arc up for the unique legal token (fixture)'),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            find.byKey(_arcKey(_me, 0)),
            findsOneWidget,
            reason: c.why('the arc still up at 500 ms (fixture)'),
          );
          await _drop(tester, rig);
          expect(
            find.byKey(_arcKey(_me, 0)),
            findsNothing,
            reason: c.why(
              'the arc gone the moment the connection leaves connected',
              'the arc is still counting down over a dead link',
            ),
          );
          expect(
            find.byKey(_glowKey(_me, 0)),
            findsNothing,
            reason: c.why(
              'the glow gone with the arc',
              'the glow is still on the token',
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 2));
          expect(
            rig.moves(),
            isEmpty,
            reason: c.why('no move sent while the link is down'),
          );
          expect(
            rig.told(loc.gameTokenButton(1)),
            0,
            reason: c.why(
              'nothing announced for a move that is not made',
              'announced "${loc.gameTokenButton(1)}" '
                  '${rig.told(loc.gameTokenButton(1))} time(s) offline',
            ),
          );

          await _resume(
            tester,
            rig,
            seats: _seats(mine: mine),
            turn: _uniqueLegalTurn(5),
          );
          expect(
            find.byKey(_arcKey(_me, 0)),
            findsOneWidget,
            reason: c.why(
              'the arc back after a snapshot that still shows one legal '
                  'token',
              'no arc: the latch for this turn was never released',
            ),
          );
          await tester.pump(const Duration(milliseconds: 1400));
          expect(
            rig.moves(),
            isEmpty,
            reason: c.why('no move before the full 1500 ms hold has run'),
          );
          await tester.pump(const Duration(milliseconds: 150));
          final List<Map<String, Object?>> moves = rig.moves();
          expect(
            moves,
            hasLength(1),
            reason: c.why(
              'exactly one move sent at the end of the renewed hold',
              '${moves.length} move(s)',
            ),
          );
          expect(moves.single['token'], 0);
          final String sent = rig.transport.sentRaw.lastWhere(
            (String raw) => _typeOf(raw) == 'move',
          );
          await _answerMove(
            tester,
            rig,
            sent,
            token: 0,
            from: 10,
            to: 15,
            face: 5,
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D3 control: a decision the server refused stays latched, no second '
      'move without a snapshot',
      (tester) async {
        const _Case c = _Case(
          'D3 control: a decision the server refused stays latched, no '
              'second move without a snapshot',
          'my await_move k=5, token 0 the only legal token; the hold sends '
              'its move; the server answers ILLEGAL_MOVE; 3 s pass connected',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: mine),
          turn: _uniqueLegalTurn(5),
        );
        try {
          await tester.pump(const Duration(milliseconds: 1550));
          expect(
            rig.moves(),
            hasLength(1),
            reason: c.why('the hold sent its move (fixture)'),
          );
          final String sent = rig.transport.sentRaw.lastWhere(
            (String raw) => _typeOf(raw) == 'move',
          );
          rig.transport.pushText(
            _frame(
              type: 'error',
              re: _idOf(sent),
              data: <String, Object?>{
                'code': 'ILLEGAL_MOVE',
                'message': 'ILLEGAL_MOVE',
              },
            ),
          );
          await tester.pump();
          await tester.pump();
          await _pumpFor(tester, const Duration(seconds: 3));
          expect(
            rig.moves(),
            hasLength(1),
            reason: c.why(
              'the refused decision not sent again by the hold',
              '${rig.moves().length} moves',
            ),
          );
          expect(
            find.byKey(_arcKey(_me, 0)),
            findsNothing,
            reason: c.why('no arc for a decision already handled'),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D3 control: a snapshot with two legal tokens arms no hold and sends '
      'nothing',
      (tester) async {
        const _Case c = _Case(
          'D3 control: a snapshot with two legal tokens arms no hold and '
              'sends nothing',
          'my await_move k=5 token 0 the only legal token; socket drops; '
              'the resume snapshot shows k=5 face 5 with tokens 0 and 1 legal',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: mine),
          turn: _uniqueLegalTurn(5),
        );
        try {
          await tester.pump(const Duration(milliseconds: 500));
          await _drop(tester, rig);
          await _resume(
            tester,
            rig,
            seats: _seats(mine: mine),
            turn: _moveTurn(
              _me,
              5,
              value: 5,
              legal: const <int>[0, 1],
              queue: const <int>[5],
              legalByFace: <Map<String, Object?>>[
                _faceLegal(5, const <int>[0, 1]),
              ],
            ),
          );
          await _pumpFor(tester, const Duration(seconds: 3));
          expect(
            find.byKey(_arcKey(_me, 0)),
            findsNothing,
            reason: c.why('no arc when the choice is the player\'s'),
          );
          expect(
            rig.moves(),
            isEmpty,
            reason: c.why('no move sent when two tokens are legal'),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ==========================================================================
  // D4: coming back to my turn is felt, once per turn.
  // ==========================================================================
  group('D4: yourTurn from a snapshot', () {
    testWidgets(
      'D4a: an in-app resume into my await_roll at a new k plays yourTurn '
      'once',
      (tester) async {
        const _Case c = _Case(
          'D4a: an in-app resume into my await_roll at a new k plays '
              'yourTurn once',
          'seat 2 on turn at k=3, socket drops, the resume snapshot shows '
              'my await_roll at k=4',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_bob, 3),
        );
        try {
          expect(rig.fake.recorded, isEmpty, reason: c.why('no cue yet'));
          await _drop(tester, rig);
          await _resume(tester, rig, seats: _seats(), turn: _rollTurn(_me, 4));
          expect(
            rig.cues(FeedbackCue.yourTurn),
            1,
            reason: c.why(
              'yourTurn once for the turn the snapshot shows',
              'played ${rig.cues(FeedbackCue.yourTurn)} time(s); '
                  'cues: ${rig.fake.recorded}',
            ),
          );
          expect(
            rig.fake.recorded.length,
            rig.cues(FeedbackCue.yourTurn),
            reason: c.why(
              'no other cue from a snapshot of a PLAYING room',
              'cues: ${rig.fake.recorded}',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D4a2: two snapshots of the same turn k play yourTurn once, not twice',
      (tester) async {
        const _Case c = _Case(
          'D4a2: two snapshots of the same turn k play yourTurn once, not '
              'twice',
          'seat 2 on turn at k=3, drop and resume into my await_roll k=4, '
              'drop and resume again into the same turn k=4',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_bob, 3),
        );
        try {
          await _drop(tester, rig);
          await _resume(tester, rig, seats: _seats(), turn: _rollTurn(_me, 4));
          await _drop(tester, rig);
          await _resume(tester, rig, seats: _seats(), turn: _rollTurn(_me, 4));
          expect(
            rig.cues(FeedbackCue.yourTurn),
            1,
            reason: c.why(
              'never more than one yourTurn per turn k',
              'played ${rig.cues(FeedbackCue.yourTurn)} time(s); '
                  'cues: ${rig.fake.recorded}',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D4b guard: yourTurn played from the live turn is not played again by '
      'a snapshot of the same k',
      (tester) async {
        const _Case c = _Case(
          'D4b guard: yourTurn played from the live turn is not played '
              'again by a snapshot of the same k',
          'seat 2 on turn at k=3; seat 2 rolls k=4 with no legal move and '
              'the turn comes to me (live yourTurn); socket drops; the resume '
              'snapshot shows my await_roll at k=4',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_bob, 3),
        );
        try {
          await _bobPassesToMe(tester, rig, k: 4);
          expect(
            rig.cues(FeedbackCue.yourTurn),
            1,
            reason: c.why('the live turn played yourTurn once (fixture)'),
          );
          expect(rig.controller.room!.turn!.k, 4);
          await _drop(tester, rig);
          await _resume(tester, rig, seats: _seats(), turn: _rollTurn(_me, 4));
          expect(
            rig.cues(FeedbackCue.yourTurn),
            1,
            reason: c.why(
              'no second yourTurn for a turn this screen already played',
              'played ${rig.cues(FeedbackCue.yourTurn)} time(s)',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D4c: a relaunch mounted into my await_roll with an empty transcript '
      'plays yourTurn once',
      (tester) async {
        const _Case c = _Case(
          'D4c: a relaunch mounted into my await_roll with an empty '
              'transcript plays yourTurn once',
          'GameScreen mounts over a room whose only frame is the resume '
              'answer (no turn frame in the transcript): my await_roll k=4',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_me, 4),
        );
        try {
          expect(
            rig.cues(FeedbackCue.yourTurn),
            1,
            reason: c.why(
              'yourTurn once at mount',
              'played ${rig.cues(FeedbackCue.yourTurn)} time(s); '
                  'cues: ${rig.fake.recorded}',
            ),
          );
          await tester.pump(const Duration(seconds: 1));
          expect(
            rig.cues(FeedbackCue.yourTurn),
            1,
            reason: c.why('still once a second later'),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D4 control: a resume into the other seat\'s turn plays no cue at all',
      (tester) async {
        const _Case c = _Case(
          'D4 control: a resume into the other seat\'s turn plays no cue at '
              'all',
          'seat 2 on turn at k=3, socket drops, the resume snapshot shows '
              'seat 2 on turn at k=5 with its tokens moved',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(),
          turn: _rollTurn(_bob, 3),
        );
        try {
          await _drop(tester, rig);
          await _resume(
            tester,
            rig,
            seats: _seats(other: const <int>[30, -1, -1, -1]),
            turn: _rollTurn(_bob, 5),
          );
          await tester.pump(const Duration(seconds: 1));
          expect(
            rig.fake.recorded,
            isEmpty,
            reason: c.why(
              'no cue from a snapshot of another seat\'s turn',
              'cues: ${rig.fake.recorded}',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets('D4 control: a resume into my await_move plays no cue', (
      tester,
    ) async {
      const _Case c = _Case(
        'D4 control: a resume into my await_move plays no cue',
        'seat 2 on turn at k=3, socket drops, the resume snapshot shows '
            'my await_move k=4 with tokens 0 and 1 legal',
      );
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: const <int>[10, 20, -1, -1]),
        turn: _rollTurn(_bob, 3),
      );
      try {
        await _drop(tester, rig);
        await _resume(
          tester,
          rig,
          seats: _seats(mine: const <int>[10, 20, -1, -1]),
          turn: _moveTurn(
            _me,
            4,
            value: 4,
            legal: const <int>[0, 1],
            queue: const <int>[4],
            legalByFace: <Map<String, Object?>>[
              _faceLegal(4, const <int>[0, 1]),
            ],
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(
          rig.fake.recorded,
          isEmpty,
          reason: c.why(
            'no cue (yourTurn is for await_roll only; a snapshot plays '
                'nothing else)',
            'cues: ${rig.fake.recorded}',
          ),
        );
      } finally {
        await _finish(tester, rig);
      }
    });
  });

  // ==========================================================================
  // D5: a game that ended while I was away.
  // ==========================================================================
  group('D5: FINISHED from a snapshot', () {
    const List<int> homeAll = <int>[57, 57, 57, 57];
    const List<int> nearlyHome = <int>[57, 57, 57, 52];

    testWidgets(
      'D5a: an in-app resume of a PLAYING game into FINISHED, winner me, '
      'plays win once',
      (tester) async {
        const _Case c = _Case(
          'D5a: an in-app resume of a PLAYING game into FINISHED, winner '
              'me, plays win once',
          'game $_gameId PLAYING with seat 2 on turn, socket drops, the '
              'resume snapshot is the same game FINISHED, winner seat 0',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: nearlyHome, other: const <int>[30, -1, -1, -1]),
          turn: _rollTurn(_bob, 9),
        );
        try {
          final AppLocalizations loc = _locOf(tester);
          await _drop(tester, rig);
          await _resume(
            tester,
            rig,
            state: 'FINISHED',
            seats: _seats(mine: homeAll, other: const <int>[30, -1, -1, -1]),
            turn: _finishedTurn(_me, 10),
            winner: _me,
          );
          await _pumpFor(tester, const Duration(seconds: 1));
          expect(
            rig.cues(FeedbackCue.win),
            1,
            reason: c.why(
              'win once for the game that ended while away',
              'win played ${rig.cues(FeedbackCue.win)} time(s); '
                  'cues: ${rig.fake.recorded}',
            ),
          );
          expect(
            rig.cues(FeedbackCue.gameOver),
            0,
            reason: c.why('no gameOver when the winner is my seat'),
          );
          expect(
            rig.told(loc.gameOverYouWin),
            1,
            reason: c.why(
              'the win line announced once (${loc.gameOverYouWin})',
              'announced ${rig.told(loc.gameOverYouWin)} time(s)',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D5b: an in-app resume of a PLAYING game into FINISHED, winner the '
      'other seat, plays gameOver once',
      (tester) async {
        const _Case c = _Case(
          'D5b: an in-app resume of a PLAYING game into FINISHED, winner '
              'the other seat, plays gameOver once',
          'game $_gameId PLAYING with seat 2 on turn, socket drops, the '
              'resume snapshot is the same game FINISHED, winner seat 2',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: const <int>[30, -1, -1, -1], other: nearlyHome),
          turn: _rollTurn(_bob, 9),
        );
        try {
          final AppLocalizations loc = _locOf(tester);
          await _drop(tester, rig);
          await _resume(
            tester,
            rig,
            state: 'FINISHED',
            seats: _seats(mine: const <int>[30, -1, -1, -1], other: homeAll),
            turn: _finishedTurn(_bob, 10),
            winner: _bob,
          );
          await _pumpFor(tester, const Duration(seconds: 1));
          expect(
            rig.cues(FeedbackCue.gameOver),
            1,
            reason: c.why(
              'gameOver once for the game that ended while away',
              'gameOver played ${rig.cues(FeedbackCue.gameOver)} time(s); '
                  'cues: ${rig.fake.recorded}',
            ),
          );
          expect(
            rig.cues(FeedbackCue.win),
            0,
            reason: c.why('no win when the winner is the other seat'),
          );
          expect(
            rig.told(loc.gameOverPlayerWins('Bob')),
            1,
            reason: c.why(
              'the winner line announced once '
                  '(${loc.gameOverPlayerWins('Bob')})',
              'announced ${rig.told(loc.gameOverPlayerWins('Bob'))} '
                  'time(s)',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    for (final int winner in <int>[_me, _bob]) {
      testWidgets(
        'D5c control: a relaunch mounted straight into FINISHED, winner seat '
        '$winner, plays neither win nor gameOver',
        (tester) async {
          final _Case c = _Case(
            'D5c control: a relaunch mounted straight into FINISHED, winner '
                'seat $winner, plays neither win nor gameOver',
            'GameScreen mounts over a FINISHED room, winner seat $winner, '
                'nothing shown before',
          );
          final _Rig rig = await _start(
            tester,
            state: 'FINISHED',
            seats: _seats(
              mine: winner == _me ? homeAll : const <int>[30, -1, -1, -1],
              other: winner == _bob ? homeAll : const <int>[30, -1, -1, -1],
            ),
            turn: _finishedTurn(winner, 10),
            winner: winner,
          );
          try {
            await _pumpFor(tester, const Duration(seconds: 2));
            expect(
              rig.fake.recorded,
              isEmpty,
              reason: c.why(
                'no cue for an end card the player opened the app onto',
                'cues: ${rig.fake.recorded}',
              ),
            );
          } finally {
            await _finish(tester, rig);
          }
        },
      );
    }

    testWidgets(
      'D5d guard: a game_over this screen received is not played again by '
      'the FINISHED snapshot',
      (tester) async {
        const _Case c = _Case(
          'D5d guard: a game_over this screen received is not played again '
              'by the FINISHED snapshot',
          'my last token steps 52 to 57 and game_over names seat 0 (win '
              'played live); the socket drops; the resume snapshot is the same '
              'game FINISHED, winner seat 0',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: nearlyHome, other: const <int>[30, -1, -1, -1]),
          turn: _moveTurn(
            _me,
            9,
            value: 5,
            legal: const <int>[3],
            queue: const <int>[5],
            legalByFace: <Map<String, Object?>>[
              _faceLegal(5, const <int>[3]),
            ],
          ),
        );
        try {
          final String move = await _tapToken(tester, rig, 3);
          await _push(
            tester,
            rig,
            'moved',
            _movedData(
              seat: _me,
              token: 3,
              from: 52,
              to: 57,
              face: 5,
              extraRoll: true,
            ),
            re: _idOf(move),
          );
          await _push(tester, rig, 'game_over', <String, Object?>{
            'winner': _me,
            'verify_url': _verifyUrl,
          });
          await _pumpFor(tester, const Duration(seconds: 3));
          expect(
            rig.cues(FeedbackCue.win),
            1,
            reason: c.why('win played once from the live game_over (fixture)'),
          );
          await _drop(tester, rig, expectCard: false);
          await _resume(
            tester,
            rig,
            state: 'FINISHED',
            seats: _seats(mine: homeAll, other: const <int>[30, -1, -1, -1]),
            turn: _finishedTurn(_me, 9),
            winner: _me,
            viaButton: false,
          );
          await _pumpFor(tester, const Duration(seconds: 1));
          expect(
            rig.cues(FeedbackCue.win),
            1,
            reason: c.why(
              'win not played a second time for the same game',
              'win played ${rig.cues(FeedbackCue.win)} time(s)',
            ),
          );
          expect(
            rig.cues(FeedbackCue.gameOver),
            0,
            reason: c.why('no gameOver for a game I won'),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );
  });

  // ==========================================================================
  // D6: nothing queued before the drop plays after the snapshot.
  // ==========================================================================
  group('D6: queued cues die with the connection', () {
    // My token 0 at 17 steps 4 onto absolute square 21 (a safe star). Seat
    // 2's progress 47 is the same absolute square (offset 26 on a 52-track).
    const List<int> mine = <int>[17, 30, -1, -1];
    const List<int> bobOnTheStar = <int>[47, -1, -1, -1];

    final Map<String, Object?> spendTheFour = _moveTurn(
      _me,
      7,
      value: 4,
      legal: const <int>[0, 1],
      queue: const <int>[4],
      legalByFace: <Map<String, Object?>>[
        _faceLegal(4, const <int>[0, 1]),
      ],
    );

    void expectFixture(_Case c) {
      expect(
        cellFor(seat: _me, progress: 21),
        cellFor(seat: _bob, progress: 47),
        reason: c.why('seat 0 progress 21 and seat 2 progress 47 share a cell'),
      );
    }

    testWidgets(
      'D6 control: a move landing on a safe square with no drop shows the '
      'safe pill',
      (tester) async {
        const _Case c = _Case(
          'D6 control: a move landing on a safe square with no drop shows '
              'the safe pill',
          'my token 0 moves 17 to 21 (safe star, seat 2 token at 47), '
              'connected throughout',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: mine, other: bobOnTheStar),
          turn: spendTheFour,
        );
        try {
          expectFixture(c);
          final String move = await _tapToken(tester, rig, 0);
          await _answerMove(
            tester,
            rig,
            move,
            token: 0,
            from: 17,
            to: 21,
            face: 4,
          );
          await _pumpFor(
            tester,
            kTokenStepDuration * 4 + const Duration(milliseconds: 100),
            step: const Duration(milliseconds: 16),
          );
          expect(
            _anySafePill(),
            findsOneWidget,
            reason: c.why('the safe pill shown after the token lands'),
          );
          await _pumpFor(tester, const Duration(seconds: 2));
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D6: a safe cue armed before a drop never shows after the snapshot',
      (tester) async {
        const _Case c = _Case(
          'D6: a safe cue armed before a drop never shows after the '
              'snapshot',
          'my token 0 moves 17 to 21 (safe star, seat 2 token at 47); the '
              'socket drops one frame later, before the token lands; the '
              'resume snapshot has my token 0 at 25',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: mine, other: bobOnTheStar),
          turn: spendTheFour,
        );
        try {
          expectFixture(c);
          final String move = await _tapToken(tester, rig, 0);
          await _answerMove(
            tester,
            rig,
            move,
            token: 0,
            from: 17,
            to: 21,
            face: 4,
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            _anySafePill(),
            findsNothing,
            reason: c.why('the pill not shown yet, the token still walking'),
          );
          await _drop(tester, rig);
          await tester.pump(const Duration(milliseconds: 100));
          await _resume(
            tester,
            rig,
            seats: _seats(
              mine: const <int>[25, 30, -1, -1],
              other: bobOnTheStar,
            ),
            turn: _rollTurn(_bob, 9),
          );
          int framesWithPill = 0;
          await _pumpFor(
            tester,
            const Duration(seconds: 3),
            step: const Duration(milliseconds: 50),
            onStep: () {
              if (_anySafePill().evaluate().isNotEmpty) {
                framesWithPill += 1;
              }
            },
          );
          expect(
            framesWithPill,
            0,
            reason: c.why(
              'no board-safe-cue pill at any point in the 3 s after the '
                  'snapshot',
              'a safe pill was on the post-resume board in $framesWithPill '
                  'of 60 frames',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets(
      'D6b control: a home arrival with no drop plays the home cue once',
      (tester) async {
        const _Case c = _Case(
          'D6b control: a home arrival with no drop plays the home cue once',
          'my token 0 moves 54 to 57, connected throughout',
        );
        final _Rig rig = await _start(
          tester,
          seats: _seats(
            mine: const <int>[54, 30, -1, -1],
            other: const <int>[5, -1, -1, -1],
          ),
          turn: _moveTurn(
            _me,
            7,
            value: 3,
            legal: const <int>[0, 1],
            queue: const <int>[3],
            legalByFace: <Map<String, Object?>>[
              _faceLegal(3, const <int>[0, 1]),
            ],
          ),
        );
        try {
          final String move = await _tapToken(tester, rig, 0);
          await _push(
            tester,
            rig,
            'moved',
            _movedData(
              seat: _me,
              token: 0,
              from: 54,
              to: 57,
              face: 3,
              extraRoll: true,
            ),
            re: _idOf(move),
          );
          await _push(tester, rig, 'turn', _turnData(_me));
          await _pumpFor(tester, const Duration(seconds: 3));
          expect(
            rig.cues(FeedbackCue.home),
            1,
            reason: c.why(
              'the home cue played once on landing',
              'cues: ${rig.fake.recorded}',
            ),
          );
        } finally {
          await _finish(tester, rig);
        }
      },
    );

    testWidgets('D6b: a landing cue held before a drop never plays after the '
        'snapshot', (tester) async {
      const _Case c = _Case(
        'D6b: a landing cue held before a drop never plays after the '
            'snapshot',
        'my token 0 moves 54 to 57 (home cue held until landing); the '
            'socket drops one frame later, before the token lands; the '
            'resume snapshot has my token 0 at 57',
      );
      final _Rig rig = await _start(
        tester,
        seats: _seats(
          mine: const <int>[54, 30, -1, -1],
          other: const <int>[5, -1, -1, -1],
        ),
        turn: _moveTurn(
          _me,
          7,
          value: 3,
          legal: const <int>[0, 1],
          queue: const <int>[3],
          legalByFace: <Map<String, Object?>>[
            _faceLegal(3, const <int>[0, 1]),
          ],
        ),
      );
      try {
        final String move = await _tapToken(tester, rig, 0);
        await _push(
          tester,
          rig,
          'moved',
          _movedData(
            seat: _me,
            token: 0,
            from: 54,
            to: 57,
            face: 3,
            extraRoll: true,
          ),
          re: _idOf(move),
        );
        await _push(tester, rig, 'turn', _turnData(_me));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          rig.cues(FeedbackCue.home),
          0,
          reason: c.why('the home cue not played before the landing'),
        );
        await _drop(tester, rig);
        await tester.pump(const Duration(milliseconds: 100));
        await _resume(
          tester,
          rig,
          seats: _seats(
            mine: const <int>[57, 30, -1, -1],
            other: const <int>[5, -1, -1, -1],
          ),
          turn: _rollTurn(_me, 7),
        );
        await _pumpFor(tester, const Duration(seconds: 3));
        expect(
          rig.cues(FeedbackCue.home),
          0,
          reason: c.why(
            'the pending home cue dropped with the connection and never '
                'played',
            'home played ${rig.cues(FeedbackCue.home)} time(s) after the '
                'snapshot; cues: ${rig.fake.recorded}',
          ),
        );
      } finally {
        await _finish(tester, rig);
      }
    });
  });
}
