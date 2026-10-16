// Acceptance tests for Sam's 2026-10-15 rule ruling, server side (order 355).
//
// Spec read for this file: docs/RULES.md rules 11a, 12, 21 and 28a;
// docs/ENGINE_API.md section 2 (RulesConfig), section 4 step 5 (the extra
// roll) and section 8 (the homeBonus paragraph); docs/PROTOCOL.md section 4
// (the blocks paragraph) and section 13.4 (the "rules absent" ruling).
//
// In short: a token arriving home grants another roll unless that move wins
// (rule 11a, engine toggle homeBonus, on for every server room); and a pair
// of one seat's own tokens on a square is a shelter, never a wall, which on
// the wire means blocks is accepted, type-checked and then ignored -- every
// room is created with it off and every frame that carries rules says
// "blocks": false.
//
// S1-S3 go over a real wire, against a running WireServer
// (test/support/wire_harness.dart), the way test/turn_loop_test.dart and
// test/protocol_conformance_test.dart already do for their own sections of
// docs/PROTOCOL.md. S4 and S5 go straight through RoomRegistry in-process,
// the way test/registry_seating_test.dart and test/verify_record_test.dart
// do for theirs.
//
// S5 needs a token at progress 51..56 with a known face. Steering a real
// room's dice chain to produce that many faces in advance
// (test/support/dice_oracle.dart) is not a search this suite can run:
// test/turn_loop_test.dart's own header measures an 8-roll capture sequence
// at roughly 6^8 (1.7 million candidates, 6.9 billion hashes) and calls that
// "not a search this suite can run"; a token reaching progress 51 needs on
// the order of 15 rolls or more, several more orders of magnitude past that.
// So this file reaches the position the way test/verify_record_test.dart
// reaches its win: a room is created, joined and started for real through
// RoomRegistry, and only then is Room.game replaced by a hand-edited
// round-trip of GameState.toJson()/fromJson(), one token row rewritten to
// progress 55 with the rest of that seat's tokens left in the yard and the
// phase moved to awaitMove with queue: [2] (roll stays null; the engine
// reads the queue). That is the point a real room would have reached after
// a closing roll of 2 left that token the only legal move.
// room.dart's own header says this kind of direct mutation of Room.game is
// expected ("order 008's turn loop does that by mutating Room.game and
// Room.state directly").

import 'dart:math';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

({RoomRegistry registry, FakeClock clock}) _directHarness() {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 10, 15));
  final RoomRegistry registry =
      RoomRegistry(clock: clock, secure: Random.secure());
  return (registry: registry, clock: clock);
}

CreateOk _create(
  RoomRegistry registry, {
  required String name,
  required int players,
  RulesConfig rules = const RulesConfig(),
}) {
  final CreateResult result =
      registry.createRoom(name: name, players: players, rules: rules);
  if (result is! CreateOk) {
    fail('expected CreateOk for name="$name" players=$players rules=$rules, '
        'got $result');
  }
  return result;
}

JoinOk _join(
  RoomRegistry registry, {
  required String code,
  required String name,
}) {
  final JoinResult result = registry.joinRoom(code: code, name: name);
  if (result is! JoinOk) {
    fail('expected JoinOk for code=$code name="$name", got $result');
  }
  return result;
}

StartOk _start(
  RoomRegistry registry, {
  required String code,
  required String seatToken,
}) {
  final StartResult result =
      registry.startGame(code: code, seatToken: seatToken);
  if (result is! StartOk) {
    fail('expected StartOk for code=$code, got $result');
  }
  return result;
}

/// Creates and starts a plain 2-seat room through [registry], with
/// [rules] at create_room, and returns the started [Room] together with
/// each seat's token, keyed by engine seat index (always 0 and 2 for a
/// 2-seat room, docs/RULES.md rule 2).
({Room room, Map<int, String> seatTokens}) _startedTwoSeatRoom(
  RoomRegistry registry, {
  RulesConfig rules = const RulesConfig(),
}) {
  final CreateOk host =
      _create(registry, name: 'Host', players: 2, rules: rules);
  final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
  final StartOk started = _start(
    registry,
    code: host.room.code,
    seatToken: host.seat.seatToken,
  );
  return (
    room: started.room,
    seatTokens: <int, String>{
      host.seat.seat: host.seat.seatToken,
      guest.seat.seat: guest.seat.seatToken,
    },
  );
}

void main() {
  group('S1: create_room with rules.blocks over the wire', () {
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

    test(
        'rules: {"blocks": true} is accepted, and both the host\'s and the '
        'guest\'s room frames say "blocks": false', () async {
      await harness.start();
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
        rules: const <String, Object?>{'blocks': true},
      );

      final Map<String, Object?> hostRules =
          lobby.hostRoom['rules']! as Map<String, Object?>;
      final Map<String, Object?> guestRules =
          lobby.guestRoom['rules']! as Map<String, Object?>;

      expect(
        hostRules['blocks'],
        isFalse,
        reason: 'docs/PROTOCOL.md section 4, 2026-10-15 ruling: the server '
            'must ignore an explicit rules.blocks: true at create_room and '
            'create the room with blocks off regardless; the host\'s own '
            'room frame said rules=$hostRules',
      );
      expect(
        guestRules['blocks'],
        isFalse,
        reason: 'the guest\'s room frame (from join_room, the same room) '
            'must carry the same "blocks": false the host\'s did; got '
            'rules=$guestRules',
      );
    });
  });

  group('S2: rules.blocks still type-checked', () {
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

    test('rules: {"blocks": "yes"} is rejected with BAD_FIELD', () async {
      await harness.start();
      final WireTestClient client = await WireTestClient.connect(
        harness.wsUri,
      );
      clients.add(client);

      client.send('create_room', <String, Object?>{
        'name': 'Host',
        'players': 2,
        'rules': <String, Object?>{'blocks': 'yes'},
      });
      final Map<String, Object?> frame = await client.next();

      expectErrorFrame(
        frame,
        'BAD_FIELD',
        because: 'docs/PROTOCOL.md section 4: blocks is ignored since '
            '2026-10-15, but "it must still be a bool if present"; a '
            'string value must still be rejected the same as before the '
            'ruling',
      );
    });
  });

  group('S3: rules absent at create_room', () {
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

    test(
        'an absent rules object defaults to "blocks": false, '
        '"capture_bonus": true', () async {
      await harness.start();
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
      );

      final Map<String, Object?> rules =
          lobby.hostRoom['rules']! as Map<String, Object?>;

      expect(
        rules['blocks'],
        isFalse,
        reason: 'docs/PROTOCOL.md section 13.4, as amended 2026-10-15: '
            '"rules absent -- accepted, and the room gets blocks: false"; '
            'got rules=$rules',
      );
      expect(
        rules['capture_bonus'],
        isTrue,
        reason: 'the documented default for capture_bonus (section 4) is '
            'unaffected by this ruling; got rules=$rules',
      );
    });
  });

  group('S4: the room\'s engine RulesConfig, after start_game', () {
    test(
        'defaults (capture_bonus left at its own default true) produce '
        'engine.RulesConfig(blocks: false, captureBonus: true, '
        'rollQueue: true, homeBonus: true)', () {
      final RoomRegistry registry = _directHarness().registry;
      final ({Room room, Map<int, String> seatTokens}) started =
          _startedTwoSeatRoom(registry);

      expect(
        started.room.game!.config.rules,
        engine.RulesConfig(
          blocks: false,
          captureBonus: true,
          rollQueue: true,
          homeBonus: true,
        ),
        reason: 'docs/ENGINE_API.md section 2, docs/PROTOCOL.md 21.3 rule 5 '
            'and the server side of the 2026-10-15 ruling: registry.dart '
            'must build every game\'s engine.RulesConfig with blocks: '
            'false, rollQueue: true and homeBonus: true regardless of what '
            'was requested, and captureBonus taken from the room\'s own '
            'rules; got ${started.room.game!.config.rules}',
      );
    });

    test(
        'capture_bonus: false at create_room carries through to '
        'engine.RulesConfig(blocks: false, captureBonus: false, '
        'rollQueue: true, homeBonus: true)', () {
      final RoomRegistry registry = _directHarness().registry;
      final ({Room room, Map<int, String> seatTokens}) started =
          _startedTwoSeatRoom(
        registry,
        rules: const RulesConfig(captureBonus: false),
      );

      expect(
        started.room.game!.config.rules,
        engine.RulesConfig(
          blocks: false,
          captureBonus: false,
          rollQueue: true,
          homeBonus: true,
        ),
        reason: 'a room created with capture_bonus: false must still turn '
            'blocks off, rollQueue on and homeBonus on, carrying only '
            'captureBonus through from the room\'s own rules; got '
            '${started.room.game!.config.rules}',
      );
    });
  });

  group('S5: a token reaching home without winning, through the registry', () {
    test(
        'leaves the same seat to roll again: the move result reports the '
        'extra roll and the turn does not pass', () {
      final RoomRegistry registry = _directHarness().registry;
      final ({Room room, Map<int, String> seatTokens}) started =
          _startedTwoSeatRoom(registry);
      final Room room = started.room;

      final int seatA = room.game!.currentSeat;
      final String seatAToken = started.seatTokens[seatA]!;

      // One token one square short of home, the rest still in the yard, so
      // the only legal move for a queued 2 is that one token, and seatA
      // cannot possibly win this move, since its other three tokens are
      // nowhere near progress 57. `roll` stays null; the queue carries the
      // face (docs/ENGINE_API.md section 10.1).
      final Map<String, Object?> gameJson = room.game!.toJson();
      final List<Object?> tokens = gameJson['tokens']! as List<Object?>;
      tokens[seatA] = const <int>[55, -1, -1, -1];
      gameJson['phase'] = 'awaitMove';
      gameJson['roll'] = null;
      gameJson['queue'] = <Object?>[2];
      room.game = engine.GameState.fromJson(gameJson);

      final List<int> legal = engine.legalTokens(room.game!);
      expect(
        legal,
        <int>[0],
        reason: 'fixture sanity check: with queue [2] and only token 0 '
            'above progress -1, token 0 must be the single legal move; got '
            'legalTokens=$legal',
      );

      final MoveResult result =
          registry.move(code: room.code, seatToken: seatAToken, token: 0);
      if (result is! MoveOk) {
        fail('expected MoveOk moving the home-bound token, got $result');
      }

      expect(
        result.events.whereType<engine.TokenHome>().length,
        1,
        reason: 'docs/ENGINE_API.md section 5 step 3: the move must emit '
            'TokenHome once the token reaches progress 57; events were '
            '${result.events}',
      );
      expect(
        result.events.whereType<engine.GameWon>(),
        isEmpty,
        reason: 'seatA\'s other three tokens are still in the yard, so this '
            'move must not win the game; events were ${result.events}',
      );
      expect(
        result.events.whereType<engine.ExtraRoll>().length,
        1,
        reason: 'docs/RULES.md rule 11a: a move that brings a token home '
            'without winning must grant exactly one ExtraRoll to the same '
            'seat; events were ${result.events}',
      );
      expect(
        result.events.whereType<engine.TurnBegan>(),
        isEmpty,
        reason: 'the turn must not pass to the next seat on a home-arrival '
            'extra roll; events were ${result.events}',
      );
      expect(
        result.gameOverSeq,
        isNull,
        reason: 'the game did not end; gameOverSeq must stay null',
      );
      expect(
        result.turnSeq,
        isNotNull,
        reason: 'section 12.2: a turn frame is still owed either way, so '
            'turnSeq must be set',
      );
      expect(
        room.game!.currentSeat,
        seatA,
        reason: 'the extra roll keeps the same seat on turn; '
            'currentSeat is now ${room.game!.currentSeat}, expected $seatA',
      );
      expect(
        room.game!.phase,
        engine.GamePhase.awaitRoll,
        reason: 'an extra roll leaves the room awaiting that seat\'s next '
            'roll, not a move; phase is ${room.game!.phase}',
      );
    });
  });
}
