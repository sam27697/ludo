// The screen a player looks at while a game is being played: the board with
// everyone's tokens where the server says they are, whose turn it is, a Roll
// button, a way to choose which token to move, and an honest end-of-game
// state. Nothing here decides a rule, rolls a die, or advances a turn on its
// own; every frame this screen draws comes straight from RoomController, and
// pressing Roll or a token button sends the intention and waits for the
// server's own reply to change anything.
//
// Not wired into navigation by this order. Nothing routes to this screen
// yet; it is built and proved standing alone, constructed directly with a
// controller.

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'board.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';

/// Distinct [Navigator.pop] result from the finished-board next-table
/// button. The AppBar leave control pops with no result, so the screen
/// that pushed this route can leave() and dispose the old controller
/// without opening another table.
enum GameScreenResult { newTable }

class GameScreen extends StatefulWidget {
  const GameScreen({
    super.key,
    required this.controller,
    this.onRequestNewTable,
  });

  final RoomController controller;

  /// When set, the finished-board next-table button calls this instead of
  /// popping [GameScreenResult.newTable]. [RoomRoute] uses it to turn the
  /// same route into a fresh create lobby without revealing Home.
  final VoidCallback? onRequestNewTable;

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
  // _countdownSeat and _countdownDeadlineMs are the raw `(seat,
  // deadlineMs)` pair the current countdown was last started from.
  Timer? _countdownTimer;
  int? _countdownSeat;
  int? _countdownDeadlineMs;
  int _countdownRemainingSeconds = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncCountdown();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    setState(_syncCountdown);
  }

  /// Restarts the countdown for the current turn, and arms or disarms the
  /// once-a-second tick that keeps it moving.
  ///
  /// Restarting happens only when the visible `(seat, deadlineMs)` pair
  /// actually changes. The same pair recurring across frames -- several
  /// of RoomController's reducers carry the prior segment's `deadlineMs`
  /// forward unchanged on a frame that is not itself a fresh reading,
  /// per the doc comments at net/room_controller.dart's `_reduceMoved`,
  /// `_reduceTurnPassed` and `_reduceGameOver` -- is not a new reading
  /// and must not restart the clock or the display would jump back up
  /// while the real deadline keeps approaching underneath it. A
  /// genuinely new segment always changes at least one half of the
  /// pair: a different seat is now playing, or a fresh `deadline_ms`
  /// arrived straight off the wire (`_reduceTurn`, `_reduceRolled`).
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
      _countdownRemainingSeconds = 0;
      return;
    }

    if (turn.seat == _countdownSeat &&
        turn.deadlineMs == _countdownDeadlineMs) {
      return;
    }

    _countdownTimer?.cancel();
    _countdownSeat = turn.seat;
    _countdownDeadlineMs = turn.deadlineMs;
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
  /// The finished-board next-table control is not this path: it either
  /// pops [GameScreenResult.newTable] so HomeScreen can open a fresh
  /// table after that same leave()/dispose() sequence, or calls
  /// [GameScreen.onRequestNewTable] when the parent keeps the route.
  void _leave() {
    Navigator.of(context).pop();
  }

  void _requestNewTable() {
    final VoidCallback? keepRoute = widget.onRequestNewTable;
    if (keepRoute != null) {
      keepRoute();
      return;
    }
    Navigator.of(context).pop(GameScreenResult.newTable);
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
            if (controller.hasDesynced) _desyncBanner(context, loc),
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.lobbyConnectionLost, textAlign: TextAlign.center),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage,
                key: const Key('game-screen-error-message'),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              key: const Key('game-screen-reconnect-button'),
              onPressed: controller.reconnect,
              child: Text(loc.lobbyReconnectButton),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
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
  /// turn banner, die (when there is a value to show), Roll button and the
  /// four token buttons.
  Widget _playingBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room,
  ) {
    final TurnState? turn = room.turn;
    final int? seat = controller.seat;

    final bool rollEnabled =
        room.state == RoomState.playing &&
        turn != null &&
        turn.seat == seat &&
        turn.phase == TurnPhase.awaitRoll;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _turnBannerText(loc, room, seat),
            key: const Key('game-screen-turn-banner'),
            textAlign: TextAlign.center,
          ),
          if (turn != null && turn.value != null) ...[
            const SizedBox(height: 8),
            Text(
              loc.gameDieValue(turn.value!),
              key: const Key('game-screen-dice-value'),
              textAlign: TextAlign.center,
            ),
          ],
          if (turn != null) ...[
            const SizedBox(height: 8),
            Text(
              loc.gameTurnCountdown(_countdownRemainingSeconds),
              key: const Key('game-screen-turn-countdown'),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: LudoBoard(
              key: const Key('game-screen-board'),
              tokens: _tokensOf(room),
              seatsInPlay: _seatsInPlayOf(room),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            key: const Key('game-screen-roll-button'),
            onPressed: rollEnabled ? controller.roll : null,
            child: Text(loc.gameRollButton),
          ),
          const SizedBox(height: 8),
          // Four buttons in a single row leave too little width for either
          // locale's label at a phone's width -- "Token 1" and "قطعة 4" both
          // wrap mid-word once each button is down to a few dozen logical
          // pixels. Two rows of two buttons roughly doubles what each label
          // gets. FittedBox is the backstop under that, not the fix itself:
          // at the widths this row actually renders at, both locales fit
          // without any scaling, and it only engages at a narrower width or
          // a larger system font than this app has been measured at, where
          // the alternative is the same mid-word wrap this row exists to
          // remove.
          Row(
            children: [
              _tokenButton(loc, controller, room, seat, 0),
              _tokenButton(loc, controller, room, seat, 1),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _tokenButton(loc, controller, room, seat, 2),
              _tokenButton(loc, controller, room, seat, 3),
            ],
          ),
        ],
      ),
    );
  }

  /// One of the four token buttons, [index] 0..3. Kept as its own widget so
  /// the two-row layout in [_playingBody] does not repeat the button itself
  /// four times; the key, the enabled test and the move intention are
  /// unchanged from before the row was split in two.
  Widget _tokenButton(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room,
    int? seat,
    int index,
  ) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ElevatedButton(
          key: Key('game-screen-token-$index'),
          onPressed: _tokenEnabled(room, seat, index)
              ? () => controller.move(index)
              : null,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(loc.gameTokenButton(index + 1)),
          ),
        ),
      ),
    );
  }

  /// H6.2 and H7: the game has finished. The board (when there are still at
  /// least two seats to draw it from) and the winner text; the Roll button
  /// and the four token buttons are absent, not merely disabled, because
  /// there is nothing left to press. The next-table button is the honest
  /// action on this ending: it is not the AppBar leave control.
  Widget _gameOverBody(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room,
  ) {
    final bool hasBoard = room.seats.length >= 2;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _winnerText(loc, controller, room),
            key: const Key('game-screen-winner'),
            textAlign: TextAlign.center,
          ),
          if (hasBoard) ...[
            const SizedBox(height: 16),
            Expanded(
              child: LudoBoard(
                key: const Key('game-screen-board'),
                tokens: _tokensOf(room),
                seatsInPlay: _seatsInPlayOf(room),
              ),
            ),
          ],
          const SizedBox(height: 16),
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

  /// H8: additive to whatever body the switch above chose. The rest of the
  /// screen keeps rendering the last state it knew.
  Widget _desyncBanner(BuildContext context, AppLocalizations loc) {
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      width: double.infinity,
      child: Text(
        loc.lobbyDesynced,
        key: const Key('game-screen-desync-banner'),
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
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

/// H4: button `index` is enabled only when every one of these holds.
bool _tokenEnabled(RoomSnapshot room, int? seat, int index) {
  final TurnState? turn = room.turn;
  return room.state == RoomState.playing &&
      turn != null &&
      turn.seat == seat &&
      turn.phase == TurnPhase.awaitMove &&
      turn.legal != null &&
      turn.legal!.contains(index);
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
