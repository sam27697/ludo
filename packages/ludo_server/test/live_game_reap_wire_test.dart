// Wire-level conformance for contract C-451, "a game being played is never
// reaped by the clock" (docs/PROTOCOL.md section 3, rewritten by the
// contract: a PLAYING room is reaped only after 10 minutes with no connected
// seat, or at the 6 hour ceiling, never at 60 minutes total).
//
// W1: through the real wire harness the turn-loop tests use (a real
// WireServer, two real sockets speaking the real protocol), a two-seat game
// whose FakeClock has been advanced 61 minutes past creation with both
// sockets still connected. After `reap()` the room must still be in the
// registry and the action the room owes next must be accepted, not answered
// NO_SUCH_ROOM.
//
// The periodic turn-expiry sweep is switched off (`automaticTurnExpiry:
// false`, the seam resume_after_expiry_test.dart uses) so that no wall-clock
// timer can act for a seat between the clock advance and the owed action.
// That keeps the owed action a pure function of the room the registry holds
// and keeps every run identical. The seat on turn is read from the registry
// at the moment of sending, so the test is correct whichever seat the game
// opened on.
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart' show Room, RoomState;
import 'package:test/test.dart';

import 'support/wire_harness.dart';

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() {
    harness = ServerHarness.build(automaticTurnExpiry: false);
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  /// Sends `start_game` from the host and drains `game_started` plus the
  /// standalone `turn` (section 13.1) off both sockets. Returns the seat the
  /// game opened on.
  Future<int> startGame(WireTestLobby lobby) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final int startingSeat =
        (hostStarted['d']! as Map<String, Object?>)['turn']! as int;
    await expectOpeningTurn(lobby.host.client, startingSeat);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startingSeat);
    return startingSeat;
  }

  /// Reads frames off [seat]'s socket until the one answering [id] arrives
  /// (the sender's copy carries `re`), and returns it.
  Future<Map<String, Object?>> answerTo(WireTestSeat seat, String id) async {
    final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
    for (int i = 0; i < 8; i++) {
      final Map<String, Object?> frame = await seat.client.next();
      seen.add(frame);
      if (frame['re'] == id) {
        return frame;
      }
    }
    throw TestFailure(
      'expected a frame answering message $id on seat ${seat.seat} within 8 '
      'frames and none arrived; frames seen: $seen',
    );
  }

  test(
      'W1: a two-seat game 61 minutes past creation with both sockets '
      'connected is still in the registry and accepts the action it owes',
      () async {
    await harness.start();
    final WireTestLobby lobby =
        await buildWireTestLobby(harness.wsUri, clients);
    final int openingSeat = await startGame(lobby);
    final String scenario = 'scenario W1: room ${lobby.code}, two seats, game '
        'opened on seat $openingSeat, FakeClock advanced 61 minutes past '
        'creation, both sockets connected, automaticTurnExpiry off';

    final Room? before = harness.registry.lookup(lobby.code);
    expect(before, isNotNull, reason: 'fixture setup: $scenario');
    expect(before!.state, RoomState.playing,
        reason: 'fixture setup: $scenario');
    expect(
      before.seats.every((seat) => seat.connected),
      isTrue,
      reason: 'fixture setup: both sockets are open, so both seats must read '
          'as connected; $scenario',
    );

    harness.clock.advance(const Duration(minutes: 61));
    final int reaped = harness.registry.reap();

    expect(
      reaped,
      0,
      reason: 'a PLAYING room with every seat connected must not be reaped '
          '61 minutes after creation; reap() removed $reaped room(s); '
          '$scenario',
    );
    final Room? room = harness.registry.lookup(lobby.code);
    expect(
      room,
      isNotNull,
      reason: 'room ${lobby.code} must still be in the registry after '
          'reap() at 61 minutes with both seats connected; it is gone; '
          '$scenario',
    );

    final engine.GameState game = room!.game!;
    final int owedSeat = game.currentSeat;
    final WireTestSeat sender =
        owedSeat == lobby.host.seat ? lobby.host : lobby.guest;
    expect(
      game.phase,
      engine.GamePhase.awaitRoll,
      reason: 'fixture setup: with the sweep off, a freshly started game '
          'owes a roll from seat $owedSeat; $scenario',
    );
    final String id = sender.client.send('roll', <String, Object?>{});

    final Map<String, Object?> reply = await answerTo(sender, id);
    final Map<String, Object?> data = reply['d']! as Map<String, Object?>;
    expect(
      reply['t'],
      isNot('error'),
      reason: 'the owed roll from seat $owedSeat must be accepted '
          'in a live game 61 minutes old; the server answered error code '
          '${data['code']} (message: "${data['message']}"); $scenario',
    );
    expect(
      reply['t'],
      'rolled',
      reason: 'the accepted roll must be answered by its own rolled '
          'broadcast; got "${reply['t']}": $data; $scenario',
    );
  });
}
