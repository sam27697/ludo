// Proof for contract C-637 / C-638
// (work/ludo/orders/637-lost-seat-table.md), written from the contract alone:
// once this phone no longer holds its seat (seatTakenOver, the game screen's
// refused seat, a room gone while playing), nothing it draws says it can act
// or that it is its turn, and nothing it sends can act for that seat. A plain
// dropped connection is not this: the seat is still mine and "Your turn"
// stays true (C-282, C-290).
//
// The rigs are copied from test/c547_controller_test.dart (a real
// RoomController over FakeTransport behind a connector double), test/c547_test.dart
// (a create lobby pushed over a host page), test/c540_test.dart (the real
// HomeScreen, RoomRoute and GameScreen, a fresh transport per connect) and
// the shared test/support/roll_tray_harness.dart (GameScreen over a real
// controller, every room state a decoded wire frame). Nothing is imported
// from another test file.
//
// Cases (an id that starts with "guard" is green on the base tree on purpose:
// it pins what must not change, or proves the probe can see what the red
// cases say is absent):
//   D1.*       the takeover frame closes the connection at once: no listener
//              ever sees (connected, seatTakenOver), the transport saw a
//              client close, a later done changes no field and starts no
//              reconnect; replayed and bursted frames; other unsolicited
//              errors and replies do not close.
//   D2.*       reconnect(), resync(), reconnectAndRematch() open nothing and
//              send nothing while seatTakenOver is true.
//   D3.*       a takeover clears hasDesynced and isResyncing and a resync
//              reply behind it changes nothing.
//   D4.*       lobby: no desync strip, no Resync, no seat pip strip under a
//              takeover or an update card; the corner close and the sound
//              switch stay.
//   D5.*       game screen, en and ar: no header row, no countdown, no pip
//              strip, no ring, no pulse, no glow, no hint, no "you're next",
//              the board does not move; nothing sent; the auto-move hold
//              sends nothing.
//   D5.refused / D5.gone   the same absences through the frames of the pop
//              for a refused seat (C-540) and a room gone mid-game (C-529).
//   D6.*       game screen: no desync strip.
//   D7.*       the face picker closes, nothing sent, no cue.
//   guard.*    a plain drop on my turn still reads gameYourTurnStale with
//              its countdown block.
//
// There is no random input. Each failure reason names the case, what was
// expected and what was seen, and ends with the command that replays that
// one case:
//   flutter test test/c637_lost_seat_test.dart --plain-name '<id>'
//
// Ambiguity, reported: the order's D5 test line asks for "a 3-seat table where
// I am also next" with my own turn. At a table of three the seat that is next
// is never the seat on turn, so the two are separate fixtures here: my turn
// (roll and move), and seat 2 on turn with me next (the "you're next" line).
// The order's "no frame was scheduled by the countdown" is asserted through
// debugPrintRebuildDirtyWidgets: a ticking countdown rebuilds its digits and
// ring (a ValueListenableBuilder<int>) once a second, and guard.D5.ticks proves
// the probe sees that on a live table. Whether the screen's timer is cancelled
// (D5 b) when nothing listens to it has no hook a test can read, so only what
// the timer would draw is asserted.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/die_mark.dart' show SeatPipStrip;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomSnapshot;
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const String _testUrl = 'wss://c637-test.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c637-001';
const String _gameId = '7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

const Key _headerChipKey = Key('game-header-chip');
const Key _headerChipDotKey = Key('game-header-chip-dot');
const Key _turnBannerKey = Key('game-screen-turn-banner');
const Key _countdownDigitsKey = Key('game-screen-turn-countdown');
const Key _countdownRingKey = Key('game-header-countdown-ring');
const Key _countdownSemanticsKey = Key('game-header-countdown-semantics');
const Key _countdownWarningKey = Key('game-header-countdown-warning');
const Key _pipStripKey = Key('game-seat-pip-strip');
const Key _diePulseKey = Key('game-die-pulse');
const Key _gameDesyncKey = Key('game-screen-desync-banner');
const Key _lobbyDesyncKey = Key('lobby-desync-banner');
const Key _lobbyResyncKey = Key('lobby-resync-button');
const Key _lobbyLeaveKey = Key('lobby-leave-button');
const Key _lobbySoundKey = Key('lobby-sound-toggle');
const Key _lobbySeatMovedLeaveKey = Key('lobby-seat-moved-leave');
const Key _openLobbyKey = Key('c637-open-lobby');
const Key _gameReconnectKey = Key('game-screen-reconnect-button');
const Key _staleTableKey = Key('game-screen-stale-table');

String _reproduce(String id) =>
    'reproduce: flutter test test/c637_lost_seat_test.dart '
    '--plain-name "$id"';

String _why(String id, String expected, String saw) =>
    '$id: expected $expected; saw $saw. ${_reproduce(id)}';

// ---------------------------------------------------------------- frames

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c637-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

/// What the server sends before it closes a displaced socket with 4004: an
/// `error` with no `re`.
String _takeoverFrame([Object? code = 'BAD_SEAT_TOKEN']) => _frame(
  type: 'error',
  data: <String, Object?>{'code': ?code, 'message': 'taken over'},
);

String _updateFrame() => _frame(
  type: 'error',
  data: <String, Object?>{
    'code': 'UPDATE_REQUIRED',
    'message': 'x',
    'min_build': 600,
  },
);

/// The seq gap: a presence frame far ahead of any room the cases hold.
String _gapFrame() => _frame(
  type: 'presence',
  data: <String, Object?>{'seat': 1, 'connected': false, 'seq': 999},
);

Map<String, Object?> _roomJson({
  String state = 'PLAYING',
  int seq = 3,
  String guest = 'Bob',
}) => <String, Object?>{
  'code': _code,
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': state == 'LOBBY' ? null : _gameId,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    for (final int seat in <int>[0, 1])
      <String, Object?>{
        'seat': seat,
        'name': seat == 0 ? 'Sam' : guest,
        'connected': true,
        'tokens': <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
      },
  ],
  'turn': state == 'PLAYING'
      ? <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        }
      : null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has nothing queued; '
        'the scenario opened a transport it should not have',
      );
    }
    return _queue.removeAt(0);
  }
}

// ------------------------------------------------------- controller table

typedef _Fields = ({
  RoomPhase phase,
  String? errorCode,
  String? errorMessage,
  RoomSnapshot? room,
  int? seat,
  String? seatToken,
  bool taken,
  bool desynced,
  bool resyncing,
  bool reconnectPending,
  bool updateRequired,
});

_Fields _fieldsOf(RoomController c) => (
  phase: c.phase,
  errorCode: c.errorCode,
  errorMessage: c.errorMessage,
  room: c.room,
  seat: c.seat,
  seatToken: c.seatToken,
  taken: c.seatTakenOver,
  desynced: c.hasDesynced,
  resyncing: c.isResyncing,
  reconnectPending: c.autoReconnectPending,
  updateRequired: c.updateRequired,
);

String _fieldsNote(_Fields f) =>
    'phase=${f.phase} errorCode=${f.errorCode} seat=${f.seat} '
    'token=${f.seatToken} taken=${f.taken} desynced=${f.desynced} '
    'resyncing=${f.resyncing} reconnectPending=${f.reconnectPending} '
    'updateRequired=${f.updateRequired} room=${f.room?.code}#${f.room?.seq}';

/// A controller that holds a PLAYING room as seat 0, connected, over
/// [transport]. [pairs] holds what a listener read at every notification.
class _Table {
  _Table(this.controller, this.transport, this.connector);

  final RoomController controller;
  final FakeTransport transport;
  final _Connector connector;
  final List<(RoomPhase, bool)> pairs = <(RoomPhase, bool)>[];

  bool _disposed = false;

  void dispose() {
    if (!_disposed) {
      _disposed = true;
      controller.dispose();
    }
  }

  static Future<_Table> connect(
    WidgetTester tester,
    String id, {
    List<Duration> delays = const <Duration>[],
    bool seated = true,
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
      autoReconnectDelays: delays,
    );
    final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
    // pumpEventQueue relies on real timers, which never fire under a
    // testWidgets body's fake clock; runAsync steps outside it.
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    if (seated) {
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': _token},
        ),
      );
    }
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(transport.sentRaw.last),
        data: _roomJson(),
      ),
    );
    await created;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: '$id: fixture: the create reply must land connected',
    );
    final _Table table = _Table(controller, transport, connector);
    addTearDown(table.dispose);
    controller.addListener(
      () => table.pairs.add((controller.phase, controller.seatTakenOver)),
    );
    return table;
  }

  Future<void> push(WidgetTester tester, String text) async {
    transport.pushText(text);
    await tester.pump();
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }
}

void _expectNeverConnectedAndTaken(_Table table, String id, String when) {
  expect(
    table.pairs,
    isNot(contains((RoomPhase.connected, true))),
    reason: _why(
      id,
      'no listener to read (connected, seatTakenOver true) $when',
      'listeners read ${table.pairs}',
    ),
  );
}

void _expectLandedClosed(_Table table, String id) {
  expect(
    table.pairs,
    isNotEmpty,
    reason: _why(id, 'a notification at the takeover frame', 'none'),
  );
  expect(
    table.pairs.last,
    (RoomPhase.closed, true),
    reason: _why(
      id,
      'the last notification to read (closed, true)',
      'listeners read ${table.pairs}',
    ),
  );
}

// ------------------------------------------------------------ lobby rig

Widget _localized(Widget home, {Locale? locale}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

int _count(Key key) => find.byKey(key, skipOffstage: false).evaluate().length;

/// A create lobby pushed over a host page on a controller of its own, the
/// create answered with a two seat lobby for seat 0 (the room is held, the
/// phase is connected, a seat token is cached).
class _LobbyRig {
  _LobbyRig._(this.connector, this.transport, this.controller);

  final _Connector connector;
  final FakeTransport transport;
  final RoomController controller;

  static Future<_LobbyRig> open(
    WidgetTester tester,
    String id, {
    required Locale locale,
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    await tester.pumpWidget(
      _localized(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                key: _openLobbyKey,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LobbyScreen(
                      controller: controller,
                      action: LobbyAction.create,
                      playerName: 'Sam',
                      players: 2,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        locale: locale,
      ),
    );
    await tester.tap(find.byKey(_openLobbyKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      transport.sentRaw,
      isNotEmpty,
      reason: '$id: fixture: the pushed lobby must have sent create_room',
    );
    expect(_typeOf(transport.sentRaw.last), 'create_room');
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': _token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(transport.sentRaw.last),
        data: _roomJson(state: 'LOBBY'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: '$id: fixture: the create reply must land connected',
    );
    return _LobbyRig._(connector, transport, controller);
  }

  Future<void> push(WidgetTester tester, String text) async {
    transport.pushText(text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  }
}

String _lobbyNote(WidgetTester tester, RoomController c) =>
    'controller=${c.phase}/taken=${c.seatTakenOver}/update=${c.updateRequired}'
    '/desynced=${c.hasDesynced}/resyncing=${c.isResyncing} '
    'desync-strip=${_count(_lobbyDesyncKey)} '
    'resync-button=${_count(_lobbyResyncKey)} '
    'pip-strips=${find.byType(SeatPipStrip, skipOffstage: false).evaluate().length} '
    'lobby-leave=${_count(_lobbyLeaveKey)} sound=${_count(_lobbySoundKey)} '
    'seat-moved-leave=${_count(_lobbySeatMovedLeaveKey)}';

/// D4 after the state change: no desync strip, no Resync control in any form,
/// no seat pip strip; the corner close and the sound switch stay.
void _expectLobbyChromeBare(
  WidgetTester tester,
  String id,
  RoomController controller,
  String when,
) {
  final AppLocalizations loc = _loc(tester);
  final String saw = _lobbyNote(tester, controller);
  expect(
    find.byKey(_lobbyDesyncKey, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no desync strip $when', saw),
  );
  expect(
    find.byKey(_lobbyResyncKey, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no Resync button (by key) $when', saw),
  );
  expect(
    find.text(loc.lobbyResyncButton, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no Resync label (by text) $when', saw),
  );
  expect(
    find.text(loc.lobbyDesynced, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no desync line $when', saw),
  );
  expect(
    find.byType(SeatPipStrip, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no seat pip strip $when', saw),
  );
  expect(
    find.byKey(_pipStripKey, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no pip strip key $when', saw),
  );
  expect(
    find.byKey(_lobbyLeaveKey),
    findsOneWidget,
    reason: _why(id, 'the corner close stays $when', saw),
  );
  expect(
    find.byKey(_lobbySoundKey),
    findsOneWidget,
    reason: _why(id, 'the sound switch stays $when', saw),
  );
}

// -------------------------------------------------------------- game rig

enum _Play { move, roll, next }

List<Map<String, Object?>> _threeSeats() => <Map<String, Object?>>[
  seatJson(0, name: 'Sam', tokens: const <int>[0, 5, -1, -1]),
  seatJson(1, name: 'Bob'),
  seatJson(2, name: 'Cy'),
];

/// My turn to move with two legal tokens, my turn to roll, and seat 2's turn
/// with me (seat 0) next in the order of three.
Map<String, Object?> _turnOf(_Play play) => switch (play) {
  _Play.move => turnJson(
    seat: 0,
    phase: 'await_move',
    k: 1,
    value: 3,
    legal: const <int>[0, 1],
    legalByFace: <Map<String, Object?>>[
      faceLegal(3, const <int>[0, 1]),
    ],
  ),
  _Play.roll => turnJson(seat: 0, phase: 'await_roll', k: 0),
  _Play.next => turnJson(seat: 2, phase: 'await_roll', k: 0),
};

Future<RollTrayDrive> _mountPlay(
  WidgetTester tester,
  _Play play,
  Locale locale,
) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: _turnOf(play),
    seats: _threeSeats(),
    players: 3,
    gameId: _gameId,
  );
  await mountGame(tester, drive, locale: locale);
  return drive;
}

/// Flushes the request timers a case left, unmounts, disposes.
Future<void> _release(WidgetTester tester, RollTrayDrive drive) async {
  await tester.pump(const Duration(seconds: 11));
  await releaseGame(tester, drive);
}

/// Every Text the tree draws, flat.
List<String> _drawnText(WidgetTester tester) => <String>[
  for (final RichText w in tester.widgetList<RichText>(
    find.byType(RichText, skipOffstage: false),
  ))
    w.text.toPlainText(),
];

String _gameNote(WidgetTester tester, RoomController controller) {
  int keys(Key key) => _count(key);
  final List<String> rings = <String>[
    for (int s = 0; s < 4; s++)
      for (int t = 0; t < 4; t++)
        if (keys(legalRingKey(s, t)) > 0) '$s-$t',
  ];
  final List<int> glows = <int>[
    for (int s = 0; s < 4; s++)
      if (keys(Key('board-turn-yard-$s')) > 0) s,
  ];
  return 'controller=${controller.phase}/taken=${controller.seatTakenOver}'
      '/desynced=${controller.hasDesynced} '
      'chip=${keys(_headerChipKey)} banner=${keys(_turnBannerKey)} '
      'countdown-digits=${keys(_countdownDigitsKey)} '
      'countdown-ring=${keys(_countdownRingKey)} '
      'pip-strips=${find.byType(SeatPipStrip, skipOffstage: false).evaluate().length} '
      'rings=$rings die-pulse=${keys(_diePulseKey)} turn-glow=$glows '
      'hint-button=${keys(hintButtonKey)} '
      'desync-strip=${keys(_gameDesyncKey)} stale-table=${keys(_staleTableKey)}';
}

/// D5 a to d, the whole list of what a lost-seat table must not draw.
void _expectNoActingTable(
  WidgetTester tester,
  String id,
  RoomController controller,
  String when,
) {
  final AppLocalizations loc = _loc(tester);
  final String saw = _gameNote(tester, controller);
  void none(Key key, String what) {
    expect(
      find.byKey(key, skipOffstage: false),
      findsNothing,
      reason: _why(id, 'no $what $when', saw),
    );
  }

  // a. the header row
  none(_headerChipKey, 'header chip');
  none(_headerChipDotKey, 'header chip dot');
  none(_turnBannerKey, 'turn banner');
  none(_countdownDigitsKey, 'countdown digits');
  none(_countdownRingKey, 'countdown ring');
  none(_countdownSemanticsKey, 'countdown semantics');
  none(_countdownWarningKey, 'countdown warning');
  // c. the board with no own seat
  for (int seat = 0; seat < 4; seat++) {
    none(Key('board-turn-yard-$seat'), 'turn glow for seat $seat');
    for (int token = 0; token < 4; token++) {
      none(legalRingKey(seat, token), 'legal ring $seat-$token');
      none(
        Key('board-automove-glow-$seat-$token'),
        'auto-move glow $seat-$token',
      );
      none(Key('board-hint-$token'), 'hint marker $token');
    }
  }
  none(_diePulseKey, 'die pulse');
  none(hintButtonKey, 'hint bulb');
  // d. the seat pip strip
  none(_pipStripKey, 'pip strip');
  expect(
    find.byType(SeatPipStrip, skipOffstage: false),
    findsNothing,
    reason: _why(id, 'no SeatPipStrip $when', saw),
  );
  // Nothing in words either: no turn line, no "you're next".
  final List<String> forbidden = <String>[
    loc.gameYourTurnRoll,
    loc.gameYourTurnMove,
    loc.gameYourTurnStale,
    loc.gameAutoMoving,
    loc.gameYourTurnTimeUp,
    loc.gameYouAreNextAnnounce,
  ];
  for (final String text in _drawnText(tester)) {
    for (final String line in forbidden) {
      expect(
        text.contains(line),
        isFalse,
        reason: _why(id, 'no drawn text containing "$line" $when', '"$text"'),
      );
    }
  }
}

/// The live table before the loss, so every absence after it is a change and
/// not a fixture that never drew the thing.
void _expectLiveTable(
  WidgetTester tester,
  String id,
  _Play play,
  RoomController controller,
) {
  final AppLocalizations loc = _loc(tester);
  final String saw = _gameNote(tester, controller);
  expect(
    find.byKey(_headerChipKey),
    findsOneWidget,
    reason: _why(id, 'fixture: the header chip before the loss', saw),
  );
  expect(
    find.byKey(_turnBannerKey),
    findsOneWidget,
    reason: _why(id, 'fixture: the turn banner before the loss', saw),
  );
  expect(
    find.byKey(_countdownDigitsKey),
    findsOneWidget,
    reason: _why(id, 'fixture: the countdown before the loss', saw),
  );
  expect(
    find.byType(SeatPipStrip),
    findsOneWidget,
    reason: _why(id, 'fixture: the pip strip before the loss', saw),
  );
  expect(
    find.byKey(hintButtonKey),
    findsOneWidget,
    reason: _why(id, 'fixture: the hint bulb before the loss', saw),
  );
  switch (play) {
    case _Play.move:
      expect(
        tester.widget<Text>(find.byKey(_turnBannerKey)).data,
        loc.gameYourTurnMove,
        reason: _why(id, 'fixture: the move line', saw),
      );
      expect(ringedTokens(tester), <int>[
        0,
        1,
      ], reason: _why(id, 'fixture: two ringed tokens before the loss', saw));
      expect(
        _count(const Key('board-turn-yard-0')),
        1,
        reason: _why(id, 'fixture: my turn glow before the loss', saw),
      );
    case _Play.roll:
      expect(
        tester.widget<Text>(find.byKey(_turnBannerKey)).data,
        loc.gameYourTurnRoll,
        reason: _why(id, 'fixture: the roll line', saw),
      );
      expect(
        _count(_diePulseKey),
        1,
        reason: _why(id, 'fixture: the pulsing die before the loss', saw),
      );
    case _Play.next:
      expect(
        tester.widget<Text>(find.byKey(_turnBannerKey)).data,
        contains(loc.gameYouAreNextAnnounce),
        reason: _why(id, 'fixture: the "you\'re next" line', saw),
      );
      expect(
        _count(const Key('board-turn-yard-2')),
        1,
        reason: _why(id, 'fixture: seat 2\'s turn glow before the loss', saw),
      );
  }
}

bool _isCountdownRebuild(String line) =>
    line.contains('countdown') ||
    line.contains('_CountdownRing') ||
    line.contains('ValueListenableBuilder<int>');

/// Pumps [seconds] one second at a time and returns what the framework said
/// it rebuilt, through debugPrintRebuildDirtyWidgets. A countdown that ticks
/// rebuilds its digits and ring once a second; nothing else does on an idle
/// table.
Future<List<String>> _pumpSeconds(WidgetTester tester, int seconds) async {
  final List<String> lines = <String>[];
  final DebugPrintCallback saved = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
  debugPrintRebuildDirtyWidgets = true;
  try {
    for (int i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  } finally {
    debugPrintRebuildDirtyWidgets = false;
    debugPrint = saved;
  }
  return lines;
}

Offset _boardTopLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(boardKey));

void _expectBoardStill(
  WidgetTester tester,
  String id,
  Offset before,
  String when,
) {
  final Offset now = _boardTopLeft(tester);
  expect(
    (now - before).distance,
    lessThan(0.01),
    reason: _why(
      id,
      'the board top-left to stay at $before $when (the header row keeps its '
          'height)',
      '$now',
    ),
  );
}

Future<void> _takeOver(WidgetTester tester, RollTrayDrive drive) =>
    pushRaw(tester, drive, _takeoverFrame());

Future<void> _farSideEnds(WidgetTester tester, RollTrayDrive drive) async {
  drive.transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
}

// ---------------------------------------------------------------- Home rig

class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class _Rig {
  final List<_TrackedController> controllers = <_TrackedController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  Future<WireTransport> _connect(Uri url) async {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    return transport;
  }

  RoomController call() {
    final _TrackedController created = _TrackedController(
      serverUrl: Uri.parse(_testUrl),
      connect: _connect,
    );
    controllers.add(created);
    return created;
  }

  FakeTransport get last => transports.last;

  List<String> sent(String type) => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (_typeOf(s) == type) s,
  ];

  String lastRequestId(String type) => _idOf(sent(type).last);

  void disposeAll() {
    for (final _TrackedController controller in controllers) {
      if (!controller.wasDisposed) {
        controller.dispose();
      }
    }
  }
}

Widget _app(RoomControllerFactory factory, {Locale? locale}) {
  return _localized(
    HomeScreen(
      onToggleLocale: () {},
      controllerFactory: factory,
      initialLinkReader: noInitialLink,
      linkStream: noLinkStream,
    ),
    locale: locale,
  );
}

/// Bounded pumps only: the game countdown never settles.
Future<void> _pumpBounded(WidgetTester tester, {int frames = 6}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _finishHome(WidgetTester tester, _Rig rig) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  rig.disposeAll();
  await tester.pump();
}

void _seedFreshSeat() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _seatPrefsKey: <String>[_code, '0', _token],
    _savedAtPrefsKey: DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  });
}

Map<String, Object?> _homePlayingRoom() => <String, Object?>{
  'code': _code,
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 3,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': _gameId,
  'client_seeds': null,
  'seats': _threeSeats(),
  'turn': _turnOf(_Play.move),
  'winner': null,
  'seq': 3,
};

// ------------------------------------------------------------------- main

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- D1
  group('D1 the takeover closes the connection at once', () {
    testWidgets(
      'D1.pairs: no listener ever reads (connected, seatTakenOver true); the '
      'first notification at the frame already reads closed; the transport '
      'saw a client close',
      (tester) async {
        const String id = 'D1.pairs';
        final _Table table = await _Table.connect(tester, id, delays: _delays);
        try {
          expect(table.transport.closeCalls, isEmpty);
          await table.push(tester, _takeoverFrame());
          expect(
            table.controller.seatTakenOver,
            isTrue,
            reason: _why(id, 'seatTakenOver true at the frame', 'false'),
          );
          expect(
            table.transport.closeCalls,
            isNotEmpty,
            reason: _why(
              id,
              'the client to close the transport in the frame\'s own turn',
              'closeCalls ${table.transport.closeCalls}, '
                  'isClosed ${table.transport.isClosed}',
            ),
          );
          _expectNeverConnectedAndTaken(table, id, 'at the frame');
          _expectLandedClosed(table, id);
          final List<(RoomPhase, bool)> takeoverPairs = table.pairs
              .where(((RoomPhase, bool) p) => p.$2)
              .toList();
          expect(
            takeoverPairs.first,
            (RoomPhase.closed, true),
            reason: _why(
              id,
              'the first notification that reads seatTakenOver true to read '
                  'phase closed',
              'listeners read ${table.pairs}',
            ),
          );
          expect(
            table.controller.phase,
            RoomPhase.closed,
            reason: _why(
              id,
              'phase closed at the frame',
              '${table.controller.phase}',
            ),
          );
        } finally {
          table.dispose();
        }
      },
    );

    testWidgets(
      'D1.fields: every other field ends as a close ends it today: errorCode '
      'null, the room, the seat and the cached token kept',
      (tester) async {
        const String id = 'D1.fields';
        final _Table table = await _Table.connect(tester, id);
        try {
          final RoomSnapshot? roomBefore = table.controller.room;
          await table.push(tester, _takeoverFrame());
          final _Fields f = _fieldsOf(table.controller);
          final String saw = _fieldsNote(f);
          expect(f.errorCode, isNull, reason: _why(id, 'errorCode null', saw));
          expect(
            f.errorMessage,
            isNull,
            reason: _why(id, 'errorMessage null', saw),
          );
          expect(
            identical(f.room, roomBefore),
            isTrue,
            reason: _why(id, 'the held room untouched', saw),
          );
          expect(f.seat, 0, reason: _why(id, 'seat 0 kept', saw));
          expect(
            f.seatToken,
            _token,
            reason: _why(id, 'the cached token kept', saw),
          );
          expect(
            f.updateRequired,
            isFalse,
            reason: _why(id, 'updateRequired false', saw),
          );
          expect(
            f.reconnectPending,
            isFalse,
            reason: _why(id, 'no reconnect pending', saw),
          );
        } finally {
          table.dispose();
        }
      },
    );

    testWidgets(
      'D1.done: the later done changes no field and starts no reconnect, '
      'past every auto-reconnect delay',
      (tester) async {
        const String id = 'D1.done';
        final _Table table = await _Table.connect(tester, id, delays: _delays);
        try {
          await table.push(tester, _takeoverFrame());
          await table.flush(tester);
          final _Fields atFrame = _fieldsOf(table.controller);
          table.transport.endFromFarSide();
          await tester.pump();
          await tester.pump();
          expect(
            table.controller.autoReconnectPending,
            isFalse,
            reason: _why(
              id,
              'no scheduled reconnect after the close',
              'one is pending',
            ),
          );
          await tester.pump(_delays[0]);
          await tester.pump(_delays[1]);
          await tester.pump(const Duration(seconds: 30));
          await table.flush(tester);
          expect(
            table.connector.calls.length,
            1,
            reason: _why(
              id,
              'the one connect the table opened and no retry',
              '${table.connector.calls.length} connects',
            ),
          );
          final _Fields later = _fieldsOf(table.controller);
          expect(
            later,
            atFrame,
            reason: _why(
              id,
              'no field to change after the close: ${_fieldsNote(atFrame)}',
              _fieldsNote(later),
            ),
          );
          _expectNeverConnectedAndTaken(table, id, 'at any point');
        } finally {
          table.dispose();
        }
      },
    );

    testWidgets(
      'D1.replay: the takeover frame twice in one burst is one takeover; '
      'nobody reads (connected, true), the fields are those of one frame',
      (tester) async {
        const String id = 'D1.replay';
        final _Table table = await _Table.connect(tester, id, delays: _delays);
        try {
          table.transport.pushText(_takeoverFrame());
          table.transport.pushText(_takeoverFrame());
          await tester.pump();
          await tester.pump();
          _expectNeverConnectedAndTaken(table, id, 'after the replay');
          _expectLandedClosed(table, id);
          expect(table.controller.errorCode, isNull);
          await tester.pump(const Duration(seconds: 30));
          expect(
            table.connector.calls.length,
            1,
            reason: _why(
              id,
              'no reconnect after a replayed frame',
              '${table.connector.calls.length} connects',
            ),
          );
        } finally {
          table.dispose();
        }
      },
    );

    testWidgets(
      'D1.burst: the frame and the far end vanishing in one burst: still no '
      '(connected, true), no reconnect',
      (tester) async {
        const String id = 'D1.burst';
        final _Table table = await _Table.connect(tester, id, delays: _delays);
        try {
          table.transport.pushText(_takeoverFrame());
          table.transport.endFromFarSide();
          await tester.pump();
          await tester.pump();
          _expectNeverConnectedAndTaken(table, id, 'after the burst');
          expect(
            table.controller.autoReconnectPending,
            isFalse,
            reason: _why(
              id,
              'no scheduled reconnect after the burst',
              'one is pending',
            ),
          );
          await tester.pump(const Duration(seconds: 30));
          expect(
            table.connector.calls.length,
            1,
            reason: _why(
              id,
              'no reconnect after the burst',
              '${table.connector.calls.length} connects',
            ),
          );
          expect(table.controller.seatTakenOver, isTrue);
          expect(table.controller.phase, RoomPhase.closed);
          expect(table.controller.errorCode, isNull);
        } finally {
          table.dispose();
        }
      },
    );

    for (final ({String name, Object? code}) other
        in <({String name, Object? code})>[
          (name: 'RATE_LIMITED', code: 'RATE_LIMITED'),
          (name: 'NO_SUCH_ROOM', code: 'NO_SUCH_ROOM'),
          (name: 'lower case', code: 'bad_seat_token'),
          (name: 'no code', code: null),
        ]) {
      testWidgets(
        'guard.D1.other (${other.name}): an unsolicited error that is not '
        'exactly BAD_SEAT_TOKEN does not close the connection',
        (tester) async {
          final String id = 'guard.D1.other ${other.name}';
          final _Table table = await _Table.connect(tester, id);
          try {
            await table.push(tester, _takeoverFrame(other.code));
            expect(
              table.controller.seatTakenOver,
              isFalse,
              reason: _why(id, 'seatTakenOver false', 'true'),
            );
            expect(
              table.transport.closeCalls,
              isEmpty,
              reason: _why(
                id,
                'no client close for a code that is not the takeover',
                'closeCalls ${table.transport.closeCalls}',
              ),
            );
            expect(
              table.controller.phase,
              RoomPhase.connected,
              reason: _why(id, 'phase connected', '${table.controller.phase}'),
            );
          } finally {
            table.dispose();
          }
        },
      );
    }

    testWidgets(
      'guard.D1.reply: BAD_SEAT_TOKEN as a reply (re set) to a request I '
      'sent is not the takeover: no flag',
      (tester) async {
        const String id = 'guard.D1.reply';
        final _Table table = await _Table.connect(tester, id);
        try {
          unawaited(table.controller.roll());
          await tester.pump();
          expect(_typeOf(table.transport.sentRaw.last), 'roll');
          table.transport.pushText(
            _frame(
              type: 'error',
              re: _idOf(table.transport.sentRaw.last),
              data: <String, Object?>{'code': 'BAD_SEAT_TOKEN', 'message': ''},
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(
            table.controller.seatTakenOver,
            isFalse,
            reason: _why(id, 'seatTakenOver false for a reply', 'true'),
          );
          _expectNeverConnectedAndTaken(table, id, 'for a reply');
        } finally {
          table.dispose();
        }
      },
    );
  });

  // ---------------------------------------------------------------- D2
  group('D2 a moved seat is never resumed', () {
    for (final ({String name, Future<void> Function(RoomController) call}) m
        in <({String name, Future<void> Function(RoomController) call})>[
          (name: 'reconnect', call: (RoomController c) => c.reconnect()),
          (name: 'resync', call: (RoomController c) => c.resync()),
          (
            name: 'reconnectAndRematch',
            call: (RoomController c) => c.reconnectAndRematch(),
          ),
        ]) {
      testWidgets(
        'D2.${m.name}: with seatTakenOver true it opens no transport and '
        'sends nothing',
        (tester) async {
          final String id = 'D2.${m.name}';
          final _Table table = await _Table.connect(
            tester,
            id,
            delays: _delays,
          );
          try {
            await table.push(tester, _takeoverFrame());
            // The server closes right behind its error frame (4004).
            table.transport.endFromFarSide();
            await tester.pump();
            await tester.pump();
            await table.flush(tester);
            expect(table.controller.seatTakenOver, isTrue);
            expect(
              table.controller.phase,
              RoomPhase.closed,
              reason: _why(
                id,
                'fixture: phase closed',
                '${table.controller.phase}',
              ),
            );
            final FakeTransport second = FakeTransport();
            table.connector.enqueue(second);
            final int sentBefore = table.transport.sentRaw.length;
            final int callsBefore = table.connector.calls.length;
            final _Fields before = _fieldsOf(table.controller);

            final Future<void> call = m.call(table.controller);
            await table.flush(tester);
            await tester.pump(const Duration(milliseconds: 50));
            await table.flush(tester);

            expect(
              table.connector.calls.length,
              callsBefore,
              reason: _why(
                id,
                'no transport opened by ${m.name}()',
                '${table.connector.calls.length - callsBefore} opened',
              ),
            );
            expect(
              second.sentRaw,
              isEmpty,
              reason: _why(
                id,
                'nothing sent on a new transport',
                '${second.sentRaw}',
              ),
            );
            expect(
              table.transport.sentRaw.length,
              sentBefore,
              reason: _why(
                id,
                'nothing sent on the old transport',
                '${table.transport.sentRaw.skip(sentBefore)}',
              ),
            );
            expect(
              _fieldsOf(table.controller),
              before,
              reason: _why(
                id,
                'no field to change: ${_fieldsNote(before)}',
                _fieldsNote(_fieldsOf(table.controller)),
              ),
            );
            // Let a call that wrongly started a request run out its timer so
            // the failure above is the only one reported.
            await tester.pump(const Duration(seconds: 11));
            await call.timeout(const Duration(seconds: 1), onTimeout: () {});
          } finally {
            table.dispose();
          }
        },
      );
    }

    testWidgets(
      'guard.D2: after a plain drop (no takeover) reconnect() does open a '
      'transport and send a resume, so the probe above can see one',
      (tester) async {
        const String id = 'guard.D2';
        final _Table table = await _Table.connect(tester, id);
        try {
          table.transport.endFromFarSide();
          await tester.pump();
          await tester.pump();
          expect(table.controller.seatTakenOver, isFalse);
          final FakeTransport second = FakeTransport();
          table.connector.enqueue(second);
          unawaited(table.controller.reconnect());
          await table.flush(tester);
          expect(
            table.connector.calls.length,
            2,
            reason: _why(
              id,
              'a second connect after a plain drop',
              '${table.connector.calls.length} connects',
            ),
          );
          expect(
            second.sentRaw.map(_typeOf).toList(),
            contains('resume'),
            reason: _why(
              id,
              'a resume on the new transport',
              '${second.sentRaw}',
            ),
          );
          await tester.pump(const Duration(seconds: 11));
        } finally {
          table.dispose();
        }
      },
    );
  });

  // ---------------------------------------------------------------- D3
  group('D3 no resync state survives a takeover', () {
    testWidgets('D3.inflight: a takeover while a resync is in flight leaves '
        'hasDesynced and isResyncing false; the resume reply behind it changes '
        'nothing', (tester) async {
      const String id = 'D3.inflight';
      final _Table table = await _Table.connect(tester, id);
      try {
        await table.push(tester, _gapFrame());
        expect(
          table.controller.hasDesynced,
          isTrue,
          reason: _why(id, 'fixture: the seq gap sets hasDesynced', 'false'),
        );
        expect(
          table.controller.isResyncing,
          isTrue,
          reason: _why(id, 'fixture: the gap sends a resume', 'false'),
        );
        final String resumeId = _idOf(table.transport.sentRaw.last);
        expect(_typeOf(table.transport.sentRaw.last), 'resume');
        final RoomSnapshot? roomBefore = table.controller.room;
        final String? guestBefore = roomBefore?.seats[1].name;

        // One burst: the takeover, then the reply to the resume.
        table.transport.pushText(_takeoverFrame());
        table.transport.pushText(
          _frame(
            type: 'room',
            re: resumeId,
            data: _roomJson(seq: 1000, guest: 'Renamed'),
          ),
        );
        await tester.pump();
        await tester.pump();
        await table.flush(tester);

        final _Fields f = _fieldsOf(table.controller);
        final String saw = _fieldsNote(f);
        expect(f.taken, isTrue, reason: _why(id, 'seatTakenOver true', saw));
        expect(
          f.desynced,
          isFalse,
          reason: _why(id, 'hasDesynced false after a takeover', saw),
        );
        expect(
          f.resyncing,
          isFalse,
          reason: _why(id, 'isResyncing false after a takeover', saw),
        );
        expect(
          identical(f.room, roomBefore),
          isTrue,
          reason: _why(
            id,
            'the held room untouched by the reply (seq ${roomBefore?.seq}, '
                'guest "$guestBefore")',
            'seq ${f.room?.seq}, guest "${f.room?.seats[1].name}"',
          ),
        );
        _expectNeverConnectedAndTaken(table, id, 'at any point');
      } finally {
        table.dispose();
      }
    });

    testWidgets(
      'D3.idle: a takeover with hasDesynced true and no resync in flight '
      '(the resume timed out) clears hasDesynced',
      (tester) async {
        const String id = 'D3.idle';
        final _Table table = await _Table.connect(tester, id);
        try {
          await table.push(tester, _gapFrame());
          await tester.pump(const Duration(seconds: 11));
          await table.flush(tester);
          expect(
            table.controller.hasDesynced,
            isTrue,
            reason: _why(
              id,
              'fixture: hasDesynced stays after a timed out resume',
              'false',
            ),
          );
          expect(
            table.controller.isResyncing,
            isFalse,
            reason: _why(id, 'fixture: the timed out resume is over', 'true'),
          );
          await table.push(tester, _takeoverFrame());
          final _Fields f = _fieldsOf(table.controller);
          final String saw = _fieldsNote(f);
          expect(f.taken, isTrue, reason: _why(id, 'seatTakenOver true', saw));
          expect(
            f.desynced,
            isFalse,
            reason: _why(id, 'hasDesynced false after a takeover', saw),
          );
          expect(
            f.resyncing,
            isFalse,
            reason: _why(id, 'isResyncing false', saw),
          );
        } finally {
          table.dispose();
        }
      },
    );

    testWidgets('D3.nogap: a takeover with no desync leaves hasDesynced and '
        'isResyncing false (nothing is invented)', (tester) async {
      const String id = 'D3.nogap';
      final _Table table = await _Table.connect(tester, id);
      try {
        await table.push(tester, _takeoverFrame());
        expect(table.controller.hasDesynced, isFalse);
        expect(table.controller.isResyncing, isFalse);
        expect(table.controller.seatTakenOver, isTrue);
      } finally {
        table.dispose();
      }
    });
  });

  // ---------------------------------------------------------------- D4
  group('D4 the lobby draws no desync strip and no pip strip', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String tag = locale.languageCode;

      testWidgets(
        'D4.taken.$tag: a takeover with hasDesynced true: no desync strip, '
        'no Resync button anywhere, no SeatPipStrip; the corner close and the '
        'sound switch stay',
        (tester) async {
          final String id = 'D4.taken.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
          );
          try {
            await lobby.push(tester, _gapFrame());
            await tester.pump(const Duration(seconds: 11));
            expect(
              lobby.controller.hasDesynced,
              isTrue,
              reason: _why(id, 'fixture: hasDesynced true', 'false'),
            );
            expect(
              find.byKey(_lobbyResyncKey),
              findsOneWidget,
              reason: _why(
                id,
                'fixture: the Resync button is drawn before the takeover',
                _lobbyNote(tester, lobby.controller),
              ),
            );
            expect(
              find.byType(SeatPipStrip),
              findsOneWidget,
              reason: _why(
                id,
                'fixture: one pip strip before the takeover',
                _lobbyNote(tester, lobby.controller),
              ),
            );

            await lobby.push(tester, _takeoverFrame());
            expect(lobby.controller.seatTakenOver, isTrue);
            _expectLobbyChromeBare(
              tester,
              id,
              lobby.controller,
              'at the takeover frame',
            );

            lobby.transport.endFromFarSide();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(lobby.controller.phase, RoomPhase.closed);
            _expectLobbyChromeBare(
              tester,
              id,
              lobby.controller,
              'once the connection is gone',
            );
            expect(
              find.byKey(_lobbySeatMovedLeaveKey),
              findsOneWidget,
              reason: _why(
                id,
                'fixture: the seat-moved card is up',
                _lobbyNote(tester, lobby.controller),
              ),
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );

      testWidgets(
        'D4.takenInflight.$tag: a takeover while the resync is in flight: '
        'the same bare chrome',
        (tester) async {
          final String id = 'D4.takenInflight.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
          );
          try {
            await lobby.push(tester, _gapFrame());
            expect(
              lobby.controller.isResyncing,
              isTrue,
              reason: _why(id, 'fixture: a resync is in flight', 'false'),
            );
            await lobby.push(tester, _takeoverFrame());
            _expectLobbyChromeBare(
              tester,
              id,
              lobby.controller,
              'at the takeover frame',
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );

      testWidgets(
        'D4.takenSynced.$tag: a takeover with the table in sync: no pip '
        'strip, the corner close and sound switch stay',
        (tester) async {
          final String id = 'D4.takenSynced.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
          );
          try {
            expect(
              find.byType(SeatPipStrip),
              findsOneWidget,
              reason: _why(
                id,
                'fixture: one pip strip before the takeover',
                _lobbyNote(tester, lobby.controller),
              ),
            );
            await lobby.push(tester, _takeoverFrame());
            _expectLobbyChromeBare(
              tester,
              id,
              lobby.controller,
              'at the takeover frame',
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );

      testWidgets(
        'D4.update.$tag: UPDATE_REQUIRED with hasDesynced true: no desync '
        'strip, no Resync button anywhere, no SeatPipStrip; the corner close '
        'and the sound switch stay',
        (tester) async {
          final String id = 'D4.update.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
          );
          try {
            await lobby.push(tester, _gapFrame());
            await tester.pump(const Duration(seconds: 11));
            expect(lobby.controller.hasDesynced, isTrue);
            expect(
              find.byKey(_lobbyResyncKey),
              findsOneWidget,
              reason: _why(
                id,
                'fixture: the Resync button is drawn before the frame',
                _lobbyNote(tester, lobby.controller),
              ),
            );
            await lobby.push(tester, _updateFrame());
            expect(
              lobby.controller.updateRequired,
              isTrue,
              reason: _why(id, 'updateRequired true', 'false'),
            );
            _expectLobbyChromeBare(
              tester,
              id,
              lobby.controller,
              'at the update frame',
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );

      testWidgets(
        'guard.D4.drop.$tag: a plain drop with hasDesynced true keeps the '
        'desync strip and the pip strip (the seat is still mine)',
        (tester) async {
          final String id = 'guard.D4.drop.$tag';
          final _LobbyRig lobby = await _LobbyRig.open(
            tester,
            id,
            locale: locale,
          );
          try {
            await lobby.push(tester, _gapFrame());
            await tester.pump(const Duration(seconds: 11));
            lobby.transport.endFromFarSide();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(lobby.controller.seatTakenOver, isFalse);
            expect(
              find.byType(SeatPipStrip),
              findsOneWidget,
              reason: _why(
                id,
                'the pip strip kept after a plain drop',
                _lobbyNote(tester, lobby.controller),
              ),
            );
            expect(
              find.byKey(_lobbyDesyncKey),
              findsOneWidget,
              reason: _why(
                id,
                'the desync strip kept after a plain drop',
                _lobbyNote(tester, lobby.controller),
              ),
            );
          } finally {
            await lobby.finish(tester);
          }
        },
      );
    }
  });

  // ---------------------------------------------------------------- D5
  group('D5 the lost-seat table says nothing it cannot do', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      for (final _Play play in _Play.values) {
        final String tag = '${play.name}.${locale.languageCode}';

        testWidgets(
          'D5.takeover.$tag: after the takeover frame there is no header row, '
          'no countdown, no pip strip, no ring, pulse, glow, hint or "you\'re '
          'next"; the board does not move; three seconds change nothing',
          (tester) async {
            final String id = 'D5.takeover.$tag';
            final RollTrayDrive drive = await _mountPlay(tester, play, locale);
            try {
              _expectLiveTable(tester, id, play, drive.controller);
              final Offset boardBefore = _boardTopLeft(tester);

              await _takeOver(tester, drive);
              expect(
                drive.controller.seatTakenOver,
                isTrue,
                reason: _why(id, 'seatTakenOver true', 'false'),
              );
              _expectNoActingTable(
                tester,
                id,
                drive.controller,
                'at the takeover frame',
              );
              _expectBoardStill(
                tester,
                id,
                boardBefore,
                'at the takeover frame',
              );

              final List<String> rebuilt = await _pumpSeconds(tester, 3);
              _expectNoActingTable(
                tester,
                id,
                drive.controller,
                '3 s after the takeover frame',
              );
              expect(
                rebuilt.where(_isCountdownRebuild),
                isEmpty,
                reason: _why(
                  id,
                  'no countdown rebuild in 3 s on a lost seat',
                  rebuilt.where(_isCountdownRebuild).toList().toString(),
                ),
              );
              _expectBoardStill(
                tester,
                id,
                boardBefore,
                '3 s after the takeover frame',
              );

              await _farSideEnds(tester, drive);
              await tester.pump(const Duration(seconds: 1));
              _expectNoActingTable(
                tester,
                id,
                drive.controller,
                'once the connection is gone',
              );
              _expectBoardStill(
                tester,
                id,
                boardBefore,
                'once the connection is gone',
              );
            } finally {
              await _release(tester, drive);
            }
          },
        );
      }
    }

    testWidgets(
      'guard.D5.ticks: on a live table the countdown does rebuild once a '
      'second (so the probe in D5.takeover can see a tick)',
      (tester) async {
        const String id = 'guard.D5.ticks';
        final RollTrayDrive drive = await _mountPlay(tester, _Play.move, _en);
        try {
          final List<String> rebuilt = await _pumpSeconds(tester, 3);
          expect(
            rebuilt.where(_isCountdownRebuild),
            isNotEmpty,
            reason: _why(
              id,
              'countdown rebuilds on a live table in 3 s',
              'none in ${rebuilt.length} rebuild lines',
            ),
          );
        } finally {
          await _release(tester, drive);
        }
      },
    );

    testWidgets(
      'D5.tapDie: after the takeover frame a tap on the die sends no roll',
      (tester) async {
        const String id = 'D5.tapDie';
        final RollTrayDrive drive = await _mountPlay(tester, _Play.roll, _en);
        try {
          await _takeOver(tester, drive);
          final int mark = drive.transport.sentRaw.length;
          await tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            sentTypesSince(drive.transport, mark),
            isEmpty,
            reason: _why(
              id,
              'nothing sent for a die tap on a lost seat',
              '${sentTypesSince(drive.transport, mark)}',
            ),
          );
        } finally {
          await _release(tester, drive);
        }
      },
    );

    testWidgets(
      'D5.tapToken: after the takeover frame a tap on a formerly legal token '
      'sends no move',
      (tester) async {
        const String id = 'D5.tapToken';
        final RollTrayDrive drive = await _mountPlay(tester, _Play.move, _en);
        try {
          await _takeOver(tester, drive);
          final int mark = drive.transport.sentRaw.length;
          await tester.tap(find.byKey(tokenHitKey(0, 0)), warnIfMissed: false);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            sentTypesSince(drive.transport, mark),
            isEmpty,
            reason: _why(
              id,
              'nothing sent for a token tap on a lost seat',
              '${sentTypesSince(drive.transport, mark)}',
            ),
          );
        } finally {
          await _release(tester, drive);
        }
      },
    );

    Future<RollTrayDrive> mountHold(WidgetTester tester) async {
      // One legal token: the client holds 1.5 s and plays it for me.
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: turnJson(
          seat: 0,
          phase: 'await_move',
          k: 1,
          value: 5,
          legal: const <int>[1],
        ),
        seats: <Map<String, Object?>>[
          seatJson(0, name: 'Sam', tokens: const <int>[-1, 3, -1, -1]),
          seatJson(1, name: 'Bob'),
        ],
        gameId: _gameId,
      );
      await mountGame(tester, drive);
      return drive;
    }

    testWidgets(
      'guard.D5.hold: with the seat held, the auto-move hold plays the one '
      'legal token (so the case below can see a move)',
      (tester) async {
        const String id = 'guard.D5.hold';
        final RollTrayDrive drive = await mountHold(tester);
        try {
          final int mark = drive.transport.sentRaw.length;
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            movesSince(drive.transport, mark),
            hasLength(1),
            reason: _why(
              id,
              'one move from the auto-move hold within 4 s',
              '${sentTypesSince(drive.transport, mark)}',
            ),
          );
        } finally {
          await _release(tester, drive);
        }
      },
    );

    testWidgets(
      'D5.hold: a takeover while the auto-move hold is pending: no move is '
      'sent for the seat that moved',
      (tester) async {
        const String id = 'D5.hold';
        final RollTrayDrive drive = await mountHold(tester);
        try {
          final int mark = drive.transport.sentRaw.length;
          await tester.pump(const Duration(milliseconds: 300));
          await _takeOver(tester, drive);
          for (int i = 0; i < 50; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            sentTypesSince(drive.transport, mark),
            isEmpty,
            reason: _why(
              id,
              'no frame sent after the takeover',
              '${sentTypesSince(drive.transport, mark)}',
            ),
          );
          _expectNoActingTable(
            tester,
            id,
            drive.controller,
            '5 s after the takeover frame',
          );
        } finally {
          await _release(tester, drive);
        }
      },
    );

    // C-540 and C-529: the frames of the pop under Home.
    for (final Locale locale in <Locale>[_en, _ar]) {
      for (final ({String name, String code}) exit
          in <({String name, String code})>[
            (name: 'refused', code: 'BAD_SEAT_TOKEN'),
            (name: 'gone', code: 'NO_SUCH_ROOM'),
          ]) {
        final String tag = '${exit.name}.${locale.languageCode}';

        testWidgets(
          'D5.$tag: through the frames of the pop (${exit.code} on the '
          'resume) the dimmed table has no header row, countdown, pip strip, '
          'ring, pulse, glow or hint',
          (tester) async {
            final String id = 'D5.$tag';
            _seedFreshSeat();
            final _Rig rig = _Rig();
            await tester.pumpWidget(_app(rig.call, locale: locale));
            await _pumpBounded(tester);
            try {
              expect(
                rig.sent('resume'),
                hasLength(1),
                reason: '$id: fixture: a fresh record resumes on its own',
              );
              rig.last.pushText(
                _frame(
                  type: 'seat_assigned',
                  data: <String, Object?>{'seat': 0, 'seat_token': _token},
                ),
              );
              rig.last.pushText(
                _frame(
                  type: 'room',
                  re: rig.lastRequestId('resume'),
                  data: _homePlayingRoom(),
                ),
              );
              await _pumpBounded(tester, frames: 3);
              expect(
                find.byType(GameScreen),
                findsOneWidget,
                reason: '$id: fixture: a resume shows GameScreen',
              );
              final RoomController controller = rig.controllers.last;
              _expectLiveTable(tester, id, _Play.move, controller);

              // The plain drop first: the seat is still mine, the stale
              // table says so.
              rig.last.endFromFarSide();
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 400));
              final AppLocalizations loc = _loc(tester);
              expect(
                tester.widget<Text>(find.byKey(_turnBannerKey)).data,
                loc.gameYourTurnStale,
                reason: _why(
                  id,
                  'fixture: the stale table keeps its "Your turn" after a plain drop',
                  _gameNote(tester, controller),
                ),
              );
              final int before = rig.transports.length;
              await tester.ensureVisible(find.byKey(_gameReconnectKey));
              await tester.tap(find.byKey(_gameReconnectKey));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 50));
              expect(
                rig.transports.length,
                before + 1,
                reason: '$id: fixture: the tap must open one new transport',
              );

              rig.last.pushText(
                _frame(
                  type: 'error',
                  re: rig.lastRequestId('resume'),
                  data: <String, Object?>{'code': exit.code, 'message': ''},
                ),
              );
              await tester.pump();
              int checked = 0;
              for (int i = 0; i < 45; i += 1) {
                if (find
                    .byType(GameScreen, skipOffstage: false)
                    .evaluate()
                    .isEmpty) {
                  break;
                }
                checked += 1;
                _expectNoActingTable(
                  tester,
                  id,
                  controller,
                  'at frame $i of the pop',
                );
                await tester.pump(const Duration(milliseconds: 16));
              }
              expect(
                checked,
                greaterThan(0),
                reason: _why(
                  id,
                  'the game route on the tree for at least one frame of the pop',
                  'none',
                ),
              );
            } finally {
              await _finishHome(tester, rig);
            }
          },
        );
      }
    }
  });

  // ---------------------------------------------------------------- D6
  group('D6 the game screen draws no desync strip on a lost seat', () {
    for (final bool inFlight in <bool>[true, false]) {
      final String tag = inFlight ? 'inflight' : 'idle';
      testWidgets('D6.$tag: a takeover with hasDesynced true (resync '
          '${inFlight ? 'in flight' : 'timed out'}) draws no desync strip', (
        tester,
      ) async {
        final String id = 'D6.$tag';
        final RollTrayDrive drive = await _mountPlay(tester, _Play.move, _en);
        try {
          await pushRaw(tester, drive, _gapFrame());
          if (!inFlight) {
            await tester.pump(const Duration(seconds: 11));
          }
          expect(
            drive.controller.hasDesynced,
            isTrue,
            reason: _why(id, 'fixture: hasDesynced true', 'false'),
          );
          expect(
            find.byKey(_gameDesyncKey),
            findsOneWidget,
            reason: _why(
              id,
              'fixture: the strip is drawn before the takeover',
              _gameNote(tester, drive.controller),
            ),
          );
          await _takeOver(tester, drive);
          expect(
            find.byKey(_gameDesyncKey, skipOffstage: false),
            findsNothing,
            reason: _why(
              id,
              'no desync strip at the takeover frame',
              _gameNote(tester, drive.controller),
            ),
          );
          await _farSideEnds(tester, drive);
          await tester.pump(const Duration(seconds: 1));
          expect(
            find.byKey(_gameDesyncKey, skipOffstage: false),
            findsNothing,
            reason: _why(
              id,
              'no desync strip once the connection is gone',
              _gameNote(tester, drive.controller),
            ),
          );
        } finally {
          await _release(tester, drive);
        }
      });
    }
  });

  // ---------------------------------------------------------------- D7
  group('D7 the face picker closes on the takeover', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      testWidgets(
        'D7.${locale.languageCode}: the picker open at the takeover closes '
        'on that rebuild; nothing is sent, no tap cue',
        (tester) async {
          final String id = 'D7.${locale.languageCode}';
          final List<Map<String, Object?>> byFace = <Map<String, Object?>>[
            faceLegal(6, const <int>[0, 2]),
            faceLegal(4, const <int>[1, 2]),
          ];
          final RollTrayDrive drive = await connectPlaying(
            tester,
            turn: turnJson(
              seat: 0,
              phase: 'await_move',
              k: 2,
              value: 6,
              legal: const <int>[0, 2],
              queue: const <int>[6, 4],
              legalByFace: byFace,
            ),
            seats: twoSeats(mine: const <int>[1, 3, 6, -1]),
            gameId: _gameId,
          );
          await mountGame(tester, drive, locale: locale);
          try {
            await tester.tap(
              find.byKey(tokenHitKey(0, 2)),
              warnIfMissed: false,
            );
            await tester.pump();
            for (int i = 0; i < 14; i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(
              tester.any(find.byKey(facePickerKey)),
              isTrue,
              reason: _why(
                id,
                'fixture: the picker is open on token 2',
                'closed',
              ),
            );
            final int mark = drive.transport.sentRaw.length;
            final int cues = drive.feedback.recorded.length;

            await _takeOver(tester, drive);
            for (int i = 0; i < 14; i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(
              tester.any(find.byKey(facePickerKey)),
              isFalse,
              reason: _why(
                id,
                'the picker closed on the takeover rebuild',
                'open, options ${pickerOptionFaces(tester)}',
              ),
            );
            expect(
              pickerOptionFaces(tester),
              isEmpty,
              reason: _why(
                id,
                'no picker option left',
                '${pickerOptionFaces(tester)}',
              ),
            );
            expect(
              movesSince(drive.transport, mark),
              isEmpty,
              reason: _why(
                id,
                'no move sent by the close',
                '${movesSince(drive.transport, mark)}',
              ),
            );
            expect(
              drive.feedback.recorded
                  .skip(cues)
                  .where((FeedbackCue c) => c == FeedbackCue.tap),
              isEmpty,
              reason: _why(
                id,
                'no tap cue from the close',
                '${drive.feedback.recorded.skip(cues).toList()}',
              ),
            );
          } finally {
            await _release(tester, drive);
          }
        },
      );
    }
  });

  // ------------------------------------------------------- negative arm
  group('guard a plain dropped connection is not a lost seat', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      for (final _Play play in <_Play>[_Play.move, _Play.roll]) {
        final String tag = '${play.name}.${locale.languageCode}';
        testWidgets('guard.drop.$tag: a plain drop on my turn still reads '
            'gameYourTurnStale with the countdown block and the header chip', (
          tester,
        ) async {
          final String id = 'guard.drop.$tag';
          final RollTrayDrive drive = await _mountPlay(tester, play, locale);
          try {
            await _farSideEnds(tester, drive);
            await tester.pump(const Duration(milliseconds: 400));
            expect(drive.controller.seatTakenOver, isFalse);
            final AppLocalizations loc = _loc(tester);
            final String saw = _gameNote(tester, drive.controller);
            expect(
              find.byKey(_turnBannerKey),
              findsOneWidget,
              reason: _why(id, 'the turn banner on a plain drop', saw),
            );
            expect(
              tester.widget<Text>(find.byKey(_turnBannerKey)).data,
              loc.gameYourTurnStale,
              reason: _why(
                id,
                'the banner to read "${loc.gameYourTurnStale}"',
                saw,
              ),
            );
            expect(
              find.byKey(_headerChipKey),
              findsOneWidget,
              reason: _why(id, 'the header chip on a plain drop', saw),
            );
            expect(
              find.byKey(_countdownDigitsKey),
              findsOneWidget,
              reason: _why(id, 'the countdown block on a plain drop', saw),
            );
            expect(
              find.byKey(_countdownRingKey),
              findsOneWidget,
              reason: _why(id, 'the countdown ring on a plain drop', saw),
            );
          } finally {
            await _release(tester, drive);
          }
        });
      }
    }
  });
}
