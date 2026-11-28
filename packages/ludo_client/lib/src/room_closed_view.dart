// What a player sees when the server closed the lobby because nobody started
// it (docs/PROTOCOL.md section 37 item 2, section 38 item 5): a calm card, the
// reason in plain words, one filled way forward and one quieter one. Never a
// raw error.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

class RoomClosedView extends StatelessWidget {
  const RoomClosedView({
    super.key,
    required this.onMakeNewRoom,
    required this.onJoinAnother,
  });

  final VoidCallback onMakeNewRoom;
  final VoidCallback onJoinAnother;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Center(
      key: const Key('room-closed-view'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            builder: (BuildContext context, double t, Widget? child) => Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, (1 - t) * 16),
                child: child,
              ),
            ),
            child: Material(
              color: LudoColors.paperElevated,
              elevation: 6,
              borderRadius: BorderRadius.circular(2 * kRadiusControl),
              child: Padding(
                padding: const EdgeInsets.all(kSpace5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const ExcludeSemantics(
                      child: Icon(
                        Icons.hourglass_bottom_rounded,
                        size: 40,
                        color: LudoColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: kSpace3),
                    Text(
                      loc.roomClosedTitle,
                      key: const Key('room-closed-title'),
                      textAlign: TextAlign.center,
                      style: textTheme.titleMedium?.copyWith(
                        color: LudoColors.ink,
                      ),
                    ),
                    const SizedBox(height: kSpace2),
                    Text(
                      loc.roomClosedBody,
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: LudoColors.inkMuted,
                      ),
                    ),
                    const SizedBox(height: kSpace5),
                    ElevatedButton.icon(
                      key: const Key('room-closed-new-room'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: onMakeNewRoom,
                      icon: const Icon(Icons.add_rounded),
                      label: Text(loc.lobbyMakeNewRoom),
                    ),
                    const SizedBox(height: kSpace2),
                    OutlinedButton.icon(
                      key: const Key('room-closed-join-another'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: onJoinAnother,
                      icon: const Icon(Icons.travel_explore_rounded),
                      label: Text(loc.lobbyJoinAnotherRoom),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
