// Order C-707t: docs/PROTOCOL.md section 35 (the roll rides the turn frame),
// the server tests its item 6 requires, written from the section alone.
//
// Real WebSocket clients against a real WireServer on a loopback port. The
// game clock is a FakeClock injected into the registry and the server, the
// automatic sweeps are off and the test runs them itself after moving the
// clock (`server.runTurnExpiryOnce()`, `server.runComputerSeatsOnce()`), the
// way c700_kick_in_play_test.dart and c705_computer_seats_test.dart do. The
// rate limiter has a clock of its own, moved 1.1 s before every message, so a
// fast scripted game never meets the per-second ceiling and a `game_log`
// request is never refused for its per-minute limit; the game clock does not
// move with it.
//
// The dice are scripted by seeding: the registry's CSPRNG slot gets
// `Random(seed)` and the computer source `Random(seed * 1000 + n)`, so the
// chain, the game id and therefore every face are fixed by the seed printed
// in every failure.
//
// Every frame a socket receives is recorded the moment it arrives, read or
// not, so the whole-game checks cover every captured frame. "Nothing else
// arrived" and "every socket has caught up" are ping barriers (the server
// answers one socket in order); nothing sleeps for a fixed time.
//
// The clients decide every action from frames with `pre` removed, so each
// full game is also a game played by a client that never reads `pre`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

const String _file = 'test/c707_pre_roll_test.dart';

typedef Frame = Map<String, Object?>;

Frame fd(Frame f) => (f['d'] ?? <String, Object?>{}) as Frame;

String _clip(String s, [int max = 360]) =>
    s.length <= max ? s : '${s.substring(0, max)}...(${s.length} chars)';

String fdesc(Frame f) => _clip('${f['t']}'
    '${f['t'] == 'error' ? ':${fd(f)['code']}' : ''} '
    '${jsonEncode(f['d'])}${f['re'] == null ? '' : ' re=${f['re']}'}');

String fdescAll(Iterable<Frame> fs) =>
    fs.isEmpty ? '(nothing)' : fs.map(fdesc).join(' | ');

Object? _canon(Object? v) {
  if (v is Map) {
    final List<String> keys = v.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final String k in keys) k: _canon(v[k])};
  }
  if (v is List) {
    return <Object?>[for (final Object? x in v) _canon(x)];
  }
  return v;
}

String canon(Object? v) => jsonEncode(_canon(v));

/// [m] without [keys].
Frame without(Frame m, Iterable<String> keys) {
  final Frame out = Map<String, Object?>.of(m);
  for (final String k in keys) {
    out.remove(k);
  }
  return out;
}

/// Section 35 item 1: `pre` is the `rolled` `d` without these four keys.
const List<String> rolledOnlyKeys = <String>[
  'seq',
  'reveal',
  'deadline_ms',
  'by',
];

/// The frame as a client that never reads `pre` sees it.
Frame stripPre(Frame f) {
  final Frame d = fd(f);
  final Frame nd = without(d, <String>['pre']);
  if (nd['turn'] is Map) {
    nd['turn'] =
        without((nd['turn']! as Map).cast<String, Object?>(), <String>['pre']);
  }
  return <String, Object?>{...f, 'd': nd};
}

/// Every path in [node] that holds a key named `pre`.
List<String> prePaths(Object? node, [String at = 'd']) {
  final List<String> out = <String>[];
  if (node is Map) {
    for (final MapEntry<Object?, Object?> e in node.entries) {
      if (e.key == 'pre') {
        out.add('$at.pre');
      }
      out.addAll(prePaths(e.value, '$at.${e.key}'));
    }
  } else if (node is List) {
    for (int i = 0; i < node.length; i++) {
      out.addAll(prePaths(node[i], '$at[$i]'));
    }
  }
  return out;
}

// ---------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------

class Got {
  Got(this.f, this.raw, this.gameMs);

  final Frame f;
  final String raw;

  /// The game clock when the frame was read off the socket.
  final int gameMs;

  String get t => f['t']! as String;
  Frame get d => fd(f);
}

class P7Client {
  P7Client._(this._ws, this.label, this.rig) {
    _ws.listen(
      (Object? raw) {
        final String text = raw! as String;
        final Frame f = jsonDecode(text) as Frame;
        all.add(Got(f, text, rig.gameMs));
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(f);
        } else {
          _buf.add(f);
        }
      },
      onDone: () {
        closed = true;
        for (final Completer<Frame> w in _waiters) {
          w.completeError(TestFailure('the socket of $label closed while a '
              'frame was awaited on it'));
        }
        _waiters.clear();
      },
      onError: (Object _) {},
    );
  }

  final WebSocket _ws;
  final String label;
  final P7Rig rig;

  /// The seat this socket holds, from its `seat_assigned`.
  int? seat;
  String? token;

  /// Every frame this socket ever received, in arrival order.
  final List<Got> all = <Got>[];
  final List<Frame> _buf = <Frame>[];
  final List<Completer<Frame>> _waiters = <Completer<Frame>>[];
  int _n = 0;
  bool closed = false;

  String send(String type, Frame data) {
    rig.limiterClock.advance(const Duration(milliseconds: 1100));
    final String full =
        'p7-${++_n}-$label'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final String id = full.length > 64 ? full.substring(0, 64) : full;
    _ws.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': id,
      'd': data,
    }));
    return id;
  }

  Future<Frame> next() {
    if (_buf.isNotEmpty) {
      return Future<Frame>.value(_buf.removeAt(0));
    }
    final Completer<Frame> c = Completer<Frame>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _waiters.remove(c);
      throw TestFailure('expected another frame on the socket of $label '
          'within 10 s and none arrived; last frames there: '
          '${fdescAll(all.reversed.take(6).toList().reversed.map((Got g) => g.f))}');
    });
  }

  /// Ping barrier: every frame queued for this socket before the pong.
  Future<List<Frame>> sync() async {
    final String id = send('ping', <String, Object?>{});
    final List<Frame> frames = <Frame>[];
    for (int i = 0; i < 4000; i++) {
      final Frame f = await next();
      if (f['t'] == 'pong' && f['re'] == id) {
        return frames;
      }
      frames.add(f);
    }
    throw TestFailure('no pong on $label within 4000 frames');
  }

  Future<Frame> untilType(String type, {int max = 60}) async {
    final List<Frame> seen = <Frame>[];
    for (int i = 0; i < max; i++) {
      final Frame f = await next();
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
// Rig
// ---------------------------------------------------------------------

class P7Rig {
  P7Rig(this.name, {required this.ruleset, required this.seed});

  final String name;
  final String ruleset;
  final int seed;
  final DateTime t0 = DateTime.utc(2026, 11, 24, 12);
  late final FakeClock clock = FakeClock(t0);
  late final FakeClock limiterClock = FakeClock(t0);
  late RoomRegistry registry;
  late WireServer server;
  late Uri uri;
  final List<P7Client> clients = <P7Client>[];
  int _rooms = 0;
  int _inst = 0;

  int get gameMs => clock.now.difference(t0).inMilliseconds;

  String get repro => 'scenario "$name": ruleset=$ruleset seed=$seed '
      '(registry CSPRNG slot Random($seed), computer source Random(${seed * 1000} '
      '+ n)), fake clock from ${t0.toIso8601String()}. Reproduce: cd '
      'packages/ludo_server && flock /tmp/ludo-suite.lock dart test $_file '
      '--plain-name "$name"';

  Future<void> boot() async {
    registry = RoomRegistry(
      clock: clock,
      secure: Random(seed),
      ruleset: ruleset,
      computerRandom: () => Random(seed * 1000 + (++_rooms)),
    );
    server = WireServer(
      registry: registry,
      rateLimiter: RateLimiter(clock: limiterClock),
      clock: clock,
      automaticTurnExpiry: false,
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    uri = Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');
  }

  Future<P7Client> open(String label) async {
    final WebSocket ws = await WebSocket.connect(uri.toString());
    final P7Client c = P7Client._(ws, label, this);
    clients.add(c);
    return c;
  }

  String install(String tag) => 'inst-c707-$tag-${++_inst}-0123456789';

  /// Moves the game clock by [ms] in 100 ms steps, running the turn sweep
  /// and the computer sweep after each, as the binary's timers do.
  void step(int ms) {
    for (int i = 0; i < ms ~/ 100; i++) {
      clock.advance(const Duration(milliseconds: 100));
      server.runTurnExpiryOnce();
      server.runComputerSeatsOnce();
    }
  }

  Future<void> dispose() async {
    for (final P7Client c in clients) {
      try {
        await c.close();
      } catch (_) {
        // a socket the server already closed
      }
    }
    await server.close();
  }
}

void scenario(
  String name,
  Future<void> Function(P7Rig r) body, {
  String ruleset = '2026-10',
  int seed = 707,
  Timeout timeout = const Timeout(Duration(minutes: 4)),
}) {
  test(name, () async {
    final P7Rig r = P7Rig(name, ruleset: ruleset, seed: seed);
    try {
      await r.boot();
      await body(r);
    } on TestFailure catch (e) {
      throw TestFailure('${e.message}\n${r.repro}');
    } on Object catch (e, s) {
      throw TestFailure('scenario died with ${e.runtimeType}: $e\n$s\n'
          '${r.repro}');
    } finally {
      await r.dispose();
    }
  }, timeout: timeout);
}

// ---------------------------------------------------------------------
// A table and its driver
// ---------------------------------------------------------------------

class Table {
  Table(this.r, this.code);

  final P7Rig r;
  final String code;

  /// The socket that plays each human seat now.
  final Map<int, P7Client> bySeat = <int, P7Client>{};

  /// Sockets that are seated and open; every one is synced after a step.
  final List<P7Client> live = <P7Client>[];

  /// The socket whose frames drive the decisions (sees every broadcast).
  late P7Client observer;

  /// The last frame that asks somebody to act, or `game_over`.
  Frame? cur;
  bool over = false;
  int actions = 0;

  P7Client get host => bySeat[0]!;

  /// Syncs every live socket; returns the frames the observer got.
  Future<List<Frame>> settle() async {
    List<Frame> mine = <Frame>[];
    for (final P7Client c in List<P7Client>.of(live)) {
      final List<Frame> got = await c.sync();
      if (identical(c, observer)) {
        mine = got;
      }
    }
    final Frame? a = lastActionable(mine);
    if (a != null) {
      cur = a;
      if (a['t'] == 'game_over') {
        over = true;
      }
    }
    return mine;
  }

  /// A fresh socket resumes [seat] (a takeover when the seat is connected).
  /// Returns the `room` `d` it is answered with; the new socket plays on.
  Future<Frame> resume(int seat, String label) async {
    final P7Client old = bySeat[seat]!;
    final P7Client c = await r.open(label);
    c.send('resume', <String, Object?>{
      'code': code,
      'seat_token': old.token,
    });
    final Frame sa = await c.next();
    if (sa['t'] != 'seat_assigned') {
      throw TestFailure('resume of seat $seat should answer seat_assigned '
          'first (section 8 rule 4); got ${fdesc(sa)}');
    }
    final Frame room = await c.next();
    if (room['t'] != 'room') {
      throw TestFailure('resume of seat $seat: the second frame should be '
          'room; got ${fdesc(room)}');
    }
    c.seat = fd(sa)['seat']! as int;
    c.token = fd(sa)['seat_token']! as String;
    live.remove(old);
    live.add(c);
    bySeat[seat] = c;
    if (identical(observer, old)) {
      observer = c;
    }
    return fd(room);
  }
}

/// The last frame of [fs] that asks a seat to act, or `game_over`.
Frame? lastActionable(List<Frame> fs) {
  for (final Frame f in fs.reversed) {
    final String t = f['t']! as String;
    if (t == 'turn' || t == 'game_over') {
      return f;
    }
    if (t == 'rolled') {
      final List<Object?> legal = fd(f)['legal'] as List<Object?>? ?? [];
      if (legal.isNotEmpty) {
        return f;
      }
    }
  }
  return null;
}

/// The move a simple client makes from [f] (pre removed): the first legal
/// token of the first face, or the release when one is owed.
Frame? moveFor(Frame f) {
  final Frame d = fd(stripPre(f));
  final List<Object?> legal = d['legal'] as List<Object?>? ?? <Object?>[];
  if (d['release'] == true) {
    return legal.isEmpty ? null : <String, Object?>{'token': legal.first};
  }
  final List<Object?> byFace =
      d['legal_by_face'] as List<Object?>? ?? <Object?>[];
  if (byFace.isNotEmpty) {
    final Frame first = byFace.first! as Frame;
    return <String, Object?>{
      'token': (first['tokens']! as List<Object?>).first,
      'face': first['face'],
    };
  }
  if (legal.isNotEmpty) {
    return <String, Object?>{'token': legal.first};
  }
  return null;
}

/// Creates a room of [players] human seats, joins them by code, starts it.
Future<Table> table(P7Rig r, int players, {Frame? rules}) async {
  final P7Client h = await r.open('seat-host');
  h.send('create_room', <String, Object?>{
    'name': 'Host',
    'players': players,
    'install': r.install('host'),
    if (rules != null) 'rules': rules,
  });
  final Frame sa = await h.next();
  if (sa['t'] != 'seat_assigned') {
    throw TestFailure('create_room should answer seat_assigned; got '
        '${fdesc(sa)}');
  }
  final Frame room = await h.untilType('room');
  h.seat = fd(sa)['seat']! as int;
  h.token = fd(sa)['seat_token']! as String;
  final Table t = Table(r, fd(room)['code']! as String);
  t.bySeat[h.seat!] = h;
  t.live.add(h);
  t.observer = h;
  const List<String> names = <String>['Ann', 'Bea', 'Cid'];
  for (int i = 1; i < players; i++) {
    final P7Client g = await r.open('seat-guest$i');
    g.send('join_room', <String, Object?>{
      'code': t.code,
      'name': names[i - 1],
      'install': r.install('g$i'),
    });
    final Frame gs = await g.next();
    if (gs['t'] != 'seat_assigned') {
      throw TestFailure('join_room by code should seat guest $i; got '
          '${fdesc(gs)}');
    }
    await g.untilType('room');
    g.seat = fd(gs)['seat']! as int;
    g.token = fd(gs)['seat_token']! as String;
    t.bySeat[g.seat!] = g;
    t.live.add(g);
  }
  await t.settle();
  h.send('start_game', <String, Object?>{});
  await t.settle();
  if (t.cur?['t'] != 'turn') {
    throw TestFailure('start_game: the opening turn never reached the host; '
        'host frames: ${fdescAll(h.all.map((Got g) => g.f))}');
  }
  return t;
}

/// Plays one step for whoever [t.cur] names: a human seat acts, a computer
/// seat is given 100 ms of clock. Returns the observer's new frames.
Future<List<Frame>> playStep(Table t, String row) async {
  final Frame f = t.cur!;
  final Frame d = fd(stripPre(f));
  final int seat = d['seat']! as int;
  final P7Client? c = t.bySeat[seat];
  if (c == null) {
    t.r.step(100);
    return t.settle();
  }
  if (f['t'] == 'turn' && d['phase'] == 'await_roll') {
    c.send('roll', <String, Object?>{});
  } else {
    final Frame? m = moveFor(f);
    if (m == null) {
      throw TestFailure('$row: the driver has nothing to do on ${fdesc(f)}');
    }
    c.send('move', m);
  }
  t.actions++;
  final List<Frame> got = await t.settle();
  for (final Frame g in got) {
    if (g['t'] == 'error') {
      throw TestFailure('$row: the server refused the scripted client: '
          '${fdesc(g)} after ${fdesc(f)}');
    }
  }
  if (identical(t.cur, f) && c.closed == false && got.isEmpty) {
    throw TestFailure('$row: no frame followed the action on ${fdesc(f)}');
  }
  return got;
}

/// Plays until a frame among the observer's new frames satisfies [stop];
/// returns it. [stop] is also tried on the current frame first.
Future<Frame> playUntil(Table t, bool Function(Frame f) stop, String row,
    {int max = 60000}) async {
  if (t.cur != null && stop(t.cur!)) {
    return t.cur!;
  }
  for (int i = 0; i < max; i++) {
    if (t.over) {
      throw TestFailure('$row: the game ended before the awaited frame');
    }
    final List<Frame> got = await playStep(t, row);
    for (final Frame g in got) {
      if (stop(g)) {
        return g;
      }
    }
  }
  throw TestFailure('$row: the awaited frame did not come within $max steps');
}

bool isRollTurn(Frame f, [int? seat]) =>
    f['t'] == 'turn' &&
    fd(f)['phase'] == 'await_roll' &&
    (seat == null || fd(f)['seat'] == seat);

// ---------------------------------------------------------------------
// Whole-game analysis
// ---------------------------------------------------------------------

class TurnCopy {
  TurnCopy(this.client, this.d);
  final P7Client client;
  final Frame d;
}

class Analysis {
  final List<String> copyViolations = <String>[];
  final List<String> preVsRolled = <String>[];
  final List<String> leaks = <String>[];

  /// Context of each await_roll turn seq -> name.
  final Map<int, String> context = <int, String>{};
  final Map<String, int> contextCount = <String, int>{};
  final Map<String, int> contextWithPre = <String, int>{};
  int awaitRollTurns = 0;
  int humanRollTurns = 0;
  int presOnRoller = 0;
  int presCompared = 0;
  int releasePres = 0;
  int legalByFacePres = 0;
  int totalFrames = 0;
}

/// Section 35 item 1 on every `turn` frame every socket received, item 2's
/// equality with the following `rolled`, and item 4's whole-game leak check.
Analysis analyse(List<P7Client> clients, {Set<int> bots = const <int>{}}) {
  final Analysis a = Analysis();

  // Every copy of every turn frame, by seq.
  final Map<int, List<TurnCopy>> turns = <int, List<TurnCopy>>{};
  for (final P7Client c in clients) {
    for (final Got g in c.all) {
      a.totalFrames++;
      if (g.t == 'turn' && g.d['seq'] is int) {
        turns.putIfAbsent(g.d['seq']! as int, () => <TurnCopy>[])
          ..add(TurnCopy(c, g.d));
      }
      // Item 4: the string "pre" only on the roller's own socket, in its own
      // await_roll turn frame or its own snapshot turn.
      if (g.raw.contains('"pre"')) {
        bool allowed = false;
        if (g.t == 'turn' &&
            g.d['seat'] == c.seat &&
            g.d['phase'] == 'await_roll') {
          allowed = prePaths(g.f['d']).every((String p) => p == 'd.pre');
        }
        if (g.t == 'room' && g.d['turn'] is Map) {
          final Frame turn = (g.d['turn']! as Map).cast<String, Object?>();
          allowed = turn['seat'] == c.seat &&
              turn['phase'] == 'await_roll' &&
              prePaths(g.f['d']).every((String p) => p == 'd.turn.pre');
        }
        if (!allowed) {
          a.leaks.add('"pre" in ${g.t} to ${c.label} (seat ${c.seat}) at '
              'game ms ${g.gameMs}: ${_clip(g.raw, 300)}');
        }
      }
    }
  }

  // One copy of every broadcast frame by seq, from whichever socket got it
  // (a snapshot's own seq is not a broadcast and is left out).
  final Map<int, Frame> obsBySeq = <int, Frame>{};
  for (final P7Client c in clients) {
    for (final Got g in c.all) {
      if (g.t != 'room' && g.d['seq'] is int) {
        obsBySeq.putIfAbsent(g.d['seq']! as int, () => g.f);
      }
    }
  }
  final List<Frame> bySeqOrder = <Frame>[
    for (final int s in (obsBySeq.keys.toList()..sort())) obsBySeq[s]!,
  ];

  String contextOf(int seq, int seat) {
    final Frame? prev = obsBySeq[seq - 1];
    if (prev == null) {
      return 'unknown (no frame at seq ${seq - 1} on any socket)';
    }
    final Frame pd = fd(prev);
    switch (prev['t']) {
      case 'game_started':
        return 'first turn';
      case 'turn_passed':
        return 'after a passed turn (turn_passed ${pd['reason']})';
      case 'rolled':
        return pd['seat'] == seat && pd['value'] == 6
            ? 'after a six that owes another roll'
            : 'after rolled ${pd['value']}';
      case 'moved':
        final List<Object?> cap = pd['captured'] as List<Object?>? ?? [];
        if (pd['seat'] == seat && pd['extra_roll'] == true && cap.isNotEmpty) {
          return 'after a capture bonus';
        }
        if (pd['seat'] == seat && pd['extra_roll'] == true) {
          return 'after a home bonus';
        }
        return 'after a move that ended the turn';
      default:
        return 'after ${prev['t']}';
    }
  }

  final List<int> seqs = turns.keys.toList()..sort();
  for (final int seq in seqs) {
    final List<TurnCopy> copies = turns[seq]!;
    final Frame d0 = copies.first.d;
    final int seat = d0['seat']! as int;
    final String phase = '${d0['phase']}';
    final String base = canon(without(d0, <String>['pre']));
    for (final TurnCopy c in copies) {
      if (canon(without(c.d, <String>['pre'])) != base) {
        a.copyViolations.add('turn seq $seq: the copy to ${c.client.label} '
            'differs from the copy to ${copies.first.client.label} by more '
            'than "pre": ${canon(c.d)} vs ${canon(d0)} (expected one frame, '
            'one seq, only the roller\'s copy differing by the one key)');
      }
    }
    if (phase != 'await_roll') {
      for (final TurnCopy c in copies) {
        if (c.d.containsKey('pre')) {
          a.copyViolations.add('turn seq $seq (phase $phase, seat $seat) to '
              '${c.client.label} carries pre=${canon(c.d['pre'])}; expected '
              'pre only in await_roll (item 1)');
        }
      }
      continue;
    }
    a.awaitRollTurns++;
    final String ctx = contextOf(seq, seat);
    a.context[seq] = ctx;
    a.contextCount[ctx] = (a.contextCount[ctx] ?? 0) + 1;
    final bool human = !bots.contains(seat);
    if (human) {
      a.humanRollTurns++;
    }
    Frame? pre;
    for (final TurnCopy c in copies) {
      final bool roller = c.client.seat == seat;
      final Object? p = c.d['pre'];
      if (roller && human) {
        if (p is! Map) {
          a.copyViolations.add('turn seq $seq ($ctx), seat $seat in '
              'await_roll: the roller\'s own copy (${c.client.label}) has no '
              'pre; expected "pre": {seat, value, legal, k, queue, ...} '
              '(item 1); got ${canon(c.d)}');
        } else {
          pre = p.cast<String, Object?>();
          a.presOnRoller++;
          a.contextWithPre[ctx] = (a.contextWithPre[ctx] ?? 0) + 1;
        }
      } else if (c.d.containsKey('pre')) {
        a.copyViolations.add(
            'turn seq $seq ($ctx), seat $seat${human ? '' : ' (a computer seat)'}: the '
            'copy to ${c.client.label} (seat ${c.client.seat}) carries '
            'pre=${canon(c.d['pre'])}; expected no pre on any socket but the '
            'roller\'s own${human ? '' : ', and none at all for a computer '
                'seat (item 1)'}');
      }
    }
    if (pre == null) {
      continue;
    }
    if (pre.containsKey('release')) {
      a.releasePres++;
    }
    if (pre.containsKey('legal_by_face')) {
      a.legalByFacePres++;
    }
    // Item 2: the rolled that follows equals pre, field for field.
    Frame? rolled;
    for (final Frame f in bySeqOrder) {
      if ((fd(f)['seq']! as int) > seq && f['t'] == 'rolled') {
        rolled = f;
        break;
      }
    }
    if (rolled == null) {
      // The game may end before a roll only if it ended at this turn.
      a.preVsRolled.add('turn seq $seq ($ctx): pre=${canon(pre)} was sent '
          'and no rolled followed in the observer log (item 3: a roll that '
          'was shown is always published)');
      continue;
    }
    a.presCompared++;
    final Frame want = without(fd(rolled), rolledOnlyKeys);
    if (canon(want) != canon(pre)) {
      a.preVsRolled.add('turn seq $seq ($ctx): pre=${canon(pre)} but the '
          'following rolled (seq ${fd(rolled)['seq']}) less seq, reveal, '
          'deadline_ms and by is ${canon(want)} (item 2: equal field for '
          'field)');
    }
  }
  return a;
}

/// Fails with [reason] when [violations] is not empty. The reason lists the
/// first few; the list itself is not printed whole.
void none(List<String> violations, {required String reason}) {
  if (violations.isNotEmpty) {
    throw TestFailure(reason);
  }
}

String _firstN(List<String> xs, [int n = 8]) =>
    '${xs.length} found; first ${min(n, xs.length)}:\n  '
    '${xs.take(n).join('\n  ')}';

// ---------------------------------------------------------------------
// A whole scripted game
// ---------------------------------------------------------------------

class LogRequest {
  LogRequest(this.seat, this.when, this.heldPre, this.entries, this.parts,
      this.violations);
  final int seat;
  final String when;
  final bool heldPre;
  final int entries;
  final int parts;
  final List<String> violations;
}

class GameRun {
  GameRun(this.r, this.t);
  final P7Rig r;
  final Table t;
  late Analysis a;
  final List<LogRequest> logs = <LogRequest>[];
  Frame? gameOver;
}

/// Sends `game_log` from [seat]'s socket and reads every part.
Future<LogRequest> askLog(Table t, int seat, String when) async {
  final P7Client c = t.bySeat[seat]!;
  // Section 17 item 4: 2 per minute per connection, on the limiter's clock.
  t.r.limiterClock.advance(const Duration(seconds: 61));
  bool heldPre = false;
  for (final Got g in c.all.reversed) {
    if (g.t == 'turn') {
      heldPre = g.d['seat'] == c.seat &&
          g.d['phase'] == 'await_roll' &&
          g.d['pre'] is Map;
      break;
    }
  }
  final String id = c.send('game_log', <String, Object?>{});
  final List<Frame> got = await c.sync();
  final List<Frame> parts = <Frame>[
    for (final Frame f in got)
      if (f['t'] == 'game_log' && f['re'] == id) f,
  ];
  final List<String> v = <String>[];
  int entries = 0;
  if (parts.isEmpty || fd(parts.last)['part'] != fd(parts.last)['parts']) {
    v.add('game_log by seat $seat $when: the parts did not all arrive; got '
        '${fdescAll(got)}');
  }
  for (final Frame p in parts) {
    for (final Object? e in fd(p)['frames'] as List<Object?>? ?? []) {
      entries++;
      final String s = jsonEncode(e);
      if (s.contains('"pre"') || prePaths(e).isNotEmpty) {
        v.add('game_log by seat $seat $when: entry ${_clip(s, 300)} carries '
            '"pre" (expected no game_log entry ever to hold an unrolled '
            'face; section 17 item 6, section 35 item 4)');
      }
    }
  }
  return LogRequest(seat, when, heldPre, entries, parts.length, v);
}

Future<GameRun> playWholeGame(P7Rig r, int players) async {
  final Table t = await table(r, players);
  final GameRun run = GameRun(r, t);
  int rollTurns = 0;
  for (int i = 0; i < 40000 && !t.over; i++) {
    final Frame f = t.cur!;
    if (isRollTurn(f)) {
      rollTurns++;
      // Every 30th await_roll turn the seat on turn asks for the log while
      // it holds its pre, and so does the seat after it.
      if (rollTurns % 30 == 1) {
        final int s = fd(f)['seat']! as int;
        run.logs.add(await askLog(
            t,
            s,
            'mid-game (roll turn $rollTurns, '
            'its own await_roll)'));
        final List<int> seats = t.bySeat.keys.toList()..sort();
        final int other = seats[(seats.indexOf(s) + 1) % seats.length];
        run.logs.add(await askLog(
            t,
            other,
            'mid-game (roll turn '
            '$rollTurns, seat $s on turn)'));
      }
    }
    await playStep(t, 'whole game');
  }
  if (!t.over) {
    throw TestFailure('the scripted game did not reach game_over within '
        '40000 steps');
  }
  run.gameOver = t.cur;
  for (final int s in t.bySeat.keys) {
    run.logs.add(await askLog(t, s, 'after game_over'));
  }
  run.a = analyse(t.live);
  return run;
}

// ---------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------

/// The pre on [c]'s copy of the turn frame with [seq], or null.
Frame? preOn(P7Client c, int seq) {
  for (final Got g in c.all) {
    if (g.t == 'turn' && g.d['seq'] == seq) {
      final Object? p = g.d['pre'];
      return p is Map ? p.cast<String, Object?>() : null;
    }
  }
  return null;
}

/// Requires [c]'s copy of [turn] to carry a pre; returns it.
Frame requirePre(P7Client c, Frame turn, String row) {
  final int seq = fd(turn)['seq']! as int;
  final Frame? p = preOn(c, seq);
  if (p == null) {
    throw TestFailure('$row: section 35 item 1: the roller\'s own copy of the '
        'await_roll turn (seq $seq, seat ${fd(turn)['seat']}) should carry '
        '"pre"; the copy to ${c.label} was '
        '${fdescAll(c.all.where((Got g) => g.t == 'turn' && g.d['seq'] == seq).map((Got g) => g.f))}');
  }
  return p;
}

void expectNoPreElsewhere(Table t, int seq, int seat, String row) {
  for (final P7Client c in t.live) {
    if (c.seat == seat) {
      continue;
    }
    for (final Got g in c.all) {
      if (g.t == 'turn' && g.d['seq'] == seq && g.d.containsKey('pre')) {
        throw TestFailure('$row: item 1: the copy of turn seq $seq to '
            '${c.label} (seat ${c.seat}) carries pre=${canon(g.d['pre'])}; '
            'expected pre on seat $seat\'s socket only');
      }
    }
  }
}

/// Item 3 on the sockets in [watch]: after the departing seat held [pre], the
/// first `rolled` is that roll, by the timer, equal to pre; it comes before
/// `seat_retired` [reason]; the next other seat's pre has k + 1.
void expectShownRollPublished(
  Table t,
  List<P7Client> watch,
  int Function(P7Client c) fromIndexOf,
  Frame pre,
  int seat,
  String reason,
  String row,
) {
  final int k = pre['k']! as int;
  for (final P7Client c in watch) {
    final List<Got> fs = c.all.sublist(fromIndexOf(c));
    final String seen = fdescAll(fs.map((Got g) => g.f));
    final int iRolled = fs.indexWhere((Got g) => g.t == 'rolled');
    final int iRetired = fs.indexWhere((Got g) => g.t == 'seat_retired');
    if (iRetired < 0) {
      throw TestFailure('$row: ${c.label}: expected seat_retired '
          '{seat $seat, reason $reason}; got $seen');
    }
    expect(fs[iRetired].d['reason'], reason,
        reason: '$row: ${c.label}: seat_retired reason; got $seen');
    if (iRolled < 0 || iRolled > iRetired) {
      throw TestFailure('$row: item 3: ${c.label}: the seat held pre '
          '${canon(pre)}; expected rolled {by: "timer", k: $k} before '
          'seat_retired $reason, got $seen');
    }
    final Frame rd = fs[iRolled].d;
    expect(rd['by'], 'timer',
        reason: '$row: item 3: ${c.label}: the published roll is taken as '
            'the timer would, by: "timer"; got ${fdesc(fs[iRolled].f)}');
    expect(canon(without(rd, rolledOnlyKeys)), canon(pre),
        reason: '$row: item 2/3: ${c.label}: the rolled published for the '
            'departing seat equals the pre it was shown; got '
            '${fdesc(fs[iRolled].f)}');
    for (final Got g in fs.sublist(iRolled + 1, iRetired)) {
      if (g.t == 'rolled') {
        throw TestFailure('$row: item 3: ${c.label}: a second roll before the '
            'retire: ${fdesc(g.f)}; got $seen');
      }
    }
  }
  // The next seat's pre: the first await_roll turn for another seat after the
  // timer's roll, on that seat's own socket.
  for (final P7Client c in t.live) {
    final List<Got> fs = c.all.sublist(fromIndexOf(c));
    final int iNext = fs.indexWhere((Got g) =>
        g.t == 'turn' && g.d['phase'] == 'await_roll' && g.d['seat'] != seat);
    if (iNext < 0) {
      throw TestFailure('$row: ${c.label}: expected a turn for the next '
          'seat after the retire; got ${fdescAll(fs.map((Got g) => g.f))}');
    }
    final Got next = fs[iNext];
    if (next.d['seat'] == c.seat) {
      final Object? p = next.d['pre'];
      if (p is! Map) {
        throw TestFailure('$row: item 1/3: the next seat\'s own copy of its '
            'turn should carry pre with k ${k + 1}; got ${fdesc(next.f)}');
      }
      expect(p['k'], k + 1,
          reason: '$row: item 3: the next seat\'s roll is a new link: pre.k '
              'expected ${k + 1} (the departing seat\'s was $k); got '
              '${canon(p)}');
    } else {
      expect(next.d.containsKey('pre'), isFalse,
          reason: '$row: item 1: ${c.label} is not the next seat; its copy '
              'of the turn has no pre; got ${fdesc(next.f)}');
    }
  }
}

void main() {
  // -------------------------------------------------------------------
  // Whole scripted games: items 1, 2 and 4 over every frame.
  // -------------------------------------------------------------------
  for (final (String ruleset, int seed) in <(String, int)>[
    ('2026-10', 7071),
    ('2026-11', 7072),
    ('2026-12', 7073),
  ]) {
    group('whole game, four seats, ruleset $ruleset, seed $seed', () {
      final P7Rig r =
          P7Rig('whole game $ruleset seed $seed', ruleset: ruleset, seed: seed);
      GameRun? run;
      Object? failure;

      setUpAll(() async {
        try {
          await r.boot();
          run = await playWholeGame(r, 4);
        } on Object catch (e, s) {
          failure = '$e\n$s';
        }
      });
      tearDownAll(() => r.dispose());

      GameRun need() {
        if (failure != null) {
          throw TestFailure('the scripted game itself failed: $failure\n'
              '${r.repro}');
        }
        return run!;
      }

      String repro(String row) =>
          'ruleset=$ruleset seed=$seed four human seats, each acting at once '
          'with its first legal token. Reproduce: cd packages/ludo_server && '
          'flock /tmp/ludo-suite.lock dart test $_file --plain-name "$row"';

      const String p1 = 'P1 pre on the roller\'s copy of the await_roll turn '
          'and on no other copy (same seq): first turn, after a passed turn, '
          'after a six, after a capture bonus';
      test(p1, () {
        final GameRun g = need();
        final Analysis a = g.a;
        // Coverage first: without these contexts the row proves nothing.
        final List<String> wanted = <String>[
          'first turn',
          'after a passed turn (turn_passed no_legal_move)',
          'after a six that owes another roll',
          'after a capture bonus',
        ];
        final List<String> missing = <String>[
          for (final String w in wanted)
            if ((a.contextCount[w] ?? 0) == 0) w,
        ];
        expect(missing, isEmpty,
            reason: 'fixture: the scripted game never produced an await_roll '
                'turn $missing; contexts seen ${a.contextCount}; pick another '
                'seed. ${repro(p1)}');
        none(a.copyViolations,
            reason: 'item 1: ${_firstN(a.copyViolations)}\n'
                'await_roll turns ${a.awaitRollTurns}, pre seen on the '
                'roller\'s copy ${a.presOnRoller}, by context with pre '
                '${a.contextWithPre}, contexts ${a.contextCount}. '
                '${repro(p1)}');
      });

      const String p2 = 'P2 pre equals the following rolled less seq, '
          'reveal, deadline_ms and by, field for field, over the whole game';
      test(p2, () {
        final GameRun g = need();
        final Analysis a = g.a;
        expect(a.presCompared, greaterThan(0),
            reason: 'item 2: no pre arrived on any roller\'s socket in '
                '${a.awaitRollTurns} await_roll turns, so nothing could be '
                'compared with its rolled (expected one pre per human '
                'await_roll turn). ${repro(p2)}');
        expect(a.presCompared, a.humanRollTurns,
            reason: 'item 2: every await_roll turn should have carried a pre '
                'compared with its rolled; compared ${a.presCompared} of '
                '${a.humanRollTurns}. ${repro(p2)}');
        none(a.preVsRolled,
            reason: 'item 2: ${_firstN(a.preVsRolled)}\n${repro(p2)}');
        // ignore: avoid_print
        print('$p2 [$ruleset]: ${a.presCompared} pre compared, '
            '${a.legalByFacePres} with legal_by_face, ${a.releasePres} with '
            'release');
      });

      const String p3 = 'P3 a client that never reads pre plays the whole '
          'game to game_over on today\'s frames';
      test(p3, () {
        final GameRun g = need();
        expect(g.gameOver?['t'], 'game_over',
            reason: 'item 2: the game should end; last frame '
                '${g.gameOver == null ? '(none)' : fdesc(g.gameOver!)}. '
                '${repro(p3)}');
        // Today's frames: every copy of a turn equals every other copy once
        // pre is taken off, so the stripped frame is the one every socket got.
        final List<String> diff = <String>[
          for (final String v in g.a.copyViolations)
            if (v.contains('differs from the copy')) v,
        ];
        none(diff,
            reason: 'item 2: a frame differs between copies by more than '
                'pre: ${_firstN(diff)}\n${repro(p3)}');
        // ignore: avoid_print
        print('$p3 [$ruleset]: ${g.t.actions} actions, '
            '${g.a.totalFrames} frames on ${g.t.live.length} sockets');
      });

      const String p4 = 'P4 no frame to any socket other than the roller\'s '
          'holds "pre": every captured frame of the whole game';
      test(p4, () {
        final GameRun g = need();
        none(g.a.leaks, reason: 'item 4: ${_firstN(g.a.leaks)}\n${repro(p4)}');
        expect(g.a.presOnRoller, greaterThan(0),
            reason: 'item 4: the row needs a face on a roller\'s socket to '
                'mean anything, and no pre arrived on any roller\'s socket '
                'in ${g.a.awaitRollTurns} await_roll turns (item 1 expects '
                'one on each). ${repro(p4)}');
      });

      const String p5 = 'P5 game_log asked by any seat, mid-game and after '
          'game_over, holds no entry with pre';
      test(p5, () {
        final GameRun g = need();
        final List<String> v = <String>[
          for (final LogRequest l in g.logs) ...l.violations,
        ];
        none(v, reason: '${_firstN(v)}\n${repro(p5)}');
        expect(g.logs.where((LogRequest l) => l.entries > 0), isNotEmpty,
            reason: 'fixture: every game_log answer was empty. ${repro(p5)}');
        final int heldPre = g.logs.where((LogRequest l) => l.heldPre).length;
        expect(heldPre, greaterThan(0),
            reason: 'the row needs a request from a seat holding its pre; '
                'none of the ${g.logs.length} requests came from a socket '
                'whose last turn frame carried pre (item 1 puts one on every '
                'await_roll turn of the seat on turn). ${repro(p5)}');
      });
    });
  }

  // -------------------------------------------------------------------
  // Snapshots and the roll counter.
  // -------------------------------------------------------------------
  scenario(
      'S1 the roller\'s snapshot carries the pre of its turn frame, an '
      'opponent\'s snapshot of the same instant does not; two snapshots give '
      'the same pre and the rolled that follows has its k', (P7Rig r) async {
    final Table t = await table(r, 3);
    for (final String when in <String>['first turn', 'mid-game']) {
      if (when == 'mid-game') {
        int rolls = 0;
        await playUntil(t, (Frame f) {
          if (f['t'] == 'rolled') {
            rolls++;
          }
          return rolls >= 12 && isRollTurn(f);
        }, 'S1 to mid-game');
      }
      final Frame turn = t.cur!;
      final int seat = fd(turn)['seat']! as int;
      final int seq = fd(turn)['seq']! as int;
      final String row = 'S1 $when (seat $seat on turn, turn seq $seq)';
      final Frame pushed = requirePre(t.bySeat[seat]!, turn, row);
      expectNoPreElsewhere(t, seq, seat, row);

      final Frame s1 = await t.resume(seat, 'roller-snap1-$when');
      final Frame s2 = await t.resume(seat, 'roller-snap2-$when');
      final int other = t.bySeat.keys.firstWhere((int s) => s != seat);
      final Frame so = await t.resume(other, 'opponent-snap-$when');
      await t.settle();

      for (final (String name, Frame s) in <(String, Frame)>[
        ('first roller snapshot', s1),
        ('second roller snapshot', s2),
      ]) {
        final Frame st = (s['turn']! as Map).cast<String, Object?>();
        expect(
            <Object?>[st['seat'], st['phase']], <Object?>[seat, 'await_roll'],
            reason: '$row: $name turn; got ${canon(st)}');
        expect(st['pre'], isA<Map<String, Object?>>(),
            reason: '$row: item 1: the $name turn object should carry pre '
                '(the seat on turn\'s own socket, await_roll); got '
                '${canon(st)}');
        expect(canon(st['pre']), canon(pushed),
            reason: '$row: item 1: the $name pre equals the pre of the '
                'pushed turn frame (k not advanced by sending it); got '
                '${canon(st['pre'])} vs pushed ${canon(pushed)}');
        expect(st['k'], (pushed['k']! as int) - 1,
            reason: '$row: section 6: turn.k is the rolls made so far, one '
                'below pre.k; got turn ${canon(st)}, pre ${canon(pushed)}');
      }
      final Frame ot = (so['turn']! as Map).cast<String, Object?>();
      expect(prePaths(so), isEmpty,
          reason: '$row: item 1: the opponent\'s (seat $other) snapshot of '
              'the same instant carries no pre anywhere; got turn '
              '${canon(ot)}');
      expect(
          canon(without(ot, <String>['pre', 'deadline_ms'])),
          canon(without((s2['turn']! as Map).cast<String, Object?>(),
              <String>['pre', 'deadline_ms'])),
          reason: '$row: the two snapshots of the same instant differ only '
              'by pre');

      // The roll from the newest roller socket gets exactly that pre.
      final List<Frame> got = await playStep(t, row);
      final Frame rolled = got.firstWhere((Frame f) => f['t'] == 'rolled',
          orElse: () => throw TestFailure('$row: no rolled after roll; got '
              '${fdescAll(got)}'));
      expect(fd(rolled)['k'], pushed['k'],
          reason: '$row: item 1: k was not advanced by sending pre (twice): '
              'the rolled has pre.k ${pushed['k']}; got ${fdesc(rolled)}');
      expect(canon(without(fd(rolled), rolledOnlyKeys)), canon(pushed),
          reason: '$row: item 2: rolled equals pre; got ${fdesc(rolled)}');
    }
  });

  // -------------------------------------------------------------------
  // Item 3: a seat that was shown a roll and leaves the turn.
  // -------------------------------------------------------------------
  Future<(Table, Frame, Frame)> seatOneHoldsPre(P7Rig r, String row,
      {Frame? rules}) async {
    final Table t = await table(r, 3, rules: rules);
    // Seat 1's first await_roll turn after seat 0's (a passed turn, so a
    // grace under 2026-11).
    final Frame turn = await playUntil(
        t,
        (Frame f) =>
            isRollTurn(f, 1) &&
            t.observer.all.any((Got g) => g.t == 'rolled' && g.d['seat'] == 0),
        '$row: to seat 1\'s turn');
    final Frame pre = requirePre(t.bySeat[1]!, turn, row);
    expectNoPreElsewhere(t, fd(turn)['seq']! as int, 1, row);
    return (t, turn, pre);
  }

  scenario(
      'R1 leave_room by a seat holding a pre: rolled by timer equal to the '
      'pre first, then seat_retired left; the next seat\'s pre has k + 1',
      (P7Rig r) async {
    const String row = 'R1';
    final (Table t, Frame _, Frame pre) = await seatOneHoldsPre(r, row);
    final Map<P7Client, int> mark = <P7Client, int>{
      for (final P7Client c in t.live) c: c.all.length,
    };
    final P7Client leaver = t.bySeat[1]!;
    final String id = leaver.send('leave_room', <String, Object?>{});
    final List<Frame> lf = await leaver.sync();
    t.live.remove(leaver);
    t.bySeat.remove(1);
    await t.settle();
    // Section 28 item 4 (left): the leaver's socket gets the seat_retired
    // with re. Whether it also gets the forced rolled first is not settled
    // by section 35; it is not asserted here (see the order report).
    final List<Frame> lr = <Frame>[
      for (final Frame f in lf)
        if (f['t'] == 'seat_retired') f,
    ];
    expect(lr.length == 1 && lr.single['re'] == id, isTrue,
        reason: '$row: section 28 item 4: the leaver gets one seat_retired '
            'with re $id; got ${fdescAll(lf)}');
    expectShownRollPublished(t, <P7Client>[t.bySeat[0]!, t.bySeat[2]!],
        (P7Client c) => mark[c]!, pre, 1, 'left', row);
  }, ruleset: '2026-11');

  scenario(
      'R2 the host kicks a seat holding a pre in PLAYING: rolled by timer '
      'equal to the pre first, then seat_retired kicked; the next seat\'s pre '
      'has k + 1', (P7Rig r) async {
    const String row = 'R2';
    final (Table t, Frame _, Frame pre) = await seatOneHoldsPre(r, row);
    final Map<P7Client, int> mark = <P7Client, int>{
      for (final P7Client c in t.live) c: c.all.length,
    };
    final P7Client kicked = t.bySeat[1]!;
    final String kickId = t.host.send('kick', <String, Object?>{'seat': 1});
    await t.host.sync();
    final List<Frame> kf = await kicked.sync();
    t.live.remove(kicked);
    t.bySeat.remove(1);
    await t.settle();
    expect(kf.isNotEmpty && kf.last['t'] == 'kicked', isTrue,
        reason: '$row: section 33 item 8: the kicked socket ends with kicked '
            '{ }; got ${fdescAll(kf)}');
    expectShownRollPublished(t, <P7Client>[t.bySeat[0]!, t.bySeat[2]!],
        (P7Client c) => mark[c]!, pre, 1, 'kicked', row);
    // Section 35 item 7(c): the forced roll's frames carry the kick's re on
    // the host's copies.
    final Got hostRolled = t.host.all
        .sublist(mark[t.host]!)
        .firstWhere((Got g) => g.t == 'rolled');
    expect(hostRolled.f['re'], kickId,
        reason: '$row: item 7(c): the host\'s copy of the forced rolled '
            'carries the kick\'s re $kickId; got ${fdesc(hostRolled.f)}');
  }, ruleset: '2026-11');

  scenario(
      'R3 a seat holding a pre is retired as absent: rolled by timer equal '
      'to the pre first, then seat_retired absent; the next seat\'s pre has '
      'k + 1', (P7Rig r) async {
    const String row = 'R3';
    // turn_seconds 120 and the grace of a passed turn put the turn timer
    // after the 120 000 ms absent count, so the retire is what acts.
    final (Table t, Frame turn, Frame pre) = await seatOneHoldsPre(r, row,
        rules: <String, Object?>{'turn_seconds': 120});
    final int grace = (fd(turn)['grace_ms'] as int?) ?? 0;
    expect(grace, greaterThan(0),
        reason: '$row: fixture: section 29 gives seat 1\'s passed-in turn a '
            'grace; got ${fdesc(turn)}');
    final Map<P7Client, int> mark = <P7Client, int>{
      for (final P7Client c in t.live) c: c.all.length,
    };
    final int droppedAt = r.gameMs;
    final P7Client gone = t.bySeat[1]!;
    t.live.remove(gone);
    t.bySeat.remove(1);
    await gone.close();
    // Wait on the condition: the host has been told the seat is down.
    final P7Client h = t.host;
    for (int i = 0; i < 200; i++) {
      await t.settle();
      if (h.all.sublist(mark[h]!).any((Got g) =>
          g.t == 'presence' && g.d['seat'] == 1 && g.d['connected'] == false)) {
        break;
      }
      if (i == 199) {
        throw TestFailure('$row: fixture: the host never got presence '
            '{seat 1, connected: false} after the socket closed');
      }
    }
    int? actedAt;
    for (int i = 0; i < 125 && actedAt == null; i++) {
      r.step(1000);
      await t.settle();
      if (h.all
          .sublist(mark[h]!)
          .any((Got g) => g.t == 'rolled' || g.t == 'seat_retired')) {
        actedAt = r.gameMs - droppedAt;
      }
    }
    expect(actedAt, isNotNull,
        reason: '$row: nothing happened within 125 s of the drop');
    expect(actedAt! < 120000 + grace, isTrue,
        reason: '$row: fixture: the absent retire (section 28 item 4, 120 s) '
            'should act before the turn timer (grace $grace + 120 000 ms); '
            'the first frame came at $actedAt ms');
    expectShownRollPublished(t, <P7Client>[t.bySeat[0]!, t.bySeat[2]!],
        (P7Client c) => mark[c]!, pre, 1, 'absent', row);
  }, ruleset: '2026-11');

  scenario(
      'R4 a turn timer expiry takes the roll that was shown (rolled by timer '
      'equal to the pre) and the next pre is a new link', (P7Rig r) async {
    const String row = 'R4';
    final Table t = await table(r, 2);
    final Frame turn = t.cur!;
    final int seat = fd(turn)['seat']! as int;
    final Frame pre = requirePre(t.bySeat[seat]!, turn, row);
    final int k = pre['k']! as int;
    final Map<P7Client, int> mark = <P7Client, int>{
      for (final P7Client c in t.live) c: c.all.length,
    };
    final int wait = (fd(turn)['deadline_ms']! as int) +
        ((fd(turn)['grace_ms'] as int?) ?? 0);
    r.step(wait - 100);
    await t.settle();
    expect(t.host.all.sublist(mark[t.host]!).where((Got g) => g.t == 'rolled'),
        isEmpty,
        reason: '$row: fixture: nothing before the deadline');
    r.step(100);
    await t.settle();
    final Got? rolled = t.host.all
        .sublist(mark[t.host]!)
        .cast<Got?>()
        .firstWhere((Got? g) => g!.t == 'rolled', orElse: () => null);
    expect(rolled, isNotNull,
        reason: '$row: the timer takes the roll at the deadline ($wait ms)');
    expect(rolled!.d['by'], 'timer',
        reason: '$row: section 22: by timer; got ${fdesc(rolled.f)}');
    expect(canon(without(rolled.d, rolledOnlyKeys)), canon(pre),
        reason: '$row: item 2/3: the timer\'s roll is the one shown: pre '
            '${canon(pre)}; got ${fdesc(rolled.f)}');
    final Frame next = await playUntil(t, (Frame f) => isRollTurn(f), row);
    final int ns = fd(next)['seat']! as int;
    final Frame np = requirePre(t.bySeat[ns]!, next, '$row next turn');
    expect(np['k'], k + 1,
        reason: '$row: item 3: the next pre is a new link, k ${k + 1}; got '
            '${canon(np)}');
  });

  // -------------------------------------------------------------------
  // Computer seats.
  // -------------------------------------------------------------------
  for (final int players in <int>[2, 4]) {
    scenario(
        'C$players a computer seat\'s turn carries no pre on any socket nor in '
        'a snapshot (play_computer, $players seats, to game_over); the '
        'human\'s own turns do', (P7Rig r) async {
      final String row = 'C$players';
      final P7Client h = await r.open('human');
      h.send('play_computer', <String, Object?>{
        'name': 'Ann',
        'players': players,
        'install': r.install('human'),
      });
      final Frame sa = await h.untilType('seat_assigned');
      h.seat = fd(sa)['seat']! as int;
      h.token = fd(sa)['seat_token']! as String;
      final Frame room = await h.untilType('room');
      final Set<int> bots = <int>{
        for (final Object? s in fd(room)['seats']! as List<Object?>)
          if ((s! as Map<String, Object?>).containsKey('bot'))
            (s as Map<String, Object?>)['seat']! as int,
      };
      expect(bots.length, players - 1,
          reason: '$row: fixture: play_computer fills every other seat');
      final Table t = Table(r, fd(room)['code']! as String);
      t.bySeat[h.seat!] = h;
      t.live.add(h);
      t.observer = h;
      await h.untilType('turn');
      await t.settle();
      t.cur ??= h.all.lastWhere((Got g) => g.t == 'turn').f;
      final List<P7Client> used = <P7Client>[h];
      bool snapped = false;
      for (int i = 0; i < 200000 && !t.over; i++) {
        final Frame f = t.cur!;
        if (!snapped && isRollTurn(f) && bots.contains(fd(f)['seat'])) {
          snapped = true;
          final Frame s = await t.resume(h.seat!, 'human-snap');
          used.add(t.bySeat[h.seat!]!);
          expect(prePaths(s), isEmpty,
              reason: '$row: item 1: a computer seat gets no pre: the '
                  'human\'s snapshot while computer seat ${fd(f)['seat']} is '
                  'on turn in await_roll carries none; got turn '
                  '${canon(s['turn'])}');
          await t.settle();
        }
        await playStep(t, row);
      }
      expect(t.over, isTrue, reason: '$row: the game should reach game_over');
      expect(snapped, isTrue,
          reason: '$row: fixture: no computer await_roll turn was seen');
      final Analysis a = analyse(used, bots: bots);
      final List<String> botLeaks = <String>[
        for (final String v in a.copyViolations)
          if (v.contains('computer seat')) v,
      ];
      none(botLeaks, reason: '$row: item 1: ${_firstN(botLeaks)}');
      none(a.leaks, reason: '$row: item 4: ${_firstN(a.leaks)}');
      none(a.copyViolations,
          reason: '$row: control, the human\'s own await_roll turns carry '
              'pre (item 1): ${_firstN(a.copyViolations)}');
      none(a.preVsRolled, reason: '$row: item 2: ${_firstN(a.preVsRolled)}');
    }, timeout: const Timeout(Duration(minutes: 6)));
  }
}
