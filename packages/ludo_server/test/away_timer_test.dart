// Order 484. docs/PROTOCOL.md section 26 rule 8, and docs/RULES.md 16c.
//
// A seat that was not connected when one whole turn of its own began, and
// that did not resume before that turn ended, is away. Every segment that
// starts while it is away has a budget of 10 000 ms. Every other segment
// keeps rules.turn_seconds * 1000 (45 000 with the default rules). The
// 10 000 is fixed. It is not a field of rules.
//
// A resume that flips an away seat back to connected clears away at once.
// If that seat is on turn and the running segment is a 10 000 ms one, the
// segment restarts at the full budget and every other socket is pushed
// presence (connected true) and then turn, same seat and phase, next seq.
// The resuming socket gets neither: its room answer is built after both.
// A resume onto a running 45 000 ms segment pushes presence only and the
// countdown continues. A takeover pushes nothing and changes nothing.
//
// game_started clears away on every seat, first game and rematch. Away
// means nothing in LOBBY or FINISHED. Seats carry no away field. The
// snapshot turn object carries segment_ms, the budget deadline_ms counts,
// present exactly when deadline_ms is.
//
// These tests drive a real WireServer and real sockets. The clock is the
// harness FakeClock. A segment expires by advancing that clock and calling
// runTurnExpiryOnce, never by sleeping. The away flags below are this
// file's own reading of rule 2, so a later segment can be named. They are
// not read off the server.
//
// Run from packages/ludo_server:
//   dart test test/away_timer_test.dart -r expanded
import 'dart:math' show Random;

import 'package:fair_dice/fair_dice.dart' show hexEncode;
import 'package:test/test.dart';

import 'support/dice_oracle.dart';
import 'support/scripted_bytes.dart';
import 'support/wire_harness.dart';

typedef _Frame = Map<String, Object?>;

const int _awayMs = 10000;

const String _hostSeed = 'away-host';
const String _guestSeed = 'away-guest';
const String _midSeed = 'away-mid';
const String _farSeed = 'away-far';

const Timeout _long = Timeout(Duration(minutes: 6));

final Map<String, SteeredSecret> _secrets = <String, SteeredSecret>{};

/// The budget rule 2 assigns to [seat] given the turns already observed.
class _Seat {
  bool away = false;
  bool beganDisconnected = false;
  bool resumedDuring = false;
  int turns = 0;
}

/// One countdown. [deadlineMs] is the value the opening frame carried,
/// which is the budget when the frame is produced with nothing elapsed.
class _Segment {
  _Segment({
    required this.seat,
    required this.phase,
    required this.deadlineMs,
    required this.seq,
    required this.startedAt,
    required this.newTurn,
    required this.from,
  });

  final int seat;
  final String phase;
  final int deadlineMs;
  final int seq;
  final DateTime startedAt;
  final bool newTurn;

  /// `turn` or `rolled`. A move-pending roll restarts the segment on the
  /// rolled frame; every other restart in this file arrives on a turn.
  final String from;
}

/// One PLAYING room and the sockets currently attached to it.
class _Table {
  _Table(this.harness);

  final ServerHarness harness;
  final List<WireTestClient> clients = <WireTestClient>[];
  final Map<int, WireTestClient> conns = <int, WireTestClient>{};
  final Map<int, String> tokens = <int, String>{};
  final Map<int, _Seat> model = <int, _Seat>{};

  bool started = false;
  late final String code;
  late final int fullMs;
  late final List<int> seats;
  _Segment? _segment;

  _Segment get segment => _segment!;

  set segment(_Segment value) => _segment = value;

  int? turnSeat;
  int roomSeq = 0;
  bool over = false;
  String why = '';
  List<int>? steered;
  int faceCursor = 0;
  List<_Frame> lastStep = <_Frame>[];

  int get opener => seats.first;

  int get highest => seats.last;

  int budgetFor(int seat) => model[seat]!.away ? _awayMs : fullMs;

  bool awayOpening(int seat) =>
      segment.seat == seat && segment.newTurn && model[seat]!.away;

  bool graceOpening(int seat) =>
      segment.seat == seat &&
      segment.newTurn &&
      model[seat]!.beganDisconnected &&
      !model[seat]!.away;

  bool freshTurn(int seat, int n) =>
      segment.seat == seat && segment.newTurn && model[seat]!.turns == n;

  String get debug {
    final String flags = model.entries
        .map((MapEntry<int, _Seat> e) =>
            '${e.key}:${e.value.away ? 'away' : 'here'}'
            '/${e.value.beganDisconnected ? 'off' : 'on'}'
            '/r${e.value.resumedDuring ? 1 : 0}'
            '/t${e.value.turns}')
        .join(',');
    final List<int> live = conns.keys.toList()..sort();
    final _Segment? current = _segment;
    final String where = current == null
        ? 'segment unset'
        : 'segment ${current.seat} ${current.phase} deadline '
            '${current.deadlineMs} from ${current.from} '
            'newTurn ${current.newTurn} seq ${current.seq}';
    return '[$why] room $code seats $seats $where roomSeq $roomSeq '
        'turnSeat $turnSeat live $live {$flags}';
  }

  static Future<_Table> open({
    required int players,
    List<int>? faces,
    int seed = 484,
  }) async {
    final String? clientSeeds = faces == null ? null : _clientSeeds(players);
    final SteeredSecret? steered = faces == null
        ? null
        : _secrets.putIfAbsent('$players:${faces.join(',')}:$clientSeeds', () {
            return findSecretForFaces(
              wanted: faces,
              gameId: _predictedGameId(players),
              clientSeeds: clientSeeds!,
              // Six faces are 6^6 trials on average. One prefix missed the
              // default 200000, so a six-face search looks further.
              maxCandidates: faces.length >= 6 ? 2000000 : 200000,
            );
          });
    final Random secure = steered == null
        ? Random(seed)
        : ScriptedBytesRandom(
            players == 2
                ? buildScript(secret: steered.secret)
                : buildThreeSeatScript(secret: steered.secret),
          );
    final ServerHarness harness = ServerHarness.build(
      secure: secure,
      automaticTurnExpiry: false,
    );
    final _Table table = _Table(harness);
    // Closed on every exit, including a start() that throws after the
    // socket is bound.
    table.started = true;
    try {
      await harness.start();
      await table._fill(players: players, faces: faces, steered: steered);
      return table;
    } catch (error) {
      await table.close();
      rethrow;
    }
  }

  Future<void> close() async {
    for (final WireTestClient client in clients) {
      await client.close();
    }
    clients.clear();
    conns.clear();
    if (started) {
      await harness.close();
      started = false;
    }
  }

  Future<void> _fill({
    required int players,
    required List<int>? faces,
    required SteeredSecret? steered,
  }) async {
    final List<_Joined> joined = <_Joined>[];
    if (players == 2) {
      final WireTestLobby lobby = await buildWireTestLobby(
        harness.wsUri,
        clients,
        players: 2,
        hostName: 'Host',
        guestName: 'Guest',
      );
      code = lobby.code;
      fullMs = _turnSeconds(lobby.hostRoom) * 1000;
      joined.add(_Joined(lobby.host.client, lobby.host.seat, lobby.host.token));
      joined.add(
        _Joined(lobby.guest.client, lobby.guest.seat, lobby.guest.token),
      );
    } else {
      joined.addAll(await _joinThree());
    }
    seats = joined.map((_Joined j) => j.seat).toList()..sort();
    expect(
      seats,
      players == 2 ? <int>[0, 2] : <int>[0, 1, 2],
      reason: 'setup: seat map. $debug',
    );
    expect(fullMs, 45000, reason: 'setup: default turn_seconds is 45. $debug');
    for (final _Joined j in joined) {
      conns[j.seat] = j.client;
      tokens[j.seat] = j.token;
      model[j.seat] = _Seat();
    }
    if (faces != null) {
      this.steered = faces;
      await _seedEveryone();
    }
    await _startGame(steered);
  }

  Future<List<_Joined>> _joinThree() async {
    final WireTestClient host = await WireTestClient.connect(harness.wsUri);
    clients.add(host);
    host.send('create_room', <String, Object?>{'name': 'Host', 'players': 3});
    final _Frame hostAssigned = await host.next();
    final _Frame hostRoom = await host.next();
    final _Frame hostRoomData = _data(hostRoom);
    code = hostRoomData['code']! as String;
    fullMs = _turnSeconds(hostRoomData) * 1000;
    final _Joined hostSeat = _Joined(
      host,
      (_data(hostAssigned)['seat']! as int),
      _data(hostAssigned)['seat_token']! as String,
    );

    final WireTestClient mid = await WireTestClient.connect(harness.wsUri);
    clients.add(mid);
    mid.send('join_room', <String, Object?>{'code': code, 'name': 'Mid'});
    final _Frame midAssigned = await mid.next();
    await mid.next();
    await host.next();
    final _Joined midSeat = _Joined(
      mid,
      _data(midAssigned)['seat']! as int,
      _data(midAssigned)['seat_token']! as String,
    );

    final WireTestClient far = await WireTestClient.connect(harness.wsUri);
    clients.add(far);
    far.send('join_room', <String, Object?>{'code': code, 'name': 'Far'});
    final _Frame farAssigned = await far.next();
    await far.next();
    await host.next();
    await mid.next();
    final _Joined farSeat = _Joined(
      far,
      _data(farAssigned)['seat']! as int,
      _data(farAssigned)['seat_token']! as String,
    );
    return <_Joined>[hostSeat, midSeat, farSeat];
  }

  Future<void> _seedEveryone() async {
    final Map<int, String> seeds = seats.length == 2
        ? <int, String>{0: _hostSeed, 2: _guestSeed}
        : <int, String>{0: _hostSeed, 1: _midSeed, 2: _farSeed};
    for (final int seat in seats) {
      conns[seat]!.send('set_seed', <String, Object?>{
        'client_seed': seeds[seat],
      });
      for (final int other in seats) {
        final _Frame frame = await receiveType(conns[other]!, 'seat_seed');
        expect(
          _data(frame)['client_seed'],
          seeds[seat],
          reason: 'setup: set_seed for seat $seat. $debug',
        );
      }
    }
  }

  Future<void> _startGame(SteeredSecret? steered) async {
    conns[opener]!.send('start_game', <String, Object?>{});
    _Frame? firstTurn;
    _Frame? startedData;
    for (final int seat in seats) {
      final _Frame started = await receiveType(
        conns[seat]!,
        'game_started',
        maxFrames: 8,
      );
      final _Frame turn = await expectOpeningTurn(
        conns[seat]!,
        _data(started)['turn'],
      );
      if (firstTurn == null) {
        startedData = _data(started);
        firstTurn = turn;
      } else {
        expect(_data(turn), _data(firstTurn), reason: 'setup: opening. $debug');
      }
    }
    if (steered != null) {
      expect(
        startedData!['game_id'],
        _predictedGameId(seats.length),
        reason: 'setup: game_id does not match the steered script. $debug',
      );
      expect(
        startedData['client_seeds'],
        _clientSeeds(seats.length),
        reason: 'setup: client_seeds. $debug',
      );
    }
    final _Frame data = _data(firstTurn!);
    expect(
      data['seat'],
      opener,
      reason: 'setup: a fresh game opens on the lowest seat. $debug',
    );
    _install(data, newTurn: true);
  }

  void _install(_Frame data, {required bool newTurn}) {
    final int seat = _asInt(data['seat'], 'turn.seat');
    final int seq = _asInt(data['seq'], 'turn.seq');
    final Object? phase = data['phase'];
    expect(
      phase,
      anyOf('await_roll', 'await_move'),
      reason: 'setup: turn.phase. $debug $data',
    );
    roomSeq = seq;
    if (newTurn) {
      turnSeat = null;
      _beginTurn(seat);
    }
    segment = _Segment(
      seat: seat,
      phase: phase! as String,
      deadlineMs: _asInt(data['deadline_ms'], 'turn.deadline_ms'),
      seq: seq,
      startedAt: harness.clock.now,
      newTurn: newTurn,
      from: 'turn',
    );
  }

  int _nextSeat(int seat) {
    final int at = seats.indexOf(seat);
    expect(at, isNonNegative, reason: 'setup: seat $seat. $debug');
    return seats[(at + 1) % seats.length];
  }

  void _beginTurn(int seat) {
    if (turnSeat != null) {
      expect(
        seat,
        _nextSeat(turnSeat!),
        reason: 'setup: turn order left $turnSeat for $seat. $debug',
      );
      final _Seat prev = model[turnSeat!]!;
      if (prev.beganDisconnected && !prev.resumedDuring) {
        prev.away = true;
      }
    }
    turnSeat = seat;
    final _Seat current = model[seat]!;
    current.beganDisconnected = !conns.containsKey(seat);
    current.resumedDuring = false;
    current.turns += 1;
  }

  void noteResume(int seat) {
    model[seat]!.away = false;
    model[seat]!.resumedDuring = true;
  }

  void noteSeq(_Frame frame) {
    final int seq = _asInt(_data(frame)['seq'], '${frame['t']}.seq');
    expect(
      seq,
      roomSeq + 1,
      reason: '${frame['t']} seq $seq does not follow $roomSeq. $debug',
    );
    roomSeq = seq;
  }

  void _noteFace(int value) {
    final List<int>? faces = steered;
    if (faces == null || faceCursor >= faces.length) {
      return;
    }
    expect(
      value,
      faces[faceCursor],
      reason: 'setup: steered face ${faceCursor + 1} of $faces was $value. '
          '$debug',
    );
    faceCursor += 1;
  }

  List<int> get liveSeats => conns.keys.toList()..sort();

  int get watcher {
    final List<int> live = liveSeats;
    expect(live, isNotEmpty, reason: 'setup: nobody is connected. $debug');
    return live.first;
  }

  void advanceTo(int elapsedMs) {
    final DateTime target = segment.startedAt.add(
      Duration(milliseconds: elapsedMs),
    );
    final int delta = target.difference(harness.clock.now).inMilliseconds;
    if (delta < 0) {
      fail('clock is already ${-delta} ms past elapsed $elapsedMs. $debug');
    }
    if (delta > 0) {
      harness.clock.advance(Duration(milliseconds: delta));
    }
  }

  /// Snapshot through a takeover resume of a seat that is already connected.
  /// Section 8 rule 6 and section 26 rule 5: this pushes nothing and does
  /// not change away.
  Future<_Frame> snapshot(int seat) async {
    final _Frame room = await _resumeSocket(seat);
    expect(
      room['state'],
      anyOf('PLAYING', 'FINISHED'),
      reason: 'setup: snapshot state. $debug ${room['state']}',
    );
    return room;
  }

  _Frame turnOf(_Frame room) {
    final Object? turn = room['turn'];
    expect(
      turn,
      isA<Map<Object?, Object?>>(),
      reason: 'setup: snapshot turn. $debug $turn',
    );
    return (turn! as Map<Object?, Object?>).cast<String, Object?>();
  }

  Future<_Frame> resume(int seat) => _resumeSocket(seat);

  Future<_Frame> _resumeSocket(int seat) async {
    final String token = tokens[seat]!;
    final WireTestClient fresh = await WireTestClient.connect(harness.wsUri);
    clients.add(fresh);
    final String id = fresh.send('resume', <String, Object?>{
      'code': code,
      'seat_token': token,
    });
    await expectSeatAssigned(
      fresh,
      expectedSeat: seat,
      expectedToken: token,
      because: why.isEmpty ? 'resume of seat $seat' : why,
    );
    final _Frame frame = await fresh.next();
    expect(
      frame['t'],
      'room',
      reason: 'section 8: resume answers seat_assigned then room. $debug '
          '${frame['t']}',
    );
    expect(frame['re'], id, reason: 'the room answers the resume. $debug');
    final WireTestClient? old = conns[seat];
    conns[seat] = fresh;
    if (old != null) {
      await old.close();
    }
    return _data(frame);
  }

  Future<void> drop(int seat) async {
    final WireTestClient? client = conns.remove(seat);
    expect(client, isNotNull,
        reason: 'setup: seat $seat is not connected. $debug');
    await client!.close();
    await expectPresence(seat, connected: false);
  }

  Future<void> expectPresence(int seat, {required bool connected}) async {
    // The seat the frame names does not receive its own presence, whether
    // it just left or it just resumed.
    final List<int> live = <int>[
      for (final int other in liveSeats)
        if (other != seat) other,
    ];
    expect(live, isNotEmpty, reason: 'setup: presence has no witness. $debug');
    int? seq;
    for (final int other in live) {
      final _Frame frame = await conns[other]!.next();
      expect(
        frame['t'],
        'presence',
        reason: 'expected presence for seat $seat connected=$connected, '
            'got "${frame['t']}" ${frame['d']}. $debug',
      );
      final _Frame data = _data(frame);
      expect(data['seat'], seat, reason: 'presence seat. $debug');
      expect(
        data['connected'],
        connected,
        reason: 'presence.connected. $debug',
      );
      final int thisSeq = _asInt(data['seq'], 'presence.seq');
      if (seq == null) {
        expect(
          thisSeq,
          roomSeq + 1,
          reason: 'presence seq $thisSeq does not follow $roomSeq. $debug',
        );
        seq = thisSeq;
      } else {
        expect(thisSeq, seq,
            reason: 'presence seq differs across sockets. $debug');
      }
    }
    roomSeq = seq!;
  }

  /// What every socket except [except] has waiting, or null when they are
  /// all quiet. A push the server already wrote is sitting in the buffer
  /// by the time the resume answer has been read, so the wait is only the
  /// proof that nothing was written. The sockets must agree.
  Future<_Frame?> nextExcept(int except) async {
    final List<int> live = <int>[
      for (final int seat in liveSeats)
        if (seat != except) seat,
    ];
    expect(live, isNotEmpty, reason: 'setup: no witness socket. $debug');
    final List<_Frame?> frames = <_Frame?>[];
    for (final int seat in live) {
      frames.add(
        await conns[seat]!.nextOrNull(
          timeout: const Duration(milliseconds: 800),
        ),
      );
    }
    if (frames.every((_Frame? frame) => frame == null)) {
      return null;
    }
    expect(
      frames.any((_Frame? frame) => frame == null),
      isFalse,
      reason: 'one witness was pushed a frame and another was not. $debug '
          '$frames',
    );
    final _Frame first = frames.first!;
    for (final _Frame? frame in frames.skip(1)) {
      expect(frame!['t'], first['t'], reason: 'witnesses disagree. $debug');
      expect(frame['d'], first['d'], reason: 'witnesses disagree. $debug');
    }
    return first;
  }

  Future<void> expectNoTurn(int seat) async {
    final _Frame? frame = await nextExcept(seat);
    if (frame != null) {
      fail(
        'resume pushed ${frame['t']} ${frame['d']}. Section 26 pushes no '
        'turn here. $debug',
      );
    }
  }

  Future<void> expectNoAction(int elapsed, int remaining) async {
    advanceTo(elapsed);
    harness.server.runTurnExpiryOnce();
    // Replacing the only connected socket (a takeover resume) removes the
    // room's socket set on the server, and the replacement is not in the
    // set a later broadcast reads. Nothing this seat does after that
    // arrives. Silence on the socket already connected is the check.
    if (liveSeats.length < 2) {
      expect(
        liveSeats,
        isNotEmpty,
        reason: 'no socket left to observe the timer. $debug',
      );
      for (final int seat in liveSeats) {
        final _Frame? frame = await conns[seat]!.nextOrNull(
          timeout: const Duration(milliseconds: 800),
        );
        if (frame != null) {
          fail(
            'timer action at $elapsed ms: ${frame['t']} ${frame['d']}. '
            '$debug',
          );
        }
      }
      return;
    }
    final _Frame room = await snapshot(watcher);
    expect(
      room['state'],
      'PLAYING',
      reason: 'no timer action is due at $elapsed ms. $debug',
    );
    expect(
      room['seq'],
      roomSeq,
      reason: 'no timer action is due at $elapsed ms; seq moved from '
          '$roomSeq to ${room['seq']}. $debug',
    );
    final _Frame turn = turnOf(room);
    expect(turn['seat'], segment.seat,
        reason: 'seat changed at $elapsed ms. $debug');
    expect(
      turn['phase'],
      segment.phase,
      reason: 'phase changed at $elapsed ms. $debug',
    );
    expect(
      turn['deadline_ms'],
      remaining,
      reason: 'at $elapsed ms of a ${segment.deadlineMs} ms segment, '
          'deadline_ms is ${turn['deadline_ms']}, wanted $remaining. $debug',
    );
  }

  /// Play the segment at the budget rule 2 names, and fail if the frame
  /// named a different one. With [boundaries], also require silence at
  /// 10 000 ms when the budget is longer than that, silence at budget-1,
  /// and a timer step at the budget.
  Future<void> drive({bool boundaries = false, String because = ''}) async {
    if (over) {
      fail('drive called after game_over. $because $debug');
    }
    final int spec = budgetFor(segment.seat);
    expect(
      segment.deadlineMs,
      spec,
      reason: '${because.isEmpty ? 'segment budget' : because} '
          'Seat ${segment.seat} is '
          '${model[segment.seat]!.away ? 'away' : 'not away'}: '
          'wanted $spec ms, the frame says ${segment.deadlineMs}. $debug',
    );
    if (boundaries && spec > _awayMs) {
      await expectNoAction(_awayMs, spec - _awayMs);
    }
    if (boundaries) {
      await expectNoAction(spec - 1, 1);
    }
    await playAnnounced();
  }

  /// Expire at the deadline the current frame announced, whatever rule 2
  /// says it should have been. Used to reach the frame that follows a
  /// segment whose own budget is the claim, and to finish a game on the
  /// budgets the server is actually using.
  Future<void> playAnnounced() async {
    advanceTo(segment.deadlineMs);
    harness.server.runTurnExpiryOnce();
    final List<int> live = liveSeats;
    if (live.isEmpty) {
      fail('no socket left to observe the timer. $debug');
    }
    final List<List<_Frame>> steps = <List<_Frame>>[];
    for (final int seat in live) {
      steps.add(await _readStep(conns[seat]!));
    }
    final List<_Frame> first = steps.first;
    for (final List<_Frame> other in steps.skip(1)) {
      expect(
        other.length,
        first.length,
        reason: 'sockets saw different timer steps: '
            '${first.map((_Frame f) => f['t']).toList()} vs '
            '${other.map((_Frame f) => f['t']).toList()}. $debug',
      );
      for (int i = 0; i < first.length; i++) {
        expect(other[i]['t'], first[i]['t'], reason: 'step frame $i. $debug');
        expect(other[i]['d'], first[i]['d'], reason: 'step frame $i. $debug');
      }
    }
    lastStep = first;
    _adopt(first);
  }

  Future<List<_Frame>> _readStep(WireTestClient client) async {
    final List<_Frame> frames = <_Frame>[];
    for (int i = 0; i < 6; i++) {
      final _Frame? frame = await client.nextOrNull(
        timeout: const Duration(seconds: 3),
      );
      if (frame == null) {
        fail(
          frames.isEmpty
              ? 'timer published nothing when the segment reached '
                  '${segment.deadlineMs} ms. $debug'
              : 'timer step stopped after '
                  '${frames.map((_Frame f) => f['t']).toList()}. $debug',
        );
      }
      final Object? type = frame['t'];
      if (type == 'presence') {
        fail('presence arrived inside a timer step: ${frame['d']}. $debug');
      }
      frames.add(frame);
      if (type == 'turn' || type == 'game_over') {
        return frames;
      }
      if (type == 'rolled') {
        final Object? legal = _data(frame)['legal'];
        if (legal is List && legal.isNotEmpty) {
          return frames;
        }
        continue;
      }
      if (type == 'moved' || type == 'turn_passed') {
        continue;
      }
      fail('unexpected "${frame['t']}" in a timer step: ${frame['d']}. $debug');
    }
    fail(
      'timer step exceeded 6 frames: '
      '${frames.map((_Frame f) => f['t']).toList()}. $debug',
    );
  }

  void _adopt(List<_Frame> frames) {
    for (final _Frame frame in frames) {
      final Object? type = frame['t'];
      if (type == 'rolled' || type == 'moved') {
        expect(
          _data(frame)['by'],
          'timer',
          reason: 'section 22: a timer $type carries by "timer". $debug '
              '${frame['d']}',
        );
        expect(
          _data(frame)['seat'],
          segment.seat,
          reason: 'setup: the timer acted for seat ${segment.seat}. $debug '
              '${frame['d']}',
        );
      }
      if (type == 'rolled') {
        _noteFace(_asInt(_data(frame)['value'], 'rolled.value'));
      }
      noteSeq(frame);
    }
    final _Frame last = frames.last;
    final Object? type = last['t'];
    if (type == 'game_over') {
      over = true;
      return;
    }
    final DateTime now = harness.clock.now;
    if (type == 'rolled') {
      final _Frame data = _data(last);
      segment = _Segment(
        seat: segment.seat,
        phase: 'await_move',
        deadlineMs: _asInt(data['deadline_ms'], 'rolled.deadline_ms'),
        seq: _asInt(data['seq'], 'rolled.seq'),
        startedAt: now,
        newTurn: false,
        from: 'rolled',
      );
      return;
    }
    expect(type, 'turn', reason: 'timer step ended on "$type". $debug');
    final _Frame data = _data(last);
    final int seat = _asInt(data['seat'], 'turn.seat');
    final bool changed = seat != turnSeat;
    if (changed) {
      _beginTurn(seat);
    }
    final Object? phase = data['phase'];
    expect(
      phase,
      anyOf('await_roll', 'await_move'),
      reason: 'turn.phase after a timer step. $debug $data',
    );
    segment = _Segment(
      seat: seat,
      phase: phase! as String,
      deadlineMs: _asInt(data['deadline_ms'], 'turn.deadline_ms'),
      seq: _asInt(data['seq'], 'turn.seq'),
      startedAt: now,
      newTurn: changed,
      from: 'turn',
    );
  }

  Future<void> until(
    bool Function() cond, {
    int bound = 40,
    bool announced = false,
  }) async {
    int steps = 0;
    while (!cond()) {
      if (over) {
        fail('game_over after $steps steps, before the condition. $debug');
      }
      if (steps >= bound) {
        fail('bound of $bound timer steps hit. $debug');
      }
      if (announced) {
        await playAnnounced();
      } else {
        await drive();
      }
      steps += 1;
    }
  }

  /// Finish the current game on the clock. Every segment of an away [seat]
  /// must open at 10 000 ms. The first of those is checked at the 9 999 /
  /// 10 000 boundary. Returns without playing once [stop] is true, so a
  /// caller can assert the opening of that segment before it is spent.
  Future<void> playUntilGameOver(
    int seat, {
    bool Function()? stop,
  }) async {
    bool bounded = false;
    int steps = 0;
    while (!over) {
      if (stop != null && stop()) {
        return;
      }
      if (steps >= 2000) {
        fail('bound of 2000 timer steps hit before game_over. $debug');
      }
      final bool short = model[seat]!.away && segment.seat == seat;
      if (short) {
        expect(
          segment.deadlineMs,
          _awayMs,
          reason: 'after its first turn, every segment of seat $seat is '
              '10 000 ms. The frame says ${segment.deadlineMs}. '
              'No timer action is due at 9 999 ms and the timer must act '
              'at 10 000. $debug',
        );
      }
      await drive(
        boundaries: short && !bounded,
        because: short
            ? 'away seat $seat plays this segment on 10 000 ms'
            : 'seat ${segment.seat} keeps the full budget',
      );
      if (short) {
        bounded = true;
      }
      steps += 1;
    }
  }

  Future<void> rematchFromFinished(int wasAway) async {
    expect(over, isTrue, reason: 'setup: rematch follows game_over. $debug');
    expect(
      conns.containsKey(wasAway),
      isFalse,
      reason: 'setup: the away seat is still disconnected at game_over. $debug',
    );
    final _Frame back = await resume(wasAway);
    expect(back['state'], 'FINISHED', reason: 'section 8 rule 5. $debug');
    await expectPresence(wasAway, connected: true);
    await expectNoTurn(wasAway);
    noteResume(wasAway);

    final List<int> order = liveSeats;
    for (int i = 0; i < order.length; i++) {
      final int seat = order[i];
      final String id = conns[seat]!.send('rematch', <String, Object?>{});
      for (final int other in order) {
        final _Frame frame = await conns[other]!.next();
        expect(
          frame['t'],
          'room',
          reason: 'section 16: rematch is answered by room, got '
              '"${frame['t']}". $debug',
        );
        if (other == seat) {
          expect(frame['re'], id,
              reason: 'the accepter\'s room answers its id. $debug');
        } else {
          expect(frame['re'], isNull,
              reason: 'a rematch broadcast carries no re. $debug');
        }
      }
      if (i != order.length - 1) {
        continue;
      }
      _Frame? started;
      _Frame? turn;
      for (final int other in order) {
        final List<_Frame> frames = await drainUntil(
          conns[other]!,
          'game_started',
          maxFrames: 8,
        );
        expect(
          frames.length - 1,
          order.length,
          reason: 'section 16.5: one server seat_seed per occupied seat '
              'before game_started. Saw '
              '${frames.map((_Frame f) => f['t']).toList()}. $debug',
        );
        for (final _Frame seed in frames.sublist(0, frames.length - 1)) {
          expect(seed['t'], 'seat_seed',
              reason: 'setup: rematch seeds. $debug');
          expect(
            _data(seed)['origin'],
            'server',
            reason: 'nobody set_seed in the rematch lobby. $debug',
          );
        }
        final _Frame open = await expectOpeningTurn(
          conns[other]!,
          _data(frames.last)['turn'],
        );
        if (started == null) {
          started = _data(frames.last);
          turn = open;
        } else {
          expect(_data(open), _data(turn!), reason: 'opening turn. $debug');
        }
      }
      _resetForRematch();
      _install(_data(turn!), newTurn: true);
    }
    expect(
      model[wasAway]!.away,
      isFalse,
      reason: 'game_started clears away. $debug',
    );
    if (segment.seat != wasAway) {
      await until(() => freshTurn(wasAway, 1));
    }
    expect(
      segment.deadlineMs,
      fullMs,
      reason: 'a rematch starts with no seat away, including seat $wasAway '
          'which was away when the previous game ended. The new game gives '
          'it ${segment.deadlineMs} ms, wanted $fullMs. $debug',
    );
  }

  void _resetForRematch() {
    for (final _Seat seat in model.values) {
      seat.away = false;
      seat.beganDisconnected = false;
      seat.resumedDuring = false;
      seat.turns = 0;
    }
    over = false;
    steered = null;
    faceCursor = 0;
    turnSeat = null;
  }

  int _asInt(Object? value, String name) {
    expect(
      value,
      isA<int>(),
      reason: '$name must be an int, got ${value.runtimeType} $value. $debug',
    );
    return value! as int;
  }
}

class _Joined {
  _Joined(this.client, this.seat, this.token);

  final WireTestClient client;
  final int seat;
  final String token;
}

int _turnSeconds(_Frame room) {
  final Object? rules = room['rules'];
  expect(rules, isA<Map<Object?, Object?>>(), reason: 'setup: room.rules');
  final Object? seconds =
      (rules! as Map<Object?, Object?>).cast<String, Object?>()['turn_seconds'];
  expect(seconds, isA<int>(), reason: 'setup: rules.turn_seconds');
  return seconds! as int;
}

String _clientSeeds(int players) {
  if (players == 2) {
    return '0:$_hostSeed|2:$_guestSeed';
  }
  return '0:$_hostSeed|1:$_midSeed|2:$_farSeed';
}

String _predictedGameId(int players) {
  final List<int> script = players == 2
      ? buildScript(secret: List<int>.filled(serverSecretDraws, 0))
      : buildThreeSeatScript(secret: List<int>.filled(serverSecretDraws, 0));
  final int offset = players == 2 ? gameIdOffset : threeSeatGameIdOffset;
  return hexEncode(script.sublist(offset, offset + gameIdDraws));
}

_Frame _data(_Frame frame) {
  final Object? raw = frame['d'];
  expect(raw, isA<Map<Object?, Object?>>(), reason: 'frame ${frame['t']} d');
  return (raw! as Map<Object?, Object?>).cast<String, Object?>();
}

Future<void> _withTable(
  int players,
  Future<void> Function(_Table table) body, {
  List<int>? faces,
  int seed = 484,
}) async {
  final _Table table = await _Table.open(
    players: players,
    faces: faces,
    seed: seed,
  );
  try {
    await body(table);
  } finally {
    await table.close();
  }
}

void main() {
  group('protocol section 26 rule 8', () {
    for (final int players in <int>[2, 3]) {
      group('$players-seat room', () {
        test('a present seat\'s opening segment is 45 000 ms', () async {
          await _withTable(players, (_Table t) async {
            t.why = 'present opening segment';
            expect(t.segment.deadlineMs, t.fullMs, reason: t.debug);
            await t.drive(
              boundaries: true,
              because: 'a present seat keeps 45 000 ms. No timer action at '
                  '10 000 or at 44 999, and the timer acts at 45 000',
            );
          });
        });

        test('a connected seat that never acts keeps 45 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'connected idle seat, rule 16b';
              await t.until(() => t.freshTurn(t.opener, 2));
              expect(t.model[t.opener]!.away, isFalse, reason: t.debug);
              expect(
                t.model[t.opener]!.beganDisconnected,
                isFalse,
                reason: t.debug,
              );
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'a connected seat that never acts keeps 45 000 ms '
                    'on its later turn. The frame says ${t.segment.deadlineMs}. '
                    '${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'no timer action at 10 000 or at 44 999 on the '
                    'idle seat\'s later turn, and the timer acts at 45 000',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test(
            'disconnect while another seat is on turn: the next turn\'s '
            'roll is 45 000 ms and the timer plays it', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'grace roll stays 45 000';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.graceOpening(seat));
              expect(t.segment.phase, 'await_roll', reason: t.debug);
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the turn that begins disconnected is still 45 000 ms '
                    'on the roll. The frame says ${t.segment.deadlineMs}. '
                    '${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'the timer plays that 45 000 ms roll. No action at '
                    '10 000 or at 44 999',
              );
              expect(
                t.lastStep.any((_Frame f) => f['t'] == 'rolled'),
                isTrue,
                reason: 'the timer rolled the grace turn. ${t.debug}',
              );
            },
            faces: List<int>.filled(players == 2 ? 1 : 2, 1),
          );
        });

        test(
            'disconnect while another seat is on turn: that turn\'s move '
            'segment is 45 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'grace move stays 45 000';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.graceOpening(seat));
              await t.until(
                () =>
                    t.segment.seat == seat &&
                    t.segment.from == 'rolled' &&
                    t.segment.phase == 'await_move',
                bound: 6,
              );
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the move segment of the turn that began '
                    'disconnected is 45 000 ms. The frame says '
                    '${t.segment.deadlineMs}. ${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'the timer plays that 45 000 ms move. No action at '
                    '10 000 or at 44 999',
              );
            },
            faces:
                players == 2 ? const <int>[1, 6, 4] : const <int>[1, 1, 6, 4],
          );
        });

        test(
            'the turn after that starts at 10 000 ms and expires at '
            '10 000, not at 9 999', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'first away turn opens at 10 000';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 60);
              expect(
                t.segment.deadlineMs,
                _awayMs,
                reason: 'the turn after a whole turn away starts with '
                    'deadline_ms 10 000. The frame says '
                    '${t.segment.deadlineMs}. No timer action is due at '
                    '9 999 ms and the timer must act at 10 000. ${t.debug}',
              );
              await t.expectNoAction(_awayMs - 1, 1);
              await t.playAnnounced();
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test('while away, a move segment after a timer roll is 10 000 ms',
            () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'away move segment';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 60);
              for (int i = 0; i < 8 && !t.over && t.segment.seat == seat; i++) {
                await t.playAnnounced();
                if (t.segment.seat == seat &&
                    t.segment.from == 'rolled' &&
                    t.segment.phase == 'await_move') {
                  expect(
                    t.segment.deadlineMs,
                    _awayMs,
                    reason: 'while away, the move segment after a timer roll '
                        'is 10 000 ms. The rolled frame says '
                        '${t.segment.deadlineMs}. ${t.debug}',
                  );
                  return;
                }
              }
              fail(
                'setup: seat $seat went away with a token out and never '
                'reached a move segment. ${t.debug}',
              );
            },
            faces:
                players == 2 ? const <int>[1, 6, 4] : const <int>[1, 1, 6, 4],
          );
        });

        test('while away, the segment after a six is 10 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'away segment after a six';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 20);
              await t.playAnnounced();
              final _Frame rolled = t.lastStep.firstWhere(
                (_Frame f) => f['t'] == 'rolled',
                orElse: () =>
                    fail('setup: the away turn did not roll. ${t.debug}'),
              );
              expect(
                _data(rolled)['value'],
                6,
                reason: 'setup: the steered face on the away turn is a six. '
                    '${t.debug}',
              );
              expect(t.segment.seat, seat,
                  reason: 'a six keeps the seat. ${t.debug}');
              expect(
                t.segment.phase,
                'await_roll',
                reason: 'a six is followed by await_roll. ${t.debug}',
              );
              expect(t.segment.newTurn, isFalse, reason: t.debug);
              expect(
                t.segment.deadlineMs,
                _awayMs,
                reason: 'while away, the segment after a six is 10 000 ms. '
                    'The turn frame says ${t.segment.deadlineMs}. ${t.debug}',
              );
            },
            faces: players == 2
                ? const <int>[1, 1, 1, 6]
                : const <int>[1, 1, 1, 1, 1, 6],
          );
        });

        test('while away, the segment after an extra roll is 10 000 ms',
            () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'away segment after an extra roll';
              final int seat = t.highest;
              await t.drop(seat);
              for (int i = 0; i < 800 && !t.over; i++) {
                final bool wasAway = t.model[seat]!.away;
                final int onSeat = t.segment.seat;
                await t.playAnnounced();
                final bool extra = t.lastStep.any((_Frame f) {
                  if (f['t'] != 'moved') {
                    return false;
                  }
                  final _Frame data = _data(f);
                  return data['seat'] == seat && data['extra_roll'] == true;
                });
                if (!wasAway || onSeat != seat || !extra) {
                  continue;
                }
                if (t.over) {
                  fail(
                    'seat $seat\'s extra roll ended the game, so there is '
                    'no following segment. Reseed. ${t.debug}',
                  );
                }
                expect(
                  t.segment.seat,
                  seat,
                  reason: 'an extra roll keeps the seat. ${t.debug}',
                );
                expect(
                  t.segment.phase,
                  'await_roll',
                  reason: 'an extra roll is followed by await_roll. ${t.debug}',
                );
                expect(
                  t.segment.deadlineMs,
                  _awayMs,
                  reason: 'while away, the segment after an extra roll is '
                      '10 000 ms. The turn frame says ${t.segment.deadlineMs}. '
                      '${t.debug}',
                );
                return;
              }
              fail(
                'bound of 800 steps hit before away seat $seat got an '
                'extra roll (a capture or a home). over=${t.over}. ${t.debug}',
              );
            },
            seed: 484 + players,
          );
        }, timeout: _long);

        test(
            'a seat that disconnects mid-turn keeps the rest of that turn '
            'at 45 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'rest of the dropped turn stays 45 000';
              final int seat = t.opener;
              await t.playAnnounced();
              expect(t.segment.seat, seat,
                  reason: 'setup: a six stays. ${t.debug}');
              expect(t.segment.newTurn, isFalse, reason: t.debug);
              await t.drop(seat);
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the segment already running when the seat drops '
                    'stays 45 000 ms. The frame says ${t.segment.deadlineMs}. '
                    '${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'the rest of that roll segment expires at 45 000, '
                    'not at 10 000',
              );
              expect(
                t.segment.seat,
                seat,
                reason: 'setup: the closing non-6 still belongs to the '
                    'dropped seat. ${t.debug}',
              );
              expect(
                t.segment.from,
                'rolled',
                reason: 'setup: the closing non-6 leaves a move. ${t.debug}',
              );
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the move segment of the turn that began connected '
                    'stays 45 000 ms. The frame says ${t.segment.deadlineMs}. '
                    '${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'that move segment expires at 45 000, not at 10 000',
              );
            },
            faces: const <int>[6, 1],
          );
        });

        test(
            'a seat that disconnects mid-turn keeps its whole next turn '
            'at 45 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'the turn after a mid-turn drop stays 45 000';
              final int seat = t.opener;
              await t.playAnnounced();
              await t.drop(seat);
              await t.until(() => t.freshTurn(seat, 2), bound: 80);
              expect(t.model[seat]!.away, isFalse, reason: t.debug);
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the whole turn after a mid-turn drop is 45 000 ms. '
                    'The frame says ${t.segment.deadlineMs}. ${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'that next turn expires at 45 000, not at 10 000',
              );
            },
            faces: const <int>[6, 1],
          );
        });

        test(
            'after a mid-turn drop, only the turn after the next one is '
            '10 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'the turn after the grace turn is 10 000';
              final int seat = t.opener;
              await t.playAnnounced();
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 80);
              expect(
                t.segment.deadlineMs,
                _awayMs,
                reason: 'only the turn after the grace turn is 10 000 ms. '
                    'The frame says ${t.segment.deadlineMs}. No timer action '
                    'is due at 9 999 ms and the timer must act at 10 000. '
                    '${t.debug}',
              );
              await t.expectNoAction(_awayMs - 1, 1);
              await t.playAnnounced();
            },
            faces: const <int>[6, 1],
          );
        });

        test(
            'a resume during the turn that would make the seat away, '
            'then another drop, leaves the next turn at 45 000 ms', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'resume during the qualifying turn clears it';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.graceOpening(seat));
              t.advanceTo(5000);
              final _Frame room = await t.resume(seat);
              expect(
                t.turnOf(room)['deadline_ms'],
                t.fullMs - 5000,
                reason: 'the grace segment is 45 000 ms, so this resume does '
                    'not restart it. deadline_ms is '
                    '${t.turnOf(room)['deadline_ms']}, wanted '
                    '${t.fullMs - 5000}. ${t.debug}',
              );
              await t.expectPresence(seat, connected: true);
              await t.expectNoTurn(seat);
              t.noteResume(seat);
              await t.drop(seat);
              await t.until(() => t.freshTurn(seat, 2), bound: 60);
              expect(t.model[seat]!.away, isFalse, reason: t.debug);
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'a resume during the turn that would have made the '
                    'seat away, even though it drops again before the turn '
                    'ends, keeps the next turn at 45 000 ms. The frame says '
                    '${t.segment.deadlineMs}. ${t.debug}',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test('the other seats stay on 45 000 ms throughout', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'other seats stay on 45 000';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(
                () => t.model[seat]!.away && t.segment.seat != seat,
                bound: 60,
              );
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'after the dropped seat has become away, the seat '
                    'now on turn is still on 45 000 ms. The frame says '
                    '${t.segment.deadlineMs}. ${t.debug}',
              );
              await t.drive(
                boundaries: true,
                because: 'that other seat expires at 45 000, not at 10 000',
              );
              await t.until(() => t.awayOpening(seat),
                  announced: true, bound: 60);
              await t.until(
                () => t.segment.seat != seat,
                announced: true,
                bound: 12,
              );
              expect(
                t.model[t.segment.seat]!.away,
                isFalse,
                reason: t.debug,
              );
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the seat that plays after an away turn is still on '
                    '45 000 ms. The frame says ${t.segment.deadlineMs}. '
                    '${t.debug}',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test(
            'a resume of an away seat between turns clears it and pushes '
            'no turn', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'resume between turns';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(
                () => t.model[seat]!.away && t.segment.seat != seat,
                bound: 60,
              );
              final int phaseSeat = t.segment.seat;
              final String phase = t.segment.phase;
              final int deadline = t.segment.deadlineMs;
              final _Frame room = await t.resume(seat);
              expect(t.turnOf(room)['seat'], phaseSeat, reason: t.debug);
              expect(t.turnOf(room)['phase'], phase, reason: t.debug);
              await t.expectPresence(seat, connected: true);
              await t.expectNoTurn(seat);
              expect(
                t.turnOf(room)['deadline_ms'],
                deadline,
                reason: 'a resume between turns does not restart the seat '
                    'that is on turn. ${t.debug}',
              );
              t.noteResume(seat);
              expect(t.model[seat]!.away, isFalse, reason: t.debug);
              await t.until(() => t.freshTurn(seat, 2), bound: 60);
              expect(
                t.segment.deadlineMs,
                t.fullMs,
                reason: 'the resumed seat\'s next turn is 45 000 ms. The '
                    'frame says ${t.segment.deadlineMs}. ${t.debug}',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test(
            'a resume onto a running 10 000 ms segment restarts it at '
            '45 000', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'resume restarts a 10 000 segment';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 60);
              final String phase = t.segment.phase;
              final int seqBefore = t.segment.seq;
              final int openedAt = t.segment.deadlineMs;
              t.advanceTo(4000);
              final List<int> watchers = t.liveSeats;
              final _Frame room = await t.resume(seat);
              final List<_Frame> presence = <_Frame>[];
              for (final int watcher in watchers) {
                final _Frame frame = await t.conns[watcher]!.next();
                expect(
                  frame['t'],
                  'presence',
                  reason: 'the other socket is pushed presence before turn. '
                      'Got "${frame['t']}" ${frame['d']}. ${t.debug}',
                );
                final _Frame data = _data(frame);
                expect(data['seat'], seat, reason: t.debug);
                expect(data['connected'], isTrue, reason: t.debug);
                presence.add(frame);
              }
              final int presenceSeq = t._asInt(
                _data(presence.first)['seq'],
                'presence.seq',
              );
              expect(
                presenceSeq,
                seqBefore + 1,
                reason: 'presence takes the next seq. ${t.debug}',
              );
              for (final _Frame frame in presence.skip(1)) {
                expect(_data(frame)['seq'], presenceSeq, reason: t.debug);
              }
              t.roomSeq = presenceSeq;
              _Frame? turn;
              for (final int watcher in watchers) {
                final _Frame? frame = await t.conns[watcher]!.nextOrNull(
                  timeout: const Duration(seconds: 1),
                );
                if (frame == null) {
                  fail(
                    'missing turn push after presence. Section 26 restarts '
                    'a running 10 000 ms segment and pushes turn after '
                    'presence. The segment opened at $openedAt ms and '
                    '4 000 ms had elapsed. ${t.debug}',
                  );
                }
                expect(
                  frame['t'],
                  'turn',
                  reason: 'presence is followed by turn, got "${frame['t']}" '
                      '${frame['d']}. ${t.debug}',
                );
                if (turn == null) {
                  turn = frame;
                } else {
                  expect(frame['d'], turn['d'], reason: t.debug);
                }
              }
              final _Frame turnData = _data(turn!);
              final int turnSeq = t._asInt(turnData['seq'], 'turn.seq');
              expect(turnSeq, presenceSeq + 1,
                  reason: 'consecutive seq. ${t.debug}');
              expect(turnData['seat'], seat, reason: t.debug);
              expect(turnData['phase'], phase,
                  reason: 'same phase. ${t.debug}');
              expect(
                turnData['deadline_ms'],
                t.fullMs,
                reason: 'the restarted segment is 45 000 ms. The turn says '
                    '${turnData['deadline_ms']}. ${t.debug}',
              );
              final _Frame resumedTurn = t.turnOf(room);
              expect(
                resumedTurn['deadline_ms'],
                t.fullMs,
                reason: 'the resumer\'s room carries the restarted '
                    'deadline_ms. Got ${resumedTurn['deadline_ms']}. ${t.debug}',
              );
              expect(
                resumedTurn.containsKey('segment_ms'),
                isTrue,
                reason: 'the resumer\'s room is missing turn.segment_ms. '
                    'keys: ${resumedTurn.keys.toList()}. ${t.debug}',
              );
              expect(
                resumedTurn['segment_ms'],
                t.fullMs,
                reason: 'turn.segment_ms on the restarted segment is '
                    '${resumedTurn['segment_ms']}, wanted ${t.fullMs}. '
                    '${t.debug}',
              );
              expect(
                room['seq'],
                turnSeq,
                reason: 'the room answer is built after the pushed turn, so '
                    'its seq equals that turn. room seq ${room['seq']}, '
                    'turn seq $turnSeq. ${t.debug}',
              );
              final _Frame? own = await t.conns[seat]!.nextOrNull(
                timeout: const Duration(milliseconds: 800),
              );
              if (own != null) {
                fail(
                  'the resuming socket was pushed ${own['t']} ${own['d']}. '
                  'It gets neither presence nor turn. ${t.debug}',
                );
              }
              t.roomSeq = turnSeq;
              t.noteResume(seat);
              t.segment = _Segment(
                seat: seat,
                phase: phase,
                deadlineMs: t.fullMs,
                seq: turnSeq,
                startedAt: t.harness.clock.now,
                newTurn: false,
                from: 'turn',
              );
              await t.expectNoAction(6000, t.fullMs - 6000);
              await t.drive(
                boundaries: true,
                because: 'the restarted segment expires 45 000 ms after the '
                    'resume, not 6 000 ms after it',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test(
            'a resume onto the 45 000 ms grace segment pushes presence '
            'only and the deadline keeps counting', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'resume on the first disconnected turn';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.graceOpening(seat));
              expect(t.segment.deadlineMs, t.fullMs, reason: t.debug);
              await t.expectNoAction(_awayMs, t.fullMs - _awayMs);
              t.advanceTo(12000);
              final int seqBefore = t.roomSeq;
              final _Frame room = await t.resume(seat);
              await t.expectPresence(seat, connected: true);
              await t.expectNoTurn(seat);
              final _Frame turn = t.turnOf(room);
              expect(turn['seat'], seat, reason: t.debug);
              expect(turn['phase'], 'await_roll', reason: t.debug);
              expect(
                turn['deadline_ms'],
                t.fullMs - 12000,
                reason: 'presence only, and the 45 000 ms deadline keeps '
                    'counting. deadline_ms is ${turn['deadline_ms']}, '
                    'wanted ${t.fullMs - 12000}. ${t.debug}',
              );
              expect(
                room['seq'],
                seqBefore + 1,
                reason: 'the only seq this resume spends is the presence. '
                    '${t.debug}',
              );
              final _Frame? own = await t.conns[seat]!.nextOrNull(
                timeout: const Duration(milliseconds: 800),
              );
              if (own != null) {
                fail(
                  'the resuming socket was pushed ${own['t']} ${own['d']}. '
                  '${t.debug}',
                );
              }
              t.advanceTo(13000);
              final _Frame later = await t.snapshot(t.watcher);
              expect(
                t.turnOf(later)['deadline_ms'],
                t.fullMs - 13000,
                reason: 'a second later the countdown has moved by 1 000 ms, '
                    'not restarted. ${t.debug}',
              );
              expect(later['seq'], t.roomSeq, reason: t.debug);
            },
            faces: List<int>.filled(players == 2 ? 1 : 2, 1),
          );
        });

        test('the snapshot of an away seat carries segment_ms 10 000',
            () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'away snapshot segment_ms';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 60);
              t.advanceTo(2500);
              final _Frame turn = t.turnOf(await t.snapshot(t.watcher));
              expect(turn['seat'], seat, reason: t.debug);
              expect(
                turn.containsKey('segment_ms'),
                isTrue,
                reason: 'section 26 rule 4: turn.segment_ms is missing. '
                    'keys: ${turn.keys.toList()}. ${t.debug}',
              );
              expect(
                turn['segment_ms'],
                _awayMs,
                reason: 'an away seat\'s segment_ms is 10 000. The snapshot '
                    'says ${turn['segment_ms']}. ${t.debug}',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test(
            'the snapshot of an away seat shows deadline_ms 10 000 minus '
            'elapsed', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'away snapshot deadline';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 60);
              t.advanceTo(2500);
              final _Frame turn = t.turnOf(await t.snapshot(t.watcher));
              expect(
                turn['deadline_ms'],
                _awayMs - 2500,
                reason: '2 500 ms into an away segment, deadline_ms is '
                    '${turn['deadline_ms']}, wanted ${_awayMs - 2500}. '
                    '${t.debug}',
              );
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        });

        test(
            'the snapshot of a present seat shows deadline_ms 45 000 '
            'minus elapsed', () async {
          await _withTable(players, (_Table t) async {
            t.why = 'present snapshot deadline';
            final _Frame opened = t.turnOf(await t.snapshot(t.watcher));
            expect(
              opened['deadline_ms'],
              t.fullMs,
              reason: 'a present seat at elapsed 0 shows ${t.fullMs}. '
                  'The snapshot says ${opened['deadline_ms']}. ${t.debug}',
            );
            t.advanceTo(2500);
            final _Frame later = t.turnOf(await t.snapshot(t.watcher));
            expect(
              later['deadline_ms'],
              t.fullMs - 2500,
              reason: '2 500 ms later a present seat shows '
                  '${t.fullMs - 2500}. The snapshot says '
                  '${later['deadline_ms']}. ${t.debug}',
            );
          });
        });

        test('the snapshot of a present seat carries segment_ms 45 000',
            () async {
          await _withTable(players, (_Table t) async {
            t.why = 'present snapshot segment_ms';
            final _Frame turn = t.turnOf(await t.snapshot(t.watcher));
            expect(
              turn.containsKey('segment_ms'),
              isTrue,
              reason: 'section 26 rule 4: turn.segment_ms is missing. '
                  'keys: ${turn.keys.toList()}. ${t.debug}',
            );
            expect(
              turn['segment_ms'],
              t.fullMs,
              reason: 'a present seat\'s segment_ms is ${t.fullMs}. The '
                  'snapshot says ${turn['segment_ms']}. ${t.debug}',
            );
          });
        });

        test(
            'a rematch starts with no seat away, including one that was '
            'away when the previous game ended', () async {
          await _withTable(
            players,
            (_Table t) async {
              t.why = 'rematch clears away';
              final int seat = t.highest;
              await t.drop(seat);
              await t.until(() => t.awayOpening(seat), bound: 60);
              await t.playUntilGameOver(seat);
              await t.rematchFromFinished(seat);
            },
            faces: List<int>.filled(players == 2 ? 2 : 3, 1),
          );
        }, timeout: _long);
      });
    }

    test(
      'a two-seat game with one seat dropped before its first turn '
      'reaches game_over with that seat\'s later segments at 10 000 ms',
      () async {
        await _withTable(
          2,
          (_Table t) async {
            t.why = 'two-seat game_over on the timer';
            final int seat = t.highest;
            await t.drop(seat);
            await t.until(() => t.awayOpening(seat), bound: 60);
            await t.playUntilGameOver(seat);
            expect(t.over, isTrue, reason: t.debug);
          },
          faces: const <int>[1, 1],
        );
      },
      timeout: _long,
    );
  });
}
