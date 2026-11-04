// Conformance tests for work/ludo/orders/C-555-resync-that-does-something.md
// (D1-D4), written from that spec alone. Orders 554 and 555 implement in
// parallel in trees this file's author has not read, so on a tree without
// them every case that pins new behaviour is expected RED and the guards GREEN.
//
// `RoomController.resync()` and `isResyncing` do not exist on the base. They
// are called through `dynamic`, behind two small wrappers that turn a
// NoSuchMethodError into a test failure naming the missing member, so the file
// compiles on the base and the cases that need them go red at that one call.
// Everything else is asserted through Keys, visible text, the render tree and
// the wire (FakeTransport.sentRaw), never through a symbol the spec adds.
//
// D1 runs under fake_async over a live FakeTransport, the way
// test/net/room_controller_test.dart reaches its request-timeout case: a seq
// gap starts the controller's own resume, no reply is ever sent, ten seconds
// pass, and the controller is left `connected` with `hasDesynced` true. D2
// reaches the same state under a LobbyScreen. D3 and D4 mount the real EndCard
// in an EndCardFrame, the way GameScreen mounts it, and swap its inputs
// between pumps so the same State sees the change.
//
// Opacity and rotation are measured on the render tree, not read off a widget
// type: opacity as the product of every Opacity and FadeTransition render
// object above a finder (and the lowest such product below it), rotation as
// the angle of the icon's accumulated paint transform. So the cases do not
// care whether the motion is built from AnimatedOpacity, FadeTransition,
// RotationTransition or a hand-rolled ticker.
//
// Nothing here calls pumpAndSettle while the sync mark turns; every wait is a
// fixed pump, and every request still open at the end of a case is answered
// so no timer is left for the framework to find.
//
// Reproduce a failure by name: each reason line carries the scenario (frames
// pushed, pump times, locale) it ran.

import 'dart:convert';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c555-test.invalid/ws';

const Key _resyncKey = Key('lobby-resync-button');
const Key _bannerKey = Key('lobby-desync-banner');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _askKey = Key('end-card-rematch-ask');
const Key _leftKey = Key('end-card-left');
const Key _goneKey = Key('end-card-rematch-gone');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

// --- frames and snapshots, the sibling suites' idiom --------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c555-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _roomJson({int seq = 1}) => <String, Object?>{
  'code': 'C555XX',
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 4,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    <String, Object?>{
      'seat': 0,
      'name': 'Sam',
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];
  Object? _rejectNextWith;

  void enqueue(FakeTransport transport) => _queue.add(transport);
  void rejectNextWith(Object error) => _rejectNextWith = error;

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_rejectNextWith != null) {
      final Object error = _rejectNextWith!;
      _rejectNextWith = null;
      throw error;
    }
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: no transport queued for call #${calls.length}',
      );
    }
    return _queue.removeAt(0);
  }
}

List<String> _resumes(FakeTransport transport) =>
    transport.sentRaw.where((String raw) => _typeOf(raw) == 'resume').toList();

// --- the members this order adds, through dynamic ----------------------------

Future<void> _resync(RoomController controller, String scenario) {
  try {
    return (controller as dynamic).resync() as Future<void>;
  } on NoSuchMethodError catch (e) {
    fail(
      'D1: RoomController.resync() is missing, so no resync can be started. '
      'Scenario: $scenario. Error: $e',
    );
  }
}

bool _isResyncing(RoomController controller, String scenario) {
  try {
    return (controller as dynamic).isResyncing as bool;
  } on NoSuchMethodError catch (e) {
    fail(
      'D1: RoomController.isResyncing is missing. Scenario: $scenario. '
      'Error: $e',
    );
  }
}

// --- D1 fixtures (fake_async) --------------------------------------------------

class _Live {
  _Live(this.controller, this.transport, this.connector);
  final RoomController controller;
  final FakeTransport transport;
  final _Connector connector;
}

/// A connected lobby (seq 1) whose seq-9 presence push started a resume that
/// nobody answered: ten-odd seconds later the controller is `connected`,
/// `hasDesynced`, on the same open transport.
_Live _desyncedAfterTimeout(FakeAsync async) {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  controller.createRoom(name: 'Sam', players: 4);
  async.flushMicrotasks();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson()));
  async.flushMicrotasks();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture: connected lobby',
  );

  transport.pushText(
    _frame(
      type: 'presence',
      data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 9},
    ),
  );
  async.flushMicrotasks();
  expect(
    controller.hasDesynced,
    isTrue,
    reason: 'fixture: seq 9 against seq 1 is a gap',
  );
  expect(
    _resumes(transport),
    hasLength(1),
    reason: 'fixture: the gap sent one resume',
  );
  async.elapse(const Duration(seconds: 11));
  async.flushMicrotasks();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture: a timeout keeps the socket',
  );
  expect(
    controller.hasDesynced,
    isTrue,
    reason: 'fixture: a resume that times out leaves hasDesynced true',
  );
  expect(
    connector.calls,
    hasLength(1),
    reason: 'fixture: one transport so far',
  );
  return _Live(controller, transport, connector);
}

// --- D2 fixtures (widgets) -----------------------------------------------------

Widget _harness(
  Widget child, {
  Locale locale = _en,
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
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: screen!,
      );
    },
    home: child,
  );
}

/// A connected LobbyScreen whose first resume timed out on the open socket:
/// the banner and its Resync button are up and nothing is in flight.
Future<_Live> _desyncedLobby(
  WidgetTester tester, {
  Locale locale = _en,
  bool disableAnimations = false,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 4,
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
  transport.pushText(_frame(type: 'room', re: id, data: _roomJson()));
  await tester.pump();
  await tester.pump();
  transport.pushText(
    _frame(
      type: 'presence',
      data: <String, Object?>{'seat': 0, 'connected': false, 'seq': 9},
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.hasDesynced,
    isTrue,
    reason: 'fixture: seq 9 against seq 1',
  );
  expect(
    _resumes(transport),
    hasLength(1),
    reason: 'fixture: the gap sent one resume',
  );
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture: the timeout keeps the socket',
  );
  expect(controller.hasDesynced, isTrue, reason: 'fixture: still desynced');
  expect(
    find.byKey(_resyncKey),
    findsOneWidget,
    reason: 'fixture: the Resync button is up',
  );
  addTearDown(controller.dispose);
  return _Live(controller, transport, connector);
}

VoidCallback? _onPressed(WidgetTester tester) =>
    (tester.widget(find.byKey(_resyncKey)) as ButtonStyleButton).onPressed;

double _syncAngle(WidgetTester tester, String scenario) {
  final Finder icon = find.descendant(
    of: find.byKey(_resyncKey),
    matching: find.byIcon(Icons.sync),
  );
  expect(
    icon,
    findsOneWidget,
    reason: 'D2: lobby-resync-button must hold Icons.sync. Scenario: $scenario',
  );
  final Matrix4 m = tester.renderObject<RenderBox>(icon).getTransformTo(null);
  return math.atan2(m.entry(1, 0), m.entry(0, 0));
}

double _angleGap(double a, double b) {
  double d = (a - b) % (2 * math.pi);
  if (d < 0) {
    d += 2 * math.pi;
  }
  return math.min(d, 2 * math.pi - d);
}

/// Answers the newest open resume with the room at seq 9.
Future<void> _answerResume(WidgetTester tester, _Live live) async {
  live.transport.pushText(
    _frame(
      type: 'room',
      re: _idOf(_resumes(live.transport).last),
      data: _roomJson(seq: 9),
    ),
  );
  await tester.pump();
  await tester.pump();
}

// --- opacity, measured ---------------------------------------------------------

double _selfFactor(RenderObject node) {
  if (node is RenderOpacity) {
    return node.opacity;
  }
  if (node is RenderAnimatedOpacity) {
    return node.opacity.value;
  }
  return 1.0;
}

/// The lowest product of Opacity/FadeTransition factors on any path from the
/// root down to a leaf under [node], starting from [above].
double _lowestBelow(RenderObject node, double above) {
  final double here = above * _selfFactor(node);
  double lowest = here;
  node.visitChildren((RenderObject child) {
    lowest = math.min(lowest, _lowestBelow(child, here));
  });
  return lowest;
}

/// How visible [finder] is: every opacity above it times the lowest product
/// below it. 1.0 is fully drawn.
double _opacityOf(WidgetTester tester, Finder finder) {
  final RenderObject node = tester.renderObject(finder);
  double above = 1.0;
  RenderObject? up = node.parent;
  while (up != null) {
    above *= _selfFactor(up);
    up = up.parent;
  }
  return _lowestBelow(node, above);
}

// --- the end card, swapped between pumps ---------------------------------------

class _Props {
  const _Props({
    this.rematch,
    this.rematchByName,
    this.occupied = const <int>[0, 1],
    this.departed = const <String>[],
    this.everyoneLeft = false,
    this.rematchGone = false,
  });

  final RematchState? rematch;
  final String? rematchByName;
  final List<int> occupied;
  final List<String> departed;
  final bool everyoneLeft;
  final bool rematchGone;
}

const _Props _plain = _Props();
const _Props _asked = _Props(
  rematch: RematchState(by: 1, ready: <int>[1]),
  rematchByName: 'Bob',
);
const _Props _oneLeft = _Props(
  occupied: <int>[0, 1],
  departed: <String>['Ken'],
);
const _Props _alone = _Props(
  occupied: <int>[0],
  departed: <String>['Bob'],
  everyoneLeft: true,
);
const _Props _gone = _Props(rematchGone: true);

class _Card {
  _Card(this.props, this.taps);
  final ValueNotifier<_Props> props;
  final List<int> taps;

  int get newTableTaps => taps.length;
}

Future<_Card> _mountCard(
  WidgetTester tester,
  _Props initial, {
  Locale locale = _en,
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ValueNotifier<_Props> props = ValueNotifier<_Props>(initial);
  addTearDown(props.dispose);
  final List<int> taps = <int>[];
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: const NoopFeedbackService(),
        child: Scaffold(
          body: SizedBox(
            width: 390,
            height: 844,
            child: ValueListenableBuilder<_Props>(
              valueListenable: props,
              builder: (BuildContext context, _Props p, Widget? _) {
                return EndCardFrame(
                  card: EndCard(
                    mySeat: 0,
                    winnerSeat: 0,
                    winnerName: 'Sam',
                    seatColors: LudoColors.seats,
                    stats: null,
                    verifyUrl: null,
                    onVerify: () {},
                    onNewTable: () => taps.add(taps.length),
                    rematch: p.rematch,
                    rematchByName: p.rematchByName,
                    occupiedSeats: p.occupied,
                    rematchGone: p.rematchGone,
                    onRematch: () {},
                    departedNames: p.departed,
                    everyoneLeft: p.everyoneLeft,
                  ),
                  trailing: const SizedBox(height: 40),
                );
              },
            ),
          ),
        ),
      ),
      locale: locale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  return _Card(props, taps);
}

/// Pumps [by] and checks the invariant that holds at every pump: exactly one
/// New table in the tree, and no line key twice.
Future<void> _pumpChecked(
  WidgetTester tester,
  Duration by,
  String scenario,
) async {
  await tester.pump(by);
  expect(
    find.byKey(_newRoomKey),
    findsOneWidget,
    reason:
        'D3: exactly one game-screen-new-room-button must be in the tree at '
        'every pump. Scenario: $scenario',
  );
  for (final Key line in <Key>[_askKey, _leftKey, _goneKey, _rematchKey]) {
    expect(
      find.byKey(line).evaluate().length,
      lessThanOrEqualTo(1),
      reason:
          'D3/D4: $line must never be in the tree twice. Scenario: $scenario',
    );
  }
}

Future<void> _tapNewTable(WidgetTester tester) async {
  await tester.tap(find.byKey(_newRoomKey), warnIfMissed: false);
}

void main() {
  // ===========================================================================
  // D1: RoomController.resync() and isResyncing.
  // ===========================================================================
  group('C-555 D1: the controller resync', () {
    test('resync() after a timed-out resume sends one resume on the same '
        'transport, isResyncing holds until the reply, a good reply clears '
        'hasDesynced', () {
      fakeAsync((FakeAsync async) {
        const String scenario =
            'lobby seq 1, presence seq 9 (gap), resume unanswered for 11 s, '
            'resync(), room reply seq 9';
        final _Live live = _desyncedAfterTimeout(async);
        final RoomController controller = live.controller;
        expect(
          _isResyncing(controller, scenario),
          isFalse,
          reason: 'D1: nothing is in flight after the timeout. $scenario',
        );

        bool settled = false;
        _resync(controller, scenario).then((_) => settled = true);
        async.flushMicrotasks();

        expect(
          _resumes(live.transport),
          hasLength(2),
          reason:
              'D1: resync() must send one more resume on the open transport; '
              'sent ${live.transport.sentRaw.map(_typeOf).toList()}. $scenario',
        );
        expect(
          live.connector.calls,
          hasLength(1),
          reason: 'D1: a resync never opens a second transport. $scenario',
        );
        expect(
          _isResyncing(controller, scenario),
          isTrue,
          reason:
              'D1: isResyncing must be true while the resume is out. $scenario',
        );
        expect(
          settled,
          isFalse,
          reason:
              'D1: the future must not complete before the reply. $scenario',
        );
        final Map<String, Object?> sent = _decode(
          _resumes(live.transport).last,
        );
        expect(
          sent['d'],
          <String, Object?>{'code': 'C555XX', 'seat_token': 'tok-0'},
          reason:
              'D1: the resume carries the room code and the cached seat token. $scenario',
        );

        live.transport.pushText(
          _frame(
            type: 'room',
            re: sent['id']! as String,
            data: _roomJson(seq: 9),
          ),
        );
        async.flushMicrotasks();

        expect(
          settled,
          isTrue,
          reason: 'D1: the future completes on the reply. $scenario',
        );
        expect(
          _isResyncing(controller, scenario),
          isFalse,
          reason: 'D1: isResyncing is false after the reply. $scenario',
        );
        expect(
          controller.hasDesynced,
          isFalse,
          reason: 'D1: a successful reply clears hasDesynced. $scenario',
        );
        expect(
          controller.phase,
          RoomPhase.connected,
          reason: 'D1: still connected. $scenario',
        );
        expect(
          live.connector.calls,
          hasLength(1),
          reason: 'D1: still one transport. $scenario',
        );
        controller.dispose();
      });
    });

    test('a second resync() while one is in flight sends nothing and '
        'completes at once', () {
      fakeAsync((FakeAsync async) {
        const String scenario =
            'timed-out resume, resync(), resync() again before any reply';
        final _Live live = _desyncedAfterTimeout(async);
        final RoomController controller = live.controller;

        bool firstSettled = false;
        _resync(controller, scenario).then((_) => firstSettled = true);
        async.flushMicrotasks();
        expect(
          _resumes(live.transport),
          hasLength(2),
          reason: 'D1: fixture, first resync sent. $scenario',
        );

        bool secondSettled = false;
        _resync(controller, scenario).then((_) => secondSettled = true);
        async.flushMicrotasks();

        expect(
          _resumes(live.transport),
          hasLength(2),
          reason:
              'D1: a second resync() in flight must send nothing; sent '
              '${live.transport.sentRaw.map(_typeOf).toList()}. $scenario',
        );
        expect(
          secondSettled,
          isTrue,
          reason:
              'D1: a resync() that starts nothing completes at once. $scenario',
        );
        expect(
          firstSettled,
          isFalse,
          reason: 'D1: the first is still waiting. $scenario',
        );

        live.transport.pushText(
          _frame(
            type: 'room',
            re: _idOf(_resumes(live.transport).last),
            data: _roomJson(seq: 9),
          ),
        );
        async.flushMicrotasks();
        expect(
          firstSettled,
          isTrue,
          reason: 'D1: the first completes on the reply. $scenario',
        );
        controller.dispose();
      });
    });

    test('a resync that times out settles, clears isResyncing and keeps '
        'hasDesynced and the socket', () {
      fakeAsync((FakeAsync async) {
        const String scenario = 'timed-out resume, resync(), no reply, 11 s';
        final _Live live = _desyncedAfterTimeout(async);
        final RoomController controller = live.controller;

        bool settled = false;
        _resync(controller, scenario).then((_) => settled = true);
        async.flushMicrotasks();
        expect(
          _isResyncing(controller, scenario),
          isTrue,
          reason: 'D1: fixture, in flight. $scenario',
        );
        async.elapse(const Duration(seconds: 11));
        async.flushMicrotasks();

        expect(
          settled,
          isTrue,
          reason: 'D1: the non-fatal failure settles the future. $scenario',
        );
        expect(
          _isResyncing(controller, scenario),
          isFalse,
          reason:
              'D1: isResyncing is false after a non-fatal failure. $scenario',
        );
        expect(
          controller.hasDesynced,
          isTrue,
          reason: 'D1: hasDesynced stays on. $scenario',
        );
        expect(
          controller.phase,
          RoomPhase.connected,
          reason: 'D1: the socket is kept. $scenario',
        );
        expect(
          live.connector.calls,
          hasLength(1),
          reason: 'D1: no new transport. $scenario',
        );
        controller.dispose();
      });
    });

    test('a server verdict on the resume settles the future and clears '
        'isResyncing', () {
      fakeAsync((FakeAsync async) {
        const String scenario =
            'timed-out resume, resync(), error NO_SUCH_ROOM as the reply';
        final _Live live = _desyncedAfterTimeout(async);
        final RoomController controller = live.controller;

        bool settled = false;
        _resync(controller, scenario).then((_) => settled = true);
        async.flushMicrotasks();
        live.transport.pushText(
          _frame(
            type: 'error',
            re: _idOf(_resumes(live.transport).last),
            data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': 'gone'},
          ),
        );
        async.flushMicrotasks();

        expect(
          settled,
          isTrue,
          reason: 'D1: a verdict settles the future. $scenario',
        );
        expect(
          _isResyncing(controller, scenario),
          isFalse,
          reason: 'D1: isResyncing is false after a verdict. $scenario',
        );
        controller.dispose();
      });
    });

    test('on a connected, undesynced controller resync() also runs one resume '
        '(the spec conditions it on phase, room, token and nothing in '
        'flight)', () {
      fakeAsync((FakeAsync async) {
        const String scenario =
            'lobby seq 1 connected, never desynced, resync()';
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        controller.createRoom(name: 'Sam', players: 4);
        async.flushMicrotasks();
        final String id = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        transport.pushText(_frame(type: 'room', re: id, data: _roomJson()));
        async.flushMicrotasks();
        expect(
          _isResyncing(controller, scenario),
          isFalse,
          reason: 'D1: isResyncing starts false. $scenario',
        );

        _resync(controller, scenario);
        async.flushMicrotasks();
        expect(
          _resumes(transport),
          hasLength(1),
          reason:
              'D1: resync() on a connected controller runs one resume. $scenario',
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: _idOf(_resumes(transport).last),
            data: _roomJson(seq: 4),
          ),
        );
        async.flushMicrotasks();
        expect(
          _isResyncing(controller, scenario),
          isFalse,
          reason: 'D1: settled. $scenario',
        );
        controller.dispose();
      });
    });

    test('guard: reconnect() from closed opens a new transport and goes '
        'connecting (the old path resync() must reproduce)', () {
      fakeAsync((FakeAsync async) {
        final _Connector connector = _Connector();
        final FakeTransport first = FakeTransport();
        final FakeTransport second = FakeTransport();
        connector.enqueue(first);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        controller.createRoom(name: 'Sam', players: 4);
        async.flushMicrotasks();
        first.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        first.pushText(
          _frame(
            type: 'room',
            re: _idOf(first.sentRaw.last),
            data: _roomJson(),
          ),
        );
        async.flushMicrotasks();
        first.endFromFarSide();
        async.flushMicrotasks();
        expect(controller.phase, RoomPhase.closed, reason: 'fixture: closed');

        connector.enqueue(second);
        controller.reconnect();
        async.flushMicrotasks();
        expect(
          connector.calls,
          hasLength(2),
          reason: 'guard: reconnect() opens a new transport',
        );
        expect(
          controller.phase,
          RoomPhase.connecting,
          reason: 'guard: phase connecting',
        );
        expect(
          _resumes(second),
          hasLength(1),
          reason: 'guard: the new transport gets the resume',
        );
        second.pushText(
          _frame(
            type: 'room',
            re: _idOf(second.sentRaw.last),
            data: _roomJson(seq: 5),
          ),
        );
        async.flushMicrotasks();
        controller.dispose();
      });
    });

    test('resync() from closed behaves as reconnect(): a new transport, '
        'phase connecting, the resume on it', () {
      fakeAsync((FakeAsync async) {
        const String scenario = 'connected lobby, far side ends, resync()';
        final _Connector connector = _Connector();
        final FakeTransport first = FakeTransport();
        final FakeTransport second = FakeTransport();
        connector.enqueue(first);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        controller.createRoom(name: 'Sam', players: 4);
        async.flushMicrotasks();
        first.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        first.pushText(
          _frame(
            type: 'room',
            re: _idOf(first.sentRaw.last),
            data: _roomJson(),
          ),
        );
        async.flushMicrotasks();
        first.endFromFarSide();
        async.flushMicrotasks();
        expect(
          controller.phase,
          RoomPhase.closed,
          reason: 'fixture: closed. $scenario',
        );

        connector.enqueue(second);
        bool settled = false;
        _resync(controller, scenario).then((_) => settled = true);
        async.flushMicrotasks();

        expect(
          connector.calls,
          hasLength(2),
          reason: 'D1: from closed, resync() opens a new transport. $scenario',
        );
        expect(
          controller.phase,
          RoomPhase.connecting,
          reason: 'D1: from closed, resync() goes connecting. $scenario',
        );
        expect(
          _resumes(second),
          hasLength(1),
          reason: 'D1: the resume goes out on the new transport. $scenario',
        );
        second.pushText(
          _frame(
            type: 'room',
            re: _idOf(second.sentRaw.last),
            data: _roomJson(seq: 5),
          ),
        );
        async.flushMicrotasks();
        expect(
          settled,
          isTrue,
          reason: 'D1: the future completes with the reconnect. $scenario',
        );
        expect(
          controller.phase,
          RoomPhase.connected,
          reason: 'D1: reconnected. $scenario',
        );
        controller.dispose();
      });
    });

    test('resync() with no room (idle) or from failed with no room does '
        'nothing and completes at once', () {
      fakeAsync((FakeAsync async) {
        const String scenario =
            'never connected; then a connector that rejects';
        final _Connector idleConnector = _Connector();
        final RoomController idle = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: idleConnector.call,
        );
        int notified = 0;
        idle.addListener(() => notified++);
        bool settled = false;
        _resync(idle, scenario).then((_) => settled = true);
        async.flushMicrotasks();
        expect(
          settled,
          isTrue,
          reason: 'D1: idle resync() completes at once. $scenario',
        );
        expect(
          idle.phase,
          RoomPhase.idle,
          reason: 'D1: idle stays idle. $scenario',
        );
        expect(
          idleConnector.calls,
          isEmpty,
          reason: 'D1: no transport opened. $scenario',
        );
        expect(
          notified,
          0,
          reason: 'D1: nothing changed, nothing notified. $scenario',
        );
        idle.dispose();

        final _Connector failing = _Connector()
          ..rejectNextWith(Exception('boom'));
        final RoomController failed = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: failing.call,
        );
        failed.createRoom(name: 'Sam', players: 4);
        async.flushMicrotasks();
        expect(
          failed.phase,
          RoomPhase.failed,
          reason: 'fixture: failed. $scenario',
        );
        final int callsBefore = failing.calls.length;
        bool failedSettled = false;
        _resync(failed, scenario).then((_) => failedSettled = true);
        async.flushMicrotasks();
        expect(
          failedSettled,
          isTrue,
          reason:
              'D1: resync() from failed with no room completes at once. $scenario',
        );
        expect(
          failing.calls.length,
          callsBefore,
          reason: 'D1: no room to resume, so no transport. $scenario',
        );
        failed.dispose();
      });
    });
  });

  // ===========================================================================
  // D2: the lobby Resync button.
  // ===========================================================================
  group('C-555 D2: lobby-resync-button', () {
    testWidgets(
      'guard: at rest the button takes taps and its sync mark is still',
      (WidgetTester tester) async {
        const String scenario = 'lobby desynced, resume timed out, no tap';
        final _Live live = await _desyncedLobby(tester);
        expect(
          _onPressed(tester),
          isNotNull,
          reason: 'at rest the button is enabled. $scenario',
        );
        final double a = _syncAngle(tester, scenario);
        await tester.pump(const Duration(milliseconds: 100));
        final double b = _syncAngle(tester, scenario);
        expect(
          _angleGap(a, b),
          lessThan(1e-6),
          reason:
              'the mark does not turn when nothing is in flight; $a then $b. $scenario',
        );
        expect(
          live.controller.hasDesynced,
          isTrue,
          reason: 'fixture. $scenario',
        );
      },
    );

    for (final Locale locale in <Locale>[_en, _ar]) {
      testWidgets(
        '${locale.languageCode}: a tap starts the resync on the open socket; '
        'while it is out the button is disabled and the mark turns; success '
        'removes the banner',
        (WidgetTester tester) async {
          final String scenario =
              'lobby desynced (resume timed out), tap Resync, 100/300/1200 ms '
              'pumps, then room reply seq 9, locale ${locale.languageCode}';
          final _Live live = await _desyncedLobby(tester, locale: locale);

          await tester.tap(find.byKey(_resyncKey));
          await tester.pump();

          expect(
            _resumes(live.transport),
            hasLength(2),
            reason:
                'D2: a tap on lobby-resync-button must send a resume on the '
                'open transport; sent '
                '${live.transport.sentRaw.map(_typeOf).toList()}. $scenario',
          );
          expect(
            live.connector.calls,
            hasLength(1),
            reason: 'D2: no second transport. $scenario',
          );
          expect(
            _onPressed(tester),
            isNull,
            reason:
                'D2: while the resync is in flight onPressed must be null. $scenario',
          );

          final double a = _syncAngle(tester, scenario);
          await tester.pump(const Duration(milliseconds: 100));
          final double b = _syncAngle(tester, scenario);
          expect(
            _angleGap(a, b),
            greaterThan(0.05),
            reason:
                'D2: the sync mark must turn while in flight; angle $a then '
                '$b after 100 ms. $scenario',
          );
          await tester.pump(const Duration(milliseconds: 200));
          final double c = _syncAngle(tester, scenario);
          expect(
            _angleGap(a, c),
            greaterThan(0.5),
            reason:
                'D2: a quarter of the 1200 ms turn later the mark must be well '
                'away from where it was; angle $a then $c. $scenario',
          );
          await tester.pump(const Duration(milliseconds: 900));
          final double d = _syncAngle(tester, scenario);
          expect(
            _angleGap(a, d),
            lessThan(0.05),
            reason:
                'D2: one full turn is 1200 ms; after 1200 ms the angle must '
                'repeat; angle $a then $d. $scenario',
          );

          // A tap on the disabled button sends nothing.
          await tester.tap(find.byKey(_resyncKey), warnIfMissed: false);
          await tester.pump();
          expect(
            _resumes(live.transport),
            hasLength(2),
            reason: 'D2: a tap while in flight sends nothing. $scenario',
          );

          await _answerResume(tester, live);
          expect(
            live.controller.hasDesynced,
            isFalse,
            reason: 'fixture: reply clears. $scenario',
          );
          expect(
            find.byKey(_bannerKey),
            findsNothing,
            reason: 'D2: after success the banner is gone. $scenario',
          );
          expect(
            find.byKey(_resyncKey),
            findsNothing,
            reason: 'D2: and so is the button. $scenario',
          );
        },
      );
    }

    testWidgets(
      'disableAnimations: the button is disabled while in flight and the '
      'mark stays still',
      (WidgetTester tester) async {
        const String scenario =
            'lobby desynced, disableAnimations true, tap Resync, 100/1200 ms';
        final _Live live = await _desyncedLobby(
          tester,
          disableAnimations: true,
        );
        await tester.tap(find.byKey(_resyncKey));
        await tester.pump();
        expect(
          _resumes(live.transport),
          hasLength(2),
          reason: 'D2: the tap still starts the resync. $scenario',
        );
        expect(
          _onPressed(tester),
          isNull,
          reason: 'D2: disabled while in flight. $scenario',
        );
        final double a = _syncAngle(tester, scenario);
        await tester.pump(const Duration(milliseconds: 100));
        final double b = _syncAngle(tester, scenario);
        await tester.pump(const Duration(milliseconds: 1100));
        final double c = _syncAngle(tester, scenario);
        expect(
          <double>[_angleGap(a, b), _angleGap(a, c)],
          everyElement(lessThan(1e-6)),
          reason:
              'D2: with disableAnimations the mark does not turn; angles '
              '$a, $b, $c. $scenario',
        );
        await _answerResume(tester, live);
      },
    );

    testWidgets('a resync that fails without a verdict leaves the button enabled and '
        'the banner up; a second tap resyncs again', (WidgetTester tester) async {
      const String scenario =
          'lobby desynced, tap Resync, no reply for 11 s, tap again, '
          'room reply seq 9';
      final _Live live = await _desyncedLobby(tester);

      await tester.tap(find.byKey(_resyncKey));
      await tester.pump();
      expect(
        _resumes(live.transport),
        hasLength(2),
        reason: 'D2: the first tap must start a resync. $scenario',
      );
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();

      expect(
        live.controller.phase,
        RoomPhase.connected,
        reason: 'fixture: the timeout keeps the socket. $scenario',
      );
      expect(
        _onPressed(tester),
        isNotNull,
        reason:
            'D2: after a non-fatal failure the button takes taps again. $scenario',
      );
      expect(
        find.byKey(_bannerKey),
        findsOneWidget,
        reason: 'D2: the banner stays. $scenario',
      );
      final double a = _syncAngle(tester, scenario);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        _angleGap(a, _syncAngle(tester, scenario)),
        lessThan(1e-6),
        reason: 'D2: the mark stops once nothing is in flight. $scenario',
      );

      await tester.tap(find.byKey(_resyncKey));
      await tester.pump();
      expect(
        _resumes(live.transport),
        hasLength(3),
        reason: 'D2: a second tap resyncs again. $scenario',
      );
      await _answerResume(tester, live);
      expect(
        find.byKey(_bannerKey),
        findsNothing,
        reason: 'D2: success removes the banner. $scenario',
      );
    });

    testWidgets(
      'while in flight the button keeps its label, its 48 dp height and the '
      'onErrorContainer colour at 60 % opacity, not Material grey',
      (WidgetTester tester) async {
        const String scenario =
            'lobby desynced, tap Resync, read the disabled look';
        final _Live live = await _desyncedLobby(tester);
        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byKey(_resyncKey)),
        );
        final Color wanted = Theme.of(tester.element(find.byKey(_bannerKey)))
            .colorScheme
            .onErrorContainer;
        final Size atRest = tester.getSize(find.byKey(_resyncKey));

        await tester.tap(find.byKey(_resyncKey));
        await tester.pump();
        expect(
          _onPressed(tester),
          isNull,
          reason: 'D2: while in flight onPressed must be null. $scenario',
        );

        final Finder label = find.descendant(
          of: find.byKey(_resyncKey),
          matching: find.text(loc.lobbyResyncButton),
        );
        expect(
          label,
          findsOneWidget,
          reason: 'D2: the label stays "${loc.lobbyResyncButton}". $scenario',
        );
        final Finder glyph = find.descendant(
          of: label,
          matching: find.byType(RichText),
        );
        final Color? painted = tester
            .widget<RichText>(glyph.first)
            .text
            .style
            ?.color;
        expect(
          painted,
          isNotNull,
          reason: 'D2: the label has a resolved colour. $scenario',
        );
        expect(
          (painted!.r * 255).round() == (wanted.r * 255).round() &&
              (painted.g * 255).round() == (wanted.g * 255).round() &&
              (painted.b * 255).round() == (wanted.b * 255).round(),
          isTrue,
          reason:
              'D2: disabled, the label keeps the onErrorContainer colour '
              '($wanted); it is painted $painted. $scenario',
        );
        final double alpha = painted.a * _opacityOf(tester, label);
        expect(
          alpha,
          closeTo(0.6, 0.03),
          reason:
              'D2: disabled, the label is drawn at 60 % ($alpha measured). $scenario',
        );
        final Size inFlight = tester.getSize(find.byKey(_resyncKey));
        expect(
          inFlight.height,
          greaterThanOrEqualTo(48),
          reason:
              'D2: the 48 dp minimum holds while disabled; ${inFlight.height}. $scenario',
        );
        expect(
          inFlight,
          atRest,
          reason: 'D2: the button does not change size. $scenario',
        );
        await _answerResume(tester, live);
      },
    );
  });

  // ===========================================================================
  // D3: the New table guard.
  // ===========================================================================
  group('C-555 D3: New table after Play again', () {
    final List<(String, _Props)> branches = <(String, _Props)>[
      ('everyoneLeft', _alone),
      ('rematchGone', _gone),
    ];
    for (final Locale locale in <Locale>[_en, _ar]) {
      for (final (String name, _Props target) in branches) {
        testWidgets(
          '${locale.languageCode}: Play again replaced by New table ($name): '
          'ignores taps for 600 ms, fades in over 250 ms, one button always',
          (WidgetTester tester) async {
            final String scenario =
                'end card showing Play again, swapped to $name at t=0 (first '
                'frame); pumps to 100, 300, 700 ms; locale '
                '${locale.languageCode}';
            final _Card card = await _mountCard(tester, _plain, locale: locale);
            expect(
              find.byKey(_rematchKey),
              findsOneWidget,
              reason: 'fixture: Play again is up. $scenario',
            );

            card.props.value = target;
            await _pumpChecked(tester, Duration.zero, scenario);
            expect(
              find.byKey(_rematchKey),
              findsNothing,
              reason:
                  'fixture: Play again is gone in the $name frame. $scenario',
            );
            final double first = _opacityOf(tester, find.byKey(_newRoomKey));

            await _pumpChecked(
              tester,
              const Duration(milliseconds: 100),
              scenario,
            );
            final double at100 = _opacityOf(tester, find.byKey(_newRoomKey));
            await _pumpChecked(
              tester,
              const Duration(milliseconds: 200),
              scenario,
            );
            final double at300 = _opacityOf(tester, find.byKey(_newRoomKey));
            await _tapNewTable(tester);
            final int tapsAt300 = card.newTableTaps;
            await _pumpChecked(
              tester,
              const Duration(milliseconds: 400),
              scenario,
            );
            await _tapNewTable(tester);
            final int tapsAt700 = card.newTableTaps;

            expect(
              at100,
              lessThan(1.0),
              reason:
                  'D3: New table must still be fading in at 100 ms (first frame '
                  '$first, 100 ms $at100). $scenario',
            );
            expect(
              at300,
              closeTo(1.0, 1e-6),
              reason:
                  'D3: New table is fully drawn at 300 ms; $at300. $scenario',
            );
            expect(
              tapsAt300,
              0,
              reason:
                  'D3: a tap at 300 ms must not call onNewTable; calls $tapsAt300. $scenario',
            );
            expect(
              tapsAt700,
              1,
              reason:
                  'D3: a tap at 700 ms must call onNewTable once; calls $tapsAt700. $scenario',
            );
          },
        );

        testWidgets('${locale.languageCode}: disableAnimations ($name): no fade, the '
            '600 ms guard stays', (WidgetTester tester) async {
          final String scenario =
              'Play again swapped to $name with disableAnimations true; '
              'taps at 300 and 700 ms; locale ${locale.languageCode}';
          final _Card card = await _mountCard(
            tester,
            _plain,
            locale: locale,
            disableAnimations: true,
          );
          card.props.value = target;
          await _pumpChecked(tester, Duration.zero, scenario);
          final double first = _opacityOf(tester, find.byKey(_newRoomKey));
          await _pumpChecked(
            tester,
            const Duration(milliseconds: 300),
            scenario,
          );
          await _tapNewTable(tester);
          final int tapsAt300 = card.newTableTaps;
          await _pumpChecked(
            tester,
            const Duration(milliseconds: 400),
            scenario,
          );
          await _tapNewTable(tester);

          expect(
            first,
            closeTo(1.0, 1e-6),
            reason:
                'D3: no fade under disableAnimations; opacity $first on the first frame. $scenario',
          );
          expect(
            tapsAt300,
            0,
            reason:
                'D3: the guard holds under disableAnimations; calls $tapsAt300 at 300 ms. $scenario',
          );
          expect(
            card.newTableTaps,
            1,
            reason:
                'D3: a tap at 700 ms calls onNewTable once; calls ${card.newTableTaps}. $scenario',
          );
        });

        testWidgets(
          '${locale.languageCode}: a card first drawn in the $name branch has '
          'no guard and no fade',
          (WidgetTester tester) async {
            final String scenario =
                'end card mounted already in $name, tap at 50 ms, locale '
                '${locale.languageCode}';
            final _Card card = await _mountCard(tester, target, locale: locale);
            final double first = _opacityOf(tester, find.byKey(_newRoomKey));
            await _pumpChecked(
              tester,
              const Duration(milliseconds: 50),
              scenario,
            );
            await _tapNewTable(tester);
            expect(
              first,
              closeTo(1.0, 1e-6),
              reason:
                  'D3: no fade on a card that never showed Play again; opacity $first. $scenario',
            );
            expect(
              card.newTableTaps,
              1,
              reason:
                  'D3: a tap at 50 ms must call onNewTable; calls ${card.newTableTaps}. $scenario',
            );
          },
        );
      }
    }
  });

  // ===========================================================================
  // D4: the lines that come and go fade in.
  // ===========================================================================
  group('C-555 D4: lines fade in', () {
    final List<(String, Key, _Props, _Props)> lines =
        <(String, Key, _Props, _Props)>[
          ('the ask line', _askKey, _plain, _asked),
          ('the left line', _leftKey, _plain, _oneLeft),
          ('the everyone-left line', _leftKey, _plain, _alone),
          ('the gone line', _goneKey, _plain, _gone),
        ];
    for (final Locale locale in <Locale>[_en, _ar]) {
      for (final (String name, Key key, _Props before, _Props after) in lines) {
        testWidgets(
          '${locale.languageCode}: $name fades in over 200 ms when it appears '
          'on a card already up',
          (WidgetTester tester) async {
            final String scenario =
                '$name ($key) appears on a card already up; pumps 0, 50, 250 '
                'ms; locale ${locale.languageCode}';
            final _Card card = await _mountCard(tester, before, locale: locale);
            expect(
              find.byKey(key),
              findsNothing,
              reason: 'fixture: $name is not up yet. $scenario',
            );

            card.props.value = after;
            await _pumpChecked(tester, Duration.zero, scenario);
            expect(
              find.byKey(key),
              findsOneWidget,
              reason: 'fixture: $name appeared. $scenario',
            );
            await _pumpChecked(
              tester,
              const Duration(milliseconds: 50),
              scenario,
            );
            final double at50 = _opacityOf(tester, find.byKey(key));
            await _pumpChecked(
              tester,
              const Duration(milliseconds: 200),
              scenario,
            );
            final double at250 = _opacityOf(tester, find.byKey(key));

            expect(
              at50,
              lessThan(1.0),
              reason:
                  'D4: $name must still be fading at 50 ms; opacity $at50. $scenario',
            );
            expect(
              at250,
              closeTo(1.0, 1e-6),
              reason:
                  'D4: $name must be fully drawn at 250 ms; opacity $at250. $scenario',
            );
          },
        );

        testWidgets(
          '${locale.languageCode}: $name is at full opacity on the card\'s '
          'first frame',
          (WidgetTester tester) async {
            final String scenario =
                '$name ($key) present in the first frame of the card; locale '
                '${locale.languageCode}';
            await _mountCard(tester, after, locale: locale);
            expect(
              find.byKey(key),
              findsOneWidget,
              reason: 'fixture: $name is up. $scenario',
            );
            final double first = _opacityOf(tester, find.byKey(key));
            expect(
              first,
              closeTo(1.0, 1e-6),
              reason:
                  'D4: nothing fades on the first frame; $name opacity $first. $scenario',
            );
          },
        );

        testWidgets(
          '${locale.languageCode}: $name is at full opacity at once under '
          'disableAnimations',
          (WidgetTester tester) async {
            final String scenario =
                '$name ($key) appears with disableAnimations true; locale '
                '${locale.languageCode}';
            final _Card card = await _mountCard(
              tester,
              before,
              locale: locale,
              disableAnimations: true,
            );
            card.props.value = after;
            await _pumpChecked(tester, Duration.zero, scenario);
            expect(
              find.byKey(key),
              findsOneWidget,
              reason: 'fixture: $name appeared. $scenario',
            );
            final double first = _opacityOf(tester, find.byKey(key));
            expect(
              first,
              closeTo(1.0, 1e-6),
              reason:
                  'D4: no fade under disableAnimations; $name opacity $first. $scenario',
            );
          },
        );
      }
    }

    testWidgets('what leaves the card goes in the frame it goes: the ask line and Play '
        'again are gone on the swap frame, never doubled', (WidgetTester tester) async {
      const String scenario =
          'card with the ask line and Play again, swapped to everyone-left '
          'at t=0';
      final _Card card = await _mountCard(tester, _asked);
      expect(
        find.byKey(_askKey),
        findsOneWidget,
        reason: 'fixture: ask line up. $scenario',
      );
      card.props.value = _alone;
      await _pumpChecked(tester, Duration.zero, scenario);
      expect(
        find.byKey(_askKey),
        findsNothing,
        reason:
            'D4: a line that leaves does not fade out; it is gone on the swap frame. $scenario',
      );
      expect(
        find.byKey(_rematchKey),
        findsNothing,
        reason: 'D3: Play again is gone on the swap frame. $scenario',
      );
      await _pumpChecked(tester, const Duration(milliseconds: 100), scenario);
      await _pumpChecked(tester, const Duration(milliseconds: 400), scenario);
    });
  });
}
