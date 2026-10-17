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
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'board.dart';
import 'die_cube.dart';
import 'die_mark.dart';
import 'end_card.dart';
import 'feedback.dart';
import 'feedback_settings_sheet.dart';
import 'game_die.dart';
import 'game_stats.dart';
import 'net/connection.dart';
import 'net/frame.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'roll_tray.dart';
import 'safe_cue.dart';
import 'theme.dart';

/// Distinct [Navigator.pop] result from the finished-board next-table
/// button, or a forced removal from the room. The corner leave control
/// pops with no result, so the screen that pushed this route can leave()
/// and dispose the old controller without opening another table.
enum GameScreenResult { newTable, removed }

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
  // elapses without cancel.
  static const Duration _autoMoveHold = Duration(milliseconds: 1500);
  Timer? _autoMoveTimer;
  int? _pendingAutoMoveToken;
  int? _autoMoveHandledK;
  List<int>? _autoMoveHandledQueue;

  // K8 (order 365, C-362 Part B): the face the auto-move hold's single
  // legal entry would spend, alongside the token above. Null under the
  // `legal.length == 1` fallback for a server with no roll queue.
  int? _pendingAutoMoveFace;

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

  // K4: the face selected to spend from the queue, and the (k, queue)
  // pair it was last reset against, so a manual tray tap is not undone by
  // the next frame that merely repeats the same turn (a countdown tick,
  // say) rather than genuinely moving it on.
  int? _selectedFace;
  int? _selectedFaceSeenK;
  List<int>? _selectedFaceSeenQueue;

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

  /// True while the active throw is still travelling, so the die under the
  /// board shows the idle cube instead of the face (C-377 D2).
  bool _throwConcealsFace = false;

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

  // C-293 rule 3: the last `turn` frame in gameTranscript when this screen
  // mounted, if any. Tied to mount time so the initial your_turn cue cannot
  // play a second time through _onFrame.
  Frame? _mountTurnFrame;
  bool _checkedMountTurnCue = false;

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

  @override
  void initState() {
    super.initState();
    _currentGameId = widget.controller.room?.gameId;
    _mountTurnFrame = _lastTurnFrame(widget.controller.gameTranscript);
    _seenRolls = List<(int k, int face)>.of(
      widget.controller.room?.recentRolls ?? const <(int k, int face)>[],
    );
    widget.controller.addListener(_onControllerChanged);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeFetchGameLog();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkMountTurnCue();
    _releaseMoveGuard();
    _syncSelectedFace();
    _syncAutoMove();
    _syncConnectionLostAnnouncement();
  }

  @override
  void dispose() {
    _screenDisposed = true;
    _countdownTimer?.cancel();
    _autoMoveTimer?.cancel();
    _rollNoAnswerTimer?.cancel();
    _noMoveTimer?.cancel();
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
    }

    final bool zeroTravel =
        frame.type == 'moved' && from != null && to != null && from == to;

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
  void _playCue(FeedbackService feedback, FeedbackCue cue) {
    feedback.play(cue);
    final String? message = _announcementFor(cue);
    if (message != null) {
      _announce(message);
    }
  }

  /// Rule 1's table. Rule 2: `canMove`, `step` and `invalidTap` are not
  /// felt-event words for a screen reader -- the die and the legal tokens
  /// already carry labels -- and answer null here, which [_playCue] takes
  /// as "nothing to announce", never an empty string sent to
  /// [SemanticsService].
  String? _announcementFor(FeedbackCue cue) {
    final AppLocalizations loc = AppLocalizations.of(context);
    switch (cue) {
      case FeedbackCue.yourTurn:
        return loc.gameYourTurnStale;
      case FeedbackCue.noMove:
        return loc.gameNoMove;
      case FeedbackCue.capturedOther:
        return loc.announceCapturedOther;
      case FeedbackCue.capturedMe:
        return loc.announceCapturedMe;
      case FeedbackCue.home:
        return loc.announceHome;
      case FeedbackCue.win:
        return loc.gameOverYouWin;
      case FeedbackCue.gameOver:
        return _gameOverAnnouncement(loc);
      case FeedbackCue.canMove:
      case FeedbackCue.step:
      case FeedbackCue.invalidTap:
        return null;
    }
  }

  /// Rule 1's `gameOver` row: the winner's name, read off the room the same
  /// way [_gameOverBody] itself resolves it, or [AppLocalizations.gameOverEnded]
  /// when the winning seat cannot be named (no winner sent, or a winner
  /// naming a seat no longer in the room).
  String _gameOverAnnouncement(AppLocalizations loc) {
    final RoomSnapshot? room = widget.controller.room;
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
    if (_isEndHeld && _travelCount == 0 && _endHoldDwellTimer == null) {
      _endHoldDwellTimer = Timer(kEndCardDwell, _releaseEndHold);
    }
    _onSafeCueLanded(seat, token);
  }

  void _onBoardTravelReset() {
    _travelCount = 0;
    _safeCueLandingsToIgnore = 0;
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
  /// guard, and the roll-wait tumble and its no-answer line. The countdown
  /// memo is untouched on purpose (rule 5's own text, "not simplified"):
  /// `_syncCountdown` already restarts it on its own the moment the room
  /// stops showing a playing board (FINISHED, then the rematch LOBBY in
  /// between), which a new game always passes through first.
  void _resetForNewGame() {
    _noMoveTimer?.cancel();
    _noMoveTimer = null;
    _noMoveVisible = false;
    _noMoveFace = null;
    _autoMoveTimer?.cancel();
    _autoMoveTimer = null;
    _pendingAutoMoveToken = null;
    _pendingAutoMoveFace = null;
    _autoMoveHandledK = null;
    _autoMoveHandledQueue = null;
    _moveSentForK = null;
    _moveSentForQueue = null;
    _moveGuardSerial = null;
    _rollNoAnswerTimer?.cancel();
    _rollNoAnswerTimer = null;
    _rollWaitK = null;
    _rollNoAnswer = false;
    _clearThrows();
    _lastKnownQueue.clear();
    _dropDeadCandidate();
    _trayDeadTimer?.cancel();
    _trayDeadTimer = null;
    _trayDeadSeat = null;
    _trayDeadFaces = null;
    _selectedFace = null;
    _selectedFaceSeenK = null;
    _selectedFaceSeenQueue = null;
    _dropPendingLandingCues();
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
  }

  void _armNoMoveHold(int? face) {
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
  }

  /// Drops the guard when the `controller.move` call numbered [serial]
  /// finishes, if that call still owns the guard.
  void _dropMoveGuardFor(int serial) {
    if (_moveGuardSerial != serial) {
      return;
    }
    _moveSentForK = null;
    _moveSentForQueue = null;
    _moveGuardSerial = null;
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

  /// K4, amended by the master mid-order: the selected face starts as
  /// `legalByFace.first.face`, not `turn.value`. ENGINE_API.md 10.1 names
  /// that `defaultFace` -- the first-queued face with a legal token, and
  /// `legal_by_face` is already in that order and lists only live faces
  /// (21.1). After a pushed `turn` frame the two agree; after a `rolled`
  /// that leaves a move pending (no `turn` follows it, 21.3's own frame
  /// table) the model's `turn.value` is the face just rolled, which is
  /// wrong for the default whenever that roll was not the first-queued
  /// one still alive. Resets on every reduced turn frame whose `k` or
  /// `queue` differs from the last one this screen reset against -- not
  /// on every rebuild, so a manual tray tap (K5) is not undone by the
  /// next frame that merely repeats the same (k, queue), like a countdown
  /// tick.
  void _syncSelectedFace() {
    final TurnState? turn = widget.controller.room?.turn;
    final List<FaceLegal>? legalByFace = turn?.legalByFace;
    if (turn == null ||
        turn.phase != TurnPhase.awaitMove ||
        legalByFace == null ||
        legalByFace.isEmpty) {
      _selectedFace = null;
      _selectedFaceSeenK = null;
      _selectedFaceSeenQueue = null;
      return;
    }
    final bool changed =
        _selectedFaceSeenK != turn.k ||
        !_sameFaces(_selectedFaceSeenQueue, turn.queue);
    if (changed) {
      _selectedFace = legalByFace.first.face;
      _selectedFaceSeenK = turn.k;
      _selectedFaceSeenQueue = List<int>.from(turn.queue);
    }
  }

  void _onControllerChanged() {
    final RoomController controller = widget.controller;
    if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      _travelCount = 0;
    }
    _syncOpponentThrows();
    setState(() {
      _syncCountdown();
      _releaseMoveGuard();
      _syncSelectedFace();
      _syncAutoMove();
      _syncRollWait();
    });
    _syncConnectionLostAnnouncement();
    _maybeFetchGameLog();
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
    // until the tumble ends.
    _throwConcealsFace = !MediaQuery.disableAnimationsOf(context);
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
  }

  void _onThrowPhase(ThrownDiePhase phase) {
    final bool conceal = phase == ThrownDiePhase.tumble;
    if (conceal == _throwConcealsFace || !mounted) {
      return;
    }
    setState(() {
      _throwConcealsFace = conceal;
    });
  }

  void _onThrowDone() {
    if (!mounted) {
      return;
    }
    setState(() {
      _activeThrow = null;
      _throwConcealsFace = false;
      _throwHurry = false;
      _startNextThrow();
    });
  }

  /// The face under the board (C-377 D2). While a throw is still
  /// travelling, none: the idle cube, so the result is not given away.
  /// From the moment that throw lands, its own face, including when a
  /// later roll has already replaced `turn.value`. With no throw up, the
  /// caller's face (turn value, selected tray face, or the no-move hold).
  int? _boardDieFace(int? dieFace) {
    final _QueuedThrow? active = _activeThrow;
    if (active == null) {
      return dieFace;
    }
    if (_throwConcealsFace) {
      return null;
    }
    return active.face;
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

  /// Tapping the die while it would roll: haptic now, start the tumble,
  /// send the intention. C-236 rule 5: this `HapticFeedback.lightImpact()`
  /// is a tap acknowledgement, not a game event, and stays alongside the
  /// feedback service rather than being folded into it; `yourTurn` and
  /// `canMove`/`noMove` for the roll that follows are played separately,
  /// from `_onFrame`, once the server's own `rolled` frame lands.
  void _onDieTap() {
    if (_isEndHeld) {
      return;
    }
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null) {
      return;
    }
    HapticFeedback.lightImpact();
    _rollNoAnswerTimer?.cancel();
    setState(() {
      _rollWaitK = turn.k;
      _rollNoAnswer = false;
    });
    _rollNoAnswerTimer = Timer(_rollNoAnswerDelay, _onRollNoAnswer);
    widget.controller.roll();
  }

  /// Clears the tumble the moment any of the three things that end it (a
  /// fresh roll for my seat, the turn no longer being mine) shows up in a
  /// new snapshot. The 4s no-answer route clears it itself, in
  /// [_onRollNoAnswer], since nothing about the snapshot changes there.
  void _syncRollWait() {
    final int? waitK = _rollWaitK;
    if (waitK == null) {
      return;
    }
    final RoomController controller = widget.controller;
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

  /// 4 seconds after a rolling tap with no new roll result: stop the
  /// tumble, show the last known face, and show the no-answer line until
  /// the next tap. A dropped connection is handled by rule 1 in [build]
  /// instead, so this only needs to guard against firing into a screen
  /// that has already moved past the playing body.
  void _onRollNoAnswer() {
    if (!mounted) {
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
    _autoMoveTimer?.cancel();
    _autoMoveTimer = Timer(_autoMoveHold, _commitPendingAutoMove);
    final AppLocalizations loc = AppLocalizations.of(context);
    _announceAutoMove(loc.gameTokenButton(_pendingAutoMoveToken! + 1));
  }

  void _clearPendingHold() {
    _autoMoveTimer?.cancel();
    _autoMoveTimer = null;
    _pendingAutoMoveToken = null;
    _pendingAutoMoveFace = null;
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
  void _sendMove(int token, int k, {int? face}) {
    final TurnState? turn = widget.controller.room?.turn;
    if (turn == null ||
        turn.seat != widget.controller.seat ||
        turn.phase != TurnPhase.awaitMove ||
        turn.k != k) {
      return;
    }
    if (_moveSentForK == k && _sameFaces(_moveSentForQueue, turn.queue)) {
      return;
    }
    final int serial = ++_moveSendSerial;
    _moveSentForK = k;
    _moveSentForQueue = List<int>.from(turn.queue);
    _moveGuardSerial = serial;
    unawaited(
      widget.controller.move(token, face: face).whenComplete(() {
        _dropMoveGuardFor(serial);
      }),
    );
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
            child: Column(
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
                            (room != null && room.state == RoomState.playing)
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
                          onPressed: () => _handleLeaveRequest(context, loc),
                          icon: const Icon(Icons.close),
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
                          onPressed: () => showFeedbackSettingsSheet(context),
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
          ),
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

  /// K7: `face`'s own tokens out of `legalByFace`, or none when `face` is
  /// null or not (no longer) one of the queued, alive faces.
  Set<int> _legalTokensForFace(List<FaceLegal> legalByFace, int? face) {
    if (face == null) {
      return const <int>{};
    }
    for (final FaceLegal entry in legalByFace) {
      if (entry.face == face) {
        return entry.tokens.toSet();
      }
    }
    return const <int>{};
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
      // K3: no die is selected or dead while the seat is still owed a
      // roll.
      return (
        faces,
        List<TrayDieState>.filled(faces.length, TrayDieState.plain),
        color,
      );
    }
    final List<FaceLegal>? legalByFace = turn.legalByFace;
    // A queue can hold the same face twice (two queued 6s): exactly one
    // die is ever selected (the master's ruling on defect 1), the first
    // queue index carrying the selected face. Any later die with that
    // same face is alive but plain, reading as `trayDieCanMove`, never a
    // second `selected`.
    final List<TrayDieState> states = <TrayDieState>[];
    bool selectedTaken = false;
    for (final int face in faces) {
      if (!selectedTaken && face == _selectedFace) {
        states.add(TrayDieState.selected);
        selectedTaken = true;
      } else if (legalByFace != null && _faceIsAlive(legalByFace, face)) {
        states.add(TrayDieState.plain);
      } else {
        states.add(TrayDieState.dead);
      }
    }
    return (faces, states, color);
  }

  /// K5: a tap on an alive, unselected tray die. `RollTray` itself already
  /// guards every other case (not interactive, the selected die, a dead
  /// die), so reaching this at all means the tap is live.
  void _onTraySelect(int face) {
    if (_selectedFace == face) {
      return;
    }
    setState(() {
      _selectedFace = face;
    });
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

    // K7 (order 365, C-362 Part B): the rings are the selected face's own
    // tokens from `legalByFace` whenever the roll queue sends one; without
    // it, `turn.legal` exactly as before.
    final bool myAwaitMove =
        !_isEndHeld &&
        turn != null &&
        turn.seat == seat &&
        turn.phase == TurnPhase.awaitMove;
    final Set<int> legalTokens = myAwaitMove
        ? (turn.legalByFace != null
              ? _legalTokensForFace(turn.legalByFace!, _selectedFace)
              : (turn.legal?.toSet() ?? const <int>{}))
        : const <int>{};

    // Rule 4a: for the whole hold the die keeps showing the face and the
    // seat colour of the `rolled` that armed it -- my own -- rather than
    // whatever the next seat's turn has already put in `turn.seat` and
    // `turn.value` underneath it.
    final Color dieSeatColor = _noMoveVisible
        ? LudoColors.seats[(seat ?? 0).clamp(0, 3)]
        : LudoColors.seats[(turn?.seat ?? seat ?? 0).clamp(0, 3)];
    // K4: under the roll queue, in awaitMove, the big die shows the
    // selected face, not necessarily `turn.value`.
    final int? dieFace = _noMoveVisible
        ? _noMoveFace
        : (myAwaitMove && turn.legalByFace != null
              ? _selectedFace
              : turn?.value);

    final (
      List<int>? trayFaces,
      List<TrayDieState>? trayStates,
      Color trayColor,
    ) = _rollTrayData(
      turn,
      seat,
    );
    final bool trayInteractive = myAwaitMove && turn.legalByFace != null;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace2,
        vertical: kSpace2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _playHeaderRow(loc, room, seat, turn, offlineTurnSeat, stale: stale),
          SizedBox(height: _playColumnGap(context, kSpace2)),
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
              onTokenStep: (int stepSeat, int token) =>
                  _onBoardTokenStep(controller, stepSeat),
              onMoveLanded: _onBoardMoveLanded,
              onTravelReset: _onBoardTravelReset,
              safeCue: _safeCue,
              onTokenTap: (int index) {
                if (_isEndHeld) {
                  return;
                }
                _cancelPendingHoldForManualMove();
                final int? k = turn?.k;
                if (k == null) {
                  return;
                }
                // K6: a server without the roll queue (`legalByFace` null)
                // sends the byte-identical frame it always did.
                _sendMove(
                  index,
                  k,
                  face: turn!.legalByFace != null ? _selectedFace : null,
                );
              },
              onIllegalTokenTap: (int index) {
                FeedbackScope.of(context).play(FeedbackCue.invalidTap);
              },
              overlay: _thrownDieOverlay(seat),
            ),
          ),
          SizedBox(height: _playColumnGap(context, kSpace4)),
          // K1: the tray sits on the die's own row, after it in reading
          // order -- a plain Row under the ambient Directionality already
          // mirrors that for Arabic, nothing here flips it by hand.
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _boardDieSlot(
                  loc,
                  turn,
                  GameDie(
                    face: _boardDieFace(dieFace),
                    seatColor: dieSeatColor,
                    enabled: rollEnabled,
                    tumbling: _rollWaitK != null,
                    noAnswer: _rollNoAnswer,
                    noMove: _noMoveVisible,
                    onTap: rollEnabled ? _onDieTap : null,
                    onInvalidTap: () {
                      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
                    },
                  ),
                ),
                if (trayFaces != null) ...[
                  const SizedBox(width: kSpace2),
                  Flexible(
                    child: RollTray(
                      key: const Key('game-roll-tray'),
                      faces: trayFaces,
                      states: trayStates!,
                      seatColor: trayColor,
                      interactive: trayInteractive,
                      onSelect: (int index) => _onTraySelect(trayFaces[index]),
                      onInvalidTap: () {
                        FeedbackScope.of(context).play(FeedbackCue.invalidTap);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: _playColumnGap(context, kSpace2)),
          _belowDieNoticeSlot(loc, offlineTurnSeat),
          SizedBox(height: _playColumnGap(context, kSpace2)),
        ],
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
  /// C-391 decision 2: past this scale the banner and the below-die notice
  /// stop growing -- both are laid out at this clamped scale, never the
  /// raw system one, so a system scale past it no longer costs the board
  /// anything more than it already has. `_playColumnClampedScaler` and
  /// `_playColumnScaleFactor` are the one clamp every reader of the system
  /// scale on this row and on the notice goes through, so the row's own
  /// height and the banner's own painted size can never disagree about
  /// what scale either was laid out at.
  static const double _headerRowHeightAtRest = 44;
  static const double _countdownRingSize = 44;
  static const double _playColumnTextScaleClamp = 1.5;

  TextScaler _playColumnClampedScaler(BuildContext context) {
    return MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: _playColumnTextScaleClamp);
  }

  double _playColumnScaleFactor(BuildContext context) {
    return _playColumnClampedScaler(context).scale(100.0) / 100.0;
  }

  double _headerRowHeightFor(BuildContext context) {
    final TextScaler scaler = _playColumnClampedScaler(context);
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

  /// C-391 decision 5: the play column's own vertical gaps (the four
  /// `SizedBox`es between the header, the board, the die row and the
  /// below-die notice) give back only as much as decisions 1-3 still leave
  /// the board short of C-391's 324 floor, never at scale 1.0, never below
  /// a floor of 4 each.
  ///
  /// On the contract's own 360x616 phone, 24 top inset, decisions 1-3
  /// alone already hold the floor up to clamped scale 1.3
  /// ([_playColumnGapShrinkStartScale]) -- every gap stays exactly
  /// [nominal] there. Past it the header and the notice (decision 2) are
  /// still growing, so this ramps every gap down at the same rate, in
  /// lock step, reaching the shared floor of 4 at
  /// [_playColumnGapShrinkFloorScale] (1.7, past the header/notice clamp
  /// at 1.5, so in practice the ramp never actually reaches it: at clamped
  /// scale 1.5 it has given back exactly half of each gap's own room above
  /// 4 -- on this phone that is 12 of the 40 nominal total, which is what
  /// measurement found the board still needed at system scale 2.0).
  double _playColumnGap(BuildContext context, double nominal) {
    final double s = _playColumnScaleFactor(context);
    final double keep =
        ((_playColumnGapShrinkFloorScale - s) /
                (_playColumnGapShrinkFloorScale -
                    _playColumnGapShrinkStartScale))
            .clamp(0.0, 1.0);
    return 4.0 + (nominal - 4.0) * keep;
  }

  /// The clamped scale at and below which [_playColumnGap] gives back
  /// nothing: decisions 1-3 alone already hold C-391's floor there.
  static const double _playColumnGapShrinkStartScale = 1.3;

  /// The clamped scale at which [_playColumnGap] would reach every gap's
  /// shared floor of 4, if the header and the notice kept growing past
  /// their own 1.5 clamp. They do not, so the ramp never actually gets
  /// there; it only sets how fast the gaps shrink between
  /// [_playColumnGapShrinkStartScale] and 1.5.
  static const double _playColumnGapShrinkFloorScale = 1.7;

  Widget _playHeaderRow(
    AppLocalizations loc,
    RoomSnapshot room,
    int? seat,
    TurnState? turn,
    SeatState? offlineTurnSeat, {
    bool stale = false,
  }) {
    final String bannerText = _turnBannerText(loc, room, seat, stale: stale);
    final int turnSeat = turn?.seat ?? seat ?? 0;
    final Color seatColor = LudoColors.seats[turnSeat.clamp(0, 3)];
    final bool myTurn = turn != null && turn.seat == seat;
    final bool offline = offlineTurnSeat != null;
    final double headerRowHeight = _headerRowHeightFor(context);
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
                        textScaler: _playColumnClampedScaler(context),
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
  /// turn and turns `LudoColors.error` for the last 10s; the Text keyed
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
    final bool lastTenSeconds = _countdownRemainingSeconds <= 10;
    final Color ringColor = lastTenSeconds ? LudoColors.error : seatColor;
    final int turnSeconds = room.rules.turnSeconds;
    final double remainingFraction = turnSeconds > 0
        ? (_countdownRemainingSeconds / turnSeconds).clamp(0.0, 1.0)
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
  /// The slot is sized for the taller of the two placeholder strings so
  /// switching between them never resizes anything underneath; when both
  /// would otherwise show, the no-move notice wins and the offline line
  /// waits for the hold to end, exactly as the rule's own wording asks.
  Widget _belowDieNoticeSlot(AppLocalizations loc, SeatState? offlineTurnSeat) {
    // C-391 decision 2: this slot's own two texts (the live notice and the
    // two placeholders reserving its space) are laid out at the same
    // clamped scale as the header banner -- past
    // `_playColumnTextScaleClamp` the slot stops growing with the system
    // scale, and the text inside it is capped to match, so the reserved
    // space this Stack settles on from its invisible children always
    // covers whichever one is actually shown.
    final TextScaler scaler = _playColumnClampedScaler(context);
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
              loc.gameSeatOffline(''),
              textAlign: TextAlign.center,
              textScaler: scaler,
            ),
          ),
        ),
        if (_noMoveVisible)
          Positioned.fill(
            child: Text(
              loc.gameNoMove,
              key: const Key('game-no-move-notice'),
              textAlign: TextAlign.center,
              textScaler: scaler,
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
  Widget _boardDieSlot(AppLocalizations loc, TurnState? turn, Widget die) {
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
    // four stat tiles, the fairness line and two buttons), so this body is
    // scrollable rather than forced into one unscrollable screen the way
    // the playing body is: nothing here is time-pressured the way a turn
    // is, and a RenderFlex overflow would hide content rather than merely
    // look cramped. The board keeps its own square shape via AspectRatio
    // instead of Expanded, which needs a bounded height a scroll view does
    // not give its children.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(kSpace4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EndCard(
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
          ),
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

  /// The turn seat's own colour above 10s left, `LudoColors.error` at 10s
  /// and below (C-250 rule 8).
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
String _turnBannerText(
  AppLocalizations loc,
  RoomSnapshot room,
  int? seat, {
  bool stale = false,
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
      return stale ? loc.gameYourTurnStale : loc.gameYourTurnMove;
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

/// One opponent roll waiting to be thrown, or the one currently in flight.
class _QueuedThrow {
  const _QueuedThrow({required this.k, required this.seat, required this.face});

  final int k;
  final int seat;
  final int face;
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
