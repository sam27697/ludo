// Conformance tests for `docs/PROTOCOL.md` section 7 (Errors) and section
// 7.1 (Close codes), walked end to end: one group per row of section 7's
// error table, one group per close code in 7.1, and one group for the
// validation order section 7 describes after the table. Every case opens a
// real WebSocket against a real, running `WireServer`
// (`test/support/wire_harness.dart`'s `ServerHarness`) and reads the JSON
// that actually comes back, the same way `fairness_lobby_test.dart` and
// `turn_loop_test.dart` already do for their own sections of the protocol.
//
// Nothing here edits `lib/` or `bin/`. Where a case disagrees with what the
// server does today, the case is left red on purpose and its `reason:`
// names the exact behaviour observed; see this file's own report for the
// list and the spec line each one breaks.
//
// `test/support/wire_harness.dart`'s `WireTestClient` always emits a
// well-formed `{v: 1, t: ..., id: ..., d: ...}` envelope, so a handful of
// cases that need to break the envelope itself -- an unsupported `v`, a
// top-level JSON value that is not an object, raw bytes pinned to an exact
// length, a binary frame, and reading the close code the server actually
// sent -- use `test/support/raw_wire_client.dart`'s `RawWireClient`
// instead, written for this file because no existing suite needed that
// level of control.

import 'dart:convert';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' show GameState;
import 'package:ludo_server/ludo_server.dart'
    show Room, RoomState, maxFrameBytes;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/engine_search.dart';
import 'support/raw_wire_client.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

/// The exact JSON text of a minimal, well-formed `ping` envelope, built
/// without going through `WireTestClient` so a raw socket can send it too.
String _pingEnvelope({required String id}) => jsonEncode(<String, Object?>{
      'v': 1,
      't': 'ping',
      'id': id,
      'd': <String, Object?>{},
    });

/// Builds a `create_room` frame whose total byte length on the wire is
/// exactly [targetBytes], by padding an extra, intentionally-unrecognised
/// `pad` field in `d` with enough `x` characters to make up the difference.
/// `x` is a single ASCII byte in UTF-8 and `jsonEncode` never escapes it, so
/// each added character grows the encoded text by exactly one byte -- the
/// padding arithmetic below is exact, not approximate, and is checked
/// against the real encoded length before this returns.
///
/// The resulting frame is never size-valid-and-otherwise-valid: `pad` is not
/// one of `create_room`'s allowed keys (`name`, `players`, `rules`), so a
/// frame built this way that passes the size check still gets `BAD_FIELD`
/// from `_handleCreateRoom`'s own allow-list, never silently succeeds. That
/// is deliberate -- the only thing a case using this helper is allowed to
/// conclude is whether the frame was rejected *for its size*, not anything
/// about the rest of its validity.
String _paddedCreateRoomFrame({required String id, required int targetBytes}) {
  String build(int padLength) {
    final Map<String, Object?> data = <String, Object?>{
      'name': 'Host',
      'players': 2,
      'pad': 'x' * padLength,
    };
    return jsonEncode(<String, Object?>{
      'v': 1,
      't': 'create_room',
      'id': id,
      'd': data,
    });
  }

  final int baseBytes = utf8.encode(build(0)).length;
  final int padLength = targetBytes - baseBytes;
  if (padLength < 0) {
    throw ArgumentError(
      'the unpadded frame is already $baseBytes bytes, more than the '
      'requested targetBytes ($targetBytes); choose a larger targetBytes',
    );
  }
  final String result = build(padLength);
  final int actualBytes = utf8.encode(result).length;
  if (actualBytes != targetBytes) {
    throw StateError(
      'padding arithmetic is wrong: wanted $targetBytes bytes, built '
      '$actualBytes',
    );
  }
  return result;
}

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];
  final List<RawWireClient> rawClients = <RawWireClient>[];

  setUp(() {
    harness = ServerHarness.build();
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    for (final RawWireClient client in rawClients) {
      await client.close();
    }
    rawClients.clear();
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

  Future<RawWireClient> connectRaw(Uri uri) async {
    final RawWireClient client = await RawWireClient.connect(uri);
    rawClients.add(client);
    return client;
  }

  WireTestSeat seatFor(WireTestLobby lobby, int seat) =>
      seat == lobby.host.seat ? lobby.host : lobby.guest;

  /// Sends `start_game` from the host and waits for `game_started` on both
  /// sockets, then the standalone `turn` frame section 13.1 requires
  /// immediately after it, on both sockets. Returns the host's
  /// `game_started` payload. Identical in shape to the same-named helper in
  /// `fairness_lobby_test.dart` and `turn_loop_test.dart`; this file keeps
  /// its own copy for the same reason those two do not share one.
  Future<Map<String, Object?>> startGame(WireTestLobby lobby) async {
    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostFrame = await receiveType(
      lobby.host.client,
      'game_started',
    );
    final Map<String, Object?> hostData =
        hostFrame['d']! as Map<String, Object?>;
    final Object? startingSeat = hostData['turn'];
    await expectOpeningTurn(lobby.host.client, startingSeat);
    await receiveType(lobby.guest.client, 'game_started');
    await expectOpeningTurn(lobby.guest.client, startingSeat);
    return hostData;
  }

  /// A fresh two-seat room, started, then forced straight to FINISHED by
  /// mutating `Room.state` directly -- the same technique
  /// `turn_loop_test.dart`'s own GAME_OVER cases use, documented there as
  /// the only way available to a test with no control over a natural win:
  /// `room.dart` itself says the turn loop is expected to mutate `Room.game`
  /// and `Room.state` directly for every in-play change, and this exercises
  /// the real wire handlers against a real, FINISHED `Room` built that way.
  /// Returns the lobby and the seat that was on turn at the moment it was
  /// forced FINISHED.
  Future<(WireTestLobby, int)> finishedLobby() async {
    final Uri uri = await start();
    final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
    final Map<String, Object?> started = await startGame(lobby);
    final int onTurn = started['turn']! as int;
    final Room? room = harness.registry.lookup(lobby.code);
    expect(
      room,
      isNotNull,
      reason: 'room ${lobby.code} must still exist in the registry for '
          'this test to force it FINISHED',
    );
    room!.state = RoomState.finished;
    return (lobby, onTurn);
  }

  // -----------------------------------------------------------------------
  // Dice steering, trimmed to what this file actually needs: a state where
  // a roll leaves exactly one legal move pending (any face that leaves a
  // legal move at all, for the WRONG_PHASE "move pending" case) and a state
  // where a roll leaves a *partial* legal list -- some but not all four
  // tokens -- so a well-formed token outside it exists to prove
  // ILLEGAL_MOVE against. Modelled on `turn_loop_test.dart`'s own
  // `buildSteeredLobby`/`driveToSteeredRoll`, which this file does not
  // import because that file keeps those helpers private to itself, the
  // same way `fairness_lobby_test.dart` keeps its own `receiveType`/
  // `drainUntil` private rather than sharing wire_harness.dart's promoted
  // copies retroactively.
  // -----------------------------------------------------------------------
  const List<int> steeredSeats = <int>[0, 2];
  const String hostSteerSeed = 'protocol-conformance-host-seed';
  const String guestSteerSeed = 'protocol-conformance-guest-seed';
  const String steerClientSeeds = '0:$hostSteerSeed|2:$guestSteerSeed';

  String predictedGameId() {
    final List<int> probe =
        buildScript(secret: List<int>.filled(serverSecretDraws, 0));
    return hexEncode(probe.sublist(gameIdOffset, gameIdOffset + gameIdDraws));
  }

  Future<(WireTestLobby, Map<String, Object?>)> buildSteeredLobby(
    List<int> wanted,
  ) async {
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
        await buildWireTestLobby(uri, clients, players: 2);
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      steeredSeats,
      reason: 'this steering helper assumes the fixed 2-player seat mapping '
          '(host=0, guest=2, lib/src/registry.dart:967-978); got host='
          '${lobby.host.seat} guest=${lobby.guest.seat}',
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
    expect(startedData['client_seeds'], steerClientSeeds);

    return (lobby, startedData);
  }

  /// Drives [faces] one roll at a time on whichever socket currently holds
  /// the turn, moving `legal.first` after every roll except the last one,
  /// and returns the lobby, the seat the last roll belongs to, and that
  /// roll's own `rolled` payload, untouched. Reads only off the acting
  /// seat's own socket -- unlike `turn_loop_test.dart`'s equivalent, this
  /// file never needs to inspect the other seat's broadcast copy, because
  /// nothing downstream of these two helpers ever reads from the other
  /// socket again.
  Future<(WireTestLobby, int, Map<String, Object?>)> driveToSteeredRoll(
    List<int> faces,
  ) async {
    final (WireTestLobby lobby, Map<String, Object?> started) =
        await buildSteeredLobby(faces);
    int current = started['turn']! as int;
    Map<String, Object?>? lastData;
    for (int i = 0; i < faces.length; i++) {
      final bool isLast = i == faces.length - 1;
      final WireTestSeat actor = seatFor(lobby, current);
      actor.client.send('roll', <String, Object?>{});
      final Map<String, Object?> rolledFrame = await actor.client.next();
      expect(
        rolledFrame['t'],
        'rolled',
        reason: 'steered roll ${i + 1}/${faces.length} (face ${faces[i]}): '
            'expected rolled from seat $current, got "${rolledFrame['t']}": '
            '${rolledFrame['d']}',
      );
      final Map<String, Object?> data =
          rolledFrame['d']! as Map<String, Object?>;
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
        final Map<String, Object?> passed = await actor.client.next();
        expect(passed['t'], 'turn_passed');
        final Map<String, Object?> turnFrame = await actor.client.next();
        expect(turnFrame['t'], 'turn');
        current = (turnFrame['d']! as Map<String, Object?>)['seat']! as int;
      } else {
        actor.client.send('move', <String, Object?>{'token': legal.first});
        final Map<String, Object?> movedFrame = await actor.client.next();
        expect(
          movedFrame['t'],
          'moved',
          reason: 'steered roll ${i + 1}/${faces.length}: expected moved '
              'after driving the first legal move, got '
              '"${movedFrame['t']}": ${movedFrame['d']}',
        );
        final Map<String, Object?> after = await actor.client.next();
        expect(
          after['t'],
          'turn',
          reason: 'the steered face sequence $faces must not reach '
              'game_over before its last roll; got "${after['t']}" instead',
        );
        current = (after['d']! as Map<String, Object?>)['seat']! as int;
      }
    }
    return (lobby, current, lastData!);
  }

  Future<(WireTestLobby, int, Map<String, Object?>)> freshLegalRoll() async {
    final List<int>? faces = findFaceSequence(
      seats: steeredSeats,
      accepts: (EngineRollStep step, GameState state) => step.legal.isNotEmpty,
    );
    expect(
      faces,
      isNotNull,
      reason: 'test/support/engine_search.dart found no face, within its '
          'own bound, that leaves a legal move on the first roll of a '
          'fresh two-seat game; docs/RULES.md rule 17 says a 6 always does',
    );
    return driveToSteeredRoll(faces!);
  }

  Future<(WireTestLobby, int, Map<String, Object?>)> partialLegalRoll() async {
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
          'neither empty nor all four tokens',
    );
    return driveToSteeredRoll(faces!);
  }

  // =========================================================================
  // 1. PROTOCOL_VERSION
  // =========================================================================
  group('PROTOCOL_VERSION, section 7 and close code 4002 (section 7.1)', () {
    test(
        'an unsupported v closes the connection with 4002, after an error '
        'frame', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendText(jsonEncode(<String, Object?>{
        'v': 2,
        't': 'ping',
        'id': 'protocol-version-case-unsupported',
        'd': <String, Object?>{},
      }));
      final RawFrame frame = await raw.next();
      expect(frame.decoded?['t'], 'error',
          reason: 'expected an error frame, got $frame');
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(data['code'], 'PROTOCOL_VERSION');
      final int? closeCode = await raw.waitClosed();
      expect(
        closeCode,
        4002,
        reason: 'docs/PROTOCOL.md section 7.1: PROTOCOL_VERSION closes '
            'with 4002; got $closeCode',
      );
    });

    test('v missing entirely is also PROTOCOL_VERSION', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendText(jsonEncode(<String, Object?>{
        't': 'ping',
        'id': 'protocol-version-case-missing',
        'd': <String, Object?>{},
      }));
      final RawFrame frame = await raw.next();
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(data['code'], 'PROTOCOL_VERSION',
          reason: 'a missing v is not a supported version either; got '
              '$frame');
    });

    test(
        'v as a JSON string "1" is also PROTOCOL_VERSION, not accepted as '
        'the integer 1', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendText(jsonEncode(<String, Object?>{
        'v': '1',
        't': 'ping',
        'id': 'protocol-version-case-string',
        'd': <String, Object?>{},
      }));
      final RawFrame frame = await raw.next();
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(data['code'], 'PROTOCOL_VERSION',
          reason: 'docs/PROTOCOL.md section 1: v is "integer, currently 1" '
              '-- the JSON string "1" is not that integer; got $frame');
    });
  });

  // =========================================================================
  // 2. BAD_TYPE
  // =========================================================================
  group('BAD_TYPE, section 7', () {
    test('an unknown t is BAD_TYPE, connection stays open and usable',
        () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      client.send('not_a_real_message_type', <String, Object?>{});
      final Map<String, Object?> reply = await client.next();
      expectErrorFrame(reply, 'BAD_TYPE',
          because: 'this type is not in docs/PROTOCOL.md section 4 or 5');

      client.send('ping', <String, Object?>{});
      final Map<String, Object?> pong = await client.next();
      expect(pong['t'], 'pong',
          reason: 'BAD_TYPE must not close the connection');
    });
  });

  // =========================================================================
  // 3. BAD_FIELD: missing, wrong type, out of range, unknown extra field
  // =========================================================================
  group('BAD_FIELD, section 7', () {
    test('missing field: name absent entirely', () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      client.send('create_room', <String, Object?>{'players': 2});
      final Map<String, Object?> reply = await client.next();
      expectErrorFrame(reply, 'BAD_FIELD',
          because: 'name was absent from d entirely');
    });

    test('wrong type: name is a JSON number, not a string', () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      client.send('create_room', <String, Object?>{'name': 123, 'players': 2});
      final Map<String, Object?> reply = await client.next();
      expectErrorFrame(reply, 'BAD_FIELD',
          because: 'name was the JSON number 123, not a string');
    });

    test('out of range: rules.turn_seconds outside 15..120', () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      client.send('create_room', <String, Object?>{
        'name': 'Host',
        'players': 2,
        'rules': <String, Object?>{'turn_seconds': 200},
      });
      final Map<String, Object?> reply = await client.next();
      expectErrorFrame(reply, 'BAD_FIELD',
          because: 'turn_seconds was 200, outside the 15..120 range '
              'docs/PROTOCOL.md section 4 allows');
    });

    test('unknown extra field: an unrecognised top-level key in d', () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      client.send('create_room', <String, Object?>{
        'name': 'Host',
        'players': 2,
        'bogus': true,
      });
      final Map<String, Object?> reply = await client.next();
      expectErrorFrame(reply, 'BAD_FIELD',
          because: '"bogus" is not one of name/players/rules, '
              "docs/PROTOCOL.md section 4's own allow-list for create_room");
    });
  });

  // =========================================================================
  // 4. TOO_LARGE, and close code 4001 (section 7.1)
  // =========================================================================
  group('TOO_LARGE, section 7 and close code 4001 (section 7.1)', () {
    test('8193 bytes is rejected without parsing, closes with 4001, no re',
        () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      final String text = _paddedCreateRoomFrame(
        id: 'too-large-case-well-formed-id',
        targetBytes: maxFrameBytes + 1,
      );
      raw.sendText(text);
      final RawFrame frame = await raw.next();
      expect(frame.decoded?['t'], 'error');
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(data['code'], 'TOO_LARGE');
      expect(
        frame.decoded?['re'],
        isNull,
        reason: 'docs/PROTOCOL.md section 7: TOO_LARGE is checked before '
            'JSON parsing, so there is no usable id to echo, even though '
            'this frame\'s own id was well-formed',
      );
      final int? closeCode = await raw.waitClosed();
      expect(
        closeCode,
        4001,
        reason: 'docs/PROTOCOL.md section 7.1: TOO_LARGE closes with '
            '4001; got $closeCode',
      );
    });

    test('exactly 8192 bytes of a valid frame is not rejected for size',
        () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      final String text = _paddedCreateRoomFrame(
        id: 'too-large-case-exact-boundary',
        targetBytes: maxFrameBytes,
      );
      raw.sendText(text);
      final RawFrame frame = await raw.next();
      // This frame is still invalid for an unrelated reason -- "pad" is not
      // an allowed create_room field -- so the server must answer
      // BAD_FIELD, never TOO_LARGE, and must never close for it.
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(
        data['code'],
        'BAD_FIELD',
        reason: 'a frame of exactly $maxFrameBytes bytes must pass the '
            'size check; expected the "pad" field to be rejected as an '
            'unknown extra field instead of the frame being rejected for '
            'its size; got ${frame.decoded}',
      );
      raw.sendText(_pingEnvelope(id: 'too-large-case-still-open'));
      final RawFrame pong = await raw.next();
      expect(
        pong.decoded?['t'],
        'pong',
        reason: 'the connection must still be open and usable after an '
            'exactly-$maxFrameBytes-byte frame',
      );
    });
  });

  // =========================================================================
  // 5. Garbage bytes: not JSON, JSON not an object, a binary frame
  // =========================================================================
  group(
      'garbage bytes, section 7 (unspecified cases pinned to today\'s '
      'behaviour)', () {
    test(
        'not JSON at all is BAD_FIELD, connection stays open (unspecified, '
        'pinned)', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendText('this is not { json at all');
      final RawFrame frame = await raw.next();
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(
        data['code'],
        'BAD_FIELD',
        reason: 'docs/PROTOCOL.md section 7 names "JSON parse" as a '
            'ladder step but does not name an error code for a parse '
            'failure; pinning the server\'s current choice, BAD_FIELD',
      );
      expect(frame.decoded?['re'], isNull);
      raw.sendText(_pingEnvelope(id: 'garbage-case-not-json-still-open'));
      final RawFrame pong = await raw.next();
      expect(pong.decoded?['t'], 'pong',
          reason: 'a JSON parse failure must not close the connection');
    });

    test(
        'valid JSON that is not an object is BAD_FIELD (unspecified, '
        'pinned)', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendText(jsonEncode(<Object?>['not', 'an', 'object']));
      final RawFrame frame = await raw.next();
      final Map<String, Object?> data =
          frame.decoded!['d']! as Map<String, Object?>;
      expect(
        data['code'],
        'BAD_FIELD',
        reason: 'docs/PROTOCOL.md section 1 defines the envelope as an '
            'object; the spec does not separately name an error for a '
            'top-level JSON array, string or number, so this pins the '
            'server\'s current choice, BAD_FIELD',
      );
      raw.sendText(_pingEnvelope(id: 'garbage-case-not-object-still-open'));
      final RawFrame pong = await raw.next();
      expect(pong.decoded?['t'], 'pong');
    });

    test(
        'a binary frame carrying a well-formed JSON envelope is processed '
        'exactly like a text frame (unspecified, pinned)', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      final String text = _pingEnvelope(id: 'binary-case-well-formed');
      raw.sendBytes(utf8.encode(text));
      final RawFrame frame = await raw.next();
      expect(
        frame.decoded?['t'],
        'pong',
        reason: 'docs/PROTOCOL.md section 1 says messages are JSON, UTF-8, '
            'one per frame, but does not say a binary WebSocket frame is '
            'treated any differently from a text one carrying the same '
            'bytes; pinning the server\'s current choice, which decodes '
            'either kind of frame the same way (lib/src/connection.dart '
            'handleFrame)',
      );
    });

    test(
        'a binary frame that is not valid UTF-8 ends the connection with '
        'no error frame and no close code (unspecified, pinned)', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendBytes(<int>[0xFF, 0xFE, 0xFD]);
      // There is nothing to wait for: the server's read loop has died
      // without sending anything, so no frame and no close ever arrives.
      // Proving that is a short, bounded wait for silence, not a sleep
      // standing in for a condition -- the condition being proven is the
      // absence of a response, which a short timeout observes exactly as
      // reliably as a long one would, since nothing on the server side is
      // still running that could answer late.
      bool timedOutWithNoFrame = false;
      try {
        await raw.next(timeout: const Duration(milliseconds: 500));
      } on TestFailure {
        timedOutWithNoFrame = true;
      }
      expect(
        timedOutWithNoFrame,
        isTrue,
        reason: 'docs/PROTOCOL.md section 7 does not cover a binary frame '
            'whose bytes are not valid UTF-8. The server today lets '
            'utf8.decode throw inside Connection.handleFrame, uncaught; '
            "wire_server.dart's _pump catches it in the same catch block "
            'that treats an ordinary disconnect this way, breaking out of '
            'its read loop with no error frame ever sent. Pinning that '
            'observed behaviour, not asserting it is correct',
      );
      expect(
        raw.closeCode,
        isNull,
        reason: 'the server never calls Connection.close for this path '
            'either (only handleDisconnect, which does not touch the '
            'socket), so dart:io never sees a close frame and closeCode '
            'stays null; pinning that observed behaviour, not asserting '
            'it is correct',
      );
    });
  });

  // =========================================================================
  // 6. NO_SUCH_ROOM
  // =========================================================================
  group('NO_SUCH_ROOM, section 7', () {
    test('a never-issued code', () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      client
          .send('join_room', <String, Object?>{'code': 'ZZZZZZ', 'name': 'P'});
      final Map<String, Object?> reply = await client.next();
      expectErrorFrame(reply, 'NO_SUCH_ROOM',
          because: 'code ZZZZZZ was never created in this harness');
    });

    test(
        "an expired room's code answers the identical frame, minus re, as "
        'a never-issued one', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
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
        reason: 'setup requires room ${lobby.code} to actually be reaped',
      );
      expect(harness.registry.lookup(lobby.code), isNull);

      final WireTestClient strayExpired = await connect(uri);
      strayExpired.send(
          'join_room', <String, Object?>{'code': lobby.code, 'name': 'P'});
      final Map<String, Object?> expiredReply = await strayExpired.next();

      final WireTestClient strayNever = await connect(uri);
      strayNever
          .send('join_room', <String, Object?>{'code': 'QWERTY', 'name': 'P'});
      final Map<String, Object?> neverReply = await strayNever.next();

      expect(expiredReply['t'], 'error');
      expect(neverReply['t'], 'error');
      final Map<String, Object?> expiredData =
          expiredReply['d']! as Map<String, Object?>;
      final Map<String, Object?> neverData =
          neverReply['d']! as Map<String, Object?>;
      expect(
        expiredData,
        neverData,
        reason: 'room ${lobby.code}, which existed and was reaped, must '
            'answer the identical d (code and message; re is a separate '
            'envelope field and is not part of this comparison) as a code '
            'that was never issued at all -- existence must not leak '
            'through a difference between the two; expired=$expiredData '
            'never=$neverData',
      );
      expect(expiredData['code'], 'NO_SUCH_ROOM',
          reason: 'both must actually be NO_SUCH_ROOM, not merely equal '
              'to each other by both being some other, wrong code');
    });
  });

  // =========================================================================
  // 7. ROOM_FULL, ROOM_STARTED, NOT_HOST, NOT_ENOUGH_PLAYERS (both forms)
  // =========================================================================
  group('ROOM_FULL, ROOM_STARTED, NOT_HOST, NOT_ENOUGH_PLAYERS, section 7', () {
    test('ROOM_FULL: every configured seat already taken', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      final WireTestClient third = await connect(uri);
      third.send(
          'join_room', <String, Object?>{'code': lobby.code, 'name': 'Third'});
      final Map<String, Object?> reply = await third.next();
      expectErrorFrame(reply, 'ROOM_FULL',
          because: 'room ${lobby.code} is a 2-player room with both seats '
              'already taken');
    });

    test('ROOM_STARTED: join attempted on a room that has left LOBBY',
        () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      await startGame(lobby);
      final WireTestClient third = await connect(uri);
      third.send(
          'join_room', <String, Object?>{'code': lobby.code, 'name': 'Third'});
      final Map<String, Object?> reply = await third.next();
      expectErrorFrame(reply, 'ROOM_STARTED',
          because: 'room ${lobby.code} is PLAYING, not LOBBY');
    });

    test('NOT_HOST: start_game from a non-host seat', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      lobby.guest.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.guest.client.next();
      expectErrorFrame(reply, 'NOT_HOST',
          because: 'seat ${lobby.guest.seat} in room ${lobby.code} is not '
              'the host (seat ${lobby.host.seat} is)');
    });

    test(
        'NOT_ENOUGH_PLAYERS, form 1: start_game with an empty seat still in '
        'the room', () async {
      final Uri uri = await start();
      final WireTestClient host = await connect(uri);
      host.send('create_room', <String, Object?>{'name': 'Solo', 'players': 3});
      await host.next(); // seat_assigned
      await host.next(); // room
      host.send('start_game', <String, Object?>{});
      final Map<String, Object?> reply = await host.next();
      expectErrorFrame(reply, 'NOT_ENOUGH_PLAYERS',
          because: 'the room is configured for 3 players and only 1 seat '
              'is occupied');
    });

    test('NOT_ENOUGH_PLAYERS, form 2: set_players below current occupancy',
        () async {
      final Uri uri = await start();
      final WireTestClient host = await connect(uri);
      host.send('create_room', <String, Object?>{'name': 'Host', 'players': 4});
      await host.next(); // seat_assigned
      final Map<String, Object?> hostRoomFrame = await host.next();
      final String code =
          (hostRoomFrame['d']! as Map<String, Object?>)['code']! as String;

      final WireTestClient guest1 = await connect(uri);
      guest1
          .send('join_room', <String, Object?>{'code': code, 'name': 'Guest1'});
      await guest1.next(); // seat_assigned
      await guest1.next(); // room
      await host.next(); // player_joined

      final WireTestClient guest2 = await connect(uri);
      guest2
          .send('join_room', <String, Object?>{'code': code, 'name': 'Guest2'});
      await guest2.next(); // seat_assigned
      await guest2.next(); // room
      await host.next(); // player_joined
      await guest1.next(); // player_joined

      host.send('set_players', <String, Object?>{'players': 2});
      final Map<String, Object?> reply = await host.next();
      expectErrorFrame(reply, 'NOT_ENOUGH_PLAYERS',
          because: 'room $code has 3 seats occupied and set_players asked '
              'for only 2');
    });
  });

  // =========================================================================
  // 8. NOT_YOUR_TURN
  // =========================================================================
  group('NOT_YOUR_TURN, section 7 and 12', () {
    test('roll from the seat not on turn', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;
      final WireTestSeat actor = seatFor(lobby, offTurn);
      actor.client.send('roll', <String, Object?>{});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'NOT_YOUR_TURN',
          because: 'seat $onTurn holds the turn in room ${lobby.code}, not '
              'seat $offTurn');
    });

    test(
        'move from the seat not on turn, naming a token that would be legal '
        'for the seat actually on turn', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;
      final WireTestSeat actor = seatFor(lobby, offTurn);
      // Token 0 is a well-formed token index; move carries no seat field at
      // all, so which seat's piece this index would name is decided
      // entirely by the sender's own identity, never by this value.
      actor.client.send('move', <String, Object?>{'token': 0});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'NOT_YOUR_TURN',
          because: 'seat $onTurn holds the turn in room ${lobby.code}, not '
              'seat $offTurn, regardless of which token index was named');
    });
  });

  // =========================================================================
  // 9. WRONG_PHASE
  // =========================================================================
  group('WRONG_PHASE, section 7 and 12', () {
    test('move while the turn is awaiting a roll, not a move', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final WireTestSeat actor = seatFor(lobby, onTurn);
      actor.client.send('move', <String, Object?>{'token': 0});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'WRONG_PHASE',
          because: 'seat $onTurn in room ${lobby.code} has not rolled yet '
              'this segment');
    });

    test('roll while a move is pending', () async {
      final (WireTestLobby lobby, int onTurn, _) = await freshLegalRoll();
      final WireTestSeat actor = seatFor(lobby, onTurn);
      actor.client.send('roll', <String, Object?>{});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'WRONG_PHASE',
          because: 'seat $onTurn in room ${lobby.code} already rolled this '
              'segment and a move is pending');
    });
  });

  // =========================================================================
  // 10. ILLEGAL_MOVE
  // =========================================================================
  group('ILLEGAL_MOVE, section 7 and 12.2', () {
    test('a well-formed token that is not in the current legal list', () async {
      final (WireTestLobby lobby, int onTurn, Map<String, Object?> rolled) =
          await partialLegalRoll();
      final List<int> legal = (rolled['legal']! as List<Object?>).cast<int>();
      final int illegalToken =
          <int>[0, 1, 2, 3].firstWhere((int t) => !legal.contains(t));
      final WireTestSeat actor = seatFor(lobby, onTurn);
      actor.client.send('move', <String, Object?>{'token': illegalToken});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'ILLEGAL_MOVE',
          because: 'token $illegalToken is well-formed but is not in the '
              'legal list $legal for this roll');
    });
  });

  // =========================================================================
  // 11. Replayed request id
  // =========================================================================
  group('replayed request id, section 1 and 7 (unspecified, pinned)', () {
    test(
        'the same id resent for move is evaluated fresh against the '
        'current state, not deduplicated (unspecified, pinned)', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);
      final Map<String, Object?> started = await startGame(lobby);
      final int onTurn = started['turn']! as int;
      final WireTestSeat actor = seatFor(lobby, onTurn);
      const String rollId = 'replay-roll-0001';

      actor.client.send('roll', <String, Object?>{}, id: rollId);
      final Map<String, Object?> first = await actor.client.next();
      expect(
        first['t'],
        'rolled',
        reason: 'setup requires the first roll to be accepted; got '
            '${first['t']}: ${first['d']}',
      );
      expect(first['re'], rollId);
      final List<int> legal =
          ((first['d']! as Map<String, Object?>)['legal']! as List<Object?>)
              .cast<int>();

      int currentTurnSeat = onTurn;
      if (legal.isEmpty) {
        final Map<String, Object?> passed = await actor.client.next();
        expect(passed['t'], 'turn_passed');
        final Map<String, Object?> turnFrame = await actor.client.next();
        expect(turnFrame['t'], 'turn');
        currentTurnSeat =
            (turnFrame['d']! as Map<String, Object?>)['seat']! as int;
      }

      // Resend the exact same frame: same type, same (empty) payload, same
      // id as the accepted roll above.
      actor.client.send('roll', <String, Object?>{}, id: rollId);
      final Map<String, Object?> replay = await actor.client.next();

      expect(
        replay['t'],
        'error',
        reason: 'docs/PROTOCOL.md does not say a replayed id is '
            'deduplicated or answered with a cached copy of the first '
            'reply; pinning the server\'s current behaviour, which '
            'evaluates the replay fresh against whatever state the room '
            'is in by then',
      );
      expect(
        replay['re'],
        rollId,
        reason: 'the id still passes the id shape check on the replay, so '
            'it is still echoed as re, even though this exact id was '
            'already used once',
      );
      if (legal.isEmpty) {
        expectErrorFrame(replay, 'NOT_YOUR_TURN',
            because: 'seat $onTurn\'s turn already passed to seat '
                '$currentTurnSeat; a replayed roll from $onTurn is simply '
                'an off-turn roll by the time it is resent');
      } else {
        expectErrorFrame(replay, 'WRONG_PHASE',
            because: 'seat $onTurn is still on turn but is now awaiting a '
                'move, not a roll; a replayed roll is simply a second roll '
                'while a move is pending');
      }
    });
  });

  // =========================================================================
  // 12. BAD_SEAT_TOKEN
  // =========================================================================
  group('BAD_SEAT_TOKEN, section 7', () {
    test('resume with a wrong seat token for an otherwise real room', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      final WireTestClient stray = await connect(uri);
      stray.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': 'this-token-was-never-issued-by-anyone',
      });
      final Map<String, Object?> reply = await stray.next();
      expectErrorFrame(reply, 'BAD_SEAT_TOKEN',
          because: 'room ${lobby.code} is real but this token matches '
              'none of its seats');
    });
  });

  // =========================================================================
  // 13. SEED_ALREADY_SET
  // =========================================================================
  group('SEED_ALREADY_SET, section 7 and 11.2', () {
    test('a second set_seed from the same seat', () async {
      final Uri uri = await start();
      final WireTestLobby lobby =
          await buildWireTestLobby(uri, clients, players: 2);
      lobby.host.client
          .send('set_seed', <String, Object?>{'client_seed': 'first-seed'});
      final Map<String, Object?> first = await lobby.host.client.next();
      expect(
        first['t'],
        'seat_seed',
        reason: 'setup requires the first set_seed from seat '
            '${lobby.host.seat} to succeed; got ${first['t']}: '
            '${first['d']}',
      );
      lobby.host.client
          .send('set_seed', <String, Object?>{'client_seed': 'second-seed'});
      final Map<String, Object?> second = await lobby.host.client.next();
      expectErrorFrame(second, 'SEED_ALREADY_SET',
          because: 'seat ${lobby.host.seat} in room ${lobby.code} already '
              'fixed a seed');
    });
  });

  // =========================================================================
  // 14. GAME_OVER: refused list and allowed list
  // =========================================================================
  group('GAME_OVER, section 7', () {
    test(
        'refused: start_game against a FINISHED room '
        '(red -- see report: server answers ROOM_STARTED today)', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(
        reply,
        'GAME_OVER',
        because: 'docs/PROTOCOL.md section 7 defines GAME_OVER as "any '
            'action against a FINISHED room, except rematch, resume, '
            'leave_room, game_log and ping" -- start_game is not excepted, '
            'and room ${lobby.code} is FINISHED. The server today answers '
            'ROOM_STARTED instead: lib/src/connection.dart '
            '_handleStartGame and lib/src/registry.dart startGame both '
            'only check "state != lobby" ahead of payload validation, '
            'collapsing PLAYING and FINISHED into one ROOM_STARTED branch '
            'rather than giving FINISHED its own GAME_OVER check the way '
            '_turnLadderError already does for roll and move. This is the '
            'finding, left red on purpose.',
      );
    });

    test(
        'refused: set_players against a FINISHED room '
        '(red -- see report: server answers ROOM_STARTED today)', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('set_players', <String, Object?>{'players': 2});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(
        reply,
        'GAME_OVER',
        because: 'docs/PROTOCOL.md section 7: set_players is not in the '
            'GAME_OVER exception list (rematch, resume, leave_room, '
            'game_log, ping), and room ${lobby.code} is FINISHED. The '
            'server today answers ROOM_STARTED instead: '
            'lib/src/connection.dart _handleSetPlayers and '
            'lib/src/registry.dart setPlayers both only check "state != '
            'lobby", the same collapse as start_game above. This is the '
            'finding, left red on purpose.',
      );
    });

    test(
        'refused: set_seed against a FINISHED room '
        '(red -- see report: server answers WRONG_PHASE today)', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('set_seed', <String, Object?>{'client_seed': 'x'});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expectErrorFrame(
        reply,
        'GAME_OVER',
        because: 'docs/PROTOCOL.md section 7: set_seed is not in the '
            'GAME_OVER exception list, and room ${lobby.code} is '
            'FINISHED. The server today answers WRONG_PHASE instead: '
            'lib/src/connection.dart _handleSetSeed and '
            'lib/src/registry.dart setSeed both check only "state != '
            'lobby" ahead of seat authorisation, with no separate '
            'FINISHED/GAME_OVER branch. This is the finding, left red on '
            'purpose.',
      );
    });

    test(
        'refused: roll against a FINISHED room answers GAME_OVER, not a '
        'lower rung', () async {
      final (WireTestLobby lobby, int onTurn) = await finishedLobby();
      final int offTurn =
          onTurn == lobby.host.seat ? lobby.guest.seat : lobby.host.seat;
      final WireTestSeat actor = seatFor(lobby, offTurn);
      actor.client.send('roll', <String, Object?>{});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'GAME_OVER',
          because: 'room ${lobby.code} is FINISHED; seat $offTurn is also '
              'not on turn, which must not surface as NOT_YOUR_TURN '
              'instead');
    });

    test(
        'refused: move against a FINISHED room answers GAME_OVER, not a '
        'lower rung', () async {
      final (WireTestLobby lobby, int onTurn) = await finishedLobby();
      final WireTestSeat actor = seatFor(lobby, onTurn);
      actor.client.send('move', <String, Object?>{'token': 0});
      final Map<String, Object?> reply = await actor.client.next();
      expectErrorFrame(reply, 'GAME_OVER',
          because: 'room ${lobby.code} is FINISHED');
    });

    test(
        'allowed: rematch against a FINISHED room is never answered '
        'GAME_OVER', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('rematch', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(
        reply['t'],
        isNot('error'),
        reason: 'rematch is on the GAME_OVER exception list; room '
            '${lobby.code} is FINISHED and the reply was ${reply['t']}: '
            '${reply['d']}',
      );
    });

    test(
        'allowed: resume against a FINISHED room is never answered '
        'GAME_OVER', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.host.token,
      });
      final Map<String, Object?> assigned = await lobby.host.client.next();
      expect(
        assigned['t'],
        'seat_assigned',
        reason: 'resume on a FINISHED room must still answer seat_assigned '
            'then room; got ${assigned['t']}: ${assigned['d']}',
      );
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(
        reply['t'],
        isNot('error'),
        reason: 'resume is on the GAME_OVER exception list; got '
            '${reply['t']}: ${reply['d']}',
      );
    });

    test(
        'allowed: leave_room against a FINISHED room is never answered '
        'GAME_OVER', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('leave_room', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(
        reply['t'],
        isNot('error'),
        reason: 'leave_room is on the GAME_OVER exception list; got '
            '${reply['t']}: ${reply['d']}',
      );
    });

    test(
        'allowed: game_log against a FINISHED room is never answered '
        'GAME_OVER', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('game_log', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(
        reply['t'],
        isNot('error'),
        reason: 'game_log is on the GAME_OVER exception list; got '
            '${reply['t']}: ${reply['d']}',
      );
    });

    test(
        'allowed: ping against a FINISHED room is never answered '
        'GAME_OVER', () async {
      final (WireTestLobby lobby, int _) = await finishedLobby();
      lobby.host.client.send('ping', <String, Object?>{});
      final Map<String, Object?> reply = await lobby.host.client.next();
      expect(
        reply['t'],
        'pong',
        reason: 'ping is on the GAME_OVER exception list; got '
            '${reply['t']}: ${reply['d']}',
      );
    });
  });

  // =========================================================================
  // 15. RATE_LIMITED
  // =========================================================================
  group('RATE_LIMITED, section 7', () {
    test('create_room: 5 per hour per IP, a refused attempt does not count',
        () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);
      for (int i = 1; i <= 5; i++) {
        client.send(
            'create_room', <String, Object?>{'name': 'Room$i', 'players': 2});
        final Map<String, Object?> seatAssigned = await client.next();
        expect(
          seatAssigned['t'],
          'seat_assigned',
          reason: 'attempt $i of 5 must be admitted; got '
              '${seatAssigned['t']}: ${seatAssigned['d']}',
        );
        await client.next(); // room
      }
      client.send(
          'create_room', <String, Object?>{'name': 'Room6', 'players': 2});
      final Map<String, Object?> sixth = await client.next();
      expectErrorFrame(sixth, 'RATE_LIMITED',
          because: 'this IP already created 5 rooms within the hour');
    });

    test('join_room/resume: 20 per minute per IP, a wrong code still counts',
        () async {
      final Uri uri = await start();
      final WireTestClient stray = await connect(uri);
      for (int i = 1; i <= 20; i++) {
        stray.send(
            'join_room', <String, Object?>{'code': 'ZZZZZZ', 'name': 'P'});
        final Map<String, Object?> reply = await stray.next();
        expectErrorFrame(reply, 'NO_SUCH_ROOM',
            because: 'attempt $i of 20, under the per-minute limit, '
                'against a code that was never issued');
      }
      stray.send('join_room', <String, Object?>{'code': 'ZZZZZZ', 'name': 'P'});
      final Map<String, Object?> reply21 = await stray.next();
      expectErrorFrame(reply21, 'RATE_LIMITED',
          because: 'this is the 21st join_room/resume from this IP within '
              'the minute');
    });

    test('game_log: 2 per minute per connection, counted ahead of identity',
        () async {
      final Uri uri = await start();
      final WireTestClient stray = await connect(uri);
      for (int i = 1; i <= 2; i++) {
        stray.send('game_log', <String, Object?>{});
        final Map<String, Object?> reply = await stray.next();
        expectErrorFrame(reply, 'BAD_SEAT_TOKEN',
            because: 'attempt $i of 2 passes the rate limit but this '
                'socket holds no seat');
      }
      stray.send('game_log', <String, Object?>{});
      final Map<String, Object?> third = await stray.next();
      expectErrorFrame(third, 'RATE_LIMITED',
          because: 'this is the 3rd game_log from this connection within '
              'the minute, over the 2-per-minute limit, which the ladder '
              'checks before identity');
    });

    test(
        'any message: 30 per second then RATE_LIMITED, then close at 60 '
        'with close code 4003', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      for (int i = 1; i <= 30; i++) {
        raw.sendText(_pingEnvelope(id: 'rate-any-$i'));
        final RawFrame frame = await raw.next();
        expect(
          frame.decoded?['t'],
          'pong',
          reason: 'message $i of 30 must be allowed; got $frame',
        );
      }
      for (int i = 31; i <= 59; i++) {
        raw.sendText(_pingEnvelope(id: 'rate-any-$i'));
        final RawFrame frame = await raw.next();
        final Map<String, Object?>? data =
            frame.decoded?['d'] as Map<String, Object?>?;
        expect(
          data?['code'],
          'RATE_LIMITED',
          reason: 'message $i of 60 must be RATE_LIMITED but the '
              'connection must still be open; got $frame',
        );
      }
      raw.sendText(_pingEnvelope(id: 'rate-any-60'));
      final RawFrame sixtieth = await raw.next();
      final Map<String, Object?>? data60 =
          sixtieth.decoded?['d'] as Map<String, Object?>?;
      expect(
        data60?['code'],
        'RATE_LIMITED',
        reason: 'message 60 must also be RATE_LIMITED; got $sixtieth',
      );
      final int? closeCode = await raw.waitClosed();
      expect(
        closeCode,
        4003,
        reason: 'docs/PROTOCOL.md section 7.1: the 60-per-second ceiling '
            'closes with 4003; got $closeCode',
      );
    });
  });

  // =========================================================================
  // Close code 4004: a seat taken over by a newer socket (section 7.1,
  // section 8 point 6)
  // =========================================================================
  group(
      'close code 4004, section 7.1: the displaced socket of a resume '
      'takeover', () {
    test(
        'the socket that gets displaced is sent BAD_SEAT_TOKEN then '
        'closed with 4004', () async {
      final Uri uri = await start();
      final RawWireClient first = await connectRaw(uri);
      first.sendText(jsonEncode(<String, Object?>{
        'v': 1,
        't': 'create_room',
        'id': 'takeover-case-create',
        'd': <String, Object?>{'name': 'Host', 'players': 2},
      }));
      final RawFrame seatAssigned = await first.next();
      expect(seatAssigned.decoded?['t'], 'seat_assigned');
      final Map<String, Object?> seatData =
          seatAssigned.decoded!['d']! as Map<String, Object?>;
      final String seatToken = seatData['seat_token']! as String;
      final RawFrame roomFrame = await first.next();
      final String code =
          (roomFrame.decoded!['d']! as Map<String, Object?>)['code']! as String;

      final RawWireClient second = await connectRaw(uri);
      second.sendText(jsonEncode(<String, Object?>{
        'v': 1,
        't': 'resume',
        'id': 'takeover-case-resume',
        'd': <String, Object?>{'code': code, 'seat_token': seatToken},
      }));
      final RawFrame secondSeatAssigned = await second.next();
      expect(secondSeatAssigned.decoded?['t'], 'seat_assigned',
          reason: 'the resuming socket must still get its own seat_assigned '
              'and room; got $secondSeatAssigned');
      await second.next(); // room

      final RawFrame displacedError = await first.next();
      expect(
        displacedError.decoded?['t'],
        'error',
        reason: 'the displaced socket must be pushed an error before it is '
            'closed; got $displacedError',
      );
      final Map<String, Object?> displacedData =
          displacedError.decoded!['d']! as Map<String, Object?>;
      expect(displacedData['code'], 'BAD_SEAT_TOKEN');
      expect(
        displacedError.decoded?['re'],
        isNull,
        reason: 'this is a push, not a reply to anything the displaced '
            'socket itself sent, so it must carry no re',
      );
      final int? closeCode = await first.waitClosed();
      expect(
        closeCode,
        4004,
        reason: 'docs/PROTOCOL.md section 7.1: a seat taken over by a '
            'newer socket closes the displaced one with 4004; got '
            '$closeCode',
      );
    });
  });

  // =========================================================================
  // 16. Validation order
  // =========================================================================
  group(
      'validation order, section 7: an input wrong two ways is rejected '
      'for the one checked first', () {
    test(
        'rejected at or before the id shape check carries no re when the '
        'id itself is malformed, regardless of what else is wrong', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      raw.sendText(jsonEncode(<String, Object?>{
        'v': 2,
        't': 'ping',
        'id': 'ab',
        'd': <String, Object?>{},
      }));
      final RawFrame frame = await raw.next();
      expect(
        frame.decoded?['re'],
        isNull,
        reason: 'id "ab" is only 2 characters, below the 8-64 character '
            'range docs/PROTOCOL.md section 1 requires, so there is no '
            'usable id for re even though v is also wrong',
      );
    });

    test(
        "a well-formed id is still echoed as re on a v failure -- the id's "
        'own shape decides, not the ladder position of the step that '
        'rejected the frame', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      const String wellFormedId = 'validation-order-wellformed-v';
      raw.sendText(jsonEncode(<String, Object?>{
        'v': 2,
        't': 'ping',
        'id': wellFormedId,
        'd': <String, Object?>{},
      }));
      final RawFrame frame = await raw.next();
      expect(
        frame.decoded?['re'],
        wellFormedId,
        reason: 'docs/PROTOCOL.md section 7, and the commit that '
            'introduced the rule (1beee49: "re is only ever an id that '
            'passed the shape check... echoing an unvalidated one means '
            'emitting a frame whose re breaks the envelope rules"): this '
            'id is itself well-formed, so echoing it on a v failure does '
            'not violate the rule -- it would only violate it if the id '
            'itself were malformed, the previous case in this group',
      );
    });

    test(
        'a well-formed id is still echoed as re on a t (BAD_TYPE) failure, '
        'for the same reason', () async {
      final Uri uri = await start();
      final RawWireClient raw = await connectRaw(uri);
      const String wellFormedId = 'validation-order-wellformed-t';
      raw.sendText(jsonEncode(<String, Object?>{
        'v': 1,
        't': 'not_a_real_type',
        'id': wellFormedId,
        'd': <String, Object?>{},
      }));
      final RawFrame frame = await raw.next();
      expect(frame.decoded?['re'], wellFormedId);
    });

    test(
        'a non-string code is BAD_FIELD; a malformed string code and a '
        'well-formed unknown one both answer NO_SUCH_ROOM', () async {
      final Uri uri = await start();
      final WireTestClient client = await connect(uri);

      client.send('join_room', <String, Object?>{'code': 12345, 'name': 'P'});
      final Map<String, Object?> nonString = await client.next();
      expectErrorFrame(nonString, 'BAD_FIELD',
          because: 'code was the JSON number 12345, not a string at all, '
              'so no lookup can be attempted with it');

      client.send('join_room',
          <String, Object?>{'code': 'not-a-valid-code-shape!!', 'name': 'P'});
      final Map<String, Object?> malformedString = await client.next();
      expectErrorFrame(malformedString, 'NO_SUCH_ROOM',
          because: 'code is a string but the wrong shape; docs/PROTOCOL.md '
              'section 7 says this is not pre-validated and goes to the '
              'registry exactly as received');

      client
          .send('join_room', <String, Object?>{'code': 'QWERTY', 'name': 'P'});
      final Map<String, Object?> wellFormedUnknown = await client.next();
      expectErrorFrame(wellFormedUnknown, 'NO_SUCH_ROOM',
          because: 'code is well-formed but was never issued by this '
              'harness');
    });

    for (final String type in <String>[
      'start_game',
      'set_players',
      'leave_room',
      'roll',
      'move',
    ]) {
      test(
          '$type from a socket in no room with a malformed payload is '
          'BAD_SEAT_TOKEN, not BAD_FIELD', () async {
        final Uri uri = await start();
        final WireTestClient stray = await connect(uri);
        final Map<String, Object?> badPayload = switch (type) {
          'start_game' => <String, Object?>{'unexpected': true},
          'set_players' => <String, Object?>{'players': 'nope'},
          'leave_room' => <String, Object?>{'unexpected': true},
          'roll' => <String, Object?>{'unexpected': true},
          'move' => <String, Object?>{'token': 'nope'},
          _ => throw StateError('unreachable: $type'),
        };
        stray.send(type, badPayload);
        final Map<String, Object?> reply = await stray.next();
        expectErrorFrame(reply, 'BAD_SEAT_TOKEN',
            because: '$type was sent from a socket that never created, '
                'joined or resumed any room, whatever its payload looks '
                'like');
      });
    }
  });
}
