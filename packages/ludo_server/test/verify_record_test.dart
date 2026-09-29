// Tests for docs/VERIFY.md sections 1 and 3, against RoomRegistry
// in-process, the way test/turn_loop_test.dart tests the turn loop but one
// level down (no WireServer, no socket): every call below goes straight
// through RoomRegistry's own methods.
//
// A real, natural win (every token of one seat reaching progress 57 through
// ordinary rolls alone) needs on the order of 60+ real rolls
// (test/turn_loop_test.dart's own header names this exact number and the
// combinatorics that make it unreachable by search). This file reaches a
// real win a different way, the same way test/turn_loop_test.dart itself
// forces a room FINISHED for its GAME_OVER tests: by mutating Room.game
// directly, which room.dart's own doc comment says is expected ("order
// 008's turn loop does that by mutating Room.game and Room.state directly").
// Concretely: a room is created, joined, seeded and started for real, so its
// chain, game_id and client_seeds are exactly what a real game would have.
// Then, before a single roll happens, the seat that is NOT on turn has three
// of its four tokens set to progress 57 (home) and the fourth to progress
// 56 -- one square short -- leaving the seat actually on turn's own row
// exactly as start_game left it (every token still in the yard). From there
// every roll is real: test/support/dice_oracle.dart's findSecretForFaces
// picks a server secret (before the room is created) that makes roll k=1
// land on a face that is not a six -- which leaves the on-turn seat no
// legal move, since every one of its tokens is still in the yard (a six is
// the only face that ever does) -- and makes roll k=2 land on exactly a 1,
// the only face that lets the other seat's progress-56 token complete the
// trip to 57 and win. k=1 is driven through the turn timer
// (RoomRegistry.expireTurns(), the FakeClock advanced past turn_seconds),
// so the record's k=1 seat attribution is proven against a real timer roll,
// not merely a client-driven one; k=2 and the winning move are client-driven,
// through roll()/move() directly.

import 'dart:convert';

import 'package:fair_dice/fair_dice.dart' show drawDie, hexEncode;
import 'package:ludo_engine/ludo_engine.dart'
    show GamePhase, GameState, GameWon, Rolled;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';

/// One real roll observed as the game was played, with the seat collected
/// from the RollOk/ExpiredTurn that produced it -- never read back off
/// Room, per the order's own instruction ("collect it from the RollOk
/// results / ExpiredTurns as the game is played, not from the room").
class _CollectedRoll {
  const _CollectedRoll({required this.k, required this.seat});
  final int k;
  final int seat;
}

/// Everything a test needs to assert on, out of one played-to-a-win game.
class _PlayedGame {
  const _PlayedGame({
    required this.registry,
    required this.room,
    required this.finalMove,
    required this.collectedRolls,
    required this.seatA,
    required this.seatB,
    required this.hostName,
    required this.guestName,
    required this.hostSeed,
    required this.guestSeed,
    required this.hostSeatToken,
    required this.guestSeatToken,
    required this.gameId,
    required this.finishedAt,
  });

  final RoomRegistry registry;
  final Room room;
  final MoveOk finalMove;
  final List<_CollectedRoll> collectedRolls;

  /// The seat that rolled first (the timer roll, k=1). Its row is left
  /// exactly as start_game produced it (every token in the yard).
  final int seatA;

  /// The other seat: three tokens already home, one at progress 56, so a
  /// roll of exactly 1 wins.
  final int seatB;

  final String hostName;
  final String guestName;
  final String hostSeed;
  final String guestSeed;
  final String hostSeatToken;
  final String guestSeatToken;
  final String gameId;

  /// The clock's own time at the instant the winning move() call returned.
  final DateTime finishedAt;
}

/// A VerifyStore whose save always throws, so a caller can exercise
/// docs/VERIFY.md section 3's "if save throws ... the game still ends
/// normally" without touching any real storage.
class _ThrowingVerifyStore implements VerifyStore {
  int saveCalls = 0;

  @override
  bool save(String gameId, String json) {
    saveCalls++;
    throw StateError('simulated disk failure (verify_record_test.dart)');
  }

  @override
  String? load(String gameId) => null;

  @override
  int purgeOlderThan(DateTime cutoff) => 0;
}

/// Plays one real game, through RoomRegistry alone, to a real win -- see
/// this file's header comment for exactly how. [clock] is the caller's own
/// FakeClock, advanced here by `turnSeconds + 1` seconds to force the timer
/// roll; the caller is free to advance it further afterwards (the reap()
/// tests below do exactly that).
_PlayedGame _playToWin({
  required FakeClock clock,
  required VerifyStore verifyStore,
  String verifyUrlBase = defaultVerifyUrlBase,
  String hostName = 'Nyx Quillfeather',
  String guestName = 'Ozzy Vexley',
  String hostSeed = 'verify-record-host-seed-nyx',
  String guestSeed = 'verify-record-guest-seed-ozzy',
  int turnSeconds = 15,
}) {
  // game_id's bytes sit at a fixed script offset that no secret ever
  // overlaps (see test/support/scripted_bytes.dart's own header), so it can
  // be predicted from a placeholder secret before the real one is even
  // chosen -- the same trick test/turn_loop_test.dart's own
  // predictedGameId() uses.
  final String predictedGameId = hexEncode(
    buildScript(secret: List<int>.filled(serverSecretDraws, 0))
        .sublist(gameIdOffset, gameIdOffset + gameIdDraws),
  );
  final String clientSeeds = '0:$hostSeed|2:$guestSeed';

  final SteeredSecret steered = findSecretForFaces(
    wanted: const <int>[1, 1],
    gameId: predictedGameId,
    clientSeeds: clientSeeds,
  );

  final RoomRegistry registry = RoomRegistry(
    clock: clock,
    secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
    verifyStore: verifyStore,
    verifyUrlBase: verifyUrlBase,
  );

  final CreateResult createResult = registry.createRoom(
    name: hostName,
    players: 2,
    rules: RulesConfig(turnSeconds: turnSeconds),
  );
  if (createResult is! CreateOk) {
    fail('createRoom failed: $createResult');
  }
  final String code = createResult.room.code;
  final String hostToken = createResult.seat.seatToken;

  final JoinResult joinResult = registry.joinRoom(code: code, name: guestName);
  if (joinResult is! JoinOk) {
    fail('joinRoom failed: $joinResult');
  }
  final String guestToken = joinResult.seat.seatToken;

  final SetSeedResult hostSeeded = registry.setSeed(
    code: code,
    seatToken: hostToken,
    clientSeed: hostSeed,
  );
  if (hostSeeded is! SetSeedOk) {
    fail('host setSeed failed: $hostSeeded');
  }
  final SetSeedResult guestSeeded = registry.setSeed(
    code: code,
    seatToken: guestToken,
    clientSeed: guestSeed,
  );
  if (guestSeeded is! SetSeedOk) {
    fail('guest setSeed failed: $guestSeeded');
  }

  final StartResult startResult =
      registry.startGame(code: code, seatToken: hostToken);
  if (startResult is! StartOk) {
    fail('startGame failed: $startResult');
  }
  final Room room = startResult.room;

  expect(
    room.gameId,
    predictedGameId,
    reason: 'predicted game_id (from buildScript\'s own fixed filler bytes) '
        'did not match the room\'s real game_id; either registry.dart\'s '
        'draw order changed, or test/support/scripted_bytes.dart\'s picture '
        'of it is stale',
  );
  expect(
    room.clientSeeds,
    clientSeeds,
    reason: 'predicted client_seeds did not match the room\'s real '
        'client_seeds',
  );

  final int seatA = room.game!.currentSeat;
  final int seatB = seatA == 0 ? 2 : 0;
  final String seatBToken = seatB == 0 ? hostToken : guestToken;

  // seatB: three tokens already home, one square short. seatA's own row is
  // left exactly as start_game produced it (every token in the yard).
  final Map<String, Object?> gameJson = room.game!.toJson();
  final List<Object?> tokens = gameJson['tokens']! as List<Object?>;
  tokens[seatB] = const <int>[57, 57, 57, 56];
  room.game = GameState.fromJson(gameJson);

  clock.advance(Duration(seconds: turnSeconds + 1));
  final List<ExpiredTurn> expired = registry.expireTurns();
  expect(
    expired.length,
    1,
    reason: 'expected exactly one room\'s segment to have expired; got '
        '${expired.length}',
  );
  final ExpiredTurn timerTurn = expired.single;
  expect(timerTurn.seat, seatA);
  expect(
    timerTurn.roll,
    isNotNull,
    reason: 'seatA was awaiting a roll (its row was left as a fresh, '
        'unstarted game), not a move, when its segment expired',
  );
  final RollOk firstRoll = timerTurn.roll!;
  expect(firstRoll.k, 1);
  final Rolled firstRolled = firstRoll.events.whereType<Rolled>().single;
  expect(
    firstRolled.value,
    1,
    reason: 'steering promised face 1 for k=1; got ${firstRolled.value}',
  );
  expect(
    firstRolled.legal,
    isEmpty,
    reason: 'seatA\'s row is an untouched fresh game (every token in the '
        'yard); a non-six roll must leave no legal move',
  );

  final List<_CollectedRoll> collected = <_CollectedRoll>[
    _CollectedRoll(k: firstRoll.k, seat: timerTurn.seat),
  ];

  expect(room.rollCount, 1);
  expect(
    room.game!.currentSeat,
    seatB,
    reason: 'a no-legal-move roll must pass the turn to the other seat',
  );
  expect(room.game!.phase, GamePhase.awaitRoll);

  final RollResult secondRollResult =
      registry.roll(code: code, seatToken: seatBToken);
  if (secondRollResult is! RollOk) {
    fail('the winning roll (k=2) was rejected: $secondRollResult');
  }
  final RollOk secondRoll = secondRollResult;
  expect(secondRoll.k, 2);
  final Rolled secondRolled = secondRoll.events.whereType<Rolled>().single;
  expect(
    secondRolled.value,
    1,
    reason: 'steering promised face 1 for k=2; got ${secondRolled.value}',
  );
  expect(
    secondRolled.legal,
    <int>[3],
    reason: 'seatB\'s only movable token is index 3 (progress 56, needing '
        'exactly a 1 to reach 57); its other three tokens are already home '
        'and immovable (rule 20)',
  );
  collected.add(_CollectedRoll(k: secondRoll.k, seat: seatB));

  final MoveResult moveResult =
      registry.move(code: code, seatToken: seatBToken, token: 3);
  if (moveResult is! MoveOk) {
    fail('the winning move was rejected: $moveResult');
  }
  final MoveOk win = moveResult;
  final DateTime finishedAt = clock.now;
  final GameWon wonEvent = win.events.whereType<GameWon>().single;
  expect(
    wonEvent.seat,
    seatB,
    reason: 'test setup error: the engine\'s own GameWon event must name '
        'seatB, or this is not actually the winning move',
  );

  return _PlayedGame(
    registry: registry,
    room: room,
    finalMove: win,
    collectedRolls: collected,
    seatA: seatA,
    seatB: seatB,
    hostName: hostName,
    guestName: guestName,
    hostSeed: hostSeed,
    guestSeed: guestSeed,
    hostSeatToken: hostToken,
    guestSeatToken: guestToken,
    gameId: room.gameId!,
    finishedAt: finishedAt,
  );
}

/// `YYYY-MM-DDTHH:MM:SSZ` in UTC, whole seconds -- the exact format
/// docs/VERIFY.md section 1.1 pins for `finished_at`.
String _formatUtcWholeSeconds(DateTime dt) {
  final DateTime utc = dt.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
      '${two(utc.second)}Z';
}

void main() {
  group('the verify record, sections 1 and 3 (shared game, read-only checks)',
      () {
    late FakeClock clock;
    late MemoryVerifyStore store;
    late _PlayedGame played;
    late String rawRecord;
    late Map<String, Object?> record;

    setUpAll(() {
      clock = FakeClock(DateTime.utc(2026, 3, 1, 12));
      store = MemoryVerifyStore(clock);
      played = _playToWin(
        clock: clock,
        verifyStore: store,
        verifyUrlBase: 'https://verify.example.test/v/',
      );
      final String? loaded = played.registry.verifyStore.load(played.gameId);
      expect(
        loaded,
        isNotNull,
        reason: 'test setup error: no record was saved for ${played.gameId} '
            'after a winning move; nothing below can be checked',
      );
      rawRecord = loaded!;
      record = jsonDecode(rawRecord)! as Map<String, Object?>;
    });

    test('exactly the ten keys of the table in section 1.1, no more', () {
      expect(
        record.keys.toSet(),
        <String>{
          'format',
          'game_id',
          'chain_commit',
          'chain_index',
          'chain_length',
          'client_seeds',
          'seeds',
          'rolls',
          'winner',
          'finished_at',
        },
        reason: 'an extra or missing key must fail here, not leak quietly '
            'past a client that only reads the keys it expects; got keys '
            '${record.keys.toList()}',
      );
    });

    test('format is 1', () {
      expect(record['format'], 1);
    });

    test('game_id is room.gameId, 16 lowercase hex', () {
      expect(record['game_id'], played.gameId);
      expect(isWellFormedGameId(played.gameId), isTrue);
    });

    test('chain_commit is room.chain.commit, 64 lowercase hex', () {
      expect(record['chain_commit'], played.room.chain.commit);
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(played.room.chain.commit),
        isTrue,
      );
    });

    test('chain_index is room.chainIndex', () {
      expect(record['chain_index'], played.room.chainIndex);
    });

    test('chain_length is room.chain.chainLength', () {
      expect(record['chain_length'], played.room.chain.chainLength);
    });

    test('client_seeds is exactly the string the dice were drawn with', () {
      expect(record['client_seeds'], played.room.clientSeeds);
    });

    test(
        'seeds: one object per seat, ascending, seat/seed/origin -- both '
        'seats called set_seed, so both origins are "player"', () {
      expect(record['seeds'], <Map<String, Object?>>[
        <String, Object?>{
          'seat': 0,
          'seed': played.hostSeed,
          'origin': 'player'
        },
        <String, Object?>{
          'seat': 2,
          'seed': played.guestSeed,
          'origin': 'player',
        },
      ]);
    });

    test(
        'rolls: k = 1..rollCount with no gap; each reveal/die/seat matches '
        'a real roll of the game', () {
      final List<Map<String, Object?>> rolls =
          (record['rolls']! as List<Object?>).cast<Map<String, Object?>>();
      expect(rolls.length, played.room.rollCount);
      for (int i = 0; i < rolls.length; i++) {
        final int k = i + 1;
        final int expectedSeat = played.collectedRolls
            .firstWhere((_CollectedRoll r) => r.k == k)
            .seat;
        final String expectedReveal = played.room.chain.reveal(k);
        final int expectedDie = drawDie(
          expectedReveal,
          played.gameId,
          played.room.clientSeeds!,
          k,
          0,
        );
        expect(rolls[i]['k'], k, reason: 'rolls[$i].k');
        expect(rolls[i]['seat'], expectedSeat, reason: 'rolls[$i].seat, k=$k');
        expect(rolls[i]['reveal'], expectedReveal,
            reason: 'rolls[$i].reveal, k=$k');
        expect(rolls[i]['die'], expectedDie, reason: 'rolls[$i].die, k=$k');
      }
    });

    test(
        'no reveal for any k above rollCount appears anywhere in the raw '
        'stored string', () {
      final String oneAboveRollCount =
          played.room.chain.reveal(played.room.rollCount + 1);
      final String chainRoot =
          played.room.chain.reveal(played.room.chain.chainLength);
      expect(
        rawRecord.contains(oneAboveRollCount),
        isFalse,
        reason: 'reveal(rollCount + 1 = ${played.room.rollCount + 1}) must '
            'never appear in the stored record',
      );
      expect(
        rawRecord.contains(chainRoot),
        isFalse,
        reason: 'the chain root (reveal(chainLength = '
            '${played.room.chain.chainLength})) must never appear in the '
            'stored record; this game never reached k == chainLength',
      );
    });

    test('winner is the seat of the engine\'s GameWon event', () {
      final GameWon wonEvent =
          played.finalMove.events.whereType<GameWon>().single;
      expect(record['winner'], wonEvent.seat);
      expect(record['winner'], played.seatB);
    });

    test(
        'finished_at is the FakeClock\'s time at the win, UTC, whole '
        'seconds, in the exact format of section 1.1', () {
      expect(record['finished_at'], _formatUtcWholeSeconds(played.finishedAt));
    });

    test(
        'no display name, seat token or room code appears anywhere in the '
        'raw stored string', () {
      final Map<String, String> needles = <String, String>{
        'host display name': played.hostName,
        'guest display name': played.guestName,
        'room code': played.room.code,
        'host seat token': played.hostSeatToken,
        'guest seat token': played.guestSeatToken,
      };
      needles.forEach((String label, String needle) {
        expect(
          rawRecord.contains(needle),
          isFalse,
          reason: 'the $label ("$needle") must never appear in the stored '
              'verify record; raw record: $rawRecord',
        );
      });
    });

    test(
        'the winning MoveOk carries verify_url equal to '
        '<verifyUrlBase><game_id>, for a registry built with a custom '
        'verifyUrlBase', () {
      expect(
        played.finalMove.verifyUrl,
        'https://verify.example.test/v/${played.gameId}',
      );
    });
  });

  test(
      'the record is already loadable at the moment move() has returned, '
      'with no await in between', () {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 3, 5));
    final MemoryVerifyStore store = MemoryVerifyStore(clock);
    final _PlayedGame played = _playToWin(clock: clock, verifyStore: store);

    // registry.move() inside _playToWin above is a plain synchronous call,
    // exactly like every other RoomRegistry method; the load below is the
    // very next statement this test executes after that call's own result
    // was already captured, with nothing awaited in between.
    final String? loadedRightAway = store.load(played.gameId);
    expect(
      loadedRightAway,
      isNotNull,
      reason: 'docs/VERIFY.md section 1: a record is written "at the '
          'moment the game is won, before move() returns the result that '
          'carries verify_url" -- a client that taps Verify the instant '
          'game_over arrives must find the record already there',
    );
  });

  test(
      'a VerifyStore whose save throws still returns MoveOk for the '
      'winning move, with the room FINISHED and verify_url still set', () {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 3, 6));
    final _ThrowingVerifyStore throwingStore = _ThrowingVerifyStore();
    final _PlayedGame played = _playToWin(
      clock: clock,
      verifyStore: throwingStore,
      verifyUrlBase: 'https://verify.example.test/v/',
    );

    expect(
      played.room.state,
      RoomState.finished,
      reason: 'docs/VERIFY.md section 3: "the game still ends normally" '
          'even when save() throws',
    );
    expect(
      played.finalMove.verifyUrl,
      'https://verify.example.test/v/${played.gameId}',
      reason: 'verify_url must still be set on the winning MoveOk even '
          'though the record could not be saved',
    );
    expect(
      throwingStore.saveCalls,
      greaterThanOrEqualTo(1),
      reason: 'test setup error: the registry must actually have called '
          'VerifyStore.save for this to be a real test of the throwing '
          'path',
    );

    // Not asserted: the exact stderr line docs/VERIFY.md section 3 also
    // requires ("verify_record_not_saved game_id=<id> reason=..."). A Zone
    // override of print() would only catch a print()-based logger (the
    // style lib/src/registry.dart's own _declineExpiredSegment already
    // uses elsewhere in this file, with its own "// ignore: avoid_print"),
    // and would miss a stderr.writeln()-based one, which is what the spec's
    // own wording ("written to stderr") more literally suggests; IOOverrides
    // cannot supply a fake Stdout for stderr either, since dart:io's own
    // Stdout class has no public constructor a test can hand it. Genuinely
    // reproducing "stderr, and only stderr, got exactly one matching line"
    // would need a subprocess with its stderr piped and inspected, which is
    // a materially heavier harness than every other assertion in this file.
    // Per the order's own instruction ("only if it is simple; if it is not,
    // say so in your report rather than asserting on it"), this is that
    // report: the log line itself is not asserted on here.
  });

  group('reap() purges verify records older than verifyRetention (section 3)',
      () {
    test('saved, clock advanced verifyRetention + 1 second, reap() -- gone',
        () {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 4, 1));
      final MemoryVerifyStore store = MemoryVerifyStore(clock);
      final _PlayedGame played = _playToWin(clock: clock, verifyStore: store);
      expect(
        store.load(played.gameId),
        isNotNull,
        reason: 'test setup error: the record must exist right after the '
            'win',
      );

      clock.advance(verifyRetention + const Duration(seconds: 1));
      played.registry.reap();

      expect(
        store.load(played.gameId),
        isNull,
        reason: 'docs/VERIFY.md section 3: "reap() also calls '
            'verifyStore.purgeOlderThan(now - verifyRetention)"; a record '
            'saved more than verifyRetention ago must be gone',
      );
    });

    test(
        'saved, clock advanced verifyRetention - 1 second, reap() -- still '
        'there', () {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 4, 1));
      final MemoryVerifyStore store = MemoryVerifyStore(clock);
      final _PlayedGame played = _playToWin(clock: clock, verifyStore: store);
      final String? original = store.load(played.gameId);
      expect(
        original,
        isNotNull,
        reason: 'test setup error: the record must exist right after the '
            'win',
      );

      clock.advance(verifyRetention - const Duration(seconds: 1));
      played.registry.reap();

      expect(
        store.load(played.gameId),
        original,
        reason: 'a record saved less than verifyRetention ago must survive '
            'reap()',
      );
    });
  });
}
