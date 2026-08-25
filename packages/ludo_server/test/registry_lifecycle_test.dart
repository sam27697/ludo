// Conformance tests for RoomRegistry against docs/PROTOCOL.md sections 2, 3
// and 4, and docs/RULES.md section 2 (including 2a), covering everything
// except player-count resizing (registry_seating_test.dart, isolated
// because it depends on the SetPlayersResult work order 010 is landing) and
// reaping/quarantine (registry_reap_test.dart, isolated because it is all
// FakeClock-driven and large on its own).
//
// Every RoomRegistry here is built with a FakeClock so nothing in this file
// depends on wall time, even where a given test never advances it.
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

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

JoinOk _join(RoomRegistry registry,
    {required String code, required String name}) {
  final JoinResult result = registry.joinRoom(code: code, name: name);
  if (result is! JoinOk) {
    fail('expected JoinOk for code=$code name="$name", got $result');
  }
  return result;
}

void main() {
  group('seating', () {
    test('2 players seat at 0 and 2, host takes seat 0', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      expect(host.seat.seat, 0);
      expect(host.room.hostSeat, 0);

      final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
      expect(guest.seat.seat, 2);
      expect(guest.room.seats.map((Seat s) => s.seat).toList(), <int>[0, 2]);
    });

    test('3 players seat at 0, 1 and 2', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 3);
      final JoinOk b = _join(registry, code: host.room.code, name: 'B');
      final JoinOk c = _join(registry, code: host.room.code, name: 'C');
      expect(host.seat.seat, 0);
      expect(b.seat.seat, 1);
      expect(c.seat.seat, 2);
      expect(c.room.seats.map((Seat s) => s.seat).toList(), <int>[0, 1, 2]);
    });

    test('4 players seat at 0, 1, 2 and 3', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 4);
      final JoinOk b = _join(registry, code: host.room.code, name: 'B');
      final JoinOk c = _join(registry, code: host.room.code, name: 'C');
      final JoinOk d = _join(registry, code: host.room.code, name: 'D');
      expect(<int>[host.seat.seat, b.seat.seat, c.seat.seat, d.seat.seat],
          <int>[0, 1, 2, 3]);
      expect(d.room.seats.map((Seat s) => s.seat).toList(), <int>[0, 1, 2, 3]);
    });

    test('room.seats stays ascending after a mid seat leaves and is refilled',
        () {
      final registry = _harness().registry;
      final CreateOk a = _create(registry, name: 'A', players: 3);
      final JoinOk b = _join(registry, code: a.room.code, name: 'B');
      _join(registry, code: a.room.code, name: 'C');

      final LeaveResult leave =
          registry.leaveRoom(code: a.room.code, seatToken: b.seat.seatToken);
      expect(leave, isA<LeaveOk>(),
          reason: 'B should be able to leave the LOBBY, got $leave');

      final JoinOk d = _join(registry, code: a.room.code, name: 'D');
      expect(d.seat.seat, 1,
          reason: 'the freed seat 1 is the lowest open canonical slot');
      expect(
        d.room.seats.map((Seat s) => s.seat).toList(),
        <int>[0, 1, 2],
        reason:
            'seats must stay ascending by seat index after a mid-list refill',
      );
      expect(
        d.room.seats.map((Seat s) => s.name).toList(),
        <String>['A', 'D', 'C'],
      );
    });

    test('joining a full room is ROOM_FULL', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      _join(registry, code: host.room.code, name: 'Guest');

      final JoinResult third =
          registry.joinRoom(code: host.room.code, name: 'Third');
      expect(third, isA<JoinFailure>());
      expect((third as JoinFailure).error, ProtocolError.roomFull);
    });

    test('joining a room that is not in LOBBY is ROOM_STARTED', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');

      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartOk>(),
          reason: 'start_game on a full LOBBY room should succeed, got $start');
      expect(guest.seat.seat, 2,
          reason:
              'sanity check on the fixture, unrelated to the assertion below');

      final JoinResult lateJoin =
          registry.joinRoom(code: host.room.code, name: 'Late');
      expect(lateJoin, isA<JoinFailure>());
      expect((lateJoin as JoinFailure).error, ProtocolError.roomStarted);
    });
  });

  group('seat tokens are the only authority', () {
    test('resume with a wrong token is BAD_SEAT_TOKEN', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);

      final ResumeResult resume = registry.resume(
          code: host.room.code, seatToken: 'not-a-real-seat-token');
      expect(resume, isA<ResumeFailure>());
      expect((resume as ResumeFailure).error, ProtocolError.badSeatToken);
    });

    test('startGame with a wrong token is BAD_SEAT_TOKEN', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      _join(registry, code: host.room.code, name: 'Guest');

      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: 'not-a-real-seat-token');
      expect(start, isA<StartFailure>());
      expect((start as StartFailure).error, ProtocolError.badSeatToken);
    });

    test('leaveRoom with a wrong token is BAD_SEAT_TOKEN', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);

      final LeaveResult leave = registry.leaveRoom(
          code: host.room.code, seatToken: 'not-a-real-seat-token');
      expect(leave, isA<LeaveFailure>());
      expect((leave as LeaveFailure).error, ProtocolError.badSeatToken);
    });

    test('a token valid in a different room is BAD_SEAT_TOKEN here', () {
      final registry = _harness().registry;
      final CreateOk roomA = _create(registry, name: 'A-Host', players: 2);
      final CreateOk roomB = _create(registry, name: 'B-Host', players: 2);

      final ResumeResult resume = registry.resume(
          code: roomA.room.code, seatToken: roomB.seat.seatToken);
      expect(resume, isA<ResumeFailure>());
      expect((resume as ResumeFailure).error, ProtocolError.badSeatToken);
    });

    test('a non-host token cannot startGame: NOT_HOST', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');

      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: guest.seat.seatToken);
      expect(start, isA<StartFailure>());
      expect((start as StartFailure).error, ProtocolError.notHost);

      final Room? afterwards = registry.lookup(host.room.code);
      expect(afterwards, isNotNull);
      expect(afterwards!.state, RoomState.lobby);
      expect(afterwards.game, isNull);
    });
  });

  group('starting', () {
    test('starting requires every configured seat filled: NOT_ENOUGH_PLAYERS',
        () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 4);
      _join(registry, code: host.room.code, name: 'B');
      _join(registry, code: host.room.code, name: 'C');

      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartFailure>());
      expect((start as StartFailure).error, ProtocolError.notEnoughPlayers);

      final Room? afterwards = registry.lookup(host.room.code);
      expect(afterwards!.state, RoomState.lobby);
      expect(afterwards.game, isNull);
    });

    test(
        'a started room is playing, has a non-null game, and refuses a '
        'second start with ROOM_STARTED', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      _join(registry, code: host.room.code, name: 'Guest');

      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartOk>(),
          reason: 'starting a full LOBBY room should succeed, got $start');

      final Room? afterwards = registry.lookup(host.room.code);
      expect(afterwards, isNotNull);
      expect(afterwards!.state, RoomState.playing);
      expect(afterwards.game, isNotNull);

      final StartResult second = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(second, isA<StartFailure>());
      expect((second as StartFailure).error, ProtocolError.roomStarted);
    });
  });

  group('leaving', () {
    test('leaving in LOBBY frees the seat and the room can be joined again',
        () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');

      final LeaveResult leave = registry.leaveRoom(
          code: host.room.code, seatToken: guest.seat.seatToken);
      expect(leave, isA<LeaveOk>());

      final Room? afterLeave = registry.lookup(host.room.code);
      expect(afterLeave!.seats.map((Seat s) => s.seat).toList(), <int>[0]);
      expect(afterLeave.state, RoomState.lobby);

      final JoinOk newcomer =
          _join(registry, code: host.room.code, name: 'Newcomer');
      expect(newcomer.seat.seat, 2);
    });

    test(
        'leaving in PLAYING does not free the seat: it stays and is '
        'marked disconnected', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartOk>(),
          reason: 'fixture setup: expected the room to start, got $start');

      final LeaveResult leave = registry.leaveRoom(
          code: host.room.code, seatToken: guest.seat.seatToken);
      expect(leave, isA<LeaveOk>(),
          reason: 'leave_room is voluntary and allowed in PLAYING, got $leave');

      final Room? afterwards = registry.lookup(host.room.code);
      expect(afterwards!.state, RoomState.playing);
      expect(
        afterwards.seats.map((Seat s) => s.seat).toList(),
        <int>[0, 2],
        reason: 'the seat must remain in the room while PLAYING',
      );
      final Seat guestSeat =
          afterwards.seats.firstWhere((Seat s) => s.seat == 2);
      expect(guestSeat.connected, isFalse);
    });

    test(
        'if the host leaves the LOBBY, the host passes to the lowest '
        'remaining seat index', () {
      final registry = _harness().registry;
      final CreateOk a = _create(registry, name: 'A', players: 4);
      _join(registry, code: a.room.code, name: 'B');
      _join(registry, code: a.room.code, name: 'C');

      final LeaveResult leave =
          registry.leaveRoom(code: a.room.code, seatToken: a.seat.seatToken);
      expect(leave, isA<LeaveOk>());

      final Room? afterwards = registry.lookup(a.room.code);
      expect(afterwards!.hostSeat, 1);
      expect(afterwards.seats.map((Seat s) => s.seat).toList(), <int>[1, 2]);
    });

    test('a seat that left while PLAYING can still resume', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);
      final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
      final StartResult start = registry.startGame(
          code: host.room.code, seatToken: host.seat.seatToken);
      expect(start, isA<StartOk>(),
          reason: 'fixture setup: expected the room to start, got $start');

      final LeaveResult leave = registry.leaveRoom(
          code: host.room.code, seatToken: guest.seat.seatToken);
      expect(leave, isA<LeaveOk>());

      final ResumeResult resume = registry.resume(
          code: host.room.code, seatToken: guest.seat.seatToken);
      expect(resume, isA<ResumeOk>(),
          reason:
              'a seat that left while PLAYING must still be able to resume, '
              'got $resume');
      expect((resume as ResumeOk).seat.seat, 2);
    });
  });

  group('reconnection', () {
    test(
        'setConnected(false) then resume with the same token returns the '
        'same seat and marks it connected again', () {
      final registry = _harness().registry;
      final CreateOk host = _create(registry, name: 'Host', players: 2);

      registry.setConnected(
          code: host.room.code,
          seatToken: host.seat.seatToken,
          connected: false);
      final Room? disconnected = registry.lookup(host.room.code);
      expect(disconnected!.seats.single.connected, isFalse);

      final ResumeResult resume =
          registry.resume(code: host.room.code, seatToken: host.seat.seatToken);
      expect(resume, isA<ResumeOk>());
      expect((resume as ResumeOk).seat.seat, 0);

      final Room? reconnected = registry.lookup(host.room.code);
      expect(reconnected!.seats.single.connected, isTrue);
    });
  });

  group(
      'name validation: 1 to 24 characters after trimming, no control '
      'characters', () {
    test('empty string is BAD_FIELD', () {
      final registry = _harness().registry;
      final CreateResult result =
          registry.createRoom(name: '', players: 2, rules: _defaultRules);
      expect(result, isA<CreateFailure>());
      expect((result as CreateFailure).error, ProtocolError.badField);
    });

    test('whitespace only is BAD_FIELD', () {
      final registry = _harness().registry;
      final CreateResult result =
          registry.createRoom(name: '    ', players: 2, rules: _defaultRules);
      expect(result, isA<CreateFailure>());
      expect((result as CreateFailure).error, ProtocolError.badField);
    });

    test('exactly 24 characters is accepted', () {
      final registry = _harness().registry;
      final String name = 'A' * 24;
      final CreateResult result =
          registry.createRoom(name: name, players: 2, rules: _defaultRules);
      expect(result, isA<CreateOk>(),
          reason: 'a 24 character name must be accepted, got $result');
      expect((result as CreateOk).seat.name, name);
    });

    test('exactly 25 characters is BAD_FIELD', () {
      final registry = _harness().registry;
      final String name = 'A' * 25;
      final CreateResult result =
          registry.createRoom(name: name, players: 2, rules: _defaultRules);
      expect(result, isA<CreateFailure>());
      expect((result as CreateFailure).error, ProtocolError.badField);
    });

    test('a name containing a newline is BAD_FIELD', () {
      final registry = _harness().registry;
      final CreateResult result = registry.createRoom(
          name: 'Sam\nEvil', players: 2, rules: _defaultRules);
      expect(result, isA<CreateFailure>());
      expect((result as CreateFailure).error, ProtocolError.badField);
    });

    test('a name containing an internal space is accepted', () {
      final registry = _harness().registry;
      final CreateResult result =
          registry.createRoom(name: 'Sam A', players: 2, rules: _defaultRules);
      expect(result, isA<CreateOk>(), reason: 'got $result');
      expect((result as CreateOk).seat.name, 'Sam A');
    });

    test('leading and trailing spaces are accepted and stored trimmed', () {
      final registry = _harness().registry;
      final CreateResult result = registry.createRoom(
          name: '  Sam  ', players: 2, rules: _defaultRules);
      expect(result, isA<CreateOk>(), reason: 'got $result');
      expect((result as CreateOk).seat.name, 'Sam');
    });

    test(
        'an Arabic name is accepted, because a length check that counts '
        'UTF-16 code units instead of characters is a real bug for a '
        'client whose users read Arabic', () {
      final registry = _harness().registry;
      const String name = 'محمد العلي';
      expect(name.length, lessThanOrEqualTo(24),
          reason: 'fixture sanity check');
      final CreateResult result =
          registry.createRoom(name: name, players: 2, rules: _defaultRules);
      expect(result, isA<CreateOk>(), reason: 'got $result');
      expect((result as CreateOk).seat.name, name);
    });
  });

  group('players validation: 2, 3 or 4 only', () {
    test('players outside 2..4 is BAD_FIELD on createRoom', () {
      final registry = _harness().registry;
      for (final int players in <int>[0, 1, 5, 6]) {
        final CreateResult result = registry.createRoom(
            name: 'Host', players: players, rules: _defaultRules);
        expect(result, isA<CreateFailure>(),
            reason: 'players=$players should be rejected, got $result');
        expect((result as CreateFailure).error, ProtocolError.badField,
            reason: 'players=$players');
      }
    });
  });

  group('turnSeconds validation: 15 to 120', () {
    test('14 is BAD_FIELD, 15 is accepted, 120 is accepted, 121 is BAD_FIELD',
        () {
      final registry = _harness().registry;

      final CreateResult r14 = registry.createRoom(
        name: 'Host',
        players: 2,
        rules: const RulesConfig(turnSeconds: 14),
      );
      expect(r14, isA<CreateFailure>(), reason: 'turnSeconds=14, got $r14');
      expect((r14 as CreateFailure).error, ProtocolError.badField);

      final CreateResult r15 = registry.createRoom(
        name: 'Host',
        players: 2,
        rules: const RulesConfig(turnSeconds: 15),
      );
      expect(r15, isA<CreateOk>(), reason: 'turnSeconds=15, got $r15');

      final CreateResult r120 = registry.createRoom(
        name: 'Host',
        players: 2,
        rules: const RulesConfig(turnSeconds: 120),
      );
      expect(r120, isA<CreateOk>(), reason: 'turnSeconds=120, got $r120');

      final CreateResult r121 = registry.createRoom(
        name: 'Host',
        players: 2,
        rules: const RulesConfig(turnSeconds: 121),
      );
      expect(r121, isA<CreateFailure>(), reason: 'turnSeconds=121, got $r121');
      expect((r121 as CreateFailure).error, ProtocolError.badField);
    });
  });

  group('existence must not leak', () {
    test(
        'joinRoom, resume, startGame and leaveRoom against a code that '
        'never existed all return NO_SUCH_ROOM', () {
      final registry = _harness().registry;
      const String neverExisted = 'ZZZZZZ';
      final String someToken = generateSeatToken(Random.secure());

      final JoinResult join = registry.joinRoom(code: neverExisted, name: 'X');
      expect(join, isA<JoinFailure>());
      expect((join as JoinFailure).error, ProtocolError.noSuchRoom);

      final ResumeResult resume =
          registry.resume(code: neverExisted, seatToken: someToken);
      expect(resume, isA<ResumeFailure>());
      expect((resume as ResumeFailure).error, ProtocolError.noSuchRoom);

      final StartResult start =
          registry.startGame(code: neverExisted, seatToken: someToken);
      expect(start, isA<StartFailure>());
      expect((start as StartFailure).error, ProtocolError.noSuchRoom);

      final LeaveResult leave =
          registry.leaveRoom(code: neverExisted, seatToken: someToken);
      expect(leave, isA<LeaveFailure>());
      expect((leave as LeaveFailure).error, ProtocolError.noSuchRoom);
    });

    test(
        'a reaped room returns NO_SUCH_ROOM on all four entry points, and '
        'specifically not BAD_SEAT_TOKEN even for a token that was '
        'genuinely a seat there', () {
      final harness = _harness();
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      final String code = host.room.code;
      final String token = host.seat.seatToken;

      harness.registry
          .setConnected(code: code, seatToken: token, connected: false);
      harness.clock.advance(const Duration(minutes: 10));
      expect(harness.registry.reap(), 1);
      expect(harness.registry.lookup(code), isNull);

      final JoinResult join = harness.registry.joinRoom(code: code, name: 'X');
      expect(join, isA<JoinFailure>());
      expect((join as JoinFailure).error, ProtocolError.noSuchRoom);

      final ResumeResult resume =
          harness.registry.resume(code: code, seatToken: token);
      expect(resume, isA<ResumeFailure>());
      expect(
        (resume as ResumeFailure).error,
        ProtocolError.noSuchRoom,
        reason:
            'a genuinely former seat token must still see NO_SUCH_ROOM, not BAD_SEAT_TOKEN, '
            'once the room is gone',
      );

      final StartResult start =
          harness.registry.startGame(code: code, seatToken: token);
      expect(start, isA<StartFailure>());
      expect((start as StartFailure).error, ProtocolError.noSuchRoom);

      final LeaveResult leave =
          harness.registry.leaveRoom(code: code, seatToken: token);
      expect(leave, isA<LeaveFailure>());
      expect((leave as LeaveFailure).error, ProtocolError.noSuchRoom);
    });

    test(
        'a code that never existed and a code whose room was reaped '
        'produce the identical NO_SUCH_ROOM value', () {
      final harness = _harness();
      final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
      final String reapedCode = host.room.code;

      harness.registry.setConnected(
          code: reapedCode, seatToken: host.seat.seatToken, connected: false);
      harness.clock.advance(const Duration(minutes: 10));
      expect(harness.registry.reap(), 1);

      const String neverExisted = 'QRSTUV';
      final JoinResult neverResult =
          harness.registry.joinRoom(code: neverExisted, name: 'X');
      final JoinResult reapedResult =
          harness.registry.joinRoom(code: reapedCode, name: 'X');
      expect(neverResult, isA<JoinFailure>());
      expect(reapedResult, isA<JoinFailure>());

      final ProtocolError neverError = (neverResult as JoinFailure).error;
      final ProtocolError reapedError = (reapedResult as JoinFailure).error;
      expect(
        reapedError,
        same(neverError),
        reason:
            'a reaped room and a room that never existed must be indistinguishable to the '
            'caller: got $reapedError for the reaped code and $neverError for the code that '
            'never existed',
      );
    });
  });
}
