import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'deep_link.dart';
import 'die_mark.dart';
import 'lobby_screen.dart' show LobbyAction;
import 'net/room_controller.dart';
import 'room_code.dart';
import 'room_route.dart';
import 'server_config.dart';
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
    with SingleTickerProviderStateMixin {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  String? _errorText;
  int _players = 4;
  StreamSubscription<Uri>? _linkSubscription;
  late final AnimationController _enter;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(_clearErrorOnEdit);
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..forward();
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

  /// Clears a standing error the moment the player edits the code field,
  /// so a message raised by a bad link or a failed Join tap does not sit
  /// under a code the player has since corrected. Runs on every keystroke,
  /// not just submission.
  void _clearErrorOnEdit() {
    if (_errorText != null) {
      setState(() {
        _errorText = null;
      });
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _codeController.removeListener(_clearErrorOnEdit);
    _codeController.dispose();
    _nameController.dispose();
    _enter.dispose();
    super.dispose();
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomRoute(
          controller: controller,
          action: LobbyAction.create,
          playerName: name,
          players: players,
        ),
      ),
    );
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
    await controller.leave();
    controller.dispose();
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RoomRoute(
          controller: controller,
          action: LobbyAction.join,
          code: normalized,
          playerName: name,
        ),
      ),
    );
    // See the matching comment in _createRoom: leave() must be awaited
    // before dispose() so a leave_room request actually reaches the wire,
    // and the up-to-10-second worst case on a dead socket is bounded and
    // deliberate, not a bug.
    await controller.leave();
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final double viewHeight = MediaQuery.sizeOf(context).height;
    // Default widget-test surface is 800x600; keep create/join on-screen
    // there. Real phones are taller and get the stacked brand + die hero.
    final bool compact = viewHeight < 640;
    final double dieSize = compact ? 72 : 148;
    final double afterBrand = compact ? 12 : 28;
    final double afterDie = compact ? 16 : 32;
    final double sectionGap = compact ? 14 : 28;

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
                24,
                compact ? 4 : 8,
                24,
                compact ? 20 : 32,
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
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(loc.appTitle, style: brandStyle),
                                          const SizedBox(height: 4),
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
                                    const SizedBox(height: 10),
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
                            decoration: InputDecoration(
                              labelText: loc.homeNameFieldLabel,
                              isDense: compact,
                            ),
                          ),
                          SizedBox(height: compact ? 12 : 20),
                          Text(
                            loc.homePlayersSelectorLabel,
                            textAlign: TextAlign.center,
                            style: textTheme.labelLarge?.copyWith(
                              color: LudoColors.inkMuted,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _PlayersSelector(
                            key: const Key('home-players-selector'),
                            value: _players,
                            onChanged: (value) =>
                                setState(() => _players = value),
                          ),
                          SizedBox(height: compact ? 14 : 24),
                          ElevatedButton(
                            key: const Key('create-room-button'),
                            onPressed: _createRoom,
                            child: Text(loc.homeCreateRoomButton),
                          ),
                          SizedBox(height: sectionGap),
                          TextField(
                            key: const Key('room-code-field'),
                            controller: _codeController,
                            textAlign: TextAlign.center,
                            textCapitalization: TextCapitalization.characters,
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
                          SizedBox(height: compact ? 8 : 12),
                          ElevatedButton(
                            key: const Key('join-room-button'),
                            onPressed: _joinRoom,
                            child: Text(loc.homeJoinRoomButton),
                          ),
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
