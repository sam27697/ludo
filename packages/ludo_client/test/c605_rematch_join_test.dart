// C-605 (order 605t): a friend joining the rematch table is seen and spoken,
// not only felt, and the Arabic spoken roll line is grammatical. Written from
// work/ludo/orders/605-rematch-join-seen-and-ar-roll-line.md (D1 to D4)
// alone, never from the implementation.
//
// Real GameScreen over a real RoomController on a FakeTransport, played to
// game_over and then to a rematch lobby (a `room` push with a `rematch`
// block, PROTOCOL 16.2), the road test/finished_card_survives_rematch_test.dart
// takes. A recording FeedbackService sits behind a FeedbackScope the way
// test/friend_joined_test.dart (C-599) does, and the accessibility channel is
// mocked to read what the screen announces.
//
// What the cases pin, by the order's letters:
//   a  one join: the line, its text, its mark, its place above the ready
//      chips, 2.5 s of life, one announcement, one cue
//   b  the same in Arabic, laid out right to left
//   c  two joins 1 s apart: the newer replaces the line and restarts the
//      2.5 s, two announcements in order, two cues
//   d  a frame naming my own seat: nothing (green on a tree without the work)
//   e  the joined seat's ready chip enters inside a SeatEntrance; chips there
//      at the card's first build do not
//   f  reduced motion: same times, no fade
//   g  the Arabic spoken roll line, for my roll and a friend's, from a played
//      game, with no lam-prefix
// plus the ugly neighbours: a malformed frame, a join in a game in progress
// (D2: cue unchanged, nothing new shown), a join that arrives with the screen
// about to go, a 40-character name at text scale 2 on a narrow card.
//
// Observations are deltas (what appeared after the frame), so an unrelated
// announcement the screen makes for its own reasons cannot fail a case.
// Time is the test clock: every wait is a pump of a stated length.
//
// Every failure reason names the scenario and carries the frames pushed and
// the pumps made so far (Scn.why), which is the whole recipe to replay it.
// Nothing here is random.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/seat_entrance.dart';
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c605-rematch-join-test.invalid/ws';
const String _roomCode = 'K7M2QP';
const String _verifyUrl = 'https://provefair.app/v/c605-rematch-join';
const Key _lineKey = Key('end-card-friend-joined-line');
const Key _historyKey = Key('game-screen-roll-history');

Key _chipKey(int seat) => Key('end-card-ready-$seat');

/// How long the line lives, from the contract.
const int _holdMs = 2500;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c605-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

/// A PLAYING room, or (with [rematchBy]) the section 16.2 rematch LOBBY that
/// follows its end: new chain, no game, no turn, `rematch {by, ready: [by]}`.
Map<String, Object?> _roomJson({
  required List<(int seat, String name)> seats,
  required int seq,
  int? rematchBy,
}) {
  final bool lobby = rematchBy != null;
  return <String, Object?>{
    'code': _roomCode,
    'state': lobby ? 'LOBBY' : 'PLAYING',
    'host_seat': 0,
    'players': 4,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
    },
    'chain_commit': (lobby ? 'b' : 'a') * 64,
    'chain_index': lobby ? 1 : 0,
    'game_id': lobby ? null : '7f3a9c1e5b2d4068',
    'client_seeds': lobby ? null : '0:sam-seed|2:friend-seed',
    'seats': <Map<String, Object?>>[
      for (final (int seat, String name) in seats) _seatJson(seat, name),
    ],
    'turn': lobby
        ? null
        : <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
    'winner': null,
    'seq': seq,
    if (lobby)
      'rematch': <String, Object?>{
        'by': rematchBy,
        'ready': <int>[rematchBy],
      },
  };
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

/// The recording seam behind the FeedbackScope: every cue the screen plays.
class _RecordingFeedback implements FeedbackService {
  final List<FeedbackCue> played = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) => played.add(cue);

  int get joinCues =>
      played.where((FeedbackCue c) => c.id == 'friend_joined').length;
}

/// A scenario's replay log: every frame pushed and every pump made.
class Scn {
  Scn(this.name);

  final String name;
  final List<String> steps = <String>[];

  void log(String step) => steps.add(step);

  String get why => 'scenario "$name"; steps so far: ${steps.join(' | ')}';
}

typedef _Roll = (int seat, int k, int face);

class _Rig {
  _Rig({
    required this.tester,
    required this.scn,
    required this.controller,
    required this.transport,
    required this.feedback,
    required this.said,
    required this.dirs,
    required this.seq,
  });

  final WidgetTester tester;
  final Scn scn;
  final RoomController controller;
  final FakeTransport transport;
  final _RecordingFeedback feedback;
  final List<String> said;
  final List<int> dirs;

  /// The room seq the controller holds; the next state change carries +1.
  int seq;

  int elapsedMs = 0;
  final Set<String> _answered = <String>{};

  Future<void> pump([int ms = 0]) async {
    elapsedMs += ms;
    scn.log('pump ${ms}ms (t=${elapsedMs}ms)');
    await tester.pump(Duration(milliseconds: ms));
  }

  /// Bounded pumps of 250 ms chunks, so animations and timers run.
  Future<void> settle(int ms) async {
    int left = ms;
    while (left > 0) {
      final int step = left > 250 ? 250 : left;
      await pump(step);
      left -= step;
    }
    await pump();
  }

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    bool bumpSeq = true,
  }) async {
    if (bumpSeq) {
      seq += 1;
    }
    final Map<String, Object?> full = <String, Object?>{
      ...data,
      if (bumpSeq) 'seq': seq,
    };
    scn.log('push $type $full (t=${elapsedMs}ms)');
    transport.pushText(_frame(type: type, data: full));
    await tester.pump();
    await tester.pump();
  }

  /// One `player_joined` with the next seq. Time does not advance.
  Future<void> join(int seat, String name) =>
      push('player_joined', <String, Object?>{'seat': seat, 'name': name});

  /// A `player_joined` with a hand-built body and the next seq.
  Future<void> joinRaw(Map<String, Object?> data) =>
      push('player_joined', data);

  Future<void> rolled(_Roll roll) => push('rolled', <String, Object?>{
    'seat': roll.$1,
    'value': roll.$3,
    'legal': const <int>[0],
    'deadline_ms': 45000,
    'k': roll.$2,
    'reveal': 'c' * 64,
  });

  Future<void> gameOver(int winner) => push('game_over', <String, Object?>{
    'winner': winner,
    'verify_url': _verifyUrl,
  });

  /// A finished room with no transcript asks for game_log; refuse it so the
  /// card settles (the way test/c601_roll_history_test.dart does).
  Future<void> refuseGameLogs() async {
    for (final String raw in List<String>.of(transport.sentRaw)) {
      if (_typeOf(raw) == 'game_log' && _answered.add(_idOf(raw))) {
        scn.log('refuse game_log ${_idOf(raw)}');
        transport.pushText(
          _frame(
            type: 'error',
            re: _idOf(raw),
            data: <String, Object?>{
              'code': 'RATE_LIMITED',
              'message': 'game_log',
            },
          ),
        );
      }
    }
    await tester.pump();
    await tester.pump();
  }

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  Finder get line => find.byKey(_lineKey);

  Finder get lineTexts =>
      find.descendant(of: line, matching: find.byType(Text), matchRoot: true);

  List<String> get lineStrings => lineTexts
      .evaluate()
      .map((Element e) => _textOf(e.widget as Text))
      .toList();

  Finder get lineMarks =>
      find.descendant(of: line, matching: find.byType(SeatMark));

  /// What was announced from index [from] on, restricted to texts that name
  /// [needle].
  List<String> saidAbout(String needle, {int from = 0}) =>
      said.sublist(from).where((String s) => s.contains(needle)).toList();
}

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

typedef _Body = Future<void> Function(_Rig rig);

/// Mounts a GameScreen on a 4-seat room (me seat 0 "Sam", seat 2 [seat2Name]),
/// plays [rolls] and a game_over won by seat 2, pumps past the end hold and,
/// with [rematchBy], opens a rematch lobby asked by that seat. Then runs
/// [body].
Future<void> _scenario(
  WidgetTester tester,
  String name,
  _Body body, {
  int? rematchBy = 0,
  Locale locale = const Locale('en'),
  bool reduceMotion = false,
  double width = 390,
  double textScale = 1.0,
  String seat2Name = 'Lina',
  List<_Roll> rolls = const <_Roll>[],
  bool finish = true,
}) async {
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final SemanticsHandle semantics = tester.ensureSemantics();
  final Scn scn = Scn(name);
  final List<String> said = <String>[];
  final List<int> dirs = <int>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        said.add(data['message'] as String);
        dirs.add(data['textDirection'] as int);
      }
      return null;
    },
  );
  addTearDown(
    () => messenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    ),
  );

  final List<(int, String)> seats = <(int, String)>[(0, 'Sam'), (2, seat2Name)];
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _RecordingFeedback recorder = _RecordingFeedback();
  try {
    final Future<void> created = controller.createRoom(name: 'Sam', players: 4);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    final String requestId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: requestId,
        data: _roomJson(seats: seats, seq: 1),
      ),
    );
    await created;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: buildAppTheme(),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduceMotion,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: recorder,
          child: GameScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    final _Rig rig = _Rig(
      tester: tester,
      scn: scn,
      controller: controller,
      transport: transport,
      feedback: recorder,
      said: said,
      dirs: dirs,
      seq: 1,
    );
    scn.log(
      'mounted seats=$seats locale=${locale.languageCode} '
      'reduceMotion=$reduceMotion width=$width textScale=$textScale',
    );
    if (finish) {
      for (final _Roll roll in rolls) {
        await rig.rolled(roll);
      }
      await rig.gameOver(2);
      expect(
        controller.room?.state,
        RoomState.finished,
        reason: 'fixture: game_over must finish the room; ${scn.why}',
      );
      await rig.settle(kEndCardHoldLimit.inMilliseconds + 300);
      await rig.refuseGameLogs();
      if (rematchBy != null) {
        rig.seq += 1;
        scn.log('push room (rematch lobby by seat $rematchBy)');
        transport.pushText(
          _frame(
            type: 'room',
            data: _roomJson(seats: seats, seq: rig.seq, rematchBy: rematchBy),
          ),
        );
        await tester.pump();
        await tester.pump();
        await rig.settle(1500);
        expect(
          controller.room?.state,
          RoomState.lobby,
          reason: 'fixture: the rematch lobby is the live room; ${scn.why}',
        );
        expect(
          controller.room?.rematch?.by,
          rematchBy,
          reason: 'fixture: the rematch block was applied; ${scn.why}',
        );
        expect(
          find.byKey(
            rematchBy == 0 ? _chipKey(0) : const Key('end-card-rematch-ask'),
          ),
          findsOneWidget,
          reason:
              'fixture: the end card shows ${rematchBy == 0 ? 'my ready chip' : 'the ask line'} '
              'in the rematch lobby; ${scn.why}',
        );
      }
    }
    await body(rig);
  } finally {
    // Unmount first so no screen timer outlives the test, then release.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    controller.dispose();
    semantics.dispose();
  }
}

// --- observing the chip entrance and any fade --------------------------------

/// The SeatEntrance widgets that are, or sit above, [target].
List<SeatEntrance> _entrancesAbove(WidgetTester tester, Finder target) => find
    .ancestor(of: target, matching: find.byType(SeatEntrance), matchRoot: true)
    .evaluate()
    .map((Element e) => e.widget as SeatEntrance)
    .toList();

/// The scale the entrance above [target] is drawn at now (1.0 when there is
/// no entrance above it).
double _entranceScale(WidgetTester tester, Finder target) {
  final Finder entrance = find.ancestor(
    of: target,
    matching: find.byType(SeatEntrance),
    matchRoot: true,
  );
  if (entrance.evaluate().isEmpty) {
    return 1.0;
  }
  final Finder scale = find.descendant(
    of: entrance.first,
    matching: find.byType(ScaleTransition),
  );
  if (scale.evaluate().isEmpty) {
    return 1.0;
  }
  return tester.widget<ScaleTransition>(scale.first).scale.value;
}

/// The product of every opacity above [target]: FadeTransition, Opacity and
/// AnimatedOpacity (its target). 1.0 means nothing above it fades.
double _opacityAbove(WidgetTester tester, Finder target) {
  double opacity = 1.0;
  final Finder fades = find.ancestor(
    of: target,
    matching: find.byWidgetPredicate(
      (Widget w) => w is FadeTransition || w is Opacity || w is AnimatedOpacity,
    ),
  );
  for (final Element element in fades.evaluate()) {
    final Widget w = element.widget;
    if (w is FadeTransition) {
      opacity *= w.opacity.value;
    } else if (w is Opacity) {
      opacity *= w.opacity;
    } else if (w is AnimatedOpacity) {
      opacity *= w.opacity;
    }
  }
  return opacity;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- a: one join ------------------------------------------------------------
  group('(a) one join at the rematch lobby, en', () {
    testWidgets('the line reads "Karim joined" with seat 1\'s mark, directly '
        'above the ready chips', (WidgetTester tester) async {
      await _scenario(tester, 'a-line-shape', (_Rig rig) async {
        expect(
          rig.line,
          findsNothing,
          reason: 'fixture: no line before any join; ${rig.scn.why}',
        );
        await rig.join(1, 'Karim');
        const String expected = 'Karim joined';
        expect(
          rig.loc.lobbyFriendJoined('Karim'),
          expected,
          reason: 'fixture: the en string is "{name} joined"',
        );
        expect(
          rig.line,
          findsOneWidget,
          reason:
              'C-605 D1: end-card-friend-joined-line appears when a '
              'player_joined for seat 1 (mine is 0) reaches the end card in '
              'its rematch lobby; none found; ${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>[expected]),
          reason:
              'C-605 D1: the line carries one Text, "$expected"; got '
              '${rig.lineStrings}; ${rig.scn.why}',
        );
        expect(
          rig.lineMarks,
          findsOneWidget,
          reason:
              'C-605 D1: the line holds the SeatMark of the joined seat; '
              '${rig.scn.why}',
        );
        expect(
          tester.widget<SeatMark>(rig.lineMarks).seat,
          1,
          reason: 'C-605 D1: the mark is seat 1\'s; ${rig.scn.why}',
        );
        expect(
          tester.getCenter(rig.lineMarks).dx,
          lessThan(tester.getCenter(rig.lineTexts).dx),
          reason:
              'C-605 D1: the disc is at the line\'s start (left in en); '
              '${rig.scn.why}',
        );

        // The chips row is the first chip's row: its top is the chips' top.
        double chipsTop = double.infinity;
        for (final int seat in <int>[0, 1, 2]) {
          expect(
            find.byKey(_chipKey(seat)),
            findsOneWidget,
            reason:
                'fixture: a ready chip for seat $seat (the joined seat has '
                'one); ${rig.scn.why}',
          );
          final double top = tester.getRect(find.byKey(_chipKey(seat))).top;
          if (top < chipsTop) {
            chipsTop = top;
          }
        }
        final Rect lineRect = tester.getRect(rig.line);
        expect(
          lineRect.bottom,
          lessThanOrEqualTo(chipsTop + 0.5),
          reason:
              'C-605 D1: the line is above the ready chips row (line bottom '
              '${lineRect.bottom}, chips top $chipsTop); ${rig.scn.why}',
        );
        expect(
          chipsTop - lineRect.bottom,
          lessThan(48),
          reason:
              'C-605 D1: directly above the chips, not further up the card '
              '(line bottom ${lineRect.bottom}, chips top $chipsTop); '
              '${rig.scn.why}',
        );
      });
    });

    testWidgets('the line is there at 2400 ms and gone after 2500 ms plus a '
        'frame; the card and the chips stay', (WidgetTester tester) async {
      await _scenario(tester, 'a-line-lifetime', (_Rig rig) async {
        await rig.join(1, 'Karim');
        expect(
          rig.line,
          findsOneWidget,
          reason: 'C-605 D1: the line shows at the join; ${rig.scn.why}',
        );
        await rig.pump(2400);
        expect(
          rig.line,
          findsOneWidget,
          reason: 'C-605 D1: the line stays 2500 ms; ${rig.scn.why}',
        );
        await rig.pump(_holdMs - 2400);
        await rig.pump();
        expect(
          rig.line,
          findsNothing,
          reason:
              'C-605 D1: gone 2500 ms from its arrival plus one frame; '
              '${rig.scn.why}',
        );
        expect(
          find.byKey(_chipKey(1)),
          findsOneWidget,
          reason: 'the joined chip stays when the line goes; ${rig.scn.why}',
        );
        await rig.pump(5000);
        expect(
          rig.line,
          findsNothing,
          reason: 'the line does not come back; ${rig.scn.why}',
        );
      });
    });

    testWidgets('exactly one announcement "Karim joined" and exactly one '
        'friend_joined cue, with the ambient direction', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'a-announce-and-cue', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        final int cuesBefore = rig.feedback.joinCues;
        await rig.join(1, 'Karim');
        await rig.pump(50);
        expect(
          rig.saidAbout('Karim', from: saidBefore),
          equals(<String>['Karim joined']),
          reason:
              'C-605 D1: TalkBack hears "Karim joined" once per join; '
              'announced since the frame: ${rig.said.sublist(saidBefore)}; '
              '${rig.scn.why}',
        );
        expect(
          rig.dirs.last,
          TextDirection.ltr.index,
          reason: 'the ambient direction (ltr in en); ${rig.scn.why}',
        );
        expect(
          rig.feedback.joinCues - cuesBefore,
          1,
          reason:
              'C-605 D2: the friend_joined cue plays once for the frame; '
              'cues so far ${rig.feedback.played.map((c) => c.id).toList()}; '
              '${rig.scn.why}',
        );
        await rig.pump(3000);
        expect(
          rig.saidAbout('Karim', from: saidBefore),
          hasLength(1),
          reason:
              'C-605 D1: the line going away says nothing more; announced: '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        expect(
          rig.feedback.joinCues - cuesBefore,
          1,
          reason: 'the clock plays no further cue; ${rig.scn.why}',
        );
      });
    });

    testWidgets('the same join reaching the card in its ask branch (I am not '
        'the asker, three seats once Karim sits) shows the line too', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'a-ask-branch', rematchBy: 2, (_Rig rig) async {
        expect(
          find.byKey(const Key('end-card-rematch-ask')),
          findsOneWidget,
          reason: 'fixture: seat 2 asked, the ask line is up; ${rig.scn.why}',
        );
        final int saidBefore = rig.said.length;
        await rig.join(1, 'Karim');
        expect(
          rig.lineStrings,
          equals(<String>['Karim joined']),
          reason:
              'C-605 D1: the end card shows the line in its rematch lobby '
              'whichever branch it is in; got ${rig.lineStrings}; '
              '${rig.scn.why}',
        );
        expect(
          rig.saidAbout('Karim', from: saidBefore),
          equals(<String>['Karim joined']),
          reason: 'one announcement; ${rig.scn.why}',
        );
      });
    });
  });

  // --- b: Arabic --------------------------------------------------------------
  group('(b) Arabic', () {
    testWidgets('the line reads «انضمّ Karim» and the disc sits at the '
        'right-hand start', (WidgetTester tester) async {
      await _scenario(tester, 'b-ar-line', (_Rig rig) async {
        const String expected = 'انضمّ Karim';
        expect(
          rig.loc.lobbyFriendJoined('Karim'),
          expected,
          reason: 'fixture: the ar string is "انضمّ {name}"',
        );
        final int saidBefore = rig.said.length;
        await rig.join(1, 'Karim');
        await rig.pump(50);
        expect(
          rig.line,
          findsOneWidget,
          reason: 'C-605 D1: the line shows in ar; ${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>[expected]),
          reason:
              'C-605 D1: the line reads "$expected"; got '
              '${rig.lineStrings}; ${rig.scn.why}',
        );
        expect(
          rig.lineMarks,
          findsOneWidget,
          reason: 'one SeatMark in the line; ${rig.scn.why}',
        );
        expect(
          tester.widget<SeatMark>(rig.lineMarks).seat,
          1,
          reason: 'the mark is seat 1\'s; ${rig.scn.why}',
        );
        expect(
          tester.getCenter(rig.lineMarks).dx,
          greaterThan(tester.getCenter(rig.lineTexts).dx),
          reason:
              'C-605 D1: mirrored, the disc is to the right of the text '
              '(the start in rtl); ${rig.scn.why}',
        );
        expect(
          rig.saidAbout('Karim', from: saidBefore),
          equals(<String>[expected]),
          reason:
              'C-605 D1: one announcement "$expected"; announced: '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        expect(
          rig.dirs.last,
          TextDirection.rtl.index,
          reason: 'the ambient direction (rtl in ar); ${rig.scn.why}',
        );
        await rig.pump(2400);
        expect(rig.line, findsOneWidget, reason: rig.scn.why);
        await rig.pump(100);
        await rig.pump();
        expect(
          rig.line,
          findsNothing,
          reason: 'gone 2500 ms from its arrival in ar too; ${rig.scn.why}',
        );
      }, locale: const Locale('ar'));
    });
  });

  // --- c: two joins -----------------------------------------------------------
  group('(c) two joins 1 s apart', () {
    testWidgets('the second replaces the first and restarts the 2.5 s; two '
        'announcements in order; two cues', (WidgetTester tester) async {
      await _scenario(tester, 'c-two-joins', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        final int cuesBefore = rig.feedback.joinCues;
        await rig.join(1, 'Karim');
        expect(
          rig.lineStrings,
          equals(<String>['Karim joined']),
          reason:
              'C-605 D1: the first join names Karim; got ${rig.lineStrings}; '
              '${rig.scn.why}',
        );
        await rig.pump(1000);
        await rig.join(3, 'Omar');
        expect(
          rig.line,
          findsOneWidget,
          reason: 'one line, not two stacked; ${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>['Omar joined']),
          reason:
              'C-605 D1: a second join replaces the line; got '
              '${rig.lineStrings}; ${rig.scn.why}',
        );
        expect(
          tester.widget<SeatMark>(rig.lineMarks).seat,
          3,
          reason: 'the disc follows the newer seat; ${rig.scn.why}',
        );
        expect(
          rig.feedback.joinCues - cuesBefore,
          2,
          reason:
              'C-605 D2: two frames, two cues; cues so far '
              '${rig.feedback.played.map((c) => c.id).toList()}; '
              '${rig.scn.why}',
        );
        // 3400 ms after Karim's join, 2400 after Omar's.
        await rig.pump(2400);
        expect(
          rig.lineStrings,
          equals(<String>['Omar joined']),
          reason:
              'C-605 D1: the 2.5 s restarts at the second join (still shown '
              '2400 ms after it, 3400 ms after the first); got '
              '${rig.lineStrings}; ${rig.scn.why}',
        );
        await rig.pump(100);
        await rig.pump();
        expect(
          rig.line,
          findsNothing,
          reason: 'gone 2500 ms after the second join; ${rig.scn.why}',
        );
        expect(
          rig.saidAbout(' joined', from: saidBefore),
          equals(<String>['Karim joined', 'Omar joined']),
          reason:
              'C-605 D1: one announcement per join, in arrival order; got '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        expect(
          rig.feedback.joinCues - cuesBefore,
          2,
          reason: 'the clock plays no further cue; ${rig.scn.why}',
        );
      });
    });

    testWidgets('two joins in the same instant: two announcements in order, '
        'two cues, the line names the newer', (WidgetTester tester) async {
      await _scenario(tester, 'c-same-instant', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        final int cuesBefore = rig.feedback.joinCues;
        rig.seq += 1;
        rig.transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 1, 'name': 'Karim', 'seq': rig.seq},
          ),
        );
        rig.seq += 1;
        rig.transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 3, 'name': 'Omar', 'seq': rig.seq},
          ),
        );
        rig.scn.log('pushed seats 1 and 3 before any pump');
        await tester.pump();
        await tester.pump();
        expect(
          rig.feedback.joinCues - cuesBefore,
          2,
          reason:
              'C-605 D2: two frames in one instant are two cues; '
              '${rig.scn.why}',
        );
        expect(
          rig.saidAbout(' joined', from: saidBefore),
          equals(<String>['Karim joined', 'Omar joined']),
          reason:
              'C-605 D1: both heard, in arrival order; got '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>['Omar joined']),
          reason: 'the newer name wins the line; ${rig.scn.why}',
        );
      });
    });
  });

  // --- d: my own seat (green on a tree without the work) -----------------------
  group('(d) a frame naming my own seat', () {
    testWidgets('no line, no announcement, no cue', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'd-own-seat', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        final int cuesBefore = rig.feedback.played.length;
        await rig.join(0, 'Sam');
        await rig.pump(100);
        expect(
          rig.line,
          findsNothing,
          reason:
              'C-605 D1: a join of my own seat is not a friend sitting '
              'down; ${rig.scn.why}',
        );
        expect(
          rig.said.sublist(saidBefore),
          isEmpty,
          reason:
              'no announcement for my own seat; announced: '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        expect(
          rig.feedback.played.sublist(cuesBefore),
          isEmpty,
          reason:
              'no cue for my own seat; played: '
              '${rig.feedback.played.sublist(cuesBefore).map((c) => c.id)}; '
              '${rig.scn.why}',
        );
        await rig.pump(3000);
        expect(rig.line, findsNothing, reason: rig.scn.why);
      });
    });

    testWidgets('a seat that is a string, missing or null: no line, no '
        'announcement, no cue, no exception', (WidgetTester tester) async {
      await _scenario(tester, 'd-malformed-seat', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        final int cuesBefore = rig.feedback.played.length;
        await rig.joinRaw(<String, Object?>{'seat': '1', 'name': 'Karim'});
        await rig.joinRaw(<String, Object?>{'name': 'Karim'});
        await rig.joinRaw(<String, Object?>{'seat': null, 'name': 'Karim'});
        await rig.pump(100);
        expect(tester.takeException(), isNull, reason: rig.scn.why);
        expect(
          rig.line,
          findsNothing,
          reason: 'a mistyped seat is no friend; ${rig.scn.why}',
        );
        expect(
          rig.saidAbout('Karim', from: saidBefore),
          isEmpty,
          reason: 'nothing announced; ${rig.scn.why}',
        );
        expect(
          rig.feedback.played.sublist(cuesBefore),
          isEmpty,
          reason: 'nothing played; ${rig.scn.why}',
        );
      });
    });

    testWidgets('player_left and presence at the rematch lobby show no line '
        'and say nothing about a join', (WidgetTester tester) async {
      await _scenario(tester, 'd-left-and-presence', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        await rig.push('presence', <String, Object?>{
          'seat': 2,
          'connected': false,
        });
        await rig.push('player_left', <String, Object?>{
          'seat': 2,
          'host_seat': 0,
        });
        await rig.pump(100);
        expect(rig.line, findsNothing, reason: rig.scn.why);
        expect(
          rig.saidAbout(' joined', from: saidBefore),
          isEmpty,
          reason: 'no join is spoken for a departure; ${rig.scn.why}',
        );
        expect(
          rig.feedback.joinCues,
          0,
          reason: 'no join cue for a departure; ${rig.scn.why}',
        );
      });
    });
  });

  // --- e: the chip entrance ---------------------------------------------------
  group('(e) the ready chip enters inside a SeatEntrance', () {
    testWidgets('the joined chip is entering and scales in; chips present at '
        'the first build are not and stay at rest', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'e-chip-entrance', (_Rig rig) async {
        for (final int seat in <int>[0, 2]) {
          for (final SeatEntrance e in _entrancesAbove(
            tester,
            find.byKey(_chipKey(seat)),
          )) {
            expect(
              e.entering,
              isFalse,
              reason:
                  'C-605 D1: the chip of seat $seat was there at the first '
                  'build and does not animate; ${rig.scn.why}',
            );
          }
        }
        await rig.join(1, 'Karim');
        final Finder chip = find.byKey(_chipKey(1));
        expect(
          chip,
          findsOneWidget,
          reason: 'fixture: the joined seat\'s chip exists; ${rig.scn.why}',
        );
        final List<SeatEntrance> above = _entrancesAbove(tester, chip);
        expect(
          above,
          hasLength(1),
          reason:
              'C-605 D1: the joined seat\'s chip is inside one SeatEntrance '
              '(the C-599 widget); found ${above.length}; ${rig.scn.why}',
        );
        expect(
          above.single.entering,
          isTrue,
          reason:
              'C-605 D1: the joined chip\'s entrance is running (entering); '
              '${rig.scn.why}',
        );
        expect(
          above.single.seat,
          1,
          reason:
              'the entrance carries the joined seat\'s colour; '
              '${rig.scn.why}',
        );
        final double first = _entranceScale(tester, chip);
        expect(
          first,
          allOf(greaterThanOrEqualTo(0.899), lessThan(0.999)),
          reason:
              'the first frame of the new chip is below 1.0 (starts at 0.9); '
              'got $first; ${rig.scn.why}',
        );
        for (final int seat in <int>[0, 2]) {
          for (final SeatEntrance e in _entrancesAbove(
            tester,
            find.byKey(_chipKey(seat)),
          )) {
            expect(
              e.entering,
              isFalse,
              reason:
                  'C-605 D1: a join does not start the entrance of the chip '
                  'of seat $seat; ${rig.scn.why}',
            );
          }
          expect(
            _entranceScale(tester, find.byKey(_chipKey(seat))),
            closeTo(1.0, 0.001),
            reason: 'the chip of seat $seat stays at rest; ${rig.scn.why}',
          );
        }
        await rig.pump(400);
        expect(
          _entranceScale(tester, chip),
          closeTo(1.0, 0.001),
          reason: 'the joined chip is at rest by 400 ms; ${rig.scn.why}',
        );
      });
    });

    testWidgets('chips present when the card first builds do not animate '
        'even when the card first builds already in the rematch lobby', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'e-first-build-chips', (_Rig rig) async {
        await rig.pump(16);
        for (final int seat in <int>[0, 2]) {
          expect(
            _entranceScale(tester, find.byKey(_chipKey(seat))),
            closeTo(1.0, 0.001),
            reason:
                'C-605 D1: the chip of seat $seat is at rest in the first '
                'frames of the card; ${rig.scn.why}',
          );
        }
      });
    });
  });

  // --- f: reduced motion ------------------------------------------------------
  group('(f) reduced motion', () {
    testWidgets('the line appears and leaves at the same times with no fade', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'f-reduced-motion', reduceMotion: true, (
        _Rig rig,
      ) async {
        final int cuesBefore = rig.feedback.joinCues;
        await rig.join(1, 'Karim');
        expect(
          rig.line,
          findsOneWidget,
          reason:
              'C-605 D1: the line appears at once under reduced motion; '
              '${rig.scn.why}',
        );
        expect(
          _opacityAbove(tester, rig.line),
          closeTo(1.0, 0.0001),
          reason:
              'C-605 D1: no fade in the first frame (opacity above the line '
              'is ${_opacityAbove(tester, rig.line)}); ${rig.scn.why}',
        );
        await rig.pump(16);
        expect(
          _opacityAbove(tester, rig.line),
          closeTo(1.0, 0.0001),
          reason: 'no fade 16 ms in; ${rig.scn.why}',
        );
        await rig.pump(2384);
        expect(
          rig.line,
          findsOneWidget,
          reason: 'still shown at 2400 ms; ${rig.scn.why}',
        );
        expect(
          _opacityAbove(tester, rig.line),
          closeTo(1.0, 0.0001),
          reason: 'no fade out before it leaves; ${rig.scn.why}',
        );
        await rig.pump(_holdMs - 2400);
        await rig.pump();
        expect(
          rig.line,
          findsNothing,
          reason:
              'C-605 D1: gone 2500 ms from its arrival plus a frame under '
              'reduced motion too; ${rig.scn.why}',
        );
        expect(
          rig.feedback.joinCues - cuesBefore,
          1,
          reason:
              'reduced motion shortens the sight, the cue stays; '
              '${rig.scn.why}',
        );
      });
    });
  });

  // --- D2: outside the end card -----------------------------------------------
  group('(D2) a join in a game in progress', () {
    testWidgets('the cue plays once as today; nothing new is shown or '
        'spoken', (WidgetTester tester) async {
      await _scenario(tester, 'h-in-progress', finish: false, (_Rig rig) async {
        expect(
          rig.controller.room?.state,
          RoomState.playing,
          reason: 'fixture: the game is in progress; ${rig.scn.why}',
        );
        final int saidBefore = rig.said.length;
        final int cuesBefore = rig.feedback.joinCues;
        await rig.join(1, 'Karim');
        await rig.pump(100);
        expect(
          rig.feedback.joinCues - cuesBefore,
          1,
          reason:
              'C-605 D2: the cue behaviour is unchanged, one friend_joined '
              'for the frame; ${rig.scn.why}',
        );
        expect(
          rig.line,
          findsNothing,
          reason:
              'C-605 D2: outside the end card nothing new is shown; '
              '${rig.scn.why}',
        );
        expect(
          rig.saidAbout('Karim joined', from: saidBefore),
          isEmpty,
          reason:
              'C-605 D2: nothing new is spoken; announced: '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        await rig.pump(3000);
        expect(rig.line, findsNothing, reason: rig.scn.why);
      });
    });
  });

  // --- ugly neighbours of D1 ---------------------------------------------------
  group('(D1) the edges of the line', () {
    testWidgets('a 40-character name at text scale 2 on a 320 dp card: no '
        'overflow, the line stays inside the card', (
      WidgetTester tester,
    ) async {
      const String longName = 'Karimxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      expect(longName.length, 41, reason: 'fixture: a very long name');
      await _scenario(
        tester,
        'j-long-name',
        (_Rig rig) async {
          await rig.join(1, longName);
          expect(
            rig.line,
            findsOneWidget,
            reason: 'C-605 D1: the line shows; ${rig.scn.why}',
          );
          final Rect rect = tester.getRect(rig.line);
          expect(
            rect.left,
            greaterThanOrEqualTo(0),
            reason: 'the line starts inside the screen: $rect; ${rig.scn.why}',
          );
          expect(
            rect.right,
            lessThanOrEqualTo(320.5),
            reason:
                'C-605 D1: the text is clamped like the ask line, the line '
                'stays within the 320 dp screen: $rect; ${rig.scn.why}',
          );
          await rig.pump(100);
          expect(
            tester.takeException(),
            isNull,
            reason: 'no layout overflow with a long name; ${rig.scn.why}',
          );
        },
        width: 320,
        textScale: 2.0,
      );
    });

    testWidgets('leaving the screen mid-line leaves no late announcement, '
        'no cue and no exception', (WidgetTester tester) async {
      await _scenario(tester, 'k-unmount-mid-line', (_Rig rig) async {
        final int saidBefore = rig.said.length;
        await rig.join(1, 'Karim');
        await rig.pump(1000);
        expect(rig.line, findsOneWidget, reason: rig.scn.why);
        final int cues = rig.feedback.played.length;
        await tester.pumpWidget(const SizedBox.shrink());
        rig.scn.log('unmounted the screen');
        await rig.pump(5000);
        expect(tester.takeException(), isNull, reason: rig.scn.why);
        expect(
          rig.saidAbout('Karim joined', from: saidBefore),
          hasLength(1),
          reason:
              'nothing is announced after the screen is gone; announced: '
              '${rig.said.sublist(saidBefore)}; ${rig.scn.why}',
        );
        expect(
          rig.feedback.played.length,
          cues,
          reason: 'nothing is played after the screen is gone; ${rig.scn.why}',
        );
      });
    });
  });

  // --- g: the Arabic spoken roll line -------------------------------------------
  group('(g) the Arabic spoken roll history line', () {
    // Seat 0 is me, seat 2 is Karim. The last three rolls are shown.
    const List<_Roll> rolls = <_Roll>[
      (0, 11, 1),
      (2, 12, 3),
      (0, 13, 6),
      (2, 14, 4),
    ];

    String spokenOf(WidgetTester tester, AppLocalizations loc, _Roll roll) {
      final Finder entry = find.descendant(
        of: find.byKey(_historyKey),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Text &&
              _textOf(w) == loc.gameRollHistoryEntry(roll.$2, roll.$3),
        ),
      );
      expect(
        entry,
        findsOneWidget,
        reason:
            'fixture: the history row for roll k=${roll.$2} face=${roll.$3} '
            'is drawn',
      );
      return tester.getSemantics(entry).label;
    }

    testWidgets('my roll reads «الرمية 13 (أنت): 6», Karim\'s «الرمية 12 '
        '(Karim): 3», and no line contains «لـ»', (WidgetTester tester) async {
      await _scenario(
        tester,
        'g-ar-spoken',
        rematchBy: null,
        locale: const Locale('ar'),
        seat2Name: 'Karim',
        rolls: rolls,
        (_Rig rig) async {
          final AppLocalizations loc = rig.loc;
          expect(loc.localeName, 'ar', reason: 'fixture: the harness is ar');
          expect(
            find.byKey(_historyKey),
            findsOneWidget,
            reason:
                'fixture: the finished board lists the last rolls; '
                '${rig.scn.why}',
          );
          final String mine = spokenOf(tester, loc, rolls[2]);
          final String theirs = spokenOf(tester, loc, rolls[1]);
          final String theirsLast = spokenOf(tester, loc, rolls[3]);
          expect(
            mine,
            'الرمية ${rolls[2].$2} (أنت): ${rolls[2].$3}',
            reason:
                'C-605 D3: my own roll (k ${rolls[2].$2}, face '
                '${rolls[2].$3}) is spoken «الرمية 13 (أنت): 6»; got "$mine"; '
                '${rig.scn.why}',
          );
          expect(
            theirs,
            'الرمية ${rolls[1].$2} (Karim): ${rolls[1].$3}',
            reason:
                'C-605 D3: Karim\'s roll (k ${rolls[1].$2}, face '
                '${rolls[1].$3}) is spoken «الرمية 12 (Karim): 3»; got '
                '"$theirs"; ${rig.scn.why}',
          );
          expect(
            theirsLast,
            'الرمية ${rolls[3].$2} (Karim): ${rolls[3].$3}',
            reason:
                'C-605 D3: Karim\'s last roll is spoken «الرمية 14 (Karim): '
                '4»; got "$theirsLast"; ${rig.scn.why}',
          );
          for (final String spoken in <String>[mine, theirs, theirsLast]) {
            expect(
              spoken.contains('لـ'),
              isFalse,
              reason:
                  'C-605 D3: the lam prefix glued to a name is gone; got '
                  '"$spoken"; ${rig.scn.why}',
            );
          }
        },
      );
    });

    testWidgets('the English line is unchanged (D3, D4)', (
      WidgetTester tester,
    ) async {
      await _scenario(
        tester,
        'g-en-unchanged',
        rematchBy: null,
        seat2Name: 'Karim',
        rolls: rolls,
        (_Rig rig) async {
          expect(
            spokenOf(tester, rig.loc, rolls[2]),
            'Roll 13: You rolled 6',
            reason: 'D3: the English string is unchanged; ${rig.scn.why}',
          );
          expect(
            spokenOf(tester, rig.loc, rolls[1]),
            'Roll 12: Karim rolled 3',
            reason: 'D3: the English string is unchanged; ${rig.scn.why}',
          );
        },
      );
    });
  });
}
