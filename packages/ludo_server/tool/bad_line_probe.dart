// The bad-line probe (X228): how long a tap and a move take to land when
// both players sit on a very bad line.
//
//   dart run tool/bad_line_probe.dart [--profile none|syria-bad]
//       [--games N] [--seed N] [--rto-ms N] [--target ws://host:port/path]
//       [--ruleset 2026-10|2026-11|2026-12] [--out file.json]
//       [--timeout-seconds N]
//
// Without --target it starts `bin/server.dart` on a free loopback port with
// an environment it builds itself (PORT, RULESET, LUDO_VERIFY_DIR,
// LUDO_VERSION, PATH, HOME and nothing else) and stops it at the end. Every
// client gets its own TCP relay (tool/probe/line.dart) that impairs both
// directions in user space; `tc netem` needs root and there is none here.
// The relay's random draws are seeded by --seed; the dice are the server's
// own CSPRNG, so two runs with one seed see the same line but not the same
// games.
//
// Two scripted clients per game speak the real protocol through their
// relays and act the moment they may: `roll` on their own `await_roll`
// turn, `move` with the first legal token on their own `rolled` or
// `await_move` turn. Measured, with one Stopwatch for every client in the
// process:
//   tap-to-face       the roller sends `roll` -> the roller reads its `rolled`
//   move-to-opponent  the mover sends `move` -> the other client reads `moved`
// plus every frame's payload size by type and direction, frames and bytes per
// game, and the frames each roll and move costs on the wire.
//
// Exit 0 when every game reached game_over on both sockets, 1 otherwise,
// 64 on a bad argument.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'probe/line.dart';
import 'probe/report.dart';

const String _usage = '''
usage: dart run tool/bad_line_probe.dart [--profile none|syria-bad] [--games N]
       [--seed N] [--rto-ms N] [--target ws://host:port/path]
       [--ruleset 2026-10|2026-11|2026-12] [--out file.json] [--timeout-seconds N]
''';

class _Args {
  String profile = 'syria-bad';
  int games = 5;
  int seed = 1124;
  int rtoMs = 1000;
  String? target;
  String ruleset = '2026-12';
  String? out;
  int timeoutSeconds = 3600;
}

_Args _parse(List<String> argv) {
  final _Args a = _Args();
  for (int i = 0; i < argv.length; i++) {
    final String flag = argv[i];
    if (i + 1 >= argv.length) {
      throw FormatException('$flag needs a value');
    }
    final String v = argv[++i];
    int asInt() {
      final int? n = int.tryParse(v);
      if (n == null) {
        throw FormatException('$flag takes an integer, got "$v"');
      }
      return n;
    }

    switch (flag) {
      case '--profile':
        if (!LineProfile.names.contains(v)) {
          throw FormatException(
              '--profile is one of ${LineProfile.names.join(', ')}, got "$v"');
        }
        a.profile = v;
      case '--games':
        a.games = asInt();
        if (a.games < 1 || a.games > 5) {
          throw const FormatException(
              '--games is 1 to 5: create_room allows five rooms per hour per '
              'address (docs/PROTOCOL.md section 7) and every game is a room');
        }
      case '--seed':
        a.seed = asInt();
      case '--rto-ms':
        a.rtoMs = asInt();
        if (a.rtoMs < 1) {
          throw const FormatException('--rto-ms must be positive');
        }
      case '--target':
        if (!v.startsWith('ws://')) {
          throw const FormatException(
              '--target takes a ws:// URL; a wss:// target would need the '
              'relay to carry TLS, which it does not');
        }
        a.target = v;
      case '--ruleset':
        if (!<String>['2026-10', '2026-11', '2026-12'].contains(v)) {
          throw FormatException('--ruleset is 2026-10, 2026-11 or 2026-12, '
              'got "$v"');
        }
        a.ruleset = v;
      case '--out':
        a.out = v;
      case '--timeout-seconds':
        a.timeoutSeconds = asInt();
      default:
        throw FormatException('unknown flag $flag');
    }
  }
  return a;
}

/// The server's per-socket limit is 30 messages in a second; one send every
/// 50 ms is 20 a second at most.
const int _serverMessageWarnPerSecond = 30;
const double _minSendGapMs = 50;

final Stopwatch _watch = Stopwatch()..start();
double _nowMs() => _watch.elapsedMicroseconds / 1000.0;

/// One client message and what the wire did with it.
class _Action {
  _Action(this.type, this.seat, this.sentAtMs);
  final String type;
  final int seat;
  final double sentAtMs;
  double? replyAtMs;
  final List<String> framesToActor = <String>[];
  final Set<int> seqs = <int>{};
  int framesBeforeReply = 0;
  int otherSendsBeforeReply = 0;
}

/// Everything measured over a run.
class _Measure {
  final List<double> tapToFace = <double>[];
  final List<double> moveToOpponent = <double>[];
  final Map<String, SizeStats> sizes = <String, SizeStats>{};
  final Map<String, String> largestRaw = <String, String>{};
  final Map<String, int> _largest = <String, int>{};
  final List<Map<String, Object?>> games = <Map<String, Object?>>[];
  final List<_Action> actions = <_Action>[];
  final List<String> errors = <String>[];

  void frame(String dir, String type, String raw) {
    final int bytes = utf8.encode(raw).length;
    final String key = '$dir $type';
    final SizeStats s = sizes.putIfAbsent(key, SizeStats.new);
    if (bytes > (_largest[key] ?? -1)) {
      _largest[key] = bytes;
      largestRaw[key] = raw;
    }
    s.add(bytes);
  }
}

class _Game {
  _Game(this.index, this.measure);
  final int index;
  final _Measure measure;
  final Map<int, Queue<double>> pendingMoves = <int, Queue<double>>{};
  final Map<String, _Action> byId = <String, _Action>{};
  final Map<int, String> seqOwner = <int, String>{};
  final List<(String, int, String)> seqFrames = <(String, int, String)>[];
  final Completer<String> code = Completer<String>();
  int framesC2s = 0;
  int framesS2c = 0;
  int bytesC2s = 0;
  int bytesS2c = 0;
  int rolls = 0;
  int moves = 0;
  int timerSteps = 0;
}

class _Player {
  _Player(this.label, this.game, this.ws, {required this.host});
  final String label;
  final _Game game;
  final WebSocket ws;
  final bool host;
  int? seat;
  int _ids = 0;
  final Completer<void> over = Completer<void>()..future.ignore();
  final Set<String> pendingIds = <String>{};

  /// The server limits one socket to [_serverMessageWarnPerSecond] messages
  /// in any second (lib/src/rate_limit.dart `_messageWarnLimit`, enforced in
  /// lib/src/connection.dart) and answers the rest with RATE_LIMITED, closing
  /// at twice that. A scripted client that acts the moment it may, on a line
  /// with no delay, sends far faster than any person does, so every send is
  /// held until [_minSendGapMs] after this client's previous one. The gap is
  /// applied before the stopwatch of a sample starts: a sample runs from the
  /// moment the frame is written to the socket, so pacing never enters it.
  double _nextSendAtMs = 0;

  void send(String type, Map<String, Object?> d) {
    final double now = _nowMs();
    final double at = now < _nextSendAtMs ? _nextSendAtMs : now;
    _nextSendAtMs = at + _minSendGapMs;
    if (at <= now) {
      _sendNow(type, d);
      return;
    }
    Timer(Duration(microseconds: ((at - now) * 1000).ceil()), () {
      if (!over.isCompleted) {
        _sendNow(type, d);
      }
    });
  }

  String _sendNow(String type, Map<String, Object?> d) {
    final String id =
        'g${game.index}-$label-${(++_ids).toString().padLeft(5, '0')}';
    final String raw =
        jsonEncode(<String, Object?>{'v': 1, 't': type, 'id': id, 'd': d});
    for (final String other in pendingIds) {
      game.byId[other]?.otherSendsBeforeReply++;
    }
    if (type == 'roll' || type == 'move') {
      final _Action a = _Action(type, seat!, _nowMs());
      game.byId[id] = a;
      game.measure.actions.add(a);
      pendingIds.add(id);
      if (type == 'move') {
        game.pendingMoves.putIfAbsent(seat!, Queue<double>.new).add(a.sentAtMs);
        game.moves++;
      } else {
        game.rolls++;
      }
    }
    ws.add(raw);
    game.measure.frame('c2s', type, raw);
    game.framesC2s++;
    game.bytesC2s += utf8.encode(raw).length;
    return id;
  }

  void onRaw(String raw) {
    final double at = _nowMs();
    final Map<String, Object?> f = jsonDecode(raw) as Map<String, Object?>;
    final String t = f['t']! as String;
    final Map<String, Object?> d =
        (f['d'] as Map<String, Object?>?) ?? <String, Object?>{};
    final String? re = f['re'] as String?;
    game.measure.frame('s2c', t, raw);
    game.framesS2c++;
    game.bytesS2c += utf8.encode(raw).length;
    for (final String id in pendingIds) {
      if (id != re) {
        game.byId[id]?.framesBeforeReply++;
      }
    }
    final Object? seq = d['seq'];
    if (seq is int) {
      game.seqFrames.add((label, seq, t));
    }
    if (re != null) {
      final _Action? a = game.byId[re];
      if (a != null) {
        a.framesToActor.add(t);
        if (seq is int) {
          a.seqs.add(seq);
          game.seqOwner[seq] = re;
        }
        if (a.replyAtMs == null) {
          a.replyAtMs = at;
          pendingIds.remove(re);
        }
      }
    }
    switch (t) {
      case 'seat_assigned':
        seat = d['seat']! as int;
      case 'room':
        if (host && !game.code.isCompleted) {
          game.code.complete(d['code']! as String);
        }
      case 'player_joined':
        if (host) {
          send('start_game', <String, Object?>{});
        }
      case 'turn':
        if (d['seat'] == seat) {
          if (d['phase'] == 'await_roll') {
            send('roll', <String, Object?>{});
          } else {
            _move(d);
          }
        }
      case 'rolled':
        if (d['by'] == 'timer') {
          game.timerSteps++;
        }
        if (d['seat'] == seat) {
          final _Action? a = re == null ? null : game.byId[re];
          if (a != null && a.type == 'roll') {
            game.measure.tapToFace.add(at - a.sentAtMs);
          }
          _move(d);
        }
      case 'moved':
        if (d['by'] == 'timer') {
          if (d['seat'] != seat) {
            game.timerSteps++;
          }
        } else if (d['seat'] != seat) {
          final Queue<double>? q = game.pendingMoves[d['seat']! as int];
          if (q != null && q.isNotEmpty) {
            game.measure.moveToOpponent.add(at - q.removeFirst());
          } else {
            game.measure.errors.add('game ${game.index} $label: moved for '
                'seat ${d['seat']} with no move sent by that seat');
          }
        }
      case 'error':
        game.measure.errors.add('game ${game.index} $label: ${jsonEncode(d)} '
            're=$re');
        final _Action? a = re == null ? null : game.byId[re];
        if (a != null && a.type == 'move') {
          game.pendingMoves[a.seat]?.remove(a.sentAtMs);
        }
      case 'game_over':
        if (!over.isCompleted) {
          over.complete();
        }
    }
  }

  void _move(Map<String, Object?> d) {
    final List<Object?> legal = d['legal'] as List<Object?>? ?? <Object?>[];
    if (legal.isNotEmpty) {
      send('move', <String, Object?>{'token': legal.first});
      return;
    }
    final List<Object?> byFace =
        d['legal_by_face'] as List<Object?>? ?? <Object?>[];
    if (byFace.isNotEmpty) {
      final Map<String, Object?> first = byFace.first! as Map<String, Object?>;
      send('move', <String, Object?>{
        'token': (first['tokens']! as List<Object?>).first,
        'face': first['face'],
      });
    }
  }
}

Future<int> _freePort() async {
  final ServerSocket s =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final int port = s.port;
  await s.close();
  return port;
}

class _LocalServer {
  _LocalServer(this.process, this.port, this.verifyDir, this.output);
  final Process process;
  final int port;
  final Directory verifyDir;
  final StringBuffer output;

  static Future<_LocalServer> start(String ruleset) async {
    final String packageDir = _packageDir();
    final int port = await _freePort();
    final Directory verifyDir =
        Directory.systemTemp.createTempSync('bad-line-probe-verify-');
    // Built from nothing: no CTL_* name, nothing else of this shell.
    final Map<String, String> env = <String, String>{
      'PORT': '$port',
      'RULESET': ruleset,
      'LUDO_VERIFY_DIR': verifyDir.path,
      'LUDO_VERSION': 'bad-line-probe',
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'HOME': Platform.environment['HOME'] ?? '/tmp',
    };
    final Process p = await Process.start(
      Platform.resolvedExecutable,
      <String>['bin/server.dart'],
      workingDirectory: packageDir,
      environment: env,
      includeParentEnvironment: false,
    );
    final StringBuffer output = StringBuffer();
    final Completer<void> listening = Completer<void>();
    p.stdout.transform(utf8.decoder).listen((String chunk) {
      output.write(chunk);
      if (!listening.isCompleted &&
          output.toString().contains('listening on port')) {
        listening.complete();
      }
    });
    p.stderr.transform(utf8.decoder).listen(output.write);
    unawaited(p.exitCode.then((int code) {
      if (!listening.isCompleted) {
        listening.completeError(
            StateError('server exited $code before listening:\n$output'));
      }
    }));
    await listening.future.timeout(const Duration(seconds: 60),
        onTimeout: () =>
            throw StateError('server not listening after 60 s:\n$output'));
    return _LocalServer(p, port, verifyDir, output);
  }

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -9;
    });
    if (verifyDir.existsSync()) {
      verifyDir.deleteSync(recursive: true);
    }
  }
}

String _packageDir() {
  final File script = File.fromUri(Platform.script);
  final Directory candidate = script.parent.parent;
  if (File('${candidate.path}/bin/server.dart').existsSync()) {
    return candidate.path;
  }
  return Directory.current.path;
}

Future<_Player> _connect(String label, _Game game, LineRelay relay, String path,
    {required bool host}) async {
  final WebSocket ws =
      await WebSocket.connect('ws://127.0.0.1:${relay.port}$path');
  final _Player p = _Player(label, game, ws, host: host);
  ws.listen((Object? raw) => p.onRaw(raw! as String), onDone: () {
    if (!p.over.isCompleted) {
      p.over.completeError(StateError('$label socket closed before game_over'));
    }
  });
  return p;
}

Future<void> _playGame(_Game game, _Args args, LineProfile profile, String host,
    int port, String path) async {
  final LineRelay hostLine = await LineRelay.start(
      upstreamHost: host,
      upstreamPort: port,
      profile: profile,
      seed: args.seed * 100 + game.index * 2);
  final LineRelay guestLine = await LineRelay.start(
      upstreamHost: host,
      upstreamPort: port,
      profile: profile,
      seed: args.seed * 100 + game.index * 2 + 1);
  final double started = _nowMs();
  try {
    final _Player a = await _connect('a', game, hostLine, path, host: true);
    a.send('create_room', <String, Object?>{'name': 'Probe A', 'players': 2});
    final String code = await game.code.future;
    final _Player b = await _connect('b', game, guestLine, path, host: false);
    b.send('join_room', <String, Object?>{
      'install': 'probe-install-${game.index.toString().padLeft(6, '0')}',
      'code': code,
      'name': 'Probe B',
    });
    await Future.wait(<Future<void>>[a.over.future, b.over.future]);
    final double ms = _nowMs() - started;
    await a.ws.close();
    await b.ws.close();
    game.measure.games.add(<String, Object?>{
      'game': game.index,
      'reached_game_over': true,
      'duration_s': (ms / 100).round() / 10,
      'rolls_sent': game.rolls,
      'moves_sent': game.moves,
      'timer_steps_seen': game.timerSteps,
      'frames_c2s': game.framesC2s,
      'frames_s2c': game.framesS2c,
      'payload_bytes_c2s': game.bytesC2s,
      'payload_bytes_s2c': game.bytesS2c,
      'wire_bytes_c2s': (hostLine.up?.bytes ?? 0) + (guestLine.up?.bytes ?? 0),
      'wire_bytes_s2c':
          (hostLine.down?.bytes ?? 0) + (guestLine.down?.bytes ?? 0),
      'line': <String, Object?>{
        'a_up': hostLine.up?.statsJson(),
        'a_down': hostLine.down?.statsJson(),
        'b_up': guestLine.up?.statsJson(),
        'b_down': guestLine.down?.statsJson(),
      },
    });
  } finally {
    await hostLine.close();
    await guestLine.close();
  }
}

/// What makes the largest frame of [raw] large: bytes per top-level `d` key.
Map<String, int> _fieldBytes(String raw) {
  final Map<String, Object?> f = jsonDecode(raw) as Map<String, Object?>;
  final Map<String, Object?> d =
      (f['d'] as Map<String, Object?>?) ?? <String, Object?>{};
  final List<MapEntry<String, int>> e = <MapEntry<String, int>>[
    for (final MapEntry<String, Object?> kv in d.entries)
      MapEntry<String, int>(kv.key, utf8.encode(jsonEncode(kv.value)).length),
  ]..sort((MapEntry<String, int> x, MapEntry<String, int> y) =>
      y.value.compareTo(x.value));
  return <String, int>{
    for (final MapEntry<String, int> kv in e) kv.key: kv.value
  };
}

Map<String, Object?> _wireShape(_Measure m, List<_Game> games) {
  final Map<String, int> rollShapes = <String, int>{};
  final Map<String, int> moveShapes = <String, int>{};
  int rollsMissingReply = 0;
  int extraSends = 0;
  int framesBefore = 0;
  for (final _Action a in m.actions) {
    final Map<String, int> into = a.type == 'roll' ? rollShapes : moveShapes;
    final String shape =
        a.framesToActor.isEmpty ? '(no reply)' : a.framesToActor.join('+');
    into[shape] = (into[shape] ?? 0) + 1;
    if (a.replyAtMs == null) {
      rollsMissingReply++;
    }
    extraSends += a.otherSendsBeforeReply;
    framesBefore += a.framesBeforeReply;
  }
  int opponentFrames = 0;
  int opponentUnowned = 0;
  for (final _Game g in games) {
    for (final (String _, int seq, String _) in g.seqFrames) {
      if (g.seqOwner.containsKey(seq)) {
        opponentFrames++;
      } else {
        opponentUnowned++;
      }
    }
  }
  return <String, Object?>{
    'c2s_messages_per_roll': 1,
    'c2s_messages_per_move': 1,
    'actions': m.actions.length,
    'actions_without_reply': rollsMissingReply,
    'other_client_messages_sent_between_an_action_and_its_reply': extraSends,
    'unrelated_frames_received_between_an_action_and_its_reply': framesBefore,
    'roll_reply_shapes_on_the_actors_socket': rollShapes,
    'move_reply_shapes_on_the_actors_socket': moveShapes,
    'seq_frames_received_belonging_to_a_client_action': opponentFrames,
    'seq_frames_received_not_caused_by_a_client_action': opponentUnowned,
  };
}

Future<void> main(List<String> argv) async {
  final _Args args;
  try {
    args = _parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('bad_line_probe: ${e.message}');
    stderr.write(_usage);
    exitCode = 64;
    return;
  }
  final LineProfile profile =
      LineProfile.named(args.profile, rtoMs: args.rtoMs);
  if (1000 / _minSendGapMs >= _serverMessageWarnPerSecond) {
    throw StateError('send gap $_minSendGapMs ms allows '
        '${1000 / _minSendGapMs} messages a second, the server warns above '
        '$_serverMessageWarnPerSecond');
  }

  _LocalServer? local;
  String host;
  int port;
  String path;
  if (args.target != null) {
    final Uri u = Uri.parse(args.target!);
    host = u.host;
    port = u.hasPort ? u.port : 80;
    path = u.path.isEmpty ? '/' : u.path;
  } else {
    local = await _LocalServer.start(args.ruleset);
    host = '127.0.0.1';
    port = local.port;
    path = '/';
  }

  final _Measure m = _Measure();
  final List<_Game> games = <_Game>[
    for (int i = 1; i <= args.games; i++) _Game(i, m),
  ];
  bool ok = true;
  final double started = _nowMs();
  try {
    // The games run side by side, each client on its own line.
    await Future.wait(<Future<void>>[
      for (final _Game g in games)
        _playGame(g, args, profile, host, port, path),
    ]).timeout(Duration(seconds: args.timeoutSeconds));
  } on Object catch (e) {
    ok = false;
    stderr.writeln('bad_line_probe: run failed: $e');
    if (local != null) {
      stderr.writeln('server output:\n${local.output}');
    }
  } finally {
    await local?.stop();
  }
  final double wallS = (_nowMs() - started) / 1000;

  final LatencySummary tap = LatencySummary(m.tapToFace);
  final LatencySummary mov = LatencySummary(m.moveToOpponent);
  final List<String> sizeKeys = m.sizes.keys.toList()..sort();
  final Map<String, Object?> json = <String, Object?>{
    'probe': 'bad_line_probe',
    'profile': profile.toJson(),
    'profile_line': profile.describe(),
    'netem_equivalent': profile.netemLine(),
    'impairment': 'user-space TCP relay per client, both directions; no tc '
        'netem (no root)',
    'seed': args.seed,
    'target': args.target ?? 'local bin/server.dart RULESET=${args.ruleset}',
    'games_requested': args.games,
    'games_reached_game_over': m.games.length,
    'wall_seconds': (wallS * 10).round() / 10,
    'tap_to_face_ms': tap.toJson(),
    'move_to_opponent_ms': mov.toJson(),
    'frame_sizes_bytes': <String, Object?>{
      for (final String k in sizeKeys) k: m.sizes[k]!.toJson(),
    },
    'largest_frame_fields_bytes': <String, Object?>{
      for (final String k in sizeKeys) k: _fieldBytes(m.largestRaw[k]!),
    },
    'games': m.games,
    'wire': _wireShape(m, games),
    'errors': m.errors,
  };
  if (m.games.length != args.games) {
    ok = false;
  }

  final StringBuffer out = StringBuffer()
    ..writeln('bad_line_probe  ${profile.describe()}')
    ..writeln('  netem equivalent (each end, egress; ingress via ifb): '
        '${profile.netemLine()}')
    ..writeln('  impairment: user-space TCP relay per client, both '
        'directions (no root, no tc); seed=${args.seed}; '
        'target=${json['target']}')
    ..writeln('  games: ${m.games.length}/${args.games} reached game_over '
        'on both sockets, wall ${wallS.toStringAsFixed(1)} s')
    ..writeln()
    ..writeln('  ${padRight('latency (ms)', 34)}${padLeft('n', 6)}'
        '${padLeft('P50', 8)}${padLeft('P95', 8)}${padLeft('P99', 8)}'
        '${padLeft('max', 8)}');
  for (final (String name, LatencySummary s) in <(String, LatencySummary)>[
    ('tap-to-face (roll -> own rolled)', tap),
    ('move-to-opponent (move -> moved)', mov),
  ]) {
    out.writeln('  ${padRight(name, 34)}${padLeft('${s.count}', 6)}'
        '${padLeft(fmtMs(s.p50), 8)}${padLeft(fmtMs(s.p95), 8)}'
        '${padLeft(fmtMs(s.p99), 8)}${padLeft(fmtMs(s.maxMs), 8)}');
  }
  out
    ..writeln()
    ..writeln('  ${padRight('frame payload bytes', 26)}${padLeft('count', 7)}'
        '${padLeft('min', 7)}${padLeft('median', 8)}${padLeft('max', 7)}');
  for (final String k in sizeKeys) {
    final Map<String, Object?> s = m.sizes[k]!.toJson();
    out.writeln('  ${padRight(k, 26)}${padLeft('${s['count']}', 7)}'
        '${padLeft('${s['min']}', 7)}${padLeft('${s['median']}', 8)}'
        '${padLeft('${s['max']}', 7)}');
  }
  out
    ..writeln()
    ..writeln('  per game: frames c2s/s2c, payload bytes c2s/s2c, wire bytes '
        'c2s/s2c (TCP payload through the relay, WebSocket framing and '
        'handshake included), rolls, moves, seconds');
  for (final Map<String, Object?> g in m.games) {
    out.writeln('  game ${g['game']}: frames ${g['frames_c2s']}/'
        '${g['frames_s2c']}, payload ${g['payload_bytes_c2s']}/'
        '${g['payload_bytes_s2c']} B, wire ${g['wire_bytes_c2s']}/'
        '${g['wire_bytes_s2c']} B, rolls ${g['rolls_sent']}, moves '
        '${g['moves_sent']}, ${g['duration_s']} s');
  }
  final Map<String, Object?> wire = json['wire']! as Map<String, Object?>;
  out
    ..writeln()
    ..writeln('  wire per action: ${jsonEncode(wire)}')
    ..writeln('  errors: ${m.errors.isEmpty ? 'none' : m.errors.join('; ')}');
  stdout.write(out);

  if (args.out != null) {
    File(args.out!)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(json)}\n');
    stdout.writeln('  json: ${args.out}');
  }
  exitCode = ok ? 0 : 1;
}
