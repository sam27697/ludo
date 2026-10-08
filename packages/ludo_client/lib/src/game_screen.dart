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
import 'die_mark.dart';
import 'end_card.dart';
import 'feedback.dart';
import 'game_die.dart';
import 'game_stats.dart';
import 'net/frame.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'theme.dart';

/// Distinct [Navigator.pop] result from the finished-board next-table
/// button. The corner leave control pops with no result, so the screen
/// that pushed this route can leave() and dispose the old controller
/// without opening another table.
enum GameScreenResult { newTable }

/// Safety-net fallback duration for held landing cues, contract C-268 rule 4e.
const Duration kLandingCueFallback = Duration(milliseconds: 2000);

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

  // Client-side unique-legal hold. Armed once per turn.k when legal has
  // exactly one token; cancelled by a manual token press, or the turn
  // leaving that unique-legal awaitMove. controller.move is not called
  // until the hold elapses without cancel.
  static const Duration _autoMoveHold = Duration(milliseconds: 1500);
  Timer? _autoMoveTimer;
  int? _pendingAutoMoveToken;
  int? _autoMoveHandledK;

  // The one guard both move paths (the hold's own timer and a token tap)
  // share: once a move has gone out for a turn.k, nothing sends a second
  // one for that same k, however it is reached. A tap landing just after
  // the hold already committed is exactly the race this exists for.
  int? _moveSentForK;

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

  // C-243: every frame this screen's own subscription has seen since it
  // mounted, in arrival order. The end card's GameStats is computed from
  // exactly this list (see _gameOverBody), never from anywhere else, so a
  // post-game number never traces back further than frames this device
  // already held.
  final List<Frame> _frames = <Frame>[];

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

  // C-268 rules 3 to 5: landing cues (capturedOther, capturedMe, home) held
  // until the token lands on the board, flushed on travel reset or game-over,
  // falling back to kLandingCueFallback if no landing arrives. Dropped on
  // dispose and _resetForNewGame.
  final List<_PendingLandingCues> _pendingLandingCues = <_PendingLandingCues>[];

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

  @override
  void initState() {
    super.initState();
    _currentGameId = widget.controller.room?.gameId;
    widget.controller.addListener(_onControllerChanged);
    _frameSub = widget.controller.frames.listen(_onFrame);
    _syncCountdown();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAutoMove();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _autoMoveTimer?.cancel();
    _rollNoAnswerTimer?.cancel();
    _noMoveTimer?.cancel();
    _dropPendingLandingCues();
    _endHoldDwellTimer?.cancel();
    _endHoldLimitTimer?.cancel();
    _heldGameOverCues.clear();
    _isEndHeld = false;
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

    _frames.add(frame);
    final List<FeedbackCue> cues = cuesForFrame(
      frame,
      mySeat: widget.controller.seat,
    );
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
        feedback.play(cue);
      }
      if (landingCues.isNotEmpty) {
        _holdLandingCues(moverSeat, moverToken, landingCues);
      }
    } else {
      if (frame.type == 'game_over') {
        _flushPendingLandingCues();
      }
      for (final FeedbackCue cue in cues) {
        feedback.play(cue);
      }
    }
    if (frame.type == 'rolled') {
      if (cues.contains(FeedbackCue.noMove)) {
        _armNoMoveHold(_intAt(frame.data, 'value'));
      } else if (_intAt(frame.data, 'value') != null) {
        _dropNoMoveHold();
      }
    }

    // C-246 rule 6: a seat removed by a host-forced start receives a
    // `player_left` naming its own seat and nothing further from the room
    // (docs/PROTOCOL.md section 16.9 rule 1). No existing "removed from a
    // lobby" path exists under lib/ to reuse, so this is treated exactly
    // as the corner Leave control treats leaving: pop with no result.
    if (frame.type == 'player_left') {
      final int? seatValue = _intAt(frame.data, 'seat');
      if (seatValue != null && seatValue == widget.controller.seat) {
        _leave();
      }
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
      feedback.play(cue);
    }
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
  }

  void _onBoardTravelReset() {
    _travelCount = 0;
    if (_isEndHeld) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_isEndHeld) {
          return;
        }
        _releaseEndHold();
      });
    } else {
      _flushPendingLandingCues();
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
    _frames.clear();
    _noMoveTimer?.cancel();
    _noMoveTimer = null;
    _noMoveVisible = false;
    _noMoveFace = null;
    _autoMoveTimer?.cancel();
    _autoMoveTimer = null;
    _pendingAutoMoveToken = null;
    _autoMoveHandledK = null;
    _moveSentForK = null;
    _rollNoAnswerTimer?.cancel();
    _rollNoAnswerTimer = null;
    _rollWaitK = null;
    _rollNoAnswer = false;
    _dropPendingLandingCues();
    _endHoldDwellTimer?.cancel();
    _endHoldDwellTimer = null;
    _endHoldLimitTimer?.cancel();
    _endHoldLimitTimer = null;
    _heldGameOverCues.clear();
    _isEndHeld = false;
    _travelCount = 0;
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

  void _onControllerChanged() {
    final RoomController controller = widget.controller;
    if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      _travelCount = 0;
    }
    setState(() {
      _syncCountdown();
      _syncAutoMove();
      _syncRollWait();
    });
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
  }

  /// True when this seat is awaiting a move and the server named exactly
  /// one legal token. The hold is a screen convenience on top of that
  /// already-authoritative list, not a second legality check.
  bool _isUniqueLegalAwaitMove() {
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;
    final TurnState? turn = room?.turn;
    return room != null &&
        room.state == RoomState.playing &&
        turn != null &&
        turn.seat == controller.seat &&
        turn.phase == TurnPhase.awaitMove &&
        turn.legal != null &&
        turn.legal!.length == 1;
  }

  /// Arms the 1.5s unique-legal hold once per `turn.k`, or drops a pending
  /// hold when the turn is no longer that unique-legal awaitMove. The
  /// board draws the held token's glow itself from `autoMoveToken`; there
  /// is no Undo to announce alongside it any more.
  void _syncAutoMove() {
    if (_isEndHeld || !_isUniqueLegalAwaitMove()) {
      _clearPendingHold();
      return;
    }
    final TurnState turn = widget.controller.room!.turn!;
    if (_autoMoveHandledK == turn.k) {
      return;
    }
    _autoMoveHandledK = turn.k;
    _pendingAutoMoveToken = turn.legal!.single;
    _autoMoveTimer?.cancel();
    _autoMoveTimer = Timer(_autoMoveHold, _commitPendingAutoMove);
    final AppLocalizations loc = AppLocalizations.of(context);
    _announceAutoMove(loc.gameTokenButton(_pendingAutoMoveToken! + 1));
  }

  void _clearPendingHold() {
    _autoMoveTimer?.cancel();
    _autoMoveTimer = null;
    _pendingAutoMoveToken = null;
  }

  void _commitPendingAutoMove() {
    if (!mounted) {
      return;
    }
    final int? token = _pendingAutoMoveToken;
    final int? k = _autoMoveHandledK;
    if (token == null || k == null) {
      return;
    }
    _autoMoveTimer = null;
    _pendingAutoMoveToken = null;
    final AppLocalizations loc = AppLocalizations.of(context);
    _announceAutoMove(loc.gameTokenButton(token + 1));
    setState(() {});
    _sendMove(token, k);
  }

  /// The one path that actually calls `controller.move`: a tap on the board
  /// and the hold's own timer both end up here, and whichever reaches a
  /// given `turn.k` first is the only one that sends anything for it.
  void _sendMove(int token, int k) {
    if (_moveSentForK == k) {
      return;
    }
    _moveSentForK = k;
    widget.controller.move(token);
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

  /// C-246 rule 1 and rule 3: the end card's Rematch/accept tap. Guarded by
  /// [_rematchInFlight] so a second tap while the request is open sends
  /// nothing; `RoomController.rematch` never throws, so this always
  /// reaches the end and clears the guard, whatever the server answered.
  Future<void> _onRematchTap() async {
    if (_rematchInFlight) {
      return;
    }
    setState(() {
      _rematchInFlight = true;
    });
    await widget.controller.rematch();
    if (!mounted) {
      return;
    }
    setState(() {
      _rematchInFlight = false;
    });
  }

  /// Opens the match `verify_url` in an external browser. The app does not
  /// prove the rolls itself; a failure to open is shown honestly.
  Future<void> _openVerifyUrl() async {
    final String? raw = widget.controller.room?.verifyUrl;
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

    final Widget body;
    if (rematchGone) {
      body = _gameOverBody(loc, controller, room, rematchGone: true);
    } else if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      // Rule 1: consulted before room, and decisive regardless of what the
      // last room snapshot said. The board a dead socket last drew is not
      // shown again underneath this.
      body = _connectionLostBody(loc, controller);
    } else if (room == null) {
      body = _loadingBody();
    } else if (room.state == RoomState.finished) {
      if (_isEndHeld && room.seats.length >= 2) {
        body = _playingBody(loc, controller, room);
      } else {
        body = _gameOverBody(loc, controller, room);
      }
    } else if (room.state == RoomState.lobby && room.rematch != null) {
      // C-246 rule 2: a rematch LOBBY (state LOBBY, non-null `rematch`) is
      // drawn by the same end card as FINISHED, so the player sees one
      // continuous next step rather than a reset screen in between.
      body = _gameOverBody(loc, controller, room);
    } else if (room.state == RoomState.playing && room.seats.length >= 2) {
      body = _playingBody(loc, controller, room);
    } else {
      body = _waitingBody(loc);
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
                    alignment: Alignment.center,
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
                          // Historical key name from the original app bar action; tests pin it.
                          key: const Key('game-screen-appbar-leave'),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          tooltip: loc.gameLeaveButton,
                          onPressed: () => _handleLeaveRequest(context, loc),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.hasDesynced) _desyncBanner(context, loc),
                if (controller.phase == RoomPhase.connecting &&
                    controller.room != null)
                  _reconnectingBanner(context, loc),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Rule 1 and rule 2: `controller.phase` is `RoomPhase.failed` or
  /// `RoomPhase.closed`. Reuses `loc.lobbyConnectionLost` and
  /// `loc.lobbyReconnectButton` from the identical state `lobby_screen.dart`
  /// already shows (`_closedBody`) rather than inventing near-duplicates;
  /// the meaning is the same connection, the same loss, the same fix.
  /// `game-screen-error-message` shows `controller.errorMessage` itself,
  /// exactly as rule 2 asks, whatever the server or the transport said.
  Widget _connectionLostBody(AppLocalizations loc, RoomController controller) {
    final String? errorMessage = controller.errorMessage;
    return Center(
      key: const Key('game-screen-connection-lost'),
      child: Padding(
        padding: const EdgeInsets.all(kSpace6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.lobbyConnectionLost, textAlign: TextAlign.center),
            if (errorMessage != null) ...[
              const SizedBox(height: kSpace2),
              Text(
                errorMessage,
                key: const Key('game-screen-error-message'),
                textAlign: TextAlign.center,
              ),
            ],
            if (controller.autoReconnectPending) ...[
              const SizedBox(height: kSpace2),
              Text(
                loc.lobbyReconnecting,
                key: const Key('game-screen-reconnecting'),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: kSpace4),
            ElevatedButton(
              key: const Key('game-screen-reconnect-button'),
              onPressed: controller.reconnect,
              child: Text(loc.lobbyReconnectButton),
            ),
            const SizedBox(height: kSpace2),
            OutlinedButton(
              key: const Key('game-screen-leave-button'),
              onPressed: _leave,
              child: Text(loc.gameLeaveButton),
            ),
          ],
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

  /// H6.3: the room is playing and has at least two seated players. Board,
  /// turn banner, and the die under it. Play itself happens on the board
  /// objects: the die is tapped to roll, a token is tapped to move it.
  Widget _playingBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room,
  ) {
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

    final Set<int> legalTokens =
        (!_isEndHeld &&
            turn != null &&
            turn.seat == seat &&
            turn.phase == TurnPhase.awaitMove &&
            turn.legal != null)
        ? turn.legal!.toSet()
        : const <int>{};

    // Rule 4a: for the whole hold the die keeps showing the face and the
    // seat colour of the `rolled` that armed it -- my own -- rather than
    // whatever the next seat's turn has already put in `turn.seat` and
    // `turn.value` underneath it.
    final Color dieSeatColor = _noMoveVisible
        ? LudoColors.seats[(seat ?? 0).clamp(0, 3)]
        : LudoColors.seats[(turn?.seat ?? seat ?? 0).clamp(0, 3)];
    final int? dieFace = _noMoveVisible ? _noMoveFace : turn?.value;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace2,
        vertical: kSpace2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _playHeaderRow(loc, room, seat, turn, offlineTurnSeat),
          const SizedBox(height: kSpace2),
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
              onTokenTap: (int index) {
                if (_isEndHeld) {
                  return;
                }
                _cancelPendingHoldForManualMove();
                final int? k = turn?.k;
                if (k == null) {
                  return;
                }
                _sendMove(index, k);
              },
              onIllegalTokenTap: (int index) {
                FeedbackScope.of(context).play(FeedbackCue.invalidTap);
              },
            ),
          ),
          const SizedBox(height: kSpace4),
          Center(
            child: _diceValueWrap(
              loc,
              turn,
              GameDie(
                face: dieFace,
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
          ),
          const SizedBox(height: kSpace2),
          _belowDieNoticeSlot(loc, offlineTurnSeat),
          const SizedBox(height: kSpace2),
        ],
      ),
    );
  }

  /// C-250 rule 1: one row of fixed height between the pip strip and the
  /// board, the same height in every playing state and both locales --
  /// rule 2's chip and rule 3's countdown ring are what the row holds, and
  /// both read straight off `room.turn`, so none of the die's own overlays
  /// (the tumble, the no-move mark) have to be threaded through here. The
  /// chip sits at the row's logical start and the ring at its end; a `Row`
  /// under the ambient `Directionality` mirrors that for Arabic on its
  /// own, nothing here flips anything by hand.
  static const double _headerRowHeight = 44;

  Widget _playHeaderRow(
    AppLocalizations loc,
    RoomSnapshot room,
    int? seat,
    TurnState? turn,
    SeatState? offlineTurnSeat,
  ) {
    final String bannerText = _turnBannerText(loc, room, seat);
    final int turnSeat = turn?.seat ?? seat ?? 0;
    final Color seatColor = LudoColors.seats[turnSeat.clamp(0, 3)];
    final bool myTurn = turn != null && turn.seat == seat;
    final bool offline = offlineTurnSeat != null;

    return SizedBox(
      height: _headerRowHeight,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
        width: _headerRowHeight,
        height: _headerRowHeight,
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
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(loc.gameNoMove, textAlign: TextAlign.center),
          ),
        ),
        ExcludeSemantics(
          child: Opacity(
            opacity: 0,
            child: Text(loc.gameSeatOffline(''), textAlign: TextAlign.center),
          ),
        ),
        if (_noMoveVisible)
          Positioned.fill(
            child: Text(
              loc.gameNoMove,
              key: const Key('game-no-move-notice'),
              textAlign: TextAlign.center,
            ),
          )
        else if (offlineTurnSeat != null)
          Positioned.fill(
            child: Text(
              loc.gameSeatOffline(offlineTurnSeat.name),
              key: const Key('game-screen-turn-seat-offline'),
              textAlign: TextAlign.center,
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
  }) {
    final bool hasBoard = room.seats.length >= 2;

    // Rule 4: a winner naming a seat absent from room.seats reads the same
    // as no winner at all (H7.21's own fallback, carried forward).
    String? winnerName;
    if (room.winner != null) {
      for (final SeatState seatState in room.seats) {
        if (seatState.seat == room.winner) {
          winnerName = seatState.name;
          break;
        }
      }
    }
    final int? winnerSeat = winnerName == null ? null : room.winner;

    // C-246 rule 4: the ask line names `rematch.by`, resolved against
    // room.seats the same way winnerName is above -- null when there is no
    // rematch open, or when `by` has since left.
    final RematchState? rematch = room.rematch;
    String? rematchByName;
    if (rematch != null) {
      for (final SeatState seatState in room.seats) {
        if (seatState.seat == rematch.by) {
          rematchByName = seatState.name;
          break;
        }
      }
    }

    // C-232: this seat's own numbers, computed from exactly the frames
    // this screen has already received. No entry in room.seats for my own
    // seat (a spectator view, or a seat the server never confirmed) leaves
    // nothing honest to show, not a guess.
    GameStats? stats;
    final int? mySeat = controller.seat;
    if (mySeat != null) {
      for (final SeatState seatState in room.seats) {
        if (seatState.seat == mySeat) {
          stats = computeGameStats(
            frames: _frames,
            seat: mySeat,
            finalTokens: seatState.tokens,
          );
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
            verifyUrl: room.verifyUrl,
            onVerify: _openVerifyUrl,
            onNewTable: _requestNewTable,
            rematch: rematch,
            rematchByName: rematchByName,
            occupiedSeats: _seatsInPlayOf(room),
            isHost: controller.isHost,
            rematchGone: rematchGone,
            onRematch: _rematchInFlight ? null : () => _onRematchTap(),
            onStartReady: controller.isHost ? controller.startGame : null,
          ),
          if (hasBoard) ...[
            const SizedBox(height: kSpace4),
            AspectRatio(
              aspectRatio: 1,
              child: LudoBoard(
                key: const Key('game-screen-board'),
                tokens: _tokensOf(room),
                seatsInPlay: _seatsInPlayOf(room),
                seatNames: _seatNamesOf(room),
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
          _rollHistory(loc, room),
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

  /// R3: shown while `phase` is `RoomPhase.connecting` with `room` still
  /// set, i.e. an automatic or manual reconnect is in flight on top of the
  /// last board this screen drew. Styled like [_desyncBanner] but with
  /// `colorScheme.secondaryContainer` rather than the error colour: this is
  /// not a fault, only a wait.
  Widget _reconnectingBanner(BuildContext context, AppLocalizations loc) {
    return Container(
      color: Theme.of(context).colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace4,
        vertical: kSpace2,
      ),
      width: double.infinity,
      child: Text(
        loc.lobbyReconnecting,
        key: const Key('game-screen-reconnecting-banner'),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
    );
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
String _turnBannerText(AppLocalizations loc, RoomSnapshot room, int? seat) {
  final TurnState? turn = room.turn;
  if (turn == null) {
    return loc.gameWaitingForTurn;
  }
  if (turn.seat == seat) {
    if (turn.phase == TurnPhase.awaitRoll) {
      return loc.gameYourTurnRoll;
    }
    if (turn.phase == TurnPhase.awaitMove) {
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
