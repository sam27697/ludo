// Order C-684t: tests for docs/PROTOCOL.md section 32 (short room codes, the
// strike ladder, CODE_BANNED, the IP block, the keyed strike store), written
// from the section alone against a real WireServer on a real socket with a
// fake clock and a temporary strike directory, plus a few cases against a real
// server process. Nothing here reads the implementation.
//
// Seams assumed (the lib that implements section 32 is written in parallel):
//
//   S1  `package:ludo_server/src/strike_store.dart` declares `StrikeStore`.
//   S2  `StrikeStore({required Clock clock, String? dir, String? salt})`:
//       a synchronous constructor. `dir` and `salt` null is the in-memory
//       store with a random salt. `dir` set loads `<dir>/strikes.json`.
//       `dir` set with a missing or shorter-than-32 `salt` throws, and the
//       thrown object's toString() names LUDO_STRIKE_SALT.
//   S3  `RoomRegistry(..., StrikeStore? strikeStore)`: a named argument. Left
//       out, the registry holds a private in-memory store. The client IP of a
//       socket reaches the registry through the existing wire path, so no
//       test passes an IP to the registry.
//   S4  The keyed hash of an install or an IP is lower-case hex of
//       HMAC-SHA256(key = utf8(salt), message = utf8(the raw string)), the IP
//       being the dotted text a trusted X-Forwarded-For gave. Tests recompute
//       it and look for it as a substring of strikes.json, never at a JSON
//       path, so the file's layout is not pinned.
//   S5  The strike housekeeping rides the sweep the harness already drives:
//       `WireServer.runTurnExpiryOnce` and `RoomRegistry.reap`, both run by
//       `_Rig.tick` after the fake clock moves.
//   S6  A rewritten store is on disk by the time the frame that caused the
//       change has been answered, or within the bounded condition wait in
//       `_fileText`. The temporary file leaves nothing behind.
//
// Determinism: every scenario has its own FakeClock and temp directory. Room
// codes are deterministic now, so nothing here depends on a seed; a failure
// names its scenario and the command that re-runs it.
//
// Waiting: no sleeps. "Nothing else arrived" uses a ping barrier (`sync`); a
// state the server reaches on its own is waited on as a condition (`_until`).
//
// Where the section is open the reading taken is marked AMBIGUITY and listed
// in the report.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ludo_server/ludo_server.dart';
import 'package:ludo_server/src/strike_store.dart';
import 'package:test/test.dart';

const String _file = 'test/c684_short_codes_strikes_test.dart';

String _repro(String name) =>
    'scenario: "$name". Deterministic: fake clock, no seed. Reproduce with: '
    'cd packages/ludo_server && dart test $_file -n "$name"';

const String _salt = 'c684-test-salt-0123456789-abcdefghijklmnop';
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTUVWXYZ';

const Duration _h24 = Duration(hours: 24);
const Duration _d7 = Duration(days: 7);
const Duration _d30 = Duration(days: 30);
const Duration _d730 = Duration(days: 730);
const Duration _s1 = Duration(seconds: 1);

/// Code number [n] in the section's order: base 33, no leading zero, `0` for 0.
String _codeAt(int n) {
  if (n == 0) {
    return '0';
  }
  final StringBuffer out = StringBuffer();
  final List<String> digits = <String>[];
  int v = n;
  while (v > 0) {
    digits.add(_alphabet[v % 33]);
    v ~/= 33;
  }
  for (final String s in digits.reversed) {
    out.write(s);
  }
  return out.toString();
}

String _hmacHex(String salt, String value) =>
    Hmac(sha256, utf8.encode(salt)).convert(utf8.encode(value)).toString();

// ---------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------

Map<String, Object?> _d(Map<String, Object?> frame) =>
    (frame['d'] ?? <String, Object?>{}) as Map<String, Object?>;

class _C {
  _C._(this._ws, this.ip) {
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
          w.completeError(StateError('socket closed before a frame arrived'));
        }
        _waiters.clear();
      },
      onError: (Object e) {},
    );
  }

  final WebSocket _ws;
  final String ip;
  final List<Map<String, Object?>> _buf = <Map<String, Object?>>[];
  final List<Completer<Map<String, Object?>>> _waiters =
      <Completer<Map<String, Object?>>>[];
  int _n = 0;
  bool closed = false;

  static Future<_C> connect(Uri uri, String ip) async {
    final WebSocket ws = await WebSocket.connect(uri.toString(),
        headers: <String, String>{'X-Forwarded-For': ip});
    return _C._(ws, ip);
  }

  void send(String type, Map<String, Object?> data) {
    _ws.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': 'c684-msg-${++_n}',
      'd': data,
    }));
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
      throw TestFailure('expected another frame on the socket of $ip within '
          '$timeout and none arrived');
    });
  }

  Future<Map<String, Object?>?> nextOrNull() async {
    if (_buf.isNotEmpty) {
      return _buf.removeAt(0);
    }
    final Completer<Map<String, Object?>> c = Completer<Map<String, Object?>>();
    _waiters.add(c);
    try {
      return await c.future.timeout(const Duration(milliseconds: 150));
    } on TimeoutException {
      _waiters.remove(c);
      return null;
    }
  }

  /// Ping barrier: every frame queued for this socket before the pong.
  Future<List<Map<String, Object?>>> sync() async {
    send('ping', <String, Object?>{});
    final List<Map<String, Object?>> frames = <Map<String, Object?>>[];
    for (int i = 0; i < 80; i++) {
      final Map<String, Object?> f = await next();
      if (f['t'] == 'pong') {
        return frames;
      }
      frames.add(f);
    }
    throw TestFailure('no pong within 80 frames; saw $frames');
  }

  Future<Map<String, Object?>> untilType(String type, {int max = 40}) async {
    final List<String> seen = <String>[];
    for (int i = 0; i < max; i++) {
      final Map<String, Object?> f = await next();
      if (f['t'] == type) {
        return f;
      }
      seen.add('${f['t']}${f['t'] == 'error' ? ':${_d(f)['code']}' : ''}');
    }
    throw TestFailure('expected a "$type" frame within $max frames; saw $seen');
  }

  Future<void> close() async {
    if (_ws.readyState == WebSocket.open) {
      await _ws.close();
    }
  }
}

// ---------------------------------------------------------------------
// World: the sockets, minted names and the wire-level actions
// ---------------------------------------------------------------------

class _Dev {
  _Dev(this.install, this.ip);

  final String install;
  final String ip;
}

class _Host {
  _Host(this.c, this.seat, this.token, this.room, this.install, this.ip);

  final _C c;
  final int seat;
  final String token;
  final Map<String, Object?> room;
  final String? install;
  final String ip;

  String get code => room['code']! as String;
  String get linkId => room['link_id']! as String;
}

class _Joined {
  _Joined(this.c, this.seat, this.token, this.room);

  final _C c;
  final int seat;
  final String token;
  final Map<String, Object?> room;
}

class _World {
  late Uri uri;
  final List<_C> clients = <_C>[];
  final Set<String> minted = <String>{};
  int _ipN = 0;
  int _instN = 0;

  String freshIp() {
    final int n = ++_ipN;
    final String ip = '10.${(n >> 16) & 255}.${(n >> 8) & 255}.${n & 255}';
    minted.add(ip);
    return ip;
  }

  String freshInstall(String tag) {
    final String s = 'inst-$tag-${++_instN}-0123456789';
    minted.add(s);
    return s;
  }

  _Dev dev(String tag, {String? ip}) =>
      _Dev(freshInstall(tag), ip ?? freshIp());

  Future<_C> open(String ip) async {
    final _C c = await _C.connect(uri, ip);
    clients.add(c);
    return c;
  }

  Future<void> closeClients() async {
    for (final _C c in clients) {
      try {
        await c.close();
      } catch (_) {
        // a socket the server already closed
      }
    }
    clients.clear();
  }

  Future<Map<String, Object?>> getJson(String path) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse('http://127.0.0.1:${uri.port}$path'));
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      return <String, Object?>{'status': res.statusCode, 'body': body};
    } finally {
      client.close(force: true);
    }
  }

  /// A host: create_room (with [install] when given) and, with [approval],
  /// guest approval switched on.
  Future<_Host> host({
    String? install,
    String? ip,
    int players = 3,
    bool approval = false,
    bool withInstall = true,
  }) async {
    final String hostIp = ip ?? freshIp();
    final String? inst = install ?? (withInstall ? freshInstall('host') : null);
    final _C c = await open(hostIp);
    c.send('create_room', <String, Object?>{
      'name': 'Host',
      'players': players,
      if (inst != null) 'install': inst,
    });
    final Map<String, Object?> sa = await c.next();
    if (sa['t'] != 'seat_assigned') {
      throw TestFailure('create_room (install=${inst != null}) from $hostIp '
          'should answer seat_assigned first; got ${sa['t']}: ${sa['d']}');
    }
    final Map<String, Object?> room = await c.next();
    if (room['t'] != 'room') {
      throw TestFailure('create_room second frame should be room; got $room');
    }
    if (approval) {
      c.send('set_guest_approval', <String, Object?>{'enabled': true});
      await c.sync();
    }
    return _Host(c, _d(sa)['seat']! as int, _d(sa)['seat_token']! as String,
        _d(room), inst, hostIp);
  }

  /// One join_room, first frame back. The socket stays open in [clients].
  Future<(_C, Map<String, Object?>)> joinRaw(
    Map<String, Object?> key, {
    String? install,
    String? ip,
    String name = 'Guest',
  }) async {
    final _C c = await open(ip ?? freshIp());
    c.send('join_room', <String, Object?>{
      ...key,
      'name': name,
      if (install != null) 'install': install,
    });
    return (c, await c.next());
  }

  /// A join that must seat at once.
  Future<_Joined> joinSeat(
    Map<String, Object?> key, {
    String? install,
    String? ip,
    String name = 'Guest',
  }) async {
    final (_C c, Map<String, Object?> f) =
        await joinRaw(key, install: install, ip: ip, name: name);
    if (f['t'] != 'seat_assigned') {
      throw TestFailure('join_room $key should seat at once; got ${f['t']}: '
          '${f['d']}');
    }
    final Map<String, Object?> room = await c.untilType('room');
    return _Joined(
        c, _d(f)['seat']! as int, _d(f)['seat_token']! as String, _d(room));
  }

  /// First frame of a typed-code join by [d] to [code]; the socket is closed.
  Future<Map<String, Object?>> tryCode(
    _Dev d,
    String code, {
    String? ip,
  }) async {
    final (_C c, Map<String, Object?> f) = await joinRaw(
        <String, Object?>{'code': code},
        install: d.install, ip: ip ?? d.ip);
    await c.close();
    return f;
  }

  /// Rejected knock: the struck device knocks, the host refuses. Returns the
  /// knocker's knock_failed `d`.
  Future<Map<String, Object?>> strikeReject(_Host h, _Dev d) async {
    final (_C c, Map<String, Object?> f) = await joinRaw(
        <String, Object?>{'code': h.code},
        install: d.install, ip: d.ip);
    if (f['t'] != 'knock_pending') {
      throw TestFailure('a code join with approval on must answer '
          'knock_pending; got ${f['t']}: ${f['d']}');
    }
    final Map<String, Object?> hk = await h.c.untilType('knock');
    h.c.send('answer_knock', <String, Object?>{
      'knock_id': _d(hk)['knock_id'],
      'accept': false,
    });
    final Map<String, Object?> failed = await c.untilType('knock_failed');
    await h.c.sync();
    await c.close();
    return _d(failed);
  }

  /// Kick of a seat held by [d]. [via] is `code` (approval off), `approved`
  /// (approval on, knock accepted) or `link`. Returns the kicked frame's `d`.
  Future<Map<String, Object?>> strikeKick(_Host h, _Dev d, String via) async {
    final _Joined j = await seatVia(h, d, via);
    return kick(h, j);
  }

  Future<_Joined> seatVia(_Host h, _Dev d, String via) async {
    if (via == 'link') {
      return joinSeat(<String, Object?>{'link': h.linkId},
          install: d.install, ip: d.ip);
    }
    if (via == 'code') {
      return joinSeat(<String, Object?>{'code': h.code},
          install: d.install, ip: d.ip);
    }
    final (_C c, Map<String, Object?> f) = await joinRaw(
        <String, Object?>{'code': h.code},
        install: d.install, ip: d.ip);
    if (f['t'] != 'knock_pending') {
      throw TestFailure('expected knock_pending, got ${f['t']}: ${f['d']}');
    }
    final Map<String, Object?> hk = await h.c.untilType('knock');
    h.c.send('answer_knock', <String, Object?>{
      'knock_id': _d(hk)['knock_id'],
      'accept': true,
    });
    final Map<String, Object?> sa = await c.untilType('seat_assigned');
    final Map<String, Object?> room = await c.untilType('room');
    await h.c.sync();
    return _Joined(
        c, _d(sa)['seat']! as int, _d(sa)['seat_token']! as String, _d(room));
  }

  Future<Map<String, Object?>> kick(_Host h, _Joined j) async {
    h.c.send('kick', <String, Object?>{'seat': j.seat});
    final Map<String, Object?> kicked = await j.c.untilType('kicked');
    await h.c.sync();
    return _d(kicked);
  }
}

// ---------------------------------------------------------------------
// Rig: an in-process server on a fake clock
// ---------------------------------------------------------------------

class _Rig extends _World {
  _Rig(this.name, {this.useStore = true, this.ruleset = '2026-10'});

  final String name;
  final bool useStore;
  final String ruleset;
  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 22, 12));
  final Directory dir = Directory.systemTemp.createTempSync('c684_');
  final List<String> logs = <String>[];
  late RoomRegistry registry;
  late WireServer server;

  File get storeFile => File('${dir.path}/strikes.json');

  Future<void> boot() async {
    registry = RoomRegistry(
      clock: clock,
      secure: Random.secure(),
      ruleset: ruleset,
      strikeStore: useStore
          ? StrikeStore(clock: clock, dir: dir.path, salt: _salt)
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

  Future<void> restart() async {
    await closeClients();
    await server.close();
    await boot();
  }

  /// Moves the fake clock and runs the sweeps that read it.
  void tick(Duration d) {
    clock.advance(d);
    server.runTurnExpiryOnce();
    registry.reap();
  }

  int get nowMs => clock.now.millisecondsSinceEpoch;

  /// strikes.json as text, waiting (bounded, on the condition) for it to
  /// satisfy [ready] when given.
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

  Future<void> dispose() async {
    await closeClients();
    await server.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // best effort
    }
  }
}

Future<void> _until(bool Function() cond, String what) async {
  for (int i = 0; i < 400; i++) {
    if (cond()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TestFailure('condition never held: $what');
}

void _scenario(
  String name,
  Future<void> Function(_Rig r) body, {
  bool useStore = true,
  String ruleset = '2026-10',
  Timeout? timeout,
  bool checkLogs = true,
}) {
  test(name, () async {
    final _Rig r = _Rig(name, useStore: useStore, ruleset: ruleset);
    try {
      await runZoned(
        () async {
          await r.boot();
          await body(r);
        },
        zoneSpecification: ZoneSpecification(
          print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
            r.logs.add(line);
          },
        ),
      );
      if (checkLogs) {
        _checkLogs(r);
      }
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

/// Section 32 item 11: no install, IP or keyed hash in any log line.
void _checkLogs(_Rig r) {
  final Set<String> secrets = <String>{
    ...r.minted,
    ...r.minted.map((String m) => _hmacHex(_salt, m)),
  };
  for (final String line in r.logs) {
    for (final String s in secrets) {
      if (line.contains(s)) {
        throw TestFailure('item 11: a log line carries a secret string '
            '"${s.length > 12 ? s.substring(0, 12) : s}..." (an install, an '
            'IP or a keyed hash); line: $line');
      }
    }
  }
}

// ---------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------

void _err(Map<String, Object?> frame, String code, String because) {
  if (frame['t'] != 'error') {
    throw TestFailure('expected an error frame $code ($because) but got '
        '"${frame['t']}": ${frame['d']}');
  }
  if (_d(frame)['code'] != code) {
    throw TestFailure('expected error $code ($because) but got '
        '${_d(frame)['code']} (message "${_d(frame)['message']}")');
  }
}

void _expectBan(
  Map<String, Object?> d, {
  required String scope,
  required int level,
  required int untilMs,
  required int nextMs,
  required String because,
}) {
  final Object? ban = d['ban'];
  if (ban is! Map) {
    throw TestFailure('item 12: $because must carry a ban object; got '
        'ban=$ban in $d');
  }
  final Map<String, Object?> b = ban.cast<String, Object?>();
  expect(b.keys.toSet(), <String>{'scope', 'until_ms', 'level', 'next_ms'},
      reason: 'item 12: $because ban keys; got $b');
  expect(b['scope'], scope, reason: 'item 12: $because ban.scope; got $b');
  expect(b['level'], level, reason: 'item 12: $because ban.level; got $b');
  expect(b['until_ms'], untilMs,
      reason: 'item 12: $because ban.until_ms (epoch ms) expected $untilMs; '
          'got $b');
  expect(b['next_ms'], nextMs,
      reason: 'item 12: $because ban.next_ms expected $nextMs; got $b');
}

void _expectNoBan(Map<String, Object?> d, String because) =>
    expect(d.containsKey('ban'), isFalse,
        reason: 'item 12: $because must carry no ban; got $d');

Future<void> _expectNotBanned(_Rig r, _Dev d, String because,
    {String? ip}) async {
  final Map<String, Object?> f = await r.tryCode(d, 'ZZZZZ', ip: ip);
  _err(
      f,
      'NO_SUCH_ROOM',
      '$because (a typed code to an absent room must '
          'reach the lookup, so the device is not banned)');
}

Future<Map<String, Object?>> _expectBanned(
  _Rig r,
  _Dev d,
  String because, {
  String code = 'ZZZZZ',
  String? ip,
}) async {
  final Map<String, Object?> f = await r.tryCode(d, code, ip: ip);
  _err(f, 'CODE_BANNED', because);
  return _d(f);
}

// ---------------------------------------------------------------------
// The ladder driver
// ---------------------------------------------------------------------

class _Step {
  const _Step(this.count, this.length, this.level, this.next);

  final int count;
  final Duration length;
  final int level;
  final Duration next;
}

const List<_Step> _steps = <_Step>[
  _Step(6, _h24, 1, _d7),
  _Step(3, _d7, 2, _d30),
  _Step(3, _d30, 3, _d730),
  _Step(5, _d730, 4, _d730),
];

/// Strikes [d] from [n] distinct fresh hosts by rejected knocks; every frame
/// but the last must carry no ban. Returns the last knock_failed `d`.
Future<Map<String, Object?>> _rejects(
  _Rig r,
  _Dev d,
  int n, {
  String label = 'strike',
  bool lastMayBan = true,
}) async {
  Map<String, Object?> last = <String, Object?>{};
  for (int i = 1; i <= n; i++) {
    final _Host h = await r.host(approval: true);
    last = await r.strikeReject(h, d);
    expect(last['outcome'], 'rejected', reason: '$label $i: knock_failed');
    if (i < n || !lastMayBan) {
      _expectNoBan(last, '$label $i of $n (knock_failed, no ban fired yet)');
    }
    await h.c.close();
  }
  return last;
}

/// Climbs [d] through [steps] ladder steps, asserting every step. After the
/// last step the ban is active (the clock is not moved past it).
Future<void> _climb(_Rig r, _Dev d, int steps) async {
  for (int s = 0; s < steps; s++) {
    final _Step step = _steps[s];
    final int fireAt = r.nowMs;
    final Map<String, Object?> last = await _rejects(r, d, step.count,
        label: 'ladder step ${s + 1} (level ${s} to ${step.level})');
    _expectBan(last,
        scope: 'device',
        level: step.level,
        untilMs: fireAt + step.length.inMilliseconds,
        nextMs: step.next.inMilliseconds,
        because: 'the ${step.count}th strike at level $s (knock_failed)');
    final Map<String, Object?> probe =
        await _expectBanned(r, d, 'right after the step-${s + 1} ban');
    expect(probe['ban'], isNotNull);
    if (s < steps - 1) {
      r.tick(step.length + _s1);
      await _expectNotBanned(r, d,
          'one second after the ${step.length.inHours} h ban of step ${s + 1}');
    }
  }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

void main() {
  group('items 1 to 3: the code order, the lowest free code, the rest', () {
    _scenario('C1 the first 36 rooms get 0..Z then 10, 11, 12', (_Rig r) async {
      final List<String> got = <String>[];
      for (int i = 0; i < 36; i++) {
        final _Host h = await r.host();
        got.add(h.code);
      }
      expect(got, <String>[for (int i = 0; i < 36; i++) _codeAt(i)],
          reason: 'item 1 and 2: the codes in creation order');
      expect(got[32], 'Z');
      expect(got[33], '10', reason: 'the 34th live room gets 10');
      expect(got.sublist(0, 33).join(), _alphabet,
          reason: 'item 1: the one-symbol alphabet is exactly 33 symbols, '
              'without I, L and O');
    });

    _scenario('C2 the whole sequence to 100: 1089 rooms, ZZ is followed by 100',
        (_Rig r) async {
      final List<String> got = <String>[];
      for (int i = 0; i < 1090; i++) {
        final _Host h = await r.host();
        got.add(h.code);
      }
      final List<String> want = <String>[
        for (int i = 0; i < 1090; i++) _codeAt(i)
      ];
      for (int i = 0; i < want.length; i++) {
        if (got[i] != want[i]) {
          fail('item 1 and 2: room number ${i + 1} should get "${want[i]}" '
              'and got "${got[i]}"');
        }
      }
      expect(got[1088], 'ZZ');
      expect(got[1089], '100');
    }, timeout: const Timeout(Duration(minutes: 4)));

    _scenario(
        'C3 a reaped middle code is handed out again only after its 10 '
        'minute rest, not before', (_Rig r) async {
      final List<_Host> hosts = <_Host>[];
      for (int i = 0; i < 5; i++) {
        hosts.add(await r.host());
      }
      expect(hosts.map((_Host h) => h.code).toList(),
          <String>['0', '1', '2', '3', '4']);
      // Room 2 goes idle: its only seat disconnects, then 10 minutes pass.
      await hosts[2].c.close();
      await _until(() {
        final Room? room = r.registry.lookup('2');
        return room != null && room.seats.every((Seat s) => !s.connected);
      }, 'the server notices the host of room 2 is gone');
      final int roomsBefore = r.registry.roomCount;
      r.tick(const Duration(minutes: 10, seconds: 1));
      expect(r.registry.lookup('2'), isNull,
          reason: 'fixture: the idle room 2 must be reaped (rooms before '
              '$roomsBefore, after ${r.registry.roomCount})');
      expect(r.registry.lookup('3'), isNotNull,
          reason: 'fixture: the other rooms have connected hosts and live');

      final _Host a = await r.host();
      expect(a.code, '5',
          reason: 'item 3: code 2 was reaped this instant and rests; the '
              'next code is the lowest free that is not resting');
      r.tick(const Duration(minutes: 9, seconds: 58));
      final _Host b = await r.host();
      expect(b.code, '6',
          reason: 'item 3: 9 min 58 s after the reap code 2 is still resting '
              '(the 24 hour quarantine is gone but the 10 minute rest '
              'holds)');
      r.tick(const Duration(seconds: 4));
      final _Host c = await r.host();
      expect(c.code, '2',
          reason: 'item 2 and 3: 10 min 2 s after the reap the lowest free '
              'code is 2 again');
      final _Host d = await r.host();
      expect(d.code, '7', reason: 'item 2: then the next lowest free');
    });

    _scenario(
        'C4 the rest is measured on the server clock from the reap, and a '
        'code freed long ago is free at once', (_Rig r) async {
      final _Host h0 = await r.host();
      final _Host h1 = await r.host();
      expect(<String>[h0.code, h1.code], <String>['0', '1']);
      await h0.c.close();
      await _until(
          () => r.registry.lookup('0')!.seats.every((Seat s) => !s.connected),
          'host of room 0 gone');
      // A long wait without a sweep does not start the rest: reap does.
      r.clock.advance(const Duration(hours: 2));
      r.registry.reap();
      expect(r.registry.lookup('0'), isNull, reason: 'fixture: 0 reaped');
      final _Host n = await r.host();
      expect(n.code, '2', reason: 'item 3: 0 is resting right after the reap');
      r.tick(const Duration(minutes: 10, seconds: 1));
      final _Host m = await r.host();
      expect(m.code, '0', reason: 'item 3: rested for 10 minutes');
    });
  });

  group('item 4: folding and NO_SUCH_ROOM', () {
    _scenario('F1 o, whitespace, i, l and lower case reach the room',
        (_Rig r) async {
      final List<_Host> hosts = <_Host>[];
      for (int i = 0; i < 11; i++) {
        hosts.add(await r.host(players: 4));
      }
      expect(hosts[0].code, '0');
      expect(hosts[1].code, '1');
      expect(hosts[10].code, 'A');
      final Map<String, String> cases = <String, String>{
        'o': '0',
        'O': '0',
        ' 0 ': '0',
        'i': '1',
        'l': '1',
        'L': '1',
        '\t a\n': 'A',
      };
      final Map<String, int> seated = <String, int>{};
      for (final MapEntry<String, String> e in cases.entries) {
        final String canon = e.value;
        final (_C c, Map<String, Object?> f) = await r.joinRaw(
            <String, Object?>{'code': e.key},
            install: r.freshInstall('g'));
        if (f['t'] == 'error' && _d(f)['code'] == 'ROOM_FULL') {
          // The room was found; it simply has no seat left (4 players).
          seated[canon] = (seated[canon] ?? 0) + 4;
          await c.close();
          continue;
        }
        expect(f['t'], 'seat_assigned',
            reason: 'item 4: typed "${e.key}" must fold to $canon and seat; '
                'got ${f['t']}: ${f['d']}');
        if (_d(f).containsKey('code')) {
          expect(_d(f)['code'], canon,
              reason: 'item 4: seat_assigned carries the canonical code');
        }
        final Map<String, Object?> room = await c.untilType('room');
        expect(_d(room)['code'], canon,
            reason: 'item 4: the room frame for typed "${e.key}" carries the '
                'canonical code');
        seated[canon] = (seated[canon] ?? 0) + 1;
      }
      expect(seated.keys.toSet(), <String>{'0', '1', 'A'});
    });

    _scenario(
        'F2 an I or L is 1: a typed "1" and "I" and "l" are one room, and '
        'the letters I, L and O are not symbols of a code', (_Rig r) async {
      await r.host();
      final _Host h1 = await r.host(players: 4);
      expect(h1.code, '1');
      for (final String typed in <String>['I', 'l']) {
        final _Joined j = await r.joinSeat(<String, Object?>{'code': typed},
            install: r.freshInstall('f'));
        expect(j.room['code'], '1', reason: 'typed "$typed" is room 1');
      }
    });

    _scenario(
        'F3 malformed and absent codes both answer NO_SUCH_ROOM, '
        'indistinguishably', (_Rig r) async {
      await r.host();
      final List<Object?> bad = <Object?>[
        'ZZZZZ', // well formed, absent
        'ZZZZZZZ', // 7 symbols
        '', // empty
        '   ', // only whitespace
        '1 2', // inner space
        '!!!', // outside the alphabet
        'ÉÉ',
        '0000000000',
      ];
      Map<String, Object?>? baseline;
      for (final Object? code in bad) {
        final (_C c, Map<String, Object?> f) = await r.joinRaw(
            <String, Object?>{'code': code},
            install: r.freshInstall('m'));
        _err(f, 'NO_SUCH_ROOM', 'item 4: typed ${jsonEncode(code)}');
        baseline ??= _d(f);
        expect(_d(f), baseline,
            reason: 'section 7: ${jsonEncode(code)} must answer exactly what '
                'a well formed absent code answers');
        await c.close();
      }
    });

    _scenario('F4 a code that is not a string is still BAD_FIELD',
        (_Rig r) async {
      final (_C c, Map<String, Object?> f) = await r
          .joinRaw(<String, Object?>{'code': 5}, install: r.freshInstall('n'));
      _err(f, 'BAD_FIELD', 'a numeric code is a payload error, section 7');
      await c.close();
    });
  });

  group('item 5: the typed-code window', () {
    _scenario(
        'T1 the 21st typed code in 10 minutes is RATE_LIMITED, is not '
        'counted, and the window after the first 20 expire admits',
        (_Rig r) async {
      final String ip = r.freshIp();
      final String inst = r.freshInstall('t');
      final _C c = await r.open(ip);
      Future<Map<String, Object?>> typed({String? install}) async {
        c.send('join_room', <String, Object?>{
          'code': 'ZZZZZ',
          'name': 'G',
          if (install != null) 'install': install,
        });
        return c.next();
      }

      for (int i = 1; i <= 20; i++) {
        _err(await typed(install: inst), 'NO_SUCH_ROOM',
            'typed code $i of 20 from one IP in one minute');
      }
      // Five minutes in, 20 more attempts: each is the 21st or later in the
      // window, so each is refused, and none of them may be counted.
      r.clock.advance(const Duration(minutes: 5));
      for (int i = 1; i <= 20; i++) {
        _err(
            await typed(install: inst),
            'RATE_LIMITED',
            'item 5: refused attempt $i at minute 5 (the 21st typed code from '
                'this IP inside 10 minutes of the first 20)');
      }
      r.clock.advance(const Duration(minutes: 5, seconds: 10));
      // 10 min 10 s after the first 20: they have expired. Had the 20
      // refusals at minute 5 been counted, the window would still be full.
      _err(await typed(install: inst), 'NO_SUCH_ROOM',
          'item 5: the next window admits, and the refusals did not count');
    });

    _scenario(
        'T2 payload validation comes before the typed-code window, and the '
        'window is per IP', (_Rig r) async {
      final String ip = r.freshIp();
      final String inst = r.freshInstall('t2');
      final _C c = await r.open(ip);
      for (int i = 0; i < 20; i++) {
        c.send('join_room',
            <String, Object?>{'code': 'ZZZZZ', 'name': 'G', 'install': inst});
        _err(await c.next(), 'NO_SUCH_ROOM', 'typed code ${i + 1}');
      }
      c.send('join_room', <String, Object?>{'code': 'ZZZZZ', 'name': 'G'});
      _err(await c.next(), 'BAD_FIELD',
          'item 5: validation (install missing) is before the window');
      final _C other = await r.open(r.freshIp());
      other.send('join_room',
          <String, Object?>{'code': 'ZZZZZ', 'name': 'G', 'install': inst});
      _err(await other.next(), 'NO_SUCH_ROOM',
          'item 5: a different IP has its own window');
    });

    _scenario(
        'T3 link joins and resumes are not counted by the typed-code window',
        (_Rig r) async {
      final String ip = r.freshIp();
      final String inst = r.freshInstall('t3');
      final _C c = await r.open(ip);
      Future<Map<String, Object?>> send(String t, Map<String, Object?> d) {
        c.send(t, d);
        return c.next();
      }

      // 19 typed codes, then 10 link joins and 4 resumes, spread over three
      // minutes so section 7's 20 per minute join/resume limit stays out.
      for (int i = 0; i < 10; i++) {
        _err(
            await send('join_room', <String, Object?>{
              'code': 'ZZZZZ',
              'name': 'G',
              'install': inst
            }),
            'NO_SUCH_ROOM',
            'typed code ${i + 1}');
      }
      r.clock.advance(const Duration(seconds: 61));
      for (int i = 0; i < 9; i++) {
        _err(
            await send('join_room', <String, Object?>{
              'code': 'ZZZZZ',
              'name': 'G',
              'install': inst
            }),
            'NO_SUCH_ROOM',
            'typed code ${11 + i}');
      }
      for (int i = 0; i < 10; i++) {
        _err(
            await send('join_room',
                <String, Object?>{'link': 'zzzz-zzzzzz', 'name': 'G'}),
            'NO_SUCH_ROOM',
            'link join ${i + 1} (not counted by the typed window)');
      }
      r.clock.advance(const Duration(seconds: 61));
      for (int i = 0; i < 4; i++) {
        final Map<String, Object?> f = await send('resume',
            <String, Object?>{'code': 'ZZZZZ', 'seat_token': 'x' * 43});
        expect(f['t'], 'error', reason: 'a resume to an absent room errors');
      }
      // 19 typed codes so far: the 20th is admitted, the 21st is refused.
      _err(
          await send('join_room',
              <String, Object?>{'code': 'ZZZZZ', 'name': 'G', 'install': inst}),
          'NO_SUCH_ROOM',
          'item 5: the 20th typed code is admitted, so link joins and '
              'resumes were not counted (19 typed so far)');
      _err(
          await send('join_room',
              <String, Object?>{'code': 'ZZZZZ', 'name': 'G', 'install': inst}),
          'RATE_LIMITED',
          'item 5: the 21st typed code');
    });
  });

  group('item 6: install on create_room and on a code join', () {
    _scenario('I1 a code join without install is BAD_FIELD, a link join is not',
        (_Rig r) async {
      final _Host h = await r.host(players: 4);
      final (_C c, Map<String, Object?> f) =
          await r.joinRaw(<String, Object?>{'code': h.code});
      _err(f, 'BAD_FIELD', 'item 6: code join without install');
      await c.close();
      final (_C c2, Map<String, Object?> f2) =
          await r.joinRaw(<String, Object?>{'code': h.code}, install: 'short');
      _err(f2, 'BAD_FIELD', 'item 6: code join with a malformed install');
      await c2.close();
      final (_C c3, Map<String, Object?> f3) =
          await r.joinRaw(<String, Object?>{'link': h.linkId});
      expect(f3['t'], 'seat_assigned',
          reason: 'item 6: a link join keeps install optional; got '
              '${f3['t']}: ${f3['d']}');
      await c3.close();
      final (_C c4, Map<String, Object?> f4) = await r.joinRaw(
          <String, Object?>{'code': h.code},
          install: r.freshInstall('ok'));
      expect(f4['t'], 'seat_assigned',
          reason: 'a code join with a valid install seats');
      await c4.close();
    });

    _scenario(
        'I2 create_room takes an optional install of the section 31 shape',
        (_Rig r) async {
      final _C a = await r.open(r.freshIp());
      a.send('create_room', <String, Object?>{'name': 'H', 'players': 2});
      expect((await a.next())['t'], 'seat_assigned',
          reason: 'create_room without install still works');
      final _C b = await r.open(r.freshIp());
      b.send('create_room', <String, Object?>{
        'name': 'H',
        'players': 2,
        'install': r.freshInstall('c')
      });
      expect((await b.next())['t'], 'seat_assigned',
          reason: 'create_room with a valid install works');
      final _C c = await r.open(r.freshIp());
      c.send('create_room',
          <String, Object?>{'name': 'H', 'players': 2, 'install': 'short'});
      _err(await c.next(), 'BAD_FIELD',
          'item 6: create_room with a malformed install');
      final _C d = await r.open(r.freshIp());
      d.send('create_room',
          <String, Object?>{'name': 'H', 'players': 2, 'install': 7});
      _err(await d.next(), 'BAD_FIELD',
          'item 6: create_room with a non-string install');
    });
  });

  group('item 7: each strike source and each non-strike event', () {
    Future<void> sixthBans(
      _Rig r,
      _Dev d,
      Future<Map<String, Object?>> Function(int i) strike,
      String frameName,
    ) async {
      for (int i = 1; i <= 5; i++) {
        _expectNoBan(await strike(i), '$frameName $i of 6');
      }
      await _expectNotBanned(r, d, 'after 5 distinct strikes');
      final int at = r.nowMs;
      final Map<String, Object?> last = await strike(6);
      _expectBan(last,
          scope: 'device',
          level: 1,
          untilMs: at + _h24.inMilliseconds,
          nextMs: _d7.inMilliseconds,
          because: 'the 6th strike ($frameName)');
      await _expectBanned(r, d, 'after the 6th strike');
    }

    _scenario('S1 a rejected knock is a strike; the 6th distinct host bans',
        (_Rig r) async {
      final _Dev d = r.dev('s1');
      await sixthBans(r, d, (int i) async {
        final _Host h = await r.host(approval: true);
        final Map<String, Object?> f = await r.strikeReject(h, d);
        expect(f['outcome'], 'rejected');
        return f;
      }, 'knock_failed');
    });

    _scenario(
        'S2 the lobby kick of a seat that joined by typed code is a strike',
        (_Rig r) async {
      final _Dev d = r.dev('s2');
      await sixthBans(r, d, (int i) async {
        final _Host h = await r.host();
        return r.strikeKick(h, d, 'code');
      }, 'kicked');
    });

    _scenario('S3 the lobby kick of an approved seat is a strike',
        (_Rig r) async {
      final _Dev d = r.dev('s3');
      await sixthBans(r, d, (int i) async {
        final _Host h = await r.host(approval: true);
        return r.strikeKick(h, d, 'approved');
      }, 'kicked');
    });

    _scenario('S4 the three counted sources add up: 2 + 2 + 2 ban at the 6th',
        (_Rig r) async {
      final _Dev d = r.dev('s4');
      final List<Future<Map<String, Object?>> Function()> sources =
          <Future<Map<String, Object?>> Function()>[
        () async => r.strikeReject(await r.host(approval: true), d),
        () async => r.strikeKick(await r.host(), d, 'code'),
        () async => r.strikeKick(await r.host(approval: true), d, 'approved'),
      ];
      Map<String, Object?> last = <String, Object?>{};
      for (int i = 0; i < 6; i++) {
        last = await sources[i % 3]();
        if (i < 5) {
          _expectNoBan(last, 'mixed strike ${i + 1}');
        }
      }
      expect(last.containsKey('ban'), isTrue,
          reason: 'item 7 and 8: 2 rejects + 2 code kicks + 2 approved '
              'kicks are 6 strikes from 6 hosts and must ban; got $last');
    });

    // Non-strike events. Six distinct hosts each; then five rejects must still
    // be no ban and the sixth reject must ban: any event that had counted
    // would have fired the ban early.
    Future<void> nonStrike(
      _Rig r,
      String event,
      Future<Map<String, Object?>?> Function(_Dev d) once,
    ) async {
      final _Dev d = r.dev('ns');
      for (int i = 1; i <= 6; i++) {
        final Map<String, Object?>? frame = await once(d);
        if (frame != null) {
          _expectNoBan(frame, '$event $i');
        }
      }
      await _expectNotBanned(
          r,
          d,
          'after six "$event" events (item 7: not a '
          'strike)');
      for (int i = 1; i <= 5; i++) {
        final _Host h = await r.host(approval: true);
        _expectNoBan(await r.strikeReject(h, d), 'control reject $i');
      }
      await _expectNotBanned(
          r, d, 'after "$event" x6 plus 5 rejects (5 strikes is no ban)');
      final _Host h = await r.host(approval: true);
      expect((await r.strikeReject(h, d)).containsKey('ban'), isTrue,
          reason: 'control: the 6th real strike must ban, which proves the '
              'helper strikes and that "$event" added nothing');
    }

    _scenario('N1 a knock that times out is not a strike', (_Rig r) async {
      await nonStrike(r, 'knock timeout', (_Dev d) async {
        final _Host h = await r.host(approval: true);
        final (_C c, Map<String, Object?> f) = await r.joinRaw(
            <String, Object?>{'code': h.code},
            install: d.install, ip: d.ip);
        expect(f['t'], 'knock_pending');
        r.tick(const Duration(seconds: 61));
        final Map<String, Object?> failed = await c.untilType('knock_failed');
        expect(_d(failed)['outcome'], 'timeout');
        await c.close();
        return _d(failed);
      });
    });

    _scenario('N2 a withdrawn knock is not a strike', (_Rig r) async {
      await nonStrike(r, 'knock withdrawn', (_Dev d) async {
        final _Host h = await r.host(approval: true);
        final (_C c, Map<String, Object?> f) = await r.joinRaw(
            <String, Object?>{'code': h.code},
            install: d.install, ip: d.ip);
        expect(f['t'], 'knock_pending');
        await h.c.untilType('knock');
        await c.close();
        final Map<String, Object?> closed = await h.c.untilType('knock_closed');
        expect(_d(closed)['outcome'], 'withdrawn');
        return null;
      });
    });

    _scenario('N3 a knock closed full is not a strike', (_Rig r) async {
      await nonStrike(r, 'knock full', (_Dev d) async {
        final _Host h = await r.host(approval: true, players: 2);
        final (_C c, Map<String, Object?> f) = await r.joinRaw(
            <String, Object?>{'code': h.code},
            install: d.install, ip: d.ip);
        expect(f['t'], 'knock_pending');
        final Map<String, Object?> hk = await h.c.untilType('knock');
        await r.joinSeat(<String, Object?>{'link': h.linkId});
        h.c.send('answer_knock', <String, Object?>{
          'knock_id': _d(hk)['knock_id'],
          'accept': true,
        });
        final Map<String, Object?> failed = await c.untilType('knock_failed');
        expect(_d(failed)['outcome'], 'full');
        await c.close();
        return _d(failed);
      });
    });

    _scenario('N4 a knock closed switched_off is not a strike', (_Rig r) async {
      await nonStrike(r, 'knock switched_off', (_Dev d) async {
        final _Host h = await r.host(approval: true, players: 2);
        final (_C c, Map<String, Object?> f) = await r.joinRaw(
            <String, Object?>{'code': h.code},
            install: d.install, ip: d.ip);
        expect(f['t'], 'knock_pending');
        await h.c.untilType('knock');
        await r.joinSeat(<String, Object?>{'link': h.linkId});
        h.c.send('set_guest_approval', <String, Object?>{'enabled': false});
        final Map<String, Object?> failed = await c.untilType('knock_failed');
        expect(_d(failed)['outcome'], 'switched_off');
        await c.close();
        return _d(failed);
      });
    });

    _scenario('N5 the lobby kick of a link seat is not a strike',
        (_Rig r) async {
      await nonStrike(r, 'link seat kicked', (_Dev d) async {
        final _Host h = await r.host();
        return r.strikeKick(h, d, 'link');
      });
    });

    _scenario(
        'N6 the PLAYING kick of section 28 is not a strike (2026-11 ruleset)',
        (_Rig r) async {
      await nonStrike(r, 'playing kick', (_Dev d) async {
        final _Host h = await r.host(players: 2);
        final _Joined j = await r.seatVia(h, d, 'code');
        await h.c.sync();
        h.c.send('start_game', <String, Object?>{});
        await h.c.untilType('game_started');
        await j.c.untilType('game_started');
        await j.c.close();
        final Map<String, Object?> pres = await h.c.untilType('presence');
        expect(_d(pres)['connected'], false);
        h.c.send('kick', <String, Object?>{'seat': j.seat});
        final Map<String, Object?> retired =
            await h.c.untilType('seat_retired');
        expect(_d(retired)['reason'], 'kicked');
        return null;
      });
    }, ruleset: '2026-11');

    _scenario('N7 the absent-seat removal is not a strike (2026-11 ruleset)',
        (_Rig r) async {
      await nonStrike(r, 'absent removal', (_Dev d) async {
        final _Host h = await r.host(players: 2);
        final _Joined j = await r.seatVia(h, d, 'code');
        await h.c.sync();
        h.c.send('start_game', <String, Object?>{});
        await h.c.untilType('game_started');
        await j.c.untilType('game_started');
        await j.c.close();
        await h.c.untilType('presence');
        r.tick(const Duration(seconds: 121));
        final Map<String, Object?> retired =
            await h.c.untilType('seat_retired');
        expect(_d(retired)['reason'], 'absent');
        return null;
      });
    }, ruleset: '2026-11');
  });

  group('item 8: the ladder', () {
    _scenario('L1 five distinct hosts are no ban, the sixth is 24 hours',
        (_Rig r) async {
      final _Dev d = r.dev('l1');
      await _climb(r, d, 1);
    });

    _scenario('L2 six strikes from one host count once: no ban',
        (_Rig r) async {
      final _Dev d = r.dev('l2');
      final String hostInstall = r.freshInstall('samehost');
      for (int i = 0; i < 8; i++) {
        final _Host h =
            await r.host(install: hostInstall, approval: true, ip: r.freshIp());
        _expectNoBan(await r.strikeReject(h, d), 'repeat strike ${i + 1}');
        await h.c.close();
      }
      await _expectNotBanned(r, d, 'eight strikes from one host key count 1');
    });

    _scenario(
        'L3 five distinct plus a repeat is still five; the next distinct '
        'host makes six', (_Rig r) async {
      final _Dev d = r.dev('l3');
      final List<String> hostInstalls = <String>[
        for (int i = 0; i < 5; i++) r.freshInstall('hh')
      ];
      for (final String inst in hostInstalls) {
        final _Host h = await r.host(install: inst, approval: true);
        _expectNoBan(await r.strikeReject(h, d), 'distinct strike');
        await h.c.close();
      }
      final _Host again = await r.host(
          install: hostInstalls[0], approval: true, ip: r.freshIp());
      _expectNoBan(await r.strikeReject(again, d),
          'a 6th strike from a host already counted');
      await _expectNotBanned(r, d, '5 distinct hosts, 6 strikes');
      final _Host sixth = await r.host(approval: true);
      expect((await r.strikeReject(sixth, d)).containsKey('ban'), isTrue,
          reason: 'item 8: the 6th DISTINCT host bans');
    });

    _scenario(
        'L4 a host key is its install when create_room carried one, else '
        'its IP', (_Rig r) async {
      final _Dev d = r.dev('l4');
      final String sharedIp = r.freshIp();
      // Four hosts with their own installs, all from ONE IP: 4 keys.
      for (int i = 0; i < 4; i++) {
        final _Host h = await r.host(approval: true, ip: sharedIp);
        _expectNoBan(await r.strikeReject(h, d), 'install host ${i + 1}');
      }
      // Three hosts WITHOUT install from one IP: they share one key.
      final String bareIp = r.freshIp();
      for (int i = 0; i < 3; i++) {
        final _Host h =
            await r.host(approval: true, ip: bareIp, withInstall: false);
        _expectNoBan(await r.strikeReject(h, d),
            'install-less host ${i + 1} on one IP (keyed by IP)');
      }
      await _expectNotBanned(r, d, '4 install keys + 1 IP key = 5 distinct');
      final _Host other =
          await r.host(approval: true, ip: r.freshIp(), withInstall: false);
      expect((await r.strikeReject(other, d)).containsKey('ban'), isTrue,
          reason: 'item 7 and 8: an install-less host on another IP is a '
              'sixth distinct key');
    });

    _scenario('L5 strikes against different installs are not pooled',
        (_Rig r) async {
      final String ip = r.freshIp();
      final _Dev a = r.dev('l5a', ip: ip);
      final _Dev b = r.dev('l5b', ip: ip);
      for (int i = 0; i < 4; i++) {
        final _Host h1 = await r.host(approval: true);
        _expectNoBan(await r.strikeReject(h1, a), 'a strike ${i + 1}');
        final _Host h2 = await r.host(approval: true);
        _expectNoBan(await r.strikeReject(h2, b), 'b strike ${i + 1}');
      }
      await _expectNotBanned(r, a, 'device a has 4 strikes');
      await _expectNotBanned(r, b, 'device b has 4 strikes');
    });

    _scenario('L6 level 1: three distinct hosts give 7 days', (_Rig r) async {
      await _climb(r, r.dev('l6'), 2);
    });

    _scenario('L7 level 2: three distinct hosts give 30 days', (_Rig r) async {
      await _climb(r, r.dev('l7'), 3);
    });

    _scenario('L8 level 3: five distinct hosts give 730 days, level 4',
        (_Rig r) async {
      await _climb(r, r.dev('l8'), 4);
    });

    _scenario(
        'L9 level 4 again: five more strikes give 730 days, level stays 4 '
        '(strikes from seats seated before the ban)', (_Rig r) async {
      final _Dev d = r.dev('l9');
      await _climb(r, d, 3);
      r.tick(_d30 + _s1);
      await _expectNotBanned(r, d, 'the 30 day ban is over');
      // Five seats held by typed code in five rooms, kicked after the ban.
      final List<_Host> hosts = <_Host>[];
      final List<_Joined> seats = <_Joined>[];
      for (int i = 0; i < 5; i++) {
        final _Host h = await r.host();
        hosts.add(h);
        seats.add(await r.seatVia(h, d, 'code'));
      }
      final Map<String, Object?> fourth =
          await _rejects(r, d, 4, label: 'level 3 strikes', lastMayBan: false);
      _expectNoBan(fourth, 'the 4th strike at level 3');
      final int firstAt = r.nowMs;
      final _Host h5 = await r.host(approval: true);
      final Map<String, Object?> fifth = await r.strikeReject(h5, d);
      _expectBan(fifth,
          scope: 'device',
          level: 4,
          untilMs: firstAt + _d730.inMilliseconds,
          nextMs: _d730.inMilliseconds,
          because: 'the 5th strike at level 3');
      for (int i = 0; i < 5; i++) {
        final Map<String, Object?> k = await r.kick(hosts[i], seats[i]);
        if (i < 4) {
          _expectNoBan(
              k,
              'kick ${i + 1} of 5 at level 4 (the count starts '
              'again at the ban)');
        } else {
          _expectBan(k,
              scope: 'device',
              level: 4,
              untilMs: r.nowMs + _d730.inMilliseconds,
              nextMs: _d730.inMilliseconds,
              because: 'the 5th strike at level 4 (kicked)');
        }
      }
      await _expectBanned(r, d, 'level 4 ban again');
    });

    _scenario(
        'L10 level 0 ageing: strikes older than 30 days no longer count, '
        'and the record is deleted', (_Rig r) async {
      final _Dev d = r.dev('l10');
      for (int i = 0; i < 5; i++) {
        final _Host h = await r.host(approval: true);
        _expectNoBan(await r.strikeReject(h, d), 'old strike ${i + 1}');
        await h.c.close();
      }
      final String hash = _hmacHex(_salt, d.install);
      final String before =
          await r.fileText(ready: (String t) => t.contains(hash));
      expect(before.contains(hash), isTrue,
          reason: 'fixture: the record of the struck install is on disk');
      r.tick(const Duration(days: 31));
      // Five fresh strikes: with the old five aged out this is 5, no ban.
      for (int i = 0; i < 5; i++) {
        final _Host h = await r.host(approval: true);
        _expectNoBan(
            await r.strikeReject(h, d),
            'item 8: strike ${i + 1} after 31 days; the first five are '
            'older than 30 days and must not count');
        await h.c.close();
      }
      await _expectNotBanned(r, d, 'five strikes inside 30 days');
      final _Host h = await r.host(approval: true);
      expect((await r.strikeReject(h, d)).containsKey('ban'), isTrue,
          reason: 'six strikes inside 30 days ban');
    });

    _scenario('L11 29 days is not old: five strikes then a sixth bans',
        (_Rig r) async {
      final _Dev d = r.dev('l11');
      for (int i = 0; i < 5; i++) {
        final _Host h = await r.host(approval: true);
        _expectNoBan(await r.strikeReject(h, d), 'strike ${i + 1}');
        await h.c.close();
      }
      r.tick(const Duration(days: 29));
      final _Host h = await r.host(approval: true);
      expect((await r.strikeReject(h, d)).containsKey('ban'), isTrue,
          reason: 'item 8: strikes 29 days old still count at level 0');
    });

    _scenario(
        'L12 a level-0 record with no strike inside 30 days is deleted '
        'from the store', (_Rig r) async {
      final _Dev d = r.dev('l12');
      final _Host h = await r.host(approval: true);
      await r.strikeReject(h, d);
      final String hash = _hmacHex(_salt, d.install);
      await r.fileText(ready: (String t) => t.contains(hash));
      r.tick(const Duration(days: 31));
      final String after =
          await r.fileText(ready: (String t) => !t.contains(hash));
      expect(after.contains(hash), isFalse,
          reason: 'item 8 and 11: a lone 31 day old strike at level 0 is '
              'swept out; the store still holds the install hash');
    });

    _scenario(
        'L13 the 365 day reset: a level 1 record whose ban started more '
        'than 365 days ago is level 0 again', (_Rig r) async {
      final _Dev d = r.dev('l13');
      await _climb(r, d, 1);
      r.tick(const Duration(days: 366));
      // At level 0 the ban needs 6. At level 1 it would fire at the 3rd.
      for (int i = 1; i <= 5; i++) {
        final _Host h = await r.host(approval: true);
        _expectNoBan(
            await r.strikeReject(h, d),
            'item 8: strike $i, 366 days after the last ban started; the '
            'record is level 0 again so a ban needs 6');
        await h.c.close();
      }
      final int at = r.nowMs;
      final _Host h = await r.host(approval: true);
      _expectBan(await r.strikeReject(h, d),
          scope: 'device',
          level: 1,
          untilMs: at + _h24.inMilliseconds,
          nextMs: _d7.inMilliseconds,
          because: 'the 6th strike after the reset is a fresh level 1 ban');
    });

    _scenario(
        'L14 364 days is not enough to reset: a level 1 record bans at '
        'the third strike', (_Rig r) async {
      final _Dev d = r.dev('l14');
      await _climb(r, d, 1);
      r.tick(const Duration(days: 364));
      await _rejects(r, d, 2, lastMayBan: false);
      final int at = r.nowMs;
      final _Host h = await r.host(approval: true);
      _expectBan(await r.strikeReject(h, d),
          scope: 'device',
          level: 2,
          untilMs: at + _d7.inMilliseconds,
          nextMs: _d30.inMilliseconds,
          because: 'the 3rd strike at level 1, 364 days after its ban');
    });
  });

  group('items 9, 10 and 12: what a ban does', () {
    _scenario('B1 CODE_BANNED carries every ban field, device scope',
        (_Rig r) async {
      final _Dev d = r.dev('b1');
      final int at = r.nowMs;
      await _rejects(r, d, 6);
      final Map<String, Object?> f = await r.tryCode(d, 'ZZZZZ');
      _err(f, 'CODE_BANNED', 'a banned device');
      expect(_d(f)['message'], isA<String>());
      _expectBan(_d(f),
          scope: 'device',
          level: 1,
          untilMs: at + _h24.inMilliseconds,
          nextMs: _d7.inMilliseconds,
          because: 'CODE_BANNED of a device that is also IP blocked (the '
              'device wins)');
    });

    _scenario(
        'B2 CODE_BANNED comes before the lookup: absent, malformed, '
        'approval on and approval off', (_Rig r) async {
      final _Dev d = r.dev('b2');
      final _Host open = await r.host(players: 4);
      final _Host gated = await r.host(players: 4, approval: true);
      await _rejects(r, d, 6);
      for (final String code in <String>[
        'ZZZZZ',
        '!!',
        '',
        open.code,
        gated.code,
        ' ${open.code.toLowerCase()} ',
      ]) {
        final Map<String, Object?> f = await r.tryCode(d, code);
        _err(f, 'CODE_BANNED', 'typed "$code" by a banned device');
      }
      // Nothing seated and nothing knocked.
      await open.c.sync();
      await gated.c.sync();
      expect(r.registry.lookup(open.code)!.seats.length, 1,
          reason: 'a banned join must not seat');
      expect(r.registry.lookup(gated.code)!.knocks, isEmpty,
          reason: 'a banned join must not knock');
    });

    _scenario(
        'B3 order: payload validation first, then the typed-code window, '
        'then the ban', (_Rig r) async {
      final _Dev d = r.dev('b3');
      await _rejects(r, d, 6);
      final (_C c, Map<String, Object?> f) =
          await r.joinRaw(<String, Object?>{'code': 'ZZZZZ'}, ip: d.ip);
      _err(
          f,
          'BAD_FIELD',
          'item 5 and 9: a banned device with no install is a payload '
              'error before the ban check');
      await c.close();
      // 6 knocks and 1 probe in the window already (and the BAD_FIELD one is
      // not counted). Fill the window with banned attempts.
      final String ip = r.freshIp();
      final _Dev b = _Dev(d.install, ip);
      final _C s = await r.open(ip);
      int counted = 0;
      Future<Map<String, Object?>> typed() {
        s.send('join_room', <String, Object?>{
          'code': 'ZZZZZ',
          'name': 'G',
          'install': b.install
        });
        return s.next();
      }

      for (int i = 0; i < 20; i++) {
        if (i == 10) {
          r.clock.advance(const Duration(seconds: 61));
        }
        _err(await typed(), 'CODE_BANNED', 'banned typed code ${i + 1}');
        counted++;
      }
      expect(counted, 20);
      _err(
          await typed(),
          'RATE_LIMITED',
          'item 5: the 21st typed code from this IP is RATE_LIMITED even for '
              'a banned device (the window is before the ban check)');
    });

    _scenario('B4 a banned device still joins by link, creates, and resumes',
        (_Rig r) async {
      final _Dev d = r.dev('b4');
      final _Host gated = await r.host(players: 4, approval: true);
      final _Host plain = await r.host(players: 4);
      // The device holds a seat from before the ban.
      final _Joined before = await r.joinSeat(
          <String, Object?>{'code': plain.code},
          install: d.install, ip: d.ip);
      await _rejects(r, d, 6);
      await _expectBanned(r, d, 'fixture: banned');
      // link join, approval on: seats at once, as ever.
      final _Joined viaLink = await r.joinSeat(
          <String, Object?>{'link': gated.linkId},
          install: d.install, ip: d.ip);
      expect(viaLink.room['code'], gated.code, reason: 'item 9: link join');
      // create_room
      final _Host created = await r.host(install: d.install, ip: d.ip);
      expect(created.code, isNotEmpty, reason: 'item 9: create_room');
      // resume of the pre-ban seat, new socket.
      await before.c.close();
      final _C c = await r.open(d.ip);
      c.send('resume',
          <String, Object?>{'code': plain.code, 'seat_token': before.token});
      final Map<String, Object?> f = await c.next();
      expect(f['t'] == 'error', isFalse,
          reason: 'item 9: resume is untouched by a ban; got ${f['t']}: '
              '${f['d']}');
      // Play is untouched: the banned seat can still ping and leave.
      expect((await c.sync()), isA<List<Map<String, Object?>>>());
    });

    _scenario('B5 the ban ends on the server clock', (_Rig r) async {
      final _Dev d = r.dev('b5');
      await _rejects(r, d, 6);
      r.tick(_h24 - const Duration(seconds: 2));
      await _expectBanned(r, d, '23 h 59 m 58 s into a 24 hour ban');
      r.tick(const Duration(seconds: 4));
      await _expectNotBanned(r, d, 'a few seconds past the 24 hour ban');
    });

    _scenario('B6 the device ban follows the install to another IP',
        (_Rig r) async {
      final _Dev d = r.dev('b6');
      await _rejects(r, d, 6);
      final Map<String, Object?> f = await _expectBanned(
          r, d, 'same install, another IP',
          ip: r.freshIp());
      expect((f['ban']! as Map<String, Object?>)['scope'], 'device');
    });

    _scenario(
        'B7 the IP block: a second install on the struck IP is blocked '
        '(network scope), another IP is not, link joins pass', (_Rig r) async {
      final _Dev d = r.dev('b7');
      final _Dev e = r.dev('b7e', ip: d.ip);
      final _Host gated = await r.host(players: 4, approval: true);
      final int at = r.nowMs;
      await _rejects(r, d, 6);
      final Map<String, Object?> f =
          await _expectBanned(r, e, 'a second install on the struck IP');
      _expectBan(f,
          scope: 'network',
          level: 0,
          untilMs: at + _h24.inMilliseconds,
          nextMs: 0,
          because: 'CODE_BANNED of an IP block alone');
      await _expectNotBanned(
          r, _Dev(e.install, r.freshIp()), 'the same install on another IP');
      final _Joined viaLink = await r.joinSeat(
          <String, Object?>{'link': gated.linkId},
          install: e.install, ip: d.ip);
      expect(viaLink.room['code'], gated.code,
          reason: 'item 9: a blocked IP still joins by link');
    });

    _scenario(
        'B8 the block lands on the IP of the struck socket, not on the '
        'IP the earlier strikes came from', (_Rig r) async {
      final String ipX = r.freshIp();
      final String ipY = r.freshIp();
      final _Dev atX = r.dev('b8', ip: ipX);
      final _Dev atY = _Dev(atX.install, ipY);
      await _rejects(r, atX, 5, lastMayBan: false);
      final _Host h = await r.host(approval: true);
      final Map<String, Object?> last = await r.strikeReject(h, atY);
      expect(last.containsKey('ban'), isTrue, reason: 'fixture: 6th strike');
      final _Dev bystanderX = r.dev('b8x', ip: ipX);
      final _Dev bystanderY = r.dev('b8y', ip: ipY);
      await _expectNotBanned(r, bystanderX, 'a bystander on the old IP');
      final Map<String, Object?> f =
          await _expectBanned(r, bystanderY, 'a bystander on the struck IP');
      expect((f['ban']! as Map<String, Object?>)['scope'], 'network');
    });

    _scenario(
        'B9 the IP block ends at 24 hours even for a 7 day device ban, and '
        'the IP hash is gone from the store after it', (_Rig r) async {
      final _Dev d = r.dev('b9');
      final _Dev e = r.dev('b9e', ip: d.ip);
      await _climb(r, d, 1);
      r.tick(_h24 + _s1);
      final int at = r.nowMs;
      final String ipHash = _hmacHex(_salt, d.ip);
      await _rejects(r, d, 3);
      final Map<String, Object?> dBan =
          await _expectBanned(r, d, 'the 7 day device ban');
      _expectBan(dBan,
          scope: 'device',
          level: 2,
          untilMs: at + _d7.inMilliseconds,
          nextMs: _d30.inMilliseconds,
          because: 'a device inside a 7 day ban while its IP is blocked');
      final Map<String, Object?> eBan =
          await _expectBanned(r, e, 'second install, IP block running');
      _expectBan(eBan,
          scope: 'network',
          level: 0,
          untilMs: at + _h24.inMilliseconds,
          nextMs: 0,
          because: 'item 10: the block is capped at 24 hours');
      final String during =
          await r.fileText(ready: (String t) => t.contains(ipHash));
      expect(during.contains(ipHash), isTrue,
          reason: 'item 10: while the block runs the IP is held as a keyed '
              'hash; the store has no HMAC(salt, ip)');
      r.tick(_h24 - const Duration(seconds: 2));
      await _expectBanned(r, e, '23 h 59 m 58 s into the IP block');
      r.tick(const Duration(seconds: 4));
      await _expectNotBanned(r, e, 'second install after the 24 hour block');
      final Map<String, Object?> still =
          await _expectBanned(r, d, 'the device is still inside its 7 day ban');
      expect((still['ban']! as Map<String, Object?>)['scope'], 'device',
          reason: 'item 12: after the block ends only the device ban holds');
      final String after =
          await r.fileText(ready: (String t) => !t.contains(ipHash));
      expect(after.contains(ipHash), isFalse,
          reason: 'item 10: the IP hash is deleted once its block ends');
      final String instHash = _hmacHex(_salt, d.install);
      expect(after.contains(instHash), isTrue,
          reason: 'the device record itself stays for its 7 day ban');
    });

    _scenario(
        'B10 the ban frame is on the firing knock_failed / kicked only; a '
        'later strike inside the same step carries none', (_Rig r) async {
      final _Dev d = r.dev('b10');
      await _rejects(r, d, 6);
      // A banned device cannot knock; an already seated one can still be
      // kicked and that kick is one strike of the next step, no ban yet.
      r.tick(_h24 + _s1);
      final _Host h = await r.host();
      final Map<String, Object?> k = await r.strikeKick(h, d, 'code');
      _expectNoBan(k, 'a first strike of the 7 day step');
    });
  });

  group('item 11: the store', () {
    _scenario('P1 strikes and a ban survive a restart over the same directory',
        (_Rig r) async {
      final _Dev d = r.dev('p1');
      final _Dev e = r.dev('p1e');
      await _rejects(r, e, 5, lastMayBan: false);
      final int at = r.nowMs;
      await _rejects(r, d, 6);
      final String instHash = _hmacHex(_salt, d.install);
      await r.fileText(ready: (String t) => t.contains(instHash));
      await r.restart();
      final Map<String, Object?> f =
          await _expectBanned(r, d, 'after a restart');
      _expectBan(f,
          scope: 'device',
          level: 1,
          untilMs: at + _h24.inMilliseconds,
          nextMs: _d7.inMilliseconds,
          because: 'the ban reloaded from strikes.json');
      await _expectNotBanned(r, e, 'a device with 5 strikes is not banned');
      final _Host h = await r.host(approval: true);
      expect((await r.strikeReject(h, e)).containsKey('ban'), isTrue,
          reason: 'item 11: the 5 strikes of e survived the restart, so one '
              'more is the 6th');
    });

    _scenario(
        'P2 the file holds keyed hashes only: no install, no IP, no name, '
        'no room, no code', (_Rig r) async {
      final _Dev d = r.dev('p2');
      final String hostInstall = r.freshInstall('p2host');
      final String bareIp = r.freshIp();
      final _Host named = await r.host(install: hostInstall, approval: true);
      await r.strikeReject(named, d);
      final _Host bare =
          await r.host(approval: true, ip: bareIp, withInstall: false);
      await r.strikeReject(bare, d);
      final String text = await r.fileText(
          ready: (String t) => t.contains(_hmacHex(_salt, bareIp)));
      expect(() => jsonDecode(text), returnsNormally,
          reason: 'item 11: strikes.json is JSON');
      for (final String raw in <String>[
        d.install,
        d.ip,
        hostInstall,
        bareIp,
        named.code,
        named.linkId,
        'Host',
        'Guest',
      ]) {
        expect(text.contains(raw), isFalse,
            reason: 'item 11: "$raw" must not be in the store');
      }
      expect(text.contains(_hmacHex(_salt, d.install)), isTrue,
          reason: 'item 11: the struck install is held as '
              'HMAC-SHA256(salt, install) in lower-case hex');
      expect(text.contains(_hmacHex(_salt, hostInstall)), isTrue,
          reason: 'item 7: the striking host key is the keyed hash of its '
              'install');
      expect(text.contains(_hmacHex(_salt, bareIp)), isTrue,
          reason: 'item 7: an install-less host is keyed by the hash of its '
              'IP');
      expect(
          text.contains(
              _hmacHex('another-salt-0123456789-abcdefghijklmnop', d.install)),
          isFalse);
      expect(
          RegExp(r'[0-9a-fA-F]{64}').allMatches(text).where(
              (RegExpMatch m) => m.group(0)!.toLowerCase() != m.group(0)),
          isEmpty,
          reason: 'item 11: hashes are lower-case hex');
      final List<String> names = r.dir
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .toList();
      expect(names, <String>['strikes.json'],
          reason: 'item 11: written to a temporary file then renamed; no '
              'temporary file may be left behind');
    });

    _scenario(
        'P3 a file that does not parse is renamed strikes.json.bad-<epoch '
        'ms> and the server starts with an empty store', (_Rig r) async {
      await r.closeClients();
      await r.server.close();
      r.storeFile.writeAsStringSync('{ this is not json');
      await r.boot();
      final List<String> bad = r.dir
          .listSync()
          .map((FileSystemEntity e) => e.uri.pathSegments.last)
          .where((String n) => n.startsWith('strikes.json.bad-'))
          .toList();
      expect(bad, hasLength(1),
          reason: 'item 11: the unparsable file is renamed aside; dir has '
              '${r.dir.listSync()}');
      expect(RegExp(r'^strikes\.json\.bad-\d+$').hasMatch(bad.single), isTrue,
          reason: 'item 11: the suffix is an epoch in milliseconds; got '
              '${bad.single}');
      expect(File('${r.dir.path}/${bad.single}').readAsStringSync(),
          '{ this is not json',
          reason: 'the bad file is kept as it was');
      final _Dev d = r.dev('p3');
      await _expectNotBanned(r, d, 'an empty store bans nobody');
      final _Host h = await r.host(approval: true);
      _expectNoBan(await r.strikeReject(h, d), 'the server works');
    });

    _scenario(
        'P4 LUDO_STRIKE_DIR without a valid salt refuses to start, naming '
        'the variable', (_Rig r) async {
      final Clock clock = r.clock;
      for (final String? salt in <String?>[null, '', 'short', 'x' * 31]) {
        Object? thrown;
        try {
          StrikeStore(clock: clock, dir: r.dir.path, salt: salt);
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isNotNull,
            reason: 'item 11: a strike dir with salt ${jsonEncode(salt)} '
                '(${salt?.length ?? 0} chars) must refuse');
        expect('$thrown', contains('LUDO_STRIKE_SALT'),
            reason: 'item 11: the refusal says which variable is wrong');
      }
      expect(() => StrikeStore(clock: clock, dir: r.dir.path, salt: 'y' * 32),
          returnsNormally,
          reason: 'a 32 character salt is enough');
    });

    _scenario(
        'P5 neither variable set: an in-memory store bans and forgets on '
        'restart, and writes no file', (_Rig r) async {
      final _Dev d = r.dev('p5');
      await _rejects(r, d, 6);
      await _expectBanned(r, d, 'the in-memory store bans');
      expect(r.dir.listSync(), isEmpty,
          reason: 'item 11: no directory, no file');
      await r.restart();
      await _expectNotBanned(r, d, 'a new in-memory registry forgets');
    }, useStore: false);
  });

  group('item 11: logs', () {
    _scenario(
        'G1 the log says strike and ban, and no hash, IP or install is in '
        'any line (checked on every scenario too)', (_Rig r) async {
      final _Dev d = r.dev('g1');
      await _climb(r, d, 2);
      expect(r.logs.any((String l) => l.contains('strike')), isTrue,
          reason: 'item 11: the log says `strike`; lines: ${r.logs}');
      expect(r.logs.any((String l) => RegExp(r'\bban\b').hasMatch(l)), isTrue,
          reason: 'item 11: the log says `ban` with level and length; '
              'lines: ${r.logs}');
      _checkLogs(r);
    });
  });

  group('item 13: web', () {
    _scenario('W1 the privacy page says what is kept, in English and Arabic',
        (_Rig r) async {
      final Map<String, Object?> en = await r.getJson('/privacy');
      expect(en['status'], 200);
      final String enBody = (en['body']! as String).toLowerCase();
      for (final String phrase in <String>[
        'install',
        'keyed hash',
        '30 days',
        '12 months',
        '24 hours',
      ]) {
        expect(enBody.contains(phrase), isTrue,
            reason: 'item 13: the English privacy page must say "$phrase"');
      }
      final Map<String, Object?> ar = await r.getJson('/privacy?lang=ar');
      expect(ar['status'], 200);
      final String arBody = ar['body']! as String;
      for (final List<String> alt in <List<String>>[
        <String>['30', '٣٠'],
        <String>['12', '١٢'],
        <String>['24', '٢٤'],
      ]) {
        expect(alt.any(arBody.contains), isTrue,
            reason: 'item 13: the Arabic privacy page must carry the figure '
                '${alt.first} (30 days, 12 months, 24 hours)');
      }
      expect(arBody.contains('العربية') || arBody.contains('lang="ar"'), isTrue,
          reason: 'fixture: the Arabic page was served');
    });
  });

  group('processes: the real server binary', () {
    Map<String, String> cleanEnv(Map<String, String> extra) {
      final Map<String, String> env = <String, String>{};
      Platform.environment.forEach((String k, String v) {
        if (!k.startsWith('CTL_') && !k.startsWith('LUDO_')) {
          env[k] = v;
        }
      });
      env.addAll(extra);
      return env;
    }

    Future<int> freePort() async {
      final ServerSocket s =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final int p = s.port;
      await s.close();
      return p;
    }

    Future<Process> spawn(Map<String, String> extra) => Process.start(
          Platform.resolvedExecutable,
          <String>['run', 'bin/server.dart'],
          environment: cleanEnv(extra),
          includeParentEnvironment: false,
        );

    Future<void> waitHealth(int port, Process p) async {
      bool exited = false;
      unawaited(p.exitCode.then((_) => exited = true));
      for (int i = 0; i < 1500; i++) {
        if (exited) {
          throw TestFailure('the server exited before /health answered');
        }
        try {
          final HttpClient c = HttpClient();
          final HttpClientRequest rq =
              await c.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
          final HttpClientResponse rs = await rq.close();
          await rs.drain<void>();
          c.close(force: true);
          if (rs.statusCode == 200) {
            return;
          }
        } catch (_) {
          // not listening yet
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      throw TestFailure('the server never answered /health');
    }

    test(
        'X1 a strike dir with no salt stops the server and names the '
        'variable', () async {
      final Directory dir = Directory.systemTemp.createTempSync('c684x_');
      try {
        final Process p = await spawn(<String, String>{
          'PORT': '${await freePort()}',
          'LUDO_STRIKE_DIR': dir.path,
        });
        final Future<String> err = p.stderr.transform(utf8.decoder).join();
        unawaited(p.stdout.drain<void>());
        final int code = await p.exitCode.timeout(const Duration(seconds: 120));
        final String text = await err;
        expect(code, isNot(0),
            reason: 'item 11: LUDO_STRIKE_DIR without a salt must stop the '
                'server; stderr: $text');
        expect(text, contains('LUDO_STRIKE_SALT'),
            reason: 'item 11: the message says which variable is wrong');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('X2 a salt of 31 characters stops the server and names the variable',
        () async {
      final Directory dir = Directory.systemTemp.createTempSync('c684x_');
      try {
        final Process p = await spawn(<String, String>{
          'PORT': '${await freePort()}',
          'LUDO_STRIKE_DIR': dir.path,
          'LUDO_STRIKE_SALT': 'a' * 31,
        });
        final Future<String> err = p.stderr.transform(utf8.decoder).join();
        unawaited(p.stdout.drain<void>());
        final int code = await p.exitCode.timeout(const Duration(seconds: 120));
        final String text = await err;
        expect(code, isNot(0),
            reason: 'item 11: a 31 character salt is invalid; stderr: $text');
        expect(text, contains('LUDO_STRIKE_SALT'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('X3 a corrupt strikes.json is renamed aside and the server starts',
        () async {
      final Directory dir = Directory.systemTemp.createTempSync('c684x_');
      final int port = await freePort();
      Process? p;
      try {
        File('${dir.path}/strikes.json').writeAsStringSync('}{ not json');
        p = await spawn(<String, String>{
          'PORT': '$port',
          'LUDO_STRIKE_DIR': dir.path,
          'LUDO_STRIKE_SALT': _salt,
        });
        final Future<String> out = p.stdout.transform(utf8.decoder).join();
        final Future<String> err = p.stderr.transform(utf8.decoder).join();
        await waitHealth(port, p);
        final List<String> names = dir
            .listSync()
            .map((FileSystemEntity e) => e.uri.pathSegments.last)
            .toList();
        expect(names.where((String n) => n.startsWith('strikes.json.bad-')),
            hasLength(1),
            reason: 'item 11: the corrupt file is renamed; dir: $names');
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(seconds: 30));
        final String logs = '${await out}${await err}';
        expect(logs.toLowerCase(), contains('strikes.json'),
            reason: 'item 11: the rename is logged at error level; '
                'output: $logs');
      } finally {
        p?.kill(ProcessSignal.sigkill);
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 4)));

    test(
        'X4 a real ban over the real binary: log lines carry no hash, IP or '
        'install, the store file persists', () async {
      final Directory dir = Directory.systemTemp.createTempSync('c684x_');
      final int port = await freePort();
      Process? p;
      try {
        final _World w = _World()
          ..uri = Uri(scheme: 'ws', host: '127.0.0.1', port: port, path: '/');
        p = await spawn(<String, String>{
          'PORT': '$port',
          'LUDO_STRIKE_DIR': dir.path,
          'LUDO_STRIKE_SALT': _salt,
          'TRUSTED_PROXIES': '127.0.0.1',
        });
        final StringBuffer logs = StringBuffer();
        p.stdout.transform(utf8.decoder).listen(logs.write);
        p.stderr.transform(utf8.decoder).listen(logs.write);
        await waitHealth(port, p);
        try {
          final _Dev d = w.dev('x4');
          Map<String, Object?> last = <String, Object?>{};
          for (int i = 0; i < 6; i++) {
            final _Host h = await w.host(approval: true);
            last = await w.strikeReject(h, d);
          }
          expect(last.containsKey('ban'), isTrue,
              reason: 'the 6th strike over the real binary must ban; got '
                  '$last');
          final Map<String, Object?> f = await w.tryCode(d, 'ZZZZZ');
          _err(f, 'CODE_BANNED', 'a banned device over the real binary');
          final File store = File('${dir.path}/strikes.json');
          for (int i = 0; i < 300 && !store.existsSync(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(store.existsSync(), isTrue,
              reason: 'item 11: strikes.json is written after a change');
        } finally {
          await w.closeClients();
        }
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(seconds: 30));
        final String text = logs.toString();
        for (final String m in w.minted) {
          expect(text.contains(m), isFalse,
              reason: 'item 11: the server output carries "$m"');
          expect(text.contains(_hmacHex(_salt, m)), isFalse,
              reason: 'item 11: the server output carries the keyed hash of '
                  '"$m"');
        }
        expect(RegExp(r'\b10\.\d+\.\d+\.\d+\b').hasMatch(text), isFalse,
            reason: 'item 11: no IP address in any log line; output: $text');
        expect(RegExp(r'[0-9a-f]{64}').hasMatch(text), isFalse,
            reason: 'item 11: no 64 character hash in any log line');
        expect(text.contains('inst-'), isFalse,
            reason: 'item 11: no install id in any log line');
        expect(text.contains('strike'), isTrue,
            reason: 'item 11: the log says `strike`; output: $text');
      } finally {
        p?.kill(ProcessSignal.sigkill);
        dir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 4)));
  });
}
