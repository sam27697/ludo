import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import 'deep_link.dart';
import 'die_mark.dart';
import 'directional_icon.dart';
import 'game_screen.dart' show GameScreenResult;
import 'lobby_screen.dart' show LobbyAction;
import 'net/connection.dart' show RoomToggles;
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'room_code.dart';
import 'room_route.dart';
import 'rule_off_strike.dart';
import 'server_config.dart';
import 'session_memory.dart';
import 'theme.dart';

/// How long the home scroll view takes to bring a link's target back into
/// view (order 194). Independent of the brand's own motion tokens in
/// theme.dart: this is a short, corrective nudge triggered by an incoming
/// link, not part of the screen's entrance.
const Duration kLinkScrollDuration = Duration(milliseconds: 300);

/// Home screen: one branded composition — wordmark, tagline, die mark, and
/// the create/join controls. Knowing the code is the only way into a room.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onToggleLocale,
    this.controllerFactory = defaultRoomControllerFactory,
    this.initialLinkReader = noInitialLink,
    this.linkStream = noLinkStream,
  });

  /// Flips the app between its two supported locales.
  final VoidCallback onToggleLocale;

  /// Builds the [RoomController] a Create Room or Join Room tap pushes a
  /// [LobbyScreen] with. The real default opens a real socket; a test
  /// substitutes one built over a fake transport.
  final RoomControllerFactory controllerFactory;

  /// Reads the link that launched the app, if any (the cold-start path).
  /// Defaults to a reader that never finds one, so a widget pumped with no
  /// arguments never touches a real platform channel.
  final InitialLinkReader initialLinkReader;

  /// A stream of links arriving while the app is already running (the
  /// warm-start path). Defaults to a stream that never emits, for the same
  /// reason as [initialLinkReader].
  final LinkStreamOpener linkStream;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  String? _errorText;
  int _players = 4;
  bool _playersSelectorOpen = false;
  bool _rulesBlocks = true;
  bool _rulesCaptureBonus = true;
  String? _nameLocaleDefault;
  StreamSubscription<Uri>? _linkSubscription;
  late final AnimationController _enter;
  bool _enterMotionArmed = false;
  bool _hasLastTable = false;
  String? _lastTableName;
  int? _lastTableSeats;
  List<String> _recentCodes = const <String>[];
  RoomController? _ownedController;
  // H3: the seat rejoin button shows exactly when this is non-null. Only
  // ever set from _restoreSessionMemory's one-time load and cleared by H2.
  SeatRecord? _seatRecord;
  // H1's per-controller dedupe: the last record written to SessionMemory
  // for the controller currently owned, so a chatty controller does not
  // write the same seat on every notification. Reset whenever a new
  // controller is watched.
  SeatRecord? _lastRecordedSeatWritten;
  // H2's per-controller dedupe for the finished/seat-gone clear, reset the
  // same way.
  bool _seatClearedForOwned = false;
  // Order 296: session memory must finish loading before deciding whether a
  // link joins or leaves the code filled for a first-time player.
  bool _sessionMemoryLoaded = false;
  // Order 296 rule 5: a link arriving before session memory loads is held
  // until the load finishes, with the latest link winning.
  Uri? _pendingLinkUri;
  // Order 296 rule 5b: bounded hold on a pending link before falling back to
  // the first-time player behaviour.
  Timer? _linkHoldTimer;
  // Order 296 rule 6: guards against pushing duplicate routes when Android
  // delivers the same link through both initial link reader and the stream.
  bool _linkJoinInFlight = false;
  // Order 194: reach the join button's and the code field's render objects
  // from _handleLink without disturbing the Key('join-room-button') /
  // Key('room-code-field') values the rest of the suite finds those widgets
  // by. Each wraps the widget that already carries that key in a
  // KeyedSubtree, one layer up.
  final GlobalKey _joinButtonScrollKey = GlobalKey();
  final GlobalKey _codeFieldScrollKey = GlobalKey();
  // Order 209: reach create-room-button's render object from the players
  // disclosure's onPressed the same way, without disturbing
  // Key('create-room-button').
  final GlobalKey _createButtonScrollKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _codeController.addListener(_clearErrorOnEdit);
    unawaited(_restoreSessionMemory());
    // Duration and reduced-motion short-circuit need Theme / MediaQuery, which
    // are not available until [didChangeDependencies].
    _enter = AnimationController(vsync: this);
    try {
      widget.initialLinkReader().then(
        (uri) {
          if (uri != null) {
            _handleLink(uri);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _reportLinkError(error, stackTrace, 'reading the initial link');
        },
      );
    } catch (error, stackTrace) {
      _reportLinkError(error, stackTrace, 'reading the initial link');
    }
    try {
      _linkSubscription = widget.linkStream().listen(
        _handleLink,
        onError: (Object error, StackTrace stackTrace) {
          _reportLinkError(error, stackTrace, 'listening to the link stream');
        },
      );
    } catch (error, stackTrace) {
      _reportLinkError(error, stackTrace, 'listening to the link stream');
    }
  }

  /// Reports a failure on either deep-link path through the framework's
  /// non-fatal channel. Neither path is allowed to show anything to the
  /// player: a link that could not be read just leaves the code field for
  /// the player to fill in by hand, which is the documented fallback.
  void _reportLinkError(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'ludo client',
        context: ErrorDescription(context),
      ),
    );
  }

  /// Applies a room code found in an incoming link to the code field, and
  /// joins or rejoins the room when the player is known and Home is the
  /// current route (order 296).
  ///
  /// A returning player whose session memory held a name from an earlier
  /// table navigates straight into the room: [LobbyAction.join] with the
  /// pre-filled code, or [LobbyAction.resume] when the memory holds a seat
  /// record for that same code.
  ///
  /// Navigation does not happen and the code is only pre-filled when the
  /// player is first-time (their name is still needed, so Join remains
  /// their tap), when another route (a lobby, a game) is currently pushed
  /// above Home (rule B5), or when the code is invalid.
  void _handleLink(Uri uri) {
    if (!mounted) {
      return;
    }
    if (!isAppRoomLinkUri(uri)) {
      // Not a room link at all: wrong scheme, wrong host or wrong path
      // shape. That is not the player's mistake, so it gets the documented
      // fallback on _reportLinkError above -- the code field is left for
      // the player to fill in by hand -- and nothing here touches it.
      return;
    }
    final AppLocalizations loc = AppLocalizations.of(context);
    final String? code = roomCodeFromUri(uri);
    final bool codeIsValid = code != null;
    setState(() {
      if (codeIsValid) {
        _codeController.text = code;
        _errorText = null;
      } else {
        _errorText = loc.homeRoomCodeInvalid;
      }
    });
    if (!codeIsValid) {
      // Rule 4: an invalid code never joins, clears any link pending on
      // session memory (the latest link wins), and keeps the error scroll.
      _pendingLinkUri = null;
      _linkHoldTimer?.cancel();
      _linkHoldTimer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _scrollLinkTargetIntoView(codeIsValid: false);
      });
      return;
    }
    if (!_sessionMemoryLoaded) {
      // Rule 5: held until session memory finishes loading; the latest
      // incoming link wins.
      // Rule 5b: bounded to 500 ms, so a store that never answers cannot
      // hold a link forever; past that it is treated as a first-time player.
      _pendingLinkUri = uri;
      _linkHoldTimer ??= Timer(
        const Duration(milliseconds: 500),
        _onLinkHoldTimeout,
      );
      return;
    }
    _decideLinkAction(code);
  }

  /// Evaluates whether an incoming link with valid [code] can push into the
  /// room or should leave the code filled in place (order 296).
  void _decideLinkAction(String code) {
    if (!mounted) {
      return;
    }
    final bool isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
    if (isCurrent && !_linkJoinInFlight && _hasLastTable) {
      final SeatRecord? record = _seatRecord;
      if (record != null && record.code == code) {
        unawaited(_joinFromLink(rejoin: true, seatRecord: record));
      } else {
        unawaited(_joinFromLink(rejoin: false));
      }
      return;
    }
    // Run 57: first-time player (rule 2) or home screen sitting underneath
    // an existing route (rule 3) scrolls the target into view rather than
    // navigating.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _scrollLinkTargetIntoView(codeIsValid: true);
    });
  }

  /// Resolves any pending link held while session memory was loading
  /// (rule 5).
  void _drainPendingLink() {
    _linkHoldTimer?.cancel();
    _linkHoldTimer = null;
    final Uri? uri = _pendingLinkUri;
    _pendingLinkUri = null;
    if (uri == null) {
      return;
    }
    final String? code = roomCodeFromUri(uri);
    if (code == null) {
      return;
    }
    _decideLinkAction(code);
  }

  /// Decides a pending link held while session memory was loading as a
  /// first-time player when the 500 ms hold bound expires (order 296 rule 5b).
  void _onLinkHoldTimeout() {
    _linkHoldTimer = null;
    if (!mounted) {
      return;
    }
    final Uri? uri = _pendingLinkUri;
    _pendingLinkUri = null;
    if (uri == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _scrollLinkTargetIntoView(codeIsValid: true);
    });
  }

  /// Runs a link-driven join or rejoin, guarding against duplicate pushes
  /// while the route is in flight (rule 6).
  Future<void> _joinFromLink({
    required bool rejoin,
    SeatRecord? seatRecord,
  }) async {
    _linkJoinInFlight = true;
    try {
      if (rejoin && seatRecord != null) {
        await _rejoinRoom(seatRecord);
      } else {
        await _joinRoom();
      }
    } finally {
      _linkJoinInFlight = false;
    }
  }

  /// Scrolls the join button (a valid code) or the code field (an invalid
  /// one) fully into the home scroll view's viewport, aligned so the
  /// target's bottom edge is visible. A no-op if the target's context is not
  /// available, which should not happen for a mounted screen but is not
  /// worth crashing over if it ever does.
  void _scrollLinkTargetIntoView({required bool codeIsValid}) {
    final BuildContext? targetContext = codeIsValid
        ? _joinButtonScrollKey.currentContext
        : _codeFieldScrollKey.currentContext;
    if (targetContext == null) {
      return;
    }
    final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
    Scrollable.ensureVisible(
      targetContext,
      alignment: 1.0,
      duration: reducedMotion ? Duration.zero : kLinkScrollDuration,
      curve: Curves.easeOut,
    );
  }

  /// Scrolls create-room-button back into the home scroll view's viewport
  /// when opening the players/rules disclosure has pushed it below the
  /// bottom edge (order 209). keepVisibleAtEnd only moves the scroll
  /// position when the button's bottom already sits past the viewport's
  /// bottom, and then only as far as bringing it to that edge, so a button
  /// that is already visible is left alone rather than pushed further up.
  /// A null context is a silent no-op, same as [_scrollLinkTargetIntoView].
  ///
  /// Instant, not animated (order 209 respec 1): a scroll with a nonzero
  /// duration runs as a DrivenScrollActivity, and that activity's
  /// shouldIgnorePointer is true for as long as it is running, so the whole
  /// Home content stops accepting taps for the length of the animation. A
  /// player who opens the rules and immediately taps a player count would
  /// lose that tap. jumpTo has no activity and ignores nothing, and the
  /// disclosure itself already opens with no animation, so an instant
  /// scroll matches it.
  void _scrollCreateButtonIntoView() {
    final BuildContext? targetContext = _createButtonScrollKey.currentContext;
    if (targetContext == null) {
      return;
    }
    Scrollable.ensureVisible(
      targetContext,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: Duration.zero,
    );
  }

  /// Rebuilds on every keystroke so Create/Join emphasis can follow the
  /// code field, and clears a standing error so a message raised by a bad
  /// link or a failed Join tap does not sit under a code the player has
  /// since corrected.
  void _clearErrorOnEdit() {
    setState(() {
      _errorText = null;
    });
  }

  /// Restores last successful-create name and seats, the last-table chip,
  /// recent join codes, and a seat record held across a process kill (H3)
  /// from [SessionMemory]. An empty or unreadable store leaves the
  /// localised name default, the four-seat disclosure, no recent chips and
  /// no rejoin button as they are. The load itself returns empty on failure,
  /// so nothing is caught here. Completing the load marks session memory as
  /// loaded and drains any pending room link (order 296).
  Future<void> _restoreSessionMemory() async {
    try {
      final SessionMemory memory = await SessionMemory.load();
      if (!mounted) {
        return;
      }
      final bool hasTable = memory.hasLastTable;
      final bool hasCodes = memory.recentCodes.isNotEmpty;
      final SeatRecord? seatRecord = memory.seatRecord;
      if (hasTable || hasCodes || seatRecord != null) {
        setState(() {
          if (hasCodes) {
            _recentCodes = List<String>.from(memory.recentCodes);
          }
          if (hasTable) {
            final String name = memory.lastName!;
            final int seats = memory.lastSeats!;
            _hasLastTable = true;
            _lastTableName = name;
            _lastTableSeats = seats;
            _nameController.text = name;
            _players = seats;
          }
          if (seatRecord != null) {
            _seatRecord = seatRecord;
          }
        });
      }
    } finally {
      _linkHoldTimer?.cancel();
      _linkHoldTimer = null;
      _sessionMemoryLoaded = true;
      if (mounted) {
        _drainPendingLink();
      }
    }
  }

  /// Prefills the name field with the localised default on first paint, and
  /// rewrites it when the locale changes if the field is still blank or still
  /// holds the previous locale's default. A name the player typed is left
  /// alone. LudoApp's locale toggle updates [Localizations], which is an
  /// inherited widget, so this is the place that sees the new default.
  /// A name restored from [SessionMemory] is treated as typed: it is not
  /// replaced by the locale default.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final String nextDefault = AppLocalizations.of(context)
        .homeDefaultPlayerName;
    final String current = _nameController.text;
    if (current.isEmpty || current == _nameLocaleDefault) {
      if (current != nextDefault) {
        _nameController.text = nextDefault;
      }
    }
    _nameLocaleDefault = nextDefault;
    _armEnterMotion();
  }

  /// Wires [_enter] to [LudoBrand.motionLong] once, and jumps to completed
  /// immediately when [MediaQuery.disableAnimationsOf] is true.
  ///
  /// Falls back to [kMotionLong] when a harness mounts [HomeScreen] without
  /// [buildAppTheme] (no [LudoBrand] extension).
  void _armEnterMotion() {
    if (_enterMotionArmed) {
      return;
    }
    _enterMotionArmed = true;
    final LudoBrand? brand = Theme.of(context).extension<LudoBrand>();
    _enter.duration = brand?.motionLong ?? kMotionLong;
    if (MediaQuery.disableAnimationsOf(context)) {
      _enter.value = 1.0;
    } else {
      _enter.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _linkHoldTimer?.cancel();
    _codeController.removeListener(_clearErrorOnEdit);
    _codeController.dispose();
    _nameController.dispose();
    _enter.dispose();
    _pendingLinkUri = null;
    final RoomController? owned = _ownedController;
    _ownedController = null;
    // H1/H2: this screen's own life is the other end of the "as long as
    // HomeScreen owns a controller" window; stop watching before it goes.
    owned?.removeListener(_onOwnedControllerChanged);
    // An in-flight create/join still has RoomConnection's 10s request
    // Timer. A connected table (Home unmounted under a live lobby, as in
    // a keyed relaunch) must not elapse FakeAsync. delayed() fires timers
    // on TestWidgetsFlutterBinding; a real binding has no delayed().
    if (owned != null && owned.phase == RoomPhase.connecting) {
      try {
        (WidgetsBinding.instance as dynamic).delayed(
          const Duration(seconds: 11),
        );
      } on Object {
        // Production WidgetsBinding, or nested FakeAsync elapse.
      }
    }
    super.dispose();
  }

  void _watchOwnedController(RoomController controller) {
    _ownedController = controller;
    _lastRecordedSeatWritten = null;
    _seatClearedForOwned = false;
    controller.addListener(_onOwnedControllerChanged);
  }

  /// H1: writes the seat this controller currently holds the moment it is
  /// worth resuming -- connected, a room snapshot, that room not finished,
  /// a seat and a seat token both present -- at most once per distinct
  /// record for as long as this controller is the one owned. Covers create,
  /// join and H4's resume alike, since all three route through
  /// [_watchOwnedController].
  ///
  /// H2(a)/(c): clears that same record, and hides the H3 button in the
  /// same frame, the moment the owned controller's room is observed
  /// finished or the controller is observed failed with a seat or room
  /// that is gone for good. H2(b), the "the player left" clear, runs from
  /// [_retireOwnedController] instead, since walking off the route is not
  /// something a notification on the controller ever announces on its own.
  void _onOwnedControllerChanged() {
    final RoomController? controller = _ownedController;
    if (controller == null) {
      return;
    }
    final RoomSnapshot? room = controller.room;
    if (controller.phase == RoomPhase.connected &&
        room != null &&
        room.state != RoomState.finished) {
      final int? seat = controller.seat;
      final String? seatToken = controller.seatToken;
      if (seat != null && seatToken != null) {
        final SeatRecord record = SeatRecord(
          code: room.code,
          seat: seat,
          seatToken: seatToken,
        );
        if (record != _lastRecordedSeatWritten) {
          _lastRecordedSeatWritten = record;
          unawaited(SessionMemory.recordSeat(record));
        }
      }
    }
    final bool finished = room != null && room.state == RoomState.finished;
    final bool seatGone =
        controller.phase == RoomPhase.failed &&
        (controller.errorCode == 'BAD_SEAT_TOKEN' ||
            controller.errorCode == 'NO_SUCH_ROOM');
    if ((finished || seatGone) && !_seatClearedForOwned) {
      _seatClearedForOwned = true;
      unawaited(SessionMemory.clearSeat());
      if (mounted) {
        setState(() {
          _seatRecord = null;
        });
      }
    }
  }

  /// C11: the app returning to the foreground is the other trigger, besides
  /// a drop, that should retry a dead connection without the player having
  /// to find the reconnect button themselves. This screen stays mounted
  /// underneath the pushed lobby or game route for the whole life of a room
  /// (see [_watchOwnedController], [_retireOwnedController]), which is why
  /// the hook lives here rather than on either of those screens. A no-op on
  /// every other lifecycle state, and a no-op on [RoomController.onAppResumed]
  /// itself when there is nothing to resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _ownedController?.onAppResumed();
    }
  }

  /// [leave] then [RoomController.dispose], unless [dispose] already retired
  /// this instance while the pushed route was still up.
  ///
  /// H2(b): once [leave] completes, the seat record is cleared and the H3
  /// button hidden unconditionally -- the player walked off the route, and
  /// leaving is leaving, whether or not a record was ever written for this
  /// controller.
  Future<void> _retireOwnedController(RoomController controller) async {
    if (!identical(_ownedController, controller)) {
      return;
    }
    controller.removeListener(_onOwnedControllerChanged);
    _ownedController = null;
    await controller.leave();
    controller.dispose();
    unawaited(SessionMemory.clearSeat());
    if (mounted) {
      setState(() {
        _seatRecord = null;
      });
    }
  }

  /// The typed name, trimmed, falling back to the localised default rather
  /// than ever sending the server an empty name.
  String _resolvedName(AppLocalizations loc) {
    final String typed = _nameController.text.trim();
    return typed.isEmpty ? loc.homeDefaultPlayerName : typed;
  }

  Future<void> _createRoom() async {
    final AppLocalizations loc = AppLocalizations.of(context);
    final String name = _resolvedName(loc);
    final int players = _players;
    final RoomToggles toggles = RoomToggles(
      blocks: _rulesBlocks,
      captureBonus: _rulesCaptureBonus,
    );
    final RoomController controller = widget.controllerFactory();
    _watchOwnedController(controller);
    // LobbyScreen/RoomRoute must not take a store dependency. Listen here
    // while create is in flight: connected + a room snapshot is a
    // successful create, and that is when last name/seats are recorded.
    bool recordedCreate = false;
    void persistSuccessfulCreate() {
      if (recordedCreate) {
        return;
      }
      if (controller.phase != RoomPhase.connected || controller.room == null) {
        return;
      }
      recordedCreate = true;
      unawaited(
        SessionMemory.recordSuccessfulCreate(name: name, seats: players),
      );
      if (mounted) {
        setState(() {
          _hasLastTable = true;
          _lastTableName = name;
          _lastTableSeats = players;
        });
      }
    }

    controller.addListener(persistSuccessfulCreate);
    persistSuccessfulCreate();
    final Object? result;
    try {
      result = await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RoomRoute(
            controller: controller,
            action: LobbyAction.create,
            playerName: name,
            players: players,
            toggles: toggles,
          ),
        ),
      );
    } finally {
      controller.removeListener(persistSuccessfulCreate);
    }
    // Rule 2 of order 080: LobbyScreen never disposes a controller it did
    // not create. This screen created it, so this screen retires it once
    // the player has walked away from the pushed route.
    //
    // leave() must run and complete before dispose(): dispose() tears the
    // connection down without telling the server, and the server treats a
    // dropped socket as a reconnect candidate rather than a released seat.
    // On a socket that already died, this can sit for up to the 10 second
    // request timeout before leave()'s own catch swallows it; that wait is
    // bounded and deliberate and is not visible to the player, since the
    // route has already popped by the time we get here.
    await _retireOwnedController(controller);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      await _createRoom();
    }
  }

  Future<void> _joinRoom() async {
    final AppLocalizations loc = AppLocalizations.of(context);
    final String normalized = normalizeRoomCode(_codeController.text);
    if (!isValidRoomCode(normalized)) {
      setState(() {
        _errorText = loc.homeRoomCodeInvalid;
      });
      return;
    }
    setState(() {
      _errorText = null;
    });
    final String name = _resolvedName(loc);
    final RoomController controller = widget.controllerFactory();
    _watchOwnedController(controller);
    // LobbyScreen/RoomRoute must not take a store dependency. Listen here
    // while join is in flight: connected + a room snapshot is a
    // successful join, and that is when the typed code is recorded.
    bool recordedJoin = false;
    void persistSuccessfulJoin() {
      if (recordedJoin) {
        return;
      }
      if (controller.phase != RoomPhase.connected || controller.room == null) {
        return;
      }
      recordedJoin = true;
      unawaited(SessionMemory.recordSuccessfulJoin(normalized));
      if (mounted) {
        setState(() {
          _recentCodes = SessionMemory.prependRecentCode(
            _recentCodes,
            normalized,
          );
        });
      }
    }

    controller.addListener(persistSuccessfulJoin);
    persistSuccessfulJoin();
    final Object? result;
    try {
      result = await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RoomRoute(
            controller: controller,
            action: LobbyAction.join,
            code: normalized,
            playerName: name,
          ),
        ),
      );
    } finally {
      controller.removeListener(persistSuccessfulJoin);
    }
    // See the matching comment in _createRoom: leave() must be awaited
    // before dispose() so a leave_room request actually reaches the wire,
    // and the up-to-10-second worst case on a dead socket is bounded and
    // deliberate, not a bug.
    await _retireOwnedController(controller);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      await _createRoom();
    }
  }

  /// H4: the H3 button's tap. Builds a controller the same way create and
  /// join do, watches it the same way, and pushes the same [RoomRoute],
  /// with [LobbyAction.resume] and [record] standing in for the code and
  /// players a create or join would otherwise carry. H1, on the controller
  /// this watches, is what records the seat again once the resume lands;
  /// nothing here writes [SessionMemory] directly.
  Future<void> _rejoinRoom(SeatRecord record) async {
    final AppLocalizations loc = AppLocalizations.of(context);
    final String name = _resolvedName(loc);
    final RoomController controller = widget.controllerFactory();
    _watchOwnedController(controller);
    final Object? result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomRoute(
          controller: controller,
          action: LobbyAction.resume,
          code: record.code,
          playerName: name,
          resume: record,
        ),
      ),
    );
    // See the matching comment in _createRoom: leave() must be awaited
    // before dispose() so a leave_room request actually reaches the wire,
    // and the up-to-10-second worst case on a dead socket is bounded and
    // deliberate, not a bug.
    await _retireOwnedController(controller);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      await _createRoom();
    }
  }

  /// Fills the code field from a recent-chip tap. Does not navigate;
  /// Join stays the next tap.
  void _fillCodeFromRecent(String code) {
    _codeController.text = code;
  }

  /// Primary action is [ElevatedButton]; the quieter twin is [OutlinedButton].
  Widget _weightedButton({
    required Key key,
    required VoidCallback onPressed,
    required String label,
    required Widget icon,
    required bool primary,
  }) {
    final Widget labelWidget = Text(label);
    if (primary) {
      return ElevatedButton.icon(
        key: key,
        onPressed: onPressed,
        icon: icon,
        label: labelWidget,
      );
    }
    return OutlinedButton.icon(
      key: key,
      onPressed: onPressed,
      icon: icon,
      label: labelWidget,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool joinPrimary = isValidRoomCode(
      normalizeRoomCode(_codeController.text),
    );
    final SeatRecord? seatRecord = _seatRecord;
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double viewHeight = MediaQuery.sizeOf(context).height;
    // Default widget-test surface is 800x600; keep create/join on-screen
    // there. Real phones are taller and get the stacked brand + die hero.
    final bool compact = viewHeight < 640;
    final double dieSize = dieMarkSize(compact);
    final double afterBrand = compact ? kSpace3 : kSpace6;
    final double afterDie = compact ? kSpace4 : kSpace7;

    final Animation<double> brandOpacity = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOutCubic),
    );
    final Animation<Offset> brandSlide =
        Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _enter,
            curve: const Interval(0.0, 0.45, curve: Curves.easeOutCubic),
          ),
        );
    final Animation<double> dieScale = Tween<double>(begin: 0.86, end: 1.0)
        .animate(
          CurvedAnimation(
            parent: _enter,
            curve: const Interval(0.15, 0.7, curve: Curves.easeOutBack),
          ),
        );
    final Animation<double> dieOpacity = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.1, 0.55, curve: Curves.easeOut),
    );
    final Animation<double> formOpacity = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
    );
    final Animation<Offset> formSlide =
        Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _enter,
            curve: const Interval(0.4, 1.0, curve: Curves.easeOutCubic),
          ),
        );

    final TextStyle? brandStyle = compact
        ? textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: LudoColors.ink,
            letterSpacing: -0.5,
            height: 1.05,
          )
        : textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: LudoColors.ink,
            letterSpacing: -0.5,
            height: 1.05,
          );

    return Scaffold(
      backgroundColor: LudoColors.paper,
      body: FeltBackdrop(
        // C-276 rule 1: no AppBar; the body's SafeArea keeps top: true
        // (the status bar inset is now the body's), while FeltBackdrop still
        // paints edge to edge.
        child: SafeArea(
          top: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  top: kSpace2,
                  end: kSpace2,
                ),
                child: Align(
                  alignment: AlignmentDirectional.topEnd,
                  child: TextButton(
                    key: const Key('locale-toggle-button'),
                    onPressed: widget.onToggleLocale,
                    style: TextButton.styleFrom(
                      backgroundColor: LudoColors.paperElevated,
                      foregroundColor: LudoColors.ink,
                      minimumSize: const Size(48, 48),
                      shape: StadiumBorder(
                        side: BorderSide(
                          color: LudoColors.inkMuted.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      side: BorderSide(
                        color: LudoColors.inkMuted.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Tooltip(
                      message: loc.homeLocaleToggleTooltip,
                      child: Text(loc.homeLocaleToggleLabel),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        kSpace6,
                        compact ? kSpace1 : kSpace2,
                        kSpace6,
                        compact ? kSpace5 : kSpace7,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FadeTransition(
                            opacity: brandOpacity,
                            child: SlideTransition(
                              position: brandSlide,
                              child: FadeTransition(
                                opacity: dieOpacity,
                                child: ScaleTransition(
                                  scale: dieScale,
                                  child: compact
                                      ? Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            DieMark(
                                              size: dieSize,
                                              semanticsLabel: loc.appTitle,
                                            ),
                                            const SizedBox(width: kSpace4),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    loc.appTitle,
                                                    style: brandStyle,
                                                  ),
                                                  const SizedBox(
                                                    height: kSpace1,
                                                  ),
                                                  Text(
                                                    loc.homeTagline,
                                                    style: textTheme.bodyMedium
                                                        ?.copyWith(
                                                          color: LudoColors
                                                              .inkMuted,
                                                          height: 1.3,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          children: [
                                            Text(
                                              loc.appTitle,
                                              textAlign: TextAlign.center,
                                              style: brandStyle,
                                            ),
                                            const SizedBox(height: kSpace2),
                                            Text(
                                              loc.homeTagline,
                                              textAlign: TextAlign.center,
                                              style: textTheme.bodyLarge
                                                  ?.copyWith(
                                                    color: LudoColors.inkMuted,
                                                    height: 1.35,
                                                  ),
                                            ),
                                            SizedBox(height: afterBrand),
                                            Center(
                                              child: DieMark(
                                                size: dieSize,
                                                semanticsLabel: loc.appTitle,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: afterDie),
                          FadeTransition(
                            opacity: formOpacity,
                            child: SlideTransition(
                              position: formSlide,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (seatRecord != null) ...[
                                    ElevatedButton.icon(
                                      key: const Key('home-rejoin-button'),
                                      onPressed: () => _rejoinRoom(seatRecord),
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                      ),
                                      label: Text(
                                        loc.homeRejoinButton(seatRecord.code),
                                      ),
                                    ),
                                    SizedBox(
                                      height: compact ? kSpace3 : kSpace5,
                                    ),
                                  ],
                                  Semantics(
                                    label: loc.homeNameFieldLabel,
                                    child:
                                        ValueListenableBuilder<
                                          TextEditingValue
                                        >(
                                          valueListenable: _nameController,
                                          builder: (context, nameValue, _) {
                                            final String trimmed = nameValue
                                                .text
                                                .trim();
                                            return TextField(
                                              key: const Key('home-name-field'),
                                              controller: _nameController,
                                              textAlign: TextAlign.center,
                                              textInputAction:
                                                  TextInputAction.go,
                                              onSubmitted: (_) {
                                                _createRoom();
                                              },
                                              style: textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                              decoration: InputDecoration(
                                                hintText:
                                                    loc.homeNameFieldLabel,
                                                filled: true,
                                                fillColor:
                                                    LudoColors.paperElevated,
                                                isDense: compact,
                                                border: OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                  borderSide: BorderSide.none,
                                                ),
                                                enabledBorder:
                                                    OutlineInputBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                      borderSide:
                                                          BorderSide.none,
                                                    ),
                                                focusedBorder:
                                                    OutlineInputBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                      borderSide:
                                                          const BorderSide(
                                                            color: LudoColors
                                                                .action,
                                                            width: 2,
                                                          ),
                                                    ),
                                                prefixIcon: CircleAvatar(
                                                  radius: 16,
                                                  backgroundColor:
                                                      LudoColors.action,
                                                  foregroundColor:
                                                      LudoColors.actionOn,
                                                  child: trimmed.isEmpty
                                                      ? const Icon(
                                                          Icons.person,
                                                          size: 20,
                                                          color: LudoColors
                                                              .actionOn,
                                                        )
                                                      : Text(
                                                          trimmed
                                                              .characters
                                                              .first
                                                              .toUpperCase(),
                                                          style: const TextStyle(
                                                            color: LudoColors
                                                                .actionOn,
                                                            fontWeight:
                                                                FontWeight.w600,
                                                          ),
                                                        ),
                                                ),
                                                suffixIcon: const Icon(
                                                  Icons.edit_outlined,
                                                  color: LudoColors.inkMuted,
                                                  size: 20,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                  ),
                                  SizedBox(height: compact ? kSpace3 : kSpace5),
                                  if (!_playersSelectorOpen)
                                    Center(
                                      child: TextButton.icon(
                                        key: const Key(
                                          'home-players-disclosure',
                                        ),
                                        onPressed: () {
                                          setState(
                                            () => _playersSelectorOpen = true,
                                          );
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                                if (!mounted) {
                                                  return;
                                                }
                                                _scrollCreateButtonIntoView();
                                              });
                                        },
                                        style: TextButton.styleFrom(
                                          foregroundColor: LudoColors.inkMuted,
                                          minimumSize: const Size(48, 48),
                                          shape: StadiumBorder(
                                            side: BorderSide(
                                              color: LudoColors.inkMuted
                                                  .withValues(alpha: 0.4),
                                              width: 1,
                                            ),
                                          ),
                                          side: BorderSide(
                                            color: LudoColors.inkMuted
                                                .withValues(alpha: 0.4),
                                            width: 1,
                                          ),
                                        ),
                                        icon: const Icon(Icons.tune),
                                        label: Text(
                                          loc.homePlayersDisclosureClosed,
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    )
                                  else ...[
                                    Text(
                                      loc.homePlayersSelectorLabel,
                                      textAlign: TextAlign.center,
                                      style: textTheme.labelLarge?.copyWith(
                                        color: LudoColors.inkMuted,
                                      ),
                                    ),
                                    const SizedBox(height: kSpace2),
                                    _PlayersSelector(
                                      key: const Key('home-players-selector'),
                                      value: _players,
                                      onChanged: (value) =>
                                          setState(() => _players = value),
                                    ),
                                    SizedBox(
                                      height: compact ? kSpace2 : kSpace3,
                                    ),
                                    IntrinsicHeight(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(
                                            child: HomeRuleToggle(
                                              key: const Key(
                                                'home-rule-blocks',
                                              ),
                                              value: _rulesBlocks,
                                              onChanged: (value) => setState(
                                                () => _rulesBlocks = value,
                                              ),
                                              icon: Icons.shield_outlined,
                                              title: loc.homeRuleBlocks,
                                              hint: loc.homeRuleBlocksHint,
                                            ),
                                          ),
                                          const SizedBox(width: kSpace3),
                                          Expanded(
                                            child: HomeRuleToggle(
                                              key: const Key(
                                                'home-rule-capture-bonus',
                                              ),
                                              value: _rulesCaptureBonus,
                                              onChanged: (value) => setState(
                                                () =>
                                                    _rulesCaptureBonus = value,
                                              ),
                                              icon: Icons.replay_rounded,
                                              title: loc.homeRuleCaptureBonus,
                                              hint:
                                                  loc.homeRuleCaptureBonusHint,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  if (_hasLastTable &&
                                      _lastTableName != null &&
                                      _lastTableSeats != null) ...[
                                    SizedBox(
                                      height: compact ? kSpace3 : kSpace4,
                                    ),
                                    _LastTableChip(
                                      name: _lastTableName!,
                                      seats: _lastTableSeats!,
                                    ),
                                  ],
                                  SizedBox(height: compact ? kSpace3 : kSpace6),
                                  KeyedSubtree(
                                    key: _createButtonScrollKey,
                                    child: _weightedButton(
                                      key: const Key('create-room-button'),
                                      onPressed: _createRoom,
                                      label: loc.homeCreateRoomButton,
                                      icon: const Icon(Icons.add_rounded),
                                      primary: !joinPrimary,
                                    ),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: compact ? kSpace1 : kSpace2,
                                    ),
                                    child: Row(
                                      key: const Key('home-join-divider'),
                                      children: [
                                        Expanded(
                                          child: Container(
                                            height: 1,
                                            color: LudoColors.inkMuted
                                                .withValues(alpha: 0.3),
                                          ),
                                        ),
                                        Flexible(
                                          flex: 3,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: kSpace3,
                                            ),
                                            child: Text(
                                              loc.homeJoinDivider,
                                              textAlign: TextAlign.center,
                                              style: textTheme.labelMedium
                                                  ?.copyWith(
                                                    color: LudoColors.inkMuted,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Container(
                                            height: 1,
                                            color: LudoColors.inkMuted
                                                .withValues(alpha: 0.3),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  KeyedSubtree(
                                    key: _codeFieldScrollKey,
                                    child: Semantics(
                                      label: loc.homeRoomCodeFieldLabel,
                                      child: TextField(
                                        key: const Key('room-code-field'),
                                        controller: _codeController,
                                        textAlign: TextAlign.center,
                                        textCapitalization:
                                            TextCapitalization.characters,
                                        textInputAction: TextInputAction.go,
                                        onSubmitted: (_) {
                                          if (joinPrimary) {
                                            _joinRoom();
                                          }
                                        },
                                        inputFormatters:
                                            const <TextInputFormatter>[
                                              _RoomCodeInputFormatter(),
                                            ],
                                        style: textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 4,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: loc.homeRoomCodeFieldLabel,
                                          hintStyle: textTheme.bodyLarge
                                              ?.copyWith(
                                                color: LudoColors.inkMuted,
                                              ),
                                          helperText: loc.homeRoomCodeFieldHint,
                                          errorText: _errorText,
                                          // Unset, InputDecoration truncates errorText
                                          // to one line with an ellipsis.
                                          // homeRoomCodeInvalid needs four lines to
                                          // clear at this field's width in either
                                          // locale.
                                          errorMaxLines: 4,
                                          filled: true,
                                          fillColor: LudoColors.paperElevated,
                                          isDense: compact,
                                          prefixIcon: const Icon(
                                            Icons.tag,
                                            color: LudoColors.inkMuted,
                                          ),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              kRadiusControl,
                                            ),
                                            borderSide: BorderSide.none,
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              kRadiusControl,
                                            ),
                                            borderSide: BorderSide.none,
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              kRadiusControl,
                                            ),
                                            borderSide: const BorderSide(
                                              color: LudoColors.action,
                                              width: 2,
                                            ),
                                          ),
                                          errorBorder: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              kRadiusControl,
                                            ),
                                            borderSide: const BorderSide(
                                              color: LudoColors.error,
                                              width: 2,
                                            ),
                                          ),
                                          focusedErrorBorder:
                                              OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      kRadiusControl,
                                                    ),
                                                borderSide: const BorderSide(
                                                  color: LudoColors.error,
                                                  width: 2,
                                                ),
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: compact ? kSpace2 : kSpace3),
                                  KeyedSubtree(
                                    key: _joinButtonScrollKey,
                                    child: _weightedButton(
                                      key: const Key('join-room-button'),
                                      onPressed: _joinRoom,
                                      label: loc.homeJoinRoomButton,
                                      icon: const DirectionalIcon(
                                        Icons.login_rounded,
                                      ),
                                      primary: joinPrimary,
                                    ),
                                  ),
                                  if (_recentCodes.isNotEmpty) ...[
                                    SizedBox(
                                      height: compact ? kSpace2 : kSpace3,
                                    ),
                                    _RecentCodes(
                                      codes: _recentCodes,
                                      onSelect: _fillCodeFromRecent,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Strips spaces/dashes and upper-cases as the player types or pastes, so
/// the field shows the same form [normalizeRoomCode] will send on Join.
/// Selection offsets are mapped through the stripped prefix so the caret
/// does not jump to the end.
class _RoomCodeInputFormatter extends TextInputFormatter {
  const _RoomCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String normalized = normalizeRoomCode(newValue.text);
    if (normalized == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: normalized,
      selection: TextSelection(
        baseOffset: _offset(newValue.text, newValue.selection.baseOffset),
        extentOffset: _offset(newValue.text, newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
    );
  }

  /// Maps [offset] in [raw] onto the normalised string.
  static int _offset(String raw, int offset) {
    if (offset <= 0) {
      return offset;
    }
    final int end = offset < raw.length ? offset : raw.length;
    return normalizeRoomCode(raw.substring(0, end)).length;
  }
}

/// Last successful table, shown when [SessionMemory.hasLastTable] is true.
/// Visual weight stays below Create (muted paper, not action fill) so
/// Create still outweighs Join with the chip on screen.
class _LastTableChip extends StatelessWidget {
  const _LastTableChip({required this.name, required this.seats});

  final String name;
  final int seats;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String seatsLabel = switch (seats) {
      2 => loc.homePlayersTwo,
      3 => loc.homePlayersThree,
      _ => loc.homePlayersFour,
    };
    final String label = '$name · $seatsLabel';
    return Center(
      child: Semantics(
        container: true,
        label: label,
        child: DecoratedBox(
          key: const Key('home-last-table-chip'),
          decoration: BoxDecoration(
            // Informational, not tappable: wash fill and a lighter felt
            // edge so this chip cannot be mistaken for a recent-code pill.
            color: LudoColors.paperWashTop,
            borderRadius: BorderRadius.circular(kRadiusControl),
            border: Border.all(color: LudoColors.feltLight),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: kSpace3,
              vertical: kSpace2,
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: textTheme.labelLarge?.copyWith(
                color: LudoColors.ink,
                fontSize: kTypeLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Recent successful join codes, shown under Join when the store has any.
/// Visual weight stays below Join (muted paper, not action fill) so a chip
/// tap fills the field and Join remains the next tap.
class _RecentCodes extends StatelessWidget {
  const _RecentCodes({required this.codes, required this.onSelect});

  final List<String> codes;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('home-recent-codes'),
      alignment: WrapAlignment.center,
      spacing: kSpace2,
      runSpacing: kSpace2,
      children: [
        for (final String code in codes)
          _RecentCodeChip(code: code, onPressed: () => onSelect(code)),
      ],
    );
  }
}

/// One recent room code. Tapping fills [HomeScreen]'s code field only.
class _RecentCodeChip extends StatelessWidget {
  const _RecentCodeChip({required this.code, required this.onPressed});

  final String code;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: code,
      child: IntrinsicWidth(
        child: Material(
          color: LudoColors.paperElevated,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusControl),
            side: const BorderSide(color: LudoColors.feltMid),
          ),
          child: InkWell(
            key: Key('home-recent-code-$code'),
            onTap: onPressed,
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusControl),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: kSpace3,
                  vertical: kSpace2,
                ),
                child: Align(
                  alignment: Alignment.center,
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    code,
                    textAlign: TextAlign.center,
                    style: textTheme.labelLarge?.copyWith(
                      color: LudoColors.ink,
                      fontSize: kTypeLabel,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The 2/3/4 seat-count selector on the home screen. A separate widget
/// rather than inline builder code so the key required on it sits on the
/// one widget that represents the whole control, not on whichever segment
/// happens to be first.
class _PlayersSelector extends StatelessWidget {
  const _PlayersSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return SegmentedButton<int>(
      // SegmentedButton defaults showSelectedIcon to true, which draws a
      // leading check inside the selected segment only. That icon and its
      // gap come out of the same fixed segment width the label has to fit
      // in, so whichever segment is selected loses width the other two
      // keep, and its label wraps where theirs does not (work/ludo/orders/
      // 146-players-selector-wrap.md). Turning the icon off gives every
      // segment the same width regardless of selection, instead of shrinking
      // or truncating the label to fit the width the icon left behind.
      // Selection stays visible without it: segmentedButtonTheme
      // (lib/src/theme.dart) already paints the selected segment with its
      // own container colour and foreground colour by WidgetState.selected,
      // independently of the icon.
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: 2, label: Text(loc.homePlayersTwo)),
        ButtonSegment(value: 3, label: Text(loc.homePlayersThree)),
        ButtonSegment(value: 4, label: Text(loc.homePlayersFour)),
      ],
      selected: <int>{value},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// C-276 rule 3: toggle card for a game rule (Blocks, Capture bonus) on the
/// home screen, matching the lobby screen rule chips instead of a settings
/// page switch. Off state displays a diagonal strike over the icon and
/// removes the check badge (doctrine P9).
class HomeRuleToggle extends StatelessWidget {
  const HomeRuleToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.icon,
    required this.title,
    required this.hint,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool disableAnimations = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      button: true,
      toggled: value,
      label: title,
      hint: hint,
      excludeSemantics: true,
      // The InkWell's own tap action is excluded with the children, so the
      // node carries it, or TalkBack's double tap would do nothing.
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: value
              ? LudoColors.action.withValues(alpha: 0.12)
              : LudoColors.inkMuted.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(kRadiusControl),
          border: Border.all(
            color: value
                ? LudoColors.action
                : LudoColors.inkMuted.withValues(alpha: 0.4),
            width: value ? 2 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadiusControl),
            onTap: () => onChanged(!value),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(kSpace3),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: kSpace6,
                            height: kSpace6,
                            child: value
                                ? Icon(
                                    icon,
                                    size: kSpace6,
                                    color: LudoColors.action,
                                  )
                                : Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Icon(
                                        icon,
                                        size: kSpace6,
                                        color: LudoColors.inkMuted,
                                      ),
                                      CustomPaint(
                                        size: const Size(kSpace6, kSpace6),
                                        painter: const RuleOffStrikePainter(
                                          color: LudoColors.inkMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                          const SizedBox(height: kSpace2),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: textTheme.labelLarge?.copyWith(
                              color: LudoColors.ink,
                            ),
                          ),
                          const SizedBox(height: kSpace1),
                          Text(
                            hint,
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall?.copyWith(
                              color: LudoColors.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (value)
                    PositionedDirectional(
                      top: kSpace2,
                      end: kSpace2,
                      child: const IgnorePointer(
                        child: Icon(
                          Icons.check_circle,
                          size: kSpace5,
                          color: LudoColors.action,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
