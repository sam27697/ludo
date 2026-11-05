import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// C-549 D1: how long a wait must last, continuously mounted, before the
/// second line says it is taking longer than usual.
const Duration kWaitingLineSlowAfter = Duration(seconds: 4);

/// One full turn of the mark.
const Duration _kTurn = Duration(milliseconds: 1200);

/// C-565 D1: the size of a wait mark that sits beside a line of text. 18 dp
/// beside 14 sp text at the default scale, growing with the system text
/// scale so the mark never shrinks to a speck next to large text (P9), and
/// capped so it cannot take the row from the words.
double waitingMarkSize(BuildContext context, TextStyle style) {
  final double fs = style.fontSize ?? 14;
  return (MediaQuery.textScalerOf(context).scale(fs) * 18 / 14).clamp(
    18.0,
    40.0,
  );
}

/// A wait that says it is still working: a turning mark beside [text], and
/// once this widget has been mounted for [kWaitingLineSlowAfter] a second
/// line with something the player can check. The count starts at the first
/// mount and a rebuild does not restart it, so a caller keeps this widget at
/// one place in its tree (or gives it a Key) while the state underneath it
/// flips between a pending timer and an attempt in flight.
///
/// With the system's animations removed the mark stays still and the second
/// line still appears: motion is shortened, meaning is not removed (P9).
/// [showMark] false drops the mark for a caller that already draws its own
/// turning indicator.
class WaitingLine extends StatefulWidget {
  const WaitingLine({
    super.key,
    required this.text,
    this.textKey,
    this.style,
    this.showMark = true,
  });

  final String text;

  /// The Key of the Text that carries [text].
  final Key? textKey;

  /// Style of [text]; the mark takes its colour and the second line a
  /// smaller size of it.
  final TextStyle? style;

  final bool showMark;

  @override
  State<WaitingLine> createState() => _WaitingLineState();
}

class _WaitingLineState extends State<WaitingLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: _kTurn,
  );
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(kWaitingLineSlowAfter, () {
      _slowTimer = null;
      if (mounted) {
        setState(() => _slow = true);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool still = MediaQuery.disableAnimationsOf(context);
    if (still) {
      _turn.stop();
      _turn.value = 0;
    } else if (!_turn.isAnimating) {
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final TextStyle line =
        widget.style ??
        textTheme.bodyMedium?.copyWith(color: LudoColors.inkMuted) ??
        const TextStyle(color: LudoColors.inkMuted);
    final TextStyle rendered = DefaultTextStyle.of(context).style.merge(line);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showMark) ...[
              ExcludeSemantics(
                child: RotationTransition(
                  key: const Key('waiting-line-mark'),
                  turns: _turn,
                  child: Icon(
                    Icons.sync_rounded,
                    size: waitingMarkSize(context, rendered),
                    color: line.color ?? LudoColors.inkMuted,
                  ),
                ),
              ),
              const SizedBox(width: kSpace2),
            ],
            Flexible(
              child: Text(
                widget.text,
                key: widget.textKey,
                textAlign: TextAlign.center,
                style: line,
              ),
            ),
          ],
        ),
        if (_slow) ...[
          const SizedBox(height: kSpace2),
          Text(
            loc.connectionSlowLine,
            key: const Key('waiting-line-slow'),
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: LudoColors.inkMuted),
          ),
        ],
      ],
    );
  }
}
