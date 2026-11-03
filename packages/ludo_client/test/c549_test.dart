// Proof for contract C-549
// (work/ludo/orders/C-549-waiting-lines-turn-and-say-more.md), written from
// the contract alone: D1 the waiting row turns and says more once it lasts,
// D2 reduced motion keeps the meaning, D3 the four rows that wait, D4 the
// game's desync banner speaks the game's words, D5 the strings.
//
// Every row is driven the way a phone drives it: a real RoomController over
// FakeTransport (test/net/fake_transport.dart, read-only here), a connector
// double copied from test/reconnecting_line_test.dart's idiom, one screen
// mount per case. The fake clock does the counting, so the 3.9 s and 4.1 s
// marks are exact and no case sleeps. Nothing here uses pumpAndSettle: the
// turning mark repeats forever and would never settle.
//
// The rows:
//   game     GameScreen's connection-lost body during an automatic sequence
//   overlay  LobbyScreen's stale-room overlay card (a room held, link lost)
//   closed   LobbyScreen's closed body (no room, a reconnect pending)
//   connect  LobbyScreen's connecting body (spinner, text, Cancel)
//
// Ambiguities, reported rather than invented around:
//
//   1. The closed row (no room held, autoReconnectPending true) cannot be
//      reached through a real controller: a sequence needs a room, and a
//      room is never dropped once held. This file reaches it the way
//      test/c533_test.dart does, with a RoomController subclass whose
//      autoReconnectPending is a flag the case flips. The same rig is the
//      only way to hold that row on screen at all, so its "flip" is a
//      rebuild storm (notifyListeners with nothing changed), not a change of
//      phase.
//
//   2. D1/D3 do not say which widget carries the key `waiting-line-slow`
//      (the Text or a wrapper). The cases accept either: the key must find
//      one widget that is, or contains, the Text with the exact string.
//
//   3. D1 says the mark "turns" without naming the widget. The cases read
//      the nearest Transform above the Icons.sync_rounded inside the row
//      (RotationTransition builds one), compare its matrix between pumps and
//      treat "no Transform at all" as a still mark. For D2 both a still
//      matrix and no Transform pass.
//
//   4. The leave-and-come-back cases need the row to leave and return with
//      the screen mounted throughout. The game and overlay rows do that
//      with a real resume answered and a second drop; the closed row does
//      it by flipping its flag. The connecting row has no way back into the
//      same body and is not part of those cases.
//
//   5. The "widget leaves no pending timer" case is proved by the framework's
//      own pending-timer and active-ticker checks plus a transientCallback
//      count; on a tree with no WaitingLine it holds trivially and is a
//      guard, not a red case.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c549-test.invalid/ws';
const String _code = 'K7M2QP';

/// The shape the sibling reconnect suites use: two entries are enough to
/// show a timer pending, an attempt in flight, and a fresh sequence after a
/// success.
const List<Duration> _delays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

const Key _slowKey = Key('waiting-line-slow');
const Key _gameLostKey = Key('game-screen-connection-lost');
const Key _gameReconnectingKey = Key('game-screen-reconnecting');
const Key _lobbyClosedKey = Key('lobby-closed');
const Key _lobbyReconnectingKey = Key('lobby-reconnecting');
const Key _lobbyConnectingKey = Key('lobby-connecting');
const Key _cancelKey = Key('lobby-cancel-button');
const Key _gameDesyncKey = Key('game-screen-desync-banner');
const Key _lobbyDesyncKey = Key('lobby-desync-banner');
const Key _resyncKey = Key('lobby-resync-button');

// The contract's exact texts (D5).
const String _slowEn = 'Taking longer than usual. Check your internet.';
const String _slowAr =
    'يستغرق الأمر وقتاً أطول من المعتاد. تحقّق من اتصال الإنترنت.';
const String _catchEn = 'Updating the table...';
const String _catchAr = 'جارٍ تحديث الطاولة...';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

String _slowFor(Locale locale) => locale == _ar ? _slowAr : _slowEn;
String _catchFor(Locale locale) => locale == _ar ? _catchAr : _catchEn;

/// The reason suffix every failure carries. There is no random seed: the
/// fake clock and the fixed [_delays] make a run deterministic, so the case
/// name is the whole reproduction.
String _reproduce(String id) =>
    'reproduce: cd packages/ludo_client && flutter test test/c549_test.dart '
    '--plain-name "$id"';

String _msg(String id, String text) => '$id: $text. ${_reproduce(id)}';

// --- server-side frames ------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c549-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {String name = ''}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  String state = 'LOBBY',
  int players = 4,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => <String, Object?>{
  'code': 'ABC234',
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
  'game_id': null,
  'client_seeds': null,
  'seats': seats ?? <Map<String, Object?>>[_seatJson(0, name: 'Sam')],
  'turn': turn,
  'winner': null,
  'seq': seq,
};

final List<Map<String, Object?>> _midGameSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

Map<String, Object?> _midGameTurn() => <String, Object?>{
  'seat': 0,
  'phase': 'await_roll',
  'deadline_ms': 45000,
  'k': 0,
};

// --- connector double --------------------------------------------------------

class _Connector {
  final List<FakeTransport?> _transports = <FakeTransport?>[];
  final List<Completer<WireTransport>?> _holds = <Completer<WireTransport>?>[];

  void enqueue(FakeTransport transport) {
    _transports.add(transport);
    _holds.add(null);
  }

  /// The next connect() never resolves on its own: the attempt stays in
  /// flight until the caller completes the returned completer.
  Completer<WireTransport> enqueueHold() {
    final Completer<WireTransport> completer = Completer<WireTransport>();
    _transports.add(null);
    _holds.add(completer);
    return completer;
  }

  Future<WireTransport> call(Uri url) async {
    if (_transports.isEmpty) {
      throw StateError('_Connector: connect() has nothing queued');
    }
    final FakeTransport? transport = _transports.removeAt(0);
    final Completer<WireTransport>? hold = _holds.removeAt(0);
    if (hold != null) {
      return hold.future;
    }
    return transport!;
  }
}

/// The closed row's controller, the shape test/c533_test.dart uses: a closed
/// controller with no room never schedules a sequence, so the flag the closed
/// body draws its line for is the one getter the case overrides.
class _PendingController extends RoomController {
  _PendingController({required super.serverUrl, required super.connect});

  bool pending = false;

  @override
  bool get autoReconnectPending => pending;

  void poke() => notifyListeners();
}

// --- harness -----------------------------------------------------------------

Widget _app(Widget home, {Locale locale = _en, bool reduceMotion = false}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: home,
  );
}

/// Drives a fresh controller through createRoom to a PLAYING snapshot with no
/// screen mounted, the order test/game_screen_connection_lost_test.dart uses.
Future<RoomController> _connectPlayingGame(
  WidgetTester tester,
  _Connector connector,
  FakeTransport transport, {
  List<Duration> autoReconnectDelays = const <Duration>[],
  bool sendSeatAssigned = true,
}) async {
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
  );
  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.pump();
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  if (sendSeatAssigned) {
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
      ),
    );
  }
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: 'PLAYING',
        players: 2,
        seats: _midGameSeats,
        turn: _midGameTurn(),
      ),
    ),
  );
  await future;
  return controller;
}

/// Mounts a fresh create lobby on [controller] and returns the create_room
/// id, the order test/lobby_stale_room_test.dart's _mountCreate runs in.
Future<String> _mountLobbyCreate(
  WidgetTester tester,
  RoomController controller,
  FakeTransport transport, {
  Locale locale = _en,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    _app(
      LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 4,
      ),
      locale: locale,
      reduceMotion: reduceMotion,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason: 'fixture is broken: LobbyScreen.initState must have sent create',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveLobbyConnected(
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

// --- reading the mark --------------------------------------------------------

/// The matrix of the nearest Transform above the sync mark inside the row
/// keyed [containerKey], or null when the mark has none (a still icon). The
/// search stops at the row's own widget.
List<double>? _rotation(WidgetTester tester, Key containerKey, String id) {
  final Finder mark = find.descendant(
    of: find.byKey(containerKey),
    matching: find.byIcon(Icons.sync_rounded),
  );
  expect(
    mark,
    findsOneWidget,
    reason: _msg(id, 'expected exactly one Icons.sync_rounded in the row'),
  );
  final Element boundary = tester.element(find.byKey(containerKey));
  Transform? found;
  tester.element(mark).visitAncestorElements((Element ancestor) {
    if (identical(ancestor, boundary)) {
      return false;
    }
    final Widget widget = ancestor.widget;
    if (widget is Transform) {
      found = widget;
      return false;
    }
    return true;
  });
  return found?.transform.storage.toList();
}

bool _sameMatrix(List<double>? a, List<double>? b) {
  if (a == null || b == null) {
    return a == null && b == null;
  }
  for (int i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 1e-6) {
      return false;
    }
  }
  return true;
}

String _show(List<double>? m) => m == null
    ? 'no Transform above the mark'
    : m.map((double v) => v.toStringAsFixed(4)).join(',');

// --- slow-line expectations --------------------------------------------------

void _expectNoSlow(WidgetTester tester, String id, String when) {
  expect(
    find.byKey(_slowKey),
    findsNothing,
    reason: _msg(
      id,
      'expected no slow line (Key waiting-line-slow) $when, but it is in '
      'the tree',
    ),
  );
  expect(
    find.text(_slowEn),
    findsNothing,
    reason: _msg(id, 'expected no connectionSlowLine text (en) $when'),
  );
  expect(
    find.text(_slowAr),
    findsNothing,
    reason: _msg(id, 'expected no connectionSlowLine text (ar) $when'),
  );
}

void _expectSlow(WidgetTester tester, String id, _Rig rig, String when) {
  final Finder line = find.byKey(_slowKey);
  expect(
    line,
    findsOneWidget,
    reason: _msg(
      id,
      'expected the slow line (Key waiting-line-slow) $when, found '
      '${line.evaluate().length}',
    ),
  );
  final String want = _slowFor(rig.locale);
  expect(
    find.text(want),
    findsOneWidget,
    reason: _msg(id, 'expected the exact slow text "$want" $when'),
  );
  final Widget widget = tester.widget(line);
  final String? data = widget is Text
      ? widget.data
      : tester
            .widget<Text>(
              find.descendant(of: line, matching: find.byType(Text)),
            )
            .data;
  expect(
    data,
    want,
    reason: _msg(id, 'the slow line must carry exactly "$want", got "$data"'),
  );
  expect(
    find.descendant(of: find.byKey(rig.containerKey), matching: line),
    findsOneWidget,
    reason: _msg(
      id,
      'the slow line must sit inside the row keyed ${rig.containerKey}',
    ),
  );
}

void _expectRow(WidgetTester tester, String id, _Rig rig, String when) {
  expect(
    find.byKey(rig.containerKey),
    findsOneWidget,
    reason: _msg(id, 'expected ${rig.containerKey} on screen $when'),
  );
  final Key? textKey = rig.textKey;
  if (textKey != null) {
    expect(
      find.byKey(textKey),
      findsOneWidget,
      reason: _msg(id, 'expected $textKey on screen $when'),
    );
  }
}

// --- the rows ----------------------------------------------------------------

abstract class _Rig {
  _Rig(this.tester, this.locale, {this.reduceMotion = false});

  final WidgetTester tester;
  final Locale locale;
  final bool reduceMotion;

  String get label;
  Key get containerKey;

  /// The Key on the Text that carries lobbyReconnecting, null for the
  /// connecting row, whose text is lobbyConnecting.
  Key? get textKey;

  bool get turns => textKey != null;

  /// Mounts the screen and returns with the row on screen for the first time.
  /// No fake time passes after the build that first draws the row.
  Future<void> open();

  /// One state flip inside the 4 s: timer pending to attempt in flight where
  /// the row has both, a rebuild otherwise. Returns the fake time consumed.
  Future<Duration> midway();

  /// The row leaves the screen because the connection came back.
  Future<void> recover();

  /// The row returns because the connection dropped again.
  Future<void> dropAgain();

  /// Releases the controller and anything it still holds.
  Future<void> close();

  Future<void> unmount() => tester.pumpWidget(const SizedBox.shrink());

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byKey(containerKey)));
}

class _GameRig extends _Rig {
  _GameRig(super.tester, super.locale, {super.reduceMotion});

  final _Connector connector = _Connector();
  late FakeTransport transport = FakeTransport();
  late final RoomController controller;
  Completer<WireTransport>? hold;

  @override
  String get label => 'game';
  @override
  Key get containerKey => _gameLostKey;
  @override
  Key? get textKey => _gameReconnectingKey;

  @override
  Future<void> open() async {
    connector.enqueue(transport);
    controller = await _connectPlayingGame(
      tester,
      connector,
      transport,
      autoReconnectDelays: _delays,
    );
    await tester.pumpWidget(
      _app(
        GameScreen(controller: controller),
        locale: locale,
        reduceMotion: reduceMotion,
      ),
    );
    await tester.pump();
    await dropAgain();
  }

  @override
  Future<Duration> midway() async {
    await tester.pump(_delays[0]);
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connecting,
      reason:
          'fixture is broken: the timer firing into a held connector must '
          'leave the phase at connecting',
    );
    return _delays[0];
  }

  @override
  Future<void> recover() async {
    final FakeTransport next = FakeTransport();
    hold!.complete(next);
    await tester.pump();
    await tester.pump();
    expect(next.sentRaw, isNotEmpty, reason: 'fixture: resume must be sent');
    expect(_typeOf(next.sentRaw.last), 'resume');
    next.pushText(
      _frame(
        type: 'room',
        re: _idOf(next.sentRaw.last),
        data: _roomJson(
          state: 'PLAYING',
          players: 2,
          seats: _midGameSeats,
          turn: _midGameTurn(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(controller.phase, RoomPhase.connected);
    transport = next;
    hold = null;
  }

  @override
  Future<void> dropAgain() async {
    hold = connector.enqueueHold();
    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(controller.phase, RoomPhase.closed);
    expect(controller.autoReconnectPending, isTrue);
  }

  @override
  Future<void> close() async {
    final Completer<WireTransport>? held = hold;
    if (held != null && !held.isCompleted) {
      held.complete(FakeTransport());
    }
    await tester.pump();
    controller.dispose();
  }
}

class _OverlayRig extends _Rig {
  _OverlayRig(super.tester, super.locale, {super.reduceMotion});

  final _Connector connector = _Connector();
  late FakeTransport transport = FakeTransport();
  late final RoomController controller;
  Completer<WireTransport>? hold;

  @override
  String get label => 'overlay';
  @override
  Key get containerKey => _lobbyClosedKey;
  @override
  Key? get textKey => _lobbyReconnectingKey;

  @override
  Future<void> open() async {
    connector.enqueue(transport);
    controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
      autoReconnectDelays: _delays,
    );
    final String id = await _mountLobbyCreate(
      tester,
      controller,
      transport,
      locale: locale,
      reduceMotion: reduceMotion,
    );
    await _resolveLobbyConnected(tester, transport, id);
    expect(controller.phase, RoomPhase.connected);
    await dropAgain();
  }

  @override
  Future<Duration> midway() async {
    await tester.pump(_delays[0]);
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connecting,
      reason:
          'fixture is broken: the timer firing into a held connector must '
          'leave the phase at connecting',
    );
    return _delays[0];
  }

  @override
  Future<void> recover() async {
    final FakeTransport next = FakeTransport();
    hold!.complete(next);
    await tester.pump();
    await tester.pump();
    expect(next.sentRaw, isNotEmpty, reason: 'fixture: resume must be sent');
    expect(_typeOf(next.sentRaw.last), 'resume');
    next.pushText(
      _frame(type: 'room', re: _idOf(next.sentRaw.last), data: _roomJson()),
    );
    await tester.pump();
    await tester.pump();
    expect(controller.phase, RoomPhase.connected);
    transport = next;
    hold = null;
  }

  @override
  Future<void> dropAgain() async {
    hold = connector.enqueueHold();
    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(controller.phase, RoomPhase.closed);
    expect(controller.autoReconnectPending, isTrue);
  }

  @override
  Future<void> close() async {
    final Completer<WireTransport>? held = hold;
    if (held != null && !held.isCompleted) {
      held.complete(FakeTransport());
    }
    await tester.pump();
    controller.dispose();
  }
}

class _ClosedRig extends _Rig {
  _ClosedRig(super.tester, super.locale, {super.reduceMotion});

  final FakeTransport transport = FakeTransport();
  late final _PendingController controller;

  @override
  String get label => 'closed';
  @override
  Key get containerKey => _lobbyClosedKey;
  @override
  Key? get textKey => _lobbyReconnectingKey;

  @override
  Future<void> open() async {
    controller = _PendingController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    await tester.pumpWidget(
      _app(
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: _code,
          playerName: 'Sam',
        ),
        locale: locale,
        reduceMotion: reduceMotion,
      ),
    );
    await tester.pump();
    await tester.pump();
    // Leaving while the join is unanswered closes the controller with no
    // room held, the closed body with nothing pending.
    final Future<void> left = controller.leave();
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await left;
    expect(controller.room, isNull);
    expect(controller.phase, RoomPhase.closed);
    await dropAgain();
  }

  @override
  Future<Duration> midway() async {
    for (int i = 0; i < 3; i++) {
      controller.poke();
      await tester.pump(const Duration(milliseconds: 500));
    }
    return const Duration(milliseconds: 1500);
  }

  @override
  Future<void> recover() async {
    controller.pending = false;
    controller.poke();
    await tester.pump();
  }

  @override
  Future<void> dropAgain() async {
    controller.pending = true;
    controller.poke();
    await tester.pump();
  }

  @override
  Future<void> close() async {
    controller.dispose();
  }
}

class _ConnectRig extends _Rig {
  _ConnectRig(super.tester, super.locale, {super.reduceMotion});

  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  late final RoomController controller;

  @override
  String get label => 'connect';
  @override
  Key get containerKey => _lobbyConnectingKey;
  @override
  Key? get textKey => null;

  @override
  Future<void> open() async {
    connector.enqueue(transport);
    controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: connector.call,
    );
    await _mountLobbyCreate(
      tester,
      controller,
      transport,
      locale: locale,
      reduceMotion: reduceMotion,
    );
    expect(
      controller.phase,
      anyOf(RoomPhase.idle, RoomPhase.connecting),
      reason: 'fixture is broken: the create request must be unanswered',
    );
    expect(controller.room, isNull);
  }

  @override
  Future<Duration> midway() async => Duration.zero;

  @override
  Future<void> recover() => throw UnsupportedError('connect row stays put');

  @override
  Future<void> dropAgain() => throw UnsupportedError('connect row stays put');

  @override
  Future<void> close() async {
    controller.dispose();
  }
}

typedef _RigFactory = _Rig Function(
  WidgetTester tester,
  Locale locale,
  bool reduceMotion,
);

final Map<String, _RigFactory> _allRows = <String, _RigFactory>{
  'game': (t, l, r) => _GameRig(t, l, reduceMotion: r),
  'overlay': (t, l, r) => _OverlayRig(t, l, reduceMotion: r),
  'closed': (t, l, r) => _ClosedRig(t, l, reduceMotion: r),
  'connect': (t, l, r) => _ConnectRig(t, l, reduceMotion: r),
};

final Map<String, _RigFactory> _reconnectingRows = <String, _RigFactory>{
  for (final MapEntry<String, _RigFactory> e in _allRows.entries)
    if (e.key != 'connect') e.key: e.value,
};

/// A row that can leave and come back with the screen mounted throughout.
final Map<String, _RigFactory> _comingBackRows = _reconnectingRows;

String _tag(Locale locale) => locale.languageCode;

/// 3.9 s after the row first appeared there is no slow line, 4.1 s after
/// there is. [used] is the fake time the flip already spent.
Future<void> _expectFourSecondMark(
  WidgetTester tester,
  String id,
  _Rig rig,
  Duration used,
) async {
  await tester.pump(const Duration(milliseconds: 3900) - used);
  _expectRow(tester, id, rig, 'at 3.9 s');
  _expectNoSlow(tester, id, 'at 3.9 s after the row first appeared');
  await tester.pump(const Duration(milliseconds: 200));
  _expectRow(tester, id, rig, 'at 4.1 s');
  _expectSlow(tester, id, rig, 'at 4.1 s after the row first appeared');
}

void main() {
  // ==========================================================================
  // D1 / D3: the slow line at 4 s, counted from the first mount, across a flip
  // ==========================================================================
  group('D1 D3: the slow line comes at 4 s, not before', () {
    for (final MapEntry<String, _RigFactory> row in _allRows.entries) {
      for (final Locale locale in _locales) {
        final String id =
            'D1 ${row.key} ${_tag(locale)}: no slow line at 3.9 s, the '
            'exact line at 4.1 s, with a flip inside the 4 s';
        testWidgets(id, (tester) async {
          final _Rig rig = row.value(tester, locale, false);
          try {
            await rig.open();
            _expectRow(tester, id, rig, 'when first shown');
            _expectNoSlow(tester, id, 'the moment the row first appeared');
            final Duration used = await rig.midway();
            _expectRow(tester, id, rig, 'after the flip');
            await _expectFourSecondMark(tester, id, rig, used);
            // Staying up: one line, not a second one per rebuild.
            await tester.pump(const Duration(seconds: 2));
            _expectSlow(tester, id, rig, 'at 6.1 s, still up and still one');
          } finally {
            await rig.close();
          }
        });
      }
    }
  });

  group('D3: the rows keep their text Keys and say it through WaitingLine', () {
    for (final MapEntry<String, _RigFactory> row in _reconnectingRows.entries) {
      for (final Locale locale in _locales) {
        final String id =
            'D3 ${row.key} ${_tag(locale)}: the text Key finds the '
            'lobbyReconnecting Text, inside a WaitingLine';
        testWidgets(id, (tester) async {
          final _Rig rig = row.value(tester, locale, false);
          try {
            await rig.open();
            final Key key = rig.textKey!;
            final Finder line = find.byKey(key);
            expect(
              line,
              findsOneWidget,
              reason: _msg(id, 'expected $key on screen'),
            );
            final Widget widget = tester.widget(line);
            expect(
              widget,
              isA<Text>(),
              reason: _msg(
                id,
                'the key must sit on the Text that carries '
                'lobbyReconnecting, found ${widget.runtimeType}',
              ),
            );
            final AppLocalizations loc = rig.loc;
            expect(loc.localeName, locale.languageCode);
            expect(
              (widget as Text).data,
              loc.lobbyReconnecting,
              reason: _msg(id, 'the text must be lobbyReconnecting'),
            );
            expect(
              find.ancestor(
                of: line,
                matching: find.byWidgetPredicate(
                  (Widget w) => w.runtimeType.toString() == 'WaitingLine',
                  description: 'a WaitingLine',
                ),
              ),
              findsOneWidget,
              reason: _msg(
                id,
                'D3: the row must be a WaitingLine (the public widget of '
                'lib/src/waiting_line.dart) around the text',
              ),
            );
            expect(
              find.descendant(
                of: find.byKey(rig.containerKey),
                matching: find.byIcon(Icons.sync_rounded),
              ),
              findsOneWidget,
              reason: _msg(id, 'one sync mark in the row'),
            );
          } finally {
            await rig.close();
          }
        });
      }
    }

    for (final Locale locale in _locales) {
      final String id =
          'D3 connect ${_tag(locale)}: the connecting body keeps its text '
          'under lobby-connecting, its Cancel, and one turning mark (the '
          'spinner)';
      testWidgets(id, (tester) async {
        final _Rig rig = _ConnectRig(tester, locale);
        try {
          await rig.open();
          final AppLocalizations loc = rig.loc;
          expect(loc.localeName, locale.languageCode);
          expect(
            find.descendant(
              of: find.byKey(_lobbyConnectingKey),
              matching: find.text(loc.lobbyConnecting),
            ),
            findsOneWidget,
            reason: _msg(id, 'lobby-connecting must hold lobbyConnecting'),
          );
          expect(
            find.descendant(
              of: find.byKey(_lobbyConnectingKey),
              matching: find.byKey(_cancelKey),
            ),
            findsOneWidget,
            reason: _msg(id, 'the Cancel button stays'),
          );
          expect(
            find.descendant(
              of: find.byKey(_lobbyConnectingKey),
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
            reason: _msg(id, 'the spinner stays'),
          );
          expect(
            find.descendant(
              of: find.byKey(_lobbyConnectingKey),
              matching: find.byIcon(Icons.sync_rounded),
            ),
            findsNothing,
            reason: _msg(
              id,
              'the spinner is the one turning mark in the connecting body; '
              'a sync mark beside it would draw two',
            ),
          );
        } finally {
          await rig.close();
        }
      });
    }
  });

  // ==========================================================================
  // D1: the mark turns, one full turn per 1200 ms
  // ==========================================================================
  group('D1: the sync mark turns', () {
    for (final MapEntry<String, _RigFactory> row in _reconnectingRows.entries) {
      for (final Locale locale in _locales) {
        final String turnId =
            'D1 ${row.key} ${_tag(locale)}: the mark rotates between two '
            'pumps 100 ms apart';
        testWidgets(turnId, (tester) async {
          final _Rig rig = row.value(tester, locale, false);
          try {
            await rig.open();
            final List<double>? first = _rotation(
              tester,
              rig.containerKey,
              turnId,
            );
            await tester.pump(const Duration(milliseconds: 100));
            final List<double>? second = _rotation(
              tester,
              rig.containerKey,
              turnId,
            );
            expect(
              first,
              isNotNull,
              reason: _msg(
                turnId,
                'the sync mark must sit under a rotating Transform '
                '(RotationTransition); there is none, so it is still',
              ),
            );
            expect(
              _sameMatrix(first, second),
              isFalse,
              reason: _msg(
                turnId,
                'the rotation must change in 100 ms; saw ${_show(first)} '
                'then ${_show(second)}',
              ),
            );
          } finally {
            await rig.close();
          }
        });

        final String periodId =
            'D1 ${row.key} ${_tag(locale)}: one full turn per 1200 ms, '
            'repeating';
        testWidgets(periodId, (tester) async {
          final _Rig rig = row.value(tester, locale, false);
          try {
            await rig.open();
            final List<double>? start = _rotation(
              tester,
              rig.containerKey,
              periodId,
            );
            await tester.pump(const Duration(milliseconds: 600));
            final List<double>? half = _rotation(
              tester,
              rig.containerKey,
              periodId,
            );
            await tester.pump(const Duration(milliseconds: 600));
            final List<double>? full = _rotation(
              tester,
              rig.containerKey,
              periodId,
            );
            await tester.pump(const Duration(milliseconds: 1200));
            final List<double>? again = _rotation(
              tester,
              rig.containerKey,
              periodId,
            );
            expect(
              start,
              isNotNull,
              reason: _msg(periodId, 'the mark must be turning at all'),
            );
            expect(
              _sameMatrix(start, half),
              isFalse,
              reason: _msg(
                periodId,
                'half a period in, the mark must have moved; start '
                '${_show(start)}, at 600 ms ${_show(half)}',
              ),
            );
            expect(
              _sameMatrix(start, full),
              isTrue,
              reason: _msg(
                periodId,
                'after 1200 ms the mark must be back where it started; '
                'start ${_show(start)}, at 1200 ms ${_show(full)}',
              ),
            );
            expect(
              _sameMatrix(start, again),
              isTrue,
              reason: _msg(
                periodId,
                'the turn repeats: at 2400 ms the mark must be at the '
                'start again; start ${_show(start)}, got ${_show(again)}',
              ),
            );
          } finally {
            await rig.close();
          }
        });
      }
    }
  });

  // ==========================================================================
  // D2: reduced motion keeps the meaning
  // ==========================================================================
  group('D2: disableAnimations stills the mark, the line still comes', () {
    for (final MapEntry<String, _RigFactory> row in _allRows.entries) {
      for (final Locale locale in _locales) {
        final String id =
            'D2 ${row.key} ${_tag(locale)}: with disableAnimations the mark '
            'does not turn and the slow line still appears at 4.1 s';
        testWidgets(id, (tester) async {
          final _Rig rig = row.value(tester, locale, true);
          try {
            await rig.open();
            expect(
              MediaQuery.disableAnimationsOf(
                tester.element(find.byKey(rig.containerKey)),
              ),
              isTrue,
              reason: 'fixture is broken: disableAnimations must be true',
            );
            Duration used = Duration.zero;
            if (rig.turns) {
              final List<double>? first = _rotation(
                tester,
                rig.containerKey,
                id,
              );
              await tester.pump(const Duration(milliseconds: 100));
              final List<double>? second = _rotation(
                tester,
                rig.containerKey,
                id,
              );
              await tester.pump(const Duration(milliseconds: 500));
              final List<double>? third = _rotation(
                tester,
                rig.containerKey,
                id,
              );
              expect(
                _sameMatrix(first, second) && _sameMatrix(first, third),
                isTrue,
                reason: _msg(
                  id,
                  'the mark must stay still: ${_show(first)}, then '
                  '${_show(second)} at 100 ms, then ${_show(third)} at '
                  '600 ms',
                ),
              );
              used = const Duration(milliseconds: 600);
            } else {
              expect(
                find.byIcon(Icons.sync_rounded),
                findsNothing,
                reason: _msg(id, 'the connecting body draws no sync mark'),
              );
            }
            await _expectFourSecondMark(tester, id, rig, used);
          } finally {
            await rig.close();
          }
        });
      }
    }
  });

  // ==========================================================================
  // Leaving the row and coming back starts a fresh count; no timer survives
  // ==========================================================================
  group(
    'D1: a row that left and came back counts from its own first mount',
    () {
      for (final MapEntry<String, _RigFactory> row in _comingBackRows.entries) {
        for (final Locale locale in _locales) {
          for (final int firstRunMs in <int>[3000, 5000]) {
            final String id =
                'D1 ${row.key} ${_tag(locale)}: the row leaves after '
                '${firstRunMs / 1000} s and returns; the new count starts at '
                'the return';
            testWidgets(id, (tester) async {
              final _Rig rig = row.value(tester, locale, false);
              try {
                await rig.open();
                final Duration used = await rig.midway();
                await tester.pump(Duration(milliseconds: firstRunMs) - used);
                if (firstRunMs > 4000) {
                  _expectSlow(
                    tester,
                    id,
                    rig,
                    'at ${firstRunMs / 1000} s of the first run',
                  );
                } else {
                  _expectNoSlow(
                    tester,
                    id,
                    'at ${firstRunMs / 1000} s of the first run',
                  );
                }

                await rig.recover();
                expect(
                  find.byKey(rig.textKey!),
                  findsNothing,
                  reason: _msg(id, 'fixture: the row must be gone once back'),
                );
                _expectNoSlow(tester, id, 'once the connection recovered');
                await tester.pump(const Duration(seconds: 1));
                _expectNoSlow(tester, id, 'a second after the recovery');

                await rig.dropAgain();
                _expectRow(tester, id, rig, 'on its return');
                _expectNoSlow(
                  tester,
                  id,
                  'the moment the row returned (no leftover of the first run)',
                );
                final Duration again = await rig.midway();
                await _expectFourSecondMark(tester, id, rig, again);
              } finally {
                await rig.close();
              }
            });
          }
        }
      }
    },
  );

  group('D1: the row leaves nothing running behind it', () {
    for (final MapEntry<String, _RigFactory> row in _allRows.entries) {
      for (final Locale locale in _locales) {
        final String id =
            'D1 ${row.key} ${_tag(locale)}: unmounted at 1 s, no slow line '
            'comes later, no ticker or timer is left';
        testWidgets(id, (tester) async {
          final _Rig rig = row.value(tester, locale, false);
          try {
            await rig.open();
            await tester.pump(const Duration(seconds: 1));
            _expectRow(tester, id, rig, 'at 1 s');
            await rig.unmount();
            await tester.pump(const Duration(seconds: 6));
            _expectNoSlow(tester, id, 'after the tree was disposed');
            expect(
              tester.binding.transientCallbackCount,
              0,
              reason: _msg(
                id,
                'a turning mark left a ticker running after its tree was '
                'disposed',
              ),
            );
          } finally {
            await rig.close();
          }
          // The framework's pending-timer check runs when this body returns:
          // a WaitingLine timer left armed fails the case there.
        });
      }
    }
  });

  // ==========================================================================
  // D4: the game's desync banner speaks the game's words
  // ==========================================================================
  group('D4: the desync banner', () {
    for (final Locale locale in _locales) {
      final String id =
          'D4 game ${_tag(locale)}: hasDesynced shows gameCatchingUp in '
          'game-screen-desync-banner and not lobbyDesynced';
      testWidgets(id, (tester) async {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        // No seat_assigned: with no seat token the gap sets hasDesynced and
        // sends no resume, leaving no request timer outstanding.
        final RoomController controller = await _connectPlayingGame(
          tester,
          connector,
          transport,
          sendSeatAssigned: false,
        );
        try {
          transport.pushText(
            _frame(
              type: 'presence',
              data: <String, Object?>{
                'seat': 0,
                'connected': false,
                'seq': 999,
              },
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(
            controller.hasDesynced,
            isTrue,
            reason: 'fixture is broken: the seq gap must set hasDesynced',
          );
          await tester.pumpWidget(
            _app(GameScreen(controller: controller), locale: locale),
          );
          await tester.pump();

          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(GameScreen)),
          );
          expect(loc.localeName, locale.languageCode);
          final Finder banner = find.byKey(_gameDesyncKey);
          expect(
            banner,
            findsOneWidget,
            reason: _msg(id, 'hasDesynced must show the banner'),
          );
          expect(
            tester.widget<Text>(banner).data,
            _catchFor(locale),
            reason: _msg(
              id,
              'the game banner must say "${_catchFor(locale)}", not '
              '"${tester.widget<Text>(banner).data}"',
            ),
          );
          expect(
            find.text(loc.lobbyDesynced),
            findsNothing,
            reason: _msg(
              id,
              'the lobby wording "${loc.lobbyDesynced}" must not appear on '
              'the game screen',
            ),
          );
          expect(
            find.byKey(_resyncKey),
            findsNothing,
            reason: _msg(id, 'the game screen offers no Resync button'),
          );
        } finally {
          controller.dispose();
        }
      });

      final String lobbyId =
          'D4 lobby ${_tag(locale)}: the lobby banner still says '
          'lobbyDesynced and keeps its Resync button';
      testWidgets(lobbyId, (tester) async {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        try {
          final String createId = await _mountLobbyCreate(
            tester,
            controller,
            transport,
            locale: locale,
          );
          await _resolveLobbyConnected(tester, transport, createId);
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
            reason: 'fixture is broken: the seq gap must set hasDesynced',
          );

          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(LobbyScreen)),
          );
          expect(loc.localeName, locale.languageCode);
          expect(
            find.descendant(
              of: find.byKey(_lobbyDesyncKey),
              matching: find.text(loc.lobbyDesynced),
            ),
            findsOneWidget,
            reason: _msg(lobbyId, 'the lobby banner keeps lobbyDesynced'),
          );
          expect(
            find.descendant(
              of: find.byKey(_lobbyDesyncKey),
              matching: find.byKey(_resyncKey),
            ),
            findsOneWidget,
            reason: _msg(lobbyId, 'the lobby banner keeps its Resync button'),
          );
          expect(
            find.text(_catchFor(locale)),
            findsNothing,
            reason: _msg(
              lobbyId,
              'the game wording must not leak into the lobby banner',
            ),
          );

          // The gap also sent a resume on the open socket; answer it so no
          // request timer is left for the framework's pending-timer check.
          expect(_typeOf(transport.sentRaw.last), 'resume');
          transport.pushText(
            _frame(
              type: 'room',
              re: _idOf(transport.sentRaw.last),
              data: _roomJson(),
            ),
          );
          await tester.pump();
          await tester.pump();
        } finally {
          controller.dispose();
        }
      });
    }
  });

  // ==========================================================================
  // D5: the strings
  // ==========================================================================
  group('D5: the strings', () {
    Map<String, Object?> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, Object?>;

    test('D5: app_en.arb carries both keys with the exact texts and an @ '
        'description each', () {
      final Map<String, Object?> en = arb('en');
      expect(
        en['connectionSlowLine'],
        _slowEn,
        reason: 'app_en.arb connectionSlowLine must be "$_slowEn"',
      );
      expect(
        en['gameCatchingUp'],
        _catchEn,
        reason: 'app_en.arb gameCatchingUp must be "$_catchEn"',
      );
      for (final String key in <String>[
        'connectionSlowLine',
        'gameCatchingUp',
      ]) {
        final Object? meta = en['@$key'];
        expect(
          meta,
          isA<Map<String, Object?>>(),
          reason: 'app_en.arb must carry an @$key entry',
        );
        final Object? description =
            (meta as Map<String, Object?>)['description'];
        expect(
          description,
          isA<String>().having((String s) => s.trim(), 'text', isNotEmpty),
          reason: 'app_en.arb @$key must carry a non-empty description',
        );
      }
    });

    test('D5: app_ar.arb carries both keys with the exact texts', () {
      final Map<String, Object?> ar = arb('ar');
      expect(
        ar['connectionSlowLine'],
        _slowAr,
        reason: 'app_ar.arb connectionSlowLine must be "$_slowAr"',
      );
      expect(
        ar['gameCatchingUp'],
        _catchAr,
        reason: 'app_ar.arb gameCatchingUp must be "$_catchAr"',
      );
    });
  });
}
