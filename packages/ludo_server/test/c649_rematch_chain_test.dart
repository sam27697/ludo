// Order C-649t: a room must be able to play game 1, rematch, game 2, rematch,
// game 3, rematch, game 4 with the same seats, with no limit on how many
// times (docs/PROTOCOL.md section 16, product doctrine P5 and P6).
//
// Written from the protocol alone. Every assertion is on frames a client
// receives over real sockets against a real WireServer, through
// test/support/wire_harness.dart, the harness test/rematch_test.dart uses.
//
// Every game here is finished by really playing it over the wire: roll,
// rolled, move, moved, game_over. The only fixture step is the one
// test/rematch_test.dart already uses for its own natural-win test: the seat
// on turn gets three tokens home and a fourth placed exactly one face short
// of home, by rewriting the room's engine state between the dice and the
// move, so the winning move is real and the verify record is saved by the
// server's own win path. No dice face is steered: the fixture reads the face
// the server really drew and places the token to match it, so the run does
// not depend on any seed. A failure therefore names the scenario and the game
// number, which are the whole reproduction.
//
// Sections quoted from docs/PROTOCOL.md:
//
//   16.4: "Everyone accepted. When every seat occupied at the moment of an
//   accepted `rematch` is in `rematch.ready`, at least two seats are
//   occupied, and every one of them is connected, the server starts the game
//   itself, exactly as an accepted `start_game` from the host would ...
//   Two friends: one tap each, no third tap."
//
//   18.3: "`leave_room` in FINISHED frees the seat, exactly as in LOBBY".
//   18.4: "A rematch after a leave follows section 16 with the seats that are
//   left: the first `rematch` from any remaining seat opens the rematch
//   LOBBY, the freed seat can be taken by code (section 16.9 rule 4), and
//   the auto-start set is the seats occupied when an accept arrives."

import 'dart:async';

import 'package:fair_dice/fair_dice.dart' show drawDie, verifyReveal;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

/// How many rematches each chain scenario takes, so four games are played.
const int _rematches = 3;

/// One played game, as the room's sockets saw it.
class _Played {
  _Played({
    required this.winner,
    required this.gameOverSeq,
    required this.verifyUrl,
    required this.rolls,
  });

  final int winner;
  final int gameOverSeq;
  final String verifyUrl;

  /// Every `rolled` frame's `d`, in order, as the seat on turn received it.
  final List<Map<String, Object?>> rolls;
}

/// Everything one scenario carries from game to game.
class _Rig {
  _Rig({
    required this.scenario,
    required this.harness,
    required this.code,
    required this.seats,
    required this.names,
  });

  final String scenario;
  final ServerHarness harness;
  final String code;

  /// Seat number to the live seat (socket, number, token).
  final Map<int, WireTestSeat> seats;
  final Map<int, String> names;

  /// Every `game_id` and `chain_commit` seen so far, to prove none repeats.
  final List<String> gameIds = <String>[];
  final List<String> chainCommits = <String>[];

  /// `seq` of the last frame seen on the room, for the "+1" rules.
  int seq = 0;

  /// The chain the room is on, as the last `room` frame said.
  int chainIndex = 0;

  /// Games finished so far, one-based in messages.
  int gamesPlayed = 0;

  String ctx(String step) => 'scenario=$scenario game=${gamesPlayed + 1} '
      'step="$step" (dice are not seeded; the fixture follows the face the '
      'server drew, so the scenario name and game number reproduce this)';

  WireTestSeat seat(int number) => seats[number]!;

  List<int> get numbers => (seats.keys.toList()..sort());
}

/// Next frame on [client], which must be of [type]; any other frame, or no
/// frame, fails with [ctx] and [who] so the failure says where it stopped.
Future<Map<String, Object?>> _expect(
  WireTestClient client,
  String type,
  String who,
  String ctx,
) async {
  final Map<String, Object?> frame;
  try {
    frame = await client.next();
  } on TestFailure catch (error) {
    throw TestFailure('$who: expected a "$type" frame and ${error.message} '
        '[$ctx]');
  } on StateError catch (error) {
    throw TestFailure('$who: expected a "$type" frame but the socket was '
        'closed (${error.message}) [$ctx]');
  }
  if (frame['t'] != type) {
    throw TestFailure('$who: expected a "$type" frame but got '
        '"${frame['t']}": ${frame['d']} [$ctx]');
  }
  return frame;
}

Map<String, Object?> _data(Map<String, Object?> frame) =>
    frame['d']! as Map<String, Object?>;

/// Rewrites the engine state of [code]'s room so [seat] holds [row], leaving
/// phase, queue, seq and every other seat as the server has them.
void _setTokens(ServerHarness harness, String code, int seat, List<int> row) {
  final Room room = harness.registry.lookup(code)!;
  final Map<String, Object?> json = room.game!.toJson();
  (json['tokens']! as List<Object?>)[seat] = row;
  room.game = engine.GameState.fromJson(json);
}

/// The seat that wins the next game: the two seats take turns, the higher
/// seat first, so a rematch is also proven after each seat's win.
int _winnerFor(_Rig rig) => rig.numbers[(rig.gamesPlayed + 1) % 2];

/// After a frame that ends or continues a turn, reads each socket up to and
/// including the next `turn`, allowing one `turn_passed` before it (sections
/// 12.1 and 21.3 item 4).
Future<void> _drainToTurn(
  _Rig rig,
  List<WireTestSeat> everyone,
  String where,
) async {
  for (final WireTestSeat s in everyone) {
    Map<String, Object?> next =
        await _expectAny(s.client, 'seat ${s.seat} waiting for turn', where);
    if (next['t'] == 'turn_passed') {
      rig.seq = _data(next)['seq']! as int;
      next = await _expect(
          s.client, 'turn', 'seat ${s.seat} after turn_passed', where);
    } else if (next['t'] != 'turn') {
      throw TestFailure('seat ${s.seat}: expected turn or turn_passed, got '
          '"${next['t']}": ${next['d']} [$where]');
    }
    rig.seq = _data(next)['seq']! as int;
  }
}

/// Plays the running game of [rig] to a natural win over the wire. Returns
/// what the sockets saw. Fails with the scenario and game if the room stops
/// answering in a way the turn loop (sections 12 and 21) does not allow.
Future<_Played> _playToWin(_Rig rig, {required int winner}) async {
  final List<Map<String, Object?>> rolls = <Map<String, Object?>>[];
  for (int step = 0; step < 80; step++) {
    final Room? room = rig.harness.registry.lookup(rig.code);
    if (room == null) {
      throw TestFailure('the room vanished while playing [${rig.ctx('play')}]');
    }
    if (room.state != RoomState.playing) {
      throw TestFailure('room state is ${room.state} while playing '
          '[${rig.ctx('play')}]');
    }
    final engine.GameState game = room.game!;
    final int onTurn = game.currentSeat;
    final WireTestSeat actor = rig.seat(onTurn);
    final List<WireTestSeat> everyone = rig.numbers.map(rig.seat).toList();
    final String where = rig.ctx('play step $step seat $onTurn');

    if (game.phase == engine.GamePhase.awaitRoll) {
      // One short of home on token 3, three home: any face the server draws
      // has a legal move on this seat (50 + 6 is still on the track).
      if (onTurn == winner) {
        _setTokens(rig.harness, rig.code, onTurn, <int>[57, 57, 57, 50]);
      }
      actor.client.send('roll', <String, Object?>{});
      Map<String, Object?>? ownRolled;
      for (final WireTestSeat s in everyone) {
        final Map<String, Object?> rolled = await _expect(
            s.client, 'rolled', 'seat ${s.seat} after roll by $onTurn', where);
        if (s.seat == onTurn) {
          ownRolled = rolled;
        }
      }
      final Map<String, Object?> rolledData = _data(ownRolled!);
      rolls.add(rolledData);
      final List<Object?> legal = rolledData['legal']! as List<Object?>;
      rig.seq = rolledData['seq']! as int;
      if (legal.isEmpty) {
        await _drainToTurn(rig, everyone, where);
      }
      continue;
    }

    if (game.phase == engine.GamePhase.awaitMove) {
      if (onTurn != winner) {
        // The seat that is not winning plays an ordinary legal move.
        final int token = engine.legalTokens(game).first;
        actor.client.send('move', <String, Object?>{'token': token});
        for (final WireTestSeat s in everyone) {
          final Map<String, Object?> moved = await _expect(
              s.client, 'moved', 'seat ${s.seat} after a plain move', where);
          rig.seq = _data(moved)['seq']! as int;
        }
        await _drainToTurn(rig, everyone, where);
        continue;
      }
      final int face = engine.defaultFace(game)!;
      _setTokens(rig.harness, rig.code, onTurn, <int>[57, 57, 57, 57 - face]);
      actor.client.send('move', <String, Object?>{'token': 3});
      Map<String, Object?>? over;
      for (final WireTestSeat s in everyone) {
        final Map<String, Object?> moved = await _expect(
            s.client, 'moved', 'seat ${s.seat} after the winning move', where);
        expect(_data(moved)['to'], 57,
            reason: 'the fixture placed token 3 on ${57 - face} and the '
                'face is $face, so the move must land on 57 [$where]');
        final Map<String, Object?> gameOver = await _expect(
            s.client, 'game_over', 'seat ${s.seat} after moved', where);
        if (s.seat == onTurn) {
          over = gameOver;
        }
      }
      final Map<String, Object?> overData = _data(over!);
      expect(overData['winner'], winner,
          reason: 'the fixture made seat $winner win [$where]');
      final _Played played = _Played(
        winner: overData['winner']! as int,
        gameOverSeq: overData['seq']! as int,
        verifyUrl: overData['verify_url']! as String,
        rolls: rolls,
      );
      rig.seq = played.gameOverSeq;
      rig.gamesPlayed++;
      return played;
    }
    throw TestFailure('unexpected engine phase ${game.phase} [$where]');
  }
  throw TestFailure('no winner after 80 steps [${rig.ctx('play')}]');
}

/// Asserts the played game's record and chain: rolls numbered from 1, every
/// reveal hashing to the previous one, the first hashing to [chainCommit],
/// and every face recomputable from the game's own id and seeds.
void _expectRecord(
  _Rig rig,
  _Played played, {
  required String gameId,
  required String clientSeeds,
  required String chainCommit,
}) {
  final String ctx = rig.ctx('record of game ${rig.gamesPlayed}');
  expect(played.verifyUrl, endsWith('/v/$gameId'),
      reason: 'game_over.verify_url must point at this game\'s own record '
          '/v/$gameId, got "${played.verifyUrl}" [$ctx]');
  expect(rig.harness.registry.verifyStore.load(gameId), isNotNull,
      reason: 'the finished game $gameId must have a stored verify record '
          '[$ctx]');
  expect(played.rolls, isNotEmpty, reason: 'no roll was played [$ctx]');
  String parent = chainCommit;
  int expectedK = 1;
  for (final Map<String, Object?> roll in played.rolls) {
    expect(roll['k'], expectedK,
        reason: 'rolls of a fresh game number from 1 and count up by one; '
            'got k=${roll['k']}, expected $expectedK [$ctx]');
    final String reveal = roll['reveal']! as String;
    expect(verifyReveal(reveal: reveal, parent: parent), isTrue,
        reason: 'reveal k=$expectedK does not hash to its parent '
            '$parent: the game is not on the chain whose commitment '
            '$chainCommit the room published [$ctx]');
    expect(roll['value'], drawDie(reveal, gameId, clientSeeds, expectedK, 0),
        reason: 'face of roll k=$expectedK is not drawDie(reveal, game_id, '
            'client_seeds, k, 0) for game $gameId seeds "$clientSeeds" '
            '[$ctx]');
    parent = reveal;
    expectedK++;
  }
}

/// What starting a game (auto-start or host) looks like on one socket: any
/// number of `seat_seed`, then `game_started`, then the opening `turn`.
/// Returns `game_started`'s `d` and the opening turn frame's `seq`.
Future<(Map<String, Object?>, int, List<Map<String, Object?>>)> _readStart(
  _Rig rig,
  WireTestSeat seat,
  String step,
) async {
  final String ctx = rig.ctx(step);
  final List<Map<String, Object?>> seeds = <Map<String, Object?>>[];
  for (int i = 0; i < 6; i++) {
    final Map<String, Object?> frame =
        await _expectAny(seat.client, 'seat ${seat.seat} start burst', ctx);
    if (frame['t'] == 'seat_seed') {
      seeds.add(_data(frame));
      continue;
    }
    if (frame['t'] != 'game_started') {
      throw TestFailure('seat ${seat.seat}: expected seat_seed or '
          'game_started in the start burst, got "${frame['t']}": '
          '${frame['d']} [$ctx]');
    }
    final Map<String, Object?> started = _data(frame);
    final Map<String, Object?> turn =
        await _expect(seat.client, 'turn', 'seat ${seat.seat} opening', ctx);
    expect(_data(turn)['seat'], started['turn'],
        reason: 'the opening turn names the seat game_started named [$ctx]');
    expect(_data(turn)['seq'], (started['seq']! as int) + 1,
        reason: 'the opening turn is game_started.seq + 1 (13.1) [$ctx]');
    return (started, _data(turn)['seq']! as int, seeds);
  }
  throw TestFailure('seat ${seat.seat}: no game_started within six frames of '
      'the accepted rematch: the rematch did not start a game [$ctx]');
}

Future<Map<String, Object?>> _expectAny(
    WireTestClient client, String who, String ctx) async {
  try {
    return await client.next();
  } on TestFailure catch (error) {
    throw TestFailure('$who: ${error.message} [$ctx]');
  } on StateError catch (error) {
    throw TestFailure('$who: socket closed (${error.message}) [$ctx]');
  }
}

final RegExp _hex16 = RegExp(r'^[0-9a-f]{16}$');
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Starts game 1 of [rig] from its LOBBY as the host would, no seeds set, and
/// returns game_started's `d`. Used by every scenario for the first game, so
/// the chain under test is game 1 then rematches.
Future<Map<String, Object?>> _hostStart(_Rig rig,
    {bool setSeeds = false}) async {
  final List<int> nums = rig.numbers;
  if (setSeeds) {
    for (final int n in nums) {
      rig
          .seat(n)
          .client
          .send('set_seed', <String, Object?>{'client_seed': 'g1-seat$n-seed'});
      for (final int m in nums) {
        await _expect(rig.seat(m).client, 'seat_seed', 'seat $m after seed $n',
            rig.ctx('game 1 seeds'));
      }
    }
  }
  final WireTestSeat host = rig.seat(nums.first);
  host.client.send('start_game', <String, Object?>{});
  Map<String, Object?>? started;
  for (final int n in nums) {
    final (Map<String, Object?> s, int seq, _) =
        await _readStart(rig, rig.seat(n), 'game 1 start');
    started ??= s;
    rig.seq = seq;
  }
  rig.gameIds.add(started!['game_id']! as String);
  return started;
}

void _expectLobbyReset(
  _Rig rig,
  Map<String, Object?> room, {
  required int requester,
  required List<int> ready,
  required String ctx,
}) {
  expect(room['state'], 'LOBBY', reason: 'rematch reopens the room [$ctx]');
  expect(room['game_id'], isNull, reason: '16.2 item 1 game_id [$ctx]');
  expect(room['client_seeds'], isNull,
      reason: '16.2 item 1 client_seeds [$ctx]');
  expect(room['turn'], isNull, reason: '16.2 item 1 turn [$ctx]');
  expect(room['winner'], isNull, reason: '16.2 item 1 winner [$ctx]');
  expect(room['chain_index'], rig.chainIndex + 1,
      reason: '16.2 item 2: chain_index +1 from ${rig.chainIndex} [$ctx]');
  final String commit = room['chain_commit']! as String;
  expect(commit, matches(_hex64), reason: 'chain_commit shape [$ctx]');
  expect(rig.chainCommits, isNot(contains(commit)),
      reason: '16.2 item 2: chain_commit must be new for every game of the '
          'room, never one seen before; seen ${rig.chainCommits} [$ctx]');
  expect(room['seq'], rig.seq + 1,
      reason: '16.2 item 5: seq advances by exactly one from ${rig.seq} '
          '[$ctx]');
  expect(room['rematch'], <String, Object?>{'by': requester, 'ready': ready},
      reason: '16.2 item 3 / 16.6 rematch snapshot [$ctx]');
  final List<Object?> seats = room['seats']! as List<Object?>;
  expect(seats, hasLength(rig.seats.length),
      reason: 'the same seats stay seated [$ctx]');
  for (final Object? entry in seats) {
    final Map<String, Object?> seat = entry! as Map<String, Object?>;
    final int number = seat['seat']! as int;
    expect(rig.names[number], seat['name'],
        reason: 'seat $number keeps its name across the rematch [$ctx]');
    expect(seat['tokens'], <int>[-1, -1, -1, -1],
        reason: 'seat $number tokens reset [$ctx]');
    expect(seat['client_seed'], isNull,
        reason: 'seat $number client_seed reset [$ctx]');
    expect(seat['seed_origin'], isNull,
        reason: 'seat $number seed_origin reset [$ctx]');
  }
}

/// Both seats send `rematch` per section 16, [first] asking first. With
/// [seeds], each seat sets its own seed for the new chain in the rematch
/// LOBBY before the last accept. With [doubleTap], [first] taps twice. The
/// new game starts by itself on the last accept; returns its `game_started`
/// `d`, the new chain's commitment and the opening turn's `seq`.
Future<({Map<String, Object?> started, String chainCommit, String seeds})>
    _rematchAll(
  _Rig rig, {
  required int first,
  bool seeds = false,
  bool doubleTap = false,
}) async {
  final List<int> nums = rig.numbers;
  final int second = nums.firstWhere((int n) => n != first);
  final String ctx = rig.ctx('rematch asked by seat $first');
  final WireTestSeat a = rig.seat(first);
  final WireTestSeat b = rig.seat(second);

  final String id1 = a.client.send('rematch', <String, Object?>{});
  final Map<String, Object?> aRoom =
      await _expect(a.client, 'room', 'seat $first own rematch', ctx);
  final Map<String, Object?> bRoom =
      await _expect(b.client, 'room', 'seat $second broadcast', ctx);
  expect(aRoom['re'], id1, reason: 'requester copy carries re [$ctx]');
  expect(bRoom.containsKey('re'), isFalse,
      reason: 'the other seat\'s copy carries no re [$ctx]');
  _expectLobbyReset(rig, _data(aRoom),
      requester: first, ready: <int>[first], ctx: ctx);
  final Map<String, Object?> lobby = _data(aRoom);
  expect(_data(bRoom)['seq'], lobby['seq'],
      reason: 'one counter per room [$ctx]');
  final String chainCommit = lobby['chain_commit']! as String;
  rig.chainCommits.add(chainCommit);
  rig.chainIndex = lobby['chain_index']! as int;
  rig.seq = lobby['seq']! as int;

  if (doubleTap) {
    final String id = a.client.send('rematch', <String, Object?>{});
    final Map<String, Object?> again =
        await _expect(a.client, 'room', 'seat $first double tap', ctx);
    expect(again['re'], id, reason: 'double tap answers the sender [$ctx]');
    expect(_data(again)['seq'], rig.seq,
        reason: '16.3: a seat already ready changes nothing, seq does not '
            'advance [$ctx]');
    expect(
        _data(again)['rematch'],
        <String, Object?>{
          'by': first,
          'ready': <int>[first]
        },
        reason: '16.3: ready list unchanged by a double tap [$ctx]');
  }

  String clientSeeds = '';
  if (seeds) {
    final List<String> parts = <String>[];
    for (final int n in nums) {
      final String seed = 'chain${rig.chainIndex}-seat$n-seed';
      rig.seat(n).client.send('set_seed', <String, Object?>{
        'client_seed': seed,
      });
      parts.add('$n:$seed');
      for (final int m in nums) {
        final Map<String, Object?> frame = await _expectAny(
            rig.seat(m).client, 'seat $m after set_seed by $n', ctx);
        if (frame['t'] == 'error') {
          throw TestFailure('16.5: set_seed for the new chain_index '
              '${rig.chainIndex} by seat $n was refused with '
              '${_data(frame)['code']} on seat $m [$ctx]');
        }
        expect(frame['t'], 'seat_seed',
            reason: 'seat $m expected seat_seed after seat $n set a seed '
                'on chain ${rig.chainIndex}, got ${frame['d']} [$ctx]');
        expect(_data(frame)['origin'], 'player', reason: 'origin [$ctx]');
        rig.seq = _data(frame)['seq']! as int;
      }
    }
    clientSeeds = parts.join('|');
    // Once per seat per chain: a second seed on the same chain is refused.
    final WireTestSeat again = rig.seat(first);
    again.client.send('set_seed', <String, Object?>{'client_seed': 'late'});
    final Map<String, Object?> refused =
        await _expectAny(again.client, 'seat $first second seed', ctx);
    expectErrorFrame(refused, 'SEED_ALREADY_SET',
        because: '16.5: SEED_ALREADY_SET applies to a second seed within '
            'the same chain_index ($ctx)');
  }

  final String id2 = b.client.send('rematch', <String, Object?>{});
  final Map<String, Object?> bAccept =
      await _expect(b.client, 'room', 'seat $second accept', ctx);
  final Map<String, Object?> aAccept =
      await _expect(a.client, 'room', 'seat $first sees accept', ctx);
  expect(bAccept['re'], id2, reason: 'accepter copy carries re [$ctx]');
  expect(aAccept.containsKey('re'), isFalse,
      reason: 'the first asker\'s copy carries no re [$ctx]');
  expect(_data(bAccept)['seq'], rig.seq + 1,
      reason: '16.3: an accept advances seq by one [$ctx]');
  expect(
      _data(bAccept)['rematch'],
      <String, Object?>{
        'by': first,
        'ready': nums,
      },
      reason: '16.3 / 16.4: the room that records the last acceptance lists '
          'every seat ready [$ctx]');
  rig.seq = _data(bAccept)['seq']! as int;

  // 16.4: no third tap. The game starts by itself right behind that room.
  Map<String, Object?>? started;
  final List<int> order = <int>[second, first];
  int openingSeq = 0;
  for (final int n in order) {
    final (Map<String, Object?> s, int seq, List<Map<String, Object?>> sd) =
        await _readStart(rig, rig.seat(n), 'auto start after rematch');
    if (seeds) {
      expect(sd, isEmpty,
          reason: 'every seat already seeded this chain, so the server '
              'draws no seat_seed [$ctx]');
    } else {
      expect(sd, hasLength(nums.length),
          reason: '11.2: a seat with no seed gets a server seed at the '
              'start, one seat_seed per seat [$ctx]');
    }
    if (started != null) {
      expect(s['game_id'], started['game_id'],
          reason: 'both seats are in the same new game [$ctx]');
    }
    started ??= s;
    openingSeq = seq;
  }
  rig.seq = openingSeq;
  final String gameId = started!['game_id']! as String;
  expect(gameId, matches(_hex16), reason: 'game_id shape [$ctx]');
  expect(rig.gameIds, isNot(contains(gameId)),
      reason: 'a rematch is a new game id; seen ${rig.gameIds} [$ctx]');
  rig.gameIds.add(gameId);
  if (seeds) {
    expect(started['client_seeds'], clientSeeds,
        reason: 'client_seeds are the seeds set for the new chain [$ctx]');
  }
  expect(rig.harness.registry.lookup(rig.code)!.state, RoomState.playing,
      reason: 'the room is PLAYING again [$ctx]');
  return (started: started, chainCommit: chainCommit, seeds: clientSeeds);
}

/// The room as a returning client sees it: a fresh socket `resume`s the
/// seat of [number], reads `seat_assigned` and `room`, and the old socket of
/// that seat is replaced. Asserts the snapshot is a fresh game.
Future<void> _expectFreshSnapshot(
  _Rig rig,
  List<WireTestClient> clients,
  int number, {
  required Map<String, Object?> started,
  required String chainCommit,
  required int chainIndex,
}) async {
  final String ctx = rig.ctx('fresh snapshot by resume of seat $number');
  final WireTestSeat old = rig.seat(number);
  final WireTestClient fresh = await WireTestClient.connect(rig.harness.wsUri);
  clients.add(fresh);
  fresh.send('resume', <String, Object?>{
    'code': rig.code,
    'seat_token': old.token,
  });
  await _expect(fresh, 'seat_assigned', 'resume of seat $number', ctx);
  final Map<String, Object?> room =
      _data(await _expect(fresh, 'room', 'resume of seat $number', ctx));
  rig.seats[number] =
      WireTestSeat(client: fresh, seat: number, token: old.token);
  expect(room['state'], 'PLAYING', reason: 'a started game is PLAYING [$ctx]');
  expect(room['game_id'], started['game_id'], reason: 'game_id [$ctx]');
  expect(room['client_seeds'], started['client_seeds'],
      reason: 'client_seeds [$ctx]');
  expect(room['winner'], isNull, reason: 'a fresh game has no winner [$ctx]');
  expect(room['rematch'], isNull,
      reason: '16.4: rematch is null from game_started on [$ctx]');
  expect(room['chain_index'], chainIndex, reason: 'chain_index [$ctx]');
  expect(room['chain_commit'], chainCommit, reason: 'chain_commit [$ctx]');
  expect(room['seq'], rig.seq,
      reason: 'snapshot seq equals the last frame\'s seq [$ctx]');
  final Map<String, Object?> turn = room['turn']! as Map<String, Object?>;
  expect(turn['phase'], 'await_roll',
      reason: 'a fresh game awaits the first roll [$ctx]');
  expect(turn['k'], 0, reason: 'no roll made yet in a fresh game [$ctx]');
  expect(turn['seat'], started['turn'], reason: 'turn seat [$ctx]');
  for (final Object? entry in room['seats']! as List<Object?>) {
    final Map<String, Object?> seat = entry! as Map<String, Object?>;
    expect(seat['tokens'], <int>[-1, -1, -1, -1],
        reason: 'seat ${seat['seat']} has every token in the yard [$ctx]');
    expect(seat['name'], rig.names[seat['seat']],
        reason: 'names are those of game 1 [$ctx]');
  }
}

Future<_Rig> _buildRig(
  String scenario,
  ServerHarness harness,
  List<WireTestClient> clients,
) async {
  await harness.start();
  final WireTestLobby lobby = await buildWireTestLobby(harness.wsUri, clients);
  final _Rig rig = _Rig(
    scenario: scenario,
    harness: harness,
    code: lobby.code,
    seats: <int, WireTestSeat>{
      lobby.host.seat: lobby.host,
      lobby.guest.seat: lobby.guest,
    },
    names: <int, String>{lobby.host.seat: 'Host', lobby.guest.seat: 'Guest'},
  );
  rig.chainIndex = lobby.guestRoom['chain_index']! as int;
  rig.chainCommits.add(lobby.guestRoom['chain_commit']! as String);
  rig.seq = lobby.guestRoom['seq']! as int;
  return rig;
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

  // Plays game 1 and [_rematches] more, [askers] choosing who asks first
  // before each rematch. Shared by the chain scenarios.
  Future<_Rig> chain(
    String scenario, {
    required int Function(_Rig rig, int rematchNumber) asker,
    bool seeds = false,
    bool doubleTap = false,
    bool freshSnapshots = false,
  }) async {
    final _Rig rig = await _buildRig(scenario, harness, clients);
    // The room frame a joiner got is the lobby's; game 1 starts as ever.
    Map<String, Object?> started = await _hostStart(rig, setSeeds: seeds);
    String gameId = started['game_id']! as String;
    String clientSeeds = started['client_seeds']! as String;
    String commit = rig.chainCommits.first;
    for (int r = 0; r <= _rematches; r++) {
      if (freshSnapshots) {
        await _expectFreshSnapshot(rig, clients, rig.numbers.last,
            started: started, chainCommit: commit, chainIndex: rig.chainIndex);
      }
      final _Played played = await _playToWin(rig, winner: _winnerFor(rig));
      _expectRecord(rig, played,
          gameId: gameId, clientSeeds: clientSeeds, chainCommit: commit);
      if (r == _rematches) {
        break;
      }
      final next = await _rematchAll(rig,
          first: asker(rig, r), seeds: seeds, doubleTap: doubleTap && r == 1);
      started = next.started;
      gameId = started['game_id']! as String;
      clientSeeds = started['client_seeds']! as String;
      commit = next.chainCommit;
    }
    expect(rig.gamesPlayed, _rematches + 1,
        reason: 'four games were played in one room [${rig.ctx('end')}]');
    expect(rig.gameIds.toSet(), hasLength(_rematches + 1),
        reason: 'four distinct game ids [${rig.ctx('end')}]');
    expect(rig.chainCommits.toSet(), hasLength(_rematches + 1),
        reason: 'four distinct chains [${rig.ctx('end')}]');
    return rig;
  }

  test('C1 host asks first every time: game, rematch x3, four games', () async {
    await chain('host-asks-first',
        asker: (_Rig rig, int r) => rig.numbers.first, freshSnapshots: true);
  });

  test('C2 the guest asks first every time', () async {
    await chain('guest-asks-first',
        asker: (_Rig rig, int r) => rig.numbers.last);
  });

  test('C3 the seats alternate who asks first, with a double tap', () async {
    await chain('alternating-askers',
        asker: (_Rig rig, int r) =>
            r.isEven ? rig.numbers.first : rig.numbers.last,
        doubleTap: true);
  });

  test('C4 both seats set their own seed on every new chain', () async {
    await chain('seeds-every-chain',
        asker: (_Rig rig, int r) =>
            r.isEven ? rig.numbers.last : rig.numbers.first,
        seeds: true);
  });

  test('C5 the host leaves after game 2: the other seat asks (16.4, 18)',
      () async {
    final _Rig rig =
        await _buildRig('host-leaves-after-game-2', harness, clients);
    final int hostSeat = rig.numbers.first;
    final int guestSeat = rig.numbers.last;
    Map<String, Object?> started = await _hostStart(rig);
    String gameId = started['game_id']! as String;
    String clientSeeds = started['client_seeds']! as String;
    String commit = rig.chainCommits.first;

    // Games 1 and 2, one rematch between them, both seats.
    _expectRecord(rig, await _playToWin(rig, winner: _winnerFor(rig)),
        gameId: gameId, clientSeeds: clientSeeds, chainCommit: commit);
    final second = await _rematchAll(rig, first: hostSeat);
    started = second.started;
    gameId = started['game_id']! as String;
    clientSeeds = started['client_seeds']! as String;
    commit = second.chainCommit;
    _expectRecord(rig, await _playToWin(rig, winner: _winnerFor(rig)),
        gameId: gameId, clientSeeds: clientSeeds, chainCommit: commit);
    final String ctx = rig.ctx('host leaves a FINISHED room');

    // 18.3: leave_room in FINISHED frees the seat; player_left to everyone.
    final String leaveId =
        rig.seat(hostSeat).client.send('leave_room', <String, Object?>{});
    final Map<String, Object?> leaverCopy = await _expect(
        rig.seat(hostSeat).client, 'player_left', 'host leaving', ctx);
    final Map<String, Object?> guestCopy = await _expect(
        rig.seat(guestSeat).client, 'player_left', 'guest watching', ctx);
    expect(leaverCopy['re'], leaveId, reason: '18.3 leaver copy has re [$ctx]');
    expect(_data(guestCopy)['seat'], hostSeat, reason: 'who left [$ctx]');
    expect(_data(guestCopy)['host_seat'], guestSeat,
        reason: '18.1: host hands on to the lowest seat left [$ctx]');
    rig.seq = _data(guestCopy)['seq']! as int;

    // 16.4 / 18.4: the one seat left asks. A rematch LOBBY opens; with one
    // seat occupied the "at least two seats" condition fails, so no start.
    final WireTestSeat guest = rig.seat(guestSeat);
    final String askId = guest.client.send('rematch', <String, Object?>{});
    final Map<String, Object?> lobbyFrame =
        await _expect(guest.client, 'room', 'guest asks alone', ctx);
    expect(lobbyFrame['re'], askId, reason: 'asker copy has re [$ctx]');
    final Map<String, Object?> lobby = _data(lobbyFrame);
    expect(lobby['state'], 'LOBBY',
        reason: '18.4: the first rematch from a remaining seat opens the '
            'rematch LOBBY [$ctx]');
    expect(
        lobby['rematch'],
        <String, Object?>{
          'by': guestSeat,
          'ready': <int>[guestSeat]
        },
        reason: '16.2 item 3 [$ctx]');
    expect(lobby['host_seat'], guestSeat, reason: '18.1 [$ctx]');
    expect(lobby['seats'], hasLength(1),
        reason: 'the host\'s seat is gone from the room [$ctx]');
    expect(lobby['chain_index'], rig.chainIndex + 1,
        reason: 'a new chain for the next game [$ctx]');
    expect(rig.chainCommits, isNot(contains(lobby['chain_commit'])),
        reason: 'a new chain_commit [$ctx]');
    final String chain3 = lobby['chain_commit']! as String;
    rig.chainCommits.add(chain3);
    rig.chainIndex = lobby['chain_index']! as int;
    rig.seq = lobby['seq']! as int;
    expect(rig.harness.registry.lookup(rig.code)!.state, RoomState.lobby,
        reason: '16.4: one occupied seat never starts a game [$ctx]');

    // The leaver's token names no seat any more (18.3).
    rig.seat(hostSeat).client.send('rematch', <String, Object?>{});
    expectErrorFrame(
        await _expectAny(rig.seat(hostSeat).client, 'leaver rematch', ctx),
        'BAD_SEAT_TOKEN',
        because: '18.3: the leaver holds no seat ($ctx)');

    // 16.9 rule 4 / 18.6: a joiner by code fills the freed seat, accepts,
    // and the game starts when the joiner accepts. The chain continues.
    final WireTestClient joinerClient =
        await WireTestClient.connect(rig.harness.wsUri);
    clients.add(joinerClient);
    joinerClient.send('join_room', <String, Object?>{
      'install': 'testinstall-00000001',
      'code': rig.code,
      'name': 'Newcomer',
    });
    final Map<String, Object?> assigned = await _expect(
        joinerClient, 'seat_assigned', 'joiner after join_room', ctx);
    await _expect(joinerClient, 'room', 'joiner after join_room', ctx);
    final Map<String, Object?> joined =
        await _expect(guest.client, 'player_joined', 'guest sees joiner', ctx);
    rig.seq = _data(joined)['seq']! as int;
    final int joinerSeat = _data(assigned)['seat']! as int;
    final WireTestSeat joiner = WireTestSeat(
        client: joinerClient,
        seat: joinerSeat,
        token: _data(assigned)['seat_token']! as String);
    expect(joinerSeat, isNot(guestSeat), reason: 'a free seat [$ctx]');
    expect(rig.harness.registry.lookup(rig.code)!.state, RoomState.lobby,
        reason: '16.9 rule 4: join_room never starts the game [$ctx]');

    rig.seats
      ..remove(hostSeat)
      ..[joinerSeat] = joiner;
    rig.names
      ..remove(hostSeat)
      ..[joinerSeat] = 'Newcomer';
    joiner.client.send('rematch', <String, Object?>{});
    await _expect(joiner.client, 'room', 'joiner accepts', ctx);
    await _expect(guest.client, 'room', 'guest sees the accept', ctx);
    final List<(Map<String, Object?>, int, List<Map<String, Object?>>)> both =
        <(Map<String, Object?>, int, List<Map<String, Object?>>)>[];
    for (final WireTestSeat s in <WireTestSeat>[joiner, guest]) {
      both.add(await _readStart(rig, s, 'start after the joiner accepts'));
    }
    started = both.first.$1;
    expect(both.last.$1['game_id'], started['game_id'], reason: 'one game');
    rig.seq = both.first.$2;
    gameId = started['game_id']! as String;
    expect(rig.gameIds, isNot(contains(gameId)), reason: 'new game id [$ctx]');
    rig.gameIds.add(gameId);
    clientSeeds = started['client_seeds']! as String;
    commit = chain3;

    // Game 3 with the two seats that are left, then game 4 by one more
    // rematch from the same two: the chain keeps going after a host change.
    _expectRecord(rig, await _playToWin(rig, winner: _winnerFor(rig)),
        gameId: gameId, clientSeeds: clientSeeds, chainCommit: commit);
    final fourth = await _rematchAll(rig, first: joinerSeat);
    gameId = fourth.started['game_id']! as String;
    _expectRecord(rig, await _playToWin(rig, winner: _winnerFor(rig)),
        gameId: gameId,
        clientSeeds: fourth.started['client_seeds']! as String,
        chainCommit: fourth.chainCommit);
    expect(rig.gamesPlayed, 4, reason: 'four games in one room [$ctx]');
  });
}
