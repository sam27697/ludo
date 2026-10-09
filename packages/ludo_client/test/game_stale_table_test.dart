// Proof of C-282: when the socket drops with a room in hand, the last
// table stays on screen, dimmed and inert, and one card sits over it.
// GameScreen is driven the same way test/game_screen_connection_lost_test.dart
// and test/reconnecting_line_test.dart drive it: a real RoomController over
// FakeTransport (test/net/fake_transport.dart, read-only here), one
// GameScreen mount per case. No pumpAndSettle (the countdown ticker never
// settles) and no bare pumpEventQueue() inside a testWidgets body.
//
// On this tree a dropped connection still wipes the board for a column of
// text and two buttons, and an attempt still shows the board under
// game-screen-reconnecting-banner. Every case except the control is red
// here for that reason. The control is the given-up reconnect button,
// which this tree already wires to controller.reconnect.
//
// Ambiguities, reported rather than invented around:
//
//   1. "Reconnected: no wrapper, no card, a legal token tap sends move" is
//      already true of this tree once a resume lands. That case also
//      asserts the board sat inside game-screen-stale-table while the
//      socket was down. That expect is the line that fails here. Without
//      it the case would be green and would not be a proof of C-282.
//
//   2. "room == null, failed: the card present, no wrapper." The key
//      game-screen-connection-lost is already on the old Center column,
//      and no stale wrapper exists, so those two expects alone are green
//      here. The case requires the keyed widget to be rule 2's Material
//      card. That type check is the line that fails here.
//
//   3. Rule 2d keys game-screen-reconnecting on the row of the sync icon
//      and lobbyReconnecting. The sync icon is found inside the card. The
//      line's text is read off the keyed widget when that widget is a
//      Text, and off the Text inside it otherwise.
//
//   4. "radius 2 * kRadiusControl" can be Material.borderRadius or the
//      borderRadius of a RoundedRectangleBorder shape. Either matches.
//
//   5. RoomController.move sends nothing when phase is not connected, so
//      a tap that reached the board would also send nothing. The tap case
//      requires the token inside the stale wrapper, and an
//      IgnorePointer(ignoring: true) ancestor of the board, which is what
//      rule 1 names.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const List<Duration> _oneDelay = <Duration>[Duration(seconds: 1)];
const List<Duration> _twoDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

const Key _staleTableKey = Key('game-screen-stale-table');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _reconnectingKey = Key('game-screen-reconnecting');
const Key _reconnectingBannerKey = Key('game-screen-reconnecting-banner');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');
const Key _boardKey = Key('game-screen-board');
const Key _dieKey = Key('game-die');
const Key _tokenHitKey = Key('board-token-hit-0-1');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'stale-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int seq = 1,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
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

Future<(RoomController, FakeTransport, _Connector)> _connectPlaying(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  required Map<String, Object?> turn,
  List<Duration> autoReconnectDelays = const <Duration>[],
  int seq = 1,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
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
      data: _roomJson(seats: seats, turn: turn, seq: seq),
    ),
  );
  await future;
  return (controller, transport, connector);
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
}

List<Map<String, Object?>> _twoSeats({
  List<int>? seat0Tokens,
}) => <Map<String, Object?>>[
  _seatJson(0, name: 'Sam', tokens: seat0Tokens ?? const <int>[-1, -1, -1, -1]),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _awaitRollTurn() =>
    _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0);

Map<String, Object?> _awaitMoveTurn() => _turnJson(
  seat: 0,
  phase: 'await_move',
  deadlineMs: 45000,
  k: 1,
  value: 4,
  legal: const <int>[1, 3],
);

/// Rule 2's card: the keyed widget is the Material, not the old Center.
void _expectConnectionLostCard(WidgetTester tester) {
  final Finder card = find.byKey(_connectionLostKey);
  expect(
    card,
    findsOneWidget,
    reason: 'game-screen-connection-lost must be on screen',
  );
  final Widget widget = tester.widget(card);
  expect(
    widget,
    isA<Material>(),
    reason:
        'game-screen-connection-lost must be rule 2\'s Material card, '
        'not the old Center column',
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
  expect(
    find.descendant(of: card, matching: find.byType(CircularProgressIndicator)),
    findsNothing,
    reason: 'the card has no CircularProgressIndicator',
  );
}

/// Rule 1: KeyedSubtree, then IgnorePointer, then ExcludeSemantics, then
/// Opacity(0.35), around the playing body. [boardRect], when set, is the
/// board's rect while connected; the wrapper must not move it.
void _expectStaleTable(WidgetTester tester, {Rect? boardRect}) {
  final Finder stale = find.byKey(_staleTableKey);
  expect(
    stale,
    findsOneWidget,
    reason:
        'a dropped connection with a room in hand must keep the table '
        'under game-screen-stale-table',
  );
  expect(
    tester.widget(stale),
    isA<KeyedSubtree>(),
    reason: 'game-screen-stale-table is the KeyedSubtree around the table',
  );
  final Finder board = find.byKey(_boardKey);
  expect(
    find.descendant(of: stale, matching: board),
    findsOneWidget,
    reason: 'game-screen-board must sit inside the stale wrapper',
  );
  expect(
    find.descendant(of: stale, matching: find.byKey(_dieKey)),
    findsOneWidget,
    reason:
        'the wrapper holds the playing body, so the die stays inside it '
        'rather than being wiped with the board',
  );
  if (boardRect != null) {
    expect(
      tester.getRect(board),
      boardRect,
      reason:
          'the wrapper adds no size: the board\'s rect equals its rect '
          'while connected',
    );
  }

  final List<Widget> chain = <Widget>[];
  tester.element(board).visitAncestorElements((Element ancestor) {
    chain.add(ancestor.widget);
    return ancestor.widget.key != _staleTableKey;
  });
  final int opacityAt = chain.indexWhere((Widget w) => w is Opacity);
  final int excludeAt = chain.indexWhere((Widget w) => w is ExcludeSemantics);
  final int ignoreAt = chain.indexWhere(
    (Widget w) => w is IgnorePointer && w.ignoring,
  );
  final int keyedAt = chain.indexWhere((Widget w) => w.key == _staleTableKey);
  expect(
    opacityAt,
    greaterThanOrEqualTo(0),
    reason: 'Opacity wraps the stale table',
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
}

String? _reconnectingText(WidgetTester tester) {
  final Finder line = find.byKey(_reconnectingKey);
  expect(
    line,
    findsOneWidget,
    reason: 'game-screen-reconnecting must be on screen while retrying',
  );
  final Widget widget = tester.widget(line);
  if (widget is Text) {
    return widget.data;
  }
  final Finder text = find.descendant(of: line, matching: find.byType(Text));
  expect(
    text,
    findsOneWidget,
    reason:
        'game-screen-reconnecting must carry the reconnecting text, '
        'whether the key sits on that Text or on the row around it',
  );
  return tester.widget<Text>(text).data;
}

/// Rule 2d: while a retry is pending or in flight, the card shows the
/// reconnecting line and no Reconnect button.
void _expectRetryingLine(WidgetTester tester) {
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(GameScreen)),
  );
  expect(_reconnectingText(tester), loc.lobbyReconnecting);
  expect(
    find.descendant(
      of: find.byKey(_connectionLostKey),
      matching: find.byIcon(Icons.sync_rounded),
    ),
    findsOneWidget,
    reason: 'the retrying card shows Icons.sync_rounded beside the line',
  );
  final Icon sync = tester.widget<Icon>(
    find.descendant(
      of: find.byKey(_connectionLostKey),
      matching: find.byIcon(Icons.sync_rounded),
    ),
  );
  expect(sync.size, 18);
  expect(
    find.byKey(_reconnectButtonKey),
    findsNothing,
    reason:
        'the Reconnect button is absent while a retry is still pending '
        'or in flight',
  );
  expect(
    find.byKey(_reconnectingBannerKey),
    findsNothing,
    reason: 'game-screen-reconnecting-banner is gone',
  );
}

void _settleMove(FakeTransport transport, String moveId, {required int seq}) {
  transport.pushText(
    _frame(
      type: 'moved',
      re: moveId,
      data: <String, Object?>{
        'seat': 0,
        'token': 1,
        'from': 10,
        'to': 14,
        'captured': <Object?>[],
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
}

void main() {
  final List<Map<String, Object?>> rollSeats = _twoSeats();
  final List<Map<String, Object?>> moveSeats = _twoSeats(
    seat0Tokens: const <int>[3, 10, 20, 30],
  );

  // ==========================================================================
  // Dropped, retry still pending: the table stays, the card has the line
  // and no Reconnect button.
  // ==========================================================================
  testWidgets(
    'a dropped socket keeps the board inside game-screen-stale-table at '
    'the same rect, under the connection-lost card, with the reconnecting '
    'line and no reconnect button',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        seats: rollSeats,
        turn: _awaitRollTurn(),
        autoReconnectDelays: _oneDelay,
      );
      await _mount(tester, controller);
      final Rect boardBefore = tester.getRect(find.byKey(_boardKey));

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();

      expect(controller.phase, RoomPhase.closed);
      expect(
        controller.autoReconnectPending,
        isTrue,
        reason:
            'fixture is broken: the scheduled attempt must still be waiting',
      );
      expect(controller.room, isNotNull);

      _expectStaleTable(tester, boardRect: boardBefore);
      _expectConnectionLostCard(tester);
      _expectRetryingLine(tester);

      controller.dispose();
    },
  );

  // ==========================================================================
  // The same moment: a tap on a legal token sends nothing.
  // ==========================================================================
  testWidgets(
    'a tap on a board token while the dropped socket is still retrying '
    'sends nothing',
    (tester) async {
      final (controller, transport, _) = await _connectPlaying(
        tester,
        seats: moveSeats,
        turn: _awaitMoveTurn(),
        autoReconnectDelays: _oneDelay,
      );
      await _mount(tester, controller);

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.autoReconnectPending, isTrue);

      expect(
        find.descendant(
          of: find.byKey(_staleTableKey),
          matching: find.byKey(_tokenHitKey),
        ),
        findsOneWidget,
        reason:
            'board-token-hit-0-1 must still be inside the stale table, '
            'so the tap has a token to miss',
      );

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_tokenHitKey), warnIfMissed: false);
      await tester.pump();

      expect(
        transport.sentRaw.length,
        sentBefore,
        reason:
            'a token tap while the table is stale must send nothing; '
            'sent ${transport.sentRaw.length - sentBefore} further frame(s)',
      );

      controller.dispose();
    },
  );

  // ==========================================================================
  // The attempt itself (phase connecting): the screen does not flip.
  // ==========================================================================
  testWidgets(
    'an automatic attempt in flight keeps the same card and reconnecting '
    'line, with no reconnecting banner, and the board still inside the '
    'stale wrapper',
    (tester) async {
      final (controller, transport, connector) = await _connectPlaying(
        tester,
        seats: rollSeats,
        turn: _awaitRollTurn(),
        autoReconnectDelays: _oneDelay,
      );
      await _mount(tester, controller);
      final Rect boardBefore = tester.getRect(find.byKey(_boardKey));
      final Completer<WireTransport> hold = connector.enqueueHold();

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
        find.byKey(_connectionLostKey),
        findsOneWidget,
        reason:
            'the connection-lost card stays while the attempt is in '
            'flight; the old screen drops it and shows the banner',
      );
      _expectStaleTable(tester, boardRect: boardBefore);
      _expectConnectionLostCard(tester);
      _expectRetryingLine(tester);

      hold.complete(FakeTransport());
      await tester.pump();
      controller.dispose();
    },
  );

  // ==========================================================================
  // Control: retries given up. The button is present and calls reconnect.
  // This is green on the old screen, which already shows the button and
  // wires it to controller.reconnect.
  // ==========================================================================
  testWidgets('control: once the automatic schedule is exhausted, '
      'game-screen-reconnect-button is present and tapping it opens exactly '
      'one new transport', (tester) async {
    final (controller, transport, connector) = await _connectPlaying(
      tester,
      seats: rollSeats,
      turn: _awaitRollTurn(),
      autoReconnectDelays: _twoDelays,
    );
    connector.enqueueReject();
    connector.enqueueReject();
    await _mount(tester, controller);

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

    final FakeTransport resumeTransport = FakeTransport();
    connector.enqueue(resumeTransport);
    final int callsBefore = connector.calls.length;

    expect(
      find.byKey(_reconnectButtonKey),
      findsOneWidget,
      reason: 'the Reconnect button is present once the schedule is exhausted',
    );
    await tester.tap(find.byKey(_reconnectButtonKey));
    await tester.pump();
    await tester.pump();

    expect(
      connector.calls.length,
      callsBefore + 1,
      reason:
          'tapping game-screen-reconnect-button must call reconnect(), '
          'which opens exactly one new transport',
    );
    expect(
      resumeTransport.sentRaw,
      isNotEmpty,
      reason: 'the reconnect tap must have sent resume',
    );
    expect(_typeOf(resumeTransport.sentRaw.last), 'resume');
    final Map<String, Object?> sent = _dataOf(resumeTransport.sentRaw.last);
    expect(sent['code'], 'K7M2QP');
    expect(sent['seat_token'], 'tok-0');

    resumeTransport.pushText(
      _frame(
        type: 'room',
        re: _idOf(resumeTransport.sentRaw.last),
        data: _roomJson(seats: rollSeats, turn: _awaitRollTurn(), seq: 1),
      ),
    );
    await tester.pump();
    await tester.pump();

    controller.dispose();
  });

  // ==========================================================================
  // Frames back: the wrapper and the card are gone, and a legal tap sends
  // move. See header ambiguity 1 for why the drop is asserted first.
  // ==========================================================================
  testWidgets(
    'once the resume lands, the stale wrapper and the card are gone and '
    'a legal token tap sends move',
    (tester) async {
      final (controller, transport, connector) = await _connectPlaying(
        tester,
        seats: moveSeats,
        turn: _awaitMoveTurn(),
        autoReconnectDelays: _oneDelay,
      );
      final FakeTransport resumeTransport = FakeTransport();
      connector.enqueue(resumeTransport);
      await _mount(tester, controller);

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed);
      expect(
        find.descendant(
          of: find.byKey(_staleTableKey),
          matching: find.byKey(_boardKey),
        ),
        findsOneWidget,
        reason:
            'while the socket is down the board must be inside '
            'game-screen-stale-table, so the resume below is a return '
            'from that table and not from a wiped column',
      );

      await tester.pump(_oneDelay[0]);
      await tester.pump();
      await tester.pump();
      expect(
        resumeTransport.sentRaw,
        isNotEmpty,
        reason: 'fixture is broken: the automatic attempt must send resume',
      );
      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: _idOf(resumeTransport.sentRaw.last),
          data: _roomJson(seats: moveSeats, turn: _awaitMoveTurn(), seq: 1),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.phase, RoomPhase.connected);
      expect(
        find.byKey(_staleTableKey),
        findsNothing,
        reason: 'the stale wrapper is gone once the phase is connected again',
      );
      expect(
        find.byKey(_connectionLostKey),
        findsNothing,
        reason: 'the connection-lost card is gone once the phase is connected',
      );
      expect(find.byKey(_reconnectingBannerKey), findsNothing);
      expect(find.byKey(_boardKey), findsOneWidget);

      final int sentBefore = resumeTransport.sentRaw.length;
      await tester.tap(find.byKey(_tokenHitKey));
      await tester.pump();

      final List<String> sent = resumeTransport.sentRaw
          .skip(sentBefore)
          .toList();
      expect(
        sent,
        hasLength(1),
        reason: 'a legal token tap on the restored board must send one move',
      );
      expect(_typeOf(sent.single), 'move');
      expect(_dataOf(sent.single)['token'], 1);

      _settleMove(resumeTransport, _idOf(sent.single), seq: 2);
      await tester.pump();
      await tester.pump();

      controller.dispose();
    },
  );

  // ==========================================================================
  // No room yet. See header ambiguity 2.
  // ==========================================================================
  testWidgets(
    'with room null and phase failed, the connection-lost card is shown '
    'and game-screen-stale-table is absent',
    (tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
      );

      final Future<void> future = controller.createRoom(
        name: 'Sam',
        players: 2,
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final String id = _idOf(transport.sentRaw.last);
      transport.pushText(
        _frame(
          type: 'error',
          re: id,
          data: <String, Object?>{'code': 'SERVER_GONE', 'message': 'gone'},
        ),
      );
      await future;
      await tester.pump();

      expect(controller.phase, RoomPhase.failed);
      expect(
        controller.room,
        isNull,
        reason: 'fixture is broken: create failed before any room snapshot',
      );

      await _mount(tester, controller);

      _expectConnectionLostCard(tester);
      expect(
        find.byKey(_staleTableKey),
        findsNothing,
        reason: 'there is no table to keep when room is null',
      );

      controller.dispose();
    },
  );
}
