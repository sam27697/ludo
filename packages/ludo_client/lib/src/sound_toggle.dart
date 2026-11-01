// Contract C-523 D7: the one sound switch. Doctrine P9 promises "haptics and
// sound each have an in-app toggle"; the player sees one speaker icon on home,
// lobby and game, and a tap mutes or unmutes both channels together through
// [FeedbackSettings.muted]. No sheet, no label, no second control.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'feedback.dart';

/// An icon button showing the speaker on while sound and vibration are on and
/// the crossed speaker while muted. [style] is the frame the settings button
/// had on the screen that hosts it, so each header keeps its own look.
///
/// Reading [FeedbackScope.settingsOf] registers this widget on the scope's
/// notifier, so the icon flips on the same frame the flag does, whoever
/// flipped it.
class SoundToggleButton extends StatelessWidget {
  const SoundToggleButton({super.key, this.style});

  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final FeedbackSettings settings = FeedbackScope.settingsOf(context);
    final bool muted = settings.muted;

    void toggle() {
      settings.muted = !settings.muted;
      // Turning it on is the one thing the player should feel: the light tick
      // that says "on". Turning it off stays silent.
      if (!settings.muted) {
        FeedbackScope.of(context).play(FeedbackCue.tap);
      }
    }

    return Semantics(
      button: true,
      toggled: !muted,
      label: loc.soundToggleLabel,
      onTap: toggle,
      excludeSemantics: true,
      child: IconButton(
        onPressed: toggle,
        style: style,
        tooltip: loc.soundToggleLabel,
        icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
      ),
    );
  }
}
