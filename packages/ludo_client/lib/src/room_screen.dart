import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'board.dart';

/// Placeholder tokens for the board this screen draws. There is no
/// networking in this build, so there is no real game state to show; these
/// sixteen numbers exist only so the screenshot pipeline has a full board to
/// photograph instead of an empty one. A server-connected build replaces
/// this constant with the room's real tokens. Nothing here is game logic.
const Map<int, List<int>> kRoomScreenPreviewTokens = <int, List<int>>{
  0: <int>[-1, 7, 24, 57],
  1: <int>[-1, 3, 18, 44],
  2: <int>[11, 29, 40, 52],
  3: <int>[-1, -1, 15, 33],
};

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
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              code == null
                  ? loc.roomScreenNoCode
                  : loc.roomScreenCodeLabel(code!),
              key: const Key('room-screen-code'),
              textAlign: TextAlign.center,
              style: code == null
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: LudoBoard(
                key: const Key('room-screen-board'),
                tokens: kRoomScreenPreviewTokens,
                seatsInPlay: const <int>[0, 1, 2, 3],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              loc.roomScreenNotImplemented,
              key: const Key('room-screen-not-implemented'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
