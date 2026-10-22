// Order 426 -- server tests for C-426 ("a step the turn timer takes says
// so"), written from work/ludo/orders/C-426-timer-played-says-so.md and
// docs/PROTOCOL.md section 22 only. Orders 427 (server) and 428 (client) are
// handed this file and write the production code against it; nothing here
// was written by reading snapshot.dart's expiry path or game_screen.dart.
//
// On base commit 0917737 (docs/PROTOCOL.md section 22 already written,
// nothing else of D1-D5 built yet): S1, S2 and S4 must be RED, each failing
// because the broadcast frame does not carry a "by" key at all --
// `buildExpiryFrames` (packages/ludo_server/lib/src/snapshot.dart:429) calls
// `buildRolled`/`buildMoved` (snapshot.dart:291, :359) with no `by` argument,
// and neither builder has one to take yet. S3 and S5 must be GREEN already:
// S3 because a client-driven roll or move has never had a `by` key and D1
// does not add one to that path; S5 because `turn_passed`, `turn` and
// `game_over` are untouched by D1 on every path, timer or not.
//
// Every case drives a real, running WireServer (test/support/wire_harness.dart
// -- the same harness turn_expiry_log_test.dart and resume_after_expiry_test.dart
// already use) and reads the frames a connected socket actually receives.
// Nothing here asserts on `buildExpiryFrames`' return value directly: a
// defect that only showed up between that return value and the socket would
// be invisible to a test that stopped at the function call, and this order's
// own text requires reading off the wire instead.
//
// Timing is exact and wall-clock-free throughout: every harness is built
// with `automaticTurnExpiry: false` (order 155/156's seam,
// test/resume_after_expiry_test.dart's own pattern) so the periodic sweep
// never runs on its own, and `_expireAfter` advances the harness's injected
// `FakeClock` past `rules.turn_seconds` (read off the wire, never hardcoded)
// and then calls `WireServer.runTurnExpiryOnce()` once, synchronously.
//
// S2, S4, S5a and S5b need the room to already be in `await_move` with one
// specific legal token, and S1, S3a and S5c need `await_roll`. Rather than
// playing real dice to reach those boards (which section 22 does not
// require of this file, and which the await_roll branches cannot steer
// without a second die-chain-inversion harness this order's file list does
// not include), `_forceGame` below overwrites `Room.game` directly with a
// hand-built `GameState`, the same technique
// test/turn_timer_conformance_test.dart's own `_forceGame` uses, reusing the
// already-started room's own `GameConfig`, `seq` and `rngState`. This is
// legitimate here because what is under test is never the board position --
// it is what the real `WireServer`/`RoomRegistry` do with it once the clock
// and `runTurnExpiryOnce()` actually drive the expiry, broadcasting through
// the same `_hub.broadcast` every other push on this server uses. Every
// fixture's "exactly one legal token" claim is checked against the engine's
// own `legalTokens` before the timer is ever exercised (a "setup requires"
// assertion, not the property under test).
//
// S5c (`await_roll` ending the turn, `turn_passed` carries no `by`) is the
// one case that does need a real, undirected die draw to come out non-6
// (rule 10q queues a 6 regardless of the board and does not end the turn,
// so a 6 would not exercise this branch at all): `_findShutoutGame` tries
// small, fixed integer seeds for `secure: Random(seed)` -- the same
// local, sliding search `turn_timer_conformance_test.dart`'s own
// `_openedTable` runs -- until the room's own first face (recomputed
// offline from `room.chain`, `room.gameId` and `room.clientSeeds` with
// `package:fair_dice`'s `drawDie`, never guessed) is not 6. A failure here
// reproduces exactly by rerunning this file: the seed search is
// deterministic and the seed it found is printed in every failure message
// that depends on it.

import 'dart:math' show Random;

import 'package:fair_dice/fair_dice.dart' show drawDie;
import 'package:ludo_engine/ludo_engine.dart'
    show GamePhase, GameState, legalTokens;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

/// The 4x4 token board `GameState.tokens` requires, same shape as
/// `turn_timer_conformance_test.dart`'s own `_boardFor`: [bySeat] gives the
/// occupied seats' own four progress values; every other seat's row is
/// `[-1, -1, -1, -1]`.
List<List<int>> _boardFor(Map<int, List<int>> bySeat) {
  return <List<int>>[
    for (int seat = 0; seat < 4; seat++)
      List<int>.of(bySeat[seat] ?? const <int>[-1, -1, -1, -1]),
  ];
}

/// Overwrites [room]'s game with a hand-built `GameState`, reusing the
/// `GameConfig` the room's own real `start_game` already fixed (seats,
/// rules, seed), the same technique and the same reason
/// `turn_timer_conformance_test.dart`'s own `_forceGame` documents: what is
/// under test is never the board position, it is what the server's own
/// `expireTurns()` and the wire broadcast on top of it do with it.
void _forceGame(
  Room room, {
  required int currentSeat,
  required GamePhase phase,
  int? roll,
  required Map<int, List<int>> tokens,
}) {
  final GameState base = room.game!;
  // The engine ignores `roll` while rollQueue is on and reads `queue`
  // instead; a single pending face is that queue (ENGINE_API section 10.1).
  final List<int> faces = roll == null ? const <int>[] : <int>[roll];
  room.game = GameState(
    config: base.config,
    tokens: _boardFor(tokens),
    currentSeat: currentSeat,
    phase: phase,
    roll: null,
    sixes: 0,
    winner: null,
    seq: base.seq + 1,
    rngState: base.rngState,
    queue: faces,
  );
}

/// The face `k = 1` will draw for [room], computed offline from its own
/// chain, game id and client seeds -- never guessed, never read off a
/// frame the server has not sent yet. `DiceChain.reveal` does not consume
/// the link.
int _firstFace(Room room) {
  return drawDie(
    room.chain.reveal(1),
    room.gameId!,
    room.clientSeeds!,
    1,
    0,
  );
}

void main() {
  final List<WireTestClient> clients = <WireTestClient>[];
  ServerHarness? harness;

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness?.close();
    harness = null;
  });

  /// A fresh, running two-seat room, host and guest connected, past
  /// `game_started` and its standalone opening `turn` frame on both
  /// sockets (`docs/PROTOCOL.md` section 13.1). No background turn-expiry
  /// timer: only `_expireAfter` below ever drives one, and it does so
  /// synchronously through `runTurnExpiryOnce()`.
  Future<(WireTestLobby, Map<String, Object?>)> _startedLobby({
    Random? secure,
  }) async {
    harness = ServerHarness.build(
      secure: secure,
      automaticTurnExpiry: false,
    );
    await harness!.start();
    final WireTestLobby lobby =
        await buildWireTestLobby(harness!.wsUri, clients, players: 2);

    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> startedData =
        hostStarted['d']! as Map<String, Object?>;
    await expectOpeningTurn(lobby.host.client, startedData['turn']);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startedData['turn']);
    return (lobby, startedData);
  }

  WireTestClient _clientFor(WireTestLobby lobby, int seat) =>
      seat == lobby.host.seat ? lobby.host.client : lobby.guest.client;

  /// `rules.turn_seconds` off the wire (never hardcoded), advanced past on
  /// the harness's injected `FakeClock`, then exactly one synchronous
  /// turn-expiry sweep -- the seam order 155/156 added, reused here rather
  /// than reinvented.
  void _expireAfter(WireTestLobby lobby) {
    final Map<String, Object?> rules =
        lobby.hostRoom['rules']! as Map<String, Object?>;
    final int turnSeconds = rules['turn_seconds']! as int;
    harness!.clock.advance(Duration(seconds: turnSeconds + 1));
    harness!.server.runTurnExpiryOnce();
  }

  group('S1-S2: the frames an expiry produces carry by:"timer"', () {
    test(
        'S1 expiry in await_roll: the broadcast rolled has by == "timer" '
        '(C-426 D2: buildExpiryFrames must pass by: "timer" into '
        'buildRolled for a timer-played roll)', () async {
      final (WireTestLobby lobby, Map<String, Object?> started) =
          await _startedLobby();
      final int onTurn = started['turn']! as int;
      final WireTestClient acting = _clientFor(lobby, onTurn);
      final WireTestClient other = _clientFor(
        lobby,
        onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat,
      );

      _expireAfter(lobby);

      final Map<String, Object?> frame = await acting.next();
      expect(
        frame['t'],
        'rolled',
        reason: 'setup requires the first frame after the expiry to be '
            'rolled (RULES.md rule 16a: a seat that has not rolled is '
            'rolled for); got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(
        data.containsKey('by'),
        isTrue,
        reason: 'C-426 D1/D2 (docs/PROTOCOL.md section 22 item 1): a '
            'rolled frame produced by a turn expiry must carry a "by" key '
            'at all, present only on timer-played frames. Catches: '
            'buildExpiryFrames (packages/ludo_server/lib/src/snapshot.dart:'
            '429) not yet passing by: "timer" into buildRolled '
            '(snapshot.dart:291). Got keys=${data.keys.toList()} data='
            '$data for room ${lobby.code} seat $onTurn.',
      );
      expect(
        data['by'],
        'timer',
        reason: 'C-426 D1: the only value "by" ever takes is the string '
            '"timer"; got ${data['by']} for room ${lobby.code}',
      );

      final Map<String, Object?> theirs = await other.next();
      expect(
        theirs['d'],
        data,
        reason: 'docs/PROTOCOL.md section 12.3: a broadcast push must '
            'reach every socket with the identical payload, by included; '
            'room ${lobby.code}',
      );
    });

    test(
        'S2 expiry in await_move: the broadcast moved has by == "timer" '
        '(C-426 D2: buildExpiryFrames must pass by: "timer" into '
        'buildMoved for a timer-played move)', () async {
      final (WireTestLobby lobby, _) = await _startedLobby();
      final Room room = harness!.registry.lookup(lobby.code)!;
      // Token 0 at progress 10 moves to 12 on a roll of 2 (no capture, not
      // home, so no extra roll and no win: the turn genuinely hands off).
      // Tokens 1 and 2 are in the yard (need a 6, rule 17); token 3 is
      // already home (progress 57, immovable, rule 20). Exactly one legal
      // token, checked below rather than assumed.
      _forceGame(
        room,
        currentSeat: lobby.host.seat,
        phase: GamePhase.awaitMove,
        roll: 2,
        tokens: <int, List<int>>{
          lobby.host.seat: <int>[10, -1, -1, 57],
          lobby.guest.seat: <int>[-1, -1, -1, -1],
        },
      );
      expect(
        legalTokens(room.game!),
        <int>[0],
        reason: 'setup requires exactly one legal token for room '
            '${lobby.code}; got ${legalTokens(room.game!)}',
      );

      _expireAfter(lobby);

      final Map<String, Object?> frame =
          await _clientFor(lobby, lobby.host.seat).next();
      expect(
        frame['t'],
        'moved',
        reason: 'setup requires the first frame after this expiry to be '
            'moved (RULES.md rule 15: the one legal move is played); got '
            '"${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(
        data.containsKey('by'),
        isTrue,
        reason: 'C-426 D1/D2: a moved frame produced by a turn expiry '
            'must carry a "by" key at all. Catches: buildExpiryFrames '
            '(packages/ludo_server/lib/src/snapshot.dart:429) not yet '
            'passing by: "timer" into buildMoved (snapshot.dart:359). Got '
            'keys=${data.keys.toList()} data=$data for room ${lobby.code}.',
      );
      expect(
        data['by'],
        'timer',
        reason: 'C-426 D1: the only value "by" ever takes is the string '
            '"timer"; got ${data['by']} for room ${lobby.code}',
      );
    });
  });

  group('S3: a client-driven roll or move never carries by at all', () {
    test(
        'S3a client roll: the broadcast rolled has no by key at all '
        '(C-426 D2: buildRolled only adds by when it is non-null, so a '
        'client-driven roll is byte-identical to today)', () async {
      final (WireTestLobby lobby, Map<String, Object?> started) =
          await _startedLobby();
      final int onTurn = started['turn']! as int;
      final WireTestClient acting = _clientFor(lobby, onTurn);

      acting.send('roll', <String, Object?>{});
      final Map<String, Object?> frame = await acting.next();
      expect(
        frame['t'],
        'rolled',
        reason: 'setup requires the client\'s own roll to be accepted in '
            'room ${lobby.code}; got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(
        data.containsKey('by'),
        isFalse,
        reason: 'C-426 D2/D7: a client\'s own roll must never carry a '
            '"by" key, present or absent-but-null -- the key itself must '
            'not exist. Catches a buildRolled/buildExpiryFrames change '
            'that always threads a by argument through instead of making '
            'it optional. Got keys=${data.keys.toList()} data=$data for '
            'room ${lobby.code} seat $onTurn.',
      );
    });

    test(
        'S3b client move: the broadcast moved has no by key at all '
        '(C-426 D2: buildMoved only adds by when it is non-null, so a '
        'client-driven move is byte-identical to today)', () async {
      final (WireTestLobby lobby, _) = await _startedLobby();
      final Room room = harness!.registry.lookup(lobby.code)!;
      _forceGame(
        room,
        currentSeat: lobby.host.seat,
        phase: GamePhase.awaitMove,
        roll: 2,
        tokens: <int, List<int>>{
          lobby.host.seat: <int>[10, -1, -1, 57],
          lobby.guest.seat: <int>[-1, -1, -1, -1],
        },
      );
      expect(legalTokens(room.game!), <int>[0]);

      lobby.host.client.send('move', <String, Object?>{'token': 0});
      final Map<String, Object?> frame = await lobby.host.client.next();
      expect(
        frame['t'],
        'moved',
        reason: 'setup requires the client\'s own move to be accepted in '
            'room ${lobby.code}; got "${frame['t']}": ${frame['d']}',
      );
      final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
      expect(
        data.containsKey('by'),
        isFalse,
        reason: 'C-426 D2/D7: a client\'s own move must never carry a '
            '"by" key, present or absent-but-null. Got keys='
            '${data.keys.toList()} data=$data for room ${lobby.code}.',
      );
    });
  });

  test(
      'S4 game_log after one timer step and one client step: the timer '
      'step\'s entry carries by, the client step\'s does not (C-426 D1/D2 '
      'via docs/PROTOCOL.md section 22 item 3 and section 17: game_log '
      'serves each push\'s data exactly as it was broadcast)', () async {
    final (WireTestLobby lobby, _) = await _startedLobby();
    final Room room = harness!.registry.lookup(lobby.code)!;
    // Timer step: same board as S2/S3b, one legal token, no capture, no
    // extra roll, no win, so the expiry hands the turn to the guest.
    _forceGame(
      room,
      currentSeat: lobby.host.seat,
      phase: GamePhase.awaitMove,
      roll: 2,
      tokens: <int, List<int>>{
        lobby.host.seat: <int>[10, -1, -1, 57],
        lobby.guest.seat: <int>[-1, -1, -1, -1],
      },
    );
    expect(legalTokens(room.game!), <int>[0]);

    _expireAfter(lobby);

    final Map<String, Object?> hostMoved = await lobby.host.client.next();
    expect(hostMoved['t'], 'moved',
        reason: 'setup: expected the timer\'s move first; got '
            '"${hostMoved['t']}": ${hostMoved['d']}');
    final Map<String, Object?> hostTurn = await lobby.host.client.next();
    expect(hostTurn['t'], 'turn',
        reason: 'setup: expected the hand-off turn frame next; got '
            '"${hostTurn['t']}": ${hostTurn['d']}');
    expect(
      (hostTurn['d']! as Map<String, Object?>)['seat'],
      lobby.guest.seat,
      reason: 'setup requires this move to hand the turn to the guest',
    );
    // Drain the guest's own copies of the same two broadcasts before the
    // room is forced again, or a later read on this socket would pick up
    // a stale frame instead of the one it is about to ask for.
    final Map<String, Object?> guestMoved = await lobby.guest.client.next();
    expect(guestMoved['t'], 'moved');
    final Map<String, Object?> guestTurn = await lobby.guest.client.next();
    expect(guestTurn['t'], 'turn');

    // Client step: a real move, not a real roll -- a fresh turn always
    // opens in await_roll, and this file does not steer the dice chain, so
    // the room is forced directly into await_move for the guest with one
    // legal token (deterministic: no die is drawn for a move) and the
    // guest's own move is sent for real, through the ordinary wire path,
    // exactly as S3b's client-driven move is.
    _forceGame(
      room,
      currentSeat: lobby.guest.seat,
      phase: GamePhase.awaitMove,
      roll: 3,
      tokens: <int, List<int>>{
        lobby.host.seat: <int>[-1, -1, -1, -1],
        lobby.guest.seat: <int>[5, -1, -1, -1],
      },
    );
    expect(legalTokens(room.game!), <int>[0]);

    lobby.guest.client.send('move', <String, Object?>{'token': 0});
    final Map<String, Object?> guestOwnMove = await lobby.guest.client.next();
    expect(
      guestOwnMove['t'],
      'moved',
      reason: 'setup requires the guest\'s own move, after the hand-off, '
          'to be accepted; got "${guestOwnMove['t']}": '
          '${guestOwnMove['d']}',
    );
    // Token 0 at progress 5 moving to 8 neither wins nor captures nor
    // reaches home, so the turn ends and a mandatory "turn" frame (back to
    // the host) follows the move on both sockets (connection.dart:
    // moved must be followed by exactly one of turn or game_over).
    final Map<String, Object?> guestOwnTurn = await lobby.guest.client.next();
    expect(
      guestOwnTurn['t'],
      'turn',
      reason: 'setup: expected the hand-back turn frame after the '
          'guest\'s own move; got "${guestOwnTurn['t']}": '
          '${guestOwnTurn['d']}',
    );
    // The guest's move (and the turn frame behind it) also broadcast to
    // the host's own socket; both copies have to be drained before the
    // host asks for anything else, or the host's next read would pick up
    // a stale broadcast instead of the game_log answer it is about to
    // request.
    final Map<String, Object?> hostMoveCopy = await lobby.host.client.next();
    expect(
      hostMoveCopy['t'],
      'moved',
      reason: 'setup: expected the host\'s own broadcast copy of the '
          'guest\'s move; got "${hostMoveCopy['t']}": ${hostMoveCopy['d']}',
    );
    final Map<String, Object?> hostTurnCopy = await lobby.host.client.next();
    expect(
      hostTurnCopy['t'],
      'turn',
      reason: 'setup: expected the host\'s own broadcast copy of the '
          'hand-back turn frame; got "${hostTurnCopy['t']}": '
          '${hostTurnCopy['d']}',
    );

    final String requestId =
        lobby.host.client.send('game_log', <String, Object?>{});
    final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
    int? parts;
    int seen = 0;
    while (parts == null || seen < parts) {
      final Map<String, Object?> part = await lobby.host.client.next();
      expect(
        part['t'],
        'game_log',
        reason: 'expected a game_log frame answering request $requestId '
            'in room ${lobby.code}; got "${part['t']}": ${part['d']}',
      );
      expect(part['re'], requestId);
      final Map<String, Object?> partData = part['d']! as Map<String, Object?>;
      parts = partData['parts']! as int;
      seen += 1;
      for (final Object? entry in partData['frames']! as List<Object?>) {
        frames.add(entry! as Map<String, Object?>);
      }
    }

    // Two "moved" entries now exist in the log -- the timer's and the
    // guest's own -- told apart by which seat moved, not by type, since
    // this design (unlike an earlier draft of this file) needs no real die
    // roll at all.
    final List<Map<String, Object?>> movedEntries =
        frames.where((Map<String, Object?> f) => f['t'] == 'moved').toList();
    expect(
      movedEntries,
      hasLength(2),
      reason: 'setup requires exactly two moved entries (the timer\'s and '
          'the guest\'s own) in the game_log for room ${lobby.code}; got '
          '$movedEntries',
    );

    final Map<String, Object?> timerMovedData = movedEntries
        .map((Map<String, Object?> e) => e['d']! as Map<String, Object?>)
        .singleWhere(
          (Map<String, Object?> d) => d['seat'] == lobby.host.seat,
          orElse: () => fail(
            'setup requires a moved entry for seat ${lobby.host.seat} '
            '(the timer\'s step) in room ${lobby.code}; got $movedEntries',
          ),
        );
    expect(
      timerMovedData.containsKey('by'),
      isTrue,
      reason: 'C-426 D1 via section 17: the game_log entry for the timer '
          'step must carry by, exactly as it was broadcast. Got keys='
          '${timerMovedData.keys.toList()} data=$timerMovedData',
    );
    expect(timerMovedData['by'], 'timer');

    final Map<String, Object?> clientMovedData = movedEntries
        .map((Map<String, Object?> e) => e['d']! as Map<String, Object?>)
        .singleWhere(
          (Map<String, Object?> d) => d['seat'] == lobby.guest.seat,
          orElse: () => fail(
            'setup requires a moved entry for seat ${lobby.guest.seat} '
            '(the guest\'s own step) in room ${lobby.code}; got '
            '$movedEntries',
          ),
        );
    expect(
      clientMovedData.containsKey('by'),
      isFalse,
      reason: 'C-426 D1 via section 17: the game_log entry for a '
          'client-driven move must carry no by key at all, exactly as it '
          'was broadcast. Got keys=${clientMovedData.keys.toList()} data='
          '$clientMovedData',
    );
  });

  group(
      'S5: turn_passed, turn and game_over following an expiry never '
      'carry by, whoever caused them (C-426 D1, docs/PROTOCOL.md section '
      '22 item 2)', () {
    test('S5a turn, after an expiry move that hands off, has no by key',
        () async {
      final (WireTestLobby lobby, _) = await _startedLobby();
      final Room room = harness!.registry.lookup(lobby.code)!;
      _forceGame(
        room,
        currentSeat: lobby.host.seat,
        phase: GamePhase.awaitMove,
        roll: 2,
        tokens: <int, List<int>>{
          lobby.host.seat: <int>[10, -1, -1, 57],
          lobby.guest.seat: <int>[-1, -1, -1, -1],
        },
      );
      expect(legalTokens(room.game!), <int>[0]);

      _expireAfter(lobby);

      final Map<String, Object?> moved = await lobby.host.client.next();
      expect(moved['t'], 'moved',
          reason: 'setup: expected moved first; got "${moved['t']}": '
              '${moved['d']}');
      final Map<String, Object?> turn = await lobby.host.client.next();
      expect(
        turn['t'],
        'turn',
        reason: 'setup requires this move to hand the turn off, so a '
            'turn frame must follow; got "${turn['t']}": ${turn['d']}',
      );
      final Map<String, Object?> turnData = turn['d']! as Map<String, Object?>;
      expect(
        turnData.containsKey('by'),
        isFalse,
        reason: 'C-426 D1: turn carries no by, whoever caused it. Catches '
            'a defect that leaked by onto the wrong frame type. Got keys='
            '${turnData.keys.toList()} data=$turnData for room '
            '${lobby.code}.',
      );
    });

    test('S5b game_over, after an expiry move that wins, has no by key',
        () async {
      final (WireTestLobby lobby, _) = await _startedLobby();
      final Room room = harness!.registry.lookup(lobby.code)!;
      // Token 0 at progress 54 needs exactly a 3 to reach 57 (rule 19);
      // the other three tokens are already home. Playing token 0 wins.
      _forceGame(
        room,
        currentSeat: lobby.host.seat,
        phase: GamePhase.awaitMove,
        roll: 3,
        tokens: <int, List<int>>{
          lobby.host.seat: <int>[54, 57, 57, 57],
          lobby.guest.seat: <int>[-1, -1, -1, -1],
        },
      );
      expect(legalTokens(room.game!), <int>[0]);

      _expireAfter(lobby);

      final Map<String, Object?> moved = await lobby.host.client.next();
      expect(moved['t'], 'moved',
          reason: 'setup: expected moved first; got "${moved['t']}": '
              '${moved['d']}');
      final Map<String, Object?> gameOver = await lobby.host.client.next();
      expect(
        gameOver['t'],
        'game_over',
        reason: 'setup requires this move to win the game; got '
            '"${gameOver['t']}": ${gameOver['d']}',
      );
      final Map<String, Object?> gameOverData =
          gameOver['d']! as Map<String, Object?>;
      expect(
        gameOverData.containsKey('by'),
        isFalse,
        reason: 'C-426 D1: game_over carries no by, whoever caused it. '
            'Got keys=${gameOverData.keys.toList()} data=$gameOverData '
            'for room ${lobby.code}.',
      );
    });

    test(
        'S5c turn_passed, after an expiry roll that leaves no legal move, '
        'has no by key', () async {
      // All four of the acting seat's tokens stay in the yard; rule 17
      // means only a 6 can ever leave a yard token, so any non-6 first
      // face leaves no legal move and the forced roll itself ends the
      // turn (PROTOCOL.md section 12.1: rolled, turn_passed, turn). A 6
      // would instead queue (rule 10q) and not end the turn, so this
      // fixture needs the real first face to land on a non-6: found by a
      // small, deterministic seed search, never guessed.
      WireTestLobby? found;
      int? foundSeed;
      for (int seed = 0; seed < 64; seed++) {
        final List<WireTestClient> probeClients = <WireTestClient>[];
        final ServerHarness probeHarness = ServerHarness.build(
          secure: Random(seed),
          automaticTurnExpiry: false,
        );
        await probeHarness.start();
        final WireTestLobby probeLobby = await buildWireTestLobby(
          probeHarness.wsUri,
          probeClients,
          players: 2,
        );
        probeLobby.host.client.send('start_game', <String, Object?>{});
        final Map<String, Object?> probeStarted =
            await receiveType(probeLobby.host.client, 'game_started');
        final Object? probeTurn =
            (probeStarted['d']! as Map<String, Object?>)['turn'];
        await expectOpeningTurn(probeLobby.host.client, probeTurn);
        await receiveType(probeLobby.guest.client, 'game_started');
        await expectOpeningTurn(probeLobby.guest.client, probeTurn);

        final Room probeRoom = probeHarness.registry.lookup(probeLobby.code)!;
        final int face = _firstFace(probeRoom);
        if (face != 6) {
          harness = probeHarness;
          clients.addAll(probeClients);
          found = probeLobby;
          foundSeed = seed;
          break;
        }
        for (final WireTestClient c in probeClients) {
          await c.close();
        }
        await probeHarness.close();
      }
      if (found == null) {
        fail('no seed in 0..63 drew a non-6 first face for this fixture; '
            'test/support ScriptedBytesRandom-based steering would be '
            'needed instead, but that support file is outside this '
            'order\'s file list');
      }
      final WireTestLobby lobby = found;
      final Room room = harness!.registry.lookup(lobby.code)!;
      _forceGame(
        room,
        currentSeat: lobby.host.seat,
        phase: GamePhase.awaitRoll,
        tokens: <int, List<int>>{
          lobby.host.seat: <int>[-1, -1, -1, -1],
          lobby.guest.seat: <int>[-1, -1, -1, -1],
        },
      );

      _expireAfter(lobby);

      final Map<String, Object?> rolled = await lobby.host.client.next();
      expect(
        rolled['t'],
        'rolled',
        reason: 'setup (seed $foundSeed): expected the forced roll first; '
            'got "${rolled['t']}": ${rolled['d']}',
      );
      final Map<String, Object?> rolledData =
          rolled['d']! as Map<String, Object?>;
      expect(
        rolledData['legal'],
        isEmpty,
        reason: 'setup (seed $foundSeed) requires no legal move for the '
            'all-yard acting seat on a non-6; got legal='
            '${rolledData['legal']}',
      );
      final Map<String, Object?> turnPassed = await lobby.host.client.next();
      expect(
        turnPassed['t'],
        'turn_passed',
        reason: 'setup (seed $foundSeed): an empty-legal rolled must be '
            'followed by turn_passed (PROTOCOL.md section 12.1); got '
            '"${turnPassed['t']}": ${turnPassed['d']}',
      );
      final Map<String, Object?> turnPassedData =
          turnPassed['d']! as Map<String, Object?>;
      expect(
        turnPassedData.containsKey('by'),
        isFalse,
        reason: 'C-426 D1: turn_passed carries no by, whoever caused it. '
            'Got keys=${turnPassedData.keys.toList()} data='
            '$turnPassedData for room ${lobby.code} (seed $foundSeed).',
      );
    });
  });
}
