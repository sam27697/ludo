import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'account.dart';
import 'code_ban_notice.dart';
import 'create_room_sheet.dart';
import 'deep_link.dart';
import 'die_mark.dart';
import 'directional_icon.dart';
import 'feedback.dart';
import 'game_screen.dart' show GameScreenResult;
import 'home_logo_panel.dart';
import 'home_style.dart';
import 'lobby_screen.dart' show LobbyAction;
import 'net/connection.dart' show RoomToggles;
import 'net/room_controller.dart';
import 'net/snapshot.dart';
import 'queue_sheet.dart';
import 'join_sheet.dart';
import 'room_code.dart';
import 'room_route.dart';
import 'server_config.dart';
import 'session_memory.dart';
import 'sound_toggle.dart';
import 'theme.dart';
import 'verify_link.dart';
import 'verify_rolls_button.dart';

/// How long the name field shakes when Create or Join is tapped with no name
/// (C-701), the same small shake every refused tap in the app gets.
const Duration kNameShakeDuration = Duration(milliseconds: 260);

/// Home screen: one branded composition (wordmark, tagline, die mark), the
/// name, and two buttons: Create room opens the create sheet, Join a game
/// opens the join sheet (C-701).
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

/// C-682: the lines home can show after a join that ended without a seat.
enum _KnockNotice { notJoined, full, switchedOff, kicked }

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // C-701: the room code lives in the join sheet now; home keeps the text and
  // its error line so both survive the sheet closing and opening again.
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final ValueNotifier<String?> _codeError = ValueNotifier<String?>(null);
  // C-701 (X226): the name is required. [_nameRequired] shows the red line
  // under the field until the field is edited; [_nameShake] is the refused
  // tap's shake.
  final FocusNode _nameFocusNode = FocusNode();
  late final AnimationController _nameShake;
  bool _nameRequired = false;
  // C-701: a tapped room link that arrived with no name. Joined as soon as a
  // name is submitted from the keyboard.
  String? _linkWaitingForName;
  // C-701: an incoming room link this app cannot read. Shown as a home notice,
  // since the code field it used to mark is no longer on home.
  bool _linkInvalidNotice = false;
  // C-701: the waiting line or a computer game ended without a seat; the
  // controller's error code, worded by [_lineErrorText].
  String? _lineErrorCode;
  bool _removedNotice = false;
  // C-447 D4: shown in the same slot as [_removedNotice] after a resume the
  // server refused (the room was reaped or the seat taken back).
  bool _gameGoneNotice = false;
  // C-529 D3: the lobby's room closed while the player was away. Null when
  // there is no such notice, otherwise which of the two lines it carries.
  GameScreenResult? _roomClosedNotice;
  // C-682: how a typed-code knock ended without a seat, or the lobby kick that
  // sent this player home. Null when there is no such line.
  _KnockNotice? _knockNotice;
  // Section 32 item 12: the ban a typed-code join, a rejected knock or a host
  // removal just told this phone about. Null when there is none to show.
  CodeBan? _codeBan;
  // C-529 D4: the code a room link filled into the code field, kept only
  // while the field still holds exactly it. A Join tap on it is a link join.
  String? _linkFilledCode;
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
  StreamSubscription<Uri>? _linkSubscription;
  late final AnimationController _enter;
  // The name the field held at the last edit, so the red line clears on an
  // edit and not on a focus change.
  String _lastNameText = '';
  bool _enterMotionArmed = false;
  List<String> _recentCodes = const <String>[];
  RoomController? _ownedController;
  // H3: the seat rejoin button shows exactly when this is non-null. C-669 R1:
  // always the last record this screen wrote to or cleared from storage, set
  // by the one-time load, by every write of H1 and cleared by H2.
  SeatRecord? _seatRecord;
  // C-669 r2 D2: when [_seatRecord] was saved, so the trust age (C-447 D2)
  // holds inside one app life as it does at the load: from the load's own
  // saved time, or from this screen's write. Null with no record, or for a
  // record whose stored time was absent (kept as the load keeps it).
  DateTime? _seatSavedAt;
  // C-669 r2 D1: bumped by every write or clear of [_seatRecord], so a walk-off
  // that sat in leave() can tell that a newer controller changed the record
  // while it waited, and then leaves the record alone.
  int _seatGeneration = 0;
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
  // C-451 D6: when this state last wrote the seat record, by widget.clock,
  // so a long game keeps the stored saved time within kSeatRecordRefresh of
  // now. Reset with _lastRecordedSeatWritten.
  DateTime? _lastSeatWriteAt;
  // H2's per-controller dedupe for the finished/seat-gone clear, reset the
  // same way.
  bool _seatClearedForOwned = false;
  // C-669 R3: the clear above was because the room finished, so a rematch
  // lobby or game of the same controller writes the seat again at once and
  // re-arms the clear. A seat that is gone for good never re-arms.
  bool _seatClearedByFinish = false;
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
    _nameController.addListener(_onNameEdited);
    _nameShake = AnimationController(vsync: this, duration: kNameShakeDuration);
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
  /// player: a link that could not be read leaves home as it was, and the
  /// player can still type the code in the join sheet.
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

  /// Joins or rejoins the room an incoming link names when Home is the
  /// current route (order 296, C-394).
  ///
  /// A stored seat for that room resumes, whether or not a name is stored.
  /// Otherwise a non-empty name joins with that name. With no name (C-701)
  /// the link is kept, the name field takes focus with the name-required
  /// line, and the join goes as soon as a name is submitted.
  ///
  /// Nothing happens while another route (a lobby, a game, a sheet) is above
  /// Home (rule B5). A link id that cannot be read shows the invalid-code
  /// line as a home notice.
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
    // Section 31: a room link carries a link id, never a code. A six-letter
    // code in /r/ is not one of ours and reads as an unreadable link.
    final String? linkId = roomLinkIdFromUri(uri);
    final bool codeIsValid = linkId != null;
    setState(() {
      _linkInvalidNotice = !codeIsValid;
    });
    if (!codeIsValid) {
      // Rule 4: an invalid code never joins and clears any link pending on
      // session memory (the latest link wins).
      _pendingLinkUri = null;
      _linkHoldTimer?.cancel();
      _linkHoldTimer = null;
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
    _decideLinkAction(linkId);
  }

  /// Evaluates whether an incoming link with valid [code] can push into the
  /// room or should leave the code filled in place (order 296, C-394).
  ///
  /// The seat-record check stands on its own, ahead of the stored-name
  /// check: resume needs no name, and neither check is the last-table chip.
  void _decideLinkAction(String linkId) {
    if (!mounted) {
      return;
    }
    _linkHadSay = true;
    final bool isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
    if (isCurrent && !_linkJoinInFlight) {
      // C-681 R1: a link for a room this phone still holds a seat in takes
      // that seat back, the same as a typed code equal to the stored code.
      final SeatRecord? held = _seatRecordForLink(linkId);
      if (held != null) {
        _linkJoinInFlight = true;
        unawaited(
          _rejoinRoom(held).whenComplete(() => _linkJoinInFlight = false),
        );
        return;
      }
      // The tapped link is the one tap. C-701 (X226): with no name there is
      // nothing to send, so the link waits for one.
      if (_typedName.isEmpty) {
        _waitForNameThenJoin(linkId);
        return;
      }
      unawaited(_joinFromLink(linkId));
    }
    // Home under another route (rule 3), or a join already in flight
    // (rule 6): the link does not navigate.
  }

  /// C-701 (X226): a link arrived with no name. The field takes focus with
  /// the name-required line; [_submitName] joins once a name is there.
  void _waitForNameThenJoin(String linkId) {
    setState(() {
      _linkWaitingForName = linkId;
      _nameRequired = true;
    });
    _nameFocusNode.requestFocus();
  }

  /// The name field's keyboard action. A link waiting for a name joins now;
  /// with no name it stays waiting and says so.
  void _submitName() {
    final String? linkId = _linkWaitingForName;
    if (linkId == null) {
      return;
    }
    if (_typedName.isEmpty) {
      _refuseForName();
      return;
    }
    setState(() {
      _linkWaitingForName = null;
    });
    if (_linkJoinInFlight) {
      return;
    }
    unawaited(_joinFromLink(linkId));
  }

  /// The trimmed name in the field; empty when none was typed. Never stands
  /// in a default (C-701, X226).
  String get _typedName => _nameController.text.trim();

  /// C-701 (X226): Create or Join tapped with no name. Nothing opens; the
  /// field takes focus, shakes once, and the red line shows until an edit.
  void _refuseForName() {
    FeedbackScope.of(context).play(FeedbackCue.invalidTap);
    setState(() {
      _nameRequired = true;
    });
    _nameFocusNode.requestFocus();
    if (!MediaQuery.disableAnimationsOf(context)) {
      _nameShake.forward(from: 0);
    }
  }

  void _onNameEdited() {
    final String text = _nameController.text;
    if (text == _lastNameText) {
      return;
    }
    _lastNameText = text;
    if (_nameRequired && mounted) {
      setState(() {
        _nameRequired = false;
      });
    }
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
    final String? linkId = roomLinkIdFromUri(uri);
    if (linkId == null) {
      return false;
    }
    _decideLinkAction(linkId);
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
    final String? linkId = roomLinkIdFromUri(uri);
    if (linkId != null) {
      _decideLinkAction(linkId);
    }
  }

  /// Runs a link-driven join, guarding against duplicate pushes while the
  /// route is in flight (rule 6).
  Future<void> _joinFromLink(String linkId) async {
    _linkJoinInFlight = true;
    try {
      await _joinByLink(linkId);
    } finally {
      _linkJoinInFlight = false;
    }
  }

  /// Clears a standing code error on every edit, so a message raised by a
  /// failed Join tap does not sit under a code the player has since
  /// corrected.
  void _clearErrorOnEdit() {
    if (_linkFilledCode != null &&
        normalizeRoomCode(_codeController.text) != _linkFilledCode) {
      _linkFilledCode = null;
    }
    _codeError.value = null;
  }

  /// Restores a stored name (from a create or a join), last successful-create
  /// seats, the last-table chip, recent join codes, a seat record held
  /// across a process kill (H3), and the last finished game's verify link
  /// (C-322 rule 3) from [SessionMemory]. An empty or unreadable store
  /// leaves the name field empty, the four-seat disclosure, no recent
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
            _nameController.text = storedName;
          }
          if (hasTable) {
            final String name = loaded.lastName!;
            _nameController.text = name;
          }
          if (seatRecord != null) {
            _setSeat(seatRecord, loaded.seatSavedAt);
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

  /// C-701 (X226): the name field starts empty, its label the hint; no
  /// default name is ever filled in or sent.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
    _screenDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _linkHoldTimer?.cancel();
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoResumeWaiting = null;
    _codeController.removeListener(_clearErrorOnEdit);
    _nameController.removeListener(_onNameEdited);
    _codeController.dispose();
    _codeError.dispose();
    _nameController.dispose();
    _nameFocusNode.dispose();
    _nameShake.dispose();
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
    _lastSeatWriteAt = null;
    _seatClearedForOwned = false;
    _seatClearedByFinish = false;
    controller.addListener(_onOwnedControllerChanged);
  }

  /// H1: writes the seat this controller currently holds the moment it is
  /// worth resuming -- connected, a room snapshot, that room not finished,
  /// a seat and a seat token both present -- at most once per distinct
  /// record for as long as this controller is the one owned, plus (C-451 D6)
  /// one rewrite of the same record with a new saved time whenever a
  /// notification arrives and [kSeatRecordRefresh] has passed since this
  /// state last wrote it, so the record's age measures time since the seat
  /// was last held while connected. No timer: the rewrite rides controller
  /// notifications. Covers create,
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
        !controller.seatTakenOver &&
        !controller.updateRequired &&
        room != null &&
        room.state != RoomState.finished) {
      final int? seat = controller.seat;
      final String? seatToken = controller.seatToken;
      if (seat != null && seatToken != null) {
        final SeatRecord record = SeatRecord(
          code: room.code,
          seat: seat,
          seatToken: seatToken,
          linkId: room.linkId,
        );
        final DateTime now = (widget.clock ?? DateTime.now)();
        final DateTime? lastWriteAt = _lastSeatWriteAt;
        // C-669 R3: the first sight of a live, non-finished room after a
        // finish clear is written at once, not after kSeatRecordRefresh: a
        // phone killed in that minute must still find the seat.
        final bool afterFinishClear = _seatClearedByFinish;
        if (afterFinishClear ||
            record != _lastRecordedSeatWritten ||
            lastWriteAt == null ||
            now.difference(lastWriteAt) >= kSeatRecordRefresh) {
          _lastRecordedSeatWritten = record;
          _lastSeatWriteAt = now;
          if (afterFinishClear) {
            _seatClearedForOwned = false;
            _seatClearedByFinish = false;
          }
          unawaited(SessionMemory.recordSeat(record, clock: widget.clock));
          // C-669 R1: the Rejoin control and the by-code paths read this.
          if (mounted) {
            setState(() {
              _setSeat(record, now);
            });
          }
        }
      }
    }
    final bool finished = room != null && room.state == RoomState.finished;
    if ((finished || _seatIsGone(controller)) && !_seatClearedForOwned) {
      _seatClearedForOwned = true;
      _seatClearedByFinish = finished;
      unawaited(SessionMemory.clearSeat());
      if (mounted) {
        setState(() {
          _setSeat(null, null);
        });
      }
    }
  }

  /// C-669 R1: the one place [_seatRecord] changes, so its saved time and the
  /// generation move with it. Called inside setState where the screen is
  /// mounted.
  void _setSeat(SeatRecord? record, DateTime? savedAt) {
    _seatRecord = record;
    _seatSavedAt = record == null ? null : savedAt;
    _seatGeneration++;
  }

  /// C-669 r2 D2: whether the held record is at least [kSeatRecordMaxAge] old
  /// by the injected clock, the rule [SessionMemory.load] applies at startup.
  bool _seatIsStale() {
    final DateTime? savedAt = _seatSavedAt;
    return _seatRecord != null &&
        savedAt != null &&
        (widget.clock ?? DateTime.now)().difference(savedAt) >=
            kSeatRecordMaxAge;
  }

  /// C-669 r2 D2: the held record, or null once it is past the trust age, in
  /// which case it is dropped from memory and, if storage still holds that
  /// very record, from storage too. The Rejoin render and every by-code path
  /// read the record through here. Does not call setState: the build reads it,
  /// and the other callers rebuild on their own.
  SeatRecord? _trustedSeat() {
    final SeatRecord? record = _seatRecord;
    if (record == null || !_seatIsStale()) {
      return record;
    }
    _setSeat(null, null);
    unawaited(SessionMemory.clearSeatIf(record));
    return null;
  }

  /// C-669 R4: the seat [controller] holds right now, in the shape H1 writes.
  SeatRecord? _recordOf(RoomController controller) {
    final String? code = controller.room?.code;
    final int? seat = controller.seat;
    final String? seatToken = controller.seatToken;
    if (code == null || seat == null || seatToken == null) {
      return null;
    }
    return SeatRecord(
      code: code,
      seat: seat,
      seatToken: seatToken,
      linkId: controller.room?.linkId ?? '',
    );
  }

  /// C-547 D4: a seat another phone took over is gone for this phone too;
  /// keeping the record would let a relaunch resume and take it back.
  /// Section 27 rule 6: a refused build says nothing about the seat. The
  /// record stays, so the same seat resumes after the update.
  bool _seatIsGone(RoomController controller) {
    return !controller.updateRequired &&
        (controller.seatTakenOver ||
            controller.wasKicked ||
            (controller.phase == RoomPhase.failed &&
                (controller.errorCode == 'BAD_SEAT_TOKEN' ||
                    controller.errorCode == 'NO_SUCH_ROOM')));
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
    final Uri? parsed = Uri.tryParse(game.verifyUrl);
    if (parsed == null ||
        (!parsed.isScheme('https') && !parsed.isScheme('http'))) {
      _showLastGameVerifyOpenFailed();
      return;
    }
    final Uri uri = verifyUriFor(parsed, Localizations.localeOf(context));
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
      // C-669 r2 D2: a phone back after more than the trust age shows no
      // Rejoin for a seat the server has long since played on.
      if (mounted && _seatIsStale()) {
        setState(_trustedSeat);
      }
    }
  }

  /// [leave] then [RoomController.dispose], unless [dispose] already retired
  /// this instance while the pushed route was still up.
  ///
  /// H2(b): once [leave] completes, the seat record is cleared and the H3
  /// button hidden, whether or not a record was ever written for this
  /// controller. C-669 R4: only when the server heard the leave, or the room
  /// is finished, or the seat is gone for good ([_seatIsGone], or [result]
  /// says the route left because the seat was removed or the room reaped).
  /// A leave that never reached the server (no live connection, timed out,
  /// refused for a reason that is not a gone seat) leaves the seat held there
  /// as a dropped one, so the record, and the Rejoin control with it, stay;
  /// the trust age expires them.
  ///
  /// C-669 r2 D1: the record is hidden in memory from the first line, so the
  /// Rejoin control never shows for the seat being left while [leave] waits
  /// for its answer. It comes back only if the leave was not delivered and
  /// nothing wrote or cleared the record meanwhile; storage is cleared only
  /// if it still holds the record being left. A newer controller's record
  /// is never touched.
  Future<void> _retireOwnedController(
    RoomController controller, {
    Object? result,
  }) async {
    if (!identical(_ownedController, controller)) {
      return;
    }
    controller.removeListener(_onOwnedControllerChanged);
    _ownedController = null;
    // Read before leave(), which moves the phase on to closed.
    final bool seatEnded =
        controller.room?.state == RoomState.finished ||
        _seatIsGone(controller) ||
        result == GameScreenResult.removed ||
        result == GameScreenResult.gameGone;
    final SeatRecord? held = _seatRecord;
    final DateTime? heldSavedAt = _seatSavedAt;
    final SeatRecord? leaving = held ?? _recordOf(controller);
    if (held != null) {
      if (!_screenDisposed && mounted) {
        setState(() {
          _setSeat(null, null);
        });
      } else {
        _setSeat(null, null);
      }
    }
    final int generation = _seatGeneration;
    final bool delivered = await controller.leave();
    // Section 27 rule 6: a build the server refused walks home with its seat
    // record intact, so the same seat resumes once the app is updated.
    final bool refusedBuild = controller.updateRequired;
    controller.dispose();
    // A write or a clear since the hide came from a newer controller or a
    // refused resume: the record is theirs, not this walk-off's.
    final bool untouched = generation == _seatGeneration;
    if (!untouched) {
      return;
    }
    if (refusedBuild || (!delivered && !seatEnded)) {
      if (held != null && !_screenDisposed && mounted) {
        setState(() {
          _setSeat(held, heldSavedAt);
        });
      }
      return;
    }
    if (leaving != null) {
      unawaited(SessionMemory.clearSeatIf(leaving));
    }
  }

  bool get _hasNotice =>
      _removedNotice ||
      _gameGoneNotice ||
      _roomClosedNotice != null ||
      _knockNotice != null ||
      _linkInvalidNotice ||
      _lineErrorCode != null ||
      _codeBan != null;

  bool get _hasPlainNotice =>
      _removedNotice ||
      _gameGoneNotice ||
      _roomClosedNotice != null ||
      _knockNotice != null ||
      _linkInvalidNotice ||
      _lineErrorCode != null;

  /// D2 of C-449: the player closes the notice by hand. Every other event
  /// that hides it (create, join, rejoin) is handled where it starts.
  void _dismissNotice() {
    setState(_clearNotices);
  }

  /// Every home notice off. Called inside setState.
  void _clearNotices() {
    _removedNotice = false;
    _gameGoneNotice = false;
    _roomClosedNotice = null;
    _knockNotice = null;
    _linkInvalidNotice = false;
    _lineErrorCode = null;
    _codeBan = null;
  }

  /// C-701: the line the home notice carries when the waiting line or a
  /// computer game ended without a seat, by the class of the failure.
  String _lineErrorText(AppLocalizations loc, String code) {
    return switch (code) {
      'RATE_LIMITED' => loc.lobbyErrorRateLimited,
      'transport' || 'closed' || 'timeout' => loc.lobbyErrorTransport,
      _ => loc.lobbyErrorGeneric,
    };
  }

  /// Shows the home notice a pushed route's [result] asks for, and no other.
  /// A null or `newTable` result leaves whatever notice is up alone. C-529
  /// D3 adds the room-closed lines, and [GameScreenResult.gameGone] now also
  /// arrives from a create or join route whose game was reaped.
  void _showNoticeFor(Object? result) {
    if (!mounted) {
      return;
    }
    switch (result) {
      case GameScreenResult.removed:
        setState(() {
          _clearNotices();
          _removedNotice = true;
          _gameGoneNotice = false;
          _roomClosedNotice = null;
          _knockNotice = null;
        });
      case GameScreenResult.gameGone:
        setState(() {
          _clearNotices();
          _removedNotice = false;
          _gameGoneNotice = true;
          _roomClosedNotice = null;
          _knockNotice = null;
        });
      case GameScreenResult.roomClosedHost:
      case GameScreenResult.roomClosedGuest:
        setState(() {
          _clearNotices();
          _roomClosedNotice = result as GameScreenResult;
        });
      default:
        break;
    }
  }

  /// C-682: read once from a join route that has just returned, before the
  /// controller is retired: how this phone's knock ended, or that the host
  /// removed it. The rejected and timed-out outcomes say the same thing, so a
  /// stranger learns nothing; a withdrawn knock was this player's own Cancel
  /// and says nothing. Sets nothing when neither happened.
  void _noteKnockOutcome(RoomController controller) {
    if (!mounted) {
      return;
    }
    final _KnockNotice? notice = controller.wasKicked
        ? _KnockNotice.kicked
        : switch (controller.knockState.phase) {
            KnockPhase.rejected ||
            KnockPhase.timedOut => _KnockNotice.notJoined,
            KnockPhase.full => _KnockNotice.full,
            KnockPhase.switchedOff => _KnockNotice.switchedOff,
            _ => null,
          };
    // Section 32 item 12: the ban rides on the frame that fired it, or on a
    // CODE_BANNED answer to a typed code. Shown whatever else is shown.
    final CodeBan? ban =
        controller.wasKicked ||
            controller.knockState.phase == KnockPhase.rejected ||
            controller.errorCode == 'CODE_BANNED'
        ? controller.ban
        : null;
    if (notice == null && ban == null) {
      return;
    }
    setState(() {
      _clearNotices();
      _knockNotice = notice;
      _codeBan = ban;
    });
  }

  /// C-529 D4: a join that came back refused NO_SUCH_ROOM or ROOM_STARTED
  /// leaves a code that can never work. Clearing it means the join sheet
  /// opens on an empty field next time, and drops any link-filled state. A1.2: only when the field
  /// still holds [joinedCode]; a code typed or filled by a link while the
  /// route was up stays, with its link state.
  void _clearDeadJoinCode(RoomController controller, String joinedCode) {
    if (!mounted ||
        controller.phase != RoomPhase.failed ||
        !(controller.errorCode == 'NO_SUCH_ROOM' ||
            controller.errorCode == 'ROOM_STARTED') ||
        normalizeRoomCode(_codeController.text) != joinedCode) {
      return;
    }
    _linkFilledCode = null;
    _codeController.clear();
  }

  /// Whether the code in the field is the one a room link filled in and the
  /// player has not touched since (C-529 D4).
  bool get _codeIsFromLink =>
      _linkFilledCode != null &&
      normalizeRoomCode(_codeController.text) == _linkFilledCode;

  /// C-701: Create room. With a name, opens the create sheet; a tile there
  /// creates the room at once. With no name, nothing opens.
  Future<void> _onCreateTapped() async {
    if (_typedName.isEmpty) {
      _refuseForName();
      return;
    }
    final bool? open = await showCreateRoomSheet(context);
    if (!mounted || open == null) {
      return;
    }
    await _createRoom(open: open);
  }

  /// C-701: Join a game. With a name, opens the join sheet: the code tile
  /// leads to the typed-code join, the random tile to the waiting line.
  Future<void> _onJoinTapped() async {
    if (_typedName.isEmpty) {
      _refuseForName();
      return;
    }
    final JoinChoice? choice = await showJoinSheet(
      context,
      codeController: _codeController,
      errorText: _codeError,
      onJoinCode: _checkCode,
    );
    if (!mounted || choice == null) {
      return;
    }
    switch (choice) {
      case JoinChoice.code:
        await _joinRoom(fromLink: _codeIsFromLink);
      case JoinChoice.random:
        await _findGame();
    }
  }

  /// The join sheet's Join: false, with the invalid-code line, for a code that
  /// cannot be sent; true when the typed-code join may go.
  bool _checkCode() {
    if (isValidRoomCode(normalizeRoomCode(_codeController.text))) {
      _codeError.value = null;
      return true;
    }
    _codeError.value = AppLocalizations.of(context).homeRoomCodeInvalid;
    return false;
  }

  /// [open] is section 33 item 1's flag: true lets the server seat strangers
  /// from the waiting line. Every other step is the create flow as it was.
  Future<void> _createRoom({required bool open}) async {
    final String name = _typedName;
    if (name.isEmpty) {
      _refuseForName();
      return;
    }
    if (_hasNotice) {
      setState(_clearNotices);
    }
    // C-666 D1: every table seats four; the host starts once a friend sits.
    const int players = 4;
    // C-523 D1: every room is created with the fixed rules.
    const RoomToggles toggles = RoomToggles();
    final RoomController controller = widget.controllerFactory();
    // The lobby sends create_room itself, its retry too; the controller adds
    // the flag to every create it sends.
    controller.createOpen = open;
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
    _showNoticeFor(result);
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
    await _retireOwnedController(controller, result: result);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      await _createRoom(open: open);
    }
  }

  /// [fromLink] is true only for a join of the code a room link filled in and
  /// the player has not changed: the lobby then words a vanished room in the
  /// link's terms (C-447 D4b, C-529 D4). A join from a typed code leaves it
  /// false.
  Future<void> _joinRoom({bool fromLink = false}) async {
    final AppLocalizations loc = AppLocalizations.of(context);
    final String normalized = normalizeRoomCode(_codeController.text);
    if (!isValidRoomCode(normalized)) {
      _codeError.value = loc.homeRoomCodeInvalid;
      return;
    }
    _codeError.value = null;
    setState(_clearNotices);
    // C-669 R2: a code this phone holds a seat for is a seat to take back, not
    // a room to join: join_room would be refused ROOM_STARTED while the game
    // runs. A stale record is safe, a refused resume clears it and says so.
    final SeatRecord? held = _seatRecordFor(normalized);
    if (held != null) {
      await _rejoinRoom(held);
      return;
    }
    final String name = _typedName;
    if (name.isEmpty) {
      _refuseForName();
      return;
    }
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
    _showNoticeFor(result);
    _noteKnockOutcome(controller);
    // C-529 D4: read before the retire below, which ends the controller.
    _clearDeadJoinCode(controller, normalized);
    // See the matching comment in _createRoom: leave() must be awaited
    // before dispose() so a leave_room request actually reaches the wire,
    // and the up-to-10-second worst case on a dead socket is bounded and
    // deliberate, not a bug.
    await _retireOwnedController(controller, result: result);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      // A new table for the same friends: friends only, as before C-701.
      await _createRoom(open: false);
    }
  }

  /// Section 31: joins the room a tapped link names, by link id. The same
  /// route and the same bookkeeping as [_joinRoom], with no code to check or
  /// remember until the server has answered with the room.
  Future<void> _joinByLink(String linkId) async {
    final String name = _typedName;
    if (name.isEmpty) {
      _waitForNameThenJoin(linkId);
      return;
    }
    setState(() {
      _clearNotices();
      _linkWaitingForName = null;
    });
    final RoomController controller = widget.controllerFactory();
    _watchOwnedController(controller);
    bool recordedJoin = false;
    void persistSuccessfulJoin() {
      if (recordedJoin) {
        return;
      }
      final RoomSnapshot? room = controller.room;
      if (controller.phase != RoomPhase.connected || room == null) {
        return;
      }
      recordedJoin = true;
      unawaited(SessionMemory.recordSuccessfulJoin(room.code, name: name));
      if (mounted) {
        setState(() {
          _recentCodes = SessionMemory.prependRecentCode(
            _recentCodes,
            room.code,
          );
        });
      }
    }

    controller.addListener(persistSuccessfulJoin);
    // Started here, from a handler, so the first notification is not raised
    // while a route builds. The lobby's own join request then finds the
    // controller already connecting and does nothing (its code is empty).
    unawaited(controller.joinByLink(link: linkId, name: name));
    final Object? result;
    try {
      result = await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => RoomRoute(
            controller: controller,
            action: LobbyAction.join,
            code: '',
            playerName: name,
            fromLink: true,
          ),
        ),
      );
    } finally {
      controller.removeListener(persistSuccessfulJoin);
    }
    _showNoticeFor(result);
    _noteKnockOutcome(controller);
    await _retireOwnedController(controller, result: result);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      // A new table for the same friends: friends only, as before C-701.
      await _createRoom(open: false);
    }
  }

  /// C-701: Random players. Joins the server's waiting line and holds the
  /// waiting window up until the server seats this phone (then the lobby, as
  /// after a join), the player leaves the line, or the line fails (then the
  /// home notice for that class of failure). A computer game started from the
  /// window lands the same way as a seat from the line.
  Future<void> _findGame() async {
    final String name = _typedName;
    if (name.isEmpty) {
      _refuseForName();
      return;
    }
    if (_hasNotice) {
      setState(_clearNotices);
    }
    final RoomController controller = widget.controllerFactory();
    _watchOwnedController(controller);
    unawaited(controller.findGame(name: name));
    final QueueOutcome? outcome = await showQueueSheet(
      context,
      controller: controller,
      playerName: name,
    );
    if (!mounted) {
      await _retireOwnedController(controller);
      return;
    }
    if (outcome != QueueOutcome.seated || controller.room == null) {
      final String? code = controller.errorCode;
      if (outcome == QueueOutcome.failed) {
        setState(() {
          _clearNotices();
          _lineErrorCode = code ?? 'closed';
        });
      }
      await _retireOwnedController(controller);
      return;
    }
    final RoomSnapshot room = controller.room!;
    unawaited(SessionMemory.recordName(name));
    final Object? result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomRoute(
          controller: controller,
          action: controller.isHost ? LobbyAction.create : LobbyAction.join,
          code: room.code,
          playerName: name,
        ),
      ),
    );
    _showNoticeFor(result);
    await _retireOwnedController(controller, result: result);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      await _createRoom(open: false);
    }
  }

  /// C-669 R2: the seat this screen holds for [code], or null. Memory equals
  /// storage once the session-memory load has completed (R1); a tap that lands
  /// before it has no record to read yet and joins as it always did.
  ///
  /// C-669 r2 D2: a record past the trust age is absent here, and dropped.
  SeatRecord? _seatRecordFor(String code) {
    final SeatRecord? record = _trustedSeat();
    return record != null && record.code == code ? record : null;
  }

  /// C-681 R1: the seat this screen holds for the room [linkId] names, or
  /// null. A record with no link id never matches (join by link as before).
  SeatRecord? _seatRecordForLink(String linkId) {
    final SeatRecord? record = _trustedSeat();
    return record != null && record.linkId.isNotEmpty && record.linkId == linkId
        ? record
        : null;
  }

  /// H4: the H3 button's tap. Builds a controller the same way create and
  /// join do, watches it the same way, and pushes the same [RoomRoute],
  /// with [LobbyAction.resume] and [record] standing in for the code and
  /// players a create or join would otherwise carry. H1, on the controller
  /// this watches, is what records the seat again once the resume lands;
  /// nothing here writes [SessionMemory] directly.
  Future<void> _rejoinRoom(SeatRecord record) async {
    if (_hasNotice) {
      setState(_clearNotices);
    }
    // A resume sends no name: the seat already has one. The lobby is handed
    // whatever the field holds, possibly nothing.
    final String name = _typedName;
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
    // C-447 D4, C-540 D4: a resume the server refused (room reaped, seat
    // taken back) or a seat removed while the route was up goes home with its
    // own true line, set before the retire like the removed notice in
    // _createRoom, and the Rejoin control for that seat goes with it: the
    // retire can sit for the 10 second request timeout on a dead socket, and
    // a seat that is gone cannot be rejoined. The stored record itself is
    // cleared by the retire, as before.
    if (result == GameScreenResult.gameGone ||
        result == GameScreenResult.removed) {
      _showNoticeFor(result);
      if (mounted && _seatRecord?.code == record.code) {
        setState(() {
          _setSeat(null, null);
        });
      }
      unawaited(SessionMemory.clearSeatIf(record));
    }
    // C-669 r2 D4: a resume the server refused for a gone room leaves a dead
    // code in the field when the player typed it, as a refused join does.
    _clearDeadJoinCode(controller, record.code);
    // See the matching comment in _createRoom: leave() must be awaited
    // before dispose() so a leave_room request actually reaches the wire,
    // and the up-to-10-second worst case on a dead socket is bounded and
    // deliberate, not a bug.
    await _retireOwnedController(controller, result: result);
    if (!mounted) {
      return;
    }
    if (result == GameScreenResult.newTable) {
      // A new table for the same friends: friends only, as before C-701.
      await _createRoom(open: false);
    }
  }

  /// C-701: the two home buttons, stacked, equal in width and height. The
  /// primary one is an [ElevatedButton] on the strong gold frame; the quiet
  /// one an [OutlinedButton] on the light frame.
  Widget _homeButton({
    required Key key,
    required VoidCallback onPressed,
    required String label,
    required Widget icon,
    required bool primary,
  }) {
    final Widget labelWidget = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final ButtonStyle style =
        homeGoldButtonStyle(minimumSize: const Size(48, 56)).copyWith(
          padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
            EdgeInsets.symmetric(horizontal: kSpace4, vertical: kSpace2),
          ),
        );
    final Widget button = primary
        ? ElevatedButton.icon(
            key: key,
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: labelWidget,
          )
        : OutlinedButton.icon(
            key: key,
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: labelWidget,
          );
    return HomeGoldFrame(strong: primary, child: button);
  }

  /// The one home notice card, worded for whichever notice is up.
  Widget _noticeCard(AppLocalizations loc) {
    final Key textKey;
    final String text;
    bool refusal = false;
    final _KnockNotice? knock = _knockNotice;
    final String? lineError = _lineErrorCode;
    if (knock != null) {
      textKey = const Key('home-knock-notice');
      text = switch (knock) {
        _KnockNotice.notJoined => loc.knockOutcomeNotJoined,
        _KnockNotice.full => loc.knockOutcomeFull,
        _KnockNotice.switchedOff => loc.knockOutcomeSwitchedOff,
        _KnockNotice.kicked => loc.knockWasKicked,
      };
      refusal = true;
    } else if (lineError != null) {
      textKey = const Key('home-line-error-notice');
      text = _lineErrorText(loc, lineError);
      refusal = true;
    } else if (_linkInvalidNotice) {
      textKey = const Key('home-link-invalid-notice');
      text = loc.homeRoomCodeInvalid;
      refusal = true;
    } else if (_roomClosedNotice != null) {
      textKey = const Key('home-room-closed-notice');
      text = _roomClosedNotice == GameScreenResult.roomClosedHost
          ? loc.homeRoomClosedHostNotice
          : loc.homeRoomClosedGuestNotice;
    } else if (_gameGoneNotice) {
      textKey = const Key('home-game-gone-notice');
      text = loc.homeGameGoneNotice;
    } else {
      textKey = const Key('home-removed-notice');
      text = loc.homeRemovedNotice;
    }
    return _HomeNotice(
      cardKey: const Key('home-notice'),
      textKey: textKey,
      text: text,
      refusal: refusal,
      dismissLabel: loc.homeNoticeDismiss,
      onDismiss: _dismissNotice,
    );
  }

  /// The name row: the field (its label the hint, C-701), and under it the
  /// red name-required line with the refusal mark while it stands. A refused
  /// tap shakes the field; under reduced motion the line and the mark carry
  /// it alone.
  Widget _nameField(AppLocalizations loc, TextTheme textTheme, bool compact) {
    OutlineInputBorder border(Color? color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(999),
      borderSide: color == null
          ? BorderSide.none
          : BorderSide(color: color, width: 2),
    );
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    final Widget field = Semantics(
      label: loc.homeNameFieldLabel,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _nameController,
        builder: (context, nameValue, _) {
          final String trimmed = nameValue.text.trim();
          return TextField(
            key: const Key('home-name-field'),
            controller: _nameController,
            focusNode: _nameFocusNode,
            textAlign: TextAlign.center,
            textInputAction: _linkWaitingForName != null
                ? TextInputAction.go
                : TextInputAction.done,
            onSubmitted: (_) => _submitName(),
            inputFormatters: const <TextInputFormatter>[_NameInputFormatter()],
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: loc.homeNameFieldLabel,
              filled: true,
              fillColor: LudoColors.paperElevated,
              isDense: compact,
              border: border(_nameRequired ? LudoColors.error : null),
              enabledBorder: border(_nameRequired ? LudoColors.error : null),
              focusedBorder: border(
                _nameRequired ? LudoColors.error : LudoColors.action,
              ),
              prefixIcon: CircleAvatar(
                radius: 16,
                backgroundColor: LudoColors.action,
                foregroundColor: LudoColors.actionOn,
                child: trimmed.isEmpty
                    ? const Icon(
                        Icons.person,
                        size: 20,
                        color: LudoColors.actionOn,
                      )
                    : Text(
                        trimmed.characters.first.toUpperCase(),
                        style: const TextStyle(
                          color: LudoColors.actionOn,
                          fontWeight: FontWeight.w600,
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
    );
    final Widget line = _nameRequired
        ? Padding(
            padding: const EdgeInsetsDirectional.only(
              top: kSpace2,
              start: kSpace3,
              end: kSpace3,
            ),
            child: Row(
              key: const Key('home-name-required'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const RefusalNoticeMark(size: 20),
                const SizedBox(width: kSpace2),
                Flexible(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      loc.homeNameRequired,
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: LudoColors.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AnimatedBuilder(
          animation: _nameShake,
          builder: (BuildContext context, Widget? child) {
            final double v = _nameShake.value;
            final double dx = 6 * math.sin(v * math.pi * 4) * (1 - v);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: field,
        ),
        AnimatedSize(
          duration: reduce ? Duration.zero : kMotionShort,
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: line,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final SeatRecord? seatRecord = _trustedSeat();
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
    final double dieSize = math.min(
      dieMarkSize(compact),
      homeDieMarkSize(compact),
    );
    final double afterBrand = compact ? kSpace3 : kSpace6;
    final double afterDie = compact ? kSpace4 : kSpace7;
    final double beforeCreate = compact ? kSpace3 : kSpace4;
    final double betweenButtons = compact ? kSpace2 : kSpace3;

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
                      // C-523 D7: the one sound switch, in the frame the
                      // settings button had.
                      HomeGoldFrame(
                        radius: kHomeRadiusPill,
                        child: SoundToggleButton(
                          key: const Key('home-sound-toggle'),
                          style: homeGoldIconStyle(),
                        ),
                      ),
                      const SizedBox(width: kSpace2),
                      HomeGoldFrame(
                        radius: kHomeRadiusPill,
                        child: TextButton(
                          key: const Key('locale-toggle-button'),
                          onPressed: widget.onToggleLocale,
                          style: homeGoldIconStyle(),
                          child: Semantics(
                            label: loc.homeLocaleToggleLabel,
                            excludeSemantics: true,
                            child: Tooltip(
                              message: loc.homeLocaleToggleTooltip,
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      const Icon(
                                        Icons.translate_rounded,
                                        size: 18,
                                      ),
                                      Text(
                                        loc.homeLocaleToggleCode,
                                        style: const TextStyle(
                                          fontSize: kTypeCode,
                                          fontWeight: FontWeight.w700,
                                          height: 1.1,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                // Top-aligned, not centred: a notice that appears below the
                // die must not move the logo and tagline above it.
                child: Align(
                  alignment: Alignment.topCenter,
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
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const HomeLogoPanel(),
                                      const SizedBox(height: kSpace1),
                                      HomeGoldFrame(
                                        key: const Key('home-tagline'),
                                        child: Padding(
                                          padding:
                                              const EdgeInsetsDirectional.only(
                                                start: kSpace3,
                                                end: kSpace3,
                                                top: kSpace1,
                                                bottom: kSpace2,
                                              ),
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Text(
                                              loc.homeTagline,
                                              maxLines: 1,
                                              softWrap: false,
                                              textAlign: TextAlign.center,
                                              style: textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: LudoColors.ink,
                                                    height: 1.3,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      SizedBox(height: afterBrand),
                                      Center(child: DieMark(size: dieSize)),
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
                                  if (_codeBan != null) ...[
                                    CodeBanNotice(
                                      key: const Key('home-code-ban'),
                                      ban: _codeBan!,
                                      dismissLabel: loc.homeNoticeDismiss,
                                      onDismiss: _dismissNotice,
                                    ),
                                    SizedBox(
                                      height: compact ? kSpace3 : kSpace4,
                                    ),
                                  ],
                                  if (_hasNotice && _hasPlainNotice) ...[
                                    _noticeCard(loc),
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
                                  _nameField(loc, textTheme, compact),
                                  SizedBox(height: beforeCreate),
                                  _homeButton(
                                    key: const Key('create-room-button'),
                                    onPressed: _onCreateTapped,
                                    label: loc.homeCreateRoomButton,
                                    icon: const Icon(Icons.add_rounded),
                                    primary: true,
                                  ),
                                  SizedBox(height: betweenButtons),
                                  _homeButton(
                                    key: const Key('join-game-button'),
                                    onPressed: _onJoinTapped,
                                    label: loc.homeJoinGameButton,
                                    icon: const DirectionalIcon(
                                      Icons.login_rounded,
                                    ),
                                    primary: false,
                                  ),
                                  // C-322 / C-701: the last game's card is
                                  // for a player signed in with Google only.
                                  // Its space stays empty otherwise.
                                  if (googleSignedIn && _showLastGame) ...[
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

/// The longest name the server takes: a trimmed 1 to 24 UTF-16 code units
/// (`_validName` in the server's registry).
const int kNameMaxUnits = 24;

final RegExp _nameControlChars = RegExp(r'[\x00-\x1f\x7f-\x9f]');

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Keeps the name field to what the server accepts (C-529 D2): the control
/// characters it refuses are dropped as they are typed or pasted, and input
/// past [kNameMaxUnits] is refused. A paste that does not fit is cut where it
/// was inserted and never inside a surrogate pair, so a trailing emoji is
/// kept or dropped whole.
class _NameInputFormatter extends TextInputFormatter {
  const _NameInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String text = newValue.text;
    int base = newValue.selection.baseOffset;
    int extent = newValue.selection.extentOffset;
    if (text.contains(_nameControlChars)) {
      final String raw = text;
      int mapped(int offset) {
        if (offset <= 0) {
          return offset;
        }
        final int end = offset < raw.length ? offset : raw.length;
        return raw.substring(0, end).replaceAll(_nameControlChars, '').length;
      }

      text = raw.replaceAll(_nameControlChars, '');
      base = mapped(base);
      extent = mapped(extent);
    }
    if (text.length > kNameMaxUnits) {
      final String old = oldValue.text;
      // The edit is the stretch of [text] between the part it shares with
      // the old value at the front and the part it shares at the back.
      int front = 0;
      final int shortest = old.length < text.length ? old.length : text.length;
      while (front < shortest &&
          old.codeUnitAt(front) == text.codeUnitAt(front)) {
        front++;
      }
      if (front > 0 &&
          front < text.length &&
          _isHighSurrogate(text.codeUnitAt(front - 1)) &&
          _isLowSurrogate(text.codeUnitAt(front))) {
        front--;
      }
      int back = 0;
      while (back < shortest - front &&
          old.codeUnitAt(old.length - 1 - back) ==
              text.codeUnitAt(text.length - 1 - back)) {
        back++;
      }
      final int backStart = text.length - back;
      if (back > 0 &&
          backStart > 0 &&
          _isHighSurrogate(text.codeUnitAt(backStart - 1)) &&
          _isLowSurrogate(text.codeUnitAt(backStart))) {
        back--;
      }
      final String inserted = text.substring(front, text.length - back);
      final int room = kNameMaxUnits - (text.length - inserted.length);
      String kept = _cutUnits(inserted, room < 0 ? 0 : room);
      String result =
          text.substring(0, front) + kept + text.substring(text.length - back);
      int caret = front + kept.length;
      if (result.length > kNameMaxUnits) {
        // An old value already past the limit (set in code, not typed).
        result = _cutUnits(result, kNameMaxUnits);
        caret = caret < result.length ? caret : result.length;
      }
      return TextEditingValue(
        text: result,
        selection: TextSelection.collapsed(offset: caret),
      );
    }
    if (text == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: base,
        extentOffset: extent,
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
    );
  }

  /// The first [units] code units of [value], backed off by one when the cut
  /// would fall between the halves of a surrogate pair.
  static String _cutUnits(String value, int units) {
    if (units >= value.length) {
      return value;
    }
    int end = units < 0 ? 0 : units;
    if (end > 0 &&
        _isHighSurrogate(value.codeUnitAt(end - 1)) &&
        _isLowSurrogate(value.codeUnitAt(end))) {
      end--;
    }
    return value.substring(0, end);
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
    this.refusal = false,
  });

  /// A refusal (not joined, kicked) wears the red mark family of the code-ban
  /// notice; every other notice keeps the neutral mark.
  final bool refusal;
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
        border: widget.refusal
            ? Border.all(
                color: kRefusalNoticeFrame,
                width: kRefusalNoticeFrameWidth,
              )
            : Border.all(color: LudoColors.feltLight),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: kSpace3,
          top: kSpace1,
          bottom: kSpace1,
        ),
        child: Row(
          children: [
            if (widget.refusal)
              const RefusalNoticeMark()
            else
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

/// C-322: the last finished game's verify link, kept reachable from home
/// for 90 days after the table is gone (rule 3). Same gold frame as the
/// other home surfaces, ink text, no action fill, so a returning player
/// reads this as a standing fact about their last game, not a third thing
/// to tap toward. The leading icon is a second,
/// non-colour signal that this entry carries a verified link (doctrine P9).
class _LastGameEntry extends StatelessWidget {
  const _LastGameEntry({required this.game, required this.onCheck});

  final LastGame game;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    return HomeGoldFrame(
      key: const Key('home-last-game'),
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
              goldFrame: true,
            ),
          ],
        ),
      ),
    );
  }
}
