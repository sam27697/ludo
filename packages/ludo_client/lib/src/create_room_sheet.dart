// C-701: the sheet Create room opens. Two tiles, one tap: Anyone (an open
// room, the default and so the emphasised tile) or Friends only. The tap
// closes the sheet and home creates the room at once; back or a tap outside
// closes it and creates nothing.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'feedback.dart';
import 'home_style.dart';
import 'theme.dart';

/// Opens the create sheet. Completes with true for an open room, false for a
/// friends-only room, and null when the sheet was closed without a choice.
Future<bool?> showCreateRoomSheet(BuildContext context) {
  return showHomeSheet<bool>(
    context,
    builder: (BuildContext sheetContext) => const CreateRoomSheet(),
  );
}

class CreateRoomSheet extends StatelessWidget {
  const CreateRoomSheet({super.key});

  void _choose(BuildContext context, bool open) {
    FeedbackScope.of(context).play(FeedbackCue.tap);
    Navigator.of(context).pop(open);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const Key('create-room-sheet'),
        padding: const EdgeInsets.fromLTRB(kSpace5, kSpace3, kSpace5, kSpace6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            HomeSheetHeader(title: loc.createSheetTitle),
            const SizedBox(height: kSpace5),
            HomeSheetTilePair(
              first: HomeSheetTile(
                key: const Key('create-open-tile'),
                picture: const Icon(Icons.public_rounded),
                word: loc.createOpenTile,
                semanticLabel: loc.createOpenTileLabel,
                emphasised: true,
                onTap: () => _choose(context, true),
              ),
              second: HomeSheetTile(
                key: const Key('create-friends-tile'),
                picture: const Icon(Icons.group_rounded),
                word: loc.createFriendsTile,
                semanticLabel: loc.createFriendsTileLabel,
                onTap: () => _choose(context, false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
