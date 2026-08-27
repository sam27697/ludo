import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'room_code.dart';
import 'room_screen.dart';

/// Home screen: app title, Create Room, and Join Room with a code field
/// validated locally against the room code shape before anything navigates.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onToggleLocale});

  /// Flips the app between its two supported locales.
  final VoidCallback onToggleLocale;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _codeController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _createRoom() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (context) => const RoomScreen()));
  }

  void _joinRoom() {
    final loc = AppLocalizations.of(context);
    final normalized = normalizeRoomCode(_codeController.text);
    if (!isValidRoomCode(normalized)) {
      setState(() {
        _errorText = loc.homeRoomCodeInvalid;
      });
      return;
    }
    setState(() {
      _errorText = null;
    });
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => RoomScreen(code: normalized)),
    );
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
              child: Text(
                loc.homeLocaleToggleLabel,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
