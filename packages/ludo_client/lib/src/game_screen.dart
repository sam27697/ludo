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

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'board.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.controller});

  final RoomController controller;

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final RoomController controller = widget.controller;
    final RoomSnapshot? room = controller.room;

    final Widget body;
    if (room == null) {
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
      appBar: AppBar(title: Text(loc.gameScreenTitle)),
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
  /// there is nothing left to press.
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
  for (final SeatState seatState in room.seats) {
    if (seatState.seat == turn.seat) {
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
