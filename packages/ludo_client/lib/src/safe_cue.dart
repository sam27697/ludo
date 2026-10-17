// The pill drawn when a move lands on a shared main-track square and
// captures nothing. GameScreen decides when one of these exists and for
// how long; this file only paints it. Contract C-384.

import 'package:flutter/widgets.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// Why the shared square captured nothing. A pair standing on a safe
/// square is [star], contract C-384 S2.
enum SafeCueReason { star, pair }

/// One safe-landing pill for [LudoBoard] to place on the mover's
/// destination. [progress] is that seat's main-track progress, 0..51.
class SafeCue {
  const SafeCue({
    required this.reason,
    required this.seat,
    required this.progress,
    required this.generation,
    required this.fade,
    this.fading = false,
  });

  final SafeCueReason reason;
  final int seat;
  final int progress;

  /// Changes each time a new pill replaces the old one, so the fade
  /// starts from fully visible instead of continuing the previous one.
  final int generation;

  /// Fade length from the screen's kSafeCueFade, carried here so the
  /// paint can match that constant without a circular import.
  final Duration fade;

  final bool fading;
}

/// Shield plus one short line. Ink on a light chip: this is information,
/// not a legal or illegal move (C-384 S3). Ignores taps. The line is a
/// live region so a screen reader speaks it once when it appears (S7).
class SafeCuePill extends StatelessWidget {
  const SafeCuePill({super.key, required this.cue});

  final SafeCue cue;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final String label = cue.reason == SafeCueReason.star
        ? loc.boardSafeSquareCue
        : loc.boardSafePairCue;
    final Key key = cue.reason == SafeCueReason.star
        ? const Key('board-safe-cue-star')
        : const Key('board-safe-cue-pair');

    return AnimatedOpacity(
      key: ValueKey<int>(cue.generation),
      opacity: cue.fading ? 0 : 1,
      duration: cue.fade,
      child: Semantics(
        key: key,
        container: true,
        liveRegion: true,
        label: label,
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: LudoColors.paperElevated,
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: LudoColors.ink.withValues(alpha: 0.24),
                      blurRadius: 5,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const CustomPaint(
                        size: Size(12, 14),
                        painter: _ShieldPainter(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        style: const TextStyle(
                          color: LudoColors.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.05,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small filled shield, the shape signal on the pill. Kept drawn (not
/// an icon font) so the chip does not depend on the material icon set.
class _ShieldPainter extends CustomPainter {
  const _ShieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Path path = Path()
      ..moveTo(w * 0.14, h * 0.08)
      ..lineTo(w * 0.86, h * 0.08)
      ..quadraticBezierTo(w * 0.98, h * 0.10, w * 0.90, h * 0.46)
      ..quadraticBezierTo(w * 0.76, h * 0.80, w * 0.50, h * 0.98)
      ..quadraticBezierTo(w * 0.24, h * 0.80, w * 0.10, h * 0.46)
      ..quadraticBezierTo(w * 0.02, h * 0.10, w * 0.14, h * 0.08)
      ..close();
    canvas.drawPath(path, Paint()..color = LudoColors.ink);
  }

  @override
  bool shouldRepaint(covariant _ShieldPainter oldDelegate) => false;
}
