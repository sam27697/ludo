// Order C-700t: docs/PROTOCOL.md section 33 item 6 (strikes, replacing section
// 32 item 7) as a table, plus the ban rows of item 9 and the `ban` on the
// PLAYING `kicked` frame of item 8. Written from the section alone against a
// real WireServer on real sockets, a fake clock and a temporary strike
// directory (section 32 item 11), ruleset 2026-11 so the PLAYING kick exists.
//
// How a strike is seen: the store file holds the keyed hash of the struck
// install (HMAC-SHA256 under the test salt, as c684_short_codes_strikes_test
// reads it), looked for as a substring, so the file layout is not pinned. An
// event that must NOT strike is followed by a control strike against a fresh
// device; once the control's hash is on disk the file has been rewritten
// after the event, and the first device's hash must be absent.
//
// Every host is on its own IP (section 32 item 15a: a strike whose host IP is
// the struck IP is not recorded).

import 'package:test/test.dart';

import 'support/c700_harness.dart';

const String _file = 'test/c700_route_strikes_test.dart';

void _s(String name, Future<void> Function(C700Rig r) body,
        {Timeout? timeout}) =>
    c700Scenario(_file, name, body,
        ruleset: '2026-11', useStore: true, timeout: timeout);

const Duration _h24 = Duration(hours: 24);
const Duration _d7 = Duration(days: 7);

Future<void> _expectStruck(C700Rig r, Dev d, String row, String event) async {
  final String hash = c700Hmac(d.install);
  final String text = await r.fileText(ready: (String t) => t.contains(hash));
  if (!text.contains(hash)) {
    throw TestFailure('$row: item 6: $event must record a strike against the '
        'struck install; strikes.json never held its keyed hash (file '
        '${text.isEmpty ? 'absent or empty' : '${text.length} bytes'})');
  }
}

Future<void> _expectNotStruck(
    C700Rig r, Dev d, String row, String event) async {
  final Dev ctl = r.dev('control');
  final Held h = await r.host(players: 4, approval: true);
  await _reject(r, h, ctl);
  final String ctlHash = c700Hmac(ctl.install);
  final String text =
      await r.fileText(ready: (String t) => t.contains(ctlHash));
  if (!text.contains(ctlHash)) {
    throw TestFailure('$row: control: a rejected knock in a friends-only room '
        'must strike, and strikes.json never held the control\'s hash, so '
        'this row proves nothing');
  }
  expect(text.contains(c700Hmac(d.install)), isFalse,
      reason: '$row: item 6: $event must not be a strike, and strikes.json '
          'holds the keyed hash of the install it would have struck');
}

/// A typed-code knock by [d] that [h] refuses. Returns knock_failed `d`.
Future<Map<String, Object?>> _reject(C700Rig r, Held h, Dev d) async {
  final C700Client c = await r.open(d.ip, '${d.tag}-knock');
  c.send('join_room', <String, Object?>{
    'code': h.code,
    'name': 'K',
    'install': d.install,
  });
  final Map<String, Object?> f = await c.next();
  if (f['t'] != 'knock_pending') {
    throw TestFailure('fixture: a code join with approval on must knock; got '
        '${fdesc(f)}');
  }
  final Map<String, Object?> hk = await h.c.untilType('knock');
  h.c.send('answer_knock', <String, Object?>{
    'knock_id': fd(hk)['knock_id'],
    'accept': false,
  });
  final Map<String, Object?> failed = await c.untilType('knock_failed');
  expect(fd(failed)['outcome'], 'rejected', reason: 'fixture: rejected');
  await h.c.sync();
  await c.close();
  return fd(failed);
}

/// Seats [d] in [h]'s room by [via]: code, approved, link or public.
Future<Held> _seat(C700Rig r, Held h, Dev d, String via) async {
  final Held s;
  switch (via) {
    case 'code':
      s = await r.join(<String, Object?>{'code': h.code}, d);
    case 'link':
      s = await r.join(<String, Object?>{'link': h.linkId}, d);
    case 'approved':
      s = await r.joinApproved(h, d);
    case 'public':
      s = await r.findSeat(d, row: 'fixture public seat');
      expect(s.code, h.code, reason: 'fixture: seated in the room under test');
    default:
      throw ArgumentError(via);
  }
  expect(seatOf(s.room, s.seat)['via'], via,
      reason: 'fixture: the seat must have via "$via"; got '
          '${seatOf(s.room, s.seat)}');
  await h.c.sync();
  return s;
}

/// Kicks [s] from [h]'s room in [phase] (LOBBY or PLAYING); returns the
/// kicked frame's `d`.
Future<Map<String, Object?>> _kick(
    C700Rig r, Held h, Held s, String phase) async {
  if (phase == 'PLAYING') {
    await r.start(h, <C700Client>[h.c, s.c]);
    forceTurn(r, h.code, seat: h.seat);
  }
  h.c.send('kick', <String, Object?>{'seat': s.seat});
  final List<Map<String, Object?>> hf = await h.c.sync();
  if (hf.isEmpty || hf.first['t'] == 'error') {
    throw TestFailure('the $phase kick of a "${seatOf(s.room, s.seat)['via']}" '
        'seat must be accepted (section 33 item 8 for PLAYING, section 31 '
        'item 6 for LOBBY); the host got ${fdescAll(hf)}');
  }
  final Map<String, Object?> kicked = await s.c.untilType('kicked');
  await s.c.close();
  return fd(kicked);
}

class _Row {
  const _Row(
      this.id, this.open, this.event, this.via, this.phase, this.strikes);

  final String id;
  final bool open;
  final String event; // reject, kick
  final String via;
  final String phase;
  final bool strikes;

  String get title {
    final String room = open ? 'an open room' : 'a friends-only room';
    final String what = event == 'reject'
        ? 'a rejected knock'
        : 'the $phase kick of a "$via" seat';
    return '$id $what in $room ${strikes ? 'strikes' : 'does not strike'}';
  }
}

const List<_Row> _table = <_Row>[
  _Row('T1', false, 'reject', 'code', 'LOBBY', true),
  _Row('T2', true, 'reject', 'code', 'LOBBY', false),
  _Row('T3', false, 'kick', 'code', 'LOBBY', true),
  _Row('T4', true, 'kick', 'code', 'LOBBY', false),
  _Row('T5', false, 'kick', 'approved', 'LOBBY', true),
  _Row('T6', true, 'kick', 'approved', 'LOBBY', false),
  _Row('T7', false, 'kick', 'code', 'PLAYING', true),
  _Row('T8', true, 'kick', 'code', 'PLAYING', false),
  _Row('T9', false, 'kick', 'approved', 'PLAYING', true),
  _Row('T10', true, 'kick', 'approved', 'PLAYING', false),
  _Row('T11', false, 'kick', 'link', 'LOBBY', false),
  _Row('T12', false, 'kick', 'link', 'PLAYING', false),
  _Row('T13', true, 'kick', 'link', 'PLAYING', false),
  _Row('T14', true, 'kick', 'public', 'LOBBY', false),
  _Row('T15', true, 'kick', 'public', 'PLAYING', false),
];

void main() {
  group('item 6 as a table', () {
    for (final _Row row in _table) {
      _s(row.title, (C700Rig r) async {
        final Dev d = r.dev('struck');
        final bool approval = row.event == 'reject' || row.via == 'approved';
        // A friends-only room is made by leaving `open` out (item 1: absent
        // means false).
        final Held h = await r.host(
            open: row.open ? true : null, players: 2, approval: approval);
        final String event = '${row.title} (open=${row.open})';
        if (row.event == 'reject') {
          await _reject(r, h, d);
        } else {
          final Held s = await _seat(r, h, d, row.via);
          final Map<String, Object?> kicked = await _kick(r, h, s, row.phase);
          expect(kicked.containsKey('ban'), isFalse,
              reason: '${row.id}: one strike fires no ban; got $kicked');
        }
        if (row.strikes) {
          await _expectStruck(r, d, row.id, event);
        } else {
          await _expectNotStruck(r, d, row.id, event);
        }
      });
    }

    _s(
        'T16 a leave_room in PLAYING from a code seat in a friends-only room '
        'does not strike', (C700Rig r) async {
      final Dev d = r.dev('leaver');
      final Held h = await r.host(players: 3);
      final Held s = await _seat(r, h, d, 'code');
      final Held o = await _seat(r, h, r.dev('other'), 'link');
      await s.c.sync();
      await r.start(h, <C700Client>[h.c, s.c, o.c]);
      s.c.send('leave_room', <String, Object?>{});
      final Map<String, Object?> f = await s.c.untilType('seat_retired');
      expect(fd(f)['reason'], 'left', reason: 'T16: fixture');
      await _expectNotStruck(r, d, 'T16', 'a leave_room');
    });

    _s(
        'T17 the PLAYING kick of a dropped code seat in a friends-only room '
        'strikes', (C700Rig r) async {
      final Dev d = r.dev('dropped');
      final Held h = await r.host(players: 2);
      final Held s = await _seat(r, h, d, 'code');
      await r.start(h, <C700Client>[h.c, s.c]);
      forceTurn(r, h.code, seat: 0);
      await s.c.close();
      await h.c.untilType('presence');
      h.c.send('kick', <String, Object?>{'seat': s.seat});
      await h.c.untilType('seat_retired');
      await _expectStruck(r, d, 'T17', 'the PLAYING kick of a dropped seat');
    });
  });

  group('item 9: bans by route', () {
    _s('B1 a public seat kicked by six hosts on six IPs is not banned',
        (C700Rig r) async {
      final Dev d = r.dev('public');
      for (int i = 1; i <= 6; i++) {
        final Held h = await r.host(open: true, players: 4, name: 'H$i');
        final Held s = await _seat(r, h, d, 'public');
        final Map<String, Object?> kicked = await _kick(r, h, s, 'LOBBY');
        expect(kicked.containsKey('ban'), isFalse,
            reason: 'B1: kick $i of a public seat carries no ban; got '
                '$kicked');
        await h.c.close();
      }
      final C700Client c = await r.open(d.ip, 'probe');
      c.send('join_room', <String, Object?>{
        'code': 'ZZZZZ',
        'name': 'P',
        'install': d.install,
      });
      expectError(
          await c.next(),
          'NO_SUCH_ROOM',
          'B1: item 6: six kicks of a public seat are no strike, so a typed '
              'code still reaches the lookup (not CODE_BANNED)');
      await _expectNotStruck(r, d, 'B1', 'six kicks of a public seat');
    });

    _s(
        'B2 a code seat refused in six friends-only rooms by six host IPs '
        'gets the 24-hour ban; find_game is untouched', (C700Rig r) async {
      final Dev d = r.dev('code');
      Map<String, Object?> last = <String, Object?>{};
      final int at = r.clock.now.millisecondsSinceEpoch;
      for (int i = 1; i <= 6; i++) {
        final Held h = await r.host(players: 4, approval: true, name: 'H$i');
        last = await _reject(r, h, d);
        if (i < 6) {
          expect(last.containsKey('ban'), isFalse,
              reason: 'B2: refusal $i of 6 fires no ban; got $last');
        }
        await h.c.close();
      }
      expect(
          last['ban'],
          <String, Object?>{
            'scope': 'device',
            'until_ms': at + _h24.inMilliseconds,
            'level': 1,
            'next_ms': _d7.inMilliseconds,
          },
          reason: 'B2: item 6 with section 32 items 8 and 12: the sixth '
              'refusal by a sixth host IP fires the 24-hour ban; got $last');
      final C700Client c = await r.open(d.ip, 'probe');
      c.send('join_room', <String, Object?>{
        'code': 'ZZZZZ',
        'name': 'P',
        'install': d.install,
      });
      expectError(
          await c.next(), 'CODE_BANNED', 'B2: the banned device types a code');
      // Item 3: a ban does not touch find_game.
      final (C700Client _, String id, Map<String, Object?> f) =
          await r.find(Dev('code-new-ip', d.install, r.freshIp()));
      expectQueued(f,
          position: 1,
          re: id,
          row: 'B2',
          what: 'item 3: find_game from a banned device');
    });

    _s(
        'B3 six PLAYING kicks of a code seat in friends-only rooms: the sixth '
        'kicked frame carries the ban', (C700Rig r) async {
      final Dev d = r.dev('played');
      Map<String, Object?> last = <String, Object?>{};
      final int at = r.clock.now.millisecondsSinceEpoch;
      for (int i = 1; i <= 6; i++) {
        final Held h = await r.host(players: 2, name: 'H$i');
        final Held s = await _seat(r, h, d, 'code');
        last = await _kick(r, h, s, 'PLAYING');
        if (i < 6) {
          expect(last.containsKey('ban'), isFalse,
              reason: 'B3: PLAYING kick $i of 6: kicked carries no ban; got '
                  '$last');
        }
        await h.c.close();
      }
      expect(
          last['ban'],
          <String, Object?>{
            'scope': 'device',
            'until_ms': at + _h24.inMilliseconds,
            'level': 1,
            'next_ms': _d7.inMilliseconds,
          },
          reason: 'B3: item 8: the kicked frame of the kick that fired a ban '
              'carries ban (section 32 item 12); got $last');
    });
  });
}
