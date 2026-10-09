// Proof of C-284: when the socket drops with a room in hand, the last
// lobby stays on screen, dimmed and inert, and one card sits over it.
// LobbyScreen is driven the same way test/reconnecting_line_test.dart's
// lobby cases and test/lobby_screen_test.dart drive it: a real
// RoomController over FakeTransport (test/net/fake_transport.dart,
// read-only here), mounted once on a fresh idle controller so initState's
// own create_room is the request that connects. One LobbyScreen mount per
// case. No pumpAndSettle (the connecting spinner never settles) and no
// bare pumpEventQueue() inside a testWidgets body.
//
// On this tree a dropped connection with a room held still shows the
// closed column, an attempt still shows the spinner, and the chrome row
// is built only while connected. Every case except the control is red
// here for that reason. The control is room == null, connecting, which
// this tree already draws as lobby-connecting.
//
// Ambiguities, reported rather than invented around:
//
//   1. "The same moment, tap the corner close" follows the attempt-in-
//      flight bullet, so the tap is taken while phase is connecting. The
//      pending-closed moment has the same corner button under rule 3.
//
//   2. "Reconnected: no wrapper, no card, Share tappable" is already true
//      of this tree once a resume lands. That case also asserts the seat
//      cards sat inside lobby-stale-room while the socket was down. That
//      expect is the line that fails here. Without it the case would be
//      green and would not be a proof of C-284.
//
//   3. "Retry given up" already shows lobby-reconnect-button on this tree
//      and wires it to controller.reconnect. The case also requires the
//      seat cards inside lobby-stale-room. That expect is the line that
//      fails here.
//
//   4. The pip strip in this tree's lobby chrome is keyed
//      game-seat-pip-strip (lobby_screen.dart), the same key GameScreen
//      uses. There is no separate lobby pip-strip key on the widget.
//
//   5. Rule 5's 360 x 640 and 800 x 600 fit matrix is not in the "What
//      proves it" list. This file does not add overflow cases for it.
//
//   6. "titleMedium" on the connection-lost line is not asserted as a
//      TextStyle. The card checks match test/game_stale_table_test.dart's
//      card helper (Material, fill, elevation, radius, max width, the
//      wifi icon) plus the connection-lost string and kSpace5 padding.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const String _roomCode = 'K7M2QP';

const List<Duration> _oneDelay = <Duration>[Duration(seconds: 1)];
const List<Duration> _twoDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

const Key _staleRoomKey = Key('lobby-stale-room');
const Key _closedKey = Key('lobby-closed');
const Key _reconnectingKey = Key('lobby-reconnecting');
const Key _reconnectButtonKey = Key('lobby-reconnect-button');
const Key _connectingKey = Key('lobby-connecting');
const Key _leaveKey = Key('lobby-leave-button');
const Key _pipKey = Key('game-seat-pip-strip');
const Key _seat0Key = Key('lobby-seat-0');
const Key _seat1Key = Key('lobby-seat-1');
const Key _shareKey = Key('lobby-share-button');
const Key _openLobbyKey = Key('open-lobby');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'lobby-stale-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

List<Map<String, Object?>> _twoSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _roomJson({int seq = 1}) => <String, Object?>{
  'code': _roomCode,
  'state': 'LOBBY',
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
  'seats': _twoSeats(),
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<Completer<WireTransport>?> _rejectQueue =
      <Completer<WireTransport>?>[];
  final List<FakeTransport?> _transportQueue = <FakeTransport?>[];
  final List<bool> _rejectFlags = <bool>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) {
    _transportQueue.add(transport);
    _rejectFlags.add(false);
    _rejectQueue.add(null);
  }

  void enqueueReject() {
    _transportQueue.add(null);
    _rejectFlags.add(true);
    _rejectQueue.add(null);
  }

  Completer<WireTransport> enqueueHold() {
    final Completer<WireTransport> completer = Completer<WireTransport>();
    _transportQueue.add(null);
    _rejectFlags.add(false);
    _rejectQueue.add(completer);
    return completer;
  }

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_transportQueue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued',
      );
    }
    final FakeTransport? transport = _transportQueue.removeAt(0);
    final bool reject = _rejectFlags.removeAt(0);
    final Completer<WireTransport>? hold = _rejectQueue.removeAt(0);
    if (reject) {
      throw StateError(
        '_Connector: connect() call #${calls.length} rejected by the test',
      );
    }
    if (hold != null) {
      return hold.future;
    }
    return transport!;
  }
}

class _PopObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

Widget _harness(
  Widget child, {
  Locale locale = const Locale('en'),
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: observers,
    home: child,
  );
}

LobbyScreen _lobby(
  RoomController controller, {
  Future<void> Function(String text)? shareText,
}) {
  return LobbyScreen(
    controller: controller,
    action: LobbyAction.create,
    playerName: 'Sam',
    players: 2,
    shareText: shareText,
  );
}

/// Mounts a fresh create lobby and returns the create_room id.
Future<String> _mountCreate(
  WidgetTester tester,
  RoomController controller,
  FakeTransport transport, {
  Future<void> Function(String text)? shareText,
}) async {
  await tester.pumpWidget(_harness(_lobby(controller, shareText: shareText)));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture is broken: LobbyScreen.initState must have sent '
        'create_room by now',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveTwoSeatLobby(
  WidgetTester tester,
  FakeTransport transport,
  String requestId,
) async {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: requestId, data: _roomJson()));
  await tester.pump();
  await tester.pump();
}

Future<(RoomController, FakeTransport, _Connector)> _connectHostLobby(
  WidgetTester tester, {
  List<Duration> autoReconnectDelays = const <Duration>[],
  Future<void> Function(String text)? shareText,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
  );
  final String createId = await _mountCreate(
    tester,
    controller,
    transport,
    shareText: shareText,
  );
  expect(_typeOf(transport.sentRaw.last), 'create_room');
  await _resolveTwoSeatLobby(tester, transport, createId);
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: 'fixture is broken: the create reply must land connected',
  );
  expect(controller.room, isNotNull);
  expect(find.byKey(_seat0Key), findsOneWidget);
  expect(find.byKey(_seat1Key), findsOneWidget);
  return (controller, transport, connector);
}

/// Rule 2's card: the keyed widget is the Material, not the old Center.
void _expectClosedCard(WidgetTester tester) {
  final Finder card = find.byKey(_closedKey);
  expect(card, findsOneWidget, reason: 'lobby-closed must be on screen');
  final Widget widget = tester.widget(card);
  expect(
    widget,
    isA<Material>(),
    reason:
        'lobby-closed must be rule 2\'s Material card, not the old '
        'Center column',
  );
  final Material material = widget as Material;
  expect(
    material.color,
    LudoColors.paperElevated,
    reason: 'the card fill is LudoColors.paperElevated',
  );
  expect(material.elevation, 6, reason: 'the card elevation is 6');
  final BorderRadiusGeometry? radius =
      material.borderRadius ??
      (material.shape is RoundedRectangleBorder
          ? (material.shape! as RoundedRectangleBorder).borderRadius
          : null);
  expect(
    radius,
    BorderRadius.circular(2 * kRadiusControl),
    reason: 'the card radius is 2 * kRadiusControl',
  );
  expect(
    tester.getSize(card).width,
    lessThanOrEqualTo(320),
    reason: 'the card\'s max width is 320; a full-bleed column is the old body',
  );
  expect(
    material.child,
    isA<Padding>(),
    reason: 'the card\'s padding is the Material\'s child',
  );
  expect(
    (material.child! as Padding).padding,
    const EdgeInsets.all(kSpace5),
    reason: 'the card padding is kSpace5',
  );
  final Finder icon = find.descendant(
    of: card,
    matching: find.byIcon(Icons.wifi_off_rounded),
  );
  expect(
    icon,
    findsOneWidget,
    reason: 'the card leads with Icons.wifi_off_rounded',
  );
  final Icon iconWidget = tester.widget<Icon>(icon);
  expect(iconWidget.size, 32);
  expect(iconWidget.color, LudoColors.inkMuted);
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(LobbyScreen)),
  );
  expect(
    find.descendant(of: card, matching: find.text(loc.lobbyConnectionLost)),
    findsOneWidget,
    reason: 'the card shows loc.lobbyConnectionLost',
  );
  expect(
    find.descendant(of: card, matching: find.byType(CircularProgressIndicator)),
    findsNothing,
    reason: 'the card has no CircularProgressIndicator',
  );
  expect(
    find.descendant(of: card, matching: find.byKey(_leaveKey)),
    findsNothing,
    reason: 'the card has no Leave button; the corner close is the way out',
  );
}

/// Rule 1: KeyedSubtree, then IgnorePointer, then ExcludeSemantics, then
/// Opacity(0.35), around the gathering. [seatRect], when set, is seat 0's
/// rect while connected; the wrapper must not move it.
void _expectStaleRoom(WidgetTester tester, {Rect? seatRect}) {
  final Finder stale = find.byKey(_staleRoomKey);
  expect(
    stale,
    findsOneWidget,
    reason:
        'a dropped connection with a room in hand must keep the lobby '
        'under lobby-stale-room',
  );
  expect(
    tester.widget(stale),
    isA<KeyedSubtree>(),
    reason: 'lobby-stale-room is the KeyedSubtree around the gathering',
  );
  expect(
    find.descendant(of: stale, matching: find.byKey(_seat0Key)),
    findsOneWidget,
    reason: 'lobby-seat-0 must sit inside the stale wrapper',
  );
  expect(
    find.descendant(of: stale, matching: find.byKey(_seat1Key)),
    findsOneWidget,
    reason: 'lobby-seat-1 must sit inside the stale wrapper',
  );
  if (seatRect != null) {
    expect(
      tester.getRect(find.byKey(_seat0Key)),
      seatRect,
      reason:
          'the wrapper adds no size: the first seat card\'s rect equals '
          'its rect before the drop',
    );
  }

  final List<Widget> chain = <Widget>[];
  tester.element(find.byKey(_seat0Key)).visitAncestorElements((
    Element ancestor,
  ) {
    chain.add(ancestor.widget);
    return ancestor.widget.key != _staleRoomKey;
  });
  final int opacityAt = chain.indexWhere((Widget w) => w is Opacity);
  final int excludeAt = chain.indexWhere((Widget w) => w is ExcludeSemantics);
  final int ignoreAt = chain.indexWhere(
    (Widget w) => w is IgnorePointer && w.ignoring,
  );
  final int keyedAt = chain.indexWhere((Widget w) => w.key == _staleRoomKey);
  expect(
    opacityAt,
    greaterThanOrEqualTo(0),
    reason: 'Opacity wraps the stale lobby',
  );
  expect(
    excludeAt,
    greaterThan(opacityAt),
    reason: 'ExcludeSemantics wraps the Opacity',
  );
  expect(
    ignoreAt,
    greaterThan(excludeAt),
    reason: 'IgnorePointer(ignoring: true) wraps the ExcludeSemantics',
  );
  expect(
    keyedAt,
    greaterThan(ignoreAt),
    reason: 'the KeyedSubtree is the outer wrapper',
  );
  expect((chain[opacityAt] as Opacity).opacity, 0.35);
  expect((chain[excludeAt] as ExcludeSemantics).excluding, isTrue);

  expect(
    find.descendant(of: stale, matching: find.byKey(_closedKey)),
    findsNothing,
    reason: 'the card sits over the wrapper, not inside it',
  );
  expect(
    find.descendant(of: stale, matching: find.byKey(_pipKey)),
    findsNothing,
    reason: 'the pip strip stays outside the stale wrapper',
  );
  expect(
    find.descendant(of: stale, matching: find.byKey(_leaveKey)),
    findsNothing,
    reason: 'the corner close stays outside the stale wrapper',
  );
}

/// Rule 2a: while a retry is pending or in flight, the card shows the
/// reconnecting line and no Reconnect button.
void _expectRetryingLine(WidgetTester tester) {
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(LobbyScreen)),
  );
  final Finder line = find.byKey(_reconnectingKey);
  expect(
    line,
    findsOneWidget,
    reason: 'lobby-reconnecting must be on screen while retrying',
  );
  expect(
    tester.widget(line),
    isA<Text>(),
    reason: 'lobby-reconnecting is the key on the Text, not on the row',
  );
  expect(tester.widget<Text>(line).data, loc.lobbyReconnecting);
  final Finder sync = find.descendant(
    of: find.byKey(_closedKey),
    matching: find.byIcon(Icons.sync_rounded),
  );
  expect(
    sync,
    findsOneWidget,
    reason: 'the retrying card shows Icons.sync_rounded beside the line',
  );
  expect(tester.widget<Icon>(sync).size, 18);
  expect(
    find.byKey(_reconnectButtonKey),
    findsNothing,
    reason:
        'the Reconnect button is absent while a retry is still pending '
        'or in flight',
  );
}

void _expectChromeOutside(WidgetTester tester) {
  expect(
    find.byKey(_pipKey),
    findsOneWidget,
    reason: 'the pip strip stays on screen while the room is stale',
  );
  final Finder leave = find.byKey(_leaveKey);
  expect(
    leave,
    findsOneWidget,
    reason: 'the corner lobby-leave-button stays on screen while stale',
  );
  expect(
    tester.widget(leave),
    isA<IconButton>(),
    reason: 'the corner close is an IconButton, not the column\'s button',
  );
  final IconButton button = tester.widget<IconButton>(leave);
  expect(button.onPressed, isNotNull);
  expect((button.icon as Icon).icon, Icons.close);
}

void main() {
  // ==========================================================================
  // Dropped, retry still pending: the lobby stays, the card has the line
  // and no Reconnect button, and the chrome does not move the seats.
  // ==========================================================================
  testWidgets(
    'a dropped socket keeps both seat cards inside lobby-stale-room at '
    'the same rect, under the lobby-closed card, with the reconnecting '
    'line, no reconnect button, and the pip strip and corner close '
    'outside the wrapper',
    (tester) async {
      final (controller, transport, _) = await _connectHostLobby(
        tester,
        autoReconnectDelays: _oneDelay,
      );
      try {
        final Rect seatBefore = tester.getRect(find.byKey(_seat0Key));

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();

        expect(controller.phase, RoomPhase.closed);
        expect(
          controller.autoReconnectPending,
          isTrue,
          reason:
              'fixture is broken: the scheduled attempt must still be '
              'waiting',
        );
        expect(controller.room, isNotNull);

        _expectStaleRoom(tester, seatRect: seatBefore);
        _expectClosedCard(tester);
        _expectRetryingLine(tester);
        _expectChromeOutside(tester);
        expect(find.byKey(_connectingKey), findsNothing);
      } finally {
        controller.dispose();
      }
    },
  );

  // ==========================================================================
  // The attempt itself (phase connecting): the screen does not flip to
  // the spinner.
  // ==========================================================================
  testWidgets(
    'an automatic attempt in flight keeps the same card and reconnecting '
    'line, with no lobby-connecting and no spinner, and the seats still '
    'inside the stale wrapper',
    (tester) async {
      final (controller, transport, connector) = await _connectHostLobby(
        tester,
        autoReconnectDelays: _oneDelay,
      );
      final Rect seatBefore = tester.getRect(find.byKey(_seat0Key));
      final Completer<WireTransport> hold = connector.enqueueHold();
      try {
        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(controller.phase, RoomPhase.closed);

        await tester.pump(_oneDelay[0]);
        await tester.pump();
        await tester.pump();

        expect(
          controller.phase,
          RoomPhase.connecting,
          reason:
              'fixture is broken: the timer firing into a held connector '
              'must leave the phase at connecting',
        );
        expect(
          find.byKey(_closedKey),
          findsOneWidget,
          reason:
              'the lobby-closed card stays while the attempt is in flight; '
              'the old screen drops it and shows the spinner',
        );
        expect(
          find.byKey(_connectingKey),
          findsNothing,
          reason: 'lobby-connecting is not shown while a room is held',
        );
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: 'an attempt with a room held shows no spinner',
        );
        _expectStaleRoom(tester, seatRect: seatBefore);
        _expectClosedCard(tester);
        _expectRetryingLine(tester);
      } finally {
        if (!hold.isCompleted) {
          hold.complete(FakeTransport());
        }
        await tester.pump();
        controller.dispose();
      }
    },
  );

  // ==========================================================================
  // The same moment (phase connecting): the corner close pops the route.
  // See header ambiguity 1.
  // ==========================================================================
  testWidgets('while an automatic attempt is in flight, tapping the corner '
      'lobby-leave-button pops the lobby route', (tester) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
      autoReconnectDelays: _oneDelay,
    );
    final _PopObserver observer = _PopObserver();
    Completer<WireTransport>? hold;

    try {
      await tester.pumpWidget(
        _harness(
          Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    key: _openLobbyKey,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _lobby(controller),
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              );
            },
          ),
          observers: <NavigatorObserver>[observer],
        ),
      );

      await tester.tap(find.byKey(_openLobbyKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        transport.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: the pushed lobby must have sent create',
      );
      final String createId = _idOf(transport.sentRaw.last);
      await _resolveTwoSeatLobby(tester, transport, createId);
      expect(controller.phase, RoomPhase.connected);

      hold = connector.enqueueHold();
      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);

      await tester.pump(_oneDelay[0]);
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.connecting,
        reason:
            'fixture is broken: the held attempt must leave the phase '
            'at connecting',
      );

      final Finder leave = find.byKey(_leaveKey);
      expect(
        leave,
        findsOneWidget,
        reason:
            'the corner lobby-leave-button must stay on screen while '
            'the attempt is in flight',
      );
      expect(
        tester.widget(leave),
        isA<IconButton>(),
        reason: 'the corner close is an IconButton',
      );
      expect(
        find.descendant(of: find.byKey(_staleRoomKey), matching: leave),
        findsNothing,
        reason: 'the corner close is outside the stale wrapper, so it taps',
      );

      await tester.tap(leave);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        observer.popCount,
        1,
        reason:
            'tapping the corner close while the attempt is in flight '
            'must pop the lobby route; didPop count was ${observer.popCount}',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'after the corner close, LobbyScreen must be gone',
      );
      expect(find.byKey(_openLobbyKey), findsOneWidget);
    } finally {
      controller.dispose();
      final Completer<WireTransport>? pending = hold;
      if (pending != null && !pending.isCompleted) {
        pending.complete(FakeTransport());
      }
    }
  });

  // ==========================================================================
  // Retry given up. The button is present and calls reconnect. See header
  // ambiguity 3 for why the wrapper is asserted first.
  // ==========================================================================
  testWidgets('once the automatic schedule is exhausted, the seats stay inside '
      'lobby-stale-room and tapping lobby-reconnect-button opens exactly '
      'one new transport whose first frame is resume', (tester) async {
    final (controller, transport, connector) = await _connectHostLobby(
      tester,
      autoReconnectDelays: _twoDelays,
    );
    connector.enqueueReject();
    connector.enqueueReject();

    try {
      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);

      await tester.pump(_twoDelays[0]);
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason: 'fixture is broken: one retry remains after the first failure',
      );

      await tester.pump(_twoDelays[1]);
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.autoReconnectPending,
        isFalse,
        reason: 'fixture is broken: both scheduled attempts have failed',
      );
      expect(controller.room, isNotNull);
      expect(controller.errorCode, 'transport');

      _expectStaleRoom(tester);
      _expectClosedCard(tester);
      expect(
        find.byKey(_reconnectingKey),
        findsNothing,
        reason: 'the reconnecting line is gone once the schedule is exhausted',
      );
      expect(
        find.byKey(_reconnectButtonKey),
        findsOneWidget,
        reason:
            'the Reconnect button is present once the schedule is exhausted',
      );

      final FakeTransport resumeTransport = FakeTransport();
      connector.enqueue(resumeTransport);
      final int callsBefore = connector.calls.length;

      await tester.tap(find.byKey(_reconnectButtonKey));
      await tester.pump();
      await tester.pump();

      expect(
        connector.calls.length,
        callsBefore + 1,
        reason:
            'tapping lobby-reconnect-button must call reconnect(), which '
            'opens exactly one new transport',
      );
      expect(
        resumeTransport.sentRaw,
        isNotEmpty,
        reason: 'the reconnect tap must have sent resume',
      );
      expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
      final Map<String, Object?> sent = _dataOf(resumeTransport.sentRaw.last);
      expect(sent['code'], _roomCode);
      expect(sent['seat_token'], 'tok-0');

      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: _idOf(resumeTransport.sentRaw.last),
          data: _roomJson(),
        ),
      );
      await tester.pump();
      await tester.pump();
    } finally {
      controller.dispose();
    }
  });

  // ==========================================================================
  // Frames back: the wrapper and the card are gone, and Share is tappable.
  // See header ambiguity 2 for why the drop is asserted first.
  // ==========================================================================
  testWidgets(
    'once the resume lands, the stale wrapper and the card are gone and '
    'lobby-share-button is tappable',
    (tester) async {
      final List<String> shared = <String>[];
      final (controller, transport, connector) = await _connectHostLobby(
        tester,
        autoReconnectDelays: _oneDelay,
        shareText: (String text) async {
          shared.add(text);
        },
      );
      final FakeTransport resumeTransport = FakeTransport();
      connector.enqueue(resumeTransport);

      try {
        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(controller.phase, RoomPhase.closed);
        expect(
          find.descendant(
            of: find.byKey(_staleRoomKey),
            matching: find.byKey(_seat0Key),
          ),
          findsOneWidget,
          reason:
              'while the socket is down the seat cards must be inside '
              'lobby-stale-room, so the resume below is a return from that '
              'lobby and not from a wiped column',
        );
        expect(
          find.descendant(
            of: find.byKey(_staleRoomKey),
            matching: find.byKey(_seat1Key),
          ),
          findsOneWidget,
        );

        await tester.pump(_oneDelay[0]);
        await tester.pump();
        await tester.pump();
        expect(
          resumeTransport.sentRaw,
          isNotEmpty,
          reason: 'fixture is broken: the automatic attempt must send resume',
        );
        expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
        expect(_dataOf(resumeTransport.sentRaw.last)['seat_token'], 'tok-0');
        resumeTransport.pushText(
          _frame(
            type: 'room',
            re: _idOf(resumeTransport.sentRaw.last),
            data: _roomJson(),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.phase, RoomPhase.connected);
        expect(
          find.byKey(_staleRoomKey),
          findsNothing,
          reason: 'the stale wrapper is gone once the phase is connected again',
        );
        expect(
          find.byKey(_closedKey),
          findsNothing,
          reason: 'the lobby-closed card is gone once the phase is connected',
        );
        expect(find.byKey(_connectingKey), findsNothing);

        final Finder share = find.byKey(_shareKey);
        expect(share, findsOneWidget, reason: 'lobby-share-button is back');
        final ButtonStyleButton shareButton = tester.widget<ButtonStyleButton>(
          share,
        );
        expect(
          shareButton.onPressed,
          isNotNull,
          reason: 'lobby-share-button is tappable once the lobby is back',
        );
        await tester.tap(share);
        expect(
          shared,
          hasLength(1),
          reason: 'tapping lobby-share-button must call the share handler',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  // ==========================================================================
  // Control: no room yet. Today's connecting body. Green on this tree.
  // ==========================================================================
  testWidgets(
    'control: with room null and phase connecting, lobby-connecting is '
    'shown and lobby-stale-room is absent',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
      );

      try {
        await _mountCreate(tester, controller, transport);

        expect(
          controller.phase,
          anyOf(RoomPhase.idle, RoomPhase.connecting),
          reason:
              'fixture is broken: the create request must still be in flight',
        );
        expect(
          controller.room,
          isNull,
          reason: 'fixture is broken: no room snapshot has arrived',
        );

        expect(
          find.byKey(_connectingKey),
          findsOneWidget,
          reason: 'room == null, connecting, keeps today\'s lobby-connecting',
        );
        expect(
          find.descendant(
            of: find.byKey(_connectingKey),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
          reason: 'today\'s connecting body still contains the spinner',
        );
        expect(
          find.byKey(_staleRoomKey),
          findsNothing,
          reason: 'there is no gathering to keep when room is null',
        );
        expect(find.byKey(_closedKey), findsNothing);
      } finally {
        controller.dispose();
      }
    },
  );
}
