// Proof for contract C-669 (work/ludo/orders/669-dropped-player-resumes.md,
// run 156): a player who was dropped and comes back lands in their seat.
// Written from the contract, R1 to R5 and gaps G1 to G4, and not from the
// body of home_screen.dart.
//
// What the contract says, as cases (ids are the order's case numbers):
//   1    R1+R2 link, same app life: create a room, play, the socket dies, walk
//        off the route, a link for the same code. The controller is asked to
//        `resume` with (code, token) and never `join_room`. 1b is the cold
//        start link over a stored record (a regression anchor), 1c delivers
//        the same link twice.
//   2    R2 typed: the same set-up, the code typed, Join tapped. 2b types it
//        lower-case with a dash, 2c types a short code (the shape error, no
//        frame at all).
//   3    R2 recent chip: the seat came from a typed join, so the code is a
//        recent chip; chip, then Join, resumes.
//   4    R2 negative: a record for room A, room B typed: `join_room` for B,
//        the record for A still in storage while B is in flight. 4b is the
//        same after an in-app-life walk-off.
//   5    R2 no record: `join_room`, as today.
//   6    R3: FINISHED clears the record, the same controller then shows the
//        rematch LOBBY and PLAYING inside five seconds of the injected clock
//        (far inside kSeatRecordRefresh): storage holds the record again at
//        once, and a takeover clears it. 6b a second finish clears it, 6c the
//        record written by the lobby survives a kill and the relaunch
//        resumes it.
//   7    R4 dead socket: PLAYING, the connection closes for a transport
//        reason, the player walks off: the record stays and Home shows the
//        Rejoin control. 7b a leave that never gets an answer (request timed
//        out), 7c the same on a rematch lobby.
//   8    R4 delivered leave: the leave is answered, the record is cleared.
//   9    R4 finished: walking off a FINISHED room clears the record, live or
//        with the socket already gone. 9c a takeover, then walk off.
//   10   One Arabic case of 7.
//
// Round 2 (defects 1 to 4 of the verdict on round 1, ids prefixed r2-):
//   r2-1a  a delivered leave whose answer is held five seconds: no Rejoin
//          control at any pumped frame of the window, then the record is gone.
//   r2-1b  walk off A with the leave pending, create B, answer A's leave: the
//          record of B is still stored, and (r2-1b2, B walked off with a dead
//          socket before the answer) Home still shows B's Rejoin control.
//   r2-1c  a leave nobody answers: the record is kept the whole time and the
//          Rejoin control is there after the timeout.
//   r2-2   the age of a kept record, by the injected clock: 61 minutes is
//          absent (typed code and link both join, the stored record is
//          cleared), 59 minutes is still resumed.
//   r2-3   a leave answered by an error frame: a code that does not say the
//          seat is gone (RATE_LIMITED, BAD_FIELD) keeps the record, one that
//          does (NO_SUCH_ROOM, BAD_SEAT_TOKEN) clears it.
//   r2-4   a typed code whose resume is refused NO_SUCH_ROOM leaves the code
//          field empty, as the refused join of a code with no record does.
//
// Rig: the real HomeScreen, RoomRoute, GameScreen and a real RoomController
// per controller the factory hands out, over a FakeTransport, a fresh one per
// connect (the rig of test/c540_test.dart, copied, not imported). The "leave
// could not be delivered" state is a closed fake socket or a leave nobody
// answers; the delivered state is a live socket that answers the leave. No
// case depends on the return type of RoomController.leave().
//
// Time: Home is built with HomeScreen.clock, a clock the case moves by hand,
// so "within five seconds" is the injected clock and not the wall. Every pump
// is bounded: the game screen's countdown never settles.
//
// Reproduce any case alone, there is no random input, with
//   flutter test test/c669_dropped_player_resumes_test.dart \
//     --plain-name '<id>'
// Each failure reason carries the case id, the steps played so far, what was
// expected and what was seen.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _rejoinKey = Key('home-rejoin-button');
const Key _appBarLeaveKey = Key('game-screen-appbar-leave');
const Key _leaveConfirmLeaveKey = Key('game-leave-confirm-leave');
const Key _lostLeaveKey = Key('game-screen-leave-button');
const Key _lobbyLeaveKey = Key('lobby-leave-button');

const String _testUrl = 'wss://c669-test.invalid/ws';
const String _fileName = 'c669_dropped_player_resumes_test.dart';

const String _codeA = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const String _codeB = 'W4X9HN';
const String _token = 'tok-c669-seat-0001';
const String _tokenB = 'tok-c669-seat-0002';
const String _gameId = '7f3a9c1e5b2d4068';
const String _verifyUrl = 'https://c669-test.invalid/v/7f3a9c1e5b2d4068';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';

/// The injected clock starts here.
final DateTime _base = DateTime.utc(2026, 11, 18, 12);

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c669-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _wireSeat(
  int seat, {
  required String name,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

/// The share-link id the fake server puts on every room frame; null is a
/// server from before section 31 (no `link_id`). Only the cases that tap a
/// link set it, so every other case keeps the wire it was written against.
String? _roomLinkId;

Map<String, Object?> _wireRoom({
  required String code,
  required String state,
  required int seq,
  int chainIndex = 0,
  Map<String, Object?>? rematch,
}) {
  final bool lobby = state == 'LOBBY';
  final bool finished = state == 'FINISHED';
  return <String, Object?>{
    'code': code,
    if (_roomLinkId != null) 'link_id': _roomLinkId,
    'state': state,
    'host_seat': 0,
    'players': 2,
    'rules': const <String, Object?>{
      'blocks': false,
      'capture_bonus': true,
      'turn_seconds': 45,
    },
    'chain_commit': (chainIndex == 0 ? 'a' : 'b') * 64,
    'chain_index': chainIndex,
    'game_id': lobby ? null : _gameId,
    'client_seeds': lobby ? null : '0:host-seed|1:guest-seed',
    'seats': <Map<String, Object?>>[
      _wireSeat(
        0,
        name: 'Host',
        tokens: finished
            ? const <int>[57, 57, 57, 57]
            : const <int>[-1, -1, -1, -1],
      ),
      _wireSeat(
        1,
        name: 'Guest',
        tokens: finished
            ? const <int>[57, 57, 12, -1]
            : const <int>[-1, -1, -1, -1],
      ),
    ],
    'turn': lobby
        ? null
        : <String, Object?>{
            'seat': 0,
            'phase': finished ? 'finished' : 'await_roll',
            'deadline_ms': finished ? 0 : 45000,
            'k': finished ? 8 : 0,
          },
    'winner': finished ? 0 : null,
    if (finished) 'verify_url': _verifyUrl,
    'seq': seq,
    'rematch': ?rematch,
  };
}

// ---------------------------------------------------------------- the rig

class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

/// A fresh controller per call and a fresh [FakeTransport] per connect.
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
  RoomController get lastController => controllers.last;

  /// Every frame of [type] sent on transport number [from] or later.
  List<String> sent(String type, {int from = 0}) => <String>[
    for (int i = from; i < transports.length; i += 1)
      for (final String s in transports[i].sentRaw)
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

class _Clock {
  DateTime now = _base;

  DateTime read() => now;
}

class _Links {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  Stream<Uri> open() => _controller.stream;

  void add(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();
}

Uri _linkFor(String linkId) =>
    Uri.parse('https://ludo.provefair.app/r/$linkId');

Widget _app(
  _Rig rig,
  _Clock clock,
  _Links links, {
  Locale? locale,
  InitialLinkReader initialLink = noInitialLink,
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
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: rig.call,
      initialLinkReader: initialLink,
      linkStream: links.open,
      clock: clock.read,
    ),
  );
}

Future<void> _pumpBounded(WidgetTester tester, {int frames = 6}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// Lets the unawaited store writes Home started finish on the real event
/// loop, so a read after it sees every write that was going to happen.
Future<void> _drainStore(WidgetTester tester) async {
  await tester.runAsync(() => pumpEventQueue());
}

Future<List<String>?> _storedSeat() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_seatPrefsKey);
}

Future<int?> _storedSavedAt() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getInt(_savedAtPrefsKey);
}

/// A record as an app from before C-447 stored it: no saved time, so Home
/// shows the Rejoin control and does not resume on its own at mount.
void _seedLegacyRecord(String code) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _seatPrefsKey: <String>[code, '0', _token],
  });
}

/// The same record, written by the app that knows the room's link id (order
/// 681, R1), with the saved time removed so Home shows Rejoin and does not
/// resume on its own at mount, exactly as [_seedLegacyRecord] leaves it.
Future<void> _seedLegacyRecordWithLink(
  WidgetTester tester,
  String code,
  String linkId,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.runAsync(() async {
    await SessionMemory.recordSeat(
      SeatRecord(code: code, seat: 0, seatToken: _token, linkId: linkId),
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedAtPrefsKey);
  });
}

// -------------------------------------------------------------- the world

/// One case: the mounted Home, its rig and clock, and the steps played, which
/// every failure reason carries.
class _World {
  _World(this.tester, this.id, {this.locale});

  final WidgetTester tester;
  final String id;
  final Locale? locale;
  _Rig rig = _Rig();
  _Clock clock = _Clock();
  final _Links links = _Links();
  final List<String> steps = <String>[];
  int seq = 0;
  String code = _codeA;
  String token = _token;

  String why(String message) =>
      '$id: $message. steps: ${steps.join(' > ')}. '
      "reproduce: flutter test test/$_fileName --plain-name '$id'";

  Future<void> mount({InitialLinkReader initialLink = noInitialLink}) async {
    steps.add('mount Home');
    await tester.pumpWidget(
      _app(rig, clock, links, locale: locale, initialLink: initialLink),
    );
    await _pumpBounded(tester);
    await _drainStore(tester);
    await _pumpBounded(tester, frames: 2);
  }

  Future<void> tap(Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.tap(find.byKey(key));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> typeCode(String text) async {
    await tester.enterText(find.byKey(_codeKey), text);
    // A full code opens the Join control through a 200 ms AnimatedSize.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// Home, a Create tap, the server's answer and a PLAYING room: the player
  /// is host, seat 0, with [_token], on the game route.
  Future<void> createAndPlay({
    String roomCode = _codeA,
    String seatToken = _token,
  }) async {
    code = roomCode;
    token = seatToken;
    steps.add('create $roomCode');
    final int from = rig.transports.length;
    await tap(_createKey);
    final List<String> creates = rig.sent('create_room', from: from);
    expect(creates, hasLength(1), reason: why('fixture: one create_room'));
    final FakeTransport transport = rig.last;
    seq = 1;
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(creates.single),
        data: _wireRoom(code: roomCode, state: 'LOBBY', seq: seq),
      ),
    );
    await _pumpBounded(tester, frames: 2);
    await pushRoom('PLAYING');
    await expectOnGameRoute('fixture: a PLAYING room shows the game');
    await expectStored(
      'fixture: the seat earned in this app life is on disk at PLAYING',
    );
  }

  /// The typed-join way in, seat 1 with [_token]: the code becomes a recent
  /// chip on Home. Ends on the game route with a PLAYING room.
  Future<void> joinAndPlay({String roomCode = _codeA}) async {
    code = roomCode;
    steps.add('typed join $roomCode');
    final int from = rig.transports.length;
    await typeCode(roomCode);
    await tap(_joinKey);
    final List<String> joins = rig.sent('join_room', from: from);
    expect(joins, hasLength(1), reason: why('fixture: one join_room'));
    final FakeTransport transport = rig.last;
    seq = 1;
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 1, 'seat_token': _token},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: _idOf(joins.single),
        data: _wireRoom(code: roomCode, state: 'LOBBY', seq: seq),
      ),
    );
    await _pumpBounded(tester, frames: 2);
    await pushRoom('PLAYING');
    await expectOnGameRoute('fixture: a PLAYING room shows the game');
    await _drainStore(tester);
    final List<String>? seat = await _storedSeat();
    expect(seat, <String>[
      roomCode,
      '1',
      _token,
    ], reason: why('fixture: the joined seat is on disk at PLAYING'));
  }

  /// One more `room` push at the next seq, at the injected time [at].
  Future<void> pushRoom(
    String state, {
    Duration? at,
    int chainIndex = 0,
    Map<String, Object?>? rematch,
  }) async {
    if (at != null) {
      clock.now = _base.add(at);
    }
    seq += 1;
    steps.add(
      'room $state seq $seq'
      '${at == null ? '' : ' at +${at.inMilliseconds / 1000}s'}',
    );
    rig.last.pushText(
      _frame(
        type: 'room',
        data: _wireRoom(
          code: code,
          state: state,
          seq: seq,
          chainIndex: chainIndex,
          rematch: rematch,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpBounded(tester, frames: 2);
    if (state == 'FINISHED') {
      await refuseGameLogs();
    }
    await _drainStore(tester);
  }

  /// The end card asks for the game log; answer so no request timer outlives
  /// the case.
  Future<void> refuseGameLogs() async {
    final FakeTransport transport = rig.last;
    if (transport.isClosed) {
      return;
    }
    for (final String raw in transport.sentRaw) {
      if (_typeOf(raw) == 'game_log') {
        transport.pushText(
          _frame(
            type: 'error',
            re: _idOf(raw),
            data: <String, Object?>{'code': 'RATE_LIMITED', 'message': ''},
          ),
        );
      }
    }
    await tester.pump();
    await tester.pump();
  }

  Future<void> expectOnGameRoute(String what) async {
    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: why('$what; GameScreen not on screen'),
    );
  }

  Future<void> expectStored(String what) async {
    await _drainStore(tester);
    final List<String>? seat = await _storedSeat();
    expect(
      seat,
      isNotNull,
      reason: why('$what; expected a stored session.seat, found none'),
    );
    expect(
      seat![0],
      code,
      reason: why('$what; stored record is for ${seat[0]}, expected $code'),
    );
    expect(
      seat[2],
      token,
      reason: why('$what; the stored token is not the one the server gave'),
    );
  }

  Future<void> expectNotStored(String what) async {
    await _drainStore(tester);
    final List<String>? seat = await _storedSeat();
    expect(
      seat,
      isNull,
      reason: why('$what; expected no stored session.seat, found $seat'),
    );
  }

  /// The far side vanishes: a transport reason, not a server error.
  Future<void> dropSocket() async {
    steps.add('socket ends from the far side');
    final RoomController controller = rig.lastController;
    rig.last.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.closed,
      reason: why('fixture: a vanished far side must close the phase'),
    );
    expect(
      controller.seatTakenOver,
      isFalse,
      reason: why('fixture: a plain drop is not a takeover'),
    );
    expect(
      controller.errorCode,
      anyOf(isNull, 'transport'),
      reason: why('fixture: the drop must not carry a server error code'),
    );
  }

  /// The connection-lost card's own Leave, which pops the route, and then
  /// whatever Home's retire does, given the 10 s a dead socket costs it.
  Future<void> walkOffDead() async {
    steps.add('walk off through the connection-lost Leave');
    expect(
      find.byKey(_lostLeaveKey),
      findsOneWidget,
      reason: why('fixture: the connection-lost card must offer Leave'),
    );
    await tap(_lostLeaveKey);
    await settleHome();
  }

  /// The corner Leave, through the confirm sheet when one opens, on a live
  /// socket. With [answer] the leave is answered the way section 4 says: with
  /// `presence` in PLAYING, with `player_left` otherwise.
  Future<void> walkOffLive({required bool answer}) async {
    steps.add('walk off through the corner Leave (answer=$answer)');
    final int from = rig.transports.length - 1;
    await tap(_appBarLeaveKey);
    if (find.byKey(_leaveConfirmLeaveKey).evaluate().isNotEmpty) {
      await tap(_leaveConfirmLeaveKey);
    }
    await _pumpBounded(tester, frames: 3);
    final List<String> leaves = rig.sent('leave_room', from: from);
    expect(
      leaves,
      hasLength(1),
      reason: why(
        'fixture: Home must send exactly one leave_room on the live '
        'socket; sent ${leaves.length}',
      ),
    );
    if (answer) {
      final bool playing =
          rig.lastController.room?.state.name.toLowerCase() == 'playing';
      seq += 1;
      rig.last.pushText(
        _frame(
          type: playing ? 'presence' : 'player_left',
          re: _idOf(leaves.single),
          data: playing
              ? <String, Object?>{'seat': 0, 'connected': false, 'seq': seq}
              : <String, Object?>{'seat': 0, 'host_seat': 0, 'seq': seq},
        ),
      );
    }
    await settleHome();
  }

  /// Runs out Home's retire: past the 10 s request timeout, so a leave that
  /// nobody answered has finished failing, then the store writes.
  Future<void> settleHome() async {
    await _pumpBounded(tester, frames: 3);
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    await _pumpBounded(tester, frames: 3);
    await _drainStore(tester);
    await _pumpBounded(tester, frames: 2);
  }

  Future<void> expectHomeCurrent() async {
    final Finder home = find.byType(HomeScreen);
    expect(home, findsOneWidget, reason: why('Home must be mounted'));
    expect(
      ModalRoute.of(tester.element(home))?.isCurrent ?? false,
      isTrue,
      reason: why('fixture: the walk-off must land on Home'),
    );
  }

  /// Takes the unawaited retire's exceptions into account too: whatever
  /// remained queued when the case ends must not throw.
  Future<void> finish() async {
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    rig.disposeAll();
    await tester.pump();
    await links.close();
  }

  // ------------------------------------------------------------ round 2

  /// Pumps [total] of test clock in [step] frames and asserts, at every one,
  /// that Home shows no Rejoin control: the seat being left is not offered
  /// back while its leave is still on the wire.
  Future<void> pumpWatching(
    Duration total, {
    Duration step = const Duration(milliseconds: 50),
  }) async {
    Duration spent = Duration.zero;
    while (spent < total) {
      await tester.pump(step);
      spent += step;
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason: why(
          'the Rejoin control showed ${spent.inMilliseconds} ms into the '
          'window of a leave that is still unanswered; nothing may be '
          'offered for the seat being left',
        ),
      );
    }
  }

  /// A walk-off on a live socket whose `leave_room` nobody answers yet. With
  /// [watch] every frame from the corner Leave tap on is checked for a Rejoin
  /// control. Returns where the pending leave went.
  Future<({int transport, String leaveId})> walkOffHeld({
    bool watch = false,
  }) async {
    steps.add('walk off through the corner Leave, leave left unanswered');
    final int index = rig.transports.length - 1;
    await tester.ensureVisible(find.byKey(_appBarLeaveKey));
    await tester.tap(find.byKey(_appBarLeaveKey));
    if (watch) {
      await pumpWatching(const Duration(milliseconds: 600));
    } else {
      await _pumpBounded(tester, frames: 3);
    }
    if (find.byKey(_leaveConfirmLeaveKey).evaluate().isNotEmpty) {
      await tester.ensureVisible(find.byKey(_leaveConfirmLeaveKey));
      await tester.tap(find.byKey(_leaveConfirmLeaveKey));
    }
    if (watch) {
      await pumpWatching(const Duration(seconds: 1));
    } else {
      await _pumpBounded(tester, frames: 3);
    }
    final List<String> leaves = rig.sent('leave_room', from: index);
    expect(
      leaves,
      hasLength(1),
      reason: why(
        'fixture: Home must send exactly one leave_room on the live '
        'socket; sent ${leaves.length}',
      ),
    );
    return (transport: index, leaveId: _idOf(leaves.single));
  }

  /// Answers a leave left pending by [walkOffHeld]: with the `presence` the
  /// server sends for a leave in PLAYING, or with an `error` frame of
  /// [errorCode].
  Future<void> answerLeave(
    ({int transport, String leaveId}) held, {
    String? errorCode,
  }) async {
    steps.add('answer the pending leave with ${errorCode ?? 'presence'}');
    final FakeTransport transport = rig.transports[held.transport];
    expect(
      transport.isClosed,
      isFalse,
      reason: why(
        'fixture: the transport of the pending leave closed before its '
        'answer, so the late answer cannot be delivered',
      ),
    );
    transport.pushText(
      _frame(
        type: errorCode == null ? 'presence' : 'error',
        re: held.leaveId,
        data: errorCode == null
            ? <String, Object?>{'seat': 0, 'connected': false, 'seq': 500}
            : <String, Object?>{'code': errorCode, 'message': ''},
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpBounded(tester, frames: 2);
    await _drainStore(tester);
  }

  /// The connection-lost card's Leave without the wait for Home's retire.
  Future<void> walkOffDeadQuick() async {
    steps.add('walk off through the connection-lost Leave, no wait');
    expect(
      find.byKey(_lostLeaveKey),
      findsOneWidget,
      reason: why('fixture: the connection-lost card must offer Leave'),
    );
    await tap(_lostLeaveKey);
    await _pumpBounded(tester, frames: 2);
  }

  void expectRejoinFor(String roomCode, String what) {
    final Finder rejoin = find.byKey(_rejoinKey);
    expect(
      rejoin,
      findsOneWidget,
      reason: why('$what; Home must show the Rejoin control for $roomCode'),
    );
    final AppLocalizations loc = AppLocalizations.of(tester.element(rejoin));
    expect(
      find.descendant(
        of: rejoin,
        matching: find.text(loc.homeRejoinButton(roomCode)),
      ),
      findsOneWidget,
      reason: why('$what; the Rejoin control must name the room $roomCode'),
    );
  }

  void expectNoRejoin(String what) {
    expect(
      find.byKey(_rejoinKey),
      findsNothing,
      reason: why('$what; Home must not show a Rejoin control'),
    );
  }

  String codeFieldText() => tester
      .widget<TextField>(find.byKey(_codeKey, skipOffstage: false))
      .controller!
      .text;

  /// Refuses the request [type] last sent, the way the server does.
  Future<void> refuseLast(String type, String errorCode) async {
    steps.add('refuse the $type with $errorCode');
    rig.last.pushText(
      _frame(
        type: 'error',
        re: rig.lastRequestId(type),
        data: <String, Object?>{'code': errorCode, 'message': ''},
      ),
    );
    await tester.pump();
    await tester.pump();
    await _pumpBounded(tester, frames: 3);
    await _drainStore(tester);
    await _pumpBounded(tester, frames: 2);
  }

  /// After a refusal the player is either already on Home or on the room
  /// screen's error card, whose Back to home returns there (the way the
  /// join path's dead code is cleared, test/c529_a1_test.dart A1.2b).
  Future<void> backToHomeIfOffered() async {
    final Finder back = find.byKey(_lobbyLeaveKey);
    if (back.evaluate().isNotEmpty) {
      steps.add('tap Back to home on the error card');
      await tester.tap(back.first);
      await tester.pump();
      await _pumpBounded(tester, frames: 3);
    }
    await expectHomeCurrent();
  }

  /// A resume was sent on a transport newer than [from], with the record's
  /// code and token, and no join_room went out on any of them.
  void expectResumeNotJoin(int from, String code) {
    final List<String> joins = rig.sent('join_room', from: from);
    final List<String> resumes = rig.sent('resume', from: from);
    expect(
      joins,
      isEmpty,
      reason: why(
        'expected no join_room for $code (the seat is held, resume '
        'it); sent ${joins.length}: ${joins.map(_dataOf).toList()}',
      ),
    );
    expect(
      resumes,
      hasLength(1),
      reason: why(
        'expected exactly one resume for $code; sent '
        '${resumes.length}',
      ),
    );
    expect(_dataOf(resumes.single), <String, Object?>{
      'code': code,
      'seat_token': token,
    }, reason: why('expected resume to carry ($code, $token) verbatim'));
  }

  /// A link id names no code, so it can never be matched to a stored record:
  /// exactly one join_room carrying `link` (never `code`), no resume.
  void expectJoinByLink(int from, String linkId) {
    final List<String> joins = rig.sent('join_room', from: from);
    final List<String> resumes = rig.sent('resume', from: from);
    expect(
      resumes,
      isEmpty,
      reason: why('expected no resume for a link id; sent ${resumes.length}'),
    );
    expect(
      joins,
      hasLength(1),
      reason: why('expected exactly one join_room for link $linkId'),
    );
    final Map<String, Object?> data = Map<String, Object?>.of(
      _dataOf(joins.single),
    );
    data.remove('install');
    data.remove('name');
    expect(data, <String, Object?>{
      'link': linkId,
    }, reason: why('expected join_room to carry the link id and no code'));
  }

  /// Answers the join the way the server does, so the case ends in a game.
  Future<void> answerJoin() async {
    final String id = rig.lastRequestId('join_room');
    seq = 10;
    rig.last.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': token},
      ),
    );
    rig.last.pushText(
      _frame(
        type: 'room',
        re: id,
        data: _wireRoom(code: code, state: 'PLAYING', seq: seq),
      ),
    );
    await _pumpBounded(tester, frames: 3);
    await expectOnGameRoute('the join must land the player in the game');
  }

  /// Answers the resume the way the server does, so the case ends in a game
  /// and not on an unanswered request.
  Future<void> answerResume() async {
    final String id = rig.lastRequestId('resume');
    seq = 10;
    rig.last.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': token},
      ),
    );
    rig.last.pushText(
      _frame(
        type: 'room',
        re: id,
        data: _wireRoom(code: code, state: 'PLAYING', seq: seq),
      ),
    );
    await _pumpBounded(tester, frames: 3);
    await expectOnGameRoute('the resume must land the player in the game');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    _roomLinkId = null;
  });

  // The R4 dead-socket walk-off is how cases 1 to 3 get back to Home with the
  // seat still held. Every one of them says so in its fixture.

  testWidgets('1 link: after a dead-socket walk-off a link id equal to the '
      'held seat\'s link id resumes with (code, token) and never joins', (
    tester,
  ) async {
    final _World w = _World(tester, '1 link same app life');
    _roomLinkId = _linkId;
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored(
        'R4: the leave was never delivered, the record is the only key to '
        'the seat the server still holds',
      );

      final int from = w.rig.transports.length;
      w.steps.add('link ${_linkFor(_linkId)}');
      w.links.add(_linkFor(_linkId));
      await _pumpBounded(tester, frames: 3);
      w.expectResumeNotJoin(from, _codeA);
      await w.answerResume();
    } finally {
      await w.finish();
    }
  });

  testWidgets('1b link id at cold start over a stored record that carries '
      'that link id resumes', (tester) async {
    await _seedLegacyRecordWithLink(tester, _codeA, _linkId);
    final _World w = _World(tester, '1b link cold start stored record');
    await w.mount(initialLink: () async => _linkFor(_linkId));
    try {
      w.expectResumeNotJoin(0, _codeA);
    } finally {
      await w.finish();
    }
  });

  testWidgets('1c link id delivered twice while the resume is under way: one '
      'resume, no join', (tester) async {
    final _World w = _World(tester, '1c link replayed');
    _roomLinkId = _linkId;
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      final int from = w.rig.transports.length;
      w.steps.add('link twice');
      w.links.add(_linkFor(_linkId));
      w.links.add(_linkFor(_linkId));
      await _pumpBounded(tester, frames: 3);
      w.expectResumeNotJoin(from, _codeA);
      expect(
        w.rig.controllers.length,
        from + 1,
        reason: w.why(
          'a replayed link must not build a second controller; built '
          '${w.rig.controllers.length - from} after the walk-off',
        ),
      );
      await w.answerResume();
    } finally {
      await w.finish();
    }
  });

  testWidgets('2 typed: the code of the room you are seated in resumes with '
      '(code, token), no join', (tester) async {
    final _World w = _World(tester, '2 typed same app life');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored('R4: the undelivered leave keeps the record');

      final int from = w.rig.transports.length;
      w.steps.add('type $_codeA, tap Join');
      await w.typeCode(_codeA);
      await w.tap(_joinKey);
      w.expectResumeNotJoin(from, _codeA);
      await w.answerResume();
    } finally {
      await w.finish();
    }
  });

  testWidgets('2b typed in lower case with a dash still resumes', (
    tester,
  ) async {
    final _World w = _World(tester, '2b typed lower case with dash');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      final int from = w.rig.transports.length;
      w.steps.add('type k7m-2qp, tap Join');
      await w.typeCode('k7m-2qp');
      await w.tap(_joinKey);
      w.expectResumeNotJoin(from, _codeA);
      await w.answerResume();
    } finally {
      await w.finish();
    }
  });

  testWidgets('2c a short code with a record held: the shape error, nothing '
      'on any wire', (tester) async {
    _seedLegacyRecord(_codeA);
    final _World w = _World(tester, '2c short code with a record');
    await w.mount();
    try {
      w.steps.add('type K7M2Q, tap Join');
      await w.typeCode('K7M2Q');
      final bool joinShown = find.byKey(_joinKey).evaluate().isNotEmpty;
      if (joinShown) {
        await w.tap(_joinKey);
      }
      expect(
        w.rig.controllers,
        isEmpty,
        reason: w.why(
          'a code that is not a code must build no controller; built '
          '${w.rig.controllers.length}',
        ),
      );
      expect(
        w.rig.sent('resume'),
        isEmpty,
        reason: w.why('a short code must not resume'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('3 typed code: a code earned by a typed join is typed again '
      'and Join resumes (C-678: the recent-code chips are gone)', (
    tester,
  ) async {
    final _World w = _World(tester, '3 typed code');
    await w.mount();
    try {
      await w.joinAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored('R4: the undelivered leave keeps the record');

      expect(
        find.byKey(const Key('home-recent-code-$_codeA'), skipOffstage: false),
        findsNothing,
        reason: w.why('C-678: no recent-code chip on Home'),
      );
      final int from = w.rig.transports.length;
      w.steps.add('clear the field, type $_codeA, tap Join');
      await tester.enterText(find.byKey(_codeKey), '');
      await tester.pump();
      await w.typeCode(_codeA);
      await w.tap(_joinKey);
      w.expectResumeNotJoin(from, _codeA);
      await w.answerResume();
    } finally {
      await w.finish();
    }
  });

  testWidgets('4 negative: a record for room A, room B typed: join for B, A '
      'still on disk', (tester) async {
    _seedLegacyRecord(_codeA);
    final _World w = _World(tester, '4 record for A, B typed');
    await w.mount();
    try {
      w.steps.add('type $_codeB, tap Join');
      await w.typeCode(_codeB);
      await w.tap(_joinKey);
      final List<String> joins = w.rig.sent('join_room');
      expect(
        joins,
        hasLength(1),
        reason: w.why(
          'expected one join_room for $_codeB; sent '
          '${joins.length}',
        ),
      );
      expect(
        _dataOf(joins.single)['code'],
        _codeB,
        reason: w.why('the join must carry the typed code'),
      );
      expect(
        w.rig.sent('resume'),
        isEmpty,
        reason: w.why('a record for another room must not be resumed'),
      );
      w.code = _codeA;
      await w.expectStored(
        'the record for $_codeA must be untouched while '
        '$_codeB is joined',
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('4b negative after a walk-off in this app life: B typed joins '
      'B, A stays on disk while B is in flight', (tester) async {
    final _World w = _World(tester, '4b held seat A, B typed');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored('R4: the undelivered leave keeps the record');

      final int from = w.rig.transports.length;
      w.steps.add('type $_codeB, tap Join');
      await w.typeCode(_codeB);
      await w.tap(_joinKey);
      final List<String> joins = w.rig.sent('join_room', from: from);
      expect(
        joins,
        hasLength(1),
        reason: w.why(
          'expected one join_room for $_codeB; sent '
          '${joins.length}',
        ),
      );
      expect(
        _dataOf(joins.single)['code'],
        _codeB,
        reason: w.why('the join must carry the typed code'),
      );
      expect(
        w.rig.sent('resume', from: from),
        isEmpty,
        reason: w.why('a record for another room must not be resumed'),
      );
      await w.expectStored(
        'the record for $_codeA must be untouched while '
        '$_codeB is joined',
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('5 no record: a typed code joins, as today', (tester) async {
    final _World w = _World(tester, '5 no record typed');
    await w.mount();
    try {
      w.steps.add('type $_codeA, tap Join');
      await w.typeCode(_codeA);
      await w.tap(_joinKey);
      final List<String> joins = w.rig.sent('join_room');
      expect(
        joins,
        hasLength(1),
        reason: w.why('expected one join_room; sent ${joins.length}'),
      );
      expect(
        _dataOf(joins.single)['code'],
        _codeA,
        reason: w.why('the join must carry the typed code'),
      );
      expect(
        w.rig.sent('resume'),
        isEmpty,
        reason: w.why('with no record nothing is resumed'),
      );
    } finally {
      await w.finish();
    }
  });

  // ------------------------------------------------------------------ R3

  testWidgets('6 rematch: after FINISHED the lobby and then PLAYING write the '
      'record at once, a takeover clears it', (tester) async {
    final _World w = _World(tester, '6 rematch rewrites the record');
    await w.mount();
    try {
      await w.createAndPlay();

      await w.pushRoom('FINISHED', at: const Duration(seconds: 10));
      await w.expectNotStored('a FINISHED room clears the record');

      await w.pushRoom(
        'LOBBY',
        at: const Duration(seconds: 12),
        chainIndex: 1,
        rematch: <String, Object?>{
          'by': 1,
          'ready': <int>[1],
        },
      );
      await w.expectStored(
        'R3: the rematch lobby of the same controller must write the record '
        'at once, 2 s after the clear and far inside kSeatRecordRefresh',
      );
      expect(
        await _storedSavedAt(),
        _base.add(const Duration(seconds: 12)).millisecondsSinceEpoch,
        reason: w.why(
          'R3: the rewrite is stamped with the clock of the '
          'notification that caused it, not left for the next refresh',
        ),
      );

      await w.pushRoom(
        'PLAYING',
        at: const Duration(seconds: 14),
        chainIndex: 1,
      );
      await w.expectStored('R3: the rematch game keeps the record');

      w.steps.add('takeover: unsolicited BAD_SEAT_TOKEN');
      w.clock.now = _base.add(const Duration(seconds: 16));
      w.rig.last.pushText(
        _frame(
          type: 'error',
          data: <String, Object?>{'code': 'BAD_SEAT_TOKEN', 'message': ''},
        ),
      );
      await _pumpBounded(tester, frames: 3);
      await w.expectNotStored(
        'R3: the clear is re-armed after the rewrite, so a takeover during '
        'the rematch clears the record again',
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('6b rematch then a second FINISHED clears the record again', (
    tester,
  ) async {
    final _World w = _World(tester, '6b second finish clears');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.pushRoom('FINISHED', at: const Duration(seconds: 10));
      await w.expectNotStored('a FINISHED room clears the record');
      await w.pushRoom(
        'LOBBY',
        at: const Duration(seconds: 12),
        chainIndex: 1,
        rematch: <String, Object?>{
          'by': 1,
          'ready': <int>[1],
        },
      );
      await w.pushRoom(
        'PLAYING',
        at: const Duration(seconds: 14),
        chainIndex: 1,
      );
      await w.expectStored('R3: the rematch game keeps the record');
      await w.pushRoom(
        'FINISHED',
        at: const Duration(seconds: 20),
        chainIndex: 1,
      );
      await w.expectNotStored(
        'R3: the clear is re-armed, so the finish of the rematch game '
        'clears the record again',
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('6c a phone killed 8 s into the rematch lobby relaunches into '
      'the seat', (tester) async {
    final _World w = _World(tester, '6c kill in the first minute of a rematch');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.pushRoom('FINISHED', at: const Duration(seconds: 10));
      await w.pushRoom(
        'LOBBY',
        at: const Duration(seconds: 12),
        chainIndex: 1,
        rematch: <String, Object?>{
          'by': 1,
          'ready': <int>[1],
        },
      );
      await w.pushRoom(
        'PLAYING',
        at: const Duration(seconds: 14),
        chainIndex: 1,
      );

      // The process dies: what is on disk now is all the next launch has.
      await _drainStore(tester);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, Object> onDisk = <String, Object>{
        for (final String key in prefs.getKeys()) key: prefs.get(key)!,
      };
      w.steps.add('kill: on disk ${onDisk[_seatPrefsKey]}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
      w.rig.disposeAll();
      SharedPreferences.setMockInitialValues(onDisk);

      w.rig = _Rig();
      w.clock = _Clock()..now = _base.add(const Duration(seconds: 22));
      await w.mount();
      w.expectResumeNotJoin(0, _codeA);
    } finally {
      await w.finish();
    }
  });

  // ------------------------------------------------------------------ R4

  testWidgets('7 dead socket: walking off keeps the record and Home shows the '
      'Rejoin control', (tester) async {
    final _World w = _World(tester, '7 dead socket walk-off');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      await w.expectStored(
        'R4: the leave could not be delivered, the server still holds the '
        'seat, the phone must keep the key to it',
      );
      final Finder rejoin = find.byKey(_rejoinKey);
      expect(
        rejoin,
        findsOneWidget,
        reason: w.why('R4: Home must show the Rejoin control for $_codeA'),
      );
      final AppLocalizations loc = AppLocalizations.of(tester.element(rejoin));
      expect(
        find.descendant(
          of: rejoin,
          matching: find.text(loc.homeRejoinButton(_codeA)),
        ),
        findsOneWidget,
        reason: w.why('the Rejoin control must name the room $_codeA'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('7b a leave nobody answers (request timed out): the record '
      'stays and the Rejoin control shows', (tester) async {
    final _World w = _World(tester, '7b leave times out');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.walkOffLive(answer: false);
      await w.expectHomeCurrent();

      await w.expectStored(
        'R4: a leave that timed out was not delivered, the record stays',
      );
      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason: w.why('R4: Home must show the Rejoin control for $_codeA'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('7c the rematch lobby of a dropped player: walking off with a '
      'dead socket keeps the record', (tester) async {
    final _World w = _World(tester, '7c dead socket in a rematch lobby');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.pushRoom('FINISHED', at: const Duration(seconds: 10));
      await w.pushRoom(
        'LOBBY',
        at: const Duration(seconds: 12),
        chainIndex: 1,
        rematch: <String, Object?>{
          'by': 1,
          'ready': <int>[1],
        },
      );
      await w.pushRoom(
        'PLAYING',
        at: const Duration(seconds: 14),
        chainIndex: 1,
      );
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      await w.expectStored(
        'R4 with R3: the rematch game is PLAYING, the leave was not '
        'delivered, the record stays',
      );
      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason: w.why('R4: Home must show the Rejoin control for $_codeA'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('8 delivered leave: answered, the record is cleared and the '
      'Rejoin control is gone (anchor, green on the base)', (tester) async {
    final _World w = _World(tester, '8 delivered leave');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.walkOffLive(answer: true);
      await w.expectHomeCurrent();

      await w.expectNotStored(
        'R4: the server heard the leave, the record is cleared as today',
      );
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason: w.why('R4: no Rejoin control after a delivered leave'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('9 finished: walking off a FINISHED room clears the record '
      '(anchor, green on the base)', (tester) async {
    final _World w = _World(tester, '9 finished walk-off');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.pushRoom('FINISHED', at: const Duration(seconds: 10));
      await w.walkOffLive(answer: true);
      await w.expectHomeCurrent();

      await w.expectNotStored('R4: a FINISHED room leaves no record');
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason: w.why('R4: no Rejoin control after leaving a FINISHED room'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('9b finished, then the socket dies, then walk off: no record', (
    tester,
  ) async {
    final _World w = _World(tester, '9b finished then dead socket');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.pushRoom('FINISHED', at: const Duration(seconds: 10));
      w.steps.add('socket ends from the far side');
      w.rig.last.endFromFarSide();
      await tester.pump();
      await tester.pump();
      await _pumpBounded(tester, frames: 2);
      w.steps.add('walk off through the corner Leave');
      await w.tap(_appBarLeaveKey);
      if (find.byKey(_leaveConfirmLeaveKey).evaluate().isNotEmpty) {
        await w.tap(_leaveConfirmLeaveKey);
      }
      await w.settleHome();
      await w.expectHomeCurrent();

      await w.expectNotStored(
        'R4: the room was FINISHED, there is no seat to keep a key to',
      );
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason: w.why('R4: no Rejoin control after leaving a FINISHED room'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('9c takeover then walk off: the seat is gone, the record is '
      'gone, no Rejoin control (anchor, green on the base)', (tester) async {
    final _World w = _World(tester, '9c takeover then walk-off');
    await w.mount();
    try {
      await w.createAndPlay();
      w.steps.add('takeover: unsolicited BAD_SEAT_TOKEN');
      w.rig.last.pushText(
        _frame(
          type: 'error',
          data: <String, Object?>{'code': 'BAD_SEAT_TOKEN', 'message': ''},
        ),
      );
      await _pumpBounded(tester, frames: 3);
      await w.expectNotStored('a takeover clears the record');
      await w.walkOffDead();
      await w.expectHomeCurrent();

      await w.expectNotStored('R4: the seat is gone, nothing to keep');
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason: w.why('R4: no Rejoin control after a takeover'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('10 Arabic: the Rejoin control shows after a dead-socket '
      'walk-off, mirrored, with no exception', (tester) async {
    final _World w = _World(
      tester,
      '10 arabic dead socket walk-off',
      locale: const Locale('ar'),
    );
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      await w.expectStored('R4: the undelivered leave keeps the record');
      final Finder rejoin = find.byKey(_rejoinKey);
      expect(
        rejoin,
        findsOneWidget,
        reason: w.why('R4: Home must show the Rejoin control for $_codeA'),
      );
      final BuildContext context = tester.element(rejoin);
      final AppLocalizations loc = AppLocalizations.of(context);
      expect(loc.localeName, 'ar', reason: w.why('fixture: Arabic locale'));
      expect(
        Directionality.of(context),
        TextDirection.rtl,
        reason: w.why('the layout must be mirrored'),
      );
      expect(
        find.descendant(
          of: rejoin,
          matching: find.text(loc.homeRejoinButton(_codeA)),
        ),
        findsOneWidget,
        reason: w.why('the Rejoin control must carry the Arabic label'),
      );
      expect(
        tester.takeException(),
        isNull,
        reason: w.why('no exception while walking off in Arabic'),
      );
    } finally {
      await w.finish();
    }
  });

  // ------------------------------------------------------------- round 2

  testWidgets('r2-1a a delivered leave answered after 5 s: no Rejoin control '
      'at any frame of the window, the record is gone after', (tester) async {
    final _World w = _World(
      tester,
      'r2-1a held leave hides the Rejoin control',
    );
    await w.mount();
    try {
      await w.createAndPlay();
      final held = await w.walkOffHeld(watch: true);
      await w.expectHomeCurrent();
      w.steps.add('hold the answer 5 s');
      await w.pumpWatching(const Duration(seconds: 5));
      await w.answerLeave(held);
      await w.settleHome();

      w.expectNoRejoin('the leave was delivered and answered');
      await w.expectNotStored(
        'the answered leave clears the record of the room that was left',
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('r2-1b walk off A with the leave pending, create B, answer A: '
      'the record of B survives in storage', (tester) async {
    final _World w = _World(tester, 'r2-1b late answer of A, B seated');
    await w.mount();
    try {
      await w.createAndPlay();
      final held = await w.walkOffHeld();
      await w.expectHomeCurrent();

      await w.createAndPlay(roomCode: _codeB, seatToken: _tokenB);
      await w.answerLeave(held);
      await w.settleHome();

      await w.expectStored(
        'the late answer of the leave of $_codeA must not clear the record '
        'of $_codeB, which was written after it',
      );
      expect(
        await _storedSavedAt(),
        isNotNull,
        reason: w.why('the record of $_codeB must carry its saved time'),
      );

      // The record of B is also the one Home would offer after a drop.
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored('B was walked off with a dead socket: kept');
      w.expectRejoinFor(_codeB, 'B was seated, its leave never delivered');
    } finally {
      await w.finish();
    }
  });

  testWidgets('r2-1b2 B walked off dead before the late answer of A: Home '
      'still holds the record of B afterwards', (tester) async {
    final _World w = _World(tester, 'r2-1b2 late answer of A over a kept B');
    await w.mount();
    try {
      await w.createAndPlay();
      final held = await w.walkOffHeld();
      await w.expectHomeCurrent();

      await w.createAndPlay(roomCode: _codeB, seatToken: _tokenB);
      await w.dropSocket();
      await w.walkOffDeadQuick();
      await w.expectHomeCurrent();

      await w.answerLeave(held);
      await w.settleHome();

      await w.expectStored(
        'the late answer of the leave of $_codeA must not clear the record '
        'of $_codeB',
      );
      w.expectRejoinFor(
        _codeB,
        'the late answer of the leave of $_codeA must not wipe Home\'s '
        'record of $_codeB',
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('r2-1c a leave nobody answers: kept while pending, the Rejoin '
      'control is shown after the timeout', (tester) async {
    final _World w = _World(tester, 'r2-1c undelivered walk-off after timeout');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.walkOffHeld();
      await w.expectHomeCurrent();

      w.steps.add('wait 5 s, leave still pending');
      await tester.pump(const Duration(seconds: 5));
      await w.expectStored('a leave still on the wire has cleared nothing');

      w.steps.add('wait past the 10 s request timeout');
      await tester.pump(const Duration(seconds: 7));
      await w.settleHome();
      await w.expectStored('R4: the leave timed out, the record stays');
      w.expectRejoinFor(_codeA, 'R4: the leave timed out');
    } finally {
      await w.finish();
    }
  });

  // The trust age (C-447 D2) of a record kept through an undelivered leave,
  // inside one app life: the injected clock decides.

  testWidgets('r2-2a a kept record 61 minutes old is absent: no Rejoin '
      'control, a typed code joins, the stored record is cleared', (
    tester,
  ) async {
    final _World w = _World(tester, 'r2-2a kept record at +61 min typed');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored('R4: the undelivered leave keeps the record');

      w.steps.add('clock +61 min');
      w.clock.now = _base.add(const Duration(minutes: 61));
      final int from = w.rig.transports.length;
      await w.typeCode(_codeA);
      w.expectNoRejoin('the record is older than kSeatRecordMaxAge');
      await w.tap(_joinKey);
      final List<String> joins = w.rig.sent('join_room', from: from);
      expect(
        joins,
        hasLength(1),
        reason: w.why(
          'a record 61 min old is absent: expected one join_room for '
          '$_codeA; sent ${joins.length}',
        ),
      );
      expect(
        w.rig.sent('resume', from: from),
        isEmpty,
        reason: w.why('a record past the trust age must not be resumed'),
      );
      await w.expectNotStored('a record past the trust age is cleared');
    } finally {
      await w.finish();
    }
  });

  testWidgets('r2-2b a kept record 61 minutes old and a link for its room: '
      'join, no resume', (tester) async {
    final _World w = _World(tester, 'r2-2b kept record at +61 min link');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      w.steps.add('clock +61 min');
      w.clock.now = _base.add(const Duration(minutes: 61));
      final int from = w.rig.transports.length;
      w.steps.add('link ${_linkFor(_linkId)}');
      w.links.add(_linkFor(_linkId));
      await _pumpBounded(tester, frames: 3);
      expect(
        w.rig.sent('resume', from: from),
        isEmpty,
        reason: w.why('a record past the trust age must not be resumed'),
      );
      expect(
        w.rig.sent('join_room', from: from),
        hasLength(1),
        reason: w.why('a link for a room with a stale record joins it'),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('r2-2c a kept record 59 minutes old is still offered and a '
      'typed code resumes it', (tester) async {
    final _World w = _World(tester, 'r2-2c kept record at +59 min typed');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();

      w.steps.add('clock +59 min');
      w.clock.now = _base.add(const Duration(minutes: 59));
      final int from = w.rig.transports.length;
      await w.typeCode(_codeA);
      w.expectRejoinFor(_codeA, 'the record is inside kSeatRecordMaxAge');
      await w.tap(_joinKey);
      w.expectResumeNotJoin(from, _codeA);
      await w.answerResume();
    } finally {
      await w.finish();
    }
  });

  // What a leave answered by an error frame proves. The server's leave_room
  // handler (ludo_server connection.dart _handleLeaveRoom, registry.dart
  // leaveRoom) answers a leave it did not process with BAD_FIELD (the leave
  // carries data), BAD_SEAT_TOKEN (no identity or the token is not seated),
  // NO_SUCH_ROOM, and the retire errors of section 28; the transport layer
  // adds RATE_LIMITED. NO_SUCH_ROOM and BAD_SEAT_TOKEN say the seat is gone
  // (R4 names both); the others say the leave was not handled and the seat
  // may still be held.
  for (final String errorCode in <String>['RATE_LIMITED', 'BAD_FIELD']) {
    testWidgets('r2-3a a leave answered $errorCode did not prove the seat '
        'gone: the record is kept and Rejoin shows', (tester) async {
      final _World w = _World(tester, 'r2-3a leave answered $errorCode');
      await w.mount();
      try {
        await w.createAndPlay();
        final held = await w.walkOffHeld();
        await w.answerLeave(held, errorCode: errorCode);
        await w.settleHome();
        await w.expectHomeCurrent();

        await w.expectStored(
          'an error that does not say the seat is gone is not a delivered '
          'leave, the record stays',
        );
        w.expectRejoinFor(_codeA, 'the leave was answered with $errorCode');
      } finally {
        await w.finish();
      }
    });
  }

  for (final String errorCode in <String>['NO_SUCH_ROOM', 'BAD_SEAT_TOKEN']) {
    testWidgets('r2-3b a leave answered $errorCode says the seat is gone: the '
        'record is cleared', (tester) async {
      final _World w = _World(tester, 'r2-3b leave answered $errorCode');
      await w.mount();
      try {
        await w.createAndPlay();
        final held = await w.walkOffHeld();
        await w.answerLeave(held, errorCode: errorCode);
        await w.settleHome();
        await w.expectHomeCurrent();

        await w.expectNotStored(
          '$errorCode on the leave means no seat to keep',
        );
        w.expectNoRejoin('the leave was answered with $errorCode');
      } finally {
        await w.finish();
      }
    });
  }

  // R5 keeps the failure handling of a refused resume: the record is
  // cleared. Defect 4 adds the same treatment of the typed code that the join
  // path already gives.

  testWidgets('r2-4a anchor: a typed code with no record, join refused '
      'NO_SUCH_ROOM: the code field is empty (green on the base)', (
    tester,
  ) async {
    final _World w = _World(tester, 'r2-4a join refused NO_SUCH_ROOM');
    await w.mount();
    try {
      await w.typeCode(_codeA);
      await w.tap(_joinKey);
      expect(
        w.rig.sent('join_room'),
        hasLength(1),
        reason: w.why('fixture: one join_room for $_codeA'),
      );
      await w.refuseLast('join_room', 'NO_SUCH_ROOM');
      await w.backToHomeIfOffered();
      expect(
        w.codeFieldText(),
        isEmpty,
        reason: w.why(
          'a code the server says is gone is cleared from the field once the player is back on Home',
        ),
      );
    } finally {
      await w.finish();
    }
  });

  testWidgets('r2-4 a typed code with a record, resume refused NO_SUCH_ROOM: '
      'the code field is empty and the record is cleared', (tester) async {
    final _World w = _World(tester, 'r2-4 resume refused NO_SUCH_ROOM');
    await w.mount();
    try {
      await w.createAndPlay();
      await w.dropSocket();
      await w.walkOffDead();
      await w.expectHomeCurrent();
      await w.expectStored('R4: the undelivered leave keeps the record');

      final int from = w.rig.transports.length;
      w.steps.add('type $_codeA, tap Join');
      await w.typeCode(_codeA);
      await w.tap(_joinKey);
      w.expectResumeNotJoin(from, _codeA);
      expect(
        w.codeFieldText(),
        _codeA,
        reason: w.why('fixture: the typed code is still in the field'),
      );

      await w.refuseLast('resume', 'NO_SUCH_ROOM');
      await w.backToHomeIfOffered();
      expect(
        w.codeFieldText(),
        isEmpty,
        reason: w.why(
          'the resume of $_codeA was refused NO_SUCH_ROOM: the dead code '
          'must not stay in the field, as after a refused join; field holds '
          '"${w.codeFieldText()}"',
        ),
      );
      await w.expectNotStored('R5: a refused resume clears the record');
    } finally {
      await w.finish();
    }
  });
}
