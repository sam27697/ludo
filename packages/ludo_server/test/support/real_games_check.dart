// A pure checker for the recorded real-games fixture
// (`packages/ludo_client/integration_test/fixtures/real_games.json`).
//
// `checkRealGames` takes the decoded JSON and returns a list of problem
// strings. Every problem starts with the game name and, when it is about one
// frame, says `view <seat> frame <index> (<type>)`, so a failure can be
// reproduced by opening that file at that index. An empty list means the
// fixture is consistent with the engine, the dice chain and itself.
//
// The checker is written from docs/PROTOCOL.md, docs/ENGINE_API.md and
// docs/FAIRNESS.md and uses the same public packages the server uses
// (`ludo_engine`, `fair_dice`). It does not read or import the recorder.
//
// What is compared between the two seat views, and what is not (check 2):
//
// * `re` is excluded. docs/PROTOCOL.md section 1: it is present only on the
//   copy that answers the sender's own message, so the two views differ by
//   it by design (section 12.3: "The sender's copy carries `re`; the others
//   do not").
// * `id` is excluded. Section 1 calls it a server-generated opaque message
//   id and does not say a broadcast shares one; in the recorded file it
//   differs between the two sockets on every frame, so it is treated as
//   per-socket envelope data.
// * Nothing inside `d` is excluded. Section 5 names no per-socket field in
//   the payload of any broadcast frame: `deadline_ms` is "milliseconds
//   remaining" but section 13.1 has it built once from the registry's
//   segment and broadcast from one shared map.
// * Frames that are not broadcast are left out of both sides before the
//   comparison: `error`, `pong`, `seat_assigned`, `game_log` (section 5 and
//   17) and a `room` that carries `re` (an answer to one request).

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:fair_dice/fair_dice.dart' show drawDie, hexDecode, hexEncode;
import 'package:ludo_engine/ludo_engine.dart' as engine;

/// Where the fixture lives, relative to `packages/ludo_server`.
const String realGamesFixturePath =
    '../ludo_client/integration_test/fixtures/real_games.json';

/// Types docs/PROTOCOL.md section 5 lists as carrying `seq`.
const Set<String> _seqCarrying = <String>{
  'room',
  'player_joined',
  'player_left',
  'presence',
  'seat_seed',
  'game_started',
  'rolled',
  'moved',
  'turn_passed',
  'turn',
  'game_over',
};

/// Frames a socket receives that are not broadcast to the room.
const Set<String> _unicastTypes = <String>{
  'error',
  'pong',
  'seat_assigned',
  'game_log',
};

/// Frames that may sit inside a game without being part of the turn loop.
const Set<String> _ignorableInGame = <String>{
  'presence',
  'emote',
  'error',
  'pong',
  'game_log',
  'seat_assigned',
};

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

Map<String, Object?>? _asMap(Object? v) => v is Map<String, Object?> ? v : null;
List<Object?>? _asList(Object? v) => v is List<Object?> ? v : null;
int? _asInt(Object? v) => v is int ? v : null;
String? _asStr(Object? v) => v is String ? v : null;

/// Structural equality for decoded JSON. An int never equals a double.
bool deepEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) {
      return false;
    }
    for (final Object? k in a.keys) {
      if (!b.containsKey(k) || !deepEq(a[k], b[k])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (!deepEq(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }
  if (a is num && b is num) {
    return (a is int) == (b is int) && a == b;
  }
  return a == b;
}

String _show(Object? v) => jsonEncode(v);

class _Frame {
  _Frame(this.index, Object? raw) : map = _asMap(raw) ?? <String, Object?>{};

  final int index;
  final Map<String, Object?> map;

  String get t => _asStr(map['t']) ?? '?';
  Map<String, Object?> get d => _asMap(map['d']) ?? <String, Object?>{};

  bool get unicast =>
      _unicastTypes.contains(t) || (t == 'room' && map.containsKey('re'));
}

/// Runs every check over the decoded fixture and returns the problems found.
/// [info] receives one line per fact the report needs (which frame supplied
/// each game's `chain_commit`).
List<String> checkRealGames(Object? doc, {void Function(String line)? info}) {
  final List<String> out = <String>[];
  final Map<String, Object?>? root = _asMap(doc);
  if (root == null) {
    return <String>['fixture: top level is not a JSON object'];
  }
  if (root['format'] != 1) {
    out.add('fixture: format is ${_show(root['format'])}, expected 1');
  }
  final List<Object?>? games = _asList(root['games']);
  if (games == null || games.isEmpty) {
    out.add('fixture: "games" is missing or empty');
    return out;
  }
  final _Coverage coverage = _Coverage();
  for (var gi = 0; gi < games.length; gi++) {
    final Map<String, Object?>? game = _asMap(games[gi]);
    if (game == null) {
      out.add('game #$gi: not a JSON object');
      continue;
    }
    final String name = _asStr(game['name']) ?? 'game#$gi';
    final _GameCheck check = _GameCheck(name, game, out, coverage, info);
    try {
      check.run();
    } catch (e, st) {
      out.add('game $name: the checker could not read this game: $e\n$st');
    }
  }
  coverage.report(out);
  return out;
}

/// What the file as a whole shows (check 6, "Coverage"), gathered from the
/// frames of `views["0"]` rather than from the file's own `events`.
class _Coverage {
  bool hostWin = false;
  bool guestWin = false;
  final Set<int> captureBy = <int>{};
  bool threeSixes = false;
  bool noLegalMove = false;

  void report(List<String> out) {
    if (!hostWin) {
      out.add('coverage: no game won by the host (seat 0)');
    }
    if (!guestWin) {
      out.add('coverage: no game won by the guest (seat 2)');
    }
    if (!captureBy.contains(0)) {
      out.add('coverage: no capture made by seat 0');
    }
    if (!captureBy.contains(2)) {
      out.add('coverage: no capture made by seat 2');
    }
    if (!threeSixes) {
      out.add('coverage: no turn_passed with reason three_sixes');
    }
    if (!noLegalMove) {
      out.add('coverage: no turn_passed with reason no_legal_move');
    }
  }
}

class _GameCheck {
  _GameCheck(this.name, this.game, this.out, this.coverage, this.info);

  final String name;
  final Map<String, Object?> game;
  final List<String> out;
  final _Coverage coverage;
  final void Function(String line)? info;

  final Map<String, List<_Frame>> views = <String, List<_Frame>>{};
  final Map<String, int> startIndex = <String, int>{};
  final Map<String, int> endIndex = <String, int>{};

  /// View 0 frame indexes where the engine saw a roll queue of two or more
  /// faces with at least one face no token could use.
  final Set<int> deadFaceFrames = <int>{};

  void problem(String where, String message) =>
      out.add('game $name $where: $message');

  void frameProblem(String view, _Frame f, String message) =>
      problem('view $view frame ${f.index} (${f.t})', message);

  void run() {
    if (!_loadViews()) {
      return;
    }
    final Map<String, Object?>? snapshot = _checkSeatingAndSnapshot();
    _replayEngine();
    _checkViewsAgree();
    _checkSeq();
    _checkDice(snapshot);
    _checkCounts();
    _checkEvents();
    _checkGameLog();
    _gatherCoverage();
  }

  // ---------------------------------------------------------------- views

  bool _loadViews() {
    final Map<String, Object?>? raw = _asMap(game['views']);
    if (raw == null) {
      problem('views', 'missing or not an object');
      return false;
    }
    var ok = true;
    for (final String s in const <String>['0', '2']) {
      final List<Object?>? list = _asList(raw[s]);
      if (list == null) {
        problem('view $s', 'missing or not a list');
        ok = false;
        continue;
      }
      final List<_Frame> frames = <_Frame>[
        for (var i = 0; i < list.length; i++) _Frame(i, list[i]),
      ];
      views[s] = frames;
      for (final _Frame f in frames) {
        if (f.map['v'] != 1 ||
            _asStr(f.map['t']) == null ||
            _asMap(f.map['d']) == null) {
          frameProblem(s, f, 'not a v1 envelope {v, t, id, d}');
        }
      }
      final List<int> starts = <int>[
        for (final _Frame f in frames)
          if (f.t == 'game_started') f.index,
      ];
      final List<int> overs = <int>[
        for (final _Frame f in frames)
          if (f.t == 'game_over') f.index,
      ];
      if (starts.length != 1) {
        problem('view $s', 'has ${starts.length} game_started frames, want 1');
        ok = false;
        continue;
      }
      if (overs.length != 1) {
        problem('view $s', 'has ${overs.length} game_over frames, want 1');
        ok = false;
        continue;
      }
      startIndex[s] = starts.single;
      endIndex[s] = overs.single;
      if (overs.single != frames.length - 1) {
        frameProblem(
          s,
          frames[overs.single],
          'game_over is not the last frame; the view has '
          '${frames.length - 1 - overs.single} frames after it',
        );
      }
      if (starts.single > overs.single) {
        problem('view $s', 'game_over comes before game_started');
        ok = false;
      }
    }
    return ok && views.length == 2;
  }

  Iterable<_Frame> _range(String s) =>
      views[s]!.sublist(startIndex[s]!, endIndex[s]! + 1);

  // ------------------------------------------------- 7. seating, snapshot

  /// Returns the last LOBBY `room` snapshot before `game_started` in view 0.
  Map<String, Object?>? _checkSeatingAndSnapshot() {
    if (!deepEq(game['seats'], <int>[0, 2])) {
      problem('seats', 'is ${_show(game['seats'])}, want [0,2]');
    }
    if (game['players'] != 2) {
      problem('players', 'is ${_show(game['players'])}, want 2');
    }
    Map<String, Object?>? chosen;
    for (final String s in const <String>['0', '2']) {
      final List<_Frame> before = views[s]!.sublist(0, startIndex[s]!);
      final List<_Frame> rooms = <_Frame>[
        for (final _Frame f in before)
          if (f.t == 'room') f,
      ];
      if (rooms.isEmpty) {
        problem('view $s', 'has no room snapshot before game_started');
        continue;
      }
      final _Frame snap = rooms.last;
      final Map<String, Object?> d = snap.d;
      if (s == '0') {
        chosen = d;
        info?.call(
          'game $name: chain_commit taken from view 0 frame ${snap.index} '
          '(room, chain_index ${_show(d['chain_index'])}, '
          '${rooms.length} room snapshot(s) before game_started)',
        );
      }
      if (d['state'] != 'LOBBY') {
        frameProblem(
            s,
            snap,
            'last room before game_started has state ${_show(d['state'])}, '
            'want LOBBY');
      }
      if (d['players'] != 2) {
        frameProblem(s, snap, 'players is ${_show(d['players'])}, want 2');
      }
      if (!deepEq(d['rules'], game['rules'])) {
        frameProblem(
            s,
            snap,
            'rules ${_show(d['rules'])} differ from the game\'s '
            '${_show(game['rules'])}');
      }
      final List<Object?> seatList = _asList(d['seats']) ?? <Object?>[];
      final Map<String, Object?> names = <String, Object?>{};
      for (final Object? e in seatList) {
        final Map<String, Object?>? m = _asMap(e);
        if (m != null) {
          names['${m['seat']}'] = m['name'];
        }
      }
      // A snapshot is the roster when it was sent. A seat that joins after
      // it arrives as a player_joined delta (section 5), a seat that leaves
      // as player_left, so the roster at game_started is the snapshot with
      // the deltas up to game_started applied.
      for (final _Frame f
          in views[s]!.sublist(snap.index + 1, startIndex[s]!)) {
        if (f.t == 'player_joined') {
          names['${f.d['seat']}'] = f.d['name'];
        } else if (f.t == 'player_left') {
          names.remove('${f.d['seat']}');
        }
      }
      if (!deepEq(names, game['names'])) {
        frameProblem(
            s,
            snap,
            'seat names ${_show(names)} (snapshot plus player_joined / '
            'player_left up to game_started) differ from the game\'s names '
            '${_show(game['names'])}');
      }
      final List<String> seated = names.keys.toList()..sort();
      if (!deepEq(seated, <String>['0', '2'])) {
        frameProblem(
            s,
            snap,
            'seated seats are ${_show(seated)}, '
            'want ["0","2"]');
      }
    }
    // Section 11.2: a chain_commit must not change for a chain_index.
    final Map<Object?, Object?> commitOf = <Object?, Object?>{};
    for (final String s in const <String>['0', '2']) {
      for (final _Frame f in views[s]!) {
        if (f.t != 'room') {
          continue;
        }
        final Object? idx = f.d['chain_index'];
        final Object? commit = f.d['chain_commit'];
        if (commitOf.containsKey(idx) && commitOf[idx] != commit) {
          frameProblem(
              s,
              f,
              'chain_commit ${_show(commit)} for chain_index ${_show(idx)} '
              'differs from ${_show(commitOf[idx])} seen earlier');
        }
        commitOf.putIfAbsent(idx, () => commit);
      }
    }
    return chosen;
  }

  // ------------------------------------------------------ 1. engine replay

  List<Object?> _lbfWire(engine.GameState s) => <Object?>[
        for (final MapEntry<int, List<int>> e in engine.legalByFace(s).entries)
          <String, Object?>{'face': e.key, 'tokens': e.value},
      ];

  static String _phaseWire(engine.GamePhase p) => switch (p) {
        engine.GamePhase.awaitRoll => 'await_roll',
        engine.GamePhase.awaitMove => 'await_move',
        engine.GamePhase.finished => 'finished',
      };

  static String _reasonWire(engine.TurnEndReason r) => switch (r) {
        engine.TurnEndReason.noLegalMove => 'no_legal_move',
        engine.TurnEndReason.threeSixes => 'three_sixes',
      };

  void _replayEngine() {
    final Map<String, Object?>? rules = _asMap(game['rules']);
    final List<Object?>? seatsRaw = _asList(game['seats']);
    if (rules == null || seatsRaw == null) {
      problem('replay', 'rules or seats missing, engine replay skipped');
      return;
    }
    final Object? cb = rules['capture_bonus'];
    if (cb is! bool) {
      problem('rules',
          'capture_bonus is ${_show(cb)}, not a bool; engine replay skipped');
      return;
    }
    final List<int> seats = <int>[
      for (final Object? s in seatsRaw)
        if (s is int) s,
    ];
    // Built the way the server builds it, packages/ludo_server/lib/src/
    // registry.dart lines 852-867: seats ascending, blocks false, captureBonus
    // from the room rules, rollQueue true, homeBonus true. The seed is not
    // read by the engine (rule 38, game_config.dart).
    final engine.GameConfig config = engine.GameConfig(
      seats: seats,
      rules: engine.RulesConfig(
        blocks: false,
        captureBonus: cb,
        rollQueue: true,
        homeBonus: true,
      ),
      seed: 0,
    );
    var state = engine.newGame(config);
    final List<_Frame> frames = views['0']!;
    final int start = startIndex['0']!;
    final int end = endIndex['0']!;
    final _Frame started = frames[start];

    if (started.d['turn'] != state.currentSeat) {
      frameProblem(
          '0',
          started,
          'turn is ${_show(started.d['turn'])}, engine opens on seat '
              '${state.currentSeat}');
    }
    if (_asStr(started.d['game_id']) != game['game_id']) {
      frameProblem(
          '0',
          started,
          'game_id ${_show(started.d['game_id'])} differs from the game\'s '
              '${_show(game['game_id'])}');
    }

    List<String> expected = <String>['turn'];
    List<engine.GameEvent> last = <engine.GameEvent>[];
    var wantK = 1;
    var reachedOver = false;

    for (var i = start + 1; i <= end; i++) {
      final _Frame f = frames[i];
      final String t = f.t;
      final Map<String, Object?> d = f.d;
      if (_ignorableInGame.contains(t)) {
        continue;
      }
      if (t == 'rolled' || t == 'moved') {
        if (expected.isNotEmpty) {
          frameProblem('0', f,
              'came while the previous step still owed ${expected.join(', ')}');
          expected = <String>[];
        }
      } else if (t == 'turn' || t == 'turn_passed' || t == 'game_over') {
        if (expected.isEmpty) {
          frameProblem(
              '0', f, 'the engine owes no $t after the previous frame');
        } else if (expected.first != t) {
          frameProblem(
              '0', f, 'frame order: engine owes ${expected.join(', ')} here');
          final int at = expected.indexOf(t);
          expected = at < 0 ? expected : expected.sublist(at + 1);
        } else {
          expected = expected.sublist(1);
        }
      } else {
        frameProblem('0', f, 'frame type $t does not belong inside a game');
        continue;
      }

      switch (t) {
        case 'rolled':
          final int? seat = _asInt(d['seat']);
          final int? value = _asInt(d['value']);
          if (seat == null || value == null || value < 1 || value > 6) {
            frameProblem(
                '0',
                f,
                'seat ${_show(d['seat'])} / value ${_show(d['value'])} is not '
                    'a seat and a face 1..6; replay stopped');
            return;
          }
          if (seat != state.currentSeat) {
            frameProblem(
                '0',
                f,
                'rolled by seat $seat, engine has seat ${state.currentSeat} on '
                    'turn');
          }
          final engine.ApplyResult r =
              engine.apply(state, engine.RollIntention(seat, value));
          if (r is! engine.Applied) {
            frameProblem(
                '0',
                f,
                'engine rejects roll of $value by seat $seat '
                    '(${(r as engine.Rejected).error.name}); replay stopped');
            return;
          }
          state = r.state;
          last = r.events;
          final engine.Rolled ev = r.events.whereType<engine.Rolled>().single;
          if (!deepEq(d['legal'], ev.legal)) {
            frameProblem(
                '0',
                f,
                'legal is ${_show(d['legal'])}, engine offers '
                    '${_show(ev.legal)}');
          }
          if (!deepEq(d['queue'], state.queue)) {
            frameProblem(
                '0',
                f,
                'queue is ${_show(d['queue'])}, engine holds '
                    '${_show(state.queue)}');
          }
          final Object? wantLbf = state.phase == engine.GamePhase.awaitMove
              ? _lbfWire(state)
              : null;
          if (!deepEq(d['legal_by_face'], wantLbf)) {
            frameProblem(
                '0',
                f,
                'legal_by_face is ${_show(d['legal_by_face'])}, engine offers '
                    '${_show(wantLbf)}');
          }
          if (d['k'] != wantK) {
            frameProblem('0', f, 'k is ${_show(d['k'])}, want $wantK');
          }
          wantK++;
          if (state.phase == engine.GamePhase.awaitMove &&
              state.queue.length >= 2 &&
              state.queue.any(
                  (int face) => !engine.legalByFace(state).containsKey(face))) {
            deadFaceFrames.add(i);
          }
          expected = r.events.any((engine.GameEvent e) => e is engine.TurnEnded)
              ? <String>['turn_passed', 'turn']
              : r.events.any((engine.GameEvent e) => e is engine.ExtraRoll)
                  ? <String>['turn']
                  : <String>[];
        case 'moved':
          final int? seat = _asInt(d['seat']);
          final int? token = _asInt(d['token']);
          final int? face = _asInt(d['face']);
          if (seat == null || token == null || face == null) {
            frameProblem('0', f,
                'seat/token/face missing or not integers; replay stopped');
            return;
          }
          if (seat != state.currentSeat) {
            frameProblem(
                '0',
                f,
                'moved by seat $seat, engine has seat ${state.currentSeat} on '
                    'turn');
          }
          final engine.ApplyResult r = engine.apply(
              state, engine.MoveIntention(seat, token, face: face));
          if (r is! engine.Applied) {
            frameProblem(
                '0',
                f,
                'engine rejects move of token $token with face $face by seat '
                    '$seat (${(r as engine.Rejected).error.name}); replay stopped');
            return;
          }
          state = r.state;
          last = r.events;
          final engine.Moved mv = r.events.whereType<engine.Moved>().single;
          if (d['from'] != mv.from || d['to'] != mv.to) {
            frameProblem(
                '0',
                f,
                'from/to is ${_show(d['from'])}->${_show(d['to'])}, engine '
                    'moves ${mv.from}->${mv.to}');
          }
          final List<Object?> wantCaptured = <Object?>[
            for (final engine.Captured c
                in r.events.whereType<engine.Captured>())
              <String, Object?>{'seat': c.seat, 'token': c.token},
          ];
          if (!deepEq(d['captured'], wantCaptured)) {
            frameProblem(
                '0',
                f,
                'captured is ${_show(d['captured'])}, engine captured '
                    '${_show(wantCaptured)}');
          }
          final bool wantExtra =
              r.events.any((engine.GameEvent e) => e is engine.ExtraRoll);
          if (d['extra_roll'] != wantExtra) {
            frameProblem(
                '0',
                f,
                'extra_roll is ${_show(d['extra_roll'])}, engine says '
                    '$wantExtra');
          }
          expected = r.events.any((engine.GameEvent e) => e is engine.GameWon)
              ? <String>['game_over']
              : r.events.any((engine.GameEvent e) => e is engine.TurnEnded)
                  ? <String>['turn_passed', 'turn']
                  : <String>['turn'];
        case 'turn_passed':
          final Iterable<engine.TurnEnded> ended =
              last.whereType<engine.TurnEnded>();
          if (ended.isEmpty) {
            frameProblem('0', f, 'the engine ended no turn at this step');
            break;
          }
          final engine.TurnEnded te = ended.first;
          if (d['reason'] != _reasonWire(te.reason)) {
            frameProblem(
                '0',
                f,
                'reason is ${_show(d['reason'])}, engine ended the turn for '
                    '${_reasonWire(te.reason)}');
          }
          if (d['seat'] != te.seat) {
            frameProblem(
                '0',
                f,
                'seat is ${_show(d['seat'])}, engine ended seat ${te.seat}\'s '
                    'turn');
          }
        case 'turn':
          _checkTurnFrame(f, state);
        case 'game_over':
          reachedOver = true;
          final Iterable<engine.GameWon> won = last.whereType<engine.GameWon>();
          if (won.isEmpty) {
            frameProblem('0', f, 'the engine reported no winner at this step');
          } else if (d['winner'] != won.first.seat) {
            frameProblem(
                '0',
                f,
                'winner is ${_show(d['winner'])}, engine says seat '
                    '${won.first.seat}');
          }
          if (!engine.isTerminal(state)) {
            frameProblem('0', f, 'engine state is not finished');
          }
      }
    }

    if (!reachedOver) {
      problem('replay', 'ended without reaching game_over');
      return;
    }
    if (state.winner != game['winner']) {
      problem(
          'winner',
          'file says ${_show(game['winner'])}, engine replay says '
              '${state.winner}');
    }
    final Map<String, Object?> finalTokens = <String, Object?>{
      for (final int s in seats) '$s': state.tokens[s],
    };
    if (!deepEq(game['final_tokens'], finalTokens)) {
      problem(
          'final_tokens',
          'file says ${_show(game['final_tokens'])}, engine replay ends at '
              '${_show(finalTokens)}');
    }
  }

  void _checkTurnFrame(_Frame f, engine.GameState state) {
    final Map<String, Object?> d = f.d;
    if (d['seat'] != state.currentSeat) {
      frameProblem(
          '0',
          f,
          'seat is ${_show(d['seat'])}, engine has seat ${state.currentSeat} '
              'on turn');
    }
    // docs/PROTOCOL.md section 21.3 rule 1.
    if (d['phase'] != _phaseWire(state.phase)) {
      frameProblem(
          '0',
          f,
          'phase is ${_show(d['phase'])}, engine is in '
              '${_phaseWire(state.phase)}');
    }
    if (!deepEq(d['queue'], state.queue)) {
      frameProblem('0', f,
          'queue is ${_show(d['queue'])}, engine holds ${_show(state.queue)}');
    }
    if (state.phase == engine.GamePhase.awaitMove) {
      if (d['value'] != engine.defaultFace(state)) {
        frameProblem(
            '0',
            f,
            'value is ${_show(d['value'])}, engine default face is '
                '${engine.defaultFace(state)}');
      }
      if (!deepEq(d['legal'], engine.legalTokens(state))) {
        frameProblem(
            '0',
            f,
            'legal is ${_show(d['legal'])}, engine offers '
                '${_show(engine.legalTokens(state))}');
      }
      if (!deepEq(d['legal_by_face'], _lbfWire(state))) {
        frameProblem(
            '0',
            f,
            'legal_by_face is ${_show(d['legal_by_face'])}, engine offers '
                '${_show(_lbfWire(state))}');
      }
    }
    final int? deadline = _asInt(d['deadline_ms']);
    final int? turnSeconds = _asInt(_asMap(game['rules'])?['turn_seconds']);
    if (deadline == null ||
        deadline < 0 ||
        (turnSeconds != null && deadline > turnSeconds * 1000)) {
      frameProblem(
          '0',
          f,
          'deadline_ms ${_show(d['deadline_ms'])} is not within '
              '0..${turnSeconds == null ? '?' : turnSeconds * 1000}');
    }
  }

  // ------------------------------------------------------ 2. views agree

  Map<String, Object?> _norm(_Frame f) => Map<String, Object?>.of(f.map)
    ..remove('id')
    ..remove('re');

  void _checkViewsAgree() {
    final List<_Frame> a = _range('0').where((f) => !f.unicast).toList();
    final List<_Frame> b = _range('2').where((f) => !f.unicast).toList();
    if (a.length != b.length) {
      problem(
          'views',
          'view 0 has ${a.length} broadcast frames from game_started to '
              'game_over, view 2 has ${b.length}');
    }
    var reported = 0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (deepEq(_norm(a[i]), _norm(b[i]))) {
        continue;
      }
      if (reported == 5) {
        problem('views', 'further differences between the views not listed');
        break;
      }
      reported++;
      final Map<String, Object?> na = _norm(a[i]);
      final Map<String, Object?> nb = _norm(b[i]);
      final Set<String> keys = <String>{...na.keys, ...nb.keys};
      final Set<String> dkeys = <String>{
        ...?_asMap(na['d'])?.keys,
        ...?_asMap(nb['d'])?.keys,
      };
      final List<String> diffs = <String>[
        for (final String k in keys)
          if (k != 'd' && !deepEq(na[k], nb[k])) k,
        for (final String k in dkeys)
          if (!deepEq(_asMap(na['d'])?[k], _asMap(nb['d'])?[k])) 'd.$k',
      ];
      problem(
        'view 2 frame ${b[i].index} (${b[i].t})',
        'differs from view 0 frame ${a[i].index} (${a[i].t}) in '
            '${diffs.join(', ')}: view 2 ${_show(nb)} vs view 0 ${_show(na)}',
      );
    }
  }

  // ---------------------------------------------------------------- 3. seq

  /// docs/PROTOCOL.md section 5 ("Carrying `seq`") names the types that carry
  /// it, and section 12.3 says the counter "advances by exactly one per
  /// frame"; section 6 makes a delta whose `seq` is not the client's own plus
  /// one a gap.
  void _checkSeq() {
    for (final String s in const <String>['0', '2']) {
      int? prev;
      for (final _Frame f in _range(s)) {
        if (!_seqCarrying.contains(f.t) || f.unicast) {
          continue;
        }
        final int? seq = _asInt(f.d['seq']);
        if (seq == null) {
          frameProblem(
              s, f, 'carries no integer seq, found ${_show(f.d['seq'])}');
          continue;
        }
        if (prev != null && seq != prev + 1) {
          frameProblem(s, f, 'seq is $seq after $prev, want ${prev + 1}');
        }
        prev = seq;
      }
    }
  }

  // --------------------------------------------------------------- 4. dice

  void _checkDice(Map<String, Object?>? snapshot) {
    final List<_Frame> frames = views['0']!;
    final _Frame started = frames[startIndex['0']!];
    final String? gameId = _asStr(started.d['game_id']);
    final String? clientSeeds = _asStr(started.d['client_seeds']);
    final String? commit = _asStr(snapshot?['chain_commit']);
    if (gameId == null || clientSeeds == null) {
      frameProblem('0', started, 'game_id or client_seeds missing');
      return;
    }
    if (commit == null || !_hex64.hasMatch(commit)) {
      problem('chain_commit',
          'the last room before game_started has no 64-hex chain_commit');
      return;
    }
    // section 11.2: client_seeds is seats ascending, "seat:seed" joined by |,
    // and each seed was broadcast in a seat_seed frame.
    final Map<int, String> seeds = <int, String>{};
    for (final _Frame f in frames.sublist(0, startIndex['0']!)) {
      if (f.t == 'seat_seed') {
        final int? seat = _asInt(f.d['seat']);
        final String? seed = _asStr(f.d['client_seed']);
        if (seat != null && seed != null) {
          seeds[seat] = seed;
        }
      }
    }
    final List<int> order = seeds.keys.toList()..sort();
    final String joined = order.map((int s) => '$s:${seeds[s]}').join('|');
    if (joined != clientSeeds) {
      frameProblem(
          '0',
          started,
          'client_seeds ${_show(clientSeeds)} is not what the seat_seed frames '
              'give: ${_show(joined)}');
    }
    for (final _Frame f in _range('0')) {
      if (f.t != 'rolled') {
        continue;
      }
      final Map<String, Object?> d = f.d;
      final int? k = _asInt(d['k']);
      final String? reveal = _asStr(d['reveal']);
      final int? value = _asInt(d['value']);
      if (k == null || k < 1 || k > 4096) {
        frameProblem('0', f, 'k ${_show(d['k'])} is not within 1..4096');
        continue;
      }
      if (reveal == null || !_hex64.hasMatch(reveal)) {
        frameProblem('0', f,
            'reveal ${_show(d['reveal'])} is not 64 lowercase hex characters');
        continue;
      }
      final int face = drawDie(reveal, gameId, clientSeeds, k, 0);
      if (value != face) {
        frameProblem(
            '0',
            f,
            'value is ${_show(value)}, fair_dice derives $face from reveal '
                '$reveal, game_id $gameId, client_seeds ${_show(clientSeeds)}, '
                'k $k');
      }
      // section 11.2: s[k-1] = SHA-256(s[k]), so k hashes reach s[0], which is
      // the chain_commit.
      List<int> link = hexDecode(reveal);
      for (var n = 0; n < k; n++) {
        link = sha256.convert(link).bytes;
      }
      if (hexEncode(link) != commit) {
        frameProblem(
            '0',
            f,
            'reveal does not hash $k times to chain_commit $commit '
                '(got ${hexEncode(link)})');
      }
    }
  }

  // ------------------------------------------------------------- 5. counts

  void _checkCounts() {
    final Map<String, Object?>? counts = _asMap(game['counts']);
    final Map<String, Object?>? finalTokens = _asMap(game['final_tokens']);
    if (counts == null || finalTokens == null) {
      problem('counts', 'counts or final_tokens missing');
      return;
    }
    const List<String> keys = <String>[
      'rolls',
      'sixes',
      'captures_made',
      'times_captured',
      'home',
    ];
    for (final String s in const <String>['0', '2']) {
      final int seat = int.parse(s);
      final Map<String, int> want = <String, int>{for (final k in keys) k: 0};
      for (final _Frame f in _range('0')) {
        final Map<String, Object?> d = f.d;
        if (f.t == 'rolled' && d['seat'] == seat) {
          want['rolls'] = want['rolls']! + 1;
          if (d['value'] == 6) {
            want['sixes'] = want['sixes']! + 1;
          }
        } else if (f.t == 'moved') {
          for (final Object? c in _asList(d['captured']) ?? <Object?>[]) {
            final Map<String, Object?>? cm = _asMap(c);
            if (d['seat'] == seat) {
              want['captures_made'] = want['captures_made']! + 1;
            }
            if (cm != null && cm['seat'] == seat) {
              want['times_captured'] = want['times_captured']! + 1;
            }
          }
        }
      }
      final List<Object?> tokens = _asList(finalTokens[s]) ?? <Object?>[];
      want['home'] = tokens.where((Object? p) => p == 57).length;
      final Map<String, Object?>? have = _asMap(counts[s]);
      if (have == null) {
        problem('counts seat $s', 'missing');
        continue;
      }
      for (final String k in keys) {
        if (have[k] is! int || have[k] != want[k]) {
          problem(
              'counts seat $s key $k',
              'file says ${_show(have[k])}, recomputed ${want[k]} from view 0 '
                  'and final_tokens');
        }
      }
      for (final String k in have.keys) {
        if (!keys.contains(k)) {
          problem('counts seat $s key $k', 'unknown key');
        }
      }
    }
  }

  // ------------------------------------------------------------ 6. events

  void _checkEvents() {
    final List<Object?>? events = _asList(game['events']);
    if (events == null) {
      problem('events', 'missing or not a list');
      return;
    }
    const Set<String> kinds = <String>{
      'capture',
      'three_sixes',
      'no_legal_move',
      'dead_face',
    };
    for (var n = 0; n < events.length; n++) {
      final Map<String, Object?>? ev = _asMap(events[n]);
      if (ev == null) {
        problem('events[$n]', 'not an object');
        continue;
      }
      final String kind = _asStr(ev['kind']) ?? '?';
      if (!kinds.contains(kind)) {
        problem('events[$n]', 'unknown kind ${_show(ev['kind'])}');
        continue;
      }
      final Map<String, Object?>? vi = _asMap(ev['view_index']);
      if (vi == null) {
        problem('events[$n] kind $kind', 'view_index missing');
        continue;
      }
      final Map<String, _Frame> pointed = <String, _Frame>{};
      for (final String s in const <String>['0', '2']) {
        final int? idx = _asInt(vi[s]);
        final List<_Frame> frames = views[s]!;
        if (idx == null || idx < startIndex[s]! || idx > endIndex[s]!) {
          problem(
              'events[$n] kind $kind view $s frame ${_show(vi[s])}',
              'index is not inside the game '
                  '(${startIndex[s]}..${endIndex[s]})');
          continue;
        }
        final _Frame f = frames[idx];
        pointed[s] = f;
        final String where = 'events[$n] kind $kind view $s frame $idx '
            '(${f.t})';
        switch (kind) {
          case 'capture':
            final Object? by = ev['by'];
            final Object? victim = ev['victim'];
            final bool hit = f.t == 'moved' &&
                f.d['seat'] == by &&
                (_asList(f.d['captured']) ?? <Object?>[])
                    .any((Object? c) => _asMap(c)?['seat'] == victim);
            if (!hit) {
              problem(
                  where,
                  'is not a moved by seat ${_show(by)} capturing a token of '
                  'seat ${_show(victim)}');
            }
          case 'three_sixes' || 'no_legal_move':
            if (f.t != 'turn_passed' ||
                f.d['reason'] != kind ||
                f.d['seat'] != ev['seat']) {
              problem(
                  where,
                  'is not a turn_passed of seat ${_show(ev['seat'])} with '
                  'reason $kind');
            }
          case 'dead_face':
            final bool engineSaysDead =
                s == '0' ? deadFaceFrames.contains(idx) : true;
            final bool shapeOk = f.t == 'rolled' && f.d['seat'] == ev['seat'];
            if (!shapeOk) {
              problem(where, 'is not a rolled by seat ${_show(ev['seat'])}');
            } else if (!engineSaysDead) {
              problem(
                  where,
                  'rolled leaves a queue ${_show(f.d['queue'])} with legal '
                  'faces ${_show(f.d['legal_by_face'])}; the engine sees no '
                  'dead face among two or more queued faces');
            }
        }
      }
      if (pointed.length == 2) {
        final int? s0 = _asInt(pointed['0']!.d['seq']);
        final int? s2 = _asInt(pointed['2']!.d['seq']);
        if (s0 != s2) {
          problem(
              'events[$n] kind $kind',
              'view 0 frame ${pointed['0']!.index} has seq $s0 but view 2 '
                  'frame ${pointed['2']!.index} has seq $s2: not the same frame');
        }
      }
    }
  }

  // --------------------------------------------------------- game_log extra

  /// docs/PROTOCOL.md section 17 rule 2: read in part order the `frames`
  /// lists are every push of the game, each as `{t, d}`, `re` never.
  void _checkGameLog() {
    final List<Object?>? parts = _asList(game['game_log']);
    if (parts == null) {
      problem('game_log', 'missing or not a list');
      return;
    }
    final List<Object?> logged = <Object?>[];
    for (var p = 0; p < parts.length; p++) {
      final Map<String, Object?>? env = _asMap(parts[p]);
      final Map<String, Object?>? d = _asMap(env?['d']);
      if (env == null || env['t'] != 'game_log' || d == null) {
        problem('game_log part ${p + 1}', 'is not a game_log frame');
        continue;
      }
      if (d['part'] != p + 1 || d['parts'] != parts.length) {
        problem(
            'game_log part ${p + 1}',
            'says part ${_show(d['part'])} of ${_show(d['parts'])}, want '
                '${p + 1} of ${parts.length}');
      }
      if (d['game_id'] != game['game_id']) {
        problem('game_log part ${p + 1}',
            'game_id ${_show(d['game_id'])} differs from the game\'s');
      }
      logged.addAll(_asList(d['frames']) ?? <Object?>[]);
    }
    final List<_Frame> want =
        _range('0').where((f) => !f.unicast && f.t != 'emote').toList();
    if (logged.length != want.length) {
      problem(
          'game_log',
          'holds ${logged.length} frames, view 0 has ${want.length} from '
              'game_started to game_over');
    }
    for (var i = 0; i < logged.length && i < want.length; i++) {
      final Map<String, Object?> expect = <String, Object?>{
        't': want[i].map['t'],
        'd': want[i].map['d'],
      };
      if (!deepEq(logged[i], expect)) {
        problem(
            'game_log entry $i vs view 0 frame ${want[i].index} '
                '(${want[i].t})',
            'logged ${_show(logged[i])}, view has ${_show(expect)}');
        break;
      }
    }
  }

  // ---------------------------------------------------------------- cover

  void _gatherCoverage() {
    final Object? winner = game['winner'];
    if (winner == 0) {
      coverage.hostWin = true;
    }
    if (winner == 2) {
      coverage.guestWin = true;
    }
    for (final _Frame f in _range('0')) {
      if (f.t == 'moved' &&
          (_asList(f.d['captured']) ?? <Object?>[]).isNotEmpty) {
        final int? by = _asInt(f.d['seat']);
        if (by != null) {
          coverage.captureBy.add(by);
        }
      } else if (f.t == 'turn_passed') {
        if (f.d['reason'] == 'three_sixes') {
          coverage.threeSixes = true;
        } else if (f.d['reason'] == 'no_legal_move') {
          coverage.noLegalMove = true;
        }
      }
    }
  }
}
