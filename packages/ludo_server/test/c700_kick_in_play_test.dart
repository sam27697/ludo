// Order C-700t: docs/PROTOCOL.md section 33 item 8 (the host's kick in
// PLAYING, replacing section 28 item 4's `kicked` case) and the PLAYING bar of
// item 7, written from the section alone against a real WireServer on real
// sockets with a fake clock. The ruleset is 2026-11 unless a row says
// otherwise.
//
// Every scenario has its own server and FakeClock. Where a row needs a seat
// on turn or a seat about to finish, the engine state is rewritten in place
// (`forceTurn`), as c652_ruleset_2026_11_test.dart does; no assertion depends
// on a die face. Readings this file pins where the section leaves a choice
// are marked AMBIGUITY and listed in the order's report.

import 'package:test/test.dart';

import 'support/c700_harness.dart';

const String _file = 'test/c700_kick_in_play_test.dart';

void _s(String name, Future<void> Function(C700Rig r) body,
        {String ruleset = '2026-11'}) =>
    c700Scenario(_file, name, body, ruleset: ruleset);

class _Table {
  _Table(this.host, this.guests);

  final Held host;
  final Map<int, Held> guests;

  List<C700Client> get all =>
      <C700Client>[host.c, for (final Held g in guests.values) g.c];
}

/// A room of [players] seats (`open` left out), every guest joined by link,
/// started.
Future<_Table> _table(C700Rig r, int players, {bool? open}) async {
  final Held h = await r.host(open: open, players: players);
  final Map<int, Held> guests = <int, Held>{};
  for (int i = 1; i < players; i++) {
    final Held g = await r
        .join(<String, Object?>{'link': h.linkId}, r.dev('g$i'), name: 'G$i');
    guests[g.seat] = g;
  }
  for (final C700Client c in <C700Client>[
    h.c,
    for (final Held g in guests.values) g.c
  ]) {
    await c.sync();
  }
  await r.start(h, <C700Client>[h.c, for (final Held g in guests.values) g.c]);
  return _Table(h, guests);
}

void _retired(
  Map<String, Object?> f, {
  required int seat,
  required int hostSeat,
  required String? re,
  required String row,
  required String who,
}) {
  expect(f['t'], 'seat_retired',
      reason: '$row: item 8: $who expected seat_retired, got ${fdesc(f)}');
  final Map<String, Object?> d = fd(f);
  expect(d.keys.toSet(), <String>{'seat', 'reason', 'host_seat', 'seq'},
      reason: '$row: $who: seat_retired keys; got ${fdesc(f)}');
  expect(<Object?>[d['seat'], d['reason'], d['host_seat']],
      <Object?>[seat, 'kicked', hostSeat],
      reason: '$row: $who: seat_retired {seat $seat, reason kicked, '
          'host_seat $hostSeat}; got ${fdesc(f)}');
  expect(d['seq'], isA<int>(), reason: '$row: $who: seq');
  expect(f['re'], re,
      reason: '$row: $who: re expected ${re ?? 'absent'}; got ${fdesc(f)}');
}

/// The kicked socket's frames: exactly seat_retired then kicked { }.
Future<void> _kickedFrames(
    C700Client c, int seat, int hostSeat, String row) async {
  final List<Map<String, Object?>> got = await c.sync();
  expect(ftypes(got), <String>['seat_retired', 'kicked'],
      reason: '$row: item 8: the kicked socket gets seat_retired, then kicked '
          '{ }, and nothing after (it holds no seat); got ${fdescAll(got)}');
  _retired(got[0],
      seat: seat,
      hostSeat: hostSeat,
      re: null,
      row: row,
      who: 'the kicked socket');
  expect(fd(got[1]), <String, Object?>{},
      reason: '$row: item 8: kicked carries { } (no seq, no ban without a '
          'ban); got ${fdesc(got[1])}');
  expect(got[1]['re'], isNull, reason: '$row: kicked carries no re');
}

Future<void> _deadToken(
    C700Rig r, String code, String token, String row) async {
  final C700Client c = await r.open(r.freshIp(), 'dead-token');
  c.send('resume', <String, Object?>{'code': code, 'seat_token': token});
  expectError(await c.next(), 'BAD_SEAT_TOKEN',
      '$row: item 8: resume with the kicked seat\'s token');
}

/// The error a socket holding no seat gets for [type].
Future<String> _seatless(C700Rig r, String type) async {
  final C700Client c = await r.open(r.freshIp(), 'seatless');
  c.send(type, <String, Object?>{});
  final Map<String, Object?> f = await c.next();
  return f['t'] == 'error' ? fd(f)['code']! as String : '${f['t']}';
}

Future<void> _quietAll(List<C700Client> cs, String row, String what) async {
  for (final C700Client c in cs) {
    final List<Map<String, Object?>> got = await c.sync();
    expect(got, isEmpty,
        reason: '$row: $what: expected no frame on ${c.label}; got '
            '${fdescAll(got)}');
  }
}

void main() {
  group('item 8: accepted kicks', () {
    _s(
        'K1 the host kicks a connected seat that is not on turn: frames, the '
        'kicked socket, the dead token', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 0);
      final Held target = t.guests[1]!;
      final Held other = t.guests[2]!;
      final String id =
          t.host.c.send('kick', <String, Object?>{'seat': target.seat});
      final List<Map<String, Object?>> hf = await t.host.c.sync();
      expect(ftypes(hf), <String>['seat_retired'],
          reason: 'K1: item 8: a connected seat is kicked (NOT_ABSENT is no '
              'longer sent); the seat was not on turn so nothing follows; '
              'got ${fdescAll(hf)}');
      _retired(hf.single,
          seat: 1, hostSeat: 0, re: id, row: 'K1', who: 'the host');
      final List<Map<String, Object?>> of = await other.c.sync();
      expect(ftypes(of), <String>['seat_retired'],
          reason: 'K1: the other seat; got ${fdescAll(of)}');
      _retired(of.single,
          seat: 1, hostSeat: 0, re: null, row: 'K1', who: 'the other seat');
      expect(fd(of.single)['seq'], fd(hf.single)['seq'],
          reason: 'K1: one broadcast, one seq');
      await _kickedFrames(target.c, 1, 0, 'K1');

      final String want = await _seatless(r, 'roll');
      target.c.send('roll', <String, Object?>{});
      final Map<String, Object?> rf = await target.c.next();
      expect(rf['t'] == 'error' ? fd(rf)['code'] : rf['t'], want,
          reason: 'K1: item 8: the kicked socket holds no seat, so roll '
              'answers as from a seatless socket ($want); got ${fdesc(rf)}');
      await _deadToken(r, t.host.code, target.token, 'K1');
      await _quietAll(<C700Client>[t.host.c, other.c], 'K1',
          'a refused resume changes nothing');
    });

    _s(
        'K2 the host kicks the seat on turn: seat_retired, then turn for the '
        'next playing seat; the kicked socket gets no turn', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 1);
      final String id = t.host.c.send('kick', <String, Object?>{'seat': 1});
      final List<Map<String, Object?>> hf = await t.host.c.sync();
      expect(ftypes(hf), <String>['seat_retired', 'turn'],
          reason: 'K2: section 28 item 4 follows a retire of the seat on '
              'turn with turn for the next playing seat; got ${fdescAll(hf)}');
      _retired(hf[0], seat: 1, hostSeat: 0, re: id, row: 'K2', who: 'host');
      expect(fd(hf[1])['seat'], 2, reason: 'K2: the next playing seat is 2');
      final List<Map<String, Object?>> of = await t.guests[2]!.c.sync();
      expect(ftypes(of), <String>['seat_retired', 'turn'],
          reason: 'K2: seat 2; got ${fdescAll(of)}');
      await _kickedFrames(t.guests[1]!.c, 1, 0, 'K2');
    });

    _s('K3 the host kicks a dropped seat', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 0);
      final Held target = t.guests[2]!;
      await target.c.close();
      final Map<String, Object?> pres = await t.host.c.untilType('presence');
      expect(fd(pres)['connected'], false, reason: 'K3: fixture presence');
      await t.guests[1]!.c.untilType('presence');
      final String id = t.host.c.send('kick', <String, Object?>{'seat': 2});
      final List<Map<String, Object?>> hf = await t.host.c.sync();
      expect(ftypes(hf), <String>['seat_retired'],
          reason: 'K3: a dropped seat is kicked; got ${fdescAll(hf)}');
      _retired(hf.single, seat: 2, hostSeat: 0, re: id, row: 'K3', who: 'host');
      await _deadToken(r, t.host.code, target.token, 'K3');
    });

    _s('K4 with three seats the game goes on after a kick', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 0);
      t.host.c.send('kick', <String, Object?>{'seat': 1});
      final List<Map<String, Object?>> hk = await t.host.c.sync();
      expect(ftypes(hk), <String>['seat_retired'],
          reason: 'K4: item 8: the kick of connected seat 1 is accepted; got '
              '${fdescAll(hk)}');
      await t.guests[2]!.c.sync();
      await t.guests[1]!.c.sync();
      // Seat 0 rolls; whatever the face, the game goes on and no turn ever
      // names the kicked seat.
      for (int round = 0; round < 3; round++) {
        forceTurn(r, t.host.code, seat: round.isEven ? 0 : 2);
        final Held actor = round.isEven ? t.host : t.guests[2]!;
        actor.c.send('roll', <String, Object?>{});
        final List<Map<String, Object?>> got = await actor.c.sync();
        expect(got.isNotEmpty && got.first['t'] == 'rolled', isTrue,
            reason: 'K4: item 8: after the kick the game goes on: seat '
                '${actor.seat} rolls; got ${fdescAll(got)}');
        for (final Map<String, Object?> f in got) {
          expect(f['t'] == 'turn' && fd(f)['seat'] == 1, isFalse,
              reason: 'K4: the kicked seat is never on turn; got '
                  '${fdescAll(got)}');
          expect(f['t'], isNot('game_over'),
              reason: 'K4: two playing seats remain; got ${fdescAll(got)}');
        }
        await (round.isEven ? t.guests[2]! : t.host).c.sync();
      }
    });

    _s(
        'K5 with two seats the kick ends the game: game_over, then '
        'player_left for the kicked seat', (C700Rig r) async {
      final _Table t = await _table(r, 2);
      forceTurn(r, t.host.code, seat: 0);
      final String id = t.host.c.send('kick', <String, Object?>{'seat': 2});
      final List<Map<String, Object?>> hf = await t.host.c.sync();
      expect(ftypes(hf), <String>['seat_retired', 'game_over', 'player_left'],
          reason: 'K5: section 28 item 4: one playing seat left ends the '
              'game and frees the retired seat; got ${fdescAll(hf)}');
      _retired(hf[0], seat: 2, hostSeat: 0, re: id, row: 'K5', who: 'host');
      expect(<Object?>[
        fd(hf[1])['winner'],
        fd(hf[1])['placings'],
        fd(hf[1])['retired'],
      ], <Object?>[
        0,
        <int>[0],
        <int>[2],
      ],
          reason:
              'K5: game_over winner, placings, retired; got ${fdesc(hf[1])}');
      expect(
          <Object?>[fd(hf[2])['seat'], fd(hf[2])['host_seat']], <Object?>[2, 0],
          reason: 'K5: player_left for the kicked seat; got ${fdesc(hf[2])}');
      await _kickedFrames(t.guests[2]!.c, 2, 0, 'K5');
    });

    _s('K6 the kicked seat stays in seats until game_over frees it',
        (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 0);
      t.host.c.send('kick', <String, Object?>{'seat': 1});
      await t.host.c.sync();
      await t.guests[1]!.c.sync();
      await t.guests[2]!.c.sync();
      final Map<String, Object?> snap =
          await resumeRoom(r, t.host.code, t.guests[2]!.token, 'watch');
      expect(seatNumbers(snap), <int>[0, 1, 2],
          reason: 'K6: item 8: the kicked seat stays in seats; got '
              '${snap['seats']}');
      expect(snap['retired'], <int>[1], reason: 'K6: snapshot retired');
      final C700Client watcher = r.clients.last;
      forceTurn(r, t.host.code, seat: 0, queue: <int>[
        3
      ], tokens: <int, List<int>>{
        0: <int>[57, 57, 57, 54],
      });
      t.host.c.send('move', <String, Object?>{'token': 3});
      final List<Map<String, Object?>> hf = await t.host.c.sync();
      expect(ftypes(hf), <String>['moved', 'game_over', 'player_left'],
          reason: 'K6: seat 0 finishes, one playing seat is left, the game '
              'ends and the kicked seat is freed; got ${fdescAll(hf)}');
      expect(fd(hf[2])['seat'], 1, reason: 'K6: player_left seat 1');
      await watcher.sync();
    });
  });

  group('item 8: refused kicks', () {
    _s('K7 the host kicking its own seat is ILLEGAL_MOVE', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      t.host.c.send('kick', <String, Object?>{'seat': 0});
      expectError(await t.host.c.next(), 'ILLEGAL_MOVE',
          'K7: item 8: the host\'s own seat');
      await _quietAll(t.all, 'K7', 'a refused kick');
    });

    _s('K8 kick of a finished seat is ILLEGAL_MOVE', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 1, queue: <int>[
        3
      ], tokens: <int, List<int>>{
        1: <int>[57, 57, 57, 54],
      });
      t.guests[1]!.c.send('move', <String, Object?>{'token': 3});
      final List<Map<String, Object?>> got = await t.guests[1]!.c.sync();
      expect(ftypes(got).contains('seat_finished'), isTrue,
          reason: 'K8: fixture: seat 1 finishes; got ${fdescAll(got)}');
      await t.host.c.sync();
      await t.guests[2]!.c.sync();
      t.host.c.send('kick', <String, Object?>{'seat': 1});
      expectError(await t.host.c.next(), 'ILLEGAL_MOVE',
          'K8: item 8: a finished seat (connected)');
      await _quietAll(t.all, 'K8', 'a refused kick');
    });

    _s('K9 kick of a retired seat and of an empty seat is ILLEGAL_MOVE',
        (C700Rig r) async {
      final _Table t = await _table(r, 3);
      forceTurn(r, t.host.code, seat: 0);
      t.guests[2]!.c.send('leave_room', <String, Object?>{});
      await t.guests[2]!.c.sync();
      await t.host.c.sync();
      await t.guests[1]!.c.sync();
      t.host.c.send('kick', <String, Object?>{'seat': 2});
      expectError(
          await t.host.c.next(), 'ILLEGAL_MOVE', 'K9: item 8: a retired seat');
      t.host.c.send('kick', <String, Object?>{'seat': 3});
      expectError(await t.host.c.next(), 'ILLEGAL_MOVE',
          'K9: item 8: an empty seat (3 of a three-seat room)');
      await _quietAll(
          <C700Client>[t.host.c, t.guests[1]!.c], 'K9', 'refused kicks');
    });

    _s(
        'K10 the ladder in PLAYING: NOT_HOST, then BAD_FIELD, then '
        'ILLEGAL_MOVE; NOT_ABSENT is never sent', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      final C700Client guest = t.guests[1]!.c;
      for (final Map<String, Object?> d in <Map<String, Object?>>[
        <String, Object?>{'seat': 'x'},
        <String, Object?>{'seat': 2},
        <String, Object?>{'seat': 0},
      ]) {
        guest.send('kick', d);
        expectError(await guest.next(), 'NOT_HOST',
            'K10: item 8: kick $d by a non-host');
      }
      for (final Map<String, Object?> d in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'seat': 'x'},
        <String, Object?>{'seat': 4},
        <String, Object?>{'seat': -1},
        <String, Object?>{'seat': 1.5},
        <String, Object?>{'seat': null},
        <String, Object?>{'seat': 2, 'extra': 1},
      ]) {
        t.host.c.send('kick', d);
        expectError(await t.host.c.next(), 'BAD_FIELD',
            'K10: item 8: kick $d by the host');
      }
      t.host.c.send('kick', <String, Object?>{'seat': 0});
      expectError(await t.host.c.next(), 'ILLEGAL_MOVE',
          'K10: item 8: the host\'s own seat after the payload checks');
      await _quietAll(t.all, 'K10', 'refused kicks');
    });

    _s('K11 under 2026-10 the PLAYING kick stays BAD_TYPE', (C700Rig r) async {
      final _Table t = await _table(r, 3);
      t.host.c.send('kick', <String, Object?>{'seat': 1});
      expectError(await t.host.c.next(), 'BAD_TYPE',
          'K11: item 8: a PLAYING kick of a connected seat under 2026-10');
      await _quietAll(t.all, 'K11', 'nothing changed');
    }, ruleset: '2026-10');
  });

  group('item 7: the PLAYING kick bars', () {
    _s(
        'K12 the kicked device is barred by link, by code and from the line '
        'after the game', (C700Rig r) async {
      final Held h = await r.host(open: true, players: 2);
      final Dev x = r.dev('x');
      final Held xs =
          await r.join(<String, Object?>{'link': h.linkId}, x, name: 'X');
      await h.c.sync();
      await r.start(h, <C700Client>[h.c, xs.c]);
      forceTurn(r, h.code, seat: 0);
      h.c.send('kick', <String, Object?>{'seat': xs.seat});
      await _kickedFrames(xs.c, xs.seat, 0, 'K12');
      await h.c.sync();
      h.c.send('rematch', <String, Object?>{});
      final Map<String, Object?> lobby = await h.c.untilType('room');
      expect(fd(lobby)['state'], 'LOBBY',
          reason: 'K12: fixture: the rematch reopens the room with a free '
              'seat; got ${fdesc(lobby)}');

      final Dev again = Dev('x-again', x.install, r.freshIp());
      for (final Map<String, Object?> key in <Map<String, Object?>>[
        <String, Object?>{'link': h.linkId},
        <String, Object?>{'code': h.code},
      ]) {
        final C700Client c = await r.open(again.ip, 'rejoin');
        c.send('join_room', <String, Object?>{
          ...key,
          'name': 'X',
          'install': x.install,
        });
        expectError(await c.next(), 'KICKED',
            'K12: item 7: a PLAYING kick bars as a lobby kick: rejoin by $key');
      }
      final (C700Client q, String _) =
          await r.queue(again, 1, name: 'X', row: 'K12 from the line');
      final List<Map<String, Object?>> hq = await h.c.sync();
      expect(hq, isEmpty,
          reason: 'K12: item 7: the kicked device is never seated from the '
              'line in that room; got ${fdescAll(hq)}');
      q.send('cancel_find', <String, Object?>{});
      expect((await q.next())['t'], 'find_cancelled', reason: 'K12: fixture');
      final Held y = await r.findSeat(r.dev('y'), row: 'K12 control');
      expect(y.code, h.code,
          reason: 'K12: control: the room is matchable for anyone else');
    });
  });
}
