// X233: no roll leaves the server before its time, in any form.
//
// docs/PROTOCOL.md section 11.3: "Never send `reveal` for a roll before that
// roll's result." Section 17 item 6: the game log reveals nothing new.
// Section 35 item 4 (not on the base yet): the only unpublished face that may
// ever sit on a device is the roller's own `pre`, on its own socket, in its own
// `await_roll`; that one exception is [rollerOwnPreAllowed] below, off.
//
// One real WireServer on a loopback port, its dice chain rooted at a secret
// the test chose (test/support/scripted_bytes.dart), so every link s[0] ..
// s[4096] is known here before the room exists. Everything the server prints
// (print, stdout, stderr, the strike store's log) is captured in a zone. The
// verify store is a DirectoryVerifyStore in a temp dir. Two real WebSocket
// clients play a full two-seat game, each acting the moment it may with the
// first legal token. Mid-game the host asks for the game log and the guest
// resumes on a fresh socket (a takeover), so a mid-game snapshot and a
// mid-game log are both inspected.
//
// After every frame any socket receives, the test checks that no link s[j] of
// a roll j not yet published (and never the innermost secret s[4096]) shows,
// as hex in either case or as base64 / base64url, in: every frame received so
// far, every log line so far, every file under the verify dir, the body of
// /health, and the bodies of /v/<game_id> and /v/<game_id>.json. A link seen
// in a log line or a frame is judged against what had been published when the
// next frame arrived, so a log line written in the same server step as the
// rolled frame that publishes its link is not counted early; one written a
// step before is. Before every client action the driver waits until every
// live socket has caught up to the highest seq seen, so "published" means the
// same thing for both sockets.
//
// The structural face check: no frame other than `rolled` carries a `k` above
// the last published roll; `value`, `legal`, `queue`, `legal_by_face` and
// `face` appear only where the protocol says they restate a published roll
// (`rolled`, `turn`, the snapshot's `turn`, `moved.face`); every face in a
// queue is one of the faces the seat on turn has already been shown rolling
// in its current turn, or a granted six; an `await_roll` turn carries no
// `value`, `legal` or `legal_by_face`; every game_log entry is a broadcast a
// socket already received.
//
// Rerun: dart test test/c703_no_early_secret_test.dart
// (in packages/ludo_server, under flock /tmp/ludo-suite.lock).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fair_dice/fair_dice.dart' show drawDie, hexDecode, hexEncode;
import 'package:ludo_server/ludo_server.dart';
import 'package:test/test.dart';

import 'support/dice_oracle.dart' show revealsFor;
import 'support/scripted_bytes.dart';

const String _rerun = 'cd packages/ludo_server && flock /tmp/ludo-suite.lock '
    'dart test test/c703_no_early_secret_test.dart';

/// docs/PROTOCOL.md section 35 item 1: once `pre` ships, the copy of an
/// `await_roll` `turn` frame (or of the snapshot's `turn` object) that goes
/// to the socket of the seat on turn may carry `pre`. Off on the base: any
/// `pre` anywhere is a leak. Turning this on is the one change section 35
/// makes to this file.
const bool rollerOwnPreAllowed = false;

/// Whether [socketSeat]'s copy of a frame may carry a `pre` object, given the
/// turn object it sits in. Section 35 item 1 and item 4.
bool rollerOwnPreIsAllowed({
  required int? socketSeat,
  required Map<String, Object?> turnObject,
}) {
  if (!rollerOwnPreAllowed) {
    return false;
  }
  return socketSeat != null &&
      turnObject['seat'] == socketSeat &&
      turnObject['phase'] == 'await_roll';
}

const int _chainLength = 4096;

/// The secret the room's chain is rooted at: s[4096].
final List<int> _secret =
    sha256.convert(utf8.encode('c703-no-early-secret')).bytes;

/// s[0] .. s[4096], lowercase hex, computed here with SHA-256 alone.
final List<String> _links = () {
  final List<String> upper =
      revealsFor(_secret, count: _chainLength, chainLength: _chainLength);
  final String s0 = hexEncode(sha256.convert(hexDecode(upper[0])).bytes);
  return <String>[s0, ...upper];
}();

/// Every encoding of every link s[1] .. s[4096] the scanner looks for, to
/// the link index. Hex is matched on a lowercased haystack, so upper and
/// mixed case are covered; base64 and base64url are matched on their first
/// 43 characters, which is the whole unpadded encoding of 32 bytes.
final Map<String, int> _linkIndex = () {
  final Map<String, int> index = <String, int>{};
  for (int j = 1; j <= _chainLength; j++) {
    final List<int> bytes = hexDecode(_links[j]);
    index[_links[j]] = j;
    index[base64.encode(bytes).substring(0, 43)] = j;
    index[base64Url.encode(bytes).substring(0, 43)] = j;
  }
  return index;
}();

final RegExp _hexRun = RegExp(r'[0-9a-f]{64,}');
final RegExp _b64Run = RegExp(r'[A-Za-z0-9+/_-]{43,}');

/// Link indices j (1..4096) whose encoding appears anywhere in [hay].
Set<int> scanForLinks(String hay) {
  final Set<int> found = <int>{};
  for (final RegExpMatch m in _hexRun.allMatches(hay.toLowerCase())) {
    final String run = m.group(0)!;
    for (int i = 0; i + 64 <= run.length; i++) {
      final int? j = _linkIndex[run.substring(i, i + 64)];
      if (j != null) {
        found.add(j);
      }
    }
  }
  for (final RegExpMatch m in _b64Run.allMatches(hay)) {
    final String run = m.group(0)!;
    for (int i = 0; i + 43 <= run.length; i++) {
      final int? j = _linkIndex[run.substring(i, i + 43)];
      if (j != null) {
        found.add(j);
      }
    }
  }
  return found;
}

typedef Frame = Map<String, Object?>;

Object? _canon(Object? value) {
  if (value is Map) {
    final List<String> keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{for (final String k in keys) k: _canon(value[k])};
  }
  if (value is List) {
    return <Object?>[for (final Object? v in value) _canon(v)];
  }
  return value;
}

String _canonJson(Object? value) => jsonEncode(_canon(value));

String _clip(String s, [int max = 400]) =>
    s.length <= max ? s : '${s.substring(0, max)}...(${s.length} chars)';

/// Captures every line the server writes to stdout or stderr. Only the
/// members the server calls are real; the rest fail loudly.
class _CapturedStream implements Stdout {
  _CapturedStream(this.label, this.sink);

  final String label;
  final void Function(String line) sink;

  @override
  void write(Object? object) => sink('$label: $object');

  @override
  void writeln([Object? object = '']) => sink('$label: $object');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      sink('$label: ${objects.join(separator)}');

  @override
  void writeCharCode(int charCode) =>
      sink('$label: ${String.fromCharCode(charCode)}');

  @override
  void add(List<int> data) => sink('$label: ${utf8.decode(data)}');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'the server called $label.${invocation.memberName}, which the capture '
      'in c703_no_early_secret_test.dart does not implement');
}

class _Socket {
  _Socket(this.label, this.seat, this.ws);

  final String label;
  int? seat;
  final WebSocket ws;
  bool live = true;
  int lastSeq = 0;
  int idCounter = 0;
}

class _Sighting {
  _Sighting(this.link, this.where);
  final int link;
  final String where;
}

/// One full game under [ruleset], watched frame by frame.
class _Watch {
  _Watch(this.ruleset);

  final String ruleset;

  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 24));
  final FakeClock limiterClock = FakeClock(DateTime.utc(2026, 11, 24));
  late final Directory verifyDir;
  late final RoomRegistry registry;
  late final WireServer server;
  final HttpClient http = HttpClient();

  final List<String> logs = <String>[];
  int _logsScanned = 0;

  final List<_Socket> sockets = <_Socket>[];
  final StreamController<(String, String)> _merged =
      StreamController<(String, String)>();
  late final StreamIterator<(String, String)> _in =
      StreamIterator<(String, String)>(_merged.stream);

  int frameCount = 0;
  final List<String> recent = <String>[];

  /// The highest k whose `rolled` frame any socket has received.
  int published = 0;
  final List<int> rollSeat = <int>[];
  final List<int> rollValue = <int>[];
  final Set<int> sightedInRolled = <int>{};

  final Set<int> seenSeq = <int>{};
  final Map<int, String> firstCopyBySeq = <int, String>{};
  final Set<String> broadcasts = <String>{};
  final Map<int, int> sixesGranted = <int, int>{};
  int? lastTurnSeat;
  int maxSeq = 0;

  final List<_Sighting> pending = <_Sighting>[];

  String? code;
  String? gameId;
  String? clientSeeds;
  int httpProbes = 0;
  String summary = '';
  int timerRolls = 0;
  final List<String> errors = <String>[];
  final Map<String, int> probeStatuses = <String, int>{};
  final Map<String, int> framesByType = <String, int>{};

  String get scenario => 'ruleset=$ruleset secret(s[4096])=${_links[4096]} '
      'frame #$frameCount published k=$published; rerun: $_rerun';

  Never fail(String what) {
    throw TestFailure('$what\n  scenario: $scenario\n  last frames:\n    '
        '${recent.join('\n    ')}');
  }

  Future<void> start() async {
    verifyDir = Directory.systemTemp.createTempSync('c703-verify-');
    registry = RoomRegistry(
      clock: clock,
      secure: ScriptedBytesRandom(buildScript(secret: _secret)),
      verifyStore: DirectoryVerifyStore(verifyDir.path),
      ruleset: ruleset,
    );
    server = WireServer(
      registry: registry,
      rateLimiter: RateLimiter(clock: limiterClock),
      clock: clock,
      automaticTurnExpiry: false,
    );
    await server.start(address: InternetAddress.loopbackIPv4, port: 0);
  }

  Future<void> stop() async {
    for (final _Socket s in sockets) {
      if (s.ws.readyState == WebSocket.open) {
        await s.ws.close();
      }
    }
    await server.close();
    http.close(force: true);
    await _in.cancel();
    if (verifyDir.existsSync()) {
      verifyDir.deleteSync(recursive: true);
    }
  }

  Future<_Socket> connect(String label, {int? seat}) async {
    final WebSocket ws =
        await WebSocket.connect('ws://127.0.0.1:${server.port}/');
    final _Socket s = _Socket(label, seat, ws);
    sockets.add(s);
    ws.listen(
      (Object? raw) => _merged.add((label, raw! as String)),
      onDone: () => s.live = false,
      onError: (Object _) => s.live = false,
    );
    return s;
  }

  void send(_Socket s, String type, Map<String, Object?> data) {
    // The one-second message ceiling (section 7) runs on its own clock,
    // moved on before every send so a fast scripted game never trips it.
    limiterClock.advance(const Duration(milliseconds: 1100));
    s.ws.add(jsonEncode(<String, Object?>{
      'v': 1,
      't': type,
      'id': '${s.label}-msg-${++s.idCounter}',
      'd': data,
    }));
  }

  /// Pulls the next frame from any socket and runs every check on it.
  Future<(String, Frame)> pump() async {
    final bool got = await _in.moveNext().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('no frame arrived on any socket within 10 s'),
        );
    if (!got) {
      fail('every socket closed before the game ended');
    }
    final (String label, String raw) = _in.current;
    frameCount++;
    final Frame frame = jsonDecode(raw) as Frame;
    final String t = frame['t']! as String;
    framesByType[t] = (framesByType[t] ?? 0) + 1;
    if (t == 'error') {
      errors.add('$label ${_clip(raw, 200)}');
    }
    recent.add('#$frameCount $label ${_clip(raw, 300)}');
    if (recent.length > 6) {
      recent.removeAt(0);
    }
    final _Socket socket = sockets.firstWhere((_Socket s) => s.label == label);
    await _check(socket, raw, frame);
    return (label, frame);
  }

  Future<void> _check(_Socket socket, String raw, Frame frame) async {
    final String t = frame['t']! as String;
    final Frame d = (frame['d'] as Frame?) ?? <String, Object?>{};
    final String where = 'frame #$frameCount to ${socket.label} ($t)';

    for (final int j in scanForLinks(raw)) {
      pending.add(_Sighting(j, where));
    }
    while (_logsScanned < logs.length) {
      final String line = logs[_logsScanned++];
      for (final int j in scanForLinks(line)) {
        pending.add(_Sighting(j, 'log line ${_clip(line, 200)}'));
      }
    }

    _structural(socket, t, d);

    if (t == 'rolled') {
      _onRolled(d, raw);
    }
    final Object? seq = d['seq'];
    if (seq is int) {
      socket.lastSeq = seq;
      if (seq > maxSeq) {
        maxSeq = seq;
      }
      final Map<String, Object?> copy = Map<String, Object?>.of(d);
      final String canon = _canonJson(<String, Object?>{'t': t, 'd': copy});
      broadcasts.add(canon);
      if (seenSeq.add(seq)) {
        firstCopyBySeq[seq] = canon;
        _updateState(t, d);
      }
    }
    if (t == 'game_started') {
      gameId = d['game_id'] as String?;
      clientSeeds = d['client_seeds'] as String?;
    }

    for (final _Sighting s in pending) {
      if (s.link > published) {
        fail(s.link == _chainLength
            ? 'the innermost secret s[4096] (the seed the chain was built '
                'from) appeared in ${s.where}'
            : 'chain link s[${s.link}] appeared in ${s.where} while the last '
                'published roll was k=$published (expected no link above '
                's[$published] anywhere before its rolled frame)');
      }
    }
    pending.clear();

    await _probe();
  }

  void _onRolled(Frame d, String raw) {
    final int k = d['k']! as int;
    if (k > published + 1) {
      fail('rolled k=$k arrived while the last published roll was '
          'k=$published (expected k <= ${published + 1})');
    }
    if (k == published + 1) {
      final String expectedReveal = _links[k];
      if (d['reveal'] != expectedReveal) {
        fail('rolled k=$k reveal=${d['reveal']} is not the s[$k] of the '
            'chain the test rooted at its secret ($expectedReveal): the '
            'chain this test knows is not the server\'s');
      }
      final int face = drawDie(expectedReveal, gameId!, clientSeeds!, k, 0);
      if (d['value'] != face) {
        fail('rolled k=$k value=${d['value']}, expected $face from s[$k]');
      }
      if (!scanForLinks(raw).contains(k)) {
        fail('the scanner did not find s[$k] in the rolled frame that '
            'carries it; the leak scan is blind');
      }
      sightedInRolled.add(k);
      if (d['by'] == 'timer') {
        timerRolls++;
      }
      published = k;
      rollSeat.add(d['seat']! as int);
      rollValue.add(face);
    }
  }

  void _updateState(String t, Frame d) {
    if (t == 'sixes_granted') {
      for (final Object? s in (d['seats'] as List<Object?>? ?? <Object?>[])) {
        final int seat = s! as int;
        sixesGranted[seat] = (sixesGranted[seat] ?? 0) + 1;
      }
    }
    if (t == 'turn') {
      final int seat = d['seat']! as int;
      if (lastTurnSeat != null && lastTurnSeat != seat) {
        sixesGranted[lastTurnSeat!] = 0;
      }
      lastTurnSeat = seat;
    }
  }

  /// The faces seat [seat] has been shown rolling in its current turn: the
  /// trailing run of published rolls by that seat, up to roll [upTo].
  List<int> _currentTurnFaces(int seat, int upTo) {
    final List<int> faces = <int>[];
    for (int i = upTo - 1; i >= 0; i--) {
      if (rollSeat[i] != seat) {
        break;
      }
      faces.add(rollValue[i]);
    }
    return faces;
  }

  static const Set<String> _faceKeys = <String>{
    'value',
    'legal',
    'queue',
    'legal_by_face',
    'face',
  };

  void _structural(_Socket socket, String t, Frame d) {
    if (t == 'game_log') {
      final List<Object?> entries =
          d['frames'] as List<Object?>? ?? <Object?>[];
      for (final Object? e in entries) {
        final Frame entry = e! as Frame;
        final String canon = _canonJson(entry);
        if (!broadcasts.contains(canon)) {
          fail('game_log entry ${_clip(canon)} to ${socket.label} is not a '
              'broadcast any socket received (section 17 item 6: the log '
              'adds nothing a seat has not already been sent)');
        }
        _walk(socket, entry['t']! as String, entry['d']! as Frame, <String>[],
            historical: true);
      }
      return;
    }
    _walk(socket, t, d, <String>[], historical: false);
    if (t == 'turn') {
      _checkTurnObject(socket, 'turn frame', d, pushed: true);
    }
    if (t == 'room' && d['turn'] is Frame) {
      _checkTurnObject(socket, 'room snapshot turn', d['turn']! as Frame,
          pushed: false);
    }
    if (t == 'rolled') {
      final int k = d['k']! as int;
      final int seat = d['seat']! as int;
      final List<int> shown = <int>[
        ..._currentTurnFaces(seat, k - 1 <= published ? k - 1 : published),
        d['value']! as int,
      ];
      _checkQueueWithin(
          socket, 'rolled k=$k', d['queue'], shown, sixesGranted[seat] ?? 0);
    }
  }

  void _walk(_Socket socket, String t, Object? node, List<String> path,
      {required bool historical}) {
    if (node is List) {
      for (int i = 0; i < node.length; i++) {
        _walk(socket, t, node[i], <String>[...path, '$i'],
            historical: historical);
      }
      return;
    }
    if (node is! Map) {
      return;
    }
    final Frame map = node.cast<String, Object?>();
    if (map.containsKey('pre')) {
      if (historical ||
          !rollerOwnPreIsAllowed(socketSeat: socket.seat, turnObject: map)) {
        fail('${historical ? 'game_log entry' : 'frame'} "$t" to '
            '${socket.label} (seat ${socket.seat}) carries "pre" at '
            '${[...path, 'pre'].join('.')}: ${_clip(jsonEncode(map['pre']))}'
            ' (section 35 is off on the base; no socket may hold a face '
            'before its rolled)');
      }
    }
    for (final MapEntry<String, Object?> e in map.entries) {
      if (e.key == 'pre') {
        continue;
      }
      final List<String> here = <String>[...path, e.key];
      final bool top = path.isEmpty;
      if (e.key == 'k' && e.value is int) {
        final int k = e.value! as int;
        final bool liveRolled = t == 'rolled' && top && !historical;
        final int bound = liveRolled ? published + 1 : published;
        if (k > bound) {
          fail('"$t" to ${socket.label} carries k=$k at ${here.join('.')} '
              'while the last published roll was k=$published (expected '
              'k <= $bound)');
        }
      }
      if (_faceKeys.contains(e.key)) {
        final bool allowed = ((t == 'rolled' || t == 'turn') && top) ||
            (t == 'moved' && top && e.key == 'face') ||
            (t == 'room' && path.length == 1 && path[0] == 'turn') ||
            (t == 'room' &&
                path.length == 3 &&
                path[0] == 'turn' &&
                path[1] == 'legal_by_face') ||
            ((t == 'rolled' || t == 'turn') &&
                path.length == 2 &&
                path[0] == 'legal_by_face');
        if (!allowed) {
          fail('"$t" to ${socket.label} carries "${e.key}" at '
              '${here.join('.')} = ${_clip(jsonEncode(e.value))}; only '
              'rolled, turn, the snapshot turn and moved.face may restate a '
              'roll');
        }
      }
      _walk(socket, t, e.value, here, historical: historical);
    }
  }

  void _checkTurnObject(_Socket socket, String what, Frame turn,
      {required bool pushed}) {
    final Object? seatRaw = turn['seat'];
    if (seatRaw is! int) {
      return;
    }
    final String? phase = turn['phase'] as String?;
    final int banked = turn['banked'] is int ? turn['banked']! as int : 0;
    final int granted = sixesGranted[seatRaw] ?? 0;
    final int sixes = banked > granted ? banked : granted;
    final List<int> shown = _currentTurnFaces(seatRaw, published);
    final Object? queue = turn['queue'];
    if (phase == 'await_roll') {
      for (final String key in <String>['value', 'legal', 'legal_by_face']) {
        if (turn.containsKey(key) && turn[key] != null) {
          fail('$what to ${socket.label} in await_roll for seat $seatRaw '
              'carries "$key"=${jsonEncode(turn[key])}: a face before the '
              'roll');
        }
      }
    }
    _checkQueueWithin(socket, '$what seat $seatRaw', queue, shown, sixes);
    if (phase == 'await_move' && queue is List) {
      final List<int> q = queue.cast<int>();
      final Object? value = turn['value'];
      if (value is int && !q.contains(value)) {
        fail('$what to ${socket.label}: value=$value is not in its queue $q');
      }
      for (final Object? e
          in (turn['legal_by_face'] as List<Object?>? ?? <Object?>[])) {
        final int face = (e! as Frame)['face']! as int;
        if (!q.contains(face)) {
          fail('$what to ${socket.label}: legal_by_face face $face is not '
              'in its queue $q');
        }
      }
    }
  }

  void _checkQueueWithin(_Socket socket, String what, Object? queue,
      List<int> shown, int grantedSixes) {
    if (queue is! List) {
      return;
    }
    final List<int> pool = <int>[
      ...shown,
      for (int i = 0; i < grantedSixes; i++) 6,
    ];
    for (final Object? f in queue) {
      if (!pool.remove(f)) {
        fail('$what to ${socket.label}: queue ${jsonEncode(queue)} holds '
            'face $f, which is not among the faces this seat has been shown '
            'rolling this turn ($shown) nor a granted six ($grantedSixes)');
      }
    }
  }

  Future<(int, String)> _get(String path) async {
    final HttpClientRequest req =
        await http.get('127.0.0.1', server.port, path);
    final HttpClientResponse res = await req.close();
    final String body = await res.transform(utf8.decoder).join();
    httpProbes++;
    return (res.statusCode, body);
  }

  Future<void> _probe() async {
    void judge(String where, String body) {
      for (final int j in scanForLinks(body)) {
        if (j > published) {
          fail(j == _chainLength
              ? 'the innermost secret s[4096] appeared in $where'
              : 'chain link s[$j] appeared in $where while the last '
                  'published roll was k=$published');
        }
      }
    }

    for (final FileSystemEntity e in verifyDir.listSync(recursive: true)) {
      judge('the verify dir file name ${e.path}', e.path);
      if (e is File) {
        judge('the verify dir file ${e.path}', e.readAsStringSync());
      }
    }
    final (int hs, String health) = await _get('/health');
    probeStatuses['/health $hs'] = (probeStatuses['/health $hs'] ?? 0) + 1;
    judge('the body of /health', health);
    if (gameId != null) {
      for (final String p in <String>['/v/$gameId', '/v/$gameId.json']) {
        final (int st, String body) = await _get(p);
        final String key = '${p.replaceAll(gameId!, '<game_id>')} $st';
        probeStatuses[key] = (probeStatuses[key] ?? 0) + 1;
        judge('the body of $p (status $st)', body);
      }
    }
  }

  /// Pumps until [want] holds for a frame, checking every frame on the way.
  Future<(String, Frame)> pumpUntil(
      bool Function(String label, Frame f) want) async {
    for (int i = 0; i < 50; i++) {
      final (String label, Frame f) = await pump();
      if (want(label, f)) {
        return (label, f);
      }
    }
    fail('the awaited frame did not arrive within 50 frames');
  }

  /// Pumps until every live socket has received the highest seq seen.
  Future<void> settle() async {
    for (int i = 0; i < 50; i++) {
      final bool behind = sockets
          .where((_Socket s) => s.live && s.seat != null)
          .any((_Socket s) => s.lastSeq < maxSeq);
      if (!behind) {
        return;
      }
      await pump();
    }
    fail('a socket did not catch up to seq $maxSeq within 50 frames');
  }
}

Map<String, Object?>? _moveFor(Frame d) {
  final List<Object?> legal = d['legal'] as List<Object?>? ?? <Object?>[];
  if (legal.isNotEmpty) {
    return <String, Object?>{'token': legal.first};
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
  return null;
}

Future<void> _playAndWatch(String ruleset) async {
  final _Watch w = _Watch(ruleset);
  await IOOverrides.runZoned(
    () => runZoned(
      () async {
        await w.start();
        try {
          await _drive(w);
        } finally {
          await w.stop();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          w.logs.add('print: $line');
        },
      ),
    ),
    stdout: () => _CapturedStream('stdout', w.logs.add),
    stderr: () => _CapturedStream('stderr', w.logs.add),
  );
  // Outside the capture zone, so it reaches the test output.
  // ignore: avoid_print
  print(w.summary);
}

Future<void> _drive(_Watch w) async {
  final _Socket host = await w.connect('host');
  w.send(host, 'create_room', <String, Object?>{'name': 'Host', 'players': 2});
  final (_, Frame hostSeat) = await w.pumpUntil(
      (String l, Frame f) => l == 'host' && f['t'] == 'seat_assigned');
  host.seat = (hostSeat['d']! as Frame)['seat']! as int;
  final (_, Frame hostRoom) =
      await w.pumpUntil((String l, Frame f) => l == 'host' && f['t'] == 'room');
  final Frame room = hostRoom['d']! as Frame;
  w.code = room['code']! as String;
  if (room['chain_commit'] != _links[0]) {
    w.fail('room.chain_commit=${room['chain_commit']} is not s[0] of the '
        'chain rooted at the test secret (${_links[0]}); '
        'test/support/scripted_bytes.dart no longer matches the draw order '
        'of registry.dart, so this test does not know the chain');
  }

  final _Socket guest = await w.connect('guest');
  w.send(guest, 'join_room', <String, Object?>{
    'install': 'testinstall-00000001',
    'code': w.code,
    'name': 'Guest',
  });
  final (_, Frame guestSeat) = await w.pumpUntil(
      (String l, Frame f) => l == 'guest' && f['t'] == 'seat_assigned');
  guest.seat = (guestSeat['d']! as Frame)['seat']! as int;
  final String guestToken = (guestSeat['d']! as Frame)['seat_token']! as String;
  await w.pumpUntil((String l, Frame f) => l == 'guest' && f['t'] == 'room');
  await w.settle();

  w.send(host, 'set_seed', <String, Object?>{'client_seed': 'seed-s0'});
  await w
      .pumpUntil((String l, Frame f) => l == 'host' && f['t'] == 'seat_seed');
  w.send(guest, 'set_seed', <String, Object?>{'client_seed': 'seed-s2'});
  await w
      .pumpUntil((String l, Frame f) => l == 'guest' && f['t'] == 'seat_seed');
  await w.settle();

  w.send(host, 'start_game', <String, Object?>{});

  final Map<int, _Socket> bySeat = <int, _Socket>{
    host.seat!: host,
    guest.seat!: guest,
  };
  bool askedLog = false;
  bool resumed = false;
  bool timed = false;
  bool hostOver = false;

  for (int guard = 0; guard < 40000 && !hostOver; guard++) {
    final (String label, Frame f) = await w.pump();
    if (label != 'host') {
      continue;
    }
    final String t = f['t']! as String;
    final Frame d = (f['d'] as Frame?) ?? <String, Object?>{};
    if (t == 'game_over') {
      hostOver = true;
      break;
    }
    Map<String, Object?>? move;
    bool roll = false;
    int? actor;
    if (t == 'turn') {
      actor = d['seat']! as int;
      if (d['phase'] == 'await_roll') {
        roll = true;
      } else {
        move = _moveFor(d);
      }
    } else if (t == 'rolled') {
      actor = d['seat']! as int;
      move = _moveFor(d);
    }
    if (actor == null || (!roll && move == null)) {
      continue;
    }
    await w.settle();

    if (roll && actor == host.seat && !askedLog && w.published >= 20) {
      askedLog = true;
      w.send(host, 'game_log', <String, Object?>{});
      await w.pumpUntil((String l, Frame g) =>
          l == 'host' &&
          g['t'] == 'game_log' &&
          (g['d']! as Frame)['part'] == (g['d']! as Frame)['parts']);
    }
    if (roll && actor == host.seat && !resumed && w.published >= 40) {
      resumed = true;
      guest.live = false;
      final _Socket again = await w.connect('guest-resumed', seat: guest.seat);
      w.send(again, 'resume', <String, Object?>{
        'code': w.code,
        'seat_token': guestToken,
      });
      await w.pumpUntil(
          (String l, Frame g) => l == 'guest-resumed' && g['t'] == 'room');
      bySeat[guest.seat!] = again;
      await w.settle();
    }

    // Once, the guest leaves a roll to the turn timer, so the timer's own
    // roll path and its log line are watched too.
    if (roll && actor == guest.seat && !timed && w.published >= 60) {
      timed = true;
      final int wait =
          (d['deadline_ms']! as int) + ((d['grace_ms'] as int?) ?? 0) + 1;
      w.clock.advance(Duration(milliseconds: wait));
      w.server.runTurnExpiryOnce();
      continue;
    }

    final _Socket by = bySeat[actor]!;
    if (roll) {
      w.send(by, 'roll', <String, Object?>{});
    } else {
      w.send(by, 'move', move!);
    }
  }
  if (!hostOver) {
    w.fail('the game did not reach game_over within 40000 frames');
  }
  await w.settle();

  // At game_over the record exists and now holds every published link, and
  // still not one link past the last roll, nor the innermost secret.
  final List<File> records = w.verifyDir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.json'))
      .toList();
  if (records.length != 1) {
    w.fail('expected exactly one record file under ${w.verifyDir.path} at '
        'game_over, found ${records.map((File f) => f.path).toList()}');
  }
  final String record = records.single.readAsStringSync();
  final Set<int> inRecord = scanForLinks(record);
  final Set<int> want = <int>{for (int k = 1; k <= w.published; k++) k};
  if (!inRecord.containsAll(want)) {
    w.fail('the record at game_over lacks links '
        '${want.difference(inRecord).take(10).toList()} of s[1..'
        '${w.published}]');
  }
  final Set<int> beyond = inRecord.where((int j) => j > w.published).toSet();
  if (beyond.isNotEmpty) {
    w.fail('the record at game_over holds links past the last roll '
        '${w.published}: ${beyond.take(10).toList()}');
  }
  final (int status, String served) = await w._get('/v/${w.gameId}.json');
  if (status != 200 || !scanForLinks(served).containsAll(want)) {
    w.fail('GET /v/${w.gameId}.json after game_over answered $status and '
        'did not carry every link s[1..${w.published}]');
  }
  if (w.sightedInRolled.length != w.published) {
    w.fail('the scanner saw ${w.sightedInRolled.length} reveals in '
        '${w.published} rolled frames');
  }
  // Section 8 rule 6: the displaced socket of the takeover is closed with
  // BAD_SEAT_TOKEN. Any other error means the driver sent something the
  // server refused, and the game it watched is not the game it meant to play.
  final List<String> unexpected = w.errors
      .where((String e) =>
          !(e.startsWith('guest {') && e.contains('"code":"BAD_SEAT_TOKEN"')))
      .toList();
  if (unexpected.isNotEmpty || w.errors.length != 1) {
    w.fail('expected exactly one error frame, BAD_SEAT_TOKEN to the socket '
        'displaced by the resume (section 8 rule 6), got ${w.errors}');
  }
  if (!askedLog || !resumed || !timed || w.timerRolls == 0) {
    w.fail('the game ended before the mid-game game_log ($askedLog), '
        'resume ($resumed) and timer roll ($timed, ${w.timerRolls} rolled '
        'by the timer) were all exercised; lower the trigger or pick another '
        'secret');
  }
  w.summary = 'c703 ruleset=${w.ruleset}: ${w.published} rolls, '
      '${w.frameCount} frames checked, ${w.logs.length} log lines, '
      '${w.httpProbes} HTTP probes ${w.probeStatuses}, frames by type '
      '${w.framesByType}, ${w.timerRolls} timer rolls, errors ${w.errors}';
}

void main() {
  test('the leak scanner finds a link in each encoding it claims to cover', () {
    final int j = 7;
    final List<int> bytes = hexDecode(_links[j]);
    final Map<String, String> forms = <String, String>{
      'lower hex': 'x=${_links[j]};',
      'upper hex': 'x=${_links[j].toUpperCase()};',
      'base64': 'x="${base64.encode(bytes)}"',
      'base64url': 'x="${base64Url.encode(bytes)}"',
      'base64url unpadded':
          'x="${base64Url.encode(bytes).replaceAll('=', '')}"',
      'inside a longer hex run': 'ab${_links[j]}cd',
    };
    forms.forEach((String name, String hay) {
      expect(scanForLinks(hay), contains(j),
          reason: 'scanner missed s[$j] written as $name: $hay');
    });
    expect(scanForLinks(_links[4096]), contains(4096),
        reason: 'scanner missed the innermost secret in hex');
    expect(scanForLinks('no secrets here ${'0' * 64}'), isEmpty,
        reason: 'scanner reported a link in a string holding none');
  });

  for (final String ruleset in <String>['2026-10', '2026-11', '2026-12']) {
    test(
      'ruleset $ruleset: no chain link, no face and not the seed reaches a '
      'frame, a log line, the verify dir, /health or /v/<game> before its roll',
      () => _playAndWatch(ruleset),
      timeout: const Timeout(Duration(minutes: 6)),
    );
  }
}
