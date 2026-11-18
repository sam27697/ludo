// Shared harness of the c672 suites (docs/PROTOCOL.md section 30, the shared
// release): one real WireServer on a loopback port, one fake clock, real
// WebSocket clients, steered dice. Every failure names its scenario, the
// steering and the command that reruns it.
//
// The ruleset is injected as a named `ruleset` argument holding the
// environment string, on RoomRegistry first and on WireServer second (the
// seam c652_ruleset_2026_11_test.dart documents). No test sleeps.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'dice_oracle.dart';
import 'scripted_bytes.dart';
import 'wire_harness.dart';

typedef Frame = Map<String, Object?>;

const String v12 = '2026-12';
const String v11 = '2026-11';
const String v10 = '2026-10';

Map<String, Object?> dataOf(Frame frame) => frame['d']! as Map<String, Object?>;

List<Object?> typesOf(List<Frame> frames) =>
    <Object?>[for (final Frame f in frames) f['t']];

List<Frame> ofType(List<Frame> frames, String type) => <Frame>[
      for (final Frame f in frames)
        if (f['t'] == type) f
    ];

Object? canon(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final String k in keys) k: canon(value[k])};
  }
  if (value is List) {
    return <Object?>[for (final Object? v in value) canon(v)];
  }
  return value;
}

/// Key-order independent JSON, so two maps compare by content.
String jsonOf(Object? value) => jsonEncode(canon(value));

// ---------------------------------------------------------------------------
// The fixture: one server, one fake clock, every failure with its scenario.
// ---------------------------------------------------------------------------

class Steer {
  Steer._(this.description, this.secret, this.gameId, this.clientSeeds,
      this.players);

  final String description;
  final List<int> secret;
  final String gameId;
  final String clientSeeds;
  final int players;

  Random random() => ScriptedBytesRandom(
        players == 2
            ? buildScript(secret: secret)
            : buildThreeSeatScript(secret: secret),
      );

  static final Map<String, Steer> _cache = <String, Steer>{};

  static String seedsFor(int players) =>
      players == 2 ? '0:seed-s0|2:seed-s2' : '0:seed-s0|1:seed-s1|2:seed-s2';

  /// A secret whose first faces are exactly [wanted].
  static Steer faces(List<int> wanted, {int players = 2}) {
    return _cache.putIfAbsent('faces:$players:${jsonOf(wanted)}', () {
      final String gameId = predictedGameId(players);
      final SteeredSecret s = findSecretForFaces(
        wanted: wanted,
        gameId: gameId,
        clientSeeds: seedsFor(players),
      );
      return Steer._(
        'steered so that rolls 1..${wanted.length} are $wanted '
        '($players seats)',
        s.secret,
        gameId,
        seedsFor(players),
        players,
      );
    });
  }

  /// A secret whose first [count] faces are all different from 6.
  static Steer noSix(int count, {int players = 2}) {
    return _cache.putIfAbsent('nosix:$players:$count', () {
      final String gameId = predictedGameId(players);
      for (int i = 0; i < 20000; i++) {
        final List<int> secret = candidateSecretAt(i);
        final List<int> faces = facesFor(
          secret,
          gameId: gameId,
          clientSeeds: seedsFor(players),
          count: count,
        );
        if (faces.every((int f) => f != 6)) {
          return Steer._(
            'steered so that rolls 1..$count are never 6 '
            '(candidate $i, faces $faces, $players seats)',
            secret,
            gameId,
            seedsFor(players),
            players,
          );
        }
      }
      throw StateError('no candidate gave $count rolls without a 6');
    });
  }
}

String predictedGameId([int players = 2]) {
  final List<int> zero = List<int>.filled(serverSecretDraws, 0);
  final List<int> probe = players == 2
      ? buildScript(secret: zero)
      : buildThreeSeatScript(secret: zero);
  final int offset = players == 2 ? gameIdOffset : threeSeatGameIdOffset;
  return hexEncode(probe.sublist(offset, offset + gameIdDraws));
}

class Fixture {
  Fixture._(this.scenario, this.ruleset, this.steer);

  final String scenario;
  final String? ruleset;
  final Steer? steer;

  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 19));

  /// The rate limiter has its own clock so that the one-second message
  /// ceiling never depends on the game clock a scenario is driving.
  final FakeClock limiterClock = FakeClock(DateTime.utc(2026, 11, 19));

  late final RoomRegistry registry;
  late final WireServer server;
  final List<WireTestClient> clients = <WireTestClient>[];
  String injection = 'none (ruleset absent)';

  static Future<Fixture> start(
    String scenario, {
    String? ruleset,
    Steer? steer,
  }) async {
    final Fixture fx = Fixture._(scenario, ruleset, steer);
    final Random rnd = steer?.random() ?? Random.secure();
    final List<String> notes = <String>[];
    RoomRegistry? registry;
    WireServer? server;
    if (ruleset == null) {
      registry = RoomRegistry(clock: fx.clock, secure: rnd);
    } else {
      try {
        registry =
            Function.apply(RoomRegistry.new, <Object?>[], <Symbol, Object?>{
          #clock: fx.clock,
          #secure: rnd,
          #ruleset: ruleset,
        }) as RoomRegistry;
        fx.injection = 'RoomRegistry(ruleset: "$ruleset")';
      } on Object catch (error) {
        notes.add('RoomRegistry(ruleset:) refused: ${error.runtimeType}');
      }
    }
    registry ??= RoomRegistry(clock: fx.clock, secure: rnd);
    final RateLimiter limiter = RateLimiter(clock: fx.limiterClock);
    if (ruleset != null && fx.injection == 'none (ruleset absent)') {
      try {
        server = Function.apply(WireServer.new, <Object?>[], <Symbol, Object?>{
          #registry: registry,
          #rateLimiter: limiter,
          #clock: fx.clock,
          #automaticTurnExpiry: false,
          #ruleset: ruleset,
        }) as WireServer;
        fx.injection = 'WireServer(ruleset: "$ruleset")';
      } on Object catch (error) {
        notes.add('WireServer(ruleset:) refused: ${error.runtimeType}');
      }
      if (server == null) {
        throw TestFailure(
          'scenario=$scenario: cannot inject RULESET="$ruleset" in process. '
          'Neither RoomRegistry nor WireServer takes a named argument '
          '`ruleset` (a String holding the environment value). Tried: '
          '${notes.join('; ')}. Section 28 rule 1 puts the switch in the '
          'server environment, read once at start; the in-process seam is '
          'the missing production piece.',
        );
      }
    }
    server ??= WireServer(
      registry: registry,
      rateLimiter: limiter,
      clock: fx.clock,
      automaticTurnExpiry: false,
    );
    fx.registry = registry;
    fx.server = server;
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
    return fx;
  }

  Uri get wsUri =>
      Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/');

  Future<WireTestClient> connect() async {
    final WireTestClient c = await WireTestClient.connect(wsUri);
    clients.add(c);
    return c;
  }

  /// Sends one message after moving the limiter's own clock a little, so the
  /// per-second ceiling never trips in a long scenario.
  String send(WireTestClient c, String type, Map<String, Object?> data) {
    limiterClock.advance(const Duration(milliseconds: 1100));
    return c.send(type, data);
  }

  /// Sends without moving the limiter clock (the rate-limit case only).
  String sendBurst(WireTestClient c, String type, Map<String, Object?> data) {
    return c.send(type, data);
  }

  Future<void> close() async {
    for (final WireTestClient c in clients) {
      try {
        await c.close();
      } on Object {
        // already closed by the server
      }
    }
    await server.close();
  }

  String get reproduce => 'scenario="$scenario" '
      '(${steer?.description ?? 'dice not steered'}; injection: $injection; '
      'rerun: dart test test/<c672 file> '
      '--plain-name "$scenario")';

  Never fail(String what, {Object? expected, Object? actual}) {
    throw TestFailure(
      '$what | expected: ${expected is String ? expected : jsonOf(expected)} | '
      'actual: ${actual is String ? actual : jsonOf(actual)} | $reproduce',
    );
  }

  void eq(Object? actual, Object? expected, String what) {
    if (jsonOf(actual) != jsonOf(expected)) {
      fail(what, expected: expected, actual: actual);
    }
  }

  void ok(bool condition, String what, [Object? actual]) {
    if (!condition) {
      fail(what, expected: 'true', actual: actual ?? 'false');
    }
  }

  void absent(Map<String, Object?> d, String key, String what) {
    if (d.containsKey(key)) {
      fail('$what: key "$key" must be absent',
          expected: 'no "$key"', actual: d);
    }
  }
}

Future<void> withFixture(
  String scenario,
  Future<void> Function(Fixture fx) body, {
  String? ruleset = v11,
  Steer? steer,
}) async {
  final Fixture fx = await Fixture.start(
    scenario,
    ruleset: ruleset,
    steer: steer,
  );
  try {
    await body(fx);
  } finally {
    await fx.close();
  }
}

/// Reads off [c] until its ping is answered: every frame the server wrote to
/// this socket before it handled the ping, in order, the pong left out.
Future<List<Frame>> flush(Fixture fx, WireTestClient c) async {
  final String id = fx.send(c, 'ping', <String, Object?>{});
  final List<Frame> out = <Frame>[];
  while (true) {
    final Frame f = await c.next(timeout: const Duration(seconds: 5));
    if (f['t'] == 'pong' && f['re'] == id) {
      return out;
    }
    out.add(f);
  }
}

class HSeat {
  HSeat(this.seat, this.token, this.client);

  final int seat;
  final String token;
  WireTestClient client;
  bool up = true;
}

class Table {
  Table(this.fx, this.code, this.seats, this.createFrame);

  final Fixture fx;
  final String code;
  final Map<int, HSeat> seats;
  final Frame createFrame;
  String? gameId;

  WireTestClient c(int seat) => seats[seat]!.client;
  String token(int seat) => seats[seat]!.token;
  Room get room => fx.registry.lookup(code)!;
  List<int> get numbers => (seats.keys.toList()..sort());

  /// Flushes every connected seat, the [first] one first (the sender, whose
  /// pong proves its message was handled before anyone else is asked).
  Future<Map<int, List<Frame>>> syncAll({int? first}) async {
    final Map<int, List<Frame>> out = <int, List<Frame>>{};
    final List<int> order = <int>[
      if (first != null && seats[first]!.up) first,
      for (final int s in numbers)
        if (s != first && seats[s]!.up) s,
    ];
    for (final int s in order) {
      out[s] = await flush(fx, c(s));
    }
    return out;
  }

  /// One client message from [seat], then every frame the room produced.
  Future<Map<int, List<Frame>>> step(
    int seat,
    String type,
    Map<String, Object?> data,
  ) async {
    fx.send(c(seat), type, data);
    return syncAll(first: seat);
  }
}

Future<Table> openTable(
  Fixture fx, {
  int players = 2,
  bool seeds = false,
  Map<String, Object?>? rules,
}) async {
  final Map<int, HSeat> seats = <int, HSeat>{};
  final WireTestClient host = await fx.connect();
  fx.send(host, 'create_room', <String, Object?>{
    'name': 'Host',
    'players': players,
    if (rules != null) 'rules': rules,
  });
  final Frame sa = await host.next();
  final Frame room = await host.next();
  if (sa['t'] != 'seat_assigned' || room['t'] != 'room') {
    fx.fail(
      'create_room is answered by seat_assigned then room',
      expected: <String>['seat_assigned', 'room'],
      actual: <Object?>[sa['t'], room['t'], dataOf(sa), dataOf(room)],
    );
  }
  seats[dataOf(sa)['seat']! as int] = HSeat(
      dataOf(sa)['seat']! as int, dataOf(sa)['seat_token']! as String, host);
  final String code = dataOf(room)['code']! as String;
  for (int i = 1; i < players; i++) {
    final WireTestClient g = await fx.connect();
    fx.send(g, 'join_room', <String, Object?>{'code': code, 'name': 'Guest$i'});
    final Frame gsa = await g.next();
    final Frame groom = await g.next();
    if (gsa['t'] != 'seat_assigned' || groom['t'] != 'room') {
      fx.fail(
        'join_room is answered by seat_assigned then room',
        expected: <String>['seat_assigned', 'room'],
        actual: <Object?>[gsa['t'], groom['t'], dataOf(gsa)],
      );
    }
    final int seat = dataOf(gsa)['seat']! as int;
    for (final HSeat other in seats.values) {
      await receiveType(other.client, 'player_joined');
    }
    seats[seat] = HSeat(seat, dataOf(gsa)['seat_token']! as String, g);
  }
  final Table t = Table(fx, code, seats, room);
  if (seeds) {
    for (final int s in t.numbers) {
      fx.send(t.c(s), 'set_seed', <String, Object?>{'client_seed': 'seed-s$s'});
      for (final int o in t.numbers) {
        await receiveType(t.c(o), 'seat_seed');
      }
    }
  }
  return t;
}

/// start_game from the host; reads every seat up to its opening turn.
Future<Map<int, List<Frame>>> startGame(Table t) async {
  final int host = t.numbers.first;
  t.fx.send(t.c(host), 'start_game', <String, Object?>{});
  final Map<int, List<Frame>> out = <int, List<Frame>>{};
  for (final int s in t.numbers) {
    out[s] = await drainUntil(
      t.c(s),
      'turn',
      maxFrames: 12,
      perFrame: const Duration(seconds: 3),
    );
  }
  final Frame gs = ofType(out[host]!, 'game_started').single;
  t.gameId = dataOf(gs)['game_id']! as String;
  final Steer? steer = t.fx.steer;
  if (steer != null) {
    t.fx.eq(
      t.gameId,
      steer.gameId,
      'the steering search predicted game_id from the registry draw order; '
      'a different game_id means the draws before start_game changed and '
      'the steered faces no longer apply',
    );
  }
  return out;
}

void force(
  Table t, {
  int? currentSeat,
  String? phase,
  List<int>? queue,
  Map<int, List<int>>? tokens,
  List<int>? drought,
  bool? releaseOwed,
  bool? releaseOffered,
  List<int>? banked,
  bool? blocks,
  int? sixes,
}) {
  final Room room = t.room;
  final Map<String, Object?> json = room.game!.toJson();
  if (currentSeat != null) {
    json['currentSeat'] = currentSeat;
  }
  if (phase != null) {
    json['phase'] = phase;
  }
  if (queue != null) {
    json['queue'] = queue;
  }
  if (tokens != null) {
    final List<Object?> rows = json['tokens']! as List<Object?>;
    tokens.forEach((int seat, List<int> row) => rows[seat] = row);
  }
  if (drought != null) {
    json['drought'] = drought;
  }
  if (releaseOwed != null) {
    json['releaseOwed'] = releaseOwed;
  }
  if (releaseOffered != null) {
    json['releaseOffered'] = releaseOffered;
  }
  if (banked != null) {
    json['banked'] = banked;
  }
  if (blocks != null) {
    final Map<String, Object?> config = json['config']! as Map<String, Object?>;
    (config['rules']! as Map<String, Object?>)['blocks'] = blocks;
  }
  if (sixes != null) {
    json['sixes'] = sixes;
  }
  room.game = engine.GameState.fromJson(json);
  room.turnSegmentStartedAt = t.fx.clock.now;
}

/// Restarts the running segment at the fake clock's present, so a sweep that
/// is about to prove something about absence never also expires a turn.
void freshSegment(Table t) {
  t.room.turnSegmentStartedAt = t.fx.clock.now;
}

Future<Map<String, Object?>> resume(Table t, int seat) async {
  final WireTestClient c = await t.fx.connect();
  t.fx.send(c, 'resume', <String, Object?>{
    'code': t.code,
    'seat_token': t.token(seat),
  });
  final Frame sa = await c.next();
  final Frame room = await c.next();
  t.fx.ok(
    sa['t'] == 'seat_assigned' && room['t'] == 'room',
    'resume is answered by seat_assigned then room',
    <Object?>[sa['t'], room['t'], dataOf(sa)],
  );
  t.seats[seat]!.client = c;
  t.seats[seat]!.up = true;
  return dataOf(room);
}

Future<Map<String, Object?>> httpGet(Fixture fx, String path) async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest req = await http.getUrl(Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: fx.server.port,
      path: path.split('?').first,
      query: path.contains('?') ? path.split('?').last : null,
    ));
    final HttpClientResponse res = await req.close();
    final String body = await utf8.decodeStream(res);
    return <String, Object?>{'status': res.statusCode, 'body': body};
  } finally {
    http.close(force: true);
  }
}

Future<Map<String, Object?>> recordOf(Table t) async {
  final Map<String, Object?> res = await httpGet(t.fx, '/v/${t.gameId}.json');
  t.fx.eq(
      res['status'], 200, 'the verify record of game ${t.gameId} is stored');
  return jsonDecode(res['body']! as String) as Map<String, Object?>;
}

/// The `error` code of [frame], failing with the scenario otherwise.
String codeOf(Fixture fx, Frame frame, String what) {
  fx.ok(frame['t'] == 'error', '$what must be answered by an error frame',
      <Object?>[frame['t'], frame['d']]);
  return dataOf(frame)['code']! as String;
}

void expectError(
  Fixture fx,
  List<Frame> frames,
  String code,
  String what,
) {
  fx.eq(typesOf(frames), <String>['error'], '$what: exactly one frame');
  fx.eq(codeOf(fx, frames.single, what), code, '$what: error code');
}

/// Closes the sockets of every seat in [seats] and waits, on the room's own
/// seat table, until the server has noticed each one. For the cases where
int openRowStart(String body, String reveal) {
  for (int from = 0;;) {
    final int hit = body.indexOf(reveal, from);
    if (hit < 0) {
      return -1;
    }
    if (body.lastIndexOf('<tr', hit) > body.lastIndexOf('</tr>', hit)) {
      return body.lastIndexOf('<tr', hit);
    }
    from = hit + 1;
  }
}

void expectReEchoed(
  Fixture fx,
  Map<int, List<Frame>> frames,
  int sender,
  String id,
  String type,
) {
  frames.forEach((int seat, List<Frame> list) {
    for (final Frame f in list) {
      if (f['t'] != type) {
        continue;
      }
      if (seat == sender) {
        fx.eq(f['re'], id, 'the sender\'s copy of "$type" carries re');
      } else {
        fx.ok(!f.containsKey('re'),
            'the copy of "$type" other seats get carries no re', f);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Positions and plays shared by the c672 files.
// ---------------------------------------------------------------------------

/// [seat] on turn awaiting a move on [face], one step short of home: moving
/// token 3 brings its fourth token home.
void forceFinishingMove(Table t, int seat, {int face = 3}) {
  force(
    t,
    currentSeat: seat,
    phase: 'awaitMove',
    queue: <int>[face],
    tokens: <int, List<int>>{
      seat: <int>[57, 57, 57, 57 - face],
    },
    releaseOwed: t.room.game!.config.rules.yardRelease ? false : null,
    releaseOffered: t.room.game!.config.rules.sharedRelease ? false : null,
    sixes: 0,
  );
}

/// A steered 2-seat game (Steer.noSix(19), seeds on) in which seat 0 rolls
/// the tenth non-6 with every token in the yard on roll 19. Plays rolls
/// 1..18 over the wire, checking each is an ordinary pass, and returns the
/// frames every seat saw for roll 19.
Future<Map<int, List<Frame>>> playToOffer(Table t) async {
  final Fixture fx = t.fx;
  for (int k = 1; k <= 18; k++) {
    final int actor = k.isOdd ? 0 : 2;
    final int other = k.isOdd ? 2 : 0;
    final Map<int, List<Frame>> frames =
        await t.step(actor, 'roll', <String, Object?>{});
    for (final int seat in <int>[0, 2]) {
      fx.eq(
          typesOf(frames[seat]!),
          <String>['rolled', 'turn_passed', 'turn'],
          'roll $k (non-6, every token in the yard) by seat $actor, seen by '
          'seat $seat');
    }
    final Map<String, Object?> rolled = dataOf(frames[actor]!.first);
    fx.eq(rolled['k'], k, 'roll $k: k');
    fx.absent(rolled, 'release', 'roll $k is not a release roll');
    fx.absent(rolled, 'offer', 'roll $k is not an offer');
    fx.eq(dataOf(frames[actor]!.last)['seat'], other, 'roll $k: next seat');
  }
  return t.step(0, 'roll', <String, Object?>{});
}

/// Closes the sockets of [seats] and waits, on the room's own seat table,
/// until the server has noticed each one.
Future<void> dropMany(Table t, List<int> seats) async {
  for (final int seat in seats) {
    t.seats[seat]!.up = false;
    await t.seats[seat]!.client.close();
  }
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final bool allDown = seats.every((int seat) =>
        !t.room.seats.singleWhere((Seat s) => s.seat == seat).connected);
    if (allDown) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      t.fx.fail('the server noticed the closed sockets of seats $seats',
          expected: 'connected=false for every one', actual: 'still up');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Every key at any depth of [value].
Set<String> allKeys(Object? value) {
  final Set<String> out = <String>{};
  void walk(Object? v) {
    if (v is Map) {
      for (final MapEntry<Object?, Object?> e in v.entries) {
        out.add(e.key! as String);
        walk(e.value);
      }
    } else if (v is List) {
      v.forEach(walk);
    }
  }

  walk(value);
  return out;
}
