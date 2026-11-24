// Order C-700t: docs/PROTOCOL.md section 33 items 1 to 5 and 7 (open rooms,
// matchable rooms, find_game, the waiting line, the public route, bars from
// the line), written from the section alone against a real WireServer on
// real sockets with a fake clock. Item 6 is c700_route_strikes_test.dart,
// item 8 is c700_kick_in_play_test.dart.
//
// Every scenario has its own server, FakeClock and fresh IPs and installs;
// nothing depends on a seed or on dice. A failure names its row, what was
// expected, what came, and the command that re-runs it.
//
// Readings this file pins where the section leaves a choice are marked
// AMBIGUITY and listed in the order's report.

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/c700_harness.dart';

const String _file = 'test/c700_open_rooms_line_test.dart';

void _s(String name, Future<void> Function(C700Rig r) body,
        {Timeout? timeout}) =>
    c700Scenario(_file, name, body, timeout: timeout);

/// Forces [code] to FINISHED without a game_over, as c680's R1 does, so a
/// rematch can be asked for without playing a game out.
void _forceFinished(C700Rig r, String code, {required int winner}) {
  final Room room = r.registry.lookup(code)!;
  final engine.GameState base = room.game!;
  room.game = engine.GameState(
    config: base.config,
    tokens: base.tokens,
    currentSeat: winner,
    phase: engine.GamePhase.finished,
    roll: null,
    sixes: 0,
    winner: winner,
    seq: base.seq + 1,
    rngState: base.rngState,
  );
  room.state = RoomState.finished;
}

Future<void> _quiet(C700Client c, String row, String what) async {
  final List<Map<String, Object?>> got = await c.sync();
  expect(got, isEmpty,
      reason: '$row: $what: expected no frame; got ${fdescAll(got)}');
}

void main() {
  group('item 1: an open room', () {
    Future<void> openCase(C700Rig r, bool? open, String row) async {
      final bool want = open ?? false;
      final Held h = await r.host(open: open, players: 3);
      expect(h.room['open'], want,
          reason: '$row: item 1: create_room with open=${open ?? 'absent'}: '
              'the create answer snapshot must carry open=$want; got '
              'open=${h.room['open']} (key present: '
              '${h.room.containsKey('open')})');
      final Held g =
          await r.join(<String, Object?>{'link': h.linkId}, r.dev('g'));
      expect(g.room['open'], want,
          reason: '$row: item 1: the joiner\'s snapshot carries open=$want; '
              'got ${g.room['open']}');
      final Map<String, Object?> snap =
          await resumeRoom(r, h.code, h.token, 'resume');
      expect(snap['open'], want,
          reason: '$row: item 1: a resume snapshot carries open=$want; got '
              '${snap['open']}');
    }

    _s('O1 open absent is false in every snapshot',
        (C700Rig r) => openCase(r, null, 'O1'));
    _s('O2 open true is true in every snapshot',
        (C700Rig r) => openCase(r, true, 'O2'));
    _s('O3 open false is false in every snapshot',
        (C700Rig r) => openCase(r, false, 'O3'));

    _s('O4 open that is not a bool is BAD_FIELD and creates no room',
        (C700Rig r) async {
      // AMBIGUITY: an explicit null is "not a bool", so BAD_FIELD, as an
      // explicit null rules is in section 4.
      for (final Object? bad in <Object?>[
        'true',
        1,
        0,
        null,
        <Object?>[],
        <String, Object?>{},
      ]) {
        final C700Client c = await r.open(r.freshIp(), 'bad');
        c.send('create_room',
            <String, Object?>{'name': 'H', 'players': 4, 'open': bad});
        expectError(await c.next(), 'BAD_FIELD',
            'O4: item 1: create_room with open=$bad (${bad.runtimeType})');
      }
      expect(r.registry.roomCount, 0,
          reason: 'O4: no refused create_room may leave a room behind');
    });

    _s('O5 a rematch keeps open, true and false', (C700Rig r) async {
      for (final bool open in <bool>[true, false]) {
        final Held h = await r.host(open: open, players: 2);
        final Held g =
            await r.join(<String, Object?>{'link': h.linkId}, r.dev('g$open'));
        await h.c.sync();
        await r.start(h, <C700Client>[h.c, g.c]);
        _forceFinished(r, h.code, winner: 0);
        final String id = h.c.send('rematch', <String, Object?>{});
        final Map<String, Object?> lobby = await h.c.untilType('room');
        expect(lobby['re'], id, reason: 'O5: the rematch answer');
        expect(fd(lobby)['state'], isNot('FINISHED'),
            reason: 'O5: fixture: the rematch reopened the room');
        expect(fd(lobby)['open'], open,
            reason: 'O5: item 1: open=$open is unchanged by a rematch (the '
                'rematch LOBBY snapshot); got ${fd(lobby)['open']}');
        await g.c.sync();
        g.c.send('rematch', <String, Object?>{});
        await g.c.sync();
        await h.c.sync();
        final Map<String, Object?> snap =
            await resumeRoom(r, h.code, h.token, 'after-rematch');
        expect(snap['open'], open,
            reason: 'O5: item 1: open=$open after the rematch started; got '
                '${snap['open']}');
      }
    });
  });

  group('items 2, 3 and 5: matchable rooms and find_game', () {
    _s(
        'F1 find_game seats at once in the oldest matchable room on its '
        'lowest free seat, via public', (C700Rig r) async {
      final Held a = await r.host(open: true, players: 4, name: 'A');
      final Held b = await r.host(open: true, players: 4, name: 'B');
      final Held s = await r.findSeat(r.dev('s'), name: 'Sami', row: 'F1');
      expect(s.code, a.code,
          reason: 'F1: item 2: rooms are ordered by creation, oldest first; '
              'expected room ${a.code}, seated in ${s.code}');
      expect(s.seat, 1, reason: 'F1: item 3: the lowest free seat is 1');
      expect(s.room['open'], true, reason: 'F1: snapshot open');
      expect(seatOf(s.room, 1)['via'], 'public',
          reason: 'F1: item 5: a seat given by find_game has via "public"; '
              'got ${seatOf(s.room, 1)}');
      expect(seatOf(s.room, 1)['name'], 'Sami', reason: 'F1: name');
      final List<Map<String, Object?>> ha = await a.c.sync();
      expect(ftypes(ha), <String>['player_joined'],
          reason: 'F1: item 3: the room gets player_joined, as a link join; '
              'got ${fdescAll(ha)}');
      expect(fd(ha.single)['seat'], 1, reason: 'F1: player_joined.seat');
      expect(fd(ha.single)['name'], 'Sami', reason: 'F1: player_joined.name');
      expect(fd(ha.single)['seq'], isA<int>(), reason: 'F1: player_joined.seq');
      await _quiet(b.c, 'F1', 'the younger open room');
    });

    Future<List<Held>> notMatchable(C700Rig r) async {
      final Held friends = await r.host(open: false, players: 4, name: 'Fr');
      final Held playing = await r.host(open: true, players: 2, name: 'Pl');
      final Held pg =
          await r.join(<String, Object?>{'link': playing.linkId}, r.dev('pg'));
      await playing.c.sync();
      await r.start(playing, <C700Client>[playing.c, pg.c]);
      final Held full = await r.host(open: true, players: 2, name: 'Fu');
      await r.join(<String, Object?>{'link': full.linkId}, r.dev('fg'));
      await full.c.sync();
      final Held down = await r.host(open: true, players: 4, name: 'Dn');
      await down.c.close();
      await r.untilDown(down.code, 0);
      return <Held>[friends, playing, full, down];
    }

    void untouched(C700Rig r, List<Held> rooms, String row) {
      final List<int> want = <int>[1, 2, 2, 1];
      for (int i = 0; i < rooms.length; i++) {
        expect(r.registry.lookup(rooms[i].code)!.seats.length, want[i],
            reason: '$row: room ${rooms[i].code} (friends-only, PLAYING, '
                'full, host down: #$i) must not gain a seat');
      }
    }

    _s(
        'F2 find_game skips a friends-only room, a PLAYING room, a full room '
        'and a room whose host socket is down', (C700Rig r) async {
      final List<Held> skip = await notMatchable(r);
      final Held e = await r.host(open: true, players: 4, name: 'E');
      final Held s = await r.findSeat(r.dev('s'), row: 'F2');
      expect(s.code, e.code,
          reason: 'F2: item 2: the only matchable room is ${e.code} (the '
              'four older rooms are not matchable); seated in ${s.code}');
      expect(s.seat, 1, reason: 'F2: lowest free seat');
      untouched(r, skip, 'F2');
    });

    _s(
        'F3 with no matchable room the caller is queued at 1, and a new open '
        'room seats it from the line', (C700Rig r) async {
      final List<Held> skip = await notMatchable(r);
      final (C700Client c, String _) = await r.queue(r.dev('s'), 1, row: 'F3');
      await _quiet(c, 'F3', 'a lone ticket with no matchable room');
      final Held e = await r.host(open: true, players: 4, name: 'E');
      final Held s = await expectSeatedFromLine(c,
          row: 'F3',
          what: 'item 4: a create makes a room matchable',
          code: e.code,
          seat: 1);
      expect(seatOf(s.room, 1)['via'], 'public',
          reason: 'F3: item 5: a seat from the line has via public');
      final List<Map<String, Object?>> he = await e.c.sync();
      expect(ftypes(he), <String>['player_joined'],
          reason: 'F3: the room gets player_joined; got ${fdescAll(he)}');
      untouched(r, skip, 'F3');
    });

    _s(
        'F4 find_game skips a room holding a computer seat (needs section 34 '
        'play_computer)', (C700Rig r) async {
      final C700Client pc = await r.open(r.freshIp(), 'pc');
      pc.send('play_computer', <String, Object?>{'name': 'Solo', 'players': 2});
      final Map<String, Object?> f = await pc.next();
      if (f['t'] != 'seat_assigned') {
        fail('F4: fixture: play_computer (section 34 item 2) must seat the '
            'caller to build a room with a computer seat; got ${fdesc(f)}');
      }
      await pc.sync();
      final int rooms = r.registry.roomCount;
      final (C700Client c, String _) = await r.queue(r.dev('s'), 1, row: 'F4');
      await _quiet(c, 'F4', 'the only room holds a computer seat');
      await _quiet(pc, 'F4', 'the computer room');
      expect(r.registry.roomCount, rooms,
          reason: 'F4: a lone ticket makes no room');
    });

    _s('F5 via public on that seat, after its resume and after a rematch',
        (C700Rig r) async {
      final Held h = await r.host(open: true, players: 2);
      final Held s = await r.findSeat(r.dev('s'), row: 'F5');
      expect(s.seat, 2,
          reason: 'F5: a two-seat room\'s seats are 0 and 2 (section 15)');
      expect(seatOf(s.room, 2)['via'], 'public', reason: 'F5: item 5');
      expect(seatOf(s.room, 0)['via'], 'host', reason: 'F5: the host');
      Map<String, Object?> snap =
          await resumeRoom(r, h.code, s.token, 'resume-public');
      expect(seatOf(snap, 2)['via'], 'public',
          reason: 'F5: item 5: a seat keeps via public across a resume; got '
              '${seatOf(snap, 2)}');
      final C700Client sc = r.clients.last;
      await h.c.sync();
      await r.start(h, <C700Client>[h.c, sc]);
      _forceFinished(r, h.code, winner: 0);
      h.c.send('rematch', <String, Object?>{});
      await h.c.untilType('room');
      await sc.sync();
      sc.send('rematch', <String, Object?>{});
      await sc.sync();
      await h.c.sync();
      snap = await resumeRoom(r, h.code, h.token, 'after-rematch');
      expect(seatOf(snap, 2)['via'], 'public',
          reason: 'F5: item 5: a seat keeps via public across a rematch; got '
              '${seatOf(snap, 2)}');
    });

    _s(
        'F6 find_game without install, with a malformed install or a bad '
        'name is BAD_FIELD and leaves no ticket', (C700Rig r) async {
      final Map<String, Map<String, Object?>> cases =
          <String, Map<String, Object?>>{
        'install missing': <String, Object?>{'name': 'S'},
        'install too short': <String, Object?>{'name': 'S', 'install': 'short'},
        'install not a string': <String, Object?>{'name': 'S', 'install': 7},
        'install of 65 characters': <String, Object?>{
          'name': 'S',
          'install': 'a' * 65
        },
        'install with a space': <String, Object?>{
          'name': 'S',
          'install': 'has space 0123456789'
        },
        'install null': <String, Object?>{'name': 'S', 'install': null},
        'name missing': <String, Object?>{'install': 'install_ok_0123456789'},
        'name empty': <String, Object?>{
          'name': '',
          'install': 'install_ok_0123456789'
        },
        'name of 25 characters': <String, Object?>{
          'name': 'n' * 25,
          'install': 'install_ok_0123456789'
        },
      };
      for (final MapEntry<String, Map<String, Object?>> e in cases.entries) {
        final C700Client c = await r.open(r.freshIp(), 'bad');
        c.send('find_game', e.value);
        expectError(
            await c.next(), 'BAD_FIELD', 'F6: item 3: find_game with ${e.key}');
      }
      final (C700Client _, String _) =
          await r.queue(r.dev('ok'), 1, row: 'F6 (control)');
      expect(r.registry.roomCount, 0,
          reason: 'F6: a refused find_game left a ticket behind (a room was '
              'made for two strangers)');
    });

    _s('F7 find_game from a seated socket is ALREADY_SEATED and changes nothing',
        (C700Rig r) async {
      final Held open = await r.host(open: true, players: 4, name: 'Open');
      final Held friends = await r.host(open: false, players: 4, name: 'Fr');
      final Held guest = await r.join(
          <String, Object?>{'link': friends.linkId}, r.dev('g'),
          name: 'G');
      await friends.c.sync();
      for (final (String who, Held h) in <(String, Held)>[
        ('the host of a friends-only room', friends),
        ('a guest seated by link', guest),
        ('the host of an open room', open),
      ]) {
        final String id = h.c.send('find_game', <String, Object?>{
          'name': 'Again',
          'install': r.freshInstall('seated'),
        });
        final Map<String, Object?> f = await h.c.next();
        expectError(f, 'ALREADY_SEATED', 'F7: item 3: find_game from $who');
        expect(f['re'], id, reason: 'F7: the error answers the find_game');
      }
      await _quiet(open.c, 'F7', 'the open room after refused find_games');
      await _quiet(friends.c, 'F7', 'the friends-only room');
      expect(r.registry.lookup(open.code)!.seats.length, 1,
          reason: 'F7: nobody was seated in the open room');
      expect(r.registry.lookup(friends.code)!.seats.length, 2,
          reason: 'F7: the friends-only room keeps both seats');
    });

    _s('F8 find_game closes the caller\'s open knock withdrawn first',
        (C700Rig r) async {
      final Held h = await r.host(players: 4, approval: true);
      final Dev k = r.dev('k');
      final C700Client c = await r.open(k.ip, 'knocker');
      c.send('join_room', <String, Object?>{
        'code': h.code,
        'name': 'K',
        'install': k.install,
      });
      expect((await c.next())['t'], 'knock_pending', reason: 'F8: fixture');
      final Map<String, Object?> knock = await h.c.untilType('knock');
      final String id = c.send('find_game', <String, Object?>{
        'name': 'K',
        'install': k.install,
      });
      // The knocker's frames before queued are not pinned; queued is last.
      final List<Map<String, Object?>> kf = await c.sync();
      if (kf.isEmpty) {
        fail('F8: find_game from a knocking socket was not answered');
      }
      expectQueued(kf.last,
          position: 1, re: id, row: 'F8', what: 'find_game after the knock');
      final Map<String, Object?> closed = await h.c.untilType('knock_closed');
      expect(fd(closed)['knock_id'], fd(knock)['knock_id'],
          reason: 'F8: knock_closed names the knock');
      expect(fd(closed)['outcome'], 'withdrawn',
          reason: 'F8: item 3: find_game closes an open knock withdrawn '
              '(section 31 item 12a); got ${fdesc(closed)}');
    });

    _s('F9 the 21st find_game in one minute from one IP is RATE_LIMITED',
        (C700Rig r) async {
      final String ip = r.freshIp();
      for (int i = 1; i <= 20; i++) {
        final (C700Client _, String _, Map<String, Object?> f) =
            await r.find(r.dev('n$i', ip: ip));
        expect(<String>['queued', 'seat_assigned'].contains(f['t']), isTrue,
            reason: 'F9: find_game $i of 20 from one IP must be served; got '
                '${fdesc(f)}');
      }
      final (C700Client _, String _, Map<String, Object?> over) =
          await r.find(r.dev('n21', ip: ip));
      expectError(
          over,
          'RATE_LIMITED',
          'F9: item 3: the 21st find_game in one minute from one IP (section '
              '7: 20 per minute)');
      // The typed-code window of section 32 item 5 (20 per 10 minutes) was
      // never touched: after the minute, 20 typed codes all reach the lookup.
      r.tick(const Duration(seconds: 61));
      for (int i = 1; i <= 20; i++) {
        final C700Client c = await r.open(ip, 'code$i');
        c.send('join_room', <String, Object?>{
          'code': 'ZZZZZ',
          'name': 'C',
          'install': r.freshInstall('code'),
        });
        expectError(
            await c.next(),
            'NO_SUCH_ROOM',
            'F9: item 3: typed code $i after 20 find_games must reach the '
                'lookup (find_game never counts against the typed-code '
                'window)');
      }
    });

    _s('F10 find_game shares the per-IP join_room limit of section 7',
        (C700Rig r) async {
      final String ip = r.freshIp();
      for (int i = 1; i <= 20; i++) {
        final C700Client c = await r.open(ip, 'code$i');
        c.send('join_room', <String, Object?>{
          'code': 'ZZZZZ',
          'name': 'C',
          'install': r.freshInstall('code'),
        });
        expectError(await c.next(), 'NO_SUCH_ROOM', 'F10: fixture join $i');
      }
      final (C700Client _, String _, Map<String, Object?> f) =
          await r.find(r.dev('late', ip: ip));
      expectError(
          f,
          'RATE_LIMITED',
          'F10: item 3: find_game after 20 join_room in one minute from the '
              'same IP');
      final (C700Client _, String _, Map<String, Object?> other) =
          await r.find(r.dev('other'));
      expect(other['t'], 'queued',
          reason: 'F10: another IP is not limited; got ${fdesc(other)}');
    });
  });

  group('item 4: the line', () {
    _s(
        'L1 the line in order: two detached tickets and an attached third, '
        'then a new open room seats the third past them and the detached '
        'two keep their places', (C700Rig r) async {
      final Dev a = r.dev('a'), b = r.dev('b'), c = r.dev('c');
      final (C700Client ca, String _) =
          await r.queue(a, 1, name: 'A', row: 'L1 a');
      await _quiet(ca, 'L1', 'a before its socket closes');
      await ca.close();
      final (C700Client cb, String tb) =
          await r.queue(b, 2, name: 'B', row: 'L1 b');
      await _quiet(cb, 'L1', 'b before its socket closes');
      await cb.close();
      final (C700Client cc, String _) =
          await r.queue(c, 3, name: 'C', row: 'L1 c');
      await _quiet(cc, 'L1', 'c, the only attached ticket');
      expect(r.registry.roomCount, 0,
          reason: 'L1: fixture: detached tickets are never two strangers, so '
              'no room exists yet');

      // players 2 (seats 0 and 2): the host and the third fill it, so nothing else can be
      // seated while the detached tickets are probed below.
      final Held r1 = await r.host(open: true, players: 2, name: 'R1');
      await expectSeatedFromLine(cc,
          row: 'L1',
          what: 'item 4: the third is seated past the two detached tickets',
          code: r1.code,
          seat: 2);
      final List<Map<String, Object?>> h1 = await r1.c.sync();
      expect(ftypes(h1), <String>['player_joined'],
          reason: 'L1: R1 gets one player_joined, for the third only; got '
              '${fdescAll(h1)}');
      expect(r.registry.lookup(r1.code)!.seats.length, 2,
          reason: 'L1: the detached tickets are never seated');

      // b is still held: re-attached inside 30 000 ms it gets its old
      // position 2, with a still ahead of it.
      r.tick(const Duration(milliseconds: 29000));
      final (C700Client nb, String idb, Map<String, Object?> fb) =
          await r.find(b, name: 'B', ticket: tb);
      expectQueued(fb,
          position: 2,
          re: idb,
          ticket: tb,
          row: 'L1',
          what: 'b re-attached keeps its ticket and its place behind a');
      await _quiet(nb, 'L1', 'b after its re-attach');
    });

    _s('L2 queued is re-sent on every position change and not otherwise',
        (C700Rig r) async {
      // The line holds detached tickets a, b, c (detached at 0, 10 000 and
      // 20 000 ms) and the attached tail d. Two attached tickets are always
      // a room (item 4), so no second attached ticket can join behind d
      // and no cancel by an attached ticket can move another attached one.
      final Dev a = r.dev('a'), b = r.dev('b'), c = r.dev('c'), d = r.dev('d');
      final (C700Client ca, String _) = await r.queue(a, 1, row: 'L2 a');
      await ca.close();
      r.tick(const Duration(seconds: 10));
      final (C700Client cb, String _) = await r.queue(b, 2, row: 'L2 b');
      await cb.close();
      r.tick(const Duration(seconds: 10));
      final (C700Client cc, String _) = await r.queue(c, 3, row: 'L2 c');
      await cc.close();
      r.tick(const Duration(seconds: 5));
      final (C700Client cd, String td) = await r.queue(d, 4, row: 'L2 d');
      await _quiet(cd, 'L2', 'd when it joined behind three detached tickets');

      r.tick(const Duration(seconds: 1));
      await _quiet(cd, 'L2', 'd after a sweep with no expiry (26 000 ms)');
      r.tick(const Duration(seconds: 3));
      await _quiet(cd, 'L2', 'd after a sweep with no expiry (29 000 ms)');

      r.tick(const Duration(seconds: 1));
      expectQueued(await cd.next(),
          position: 3,
          re: null,
          ticket: td,
          row: 'L2',
          what: 'd 4 -> 3 when a expires at 30 000 ms');
      await _quiet(cd, 'L2', 'd after one change');

      r.tick(const Duration(seconds: 5));
      await _quiet(cd, 'L2', 'd after a sweep with no expiry (35 000 ms)');
      r.tick(const Duration(seconds: 5));
      expectQueued(await cd.next(),
          position: 2,
          re: null,
          ticket: td,
          row: 'L2',
          what: 'd 3 -> 2 when b expires at 40 000 ms');
      r.tick(const Duration(seconds: 10));
      expectQueued(await cd.next(),
          position: 1,
          re: null,
          ticket: td,
          row: 'L2',
          what: 'd 2 -> 1 when c expires at 50 000 ms');
      await _quiet(cd, 'L2', 'd at the head, alone');
      expect(r.registry.roomCount, 0,
          reason: 'L2: one attached ticket makes no room');

      final String id = cd.send('cancel_find', <String, Object?>{});
      final Map<String, Object?> f = await cd.next();
      expect(<Object?>[f['t'], f['re']], <Object?>['find_cancelled', id],
          reason: 'L2: cancel_find by d; got ${fdesc(f)}');
    });

    _s(
        'L3 two strangers and no room: the head hosts a new open four-seat '
        'room, the next three are seated in it, a fifth waits until a seat '
        'frees', (C700Rig r) async {
      final Held ref = await r.host(open: false, players: 4, name: 'Ref');
      final Map<String, Object?> defaults =
          ref.room['rules']! as Map<String, Object?>;
      final List<Dev> d = <Dev>[for (int i = 1; i <= 5; i++) r.dev('s$i')];
      final (C700Client c1, String _) =
          await r.queue(d[0], 1, name: 'S1', row: 'L3 first');
      await _quiet(c1, 'L3', 'a lone ticket');
      expect(r.registry.roomCount, 1, reason: 'L3: one ticket makes nothing');

      // AMBIGUITY: the second ticket is answered queued (position 2, re)
      // and then seated from the line (no re) once the head's room exists.
      final (C700Client c2, String id2, Map<String, Object?> f2) =
          await r.find(d[1], name: 'S2');
      expectQueued(f2,
          position: 2, re: id2, row: 'L3', what: 'the second ticket');
      final Held host = await expectSeatedFromLine(c1,
          row: 'L3', what: 'the head hosts the new room', seat: 0);
      expect(host.room['players'], 4, reason: 'L3: item 4: players 4');
      expect(host.room['open'], true, reason: 'L3: item 4: open true');
      expect(host.room['host_seat'], 0, reason: 'L3: the head is the host');
      expect(seatNumbers(host.room), <int>[0],
          reason: 'L3: the head is seated first, alone');
      expect(seatOf(host.room, 0)['via'], 'host',
          reason: 'L3: item 4: the head has via "host"');
      expect(seatOf(host.room, 0)['name'], 'S1', reason: 'L3: head name');
      expect(host.room['rules'], defaults,
          reason: 'L3: item 4: default rules, as create_room without rules');
      expect(host.room['link_id'], isA<String>(),
          reason: 'L3: the room has a link id as any created room');
      expect(host.room['code'], isNot(ref.code), reason: 'L3: a new room');
      await expectSeatedFromLine(c2,
          row: 'L3', what: 'the second', code: host.code, seat: 1);
      final List<Map<String, Object?>> h1 = await c1.sync();
      expect(ftypes(h1), <String>['player_joined'],
          reason: 'L3: the head sees the second join; got ${fdescAll(h1)}');

      final Held s3 = await r.findSeat(d[2], name: 'S3', row: 'L3 third');
      final Held s4 = await r.findSeat(d[3], name: 'S4', row: 'L3 fourth');
      expect(<Object?>[
        s3.code,
        s3.seat,
        s4.code,
        s4.seat
      ], <Object?>[
        host.code,
        2,
        host.code,
        3
      ], reason: 'L3: the third and fourth fill seats 2 and 3');
      expect(seatOf(s4.room, 3)['via'], 'public', reason: 'L3: via');
      final (C700Client c5, String t5) =
          await r.queue(d[4], 1, name: 'S5', row: 'L3 fifth');
      expect(r.registry.roomCount, 2,
          reason: 'L3: a lone fifth ticket makes no room');
      await _quiet(c5, 'L3', 'the fifth while the room is full');

      await s3.c.sync();
      final String leaveId = s3.c.send('leave_room', <String, Object?>{});
      final Map<String, Object?> left = await s3.c.next();
      expect(left['re'], leaveId, reason: 'L3: fixture leave_room');
      final Held s5 = await expectSeatedFromLine(c5,
          row: 'L3', what: 'item 4: a leave frees a seat', code: host.code);
      expect(s5.seat, 2, reason: 'L3: the freed seat 2');
      expect(t5, isNotEmpty);
    });

    _s('L4 a single ticket alone creates nothing', (C700Rig r) async {
      final (C700Client c, String _) = await r.queue(r.dev('s'), 1, row: 'L4');
      for (int i = 0; i < 5; i++) {
        r.tick(const Duration(seconds: 1));
      }
      await _quiet(c, 'L4', 'a lone ticket over five sweeps');
      expect(r.registry.roomCount, 0,
          reason: 'L4: item 4: two strangers need two attached tickets');
    });

    _s(
        'L5 cancel_find leaves the line and answers find_cancelled, with or '
        'without a ticket', (C700Rig r) async {
      final C700Client none = await r.open(r.freshIp(), 'none');
      final String id0 = none.send('cancel_find', <String, Object?>{});
      final Map<String, Object?> f0 = await none.next();
      expect(<Object?>[f0['t'], fd(f0), f0['re']],
          <Object?>['find_cancelled', <String, Object?>{}, id0],
          reason: 'L5: item 4: cancel_find without a ticket is answered '
              'find_cancelled {} with re; got ${fdesc(f0)}');

      final (C700Client c, String _) = await r.queue(r.dev('q'), 1, row: 'L5');
      final String id1 = c.send('cancel_find', <String, Object?>{});
      final Map<String, Object?> f1 = await c.next();
      expect(<Object?>[
        f1['t'],
        fd(f1),
        f1['re']
      ], <Object?>[
        'find_cancelled',
        <String, Object?>{},
        id1
      ], reason: 'L5: cancel_find with a ticket; got ${fdesc(f1)}');
      final Held h = await r.host(open: true, players: 4);
      await _quiet(c, 'L5', 'a cancelled ticket is never seated');
      await _quiet(h.c, 'L5', 'the open room after the cancel');
      final Held s = await r.findSeat(r.dev('n'), row: 'L5 control');
      expect(s.seat, 1, reason: 'L5: seat 1 was left free');
    });

    _s('L6 a detached ticket is passed over and is not one of two strangers',
        (C700Rig r) async {
      final (C700Client ca, String _) = await r.queue(r.dev('a'), 1, row: 'L6');
      await ca.close();
      // AMBIGUITY: a detached ticket keeps its place, so it still counts in
      // the positions of those behind it.
      final (C700Client cb, String _) = await r.queue(r.dev('b'), 2, row: 'L6');
      await _quiet(cb, 'L6', 'b behind a detached ticket');
      expect(r.registry.roomCount, 0,
          reason: 'L6: item 4: a detached ticket is never counted for two '
              'strangers');
      final Held h = await r.host(open: true, players: 4);
      await expectSeatedFromLine(cb,
          row: 'L6',
          what: 'b is served past the detached a',
          code: h.code,
          seat: 1);
      final List<Map<String, Object?>> hf = await h.c.sync();
      expect(ftypes(hf), <String>['player_joined'],
          reason: 'L6: only b is seated; got ${fdescAll(hf)}');
      expect(r.registry.lookup(h.code)!.seats.length, 2,
          reason: 'L6: the detached ticket is never seated');
    });

    _s(
        'L7 a detached ticket re-attached by ticket at 29 999 ms takes its old '
        'place', (C700Rig r) async {
      final Dev a = r.dev('a'), b = r.dev('b');
      final (C700Client ca, String ta) =
          await r.queue(a, 1, name: 'A', row: 'L7 a');
      await ca.close();
      final (C700Client cb, String tb) =
          await r.queue(b, 2, name: 'B', row: 'L7 b');
      await cb.close();
      r.tick(const Duration(milliseconds: 29999));
      // b first: in its old place it stays behind a.
      final (C700Client nb, String idb, Map<String, Object?> fb) =
          await r.find(b, name: 'B', ticket: tb);
      expectQueued(fb,
          position: 2,
          re: idb,
          ticket: tb,
          row: 'L7',
          what: 'b re-attached at 29 999 ms keeps its ticket and place');
      expect(r.registry.roomCount, 0,
          reason: 'L7: one attached ticket makes no room');
      final (C700Client na, String ida, Map<String, Object?> fa) =
          await r.find(a, name: 'A', ticket: ta);
      expectQueued(fa,
          position: 1,
          re: ida,
          ticket: ta,
          row: 'L7',
          what: 'a re-attached keeps its ticket and the head');
      // Two attached: the head (a, in its old place) hosts, b is seated.
      final Held ha =
          await expectSeatedFromLine(na, row: 'L7', what: 'a hosts', seat: 0);
      await expectSeatedFromLine(nb,
          row: 'L7', what: 'b is seated second', code: ha.code, seat: 1);
    });

    _s(
        'L8 at 30 000 ms detached the ticket is dropped and its ticket is '
        'treated as new', (C700Rig r) async {
      final Dev a = r.dev('a');
      final (C700Client ca, String ta) = await r.queue(a, 1, row: 'L8');
      await ca.close();
      r.tick(const Duration(milliseconds: 30000));
      final (C700Client _, String id, Map<String, Object?> f) =
          await r.find(a, ticket: ta);
      expectQueued(f,
          position: 1,
          re: id,
          row: 'L8',
          what: 'find_game with the expired '
              'ticket');
      expect(fd(f)['ticket'], isNot(ta),
          reason: 'L8: item 4: after 30 000 ms detached the ticket is '
              'dropped, so the caller gets a new ticket; got the old one');
    });

    _s(
        'L9 a re-attach with a wrong install is a new ticket at the tail; '
        'the right install still re-attaches', (C700Rig r) async {
      final Dev a = r.dev('a');
      final (C700Client ca, String ta) =
          await r.queue(a, 1, name: 'A', row: 'L9');
      await ca.close();
      final Dev other = r.dev('other', ip: a.ip);
      final (C700Client co, String ido, Map<String, Object?> fo) =
          await r.find(other, name: 'O', ticket: ta);
      expectQueued(fo,
          position: 2,
          re: ido,
          row: 'L9',
          what: 'the ticket with a different install is a fresh find_game');
      expect(fd(fo)['ticket'], isNot(ta),
          reason: 'L9: item 4: a mismatched install gets a new ticket');
      expect(r.registry.roomCount, 0,
          reason: 'L9: the detached a and one attached ticket make no room');
      final (C700Client na, String ida, Map<String, Object?> fa) =
          await r.find(a, name: 'A', ticket: ta);
      expectQueued(fa,
          position: 1,
          re: ida,
          ticket: ta,
          row: 'L9',
          what: 'the right install re-attaches the held ticket at the head');
      final Held ha = await expectSeatedFromLine(na,
          row: 'L9', what: 'a hosts the two strangers', seat: 0);
      await expectSeatedFromLine(co,
          row: 'L9', what: 'the other is seated', code: ha.code, seat: 1);
    });

    _s('L10 an unknown ticket is a fresh find_game at the tail',
        (C700Rig r) async {
      final (C700Client ca, String ta) =
          await r.queue(r.dev('a'), 1, row: 'L10');
      await ca.close();
      const String unknown = 'AAAAAAAAAAAAAAAAAAAAAA';
      final (C700Client _, String id, Map<String, Object?> f) =
          await r.find(r.dev('e'), ticket: unknown);
      expectQueued(f,
          position: 2,
          re: id,
          row: 'L10',
          what: 'find_game with an unknown '
              'ticket');
      expect(<Object?>[
        fd(f)['ticket'] == unknown,
        fd(f)['ticket'] == ta
      ], <bool>[
        false,
        false
      ], reason: 'L10: item 4: an unknown ticket gets a new ticket');
    });

    _s('L11 a queued socket that sends create_room leaves the line',
        (C700Rig r) async {
      final (C700Client q, String _) = await r.queue(r.dev('q'), 1, row: 'L11');
      q.send('create_room', <String, Object?>{
        'name': 'Q',
        'players': 4,
        'open': false,
      });
      expect(<Object?>[
        (await q.next())['t'],
        (await q.next())['t']
      ], <String>[
        'seat_assigned',
        'room'
      ], reason: 'L11: create_room from a queued socket is served');
      final (C700Client s, String _) = await r.queue(r.dev('s'), 1, row: 'L11');
      await _quiet(s, 'L11', 'the next stranger');
      await _quiet(q, 'L11', 'the socket that left the line');
      expect(r.registry.roomCount, 1,
          reason: 'L11: item 4: create_room dropped the ticket, so the next '
              'find_game is alone in the line and no two-strangers room is '
              'made');
    });

    _s('L12 a second find_game from a queued socket takes a new ticket',
        (C700Rig r) async {
      final Dev q = r.dev('q');
      final (C700Client c, String t1) = await r.queue(q, 1, row: 'L12');
      final (C700Client _, String id, Map<String, Object?> f) =
          await r.find(q, on: c);
      expectQueued(f,
          position: 1, re: id, row: 'L12', what: 'the second find_game');
      expect(fd(f)['ticket'], isNot(t1),
          reason: 'L12: item 4: a second find_game drops the ticket first');
      expect(r.registry.roomCount, 0,
          reason: 'L12: one socket is never two strangers');
    });

    _s('L13 a host reconnect makes its room matchable and seats the line',
        (C700Rig r) async {
      final Held h = await r.host(open: true, players: 4);
      await h.c.close();
      await r.untilDown(h.code, 0);
      final (C700Client c, String _) = await r.queue(r.dev('s'), 1, row: 'L13');
      final C700Client back = await r.open(r.freshIp(), 'host-back');
      back.send('resume', <String, Object?>{
        'code': h.code,
        'seat_token': h.token,
      });
      expect(<Object?>[
        (await back.next())['t'],
        (await back.next())['t']
      ], <String>[
        'seat_assigned',
        'room'
      ], reason: 'L13: fixture resume');
      await expectSeatedFromLine(c,
          row: 'L13', what: 'item 4: a host reconnect', code: h.code, seat: 1);
      expect(ftypes(await back.sync()), <String>['player_joined'],
          reason: 'L13: the host sees the join');
    });

    _s('L14 a set_players raise seats the line', (C700Rig r) async {
      final Held h = await r.host(open: true, players: 2);
      await r.join(<String, Object?>{'link': h.linkId}, r.dev('g'));
      await h.c.sync();
      final (C700Client c, String _) = await r.queue(r.dev('s'), 1, row: 'L14');
      h.c.send('set_players', <String, Object?>{'players': 3});
      await expectSeatedFromLine(c,
          row: 'L14',
          what: 'item 4: a set_players raise frees seat 2',
          code: h.code,
          seat: 2);
    });

    _s(
        'L15 a device kicked from an open room is not seated in it from the '
        'line but is seated in the next one', (C700Rig r) async {
      final Held r0 = await r.host(open: true, players: 4, name: 'R0');
      final Dev x = r.dev('x');
      final Held s = await r.findSeat(x, name: 'X', row: 'L15');
      expect(s.code, r0.code, reason: 'L15: fixture');
      await r0.c.sync();
      r0.c.send('kick', <String, Object?>{'seat': s.seat});
      await s.c.untilType('kicked');
      await r0.c.sync();
      final (C700Client again, String _) =
          await r.queue(x, 1, on: s.c, name: 'X', row: 'L15 same socket');
      // Its ticket stays detached for 30 000 ms after the close, so the same
      // install queueing again from another IP is position 2.
      await _quiet(r0.c, 'L15', 'R0 bars x');
      await again.close();
      final (C700Client fresh, String _) = await r.queue(
          Dev('x2', x.install, r.freshIp()), 2,
          name: 'X', row: 'L15 same install, another IP');
      await _quiet(fresh, 'L15', 'x waits');
      final Held r1 = await r.host(open: true, players: 4, name: 'R1');
      await expectSeatedFromLine(fresh,
          row: 'L15',
          what: 'item 7: x is seated in the next open room',
          code: r1.code,
          seat: 1);
      expect(r.registry.lookup(r0.code)!.seats.length, 1,
          reason: 'L15: item 7: R0 never seats the kicked device');
    });

    _s('L16 a rematch LOBBY with a free seat is matchable', (C700Rig r) async {
      final Held h = await r.host(open: true, players: 3);
      final Held g1 =
          await r.join(<String, Object?>{'link': h.linkId}, r.dev('g1'));
      final Held g2 =
          await r.join(<String, Object?>{'link': h.linkId}, r.dev('g2'));
      await h.c.sync();
      await g1.c.sync();
      await r.start(h, <C700Client>[h.c, g1.c, g2.c]);
      _forceFinished(r, h.code, winner: 0);
      g2.c.send('leave_room', <String, Object?>{});
      await g2.c.next();
      await h.c.sync();
      h.c.send('rematch', <String, Object?>{});
      await h.c.untilType('room');
      final Held s = await r.findSeat(r.dev('s'), row: 'L16');
      expect(<Object?>[s.code, s.seat], <Object?>[h.code, g2.seat],
          reason: 'L16: item 2: a rematch LOBBY counts; the freed seat');
    });

    _s(
        'Q1 a queued socket holds no seat: in-room messages answer as from a '
        'seatless socket', (C700Rig r) async {
      final Map<String, Map<String, Object?>> msgs =
          <String, Map<String, Object?>>{
        'roll': <String, Object?>{},
        'move': <String, Object?>{'token': 0},
        'start_game': <String, Object?>{},
        'rematch': <String, Object?>{},
        'kick': <String, Object?>{'seat': 1},
        'set_seed': <String, Object?>{'client_seed': 'abc'},
      };
      final C700Client bare = await r.open(r.freshIp(), 'bare');
      final Map<String, String?> want = <String, String?>{};
      for (final MapEntry<String, Map<String, Object?>> m in msgs.entries) {
        bare.send(m.key, m.value);
        final Map<String, Object?> f = await bare.next();
        want[m.key] =
            f['t'] == 'error' ? fd(f)['code'] as String? : '${f['t']}';
      }
      final (C700Client q, String _) = await r.queue(r.dev('q'), 1, row: 'Q1');
      for (final MapEntry<String, Map<String, Object?>> m in msgs.entries) {
        q.send(m.key, m.value);
        final Map<String, Object?> f = await q.next();
        final String? got =
            f['t'] == 'error' ? fd(f)['code'] as String? : '${f['t']}';
        expect(got, want[m.key],
            reason: 'Q1: item 4: ${m.key} from a queued socket must answer '
                'as from a seatless one (${want[m.key]}); got ${fdesc(f)}');
      }
    });
  });
}
