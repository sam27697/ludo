// Conformance tests for docs/PROTOCOL.md section 16.9 rule 5 (order 584t,
// contract C-584): the rematch auto-start of section 16.4 is also evaluated
// after a `resume` and after a `leave_room` in a rematch LOBBY. Written from
// the contract, over a real WireServer via test/support/wire_harness.dart,
// in the style of rematch_test.dart. Every assertion is on frames as a
// client receives them: type, order, `seq` steps and the presence or
// absence of `re`.
//
// Nothing here is random. Message ids are the harness's `test-msg-<n>`
// counter and rooms are driven by hand, so a failure is reproduced by
// re-running the one test named in its message:
//
//   cd packages/ludo_server
//   dart test test/rematch_autostart_reeval_test.dart -N "<test name>"
//
// "Nothing started" is always proven the same way: a ping on every live
// socket must be answered by a pong as the very next frame. The server runs
// a message's whole handler, start frames included, before it reads the next
// message on any socket, so a start that was going to happen is already
// queued ahead of that pong.
//
// Rule 5's last bullet, a takeover resume (the seat's socket still connected,
// a second socket resuming it) in a rematch LOBBY where every seat is ready
// and connected, has no test: under section 16.4 that room cannot exist, the
// last accept would have started it. Seat takeover itself is covered by
// takeover_broadcast_test.dart.

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

const String _file = 'test/rematch_autostart_reeval_test.dart';

Map<String, Object?> _data(Map<String, Object?> frame) =>
    frame['d']! as Map<String, Object?>;

int _seq(Map<String, Object?> frame) => _data(frame)['seq']! as int;

List<int> _readyOf(Map<String, Object?> roomFrame) {
  final Object? rematch = _data(roomFrame)['rematch'];
  if (rematch is! Map<String, Object?>) {
    throw TestFailure('expected a non-null rematch in room frame: $roomFrame');
  }
  return (rematch['ready']! as List<Object?>).cast<int>();
}

/// The tail every failure in this file ends with: the scenario to re-run.
String _repro(String scenario) =>
    'scenario "$scenario" (deterministic, no seed; re-run with: cd '
    'packages/ludo_server && dart test $_file -N "$scenario")';

/// The next frame on [client], or a failure naming [who], what was owed
/// ([expected]) and [scenario] when nothing arrives within three seconds.
/// The wait is cancelled on timeout so a late frame is not swallowed.
Future<Map<String, Object?>> _nextFrame(
  WireTestClient client, {
  required String who,
  required String scenario,
  required String expected,
}) async {
  final Map<String, Object?>? frame =
      await client.nextOrNull(timeout: const Duration(seconds: 3));
  if (frame == null) {
    throw TestFailure(
      'expected $expected on $who and nothing arrived within 3 s. '
      '${_repro(scenario)}',
    );
  }
  return frame;
}

/// Reads the next frame on [client] and asserts it is a [type] frame.
Future<Map<String, Object?>> _expectFrame(
  WireTestClient client,
  String type, {
  required String who,
  required String scenario,
  required String expected,
}) async {
  final Map<String, Object?> frame = await _nextFrame(client,
      who: who, scenario: scenario, expected: 'a "$type" frame ($expected)');
  if (frame['t'] != type) {
    throw TestFailure(
      'expected a "$type" frame on $who ($expected) but the next frame was '
      '"${frame['t']}": ${frame['d']}. ${_repro(scenario)}',
    );
  }
  return frame;
}

/// A ping on each of [sockets] must come back as the pong answering it, with
/// nothing in front of it. [why] says what the silence proves.
Future<void> _expectQuiet(
  Map<String, WireTestClient> sockets, {
  required String scenario,
  required String why,
}) async {
  for (final MapEntry<String, WireTestClient> entry in sockets.entries) {
    final String id = entry.value.send('ping', <String, Object?>{});
    final Map<String, Object?> frame = await _nextFrame(entry.value,
        who: entry.key, scenario: scenario, expected: 'a pong');
    if (frame['t'] != 'pong' || frame['re'] != id) {
      throw TestFailure(
        'expected the next frame on ${entry.key} to be the pong answering '
        'its ping ($why) but got "${frame['t']}" with re=${frame['re']}: '
        '${frame['d']}. A game start was sent that the contract does not '
        'allow. ${_repro(scenario)}',
      );
    }
  }
}

/// The frames of one start as one socket received them: any number of
/// `seat_seed`, then `game_started`, then the standalone `turn`.
class _Start {
  _Start(this.who, this.seeds, this.gameStarted, this.turn);

  final String who;
  final List<Map<String, Object?>> seeds;
  final Map<String, Object?> gameStarted;
  final Map<String, Object?> turn;

  List<Map<String, Object?>> get all =>
      <Map<String, Object?>>[...seeds, gameStarted, turn];

  /// The seats named by the frozen `client_seeds` string of section 11.2
  /// (`seat:seed|seat:seed`), in the order it lists them.
  List<int> get seats => (_data(gameStarted)['client_seeds']! as String)
      .split('|')
      .map((String part) => int.parse(part.split(':').first))
      .toList();
}

/// Reads one start off [client]: `seat_seed` frames if any, `game_started`,
/// then `turn`, in that order, each with a bounded wait.
Future<_Start> _readStart(
  WireTestClient client, {
  required String who,
  required String scenario,
  required String expected,
}) async {
  final List<Map<String, Object?>> seeds = <Map<String, Object?>>[];
  Map<String, Object?> frame = await _nextFrame(client,
      who: who,
      scenario: scenario,
      expected: 'the game start ($expected): seat_seed or game_started');
  while (frame['t'] == 'seat_seed') {
    seeds.add(frame);
    frame = await _nextFrame(client,
        who: who,
        scenario: scenario,
        expected: 'game_started after the seat_seed frames ($expected)');
  }
  if (frame['t'] != 'game_started') {
    throw TestFailure(
      'expected game_started after the seat_seed frames on $who ($expected) '
      'but got "${frame['t']}": ${frame['d']}. ${_repro(scenario)}',
    );
  }
  final Map<String, Object?> turn = await _expectFrame(client, 'turn',
      who: who,
      scenario: scenario,
      expected: '$expected: the standalone turn right after game_started');
  return _Start(who, seeds, frame, turn);
}

/// Everything rule 5 says about a start that answers no request, plus the
/// seq chain of 16.4: no frame of [starts] has an `re` key, the first frame
/// is `afterSeq + 1`, each next is +1, `turn.seat` is `game_started.turn`,
/// the game's seats are [seats], and every socket saw the same seqs.
void _expectUnsolicitedStart(
  List<_Start> starts, {
  required int afterSeq,
  required List<int> seats,
  required String scenario,
}) {
  List<int>? firstSeqs;
  for (final _Start start in starts) {
    for (final Map<String, Object?> frame in start.all) {
      expect(frame.containsKey('re'), isFalse,
          reason: 'rule 5: a start triggered by a resume or a leave_room '
              'answers no request, so no frame of it carries re; '
              '"${frame['t']}" on ${start.who} carried re=${frame['re']}. '
              '${_repro(scenario)}');
    }
    final List<int> seqs = start.all.map(_seq).toList();
    expect(seqs, <int>[for (int i = 0; i < seqs.length; i++) afterSeq + 1 + i],
        reason: 'section 16.4: the start continues from the last frame '
            'before it (seq $afterSeq) and steps +1 per frame; ${start.who} '
            'saw ${start.all.map((Map<String, Object?> f) => '${f['t']}@${_seq(f)}').toList()}. '
            '${_repro(scenario)}');
    expect(start.seats, seats,
        reason: 'the game must be dealt to the occupied seats $seats; '
            '${start.who} got client_seeds='
            '"${_data(start.gameStarted)['client_seeds']}". '
            '${_repro(scenario)}');
    expect(_data(start.turn)['seat'], _data(start.gameStarted)['turn'],
        reason: 'section 13.1: turn.seat must equal game_started.turn on '
            '${start.who}. ${_repro(scenario)}');
    firstSeqs ??= seqs;
    expect(seqs, firstSeqs,
        reason: 'one counter per room: ${start.who} must see the same seqs '
            'as the first socket. ${_repro(scenario)}');
  }
}

/// Forces [code]'s room FINISHED the way rematch_test.dart does, with a
/// hand-built finished `GameState`. Pure fixture setup, no frame is sent.
void _forceFinished(ServerHarness harness, String code, {required int winner}) {
  final Room? room = harness.registry.lookup(code);
  if (room == null) {
    fail('fixture setup: room $code must still exist to be forced FINISHED');
  }
  final engine.GameState base = room.game!;
  room.game = engine.GameState(
    config: base.config,
    tokens: base.tokens,
    currentSeat: winner,
    phase: engine.GamePhase.finished,
    roll: null,
    sixes: 0,
    winner: winner,
    seq: base.seq + 1,
    rngState: base.rngState,
  );
  room.state = RoomState.finished;
}

/// Drains the ordinary start cascade off [client]: any number of `seat_seed`
/// frames, `game_started`, then the standalone `turn`. Fixture setup only.
Future<void> _drainStartCascade(WireTestClient client) async {
  Map<String, Object?> frame = await client.next();
  while (frame['t'] == 'seat_seed') {
    frame = await client.next();
  }
  if (frame['t'] != 'game_started') {
    fail('fixture setup: expected game_started after any seat_seed frames, '
        'got "${frame['t']}": ${frame['d']}');
  }
  final Map<String, Object?> turn = await client.next();
  if (turn['t'] != 'turn') {
    fail('fixture setup: expected the standalone turn right after '
        'game_started, got "${turn['t']}": ${turn['d']}');
  }
}

/// Builds a two-seat room, starts it, forces it FINISHED, and drains every
/// handshake frame, so both sockets sit right after the end of game 1. The
/// host is seat A in the cases below, the guest seat B.
Future<WireTestLobby> _finishedTwoSeatRoom(
  ServerHarness harness,
  List<WireTestClient> clients,
) async {
  final WireTestLobby lobby = await buildWireTestLobby(harness.wsUri, clients);
  lobby.host.client.send('start_game', <String, Object?>{});
  await _drainStartCascade(lobby.host.client);
  await _drainStartCascade(lobby.guest.client);
  _forceFinished(harness, lobby.code, winner: 0);
  return lobby;
}

class _ThreeSeatLobby {
  _ThreeSeatLobby({
    required this.code,
    required this.host,
    required this.mid,
    required this.far,
  });

  final String code;
  final WireTestSeat host;
  final WireTestSeat mid;
  final WireTestSeat far;
}

/// Three seats in one room, host/mid/far by join order, started, forced
/// FINISHED, every handshake frame drained. Same technique as
/// rematch_test.dart's helper of the same name, copied because that one is
/// private.
Future<_ThreeSeatLobby> _finishedThreeSeatRoom(
  ServerHarness harness,
  List<WireTestClient> clients,
) async {
  final WireTestClient hostClient = await WireTestClient.connect(harness.wsUri);
  clients.add(hostClient);
  hostClient
      .send('create_room', <String, Object?>{'name': 'Host', 'players': 3});
  final Map<String, Object?> hostSeatAssigned = await hostClient.next();
  final Map<String, Object?> hostRoomFrame = await hostClient.next();
  final String code = _data(hostRoomFrame)['code']! as String;

  Future<WireTestSeat> join(
      String name, List<WireTestClient> alreadySeated) async {
    final WireTestClient client = await WireTestClient.connect(harness.wsUri);
    clients.add(client);
    client.send('join_room', <String, Object?>{'code': code, 'name': name});
    final Map<String, Object?> assigned = await client.next();
    await client.next(); // room
    for (final WireTestClient seated in alreadySeated) {
      await seated.next(); // player_joined
    }
    return WireTestSeat(
      client: client,
      seat: _data(assigned)['seat']! as int,
      token: _data(assigned)['seat_token']! as String,
    );
  }

  final WireTestSeat mid = await join('Mid', <WireTestClient>[hostClient]);
  final WireTestSeat far =
      await join('Far', <WireTestClient>[hostClient, mid.client]);

  hostClient.send('start_game', <String, Object?>{});
  await _drainStartCascade(hostClient);
  await _drainStartCascade(mid.client);
  await _drainStartCascade(far.client);
  _forceFinished(harness, code, winner: 0);

  return _ThreeSeatLobby(
    code: code,
    host: WireTestSeat(
      client: hostClient,
      seat: _data(hostSeatAssigned)['seat']! as int,
      token: _data(hostSeatAssigned)['seat_token']! as String,
    ),
    mid: mid,
    far: far,
  );
}

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() {
    harness = ServerHarness.build();
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  Future<Uri> start() async {
    await harness.start();
    return harness.wsUri;
  }

  /// A new socket resuming [seat] of [code]; reads the resume's own
  /// `seat_assigned` and returns the socket and the `room` that follows it.
  Future<(WireTestClient, Map<String, Object?>)> resume(
    Uri uri,
    String code,
    WireTestSeat seat, {
    required String who,
    required String scenario,
  }) async {
    final WireTestClient fresh = await WireTestClient.connect(uri);
    clients.add(fresh);
    fresh.send('resume', <String, Object?>{
      'code': code,
      'seat_token': seat.token,
    });
    final Map<String, Object?> assigned = await _expectFrame(
        fresh, 'seat_assigned',
        who: who,
        scenario: scenario,
        expected: 'section 15: the resume answers seat_assigned first');
    expect(_data(assigned)['seat'], seat.seat,
        reason: 'the resumed seat keeps its number. ${_repro(scenario)}');
    final Map<String, Object?> room = await _expectFrame(fresh, 'room',
        who: who,
        scenario: scenario,
        expected: 'section 8 rule 4: the resume answers the room snapshot');
    return (fresh, room);
  }

  group('rule 5: auto-start after a resume', () {
    // Catches: a resume that restores the connected flag of the last missing
    // ready seat and leaves the table stuck, the exact defect rule 5 exists
    // for. Also catches a start that is sent but wrongly framed: an `re` on
    // the resuming socket (the resume's id is not owed a game_started), a
    // start sent to B before B's presence(true), or a seq step skipped or
    // repeated between the presence and the opening turn.
    test('two seats: A drops, B accepts, A resumes and the game starts',
        () async {
      const String scenario =
          'two seats: A drops, B accepts, A resumes and the game starts';
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.guest;

      a.client.send('rematch', <String, Object?>{});
      expect(_readyOf(await a.client.next()), <int>[a.seat]);
      await b.client.next(); // room, broadcast copy

      await a.client.close();
      final Map<String, Object?> away = await _expectFrame(b.client, 'presence',
          who: 'B',
          scenario: scenario,
          expected: 'section 8 rule 2: A\'s socket closed');
      expect(_data(away)['seat'], a.seat);
      expect(_data(away)['connected'], isFalse);

      final String acceptId = b.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> accept = await _expectFrame(b.client, 'room',
          who: 'B', scenario: scenario, expected: 'the room answering B');
      expect(accept['re'], acceptId);
      expect(_readyOf(accept), <int>[a.seat, b.seat]..sort(),
          reason: 'setup: both seats must be ready before A comes back. '
              '${_repro(scenario)}');
      await _expectQuiet(<String, WireTestClient>{'B': b.client},
          scenario: scenario,
          why: 'A is ready but offline, so section 16.4 forbids the start');

      final (WireTestClient aNew, Map<String, Object?> aRoom) = await resume(
        uri,
        lobby.code,
        a,
        who: 'A (new socket)',
        scenario: scenario,
      );
      expect(_data(aRoom)['state'], 'LOBBY',
          reason: 'the resume answers the LOBBY the seat left. '
              '${_repro(scenario)}');
      expect(_readyOf(aRoom), <int>[a.seat, b.seat]..sort());

      final Map<String, Object?> back = await _expectFrame(b.client, 'presence',
          who: 'B',
          scenario: scenario,
          expected: 'section 13.2: A\'s resume flipped the seat to connected');
      expect(_data(back)['seat'], a.seat);
      expect(_data(back)['connected'], isTrue);
      final int presenceSeq = _seq(back);
      expect(presenceSeq, _seq(away) + 2,
          reason: 'B\'s accept stepped seq once, A\'s return once more. '
              '${_repro(scenario)}');
      expect(_seq(aRoom), presenceSeq,
          reason: 'the snapshot is read off the same counter after the flip. '
              '${_repro(scenario)}');

      final _Start onA = await _readStart(aNew,
          who: 'A (new socket)',
          scenario: scenario,
          expected: 'rule 5: A\'s resume completed the ready set');
      final _Start onB = await _readStart(b.client,
          who: 'B',
          scenario: scenario,
          expected: 'rule 5: A\'s resume completed the ready set');
      _expectUnsolicitedStart(
        <_Start>[onA, onB],
        afterSeq: presenceSeq,
        seats: <int>[a.seat, b.seat]..sort(),
        scenario: scenario,
      );
    });

    // Catches: the connected term of 16.4 being dropped on the resume path
    // (a start while B, also ready, is still offline), and the resume of A
    // being treated as the completing event on its own.
    test('no start: resume while another ready seat is still offline',
        () async {
      const String scenario =
          'no start: resume while another ready seat is still offline';
      final Uri uri = await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.mid;
      final WireTestSeat c = lobby.far;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();
      await c.client.next();
      b.client.send('rematch', <String, Object?>{});
      await b.client.next();
      await a.client.next();
      await c.client.next();

      await a.client.close();
      await b.client.next(); // presence A false
      await c.client.next();
      await b.client.close();
      await c.client.next(); // presence B false

      c.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> accept = await _expectFrame(c.client, 'room',
          who: 'C', scenario: scenario, expected: 'the room answering C');
      expect(_readyOf(accept), <int>[a.seat, b.seat, c.seat]..sort(),
          reason: 'setup: every seat must be ready, two of them offline. '
              '${_repro(scenario)}');

      final (WireTestClient aNew, _) = await resume(
        uri,
        lobby.code,
        a,
        who: 'A (new socket)',
        scenario: scenario,
      );
      await _expectFrame(c.client, 'presence',
          who: 'C',
          scenario: scenario,
          expected: 'A\'s resume flipped the seat to connected');

      await _expectQuiet(<String, WireTestClient>{
        'A (new socket)': aNew,
        'C': c.client,
      },
          scenario: scenario,
          why: 'B is ready but still offline, so the set is not connected');
    });

    // Catches: a start on any resume into a rematch LOBBY that merely sees
    // everyone connected, without reading rematch.ready. B never accepted.
    test('no start: resume of a seat that is not ready', () async {
      const String scenario = 'no start: resume of a seat that is not ready';
      final Uri uri = await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.guest;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();

      await b.client.close();
      await _expectFrame(a.client, 'presence',
          who: 'A', scenario: scenario, expected: 'B\'s socket closed');

      final (WireTestClient bNew, Map<String, Object?> bRoom) = await resume(
        uri,
        lobby.code,
        b,
        who: 'B (new socket)',
        scenario: scenario,
      );
      expect(_readyOf(bRoom), <int>[a.seat],
          reason: 'setup: only A is ready. ${_repro(scenario)}');
      await _expectFrame(a.client, 'presence',
          who: 'A',
          scenario: scenario,
          expected: 'B\'s resume flipped the seat to connected');

      await _expectQuiet(<String, WireTestClient>{
        'A': a.client,
        'B (new socket)': bNew,
      },
          scenario: scenario,
          why: 'B resumed but never accepted, so the set is not ready');
    });

    // Catches: a resume into the first, non-rematch LOBBY evaluating
    // auto-start as "room full and everyone connected". The room is full
    // (two of two) and both seats are connected after the resume; rematch is
    // null, so no seat is ready.
    test('no start: resume into a first, non-rematch LOBBY', () async {
      const String scenario =
          'no start: resume into a first, non-rematch LOBBY';
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(harness.wsUri, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.guest;
      expect(lobby.guestRoom['rematch'], isNull,
          reason: 'setup: a first LOBBY has no rematch. ${_repro(scenario)}');

      await b.client.close();
      await _expectFrame(a.client, 'presence',
          who: 'A', scenario: scenario, expected: 'B\'s socket closed');

      final (WireTestClient bNew, _) = await resume(
        uri,
        lobby.code,
        b,
        who: 'B (new socket)',
        scenario: scenario,
      );
      await _expectFrame(a.client, 'presence',
          who: 'A',
          scenario: scenario,
          expected: 'B\'s resume flipped the seat to connected');

      await _expectQuiet(<String, WireTestClient>{
        'A': a.client,
        'B (new socket)': bNew,
      },
          scenario: scenario,
          why: 'a first LOBBY is started by the host, never by the server');
    });
  });

  group('rule 5: auto-start after a leave_room', () {
    // Catches: a leave that frees the last not-ready seat and leaves the
    // table stuck. Also catches the start being sent to the leaver (a
    // handler that reuses the sender's own copy of the start frames): the
    // leaver must get its player_left and nothing after it. Ping and pong
    // were chosen over a short nextOrNull on C because a pong is a
    // positive, ordered proof: any frame the server meant for C is queued
    // ahead of it, with no timer to tune.
    test('three seats: A and B ready, C leaves and the game starts', () async {
      const String scenario =
          'three seats: A and B ready, C leaves and the game starts';
      await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.mid;
      final WireTestSeat c = lobby.far;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();
      await c.client.next();
      b.client.send('rematch', <String, Object?>{});
      await b.client.next();
      await a.client.next();
      final Map<String, Object?> cLast = await c.client.next();
      expect(_readyOf(cLast), <int>[a.seat, b.seat]..sort(),
          reason: 'setup: A and B ready, C not. ${_repro(scenario)}');

      final String leaveId = c.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> cLeft = await _expectFrame(
          c.client, 'player_left',
          who: 'C',
          scenario: scenario,
          expected: 'section 4: the leaver is told what the room is told');
      expect(cLeft['re'], leaveId);
      expect(_data(cLeft)['seat'], c.seat);
      final Map<String, Object?> aLeft = await _expectFrame(
          a.client, 'player_left',
          who: 'A', scenario: scenario, expected: 'C\'s leave broadcast');
      final Map<String, Object?> bLeft = await _expectFrame(
          b.client, 'player_left',
          who: 'B', scenario: scenario, expected: 'C\'s leave broadcast');
      expect(_seq(aLeft), _seq(cLeft));
      expect(_seq(bLeft), _seq(cLeft));
      expect(_data(aLeft)['seat'], c.seat);

      await _expectQuiet(<String, WireTestClient>{'C': c.client},
          scenario: scenario,
          why: 'rule 5: the leaving socket gets nothing after its '
              'player_left');

      final _Start onA = await _readStart(a.client,
          who: 'A',
          scenario: scenario,
          expected: 'rule 5: C\'s leave left every seat ready and connected');
      final _Start onB = await _readStart(b.client,
          who: 'B',
          scenario: scenario,
          expected: 'rule 5: C\'s leave left every seat ready and connected');
      _expectUnsolicitedStart(
        <_Start>[onA, onB],
        afterSeq: _seq(cLeft),
        seats: <int>[a.seat, b.seat]..sort(),
        scenario: scenario,
      );
    });

    // Catches: a leave that leaves a single occupied seat starting a
    // one-player game because that seat is ready and connected. Section 16.4
    // requires at least two occupied seats.
    test('no start: a leave that leaves one seat', () async {
      const String scenario = 'no start: a leave that leaves one seat';
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.guest;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();

      b.client.send('leave_room', <String, Object?>{});
      await _expectFrame(b.client, 'player_left',
          who: 'B', scenario: scenario, expected: 'B\'s own leave');
      await _expectFrame(a.client, 'player_left',
          who: 'A', scenario: scenario, expected: 'B\'s leave broadcast');

      await _expectQuiet(<String, WireTestClient>{
        'A': a.client,
        'B (left)': b.client,
      },
          scenario: scenario,
          why: 'only A is left, ready and connected, but two seats are '
              'required');
    });

    // Catches: a leave of a ready seat starting the game while another
    // remaining seat has not accepted. C is ready and leaves; B never
    // accepted and stays.
    test('no start: a leave while another remaining seat is not ready',
        () async {
      const String scenario =
          'no start: a leave while another remaining seat is not ready';
      await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.mid;
      final WireTestSeat c = lobby.far;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();
      await c.client.next();
      c.client.send('rematch', <String, Object?>{});
      await c.client.next();
      await a.client.next();
      final Map<String, Object?> bLast = await b.client.next();
      expect(_readyOf(bLast), <int>[a.seat, c.seat]..sort(),
          reason: 'setup: A and C ready, B not. ${_repro(scenario)}');

      c.client.send('leave_room', <String, Object?>{});
      await _expectFrame(c.client, 'player_left',
          who: 'C', scenario: scenario, expected: 'C\'s own leave');
      await _expectFrame(a.client, 'player_left',
          who: 'A', scenario: scenario, expected: 'C\'s leave broadcast');
      await _expectFrame(b.client, 'player_left',
          who: 'B', scenario: scenario, expected: 'C\'s leave broadcast');

      await _expectQuiet(<String, WireTestClient>{
        'A': a.client,
        'B': b.client,
        'C (left)': c.client,
      }, scenario: scenario, why: 'B is still seated and not ready');
    });
  });

  group('rule 5: join_room is never evaluated', () {
    // Catches: a join into a rematch LOBBY starting the game because every
    // other seat is ready and connected. The table is emptied down to A
    // (ready) first, so the only state the joiner changes is "one more seat,
    // not ready". The last step accepts for the joiner and expects the
    // start, which shows the silence before it was a decision and not a
    // room that could not start.
    test('no start: join_room into a rematch LOBBY with every other seat ready',
        () async {
      const String scenario =
          'no start: join_room into a rematch LOBBY with every other seat ready';
      final Uri uri = await start();
      final _ThreeSeatLobby lobby =
          await _finishedThreeSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.mid;
      final WireTestSeat c = lobby.far;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();
      await c.client.next();

      b.client.send('leave_room', <String, Object?>{});
      await b.client.next();
      await a.client.next();
      await c.client.next();
      c.client.send('leave_room', <String, Object?>{});
      await c.client.next();
      final Map<String, Object?> lastLeft = await _expectFrame(
          a.client, 'player_left',
          who: 'A', scenario: scenario, expected: 'C\'s leave broadcast');
      await _expectQuiet(<String, WireTestClient>{'A': a.client},
          scenario: scenario,
          why: 'setup: A alone is ready and connected, but two seats are '
              'required');

      final WireTestClient d = await WireTestClient.connect(uri);
      clients.add(d);
      d.send('join_room', <String, Object?>{'code': lobby.code, 'name': 'D'});
      await _expectFrame(d, 'seat_assigned',
          who: 'D', scenario: scenario, expected: 'the join');
      final Map<String, Object?> dRoom = await _expectFrame(d, 'room',
          who: 'D', scenario: scenario, expected: 'the join');
      expect(_readyOf(dRoom), <int>[a.seat],
          reason: 'setup: the joiner is not ready, A is. ${_repro(scenario)}');
      await _expectFrame(a.client, 'player_joined',
          who: 'A', scenario: scenario, expected: 'D\'s join broadcast');

      await _expectQuiet(<String, WireTestClient>{
        'A': a.client,
        'D': d,
      },
          scenario: scenario,
          why: 'rule 5: a joiner is not ready, so join_room never starts');

      d.send('rematch', <String, Object?>{});
      await _expectFrame(d, 'room',
          who: 'D', scenario: scenario, expected: 'D\'s own accept');
      await _expectFrame(a.client, 'room',
          who: 'A', scenario: scenario, expected: 'D\'s accept broadcast');
      await _readStart(a.client,
          who: 'A',
          scenario: scenario,
          expected: 'D\'s accept completed the ready set (seq after '
              '${_seq(lastLeft)})');
    });
  });

  group('16.4 the accept path is unchanged', () {
    // Catches: rule 5 changing what the last accept's start carries. Today
    // (connection.dart _handleRematch and _publishStart) the accept answers
    // a request: the accepter's own game_started and turn carry re set to
    // the accept's id, the other socket's copies carry none, and the
    // server-drawn seat_seed broadcasts carry none on either socket. The
    // seq runs on from the room that recorded the acceptance.
    test(
        'the last accept still starts, with re on the accepter\'s '
        'game_started and turn only', () async {
      const String scenario =
          'the last accept still starts, with re on the accepter\'s '
          'game_started and turn only';
      await start();
      final WireTestLobby lobby = await _finishedTwoSeatRoom(harness, clients);
      final WireTestSeat a = lobby.host;
      final WireTestSeat b = lobby.guest;

      a.client.send('rematch', <String, Object?>{});
      await a.client.next();
      await b.client.next();

      final String acceptId = b.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> bRoom = await _expectFrame(b.client, 'room',
          who: 'B', scenario: scenario, expected: 'the room answering B');
      final Map<String, Object?> aRoom = await _expectFrame(a.client, 'room',
          who: 'A', scenario: scenario, expected: 'B\'s accept broadcast');
      expect(bRoom['re'], acceptId);
      expect(aRoom.containsKey('re'), isFalse);

      final _Start onB = await _readStart(b.client,
          who: 'B (accepter)',
          scenario: scenario,
          expected: 'section 16.4: the last accept starts the game');
      final _Start onA = await _readStart(a.client,
          who: 'A',
          scenario: scenario,
          expected: 'section 16.4: the last accept starts the game');

      for (final _Start side in <_Start>[onA, onB]) {
        for (final Map<String, Object?> seed in side.seeds) {
          expect(seed.containsKey('re'), isFalse,
              reason: 'seat_seed is a broadcast with no actor, on '
                  '${side.who}. ${_repro(scenario)}');
        }
      }
      expect(onB.gameStarted['re'], acceptId,
          reason: 'the accepter\'s own game_started answers its rematch. '
              '${_repro(scenario)}');
      expect(onB.turn['re'], acceptId,
          reason: 'the accepter\'s own turn answers its rematch. '
              '${_repro(scenario)}');
      expect(onA.gameStarted.containsKey('re'), isFalse,
          reason: 'the other socket\'s game_started carries no re. '
              '${_repro(scenario)}');
      expect(onA.turn.containsKey('re'), isFalse,
          reason: 'the other socket\'s turn carries no re. '
              '${_repro(scenario)}');
      expect(onA.all.map(_seq).toList(), onB.all.map(_seq).toList());
      expect(onB.all.map(_seq).toList(),
          <int>[for (int i = 0; i < onB.all.length; i++) _seq(bRoom) + 1 + i],
          reason: 'the start continues from the room that recorded the '
              'acceptance, +1 per frame. ${_repro(scenario)}');
      expect(onB.seats, <int>[a.seat, b.seat]..sort());
    });
  });
}
