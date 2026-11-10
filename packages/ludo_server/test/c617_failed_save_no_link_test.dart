// Tests for contract C-617 (work/ludo/orders/617-no-dead-verify-link.md),
// decisions D1 and D2: a game whose verification record was not saved hands
// out no verify link. The winning MoveOk carries verify_url == '' (never a
// URL that opens "no record", never a URL that opens another game's record),
// and every frame built from that MoveOk carries the same empty string. The
// game itself ends exactly as it does when the save works.
//
// Nothing here is random. Every game is played from a fixed pair of client
// seeds and a server secret found offline by test/support/dice_oracle.dart,
// so a failure reproduces by running the one test named in its message:
//   cd packages/ludo_server && dart test test/c617_failed_save_no_link_test.dart -N '<test name>'
// Every reason below names the scenario (store behaviour, how the game was
// won, and the seed pair), which is all that is needed to replay it.
//
// How a win is reached: the same way test/verify_record_test.dart reaches
// one. A room is created, joined, seeded and started for real; before a
// single roll, the seat that is not on turn has three tokens home and one at
// progress 56, and the secret is steered so the first roll (k=1, played by
// the turn timer for the seat on turn) is a non-six that passes the turn and
// the second (k=2) is a 1. The other seat then rolls and moves, or lets the
// timer move, for the winning move. The registry cases call RoomRegistry
// directly; the wire cases run the same game over real WebSockets against a
// real WireServer, with the store injected into the registry underneath.
//
// Case letters follow the order's list: (a) control, (b) save returns false,
// (c) save throws, (d) a seat reconnecting after the win, (e) the stderr
// line. (e) is not asserted: dart:io offers no way to capture stderr in
// process, and a child process per case costs more than the line is worth.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' show GameState, GameWon;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

const String _urlBase = 'https://verify.example.test/v/';
const int _turnSeconds = 15;

/// The seed pairs every registry case is run for: the failure must not
/// depend on which game it happens to be.
const List<List<String>> _seedPairs = <List<String>>[
  <String>['c617-host-seed-alpha', 'c617-guest-seed-beta'],
  <String>['c617-host-seed-gamma', 'c617-guest-seed-delta'],
  <String>['c617-h', 'c617-g'],
];

// ---------------------------------------------------------------------
// Store doubles.
// ---------------------------------------------------------------------

/// Saves into memory and counts the calls, so a case can say how many times
/// the registry tried.
class _CountingStore implements VerifyStore {
  _CountingStore(Clock clock) : _inner = MemoryVerifyStore(clock);

  final MemoryVerifyStore _inner;
  int saveCalls = 0;

  @override
  bool save(String gameId, String json) {
    saveCalls++;
    return _inner.save(gameId, json);
  }

  @override
  String? load(String gameId) => _inner.load(gameId);

  @override
  int purgeOlderThan(DateTime cutoff) => _inner.purgeOlderThan(cutoff);
}

/// `save` answers false, as the real stores do when a record for the id
/// already exists.
class _RefusingStore implements VerifyStore {
  int saveCalls = 0;

  @override
  bool save(String gameId, String json) {
    saveCalls++;
    return false;
  }

  @override
  String? load(String gameId) => null;

  @override
  int purgeOlderThan(DateTime cutoff) => 0;
}

/// `save` throws [error], whatever it is (an Error, an Exception, or a bare
/// string: Dart lets anything be thrown).
class _ThrowingStore implements VerifyStore {
  _ThrowingStore(this.error);

  final Object error;
  int saveCalls = 0;

  @override
  bool save(String gameId, String json) {
    saveCalls++;
    throw error;
  }

  @override
  String? load(String gameId) => null;

  @override
  int purgeOlderThan(DateTime cutoff) => 0;
}

// ---------------------------------------------------------------------
// A game armed one move short of a win, through the registry.
// ---------------------------------------------------------------------

class _Armed {
  _Armed({
    required this.registry,
    required this.clock,
    required this.room,
    required this.code,
    required this.gameId,
    required this.seatA,
    required this.seatB,
    required this.seatBToken,
    required this.seeds,
  });

  final RoomRegistry registry;
  final FakeClock clock;
  final Room room;
  final String code;
  final String gameId;

  /// On turn at the start; its row is untouched.
  final int seatA;

  /// Three tokens home, one on 56: a roll of 1 wins.
  final int seatB;
  final String seatBToken;
  final List<String> seeds;
}

final Map<String, SteeredSecret> _steeredCache = <String, SteeredSecret>{};

String _predictedGameId() => hexEncode(
      buildScript(secret: List<int>.filled(serverSecretDraws, 0))
          .sublist(gameIdOffset, gameIdOffset + gameIdDraws),
    );

SteeredSecret _steer(String hostSeed, String guestSeed) {
  return _steeredCache.putIfAbsent(
    '$hostSeed|$guestSeed',
    () => findSecretForFaces(
      wanted: const <int>[1, 1],
      gameId: _predictedGameId(),
      clientSeeds: '0:$hostSeed|2:$guestSeed',
    ),
  );
}

/// Mutates [game] so the seat that is not on turn is one square short.
GameState _armedBoard(GameState game, int seatB) {
  final Map<String, Object?> json = game.toJson();
  final List<Object?> tokens = json['tokens']! as List<Object?>;
  tokens[seatB] = const <int>[57, 57, 57, 56];
  return GameState.fromJson(json);
}

_Armed _arm(VerifyStore store, List<String> seeds, {FakeClock? clock}) {
  final FakeClock theClock = clock ?? FakeClock(DateTime.utc(2026, 11, 10));
  final SteeredSecret steered = _steer(seeds[0], seeds[1]);
  final RoomRegistry registry = RoomRegistry(
    clock: theClock,
    secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
    verifyStore: store,
    verifyUrlBase: _urlBase,
  );
  final CreateResult created = registry.createRoom(
    name: 'Host',
    players: 2,
    rules: RulesConfig(turnSeconds: _turnSeconds),
  );
  if (created is! CreateOk) {
    fail('setup: createRoom failed: $created');
  }
  final String code = created.room.code;
  final JoinResult joined = registry.joinRoom(code: code, name: 'Guest');
  if (joined is! JoinOk) {
    fail('setup: joinRoom failed: $joined');
  }
  final SetSeedResult hostSeeded = registry.setSeed(
    code: code,
    seatToken: created.seat.seatToken,
    clientSeed: seeds[0],
  );
  final SetSeedResult guestSeeded = registry.setSeed(
    code: code,
    seatToken: joined.seat.seatToken,
    clientSeed: seeds[1],
  );
  if (hostSeeded is! SetSeedOk || guestSeeded is! SetSeedOk) {
    fail('setup: setSeed failed: $hostSeeded / $guestSeeded');
  }
  final StartResult started =
      registry.startGame(code: code, seatToken: created.seat.seatToken);
  if (started is! StartOk) {
    fail('setup: startGame failed: $started');
  }
  final Room room = started.room;
  expect(
    room.gameId,
    _predictedGameId(),
    reason: 'setup: the predicted game_id did not match the room\'s; the '
        'draw order in registry.dart and test/support/scripted_bytes.dart '
        'disagree (seeds $seeds)',
  );
  final int seatA = room.game!.currentSeat;
  final int seatB = seatA == 0 ? 2 : 0;
  room.game = _armedBoard(room.game!, seatB);
  return _Armed(
    registry: registry,
    clock: theClock,
    room: room,
    code: code,
    gameId: room.gameId!,
    seatA: seatA,
    seatB: seatB,
    seatBToken: seatB == 0 ? created.seat.seatToken : joined.seat.seatToken,
    seeds: seeds,
  );
}

/// k=1: the timer rolls for the seat on turn, a non-six with no legal move.
void _timerRollsFirst(_Armed a, String why) {
  a.clock.advance(const Duration(seconds: _turnSeconds + 1));
  final List<ExpiredTurn> expired = a.registry.expireTurns();
  expect(expired.length, 1, reason: 'setup ($why): expected one expiry');
  expect(expired.single.roll, isNotNull,
      reason: 'setup ($why): the first expiry must be a roll');
}

/// k=2: seat B rolls a 1; its token 3 is then the only legal move.
void _seatBRolls(_Armed a, String why) {
  final RollResult rolled =
      a.registry.roll(code: a.code, seatToken: a.seatBToken);
  if (rolled is! RollOk) {
    fail('setup ($why): the winning roll was refused: $rolled');
  }
}

MoveOk _winByClient(_Armed a, String why) {
  _timerRollsFirst(a, why);
  _seatBRolls(a, why);
  final MoveResult moved =
      a.registry.move(code: a.code, seatToken: a.seatBToken, token: 3);
  if (moved is! MoveOk) {
    fail('setup ($why): the winning move was refused: $moved');
  }
  expect(moved.events.whereType<GameWon>(), isNotEmpty,
      reason: 'setup ($why): the move did not win');
  return moved;
}

ExpiredTurn _winByTimer(_Armed a, String why) {
  _timerRollsFirst(a, why);
  _seatBRolls(a, why);
  a.clock.advance(const Duration(seconds: _turnSeconds + 1));
  final List<ExpiredTurn> expired = a.registry.expireTurns();
  expect(expired.length, 1, reason: 'setup ($why): expected one expiry');
  expect(expired.single.move, isNotNull,
      reason: 'setup ($why): the timer was owed a move, not a roll');
  expect(expired.single.move!.events.whereType<GameWon>(), isNotEmpty,
      reason: 'setup ($why): the timer move did not win');
  return expired.single;
}

/// Everything about a winning move that must not depend on whether the
/// record was stored, as a comparable map. The verify link is left out: it
/// is the one thing that is allowed to differ.
Map<String, Object?> _fingerprint(MoveOk m, Room room) => <String, Object?>{
      'movedSeq': m.movedSeq,
      'gameOverSeq': m.gameOverSeq,
      'turnSeq': m.turnSeq,
      'turnPassedSeq': m.turnPassedSeq,
      'nextDeadlineMs': m.nextDeadlineMs,
      'face': m.face,
      'events': <String>[for (final Object e in m.events) '${e.runtimeType}'],
      'winner': m.events.whereType<GameWon>().single.seat,
      'roomSeq': room.seq,
      'rollCount': room.rollCount,
      'state': '${room.state}',
    };

/// The frames a timer-played win publishes, with game_over's verify_url
/// taken out so two runs can be compared.
List<Map<String, Object?>> _framesWithoutLink(List<OutFrame> frames) {
  return <Map<String, Object?>>[
    for (final OutFrame f in frames)
      <String, Object?>{
        'type': f.type,
        'data': <String, Object?>{
          for (final MapEntry<String, Object?> e in f.data.entries)
            if (!(f.type == 'game_over' && e.key == 'verify_url'))
              e.key: e.value,
        },
      },
  ];
}

Map<String, Object?> _gameOverOf(List<OutFrame> frames, String why) {
  final List<OutFrame> over =
      frames.where((OutFrame f) => f.type == 'game_over').toList();
  expect(over.length, 1,
      reason: 'expected exactly one game_over frame ($why); frame types: '
          '${<String>[for (final OutFrame f in frames) f.type]}');
  return over.single.data;
}

// ---------------------------------------------------------------------
// The wire side: a real WireServer, real WebSockets.
// ---------------------------------------------------------------------

class _WireOutcome {
  _WireOutcome({
    required this.gameId,
    required this.winnerFrames,
    required this.guestFrames,
    required this.resumedRooms,
    required this.finished,
  });

  final String gameId;

  /// Every frame the winning seat's socket received from the winning roll
  /// on, up to and including game_over.
  final List<Map<String, Object?>> winnerFrames;

  /// The same on the other seat's socket.
  final List<Map<String, Object?>> guestFrames;

  /// The `room` frame `d` each seat got when it resumed after the game
  /// ended, keyed by seat.
  final Map<int, Map<String, Object?>> resumedRooms;

  final bool finished;

  Map<String, Object?> get winnerGameOver => winnerFrames
          .firstWhere((Map<String, Object?> f) => f['t'] == 'game_over')['d']!
      as Map<String, Object?>;
}

Future<_WireOutcome> _playOverWire(
  VerifyStore store,
  List<String> seeds, {
  required bool byTimer,
  required List<WireTestClient> clients,
  required List<WireServer> servers,
}) async {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 10));
  final SteeredSecret steered = _steer(seeds[0], seeds[1]);
  final RoomRegistry registry = RoomRegistry(
    clock: clock,
    secure: ScriptedBytesRandom(buildScript(secret: steered.secret)),
    verifyStore: store,
    verifyUrlBase: _urlBase,
  );
  final WireServer server = WireServer(
    registry: registry,
    rateLimiter: RateLimiter(clock: clock),
    clock: clock,
    automaticTurnExpiry: false,
  );
  servers.add(server);
  await server.start(address: InternetAddress.loopbackIPv4, port: 0);
  final Uri uri =
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  final WireTestLobby lobby = await buildWireTestLobby(
    uri,
    clients,
    rules: const <String, Object?>{'turn_seconds': _turnSeconds},
  );
  expect(<int>[lobby.host.seat, lobby.guest.seat], <int>[0, 2],
      reason: 'the fixed 2 player seat mapping changed (host=0, guest=2), '
          'so the seed prediction in this file is stale');
  lobby.host.client
      .send('set_seed', <String, Object?>{'client_seed': seeds[0]});
  await receiveType(lobby.host.client, 'seat_seed');
  lobby.guest.client
      .send('set_seed', <String, Object?>{'client_seed': seeds[1]});
  await receiveType(lobby.guest.client, 'seat_seed');
  lobby.host.client.send('start_game', <String, Object?>{});
  final Map<String, Object?> started = (await receiveType(
    lobby.host.client,
    'game_started',
  ))['d']! as Map<String, Object?>;
  await expectOpeningTurn(lobby.host.client, started['turn']);
  await receiveType(lobby.guest.client, 'game_started');
  await expectOpeningTurn(lobby.guest.client, started['turn']);

  final int seatA = started['turn']! as int;
  final int seatB = seatA == 0 ? 2 : 0;
  final WireTestSeat winner = seatB == 0 ? lobby.host : lobby.guest;
  final WireTestSeat other = seatB == 0 ? lobby.guest : lobby.host;
  final Room room = registry.lookup(lobby.code)!;
  room.game = _armedBoard(room.game!, seatB);

  // k=1, by the timer, for seat A.
  clock.advance(const Duration(seconds: _turnSeconds + 1));
  server.runTurnExpiryOnce();
  await receiveType(lobby.host.client, 'turn', maxFrames: 8);
  await receiveType(lobby.guest.client, 'turn', maxFrames: 8);

  // k=2, by seat B over the wire.
  winner.client.send('roll', <String, Object?>{});
  await drainUntil(winner.client, 'rolled', maxFrames: 8);
  await drainUntil(other.client, 'rolled', maxFrames: 8);

  if (byTimer) {
    clock.advance(const Duration(seconds: _turnSeconds + 1));
    server.runTurnExpiryOnce();
  } else {
    winner.client.send('move', <String, Object?>{'token': 3});
  }
  final List<Map<String, Object?>> winnerFrames =
      await drainUntil(winner.client, 'game_over', maxFrames: 8);
  final List<Map<String, Object?>> guestFrames =
      await drainUntil(other.client, 'game_over', maxFrames: 8);

  // (d): both seats come back after the game ended.
  final Map<int, Map<String, Object?>> resumed = <int, Map<String, Object?>>{};
  for (final WireTestSeat seat in <WireTestSeat>[lobby.host, lobby.guest]) {
    seat.client.send('resume', <String, Object?>{
      'code': lobby.code,
      'seat_token': seat.token,
    });
    final Map<String, Object?> frame =
        await receiveType(seat.client, 'room', maxFrames: 6);
    resumed[seat.seat] = frame['d']! as Map<String, Object?>;
  }

  return _WireOutcome(
    gameId: started['game_id']! as String,
    winnerFrames: winnerFrames,
    guestFrames: guestFrames,
    resumedRooms: resumed,
    finished: room.state == RoomState.finished,
  );
}

/// Every string anywhere in [value], depth first.
Iterable<String> _allStrings(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is Map) {
    for (final Object? v in value.values) {
      yield* _allStrings(v);
    }
  } else if (value is List) {
    for (final Object? v in value) {
      yield* _allStrings(v);
    }
  }
}

/// A frame's seq and type, for comparing two runs frame by frame.
List<String> _shape(List<Map<String, Object?>> frames) => <String>[
      for (final Map<String, Object?> f in frames)
        '${f['t']}#${(f['d']! as Map<String, Object?>)['seq']}',
    ];

void main() {
  for (final List<String> seeds in _seedPairs) {
    final String seedLabel = 'seeds ${seeds[0]}/${seeds[1]}';

    group('registry, win by a client move, $seedLabel', () {
      late Map<String, Object?> controlPrint;
      late MoveOk control;
      late String controlGameId;

      setUp(() {
        final _CountingStore store = _CountingStore(FakeClock(DateTime.utc(1)));
        final _Armed a = _arm(store, seeds);
        control = _winByClient(a, 'control');
        controlGameId = a.gameId;
        controlPrint = _fingerprint(control, a.room);
      });

      test(
          '(a) control: the store saves, verify_url is <base><game_id> and '
          'the record is loadable', () {
        final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 10));
        final _CountingStore store = _CountingStore(clock);
        final _Armed a = _arm(store, seeds, clock: clock);
        final MoveOk win = _winByClient(a, '(a) saving store');
        expect(win.verifyUrl, '$_urlBase${a.gameId}',
            reason: '(a) a saved record must give verify_url '
                '<base><game_id>; saving store, win by client move, '
                '$seedLabel, got ${win.verifyUrl}');
        expect(win.verifyUrl, isNotEmpty);
        expect(store.load(a.gameId), isNotNull,
            reason: '(a) the record must be loadable once the link is out; '
                '$seedLabel');
        expect(store.saveCalls, 1);
      });

      test(
          '(b) save returns false: verify_url is the empty string, and '
          'the game ends exactly as the control does', () {
        final _RefusingStore store = _RefusingStore();
        final _Armed a = _arm(store, seeds);
        final MoveOk win = _winByClient(a, '(b) refusing store');
        expect(win.verifyUrl, isNotNull,
            reason: '(b) verify_url must stay a string, never null (the wire '
                'layer reads it with a bang); refusing store, win by client '
                'move, $seedLabel');
        expect(win.verifyUrl, '',
            reason: '(b) save returned false so no record exists for '
                '${a.gameId}; expected verify_url \'\' but got '
                '\'${win.verifyUrl}\' (refusing store, win by client move, '
                '$seedLabel)');
        expect(_fingerprint(win, a.room), controlPrint,
            reason: '(b) a failed save must not change a single seq, event '
                'or the winner; control game_id $controlGameId, refusing '
                'store, $seedLabel');
        expect(a.room.state, RoomState.finished);
        expect(store.saveCalls, 1,
            reason: '(b) the registry must try the save once, not retry');
      });

      test(
          '(b) a record for this game_id already exists: verify_url is '
          'empty, and the other record is left alone', () {
        final MemoryVerifyStore store = MemoryVerifyStore(FakeClock(
          DateTime.utc(2026, 11, 10),
        ));
        const String other = '{"someone":"else"}';
        expect(store.save(_predictedGameId(), other), isTrue);
        final _Armed a = _arm(store, seeds);
        final MoveOk win = _winByClient(a, '(b) preloaded store');
        expect(win.verifyUrl, '',
            reason: '(b) the id already held another record, so this game '
                'has none and its link would open that one; expected \'\' '
                'but got \'${win.verifyUrl}\' (preloaded store, $seedLabel)');
        expect(store.load(a.gameId), other,
            reason: '(b) a refused save must change nothing in the store');
        expect(_fingerprint(win, a.room), controlPrint);
      });

      final Map<String, Object> throwers = <String, Object>{
        'StateError': StateError('simulated disk failure'),
        'FileSystemException':
            const FileSystemException('No space left on device', '/tmp/x'),
        'a bare string': 'disk full',
      };
      throwers.forEach((String label, Object error) {
        test(
            '(c) save throws $label: verify_url is empty, the game is '
            'finished, nothing else differs from the control', () {
          final _ThrowingStore store = _ThrowingStore(error);
          final _Armed a = _arm(store, seeds);
          final MoveOk win = _winByClient(a, '(c) throwing store ($label)');
          expect(win.verifyUrl, '',
              reason: '(c) save threw $label; expected verify_url \'\' but '
                  'got \'${win.verifyUrl}\' (throwing store, win by client '
                  'move, $seedLabel)');
          expect(a.room.state, RoomState.finished,
              reason: '(c) a throwing store must never cost the players a '
                  'finished game; $seedLabel');
          expect(_fingerprint(win, a.room), controlPrint,
              reason: '(c) a throwing save must not change a seq, an event '
                  'or the winner; throwing store ($label), $seedLabel');
          expect(store.saveCalls, 1);
        });
      });

      test(
          'a replayed winning move and a roll after a failed-save win are '
          'refused, and do not try to save again', () {
        final _RefusingStore store = _RefusingStore();
        final _Armed a = _arm(store, seeds);
        _winByClient(a, 'replay');
        final MoveResult again =
            a.registry.move(code: a.code, seatToken: a.seatBToken, token: 3);
        expect(again, isA<MoveFailure>(),
            reason: 'a second move after the game ended must be refused, '
                'not answered with a second game_over and a link; got '
                '$again (refusing store, $seedLabel)');
        final RollResult roll =
            a.registry.roll(code: a.code, seatToken: a.seatBToken);
        expect(roll, isA<RollFailure>(),
            reason: 'a roll against a finished room must be refused; got '
                '$roll ($seedLabel)');
        expect(store.saveCalls, 1,
            reason: 'a refused replay must not reach the store again');
      });
    });

    group('registry, win by the turn timer, $seedLabel', () {
      late List<Map<String, Object?>> controlFrames;
      late Map<String, Object?> controlPrint;

      setUp(() {
        final _Armed a =
            _arm(_CountingStore(FakeClock(DateTime.utc(1))), seeds);
        final ExpiredTurn expired = _winByTimer(a, 'timer control');
        controlFrames = _framesWithoutLink(buildExpiryFrames(expired));
        controlPrint = _fingerprint(expired.move!, a.room);
      });

      test('(a) control: the timer win carries <base><game_id>', () {
        final _Armed a =
            _arm(_CountingStore(FakeClock(DateTime.utc(1))), seeds);
        final ExpiredTurn expired = _winByTimer(a, '(a) timer');
        final Map<String, Object?> over =
            _gameOverOf(buildExpiryFrames(expired), '(a) timer, $seedLabel');
        expect(over['verify_url'], '$_urlBase${a.gameId}',
            reason: '(a) timer win, saving store, $seedLabel');
      });

      test(
          '(b) save returns false: the timer\'s game_over carries '
          'verify_url \'\' and the same frames and seqs as the control', () {
        final _Armed a = _arm(_RefusingStore(), seeds);
        final ExpiredTurn expired = _winByTimer(a, '(b) timer');
        final List<OutFrame> frames = buildExpiryFrames(expired);
        final Map<String, Object?> over =
            _gameOverOf(frames, '(b) timer, $seedLabel');
        expect(over.containsKey('verify_url'), isTrue,
            reason: '(b) game_over must still carry the verify_url key; '
                '$over');
        expect(over['verify_url'], '',
            reason: '(b) timer win after a refused save; expected \'\' but '
                'got \'${over['verify_url']}\' (refusing store, $seedLabel)');
        expect(_framesWithoutLink(frames), controlFrames,
            reason: '(b) every frame and seq must match the control '
                '($seedLabel)');
        expect(_fingerprint(expired.move!, a.room), controlPrint);
      });

      test(
          '(c) save throws: the timer\'s game_over carries verify_url \'\' '
          'and the room is finished', () {
        final _Armed a = _arm(_ThrowingStore(StateError('disk')), seeds);
        final ExpiredTurn expired = _winByTimer(a, '(c) timer');
        final List<OutFrame> frames = buildExpiryFrames(expired);
        final Map<String, Object?> over =
            _gameOverOf(frames, '(c) timer, $seedLabel');
        expect(over['verify_url'], '',
            reason: '(c) timer win after a throwing save; expected \'\' but '
                'got \'${over['verify_url']}\' ($seedLabel)');
        expect(a.room.state, RoomState.finished);
        expect(_framesWithoutLink(frames), controlFrames);
      });
    });
  }

  group('wire, real sockets against a real WireServer', () {
    final List<WireTestClient> clients = <WireTestClient>[];
    final List<WireServer> servers = <WireServer>[];
    const List<String> seeds = <String>[
      'c617-wire-host-seed',
      'c617-wire-guest-seed',
    ];

    tearDown(() async {
      for (final WireTestClient c in clients) {
        await c.close();
      }
      clients.clear();
      for (final WireServer s in servers) {
        await s.close();
      }
      servers.clear();
    });

    for (final bool byTimer in <bool>[false, true]) {
      final String how = byTimer ? 'win by the turn timer' : 'win by a move';
      final String scenario = '$how, seeds ${seeds[0]}/${seeds[1]}';

      test('(a) control, $how: game_over carries <base><game_id>', () async {
        final _WireOutcome out = await _playOverWire(
          _CountingStore(FakeClock(DateTime.utc(1))),
          seeds,
          byTimer: byTimer,
          clients: clients,
          servers: servers,
        );
        expect(out.winnerGameOver['verify_url'], '$_urlBase${out.gameId}',
            reason: '(a) saving store, $scenario');
      });

      test(
          '(b) $how, save returns false: both sockets get game_over with '
          'verify_url \'\', frames and seqs match the control', () async {
        final _WireOutcome control = await _playOverWire(
          _CountingStore(FakeClock(DateTime.utc(1))),
          seeds,
          byTimer: byTimer,
          clients: clients,
          servers: servers,
        );
        final _WireOutcome out = await _playOverWire(
          _RefusingStore(),
          seeds,
          byTimer: byTimer,
          clients: clients,
          servers: servers,
        );
        for (final List<Map<String, Object?>> frames
            in <List<Map<String, Object?>>>[
          out.winnerFrames,
          out.guestFrames
        ]) {
          final Map<String, Object?> over =
              frames.last['d']! as Map<String, Object?>;
          expect(over.containsKey('verify_url'), isTrue,
              reason: '(b) game_over must still carry the key; $over '
                  '($scenario)');
          expect(over['verify_url'], '',
              reason: '(b) expected game_over.verify_url \'\' on every '
                  'socket after a refused save, got \'${over['verify_url']}\' '
                  '($scenario)');
          expect(over['winner'], isA<int>());
        }
        expect(_shape(out.winnerFrames), _shape(control.winnerFrames),
            reason: '(b) the winning seat must see the same frame types and '
                'seqs as in the control ($scenario)');
        expect(_shape(out.guestFrames), _shape(control.guestFrames),
            reason: '(b) the other seat must see the same frame types and '
                'seqs as in the control ($scenario)');
        expect(out.winnerGameOver['winner'], control.winnerGameOver['winner'],
            reason: '(b) the winner must not change ($scenario)');
        expect(out.finished, isTrue);
      });

      test(
          '(c) $how, save throws: game_over carries verify_url \'\' and the '
          'room is finished', () async {
        final _WireOutcome out = await _playOverWire(
          _ThrowingStore(StateError('simulated disk failure')),
          seeds,
          byTimer: byTimer,
          clients: clients,
          servers: servers,
        );
        expect(out.winnerGameOver['verify_url'], '',
            reason: '(c) expected game_over.verify_url \'\' after a throwing '
                'save, got \'${out.winnerGameOver['verify_url']}\' '
                '($scenario)');
        expect(out.finished, isTrue,
            reason: '(c) the room must be FINISHED ($scenario)');
      });

      test(
          '(d) $how, save returns false: a seat that resumes afterwards is '
          'handed no verify link in its room snapshot', () async {
        final _WireOutcome out = await _playOverWire(
          _RefusingStore(),
          seeds,
          byTimer: byTimer,
          clients: clients,
          servers: servers,
        );
        out.resumedRooms.forEach((int seat, Map<String, Object?> room) {
          expect(room['state'], 'FINISHED',
              reason: '(d) the resumed room must say FINISHED ($scenario)');
          if (room.containsKey('verify_url')) {
            expect(room['verify_url'], '',
                reason: '(d) a room snapshot that carries verify_url must '
                    'carry \'\' after a refused save; seat $seat got '
                    '\'${room['verify_url']}\' ($scenario)');
          }
          final List<String> links = <String>[
            for (final String s in _allStrings(room))
              if (s.contains(_urlBase) || s.contains('/v/')) s,
          ];
          expect(links, isEmpty,
              reason: '(d) no string in the resume snapshot may point at a '
                  'verify page when the record was not saved; seat $seat '
                  'got $links in ${jsonEncode(room)} ($scenario)');
        });
      });
    }
  });
}
