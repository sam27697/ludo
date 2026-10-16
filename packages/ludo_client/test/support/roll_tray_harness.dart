// Shared driver for the roll-tray screen tests. A real RoomController sits
// on FakeTransport; every room state arrives as a decoded wire frame.
// GameScreen is mounted once per case by the caller.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
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

Key traySelectedKey(int index) => Key('game-roll-tray-selected-$index');

Key trayDeadKey(int index) => Key('game-roll-tray-dead-$index');

Key bigFaceKey(int face) => Key('game-die-face-$face');

Key legalRingKey(int seat, int token) => Key('board-legal-ring-$seat-$token');

Key tokenHitKey(int seat, int token) => Key('board-token-hit-$seat-$token');

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
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
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
  });

  final RoomController controller;
  final FakeTransport transport;
  final RecordingFeedback feedback;
  int lastSeq;

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
/// snapshot turn object, already in wire shape.
Future<RollTrayDrive> connectPlaying(
  WidgetTester tester, {
  required Map<String, Object?>? turn,
  List<Map<String, Object?>>? seats,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(rollTrayTestUrl),
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
      data: _roomJson(seats: seats ?? twoSeats(), turn: turn),
    ),
  );
  await future;
  return RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
  );
}

Widget rollTrayHarness(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
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
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
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
