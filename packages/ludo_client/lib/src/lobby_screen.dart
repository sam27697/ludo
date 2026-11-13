// The first screen that turns a tap into a live socket. Everything it shows
// comes from RoomController; nothing here rolls a die, resolves a rule, or
// advances a turn. When the server disagrees with what this screen last
// drew, the server wins and the next rebuild shows that.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_mark.dart';
import 'feedback.dart';
import 'game_screen.dart' show GameScreenResult;
import 'net/connection.dart' show RoomToggles;
import 'net/frame.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'seat_card.dart';
import 'seat_entrance.dart';
import 'seat_mark.dart';
import 'seat_names.dart';
import 'sound_toggle.dart';
import 'spoken_line.dart';
import 'rule_off_strike.dart';
import 'session_memory.dart' show SeatRecord;
import 'theme.dart';
import 'update_required_view.dart';
import 'waiting_line.dart';

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

/// The codes where asking the server again changes nothing: the room is gone,
/// the room takes no more players, or the name itself is refused (C-529 D4).
const Set<String> _unretryableLobbyErrorCodes = <String>{
  'NO_SUCH_ROOM',
  'ROOM_STARTED',
  'BAD_FIELD',
};

/// C-536 D1: the label each seat in [seats] is drawn and spoken with,
/// keyed by `seat`. Recomputed from the snapshot at hand every time it is
/// asked, so a seat that leaves frees its name. The number is formatted for
/// the locale the way the home screen formats its counts.
Map<int, String> seatLabelsFor(
  BuildContext context,
  Iterable<SeatState> seats,
) {
  final AppLocalizations loc = AppLocalizations.of(context);
  final MaterialLocalizations material = MaterialLocalizations.of(context);
  return seatDisplayNames(
    seats,
    (String name, int number) =>
        loc.seatNameNumbered(name, material.formatDecimal(number)),
  );
}

/// C-599 D5(b): how long the "Karim joined" line stays under the seat grid.
const Duration kFriendJoinedLineHold = Duration(milliseconds: 2500);

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
    this.fromLink = false,
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

  /// True when a [LobbyAction.join] was started from a room link rather than
  /// from a code the player typed (C-447 D4b). A link whose room is gone
  /// shows [AppLocalizations.lobbyErrorLinkRoomGone] with no retry, since no
  /// retry of a reaped room can succeed. Ignored on create and resume.
  final bool fromLink;

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
  /// C-624 D4: the polite live region the friend-joined line also goes to,
  /// beside its announcement event.
  final SpokenLineController _spokenLine = SpokenLineController();

  /// True from the moment [lobby-start-with-present-button] is tapped until
  /// [controller.setPlayers] and, when it runs, [controller.startGame] both
  /// settle. While true a second tap sends nothing.
  bool _startWithPresentInFlight = false;

  /// C-246 rule 7: true while this device's own `rematch` accept is open,
  /// so a second tap on [lobby-rematch-accept] sends nothing.
  bool _rematchInFlight = false;

  /// True while the lobby scroll still has content below the viewport, so
  /// the docked action can show a soft top shadow (C-398). False when the
  /// column fits or the scroll is at its end.
  bool _contentUnderAction = false;

  void _noteContentUnderAction(ScrollMetrics metrics) {
    final bool under = metrics.maxScrollExtent > metrics.pixels + 0.5;
    if (under == _contentUnderAction) {
      return;
    }
    _contentUnderAction = under;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  StreamSubscription<Frame>? _framesSubscription;

  /// C-447 D4: set once a refused resume has started popping this route, so
  /// a second notification cannot pop twice. C-529 D3 shares it for a room
  /// that closed while the player was away.
  bool _resumeRefusalHandled = false;

  /// C-533 D1: set once a `player_left` naming this seat has started leaving
  /// the route, so a second such frame does nothing.
  bool _removedLeaveHandled = false;

  /// C-599 D5(a): the seats the grid has already drawn. Null until the grid
  /// first builds with a room; the seats it holds then are the ones that do
  /// not animate. A seat that leaves drops out, so its next occupant does.
  Set<int>? _drawnSeats;

  /// The entrance widgets keep one state per seat through any regrouping of
  /// the grid (two to a row, one to a row), so a card mid-entrance is never
  /// restarted by a neighbour joining.
  final Map<int, GlobalKey> _entranceKeys = <int, GlobalKey>{};

  /// C-599 D5(b), (c): the seat the "joined" line is about, while it shows,
  /// and the seats whose announcement is still owed, in arrival order. The
  /// name is read from the room at build time, because the frame reaches
  /// this screen before the controller has added the seat; two joins can
  /// land before the next build, so each owes its own announcement.
  int? _joinedSeat;
  final List<int> _joinedAnnounceQueue = <int>[];
  Timer? _joinedTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _framesSubscription = widget.controller.frames.listen(_onFrame);
    _issueRequest();
  }

  @override
  void dispose() {
    _spokenLine.dispose();
    _joinedTimer?.cancel();
    _framesSubscription?.cancel();
    _framesSubscription = null;
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    setState(() {});
    _syncUpdateRequiredAnnouncement();
    if (_resumeRefusalHandled || widget.controller.updateRequired) {
      return;
    }
    if (_resumeRefused) {
      _resumeRefusalHandled = true;
      // C-540 D2: a seat only drops its socket and keeps its token, so a
      // refused token means the next game started without this player.
      _leaveWith(
        widget.controller.errorCode == 'BAD_SEAT_TOKEN'
            ? GameScreenResult.removed
            : GameScreenResult.gameGone,
      );
    } else if (_roomClosedWhileAway) {
      _resumeRefusalHandled = true;
      _leaveWith(
        widget.controller.isHost
            ? GameScreenResult.roomClosedHost
            : GameScreenResult.roomClosedGuest,
      );
    }
  }

  /// True once the update card's title has been spoken for this route, so a
  /// rebuild never says it twice (section 27 rule 6).
  bool _announcedUpdateRequired = false;

  /// Speaks the update card's title once, the moment the controller says the
  /// server refused this build, through the same spoken line the lobby uses
  /// for its other lines.
  void _syncUpdateRequiredAnnouncement() {
    if (_announcedUpdateRequired || !widget.controller.updateRequired) {
      return;
    }
    _announcedUpdateRequired = true;
    final String title = AppLocalizations.of(context).updateRequiredTitle;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      SemanticsService.sendAnnouncement(
        View.of(context),
        title,
        Directionality.of(context),
      );
      _spokenLine.speak(title);
    });
  }

  /// Hands [result] to Home. A popup above this route (the settings sheet)
  /// must not be the thing a plain pop closes, and must not be left standing
  /// over Home either, so everything above this route is dismissed first and
  /// this route itself is what leaves (C-533 D1, the shape of
  /// `GameScreen._leaveGameRoute`).
  void _leaveWith(GameScreenResult result) {
    final NavigatorState navigator = Navigator.of(context);
    final Route<dynamic> route = ModalRoute.of(context)!;
    if (!route.isActive) {
      return;
    }
    if (route.isCurrent) {
      _leaveLobby(result);
      return;
    }
    navigator.popUntil((Route<dynamic> r) => r == route);
    if (route.isCurrent) {
      _leaveLobby(result);
    } else {
      navigator.removeRoute(route, result);
    }
  }

  /// C-447 D4: a resume answered NO_SUCH_ROOM (the room was reaped) or
  /// BAD_SEAT_TOKEN (the seat was taken back). The player typed no code, so
  /// there is nothing to check and nothing to retry: the route goes home
  /// instead of drawing the error body, with [GameScreenResult.gameGone] for
  /// the first and [GameScreenResult.removed] for the second (C-540 D2).
  bool get _resumeRefused {
    final RoomController controller = widget.controller;
    return widget.action == LobbyAction.resume &&
        controller.phase == RoomPhase.failed &&
        (controller.errorCode == 'NO_SUCH_ROOM' ||
            controller.errorCode == 'BAD_SEAT_TOKEN');
  }

  /// C-529 D3: a create or join lobby that held a room, and whose room the
  /// server reaped while the phone was away, comes back NO_SUCH_ROOM. The
  /// player typed no code and asked for no new room, so the route goes home
  /// with the line that says what happened; the error body's typed-code text
  /// and its Retry would be false here.
  bool get _roomClosedWhileAway {
    final RoomController controller = widget.controller;
    return widget.action != LobbyAction.resume &&
        controller.phase == RoomPhase.failed &&
        controller.errorCode == 'NO_SUCH_ROOM' &&
        controller.room != null;
  }

  // C-316 rule 3: a player_left naming this seat while in lobby leaves with
  // GameScreenResult.removed (C-533 D1: through _leaveWith, once).
  void _onFrame(Frame frame) {
    if (frame.type == 'player_joined') {
      _onFriendJoined(frame);
      return;
    }
    if (frame.type == 'player_left') {
      final dynamic seatValue = frame.data['seat'];
      final int? seat = seatValue is int
          ? seatValue
          : (seatValue is num ? seatValue.toInt() : null);
      if (seat != null &&
          seat == widget.controller.seat &&
          !_removedLeaveHandled) {
        if (mounted) {
          _removedLeaveHandled = true;
          _leaveWith(GameScreenResult.removed);
        }
      }
    }
  }

  /// C-599 D4, D5: a friend sat down while this phone waits in the lobby.
  /// The cue goes through the one feedback service, once for the frame; the
  /// line under the grid restarts for the newest join, and its spoken twin
  /// goes out from [_seatGrid] once the seat is in the room.
  void _onFriendJoined(Frame frame) {
    final RoomController controller = widget.controller;
    if (!mounted || controller.room?.state != RoomState.lobby) {
      return;
    }
    final List<FeedbackCue> cues = cuesForFrame(frame, mySeat: controller.seat);
    if (cues.isEmpty) {
      return;
    }
    final FeedbackService feedback = FeedbackScope.of(context);
    for (final FeedbackCue cue in cues) {
      feedback.play(cue);
    }
    final int seat = frame.data['seat'] as int;
    if (seat < 0 || seat >= LudoColors.seats.length) {
      return;
    }
    _joinedTimer?.cancel();
    _joinedTimer = Timer(kFriendJoinedLineHold, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _joinedSeat = null;
        _joinedAnnounceQueue.clear();
      });
    });
    setState(() {
      _joinedSeat = seat;
      _joinedAnnounceQueue.add(seat);
    });
  }

  /// The one request this screen ever issues on its own initiative: the
  /// create or join initState opened with, or the same thing again from the
  /// retry button. Never awaited here; RoomController's own contract is that
  /// neither future ever throws.
  void _issueRequest() {
    // C-529 D3: once a room code was issued to this lobby, Retry resumes that
    // seat. Sending createRoom or joinRoom again would open a second room, or
    // take a second seat, that nobody asked for.
    if (widget.controller.room != null) {
      widget.controller.reconnect();
      return;
    }
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
  ///
  /// C-540 D6: a tap that lands while this route is already leaving does
  /// nothing, so it cannot pop the route below.
  void _leaveLobby([Object? result]) {
    final NavigatorState navigator = Navigator.of(context);
    final Route<dynamic> route = ModalRoute.of(context)!;
    if (!route.isActive || !route.isCurrent) {
      return;
    }
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
    if (controller.updateRequired) {
      // Section 27 rule 6, and it outranks every body below, the seat-moved
      // card included: this build cannot play on this server, so there is
      // nothing else to show. Home is what the corner close does.
      phaseBody = UpdateRequiredView(onHome: _leaveLobby);
    } else if (stale) {
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
        // A refused resume is already leaving with gameGone; the frames of
        // the pop transition keep the waiting body, never the error body.
        RoomPhase.failed when _resumeRefused || _roomClosedWhileAway =>
          _connectingBody(loc),
        RoomPhase.failed => _errorBody(loc, controller),
        RoomPhase.closed => _closedBody(loc, controller),
      };
    }

    return Scaffold(
      backgroundColor: LudoColors.paper,
      body: FeltBackdrop(
        child: SafeArea(
          // C-624 D4: the polite live region rides beside the column, in this
          // route's own semantics tree.
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Column(
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
                          // mute sound and vibration without leaving. C-523 D7:
                          // the one sound switch.
                          PositionedDirectional(
                            end: kSpace2,
                            child: SoundToggleButton(
                              key: const Key('lobby-sound-toggle'),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
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
              PositionedDirectional(
                top: 0,
                start: 0,
                child: SpokenLineRegion(controller: _spokenLine),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectingBody(AppLocalizations loc) {
    return Center(
      key: const Key('lobby-connecting'),
      // C-560 D4: the same side margin the connected body keeps, so the line
      // wraps inside the screen at large text sizes.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kSpace6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // C-560 D4: the line draws the one turning mark; with animations
            // removed it is a still, full-size icon that still reads as one.
            WaitingLine(
              key: const Key('lobby-connecting-line'),
              text: loc.lobbyConnecting,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: kSpace4),
            OutlinedButton(
              key: const Key('lobby-cancel-button'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _leaveLobby,
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBody(AppLocalizations loc, RoomController controller) {
    // C-447 D4b: a join that came from a link and found no such room says so
    // in the link's terms; a typed code keeps its text.
    final bool linkRoomGone =
        widget.fromLink &&
        widget.action == LobbyAction.join &&
        controller.errorCode == 'NO_SUCH_ROOM';
    // C-529 D4: no retry for a refusal a retry cannot change, typed or link.
    // A1.4: a lobby that held a room retries by resuming its seat, so a seat
    // taken back (BAD_SEAT_TOKEN) or a missing seat token has nothing to retry.
    final bool retryable =
        !_unretryableLobbyErrorCodes.contains(controller.errorCode) &&
        (controller.room == null ||
            (controller.errorCode != 'BAD_SEAT_TOKEN' &&
                controller.seatToken != null));
    // A1.3: only a create or join that never held a room has nothing to
    // leave. A resume lobby holds a stored seat, which Leave discards.
    final bool backToHome =
        widget.action != LobbyAction.resume && controller.room == null;
    // C-533 D2: the card shape of the game screen's connection-lost body.
    // The icon says what kind of refusal this is; the text is unchanged.
    final IconData icon = linkRoomGone || controller.errorCode == 'NO_SUCH_ROOM'
        ? Icons.link_off_rounded
        : controller.errorCode == 'transport'
        ? Icons.wifi_off_rounded
        : Icons.info_outline_rounded;
    final Widget leaveLabel = Text(
      backToHome ? loc.lobbyBackToHomeButton : loc.gameLeaveButton,
    );
    return Center(
      key: const Key('lobby-error'),
      child: _lobbyCard(
        cardKey: const Key('lobby-error-card'),
        icon: icon,
        title: linkRoomGone
            ? loc.lobbyErrorLinkRoomGone
            : lobbyErrorMessage(loc, controller.errorCode),
        // Exactly one filled button: Retry when it is offered, else the way
        // out takes that place.
        children: [
          if (retryable) ...[
            ElevatedButton(
              key: const Key('lobby-retry-button'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _issueRequest,
              child: Text(loc.lobbyRetryButton),
            ),
            const SizedBox(height: kSpace2),
            OutlinedButton(
              key: const Key('lobby-leave-button'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _leaveLobby,
              child: leaveLabel,
            ),
          ] else
            ElevatedButton(
              key: const Key('lobby-leave-button'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _leaveLobby,
              child: leaveLabel,
            ),
        ],
      ),
    );
  }

  Widget _closedBody(AppLocalizations loc, RoomController controller) {
    if (controller.seatTakenOver) {
      return Center(child: _seatMovedCard(loc, const Key('lobby-closed')));
    }
    return Center(
      child: _lobbyCard(
        cardKey: const Key('lobby-closed'),
        icon: Icons.wifi_off_rounded,
        title: loc.lobbyConnectionLost,
        children: [
          if (controller.autoReconnectPending) ...[
            WaitingLine(
              key: const Key('lobby-waiting-line'),
              text: loc.lobbyReconnecting,
              textKey: const Key('lobby-reconnecting'),
            ),
            const SizedBox(height: kSpace4),
          ],
          ElevatedButton(
            key: const Key('lobby-reconnect-button'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: controller.reconnect,
            child: Text(loc.lobbyReconnectButton),
          ),
          const SizedBox(height: kSpace2),
          OutlinedButton(
            key: const Key('lobby-leave-button'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _leaveLobby,
            child: Text(loc.gameLeaveButton),
          ),
        ],
      ),
    );
  }

  /// C-547 D2: the card for a seat another phone took over, in the lobby's
  /// card shape under [cardKey]. The reason, no Reconnect (resuming would take
  /// the seat back from that phone) and Leave as the one filled action. Its
  /// Key is not `lobby-leave-button`: the header's corner close owns that one
  /// on the stale-room overlay.
  Widget _seatMovedCard(AppLocalizations loc, Key cardKey) {
    return _lobbyCard(
      cardKey: cardKey,
      icon: Icons.phonelink_rounded,
      title: loc.seatMovedLine,
      children: [
        ElevatedButton(
          key: const Key('lobby-seat-moved-leave'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: _leaveLobby,
          child: Text(loc.gameLeaveButton),
        ),
      ],
    );
  }

  /// C-533 D2: the one card shape for the lobby's error and never-connected
  /// bodies, the game screen's `_connectionLostBody` without its game state:
  /// [icon] on top, [title] in `titleMedium`, then [children] (the actions).
  Widget _lobbyCard({
    required Key cardKey,
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Material(
        key: cardKey,
        color: LudoColors.paperElevated,
        borderRadius: BorderRadius.circular(2 * kRadiusControl),
        elevation: 6,
        child: Padding(
          padding: const EdgeInsets.all(kSpace5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 32, color: LudoColors.inkMuted),
              const SizedBox(height: kSpace2),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: LudoColors.ink),
              ),
              const SizedBox(height: kSpace4),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  /// C-284 rule 2: one card centred over the stale room. Retrying shows the
  /// sync icon and reconnecting line without a Reconnect button; given up
  /// shows the Reconnect button. The corner close is the way out; no Leave
  /// button in the card.
  Widget _connectionLostCard(AppLocalizations loc, RoomController controller) {
    if (controller.seatTakenOver) {
      return Center(child: _seatMovedCard(loc, const Key('lobby-closed')));
    }
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
                  WaitingLine(
                    key: const Key('lobby-waiting-line'),
                    text: loc.lobbyReconnecting,
                    textKey: const Key('lobby-reconnecting'),
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
    // C-398: compact is the height inside the safe area, not the raw screen
    // height. A 640-tall phone with a status bar and a nav bar is short
    // once those insets are subtracted. The threshold stays 640.
    final MediaQueryData media = MediaQuery.of(context);
    final double safeHeight =
        media.size.height - media.padding.top - media.padding.bottom;
    final bool compact = safeHeight < 640;
    final double dieSize = dieMarkSize(compact);
    final List<Widget> action = _lobbyAction(
      loc,
      controller,
      room,
      compact: compact,
      roomFull: roomFull,
      inRematchLobby: inRematchLobby,
      amReadyForRematch: amReadyForRematch,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (ScrollMetricsNotification notification) {
              _noteContentUnderAction(notification.metrics);
              return false;
            },
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                kSpace6,
                // C-262 rule 5: the 48dp lobby-leave-button row above this scroll
                // area already claims the height the old, shorter pip-strip row
                // did not, so every optional compact gap below is trimmed to the
                // smallest spacing unit. The start and waiting block is docked
                // below the scroll (C-398), not kept in by these gaps.
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
                    style: textTheme.labelLarge?.copyWith(
                      color: LudoColors.inkMuted,
                    ),
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
                  _friendJoinedLine(loc, room),
                  // C-523 D6: a default room shows no rule chip; only a room
                  // an older client created with the bonus off says so.
                  if (!room.rules.captureBonus) ...[
                    SizedBox(height: compact ? kSpace1 : kSpace3),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: kSpace2,
                      runSpacing: kSpace2,
                      children: [
                        _ruleChip(
                          chipKey: const Key('lobby-rule-capture-bonus-chip'),
                          icon: Icons.replay_rounded,
                          on: room.rules.captureBonus,
                          textKey: const Key('lobby-rule-capture-bonus'),
                          text: loc.lobbyRuleCaptureBonusOff,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        if (action.isNotEmpty)
          DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: _contentUnderAction
                  ? <BoxShadow>[
                      BoxShadow(
                        color: LudoColors.ink.withValues(alpha: 0.12),
                        blurRadius: 8,
                        offset: const Offset(0, -2),
                      ),
                    ]
                  : null,
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                kSpace6,
                kSpace2,
                kSpace6,
                compact ? kSpace4 : kSpace6,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: action,
              ),
            ),
          ),
      ],
    );
  }

  /// C-551 D2: a docked waiting line is a status, so it carries a still
  /// hourglass ahead of the text. The row follows the ambient direction, so
  /// the mark sits on the right in Arabic. The mark is out of semantics and
  /// does not move: the seat list above is what moves when a friend joins.
  Widget _dockedWaiting(String text, Key textKey) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        // A Builder: the line's Text renders under the Scaffold's Material,
        // so the style to measure is the one at the Row, not the State's.
        ExcludeSemantics(
          child: Builder(
            builder: (BuildContext rowContext) => Icon(
              Icons.hourglass_top_rounded,
              key: const Key('lobby-docked-waiting-mark'),
              size: waitingMarkSize(
                rowContext,
                DefaultTextStyle.of(rowContext).style,
              ),
              color: LudoColors.inkMuted,
            ),
          ),
        ),
        const SizedBox(width: kSpace2),
        Flexible(
          child: Text(text, key: textKey, textAlign: TextAlign.center),
        ),
      ],
    );
  }

  /// C-398: the host's start, the short-room start, and the waiting line
  /// (and the rematch accept that replaces them) sit outside the scroll.
  List<Widget> _lobbyAction(
    AppLocalizations loc,
    RoomController controller,
    RoomSnapshot room, {
    required bool compact,
    required bool roomFull,
    required bool inRematchLobby,
    required bool amReadyForRematch,
  }) {
    if (inRematchLobby && !amReadyForRematch) {
      return <Widget>[
        ElevatedButton(
          key: const Key('lobby-rematch-accept'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: _rematchInFlight ? null : () => _onRematchAccept(),
          child: Text(loc.endRematch),
        ),
      ];
    }
    if (inRematchLobby && amReadyForRematch) {
      return <Widget>[
        _dockedWaiting(
          loc.endRematchWaiting,
          const Key('lobby-rematch-waiting'),
        ),
      ];
    }
    if (!controller.isHost) {
      return <Widget>[
        _dockedWaiting(
          roomFull
              ? loc.lobbyWaitingForHost
              : loc.lobbyWaitingForPlayers(room.seats.length, room.players),
          const Key('lobby-waiting'),
        ),
      ];
    }
    // C-274 rules 1-2: a full room enables the start button; a room short
    // of full shows the waiting line, with no disabled start button.
    if (roomFull) {
      return <Widget>[
        ElevatedButton(
          key: const Key('lobby-start-button'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: controller.startGame,
          child: Text(loc.lobbyStartButton, textAlign: TextAlign.center),
        ),
      ];
    }
    return <Widget>[
      _dockedWaiting(
        loc.lobbyWaitingForPlayers(room.seats.length, room.players),
        const Key('lobby-waiting'),
      ),
      if (room.state == RoomState.lobby && room.seats.length >= 2) ...[
        SizedBox(height: compact ? kSpace1 : kSpace2),
        ElevatedButton(
          key: const Key('lobby-start-with-present-button'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: _startWithPresentInFlight
              ? null
              : () => _startWithPresent(room.seats.length),
          child: Text(
            loc.lobbyStartWithPresent(room.seats.length),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ];
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
    final Map<int, String> labels = seatLabelsFor(context, room.seats);
    // C-599 D5(a): a seat the grid has not drawn before enters; the seats
    // present when the grid first builds do not.
    final Set<int> current = <int>{
      for (final SeatState seat in room.seats) seat.seat,
    };
    final Set<int> drawnBefore = _drawnSeats ?? current;
    _drawnSeats = current;
    _entranceKeys.removeWhere(
      (int seat, GlobalKey _) => !current.contains(seat),
    );
    final List<Widget> cards = [
      for (final SeatState seat in room.seats)
        SeatEntrance(
          key: _entranceKeys.putIfAbsent(seat.seat, () => GlobalKey()),
          seat: seat.seat,
          entering: !drawnBefore.contains(seat.seat),
          child: SeatCard(
            seat: seat,
            displayName: labels[seat.seat],
            isMine: controller.seat == seat.seat,
            isHost: seat.seat == room.hostSeat,
            youLabel: loc.seatYou,
          ),
        ),
      for (int i = 0; i < openCount; i++)
        OpenSeatCard(index: i, label: loc.lobbyOpenSeat),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool twoColumns = _seatedNamesFitTwoUp(
          context,
          room,
          labels,
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

  /// C-599 D5(c): speaks, in arrival order, the join of every queued seat
  /// that is now in [room], each with its own seat's label. A seat is
  /// taken off the queue as it is scheduled, so a second build in the same
  /// frame announces nothing twice. The drain stops at the first seat the
  /// room does not hold yet, so a later join is never spoken ahead of it.
  void _drainJoinAnnouncements(AppLocalizations loc, RoomSnapshot room) {
    if (_joinedAnnounceQueue.isEmpty) {
      return;
    }
    final Map<int, String> labels = seatLabelsFor(context, room.seats);
    while (_joinedAnnounceQueue.isNotEmpty) {
      final String? name = labels[_joinedAnnounceQueue.first];
      if (name == null) {
        return;
      }
      _joinedAnnounceQueue.removeAt(0);
      final String text = loc.lobbyFriendJoined(name);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        SemanticsService.sendAnnouncement(
          View.of(context),
          text,
          Directionality.of(context),
        );
        _spokenLine.speak(text);
      });
    }
  }

  /// C-599 D5(b), (c): "Karim joined" directly under the seat grid, the
  /// joining seat's mark at its start and the text in ink, for
  /// [kFriendJoinedLineHold]; a newer join replaces it. The name is the
  /// label that seat's card shows. The line is out of the semantics tree:
  /// TalkBack hears the same text once, as an announcement, sent here after
  /// the frame in which the seat first shows up in the room.
  Widget _friendJoinedLine(AppLocalizations loc, RoomSnapshot room) {
    final int? seat = _joinedSeat;
    final String? name = seat == null
        ? null
        : seatLabelsFor(context, room.seats)[seat];
    final String? text = name == null ? null : loc.lobbyFriendJoined(name);
    _drainJoinAnnouncements(loc, room);
    final bool still = MediaQuery.disableAnimationsOf(context);
    final Duration motion = still ? Duration.zero : kMotionShort;
    final Widget content = seat == null || text == null
        ? const SizedBox(width: double.infinity)
        : ExcludeSemantics(
            child: TweenAnimationBuilder<double>(
              key: const Key('lobby-friend-joined-line'),
              tween: Tween<double>(begin: 0, end: 1),
              duration: motion,
              curve: Curves.easeOut,
              builder: (BuildContext context, double t, Widget? line) =>
                  Opacity(opacity: t, child: line),
              child: Padding(
                padding: const EdgeInsets.only(bottom: kSpace2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: LudoColors.seats[seat],
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox.square(
                        dimension: kSpace5,
                        child: Center(child: SeatMark(seat: seat, size: 10)),
                      ),
                    ),
                    const SizedBox(width: kSpace2),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: LudoColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
    // AnimatedSize asserts on a zero duration, so under reduced motion the
    // line simply is or is not there.
    return still
        ? content
        : AnimatedSize(
            duration: motion,
            alignment: Alignment.topCenter,
            child: content,
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
    Map<int, String> labels,
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
          text: labels[seat.seat] ?? seat.name,
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
            _ResyncButton(
              resyncing: controller.isResyncing,
              onPressed: controller.resync,
              label: loc.lobbyResyncButton,
            ),
          ],
        ),
      ),
    );
  }
}

/// C-555 D2: the desync strip's Resync pill. While a resync is out on the
/// socket it takes no tap, draws in the strip's own colour at 60 % rather
/// than Material's grey, and its mark turns once per 1200 ms. With the
/// system's animations removed the mark stays still and the guard stays (P9).
class _ResyncButton extends StatefulWidget {
  const _ResyncButton({
    required this.resyncing,
    required this.onPressed,
    required this.label,
  });

  final bool resyncing;
  final Future<void> Function() onPressed;
  final String label;

  @override
  State<_ResyncButton> createState() => _ResyncButtonState();
}

class _ResyncButtonState extends State<_ResyncButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTurn();
  }

  @override
  void didUpdateWidget(_ResyncButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTurn();
  }

  void _syncTurn() {
    final bool still = MediaQuery.disableAnimationsOf(context);
    if (widget.resyncing && !still) {
      if (!_turn.isAnimating) {
        _turn.repeat();
      }
    } else {
      _turn.stop();
      _turn.value = 0;
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color ink = Theme.of(context).colorScheme.onErrorContainer;
    final Color dimmed = ink.withValues(alpha: 0.6);
    return OutlinedButton.icon(
      key: const Key('lobby-resync-button'),
      style:
          OutlinedButton.styleFrom(
            foregroundColor: ink,
            disabledForegroundColor: dimmed,
            minimumSize: const Size(48, 48),
          ).copyWith(
            side: WidgetStateProperty.resolveWith<BorderSide>(
              (Set<WidgetState> states) => BorderSide(
                color: states.contains(WidgetState.disabled) ? dimmed : ink,
              ),
            ),
          ),
      onPressed: widget.resyncing ? null : () => unawaited(widget.onPressed()),
      icon: RotationTransition(
        turns: _turn,
        child: const Icon(Icons.sync, size: 20),
      ),
      label: Text(widget.label),
    );
  }
}
