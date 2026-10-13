// Contract C-329: the switches doctrine P9 promises -- "haptics and sound
// each have an in-app toggle" -- reachable from a real screen rather than
// only persisted in storage. [showFeedbackSettingsSheet] is the one place
// either switch is drawn; home and game screens both call it and never
// build a row of their own.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'feedback.dart';
import 'theme.dart';

/// Opens the sheet over [context]. The [FeedbackSettings] read off
/// [FeedbackScope.settingsOf] is captured once, from the caller's own
/// context, and handed to the sheet directly -- not re-read from the sheet
/// route's context -- so the toggle a player sees is unambiguously the
/// scope already wired above the screen that opened it.
Future<void> showFeedbackSettingsSheet(BuildContext context) {
  final FeedbackSettings settings = FeedbackScope.settingsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (BuildContext sheetContext) {
      return _FeedbackSettingsSheet(settings: settings);
    },
  );
}

class _FeedbackSettingsSheet extends StatelessWidget {
  const _FeedbackSettingsSheet({required this.settings});

  final FeedbackSettings settings;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: AnimatedBuilder(
        // Rule 1/5: a flip writes through the setter at once and this
        // sheet must show the new value at once, from the same
        // FeedbackSettings the rest of the app reads -- never a value
        // this widget caches itself.
        animation: settings,
        builder: (BuildContext context, Widget? _) {
          return Material(
            key: const Key('feedback-settings-sheet'),
            color: LudoColors.paper,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(kRadiusControl * 2),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace5,
                kSpace3,
                kSpace5,
                kSpace6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: kSpace7,
                      height: kSpace1,
                      margin: const EdgeInsets.only(bottom: kSpace4),
                      decoration: BoxDecoration(
                        color: LudoColors.inkMuted.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(kSpace1),
                      ),
                    ),
                  ),
                  Text(
                    loc.settingsTitle,
                    textAlign: TextAlign.start,
                    style: textTheme.titleMedium?.copyWith(
                      color: LudoColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: kSpace2),
                  _SettingsRow(
                    switchKey: const Key('feedback-settings-haptics'),
                    icon: Icons.vibration,
                    label: loc.settingsHaptics,
                    value: settings.haptics,
                    onChanged: (bool value) => settings.haptics = value,
                  ),
                  _SettingsRow(
                    switchKey: const Key('feedback-settings-sound'),
                    icon: settings.sound
                        ? Icons.volume_up_rounded
                        : Icons.volume_off_rounded,
                    label: loc.settingsSound,
                    value: settings.sound,
                    onChanged: (bool value) => settings.sound = value,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One row: a leading icon, a label and a [Switch], the whole row at least
/// 48dp tall and tappable anywhere, not only on the switch itself (rule 1).
/// Directional spacing only, so the row mirrors in Arabic without a branch.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.switchKey,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Key switchKey;
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusControl),
          onTap: () => onChanged(!value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(vertical: kSpace2),
              child: Row(
                children: [
                  Icon(icon, color: LudoColors.ink),
                  const SizedBox(width: kSpace4),
                  Expanded(
                    child: Text(
                      label,
                      style: textTheme.bodyLarge?.copyWith(
                        color: LudoColors.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: kSpace3),
                  Switch(
                    key: switchKey,
                    value: value,
                    onChanged: onChanged,
                    activeThumbColor: LudoColors.action,
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
