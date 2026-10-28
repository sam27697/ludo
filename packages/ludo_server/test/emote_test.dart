// Wire tests for quick messages, docs/PROTOCOL.md section 25 rule 8, one
// case per item of that rule (the four BAD_FIELD shapes are split).
// Written from section 25 and from docs/RULES.md rule 2. Nothing here
// reads the handler: on this branch `emote` is not a known `t`, so a case
// that sends one is answered `BAD_TYPE`.
//
// Two-player rooms sit on seats 0 and 2 (docs/RULES.md rule 2). There is
// no seat 1. Section 25 rule 8 says "an emote from seat 1" and writes the
// payload as `{seat: 1}`. Rule 4 of the same section says `seat` is the
// sender's seat. The second player is seat 2, and that is what these
// cases assert.
//
// Cadence uses the harness `FakeClock` (section 25 rule 3: the server's
// clock decides). Nothing here sleeps for the 3000 ms gap or the
// 60000 ms window. The turn sweep is off, the same way `game_log_test`
// turns it off: advancing the injected clock must not let a real sweep
// push a `rolled` or a `turn` into the queue.

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/queue_injection.dart';
import 'support/wire_harness.dart';

/// Section 25 rule 1, in the sheet order. Permanent ids.
const List<String> _ids = <String>[
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
  'no_way',
  'good_game',
];

/// Section 25 rule 3. An emote is admitted only when at least this long
/// has passed since that seat's last admitted emote.
const Duration _minGap = Duration(milliseconds: 3000);

/// One millisecond short of [_minGap]. Rule 8: this is `RATE_LIMITED`.
const Duration _underGap = Duration(milliseconds: 2999);

/// Section 25 rule 3. Fewer than 10 admitted emotes in this long a window
/// before the attempt. An emote whose age is exactly this does not count:
/// rule 8 admits again once the oldest of the ten is this old.
const Duration _window = Duration(milliseconds: 60000);

class _Playing {
  _Playing({
    required this.lobby,
    required this.turnSeat,
    required this.seq,
  });

  final WireTestLobby lobby;
  final int turnSeat;

  /// `seq` on the opening `turn` frame, which is the room's seq once
  /// `start_game` has finished (section 13.1: that frame is the last
  /// state change of the start).
  final int seq;
}

void main() {
  late ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];

  setUp(() {
    harness = ServerHarness.build(automaticTurnExpiry: false);
  });

  tearDown(() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    await harness.close();
  });

  Future<_Playing> playing() async {
    await harness.start();
    final WireTestLobby lobby = await buildWireTestLobby(
      harness.wsUri,
      clients,
      players: 2,
    );
    expect(
      <int>[lobby.host.seat, lobby.guest.seat],
      <int>[0, 2],
      reason: 'docs/RULES.md rule 2: two players take seats 0 and 2. '
          'Section 25 rule 8 names "seat 1", and a two-seat room has no '
          'seat 1; the second player is seat 2.',
    );

    lobby.host.client.send('start_game', <String, Object?>{});
    final Map<String, Object?> hostStarted = await receiveType(
      lobby.host.client,
      'game_started',
    );
    final Map<String, Object?> started =
        hostStarted['d']! as Map<String, Object?>;
    final Object? turnSeat = started['turn'];
    final Map<String, Object?> hostTurn = await expectOpeningTurn(
      lobby.host.client,
      turnSeat,
    );
    await receiveType(lobby.guest.client, 'game_started');
    final Map<String, Object?> guestTurn = await expectOpeningTurn(
      lobby.guest.client,
      turnSeat,
    );

    expect(
      turnSeat,
      lobby.host.seat,
      reason: 'docs/RULES.md rule 4: the host seat moves first; got '
          'game_started.turn=$turnSeat host=${lobby.host.seat}',
    );
    final Object? hostSeq = (hostTurn['d']! as Map<String, Object?>)['seq'];
    final Object? guestSeq = (guestTurn['d']! as Map<String, Object?>)['seq'];
    expect(
      hostSeq,
      isA<int>(),
      reason: 'section 5: the opening turn carries seq; got $hostSeq',
    );
    expect(
      guestSeq,
      hostSeq,
      reason: 'section 5: one seq counter per room, so both sockets see '
          'the same opening turn seq; host=$hostSeq guest=$guestSeq',
    );
    return _Playing(
      lobby: lobby,
      turnSeat: turnSeat! as int,
      seq: hostSeq! as int,
    );
  }

  WireTestSeat otherOf(_Playing game, WireTestSeat sender) {
    if (sender.seat == game.lobby.host.seat) {
      return game.lobby.guest;
    }
    return game.lobby.host;
  }

  /// The admitted push, section 25 rule 4. [re] null means the frame must
  /// not carry `re` at all (the other sockets' copy).
  void expectEmote(
    Map<String, Object?> frame, {
    required int seat,
    required String emote,
    required String? re,
    required String because,
  }) {
    expect(
      frame['t'],
      'emote',
      reason: '$because: expected an emote frame, got "${frame['t']}" '
          '${frame['d']}',
    );
    if (re == null) {
      expect(
        frame.containsKey('re'),
        isFalse,
        reason: '$because: the other sockets\' copy has no re '
            '(section 25 rule 4); got re=${frame['re']}',
      );
    } else {
      expect(
        frame['re'],
        re,
        reason: '$because: the sender\'s copy carries re equal to the '
            'request id (section 25 rule 4)',
      );
    }
    expect(
      frame.containsKey('seq'),
      isFalse,
      reason: '$because: seq is not an envelope field on emote; '
          'got ${frame['seq']}',
    );
    final Object? raw = frame['d'];
    expect(
      raw,
      isA<Map<String, Object?>>(),
      reason: '$because: emote d is an object; got $raw',
    );
    final Map<String, Object?> data = raw! as Map<String, Object?>;
    expect(
      data.containsKey('seq'),
      isFalse,
      reason: '$because: section 25 rules 4 and 5, emote carries no seq; '
          'got $data',
    );
    expect(
      data,
      <String, Object?>{'seat': seat, 'emote': emote},
      reason: '$because: section 25 rule 4, d is the sender seat and the '
          'id as received',
    );
  }

  Future<void> admit(
    _Playing game,
    WireTestSeat sender,
    String emote, {
    required String because,
  }) async {
    final String requestId = sender.client.send('emote', <String, Object?>{
      'emote': emote,
    });
    final Map<String, Object?> mine = await sender.client.next();
    expectEmote(
      mine,
      seat: sender.seat,
      emote: emote,
      re: requestId,
      because: '$because, sender seat ${sender.seat}',
    );
    final WireTestSeat other = otherOf(game, sender);
    final Map<String, Object?> theirs = await other.client.next();
    expectEmote(
      theirs,
      seat: sender.seat,
      emote: emote,
      re: null,
      because: '$because, other seat ${other.seat}',
    );
  }

  Future<void> expectEmoteError(
    WireTestClient client,
    String requestId,
    String code, {
    required String because,
  }) async {
    final Map<String, Object?> frame = await client.next();
    expect(
      frame['t'],
      'error',
      reason: '$because: expected an error frame, got "${frame['t']}" '
          '${frame['d']}',
    );
    final Object? raw = frame['d'];
    expect(
      raw,
      isA<Map<String, Object?>>(),
      reason: '$because: error d is an object; got $raw',
    );
    final Map<String, Object?> data = raw! as Map<String, Object?>;
    expect(
      data['code'],
      code,
      reason: because,
    );
    expect(
      frame['re'],
      requestId,
      reason: '$because: section 1, an error that answers a message '
          'carries re',
    );
    expect(
      data.containsKey('seq'),
      isFalse,
      reason: '$because: section 5, an error carries no seq; got $data',
    );
  }

  group('section 25 rule 8', () {
    test(
        'an emote from the second seat reaches that seat with re and '
        'seat 0 without, both with the sender seat and the id, and no seq',
        () async {
      final _Playing game = await playing();
      // The second player. Wire seat 2, which is rule 8's "seat 1":
      // rule 4's payload seat is this seat, and seat 0 is the host,
      // who gets the copy with no re.
      await admit(
        game,
        game.lobby.guest,
        'hi',
        because: 'delivery of one admitted emote',
      );
    });

    test('an emote sent when it is not the sender\'s turn is admitted',
        () async {
      final _Playing game = await playing();
      final WireTestSeat sender = game.lobby.guest;
      expect(
        game.turnSeat,
        isNot(sender.seat),
        reason: 'the sender must not hold the turn; turn seat is '
            '${game.turnSeat}, sender is ${sender.seat}',
      );
      await admit(
        game,
        sender,
        'nice',
        because: 'not the sender\'s turn (section 25 rule 2)',
      );
    });

    test(
        'every one of the twelve ids is admitted, clock advanced between '
        'them', () async {
      final _Playing game = await playing();
      // A 3000 ms gap admits only ten inside one window (the eleventh
      // case below). A full window between ids puts each one outside
      // the previous window, and still satisfies the 3000 ms gap.
      for (int i = 0; i < _ids.length; i++) {
        if (i > 0) {
          harness.clock.advance(_window);
        }
        await admit(
          game,
          game.lobby.host,
          _ids[i],
          because: 'id ${_ids[i]} (${i + 1} of ${_ids.length})',
        );
      }
    });

    test('BAD_FIELD for an unknown id', () async {
      final _Playing game = await playing();
      final String requestId =
          game.lobby.host.client.send('emote', <String, Object?>{
        'emote': 'nope',
      });
      await expectEmoteError(
        game.lobby.host.client,
        requestId,
        'BAD_FIELD',
        because: 'section 25 rule 1: an id outside the twelve is '
            'BAD_FIELD',
      );
    });

    test('BAD_FIELD for a number', () async {
      final _Playing game = await playing();
      final String requestId =
          game.lobby.host.client.send('emote', <String, Object?>{
        'emote': 1,
      });
      await expectEmoteError(
        game.lobby.host.client,
        requestId,
        'BAD_FIELD',
        because: 'section 25 rule 1: a value that is not a string is '
            'BAD_FIELD',
      );
    });

    test('BAD_FIELD for a missing emote key', () async {
      final _Playing game = await playing();
      final String requestId =
          game.lobby.host.client.send('emote', <String, Object?>{});
      await expectEmoteError(
        game.lobby.host.client,
        requestId,
        'BAD_FIELD',
        because: 'section 25 rule 1: a missing emote key is BAD_FIELD',
      );
    });

    test('BAD_FIELD for an extra key', () async {
      final _Playing game = await playing();
      final String requestId =
          game.lobby.host.client.send('emote', <String, Object?>{
        'emote': 'hi',
        'text': 'hello',
      });
      await expectEmoteError(
        game.lobby.host.client,
        requestId,
        'BAD_FIELD',
        because: 'section 25 rule 1: any other key in d is BAD_FIELD',
      );
    });

    test('WRONG_PHASE in LOBBY', () async {
      await harness.start();
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
        players: 2,
      );
      final String requestId =
          lobby.guest.client.send('emote', <String, Object?>{
        'emote': 'hi',
      });
      await expectEmoteError(
        lobby.guest.client,
        requestId,
        'WRONG_PHASE',
        because: 'section 25 rule 2: LOBBY is WRONG_PHASE, before the '
            'payload is read',
      );
    });

    test('GAME_OVER after game_over', () async {
      final _Playing game = await playing();
      final Room? room = harness.registry.lookup(game.lobby.code);
      if (room == null || room.game == null) {
        fail(
          'setup: room ${game.lobby.code} has no game to finish',
        );
      }
      // The winning position roll_queue_wire_test.dart already drives:
      // three tokens home, the fourth three steps away, queue starting
      // with that 3. The move is the server's; this only places the
      // tokens so the next move is the win.
      forceQueueGame(
        room,
        currentSeat: game.lobby.host.seat,
        phase: engine.GamePhase.awaitMove,
        queue: const <int>[3, 5],
        tokens: <int, List<int>>{
          game.lobby.host.seat: <int>[57, 57, 57, 54],
        },
        now: harness.clock.now,
      );
      game.lobby.host.client.send('move', <String, Object?>{
        'token': 3,
        'face': 3,
      });
      await expectMovedThenOver(game.lobby.host.client);
      await expectMovedThenOver(game.lobby.guest.client);

      final String requestId =
          game.lobby.guest.client.send('emote', <String, Object?>{
        'emote': 'good_game',
      });
      await expectEmoteError(
        game.lobby.guest.client,
        requestId,
        'GAME_OVER',
        because: 'section 25 rule 2 and rule 7: after game_over, emote '
            'is GAME_OVER. emote is not on the section 7 exception list',
      );
    });

    test('BAD_SEAT_TOKEN from a socket with no seat', () async {
      final _Playing game = await playing();
      final WireTestClient stray = await WireTestClient.connect(
        harness.wsUri,
      );
      clients.add(stray);
      final String requestId = stray.send('emote', <String, Object?>{
        'emote': 'hi',
      });
      await expectEmoteError(
        stray,
        requestId,
        'BAD_SEAT_TOKEN',
        because: 'section 25 rule 2: a socket with no identity is '
            'BAD_SEAT_TOKEN, in a room that is otherwise PLAYING '
            '(${game.lobby.code})',
      );
    });

    test(
        'a second emote 2999 ms after the first is RATE_LIMITED and one '
        'at 3000 ms is admitted', () async {
      final _Playing game = await playing();
      final WireTestSeat sender = game.lobby.guest;
      await admit(
        game,
        sender,
        'hi',
        because: 'the first emote, at t=0',
      );

      harness.clock.advance(_underGap);
      final String limitedId = sender.client.send('emote', <String, Object?>{
        'emote': 'oops',
      });
      await expectEmoteError(
        sender.client,
        limitedId,
        'RATE_LIMITED',
        because: 'section 25 rule 8: 2999 ms after the last admitted '
            'emote is RATE_LIMITED',
      );

      // t = 3000 ms from the admitted emote. The reject at 2999 ms does
      // not count (rule 3), so this is 3000 ms since the last admitted
      // one, which rule 3 allows.
      harness.clock.advance(const Duration(milliseconds: 1));
      await admit(
        game,
        sender,
        'nice',
        because: '3000 ms after the admitted emote',
      );
    });

    test(
        'an eleventh within 60000 ms is RATE_LIMITED even with 3000 ms '
        'gaps, and is admitted once the oldest is 60000 ms old', () async {
      final _Playing game = await playing();
      final WireTestSeat sender = game.lobby.host;
      // t = 0, 3000, ..., 27000. Ten admitted.
      for (int i = 0; i < 10; i++) {
        if (i > 0) {
          harness.clock.advance(_minGap);
        }
        await admit(
          game,
          sender,
          'hi',
          because: 'admitted emote ${i + 1} of 10',
        );
      }

      // t = 30000. The gap since the last admitted emote is 3000 ms, so
      // the gap rule allows it. All ten are younger than 60000 ms, so
      // the window rule refuses it.
      harness.clock.advance(_minGap);
      final String limitedId = sender.client.send('emote', <String, Object?>{
        'emote': 'hi',
      });
      await expectEmoteError(
        sender.client,
        limitedId,
        'RATE_LIMITED',
        because: 'section 25 rule 8: an eleventh inside 60000 ms is '
            'RATE_LIMITED even though the gaps are 3000 ms',
      );

      // t = 60000. The oldest of the ten (t = 0) is exactly 60000 ms
      // old and drops out of "the 60000 ms before". Nine remain. The
      // reject at t = 30000 did not take a slot. Last admitted emote
      // was at t = 27000, so the gap rule allows it too.
      harness.clock.advance(const Duration(milliseconds: 30000));
      await admit(
        game,
        sender,
        'nice',
        because: 'the oldest of the ten is 60000 ms old',
      );
    });

    test(
        'a rejected emote does not count: a reject at 1000 ms does not '
        'delay the admit at 3000 ms', () async {
      final _Playing game = await playing();
      final WireTestSeat sender = game.lobby.guest;
      await admit(
        game,
        sender,
        'hi',
        because: 'admitted at t=0',
      );

      harness.clock.advance(const Duration(milliseconds: 1000));
      final String limitedId = sender.client.send('emote', <String, Object?>{
        'emote': 'oops',
      });
      await expectEmoteError(
        sender.client,
        limitedId,
        'RATE_LIMITED',
        because: 'section 25 rule 8: the emote at 1000 ms is rejected',
      );

      // t = 3000. If the reject had counted, the next admit would be
      // no earlier than t = 4000.
      harness.clock.advance(const Duration(milliseconds: 2000));
      await admit(
        game,
        sender,
        'nice',
        because: 'admitted at t=3000, the reject at t=1000 did not count',
      );
    });

    test('the cadence survives a resume of that seat on a new socket',
        () async {
      final _Playing game = await playing();
      final WireTestLobby lobby = game.lobby;
      await admit(
        game,
        lobby.guest,
        'hi',
        because: 'admitted on the original socket, at t=0',
      );

      harness.clock.advance(const Duration(milliseconds: 1000));
      await lobby.guest.client.close();
      await drainPresence(
        lobby.host.client,
        lobby.guest.seat,
        connected: false,
      );

      final WireTestClient fresh = await WireTestClient.connect(
        harness.wsUri,
      );
      clients.add(fresh);
      final String resumeId = fresh.send('resume', <String, Object?>{
        'code': lobby.code,
        'seat_token': lobby.guest.token,
      });
      await expectSeatAssigned(
        fresh,
        expectedSeat: lobby.guest.seat,
        expectedToken: lobby.guest.token,
        because: 'section 25 rule 3: resume of the same seat token on a '
            'new socket',
      );
      final Map<String, Object?> roomFrame = await fresh.next();
      expect(
        roomFrame['t'],
        'room',
        reason: 'section 8: resume is answered by seat_assigned then '
            'room; got "${roomFrame['t']}" ${roomFrame['d']}',
      );
      expect(roomFrame['re'], resumeId);
      await drainPresence(
        lobby.host.client,
        lobby.guest.seat,
        connected: true,
      );

      // t = 1000 on the new socket. A resume must not clear the seat's
      // cadence (rule 3: kept by seat token, in the room).
      final String limitedId = fresh.send('emote', <String, Object?>{
        'emote': 'oops',
      });
      await expectEmoteError(
        fresh,
        limitedId,
        'RATE_LIMITED',
        because: 'section 25 rule 8: 1000 ms after the admitted emote, '
            'on a new socket for the same seat, is still RATE_LIMITED',
      );

      harness.clock.advance(const Duration(milliseconds: 2000));
      final String requestId = fresh.send('emote', <String, Object?>{
        'emote': 'nice',
      });
      final Map<String, Object?> mine = await fresh.next();
      expectEmote(
        mine,
        seat: lobby.guest.seat,
        emote: 'nice',
        re: requestId,
        because: '3000 ms after the original admit, on the resumed socket',
      );
      final Map<String, Object?> theirs = await lobby.host.client.next();
      expectEmote(
        theirs,
        seat: lobby.guest.seat,
        emote: 'nice',
        re: null,
        because: 'the host\'s copy of the emote admitted after resume',
      );
    });

    test('the connection stays open after RATE_LIMITED', () async {
      final _Playing game = await playing();
      final WireTestSeat sender = game.lobby.host;
      await admit(
        game,
        sender,
        'hi',
        because: 'the admitted emote a cadence reject has to follow',
      );
      harness.clock.advance(_underGap);
      final String limitedId = sender.client.send('emote', <String, Object?>{
        'emote': 'oops',
      });
      await expectEmoteError(
        sender.client,
        limitedId,
        'RATE_LIMITED',
        because: 'section 25 rule 3: RATE_LIMITED, and the connection '
            'stays open',
      );

      final String pingId = sender.client.send('ping', <String, Object?>{});
      final Map<String, Object?> pong = await sender.client.next();
      expect(
        pong['t'],
        'pong',
        reason: 'section 25 rule 8: after RATE_LIMITED a ping still '
            'answers; got "${pong['t']}" ${pong['d']}',
      );
      expect(
        pong['re'],
        pingId,
        reason: 'section 1: pong answers the ping, so it carries re',
      );
    });

    test('the game_log answer holds no emote entry after several were sent',
        () async {
      final _Playing game = await playing();
      const List<String> sent = <String>['hi', 'nice', 'oops'];
      for (int i = 0; i < sent.length; i++) {
        if (i > 0) {
          harness.clock.advance(_minGap);
        }
        await admit(
          game,
          game.lobby.guest,
          sent[i],
          because: 'emote ${i + 1} of ${sent.length} before game_log',
        );
      }

      final String requestId =
          game.lobby.host.client.send('game_log', <String, Object?>{});
      final List<Map<String, Object?>> entries = await readGameLog(
        game.lobby.host.client,
        requestId,
      );
      for (final Map<String, Object?> entry in entries) {
        expect(
          entry['t'],
          isNot('emote'),
          reason: 'section 25 rule 5 and rule 8: the game_log answer '
              'holds no emote entry; got $entry',
        );
      }
      expect(
        entries
            .any((Map<String, Object?> entry) => entry['t'] == 'game_started'),
        isTrue,
        reason: 'section 17 rule 2: the log of this game runs from '
            'game_started, so an empty answer is not "no emote"',
      );
    });

    test('the room seq is the same before and after an admitted emote',
        () async {
      final _Playing game = await playing();
      await admit(
        game,
        game.lobby.host,
        'hi',
        because: 'the admitted emote that must not move seq',
      );

      // Same socket, still connected. Section 13.2: a takeover of a seat
      // that is already connected broadcasts nothing, so the snapshot
      // seq is the room's seq and not a presence bump.
      final String resumeId =
          game.lobby.host.client.send('resume', <String, Object?>{
        'code': game.lobby.code,
        'seat_token': game.lobby.host.token,
      });
      await expectSeatAssigned(
        game.lobby.host.client,
        expectedSeat: game.lobby.host.seat,
        expectedToken: game.lobby.host.token,
        because: 'reading the room seq back after the emote',
      );
      final Map<String, Object?> roomFrame =
          await game.lobby.host.client.next();
      expect(
        roomFrame['t'],
        'room',
        reason: 'section 8: resume answers with room after seat_assigned; '
            'got "${roomFrame['t']}" ${roomFrame['d']}',
      );
      expect(roomFrame['re'], resumeId);
      final Map<String, Object?> data = roomFrame['d']! as Map<String, Object?>;
      expect(
        data['seq'],
        game.seq,
        reason: 'section 25 rule 5 and rule 8: an admitted emote is not '
            'a state change, so the room seq stays ${game.seq}; '
            'got ${data['seq']}',
      );
    });
  });
}

/// `moved` then `game_over`, section 21.3's winning move, on one socket.
Future<void> expectMovedThenOver(WireTestClient client) async {
  final Map<String, Object?> moved = await client.next();
  expect(
    moved['t'],
    'moved',
    reason: 'setup: a winning move publishes moved, then game_over '
        '(section 21.3); got "${moved['t']}" ${moved['d']}',
  );
  final Map<String, Object?> over = await client.next();
  expect(
    over['t'],
    'game_over',
    reason: 'setup: section 25 rule 8 is GAME_OVER after game_over; '
        'got "${over['t']}" ${over['d']}',
  );
}

/// One `presence` on [survivor], section 8. Left in the queue it is read
/// as the next emote or the next error.
Future<void> drainPresence(
  WireTestClient survivor,
  int seat, {
  required bool connected,
}) async {
  final Map<String, Object?> frame = await survivor.next();
  expect(
    frame['t'],
    'presence',
    reason: 'expected presence for seat $seat connected=$connected; '
        'got "${frame['t']}" ${frame['d']}',
  );
  final Map<String, Object?> data = frame['d']! as Map<String, Object?>;
  expect(data['seat'], seat);
  expect(data['connected'], connected);
}

/// Every part of one `game_log` answer, section 17 rule 2.
Future<List<Map<String, Object?>>> readGameLog(
  WireTestClient client,
  String requestId,
) async {
  final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
  int? parts;
  var seen = 0;
  while (parts == null || seen < parts) {
    final Map<String, Object?> part = await client.next();
    expect(
      part['t'],
      'game_log',
      reason: 'expected a game_log part answering $requestId; '
          'got "${part['t']}" ${part['d']}',
    );
    expect(part['re'], requestId);
    final Map<String, Object?> data = part['d']! as Map<String, Object?>;
    final Object? rawParts = data['parts'];
    if (rawParts is! int || rawParts < 1 || rawParts > 200) {
      fail('game_log parts must be an int in 1..200, got $rawParts');
    }
    parts = rawParts;
    seen += 1;
    final Object? rawFrames = data['frames'];
    if (rawFrames is! List<Object?>) {
      fail('game_log frames must be a list, got $rawFrames');
    }
    for (final Object? item in rawFrames) {
      if (item is! Map<String, Object?>) {
        fail('a game_log entry must be an object, got $item');
      }
      entries.add(item);
    }
  }
  return entries;
}
