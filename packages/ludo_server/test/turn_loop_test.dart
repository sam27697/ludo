// Conformance tests for `docs/PROTOCOL.md` section 12, the turn loop, read
// together with sections 4, 5, 6, 7 and 11.2. Written from those sections
// only, against a real, running `WireServer`, the same way
// `fairness_lobby_test.dart` covers section 11's lobby half.
//
// Order 055 folds in order 052's seam: `test/support/scripted_bytes.dart`'s
// `ScriptedBytesRandom` and `test/support/dice_oracle.dart`'s
// `findSecretForFaces` let a wire-level test choose the exact die-face
// sequence a room produces, at the one-time cost of an offline search whose
// size is roughly `6^(faces wanted)` -- `test/dice_steering_test.dart` is
// the proof this works and this file only calls it, never edits it. That
// closes two of the three skips this file used to carry outright: a non-six
// on the first roll of a fresh game and three consecutive sixes are one-
// and three-face searches. It also turns the retry loop this file used to
// run -- up to 60 real, unsteered rolls hoping one would leave an empty
// `legal` list -- from a coin flip into the same one-face search; that loop
// is gone. The third kind of skip, a real capture and a real win, is not
// closed: each is a real, measured number of faces, named next to its own
// `skip:` below, past which `6^n` is not a search this suite can run in its
// own lifetime. `test/support/scripted_random.dart` -- the room-code-only
// seam an earlier draft of this file blamed for all three -- is untouched
// and unused by anything below; it was never the seam this file needed.
import 'package:fair_dice/fair_dice.dart' show drawDie, hexEncode, verifyReveal;
import 'package:ludo_engine/ludo_engine.dart' show GameState, TurnEndReason;
import 'package:ludo_server/ludo_server.dart' show Room, RoomState;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

const String _captureUnreachable =
    'needs a real capture; the shortest sequence found for a 2-seat room is '
    '8 rolls -- the capturing seat spends its own first turn reaching '
    'progress 11 (faces 6, 6, 5), the victim seat then leaves the yard and '
    'stops one square past its own entry, the smallest square that is not '
    'itself safe (faces 6, 1), and the capturing seat closes the remaining '
    '16 and lands on it (faces 6, 6, 4). 6^8 is nearly 1.7 million '
    'candidates, and test/support/dice_oracle.dart walks its full '
    '4096-link chain for every one of them regardless of how few faces are '
    'wanted -- on the order of 6.9 billion hashes, not a search this suite '
    'can run';
const String _winUnreachable =
    'needs a natural win: one seat\'s 4 tokens need 4*57=228 total progress '
    'plus their 4 individual yard exits, and docs/RULES.md rule 10 still '
    'caps every run of sixes at 2 before a forced break and a hand-off to '
    'the other seat, the same pattern the three-sixes test in this file '
    'exercises -- so even a best-case run is on the order of 60 or more '
    'rolls, putting the search at 6^60 or beyond, a number with no useful '
    'relationship to the 6^8 the capture case above already found too '
    'large to run';

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
  /// server-assigned one at this point, section 11.2). Also consumes the
  /// standalone `turn` frame section 13.1 requires immediately after
  /// `game_started`, on both sockets, via [expectOpeningTurn] -- otherwise
  /// it sits in each socket's queue and is mistaken for whatever the next
  /// helper actually asked for. Returns the host's `game_started` payload,
  /// which carries `turn` (the seat starting the game), `game_id` and
  /// `client_seeds`.
  Future<Map<String, Object?>> startGame(WireTestLobby lobby) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostFrame = await receiveType(
      lobby.host.client,
      'game_started',
    );
    final Map<String, Object?> hostFrameData =
        hostFrame['d']! as Map<String, Object?>;
    final Object? startingSeat = hostFrameData['turn'];
    await expectOpeningTurn(lobby.host.client, startingSeat);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startingSeat);
    return hostFrameData;
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
  /// (section 12.1): `turn_passed`, then `turn` for whichever seat now
  /// holds it. Returns that seat. Section 12.1 gives `turn_passed` two
  /// disjoint reasons, both of which leave `legal` empty on the `rolled`
  /// that preceded them -- "no_legal_move" (the engine had nothing to
  /// move) and "three_sixes" (the turn ended on a third consecutive six,
  /// which forfeits the turn regardless of what would otherwise have been
  /// legal) -- so a generic "bounce past whatever ended this turn without
  /// a move" helper used across many tests must accept either; a test
  /// that specifically needs the no_legal_move reason (see the
  /// `turn_passed` group below) checks it itself rather than relying on
  /// this one to. Reads via [_next], which also drains and checks the
  /// other socket's copy of each of the two frames, so no backlog is left
  /// behind on it.
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
      anyOf('no_legal_move', 'three_sixes'),
      reason: 'turn_passed following an empty-legal rolled must carry '
          'reason "no_legal_move" or "three_sixes" (section 12.1); got '
          '${passedData['reason']}',
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

  // -----------------------------------------------------------------------
  // Order 055's steering seam: order 052's dice-steering seam, applied to
  // this file's own tests rather than proved in the abstract the way
  // test/dice_steering_test.dart proves it. Every steered test below uses
  // the same two client seeds, so client_seeds -- and therefore which
  // secret findSecretForFaces has to search for -- is known before a
  // single frame is sent.
  // -----------------------------------------------------------------------
  const String hostSteerSeed = 'turn-loop-host-seed';
  const String guestSteerSeed = 'turn-loop-guest-seed';
  const String steerClientSeeds = '0:$hostSteerSeed|2:$guestSteerSeed';

  /// The `game_id` any steered room below will report, computed offline
  /// exactly as test/dice_steering_test.dart does: buildScript's
  /// filler-byte formula at the game_id offset does not depend on the
  /// secret spliced in ahead of it, so this is fixed before
  /// findSecretForFaces has even chosen one.
  String predictedGameId() {
    final List<int> probe =
        buildScript(secret: List<int>.filled(serverSecretDraws, 0));
    return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
  }

  /// Builds a fresh 2-seat room whose die faces are steered to [wanted] for
  /// `k = 1..wanted.length` (test/support/dice_oracle.dart's
  /// `findSecretForFaces`, searched before a single frame is sent), joins a
  /// guest, fixes both seats' seeds so `client_seeds` matches
  /// [steerClientSeeds], and starts the game. Reassigns the outer
  /// `harness` so setUp's default, never-started harness is replaced
  /// before anything talks to the network; `tearDown` closes whichever
  /// harness that variable holds at the end of a test, so nothing this
  /// leaves behind leaks. Returns the lobby and the `game_started` payload.
  Future<(WireTestLobby, Map<String, Object?>)> buildSteeredLobby(
    List<int> wanted, {
    Map<String, Object?> rules = const <String, Object?>{},
  }) async {
    final String gameId = predictedGameId();
    final SteeredSecret steered = findSecretForFaces(
      wanted: wanted,
      gameId: gameId,
      clientSeeds: steerClientSeeds,
    );
    harness = ServerHarness.build(
      secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
    );
    final Uri uri = await start();
    final WireTestLobby lobby =
        await buildWireTestLobby(uri, clients, players: 2, rules: rules);
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      <int>[0, 2],
      reason: 'this steering helper assumes the fixed 2-player seat '
          'mapping (host=0, guest=2, lib/src/registry.dart:967-978) so it '
          'can predict client_seeds before the room exists; got host='
          '${lobby.host.seat} guest=${lobby.guest.seat}. If this ever '
          'fails, the mapping changed and steerClientSeeds needs to change '
          'with it -- it is not a flake.',
    );

    lobby.host.client
        .send('set_seed', <String, Object?>{'client_seed': hostSteerSeed});
    await receiveType(lobby.host.client, 'seat_seed');
    lobby.guest.client
        .send('set_seed', <String, Object?>{'client_seed': guestSteerSeed});
    await receiveType(lobby.guest.client, 'seat_seed');

    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    // Section 13.1: a standalone turn immediately follows game_started, on
    // every socket in the room; consumed and asserted here so nothing
    // downstream mistakes it for the frame it actually asked for.
    await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);

    expect(
      startedData['game_id'],
      gameId,
      reason: 'predicted game_id (computed offline from buildScript\'s '
          'filler bytes) did not match game_started.game_id off the wire; '
          'the draw-order picture in scripted_bytes.dart no longer '
          'matches registry.dart',
    );
    expect(
      startedData['client_seeds'],
      steerClientSeeds,
      reason: 'predicted client_seeds did not match game_started.'
          'client_seeds off the wire',
    );

    return (lobby, startedData);
  }

  /// The fixed 2-player seat mapping every steered helper below assumes
  /// (host=0, guest=2, lib/src/registry.dart:967-978), spelled out once so
  /// `test/support/engine_search.dart`'s offline search runs over exactly
  /// the seats the wire-level room it steers will actually use.
  const List<int> steeredSeats = <int>[0, 2];

  /// Sends [faces] one roll at a time on the socket currently holding the
  /// turn, steering each through [buildSteeredLobby] first so every value
  /// is fixed before a single frame is sent. Every roll except the last is
  /// driven all the way through: if it leaves a legal move, the move sent
  /// is `legal.first` -- rule 15's own definition of "the first legal
  /// move", and the exact policy `test/support/engine_search.dart`'s
  /// search assumed when it found [faces] in the first place, so replaying
  /// it here is required, not a convenience -- and whatever follows
  /// (`turn_passed`+`turn`, or `moved`+`turn`) is drained via the readers
  /// already in this file. The last face's own `roll` is sent and its
  /// `rolled` frame returned untouched, without a move: that is the one
  /// roll a caller actually wanted to observe, and every earlier face in
  /// [faces] only existed to reach the state it is rolled from.
  ///
  /// [beforeFinalRoll], if given, runs immediately before that last `roll`
  /// is sent -- the seam a caller uses to advance the injected clock partway
  /// through a steered sequence without disturbing which face any roll
  /// produces.
  Future<(WireTestLobby, int, Map<String, Object?>)> driveToSteeredRoll(
    List<int> faces, {
    Map<String, Object?> rules = const <String, Object?>{},
    Future<void> Function()? beforeFinalRoll,
  }) async {
    final (WireTestLobby lobby, Map<String, Object?> started) =
        await buildSteeredLobby(faces, rules: rules);
    int current = started['turn']! as int;
    Map<String, Object?>? lastData;
    for (int i = 0; i < faces.length; i++) {
      final bool isLast = i == faces.length - 1;
      if (isLast && beforeFinalRoll != null) {
        await beforeFinalRoll();
      }
      final Map<String, Object?> frame = await sendRoll(lobby, current);
      expect(
        frame['t'],
        'rolled',
        reason: 'steered roll ${i + 1}/${faces.length} (face ${faces[i]}): '
            'expected a rolled frame from seat $current in room '
            '${lobby.code}, got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(
        data['value'],
        faces[i],
        reason: 'steering must produce the wanted face on the wire; wanted '
            '${faces[i]} at roll ${i + 1}/${faces.length}, got '
            '${data['value']}',
      );
      if (isLast) {
        lastData = data;
        break;
      }
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
          reason: 'steered roll ${i + 1}/${faces.length}: expected moved '
              'after driving the first legal move, got "${moved['t']}": '
              '${moved['d']}',
        );
        final _AfterMove after = await consumeAfterMove(lobby, current);
        expect(
          after.gameOver,
          isFalse,
          reason: 'the steered face sequence $faces reached game_over '
              'before its last roll; test/support/engine_search.dart\'s '
              'offline search must have missed a win reachable this early, '
              'which is itself worth reporting',
        );
        current = after.nextSeat!;
      }
    }
    return (lobby, current, lastData!);
  }

  /// Like [driveToSteeredRoll], but drives every face in [faces] all the
  /// way through -- including the last -- and returns each roll's own
  /// `rolled` payload, in order, rather than stopping at the last one, plus
  /// the lobby and the room's own `game_started` payload (a caller that
  /// needs `game_id`/`client_seeds` off it, the way the hash-chain test
  /// below does, would otherwise have no way to reach it). Used by tests
  /// that need several real, distinct rolls (and reveals) rather than a
  /// single game state to land on.
  Future<(WireTestLobby, Map<String, Object?>, List<Map<String, Object?>>)>
      driveSteeredRollSeries(
    List<int> faces, {
    Map<String, Object?> rules = const <String, Object?>{},
  }) async {
    final (WireTestLobby lobby, Map<String, Object?> started) =
        await buildSteeredLobby(faces, rules: rules);
    int current = started['turn']! as int;
    final List<Map<String, Object?>> collected = <Map<String, Object?>>[];
    for (int i = 0; i < faces.length; i++) {
      final Map<String, Object?> frame = await sendRoll(lobby, current);
      expect(
        frame['t'],
        'rolled',
        reason: 'steered roll ${i + 1}/${faces.length} (face ${faces[i]}): '
            'expected a rolled frame from seat $current in room '
            '${lobby.code}, got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(
        data['value'],
        faces[i],
        reason: 'steering must produce the wanted face on the wire; wanted '
            '${faces[i]} at roll ${i + 1}/${faces.length}, got '
            '${data['value']}',
      );
      collected.add(data);
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
          reason: 'steered roll ${i + 1}/${faces.length}: expected moved '
              'after driving the first legal move, got "${moved['t']}": '
              '${moved['d']}',
        );
        final _AfterMove after = await consumeAfterMove(lobby, current);
        expect(
          after.gameOver,
          isFalse,
          reason: 'the steered face sequence $faces reached game_over '
              'before collecting ${faces.length} rolls; '
              'test/support/engine_search.dart\'s offline roll-budget '
              'search must have missed a win reachable this early, which '
              'is itself worth reporting',
        );
        current = after.nextSeat!;
      }
    }
    return (lobby, started, collected);
  }

  /// The one game state every old `reachLegalRoll` call site in this file
  /// was actually fishing for: the very first roll of a fresh two-seat
  /// game, where every token starts in the yard (docs/RULES.md rule 17) so
  /// a legal move exists if and only if the face is 6. Found by
  /// `test/support/engine_search.dart`'s offline search rather than
  /// hand-asserted, so a future rule change that made this untrue would
  /// fail this search (and name the state it could not reach) instead of
  /// silently steering the wrong face. Returns the lobby, the seat that
  /// rolled, and that roll's own `rolled` payload.
  Future<(WireTestLobby, int, Map<String, Object?>)> freshLegalRoll({
    Map<String, Object?> rules = const <String, Object?>{},
  }) async {
    final List<int>? faces = findFaceSequence(
      seats: steeredSeats,
      accepts: (EngineRollStep step, GameState state) => step.legal.isNotEmpty,
    );
    expect(
      faces,
      isNotNull,
      reason: 'test/support/engine_search.dart found no face, within its '
          'own bound, that leaves a legal move on the first roll of a '
          'fresh two-seat game; docs/RULES.md rule 17 says a 6 always does, '
          'so this is the offline search disagreeing with the rules, not '
          'an unlucky run',
    );
    return driveToSteeredRoll(faces!, rules: rules);
  }

  /// The state the old `reachPartialLegalRoll` call site was fishing for: a
  /// roll that leaves a legal list which is neither empty nor all four
  /// tokens -- needed to prove ILLEGAL_MOVE against a well-formed token
  /// that is simply not on it. Found by `test/support/engine_search.dart`'s
  /// offline search: a single face cannot produce this on the first roll of
  /// a fresh game (a 6 makes every token legal at once, nothing else makes
  /// any token legal at all), so the search looks past the first roll
  /// rather than this file asserting by hand how many faces it takes.
  Future<(WireTestLobby, int, Map<String, Object?>)>
      freshPartialLegalRoll() async {
    final List<int>? faces = findFaceSequence(
      seats: steeredSeats,
      accepts: (EngineRollStep step, GameState state) =>
          step.legal.isNotEmpty && step.legal.length < 4,
    );
    expect(
      faces,
      isNotNull,
      reason: 'test/support/engine_search.dart found no face sequence, '
          'within its own bound, that leaves a legal list which is '
          'neither empty nor all four tokens -- needed to prove '
          'ILLEGAL_MOVE against a token that is well-formed but not legal',
    );
    return driveToSteeredRoll(faces!);
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
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();
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
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();

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
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();

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
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, 'zero');
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was the JSON string "zero", not an integer',
      );
    });

    test('BAD_FIELD: token is outside 0..3 (below range)', () async {
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();

      final Map<String, Object?> reply = await sendMove(lobby, onTurn, -1);
      expectErrorFrame(
        reply,
        'BAD_FIELD',
        because: 'token was -1, outside 0..3',
      );
    });

    test('BAD_FIELD: token is outside 0..3 (above range)', () async {
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();

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
      final (WireTestLobby lobby, int onTurn, Map<String, Object?> rolled) =
          await freshLegalRoll();
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
      final (WireTestLobby lobby, int onTurn, Map<String, Object?> rolled) =
          await freshPartialLegalRoll();
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
      final (WireTestLobby lobby, int onTurn, Map<String, Object?> rolled) =
          await freshLegalRoll();
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
      const int fullMs = 30 * 1000;
      // The same state freshLegalRoll steers for -- the first roll of a
      // fresh two-seat game leaves a legal move if and only if it is a 6
      // (docs/RULES.md rule 17) -- found by test/support/engine_search.dart
      // rather than hand-asserted here.
      final List<int>? faces = findFaceSequence(
        seats: steeredSeats,
        accepts: (EngineRollStep step, GameState state) =>
            step.legal.isNotEmpty,
      );
      expect(
        faces,
        isNotNull,
        reason: 'test/support/engine_search.dart found no face, within its '
            'own bound, that leaves a legal move on the first roll of a '
            'fresh two-seat game',
      );

      final (WireTestLobby lobby, int current, Map<String, Object?> rolled) =
          await driveToSteeredRoll(
        faces!,
        rules: <String, Object?>{'turn_seconds': 30},
        beforeFinalRoll: () async {
          // Decay the segment before the roll this test actually observes,
          // so the restart it asserts below is a genuine restart -- this is
          // not merely "the clock never moved so it was trivially still
          // full".
          harness.clock.advance(const Duration(seconds: 5));
        },
      );
      expect(
        rolled['legal'],
        isNotEmpty,
        reason: 'setup requires the steered roll to actually leave a legal '
            'move for seat $current in room ${lobby.code} for this '
            'property to mean anything; got legal=${rolled['legal']}',
      );
      expect(
        rolled['deadline_ms'],
        fullMs,
        reason: 'a rolled frame that leaves a legal move pending must '
            'restart the segment to the full window ($fullMs ms), even '
            'though this segment had decayed first; got '
            '${rolled['deadline_ms']}',
      );
    });

    test('restarts to the full window when an extra roll is granted', () async {
      // A 6 on the first roll of a fresh game is a one-face search: every
      // token is in the yard, so a 6 is the only face with a legal move at
      // all, and rolling one always grants another roll (docs/RULES.md
      // rule 9) once the resulting move is applied.
      final (WireTestLobby lobby, Map<String, Object?> started) =
          await buildSteeredLobby(
        <int>[6],
        rules: <String, Object?>{'turn_seconds': 30},
      );
      final int onTurn = started['turn']! as int;
      const int fullMs = 30 * 1000;

      final Map<String, Object?> rolled = await sendRoll(lobby, onTurn);
      expect(
        rolled['t'],
        'rolled',
        reason: 'expected rolled from the steered 6, got "${rolled['t']}": '
            '${rolled['d']}',
      );
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(rolledData['value'], 6);
      final List<int> legal =
          (rolledData['legal']! as List<Object?>).cast<int>();
      expect(
        legal,
        isNotEmpty,
        reason: 'a 6 on the first roll of a fresh game must leave every '
            'token in the yard eligible to leave it (docs/RULES.md rule '
            '17); got an empty legal list',
      );
      expect(
        rolledData['deadline_ms'],
        fullMs,
        reason: 'a rolled frame that leaves a legal move pending must '
            'itself restart the segment (section 6); got '
            '${rolledData['deadline_ms']}',
      );

      // Let time pass between the roll and the move, so a turn frame that
      // merely inherited the rolled frame's own restart above -- rather
      // than restarting again specifically because an extra roll was
      // granted -- would show a decayed value here, not the full window.
      harness.clock.advance(const Duration(seconds: 11));

      final Map<String, Object?> moved =
          await sendMove(lobby, onTurn, legal.first);
      expect(
        moved['t'],
        'moved',
        reason: 'expected moved after the legal move, got "${moved['t']}": '
            '${moved['d']}',
      );
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(
        movedData['extra_roll'],
        isTrue,
        reason: 'a 6 must grant an extra roll (docs/RULES.md rule 9); got '
            'extra_roll=${movedData['extra_roll']}',
      );

      final Map<String, Object?> turnFrame = await _next(lobby, onTurn);
      expect(
        turnFrame['t'],
        'turn',
        reason: 'an extra roll keeps the same seat on turn (section 12.2); '
            'got "${turnFrame['t']}": ${turnFrame['d']}',
      );
      final Map<String, Object?> turnData =
          turnFrame['d']! as Map<String, Object?>;
      expect(
        turnData['seat'],
        onTurn,
        reason: 'the extra roll must stay with the same seat, not hand off',
      );
      expect(
        turnData['deadline_ms'],
        fullMs,
        reason: 'an extra roll must restart the segment to the full '
            'window ($fullMs ms, section 6); 11000ms passed between the '
            'roll and the move, so this value would be $fullMs minus that '
            'if the restart had not happened -- got '
            '${turnData['deadline_ms']}',
      );
    });
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
      // 5 real, distinct rolls are all this property needs -- nothing
      // about a *specific* game state, just enough rolled frames to prove
      // the reveal chain end to end. test/support/engine_search.dart
      // verifies, against the real engine, that 5 rolls can be driven from
      // a fresh two-seat game without ever reaching game_over (rule 33's
      // 228-progress win condition is nowhere near reachable in 5 rolls
      // under any face sequence; see _winUnreachable above for the fuller
      // accounting), rather than this file assuming it.
      const int wanted = 5;
      final List<int>? faces =
          findRollBudgetFaces(seats: steeredSeats, rolls: wanted);
      expect(
        faces,
        isNotNull,
        reason: 'test/support/engine_search.dart found no $wanted-roll face '
            'sequence, from a fresh two-seat game, that avoids game_over '
            'along the way',
      );

      final (
        WireTestLobby lobby,
        Map<String, Object?> started,
        List<Map<String, Object?>> rolls
      ) = await driveSteeredRollSeries(faces!);
      final String chainCommit = lobby.hostRoom['chain_commit']! as String;
      final String gameId = started['game_id']! as String;
      final String clientSeeds = started['client_seeds']! as String;

      final List<_RollRecord> records = <_RollRecord>[
        for (final Map<String, Object?> data in rolls)
          _RollRecord(
            k: data['k']! as int,
            reveal: data['reveal']! as String,
            value: data['value']! as int,
          ),
      ];

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
      // Steered, not retried: on the first roll of a fresh game every
      // token is in the yard (docs/RULES.md rule 17), so any face that is
      // not a 6 leaves no legal move at all -- a one-face search, and
      // deterministic in place of the up-to-60-real-rolls gamble this test
      // used to run (order 055; see the file header for the seam and why
      // that gamble flaked).
      const int nonSixFace = 2;
      final (WireTestLobby lobby, Map<String, Object?> started) =
          await buildSteeredLobby(<int>[nonSixFace]);
      final int onTurn = started['turn']! as int;

      // A `roll` whose value leaves no legal move is the only single wire
      // message this section documents producing exactly three broadcast
      // pushes back to back (rolled, turn_passed, turn -- section 12.1).
      // A `move` never produces three: section 12.2's own if/else-if/else
      // always fires exactly one of {game_over, turn} after `moved`, so a
      // `move` produces two pushes, never three.
      final String rollId =
          seatFor(lobby, onTurn).client.send('roll', <String, Object?>{});
      // Read raw here, deliberately not via _next: this test inspects both
      // sockets' copies directly, precisely so it can assert re is absent
      // from the other socket's copies itself.
      final Map<String, Object?> rolled =
          await seatFor(lobby, onTurn).client.next();
      expect(
        rolled['t'],
        'rolled',
        reason: 'expected rolled from the steered non-six, got '
            '"${rolled['t']}": ${rolled['d']}',
      );
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(
        rolledData['value'],
        nonSixFace,
        reason: 'steering must produce the wanted face on the wire; got '
            '${rolledData['value']}',
      );
      final List<int> legal =
          (rolledData['legal']! as List<Object?>).cast<int>();
      expect(
        legal,
        isEmpty,
        reason: 'a non-6 on the first roll of a fresh game must leave '
            'every token in the yard unable to move (docs/RULES.md rule '
            '17); got legal=$legal for value=$nonSixFace',
      );

      final Map<String, Object?> passed =
          await seatFor(lobby, onTurn).client.next();
      expect(
        passed['t'],
        'turn_passed',
        reason: 'the empty-legal rolled must be followed by turn_passed '
            '(section 12.1); got "${passed['t']}": ${passed['d']}',
      );
      final Map<String, Object?> turn =
          await seatFor(lobby, onTurn).client.next();
      expect(
        turn['t'],
        'turn',
        reason: 'turn_passed must be followed by turn for the next seat '
            '(section 12.1); got "${turn['t']}": ${turn['d']}',
      );
      final List<Map<String, Object?>> triple = <Map<String, Object?>>[
        rolled,
        passed,
        turn,
      ];

      // rolled was read off onTurn's own socket, which is always the
      // sender's own copy, so re must equal rollId here (section 12.3:
      // the sender's own copy carries re).
      expect(
        rolled['re'],
        rollId,
        reason: 'the sender\'s own copy of rolled must carry re ($rollId); '
            'got ${rolled['re']}',
      );
      final WireTestSeat other =
          onTurn == lobby.host.seat ? lobby.guest : lobby.host;
      final int nextSeat = (turn['d']! as Map<String, Object?>)['seat']! as int;
      expect(
        nextSeat,
        isNot(onTurn),
        reason: 'turn_passed must hand the turn to a different seat; got '
            'the same seat $onTurn back',
      );

      final List<int> seqs = triple
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
      final Map<String, Object?> otherRolled = await other.client.next();
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
      // The first roll of a fresh two-seat game leaves no legal move for
      // any face but 6 (docs/RULES.md rule 17: every token is in the yard,
      // and only a 6 lets one leave it), and rule 7 makes that a
      // no_legal_move pass rather than any other reason -- a one-face
      // search, confirmed by test/support/engine_search.dart against the
      // real engine rather than asserted here.
      final List<int>? faces = findFaceSequence(
        seats: steeredSeats,
        accepts: (EngineRollStep step, GameState state) =>
            step.legal.isEmpty &&
            step.turnEndReason == TurnEndReason.noLegalMove,
      );
      expect(
        faces,
        isNotNull,
        reason: 'test/support/engine_search.dart found no face, within its '
            'own bound, that leaves turn_passed with reason no_legal_move '
            'on the first roll of a fresh two-seat game',
      );
      final int wantedFace = faces!.single;

      final (WireTestLobby lobby, Map<String, Object?> started) =
          await buildSteeredLobby(faces);
      final int current = started['turn']! as int;

      final Map<String, Object?> rolled = await sendRoll(lobby, current);
      expect(
        rolled['t'],
        'rolled',
        reason: 'expected rolled from the steered face $wantedFace for '
            'seat $current in room ${lobby.code}, got "${rolled['t']}": '
            '${rolled['d']}',
      );
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(
        rolledData['value'],
        wantedFace,
        reason: 'steering must produce the wanted face on the wire; got '
            '${rolledData['value']}',
      );
      final Object? reveal = rolledData['reveal'];
      expect(
        reveal,
        isA<String>(),
        reason: 'the rolled frame preceding a turn_passed must still '
            'carry its reveal (section 12.1: "the roll happened, and a '
            'roll that is not published is a hole in the chain")',
      );
      expect(_hex64.hasMatch(reveal! as String), isTrue);
      expect(
        rolledData['legal'],
        isEmpty,
        reason: 'steering targeted a face that leaves no legal move; got '
            'legal=${rolledData['legal']}',
      );

      // Read via _next: both frames are broadcast to every socket in the
      // room (section 12.3), so the other socket's copy of each is drained
      // (and checked) here too, consistent with every other read in this
      // file.
      final Map<String, Object?> passed = await _next(lobby, current);
      expect(
        passed['t'],
        'turn_passed',
        reason: 'expected turn_passed immediately after the empty-legal '
            'rolled, got "${passed['t']}": ${passed['d']}',
      );
      final Object? reason = (passed['d']! as Map<String, Object?>)['reason'];
      expect(
        reason,
        'no_legal_move',
        reason: 'steering targeted the first roll of a fresh game (rule 7), '
            'which must produce reason no_legal_move, not three_sixes; got '
            '$reason',
      );
      final Map<String, Object?> turn = await _next(lobby, current);
      expect(
        turn['t'],
        'turn',
        reason: 'expected turn for the next seat immediately after '
            'turn_passed, got "${turn['t']}": ${turn['d']}',
      );
      final int nextSeat = (turn['d']! as Map<String, Object?>)['seat']! as int;
      expect(
        nextSeat,
        isNot(current),
        reason: 'turn must move to a different seat after turn_passed '
            '(reason $reason)',
      );
    });

    test(
        'turn_passed with reason three_sixes after a third consecutive '
        'six', () async {
      // Two sixes real enough to each grant an extra roll, then a third:
      // docs/RULES.md rule 10, the third is not played at all and the
      // turn passes immediately. A three-face search, about 216
      // candidates.
      final (WireTestLobby lobby, Map<String, Object?> started) =
          await buildSteeredLobby(<int>[6, 6, 6]);
      final int onTurn = started['turn']! as int;
      final WireTestSeat other =
          onTurn == lobby.host.seat ? lobby.guest : lobby.host;

      final Map<String, Object?> rolled1 = await sendRoll(lobby, onTurn);
      expect(rolled1['t'], 'rolled',
          reason: 'expected rolled for the first six, got '
              '"${rolled1['t']}": ${rolled1['d']}');
      final List<int> legal1 =
          ((rolled1['d']! as Map<String, Object?>)['legal']! as List<Object?>)
              .cast<int>();
      expect(
        legal1,
        isNotEmpty,
        reason: 'the first six of the game must leave a legal move -- '
            'every token is in the yard, and a six can bring any of them '
            'out; got an empty legal list',
      );
      final Map<String, Object?> moved1 =
          await sendMove(lobby, onTurn, legal1.first);
      expect(moved1['t'], 'moved',
          reason: 'expected moved after the first six\'s move, got '
              '"${moved1['t']}": ${moved1['d']}');
      expect(
        (moved1['d']! as Map<String, Object?>)['extra_roll'],
        isTrue,
        reason: 'the first six must grant an extra roll (docs/RULES.md '
            'rule 9)',
      );
      final _AfterMove after1 = await consumeAfterMove(lobby, onTurn);
      expect(after1.gameOver, isFalse,
          reason: 'reached game_over after only one move; unexpected this '
              'early in a fresh 2-seat game');
      expect(
        after1.nextSeat,
        onTurn,
        reason: 'the extra roll from the first six must stay with the '
            'same seat',
      );

      final Map<String, Object?> rolled2 = await sendRoll(lobby, onTurn);
      expect(rolled2['t'], 'rolled',
          reason: 'expected rolled for the second consecutive six, got '
              '"${rolled2['t']}": ${rolled2['d']}');
      final List<int> legal2 =
          ((rolled2['d']! as Map<String, Object?>)['legal']! as List<Object?>)
              .cast<int>();
      expect(
        legal2,
        isNotEmpty,
        reason: 'the second consecutive six must still leave a legal '
            'move -- three other tokens are still in the yard; got an '
            'empty legal list',
      );
      final Map<String, Object?> moved2 =
          await sendMove(lobby, onTurn, legal2.first);
      expect(moved2['t'], 'moved',
          reason: 'expected moved after the second six\'s move, got '
              '"${moved2['t']}": ${moved2['d']}');
      expect(
        (moved2['d']! as Map<String, Object?>)['extra_roll'],
        isTrue,
        reason: 'the second consecutive six must also grant an extra '
            'roll (docs/RULES.md rule 9)',
      );
      final _AfterMove after2 = await consumeAfterMove(lobby, onTurn);
      expect(after2.gameOver, isFalse,
          reason: 'reached game_over after only two moves; unexpected '
              'this early in a fresh 2-seat game');
      expect(
        after2.nextSeat,
        onTurn,
        reason: 'the extra roll from the second six must stay with the '
            'same seat',
      );

      // The third consecutive six: docs/RULES.md rule 10, "the third 6 is
      // not played at all: the move it would have allowed is not made,
      // and the turn passes immediately." docs/PROTOCOL.md section 12.1:
      // the rolled frame is still sent first and still carries its
      // reveal -- the roll happened, and a roll that is not published is
      // a hole in the chain -- but its own legal list is empty regardless
      // of what tokens could otherwise have moved.
      final Map<String, Object?> rolled3 = await sendRoll(lobby, onTurn);
      expect(rolled3['t'], 'rolled',
          reason: 'expected rolled for the third consecutive six, got '
              '"${rolled3['t']}": ${rolled3['d']}');
      final Map<String, Object?> rolled3Data =
          rolled3['d']! as Map<String, Object?>;
      expect(rolled3Data['value'], 6);
      expect(rolled3Data['k'], 3);
      expect(
        rolled3Data['legal'],
        isEmpty,
        reason: 'the third consecutive six must leave no legal move at '
            'all (docs/RULES.md rule 10), regardless of what would '
            'otherwise be legal; got ${rolled3Data['legal']}',
      );
      expect(
        rolled3Data['reveal'],
        matches(_hex64),
        reason: 'the third six still happened and must still publish its '
            'reveal (docs/PROTOCOL.md section 12.1); got '
            '${rolled3Data['reveal']}',
      );

      final Map<String, Object?> passed = await _next(lobby, onTurn);
      expect(
        passed['t'],
        'turn_passed',
        reason: 'the empty-legal rolled from the third six must be '
            'followed by turn_passed; got "${passed['t']}": '
            '${passed['d']}',
      );
      expect(
        (passed['d']! as Map<String, Object?>)['reason'],
        'three_sixes',
        reason: 'turn_passed after a third consecutive six must carry '
            'reason "three_sixes"; got '
            '${(passed['d']! as Map<String, Object?>)['reason']}',
      );

      final Map<String, Object?> turnFrame = await _next(lobby, onTurn);
      expect(
        turnFrame['t'],
        'turn',
        reason: 'turn_passed must be followed by turn for the next seat; '
            'got "${turnFrame['t']}": ${turnFrame['d']}',
      );
      final int nextSeat =
          (turnFrame['d']! as Map<String, Object?>)['seat']! as int;
      expect(
        nextSeat,
        other.seat,
        reason: 'the third six must hand the turn to the other seat, not '
            'keep it',
      );

      // "Any moves made on the first and second 6 stand" (docs/RULES.md
      // rule 10): the two real moves above must not have been undone by
      // the third six's forfeit.
      final Map<String, Object?> expectedFinal1 =
          moved1['d']! as Map<String, Object?>;
      final Map<String, Object?> expectedFinal2 =
          moved2['d']! as Map<String, Object?>;
      final Map<int, int> expectedProgress = <int, int>{
        expectedFinal1['token']! as int: expectedFinal1['to']! as int,
        expectedFinal2['token']! as int: expectedFinal2['to']! as int,
      };
      final Map<String, Object?> snapshot =
          await resumeSnapshot(lobby, seatFor(lobby, onTurn));
      final Map<String, Object?> onTurnSeatSnapshot =
          (snapshot['seats']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .firstWhere((Map<String, Object?> s) => s['seat'] == onTurn);
      final List<Object?> tokens =
          onTurnSeatSnapshot['tokens']! as List<Object?>;
      expectedProgress.forEach((int token, int progress) {
        expect(
          tokens[token],
          progress,
          reason: 'docs/RULES.md rule 10: "any moves made on the first '
              'and second 6 stand" -- token $token should still be at '
              'progress $progress after the third six forfeits the turn; '
              'room snapshot had ${tokens[token]}',
        );
      });
    });
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
