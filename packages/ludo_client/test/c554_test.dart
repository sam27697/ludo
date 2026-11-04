// Conformance tests for work/ludo/orders/C-554-time-up-and-a-new-table-
// arrives.md (D1-D5), written from that spec alone. Orders 554 and 555
// implement in parallel in trees this file's author has not read, so on a
// tree without them the cases that pin new behaviour are expected RED and the
// guards (what must not change) GREEN.
//
// Nothing here names a symbol the spec adds: `fromLobby`, `TableEntrance` and
// the three new `loc` getters do not exist on the base. Everything is asserted
// through Keys, visible text, semantics labels, captured announcements and
// the render tree, so the file compiles on the base and goes red on its own
// assertions. The three new strings are matched by their literal text from
// D5. RoomController and GameScreen are driven the way the sibling suites
// drive them: a real controller over a FakeTransport, real frames, and
// RoomRoute where the spec says RoomRoute is what mounts the screen.
//
// The hourglass and the entrance layer are measured, not looked up:
//   - rotation is the angle of the icon's accumulated paint transform, so it
//     does not matter whether the turn comes from RotationTransition,
//     Transform.rotate or an animated wrapper;
//   - the entrance layer's opacity is read from a screenshot of the app
//     (the pixel over the die against the theme's scaffold colour), because
//     the layer is painted in that very colour and a widget-level opacity
//     probe would depend on how it is built.
//
// Timers: nothing here uses pumpAndSettle while the hourglass turns. Every
// wait is a fixed pump. Whether a ticker survives a turn that is gone is read
// from the scheduler's transient callback count against a control run, and
// whether one survives dispose is left to flutter_test's own checks.
//
// Reproduce a failure by name: every reason line carries the scenario (seat,
// deadline_ms, locale, sequence of frames) it ran.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/room_route.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:path/path.dart' as p;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c554-test.invalid/ws';

const Key _timeUpKey = Key('game-screen-turn-timeup');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _countdownSemanticsKey = Key('game-header-countdown-semantics');
const Key _ringKey = Key('game-header-countdown-ring');
const Key _entranceKey = Key('game-table-entrance');
const Key _dieKey = Key('game-die');
const Key _boardKey = Key('game-screen-board');
// Drawn by the playing body only, never by an end card.
const Key _playingChipKey = Key('game-header-chip');
const Key _rematchKey = Key('end-card-rematch');
const Key _offlineKey = Key('end-card-offline');
const Key _shotKey = Key('c554-shot');

const String _startedEn = 'The game has started';
const String _startedAr = 'بدأت اللعبة';
const String _hostNowEn = 'You are the host now';
const String _hostNowAr = 'أصبحت المضيف الآن';
const String _timeUpEn = 'Time is up';
const String _timeUpAr = 'انتهى الوقت';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

String _startedFor(Locale l) =>
    l.languageCode == 'ar' ? _startedAr : _startedEn;
String _hostNowFor(Locale l) =>
    l.languageCode == 'ar' ? _hostNowAr : _hostNowEn;
String _timeUpFor(Locale l) => l.languageCode == 'ar' ? _timeUpAr : _timeUpEn;
String _sepFor(Locale l) => l.languageCode == 'ar' ? '، ' : ', ';

// --- frames and room snapshots, the sibling suites' idiom ---------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c554-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
};

Map<String, Object?> _roomJson({
  String code = 'C554XX',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  Map<String, Object?>? rematch,
  int chainIndex = 0,
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
  'chain_commit': (chainIndex.isEven ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': gameId == null ? null : '0:seed',
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'verify_url': state == 'FINISHED' ? 'https://c554-test.invalid/verify' : null,
  'rematch': rematch,
  'seq': seq,
};

List<Map<String, Object?>> _seatsOf(List<String> names) =>
    <Map<String, Object?>>[
      for (int i = 0; i < names.length; i++) _seatJson(i, name: names[i]),
    ];

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

/// A controller over a fake transport, landed on [roomData] by a createRoom
/// (or, with [resume], a resumeRoom) reply. mySeat is [mySeat].
Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester, {
  required int mySeat,
  required Map<String, Object?> roomData,
  bool resume = false,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final Future<void> future = resume
      ? controller.resumeRoom(
          code: roomData['code']! as String,
          seat: mySeat,
          seatToken: 'tok-$mySeat',
        )
      : controller.createRoom(
          name: 'p$mySeat',
          players: roomData['players']! as int,
        );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: roomData));
  await future;
  addTearDown(controller.dispose);
  _transports[controller] = transport;
  return (controller, transport);
}

/// Which transport each controller built by [_connect] sits on, so
/// [_mountGame] can answer the request a finished screen opens on mount.
final Map<RoomController, FakeTransport> _transports =
    <RoomController, FakeTransport>{};

Widget _harness(
  Widget child, {
  Locale locale = _en,
  bool disableAnimations = false,
}) {
  return RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(
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
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: screen!,
        );
      },
      home: child,
    ),
  );
}

Future<void> _mountGame(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = _en,
  bool disableAnimations = false,
  FeedbackService service = const NoopFeedbackService(),
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: service,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  final FakeTransport? transport = _transports[controller];
  if (transport != null) {
    await _refuseGameLogs(tester, transport);
  }
}

/// The game-log requests already answered, per transport.
final Expando<Set<String>> _refusedLogs = Expando<Set<String>>('refusedLogs');

/// A finished screen with no transcript asks the server for the game log, on
/// its first frame or when a game ends under it. Refuse every request not yet
/// answered, so the request's 10 s timer is not left running and the case
/// measures only what it was written to measure.
Future<void> _refuseGameLogs(
  WidgetTester tester,
  FakeTransport transport,
) async {
  final Set<String> done = _refusedLogs[transport] ??= <String>{};
  bool answered = false;
  for (final String raw in transport.sentRaw.toList()) {
    if (_typeOf(raw) == 'game_log' && done.add(_idOf(raw))) {
      answered = true;
      transport.pushText(
        _frame(
          type: 'error',
          re: _idOf(raw),
          data: <String, Object?>{
            'code': 'GAME_LOG_UNAVAILABLE',
            'message': 'not in this test',
          },
        ),
      );
    }
  }
  if (answered) {
    await tester.pump();
    await tester.pump();
  }
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// Fixture check for the departure cases: the card itself must be showing
/// [expected] on its left line, so that what is asserted next is an
/// announcement of something the card says.
void _expectCardLeftLine(
  WidgetTester tester,
  String expected,
  String scenario,
) {
  final Finder line = find.byKey(const Key('end-card-left'));
  expect(
    line,
    findsOneWidget,
    reason:
        'fixture: the end card must show end-card-left. Scenario: $scenario',
  );
  expect(
    tester.widget<Text>(line).data,
    expected,
    reason:
        'fixture: the end card left line must read "$expected". '
        'Scenario: $scenario',
  );
}

class _RecordingFeedback implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) => recorded.add(cue);
}

/// Collects every `announce` event off SystemChannels.accessibility, the way
/// test/talkback_announce_test.dart does.
class _Announcements {
  final List<String> messages = <String>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          messages.add(data['message'] as String);
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
  }

  int count(String text) => messages.where((String m) => m == text).length;
}

Future<void> _push(
  WidgetTester tester,
  FakeTransport transport,
  String type,
  Map<String, Object?> data, {
  String? re,
}) async {
  transport.pushText(_frame(type: type, re: re, data: data));
  await tester.pump();
  await tester.pump();
}

// --- D1 probes ----------------------------------------------------------------

/// The accumulated rotation of the hourglass, in radians, read from its
/// paint transform to the root.
double _hourglassAngle(WidgetTester tester, String scenario) {
  final Finder icon = find.descendant(
    of: find.byKey(_timeUpKey),
    matching: find.byIcon(Icons.hourglass_bottom_rounded),
    matchRoot: true,
  );
  expect(
    icon,
    findsOneWidget,
    reason:
        'D1: game-screen-turn-timeup must hold Icons.hourglass_bottom_rounded; '
        'found ${icon.evaluate().length}. Scenario: $scenario',
  );
  final Matrix4 m = tester.renderObject<RenderBox>(icon).getTransformTo(null);
  return math.atan2(m.entry(1, 0), m.entry(0, 0));
}

double _wrap(double value, double period) {
  double r = value % period;
  if (r < 0) {
    r += period;
  }
  return r;
}

/// Distance between two angles on a circle of [period].
double _angleGap(double a, double b, double period) {
  final double d = _wrap(a - b, period);
  return math.min(d, period - d);
}

String? _countdownLabel(WidgetTester tester) {
  final Finder f = find.byKey(_countdownSemanticsKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  return (tester.widget(f) as Semantics).properties.label;
}

String? _digitsText(WidgetTester tester) {
  final Finder f = find.byKey(_countdownKey);
  if (f.evaluate().isEmpty) {
    return null;
  }
  final Widget w = tester.widget(f);
  if (w is Text) {
    return w.data;
  }
  return tester
      .widget<Text>(find.descendant(of: f, matching: find.byType(Text)).first)
      .data;
}

Future<(RoomController, FakeTransport)> _connectTurn(
  WidgetTester tester, {
  required int deadlineMs,
  bool resume = false,
  int mySeat = 0,
}) {
  return _connect(
    tester,
    mySeat: mySeat,
    resume: resume,
    roomData: _roomJson(
      seats: _seatsOf(<String>['Sam', 'Bob']),
      turn: _turnJson(
        seat: 0,
        phase: 'await_roll',
        deadlineMs: deadlineMs,
        k: 0,
      ),
      gameId: 'g1',
      seq: 1,
    ),
  );
}

/// Pumps whole seconds until the digits are gone or [seconds] have passed.
Future<void> _runDownToZero(WidgetTester tester, int seconds) async {
  for (int i = 0; i < seconds; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump(const Duration(milliseconds: 50));
}

// --- D2/D3 probes -------------------------------------------------------------

Future<ui.Image> _shoot(WidgetTester tester) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_shotKey),
  );
  final ui.Image? image = await tester.runAsync(() => boundary.toImage());
  return image!;
}

Future<Color> _pixelAt(WidgetTester tester, Offset logical) async {
  final ui.Image image = await _shoot(tester);
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final int x = logical.dx.round().clamp(0, image.width - 1);
  final int y = logical.dy.round().clamp(0, image.height - 1);
  final int at = (y * image.width + x) * 4;
  final ByteData bytes = data!;
  return Color.fromARGB(
    bytes.getUint8(at + 3),
    bytes.getUint8(at),
    bytes.getUint8(at + 1),
    bytes.getUint8(at + 2),
  );
}

bool _sameRgb(Color a, Color b) =>
    (a.r * 255).round() == (b.r * 255).round() &&
    (a.g * 255).round() == (b.g * 255).round() &&
    (a.b * 255).round() == (b.b * 255).round();

/// RoomRoute over a 2-seat create lobby that has been answered, seat 0 host.
Future<(RoomController, FakeTransport)> _mountRoomRouteInLobby(
  WidgetTester tester, {
  Locale locale = _en,
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: const NoopFeedbackService(),
        child: RoomRoute(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 2,
        ),
      ),
      locale: locale,
      disableAnimations: disableAnimations,
    ),
  );
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
      data: _roomJson(
        state: 'LOBBY',
        seats: _seatsOf(<String>['Sam', 'Bob']),
        seq: 1,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  addTearDown(controller.dispose);
  expect(
    find.byType(LobbyScreen),
    findsOneWidget,
    reason: 'fixture: the answered create must leave RoomRoute on the lobby',
  );
  return (controller, transport);
}

/// Pushes game_started and pumps zero-length frames until GameScreen is in the
/// tree, so what is checked next is the first frame that shows it.
Future<void> _startGameFromLobby(
  WidgetTester tester,
  FakeTransport transport,
) async {
  transport.pushText(
    _frame(
      type: 'game_started',
      data: <String, Object?>{
        'turn': 0,
        'game_id': 'g1',
        'client_seeds': '0:seed',
        'seq': 2,
      },
    ),
  );
  for (int i = 0; i < 3 && find.byType(GameScreen).evaluate().isEmpty; i++) {
    await tester.pump();
  }
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: 'fixture: game_started must swap RoomRoute onto GameScreen',
  );
}

/// Pushes the rematch game's `game_started` and pumps zero-length frames until
/// the playing body is in the tree (only it draws [_playingChipKey]), the way
/// [_push] delivers a frame: one pump has not yet carried the frame to the
/// screen. What is read next is the first frame of the new board.
Future<void> _startRematchGame(
  WidgetTester tester,
  FakeTransport transport, {
  required String gameId,
  required int seq,
}) async {
  expect(
    find.byKey(_playingChipKey),
    findsNothing,
    reason: 'fixture: the end card draws no playing header before the start',
  );
  transport.pushText(
    _frame(
      type: 'game_started',
      data: <String, Object?>{
        'turn': 0,
        'game_id': gameId,
        'client_seeds': '0:seed',
        'seq': seq,
      },
    ),
  );
  for (
    int i = 0;
    i < 4 && find.byKey(_playingChipKey).evaluate().isEmpty;
    i++
  ) {
    await tester.pump();
  }
  expect(
    find.byKey(_playingChipKey),
    findsOneWidget,
    reason: 'fixture: game_started must put the playing header on screen',
  );
}

/// Taps the die and answers the roll it sends, so no request stays open.
/// Returns how many `roll` requests the tap produced.
Future<int> _tapDieAndAnswer(
  WidgetTester tester,
  FakeTransport transport, {
  required int seq,
}) async {
  await tester.tap(find.byKey(_dieKey));
  await tester.pump();
  final List<String> rolls = transport.sentRaw
      .where((String raw) => _typeOf(raw) == 'roll')
      .toList();
  if (rolls.isNotEmpty) {
    transport.pushText(
      _frame(
        type: 'rolled',
        re: _idOf(rolls.last),
        data: <String, Object?>{
          'seat': 0,
          'value': 6,
          'legal': const <int>[0, 1],
          'deadline_ms': 45000,
          'k': 1,
          'reveal': 'f' * 64,
          'seq': seq,
        },
      ),
    );
  }
  await tester.pump();
  return rolls.length;
}

/// A FINISHED table on GameScreen (game g1) mounted straight onto its end
/// card, mySeat [mySeat]. Reached the way a phone reaches it: a resume into a
/// FINISHED room. A create or join reply never records the finished snapshot
/// (`RoomController.lastFinished`), and without it the card has no baseline to
/// measure departures against, which no real table is in.
Future<(RoomController, FakeTransport)> _connectFinished(
  WidgetTester tester, {
  required int mySeat,
  required List<String> names,
  int hostSeat = 0,
  Map<String, Object?>? rematch,
}) {
  return _connect(
    tester,
    mySeat: mySeat,
    resume: true,
    roomData: _roomJson(
      state: 'FINISHED',
      hostSeat: hostSeat,
      players: names.length,
      seats: _seatsOf(names),
      turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 8),
      winner: 0,
      gameId: 'g1',
      rematch: rematch,
      chainIndex: rematch == null ? 0 : 1,
      seq: 1,
    ),
  );
}

void main() {
  // ===========================================================================
  // D1: the clock that ran out says so.
  // ===========================================================================
  group('C-554 D1: time up', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;

      testWidgets(
        '$lang: the countdown reaching zero swaps the digits for the hourglass '
        'and the label for "${_timeUpFor(locale)}"',
        (WidgetTester tester) async {
          final String scenario =
              'createRoom seat 0, turn seat 0 await_roll, deadline_ms 3000, '
              'locale $lang, three one-second pumps';
          final (RoomController controller, _) = await _connectTurn(
            tester,
            deadlineMs: 3000,
          );
          await _mountGame(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);

          expect(_digitsText(tester), '3', reason: 'fixture ($scenario)');
          expect(
            find.byKey(_timeUpKey),
            findsNothing,
            reason: 'above zero ($scenario)',
          );

          await _runDownToZero(tester, 3);

          expect(
            find.byKey(_timeUpKey),
            findsOneWidget,
            reason:
                'D1: at zero game-screen-turn-timeup must be on screen; '
                'digits showed "${_digitsText(tester)}". Scenario: $scenario',
          );
          expect(
            find.byKey(_countdownKey),
            findsNothing,
            reason:
                'D1: at zero the digits Text game-screen-turn-countdown must '
                'be gone. Scenario: $scenario',
          );
          expect(
            _countdownLabel(tester),
            _timeUpFor(locale),
            reason:
                'D1: the game-header-countdown-semantics label at zero must be '
                'gameTurnTimeUp "${_timeUpFor(locale)}", not '
                '"${loc.gameTurnCountdown(0)}". Scenario: $scenario',
          );
        },
      );

      testWidgets(
        '$lang: a resume into a turn with deadline_ms 0 shows the hourglass '
        'on its first frames',
        (WidgetTester tester) async {
          final String scenario =
              'resumeRoom seat 0, turn seat 0 await_roll, deadline_ms 0, '
              'locale $lang';
          final (RoomController controller, _) = await _connectTurn(
            tester,
            deadlineMs: 0,
            resume: true,
          );
          await _mountGame(tester, controller, locale: locale);
          await tester.pump(const Duration(milliseconds: 50));

          expect(
            find.byKey(_timeUpKey),
            findsOneWidget,
            reason:
                'D1: an overdue resumed turn must show the hourglass. $scenario',
          );
          expect(
            find.byKey(_countdownKey),
            findsNothing,
            reason: 'D1: no digits on an overdue resumed turn. $scenario',
          );
          expect(
            _countdownLabel(tester),
            _timeUpFor(locale),
            reason:
                'D1: label on an overdue resumed turn must be '
                '"${_timeUpFor(locale)}". $scenario',
          );
        },
      );
    }

    testWidgets('the hourglass sits inside the ring, in the ring colour', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'resumeRoom seat 0, deadline_ms 0, locale en, 390x844';
      final (RoomController controller, _) = await _connectTurn(
        tester,
        deadlineMs: 0,
        resume: true,
      );
      await _mountGame(tester, controller);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byKey(_timeUpKey), findsOneWidget, reason: 'D1 ($scenario)');
      final Rect ring = tester.getRect(find.byKey(_ringKey));
      final Rect mark = tester.getRect(find.byKey(_timeUpKey));
      expect(
        ring.inflate(0.5).contains(mark.topLeft) &&
            ring.inflate(0.5).contains(mark.bottomRight),
        isTrue,
        reason:
            'D1: the hourglass rect $mark must lie inside the ring rect '
            '$ring. Scenario: $scenario',
      );
      final Finder glyph = find.descendant(
        of: find.byKey(_timeUpKey),
        matching: find.byType(RichText),
        matchRoot: true,
      );
      final Color? colour = tester
          .widget<RichText>(glyph.first)
          .text
          .style
          ?.color;
      expect(
        colour != null && _sameRgb(colour, LudoColors.error),
        isTrue,
        reason:
            'D1: the hourglass must be drawn in LudoColors.error '
            '(${LudoColors.error}); it is $colour. Scenario: $scenario',
      );
    });

    testWidgets(
      'the hourglass turns: a half turn every 600 ms, different 100 ms apart',
      (WidgetTester tester) async {
        const String scenario =
            'resumeRoom seat 0, deadline_ms 0, motion on, samples at +50, '
            '+150, +450, +750 ms';
        final (RoomController controller, _) = await _connectTurn(
          tester,
          deadlineMs: 0,
          resume: true,
        );
        await _mountGame(tester, controller);
        await tester.pump(const Duration(milliseconds: 50));
        final double a = _hourglassAngle(tester, scenario);
        await tester.pump(const Duration(milliseconds: 100));
        final double b = _hourglassAngle(tester, scenario);
        expect(
          _angleGap(a, b, 2 * math.pi),
          greaterThan(0.01),
          reason:
              'D1: the hourglass must have turned between two pumps 100 ms '
              'apart; angle was $a then $b. Scenario: $scenario',
        );
        // A half turn is 600 ms: the hourglass looks the same every 600 ms.
        await tester.pump(const Duration(milliseconds: 300));
        final double c = _hourglassAngle(tester, scenario);
        await tester.pump(const Duration(milliseconds: 300));
        final double d = _hourglassAngle(tester, scenario);
        expect(
          _angleGap(b, d, math.pi),
          lessThan(0.05),
          reason:
              'D1: 600 ms later the angle must repeat modulo a half turn; '
              'angles $b, $c, $d. Scenario: $scenario',
        );
        expect(
          _angleGap(b, c, math.pi),
          greaterThan(0.2),
          reason:
              'D1: 300 ms (a quarter of the turning period) later the angle '
              'must be well away from where it was; angles $b, $c. '
              'Scenario: $scenario',
        );
      },
    );

    testWidgets('disableAnimations: the hourglass is there and does not turn', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'resumeRoom seat 0, deadline_ms 0, disableAnimations true';
      final (RoomController controller, _) = await _connectTurn(
        tester,
        deadlineMs: 0,
        resume: true,
      );
      await _mountGame(tester, controller, disableAnimations: true);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(_timeUpKey),
        findsOneWidget,
        reason:
            'D1: the hourglass is shown still when motion is off. $scenario',
      );
      final double a = _hourglassAngle(tester, scenario);
      await tester.pump(const Duration(milliseconds: 100));
      final double b = _hourglassAngle(tester, scenario);
      await tester.pump(const Duration(milliseconds: 300));
      final double c = _hourglassAngle(tester, scenario);
      expect(
        <double>[_angleGap(a, b, 2 * math.pi), _angleGap(a, c, 2 * math.pi)],
        everyElement(lessThan(1e-6)),
        reason:
            'D1: with disableAnimations the hourglass must stay still; '
            'angles $a, $b, $c. Scenario: $scenario',
      );
    });

    // Guards: above zero nothing changes. GREEN on the base and after.
    for (final Locale locale in <Locale>[_en, _ar]) {
      testWidgets(
        'guard ${locale.languageCode}: at 1 s and above the digits, the '
        '"Ns left" label and the absence of the hourglass are unchanged',
        (WidgetTester tester) async {
          final String scenario =
              'createRoom seat 0, deadline_ms 3000, locale '
              '${locale.languageCode}';
          final (RoomController controller, _) = await _connectTurn(
            tester,
            deadlineMs: 3000,
          );
          await _mountGame(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);
          for (final int left in <int>[3, 2, 1]) {
            expect(_digitsText(tester), '$left', reason: 'digits ($scenario)');
            expect(
              _countdownLabel(tester),
              loc.gameTurnCountdown(left),
              reason: 'label at $left s ($scenario)',
            );
            expect(
              find.byKey(_timeUpKey),
              findsNothing,
              reason: 'no hourglass at $left s ($scenario)',
            );
            await tester.pump(const Duration(seconds: 1));
          }
        },
      );
    }

    testWidgets(
      'room leaves playing: the hourglass is gone and no ticker is left '
      'running beyond a control run that never timed out',
      (WidgetTester tester) async {
        const String scenario =
            'createRoom seat 0, deadline_ms 2000, three seconds to zero, '
            'then game_over winner 1 (seq 2); control: deadline 45000, '
            'game_over at once';

        Future<int> run(int deadlineMs, int secondsToZero) async {
          final (RoomController controller, FakeTransport transport) =
              await _connectTurn(tester, deadlineMs: deadlineMs);
          await _mountGame(tester, controller);
          if (secondsToZero > 0) {
            await _runDownToZero(tester, secondsToZero);
            expect(
              find.byKey(_timeUpKey),
              findsOneWidget,
              reason:
                  'D1: the hourglass must be up before the game ends. $scenario',
            );
          }
          await _push(tester, transport, 'game_over', <String, Object?>{
            'winner': 1,
            'verify_url': 'https://c554-test.invalid/verify',
            'seq': 2,
          });
          // The finished screen asks for the game log; the request's timer
          // is the screen's, not the hourglass's, so it is answered here.
          await _refuseGameLogs(tester, transport);
          for (int i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          expect(
            find.byKey(_timeUpKey),
            findsNothing,
            reason: 'D1: no hourglass once the game is over. $scenario',
          );
          expect(
            find.byKey(const Key('game-screen-winner')),
            findsOneWidget,
            reason: 'fixture: the end card is up ($scenario)',
          );
          final int transient = tester.binding.transientCallbackCount;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          return transient;
        }

        final int control = await run(45000, 0);
        final int afterTimeUp = await run(2000, 2);
        expect(
          afterTimeUp,
          control,
          reason:
              'D1: after the turn is gone no ticker may keep running; '
              'transient callbacks $afterTimeUp vs $control in the control '
              'run. Scenario: $scenario',
        );
      },
    );

    testWidgets('dispose while the hourglass turns leaves nothing behind', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'resumeRoom seat 0, deadline_ms 0, unmount at +450 ms';
      final (RoomController controller, _) = await _connectTurn(
        tester,
        deadlineMs: 0,
        resume: true,
      );
      await _mountGame(tester, controller);
      await tester.pump(const Duration(milliseconds: 450));
      expect(
        find.byKey(_timeUpKey),
        findsOneWidget,
        reason: 'D1: the hourglass must be turning before dispose. $scenario',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(
        tester.takeException(),
        isNull,
        reason:
            'D1: disposing a screen with a turning hourglass must not throw. $scenario',
      );
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'D1: no ticker may outlive the screen. $scenario',
      );
    });
  });

  // ===========================================================================
  // D2/D3: a new game arrives with motion and a voice.
  // ===========================================================================
  group('C-554 D2/D3: the table entrance and the started line', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;

      testWidgets(
        '$lang: lobby to game through RoomRoute: layer on the first game '
        'frame, gone after 400 ms, a tap on the die goes through, one '
        'announcement of "${_startedFor(locale)}", said before anything else',
        (WidgetTester tester) async {
          final String scenario =
              'RoomRoute create, 2 seats, lobby answered (seq 1), '
              'game_started turn 0 g1 (seq 2), turn seat 0 45000 (seq 3), '
              'locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (RoomController controller, FakeTransport transport) =
              await _mountRoomRouteInLobby(tester, locale: locale);

          await _startGameFromLobby(tester, transport);
          final bool layerOnFirstFrame =
              find.byKey(_entranceKey).evaluate().length == 1;

          await _push(tester, transport, 'turn', <String, Object?>{
            'seat': 0,
            'deadline_ms': 45000,
            'seq': 3,
          });
          expect(
            find.byKey(_dieKey),
            findsOneWidget,
            reason: 'fixture: my die must be on the board ($scenario)',
          );
          final int rolls = await _tapDieAndAnswer(tester, transport, seq: 4);
          final bool layerStillThere =
              find.byKey(_entranceKey).evaluate().length == 1;
          await tester.pump(const Duration(milliseconds: 400));

          expect(
            rolls,
            1,
            reason:
                'D2: a tap on the die while the entrance runs must still send '
                'one roll; sent ${transport.sentRaw.map(_typeOf).toList()}. '
                'Scenario: $scenario',
          );
          expect(
            layerOnFirstFrame,
            isTrue,
            reason:
                'D2: game-table-entrance must be in the tree on the first '
                'game frame. Scenario: $scenario',
          );
          expect(
            layerStillThere,
            isTrue,
            reason:
                'D2: the layer must still be up when the tap lands (no time '
                'has passed). Scenario: $scenario',
          );
          expect(
            find.byKey(_entranceKey),
            findsNothing,
            reason:
                'D2: the layer must be gone 400 ms later. Scenario: $scenario',
          );
          expect(
            said.count(_startedFor(locale)),
            1,
            reason:
                'D3: "${_startedFor(locale)}" must be announced exactly once; '
                'heard ${said.messages}. Scenario: $scenario',
          );
          expect(
            said.messages.isEmpty ? null : said.messages.first,
            _startedFor(locale),
            reason:
                'D3: the started line must be heard before the turn '
                'announcement the same build produces; heard '
                '${said.messages}. Scenario: $scenario',
          );
          expect(controller.room!.gameId, 'g1', reason: 'fixture ($scenario)');
        },
      );

      testWidgets(
        '$lang: the rematch board after an end card (new gameId) gets the '
        'layer and the line, once',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1 on GameScreen (seq 1), rematch lobby by 0 '
              '(seq 2), game_started g2 (seq 3), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 0,
            names: <String>['Sam', 'Bob'],
            rematch: <String, Object?>{
              'by': 0,
              'ready': <int>[0],
            },
          );
          await _mountGame(tester, controller, locale: locale);
          expect(
            find.byKey(_entranceKey),
            findsNothing,
            reason: 'a board mounted on an end card has no layer ($scenario)',
          );

          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'LOBBY',
              seats: _seatsOf(<String>['Sam', 'Bob']),
              gameId: 'g1',
              rematch: <String, Object?>{
                'by': 0,
                'ready': <int>[0, 1],
              },
              chainIndex: 1,
              seq: 2,
            ),
          );
          expect(
            find.byKey(_entranceKey),
            findsNothing,
            reason: 'the rematch lobby itself is not a new game ($scenario)',
          );
          expect(
            said.count(_startedFor(locale)),
            0,
            reason: 'nothing started yet, heard ${said.messages} ($scenario)',
          );

          await _startRematchGame(tester, transport, gameId: 'g2', seq: 3);
          final bool layerOnFirstFrame =
              find.byKey(_entranceKey).evaluate().length == 1;
          final bool boardUp =
              find.byKey(_playingChipKey).evaluate().length == 1;
          await _push(tester, transport, 'turn', <String, Object?>{
            'seat': 0,
            'deadline_ms': 45000,
            'seq': 4,
          });
          final int rolls = await _tapDieAndAnswer(tester, transport, seq: 5);
          await tester.pump(const Duration(milliseconds: 400));

          expect(controller.room!.gameId, 'g2', reason: 'fixture ($scenario)');
          expect(
            boardUp,
            isTrue,
            reason: 'fixture: playing board up ($scenario)',
          );
          expect(
            rolls,
            1,
            reason:
                'D2(b): a tap on the die while the layer runs must still send '
                'one roll. Scenario: $scenario',
          );
          expect(
            layerOnFirstFrame,
            isTrue,
            reason:
                'D2(b): the first frame of a board for a new gameId must carry '
                'game-table-entrance. Scenario: $scenario',
          );
          expect(
            find.byKey(_entranceKey),
            findsNothing,
            reason: 'D2(b): gone after 400 ms. Scenario: $scenario',
          );
          expect(
            said.count(_startedFor(locale)),
            1,
            reason:
                'D3: the rematch board announces "${_startedFor(locale)}" '
                'once; heard ${said.messages}. Scenario: $scenario',
          );

          // It does not run twice for one game.
          await _push(tester, transport, 'turn', <String, Object?>{
            'seat': 1,
            'deadline_ms': 45000,
            'seq': 6,
          });
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.byKey(_entranceKey),
            findsNothing,
            reason: 'D2: no second run for one game. Scenario: $scenario',
          );
          expect(
            said.count(_startedFor(locale)),
            1,
            reason: 'D3: no second announcement for one game ($scenario)',
          );
        },
      );
    }

    testWidgets(
      'a plain mount into a game in progress has no layer and no announcement',
      (WidgetTester tester) async {
        const String scenario =
            'GameScreen mounted directly on a PLAYING room, turn seat 0, '
            '45000, locale en';
        final _Announcements said = _Announcements()..install(tester);
        final (RoomController controller, _) = await _connectTurn(
          tester,
          deadlineMs: 45000,
          resume: true,
        );
        await _mountGame(tester, controller);
        expect(
          find.byKey(_boardKey),
          findsWidgets,
          reason: 'fixture ($scenario)',
        );
        expect(
          find.byKey(_entranceKey),
          findsNothing,
          reason: 'D2: a resume into a game has no layer. Scenario: $scenario',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(_entranceKey),
          findsNothing,
          reason: 'D2 (+100 ms). $scenario',
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          said.count(_startedEn),
          0,
          reason:
              'D3: no started line on a plain mount; heard ${said.messages}. $scenario',
        );
      },
    );

    testWidgets(
      'RoomRoute mounted over a room already playing is a plain mount: no '
      'layer, no announcement',
      (WidgetTester tester) async {
        const String scenario =
            'controller already on a PLAYING room (seat 0 turn, 45000), then '
            'RoomRoute create mounted over it, locale en';
        final _Announcements said = _Announcements()..install(tester);
        final (RoomController controller, _) = await _connectTurn(
          tester,
          deadlineMs: 45000,
        );
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _harness(
            FeedbackScope(
              settings: FeedbackSettings.forTest(),
              service: const NoopFeedbackService(),
              child: RoomRoute(
                controller: controller,
                action: LobbyAction.resume,
                playerName: 'Sam',
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: 'fixture: RoomRoute starts on the game ($scenario)',
        );
        expect(
          find.byKey(_entranceKey),
          findsNothing,
          reason:
              'D2: RoomRoute passes fromLobby only when its listener flips, '
              'never from initState. Scenario: $scenario',
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(_entranceKey),
          findsNothing,
          reason: 'D2 (+100 ms). $scenario',
        );
        expect(
          said.count(_startedEn),
          0,
          reason: 'D3: heard ${said.messages}. $scenario',
        );
      },
    );

    for (final Locale locale in <Locale>[_en, _ar]) {
      testWidgets(
        '${locale.languageCode}: disableAnimations: no layer is ever drawn, '
        'the line is still said once (lobby to game, then rematch board)',
        (WidgetTester tester) async {
          final String scenario =
              'RoomRoute lobby to game with disableAnimations true, locale '
              '${locale.languageCode}';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _mountRoomRouteInLobby(
            tester,
            locale: locale,
            disableAnimations: true,
          );
          await _startGameFromLobby(tester, transport);
          final bool layerOnFirstFrame = find
              .byKey(_entranceKey)
              .evaluate()
              .isNotEmpty;
          await tester.pump(const Duration(milliseconds: 100));
          final bool layerLater = find
              .byKey(_entranceKey)
              .evaluate()
              .isNotEmpty;
          await tester.pump(const Duration(milliseconds: 400));

          expect(
            <bool>[layerOnFirstFrame, layerLater],
            everyElement(isFalse),
            reason:
                'D2: with disableAnimations the layer is not drawn at all. '
                'Scenario: $scenario',
          );
          expect(
            said.count(_startedFor(locale)),
            1,
            reason:
                'D3: the line is announced whether or not animations are '
                'disabled; heard ${said.messages}. Scenario: $scenario',
          );
          expect(
            controller.room!.state.name,
            'playing',
            reason: 'fixture ($scenario)',
          );
        },
      );
    }

    testWidgets(
      'disableAnimations: the rematch board has no layer and still says the line',
      (WidgetTester tester) async {
        const String scenario =
            'FINISHED g1 (seq 1), rematch lobby (seq 2), game_started g2 '
            '(seq 3), disableAnimations true, locale en';
        final _Announcements said = _Announcements()..install(tester);
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectFinished(
          tester,
          mySeat: 0,
          names: <String>['Sam', 'Bob'],
          rematch: <String, Object?>{
            'by': 0,
            'ready': <int>[0],
          },
        );
        await _mountGame(tester, controller, disableAnimations: true);
        await _push(
          tester,
          transport,
          'room',
          _roomJson(
            state: 'LOBBY',
            seats: _seatsOf(<String>['Sam', 'Bob']),
            gameId: 'g1',
            rematch: <String, Object?>{
              'by': 0,
              'ready': <int>[0, 1],
            },
            chainIndex: 1,
            seq: 2,
          ),
        );
        await _startRematchGame(tester, transport, gameId: 'g2', seq: 3);
        final bool layer = find.byKey(_entranceKey).evaluate().isNotEmpty;
        await tester.pump(const Duration(milliseconds: 400));
        expect(controller.room!.gameId, 'g2', reason: 'fixture ($scenario)');
        expect(
          layer,
          isFalse,
          reason: 'D2: no layer under disableAnimations. $scenario',
        );
        expect(
          said.count(_startedEn),
          1,
          reason: 'D3: heard ${said.messages}. $scenario',
        );
      },
    );

    testWidgets(
      'the layer is opaque in the screen colour on its first frame and the '
      'board shows through once it is gone',
      (WidgetTester tester) async {
        const String scenario =
            'RoomRoute lobby to game, pixel under the centre of game-die, '
            'first frame and +400 ms, locale en, 390x844';
        final (RoomController controller, FakeTransport transport) =
            await _mountRoomRouteInLobby(tester);
        await _startGameFromLobby(tester, transport);
        await _push(tester, transport, 'turn', <String, Object?>{
          'seat': 0,
          'deadline_ms': 45000,
          'seq': 3,
        });
        expect(
          find.byKey(_dieKey),
          findsOneWidget,
          reason: 'fixture ($scenario)',
        );
        final Offset at = tester.getCenter(find.byKey(_dieKey));
        final Color scaffold = Theme.of(tester.element(find.byType(GameScreen)))
            .scaffoldBackgroundColor;
        final Color first = await _pixelAt(tester, at);
        await tester.pump(const Duration(milliseconds: 400));
        final Color later = await _pixelAt(tester, at);

        expect(
          _sameRgb(first, scaffold),
          isTrue,
          reason:
              'D2: on the first frame the layer is opaque and painted in '
              'scaffoldBackgroundColor $scaffold; the pixel over the die is '
              '$first. Scenario: $scenario',
        );
        expect(
          _sameRgb(later, scaffold),
          isFalse,
          reason:
              'D2: 400 ms later the die must show through; pixel $later is '
              'still the scaffold colour $scaffold. Scenario: $scenario',
        );
        expect(controller.room!.gameId, 'g1', reason: 'fixture ($scenario)');
      },
    );
  });

  // ===========================================================================
  // D4: the end card speaks.
  // ===========================================================================
  group('C-554 D4: the end card announces what the others do', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;

      testWidgets(
        '$lang: another seat asking for a rematch is announced once, with the '
        'ask line\'s name; a later ready update adds nothing; no cue',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob/Ken, me seat 1, rematch lobby by 2 '
              '(seq 2) then ready [2,0] (seq 3), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final _RecordingFeedback cues = _RecordingFeedback();
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 1,
            names: <String>['Sam', 'Bob', 'Ken'],
          );
          await _mountGame(tester, controller, locale: locale, service: cues);
          final AppLocalizations loc = _locOf(tester);
          expect(
            said.messages,
            isEmpty,
            reason: 'first state announces nothing ($scenario)',
          );

          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'LOBBY',
              players: 3,
              seats: _seatsOf(<String>['Sam', 'Bob', 'Ken']),
              gameId: 'g1',
              rematch: <String, Object?>{
                'by': 2,
                'ready': <int>[2],
              },
              chainIndex: 1,
              seq: 2,
            ),
          );
          expect(
            said.messages,
            <String>[loc.endRematchAsk('Ken')],
            reason:
                'D4: one announcement of endRematchAsk("Ken"); heard '
                '${said.messages}. Scenario: $scenario',
          );

          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'LOBBY',
              players: 3,
              seats: _seatsOf(<String>['Sam', 'Bob', 'Ken']),
              gameId: 'g1',
              rematch: <String, Object?>{
                'by': 2,
                'ready': <int>[2, 0],
              },
              chainIndex: 1,
              seq: 3,
            ),
          );
          expect(
            said.messages,
            hasLength(1),
            reason:
                'D4: the ask is announced once per round; a ready update must '
                'add nothing; heard ${said.messages}. Scenario: $scenario',
          );
          expect(
            cues.recorded,
            isEmpty,
            reason:
                'D4: no haptic or sound; played ${cues.recorded} ($scenario)',
          );
        },
      );

      testWidgets(
        '$lang: seats leaving are announced one change at a time, only the '
        'new names, joined with the card\'s separator',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob/Ken/Mia, me seat 0: player_left 1 '
              '(seq 2), room without 2 and 3 (seq 3), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 0,
            names: <String>['Sam', 'Bob', 'Ken', 'Mia'],
          );
          await _mountGame(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);

          await _push(tester, transport, 'player_left', <String, Object?>{
            'seat': 1,
            'seq': 2,
          });
          _expectCardLeftLine(tester, loc.endLeft('Bob'), scenario);
          expect(
            said.messages,
            <String>[loc.endLeft('Bob')],
            reason:
                'D4: endLeft("Bob") once; heard ${said.messages}. $scenario',
          );

          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'FINISHED',
              players: 4,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(3, name: 'Mia'),
              ],
              turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 8),
              winner: 0,
              gameId: 'g1',
              seq: 3,
            ),
          );
          _expectCardLeftLine(
            tester,
            loc.endLeft(<String>['Bob', 'Ken'].join(_sepFor(locale))),
            scenario,
          );
          expect(
            said.messages,
            <String>[loc.endLeft('Bob'), loc.endLeft('Ken')],
            reason:
                'D4: the second change names only the seat that joined the '
                'departed list ("Ken"), not "Bob" again; heard '
                '${said.messages}. Scenario: $scenario',
          );
        },
      );

      testWidgets('$lang: two seats leaving in one change are named together', (
        WidgetTester tester,
      ) async {
        final String scenario =
            'FINISHED g1, seats Sam/Bob/Ken/Mia, me seat 0, one room '
            'snapshot (seq 2) without Bob and Ken, locale $lang';
        final _Announcements said = _Announcements()..install(tester);
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectFinished(
          tester,
          mySeat: 0,
          names: <String>['Sam', 'Bob', 'Ken', 'Mia'],
        );
        await _mountGame(tester, controller, locale: locale);
        final AppLocalizations loc = _locOf(tester);
        await _push(
          tester,
          transport,
          'room',
          _roomJson(
            state: 'FINISHED',
            players: 4,
            seats: <Map<String, Object?>>[
              _seatJson(0, name: 'Sam'),
              _seatJson(3, name: 'Mia'),
            ],
            turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 8),
            winner: 0,
            gameId: 'g1',
            seq: 2,
          ),
        );
        _expectCardLeftLine(
          tester,
          loc.endLeft(<String>['Bob', 'Ken'].join(_sepFor(locale))),
          scenario,
        );
        expect(
          said.messages,
          <String>[
            loc.endLeft(<String>['Bob', 'Ken'].join(_sepFor(locale))),
          ],
          reason:
              'D4: one endLeft for both names; heard ${said.messages}. $scenario',
        );
      });

      testWidgets(
        '$lang: everyone else leaving is announced as endEveryoneLeft '
        'instead of endLeft, even when it takes several seats in one change',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob/Ken, me seat 0, room with only me '
              '(seq 2), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 0,
            names: <String>['Sam', 'Bob', 'Ken'],
          );
          await _mountGame(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);
          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'FINISHED',
              players: 3,
              seats: <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
              turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 8),
              winner: 0,
              gameId: 'g1',
              seq: 2,
            ),
          );
          _expectCardLeftLine(tester, loc.endEveryoneLeft, scenario);
          expect(
            said.messages,
            <String>[loc.endEveryoneLeft],
            reason:
                'D4: endEveryoneLeft alone, never with endLeft; heard '
                '${said.messages}. Scenario: $scenario',
          );
        },
      );

      testWidgets(
        '$lang: the host role passing to me is announced "${_hostNowFor(locale)}" '
        'once; with a departure in the same change, left comes first',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob/Ken, host 0, me seat 1: room with '
              'host_seat 1, all seats present (seq 2), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 1,
            names: <String>['Sam', 'Bob', 'Ken'],
          );
          await _mountGame(tester, controller, locale: locale);
          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'FINISHED',
              hostSeat: 1,
              players: 3,
              seats: _seatsOf(<String>['Sam', 'Bob', 'Ken']),
              turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 8),
              winner: 0,
              gameId: 'g1',
              seq: 2,
            ),
          );
          expect(controller.isHost, isTrue, reason: 'fixture ($scenario)');
          expect(said.messages, <String>[
            _hostNowFor(locale),
          ], reason: 'D4: endHostNow once; heard ${said.messages}. $scenario');
        },
      );

      testWidgets(
        '$lang: a departure that hands me the host role announces left, then '
        'host',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob/Ken, host 0, me seat 1, '
              'player_left seat 0 host_seat 1 (seq 2), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 1,
            names: <String>['Sam', 'Bob', 'Ken'],
          );
          await _mountGame(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);
          await _push(tester, transport, 'player_left', <String, Object?>{
            'seat': 0,
            'host_seat': 1,
            'seq': 2,
          });
          expect(controller.isHost, isTrue, reason: 'fixture ($scenario)');
          _expectCardLeftLine(tester, loc.endLeft('Sam'), scenario);
          expect(
            said.messages,
            <String>[loc.endLeft('Sam'), _hostNowFor(locale)],
            reason:
                'D4: endLeft("Sam") then endHostNow; heard ${said.messages}. '
                'Scenario: $scenario',
          );
        },
      );

      testWidgets(
        '$lang: ask, left and host in one change come in that order, nothing '
        'else, no cue',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob/Ken, host 0, me seat 1; one room '
              'snapshot (seq 2): rematch by 2, Sam gone, host_seat 1; locale '
              '$lang';
          final _Announcements said = _Announcements()..install(tester);
          final _RecordingFeedback cues = _RecordingFeedback();
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 1,
            names: <String>['Sam', 'Bob', 'Ken'],
          );
          await _mountGame(tester, controller, locale: locale, service: cues);
          final AppLocalizations loc = _locOf(tester);
          await _push(
            tester,
            transport,
            'room',
            _roomJson(
              state: 'LOBBY',
              hostSeat: 1,
              players: 3,
              seats: <Map<String, Object?>>[
                _seatJson(1, name: 'Bob'),
                _seatJson(2, name: 'Ken'),
              ],
              gameId: 'g1',
              rematch: <String, Object?>{
                'by': 2,
                'ready': <int>[2],
              },
              chainIndex: 1,
              seq: 2,
            ),
          );
          _expectCardLeftLine(tester, loc.endLeft('Sam'), scenario);
          expect(
            said.messages,
            <String>[
              loc.endRematchAsk('Ken'),
              loc.endLeft('Sam'),
              _hostNowFor(locale),
            ],
            reason:
                'D4: ask, then left, then host, once each; heard '
                '${said.messages}. Scenario: $scenario',
          );
          expect(cues.recorded, isEmpty, reason: 'D4: no cue ($scenario)');
        },
      );

      testWidgets(
        '$lang: everyone leaving and the host role passing in one change: '
        'everyone-left, then host',
        (WidgetTester tester) async {
          final String scenario =
              'FINISHED g1, seats Sam/Bob, host 0, me seat 1; player_left 0 '
              'host_seat 1 (seq 2), locale $lang';
          final _Announcements said = _Announcements()..install(tester);
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectFinished(
            tester,
            mySeat: 1,
            names: <String>['Sam', 'Bob'],
          );
          await _mountGame(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);
          await _push(tester, transport, 'player_left', <String, Object?>{
            'seat': 0,
            'host_seat': 1,
            'seq': 2,
          });
          _expectCardLeftLine(tester, loc.endEveryoneLeft, scenario);
          expect(
            said.messages,
            <String>[loc.endEveryoneLeft, _hostNowFor(locale)],
            reason:
                'D4: endEveryoneLeft then endHostNow, never endLeft; heard '
                '${said.messages}. Scenario: $scenario',
          );
        },
      );
    }

    testWidgets(
      'the state the card first appears in is not announced: a rematch ask, a '
      'departure and the host role already there at mount',
      (WidgetTester tester) async {
        const String scenario =
            'FINISHED g1 seats Sam/Bob/Ken, me seat 1; before mounting: '
            'room with rematch by 2, Sam gone, host_seat 1 (seq 2); then '
            'GameScreen mounted, 3 s of pumps';
        final _Announcements said = _Announcements()..install(tester);
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectFinished(
          tester,
          mySeat: 1,
          names: <String>['Sam', 'Bob', 'Ken'],
        );
        transport.pushText(
          _frame(
            type: 'room',
            data: _roomJson(
              state: 'LOBBY',
              hostSeat: 1,
              players: 3,
              seats: <Map<String, Object?>>[
                _seatJson(1, name: 'Bob'),
                _seatJson(2, name: 'Ken'),
              ],
              gameId: 'g1',
              rematch: <String, Object?>{
                'by': 2,
                'ready': <int>[2],
              },
              chainIndex: 1,
              seq: 2,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(controller.isHost, isTrue, reason: 'fixture ($scenario)');
        await _mountGame(tester, controller);
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          said.messages,
          isEmpty,
          reason:
              'D4: only changes after the card is up are announced; heard '
              '${said.messages}. Scenario: $scenario',
        );
      },
    );

    testWidgets('my own rematch ask is not announced', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'FINISHED g1 seats Sam/Bob, me seat 1: tap Play again, reply '
          'room with rematch by 1 (seq 2)';
      final _Announcements said = _Announcements()..install(tester);
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectFinished(
        tester,
        mySeat: 1,
        names: <String>['Sam', 'Bob'],
      );
      await _mountGame(tester, controller);
      await tester.tap(find.byKey(_rematchKey));
      await tester.pump();
      final String id = _idOf(
        transport.sentRaw.where((String raw) => _typeOf(raw) == 'rematch').last,
      );
      transport.pushText(
        _frame(
          type: 'room',
          re: id,
          data: _roomJson(
            state: 'LOBBY',
            seats: _seatsOf(<String>['Sam', 'Bob']),
            gameId: 'g1',
            rematch: <String, Object?>{
              'by': 1,
              'ready': <int>[1],
            },
            chainIndex: 1,
            seq: 2,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        controller.room!.rematch?.by,
        1,
        reason: 'fixture: my ask is in the room ($scenario)',
      );
      expect(
        said.messages,
        isEmpty,
        reason:
            'D4: my own ask is not announced; heard ${said.messages}. $scenario',
      );
    });

    testWidgets('the offline card announces none of it', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'FINISHED g1 seats Sam/Bob/Ken, me seat 0; the transport ends '
          'from the far side, 3 s of pumps';
      final _Announcements said = _Announcements()..install(tester);
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectFinished(
        tester,
        mySeat: 0,
        names: <String>['Sam', 'Bob', 'Ken'],
      );
      await _mountGame(tester, controller);
      final AppLocalizations loc = _locOf(tester);
      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        find.byKey(_offlineKey),
        findsOneWidget,
        reason: 'fixture: the card is offline ($scenario)',
      );
      final List<String> d4 = said.messages
          .where(
            (String m) =>
                m.contains(loc.endEveryoneLeft) ||
                m == _hostNowEn ||
                m.contains('wants to play again') ||
                m.contains('left the table'),
          )
          .toList();
      expect(
        d4,
        isEmpty,
        reason:
            'D4: the offline card announces no table changes; heard ${said.messages}. $scenario',
      );
    });

    testWidgets('a table that has closed announces nothing further', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'FINISHED g1 seats Sam/Bob/Ken, me seat 1: tap Play again, '
          'rematch answered NO_SUCH_ROOM, 3 s of pumps';
      final _Announcements said = _Announcements()..install(tester);
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectFinished(
        tester,
        mySeat: 1,
        names: <String>['Sam', 'Bob', 'Ken'],
      );
      await _mountGame(tester, controller);
      await tester.tap(find.byKey(_rematchKey));
      await tester.pump();
      final String id = _idOf(
        transport.sentRaw.where((String raw) => _typeOf(raw) == 'rematch').last,
      );
      await _push(tester, transport, 'error', <String, Object?>{
        'code': 'NO_SUCH_ROOM',
        'message': 'gone',
      }, re: id);
      expect(
        find.byKey(const Key('end-card-rematch-gone')),
        findsOneWidget,
        reason: 'fixture: the card says the table closed ($scenario)',
      );
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        said.messages,
        isEmpty,
        reason:
            'D4: nothing on a closed table; heard ${said.messages}. $scenario',
      );
    });
  });

  // ===========================================================================
  // D5: the strings.
  // ===========================================================================
  group('C-554 D5: the arb strings', () {
    Map<String, dynamic> readArb(String name) {
      Directory dir = Directory.current;
      File file = File(p.join(dir.path, 'lib', 'l10n', name));
      if (!file.existsSync()) {
        dir = Directory(p.join(dir.path, 'packages', 'ludo_client'));
        file = File(p.join(dir.path, 'lib', 'l10n', name));
      }
      expect(file.existsSync(), isTrue, reason: 'expected ${file.path}');
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }

    const Map<String, (String, String)> texts = <String, (String, String)>{
      'gameTurnTimeUp': (_timeUpEn, _timeUpAr),
      'gameStartedLine': (_startedEn, _startedAr),
      'endHostNow': (_hostNowEn, _hostNowAr),
    };

    texts.forEach((String key, (String, String) pair) {
      test('$key carries the spec text in both files and an @ description', () {
        final Map<String, dynamic> en = readArb('app_en.arb');
        final Map<String, dynamic> ar = readArb('app_ar.arb');
        expect(
          en[key],
          pair.$1,
          reason:
              'D5: app_en.arb $key must read "${pair.$1}"; it is ${en[key]}',
        );
        expect(
          ar[key],
          pair.$2,
          reason:
              'D5: app_ar.arb $key must read "${pair.$2}"; it is ${ar[key]}',
        );
        final Object? meta = en['@$key'];
        expect(
          meta is Map<String, dynamic> &&
              meta['description'] is String &&
              (meta['description'] as String).trim().isNotEmpty,
          isTrue,
          reason:
              'D5: app_en.arb must carry @$key with a description; got $meta',
        );
      });
    });
  });
}
