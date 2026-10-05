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
import 'seat_card.dart';
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

  /// C-246 rule 7: true while this device's own `rematch` accept is open,
  /// so a second tap on [lobby-rematch-accept] sends nothing.
  bool _rematchInFlight = false;

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

  /// C-246 rule 7: the tap handler for `lobby-rematch-accept`, sending
  /// `rematch` for a joiner who landed on this screen because a rematch
  /// LOBBY's route never saw a game. `RoomController.rematch` never
  /// throws, so this always reaches the end and clears the guard.
  Future<void> _onRematchAccept() async {
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
                // C-254 rule 5: only the occupied seats get a pip here,
                // not the fixed four the strip draws by default.
                SeatPipStrip(
                  key: const Key('game-seat-pip-strip'),
                  seats: controller.room!.seats
                      .map((SeatState s) => s.seat)
                      .toList(),
                ),
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
    // C-246 rule 7: a joiner of a rematch LOBBY lands here, because this
    // route never saw a game. Not the host and not any seat that already
    // played game one -- both stay on GameScreen, whose own latch never
    // sends them back to this screen (rule 2) -- so the ordinary host and
    // waiting blocks below are replaced by the one-tap accept whenever
    // this seat has not answered yet.
    final RematchState? rematch = room.rematch;
    final bool inRematchLobby =
        room.state == RoomState.lobby && rematch != null;
    final bool amReadyForRematch =
        inRematchLobby &&
        controller.seat != null &&
        rematch.ready.contains(controller.seat);
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
          _seatGrid(loc, room, controller),
          SizedBox(height: compact ? kSpace2 : kSpace3),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: kSpace2,
            runSpacing: kSpace2,
            children: [
              _ruleChip(
                chipKey: const Key('lobby-rule-blocks-chip'),
                icon: Icons.shield_outlined,
                on: room.rules.blocks,
                textKey: const Key('lobby-rule-blocks'),
                text: room.rules.blocks
                    ? loc.lobbyRuleBlocksOn
                    : loc.lobbyRuleBlocksOff,
              ),
              _ruleChip(
                chipKey: const Key('lobby-rule-capture-bonus-chip'),
                icon: Icons.replay_rounded,
                on: room.rules.captureBonus,
                textKey: const Key('lobby-rule-capture-bonus'),
                text: room.rules.captureBonus
                    ? loc.lobbyRuleCaptureBonusOn
                    : loc.lobbyRuleCaptureBonusOff,
              ),
            ],
          ),
          if (inRematchLobby && !amReadyForRematch) ...[
            const SizedBox(height: kSpace4),
            ElevatedButton(
              key: const Key('lobby-rematch-accept'),
              onPressed: _rematchInFlight ? null : () => _onRematchAccept(),
              child: Text(loc.endRematch),
            ),
          ] else if (inRematchLobby && amReadyForRematch) ...[
            const SizedBox(height: kSpace4),
            Text(
              loc.endRematchWaiting,
              key: const Key('lobby-rematch-waiting'),
              textAlign: TextAlign.center,
            ),
          ],
          if (!inRematchLobby && !controller.isHost) ...[
            const SizedBox(height: kSpace4),
            Text(
              roomFull
                  ? loc.lobbyWaitingForHost
                  : loc.lobbyWaitingForPlayers(room.seats.length, room.players),
              key: const Key('lobby-waiting'),
              textAlign: TextAlign.center,
            ),
          ],
          if (!inRematchLobby && controller.isHost) ...[
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

  /// C-254 rules 1-3: the occupied seats (in `room.seats` order, never
  /// re-sorted by seat number) followed by one open-seat placeholder per
  /// seat nobody has taken yet, laid out two to a row. A plain `Row` of
  /// each pair sits under the ambient `Directionality`, so Arabic mirrors
  /// seat order to start at the right on its own; nothing here flips
  /// anything by hand.
  Widget _seatGrid(
    AppLocalizations loc,
    RoomSnapshot room,
    RoomController controller,
  ) {
    final int openCount = room.players - room.seats.length;
    final List<Widget> cards = [
      for (final SeatState seat in room.seats)
        SeatCard(
          seat: seat,
          isMine: controller.seat == seat.seat,
          isHost: seat.seat == room.hostSeat,
          youLabel: loc.seatYou,
        ),
      for (int i = 0; i < openCount; i++)
        OpenSeatCard(index: i, label: loc.lobbyOpenSeat),
    ];

    final List<Widget> rows = [];
    for (int i = 0; i < cards.length; i += 2) {
      final bool hasSecond = i + 1 < cards.length;
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: kSpace2),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: cards[i]),
                const SizedBox(width: kSpace2),
                Expanded(child: hasSecond ? cards[i + 1] : const SizedBox()),
              ],
            ),
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  /// C-254 rule 4: an icon plus the existing label `Text`, key and string
  /// unchanged. Off state keeps the same icon, mutes its colour, and adds
  /// a diagonal strike -- a second signal besides colour (doctrine P9).
  /// Amendment rule 8: the chip itself (this `DecoratedBox`) carries its
  /// own key, so a test can find the icon and the strike inside the chip
  /// without reading them off the label `Text`. Amendment rule 9: the
  /// label sits in a `Flexible` rather than a bare `Text` in a
  /// `Row(mainAxisSize: min)`, so at 360dp, en/ar, scale 1.0/1.3, it wraps
  /// instead of pushing the row past its given width.
  Widget _ruleChip({
    required Key chipKey,
    required IconData icon,
    required bool on,
    required Key textKey,
    required String text,
  }) {
    final Color color = on ? LudoColors.action : LudoColors.inkMuted;
    return DecoratedBox(
      key: chipKey,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(kRadiusControl),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace3,
          vertical: kSpace2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: kSpace5,
              height: kSpace5,
              child: on
                  ? Icon(icon, size: kSpace5, color: color)
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(icon, size: kSpace5, color: color),
                        CustomPaint(
                          size: Size(kSpace5, kSpace5),
                          painter: _RuleOffStrikePainter(color: color),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: kSpace2),
            Flexible(child: Text(text, key: textKey, maxLines: 2)),
          ],
        ),
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

/// C-254 rule 4: the diagonal strike an "off" rule chip draws over its own
/// icon, on top of the muted colour, so off is never colour alone.
class _RuleOffStrikePainter extends CustomPainter {
  const _RuleOffStrikePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.12, size.height * 0.12),
      Offset(size.width * 0.88, size.height * 0.88),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant _RuleOffStrikePainter oldDelegate) =>
      oldDelegate.color != color;
}
