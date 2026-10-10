// Wire tests for `game_log`, docs/PROTOCOL.md section 17, read with the
// `game_log` rows in sections 4, 5 and 7. Every case talks to a real
// `WireServer` on 127.0.0.1, the same way `rematch_test.dart` and
// `turn_loop_test.dart` do.
//
// Two-player rooms sit on seats 0 and 2 (docs/RULES.md rule 2). There is
// no seat 1 in a two-seat game. Seat 0 is the host and is the socket that
// sends `game_log`. Seat 2 stays connected for the whole game and is the
// record the answer is compared against: the order's "seat 1".
//
// Cases 1 and 3 need a game long enough that the log cannot fit in one
// 8192-byte frame, and they need it to end. `turn_loop_test.dart` records
// why a natural win cannot be searched as a die-face prefix. The dice here
// are the server's: `test/support/scripted_bytes.dart` fixes the draw so
// the run repeats, and the client only ever sends `roll` and `move`. Play
// stops once the recorded entries themselves exceed one frame, and one
// token is then placed so the server's own next face (the same
// `chain.reveal` / `drawDie` `RoomRegistry.roll` uses) finishes the game.
// That placement is the board mutation `verify_record_test.dart` and
// `rematch_test.dart` already use to reach FINISHED without a searched
// win. The pushes it produces are still the server's, and the log is
// compared to those pushes, not to a position this file invents.
//
// A part's length is the websocket message as received.
// `test/support/wire_harness.dart`'s `WireTestClient` decodes and drops
// that text. Nothing else under `test/support/` keeps it
// (`dice_oracle.dart`, `engine_search.dart`, `scripted_bytes.dart`,
// `scripted_random.dart`), so the client that does is local to this file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fair_dice/fair_dice.dart' show drawDie;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// docs/PROTOCOL.md section 1, which section 17 applies to every part.
const int _maxFrameBytes = 8192;

/// Entry JSON larger than one frame. The part has to carry these bytes
/// plus its own envelope, so a log that reaches this cannot be one part.
const int _longEntryBytes = 10000;

/// Broadcast push types section 5 / 17 put in the log. Private frames
/// (`error`, `pong`, `seat_assigned`, `game_log`) are not in the set, and
/// a play step that sees one fails instead of recording it.
const Set<String> _logTypes = <String>{
  'room',
  'player_joined',
  'player_left',
  'presence',
  'seat_seed',
  'game_started',
  'rolled',
  'moved',
  'turn_passed',
  'turn',
  'game_over',
};

class _Incoming {
  _Incoming(this.raw, this.frame);

  final String raw;
  final Map<String, Object?> frame;

  int get bytes => utf8.encode(raw).length;
}

class _RawQueue {
  _RawQueue(WebSocket socket) {
    _subscription = socket.listen(
      (Object? raw) {
        final String text = raw is String
            ? raw
            : raw is List<int>
                ? utf8.decode(raw)
                : throw StateError(
                    'websocket payload ${raw.runtimeType} is neither text '
                    'nor bytes',
                  );
        final _Incoming incoming = _Incoming(
          text,
          jsonDecode(text) as Map<String, Object?>,
        );
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(incoming);
        } else {
          _buffered.add(incoming);
        }
      },
      onDone: () {
        _done = true;
        for (final Completer<_Incoming> waiter in _waiting) {
          waiter.completeError(
            StateError('socket closed before a frame arrived'),
          );
        }
        _waiting.clear();
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final Completer<_Incoming> waiter in _waiting) {
          waiter.completeError(error, stackTrace);
        }
        _waiting.clear();
      },
    );
  }

  late final StreamSubscription<dynamic> _subscription;
  final List<_Incoming> _buffered = <_Incoming>[];
  final List<Completer<_Incoming>> _waiting = <Completer<_Incoming>>[];
  bool _done = false;

  Future<_Incoming> next() {
    if (_buffered.isNotEmpty) {
      return Future<_Incoming>.value(_buffered.removeAt(0));
    }
    if (_done) {
      return Future<_Incoming>.error(
        StateError('socket already closed and no frame was pending'),
      );
    }
    final Completer<_Incoming> waiter = Completer<_Incoming>();
    _waiting.add(waiter);
    return waiter.future;
  }

  Future<void> close() => _subscription.cancel();
}

/// Same envelope as `WireTestClient`, plus the text the socket delivered,
/// which a part-size check has to measure unchanged.
class _RawClient {
  _RawClient._(this._socket, this._queue);

  final WebSocket _socket;
  final _RawQueue _queue;
  int _ids = 0;

  static Future<_RawClient> connect(Uri uri) async {
    final WebSocket socket = await WebSocket.connect(uri.toString());
    return _RawClient._(socket, _RawQueue(socket));
  }

  String send(String type, Map<String, Object?> data) {
    final String id = 'test-msg-${++_ids}';
    _socket.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': id,
      'd': data,
    }));
    return id;
  }

  Future<_Incoming> next({
    Duration timeout = const Duration(seconds: 3),
  }) {
    return _queue.next().timeout(
          timeout,
          onTimeout: () => throw TestFailure(
            'expected another frame on this socket within $timeout and '
            'none arrived',
          ),
        );
  }

  Future<void> close() async {
    await _queue.close();
    if (_socket.readyState == WebSocket.open) {
      await _socket.close();
    }
  }
}

class _Seat {
  _Seat({required this.client, required this.seat, required this.token});

  final _RawClient client;
  final int seat;
  final String token;
}

class _Lobby {
  _Lobby({required this.code, required this.host, required this.guest});

  final String code;
  final _Seat host;
  final _Seat guest;
}

class _Ply {
  const _Ply({required this.gameOver, this.nextSeat});

  final bool gameOver;
  final int? nextSeat;
}

class _Part {
  _Part({required this.bytes, required this.frames});

  final int bytes;
  final List<Map<String, Object?>> frames;
}

Map<String, Object?> _data(Map<String, Object?> frame) {
  final Object? data = frame['d'];
  if (data is! Map<String, Object?>) {
    fail('frame "${frame['t']}" has no object d: $data');
  }
  return data;
}

void _remember(List<Map<String, Object?>> record, Map<String, Object?> frame) {
  final Object? type = frame['t'];
  if (type is! String || !_logTypes.contains(type)) {
    fail(
      'recorder saw "${frame['t']}", which is not a broadcast push the '
      'log is allowed to carry: ${frame['d']}',
    );
  }
  record.add(<String, Object?>{
    't': type,
    'd': _data(frame),
  });
}

int _entryBytes(List<Map<String, Object?>> record) {
  var total = 0;
  for (final Map<String, Object?> entry in record) {
    total += utf8.encode(jsonEncode(entry)).length;
  }
  return total;
}

/// FINISHED with a winner, the same direct `Room` mutation
/// `rematch_test.dart` uses. No frame is sent. Case 7 only needs a
/// finished room so `rematch` is legal; the first game's pushes are not
/// what that case compares.
void _forceFinished(ServerHarness harness, String code, {required int winner}) {
  final Room? room = harness.registry.lookup(code);
  if (room == null || room.game == null) {
    fail('room $code has no game to force FINISHED');
  }
  final engine.GameState base = room.game!;
  room.game = engine.GameState(
    config: base.config,
    tokens: <List<int>>[
      for (final List<int> row in base.tokens) List<int>.of(row),
    ],
    currentSeat: winner,
    phase: engine.GamePhase.finished,
    roll: null,
    sixes: 0,
    winner: winner,
    seq: base.seq + 1,
    rngState: base.rngState,
  );
  room.state = RoomState.finished;
}

/// One token sits exactly [face] steps from home. The other three of that
/// seat are already home, so the server's next roll of [face], followed by
/// the one legal move, wins. Opponents stay where they are: the path from
/// progress `57 - face` (51..56) into home does not cross a blockable
/// main-track square.
void _armWinningToken(Room room, int seat, int face) {
  final engine.GameState game = room.game!;
  final List<List<int>> tokens = <List<int>>[
    for (final List<int> row in game.tokens) List<int>.of(row),
  ];
  tokens[seat] = <int>[57, 57, 57, 57 - face];
  room.game = engine.GameState(
    config: game.config,
    tokens: tokens,
    currentSeat: game.currentSeat,
    phase: game.phase,
    roll: game.roll,
    sixes: game.sixes,
    winner: game.winner,
    seq: game.seq,
    rngState: game.rngState,
  );
}

/// The face `RoomRegistry.roll` will draw for `k = rollCount + 1`.
int _serverFace(Room room) {
  final String? gameId = room.gameId;
  final String? clientSeeds = room.clientSeeds;
  if (gameId == null || clientSeeds == null) {
    fail('room ${room.code} has no game_id or client_seeds');
  }
  final int k = room.rollCount + 1;
  return drawDie(room.chain.reveal(k), gameId, clientSeeds, k, 0);
}

_Part _checkPart(
  _Incoming incoming, {
  required String requestId,
  required String gameId,
  required int partIndex,
  required int partCount,
}) {
  final Map<String, Object?> frame = incoming.frame;
  expect(frame['t'], 'game_log');
  expect(
    frame['re'],
    requestId,
    reason: 'each game_log part answers the request id (section 17 rule 2)',
  );
  final Map<String, Object?> data = _data(frame);
  expect(
    data['game_id'],
    gameId,
    reason: 'every part carries the current game_id',
  );
  expect(
    data['part'],
    partIndex,
    reason: 'part runs 1..parts in order',
  );
  expect(
    data['parts'],
    partCount,
    reason: 'every part carries the same parts count',
  );
  final Object? rawFrames = data['frames'];
  if (rawFrames is! List<Object?>) {
    fail('game_log frames must be a list, got $rawFrames');
  }
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  for (final Object? item in rawFrames) {
    if (item is! Map<String, Object?>) {
      fail('a game_log entry must be an object, got $item');
    }
    frames.add(item);
  }
  return _Part(bytes: incoming.bytes, frames: frames);
}

Future<List<_Part>> _readLog(
  _RawClient client,
  String requestId,
  String gameId,
) async {
  final _Incoming first = await client.next();
  if (first.frame['t'] != 'game_log') {
    fail(
      'expected a game_log frame answering $requestId, got '
      '"${first.frame['t']}": ${first.frame['d']}',
    );
  }
  final Object? rawParts = _data(first.frame)['parts'];
  if (rawParts is! int || rawParts < 1 || rawParts > 200) {
    fail('game_log parts must be an int in 1..200, got $rawParts');
  }
  final int partCount = rawParts;
  final List<_Part> parts = <_Part>[
    _checkPart(
      first,
      requestId: requestId,
      gameId: gameId,
      partIndex: 1,
      partCount: partCount,
    ),
  ];
  for (var n = 2; n <= partCount; n++) {
    final _Incoming incoming = await client.next();
    if (incoming.frame['t'] != 'game_log') {
      fail(
        'expected game_log part $n of $partCount, got '
        '"${incoming.frame['t']}": ${incoming.frame['d']}',
      );
    }
    parts.add(
      _checkPart(
        incoming,
        requestId: requestId,
        gameId: gameId,
        partIndex: n,
        partCount: partCount,
      ),
    );
  }
  return parts;
}

List<Map<String, Object?>> _framesOf(List<_Part> parts) {
  return <Map<String, Object?>>[
    for (final _Part part in parts) ...part.frames,
  ];
}

void main() {
  late ServerHarness harness;
  final List<_RawClient> clients = <_RawClient>[];

  setUp(() {
    harness = ServerHarness.build();
  });

  tearDown(() async {
    for (final _RawClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  Future<Uri> start() async {
    await harness.start();
    return harness.wsUri;
  }

  /// Replaces the harness from [setUp] with one whose dice chain is fixed
  /// by [buildScript]. The background turn sweep is off: a push during
  /// these tests comes from a `roll` or `move` the test sent.
  void useScriptedDice() {
    harness = ServerHarness.build(
      secure: ScriptedBytesRandom(
        buildScript(secret: List<int>.filled(serverSecretDraws, 0x3c)),
      ),
      automaticTurnExpiry: false,
    );
  }

  Future<_Lobby> openLobby(Uri uri) async {
    final _RawClient host = await _RawClient.connect(uri);
    clients.add(host);
    host.send('create_room', <String, Object?>{
      'name': 'Host',
      'players': 2,
    });
    final _Incoming hostSeat = await host.next();
    final _Incoming hostRoom = await host.next();
    expect(hostSeat.frame['t'], 'seat_assigned');
    expect(hostRoom.frame['t'], 'room');
    final Map<String, Object?> hostSeatData = _data(hostSeat.frame);
    final String code = _data(hostRoom.frame)['code']! as String;
    final int hostIndex = hostSeatData['seat']! as int;

    final _RawClient guest = await _RawClient.connect(uri);
    clients.add(guest);
    guest.send('join_room', <String, Object?>{
      'code': code,
      'name': 'Guest',
    });
    final _Incoming guestSeat = await guest.next();
    await guest.next(); // room
    await host.next(); // player_joined
    final Map<String, Object?> guestSeatData = _data(guestSeat.frame);
    final int guestIndex = guestSeatData['seat']! as int;
    expect(
      hostIndex,
      0,
      reason: 'the host of a fresh room is seat 0',
    );
    expect(
      guestIndex,
      2,
      reason: 'a two-player room seats the guest at 2, not 1 '
          '(docs/RULES.md rule 2)',
    );
    return _Lobby(
      code: code,
      host: _Seat(
        client: host,
        seat: hostIndex,
        token: hostSeatData['seat_token']! as String,
      ),
      guest: _Seat(
        client: guest,
        seat: guestIndex,
        token: guestSeatData['seat_token']! as String,
      ),
    );
  }

  Future<void> seedBoth(_Lobby lobby) async {
    lobby.host.client.send('set_seed', <String, Object?>{
      'client_seed': 'game-log-host-seed',
    });
    final _Incoming hostCopy = await lobby.host.client.next();
    final _Incoming guestCopy = await lobby.guest.client.next();
    expect(hostCopy.frame['t'], 'seat_seed');
    expect(guestCopy.frame['t'], 'seat_seed');
    lobby.guest.client.send('set_seed', <String, Object?>{
      'client_seed': 'game-log-guest-seed',
    });
    final _Incoming guestOwn = await lobby.guest.client.next();
    final _Incoming hostBroadcast = await lobby.host.client.next();
    expect(guestOwn.frame['t'], 'seat_seed');
    expect(hostBroadcast.frame['t'], 'seat_seed');
  }

  Future<_Incoming> skipToGameStarted(_RawClient client) async {
    _Incoming incoming = await client.next();
    while (incoming.frame['t'] == 'seat_seed') {
      incoming = await client.next();
    }
    if (incoming.frame['t'] != 'game_started') {
      fail(
        'expected game_started, got "${incoming.frame['t']}": '
        '${incoming.frame['d']}',
      );
    }
    return incoming;
  }

  /// Drains the start cascade on both sockets. The record, when passed,
  /// starts at the recorder's `game_started` (seat seeds, if any, are
  /// earlier and are not part of the game log).
  Future<({String gameId, int turn})> startGame(
    _Lobby lobby,
    List<Map<String, Object?>> record,
  ) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    await skipToGameStarted(lobby.host.client);
    final _Incoming hostTurn = await lobby.host.client.next();
    if (hostTurn.frame['t'] != 'turn') {
      fail(
        'expected the opening turn on seat 0, got '
        '"${hostTurn.frame['t']}": ${hostTurn.frame['d']}',
      );
    }
    final _Incoming guestStarted = await skipToGameStarted(lobby.guest.client);
    _remember(record, guestStarted.frame);
    final _Incoming guestTurn = await lobby.guest.client.next();
    if (guestTurn.frame['t'] != 'turn') {
      fail(
        'expected the opening turn on the recorder, got '
        '"${guestTurn.frame['t']}": ${guestTurn.frame['d']}',
      );
    }
    _remember(record, guestTurn.frame);
    final Map<String, Object?> started = _data(guestStarted.frame);
    final Object? gameId = started['game_id'];
    final Object? turn = started['turn'];
    if (gameId is! String || turn is! int) {
      fail('game_started must carry game_id and turn, got $started');
    }
    return (gameId: gameId, turn: turn);
  }

  _Seat seatFor(_Lobby lobby, int seat) =>
      seat == lobby.host.seat ? lobby.host : lobby.guest;

  /// One broadcast, read off the actor and off the other socket. The
  /// recorder's copy (seat 2, which did not have to be the actor) is what
  /// goes in [record]. `d` is the same on both copies; the envelope id is
  /// not, and the log does not carry it.
  Future<Map<String, Object?>> readBroadcast(
    _Lobby lobby,
    int actorSeat,
    List<Map<String, Object?>> record,
  ) async {
    final _Seat actor = seatFor(lobby, actorSeat);
    final _Incoming mine = await actor.client.next();
    if (mine.frame['t'] == 'error') {
      fail(
        'seat $actorSeat received an error during play: ${mine.frame['d']}',
      );
    }
    final _Seat other = actorSeat == lobby.host.seat ? lobby.guest : lobby.host;
    final _Incoming theirs = await other.client.next();
    expect(
      theirs.frame['t'],
      mine.frame['t'],
      reason: 'a broadcast push reaches both sockets with the same type',
    );
    expect(
      theirs.frame['d'],
      mine.frame['d'],
      reason: 'a broadcast push reaches both sockets with the same d',
    );
    final _Incoming guestCopy =
        identical(actor.client, lobby.guest.client) ? mine : theirs;
    _remember(record, guestCopy.frame);
    return mine.frame;
  }

  Future<_Ply> ply(
    _Lobby lobby,
    int actorSeat,
    List<Map<String, Object?>> record,
  ) async {
    seatFor(lobby, actorSeat).client.send('roll', <String, Object?>{});
    final Map<String, Object?> rolled =
        await readBroadcast(lobby, actorSeat, record);
    if (rolled['t'] != 'rolled') {
      fail(
        'expected rolled from seat $actorSeat, got "${rolled['t']}": '
        '${rolled['d']}',
      );
    }
    final Object? rawLegal = _data(rolled)['legal'];
    if (rawLegal is! List<Object?>) {
      fail('rolled.legal must be a list, got $rawLegal');
    }
    final List<int> legal = <int>[
      for (final Object? token in rawLegal) token! as int,
    ];
    if (legal.isEmpty) {
      final Map<String, Object?> passed =
          await readBroadcast(lobby, actorSeat, record);
      if (passed['t'] != 'turn_passed') {
        fail(
          'an empty legal list must be followed by turn_passed, got '
          '"${passed['t']}": ${passed['d']}',
        );
      }
      final Map<String, Object?> turn =
          await readBroadcast(lobby, actorSeat, record);
      if (turn['t'] != 'turn') {
        fail(
          'turn_passed must be followed by turn, got "${turn['t']}": '
          '${turn['d']}',
        );
      }
      final Object? next = _data(turn)['seat'];
      if (next is! int) {
        fail('turn.seat must be an int, got $next');
      }
      return _Ply(gameOver: false, nextSeat: next);
    }

    seatFor(lobby, actorSeat).client.send('move', <String, Object?>{
      'token': legal.first,
    });
    final Map<String, Object?> moved =
        await readBroadcast(lobby, actorSeat, record);
    if (moved['t'] != 'moved') {
      fail('expected moved, got "${moved['t']}": ${moved['d']}');
    }
    final Map<String, Object?> after =
        await readBroadcast(lobby, actorSeat, record);
    if (after['t'] == 'game_over') {
      return const _Ply(gameOver: true);
    }
    if (after['t'] != 'turn') {
      fail(
        'moved must be followed by game_over or turn, got '
        '"${after['t']}": ${after['d']}',
      );
    }
    final Object? next = _data(after)['seat'];
    if (next is! int) {
      fail('turn.seat must be an int, got $next');
    }
    return _Ply(gameOver: false, nextSeat: next);
  }

  Future<void> finish(
    _Lobby lobby,
    int seat,
    List<Map<String, Object?>> record,
  ) async {
    var current = seat;
    for (var attempt = 0; attempt < 4; attempt++) {
      final Room? found = harness.registry.lookup(lobby.code);
      if (found == null || found.game == null) {
        fail('room ${lobby.code} has no game to finish');
      }
      final Room room = found;
      final engine.GameState game = room.game!;
      if (game.phase != engine.GamePhase.awaitRoll ||
          game.currentSeat != current) {
        fail(
          'finishing roll wanted awaitRoll for seat $current, '
          'game is ${game.phase} seat ${game.currentSeat}',
        );
      }
      final int face = _serverFace(room);
      // Rule 10: a third six in a row is not played. Do not arm a win
      // onto a roll the engine is about to forfeit.
      if (game.sixes == 2 && face == 6) {
        final _Ply passed = await ply(lobby, current, record);
        if (passed.gameOver || passed.nextSeat == null) {
          fail('a third six forfeits the turn; it does not end the game');
        }
        current = passed.nextSeat!;
        continue;
      }
      _armWinningToken(room, current, face);
      final _Ply won = await ply(lobby, current, record);
      if (!won.gameOver) {
        fail(
          'seat $current, one token $face from home, did not win; '
          'last recorded push was ${record.last}',
        );
      }
      return;
    }
    fail('the next server face kept forfeiting before a winning roll');
  }

  Future<({_Lobby lobby, String gameId, List<Map<String, Object?>> record})>
      playLong(Uri uri) async {
    final _Lobby lobby = await openLobby(uri);
    await seedBoth(lobby);
    final List<Map<String, Object?>> record = <Map<String, Object?>>[];
    final ({String gameId, int turn}) started = await startGame(lobby, record);
    int? seat = started.turn;
    var plies = 0;
    while (_entryBytes(record) < _longEntryBytes) {
      plies += 1;
      if (plies > 80) {
        fail(
          'recorded entries are ${_entryBytes(record)} bytes after 80 '
          'plies, short of the $_longEntryBytes that forces a second part',
        );
      }
      // Section 7 counts every message in a one-second window on this
      // clock. One ply per second keeps a long game under 30.
      harness.clock.advance(const Duration(seconds: 1));
      final _Ply step = await ply(lobby, seat!, record);
      if (step.gameOver) {
        break;
      }
      seat = step.nextSeat;
    }
    if (record.last['t'] != 'game_over') {
      await finish(lobby, seat!, record);
    }
    expect(record.first['t'], 'game_started');
    expect(record.last['t'], 'game_over');
    expect(
      _entryBytes(record),
      greaterThan(_maxFrameBytes),
      reason: 'the recorded entries alone must exceed one frame, or case 3 '
          'cannot require two parts',
    );
    return (lobby: lobby, gameId: started.gameId, record: record);
  }

  Future<void> silence(_RawClient client, int seat) async {
    try {
      final _Incoming extra = await client.next(
        timeout: const Duration(seconds: 1),
      );
      fail(
        'seat $seat received "${extra.frame['t']}" when only seat 0 sent '
        'game_log: ${extra.frame['d']}',
      );
    } on TestFailure catch (error) {
      if (!'$error'.contains('none arrived')) {
        rethrow;
      }
    }
  }

  group('game_log, docs/PROTOCOL.md section 17', () {
    test(
        '1. after game_over, seat 0\'s game_log matches the other seat\'s '
        'record, and game_id is the game\'s', () async {
      useScriptedDice();
      final Uri uri = await start();
      final ({
        _Lobby lobby,
        String gameId,
        List<Map<String, Object?>> record,
      }) played = await playLong(uri);

      final String id =
          played.lobby.host.client.send('game_log', <String, Object?>{});
      final List<_Part> parts =
          await _readLog(played.lobby.host.client, id, played.gameId);
      expect(
        _framesOf(parts),
        played.record,
        reason: 'reassembled frames must equal what seat '
            '${played.lobby.guest.seat} recorded from game_started through '
            'game_over, element by element (section 17 rule 2)',
      );
    });

    test(
        '2. mid-game, after rolls and moves, game_log matches the record '
        'so far', () async {
      final Uri uri = await start();
      final _Lobby lobby = await openLobby(uri);
      final List<Map<String, Object?>> record = <Map<String, Object?>>[];
      final ({String gameId, int turn}) started =
          await startGame(lobby, record);
      int? seat = started.turn;
      var rolls = 0;
      var moves = 0;
      var guard = 0;
      while (rolls < 3 || moves < 2) {
        guard += 1;
        if (guard > 40) {
          fail(
            'did not see 3 rolls and 2 moves within 40 plies '
            '(rolls=$rolls moves=$moves)',
          );
        }
        final _Ply step = await ply(lobby, seat!, record);
        if (step.gameOver) {
          fail('the game ended before the mid-game sample');
        }
        seat = step.nextSeat;
        rolls =
            record.where((Map<String, Object?> e) => e['t'] == 'rolled').length;
        moves =
            record.where((Map<String, Object?> e) => e['t'] == 'moved').length;
      }
      expect(record.last['t'], isNot('game_over'));

      final String id = lobby.host.client.send('game_log', <String, Object?>{});
      final List<_Part> parts =
          await _readLog(lobby.host.client, id, started.gameId);
      expect(
        _framesOf(parts),
        record,
        reason: 'mid-game, the reassembled frames must equal what seat '
            '${lobby.guest.seat} has recorded so far',
      );
    });

    test(
        '3. every part is at most 8192 bytes as received, a long game '
        'has at least two, and part, re and game_id agree', () async {
      useScriptedDice();
      final Uri uri = await start();
      final ({
        _Lobby lobby,
        String gameId,
        List<Map<String, Object?>> record,
      }) played = await playLong(uri);

      final String id =
          played.lobby.host.client.send('game_log', <String, Object?>{});
      final List<_Part> parts =
          await _readLog(played.lobby.host.client, id, played.gameId);
      expect(
        parts.length,
        greaterThanOrEqualTo(2),
        reason: 'case 1\'s game is past one frame, so game_log must split',
      );
      for (final _Part part in parts) {
        expect(
          part.bytes,
          lessThanOrEqualTo(_maxFrameBytes),
          reason: 'section 17: each part, as received on the wire, is at '
              'most $_maxFrameBytes bytes; got ${part.bytes}',
        );
      }
      expect(
        played.record.last['t'],
        'game_over',
        reason: 'the game this part check reads is the finished game, '
            'same shape as case 1',
      );
    });

    test('4. in LOBBY, game_log is WRONG_PHASE and carries re', () async {
      final Uri uri = await start();
      final _Lobby lobby = await openLobby(uri);
      final String id = lobby.host.client.send('game_log', <String, Object?>{});
      final _Incoming reply = await lobby.host.client.next();
      expect(
        reply.frame['re'],
        id,
        reason: 'WRONG_PHASE answers the request that caused it',
      );
      expectErrorFrame(
        reply.frame,
        'WRONG_PHASE',
        because: 'the room is still LOBBY (section 17 rule 1)',
      );
    });

    test(
        '5. a socket that holds no seat gets BAD_SEAT_TOKEN, the code '
        'roll gets from such a socket', () async {
      // turn_loop_test.dart, "BAD_SEAT_TOKEN: a socket that never created,
      // joined or resumed any room", and docs/PROTOCOL.md section 7: a
      // socket in no room gets BAD_SEAT_TOKEN for roll. Section 17 rule 1
      // gives game_log that same error.
      final Uri uri = await start();
      final _RawClient stray = await _RawClient.connect(uri);
      clients.add(stray);
      final String id = stray.send('game_log', <String, Object?>{});
      final _Incoming reply = await stray.next();
      expect(reply.frame['re'], id);
      expectErrorFrame(
        reply.frame,
        'BAD_SEAT_TOKEN',
        because: 'this socket holds no seat, the same refusal roll gets',
      );
    });

    test(
        '6. the third game_log within a minute on one connection is '
        'RATE_LIMITED', () async {
      // PLAYING, so the first two are real answers. Section 17 rule 4
      // allows 2 per minute per connection, then RATE_LIMITED, and the
      // parts of an answer do not count. A just-started game is one small
      // log, read in full before the next request.
      final Uri uri = await start();
      final _Lobby lobby = await openLobby(uri);
      final List<Map<String, Object?>> record = <Map<String, Object?>>[];
      final ({String gameId, int turn}) started =
          await startGame(lobby, record);

      final String id1 =
          lobby.host.client.send('game_log', <String, Object?>{});
      final List<_Part> first =
          await _readLog(lobby.host.client, id1, started.gameId);
      expect(_framesOf(first), isNotEmpty);

      final String id2 =
          lobby.host.client.send('game_log', <String, Object?>{});
      final List<_Part> second =
          await _readLog(lobby.host.client, id2, started.gameId);
      expect(_framesOf(second), isNotEmpty);

      final String id3 =
          lobby.host.client.send('game_log', <String, Object?>{});
      final _Incoming third = await lobby.host.client.next();
      expect(third.frame['re'], id3);
      expectErrorFrame(
        third.frame,
        'RATE_LIMITED',
        because: 'the third game_log within a minute on this connection '
            '(section 17 rule 4)',
      );
    });

    test('7. after a rematch game_started, game_log is the new game only',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await openLobby(uri);
      final List<Map<String, Object?>> ignored = <Map<String, Object?>>[];
      final ({String gameId, int turn}) firstGame =
          await startGame(lobby, ignored);
      _forceFinished(harness, lobby.code, winner: lobby.host.seat);

      lobby.host.client.send('rematch', <String, Object?>{});
      final _Incoming hostAsk = await lobby.host.client.next();
      final _Incoming guestAsk = await lobby.guest.client.next();
      expect(hostAsk.frame['t'], 'room');
      expect(guestAsk.frame['t'], 'room');

      lobby.guest.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> guestStarted =
          await _drainRematchStart(lobby.guest.client);
      final Map<String, Object?> hostStarted =
          await _drainRematchStart(lobby.host.client);
      final Object? newGameId = guestStarted['game_id'];
      if (newGameId is! String) {
        fail('rematch game_started has no game_id: $guestStarted');
      }
      expect(hostStarted['game_id'], newGameId);
      expect(newGameId, isNot(firstGame.gameId));

      final String id = lobby.host.client.send('game_log', <String, Object?>{});
      final List<Map<String, Object?>> frames =
          _framesOf(await _readLog(lobby.host.client, id, newGameId));
      expect(frames, isNotEmpty);
      expect(frames.first['t'], 'game_started');
      expect(
        _data(frames.first)['game_id'],
        newGameId,
        reason: 'the log starts at the new game_started, not the previous '
            'game (section 17 rule 5)',
      );
      for (final Map<String, Object?> entry in frames) {
        if (entry['t'] == 'game_started') {
          expect(_data(entry)['game_id'], newGameId);
        }
      }
    });

    test('8. the game_log answer reaches the requester and no other socket',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await openLobby(uri);
      final List<Map<String, Object?>> record = <Map<String, Object?>>[];
      final ({String gameId, int turn}) started =
          await startGame(lobby, record);

      final String id = lobby.host.client.send('game_log', <String, Object?>{});
      final List<_Part> parts =
          await _readLog(lobby.host.client, id, started.gameId);
      expect(parts, isNotEmpty);
      await silence(lobby.guest.client, lobby.guest.seat);
    });

    test('9. a non-empty d is BAD_FIELD', () async {
      // Section 7 checks phase before payload fields, the same way `roll`
      // and `rematch` do. Sent in PLAYING, so the refusal is the field
      // and not WRONG_PHASE.
      final Uri uri = await start();
      final _Lobby lobby = await openLobby(uri);
      final List<Map<String, Object?>> record = <Map<String, Object?>>[];
      await startGame(lobby, record);
      final String id = lobby.host.client.send('game_log', <String, Object?>{
        'x': 1,
      });
      final _Incoming reply = await lobby.host.client.next();
      expect(reply.frame['re'], id);
      expectErrorFrame(
        reply.frame,
        'BAD_FIELD',
        because: 'game_log d must be empty; sent {"x": 1}',
      );
    });
  });
}

/// The completing `rematch` on a two-seat room: the accepter's `room`,
/// then two server `seat_seed` frames (the rematch lobby has no seeds),
/// then `game_started`, then the opening `turn`. Same order
/// `rematch_test.dart` drains for section 16.4 auto-start.
Future<Map<String, Object?>> _drainRematchStart(_RawClient client) async {
  final _Incoming room = await client.next();
  if (room.frame['t'] != 'room') {
    fail(
      'expected the rematch room frame, got "${room.frame['t']}": '
      '${room.frame['d']}',
    );
  }
  final _Incoming seedA = await client.next();
  final _Incoming seedB = await client.next();
  if (seedA.frame['t'] != 'seat_seed' || seedB.frame['t'] != 'seat_seed') {
    fail(
      'expected two seat_seed frames before the new game_started, got '
      '"${seedA.frame['t']}" then "${seedB.frame['t']}"',
    );
  }
  final _Incoming started = await client.next();
  if (started.frame['t'] != 'game_started') {
    fail(
      'expected the new game_started, got "${started.frame['t']}": '
      '${started.frame['d']}',
    );
  }
  final _Incoming turn = await client.next();
  if (turn.frame['t'] != 'turn') {
    fail(
      'expected the opening turn after the new game_started, got '
      '"${turn.frame['t']}": ${turn.frame['d']}',
    );
  }
  return _data(started.frame);
}
