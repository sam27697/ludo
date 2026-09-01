// The third widget: it owns exactly one decision, lobby or game, and owns
// nothing else. LobbyScreen shows the room code and the seat list and a
// Start button; when the host presses Start the server answers with
// game_started and the controller's room.state becomes RoomState.playing.
// Left alone, LobbyScreen would go on showing the lobby forever, because it
// never looks at room.state to decide what to draw. This widget is the one
// place that does.

import 'package:flutter/material.dart';

import 'game_screen.dart';
import 'lobby_screen.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';

class RoomRoute extends StatefulWidget {
  const RoomRoute({
    super.key,
    required this.controller,
    required this.action,
    required this.playerName,
    this.code,
    this.players = 4,
  });

  final RoomController controller;
  final LobbyAction action;
  final String playerName;

  /// Forwarded to [LobbyScreen] unchanged; see its own field for the meaning.
  final String? code;

  /// Forwarded to [LobbyScreen] unchanged; see its own field for the meaning.
  final int players;

  @override
  State<RoomRoute> createState() => _RoomRouteState();
}

class _RoomRouteState extends State<RoomRoute> {
  /// Once true, this route shows GameScreen for the rest of its life and
  /// never shows LobbyScreen again, even if a later snapshot puts
  /// room.state back to RoomState.lobby.
  ///
  /// This is not a second source of truth about game state; the server
  /// stays authoritative for that. It exists because LobbyScreen.initState
  /// issues a request -- createRoom on LobbyAction.create, joinRoom on
  /// LobbyAction.join -- once, on mount. If this route swapped back to
  /// LobbyScreen after showing GameScreen, mounting a fresh LobbyScreen
  /// would run that initState a second time and create a second room, or
  /// re-join the first one. The latch is what stops a widget remount from
  /// firing a network intention a second time; do not simplify it away.
  ///
  /// Only ever assigned here, in the controller listener, never inside
  /// build.
  bool _showGame = false;

  @override
  void initState() {
    super.initState();
    _showGame = _roomIsInGame(widget.controller.room);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    // Once latched, this route has nothing left to react to: GameScreen
    // holds its own listener and rebuilds itself. Skipping the call here
    // also matters before the latch trips: LobbyScreen.initState fires
    // createRoom/joinRoom synchronously, which notifies listeners before
    // this build even returns (RoomController._openFresh sets phase
    // connecting and calls notifyListeners before its first await), so an
    // unconditional setState here would reenter this element's own build.
    // Rebuilding only on the one transition that matters avoids that.
    if (_showGame || !_roomIsInGame(widget.controller.room)) {
      return;
    }
    setState(() {
      _showGame = true;
    });
  }

  static bool _roomIsInGame(RoomSnapshot? room) {
    return room != null &&
        (room.state == RoomState.playing || room.state == RoomState.finished);
  }

  @override
  Widget build(BuildContext context) {
    if (_showGame) {
      return GameScreen(controller: widget.controller);
    }
    return LobbyScreen(
      controller: widget.controller,
      action: widget.action,
      playerName: widget.playerName,
      code: widget.code,
      players: widget.players,
    );
  }
}
