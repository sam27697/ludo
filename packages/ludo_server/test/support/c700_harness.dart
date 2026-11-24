// Shared rig for the order C-700t suites (docs/PROTOCOL.md section 33: open
// rooms, the waiting line, join routes, strikes by route, the host's kick in
// PLAYING). Used by c700_open_rooms_line_test.dart,
// c700_route_strikes_test.dart and c700_kick_in_play_test.dart.
//
// Built as c684_short_codes_strikes_test.dart builds its rig: a real
// WireServer on a loopback port, a FakeClock injected into the registry, the
// rate limiter and the server, the automatic sweep off, and every socket
// presenting its own address through a trusted X-Forwarded-For so that each
// person in a scenario is a distinct IP. Nothing here reads the
// implementation of section 33; every frame is built and read as JSON.
//
// Waiting: nothing sleeps for a fixed time. "Nothing else arrived" is proved
// with a ping barrier (`C700Client.sync`): the server answers one socket's
// frames in order, so every frame queued for it before the pong is read
// before the pong. A state the server reaches on its own (a closed socket
// noticed, a store file rewritten) is waited on as a bounded condition.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

const String c700Salt = 'c700-test-salt-0123456789-abcdefghijklmnop';

/// Section 33 item 3: `ticket` is 22 characters of base64url.
final RegExp c700TicketShape = RegExp(r'^[A-Za-z0-9_-]{22}$');

String c700Hmac(String value) =>
    Hmac(sha256, utf8.encode(c700Salt)).convert(utf8.encode(value)).toString();

Map<String, Object?> fd(Map<String, Object?> frame) =>
    (frame['d'] ?? <String, Object?>{}) as Map<String, Object?>;

String fdesc(Map<String, Object?> f) => '${f['t']}'
    '${f['t'] == 'error' ? ':${fd(f)['code']}' : ''} '
    '${jsonEncode(f['d'])}${f['re'] == null ? '' : ' re=${f['re']}'}';

String fdescAll(List<Map<String, Object?>> fs) =>
    fs.isEmpty ? '(nothing)' : fs.map(fdesc).join(' | ');

List<String> ftypes(List<Map<String, Object?>> fs) =>
    <String>[for (final Map<String, Object?> f in fs) f['t']! as String];

// ---------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------

class C700Client {
  C700Client._(this._ws, this.ip, this.label) {
    _ws.listen(
      (Object? raw) {
        final Map<String, Object?> f =
            jsonDecode(raw! as String) as Map<String, Object?>;
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(f);
        } else {
          _buf.add(f);
        }
      },
      onDone: () {
        closed = true;
        for (final Completer<Map<String, Object?>> w in _waiters) {
          w.completeError(StateError('socket of $label closed before a frame '
              'arrived'));
        }
        _waiters.clear();
      },
      onError: (Object e) {},
    );
  }

  final WebSocket _ws;
  final String ip;
  final String label;
  final List<Map<String, Object?>> _buf = <Map<String, Object?>>[];
  final List<Completer<Map<String, Object?>>> _waiters =
      <Completer<Map<String, Object?>>>[];
  int _n = 0;
  bool closed = false;

  static Future<C700Client> connect(Uri uri, String ip, String label) async {
    final WebSocket ws = await WebSocket.connect(uri.toString(),
        headers: <String, String>{'X-Forwarded-For': ip});
    return C700Client._(ws, ip, label);
  }

  /// Sends one frame and returns its id, so a reply's `re` can be compared.
  String send(String type, Map<String, Object?> data) {
    final String full =
        'c700-${++_n}-$label'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final String id = full.length > 64 ? full.substring(0, 64) : full;
    _ws.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': id,
      'd': data,
    }));
    return id;
  }

  Future<Map<String, Object?>> next({
    Duration timeout = const Duration(seconds: 4),
  }) {
    if (_buf.isNotEmpty) {
      return Future<Map<String, Object?>>.value(_buf.removeAt(0));
    }
    final Completer<Map<String, Object?>> c = Completer<Map<String, Object?>>();
    _waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      throw TestFailure('expected another frame on the socket of $label '
          '($ip) within $timeout and none arrived');
    });
  }

  /// Ping barrier: every frame queued for this socket before the pong.
  Future<List<Map<String, Object?>>> sync() async {
    final String id = send('ping', <String, Object?>{});
    final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
    for (int i = 0; i < 120; i++) {
      final Map<String, Object?> f = await next();
      if (f['t'] == 'pong' && f['re'] == id) {
        return frames;
      }
      frames.add(f);
    }
    throw TestFailure('no pong on $label within 120 frames; saw '
        '${fdescAll(frames)}');
  }

  Future<Map<String, Object?>> untilType(String type, {int max = 40}) async {
    final List<Map<String, Object?>> seen = <Map<String, Object?>>[];
    for (int i = 0; i < max; i++) {
      final Map<String, Object?> f = await next();
      if (f['t'] == type) {
        return f;
      }
      seen.add(f);
    }
    throw TestFailure('expected a "$type" frame on $label within $max '
        'frames; saw ${fdescAll(seen)}');
  }

  Future<void> close() async {
    if (_ws.readyState == WebSocket.open) {
      await _ws.close();
    }
  }
}

// ---------------------------------------------------------------------
// People and seats
// ---------------------------------------------------------------------

/// A device: an install id and the IP it connects from.
class Dev {
  Dev(this.tag, this.install, this.ip);

  final String tag;
  final String install;
  final String ip;
}

/// A seat held by a socket.
class Held {
  Held(this.c, this.seat, this.token, this.room);

  final C700Client c;
  final int seat;
  final String token;
  final Map<String, Object?> room;

  String get code => room['code']! as String;
  String get linkId => room['link_id']! as String;
}

class C700Rig {
  C700Rig(this.name, {this.ruleset = '2026-10', this.useStore = false});

  final String name;
  final String ruleset;
  final bool useStore;
  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 24, 12));
  final Directory dir = Directory.systemTemp.createTempSync('c700_');
  final List<C700Client> clients = <C700Client>[];
  late Uri uri;
  late RoomRegistry registry;
  late WireServer server;
  int _ipN = 0;
  int _instN = 0;

  File get storeFile => File('${dir.path}/strikes.json');

  Future<void> boot() async {
    registry = RoomRegistry(
      clock: clock,
      secure: Random.secure(),
      ruleset: ruleset,
      strikeStore: useStore
          ? StrikeStore(clock: clock, dir: dir.path, salt: c700Salt)
          : null,
    );
    server = WireServer(
      registry: registry,
      rateLimiter: RateLimiter(clock: clock),
      clock: clock,
      automaticTurnExpiry: false,
      trustedProxies: const <String>{'127.0.0.1'},
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    uri = Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');
  }

  String freshIp() {
    final int n = ++_ipN;
    return '10.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}';
  }

  String freshInstall(String tag) => 'inst-$tag-${++_instN}-0123456789';

  Dev dev(String tag, {String? ip}) =>
      Dev(tag, freshInstall(tag), ip ?? freshIp());

  Future<C700Client> open(String ip, String label) async {
    final C700Client c = await C700Client.connect(uri, ip, label);
    clients.add(c);
    return c;
  }

  /// Moves the fake clock and runs the one-second sweep and the reaper.
  void tick(Duration d) {
    clock.advance(d);
    server.runTurnExpiryOnce();
    registry.reap();
  }

  Future<void> dispose() async {
    for (final C700Client c in clients) {
      try {
        await c.close();
      } catch (_) {
        // a socket the server already closed
      }
    }
    await server.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // best effort
    }
  }

  // -------------------------------------------------------------------
  // Wire actions
  // -------------------------------------------------------------------

  /// create_room. [open] null leaves the key out. Returns the host's seat.
  Future<Held> host({
    bool? open,
    int players = 4,
    bool approval = false,
    String? install,
    String? ip,
    String name = 'Host',
  }) async {
    final C700Client c = await this.open(ip ?? freshIp(), 'host-$name');
    c.send('create_room', <String, Object?>{
      'name': name,
      'players': players,
      if (open != null) 'open': open,
      'install': install ?? freshInstall('host'),
    });
    final Map<String, Object?> sa = await c.next();
    if (sa['t'] != 'seat_assigned') {
      throw TestFailure('create_room (open=$open) by $name should answer '
          'seat_assigned first; got ${fdesc(sa)}');
    }
    final Map<String, Object?> room = await c.next();
    if (room['t'] != 'room') {
      throw TestFailure('create_room second frame should be room; got '
          '${fdesc(room)}');
    }
    if (approval) {
      c.send('set_guest_approval', <String, Object?>{'enabled': true});
      await c.sync();
    }
    return Held(
        c, fd(sa)['seat']! as int, fd(sa)['seat_token']! as String, fd(room));
  }

  /// A join_room that must seat at once. [key] is `{'link': ..}` or
  /// `{'code': ..}`. Every other seated socket is left unread.
  Future<Held> join(Map<String, Object?> key, Dev d,
      {String name = 'Guest'}) async {
    final C700Client c = await open(d.ip, '${d.tag}-join');
    c.send('join_room', <String, Object?>{
      ...key,
      'name': name,
      'install': d.install,
    });
    final Map<String, Object?> f = await c.next();
    if (f['t'] != 'seat_assigned') {
      throw TestFailure('join_room $key by ${d.tag} should seat at once; got '
          '${fdesc(f)}');
    }
    final Map<String, Object?> room = await c.untilType('room');
    return Held(
        c, fd(f)['seat']! as int, fd(f)['seat_token']! as String, fd(room));
  }

  /// An approved seat: approval must be on; [d] knocks by code, the host
  /// accepts.
  Future<Held> joinApproved(Held h, Dev d, {String name = 'Guest'}) async {
    final C700Client c = await open(d.ip, '${d.tag}-knock');
    c.send('join_room', <String, Object?>{
      'code': h.code,
      'name': name,
      'install': d.install,
    });
    final Map<String, Object?> f = await c.next();
    if (f['t'] != 'knock_pending') {
      throw TestFailure('a code join with approval on must answer '
          'knock_pending; got ${fdesc(f)}');
    }
    final Map<String, Object?> hk = await h.c.untilType('knock');
    h.c.send('answer_knock', <String, Object?>{
      'knock_id': fd(hk)['knock_id'],
      'accept': true,
    });
    final Map<String, Object?> sa = await c.untilType('seat_assigned');
    final Map<String, Object?> room = await c.untilType('room');
    await h.c.sync();
    return Held(
        c, fd(sa)['seat']! as int, fd(sa)['seat_token']! as String, fd(room));
  }

  /// Sends find_game on [c] (a new socket of [d] when null) and returns the
  /// socket, the message id and the first frame back.
  Future<(C700Client, String, Map<String, Object?>)> find(
    Dev d, {
    C700Client? on,
    String name = 'Stranger',
    String? ticket,
    String? install,
  }) async {
    final C700Client c = on ?? await open(d.ip, '${d.tag}-find');
    final String id = c.send('find_game', <String, Object?>{
      'name': name,
      'install': install ?? d.install,
      if (ticket != null) 'ticket': ticket,
    });
    return (c, id, await c.next());
  }

  /// find_game that must be answered `queued` at [position]; returns the
  /// socket and the ticket.
  Future<(C700Client, String)> queue(
    Dev d,
    int position, {
    C700Client? on,
    String name = 'Stranger',
    String? ticket,
    String? install,
    required String row,
  }) async {
    final (C700Client c, String id, Map<String, Object?> f) =
        await find(d, on: on, name: name, ticket: ticket, install: install);
    expectQueued(f,
        position: position, re: id, row: row, what: 'find_game by ${d.tag}');
    return (c, fd(f)['ticket']! as String);
  }

  /// find_game that must seat at once (item 3, first branch): seat_assigned
  /// then room with `re`.
  Future<Held> findSeat(
    Dev d, {
    C700Client? on,
    String name = 'Stranger',
    required String row,
  }) async {
    final (C700Client c, String id, Map<String, Object?> sa) =
        await find(d, on: on, name: name);
    if (sa['t'] != 'seat_assigned') {
      throw TestFailure('$row: section 33 item 3: find_game by ${d.tag} with '
          'a matchable room open should seat at once (seat_assigned then '
          'room); got ${fdesc(sa)}');
    }
    final Map<String, Object?> room = await c.next();
    expect(room['t'], 'room',
        reason: '$row: item 3: seat_assigned must be followed by room; got '
            '${fdesc(room)}');
    expect(room['re'], id,
        reason: '$row: item 3: the room that answers find_game carries re '
            '($id); got ${fdesc(room)}');
    return Held(
        c, fd(sa)['seat']! as int, fd(sa)['seat_token']! as String, fd(room));
  }

  /// Starts the game from [h]; reads every socket in [all] up to its
  /// opening turn. Returns the opening turn seat.
  Future<int> start(Held h, List<C700Client> all) async {
    h.c.send('start_game', <String, Object?>{});
    int? turn;
    for (final C700Client c in all) {
      final Map<String, Object?> gs = await c.untilType('game_started');
      turn = fd(gs)['turn']! as int;
      await c.untilType('turn');
    }
    for (final C700Client c in all) {
      await c.sync();
    }
    return turn!;
  }

  /// Waits, bounded, until the registry shows [seat] of [code] disconnected.
  Future<void> untilDown(String code, int seat) async {
    for (int i = 0; i < 400; i++) {
      final Room? room = registry.lookup(code);
      if (room != null &&
          room.seats.any((Seat s) => s.seat == seat && !s.connected)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TestFailure('fixture: the server never noticed seat $seat of room '
        '$code going down');
  }

  /// strikes.json as text, waiting (bounded) for [ready].
  Future<String> fileText({bool Function(String)? ready}) async {
    String text = '';
    for (int i = 0; i < 300; i++) {
      text = storeFile.existsSync() ? storeFile.readAsStringSync() : '';
      if (text.isNotEmpty && (ready == null || ready(text))) {
        return text;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return text;
  }
}

/// Rewrites the engine state of [code]: [seat] on turn awaiting a roll, or
/// with [queue] awaiting a move, with [tokens] rows replaced. The segment
/// restarts at the fake clock's present.
void forceTurn(
  C700Rig r,
  String code, {
  required int seat,
  List<int>? queue,
  Map<int, List<int>>? tokens,
}) {
  final Room room = r.registry.lookup(code)!;
  final Map<String, Object?> json = room.game!.toJson();
  json['currentSeat'] = seat;
  json['phase'] = queue == null ? 'awaitRoll' : 'awaitMove';
  json['queue'] = queue ?? <int>[];
  json['sixes'] = 0;
  if (json.containsKey('releaseOwed')) {
    json['releaseOwed'] = false;
  }
  if (tokens != null) {
    final List<Object?> rows = json['tokens']! as List<Object?>;
    tokens.forEach((int s, List<int> row) => rows[s] = row);
  }
  room.game = engine.GameState.fromJson(json);
  room.turnSegmentStartedAt = r.clock.now;
}

// ---------------------------------------------------------------------
// Scenario wrapper and assertions
// ---------------------------------------------------------------------

void c700Scenario(
  String file,
  String name,
  Future<void> Function(C700Rig r) body, {
  String ruleset = '2026-10',
  bool useStore = false,
  Timeout? timeout,
}) {
  test(name, () async {
    final C700Rig r = C700Rig(name, ruleset: ruleset, useStore: useStore);
    final String repro = 'scenario: "$name" (RULESET=$ruleset in process). '
        'Deterministic: fake clock, fresh IPs and installs, no seed. '
        'Reproduce with: cd packages/ludo_server && dart test $file -n '
        '"$name"';
    try {
      await r.boot();
      await body(r);
    } on TestFailure catch (e) {
      throw TestFailure('${e.message}\n$repro');
    } on Object catch (e, s) {
      throw TestFailure('scenario died with ${e.runtimeType}: $e\n$s\n$repro');
    } finally {
      await r.dispose();
    }
  }, timeout: timeout);
}

void expectError(Map<String, Object?> f, String code, String because) {
  if (f['t'] != 'error') {
    throw TestFailure('$because: expected error $code, got ${fdesc(f)}');
  }
  if (fd(f)['code'] != code) {
    throw TestFailure('$because: expected error $code, got error '
        '${fd(f)['code']} (message "${fd(f)['message']}")');
  }
}

/// Section 33 item 3: `queued` `{ "ticket", "position" }`, no `seq`; `re`
/// equal to [re] when it answers a find_game, absent when [re] is null.
void expectQueued(
  Map<String, Object?> f, {
  required int position,
  required String? re,
  required String row,
  required String what,
  String? ticket,
}) {
  if (f['t'] != 'queued') {
    throw TestFailure('$row: $what: expected queued {ticket, position: '
        '$position}, got ${fdesc(f)}');
  }
  final Map<String, Object?> d = fd(f);
  expect(d.keys.toSet(), <String>{'ticket', 'position'},
      reason: '$row: $what: queued carries exactly ticket and position (no '
          'seq); got ${fdesc(f)}');
  expect(d['ticket'], isA<String>(),
      reason: '$row: $what: queued.ticket; got ${fdesc(f)}');
  expect(c700TicketShape.hasMatch(d['ticket']! as String), isTrue,
      reason: '$row: $what: ticket must be 22 characters of base64url; got '
          '"${d['ticket']}"');
  if (ticket != null) {
    expect(d['ticket'], ticket,
        reason: '$row: $what: the same ticket expected; got ${fdesc(f)}');
  }
  expect(d['position'], position,
      reason: '$row: $what: queued.position expected $position; got '
          '${fdesc(f)}');
  expect(f['re'], re,
      reason: '$row: $what: queued re expected ${re ?? 'absent'}; got '
          '${fdesc(f)}');
}

/// Item 4: a seat given from the line: seat_assigned then room, neither
/// with `re`. Returns the seat.
Future<Held> expectSeatedFromLine(
  C700Client c, {
  required String row,
  required String what,
  String? code,
  int? seat,
}) async {
  final Map<String, Object?> sa = await c.next();
  if (sa['t'] != 'seat_assigned') {
    throw TestFailure('$row: $what: expected seat_assigned (seated from the '
        'line), got ${fdesc(sa)}');
  }
  final Map<String, Object?> room = await c.next();
  expect(room['t'], 'room',
      reason: '$row: $what: seat_assigned must be followed by room; got '
          '${fdesc(room)}');
  expect(sa['re'], isNull,
      reason: '$row: $what: item 4: seat_assigned from the line carries no '
          're; got ${fdesc(sa)}');
  expect(room['re'], isNull,
      reason: '$row: $what: item 4: room from the line carries no re; got '
          '${fdesc(room)}');
  if (code != null) {
    expect(fd(room)['code'], code,
        reason: '$row: $what: seated in room $code; got room '
            '${fd(room)['code']}');
  }
  if (seat != null) {
    expect(fd(sa)['seat'], seat,
        reason: '$row: $what: lowest free seat $seat expected; got '
            '${fdesc(sa)}');
  }
  return Held(
      c, fd(sa)['seat']! as int, fd(sa)['seat_token']! as String, fd(room));
}

Map<String, Object?> seatOf(Map<String, Object?> room, int seat) {
  for (final Object? s in room['seats']! as List<Object?>) {
    final Map<String, Object?> m = s! as Map<String, Object?>;
    if (m['seat'] == seat) {
      return m;
    }
  }
  throw TestFailure('seat $seat absent from snapshot seats: ${room['seats']}');
}

List<int> seatNumbers(Map<String, Object?> room) => <int>[
      for (final Object? s in room['seats']! as List<Object?>)
        (s! as Map<String, Object?>)['seat']! as int
    ]..sort();

/// A fresh socket resumes [token] in [code]; returns the room `d`.
Future<Map<String, Object?>> resumeRoom(
    C700Rig r, String code, String token, String label) async {
  final C700Client c = await r.open(r.freshIp(), label);
  c.send('resume', <String, Object?>{'code': code, 'seat_token': token});
  final Map<String, Object?> sa = await c.next();
  if (sa['t'] != 'seat_assigned') {
    throw TestFailure('resume of $code should answer seat_assigned; got '
        '${fdesc(sa)}');
  }
  final Map<String, Object?> room = await c.next();
  expect(room['t'], 'room', reason: 'resume second frame; got ${fdesc(room)}');
  return fd(room);
}
