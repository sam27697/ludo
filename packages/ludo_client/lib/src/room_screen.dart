import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';

/// Placeholder room screen. There is no networking in this build; this
/// screen exists to show, honestly, that Create Room and Join Room lead
/// somewhere and that somewhere is not connected to anything yet.
class RoomScreen extends StatelessWidget {
  const RoomScreen({super.key, this.code});

  /// The room code, when one is already known (the Join Room flow, where the
  /// player typed and validated it locally). Null on the Create Room flow,
  /// where a real code can only come from the server and there is no server
  /// connection here, so none is invented.
  final String? code;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.roomScreenTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              code == null
                  ? loc.roomScreenNoCode
                  : loc.roomScreenCodeLabel(code!),
              key: const Key('room-screen-code'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Text(
              loc.roomScreenNotImplemented,
              key: const Key('room-screen-not-implemented'),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
