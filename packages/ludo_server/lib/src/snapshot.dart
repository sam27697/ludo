// docs/PROTOCOL.md sections 6, 5 and 11, and the section 5 payload shapes
// that are built straight from a `Room` or a `Seat` rather than from an
// inbound message. `docs/ENGINE_API.md` section 9 is the wire mapping for
// the engine's own vocabulary; this file is the server's half of that
// mapping, turning a `GameState` into the redacted snapshot a client is
// allowed to see. `rngState`, `config.seed` and a room's dice-chain server
// secret never appear below, on purpose: sending any of them would hand a
// client every future roll.

import 'package:ludo_engine/ludo_engine.dart' as engine;

import 'registry.dart';
import 'room.dart';

/// The full `room` push, section 6. `seq` is read, never computed: it is
/// `room.seq`, the registry's own counter, moved by exactly one on every
/// successful state-changing call before this is ever built.
///
/// [now] is the instant `turn.deadline_ms` is computed against, per section
/// 6: "the value is `max(0, turn_seconds * 1000 - elapsed)` measured on the
/// server's injected clock, so it is computable in a snapshot whether or not
/// anything is scheduled to fire at zero." This file has no clock of its
/// own -- `clock.dart` says nothing under `lib/src/` calls `DateTime.now()`
/// directly -- so the caller (`connection.dart`, holding the same injected
/// `Clock` the registry was built with) passes the reading in.
///
/// Section 31 item 1 and 3: `link_id`, `guest_approval` and `knocks`. The open
/// knocks are shown to the host only: [forHost] true lists them, and every
/// other viewer, and every frame broadcast to a whole room, sees `[]`.
Map<String, Object?> buildRoomSnapshot(
  Room room, {
  required DateTime now,
  bool forHost = false,
}) {
  final engine.GameState? game = room.game;
  return <String, Object?>{
    'code': room.code,
    'link_id': room.linkId,
    'guest_approval': room.guestApproval,
    'knocks': <Object?>[
      if (forHost)
        for (final Knock knock in room.knocks) knockPayload(knock, now),
    ],
    'state': _wireState(room.state),
    'host_seat': room.hostSeat,
    'players': room.players,
    'rules': <String, Object?>{
      // docs/PROTOCOL.md section 4, 2026-10-15 ruling: every room plays
      // with blocks off, so every frame that carries rules says so,
      // whatever was requested at create_room.
      'blocks': false,
      'capture_bonus': room.rules.captureBonus,
      'turn_seconds': room.rules.turnSeconds,
      // docs/PROTOCOL.md section 28 rule 1: present under 2026-11 only.
      if (room.isRuleset202611) 'ruleset': room.ruleset,
    },
    // docs/PROTOCOL.md section 11.2: present in every state, including
    // LOBBY, from the moment the room exists. `chain_commit` is
    // `room.chain.commit`, never `room`'s raw server secret.
    'chain_commit': room.chain.commit,
    'chain_index': room.chainIndex,
    'game_id': room.gameId,
    'client_seeds': room.clientSeeds,
    'seats': <Object?>[
      for (final Seat seat in room.seats) _seatSnapshot(room, seat),
    ],
    'turn': _turnSnapshot(room, now),
    'winner': game?.winner,
    // docs/PROTOCOL.md section 28 rule 3: seats in place order and seats in
    // retirement order, empty lists before there is a game. 2026-11 only.
    if (room.isRuleset202611)
      'placings': List<int>.of(game?.placings ?? <int>[]),
    if (room.isRuleset202611) 'retired': List<int>.of(game?.retired ?? <int>[]),
    // docs/PROTOCOL.md section 16.6: null, or { "by": seat, "ready": [seat,
    // ...] } with `ready` in ascending seat order. Present in every state;
    // non-null only in a rematch LOBBY.
    'rematch': _rematchSnapshot(room.rematch),
    'seq': room.seq,
  };
}

/// Section 31 item 3: `{ knock_id, name, expires_ms }`, `expires_ms` being the
/// time left of the knock's 60 s at [now], 1 to 60000.
Map<String, Object?> knockPayload(Knock knock, DateTime now) {
  final int left = 60000 - now.difference(knock.createdAt).inMilliseconds;
  return <String, Object?>{
    'knock_id': knock.id,
    'name': knock.name,
    'expires_ms': left < 1 ? 1 : left,
  };
}

Map<String, Object?>? _rematchSnapshot(Rematch? rematch) {
  if (rematch == null) {
    return null;
  }
  return <String, Object?>{
    'by': rematch.by,
    'ready': List<int>.of(rematch.ready)..sort(),
  };
}

Map<String, Object?> _seatSnapshot(Room room, Seat seat) {
  final List<int> tokens =
      room.game?.tokens[seat.seat] ?? const <int>[-1, -1, -1, -1];
  return <String, Object?>{
    'seat': seat.seat,
    'name': seat.name,
    'via': seat.via,
    'connected': seat.connected,
    'tokens': tokens,
    // docs/PROTOCOL.md section 6: null until this seat's seed is fixed,
    // and `seed_origin` is `"player"` or `"server"` from that point on and
    // never null again.
    'client_seed': seat.clientSeed,
    'seed_origin': seat.seedOrigin,
    // docs/PROTOCOL.md section 23 rule 1: always present, an int >= 0, in
    // every state; LOBBY reads 0 because the registry resets it there.
    'timer_steps': seat.timerSteps,
    // docs/PROTOCOL.md section 28 rule 2: rule 9r's count, 0..9, 2026-11
    // only. 0 before there is a game.
    if (room.isRuleset202611) 'drought': room.game?.drought[seat.seat] ?? 0,
    // docs/PROTOCOL.md section 30 rule 5: the sixes banked for this seat,
    // 0..3, 2026-12 only. 0 before there is a game.
    if (room.isRuleset202612) 'banked': room.game?.banked[seat.seat] ?? 0,
  };
}

/// `docs/PROTOCOL.md` section 6 and section 21.3 rule 2: `value`, `legal`,
/// `sixes` and `legal_by_face` are absent when `phase` is `await_roll`;
/// `deadline_ms`, `k` and `queue` are present in every phase (`queue` is
/// `[]` in `finished`, never omitted there). Before `start_game`,
/// `room.game` is null and there is no turn yet.
Map<String, Object?>? _turnSnapshot(Room room, DateTime now) {
  final engine.GameState? game = room.game;
  if (game == null) {
    return null;
  }
  final TurnQueueFields queueFields = turnQueueFields(game);
  final Map<String, Object?> turn = <String, Object?>{
    'seat': game.currentSeat,
    'phase': queueFields.phase,
    'queue': queueFields.queue,
  };
  if (game.phase == engine.GamePhase.awaitMove) {
    if (queueFields.release) {
      // docs/PROTOCOL.md section 28 rule 2: while a release is owed the turn
      // carries `release: true` and the releasable tokens, and no `value`
      // and no `legal_by_face`: there is no face to spend.
      turn['release'] = true;
      if (queueFields.offer) {
        // Section 30 rule 2: the release is on offer, to take or decline.
        turn['offer'] = true;
      }
      turn['legal'] = queueFields.legal;
      turn['sixes'] = game.sixes;
    } else {
      // docs/PROTOCOL.md section 21.3 rule 2: `value` is `defaultFace`, not
      // `game.roll` -- `game.roll` is always null under the queue
      // (ENGINE_API.md section 10.1) and `defaultFace` is the one thing that
      // decides which queued face an omitted `move.face` would spend.
      turn['value'] = queueFields.value;
      turn['legal'] = queueFields.legal;
      turn['sixes'] = game.sixes;
      turn['legal_by_face'] = queueFields.legalByFace;
    }
  }
  turn['deadline_ms'] = _deadlineMs(room, now);
  // docs/PROTOCOL.md section 29 rule 3: while the grace runs, the grace left;
  // once it has run out the key is absent, never 0.
  final int graceLeftMs = room.graceLeftMs(now);
  if (graceLeftMs > 0) {
    turn['grace_ms'] = graceLeftMs;
  }
  // docs/PROTOCOL.md section 26 rule 4: present exactly when `deadline_ms`
  // is, and the budget that countdown runs against.
  turn['segment_ms'] = room.turnSegmentMs;
  turn['k'] = room.rollCount;
  return turn;
}

/// `docs/PROTOCOL.md` section 21.1 and 21.3: the fields every `turn` --
/// pushed or snapshotted -- carries about the roll queue, computed once
/// from the engine state the moment that specific frame is fixed, never
/// re-derived from any legality rule of this file's own. `phase` and
/// `queue` are always set; `value`, `legal` and `legalByFace` are set only
/// when [game]'s phase is `awaitMove`, where `value` is
/// `engine.defaultFace` (the engine's own `roll` is always null under the
/// queue) and `legal` is that face's own legal tokens, ascending.
class TurnQueueFields {
  TurnQueueFields({
    required this.phase,
    required this.queue,
    this.value,
    this.legal,
    this.legalByFace,
    this.release = false,
    this.offer = false,
  });

  /// Section 28 rule 2: a yard release is owed. Then [legal] is the
  /// releasable tokens and [value] and [legalByFace] are null.
  final bool release;

  /// Section 30 rule 2: the owed release is an offer the seat may take or
  /// decline. Only together with [release].
  final bool offer;

  final String phase;
  final List<int> queue;
  final int? value;
  final List<int>? legal;
  final List<Map<String, Object?>>? legalByFace;
}

TurnQueueFields turnQueueFields(engine.GameState game) {
  final String phase = _wirePhase(game.phase);
  final List<int> queue = List<int>.of(game.queue);
  if (game.phase != engine.GamePhase.awaitMove) {
    return TurnQueueFields(phase: phase, queue: queue);
  }
  if (game.releaseOwed) {
    return TurnQueueFields(
      phase: phase,
      queue: queue,
      legal: engine.legalTokens(game),
      release: true,
      offer: game.releaseOffered,
    );
  }
  return TurnQueueFields(
    phase: phase,
    queue: queue,
    value: engine.defaultFace(game),
    legal: engine.legalTokens(game),
    legalByFace: _wireLegalByFace(game),
  );
}

/// `docs/ENGINE_API.md` section 10.1's `legalByFace`, in the wire shape
/// section 21.1 fixes: `[{"face": int, "tokens": [int]}]`, in first-queued
/// order (the map's own iteration order, which `engine.legalByFace` already
/// builds in that order and this file does not re-sort).
List<Map<String, Object?>> _wireLegalByFace(engine.GameState game) {
  final Map<int, List<int>> byFace = engine.legalByFace(game);
  return <Map<String, Object?>>[
    for (final entry in byFace.entries)
      <String, Object?>{'face': entry.key, 'tokens': entry.value},
  ];
}

/// `docs/PROTOCOL.md` section 6's `deadline_ms` formula, with the running
/// segment's own budget (section 26 rule 3), read against [now]
/// rather than against the moment some earlier frame was built -- a `room`
/// snapshot can be requested at any time after the segment it describes
/// started, so this is computed fresh every time this function runs, unlike
/// the `deadline_ms` on a `rolled` or `turn` push, which the registry fixed
/// once, at the instant that specific frame was decided, and which this
/// file never recomputes.
int _deadlineMs(Room room, DateTime now) => room.segmentRemainingMs(now);

String _wireState(RoomState state) {
  switch (state) {
    case RoomState.lobby:
      return 'LOBBY';
    case RoomState.playing:
      return 'PLAYING';
    case RoomState.finished:
      return 'FINISHED';
  }
}

String _wirePhase(engine.GamePhase phase) {
  switch (phase) {
    case engine.GamePhase.awaitRoll:
      return 'await_roll';
    case engine.GamePhase.awaitMove:
      return 'await_move';
    case engine.GamePhase.finished:
      return 'finished';
  }
}

/// `seat_assigned`, section 5. Sent to one socket at a time: the seat that
/// just took its place on `create_room` or `join_room`, the resuming socket
/// on every `resume` whether or not its seat number moved while it was away
/// (section 15 rule 2), and a connected seat whose number `set_players` just
/// changed (section 15 rule 1). Its `seat_token` must never appear anywhere
/// else: not in a broadcast, not in a log line, not in any other client's
/// snapshot.
Map<String, Object?> buildSeatAssigned(Seat seat) {
  return <String, Object?>{
    'seat': seat.seat,
    'seat_token': seat.seatToken,
  };
}

/// `player_joined`, section 5. `seq` is read from `room.seq` at the moment
/// the push is built, per section 5's "carrying `seq`" list.
Map<String, Object?> buildPlayerJoined(Seat seat, int seq) {
  return <String, Object?>{
    'seat': seat.seat,
    'name': seat.name,
    'seq': seq,
  };
}

/// `player_left`, section 5 and section 18: `host_seat` is the room's host
/// after the seat was freed, or -1 when none is left.
Map<String, Object?> buildPlayerLeft(int seat, int hostSeat, int seq) {
  return <String, Object?>{
    'seat': seat,
    'host_seat': hostSeat,
    'seq': seq,
  };
}

/// `presence`, section 5.
Map<String, Object?> buildPresence(int seat, bool connected, int seq) {
  return <String, Object?>{'seat': seat, 'connected': connected, 'seq': seq};
}

/// `game_started`, section 5 and section 11.2: `{ "turn": int, "game_id":
/// string, "client_seeds": string }`, plus `seq`.
///
/// No `seed_commit` -- the commitment is `chain_commit`, already published
/// in `room` at room creation, and it is not repeated here because it has
/// not changed. `game_id` and `client_seeds` are read off [room], which
/// `RoomRegistry.startGame` has already set by the time this is called;
/// both are frozen from this instant on and never appear anywhere else in
/// this file.
Map<String, Object?> buildGameStarted(Room room, int seq) {
  final engine.GameState game = room.game!;
  return <String, Object?>{
    'turn': game.currentSeat,
    'game_id': room.gameId,
    'client_seeds': room.clientSeeds,
    'seq': seq,
  };
}

/// `seat_seed`, section 5 and section 11.2: broadcast to the whole room
/// whenever a seat's seed is fixed -- once on an accepted `set_seed`
/// (`origin: "player"`), and again at `start_game` for every seat that sent
/// none (`origin: "server"`).
Map<String, Object?> buildSeatSeed({
  required int seat,
  required String clientSeed,
  required String origin,
  required int seq,
}) {
  return <String, Object?>{
    'seat': seat,
    'client_seed': clientSeed,
    'origin': origin,
    'seq': seq,
  };
}

/// `rolled`, section 5, section 11.2/11.3 and section 21.1/21.3: `value`,
/// `legal`, `deadline_ms`, `k` and `reveal` are exactly what the registry's
/// `roll()` call decided -- this never recomputes a face, a chain link or a
/// `seq`, it only lays out the fields that were already fixed by the one
/// code path allowed to read `chain.reveal(k)` and publish it. `queue` is
/// the queue after the roll (section 21.3 rule 3), and `legalByFace` is
/// given, and only given, when the phase after the roll is `await_move`.
/// `by`, section 22: given, and only given, as `"timer"` when a turn
/// expiry produced this roll; absent (the key not present at all) for
/// every roll a client's own `roll` produced.
Map<String, Object?> buildRolled({
  required int seat,
  required int value,
  required List<int> legal,
  required int deadlineMs,
  required int k,
  required String reveal,
  required int seq,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
  String? by,
  bool release = false,
  bool offer = false,
}) {
  return <String, Object?>{
    'seat': seat,
    'value': value,
    'legal': legal,
    'deadline_ms': deadlineMs,
    'k': k,
    'reveal': reveal,
    'seq': seq,
    if (queue != null) 'queue': queue,
    if (legalByFace != null) 'legal_by_face': legalByFace,
    // docs/PROTOCOL.md section 28 rule 2: given, and only given, as `true`
    // on the roll that grants a yard release, a lapse included.
    if (release) 'release': true,
    // Section 30 rule 2: the release is an offer, not yet taken.
    if (offer) 'offer': true,
    if (by != null) 'by': by,
  };
}

/// `turn_passed`, section 5: `reason` is `"no_legal_move"` or
/// `"three_sixes"`, the wire strings for `engine.TurnEndReason`.
Map<String, Object?> buildTurnPassed({
  required int seat,
  required String reason,
  required int seq,
}) {
  return <String, Object?>{'seat': seat, 'reason': reason, 'seq': seq};
}

/// `turn`, section 5 and section 21.3 rule 1: sent for the seat that now
/// holds the turn, whether because the turn passed, because that seat was
/// granted an extra roll, or because that seat still has faces left to
/// spend. `phase` and `queue` are given on every call since every room
/// plays the queue (section 21.3 rule 5); `value`, `legal` and
/// `legalByFace` are given, and only given, when `phase` is `await_move`.
/// [graceMs] is section 29's `grace_ms`.
Map<String, Object?> buildTurn({
  required int seat,
  required int deadlineMs,
  required int seq,
  String? phase,
  List<int>? queue,
  int? value,
  List<int>? legal,
  List<Map<String, Object?>>? legalByFace,
  bool release = false,
  bool offer = false,
  int? banked,
  int? graceMs,
}) {
  return <String, Object?>{
    'seat': seat,
    'deadline_ms': deadlineMs,
    // docs/PROTOCOL.md section 29 rule 3: given, and only given, on the
    // `turn` of a pass in a 2026-11 room; the key is never 0.
    if (graceMs != null && graceMs > 0) 'grace_ms': graceMs,
    'seq': seq,
    if (phase != null) 'phase': phase,
    if (queue != null) 'queue': queue,
    if (value != null) 'value': value,
    if (legal != null) 'legal': legal,
    if (legalByFace != null) 'legal_by_face': legalByFace,
    // docs/PROTOCOL.md section 28 rule 2: a yard release is owed.
    if (release) 'release': true,
    if (offer) 'offer': true,
    // Section 30 rule 5: the sixes banked for the seat, queued with this turn.
    if (banked != null && banked > 0) 'banked': banked,
  };
}

/// `release_declined`, section 30 rule 4.
Map<String, Object?> buildReleaseDeclined({
  required int seat,
  required int seq,
}) {
  return <String, Object?>{'seat': seat, 'seq': seq};
}

/// `sixes_granted`, section 30 rule 3: [seats] ascending, the other playing
/// seats granted a banked six by a taken release.
Map<String, Object?> buildSixesGranted({
  required List<int> seats,
  required int seq,
}) {
  return <String, Object?>{'seats': List<int>.of(seats), 'seq': seq};
}

/// Section 30 rule 5: how many banked sixes the step that produced [events]
/// queued for [seat] as its turn began, 0 when none. The engine empties the
/// bank into the queue at that moment, so the count is read off its
/// `SixesQueued` event and nowhere else.
int queuedBankedSixes(List<engine.GameEvent> events, int seat) {
  for (final engine.SixesQueued queued
      in events.whereType<engine.SixesQueued>()) {
    if (queued.seat == seat) {
      return queued.count;
    }
  }
  return 0;
}

/// `moved`, section 5, section 12.2 and section 21.1: built from the
/// engine's own `Moved` and `Captured` events and from nothing else, plus
/// the face this move spent, which the registry fixed at `move()` time
/// because the engine's own `Moved` event carries none. `captured` is the
/// list of `{seat, token}` the engine reported captured by this move, in
/// the order it reported them, empty when there were none. `by`, section
/// 22: given, and only given, as `"timer"` when a turn expiry produced
/// this move; absent (the key not present at all) for every move a
/// client's own `move` produced.
Map<String, Object?> buildMoved({
  required int seat,
  required int token,
  required int from,
  required int to,
  required List<Map<String, Object?>> captured,
  required bool extraRoll,
  required int seq,
  int? face,
  String? by,
  bool release = false,
}) {
  return <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': extraRoll,
    'seq': seq,
    if (face != null) 'face': face,
    // docs/PROTOCOL.md section 28 rule 2: the move spent a yard release and
    // so carries no `face`.
    if (release) 'release': true,
    if (by != null) 'by': by,
  };
}

/// `game_over`, section 5 and section 11.2: no `seed` -- every roll's secret
/// was already published in its own `rolled` frame -- and `verify_url` is
/// the permalink, `https://provefair.app/v/<game_id>`, built by the
/// registry from `room.gameId` and handed in here unchanged.
///
/// [placings] and [retired], given together and only under 2026-11
/// (`docs/PROTOCOL.md` section 28 rule 3), are the seats in place order and
/// the seats in retirement order.
Map<String, Object?> buildGameOver({
  required int winner,
  required String verifyUrl,
  required int seq,
  List<int>? placings,
  List<int>? retired,
}) {
  return <String, Object?>{
    'winner': winner,
    'verify_url': verifyUrl,
    'seq': seq,
    if (placings != null) 'placings': List<int>.of(placings),
    if (retired != null) 'retired': List<int>.of(retired),
  };
}

/// `seat_finished`, `docs/PROTOCOL.md` section 28 rule 3: [place] is 1-based.
Map<String, Object?> buildSeatFinished({
  required int seat,
  required int place,
  required int seq,
}) {
  return <String, Object?>{'seat': seat, 'place': place, 'seq': seq};
}

/// `seat_retired`, `docs/PROTOCOL.md` section 28 rule 4: [reason] is `left`,
/// `absent` or `kicked`, [hostSeat] the host after the retirement.
Map<String, Object?> buildSeatRetired({
  required int seat,
  required String reason,
  required int hostSeat,
  required int seq,
}) {
  return <String, Object?>{
    'seat': seat,
    'reason': reason,
    'host_seat': hostSeat,
    'seq': seq,
  };
}

/// One frame the wire layer must publish, and the type name it goes out
/// under. A list of these is an order, not a set: section 12 fixes the order
/// frames are sent in and a caller sends them exactly as given.
class OutFrame {
  const OutFrame(this.type, this.data);

  final String type;
  final Map<String, Object?> data;
}

/// The wire string for `engine.TurnEndReason`, `docs/PROTOCOL.md` section 5's
/// `turn_passed.reason`. Public because both the client-driven path in
/// `connection.dart` and the timer-driven path below need it and a second
/// copy of a two-branch mapping is a second place for it to drift.
String wireTurnEndReason(engine.TurnEndReason reason) {
  switch (reason) {
    case engine.TurnEndReason.noLegalMove:
      return 'no_legal_move';
    case engine.TurnEndReason.threeSixes:
      return 'three_sixes';
    case engine.TurnEndReason.released:
      return 'released';
  }
}

/// Every frame a timer-played turn publishes, in section 21.3 rule 4's own
/// order, which replaces section 12 for every room since every room plays
/// the queue: for a roll, [buildRollFrames]; for a move, [buildMoveFrames].
/// None of them carries `re`: no client request is being answered, so there
/// is no id to answer. Section 22: the `rolled` or `moved` this produces
/// carries `by: "timer"`; `turn_passed`, `turn` and `game_over` never do,
/// whoever caused them.
List<OutFrame> buildExpiryFrames(ExpiredTurn expired) {
  final RollOk? rolled = expired.roll;
  if (rolled != null) {
    return buildRollFrames(rolled, by: 'timer');
  }
  return buildMoveFrames(expired.move!, by: 'timer');
}

/// Every frame `RoomRegistry.roll` decided on, in section 21.3 rule 4's
/// order: `rolled` always, carrying the queue after the roll and, when a
/// move is now pending, `legal_by_face`; then, exactly when [ok] set them,
/// `turn_passed` and/or a `turn` for whichever seat holds the segment next.
/// Section 28 rule 2: the `rolled` of a roll that granted a yard release
/// (the engine's `YardReleased` event) carries `release: true` and, with
/// the release owed, no `legal_by_face`. [by] is section 22's, given for a
/// roll the turn timer made. One builder for the client-driven path and the
/// timer's, so the two cannot drift.
List<OutFrame> buildRollFrames(RollOk ok, {String? by}) {
  final List<OutFrame> frames = <OutFrame>[];
  final engine.Rolled event = ok.events.whereType<engine.Rolled>().single;
  final engine.GameState afterRoll = ok.room.game!;
  final TurnQueueFields afterRollFields = turnQueueFields(afterRoll);
  frames.add(
    OutFrame(
      'rolled',
      buildRolled(
        seat: event.seat,
        value: event.value,
        legal: event.legal,
        deadlineMs: ok.rolledDeadlineMs,
        k: ok.k,
        reveal: ok.reveal,
        seq: ok.rolledSeq,
        queue: afterRollFields.queue,
        legalByFace: afterRollFields.legalByFace,
        by: by,
        release: ok.release,
        offer: afterRollFields.offer,
      ),
    ),
  );
  if (ok.turnPassedSeq != null) {
    final engine.TurnEnded ended =
        ok.events.whereType<engine.TurnEnded>().single;
    frames.add(
      OutFrame(
        'turn_passed',
        buildTurnPassed(
          seat: ended.seat,
          reason: wireTurnEndReason(ended.reason),
          seq: ok.turnPassedSeq!,
        ),
      ),
    );
  }
  if (ok.turnSeq != null) {
    frames.add(
      OutFrame(
        'turn',
        buildTurn(
          seat: afterRoll.currentSeat,
          deadlineMs: ok.nextDeadlineMs!,
          seq: ok.turnSeq!,
          phase: afterRollFields.phase,
          queue: afterRollFields.queue,
          value: afterRollFields.value,
          legal: afterRollFields.legal,
          legalByFace: afterRollFields.legalByFace,
          release: afterRollFields.release,
          offer: afterRollFields.offer,
          banked: queuedBankedSixes(ok.events, afterRoll.currentSeat),
          graceMs: ok.nextGraceMs,
        ),
      ),
    );
  }
  return frames;
}

/// Every frame `RoomRegistry.declineRelease` decided on, section 30 rule 4:
/// `release_declined`, `turn_passed` (`no_legal_move`), then the `turn` of
/// the next seat, which carries `banked` when that seat holds banked sixes.
List<OutFrame> buildDeclineFrames(DeclineOk ok) {
  final engine.ReleaseDeclined declined =
      ok.events.whereType<engine.ReleaseDeclined>().single;
  final engine.TurnEnded ended = ok.events.whereType<engine.TurnEnded>().single;
  final engine.GameState after = ok.room.game!;
  final TurnQueueFields fields = turnQueueFields(after);
  return <OutFrame>[
    OutFrame(
      'release_declined',
      buildReleaseDeclined(seat: declined.seat, seq: ok.declinedSeq),
    ),
    OutFrame(
      'turn_passed',
      buildTurnPassed(
        seat: ended.seat,
        reason: wireTurnEndReason(ended.reason),
        seq: ok.turnPassedSeq,
      ),
    ),
    OutFrame(
      'turn',
      buildTurn(
        seat: after.currentSeat,
        deadlineMs: ok.nextDeadlineMs,
        seq: ok.turnSeq,
        phase: fields.phase,
        queue: fields.queue,
        value: fields.value,
        legal: fields.legal,
        legalByFace: fields.legalByFace,
        release: fields.release,
        offer: fields.offer,
        banked: queuedBankedSixes(ok.events, after.currentSeat),
        graceMs: ok.nextGraceMs,
      ),
    ),
  ];
}

/// Every frame `RoomRegistry.move` decided on: `moved` always, carrying the
/// face it spent (none for a yard release, which carries `release: true`
/// instead, section 28 rule 2), then exactly one of: `game_over` followed
/// by one `player_left` per freed retired seat (section 28 rule 4); or
/// `seat_finished` (section 28 rule 3) then `turn`; or `turn_passed`
/// followed by `turn`; or a bare `turn`. [by] is section 22's.
List<OutFrame> buildMoveFrames(MoveOk ok, {String? by}) {
  final List<OutFrame> frames = <OutFrame>[];
  final engine.Moved event = ok.events.whereType<engine.Moved>().single;
  frames.add(
    OutFrame(
      'moved',
      buildMoved(
        seat: event.seat,
        token: event.token,
        from: event.from,
        to: event.to,
        captured: <Map<String, Object?>>[
          for (final engine.Captured c
              in ok.events.whereType<engine.Captured>())
            <String, Object?>{'seat': c.seat, 'token': c.token},
        ],
        extraRoll: ok.events.whereType<engine.ExtraRoll>().isNotEmpty,
        seq: ok.movedSeq,
        face: ok.face,
        by: by,
        release: ok.release,
      ),
    ),
  );
  final List<engine.GameWon> won =
      ok.events.whereType<engine.GameWon>().toList();
  if (won.isNotEmpty) {
    frames.addAll(
      _gameOverFrames(
        game: ok.room.game!,
        room: ok.room,
        winner: won.single.seat,
        verifyUrl: ok.verifyUrl!,
        gameOverSeq: ok.gameOverSeq!,
        freed: ok.freed,
      ),
    );
    return frames;
  }
  if (ok.seatFinishedSeq != null) {
    final engine.SeatFinished finished =
        ok.events.whereType<engine.SeatFinished>().first;
    frames.add(
      OutFrame(
        'seat_finished',
        buildSeatFinished(
          seat: finished.seat,
          place: finished.place,
          seq: ok.seatFinishedSeq!,
        ),
      ),
    );
  }
  final engine.GameState afterMove = ok.room.game!;
  final TurnQueueFields afterMoveFields = turnQueueFields(afterMove);
  if (ok.sixesGrantedSeq != null) {
    // Section 30 rule 3: a taken shared release grants the other playing
    // seats a six, after `moved` and before the pass.
    frames.add(
      OutFrame(
        'sixes_granted',
        buildSixesGranted(
          seats: ok.events.whereType<engine.SixesBanked>().single.seats,
          seq: ok.sixesGrantedSeq!,
        ),
      ),
    );
  }
  if (ok.turnPassedSeq != null) {
    final engine.TurnEnded ended =
        ok.events.whereType<engine.TurnEnded>().single;
    frames.add(
      OutFrame(
        'turn_passed',
        buildTurnPassed(
          seat: ended.seat,
          reason: wireTurnEndReason(ended.reason),
          seq: ok.turnPassedSeq!,
        ),
      ),
    );
  }
  frames.add(
    OutFrame(
      'turn',
      buildTurn(
        seat: afterMove.currentSeat,
        deadlineMs: ok.nextDeadlineMs!,
        seq: ok.turnSeq!,
        phase: afterMoveFields.phase,
        queue: afterMoveFields.queue,
        value: afterMoveFields.value,
        legal: afterMoveFields.legal,
        legalByFace: afterMoveFields.legalByFace,
        release: afterMoveFields.release,
        offer: afterMoveFields.offer,
        banked: queuedBankedSixes(ok.events, afterMove.currentSeat),
        graceMs: ok.nextGraceMs,
      ),
    ),
  );
  return frames;
}

/// Every frame a retirement decided on, `docs/PROTOCOL.md` section 28 rule 4,
/// in the order the engine's events say: `seat_retired`, then nothing more,
/// or a `turn` for the next playing seat, or a `game_over` followed by one
/// `player_left` per freed retired seat.
List<OutFrame> buildRetireFrames(RetireOk ok) {
  final List<OutFrame> frames = <OutFrame>[
    OutFrame(
      'seat_retired',
      buildSeatRetired(
        seat: ok.seat.seat,
        reason: ok.reason,
        hostSeat: ok.hostSeat,
        seq: ok.retiredSeq,
      ),
    ),
  ];
  if (ok.gameOverSeq != null) {
    final engine.GameWon won = ok.events.whereType<engine.GameWon>().single;
    frames.addAll(
      _gameOverFrames(
        game: ok.after,
        room: ok.room,
        winner: won.seat,
        verifyUrl: ok.verifyUrl!,
        gameOverSeq: ok.gameOverSeq!,
        freed: ok.freed,
      ),
    );
    return frames;
  }
  if (ok.turnSeq != null) {
    final engine.GameState after = ok.after;
    final TurnQueueFields fields = turnQueueFields(after);
    frames.add(
      OutFrame(
        'turn',
        buildTurn(
          seat: after.currentSeat,
          deadlineMs: ok.nextDeadlineMs!,
          seq: ok.turnSeq!,
          phase: fields.phase,
          queue: fields.queue,
          value: fields.value,
          legal: fields.legal,
          legalByFace: fields.legalByFace,
          release: fields.release,
          offer: fields.offer,
          banked: queuedBankedSixes(ok.events, after.currentSeat),
          graceMs: ok.nextGraceMs,
        ),
      ),
    );
  }
  return frames;
}

/// `game_over`, then, section 28 rule 4 "At the end", one `player_left` per
/// retired seat the end freed, in retirement order, each at its own `seq`.
/// `placings` and `retired` go on `game_over` under 2026-11 only.
List<OutFrame> _gameOverFrames({
  required engine.GameState game,
  required Room room,
  required int winner,
  required String verifyUrl,
  required int gameOverSeq,
  required List<FreedSeat> freed,
}) {
  final bool ruleset202611 = room.isRuleset202611;
  return <OutFrame>[
    OutFrame(
      'game_over',
      buildGameOver(
        winner: winner,
        verifyUrl: verifyUrl,
        seq: gameOverSeq,
        placings: ruleset202611 ? game.placings : null,
        retired: ruleset202611 ? game.retired : null,
      ),
    ),
    for (final FreedSeat gone in freed)
      OutFrame(
        'player_left',
        buildPlayerLeft(gone.seat.seat, gone.hostSeat, gone.seq),
      ),
  ];
}
