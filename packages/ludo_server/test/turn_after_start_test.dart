// Conformance tests for `docs/PROTOCOL.md` section 13.1: "A standalone
// `turn` follows `game_started`. Always." Written from section 13.1, read
// together with section 12.3 for the `seq` and `re` rules it points back to,
// and section 5 for the exact field names `game_started` and `turn` carry.
// Nothing below was derived from `connection.dart`'s `_handleStartGame` or
// `registry.dart`'s `startGame` -- this file is the blind half of order 062,
// proving the spec against a real, running `WireServer` the way
// `turn_loop_test.dart` proves section 12, while another worker implements
// the same spec text on a branch this file cannot see.
//
// Section 13.1 says the server does not do this yet as of the branch this
// suite is written against: "connection.dart's _handleStartGame sends
// game_started and stops; the only two turn emissions are in the roll and
// move handlers." Every test below is therefore expected to fail, and the
// failure is the point -- this file is what the other half's implementation
// gets checked against, not a suite that is expected to pass today.

import 'package:test/test.dart';

import 'support/wire_harness.dart';

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

  group('the opening turn frame, section 13.1', () {
    test(
        'order: every seat_seed the call emits, then game_started, then '
        'turn immediately after it, with turn.seat == game_started.turn '
        'and seq advancing by exactly one across the whole burst (section '
        '12.3)', () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);

      final String startId =
          lobby.host.client.send('start_game', <String, Object?>{});
      final List<Map<String, Object?>> burst =
          await drainUntil(lobby.host.client, 'turn');

      expect(
        burst.length,
        greaterThanOrEqualTo(2),
        reason: 'start_game (id $startId) on room ${lobby.code} must '
            'produce at least game_started and a standalone turn frame '
            '(section 13.1); got $burst',
      );
      expect(
        burst.last['t'],
        'turn',
        reason: 'drainUntil only returns once a turn frame arrives; this '
            'restates that for a self-describing failure if that ever '
            'changes',
      );

      // Section 13.1's order: "seat_seed (one per server-seeded seat, each
      // at its own seq), game_started, turn" -- turn is the very last
      // frame in the burst and game_started is the one immediately before
      // it, with every earlier frame being a seat_seed push.
      final int gameStartedIndex = burst.length - 2;
      expect(
        burst[gameStartedIndex]['t'],
        'game_started',
        reason: 'section 13.1: turn must be immediately preceded by '
            'game_started, with nothing between them; got the burst '
            '$burst',
      );
      for (int i = 0; i < gameStartedIndex; i++) {
        expect(
          burst[i]['t'],
          'seat_seed',
          reason: 'section 13.1: every frame before game_started in this '
              'burst must be a seat_seed push (one per server-seeded '
              'seat, in seq order); frame $i of the burst was '
              '"${burst[i]['t']}" instead: $burst',
        );
      }

      final Map<String, Object?> gameStartedData =
          burst[gameStartedIndex]['d']! as Map<String, Object?>;
      final Map<String, Object?> turnData =
          burst.last['d']! as Map<String, Object?>;

      expect(
        turnData['seat'],
        gameStartedData['turn'],
        reason: 'section 13.1: turn.seat must equal game_started.turn, '
            'the same seat from the same start_game; got turn.seat='
            '${turnData['seat']} game_started.turn='
            '${gameStartedData['turn']}',
      );

      final List<int> seqs = burst
          .map((Map<String, Object?> f) =>
              (f['d']! as Map<String, Object?>)['seq']! as int)
          .toList();
      for (int i = 1; i < seqs.length; i++) {
        expect(
          seqs[i],
          seqs[i - 1] + 1,
          reason: 'section 12.3: the room counter advances by exactly '
              'one per frame, no gap and no repeat, across the whole '
              'start_game burst; got seqs $seqs from frames $burst',
        );
      }
      expect(
        turnData['seq'],
        (gameStartedData['seq']! as int) + 1,
        reason: 'section 13.1: "The turn frame carries its own seq, one '
            'greater than game_started\'s"; got game_started.seq='
            '${gameStartedData['seq']} turn.seq=${turnData['seq']}',
      );
    });

    test(
        'deadline_ms is absent from game_started and present, a positive '
        'integer bounded by rules.turn_seconds * 1000, on turn (section '
        '13.1)', () async {
      const int turnSeconds = 37;
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(
        uri,
        clients,
        rules: <String, Object?>{'turn_seconds': turnSeconds},
      );

      final String startId =
          lobby.host.client.send('start_game', <String, Object?>{});
      final List<Map<String, Object?>> burst =
          await drainUntil(lobby.host.client, 'turn');
      final Map<String, Object?> gameStartedFrame = burst.firstWhere(
        (Map<String, Object?> f) => f['t'] == 'game_started',
        orElse: () => throw TestFailure(
          'start_game (id $startId) on room ${lobby.code} produced no '
          'game_started frame in its burst: $burst',
        ),
      );
      final Map<String, Object?> gameStartedData =
          gameStartedFrame['d']! as Map<String, Object?>;
      final Map<String, Object?> turnData =
          burst.last['d']! as Map<String, Object?>;

      expect(
        gameStartedData.containsKey('deadline_ms'),
        isFalse,
        reason: 'section 13.1: "game_started carries {turn, game_id, '
            'client_seeds} with no deadline_ms"; got $gameStartedData',
      );
      expect(
        turnData.containsKey('deadline_ms'),
        isTrue,
        reason: 'section 13.1: the standalone turn frame carries the '
            'first segment\'s deadline_ms, which game_started does not; '
            'turn was $turnData',
      );
      final Object? rawDeadline = turnData['deadline_ms'];
      expect(
        rawDeadline,
        isA<int>(),
        reason: 'deadline_ms must be an integer number of milliseconds '
            'remaining (section 5); got ${rawDeadline.runtimeType}: '
            '$rawDeadline',
      );
      final int deadlineMs = rawDeadline! as int;
      expect(
        deadlineMs,
        inInclusiveRange(1, turnSeconds * 1000),
        reason: 'deadline_ms must be a positive number of milliseconds no '
            'greater than rules.turn_seconds ($turnSeconds seconds = '
            '${turnSeconds * 1000}ms); got $deadlineMs',
      );
    });

    test(
        'reaches the guest\'s socket too, with an identical payload; re is '
        'set to start_game\'s id on the sender\'s own copy of turn and '
        'absent on the other socket\'s copy (section 12.3\'s pattern)',
        () async {
      final Uri uri = await start();
      final WireTestLobby lobby = await buildWireTestLobby(uri, clients);

      final String startId =
          lobby.host.client.send('start_game', <String, Object?>{});
      final List<Map<String, Object?>> hostBurst =
          await drainUntil(lobby.host.client, 'turn');
      final List<Map<String, Object?>> guestBurst =
          await drainUntil(lobby.guest.client, 'turn');

      expect(
        guestBurst.map((Map<String, Object?> f) => f['t']).toList(),
        hostBurst.map((Map<String, Object?> f) => f['t']).toList(),
        reason: 'room ${lobby.code}: every socket in the room must see the '
            'same start_game burst, in the same order (sections 12.3 and '
            '13.3 -- one room counter, one order); host saw '
            '${hostBurst.map((Map<String, Object?> f) => f['t']).toList()}, '
            'guest saw '
            '${guestBurst.map((Map<String, Object?> f) => f['t']).toList()}',
      );

      final Map<String, Object?> hostTurnFrame = hostBurst.last;
      final Map<String, Object?> guestTurnFrame = guestBurst.last;
      expect(
        guestTurnFrame['t'],
        'turn',
        reason: 'the guest, seat ${lobby.guest.seat} in room ${lobby.code}, '
            'never received a turn frame after seat ${lobby.host.seat} '
            'sent start_game (id $startId); guest burst was: $guestBurst',
      );

      final Map<String, Object?> hostTurnData =
          hostTurnFrame['d']! as Map<String, Object?>;
      final Map<String, Object?> guestTurnData =
          guestTurnFrame['d']! as Map<String, Object?>;
      expect(
        guestTurnData,
        hostTurnData,
        reason: 'room ${lobby.code}: a broadcast push must reach every '
            'socket with the identical payload (section 12.3); host saw '
            '$hostTurnData, guest saw $guestTurnData',
      );

      expect(
        hostTurnFrame['re'],
        startId,
        reason: 'seat ${lobby.host.seat} sent start_game (id $startId); '
            'its own copy of the turn frame that answers it must carry '
            're == $startId (section 12.3: "the sender\'s copy carries '
            're"); got ${hostTurnFrame['re']}',
      );
      expect(
        guestTurnFrame['re'],
        isNull,
        reason: 'seat ${lobby.guest.seat} did not send start_game; its '
            'copy of the turn frame must carry no re (section 12.3: '
            '"the others do not"); got ${guestTurnFrame['re']}',
      );
    });
  });
}
