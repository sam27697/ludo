// Order 432 -- screen tests for decision D4 of
// work/ludo/orders/C-432-timer-steps-survive-resume.md, written from that
// contract, from docs/PROTOCOL.md section 23 and from C-426 D3/D4 only.
//
// D4: whenever the game screen takes a snapshot of a PLAYING room (the room
// the controller already holds when GameScreen mounts, and every later
// `room` frame, a resume answer included), it reads its own seat's
// `timer_steps`. Greater than 0: the C-426 D3 notice (`game-timer-played-
// notice`, `gameTimerPlayedMine`) shows exactly as if a live `by: "timer"`
// frame for my seat had armed it, announced once to TalkBack when armed from
// hidden, not announced again when already shown, cleared by the same three
// D3 events. Equal to 0: a shown notice is dropped. Absent (an older
// server): nothing changes. A FINISHED snapshot shows no notice whatever its
// count, and a snapshot never produces a notice for another seat.
//
// Every case mounts the real GameScreen over a real RoomController and a
// FakeTransport, feeds raw JSON frames by hand, and reads the screen through
// find.byKey, the localized strings and the platform accessibility channel.
// Snapshots are raw JSON, so none of this depends on `SeatState.timerSteps`
// existing; this file compiles on the base commit (12853b9) and every case
// that depends on the new field fails there because the notice never
// appears, not because anything is missing from the build.
//
// Helpers are copied by hand from test/timer_played_notice_test.dart (mount,
// the drop-reconnect-resume dance of its C10, the announcement recorder),
// test/game_screen_resume_after_expiry_test.dart and
// test/feedback_wiring_test.dart (the fake feedback service), per the
// project rule never to import across test files.
//
// Hygiene: one mount per case; no pumpAndSettle (the die pulses while my
// seat is in await_roll); every pump is bounded; every roll or move a case
// sends is answered before the case ends; the controller is disposed in the
// body and, if an expectation throws first, from a tearDown guard.
//
// Reproduce any case: cd packages/ludo_client && flutter test
// test/timer_steps_resume_test.dart --plain-name "<case name>"
//
// Expected on the base commit: R1, R3, R4b, R5, R6, R6b, R6c, R8b and R10
// red (the notice that D4 requires never appears, or never leaves); R2, R4,
// R7, R8 and R9 green and written to stay meaningful once the field is read.
// R4 is green on the base for a reason worth stating: with nothing reading
// `timer_steps`, a notice armed by a live frame survives a resume (C-426
// C10), which is also exactly what D4 requires, so the screen cannot tell
// the two apart; the case guards against an implementation that re-announces
// or drops-and-redraws on the snapshot.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState;
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://timer-steps-resume-test.invalid/ws';
const String _file = 'test/timer_steps_resume_test.dart';

const Key _mineKey = Key('game-timer-played-notice');
const Key _otherKey = Key('game-timer-played-other-notice');
const Key _dieKey = Key('game-die');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

/// Marks "leave the `timer_steps` key out of the seat object".
const Object _absent = Object();

// --- frames ---------------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'timer-steps-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

/// A section 6 seat object. [steps] is the `timer_steps` value; the default
/// leaves the key out, an explicit `null` sends JSON null.
Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
  Object? steps = _absent,
}) {
  final Map<String, Object?> json = <String, Object?>{
    'seat': seat,
    'name': name,
    'connected': connected,
    'tokens': tokens,
    'client_seed': null,
    'seed_origin': null,
  };
  if (!identical(steps, _absent)) {
    json['timer_steps'] = steps;
  }
  return json;
}

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
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

Map<String, Object?> get _awaitRoll => <String, Object?>{
  'seat': 0,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'k': 0,
};

Map<String, Object?> get _awaitMove => <String, Object?>{
  'seat': 0,
  'phase': 'await_move',
  'deadline_ms': 45000,
  'k': 1,
  'value': 5,
  'legal': const <int>[0, 1],
};

Map<String, Object?> get _finishedTurn => <String, Object?>{
  'seat': 1,
  'phase': 'finished',
  'deadline_ms': 0,
  'k': 9,
};

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

class _Announcement {
  const _Announcement(this.message, this.textDirectionIndex);
  final String message;
  final int textDirectionIndex;

  @override
  String toString() => '"$message" (direction index $textDirectionIndex)';
}

/// One mounted game: controller, the live transport, the connector that hands
/// out the next one, the recorded announcements and cues.
class _Rig {
  _Rig({
    required this.controller,
    required this.transport,
    required this.connector,
    required this.seq,
    required this.fake,
    required this.announcements,
  });

  final RoomController controller;
  FakeTransport transport;
  final _Connector connector;
  final _Seq seq;
  final _FakeFeedbackService fake;
  final List<_Announcement> announcements;
  bool _disposed = false;

  void disposeOnce() {
    if (!_disposed) {
      _disposed = true;
      controller.dispose();
    }
  }
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
  Locale locale = const Locale('en'),
}) async {
  final List<_Announcement> announcements = <_Announcement>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        announcements.add(
          _Announcement(
            data['message'] as String,
            data['textDirection'] as int,
          ),
        );
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
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
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
      locale: locale,
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

/// The socket dies, the player taps reconnect, and the server answers the
/// `resume` with [seats] / [turn] as a `room` snapshot. Copied from C10 of
/// test/timer_played_notice_test.dart; the pumps are bounded and the resume
/// request is answered, so no timer outlives the case.
Future<void> _dropAndResume(
  WidgetTester tester,
  _Rig rig, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  String state = 'PLAYING',
  int? winner,
}) async {
  rig.transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    rig.controller.phase,
    RoomPhase.closed,
    reason: 'setup: the far side vanishing must close the controller',
  );
  expect(
    find.byKey(_connectionLostKey),
    findsOneWidget,
    reason: 'setup: the connection-lost body must show before reconnect',
  );

  final FakeTransport resumeTransport = FakeTransport();
  rig.connector.enqueue(resumeTransport);
  await tester.tap(find.byKey(_reconnectButtonKey));
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  expect(
    resumeTransport.sentRaw,
    isNotEmpty,
    reason: 'setup: reconnect must have sent a resume request',
  );
  expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
  final String resumeId = _idOf(resumeTransport.sentRaw.last);
  rig.transport = resumeTransport;
  resumeTransport.pushText(
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

/// A live `by: "timer"` frame for seat 0 (C-426 D3), the way a connected
/// player is told.
Future<void> _armLive(WidgetTester tester, _Rig rig) async {
  rig.transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': 0,
        'token': 0,
        'from': 2,
        'to': 2,
        'captured': const <Object?>[],
        'extra_roll': false,
        'by': 'timer',
        'seq': rig.seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Unmounts, then disposes the controller, so no timer survives the case.
Future<void> _finish(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(const SizedBox.shrink());
  rig.disposeOnce();
  await tester.pump();
}

List<_Announcement> _mineAnnouncements(_Rig rig, AppLocalizations loc) => rig
    .announcements
    .where((_Announcement a) => a.message == loc.gameTimerPlayedMine)
    .toList();

String _why(String name, String rule, String defect) =>
    'C-432 $rule. Catches: $defect. Reproduce: cd packages/ludo_client && '
    'flutter test $_file --plain-name "$name"';

List<Map<String, Object?>> _seats({
  Object? mine = _absent,
  Object? other = _absent,
  List<int> myTokens = const <int>[2, 10, -1, -1],
}) => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam', tokens: myTokens, steps: mine),
  _seatJson(1, name: 'Bob', steps: other),
];

void main() {
  // ==========================================================================
  // R1 and R10: mounting into a PLAYING room whose own seat has timer_steps.
  // ==========================================================================
  group('R1 and R10: mount into a room that already says the timer played', () {
    testWidgets(
      'R1 mount into PLAYING with own timer_steps 2: the notice shows the '
      'en text and is announced once',
      (tester) async {
        const String name =
            'R1 mount into PLAYING with own timer_steps 2: the notice shows '
            'the en text and is announced once';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 2, other: 0),
          turn: _awaitRoll,
        );
        final AppLocalizations loc = _locOf(tester);
        expect(loc.localeName, 'en', reason: 'setup: the en locale is mounted');

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: _why(
            name,
            'D4 (> 0 on the room the controller holds at mount shows the '
                'C-426 D3 notice, game-timer-played-notice)',
            'a screen that only reacts to live by: timer frames, so a '
                'player whose app was killed and relaunched into a moved '
                'board is told nothing',
          ),
        );
        expect(
          tester.widget<Text>(find.byKey(_mineKey)).data,
          loc.gameTimerPlayedMine,
          reason: _why(
            name,
            'D4/D5 (the text is gameTimerPlayedMine, no new string)',
            'a snapshot notice with its own wording',
          ),
        );
        expect(
          _mineAnnouncements(rig, loc),
          hasLength(1),
          reason: _why(
            name,
            'D4 (announced once to TalkBack when armed from hidden); '
                'recorded ${rig.announcements}',
            'a snapshot-armed notice that is silent to TalkBack, or '
                'announced on every rebuild',
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(
          _mineAnnouncements(rig, loc),
          hasLength(1),
          reason: _why(
            name,
            'D4 (not re-announced while already shown); recorded '
                '${rig.announcements}',
            'an announcement fired from build or from the countdown tick',
          ),
        );
        await _finish(tester, rig);
      },
    );

    testWidgets(
      'R10 ar: the same mount shows the exact ar string and announces it '
      'once, right to left',
      (tester) async {
        const String name =
            'R10 ar: the same mount shows the exact ar string and announces '
            'it once, right to left';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 2, other: 0),
          turn: _awaitRoll,
          locale: const Locale('ar'),
        );
        final AppLocalizations loc = _locOf(tester);
        expect(loc.localeName, 'ar', reason: 'setup: the ar locale is mounted');
        expect(loc.gameTimerPlayedMine, isNotEmpty);

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: _why(
            name,
            'D4 + C-426 D9 (the ar notice from a snapshot)',
            'a snapshot notice only wired for the en path',
          ),
        );
        expect(
          tester.widget<Text>(find.byKey(_mineKey)).data,
          loc.gameTimerPlayedMine,
          reason: _why(
            name,
            'D9 (the ar text is exactly gameTimerPlayedMine)',
            'a hard-coded or transliterated string',
          ),
        );
        final List<_Announcement> mine = _mineAnnouncements(rig, loc);
        expect(
          mine,
          hasLength(1),
          reason: _why(
            name,
            'D4 (one announcement in the active locale); recorded '
                '${rig.announcements}',
            'an announcement in the wrong locale or none',
          ),
        );
        expect(
          mine.single.textDirectionIndex,
          TextDirection.rtl.index,
          reason: _why(
            name,
            'D4 (the announcement carries the active locale\'s direction)',
            'an ar announcement sent left to right',
          ),
        );
        await _finish(tester, rig);
      },
    );
  });

  // ==========================================================================
  // R2: nothing to say.
  // ==========================================================================
  group('R2: a mount with 0, with the key absent, or with JSON null', () {
    final Map<String, Object?> variants = <String, Object?>{
      'timer_steps 0': 0,
      'the key absent (an older server)': _absent,
      'timer_steps JSON null': null,
    };
    for (final MapEntry<String, Object?> variant in variants.entries) {
      testWidgets('R2 mount with own ${variant.key}: no notice, no '
          'announcement', (tester) async {
        final String name =
            'R2 mount with own ${variant.key}: no notice, no announcement';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: variant.value, other: variant.value),
          turn: _awaitRoll,
        );
        final AppLocalizations loc = _locOf(tester);
        expect(
          find.byKey(_dieKey),
          findsOneWidget,
          reason: 'setup: the playing board must be mounted (my die is up)',
        );
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason: _why(
            name,
            'D4 (== 0 or absent shows nothing)',
            'a screen that shows the notice for any snapshot, or reads an '
                'absent key as non-zero',
          ),
        );
        expect(find.byKey(_otherKey), findsNothing);
        expect(
          _mineAnnouncements(rig, loc),
          isEmpty,
          reason: _why(
            name,
            'D4 (nothing armed, nothing announced); recorded '
                '${rig.announcements}',
            'an announcement fired without a notice',
          ),
        );
        await _finish(tester, rig);
      });
    }
  });

  // ==========================================================================
  // R3, R4, R4b, R5: the drop, the resume, the answer.
  // ==========================================================================
  group('R3 to R5: the resume answer', () {
    testWidgets(
      'R3 not armed, drop, resume answer with own timer_steps 1: the notice '
      'shows and is announced once',
      (tester) async {
        const String name =
            'R3 not armed, drop, resume answer with own timer_steps 1: the '
            'notice shows and is announced once';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 0, other: 0),
          turn: _awaitRoll,
        );
        final AppLocalizations loc = _locOf(tester);
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason: 'setup: nothing is shown before the drop',
        );

        await _dropAndResume(
          tester,
          rig,
          seats: _seats(mine: 1, other: 0),
          turn: _awaitRoll,
        );

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: _why(
            name,
            'D4 (a resume answer is a snapshot of a PLAYING room; > 0 shows '
                'the notice)',
            'the exact defect C-432 exists for: steps the timer took while '
                'the phone was off the socket are never announced',
          ),
        );
        expect(
          tester.widget<Text>(find.byKey(_mineKey)).data,
          loc.gameTimerPlayedMine,
        );
        expect(
          _mineAnnouncements(rig, loc),
          hasLength(1),
          reason: _why(
            name,
            'D4 (announced once when armed from hidden); recorded '
                '${rig.announcements}',
            'a resume-armed notice that TalkBack never hears',
          ),
        );
        await _finish(tester, rig);
      },
    );

    testWidgets(
      'R4 armed by a live by: timer frame, drop, resume answer with own '
      'timer_steps 1: still shown, no second announcement',
      (tester) async {
        const String name =
            'R4 armed by a live by: timer frame, drop, resume answer with '
            'own timer_steps 1: still shown, no second announcement';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 0, other: 0),
          turn: _awaitRoll,
        );
        final AppLocalizations loc = _locOf(tester);
        await _armLive(tester, rig);
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: 'setup: the live frame arms the notice (C-426 D3)',
        );
        expect(
          _mineAnnouncements(rig, loc),
          hasLength(1),
          reason: 'setup: arming from hidden announces once',
        );

        await _dropAndResume(
          tester,
          rig,
          seats: _seats(mine: 1, other: 0),
          turn: _awaitRoll,
        );

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: _why(
            name,
            'D4 (> 0 on a snapshot while shown leaves it shown)',
            'a snapshot path that rebuilds the notice state from scratch '
                'and drops it',
          ),
        );
        expect(
          _mineAnnouncements(rig, loc),
          hasLength(1),
          reason: _why(
            name,
            'D4 (not re-announced when already shown); recorded '
                '${rig.announcements}',
            'a snapshot that announces every time it sees a count above 0',
          ),
        );
        await _finish(tester, rig);
      },
    );

    testWidgets(
      'R4b armed from a snapshot at mount (2), drop, resume answer with 3: '
      'still one announcement',
      (tester) async {
        const String name =
            'R4b armed from a snapshot at mount (2), drop, resume answer '
            'with 3: still one announcement';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 2, other: 0),
          turn: _awaitRoll,
        );
        final AppLocalizations loc = _locOf(tester);
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: 'setup: D4 arms the notice from the mounted snapshot',
        );

        await _dropAndResume(
          tester,
          rig,
          seats: _seats(mine: 3, other: 0),
          turn: _awaitRoll,
        );

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: _why(
            name,
            'D4 (a larger count on a snapshot keeps the notice up)',
            'a notice keyed to the count that vanishes when the count '
                'changes',
          ),
        );
        expect(
          _mineAnnouncements(rig, loc),
          hasLength(1),
          reason: _why(
            name,
            'D4 (a second snapshot with a count > 0 does not re-announce); '
                'recorded ${rig.announcements}',
            'announcing on every snapshot instead of on arming from hidden',
          ),
        );
        await _finish(tester, rig);
      },
    );

    testWidgets(
      'R5 armed by a live by: timer frame, drop, resume answer with own '
      'timer_steps 0: the notice is dropped',
      (tester) async {
        const String name =
            'R5 armed by a live by: timer frame, drop, resume answer with '
            'own timer_steps 0: the notice is dropped';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 0, other: 0),
          turn: _awaitRoll,
        );
        await _armLive(tester, rig);
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason: 'setup: the live frame arms the notice (C-426 D3)',
        );

        await _dropAndResume(
          tester,
          rig,
          seats: _seats(mine: 0, other: 0),
          turn: _awaitRoll,
        );

        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason: _why(
            name,
            'D4 (== 0 drops a shown notice: section 23 rule 3, the seat\'s '
                'own client has since played and the server reset the '
                'count)',
            'a notice that outlives the move that made it stale, shown to '
                'a player who already played on another device or session',
          ),
        );
        await _finish(tester, rig);
      },
    );
  });

  // ==========================================================================
  // R6: the same three clearing events as a live arm.
  // ==========================================================================
  group('R6: a snapshot-armed notice clears on the three D3 events', () {
    testWidgets('R6 armed from a snapshot, then my sent die tap: dropped', (
      tester,
    ) async {
      const String name =
          'R6 armed from a snapshot, then my sent die tap: dropped';
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: 2, other: 0),
        turn: _awaitRoll,
      );
      expect(
        find.byKey(_mineKey),
        findsOneWidget,
        reason: 'setup: D4 arms the notice from the mounted snapshot',
      );

      await tester.tap(find.byKey(_dieKey));
      await tester.pump();

      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason: _why(
          name,
          'D4 (cleared by the same three D3 events: a die tap that '
              'sends roll)',
          'a snapshot-armed notice that sticks for ever because only '
              'live-armed ones were wired to the clear',
        ),
      );
      final String rollId = _idOf(
        rig.transport.sentRaw.firstWhere((String s) => _typeOf(s) == 'roll'),
      );
      rig.transport.pushText(
        _frame(
          type: 'rolled',
          re: rollId,
          data: <String, Object?>{
            'seat': 0,
            'value': 4,
            'legal': const <int>[0, 1],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'f' * 64,
            'seq': rig.seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason: _why(
          name,
          'D4 (the answer to my roll is a frame, not a snapshot, and '
              'arms nothing)',
          'a re-arm from stale snapshot state after the clear',
        ),
      );
      await _finish(tester, rig);
    });

    testWidgets('R6b armed from a snapshot, then my sent token tap: dropped', (
      tester,
    ) async {
      const String name =
          'R6b armed from a snapshot, then my sent token tap: dropped';
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: 2, other: 0),
        turn: _awaitMove,
      );
      expect(
        find.byKey(_mineKey),
        findsOneWidget,
        reason: 'setup: D4 arms the notice from the mounted snapshot',
      );

      await tester.tap(find.byKey(_hitKey(0, 0)));
      await tester.pump();

      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason: _why(
          name,
          'D4 (cleared by a token tap that sends move)',
          'a snapshot-armed notice that survives my own move',
        ),
      );
      final String moveId = _idOf(
        rig.transport.sentRaw.firstWhere((String s) => _typeOf(s) == 'move'),
      );
      rig.transport.pushText(
        _frame(
          type: 'moved',
          re: moveId,
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 2,
            'to': 2,
            'captured': const <Object?>[],
            'extra_roll': false,
            'seq': rig.seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await _finish(tester, rig);
    });

    testWidgets('R6c armed from a snapshot, then game over: dropped', (
      tester,
    ) async {
      const String name = 'R6c armed from a snapshot, then game over: dropped';
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: 2, other: 0),
        turn: _awaitRoll,
      );
      expect(
        find.byKey(_mineKey),
        findsOneWidget,
        reason: 'setup: D4 arms the notice from the mounted snapshot',
      );

      rig.transport.pushText(
        _frame(
          type: 'game_over',
          data: <String, Object?>{
            'winner': 1,
            'verify_url': 'https://timer-steps-resume-test.invalid/v/1',
            'seq': rig.seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason: _why(
          name,
          'D4 (cleared by game over)',
          'a notice left over the end of the game',
        ),
      );
      await _finish(tester, rig);
    });
  });

  // ==========================================================================
  // R7: FINISHED shows nothing.
  // ==========================================================================
  group('R7: a FINISHED snapshot shows no notice whatever its count', () {
    testWidgets('R7 resume answer FINISHED with own timer_steps 3: no notice', (
      tester,
    ) async {
      const String name =
          'R7 resume answer FINISHED with own timer_steps 3: no notice';
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: 0, other: 0),
        turn: _awaitRoll,
      );
      final AppLocalizations loc = _locOf(tester);

      await _dropAndResume(
        tester,
        rig,
        state: 'FINISHED',
        winner: 1,
        seats: _seats(mine: 3, other: 1),
        turn: _finishedTurn,
      );

      expect(
        rig.controller.room!.state,
        RoomState.finished,
        reason: 'setup: the controller must hold the FINISHED snapshot',
      );
      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'setup: the game screen is still the mounted screen',
      );
      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason: _why(
          name,
          'D4 (a FINISHED snapshot shows no notice whatever its count; '
              'section 23 rule 3 keeps the count at game_over)',
          'the end card or the finished board carrying a "played for '
              'you" line about a game that is over',
        ),
      );
      expect(find.byKey(_otherKey), findsNothing);
      expect(
        _mineAnnouncements(rig, loc),
        isEmpty,
        reason: _why(
          name,
          'D4 (nothing armed on FINISHED); recorded ${rig.announcements}',
          'a TalkBack announcement about a finished game',
        ),
      );
      await _finish(tester, rig);
    });

    testWidgets(
      'R7b mount straight into FINISHED with own timer_steps 3: no notice',
      (tester) async {
        const String name =
            'R7b mount straight into FINISHED with own timer_steps 3: no '
            'notice';
        final _Rig rig = await _start(
          tester,
          state: 'FINISHED',
          winner: 1,
          seats: _seats(mine: 3, other: 1),
          turn: _finishedTurn,
        );
        final AppLocalizations loc = _locOf(tester);

        expect(
          rig.controller.room!.state,
          RoomState.finished,
          reason: 'setup: the controller holds a FINISHED room at mount',
        );
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason: _why(
            name,
            'D4 (the mount-time read also ignores FINISHED)',
            'the mount path skipping the PLAYING check the resume path has',
          ),
        );
        expect(_mineAnnouncements(rig, loc), isEmpty);
        await _finish(tester, rig);
      },
    );
  });

  // ==========================================================================
  // R8: never another seat's notice from a snapshot.
  // ==========================================================================
  group('R8: a snapshot never produces a notice for another seat', () {
    testWidgets(
      'R8 another seat at 4 and mine at 0, at mount and on a resume answer: '
      'neither notice',
      (tester) async {
        const String name =
            'R8 another seat at 4 and mine at 0, at mount and on a resume '
            'answer: neither notice';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 0, other: 4),
          turn: _awaitRoll,
        );
        final AppLocalizations loc = _locOf(tester);
        expect(
          find.byKey(_dieKey),
          findsOneWidget,
          reason: 'setup: the playing board must be mounted',
        );
        expect(
          find.byKey(_otherKey),
          findsNothing,
          reason: _why(
            name,
            'D4 + C-426 D4 (another seat\'s notice stays live-only; a '
                'snapshot count of 4 on seat 1 is not news)',
            'the snapshot path reusing the other-seat branch and showing '
                '"Bob ran out of time" for a step taken minutes ago',
          ),
        );
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason: _why(
            name,
            'D4 (my count is 0)',
            'the other seat\'s count read as mine',
          ),
        );

        await _dropAndResume(
          tester,
          rig,
          seats: _seats(mine: 0, other: 5),
          turn: _awaitRoll,
        );

        expect(
          find.byKey(_otherKey),
          findsNothing,
          reason: _why(
            name,
            'D4 + C-426 D4 (also on a resume answer)',
            'the other-seat notice armed from a snapshot',
          ),
        );
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason: _why(
            name,
            'D4 (my count is still 0)',
            'the other seat\'s count read as mine on the resume path',
          ),
        );
        expect(
          rig.announcements.where(
            (_Announcement a) => a.message == loc.gameTimerPlayedOther('Bob'),
          ),
          isEmpty,
          reason: _why(
            name,
            'D4 (no announcement about another seat from a snapshot); '
                'recorded ${rig.announcements}',
            'a TalkBack announcement for a step the player did not see',
          ),
        );
        await _finish(tester, rig);
      },
    );

    testWidgets('R8b mine at 1 and another seat at 4: only my notice shows', (
      tester,
    ) async {
      const String name =
          'R8b mine at 1 and another seat at 4: only my notice shows';
      final _Rig rig = await _start(
        tester,
        seats: _seats(mine: 1, other: 4),
        turn: _awaitRoll,
      );
      final AppLocalizations loc = _locOf(tester);

      expect(
        find.byKey(_mineKey),
        findsOneWidget,
        reason: _why(
          name,
          'D4 (my own seat\'s count decides, whatever the others read)',
          'a screen that sums or maxes the counts, or reads seat 1\'s '
              'instead of mine',
        ),
      );
      expect(
        find.byKey(_otherKey),
        findsNothing,
        reason: _why(
          name,
          'D4 + C-426 D4 (no other-seat notice from a snapshot)',
          'both notices competing for the one slot',
        ),
      );
      expect(
        _mineAnnouncements(rig, loc),
        hasLength(1),
        reason: _why(
          name,
          'D4 (one announcement, mine); recorded ${rig.announcements}',
          'an extra announcement for the other seat',
        ),
      );
      await _finish(tester, rig);
    });
  });

  // ==========================================================================
  // R9: no feedback cue from a snapshot.
  // ==========================================================================
  group('R9: arming from a snapshot records no feedback cue', () {
    testWidgets(
      'R9 mount with 2 then a resume answer with 1: the fake feedback '
      'service records nothing',
      (tester) async {
        const String name =
            'R9 mount with 2 then a resume answer with 1: the fake feedback '
            'service records nothing';
        final _Rig rig = await _start(
          tester,
          seats: _seats(mine: 2, other: 0),
          turn: _awaitRoll,
        );
        expect(
          rig.fake.recorded,
          isEmpty,
          reason: _why(
            name,
            'D5 + C-426 D6 (no new cue, haptic or sound; a snapshot is not '
                'a game event); recorded ${rig.fake.recorded}',
            'a snapshot-armed notice that plays a sound or a haptic, which '
                'every app resume would then repeat',
          ),
        );

        await _dropAndResume(
          tester,
          rig,
          seats: _seats(mine: 1, other: 0),
          turn: _awaitRoll,
        );

        expect(
          rig.fake.recorded,
          isEmpty,
          reason: _why(
            name,
            'D5 + C-426 D6 (the resume answer plays nothing either); '
                'recorded ${rig.fake.recorded}',
            'a cue on the resume path',
          ),
        );
        await _finish(tester, rig);
      },
    );
  });
}
