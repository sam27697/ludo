import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'deep_link.dart';
import 'lobby_screen.dart';
import 'net/room_controller.dart';
import 'room_code.dart';
import 'server_config.dart';

/// Home screen: app title, a name field, a player-count selector, Create
/// Room, and Join Room with a code field validated locally against the room
/// code shape before anything navigates.
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

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  String? _errorText;
  int _players = 4;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _codeController.dispose();
    _nameController.dispose();
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
        builder: (context) => LobbyScreen(
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
        builder: (context) => LobbyScreen(
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
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.appTitle),
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('home-name-field'),
                  controller: _nameController,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    labelText: loc.homeNameFieldLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  loc.homePlayersSelectorLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                _PlayersSelector(
                  key: const Key('home-players-selector'),
                  value: _players,
                  onChanged: (value) => setState(() => _players = value),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  key: const Key('create-room-button'),
                  onPressed: _createRoom,
                  child: Text(loc.homeCreateRoomButton),
                ),
                const SizedBox(height: 32),
                TextField(
                  key: const Key('room-code-field'),
                  controller: _codeController,
                  textAlign: TextAlign.center,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: loc.homeRoomCodeFieldLabel,
                    hintText: loc.homeRoomCodeFieldHint,
                    errorText: _errorText,
                    // Unset, InputDecoration truncates errorText to one line
                    // with an ellipsis (see InputDecoration.errorMaxLines in
                    // the framework). homeRoomCodeInvalid needs four lines to
                    // clear at this field's width in either locale (measured
                    // with TextPainter against the field's actual layout
                    // width), and an error a player cannot read to the end is
                    // worse than no error, so let it wrap instead of clipping
                    // it.
                    errorMaxLines: 4,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  key: const Key('join-room-button'),
                  onPressed: _joinRoom,
                  child: Text(loc.homeJoinRoomButton),
                ),
              ],
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
