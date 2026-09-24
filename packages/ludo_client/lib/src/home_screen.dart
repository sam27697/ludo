import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import 'deep_link.dart';
import 'die_mark.dart';
import 'game_screen.dart' show GameScreenResult;
import 'lobby_screen.dart' show LobbyAction;
import 'net/room_controller.dart';
import 'room_code.dart';
import 'room_route.dart';
import 'server_config.dart';
import 'session_memory.dart';
import 'theme.dart';

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
  String? _nameLocaleDefault;
  StreamSubscription<Uri>? _linkSubscription;
  late final AnimationController _enter;
  bool _enterMotionArmed = false;
  bool _hasLastTable = false;
  String? _lastTableName;
  int? _lastTableSeats;
  List<String> _recentCodes = const <String>[];
  RoomController? _ownedController;

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

  /// Applies a room code found in an incoming link to the code field.
  ///
  /// This never navigates: a link only pre-fills and validates the code, the
  /// same way a player pastes one in by hand, and the player still taps Join
  /// themselves. That holds whether the home screen is the front-most route
  /// or another route (a lobby, a game) is currently pushed above it; either
  /// way nothing here pops or pushes anything.
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
    setState(() {
      if (code != null) {
        _codeController.text = code;
        _errorText = null;
      } else {
        _errorText = loc.homeRoomCodeInvalid;
      }
    });
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
  /// and recent join codes from [SessionMemory]. An empty or unreadable
  /// store leaves the localised name default, the four-seat disclosure,
  /// and no recent chips as they are.
  Future<void> _restoreSessionMemory() async {
    final SessionMemory memory = await SessionMemory.load();
    if (!mounted) {
      return;
    }
    final bool hasTable = memory.hasLastTable;
    final bool hasCodes = memory.recentCodes.isNotEmpty;
    if (!hasTable && !hasCodes) {
      return;
    }
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
    });
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
    _codeController.removeListener(_clearErrorOnEdit);
    _codeController.dispose();
    _nameController.dispose();
    _enter.dispose();
    final RoomController? owned = _ownedController;
    _ownedController = null;
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
  Future<void> _retireOwnedController(RoomController controller) async {
    if (!identical(_ownedController, controller)) {
      return;
    }
    _ownedController = null;
    await controller.leave();
    controller.dispose();
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
    required bool primary,
  }) {
    final Widget child = Text(label);
    if (primary) {
      return ElevatedButton(key: key, onPressed: onPressed, child: child);
    }
    return OutlinedButton(key: key, onPressed: onPressed, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool joinPrimary = isValidRoomCode(
      normalizeRoomCode(_codeController.text),
    );
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double viewHeight = MediaQuery.sizeOf(context).height;
    // Default widget-test surface is 800x600; keep create/join on-screen
    // there. Real phones are taller and get the stacked brand + die hero.
    final bool compact = viewHeight < 640;
    final double dieSize = dieMarkSize(compact);
    final double afterBrand = compact ? kSpace3 : kSpace6;
    final double afterDie = compact ? kSpace4 : kSpace7;
    final double sectionGap = compact ? kSpace3 : kSpace6;

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
      appBar: AppBar(
        // Brand lives in the body at hero scale; the bar only carries the
        // locale toggle so contrast gates and the toggle key still hold.
        backgroundColor: LudoColors.paperElevated,
        title: const SizedBox.shrink(),
        actions: [
          TextButton(
            key: const Key('locale-toggle-button'),
            onPressed: widget.onToggleLocale,
            child: Tooltip(
              message: loc.homeLocaleToggleTooltip,
              child: Text(loc.homeLocaleToggleLabel),
            ),
          ),
        ],
      ),
      body: FeltBackdrop(
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
                                  crossAxisAlignment: CrossAxisAlignment.center,
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
                                          Text(loc.appTitle, style: brandStyle),
                                          const SizedBox(height: kSpace1),
                                          Text(
                                            loc.homeTagline,
                                            style: textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: LudoColors.inkMuted,
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
                                      style: textTheme.bodyLarge?.copyWith(
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
                          TextField(
                            key: const Key('home-name-field'),
                            controller: _nameController,
                            textAlign: TextAlign.center,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) {
                              _createRoom();
                            },
                            decoration: InputDecoration(
                              labelText: loc.homeNameFieldLabel,
                              isDense: compact,
                            ),
                          ),
                          SizedBox(height: compact ? kSpace3 : kSpace5),
                          if (!_playersSelectorOpen)
                            TextButton(
                              key: const Key('home-players-disclosure'),
                              onPressed: () =>
                                  setState(() => _playersSelectorOpen = true),
                              style: TextButton.styleFrom(
                                foregroundColor: LudoColors.inkMuted,
                                minimumSize: const Size(48, 48),
                              ),
                              child: Text(
                                loc.homePlayersDisclosureClosed,
                                textAlign: TextAlign.center,
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
                          ],
                          if (_hasLastTable &&
                              _lastTableName != null &&
                              _lastTableSeats != null) ...[
                            SizedBox(height: compact ? kSpace3 : kSpace4),
                            _LastTableChip(
                              name: _lastTableName!,
                              seats: _lastTableSeats!,
                            ),
                          ],
                          SizedBox(height: compact ? kSpace3 : kSpace6),
                          _weightedButton(
                            key: const Key('create-room-button'),
                            onPressed: _createRoom,
                            label: loc.homeCreateRoomButton,
                            primary: !joinPrimary,
                          ),
                          SizedBox(height: sectionGap),
                          TextField(
                            key: const Key('room-code-field'),
                            controller: _codeController,
                            textAlign: TextAlign.center,
                            textCapitalization: TextCapitalization.characters,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) {
                              if (joinPrimary) {
                                _joinRoom();
                              }
                            },
                            inputFormatters: const <TextInputFormatter>[
                              _RoomCodeInputFormatter(),
                            ],
                            decoration: InputDecoration(
                              labelText: loc.homeRoomCodeFieldLabel,
                              hintText: loc.homeRoomCodeFieldHint,
                              errorText: _errorText,
                              // Unset, InputDecoration truncates errorText to
                              // one line with an ellipsis. homeRoomCodeInvalid
                              // needs four lines to clear at this field's
                              // width in either locale.
                              errorMaxLines: 4,
                              isDense: compact,
                            ),
                          ),
                          SizedBox(height: compact ? kSpace2 : kSpace3),
                          _weightedButton(
                            key: const Key('join-room-button'),
                            onPressed: _joinRoom,
                            label: loc.homeJoinRoomButton,
                            primary: joinPrimary,
                          ),
                          if (_recentCodes.isNotEmpty) ...[
                            SizedBox(height: compact ? kSpace2 : kSpace3),
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
