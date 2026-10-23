// A resume across a rematch (C-445, order 445), written from the contract:
// docs/PROTOCOL.md sections 8, 16 and 17 and work/ludo/orders/
// C-445-resume-across-a-rematch.md, decisions D1 to D3.
//
// The story: two friends finish game A. This phone drops while the end card
// is up, its friends start a rematch, and the phone comes back through
// `resume` into a PLAYING snapshot of game B. It never saw B's
// `game_started` (section 8 rule 4 replays nothing). The record it keeps
// for the end card's numbers must then be B's, or empty, never A's with B
// stacked behind it.
//
// Seating is section 15's canonical set for two players, [0, 2]. This
// device is seat 0 (the host) and loses both games to seat 2, so the card
// is the loser's, which shows the four honest tiles (doctrine P6).
//
// Two groups. The controller group is a RoomController over FakeTransport,
// the rig of test/game_transcript_test.dart. The screen group mounts
// GameScreen on the same controller, the rig of
// test/finished_card_survives_rematch_test.dart and
// test/end_card_game_log_test.dart. Every frame is one the server could
// send: seqs run without a hole, the resume answer is a full snapshot at the
// seq of the last frame it stands for, and the game_log answer is the
// section 17 reading of the same frames.
//
// Hand counts for this device (seat 0), from the scripts below and not from
// computeGameStats:
//   game A: rolled 6, 6, 6, 2   rolls 4, sixes 3
//           two moves each with one captured entry   captures 2
//           final tokens [57, 57, 20, 5]             home 2
//   game B: rolled 6, 4, 3, 2, 5   rolls 5, sixes 1
//           no captured entry                        captures 0
//           final tokens [57, 57, 57, 48]            home 3
// Every tile differs between the two games, so a tile that shows A's number
// on B's card cannot be mistaken for B's own.
//
// Every failure message names its case tag, what was expected, what was
// seen, and the command that reproduces it. The scripts are fixed, so
// there is no seed.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://resume-across-rematch.invalid/ws';
const String _code = 'K7M2QP';

// 16 lowercase hex characters, PROTOCOL section 11.
const String _gameA = 'a1a1a1a1a1a1a1a1';
const String _gameB = 'b2b2b2b2b2b2b2b2';
const String _gameC = 'c3c3c3c3c3c3c3c3';

const String _meName = 'Sam';
const String _otherName = 'Bob';
const int _me = 0;
const int _other = 2;

// Hand counts, see the header.
const int _aRolls = 4;
const int _aSixes = 3;
const int _aCaptures = 2;
const int _aHome = 2;
const int _bRolls = 5;
const int _bSixes = 1;
const int _bCaptures = 0;
const int _bHome = 3;

const Key _rollsKey = Key('end-card-stat-rolls');
const Key _sixesKey = Key('end-card-stat-sixes');
const Key _capturesKey = Key('end-card-stat-captures');
const Key _homeKey = Key('end-card-stat-home');
const Key _loseKey = Key('end-card-lose');
const Key _offlineKey = Key('end-card-offline');

/// Long enough for a post-frame game_log to have been sent, and short of
/// RoomConnection's 10 s request timeout.
const Duration _fewSeconds = Duration(seconds: 3);

int _serverIdSeq = 0;

String _nextServerId() {
  _serverIdSeq += 1;
  return 'c445-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

/// One push as the server broadcasts it, and as a section 17 log holds it:
/// the type and the data, `seq` inside the data.
typedef _Entry = ({String t, Map<String, Object?> d});

int _seqOf(_Entry entry) => entry.d['seq']! as int;

/// A scripted game. Seqs run on from [firstSeq] with no hole.
class _Script {
  _Script(this.gameId, int firstSeq) : _seq = firstSeq - 1;

  final String gameId;
  final List<_Entry> entries = <_Entry>[];
  int _seq;
  int _k = 0;

  int get lastSeq => _seq;

  void _add(String type, Map<String, Object?> data) {
    _seq += 1;
    entries.add((t: type, d: <String, Object?>{...data, 'seq': _seq}));
  }

  void started({required int turnSeat}) =>
      _add('game_started', <String, Object?>{
        'turn': turnSeat,
        'game_id': gameId,
        'client_seeds': '0:sam-seed|2:bob-seed',
      });

  void turn(int seat) =>
      _add('turn', <String, Object?>{'seat': seat, 'deadline_ms': 45000});

  void rolled(int seat, int value) {
    _k += 1;
    _add('rolled', <String, Object?>{
      'seat': seat,
      'value': value,
      'legal': const <int>[0, 1, 2, 3],
      'deadline_ms': 45000,
      'k': _k,
      'reveal': 'a' * 64,
    });
  }

  void moved(
    int seat,
    int token,
    int from,
    int to, {
    List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  }) => _add('moved', <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': false,
  });

  void over(int winner) => _add('game_over', <String, Object?>{
    'winner': winner,
    'verify_url': 'https://resume-across-rematch.invalid/v/$gameId',
  });
}

/// Game A: seat 0 rolls 6, 6, 6, 2 and captures twice; seat 2 wins.
/// Index 0 game_started, 1 turn, 2 rolled, 3 moved, 4 rolled, 5 moved,
/// 6 rolled, 7 moved, ...
_Script _scriptA() {
  final _Script s = _Script(_gameA, 2);
  s.started(turnSeat: _me);
  s.turn(_me);
  s.rolled(_me, 6);
  s.moved(
    _me,
    0,
    -1,
    57,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': _other, 'token': 0},
    ],
  );
  s.rolled(_other, 3);
  s.moved(_other, 0, -1, 57);
  s.rolled(_me, 6);
  s.moved(
    _me,
    1,
    -1,
    57,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': _other, 'token': 1},
    ],
  );
  s.rolled(_other, 4);
  s.moved(_other, 1, -1, 57);
  s.rolled(_me, 6);
  s.moved(_me, 2, -1, 20);
  s.rolled(_other, 5);
  s.moved(_other, 2, -1, 57);
  s.rolled(_me, 2);
  s.moved(_me, 3, -1, 5);
  s.rolled(_other, 6);
  s.moved(_other, 3, -1, 57);
  s.over(_other);
  return s;
}

/// A second (or third) game: seat 0 rolls 6, 4, 3, 2, 5, never captures and
/// ends on [57, 57, 57, 48]; seat 2 wins. Index 0 game_started, 1 turn,
/// 2 rolled, 3 moved, 4 rolled, 5 moved, ...
_Script _scriptB(String gameId, int firstSeq) {
  final _Script s = _Script(gameId, firstSeq);
  s.started(turnSeat: _me);
  s.turn(_me);
  s.rolled(_me, 6);
  s.moved(_me, 0, -1, 57);
  s.rolled(_other, 2);
  s.moved(_other, 0, -1, 57);
  s.rolled(_me, 4);
  s.moved(_me, 1, -1, 57);
  s.rolled(_other, 5);
  s.moved(_other, 1, -1, 57);
  s.rolled(_me, 3);
  s.moved(_me, 2, -1, 57);
  s.rolled(_other, 4);
  s.moved(_other, 2, -1, 57);
  s.rolled(_me, 2);
  s.moved(_me, 3, -1, 10);
  s.rolled(_me, 5);
  s.moved(_me, 3, 10, 48);
  s.rolled(_other, 3);
  s.moved(_other, 3, -1, 57);
  s.over(_other);
  return s;
}

/// Token positions of [seat] after the first [count] entries of [entries]:
/// a fixture fold of the moved frames, so a snapshot stands for exactly the
/// frames before it.
List<int> _tokensAfter(List<_Entry> entries, int count, int seat) {
  final List<int> tokens = <int>[-1, -1, -1, -1];
  for (final _Entry entry in entries.take(count)) {
    if (entry.t != 'moved') {
      continue;
    }
    if (entry.d['seat'] == seat) {
      tokens[entry.d['token']! as int] = entry.d['to']! as int;
    }
    for (final Object? hit in entry.d['captured']! as List<Object?>) {
      final Map<String, Object?> cap = hit! as Map<String, Object?>;
      if (cap['seat'] == seat) {
        tokens[cap['token']! as int] = -1;
      }
    }
  }
  return tokens;
}

Map<String, Object?> _seatJson(int seat, String name, List<int> tokens) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': tokens,
      'client_seed': null,
      'seed_origin': null,
    };

/// A room snapshot standing for the first [count] entries of [script].
/// [chainIndex] is the game's index in the room (0 for A, 1 for B).
Map<String, Object?> _roomOf(
  _Script script,
  int count, {
  required String state,
  required int chainIndex,
  int? winner,
}) {
  final List<_Entry> shown = script.entries;
  final bool finished = state == 'FINISHED';
  return <String, Object?>{
    'code': _code,
    'state': state,
    'host_seat': _me,
    'players': 2,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
    },
    'chain_commit': 'abc'[chainIndex] * 64,
    'chain_index': chainIndex,
    'game_id': script.gameId,
    'client_seeds': '0:sam-seed|2:bob-seed',
    'seats': <Map<String, Object?>>[
      _seatJson(_me, _meName, _tokensAfter(shown, count, _me)),
      _seatJson(_other, _otherName, _tokensAfter(shown, count, _other)),
    ],
    'turn': <String, Object?>{
      'seat': _me,
      'phase': finished ? 'finished' : 'await_roll',
      'deadline_ms': finished ? 0 : 45000,
      'k': 0,
    },
    'winner': finished ? winner : null,
    'rematch': null,
    if (finished)
      'verify_url': 'https://resume-across-rematch.invalid/v/${script.gameId}',
    'seq': _seqOf(shown[count - 1]),
  };
}

/// Section 16.2's first rematch: LOBBY, game_id null, a new chain,
/// rematch {by, ready: [by]}.
Map<String, Object?> _rematchLobby({required int seq, required int by}) =>
    <String, Object?>{
      'code': _code,
      'state': 'LOBBY',
      'host_seat': _me,
      'players': 2,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': 'b' * 64,
      'chain_index': 1,
      'game_id': null,
      'client_seeds': null,
      'seats': <Map<String, Object?>>[
        _seatJson(_me, _meName, const <int>[-1, -1, -1, -1]),
        _seatJson(_other, _otherName, const <int>[-1, -1, -1, -1]),
      ],
      'turn': null,
      'winner': null,
      'rematch': <String, Object?>{
        'by': by,
        'ready': <int>[by],
      },
      'seq': seq,
    };

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: connect() has no transport queued');
    }
    return _queue.removeAt(0);
  }
}

/// How a case waits for a pushed frame to land: a plain event-queue pump in
/// the controller group, bounded widget pumps in the screen group. No
/// sleeps anywhere.
class _Env {
  _Env.plain() : tester = null;
  _Env.widget(WidgetTester this.tester);

  final WidgetTester? tester;

  Future<void> settle() async {
    final WidgetTester? t = tester;
    if (t == null) {
      await pumpEventQueue();
    } else {
      await t.pump();
      await t.pump();
    }
  }

  /// Lets the connection's own async work (connect, send) run.
  Future<void> io() async {
    final WidgetTester? t = tester;
    if (t == null) {
      await pumpEventQueue();
    } else {
      await t.runAsync(() => pumpEventQueue());
      await t.pump();
    }
  }
}

class _Rig {
  _Rig(this.controller, this.transport, this.connector);

  final RoomController controller;
  FakeTransport transport;
  final _Connector connector;
  final List<FakeTransport> transports = <FakeTransport>[];
  int seq = 1;
}

/// Seat 0 creates the two-player room. The room is at seq 1 in [state].
Future<_Rig> _open(_Env env, {required String state}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _Rig rig = _Rig(controller, transport, connector);
  rig.transports.add(transport);
  final Future<void> future = controller.createRoom(name: _meName, players: 2);
  await env.io();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': _me, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: <String, Object?>{
        'code': _code,
        'state': state,
        'host_seat': _me,
        'players': 2,
        'rules': <String, Object?>{
          'blocks': true,
          'capture_bonus': true,
          'turn_seconds': 45,
        },
        'chain_commit': 'a' * 64,
        'chain_index': 0,
        'game_id': null,
        'client_seeds': null,
        'seats': <Map<String, Object?>>[
          _seatJson(_me, _meName, const <int>[-1, -1, -1, -1]),
          _seatJson(_other, _otherName, const <int>[-1, -1, -1, -1]),
        ],
        'turn': null,
        'winner': null,
        'rematch': null,
        'seq': 1,
      },
    ),
  );
  await future;
  await env.settle();
  return rig;
}

/// One live push of [entry] on the current transport.
Future<void> _deliver(_Env env, _Rig rig, _Entry entry) async {
  rig.transport.pushText(_frame(type: entry.t, data: entry.d));
  rig.seq = _seqOf(entry);
  await env.settle();
}

Future<void> _deliverAll(_Env env, _Rig rig, Iterable<_Entry> entries) async {
  for (final _Entry entry in entries) {
    await _deliver(env, rig, entry);
  }
}

/// The socket dies from the far side, the controller reconnects on a fresh
/// transport, sends `resume` (section 8 rule 3) and the server answers with
/// [room] (rule 4). Returns the new transport.
Future<FakeTransport> _dropAndResume(
  _Env env,
  _Rig rig,
  Map<String, Object?> room,
) async {
  rig.transport.endFromFarSide();
  await env.settle();
  expect(
    rig.controller.phase,
    anyOf(RoomPhase.closed, RoomPhase.failed),
    reason: 'fixture: the far side ending must leave the controller offline',
  );
  final FakeTransport next = FakeTransport();
  rig.connector.enqueue(next);
  unawaited(rig.controller.reconnect());
  await env.io();
  expect(
    next.sentRaw.map(_typeOf),
    contains('resume'),
    reason: 'fixture: reconnect must send resume on the new transport',
  );
  final String resumeId = _idOf(
    next.sentRaw.where((String raw) => _typeOf(raw) == 'resume').last,
  );
  rig.transport = next;
  rig.transports.add(next);
  next.pushText(_frame(type: 'room', re: resumeId, data: room));
  rig.seq = room['seq']! as int;
  await env.settle();
  expect(
    rig.controller.phase,
    RoomPhase.connected,
    reason: 'fixture: the resume answer must leave the controller connected',
  );
  return next;
}

String _why(String tag, String expected, String got) =>
    '[$tag] expected: $expected. got: $got. reproduce: cd packages/ludo_client '
    '&& flutter test test/resume_across_rematch_test.dart '
    '--plain-name "$tag:" (fixed script, no seed).';

String _dump(RoomController controller) => controller.gameTranscript
    .map((Frame frame) {
      final Object? game = frame.data['game_id'];
      return '${frame.type}(seq ${frame.seq}${game == null ? '' : ', game $game'})';
    })
    .join(', ');

List<String> _types(RoomController controller) =>
    controller.gameTranscript.map((Frame frame) => frame.type).toList();

List<String> _typesOf(Iterable<_Entry> entries) =>
    entries.map((_Entry entry) => entry.t).toList();

/// Transcript frames that belong to a game that ended at [seq] or earlier:
/// anything at or below that seq, or naming one of [games].
List<Frame> _staleFrames(
  RoomController controller, {
  required int endedAtSeq,
  required Set<String> games,
}) => controller.gameTranscript.where((Frame frame) {
  final int? seq = frame.seq;
  return (seq != null && seq <= endedAtSeq) ||
      games.contains(frame.data['game_id']);
}).toList();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('controller: the transcript and lastFinished across a rematch', () {
    test('T1: game A live to game_over, drop, resume answer PLAYING game B '
        'then live B frames: the transcript holds no frame of game A and no '
        'game_started', () async {
      const String tag = 'T1';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      final _Script b = _scriptB(_gameB, a.lastSeq + 3);
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries);
        expect(
          rig.controller.room!.state,
          RoomState.finished,
          reason: 'fixture: game A must end FINISHED live',
        );
        expect(
          rig.controller.gameTranscript,
          hasLength(a.entries.length),
          reason:
              'fixture: all of game A was seen live; got ${_dump(rig.controller)}',
        );

        await _dropAndResume(
          env,
          rig,
          _roomOf(b, 2, state: 'PLAYING', chainIndex: 1),
        );
        await _deliverAll(env, rig, b.entries.skip(2).take(2));

        final List<Frame> stale = _staleFrames(
          rig.controller,
          endedAtSeq: a.lastSeq,
          games: <String>{_gameA},
        );
        expect(
          stale,
          isEmpty,
          reason: _why(
            tag,
            'no frame of game A (seq <= ${a.lastSeq} or game_id $_gameA) '
                'after the resume into game B',
            '${stale.length} such frames; transcript is ${_dump(rig.controller)}',
          ),
        );
        expect(
          _types(rig.controller),
          isNot(contains('game_started')),
          reason: _why(
            tag,
            'no game_started in the transcript (B\'s was never received)',
            _dump(rig.controller),
          ),
        );
        expect(
          _types(rig.controller),
          <String>['room', 'rolled', 'moved'],
          reason: _why(
            tag,
            'the resume answer and the two live B frames, nothing before',
            _dump(rig.controller),
          ),
        );
        expect(
          rig.controller.gameTranscript.first.data['game_id'],
          _gameB,
          reason: _why(
            tag,
            'the record opens at the room frame of game B',
            _dump(rig.controller),
          ),
        );
      } finally {
        rig.controller.dispose();
      }
    });

    test(
      'T2: control, a drop before game_over and the resume answer is '
      'PLAYING game A: the transcript keeps game_started and appends',
      () async {
        const String tag = 'T2';
        final _Env env = _Env.plain();
        final _Script a = _scriptA();
        final _Rig rig = await _open(env, state: 'LOBBY');
        try {
          await _deliverAll(env, rig, a.entries.take(4));
          await _dropAndResume(
            env,
            rig,
            _roomOf(a, 4, state: 'PLAYING', chainIndex: 0),
          );
          await _deliverAll(env, rig, a.entries.skip(4).take(2));

          expect(
            _types(rig.controller),
            <String>[..._typesOf(a.entries.take(4)), 'room', 'rolled', 'moved'],
            reason: _why(
              tag,
              'A\'s four frames, then the resume answer, then the two live '
              'frames; the same game appends',
              _dump(rig.controller),
            ),
          );
          expect(
            rig.controller.gameTranscript.first.data['game_id'],
            _gameA,
            reason: _why(
              tag,
              'the record still opens at game A\'s game_started',
              _dump(rig.controller),
            ),
          );
        } finally {
          rig.controller.dispose();
        }
      },
    );

    test('T2b: control, two drops inside game A: every resume answer of the '
        'same game appends and nothing is cleared', () async {
      const String tag = 'T2b';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries.take(4));
        await _dropAndResume(
          env,
          rig,
          _roomOf(a, 4, state: 'PLAYING', chainIndex: 0),
        );
        await _deliverAll(env, rig, a.entries.skip(4).take(2));
        await _dropAndResume(
          env,
          rig,
          _roomOf(a, 6, state: 'PLAYING', chainIndex: 0),
        );
        await _deliverAll(env, rig, a.entries.skip(6).take(1));

        expect(
          _types(rig.controller),
          <String>[
            ..._typesOf(a.entries.take(4)),
            'room',
            ..._typesOf(a.entries.skip(4).take(2)),
            'room',
            ..._typesOf(a.entries.skip(6).take(1)),
          ],
          reason: _why(
            tag,
            'both resume answers of game A appended in order',
            _dump(rig.controller),
          ),
        );
      } finally {
        rig.controller.dispose();
      }
    });

    test('T3: lastFinished is game A after A\'s game_over; a resume answer '
        'PLAYING game B clears it', () async {
      const String tag = 'T3';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      final _Script b = _scriptB(_gameB, a.lastSeq + 3);
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries);
        expect(
          rig.controller.lastFinished?.gameId,
          _gameA,
          reason: _why(
            tag,
            'fixture: lastFinished is game A after A\'s game_over',
            '${rig.controller.lastFinished?.gameId}',
          ),
        );

        await _dropAndResume(
          env,
          rig,
          _roomOf(b, 2, state: 'PLAYING', chainIndex: 1),
        );

        expect(rig.controller.room!.gameId, _gameB);
        expect(
          rig.controller.lastFinished,
          isNull,
          reason: _why(
            tag,
            'lastFinished cleared by a PLAYING room of game $_gameB, as a '
                'live game_started clears it',
            'lastFinished is game ${rig.controller.lastFinished?.gameId}',
          ),
        );
      } finally {
        rig.controller.dispose();
      }
    });

    test('E1: a resume answer FINISHED of game B: lastFinished is recorded '
        'as game B (D2 leaves a FINISHED frame as it is today)', () async {
      const String tag = 'E1';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      final _Script b = _scriptB(_gameB, a.lastSeq + 3);
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries);
        await _dropAndResume(
          env,
          rig,
          _roomOf(
            b,
            b.entries.length,
            state: 'FINISHED',
            chainIndex: 1,
            winner: _other,
          ),
        );

        expect(
          rig.controller.lastFinished?.gameId,
          _gameB,
          reason: _why(
            tag,
            'lastFinished is the FINISHED snapshot of game $_gameB',
            'lastFinished is ${rig.controller.lastFinished?.gameId}',
          ),
        );
      } finally {
        rig.controller.dispose();
      }
    });

    test('E2: a resume answer FINISHED of game B after game A: the '
        'transcript holds no frame of game A', () async {
      const String tag = 'E2';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      final _Script b = _scriptB(_gameB, a.lastSeq + 3);
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries);
        await _dropAndResume(
          env,
          rig,
          _roomOf(
            b,
            b.entries.length,
            state: 'FINISHED',
            chainIndex: 1,
            winner: _other,
          ),
        );

        final List<Frame> stale = _staleFrames(
          rig.controller,
          endedAtSeq: a.lastSeq,
          games: <String>{_gameA},
        );
        expect(
          stale,
          isEmpty,
          reason: _why(
            tag,
            'no frame of game A once the room is a FINISHED game B',
            '${stale.length} such frames; transcript is ${_dump(rig.controller)}',
          ),
        );
        expect(
          _types(rig.controller),
          <String>['room'],
          reason: _why(
            tag,
            'only the resume answer itself',
            _dump(rig.controller),
          ),
        );
      } finally {
        rig.controller.dispose();
      }
    });

    test('E3: two rematches across two drops (A, then B, then C): the '
        'transcript holds game C\'s frames only', () async {
      const String tag = 'E3';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      final _Script b = _scriptB(_gameB, a.lastSeq + 3);
      final _Script c = _scriptB(_gameC, b.lastSeq + 3);
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries);
        await _dropAndResume(
          env,
          rig,
          _roomOf(b, 2, state: 'PLAYING', chainIndex: 1),
        );
        await _deliverAll(env, rig, b.entries.skip(2));
        expect(
          rig.controller.room!.state,
          RoomState.finished,
          reason: 'fixture: game B must end FINISHED live',
        );

        await _dropAndResume(
          env,
          rig,
          _roomOf(c, 2, state: 'PLAYING', chainIndex: 2),
        );
        await _deliverAll(env, rig, c.entries.skip(2).take(2));

        final List<Frame> stale = _staleFrames(
          rig.controller,
          endedAtSeq: b.lastSeq,
          games: <String>{_gameA, _gameB},
        );
        expect(
          stale,
          isEmpty,
          reason: _why(
            tag,
            'no frame of game A or B after the resume into game C',
            '${stale.length} such frames; transcript is ${_dump(rig.controller)}',
          ),
        );
        expect(
          _types(rig.controller),
          <String>['room', 'rolled', 'moved'],
          reason: _why(
            tag,
            'the resume answer and the two live C frames',
            _dump(rig.controller),
          ),
        );
      } finally {
        rig.controller.dispose();
      }
    });

    test('E4: control, the resume answer is the rematch LOBBY (not PLAYING '
        'or FINISHED): game A\'s record is kept, and B\'s game_started then '
        'starts over', () async {
      const String tag = 'E4';
      final _Env env = _Env.plain();
      final _Script a = _scriptA();
      // Host start from the rematch LOBBY with two ready seats runs the
      // start order directly (section 16.9 ruling 3): game_started follows
      // the lobby snapshot with the next seq.
      final _Script b = _scriptB(_gameB, a.lastSeq + 2);
      final _Rig rig = await _open(env, state: 'LOBBY');
      try {
        await _deliverAll(env, rig, a.entries);
        await _dropAndResume(
          env,
          rig,
          _rematchLobby(seq: a.lastSeq + 1, by: _other),
        );

        expect(
          _types(rig.controller),
          <String>[..._typesOf(a.entries), 'room'],
          reason: _why(
            tag,
            'a LOBBY answer is not in D1: A\'s frames stay and the room '
            'frame appends',
            _dump(rig.controller),
          ),
        );

        await _deliverAll(env, rig, b.entries.take(2));
        expect(
          _types(rig.controller),
          <String>['game_started', 'turn'],
          reason: _why(
            tag,
            'B\'s live game_started clears A\'s record and opens B\'s',
            _dump(rig.controller),
          ),
        );
        expect(rig.controller.gameTranscript.first.data['game_id'], _gameB);
      } finally {
        rig.controller.dispose();
      }
    });

    test(
      'E5: control, a relaunched controller (resumeRoom, transcript never '
      'opened) resumed into PLAYING game B: the transcript stays empty',
      () async {
        const String tag = 'E5';
        final _Env env = _Env.plain();
        final _Script b = _scriptB(_gameB, 40);
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        try {
          unawaited(
            controller.resumeRoom(code: _code, seat: _me, seatToken: 'tok-0'),
          );
          await env.io();
          final String resumeId = _idOf(
            transport.sentRaw
                .where((String raw) => _typeOf(raw) == 'resume')
                .last,
          );
          transport.pushText(
            _frame(
              type: 'seat_assigned',
              data: <String, Object?>{'seat': _me, 'seat_token': 'tok-0'},
            ),
          );
          transport.pushText(
            _frame(
              type: 'room',
              re: resumeId,
              data: _roomOf(b, 2, state: 'PLAYING', chainIndex: 1),
            ),
          );
          await env.settle();
          expect(controller.room?.gameId, _gameB);
          for (final _Entry entry in b.entries.skip(2).take(2)) {
            transport.pushText(_frame(type: entry.t, data: entry.d));
            await env.settle();
          }

          expect(
            controller.gameTranscript,
            isEmpty,
            reason: _why(
              tag,
              'a transcript that never opened stays empty (D1 leaves a '
              'relaunch alone)',
              _dump(controller),
            ),
          );
        } finally {
          controller.dispose();
        }
      },
    );
  });

  group('screen: the end card after a resume across a rematch', () {
    testWidgets('T5: control, game A won by seat 2 live with no drop: the '
        'end card shows A\'s numbers and sends no game_log', (
      WidgetTester tester,
    ) async {
      const String tag = 'T5';
      final _Rig rig = await _mountPlaying(tester);
      try {
        final _Script a = _scriptA();
        await _deliverAll(_Env.widget(tester), rig, a.entries);
        await _pumpPastEndCardHold(tester);
        await _pumpFor(tester, _fewSeconds);

        expect(
          find.byKey(_loseKey),
          findsOneWidget,
          reason: _why(tag, 'the loser\'s card is up', _screenNote(tester)),
        );
        _expectTiles(
          tester,
          tag,
          rolls: _aRolls,
          sixes: _aSixes,
          captures: _aCaptures,
          home: _aHome,
        );
        expect(
          _sent(rig, 'game_log'),
          isEmpty,
          reason: _why(
            tag,
            'no game_log, the transcript is complete',
            'sent ${_sent(rig, 'game_log').length}',
          ),
        );
      } finally {
        await _finish(tester, rig.controller);
      }
    });

    testWidgets('T4a: game A won by seat 2 live, drop on the end card, '
        'resume into PLAYING game B, B played live to game_over: the stat '
        'tiles do not show game A\'s numbers', (WidgetTester tester) async {
      const String tag = 'T4a';
      final _Rig rig = await _mountPlaying(tester);
      try {
        final _Env env = _Env.widget(tester);
        final _Script a = _scriptA();
        final _Script b = _scriptB(_gameB, a.lastSeq + 3);
        await _playRematchResume(tester, env, rig, a, b, tag);

        expect(
          find.byKey(_loseKey),
          findsOneWidget,
          reason: _why(tag, 'game B\'s loser card is up', _screenNote(tester)),
        );
        _expectNotShown(
          tester,
          tag,
          rolls: _aRolls,
          sixes: _aSixes,
          captures: _aCaptures,
        );
      } finally {
        await _finish(tester, rig.controller);
      }
    });

    testWidgets('T4b: the same scene: one game_log is requested for game B; '
        'answered with game B\'s frames, the tiles show game B\'s numbers', (
      WidgetTester tester,
    ) async {
      const String tag = 'T4b';
      final _Rig rig = await _mountPlaying(tester);
      try {
        final _Env env = _Env.widget(tester);
        final _Script a = _scriptA();
        final _Script b = _scriptB(_gameB, a.lastSeq + 3);
        await _playRematchResume(tester, env, rig, a, b, tag);
        await _pumpFor(tester, _fewSeconds);

        final List<String> requests = _sent(rig, 'game_log');
        expect(
          requests,
          hasLength(1),
          reason: _why(
            tag,
            'exactly one game_log for the incomplete record of game B',
            'sent ${requests.length}; ${_screenNote(tester)}',
          ),
        );
        final String requestId = _idOf(requests.single);
        _pushGameLog(rig.transport, requestId, _gameB, b.entries);
        await tester.pump();
        await tester.pump();

        _expectTiles(
          tester,
          tag,
          rolls: _bRolls,
          sixes: _bSixes,
          captures: _bCaptures,
          home: _bHome,
        );
      } finally {
        await _finish(tester, rig.controller);
      }
    });
  });
}

// Screen rig.

Widget _harness(Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: appSupportedLocales,
  localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

/// Seat 0 in a PLAYING room at seq 1 with GameScreen mounted on the
/// controller. Game A's game_started then arrives live at seq 2.
Future<_Rig> _mountPlaying(WidgetTester tester) async {
  final _Rig rig = await _open(_Env.widget(tester), state: 'PLAYING');
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness(GameScreen(controller: rig.controller)));
  await tester.pump();
  return rig;
}

/// Unmounts, then disposes, so no timer survives the case.
Future<void> _finish(WidgetTester tester, RoomController controller) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await tester.pump();
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const Duration chunk = Duration(milliseconds: 250);
  Duration remaining = total;
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
  await tester.pump();
}

/// The board snaps a jump it cannot step, so the hold releases at
/// kEndCardHoldLimit. Bounded chunks, never one long pump.
Future<void> _pumpPastEndCardHold(WidgetTester tester) =>
    _pumpFor(tester, kEndCardHoldLimit);

/// Every game_log request this case has sent, on any of its transports.
List<String> _sent(_Rig rig, String type) => <String>[
  for (final FakeTransport transport in rig.transports)
    ...transport.sentRaw.where((String raw) => _typeOf(raw) == type),
];

/// Game A live to game_over and the end card up, a drop on the end card, a
/// resume into PLAYING game B, then game B live to its game_over and the end
/// card up again.
Future<void> _playRematchResume(
  WidgetTester tester,
  _Env env,
  _Rig rig,
  _Script a,
  _Script b,
  String tag,
) async {
  await _deliverAll(env, rig, a.entries);
  await _pumpPastEndCardHold(tester);
  expect(
    rig.controller.room!.state,
    RoomState.finished,
    reason: 'fixture: game A must end FINISHED live',
  );
  expect(
    find.byKey(_loseKey),
    findsOneWidget,
    reason: _why(tag, 'fixture: game A\'s loser card', _screenNote(tester)),
  );
  _expectTiles(
    tester,
    tag,
    rolls: _aRolls,
    sixes: _aSixes,
    captures: _aCaptures,
    home: _aHome,
  );

  rig.transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    find.byKey(_offlineKey),
    findsOneWidget,
    reason: _why(
      tag,
      'fixture: the end card says it is offline after the drop',
      _screenNote(tester),
    ),
  );
  final FakeTransport next = FakeTransport();
  rig.connector.enqueue(next);
  unawaited(rig.controller.reconnect());
  await env.io();
  final String resumeId = _idOf(
    next.sentRaw.where((String raw) => _typeOf(raw) == 'resume').last,
  );
  rig.transport = next;
  rig.transports.add(next);
  next.pushText(
    _frame(
      type: 'room',
      re: resumeId,
      data: _roomOf(b, 2, state: 'PLAYING', chainIndex: 1),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    rig.controller.room?.state,
    RoomState.playing,
    reason: _why(
      tag,
      'fixture: the resume answer lands a PLAYING room',
      '${rig.controller.room?.state}',
    ),
  );
  expect(rig.controller.room?.gameId, _gameB);

  await _deliverAll(env, rig, b.entries.skip(2));
  expect(
    rig.controller.room!.state,
    RoomState.finished,
    reason: _why(
      tag,
      'fixture: game B must end FINISHED live',
      '${rig.controller.room?.state}',
    ),
  );
  await _pumpPastEndCardHold(tester);
}

/// Two parts, back to back, as the server sends them (section 17 rule 2).
void _pushGameLog(
  FakeTransport transport,
  String requestId,
  String gameId,
  List<_Entry> entries,
) {
  final int split = entries.length ~/ 2;
  final List<List<_Entry>> parts = <List<_Entry>>[
    entries.sublist(0, split),
    entries.sublist(split),
  ];
  for (int i = 0; i < parts.length; i++) {
    transport.pushText(
      _frame(
        type: 'game_log',
        re: requestId,
        data: <String, Object?>{
          'game_id': gameId,
          'part': i + 1,
          'parts': parts.length,
          'frames': <Map<String, Object?>>[
            for (final _Entry entry in parts[i])
              <String, Object?>{'t': entry.t, 'd': entry.d},
          ],
        },
      ),
    );
  }
}

String _textUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  for (final Text text in tester.widgetList<Text>(
    find.descendant(of: root, matching: find.byType(Text)),
  )) {
    final String? data = text.data;
    if (data != null && data.isNotEmpty) {
      out.writeln(data.replaceAll('\n', ' '));
    }
  }
  return out.toString();
}

bool _tileShows(WidgetTester tester, Key key, int number) =>
    RegExp('(?<!\\d)$number(?!\\d)')
        .hasMatch(_textUnder(tester, find.byKey(key)));

String _screenNote(WidgetTester tester) {
  String tile(String name, Key key) {
    final Finder finder = find.byKey(key);
    return finder.evaluate().isEmpty
        ? '$name absent'
        : '$name "${_textUnder(tester, finder).trim().replaceAll('\n', ' ')}"';
  }

  return 'tiles: ${tile('rolls', _rollsKey)}; ${tile('sixes', _sixesKey)}; '
      '${tile('captures', _capturesKey)}; ${tile('home', _homeKey)}';
}

/// All four tiles present and showing exactly these numbers.
void _expectTiles(
  WidgetTester tester,
  String tag, {
  required int rolls,
  required int sixes,
  required int captures,
  required int home,
}) {
  final Map<String, (Key, int)> want = <String, (Key, int)>{
    'rolls': (_rollsKey, rolls),
    'sixes': (_sixesKey, sixes),
    'captures': (_capturesKey, captures),
    'home': (_homeKey, home),
  };
  want.forEach((String name, (Key, int) spec) {
    expect(
      find.byKey(spec.$1),
      findsOneWidget,
      reason: _why(
        tag,
        'the $name tile present showing ${spec.$2}',
        _screenNote(tester),
      ),
    );
    expect(
      _tileShows(tester, spec.$1, spec.$2),
      isTrue,
      reason: _why(
        tag,
        'the $name tile showing ${spec.$2}',
        _screenNote(tester),
      ),
    );
  });
}

/// No tile shows the stale game's number. A tile that is absent shows
/// nothing, which is the honest incomplete card (home alone).
void _expectNotShown(
  WidgetTester tester,
  String tag, {
  required int rolls,
  required int sixes,
  required int captures,
}) {
  final Map<String, (Key, int)> stale = <String, (Key, int)>{
    'rolls': (_rollsKey, rolls),
    'sixes': (_sixesKey, sixes),
    'captures': (_capturesKey, captures),
  };
  stale.forEach((String name, (Key, int) spec) {
    expect(
      _tileShows(tester, spec.$1, spec.$2),
      isFalse,
      reason: _why(
        tag,
        'the $name tile does not show game A\'s ${spec.$2} on game B\'s card',
        _screenNote(tester),
      ),
    );
  });
}
