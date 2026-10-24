// Proof for contract C-451 D6 and D7 (work/ludo/orders/C-451-a-live-game-is-
// never-reaped.md): while a phone is connected to a live game, Home keeps the
// stored seat record fresh, so a phone killed late in a long game still comes
// back to it.
//
// Written from the contract and from test/relaunch_back_to_game_test.dart's
// rig (copied, not imported: its helpers are private). Nothing here was
// derived from the body of home_screen.dart.
//
// Case ids follow the contract's client tests:
//   C1a..C1c, C1e   a notification inside the refresh interval leaves
//                   session.seatSavedAt alone; one at or past it rewrites it
//   C1d             kSeatRecordRefresh is public and one minute
//   C2w, C2r        a record kept fresh for 70 minutes, then a relaunch five
//                   minutes after the last notification resumes
//   C3              no write once the room is FINISHED
//   C4              the record's three strings never change across refreshes
//
// C2 is split in two cases because every case in the relaunch file mounts one
// Home, and the lesson for this suite is one mount per case: C2w mounts, plays
// 70 minutes on the injected clock and asserts what is stored (and what a
// relaunch five minutes later would read from it); C2r seeds a store that
// holds exactly the time C2w ends with and mounts a fresh Home five minutes
// after it. The two share the constants below, so they describe one scenario.
//
// Time: Home is built with HomeScreen.clock, a clock the case moves by hand.
// The widget tester's own fake clock only moves in bounded pumps and is not
// the clock under test. Notifications are `room` pushes with the next seq.
//
// Reproduce any case alone with
//   flutter test test/seat_record_refresh_test.dart --plain-name '<case id>'
// The scenarios are deterministic: there is no seed.
//
// Hygiene: one pumpWidget per case; every pump is bounded (the game screen's
// countdown ticks forever, so pumpAndSettle would never return); the tree is
// unmounted and the controllers disposed in the body.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show RoomState;
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://seat-refresh-test.invalid/ws';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

const String _kCode = 'K7M2QP';
const int _kSeat = 2;
const String _kToken = 'tok-refresh-seed-001';

/// The contract's D6 value, spelled out so the behaviour cases do not depend
/// on the public name (C1d pins the name).
const Duration _oneMinute = Duration(minutes: 1);

/// Where the injected clock starts.
final DateTime _base = DateTime.utc(2026, 10, 24, 12);

/// C2: how long the game plays with the phone connected, and how long after
/// the last notification the phone comes back.
const Duration _gameLength = Duration(minutes: 70);
const Duration _killedFor = Duration(minutes: 5);

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'refresh-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  bool connected = true,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  required int seq,
  String state = 'PLAYING',
  bool hostConnected = true,
}) {
  final bool finished = state == 'FINISHED';
  return <String, Object?>{
    'code': _kCode,
    'state': state,
    'host_seat': 0,
    'players': 2,
    'rules': const <String, Object?>{
      'blocks': false,
      'capture_bonus': true,
      'turn_seconds': 45,
    },
    'chain_commit': 'a' * 64,
    'chain_index': 0,
    'game_id': 'g' * 16,
    'client_seeds': '0:seed',
    'seats': <Map<String, Object?>>[
      _seatJson(0, name: 'Host', connected: hostConnected),
      _seatJson(_kSeat, name: 'Rejoiner'),
    ],
    'turn': finished
        ? null
        : const <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
    'winner': finished ? 0 : null,
    if (finished) 'verify_url': 'https://verify.invalid/g/gggggggggggggggg',
    'seq': seq,
  };
}

/// A controller that remembers whether [dispose] has run: Home disposes the
/// controllers it owns when a route pops, and a second dispose throws.
class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class _Factory {
  final List<_TrackedController> controllers = <_TrackedController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final _TrackedController created = _TrackedController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }

  List<String> get allTypes => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw) _typeOf(s),
  ];

  void disposeAll() {
    for (final _TrackedController controller in controllers) {
      if (!controller.wasDisposed) {
        controller.dispose();
      }
    }
  }
}

/// The clock Home is built with, moved by hand.
class _Clock {
  DateTime now = _base;

  DateTime read() => now;
}

Widget _app(RoomControllerFactory factory, DateTime Function() clock) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: factory,
      clock: clock,
    ),
  );
}

/// Bounded pumps only: long enough for the load and a pushed route's
/// transition, never pumpAndSettle.
Future<void> _pumpBounded(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// Lets the unawaited store writes Home started finish, on the real event
/// loop, so a read after it sees every write that was going to happen.
Future<void> _drainStore(WidgetTester tester) async {
  await tester.runAsync(() => pumpEventQueue());
}

Future<int?> _storedSavedAtMillis() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_savedAtPrefsKey);
}

Future<List<String>?> _storedSeat() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_seatPrefsKey);
}

String _offset(int? millis) {
  if (millis == null) {
    return 'absent';
  }
  final double seconds = (millis - _base.millisecondsSinceEpoch) / 1000;
  return 't+${seconds.toStringAsFixed(3)}s';
}

int _millisAt(Duration sinceBase) =>
    _base.add(sinceBase).millisecondsSinceEpoch;

String _repro(String id) =>
    'reproduce: flutter test test/seat_record_refresh_test.dart '
    "--plain-name '$id'";

void _seedRecord({required Duration savedAtSinceBase}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _seatPrefsKey: <String>[_kCode, _kSeat.toString(), _kToken],
    _savedAtPrefsKey: _millisAt(savedAtSinceBase),
  });
}

/// One mounted Home with a resumed PLAYING game on top of it and the
/// injected clock at [_base]. Home wrote the record when the room arrived;
/// [notifyAt] sends one more `room` push after moving the clock.
class _Game {
  _Game(this.tester, this.id, this.factory, this.clock);

  final WidgetTester tester;
  final String id;
  final _Factory factory;
  final _Clock clock;
  int seq = 5;
  int notifications = 0;

  FakeTransport get transport => factory.transports.single;
  RoomController get controller => factory.controllers.single;

  /// Mounts Home over a record saved five minutes before [_base] (so the
  /// resume is accepted, C-447 D3), answers the automatic resume with a
  /// PLAYING room and checks the fixture: the first write is at [_base].
  static Future<_Game> start(WidgetTester tester, String id) async {
    _seedRecord(savedAtSinceBase: -const Duration(minutes: 5));
    final _Factory factory = _Factory();
    final _Clock clock = _Clock();
    await tester.pumpWidget(_app(factory.call, clock.read));
    await _pumpBounded(tester);

    final _Game game = _Game(tester, id, factory, clock);
    expect(
      factory.allTypes,
      <String>['resume'],
      reason:
          '$id fixture: the seeded record must resume exactly once; sent '
          '${factory.allTypes}. ${_repro(id)}',
    );
    final String resumeId = _idOf(factory.transports.single.sentRaw.single);
    expect(_dataOf(factory.transports.single.sentRaw.single), <String, Object?>{
      'code': _kCode,
      'seat_token': _kToken,
    }, reason: '$id fixture: the resume must carry the seeded code and token');
    game.controller.addListener(() => game.notifications += 1);
    game.transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': _kSeat, 'seat_token': _kToken},
      ),
    );
    game.transport.pushText(
      _frame(
        type: 'room',
        re: resumeId,
        data: _roomJson(seq: game.seq),
      ),
    );
    await _pumpBounded(tester, frames: 4);
    await _drainStore(tester);

    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: '$id fixture: the PLAYING room must put the game on screen',
    );
    await game.expectSaved(
      Duration.zero,
      what: 'fixture: the record is written when the resumed room arrives',
    );
    return game;
  }

  /// Moves the clock to [sinceBase] and delivers one more `room` push (the
  /// next seq), which notifies the owned controller once. The `room` is
  /// PLAYING unless [state] says otherwise.
  Future<void> notifyAt(
    Duration sinceBase, {
    String state = 'PLAYING',
    bool hostConnected = true,
  }) async {
    clock.now = _base.add(sinceBase);
    final int before = notifications;
    seq += 1;
    transport.pushText(
      _frame(
        type: 'room',
        data: _roomJson(seq: seq, state: state, hostConnected: hostConnected),
      ),
    );
    await tester.pump();
    await tester.pump();
    await _drainStore(tester);
    expect(
      notifications,
      before + 1,
      reason:
          '$id fixture: the room push at ${_offset(_millisAt(sinceBase))} '
          'must notify the controller exactly once; it notified '
          '${notifications - before} times',
    );
  }

  /// Asserts the stored saved time is exactly [sinceBase] after [_base].
  Future<void> expectSaved(Duration sinceBase, {required String what}) async {
    final int? stored = await _storedSavedAtMillis();
    expect(
      stored,
      _millisAt(sinceBase),
      reason:
          '$id: $what. expected session.seatSavedAt '
          '${_offset(_millisAt(sinceBase))}, stored ${_offset(stored)}. '
          '${_repro(id)}',
    );
  }

  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    factory.disposeAll();
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- C1
  testWidgets('C1a (D6): notifications 30 s and 59 s after a write leave '
      'session.seatSavedAt unchanged', (tester) async {
    const String id =
        'C1a (D6): notifications 30 s and 59 s after a write '
        'leave session.seatSavedAt unchanged';
    final _Game game = await _Game.start(tester, id);

    await game.notifyAt(const Duration(seconds: 30));
    await game.expectSaved(
      Duration.zero,
      what:
          'a notification 30 s after the write must not write again '
          '(D6: nothing else writes more often)',
    );
    await game.notifyAt(const Duration(seconds: 31));
    await game.notifyAt(const Duration(seconds: 45));
    await game.notifyAt(const Duration(seconds: 59));
    await game.expectSaved(
      Duration.zero,
      what:
          'four notifications inside the first minute, the last at 59 s, '
          'must leave the first write in place',
    );

    await game.finish();
  });

  testWidgets('C1b (D6): a notification 61 s after the write rewrites it to '
      'the new now; the next one is measured from that write', (tester) async {
    const String id =
        'C1b (D6): a notification 61 s after the write rewrites '
        'it to the new now; the next one is measured from that write';
    final _Game game = await _Game.start(tester, id);

    await game.notifyAt(const Duration(seconds: 30));
    await game.notifyAt(const Duration(seconds: 61));
    await game.expectSaved(
      const Duration(seconds: 61),
      what: 'a notification 61 s after the write must rewrite the saved time',
    );

    await game.notifyAt(const Duration(seconds: 90));
    await game.expectSaved(
      const Duration(seconds: 61),
      what:
          'a notification 29 s after the second write must not write: the '
          'interval runs from the last write, not from the first',
    );

    await game.notifyAt(const Duration(seconds: 121));
    await game.expectSaved(
      const Duration(seconds: 121),
      what:
          'a notification 60 s after the second write must write a third '
          'time',
    );

    await game.finish();
  });

  testWidgets('C1c (D6): the boundary is "at least" the interval: 59.999 s '
      'does not write, 60 s does', (tester) async {
    const String id =
        'C1c (D6): the boundary is "at least" the interval: '
        '59.999 s does not write, 60 s does';
    final _Game game = await _Game.start(tester, id);

    await game.notifyAt(_oneMinute - const Duration(milliseconds: 1));
    await game.expectSaved(
      Duration.zero,
      what: 'a notification 59.999 s after the write must not write',
    );

    await game.notifyAt(_oneMinute);
    await game.expectSaved(
      _oneMinute,
      what:
          'a notification exactly one minute after the write must write '
          '(D6: "at least")',
    );

    await game.finish();
  });

  test('C1d (D6): kSeatRecordRefresh is public and is one minute', () {
    const String id =
        'C1d (D6): kSeatRecordRefresh is public and is one '
        'minute';
    expect(
      kSeatRecordRefresh,
      _oneMinute,
      reason:
          '$id. expected Duration(minutes: 1) exported by '
          'lib/src/session_memory.dart, got $kSeatRecordRefresh. '
          '${_repro(id)}',
    );
    expect(
      kSeatRecordMaxAge,
      const Duration(minutes: 60),
      reason:
          '$id (D7): kSeatRecordMaxAge stays 60 minutes, got '
          '$kSeatRecordMaxAge. ${_repro(id)}',
    );
  });

  testWidgets('C1e (D6): a controller that is no longer connected is not '
      'refreshed', (tester) async {
    const String id =
        'C1e (D6): a controller that is no longer connected is '
        'not refreshed';
    final _Game game = await _Game.start(tester, id);

    await game.notifyAt(const Duration(seconds: 30));
    game.clock.now = _base.add(const Duration(seconds: 90));
    await game.transport.close();
    await tester.pump();
    await tester.pump();
    await _drainStore(tester);

    expect(
      game.controller.phase,
      isNot(RoomPhase.connected),
      reason:
          '$id fixture: closing the transport must end the connection; '
          'phase is ${game.controller.phase}',
    );
    final int? stored = await _storedSavedAtMillis();
    expect(
      stored,
      isNot(_millisAt(const Duration(seconds: 90))),
      reason:
          '$id: the controller dropped at t+90s, a minute after the write, '
          'and its notification must not write a fresh time; stored '
          '${_offset(stored)}. ${_repro(id)}',
    );

    await game.finish();
  });

  // ---------------------------------------------------------------- C2
  testWidgets('C2w (D6): a record kept fresh for 70 minutes is stored at the '
      'last notification and survives a load five minutes later', (
    tester,
  ) async {
    const String id =
        'C2w (D6): a record kept fresh for 70 minutes is stored '
        'at the last notification and survives a load five minutes later';
    final _Game game = await _Game.start(tester, id);

    // One notification a minute for the whole game.
    final int minutes = _gameLength.inMinutes;
    for (int minute = 1; minute <= minutes; minute += 1) {
      await game.notifyAt(Duration(minutes: minute));
    }
    await game.expectSaved(
      _gameLength,
      what:
          'a notification every minute for 70 minutes must leave the saved '
          'time at the last notification, not at the start of the game',
    );

    final DateTime relaunchAt = _base.add(_gameLength + _killedFor);
    final SessionMemory memory = await SessionMemory.load(
      clock: () => relaunchAt,
    );
    expect(
      memory.seatRecord,
      const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
      reason:
          '$id: a load five minutes after the last notification (75 minutes '
          'into the game) must still return the record; it returned '
          '${memory.seatRecord}. ${_repro(id)}',
    );

    await game.finish();
  });

  testWidgets('C2r (C-447 D3, after D6): a relaunch five minutes after the '
      'last notification of a 70 minute game resumes on its own', (
    tester,
  ) async {
    const String id =
        'C2r (C-447 D3, after D6): a relaunch five minutes '
        'after the last notification of a 70 minute game resumes on its own';
    // The store C2w ends with: the record, saved at the last notification.
    _seedRecord(savedAtSinceBase: _gameLength);
    final _Factory factory = _Factory();
    final _Clock clock = _Clock()..now = _base.add(_gameLength + _killedFor);
    await tester.pumpWidget(_app(factory.call, clock.read));
    await _pumpBounded(tester);

    expect(
      factory.controllers,
      hasLength(1),
      reason:
          '$id: a record saved 5 minutes ago on the injected clock (75 '
          'minutes into the game) must resume; built '
          '${factory.controllers.length} controllers, sent '
          '${factory.allTypes}. ${_repro(id)}',
    );
    expect(factory.allTypes, <String>[
      'resume',
    ], reason: '$id: exactly one resume frame; sent ${factory.allTypes}');
    expect(_dataOf(factory.transports.single.sentRaw.single), <String, Object?>{
      'code': _kCode,
      'seat_token': _kToken,
    }, reason: '$id: the resume carries the stored code and token');
    expect(await _storedSeat(), <String>[
      _kCode,
      _kSeat.toString(),
      _kToken,
    ], reason: '$id: the record must not be dropped by the relaunch');

    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    factory.disposeAll();
    await tester.pump();
  });

  // ---------------------------------------------------------------- C3
  testWidgets('C3 (D6): no write once the room is FINISHED, including a '
      'finish that arrives past the refresh interval', (tester) async {
    const String id =
        'C3 (D6): no write once the room is FINISHED, '
        'including a finish that arrives past the refresh interval';
    final _Game game = await _Game.start(tester, id);

    // The finishing notification arrives 61 s after the last write, so the
    // interval alone would allow a rewrite. The record must be cleared, not
    // refreshed.
    game.clock.now = _base.add(const Duration(seconds: 61));
    final int before = game.notifications;
    game.seq += 1;
    game.transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': 0,
          'verify_url': 'https://verify.invalid/g/gggggggggggggggg',
          'seq': game.seq,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await _drainStore(tester);
    expect(
      game.notifications,
      before + 1,
      reason: '$id fixture: game_over must notify the controller once',
    );
    expect(
      game.controller.room!.state,
      RoomState.finished,
      reason: '$id fixture: game_over must leave the room FINISHED',
    );
    expect(
      await _storedSeat(),
      isNull,
      reason:
          '$id: game_over at t+61s must clear session.seat and not rewrite '
          'it; stored ${await _storedSeat()}. ${_repro(id)}',
    );
    expect(
      await _storedSavedAtMillis(),
      isNull,
      reason:
          '$id: game_over at t+61s must clear session.seatSavedAt; stored '
          '${_offset(await _storedSavedAtMillis())}. ${_repro(id)}',
    );

    // Later notifications on the finished room, well past the interval.
    await game.notifyAt(const Duration(seconds: 62), state: 'FINISHED');
    await game.notifyAt(const Duration(minutes: 10), state: 'FINISHED');
    await game.notifyAt(
      const Duration(minutes: 70),
      state: 'FINISHED',
      hostConnected: false,
    );
    expect(
      await _storedSeat(),
      isNull,
      reason:
          '$id: notifications on a FINISHED room (t+62s, t+10min, t+70min) '
          'must not write session.seat; stored ${await _storedSeat()}. '
          '${_repro(id)}',
    );
    expect(
      await _storedSavedAtMillis(),
      isNull,
      reason:
          '$id: notifications on a FINISHED room must not write '
          'session.seatSavedAt; stored '
          '${_offset(await _storedSavedAtMillis())}. ${_repro(id)}',
    );

    await game.finish();
  });

  // ---------------------------------------------------------------- C4
  testWidgets('C4 (D6): the record\'s three strings are the same after every '
      'refresh', (tester) async {
    const String id =
        'C4 (D6): the record\'s three strings are the same '
        'after every refresh';
    final _Game game = await _Game.start(tester, id);
    final List<String> expected = <String>[_kCode, _kSeat.toString(), _kToken];

    Future<void> expectShape(String when) async {
      final List<String>? stored = await _storedSeat();
      expect(
        stored,
        expected,
        reason:
            '$id: $when. expected session.seat $expected (code, seat, token '
            'as three strings), stored $stored. ${_repro(id)}',
      );
    }

    await expectShape('after the first write');
    await game.notifyAt(const Duration(seconds: 30));
    await expectShape('after a notification inside the interval');
    await game.notifyAt(const Duration(seconds: 61));
    await expectShape('after the first refresh (t+61s)');
    await game.notifyAt(const Duration(seconds: 122), hostConnected: false);
    await expectShape('after the second refresh (t+122s, host disconnected)');
    await game.notifyAt(const Duration(minutes: 30));
    await expectShape('after a refresh 28 minutes later (t+30min)');

    final SessionMemory memory = await SessionMemory.load(
      clock: () => _base.add(const Duration(minutes: 31)),
    );
    expect(
      memory.seatRecord,
      const SeatRecord(code: _kCode, seat: _kSeat, seatToken: _kToken),
      reason:
          '$id: the record a load reads back must equal the one first '
          'written; read ${memory.seatRecord}. ${_repro(id)}',
    );

    await game.finish();
  });
}
