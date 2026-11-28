// Order 727t, controller half: docs/PROTOCOL.md section 38 items 1 to 3 and
// section 37 item 3 as the RoomController must read them (lobby_closing,
// ask_start, ask_start_ok, start_asked, room_closed with lobby_timeout).
//
// Written from the section texts and the controller contract of order 727
// alone. A real RoomController over FakeTransport (test/net/fake_transport.
// dart) with an injected clock, frames pushed one by one, no mocks of the
// controller. No random input, so the scenario name is the seed. Replay one
// case with:
//   flutter test test/c727_controller_lobby_closing_test.dart \
//     --plain-name '<scenario>'
// Every failure names the scenario, the frames pushed and the frames sent.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _code = 'K7M2QP';
const String _token = 'tok-c727-001';

int _idSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c727-srv-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;
String _idOf(String raw) => _decode(raw)['id']! as String;

Map<String, Object?> _roomJson({
  required int seq,
  List<int> seats = const <int>[0, 1],
  String state = 'LOBBY',
}) => <String, Object?>{
  'code': _code,
  'state': state,
  'host_seat': 0,
  'players': 4,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    for (final int s in seats)
      <String, Object?>{
        'seat': s,
        'name': s == 0 ? 'Sam' : 'Bob$s',
        'connected': true,
        'tokens': const <int>[-1, -1, -1, -1],
        'client_seed': null,
        'seed_origin': null,
      },
  ],
  'turn': state == 'PLAYING'
      ? <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        }
      : null,
  'winner': state == 'FINISHED' ? 0 : null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> queue = <FakeTransport>[];
  Future<WireTransport> call(Uri url) async {
    if (queue.isEmpty) {
      throw StateError('_Connector: nothing queued');
    }
    return queue.removeAt(0);
  }
}

class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

class _Rig {
  _Rig(this.name, this.tester, this.controller, this.transport, this.clock);

  final String name;
  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final _Clock clock;
  final List<String> pushed = <String>[];
  int seq = 1;

  String get why =>
      'scenario "$name"; pushed ${pushed.join(' | ')}; sent '
      '${transport.sentRaw.map(_typeOf).toList()}. reproduce: flutter test '
      "test/c727_controller_lobby_closing_test.dart --plain-name '$name'";

  static Future<_Rig> open(
    WidgetTester tester,
    String name, {
    bool host = false,
    List<int> seats = const <int>[0, 1],
    List<Duration> reconnectDelays = const <Duration>[],
    FakeTransport? second,
  }) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.queue.add(transport);
    if (second != null) {
      connector.queue.add(second);
    }
    final _Clock clock = _Clock(DateTime.utc(2026, 11, 28, 9));
    final RoomController controller = RoomController(
      serverUrl: Uri.parse('wss://c727.invalid/ws'),
      connect: connector.call,
      autoReconnectDelays: reconnectDelays,
      clock: clock.call,
    );
    addTearDown(() async {
      controller.dispose();
      await tester.pump(const Duration(seconds: 11));
    });
    final Future<void> opened = host
        ? controller.createRoom(name: 'Sam', players: 4)
        : controller.joinRoom(code: _code, name: 'Bob1');
    final _Rig rig = _Rig(name, tester, controller, transport, clock);
    await rig.settle();
    transport.pushText(
      _frame('seat_assigned', <String, Object?>{
        'seat': host ? 0 : 1,
        'seat_token': _token,
      }),
    );
    transport.pushText(
      _frame(
        'room',
        _roomJson(seq: rig.seq, seats: seats),
        re: _idOf(transport.sentRaw.last),
      ),
    );
    await rig.settle();
    await opened;
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture: expected connected. ${rig.why}',
    );
    return rig;
  }

  Future<void> settle() async {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    pushed.add('$type${jsonEncode(data)}');
    transport.pushText(_frame(type, data));
    await settle();
  }

  Future<void> pushRoom({List<int>? seats, String state = 'LOBBY'}) async {
    seq += 1;
    pushed.add('room(seq $seq, $state)');
    transport.pushText(
      _frame(
        'room',
        _roomJson(seq: seq, seats: seats ?? <int>[0, 1], state: state),
      ),
    );
    await settle();
  }

  /// Sends askStart and answers it with [replyType]/[data]. Returns the
  /// outcome and the raw request frame.
  Future<(AskStartOutcome, String)> ask(
    String replyType,
    Map<String, Object?> data,
  ) async {
    final int before = transport.sentRaw.length;
    final Future<AskStartOutcome> pending = controller.askStart();
    await settle();
    expect(
      transport.sentRaw.length,
      before + 1,
      reason: 'askStart must send exactly one frame. $why',
    );
    final String raw = transport.sentRaw.last;
    expect(_typeOf(raw), 'ask_start', reason: 'wrong request type. $why');
    pushed.add('$replyType${jsonEncode(data)} (re ask_start)');
    transport.pushText(_frame(replyType, data, re: _idOf(raw)));
    await settle();
    return (await pending, raw);
  }
}

void main() {
  late String install;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    install = await installId();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kInstallIdKey: install,
    });
  });

  group('lobby_closing', () {
    testWidgets('lobby_closing sets lobbyClosesAt to clock + closes_in_s and '
        'nothing else', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'closing sets only the deadline');
      expect(
        r.controller.lobbyClosesAt,
        isNull,
        reason: 'null before. ${r.why}',
      );
      final RoomSnapshot? room = r.controller.room;
      final int sent = r.transport.sentRaw.length;
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      expect(
        r.controller.lobbyClosesAt,
        r.clock.now.add(const Duration(seconds: 120)),
        reason: 'expected clock + 120 s. ${r.why}',
      );
      expect(r.controller.phase, RoomPhase.connected, reason: r.why);
      expect(r.controller.room, same(room), reason: 'room changed. ${r.why}');
      expect(r.controller.errorCode, isNull, reason: r.why);
      expect(r.controller.askStartAvailableAt, isNull, reason: r.why);
      expect(r.controller.lastStartAsked, isNull, reason: r.why);
      expect(r.controller.lobbyTimedOut, isFalse, reason: r.why);
      expect(
        r.transport.sentRaw.length,
        sent,
        reason: 'sent a reply. ${r.why}',
      );
    });

    testWidgets('lobby_closing reads the clock at arrival', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'closing uses arrival clock');
      r.clock.advance(const Duration(minutes: 8, seconds: 59));
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 61});
      expect(
        r.controller.lobbyClosesAt,
        r.clock.now.add(const Duration(seconds: 61)),
        reason: 'expected arrival clock + 61 s. ${r.why}',
      );
    });

    testWidgets('a second lobby_closing replaces the deadline (the '
        'late-attach replay)', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'closing twice');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      r.clock.advance(const Duration(seconds: 30));
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 90});
      expect(
        r.controller.lobbyClosesAt,
        r.clock.now.add(const Duration(seconds: 90)),
        reason: 'expected the newer frame to win. ${r.why}',
      );
    });

    testWidgets('closes_in_s of 0 is a deadline of now', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'closing zero');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 0});
      expect(r.controller.lobbyClosesAt, r.clock.now, reason: r.why);
    });

    for (final (String label, Map<String, Object?> data)
        in <(String, Map<String, Object?>)>[
          ('missing', <String, Object?>{}),
          ('string', <String, Object?>{'closes_in_s': '120'}),
          ('negative', <String, Object?>{'closes_in_s': -5}),
          ('null', <String, Object?>{'closes_in_s': null}),
        ]) {
      testWidgets('malformed closes_in_s ($label) sets no past deadline and '
          'breaks nothing', (WidgetTester tester) async {
        final _Rig r = await _Rig.open(tester, 'closing malformed $label');
        await r.push('lobby_closing', data);
        final DateTime? at = r.controller.lobbyClosesAt;
        expect(
          at == null || !at.isBefore(r.clock.now),
          isTrue,
          reason:
              'a malformed frame must not set a past deadline; saw $at. '
              '${r.why}',
        );
        expect(r.controller.phase, RoomPhase.connected, reason: r.why);
        await r.pushRoom();
        expect(
          r.controller.room?.seq,
          r.seq,
          reason: 'later push must apply. ${r.why}',
        );
      });
    }

    testWidgets('a phase change (the game starts) clears lobbyClosesAt', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'closing cleared by phase change');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      expect(r.controller.lobbyClosesAt, isNotNull, reason: r.why);
      await r.pushRoom(state: 'PLAYING');
      expect(
        r.controller.lobbyClosesAt,
        isNull,
        reason: 'left LOBBY but the deadline stayed. ${r.why}',
      );
    });

    testWidgets('a lobby_closing that arrives outside the lobby leaves no '
        'deadline behind', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'closing while playing');
      await r.pushRoom(state: 'PLAYING');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 100});
      expect(
        r.controller.lobbyClosesAt,
        isNull,
        reason: 'a PLAYING room has no lobby deadline. ${r.why}',
      );
    });

    testWidgets('a rematch answer clears lobbyClosesAt and the ask cooldown', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'closing cleared by rematch');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      await r.ask('ask_start_ok', <String, Object?>{
        'delivered': true,
        'next_in_s': 60,
      });
      expect(r.controller.askStartAvailableAt, isNotNull, reason: r.why);
      final Future<void> done = r.controller.rematch();
      await r.settle();
      r.seq += 1;
      r.transport.pushText(
        _frame(
          'room',
          _roomJson(seq: r.seq),
          re: _idOf(r.transport.sentRaw.last),
        ),
      );
      await r.settle();
      await done;
      expect(
        r.controller.lobbyClosesAt,
        isNull,
        reason: 'deadline kept. ${r.why}',
      );
      expect(
        r.controller.askStartAvailableAt,
        isNull,
        reason: 'cooldown kept after a rematch. ${r.why}',
      );
    });

    testWidgets('a full round (lobby, play, finish, rematch) carries no '
        'deadline or cooldown into the new lobby', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'closing across a full round');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      await r.ask('ask_start_ok', <String, Object?>{
        'delivered': true,
        'next_in_s': 60,
      });
      await r.pushRoom(state: 'PLAYING');
      await r.pushRoom(state: 'FINISHED');
      expect(r.controller.lobbyClosesAt, isNull, reason: r.why);
      final Future<void> done = r.controller.rematch();
      await r.settle();
      r.seq += 1;
      r.transport.pushText(
        _frame(
          'room',
          _roomJson(seq: r.seq),
          re: _idOf(r.transport.sentRaw.last),
        ),
      );
      await r.settle();
      await done;
      expect(r.controller.room?.state, RoomState.lobby, reason: r.why);
      expect(r.controller.lobbyClosesAt, isNull, reason: r.why);
      expect(r.controller.askStartAvailableAt, isNull, reason: r.why);
      expect(r.controller.canAskStart, isTrue, reason: r.why);
    });

    testWidgets('leave clears lobbyClosesAt and the ask cooldown', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'closing cleared by leave');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 120});
      await r.ask('ask_start_ok', <String, Object?>{
        'delivered': true,
        'next_in_s': 60,
      });
      final Future<bool> left = r.controller.leave();
      await r.settle();
      r.transport.pushText(
        _frame('ok', <String, Object?>{}, re: _idOf(r.transport.sentRaw.last)),
      );
      await r.settle();
      await left;
      expect(r.controller.lobbyClosesAt, isNull, reason: r.why);
      expect(r.controller.askStartAvailableAt, isNull, reason: r.why);
      expect(r.controller.canAskStart, isFalse, reason: r.why);
    });
  });

  group('ask_start', () {
    testWidgets('the request frame carries a type and an empty body, no '
        'other key', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'ask request has no keys');
      final (AskStartOutcome _, String raw) = await r.ask(
        'ask_start_ok',
        <String, Object?>{'delivered': true, 'next_in_s': 60},
      );
      final Map<String, Object?> f = _decode(raw);
      expect(f['t'], 'ask_start', reason: r.why);
      final Object? d = f['d'];
      expect(
        d == null || (d is Map && d.isEmpty),
        isTrue,
        reason:
            'ask_start d must carry no key (else BAD_FIELD); saw $d. '
            '${r.why}',
      );
      expect(
        f.keys.toSet().difference(<String>{'v', 't', 'id', 'd'}),
        isEmpty,
        reason: 'unexpected top-level keys in $raw. ${r.why}',
      );
    });

    testWidgets('ask_start_ok gives accepted, delivered and a +60 s '
        'cooldown', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'ask ok delivered');
      expect(
        r.controller.canAskStart,
        isTrue,
        reason: 'two seats, guest. ${r.why}',
      );
      final (AskStartOutcome o, String _) = await r.ask(
        'ask_start_ok',
        <String, Object?>{'delivered': true, 'next_in_s': 60},
      );
      expect(o.accepted, isTrue, reason: r.why);
      expect(o.delivered, isTrue, reason: r.why);
      expect(o.retryAfterS, isNull, reason: r.why);
      expect(o.errorCode, isNull, reason: r.why);
      expect(
        r.controller.askStartAvailableAt,
        r.clock.now.add(const Duration(seconds: 60)),
        reason: 'expected +60 s. ${r.why}',
      );
      expect(
        r.controller.canAskStart,
        isFalse,
        reason: 'inside cooldown. ${r.why}',
      );
    });

    testWidgets('ask_start_ok delivered false is still accepted and still '
        'starts the cooldown', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'ask ok not delivered');
      final (AskStartOutcome o, String _) = await r.ask(
        'ask_start_ok',
        <String, Object?>{'delivered': false, 'next_in_s': 60},
      );
      expect(o.accepted, isTrue, reason: r.why);
      expect(o.delivered, isFalse, reason: r.why);
      expect(
        r.controller.askStartAvailableAt,
        r.clock.now.add(const Duration(seconds: 60)),
        reason: r.why,
      );
    });

    testWidgets('next_in_s is honoured when it is not 60', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'ask ok next_in 45');
      await r.ask('ask_start_ok', <String, Object?>{
        'delivered': true,
        'next_in_s': 45,
      });
      expect(
        r.controller.askStartAvailableAt,
        r.clock.now.add(const Duration(seconds: 45)),
        reason: r.why,
      );
    });

    testWidgets('RATE_LIMITED with retry_after_s 41 gives retryAfterS 41 and '
        'availability +41 s', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'ask rate limited 41');
      final (AskStartOutcome o, String _) = await r.ask(
        'error',
        <String, Object?>{
          'code': 'RATE_LIMITED',
          'message': 'slow down',
          'retry_after_s': 41,
        },
      );
      expect(o.accepted, isFalse, reason: r.why);
      expect(o.delivered, isFalse, reason: r.why);
      expect(o.retryAfterS, 41, reason: r.why);
      expect(o.errorCode, 'RATE_LIMITED', reason: r.why);
      expect(
        r.controller.askStartAvailableAt,
        r.clock.now.add(const Duration(seconds: 41)),
        reason: r.why,
      );
      expect(r.controller.canAskStart, isFalse, reason: r.why);
      expect(
        r.controller.phase,
        RoomPhase.connected,
        reason: 'a refused ask must not fail the connection. ${r.why}',
      );
    });

    testWidgets('canAskStart turns true again exactly when the cooldown ends '
        'on the injected clock', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'ask cooldown boundary');
      await r.ask('ask_start_ok', <String, Object?>{
        'delivered': true,
        'next_in_s': 60,
      });
      r.clock.advance(const Duration(seconds: 59));
      expect(r.controller.canAskStart, isFalse, reason: 'at 59 s. ${r.why}');
      r.clock.advance(const Duration(seconds: 1));
      expect(r.controller.canAskStart, isTrue, reason: 'at 60 s. ${r.why}');
    });

    for (final String code in <String>[
      'NOT_ENOUGH_PLAYERS',
      'ROOM_STARTED',
      'BAD_FIELD',
      'NO_SUCH_ROOM',
    ]) {
      testWidgets('a $code refusal is an outcome with errorCode and no '
          'cooldown', (WidgetTester tester) async {
        final _Rig r = await _Rig.open(tester, 'ask refused $code');
        final (AskStartOutcome o, String _) = await r.ask(
          'error',
          <String, Object?>{'code': code, 'message': 'no'},
        );
        expect(o.accepted, isFalse, reason: r.why);
        expect(o.errorCode, code, reason: r.why);
        expect(o.retryAfterS, isNull, reason: r.why);
        expect(
          r.controller.askStartAvailableAt,
          isNull,
          reason:
              'a refusal other than RATE_LIMITED sets no cooldown. '
              '${r.why}',
        );
      });
    }

    testWidgets('the cooldown survives a reconnect of the same controller', (
      WidgetTester tester,
    ) async {
      final FakeTransport second = FakeTransport();
      final _Rig r = await _Rig.open(
        tester,
        'ask cooldown survives reconnect',
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        second: second,
      );
      await r.ask('ask_start_ok', <String, Object?>{
        'delivered': true,
        'next_in_s': 60,
      });
      final DateTime? before = r.controller.askStartAvailableAt;
      expect(before, isNotNull, reason: r.why);
      r.transport.endFromFarSide();
      await r.settle();
      await tester.pump(const Duration(milliseconds: 50));
      await r.settle();
      expect(
        second.sentRaw.map(_typeOf),
        contains('resume'),
        reason: 'fixture: reconnect must send resume. ${r.why}',
      );
      final String resumeId = _idOf(
        second.sentRaw.lastWhere((String s) => _typeOf(s) == 'resume'),
      );
      second.pushText(_frame('room', _roomJson(seq: 5), re: resumeId));
      await r.settle();
      expect(r.controller.phase, RoomPhase.connected, reason: r.why);
      expect(
        r.controller.askStartAvailableAt,
        before,
        reason: 'cooldown lost across reconnect. ${r.why}',
      );
      expect(r.controller.canAskStart, isFalse, reason: r.why);
    });

    testWidgets('canAskStart is false for the host', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'cannot ask as host', host: true);
      expect(r.controller.isHost, isTrue, reason: 'fixture. ${r.why}');
      expect(r.controller.canAskStart, isFalse, reason: r.why);
    });

    testWidgets('canAskStart is false with one occupied seat', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(
        tester,
        'cannot ask with one seat',
        seats: const <int>[1],
      );
      expect(r.controller.canAskStart, isFalse, reason: r.why);
    });

    testWidgets('canAskStart follows the seat count as seats arrive and go', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(
        tester,
        'ask follows seat count',
        seats: const <int>[1],
      );
      expect(r.controller.canAskStart, isFalse, reason: 'one seat. ${r.why}');
      await r.pushRoom(seats: <int>[0, 1]);
      expect(r.controller.canAskStart, isTrue, reason: 'two seats. ${r.why}');
      await r.pushRoom(seats: <int>[1]);
      expect(
        r.controller.canAskStart,
        isFalse,
        reason: 'back to one. ${r.why}',
      );
    });

    testWidgets('canAskStart is false outside the lobby', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'cannot ask while playing');
      await r.pushRoom(state: 'PLAYING');
      expect(r.controller.canAskStart, isFalse, reason: r.why);
    });

    testWidgets('a fresh controller offers nothing', (
      WidgetTester tester,
    ) async {
      final RoomController c = RoomController(
        serverUrl: Uri.parse('wss://c727.invalid/ws'),
        connect: (Uri _) async => FakeTransport(),
        autoReconnectDelays: const <Duration>[],
      );
      addTearDown(c.dispose);
      const String s = 'scenario "ask on idle controller"';
      expect(c.canAskStart, isFalse, reason: s);
      expect(c.lobbyClosesAt, isNull, reason: s);
      expect(c.askStartAvailableAt, isNull, reason: s);
      expect(c.lastStartAsked, isNull, reason: s);
      expect(c.lobbyTimedOut, isFalse, reason: s);
    });
  });

  group('start_asked', () {
    testWidgets('each start_asked frame bumps the serial, the same asker '
        'twice included', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'start_asked serial', host: true);
      expect(r.controller.lastStartAsked, isNull, reason: r.why);
      await r.push('start_asked', <String, Object?>{'seat': 1, 'name': 'Bob1'});
      final StartAsked? a = r.controller.lastStartAsked;
      expect(a, isNotNull, reason: r.why);
      expect(a!.seat, 1, reason: r.why);
      expect(a.name, 'Bob1', reason: r.why);
      final int s1 = a.serial;
      await r.push('start_asked', <String, Object?>{'seat': 1, 'name': 'Bob1'});
      final int s2 = r.controller.lastStartAsked!.serial;
      expect(s2, s1 + 1, reason: 'same asker twice must bump by one. ${r.why}');
      await r.push('start_asked', <String, Object?>{'seat': 2, 'name': 'Cy'});
      final StartAsked c = r.controller.lastStartAsked!;
      expect(c.serial, s2 + 1, reason: r.why);
      expect(c.seat, 2, reason: r.why);
      expect(c.name, 'Cy', reason: r.why);
    });

    testWidgets('start_asked notifies listeners on every frame', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(
        tester,
        'start_asked notifies',
        host: true,
      );
      int notes = 0;
      r.controller.addListener(() => notes += 1);
      await r.push('start_asked', <String, Object?>{'seat': 1, 'name': 'Bob1'});
      await r.push('start_asked', <String, Object?>{'seat': 1, 'name': 'Bob1'});
      expect(notes, greaterThanOrEqualTo(2), reason: 'saw $notes. ${r.why}');
    });

    testWidgets('start_asked changes nothing but lastStartAsked and sends '
        'nothing', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(
        tester,
        'start_asked changes only itself',
        host: true,
      );
      final RoomSnapshot? room = r.controller.room;
      final int sent = r.transport.sentRaw.length;
      await r.push('start_asked', <String, Object?>{'seat': 1, 'name': 'Bob1'});
      expect(r.controller.room, same(room), reason: r.why);
      expect(r.controller.phase, RoomPhase.connected, reason: r.why);
      expect(r.controller.errorCode, isNull, reason: r.why);
      expect(r.controller.lobbyClosesAt, isNull, reason: r.why);
      expect(r.controller.askStartAvailableAt, isNull, reason: r.why);
      expect(r.transport.sentRaw.length, sent, reason: r.why);
    });

    testWidgets('a start_asked without a usable name or seat never throws '
        'and the next valid one still counts', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(
        tester,
        'start_asked malformed',
        host: true,
      );
      await r.push('start_asked', <String, Object?>{'seat': 'x'});
      await r.push('start_asked', <String, Object?>{});
      expect(r.controller.phase, RoomPhase.connected, reason: r.why);
      await r.push('start_asked', <String, Object?>{'seat': 1, 'name': 'Bob1'});
      expect(r.controller.lastStartAsked?.name, 'Bob1', reason: r.why);
    });
  });

  group('room_closed', () {
    testWidgets('room_closed lobby_timeout sets lobbyTimedOut and detaches '
        'without an error code', (WidgetTester tester) async {
      final _Rig r = await _Rig.open(tester, 'room_closed lobby_timeout');
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 5});
      expect(r.controller.lobbyTimedOut, isFalse, reason: 'before. ${r.why}');
      await r.push('room_closed', <String, Object?>{'reason': 'lobby_timeout'});
      expect(r.controller.lobbyTimedOut, isTrue, reason: r.why);
      expect(
        r.controller.errorCode,
        isNull,
        reason: 'a lobby timeout is not an error. ${r.why}',
      );
      expect(
        r.controller.seatToken,
        isNull,
        reason: 'the seat token is dead after the close frame. ${r.why}',
      );
      expect(r.controller.phase, isNot(RoomPhase.failed), reason: r.why);
      expect(r.controller.lobbyClosesAt, isNull, reason: r.why);
      expect(r.controller.canAskStart, isFalse, reason: r.why);
    });

    testWidgets('after room_closed lobby_timeout a socket drop never tries '
        'to resume the dead seat', (WidgetTester tester) async {
      final FakeTransport second = FakeTransport();
      final _Rig r = await _Rig.open(
        tester,
        'room_closed then socket drop',
        reconnectDelays: const <Duration>[Duration(milliseconds: 10)],
        second: second,
      );
      await r.push('room_closed', <String, Object?>{'reason': 'lobby_timeout'});
      r.transport.endFromFarSide();
      await r.settle();
      await tester.pump(const Duration(milliseconds: 100));
      await r.settle();
      expect(
        second.sentRaw,
        isEmpty,
        reason: 'a resume was sent for a closed room. ${r.why}',
      );
      expect(r.controller.lobbyTimedOut, isTrue, reason: r.why);
    });

    testWidgets('room_closed lobby_timeout on a host controller too', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'room_closed host', host: true);
      await r.push('room_closed', <String, Object?>{'reason': 'lobby_timeout'});
      expect(r.controller.lobbyTimedOut, isTrue, reason: r.why);
      expect(r.controller.errorCode, isNull, reason: r.why);
    });

    for (final Map<String, Object?> data in <Map<String, Object?>>[
      <String, Object?>{'reason': 'idle'},
      <String, Object?>{'reason': 'LOBBY_TIMEOUT'},
      <String, Object?>{'reason': ''},
      <String, Object?>{'reason': 7},
      <String, Object?>{},
    ]) {
      testWidgets('room_closed ${jsonEncode(data)} does not set '
          'lobbyTimedOut', (WidgetTester tester) async {
        final _Rig r = await _Rig.open(
          tester,
          'room_closed other ${jsonEncode(data)}',
        );
        await r.push('room_closed', data);
        expect(
          r.controller.lobbyTimedOut,
          isFalse,
          reason: 'only lobby_timeout is a lobby timeout. ${r.why}',
        );
      });
    }

    testWidgets('lobbyTimedOut stays false through ordinary traffic', (
      WidgetTester tester,
    ) async {
      final _Rig r = await _Rig.open(tester, 'timed out stays false');
      await r.pushRoom();
      await r.push('lobby_closing', <String, Object?>{'closes_in_s': 100});
      await r.pushRoom(state: 'PLAYING');
      expect(r.controller.lobbyTimedOut, isFalse, reason: r.why);
    });
  });
}
