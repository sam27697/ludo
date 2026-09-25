// The first screen that turns a tap into a live socket. Everything it shows
// comes from RoomController; nothing here rolls a die, resolves a rule, or
// advances a turn. When the server disagrees with what this screen last
// drew, the server wins and the next rebuild shows that.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_mark.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'session_memory.dart' show SeatRecord;
import 'theme.dart';

/// The one request LobbyScreen issues, once, from initState.
enum LobbyAction { create, join, resume }

/// The base every shareable room link is built from. One constant, one
/// place. Room links are served by the game server's own GET /r/<CODE>
/// route.
const String kRoomLinkBase = 'https://ludo.provefair.app/r/';

/// The codes a `failed` room can carry that are worth retrying
/// automatically: a transport that would not open, a request that timed
/// out, and a connection that closed under a request. Mirrors
/// `_retryableErrorCodes` in `net/room_controller.dart`, which is private to
/// that file, so this is its own copy rather than an import of it.
const Set<String> _retryableLobbyErrorCodes = <String>{
  'transport',
  'timeout',
  'closed',
};

/// Maps a RoomController error code to a localised message. Pure and
/// top-level so it can be tested without pumping a widget.
String lobbyErrorMessage(AppLocalizations loc, String? code) {
  switch (code) {
    case 'NO_SUCH_ROOM':
      return loc.lobbyErrorNoSuchRoom;
    case 'ROOM_FULL':
      return loc.lobbyErrorRoomFull;
    case 'ROOM_STARTED':
      return loc.lobbyErrorRoomStarted;
    case 'RATE_LIMITED':
      return loc.lobbyErrorRateLimited;
    case 'transport':
      return loc.lobbyErrorTransport;
    default:
      return loc.lobbyErrorGeneric;
  }
}

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({
    super.key,
    required this.controller,
    required this.action,
    required this.playerName,
    this.code,
    this.players = 4,
    this.resume,
  });

  final RoomController controller;
  final LobbyAction action;
  final String playerName;

  /// Required in practice when [action] is [LobbyAction.join]; ignored on
  /// create.
  final String? code;

  /// The seat count requested on create; ignored on join.
  final int players;

  /// Required in practice when [action] is [LobbyAction.resume]; ignored
  /// otherwise. The seat the resume request is sent for.
  final SeatRecord? resume;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _issueRequest();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    setState(() {});
  }

  /// The one request this screen ever issues on its own initiative: the
  /// create or join initState opened with, or the same thing again from the
  /// retry button. Never awaited here; RoomController's own contract is that
  /// neither future ever throws.
  void _issueRequest() {
    switch (widget.action) {
      case LobbyAction.create:
        widget.controller.createRoom(
          name: widget.playerName,
          players: widget.players,
        );
      case LobbyAction.join:
        widget.controller.joinRoom(code: widget.code!, name: widget.playerName);
      case LobbyAction.resume:
        final SeatRecord resume = widget.resume!;
        widget.controller.resumeRoom(
          code: resume.code,
          seat: resume.seat,
          seatToken: resume.seatToken,
        );
    }
  }

  Future<void> _copyToClipboard(String text, AppLocalizations loc) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(loc.lobbyLinkCopied)));
  }

  /// Pops this lobby. Completes the pop immediately so Cancel is not gated
  /// on the page transition.
  void _leaveLobby() {
    final NavigatorState navigator = Navigator.of(context);
    final Route<dynamic> route = ModalRoute.of(context)!;
    navigator.pop();
    if (route.navigator != null) {
      navigator.finalizeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final RoomController controller = widget.controller;
    final bool connected = controller.phase == RoomPhase.connected;

    // L1: a `failed` phase with a room still set and a retryable errorCode
    // is the same "connection lost, an automatic reconnect may already be
    // under way" state `closed` is, not the create/join/resume error body.
    // Retrying it with `_issueRequest` would re-create the room out from
    // under the friends already waiting in the old one.
    final bool retryableFailure =
        controller.phase == RoomPhase.failed &&
        controller.room != null &&
        _retryableLobbyErrorCodes.contains(controller.errorCode);

    final Widget phaseBody = switch (controller.phase) {
      RoomPhase.idle || RoomPhase.connecting => _connectingBody(loc),
      RoomPhase.connected => _connectedBody(loc, controller),
      RoomPhase.failed =>
        retryableFailure
            ? _closedBody(loc, controller)
            : _errorBody(loc, controller),
      RoomPhase.closed => _closedBody(loc, controller),
    };

    return Scaffold(
      backgroundColor: LudoColors.paper,
      body: FeltBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              // Same signature chrome as GameScreen: felt edge frames the
              // seat-pip strip so home→lobby→game stays one continuous table.
              // Only on the connected gathering body to avoid crowding
              // connecting / error / closed states.
              if (connected) ...[
                const FeltEdge(key: Key('game-felt-edge')),
                const SeatPipStrip(key: Key('game-seat-pip-strip')),
              ],
              if (controller.hasDesynced) _desyncBanner(loc, controller),
              Expanded(child: phaseBody),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectingBody(AppLocalizations loc) {
    return Center(
      key: const Key('lobby-connecting'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: kSpace4),
          Text(loc.lobbyConnecting),
          const SizedBox(height: kSpace4),
          OutlinedButton(
            key: const Key('lobby-cancel-button'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _leaveLobby,
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ],
      ),
    );
  }

  Widget _errorBody(AppLocalizations loc, RoomController controller) {
    return Center(
      key: const Key('lobby-error'),
      child: Padding(
        padding: const EdgeInsets.all(kSpace6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              lobbyErrorMessage(loc, controller.errorCode),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: kSpace4),
            ElevatedButton(
              key: const Key('lobby-retry-button'),
              onPressed: _issueRequest,
              child: Text(loc.lobbyRetryButton),
            ),
          ],
        ),
      ),
    );
  }

  Widget _closedBody(AppLocalizations loc, RoomController controller) {
    return Center(
      key: const Key('lobby-closed'),
      child: Padding(
        padding: const EdgeInsets.all(kSpace6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(loc.lobbyConnectionLost, textAlign: TextAlign.center),
            if (controller.autoReconnectPending) ...[
              const SizedBox(height: kSpace2),
              Text(
                loc.lobbyReconnecting,
                key: const Key('lobby-reconnecting'),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: kSpace4),
            ElevatedButton(
              key: const Key('lobby-reconnect-button'),
              onPressed: controller.reconnect,
              child: Text(loc.lobbyReconnectButton),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectedBody(AppLocalizations loc, RoomController controller) {
    final RoomSnapshot room = controller.room!;
    final bool roomFull = room.seats.length == room.players;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double viewHeight = MediaQuery.sizeOf(context).height;
    // Same compact rule as home: widget-test surfaces are 800x600; real
    // phones are taller and get the larger shoutable die.
    final bool compact = viewHeight < 640;
    final double dieSize = dieMarkSize(compact);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        kSpace6,
        compact ? kSpace2 : kSpace6,
        kSpace6,
        compact ? kSpace4 : kSpace6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            loc.lobbyRoomCodeLabel,
            textAlign: TextAlign.center,
            style: textTheme.labelLarge?.copyWith(color: LudoColors.inkMuted),
          ),
          SizedBox(height: compact ? kSpace2 : kSpace3),
          Center(
            child: DieMark(
              size: dieSize,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  room.code,
                  key: const Key('lobby-room-code'),
                  textAlign: TextAlign.center,
                  style: textTheme.headlineMedium?.copyWith(
                    color: LudoColors.ink,
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? kSpace3 : kSpace4),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('lobby-copy-link-button'),
                  onPressed: () =>
                      _copyToClipboard(kRoomLinkBase + room.code, loc),
                  child: Text(loc.lobbyCopyLinkButton),
                ),
              ),
              const SizedBox(width: kSpace3),
              Expanded(
                child: OutlinedButton(
                  key: const Key('lobby-copy-code-button'),
                  onPressed: () => _copyToClipboard(room.code, loc),
                  child: Text(loc.lobbyCopyCodeButton),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? kSpace4 : kSpace6),
          for (final SeatState seat in room.seats)
            Padding(
              key: Key('lobby-seat-${seat.seat}'),
              padding: const EdgeInsets.symmetric(vertical: kSpace1),
              child: Text(seat.name, textAlign: TextAlign.center),
            ),
          if (!controller.isHost) ...[
            const SizedBox(height: kSpace4),
            Text(
              loc.lobbyWaitingForPlayers(room.seats.length, room.players),
              key: const Key('lobby-waiting'),
              textAlign: TextAlign.center,
            ),
          ],
          if (controller.isHost) ...[
            SizedBox(height: compact ? kSpace4 : kSpace6),
            ElevatedButton(
              key: const Key('lobby-start-button'),
              onPressed: roomFull ? controller.startGame : null,
              child: Text(
                roomFull
                    ? loc.lobbyStartButton
                    : loc.lobbyWaitingForPlayers(
                        room.seats.length,
                        room.players,
                      ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _desyncBanner(AppLocalizations loc, RoomController controller) {
    return Material(
      key: const Key('lobby-desync-banner'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace4,
          vertical: kSpace2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                loc.lobbyDesynced,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              key: const Key('lobby-resync-button'),
              onPressed: controller.reconnect,
              child: Text(loc.lobbyResyncButton),
            ),
          ],
        ),
      ),
    );
  }
}
