// Order 134 -- what happens to a seat that drops while it holds the turn,
// and comes back on a fresh socket.
//
// Order 116 (run 35) measured `_handleResume` sending only a `room`
// snapshot, never a standalone `turn` frame, and concluded the stall this
// caused was a permanent deadlock whenever the dropped seat held the turn.
// That conclusion rested on "no Timer anywhere ever force-ends a turn",
// which orders 124 and 125 made false: `wire_server.dart` now runs a
// turn-expiry sweep, `Timer.periodic(turnExpiryInterval, ...)`
// (`wire_server.dart:207`). This file does not assume either the old
// "permanent" half or a new "now fixed" half; it measures the one thing
// that actually answers the player's question -- can the seat that just
// reconnected still take the turn it nominally holds, right now, before any
// expiry timer has had a chance to act.
//
// That question needs no clock advance at all: closing a socket and
// resuming on a fresh one does not, on its own, move the injected
// `FakeClock` forward by so much as a millisecond, so `deadline_ms` on the
// resumed snapshot is read exactly as it stood the instant the segment
// began. The complementary question -- what happens if the seat comes back
// only after its budget has already run out -- is deliberately not asked
// here: `turn_expiry_guard_test.dart`'s own header records that
// `turnExpiryInterval` is a hardcoded 1-second *real* `Timer.periodic`, not
// driven by the injected clock, and that only one case in this whole
// package (`turn_expiry_guard_test.dart`'s C1) accepts paying a bounded,
// condition-polled real wait to touch that timer at all. A test built to
// advance the fake clock past the budget would not make that timer fire
// any sooner; the only way to observe it landing on a room is to wait on
// the real second it runs on, which is exactly the "waits on real
// wall-clock seconds" this order's own text asks not to write. Reported
// here as the one thing this file could not do without either a real sleep
// or reaching outside the file list to change the timer's own cadence,
// neither of which is available under this order's rules.
//
// Grepped before relying on the claim: across turn_loop_test.dart, `resume`
// is sent from `resumeSnapshot` (turn_loop_test.dart:242) only on the
// seat's own still-open socket, and every WireTestClient.close() call in
// that file (lines 91 and 94, wire_harness.dart's own tearDown pattern) is
// teardown, never mid-game. No existing test closes one seat's socket
// mid-turn and resumes it on a fresh one.
//
// The two scenarios below share one steered die-face sequence, found by
// `test/support/engine_search.dart`'s offline search rather than
// hand-asserted (the same seam `turn_loop_test.dart` uses), under the
// server's roll queue (docs/RULES.md 3.2a). A lone non-6 on a fresh yard
// passes the turn (rule 11q, nothing queued can move). A 6 is queued and
// the same seat rolls again before any move is offered (rule 10q), so the
// non-host seat reaches `await_move` only on the closing non-6 after that
// 6. Both tests drive the handoff the same way; they differ only in where
// the non-host socket is closed -- before its own rolls (`await_roll`) or
// after the closing roll, before the move (`await_move`).
import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' show GameState;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// The fixed 2-player seat mapping (host=0, guest=2,
/// `lib/src/registry.dart:967-978`) this file's steering assumes, checked
/// rather than trusted -- see `buildSteeredLobby`'s own assertion below.
const List<int> _steeredSeats = <int>[0, 2];

const String _hostSteerSeed = 'resume-holding-turn-host-seed';
const String _guestSteerSeed = 'resume-holding-turn-guest-seed';
const String _steerClientSeeds = '0:$_hostSteerSeed|2:$_guestSteerSeed';

/// The `game_id` any steered room below reports, computed offline exactly
/// as `dice_steering_test.dart` and `turn_loop_test.dart` do: `buildScript`'s
/// filler-byte formula at the `game_id` offset does not depend on the
/// secret spliced in ahead of it, so this is fixed before
/// `findSecretForFaces` has even chosen one.
String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

/// The shortest face sequence, found offline against the pure engine under
/// [serverRoomRules], whose last roll leaves a legal move for a seat other
/// than the one that opened the game. Under the queue that is a passing
/// non-6 (the handoff), then a 6 (queued, still `await_roll`), then a
/// closing non-6 (rule 11q: the queued 6 can leave the yard). Not
/// hand-asserted: a future rule change that made this untrue would fail
/// this search, naming the mismatch, instead of silently steering a face
/// nobody asked for.
List<int> _findHandoffThenLegalRollFaces() {
  final List<int>? faces = findFaceSequence(
    seats: _steeredSeats,
    rules: serverRoomRules,
    accepts: (EngineRollStep step, GameState stateAfterRoll) =>
        step.legal.isNotEmpty &&
        stateAfterRoll.currentSeat != _steeredSeats.first,
  );
  expect(
    faces,
    isNotNull,
    reason: 'test/support/engine_search.dart found no face sequence, within '
        'its own bound, whose last roll leaves a legal move for a seat '
        'other than the one that started the game; this scenario needs '
        'the turn to change hands before the seat under test ever rolls, '
        'so there is nothing to steer without one',
  );
  return faces!;
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

  /// Builds a fresh 2-seat room steered so its first `wanted.length` rolls
  /// produce exactly `wanted`, joins a guest, fixes both seats' seeds so
  /// `client_seeds` matches `_steerClientSeeds`, and starts the game.
  /// Reassigns the outer `harness` so `setUp`'s default, never-started
  /// harness is replaced before anything talks to the network; `tearDown`
  /// closes whichever harness that variable holds at the end of a test.
  /// Modelled on `turn_loop_test.dart`'s own `buildSteeredLobby`, which this
  /// file cannot import (it is private to that file) and may not modify.
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
          'while the host is seat ${lobby.host.seat} '
          '(lib/src/engine_core.dart:30: a fresh game starts on '
          'config.seats.first, which registry.dart builds from the room\'s '
          'own seat list in ascending order, so this should always be the '
          'lowest-numbered seat)',
    );

    return (lobby, startedData);
  }

  /// Reads the next frame off [actingClient] and, unless it is a private
  /// `error`, also reads and checks the identical broadcast copy off
  /// [otherClient] -- the same design `turn_loop_test.dart`'s own `_next`
  /// uses and explains: reading only the sender's own socket leaves the
  /// other socket's copy of every accepted message sitting in its queue,
  /// which the next read on that socket -- in particular, the room snapshot
  /// a later `resume` on that same socket would ask for -- collides with
  /// instead of getting what it actually asked for.
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
  /// sockets, and returns the `turn` frame's own `d`. Under the queue that
  /// is one `turn` for the same seat still in `await_roll` (a 6, section
  /// 21.3) or `turn_passed` then `turn` (section 12.1).
  Future<Map<String, Object?>> consumeNoLegalMove(
    WireTestClient actingClient,
    WireTestClient otherClient, {
    required String because,
  }) async {
    final Map<String, Object?> next =
        await readAndDrain(actingClient, otherClient, because: because);
    if (next['t'] == 'turn') {
      final Map<String, Object?> turnData =
          next['d']! as Map<String, Object?>;
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
    final Map<String, Object?> passedData =
        next['d']! as Map<String, Object?>;
    expect(
      passedData['reason'],
      anyOf('no_legal_move', 'three_sixes'),
      reason: '$because: turn_passed after an empty-legal roll must say '
          'why; got ${passedData['reason']}',
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

  /// Rolls [faces] from [start] for [seat] until a roll leaves a legal
  /// move, draining each queued 6's follow-up `turn`. Returns that closing
  /// roll's `d`. The search that produced [faces] puts the accepting roll
  /// last, so an earlier legal move is a steering bug, not a pass.
  Future<Map<String, Object?>> rollUntilAwaitMove(
    WireTestClient actor,
    WireTestClient other,
    List<int> faces,
    int start, {
    required int seat,
    required String because,
  }) async {
    if (start >= faces.length) {
      fail('$because: no steered roll left to reach await_move');
    }
    for (int i = start; i < faces.length; i++) {
      final Map<String, Object?> rolled = await sendAndRead(
        actor,
        other,
        'roll',
        <String, Object?>{},
        because: '$because, steered face ${faces[i]}',
      );
      expect(
        rolled['t'],
        'rolled',
        reason: '$because: expected rolled for face ${faces[i]}, got '
            '"${rolled['t']}": ${rolled['d']}',
      );
      final Map<String, Object?> data =
          rolled['d']! as Map<String, Object?>;
      expect(data['seat'], seat);
      expect(
        data['value'],
        faces[i],
        reason: '$because: steering must still produce ${faces[i]}, got '
            '${data['value']}',
      );
      final List<Object?> legal = data['legal']! as List<Object?>;
      if (legal.isEmpty) {
        final Map<String, Object?> turnData = await consumeNoLegalMove(
          actor,
          other,
          because: '$because: face ${faces[i]} left nothing to move yet',
        );
        expect(
          turnData['seat'],
          seat,
          reason: '$because: a queued 6 keeps seat $seat on turn; got '
              'seat=${turnData['seat']}',
        );
        continue;
      }
      expect(
        i,
        faces.length - 1,
        reason: '$because: a legal move arrived on face ${faces[i]} before '
            'the last steered roll ${faces.last}',
      );
      return data;
    }
    fail('$because: steered rolls $faces ended without a legal move');
  }

  /// The face an `await_move` frame names as `value`: the first entry of
  /// `legal_by_face` (docs/PROTOCOL.md 21.3, `defaultFace`).
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

  /// Drains the one frame section 12.2 sends after `moved`: `game_over`, or
  /// `turn` for whichever seat now holds it.
  Future<Map<String, Object?>> consumeAfterMove(
    WireTestClient actingClient,
    WireTestClient otherClient, {
    required String because,
  }) async {
    final Map<String, Object?> next =
        await readAndDrain(actingClient, otherClient, because: because);
    expect(
      next['t'],
      anyOf('turn', 'game_over'),
      reason: '$because: moved must be followed by either game_over or '
          'turn (docs/PROTOCOL.md section 12.2); got "${next['t']}": '
          '${next['d']}',
    );
    return next;
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

  /// A socket closing (`connection.dart`'s `handleDisconnect`) and a resume
  /// that actually flips a seat back (`_handleResume`, guarded on
  /// `ok.reconnected`) each broadcast one `presence` push to every *other*
  /// socket in the room -- never to the socket that just left or returned,
  /// and never carrying `re`, since neither is an answer to a request that
  /// socket sent. Left undrained, either sits in the surviving socket's
  /// queue and is mistaken for whatever frame that socket's next read
  /// actually asked for; every scenario below produces exactly one of each
  /// (a drop, then a resume) on the seat under test, both landing on the
  /// same surviving host socket, in that order.
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

  /// Plays steered rolls until the non-host seat holds an unrolled turn:
  /// `await_roll`, and the roll that got it there was not its own (so
  /// nothing of its queue has started). Returns the index of the next
  /// unplayed face, which is that seat's first roll.
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
      final int played = index;
      index++;
      final Map<String, Object?> turnData = await consumeNoLegalMove(
        lobby.host.client,
        lobby.guest.client,
        because: 'handoff roll ${played + 1} left nothing to move',
      );
      if (turnData['seat'] == lobby.guest.seat &&
          rolledData['seat'] != lobby.guest.seat) {
        expect(
          turnData['phase'],
          'await_roll',
          reason: 'the handed turn must be an unrolled one; got $turnData',
        );
        return index;
      }
    }
    fail(
      'steered faces $faces never handed an unrolled turn to seat '
      '${lobby.guest.seat}',
    );
  }

  group(
      'a non-host seat holding the turn drops and resumes on a fresh '
      'socket', () {
    test(
        'await_roll: dropped before rolling -- the resumed room snapshot '
        'still names the seat on turn with a live deadline, and the '
        'resumed seat can still roll and move', () async {
      final List<int> faces = _findHandoffThenLegalRollFaces();
      final (WireTestLobby lobby, _) = await buildSteeredLobby(faces);

      final int nextFace = await driveHandoffToNonHost(lobby, faces);

      // -- The moment under test: the non-host seat drops while it holds
      // an unrolled turn. Nothing has been sent from its socket since the
      // handoff above, so this is a genuine "phone died before I could
      // even roll" drop, not a sample of a socket that is still live.
      await lobby.guest.client.close();
      await drainPresence(lobby.host.client, lobby.guest.seat,
          connected: false);

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
        because: 'await_roll: resume must answer seat_assigned before the '
            'room snapshot',
      );
      final Map<String, Object?> resumeFrame = await freshGuest.next();
      expect(
        resumeFrame['t'],
        'room',
        reason: 'point of death candidate: resume on a fresh socket for a '
            'seat holding the turn must answer with a room snapshot, '
            'immediately after seat_assigned (connection.dart\'s '
            '_handleResume, docs/PROTOCOL.md section 8); got '
            '"${resumeFrame['t']}": ${resumeFrame['d']}',
      );
      expect(resumeFrame['re'], resumeId);
      // This resume is a genuine flip back to connected, so the host's
      // still-open socket sees a second presence push that must be
      // drained before the host's socket is read again below
      // (readAndDrain on the resumed seat's own roll), or that push is
      // mistaken for the roll's own broadcast copy.
      await drainPresence(lobby.host.client, lobby.guest.seat, connected: true);
      final Map<String, Object?> roomData =
          resumeFrame['d']! as Map<String, Object?>;
      final Map<String, Object?> resumedTurn = turnObject(roomData);
      expect(
        resumedTurn['seat'],
        lobby.guest.seat,
        reason: 'point of death candidate: the resumed room snapshot must '
            'still name seat ${lobby.guest.seat} as on turn; got seat='
            '${resumedTurn['seat']}',
      );
      expect(
        resumedTurn['phase'],
        'await_roll',
        reason: 'point of death candidate: the resumed room snapshot must '
            'still show await_roll (the seat had not rolled before it '
            'dropped); got phase=${resumedTurn['phase']}',
      );
      final Object? rawDeadline = resumedTurn['deadline_ms'];
      expect(
        rawDeadline,
        isA<int>(),
        reason: 'point of death candidate: deadline_ms must be an int on '
            'the resumed turn object; got ${rawDeadline.runtimeType}: '
            '$rawDeadline',
      );
      expect(
        rawDeadline! as int,
        greaterThan(0),
        reason: 'point of death candidate: deadline_ms on the resumed turn '
            'must still be a live, positive figure -- no time has passed '
            'on the injected clock between the drop and the resume, so a '
            'value of 0 here would mean the drop itself silently spent '
            'the seat\'s whole budget before it even got a chance to act; '
            'got $rawDeadline',
      );

      // -- The assertion that matters: the resumed seat actually acts.
      // Under the queue it rolls until the closing non-6 leaves a move
      // (rule 10q queues each 6 first). The first of those rolls is the
      // finding: a seat that just reconnected must be allowed to roll.
      final Map<String, Object?> actedData = await rollUntilAwaitMove(
        freshGuest,
        lobby.host.client,
        faces,
        nextFace,
        seat: lobby.guest.seat,
        because: 'THE FINDING: seat ${lobby.guest.seat} resumed on a fresh '
            'socket while holding an unrolled turn (room ${lobby.code}) '
            'and must be able to roll',
      );
      final int legalToken =
          (actedData['legal']! as List<Object?>).cast<int>().first;

      final Map<String, Object?> moved = await sendAndRead(
        freshGuest,
        lobby.host.client,
        'move',
        <String, Object?>{'token': legalToken},
        because: 'the resumed seat\'s own move, proving the game advances '
            'past the roll it just took',
      );
      expect(
        moved['t'],
        'moved',
        reason: 'the resumed seat\'s legal move must be accepted; got '
            '"${moved['t']}": ${moved['d']}',
      );
      await consumeAfterMove(
        freshGuest,
        lobby.host.client,
        because: 'the resumed seat\'s move must still hand the turn '
            'onward (or end the game) exactly like any other move',
      );
    });

    test(
        'await_move: dropped after rolling, before moving -- the resumed '
        'room snapshot still carries the pending roll with a live '
        'deadline, and the resumed seat can still move', () async {
      final List<int> faces = _findHandoffThenLegalRollFaces();
      final (WireTestLobby lobby, _) = await buildSteeredLobby(faces);

      final int nextFace = await driveHandoffToNonHost(lobby, faces);

      // The non-host seat rolls through to await_move, on its own
      // still-open socket, before it drops. A 6 is queued and does not
      // itself leave a move (rule 10q); the closing non-6 does. This is
      // the "phone died after I saw the dice, before I could tap a token"
      // scenario, not a fresh unrolled turn.
      final Map<String, Object?> rolledData = await rollUntilAwaitMove(
        lobby.guest.client,
        lobby.host.client,
        faces,
        nextFace,
        seat: lobby.guest.seat,
        because: 'the non-host seat\'s own rolls, before it drops',
      );

      // -- The moment under test: the non-host seat drops holding a
      // pending, unplayed roll.
      await lobby.guest.client.close();
      await drainPresence(lobby.host.client, lobby.guest.seat,
          connected: false);

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
        because: 'await_move: resume must answer seat_assigned before the '
            'room snapshot',
      );
      final Map<String, Object?> resumeFrame = await freshGuest.next();
      expect(
        resumeFrame['t'],
        'room',
        reason: 'point of death candidate: resume on a fresh socket for a '
            'seat holding a pending roll must answer with a room snapshot, '
            'immediately after seat_assigned; got "${resumeFrame['t']}": '
            '${resumeFrame['d']}',
      );
      expect(resumeFrame['re'], resumeId);
      // Same reconnect presence as the await_roll scenario above: the
      // host's still-open socket sees it and it must be drained before
      // the host's socket is read again below.
      await drainPresence(lobby.host.client, lobby.guest.seat, connected: true);
      final Map<String, Object?> roomData =
          resumeFrame['d']! as Map<String, Object?>;
      final Map<String, Object?> resumedTurn = turnObject(roomData);
      expect(
        resumedTurn['seat'],
        lobby.guest.seat,
        reason: 'point of death candidate: the resumed room snapshot must '
            'still name seat ${lobby.guest.seat} as on turn; got seat='
            '${resumedTurn['seat']}',
      );
      expect(
        resumedTurn['phase'],
        'await_move',
        reason: 'point of death candidate: the resumed room snapshot must '
            'still show await_move (the seat had rolled but not moved '
            'before it dropped); got phase=${resumedTurn['phase']}',
      );
      expect(
        resumedTurn['value'],
        defaultFaceOf(
          rolledData,
          because: 'the closing roll that left the pending move',
        ),
        reason: 'the resumed turn object\'s value is defaultFace '
            '(docs/PROTOCOL.md 21.3), the face an omitted move.face would '
            'spend, not the closing roll\'s own value; got '
            '${resumedTurn['value']}, rolled said ${rolledData['value']} '
            'with legal_by_face=${rolledData['legal_by_face']}',
      );
      expect(
        resumedTurn['queue'],
        rolledData['queue'],
        reason: 'the resumed turn must still hold the queue the seat saw '
            'before it dropped; got ${resumedTurn['queue']}, had '
            '${rolledData['queue']}',
      );
      expect(
        resumedTurn['legal'],
        rolledData['legal'],
        reason: 'the resumed turn object\'s legal list must match the one '
            'the seat already saw before it dropped; got '
            '${resumedTurn['legal']}, had ${rolledData['legal']}',
      );
      expect(
        resumedTurn['legal_by_face'],
        rolledData['legal_by_face'],
        reason: 'the resumed legal_by_face must match the closing roll; '
            'got ${resumedTurn['legal_by_face']}, had '
            '${rolledData['legal_by_face']}',
      );
      final Object? rawDeadline = resumedTurn['deadline_ms'];
      expect(
        rawDeadline,
        isA<int>(),
        reason: 'point of death candidate: deadline_ms must be an int on '
            'the resumed turn object; got ${rawDeadline.runtimeType}: '
            '$rawDeadline',
      );
      expect(
        rawDeadline! as int,
        greaterThan(0),
        reason: 'point of death candidate: deadline_ms on the resumed turn '
            'must still be live -- no time has passed on the injected '
            'clock between the drop and the resume; got $rawDeadline',
      );

      // -- The assertion that matters: the resumed seat actually acts.
      final int legalToken =
          (resumedTurn['legal']! as List<Object?>).cast<int>().first;
      final Map<String, Object?> moved = await sendAndRead(
        freshGuest,
        lobby.host.client,
        'move',
        <String, Object?>{'token': legalToken},
        because: 'the resumed seat\'s own move',
      );
      expect(
        moved['t'],
        'moved',
        reason: 'THE FINDING: seat ${lobby.guest.seat} resumed on a fresh '
            'socket while holding a pending, unplayed roll (room '
            '${lobby.code}), and its own move came back as "${moved['t']}" '
            '(${moved['d']}) instead of "moved" -- a seat that has just '
            'reconnected cannot finish the turn the room still says is '
            'its own',
      );
      final Map<String, Object?> movedData =
          moved['d']! as Map<String, Object?>;
      expect(
        movedData['seat'],
        lobby.guest.seat,
        reason: 'the accepted move must be recorded for seat '
            '${lobby.guest.seat}; got seat=${movedData['seat']}',
      );
      expect(
        movedData['token'],
        legalToken,
        reason: 'the accepted move must carry the token that was sent; '
            'got token=${movedData['token']}',
      );
      await consumeAfterMove(
        freshGuest,
        lobby.host.client,
        because: 'the resumed seat\'s move must still be followed by turn '
            'or game_over, proving the game genuinely advances past the '
            'resume, not just accepts one message',
      );
    });
  });
}
