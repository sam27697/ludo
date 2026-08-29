import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
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
  });

  /// Flips the app between its two supported locales.
  final VoidCallback onToggleLocale;

  /// Builds the [RoomController] a Create Room or Join Room tap pushes a
  /// [LobbyScreen] with. The real default opens a real socket; a test
  /// substitutes one built over a fake transport.
  final RoomControllerFactory controllerFactory;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  String? _errorText;
  int _players = 4;

  @override
  void dispose() {
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
