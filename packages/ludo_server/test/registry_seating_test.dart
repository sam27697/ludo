// Conformance tests for RoomRegistry.setPlayers, docs/PROTOCOL.md sections
// 3 and 4 ("set_players") and docs/RULES.md rule 2a: a game's seat set is
// fixed by the number of players actually in the game, and set_players
// re-seats everyone onto the canonical seat set for the new count.
//
// Kept in its own file, separate from registry_lifecycle_test.dart, because
// SetPlayersResult and RoomRegistry.setPlayers are landing under work order
// 010 in parallel with this one and may not exist yet. If they do not
// compile, only this file fails to compile; the rest of the suite still
// runs.
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
  test(
      'resizing a 4p room holding 2 people down to 2 reseats them at 0 '
      'and 2 in join order, both tokens still resume to the new seat, and '
      'the host seat follows the host', () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 4);
    final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
    expect(guest.seat.seat, 1,
        reason:
            'fixture sanity check: second joiner of a 4p room takes seat 1');

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 2,
    );
    expect(resize, isA<SetPlayersOk>(), reason: 'got $resize');
    final Room resized = (resize as SetPlayersOk).room;
    expect(resized.players, 2);
    expect(resized.seats.map((Seat s) => s.seat).toList(), <int>[0, 2]);
    expect(resized.hostSeat, 0,
        reason: 'the host was seat 0 before resizing and must remain the host');

    final ResumeResult resumeHost =
        registry.resume(code: host.room.code, seatToken: host.seat.seatToken);
    expect(resumeHost, isA<ResumeOk>(), reason: 'got $resumeHost');
    expect((resumeHost as ResumeOk).seat.seat, 0);

    final ResumeResult resumeGuest =
        registry.resume(code: host.room.code, seatToken: guest.seat.seatToken);
    expect(resumeGuest, isA<ResumeOk>(), reason: 'got $resumeGuest');
    expect((resumeGuest as ResumeOk).seat.seat, 2);
  });

  test('resizing a 2p room holding 2 people up to 4 reseats them at 0 and 1',
      () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 2);
    final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
    expect(guest.seat.seat, 2,
        reason:
            'fixture sanity check: second joiner of a 2p room takes seat 2');

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 4,
    );
    expect(resize, isA<SetPlayersOk>(), reason: 'got $resize');
    final Room resized = (resize as SetPlayersOk).room;
    expect(resized.players, 4);
    expect(resized.seats.map((Seat s) => s.seat).toList(), <int>[0, 1]);
    expect(resized.hostSeat, 0);

    final ResumeResult resumeHost =
        registry.resume(code: host.room.code, seatToken: host.seat.seatToken);
    expect((resumeHost as ResumeOk).seat.seat, 0);
    final ResumeResult resumeGuest =
        registry.resume(code: host.room.code, seatToken: guest.seat.seatToken);
    expect((resumeGuest as ResumeOk).seat.seat, 1);
  });

  test(
      'resizing below current occupancy is NOT_ENOUGH_PLAYERS and mutates nothing',
      () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 4);
    _join(registry, code: host.room.code, name: 'B');
    _join(registry, code: host.room.code, name: 'C');
    final Room before = registry.lookup(host.room.code)!;
    final List<int> seatsBefore = before.seats.map((Seat s) => s.seat).toList();
    final List<String> tokensBefore =
        before.seats.map((Seat s) => s.seatToken).toList();

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 2,
    );
    expect(resize, isA<SetPlayersFailure>(),
        reason: 'occupancy is 3, requesting players=2, got $resize');
    expect((resize as SetPlayersFailure).error, ProtocolError.notEnoughPlayers);

    final Room after = registry.lookup(host.room.code)!;
    expect(after.players, 4);
    expect(after.seats.map((Seat s) => s.seat).toList(), seatsBefore);
    expect(after.seats.map((Seat s) => s.seatToken).toList(), tokensBefore);
  });

  test(
      'resizing to the current occupancy count is SetPlayersOk and changes no token',
      () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 3);
    final JoinOk b = _join(registry, code: host.room.code, name: 'B');
    final JoinOk c = _join(registry, code: host.room.code, name: 'C');

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 3,
    );
    expect(resize, isA<SetPlayersOk>(), reason: 'got $resize');

    final Room after = (resize as SetPlayersOk).room;
    expect(
      after.seats.map((Seat s) => s.seatToken).toList(),
      <String>[host.seat.seatToken, b.seat.seatToken, c.seat.seatToken],
    );
  });

  test('resizing a PLAYING room is ROOM_STARTED', () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 2);
    _join(registry, code: host.room.code, name: 'Guest');
    final StartResult start = registry.startGame(
        code: host.room.code, seatToken: host.seat.seatToken);
    expect(start, isA<StartOk>(),
        reason: 'fixture setup: expected the room to start, got $start');

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 4,
    );
    expect(resize, isA<SetPlayersFailure>());
    expect((resize as SetPlayersFailure).error, ProtocolError.roomStarted);
  });

  test('players: 5 and players: 1 are BAD_FIELD', () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 2);

    final SetPlayersResult five = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 5,
    );
    expect(five, isA<SetPlayersFailure>(), reason: 'got $five');
    expect((five as SetPlayersFailure).error, ProtocolError.badField);

    final SetPlayersResult one = registry.setPlayers(
      code: host.room.code,
      seatToken: host.seat.seatToken,
      players: 1,
    );
    expect(one, isA<SetPlayersFailure>(), reason: 'got $one');
    expect((one as SetPlayersFailure).error, ProtocolError.badField);
  });

  test('setPlayers with a wrong seat token is BAD_SEAT_TOKEN', () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 2);

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: 'not-a-real-seat-token',
      players: 3,
    );
    expect(resize, isA<SetPlayersFailure>());
    expect((resize as SetPlayersFailure).error, ProtocolError.badSeatToken);
  });

  test('setPlayers from a non-host seat is NOT_HOST', () {
    final registry = _harness().registry;
    final CreateOk host = _create(registry, name: 'Host', players: 3);
    final JoinOk guest = _join(registry, code: host.room.code, name: 'Guest');
    _join(registry, code: host.room.code, name: 'Third');

    final SetPlayersResult resize = registry.setPlayers(
      code: host.room.code,
      seatToken: guest.seat.seatToken,
      players: 2,
    );
    expect(resize, isA<SetPlayersFailure>());
    expect((resize as SetPlayersFailure).error, ProtocolError.notHost);
  });
}
