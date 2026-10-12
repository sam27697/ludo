// One verify door (C-325 rule 1). Outlined pill leading to the match's
// verification page, shared between the end card and home's last-game entry.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// The verify door (C-325 rule 1): an outlined pill in the felt colour
/// that opens the match's verification page. Quieter than primary actions,
/// louder than a caption, mirrored in Arabic with EdgeInsetsDirectional.
class VerifyRollsButton extends StatelessWidget {
  const VerifyRollsButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool enabled = onPressed != null;
    final Color color = enabled
        ? LudoColors.feltMid
        : LudoColors.inkMuted.withValues(alpha: 0.6);

    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: LudoColors.feltMid,
        disabledForegroundColor: color,
        side: BorderSide(color: color),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusControl),
        ),
        minimumSize: const Size(48, 48),
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: kSpace4,
          vertical: kSpace3,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.verified_outlined, size: 20),
          const SizedBox(width: kSpace2),
          Flexible(
            child: Text(loc.endFairCheck, textAlign: TextAlign.center),
          ),
          const SizedBox(width: kSpace2),
          const Icon(Icons.open_in_new, size: 20),
        ],
      ),
    );
  }
}
