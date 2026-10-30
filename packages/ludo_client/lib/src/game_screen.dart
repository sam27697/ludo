// The screen a player looks at while a game is being played: the board with
// everyone's tokens where the server says they are, whose turn it is, a die
// under the board that rolls when tapped, tokens on the board that move when
// tapped, and an honest end-of-game state. Nothing here decides a rule,
// rolls a die, or advances a turn on its own; every frame this screen draws
// comes straight from RoomController, and tapping the die or a token sends
// the intention and waits for the server's own reply to change anything.
//
// Unique-legal exception, still not a rule: when the server names exactly
// one legal token, that token glows for 1.5 seconds and then this screen
// sends that one move if the player does not tap it first. There is no
// Undo: with one legal token, waiting out the hold and letting the turn
// timer expire both lead to that same move, so an Undo cancelled nothing a
// player could actually avoid.
//
// Not wired into navigation by this order. Nothing routes to this screen
// yet; it is built and proved standing alone, constructed directly with a
// controller.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show BoxParentData, RenderBox, RenderShiftedBox;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'board.dart';
import 'capture_gloat.dart';
import 'chat_bubble.dart' show EndCardChatBubble, EndCardChatLine;
import 'dead_mark.dart' show deadBadgeRect;
import 'die_cube.dart';
import 'die_mark.dart';
import 'end_card.dart';
import 'feedback.dart';
import 'feedback_settings_sheet.dart';
import 'game_die.dart';
import 'game_stats.dart';
import 'hint_button.dart';
import 'move_hint.dart';
import 'net/connection.dart';
import 'net/frame.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'no_move_reason.dart';
import 'quick_chat.dart';
import 'roll_tray.dart';
import 'safe_cue.dart';
import 'seat_die.dart';
import 'session_memory.dart';
import 'theme.dart';
import 'token_face_picker.dart';

/// Distinct [Navigator.pop] result from the finished-board next-table
/// button, a forced removal from the room, or a resume the server refused
/// because the room or the seat is gone (C-447 D4). The corner leave control
/// pops with no result, so the screen that pushed this route can leave()
/// and dispose the old controller without opening another table.
enum GameScreenResult { newTable, removed, gameGone }

/// C-432 D4: what a snapshot's own-seat `timer_steps` asks of the C-426 D3
/// notice. `none` is an older server's absent field, a seat that is not in
/// the snapshot, or a LOBBY snapshot.
enum _TimerStepsAction { arm, drop, none }

/// C-462 D2/D4: the picker open on one of my tokens, and the turn it
/// opened against. A rebuild closes it when any D4 condition fails.
class _OpenFacePick {
  const _OpenFacePick({
    required this.token,
    required this.k,
    required this.queue,
    required this.faces,
  });

  final int token;
  final int k;
  final List<int> queue;
  final List<int> faces;
}

/// C-471 D4: the marker this screen is showing, and the turn it belongs
/// to. [namesFace] is true when D1's candidates held more than one face.
class _ActiveHint {
  const _ActiveHint({
    required this.move,
    required this.gameId,
    required this.k,
    required this.seat,
    required this.namesFace,
  });

  final MoveHint move;
  final String gameId;
  final int k;
  final int seat;
  final bool namesFace;
}

/// Safety-net fallback duration for held landing cues, contract C-268 rule 4e.
const Duration kLandingCueFallback = Duration(milliseconds: 2000);

/// How long the safe-landing pill stays fully up, contract C-384 S5.
const Duration kSafeCueHold = Duration(milliseconds: 1400);

/// Fade after [kSafeCueHold] before the pill leaves the tree, contract
/// C-384 S5. Skipped when animations are disabled.
const Duration kSafeCueFade = Duration(milliseconds: 200);

/// Dwell time after winning move lands before end card, contract C-270 rule 4a.
const Duration kEndCardDwell = Duration(milliseconds: 600);

/// Upper bound on end-card hold before forcing release, contract C-270 rule 4c.
const Duration kEndCardHoldLimit = Duration(milliseconds: 2500);

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.controller});

  final RoomController controller;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  // The turn countdown's own local clock. docs/PROTOCOL.md section 6:
  // TurnState.deadlineMs is milliseconds remaining as measured on the
  // server at the moment the frame carrying it was sent, never an
  // absolute time, so this widget owns counting the rest of it down
  // itself: _countdownRemainingSeconds starts at the whole seconds the
  // last fresh reading carried and a once-a-second Timer.periodic ticks
  // it down from there, rather than reading a wall clock. Deliberately
  // not built on DateTime.now(): flutter_test's fake time only fakes
  // Timer, not DateTime, so a countdown that measured elapsed wall time
  // would read as barely-elapsed real time under every widget test that
  // pumps a virtual clock forward, this package's own suite included.
  // _countdownSeat, _countdownDeadlineMs and _countdownK are the raw
  // `(seat, deadlineMs, k)` triple the current countdown was last
  // started from.
  Timer? _countdownTimer;
  int? _countdownSeat;
  int? _countdownDeadlineMs;
  int? _countdownK;
  int _countdownRemainingSeconds = 0;

  // Client-side unique-legal hold. Armed once per await_move decision
  // (this seat, turn.k, and the queue) when exactly one token is legal.
  // Several spends of one roll queue share a k; a new queue arms again.
  // With no roll queue the queue is empty, so this is once per turn.k.
  // Cancelled by a manual token press, or the turn leaving that
  // unique-legal awaitMove. controller.move is not called until the hold
  // elapses without cancel. The duration itself is board.dart's own public
  // `kAutoMoveHold` (C-417 D2): the board's countdown arc and this timer
  // count from the same constant, so the arc reaching empty and the move
  // actually being sent coincide within a frame.
  Timer? _autoMoveTimer;

  // C-408 D8 (run 99): bounds D7's wait for a walk the board, for
  // whatever reason, never lands or snaps away (two `moved` frames of one
  // token coalesced into one build, or a refused `moved` whose resync
  // leaves the token where it was). Armed in `_syncAutoMove` the same
  // moment `_autoMoveAwaitingWalk` is set, from the legs `_travellingLegs`
  // counts at that moment (D8's formula). Cancelled wherever the 1500 ms
  // hold itself starts (`_startAutoMoveTimer`, the one path a landing or a
  // snap also goes through) or the decision drops (`_clearPendingHold`,
  // `_resetForNewGame`, dispose).
  Timer? _autoMoveCeilingTimer;
  int? _pendingAutoMoveToken;
  int? _autoMoveHandledK;
  List<int>? _autoMoveHandledQueue;

  // K8 (order 365, C-362 Part B): the face the auto-move hold's single
  // legal entry would spend, alongside the token above. Null under the
  // `legal.length == 1` fallback for a server with no roll queue.
  int? _pendingAutoMoveFace;

  // C-408 D7 (run 98): how many travelling legs this screen has taken off
  // a `moved` frame (seat, token) and not yet seen land, through either
  // `_onBoardMoveLanded` or the snap path `_onBoardTravelReset`. Keyed the
  // same way board.dart keys its own override map, `'$seat-$token'`. A
  // token whose count is back at zero is drawn at its truth, board.dart's
  // own D1/D2; this screen never reads the board's drawn position
  // directly, only this count built from the frames it already handed
  // the board.
  final Map<String, int> _travellingLegs = <String, int>{};

  // C-408 D7: true from the moment `_syncAutoMove` would have started the
  // 1500 ms hold while the held token's own walk was still travelling
  // (per `_travellingLegs`), until that walk lands or is snapped away.
  // The decision stays latched in `_autoMoveHandledK`/
  // `_autoMoveHandledQueue` the whole time; only the timer's own start is
  // delayed, so the glow is on screen for the full 1500 ms before the
  // move is sent.
  bool _autoMoveAwaitingWalk = false;

  // docs/PROTOCOL.md section 21 (C-362 Part B), order 365, K9/K10: the
  // roll queue's own bookkeeping, kept here because the model clears
  // `TurnState.queue` back to its placeholder `[]` on `moved` and
  // `turn_passed` (A4, 21.3 ruling 1) and this screen is what has to
  // rebuild a dead-ending turn's unspent faces across that gap.
  //
  // `_lastKnownQueue`: the queue this screen last confirmed real (read
  // off a `turn` frame, or a `rolled` that did not end the turn) for a
  // given seat -- "the queue the client held for that seat before the
  // roll [or move]", K9's own phrase.
  final Map<int, List<int>> _lastKnownQueue = <int, List<int>>{};

  // A `rolled`- or `moved`-dead candidate, banked the moment this screen
  // sees the turn might be about to die on dead faces, resolved into D
  // (K9) the instant `turn_passed` names why, or dropped if anything else
  // arrives first.
  int? _deadCandidateSeat;
  List<int>? _deadCandidateQueueBefore;
  int? _deadCandidateFace;
  bool _deadCandidateFromMove = false;

  // K1c/K9: the tray's own dead-faces hold. Deliberately not seat-gated
  // the way the die's own `_noMoveVisible` hold below is (C-236 rule 4
  // kept that mechanism, and its gating, exactly as it was): K1's own
  // closing line is "every player sees every seat's tray", so this one
  // arms for whichever seat's turn died, for every viewer.
  int? _trayDeadSeat;
  List<int>? _trayDeadFaces;
  Timer? _trayDeadTimer;

  // C-462 D2/D4: the open face picker, or null. Closed by the checks in
  // [_syncFacePick] on every rebuild, and by the tap rules in D2 and D3.
  _OpenFacePick? _facePick;

  // C-471 D5: the id read from `session.hintUsedGame`, and the id this
  // screen has spent. The spent id is set in the tap, before the store
  // write returns, so a second tap in the same frame cannot spend again.
  String? _storedHintGameId;
  String? _spentHintGameId;

  // C-471 D5: false until the stored id has been read, on success or
  // failure. Until then the control is waiting and a tap spends nothing.
  bool _hintStoreRead = false;

  // C-471 D4: the marker up right now. Cleared when a move is sent, and
  // when the turn stops being this seat's await-move at this k.
  _ActiveHint? _shownHint;

  // The one guard both move paths (the hold's own timer and a token tap)
  // share. At most one move is in flight for one decision: this seat,
  // await_move, this turn.k, and this queue. A second tap before that
  // request has finished sends nothing. The same holds after a refusal:
  // the next two taps, before the new request finishes, still send one.
  //
  // The guard belongs to the `controller.move` call that set it. When
  // that call finishes, the guard drops, whichever way the call ended:
  // the reply came back, the server refused and the refusal was
  // swallowed, or the socket died under the request. The finish drops
  // the guard only when `_moveGuardSerial` is still that call's number.
  // An accepted move's `moved` and `turn` can arrive before its reply,
  // and the next spend may already be in flight; a late finish of the
  // older call must leave the newer guard in place.
  //
  // The guard also drops when the live turn stops being the decision the
  // move was sent for. A `moved` for my seat does that (the reducer
  // leaves await_move), and so does a new queue, a new phase, or another
  // seat's turn. The next decision may then send once, from a tap or
  // from the one-legal-move hold, even when turn.k is unchanged. With no
  // roll queue the queue is empty, so one await_move of that k stays
  // blocked until the request finishes or the decision ends.
  //
  // The hold's own latch (`_autoMoveHandledK`) is separate. A refusal
  // does not clear it, so the hold does not send that decision again.
  // A tap still can.
  int? _moveSentForK;
  List<int>? _moveSentForQueue;
  int _moveSendSerial = 0;
  int? _moveGuardSerial;

  // C-422 D4: the token index `_sendMove` last put on the wire, tap path
  // and hold path alike; drawn lifted on the board (`Board.sentToken`)
  // until the guard above drops, by the same three routes. Never set or
  // cleared on its own -- it rides on the guard, it does not add a new
  // one.
  int? _moveSentToken;

  // The die's "waiting for my roll result" state. Set together with the
  // turn.k a rolling tap was sent under; cleared when the snapshot shows my
  // seat with a later k and a non-null value (the roll landed), when the
  // turn stops being mine, or by the 4s no-answer timer below. While this
  // is set the die tumbles; once it clears (by any of those three routes)
  // the die shows whatever `turn.value` it is given, tumble or not.
  int? _rollWaitK;
  Timer? _rollNoAnswerTimer;
  bool _rollNoAnswer = false;
  static const Duration _rollNoAnswerDelay = Duration(seconds: 4);

  // C-377: throws queued off `recentRolls` after this screen is up. The
  // baseline is whatever the room already held at mount, so the first
  // build never throws for a roll it did not see arrive. A list that is
  // not an append (a resync, a new game) replaces the baseline and throws
  // nothing.
  List<(int k, int face)> _seenRolls = const <(int k, int face)>[];
  _QueuedThrow? _activeThrow;
  final List<_QueuedThrow> _throwQueue = <_QueuedThrow>[];
  bool _throwHurry = false;

  /// True while the active throw is still travelling. The seat die of that
  /// seat stays off the board until the throw lands (C-465 D2). With no
  /// seat of my own, it still hides the face on the die under the board
  /// (C-377 D2).
  bool _throwConcealsFace = false;

  /// Last face this screen saw each other seat roll. Written when that
  /// seat's throw lands, never when it is queued, and from `turn.value`
  /// once no throw of that seat is queued or up (C-465 D2). Shown on the
  /// seat die once their turn has passed, until their next turn begins.
  /// A resync that replaces `recentRolls` drops the map, then the seat
  /// holding the turn records `turn.value` again.
  final Map<int, int> _rememberedSeatFaces = <int, int>{};

  /// The turn seat [_syncSeatFaceMemory] last applied, so a change to a
  /// new seat is that seat's turn beginning.
  int? _faceMemoryTurnSeat;

  // C-236 rule 2: one subscription to controller.frames for the life of
  // this screen, feeding every frame's cues to the one FeedbackService
  // above this tree. C-236 rules 4, 4a and 4b: the
  // no-move beat it also drives. Armed by a `rolled` for my seat with an
  // empty `legal`; holds `game-die-no-move-mark` and `game-no-move-notice`
  // up for exactly `_noMoveHold` from that `rolled`, whatever the turn
  // banner does underneath it in the meantime, and ends early when a
  // newer `rolled` carrying a value -- for any seat now, since the die is
  // shared and a fresh roll anywhere must take it back, not only mine --
  // lands. `_noMoveFace` is the face that armed `rolled` carried; it is
  // what the die shows for the whole hold, in my own seat colour, even
  // once the next seat's turn has cleared `turn.value` underneath it.
  StreamSubscription<Frame>? _frameSub;
  static const Duration _noMoveHold = Duration(milliseconds: 1500);
  Timer? _noMoveTimer;
  bool _noMoveVisible = false;
  int? _noMoveFace;
  // C-474 D1: why the armed notice has no move. Fixed when the notice arms
  // and untouched while it is up, even when a snapshot lands under it.
  NoMoveReason _noMoveReason = NoMoveReason.plain;

  // C-426 (order 428, docs/PROTOCOL.md section 22): a `rolled` or `moved`
  // whose raw data carries `by == "timer"` exactly. Mine
  // (`_timerPlayedMineVisible`) has no timer of its own -- D3's three
  // clearing events (my own play tap that sends, game over, this screen
  // leaving) are each handled at their own call site, not by a hold here.
  // Another seat's (`_timerPlayedOtherName`) is a plain 2500ms hold,
  // re-armed by the next qualifying frame naming that seat.
  bool _timerPlayedMineVisible = false;
  String? _timerPlayedOtherName;
  Timer? _timerPlayedOtherTimer;
  static const Duration _timerPlayedOtherHold = Duration(milliseconds: 2500);

  // C-432 D4 (order 434, docs/PROTOCOL.md section 23): the same
  // `_timerPlayedMineVisible` is also armed from my own seat's
  // `timer_steps` in a PLAYING snapshot. The one the controller already
  // held when this screen mounted cannot be announced from `initState`
  // (no inherited widget is readable there), so it sets this flag and
  // `didChangeDependencies` announces it once.
  bool _announceMountTimerPlayed = false;

  // C-293 rule 3: the last `turn` frame in gameTranscript when this screen
  // mounted, if any. Tied to mount time so the initial your_turn cue cannot
  // play a second time through _onFrame.
  Frame? _mountTurnFrame;
  bool _checkedMountTurnCue = false;

  // C-442 D4: the `turn.k` this screen last played `yourTurn` for, from a
  // live `turn` frame, the mount check, or a snapshot. A snapshot of my
  // `await_roll` plays the cue only for a k that is not this one, so a turn
  // is announced once however many times the room is replaced under it.
  int? _yourTurnPlayedK;

  // C-442 D5: the `game_id` of the last room this screen saw PLAYING and
  // whose `game_over` it has not received. A FINISHED snapshot naming this
  // same game is a game that ended while the screen was not listening.
  // Cleared by the `game_over` this screen does receive, and once the
  // snapshot's own cue has been played.
  String? _playingGameId;

  // C-246 rule 5: the `game_id` every per-game thing below is currently
  // reckoned against. Set from whatever the controller already held at
  // mount (a resume straight into a playing or finished room carries one),
  // then from every `game_started` this screen's own subscription sees. A
  // `game_started` naming a different `game_id` is a rematch's second game
  // starting: every per-game thing this screen holds is dropped before the
  // new id is recorded, in `_resetForNewGame`.
  String? _currentGameId;

  // C-246 rule 3: true while this device's own `rematch` request is open,
  // so a second tap sends nothing. Reset once the request settles, success
  // or failure alike -- `RoomController.rematch` never throws, so the
  // `await` below always resumes.
  bool _rematchInFlight = false;
  // Set as the first line of dispose(). _onRematchTap's own setState guard
  // reads this alongside `mounted`, synchronously true from the top of
  // dispose() rather than depending on the framework's own unmount
  // bookkeeping.
  bool _screenDisposed = false;

  // C-268 rules 3 to 5: landing cues (capturedOther, capturedMe, home) held
  // until the token lands on the board, flushed on travel reset or game-over,
  // falling back to kLandingCueFallback if no landing arrives. Dropped on
  // dispose and _resetForNewGame.
  final List<_PendingLandingCues> _pendingLandingCues = <_PendingLandingCues>[];

  // C-468 D5: one gloat on the capturer's yard. Pending entries wait for
  // the same three releases as the landing cues above. The sound timer
  // belongs to the captured seat; a replace or a removal before it fires
  // cancels it.
  BoardGloat? _gloat;
  int _gloatSerial = 0;
  Timer? _gloatSoundTimer;
  Timer? _gloatLifeTimer;
  final List<_PendingGloat> _pendingGloats = <_PendingGloat>[];

  // C-478 D5, C-500 D1: quick messages. The screen holds one line, the
  // newest, born from the server's `emote` frame only (mine included, no
  // optimistic draw) on its own [kChatBubbleLife] timer. It is drawn in the
  // header band on every body, and the room leaving PLAYING does not take it
  // down. A resync, a dropped link, a new game or the screen going clears it,
  // the way it clears the gloat. [_chatMuted] is owned here and bound both
  // ways to the sheet's switch.
  _ChatEntry? _chat;
  int _chatSerial = 0;
  final ValueNotifier<bool> _chatMuted = ValueNotifier<bool>(false);
  bool _chatCooling = false;
  Timer? _chatCoolTimer;

  // C-384: at most one safe-landing pill. Held like a landing cue until
  // the mover's onMoveLanded (or kLandingCueFallback, or a travel snap),
  // except under reduced motion, where it shows on the moved frame.
  // A newer qualifying move drops the one still waiting and, once it
  // shows, replaces the pill that is up. [_safeCueLandingsToIgnore]
  // counts landings of moves we already replaced, so an earlier move
  // cannot reveal the newer cue. [_safeCueEpoch] drops a snap-reveal
  // that a later clear or a newer move has superseded.
  _PendingSafeCue? _pendingSafeCue;
  int _safeCueLandingsToIgnore = 0;
  int _safeCueEpoch = 0;
  int _safeCueGeneration = 0;
  SafeCue? _safeCue;
  Timer? _safeCueHoldTimer;
  Timer? _safeCueFadeTimer;

  // C-270: moves currently in travel, and the end-card hold entered when
  // game_over arrives while travel is still in flight.
  int _travelCount = 0;
  bool _isEndHeld = false;
  final List<FeedbackCue> _heldGameOverCues = <FeedbackCue>[];
  Timer? _endHoldDwellTimer;
  Timer? _endHoldLimitTimer;

  // C-272 rule 4: true while the leave confirmation sheet is open, so a
  // second tap on the corner leave icon does not open a second sheet.
  bool _isLeaveConfirmOpen = false;

  // C-337 rule 3: true once this screen has announced the connection-lost
  // body for the entrance it is currently in, so a rebuild while it stays
  // up never repeats it. Dropped back to false the moment the body stops
  // showing, so the next entrance is announced again.
  bool _announcedConnectionLost = false;

  // C-304: stats fetched from the server's game_log when local gameTranscript
  // is incomplete, and request guards.
  GameStats? _fetchedStats;
  String? _fetchedStatsGameId;
  int _gameLogRequestsCount = 0;
  bool _gameLogFailedSocketDown = false;
  bool _gameLogFetchInFlight = false;
  // C-445 D3: the game the last game_log request was made for, so a snapshot
  // naming that same game does not forget the request already made for it.
  String? _gameLogTargetId;

  @override
  void initState() {
    super.initState();
    _currentGameId = widget.controller.room?.gameId;
    _notePlayingGame();
    final RoomSnapshot? mountRoom = widget.controller.room;
    if (mountRoom != null &&
        _timerStepsAction(mountRoom) == _TimerStepsAction.arm) {
      _timerPlayedMineVisible = true;
      _announceMountTimerPlayed = true;
    }
    _mountTurnFrame = _lastTurnFrame(widget.controller.gameTranscript);
    // C-442 D4': the turn the screen mounts onto counts as shown, so a
    // later snapshot of the same `k` plays nothing.
    final TurnState? shownTurn = mountRoom?.turn;
    if (shownTurn != null &&
        shownTurn.seat == widget.controller.seat &&
        shownTurn.phase == TurnPhase.awaitRoll) {
      _yourTurnPlayedK = shownTurn.k;
    }
    _seenRolls = List<(int k, int face)>.of(
      widget.controller.room?.recentRolls ?? const <(int k, int face)>[],
    );
    _syncSeatFaceMemory();
    widget.controller.addListener(_onControllerChanged);
    _chatMuted.addListener(_onChatMutedChanged);
    _frameSub = widget.controller.frames.listen(_onFrame);
    // K9: this screen can mount straight into a turn already mid-queue
    // (a resumed app, a reconnect) with no `turn` or `rolled` frame of
    // its own to have called `_rememberQueue` from. The queue the room
    // snapshot already carries is just as much "the queue the client
    // held for that seat" as one read off a frame, so seed it the same
    // way; the very next `turn` frame for this seat overwrites it as
    // usual.
    final TurnState? mountTurn = widget.controller.room?.turn;
    if (mountTurn != null) {
      _rememberQueue(mountTurn.seat, mountTurn.queue);
    }
    _syncCountdown();
    unawaited(_loadHintUsed());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeFetchGameLog();
    });
  }

  /// C-471 D5. A missing or unreadable store leaves the hint unused.
  Future<void> _loadHintUsed() async {
    String? stored;
    try {
      stored = await SessionMemory.hintUsedGameId();
    } on Object {
      stored = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _storedHintGameId = stored;
      _hintStoreRead = true;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_announceMountTimerPlayed) {
      _announceMountTimerPlayed = false;
      _announce(AppLocalizations.of(context).gameTimerPlayedMine);
    }
    _checkMountTurnCue();
    _releaseMoveGuard();
    _syncAutoMove();
    _syncConnectionLostAnnouncement();
  }

  @override
  void dispose() {
    _screenDisposed = true;
    _countdownTimer?.cancel();
    _autoMoveTimer?.cancel();
    _autoMoveCeilingTimer?.cancel();
    _rollNoAnswerTimer?.cancel();
    _noMoveTimer?.cancel();
    _timerPlayedOtherTimer?.cancel();
    _trayDeadTimer?.cancel();
    _dropPendingLandingCues();
    _clearSafeCue();
    _endHoldDwellTimer?.cancel();
    _endHoldLimitTimer?.cancel();
    _heldGameOverCues.clear();
    _isEndHeld = false;
    _mountTurnFrame = null;
    _frameSub?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    // C-468 D5: disposing before the 250 ms cancels the captured seat's sound.
    _removeGloat();
    _chatCoolTimer?.cancel();
    _clearChatBubbles();
    _chatMuted.removeListener(_onChatMutedChanged);
    // Not disposed: an open quick messages sheet can still write the switch.
    super.dispose();
  }

  /// C-236 rule 2: every cue `cuesForFrame` derives for this frame, played
  /// in list order, synchronously, through the one `FeedbackService`
  /// `FeedbackScope.of` finds. This is the only place a cue is played for a
  /// frame; the derivation is `cuesForFrame`'s and only its.
  ///
  /// Also arms or drops the no-move hold (rule 4, amended 4a/4b): a
  /// `rolled` naming my seat with an empty `legal` arms it with the face
  /// that `rolled` carried. Any other `rolled` that carries a value --
  /// another seat's roll included, since the die is shared -- drops an
  /// earlier hold; a `rolled` with no readable `value` changes nothing,
  /// there being no new face to take the die's place.
  void _onFrame(Frame frame) {
    // C-478 D5.4: a quick message is chatter. It changes no state here, owes
    // no cue and reaches none of the bookkeeping below.
    if (frame.type == 'emote') {
      _onEmoteFrame(frame);
      return;
    }
    // C-246 rule 5: a `game_started` naming a game this screen has not
    // already recorded is the next game after a rematch (or the very
    // first game, handled the same way since `_currentGameId` starts
    // null). Every per-game thing this screen holds is dropped before
    // this frame itself becomes the new list's first entry, so game two's
    // stats never carry a single frame of game one's.
    if (frame.type == 'game_started') {
      final String? gameId = _stringAt(frame.data, 'game_id');
      if (gameId != null && gameId != _currentGameId) {
        _resetForNewGame();
        _currentGameId = gameId;
      }
    }
    // C-445 D3: a snapshot (a `room` frame, C-442's meaning) of a PLAYING or
    // FINISHED game this screen has not recorded is the next game seen from
    // a phone that was away through the rematch, which never gets that
    // game's `game_started`. It starts the new game exactly as that frame
    // would, ahead of the re-base `_onSnapshotFrame` runs below, so the
    // re-base and the per-turn memory begin from the new game.
    if (frame.type == 'room') {
      RoomSnapshot? snapshot;
      try {
        snapshot = RoomSnapshot.fromJson(frame.data);
      } on SnapshotFormatException {
        snapshot = null;
      }
      final String? gameId = snapshot?.gameId;
      if (snapshot != null &&
          gameId != null &&
          snapshot.state != RoomState.lobby &&
          gameId != _currentGameId) {
        // The controller applies a snapshot before this screen sees its
        // frame, so the end card may already have asked for this game's
        // log; that request, its answer and its count belong to the game
        // the snapshot names and survive the reset.
        final bool keepLogFetch = _gameLogTargetId == gameId;
        final GameStats? keptStats = _fetchedStats;
        final String? keptStatsGameId = _fetchedStatsGameId;
        final int keptRequests = _gameLogRequestsCount;
        final bool keptFailed = _gameLogFailedSocketDown;
        final bool keptInFlight = _gameLogFetchInFlight;
        _resetForNewGame();
        _currentGameId = gameId;
        if (keepLogFetch) {
          _gameLogTargetId = gameId;
          _fetchedStats = keptStats;
          _fetchedStatsGameId = keptStatsGameId;
          _gameLogRequestsCount = keptRequests;
          _gameLogFailedSocketDown = keptFailed;
          _gameLogFetchInFlight = keptInFlight;
        }
      }
    }

    List<FeedbackCue> cues = cuesForFrame(
      frame,
      mySeat: widget.controller.seat,
    );
    // docs/PROTOCOL.md section 21 (C-362 Part B), order 365, K9/K10: must
    // run ahead of every use of `cues` below, since a 6 (or a bonus roll)
    // that still owes another roll makes `cuesForFrame` answer `noMove`
    // for this same `rolled` -- correct for an old server's genuine dead
    // roll, wrong here.
    if (_trackRollQueue(frame)) {
      cues = cues
          .where((FeedbackCue cue) => cue != FeedbackCue.noMove)
          .toList();
    }
    // C-474 D3.3: the announcement below plays before the notice arms, so
    // the reason is taken first and both read the same one.
    if (frame.type == 'rolled' && cues.contains(FeedbackCue.noMove)) {
      _resolveNoMoveReason(_intAt(frame.data, 'value'));
    }
    if (frame.type == 'turn' && cues.contains(FeedbackCue.yourTurn)) {
      final TurnState? liveTurn = widget.controller.room?.turn;
      if (liveTurn != null && liveTurn.seat == widget.controller.seat) {
        _yourTurnPlayedK = liveTurn.k;
      }
    }
    if (frame.type == 'game_over') {
      _playingGameId = null;
    }
    final FeedbackService feedback = FeedbackScope.of(context);
    final int? from = _intAt(frame.data, 'from');
    final int? to = _intAt(frame.data, 'to');
    final int? moverSeat = _intAt(frame.data, 'seat');
    final int? moverToken = _intAt(frame.data, 'token');
    final bool isTravellingMove =
        frame.type == 'moved' &&
        moverSeat != null &&
        moverToken != null &&
        from != null &&
        to != null &&
        from != to;
    if (isTravellingMove) {
      _travelCount++;
      _markLegTravelling(moverSeat, moverToken);
    }

    final bool zeroTravel =
        frame.type == 'moved' && from != null && to != null && from == to;

    // C-426 D3/D4 (order 428, docs/PROTOCOL.md section 22): the raw
    // `rolled` / `moved` data this screen already switches on above
    // carries `by: "timer"` exactly on a frame the turn expiry produced.
    // D6: no cue, no haptic, no sound changes for this -- every cue this
    // frame derived above already played (or will play, below) exactly
    // as it would have without `by`.
    if ((frame.type == 'rolled' || frame.type == 'moved') &&
        _stringAt(frame.data, 'by') == 'timer') {
      _onTimerPlayedFrame(moverSeat);
    }
    if (frame.type == 'game_over') {
      _dropTimerPlayedNoticesOnGameOver();
    }
    if (frame.type == 'room') {
      _onSnapshotFrame(frame);
    }

    if (frame.type == 'game_over' && _travelCount > 0) {
      _isEndHeld = true;
      _heldGameOverCues.addAll(cues);
      _endHoldLimitTimer?.cancel();
      _endHoldLimitTimer = Timer(kEndCardHoldLimit, _releaseEndHold);
      _clearPendingHold();
      if (mounted) {
        setState(() {});
      }
    } else if (frame.type == 'moved' &&
        !zeroTravel &&
        moverSeat != null &&
        moverToken != null) {
      final List<FeedbackCue> immediateCues = <FeedbackCue>[];
      final List<FeedbackCue> landingCues = <FeedbackCue>[];
      for (final FeedbackCue cue in cues) {
        if (_isLandingCue(cue)) {
          landingCues.add(cue);
        } else {
          immediateCues.add(cue);
        }
      }
      for (final FeedbackCue cue in immediateCues) {
        _playCue(feedback, cue);
      }
      if (landingCues.isNotEmpty) {
        _holdLandingCues(moverSeat, moverToken, landingCues);
      }
    } else {
      if (frame.type == 'game_over') {
        _flushPendingLandingCues();
        _maybeFetchGameLog();
      }
      for (final FeedbackCue cue in cues) {
        _playCue(feedback, cue);
      }
    }
    // C-468 D4: my own roll that left neither canMove nor noMove after the
    // queue filter. Those two clips are themselves the landing.
    _maybePlayOwnDieLand(frame, cues);
    // C-468 D5: a live moved with a capture. A snapshot never reaches
    // this, and a resync's ignored frames are skipped inside.
    if (frame.type == 'moved') {
      _considerGloat(frame);
    }
    if (frame.type == 'game_over') {
      // Still in the air: the landing may still start one. Already down:
      // the end card takes the board, so nothing pending may start later.
      _removeGloat(pending: _travelCount == 0);
    }
    // C-377 D5: a move or a passed turn while a throw is travelling
    // shortens that throw. It does not play a cue of its own (D9).
    if (frame.type == 'moved' || frame.type == 'turn_passed') {
      _hurryActiveThrow();
    }
    if (frame.type == 'rolled') {
      if (cues.contains(FeedbackCue.noMove)) {
        _armNoMoveHold(_intAt(frame.data, 'value'));
      } else if (_intAt(frame.data, 'value') != null) {
        _dropNoMoveHold();
        _dropTrayDead();
      }
    }

    // C-246 rule 6, C-316 rule 3: a seat removed by a host-forced start receives
    // a `player_left` naming its own seat and nothing further from the room
    // (docs/PROTOCOL.md section 16.9 rule 1). Pops with GameScreenResult.removed.
    if (frame.type == 'player_left') {
      final int? seatValue = _intAt(frame.data, 'seat');
      if (seatValue != null && seatValue == widget.controller.seat) {
        Navigator.of(context).pop(GameScreenResult.removed);
      }
    }

    if (frame.type == 'game_over') {
      _clearSafeCue();
    } else {
      _considerSafeCue(frame);
    }
  }

  static bool _isLandingCue(FeedbackCue cue) =>
      cue == FeedbackCue.capturedOther ||
      cue == FeedbackCue.capturedMe ||
      cue == FeedbackCue.home;

  void _playCues(List<FeedbackCue> cues) {
    if (!mounted || cues.isEmpty) {
      return;
    }
    final FeedbackService feedback = FeedbackScope.of(context);
    for (final FeedbackCue cue in cues) {
      _playCue(feedback, cue);
    }
  }

  /// C-337 rule 1: the one place a cue is both played through the feedback
  /// service and, when it is felt, announced to a screen reader in the same
  /// synchronous call. Every place on this screen that plays a cue -- the
  /// two loops in [_onFrame], [_playCues] (landing cues released on
  /// landing, on the fallback timer, or with the end-card hold), and the
  /// mount-time `yourTurn` in [_checkMountTurnCue] -- calls this and only
  /// this, so rule 1 holds by construction rather than by each site
  /// remembering to add its own announcement.
  void _playCue(
    FeedbackService feedback,
    FeedbackCue cue, {
    RoomSnapshot? snapshot,
  }) {
    feedback.play(cue);
    final String? message = _announcementFor(cue, snapshot: snapshot);
    if (message != null) {
      _announce(message);
    }
  }

  /// Rule 1's table. Rule 2: `canMove`, `step`, `invalidTap` and `tap` are
  /// not felt-event words for a screen reader -- the die and the legal
  /// tokens already carry labels -- and answer null here, which [_playCue]
  /// takes as "nothing to announce", never an empty string sent to
  /// [SemanticsService]. `tap` itself is never played through [_playCue]
  /// (C-422 D2/D3 play it straight off the die and token tap handlers, in
  /// the tap's own frame, not through the frame-driven table rule 1
  /// covers); the case below exists only so this switch stays exhaustive.
  /// `dieLand` and `gloat` are sound only and answer null (C-468 D4, D5).
  String? _announcementFor(FeedbackCue cue, {RoomSnapshot? snapshot}) {
    final AppLocalizations loc = AppLocalizations.of(context);
    switch (cue) {
      case FeedbackCue.yourTurn:
        return loc.gameYourTurnStale;
      case FeedbackCue.noMove:
        // C-474 D3.3: the same line the notice shows.
        return _noMoveLine(loc, _noMoveReason);
      case FeedbackCue.capturedOther:
        return loc.announceCapturedOther;
      case FeedbackCue.capturedMe:
        return loc.announceCapturedMe;
      case FeedbackCue.home:
        return loc.announceHome;
      case FeedbackCue.win:
        return loc.gameOverYouWin;
      case FeedbackCue.gameOver:
        return _gameOverAnnouncement(loc, snapshot: snapshot);
      case FeedbackCue.canMove:
      case FeedbackCue.step:
      case FeedbackCue.invalidTap:
      case FeedbackCue.tap:
      case FeedbackCue.dieLand:
      case FeedbackCue.gloat:
        return null;
    }
  }

  /// Rule 1's `gameOver` row: the winner's name, read off the room the same
  /// way [_gameOverBody] itself resolves it, or [AppLocalizations.gameOverEnded]
  /// when the winning seat cannot be named (no winner sent, or a winner
  /// naming a seat no longer in the room).
  ///
  /// C-442 D5: a snapshot that is being played for is not yet the room the
  /// controller holds when its frame reaches this screen, so the caller
  /// hands it in and the winner is read off it.
  String _gameOverAnnouncement(AppLocalizations loc, {RoomSnapshot? snapshot}) {
    final RoomSnapshot? room = snapshot ?? widget.controller.room;
    final int? winner = room?.winner;
    if (room != null && winner != null) {
      for (final SeatState seatState in room.seats) {
        if (seatState.seat == winner) {
          return loc.gameOverPlayerWins(seatState.name);
        }
      }
    }
    return loc.gameOverEnded;
  }

  /// The one call to [SemanticsService.sendAnnouncement] every announcement
  /// on this screen -- a felt cue, the die's no-answer line, the
  /// connection-lost body -- goes through, the same shape
  /// [_announceAutoMove] already uses.
  void _announce(String message) {
    if (!mounted || message.isEmpty) {
      return;
    }
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  /// C-293 rule 3: plays `your_turn` once at mount if the last `turn` frame
  /// in `gameTranscript` at mount named my seat and the room still shows my
  /// turn awaiting a roll. Guarded to run once.
  void _checkMountTurnCue() {
    if (_checkedMountTurnCue) {
      return;
    }
    _checkedMountTurnCue = true;
    final Frame? mountTurn = _mountTurnFrame;
    if (mountTurn == null) {
      return;
    }
    final int? mySeat = widget.controller.seat;
    if (mySeat == null || _intAt(mountTurn.data, 'seat') != mySeat) {
      return;
    }
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null ||
        turn.seat != mySeat ||
        turn.phase != TurnPhase.awaitRoll) {
      return;
    }
    _yourTurnPlayedK = turn.k;
    _playCue(FeedbackScope.of(context), FeedbackCue.yourTurn);
  }

  static Frame? _lastTurnFrame(List<Frame> transcript) {
    for (int i = transcript.length - 1; i >= 0; i--) {
      if (transcript[i].type == 'turn') {
        return transcript[i];
      }
    }
    return null;
  }

  void _holdLandingCues(int seat, int token, List<FeedbackCue> cues) {
    final _PendingLandingCues entry = _PendingLandingCues(
      seat: seat,
      token: token,
      cues: cues,
    );
    entry.fallbackTimer = Timer(kLandingCueFallback, () {
      _onLandingCueFallback(entry);
    });
    _pendingLandingCues.add(entry);
  }

  void _onLandingCueFallback(_PendingLandingCues entry) {
    if (!_pendingLandingCues.remove(entry)) {
      return;
    }
    entry.fallbackTimer?.cancel();
    entry.fallbackTimer = null;
    _playCues(entry.cues);
  }

  void _onBoardMoveLanded(int seat, int token) {
    _markLegLanded(seat, token);
    _maybeStartAutoMoveAfterWalk(seat, token);
    if (_travelCount > 0) {
      _travelCount--;
    }
    final int index = _pendingLandingCues.indexWhere(
      (entry) => entry.seat == seat && entry.token == token,
    );
    if (index != -1) {
      final _PendingLandingCues entry = _pendingLandingCues.removeAt(index);
      entry.fallbackTimer?.cancel();
      entry.fallbackTimer = null;
      _playCues(entry.cues);
    }
    // C-468 D5: the same landing that releases the cues starts the gloat.
    _releaseGloatForLanding(seat, token);
    if (_isEndHeld && _travelCount == 0 && _endHoldDwellTimer == null) {
      _endHoldDwellTimer = Timer(kEndCardDwell, _releaseEndHold);
    }
    _onSafeCueLanded(seat, token);
  }

  void _onBoardTravelReset() {
    _travelCount = 0;
    _safeCueLandingsToIgnore = 0;
    // C-468 D5: a snap is one of the three releases. The board calls this
    // from its own update, so the face is applied on the next frame.
    _flushPendingGloats();
    // C-408 D7: a snap draws every token at truth at once (C-252 rule 2),
    // so every leg this screen was still waiting on has, in effect,
    // landed. Drop the bookkeeping and let a hold still waiting on one of
    // them start now.
    _travellingLegs.clear();
    if (_autoMoveAwaitingWalk) {
      _startAutoMoveTimer();
    }
    if (_isEndHeld) {
      _dropPendingSafeCue();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isEndHeld) {
          return;
        }
        _releaseEndHold();
      });
    } else {
      _flushPendingLandingCues();
      _revealPendingSafeCueAfterFrame();
    }
  }

  void _releaseEndHold() {
    if (!_isEndHeld) {
      return;
    }
    _isEndHeld = false;
    _endHoldDwellTimer?.cancel();
    _endHoldDwellTimer = null;
    _endHoldLimitTimer?.cancel();
    _endHoldLimitTimer = null;
    // C-468 D5: the end card replaces the playing board.
    _removeGloat();
    _flushPendingLandingCues();
    final List<FeedbackCue> cues = List<FeedbackCue>.from(_heldGameOverCues);
    _heldGameOverCues.clear();
    _playCues(cues);
    if (mounted) {
      setState(() {});
    }
    _maybeFetchGameLog();
  }

  void _flushPendingLandingCues() {
    if (_pendingLandingCues.isEmpty) {
      return;
    }
    final List<_PendingLandingCues> entries = List<_PendingLandingCues>.from(
      _pendingLandingCues,
    );
    _pendingLandingCues.clear();
    for (final _PendingLandingCues entry in entries) {
      entry.fallbackTimer?.cancel();
      entry.fallbackTimer = null;
      _playCues(entry.cues);
    }
  }

  void _dropPendingLandingCues() {
    for (final _PendingLandingCues entry in _pendingLandingCues) {
      entry.fallbackTimer?.cancel();
      entry.fallbackTimer = null;
    }
    _pendingLandingCues.clear();
  }

  /// C-468 D4. A `rolled` for my seat whose cues, after the queue filter,
  /// hold neither `canMove` nor `noMove`. The 6 that still owes a roll and
  /// has nothing to move is the case that used to land in silence.
  void _maybePlayOwnDieLand(Frame frame, List<FeedbackCue> cues) {
    if (frame.type != 'rolled' || widget.controller.hasDesynced) {
      return;
    }
    final int? seat = _intAt(frame.data, 'seat');
    final int? mySeat = widget.controller.seat;
    if (seat == null || mySeat == null || seat != mySeat) {
      return;
    }
    if (cues.contains(FeedbackCue.canMove) ||
        cues.contains(FeedbackCue.noMove)) {
      return;
    }
    _playCue(FeedbackScope.of(context), FeedbackCue.dieLand);
  }

  /// C-468 D4. One sound per throw. A hurried throw still lands once.
  void _playDieLandOnce(_QueuedThrow thrown) {
    if (thrown.dieLandPlayed || !mounted || _screenDisposed) {
      return;
    }
    thrown.dieLandPlayed = true;
    _playCue(FeedbackScope.of(context), FeedbackCue.dieLand);
  }

  /// C-468 D5. A live `moved` whose `captured` list is non-empty. Empty,
  /// missing, a snapshot and a frame ignored by a resync do not start one.
  void _considerGloat(Frame frame) {
    if (widget.controller.hasDesynced) {
      return;
    }
    final Object? captured = frame.data['captured'];
    if (captured is! List || captured.isEmpty) {
      return;
    }
    final int? seat = _intAt(frame.data, 'seat');
    final int? token = _intAt(frame.data, 'token');
    if (seat == null || token == null || seat < 0 || seat > 3) {
      return;
    }
    final List<int> capturedSeats = <int>[];
    for (final Object? entry in captured) {
      if (entry is Map) {
        final Object? entrySeat = entry['seat'];
        if (entrySeat is int) {
          capturedSeats.add(entrySeat);
        }
      }
    }
    _holdGloat(seat, token, capturedSeats);
  }

  void _holdGloat(int seat, int token, List<int> capturedSeats) {
    final _PendingGloat pending = _PendingGloat(
      seat: seat,
      token: token,
      capturedSeats: capturedSeats,
    );
    pending.fallbackTimer = Timer(kLandingCueFallback, () {
      if (!_pendingGloats.remove(pending)) {
        return;
      }
      pending.fallbackTimer = null;
      _beginGloat(pending);
    });
    _pendingGloats.add(pending);
  }

  void _releaseGloatForLanding(int seat, int token) {
    final int index = _pendingGloats.indexWhere(
      (entry) => entry.seat == seat && entry.token == token,
    );
    if (index == -1) {
      return;
    }
    final _PendingGloat pending = _pendingGloats.removeAt(index);
    pending.fallbackTimer?.cancel();
    pending.fallbackTimer = null;
    _beginGloat(pending);
  }

  void _flushPendingGloats() {
    if (_pendingGloats.isEmpty) {
      return;
    }
    final List<_PendingGloat> entries = List<_PendingGloat>.of(_pendingGloats);
    _pendingGloats.clear();
    for (final _PendingGloat entry in entries) {
      entry.fallbackTimer?.cancel();
      entry.fallbackTimer = null;
      _beginGloat(entry);
    }
  }

  void _dropPendingGloats() {
    for (final _PendingGloat entry in _pendingGloats) {
      entry.fallbackTimer?.cancel();
      entry.fallbackTimer = null;
    }
    _pendingGloats.clear();
  }

  /// Starts the face and, when this screen's seat was captured, the sound
  /// 250 ms later. A gloat already up is replaced, and its sound goes with
  /// it if the 250 ms had not elapsed. C-468 D5.
  void _beginGloat(_PendingGloat pending) {
    _gloatSoundTimer?.cancel();
    _gloatSoundTimer = null;
    _gloatLifeTimer?.cancel();
    _gloatLifeTimer = null;
    _gloatSerial++;
    final int serial = _gloatSerial;
    final int seat = pending.seat;
    _gloat = BoardGloat(seat: seat, serial: serial);
    _scheduleGloatRebuild();
    final int? mySeat = widget.controller.seat;
    if (mySeat != null &&
        mySeat != seat &&
        pending.capturedSeats.contains(mySeat)) {
      _gloatSoundTimer = Timer(kCaptureGloatSoundDelay, () {
        _gloatSoundTimer = null;
        if (!mounted || _screenDisposed || _gloat?.serial != serial) {
          return;
        }
        _playCue(FeedbackScope.of(context), FeedbackCue.gloat);
      });
    }
    _gloatLifeTimer = Timer(kCaptureGloatLife, () {
      _gloatLifeTimer = null;
      if (_gloat?.serial != serial) {
        return;
      }
      _gloat = null;
      _scheduleGloatRebuild();
    });
  }

  /// The board reports a snap from inside its own update, so a setState
  /// here has to wait until that frame is done. Same pattern as the
  /// auto-move banner. C-468 D5.
  void _scheduleGloatRebuild() {
    if (!mounted || _screenDisposed) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_screenDisposed) {
          setState(() {});
        }
      });
      return;
    }
    setState(() {});
  }

  /// Game over, resync, a new game, dispose. Cancels the sound when the
  /// 250 ms has not elapsed. [pending] false leaves a gloat that is still
  /// waiting for its landing. C-468 D5.
  void _removeGloat({bool pending = true}) {
    _gloatSoundTimer?.cancel();
    _gloatSoundTimer = null;
    _gloatLifeTimer?.cancel();
    _gloatLifeTimer = null;
    if (pending) {
      _dropPendingGloats();
    }
    if (_gloat == null) {
      return;
    }
    _gloat = null;
    _scheduleGloatRebuild();
  }

  /// C-478 D5.4 and C-500 D1 to D3. An `emote` push shows a line when the
  /// room is PLAYING, FINISHED or a rematch LOBBY, the seat is known, the id
  /// is one of the twelve and the player has not hidden the others (mine are
  /// never hidden). Anything else shows nothing and says nothing. A line that
  /// is shown replaces the one up, from any seat, and starts its life over; a
  /// line that is not shown never removes the one up.
  void _onEmoteFrame(Frame frame) {
    final RoomSnapshot? room = widget.controller.room;
    final int? seat = _intAt(frame.data, 'seat');
    final String? id = _stringAt(frame.data, 'emote');
    if (room == null || seat == null || id == null) {
      return;
    }
    final bool afterGame =
        room.state == RoomState.finished ||
        (room.state == RoomState.lobby && room.rematch != null);
    if (room.state != RoomState.playing && !afterGame) {
      return;
    }
    // A seat that left after the game still says good game: the end card and
    // the held end also know the seats of the game they are showing.
    final bool known =
        room.seats.any((SeatState s) => s.seat == seat) ||
        (afterGame &&
            (widget.controller.lastFinished?.seats.any(
                  (SeatState s) => s.seat == seat,
                ) ??
                false));
    if (!known || !kQuickChatIds.contains(id)) {
      return;
    }
    if (_chatMuted.value && seat != widget.controller.seat) {
      return;
    }
    _chatSerial++;
    final int serial = _chatSerial;
    _chat?.timer.cancel();
    _chat = _ChatEntry(
      id: id,
      seat: seat,
      serial: serial,
      // The insets of this line's own moment, kept for its whole life.
      // C-500 D4.
      clearOfChatButton: _showsChatButton(widget.controller, room),
      timer: Timer(kChatBubbleLife, () {
        if (_chat?.serial != serial) {
          return;
        }
        _chat = null;
        _scheduleGloatRebuild();
      }),
    );
    _scheduleGloatRebuild();
  }

  /// The chat button's own condition: on the header row while a seated player
  /// is connected to a table in play. C-500 D4.
  bool _showsChatButton(RoomController controller, RoomSnapshot? room) {
    return controller.phase == RoomPhase.connected &&
        room != null &&
        room.state == RoomState.playing &&
        controller.seat != null;
  }

  /// The line goes, with its timer. A resync, a resume, a new game, dispose.
  /// C-478 D5.4, C-500 D3.
  void _clearChatBubbles() {
    final _ChatEntry? line = _chat;
    if (line == null) {
      return;
    }
    line.timer.cancel();
    _chat = null;
    _scheduleGloatRebuild();
  }

  /// Hiding the others takes down another seat's line that is up.
  void _onChatMutedChanged() {
    if (_chatMuted.value &&
        _chat != null &&
        _chat?.seat != widget.controller.seat) {
      _chat?.timer.cancel();
      _chat = null;
    }
    _scheduleGloatRebuild();
  }

  /// C-500 D1. The one line, the name resolved against the live seats and
  /// then the game just finished. A line whose seat has no name in either is
  /// not drawn.
  EndCardChatLine? _chatLineOf(
    AppLocalizations loc,
    RoomSnapshot? room,
    RoomSnapshot? finished,
  ) {
    final _ChatEntry? entry = _chat;
    if (entry == null) {
      return null;
    }
    final String? line = quickChatLine(loc, entry.id);
    if (line == null) {
      return null;
    }
    for (final RoomSnapshot? source in <RoomSnapshot?>[room, finished]) {
      for (final SeatState s in source?.seats ?? const <SeatState>[]) {
        if (s.seat == entry.seat) {
          return EndCardChatLine(
            seat: entry.seat,
            name: s.name,
            text: line,
            serial: entry.serial,
          );
        }
      }
    }
    return null;
  }

  /// C-478 D5.1. A tap while the button rests plays the invalid-tap cue and
  /// opens nothing.
  void _onChatButtonTap() {
    if (_chatCooling) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    showQuickChatSheet(context, onPick: _onChatPick, muted: _chatMuted);
  }

  /// C-478 D5.3. No optimistic bubble: the server's copy of the message
  /// comes back as an `emote` frame like everyone else's. The rest starts
  /// when that copy has come back, and a refusal shows and plays nothing.
  Future<void> _onChatPick(String id) async {
    final bool sent = await widget.controller.sendEmote(id);
    if (!sent || !mounted || _screenDisposed) {
      return;
    }
    _chatCoolTimer?.cancel();
    setState(() {
      _chatCooling = true;
    });
    _chatCoolTimer = Timer(kQuickChatCooldown, () {
      _chatCoolTimer = null;
      if (!mounted || _screenDisposed) {
        return;
      }
      setState(() {
        _chatCooling = false;
      });
    });
  }

  /// C-384 S1 and S2. A `moved` frame with an empty `captured`, a
  /// main-track `to`, and at least one other seat's token already on
  /// that absolute square. Safe square wins over a pair.
  void _considerSafeCue(Frame frame) {
    if (frame.type != 'moved') {
      return;
    }
    final int? seat = _intAt(frame.data, 'seat');
    final int? token = _intAt(frame.data, 'token');
    final int? to = _intAt(frame.data, 'to');
    if (seat == null ||
        token == null ||
        to == null ||
        seat < 0 ||
        seat > 3 ||
        to < 0 ||
        to > 51) {
      return;
    }
    final Object? captured = frame.data['captured'];
    if (captured is! List || captured.isNotEmpty) {
      return;
    }
    final RoomSnapshot? room = widget.controller.room;
    if (room == null || !_otherSeatOnSquare(room, seat, to)) {
      return;
    }
    _armSafeCue(
      seat: seat,
      token: token,
      progress: to,
      star: _cellIsSafe(cellFor(seat: seat, progress: to)),
    );
  }

  void _armSafeCue({
    required int seat,
    required int token,
    required int progress,
    required bool star,
  }) {
    final _PendingSafeCue pending = _PendingSafeCue(
      seat: seat,
      token: token,
      progress: progress,
      star: star,
    );
    _safeCueEpoch++;
    if (MediaQuery.disableAnimationsOf(context)) {
      _dropPendingSafeCue();
      _safeCueLandingsToIgnore = 0;
      _revealSafeCue(pending);
      return;
    }
    if (_pendingSafeCue != null) {
      _safeCueLandingsToIgnore++;
      _pendingSafeCue!.fallbackTimer?.cancel();
      _pendingSafeCue!.fallbackTimer = null;
    }
    _pendingSafeCue = pending;
    pending.fallbackTimer = Timer(kLandingCueFallback, () {
      if (!identical(_pendingSafeCue, pending)) {
        return;
      }
      _pendingSafeCue = null;
      pending.fallbackTimer = null;
      _revealSafeCue(pending);
    });
  }

  void _onSafeCueLanded(int seat, int token) {
    if (_safeCueLandingsToIgnore > 0) {
      _safeCueLandingsToIgnore--;
      return;
    }
    final _PendingSafeCue? pending = _pendingSafeCue;
    if (pending == null || pending.seat != seat || pending.token != token) {
      return;
    }
    pending.fallbackTimer?.cancel();
    pending.fallbackTimer = null;
    _pendingSafeCue = null;
    _revealSafeCue(pending);
  }

  /// A snap drops the in-flight move, the same moment landing cues flush.
  /// Show the pill then, unless a newer move or a clear already won.
  void _revealPendingSafeCueAfterFrame() {
    final _PendingSafeCue? pending = _pendingSafeCue;
    if (pending == null) {
      return;
    }
    pending.fallbackTimer?.cancel();
    pending.fallbackTimer = null;
    _pendingSafeCue = null;
    final int epoch = _safeCueEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _screenDisposed || epoch != _safeCueEpoch) {
        return;
      }
      _revealSafeCue(pending);
    });
  }

  void _dropPendingSafeCue() {
    _pendingSafeCue?.fallbackTimer?.cancel();
    _pendingSafeCue?.fallbackTimer = null;
    _pendingSafeCue = null;
  }

  void _revealSafeCue(_PendingSafeCue pending) {
    pending.fallbackTimer?.cancel();
    pending.fallbackTimer = null;
    _safeCueHoldTimer?.cancel();
    _safeCueFadeTimer?.cancel();
    _safeCueFadeTimer = null;
    _safeCueGeneration++;
    final int generation = _safeCueGeneration;
    final SafeCue cue = SafeCue(
      reason: pending.star ? SafeCueReason.star : SafeCueReason.pair,
      seat: pending.seat,
      progress: pending.progress,
      generation: generation,
      fade: kSafeCueFade,
    );
    if (!mounted || _screenDisposed) {
      _safeCue = cue;
      return;
    }
    setState(() {
      _safeCue = cue;
    });
    _safeCueHoldTimer = Timer(kSafeCueHold, () {
      _onSafeCueHoldEnded(generation);
    });
  }

  void _onSafeCueHoldEnded(int generation) {
    _safeCueHoldTimer = null;
    if (!mounted || _screenDisposed) {
      return;
    }
    final SafeCue? cue = _safeCue;
    if (cue == null || cue.generation != generation) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _safeCue = null;
      });
      return;
    }
    setState(() {
      _safeCue = SafeCue(
        reason: cue.reason,
        seat: cue.seat,
        progress: cue.progress,
        generation: cue.generation,
        fade: cue.fade,
        fading: true,
      );
    });
    _safeCueFadeTimer = Timer(kSafeCueFade, () {
      _safeCueFadeTimer = null;
      if (!mounted || _screenDisposed) {
        return;
      }
      if (_safeCue?.generation != generation) {
        return;
      }
      setState(() {
        _safeCue = null;
      });
    });
  }

  /// New game, leaving the table, game over. Cancels a pill that has not
  /// been shown yet as well as one that is up.
  void _clearSafeCue() {
    _safeCueEpoch++;
    _safeCueLandingsToIgnore = 0;
    _dropPendingSafeCue();
    _safeCueHoldTimer?.cancel();
    _safeCueHoldTimer = null;
    _safeCueFadeTimer?.cancel();
    _safeCueFadeTimer = null;
    if (_safeCue == null) {
      return;
    }
    _safeCue = null;
    if (mounted && !_screenDisposed) {
      setState(() {});
    }
  }

  /// C-259 rule 2: the board's own `onTokenStep`, fired once as the drawn
  /// token actually arrives on each square. Plays exactly one
  /// `FeedbackCue.step` when [stepSeat] is `controller.seat` -- the same
  /// seat this screen passes to `cuesForFrame` as `mySeat` -- and nothing
  /// for any other seat's token, including when `controller.seat` is null.
  void _onBoardTokenStep(RoomController controller, int stepSeat) {
    if (stepSeat != controller.seat) {
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.step);
  }

  /// C-246 rule 5: drops every per-game thing this screen holds -- the
  /// frame list feeding `computeGameStats`, the no-move hold and its held
  /// face, the pending auto-move and the k it was armed for, the move-sent
  /// guard, the roll-wait tumble and its no-answer line, and (C-426, order
  /// 428) both timer-played notices -- a new game's first turn starts this
  /// screen fresh, which is distinct from D3's own "does NOT clear when my
  /// next turn begins" (that rule is about the next turn of the same game).
  /// The countdown memo is untouched on purpose (rule 5's own text, "not
  /// simplified"): `_syncCountdown` already restarts it on its own the
  /// moment the room stops showing a playing board (FINISHED, then the
  /// rematch LOBBY in between), which a new game always passes through
  /// first.
  void _resetForNewGame() {
    _noMoveTimer?.cancel();
    _noMoveTimer = null;
    _noMoveVisible = false;
    _noMoveFace = null;
    _noMoveReason = NoMoveReason.plain;
    _timerPlayedOtherTimer?.cancel();
    _timerPlayedOtherTimer = null;
    _timerPlayedMineVisible = false;
    _timerPlayedOtherName = null;
    _autoMoveTimer?.cancel();
    _autoMoveTimer = null;
    _autoMoveCeilingTimer?.cancel();
    _autoMoveCeilingTimer = null;
    _pendingAutoMoveToken = null;
    _pendingAutoMoveFace = null;
    _autoMoveHandledK = null;
    _autoMoveHandledQueue = null;
    _autoMoveAwaitingWalk = false;
    _travellingLegs.clear();
    _moveSentForK = null;
    _moveSentForQueue = null;
    _moveGuardSerial = null;
    _moveSentToken = null;
    _rollNoAnswerTimer?.cancel();
    _rollNoAnswerTimer = null;
    _rollWaitK = null;
    _rollNoAnswer = false;
    _clearThrows();
    _syncSeatFaceMemory();
    _lastKnownQueue.clear();
    _yourTurnPlayedK = null;
    _dropDeadCandidate();
    _trayDeadTimer?.cancel();
    _trayDeadTimer = null;
    _trayDeadSeat = null;
    _trayDeadFaces = null;
    _facePick = null;
    _shownHint = null;
    _dropPendingLandingCues();
    _removeGloat();
    _clearChatBubbles();
    // The cooldown is the server's cadence (PROTOCOL section 25 rule 3), not
    // the game's: a new game leaves it running.
    _clearSafeCue();
    _endHoldDwellTimer?.cancel();
    _endHoldDwellTimer = null;
    _endHoldLimitTimer?.cancel();
    _endHoldLimitTimer = null;
    _heldGameOverCues.clear();
    _isEndHeld = false;
    _travelCount = 0;
    _fetchedStats = null;
    _fetchedStatsGameId = null;
    _gameLogRequestsCount = 0;
    _gameLogFailedSocketDown = false;
    _gameLogFetchInFlight = false;
    _gameLogTargetId = null;
  }

  /// C-474 D1: takes the reason for a notice arming on [face]. A notice
  /// already up on the same face keeps the reason it was armed with. `F` is
  /// the live queue when it is not empty, otherwise just the face; `U` is
  /// read off my own seat's tokens in the room the controller holds.
  void _resolveNoMoveReason(int? face) {
    if (_noMoveVisible && _noMoveFace == face) {
      return;
    }
    final RoomSnapshot? room = widget.controller.room;
    final int? mySeat = widget.controller.seat;
    List<int>? mine;
    if (room != null && mySeat != null) {
      for (final SeatState seatState in room.seats) {
        if (seatState.seat == mySeat) {
          mine = seatState.tokens;
        }
      }
    }
    final List<int> queue = room?.turn?.queue ?? const <int>[];
    final List<int> faces = queue.isNotEmpty
        ? List<int>.from(queue)
        : <int>[?face];
    _noMoveReason = mine == null
        ? NoMoveReason.plain
        : noMoveReason(myTokens: mine, faces: faces);
  }

  String _noMoveLine(AppLocalizations loc, NoMoveReason reason) {
    switch (reason) {
      case NoMoveReason.needSix:
        return loc.gameNoMoveNeedSix;
      case NoMoveReason.needExact:
        return loc.gameNoMoveNeedExact;
      case NoMoveReason.plain:
        return loc.gameNoMove;
    }
  }

  void _armNoMoveHold(int? face) {
    _resolveNoMoveReason(face);
    _noMoveTimer?.cancel();
    _noMoveTimer = Timer(_noMoveHold, _dropNoMoveHold);
    if (_noMoveVisible && _noMoveFace == face) {
      return;
    }
    setState(() {
      _noMoveVisible = true;
      _noMoveFace = face;
    });
  }

  void _dropNoMoveHold() {
    _noMoveTimer?.cancel();
    _noMoveTimer = null;
    if (!mounted || !_noMoveVisible) {
      return;
    }
    setState(() {
      _noMoveVisible = false;
      _noMoveFace = null;
      _noMoveReason = NoMoveReason.plain;
    });
  }

  /// C-426 D3/D4 (order 428, docs/PROTOCOL.md section 22): called from
  /// [_onFrame] for every `rolled` or `moved` whose raw data carries
  /// `by == "timer"` exactly -- D7 means any other value, including
  /// absent, never reaches here at all.
  ///
  /// My own seat arms [_timerPlayedMineVisible] and announces once to
  /// TalkBack, but only while it was hidden: D3's "a later timer step for
  /// my seat keeps it up (re-armed, same text)" means a seat already
  /// shown gets no second announcement and no other change. Clearing it
  /// happens at each of D3's own three call sites (a sent die tap, a sent
  /// token tap, game over) and in [_resetForNewGame], never here.
  ///
  /// Another seat arms [_timerPlayedOtherName] for [_timerPlayedOtherHold]
  /// and announces every time (D4 carries no "from hidden" qualifier,
  /// unlike D3) -- but only when that seat still has an entry in
  /// `room.seats` (present, not departed) with `connected == true`
  /// (online); a departed or an offline seat already has its own mark and
  /// gets nothing new here.
  void _onTimerPlayedFrame(int? seat) {
    if (seat == null || !mounted) {
      return;
    }
    final int? mySeat = widget.controller.seat;
    if (mySeat != null && seat == mySeat) {
      _showTimerPlayedMine();
      return;
    }
    final RoomSnapshot? room = widget.controller.room;
    SeatState? seatState;
    if (room != null) {
      for (final SeatState candidate in room.seats) {
        if (candidate.seat == seat) {
          seatState = candidate;
          break;
        }
      }
    }
    if (seatState == null || !seatState.connected) {
      return;
    }
    final String name = seatState.name;
    _timerPlayedOtherTimer?.cancel();
    _timerPlayedOtherTimer = Timer(
      _timerPlayedOtherHold,
      _dropTimerPlayedOther,
    );
    setState(() {
      _timerPlayedOtherName = name;
    });
    _announce(AppLocalizations.of(context).gameTimerPlayedOther(name));
  }

  /// Arms my own notice and announces it once, only while it was hidden.
  /// Shared by the live `by: "timer"` path and the snapshot path below, so
  /// both obey the same "announce only when armed from hidden" rule.
  void _showTimerPlayedMine() {
    if (!mounted || _timerPlayedMineVisible) {
      return;
    }
    setState(() {
      _timerPlayedMineVisible = true;
    });
    _announce(AppLocalizations.of(context).gameTimerPlayedMine);
  }

  /// What my own seat's `timer_steps` in [room] asks of the notice
  /// (docs/PROTOCOL.md section 23 rule 6, C-432 D4). Only my own seat is
  /// read; another seat's count never raises a notice.
  _TimerStepsAction _timerStepsAction(RoomSnapshot room) {
    if (room.state == RoomState.finished) {
      return _TimerStepsAction.drop;
    }
    if (room.state != RoomState.playing) {
      return _TimerStepsAction.none;
    }
    final int? mySeat = widget.controller.seat;
    if (mySeat == null) {
      return _TimerStepsAction.none;
    }
    for (final SeatState candidate in room.seats) {
      if (candidate.seat != mySeat) {
        continue;
      }
      final int? steps = candidate.timerSteps;
      if (steps == null) {
        return _TimerStepsAction.none;
      }
      return steps > 0 ? _TimerStepsAction.arm : _TimerStepsAction.drop;
    }
    return _TimerStepsAction.none;
  }

  /// C-432 D4: a `room` frame is a snapshot, which is how the answer to a
  /// `resume` reaches this screen. It reaches [_onFrame] before the
  /// controller has replaced its own room with it, so the frame's data is
  /// decoded here with the same [RoomSnapshot.fromJson] the controller
  /// uses; a frame that does not decode is one the controller itself
  /// discards, and it changes nothing here either. A FINISHED snapshot
  /// shows no notice, so it also drops one a missed `game_over` left up.
  void _onSnapshotFrame(Frame frame) {
    final RoomSnapshot room;
    try {
      room = RoomSnapshot.fromJson(frame.data);
    } on SnapshotFormatException {
      return;
    }
    switch (_timerStepsAction(room)) {
      case _TimerStepsAction.arm:
        _showTimerPlayedMine();
      case _TimerStepsAction.drop:
        if (_timerPlayedMineVisible && mounted) {
          setState(() {
            _timerPlayedMineVisible = false;
          });
        }
      case _TimerStepsAction.none:
        break;
    }
    _rebaseFromSnapshot(room);
  }

  /// C-442: remembers the game this screen is showing as PLAYING, so a
  /// FINISHED snapshot of that same game can tell a game that ended while
  /// the screen was away from an end card the player opened the app onto.
  void _notePlayingGame() {
    final RoomSnapshot? room = widget.controller.room;
    if (room != null && room.state == RoomState.playing) {
      final String? gameId = room.gameId;
      if (gameId != null) {
        _playingGameId = gameId;
      }
    }
  }

  /// C-442 D2, D4, D5: what a snapshot of the room does to the per-turn
  /// memory this screen keeps. A snapshot replaces the room underneath
  /// frames this screen never saw, so each thing a live frame would have
  /// set is set again from the snapshot itself.
  ///
  /// The queue the screen remembers for the snapshot's turn seat is the
  /// snapshot's own, exactly as the mount seeds it (K9); a dead-end
  /// candidate banked from frames before the replacement is dropped, since
  /// the `turn_passed` that would resolve it can no longer follow.
  ///
  /// `yourTurn` plays once for my `await_roll`, unless this screen already
  /// played it for that same `k`. A FINISHED snapshot of the game this
  /// screen was showing as PLAYING, whose `game_over` never reached it,
  /// plays the cue that `game_over` would have. No other cue comes from a
  /// snapshot of a PLAYING room (PROTOCOL section 8 rule 4, C-293 rule 3).
  void _rebaseFromSnapshot(RoomSnapshot room) {
    _dropDeadCandidate();
    final TurnState? turn = room.turn;
    if (turn != null) {
      _rememberQueue(turn.seat, turn.queue);
    }
    if (!mounted) {
      return;
    }
    final int? mySeat = widget.controller.seat;
    if (mySeat == null) {
      return;
    }
    if (room.state == RoomState.playing) {
      if (turn != null &&
          turn.seat == mySeat &&
          turn.phase == TurnPhase.awaitRoll &&
          _yourTurnPlayedK != turn.k) {
        _yourTurnPlayedK = turn.k;
        _playCue(FeedbackScope.of(context), FeedbackCue.yourTurn);
      }
      return;
    }
    if (room.state == RoomState.finished) {
      final String? gameId = room.gameId;
      final int? winner = room.winner;
      if (gameId == null || gameId != _playingGameId) {
        return;
      }
      _playingGameId = null;
      if (winner == null) {
        return;
      }
      _playCue(
        FeedbackScope.of(context),
        winner == mySeat ? FeedbackCue.win : FeedbackCue.gameOver,
        snapshot: room,
      );
    }
  }

  void _dropTimerPlayedOther() {
    _timerPlayedOtherTimer = null;
    if (!mounted || _timerPlayedOtherName == null) {
      return;
    }
    setState(() {
      _timerPlayedOtherName = null;
    });
  }

  /// C-426 D3: game over is one of the notice's three clearing events for
  /// my own seat. D4 names no such event for another seat's 2500ms hold,
  /// but the game has ended either way, so the same frame drops both --
  /// no later frame for this game is coming to re-arm either one.
  void _dropTimerPlayedNoticesOnGameOver() {
    _timerPlayedOtherTimer?.cancel();
    _timerPlayedOtherTimer = null;
    if (!_timerPlayedMineVisible && _timerPlayedOtherName == null) {
      return;
    }
    if (!mounted) {
      _timerPlayedMineVisible = false;
      _timerPlayedOtherName = null;
      return;
    }
    setState(() {
      _timerPlayedMineVisible = false;
      _timerPlayedOtherName = null;
    });
  }

  // == docs/PROTOCOL.md section 21 (C-362 Part B), order 365: the roll ==
  // == queue's own bookkeeping (K9/K10).                               ==

  void _rememberQueue(int seat, List<int> queue) {
    _lastKnownQueue[seat] = List<int>.from(queue);
  }

  void _dropDeadCandidate() {
    _deadCandidateSeat = null;
    _deadCandidateQueueBefore = null;
    _deadCandidateFace = null;
    _deadCandidateFromMove = false;
  }

  bool _sameFaces(List<int>? a, List<int>? b) {
    if (a == null || b == null) {
      return a == b;
    }
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// True when [turn] is this seat in await_move at [k] with [queue].
  bool _sameMoveDecision(TurnState? turn, int? k, List<int>? queue) {
    if (turn == null || k == null) {
      return false;
    }
    return turn.seat == widget.controller.seat &&
        turn.phase == TurnPhase.awaitMove &&
        turn.k == k &&
        _sameFaces(turn.queue, queue);
  }

  /// Drops the move guard once the live turn is no longer the decision a
  /// move was sent for. The call that set the guard may still be in
  /// flight; forgetting its serial here means that call's later finish
  /// cannot drop a guard a newer send has set. See [_moveSentForK].
  ///
  /// C-422 D4: also drops the lift (`_moveSentToken`), on the same route a
  /// `moved` for my seat takes -- this is called from `_onControllerChanged`,
  /// already inside its own `setState`, so no further call is needed here.
  void _releaseMoveGuard() {
    if (_moveSentForK == null) {
      return;
    }
    if (_sameMoveDecision(
      widget.controller.room?.turn,
      _moveSentForK,
      _moveSentForQueue,
    )) {
      return;
    }
    _moveSentForK = null;
    _moveSentForQueue = null;
    _moveGuardSerial = null;
    _moveSentToken = null;
  }

  /// Drops the guard when the `controller.move` call numbered [serial]
  /// finishes, if that call still owns the guard.
  ///
  /// C-422 D4: this is the route a refusal or a dead socket takes -- the
  /// call ends with no `moved` ever changing `widget.controller.room`, so
  /// nothing else schedules a rebuild for the lift this guard was carrying.
  /// `setState` here is this route's only one, called only when the guard
  /// (and so the lift) actually drops, and only while the screen is still
  /// mounted (the call may finish well after this screen is gone).
  void _dropMoveGuardFor(int serial) {
    if (_moveGuardSerial != serial) {
      return;
    }
    if (!mounted) {
      _moveSentForK = null;
      _moveSentForQueue = null;
      _moveGuardSerial = null;
      _moveSentToken = null;
      return;
    }
    setState(() {
      _moveSentForK = null;
      _moveSentForQueue = null;
      _moveGuardSerial = null;
      _moveSentToken = null;
    });
  }

  /// Reads whatever `frame` just did to `widget.controller.room`'s
  /// already-reduced `turn` (RoomController pushes to `frames` ahead of
  /// its own `_reduce`, but `_reduce` itself runs synchronously inside
  /// that same call, ahead of this broadcast listener's own microtask, so
  /// every read below already sees it) and keeps `_lastKnownQueue` and
  /// `_deadCandidate*` in step with it. Answers true exactly when
  /// `cuesForFrame`'s `noMove` for this very `rolled` is actually K10's "a
  /// 6 (or a bonus) that still owes another roll" rather than a dead end,
  /// so `_onFrame` can drop that one cue before it plays.
  bool _trackRollQueue(Frame frame) {
    final TurnState? liveTurn = widget.controller.room?.turn;

    switch (frame.type) {
      case 'turn':
        final int? seat = _intAt(frame.data, 'seat');
        if (seat != null && liveTurn != null && liveTurn.seat == seat) {
          _rememberQueue(seat, liveTurn.queue);
        }
        _dropDeadCandidate();
        return false;

      case 'rolled':
        final int? seat = _intAt(frame.data, 'seat');
        if (seat == null || liveTurn == null || liveTurn.seat != seat) {
          return false;
        }
        if (liveTurn.phase != TurnPhase.awaitRoll) {
          // A move is now pending: not a death.
          _rememberQueue(seat, liveTurn.queue);
          _dropDeadCandidate();
          return false;
        }
        if (liveTurn.queue.isNotEmpty) {
          // K10: a 6 (or a bonus roll) that still owes another roll.
          _dropDeadCandidate();
          _rememberQueue(seat, liveTurn.queue);
          return true;
        }
        // The queue-mode placeholder for a roll that voided or passed
        // the turn (21.3.3: `queue` arrives as `[]` on the wire itself).
        // `turn_passed`'s own `reason` is the only thing that says
        // which; bank the pieces K9's D needs until it names it.
        _deadCandidateSeat = seat;
        _deadCandidateQueueBefore = List<int>.from(
          _lastKnownQueue[seat] ?? const <int>[],
        );
        _deadCandidateFace = _intAt(frame.data, 'value');
        _deadCandidateFromMove = false;
        return false;

      case 'moved':
        final int? seat = _intAt(frame.data, 'seat');
        final int? face = _intAt(frame.data, 'face');
        final bool extraRoll = frame.data['extra_roll'] == true;
        if (seat == null || face == null || extraRoll) {
          _dropDeadCandidate();
          return false;
        }
        // K9's third case: the face just spent might leave only dead
        // faces. Only `turn_passed no_legal_move` landing next confirms
        // it; anything else means the move did not kill the turn.
        _deadCandidateSeat = seat;
        _deadCandidateQueueBefore = List<int>.from(
          _lastKnownQueue[seat] ?? const <int>[],
        );
        _deadCandidateFace = face;
        _deadCandidateFromMove = true;
        return false;

      case 'turn_passed':
        _resolveDeadCandidate(frame);
        return false;

      default:
        return false;
    }
  }

  /// K9: resolves a banked `rolled`- or `moved`-dead candidate against the
  /// `turn_passed` that names why the turn actually died, into D, and
  /// shows it. Drops the candidate silently when `turn_passed` names a
  /// seat this screen was not tracking one for -- a frame this screen
  /// missed is not a case to guess at.
  void _resolveDeadCandidate(Frame frame) {
    final int? seat = _intAt(frame.data, 'seat');
    final String? reason = _stringAt(frame.data, 'reason');
    final int? candidateSeat = _deadCandidateSeat;
    if (seat == null ||
        reason == null ||
        candidateSeat == null ||
        candidateSeat != seat) {
      _dropDeadCandidate();
      return;
    }
    final List<int> before = _deadCandidateQueueBefore ?? const <int>[];
    final int? face = _deadCandidateFace;
    final bool fromMove = _deadCandidateFromMove;
    _dropDeadCandidate();

    List<int>? dead;
    if (reason == 'three_sixes') {
      // 10q/K9: the third six is never queued; D is the two already
      // queued, never the voided third.
      dead = List<int>.from(before);
    } else if (reason == 'no_legal_move' && face != null) {
      if (fromMove) {
        dead = List<int>.from(before);
        final int at = dead.indexOf(face);
        if (at != -1) {
          dead.removeAt(at);
        }
      } else {
        dead = List<int>.from(before)..add(face);
      }
    }
    if (dead == null || dead.isEmpty) {
      return;
    }

    // K1c/K9: every viewer sees the dead faces in the tray, whoever's
    // turn it was.
    if (dead.length >= 2) {
      _armTrayDead(seat, dead);
    }

    // The big die's own red-X-and-haptic hold stays the seat-gated
    // mechanism it already was (C-236 rule 4): a `rolled`-triggered dead
    // end already armed it correctly, for my own seat, through the
    // ordinary cuesForFrame path in `_onFrame`, for both reasons above.
    // Only the `moved`-triggered path needs a manual arm here (nothing
    // else ever drives it), and, matching that same gating, only for my
    // own seat.
    if (fromMove &&
        reason == 'no_legal_move' &&
        seat == widget.controller.seat) {
      _armNoMoveHold(dead.last);
      if (mounted) {
        _playCue(FeedbackScope.of(context), FeedbackCue.noMove);
      }
    }
  }

  void _armTrayDead(int seat, List<int> faces) {
    _trayDeadTimer?.cancel();
    _trayDeadTimer = Timer(_noMoveHold, _dropTrayDead);
    if (_trayDeadSeat == seat && _sameFaces(_trayDeadFaces, faces)) {
      return;
    }
    setState(() {
      _trayDeadSeat = seat;
      _trayDeadFaces = faces;
    });
  }

  void _dropTrayDead() {
    _trayDeadTimer?.cancel();
    _trayDeadTimer = null;
    if (!mounted || _trayDeadFaces == null) {
      return;
    }
    setState(() {
      _trayDeadSeat = null;
      _trayDeadFaces = null;
    });
  }

  void _onControllerChanged() {
    final RoomController controller = widget.controller;
    if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      _travelCount = 0;
    }
    // C-468 D5: resync notifies with hasDesynced before the snapshot.
    if (controller.hasDesynced) {
      _removeGloat();
      _clearChatBubbles();
    }
    _notePlayingGame();
    if (controller.phase != RoomPhase.connected) {
      _dropWhatTheLinkArmed();
    }
    // Throws first. A resync clears the remembered faces, and the sync
    // below records the holder's `turn.value` again (C-465 D2).
    _syncOpponentThrows();
    _syncSeatFaceMemory();
    setState(() {
      _syncCountdown();
      _releaseMoveGuard();
      _syncAutoMove();
      _syncRollWait();
    });
    _syncConnectionLostAnnouncement();
    _maybeFetchGameLog();
  }

  /// C-442 D6: the connection is no longer `connected`, so nothing this
  /// screen armed from a frame under it may fire after it. Every landing
  /// cue still waiting for a token to land, the safe-landing pill still
  /// waiting for the same, and the bookkeeping of walks still in flight are
  /// dropped; the snapshot that follows draws every token at truth (C-252
  /// rule 2) and the gap is neither replayed nor felt (C-293 rule 3). A cue
  /// already played stays played, and a pill already up runs out as it
  /// always did. The held `game_over` cues are not dropped: the screen did
  /// receive that frame.
  void _dropWhatTheLinkArmed() {
    _dropPendingLandingCues();
    // C-468 D5: a resync or a dropped link does not carry a gloat across.
    _removeGloat();
    _clearChatBubbles();
    _safeCueEpoch++;
    _safeCueLandingsToIgnore = 0;
    _dropPendingSafeCue();
    _travelCount = 0;
    _travellingLegs.clear();
  }

  /// C-377 D3: a throw for every `(k, face)` appended to `recentRolls`
  /// since the last snapshot this screen saw, when that roll belongs to
  /// another seat. The list the screen mounted with is the baseline, so
  /// it never throws. A list that is not an append (resync, new game)
  /// replaces the baseline and drops anything still in flight (A6).
  void _syncOpponentThrows() {
    final RoomSnapshot? room = widget.controller.room;
    final List<(int k, int face)> next = List<(int k, int face)>.of(
      room?.recentRolls ?? const <(int k, int face)>[],
    );
    final List<(int k, int face)>? added = _appendedRolls(_seenRolls, next);
    if (added == null) {
      _activeThrow = null;
      _throwQueue.clear();
      _throwHurry = false;
      _throwConcealsFace = false;
      _seenRolls = next;
      // C-465 D2: a resync forgets every face this screen had remembered.
      _rememberedSeatFaces.clear();
      // C-468 D5: a room snapshot whose recentRolls is not an append
      // (C-465 A6) is a resync too. The gloat that is up, and any still
      // waiting for its landing, go, and the captured seat's sound with them.
      _removeGloat();
      _clearChatBubbles();
      return;
    }
    _seenRolls = next;
    if (added.isEmpty) {
      return;
    }
    final int? turnSeat = room?.turn?.seat;
    final int? mySeat = widget.controller.seat;
    if (turnSeat == null || turnSeat == mySeat) {
      return;
    }
    for (final (int k, int face) in added) {
      // C-465 D2: a face outside 1..6 is not a throw. Queuing it would
      // build a thrown die, play die_land and remember the face.
      // restingRotationFor refuses that face. The seat die stays idle.
      if (face < 1 || face > 6) {
        continue;
      }
      _throwQueue.add(_QueuedThrow(k: k, seat: turnSeat, face: face));
    }
    _startNextThrow();
  }

  /// Starts the head of the queue when nothing is in flight. A throw
  /// already running is left to finish; a non-empty queue behind it is
  /// the D5 hurry.
  void _startNextThrow() {
    if (_activeThrow != null) {
      if (_throwQueue.isNotEmpty) {
        _throwHurry = true;
      }
      return;
    }
    if (_throwQueue.isEmpty) {
      _throwHurry = false;
      _throwConcealsFace = false;
      return;
    }
    _activeThrow = _throwQueue.removeAt(0);
    _throwHurry = _throwQueue.isNotEmpty;
    // D8 lands on the first frame, so the die under the board shows the
    // face in that same frame (D2). With motion on, the face stays hidden
    // until the tumble ends. Reduced motion has already landed, so the
    // face enters memory here (C-465 D2).
    _throwConcealsFace = !MediaQuery.disableAnimationsOf(context);
    if (!_throwConcealsFace) {
      final _QueuedThrow landed = _activeThrow!;
      _rememberedSeatFaces[landed.seat] = landed.face;
      // C-468 D4: reduced motion has already landed, so the sound is now.
      _playDieLandOnce(landed);
    }
  }

  /// C-377 D5: `moved` or `turn_passed` while a throw is up. The widget
  /// shortens whatever is left of the tumble, and the rest, to [kThrowFast].
  void _hurryActiveThrow() {
    if (_activeThrow == null || _throwHurry) {
      return;
    }
    _throwHurry = true;
    if (mounted) {
      setState(() {});
    }
  }

  void _clearThrows() {
    _activeThrow = null;
    _throwQueue.clear();
    _throwHurry = false;
    _throwConcealsFace = false;
    _seenRolls = List<(int k, int face)>.of(
      widget.controller.room?.recentRolls ?? const <(int k, int face)>[],
    );
    _rememberedSeatFaces.clear();
    _faceMemoryTurnSeat = null;
  }

  /// C-465 D2. While another seat holds the turn, remember `turn.value`
  /// once no throw of that seat is queued or still up. The throw itself
  /// writes the face when it lands, never when it is queued. When that
  /// seat's turn begins, drop the face kept from the previous one first,
  /// so a turn that never rolls goes back to the idle pose. The rolls
  /// this screen mounted with are the baseline, same as the throws: they
  /// are not faces this screen saw arrive.
  void _syncSeatFaceMemory() {
    final int? mySeat = widget.controller.seat;
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null) {
      _faceMemoryTurnSeat = null;
      return;
    }
    if (mySeat != null &&
        turn.seat != mySeat &&
        _faceMemoryTurnSeat != turn.seat) {
      _rememberedSeatFaces.remove(turn.seat);
    }
    _faceMemoryTurnSeat = turn.seat;
    final int? value = turn.value;
    if (mySeat == null || turn.seat == mySeat || value == null) {
      return;
    }
    if (_seatThrowPending(turn.seat)) {
      return;
    }
    _rememberedSeatFaces[turn.seat] = value;
  }

  /// A throw of [seat] is waiting in the queue or is the one in flight,
  /// in any phase (C-465 D2).
  bool _seatThrowPending(int seat) {
    final _QueuedThrow? active = _activeThrow;
    if (active != null && active.seat == seat) {
      return true;
    }
    for (final _QueuedThrow waiting in _throwQueue) {
      if (waiting.seat == seat) {
        return true;
      }
    }
    return false;
  }

  /// C-465 D2, D3. The seat die stays off while [seat]'s throw is queued
  /// or still tumbling, so a result is not on the board before the throw
  /// has flown. From the moment the throw in flight leaves the tumble
  /// the seat die is drawn under it, even when a successor is queued.
  bool _seatDieHeldBack(int seat) {
    final _QueuedThrow? active = _activeThrow;
    if (active != null && active.seat == seat && _throwConcealsFace) {
      return true;
    }
    final bool landedHere =
        active != null && active.seat == seat && !_throwConcealsFace;
    if (landedHere) {
      return false;
    }
    for (final _QueuedThrow waiting in _throwQueue) {
      if (waiting.seat == seat) {
        return true;
      }
    }
    return false;
  }

  void _onThrowPhase(ThrownDiePhase phase) {
    final bool conceal = phase == ThrownDiePhase.tumble;
    if (conceal == _throwConcealsFace || !mounted) {
      return;
    }
    _QueuedThrow? landed;
    setState(() {
      _throwConcealsFace = conceal;
      // Leaving the tumble is the landing. The face enters memory here,
      // not when the throw was queued (C-465 D2).
      if (!conceal) {
        landed = _activeThrow;
        if (landed != null) {
          _rememberedSeatFaces[landed!.seat] = landed!.face;
        }
      }
    });
    // C-468 D4: once per throw, including a hurried one. The flag stops
    // a later rest-to-fade phase from playing it again.
    if (landed != null) {
      _playDieLandOnce(landed!);
    }
  }

  void _onThrowDone() {
    if (!mounted) {
      return;
    }
    setState(() {
      final _QueuedThrow? done = _activeThrow;
      if (done != null) {
        _rememberedSeatFaces[done.seat] = done.face;
      }
      _activeThrow = null;
      _throwConcealsFace = false;
      _throwHurry = false;
      _startNextThrow();
    });
  }

  /// The face under the board. With a seat of my own the throw never
  /// conceals or sets it (C-465 D1.2): [dieFace] is already that die's
  /// face. With no seat, C-377 D2 stands: while a throw is still
  /// travelling, none, and from the moment it lands, its own face.
  int? _boardDieFace(int? dieFace) {
    if (widget.controller.seat != null) {
      return dieFace;
    }
    final _QueuedThrow? active = _activeThrow;
    if (active == null) {
      return dieFace;
    }
    if (_throwConcealsFace) {
      return null;
    }
    return active.face;
  }

  /// C-465 D4: the seat the tray belongs to. The dead-faces hold wins,
  /// the same way [_rollTrayData] already lets it win over [turn].
  int? _rollRecordSeat(TurnState? turn) {
    if (_trayDeadFaces != null && _trayDeadFaces!.length >= 2) {
      return _trayDeadSeat;
    }
    return turn?.seat;
  }

  /// C-465 D2. One [SeatDie] per other seat in play. Empty when this
  /// screen has no seat of its own, which leaves the board unchanged.
  /// A seat whose throw is queued or still tumbling is left out: the
  /// thrown die is that die in flight, and the result is not drawn
  /// before the throw has flown.
  List<SeatDie> _seatDiceOf(RoomSnapshot room) {
    final int? mySeat = widget.controller.seat;
    if (mySeat == null) {
      return const <SeatDie>[];
    }
    final TurnState? turn = room.turn;
    final _QueuedThrow? active = _activeThrow;
    final List<SeatDie> dice = <SeatDie>[];
    for (final int seat in _seatsInPlayOf(room)) {
      if (seat == mySeat || _seatDieHeldBack(seat)) {
        continue;
      }
      final bool holdsTurn = turn != null && turn.seat == seat;
      final int? face;
      if (active != null && active.seat == seat) {
        face = active.face;
      } else if (turn != null && turn.seat == seat) {
        face = turn.value;
      } else {
        face = _rememberedSeatFaces[seat];
      }
      dice.add(SeatDie(seat: seat, face: face, active: holdsTurn));
    }
    return dice;
  }

  Widget? _thrownDieOverlay(int? mySeat) {
    final _QueuedThrow? active = _activeThrow;
    if (active == null) {
      return null;
    }
    return BoardThrownDie(
      key: ValueKey<int>(active.k),
      seat: active.seat,
      face: active.face,
      mySeat: mySeat,
      hurry: _throwHurry,
      successorWaiting: _throwQueue.isNotEmpty,
      onPhase: _onThrowPhase,
      onDone: _onThrowDone,
    );
  }

  /// C-337 rule 3: announces [AppLocalizations.lobbyConnectionLost] once
  /// each time this screen enters the connection-lost body -- either the
  /// stale-table overlay or the no-room card, [_connectionLostBody]'s own
  /// two call sites in [build] -- and clears the guard the moment the body
  /// stops showing, so the next drop is announced again. Never on a
  /// rebuild while it stays up.
  void _syncConnectionLostAnnouncement() {
    final bool showing = _isShowingConnectionLostBody();
    if (!showing) {
      _announcedConnectionLost = false;
      return;
    }
    if (_announcedConnectionLost) {
      return;
    }
    _announcedConnectionLost = true;
    _announce(AppLocalizations.of(context).lobbyConnectionLost);
  }

  /// Mirrors [build]'s own decision of when [_connectionLostBody] is the
  /// body drawn, without rebuilding the widget tree: the end card (a gone
  /// rematch, or an offline end card) always wins over it, same priority
  /// order as [build].
  bool _isShowingConnectionLostBody() {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;

    final bool rematchGone =
        controller.phase == RoomPhase.failed &&
        controller.errorCode == 'NO_SUCH_ROOM' &&
        room != null;
    if (rematchGone) {
      return false;
    }

    final bool isOffline =
        controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed ||
        controller.phase == RoomPhase.connecting;
    final bool isOfflineEndCard =
        isOffline &&
        room != null &&
        ((room.state == RoomState.finished && !_isEndHeld) ||
            (room.state == RoomState.lobby && controller.lastFinished != null));
    if (isOfflineEndCard) {
      return false;
    }

    if (room != null && isOffline) {
      return true;
    }
    if (room == null) {
      return controller.phase == RoomPhase.failed ||
          controller.phase == RoomPhase.closed;
    }
    return false;
  }

  /// Tapping the die while it would roll: the `tap` cue now, start the
  /// tumble, send the intention. C-422 D2: the tap's acknowledgement plays
  /// through the feedback service, not a raw platform call outside it
  /// (C-236 rule 5's old contract), so the in-app haptics switch governs
  /// it; `yourTurn` and `canMove`/`noMove` for the roll that follows are
  /// played separately, from `_onFrame`, once the server's own `rolled`
  /// frame lands. C-426 D3: a die tap always reaches this point exactly
  /// when it is going to send `roll` (the caller only wires `onTap` here
  /// while `rollEnabled`), so this is one of the notice's own three
  /// clearing events for my own seat.
  void _onDieTap() {
    if (_isEndHeld) {
      return;
    }
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null) {
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    _rollNoAnswerTimer?.cancel();
    setState(() {
      _rollWaitK = turn.k;
      _rollNoAnswer = false;
      _timerPlayedMineVisible = false;
    });
    _rollNoAnswerTimer = Timer(_rollNoAnswerDelay, _onRollNoAnswer);
    widget.controller.roll();
  }

  /// Clears the tumble the moment any of the three things that end it (a
  /// fresh roll for my seat, the turn no longer being mine) shows up in a
  /// new snapshot. The 4s no-answer route clears it itself, in
  /// [_onRollNoAnswer], since nothing about the snapshot changes there.
  void _syncRollWait() {
    final RoomController controller = widget.controller;
    // C-442 D1: the 4 s timer and the tumble were armed under a connection
    // that has since left `connected`; the reconnecting card owns that
    // state. The no-answer line itself is shown only while the room shows
    // my seat's turn in await_roll over a live link, so it goes the moment
    // anything else is true, however it got there.
    if (controller.phase != RoomPhase.connected) {
      _rollNoAnswerTimer?.cancel();
      _rollNoAnswerTimer = null;
      _rollWaitK = null;
      _rollNoAnswer = false;
      return;
    }
    if (_rollNoAnswer && !_myRollIsAwaited()) {
      _rollNoAnswer = false;
    }
    final int? waitK = _rollWaitK;
    if (waitK == null) {
      return;
    }
    final TurnState? turn = controller.room?.turn;
    final bool stillMine = turn != null && turn.seat == controller.seat;
    final bool resultArrived =
        stillMine && turn.k > waitK && turn.value != null;
    if (!stillMine || resultArrived) {
      _rollNoAnswerTimer?.cancel();
      _rollNoAnswerTimer = null;
      _rollWaitK = null;
    }
  }

  /// C-442 D1: true when the room shows my seat's turn in await_roll and the
  /// connection is `connected`: the only state in which "Tap the die again"
  /// is something the player can do.
  bool _myRollIsAwaited() {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    final TurnState? turn = room?.turn;
    return controller.phase == RoomPhase.connected &&
        room != null &&
        room.state == RoomState.playing &&
        turn != null &&
        turn.seat == controller.seat &&
        turn.phase == TurnPhase.awaitRoll;
  }

  /// 4 seconds after a rolling tap with no new roll result: stop the
  /// tumble, show the last known face, and show the no-answer line until
  /// the next tap. A dropped connection is handled by rule 1 in [build]
  /// instead, so this only needs to guard against firing into a screen
  /// that has already moved past the playing body.
  void _onRollNoAnswer() {
    if (!mounted) {
      return;
    }
    if (!_myRollIsAwaited()) {
      setState(() {
        _rollWaitK = null;
        _rollNoAnswer = false;
      });
      return;
    }
    setState(() {
      _rollWaitK = null;
      _rollNoAnswer = true;
    });
    // C-337 rule 3: the die's no-answer line, spoken once each time it
    // appears. This is the only place `_rollNoAnswer` turns true, so
    // nothing else can make it appear a second time without another trip
    // through here.
    _announce(AppLocalizations.of(context).gameRollNoAnswer);
  }

  /// True when this seat is awaiting a move and the server named exactly
  /// one legal token to spend. The hold is a screen convenience on top of
  /// that already-authoritative list, not a second legality check.
  ///
  /// K8 (order 365, C-362 Part B): under the roll queue (`legalByFace`
  /// non-null) the test is on `legalByFace` instead -- exactly one queued
  /// face with a legal move, and that face legal for exactly one token.
  /// Without the queue (`legalByFace` null), today's rule is unchanged.
  bool _isUniqueLegalAwaitMove() {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    final TurnState? turn = room?.turn;
    if (room == null ||
        room.state != RoomState.playing ||
        turn == null ||
        turn.seat != controller.seat ||
        turn.phase != TurnPhase.awaitMove) {
      return false;
    }
    final List<FaceLegal>? legalByFace = turn.legalByFace;
    if (legalByFace != null) {
      return legalByFace.length == 1 && legalByFace.single.tokens.length == 1;
    }
    return turn.legal != null && turn.legal!.length == 1;
  }

  /// Arms the 1.5s unique-legal hold once per await_move decision (this
  /// seat, `turn.k`, and the queue), or drops a pending hold when the turn
  /// is no longer that unique-legal awaitMove. A new queue under the same
  /// k is a new decision and arms again. Once armed, the decision stays
  /// handled, so a move the server refused is not sent again by the hold.
  /// A tap still goes through [_sendMove]. The board draws the held
  /// token's glow itself from `autoMoveToken`; there is no Undo to
  /// announce alongside it any more.
  void _syncAutoMove() {
    // C-442 D3: the game does not move by itself while the link is down.
    // The pending hold goes, and the latch for this decision is released
    // with it: the only way back to `connected` is a snapshot, and the
    // decision is then taken afresh from the turn that snapshot shows. A
    // decision the server refused over a live link stays latched below.
    if (widget.controller.phase != RoomPhase.connected) {
      _autoMoveHandledK = null;
      _autoMoveHandledQueue = null;
      _clearPendingHold();
      return;
    }
    final TurnState? turnNow = widget.controller.room?.turn;
    final bool stillArmed = _sameMoveDecision(
      turnNow,
      _autoMoveHandledK,
      _autoMoveHandledQueue,
    );
    if (!stillArmed) {
      _autoMoveHandledK = null;
      _autoMoveHandledQueue = null;
    }
    if (_isEndHeld || !_isUniqueLegalAwaitMove()) {
      _clearPendingHold();
      return;
    }
    final TurnState turn = turnNow!;
    if (stillArmed) {
      return;
    }
    _autoMoveHandledK = turn.k;
    _autoMoveHandledQueue = List<int>.from(turn.queue);
    final List<FaceLegal>? legalByFace = turn.legalByFace;
    if (legalByFace != null) {
      _pendingAutoMoveToken = legalByFace.single.tokens.single;
      _pendingAutoMoveFace = legalByFace.single.face;
    } else {
      _pendingAutoMoveToken = turn.legal!.single;
      _pendingAutoMoveFace = null;
    }
    final AppLocalizations loc = AppLocalizations.of(context);
    // C-417 D5: arming says the token will move by itself, not merely
    // which token it is -- the commit announcement below still names the
    // token alone, since by then it already has.
    _announceAutoMove(loc.announceAutoMoveArmed(_pendingAutoMoveToken! + 1));
    // C-408 D7: the glow this hold counts down is board.dart's own D2,
    // which the board does not draw until the held token's disc reaches
    // its truth. A `moved` frame already in hand for this very token may
    // still be travelling there (this very `turn` frame is often the one
    // right after that `moved`); if so, the clock starts only once that
    // walk lands or is snapped away, in `_onBoardMoveLanded` or
    // `_onBoardTravelReset`, not here. Not walking: start now, as before
    // D7 ever existed.
    if (_isTravelling(turn.seat, _pendingAutoMoveToken!)) {
      _autoMoveTimer?.cancel();
      _autoMoveTimer = null;
      _autoMoveAwaitingWalk = true;
      _armAutoMoveCeiling(turn.seat, _pendingAutoMoveToken!);
    } else {
      _startAutoMoveTimer();
    }
  }

  /// C-408 D8: the ceiling on a wait for a walk that never lands or
  /// snaps, computed once, the moment the wait starts, from every leg
  /// this screen has counted so far, across every seat --
  /// `_travellingLegs`'s own values summed. Each counted leg is charged
  /// the worst a leg the board really plays can cost: six steps (the
  /// longest a single face can walk) plus one capture flight, at the
  /// step and flight durations in force (`MediaQuery.disableAnimationsOf`,
  /// read the way board.dart reads it), plus a flat 250 ms. Every walk
  /// the board really plays lands well inside that, so D7 is unchanged
  /// for it; only a leg the board never lands or snaps ever reaches this
  /// timer's fire.
  void _armAutoMoveCeiling(int seat, int token) {
    _autoMoveCeilingTimer?.cancel();
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final Duration step = reduced
        ? kTokenStepDurationReduced
        : kTokenStepDuration;
    final Duration flight = reduced
        ? kCaptureFlightDurationReduced
        : kCaptureFlightDuration;
    final int legs = _travellingLegs.values.fold<int>(
      0,
      (int sum, int count) => sum + count,
    );
    final Duration perLeg = step * 6 + flight;
    final Duration ceiling = perLeg * legs + const Duration(milliseconds: 250);
    _autoMoveCeilingTimer = Timer(
      ceiling,
      () => _onAutoMoveCeiling(seat, token),
    );
  }

  /// C-408 D8: the ceiling fired while the hold was still waiting for
  /// this token's walk. Drop the bookkeeping for that one token (the
  /// leg the board never landed or snapped) and start the 1500 ms hold
  /// now, exactly as a real landing or snap would have.
  void _onAutoMoveCeiling(int seat, int token) {
    _autoMoveCeilingTimer = null;
    if (!_autoMoveAwaitingWalk ||
        seat != widget.controller.seat ||
        token != _pendingAutoMoveToken) {
      return;
    }
    _travellingLegs.remove(_travelKey(seat, token));
    _startAutoMoveTimer();
  }

  static String _travelKey(int seat, int token) => '$seat-$token';

  /// True while a `moved` frame's travel for (seat, token) has reached
  /// this screen but not yet been seen to land or snap. C-408 D7's only
  /// source for "is the held token still walking".
  bool _isTravelling(int seat, int token) =>
      (_travellingLegs[_travelKey(seat, token)] ?? 0) > 0;

  void _markLegTravelling(int seat, int token) {
    final String key = _travelKey(seat, token);
    _travellingLegs[key] = (_travellingLegs[key] ?? 0) + 1;
  }

  /// One queued leg of (seat, token) has landed. Contract C-408 D6: a
  /// second leg queued behind the first keeps the disc travelling past
  /// this same landing, so the count only reaches zero -- "not walking"
  /// again -- once every leg this screen has seen for that token has.
  void _markLegLanded(int seat, int token) {
    final String key = _travelKey(seat, token);
    final int count = _travellingLegs[key] ?? 0;
    if (count <= 1) {
      _travellingLegs.remove(key);
    } else {
      _travellingLegs[key] = count - 1;
    }
  }

  /// C-408 D7: a leg of (seat, token) has just landed; if the held hold
  /// was waiting on exactly this token's walk, and no further leg of it
  /// is still travelling, start the 1500 ms clock now.
  void _maybeStartAutoMoveAfterWalk(int seat, int token) {
    if (!_autoMoveAwaitingWalk ||
        seat != widget.controller.seat ||
        token != _pendingAutoMoveToken ||
        _isTravelling(seat, token)) {
      return;
    }
    _startAutoMoveTimer();
  }

  void _startAutoMoveTimer() {
    _autoMoveAwaitingWalk = false;
    _autoMoveCeilingTimer?.cancel();
    _autoMoveCeilingTimer = null;
    _autoMoveTimer?.cancel();
    _autoMoveTimer = Timer(kAutoMoveHold, _commitPendingAutoMove);
    _rebuildForAutoMoveBanner();
  }

  /// C-417 D4: the banner reads `_autoMoveTimer`, and the hold can start
  /// from a board callback (a walk landing, a snap, the C-408 ceiling)
  /// that does not rebuild this screen. Rebuild now, or right after the
  /// current frame when the callback arrives in the middle of one.
  void _rebuildForAutoMoveBanner() {
    if (!mounted) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
      return;
    }
    setState(() {});
  }

  void _clearPendingHold() {
    _autoMoveTimer?.cancel();
    _autoMoveTimer = null;
    _autoMoveCeilingTimer?.cancel();
    _autoMoveCeilingTimer = null;
    _pendingAutoMoveToken = null;
    _pendingAutoMoveFace = null;
    _autoMoveAwaitingWalk = false;
  }

  void _commitPendingAutoMove() {
    if (!mounted) {
      return;
    }
    final int? token = _pendingAutoMoveToken;
    final int? face = _pendingAutoMoveFace;
    final int? k = _autoMoveHandledK;
    final List<int>? armedQueue = _autoMoveHandledQueue;
    if (token == null || k == null) {
      return;
    }
    _autoMoveTimer = null;
    _pendingAutoMoveToken = null;
    _pendingAutoMoveFace = null;
    final TurnState? turn = widget.controller.room?.turn;
    if (!_sameMoveDecision(turn, k, armedQueue)) {
      setState(() {});
      return;
    }
    final AppLocalizations loc = AppLocalizations.of(context);
    _announceAutoMove(loc.gameTokenButton(token + 1));
    setState(() {});
    _sendMove(token, k, face: face);
  }

  /// The one path that actually calls `controller.move`: a tap on the board
  /// and the hold's own timer both end up here, and whichever reaches the
  /// current decision first is the only one that sends anything until that
  /// call finishes or the decision changes.
  ///
  /// K6 (order 365, C-362 Part B): `face` goes out only when the caller
  /// read it off a non-null `legalByFace`; `RoomController.move` itself
  /// only puts it on the wire when non-null (C-362 A6), so a server
  /// without the roll queue, where `face` is always null here, sends the
  /// byte-identical frame it always did.
  ///
  /// C-422 D3/D4: returns true exactly when this call put a move on the
  /// wire (passed every guard above), false otherwise. The caller on the
  /// tap path plays `FeedbackCue.tap` only on true; the hold's own commit
  /// never looks at the return value, since the player did not tap. Either
  /// way, a true return also set `_moveSentToken` to [token], which is
  /// what draws the lift -- the return value and the lift always agree on
  /// whether this call sent anything.
  bool _sendMove(int token, int k, {int? face}) {
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null ||
        turn.seat != widget.controller.seat ||
        turn.phase != TurnPhase.awaitMove ||
        turn.k != k) {
      return false;
    }
    if (_moveSentForK == k && _sameFaces(_moveSentForQueue, turn.queue)) {
      return false;
    }
    final int serial = ++_moveSendSerial;
    _moveSentForK = k;
    _moveSentForQueue = List<int>.from(turn.queue);
    _moveGuardSerial = serial;
    _moveSentToken = token;
    // C-471 D4: a move sent by me takes the marker down. It is not shown
    // again in this game, even when the move was a different token.
    _shownHint = null;
    unawaited(
      widget.controller.move(token, face: face).whenComplete(() {
        _dropMoveGuardFor(serial);
      }),
    );
    return true;
  }

  /// A token tap is an explicit move: drop the hold silently, then let the
  /// tap send the same move the hold would have.
  void _cancelPendingHoldForManualMove() {
    if (_pendingAutoMoveToken == null) {
      return;
    }
    _clearPendingHold();
    setState(() {});
  }

  void _announceAutoMove(String message) {
    if (!mounted || message.isEmpty) {
      return;
    }
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  /// Restarts the countdown for the current turn, and arms or disarms the
  /// once-a-second tick that keeps it moving.
  ///
  /// Restarting happens only when the visible `(seat, deadlineMs, k)`
  /// triple actually changes. The same triple recurring across frames --
  /// several of RoomController's reducers carry the prior segment's
  /// `deadlineMs` forward unchanged on a frame that is not itself a fresh
  /// reading, per the doc comments at net/room_controller.dart's
  /// `_reduceMoved`, `_reduceTurnPassed` and `_reduceGameOver` -- is not
  /// a new reading and must not restart the clock or the display would
  /// jump back up while the real deadline keeps approaching underneath
  /// it. A genuinely new segment always changes at least one member of
  /// the triple: a different seat is now playing, a fresh `deadline_ms`
  /// arrived straight off the wire (`_reduceTurn`, `_reduceRolled`), or
  /// `turn.k` moved on even though the seat and a stale-looking
  /// `deadline_ms` happen to coincide with the segment before it -- the
  /// case a disconnect and resume can produce, since `k` is the one
  /// field the server always advances for a genuinely new turn and never
  /// replays.
  ///
  /// No timer runs while the room is not showing a playing board with a
  /// current turn, and none is armed for a turn whose deadline has
  /// already reached zero. The one already running is cancelled the
  /// instant its own tick counts down to nothing (see
  /// `_armCountdownTimer` below) -- requirement 4a: a countdown that
  /// keeps scheduling frames after zero never lets `pumpAndSettle`
  /// return, and both test/composed_play_test.dart and
  /// test/game_screen_test.dart drive a playing board through exactly
  /// that call.
  void _syncCountdown() {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    final bool showingPlayingBody =
        room != null &&
        room.state == RoomState.playing &&
        room.seats.length >= 2;
    final TurnState? turn = showingPlayingBody ? room.turn : null;

    if (turn == null) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
      _countdownSeat = null;
      _countdownDeadlineMs = null;
      _countdownK = null;
      _countdownRemainingSeconds = 0;
      return;
    }

    if (turn.seat == _countdownSeat &&
        turn.deadlineMs == _countdownDeadlineMs &&
        turn.k == _countdownK) {
      return;
    }

    _countdownTimer?.cancel();
    _countdownSeat = turn.seat;
    _countdownDeadlineMs = turn.deadlineMs;
    _countdownK = turn.k;
    // Requirement 1: the whole seconds remaining, rounded up so a segment
    // that has not truly reached zero never reads as "0 seconds left" a
    // moment before it actually is.
    _countdownRemainingSeconds = turn.deadlineMs <= 0
        ? 0
        : (turn.deadlineMs + 999) ~/ 1000;
    _countdownTimer = _countdownRemainingSeconds > 0
        ? _armCountdownTimer()
        : null;
  }

  /// The once-a-second tick. Requirement 2: clamps at zero and never
  /// goes negative. Requirement 4a: the tick that brings the display to
  /// zero cancels itself, so nothing here ever schedules another frame
  /// once there is nothing left to count down.
  Timer _armCountdownTimer() {
    return Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_countdownRemainingSeconds > 1) {
          _countdownRemainingSeconds -= 1;
        } else {
          _countdownRemainingSeconds = 0;
          _countdownTimer?.cancel();
          _countdownTimer = null;
        }
      });
    });
  }

  /// The one path every leave affordance on this screen goes through,
  /// corner leave icon and connection-lost body alike.
  ///
  /// This pops and nothing else. It does not call `controller.leave()`.
  /// `home_screen.dart` created this controller and already owns retiring
  /// it: both of its entry points `await Navigator.push(...)`, and once
  /// that returns -- which happens the instant this pop lands -- they
  /// `await controller.leave()` before `controller.dispose()`, in that
  /// order, on purpose. Calling `leave()` here as well would race that:
  /// on a socket the server has already dropped, this screen's own call
  /// can still be suspended inside `leave()`'s awaited request when
  /// `home_screen.dart`'s `dispose()` lands, and the eventual timeout
  /// reaches back into a controller that has already been disposed. So
  /// this screen's only job is to get the player off it promptly, on a
  /// dead server or a live one, and leave the actual leaving to the code
  /// that was reviewed to do it in the right order.
  ///
  /// The finished-board next-table control is not this path: it pops
  /// [GameScreenResult.newTable] so HomeScreen can open a fresh table
  /// after that same leave()/dispose() sequence.
  void _leave() {
    _clearSafeCue();
    Navigator.of(context).pop();
  }

  void _requestNewTable() {
    Navigator.of(context).pop(GameScreenResult.newTable);
  }

  /// C-272 rule 3: confirm only when leaving costs something.
  bool _needsLeaveConfirm() {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    if (room == null) {
      return false;
    }
    if (room.state != RoomState.playing) {
      return false;
    }
    final int? seat = controller.seat;
    if (seat == null) {
      return false;
    }
    final bool hasSeat = room.seats.any((SeatState s) => s.seat == seat);
    if (!hasSeat) {
      return false;
    }
    if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      return false;
    }
    return true;
  }

  void _handleLeaveRequest(BuildContext context, AppLocalizations loc) {
    if (_needsLeaveConfirm()) {
      _showLeaveConfirm(context, loc);
      return;
    }
    _leave();
  }

  /// C-272 rule 4: modal bottom sheet confirming leave when in playing state.
  void _showLeaveConfirm(BuildContext context, AppLocalizations loc) {
    if (!mounted || _isLeaveConfirmOpen) {
      return;
    }
    _isLeaveConfirmOpen = true;
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return Padding(
          key: const Key('game-leave-confirm'),
          padding: const EdgeInsets.all(kSpace5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                loc.gameLeaveConfirmTitle,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: kSpace2),
              Text(loc.gameLeaveConfirmBody),
              const SizedBox(height: kSpace4),
              FilledButton(
                key: const Key('game-leave-confirm-stay'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: Text(loc.gameLeaveConfirmStay),
              ),
              const SizedBox(height: kSpace2),
              TextButton(
                key: const Key('game-leave-confirm-leave'),
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  if (mounted) {
                    _leave();
                  }
                },
                child: Text(loc.gameLeaveButton),
              ),
            ],
          ),
        );
      },
    ).whenComplete(() {
      _isLeaveConfirmOpen = false;
    });
  }

  /// C-246 rule 1 and rule 3, C-316 rule 4: the end card's Rematch/accept tap.
  /// Guarded by [_rematchInFlight] so a second tap while the request is open
  /// sends nothing. When offline, starts the reconnect and sends rematch once
  /// resumed. Neither method throws, so this always reaches the end and clears
  /// the guard.
  Future<void> _onRematchTap() async {
    if (_rematchInFlight) {
      return;
    }
    setState(() {
      _rematchInFlight = true;
    });
    if (widget.controller.phase != RoomPhase.connected) {
      await widget.controller.reconnectAndRematch();
    } else {
      await widget.controller.rematch();
    }
    // `mounted` is not enough here; see _screenDisposed's own comment.
    if (_screenDisposed || !mounted) {
      return;
    }
    setState(() {
      _rematchInFlight = false;
    });
  }

  /// Opens the match `verify_url` in an external browser. The app does not
  /// prove the rolls itself; a failure to open is shown honestly.
  Future<void> _openVerifyUrl() async {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    final RoomSnapshot? lastFinished = controller.lastFinished;
    final RoomSnapshot? finished =
        (room != null &&
            lastFinished != null &&
            ((room.state == RoomState.lobby && room.rematch != null) ||
                (room.state == RoomState.finished &&
                    room.gameId == lastFinished.gameId)))
        ? lastFinished
        : room;
    final String? raw = finished?.verifyUrl;
    if (raw == null || raw.isEmpty) {
      return;
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || (!uri.isScheme('https') && !uri.isScheme('http'))) {
      _showVerifyOpenFailed();
      return;
    }
    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      opened = false;
    } on ArgumentError {
      opened = false;
    }
    if (!opened && mounted) {
      _showVerifyOpenFailed();
    }
  }

  void _showVerifyOpenFailed() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).gameVerifyOpenFailed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;

    // C-246 rule 8, and this file's own ambiguity note: every rematch
    // failure alike lands the controller in RoomPhase.failed (room 1's
    // unconditional "routes through the same in-room request failure
    // path"); this is what tells a NO_SUCH_ROOM failure apart from every
    // other one, so the end card can stay up in its gone state instead of
    // falling into the ordinary connection-lost body below. `room` is
    // whatever this controller held before the failed request -- `_fail`
    // never touches it -- so it is still the finished (or rematch-LOBBY)
    // snapshot the end card was already showing.
    final bool rematchGone =
        controller.phase == RoomPhase.failed &&
        controller.errorCode == 'NO_SUCH_ROOM' &&
        room != null;

    // C-316 rule 4: when the room is FINISHED or a rematch LOBBY with
    // lastFinished, and the connection is failed, closed or connecting, the
    // end card is drawn as when connected: not dimmed, not under IgnorePointer,
    // no connection-lost card.
    final bool isOffline =
        controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed ||
        controller.phase == RoomPhase.connecting;
    final bool isOfflineEndCard =
        isOffline &&
        room != null &&
        ((room.state == RoomState.finished && !_isEndHeld) ||
            (room.state == RoomState.lobby && controller.lastFinished != null));

    // C-462 D4: the picker closes, with no send and no cue, on the rebuild
    // that makes any of its conditions true.
    _syncFacePick(
      playingOnScreen:
          !rematchGone &&
          !isOfflineEndCard &&
          room != null &&
          _showsPlayingBody(room),
    );
    _syncShownHint();

    final Widget body;
    if (rematchGone) {
      body = _gameOverBody(loc, controller, room, rematchGone: true);
    } else if (isOfflineEndCard) {
      body = _gameOverBody(loc, controller, room, isOffline: true);
    } else if (room != null && isOffline) {
      // C-282 rules 1 and 2: a dropped or retrying connection keeps the
      // last snapshot's table in view (dimmed, untappable) under the
      // connection-lost card.
      final Widget staleTable = _connectedBody(
        loc,
        controller,
        room,
        stale: true,
      );
      body = Stack(
        fit: StackFit.expand,
        children: [
          KeyedSubtree(
            key: const Key('game-screen-stale-table'),
            child: IgnorePointer(
              ignoring: true,
              child: ExcludeSemantics(
                child: Opacity(opacity: 0.35, child: staleTable),
              ),
            ),
          ),
          _connectionLostBody(loc, controller),
        ],
      );
    } else if (room == null) {
      // C-282 rule 4: failed or closed with no room yet shows the card
      // centred over an empty body; connecting stays loading.
      if (controller.phase == RoomPhase.failed ||
          controller.phase == RoomPhase.closed) {
        body = _connectionLostBody(loc, controller);
      } else {
        body = _loadingBody();
      }
    } else {
      body = _connectedBody(loc, controller, room);
    }

    // C-500 D1: the one quick message line is drawn on every body, so the
    // table, the held end, the end card and the rest all get it in one place.
    final EndCardChatLine? chatLine = _chatLineOf(
      loc,
      room,
      controller.lastFinished,
    );
    final bool showsChatButton = _showsChatButton(controller, room);

    final SystemUiOverlayStyle overlayStyle =
        Theme.of(context).brightness == Brightness.light
        ? SystemUiOverlayStyle.dark
        : SystemUiOverlayStyle.light;

    return PopScope(
      canPop: !_needsLeaveConfirm(),
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) {
          return;
        }
        _showLeaveConfirm(context, loc);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: SafeArea(
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Column(
                  children: [
                    // Signature chrome: felt edge frames the seat-pip strip so
                    // every body below (waiting, playing, game-over, and the rest)
                    // inherits the same table cue without each state painting its
                    // own copy.
                    const FeltEdge(key: Key('game-felt-edge')),
                    SizedBox(
                      height: 48,
                      child: Stack(
                        // C-250 rule 1 lets only the play header sit between the
                        // strip and the board, so the row's spare height goes above
                        // the strip.
                        alignment: Alignment.bottomCenter,
                        children: [
                          SeatPipStrip(
                            key: const Key('game-seat-pip-strip'),
                            seats: room == null ? null : _seatsInPlayOf(room),
                            turnSeat:
                                (room != null &&
                                    room.state == RoomState.playing)
                                ? room.turn?.seat
                                : null,
                          ),
                          PositionedDirectional(
                            start: kSpace2,
                            child: IconButton(
                              // The key name is historical (the old app bar
                              // action); tests pin it.
                              key: const Key('game-screen-appbar-leave'),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              tooltip: loc.gameLeaveButton,
                              onPressed: () =>
                                  _handleLeaveRequest(context, loc),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                          if (showsChatButton)
                            PositionedDirectional(
                              end: kSpace2 + 48 + kSpace1,
                              child: Opacity(
                                opacity: _chatCooling ? 0.38 : 1,
                                child: IconButton(
                                  key: const Key('game-chat-button'),
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(48, 48),
                                  ),
                                  tooltip: loc.chatButtonTooltip,
                                  onPressed: _onChatButtonTap,
                                  icon: const Icon(
                                    Icons.chat_bubble_outline_rounded,
                                  ),
                                ),
                              ),
                            ),
                          PositionedDirectional(
                            end: kSpace2,
                            child: IconButton(
                              key: const Key('game-settings-button'),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              tooltip: loc.settingsTooltip,
                              onPressed: () =>
                                  showFeedbackSettingsSheet(context),
                              icon: const Icon(Icons.tune_rounded),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (controller.hasDesynced) _desyncBanner(context, loc),
                    Expanded(child: body),
                  ],
                ),
                if (chatLine != null)
                  _chatLayer(
                    loc,
                    chatLine,
                    clearOfChatButton: _chat?.clearOfChatButton ?? false,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// C-500 D1 and D4. The one quick message line, laid over the whole screen
  /// column so a bubble taller than the header row paints over the top of the
  /// body instead of under it. It mirrors the column's own top (the felt edge,
  /// then the 48 dp header row), takes no layout space and takes no taps, so
  /// the buttons and the pip strip under it keep working. It sits in the span
  /// between the leave button and the first button at the end side, which is
  /// the chat button when the row carries it and the settings button when not.
  Widget _chatLayer(
    AppLocalizations loc,
    EndCardChatLine line, {
    required bool clearOfChatButton,
  }) {
    return Positioned.fill(
      child: IgnorePointer(
        key: const Key('end-card-chat-lines'),
        child: Column(
          children: [
            const SizedBox(height: kFeltEdgeThickness),
            SizedBox(
              height: 48,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  const double startInset = kSpace2 + 48 + kSpace1;
                  final double endInset = clearOfChatButton
                      ? kSpace2 + 48 + kSpace1 + 48 + kSpace1
                      : startInset;
                  final double maxWidth = math.max(
                    0,
                    math.min(320, constraints.maxWidth - startInset - endInset),
                  );
                  return Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: startInset,
                      end: endInset,
                    ),
                    child: CustomSingleChildLayout(
                      delegate: _HeaderBandLine(maxWidth),
                      child: EndCardChatBubble(
                        seat: line.seat,
                        name: line.name,
                        text: line.text,
                        label: loc.chatSaid(line.name, line.text),
                        serial: line.serial,
                        maxWidth: maxWidth,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// C-282 rule 1: the body the room would get when connected, run on the
  /// current or last known snapshot.
  Widget _connectedBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room, {
    bool stale = false,
  }) {
    if (room.state == RoomState.finished) {
      if (_isEndHeld && room.seats.length >= 2) {
        return _playingBody(loc, controller, room, stale: stale);
      } else {
        return _gameOverBody(loc, controller, room);
      }
    } else if (room.state == RoomState.lobby && room.rematch != null) {
      // C-246 rule 2: a rematch LOBBY (state LOBBY, non-null `rematch`) is
      // drawn by the same end card as FINISHED, so the player sees one
      // continuous next step rather than a reset screen in between.
      return _gameOverBody(loc, controller, room);
    } else if (room.state == RoomState.playing && room.seats.length >= 2) {
      return _playingBody(loc, controller, room, stale: stale);
    } else {
      return _waitingBody(loc);
    }
  }

  /// C-282 rule 2: one card centred in the body area over the stale table (or
  /// over an empty body when no room yet exists). Retrying shows the sync icon
  /// and reconnecting line without a Reconnect button; given up shows the
  /// Reconnect button; Leave is always last.
  Widget _connectionLostBody(AppLocalizations loc, RoomController controller) {
    final String? errorMessage = controller.errorMessage;
    final bool isRetrying =
        controller.autoReconnectPending ||
        controller.phase == RoomPhase.connecting;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Material(
          key: const Key('game-screen-connection-lost'),
          color: LudoColors.paperElevated,
          borderRadius: BorderRadius.circular(2 * kRadiusControl),
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.all(kSpace5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(
                  Icons.wifi_off_rounded,
                  size: 32,
                  color: LudoColors.inkMuted,
                ),
                const SizedBox(height: kSpace2),
                Text(
                  loc.lobbyConnectionLost,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(color: LudoColors.ink),
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: kSpace2),
                  Text(
                    errorMessage,
                    key: const Key('game-screen-error-message'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: LudoColors.inkMuted),
                  ),
                ],
                const SizedBox(height: kSpace4),
                if (isRetrying) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.sync_rounded,
                        size: 18,
                        color: LudoColors.inkMuted,
                      ),
                      const SizedBox(width: kSpace2),
                      Flexible(
                        child: Text(
                          loc.lobbyReconnecting,
                          key: const Key('game-screen-reconnecting'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: LudoColors.inkMuted),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: kSpace4),
                ] else ...[
                  ElevatedButton(
                    key: const Key('game-screen-reconnect-button'),
                    onPressed: controller.reconnect,
                    child: Text(loc.lobbyReconnectButton),
                  ),
                  const SizedBox(height: kSpace2),
                ],
                OutlinedButton(
                  key: const Key('game-screen-leave-button'),
                  onPressed: _leave,
                  child: Text(loc.gameLeaveButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// H6.1: `controller.room` is null. Nothing else is built here; a
  /// `CircularProgressIndicator` never settles, so this state must never be
  /// reached with `pumpAndSettle`.
  Widget _loadingBody() {
    return const Center(
      child: CircularProgressIndicator(key: Key('game-screen-loading')),
    );
  }

  /// H6.4: `RoomState.lobby`, or a `RoomState.playing` room with fewer than
  /// two seated players. No board, no turn banner, no buttons.
  Widget _waitingBody(AppLocalizations loc) {
    return Center(
      child: Text(
        loc.gameWaitingForStart,
        key: const Key('game-screen-waiting'),
        textAlign: TextAlign.center,
      ),
    );
  }

  /// C-462 D1: every token any entry of [legalByFace] can move.
  Set<int> _legalTokenUnion(List<FaceLegal> legalByFace) {
    final Set<int> tokens = <int>{};
    for (final FaceLegal entry in legalByFace) {
      tokens.addAll(entry.tokens);
    }
    return tokens;
  }

  /// C-462 D2: the faces, in [legalByFace] order, whose tokens include
  /// [token].
  List<int> _facesForToken(List<FaceLegal> legalByFace, int token) {
    final List<int> faces = <int>[];
    for (final FaceLegal entry in legalByFace) {
      if (entry.tokens.contains(token)) {
        faces.add(entry.face);
      }
    }
    return faces;
  }

  /// True when [_connectedBody] draws [_playingBody] for [room]. The end
  /// hold still counts: that body is on screen, and D4 closes the picker
  /// for the hold itself.
  bool _showsPlayingBody(RoomSnapshot room) {
    if (room.state == RoomState.finished) {
      return _isEndHeld && room.seats.length >= 2;
    }
    if (room.state == RoomState.lobby && room.rematch != null) {
      return false;
    }
    return room.state == RoomState.playing && room.seats.length >= 2;
  }

  /// C-462 D4. Field write only: this runs at the start of [build].
  void _syncFacePick({required bool playingOnScreen}) {
    final _OpenFacePick? pick = _facePick;
    if (pick == null) {
      return;
    }
    if (_facePickMustClose(pick, playingOnScreen: playingOnScreen)) {
      _facePick = null;
    }
  }

  bool _facePickMustClose(_OpenFacePick pick, {required bool playingOnScreen}) {
    if (!playingOnScreen || _isEndHeld || _pendingAutoMoveToken != null) {
      return true;
    }
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null ||
        turn.seat != widget.controller.seat ||
        turn.phase != TurnPhase.awaitMove ||
        turn.k != pick.k ||
        !_sameFaces(turn.queue, pick.queue)) {
      return true;
    }
    final List<FaceLegal>? legalByFace = turn.legalByFace;
    if (legalByFace == null) {
      return true;
    }
    return _facesForToken(legalByFace, pick.token).length < 2;
  }

  /// C-422 D3 / C-462 D2: a token tap that sends [face] (null without the
  /// roll queue) does it in the tap's own callback. The lift and the
  /// `tap` cue happen only when [_sendMove] accepts. An open picker
  /// closes either way. The hold's own commit does not come through here
  /// (C-417).
  void _sendTokenMove(int token, int k, {int? face}) {
    bool sent = false;
    setState(() {
      _facePick = null;
      sent = _sendMove(token, k, face: face);
      if (sent) {
        // C-426 D3: a token tap that sends `move` clears my timer-played
        // notice.
        _timerPlayedMineVisible = false;
      }
    });
    if (sent) {
      FeedbackScope.of(context).play(FeedbackCue.tap);
    }
  }

  /// C-462 D3: the picked face goes out through [_sendMove]. The picker
  /// closes either way. The tap cue plays only when the send went out.
  void _onFacePicked(int face) {
    final _OpenFacePick? pick = _facePick;
    if (pick == null) {
      return;
    }
    bool sent = false;
    setState(() {
      _facePick = null;
      sent = _sendMove(pick.token, pick.k, face: face);
      if (sent) {
        // C-426 D3: a play that sends `move` clears my timer-played
        // notice. With two or more faces this send is the picker tap,
        // not the token tap (C-462 D3).
        _timerPlayedMineVisible = false;
      }
    });
    if (sent) {
      FeedbackScope.of(context).play(FeedbackCue.tap);
    }
  }

  TokenFacePick? _tokenFacePick(int? seat) {
    final _OpenFacePick? pick = _facePick;
    if (pick == null) {
      return null;
    }
    return TokenFacePick(
      token: pick.token,
      faces: pick.faces,
      seatColor: LudoColors.seats[(seat ?? 0).clamp(0, 3)],
      onPick: _onFacePicked,
    );
  }

  bool _faceIsAlive(List<FaceLegal> legalByFace, int face) {
    for (final FaceLegal entry in legalByFace) {
      if (entry.face == face) {
        return true;
      }
    }
    return false;
  }

  /// K1/K3/K9: what `RollTray` draws, for any `turn` (every viewer reads
  /// the same shared state here, K1's own closing line). The tray's own
  /// dead-faces hold (`_trayDeadFaces`, armed only by `_resolveDeadCandidate`,
  /// K9) wins over a live `turn` while it is up, exactly the way the die's
  /// own `_noMoveVisible` already wins over `turn.value` above.
  (List<int>?, List<TrayDieState>?, Color) _rollTrayData(
    TurnState? turn,
    int? mySeat,
  ) {
    if (_trayDeadFaces != null && _trayDeadFaces!.length >= 2) {
      final List<int> faces = _trayDeadFaces!;
      return (
        faces,
        List<TrayDieState>.filled(faces.length, TrayDieState.dead),
        LudoColors.seats[(_trayDeadSeat ?? 0).clamp(0, 3)],
      );
    }
    if (turn == null) {
      return (null, null, LudoColors.seats[0]);
    }
    final bool showByCount = turn.queue.length >= 2;
    final bool showByAwaitRoll =
        turn.phase == TurnPhase.awaitRoll && turn.queue.isNotEmpty;
    if (!showByCount && !showByAwaitRoll) {
      return (null, null, LudoColors.seats[0]);
    }
    final List<int> faces = turn.queue;
    final Color color = LudoColors.seats[turn.seat.clamp(0, 3)];
    if (turn.phase == TurnPhase.awaitRoll) {
      // K3: no tile is dead while the seat is still owed a roll.
      return (
        faces,
        List<TrayDieState>.filled(faces.length, TrayDieState.plain),
        color,
      );
    }
    // C-462 D6: a face legalByFace still lists is plain. Anything else
    // in the queue is dead. The same face twice shares that one answer.
    final List<FaceLegal>? legalByFace = turn.legalByFace;
    final List<TrayDieState> states = <TrayDieState>[
      for (final int face in faces)
        legalByFace != null && _faceIsAlive(legalByFace, face)
            ? TrayDieState.plain
            : TrayDieState.dead,
    ];
    return (faces, states, color);
  }

  /// C-471 D3. The die's row, with the hint control overlaid on its
  /// leading edge. The control is absent unless the room is PLAYING and
  /// this device holds a seat. C-511 D1/D2: the die, its no-move mark and
  /// the tray keep clear of the control's box plus [kSpace2], and the
  /// tray is handed the width that band leaves it (D3).
  Widget _dieRow(
    RoomSnapshot room,
    int? seat,
    AppLocalizations loc,
    TurnState? turn,
    bool fadeIdleDie,
    int? dieFace,
    Color dieSeatColor,
    bool rollEnabled,
    _PlayColumnMetrics metrics,
    List<int>? trayFaces,
    List<TrayDieState>? trayStates,
    Color trayColor,
    SeatRollRecord? boardRecord,
    bool trayOwnMove,
  ) {
    final HintControlState? hintState = _hintControlState(room, seat);
    final bool hinted = hintState != null && seat != null;
    // C-511 D1: the control's own 48 dp box and the gap after it.
    final double reserved = hinted ? kHintHitWidth + kSpace2 : 0;
    // C-511 D1: the no-move mark hangs off the die's physical right
    // (deadBadgeRect). In RTL that is the side facing the hint.
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final double overhang = hinted && rtl && _noMoveVisible
        ? deadBadgeRect(const Size.square(_dieRowHeight)).right - _dieRowHeight
        : 0;
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _boardDieSlot(
          loc,
          turn,
          // C-468 D7: Opacity is an ancestor of the die's art.
          // The key on the die is unchanged.
          Opacity(
            opacity: fadeIdleDie ? 0.45 : 1,
            child: GameDie(
              face: dieFace,
              seatColor: dieSeatColor,
              enabled: rollEnabled,
              tumbling: _rollWaitK != null,
              noAnswer: _rollNoAnswer,
              noMove: _noMoveVisible,
              // C-404: the die's top sits exactly at the row's own
              // top (it is the tallest thing in the row), which
              // sits `metrics.boardGap` below the board -- the
              // same number board_floor_nav_inset_test.dart
              // measures as die.top - board.bottom. Handing that
              // straight to the die is what lets its badge clamp
              // itself without this column's gaps, clamp or floor
              // changing at all.
              badgeHeadroom: metrics.boardGap,
              onTap: rollEnabled ? _onDieTap : null,
              onInvalidTap: () {
                FeedbackScope.of(context).play(FeedbackCue.invalidTap);
              },
            ),
          ),
        ),
        if (trayFaces != null && boardRecord == null) ...<Widget>[
          const SizedBox(width: kSpace2),
          Flexible(
            child: RollTray(
              key: const Key('game-roll-tray'),
              faces: trayFaces,
              states: trayStates!,
              seatColor: trayColor,
              ownMove: trayOwnMove,
            ),
          ),
        ],
      ],
    );
    final Widget band = _DieBand(
      reserved: reserved,
      overhang: overhang,
      textDirection: Directionality.of(context),
      child: row,
    );
    if (!hinted) {
      return band;
    }
    // The band is the full row width, the same as the Centre that held
    // it. The bulb is a positioned child, not a new child of the row
    // (C-471 D3).
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        band,
        PositionedDirectional(
          start: 0,
          top: 0,
          bottom: 0,
          child: Center(
            child: HintButton(
              state: hintState,
              seatColor: LudoColors.seats[seat.clamp(0, 3)],
              onTap: _onHintTap,
            ),
          ),
        ),
      ],
    );
  }

  /// C-471 D3. Null when the control is not on screen.
  HintControlState? _hintControlState(RoomSnapshot room, int? seat) {
    if (room.state != RoomState.playing || seat == null) {
      return null;
    }
    if (_hintIsUsed(room.gameId)) {
      return HintControlState.used;
    }
    if (!_hintStoreRead || room.gameId == null || !_hintOfferable(room, seat)) {
      return HintControlState.waiting;
    }
    return HintControlState.ready;
  }

  bool _hintIsUsed(String? gameId) {
    if (gameId == null) {
      return false;
    }
    return _spentHintGameId == gameId || _storedHintGameId == gameId;
  }

  /// Offerable only on my await-move, with a game id, and at least two
  /// different choices (C-471 D1). [recommendMove] is that test.
  bool _hintOfferable(RoomSnapshot room, int seat) {
    final TurnState? turn = room.turn;
    if (turn == null ||
        turn.seat != seat ||
        turn.phase != TurnPhase.awaitMove) {
      return false;
    }
    return recommendMove(
          mySeat: seat,
          tokens: _tokensOf(room),
          legal: _hintLegal(turn),
        ) !=
        null;
  }

  /// C-471 D1, in wire order.
  List<(int face, List<int> tokens)> _hintLegal(TurnState turn) {
    final List<FaceLegal>? byFace = turn.legalByFace;
    if (byFace != null) {
      return <(int face, List<int> tokens)>[
        for (final FaceLegal entry in byFace) (entry.face, entry.tokens),
      ];
    }
    final int? value = turn.value;
    final List<int>? legal = turn.legal;
    if (value == null || legal == null) {
      return const <(int face, List<int> tokens)>[];
    }
    return <(int face, List<int> tokens)>[(value, legal)];
  }

  bool _hintNamesFace(List<(int face, List<int> tokens)> legal) {
    final Set<int> faces = <int>{};
    for (final (int face, List<int> tokenList) in legal) {
      if (tokenList.isEmpty) {
        continue;
      }
      faces.add(face);
    }
    return faces.length > 1;
  }

  /// C-471 D3. True only when this tap spent the hint. The used flag is
  /// set before the store write, and before this callback returns.
  bool _onHintTap() {
    final RoomSnapshot? room = widget.controller.room;
    final int? seat = widget.controller.seat;
    if (room == null ||
        seat == null ||
        room.state != RoomState.playing ||
        room.gameId == null ||
        !_hintStoreRead ||
        _hintIsUsed(room.gameId)) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return false;
    }
    final TurnState? turn = room.turn;
    if (turn == null ||
        turn.seat != seat ||
        turn.phase != TurnPhase.awaitMove) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return false;
    }
    final String gameId = room.gameId!;
    final List<(int face, List<int> tokens)> legal = _hintLegal(turn);
    final MoveHint? hint = recommendMove(
      mySeat: seat,
      tokens: _tokensOf(room),
      legal: legal,
    );
    if (hint == null) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return false;
    }
    setState(() {
      _spentHintGameId = gameId;
      _shownHint = _ActiveHint(
        move: hint,
        gameId: gameId,
        k: turn.k,
        seat: seat,
        namesFace: _hintNamesFace(legal),
      );
    });
    unawaited(SessionMemory.recordHintUsed(gameId));
    FeedbackScope.of(context).play(FeedbackCue.tap);
    return true;
  }

  /// C-471 D4. Field write only: this runs at the start of [build].
  void _syncShownHint() {
    final _ActiveHint? shown = _shownHint;
    if (shown == null) {
      return;
    }
    final RoomSnapshot? room = widget.controller.room;
    final int? mySeat = widget.controller.seat;
    final TurnState? turn = room?.turn;
    final bool still =
        room != null &&
        room.state == RoomState.playing &&
        room.gameId == shown.gameId &&
        mySeat != null &&
        mySeat == shown.seat &&
        turn != null &&
        turn.seat == mySeat &&
        turn.phase == TurnPhase.awaitMove &&
        turn.k == shown.k;
    if (!still) {
      _shownHint = null;
    }
  }

  /// H6.3: the room is playing and has at least two seated players. Board,
  /// turn banner, and the die under it. Play itself happens on the board
  /// objects: the die is tapped to roll, a token is tapped to move it.
  Widget _playingBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room, {
    bool stale = false,
  }) {
    final TurnState? turn = room.turn;
    final int? seat = controller.seat;
    final SeatState? offlineTurnSeat = _offlineTurnSeat(room);

    final bool rollEnabled =
        !_isEndHeld &&
        room.state == RoomState.playing &&
        turn != null &&
        turn.seat == seat &&
        turn.phase == TurnPhase.awaitRoll &&
        _rollWaitK == null;

    // C-462 D1: under the roll queue the rings are every token any alive
    // face can move. Without `legalByFace`, `turn.legal` exactly as before.
    final bool myAwaitMove =
        !_isEndHeld &&
        turn != null &&
        turn.seat == seat &&
        turn.phase == TurnPhase.awaitMove;
    final Set<int> legalTokens = myAwaitMove
        ? (turn.legalByFace != null
              ? _legalTokenUnion(turn.legalByFace!)
              : (turn.legal?.toSet() ?? const <int>{}))
        : const <int>{};

    // C-465 D1: with a seat of my own the die under the board is only ever
    // mine. Its colour is my seat colour in every phase. On my own turn
    // the face is still `turn.value` (C-462 D7) and my own tumble. While
    // another seat holds the turn, and my no-move hold is not up, the
    // face is null. Rule 4a is unchanged: for the whole hold the die
    // keeps the face and the colour of the roll that armed it, my own,
    // while the next seat's turn has begun underneath. With no seat, the
    // colour and the face stay what they were (C-377). The no-move hold
    // is only ever armed for my own seat, so a spectator has no separate
    // colour for it.
    final Color dieSeatColor = seat != null
        ? LudoColors.seats[seat.clamp(0, 3)]
        : LudoColors.seats[(turn?.seat ?? 0).clamp(0, 3)];
    final int? rawDieFace = _noMoveVisible
        ? _noMoveFace
        : (seat != null && (turn == null || turn.seat != seat))
        ? null
        : turn?.value;
    final int? dieFace = _boardDieFace(rawDieFace);
    // C-468 D7: the idle die under the board, while another seat holds
    // the turn and my no-move hold is not up. Full opacity otherwise.
    final bool fadeIdleDie =
        seat != null && turn != null && turn.seat != seat && !_noMoveVisible;

    final (
      List<int>? trayFaces,
      List<TrayDieState>? trayStates,
      Color trayColor,
    ) = _rollTrayData(
      turn,
      seat,
    );
    // C-462 D6: the old `trayInteractive` flag, now only a label switch.
    final bool trayOwnMove = myAwaitMove && turn.legalByFace != null;
    // C-465 D4: my record, and a spectator's, stay in the row under the
    // board. Another seat's record is drawn in that seat's yard, so the
    // row under the board does not carry it.
    final int? recordSeat = trayFaces == null ? null : _rollRecordSeat(turn);
    final SeatRollRecord? boardRecord =
        trayFaces != null &&
            trayStates != null &&
            seat != null &&
            recordSeat != null &&
            recordSeat != seat
        ? SeatRollRecord(
            seat: recordSeat,
            faces: trayFaces,
            states: trayStates,
            seatColor: trayColor,
          )
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace2,
        vertical: kSpace2,
      ),
      // C-402 decision 2: the column measures its own shortfall from
      // whatever height it actually has -- this `LayoutBuilder` sits under
      // `SafeArea` already, so both system insets are already out of
      // `constraints` by the time `_resolvePlayColumnMetrics` sees it.
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final _PlayColumnMetrics metrics = _resolvePlayColumnMetrics(
            context,
            loc,
            constraints.maxWidth,
            constraints.maxHeight,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _playHeaderRow(
                loc,
                room,
                seat,
                turn,
                offlineTurnSeat,
                clampScale: metrics.textScaleClamp,
                stale: stale,
              ),
              SizedBox(height: metrics.headerGap),
              Expanded(
                child: LudoBoard(
                  key: const Key('game-screen-board'),
                  tokens: _tokensOf(room),
                  seatsInPlay: _seatsInPlayOf(room),
                  seatNames: _seatNamesOf(room),
                  youLabel: loc.seatYou,
                  turnSeat: turn?.seat,
                  mySeat: seat,
                  legal: legalTokens,
                  autoMoveToken: _isEndHeld ? null : _pendingAutoMoveToken,
                  sentToken: _moveSentToken,
                  onTokenStep: (int stepSeat, int token) =>
                      _onBoardTokenStep(controller, stepSeat),
                  onMoveLanded: _onBoardMoveLanded,
                  onTravelReset: _onBoardTravelReset,
                  safeCue: _safeCue,
                  facePick: _tokenFacePick(seat),
                  onTokenTap: (int index) {
                    if (_isEndHeld) {
                      return;
                    }
                    _cancelPendingHoldForManualMove();
                    final TurnState? liveTurn = turn;
                    final int? k = liveTurn?.k;
                    if (liveTurn == null || k == null) {
                      return;
                    }
                    final List<FaceLegal>? legalByFace = liveTurn.legalByFace;
                    // K6: a server without the roll queue (`legalByFace`
                    // null) sends the byte-identical frame it always did.
                    if (legalByFace == null) {
                      _sendTokenMove(index, k, face: null);
                      return;
                    }
                    // C-462 D2. F is this token's faces, in legalByFace
                    // order. The cue plays only when something is sent
                    // or a picker opens, never when a picker closes.
                    final List<int> faces = _facesForToken(legalByFace, index);
                    final bool openHere =
                        _facePick != null && _facePick!.token == index;
                    if (faces.length >= 2 && openHere) {
                      setState(() {
                        _facePick = null;
                      });
                      return;
                    }
                    if (faces.length >= 2) {
                      setState(() {
                        _facePick = _OpenFacePick(
                          token: index,
                          k: liveTurn.k,
                          queue: List<int>.from(liveTurn.queue),
                          faces: faces,
                        );
                      });
                      FeedbackScope.of(context).play(FeedbackCue.tap);
                      return;
                    }
                    if (faces.length == 1) {
                      _sendTokenMove(index, k, face: faces.single);
                    }
                  },
                  onIllegalTokenTap: (int index) {
                    // Today's illegal tap, and an open picker closes with
                    // it (C-462 D2). The cue is the one this tap already
                    // played; closing adds none.
                    FeedbackScope.of(context).play(FeedbackCue.invalidTap);
                    if (_facePick != null) {
                      setState(() {
                        _facePick = null;
                      });
                    }
                  },
                  overlay: _thrownDieOverlay(seat),
                  seatDice: _seatDiceOf(room),
                  seatRecord: boardRecord,
                  gloat: _gloat,
                  chatPop: _chat == null
                      ? null
                      : BoardChatPop(seat: _chat!.seat, serial: _chat!.serial),
                  hint: _shownHint?.move,
                  hintNamesFace: _shownHint?.namesFace ?? false,
                ),
              ),
              SizedBox(height: metrics.boardGap),
              // K1: the tray sits on the die's own row, after it in reading
              // order -- a plain Row under the ambient Directionality
              // already mirrors that for Arabic, nothing here flips it by
              // hand.
              _dieRow(
                room,
                seat,
                loc,
                turn,
                fadeIdleDie,
                dieFace,
                dieSeatColor,
                rollEnabled,
                metrics,
                trayFaces,
                trayStates,
                trayColor,
                boardRecord,
                trayOwnMove,
              ),
              SizedBox(height: metrics.dieGap),
              _belowDieNoticeSlot(
                loc,
                offlineTurnSeat,
                clampScale: metrics.textScaleClamp,
              ),
              SizedBox(height: metrics.noticeGap),
            ],
          );
        },
      ),
    );
  }

  /// C-250 rule 1: one row between the pip strip and the board, the same
  /// height in every playing state and both locales -- rule 2's chip and
  /// rule 3's countdown ring are what the row holds, and both read
  /// straight off `room.turn`, so none of the die's own overlays (the
  /// tumble, the no-move mark) have to be threaded through here. The chip
  /// sits at the row's logical start and the ring at its end; a `Row`
  /// under the ambient `Directionality` mirrors that for Arabic on its
  /// own, nothing here flips anything by hand.
  ///
  /// C-339 decision 3: at the system's default text size this row is
  /// still exactly the old fixed 44 holding a one-line banner -- that
  /// case returns the literal constant, not a computed value, so it can
  /// never drift from it by a rounding hair. Above that scale the row's
  /// height grows, but only with the scale itself (`_headerRowHeightFor`
  /// never reads `room` or `turn`): the same number for a given scale in
  /// every state, so the board underneath never jumps as the turn
  /// changes. What it grows to is measured, not guessed -- the banner's
  /// own font at the ambient scale, two lines of it (decision 3's "the
  /// banner may take two lines there") plus the chip's fixed vertical
  /// padding, since two lines is what a banner that no longer fits one
  /// line at the chip's width (decision 3's own defect) can need, in
  /// every state alike. The countdown ring itself is untouched by any of
  /// this (the measurement found it "fine at every scale"); it keeps the
  /// old fixed 44 box under its own name, `_countdownRingSize`, below.
  ///
  /// C-391 decision 2: past the clamp the banner and the below-die notice
  /// stop growing -- both are laid out at the clamped scale
  /// [_PlayColumnMetrics.textScaleClamp] resolves to, never the raw system
  /// one, so a system scale past it no longer costs the board anything
  /// more than it already has. Every reader of the system scale on this
  /// row and on the notice is handed that same resolved clamp, so the
  /// row's own height and the banner's own painted size can never disagree
  /// about what scale either was laid out at.
  static const double _headerRowHeightAtRest = 44;
  static const double _countdownRingSize = 44;

  /// C-391's own clamp: the ceiling [_resolvePlayColumnMetrics] starts
  /// from and only comes down from under C-402 decision 3.
  static const double _playColumnTextScaleClamp = 1.5;

  /// C-402 decision 3: how far down from [_playColumnTextScaleClamp] the
  /// header and notice clamp is allowed to come, and no further, once the
  /// gaps alone (down to their own floor of 4 each) still leave the board
  /// short.
  static const double _playColumnTextScaleClampFloor = 1.3;

  /// The die row's own height never moves with the clamp or the shape:
  /// `GameDie` paints at a fixed 72dp regardless of text scale, and the
  /// tray's own dice are smaller still, so the `Row` around them always
  /// settles on the die's height. [_resolvePlayColumnMetrics] needs that
  /// number to know what the header, the gaps and the notice leave the
  /// board.
  static const double _dieRowHeight = 72;

  /// C-391's own floor, carried forward by C-402 decision 1.
  static const double _boardFloor = 324;

  /// The one clamp every reader of the system scale on the header row and
  /// the notice goes through, at whatever `clampScale`
  /// [_resolvePlayColumnMetrics] settled this build on.
  TextScaler _clampedScaler(BuildContext context, double clampScale) {
    return MediaQuery.textScalerOf(context).clamp(maxScaleFactor: clampScale);
  }

  double _headerRowHeightFor(BuildContext context, TextScaler scaler) {
    final double scaleFactor = scaler.scale(100.0) / 100.0;
    if (scaleFactor <= 1.0) {
      return _headerRowHeightAtRest;
    }
    // The banner itself sets no fontSize of its own (only `fontWeight`), so
    // it paints at whatever the ambient `DefaultTextStyle` resolves to --
    // which, under the real tree, is the `Scaffold`'s own `Material`
    // setting it from `Theme.of(context).textTheme.bodyMedium`
    // (`Material.build`), not whatever `DefaultTextStyle.of(context)`
    // would answer from here, above that `Material`.
    final TextStyle bannerStyle = Theme.of(context).textTheme.bodyMedium!;
    final TextPainter template = TextPainter(
      text: TextSpan(text: ' ', style: bannerStyle),
      textDirection: Directionality.of(context),
      textScaler: scaler,
    );
    final double oneLine = template.preferredLineHeight;
    template.dispose();
    final double contentHeight = math.max(kSpace2, oneLine * 2);
    return contentHeight + kSpace1 * 2;
  }

  /// The below-die notice slot reserves whichever of its placeholder
  /// strings (C-250 rule 4; C-426 D5 adds the two timer-played lines)
  /// paints taller at the given scale and width -- the same strings and
  /// the same style `_belowDieNoticeSlot` lays them out with, so this
  /// never guesses a height Flutter would not itself have settled the
  /// real `Stack` on.
  double _noticeHeightFor(
    BuildContext context,
    TextScaler scaler,
    double maxWidth,
    AppLocalizations loc,
  ) {
    final TextStyle style = Theme.of(context).textTheme.bodyMedium!;
    final TextDirection direction = Directionality.of(context);
    double heightOf(String text, {int? maxLines}) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textAlign: TextAlign.center,
        textDirection: direction,
        textScaler: scaler,
        maxLines: maxLines,
        ellipsis: maxLines != null ? '…' : null,
      );
      painter.layout(maxWidth: maxWidth);
      final double height = painter.height;
      painter.dispose();
      return height;
    }

    return math.max(
      math.max(
        // C-474 A2: the two reason lines are measured unbounded, exactly as
        // the plain line is, so the slot is the tallest of the three.
        math.max(heightOf(loc.gameNoMove), heightOf(loc.gameSeatOffline(''))),
        math.max(
          heightOf(loc.gameNoMoveNeedSix),
          heightOf(loc.gameNoMoveNeedExact),
        ),
      ),
      // C-426 D5 (order 428): these two measure at `maxLines: 1`, matching
      // the live Text widgets below -- the slot's own rest height must
      // never be able to grow from either one wrapping to a second line.
      math.max(
        heightOf(loc.gameTimerPlayedMine, maxLines: 1),
        heightOf(loc.gameTimerPlayedOther(''), maxLines: 1),
      ),
    );
  }

  /// C-402 decision 2 replaces the scale-keyed ramp the old
  /// `_playColumnGap` used (tuned on one phone, so it gave back nothing on
  /// a short one and too little on a tall one) with a measured one: how
  /// much height the header, the die row and the notice leave out of what
  /// the column's own `LayoutBuilder` constraint actually has is compared
  /// against the 324 floor, and the four gaps give back exactly that
  /// shortfall -- shared in proportion to each gap's own room above the
  /// shared floor of 4, never below it. At or over the floor with every
  /// gap nominal, nothing shrinks (decision 6).
  ///
  /// C-402 decision 3: if the gaps at 4 each still leave the board short,
  /// the clamp itself is walked down from [_playColumnTextScaleClamp]
  /// toward [_playColumnTextScaleClampFloor] -- never further, and only as
  /// far as the floor needs -- which shrinks the header and the notice
  /// (both growers under C-391 decision 2) and gives the board back the
  /// rest. Both quantities only grow with the clamp, never shrink it, so
  /// a bisection against the one shortfall equation finds the highest
  /// clamp (the smallest shrink) that still reaches 324.
  _PlayColumnMetrics _resolvePlayColumnMetrics(
    BuildContext context,
    AppLocalizations loc,
    double maxWidth,
    double maxHeight,
  ) {
    const double headerGap = kSpace2;
    const double boardGap = kSpace4;
    const double dieGap = kSpace2;
    const double noticeGap = kSpace2;
    const double nominalSum = headerGap + boardGap + dieGap + noticeGap;
    const double gapFloorEach = 4.0;
    const double gapFloorSum = gapFloorEach * 4;

    if (!maxHeight.isFinite || !maxWidth.isFinite) {
      // Unbounded height (a test harness or a scrolling parent): nothing
      // to measure against, so nominal gaps at the ceiling clamp.
      return const _PlayColumnMetrics(
        textScaleClamp: _playColumnTextScaleClamp,
        headerGap: headerGap,
        boardGap: boardGap,
        dieGap: dieGap,
        noticeGap: noticeGap,
      );
    }

    final TextScaler systemScaler = MediaQuery.textScalerOf(context);
    double fixedCostAt(double clamp) {
      final TextScaler scaler = systemScaler.clamp(maxScaleFactor: clamp);
      return _headerRowHeightFor(context, scaler) +
          _dieRowHeight +
          _noticeHeightFor(context, scaler, maxWidth, loc);
    }

    final double neededForFloor = maxHeight - _boardFloor - gapFloorSum;
    double clamp = _playColumnTextScaleClamp;
    if (fixedCostAt(clamp) > neededForFloor) {
      double lo = _playColumnTextScaleClampFloor;
      double hi = clamp;
      if (fixedCostAt(lo) > neededForFloor) {
        // Even at the clamp's floor, with every gap at 4, this shape
        // cannot reach 324 (s6, width-bound anyway). Stop at 1.3.
        clamp = lo;
      } else {
        for (int i = 0; i < 32; i++) {
          final double mid = (lo + hi) / 2;
          if (fixedCostAt(mid) <= neededForFloor) {
            lo = mid;
          } else {
            hi = mid;
          }
        }
        clamp = lo;
      }
    }

    final double fixedCost = fixedCostAt(clamp);
    final double gapSum = (maxHeight - fixedCost - _boardFloor).clamp(
      gapFloorSum,
      nominalSum,
    );
    final double give = nominalSum - gapSum;
    const double room = nominalSum - gapFloorSum;
    double gapFor(double nominal) {
      if (give <= 0) {
        return nominal;
      }
      return nominal - give * ((nominal - gapFloorEach) / room);
    }

    return _PlayColumnMetrics(
      textScaleClamp: clamp,
      headerGap: gapFor(headerGap),
      boardGap: gapFor(boardGap),
      dieGap: gapFor(dieGap),
      noticeGap: gapFor(noticeGap),
    );
  }

  Widget _playHeaderRow(
    AppLocalizations loc,
    RoomSnapshot room,
    int? seat,
    TurnState? turn,
    SeatState? offlineTurnSeat, {
    required double clampScale,
    bool stale = false,
  }) {
    // C-417 D4: the glow is visible exactly while `_autoMoveTimer` is the
    // real 1500ms countdown -- it is only armed (`_startAutoMoveTimer`)
    // once C-408's own wait for the held token's walk has let it start,
    // the same frame board.dart's own `atRestAtTruth` lets the glow (and
    // the arc nested inside it) actually draw.
    final bool autoMoveVisible = !_isEndHeld && _autoMoveTimer != null;
    final String bannerText = _turnBannerText(
      loc,
      room,
      seat,
      stale: stale,
      autoMoveVisible: autoMoveVisible,
    );
    final int turnSeat = turn?.seat ?? seat ?? 0;
    final Color seatColor = LudoColors.seats[turnSeat.clamp(0, 3)];
    final bool myTurn = turn != null && turn.seat == seat;
    final bool offline = offlineTurnSeat != null;
    final TextScaler scaler = _clampedScaler(context, clampScale);
    final double headerRowHeight = _headerRowHeightFor(context, scaler);
    final int bannerMaxLines = headerRowHeight > _headerRowHeightAtRest ? 2 : 1;

    return SizedBox(
      height: headerRowHeight,
      child: Row(
        children: [
          Expanded(
            child: DecoratedBox(
              key: const Key('game-header-chip'),
              decoration: BoxDecoration(
                color: seatColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(kRadiusControl),
                // Rule 2's second signal on my own turn: an outline in my
                // own colour, on top of the chip's own tint, not only the
                // colour itself (doctrine P9).
                border: myTurn ? Border.all(color: seatColor, width: 2) : null,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSpace3,
                  vertical: kSpace1,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      key: const Key('game-header-chip-dot'),
                      decoration: BoxDecoration(
                        color: seatColor,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(width: kSpace2, height: kSpace2),
                    ),
                    const SizedBox(width: kSpace2),
                    // Rule 4's last line: the chip also carries an offline
                    // icon while the turn seat is offline.
                    if (offline) ...[
                      Icon(Icons.wifi_off, size: kSpace4, color: seatColor),
                      const SizedBox(width: kSpace1),
                    ],
                    Expanded(
                      child: Text(
                        bannerText,
                        key: const Key('game-screen-turn-banner'),
                        maxLines: bannerMaxLines,
                        overflow: TextOverflow.ellipsis,
                        // C-391 decision 2: the banner's own text is laid
                        // out at the clamped scale, not the ring's or the
                        // board's ambient one, so it never asks this row
                        // for more than `_headerRowHeightFor` already
                        // measured it at.
                        textScaler: scaler,
                        style: TextStyle(
                          fontWeight: myTurn
                              ? FontWeight.w700
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (turn != null && room.state == RoomState.playing) ...[
            const SizedBox(width: kSpace2),
            _countdownBlock(loc, room, turn, seatColor),
          ],
        ],
      ),
    );
  }

  /// C-250 rule 3 / amendment run 72 (rule 9): the ring depletes with the
  /// turn and turns `LudoColors.error` for the last 10s (the last 3s when
  /// the running segment is itself 10s or shorter, C-495); the Text keyed
  /// `game-screen-turn-countdown` shows only the bare seconds so it fits on
  /// one line inside the ring, and the sentence that used to sit there
  /// moves to the `game-header-countdown-semantics` label, with the
  /// visible digits excluded so TalkBack does not read it twice.
  Widget _countdownBlock(
    AppLocalizations loc,
    RoomSnapshot room,
    TurnState turn,
    Color seatColor,
  ) {
    // C-495 decision 3: the ring measures the segment that is running (an
    // away seat's is 10s, not the room's turn length). An old server sends
    // no segment, so the room's turn length stands in for it.
    final int? segmentMs = turn.segmentMs;
    final int budget = (segmentMs != null && segmentMs > 0)
        ? (segmentMs + 999) ~/ 1000
        : room.rules.turnSeconds;
    final bool shortClock = budget <= 10;
    final bool runningOut = shortClock
        ? _countdownRemainingSeconds <= 3
        : _countdownRemainingSeconds <= 10;
    final Color ringColor = runningOut ? LudoColors.error : seatColor;
    final double remainingFraction = budget > 0
        ? (_countdownRemainingSeconds / budget).clamp(0.0, 1.0)
        : 0.0;

    return Semantics(
      key: const Key('game-header-countdown-semantics'),
      label: loc.gameTurnCountdown(_countdownRemainingSeconds),
      child: SizedBox(
        width: _countdownRingSize,
        height: _countdownRingSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _CountdownRing(
              key: const Key('game-header-countdown-ring'),
              color: ringColor,
              remainingFraction: remainingFraction,
            ),
            ExcludeSemantics(
              child: Text(
                loc.gameTurnCountdownDigits(_countdownRemainingSeconds),
                key: const Key('game-screen-turn-countdown'),
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  color: ringColor,
                  fontWeight: FontWeight.w600,
                  fontSize: kTypeLabel,
                  height: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// C-250 rule 4: the fixed notice slot below the die, shared by the
  /// no-move notice and the seat-offline line rather than giving each its
  /// own reserved space above the board the way the pre-C-250 shape did.
  /// C-426 D5 (order 428) adds the two timer-played lines to the same
  /// slot, at a fixed priority, highest first: `game-no-move-notice`,
  /// `game-timer-played-other-notice`, `game-screen-turn-seat-offline`,
  /// `game-timer-played-notice`. A lower one comes back on its own the
  /// moment a higher one's own condition ends, since this method reads
  /// live state on every build rather than latching a choice. The slot is
  /// sized for the tallest of its placeholder strings (`_noticeHeightFor`)
  /// so switching between any of them never resizes anything underneath.
  /// D5's "each line is one line": the two timer-played lines (and their
  /// own placeholders, measured the same way in `_noticeHeightFor`) carry
  /// `maxLines: 1` and an ellipsis, so neither can ever claim a second
  /// line at rest and move the board underneath -- the two pre-existing
  /// lines are untouched.
  Widget _belowDieNoticeSlot(
    AppLocalizations loc,
    SeatState? offlineTurnSeat, {
    required double clampScale,
  }) {
    // C-391 decision 2: this slot's own texts (the live notice and the
    // placeholders reserving its space) are laid out at the same clamped
    // scale as the header banner -- past the clamp the slot stops growing
    // with the system scale, and the text inside it is capped to match,
    // so the reserved space this Stack settles on from its invisible
    // children always covers whichever one is actually shown.
    final TextScaler scaler = _clampedScaler(context, clampScale);
    final String? timerPlayedOtherName = _timerPlayedOtherName;
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(
              loc.gameNoMove,
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(
              loc.gameNoMoveNeedSix,
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(
              loc.gameNoMoveNeedExact,
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(
              loc.gameSeatOffline(''),
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(
              loc.gameTimerPlayedMine,
              textAlign: TextAlign.center,
              textScaler: scaler,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(
              loc.gameTimerPlayedOther(''),
              textAlign: TextAlign.center,
              textScaler: scaler,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (_noMoveVisible)
          Positioned.fill(
            child: Text(
              _noMoveLine(loc, _noMoveReason),
              key: const Key('game-no-move-notice'),
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          )
        else if (timerPlayedOtherName != null)
          Positioned.fill(
            child: Text(
              loc.gameTimerPlayedOther(timerPlayedOtherName),
              key: const Key('game-timer-played-other-notice'),
              textAlign: TextAlign.center,
              textScaler: scaler,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          )
        else if (offlineTurnSeat != null)
          Positioned.fill(
            child: Text(
              loc.gameSeatOffline(offlineTurnSeat.name),
              key: const Key('game-screen-turn-seat-offline'),
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          )
        else if (_timerPlayedMineVisible)
          Positioned.fill(
            child: Text(
              loc.gameTimerPlayedMine,
              key: const Key('game-timer-played-notice'),
              textAlign: TextAlign.center,
              textScaler: scaler,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  /// C-250 rule 5: `game-screen-dice-value` moves off a visible line and
  /// onto a `Semantics` wrapping the die, present under exactly the
  /// condition the old visible line was (`turn.value` non-null) -- the
  /// die's own face already says it to a sighted player, so nothing
  /// visible repeats it.
  Widget _diceValueWrap(AppLocalizations loc, TurnState? turn, Widget die) {
    if (turn == null || turn.value == null) {
      return die;
    }
    return Semantics(
      key: const Key('game-screen-dice-value'),
      label: loc.gameDieValue(turn.value!),
      child: die,
    );
  }

  /// With no throw up, [_diceValueWrap] exactly as before. While one is
  /// travelling the value is left unannounced (D2). Once it has landed,
  /// the announcement is that throw's face, which is what the die shows.
  /// With a seat of my own the throw never sets this die (C-465 D1).
  /// The node follows the face the die is showing: my turn's value, or
  /// the held face during the no-move hold. While another seat holds the
  /// turn and that hold is not up, the node is absent.
  Widget _boardDieSlot(AppLocalizations loc, TurnState? turn, Widget die) {
    final int? mySeat = widget.controller.seat;
    if (mySeat != null) {
      if (_noMoveVisible) {
        final int? held = _noMoveFace;
        if (held == null) {
          return die;
        }
        return Semantics(
          key: const Key('game-screen-dice-value'),
          label: loc.gameDieValue(held),
          child: die,
        );
      }
      if (turn != null && turn.seat == mySeat) {
        return _diceValueWrap(loc, turn, die);
      }
      return die;
    }
    final _QueuedThrow? active = _activeThrow;
    if (active == null) {
      return _diceValueWrap(loc, turn, die);
    }
    if (_throwConcealsFace) {
      return die;
    }
    return Semantics(
      key: const Key('game-screen-dice-value'),
      label: loc.gameDieValue(active.face),
      child: die,
    );
  }

  /// H6.2 and H7: the game has finished. C-243's `EndCard` carries the
  /// title, the winner's celebration or the loser's warmth, the honest
  /// numbers and the fairness line; this method's own job is only to
  /// resolve the plain values `EndCard` needs and hand them across --
  /// `EndCard` never reads `room` or `controller` itself. The board (when
  /// there are still at least two seats to draw it from) stays visible
  /// underneath, per contract rule 8; roll history is unchanged, the last
  /// three faces. The Roll button and the four token buttons are absent,
  /// not merely disabled, because there is nothing left to press.
  Widget _gameOverBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room, {
    bool rematchGone = false,
    bool isOffline = false,
  }) {
    // C-310 rule 2: when a rematch is open in LOBBY, resolve the finished
    // game's presentation (winner, numbers, loser line, verify link, board)
    // from the last FINISHED snapshot held by the controller.
    // Rule 4: when lastFinished is null (the process was killed and resumed
    // straight into the rematch LOBBY), falling back to room keeps today's
    // ended variant. That is the honest fallback, not a gap to paper over.
    // C-316 rule 2: on a FINISHED room whose gameId equals
    // controller.lastFinished?.gameId, finished is lastFinished so a departed
    // seat does not clear the winner, numbers or board.
    final RoomSnapshot? lastFinished = controller.lastFinished;
    final RoomSnapshot finished =
        (lastFinished != null &&
            ((room.state == RoomState.lobby && room.rematch != null) ||
                (room.state == RoomState.finished &&
                    room.gameId == lastFinished.gameId)))
        ? lastFinished
        : room;

    // C-316 rule 2: departed seats on the end card.
    final RoomSnapshot? departedBaseline =
        lastFinished ?? (room.state == RoomState.finished ? room : null);
    final List<String> departedNames = <String>[];
    bool everyoneLeft = false;
    bool rematchByDeparted = false;

    if (departedBaseline != null) {
      final Set<int> liveSeats = room.seats
          .map((SeatState s) => s.seat)
          .toSet();
      final List<SeatState> pastSeats = List<SeatState>.from(
        departedBaseline.seats,
      )..sort((SeatState a, SeatState b) => a.seat.compareTo(b.seat));
      for (final SeatState s in pastSeats) {
        if (s.seat != controller.seat && !liveSeats.contains(s.seat)) {
          departedNames.add(s.name);
        }
      }
      final bool otherSeatPresent = liveSeats.any(
        (int seat) => seat != controller.seat,
      );
      if (departedNames.isNotEmpty && !otherSeatPresent) {
        everyoneLeft = true;
      }
      final RematchState? rematch = room.rematch;
      if (rematch != null && !liveSeats.contains(rematch.by)) {
        rematchByDeparted = true;
      }
    }

    final bool hasBoard = finished.seats.length >= 2;

    // Rule 4: a winner naming a seat absent from room.seats reads the same
    // as no winner at all (H7.21's own fallback, carried forward).
    // C-310 rule 2: the winner's name comes from finished.seats, so a winner
    // who left after asking is still named.
    String? winnerName;
    if (finished.winner != null) {
      for (final SeatState seatState in finished.seats) {
        if (seatState.seat == finished.winner) {
          winnerName = seatState.name;
          break;
        }
      }
    }
    final int? winnerSeat = winnerName == null ? null : finished.winner;

    // C-246 rule 4: the ask line names `rematch.by`, resolved against
    // live room.seats, falling back to finished.seats if that seat has since
    // left. Null when there is no rematch open, or when `by` is in neither.
    final RematchState? rematch = room.rematch;
    String? rematchByName;
    if (rematch != null) {
      for (final SeatState seatState in room.seats) {
        if (seatState.seat == rematch.by) {
          rematchByName = seatState.name;
          break;
        }
      }
      if (rematchByName == null) {
        for (final SeatState seatState in finished.seats) {
          if (seatState.seat == rematch.by) {
            rematchByName = seatState.name;
            break;
          }
        }
      }
    }

    // C-293 rule 2, amended by C-304 rules 3 and 5, and C-310 rule 2: this
    // seat's numbers, computed from controller's gameTranscript when complete,
    // or from the server's game_log when fetched. Final tokens and steps left
    // come from finished.seats, and the fetched-stats cache is keyed on
    // finished.gameId. The fetch gate stays on live room.state. An incomplete
    // transcript falls back to "N home" alone while the fetch is in flight
    // or if it fails.
    GameStats? stats;
    int? stepsLeft;
    final int? mySeat = controller.seat;
    if (mySeat != null) {
      for (final SeatState seatState in finished.seats) {
        if (seatState.seat == mySeat) {
          stepsLeft = stepsLeftOf(seatState.tokens);
          final GameStats localStats = computeGameStats(
            frames: controller.gameTranscript,
            seat: mySeat,
            finalTokens: seatState.tokens,
          );
          if (localStats.complete) {
            stats = localStats;
          } else if (_fetchedStats != null &&
              _fetchedStatsGameId == finished.gameId) {
            stats = _fetchedStats;
          } else {
            stats = localStats;
            if (room.state == RoomState.finished &&
                !_gameLogFetchInFlight &&
                (_gameLogRequestsCount == 0 ||
                    (_gameLogRequestsCount == 1 &&
                        _gameLogFailedSocketDown &&
                        controller.phase == RoomPhase.connected))) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _maybeFetchGameLog();
              });
            }
          }
          break;
        }
      }
    }

    // The card alone, win or lose, already carries more content than the
    // pre-C-243 single line of text did (a celebration or nudge, up to
    // four stat tiles, the fairness line and two buttons), so this body
    // scrolls rather than being forced into one unscrollable screen the
    // way the playing body is: nothing here is time-pressured the way a
    // turn is, and a RenderFlex overflow would hide content rather than
    // merely look cramped. C-398 pulls the action area out of that scroll
    // and pins it to the bottom of the safe area. The board keeps its own
    // square shape via AspectRatio instead of Expanded, which needs a
    // bounded height a scroll view does not give its children.
    return EndCardFrame(
      card: EndCard(
        mySeat: mySeat,
        winnerSeat: winnerSeat,
        winnerName: winnerName,
        seatColors: LudoColors.seats,
        stats: stats,
        stepsLeft: stepsLeft,
        verifyUrl: finished.verifyUrl,
        onVerify: _openVerifyUrl,
        onNewTable: _requestNewTable,
        rematch: rematch,
        rematchByName: rematchByName,
        occupiedSeats: _seatsInPlayOf(room),
        isHost: controller.isHost,
        rematchGone: rematchGone,
        departedNames: departedNames,
        everyoneLeft: everyoneLeft,
        rematchByDeparted: rematchByDeparted,
        isOffline: isOffline,
        onRematch: _rematchInFlight ? null : () => _onRematchTap(),
        onStartReady: controller.isHost ? controller.startGame : null,
        quickReplies: mySeat == null || isOffline || rematchGone || everyoneLeft
            ? const <String>[]
            : winnerSeat == null
            ? const <String>['good_game']
            : winnerSeat == mySeat
            ? const <String>['good_game', 'ha_ha']
            : const <String>['good_game', 'revenge', 'lucky'],
        onQuickReply: _onChatPick,
        quickReplyCooling: _chatCooling,
      ),
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasBoard) ...[
            const SizedBox(height: kSpace4),
            AspectRatio(
              aspectRatio: 1,
              child: LudoBoard(
                key: const Key('game-screen-board'),
                tokens: _tokensOf(finished),
                seatsInPlay: _seatsInPlayOf(finished),
                seatNames: _seatNamesOf(finished),
                youLabel: loc.seatYou,
                turnSeat: null,
                mySeat: mySeat,
                interactive: false,
                onTokenStep: (int stepSeat, int token) =>
                    _onBoardTokenStep(controller, stepSeat),
                onMoveLanded: _onBoardMoveLanded,
                onTravelReset: _onBoardTravelReset,
              ),
            ),
          ],
          const SizedBox(height: kSpace4),
          _rollHistory(loc, finished),
        ],
      ),
    );
  }

  /// Last faces with their `k` on the finished board. Empty when no `rolled`
  /// frames landed on this controller before game-over.
  Widget _rollHistory(AppLocalizations loc, RoomSnapshot room) {
    final List<(int k, int face)> rolls = room.recentRolls;
    return Column(
      key: const Key('game-screen-roll-history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          loc.gameRollHistoryHeading,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelLarge
              ?.copyWith(fontSize: kTypeLabel, color: LudoColors.inkMuted),
        ),
        if (rolls.isEmpty)
          Text(loc.gameRollHistoryEmpty, textAlign: TextAlign.center)
        else
          for (final (int k, int face) in rolls) ...[
            const SizedBox(height: kSpace1),
            Text(
              loc.gameRollHistoryEntry(k, face),
              textAlign: TextAlign.center,
            ),
          ],
      ],
    );
  }

  /// H8: additive to whatever body the switch above chose. The rest of the
  /// screen keeps rendering the last state it knew.
  Widget _desyncBanner(BuildContext context, AppLocalizations loc) {
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace4,
        vertical: kSpace2,
      ),
      width: double.infinity,
      child: Text(
        loc.lobbyDesynced,
        key: const Key('game-screen-desync-banner'),
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }

  /// C-304 rules 3, 4, 5: when the end card is up and local gameTranscript
  /// stats are incomplete, requests game_log from the server at most once,
  /// plus one more only if the first failed because the socket was down and
  /// a later reconnect succeeded while the card is still up.
  void _maybeFetchGameLog() {
    if (!mounted) {
      return;
    }
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    if (room == null) {
      return;
    }
    final String? gameId = room.gameId;
    if (gameId == null || gameId.isEmpty) {
      return;
    }
    final bool endCardUp = !_isEndHeld && room.state == RoomState.finished;
    if (!endCardUp) {
      return;
    }
    final int? mySeat = controller.seat;
    if (mySeat == null) {
      return;
    }
    SeatState? mySeatState;
    for (final SeatState s in room.seats) {
      if (s.seat == mySeat) {
        mySeatState = s;
        break;
      }
    }
    if (mySeatState == null) {
      return;
    }

    // Rule 5: No request when the transcript is complete.
    final GameStats localStats = computeGameStats(
      frames: controller.gameTranscript,
      seat: mySeat,
      finalTokens: mySeatState.tokens,
    );
    if (localStats.complete) {
      return;
    }

    if (_fetchedStats != null && _fetchedStatsGameId == gameId) {
      return;
    }

    // Rule 4: at most one request per game, plus one more only if the first
    // failed because the socket was down and a later reconnect succeeded
    // while the card is still up. Never a retry loop.
    if (_gameLogFetchInFlight) {
      return;
    }
    if (_gameLogRequestsCount >= 2) {
      return;
    }
    if (_gameLogRequestsCount == 1) {
      if (!_gameLogFailedSocketDown ||
          controller.phase != RoomPhase.connected) {
        return;
      }
    } else {
      if (controller.phase != RoomPhase.connected) {
        return;
      }
    }

    _fetchGameLog(gameId, mySeat, mySeatState.tokens);
  }

  Future<void> _fetchGameLog(
    String targetGameId,
    int mySeat,
    List<int> finalTokens,
  ) async {
    _gameLogFetchInFlight = true;
    _gameLogTargetId = targetGameId;
    _gameLogRequestsCount++;
    try {
      final List<Frame> frames = await widget.controller.fetchGameLog();
      if (!mounted) {
        return;
      }
      final RoomSnapshot? room = widget.controller.room;
      // C-316 rule 5: the answer is kept when its game is the finished game
      // the card shows (lastFinished.gameId, or the FINISHED room's own id
      // when the fetch started); discarded only when a new game has started
      // since.
      final String? showingGameId =
          widget.controller.lastFinished?.gameId ?? room?.gameId;
      if (showingGameId != targetGameId) {
        return;
      }
      if (room != null &&
          room.state == RoomState.playing &&
          room.gameId != targetGameId) {
        return;
      }
      if (frames.isEmpty) {
        return;
      }
      final Frame first = frames.first;
      if (first.type != 'game_started') {
        return;
      }
      final Object? logGameId = first.data['game_id'];
      if (logGameId is! String || logGameId != targetGameId) {
        return;
      }
      final RoomSnapshot? finished = widget.controller.lastFinished;
      SeatState? currentSeatState;
      if (finished != null) {
        for (final SeatState s in finished.seats) {
          if (s.seat == mySeat) {
            currentSeatState = s;
            break;
          }
        }
      } else if (room != null) {
        for (final SeatState s in room.seats) {
          if (s.seat == mySeat) {
            currentSeatState = s;
            break;
          }
        }
      }
      final List<int> tokens = currentSeatState?.tokens ?? finalTokens;
      final GameStats stats = computeGameStats(
        frames: frames,
        seat: mySeat,
        finalTokens: tokens,
      );
      setState(() {
        _fetchedStats = stats;
        _fetchedStatsGameId = targetGameId;
      });
    } on ConnectionClosedException {
      _gameLogFailedSocketDown = true;
    } on ProtocolErrorException {
      _gameLogFailedSocketDown = widget.controller.phase != RoomPhase.connected;
    } on RequestTimeoutException {
      _gameLogFailedSocketDown = widget.controller.phase != RoomPhase.connected;
    } on FrameFormatException {
      _gameLogFailedSocketDown = widget.controller.phase != RoomPhase.connected;
    } finally {
      _gameLogFetchInFlight = false;
    }
  }
}

/// C-250 rule 8: the countdown's own ring, key `game-header-countdown-ring`,
/// exposing the colour it is currently painted with as a plain public
/// field rather than making a caller re-derive it from the seconds left.
/// Amendment run 72 (rule 9a): it expands to fill whatever box the
/// countdown block gives it, rather than staying a childless `CustomPaint`
/// that would otherwise paint at `Size.zero`. The depleting sweep itself is
/// Canvas work (`_CountdownRingPainter`); nothing about "is it red yet"
/// lives there, only "what colour was I given".
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    super.key,
    required this.color,
    required this.remainingFraction,
  });

  /// The turn seat's own colour, `LudoColors.error` at 10s left and below
  /// on a segment longer than 10s, at 3s and below on a segment of 10s or
  /// less (C-250 rule 8, C-495 decision 3).
  final Color color;

  /// 0.0 (deadline reached) to 1.0 (a fresh turn): how much of the turn is
  /// still left, the fraction of the ring the sweep still covers.
  final double remainingFraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: CustomPaint(
        painter: _CountdownRingPainter(
          color: color,
          remainingFraction: remainingFraction,
        ),
      ),
    );
  }
}

class _CountdownRingPainter extends CustomPainter {
  const _CountdownRingPainter({
    required this.color,
    required this.remainingFraction,
  });

  final Color color;
  final double remainingFraction;

  static const double _strokeWidth = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Rect.fromLTWH(
      _strokeWidth / 2,
      _strokeWidth / 2,
      size.width - _strokeWidth,
      size.height - _strokeWidth,
    );
    final Paint track = Paint()
      ..color = LudoColors.inkMuted.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    canvas.drawOval(bounds, track);

    if (remainingFraction <= 0) {
      return;
    }
    final Paint sweep = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      bounds,
      -math.pi / 2,
      2 * math.pi * remainingFraction,
      false,
      sweep,
    );
  }

  @override
  bool shouldRepaint(covariant _CountdownRingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.remainingFraction != remainingFraction;
}

/// H1: a map from each seat's `seat` to that seat's `tokens` list, taken
/// straight from `room.seats`.
Map<int, List<int>> _tokensOf(RoomSnapshot room) {
  return <int, List<int>>{
    for (final SeatState seatState in room.seats)
      seatState.seat: seatState.tokens,
  };
}

/// H1: the `seat` of every entry in `room.seats`, in the order they appear.
List<int> _seatsInPlayOf(RoomSnapshot room) {
  return <int>[for (final SeatState seatState in room.seats) seatState.seat];
}

/// C-257 rule 1/3: each occupied seat's own `name` from `room.seats`,
/// keyed by seat. `LudoBoard` decides who gets a chip from this and
/// `seatsInPlay` together; this function only reports what the room said.
Map<int, String> _seatNamesOf(RoomSnapshot room) {
  return <int, String>{
    for (final SeatState seatState in room.seats)
      seatState.seat: seatState.name,
  };
}

/// H2, decided in the order given there, first match wins.
/// C-290 rule 2: finished beats every other case, including stale.
/// C-417 D4: inside the awaitMove branch, stale still beats the auto-move
/// line (stale is a connection problem, C-290's own order over it is
/// unchanged), but once the unique-legal hold's glow is actually visible
/// [autoMoveVisible] beats the plain move line under it.
String _turnBannerText(
  AppLocalizations loc,
  RoomSnapshot room,
  int? seat, {
  bool stale = false,
  bool autoMoveVisible = false,
}) {
  if (room.state == RoomState.finished ||
      room.turn?.phase == TurnPhase.finished) {
    return loc.gameOverEnded;
  }
  final TurnState? turn = room.turn;
  if (turn == null) {
    return loc.gameWaitingForTurn;
  }
  if (turn.seat == seat) {
    if (turn.phase == TurnPhase.awaitRoll) {
      return stale ? loc.gameYourTurnStale : loc.gameYourTurnRoll;
    }
    if (turn.phase == TurnPhase.awaitMove) {
      if (stale) {
        return loc.gameYourTurnStale;
      }
      if (autoMoveVisible) {
        return loc.gameAutoMoving;
      }
      return loc.gameYourTurnMove;
    }
  }
  return _waitingForSeatText(loc, room, turn.seat);
}

/// Names the seat `turnSeat` the same way [_turnBannerText] does once it
/// has decided the turn is not this player's own: the matching seat's
/// `name` in `loc.gameWaitingForPlayer`, or `loc.gameWaitingForTurn` if no
/// entry in `room.seats` carries `turnSeat`. Called from [_turnBannerText].
String _waitingForSeatText(
  AppLocalizations loc,
  RoomSnapshot room,
  int turnSeat,
) {
  for (final SeatState seatState in room.seats) {
    if (seatState.seat == turnSeat) {
      return loc.gameWaitingForPlayer(seatState.name);
    }
  }
  return loc.gameWaitingForTurn;
}

/// The seat whose turn it currently is, when that seat's socket has
/// dropped: `room.turn` names a seat, that seat has an entry in
/// `room.seats`, and that entry's `connected` is `false`. Null in every
/// other case, including when there is no current turn at all or when the
/// turn names a seat absent from `room.seats`. Backs the offline line
/// `_playingBody` renders under the turn banner; does not touch
/// [_turnBannerText] or [_waitingForSeatText].
SeatState? _offlineTurnSeat(RoomSnapshot room) {
  final TurnState? turn = room.turn;
  if (turn == null) {
    return null;
  }
  for (final SeatState seatState in room.seats) {
    if (seatState.seat == turn.seat) {
      return seatState.connected ? null : seatState;
    }
  }
  return null;
}

/// `data[key]` from a frame's `d`, when present and an `int`; null
/// otherwise. Mirrors feedback.dart's own private `_intAt` -- duplicated
/// here rather than exported, since this screen's one use of it (reading
/// the face a `rolled` carried, to arm or drop the no-move hold) has
/// nothing to do with cue derivation.
int? _intAt(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  return value is int ? value : null;
}

/// `data[key]` from a frame's `d`, when present and a `String`; null
/// otherwise. C-246: reads `game_started`'s own `game_id` to decide
/// whether a new game has begun.
String? _stringAt(Map<String, Object?> data, String key) {
  final Object? value = data[key];
  return value is String ? value : null;
}

/// What `_resolvePlayColumnMetrics` settled this build on: the clamp the
/// header and the notice are laid out at (C-402 decision 3), and the four
/// play-column gaps (C-402 decision 2), in the same order they appear in
/// the column -- after the header, after the board, after the die row,
/// after the notice.
class _PlayColumnMetrics {
  const _PlayColumnMetrics({
    required this.textScaleClamp,
    required this.headerGap,
    required this.boardGap,
    required this.dieGap,
    required this.noticeGap,
  });

  final double textScaleClamp;
  final double headerGap;
  final double boardGap;
  final double dieGap;
  final double noticeGap;
}

/// One opponent roll waiting to be thrown, or the one currently in flight.
class _QueuedThrow {
  _QueuedThrow({required this.k, required this.seat, required this.face});

  final int k;
  final int seat;
  final int face;

  /// C-468 D4: set the moment this throw's landing is heard, so a later
  /// phase of the same throw does not play it again.
  bool dieLandPlayed = false;
}

/// Pairs in [next] that were appended to [prev], or null when [next] is
/// not an append (the ring was replaced). The ring keeps three and drops
/// from the front, so an append shares a suffix of [prev] with a prefix
/// of [next]. The empty suffix only counts when [prev] itself is empty.
List<(int k, int face)>? _appendedRolls(
  List<(int k, int face)> prev,
  List<(int k, int face)> next,
) {
  for (int drop = 0; drop <= prev.length; drop++) {
    final int keep = prev.length - drop;
    if (keep > next.length) {
      continue;
    }
    bool match = true;
    for (int i = 0; i < keep; i++) {
      if (prev[drop + i] != next[i]) {
        match = false;
        break;
      }
    }
    if (!match) {
      continue;
    }
    if (drop == prev.length && prev.isNotEmpty) {
      return null;
    }
    return next.sublist(keep);
  }
  return null;
}

/// Another seat already stands on the mover's destination. Progress
/// outside the main track is not an absolute square, so it does not count.
bool _otherSeatOnSquare(RoomSnapshot room, int moverSeat, int to) {
  final BoardCell dest = cellFor(seat: moverSeat, progress: to);
  for (final SeatState seatState in room.seats) {
    if (seatState.seat == moverSeat) {
      continue;
    }
    for (final int progress in seatState.tokens) {
      if (progress < 0 || progress > 51) {
        continue;
      }
      if (cellFor(seat: seatState.seat, progress: progress) == dest) {
        return true;
      }
    }
  }
  return false;
}

bool _cellIsSafe(BoardCell cell) {
  for (final int absolute in safeTrackSquares) {
    if (safeSquareCell(absolute) == cell) {
      return true;
    }
  }
  return false;
}

/// C-384: one qualifying move waiting for its landing.
class _PendingSafeCue {
  _PendingSafeCue({
    required this.seat,
    required this.token,
    required this.progress,
    required this.star,
  });

  final int seat;
  final int token;
  final int progress;
  final bool star;
  Timer? fallbackTimer;
}

/// C-511 D2. Places the die row's content in the row's own width: where
/// it, centred, stays clear of the hint's reserved extent, exactly as the
/// `Center` it replaces; otherwise its start edge sits at the extent's
/// end. [reserved] is the hint's box plus the gap; [overhang] is how far
/// the no-move mark hangs past the die on the start side (RTL only), which
/// counts as content. The child is laid out in what the band leaves, so
/// the tray's `Flexible` is handed the width after the extent, the die and
/// the gap (D3).
class _DieBand extends SingleChildRenderObjectWidget {
  const _DieBand({
    required this.reserved,
    required this.overhang,
    required this.textDirection,
    required super.child,
  });

  final double reserved;
  final double overhang;
  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDieBand(reserved, overhang, textDirection);

  @override
  void updateRenderObject(BuildContext context, _RenderDieBand renderObject) {
    renderObject
      ..reserved = reserved
      ..overhang = overhang
      ..textDirection = textDirection;
  }
}

class _RenderDieBand extends RenderShiftedBox {
  _RenderDieBand(this._reserved, this._overhang, this._textDirection)
    : super(null);

  double _reserved;
  double _overhang;
  TextDirection _textDirection;

  set reserved(double value) {
    if (value != _reserved) {
      _reserved = value;
      markNeedsLayout();
    }
  }

  set overhang(double value) {
    if (value != _overhang) {
      _overhang = value;
      markNeedsLayout();
    }
  }

  set textDirection(TextDirection value) {
    if (value != _textDirection) {
      _textDirection = value;
      markNeedsLayout();
    }
  }

  double get _lead => _reserved + _overhang;

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth) {
      return constraints.loosen();
    }
    return BoxConstraints(
      maxWidth: math.max(0, constraints.maxWidth - _lead),
      maxHeight: constraints.maxHeight,
    );
  }

  Size _sizeFor(BoxConstraints constraints, Size childSize) {
    if (!constraints.hasBoundedWidth) {
      return constraints.constrain(childSize);
    }
    return constraints.constrain(Size(constraints.maxWidth, childSize.height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? child = this.child;
    if (child == null) {
      return constraints.smallest;
    }
    return _sizeFor(
      constraints,
      child.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = _sizeFor(constraints, child.size);
    double start = (size.width - child.size.width) / 2;
    if (start < _lead) {
      start = _lead;
    }
    final double dx = _textDirection == TextDirection.ltr
        ? start
        : size.width - start - child.size.width;
    (child.parentData! as BoxParentData).offset = Offset(dx, 0);
  }
}

/// C-492 D6: centres the header band's line on the row. A line that fits is
/// centred vertically; a taller one starts at the row's top and paints down
/// over the body. The row's own size is kept, so the line takes no space.
class _HeaderBandLine extends SingleChildLayoutDelegate {
  _HeaderBandLine(this.maxWidth);

  final double maxWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(maxWidth: maxWidth);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return Offset(
      (size.width - childSize.width) / 2,
      math.max(0, (size.height - childSize.height) / 2),
    );
  }

  @override
  bool shouldRelayout(_HeaderBandLine oldDelegate) {
    return oldDelegate.maxWidth != maxWidth;
  }
}

/// The quick message line: the preset id, the seat that said it, the start
/// serial the bubble and the chip pop restart on, and the timer that takes it
/// down.
class _ChatEntry {
  _ChatEntry({
    required this.id,
    required this.seat,
    required this.serial,
    required this.clearOfChatButton,
    required this.timer,
  });

  final String id;
  final int seat;
  final int serial;

  /// Whether the chat button was on the header row when the line was born, so
  /// the line keeps clear of it after the button goes. C-500 D4.
  final bool clearOfChatButton;
  final Timer timer;
}

/// C-468 D5: one capture waiting for the mover's landing.
class _PendingGloat {
  _PendingGloat({
    required this.seat,
    required this.token,
    required this.capturedSeats,
  });

  final int seat;
  final int token;
  final List<int> capturedSeats;
  Timer? fallbackTimer;
}

/// C-268 rules 3 to 5: landing cues held for mover (seat, token).
class _PendingLandingCues {
  _PendingLandingCues({
    required this.seat,
    required this.token,
    required this.cues,
  });

  final int seat;
  final int token;
  final List<FeedbackCue> cues;
  Timer? fallbackTimer;
}
