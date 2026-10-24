// Conformance tests for reaping and the code quarantine window,
// docs/PROTOCOL.md section 3, as contract C-451 rewrites it:
//   LOBBY: reaped after 10 minutes with no connected seat, and 60 minutes
//     after the room's lifetime started regardless.
//   PLAYING: reaped after 10 minutes with no connected seat; the 60 minute
//     total does not apply.
//   FINISHED: reaped 10 minutes after the registry first observes it so; the
//     60 minute total does not apply.
//   Any room that is not LOBBY: reaped 6 hours after its lifetime started,
//     regardless.
//   A reaped room's code is not reissued for 24 hours.
// All FakeClock-driven, so timing is exact rather than approximate.
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/scripted_random.dart';

const RulesConfig _defaultRules = RulesConfig();

({RoomRegistry registry, FakeClock clock}) _harness() {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
  final RoomRegistry registry =
      RoomRegistry(clock: clock, secure: Random.secure());
  return (registry: registry, clock: clock);
}

CreateOk _create(
  RoomRegistry registry, {
  required String name,
  required int players,
  RulesConfig rules = _defaultRules,
}) {
  final CreateResult result =
      registry.createRoom(name: name, players: players, rules: rules);
  if (result is! CreateOk) {
    fail('expected CreateOk for name="$name" players=$players, got $result');
  }
  return result;
}

void main() {
  test(
      'a LOBBY with nobody connected is reaped at exactly 10 minutes and not at 9',
      () {
    final harness = _harness();
    final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
    harness.registry.setConnected(
        code: host.room.code, seatToken: host.seat.seatToken, connected: false);

    harness.clock.advance(const Duration(minutes: 9));
    expect(harness.registry.reap(), 0,
        reason: 'must not be reaped at 9 minutes idle');
    expect(harness.registry.lookup(host.room.code), isNotNull);

    harness.clock.advance(const Duration(minutes: 1));
    expect(harness.registry.reap(), 1,
        reason: 'must be reaped at exactly 10 minutes idle');
    expect(harness.registry.lookup(host.room.code), isNull);
  });

  test(
      'a LOBBY with somebody connected is reaped at exactly 60 minutes and not at 59',
      () {
    final harness = _harness();
    final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
    final JoinResult join =
        harness.registry.joinRoom(code: host.room.code, name: 'Guest');
    expect(join, isA<JoinOk>(), reason: 'fixture setup, got $join');

    harness.clock.advance(const Duration(minutes: 59));
    expect(harness.registry.reap(), 0,
        reason: 'must not be reaped at 59 minutes total, LOBBY with seats '
            'connected');
    expect(harness.registry.lookup(host.room.code), isNotNull);

    harness.clock.advance(const Duration(minutes: 1));
    expect(harness.registry.reap(), 1,
        reason: 'must be reaped at exactly 60 minutes total in LOBBY');
    expect(harness.registry.lookup(host.room.code), isNull);
  });

  test('a LOBBY with somebody connected survives 30 minutes', () {
    final harness = _harness();
    final CreateOk host = _create(harness.registry, name: 'Host', players: 3);

    harness.clock.advance(const Duration(minutes: 30));
    expect(harness.registry.reap(), 0);
    expect(harness.registry.lookup(host.room.code), isNotNull);
  });

  test('reconnecting resets the 10-minute idle clock', () {
    final harness = _harness();
    final CreateOk host = _create(harness.registry, name: 'Host', players: 2);

    harness.registry.setConnected(
        code: host.room.code, seatToken: host.seat.seatToken, connected: false);
    harness.clock.advance(const Duration(minutes: 9));
    harness.registry.setConnected(
        code: host.room.code, seatToken: host.seat.seatToken, connected: true);
    harness.clock.advance(const Duration(minutes: 2));
    expect(
      harness.registry.reap(),
      0,
      reason:
          'reconnecting at 9 minutes idle should reset the 10-minute clock; this point is '
          '11 minutes after the original disconnect but the room must not be reaped',
    );
    expect(harness.registry.lookup(host.room.code), isNotNull);

    harness.registry.setConnected(
        code: host.room.code, seatToken: host.seat.seatToken, connected: false);
    harness.clock.advance(const Duration(minutes: 9));
    expect(harness.registry.reap(), 0,
        reason: '9 minutes since the second disconnect');
    expect(harness.registry.lookup(host.room.code), isNotNull);

    harness.clock.advance(const Duration(minutes: 1));
    expect(harness.registry.reap(), 1,
        reason: '10 minutes since the second disconnect');
    expect(harness.registry.lookup(host.room.code), isNull);
  });

  test('reap() returns the number of rooms reaped', () {
    final harness = _harness();
    final List<CreateOk> idle = <CreateOk>[
      _create(harness.registry, name: 'A', players: 2),
      _create(harness.registry, name: 'B', players: 2),
      _create(harness.registry, name: 'C', players: 2),
    ];
    for (final CreateOk room in idle) {
      harness.registry.setConnected(
          code: room.room.code,
          seatToken: room.seat.seatToken,
          connected: false);
    }
    final CreateOk stillConnected =
        _create(harness.registry, name: 'D', players: 2);

    harness.clock.advance(const Duration(minutes: 10));
    expect(harness.registry.reap(), 3,
        reason: 'exactly the 3 idle, disconnected rooms should be reaped');
    for (final CreateOk room in idle) {
      expect(harness.registry.lookup(room.room.code), isNull);
    }
    expect(harness.registry.lookup(stillConnected.room.code), isNotNull);
  });

  test(
      'a reaped code is not reissued for 24 hours; the same forced draw '
      'yields it again once the window has elapsed', () {
    final FakeClock clock = FakeClock(DateTime.utc(2026, 1, 1));
    final ScriptedRandom scripted = ScriptedRandom('BCDFGH');
    final RoomRegistry registry = RoomRegistry(clock: clock, secure: scripted);

    final CreateResult victimResult =
        registry.createRoom(name: 'Host', players: 2, rules: _defaultRules);
    expect(victimResult, isA<CreateOk>(), reason: 'got $victimResult');
    final CreateOk victim = victimResult as CreateOk;
    expect(
      victim.room.code,
      'BCDFGH',
      reason:
          'ScriptedRandom must force the first draw to spell the target code',
    );

    registry.setConnected(
        code: victim.room.code,
        seatToken: victim.seat.seatToken,
        connected: false);
    clock.advance(const Duration(minutes: 10));
    expect(registry.reap(), 1);
    expect(registry.lookup('BCDFGH'), isNull);

    scripted.rearm();
    final CreateResult duringResult =
        registry.createRoom(name: 'Someone', players: 2, rules: _defaultRules);
    expect(duringResult, isA<CreateOk>(), reason: 'got $duringResult');
    expect(
      (duringResult as CreateOk).room.code,
      isNot('BCDFGH'),
      reason:
          'a code reaped less than 24h ago must not be reissued, even when the CSPRNG draws it again',
    );

    clock.advance(const Duration(hours: 24) + const Duration(minutes: 1));
    scripted.rearm();
    final CreateResult afterResult =
        registry.createRoom(name: 'Another', players: 2, rules: _defaultRules);
    expect(afterResult, isA<CreateOk>(), reason: 'got $afterResult');
    expect(
      (afterResult as CreateOk).room.code,
      'BCDFGH',
      reason:
          'once the 24h quarantine has elapsed, the same forced draw must be allowed to '
          'yield the code again',
    );
  });

  group('C-451: a live game is never reaped by the clock', () {
    // Creates a two-seat room and starts it. Returns the host and guest so a
    // case can connect and disconnect each seat by name.
    ({CreateOk host, JoinOk guest}) startedRoom(
        ({RoomRegistry registry, FakeClock clock}) harness) {
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      final JoinResult join =
          harness.registry.joinRoom(code: host.room.code, name: 'Guest');
      if (join is! JoinOk) {
        fail('fixture setup: expected JoinOk, got $join');
      }
      final StartResult start = harness.registry
          .startGame(code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartOk>(),
          reason: 'fixture setup: expected the room to start, got $start');
      expect(harness.registry.lookup(host.room.code)!.state, RoomState.playing,
          reason: 'fixture setup: the room must be PLAYING');
      return (host: host, guest: join);
    }

    void setSeat(
      ({RoomRegistry registry, FakeClock clock}) harness,
      String code,
      String seatToken,
      bool connected,
    ) {
      expect(
        harness.registry.setConnected(
            code: code, seatToken: seatToken, connected: connected),
        isTrue,
        reason: 'fixture setup: setConnected(connected: $connected) must '
            'flip the seat',
      );
    }

    // R1.
    test(
        'R1: a PLAYING room with one seat connected throughout survives 59 '
        'minutes, 61 minutes, 3 hours and 5h59m59s, and is reaped at exactly 6 '
        'hours', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;
      setSeat(harness, code, room.guest.seat.seatToken, false);

      Duration elapsed = Duration.zero;
      void advanceTo(Duration target) {
        harness.clock.advance(target - elapsed);
        elapsed = target;
      }

      final List<Duration> alive = <Duration>[
        const Duration(minutes: 59),
        const Duration(minutes: 61),
        const Duration(hours: 3),
        const Duration(hours: 5, minutes: 59),
        const Duration(hours: 5, minutes: 59, seconds: 59),
      ];
      for (final Duration at in alive) {
        advanceTo(at);
        expect(harness.registry.reap(), 0,
            reason: 'R1: PLAYING, host connected throughout, must not be '
                'reaped $at after creation');
        expect(harness.registry.lookup(code), isNotNull,
            reason: 'R1: room $code gone $at after creation');
      }

      advanceTo(const Duration(hours: 6));
      expect(harness.registry.reap(), 1,
          reason: 'R1: the 6 hour ceiling must reap a PLAYING room at '
              'exactly 6 hours after creation even with a seat connected');
      expect(harness.registry.lookup(code), isNull);
    });

    // R1 variant: the ceiling is a total, so being idle and busy changes
    // nothing about it. Both seats connected the whole time.
    test('R1: a PLAYING room with both seats connected is reaped at 6 hours',
        () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(hours: 5, minutes: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R1: both seats connected, 5h59m after creation');
      harness.clock.advance(const Duration(minutes: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R1: both seats connected, exactly 6 hours after creation');
      expect(harness.registry.lookup(code), isNull);
    });

    // R2.
    test(
        'R2: a PLAYING room whose every seat disconnected at minute 20 is not '
        'reaped at 9m59s after the last disconnect and is reaped at 10m', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 20));
      setSeat(harness, code, room.host.seat.seatToken, false);
      setSeat(harness, code, room.guest.seat.seatToken, false);

      harness.clock.advance(const Duration(minutes: 9, seconds: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R2: 9m59s after every seat disconnected (minute 20) must '
              'not be reaped');
      expect(harness.registry.lookup(code), isNotNull);

      harness.clock.advance(const Duration(seconds: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R2: exactly 10m after every seat disconnected must be '
              'reaped, PLAYING');
      expect(harness.registry.lookup(code), isNull);
    });

    // R2, ugly: the idle clock runs from the moment the LAST seat leaves,
    // not from the first.
    test(
        'R2: the idle clock starts when the last connected seat leaves, not '
        'when the first one does', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 20));
      setSeat(harness, code, room.guest.seat.seatToken, false);
      harness.clock.advance(const Duration(minutes: 8));
      setSeat(harness, code, room.host.seat.seatToken, false);

      harness.clock.advance(const Duration(minutes: 9, seconds: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R2: 9m59s after the last seat left (18m after the first) '
              'must not be reaped');
      harness.clock.advance(const Duration(seconds: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R2: exactly 10m after the last seat left must be reaped');
      expect(harness.registry.lookup(code), isNull);
    });

    // R2, ugly: with a seat connected the same room is not idle at all.
    test(
        'R2: a PLAYING room with one seat connected is never idle, however '
        'long the other seat has been gone', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 5));
      setSeat(harness, code, room.guest.seat.seatToken, false);
      harness.clock.advance(const Duration(minutes: 30));
      expect(harness.registry.reap(), 0,
          reason: 'R2: one seat gone for 30m, the host connected: not idle');
      expect(harness.registry.lookup(code), isNotNull);
    });

    // R2, D2: the turn timer acting for an absent seat is not a connection.
    test(
        'R2: the turn timer playing for absent seats does not postpone the '
        'idle reap', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 20));
      setSeat(harness, code, room.host.seat.seatToken, false);
      setSeat(harness, code, room.guest.seat.seatToken, false);

      // Let the timer act for the absent seats three times, a few minutes
      // apart, inside the idle window.
      for (int i = 0; i < 3; i++) {
        harness.clock.advance(const Duration(minutes: 3));
        final List<ExpiredTurn> acted = harness.registry.expireTurns();
        expect(acted, isNotEmpty,
            reason: 'fixture setup: at ${3 * (i + 1)}m after the disconnect '
                'the timer must have acted for the absent seat on turn');
        expect(harness.registry.reap(), 0,
            reason: 'R2: ${3 * (i + 1)}m idle, must not be reaped yet');
      }

      harness.clock.advance(const Duration(minutes: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R2/D2: 10m after every seat disconnected the room must be '
              'reaped even though the timer acted for the seats at 3m, 6m '
              'and 9m; the timer is not a connection');
      expect(harness.registry.lookup(code), isNull);
    });

    // R3.
    test(
        'R3: all disconnect, one reconnects at 9 minutes: not reaped 15 '
        'minutes after the first disconnect, and the idle clock restarts at '
        'the next all-disconnected moment', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 20));
      setSeat(harness, code, room.host.seat.seatToken, false);
      setSeat(harness, code, room.guest.seat.seatToken, false);

      harness.clock.advance(const Duration(minutes: 9));
      expect(harness.registry.reap(), 0, reason: 'R3: 9m idle');
      setSeat(harness, code, room.host.seat.seatToken, true);

      harness.clock.advance(const Duration(minutes: 6));
      expect(harness.registry.reap(), 0,
          reason: 'R3: 15m after the first disconnect, but the host '
              'reconnected at 9m, so the room is not idle');
      expect(harness.registry.lookup(code), isNotNull);

      // The host leaves again: a new idle period starts here, at minute 35.
      setSeat(harness, code, room.host.seat.seatToken, false);
      harness.clock.advance(const Duration(minutes: 9, seconds: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R3: 9m59s after the second all-disconnected moment (24m59s '
              'after the first) must not be reaped; the clock must have '
              'restarted');
      harness.clock.advance(const Duration(seconds: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R3: 10m after the second all-disconnected moment must be '
              'reaped');
      expect(harness.registry.lookup(code), isNull);
    });

    // R5.
    test(
        'R5: a game started at minute 50 is not reaped at minute 61 or 120 '
        'with a seat connected', () {
      final harness = _harness();
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      final JoinResult join =
          harness.registry.joinRoom(code: host.room.code, name: 'Guest');
      expect(join, isA<JoinOk>(), reason: 'fixture setup, got $join');
      harness.clock.advance(const Duration(minutes: 50));
      final StartResult start = harness.registry
          .startGame(code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartOk>(),
          reason: 'fixture setup: expected the room to start at minute 50, '
              'got $start');

      harness.clock.advance(const Duration(minutes: 11));
      expect(harness.registry.reap(), 0,
          reason: 'R5: minute 61, started at minute 50, seats connected');
      expect(harness.registry.lookup(host.room.code), isNotNull);

      harness.clock.advance(const Duration(minutes: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R5: minute 120, started at minute 50, seats connected');
      expect(harness.registry.lookup(host.room.code), isNotNull);
    });

    // R5, ugly: the same room left in LOBBY keeps the 60 minute total.
    test(
        'R5: the same room left in LOBBY with a seat connected is reaped at '
        'minute 60', () {
      final harness = _harness();
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      harness.clock.advance(const Duration(minutes: 59));
      expect(harness.registry.reap(), 0, reason: 'R5: LOBBY at minute 59');
      harness.clock.advance(const Duration(minutes: 1));
      expect(harness.registry.reap(), 1, reason: 'R5: LOBBY at minute 60');
      expect(harness.registry.lookup(host.room.code), isNull);
    });

    // R6. FINISHED is reached the way rematch_test.dart, leave_table_test.dart
    // and turn_loop_test.dart reach it: the direct mutation of Room.state.
    test(
        'R6: FINISHED at minute 58 with seats connected is not reaped at '
        'minute 61 and is reaped 10 minutes after it was first observed', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 58));
      harness.registry.lookup(code)!.state = RoomState.finished;
      expect(harness.registry.reap(), 0,
          reason: 'R6: first observation of FINISHED at minute 58 must not '
              'reap');

      harness.clock.advance(const Duration(minutes: 3));
      expect(harness.registry.reap(), 0,
          reason: 'R6: minute 61, FINISHED observed at minute 58 (3m ago), '
              'seats connected: the 60 minute total must not apply');
      expect(harness.registry.lookup(code), isNotNull);

      harness.clock.advance(const Duration(minutes: 6, seconds: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R6: 9m59s after FINISHED was first observed');
      harness.clock.advance(const Duration(seconds: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R6: exactly 10m after FINISHED was first observed (minute '
              '68) must reap');
      expect(harness.registry.lookup(code), isNull);
    });

    // R6, ugly: the 10 minutes count from the first reap() that sees
    // FINISHED, not from when the state was written.
    test(
        'R6: the FINISHED clock starts at the first reap() that sees it, not '
        'when the state was written', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(minutes: 58));
      harness.registry.lookup(code)!.state = RoomState.finished;
      harness.clock.advance(const Duration(minutes: 4));
      expect(harness.registry.reap(), 0,
          reason: 'R6: the first reap() to see FINISHED runs at minute 62; '
              'it starts the 10 minute clock and must not reap');
      harness.clock.advance(const Duration(minutes: 9, seconds: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R6: 9m59s after the first observation (minute 62)');
      harness.clock.advance(const Duration(seconds: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R6: 10m after the first observation (minute 72)');
      expect(harness.registry.lookup(code), isNull);
    });

    // R8 (D9). The FINISHED clock belongs to one finished game: a stamp
    // taken at game 1's end card must not shorten game 2's end card.
    // Housekeeping ticks (reap()) run while the room is in LOBBY and PLAYING
    // between the two games, as the server's once-a-minute tick does.
    test(
        'R8: a rematched room gets a fresh FINISHED clock for game 2: game 1 '
        'stamped at minute 0, rematch at 5, game 2 finished at 35, reaped '
        '10 minutes after game 2 was first observed finished, not before', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;
      final Room live = harness.registry.lookup(code)!;

      live.state = RoomState.finished;
      expect(harness.registry.reap(), 0,
          reason: 'R8: minute 0, game 1 FINISHED first observed here');

      harness.clock.advance(const Duration(minutes: 5));
      final RematchResult asked = harness.registry
          .rematch(code: code, seatToken: room.host.seat.seatToken);
      expect(asked, isA<RematchOk>(),
          reason: 'fixture setup: the host rematch at minute 5 must be '
              'accepted, got $asked');
      final RematchResult accepted = harness.registry
          .rematch(code: code, seatToken: room.guest.seat.seatToken);
      expect(accepted, isA<RematchOk>(),
          reason: 'fixture setup: the guest accept must succeed, got '
              '$accepted');
      expect((accepted as RematchOk).autoStart, isTrue,
          reason: 'fixture setup: both seats connected and ready, the '
              'rematch must auto-start');
      harness.registry.startRematchAuto(accepted.room);
      expect(harness.registry.lookup(code)!.state, RoomState.playing,
          reason: 'fixture setup: game 2 must be PLAYING after the rematch');

      harness.clock.advance(const Duration(minutes: 15));
      expect(harness.registry.reap(), 0,
          reason: 'R8: minute 20, game 2 PLAYING, seats connected');

      harness.clock.advance(const Duration(minutes: 15));
      harness.registry.lookup(code)!.state = RoomState.finished;
      harness.clock.advance(const Duration(minutes: 1));
      expect(harness.registry.reap(), 0,
          reason: 'R8: minute 36, 1 minute after game 2 finished (35). Game '
              '1\'s FINISHED stamp from minute 0 must not apply to game 2');
      expect(harness.registry.lookup(code), isNotNull,
          reason: 'R8: room $code lost its game 2 end card 1 minute after '
              'game 2 finished');

      harness.clock.advance(const Duration(minutes: 9, seconds: 59));
      expect(harness.registry.reap(), 0,
          reason: 'R8: 9m59s after game 2 was first observed FINISHED '
              '(minute 36)');
      harness.clock.advance(const Duration(seconds: 1));
      expect(harness.registry.reap(), 1,
          reason: 'R8: 10m after game 2 was first observed FINISHED (minute '
              '36), reaped at minute 46');
      expect(harness.registry.lookup(code), isNull);
    });

    // D3 and D4 together: a FINISHED room is gone long before the ceiling.
    test(
        'R6: a FINISHED room with seats connected never outlives 10 minutes '
        'of observation, even hours into the ceiling window', () {
      final harness = _harness();
      final room = startedRoom(harness);
      final String code = room.host.room.code;

      harness.clock.advance(const Duration(hours: 4));
      harness.registry.lookup(code)!.state = RoomState.finished;
      expect(harness.registry.reap(), 0, reason: 'R6: 4h, first observation');
      harness.clock.advance(const Duration(minutes: 10));
      expect(harness.registry.reap(), 1,
          reason: 'R6: 10m after first observation at 4h');
      expect(harness.registry.lookup(code), isNull);
    });
  });
}
