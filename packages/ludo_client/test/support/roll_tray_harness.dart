// Shared driver for the roll-tray screen tests. A real RoomController sits
// on FakeTransport; every room state arrives as a decoded wire frame.
// GameScreen is mounted once per case by the caller.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board_geometry.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import '../net/fake_transport.dart';

const String rollTrayTestUrl = 'wss://roll-tray-test.invalid/ws';

const Key rollTrayKey = Key('game-roll-tray');
const Key bigDieKey = Key('game-die');
const Key boardKey = Key('game-screen-board');
const Key noMoveMarkKey = Key('game-die-no-move-mark');
const Key noMoveNoticeKey = Key('game-no-move-notice');

const int rollTrayDeadlineMs = 45000;
const String rollTrayReveal =
    'abcdef0123456789abcdef0123456789'
    'abcdef0123456789abcdef0123456789';

Key trayDieKey(int index) => Key('game-roll-tray-die-$index');

Key trayFaceKey(int index, int face) => Key('game-roll-tray-face-$index-$face');

/// The selected mark C-462 removed from the tray. No state draws it any
/// more; the key stays here so a case can assert it is absent.
Key traySelectedKey(int index) => Key('game-roll-tray-selected-$index');

Key trayDeadKey(int index) => Key('game-roll-tray-dead-$index');

Key bigFaceKey(int face) => Key('game-die-face-$face');

/// The big die's idle cube (C-238), shown when no face is known.
const Key idleArtKey = Key('game-die-idle-art');

/// The die-value semantics wrapper around the big die (C-465 D1.4).
const Key diceValueKey = Key('game-screen-dice-value');

/// C-465 D2: the die a seat keeps in the middle of its own yard.
Key seatDieKey(int seat) => Key('board-seat-die-$seat');

Key seatDieFaceKey(int seat, int face) =>
    Key('board-seat-die-face-$seat-$face');

Key seatDieIdleKey(int seat) => Key('board-seat-die-idle-$seat');

/// C-465 D4: another seat's roll record, drawn on the board in its yard.
Key seatRecordKey(int seat) => Key('board-seat-record-$seat');

/// C-377 / C-465 D3: the opponent's thrown die and its two phases.
Key opponentThrowKey(int seat) => Key('opponent-throw-$seat');

Key opponentThrowTumblingKey(int seat) => Key('opponent-throw-tumbling-$seat');

Key opponentThrowLandedKey(int seat, int face) =>
    Key('opponent-throw-landed-$seat-$face');

Key legalRingKey(int seat, int token) => Key('board-legal-ring-$seat-$token');

Key tokenHitKey(int seat, int token) => Key('board-token-hit-$seat-$token');

/// C-462 D5: the face picker bubble and its options.
const Key facePickerKey = Key('board-face-picker');

Key facePickerOptionKey(int face) => Key('board-face-picker-option-$face');

const String _facePickerOptionPrefix = 'board-face-picker-option-';

/// C-471 D3: the hint control. The root carries `game-hint-button`; exactly
/// one of the three state keys sits inside it.
const Key hintButtonKey = Key('game-hint-button');
const Key hintReadyKey = Key('game-hint-ready');
const Key hintWaitingKey = Key('game-hint-waiting');
const Key hintUsedKey = Key('game-hint-used');

/// C-471 D4: the marker on the hinted token and its face chip.
Key boardHintKey(int token) => Key('board-hint-$token');

Key boardHintFaceKey(int face) => Key('board-hint-face-$face');

/// C-471 D4: wraps the face picker option of the hinted face.
Key facePickerHintedKey(int face) => Key('board-face-picker-hinted-$face');

/// C-471 D5: the SharedPreferences key that holds the last game id the hint
/// was spent in.
const String hintUsedPrefsKey = 'session.hintUsedGame';

int _serverIdSeq = 0;

String _nextServerId() {
  _serverIdSeq += 1;
  return 'roll-tray-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> decodeFrame(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String frameType(String text) => decodeFrame(text)['t']! as String;

Map<String, Object?> frameData(String text) =>
    decodeFrame(text)['d']! as Map<String, Object?>;

String _idOf(String text) => decodeFrame(text)['id']! as String;

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

Map<String, Object?> seatJson(
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

List<Map<String, Object?>> twoSeats({
  List<int> mine = const <int>[-1, -1, -1, -1],
  List<int> other = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  seatJson(0, name: 'Sam', tokens: mine),
  seatJson(1, name: 'Bob', tokens: other),
];

Map<String, Object?> faceLegal(int face, List<int> tokens) => <String, Object?>{
  'face': face,
  'tokens': tokens,
};

Map<String, Object?> turnJson({
  required int seat,
  required String phase,
  required int k,
  int? value,
  List<int>? legal,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _roomJson({
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
  int players = 2,
  String? gameId,
  String state = 'PLAYING',
  int? winner,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': 0,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': gameId,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

/// A room snapshot body in wire shape, for a server-initiated `room` push
/// ([RollTrayDrive.push] stamps the sequence number). [gameId], [state] and
/// [winner] default to what every earlier caller got: no game id, PLAYING,
/// no winner.
Map<String, Object?> roomData({
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int players = 2,
  String? gameId,
  String state = 'PLAYING',
  int? winner,
}) => _roomJson(
  seats: seats,
  turn: turn,
  players: players,
  gameId: gameId,
  state: state,
  winner: winner,
);

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

/// Records cues GameScreen plays. The cue ids themselves are not under
/// test here; the list is only what the screen asked to play, in order.
class RecordingFeedback implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

class RollTrayDrive {
  RollTrayDrive({
    required this.controller,
    required this.transport,
    required this.feedback,
    required this.lastSeq,
    required this.enqueueTransport,
  });

  final RoomController controller;
  final FakeTransport transport;
  final RecordingFeedback feedback;
  int lastSeq;

  /// Queues the transport the controller's next connect() returns, for a
  /// reconnect after [transport] is gone.
  final void Function(FakeTransport transport) enqueueTransport;

  Future<void> push(
    WidgetTester tester,
    String type,
    Map<String, Object?> data,
  ) async {
    lastSeq += 1;
    transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': lastSeq}),
    );
    await tester.pump();
    await tester.pump();
  }
}

/// createRoom, then seat_assigned and a room snapshot. [turn] is the
/// snapshot turn object, already in wire shape. [mySeat] is the seat the
/// server assigns this client (0 unless a case needs another view) and
/// [players] the room's player count. [gameId], [state] and [winner] are the
/// snapshot's own fields (defaults: no game id, PLAYING, no winner), and
/// [sendSeatAssigned] false leaves this client with no seat at all.
Future<RollTrayDrive> connectPlaying(
  WidgetTester tester, {
  required Map<String, Object?>? turn,
  List<Map<String, Object?>>? seats,
  int mySeat = 0,
  int players = 2,
  String? gameId,
  String state = 'PLAYING',
  int? winner,
  bool sendSeatAssigned = true,
  List<Duration> autoReconnectDelays = const <Duration>[],
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(rollTrayTestUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
  );
  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  if (sendSeatAssigned) {
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
      ),
    );
  }
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        seats: seats ?? twoSeats(),
        turn: turn,
        players: players,
        gameId: gameId,
        state: state,
        winner: winner,
      ),
    ),
  );
  await future;
  return RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: connector.enqueue,
  );
}

/// The id of a request frame this client sent, for building its reply.
String requestIdOf(String text) => _idOf(text);

/// The server's `error` reply to the request [re] (docs/PROTOCOL.md
/// section 3).
String errorReplyFrame({required String re, required String code}) => _frame(
  type: 'error',
  re: re,
  data: <String, Object?>{'code': code, 'message': code},
);

/// The server's `emote` push (docs/PROTOCOL.md section 25): `{seat, emote}`
/// and no `seq`. [re] is set only on the sender's own copy. [emote] and
/// [seat] are untyped so a case can send what a broken server would.
String emoteFrame({
  required Object? seat,
  required Object? emote,
  String? re,
}) => _frame(
  type: 'emote',
  re: re,
  data: <String, Object?>{'seat': seat, 'emote': emote},
);

/// Delivers [text] (a frame built here) and flushes it with the two bare
/// pumps [RollTrayDrive.push] runs; no fake time passes.
Future<void> pushRaw(
  WidgetTester tester,
  RollTrayDrive drive,
  String text,
) async {
  drive.transport.pushText(text);
  await tester.pump();
  await tester.pump();
}

/// The `emote` requests this client sent from index [from] of the
/// transport's sent frames, whole (type, id, data).
List<Map<String, Object?>> emotesSince(FakeTransport transport, int from) =>
    <Map<String, Object?>>[
      for (final String text in transport.sentRaw.skip(from))
        if (frameType(text) == 'emote') decodeFrame(text),
    ];

/// The `t` of every frame this client sent from index [from].
List<String> sentTypesSince(FakeTransport transport, int from) => <String>[
  for (final String text in transport.sentRaw.skip(from)) frameType(text),
];

/// The server's `room` reply to the request [re], a resume most often.
String roomReplyFrame({
  required String re,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => _frame(
  type: 'room',
  re: re,
  data: _roomJson(seats: seats, turn: turn, seq: seq),
);

Widget rollTrayHarness(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? screen) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: screen!,
      );
    },
    home: child,
  );
}

Future<void> mountGame(
  WidgetTester tester,
  RollTrayDrive drive, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    rollTrayHarness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: drive.feedback,
        child: GameScreen(controller: drive.controller),
      ),
      locale: locale,
      textScale: textScale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Unmounts first so GameScreen cancels its own timers, then disposes
/// the controller. Called from the test body, not only from addTearDown.
Future<void> releaseGame(WidgetTester tester, RollTrayDrive drive) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  drive.controller.dispose();
}

List<Map<String, Object?>> movesSince(FakeTransport transport, int from) {
  final List<Map<String, Object?>> moves = <Map<String, Object?>>[];
  for (final String text in transport.sentRaw.skip(from)) {
    if (frameType(text) == 'move') {
      moves.add(frameData(text));
    }
  }
  return moves;
}

int trayDieCount(WidgetTester tester) {
  int count = 0;
  for (int i = 0; i < 6; i++) {
    if (tester.any(find.byKey(trayDieKey(i)))) {
      count += 1;
    }
  }
  return count;
}

int cueCount(RecordingFeedback feedback, FeedbackCue cue) {
  int count = 0;
  for (final FeedbackCue recorded in feedback.recorded) {
    if (recorded == cue) {
      count += 1;
    }
  }
  return count;
}

/// The tokens of seat 0 that carry a legal ring right now.
List<int> ringedTokens(WidgetTester tester) => <int>[
  for (int token = 0; token < 4; token++)
    if (tester.any(find.byKey(legalRingKey(0, token)))) token,
];

/// Every `board-face-picker-option-<face>` in the tree, as faces, in tree
/// order.
List<int> pickerOptionFaces(WidgetTester tester) {
  final List<int> faces = <int>[];
  for (final Element element in find.byWidgetPredicate((Widget widget) {
    final Key? key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith(_facePickerOptionPrefix);
  }).evaluate()) {
    final ValueKey<String> key = element.widget.key! as ValueKey<String>;
    faces.add(int.parse(key.value.substring(_facePickerOptionPrefix.length)));
  }
  return faces;
}

/// The square the board draws in, centred inside the LudoBoard widget.
Rect boardSquare(WidgetTester tester) {
  final Rect widget = tester.getRect(find.byKey(boardKey));
  final double side = widget.width < widget.height
      ? widget.width
      : widget.height;
  return Rect.fromCenter(center: widget.center, width: side, height: side);
}

/// The yard quadrant of [seat] in view space, inside the board square
/// [board]: the 6 by 6 block [yardQuadrantOrigin] names, run through the
/// same view rotation the board uses for [mySeat]. My own yard is
/// bottom-left in every view.
Rect yardQuadrantViewRect(Rect board, int seat, int? mySeat) {
  final double cell = board.width / 15;
  final int quarters = viewQuarters(mySeat);
  final BoardCell origin = yardQuadrantOrigin(seat);
  final BoardCell a = toView(origin, quarters);
  final BoardCell b = toView(
    BoardCell(
      origin.col + yardQuadrantSide - 1,
      origin.row + yardQuadrantSide - 1,
    ),
    quarters,
  );
  final int minCol = a.col < b.col ? a.col : b.col;
  final int maxCol = a.col < b.col ? b.col : a.col;
  final int minRow = a.row < b.row ? a.row : b.row;
  final int maxRow = a.row < b.row ? b.row : a.row;
  return Rect.fromLTRB(
    board.left + minCol * cell,
    board.top + minRow * cell,
    board.left + (maxCol + 1) * cell,
    board.top + (maxRow + 1) * cell,
  );
}

/// My own seat (0) rolls [face] with no legal token, as the server frames it
/// when the roll voids the turn (docs/PROTOCOL.md section 21.3, rule 4):
/// `rolled` with an empty `legal` and an empty `queue`, then `turn_passed`
/// `no_legal_move`, then the next seat's `turn`. Each frame is flushed with
/// the two bare pumps [RollTrayDrive.push] runs; no fake time passes, so the
/// no-move notice is up when this returns.
Future<void> pushMyNoMoveRoll(
  WidgetTester tester,
  RollTrayDrive drive, {
  required int face,
  int k = 1,
}) async {
  await drive.push(tester, 'rolled', <String, Object?>{
    'seat': 0,
    'value': face,
    'legal': <int>[],
    'deadline_ms': rollTrayDeadlineMs,
    'k': k,
    'reveal': rollTrayReveal,
    'queue': <int>[],
  });
  await drive.push(tester, 'turn_passed', <String, Object?>{
    'seat': 0,
    'reason': 'no_legal_move',
  });
  await drive.push(tester, 'turn', <String, Object?>{
    'seat': 1,
    'phase': 'await_roll',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': <int>[],
  });
}

/// The height of the below-die notice slot while the no-move notice is up.
/// The notice is a `Positioned.fill` child of the slot's `Stack`, and that
/// `Stack` is the nearest ancestor `Stack` of the notice; the `Stack` is
/// sized by the invisible measuring children, so its height is the slot's
/// reserved height.
double noMoveNoticeSlotHeight(WidgetTester tester) {
  final Finder slot = find
      .ancestor(of: find.byKey(noMoveNoticeKey), matching: find.byType(Stack))
      .first;
  return tester.getSize(slot).height;
}
