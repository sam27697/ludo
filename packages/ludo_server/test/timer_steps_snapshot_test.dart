// Order 432 -- server tests for C-432 ("timer steps survive a resume"),
// written from work/ludo/orders/C-432-timer-steps-survive-resume.md and
// docs/PROTOCOL.md sections 8, 22 and 23 only.
//
// The contract under test (section 23): every seat object of every snapshot,
// the `room` frame and the answer to `resume`, carries `timer_steps`, an int
// that is never negative and is always present. In PLAYING and FINISHED it is
// the number of `rolled` and `moved` frames carrying `by: "timer"` for that
// seat since the later of the current `game_started` and that seat's own most
// recent accepted `roll` or `move`. A timer step adds one, a client's accepted
// `roll` or `move` sets its own seat to 0, `game_started` sets every seat to
// 0, a rejected request changes nothing, LOBBY reads 0, FINISHED keeps the
// value it had at `game_over`. No frame other than a snapshot carries it.
//
// Case map (the order's names, plus X cases for rules of section 23 the
// order's list leaves out):
//   S1  LOBBY reads 0 (S1a two seats, S1b four-player table, S1c the resume
//       answer right after game_started)
//   S2  one expiry roll leaving a move pending: that seat 1, the others 0
//   S3  then the expiry move: 2
//   S4  an expiry roll with no legal move: 1, the turn_passed adds nothing
//   S5  the seat's own accepted roll on its next turn: 0, and another
//       seat's accepted roll does not reset it
//   S6  rejected requests (out of turn, wrong phase, bad field, replayed id)
//       leave the count unchanged
//   S7  a rematch: the rematch LOBBY reads 0, the new game_started resets
//       every seat, and the new game counts from 0
//   S8  no rolled, moved, turn, turn_passed, game_over or game_log frame
//       contains the key
//   X1  FINISHED keeps the value it had at game_over
//   X2  an accepted client `move` resets, as an accepted `roll` does
//   X3  both seats away for two expiries, both resume, counts survive
//
// On 12853b9 (section 23 written, nothing built): every case that reads a
// snapshot is red for the same reason, the seat objects carry no
// `timer_steps` key. S8 is green: it scans frames that must never carry the
// key, and it stays meaningful once the key exists because it also demands
// that the scan saw every frame type the rule names, timer-played ones
// included.
//
// Everything runs over real sockets against a real WireServer
// (test/support/wire_harness.dart). Expiries are driven exactly as
// timer_step_by_test.dart and resume_after_expiry_test.dart drive them:
// `automaticTurnExpiry: false`, the injected FakeClock advanced past
// `rules.turn_seconds` read off the wire, then one synchronous
// `runTurnExpiryOnce()`. Dice are real: the server secret is steered with
// test/support/dice_oracle.dart and the face sequences are found with
// test/support/engine_search.dart, as resume_after_expiry_test.dart does.
// The only board edit is `_forceGame`, the technique timer_step_by_test.dart
// and turn_timer_conformance_test.dart already use, for the cases that need
// a specific winning board (S7, S8, X1); the engine is never replaced.
//
// Snapshots are read off a real `resume` answer, never off Registry
// internals. A resume on a fresh socket for a seat that still has a live
// socket takes the seat over (section 8 rule 6) and broadcasts nothing, which
// is how a mid-game snapshot is taken without disturbing the other seat.
//
// Every failure message names the contract rule, the defect it catches, what
// the snapshot actually said, and the scenario, steered faces and room code
// to reproduce it. There is no randomness beyond the scripted byte source and
// no wall-clock wait.

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

const String _hostSeed = 'order432-host-seed';
const String _guestSeed = 'order432-guest-seed';

/// Seats of a two-player room are fixed at 0 and 2 in join order
/// (lib/src/registry.dart `_seatIndicesFor`, asserted below, not trusted).
const String _clientSeeds = '0:$_hostSeed|2:$_guestSeed';

const String _file = 'test/timer_steps_snapshot_test.dart';

String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

/// A closing-roll sequence whose last roll leaves a legal move for the seat
/// that did not open the game: the host passes with a non-6, the guest queues
/// a 6, and the timer's closing non-6 leaves the queued 6 to be moved. The
/// same search resume_after_expiry_test.dart runs for its await_roll case.
List<int> _awaitRollExpiryFaces() {
  const List<int> seats = <int>[0, 2];
  final List<int>? faces = findFaceSequence(
    seats: seats,
    rules: serverRoomRules,
    accepts: (EngineRollStep step, engine.GameState after) =>
        step.legal.isNotEmpty && after.currentSeat != seats.first,
  );
  expect(
    faces,
    isNotNull,
    reason: 'setup: engine_search found no face sequence whose last roll '
        'leaves a legal move for the non-opening seat',
  );
  return faces!;
}

List<List<int>> _boardFor(Map<int, List<int>> bySeat) {
  return <List<int>>[
    for (int seat = 0; seat < 4; seat++)
      List<int>.of(bySeat[seat] ?? const <int>[-1, -1, -1, -1]),
  ];
}

/// Overwrites the room's game with a hand-built board, keeping its own
/// config, seq and rng state, exactly as timer_step_by_test.dart does.
void _forceGame(
  Room room, {
  required int currentSeat,
  required engine.GamePhase phase,
  int? roll,
  required Map<int, List<int>> tokens,
}) {
  final engine.GameState base = room.game!;
  room.game = engine.GameState(
    config: base.config,
    tokens: _boardFor(tokens),
    currentSeat: currentSeat,
    phase: phase,
    roll: null,
    sixes: 0,
    winner: null,
    seq: base.seq + 1,
    rngState: base.rngState,
    queue: roll == null ? const <int>[] : <int>[roll],
  );
}

typedef Frame = Map<String, Object?>;

Frame _data(Frame frame) => frame['d']! as Frame;

/// One seat's live socket.
class _Conn {
  _Conn(this.client, this.token);
  final WireTestClient client;
  final String token;
}

/// A running two-seat table plus everything needed to drive it and to say how
/// to rebuild it when a case fails.
class _Table {
  _Table({
    required this.harness,
    required this.lobby,
    required this.clients,
    required this.scenario,
    required this.faces,
    required this.started,
  }) {
    conns[lobby.host.seat] = _Conn(lobby.host.client, lobby.host.token);
    conns[lobby.guest.seat] = _Conn(lobby.guest.client, lobby.guest.token);
  }

  final ServerHarness harness;
  final WireTestLobby lobby;
  final List<WireTestClient> clients;
  final String scenario;
  final List<int> faces;
  final Frame started;
  final Map<int, _Conn> conns = <int, _Conn>{};

  /// Every frame read through this table, in read order, for S8.
  final List<Frame> seen = <Frame>[];

  /// Ids this table sent per seat, in order.
  final Map<int, List<String>> sentIds = <int, List<String>>{};

  String get code => lobby.code;
  int get host => lobby.host.seat;
  int get guest => lobby.guest.seat;
  Room get room => harness.registry.lookup(code)!;

  int get turnSeconds {
    final Frame rules = lobby.hostRoom['rules']! as Frame;
    return rules['turn_seconds']! as int;
  }

  String repro(String name) =>
      'Reproduce: cd packages/ludo_server && dart test $_file '
      '--plain-name "$name" (scenario $scenario, steered faces $faces, '
      'client seeds $_clientSeeds, room $code, turn_seconds $turnSeconds; '
      'fully deterministic, the injected clock is the only clock)';

  Future<Frame> read(int seat) async {
    final _Conn? conn = conns[seat];
    if (conn == null) {
      fail('test bug: seat $seat has no live socket in scenario $scenario');
    }
    final Frame frame = await conn.client.next();
    seen.add(frame);
    return frame;
  }

  /// Reads one logical step off [seat]'s socket: frames up to and including a
  /// `turn`, a `game_over`, or a `rolled` that leaves a legal move pending
  /// (nothing follows that one). `presence` frames are recorded and skipped:
  /// a resume or a drop on the other seat produces them and no case here
  /// asserts on them.
  Future<List<Frame>> step(int seat) async {
    final List<Frame> frames = <Frame>[];
    while (true) {
      final Frame frame = await read(seat);
      if (frame['t'] == 'presence') {
        continue;
      }
      frames.add(frame);
      final String type = frame['t']! as String;
      if (type == 'turn' || type == 'game_over') {
        return frames;
      }
      if (type == 'error') {
        return frames;
      }
      if (type == 'rolled' &&
          (_data(frame)['legal']! as List<Object?>).isNotEmpty) {
        return frames;
      }
    }
  }

  /// One step off every live socket, asserting they saw the same frame types
  /// in the same order (section 12.3). Returns each seat's frames.
  Future<Map<int, List<Frame>>> stepAll() async {
    final Map<int, List<Frame>> bySeat = <int, List<Frame>>{};
    for (final int seat in conns.keys.toList()..sort()) {
      bySeat[seat] = await step(seat);
    }
    if (bySeat.length > 1) {
      final List<String> first =
          bySeat.values.first.map((Frame f) => f['t']! as String).toList();
      for (final MapEntry<int, List<Frame>> e in bySeat.entries) {
        expect(
          e.value.map((Frame f) => f['t']! as String).toList(),
          first,
          reason: 'section 12.3: a broadcast reaches every socket with the '
              'same frames in the same order; seat ${e.key} saw '
              '${e.value.map((Frame f) => f['t']).toList()} against $first '
              'in room $code',
        );
      }
    }
    return bySeat;
  }

  /// Sends [type] from [seat] and returns the frames that socket got back.
  /// The reply must be an accepted step answering this id.
  Future<List<Frame>> act(
    int seat,
    String type,
    Frame data, {
    String? id,
  }) async {
    final String sent = conns[seat]!.client.send(type, data, id: id);
    (sentIds[seat] ??= <String>[]).add(sent);
    final Map<int, List<Frame>> all = await stepAll();
    final List<Frame> mine = all[seat]!;
    expect(
      mine.first['t'],
      isNot('error'),
      reason: 'setup: the $type sent by seat $seat (id $sent) must be '
          'accepted; got ${mine.first}. ${repro(scenario)}',
    );
    expect(
      mine.first['re'],
      sent,
      reason: 'the sender\'s own copy must answer id $sent; got '
          '${mine.first['re']}',
    );
    return mine;
  }

  /// Sends [type] from [seat] and expects exactly the error [code] back on
  /// that socket, answering [id].
  Future<void> reject(
    int seat,
    String type,
    Frame data, {
    required String code,
    String? id,
    required String because,
  }) async {
    final String sent = conns[seat]!.client.send(type, data, id: id);
    final Frame frame = await read(seat);
    expect(
      frame['t'],
      'error',
      reason: 'setup: $because; expected an error frame for the $type from '
          'seat $seat, got "${frame['t']}": ${frame['d']}',
    );
    expect(
      _data(frame)['code'],
      code,
      reason: 'setup: $because; expected error $code for the $type from '
          'seat $seat, got ${_data(frame)['code']}',
    );
    expect(frame['re'], sent);
  }

  /// Advances the injected clock past one segment and runs one sweep. Returns
  /// the frames the first live socket saw (empty when nobody is connected).
  Future<List<Frame>> expire() async {
    harness.clock.advance(Duration(seconds: turnSeconds + 1));
    harness.server.runTurnExpiryOnce();
    if (conns.isEmpty) {
      return <Frame>[];
    }
    final Map<int, List<Frame>> all = await stepAll();
    return all.values.first;
  }

  /// Closes [seat]'s socket, the way a phone that left the network does.
  Future<void> drop(int seat) async {
    final _Conn? conn = conns.remove(seat);
    if (conn != null) {
      await conn.client.close();
    }
  }

  /// A `resume` for [seat] on a fresh socket, the new socket replacing the old
  /// one (a takeover when the old one is still open). Returns the `room`
  /// snapshot of the answer.
  Future<Frame> snapshot(int seat) async {
    final String token = seat == host ? lobby.host.token : lobby.guest.token;
    final WireTestClient fresh = await WireTestClient.connect(harness.wsUri);
    clients.add(fresh);
    fresh.send('resume', <String, Object?>{'code': code, 'seat_token': token});
    await expectSeatAssigned(
      fresh,
      expectedSeat: seat,
      expectedToken: token,
      because:
          'a snapshot is read off the answer to resume; ${repro(scenario)}',
    );
    final Frame room = await fresh.next();
    seen.add(room);
    expect(
      room['t'],
      'room',
      reason: 'setup: the answer to resume is seat_assigned then room '
          '(section 8 rule 4); got "${room['t']}": ${room['d']}',
    );
    final _Conn? old = conns[seat];
    conns[seat] = _Conn(fresh, token);
    if (old != null) {
      await old.client.close();
    }
    return _data(room);
  }
}

/// Asserts every seat object in [room] carries `timer_steps` equal to the
/// value wanted for its seat number, and that the seats are exactly those
/// named in [want].
void _expectSteps(
  _Table table,
  Frame room,
  Map<int, int> want, {
  required String name,
  required String rule,
  required String defect,
  String? state,
}) {
  final String why = 'docs/PROTOCOL.md section 23 $rule. Catches: $defect. '
      '${table.repro(name)}';
  if (state != null) {
    expect(room['state'], state,
        reason: 'setup: the snapshot must be $state; got ${room['state']}. '
            '$why');
  }
  final List<Object?> seats = room['seats']! as List<Object?>;
  expect(
    seats.map((Object? s) => (s! as Frame)['seat']).toList()..sort(),
    want.keys.toList()..sort(),
    reason: 'setup: the snapshot must list exactly seats ${want.keys}; $why',
  );
  for (final Object? entry in seats) {
    final Frame seat = entry! as Frame;
    final int number = seat['seat']! as int;
    expect(
      seat.containsKey('timer_steps'),
      isTrue,
      reason: 'rule 1: every seat object of every snapshot carries '
          'timer_steps, always present; seat $number of the ${room['state']} '
          'snapshot has keys ${seat.keys.toList()}. $why',
    );
    expect(
      seat['timer_steps'],
      isA<int>(),
      reason: 'rule 1: timer_steps is an integer; seat $number carried '
          '${seat['timer_steps'].runtimeType} ${seat['timer_steps']}. $why',
    );
    expect(
      seat['timer_steps']! as int,
      greaterThanOrEqualTo(0),
      reason: 'rule 1: timer_steps is never negative; seat $number carried '
          '${seat['timer_steps']}. $why',
    );
    expect(
      seat['timer_steps'],
      want[number],
      reason: 'expected seat $number to read ${want[number]}, the snapshot '
          'says ${seat['timer_steps']} (all seats: '
          '${seats.map((Object? s) => '${(s! as Frame)['seat']}='
              '${(s as Frame)['timer_steps']}').join(', ')}). $why',
    );
  }
}

bool _hasKeyDeep(Object? node, String key) {
  if (node is Map) {
    for (final MapEntry<Object?, Object?> e in node.entries) {
      if (e.key == key || _hasKeyDeep(e.value, key)) {
        return true;
      }
    }
    return false;
  }
  if (node is List) {
    return node.any((Object? child) => _hasKeyDeep(child, key));
  }
  return false;
}

void main() {
  final List<WireTestClient> clients = <WireTestClient>[];
  ServerHarness? harness;

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness?.close();
    harness = null;
  });

  /// A two-seat table whose first `faces.length` dice are steered, both seats
  /// seeded, started, with the opening turn consumed on both sockets.
  Future<_Table> steeredTable(String scenario, List<int> faces) async {
    final String gameId = _predictedGameId();
    final SteeredSecret steered = findSecretForFaces(
      wanted: faces,
      gameId: gameId,
      clientSeeds: _clientSeeds,
    );
    harness = ServerHarness.build(
      secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
      automaticTurnExpiry: false,
    );
    await harness!.start();
    final WireTestLobby lobby =
        await buildWireTestLobby(harness!.wsUri, clients, players: 2);
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      <int>[0, 2],
      reason: 'setup: the fixed 2-player seat mapping (host 0, guest 2) is '
          'what _clientSeeds is computed from; got ${lobby.host.seat} and '
          '${lobby.guest.seat}',
    );
    lobby.host.client
        .send('set_seed', <String, Object?>{'client_seed': _hostSeed});
    await receiveType(lobby.host.client, 'seat_seed');
    lobby.guest.client
        .send('set_seed', <String, Object?>{'client_seed': _guestSeed});
    await receiveType(lobby.guest.client, 'seat_seed');
    lobby.host.client.send('start_game', <String, Object?>{});
    final Frame hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Frame startedData = _data(hostStarted);
    await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);
    expect(startedData['game_id'], gameId,
        reason: 'setup: the predicted game_id must match game_started');
    expect(
      startedData['turn'],
      lobby.host.seat,
      reason: 'setup requires the host to hold the opening turn; got '
          '${startedData['turn']}',
    );
    return _Table(
      harness: harness!,
      lobby: lobby,
      clients: clients,
      scenario: scenario,
      faces: faces,
      started: startedData,
    );
  }

  /// Steered faces [2, 3, 4]: every roll is a non-6 on an all-yard board, so
  /// each roll has no legal move and passes the turn. Host rolls first.
  Future<_Table> passingTable(String scenario) =>
      steeredTable(scenario, const <int>[2, 3, 4]);

  /// The await_roll expiry fixture: the host passes, the guest queues a 6 by
  /// its own client rolls, and it is the guest's turn to roll when the caller
  /// expires the segment, which makes the timer roll a closing non-6 that
  /// leaves a legal move. The host's turn took only client rolls.
  Future<_Table> awaitRollTable(String scenario) async {
    final List<int> faces = _awaitRollExpiryFaces();
    final _Table table = await steeredTable(scenario, faces);
    int index = 0;
    bool handedOff = false;
    while (!handedOff) {
      if (index >= faces.length) {
        fail('setup: faces $faces never handed an unrolled turn to the guest');
      }
      final List<Frame> frames = await table.act(
        table.host,
        'roll',
        <String, Object?>{},
      );
      final Frame rolled = frames.first;
      expect(rolled['t'], 'rolled');
      expect(_data(rolled)['value'], faces[index],
          reason: 'setup: steering must give ${faces[index]} at roll '
              '${index + 1}; got ${_data(rolled)['value']}');
      expect(_data(rolled)['legal'], isEmpty,
          reason: 'setup: the handoff rolls leave no move');
      index++;
      expect(frames.last['t'], 'turn');
      handedOff = _data(frames.last)['seat'] == table.guest;
    }
    for (; index < faces.length - 1; index++) {
      final List<Frame> frames = await table.act(
        table.guest,
        'roll',
        <String, Object?>{},
      );
      expect(_data(frames.first)['value'], faces[index],
          reason: 'setup: steering must give ${faces[index]} at roll '
              '${index + 1}; got ${_data(frames.first)['value']}');
      expect(_data(frames.first)['legal'], isEmpty,
          reason: 'setup: a queued 6 leaves no move yet');
      expect(_data(frames.last)['seat'], table.guest);
      expect(_data(frames.last)['phase'], 'await_roll');
    }
    return table;
  }

  /// passingTable after one timer roll for the host (host reads 1), then the
  /// guest forced onto a winning board and the timer playing the winning
  /// move: FINISHED, the guest the winner, both seats at 1.
  Future<_Table> finishedByTimerTable(String scenario) async {
    final _Table table = await passingTable(scenario);
    final List<Frame> first = await table.expire();
    expect(first.first['t'], 'rolled');
    expect(_data(first.first)['seat'], table.host);
    _forceGame(
      table.room,
      currentSeat: table.guest,
      phase: engine.GamePhase.awaitMove,
      roll: 3,
      tokens: <int, List<int>>{
        table.host: <int>[-1, -1, -1, -1],
        table.guest: <int>[54, 57, 57, 57],
      },
    );
    expect(engine.legalTokens(table.room.game!), <int>[0]);
    final List<Frame> second = await table.expire();
    expect(
        second.map((Frame f) => f['t']).toList(),
        <String>[
          'moved',
          'game_over',
        ],
        reason: 'setup: the expiry move must win the game');
    return table;
  }

  group('S1: LOBBY reads 0 for every seat', () {
    test(
        'S1a two seats: the create and join replies and the LOBBY resume '
        'answer carry timer_steps 0, an int, on every seat object', () async {
      harness = ServerHarness.build(automaticTurnExpiry: false);
      await harness!.start();
      final WireTestLobby lobby =
          await buildWireTestLobby(harness!.wsUri, clients, players: 2);
      final _Table table = _Table(
        harness: harness!,
        lobby: lobby,
        clients: clients,
        scenario: 'lobby-2',
        faces: const <int>[],
        started: const <String, Object?>{},
      );
      const String name = 'S1a';
      _expectSteps(
        table,
        lobby.hostRoom,
        <int, int>{lobby.host.seat: 0},
        name: name,
        state: 'LOBBY',
        rule: 'rule 3 (LOBBY reads 0) and rule 1 (always present), the room '
            'reply to create_room',
        defect: 'a snapshot builder that leaves the key out when the game '
            'has not started',
      );
      _expectSteps(
        table,
        lobby.guestRoom,
        <int, int>{lobby.host.seat: 0, lobby.guest.seat: 0},
        name: name,
        state: 'LOBBY',
        rule: 'rule 1, the room reply to join_room',
        defect: 'the key present on create_room but not on join_room',
      );
      final Frame resumed = await table.snapshot(lobby.guest.seat);
      _expectSteps(
        table,
        resumed,
        <int, int>{lobby.host.seat: 0, lobby.guest.seat: 0},
        name: name,
        state: 'LOBBY',
        rule: 'rules 1 and 3, the answer to resume in LOBBY',
        defect: 'resume building seats through a path that skips the key',
      );
    });

    test(
        'S1b four-player table with two seated: every seat object that is '
        'listed carries timer_steps 0', () async {
      harness = ServerHarness.build(automaticTurnExpiry: false);
      await harness!.start();
      final WireTestLobby lobby =
          await buildWireTestLobby(harness!.wsUri, clients, players: 4);
      final _Table table = _Table(
        harness: harness!,
        lobby: lobby,
        clients: clients,
        scenario: 'lobby-4',
        faces: const <int>[],
        started: const <String, Object?>{},
      );
      final Map<int, int> want = <int, int>{
        for (final Object? s in lobby.guestRoom['seats']! as List<Object?>)
          (s! as Frame)['seat']! as int: 0,
      };
      expect(want.length, 2,
          reason: 'setup: two seats are filled in this table; got $want');
      _expectSteps(
        table,
        lobby.guestRoom,
        want,
        name: 'S1b',
        state: 'LOBBY',
        rule: 'rule 1, every seat object of every snapshot, whatever the '
            'player count',
        defect: 'the key added only for two-player tables',
      );
    });

    test(
        'S1c right after game_started and before any step: the resume answer '
        'reads 0 for every seat', () async {
      final _Table table = await passingTable('started-untouched');
      final Frame room = await table.snapshot(table.guest);
      _expectSteps(
        table,
        room,
        <int, int>{table.host: 0, table.guest: 0},
        name: 'S1c',
        state: 'PLAYING',
        rule: 'rules 2 and 3 (nothing counted since game_started)',
        defect: 'a count that starts at null or at a leftover value',
      );
    });
  });

  group('S2 and S3: a timer roll that leaves a move, then the timer move', () {
    test(
        'S2 one expiry roll leaving a move pending for the guest: the guest '
        'reads 1, the host 0', () async {
      final _Table table = await awaitRollTable('await-roll-expiry');
      final List<Frame> frames = await table.expire();
      expect(frames.first['t'], 'rolled',
          reason: 'setup: the sweep must roll for the guest; got $frames');
      expect(_data(frames.first)['seat'], table.guest);
      expect(_data(frames.first)['by'], 'timer',
          reason: 'setup (section 22): the sweep\'s roll carries by: timer');
      expect(_data(frames.first)['legal'], isNotEmpty,
          reason: 'setup: the timer roll must leave a move pending');
      final Frame room = await table.snapshot(table.host);
      _expectSteps(
        table,
        room,
        <int, int>{table.host: 0, table.guest: 1},
        name: 'S2',
        state: 'PLAYING',
        rule: 'rule 2 (each rolled frame carrying by: timer adds one) after '
            'the guest\'s own client rolls reset it to 0',
        defect: 'the timer roll not counted, counted for the wrong seat, or '
            'the seat\'s earlier client rolls still contributing',
      );
    });

    test(
        'S3 then the expiry move: the guest reads 2, and the timer\'s own '
        'call into the roll and move paths did not reset it', () async {
      final _Table table = await awaitRollTable('await-roll-expiry');
      final List<Frame> roll = await table.expire();
      expect(_data(roll.first)['by'], 'timer');
      final List<Frame> move = await table.expire();
      expect(move.first['t'], 'moved',
          reason: 'setup: the second sweep must play the pending move; got '
              '$move');
      expect(_data(move.first)['seat'], table.guest);
      expect(_data(move.first)['by'], 'timer',
          reason: 'setup (section 22): the sweep\'s move carries by: timer');
      final Frame room = await table.snapshot(table.host);
      _expectSteps(
        table,
        room,
        <int, int>{table.host: 0, table.guest: 2},
        name: 'S3',
        state: 'PLAYING',
        rule: 'rule 2 (a timer roll then a timer move is 2) and rule 3 '
            '(only the seat\'s own client resets it)',
        defect: 'the timer calling the same roll/move methods a client does '
            'and so resetting the count to 0 after each step, or counting '
            'rolls only',
      );
    });
  });

  test(
      'S4 a timer roll with no legal move: the host reads 1, and the '
      'turn_passed that follows adds nothing', () async {
    final _Table table = await passingTable('timer-roll-no-move');
    final List<Frame> frames = await table.expire();
    expect(
      frames.map((Frame f) => f['t']).toList(),
      <String>['rolled', 'turn_passed', 'turn'],
      reason: 'setup: a timer roll of ${table.faces.first} on an all-yard '
          'board is rolled, turn_passed, turn; got $frames',
    );
    expect(_data(frames.first)['by'], 'timer');
    expect(_data(frames.first)['legal'], isEmpty);
    final Frame room = await table.snapshot(table.guest);
    _expectSteps(
      table,
      room,
      <int, int>{table.host: 1, table.guest: 0},
      name: 'S4',
      state: 'PLAYING',
      rule: 'rule 2 (a timer roll that leaves no legal move adds one; the '
          'turn_passed after it adds nothing)',
      defect: 'counting the turn_passed as a second step (2), counting it '
          'for the seat it passes to, or not counting an empty-legal roll '
          '(0)',
    );
  });

  group('S5: a seat\'s own accepted roll resets its count', () {
    test(
        'S5 the host\'s count survives the guest\'s accepted roll and is '
        'reset by the host\'s own roll on its next turn', () async {
      final _Table table = await passingTable('timer-then-own-rolls');
      await table.expire();
      final Frame afterTimer = await table.snapshot(table.guest);
      _expectSteps(
        table,
        afterTimer,
        <int, int>{table.host: 1, table.guest: 0},
        name: 'S5',
        state: 'PLAYING',
        rule: 'rule 2, the starting point of this case',
        defect: 'the timer roll not counted at all',
      );

      await table.act(table.guest, 'roll', <String, Object?>{});
      final Frame afterGuest = await table.snapshot(table.host);
      _expectSteps(
        table,
        afterGuest,
        <int, int>{table.host: 1, table.guest: 0},
        name: 'S5',
        state: 'PLAYING',
        rule: 'rule 3 (only the seat\'s OWN accepted roll or move resets '
            'it; the guest\'s roll is not the host\'s)',
        defect: 'a reset applied to every seat, or to the seat that is not '
            'the sender, on any accepted roll',
      );

      await table.act(table.host, 'roll', <String, Object?>{});
      final Frame afterHost = await table.snapshot(table.guest);
      _expectSteps(
        table,
        afterHost,
        <int, int>{table.host: 0, table.guest: 0},
        name: 'S5',
        state: 'PLAYING',
        rule: 'rule 3 (an accepted roll sent by the seat\'s own client sets '
            'it to 0)',
        defect: 'no reset on the client roll path, so a player who came '
            'back and played keeps being told the timer played for them',
      );
    });
  });

  group('S6: a rejected request changes nothing', () {
    test(
        'S6a the host, holding 1 and out of turn, sends roll and move: both '
        'are NOT_YOUR_TURN and its count stays 1', () async {
      final _Table table = await passingTable('rejected-out-of-turn');
      await table.expire();
      await table.reject(
        table.host,
        'roll',
        <String, Object?>{},
        code: 'NOT_YOUR_TURN',
        because: 'the timer passed the turn to the guest',
      );
      await table.reject(
        table.host,
        'move',
        <String, Object?>{'token': 0},
        code: 'NOT_YOUR_TURN',
        because: 'the timer passed the turn to the guest',
      );
      final Frame room = await table.snapshot(table.guest);
      _expectSteps(
        table,
        room,
        <int, int>{table.host: 1, table.guest: 0},
        name: 'S6a',
        state: 'PLAYING',
        rule: 'rule 3 (a rejected request changes nothing)',
        defect: 'the reset running before the turn check, so an out-of-turn '
            'roll or move wipes the count',
      );
    });

    test(
        'S6b the guest, holding 1 with a move pending, sends a second roll, '
        'a replayed roll id, an out-of-range move, and the host sends a move '
        'out of turn: all rejected, counts stay 1 and 0', () async {
      final _Table table = await awaitRollTable('rejected-wrong-phase');
      await table.expire();
      final String replayed = table.sentIds[table.guest]!.first;
      await table.reject(
        table.guest,
        'roll',
        <String, Object?>{},
        code: 'WRONG_PHASE',
        because: 'a move is pending after the timer\'s roll',
      );
      await table.reject(
        table.guest,
        'roll',
        <String, Object?>{},
        id: replayed,
        code: 'WRONG_PHASE',
        because: 'id $replayed was used by this seat\'s first accepted roll '
            'and section 20 makes a replay a new, here refused, intention',
      );
      await table.reject(
        table.guest,
        'move',
        <String, Object?>{'token': 9},
        code: 'BAD_FIELD',
        because: 'token 9 is outside 0..3',
      );
      await table.reject(
        table.host,
        'move',
        <String, Object?>{'token': 0},
        code: 'NOT_YOUR_TURN',
        because: 'the guest holds the turn',
      );
      final Frame room = await table.snapshot(table.host);
      _expectSteps(
        table,
        room,
        <int, int>{table.host: 0, table.guest: 1},
        name: 'S6b',
        state: 'PLAYING',
        rule: 'rule 3 (a rejected request changes nothing), including a '
            'replayed request id (section 20)',
        defect: 'a reset applied on receipt of a roll or move rather than on '
            'acceptance, or keyed on the request id',
      );
    });
  });

  group('S7: a rematch', () {
    test(
        'S7 the rematch LOBBY reads 0, the new game_started resets every '
        'seat, and the new game counts from 0', () async {
      final _Table table = await finishedByTimerTable('rematch-after-timer');
      final Frame finished = await table.snapshot(table.host);
      expect(finished['state'], 'FINISHED',
          reason: 'setup: the game must be over; got ${finished['state']}');
      _expectSteps(
        table,
        finished,
        <int, int>{table.host: 1, table.guest: 1},
        name: 'S7',
        state: 'FINISHED',
        rule: 'rule 3 (FINISHED keeps the value it had at game_over); the '
            'starting point of the rematch case',
        defect: 'FINISHED zeroing the counts, which would hide a rematch '
            'that fails to reset',
      );

      table.conns[table.host]!.client.send('rematch', <String, Object?>{});
      final Map<int, Frame> lobbyRoom = <int, Frame>{};
      for (final int seat in <int>[table.host, table.guest]) {
        final Frame frame = await table.read(seat);
        expect(frame['t'], 'room',
            reason: 'setup: the rematch is answered by a room broadcast; got '
                '"${frame['t']}": ${frame['d']}');
        lobbyRoom[seat] = _data(frame);
      }
      _expectSteps(
        table,
        lobbyRoom[table.guest]!,
        <int, int>{table.host: 0, table.guest: 0},
        name: 'S7',
        state: 'LOBBY',
        rule: 'rule 3 (a rematch LOBBY reads 0 for every seat)',
        defect: 'the FINISHED counts carried into the rematch LOBBY',
      );

      table.conns[table.guest]!.client.send('rematch', <String, Object?>{});
      for (final int seat in <int>[table.host, table.guest]) {
        final List<String> types = <String>[];
        while (true) {
          final Frame frame = await table.read(seat);
          types.add(frame['t']! as String);
          if (frame['t'] == 'room') {
            _expectSteps(
              table,
              _data(frame),
              <int, int>{table.host: 0, table.guest: 0},
              name: 'S7',
              state: 'LOBBY',
              rule: 'rule 3 (the rematch LOBBY after the last acceptance '
                  'reads 0)',
              defect: 'the FINISHED counts carried into the rematch LOBBY',
            );
          }
          if (frame['t'] == 'turn') {
            break;
          }
          expect(types.length, lessThan(12),
              reason: 'setup: the auto-started rematch must reach its '
                  'opening turn; saw $types');
        }
        expect(types, contains('game_started'),
            reason: 'setup: both accepted, so the server starts the game; '
                'saw $types');
      }

      final Frame started = await table.snapshot(table.guest);
      _expectSteps(
        table,
        started,
        <int, int>{table.host: 0, table.guest: 0},
        name: 'S7',
        state: 'PLAYING',
        rule: 'rule 3 (game_started sets every seat to 0, in every rematch)',
        defect: 'game_started not resetting the stored counts, hidden while '
            'the LOBBY snapshot reports 0 by phase alone',
      );

      final int opener =
          _data(table.seen.lastWhere((Frame f) => f['t'] == 'turn'))['seat']!
              as int;
      final int other = opener == table.host ? table.guest : table.host;
      await table.expire();
      final Frame counted = await table.snapshot(other);
      _expectSteps(
        table,
        counted,
        <int, int>{
          opener: 1,
          other: 0,
        },
        name: 'S7',
        state: 'PLAYING',
        rule: 'rule 2 (counting restarts at game_started; the first timer '
            'step of the new game is 1, not the old game\'s 1 plus one)',
        defect: 'a count that continues across games',
      );
    });
  });

  test(
      'S8 no rolled, moved, turn, turn_passed, game_over or game_log frame '
      'carries timer_steps, anywhere inside it', () async {
    final _Table table = await passingTable('frames-carry-no-key');
    await table.expire();
    await table.act(table.guest, 'roll', <String, Object?>{});
    _forceGame(
      table.room,
      currentSeat: table.host,
      phase: engine.GamePhase.awaitMove,
      roll: 3,
      tokens: <int, List<int>>{
        table.host: <int>[54, 57, 57, 57],
        table.guest: <int>[-1, -1, -1, -1],
      },
    );
    final List<Frame> last = await table.expire();
    expect(
        last.map((Frame f) => f['t']).toList(),
        <String>[
          'moved',
          'game_over',
        ],
        reason: 'setup: the timer move must win; got $last');

    final String requestId =
        table.conns[table.host]!.client.send('game_log', <String, Object?>{});
    int parts = 1;
    int got = 0;
    while (got < parts) {
      final Frame part = await table.read(table.host);
      expect(part['t'], 'game_log',
          reason: 'setup: expected game_log answering $requestId; got '
              '"${part['t']}": ${part['d']}');
      parts = _data(part)['parts']! as int;
      got++;
    }

    final Set<String> types =
        table.seen.map((Frame f) => f['t']! as String).toSet();
    for (final String needed in <String>[
      'rolled',
      'moved',
      'turn',
      'turn_passed',
      'game_over',
      'game_log',
    ]) {
      expect(types, contains(needed),
          reason: 'the scan is only meaningful if it saw a $needed frame; '
              'saw $types. ${table.repro('S8')}');
    }
    expect(
      table.seen.any(
              (Frame f) => f['t'] == 'rolled' && _data(f)['by'] == 'timer') &&
          table.seen
              .any((Frame f) => f['t'] == 'moved' && _data(f)['by'] == 'timer'),
      isTrue,
      reason: 'the scan must include timer-played rolled and moved frames, '
          'the ones a lazy implementation would decorate; saw $types',
    );
    for (final Frame frame in table.seen) {
      if (frame['t'] == 'room' || frame['t'] == 'seat_assigned') {
        continue;
      }
      expect(
        _hasKeyDeep(frame, 'timer_steps'),
        isFalse,
        reason: 'section 23 rule 4: no frame other than a snapshot carries '
            'timer_steps, and game_log serves frames as they were '
            'broadcast; found it in a "${frame['t']}" frame: $frame. '
            'Catches: the field added to a frame builder shared with '
            'snapshots, or to the log entries. ${table.repro('S8')}',
      );
    }
  });

  test(
      'X1 FINISHED keeps the value it had at game_over: host 1 and guest 1 '
      'after a timer roll and a winning timer move', () async {
    final _Table table = await finishedByTimerTable('finished-keeps');
    final Frame room = await table.snapshot(table.host);
    _expectSteps(
      table,
      room,
      <int, int>{table.host: 1, table.guest: 1},
      name: 'X1',
      state: 'FINISHED',
      rule: 'rule 3 (in FINISHED it keeps the value it had at game_over) '
          'and rule 2 (counted in FINISHED too)',
      defect: 'game_over clearing the counts, or the winning timer move '
          'not counted',
    );
  });

  test(
      'X2 an accepted client move resets the count like an accepted roll: '
      'the guest holding 1 with a move pending moves and reads 0', () async {
    final _Table table = await awaitRollTable('own-move-resets');
    final List<Frame> roll = await table.expire();
    final List<Object?> legal = _data(roll.first)['legal']! as List<Object?>;
    final Frame before = await table.snapshot(table.host);
    _expectSteps(
      table,
      before,
      <int, int>{table.host: 0, table.guest: 1},
      name: 'X2',
      state: 'PLAYING',
      rule: 'rule 2, the starting point of this case',
      defect: 'the timer roll not counted',
    );
    final List<Frame> moved = await table.act(
      table.guest,
      'move',
      <String, Object?>{'token': legal.first},
    );
    expect(moved.first['t'], 'moved');
    expect(_data(moved.first).containsKey('by'), isFalse,
        reason: 'setup: a client move carries no by');
    final Frame after = await table.snapshot(table.host);
    _expectSteps(
      table,
      after,
      <int, int>{table.host: 0, table.guest: 0},
      name: 'X2',
      state: 'PLAYING',
      rule: 'rule 3 (an accepted roll OR move sent by the seat\'s own '
          'client sets it to 0)',
      defect: 'the reset wired to the roll path only',
    );
  });

  test(
      'X3 both seats away for two expiries: each timer roll is counted for '
      'its own seat, both resume into 1 and 1, and the host\'s own roll '
      'resets only the host', () async {
    final _Table table = await passingTable('both-away');
    await table.drop(table.host);
    await table.drop(table.guest);
    await table.expire();
    await table.expire();

    final Frame guestView = await table.snapshot(table.guest);
    _expectSteps(
      table,
      guestView,
      <int, int>{table.host: 1, table.guest: 1},
      name: 'X3',
      state: 'PLAYING',
      rule: 'rule 2 (every timer step is counted whether or not any socket '
          'is connected to see it)',
      defect: 'counting kept on the broadcast path, so steps taken with '
          'nobody connected are lost',
    );
    final Frame hostView = await table.snapshot(table.host);
    _expectSteps(
      table,
      hostView,
      <int, int>{table.host: 1, table.guest: 1},
      name: 'X3',
      state: 'PLAYING',
      rule: 'rule 1 (the same snapshot for every resumer)',
      defect: 'a count kept per connection rather than per seat',
    );

    await table.act(table.host, 'roll', <String, Object?>{});
    final Frame after = await table.snapshot(table.guest);
    _expectSteps(
      table,
      after,
      <int, int>{table.host: 0, table.guest: 1},
      name: 'X3',
      state: 'PLAYING',
      rule: 'rule 3 (the host\'s own accepted roll resets the host only)',
      defect: 'a reset applied to every seat',
    );
  });
}
