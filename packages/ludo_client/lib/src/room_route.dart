// The third widget: it owns exactly one decision, lobby or game, and owns
// nothing else. LobbyScreen shows the room code and the seat list and a
// Start button; when the host presses Start the server answers with
// game_started and the controller's room.state becomes RoomState.playing.
// Left alone, LobbyScreen would go on showing the lobby forever, because it
// never looks at room.state to decide what to draw. This widget is the one
// place that does.

import 'dart:async';

import 'package:flutter/material.dart';

import 'game_screen.dart';
import 'lobby_screen.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'server_config.dart';

class RoomRoute extends StatefulWidget {
  const RoomRoute({
    super.key,
    required this.controller,
    required this.action,
    required this.playerName,
    this.code,
    this.players = 4,
    this.controllerFactory = defaultRoomControllerFactory,
  });

  final RoomController controller;
  final LobbyAction action;
  final String playerName;

  /// Forwarded to [LobbyScreen] unchanged; see its own field for the meaning.
  final String? code;

  /// Forwarded to [LobbyScreen] unchanged; see its own field for the meaning.
  final int players;

  /// Builds the fresh [RoomController] used when the finished board becomes
  /// the next lobby in place. Defaults to a real socket; tests can inject.
  final RoomControllerFactory controllerFactory;

  @override
  State<RoomRoute> createState() => _RoomRouteState();
}

class _RoomRouteState extends State<RoomRoute> {
  /// Once true, this route shows GameScreen until [_becomeNextLobby] clears
  /// it, even if a later snapshot puts room.state back to RoomState.lobby.
  ///
  /// This is not a second source of truth about game state; the server
  /// stays authoritative for that. It exists because LobbyScreen.initState
  /// issues a request -- createRoom on LobbyAction.create, joinRoom on
  /// LobbyAction.join -- once, on mount. If this route swapped back to
  /// LobbyScreen after showing GameScreen on the same controller, mounting
  /// a fresh LobbyScreen would run that initState a second time and create
  /// a second room, or re-join the first one. The latch is what stops a
  /// widget remount from firing a network intention a second time by
  /// accident; [_becomeNextLobby] is the deliberate path that clears it
  /// only after switching to a fresh controller.
  ///
  /// Only ever assigned here, in the controller listener or
  /// [_becomeNextLobby], never inside build.
  bool _showGame = false;

  /// The controller the route is currently drawing. Starts as
  /// [RoomRoute.controller] (owned by HomeScreen). Controllers created
  /// here for a next table are owned by this state and retired in
  /// [dispose] or when another next table supersedes them.
  late RoomController _controller;

  /// Non-null when [_controller] was built by [RoomRoute.controllerFactory]
  /// for an in-place next table. HomeScreen still owns disposing
  /// [RoomRoute.controller].
  RoomController? _routeOwned;

  bool _renewing = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    _showGame = _roomIsInGame(_controller.room);
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    final RoomController? owned = _routeOwned;
    if (owned != null) {
      unawaited(owned.leave().whenComplete(owned.dispose));
    }
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
    if (_showGame || !_roomIsInGame(_controller.room)) {
      return;
    }
    setState(() {
      _showGame = true;
    });
  }

  /// Open a fresh controller, clear the latch, and mount LobbyScreen with
  /// [LobbyAction.create] on this same route. Then leave the finished room.
  /// Does not pop to Home. Does not call a protocol rematch.
  Future<void> _becomeNextLobby() async {
    if (_renewing) {
      return;
    }
    _renewing = true;
    final RoomController retiring = _controller;
    final RoomController? ownedRetiring = _routeOwned;
    retiring.removeListener(_onControllerChanged);

    final RoomController next = widget.controllerFactory();
    if (!mounted) {
      next.dispose();
      await retiring.leave();
      ownedRetiring?.dispose();
      _renewing = false;
      return;
    }
    _routeOwned = next;
    _controller = next;
    _showGame = false;
    next.addListener(_onControllerChanged);
    setState(() {});
    _renewing = false;

    await retiring.leave();
    ownedRetiring?.dispose();
  }

  static bool _roomIsInGame(RoomSnapshot? room) {
    return room != null &&
        (room.state == RoomState.playing || room.state == RoomState.finished);
  }

  @override
  Widget build(BuildContext context) {
    if (_showGame) {
      return GameScreen(
        controller: _controller,
        onRequestNewTable: _becomeNextLobby,
      );
    }
    final bool nextTableLobby = _routeOwned != null;
    return LobbyScreen(
      controller: _controller,
      action: nextTableLobby ? LobbyAction.create : widget.action,
      playerName: widget.playerName,
      code: nextTableLobby ? null : widget.code,
      players: widget.players,
    );
  }
}
