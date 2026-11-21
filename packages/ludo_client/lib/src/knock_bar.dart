// The host's side of guest approval (docs/PROTOCOL.md section 31): the switch
// beside the room code and one card per person who typed the code and waits at
// the door. Nothing here decides anything. The server's snapshot says whether
// approval is on and who is waiting; a tap only sends an intention and the
// next snapshot is what is drawn.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'feedback.dart';
import 'net/snapshot.dart' show Knock;
import 'theme.dart';

/// Every target on a knock card is at least this tall and wide (doctrine P9).
const double kKnockTargetSize = 48;

/// The diameter of the draining ring on a knock card.
const double kKnockRingSize = 40;

/// The host's approval switch: a pill with a lock glyph, the label and a
/// switch, and under it, while on, one hint line. The switch's value is the
/// server's [value]; a tap sends the opposite through [onChanged] and the
/// pill changes when the snapshot that answers it arrives.
class ApprovalSwitch extends StatelessWidget {
  const ApprovalSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color tint = value ? LudoColors.action : LudoColors.inkMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Material(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(kRadiusControl),
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadiusControl),
            onTap: () => onChanged(!value),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kKnockTargetSize),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: kSpace3,
                  end: kSpace2,
                ),
                child: Row(
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Icon(
                        value ? Icons.lock_person_outlined : Icons.lock_open,
                        size: kSpace5,
                        color: tint,
                      ),
                    ),
                    const SizedBox(width: kSpace2),
                    Expanded(
                      child: Text(
                        loc.approvalSwitchLabel,
                        style: textTheme.bodyMedium?.copyWith(
                          color: LudoColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Switch(
                      key: const Key('approval-switch'),
                      value: value,
                      onChanged: onChanged,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (value)
          Padding(
            key: const Key('approval-hint'),
            padding: const EdgeInsetsDirectional.only(
              top: kSpace1,
              start: kSpace3,
              end: kSpace3,
            ),
            child: Text(
              loc.approvalSwitchHint,
              style: textTheme.bodySmall?.copyWith(color: LudoColors.inkMuted),
            ),
          ),
      ],
    );
  }
}

/// One card per open knock, above the seat cards. Plays the `your_turn` cue
/// once for each knock id it has not shown before, through the one feedback
/// service; no other pattern is used.
class KnockBar extends StatefulWidget {
  const KnockBar({super.key, required this.knocks, required this.onAnswer});

  final List<Knock> knocks;

  /// Sends `answer_knock`: the knock id and whether the host accepted.
  final void Function(String knockId, bool accept) onAnswer;

  @override
  State<KnockBar> createState() => _KnockBarState();
}

class _KnockBarState extends State<KnockBar> {
  final Set<String> _seen = <String>{};

  void _announceNew() {
    final List<Knock> fresh = <Knock>[
      for (final Knock knock in widget.knocks)
        if (!_seen.contains(knock.id)) knock,
    ];
    if (fresh.isEmpty) {
      return;
    }
    _seen.addAll(fresh.map((Knock knock) => knock.id));
    FeedbackScope.of(context).play(FeedbackCue.yourTurn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _announceNew();
  }

  @override
  void didUpdateWidget(KnockBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _announceNew();
  }

  @override
  Widget build(BuildContext context) {
    final bool still = MediaQuery.disableAnimationsOf(context);
    final Widget column = Column(
      key: const Key('knock-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final Knock knock in widget.knocks)
          Padding(
            key: ValueKey<String>('knock-slot-${knock.id}'),
            padding: const EdgeInsets.only(bottom: kSpace2),
            child: KnockCard(
              key: Key('knock-card-${knock.id}'),
              knock: knock,
              onAnswer: (bool accept) => widget.onAnswer(knock.id, accept),
            ),
          ),
      ],
    );
    // AnimatedSize asserts on a zero duration, so under reduced motion the
    // bar simply is or is not there.
    return still
        ? column
        : AnimatedSize(
            duration: kMotionShort,
            alignment: Alignment.topCenter,
            child: column,
          );
  }
}

/// A person waiting at the door: the name large, a ring that drains with the
/// time the server gave, a green Accept (check) and a red Reject (cross).
class KnockCard extends StatefulWidget {
  const KnockCard({super.key, required this.knock, required this.onAnswer});

  final Knock knock;
  final ValueChanged<bool> onAnswer;

  @override
  State<KnockCard> createState() => _KnockCardState();
}

class _KnockCardState extends State<KnockCard>
    with SingleTickerProviderStateMixin {
  /// The ring is full at 0 and empty at 1, over the knock's whole life as
  /// first seen. The server closes the knock; the ring only shows its clock.
  late final AnimationController _drain;
  late final int _totalMs;

  @override
  void initState() {
    super.initState();
    _totalMs = math.max(1, widget.knock.expiresMs);
    _drain = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _totalMs),
    )..forward();
  }

  @override
  void didUpdateWidget(KnockCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.knock.expiresMs != widget.knock.expiresMs) {
      // A newer snapshot of the same knock carries the time left at that
      // moment; the server's clock wins over the one this card has run.
      final double left = (widget.knock.expiresMs / _totalMs).clamp(0.0, 1.0);
      _drain.value = 1 - left;
      _drain.forward();
    }
  }

  @override
  void dispose() {
    _drain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final MaterialLocalizations material = MaterialLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String id = widget.knock.id;
    return Material(
      color: LudoColors.paperElevated,
      elevation: 3,
      borderRadius: BorderRadius.circular(kRadiusControl),
      child: Padding(
        padding: const EdgeInsets.all(kSpace3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                AnimatedBuilder(
                  animation: _drain,
                  builder: (BuildContext context, Widget? child) {
                    final double left = 1 - _drain.value;
                    final int seconds = (left * _totalMs / 1000).ceil();
                    return Semantics(
                      label: loc.knockSecondsLeft(
                        material.formatDecimal(seconds),
                      ),
                      child: ExcludeSemantics(
                        child: CustomPaint(
                          key: Key('knock-ring-$id'),
                          size: const Size.square(kKnockRingSize),
                          painter: _KnockRingPainter(
                            fraction: left,
                            color: LudoColors.action,
                            track: LudoColors.inkMuted.withValues(alpha: 0.2),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: kSpace3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.knock.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleLarge?.copyWith(
                          color: LudoColors.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        loc.knockWantsToJoin(widget.knock.name),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: LudoColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: kSpace3),
            Row(
              children: <Widget>[
                Expanded(
                  child: _KnockTarget(
                    targetKey: Key('knock-reject-$id'),
                    icon: Icons.close_rounded,
                    label: loc.knockReject,
                    background: LudoColors.error,
                    foreground: Colors.white,
                    onTap: () => widget.onAnswer(false),
                  ),
                ),
                const SizedBox(width: kSpace3),
                Expanded(
                  child: _KnockTarget(
                    targetKey: Key('knock-accept-$id'),
                    icon: Icons.check_rounded,
                    label: loc.knockAccept,
                    background: LudoColors.success,
                    foreground: LudoColors.ink,
                    onTap: () => widget.onAnswer(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A big rounded target: a shape (check or cross) and one word, never a colour
/// alone. At least [kKnockTargetSize] in both directions at any text scale.
class _KnockTarget extends StatelessWidget {
  const _KnockTarget({
    required this.targetKey,
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final Key targetKey;
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        key: targetKey,
        color: background,
        borderRadius: BorderRadius.circular(kKnockTargetSize),
        child: InkWell(
          borderRadius: BorderRadius.circular(kKnockTargetSize),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kKnockTargetSize,
              minWidth: kKnockTargetSize,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace2,
                vertical: kSpace2,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(icon, color: foreground, size: kSpace6),
                  const SizedBox(width: kSpace1),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
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

/// The ring: a faint full circle and an arc over it that shrinks to nothing,
/// clockwise from the top in both text directions.
class _KnockRingPainter extends CustomPainter {
  const _KnockRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
  });

  final double fraction;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const double stroke = 5;
    final Rect rect = (Offset.zero & size).deflate(stroke / 2);
    final Paint trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, 2 * math.pi, false, trackPaint);
    final Paint arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_KnockRingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}
