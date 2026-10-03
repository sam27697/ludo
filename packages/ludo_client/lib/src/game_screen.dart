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

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'board.dart';
import 'die_mark.dart';
import 'feedback.dart';
import 'game_die.dart';
import 'net/frame.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'theme.dart';

/// Distinct [Navigator.pop] result from the finished-board next-table
/// button. The AppBar leave control pops with no result, so the screen
/// that pushed this route can leave() and dispose the old controller
/// without opening another table.
enum GameScreenResult { newTable }

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
  // above this tree. C-236 rule 4: the no-move beat it also drives. Armed
  // by a `rolled` for my seat with an empty `legal`; holds
  // `game-die-no-move-mark` and `game-no-move-notice` up for exactly
  // `_noMoveHold` from that `rolled`, whatever the turn banner does
  // underneath it in the meantime, and ends early only when a newer
  // `rolled` for my seat -- can-move or no-move alike -- lands.
  StreamSubscription<Frame>? _frameSub;
  static const Duration _noMoveHold = Duration(milliseconds: 1500);
  Timer? _noMoveTimer;
  bool _noMoveVisible = false;

  @override
  void initState() {
    super.initState();
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
    _frameSub?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// C-236 rule 2: every cue `cuesForFrame` derives for this frame, played
  /// in list order, synchronously, through the one `FeedbackService`
  /// `FeedbackScope.of` finds. This is the only place a cue is played for a
  /// frame; the derivation is `cuesForFrame`'s and only its.
  ///
  /// Also arms or drops the no-move hold (rule 4): a `rolled` this screen
  /// derived a cue for (so a well-formed `rolled` naming my seat) arms the
  /// hold when that cue is `noMove`, and drops it otherwise -- the "newer
  /// rolled for my seat" that ends an earlier hold early.
  void _onFrame(Frame frame) {
    final List<FeedbackCue> cues = cuesForFrame(
      frame,
      mySeat: widget.controller.seat,
    );
    final FeedbackService feedback = FeedbackScope.of(context);
    for (final FeedbackCue cue in cues) {
      feedback.play(cue);
    }
    if (frame.type == 'rolled' && cues.isNotEmpty) {
      if (cues.contains(FeedbackCue.noMove)) {
        _armNoMoveHold();
      } else {
        _dropNoMoveHold();
      }
    }
  }

  void _armNoMoveHold() {
    _noMoveTimer?.cancel();
    _noMoveTimer = Timer(_noMoveHold, _dropNoMoveHold);
    if (!_noMoveVisible) {
      setState(() {
        _noMoveVisible = true;
      });
    }
  }

  void _dropNoMoveHold() {
    _noMoveTimer?.cancel();
    _noMoveTimer = null;
    if (!mounted || !_noMoveVisible) {
      return;
    }
    setState(() {
      _noMoveVisible = false;
    });
  }

  void _onControllerChanged() {
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
    if (!_isUniqueLegalAwaitMove()) {
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
  /// in-game AppBar action and connection-lost body alike.
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

    final Widget body;
    if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      // Rule 1: consulted before room, and decisive regardless of what the
      // last room snapshot said. The board a dead socket last drew is not
      // shown again underneath this.
      body = _connectionLostBody(loc, controller);
    } else if (room == null) {
      body = _loadingBody();
    } else if (room.state == RoomState.finished) {
      body = _gameOverBody(loc, controller, room);
    } else if (room.state == RoomState.playing && room.seats.length >= 2) {
      body = _playingBody(loc, controller, room);
    } else {
      body = _waitingBody(loc);
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(loc.gameScreenTitle),
        actions: [
          TextButton(
            key: const Key('game-screen-appbar-leave'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _leave,
            child: Text(loc.gameLeaveButton),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Signature chrome: felt edge frames the seat-pip strip so every
            // body below (waiting, playing, game-over, and the rest) inherits
            // the same table cue without each state painting its own copy.
            const FeltEdge(key: Key('game-felt-edge')),
            const SeatPipStrip(key: Key('game-seat-pip-strip')),
            if (controller.hasDesynced) _desyncBanner(context, loc),
            if (controller.phase == RoomPhase.connecting &&
                controller.room != null)
              _reconnectingBanner(context, loc),
            Expanded(child: body),
          ],
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
        room.state == RoomState.playing &&
        turn != null &&
        turn.seat == seat &&
        turn.phase == TurnPhase.awaitRoll &&
        _rollWaitK == null;

    final Set<int> legalTokens =
        (turn != null &&
            turn.seat == seat &&
            turn.phase == TurnPhase.awaitMove &&
            turn.legal != null)
        ? turn.legal!.toSet()
        : const <int>{};

    final Color dieSeatColor =
        LudoColors.seats[(turn?.seat ?? seat ?? 0).clamp(0, 3)];

    return Padding(
      padding: const EdgeInsets.all(kSpace4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _turnBannerText(loc, room, seat),
            key: const Key('game-screen-turn-banner'),
            textAlign: TextAlign.center,
          ),
          if (offlineTurnSeat != null) ...[
            const SizedBox(height: kSpace2),
            Text(
              loc.gameSeatOffline(offlineTurnSeat.name),
              key: const Key('game-screen-turn-seat-offline'),
              textAlign: TextAlign.center,
            ),
          ],
          if (turn != null && turn.value != null) ...[
            const SizedBox(height: kSpace2),
            Text(
              loc.gameDieValue(turn.value!),
              key: const Key('game-screen-dice-value'),
              textAlign: TextAlign.center,
            ),
          ],
          if (turn != null) ...[
            const SizedBox(height: kSpace2),
            Text(
              loc.gameTurnCountdown(_countdownRemainingSeconds),
              key: const Key('game-screen-turn-countdown'),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: kSpace4),
          Expanded(
            child: LudoBoard(
              key: const Key('game-screen-board'),
              tokens: _tokensOf(room),
              seatsInPlay: _seatsInPlayOf(room),
              mySeat: seat,
              legal: legalTokens,
              autoMoveToken: _pendingAutoMoveToken,
              onTokenTap: (int index) {
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
            child: GameDie(
              face: turn?.value,
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
          if (_noMoveVisible) ...[
            const SizedBox(height: kSpace2),
            Text(
              loc.gameNoMove,
              key: const Key('game-no-move-notice'),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: kSpace4),
        ],
      ),
    );
  }

  /// H6.2 and H7: the game has finished. The board (when there are still at
  /// least two seats to draw it from) and the winner text; the Roll button
  /// and the four token buttons are absent, not merely disabled, because
  /// there is nothing left to press. The next-table button is the honest
  /// action on this ending: it is not the AppBar leave control. Verify
  /// opens `verify_url` externally; roll history is the last three faces.
  Widget _gameOverBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room,
  ) {
    final bool hasBoard = room.seats.length >= 2;
    final String? verifyUrl = room.verifyUrl;
    final bool canVerify = verifyUrl != null && verifyUrl.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(kSpace4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _winnerText(loc, controller, room),
            key: const Key('game-screen-winner'),
            textAlign: TextAlign.center,
          ),
          if (hasBoard) ...[
            const SizedBox(height: kSpace4),
            Expanded(
              child: LudoBoard(
                key: const Key('game-screen-board'),
                tokens: _tokensOf(room),
                seatsInPlay: _seatsInPlayOf(room),
              ),
            ),
          ],
          const SizedBox(height: kSpace4),
          _rollHistory(loc, room),
          const SizedBox(height: kSpace4),
          OutlinedButton(
            key: const Key('game-screen-verify-button'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: canVerify ? _openVerifyUrl : null,
            child: Text(loc.gameVerifyButton),
          ),
          const SizedBox(height: kSpace2),
          ElevatedButton(
            key: const Key('game-screen-new-room-button'),
            style: ElevatedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _requestNewTable,
            child: Text(loc.gameNewRoomButton),
          ),
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

/// H7, decided in the order given there, first match wins.
String _winnerText(
  AppLocalizations loc,
  RoomController controller,
  RoomSnapshot room,
) {
  final int? winner = room.winner;
  if (winner != null && winner == controller.seat) {
    return loc.gameOverYouWin;
  }
  if (winner != null) {
    for (final SeatState seatState in room.seats) {
      if (seatState.seat == winner) {
        return loc.gameOverPlayerWins(seatState.name);
      }
    }
  }
  return loc.gameOverEnded;
}
