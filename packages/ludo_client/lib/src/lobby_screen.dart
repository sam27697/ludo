// The first screen that turns a tap into a live socket. Everything it shows
// comes from RoomController; nothing here rolls a die, resolves a rule, or
// advances a turn. When the server disagrees with what this screen last
// drew, the server wins and the next rebuild shows that.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_mark.dart';
import 'feedback_settings_sheet.dart' show showFeedbackSettingsSheet;
import 'game_screen.dart' show GameScreenResult;
import 'net/connection.dart' show RoomToggles;
import 'net/frame.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'seat_card.dart';
import 'rule_off_strike.dart';
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

  StreamSubscription<Frame>? _framesSubscription;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _framesSubscription = widget.controller.frames.listen(_onFrame);
    _issueRequest();
  }

  @override
  void dispose() {
    _framesSubscription?.cancel();
    _framesSubscription = null;
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    setState(() {});
  }

  // C-316 rule 3: a player_left naming this seat while in lobby pops with
  // GameScreenResult.removed.
  void _onFrame(Frame frame) {
    if (frame.type == 'player_left') {
      final dynamic seatValue = frame.data['seat'];
      final int? seat = seatValue is int
          ? seatValue
          : (seatValue is num ? seatValue.toInt() : null);
      if (seat != null && seat == widget.controller.seat) {
        if (mounted) {
          _leaveLobby(GameScreenResult.removed);
        }
      }
    }
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
  void _leaveLobby([Object? result]) {
    final NavigatorState navigator = Navigator.of(context);
    final Route<dynamic> route = ModalRoute.of(context)!;
    navigator.pop(result);
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

    // C-284 rule 1: stale is when a room is held and connection is lost,
    // retrying, or in a retryable failure.
    final bool stale =
        controller.room != null &&
        (controller.phase == RoomPhase.closed ||
            controller.phase == RoomPhase.connecting ||
            retryableFailure);

    final Widget phaseBody;
    if (stale) {
      // C-284 rules 1 and 2: a dropped or retrying connection keeps the
      // room in view (dimmed, untappable) under the connection-lost card.
      phaseBody = Stack(
        fit: StackFit.expand,
        children: [
          KeyedSubtree(
            key: const Key('lobby-stale-room'),
            child: IgnorePointer(
              ignoring: true,
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 0.35,
                  child: _connectedBody(loc, controller),
                ),
              ),
            ),
          ),
          _connectionLostCard(loc, controller),
        ],
      );
    } else {
      phaseBody = switch (controller.phase) {
        RoomPhase.idle || RoomPhase.connecting => _connectingBody(loc),
        RoomPhase.connected => _connectedBody(loc, controller),
        RoomPhase.failed => _errorBody(loc, controller),
        RoomPhase.closed => _closedBody(loc, controller),
      };
    }

    return Scaffold(
      backgroundColor: LudoColors.paper,
      body: FeltBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              // Same signature chrome as GameScreen: felt edge frames the
              // seat-pip strip so home→lobby→game stays one continuous table.
              // C-284 rule 3: built when connected or stale so the chrome row
              // and its corner close stay in place without jumping.
              if (connected || stale) ...[
                const FeltEdge(key: Key('game-felt-edge')),
                // C-262 rules 1-2: lobby-leave-button lives in this chrome
                // row, at the top start corner, beside the pip strip --
                // never a new full-width row above the content. The fixed
                // 48dp height keeps the Stack from sizing to the shorter pip
                // strip alone, which would let the icon's tap target bleed
                // above the row; the Stack itself keeps the strip centred on
                // its own width, and PositionedDirectional gives Arabic the
                // mirror (top right) for free, no hand-picked side.
                SizedBox(
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // C-254 rule 5: only the occupied seats get a pip
                      // here, not the fixed four the strip draws by
                      // default.
                      SeatPipStrip(
                        key: const Key('game-seat-pip-strip'),
                        seats: controller.room!.seats
                            .map((SeatState s) => s.seat)
                            .toList(),
                      ),
                      PositionedDirectional(
                        start: kSpace2,
                        child: IconButton(
                          key: const Key('lobby-leave-button'),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          tooltip: loc.gameLeaveButton,
                          onPressed: _leaveLobby,
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      // C-335 rule 1: the mirror of lobby-leave-button, at
                      // the end corner, so a player waiting on friends can
                      // mute sound and vibration without leaving.
                      PositionedDirectional(
                        end: kSpace2,
                        child: IconButton(
                          key: const Key('lobby-settings-button'),
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

  /// C-284 rule 2: one card centred over the stale room. Retrying shows the
  /// sync icon and reconnecting line without a Reconnect button; given up
  /// shows the Reconnect button. The corner close is the way out; no Leave
  /// button in the card.
  Widget _connectionLostCard(AppLocalizations loc, RoomController controller) {
    final bool isRetrying =
        controller.autoReconnectPending ||
        controller.phase == RoomPhase.connecting;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Material(
          key: const Key('lobby-closed'),
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
                const SizedBox(height: kSpace4),
                if (isRetrying)
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
                          key: const Key('lobby-reconnecting'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: LudoColors.inkMuted),
                        ),
                      ),
                    ],
                  )
                else
                  ElevatedButton(
                    key: const Key('lobby-reconnect-button'),
                    onPressed: controller.reconnect,
                    child: Text(loc.lobbyReconnectButton),
                  ),
              ],
            ),
          ),
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
        // C-262 rule 5: the 48dp lobby-leave-button row above this scroll
        // area already claims the height the old, shorter pip-strip row
        // did not, so every optional compact gap below is trimmed to the
        // smallest spacing unit to keep host, start and start-with-present
        // inside 360x616 and 800x600 in both locales.
        compact ? kSpace1 : kSpace6,
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
          SizedBox(height: compact ? kSpace1 : kSpace3),
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
          SizedBox(height: compact ? kSpace1 : kSpace4),
          ElevatedButton.icon(
            key: const Key('lobby-share-button'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => _shareInvite(room, loc),
            icon: const Icon(Icons.share),
            label: Text(loc.lobbyShareButton),
          ),
          SizedBox(height: compact ? kSpace1 : kSpace3),
          Row(
            children: [
              Expanded(
                // C-340 rule 1-2: an outlined pill, quieter than the filled
                // Invite friends button above it -- a visible border and a
                // leading icon so the label reads as tappable (doctrine P3,
                // P8), never a bare caption. Rule 6: two of these side by
                // side at 360dp leaves little room for icon plus label, so
                // the pill's own padding is trimmed (never the label's
                // text) and the label sits in a FittedBox that shrinks
                // before it would ever wrap or ellipsize.
                child: OutlinedButton.icon(
                  key: const Key('lobby-copy-link-button'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: kSpace2,
                      vertical: kSpace3,
                    ),
                  ),
                  onPressed: () =>
                      _copyToClipboard(kRoomLinkBase + room.code, loc),
                  icon: const Icon(Icons.link, size: 18),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(loc.lobbyCopyLinkButton, maxLines: 1),
                  ),
                ),
              ),
              const SizedBox(width: kSpace3),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('lobby-copy-code-button'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: kSpace2,
                      vertical: kSpace3,
                    ),
                  ),
                  onPressed: () => _copyToClipboard(room.code, loc),
                  icon: const Icon(Icons.content_copy, size: 18),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(loc.lobbyCopyCodeButton, maxLines: 1),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? kSpace1 : kSpace6),
          _seatGrid(loc, room, controller),
          SizedBox(height: compact ? kSpace1 : kSpace3),
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
            // C-274 rules 1-2: a full room enables the start button; a room
            // short of full shows the waiting line, with no disabled start
            // button.
            if (roomFull) ...[
              SizedBox(height: compact ? kSpace1 : kSpace6),
              ElevatedButton(
                key: const Key('lobby-start-button'),
                onPressed: controller.startGame,
                child: Text(loc.lobbyStartButton, textAlign: TextAlign.center),
              ),
            ] else ...[
              const SizedBox(height: kSpace4),
              Text(
                loc.lobbyWaitingForPlayers(room.seats.length, room.players),
                key: const Key('lobby-waiting'),
                textAlign: TextAlign.center,
              ),
              if (room.state == RoomState.lobby &&
                  !roomFull &&
                  room.seats.length >= 2) ...[
                SizedBox(height: compact ? kSpace1 : kSpace2),
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
          ],
        ],
      ),
    );
  }

  /// C-254 rules 1-3, C-347 decisions 1-3: the occupied seats (in
  /// `room.seats` order, never re-sorted by seat number) followed by one
  /// open-seat placeholder per seat nobody has taken yet. Two to a row
  /// while every seated name still fits one line in the width it gets
  /// inside a half-width card at the current text scale; one to a row,
  /// for the whole grid at once, the moment any one of them does not. A
  /// plain `Row` of each pair (or, one-up, of each single card) sits under
  /// the ambient `Directionality`, so Arabic mirrors seat order to start
  /// at the right on its own; nothing here flips anything by hand.
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

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool twoColumns = _seatedNamesFitTwoUp(
          context,
          room,
          constraints,
        );
        final List<Widget> rows = [];
        if (twoColumns) {
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
                      Expanded(
                        child: hasSecond ? cards[i + 1] : const SizedBox(),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
        } else {
          for (final Widget card in cards) {
            rows.add(
              Padding(
                padding: const EdgeInsets.only(bottom: kSpace2),
                child: Row(children: [Expanded(child: card)]),
              ),
            );
          }
        }
        return Column(children: rows);
      },
    );
  }

  /// C-347 decision 1: true while every seated player's name, measured in
  /// the card's own ambient style (`SeatCard`'s `DefaultTextStyle` merged
  /// with its name colour) at the ambient `TextScaler`, still lays out to
  /// one line inside the width that name would get in a half-width card --
  /// the grid's own [constraints] width, less the gap between the two
  /// columns, halved, less what `SeatCard` itself spends on padding, the
  /// token disc and (on an offline seat) the wifi-off icon. False the
  /// moment one name does not fit, so the whole grid drops to one column
  /// together (decision 1's "every row switches together"). Every
  /// `TextPainter` built to ask the question is disposed before this
  /// returns.
  bool _seatedNamesFitTwoUp(
    BuildContext context,
    RoomSnapshot room,
    BoxConstraints constraints,
  ) {
    final double halfCardWidth = (constraints.maxWidth - kSpace2) / 2;
    final TextDirection textDirection = Directionality.of(context);
    final TextScaler textScaler = MediaQuery.textScalerOf(context);

    bool allFit = true;
    for (final SeatState seat in room.seats) {
      final bool offline = !seat.connected;
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: seat.name,
          style: seatCardNameStyle(context, offline: offline),
        ),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout(maxWidth: seatCardNameWidth(halfCardWidth, offline: offline));
      if (painter.didExceedMaxLines) {
        allFit = false;
      }
      painter.dispose();
    }
    return allFit;
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
                          painter: RuleOffStrikePainter(color: color),
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
            // C-340 rule 3: same outlined-pill treatment as the copy
            // actions, in the strip's own onErrorContainer colour so it
            // reads against the error-tinted banner, not the paper theme.
            OutlinedButton.icon(
              key: const Key('lobby-resync-button'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
                side: BorderSide(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                minimumSize: const Size(48, 48),
              ),
              onPressed: controller.reconnect,
              icon: const Icon(Icons.sync, size: 20),
              label: Text(loc.lobbyResyncButton),
            ),
          ],
        ),
      ),
    );
  }
}
