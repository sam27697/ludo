// Order 052: proves the test seam that lets a wire-level test choose which
// die faces a room produces, without touching `lib/` at all.
// `test/support/scripted_bytes.dart` and `test/support/dice_oracle.dart` are
// the seam; this file is the proof it works, that it does not undermine the
// chain's verifiability, that it is deterministic, and that it has teeth --
// an unarmed room does not produce the steered sequence by accident.
//
// Written from `docs/PROTOCOL.md` sections 11 and 12 and from
// `lib/src/registry.dart`, read to get the draw order right, never modified.
// Nothing in this file un-skips or edits anything in `turn_loop_test.dart`;
// that suite's five skipped tests and its one flaky test are a later order's
// job, not this one's.

import 'package:fair_dice/fair_dice.dart' show hexEncode, verifyReveal;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// The five faces every armed room in this file is steered to produce, for
/// `k = 1 .. 5`. Chosen to satisfy the order's own requirement that the
/// sequence "includes three consecutive sixes": positions 1-3 are `6, 6, 6`.
/// `docs/RULES.md` rule 10 ("the third consecutive 6 is not played at all",
/// `packages/ludo_engine/lib/src/engine_core.dart:104-112`) forces the third
/// six's turn to pass without a move, which is why this sequence is driven
/// by two seats rather than one: seat A rolls `6, 6, 6` and is passed to
/// seat B, who rolls the fourth and fifth faces.
const List<int> _wantedFaces = <int>[6, 6, 6, 3, 5];

const String _hostSeed = 'host-seed';
const String _guestSeed = 'guest-seed';

/// `docs/PROTOCOL.md` section 2 / `lib/src/registry.dart:967-978`: for a
/// 2-player room the seat indices are fixed at `[0, 2]` and are assigned in
/// join order, never drawn from the injected `Random`. The host (who always
/// creates first) is seat 0 and the guest is seat 2, deterministically, for
/// every room this file builds. `client_seeds` (section 11.2: seats in
/// ascending index, `seat:seed`, joined by `|`) is therefore known before
/// any room exists, from the seeds this file itself chooses.
const String _clientSeeds = '0:$_hostSeed|2:$_guestSeed';

/// A `game_id` this file can predict before creating a room: the filler byte
/// formula `buildScript` documents (`i % 256` at script position `i`,
/// outside the secret window) does not depend on the secret, so the 8 bytes
/// at [gameIdOffset] are the same for every secret. Used only to run the
/// offline search in [_armRoom]; every test below still checks this
/// prediction against `game_started.game_id` read off a real socket, rather
/// than trusting it blind.
String _predictedGameId() {
  final List<int> probe =
      buildScript(secret: List<int>.filled(serverSecretDraws, 0));
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

/// One roll this suite actually observed over the wire: the fields `rolled`
/// carries that this file's assertions need, kept as plain values rather
/// than the raw frame.
class _RollRecord {
  _RollRecord({
    required this.k,
    required this.seat,
    required this.value,
    required this.reveal,
  });

  final int k;
  final int seat;
  final int value;
  final String reveal;
}

/// A room built, joined, seeded and started through [ServerHarness], with
/// the [_RollRecord]s of the first [_wantedFaces.length] rolls already
/// collected.
class _ArmedRoom {
  _ArmedRoom({
    required this.harness,
    required this.lobby,
    required this.chainCommit,
    required this.gameId,
    required this.rolls,
    this.steered,
  });

  final ServerHarness harness;
  final WireTestLobby lobby;

  /// `chain_commit` from the `room` frame the host received at creation.
  final String chainCommit;

  /// `game_id` from `game_started`.
  final String gameId;

  final List<_RollRecord> rolls;

  /// The secret and predicted faces/reveals [findSecretForFaces] found for
  /// an armed room; `null` for the unarmed negative control.
  final SteeredSecret? steered;
}

WireTestSeat _seatFor(WireTestLobby lobby, int seat) =>
    seat == lobby.host.seat ? lobby.host : lobby.guest;

/// Reads one state-changing push off [actingSeat]'s own socket -- the
/// socket that sent the message that caused it, so this copy carries `re`
/// -- and drains the identical broadcast copy off the other seat's socket
/// right behind it (section 12.3: every such push reaches every connected
/// socket in the room, sender included). Every call this file makes to
/// either socket goes through this function or [WireTestClient.send]; none
/// reads only one side, because a push left undrained on the socket that
/// did not cause it sits in that socket's queue and is the first thing a
/// later, unrelated read on that same socket sees -- turn_loop_test.dart's
/// header documents hitting exactly this before adopting the same fix.
Future<Map<String, Object?>> _next(WireTestLobby lobby, int actingSeat) async {
  final WireTestSeat acting = _seatFor(lobby, actingSeat);
  final WireTestSeat other =
      actingSeat == lobby.host.seat ? lobby.guest : lobby.host;
  final Map<String, Object?> mine = await acting.client.next();
  await other.client.next();
  return mine;
}

/// Drives exactly [count] rolls starting with [startingSeat] on turn,
/// sending a `move` with the first legal token whenever one is required to
/// reach the next roll (docs/PROTOCOL.md section 12.1: a `roll` is only
/// accepted when "the turn is awaiting a move, not a roll" is false, i.e.
/// the previous roll's move, if any, must already be resolved), and
/// collecting each `rolled` frame's `k`, `seat`, `value` and `reveal`.
Future<List<_RollRecord>> _driveRolls(
  WireTestLobby lobby,
  int startingSeat,
  int count,
) async {
  final List<_RollRecord> records = <_RollRecord>[];
  int current = startingSeat;
  while (records.length < count) {
    final WireTestSeat seat = _seatFor(lobby, current);
    seat.client.send('roll', <String, Object?>{});
    final Map<String, Object?> rolled = await _next(lobby, current);
    expect(
      rolled['t'],
      'rolled',
      reason: 'attempt ${records.length + 1}: expected rolled, got '
          '"${rolled['t']}": ${rolled['d']}',
    );
    final Map<String, Object?> rolledData =
        rolled['d']! as Map<String, Object?>;
    records.add(
      _RollRecord(
        k: rolledData['k']! as int,
        seat: current,
        value: rolledData['value']! as int,
        reveal: rolledData['reveal']! as String,
      ),
    );
    final List<Object?> legal = rolledData['legal']! as List<Object?>;
    if (legal.isEmpty) {
      final Map<String, Object?> passed = await _next(lobby, current);
      expect(
        passed['t'],
        'turn_passed',
        reason: 'an empty-legal rolled must be followed by turn_passed '
            '(section 12.1); got "${passed['t']}": ${passed['d']}',
      );
      final Map<String, Object?> turn = await _next(lobby, current);
      expect(
        turn['t'],
        'turn',
        reason: 'turn_passed must be followed by turn (section 12.1); got '
            '"${turn['t']}": ${turn['d']}',
      );
      current = (turn['d']! as Map<String, Object?>)['seat']! as int;
      continue;
    }
    seat.client.send('move', <String, Object?>{'token': legal.first});
    final Map<String, Object?> moved = await _next(lobby, current);
    expect(
      moved['t'],
      'moved',
      reason: 'expected moved, got "${moved['t']}": ${moved['d']}',
    );
    final Map<String, Object?> after = await _next(lobby, current);
    if (after['t'] == 'game_over') {
      throw TestFailure(
        'reached game_over after only ${records.length} of $count steered '
        'rolls; unexpected this early in a fresh 2-seat game -- if this '
        'reproduces, the wanted faces $_wantedFaces or the moves this '
        'driver chose (always legal.first) are the place to look',
      );
    }
    expect(
      after['t'],
      'turn',
      reason: 'moved must be followed by either game_over or turn (section '
          '12.2); got "${after['t']}": ${after['d']}',
    );
    current = (after['d']! as Map<String, Object?>)['seat']! as int;
  }
  return records;
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

  /// Builds one room whose die faces are steered to [wanted] (searched with
  /// [findSecretForFaces] before a single frame is sent), joins a guest,
  /// fixes both seats' seeds with [_hostSeed]/[_guestSeed], starts the game,
  /// and drives exactly `wanted.length` rolls. If [secret] is supplied, that
  /// secret is scripted directly instead of searching for one -- used by the
  /// determinism test to reuse a secret [findSecretForFaces] already found
  /// for a second, independent room.
  Future<_ArmedRoom> armRoom({List<int>? wanted, List<int>? secret}) async {
    final String gameId = _predictedGameId();
    final SteeredSecret? steered = secret == null
        ? findSecretForFaces(
            wanted: wanted ?? _wantedFaces,
            gameId: gameId,
            clientSeeds: _clientSeeds,
          )
        : null;
    final List<int> chosenSecret = secret ?? steered!.secret;

    final ServerHarness harness = ServerHarness.build(
        secure: ScriptedBytesRandom(buildScript(secret: chosenSecret)));
    harnesses.add(harness);
    await harness.start();

    final WireTestLobby lobby =
        await buildWireTestLobby(harness.wsUri, clients, players: 2);
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      <int>[0, 2],
      reason: 'this file assumes the fixed 2-player seat mapping '
          'lib/src/registry.dart:967-978 documents (host=0, guest=2) so it '
          'can predict client_seeds before creating the room; got host='
          '${lobby.host.seat} guest=${lobby.guest.seat}. If this ever '
          'fails, the mapping changed and _clientSeeds above needs to '
          'change with it -- it is not a flake.',
    );

    lobby.host.client
        .send('set_seed', <String, Object?>{'client_seed': _hostSeed});
    await receiveType(lobby.host.client, 'seat_seed');
    lobby.guest.client
        .send('set_seed', <String, Object?>{'client_seed': _guestSeed});
    await receiveType(lobby.guest.client, 'seat_seed');

    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    // Section 13.1: a standalone turn immediately follows game_started, on
    // every socket in the room; consumed and asserted here so _driveRolls
    // below does not mistake it for the first rolled frame it sends for.
    await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);

    expect(
      startedData['game_id'],
      gameId,
      reason: 'predicted game_id (computed offline from buildScript\'s '
          'filler bytes at gameIdOffset, before this room was created) did '
          'not match game_started.game_id read off the wire; the draw-order '
          'picture in scripted_bytes.dart no longer matches registry.dart',
    );
    expect(
      startedData['client_seeds'],
      _clientSeeds,
      reason: 'predicted client_seeds did not match game_started.'
          'client_seeds read off the wire',
    );

    final int startingSeat = startedData['turn']! as int;
    final List<_RollRecord> rolls =
        await _driveRolls(lobby, startingSeat, (wanted ?? _wantedFaces).length);

    return _ArmedRoom(
      harness: harness,
      lobby: lobby,
      chainCommit: lobby.hostRoom['chain_commit']! as String,
      gameId: gameId,
      rolls: rolls,
      steered: steered,
    );
  }

  /// Builds one room through the harness the ordinary way -- no `secure`
  /// argument, so `ServerHarness.build` falls back to `Random.secure()`
  /// exactly as it does for every other suite -- with the same two seeds
  /// this file uses everywhere else, and starts it.
  Future<_ArmedRoom> unarmedRoom() async {
    final ServerHarness harness = ServerHarness.build();
    harnesses.add(harness);
    await harness.start();

    final WireTestLobby lobby =
        await buildWireTestLobby(harness.wsUri, clients, players: 2);

    lobby.host.client
        .send('set_seed', <String, Object?>{'client_seed': _hostSeed});
    await receiveType(lobby.host.client, 'seat_seed');
    lobby.guest.client
        .send('set_seed', <String, Object?>{'client_seed': _guestSeed});
    await receiveType(lobby.guest.client, 'seat_seed');

    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    // Section 13.1: a standalone turn immediately follows game_started, on
    // every socket in the room; consumed and asserted here so _driveRolls
    // below does not mistake it for the first rolled frame it sends for.
    await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);

    final int startingSeat = startedData['turn']! as int;
    final List<_RollRecord> rolls =
        await _driveRolls(lobby, startingSeat, _wantedFaces.length);

    return _ArmedRoom(
      harness: harness,
      lobby: lobby,
      chainCommit: lobby.hostRoom['chain_commit']! as String,
      gameId: startedData['game_id']! as String,
      rolls: rolls,
      steered: null,
    );
  }

  test(
      'steering works: a room armed with a scripted secret produces exactly '
      'the named five-face sequence, including three consecutive sixes, in '
      'its own rolled frames', () async {
    final _ArmedRoom room = await armRoom();

    final List<int> observed =
        room.rolls.map((_RollRecord r) => r.value).toList();
    expect(
      observed,
      _wantedFaces,
      reason: 'wanted faces $_wantedFaces for game_id=${room.gameId}, '
          'client_seeds=$_clientSeeds, secret='
          '${hexEncode(room.steered!.secret)} but the server\'s own rolled '
          'frames carried $observed',
    );
    expect(
      observed.sublist(0, 3),
      <int>[6, 6, 6],
      reason: 'the steered sequence must include three consecutive sixes; '
          'got $observed',
    );
    expect(
      room.rolls.map((_RollRecord r) => r.k).toList(),
      <int>[1, 2, 3, 4, 5],
      reason: 'k must increment by exactly one per roll (section 12.1); '
          'got ${room.rolls.map((_RollRecord r) => r.k).toList()}',
    );
  });

  test(
      'the chain still verifies: every one of the five steered reveals '
      'verifies against chain_commit with verifyReveal, so steering the '
      'dice is not a way of forging them', () async {
    final _ArmedRoom room = await armRoom();

    expect(
      room.chainCommit,
      matches(RegExp(r'^[0-9a-f]{64}$')),
      reason: 'chain_commit off the wire must be 64 lowercase hex '
          'characters; got "${room.chainCommit}"',
    );

    String parent = room.chainCommit;
    for (final _RollRecord roll in room.rolls) {
      final bool ok = verifyReveal(reveal: roll.reveal, parent: parent);
      expect(
        ok,
        isTrue,
        reason: 'k=${roll.k} reveal ${roll.reveal} does not hash back to '
            'the previous link ($parent, ${parent == room.chainCommit ? 'chain_commit' : 'k=${roll.k - 1}\'s reveal'}); '
            'steering broke the chain\'s own verifiability, which is the '
            'one thing this seam must never do',
      );
      parent = roll.reveal;
    }
  });

  test(
      'it is deterministic: the same scripted secret and the same client '
      'seeds produce the same five faces on a second, independently '
      'created room', () async {
    final _ArmedRoom first = await armRoom();
    final List<int> firstSecret = first.steered!.secret;

    final _ArmedRoom second = await armRoom(secret: firstSecret);

    expect(
      second.rolls.map((_RollRecord r) => r.value).toList(),
      first.rolls.map((_RollRecord r) => r.value).toList(),
      reason: 'the same secret (${hexEncode(firstSecret)}) and the same '
          'client_seeds ($_clientSeeds) must reproduce the same face '
          'sequence on an independently created room; first room produced '
          '${first.rolls.map((_RollRecord r) => r.value).toList()}, second '
          'produced ${second.rolls.map((_RollRecord r) => r.value).toList()}',
    );
    // Everything upstream of the faces is reproduced too, which is the
    // stronger and more informative claim: identical secret, identical
    // filler bytes (buildScript's formula does not depend on the secret) and
    // identical client_seeds necessarily give an identical chain_commit and
    // an identical game_id, not merely an identical face sequence.
    expect(second.chainCommit, first.chainCommit);
    expect(second.gameId, first.gameId);
  });

  test(
      'the assertion has teeth: an unarmed room (no scripted source) does '
      'not share the armed room\'s chain_commit', () async {
    // A negative control on the *faces* (assert five unarmed rolls do not
    // equal _wantedFaces) would be correct but flaky on principle: one
    // unarmed room matching by chance is 1 in 6^5 = 7776, which is too
    // likely to leave to luck in a suite that must never be red by chance.
    // chain_commit is a public, deterministic function of the room's
    // 32-byte secret (docs/PROTOCOL.md section 11.2, `s[0]`); an unarmed
    // room's secret comes from a real Random.secure() draw, so an unarmed
    // chain_commit matching the armed room's by chance is a 2^-256 event,
    // not a 1-in-7776 one. That is the "assert on the secret rather than
    // the faces" option the order names, and it is the one this test takes:
    // one unarmed room is enough, and this can never flake.
    final _ArmedRoom armed = await armRoom();
    final _ArmedRoom unarmed = await unarmedRoom();

    expect(
      unarmed.chainCommit,
      isNot(equals(armed.chainCommit)),
      reason: 'an unarmed room (Random.secure(), never scripted) produced '
          'the same chain_commit as the armed room; either something is '
          'catastrophically wrong with this test\'s isolation between '
          'harnesses, or Random.secure() just collided with a scripted '
          '32-byte secret, which is a 2^-256 event and not one this suite '
          'should ever actually see',
    );
  });
}
