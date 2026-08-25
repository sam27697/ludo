// Conformance tests for reaping and the code quarantine window,
// docs/PROTOCOL.md section 3:
//   "A room in any state is reaped 60 minutes after creation regardless.
//    A LOBBY with no connected clients is reaped after 10 minutes... A
//    reaped room's code is not reissued for 24 hours."
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
      'any room is reaped at exactly 60 minutes and not at 59, including a PLAYING one',
      () {
    final harness = _harness();
    final CreateOk host = _create(harness.registry, name: 'Host', players: 2);
    final JoinResult join =
        harness.registry.joinRoom(code: host.room.code, name: 'Guest');
    expect(join, isA<JoinOk>(), reason: 'fixture setup, got $join');
    final StartResult start = harness.registry
        .startGame(code: host.room.code, seatToken: host.seat.seatToken);
    expect(start, isA<StartOk>(),
        reason: 'fixture setup: expected the room to start, got $start');

    harness.clock.advance(const Duration(minutes: 59));
    expect(harness.registry.reap(), 0,
        reason: 'must not be reaped at 59 minutes total, even PLAYING');
    expect(harness.registry.lookup(host.room.code), isNotNull);

    harness.clock.advance(const Duration(minutes: 1));
    expect(harness.registry.reap(), 1,
        reason:
            'must be reaped at exactly 60 minutes total regardless of state');
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
}
