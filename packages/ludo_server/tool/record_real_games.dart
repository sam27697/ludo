// Order 574: records complete two-player games played over a real WebSocket
// against a real, separately started server process, and writes them as the
// fixture `packages/ludo_client/integration_test/fixtures/real_games.json`.
//
//   dart run tool/record_real_games.dart --target ws://127.0.0.1:8096/ws
//       [--choice-seed N] [--max-games N] [--host-name NAME]
//       [--guest-name NAME] [--out PATH] [--timeout-seconds N]
//
// The dice are the server's. This tool never rolls, never picks a face and
// never searches for a good game: its only choice is which of the moves the
// server offered (`legal_by_face`, or `legal` on a server that sends no
// faces) it sends, drawn from a `Random(--choice-seed)`.
//
// Every game is played in a NEW room on a new socket pair: the host creates,
// the guest joins by code, the host sets a seed and starts the game, so each
// game's views begin at the socket's first frame, the way a fresh client
// enters a game. No rematch. `create_room` is limited to five per hour per
// address (docs/PROTOCOL.md section 7, measured: the sixth from one address
// answers RATE_LIMITED), so a run plays at most [_roomLimit] games and
// `--max-games` above that is refused. The limiter is not worked around: when
// five games do not cover everything the run exits 2 and the operator runs
// it again against a fresh server process. Playing stops as soon as the kept
// games cover everything in [_requirements]; at most [_maxKept] games are
// kept, chosen to cover the most, then to be the fewest, then to be the
// shortest. Both sockets of a room are closed once its `game_log` is fetched.
//
// Exit codes: 0 covered and written, 1 a protocol or cross-check failure
// (nothing is written), 2 `--max-games` reached without full coverage
// (nothing is written), 64 bad command line.
//
// docs/SIMULATOR.md says how to start the server and re-record.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sim/fairness.dart';
import 'sim/game.dart' show SeenRoll;
import 'sim/json.dart';
import 'sim/record_check.dart';
import 'sim/scenario.dart';
import 'sim/wire.dart';

const int _hostSeat = 0;
const int _guestSeat = 2;
const int _maxKept = 4;

/// `create_room` answers RATE_LIMITED from the sixth in an hour per address.
const int _roomLimit = 5;

/// Absolute squares that are entry squares (docs/RULES.md section 1.1).
const Set<int> _entrySquares = <int>{0, 13, 26, 39};

/// The frame types a room broadcasts as part of a game, the ones both seats
/// must see identically and the ones `game_log` serves (section 17).
const Set<String> _gamePushTypes = <String>{
  'game_started',
  'turn',
  'rolled',
  'moved',
  'turn_passed',
  'game_over',
};

const String _reqHostWin = 'host_win';
const String _reqGuestWin = 'guest_win';
const String _reqCaptureBySeat0 = 'capture_by_seat0';
const String _reqCaptureBySeat2 = 'capture_by_seat2';
const String _reqThreeSixes = 'three_sixes';
const String _reqNoLegalMove = 'no_legal_move';
const String _reqDeadFace = 'dead_face';

const List<String> _requirements = <String>[
  _reqHostWin,
  _reqGuestWin,
  _reqCaptureBySeat0,
  _reqCaptureBySeat2,
  _reqThreeSixes,
  _reqNoLegalMove,
  _reqDeadFace,
];

const String _usage = '''
usage: dart run tool/record_real_games.dart --target <ws-url> [options]

  --target <url>         ws:// or wss:// URL of a running server (required)
  --choice-seed <n>      seed of the move choices (default 1)
  --max-games <n>        give up, exit 2, after this many games, one new room
                         each (default 5, the most create_room allows an hour;
                         more is refused, exit 64)
  --host-name <name>     seat 0 display name (default Priya)
  --guest-name <name>    seat 2 display name (default Karim)
  --out <path>           output file (default: ludo_client's
                         integration_test/fixtures/real_games.json)
  --timeout-seconds <n>  bound on the whole run (default 3000)
''';

class _Args {
  _Args({
    required this.target,
    required this.choiceSeed,
    required this.maxGames,
    required this.hostName,
    required this.guestName,
    required this.out,
    required this.timeoutSeconds,
  });

  final Uri target;
  final int choiceSeed;
  final int maxGames;
  final String hostName;
  final String guestName;
  final String out;
  final int timeoutSeconds;
}

class _UsageError implements Exception {
  _UsageError(this.message);
  final String message;
  @override
  String toString() => message;
}

_Args _parseArgs(List<String> argv) {
  final Map<String, String> values = <String, String>{};
  const Set<String> known = <String>{
    '--target',
    '--choice-seed',
    '--max-games',
    '--host-name',
    '--guest-name',
    '--out',
    '--timeout-seconds',
  };
  for (int i = 0; i < argv.length; i++) {
    final String flag = argv[i];
    if (!known.contains(flag)) {
      throw _UsageError('unknown argument "$flag"');
    }
    if (i + 1 >= argv.length) {
      throw _UsageError('$flag needs a value');
    }
    values[flag] = argv[++i];
  }
  final String? rawTarget = values['--target'];
  if (rawTarget == null) {
    throw _UsageError('--target is required');
  }
  final Uri target = Uri.parse(rawTarget);
  if (target.scheme != 'ws' && target.scheme != 'wss') {
    throw _UsageError('--target must be a ws:// or wss:// URL, got $rawTarget');
  }
  int intFlag(String flag, int fallback, {int min = 0}) {
    final String? raw = values[flag];
    if (raw == null) {
      return fallback;
    }
    final int? parsed = int.tryParse(raw);
    if (parsed == null || parsed < min) {
      throw _UsageError('$flag needs an integer >= $min, got "$raw"');
    }
    return parsed;
  }

  final int maxGames = intFlag('--max-games', _roomLimit, min: 1);
  if (maxGames > _roomLimit) {
    throw _UsageError(
      '--max-games $maxGames is more than $_roomLimit: create_room is limited '
      'to $_roomLimit per hour per address and every game needs its own room. '
      'Run again against a fresh server process instead.',
    );
  }

  return _Args(
    target: target,
    choiceSeed: intFlag('--choice-seed', 1, min: -1 << 31),
    maxGames: maxGames,
    hostName: values['--host-name'] ?? 'Priya',
    guestName: values['--guest-name'] ?? 'Karim',
    out: values['--out'] ??
        Platform.script
            .resolve(
                '../../ludo_client/integration_test/fixtures/real_games.json')
            .toFilePath(),
    timeoutSeconds: intFlag('--timeout-seconds', 3000, min: 1),
  );
}

/// One finished game, everything the fixture needs for it.
class _Game {
  _Game({
    required this.order,
    required this.gameId,
    required this.rules,
    required this.winner,
    required this.finalTokens,
    required this.counts,
    required this.views,
    required this.events,
    required this.covers,
    required this.totalRolls,
  });

  /// Position in play order, 1-based.
  final int order;
  final String gameId;
  final Map<String, Object?> rules;
  final int winner;
  final Map<int, List<int>> finalTokens;
  final Map<int, Map<String, int>> counts;
  final Map<int, List<Frame>> views;
  final List<Map<String, Object?>> events;
  final Set<String> covers;
  final int totalRolls;

  /// The `game_log` parts seat 0 received, set only for kept games.
  List<Frame> gameLog = <Frame>[];
}

/// A failure that is a finding about the server or about this run, not a
/// usage error. The message says what was expected and what happened.
class _RunFailure implements Exception {
  _RunFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the turn loop learned about one game while playing it.
class _Played {
  _Played({
    required this.gameId,
    required this.clientSeeds,
    required this.chainCommit,
    required this.winner,
    required this.verifyUrl,
    required this.rolls,
  });

  final String gameId;
  final String clientSeeds;
  final String chainCommit;
  final int winner;
  final String verifyUrl;
  final List<SeenRoll> rolls;
}

/// Reads frames off [socket] until one of [type] arrives and returns it.
/// An `error` frame, or more than [maxFrames] frames without the one wanted,
/// is a failure naming [because].
Future<Frame> _awaitType(
  SimSocket socket,
  String type, {
  required String because,
  int maxFrames = 64,
}) async {
  for (int i = 0; i < maxFrames; i++) {
    final Frame frame = await socket.next();
    final String actual = frameType(frame);
    if (actual == type) {
      return frame;
    }
    if (actual == 'error') {
      final Map<String, Object?> d = frameData(frame);
      throw _RunFailure(
        '[${socket.label}] waiting for "$type" ($because) got error '
        '${d['code']}: ${d['message']}',
      );
    }
  }
  throw _RunFailure(
    '[${socket.label}] waiting for "$type" ($because): none in $maxFrames '
    'frames',
  );
}

int _entryOf(int seat) => seat * 13;

String _line(Object? value) => jsonEncode(value);

class _Recorder {
  _Recorder(this.args)
      : random = Random(args.choiceSeed),
        httpBase = Uri(
          scheme: args.target.scheme == 'wss' ? 'https' : 'http',
          host: args.target.host,
          port: args.target.hasPort ? args.target.port : null,
        );

  final _Args args;
  final Random random;

  /// The same server over HTTP: `/health` and the verify records. The
  /// `verify_url` the server hands out names the public host, which this
  /// tool never contacts.
  final Uri httpBase;

  late SimSocket host;
  late SimSocket guest;
  String chainCommit = '';
  Map<String, Object?> rules = <String, Object?>{};

  int gamesPlayed = 0;
  List<_Game> kept = <_Game>[];

  bool connected = false;

  String where() => 'choice-seed=${args.choiceSeed} target=${args.target} '
      'game=${gamesPlayed + 1} (the faces are the server\'s: re-run with the '
      'same seed against a fresh server and read the frames below)';

  /// The last few frames each seat received, printed with a failure.
  String tail() {
    if (!connected) {
      return '';
    }
    final StringBuffer out = StringBuffer();
    for (final SimSocket s in <SimSocket>[host, guest]) {
      final int from = max(0, s.log.length - 4);
      for (int i = from; i < s.log.length; i++) {
        out.writeln('  ${s.label}[$i]: ${_line(s.log[i])}');
      }
    }
    return out.toString();
  }

  Future<void> run() async {
    final String serverVersion = await _serverVersion();
    while (gamesPlayed < args.maxGames) {
      connected = false;
      host = await SimSocket.connect(args.target, label: 'host');
      try {
        guest = await SimSocket.connect(args.target, label: 'guest');
        connected = true;
        try {
          await _openRoom();
          final Frame openingTurn = await _begin();
          final _Played played = await _play(openingTurn);
          gamesPlayed++;
          await _settle(played);
          final int covered = _covered(kept).length;
          stdout.writeln(
            'game $gamesPlayed: winner seat ${played.winner}, '
            '${played.rolls.length} rolls, kept ${kept.length}, '
            'covered $covered/${_requirements.length}',
          );
        } finally {
          await guest.close();
        }
      } finally {
        await host.close();
      }
      if (_covered(kept).length == _requirements.length) {
        break;
      }
    }
    final Set<String> covered = _covered(kept);
    final List<String> missing = <String>[
      for (final String r in _requirements)
        if (!covered.contains(r)) r,
    ];
    stdout.writeln('games played: $gamesPlayed, games kept: ${kept.length}');
    for (final _Game g in kept) {
      stdout.writeln(
        'kept game ${g.order} (${g.gameId}): winner seat ${g.winner}, '
        '${g.totalRolls} rolls, covers ${(g.covers.toList()..sort()).join(', ')}',
      );
    }
    if (missing.isNotEmpty) {
      stdout.writeln(
        'not covered after $gamesPlayed games: ${missing.join(', ')}; '
        'run again against a fresh server process (create_room allows '
        '$_roomLimit rooms an hour per address)',
      );
      exitCode = 2;
      return;
    }
    stdout.writeln('coverage: all ${_requirements.length} covered '
        '(${_requirements.join(', ')})');
    final int bytes = _write(serverVersion);
    stdout.writeln('wrote ${args.out} ($bytes bytes)');
    exitCode = 0;
  }

  Future<String> _serverVersion() async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest req = await client
          .getUrl(httpBase.replace(path: '/health'))
          .timeout(const Duration(seconds: 15));
      final HttpClientResponse res =
          await req.close().timeout(const Duration(seconds: 15));
      final String body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      final Object? decoded = jsonDecode(body);
      if (res.statusCode != 200 ||
          decoded is! Map<String, Object?> ||
          decoded['version'] is! String) {
        throw _RunFailure(
          'GET /health returned ${res.statusCode} $body; expected 200 with a '
          'string "version"',
        );
      }
      return decoded['version']! as String;
    } finally {
      client.close(force: true);
    }
  }

  /// A new room: create, then join by code, as a host and a friend would.
  Future<void> _openRoom() async {
    await host.send('create_room', <String, Object?>{
      'name': args.hostName,
      'players': 2,
    });
    final Frame hostSeat =
        await _awaitType(host, 'seat_assigned', because: 'create_room reply');
    final int gotHost =
        requireInt(frameData(hostSeat), 'seat', frame: 'seat_assigned');
    if (gotHost != _hostSeat) {
      throw _RunFailure('the host was seated at $gotHost, expected '
          '$_hostSeat: ${frameData(hostSeat)}');
    }
    final Frame hostRoom =
        await _awaitType(host, 'room', because: 'create_room reply');
    final Map<String, Object?> roomData = frameData(hostRoom);
    final String code = requireString(roomData, 'code', frame: 'room');
    _takeRoom(roomData);

    await guest.send('join_room', <String, Object?>{
      'code': code,
      'name': args.guestName,
    });
    final Frame guestSeat =
        await _awaitType(guest, 'seat_assigned', because: 'join_room reply');
    final int gotGuest =
        requireInt(frameData(guestSeat), 'seat', frame: 'seat_assigned');
    if (gotGuest != _guestSeat) {
      throw _RunFailure('the guest was seated at $gotGuest, expected '
          '$_guestSeat: ${frameData(guestSeat)}');
    }
    await _awaitType(guest, 'room', because: 'join_room reply');
    await _awaitType(host, 'player_joined', because: 'the guest joined');
  }

  void _takeRoom(Map<String, Object?> roomData) {
    chainCommit = requireString(roomData, 'chain_commit', frame: 'room');
    final Object? r = roomData['rules'];
    if (r is! Map<String, Object?>) {
      throw _RunFailure('the room frame has no rules object: $roomData');
    }
    rules = r;
  }

  /// Brings the lobby to a started game and returns the opening `turn` frame.
  /// The host fixes its own seed once the lobby's `chain_commit` is in hand;
  /// the guest leaves its seed to the server.
  Future<Frame> _begin() async {
    final String seed = 'rec-${args.choiceSeed}-g${gamesPlayed + 1}';
    await host.send('set_seed', <String, Object?>{'client_seed': seed});
    await _awaitType(host, 'seat_seed', because: 'the host set_seed');
    await _awaitType(guest, 'seat_seed', because: 'the host set_seed');
    await host.send('start_game', <String, Object?>{});
    await _awaitType(host, 'game_started', because: 'game start');
    await _awaitType(guest, 'game_started', because: 'game start');
    await _awaitType(guest, 'turn', because: 'the opening turn');
    return _awaitType(host, 'turn', because: 'the opening turn');
  }

  SimSocket _socketOf(int seat) => seat == _hostSeat ? host : guest;

  /// Plays to `game_over`, reading seat 0's socket and acting for whichever
  /// seat is on turn. Every move is one the server offered.
  Future<_Played> _play(Frame openingTurn) async {
    final Frame startedFrame = host.log.lastWhere(
      (Frame f) => frameType(f) == 'game_started',
    );
    final Map<String, Object?> started = frameData(startedFrame);
    final String gameId =
        requireString(started, 'game_id', frame: 'game_started');
    final String clientSeeds =
        requireString(started, 'client_seeds', frame: 'game_started');
    final String commit = chainCommit;
    final FairnessTracker fairness = FairnessTracker(
      chainCommit: commit,
      gameId: gameId,
      clientSeeds: clientSeeds,
    );
    final List<SeenRoll> rolls = <SeenRoll>[];
    Frame? frame = openingTurn;
    for (int read = 0; read < 20000; read++) {
      frame ??= await host.next();
      final String type = frameType(frame);
      final Map<String, Object?> d = frameData(frame);
      if (d['by'] != null) {
        throw _RunFailure(
          'a "$type" frame carries by=${d['by']}: the turn timer played for '
          'a seat, so this game is not one the tool played. Frame: ${_line(d)}',
        );
      }
      switch (type) {
        case 'rolled':
          fairness.verifyRolled(d);
          rolls.add(SeenRoll(
            k: requireInt(d, 'k', frame: 'rolled'),
            seat: requireInt(d, 'seat', frame: 'rolled'),
            reveal: requireString(d, 'reveal', frame: 'rolled'),
            die: requireInt(d, 'value', frame: 'rolled'),
          ));
          if (_hasMove(d)) {
            await _sendMove(requireInt(d, 'seat', frame: 'rolled'), d);
          }
        case 'turn':
          final int seat = requireInt(d, 'seat', frame: 'turn');
          if (d['phase'] == 'await_move') {
            await _sendMove(seat, d);
          } else {
            await _socketOf(seat).send('roll', <String, Object?>{});
          }
        case 'game_over':
          final String url = requireString(d, 'verify_url', frame: 'game_over');
          if (!url.endsWith('/v/$gameId')) {
            throw _RunFailure('game_over.verify_url="$url" does not end with '
                '"/v/$gameId"');
          }
          // The guest's socket was not read during play; its queue still holds
          // every frame of the game ahead of this one.
          await _awaitType(
            guest,
            'game_over',
            because: 'game over',
            maxFrames: 20000,
          );
          return _Played(
            gameId: gameId,
            clientSeeds: clientSeeds,
            chainCommit: commit,
            winner: requireInt(d, 'winner', frame: 'game_over'),
            verifyUrl: url,
            rolls: rolls,
          );
        case 'error':
          throw _RunFailure(
            'error frame during play: ${d['code']}: ${d['message']} '
            '(after ${rolls.length} rolls)',
          );
        default:
          break;
      }
      frame = null;
    }
    throw _RunFailure('read 20000 frames without a game_over');
  }

  bool _hasMove(Map<String, Object?> d) {
    final Object? byFace = d['legal_by_face'];
    if (byFace is List<Object?>) {
      return byFace.isNotEmpty;
    }
    final Object? legal = d['legal'];
    return legal is List<Object?> && legal.isNotEmpty;
  }

  /// Sends one `move`, drawn at random from what the frame offered:
  /// `legal_by_face` (face and token) when present, else `legal`.
  Future<void> _sendMove(int seat, Map<String, Object?> d) async {
    final Object? byFace = d['legal_by_face'];
    if (byFace is List<Object?> && byFace.isNotEmpty) {
      final List<(int, int)> options = <(int, int)>[];
      for (final Map<String, Object?> entry
          in requireMapList(d, 'legal_by_face', frame: 'move offer')) {
        final int face = requireInt(entry, 'face', frame: 'legal_by_face');
        for (final int token
            in requireIntList(entry, 'tokens', frame: 'legal_by_face')) {
          options.add((face, token));
        }
      }
      if (options.isEmpty) {
        throw _RunFailure('legal_by_face has no tokens: ${_line(d)}');
      }
      final (int, int) pick = options[random.nextInt(options.length)];
      await _socketOf(seat).send(
        'move',
        <String, Object?>{'token': pick.$2, 'face': pick.$1},
      );
      return;
    }
    final List<int> legal = requireIntList(d, 'legal', frame: 'move offer');
    if (legal.isEmpty) {
      throw _RunFailure('a move is due but the frame offers none: ${_line(d)}');
    }
    await _socketOf(seat).send(
      'move',
      <String, Object?>{'token': legal[random.nextInt(legal.length)]},
    );
  }

  /// The frames [socket] received, from its first frame through its last
  /// `game_over`, `pong` dropped.
  List<Frame> _viewOf(int seat) {
    final SimSocket socket = _socketOf(seat);
    int end = -1;
    for (int i = socket.log.length - 1; i >= 0; i--) {
      if (frameType(socket.log[i]) == 'game_over') {
        end = i;
        break;
      }
    }
    if (end < 0) {
      throw _RunFailure('seat $seat received no game_over');
    }
    return <Frame>[
      for (final Frame f in socket.log.sublist(0, end + 1))
        if (frameType(f) != 'pong') f,
    ];
  }

  Future<void> _settle(_Played played) async {
    final Map<int, List<Frame>> views = <int, List<Frame>>{
      _hostSeat: _viewOf(_hostSeat),
      _guestSeat: _viewOf(_guestSeat),
    };
    final _Game game = await _analyse(played, views);
    final List<_Game> pool = <_Game>[...kept, game];
    final List<_Game> best = _bestSubset(pool);
    if (best.contains(game)) {
      game.gameLog = await _fetchGameLog(played.gameId, views[_hostSeat]!);
      kept = best..sort((_Game a, _Game b) => a.order.compareTo(b.order));
    } else {
      kept = best..sort((_Game a, _Game b) => a.order.compareTo(b.order));
    }
  }

  /// Fewest-games-first is the third key: most requirements covered, then
  /// fewest games, then fewest rolls in total.
  List<_Game> _bestSubset(List<_Game> pool) {
    List<_Game> best = <_Game>[];
    (int, int, int) bestScore = (0, 0, 0);
    for (int mask = 0; mask < (1 << pool.length); mask++) {
      final List<_Game> subset = <_Game>[
        for (int i = 0; i < pool.length; i++)
          if (mask & (1 << i) != 0) pool[i],
      ];
      if (subset.length > _maxKept) {
        continue;
      }
      final int covered = _covered(subset).length;
      final int rolls = subset.fold(0, (int a, _Game g) => a + g.totalRolls);
      final (int, int, int) score = (covered, -subset.length, -rolls);
      if (_better(score, bestScore)) {
        best = subset;
        bestScore = score;
      }
    }
    return best;
  }

  bool _better((int, int, int) a, (int, int, int) b) {
    if (a.$1 != b.$1) {
      return a.$1 > b.$1;
    }
    if (a.$2 != b.$2) {
      return a.$2 > b.$2;
    }
    return a.$3 > b.$3;
  }

  Set<String> _covered(List<_Game> games) => <String>{
        for (final _Game g in games) ...g.covers,
      };

  Future<_Game> _analyse(_Played played, Map<int, List<Frame>> views) async {
    final List<Frame> hostView = views[_hostSeat]!;
    final List<Frame> guestView = views[_guestSeat]!;

    // Both seats saw the same game, push for push.
    final List<int> hostIdx = <int>[
      for (int i = 0; i < hostView.length; i++)
        if (_gamePushTypes.contains(frameType(hostView[i]))) i,
    ];
    final List<int> guestIdx = <int>[
      for (int i = 0; i < guestView.length; i++)
        if (_gamePushTypes.contains(frameType(guestView[i]))) i,
    ];
    if (hostIdx.length != guestIdx.length) {
      throw _RunFailure(
        'seat 0 received ${hostIdx.length} game pushes and seat 2 received '
        '${guestIdx.length} for game ${played.gameId}',
      );
    }
    for (int p = 0; p < hostIdx.length; p++) {
      final Frame a = hostView[hostIdx[p]];
      final Frame b = guestView[guestIdx[p]];
      if (frameType(a) != frameType(b) ||
          _line(frameData(a)) != _line(frameData(b))) {
        throw _RunFailure(
          'push $p of game ${played.gameId} differs between the seats: '
          'seat 0 ${_line(a)} vs seat 2 ${_line(b)}',
        );
      }
    }
    Map<String, int> viewIndexAt(int hostViewIndex) {
      final int p = hostIdx.indexOf(hostViewIndex);
      return <String, int>{
        '$_hostSeat': hostViewIndex,
        '$_guestSeat': guestIdx[p],
      };
    }

    final Map<int, List<int>> tokens = <int, List<int>>{
      _hostSeat: <int>[-1, -1, -1, -1],
      _guestSeat: <int>[-1, -1, -1, -1],
    };
    final Map<int, Map<String, int>> counts = <int, Map<String, int>>{
      for (final int s in <int>[_hostSeat, _guestSeat])
        s: <String, int>{
          'rolls': 0,
          'sixes': 0,
          'captures_made': 0,
          'times_captured': 0,
          'home': 0,
        },
    };
    final List<Map<String, Object?>> events = <Map<String, Object?>>[];
    final Set<String> covers = <String>{};
    final int winner = played.winner;
    covers.add(winner == _hostSeat ? _reqHostWin : _reqGuestWin);

    for (final int i in hostIdx) {
      final Frame frame = hostView[i];
      final String type = frameType(frame);
      final Map<String, Object?> d = frameData(frame);
      if (type == 'rolled') {
        final int seat = requireInt(d, 'seat', frame: 'rolled');
        counts[seat]!['rolls'] = counts[seat]!['rolls']! + 1;
        if (requireInt(d, 'value', frame: 'rolled') == 6) {
          counts[seat]!['sixes'] = counts[seat]!['sixes']! + 1;
        }
        final Object? queueRaw = d['queue'];
        if (queueRaw is List<Object?> && queueRaw.length >= 2) {
          final List<int> queue = requireIntList(d, 'queue', frame: 'rolled');
          final Object? byFace = d['legal_by_face'];
          if (byFace is List<Object?> && byFace.isNotEmpty) {
            final Set<int> live = <int>{
              for (final Map<String, Object?> e in requireMapList(
                d,
                'legal_by_face',
                frame: 'rolled',
              ))
                requireInt(e, 'face', frame: 'legal_by_face'),
            };
            if (queue.any((int face) => !live.contains(face))) {
              events.add(<String, Object?>{
                'kind': 'dead_face',
                'seat': seat,
                'view_index': viewIndexAt(i),
              });
              covers.add(_reqDeadFace);
            }
          }
        }
      } else if (type == 'turn_passed') {
        final int seat = requireInt(d, 'seat', frame: 'turn_passed');
        final String reason = requireString(d, 'reason', frame: 'turn_passed');
        if (reason == 'three_sixes' || reason == 'no_legal_move') {
          events.add(<String, Object?>{
            'kind': reason,
            'seat': seat,
            'view_index': viewIndexAt(i),
          });
          covers
              .add(reason == 'three_sixes' ? _reqThreeSixes : _reqNoLegalMove);
        } else {
          throw _RunFailure('turn_passed with an undefined reason "$reason": '
              '${_line(d)}');
        }
      } else if (type == 'moved') {
        _applyMoved(d, tokens, counts, events, covers, viewIndexAt(i));
      }
    }

    final Map<int, List<int>> finalTokens = <int, List<int>>{
      for (final int s in <int>[_hostSeat, _guestSeat])
        s: List<int>.of(tokens[s]!),
    };
    for (final int s in <int>[_hostSeat, _guestSeat]) {
      counts[s]!['home'] = finalTokens[s]!.where((int t) => t == 57).length;
    }
    if (finalTokens[winner]!.any((int t) => t != 57)) {
      throw _RunFailure(
        'game_over names seat $winner but the moved frames leave its tokens '
        'at ${finalTokens[winner]} (game ${played.gameId})',
      );
    }
    final int total =
        counts[_hostSeat]!['rolls']! + counts[_guestSeat]!['rolls']!;
    if (total != played.rolls.length) {
      throw _RunFailure('${played.rolls.length} rolled frames were verified '
          'but the views count $total rolls');
    }
    await _crossCheckRecord(played, counts);

    return _Game(
      order: gamesPlayed,
      gameId: played.gameId,
      rules: rules,
      winner: winner,
      finalTokens: finalTokens,
      counts: counts,
      views: views,
      events: events,
      covers: covers,
      totalRolls: total,
    );
  }

  /// Folds one `moved` frame into [tokens], failing if the frame does not
  /// start where the previous frames left that token, and records captures.
  void _applyMoved(
    Map<String, Object?> d,
    Map<int, List<int>> tokens,
    Map<int, Map<String, int>> counts,
    List<Map<String, Object?>> events,
    Set<String> covers,
    Map<String, int> viewIndex,
  ) {
    final int seat = requireInt(d, 'seat', frame: 'moved');
    final int token = requireInt(d, 'token', frame: 'moved');
    final int from = requireInt(d, 'from', frame: 'moved');
    final int to = requireInt(d, 'to', frame: 'moved');
    if (tokens[seat]![token] != from) {
      throw _RunFailure(
        'moved frame ${_line(d)} starts seat $seat token $token at $from but '
        'the frames before it left it at ${tokens[seat]![token]}',
      );
    }
    tokens[seat]![token] = to;
    final List<Map<String, Object?>> captured =
        requireMapList(d, 'captured', frame: 'moved');
    for (final Map<String, Object?> c in captured) {
      final int victim = requireInt(c, 'seat', frame: 'moved.captured');
      final int victimToken = requireInt(c, 'token', frame: 'moved.captured');
      final int victimAt = tokens[victim]![victimToken];
      if (to < 0 || to > 51 || victimAt < 0 || victimAt > 51) {
        throw _RunFailure(
          'capture off the main track in ${_line(d)}: mover at $to, victim '
          'token at $victimAt',
        );
      }
      final int moverSquare = (_entryOf(seat) + to) % 52;
      final int victimSquare = (_entryOf(victim) + victimAt) % 52;
      if (moverSquare != victimSquare) {
        throw _RunFailure(
          'capture between different squares in ${_line(d)}: mover on '
          '$moverSquare, victim on $victimSquare',
        );
      }
      tokens[victim]![victimToken] = -1;
      counts[seat]!['captures_made'] = counts[seat]!['captures_made']! + 1;
      counts[victim]!['times_captured'] =
          counts[victim]!['times_captured']! + 1;
      events.add(<String, Object?>{
        'kind': 'capture',
        'by': seat,
        'victim': victim,
        'view_index': viewIndex,
      });
      if (!_entrySquares.contains(moverSquare)) {
        covers.add(
          seat == _hostSeat ? _reqCaptureBySeat0 : _reqCaptureBySeat2,
        );
      }
    }
  }

  /// Fetches the stored record from the server under test and compares the
  /// roll and six counts per seat with what the frames show. The fetch also
  /// goes through the simulator's own record check.
  Future<void> _crossCheckRecord(
    _Played played,
    Map<int, Map<String, int>> counts,
  ) async {
    final Uri jsonUri = httpBase.replace(path: '/v/${played.gameId}.json');
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    Map<String, Object?>? record;
    try {
      for (int attempt = 0; attempt < 100 && record == null; attempt++) {
        final HttpClientRequest req =
            await client.getUrl(jsonUri).timeout(const Duration(seconds: 15));
        final HttpClientResponse res =
            await req.close().timeout(const Duration(seconds: 15));
        final String body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final Object? decoded = jsonDecode(body);
          if (decoded is Map<String, Object?>) {
            record = decoded;
          }
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } finally {
      client.close(force: true);
    }
    if (record == null) {
      throw _RunFailure('GET $jsonUri never answered 200 with a record');
    }
    final Object? recordRolls = record['rolls'];
    if (recordRolls is! List<Object?>) {
      throw _RunFailure('the record at $jsonUri has no rolls list');
    }
    for (final int s in <int>[_hostSeat, _guestSeat]) {
      int rolls = 0;
      int sixes = 0;
      for (final Object? r in recordRolls) {
        if (r is Map<String, Object?> && r['seat'] == s) {
          rolls++;
          if (r['die'] == 6) {
            sixes++;
          }
        }
      }
      if (rolls != counts[s]!['rolls'] || sixes != counts[s]!['sixes']) {
        throw _RunFailure(
          'seat $s: the frames show ${counts[s]!['rolls']} rolls and '
          '${counts[s]!['sixes']} sixes, the stored record at $jsonUri has '
          '$rolls rolls and $sixes sixes',
        );
      }
    }
    try {
      await fetchAndVerifyRecord(
        verifyUrl: httpBase.replace(path: '/v/${played.gameId}').toString(),
        gameId: played.gameId,
        chainCommit: played.chainCommit,
        clientSeeds: played.clientSeeds,
        winner: played.winner,
        rolls: played.rolls,
      );
    } on ScenarioFailure catch (error) {
      throw _RunFailure(error.message);
    }
  }

  /// Seat 0 asks for the `game_log` and keeps every part verbatim, after
  /// checking it is the broadcast pushes of this game that seat 0 received.
  Future<List<Frame>> _fetchGameLog(String gameId, List<Frame> hostView) async {
    // Section 17 rule 4 limits requests per connection; this socket asks once.
    final String id = await host.send('game_log', <String, Object?>{});
    final List<Frame> parts = <Frame>[];
    int expectedParts = 1;
    do {
      final Frame frame = await host.next();
      final String type = frameType(frame);
      final Map<String, Object?> d = frameData(frame);
      if (type == 'error') {
        throw _RunFailure('game_log answered error ${d['code']}: '
            '${d['message']}');
      }
      if (type != 'game_log' || frame['re'] != id) {
        throw _RunFailure('expected game_log re=$id, got ${_line(frame)}');
      }
      expectedParts = requireInt(d, 'parts', frame: 'game_log');
      if (requireInt(d, 'part', frame: 'game_log') != parts.length + 1) {
        throw _RunFailure('game_log part out of order: ${_line(d)}');
      }
      if (d['game_id'] != gameId) {
        throw _RunFailure('game_log game_id ${d['game_id']} is not $gameId');
      }
      parts.add(frame);
    } while (parts.length < expectedParts);

    final List<Map<String, Object?>> logged = <Map<String, Object?>>[
      for (final Frame part in parts)
        ...requireMapList(frameData(part), 'frames', frame: 'game_log'),
    ];
    final int startIdx = hostView.indexWhere(
      (Frame f) => frameType(f) == 'game_started',
    );
    const Set<String> unicast = <String>{
      'seat_assigned',
      'room',
      'game_log',
      'error',
      'pong',
    };
    final List<Frame> seen = <Frame>[
      for (final Frame f in hostView.sublist(startIdx))
        if (!unicast.contains(frameType(f))) f,
    ];
    if (seen.length != logged.length) {
      throw _RunFailure(
        'game_log holds ${logged.length} frames, seat 0 received '
        '${seen.length} pushes from game_started on (game $gameId)',
      );
    }
    for (int i = 0; i < seen.length; i++) {
      if (logged[i]['t'] != frameType(seen[i]) ||
          _line(logged[i]['d']) != _line(frameData(seen[i]))) {
        throw _RunFailure(
          'game_log entry $i is ${_line(logged[i])} but seat 0 received '
          '${_line(seen[i])} (game $gameId)',
        );
      }
    }
    return parts;
  }

  String _gameName(_Game g, Map<int, int> perWinner) {
    final int n = (perWinner[g.winner] ?? 0) + 1;
    perWinner[g.winner] = n;
    return '${g.winner == _hostSeat ? 'host' : 'guest'}_wins_$n';
  }

  /// Writes the fixture and returns its size in bytes. Two-space indent;
  /// every recorded frame, event and small object sits on one line.
  int _write(String serverVersion) {
    final StringBuffer out = StringBuffer();
    final Map<int, int> perWinner = <int, int>{};
    out.writeln('{');
    out.writeln('  "format": 1,');
    out.writeln(
        '  "tool": "packages/ludo_server/tool/record_real_games.dart",');
    out.writeln('  "server_version": ${_line(serverVersion)},');
    out.writeln(
      '  "recorded_at": ${_line(DateTime.now().toUtc().toIso8601String())},',
    );
    out.writeln('  "choice_seed": ${args.choiceSeed},');
    out.writeln('  "games": [');
    for (int gi = 0; gi < kept.length; gi++) {
      final _Game g = kept[gi];
      out.writeln('    {');
      out.writeln('      "name": ${_line(_gameName(g, perWinner))},');
      out.writeln('      "players": 2,');
      out.writeln('      "seats": [$_hostSeat, $_guestSeat],');
      out.writeln('      "names": ${_line(<String, String>{
            '$_hostSeat': args.hostName,
            '$_guestSeat': args.guestName,
          })},');
      out.writeln('      "rules": ${_line(g.rules)},');
      out.writeln('      "game_id": ${_line(g.gameId)},');
      out.writeln('      "winner": ${g.winner},');
      out.writeln('      "final_tokens": ${_line(<String, List<int>>{
            for (final MapEntry<int, List<int>> e in g.finalTokens.entries)
              '${e.key}': e.value,
          })},');
      out.writeln('      "counts": ${_line(<String, Map<String, int>>{
            for (final MapEntry<int, Map<String, int>> e in g.counts.entries)
              '${e.key}': e.value,
          })},');
      out.writeln('      "views": {');
      final List<int> seats = <int>[_hostSeat, _guestSeat];
      for (int si = 0; si < seats.length; si++) {
        out.writeln('        "${seats[si]}": [');
        _writeLines(out, g.views[seats[si]]!, '          ');
        out.writeln('        ]${si == seats.length - 1 ? '' : ','}');
      }
      out.writeln('      },');
      out.writeln('      "game_log": [');
      _writeLines(out, g.gameLog, '        ');
      out.writeln('      ],');
      out.writeln('      "events": [');
      _writeLines(out, g.events, '        ');
      out.writeln('      ]');
      out.writeln('    }${gi == kept.length - 1 ? '' : ','}');
    }
    out.writeln('  ]');
    out.writeln('}');
    final List<int> bytes = utf8.encode(out.toString());
    final File file = File(args.out);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return bytes.length;
  }

  void _writeLines(StringBuffer out, List<Object?> items, String indent) {
    for (int i = 0; i < items.length; i++) {
      out.writeln(
          '$indent${_line(items[i])}${i == items.length - 1 ? '' : ','}');
    }
  }
}

Future<void> main(List<String> argv) async {
  final _Args args;
  try {
    args = _parseArgs(argv);
  } on _UsageError catch (error) {
    stderr.writeln('record_real_games: $error');
    stderr.write(_usage);
    exitCode = 64;
    return;
  }
  final _Recorder recorder = _Recorder(args);
  try {
    await recorder.run().timeout(Duration(seconds: args.timeoutSeconds));
  } on TimeoutException {
    stderr.writeln('FAIL: the run did not finish within --timeout-seconds '
        '${args.timeoutSeconds} (${recorder.where()})');
    stderr.write(recorder.tail());
    exitCode = 1;
  } catch (error) {
    stderr.writeln('FAIL: $error (${recorder.where()})');
    stderr.write(recorder.tail());
    exitCode = 1;
  }
}
