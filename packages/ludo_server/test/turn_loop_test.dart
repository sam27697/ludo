// Conformance tests for `docs/PROTOCOL.md` section 12, the turn loop, read
// together with sections 4, 5, 6, 7 and 11.2. Written from those sections
// only, against a real, running `WireServer`, the same way
// `fairness_lobby_test.dart` covers section 11's lobby half.
//
// Every test in this file is expected to fail on this branch. `roll` and
// `move` currently answer `WRONG_PHASE` unconditionally --
// `connection.dart:695`, "No turn loop yet: order 008." This file never
// reaches into `lib/` to make one pass; it only sends real JSON over a real
// socket and reads the JSON that comes back.
//
// Three properties this order asked for could not be tested and are marked
// `skip:` below rather than faked, each with the specific reason. All three
// come back to the same root cause, explained in full next to the first one
// (`_captureUnreachable`): `test/support/scripted_random.dart`'s
// `ScriptedRandom` only intercepts `Random.nextInt(32)` (the room-code
// alphabet size). `RoomRegistry._drawBytes`, the one thing standing between
// a test and a chosen die-face sequence, draws every byte -- the chain's
// server secret, a server-assigned seat seed, and `game_id` alike -- with
// `Random.nextInt(256)`, which `ScriptedRandom` does not touch at all: those
// calls always fall through to a real `Random.secure()`. There is no
// documented seam that lets a wire-level test choose or predict a die face,
// and building one would mean encoding the exact order and byte-width of
// every CSPRNG draw `RoomRegistry` happens to make today (room code, two
// seat tokens, the secret, per-seat server seeds, `game_id`) -- undocumented
// implementation detail a blind conformance suite must not depend on.
import 'package:fair_dice/fair_dice.dart' show drawDie, verifyReveal;
import 'package:ludo_server/ludo_server.dart' show Room, RoomState;
import 'package:test/test.dart';

import 'support/wire_harness.dart';

const String _captureUnreachable =
    'needs a real capture, which needs control over which die faces land, '
    'which this suite could not obtain through test/support/scripted_random '
    'as it ships -- see the file header';
const String _threeSixesUnreachable =
    'needs three consecutive sixes forced into one seat\'s rolls, which '
    'needs control over the die faces -- see the file header';
const String _winUnreachable =
    'needs a natural win, which needs control over the die faces for the '
    'whole game, not just one roll -- see the file header';

/// A room's first chain commitment, and every subsequent `reveal`: `s[k]`,
/// 64 lowercase hex characters.
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// One real roll this suite actually observed: the fields `rolled` carries
/// that the chain-verification and no-early-reveal tests need across many
/// rolls, kept as plain values rather than the raw frame so a caller never
/// has to re-parse JSON it already parsed once.
class _RollRecord {
  _RollRecord({required this.k, required this.reveal, required this.value});

  final int k;
  final String reveal;
  final int value;
}

/// What happened after a `moved` frame's follow-up, whichever of the two
/// section 12.2 branches fired: either the game ended (`game_over`, no
/// `turn` follows it) or the room told some seat -- the same one or the
/// next -- that it now holds the turn.
class _AfterMove {
  _AfterMove({this.nextSeat, required this.gameOver});

  final int? nextSeat;
  final bool gameOver;
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

  Future<WireTestClient> connectStray(Uri uri) async {
    final WireTestClient client = await WireTestClient.connect(uri);
    clients.add(client);
    return client;
  }

  /// Sends `start_game` from the host and waits for `game_started` on both
  /// sockets, tolerating any `seat_seed` pushes a correct implementation
  /// interleaves around it (every seat that never called `set_seed` gets a
  /// server-assigned one at this point, section 11.2). Returns the host's
  /// `game_started` payload, which carries `turn` (the seat starting the
  /// game), `game_id` and `client_seeds`.
  Future<Map<String, Object?>> startGame(WireTestLobby lobby) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostFrame = await receiveType(
      lobby.host.client,
      'game_started',
    );
    await receiveType(lobby.guest.client, 'game_started');
    return hostFrame['d']! as Map<String, Object?>;
  }

  WireTestSeat seatFor(WireTestLobby lobby, int seat) =>
      seat == lobby.host.seat ? lobby.host : lobby.guest;

  /// Every helper in this file that sends `roll` or `move` and then reads
  /// the reply is built on this pair of functions rather than on a raw
  /// `client.next()`. The design chosen here, and the reason: section 12.3
  /// puts every message into exactly one of two disjoint cases. Either it
  /// is rejected and answered with a private `error` that reaches only the
  /// sender's own socket (section 5: error carries no `seq` and is not one
  /// of the state-changing pushes), or it is accepted and produces one or
  /// more state-changing pushes, each of which "is broadcast to every
  /// connected socket in the room, including the one that sent the
  /// message that caused it" -- the sender's own copy carries `re`, no
  /// other socket's copy does.
  ///
  /// A fixed reader (always read the log from the host's socket, say) was
  /// tried first and abandoned, because it hangs forever on the `error`
  /// case whenever the guest is the one sending: an error never reaches
  /// the host's socket at all. Reading only from the sender's own socket
  /// and never touching the other one was also tried, and is what caused
  /// twelve failures in a row: every accepted message's broadcast copy on
  /// the *other* socket is left sitting in that socket's queue undrained,
  /// and the moment a helper later reads from that socket -- because the
  /// turn passed to it, or a caller samples it directly with `resume` --
  /// the first thing it sees is that stale backlog, not whatever the
  /// caller actually asked for.
  ///
  /// So the design here is neither of those: read the sender's own socket
  /// first, and only if what came back was not an `error`, also drain the
  /// identical broadcast copy off the other socket in the room, right
  /// here, before returning. That keeps both sockets fully drained after
  /// every helper call, so nothing downstream -- an off-turn seat's error,
  /// a `resume` sampled mid-turn, the next seat's own roll -- can ever
  /// collide with a frame an earlier call left behind.
  Future<void> _drainOtherCopy(
    WireTestLobby lobby,
    int actingSeat,
    Map<String, Object?> mine,
  ) async {
    final WireTestSeat other =
        actingSeat == lobby.host.seat ? lobby.guest : lobby.host;
    final Map<String, Object?> theirs = await other.client.next();
    expect(
      theirs['t'],
      mine['t'],
      reason: 'room ${lobby.code}: a broadcast push must reach every '
          'socket with the same frame type (section 12.3); seat '
          '$actingSeat\'s socket saw "${mine['t']}", the other socket saw '
          '"${theirs['t']}" instead',
    );
    expect(
      theirs['d'],
      mine['d'],
      reason: 'room ${lobby.code}: a broadcast push must reach every '
          'socket with the identical payload (section 12.3); seat '
          '$actingSeat\'s socket saw ${mine['d']}, the other socket saw '
          '${theirs['d']}',
    );
    expect(
      theirs['re'],
      isNull,
      reason: 'room ${lobby.code}: a socket that did not send the message '
          'must never see re on the resulting broadcast (section 12.3); '
          'the other socket saw re=${theirs['re']} on a '
          '"${theirs['t']}" frame',
    );
  }

  /// The next frame that resulted from a message [actingSeat] sent, read
  /// off [actingSeat]'s own socket and, unless it was a private `error`,
  /// also drained (and checked) off the other socket in the room via
  /// [_drainOtherCopy] -- see that function's doc comment for the design
  /// this implements and the reason two other designs were tried first and
  /// abandoned.
  Future<Map<String, Object?>> _next(
    WireTestLobby lobby,
    int actingSeat,
  ) async {
    final Map<String, Object?> mine =
        await seatFor(lobby, actingSeat).client.next();
    if (mine['t'] != 'error') {
      await _drainOtherCopy(lobby, actingSeat, mine);
    }
    return mine;
  }

  /// Sends [type] from whichever socket holds [seat] and returns the reply
  /// via [_next], which is what actually keeps both sockets in the room
  /// drained in lockstep -- see its doc comment for why that matters.
  Future<Map<String, Object?>> _sendAndRead(
    WireTestLobby lobby,
    int seat,
    String type,
    Map<String, Object?> data,
  ) {
    seatFor(lobby, seat).client.send(type, data);
    return _next(lobby, seat);
  }

  /// Sends `resume` on [seat]'s own socket and returns the `room` snapshot
  /// it gets back. Read-only from the protocol's point of view (section 8);
  /// used here purely to sample state -- `turn.k`, `turn.deadline_ms` -- at
  /// a moment of the test's choosing, without disturbing the room's own
  /// broadcast stream the way sending `roll` or `move` would. A caller
  /// that read a `rolled` frame and stopped there, without also draining
  /// whatever `turn_passed`/`turn` a no-legal-move roll queues behind it
  /// (see `consumeNoLegalMove` below), would have this call collide with
  /// that leftover backlog instead of getting a snapshot; every caller
  /// below drains first.
  Future<Map<String, Object?>> resumeSnapshot(
    WireTestLobby lobby,
    WireTestSeat seat,
  ) async {
    seat.client.send('resume', <String, Object?>{
      'code': lobby.code,
      'seat_token': seat.token,
    });
    final Map<String, Object?> frame = await seat.client.next();
    expect(
      frame['t'],
      'room',
      reason: 'resume on room ${lobby.code} for seat ${seat.seat} must '
          'answer with a room snapshot; got "${frame['t']}": ${frame['d']}',
    );
    return frame['d']! as Map<String, Object?>;
  }

  /// Sends `roll` from whichever socket currently holds [seat] and returns
  /// the reply on that same socket, via [_sendAndRead]/[_next], which also
  /// drains the identical broadcast copy off the other socket in the room
  /// so it cannot corrupt a later read on it.
  Future<Map<String, Object?>> sendRoll(WireTestLobby lobby, int seat) async {
    return _sendAndRead(lobby, seat, 'roll', <String, Object?>{});
  }

  Future<Map<String, Object?>> sendMove(
    WireTestLobby lobby,
    int seat,
    Object? token,
  ) async {
    return _sendAndRead(lobby, seat, 'move', <String, Object?>{'token': token});
  }

  /// Reads the two frames a `rolled` with an empty `legal` list produces
  /// (section 12.1): `turn_passed` with `reason: "no_legal_move"`, then
  /// `turn` for whichever seat now holds it. Returns that seat. Reads via
  /// [_next], which also drains and checks the other socket's copy of
  /// each of the two frames, so no backlog is left behind on it.
  Future<int> consumeNoLegalMove(WireTestLobby lobby, int actingSeat) async {
    final Map<String, Object?> passed = await _next(lobby, actingSeat);
    expect(
      passed['t'],
      'turn_passed',
      reason: 'a rolled frame with an empty legal list must be followed by '
          'turn_passed (section 12.1); got "${passed['t']}": ${passed['d']}',
    );
    final Map<String, Object?> passedData =
        passed['d']! as Map<String, Object?>;
    expect(
      passedData['reason'],
      'no_legal_move',
      reason: 'turn_passed following an empty-legal rolled must carry '
          'reason "no_legal_move"; got ${passedData['reason']}',
    );
    final Map<String, Object?> turn = await _next(lobby, actingSeat);
    expect(
      turn['t'],
      'turn',
      reason: 'turn_passed must be followed by turn for the next seat '
          '(section 12.1); got "${turn['t']}": ${turn['d']}',
    );
    return (turn['d']! as Map<String, Object?>)['seat']! as int;
  }

  /// Reads the one frame section 12.2 sends after `moved`: either
  /// `game_over` (game won, no `turn` follows it) or `turn` for whichever
  /// seat -- the same one or the next -- now holds it. Reads via [_next],
  /// which also drains and checks the other socket's copy.
  Future<_AfterMove> consumeAfterMove(
      WireTestLobby lobby, int actingSeat) async {
    final Map<String, Object?> next = await _next(lobby, actingSeat);
    if (next['t'] == 'game_over') {
      return _AfterMove(gameOver: true);
    }
    expect(
      next['t'],
      'turn',
      reason: 'moved must be followed by either game_over or turn (section '
          '12.2); got "${next['t']}": ${next['d']}',
    );
    return _AfterMove(
      nextSeat: (next['d']! as Map<String, Object?>)['seat']! as int,
      gameOver: false,
    );
  }

  /// Rolls for [seat], repeating for whichever seat next holds the turn on
  /// every no-legal-move pass, until a roll leaves at least one legal move
  /// -- or [maxAttempts] rolls happen without one. Returns the `rolled`
  /// payload of the successful roll and the seat that rolled it, leaving
  /// the room in PLAYING/await_move for that seat. Used by every test below
  /// that needs a real `move` to be legal, none of which need a *specific*
  /// legal move, only *a* legal one.
  Future<(int, Map<String, Object?>)> reachLegalRoll(
    WireTestLobby lobby,
    int seat, {
    int maxAttempts = 60,
  }) async {
    int current = seat;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      // Advances the injected FakeClock past docs/PROTOCOL.md section 7's
      // 1-second sliding window for the per-connection message limit (30
      // then RATE_LIMITED, 60 then close, lib/src/rate_limit.dart) before
      // every retry. The clock in this harness never ticks on its own, so
      // without this a retry loop long enough to find an empty legal list
      // several times in a row eventually trips a real, correctly
      // implemented rate limit that has nothing to do with the property
      // this loop is trying to reach.
      harness.clock.advance(const Duration(seconds: 2));
      final Map<String, Object?> frame = await sendRoll(lobby, current);
      expect(
        frame['t'],
        'rolled',
        reason: 'attempt $attempt/$maxAttempts: expected a rolled frame '
            'from seat $current in room ${lobby.code}, got "${frame['t']}": '
            '${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      final List<int> legal = (data['legal']! as List<Object?>).cast<int>();
      if (legal.isNotEmpty) {
        return (current, data);
      }
      current = await consumeNoLegalMove(lobby, current);
    }
    throw TestFailure(
      'no roll left a legal move for any seat in room ${lobby.code} within '
      '$maxAttempts attempts; this suite cannot steer the dice (see the '
      'file header), so this is a real possible outcome of an unlucky run, '
      'not necessarily a defect',
    );
  }

  /// Like [reachLegalRoll], but also retries past any roll whose legal
  /// list already covers every token 0..3 -- a real possible outcome
  /// early in a two-player game, where a six with all four of a seat's
  /// tokens still in the yard makes all four legal at once -- because a
  /// roll like that leaves no well-formed token 0..3 left over to prove
  /// ILLEGAL_MOVE against. A roll like that cannot simply be discarded:
  /// once it has happened the room is in await_move, and a second roll
  /// before a move would itself be rejected by the ladder (WRONG_PHASE),
  /// so it is completed with an arbitrary legal move, exactly as a real
  /// client would, before this tries again for a roll this test can
  /// actually use.
  Future<(int, Map<String, Object?>)> reachPartialLegalRoll(
    WireTestLobby lobby,
    int seat, {
    int maxAttempts = 60,
  }) async {
    int current = seat;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      // See reachLegalRoll's identical comment above: advances the fake
      // clock past the per-connection message rate limit's 1-second
      // window before every retry.
      harness.clock.advance(const Duration(seconds: 2));
      final Map<String, Object?> frame = await sendRoll(lobby, current);
      expect(
        frame['t'],
        'rolled',
        reason: 'attempt $attempt/$maxAttempts: expected a rolled frame '
            'from seat $current in room ${lobby.code}, got "${frame['t']}": '
            '${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      final List<int> legal = (data['legal']! as List<Object?>).cast<int>();
      if (legal.isEmpty) {
        current = await consumeNoLegalMove(lobby, current);
        continue;
      }
      if (legal.length < 4) {
        return (current, data);
      }
      final Map<String, Object?> moved = await sendMove(
        lobby,
        current,
        legal.first,
      );
      expect(
        moved['t'],
        'moved',
        reason: 'expected moved after a legal move, got '
            '"${moved['t']}": ${moved['d']}',
      );
      final _AfterMove after = await consumeAfterMove(lobby, current);
      if (after.gameOver) {
        throw TestFailure(
          'reached game_over while only looking for a roll with a '
          'partial legal list to prove ILLEGAL_MOVE against; unexpected '
          'this early without steering the dice',
        );
      }
      current = after.nextSeat!;
    }
    throw TestFailure(
      'no roll left a legal list that was both non-empty and short of '
      'all four tokens for any seat in room ${lobby.code} within '
      '$maxAttempts attempts; this suite cannot steer the dice (see the '
      'file header), so this is a real possible outcome of an unlucky '
      'run, not necessarily a defect',
    );
  }

  group('roll: the rejection ladder, section 12.1, in order', () {
    test(
        'NO_SUCH_ROOM: a room that has been reaped, even though the '
        'sender was off turn (a lower rung) when it existed', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

      harness.registry.setConnected(
        code: lobby.code,
        seatToken: lobby.host.token,
        connected: false,
      );
      harness.registry.setConnected(
        code: lobby.code,
        seatToken: lobby.guest.token,
        connected: false,
      );
      // A PLAYING room is not evicted by the 10-minute LOBBY-idle rule
      // (section 3: that rule is LOBBY-only); it only reaps under the
      // 60-minute-regardless rule every room gets, so the clock has to
      // move further here than the LOBBY-idle pattern the other test
      // files use.
      harness.clock.advance(const Duration(minutes: 61));
      expect(
        harness.registry.reap(),
        1,
        reason: 'setup requires room ${lobby.code} to actually be reaped',
      );

      final Map<String, Object?> reply = await sendRoll(lobby, offTurn);
      expectErrorFrame(
        reply,
        'NO_SUCH_ROOM',
        because: 'room ${lobby.code} was reaped; seat $offTurn also was not '
            'on turn (seat $onTurn was), which must not surface instead',
      );
    });

    test(
        'BAD_SEAT_TOKEN: a socket that never created, joined or resumed '
        'any room', () async {
      final Uri uri = await start();
      final WireTestClient stray = await connectStray(uri);
      stray.send('roll', <String, Object?>{});
      final Map<String, Object?> reply = await stray.next();
      expectErrorFrame(
        reply,
        'BAD_SEAT_TOKEN',
        because: 'this socket holds no identity in any room at all',
      );
    });

    test(
        'GAME_OVER: a FINISHED room, even from a seat that would '
        'otherwise not be on turn (a lower rung)', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

      // A natural win needs control over the dice this suite does not have
      // (see the file header), so FINISHED is reached the only other way
      // available to a test: the same direct mutation of `Room.state` the
      // turn loop itself is documented to perform once it exists
      // (`room.dart`: "order 008's turn loop does that by mutating
      // Room.game and Room.state directly, the same way it is expected to
      // mutate them for every other in-play change"). This exercises the
      // real wire handler for `roll` against a real, FINISHED `Room`; it
      // never fakes the response itself.
      final Room? room = harness.registry.lookup(lobby.code);
      expect(
        room,
        isNotNull,
        reason: 'room ${lobby.code} must still exist '
            'in the registry for this test to force it FINISHED',
      );
      room!.state = RoomState.finished;

      final Map<String, Object?> reply = await sendRoll(lobby, offTurn);
      expectErrorFrame(
        reply,
        'GAME_OVER',
        because: 'room ${lobby.code} is FINISHED; seat $offTurn also was '
            'not the seat recorded on turn ($onTurn), which must not '
            'surface instead',
      );
    });

    test('WRONG_PHASE: the room is still in LOBBY', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);

      final Map<String, Object?> reply = await sendRoll(lobby, lobby.host.seat);
      expectErrorFrame(
        reply,
        'WRONG_PHASE',
        because: 'room ${lobby.code} has not left LOBBY',
      );
    });

    test(
        'NOT_YOUR_TURN: the sender is seated but it is not their turn, '
        'before anyone has rolled', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

      final Map<String, Object?> reply = await sendRoll(lobby, offTurn);
      expectErrorFrame(
        reply,
        'NOT_YOUR_TURN',
        because: 'seat $onTurn holds the turn in room ${lobby.code}, not '
            'seat $offTurn',
      );
    });

    test(
        'NOT_YOUR_TURN precedes WRONG_PHASE: an off-turn roll while the '
        'on-turn seat is itself in the wrong phase to roll again', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, _) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

      // Room-level turn.phase is now await_move for `onTurn`. An off-turn
      // roll must still answer NOT_YOUR_TURN, not WRONG_PHASE, because the
      // ladder checks whose turn it is before it checks the phase --
      // section 12.1's own worked example.
      final Map<String, Object?> reply = await sendRoll(lobby, offTurn);
      expectErrorFrame(
        reply,
        'NOT_YOUR_TURN',
        because: 'seat $onTurn holds the turn in room ${lobby.code} and is '
            'mid-roll (awaiting a move), which must not surface as '
            'WRONG_PHASE for seat $offTurn instead (section 12.1)',
      );
    });

    test(
        'WRONG_PHASE: the on-turn seat rolls again while a move is '
        'pending', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, _) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );

      final Map<String, Object?> reply = await sendRoll(lobby, onTurn);
      expectErrorFrame(
        reply,
        'WRONG_PHASE',
        because: 'seat $onTurn in room ${lobby.code} already rolled and a '
            'move is pending; a second roll must be rejected',
      );
    });
  });

  group('move: the rejection ladder, section 12.2, in order', () {
    test('NO_SUCH_ROOM: a room that has been reaped', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      await startGame(lobby);

      harness.registry.setConnected(
        code: lobby.code,
        seatToken: lobby.host.token,
        connected: false,
      );
      harness.registry.setConnected(
        code: lobby.code,
        seatToken: lobby.guest.token,
        connected: false,
      );
      // See the comment on the identical setup in the roll ladder's
      // NO_SUCH_ROOM test above: a PLAYING room needs the 60-minute
      // regardless rule, not the 10-minute LOBBY-idle one.
      harness.clock.advance(const Duration(minutes: 61));
      expect(harness.registry.reap(), 1);

      final Map<String, Object?> reply = await sendMove(
        lobby,
        lobby.host.seat,
        0,
      );
      expectErrorFrame(
        reply,
        'NO_SUCH_ROOM',
        because: 'room ${lobby.code} was reaped',
      );
    });

    test(
        'BAD_SEAT_TOKEN: a socket that never created, joined or resumed '
        'any room', () async {
      final Uri uri = await start();
      final WireTestClient stray = await connectStray(uri);
      stray.send('move', <String, Object?>{'token': 0});
      final Map<String, Object?> reply = await stray.next();
      expectErrorFrame(
        reply,
        'BAD_SEAT_TOKEN',
        because: 'this socket holds no identity in any room at all',
      );
    });

    test('GAME_OVER: a FINISHED room', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      final Room? room = harness.registry.lookup(lobby.code);
      expect(room, isNotNull);
      room!.state = RoomState.finished;

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, 0);
      expectErrorFrame(
        reply,
        'GAME_OVER',
        because: 'room ${lobby.code} is FINISHED',
      );
    });

    test('WRONG_PHASE: the room is still in LOBBY', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);

      final Map<String, Object?> reply = await sendMove(
        lobby,
        lobby.host.seat,
        0,
      );
      expectErrorFrame(
        reply,
        'WRONG_PHASE',
        because: 'room ${lobby.code} has not left LOBBY',
      );
    });

    test(
      'NOT_YOUR_TURN: the sender is seated but it is not their turn',
      () async {
        final Uri uri = await start();
        final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
        final Map<String, Object?> started = await startGame(lobby);
        final int onTurn = started['turn']! as int;
        final int offTurn =
            onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

        final Map<String, Object?> reply = await sendMove(lobby, offTurn, 0);
        expectErrorFrame(
          reply,
          'NOT_YOUR_TURN',
          because: 'seat $onTurn holds the turn in room ${lobby.code}',
        );
      },
    );

    test(
        'WRONG_PHASE: a move while the turn is awaiting a roll, not a '
        'move', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, 0);
      expectErrorFrame(
        reply,
        'WRONG_PHASE',
        because: 'seat $onTurn in room ${lobby.code} has not rolled yet '
            'this segment; a move must wait for await_move',
      );
    });

    test(
        'WRONG_PHASE precedes BAD_FIELD: a malformed token sent while '
        'awaiting a roll answers WRONG_PHASE, not BAD_FIELD', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, 'nope');
      expectErrorFrame(
        reply,
        'WRONG_PHASE',
        because: 'seat $onTurn in room ${lobby.code} is awaiting a roll, '
            'which the ladder checks before token shape, even though the '
            'token sent ("nope") is also malformed (section 7: "phase '
            'correct, payload fields, rule legality")',
      );
    });

    test('BAD_FIELD: token is absent', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, _) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );

      seatFor(lobby, onTurn).client.send('move', <String, Object?>{});
      final Map<String, Object?> reply =
          await seatFor(lobby, onTurn).client.next();
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was absent from d entirely',
      );
    });

    test('BAD_FIELD: token is not an integer', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, _) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, 'zero');
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was the JSON string "zero", not an integer',
      );
    });

    test('BAD_FIELD: token is outside 0..3 (below range)', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, _) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, -1);
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was -1, outside 0..3',
      );
    });

    test('BAD_FIELD: token is outside 0..3 (above range)', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, _) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, 4);
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was 4, outside 0..3',
      );
    });

    test(
        'BAD_FIELD precedes ILLEGAL_MOVE: a malformed token is BAD_FIELD '
        'even while a legal move exists to compare it against', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, Map<String, Object?> rolled) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );
      final List<int> legal = (rolled['legal']! as List<Object?>).cast<int>();
      expect(
        legal,
        isNotEmpty,
        reason: 'setup requires a legal move to '
            'exist for this precedence to mean anything',
      );

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, null);
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was JSON null while legal moves $legal existed; a '
            'malformed field must never be evaluated for legality (section '
            '12.2: "checked before legality, because a malformed field is '
            'not an illegal move")',
      );
    });

    test(
        'ILLEGAL_MOVE: a well-formed token that is not in the current '
        'legal list', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, Map<String, Object?> rolled) =
          await reachPartialLegalRoll(
        lobby,
        started['turn']! as int,
      );
      final List<int> legal = (rolled['legal']! as List<Object?>).cast<int>();
      final int illegalToken = <int>[
        0,
        1,
        2,
        3,
      ].firstWhere((int t) => !legal.contains(t));

      final Map<String, Object?> reply = await sendMove(
        lobby,
        onTurn,
        illegalToken,
      );
      expectErrorFrame(
        reply,
        'ILLEGAL_MOVE',
        because: 'token $illegalToken is well-formed but is not in the '
            'legal list $legal for this roll',
      );
    });
  });

  group('the rolled frame, section 5 and 11.2', () {
    test(
        'carries seat, value in 1..6, legal, deadline_ms, k, reveal '
        '(64 lowercase hex) and seq; k is 1 on the first roll', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      final Map<String, Object?> frame = await sendRoll(lobby, onTurn);
      expect(
        frame['t'],
        'rolled',
        reason: 'expected a rolled frame from the first roll of the game '
            'in room ${lobby.code}, got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(data['seat'], onTurn);
      expect(
        data['value'],
        allOf(isA<int>(), inInclusiveRange(1, 6)),
        reason: 'value must be an integer 1..6; got ${data['value']}',
      );
      expect(data['legal'], isA<List<Object?>>());
      expect(
        data['deadline_ms'],
        isA<int>(),
        reason: 'deadline_ms must be present on rolled (section 5)',
      );
      expect(
        data['k'],
        1,
        reason: 'k must be 1 on the first roll of the game (section 11.2); '
            'got ${data['k']}',
      );
      final Object? rawReveal = data['reveal'];
      expect(rawReveal, isA<String>(), reason: 'reveal must be a string');
      final String reveal = rawReveal! as String;
      expect(
        _hex64.hasMatch(reveal),
        isTrue,
        reason: 'reveal must be 64 lowercase hex characters; got "$reveal" '
            '(length ${reveal.length})',
      );
      expect(
        data['seq'],
        isA<int>(),
        reason: 'rolled is on the mandatory '
            '-seq list, section 5',
      );
    });
  });

  group('the moved frame, section 12.2', () {
    test(
        'carries seat, token, from, to, captured (never absent, never '
        'null), extra_roll and seq', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final (int onTurn, Map<String, Object?> rolled) = await reachLegalRoll(
        lobby,
        started['turn']! as int,
      );
      final List<int> legal = (rolled['legal']! as List<Object?>).cast<int>();
      final int token = legal.first;

      final Map<String, Object?> frame = await sendMove(lobby, onTurn, token);
      expect(
        frame['t'],
        'moved',
        reason: 'expected moved after a legal move by seat $onTurn in room '
            '${lobby.code}, got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(data['seat'], onTurn);
      expect(data['token'], token);
      expect(data['from'], isA<int>());
      expect(data['to'], isA<int>());
      expect(
        data.containsKey('captured'),
        isTrue,
        reason: 'captured must never be absent, even with nothing '
            'captured (section 12.2)',
      );
      expect(
        data['captured'],
        isNotNull,
        reason: 'captured must never be null; got null',
      );
      expect(data['captured'], isA<List<Object?>>());
      if ((data['captured']! as List<Object?>).isEmpty) {
        // The overwhelmingly likely branch this early with uncontrolled
        // dice: nothing was on the board to capture yet.
        expect(data['captured'], <Object?>[]);
      }
      expect(data['extra_roll'], isA<bool>());
      expect(data['seq'], isA<int>());
    });

    test(
      'a real capture produces a real {seat, token} entry in captured',
      () {},
      skip: _captureUnreachable,
    );
  });

  group('the rejected roll advances nothing, section 12.1', () {
    test(
        'turn.k is unchanged across a rejected roll, and the next '
        'accepted roll carries the k it would have had', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;

      final Map<String, Object?> before = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      final int kBefore = _turnInt(
          _turnObject(before, 'before the rejected roll'),
          'k',
          'before the rejected roll');
      expect(
        kBefore,
        0,
        reason: 'turn.k must be 0 before the first roll of '
            'a fresh game (section 6)',
      );

      final Map<String, Object?> rejected = await sendRoll(lobby, offTurn);
      expectErrorFrame(
        rejected,
        'NOT_YOUR_TURN',
        because: 'setup requires this roll to actually be rejected by the '
            'ladder for the property below to mean anything',
      );

      final Map<String, Object?> after = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      final int kAfter = _turnInt(_turnObject(after, 'after the rejected roll'),
          'k', 'after the rejected roll');
      expect(
        kAfter,
        kBefore,
        reason: 'a roll rejected by the ladder must advance nothing '
            '(section 12.1: "the counter, the chain and the engine are '
            'all untouched"); turn.k was $kBefore before the rejected '
            'roll and $kAfter after it',
      );

      final Map<String, Object?> accepted = await sendRoll(lobby, onTurn);
      expect(
        accepted['t'],
        'rolled',
        reason: 'expected the accepted roll from seat $onTurn to succeed '
            'in room ${lobby.code}, got "${accepted['t']}": '
            '${accepted['d']}',
      );
      final Map<String, Object?> acceptedData =
          accepted['d']! as Map<String, Object?>;
      expect(
        acceptedData['k'],
        kBefore + 1,
        reason: 'the next accepted roll must carry the k it would have '
            'had absent the rejection ($kBefore + 1); got '
            '${acceptedData['k']}',
      );
    });
  });

  group('turn.k in the room snapshot, section 6', () {
    test(
        '0 after game_started and before the first roll; equal to the '
        'last rolled k after a roll; a resuming client reads the same '
        'value the frames implied', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      final Map<String, Object?> beforeRoll = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      expect(
        _turnObject(beforeRoll, 'before the first roll')['k'],
        0,
        reason: 'turn.k must be 0 from game_started until the first roll '
            '(section 6)',
      );

      final Map<String, Object?> rolled = await sendRoll(lobby, onTurn);
      expect(
        rolled['t'],
        'rolled',
        reason: 'expected rolled from seat $onTurn in room ${lobby.code}, '
            'got "${rolled['t']}": ${rolled['d']}',
      );
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      final int k = rolledData['k']! as int;
      final List<int> legal =
          (rolledData['legal']! as List<Object?>).cast<int>();
      if (legal.isEmpty) {
        // A rolled with an empty legal list queues turn_passed then turn
        // behind it on both sockets (section 12.1). resumeSnapshot below
        // expects the very next frame on each socket to be the room
        // snapshot resume itself produces, so that backlog has to be
        // drained to a known state first, or resume collides with the
        // stale turn_passed instead of answering with a snapshot.
        await consumeNoLegalMove(lobby, onTurn);
      }

      final Map<String, Object?> afterRoll = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      final Map<String, Object?> afterRoot =
          _turnObject(afterRoll, 'after a roll');
      expect(
        afterRoot['k'],
        k,
        reason: 'turn.k after a roll must equal the last rolled frame\'s '
            'own k ($k); host snapshot had ${afterRoot['k']}',
      );

      final Map<String, Object?> guestResume = await resumeSnapshot(
        lobby,
        lobby.guest,
      );
      expect(
        _turnObject(guestResume, 'guest resuming mid-game')['k'],
        k,
        reason: 'a different client resuming mid-game must read the same '
            'turn.k ($k) the frames already implied',
      );
    });
  });

  group('deadline_ms, section 6 and 12.3', () {
    test(
        'present, an integer, bounded by 0 and turn_seconds * 1000, '
        'restarts when a seat\'s turn begins, decays deterministically on '
        'the injected clock, and floors at zero', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(
        uri,
        clients,
        rules: <String, Object?>{'turn_seconds': 20},
      );
      await startGame(lobby);
      const int fullMs = 20 * 1000;

      final Map<String, Object?> fresh = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      final Map<String, Object?> freshTurn =
          _turnObject(fresh, 'a fresh turn, no roll yet');
      expect(
        freshTurn['deadline_ms'],
        isA<int>(),
        reason: 'deadline_ms must be present on the turn object',
      );
      expect(
        freshTurn['deadline_ms'],
        fullMs,
        reason: 'a seat\'s turn beginning must restart the segment to the '
            'full window ($fullMs ms); got ${freshTurn['deadline_ms']} '
            'with no time having passed on the injected clock yet',
      );

      harness.clock.advance(const Duration(seconds: 7));
      final Map<String, Object?> decayed = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      final int decayedMs = _turnInt(
          _turnObject(decayed, 'after advancing the clock 7000ms'),
          'deadline_ms',
          'after advancing the clock 7000ms');
      expect(
        decayedMs,
        fullMs - 7000,
        reason: 'deadline_ms must be max(0, turn_seconds * 1000 - elapsed) '
            'on the server\'s injected clock (section 6); expected '
            '${fullMs - 7000} after advancing the fake clock by exactly '
            '7000ms with nothing else happening, got $decayedMs',
      );
      expect(
        decayedMs,
        inInclusiveRange(0, fullMs),
        reason: 'deadline_ms must never leave 0..$fullMs',
      );

      harness.clock.advance(const Duration(seconds: 30));
      final Map<String, Object?> floored = await resumeSnapshot(
        lobby,
        lobby.host,
      );
      expect(
        _turnObject(
            floored, 'after advancing well past turn_seconds')['deadline_ms'],
        0,
        reason: 'deadline_ms must clamp to 0, never go negative, once '
            'elapsed exceeds turn_seconds * 1000',
      );
    });

    test(
        'restarts to the full window when a rolled frame leaves a legal '
        'move pending, even after the segment had already decayed', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(
        uri,
        clients,
        rules: <String, Object?>{'turn_seconds': 30},
      );
      final Map<String, Object?> started = await startGame(lobby);
      const int fullMs = 30 * 1000;

      int current = started['turn']! as int;
      Map<String, Object?>? rolled;
      const int maxAttempts = 60;
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        // Decay the segment before every attempt, so whichever attempt
        // finally leaves a legal move pending has genuinely decayed
        // first -- this is not merely "the clock never moved so it was
        // trivially still full".
        harness.clock.advance(const Duration(seconds: 5));
        final Map<String, Object?> frame = await sendRoll(lobby, current);
        expect(
          frame['t'],
          'rolled',
          reason: 'attempt $attempt/$maxAttempts: expected rolled from '
              'seat $current in room ${lobby.code}, got "${frame['t']}": '
              '${frame['d']}',
        );
        final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
        final List<int> legal = (data['legal']! as List<Object?>).cast<int>();
        if (legal.isNotEmpty) {
          rolled = data;
          break;
        }
        current = await consumeNoLegalMove(lobby, current);
      }
      expect(
        rolled,
        isNotNull,
        reason: 'no roll left a legal move within $maxAttempts attempts; '
            'this suite cannot steer the dice (see the file header)',
      );
      expect(
        rolled!['deadline_ms'],
        fullMs,
        reason: 'a rolled frame that leaves a legal move pending must '
            'restart the segment to the full window ($fullMs ms), even '
            'though this segment had decayed first; got '
            '${rolled['deadline_ms']}',
      );
    });

    test(
      'restarts to the full window when an extra roll is granted',
      () {},
      skip: 'needs a roll that grants an extra roll (a six or a '
          'capture), which needs control over the die faces -- see the '
          'file header',
    );
  });

  group('no reveal arrives early, section 11.3', () {
    test(
        'no frame of any type carries a reveal for a roll number greater '
        'than the number of rolled frames already received', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);

      int current = started['turn']! as int;
      int rolledSeen = 0;
      const int totalRolls = 5;
      for (int i = 0; i < totalRolls; i++) {
        final Map<String, Object?> frame = await sendRoll(lobby, current);
        expect(
          frame['t'],
          'rolled',
          reason: 'roll ${i + 1}/$totalRolls: expected rolled from seat '
              '$current in room ${lobby.code}, got "${frame['t']}": '
              '${frame['d']}',
        );
        rolledSeen++;
        final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
        expect(
          data['k'],
          rolledSeen,
          reason: 'rolled frame ${rolledSeen} must carry k == $rolledSeen',
        );
        final List<int> legal = (data['legal']! as List<Object?>).cast<int>();
        if (legal.isEmpty) {
          // Read via _next, not a raw client.next(): both frames are
          // broadcast to every socket in the room (section 12.3), so the
          // other socket's copy of each has to be drained here too, or it
          // sits in that socket's queue and corrupts a later read on it.
          final Map<String, Object?> passed = await _next(lobby, current);
          _assertNoEarlyReveal(passed, rolledSeen);
          final Map<String, Object?> turn = await _next(lobby, current);
          _assertNoEarlyReveal(turn, rolledSeen);
          current = (turn['d']! as Map<String, Object?>)['seat']! as int;
        } else {
          final int token = legal.first;
          final Map<String, Object?> moved = await sendMove(
            lobby,
            current,
            token,
          );
          expect(
            moved['t'],
            'moved',
            reason: 'expected moved after a legal move, got '
                '"${moved['t']}": ${moved['d']}',
          );
          _assertNoEarlyReveal(moved, rolledSeen);
          final Map<String, Object?> after = await _next(lobby, current);
          _assertNoEarlyReveal(after, rolledSeen);
          if (after['t'] == 'game_over') {
            break;
          }
          current = (after['d']! as Map<String, Object?>)['seat']! as int;
        }
      }
    });
  });

  group(
      'the hash chain and every rolled value verify end to end, section '
      '11.1 and 11.2 -- "the most valuable test in this file"', () {
    test(
        'SHA-256(reveal_1) == chain_commit; SHA-256(reveal_k) == '
        'reveal_{k-1}; every value == drawDie(reveal, game_id, '
        'client_seeds, k, 0), recomputed independently', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final String chainCommit = lobby.hostRoom['chain_commit']! as String;
      final String gameId = started['game_id']! as String;
      final String clientSeeds = started['client_seeds']! as String;

      final List<_RollRecord> records = <_RollRecord>[];
      int current = started['turn']! as int;
      const int wanted = 5;
      const int maxAttempts = 30;
      for (int attempt = 1;
          attempt <= maxAttempts && records.length < wanted;
          attempt++) {
        // Advances the fake clock past the per-connection message rate
        // limit's 1-second window before every attempt -- see
        // reachLegalRoll's identical comment for why.
        harness.clock.advance(const Duration(seconds: 2));
        final Map<String, Object?> frame = await sendRoll(lobby, current);
        expect(
          frame['t'],
          'rolled',
          reason: 'attempt $attempt: expected rolled from seat $current in '
              'room ${lobby.code}, got "${frame['t']}": ${frame['d']} '
              '(this is the expected failure mode while roll is '
              'unimplemented: WRONG_PHASE unconditionally, '
              'connection.dart:695)',
        );
        final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
        records.add(
          _RollRecord(
            k: data['k']! as int,
            reveal: data['reveal']! as String,
            value: data['value']! as int,
          ),
        );
        final List<int> legal = (data['legal']! as List<Object?>).cast<int>();
        if (legal.isEmpty) {
          current = await consumeNoLegalMove(lobby, current);
        } else {
          final Map<String, Object?> moved = await sendMove(
            lobby,
            current,
            legal.first,
          );
          expect(
            moved['t'],
            'moved',
            reason: 'expected moved, got '
                '"${moved['t']}": ${moved['d']}',
          );
          final _AfterMove after = await consumeAfterMove(lobby, current);
          if (after.gameOver) {
            break;
          }
          current = after.nextSeat!;
        }
      }

      expect(
        records.length,
        greaterThanOrEqualTo(2),
        reason: 'need at least 2 real rolls to prove a chain link end to '
            'end; only collected ${records.length} in room ${lobby.code}',
      );

      for (int i = 0; i < records.length; i++) {
        expect(
          records[i].k,
          i + 1,
          reason: 'roll #${i + 1} carried k=${records[i].k}, expected '
              '${i + 1} (k is 1-based and increments by exactly one per '
              'roll, section 11.2)',
        );
      }

      expect(
        verifyReveal(reveal: records[0].reveal, parent: chainCommit),
        isTrue,
        reason: 'SHA-256(reveal of roll 1, "${records[0].reveal}") must '
            'equal chain_commit ("$chainCommit") published in room at '
            'creation (section 11.1)',
      );
      for (int i = 1; i < records.length; i++) {
        expect(
          verifyReveal(
            reveal: records[i].reveal,
            parent: records[i - 1].reveal,
          ),
          isTrue,
          reason: 'SHA-256(reveal of roll ${i + 1}, "${records[i].reveal}") '
              'must equal the reveal of roll $i '
              '("${records[i - 1].reveal}")',
        );
      }

      for (final _RollRecord r in records) {
        final int expectedValue = drawDie(
          r.reveal,
          gameId,
          clientSeeds,
          r.k,
          0,
        );
        expect(
          r.value,
          expectedValue,
          reason: 'rolled k=${r.k} carried value ${r.value} but '
              'drawDie(reveal, game_id, client_seeds, ${r.k}, 0) '
              'recomputes $expectedValue independently from '
              'packages/fair_dice (sections 11.2 and 12.1); game_id='
              '"$gameId" client_seeds="$clientSeeds"',
        );
      }
    });
  });

  group('seq, section 12.3', () {
    test(
        'every frame carries seq, the counter advances by exactly one '
        'per frame, three consecutive values from one no-legal-move '
        'roll, and the sender\'s own copy carries re where the other '
        'socket\'s copy does not', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      // A `roll` whose value leaves no legal move is the only single wire
      // message this section documents producing exactly three broadcast
      // pushes back to back (rolled, turn_passed, turn -- section 12.1).
      // A `move` never produces three: section 12.2's own if/else-if/else
      // always fires exactly one of {game_over, turn} after `moved`, so a
      // `move` produces two pushes, never three. Both are exercised below;
      // see this file's final report for the ambiguity this resolves.
      int attempts = 0;
      const int maxAttempts = 60;
      int current = onTurn;
      List<Map<String, Object?>>? triple;
      WireTestSeat? other;
      while (attempts < maxAttempts) {
        attempts++;
        // Advances the fake clock past the per-connection message rate
        // limit's 1-second window before every attempt -- see
        // reachLegalRoll's identical comment for why.
        harness.clock.advance(const Duration(seconds: 2));
        final String rollId =
            seatFor(lobby, current).client.send('roll', <String, Object?>{});
        // Read raw here, deliberately not via _next: until legal is known
        // below, this attempt might turn out to be the no-legal-move
        // triple this test inspects both sockets of directly (the other
        // socket's copies are read explicitly, further down, precisely so
        // this test can assert re is absent from them itself). Only once
        // an attempt is known to be discarded (the legal-move branch
        // below) does the other socket's copy of it get drained here
        // instead, so a discarded attempt cannot leave a backlog behind.
        final Map<String, Object?> rolled =
            await seatFor(lobby, current).client.next();
        expect(
          rolled['t'],
          'rolled',
          reason: 'attempt $attempts: expected rolled, got '
              '"${rolled['t']}": ${rolled['d']}',
        );
        final List<int> legal =
            ((rolled['d']! as Map<String, Object?>)['legal']! as List<Object?>)
                .cast<int>();
        if (legal.isEmpty) {
          final Map<String, Object?> passed =
              await seatFor(lobby, current).client.next();
          final Map<String, Object?> turn =
              await seatFor(lobby, current).client.next();
          triple = <Map<String, Object?>>[rolled, passed, turn];

          final int rollingSeat = current;
          // rolled was read off rollingSeat's own socket, which is always
          // the sender's own copy regardless of whether rollingSeat is
          // the host or the guest seat, so re must always equal rollId
          // here (section 12.3: the sender's own copy carries re).
          expect(
            rolled['re'],
            rollId,
            reason: 'the sender\'s own copy of rolled must carry re '
                '($rollId); got ${rolled['re']}',
          );
          other = rollingSeat == lobby.host.seat ? lobby.guest : lobby.host;

          current = (turn['d']! as Map<String, Object?>)['seat']! as int;
          break;
        }
        // This attempt left a legal move pending instead; it is
        // discarded. rolled was read raw above without draining the other
        // socket's copy (because until legal was known this attempt
        // might have been the target), so that copy has to be drained
        // here now that the attempt is known not to be it.
        await _drainOtherCopy(lobby, current, rolled);

        final String moveId = seatFor(
          lobby,
          current,
        ).client.send('move', <String, Object?>{'token': legal.first});
        final Map<String, Object?> moved = await _next(lobby, current);
        expect(
          moved['t'],
          'moved',
          reason: 'expected moved, got '
              '"${moved['t']}": ${moved['d']}',
        );
        final _AfterMove after = await consumeAfterMove(lobby, current);
        if (after.gameOver) {
          throw TestFailure(
            'reached game_over while only looking for a '
            'no-legal-move roll to test the 3-consecutive-seq case; '
            'unexpected this early without steering the dice',
          );
        }
        current = after.nextSeat!;
        // rollId/moveId are only used above to correlate re; nothing more
        // to do with them here.
        expect(moveId, isNotEmpty);
      }
      expect(
        triple,
        isNotNull,
        reason: 'no roll left an empty legal list within $maxAttempts '
            'attempts; this suite cannot steer the dice (see the file '
            'header)',
      );

      final List<int> seqs = triple!
          .map(
            (Map<String, Object?> f) =>
                (f['d']! as Map<String, Object?>)['seq']! as int,
          )
          .toList();
      expect(
        seqs,
        <int>[seqs[0], seqs[0] + 1, seqs[0] + 2],
        reason: 'rolled, turn_passed and turn from one no-legal-move roll '
            'must carry three consecutive seq values; got $seqs',
      );

      // Broadcast reach: the other socket must have received the same
      // rolled/turn_passed/turn sequence, without re.
      final Map<String, Object?> otherRolled = await other!.client.next();
      final Map<String, Object?> otherPassed = await other.client.next();
      final Map<String, Object?> otherTurn = await other.client.next();
      for (final Map<String, Object?> f in <Map<String, Object?>>[
        otherRolled,
        otherPassed,
        otherTurn,
      ]) {
        expect(
          f['re'],
          isNull,
          reason: 'the socket that did not send roll must see no re on '
              'any of the three pushes it caused; got ${f['re']} on a '
              '"${f['t']}" frame',
        );
      }
      expect(
        <int>[
          (otherRolled['d']! as Map<String, Object?>)['seq']! as int,
          (otherPassed['d']! as Map<String, Object?>)['seq']! as int,
          (otherTurn['d']! as Map<String, Object?>)['seq']! as int,
        ],
        seqs,
        reason: 'the other socket must see the identical seq values the '
            'sender\'s socket saw for the same three frames',
      );
    });
  });

  group('turn_passed, section 12.1', () {
    test(
        'a roll with no legal move produces rolled first (still carrying '
        'its reveal), then turn_passed with reason no_legal_move, then '
        'turn for the next seat', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);

      int current = started['turn']! as int;
      const int maxAttempts = 40;
      bool found = false;
      for (int attempt = 1; attempt <= maxAttempts && !found; attempt++) {
        // Advances the fake clock past the per-connection message rate
        // limit's 1-second window before every attempt -- see
        // reachLegalRoll's identical comment for why.
        harness.clock.advance(const Duration(seconds: 2));
        final Map<String, Object?> rolled = await sendRoll(lobby, current);
        expect(
          rolled['t'],
          'rolled',
          reason: 'attempt $attempt/$maxAttempts: expected rolled from '
              'seat $current in room ${lobby.code}, got "${rolled['t']}": '
              '${rolled['d']}',
        );
        final Map<String, Object?> rolledData =
            rolled['d']! as Map<String, Object?>;
        final Object? reveal = rolledData['reveal'];
        expect(
          reveal,
          isA<String>(),
          reason: 'the rolled frame preceding a turn_passed must still '
              'carry its reveal (section 12.1: "the roll happened, and a '
              'roll that is not published is a hole in the chain")',
        );
        expect(_hex64.hasMatch(reveal! as String), isTrue);

        final List<int> legal =
            (rolledData['legal']! as List<Object?>).cast<int>();
        if (legal.isEmpty) {
          found = true;
          // Read via _next: both frames are broadcast to every socket in
          // the room (section 12.3), so the other socket's copy of each
          // is drained (and checked) here too, consistent with every
          // other read in this file.
          final Map<String, Object?> passed = await _next(lobby, current);
          expect(
            passed['t'],
            'turn_passed',
            reason: 'expected '
                'turn_passed immediately after the empty-legal rolled, got '
                '"${passed['t']}": ${passed['d']}',
          );
          expect(
            (passed['d']! as Map<String, Object?>)['reason'],
            'no_legal_move',
          );
          final Map<String, Object?> turn = await _next(lobby, current);
          expect(
            turn['t'],
            'turn',
            reason: 'expected turn for the next '
                'seat immediately after turn_passed, got "${turn['t']}": '
                '${turn['d']}',
          );
          expect(
            (turn['d']! as Map<String, Object?>)['seat'],
            isNot(current),
            reason: 'turn must move to a different seat after '
                'no_legal_move',
          );
        } else {
          final Map<String, Object?> moved = await sendMove(
            lobby,
            current,
            legal.first,
          );
          expect(moved['t'], 'moved');
          final _AfterMove after = await consumeAfterMove(lobby, current);
          if (after.gameOver) {
            throw TestFailure(
              'reached game_over while only looking for '
              'a no-legal-move roll; unexpected this early without '
              'steering the dice',
            );
          }
          current = after.nextSeat!;
        }
      }
      expect(
        found,
        isTrue,
        reason: 'no roll left an empty legal list within $maxAttempts '
            'attempts across both seats in room ${lobby.code}; this suite '
            'cannot steer the dice (see the file header)',
      );
    });

    test(
      'turn_passed with reason three_sixes after a third consecutive '
      'six',
      () {},
      skip: _threeSixesUnreachable,
    );
  });

  group('game_over, section 5, 11.2 and 12.2', () {
    test(
        'every action against a FINISHED room (roll, move) answers '
        'GAME_OVER, forced via direct Room.state mutation since this '
        'suite cannot reach a natural win', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;

      final Room? room = harness.registry.lookup(lobby.code);
      expect(room, isNotNull);
      room!.state = RoomState.finished;

      final Map<String, Object?> rollReply = await sendRoll(lobby, onTurn);
      expectErrorFrame(
        rollReply,
        'GAME_OVER',
        because: 'room ${lobby.code} is FINISHED',
      );

      final Map<String, Object?> moveReply = await sendMove(lobby, onTurn, 0);
      expectErrorFrame(
        moveReply,
        'GAME_OVER',
        because: 'room ${lobby.code} is FINISHED',
      );
    });

    test(
      'carries winner and verify_url == https://provefair.app/v/'
      '<game_id>, and no seed field',
      () {},
      skip: _winUnreachable,
    );

    test(
      'a game_over is never followed by a turn',
      () {},
      skip: _winUnreachable,
    );
  });
}

/// The `turn` object of a room snapshot, asserted present and shaped as a
/// map before a caller reads a field off it -- a clean `expect()` failure
/// naming what was missing, rather than a raw null-check crash, when
/// `turn` is absent (which it is today: the turn loop this section
/// describes is order 008's, not yet wired into the snapshot at all).
Map<String, Object?> _turnObject(
    Map<String, Object?> snapshot, String context) {
  final Object? turn = snapshot['turn'];
  expect(
    turn,
    isA<Map<String, Object?>>(),
    reason: 'expected a turn object in the room snapshot ($context); got '
        '${turn.runtimeType}: $turn',
  );
  return turn! as Map<String, Object?>;
}

/// A required integer field of a `turn` object already fetched via
/// [_turnObject], asserted present as an int before a caller reads it, for
/// the same reason [_turnObject] itself checks first.
int _turnInt(Map<String, Object?> turn, String field, String context) {
  final Object? value = turn[field];
  expect(
    value,
    isA<int>(),
    reason: 'expected turn.$field to be an integer ($context); got '
        '${value.runtimeType}: $value',
  );
  return value! as int;
}

void _assertNoEarlyReveal(Map<String, Object?> frame, int rolledSoFar) {
  final Object? d = frame['d'];
  if (d is! Map<String, Object?>) {
    return;
  }
  if (frame['t'] == 'rolled') {
    // A rolled frame's own reveal is for the roll it announces, which by
    // construction of the calling loop is exactly rolledSoFar -- covered
    // by the k == rolledSoFar assertion the caller already made.
    return;
  }
  expect(
    d.containsKey('reveal'),
    isFalse,
    reason: 'only a rolled frame may carry reveal; a "${frame['t']}" frame '
        'carried one after $rolledSoFar rolled frames had been received: '
        '${d['reveal']}',
  );
}
