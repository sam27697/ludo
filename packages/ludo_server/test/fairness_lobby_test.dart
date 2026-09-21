// Conformance tests for `docs/PROTOCOL.md` section 11, the lobby half only:
// the chain commitment a room publishes at creation, the `set_seed`
// rejection ladder in the exact order section 11 tables it, the `seat_seed`
// broadcast, and what `game_started` carries and no longer carries.
//
// This file is written from that section, not from `packages/ludo_server`'s
// current source. As of this branch nothing in section 11 exists yet on the
// server: `set_seed` is not a known message type, there is no
// `chain_commit` on the room snapshot, and `game_started` still carries the
// old one-seed scheme's `seed_commit`. Every test below is expected to fail
// today for that reason, and this file never reaches into `lib/` to make one
// pass -- it only opens a real WebSocket against a real, running server and
// reads the JSON that comes back, exactly as a client would.
//
// Two things this file deliberately does NOT do, because doing them would be
// asserting a defect rather than the spec:
//   - it never expects a frame named `seed_set`; the wire name is
//     `seat_seed`, section 11.2's boxed note explains why.
//   - it never looks for a `die` field on `rolled`; there is no `rolled` in
//     this file at all, because the turn loop is order 008 and out of scope
//     here (`k`, `reveal`, `value`, chain rollover at N = 4096).
//
// Every helper below reads and writes plain `Map<String, Object?>` JSON, not
// a message type from `lib/`, so a symbol that does not exist yet on this
// branch is never referenced by this file at all.

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

// `SetSeedResult` and `SetSeedFailure` now come from the package's own
// export list; they used to be reached for through `src/registry.dart`
// because they were missing from it. The reason this suite needs them at
// all is documented at their one call site below: `set_seed`'s own wire
// message, `docs/PROTOCOL.md` section 4, carries no room `code` field at
// all, so there is no way for a real client socket to ever send a set_seed
// against a room code that never existed -- a socket's room is always the
// one it created, joined or resumed into, which necessarily existed at that
// moment. `RoomRegistry.setSeed` is the only entry point that can even be
// asked the "never existed" question for this message, and it is a real
// method on the real registry the wire server itself calls, not a mock of
// one.

/// A room's first chain commitment: `s[0]`, 64 lowercase hex characters.
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// A server-issued seed, 16 bytes hex: 32 lowercase hex characters.
final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

/// `game_id`, 16 lowercase hex characters.
final RegExp _hex16 = RegExp(r'^[0-9a-f]{16}$');

/// One seat's identity on a connected socket: the seat index the registry
/// assigned it and the seat token that reclaims it, per
/// `docs/PROTOCOL.md` section 2.
class _Seat {
  _Seat({required this.client, required this.seat, required this.token});

  final WireTestClient client;
  final int seat;
  final String token;
}

/// A two-seat room in LOBBY, both seats filled, every handshake frame
/// already drained from both sockets' queues -- host and guest are ready
/// for a test to send the one message it actually wants to observe.
class _Lobby {
  _Lobby({
    required this.code,
    required this.host,
    required this.guest,
    required this.hostRoom,
    required this.guestRoom,
  });

  final String code;
  final _Seat host;
  final _Seat guest;

  /// The `d` of the `room` frame the host received on `create_room`.
  final Map<String, Object?> hostRoom;

  /// The `d` of the `room` frame the guest received on `join_room`.
  final Map<String, Object?> guestRoom;
}

/// One seat in a room nobody else has joined yet, used by the `chain_commit`
/// tests that only need a single socket.
class _SoloRoom {
  _SoloRoom({
    required this.client,
    required this.seat,
    required this.seatToken,
    required this.roomData,
  });

  final WireTestClient client;
  final int seat;
  final String seatToken;
  final Map<String, Object?> roomData;
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

  Future<WireTestClient> connect(Uri uri) async {
    final WireTestClient client = await WireTestClient.connect(uri);
    clients.add(client);
    return client;
  }

  Future<_SoloRoom> createSoloRoom(
    Uri uri, {
    int players = 2,
    String name = 'Host',
  }) async {
    final WireTestClient client = await connect(uri);
    client.send('create_room', <String, Object?>{
      'name': name,
      'players': players,
    });
    final Map<String, Object?> seatAssigned = await client.next();
    final Map<String, Object?> roomFrame = await client.next();
    final Map<String, Object?> seatData =
        seatAssigned['d']! as Map<String, Object?>;
    return _SoloRoom(
      client: client,
      seat: seatData['seat']! as int,
      seatToken: seatData['seat_token']! as String,
      roomData: roomFrame['d']! as Map<String, Object?>,
    );
  }

  Future<_Lobby> buildTwoSeatLobby(
    Uri uri, {
    String hostName = 'Host',
    String guestName = 'Guest',
  }) async {
    final _SoloRoom hostRoom = await createSoloRoom(
      uri,
      players: 2,
      name: hostName,
    );

    final WireTestClient guestClient = await connect(uri);
    guestClient.send('join_room', <String, Object?>{
      'code': hostRoom.roomData['code']! as String,
      'name': guestName,
    });
    final Map<String, Object?> guestSeatAssigned = await guestClient.next();
    final Map<String, Object?> guestRoomFrame = await guestClient.next();
    final Map<String, Object?> guestSeatData =
        guestSeatAssigned['d']! as Map<String, Object?>;

    // The host's socket also receives player_joined for the guest; drained
    // here so later reads on the host's queue see only what a later message
    // actually produces.
    await hostRoom.client.next();

    return _Lobby(
      code: hostRoom.roomData['code']! as String,
      host: _Seat(
        client: hostRoom.client,
        seat: hostRoom.seat,
        token: hostRoom.seatToken,
      ),
      guest: _Seat(
        client: guestClient,
        seat: guestSeatData['seat']! as int,
        token: guestSeatData['seat_token']! as String,
      ),
      hostRoom: hostRoom.roomData,
      guestRoom: guestRoomFrame['d']! as Map<String, Object?>,
    );
  }

  /// Reads frames off [client] one at a time, discarding anything that is
  /// not a [type] frame, up to [maxFrames]. This tolerates a correct
  /// implementation interleaving other pushes (a `seat_seed` broadcast
  /// alongside `game_started`, for instance) in an order this section of
  /// the spec does not pin, while still failing -- inside a bounded, short
  /// wall-clock budget -- when the frame this test actually needs never
  /// shows up at all.
  Future<Map<String, Object?>> receiveType(
    WireTestClient client,
    String type, {
    int maxFrames = 6,
    Duration perFrame = const Duration(milliseconds: 500),
  }) async {
    for (int i = 0; i < maxFrames; i++) {
      final Map<String, Object?> frame = await client.next(timeout: perFrame);
      if (frame['t'] == type) {
        return frame;
      }
    }
    throw TestFailure(
      'expected a "$type" frame within $maxFrames frames and none arrived',
    );
  }

  /// Reads frames off [client] one at a time until a [type] frame arrives,
  /// returning every frame seen along the way, [type] included, in arrival
  /// order. This tolerates any number of interleaved pushes -- a `seat_seed`
  /// broadcast for the sender's own seat, a `seat_seed` for another seat's
  /// server-assigned seed, in whatever order a correct implementation
  /// happens to emit them -- while still failing, inside a bounded, short
  /// wall-clock budget, when [type] never shows up at all. A caller that
  /// needs both the interleaved pushes and the frame that follows them (a
  /// `seat_seed` push together with the `game_started` that ends the burst,
  /// for instance) reads them off the returned list instead of guessing how
  /// many frames the burst contains.
  Future<List<Map<String, Object?>>> drainUntil(
    WireTestClient client,
    String type, {
    int maxFrames = 6,
    Duration perFrame = const Duration(milliseconds: 500),
  }) async {
    final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
    for (int i = 0; i < maxFrames; i++) {
      final Map<String, Object?> frame = await client.next(timeout: perFrame);
      frames.add(frame);
      if (frame['t'] == type) {
        return frames;
      }
    }
    throw TestFailure(
      'expected a "$type" frame within $maxFrames frames on this socket and '
      'none arrived; frames seen along the way: $frames',
    );
  }

  /// Sends `start_game` from the host and waits for `game_started` on both
  /// sockets, tolerating any `seat_seed` pushes a correct implementation
  /// interleaves around it. Also consumes the standalone `turn` frame
  /// section 13.1 requires immediately after `game_started`, on both
  /// sockets, via [expectOpeningTurn] -- otherwise it sits in each
  /// socket's queue and is mistaken for whatever the next helper actually
  /// asked for. Returns the host's `game_started` payload.
  Future<Map<String, Object?>> startGame(_Lobby lobby) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostFrame =
        await receiveType(lobby.host.client, 'game_started');
    final Map<String, Object?> hostFrameData =
        hostFrame['d']! as Map<String, Object?>;
    final Object? startingSeat = hostFrameData['turn'];
    await expectOpeningTurn(lobby.host.client, startingSeat);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startingSeat);
    return hostFrameData;
  }

  Future<Map<String, Object?>> setSeed(
    WireTestClient client,
    Map<String, Object?> data,
  ) {
    client.send('set_seed', data);
    return client.next();
  }

  void expectErrorCode(
    Map<String, Object?> frame,
    String expectedCode, {
    required String because,
  }) {
    expect(
      frame['t'],
      'error',
      reason: 'expected an error frame ($because) but got a "${frame['t']}" '
          'frame instead: ${frame['d']}',
    );
    final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
    expect(
      data['code'],
      expectedCode,
      reason: 'expected error code $expectedCode ($because) but got '
          '${data['code']} (message: "${data['message']}")',
    );
  }

  group('room: chain_commit and chain_index, section 11.2', () {
    test(
        'chain_commit is present at room creation as 64 lowercase hex characters',
        () async {
      final Uri uri = await start();
      final _SoloRoom room = await createSoloRoom(uri);

      final Object? chainCommit = room.roomData['chain_commit'];
      expect(
        chainCommit,
        isA<String>(),
        reason: 'the room frame at creation must carry chain_commit as a '
            'string, s[0] of the chain (section 11.2); got '
            '${chainCommit.runtimeType}: $chainCommit',
      );
      final String chainCommitValue = chainCommit! as String;
      expect(
        _hex64.hasMatch(chainCommitValue),
        isTrue,
        reason: 'chain_commit must be exactly 64 lowercase hex characters; '
            'got "$chainCommitValue" (length ${chainCommitValue.length})',
      );
    });

    test("chain_index is 0 for a room's first chain", () async {
      final Uri uri = await start();
      final _SoloRoom room = await createSoloRoom(uri);

      expect(
        room.roomData['chain_index'],
        0,
        reason: 'chain_index must be 0 for the first chain of a freshly '
            'created room; got ${room.roomData['chain_index']}',
      );
    });

    test(
        'a late joiner receives the same chain_commit and chain_index as the host',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      // Asserted first and independently of the comparison below: a room
      // frame that carries no chain_commit at all would otherwise let a
      // null-equals-null comparison between host and guest pass by
      // accident, without either side ever having seen a real commitment.
      final Object? hostChainCommit = lobby.hostRoom['chain_commit'];
      expect(
        hostChainCommit,
        isA<String>(),
        reason: "the host's own room frame for ${lobby.code} must carry a "
            'chain_commit before this test can compare it against the '
            'guest; got ${hostChainCommit.runtimeType}: $hostChainCommit',
      );
      expect(
        _hex64.hasMatch(hostChainCommit! as String),
        isTrue,
        reason: 'the chain_commit this test is comparing against must '
            'itself be 64 lowercase hex characters; got "$hostChainCommit"',
      );
      expect(
        lobby.hostRoom['chain_index'],
        0,
        reason: 'the chain_index this test is comparing against must '
            "itself be 0, the room's first chain; got "
            '${lobby.hostRoom['chain_index']}',
      );

      expect(
        lobby.guestRoom['chain_commit'],
        lobby.hostRoom['chain_commit'],
        reason: 'the guest joined room ${lobby.code} after the host and '
            'must see the identical chain_commit; host had '
            '${lobby.hostRoom['chain_commit']}, guest had '
            '${lobby.guestRoom['chain_commit']}',
      );
      expect(
        lobby.guestRoom['chain_index'],
        lobby.hostRoom['chain_index'],
        reason: 'chain_index must match between the host and a later '
            'joiner of the same room ${lobby.code}',
      );
    });

    test(
        'resuming into the same room returns the same chain_commit and chain_index',
        () async {
      final Uri uri = await start();
      final _SoloRoom room = await createSoloRoom(uri);

      room.client.send('resume', <String, Object?>{
        'code': room.roomData['code']! as String,
        'seat_token': room.seatToken,
      });
      final Map<String, Object?> resumed = await room.client.next();
      final Map<String, Object?> resumedData =
          resumed['d']! as Map<String, Object?>;

      // Asserted first and independently of the comparison below, for the
      // same reason as the late-joiner test: a room frame with no
      // chain_commit at all would otherwise let a null-equals-null
      // comparison pass without either frame ever carrying a real one.
      final Object? originalChainCommit = room.roomData['chain_commit'];
      expect(
        originalChainCommit,
        isA<String>(),
        reason: 'the original room frame for ${room.roomData['code']} must '
            'carry a chain_commit before this test can compare a resume '
            'against it; got ${originalChainCommit.runtimeType}: '
            '$originalChainCommit',
      );
      expect(
        _hex64.hasMatch(originalChainCommit! as String),
        isTrue,
        reason: 'the chain_commit this test is comparing against must '
            'itself be 64 lowercase hex characters; got '
            '"$originalChainCommit"',
      );

      expect(
        resumedData['chain_commit'],
        room.roomData['chain_commit'],
        reason: 'a resume on room ${room.roomData['code']} must not see a '
            'chain_commit different from the one published at creation',
      );
      expect(
        resumedData['chain_index'],
        room.roomData['chain_index'],
        reason: 'a resume on room ${room.roomData['code']} must not see a '
            'chain_index different from the one published at creation',
      );
    });

    test('two different rooms do not share a chain_commit', () async {
      final Uri uri = await start();
      final _SoloRoom roomA = await createSoloRoom(uri, name: 'Alice');
      final _SoloRoom roomB = await createSoloRoom(uri, name: 'Bob');

      expect(
        roomA.roomData['chain_commit'],
        isNot(equals(roomB.roomData['chain_commit'])),
        reason: 'room ${roomA.roomData['code']} and room '
            '${roomB.roomData['code']} both reported chain_commit '
            '"${roomA.roomData['chain_commit']}"; each room must commit to '
            'its own chain',
      );
    });
  });

  group('set_seed: the rejection ladder, section 11.2', () {
    test('set_seed after start_game is refused with WRONG_PHASE', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);
      await startGame(lobby);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expectErrorCode(
        reply,
        'WRONG_PHASE',
        because: 'room ${lobby.code} left LOBBY when start_game ran',
      );
    });

    test(
        'set_seed from a socket holding no seat is refused with BAD_SEAT_TOKEN',
        () async {
      final Uri uri = await start();
      final WireTestClient stray = await connect(uri);

      final Map<String, Object?> reply = await setSeed(
        stray,
        <String, Object?>{'client_seed': 'nobody-seed'},
      );
      expectErrorCode(
        reply,
        'BAD_SEAT_TOKEN',
        because: 'this socket never created, joined or resumed any room',
      );
    });

    test('set_seed with client_seed absent is BAD_FIELD', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{},
      );
      expectErrorCode(
        reply,
        'BAD_FIELD',
        because: 'client_seed was absent from d entirely',
      );
    });

    test('set_seed with client_seed not a string is BAD_FIELD', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 12345},
      );
      expectErrorCode(
        reply,
        'BAD_FIELD',
        because: 'client_seed was the JSON number 12345, not a string',
      );
    });

    test('set_seed with an empty client_seed is BAD_FIELD', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': ''},
      );
      expectErrorCode(
        reply,
        'BAD_FIELD',
        because: 'client_seed was the empty string',
      );
    });

    test('set_seed with a client_seed over 64 characters is BAD_FIELD',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);
      final String tooLong = 'a' * 65;

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': tooLong},
      );
      expectErrorCode(
        reply,
        'BAD_FIELD',
        because: 'client_seed was ${tooLong.length} characters, one over '
            'the 64 character maximum',
      );
    });

    test('set_seed with a character outside [A-Za-z0-9_-] is BAD_FIELD',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'bad seed!'},
      );
      expectErrorCode(
        reply,
        'BAD_FIELD',
        because: 'client_seed "bad seed!" contains a space and an '
            'exclamation mark, both outside [A-Za-z0-9_-]',
      );
    });

    test('set_seed with a client_seed of exactly 64 characters is accepted',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);
      final String seed = 'a' * 64;

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': seed},
      );
      expect(
        reply['t'],
        'seat_seed',
        reason: 'a 64 character client_seed is within the allowed 1 to 64 '
            'range and must be accepted; got type=${reply['t']} '
            'data=${reply['d']}',
      );
    });

    test('set_seed with a client_seed of exactly 1 character is accepted',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'a'},
      );
      expect(
        reply['t'],
        'seat_seed',
        reason: 'a 1 character client_seed is within the allowed 1 to 64 '
            'range and must be accepted; got type=${reply['t']} '
            'data=${reply['d']}',
      );
    });

    test('set_seed with underscores and hyphens in client_seed is accepted',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'a_b-c'},
      );
      expect(
        reply['t'],
        'seat_seed',
        reason: 'underscore and hyphen are both inside [A-Za-z0-9_-] and '
            'must be accepted; got type=${reply['t']} data=${reply['d']}',
      );
    });

    test('set_seed works for any seated player, not only the host', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> reply = await setSeed(
        lobby.guest.client,
        <String, Object?>{'client_seed': 'bob-seed'},
      );
      expect(
        reply['t'],
        'seat_seed',
        reason: 'a non-host seat must be able to fix its own seed; got '
            'type=${reply['t']} data=${reply['d']}',
      );
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;
      expect(data['seat'], lobby.guest.seat);
    });

    test(
        'a second set_seed from the same seat is refused with SEED_ALREADY_SET',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> first = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        first['t'],
        'seat_seed',
        reason: 'the first set_seed from seat ${lobby.host.seat} must '
            'succeed for this test to reach the state it is checking; got '
            'type=${first['t']} data=${first['d']}',
      );

      final Map<String, Object?> second = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed-2'},
      );
      expectErrorCode(
        second,
        'SEED_ALREADY_SET',
        because: 'seat ${lobby.host.seat} in room ${lobby.code} already '
            'fixed a seed',
      );
    });

    test(
        'set_seed after start_game with a malformed field is WRONG_PHASE, not BAD_FIELD',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);
      await startGame(lobby);

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': ''},
      );
      expectErrorCode(
        reply,
        'WRONG_PHASE',
        because: 'room ${lobby.code} left LOBBY, which the ladder checks '
            'before client_seed shape, even though the client_seed sent '
            '("") is also malformed',
      );
    });

    test(
        'set_seed from a socket holding no seat with a malformed field is BAD_SEAT_TOKEN, not BAD_FIELD',
        () async {
      final Uri uri = await start();
      final WireTestClient stray = await connect(uri);

      final Map<String, Object?> reply = await setSeed(
        stray,
        <String, Object?>{},
      );
      expectErrorCode(
        reply,
        'BAD_SEAT_TOKEN',
        because: 'this socket holds no seat, which the ladder checks '
            'before client_seed shape, even though client_seed is also '
            'absent',
      );
    });

    test(
        'set_seed after start_game from a seat that already has a seed is WRONG_PHASE, not SEED_ALREADY_SET',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> first = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        first['t'],
        'seat_seed',
        reason: 'the first set_seed from seat ${lobby.host.seat} must '
            'succeed for this test to reach the state it is checking; got '
            'type=${first['t']} data=${first['d']}',
      );

      await startGame(lobby);

      final Map<String, Object?> second = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed-2'},
      );
      expectErrorCode(
        second,
        'WRONG_PHASE',
        because: 'room ${lobby.code} left LOBBY, which the ladder checks '
            'before the already-set check, even though seat '
            '${lobby.host.seat} already fixed a seed',
      );
    });

    test(
        'a second set_seed with a malformed field is BAD_FIELD, not SEED_ALREADY_SET',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> first = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        first['t'],
        'seat_seed',
        reason: 'the first set_seed from seat ${lobby.host.seat} must '
            'succeed for this test to reach the state it is checking; got '
            'type=${first['t']} data=${first['d']}',
      );

      final Map<String, Object?> second = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': ''},
      );
      expectErrorCode(
        second,
        'BAD_FIELD',
        because: 'client_seed on the second attempt is empty, which the '
            'ladder checks before the already-set check, even though seat '
            '${lobby.host.seat} already fixed a seed',
      );
    });
  });

  group('set_seed: the NO_SUCH_ROOM row, section 11.2, amended 2026-08-28', () {
    // The four rungs below NO_SUCH_ROOM (WRONG_PHASE, BAD_SEAT_TOKEN,
    // BAD_FIELD, SEED_ALREADY_SET, in that order) are already pinned by the
    // group above, including two precedence cases
    // (WRONG_PHASE-over-BAD_FIELD and BAD_SEAT_TOKEN-over-BAD_FIELD) and one
    // that specifically exercises a room already in PLAYING. Nothing here
    // repeats those; this group only adds what the amendment made new: the
    // row itself, that it does not leak "existed" versus "never existed",
    // and that it outranks BAD_FIELD too.

    test(
        'setSeed on the registry against a room code that never existed is refused with NO_SUCH_ROOM',
        () async {
      // No `start()`, no socket: as the import note above explains, there is
      // no wire form of this scenario for set_seed, so this one test goes
      // straight at RoomRegistry.setSeed, the same real method
      // connection.dart's wire handler calls, and does not touch anything
      // this branch's server does not already expose.
      final ServerHarness bareHarness = ServerHarness.build();
      addTearDown(bareHarness.close);
      const String neverExisted = 'ZZZZZZ';

      final SetSeedResult result = bareHarness.registry.setSeed(
        code: neverExisted,
        seatToken: 'irrelevant-seat-token-never-existed',
        clientSeed: 'irrelevant-seed',
      );

      expect(
        result,
        isA<SetSeedFailure>(),
        reason: 'setSeed against room code "$neverExisted", which this test '
            'never created, must fail; got $result',
      );
      expect(
        (result as SetSeedFailure).error,
        ProtocolError.noSuchRoom,
        reason: 'a room code that never existed must answer NO_SUCH_ROOM '
            '(section 11.2, amended 2026-08-28); got ${result.error}',
      );
    });

    test(
        'set_seed against a room that has been reaped is refused with NO_SUCH_ROOM, not WRONG_PHASE and not BAD_SEAT_TOKEN',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      // Both sockets stay open for the rest of this test -- set_seed is
      // about to be sent on one of them -- but the registry's own idea of
      // "connected" is flipped false for both seats so the room becomes
      // idle-eligible, the same disconnect-then-advance-then-reap sequence
      // `registry_lifecycle_test.dart` uses against joinRoom, resume,
      // startGame and leaveRoom, aimed here at set_seed instead.
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
      harness.clock.advance(const Duration(minutes: 10));
      expect(
        harness.registry.reap(),
        1,
        reason: 'setup requires room ${lobby.code} to actually be reaped '
            'for this test to reach the state it is checking',
      );
      expect(
        harness.registry.lookup(lobby.code),
        isNull,
        reason:
            'room ${lobby.code} must be gone from the registry after reap()',
      );

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expectErrorCode(
        reply,
        'NO_SUCH_ROOM',
        because: 'room ${lobby.code} was reaped and the socket sending '
            'set_seed still holds a seat token that was genuinely seat '
            '${lobby.host.seat} in it (section 11.2, amended 2026-08-28)',
      );
    });

    test(
        'a room code that never existed and a room that was reaped produce the identical NO_SUCH_ROOM value for set_seed',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      const String neverExisted = 'QRSTUV';
      final SetSeedResult neverResult = harness.registry.setSeed(
        code: neverExisted,
        seatToken: 'irrelevant-seat-token-never-existed',
        clientSeed: 'irrelevant-seed',
      );
      expect(
        neverResult,
        isA<SetSeedFailure>(),
        reason: 'setup requires the never-existed code to fail; got '
            '$neverResult',
      );

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
      harness.clock.advance(const Duration(minutes: 10));
      expect(
        harness.registry.reap(),
        1,
        reason: 'setup requires room ${lobby.code} to actually be reaped '
            'for this test to reach the state it is checking',
      );

      final Map<String, Object?> reapedReply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        reapedReply['t'],
        'error',
        reason: 'expected an error frame for the reaped room '
            '${lobby.code} but got a "${reapedReply['t']}" frame instead: '
            '${reapedReply['d']}',
      );
      final Map<String, Object?> reapedData =
          reapedReply['d']! as Map<String, Object?>;

      final String neverExistedWireCode =
          wireErrorCode((neverResult as SetSeedFailure).error);
      expect(
        reapedData['code'],
        neverExistedWireCode,
        reason: 'code "$neverExisted", which never existed, answered '
            '$neverExistedWireCode; room ${lobby.code}, which existed and '
            'was reaped, answered ${reapedData['code']}; existence must not '
            'leak through a difference between the two (section 11.2, '
            'amended 2026-08-28)',
      );
      expect(
        reapedData['code'],
        'NO_SUCH_ROOM',
        reason: 'both must actually be NO_SUCH_ROOM, not merely equal to '
            'each other by both being some other, wrong code',
      );
    });

    test(
        'set_seed against a reaped room with a malformed client_seed is refused with NO_SUCH_ROOM, not BAD_FIELD',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

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
      harness.clock.advance(const Duration(minutes: 10));
      expect(
        harness.registry.reap(),
        1,
        reason: 'setup requires room ${lobby.code} to actually be reaped '
            'for this test to reach the state it is checking',
      );

      final Map<String, Object?> reply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': ''},
      );
      expectErrorCode(
        reply,
        'NO_SUCH_ROOM',
        because: 'room ${lobby.code} no longer exists, which the ladder '
            'checks before client_seed shape, even though the client_seed '
            'sent ("") is also malformed -- NO_SUCH_ROOM sits above '
            'BAD_FIELD (section 11.2, amended 2026-08-28)',
      );
    });
  });

  group('seat_seed: the broadcast, section 11.2', () {
    test(
        'an accepted set_seed replies to the sender with seat, client_seed, origin player, and seq',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final String sentId = lobby.host.client.send(
        'set_seed',
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      final Map<String, Object?> reply = await lobby.host.client.next();

      expect(
        reply['t'],
        'seat_seed',
        reason: 'the reply to an accepted set_seed must be a seat_seed '
            'frame, not "seed_set" and not anything else (section 11.2); '
            'got type=${reply['t']} data=${reply['d']}',
      );
      expect(
        reply['re'],
        sentId,
        reason: 'the reply to set_seed must carry re equal to the id it '
            'answers ($sentId)',
      );
      final Map<String, Object?> data = reply['d']! as Map<String, Object?>;
      expect(data['seat'], lobby.host.seat);
      expect(data['client_seed'], 'alice-seed');
      expect(data['origin'], 'player');
      expect(
        data['seq'],
        isA<int>(),
        reason: 'seat_seed is on the mandatory-seq list, section 5',
      );
      expect(
        data.keys.toSet(),
        <String>{'seat', 'client_seed', 'origin', 'seq'},
        reason: 'seat_seed must carry exactly these four fields; got '
            '${data.keys.toList()}',
      );
    });

    test(
        'an accepted set_seed is broadcast, with no re, to every other connected socket in the room',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      lobby.host.client.send(
        'set_seed',
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      await lobby.host.client.next(); // the direct reply to the host

      final Map<String, Object?> pushed = await lobby.guest.client.next();
      expect(
        pushed['t'],
        'seat_seed',
        reason: 'the guest, still connected in room ${lobby.code}, must '
            'see the host fixing a seed; got type=${pushed['t']} '
            'data=${pushed['d']}',
      );
      expect(
        pushed['re'],
        isNull,
        reason: 'a broadcast to a socket that did not send the message '
            'must carry no re',
      );
      final Map<String, Object?> data = pushed['d']! as Map<String, Object?>;
      expect(data['seat'], lobby.host.seat);
      expect(data['client_seed'], 'alice-seed');
      expect(data['origin'], 'player');
    });

    test(
        'a seat with no client seed gets a server seed at start_game, origin server, 32 lowercase hex characters',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> hostSeedReply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        hostSeedReply['t'],
        'seat_seed',
        reason: 'the host seat must be able to fix a seed before '
            'start_game for this scenario to isolate the guest seat, '
            'which sets none; got type=${hostSeedReply['t']} '
            'data=${hostSeedReply['d']}',
      );

      lobby.host.client.send('start_game', <String, Object?>{});
      final List<Map<String, Object?>> guestFrames =
          await drainUntil(lobby.guest.client, 'game_started');

      Map<String, Object?>? serverSeedFrame;
      for (final Map<String, Object?> frame in guestFrames) {
        if (frame['t'] != 'seat_seed') {
          continue;
        }
        final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
        if (data['seat'] == lobby.guest.seat) {
          serverSeedFrame = frame;
        }
      }
      expect(
        serverSeedFrame,
        isNotNull,
        reason: 'expected a seat_seed push for seat ${lobby.guest.seat} '
            '(origin server) around start_game on room ${lobby.code}; '
            'frames received on the guest socket were: $guestFrames',
      );
      final Map<String, Object?> data =
          serverSeedFrame!['d']! as Map<String, Object?>;
      expect(
        data['origin'],
        'server',
        reason: 'seat ${lobby.guest.seat} sent no client_seed of its own, '
            'so the server must fix one with origin "server"',
      );
      final Object? seedValue = data['client_seed'];
      expect(
        seedValue,
        isA<String>(),
        reason: 'client_seed on a server-fixed seat_seed must be a string; '
            'got ${seedValue.runtimeType}: $seedValue',
      );
      final String seedValueString = seedValue! as String;
      expect(
        _hex32.hasMatch(seedValueString),
        isTrue,
        reason: 'a server-issued seed must be a 16-byte hex string, 32 '
            'lowercase hex characters; got "$seedValueString" '
            '(length ${seedValueString.length})',
      );
    });

    test('every seat has a non-null client_seed by the time the game starts',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);
      // Neither seat sets a seed: both must be server-assigned at
      // start_game, per section 11.2: "Every seat has a seed by the time
      // the game starts."
      await startGame(lobby);

      lobby.host.client.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.host.token,
      });
      final Map<String, Object?> refreshed = await lobby.host.client.next();
      final Map<String, Object?> roomData =
          refreshed['d']! as Map<String, Object?>;
      final List<Object?> seats = roomData['seats']! as List<Object?>;

      expect(
        seats,
        isNotEmpty,
        reason: 'room ${lobby.code} snapshot has no seats at all after '
            'start_game',
      );
      for (final Object? rawSeat in seats) {
        final Map<String, Object?> seat = rawSeat! as Map<String, Object?>;
        expect(
          seat['client_seed'],
          isNotNull,
          reason: 'seat ${seat['seat']} in room ${lobby.code} has no '
              'client_seed even though start_game has already run',
        );
        expect(
          seat['seed_origin'],
          anyOf('player', 'server'),
          reason: 'seat ${seat['seat']} in room ${lobby.code} has '
              'seed_origin ${seat['seed_origin']}, neither "player" nor '
              '"server"',
        );
      }
    });
  });

  group('game_started: gains and drops, section 11.2', () {
    test('game_started carries a game_id of 16 lowercase hex characters',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> data = await startGame(lobby);
      final Object? gameId = data['game_id'];
      expect(
        gameId,
        isA<String>(),
        reason: 'game_started must carry game_id as a string; got '
            '${gameId.runtimeType}: $gameId',
      );
      final String gameIdValue = gameId! as String;
      expect(
        _hex16.hasMatch(gameIdValue),
        isTrue,
        reason: 'game_id must be exactly 16 lowercase hex characters; got '
            '"$gameIdValue" (length ${gameIdValue.length})',
      );
    });

    test('game_id is not the room code', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> data = await startGame(lobby);
      // Asserted first: an absent game_id is trivially "not equal" to the
      // room code, which would let this test pass without game_id
      // existing at all. The dedicated shape test covers the positive
      // case; this one still has to earn its own pass.
      expect(
        data['game_id'],
        isA<String>(),
        reason: 'game_started must carry game_id as a string before this '
            'test can compare it against the room code; got '
            '${data['game_id'].runtimeType}: ${data['game_id']}',
      );
      expect(
        data['game_id'],
        isNot(equals(lobby.code)),
        reason: 'game_id "${data['game_id']}" must not equal the room code '
            '"${lobby.code}" -- the room code is reissued after 24 hours '
            'and the game_id must not be',
      );
    });

    test(
        'client_seeds is the frozen combined string, seats ascending, seat:seed joined by |',
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> hostSeedReply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        hostSeedReply['t'],
        'seat_seed',
        reason: 'the host seat must be able to fix a seed before '
            'start_game for this scenario; got type=${hostSeedReply['t']} '
            'data=${hostSeedReply['d']}',
      );

      lobby.host.client.send('start_game', <String, Object?>{});
      final List<Map<String, Object?>> guestFrames =
          await drainUntil(lobby.guest.client, 'game_started');

      String? guestServerSeed;
      Map<String, Object?>? gameStartedData;
      for (final Map<String, Object?> frame in guestFrames) {
        final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
        if (frame['t'] == 'seat_seed' && data['seat'] == lobby.guest.seat) {
          guestServerSeed = data['client_seed'] as String?;
        }
        if (frame['t'] == 'game_started') {
          gameStartedData = data;
        }
      }
      expect(
        guestServerSeed,
        isNotNull,
        reason: 'expected a server-assigned seat_seed for seat '
            '${lobby.guest.seat} around start_game; frames were: '
            '$guestFrames',
      );
      expect(
        gameStartedData,
        isNotNull,
        reason: 'expected a game_started push among: $guestFrames',
      );

      final String expected =
          '${lobby.host.seat}:alice-seed|${lobby.guest.seat}:$guestServerSeed';
      expect(
        gameStartedData!['client_seeds'],
        expected,
        reason: 'client_seeds must be the exact frozen combined string, '
            'seats in ascending index, seat:seed joined by |; expected '
            '"$expected", got "${gameStartedData['client_seeds']}"',
      );
    });

    test('game_started has no seed_commit field', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> data = await startGame(lobby);
      expect(
        data.containsKey('seed_commit'),
        isFalse,
        reason: 'seed_commit was the one-seed scheme and must be gone '
            'from game_started (section 11.2 and 11.4); keys present: '
            '${data.keys.toList()}',
      );
    });

    test('game_started does not repeat chain_commit', () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> data = await startGame(lobby);
      expect(
        data.containsKey('chain_commit'),
        isFalse,
        reason: 'chain_commit was already published in room at creation '
            'and must not be repeated on game_started; keys present: '
            '${data.keys.toList()}',
      );
    });

    test('game_id differs between two different games', () async {
      final Uri uri = await start();
      final _Lobby lobbyA = await buildTwoSeatLobby(uri,
          hostName: 'A-Host', guestName: 'A-Guest');
      final _Lobby lobbyB = await buildTwoSeatLobby(uri,
          hostName: 'B-Host', guestName: 'B-Guest');

      final Map<String, Object?> dataA = await startGame(lobbyA);
      final Map<String, Object?> dataB = await startGame(lobbyB);

      expect(
        dataA['game_id'],
        isNot(equals(dataB['game_id'])),
        reason: 'room ${lobbyA.code} and room ${lobbyB.code} both reported '
            'game_id "${dataA['game_id']}"; two different games must not '
            'share one',
      );
    });
  });

  group('a fixed seed never changes, section 11.3', () {
    test("a seat's seed never changes once fixed, even across start_game",
        () async {
      final Uri uri = await start();
      final _Lobby lobby = await buildTwoSeatLobby(uri);

      final Map<String, Object?> setReply = await setSeed(
        lobby.host.client,
        <String, Object?>{'client_seed': 'alice-seed'},
      );
      expect(
        setReply['t'],
        'seat_seed',
        reason: 'setup requires set_seed to succeed for seat '
            '${lobby.host.seat} before start_game; got type=${setReply['t']} '
            'data=${setReply['d']}',
      );

      await startGame(lobby);

      lobby.host.client.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.host.token,
      });
      final Map<String, Object?> refreshed = await lobby.host.client.next();
      final Map<String, Object?> roomData =
          refreshed['d']! as Map<String, Object?>;
      final List<Object?> seats = roomData['seats']! as List<Object?>;

      Map<String, Object?>? hostSeatData;
      for (final Object? rawSeat in seats) {
        final Map<String, Object?> seat = rawSeat! as Map<String, Object?>;
        if (seat['seat'] == lobby.host.seat) {
          hostSeatData = seat;
        }
      }
      expect(
        hostSeatData,
        isNotNull,
        reason: 'seat ${lobby.host.seat} is missing from the room '
            '${lobby.code} snapshot after start_game',
      );
      expect(
        hostSeatData!['client_seed'],
        'alice-seed',
        reason: 'the seed fixed in LOBBY for seat ${lobby.host.seat} must '
            'be unchanged after start_game; got '
            '"${hostSeatData['client_seed']}"',
      );
      expect(
        hostSeatData['seed_origin'],
        'player',
        reason: 'seed_origin for seat ${lobby.host.seat} must stay '
            '"player" after start_game since it was set by the player',
      );
    });
  });
}
