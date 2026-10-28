// Order 491 -- a takeover must not orphan the new socket.
//
// docs/PROTOCOL.md section 8 rule 6: a second socket presenting a valid
// `seat_token` for a seat that is already connected takes the seat over; the
// older socket is sent `BAD_SEAT_TOKEN` and closed (4004, section 7.1), and
// the new one holds the seat. Section 12.3: every broadcast frame goes to
// every connected socket in the room. Put together: after a takeover, the
// new socket is a connected socket in the room and must see every later
// broadcast, however many sockets the room has and whichever phase it is in.
//
// Every case below runs over real sockets against a real `WireServer`
// (`ServerHarness`), nothing in-process. The cases that matter most are the
// ones where the taken-over socket is the ONLY socket attached to the room:
// there is nobody else whose delivery could mask a broadcast that never
// reaches the new socket. Case 4 is the control and has a second socket
// attached on purpose.
//
// No die face, seed or clock value decides any outcome here: what is asserted
// is which sockets receive which frame type, so there is no seed to record.
// A failure names its case; re-run one with
// `dart test test/takeover_broadcast_test.dart -n 'case N'`.
import 'package:test/test.dart';

import 'support/wire_harness.dart';

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() async {
    harness = ServerHarness.build();
    await harness.start();
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  Future<WireTestClient> dial() async {
    final WireTestClient client = await WireTestClient.connect(harness.wsUri);
    clients.add(client);
    return client;
  }

  /// Reads frames off [client] until a [type] frame arrives and returns it,
  /// giving up after [maxFrames] frames or one second of silence. A frame
  /// that never comes fails with [scenario], the frame type and every frame
  /// that did arrive, instead of the harness's generic timeout. Frames of
  /// other types ahead of it are skipped: the spec pins which frames a socket
  /// receives, not the order two unrelated pushes land in.
  Future<Map<String, Object?>> awaitFrame(
    WireTestClient client,
    String type, {
    required String scenario,
    int maxFrames = 6,
  }) async {
    final List<String> seen = <String>[];
    for (int i = 0; i < maxFrames; i++) {
      final Map<String, Object?> frame;
      try {
        frame = await client.next(timeout: const Duration(seconds: 1));
      } catch (error) {
        throw TestFailure(
          '$scenario: expected a "$type" frame on this socket and it never '
          'arrived (docs/PROTOCOL.md section 8 rule 6 and section 12.3: a '
          'socket that took a seat over is a connected socket in the room '
          'and must receive every later broadcast). Frames seen before '
          'giving up: $seen. Socket said: $error',
        );
      }
      seen.add(frame['t']! as String);
      if (frame['t'] == type) {
        return frame;
      }
    }
    throw TestFailure(
      '$scenario: expected a "$type" frame on this socket within $maxFrames '
      'frames and none was a "$type". Frames seen: $seen',
    );
  }

  /// Creates a room with [client] as its only seat and returns that seat and
  /// the room code, both handshake frames already read.
  Future<(WireTestSeat, String)> createRoom(
    WireTestClient client, {
    int players = 2,
  }) async {
    client.send('create_room', <String, Object?>{
      'name': 'Host',
      'players': players,
    });
    final Map<String, Object?> assigned = await client.next();
    expect(assigned['t'], 'seat_assigned');
    final Map<String, Object?> assignedData =
        assigned['d']! as Map<String, Object?>;
    final Map<String, Object?> room = await client.next();
    expect(room['t'], 'room');
    final String code = (room['d']! as Map<String, Object?>)['code']! as String;
    return (
      WireTestSeat(
        client: client,
        seat: assignedData['seat']! as int,
        token: assignedData['seat_token']! as String,
      ),
      code,
    );
  }

  /// Section 8 rule 6 and section 7.1: the older socket of a takeover is
  /// pushed `BAD_SEAT_TOKEN` and then closed with 4004.
  Future<void> expectDisplaced(
    WireTestClient displaced, {
    required String scenario,
  }) async {
    final Map<String, Object?> kicked = await awaitFrame(
      displaced,
      'error',
      scenario: '$scenario: the displaced socket',
    );
    expectErrorFrame(
      kicked,
      'BAD_SEAT_TOKEN',
      because: '$scenario: section 8 rule 6, the older socket is told',
    );
    expect(
      await displaced.waitClosed(),
      4004,
      reason: '$scenario: section 7.1, the displaced socket closes with 4004',
    );
  }

  /// Opens a new socket, resumes [seat] on it while [displaced] (the socket
  /// that held it) is still open, and checks everything section 8 rule 6
  /// promises about the takeover itself: the new socket gets `seat_assigned`
  /// then `room`, and [displaced] gets `BAD_SEAT_TOKEN` and is closed with
  /// 4004. Returns the new socket's seat. What the new socket receives after
  /// that is what the cases below are about.
  Future<WireTestSeat> takeOver(
    WireTestSeat seat,
    String code,
    WireTestClient displaced, {
    required String scenario,
    bool checkDisplaced = true,
  }) async {
    final WireTestClient fresh = await dial();
    fresh.send('resume', <String, Object?>{
      'code': code,
      'seat_token': seat.token,
    });
    await expectSeatAssigned(
      fresh,
      expectedSeat: seat.seat,
      expectedToken: seat.token,
      because: '$scenario: the takeover itself',
    );
    final Map<String, Object?> room = await awaitFrame(
      fresh,
      'room',
      scenario: '$scenario: the takeover itself',
    );
    expect(room['re'], isNotNull,
        reason: '$scenario: the room answering a resume carries re');
    if (checkDisplaced) {
      await expectDisplaced(displaced, scenario: scenario);
    }
    return WireTestSeat(client: fresh, seat: seat.seat, token: seat.token);
  }

  /// Joins a new socket into [code] under [name] and reads its own
  /// `seat_assigned` and `room`, so nothing of its handshake is left queued.
  Future<WireTestSeat> joinGuest(String code, String name) async {
    final WireTestClient guest = await dial();
    guest.send('join_room', <String, Object?>{'code': code, 'name': name});
    final Map<String, Object?> assigned = await guest.next();
    expect(assigned['t'], 'seat_assigned',
        reason: 'joining "$name" into $code: got ${assigned['t']}');
    final Map<String, Object?> data = assigned['d']! as Map<String, Object?>;
    await awaitFrame(guest, 'room', scenario: 'joining "$name" into $code');
    return WireTestSeat(
      client: guest,
      seat: data['seat']! as int,
      token: data['seat_token']! as String,
    );
  }

  void expectJoined(
    Map<String, Object?> frame,
    WireTestSeat guest,
    String name, {
    required String scenario,
  }) {
    final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
    expect(data['seat'], guest.seat,
        reason: '$scenario: player_joined.seat must be the guest\'s seat');
    expect(data['name'], name,
        reason: '$scenario: player_joined.name must be "$name"');
  }

  void expectPresence(
    Map<String, Object?> frame,
    int seat,
    bool connected, {
    required String scenario,
  }) {
    final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
    expect(data['seat'], seat,
        reason: '$scenario: presence.seat must be $seat, got ${data['seat']}');
    expect(data['connected'], connected,
        reason: '$scenario: presence.connected must be $connected, got '
            '${data['connected']}');
  }

  group('a seat taken over on a new socket keeps receiving the room', () {
    test(
        'case 1: LOBBY, the host is the only seat; the guest who joins is '
        'announced to the new socket', () async {
      const String scenario = 'case 1 (LOBBY, host alone, takeover)';
      final WireTestClient a = await dial();
      final (WireTestSeat host, String code) = await createRoom(a);

      final WireTestSeat b = await takeOver(host, code, a, scenario: scenario);

      final WireTestSeat guest = await joinGuest(code, 'Guest');
      final Map<String, Object?> joined = await awaitFrame(
        b.client,
        'player_joined',
        scenario: scenario,
      );
      expectJoined(joined, guest, 'Guest', scenario: scenario);
    });

    test(
        'case 2: LOBBY, host and guest seated, the guest\'s socket closed; '
        'the guest resuming is announced to the new socket', () async {
      const String scenario = 'case 2 (LOBBY, host only socket attached)';
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
      );
      // The guest's socket goes away; the host's own socket sees the seat
      // flip, which is also the condition that the server has noticed, so
      // the takeover below is of the room's only attached socket.
      await lobby.guest.client.close();
      final Map<String, Object?> gone = await awaitFrame(
        lobby.host.client,
        'presence',
        scenario: '$scenario: setup, the guest\'s disconnect',
      );
      expectPresence(
        gone,
        lobby.guest.seat,
        false,
        scenario: '$scenario: setup, the guest\'s disconnect',
      );

      final WireTestSeat b = await takeOver(
        lobby.host,
        lobby.code,
        lobby.host.client,
        scenario: scenario,
      );

      final WireTestClient guestAgain = await dial();
      guestAgain.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      await expectSeatAssigned(
        guestAgain,
        expectedSeat: lobby.guest.seat,
        expectedToken: lobby.guest.token,
        because: '$scenario: the guest coming back',
      );

      final Map<String, Object?> back = await awaitFrame(
        b.client,
        'presence',
        scenario: scenario,
      );
      expectPresence(
        back,
        lobby.guest.seat,
        true,
        scenario: scenario,
      );
    });

    test(
        'case 3: PLAYING, two seats, the other seat disconnected; presence '
        'and then the new socket\'s own roll reach the new socket and the '
        'other seat', () async {
      const String scenario = 'case 3 (PLAYING, taken-over socket alone)';
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
      );
      lobby.host.client.send('start_game', <String, Object?>{});
      final Map<String, Object?> hostStarted = await awaitFrame(
          lobby.host.client, 'game_started',
          scenario: scenario);
      final Map<String, Object?> startedData =
          hostStarted['d']! as Map<String, Object?>;
      expect(
        startedData['turn'],
        lobby.host.seat,
        reason: '$scenario: setup, the host (seat ${lobby.host.seat}) must '
            'open the game so its own roll is accepted; game_started.turn='
            '${startedData['turn']}',
      );
      await expectOpeningTurn(lobby.host.client, startedData['turn']);
      await awaitFrame(lobby.guest.client, 'game_started', scenario: scenario);
      await expectOpeningTurn(lobby.guest.client, startedData['turn']);

      await lobby.guest.client.close();
      final Map<String, Object?> gone = await awaitFrame(
        lobby.host.client,
        'presence',
        scenario: '$scenario: setup, the guest\'s disconnect',
      );
      expectPresence(
        gone,
        lobby.guest.seat,
        false,
        scenario: '$scenario: setup, the guest\'s disconnect',
      );

      final WireTestSeat b = await takeOver(
        lobby.host,
        lobby.code,
        lobby.host.client,
        scenario: scenario,
      );

      final WireTestClient guestAgain = await dial();
      guestAgain.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      await expectSeatAssigned(
        guestAgain,
        expectedSeat: lobby.guest.seat,
        expectedToken: lobby.guest.token,
        because: '$scenario: the other seat coming back',
      );
      await awaitFrame(guestAgain, 'room', scenario: scenario);

      final Map<String, Object?> back = await awaitFrame(
        b.client,
        'presence',
        scenario: scenario,
      );
      expectPresence(
        back,
        lobby.guest.seat,
        true,
        scenario: scenario,
      );

      final String rollId = b.client.send('roll', <String, Object?>{});
      final Map<String, Object?> mine = await awaitFrame(
        b.client,
        'rolled',
        scenario: '$scenario: the new socket\'s own roll',
      );
      expect(mine['re'], rollId,
          reason: '$scenario: the roller\'s copy of rolled carries re');
      final Map<String, Object?> theirs = await awaitFrame(
        guestAgain,
        'rolled',
        scenario: '$scenario: the other seat, watching the new socket roll',
      );
      expect(theirs['re'], isNull,
          reason: '$scenario: section 12.3, the others\' copy carries no re');
      expect(theirs['d'], mine['d'],
          reason: '$scenario: both sockets must see the identical rolled '
              'payload');
      expect((mine['d']! as Map<String, Object?>)['seat'], lobby.host.seat,
          reason: '$scenario: the roll is the host seat\'s');
    });

    test(
        'case 4 (control, passes today): a takeover with another seat\'s '
        'socket attached keeps both sockets receiving', () async {
      const String scenario = 'case 4 (control, two sockets attached)';
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
        players: 3,
      );

      final WireTestSeat b = await takeOver(
        lobby.host,
        lobby.code,
        lobby.host.client,
        scenario: scenario,
      );

      final WireTestSeat third = await joinGuest(lobby.code, 'Third');
      final Map<String, Object?> atNew = await awaitFrame(
        b.client,
        'player_joined',
        scenario: '$scenario: the new socket',
      );
      expectJoined(atNew, third, 'Third', scenario: scenario);
      final Map<String, Object?> atGuest = await awaitFrame(
        lobby.guest.client,
        'player_joined',
        scenario: '$scenario: the guest\'s socket',
      );
      expectJoined(atGuest, third, 'Third', scenario: scenario);
    });

    test(
        'case 5: a second takeover in a row, the first new socket being the '
        'only one attached; the third socket receives the next join', () async {
      const String scenario = 'case 5 (LOBBY, takeover of a takeover)';
      final WireTestClient a = await dial();
      final (WireTestSeat host, String code) = await createRoom(a);

      final WireTestSeat b = await takeOver(host, code, a, scenario: scenario);
      // B's displacement is its own case (5b): the frame this case is about
      // must be reported on its own, not hidden behind that check.
      final WireTestSeat c = await takeOver(
        host,
        code,
        b.client,
        scenario: '$scenario, second takeover',
        checkDisplaced: false,
      );

      final WireTestSeat guest = await joinGuest(code, 'Guest');
      final Map<String, Object?> joined = await awaitFrame(
        c.client,
        'player_joined',
        scenario: scenario,
      );
      expectJoined(joined, guest, 'Guest', scenario: scenario);
    });

    test(
        'case 5b: a second takeover in a row displaces the first new socket '
        'with BAD_SEAT_TOKEN and 4004, not only the original one', () async {
      const String scenario = 'case 5b (LOBBY, second takeover displaces)';
      final WireTestClient a = await dial();
      final (WireTestSeat host, String code) = await createRoom(a);

      final WireTestSeat b = await takeOver(host, code, a, scenario: scenario);
      await takeOver(
        host,
        code,
        b.client,
        scenario: '$scenario, second takeover',
      );
    });
  });
}
