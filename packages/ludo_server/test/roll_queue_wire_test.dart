// Order 361: wire conformance for the roll queue, `docs/PROTOCOL.md`
// section 21 (21.1 fields, 21.2 timing, 21.3 rulings), read together with
// `docs/ENGINE_API.md` section 10 and `docs/RULES.md` section 3.2a.
//
// Written from those documents only, against a real, running `WireServer`,
// the way `dice_steering_test.dart` and `turn_loop_test.dart` already do.
// Never read against `lib/src/connection.dart`, `lib/src/registry.dart` or
// `lib/src/snapshot.dart` to decide what a test should expect; those files
// were read only to find the seam this suite needed (`test/support/
// queue_injection.dart`'s header explains exactly which lines) and to
// predict, for this report, which assertions below fail on this branch's
// base and why.
//
// Two seams, reused unmodified:
//
// - Dice steering (`test/support/dice_oracle.dart`,
//   `test/support/scripted_bytes.dart`), exactly as `dice_steering_test.dart`
//   uses it, for every case that needs a *specific real die face* out of a
//   real `roll` call: W2, W3, W4, W5, W8, the bonus roll in W9, and the
//   mid-streak roll in W12.
// - Direct engine-state injection (`test/support/queue_injection.dart`'s
//   `forceQueueGame`), exactly the seam `turn_timer_conformance_test.dart`'s
//   private `_forceGame` and `verify_record_test.dart`'s hand-built row
//   already use, for every board position this suite needs that a real
//   dice-steered sequence cannot reach at all: `turn_loop_test.dart`'s own
//   header prices a real capture at an 8-face search and a real win at 60
//   or more, both through the registry's real dice chain, and W7, W9's
//   board, W10, W11 and half of W12 are exactly that kind of position,
//   now wanted for a feature neither of those two files tests. What is
//   under test, every time `forceQueueGame` is used, is never the position
//   it builds -- it is what a real `roll` or `move` sent over a real socket
//   does with it.
//
// This suite is written against `docs/PROTOCOL.md` section 21 as specified.
// Section 21's own header says "Status: specified, not yet built"; order 360
// is building the server side in parallel, on the same base this file is
// written against, and this file never reads that work. Every test below is
// expected to fail on this base -- the acceptance run pastes those failures
// -- and to pass once the fields and the frame order this file names are
// implemented.

import 'dart:convert';

import 'package:fair_dice/fair_dice.dart' show drawDie, hexEncode, verifyReveal;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/queue_injection.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// `docs/PROTOCOL.md` section 2 / `lib/src/registry.dart`: for a 2-player
/// room the seat indices are fixed at `[0, 2]`, assigned in join order, and
/// the host -- who always creates first -- takes seat 0. Every test below
/// assumes this and checks it rather than trusting it blind, the same way
/// `dice_steering_test.dart` does.
const List<int> _twoSeats = <int>[0, 2];

const String _hostSeed = 'rollq-host-seed';
const String _guestSeed = 'rollq-guest-seed';
const String _clientSeeds = '0:$_hostSeed|2:$_guestSeed';

/// `test/support/scripted_bytes.dart`'s filler-byte formula at
/// `gameIdOffset` does not depend on the secret spliced in ahead of it, so
/// `game_id` can be predicted before a room exists -- the same trick
/// `dice_steering_test.dart`, `turn_loop_test.dart` and
/// `verify_record_test.dart` all use.
String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

void main() {
  final List<WireTestClient> clients = <WireTestClient>[];
  final List<ServerHarness> harnesses = <ServerHarness>[];

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    for (final ServerHarness harness in harnesses) {
      await harness.close();
    }
    harnesses.clear();
  });

  /// A harness with no steered dice at all: `Random.secure()`, exactly as
  /// most of this package's own suites build one. Used by every test that
  /// never calls `roll` for real (W1, W6, W7, W10, W11, half of W12), since
  /// those never touch the chain.
  Future<ServerHarness> plainHarness({bool automaticTurnExpiry = true}) async {
    final ServerHarness harness =
        ServerHarness.build(automaticTurnExpiry: automaticTurnExpiry);
    harnesses.add(harness);
    await harness.start();
    return harness;
  }

  /// A harness whose dice chain is steered so that its first `wanted.length`
  /// real rolls -- in a fresh 2-seat room seeded with `_hostSeed`/
  /// `_guestSeed` -- produce exactly `wanted`, in order. Costs one offline
  /// search (`findSecretForFaces`), roughly `6^wanted.length` candidates at
  /// the fast path's `O(chainLength + candidates)` cost; every sequence this
  /// file asks for is 1 to 3 faces, so this is instant.
  Future<ServerHarness> steeredHarness(
    List<int> wanted, {
    bool automaticTurnExpiry = true,
  }) async {
    final SteeredSecret steered = findSecretForFaces(
      wanted: wanted,
      gameId: _predictedGameId(),
      clientSeeds: _clientSeeds,
    );
    final ServerHarness harness = ServerHarness.build(
      secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
      automaticTurnExpiry: automaticTurnExpiry,
    );
    harnesses.add(harness);
    await harness.start();
    return harness;
  }

  WireTestSeat seatFor(WireTestLobby lobby, int seat) =>
      seat == lobby.host.seat ? lobby.host : lobby.guest;

  /// Reads one frame off [actingSeat]'s own socket and, unless it is a
  /// private `error`, also drains and checks the identical broadcast copy
  /// off the other socket in the room (`docs/PROTOCOL.md` section 12.3:
  /// every state-changing push reaches every connected socket, the sender's
  /// own copy carrying `re`, no other socket's copy carrying it). Call once
  /// per wire frame a message produced, in order -- `rolled` then
  /// `turn_passed` then `turn` is three calls, not one.
  Future<Map<String, Object?>> nextBroadcast(
    WireTestLobby lobby,
    int actingSeat,
  ) async {
    final Map<String, Object?> mine =
        await seatFor(lobby, actingSeat).client.next();
    if (mine['t'] != 'error') {
      final WireTestSeat other =
          actingSeat == lobby.host.seat ? lobby.guest : lobby.host;
      final Map<String, Object?> theirs = await other.client.next();
      expect(
        theirs['t'],
        mine['t'],
        reason: 'room ${lobby.code}: a broadcast push must reach every '
            'socket with the same frame type; seat $actingSeat\'s socket '
            'saw "${mine['t']}", the other socket saw "${theirs['t']}"',
      );
      expect(
        theirs['d'],
        mine['d'],
        reason: 'room ${lobby.code}: a broadcast push must reach every '
            'socket with the identical payload; seat $actingSeat\'s socket '
            'saw ${mine['d']}, the other socket saw ${theirs['d']}',
      );
      expect(
        theirs['re'],
        isNull,
        reason: 'room ${lobby.code}: a socket that did not send the '
            'message must never see re on the resulting broadcast; got '
            're=${theirs['re']} on a "${theirs['t']}" frame',
      );
    }
    return mine;
  }

  Future<Map<String, Object?>> sendAndRead(
    WireTestLobby lobby,
    int seat,
    String type,
    Map<String, Object?> data,
  ) {
    seatFor(lobby, seat).client.send(type, data);
    return nextBroadcast(lobby, seat);
  }

  /// Asserts nothing arrives on [client] within [within] -- a bounded,
  /// real-socket liveness wait, the same idiom `WireTestClient.next`'s own
  /// `timeout` already uses throughout this package's suites, never an
  /// unconditional sleep standing in for a condition: there is no positive
  /// condition to wait for when the claim under test is an absence.
  Future<void> expectNoMoreFrames(
    WireTestClient client, {
    Duration within = const Duration(milliseconds: 200),
    required String because,
  }) async {
    Map<String, Object?>? unexpected;
    try {
      unexpected = await client.next(timeout: within);
    } on TestFailure {
      return;
    }
    fail(
      '$because: expected no further frame within $within and one '
      'arrived anyway: "${unexpected['t']}": ${unexpected['d']}',
    );
  }

  /// Joins a fresh two-seat room, fixes both seats' seeds to the constants
  /// above, and checks the fixed 2-player seat mapping this whole file
  /// depends on to predict `client_seeds`.
  Future<WireTestLobby> seededLobby(Uri uri) async {
    final WireTestLobby lobby =
        await buildWireTestLobby(uri, clients, players: 2);
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      _twoSeats,
      reason: 'this file assumes the fixed 2-player seat mapping (host=0, '
          'guest=2) so it can predict client_seeds before creating the '
          'room; got host=${lobby.host.seat} guest=${lobby.guest.seat}',
    );
    lobby.host.client
        .send('set_seed', <String, Object?>{'client_seed': _hostSeed});
    await receiveType(lobby.host.client, 'seat_seed');
    lobby.guest.client
        .send('set_seed', <String, Object?>{'client_seed': _guestSeed});
    await receiveType(lobby.guest.client, 'seat_seed');
    return lobby;
  }

  /// Sends `start_game` from the host and drains `game_started` plus the
  /// section 13.1 standalone opening `turn`, on both sockets, returning the
  /// host's `game_started` payload and the raw opening `turn` frame (so a
  /// caller can look at fields `expectOpeningTurn` does not check, such as
  /// `phase` and `queue`).
  Future<(Map<String, Object?> started, Map<String, Object?> openingTurn)>
      startGame(WireTestLobby lobby) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    final Map<String, Object?> openingTurn =
        await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);
    return (startedData, openingTurn);
  }

  Room roomOf(ServerHarness harness, String code) =>
      harness.registry.lookup(code)!;

  group('W1', () {
    test(
        'after start_game the room\'s engine config has rollQueue, '
        'homeBonus true, blocks false; the standalone turn carries '
        'phase: await_roll and queue: []', () async {
      final ServerHarness harness = await plainHarness();
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (_, Map<String, Object?> openingTurn) = await startGame(lobby);

      final Room room = roomOf(harness, lobby.code);
      final engine.RulesConfig rules = room.game!.config.rules;
      expect(
        rules.rollQueue,
        isTrue,
        reason: 'docs/PROTOCOL.md 21.3.5: every room is created with the '
            'engine\'s rollQueue: true; got false -- this is the one field '
            'this order expects to be false on this base, since the server '
            'side (order 360) has not landed yet',
      );
      expect(
        rules.homeBonus,
        isTrue,
        reason: 'docs/PROTOCOL.md 21.3.5: every room is created with '
            'homeBonus: true; got ${rules.homeBonus}',
      );
      expect(
        rules.blocks,
        isFalse,
        reason: 'docs/PROTOCOL.md 21.3.5 / section 4, 2026-10-15 ruling: '
            'every room is created with blocks off; got ${rules.blocks}',
      );

      final Map<String, Object?> turnData =
          openingTurn['d']! as Map<String, Object?>;
      expect(
        turnData['phase'],
        'await_roll',
        reason: 'docs/PROTOCOL.md 21.3.1: the pushed turn frame gains '
            'phase on every frame; the opening turn of a fresh game must '
            'read await_roll; got ${turnData['phase']}',
      );
      expect(
        turnData['queue'],
        <int>[],
        reason: 'docs/PROTOCOL.md 21.3.1: the pushed turn frame gains '
            'queue on every frame; a fresh game\'s opening turn has never '
            'rolled, so queue must be []; got ${turnData['queue']}',
      );
    });
  });

  group('W2', () {
    test(
        'a 6: rolled {value 6, legal [], queue [6]}, then turn same seat '
        'await_roll with queue [6]; nothing else', () async {
      final ServerHarness harness = await steeredHarness(const <int>[6]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (Map<String, Object?> started, _) = await startGame(lobby);
      final int startingSeat = started['turn']! as int;

      final Map<String, Object?> rolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      expect(rolled['t'], 'rolled',
          reason: 'expected rolled, got "${rolled['t']}": ${rolled['d']}');
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(rolledData['value'], 6, reason: 'steered a 6; got $rolledData');
      expect(rolledData['legal'], <int>[],
          reason: 'docs/ENGINE_API.md 10.3 rule 3: a queued 6 that owes '
              'another roll leaves Rolled.legal empty; got $rolledData');
      expect(rolledData['queue'], <int>[6],
          reason: 'docs/PROTOCOL.md 21.3.3: queue is the queue after the '
              'roll; got $rolledData');

      final Map<String, Object?> turn =
          await nextBroadcast(lobby, startingSeat);
      expect(turn['t'], 'turn',
          reason: 'docs/PROTOCOL.md 21.3.4: a 6 owing another roll is '
              'rolled then turn (same seat, await_roll); got '
              '"${turn['t']}": ${turn['d']}');
      final Map<String, Object?> turnData = turn['d']! as Map<String, Object?>;
      expect(turnData['seat'], startingSeat,
          reason: 'the turn stays with the same seat; got $turnData');
      expect(turnData['phase'], 'await_roll', reason: '$turnData');
      expect(turnData['queue'], <int>[6], reason: '$turnData');

      await expectNoMoreFrames(
        seatFor(lobby, startingSeat).client,
        because: 'docs/PROTOCOL.md 21.3.4: a 6 owing another roll produces '
            'exactly rolled, turn and nothing else',
      );
      await expectNoMoreFrames(
        seatFor(
                lobby,
                startingSeat == lobby.host.seat
                    ? lobby.guest.seat
                    : lobby.host.seat)
            .client,
        because: 'same, on the other socket in the room',
      );
    });
  });

  group('W3', () {
    test(
        '6 then 3: the second rolled has queue [6,3], legal = the default '
        'face\'s tokens, legal_by_face in first-queued order; no turn after '
        'it', () async {
      final ServerHarness harness = await steeredHarness(const <int>[6, 3]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (Map<String, Object?> started, _) = await startGame(lobby);
      final int startingSeat = started['turn']! as int;

      final Map<String, Object?> firstRolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      expect((firstRolled['d']! as Map<String, Object?>)['value'], 6);
      await nextBroadcast(lobby, startingSeat); // the same-seat turn after it

      final Map<String, Object?> secondRolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      expect(secondRolled['t'], 'rolled', reason: '${secondRolled['d']}');
      final Map<String, Object?> data =
          secondRolled['d']! as Map<String, Object?>;
      expect(data['value'], 3, reason: 'steered a 3 second; got $data');
      expect(data['queue'], <int>[6, 3],
          reason: 'docs/PROTOCOL.md 21.3.3: queue is the queue after the '
              'roll; got $data');
      // A fresh board: every token in the yard, so only a 6 can move
      // anything (RULES.md rule 17). The default face is therefore 6, the
      // first-queued face with a legal token, and all four tokens may use
      // it.
      expect(data['legal'], <int>[0, 1, 2, 3],
          reason: 'docs/ENGINE_API.md 10.3 rule 4 / PROTOCOL.md 21.3.3: '
              'legal is the default face\'s tokens when a move is pending; '
              'got $data');
      expect(
        data['legal_by_face'],
        <Map<String, Object?>>[
          <String, Object?>{
            'face': 6,
            'tokens': <int>[0, 1, 2, 3]
          },
        ],
        reason: 'docs/PROTOCOL.md 21.1: legal_by_face lists only faces '
            'with a legal token, in first-queued order; face 3 has none '
            'on a fresh board; got $data',
      );

      await expectNoMoreFrames(
        seatFor(lobby, startingSeat).client,
        because: 'docs/PROTOCOL.md 21.3.4: a roll that leaves a move '
            'pending produces exactly rolled, nothing else',
      );
    });
  });

  group('W4', () {
    test(
        'move with face: moved.face is that face; then turn same seat '
        'await_move carrying queue, value (= default face), legal, '
        'legal_by_face', () async {
      final ServerHarness harness = await steeredHarness(const <int>[6, 3]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (Map<String, Object?> started, _) = await startGame(lobby);
      final int startingSeat = started['turn']! as int;

      await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      await nextBroadcast(lobby, startingSeat); // same-seat turn after the 6
      final Map<String, Object?> secondRolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      expect(
          (secondRolled['d']! as Map<String, Object?>)['queue'], <int>[6, 3]);

      // Spend the queued 6 explicitly, on token 0 (any of the four is
      // equally legal out of the yard).
      final Map<String, Object?> moved = await sendAndRead(
        lobby,
        startingSeat,
        'move',
        <String, Object?>{'token': 0, 'face': 6},
      );
      expect(moved['t'], 'moved', reason: '${moved['d']}');
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(movedData['face'], 6,
          reason: 'docs/PROTOCOL.md 21.1: moved gains face, the face '
              'spent; got $movedData');
      expect(movedData['token'], 0);
      expect(movedData['from'], -1);
      expect(movedData['to'], 0);
      expect(movedData['captured'], <Map<String, Object?>>[]);
      expect(movedData['extra_roll'], isFalse,
          reason: 'docs/RULES.md 12q: a 6 spent on a move grants nothing; '
              'got $movedData');

      final Map<String, Object?> turn =
          await nextBroadcast(lobby, startingSeat);
      expect(turn['t'], 'turn', reason: '${turn['d']}');
      final Map<String, Object?> turnData = turn['d']! as Map<String, Object?>;
      expect(turnData['seat'], startingSeat);
      expect(turnData['phase'], 'await_move', reason: '$turnData');
      expect(turnData['queue'], <int>[3],
          reason: 'the spent 6 is removed, the 3 remains queued; got '
              '$turnData');
      expect(turnData['value'], 3,
          reason: 'docs/PROTOCOL.md 21.3.1: value is defaultFace in '
              'await_move; the only token out of the yard (progress 0) '
              'can use the remaining 3; got $turnData');
      expect(turnData['legal'], <int>[0], reason: '$turnData');
      expect(
        turnData['legal_by_face'],
        <Map<String, Object?>>[
          <String, Object?>{
            'face': 3,
            'tokens': <int>[0]
          },
        ],
        reason: '$turnData',
      );
    });
  });

  group('W5', () {
    test('move without face spends the default face (moved.face)', () async {
      final ServerHarness harness = await steeredHarness(const <int>[6, 3]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (Map<String, Object?> started, _) = await startGame(lobby);
      final int startingSeat = started['turn']! as int;

      await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      await nextBroadcast(lobby, startingSeat);
      await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});

      // queue is [6, 3]; a fresh board makes 6 the only legal face, so it
      // is the default. No face given at all.
      final Map<String, Object?> moved = await sendAndRead(
        lobby,
        startingSeat,
        'move',
        <String, Object?>{'token': 0},
      );
      expect(moved['t'], 'moved', reason: '${moved['d']}');
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(movedData['face'], 6,
          reason: 'docs/PROTOCOL.md 21.1: absent face spends defaultFace, '
              'which on a fresh board is the only queued face with a '
              'legal token (6); got $movedData');

      await nextBroadcast(lobby, startingSeat); // the resulting turn frame
    });
  });

  group('W6', () {
    test(
        'face 0, 7, "6", 2.5: BAD_FIELD; a face not queued, or a token not '
        'legal for it: ILLEGAL_MOVE; no frame broadcast, state unchanged',
        () async {
      final ServerHarness harness = await plainHarness();
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      await startGame(lobby);
      final int hostSeat = lobby.host.seat;
      final Room room = roomOf(harness, lobby.code);

      // One token out on the track at progress 5 (legal for face 4: 5+4=9),
      // the other three still in the yard (illegal for any non-6,
      // including 4). Queue holds only the one face.
      forceQueueGame(
        room,
        currentSeat: hostSeat,
        phase: engine.GamePhase.awaitMove,
        queue: const <int>[4],
        tokens: <int, List<int>>{
          hostSeat: <int>[5, -1, -1, -1]
        },
        now: harness.clock.now,
      );
      final engine.GameState setupState = room.game!;
      expect(
        engine.legalByFace(setupState),
        <int, List<int>>{
          4: <int>[0]
        },
        reason: 'setup requires: token 0 at progress 5 is the only legal '
            'move for face 4 (5+4=9); got '
            '${engine.legalByFace(setupState)}',
      );

      Future<void> expectBadField(Map<String, Object?> data, String why) async {
        final Map<String, Object?> error =
            await sendAndRead(lobby, hostSeat, 'move', data);
        expectErrorFrame(error, 'BAD_FIELD', because: why);
      }

      Future<void> expectIllegal(Map<String, Object?> data, String why) async {
        final Map<String, Object?> error =
            await sendAndRead(lobby, hostSeat, 'move', data);
        expectErrorFrame(error, 'ILLEGAL_MOVE', because: why);
      }

      await expectBadField(
          <String, Object?>{'token': 0, 'face': 0}, 'face 0 is out of 1..6');
      await expectBadField(
          <String, Object?>{'token': 0, 'face': 7}, 'face 7 is out of 1..6');
      await expectBadField(<String, Object?>{'token': 0, 'face': '6'},
          'face as a string, not an int');
      await expectBadField(<String, Object?>{'token': 0, 'face': 2.5},
          'face as a double, not an int');
      await expectIllegal(<String, Object?>{'token': 0, 'face': 5},
          'face 5 is not in the queue [4]');
      await expectIllegal(<String, Object?>{'token': 1, 'face': 4},
          'token 1 (progress -1) is not legal for the queued face 4');

      await expectNoMoreFrames(
        seatFor(
                lobby,
                hostSeat == lobby.host.seat
                    ? lobby.guest.seat
                    : lobby.host.seat)
            .client,
        because: 'docs/PROTOCOL.md section 7: a rejected move is a private '
            'error and broadcasts nothing to the rest of the room',
      );

      final engine.GameState after = room.game!;
      expect(after.phase, engine.GamePhase.awaitMove);
      expect(after.queue, <int>[4]);
      expect(after.tokens[hostSeat], <int>[5, -1, -1, -1],
          reason: 'none of the six rejected moves above may have touched '
              'the board');
    });
  });

  group('W7', () {
    test(
        'a move leaving only dead faces: moved, turn_passed no_legal_move, '
        'turn next seat', () async {
      final ServerHarness harness = await plainHarness();
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      await startGame(lobby);
      final int hostSeat = lobby.host.seat;
      final int guestSeat = lobby.guest.seat;
      final Room room = roomOf(harness, lobby.code);

      // Token 0 at progress 53. queue = [5, 2]: face 5 is dead from the
      // start (53+5=58 > 57, RULES.md rule 19; no other token can use a
      // non-6 out of the yard either), face 2 is legal (53+2=55). Spending
      // the 2 moves the token to 55, after which 5 is still dead
      // (55+5=60 > 57) -- the only legal face was just spent, so the turn
      // must pass with the dead 5 discarded.
      forceQueueGame(
        room,
        currentSeat: hostSeat,
        phase: engine.GamePhase.awaitMove,
        queue: const <int>[5, 2],
        tokens: <int, List<int>>{
          hostSeat: <int>[53, -1, -1, -1]
        },
        now: harness.clock.now,
      );
      expect(
        engine.legalByFace(room.game!),
        <int, List<int>>{
          2: <int>[0]
        },
        reason: 'setup requires: face 5 has no legal token at all, face 2 '
            'has only token 0; got ${engine.legalByFace(room.game!)}',
      );
      expect(engine.defaultFace(room.game!), 2);

      final Map<String, Object?> moved = await sendAndRead(
        lobby,
        hostSeat,
        'move',
        <String, Object?>{'token': 0},
      );
      expect(moved['t'], 'moved', reason: '${moved['d']}');
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(movedData['face'], 2);
      expect(movedData['from'], 53);
      expect(movedData['to'], 55);
      expect(movedData['extra_roll'], isFalse);

      final Map<String, Object?> turnPassed =
          await nextBroadcast(lobby, hostSeat);
      expect(turnPassed['t'], 'turn_passed',
          reason: 'docs/PROTOCOL.md 21.3.4: a move that leaves only dead '
              'faces is moved, turn_passed(no_legal_move), turn; got '
              '"${turnPassed['t']}": ${turnPassed['d']}');
      expect((turnPassed['d']! as Map<String, Object?>)['reason'],
          'no_legal_move');
      expect((turnPassed['d']! as Map<String, Object?>)['seat'], hostSeat);

      final Map<String, Object?> turn = await nextBroadcast(lobby, hostSeat);
      expect(turn['t'], 'turn', reason: '${turn['d']}');
      final Map<String, Object?> turnData = turn['d']! as Map<String, Object?>;
      expect(turnData['seat'], guestSeat);
      expect(turnData['phase'], 'await_roll');
      expect(turnData['queue'], <int>[],
          reason: 'docs/RULES.md 13q: the dead face left in the queue is '
              'discarded when the turn passes; got $turnData');
    });
  });

  group('W8', () {
    test(
        '6, 6, 6: rolled (queue []), turn_passed three_sixes, turn next '
        'seat', () async {
      final ServerHarness harness = await steeredHarness(const <int>[6, 6, 6]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (Map<String, Object?> started, _) = await startGame(lobby);
      final int startingSeat = started['turn']! as int;
      final int otherSeat =
          startingSeat == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

      await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      await nextBroadcast(lobby, startingSeat); // turn after the 1st 6
      await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      await nextBroadcast(lobby, startingSeat); // turn after the 2nd 6

      final Map<String, Object?> thirdRolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      expect(thirdRolled['t'], 'rolled', reason: '${thirdRolled['d']}');
      final Map<String, Object?> rolledData =
          thirdRolled['d']! as Map<String, Object?>;
      expect(rolledData['value'], 6);
      expect(rolledData['legal'], <int>[],
          reason: 'docs/ENGINE_API.md 10.3: a voided turn leaves '
              'Rolled.legal empty; got $rolledData');
      expect(rolledData['queue'], <int>[],
          reason: 'docs/PROTOCOL.md 21.3.3: queue is [] when the roll '
              'voided the turn; got $rolledData');

      final Map<String, Object?> turnPassed =
          await nextBroadcast(lobby, startingSeat);
      expect(turnPassed['t'], 'turn_passed', reason: '${turnPassed['d']}');
      expect(
          (turnPassed['d']! as Map<String, Object?>)['reason'], 'three_sixes');
      expect((turnPassed['d']! as Map<String, Object?>)['seat'], startingSeat);

      final Map<String, Object?> turn =
          await nextBroadcast(lobby, startingSeat);
      expect(turn['t'], 'turn', reason: '${turn['d']}');
      final Map<String, Object?> turnData = turn['d']! as Map<String, Object?>;
      expect(turnData['seat'], otherSeat);
      expect(turnData['phase'], 'await_roll');
      expect(turnData['queue'], <int>[]);
    });
  });

  group('W9', () {
    test(
        'a capture mid-queue: moved extra_roll: true, turn same seat '
        'await_roll with the remaining queue; the bonus roll\'s face is '
        'appended', () async {
      // The bonus roll (after the capture) is steered to a 2: non-six, so
      // this test needs only one real roll beyond the capturing move, and
      // a simple single-step assertion on it.
      final ServerHarness harness = await steeredHarness(const <int>[2]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      await startGame(lobby);
      final int hostSeat = lobby.host.seat;
      final int guestSeat = lobby.guest.seat;
      final Room room = roomOf(harness, lobby.code);

      // Host token 0 at progress 7 (absolute square 0+7=7). Spending the
      // queued 3 moves it to progress 10 (absolute square 10), which is not
      // one of the eight safe squares (0, 8, 13, 21, 26, 34, 39, 47).
      // Guest token 0 at progress 36 (absolute square (26+36) mod 52 = 10)
      // sits exactly there, alone -- RULES.md rule 27/29, a capture.
      forceQueueGame(
        room,
        currentSeat: hostSeat,
        phase: engine.GamePhase.awaitMove,
        queue: const <int>[3, 4],
        tokens: <int, List<int>>{
          hostSeat: <int>[7, -1, -1, -1],
          guestSeat: <int>[36, -1, -1, -1],
        },
        now: harness.clock.now,
      );
      expect(
        engine.legalByFace(room.game!)[3],
        <int>[0],
        reason: 'setup requires: token 0 at progress 7 is legal for face '
            '3 (7+3=10, landing on the guest token); got '
            '${engine.legalByFace(room.game!)}',
      );

      final Map<String, Object?> moved = await sendAndRead(
        lobby,
        hostSeat,
        'move',
        <String, Object?>{'token': 0, 'face': 3},
      );
      expect(moved['t'], 'moved', reason: '${moved['d']}');
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(movedData['from'], 7);
      expect(movedData['to'], 10);
      expect(movedData['face'], 3);
      expect(
        movedData['captured'],
        <Map<String, Object?>>[
          <String, Object?>{'seat': guestSeat, 'token': 0},
        ],
        reason: '$movedData',
      );
      expect(movedData['extra_roll'], isTrue,
          reason: 'docs/RULES.md rule 32: a capture grants another roll; '
              'got $movedData');

      final Map<String, Object?> turn = await nextBroadcast(lobby, hostSeat);
      expect(turn['t'], 'turn', reason: '${turn['d']}');
      final Map<String, Object?> turnData = turn['d']! as Map<String, Object?>;
      expect(turnData['seat'], hostSeat,
          reason: 'docs/PROTOCOL.md 21.3.4: a capture mid-queue keeps the '
              'same seat, awaiting the bonus roll; got $turnData');
      expect(turnData['phase'], 'await_roll');
      expect(turnData['queue'], <int>[4],
          reason: 'the spent 3 is gone, the unspent 4 remains; got '
              '$turnData');
      final int turnSeconds = room.rules.turnSeconds;
      expect(turnData['deadline_ms'], turnSeconds * 1000,
          reason: 'docs/PROTOCOL.md 21.2: a moved that owes a roll '
              'restarts the segment; got $turnData');

      final Map<String, Object?> rolled =
          await sendAndRead(lobby, hostSeat, 'roll', <String, Object?>{});
      expect(rolled['t'], 'rolled', reason: '${rolled['d']}');
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(rolledData['value'], 2,
          reason: 'steered the bonus roll to a '
              '2; got $rolledData');
      expect(rolledData['queue'], <int>[4, 2],
          reason: 'docs/RULES.md 12q: the bonus roll\'s face joins the end '
              'of the queue; got $rolledData');
      expect(rolledData['legal'], <int>[0],
          reason: 'the only token out of the yard (progress 10) is legal '
              'for the default face (4: 10+4=14); got $rolledData');

      await expectNoMoreFrames(
        seatFor(lobby, hostSeat).client,
        because: 'docs/PROTOCOL.md 21.3.4: a roll that leaves a move '
            'pending produces exactly rolled, nothing else',
      );
    });
  });

  group('W10', () {
    test('a winning move with faces left: moved, game_over, nothing after',
        () async {
      final ServerHarness harness = await plainHarness();
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      await startGame(lobby);
      final int hostSeat = lobby.host.seat;
      final int guestSeat = lobby.guest.seat;
      final Room room = roomOf(harness, lobby.code);

      // Three tokens already home; the fourth at progress 54. queue =
      // [3, 5]: spending the 3 reaches exactly 57 (the win); 5 is dead
      // (54+5=59 > 57, and every other token is immovable at 57) and is
      // left in the queue at the moment of the winning move.
      forceQueueGame(
        room,
        currentSeat: hostSeat,
        phase: engine.GamePhase.awaitMove,
        queue: const <int>[3, 5],
        tokens: <int, List<int>>{
          hostSeat: <int>[57, 57, 57, 54]
        },
        now: harness.clock.now,
      );
      expect(engine.legalByFace(room.game!), <int, List<int>>{
        3: <int>[3]
      });

      final Map<String, Object?> moved = await sendAndRead(
        lobby,
        hostSeat,
        'move',
        <String, Object?>{'token': 3, 'face': 3},
      );
      expect(moved['t'], 'moved', reason: '${moved['d']}');
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(movedData['from'], 54);
      expect(movedData['to'], 57);
      expect(movedData['captured'], <Map<String, Object?>>[]);
      expect(movedData['extra_roll'], isFalse,
          reason: 'docs/RULES.md rule 11a: a home arrival that wins the '
              'game grants no bonus; got $movedData');

      final Map<String, Object?> gameOver =
          await nextBroadcast(lobby, hostSeat);
      expect(gameOver['t'], 'game_over', reason: '${gameOver['d']}');
      final Map<String, Object?> gameOverData =
          gameOver['d']! as Map<String, Object?>;
      expect(gameOverData['winner'], hostSeat);
      expect(gameOverData['verify_url'], '$defaultVerifyUrlBase${room.gameId}');

      await expectNoMoreFrames(
        seatFor(lobby, hostSeat).client,
        because: 'docs/PROTOCOL.md section 12.2: no turn frame follows a '
            'game_over',
      );
      await expectNoMoreFrames(
        seatFor(lobby, guestSeat).client,
        because: 'same, on the other socket in the room',
      );
      expect(room.state, RoomState.finished);
    });
  });

  group('W11', () {
    test(
        'resume snapshot mid-streak (await_roll, queue [6]) and in '
        'await_move: turn.queue, turn.value = default face, legal, '
        'legal_by_face; finished: queue: [], no legal_by_face', () async {
      // (a) await_roll mid-streak.
      {
        final ServerHarness harness = await plainHarness();
        final WireTestLobby lobby = await seededLobby(harness.wsUri);
        await startGame(lobby);
        final int hostSeat = lobby.host.seat;
        final Room room = roomOf(harness, lobby.code);
        forceQueueGame(
          room,
          currentSeat: hostSeat,
          phase: engine.GamePhase.awaitRoll,
          queue: const <int>[6],
          sixes: 1,
          tokens: const <int, List<int>>{},
          now: harness.clock.now,
        );

        final String resumeId = seatFor(lobby, hostSeat).client.send(
          'resume',
          <String, Object?>{
            'code': lobby.code,
            'seat_token': seatFor(lobby, hostSeat).token
          },
        );
        await expectSeatAssigned(
          seatFor(lobby, hostSeat).client,
          expectedSeat: hostSeat,
          expectedToken: seatFor(lobby, hostSeat).token,
          because: 'W11a resume',
        );
        final Map<String, Object?> room1 =
            await seatFor(lobby, hostSeat).client.next();
        expect(room1['re'], resumeId);
        final Map<String, Object?> roomData =
            room1['d']! as Map<String, Object?>;
        final Map<String, Object?> turn =
            roomData['turn']! as Map<String, Object?>;
        expect(turn['phase'], 'await_roll');
        expect(turn['queue'], <int>[6],
            reason: 'docs/PROTOCOL.md 21.3.2: the snapshot\'s turn object '
                'gains queue in await_roll; got $turn');
        expect(turn.containsKey('value'), isFalse,
            reason: 'section 6: value is absent when phase is await_roll; '
                'got $turn');
        expect(turn.containsKey('legal'), isFalse, reason: '$turn');
        expect(turn.containsKey('legal_by_face'), isFalse,
            reason: 'docs/PROTOCOL.md 21.3.2: legal_by_face is only in '
                'await_move; got $turn');
      }

      // (b) await_move.
      {
        final ServerHarness harness = await plainHarness();
        final WireTestLobby lobby = await seededLobby(harness.wsUri);
        await startGame(lobby);
        final int hostSeat = lobby.host.seat;
        final int guestSeat = lobby.guest.seat;
        final Room room = roomOf(harness, lobby.code);
        forceQueueGame(
          room,
          currentSeat: hostSeat,
          phase: engine.GamePhase.awaitMove,
          queue: const <int>[4, 2],
          tokens: <int, List<int>>{
            hostSeat: <int>[10, -1, -1, -1]
          },
          now: harness.clock.now,
        );
        expect(
          engine.legalByFace(room.game!),
          <int, List<int>>{
            4: <int>[0],
            2: <int>[0]
          },
        );

        final String resumeId = seatFor(lobby, guestSeat).client.send(
          'resume',
          <String, Object?>{
            'code': lobby.code,
            'seat_token': seatFor(lobby, guestSeat).token,
          },
        );
        await expectSeatAssigned(
          seatFor(lobby, guestSeat).client,
          expectedSeat: guestSeat,
          expectedToken: seatFor(lobby, guestSeat).token,
          because: 'W11b resume',
        );
        final Map<String, Object?> room1 =
            await seatFor(lobby, guestSeat).client.next();
        expect(room1['re'], resumeId);
        final Map<String, Object?> roomData =
            room1['d']! as Map<String, Object?>;
        final Map<String, Object?> turn =
            roomData['turn']! as Map<String, Object?>;
        expect(turn['phase'], 'await_move');
        expect(turn['queue'], <int>[4, 2], reason: '$turn');
        expect(turn['value'], 4,
            reason: 'docs/PROTOCOL.md 21.3.2: value in await_move is '
                'defaultFace; got $turn');
        expect(turn['legal'], <int>[0], reason: '$turn');
        expect(
          turn['legal_by_face'],
          <Map<String, Object?>>[
            <String, Object?>{
              'face': 4,
              'tokens': <int>[0]
            },
            <String, Object?>{
              'face': 2,
              'tokens': <int>[0]
            },
          ],
          reason: '$turn',
        );
      }

      // (c) finished.
      {
        final ServerHarness harness = await plainHarness();
        final WireTestLobby lobby = await seededLobby(harness.wsUri);
        await startGame(lobby);
        final int hostSeat = lobby.host.seat;
        final Room room = roomOf(harness, lobby.code);
        forceQueueGame(
          room,
          currentSeat: hostSeat,
          phase: engine.GamePhase.finished,
          queue: const <int>[],
          winner: hostSeat,
          tokens: <int, List<int>>{
            hostSeat: <int>[57, 57, 57, 57]
          },
          now: harness.clock.now,
          roomState: RoomState.finished,
        );

        final String resumeId = seatFor(lobby, hostSeat).client.send(
          'resume',
          <String, Object?>{
            'code': lobby.code,
            'seat_token': seatFor(lobby, hostSeat).token,
          },
        );
        await expectSeatAssigned(
          seatFor(lobby, hostSeat).client,
          expectedSeat: hostSeat,
          expectedToken: seatFor(lobby, hostSeat).token,
          because: 'W11c resume',
        );
        final Map<String, Object?> room1 =
            await seatFor(lobby, hostSeat).client.next();
        expect(room1['re'], resumeId);
        final Map<String, Object?> roomData =
            room1['d']! as Map<String, Object?>;
        expect(roomData['state'], 'FINISHED');
        expect(roomData['winner'], hostSeat);
        final Map<String, Object?> turn =
            roomData['turn']! as Map<String, Object?>;
        expect(turn['phase'], 'finished');
        expect(turn['queue'], <int>[],
            reason: 'docs/PROTOCOL.md 21.3.2: finished carries queue: []; '
                'got $turn');
        expect(turn.containsKey('legal_by_face'), isFalse,
            reason: 'docs/PROTOCOL.md 21.3.2: finished carries no '
                'legal_by_face; got $turn');
      }
    });
  });

  group('W12', () {
    test(
        'timer: expiry in await_move spends the default face on its '
        'first legal token and publishes the same frames as W4/W7 would; '
        'expiry in await_roll mid-streak rolls. Each same-seat frame '
        'restarts the segment (21.2): its deadline_ms is the full '
        'turnSeconds', () async {
      // (a) expiry in await_move.
      {
        final ServerHarness harness =
            await plainHarness(automaticTurnExpiry: false);
        final WireTestLobby lobby = await seededLobby(harness.wsUri);
        await startGame(lobby);
        final int hostSeat = lobby.host.seat;
        final Room room = roomOf(harness, lobby.code);
        final int turnSeconds = room.rules.turnSeconds;

        forceQueueGame(
          room,
          currentSeat: hostSeat,
          phase: engine.GamePhase.awaitMove,
          queue: const <int>[4, 2],
          tokens: <int, List<int>>{
            hostSeat: <int>[10, -1, -1, -1]
          },
          now: harness.clock.now,
        );
        expect(engine.defaultFace(room.game!), 4);
        expect(
          engine.legalByFace(room.game!)[4],
          <int>[0],
          reason: 'setup requires: token 0 at progress 10 is the first '
              'legal token for the default face 4; got '
              '${engine.legalByFace(room.game!)}',
        );

        harness.clock.advance(Duration(seconds: turnSeconds + 1));
        harness.server.runTurnExpiryOnce();

        final Map<String, Object?> moved = await lobby.host.client.next();
        expect(moved['t'], 'moved',
            reason: 'docs/RULES.md 15q: expiry in await_move spends the '
                'first queued face with a legal move, on its first legal '
                'token; got "${moved['t']}": ${moved['d']}');
        final Map<String, Object?> movedData =
            moved['d']! as Map<String, Object?>;
        expect(movedData['face'], 4);
        expect(movedData['token'], 0);
        expect(movedData['from'], 10);
        expect(movedData['to'], 14);
        expect(movedData.containsKey('re'), isFalse,
            reason: 'no client request is being answered by a timer '
                'sweep; got $movedData');

        final Map<String, Object?> guestCopy = await lobby.guest.client.next();
        expect(guestCopy['t'], 'moved');
        expect(guestCopy['d'], movedData);

        final Map<String, Object?> turn = await lobby.host.client.next();
        expect(turn['t'], 'turn', reason: '${turn['d']}');
        final Map<String, Object?> turnData =
            turn['d']! as Map<String, Object?>;
        expect(turnData['seat'], hostSeat);
        expect(turnData['phase'], 'await_move');
        expect(turnData['queue'], <int>[2]);
        expect(turnData['deadline_ms'], turnSeconds * 1000,
            reason: 'docs/PROTOCOL.md 21.2: the timer\'s own step restarts '
                'the segment exactly as a player\'s move would; got '
                '$turnData');
        expect(await lobby.guest.client.next(), <String, Object?>{
          't': 'turn',
          'd': turnData,
        });
      }

      // (b) expiry in await_roll mid-streak.
      {
        final ServerHarness harness = await steeredHarness(
          const <int>[3],
          automaticTurnExpiry: false,
        );
        final WireTestLobby lobby = await seededLobby(harness.wsUri);
        final (Map<String, Object?> started, _) = await startGame(lobby);
        final int startingSeat = started['turn']! as int;
        final Room room = roomOf(harness, lobby.code);
        final int turnSeconds = room.rules.turnSeconds;

        forceQueueGame(
          room,
          currentSeat: startingSeat,
          phase: engine.GamePhase.awaitRoll,
          queue: const <int>[6],
          sixes: 1,
          tokens: const <int, List<int>>{},
          now: harness.clock.now,
        );

        harness.clock.advance(Duration(seconds: turnSeconds + 1));
        harness.server.runTurnExpiryOnce();

        final Map<String, Object?> rolled =
            await seatFor(lobby, startingSeat).client.next();
        expect(rolled['t'], 'rolled',
            reason: 'docs/RULES.md 15q: expiry in await_roll rolls; got '
                '"${rolled['t']}": ${rolled['d']}');
        final Map<String, Object?> rolledData =
            rolled['d']! as Map<String, Object?>;
        expect(rolledData['value'], 3, reason: 'steered; got $rolledData');
        expect(rolledData['queue'], <int>[6, 3]);
        expect(rolledData['legal'], <int>[0, 1, 2, 3],
            reason: 'a fresh board: all four tokens are legal for the '
                'default face 6; got $rolledData');
        expect(rolledData['deadline_ms'], turnSeconds * 1000,
            reason: 'docs/PROTOCOL.md 21.2: a rolled that leaves a move '
                'pending restarts the segment; got $rolledData');
        expect(rolledData.containsKey('re'), isFalse);

        final int otherSeat = startingSeat == lobby.host.seat
            ? lobby.guest.seat
            : lobby.host.seat;
        final Map<String, Object?> otherCopy =
            await seatFor(lobby, otherSeat).client.next();
        expect(otherCopy['t'], 'rolled');
        expect(otherCopy['d'], rolledData);
      }
    });
  });

  group('W13', () {
    test(
        'a finished queue game\'s verify record passes the existing '
        'record check (rolls drawn one per k, in order)', () async {
      final ServerHarness harness = await steeredHarness(const <int>[6, 3]);
      final WireTestLobby lobby = await seededLobby(harness.wsUri);
      final (Map<String, Object?> started, _) = await startGame(lobby);
      final int startingSeat = started['turn']! as int;
      final Room room = roomOf(harness, lobby.code);

      // Put the rolling seat one step short of its own win before any real
      // roll happens: three tokens home, the fourth at progress 51. The
      // phase/queue/sixes this leaves in place are exactly start_game's own
      // fresh values (await_roll, [], 0) -- only the tokens are forced.
      forceQueueGame(
        room,
        currentSeat: startingSeat,
        phase: engine.GamePhase.awaitRoll,
        queue: const <int>[],
        tokens: <int, List<int>>{
          startingSeat: <int>[57, 57, 57, 51]
        },
        now: harness.clock.now,
      );

      final List<int> observedFaces = <int>[];
      final Map<String, Object?> firstRolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      observedFaces
          .add((firstRolled['d']! as Map<String, Object?>)['value']! as int);
      await nextBroadcast(lobby, startingSeat); // same-seat turn after the 6

      final Map<String, Object?> secondRolled =
          await sendAndRead(lobby, startingSeat, 'roll', <String, Object?>{});
      observedFaces
          .add((secondRolled['d']! as Map<String, Object?>)['value']! as int);
      expect(observedFaces, <int>[6, 3]);

      final Map<String, Object?> moved = await sendAndRead(
        lobby,
        startingSeat,
        'move',
        <String, Object?>{'token': 3, 'face': 6},
      );
      expect((moved['d']! as Map<String, Object?>)['to'], 57);
      final Map<String, Object?> gameOver =
          await nextBroadcast(lobby, startingSeat);
      expect(gameOver['t'], 'game_over', reason: '${gameOver['d']}');

      expect(room.rollCount, 2);
      final String? recordJson =
          harness.registry.verifyStore.load(room.gameId!);
      expect(recordJson, isNotNull,
          reason: 'a finished game must have a saved verify record');
      final Map<String, Object?> record =
          jsonDecode(recordJson!) as Map<String, Object?>;
      expect(record['game_id'], room.gameId);
      expect(record['winner'], startingSeat);
      final List<Object?> rolls = record['rolls']! as List<Object?>;
      expect(rolls.length, 2,
          reason: 'docs/VERIFY.md section 1.2: one roll entry per k, and '
              'this game made exactly 2 real rolls; got $rolls');

      String parent = room.chain.commit;
      for (int i = 0; i < rolls.length; i++) {
        final Map<String, Object?> entry = rolls[i]! as Map<String, Object?>;
        expect(entry['k'], i + 1,
            reason: 'rolls drawn one per k, in order; got $rolls');
        expect(entry['seat'], startingSeat);
        final String reveal = entry['reveal']! as String;
        expect(
          verifyReveal(reveal: reveal, parent: parent),
          isTrue,
          reason: 'k=${entry['k']} reveal $reveal does not hash back to '
              'the previous chain link ($parent)',
        );
        expect(
          entry['die'],
          drawDie(reveal, room.gameId!, room.clientSeeds!, i + 1, 0),
          reason: 'the record\'s die must be the same pure function of '
              'its own reveal the live rolled frame used; got $entry',
        );
        expect(entry['die'], observedFaces[i],
            reason: 'the record\'s die for k=${i + 1} must match the '
                'face this test actually saw over the wire; got $entry, '
                'observed $observedFaces');
        parent = reveal;
      }
    });
  });
}
