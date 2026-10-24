import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'deep_link.dart';
import 'die_mark.dart';
import 'directional_icon.dart';
import 'feedback_settings_sheet.dart';
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
import 'verify_rolls_button.dart';

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
    this.clock,
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

  /// C-322 rule 2: the "now" a finished game is recorded at, and rule 4's
  /// 90-day window is measured against the same clock, so a test can
  /// inject a fixed time instead of depending on the wall clock.
  /// Null means the wall clock.
  final DateTime Function()? clock;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  String? _errorText;
  bool _removedNotice = false;
  // C-447 D4: shown in the same slot as [_removedNotice] after a resume the
  // server refused (the room was reaped or the seat taken back).
  bool _gameGoneNotice = false;
  // C-447 D3: the one automatic resume this screen state ever starts.
  bool _autoResumeStarted = false;
  // C-447 D3b: the initial link reader has answered (a link, null or an
  // error), so a cold link has had its say before the stored seat resumes.
  bool _initialLinkSettled = false;
  // C-447 D3b: a valid room link was decided by this screen, whichever path
  // delivered it; the link then wins and the stored seat does not resume.
  bool _linkHadSay = false;
  // C-447 D3b: the stored seat waiting for the reader, with the bound that
  // stops the wait (the same 500 ms as the link hold, measured from the
  // moment the session-memory load completed).
  SessionMemory? _autoResumeWaiting;
  Timer? _autoResumeTimer;
  int _players = 4;
  bool _playersSelectorOpen = false;
  bool _rulesCaptureBonus = true;
  String? _nameLocaleDefault;
  StreamSubscription<Uri>? _linkSubscription;
  late final AnimationController _enter;
  bool _enterMotionArmed = false;
  bool _hasLastTable = false;
  // A stored non-empty name, with or without a seat count. The link gate
  // reads this. The last-table chip still reads [_hasLastTable].
  bool _hasStoredName = false;
  String? _lastTableName;
  int? _lastTableSeats;
  List<String> _recentCodes = const <String>[];
  RoomController? _ownedController;
  // H3: the seat rejoin button shows exactly when this is non-null. Only
  // ever set from _restoreSessionMemory's one-time load and cleared by H2.
  SeatRecord? _seatRecord;
  // C-322 rule 3: home-last-game shows exactly when this is non-null and
  // not yet past rule 4's window. Set from _restoreSessionMemory's one-time
  // load, and again by _maybeRecordLastGame the moment a finished game is
  // observed, so the entry is there the instant the game route pops.
  LastGame? _lastGame;
  // C-322 rule 2's own dedupe, independent of which controller is owned:
  // the gameId of the last LastGame this screen itself wrote, so a second
  // controller later observing the same already-recorded game (a resumed
  // finished room, say) never overwrites a true finishedAt with a later
  // one. Seeded from storage on restore, not reset per controller.
  String? _lastGameWrittenId;
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
  // C-398: focusing the code field brings join-room-button up with it,
  // the same pair the room-link scroll already moves together.
  final FocusNode _codeFocusNode = FocusNode();
  double _codeFocusInset = -1;
  // Set as the first line of dispose(), before anything else runs.
  // _retireOwnedController's own setState guard reads this alongside
  // `mounted`, synchronously true from the top of dispose() rather than
  // depending on the framework's own unmount bookkeeping.
  bool _screenDisposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _codeController.addListener(_clearErrorOnEdit);
    _codeFocusNode.addListener(_onCodeFieldFocus);
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
          _settleInitialLink();
        },
        onError: (Object error, StackTrace stackTrace) {
          _reportLinkError(error, stackTrace, 'reading the initial link');
          _settleInitialLink();
        },
      );
    } catch (error, stackTrace) {
      _reportLinkError(error, stackTrace, 'reading the initial link');
      _initialLinkSettled = true;
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
  /// joins or rejoins the room when Home is the current route (order 296,
  /// C-394).
  ///
  /// A stored seat for that same code resumes, whether or not a name is
  /// stored. Otherwise a stored, non-empty name joins with that name.
  ///
  /// Navigation does not happen and the code is only pre-filled when the
  /// player is first-time (no stored name and no matching seat, so Join
  /// remains their tap), when another route (a lobby, a game) is currently
  /// pushed above Home (rule B5), or when the code is invalid.
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
  /// room or should leave the code filled in place (order 296, C-394).
  ///
  /// The seat-record check stands on its own, ahead of the stored-name
  /// check: resume needs no name, and neither check is the last-table chip.
  void _decideLinkAction(String code) {
    if (!mounted) {
      return;
    }
    _linkHadSay = true;
    final bool isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
    if (isCurrent && !_linkJoinInFlight) {
      final SeatRecord? record = _seatRecord;
      if (record != null && record.code == code) {
        unawaited(_joinFromLink(rejoin: true, seatRecord: record));
        return;
      }
      if (_hasStoredName) {
        unawaited(_joinFromLink(rejoin: false));
        return;
      }
    }
    // Run 57: first-time player (rule 2) or home screen sitting underneath
    // an existing route (rule 3) scrolls the target into view rather than
    // navigating. A join already in flight takes this path too (rule 6).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _scrollLinkTargetIntoView(codeIsValid: true);
    });
  }

  /// Resolves any pending link held while session memory was loading
  /// (rule 5). Returns true when a link with a valid code was decided, so
  /// the caller knows the link, not the stored seat, has the say on what
  /// Home does next (C-447 D3).
  bool _drainPendingLink() {
    _linkHoldTimer?.cancel();
    _linkHoldTimer = null;
    final Uri? uri = _pendingLinkUri;
    _pendingLinkUri = null;
    if (uri == null) {
      return false;
    }
    final String? code = roomCodeFromUri(uri);
    if (code == null) {
      return false;
    }
    _decideLinkAction(code);
    return true;
  }

  /// C-447 D3: starts the resume a tap on `home-rejoin-button` would start,
  /// once, when the stored seat is fresh. Called only from the completion of
  /// the session-memory load, after the pending link had its turn. Does
  /// nothing when a link was decided in that completion (a link for the same
  /// code made its own rejoin, a link for another code wins and leaves the
  /// button), when Home is not the current route, or when a link join is
  /// already in flight.
  void _maybeAutoResume(SeatRecord? record, DateTime? savedAt) {
    if (record == null || savedAt == null || _autoResumeStarted) {
      return;
    }
    if (!mounted || _linkJoinInFlight || _linkHadSay) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    _autoResumeStarted = true;
    unawaited(_rejoinRoom(record));
  }

  /// C-447 D3b: the initial link reader answered. Any link it returned has
  /// already been handled by the caller, so a stored seat that was waiting
  /// for the reader may now decide.
  void _settleInitialLink() {
    _initialLinkSettled = true;
    _finishAutoResumeWait();
  }

  /// C-447 D3b: ends the wait for the initial link reader, because it
  /// answered or because 500 ms passed since the load completed, and runs
  /// the one auto-resume decision.
  void _finishAutoResumeWait() {
    final SessionMemory? memory = _autoResumeWaiting;
    if (memory == null) {
      return;
    }
    _autoResumeWaiting = null;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _maybeAutoResume(memory.seatRecord, memory.seatSavedAt);
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
        await _joinRoom(fromLink: true);
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

  void _onCodeFieldFocus() {
    if (!_codeFocusNode.hasFocus) {
      return;
    }
    _scrollJoinIntoViewWithField();
  }

  /// Brings join-room-button fully into the viewport when the code field
  /// has focus, including after the keyboard shrinks that viewport. Leaves
  /// a button that is already visible where it is, so a tap in the field
  /// on a roomy screen does not jump the scroll.
  void _scrollJoinIntoViewWithField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_codeFocusNode.hasFocus) {
        return;
      }
      final BuildContext? targetContext = _joinButtonScrollKey.currentContext;
      if (targetContext == null) {
        return;
      }
      final bool reducedMotion = MediaQuery.disableAnimationsOf(context);
      Scrollable.ensureVisible(
        targetContext,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: reducedMotion ? Duration.zero : kLinkScrollDuration,
        curve: Curves.easeOut,
      );
    });
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

  /// Restores a stored name (from a create or a join), last successful-create
  /// seats, the last-table chip, recent join codes, a seat record held
  /// across a process kill (H3), and the last finished game's verify link
  /// (C-322 rule 3) from [SessionMemory]. An empty or unreadable store
  /// leaves the localised name default, the four-seat disclosure, no recent
  /// chips, no rejoin button and no home-last-game entry as they are. The
  /// load itself returns empty on failure, so nothing is caught here.
  /// Completing the load marks session memory as loaded, drains any
  /// pending room link (order 296) and, when no link was decided and the
  /// stored seat is fresh, resumes it on its own once (C-447 D3). A stored name fills the name field on
  /// its own; the last-table chip still requires a seat count too.
  Future<void> _restoreSessionMemory() async {
    SessionMemory? memory;
    try {
      final SessionMemory loaded = await SessionMemory.load(
        clock: widget.clock,
      );
      memory = loaded;
      if (!mounted) {
        return;
      }
      final bool hasTable = loaded.hasLastTable;
      final bool hasCodes = loaded.recentCodes.isNotEmpty;
      final SeatRecord? seatRecord = loaded.seatRecord;
      final LastGame? lastGame = loaded.lastGame;
      final String? storedName = loaded.lastName;
      final bool hasStoredName = storedName != null && storedName.isNotEmpty;
      if (lastGame != null) {
        // C-322 rule 2's dedupe is per screen life, not per load: seed it
        // here so a controller later observing this same already-recorded
        // game never overwrites its true finishedAt with a later one.
        _lastGameWrittenId = lastGame.gameId;
      }
      if (hasTable ||
          hasCodes ||
          seatRecord != null ||
          lastGame != null ||
          hasStoredName) {
        setState(() {
          if (hasCodes) {
            _recentCodes = List<String>.from(loaded.recentCodes);
          }
          if (storedName != null && storedName.isNotEmpty) {
            _hasStoredName = true;
            _nameController.text = storedName;
          }
          if (hasTable) {
            final String name = loaded.lastName!;
            final int seats = loaded.lastSeats!;
            _hasLastTable = true;
            _lastTableName = name;
            _lastTableSeats = seats;
            _nameController.text = name;
            _players = seats;
          }
          if (seatRecord != null) {
            _seatRecord = seatRecord;
          }
          if (lastGame != null) {
            _lastGame = lastGame;
          }
        });
      }
    } finally {
      _linkHoldTimer?.cancel();
      _linkHoldTimer = null;
      _sessionMemoryLoaded = true;
      if (mounted) {
        final bool linkDecided = _drainPendingLink();
        if (!linkDecided && memory != null) {
          if (_initialLinkSettled) {
            _maybeAutoResume(memory.seatRecord, memory.seatSavedAt);
          } else {
            // D3b: the reader has not answered yet. Wait for it, bounded.
            _autoResumeWaiting = memory;
            _autoResumeTimer = Timer(
              const Duration(milliseconds: 500),
              _finishAutoResumeWait,
            );
          }
        }
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
    final double inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset != _codeFocusInset) {
      final bool grew = inset > _codeFocusInset;
      _codeFocusInset = inset;
      if (grew && _codeFocusNode.hasFocus) {
        _scrollJoinIntoViewWithField();
      }
    }
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
    _screenDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _linkHoldTimer?.cancel();
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoResumeWaiting = null;
    _codeController.removeListener(_clearErrorOnEdit);
    _codeFocusNode.removeListener(_onCodeFieldFocus);
    _codeFocusNode.dispose();
    _codeController.dispose();
    _nameController.dispose();
    _enter.dispose();
    _pendingLinkUri = null;
    final RoomController? owned = _ownedController;
    _ownedController = null;
    // H1/H2: this screen's own life is the other end of the "as long as
    // HomeScreen owns a controller" window; stop watching before it goes.
    owned?.removeListener(_onOwnedControllerChanged);
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
    _maybeRecordLastGame(controller);
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
          unawaited(SessionMemory.recordSeat(record, clock: widget.clock));
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

  /// C-322 rule 2: the finished snapshot F is [controller]'s own room when
  /// it is FINISHED, otherwise [RoomController.lastFinished] when the room
  /// has already moved on to a rematch LOBBY. The moment F carries a
  /// gameId, a non-empty verifyUrl on the http(s) scheme, and that gameId
  /// is not the one this screen already wrote, the verify link is kept so
  /// home can show it after the route pops -- without a reload, since the
  /// screen's own copy is set in the same [setState]. Only the four
  /// [LastGame] fields are kept; nothing else about the game (names,
  /// stats) is persisted here.
  void _maybeRecordLastGame(RoomController controller) {
    final RoomSnapshot? room = controller.room;
    RoomSnapshot? finished;
    if (room != null && room.state == RoomState.finished) {
      finished = room;
    } else if (room != null &&
        room.state == RoomState.lobby &&
        room.rematch != null) {
      finished = controller.lastFinished;
    }
    if (finished == null) {
      return;
    }
    final String? gameId = finished.gameId;
    final String? verifyUrl = finished.verifyUrl;
    if (gameId == null || verifyUrl == null || verifyUrl.isEmpty) {
      return;
    }
    if (gameId == _lastGameWrittenId) {
      return;
    }
    final Uri? uri = Uri.tryParse(verifyUrl);
    if (uri == null || (!uri.isScheme('https') && !uri.isScheme('http'))) {
      return;
    }
    _lastGameWrittenId = gameId;
    final LastGame game = LastGame(
      gameId: gameId,
      verifyUrl: verifyUrl,
      finishedAt: (widget.clock ?? DateTime.now)(),
      won: finished.winner == controller.seat,
    );
    unawaited(SessionMemory.recordLastGame(game));
    if (mounted) {
      setState(() {
        _lastGame = game;
      });
    }
  }

  /// C-322 rule 4: home-last-game shows a held [LastGame] only while it is
  /// no older than [kVerifyRetention] by [widget.clock]'s "now". The record
  /// itself is left in storage past the window; only the home entry hides.
  bool get _showLastGame {
    final LastGame? game = _lastGame;
    if (game == null) {
      return false;
    }
    final DateTime now = (widget.clock ?? DateTime.now)();
    final DateTime expiry = game.finishedAt.add(kVerifyRetention);
    return !expiry.isBefore(now);
  }

  /// C-322 rule 5: opens the remembered game's verify link the same way the
  /// end card's own verify button does -- the real `url_launcher` plugin,
  /// no wrapper -- so this entry is observable on the same method channel.
  /// Never sends a frame and never opens a room: this is a meta action on a
  /// game that is already over.
  Future<void> _openLastGameVerifyUrl() async {
    final LastGame? game = _lastGame;
    if (game == null) {
      return;
    }
    final Uri? uri = Uri.tryParse(game.verifyUrl);
    if (uri == null || (!uri.isScheme('https') && !uri.isScheme('http'))) {
      _showLastGameVerifyOpenFailed();
      return;
    }
    bool opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      opened = false;
    } on ArgumentError {
      opened = false;
    }
    if (!opened && mounted) {
      _showLastGameVerifyOpenFailed();
    }
  }

  void _showLastGameVerifyOpenFailed() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).gameVerifyOpenFailed),
      ),
    );
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
    // `_screenDisposed` is set synchronously at the top of dispose(), ahead
    // of the framework's own unmount bookkeeping that `mounted` reads; kept
    // here alongside `mounted` as the stricter of the two checks.
    if (!_screenDisposed && mounted) {
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

  /// D2 of C-449: the player closes the notice by hand. Every other event
  /// that hides it (create, join, rejoin) is handled where it starts.
  void _dismissNotice() {
    setState(() {
      _removedNotice = false;
      _gameGoneNotice = false;
    });
  }

  Future<void> _createRoom() async {
    if (_removedNotice || _gameGoneNotice) {
      setState(() {
        _removedNotice = false;
        _gameGoneNotice = false;
      });
    }
    final AppLocalizations loc = AppLocalizations.of(context);
    final String name = _resolvedName(loc);
    final int players = _players;
    final RoomToggles toggles = RoomToggles(captureBonus: _rulesCaptureBonus);
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
          _hasStoredName = true;
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
    // C-316 rule 3: a removed player must see home-removed-notice as soon
    // as the route returns, not after the controller has retired. Set the
    // notice here, before the retire below, which can sit for up to the
    // 10 second request timeout on a dead socket.
    if (result == GameScreenResult.removed && mounted) {
      setState(() {
        _removedNotice = true;
        _gameGoneNotice = false;
      });
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

  /// [fromLink] is true only for a join a room link started: the lobby then
  /// words a vanished room in the link's terms and offers no retry (C-447
  /// D4b). A join from a typed code leaves it false.
  Future<void> _joinRoom({bool fromLink = false}) async {
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
      _removedNotice = false;
      _gameGoneNotice = false;
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
      unawaited(SessionMemory.recordSuccessfulJoin(normalized, name: name));
      if (mounted) {
        setState(() {
          _hasStoredName = true;
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
            fromLink: fromLink,
          ),
        ),
      );
    } finally {
      controller.removeListener(persistSuccessfulJoin);
    }
    // C-316 rule 3: set the notice before the retire below; see the
    // matching comment in _createRoom.
    if (result == GameScreenResult.removed && mounted) {
      setState(() {
        _removedNotice = true;
        _gameGoneNotice = false;
      });
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
    if (_removedNotice || _gameGoneNotice) {
      setState(() {
        _removedNotice = false;
        _gameGoneNotice = false;
      });
    }
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
    // C-447 D4: a resume the server refused (room reaped, seat taken back)
    // goes home with its own true line, set before the retire like the
    // removed notice in _createRoom.
    if (result == GameScreenResult.gameGone && mounted) {
      setState(() {
        _gameGoneNotice = true;
        _removedNotice = false;
      });
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
    } else if (result == GameScreenResult.removed) {
      setState(() {
        _removedNotice = true;
        _gameGoneNotice = false;
      });
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
    final MediaQueryData media = MediaQuery.of(context);
    // C-398: compact is the height inside the safe area, not the raw screen
    // height. The 800x600 widget-test surface stays compact (600 < 640).
    // A 640-tall phone with a status bar and a nav bar is short once those
    // insets are subtracted. The threshold stays 640.
    final double safeHeight =
        media.size.height - media.padding.top - media.padding.bottom;
    // Die size flips at 640 (C-398). The stacked hero needs more than that
    // before the join step still fits at text scale 1.3, so a safe height
    // under 800 keeps the side-by-side hero and only the die grows.
    final bool compact = safeHeight < 640;
    final bool stackedHero = safeHeight >= 800;
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: const Key('home-settings-button'),
                        onPressed: () => showFeedbackSettingsSheet(context),
                        style: IconButton.styleFrom(
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
                        tooltip: loc.settingsTooltip,
                        icon: const Icon(Icons.tune_rounded),
                      ),
                      const SizedBox(width: kSpace2),
                      TextButton(
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
                    ],
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
                                  child: !stackedHero
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
                                  if (_removedNotice || _gameGoneNotice) ...[
                                    _HomeNotice(
                                      cardKey: const Key('home-notice'),
                                      textKey: _gameGoneNotice
                                          ? const Key('home-game-gone-notice')
                                          : const Key('home-removed-notice'),
                                      text: _gameGoneNotice
                                          ? loc.homeGameGoneNotice
                                          : loc.homeRemovedNotice,
                                      dismissLabel: loc.homeNoticeDismiss,
                                      onDismiss: _dismissNotice,
                                    ),
                                    SizedBox(
                                      height: compact ? kSpace3 : kSpace4,
                                    ),
                                  ],
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
                                    HomeRuleToggle(
                                      key: const Key('home-rule-capture-bonus'),
                                      value: _rulesCaptureBonus,
                                      onChanged: (value) => setState(
                                        () => _rulesCaptureBonus = value,
                                      ),
                                      icon: Icons.replay_rounded,
                                      title: loc.homeRuleCaptureBonus,
                                      hint: loc.homeRuleCaptureBonusHint,
                                    ),
                                    SizedBox(
                                      height: compact ? kSpace2 : kSpace3,
                                    ),
                                    Text(
                                      loc.houseRulesLine,
                                      key: const Key('home-house-rules'),
                                      textAlign: TextAlign.center,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: LudoColors.inkMuted,
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
                                        focusNode: _codeFocusNode,
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
                                  if (_showLastGame) ...[
                                    SizedBox(
                                      height: compact ? kSpace3 : kSpace4,
                                    ),
                                    _LastGameEntry(
                                      game: _lastGame!,
                                      onCheck: _openLastGameVerifyUrl,
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

/// C-449 D1-D3: the one surface every Home notice renders in. A tinted card
/// with a leading info icon and a trailing close control, ink text at body
/// size. Directional padding and a plain [Row] mean it mirrors in Arabic
/// without any locale branch: the icon sits at the start edge, the close
/// control at the end edge. The text wraps at large text scales.
class _HomeNotice extends StatefulWidget {
  const _HomeNotice({
    required this.cardKey,
    required this.textKey,
    required this.text,
    required this.dismissLabel,
    required this.onDismiss,
  });

  final Key cardKey;
  final Key textKey;
  final String text;
  final String dismissLabel;
  final VoidCallback onDismiss;

  @override
  State<_HomeNotice> createState() => _HomeNoticeState();
}

class _HomeNoticeState extends State<_HomeNotice> {
  @override
  void initState() {
    super.initState();
    // At a large text scale the title block can fill the screen and push the
    // card below the fold, where the player cannot learn why they are here.
    // C-449 D1b: scroll only when some part of the card is outside the
    // viewport, by the least distance that shows all of it, and never by a
    // jump. A card that is already fully visible leaves the offset alone.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealIfNeeded());
  }

  void _revealIfNeeded() {
    if (!mounted) {
      return;
    }
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    final RenderObject? object = context.findRenderObject();
    if (scrollable == null || object == null || !object.attached) {
      return;
    }
    final RenderAbstractViewport? viewport = RenderAbstractViewport.maybeOf(
      object,
    );
    if (viewport == null) {
      return;
    }
    final ScrollPosition position = scrollable.position;
    // Offsets at which the card's start edge sits on the viewport's start edge
    // and its end edge sits on the viewport's end edge. The card is fully
    // visible exactly when the current offset lies between the two.
    final double atStart = viewport.getOffsetToReveal(object, 0.0).offset;
    final double atEnd = viewport.getOffsetToReveal(object, 1.0).offset;
    const double slack = 0.5;
    final double pixels = position.pixels;
    final ScrollPositionAlignmentPolicy? policy;
    if (pixels > atStart + slack) {
      policy = ScrollPositionAlignmentPolicy.keepVisibleAtStart;
    } else if (pixels < atEnd - slack) {
      policy = ScrollPositionAlignmentPolicy.keepVisibleAtEnd;
    } else {
      policy = null;
    }
    if (policy == null) {
      return;
    }
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    position.ensureVisible(
      object,
      alignmentPolicy: policy,
      duration: reduce ? Duration.zero : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool disableAnimations = MediaQuery.disableAnimationsOf(context);
    final Widget card = DecoratedBox(
      key: widget.cardKey,
      decoration: BoxDecoration(
        color: LudoColors.paperWashTop,
        borderRadius: BorderRadius.circular(kRadiusControl),
        border: Border.all(color: LudoColors.feltLight),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: kSpace3,
          top: kSpace1,
          bottom: kSpace1,
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: LudoColors.ink,
              size: 24,
            ),
            const SizedBox(width: kSpace3),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: kSpace2),
                // C-449 D2b: announced when Home comes back.
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    widget.text,
                    key: widget.textKey,
                    textAlign: TextAlign.start,
                    style: textTheme.bodyMedium?.copyWith(
                      color: LudoColors.ink,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('home-notice-dismiss'),
              onPressed: widget.onDismiss,
              tooltip: widget.dismissLabel,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              color: LudoColors.ink,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
    if (disableAnimations) {
      return card;
    }
    // The notice fades in; it never pops. Layout is not animated so the
    // controls inside are in their final place on the first frame.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: card,
    );
  }
}

/// Last successful table, shown when [SessionMemory.hasLastTable] is true.
/// Visual weight stays below Create (muted paper, not action fill) so
/// Create still outweighs Join with the chip on screen.
class _LastTableChip extends StatelessWidget {
  const _LastTableChip({required this.name, required this.seats});

  final String name;
  final int seats;

  /// U+00A0, spelled as an escape so the character can never be mistaken
  /// for a plain space by a reader or silently normalised by an editor.
  static const String _noBreakSpace = '\u00A0';

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
    // C-351: at a system text scale of 1.5 and above the label may wrap to
    // a second line; below that nothing changes (one line, ellipsis). The
    // scale is read off the ambient TextScaler at this chip's own font
    // size, never off the platform directly, so it answers "how much
    // bigger is this text actually drawn", not "what did the OS report".
    final double scaleAtLabel =
        MediaQuery.textScalerOf(context).scale(kTypeLabel) / kTypeLabel;
    final int maxLines = scaleAtLabel >= 1.5 ? 2 : 1;
    // The break may only fall between the name and the seat count: the
    // space that glues name to "·" is non-breaking, and every space inside
    // the seat label is made non-breaking too, leaving the single plain
    // space after "·" as the only place Flutter's line breaker can act.
    final String seatsNoBreak = seatsLabel.replaceAll(' ', _noBreakSpace);
    final String painted = '$name$_noBreakSpace· $seatsNoBreak';
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
              painted,
              maxLines: maxLines,
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

/// C-322: the last finished game's verify link, kept reachable from home
/// for 90 days after the table is gone (rule 3). Same register as
/// [_LastTableChip] -- paper wash, felt edge, ink text, no action fill --
/// so a returning player reads this as a standing fact about their last
/// game, not a third thing to tap toward. The leading icon is a second,
/// non-colour signal that this entry carries a verified link (doctrine P9).
class _LastGameEntry extends StatelessWidget {
  const _LastGameEntry({required this.game, required this.onCheck});

  final LastGame game;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    return DecoratedBox(
      key: const Key('home-last-game'),
      decoration: BoxDecoration(
        color: LudoColors.paperWashTop,
        borderRadius: BorderRadius.circular(kRadiusControl),
        border: Border.all(color: LudoColors.feltLight),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(kSpace3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              loc.homeLastGame,
              textAlign: TextAlign.center,
              style: textTheme.labelLarge?.copyWith(
                color: LudoColors.ink,
                fontSize: kTypeLabel,
              ),
            ),
            const SizedBox(height: kSpace2),
            VerifyRollsButton(
              key: const Key('home-last-game-check'),
              onPressed: onCheck,
            ),
          ],
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

/// C-276 rule 3: toggle card for a game rule (Capture bonus) on the home
/// screen, matching the lobby screen rule chips instead of a settings page
/// switch. Off state displays a diagonal strike over the icon and removes
/// the check badge (doctrine P9).
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
