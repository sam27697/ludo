// The first screen that turns a tap into a live socket. Everything it shows
// comes from RoomController; nothing here rolls a die, resolves a rule, or
// advances a turn. When the server disagrees with what this screen last
// drew, the server wins and the next rebuild shows that.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_mark.dart';
import 'net/connection.dart' show RoomToggles;
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
    this.toggles = const RoomToggles(),
    this.resume,
    this.shareText,
  });

  final RoomController controller;
  final LobbyAction action;
  final String playerName;

  /// Required in practice when [action] is [LobbyAction.join]; ignored on
  /// create.
  final String? code;

  /// The seat count requested on create; ignored on join.
  final int players;

  /// The rules toggles requested on create; ignored on join.
  final RoomToggles toggles;

  /// Required in practice when [action] is [LobbyAction.resume]; ignored
  /// otherwise. The seat the resume request is sent for.
  final SeatRecord? resume;

  /// The tap handler for `lobby-share-button`, in place of the real system
  /// share sheet. Null in production, where the screen calls
  /// `SharePlus.instance.share` itself; set by tests to capture the text
  /// the screen would have shared without opening a sheet no test harness
  /// can drive.
  final Future<void> Function(String text)? shareText;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  /// True from the moment [lobby-start-with-present-button] is tapped until
  /// [controller.setPlayers] and, when it runs, [controller.startGame] both
  /// settle. While true a second tap sends nothing.
  bool _startWithPresentInFlight = false;

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
          toggles: widget.toggles,
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

  /// The tap handler for `lobby-start-with-present-button`: shrinks the
  /// room to [count], the seats occupied right now, then starts the game
  /// with them, but only when that shrink actually landed the room full on
  /// a controller still connected -- a friend joining between the tap and
  /// the server reading `set_players` is a race `controller.setPlayers`
  /// itself already recovers from silently, and this must not paper over
  /// that recovery by starting a game the fuller room was never asked for.
  Future<void> _startWithPresent(int count) async {
    if (_startWithPresentInFlight) {
      return;
    }
    setState(() {
      _startWithPresentInFlight = true;
    });
    await widget.controller.setPlayers(count);
    if (mounted) {
      final RoomController controller = widget.controller;
      final RoomSnapshot? room = controller.room;
      if (controller.phase == RoomPhase.connected &&
          room != null &&
          room.seats.length == room.players) {
        await controller.startGame();
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _startWithPresentInFlight = false;
    });
  }

  /// The tap handler for `lobby-share-button`: opens the system share sheet
  /// (or, under test, calls [LobbyScreen.shareText]) with one localised
  /// line carrying the room link and the code. Offered to host and guest
  /// alike, in every connected state where the code is shown. A share that
  /// throws still leaves the player holding the link, through the same
  /// clipboard fallback `lobby-copy-link-button` uses, and the error is
  /// never swallowed silently.
  Future<void> _shareInvite(RoomSnapshot room, AppLocalizations loc) async {
    final String link = kRoomLinkBase + room.code;
    final String text = loc.lobbyShareText(link, room.code);
    try {
      final Future<void> Function(String text)? shareText = widget.shareText;
      if (shareText != null) {
        await shareText(text);
      } else {
        await SharePlus.instance.share(ShareParams(text: text));
      }
    } catch (error, stackTrace) {
      debugPrint(
        'lobby share failed, copying the link instead: $error\n$stackTrace',
      );
      if (!mounted) {
        return;
      }
      await _copyToClipboard(link, loc);
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
            const SizedBox(height: kSpace2),
            OutlinedButton(
              key: const Key('lobby-leave-button'),
              onPressed: _leaveLobby,
              child: Text(loc.gameLeaveButton),
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
            const SizedBox(height: kSpace2),
            OutlinedButton(
              key: const Key('lobby-leave-button'),
              onPressed: _leaveLobby,
              child: Text(loc.gameLeaveButton),
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
          ElevatedButton.icon(
            key: const Key('lobby-share-button'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => _shareInvite(room, loc),
            icon: const Icon(Icons.share),
            label: Text(loc.lobbyShareButton),
          ),
          SizedBox(height: compact ? kSpace2 : kSpace3),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const Key('lobby-copy-link-button'),
                  onPressed: () =>
                      _copyToClipboard(kRoomLinkBase + room.code, loc),
                  child: Text(loc.lobbyCopyLinkButton),
                ),
              ),
              const SizedBox(width: kSpace3),
              Expanded(
                child: TextButton(
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
          SizedBox(height: compact ? kSpace2 : kSpace3),
          Text(
            room.rules.blocks ? loc.lobbyRuleBlocksOn : loc.lobbyRuleBlocksOff,
            key: const Key('lobby-rule-blocks'),
            textAlign: TextAlign.center,
          ),
          Text(
            room.rules.captureBonus
                ? loc.lobbyRuleCaptureBonusOn
                : loc.lobbyRuleCaptureBonusOff,
            key: const Key('lobby-rule-capture-bonus'),
            textAlign: TextAlign.center,
          ),
          if (!controller.isHost) ...[
            const SizedBox(height: kSpace4),
            Text(
              roomFull
                  ? loc.lobbyWaitingForHost
                  : loc.lobbyWaitingForPlayers(room.seats.length, room.players),
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
            if (room.state == RoomState.lobby &&
                !roomFull &&
                room.seats.length >= 2) ...[
              const SizedBox(height: kSpace2),
              ElevatedButton(
                key: const Key('lobby-start-with-present-button'),
                onPressed: _startWithPresentInFlight
                    ? null
                    : () => _startWithPresent(room.seats.length),
                child: Text(
                  loc.lobbyStartWithPresent(room.seats.length),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
          SizedBox(height: compact ? kSpace2 : kSpace3),
          OutlinedButton(
            key: const Key('lobby-leave-button'),
            onPressed: _leaveLobby,
            child: Text(loc.gameLeaveButton),
          ),
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
