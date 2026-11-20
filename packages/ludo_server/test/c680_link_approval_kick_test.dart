// Order C-680t: tests for docs/PROTOCOL.md section 31 (room link ids, guest
// approval, knocks, the lobby kick, bars, the /r/<id> routes), written from
// the section alone, against a real WireServer on a real socket with a fake
// clock. Nothing here reads the implementation.
//
// Determinism: every scenario runs on its own server with a FakeClock and
// automaticTurnExpiry off. No dice are involved except in the one game that is
// started to reach PLAYING, and no assertion depends on a face. A failure
// names its scenario and the exact command that re-runs it; there is no seed.
//
// Waiting: nothing sleeps. Every "nothing else arrived" check uses a ping
// barrier (`_sync`): the server answers frames on one socket in order, so
// every frame queued for that socket before the pong is read before it.
//
// Time driver: section 31 says a knock times out "on the server clock" but
// not which sweep notices. These tests advance the FakeClock and then run both
// existing sweeps (`WireServer.runTurnExpiryOnce` and `RoomRegistry.reap`)
// through `_Rig.tick`. See the report for this interpretation.
//
// Spec ambiguities and the reading each test took are marked `AMBIGUITY`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/wire_harness.dart';

const String _file = 'test/c680_link_approval_kick_test.dart';

String _repro(String name) =>
    'scenario: "$name". Deterministic: fake clock, no seed. Reproduce with: '
    'cd packages/ludo_server && dart test $_file -n "$name"';

final RegExp _linkShape = RegExp(r'^[0-9a-z]+-[a-z0-9]{6}$');

// ---------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------

class _Rig {
  _Rig(this.name) : h = ServerHarness.build(automaticTurnExpiry: false);

  final String name;
  final ServerHarness h;
  final List<WireTestClient> clients = <WireTestClient>[];
  final Set<WireTestClient> gone = <WireTestClient>{};

  Future<WireTestClient> open() async {
    final WireTestClient c = await WireTestClient.connect(h.wsUri);
    clients.add(c);
    return c;
  }

  /// Reads every pending frame off every live socket, discarding them.
  Future<void> flushAll() async {
    for (final WireTestClient c in clients) {
      if (!gone.contains(c)) {
        await _sync(c);
      }
    }
  }

  /// Moves the fake clock and runs the sweeps that read it.
  void tick(Duration d) {
    h.clock.advance(d);
    h.server.runTurnExpiryOnce();
    h.registry.reap();
  }

  Future<void> dispose() async {
    for (final WireTestClient c in clients) {
      try {
        await c.close();
      } catch (_) {
        // a socket the server already closed
      }
    }
    await h.close();
  }
}

void _scenario(
  String name,
  Future<void> Function(_Rig r) body, {
  Timeout? timeout,
}) {
  test(name, () async {
    final _Rig r = _Rig(name);
    try {
      await r.h.start();
      await body(r);
    } on TestFailure catch (e) {
      throw TestFailure('${e.message}\n${_repro(name)}');
    } on Object catch (e, s) {
      throw TestFailure('scenario died with ${e.runtimeType}: $e\n$s\n'
          '${_repro(name)}');
    } finally {
      await r.dispose();
    }
  }, timeout: timeout);
}

// ---------------------------------------------------------------------
// Frame helpers
// ---------------------------------------------------------------------

Map<String, Object?> _d(Map<String, Object?> frame) =>
    (frame['d'] ?? <String, Object?>{}) as Map<String, Object?>;

/// Sends a ping and returns every frame that arrived before the pong.
Future<List<Map<String, Object?>>> _sync(WireTestClient c) async {
  c.send('ping', <String, Object?>{});
  final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
  for (int i = 0; i < 80; i++) {
    final Map<String, Object?> f = await c.next();
    if (f['t'] == 'pong') {
      return frames;
    }
    frames.add(f);
  }
  throw TestFailure('no pong within 80 frames; saw $frames');
}

List<Map<String, Object?>> _ofType(
        List<Map<String, Object?>> frames, String t) =>
    frames.where((Map<String, Object?> f) => f['t'] == t).toList();

/// Reads frames until every type in [types] has been seen once.
Future<Map<String, Map<String, Object?>>> _gather(
  WireTestClient c,
  Set<String> types,
) async {
  final Map<String, Map<String, Object?>> seen =
      <String, Map<String, Object?>>{};
  for (int i = 0; i < 12 && !seen.keys.toSet().containsAll(types); i++) {
    final Map<String, Object?> f = await c.next();
    seen.putIfAbsent(f['t']! as String, () => f);
  }
  if (!seen.keys.toSet().containsAll(types)) {
    throw TestFailure('expected frames of types $types, saw ${seen.keys}');
  }
  return seen;
}

void _err(Map<String, Object?> frame, String code, String because) =>
    expectErrorFrame(frame, code, because: because);

void _noSeq(Map<String, Object?> frame, String because) => expect(
      _d(frame).containsKey('seq'),
      isFalse,
      reason: 'section 31: $because must carry no seq; got ${frame['t']} '
          'with d=${_d(frame)}',
    );

void _hasSeq(Map<String, Object?> frame, String because) => expect(
      _d(frame)['seq'],
      isA<int>(),
      reason: 'section 31: $because must carry seq as an int; got '
          '${frame['t']} with d=${_d(frame)}',
    );

/// A valid install id (16 to 64 characters of [A-Za-z0-9_-]).
String _inst(String tag) => 'install_${tag}_0123456789';

class _Seat {
  _Seat(this.c, this.seat, this.token, this.room);

  final WireTestClient c;
  final int seat;
  final String token;
  final Map<String, Object?> room;

  String get code => room['code']! as String;
  String get linkId {
    final Object? v = room['link_id'];
    if (v is! String) {
      throw TestFailure('section 31 item 1: the room snapshot must carry '
          'link_id as a string; got $v in $room');
    }
    return v;
  }
}

Future<_Seat> _create(_Rig r, {int players = 3, String name = 'Host'}) async {
  final WireTestClient c = await r.open();
  c.send('create_room', <String, Object?>{'name': name, 'players': players});
  final Map<String, Object?> sa = await c.next();
  final Map<String, Object?> room = await c.next();
  expect(sa['t'], 'seat_assigned', reason: 'create_room first frame: $sa');
  expect(room['t'], 'room', reason: 'create_room second frame: $room');
  return _Seat(
      c, _d(sa)['seat']! as int, _d(sa)['seat_token']! as String, _d(room));
}

class _Raw {
  _Raw(this.c, this.frame);

  final WireTestClient c;
  final Map<String, Object?> frame;
}

/// Opens a socket, sends one join_room, returns the first frame back.
Future<_Raw> _joinRaw(
  _Rig r,
  Map<String, Object?> key,
  String name, {
  String? install,
  Object? rawInstall,
}) async {
  final WireTestClient c = await r.open();
  c.send('join_room', <String, Object?>{
    ...key,
    'name': name,
    if (install != null) 'install': install,
    if (rawInstall != null) 'install': rawInstall,
  });
  return _Raw(c, await c.next());
}

/// A join that must seat at once: seat_assigned then room on the joiner.
Future<_Seat> _join(
  _Rig r,
  Map<String, Object?> key,
  String name, {
  String? install,
}) async {
  final _Raw raw = await _joinRaw(r, key, name, install: install);
  expect(raw.frame['t'], 'seat_assigned',
      reason: 'join_room $key by "$name" should seat at once; got '
          '${raw.frame['t']}: ${raw.frame['d']}');
  final Map<String, Object?> room = await raw.c.next();
  expect(room['t'], 'room',
      reason: 'seat_assigned must be followed by room; got $room');
  await r.flushAll();
  return _Seat(raw.c, _d(raw.frame)['seat']! as int,
      _d(raw.frame)['seat_token']! as String, _d(room));
}

Map<String, Object?> _seatEntry(Map<String, Object?> room, int seat) {
  final List<Object?> seats = room['seats']! as List<Object?>;
  for (final Object? s in seats) {
    final Map<String, Object?> m = s! as Map<String, Object?>;
    if (m['seat'] == seat) {
      return m;
    }
  }
  throw TestFailure('seat $seat absent from snapshot seats: $seats');
}

bool _hasSeatEntry(Map<String, Object?> room, int seat) =>
    (room['seats']! as List<Object?>)
        .any((Object? s) => (s! as Map<String, Object?>)['seat'] == seat);

class _Knock {
  _Knock(this.c, this.id, this.name);

  final WireTestClient c;
  final String id;
  final String name;
}

/// A typed-code join with approval on: knock_pending to the knocker, knock to
/// the host.
Future<_Knock> _knock(
  _Rig r,
  _Seat host,
  String name, {
  String? install,
}) async {
  final _Raw raw = await _joinRaw(r, <String, Object?>{'code': host.code}, name,
      install: install);
  expect(raw.frame['t'], 'knock_pending',
      reason: 'section 31 item 3: a code join with guest_approval on must be '
          'answered knock_pending; got ${raw.frame['t']}: ${raw.frame['d']}');
  final Map<String, Object?> pd = _d(raw.frame);
  _noSeq(raw.frame, 'knock_pending');
  expect(pd['expires_ms'], 60000, reason: 'knock_pending.expires_ms');
  expect(pd['knock_id'], isA<String>(), reason: 'knock_pending.knock_id');
  expect((pd['knock_id']! as String).isNotEmpty, isTrue);
  final Map<String, Object?> hk = await receiveType(host.c, 'knock');
  final Map<String, Object?> kd = _d(hk);
  expect(kd['knock_id'], pd['knock_id'],
      reason: 'host knock.knock_id must equal the knocker knock_pending id');
  expect(kd['name'], name, reason: 'host knock.name');
  expect(kd['expires_ms'], 60000, reason: 'host knock.expires_ms');
  _hasSeq(hk, 'the host knock');
  return _Knock(raw.c, pd['knock_id']! as String, name);
}

void _answer(_Seat host, _Knock k, bool accept) => host.c.send(
    'answer_knock', <String, Object?>{'knock_id': k.id, 'accept': accept});

Future<void> _approval(_Seat host, bool enabled) async {
  host.c.send('set_guest_approval', <String, Object?>{'enabled': enabled});
}

/// A fresh socket that resumes [seat], returning the room snapshot `d`.
Future<Map<String, Object?>> _resumeRoom(
    _Rig r, String code, String token) async {
  final WireTestClient c = await r.open();
  c.send('resume', <String, Object?>{'code': code, 'seat_token': token});
  return _d(await receiveType(c, 'room'));
}

Future<Map<String, Object?>> _resumeFrame(
    _Rig r, String code, String token) async {
  final WireTestClient c = await r.open();
  c.send('resume', <String, Object?>{'code': code, 'seat_token': token});
  return c.next();
}

/// Starts the game from [host] (every seat must be filled) and drains.
Future<void> _start(_Rig r, _Seat host) async {
  host.c.send('start_game', <String, Object?>{});
  await receiveType(host.c, 'game_started', maxFrames: 12);
  await r.flushAll();
}

void _forceFinished(_Rig r, String code, {required int winner}) {
  final Room? room = r.h.registry.lookup(code);
  if (room == null) {
    fail('fixture: room $code must exist to be forced FINISHED');
  }
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

// ---------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------

class _Page {
  _Page(this.path, this.status, this.body);

  final String path;
  final int status;
  final String body;

  String get desc => 'GET $path -> $status, body[0..200]: '
      '${body.length > 200 ? body.substring(0, 200) : body}';
}

Future<_Page> _get(_Rig r, String path) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest req = await client
        .getUrl(Uri.parse('http://127.0.0.1:${r.h.server.port}$path'));
    final HttpClientResponse res = await req.close();
    final String body = await res.transform(utf8.decoder).join();
    return _Page(path, res.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

void main() {
  group('item 1: the link id', () {
    _scenario(
      'L1 link id shape, time part and uniqueness over 2000 creations',
      (_Rig r) async {
        final Set<String> ids = <String>{};
        final Set<String> randomParts = <String>{};
        for (int i = 0; i < 2000; i++) {
          if (i > 0 && i % 5 == 0) {
            // five creations per IP per hour is the limiter's own rule
            r.h.clock.advance(const Duration(minutes: 61));
          }
          final _Seat s = await _create(r, name: 'H$i');
          final Object? link = s.room['link_id'];
          expect(link, isA<String>(),
              reason: 'creation $i: snapshot.link_id must be a string, got '
                  '$link');
          final String id = link! as String;
          expect(_linkShape.hasMatch(id), isTrue,
              reason: 'creation $i: link_id "$id" must be base36 seconds, a '
                  '-, then six [a-z0-9]');
          final String timePart = id.split('-').first;
          final int nowSeconds = r.h.clock.now.millisecondsSinceEpoch ~/ 1000;
          expect(int.parse(timePart, radix: 36), nowSeconds,
              reason: 'creation $i: link_id "$id" time part must be the '
                  'creation time in whole seconds ($nowSeconds) in base 36');
          expect(id.contains(s.code.toLowerCase()), isFalse,
              reason: 'creation $i: link id "$id" must not contain the room '
                  'code ${s.code}');
          expect(ids.add(id), isTrue,
              reason: 'creation $i: link_id "$id" was issued twice');
          randomParts.add(id.split('-').last);
          await s.c.close();
          r.gone.add(s.c);
        }
        expect(ids.length, 2000, reason: '2000 distinct link ids');
        expect(randomParts.length, greaterThanOrEqualTo(1990),
            reason: 'the six random characters must come from a CSPRNG; got '
                'only ${randomParts.length} distinct of 2000');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    _scenario(
        'L2 five rooms created in one second share a time part but not '
        'the link id', (_Rig r) async {
      final List<String> ids = <String>[];
      for (int i = 0; i < 5; i++) {
        final _Seat s = await _create(r, name: 'H$i');
        ids.add(s.linkId);
      }
      expect(ids.map((String i) => i.split('-').first).toSet().length, 1,
          reason: 'the clock did not move, so the time part must be one '
              'value; got $ids');
      expect(ids.toSet().length, 5,
          reason: 'the random part must tell them apart; got $ids');
    });

    _scenario(
        'S1 a fresh room snapshot: guest_approval false, knocks empty, '
        'host via', (_Rig r) async {
      final _Seat host = await _create(r);
      expect(host.room['guest_approval'], false,
          reason: 'item 5: guest_approval defaults to false at creation; '
              'snapshot=${host.room}');
      expect(host.room['knocks'], isEmpty,
          reason: 'item 3: the host snapshot carries knocks, empty when '
              'none; got ${host.room['knocks']}');
      expect(_seatEntry(host.room, host.seat)['via'], 'host',
          reason: 'item 1: the creating seat has via "host"');
    });
  });

  group('item 2: join_room keys', () {
    _scenario('J1 a link join seats at once with approval off, via link',
        (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat g =
          await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      expect(_seatEntry(g.room, g.seat)['via'], 'link',
          reason: 'item 1: a seat taken by a tapped link has via "link"');
      expect(_seatEntry(g.room, host.seat)['via'], 'host');
      expect(g.room['link_id'], host.linkId);
    });

    _scenario('J2 a link join seats at once with approval ON, never a knock',
        (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await receiveType(host.c, 'room');
      final _Raw raw = await _joinRaw(
          r, <String, Object?>{'link': host.linkId}, 'G',
          install: _inst('g'));
      expect(raw.frame['t'], 'seat_assigned',
          reason: 'item 2: a link join seats at once whatever guest_approval '
              'says; got ${raw.frame['t']}: ${raw.frame['d']}');
      final Map<String, Object?> room = await raw.c.next();
      expect(
          _seatEntry(_d(room), _d(raw.frame)['seat']! as int)['via'], 'link');
      expect(_d(room)['guest_approval'], true);
    });

    _scenario('J3 a code join seats at once with approval off, via code',
        (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat g = await _join(r, <String, Object?>{'code': host.code}, 'G');
      expect(_seatEntry(g.room, g.seat)['via'], 'code',
          reason: 'item 1: a typed-code seat has via "code"');
    });

    _scenario(
        'J4 unknown, garbage, finished and reaped links are all '
        'NO_SUCH_ROOM, byte for byte alike', (_Rig r) async {
      final _Seat hostA = await _create(r, players: 2, name: 'A');
      await _join(r, <String, Object?>{'link': hostA.linkId}, 'GA');
      await _start(r, hostA);
      _forceFinished(r, hostA.code, winner: 0);
      final String finishedLink = hostA.linkId;

      final _Seat hostB = await _create(r, name: 'B');
      final String lobbyLink = hostB.linkId;

      final Map<String, Object?> unknown =
          (await _joinRaw(r, <String, Object?>{'link': 't5k2q9a-x7m3pd'}, 'X'))
              .frame;
      _err(unknown, 'NO_SUCH_ROOM', 'a well-formed link that never existed');
      final Map<String, Object?> baseline = _d(unknown);

      final Map<String, String> probes = <String, String>{
        'garbage': 'not a link at all',
        'empty': '',
        'a former room code': hostB.code,
        'finished, not yet reaped': finishedLink,
      };
      for (final MapEntry<String, String> p in probes.entries) {
        final Map<String, Object?> f =
            (await _joinRaw(r, <String, Object?>{'link': p.value}, 'X')).frame;
        _err(f, 'NO_SUCH_ROOM', 'item 2: ${p.key} ("${p.value}")');
        expect(_d(f), baseline,
            reason: 'item 2: the answer for ${p.key} must be identical to '
                'the answer for an unknown link so ids cannot be probed');
      }

      r.tick(const Duration(minutes: 61));
      expect(r.h.registry.lookup(hostB.code), isNull,
          reason: 'fixture: a LOBBY must be reaped 61 minutes after creation');
      for (final String link in <String>[lobbyLink, finishedLink]) {
        final Map<String, Object?> f =
            (await _joinRaw(r, <String, Object?>{'link': link}, 'X')).frame;
        _err(f, 'NO_SUCH_ROOM', 'item 2: reaped room link $link');
        expect(_d(f), baseline, reason: 'reaped link $link answer differs');
      }
    });

    _scenario(
        'J5 both keys or neither is BAD_FIELD; wrong install is '
        'BAD_FIELD on either shape', (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      final List<(String, Map<String, Object?>)> cases =
          <(String, Map<String, Object?>)>[
        (
          'both code and link',
          <String, Object?>{'code': host.code, 'link': host.linkId}
        ),
        ('neither code nor link', <String, Object?>{}),
        ('link of the wrong type', <String, Object?>{'link': 7}),
        ('code of the wrong type', <String, Object?>{'code': 7}),
      ];
      final WireTestClient c = await r.open();
      for (final (String, Map<String, Object?>) k in cases) {
        c.send('join_room', <String, Object?>{...k.$2, 'name': 'G'});
        _err(await c.next(), 'BAD_FIELD', 'item 2: ${k.$1}');
      }
      final Map<String, Object?> link = <String, Object?>{'link': host.linkId};
      final Map<String, Object?> code = <String, Object?>{'code': host.code};
      final Map<String, Object?> bad = <String, Object?>{
        'install 15 chars': 'a' * 15,
        'install 65 chars': 'a' * 65,
        'install with a bad character': 'abcdefghijklmnop!',
        'install with a space': 'abcdefghijklmnop qrs',
        'install not a string': 1234567890123456789,
      };
      for (final MapEntry<String, Object?> b in bad.entries) {
        for (final MapEntry<String, Map<String, Object?>> shape
            in <String, Map<String, Object?>>{
          'link': link,
          'code': code,
        }.entries) {
          c.send('join_room', <String, Object?>{
            ...shape.value,
            'name': 'G',
            'install': b.value
          });
          _err(await c.next(), 'BAD_FIELD',
              'item 2: ${b.key} on a ${shape.key} join');
        }
      }
      // nothing above may have seated anyone
      final List<Map<String, Object?>> hostFrames = await _sync(host.c);
      expect(_ofType(hostFrames, 'player_joined'), isEmpty,
          reason: 'a BAD_FIELD join must not seat anyone; host saw '
              '$hostFrames');
    });

    _scenario('J6 install of exactly 16 and exactly 64 characters is accepted',
        (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      await _join(r, <String, Object?>{'link': host.linkId}, 'G16',
          install: 'a' * 16);
      await _join(r, <String, Object?>{'code': host.code}, 'G64',
          install: 'B-_9' * 16);
    });
  });

  group('item 3: a typed code with approval on knocks', () {
    _scenario(
        'K1 knock: pending to the knocker, knock with seq to the host, '
        'the same seq as a snapshot to other seats, no seat taken',
        (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat g =
          await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      await _approval(host, true);
      await r.flushAll();

      final _Raw raw = await _joinRaw(
          r, <String, Object?>{'code': host.code}, 'Knocker',
          install: _inst('k'));
      expect(raw.frame['t'], 'knock_pending',
          reason: 'item 3: got ${raw.frame['t']}: ${raw.frame['d']}');
      _noSeq(raw.frame, 'knock_pending');
      expect(_d(raw.frame)['expires_ms'], 60000);

      final Map<String, Object?> hk = await receiveType(host.c, 'knock');
      _hasSeq(hk, 'knock');
      expect(_d(hk)['name'], 'Knocker');
      expect(_d(hk)['knock_id'], _d(raw.frame)['knock_id']);

      final Map<String, Object?> gRoom = await receiveType(g.c, 'room');
      expect(_d(gRoom)['seq'], _d(hk)['seq'],
          reason: 'item 3: other seated sockets get the same seq through a '
              'room snapshot as the host got on knock');
      expect(_d(gRoom)['knocks'], isEmpty,
          reason: 'item 3: knocks is shown to the host only; a non-host seat '
              'must see []; got ${_d(gRoom)['knocks']}');

      final Map<String, Object?> snap =
          await _resumeRoom(r, host.code, host.token);
      expect((snap['seats']! as List<Object?>).length, 2,
          reason:
              'a knocker holds no seat until accepted; seats=${snap['seats']}');
      final List<Object?> knocks = snap['knocks']! as List<Object?>;
      expect(knocks.length, 1, reason: 'host snapshot knocks: $knocks');
      final Map<String, Object?> k = knocks.single! as Map<String, Object?>;
      expect(k['knock_id'], _d(raw.frame)['knock_id']);
      expect(k['name'], 'Knocker');
      expect(k['expires_ms'], isA<int>());
      expect(k['expires_ms']! as int, inInclusiveRange(1, 60000));
    });

    _scenario(
        'K2 NO_SUCH_ROOM, ROOM_FULL and ROOM_STARTED come before a '
        'knock', (_Rig r) async {
      final _Seat host = await _create(r, players: 2);
      await _approval(host, true);
      await r.flushAll();
      _err((await _joinRaw(r, <String, Object?>{'code': 'ZZZZZZ'}, 'K')).frame,
          'NO_SUCH_ROOM', 'unknown code with approval on');
      await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      _err((await _joinRaw(r, <String, Object?>{'code': host.code}, 'K')).frame,
          'ROOM_FULL', 'a full room with approval on');
      await _start(r, host);
      _err((await _joinRaw(r, <String, Object?>{'code': host.code}, 'K')).frame,
          'ROOM_STARTED', 'a started room with approval on');
    });

    _scenario(
        'K3 accept seats on the lowest free seat, via approved: '
        'seat_assigned then room to the knocker, player_joined to the rest, '
        'knock_closed accepted with seq to the host', (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      final _Seat g =
          await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await r.flushAll();

      _answer(host, k, true);
      final Map<String, Object?> sa = await k.c.next();
      expect(sa['t'], 'seat_assigned',
          reason: 'item 4: the accepted knocker gets seat_assigned first; '
              'got ${sa['t']}: ${sa['d']}');
      final Map<String, Object?> room = await k.c.next();
      expect(room['t'], 'room', reason: 'then room; got $room');
      final int seat = _d(sa)['seat']! as int;
      expect(seat, isNot(host.seat));
      expect(seat, isNot(g.seat));
      // the lowest free seat: every free seat of this room is above or below
      // it only by the canonical order, so compare with the seats left
      final List<int> taken = <int>[host.seat, g.seat, seat];
      expect(taken.toSet().length, 3);
      expect(_seatEntry(_d(room), seat)['via'], 'approved');
      expect(_d(room)['knocks'], isEmpty);

      final List<Map<String, Object?>> hostFrames = await _sync(host.c);
      expect(_ofType(hostFrames, 'error'), isEmpty,
          reason: 'accepting must not error; host saw $hostFrames');
      final List<Map<String, Object?>> closed =
          _ofType(hostFrames, 'knock_closed');
      expect(closed.length, 1, reason: 'host frames: $hostFrames');
      expect(_d(closed.single)['outcome'], 'accepted');
      expect(_d(closed.single)['knock_id'], k.id);
      _hasSeq(closed.single, 'knock_closed');
      expect(_ofType(hostFrames, 'player_joined'), isNotEmpty,
          reason: 'item 4: everyone else gets player_joined; host saw '
              '$hostFrames');
      final List<Map<String, Object?>> gFrames = await _sync(g.c);
      expect(_ofType(gFrames, 'player_joined'), isNotEmpty,
          reason: 'item 4: the other seated guest gets player_joined; saw '
              '$gFrames');
    });

    _scenario('K3b accept picks the LOWEST free seat', (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      final _Seat a =
          await _join(r, <String, Object?>{'link': host.linkId}, 'A');
      final _Seat b =
          await _join(r, <String, Object?>{'link': host.linkId}, 'B');
      host.c.send('kick', <String, Object?>{'seat': a.seat});
      await receiveType(host.c, 'player_left');
      await r.flushAll();
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      _answer(host, k, true);
      final Map<String, Object?> sa = await k.c.next();
      expect(sa['t'], 'seat_assigned');
      expect(_d(sa)['seat'], a.seat,
          reason: 'item 4: lowest free seat: seat ${a.seat} (freed by the '
              'kick) is lower than the never-used seats; B holds ${b.seat}');
    });
  });

  group('item 4: closing a knock', () {
    _scenario(
        'K4 reject: knock_failed (no seq) to the knocker, knock_closed '
        'with seq to the host; an installer is then KNOCK_REFUSED but the '
        'link still works', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      _answer(host, k, false);

      final Map<String, Object?> kf = await receiveType(k.c, 'knock_failed');
      expect(_d(kf)['outcome'], 'rejected');
      expect(_d(kf)['knock_id'], k.id);
      _noSeq(kf, 'knock_failed');
      final Map<String, Object?> kc = await receiveType(host.c, 'knock_closed');
      expect(_d(kc)['outcome'], 'rejected');
      _hasSeq(kc, 'knock_closed');

      k.c.send('join_room', <String, Object?>{
        'code': host.code,
        'name': 'K',
        'install': _inst('k'),
      });
      _err(await k.c.next(), 'KNOCK_REFUSED',
          'item 4: a rejected installer knocking again by code');

      final _Raw other = await _joinRaw(
          r, <String, Object?>{'code': host.code}, 'Other',
          install: _inst('other'));
      expect(other.frame['t'], 'knock_pending',
          reason: 'a different install is not barred by the first '
              'knocker\'s rejection; got ${other.frame['t']}');

      k.c.send('join_room', <String, Object?>{
        'link': host.linkId,
        'name': 'K',
        'install': _inst('k'),
      });
      final Map<String, Object?> sa = await k.c.next();
      expect(sa['t'], 'seat_assigned',
          reason: 'item 4: a refusal bars only the typed-code path; the link '
              'must still seat; got ${sa['t']}: ${sa['d']}');
      final Map<String, Object?> room = await k.c.next();
      expect(_seatEntry(_d(room), _d(sa)['seat']! as int)['via'], 'link');
    });

    _scenario(
        'K5 reject of an IP-only knocker (no install): KNOCK_REFUSED by '
        'code afterwards, link still works', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K');
      _answer(host, k, false);
      await receiveType(k.c, 'knock_failed');
      await receiveType(host.c, 'knock_closed');

      k.c.send('join_room', <String, Object?>{'code': host.code, 'name': 'K'});
      _err(await k.c.next(), 'KNOCK_REFUSED',
          'item 4: an IP-only knocker, rejected, knocking again by code');
      final _Raw again =
          await _joinRaw(r, <String, Object?>{'code': host.code}, 'K2');
      _err(
          again.frame,
          'KNOCK_REFUSED',
          'item 4: with no install the bar is by IP, so a second no-install '
              'socket on the same IP is barred too');
      k.c.send(
          'join_room', <String, Object?>{'link': host.linkId, 'name': 'K'});
      expect((await k.c.next())['t'], 'seat_assigned',
          reason: 'the link must still seat an IP-only refused knocker');
    });

    _scenario('K6 a timed-out knocker is barred from knocking again by code',
        (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      r.tick(const Duration(seconds: 60));
      await receiveType(k.c, 'knock_failed');
      k.c.send('join_room', <String, Object?>{
        'code': host.code,
        'name': 'K',
        'install': _inst('k'),
      });
      _err(await k.c.next(), 'KNOCK_REFUSED',
          'item 4: a timed-out knocker knocking again by code');
    });

    _scenario(
        'K7 timeout: nothing at 59.999 s, knock_closed and knock_failed '
        'timeout at 60 s', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await r.flushAll();

      r.tick(const Duration(milliseconds: 59999));
      final List<Map<String, Object?>> hostEarly = await _sync(host.c);
      final List<Map<String, Object?>> knockerEarly = await _sync(k.c);
      expect(
          hostEarly.where((Map<String, Object?> f) =>
              f['t'] == 'knock_closed' || f['t'] == 'knock_failed'),
          isEmpty,
          reason: 'item 4: at 59.999 s the knock is still open; host saw '
              '$hostEarly');
      expect(knockerEarly, isEmpty,
          reason: 'at 59.999 s the knocker must hear nothing; saw '
              '$knockerEarly');

      r.tick(const Duration(milliseconds: 1));
      final Map<String, Object?> kc = await receiveType(host.c, 'knock_closed');
      expect(_d(kc)['outcome'], 'timeout',
          reason: 'item 4: at exactly 60 s the knock closes timeout');
      expect(_d(kc)['knock_id'], k.id);
      _hasSeq(kc, 'knock_closed');
      final Map<String, Object?> kf = await receiveType(k.c, 'knock_failed');
      expect(_d(kf)['outcome'], 'timeout');
      _noSeq(kf, 'knock_failed');

      _answer(host, k, true);
      _err(await host.c.next(), 'NO_SUCH_KNOCK',
          'item 4: answering a knock that timed out');
    });

    _scenario('K8 an accept at 59.999 s still seats the knocker',
        (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      r.tick(const Duration(milliseconds: 59999));
      _answer(host, k, true);
      final Map<String, Object?> f = await k.c.next();
      expect(f['t'], 'seat_assigned',
          reason: 'item 4: 59.999 s is inside the window; got ${f['t']}: '
              '${f['d']}');
    });

    _scenario(
        'K9 accept with no free seat left closes full, knocker gets '
        'ROOM_FULL', (_Rig r) async {
      final _Seat host = await _create(r, players: 2);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await _join(r, <String, Object?>{'link': host.linkId}, 'Linker');
      _answer(host, k, true);
      final Map<String, Map<String, Object?>> got =
          await _gather(k.c, <String>{'error', 'knock_failed'});
      _err(got['error']!, 'ROOM_FULL', 'item 4: no seat free at accept');
      expect(_d(got['knock_failed']!)['outcome'], 'full');
      final Map<String, Object?> kc = await receiveType(host.c, 'knock_closed');
      expect(_d(kc)['outcome'], 'full');
      _hasSeq(kc, 'knock_closed');
    });

    _scenario(
        'K9b start_game closes every still-open knock full: knock_closed '
        'with seq to the host, knock_failed (no seq) to the knocker',
        (_Rig r) async {
      final _Seat host = await _create(r, players: 2);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await _join(r, <String, Object?>{'link': host.linkId}, 'Linker');
      expect(_ofType(await _sync(k.c), 'knock_failed'), isEmpty,
          reason: 'item 11e: the knock stays open when the last seat fills');
      host.c.send('start_game', <String, Object?>{});
      final List<Map<String, Object?>> hostFrames =
          await drainUntil(host.c, 'knock_closed', maxFrames: 20);
      final Map<String, Object?> kc = hostFrames.last;
      expect(_d(kc)['outcome'], 'full',
          reason: 'item 11e: start_game closes every open knock full; host '
              'frames: $hostFrames');
      expect(_d(kc)['knock_id'], k.id);
      _hasSeq(kc, 'knock_closed');
      final Map<String, Object?> kf = await receiveType(k.c, 'knock_failed');
      expect(_d(kf)['outcome'], 'full');
      expect(_d(kf)['knock_id'], k.id);
      _noSeq(kf, 'knock_failed');
      _answer(host, k, true);
      final List<Map<String, Object?>> after = await _sync(host.c);
      expect(
          _ofType(after, 'error')
              .map((Map<String, Object?> f) => _d(f)['code']),
          contains('WRONG_PHASE'),
          reason: 'answering after the game started: $after');
    });

    _scenario('K10 withdrawn: the knocker\'s socket closing', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await k.c.close();
      r.gone.add(k.c);
      final Map<String, Object?> kc = await receiveType(host.c, 'knock_closed');
      expect(_d(kc)['outcome'], 'withdrawn');
      expect(_d(kc)['knock_id'], k.id);
      _hasSeq(kc, 'knock_closed');
      _answer(host, k, true);
      _err(await host.c.next(), 'NO_SUCH_KNOCK',
          'answering the knock of a socket that closed');
    });

    _scenario(
        'K10b withdrawn: the knocker sends leave_room, and may knock '
        'again afterwards', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      k.c.send('leave_room', <String, Object?>{});
      final Map<String, Object?> kc = await receiveType(host.c, 'knock_closed');
      expect(_d(kc)['outcome'], 'withdrawn',
          reason: 'item 4: leave_room by a knocker withdraws the knock');
      expect(_d(kc)['knock_id'], k.id);
      await _sync(k.c);
      k.c.send('join_room', <String, Object?>{
        'code': host.code,
        'name': 'K',
        'install': _inst('k'),
      });
      final Map<String, Object?> again = await k.c.next();
      expect(again['t'], 'knock_pending',
          reason: 'a withdrawn knock is closed, so the socket holds no open '
              'knock and a withdrawal bars nobody; got ${again['t']}: '
              '${again['d']}');
    });

    _scenario(
        'K11 switching approval off seats open knocks in arrival '
        'order up to the free seats, the rest close switched_off',
        (_Rig r) async {
      final _Seat host = await _create(r, players: 3);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k1 = await _knock(r, host, 'K1', install: _inst('k1'));
      final _Knock k2 = await _knock(r, host, 'K2', install: _inst('k2'));
      final _Knock k3 = await _knock(r, host, 'K3', install: _inst('k3'));
      await r.flushAll();

      await _approval(host, false);
      final Map<String, Object?> sa1 = await k1.c.next();
      final Map<String, Object?> sa2 = await k2.c.next();
      expect(sa1['t'], 'seat_assigned', reason: 'K1 arrived first: $sa1');
      expect(sa2['t'], 'seat_assigned', reason: 'K2 arrived second: $sa2');
      expect(_d(sa1)['seat']! as int, lessThan(_d(sa2)['seat']! as int),
          reason: 'item 5: arrival order, each on the lowest free seat');
      final Map<String, Map<String, Object?>> k3got =
          await _gather(k3.c, <String>{'error', 'knock_failed'});
      _err(k3got['error']!, 'ROOM_FULL', 'item 5: third knock, no seat');
      expect(_d(k3got['knock_failed']!)['outcome'], 'switched_off');

      final List<Map<String, Object?>> hostFrames = await _sync(host.c);
      final List<Map<String, Object?>> closed =
          _ofType(hostFrames, 'knock_closed');
      expect(
          closed
              .map((Map<String, Object?> f) =>
                  '${_d(f)['knock_id']}:${_d(f)['outcome']}')
              .toList(),
          <String>[
            '${k1.id}:accepted',
            '${k2.id}:accepted',
            '${k3.id}:switched_off',
          ],
          reason: 'item 5: knock_closed to the host in arrival order; host '
              'frames: $hostFrames');
      final Map<String, Object?> room = _d(_ofType(hostFrames, 'room').last);
      expect(room['guest_approval'], false);
      expect(room['knocks'], isEmpty);
      expect(_seatEntry(room, _d(sa1)['seat']! as int)['via'], 'approved');
      expect(_seatEntry(room, _d(sa2)['seat']! as int)['via'], 'approved');
    });

    _scenario(
        'K12 a fourth open knock is TOO_MANY_KNOCKS; closing one makes '
        'room for another', (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k1 = await _knock(r, host, 'K1', install: _inst('k1'));
      await _knock(r, host, 'K2', install: _inst('k2'));
      await _knock(r, host, 'K3', install: _inst('k3'));
      final _Raw fourth = await _joinRaw(
          r, <String, Object?>{'code': host.code}, 'K4',
          install: _inst('k4'));
      _err(fourth.frame, 'TOO_MANY_KNOCKS', 'item 3: the fourth open knock');
      expect(_ofType(await _sync(host.c), 'knock'), isEmpty,
          reason: 'a refused fourth knock must not reach the host');

      _answer(host, k1, false);
      await receiveType(host.c, 'knock_closed');
      fourth.c.send('join_room', <String, Object?>{
        'code': host.code,
        'name': 'K4',
        'install': _inst('k4'),
      });
      final Map<String, Object?> again = await fourth.c.next();
      expect(again['t'], 'knock_pending',
          reason: 'the limit is on OPEN knocks; one closed, so a new one '
              'fits; got ${again['t']}: ${again['d']}');
    });

    _scenario(
        'K13 a second join_room from a socket with an open knock is '
        'RATE_LIMITED and the first knock stays open', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      k.c.send('join_room', <String, Object?>{
        'code': host.code,
        'name': 'K',
        'install': _inst('k'),
      });
      _err(await k.c.next(), 'RATE_LIMITED',
          'item 3: a second join_room from a socket with an open knock');
      expect(_ofType(await _sync(host.c), 'knock'), isEmpty,
          reason: 'the refused second knock must not reach the host');
      _answer(host, k, true);
      expect((await k.c.next())['t'], 'seat_assigned',
          reason: 'the first knock must still be answerable');
    });
  });

  group('items 4 and 5: who may answer, when', () {
    _scenario('A1 answer_knock by a non-host is NOT_HOST', (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat g =
          await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await r.flushAll();
      g.c.send(
          'answer_knock', <String, Object?>{'knock_id': k.id, 'accept': true});
      _err(await g.c.next(), 'NOT_HOST', 'item 4: a seated non-host answering');
      expect(await _sync(k.c), isEmpty,
          reason: 'a refused answer must not seat the knocker');
    });

    _scenario('A2 answer_knock in PLAYING is WRONG_PHASE', (_Rig r) async {
      final _Seat host = await _create(r, players: 2);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      await _start(r, host);
      _answer(host, k, true);
      _err(await host.c.next(), 'WRONG_PHASE',
          'item 4: answer_knock once the game is PLAYING');
    });

    _scenario(
        'A3 unknown knock id and a doubly answered id are '
        'NO_SUCH_KNOCK; bad payloads are BAD_FIELD', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      host.c.send('answer_knock',
          <String, Object?>{'knock_id': 'nope-0000', 'accept': true});
      _err(await host.c.next(), 'NO_SUCH_KNOCK', 'a knock id never issued');

      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      _answer(host, k, false);
      await receiveType(host.c, 'knock_closed');
      _answer(host, k, true);
      _err(
          await host.c.next(), 'NO_SUCH_KNOCK', 'item 4: an already closed id');

      host.c.send(
          'answer_knock', <String, Object?>{'knock_id': 5, 'accept': true});
      _err(await host.c.next(), 'BAD_FIELD', 'knock_id not a string');
      host.c.send(
          'answer_knock', <String, Object?>{'knock_id': k.id, 'accept': 'yes'});
      _err(await host.c.next(), 'BAD_FIELD', 'accept not a bool');
      host.c.send('answer_knock', <String, Object?>{'accept': true});
      _err(await host.c.next(), 'BAD_FIELD', 'knock_id missing');
    });

    _scenario(
        'A4 set_guest_approval: NOT_HOST for a guest, BAD_FIELD for a '
        'non-bool, room with seq to everyone, works in PLAYING',
        (_Rig r) async {
      final _Seat host = await _create(r, players: 2);
      final _Seat g =
          await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      g.c.send('set_guest_approval', <String, Object?>{'enabled': true});
      _err(await g.c.next(), 'NOT_HOST', 'a guest switching approval');
      host.c.send('set_guest_approval', <String, Object?>{'enabled': 'on'});
      _err(await host.c.next(), 'BAD_FIELD', 'enabled not a bool');
      host.c.send('set_guest_approval', <String, Object?>{});
      _err(await host.c.next(), 'BAD_FIELD', 'enabled missing');
      await r.flushAll();

      await _approval(host, true);
      final Map<String, Object?> hr = await receiveType(host.c, 'room');
      expect(_d(hr)['guest_approval'], true);
      _hasSeq(hr, 'the answering room');
      final Map<String, Object?> gr = await receiveType(g.c, 'room');
      expect(_d(gr)['guest_approval'], true);
      expect(_d(gr)['seq'], _d(hr)['seq'],
          reason: 'item 5: broadcast with the same seq');
      expect(_d(gr)['seats'], hasLength(2),
          reason: 'item 5: switching on leaves seated players seated');

      await _start(r, host);
      await _approval(host, false);
      final Map<String, Object?> pr = await receiveType(host.c, 'room');
      expect(_d(pr)['guest_approval'], false,
          reason: 'item 5: any state of a live room, here PLAYING');
      expect(_d(pr)['state'], 'PLAYING');
    });
  });

  group('items 6 and 7: the lobby kick and the bars', () {
    _scenario(
        'Q1 lobby kick frees the seat; kicked gets kicked (no seq); '
        'room gets player_left; old token is dead; the socket holds no seat',
        (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat a = await _join(
          r, <String, Object?>{'link': host.linkId}, 'A',
          install: _inst('a'));
      final _Seat b = await _join(r, <String, Object?>{'code': host.code}, 'B');
      host.c.send('kick', <String, Object?>{'seat': a.seat});

      final Map<String, Object?> kicked = await receiveType(a.c, 'kicked');
      expect(_d(kicked), isEmpty, reason: 'item 6: kicked carries { }');
      expect(kicked['re'], isNull);
      final Map<String, Object?> pl = await receiveType(b.c, 'player_left');
      expect(_d(pl)['seat'], a.seat);
      _hasSeq(pl, 'player_left');
      await receiveType(host.c, 'player_left');
      await r.flushAll();

      a.c.send('start_game', <String, Object?>{});
      _err(await a.c.next(), 'BAD_SEAT_TOKEN',
          'item 6: the kicked socket holds no seat afterwards');
      a.c.send('resume',
          <String, Object?>{'code': host.code, 'seat_token': a.token});
      _err(await a.c.next(), 'BAD_SEAT_TOKEN',
          'item 6: resume on the kicked socket with the dead token');
      final Map<String, Object?> fresh =
          await _resumeFrame(r, host.code, a.token);
      _err(fresh, 'BAD_SEAT_TOKEN',
          'item 6: resume on a fresh socket with the dead token');

      final Map<String, Object?> snap =
          await _resumeRoom(r, host.code, host.token);
      expect(_hasSeatEntry(snap, a.seat), isFalse,
          reason: 'the kicked seat must be freed; seats=${snap['seats']}');
      expect(_hasSeatEntry(snap, b.seat), isTrue);
    });

    _scenario(
        'Q2 a kicked installer is KICKED by link and by code; a second '
        'player on the same IP with another install is not barred and takes '
        'the freed seat', (_Rig r) async {
      final _Seat host = await _create(r, players: 3);
      final _Seat a = await _join(
          r, <String, Object?>{'link': host.linkId}, 'A',
          install: _inst('a'));
      host.c.send('kick', <String, Object?>{'seat': a.seat});
      await receiveType(a.c, 'kicked');
      await receiveType(host.c, 'player_left');
      await r.flushAll();

      _err(
          (await _joinRaw(r, <String, Object?>{'link': host.linkId}, 'A',
                  install: _inst('a')))
              .frame,
          'KICKED',
          'item 7: rejoin by link with the kicked install');
      _err(
          (await _joinRaw(r, <String, Object?>{'code': host.code}, 'A',
                  install: _inst('a')))
              .frame,
          'KICKED',
          'item 7: rejoin by code with the kicked install');

      final _Seat c = await _join(
          r, <String, Object?>{'link': host.linkId}, 'C',
          install: _inst('c'));
      expect(c.seat, a.seat,
          reason: 'a different install on the same IP is not barred and takes '
              'the lowest free seat, the freed one');
    });

    _scenario(
        'Q3 a kicked socket with no install is barred by IP, by link '
        'and by code', (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat a =
          await _join(r, <String, Object?>{'link': host.linkId}, 'A');
      host.c.send('kick', <String, Object?>{'seat': a.seat});
      await receiveType(a.c, 'kicked');
      await receiveType(host.c, 'player_left');
      await r.flushAll();
      _err(
          (await _joinRaw(r, <String, Object?>{'link': host.linkId}, 'A'))
              .frame,
          'KICKED',
          'item 7: no install, rejoin by link, same IP');
      _err((await _joinRaw(r, <String, Object?>{'code': host.code}, 'A')).frame,
          'KICKED', 'item 7: no install, rejoin by code, same IP');
    });

    _scenario(
        'Q4 a kicked installer is KICKED by code even with approval on '
        '(no knock is made)', (_Rig r) async {
      final _Seat host = await _create(r);
      final _Seat a = await _join(
          r, <String, Object?>{'link': host.linkId}, 'A',
          install: _inst('a'));
      host.c.send('kick', <String, Object?>{'seat': a.seat});
      await receiveType(a.c, 'kicked');
      await receiveType(host.c, 'player_left');
      await _approval(host, true);
      await r.flushAll();
      _err(
          (await _joinRaw(r, <String, Object?>{'code': host.code}, 'A',
                  install: _inst('a')))
              .frame,
          'KICKED',
          'item 7: kicked, approval on, by code');
      expect(_ofType(await _sync(host.c), 'knock'), isEmpty,
          reason: 'a barred join must not knock');
    });

    _scenario(
        'Q5 kick errors: host kicking self and an empty seat are '
        'ILLEGAL_MOVE, a non-host is NOT_HOST', (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      final _Seat g =
          await _join(r, <String, Object?>{'link': host.linkId}, 'G');
      host.c.send('kick', <String, Object?>{'seat': host.seat});
      _err(await host.c.next(), 'ILLEGAL_MOVE', 'item 6: host kicks self');
      final int empty = <int>[0, 1, 2, 3]
          .firstWhere((int s) => s != host.seat && s != g.seat);
      host.c.send('kick', <String, Object?>{'seat': empty});
      _err(await host.c.next(), 'ILLEGAL_MOVE',
          'item 6: kick of empty seat $empty');
      g.c.send('kick', <String, Object?>{'seat': host.seat});
      _err(await g.c.next(), 'NOT_HOST', 'item 6: a guest kicks the host');
      await r.flushAll();
      final Map<String, Object?> snap =
          await _resumeRoom(r, host.code, host.token);
      expect(
          _hasSeatEntry(snap, host.seat) && _hasSeatEntry(snap, g.seat), isTrue,
          reason: 'no refused kick may remove a seat; seats=${snap['seats']}');
    });
  });

  group('snapshot, rematch and resume', () {
    _scenario('R1 a rematch keeps guest_approval, link_id and every via',
        (_Rig r) async {
      final _Seat host = await _create(r, players: 4);
      final _Seat a = await _join(r, <String, Object?>{'code': host.code}, 'A');
      await _approval(host, true);
      await r.flushAll();
      final _Seat b = await _join(
          r, <String, Object?>{'link': host.linkId}, 'B',
          install: _inst('b'));
      final _Knock k = await _knock(r, host, 'C', install: _inst('c'));
      _answer(host, k, true);
      final Map<String, Object?> csa = await k.c.next();
      expect(csa['t'], 'seat_assigned');
      final _Seat c = _Seat(k.c, _d(csa)['seat']! as int,
          _d(csa)['seat_token']! as String, _d(await k.c.next()));
      await r.flushAll();

      await _start(r, host);
      _forceFinished(r, host.code, winner: 0);
      for (final _Seat s in <_Seat>[host, a, b, c]) {
        s.c.send('rematch', <String, Object?>{});
        await r.flushAll();
      }

      final Map<String, Object?> snap =
          await _resumeRoom(r, host.code, host.token);
      expect(snap['link_id'], host.linkId,
          reason: 'item 1: link_id survives a rematch');
      expect(snap['code'], host.code);
      expect(snap['guest_approval'], true,
          reason: 'item 5: unchanged by a rematch');
      final Map<int, String> want = <int, String>{
        host.seat: 'host',
        a.seat: 'code',
        b.seat: 'link',
        c.seat: 'approved',
      };
      want.forEach((int seat, String via) {
        expect(_seatEntry(snap, seat)['via'], via,
            reason: 'item 1: seat $seat keeps via "$via" across a rematch; '
                'seats=${snap['seats']}');
      });
    });

    _scenario(
        'R2 a seat accepted from a knock can resume, keeping via '
        'approved', (_Rig r) async {
      final _Seat host = await _create(r);
      await _approval(host, true);
      await r.flushAll();
      final _Knock k = await _knock(r, host, 'K', install: _inst('k'));
      _answer(host, k, true);
      final Map<String, Object?> sa = await k.c.next();
      await k.c.next();
      await r.flushAll();
      final int seat = _d(sa)['seat']! as int;
      final String token = _d(sa)['seat_token']! as String;

      final WireTestClient fresh = await r.open();
      fresh.send(
          'resume', <String, Object?>{'code': host.code, 'seat_token': token});
      final Map<String, Object?> rsa = await fresh.next();
      expect(rsa['t'], 'seat_assigned',
          reason: 'resume of an approved seat; got ${rsa['t']}: ${rsa['d']}');
      expect(_d(rsa)['seat'], seat);
      final Map<String, Object?> room = await fresh.next();
      expect(room['t'], 'room');
      expect(_seatEntry(_d(room), seat)['via'], 'approved',
          reason: 'item 1: a seat keeps its via across a resume');
      expect(_seatEntry(_d(room), seat)['connected'], true);
      expect(_d(room)['link_id'], host.linkId);
    });
  });

  group('item 9: the /r/<id> routes', () {
    _scenario(
        'W1 a live link id serves the invite page with the link id and '
        'not the code; everything else serves one ended page', (_Rig r) async {
      final _Seat fin = await _create(r, players: 2, name: 'F');
      await _join(r, <String, Object?>{'link': fin.linkId}, 'FG');
      await _start(r, fin);
      _forceFinished(r, fin.code, winner: 0);
      final _Page finBefore = await _get(r, '/r/${fin.linkId}');

      final _Seat lobby = await _create(r, name: 'L');
      final _Page lobbyBefore = await _get(r, '/r/${lobby.linkId}');
      expect(lobbyBefore.status, 200, reason: lobbyBefore.desc);

      r.tick(const Duration(minutes: 61));
      final _Seat live = await _create(r, name: 'Live');

      final _Page livePage = await _get(r, '/r/${live.linkId}');
      expect(livePage.status, 200,
          reason: 'item 9: a live link id serves the invite page; '
              '${livePage.desc}');
      expect(livePage.body.contains(live.linkId), isTrue,
          reason: 'item 9: the page carries the link id; ${livePage.desc}');
      expect(livePage.body.toUpperCase().contains(live.code), isFalse,
          reason: 'item 9: the page carries the link id, not the code '
              '${live.code}; ${livePage.desc}');

      // Ruling 11(c): an id of the link shape that is not live serves what a
      // well-formed unknown code serves today (200); anything not of that
      // shape is 404 as today. Neither ever serves a room.
      final Map<String, String> shaped = <String, String>{
        'a never-issued well-formed id': 't5k2q9a-x7m3pd',
        'the finished room, reaped': fin.linkId,
        'the lobby room, reaped': lobby.linkId,
      };
      final Map<String, String> unshaped = <String, String>{
        'garbage with a dash': 'zzzz-garbage',
        'a very long garbage id': 'x' * 60,
        'the live room\'s former code (upper)': live.code,
        'the live room\'s former code (lower)': live.code.toLowerCase(),
      };
      final Map<String, _Page> pages = <String, _Page>{};
      for (final MapEntry<String, String> e in shaped.entries) {
        pages[e.key] = await _get(r, '/r/${e.value}');
      }
      final _Page base = pages['a never-issued well-formed id']!;
      for (final MapEntry<String, _Page> e in pages.entries) {
        expect(e.value.status, 200,
            reason: 'item 11c: ${e.key} is link-shaped and not live, so it '
                'serves the ended page with the status a well-formed unknown '
                'code serves today (200); ${e.value.desc}');
        final String id = e.value.path.substring(3);
        expect(e.value.body.replaceAll(id, '<<ID>>'),
            base.body.replaceAll('t5k2q9a-x7m3pd', '<<ID>>'),
            reason: 'item 9: ${e.key} must serve the same ended page as '
                'any unknown id, so ids cannot be probed');
        expect(e.value.body.contains(live.linkId), isFalse,
            reason: 'the ended page must never carry a live room\'s link id');
      }
      final Map<String, _Page> cut = <String, _Page>{};
      for (final MapEntry<String, String> e in unshaped.entries) {
        cut[e.key] = await _get(r, '/r/${e.value}');
      }
      final _Page cutBase = cut.values.first;
      for (final MapEntry<String, _Page> e in cut.entries) {
        expect(e.value.status, 404,
            reason: 'item 11c: ${e.key} is not of the link shape, so it is '
                '404 as today; ${e.value.desc}');
        expect(e.value.body, cutBase.body,
            reason: 'item 11c: every non-shaped id serves the same page; '
                '${e.key} differs; ${e.value.desc}');
        expect(e.value.body.contains(live.linkId), isFalse,
            reason: 'a non-shaped id must never serve a live room');
        expect(e.value.body.toUpperCase().contains(live.code), isFalse,
            reason: 'the former code ${live.code} must never serve a room; '
                '${e.value.desc}');
      }
      expect(base.body, isNot(livePage.body),
          reason: 'the ended page must differ from the live invite page');
      expect(finBefore.status, 200);
      expect(finBefore.body.replaceAll(fin.linkId, '<<ID>>'),
          base.body.replaceAll('t5k2q9a-x7m3pd', '<<ID>>'),
          reason: 'item 9: a finished (not yet reaped) room serves the '
              'ended page too; ${finBefore.desc}');
    });
  });
}
