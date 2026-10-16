// Order 156 -- what a seat sees, on a fresh socket, when it comes back
// *after* the turn-expiry sweep has already played its turn for it.
//
// Order 134 (`resume_holding_turn_test.dart`) measured the adjacent case: a
// seat that drops and resumes before any expiry could act. Its own header
// explains why it stopped there -- `turnExpiryInterval` was a hardcoded
// 1-second *real* `Timer.periodic`
// (`lib/src/wire_server.dart:turnExpiryInterval`), so the only way to
// observe the sweep land on a room was to wait out a real second, which that
// order's rules did not allow. Order 155 removed that obstacle: `WireServer`
// now takes `automaticTurnExpiry` (`lib/src/wire_server.dart:117`), and when
// it is false, `start()` creates no periodic timer at all
// (`lib/src/wire_server.dart:215`) and the sweep runs only when
// `runTurnExpiryOnce()` (`lib/src/wire_server.dart:244`) is called, through
// the same `_runTurnExpiry` the periodic timer would have called -- same
// guards, same broadcasts. Every server this file builds passes
// `automaticTurnExpiry: false`; nothing here waits on a real clock at all,
// and nothing here polls for a timer.
//
// Two scenarios, structurally parallel, differing only in the phase the
// segment is in when it expires:
//
// - S1: the seat drops holding a turn that still owes a roll (`await_roll`),
//   with a 6 already queued. The sweep rolls the closing non-6 for it.
//   That roll leaves a legal move (the queued 6 can leave the yard), so
//   rule 15q does not also play the move in the same step, and the resumed
//   seat is left in `await_move`, still on turn. A single roll from an
//   all-yard board cannot do this: rule 10q queues a 6 and offers no move
//   until a non-6 closes the rolling.
// - S2: the seat rolls through to a pending move (`await_move`), then
//   drops. The sweep plays rule 15q's one step (the default face on its
//   first legal token). The steered sequence, found by
//   `test/support/engine_search.dart` under the server's roll queue, is
//   chosen so that one move neither wins nor owes another roll and leaves
//   the queue empty, so the turn actually changes hands.
//
// **Measured, not assumed going in** (per this order's own text: "you do
// not know the answer in advance"): in both S1 and S2, `_handleResume`
// (`lib/src/connection.dart:371`) answers with a `room` snapshot built from
// `buildRoomSnapshot(ok.room, ...)` (`connection.dart:404`), where `ok.room`
// is `registry.resume`'s own `_rooms[code]` lookup
// (`lib/src/registry.dart:436`) -- the *same* mutable `Room` the sweep's
// `roll`/`move` calls (`registry.dart:535`, `registry.dart:638`) already
// wrote into in place. There is no cached or pre-drop copy anywhere on this
// path for a stale snapshot to come from. Both scenarios below found the
// resumed snapshot correct: the live post-sweep turn, matching the registry,
// not the pre-drop one. That is reported here as a measurement of this run,
// against this commit, not as a property proven for all time.
//
// In S1 the resumed seat still holds the turn (now `await_move`, on the
// rolled face the sweep drew) and a legal move from it is accepted. In S2
// the turn now belongs to the other seat, and a move attempt from the
// resumed seat is refused `NOT_YOUR_TURN`, promptly -- not ignored, not
// stalled.
//
// `resume_holding_turn_test.dart` is the template this file was told to
// reuse rather than reinvent: the steered-dice setup, `buildSteeredLobby`,
// `driveHandoffToNonHost`, `readAndDrain`/`sendAndRead`, `drainPresence` and
// `turnObject` below are the same patterns, copied and adapted (that file is
// out of the file list this order may edit, and is not imported from here:
// its own helpers are private to it). `rules.turn_seconds` is read off the
// wire in both scenarios below, never hardcoded, per this order's own
// instruction -- Sam's open decision on 45 vs. 90 seconds
// (`c-20260905-2326-307e`) is not this file's to settle.
import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// The fixed 2-player seat mapping (host=0, guest=2,
/// `lib/src/registry.dart:1186-1197`'s `_seatIndicesFor`), checked rather
/// than trusted -- see `buildSteeredLobby`'s own assertion below.
const List<int> _steeredSeats = <int>[0, 2];

const String _hostSteerSeed = 'resume-after-expiry-host-seed';
const String _guestSteerSeed = 'resume-after-expiry-guest-seed';
const String _steerClientSeeds = '0:$_hostSteerSeed|2:$_guestSteerSeed';

/// Computed offline exactly as `resume_holding_turn_test.dart` and
/// `turn_loop_test.dart` do: `buildScript`'s filler-byte formula at the
/// `game_id` offset does not depend on the secret spliced in ahead of it.
String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

/// S1's face sequence, under [serverRoomRules]. The last roll leaves a
/// legal move for the non-host seat. On a fresh yard that is a passing
/// non-6 (the handoff), a 6 the seat itself queues, then a closing non-6
/// the sweep will roll. Not hand-asserted: a future rule change that made
/// this untrue would fail this search instead of steering a face nobody
/// asked for.
List<int> _findAwaitRollExpiryFaces() {
  final List<int>? faces = findFaceSequence(
    seats: _steeredSeats,
    rules: serverRoomRules,
    accepts: (EngineRollStep step, engine.GameState stateAfterRoll) =>
        step.legal.isNotEmpty &&
        stateAfterRoll.currentSeat != _steeredSeats.first,
  );
  expect(
    faces,
    isNotNull,
    reason: 'test/support/engine_search.dart found no face sequence, within '
        'its own bound, whose last roll leaves a legal move for a seat '
        'other than the one that started the game',
  );
  return faces!;
}

/// S2's face sequence, under [serverRoomRules]. The last roll is the
/// non-host seat's, leaves a legal move, and the one move rule 15q commits
/// the sweep to (`legal.first`, no face, so the engine spends
/// `defaultFace`) is a plain `TurnBegan` to a different seat: the queue is
/// empty afterwards, so the frames are `moved` then `turn`, with no
/// `ExtraRoll`, no `GameWon` and no `TurnEnded`. A spent 6 grants nothing
/// (rule 12q), and a queued 6 plus a closer usually leaves the closer still
/// to spend, so this search looks past that first `await_move`.
List<int> _findAwaitMoveExpiryFaces() {
  final List<int>? faces = findFaceSequence(
    seats: _steeredSeats,
    rules: serverRoomRules,
    maxDepth: 6,
    accepts: (EngineRollStep step, engine.GameState stateAfterRoll) {
      if (stateAfterRoll.currentSeat != _steeredSeats[1]) {
        return false;
      }
      if (step.legal.isEmpty || step.face == 6) {
        return false;
      }
      final int seat = stateAfterRoll.currentSeat;
      final int token = step.legal.first;
      final engine.ApplyResult applied =
          engine.apply(stateAfterRoll, engine.MoveIntention(seat, token));
      if (applied is! engine.Applied) {
        return false;
      }
      if (applied.events.whereType<engine.ExtraRoll>().isNotEmpty) {
        return false;
      }
      if (applied.events.whereType<engine.GameWon>().isNotEmpty) {
        return false;
      }
      if (applied.events.whereType<engine.TurnEnded>().isNotEmpty) {
        return false;
      }
      final Iterable<engine.TurnBegan> began =
          applied.events.whereType<engine.TurnBegan>();
      return began.isNotEmpty && began.single.seat != seat;
    },
  );
  expect(
    faces,
    isNotNull,
    reason: 'test/support/engine_search.dart found no face sequence, within '
        'its own bound, whose last roll for the non-host seat leaves a '
        'legal move that plainly hands the turn onward once played -- no '
        'extra roll, no win',
  );
  return faces!;
}

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() {
    // Order 156: every server this file builds has no background
    // turn-expiry timer. `driveSweep` below is the only thing that ever
    // runs one, and it runs exactly once, synchronously, on demand.
    harness = ServerHarness.build(automaticTurnExpiry: false);
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  /// Builds a fresh 2-seat room steered so its first `wanted.length` rolls
  /// produce exactly `wanted`, joins a guest, fixes both seats' seeds, and
  /// starts the game. Reassigns the outer `harness` so `setUp`'s
  /// never-started default is replaced before anything talks to the
  /// network. Modelled on `resume_holding_turn_test.dart`'s own
  /// `buildSteeredLobby`, which is private to that file and may not be
  /// imported.
  Future<(WireTestLobby, Map<String, Object?>)> buildSteeredLobby(
    List<int> wanted,
  ) async {
    final String gameId = _predictedGameId();
    final SteeredSecret steered = findSecretForFaces(
      wanted: wanted,
      gameId: gameId,
      clientSeeds: _steerClientSeeds,
    );
    harness = ServerHarness.build(
      secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
      automaticTurnExpiry: false,
    );
    await harness.start();
    final WireTestLobby lobby =
        await buildWireTestLobby(harness.wsUri, clients, players: 2);
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      _steeredSeats,
      reason: 'this steering helper assumes the fixed 2-player seat mapping '
          '(host=0, guest=2, lib/src/registry.dart:967-978) so it can '
          'predict client_seeds before the room exists; got host='
          '${lobby.host.seat} guest=${lobby.guest.seat}. If this ever '
          'fails, the mapping changed and this file needs to change with '
          'it -- it is not a flake.',
    );

    lobby.host.client
        .send('set_seed', <String, Object?>{'client_seed': _hostSteerSeed});
    await receiveType(lobby.host.client, 'seat_seed');
    lobby.guest.client
        .send('set_seed', <String, Object?>{'client_seed': _guestSteerSeed});
    await receiveType(lobby.guest.client, 'seat_seed');

    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);

    expect(
      startedData['game_id'],
      gameId,
      reason: 'predicted game_id did not match game_started.game_id off '
          'the wire; the draw-order picture in scripted_bytes.dart no '
          'longer matches registry.dart',
    );
    expect(
      startedData['client_seeds'],
      _steerClientSeeds,
      reason: 'predicted client_seeds did not match game_started.'
          'client_seeds off the wire',
    );
    expect(
      startedData['turn'],
      lobby.host.seat,
      reason: 'setup requires the host to hold the opening turn so the '
          'steered first roll (which leaves no legal move) hands it to '
          'the non-host seat; got game_started.turn=${startedData['turn']} '
          'while the host is seat ${lobby.host.seat}',
    );

    return (lobby, startedData);
  }

  /// Reads the next frame off [actingClient] and, unless it is a private
  /// `error`, also reads and checks the identical broadcast copy off
  /// [otherClient]. Same design and same reason as
  /// `resume_holding_turn_test.dart`'s own `readAndDrain`: leaving the other
  /// socket's copy of an accepted message in its queue collides with
  /// whatever that socket's next read actually asked for.
  Future<Map<String, Object?>> readAndDrain(
    WireTestClient actingClient,
    WireTestClient otherClient, {
    required String because,
  }) async {
    final Map<String, Object?> mine = await actingClient.next();
    if (mine['t'] == 'error') {
      return mine;
    }
    final Map<String, Object?> theirs = await otherClient.next();
    expect(
      theirs['t'],
      mine['t'],
      reason: '$because: a broadcast push must reach every socket with the '
          'same frame type (docs/PROTOCOL.md section 12.3); one socket saw '
          '"${mine['t']}", the other saw "${theirs['t']}" instead',
    );
    expect(
      theirs['d'],
      mine['d'],
      reason: '$because: a broadcast push must reach every socket with the '
          'identical payload; one socket saw ${mine['d']}, the other saw '
          '${theirs['d']}',
    );
    return mine;
  }

  Future<Map<String, Object?>> sendAndRead(
    WireTestClient actingClient,
    WireTestClient otherClient,
    String type,
    Map<String, Object?> data, {
    required String because,
  }) {
    actingClient.send(type, data);
    return readAndDrain(actingClient, otherClient, because: because);
  }

  /// Drains what an empty-legal `rolled` queues behind it, off both
  /// sockets, and returns the `turn` frame's own `d`. A 6 is followed by
  /// one `turn` for the same seat still in `await_roll` (section 21.3); a
  /// turn that passed is `turn_passed` then `turn` (section 12.1).
  Future<Map<String, Object?>> consumeNoLegalMove(
    WireTestClient actingClient,
    WireTestClient otherClient, {
    required String because,
  }) async {
    final Map<String, Object?> next =
        await readAndDrain(actingClient, otherClient, because: because);
    if (next['t'] == 'turn') {
      final Map<String, Object?> turnData = next['d']! as Map<String, Object?>;
      expect(
        turnData['phase'],
        'await_roll',
        reason: '$because: an empty-legal rolled followed by turn is the '
            'extra roll a 6 owes, which stays await_roll; got $turnData',
      );
      return turnData;
    }
    expect(
      next['t'],
      'turn_passed',
      reason: '$because: a rolled frame with an empty legal list must be '
          'followed by turn (a queued 6) or turn_passed; got '
          '"${next['t']}": ${next['d']}',
    );
    final Map<String, Object?> turn =
        await readAndDrain(actingClient, otherClient, because: because);
    expect(
      turn['t'],
      'turn',
      reason: '$because: turn_passed must be followed by turn for the next '
          'seat; got "${turn['t']}": ${turn['d']}',
    );
    return turn['d']! as Map<String, Object?>;
  }

  /// Spends [legal] and every face still pending after it, always
  /// `legal.first`, until the phase leaves `await_move`. Returns the seat
  /// that then holds the turn.
  Future<int> spendUntilAwaitRoll(
    WireTestClient actingClient,
    WireTestClient otherClient,
    List<int> legal, {
    required String because,
  }) async {
    List<int> pending = legal;
    while (true) {
      final Map<String, Object?> moved = await sendAndRead(
        actingClient,
        otherClient,
        'move',
        <String, Object?>{'token': pending.first},
        because: because,
      );
      expect(
        moved['t'],
        'moved',
        reason: '$because: expected moved, got "${moved['t']}": '
            '${moved['d']}',
      );
      final Map<String, Object?> after = await readAndDrain(
        actingClient,
        otherClient,
        because: because,
      );
      if (after['t'] == 'game_over') {
        fail(
          '$because: reached game_over while spending a queued face; the '
          'offline search must have missed a win reachable this early',
        );
      }
      if (after['t'] == 'turn_passed') {
        final Map<String, Object?> turn = await readAndDrain(
          actingClient,
          otherClient,
          because: because,
        );
        expect(
          turn['t'],
          'turn',
          reason: '$because: turn_passed after a move must be followed by '
              'turn; got "${turn['t']}": ${turn['d']}',
        );
        return (turn['d']! as Map<String, Object?>)['seat']! as int;
      }
      expect(
        after['t'],
        'turn',
        reason: '$because: moved must be followed by game_over, '
            'turn_passed or turn; got "${after['t']}": ${after['d']}',
      );
      final Map<String, Object?> turnData = after['d']! as Map<String, Object?>;
      if (turnData['phase'] == 'await_move') {
        final Object? rawLegal = turnData['legal'];
        if (rawLegal is! List<Object?> || rawLegal.isEmpty) {
          fail('$because: await_move must name a legal token, got $turnData');
        }
        pending = rawLegal.cast<int>();
        continue;
      }
      expect(
        turnData['phase'],
        'await_roll',
        reason: '$because: a turn after the queue is spent must be '
            'await_roll; got $turnData',
      );
      return turnData['seat']! as int;
    }
  }

  WireTestClient _clientFor(WireTestLobby lobby, int seat) =>
      seat == lobby.host.seat ? lobby.host.client : lobby.guest.client;

  /// The face an `await_move` frame names as `value` (`defaultFace`).
  int defaultFaceOf(Map<String, Object?> data, {required String because}) {
    final Object? raw = data['legal_by_face'];
    if (raw is! List<Object?> || raw.isEmpty) {
      fail('$because: await_move must carry legal_by_face, got $data');
    }
    final Object? first = raw.first;
    if (first is! Map<String, Object?>) {
      fail('$because: legal_by_face entries must be objects, got $first');
    }
    final Object? face = first['face'];
    if (face is! int) {
      fail('$because: legal_by_face.face must be an int, got $face');
    }
    return face;
  }

  /// The `turn` object of a `room` snapshot's own `d`, asserted present and
  /// shaped as a map before a caller reads a field off it.
  Map<String, Object?> turnObject(Map<String, Object?> roomData) {
    final Object? turn = roomData['turn'];
    expect(
      turn,
      isA<Map<String, Object?>>(),
      reason: 'expected a turn object in the resumed room snapshot '
          '(snapshot.dart\'s buildRoomSnapshot always calls _turnSnapshot '
          'once a game exists); got ${turn.runtimeType}: $turn',
    );
    return turn! as Map<String, Object?>;
  }

  /// One seat's own `tokens` array off a `room` snapshot's `seats` list --
  /// section 6: four `progress` integers, the board state this order's item
  /// 3 asks be checked against what the sweep actually did.
  List<Object?> tokensFor(Map<String, Object?> roomData, int seat) {
    final List<Object?> seats = roomData['seats']! as List<Object?>;
    for (final Object? entry in seats) {
      final Map<String, Object?> seatData = entry! as Map<String, Object?>;
      if (seatData['seat'] == seat) {
        return seatData['tokens']! as List<Object?>;
      }
    }
    fail('no seat $seat in room snapshot seats: $seats');
  }

  /// A socket closing and a resume that flips a seat back each broadcast one
  /// `presence` push to every *other* socket in the room -- never to the
  /// socket that just left or returned. Same helper and same reasoning as
  /// `resume_holding_turn_test.dart`'s own `drainPresence`.
  Future<void> drainPresence(
    WireTestClient survivorClient,
    int seat, {
    required bool connected,
  }) async {
    final Map<String, Object?> presence = await survivorClient.next();
    expect(
      presence['t'],
      'presence',
      reason: 'expected the surviving socket to see a presence push for '
          'seat $seat (connected=$connected); got "${presence['t']}": '
          '${presence['d']}',
    );
    final Map<String, Object?> presenceData =
        presence['d']! as Map<String, Object?>;
    expect(presenceData['seat'], seat);
    expect(
      presenceData['connected'],
      connected,
      reason: 'expected presence.connected=$connected for seat $seat; got '
          '${presenceData['connected']}',
    );
  }

  /// Plays steered rolls until the non-host seat holds an unrolled turn,
  /// and returns the index of its first unplayed face. The host is the
  /// only seat that rolls here: the search's handoff is that seat passing
  /// before the guest has rolled at all.
  Future<int> driveHandoffToNonHost(
    WireTestLobby lobby,
    List<int> faces,
  ) async {
    var index = 0;
    while (index < faces.length) {
      final Map<String, Object?> rolled = await sendAndRead(
        lobby.host.client,
        lobby.guest.client,
        'roll',
        <String, Object?>{},
        because: 'steered handoff roll ${index + 1}',
      );
      expect(
        rolled['t'],
        'rolled',
        reason: 'expected a rolled frame from the host in room '
            '${lobby.code}, got "${rolled['t']}": ${rolled['d']}',
      );
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(
        rolledData['value'],
        faces[index],
        reason: 'steering must produce face ${faces[index]} at roll '
            '${index + 1}; got ${rolledData['value']}',
      );
      expect(
        rolledData['legal'],
        isEmpty,
        reason: 'the handoff must not reach await_move before the non-host '
            'seat is the one on turn; got legal=${rolledData['legal']}',
      );
      index++;
      final Map<String, Object?> turnData = await consumeNoLegalMove(
        lobby.host.client,
        lobby.guest.client,
        because: 'handoff roll left nothing to move',
      );
      if (turnData['seat'] == lobby.guest.seat &&
          rolledData['seat'] != lobby.guest.seat) {
        return index;
      }
    }
    fail(
      'steered faces $faces never handed an unrolled turn to seat '
      '${lobby.guest.seat}',
    );
  }

  /// The guest rolls every steered face from [start] up to but not
  /// including the last. Each of those is a 6 the search queued (an
  /// earlier legal move would have been the sequence's end). Leaves the
  /// guest in `await_roll` with that queue, so the sweep can roll [faces]'s
  /// last face.
  Future<void> queueGuestRollsBeforeLast(
    WireTestLobby lobby,
    List<int> faces,
    int start,
  ) async {
    if (start >= faces.length - 1) {
      fail(
        'the sweep needs a steered roll still unplayed; faces=$faces '
        'start=$start',
      );
    }
    for (int i = start; i < faces.length - 1; i++) {
      final Map<String, Object?> rolled = await sendAndRead(
        lobby.guest.client,
        lobby.host.client,
        'roll',
        <String, Object?>{},
        because: 'the non-host seat queues face ${faces[i]} before the drop',
      );
      expect(rolled['t'], 'rolled');
      final Map<String, Object?> data = rolled['d']! as Map<String, Object?>;
      expect(data['value'], faces[i]);
      expect(data['seat'], lobby.guest.seat);
      expect(
        data['legal'],
        isEmpty,
        reason: 'a roll before the closing one must not leave a move yet; '
            'got $data',
      );
      final Map<String, Object?> turnData = await consumeNoLegalMove(
        lobby.guest.client,
        lobby.host.client,
        because: 'face ${faces[i]} queued, the seat still owes a roll',
      );
      expect(turnData['seat'], lobby.guest.seat);
      expect(turnData['phase'], 'await_roll');
    }
  }

  /// Plays every steered face except the last, spending a queue whenever a
  /// roll leaves a move. Returns with the non-host seat in `await_roll`,
  /// about to roll [faces]'s last face: the one the sweep will find pending.
  Future<void> playAllButLast(WireTestLobby lobby, List<int> faces) async {
    if (faces.length < 2) {
      fail('S2 needs a setup roll and a closing roll; got $faces');
    }
    var seat = lobby.host.seat;
    for (int i = 0; i < faces.length - 1; i++) {
      final WireTestClient actor = _clientFor(lobby, seat);
      final WireTestClient other = _clientFor(
        lobby,
        seat == lobby.host.seat ? lobby.guest.seat : lobby.host.seat,
      );
      final Map<String, Object?> rolled = await sendAndRead(
        actor,
        other,
        'roll',
        <String, Object?>{},
        because: 'setup roll ${i + 1}/${faces.length} (face ${faces[i]})',
      );
      expect(
        rolled['t'],
        'rolled',
        reason: 'setup roll ${i + 1} must be accepted; got '
            '"${rolled['t']}": ${rolled['d']}',
      );
      final Map<String, Object?> data = rolled['d']! as Map<String, Object?>;
      expect(data['value'], faces[i]);
      expect(data['seat'], seat);
      final List<Object?> legal = data['legal']! as List<Object?>;
      if (legal.isEmpty) {
        final Map<String, Object?> turnData = await consumeNoLegalMove(
          actor,
          other,
          because: 'setup roll ${i + 1} left nothing to move',
        );
        seat = turnData['seat']! as int;
      } else {
        seat = await spendUntilAwaitRoll(
          actor,
          other,
          legal.cast<int>(),
          because: 'setup roll ${i + 1} left a queue to spend',
        );
      }
    }
    expect(
      seat,
      lobby.guest.seat,
      reason: 'the last steered roll must belong to the non-host seat; '
          'after the prefix the seat on turn is $seat, faces=$faces',
    );
  }

  /// `rules.turn_seconds` off the wire, as this order's own text requires
  /// ("Read `room.rules.turnSeconds`; never hardcode a number of seconds").
  int turnSecondsOf(WireTestLobby lobby) {
    final Map<String, Object?> rules =
        lobby.hostRoom['rules']! as Map<String, Object?>;
    return rules['turn_seconds']! as int;
  }

  /// Advances the harness's injected `FakeClock` strictly past one full
  /// segment budget -- no real wall-clock wait, no `Future.delayed`, no
  /// polling -- and runs exactly one synchronous turn-expiry sweep through
  /// the seam order 155 added. Never called more than once per scenario:
  /// `runTurnExpiryOnce` is documented to run the identical sweep the
  /// periodic timer would, and one call is exactly the "the clock passes
  /// the budget, the sweep acts" this order describes.
  void expireOneSegment(WireTestLobby lobby) {
    final int turnSeconds = turnSecondsOf(lobby);
    harness.clock.advance(Duration(seconds: turnSeconds + 1));
    harness.server.runTurnExpiryOnce();
  }

  group(
      'a non-host seat drops, its segment expires while it is away, and '
      'it resumes on a fresh socket after the sweep already acted', () {
    test(
        'await_roll: the sweep rolls for the dropped seat; the roll leaves '
        'a legal move, so the resumed snapshot still names that seat on '
        'turn, now in await_move, and its own legal move is accepted',
        () async {
      final List<int> faces = _findAwaitRollExpiryFaces();
      final (WireTestLobby lobby, _) = await buildSteeredLobby(faces);

      final int nextFace = await driveHandoffToNonHost(lobby, faces);
      // A 6 has to be queued before the drop. The sweep takes one step
      // (rule 15q), and only the closing non-6 leaves a move.
      await queueGuestRollsBeforeLast(lobby, faces, nextFace);

      // The moment under test: the non-host seat drops while it still owes
      // a roll. The queued 6 is unspent; the sweep will roll the closer.
      await lobby.guest.client.close();
      await drainPresence(lobby.host.client, lobby.guest.seat,
          connected: false);

      // The clock passes the segment budget and the sweep acts while the
      // seat is still away -- observed here from the host's still-open
      // socket, which is the wire, not the server's own log (item 1).
      expireOneSegment(lobby);
      final Map<String, Object?> sweepFrame = await lobby.host.client.next();
      expect(
        sweepFrame['t'],
        'rolled',
        reason: 'point of death candidate: the sweep must roll for the '
            'dropped seat once its segment expires in await_roll '
            '(docs/RULES.md rule 16a) and publish it as an ordinary rolled '
            'frame; got "${sweepFrame['t']}": ${sweepFrame['d']}',
      );
      final Map<String, Object?> sweepData =
          sweepFrame['d']! as Map<String, Object?>;
      expect(
        sweepData['seat'],
        lobby.guest.seat,
        reason: 'the sweep rolled for the wrong seat; expected seat '
            '${lobby.guest.seat}, got ${sweepData['seat']}',
      );
      expect(
        sweepData['value'],
        faces.last,
        reason: 'the sweep\'s own roll is the last steered face; wanted '
            '${faces.last}, got ${sweepData['value']}',
      );
      expect(
        sweepData['queue'],
        faces.sublist(nextFace),
        reason: 'the closing roll appends onto the faces the seat queued '
            'before the drop; got queue=${sweepData['queue']}, steered '
            'tail=${faces.sublist(nextFace)}',
      );
      expect(
        sweepData['legal'],
        isNotEmpty,
        reason: 'setup requires the sweep\'s steered roll to leave a legal '
            'move, so the segment does not end here and the resumed seat '
            'is still the one on turn; got legal=${sweepData['legal']}',
      );

      final WireTestClient freshGuest =
          await WireTestClient.connect(harness.wsUri);
      clients.add(freshGuest);
      final String resumeId = freshGuest.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      // docs/PROTOCOL.md section 15 rule 2: resume is answered with
      // seat_assigned, then room, whether or not the seat moved while it
      // was away.
      await expectSeatAssigned(
        freshGuest,
        expectedSeat: lobby.guest.seat,
        expectedToken: lobby.guest.token,
        because: 'S1 (await_roll sweep): resume must answer seat_assigned '
            'before the room snapshot',
      );
      final Map<String, Object?> resumeFrame = await freshGuest.next();
      expect(
        resumeFrame['t'],
        'room',
        reason: 'resume on a fresh socket must answer with a room snapshot, '
            'immediately after seat_assigned (connection.dart\'s '
            '_handleResume, docs/PROTOCOL.md section 8); got '
            '"${resumeFrame['t']}": ${resumeFrame['d']}',
      );
      expect(resumeFrame['re'], resumeId);
      await drainPresence(lobby.host.client, lobby.guest.seat, connected: true);
      final Map<String, Object?> roomData =
          resumeFrame['d']! as Map<String, Object?>;

      // Item 2: the resumed turn object must be the turn that exists now,
      // after the sweep, not the pre-drop await_roll turn.
      final Map<String, Object?> resumedTurn = turnObject(roomData);
      expect(
        resumedTurn['seat'],
        lobby.guest.seat,
        reason: 'point of death candidate: the resumed room snapshot must '
            'name seat ${lobby.guest.seat} as on turn, exactly as the '
            'registry holds it after the sweep; got seat='
            '${resumedTurn['seat']}',
      );
      expect(
        resumedTurn['phase'],
        'await_move',
        reason: 'point of death candidate: the sweep\'s own roll left a '
            'legal move, so the seat it rolled for is now in await_move, '
            'not the pre-drop await_roll; got phase='
            '${resumedTurn['phase']}',
      );
      expect(
        resumedTurn['value'],
        defaultFaceOf(sweepData, because: 'the sweep\'s closing roll'),
        reason: 'point of death candidate: the resumed turn object\'s '
            'value is defaultFace (docs/PROTOCOL.md 21.3), the face the '
            'seat will spend, which is not necessarily the face the sweep '
            'just rolled (${sweepData['value']}); got '
            '${resumedTurn['value']}',
      );
      expect(
        resumedTurn['queue'],
        sweepData['queue'],
        reason: 'the resumed queue must be the one the sweep\'s rolled '
            'frame already announced; got ${resumedTurn['queue']}',
      );
      expect(
        resumedTurn['legal'],
        sweepData['legal'],
        reason: 'point of death candidate: the resumed turn object\'s '
            'legal list must match what the sweep\'s own rolled frame '
            'already announced; got ${resumedTurn['legal']}, sweep said '
            '${sweepData['legal']}',
      );
      expect(
        resumedTurn['legal_by_face'],
        sweepData['legal_by_face'],
        reason: 'the resumed legal_by_face must match the sweep\'s rolled '
            'frame; got ${resumedTurn['legal_by_face']}',
      );
      final int turnSeconds = turnSecondsOf(lobby);
      expect(
        resumedTurn['deadline_ms'],
        turnSeconds * 1000,
        reason: 'point of death candidate: the sweep\'s own roll restarted '
            'the segment (docs/PROTOCOL.md section 6: a rolled frame that '
            'leaves a legal move pending restarts it), and no further time '
            'has passed on the injected clock since; the resumed deadline '
            'must read the full budget, got ${resumedTurn['deadline_ms']}',
      );

      // Item 3: the board reflects what the sweep did -- here, a roll only,
      // so the guest's tokens must still all be in the yard.
      expect(
        tokensFor(roomData, lobby.guest.seat),
        <int>[-1, -1, -1, -1],
        reason: 'the sweep only rolled in this scenario; no token should '
            'have moved yet',
      );

      // Item 4: the snapshot says the resumed seat still holds the turn,
      // so its own legal move must be accepted.
      final int legalToken =
          (resumedTurn['legal']! as List<Object?>).cast<int>().first;
      final Map<String, Object?> moved = await sendAndRead(
        freshGuest,
        lobby.host.client,
        'move',
        <String, Object?>{'token': legalToken},
        because: 'the resumed seat\'s own move, on the turn the snapshot '
            'told it it still held',
      );
      expect(
        moved['t'],
        'moved',
        reason: 'THE FINDING: seat ${lobby.guest.seat} resumed on a fresh '
            'socket after the turn-expiry sweep rolled for it in room '
            '${lobby.code}, was told by its own resumed snapshot that it '
            'still held the turn, and its own legal move came back as '
            '"${moved['t']}" (${moved['d']}) instead of "moved"',
      );
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(movedData['seat'], lobby.guest.seat);
      expect(movedData['token'], legalToken);
    });

    test(
        'await_move: the sweep plays the dropped seat\'s pending roll, the '
        'move hands the turn to the other seat, and the resumed snapshot '
        'shows that -- a move attempt from the resumed seat is refused '
        'NOT_YOUR_TURN', () async {
      final List<int> faces = _findAwaitMoveExpiryFaces();
      final (WireTestLobby lobby, _) = await buildSteeredLobby(faces);

      // Spend every steered roll except the last. The search chose that
      // last roll so one timer step (rule 15q) hands the turn on: no extra
      // roll, no win, queue empty afterwards. A 6 spent on a move grants
      // nothing (rule 12q), so the old "move the 6, then take its extra
      // roll" setup is not a state the queue can be in.
      await playAllButLast(lobby, faces);
      final Map<String, Object?> secondRoll = await sendAndRead(
        lobby.guest.client,
        lobby.host.client,
        'roll',
        <String, Object?>{},
        because: 'the non-host seat\'s closing roll, before it drops',
      );
      expect(secondRoll['t'], 'rolled');
      final Map<String, Object?> secondRollData =
          secondRoll['d']! as Map<String, Object?>;
      expect(
        secondRollData['value'],
        faces.last,
        reason: 'wanted ${faces.last}, got ${secondRollData['value']}',
      );
      expect(
        secondRollData['seat'],
        lobby.guest.seat,
      );
      expect(
        secondRollData['legal'],
        isNotEmpty,
        reason: 'setup requires the closing roll to leave a legal move, so '
            'the seat is genuinely in await_move (a pending decision) when '
            'it drops, not bounced onward automatically; got legal='
            '${secondRollData['legal']}',
      );

      // The moment under test: the non-host seat drops holding a pending,
      // unplayed roll.
      await lobby.guest.client.close();
      await drainPresence(lobby.host.client, lobby.guest.seat,
          connected: false);

      // The clock passes the segment budget and the sweep plays the
      // pending roll's own legal move for the dropped seat -- observed
      // here off the host's still-open socket (item 1).
      expireOneSegment(lobby);
      final Map<String, Object?> sweepMoveFrame =
          await lobby.host.client.next();
      expect(
        sweepMoveFrame['t'],
        'moved',
        reason: 'point of death candidate: the sweep must play the '
            'dropped seat\'s pending move once its segment expires in '
            'await_move (docs/RULES.md rule 15) and publish it as an '
            'ordinary moved frame; got "${sweepMoveFrame['t']}": '
            '${sweepMoveFrame['d']}',
      );
      final Map<String, Object?> sweepMoveData =
          sweepMoveFrame['d']! as Map<String, Object?>;
      expect(sweepMoveData['seat'], lobby.guest.seat);
      final int sweptToken =
          (secondRollData['legal']! as List<Object?>).cast<int>().first;
      expect(
        sweepMoveData['token'],
        sweptToken,
        reason: 'rule 15: where several legal moves exist the ascending '
            'token index decides; expected $sweptToken, got '
            '${sweepMoveData['token']}',
      );
      expect(
        sweepMoveData['extra_roll'],
        isFalse,
        reason: 'setup requires this steered move to grant no further '
            'extra roll, so the turn genuinely changes hands; got '
            'extra_roll=${sweepMoveData['extra_roll']}',
      );
      final Map<String, Object?> sweepTurnFrame =
          await lobby.host.client.next();
      expect(
        sweepTurnFrame['t'],
        'turn',
        reason: 'a moved frame that neither wins nor grants an extra roll '
            'must be followed by a turn frame for the next seat (section '
            '12.2); got "${sweepTurnFrame['t']}": ${sweepTurnFrame['d']}',
      );
      final Map<String, Object?> sweepTurnData =
          sweepTurnFrame['d']! as Map<String, Object?>;
      expect(
        sweepTurnData['seat'],
        lobby.host.seat,
        reason: 'setup requires the steered move to hand the turn to the '
            'host; got turn.seat=${sweepTurnData['seat']}',
      );

      final WireTestClient freshGuest =
          await WireTestClient.connect(harness.wsUri);
      clients.add(freshGuest);
      final String resumeId = freshGuest.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      // docs/PROTOCOL.md section 15 rule 2: resume is answered with
      // seat_assigned, then room, whether or not the seat moved while it
      // was away.
      await expectSeatAssigned(
        freshGuest,
        expectedSeat: lobby.guest.seat,
        expectedToken: lobby.guest.token,
        because: 'S2 (await_move sweep): resume must answer seat_assigned '
            'before the room snapshot',
      );
      final Map<String, Object?> resumeFrame = await freshGuest.next();
      expect(
        resumeFrame['t'],
        'room',
        reason: 'resume on a fresh socket must answer with a room snapshot, '
            'immediately after seat_assigned; got "${resumeFrame['t']}": '
            '${resumeFrame['d']}',
      );
      expect(resumeFrame['re'], resumeId);
      await drainPresence(lobby.host.client, lobby.guest.seat, connected: true);
      final Map<String, Object?> roomData =
          resumeFrame['d']! as Map<String, Object?>;

      // Item 2: the resumed turn object is the turn that exists now -- the
      // host's, not the guest's pre-drop pending move.
      final Map<String, Object?> resumedTurn = turnObject(roomData);
      expect(
        resumedTurn['seat'],
        lobby.host.seat,
        reason: 'point of death candidate: the resumed room snapshot must '
            'name seat ${lobby.host.seat} as on turn, exactly as the '
            'registry holds it after the sweep\'s move handed it there; '
            'got seat=${resumedTurn['seat']}',
      );
      expect(
        resumedTurn['phase'],
        'await_roll',
        reason: 'point of death candidate: the host has not rolled yet; '
            'got phase=${resumedTurn['phase']}',
      );
      expect(
        resumedTurn.containsKey('value'),
        isFalse,
        reason: 'docs/PROTOCOL.md section 6: value is absent when phase is '
            'await_roll; got ${resumedTurn['value']}',
      );
      final int turnSeconds = turnSecondsOf(lobby);
      expect(
        resumedTurn['deadline_ms'],
        turnSeconds * 1000,
        reason: 'point of death candidate: the sweep\'s own move restarted '
            'the segment for the host (section 6: the next seat\'s turn '
            'frame restarts it), and no further time has passed on the '
            'injected clock since; got ${resumedTurn['deadline_ms']}',
      );

      // Item 3: the board reflects what the sweep did -- the swept token
      // advanced by the steered face.
      final List<Object?> guestTokens = tokensFor(roomData, lobby.guest.seat);
      expect(
        guestTokens[sweptToken],
        sweepMoveData['to'],
        reason: 'point of death candidate: the resumed board must show '
            'the token the sweep moved at the progress it moved it to; '
            'got tokens=$guestTokens, sweep moved token $sweptToken to '
            '${sweepMoveData['to']}',
      );

      // Item 4: the snapshot says another seat now holds the turn, so a
      // move attempt from the resumed seat must be refused promptly, not
      // ignored into a stall.
      freshGuest.send('move', <String, Object?>{'token': sweptToken});
      final Map<String, Object?> refused = await freshGuest.next();
      expect(
        refused['t'],
        'error',
        reason: 'THE FINDING: seat ${lobby.guest.seat} resumed after the '
            'turn-expiry sweep moved for it and handed the turn to seat '
            '${lobby.host.seat} in room ${lobby.code}; its own move attempt '
            'must be refused, not accepted or left unanswered, and instead '
            'came back as "${refused['t']}": ${refused['d']}',
      );
      expectErrorFrame(
        refused,
        'NOT_YOUR_TURN',
        because: 'seat ${lobby.host.seat} holds the turn after the sweep, '
            'not the just-resumed seat ${lobby.guest.seat} '
            '(docs/PROTOCOL.md section 7)',
      );

      // The game is not stalled: the seat the snapshot actually named can
      // still act.
      final Map<String, Object?> hostRolled = await sendAndRead(
        lobby.host.client,
        freshGuest,
        'roll',
        <String, Object?>{},
        because: 'proving the room is not stalled: the seat the resumed '
            'snapshot actually named on turn can still roll',
      );
      expect(hostRolled['t'], 'rolled');
    });
  });
}
