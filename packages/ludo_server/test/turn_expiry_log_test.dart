// Order 136 -- the proof of the `turn-expiry applied` success-path log line,
// written blind against the frozen contract handed to this order, without
// reading whatever `_runTurnExpiry` does or does not print on the base
// commit this branch was cut from. That contract, copied verbatim:
//
//   turn-expiry applied room=<CODE> seat=<N> phase=<await_roll|await_move>
//     frames=<t1+t2+...> seq=<N>
//
//   - Once per ExpiredTurn, after all of that turn's frames have broadcast
//     without throwing. Not once per frame.
//   - Not printed when the publish throws (that path keeps its existing
//     "turn-expiry publish failed ..." line).
//   - Not printed when the sweep expired nothing.
//   - room is the room code; seat is the seat index the server acted for.
//   - phase is await_roll when the segment ran out while the seat still
//     owed a roll, await_move when it ran out while the seat owed a token
//     choice.
//   - frames is the type of each broadcast frame in order, joined with "+",
//     e.g. rolled+turn_passed+turn. Empty list prints frames=none.
//   - seq is the value of seq inside the last broadcast frame's own data
//     map, printed as an integer. Absent or non-int prints seq=-.
//
// This suite is expected to be red on the base commit: the print this
// contract describes does not exist there yet. L1 through L4 pin the
// success path and must fail; L5 is the control that proves a sweep that
// expires nothing stays silent, and must pass on both worlds -- a control
// that agreed with everything would prove nothing about whether the other
// four cases can actually tell the two worlds apart.
//
// Every case below drives a real, running WireServer and reads whatever a
// connected client actually receives on the wire, in arrival order --
// never a value the server also happens to have computed for its own log
// line, per the standing lesson this file exists to re-prove (STATE.md
// lesson 4/26).
//
// Determinism without a real 45-second wait, two different ways:
//   - L1, L2, L3 and L4 need the very first die roll of a fresh two-seat
//     game to land on a chosen face, so which branch of the turn-expiry
//     contract fires is known before a single frame is sent. That reuses
//     the offline chain-inversion search `test/support/dice_oracle.dart`
//     already proves correct (`test/dice_steering_test.dart`) and
//     `test/turn_loop_test.dart` already drives against a live server: a
//     `ScriptedBytesRandom` script built by `test/support/scripted_bytes.dart`
//     makes the room's dice chain, and therefore its first face, a fixed,
//     predictable value.
//   - The turn budget itself is decided by `FakeClock`
//     (`test/turn_timer_test.dart` and `test/turn_expiry_guard_test.dart`'s
//     own mechanism): the room is configured with a short (but valid, docs/RULES.md's 15-second minimum) turn_seconds and
//     the injected clock is advanced past it instantly. What is NOT driven
//     by that clock is `turnExpiryInterval`'s own `Timer.periodic`
//     (`lib/src/wire_server.dart`) -- that timer is real, wall-clock,
//     1-second-period, exactly as `turn_expiry_guard_test.dart`'s C1 case
//     documents, so every case below waits on a real, bounded condition
//     (a frame arriving, or a sweep counter advancing) rather than sleeping
//     a fixed amount of time.
//
// print capture and the key=value line parser below are the same two
// idioms `test/turn_expiry_guard_test.dart` already uses (`runZoned` with a
// `ZoneSpecification.print` override, and a deliberately loose
// space-split/`=`-split parser rather than a byte-for-byte format check),
// reused here rather than reinvented, per this order's own instruction.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// The two fixed client seeds every steered room below uses, and the
/// `client_seeds` string they produce under the fixed 2-player seat mapping
/// (host=0, guest=2, `lib/src/registry.dart`) -- known before a room exists,
/// exactly as `test/turn_loop_test.dart`'s own steering seam works.
const String _hostSeed = 'order136-host-seed';
const String _guestSeed = 'order136-guest-seed';
const String _clientSeeds = '0:$_hostSeed|2:$_guestSeed';

/// The `game_id` any steered room below reports: `buildScript`'s filler-byte
/// formula at the game_id offset does not depend on the secret spliced in
/// ahead of it, so this is fixed before `findSecretForFaces` has even chosen
/// a secret.
String _predictedGameId() {
  final List<int> probe = buildScript(
    secret: List<int>.filled(serverSecretDraws, 0),
  );
  return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
}

/// `key=value` pairs, space-separated, out of one captured print line.
/// Deliberately not a byte-for-byte comparison against the frozen format, so
/// a stray space does not turn a passing fix into a red suite -- the same
/// idiom `test/turn_expiry_guard_test.dart` already uses.
Map<String, String> _tokensOf(String line) {
  final Map<String, String> tokens = <String, String>{};
  for (final String part in line.split(' ')) {
    final int eq = part.indexOf('=');
    if (eq > 0) {
      tokens[part.substring(0, eq)] = part.substring(eq + 1);
    }
  }
  return tokens;
}

/// Every line captured in one test that mentions the applied log this file
/// pins, out of the full set of lines a run captured -- narrowed this way,
/// rather than asserting on `lines` directly, so a stray, unrelated print
/// (housekeeping's own line, or the sweep/publish failure lines this print
/// is not) cannot be mistaken for the line under test.
List<String> _appliedLines(List<String> lines) =>
    lines.where((String line) => line.contains('turn-expiry applied')).toList();

/// Polls [condition] on a real wall clock, failing with [describe]'s message
/// if [timeout] passes first -- a stall is a fast, explicit test failure
/// rather than a hang. Not driven by the injected `FakeClock`:
/// `turnExpiryInterval`'s `Timer.periodic` is real, wall-clock, exactly as
/// `test/turn_expiry_guard_test.dart`'s own `_waitUntil` documents.
Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
  required String Function() describe,
  Duration step = const Duration(milliseconds: 25),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(describe());
    }
    await Future<void>.delayed(step);
  }
}

WireTestSeat _seatFor(WireTestLobby lobby, int seat) =>
    seat == lobby.host.seat ? lobby.host : lobby.guest;

/// A running, steered two-seat game, fresh out of `game_started`, with
/// `onTurn` the seat that must act next. `harness` is left running; the
/// caller is responsible for closing it (via `addTearDown`).
typedef _SteeredGame = ({
  ServerHarness harness,
  WireTestLobby lobby,
  int onTurn,
});

/// Builds a fresh two-seat room whose very first die roll (`k = 1`) is
/// steered to [wanted]'s single face, joins a guest, fixes both seats'
/// client seeds so `client_seeds` matches [_clientSeeds], starts the game
/// with `turn_seconds: 15` (docs/RULES.md's minimum) and drains every handshake frame (including the
/// standalone opening `turn` frame, PROTOCOL section 13.1) on both sockets.
/// [clients] is the caller's own socket list, so its `tearDown` closes
/// whatever this opens.
Future<_SteeredGame> _buildSteeredGame(
  List<WireTestClient> clients,
  List<int> wanted,
) async {
  final String gameId = _predictedGameId();
  final SteeredSecret steered = findSecretForFaces(
    wanted: wanted,
    gameId: gameId,
    clientSeeds: _clientSeeds,
  );
  final ServerHarness harness = ServerHarness.build(
    secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
  );
  await harness.start();

  final WireTestLobby lobby = await buildWireTestLobby(
    harness.wsUri,
    clients,
    players: 2,
    rules: const <String, Object?>{'turn_seconds': 15},
  );
  if (lobby.host.seat != 0 || lobby.guest.seat != 2) {
    fail(
      'this steering seam assumes the fixed 2-player seat mapping host=0, '
      'guest=2 (lib/src/registry.dart); got host=${lobby.host.seat} '
      'guest=${lobby.guest.seat}. If this ever fails, the mapping changed '
      'and this file\'s _clientSeeds needs to change with it.',
    );
  }

  lobby.host.client.send('set_seed', <String, Object?>{
    'client_seed': _hostSeed,
  });
  await receiveType(lobby.host.client, 'seat_seed');
  lobby.guest.client.send('set_seed', <String, Object?>{
    'client_seed': _guestSeed,
  });
  await receiveType(lobby.guest.client, 'seat_seed');

  lobby.host.client.send('start_game', <String, Object?>{});
  final Map<String, Object?> hostStarted = await receiveType(
    lobby.host.client,
    'game_started',
  );
  final Map<String, Object?> startedData =
      hostStarted['d']! as Map<String, Object?>;
  await expectOpeningTurn(lobby.host.client, startedData['turn']);
  await receiveType(lobby.guest.client, 'game_started');
  await expectOpeningTurn(lobby.guest.client, startedData['turn']);

  if (startedData['game_id'] != gameId ||
      startedData['client_seeds'] != _clientSeeds) {
    fail(
      'dice-steering assumption did not hold: predicted game_id=$gameId '
      'client_seeds=$_clientSeeds; got off the wire game_id='
      '${startedData['game_id']} client_seeds=${startedData['client_seeds']}. '
      'test/support/scripted_bytes.dart\'s picture of the registry draw '
      'order may no longer match lib/src/registry.dart.',
    );
  }

  return (harness: harness, lobby: lobby, onTurn: startedData['turn']! as int);
}

/// The frame types received, in order, and the last frame's own `d` map --
/// exactly the two things the contract's `frames=` and `seq=` clauses are
/// measured against, and nothing the server also happens to have computed
/// for its own log line.
typedef _Observed = ({List<String> types, Map<String, Object?> lastData});

/// Reads the frames one expired `await_roll` segment publishes off [client]:
/// always `rolled` first (PROTOCOL section 12.1); followed by `turn_passed`
/// and `turn` if and only if the roll left no legal move -- read from the
/// `legal` field the wire itself reports on the `rolled` frame, not assumed
/// in advance, so this reader is correct regardless of which face was
/// steered.
Future<_Observed> _readRollBranch(WireTestClient client) async {
  final Map<String, Object?> rolled = await client.next(
    timeout: const Duration(seconds: 8),
  );
  expect(
    rolled['t'],
    'rolled',
    reason: 'expected the timer\'s forced roll to broadcast a "rolled" '
        'frame first (docs/RULES.md rule 16a); got "${rolled['t']}": '
        '${rolled['d']}',
  );
  final Map<String, Object?> rolledData = rolled['d']! as Map<String, Object?>;
  final List<Object?> legal = rolledData['legal']! as List<Object?>;
  final List<String> types = <String>['rolled'];
  Map<String, Object?> lastData = rolledData;
  if (legal.isEmpty) {
    final Map<String, Object?> turnPassed = await client.next(
      timeout: const Duration(seconds: 3),
    );
    expect(
      turnPassed['t'],
      'turn_passed',
      reason: 'a forced roll that leaves no legal move must be followed by '
          'turn_passed (PROTOCOL section 12.1); got "${turnPassed['t']}": '
          '${turnPassed['d']}',
    );
    types.add('turn_passed');
    final Map<String, Object?> turn = await client.next(
      timeout: const Duration(seconds: 3),
    );
    expect(
      turn['t'],
      'turn',
      reason: 'turn_passed must be followed by turn for the next seat '
          '(PROTOCOL section 12.1); got "${turn['t']}": ${turn['d']}',
    );
    types.add('turn');
    lastData = turn['d']! as Map<String, Object?>;
  }
  return (types: types, lastData: lastData);
}

/// Reads the frames one expired `await_move` segment publishes off [client]:
/// `moved`, then exactly one of `turn` or `game_over` (PROTOCOL section
/// 12.2 fixes this unconditionally, unlike the roll branch above).
Future<_Observed> _readMoveBranch(WireTestClient client) async {
  final Map<String, Object?> moved = await client.next(
    timeout: const Duration(seconds: 8),
  );
  expect(
    moved['t'],
    'moved',
    reason: 'expected the timer\'s forced move to broadcast a "moved" '
        'frame first (docs/RULES.md rule 15); got "${moved['t']}": '
        '${moved['d']}',
  );
  final Map<String, Object?> after = await client.next(
    timeout: const Duration(seconds: 3),
  );
  expect(
    after['t'],
    anyOf('turn', 'game_over'),
    reason: 'moved must be followed by exactly one of turn or game_over '
        '(PROTOCOL section 12.2); got "${after['t']}": ${after['d']}',
  );
  return (
    types: <String>['moved', after['t']! as String],
    lastData: after['d']! as Map<String, Object?>,
  );
}

/// Order 136's C1/C2/C3-style registry seam: a plain subclass whose override
/// of the one public method the periodic sweep calls counts real
/// invocations, so a real-wall-clock wait for "the sweep has genuinely run
/// N times" (L5's control) is a condition, not a guess at how long a
/// `Timer.periodic` needs.
class _SweepCountingRegistry extends RoomRegistry {
  _SweepCountingRegistry({required Clock clock, required Random secure})
      : super(clock: clock, secure: secure);

  int sweeps = 0;

  @override
  List<ExpiredTurn> expireTurns() {
    sweeps++;
    return super.expireTurns();
  }
}

void main() {
  group('turn-expiry applied -- the success-path log line, order 136', () {
    test(
        'L1: await_roll -- exactly one applied line, room/seat/phase correct, '
        'frames matching what a connected client actually received', () async {
      final List<WireTestClient> clients = <WireTestClient>[];
      final List<String> lines = <String>[];
      late _SteeredGame game;
      late _Observed observed;

      await runZoned(
        () async {
          // Face 6: docs/RULES.md rule 17 -- on the first roll of a fresh
          // game every token is in the yard, so a 6 is the only face that
          // leaves a legal move. This steers the single-frame branch: the
          // forced roll must not end the turn.
          game = await _buildSteeredGame(clients, <int>[6]);
          game.harness.clock.advance(const Duration(seconds: 15));
          observed = await _readRollBranch(
            _seatFor(game.lobby, game.onTurn).client,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            lines.add(line);
          },
        ),
      );
      addTearDown(() async {
        for (final WireTestClient c in clients) {
          await c.close();
        }
        await game.harness.close();
      });

      if (observed.types.length != 1) {
        fail(
          'L1 setup expected the steered six to leave a legal move so '
          'the forced roll alone would not end the turn; instead the '
          'client received ${observed.types.length} frame(s): '
          '${observed.types}. Scenario to reproduce: wanted faces [6], '
          'client_seeds=$_clientSeeds, room ${game.lobby.code}.',
        );
      }

      final List<String> applied = _appliedLines(lines);
      expect(
        applied,
        hasLength(1),
        reason: 'room ${game.lobby.code}, seat ${game.onTurn}: expected '
            'exactly one "turn-expiry applied" line for this one '
            'ExpiredTurn; got ${applied.length}: $applied. All captured '
            'print lines: $lines',
      );
      final Map<String, String> tokens = _tokensOf(applied.single);
      expect(
        tokens['room'],
        game.lobby.code,
        reason: 'line was: "${applied.single}"',
      );
      expect(
        tokens['seat'],
        '${game.onTurn}',
        reason: 'line was: "${applied.single}"',
      );
      expect(
        tokens['phase'],
        'await_roll',
        reason: 'line was: "${applied.single}"',
      );
      expect(
        tokens['frames'],
        observed.types.join('+'),
        reason: 'line was: "${applied.single}"; the client actually '
            'received, in order: ${observed.types}',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
        'L2: seq is the seq inside the last frame the client received, never '
        'a value the server also computed for the log', () async {
      final List<WireTestClient> clients = <WireTestClient>[];
      final List<String> lines = <String>[];
      late _SteeredGame game;
      late _Observed observed;

      await runZoned(
        () async {
          game = await _buildSteeredGame(clients, <int>[6]);
          game.harness.clock.advance(const Duration(seconds: 15));
          observed = await _readRollBranch(
            _seatFor(game.lobby, game.onTurn).client,
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            lines.add(line);
          },
        ),
      );
      addTearDown(() async {
        for (final WireTestClient c in clients) {
          await c.close();
        }
        await game.harness.close();
      });

      final List<String> applied = _appliedLines(lines);
      expect(
        applied,
        hasLength(1),
        reason: 'room ${game.lobby.code}, seat ${game.onTurn}: expected '
            'exactly one "turn-expiry applied" line; got ${applied.length}: '
            '$applied. All captured print lines: $lines. Frames the '
            'client received, in order: ${observed.types}',
      );

      final Object? wireSeq = observed.lastData['seq'];
      expect(
        wireSeq,
        isA<int>(),
        reason: 'setup requires the last frame received '
            '("${observed.types.isEmpty ? '<none>' : observed.types.last}") '
            'to carry an integer seq for this property to mean anything; '
            'got $wireSeq off the wire',
      );

      final Map<String, String> tokens = _tokensOf(applied.single);
      expect(
        tokens['seq'],
        '$wireSeq',
        reason: 'line was: "${applied.single}"; the last frame the '
            'client received on the wire was a '
            '"${observed.types.last}" frame whose own d.seq is $wireSeq '
            '-- the log\'s seq must equal that value, decoded from the '
            'wire, not a value the server separately computed for the '
            'log line (this is the clause standing lesson 4 exists for)',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
        'L3: await_move -- phase=await_move, and frames match what a '
        'connected client actually received for the forced move', () async {
      final List<WireTestClient> clients = <WireTestClient>[];
      final List<String> lines = <String>[];
      late _SteeredGame game;
      late _Observed observed;

      await runZoned(
        () async {
          // Face 6 again, but this time the seat actually rolls (a real
          // client message, not the timer), reaching await_move; the timer
          // is left to expire that segment and play the lowest legal token
          // (docs/RULES.md rule 15) without anyone ever sending `move`.
          game = await _buildSteeredGame(clients, <int>[6]);
          final WireTestSeat onTurnSeat = _seatFor(game.lobby, game.onTurn);
          onTurnSeat.client.send('roll', <String, Object?>{});
          final Map<String, Object?> rolled = await onTurnSeat.client.next();
          expect(
            rolled['t'],
            'rolled',
            reason: 'setup: the manual roll from seat ${game.onTurn} in '
                'room ${game.lobby.code} must be accepted; got '
                '"${rolled['t']}": ${rolled['d']}',
          );
          final Map<String, Object?> rolledData =
              rolled['d']! as Map<String, Object?>;
          final List<Object?> legal = rolledData['legal']! as List<Object?>;
          if (legal.isEmpty) {
            fail(
              'L3 setup expected the steered six to leave at least one '
              'legal move on the fresh board (docs/RULES.md rule 17) so '
              'the game would reach await_move; got an empty legal list '
              'instead off the wire. Scenario to reproduce: wanted faces '
              '[6], client_seeds=$_clientSeeds, room ${game.lobby.code}.',
            );
          }
          game.harness.clock.advance(const Duration(seconds: 15));
          observed = await _readMoveBranch(onTurnSeat.client);
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            lines.add(line);
          },
        ),
      );
      addTearDown(() async {
        for (final WireTestClient c in clients) {
          await c.close();
        }
        await game.harness.close();
      });

      final List<String> applied = _appliedLines(lines);
      expect(
        applied,
        hasLength(1),
        reason: 'room ${game.lobby.code}, seat ${game.onTurn}: expected '
            'exactly one "turn-expiry applied" line for this one '
            'ExpiredTurn; got ${applied.length}: $applied. All captured '
            'print lines: $lines. Frames the client received, in order: '
            '${observed.types}',
      );
      final Map<String, String> tokens = _tokensOf(applied.single);
      expect(
        tokens['room'],
        game.lobby.code,
        reason: 'line was: "${applied.single}"',
      );
      expect(
        tokens['seat'],
        '${game.onTurn}',
        reason: 'line was: "${applied.single}"',
      );
      expect(
        tokens['phase'],
        'await_move',
        reason: 'line was: "${applied.single}"',
      );
      expect(
        tokens['frames'],
        observed.types.join('+'),
        reason: 'line was: "${applied.single}"; the client actually '
            'received, in order: ${observed.types}',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      'L4: one line per turn, not per frame -- a scenario broadcasting '
      'rolled+turn_passed+turn still produces exactly one applied line',
      () async {
        final List<WireTestClient> clients = <WireTestClient>[];
        final List<String> lines = <String>[];
        late _SteeredGame game;
        late _Observed observed;

        await runZoned(
          () async {
            // Face 1: docs/RULES.md rule 17 -- with every token still in the
            // yard, any non-six leaves no legal move, so the forced roll
            // itself ends the turn and PROTOCOL section 12.1 requires
            // rolled+turn_passed+turn, three frames, for this one expiry.
            game = await _buildSteeredGame(clients, <int>[1]);
            game.harness.clock.advance(const Duration(seconds: 15));
            observed = await _readRollBranch(
              _seatFor(game.lobby, game.onTurn).client,
            );
          },
          zoneSpecification: ZoneSpecification(
            print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
              lines.add(line);
            },
          ),
        );
        addTearDown(() async {
          for (final WireTestClient c in clients) {
            await c.close();
          }
          await game.harness.close();
        });

        if (observed.types.length != 3) {
          fail(
            'L4 setup expected the steered non-six to leave no legal move '
            'so the forced roll would end the turn, broadcasting '
            'rolled+turn_passed+turn; instead the client received '
            '${observed.types.length} frame(s): ${observed.types}. '
            'Scenario to reproduce: wanted faces [1], '
            'client_seeds=$_clientSeeds, room ${game.lobby.code}.',
          );
        }

        final List<String> applied = _appliedLines(lines);
        expect(
          applied,
          hasLength(1),
          reason: 'room ${game.lobby.code}, seat ${game.onTurn}: the '
              'client received 3 frames (${observed.types}) for this one '
              'expiry, but the log line must still be printed once per '
              'turn, not once per frame; got ${applied.length} applied '
              'line(s): $applied. All captured print lines: $lines',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
        'L5: silence -- a sweep over a turn that has not expired prints no '
        'applied line at all, across several genuine real sweeps', () async {
      final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
      final _SweepCountingRegistry registry = _SweepCountingRegistry(
        clock: clock,
        secure: Random.secure(),
      );
      final RateLimiter rateLimiter = RateLimiter(clock: clock);
      final WireServer server = WireServer(
        registry: registry,
        rateLimiter: rateLimiter,
        clock: clock,
      );
      final List<WireTestClient> clients = <WireTestClient>[];
      addTearDown(() async {
        for (final WireTestClient c in clients) {
          await c.close();
        }
        await server.close();
      });

      final List<String> lines = <String>[];
      late String code;

      await runZoned(
        () async {
          await server.start(address: InternetAddress.loopbackIPv4, port: 0);
          final Uri uri = Uri(
            scheme: 'ws',
            host: '127.0.0.1',
            port: server.port,
            path: '/',
          );
          final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
          code = lobby.code;
          lobby.host.client.send('start_game', <String, Object?>{});
          final Map<String, Object?> hostStarted = await receiveType(
            lobby.host.client,
            'game_started',
          );
          final Object? startingSeat =
              (hostStarted['d']! as Map<String, Object?>)['turn'];
          await expectOpeningTurn(lobby.host.client, startingSeat);
          await receiveType(lobby.guest.client, 'game_started');
          await expectOpeningTurn(lobby.guest.client, startingSeat);

          // The segment just opened on the injected clock: nothing has
          // expired. Wait for several genuine real sweeps (the periodic
          // timer is real wall-clock, not driven by the injected clock)
          // before checking that none of them printed the applied line --
          // the count is what stops this control passing vacuously because
          // the timer never actually ticked.
          await _waitUntil(
            () => registry.sweeps >= 3,
            timeout: const Duration(seconds: 8),
            describe: () => 'the turn-expiry sweep only ran '
                '${registry.sweeps} time(s) in 8 real seconds for room '
                '$code; the periodic timer may have stopped ticking '
                'entirely, which would make this control meaningless '
                'rather than a genuine silence',
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            lines.add(line);
          },
        ),
      );

      final List<String> applied = _appliedLines(lines);
      expect(
        applied,
        isEmpty,
        reason: 'room $code: a sweep over a turn that has not expired '
            'must print no "turn-expiry applied" line at all; got '
            '${applied.length}: $applied, across ${registry.sweeps} real '
            'sweep(s) that genuinely ran',
      );
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}
