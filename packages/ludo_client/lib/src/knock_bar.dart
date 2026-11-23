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

/// How long the server holds a knock open (docs/PROTOCOL.md section 31). The
/// ring is full at this much time left and empty at none, so a knock that
/// reaches the host with 20 s left starts at a third.
const int kKnockWindowMs = 60000;

/// The host's approval switch: a pill with a lock glyph, the label and a
/// switch, and under it, while on, one hint line. The switch's value is the
/// server's [value]; a tap sends the opposite through [onChanged] and the
/// pill changes when the snapshot that answers it arrives.
class ApprovalSwitch extends StatelessWidget {
  const ApprovalSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// The in-game form: only as wide as its content and no hint line, so it
  /// can float over a table without taking any of the table's room.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color tint = value ? LudoColors.action : LudoColors.inkMuted;
    return Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
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
                  mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Icon(
                        value ? Icons.lock_person_outlined : Icons.lock_open,
                        size: kSpace5,
                        color: tint,
                      ),
                    ),
                    const SizedBox(width: kSpace2),
                    Flexible(
                      fit: compact ? FlexFit.loose : FlexFit.tight,
                      child: Text(
                        loc.approvalSwitchLabel,
                        maxLines: compact ? 1 : null,
                        overflow: compact ? TextOverflow.ellipsis : null,
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
        if (value && !compact)
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

/// One compact card per open knock, above the seat cards. A card is one
/// 48 dp row plus the drain bar, so three of them leave the seats in view
/// on a 640 dp phone.
/// Plays the `your_turn` cue
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
    return Column(
      key: const Key('knock-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final Knock knock in widget.knocks)
          Padding(
            key: ValueKey<String>('knock-slot-${knock.id}'),
            padding: const EdgeInsets.only(bottom: kSpace1),
            child: _KnockEntrance(
              child: KnockCard(
                key: Key('knock-card-${knock.id}'),
                knock: knock,
                onAnswer: (bool accept) => widget.onAnswer(knock.id, accept),
              ),
            ),
          ),
      ],
    );
  }
}

/// A card fades up when it first appears. It never travels: the door switch
/// sits directly above the first card, so a card painted off its laid-out
/// place would cross it, and a target is never somewhere other than where it
/// is hit-tested.
class _KnockEntrance extends StatelessWidget {
  const _KnockEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: kMotionShort,
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double t, Widget? child) {
        return Opacity(opacity: t, child: child);
      },
      child: child,
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
  /// 0 at the time the server last reported, 1 when it runs out. The server
  /// closes the knock; the ring only shows its clock.
  late final AnimationController _drain;
  late int _startMs;

  @override
  void initState() {
    super.initState();
    _startMs = math.max(1, widget.knock.expiresMs);
    _drain = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _startMs),
    )..forward();
  }

  @override
  void didUpdateWidget(KnockCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.knock.expiresMs != widget.knock.expiresMs) {
      // A newer snapshot of the same knock carries the time left at that
      // moment; the server's clock wins over the one this card has run.
      _startMs = math.max(1, widget.knock.expiresMs);
      _drain.duration = Duration(milliseconds: _startMs);
      _drain.forward(from: 0);
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
        padding: const EdgeInsetsDirectional.only(
          start: kSpace3,
          end: kSpace2,
          top: kSpaceTight,
          bottom: kSpace1,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                AnimatedBuilder(
                  animation: _drain,
                  builder: (BuildContext context, Widget? child) {
                    final double leftMs = (1 - _drain.value) * _startMs;
                    final double fraction = (leftMs / kKnockWindowMs).clamp(
                      0.0,
                      1.0,
                    );
                    final int seconds = (leftMs / 1000).ceil();
                    return Semantics(
                      label: loc.knockSecondsLeft(
                        material.formatDecimal(seconds),
                      ),
                      child: ExcludeSemantics(
                        child: SizedBox.square(
                          dimension: kKnockRingSize,
                          child: CircularProgressIndicator(
                            key: Key('knock-ring-$id'),
                            value: fraction,
                            strokeWidth: 5,
                            strokeCap: StrokeCap.round,
                            color: LudoColors.action,
                            backgroundColor: LudoColors.inkMuted.withValues(
                              alpha: 0.2,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: kSpace3),
                Expanded(
                  child: Semantics(
                    label: loc.knockWantsToJoin(widget.knock.name),
                    excludeSemantics: true,
                    child: Text(
                      widget.knock.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        color: LudoColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: kSpace2),
                _KnockTarget(
                  targetKey: Key('knock-reject-$id'),
                  icon: Icons.close_rounded,
                  label: loc.knockReject,
                  background: LudoColors.error,
                  foreground: Colors.white,
                  onTap: () => widget.onAnswer(false),
                ),
                const SizedBox(width: kSpace2),
                _KnockTarget(
                  targetKey: Key('knock-accept-$id'),
                  icon: Icons.check_rounded,
                  label: loc.knockAccept,
                  background: LudoColors.success,
                  foreground: LudoColors.ink,
                  onTap: () => widget.onAnswer(true),
                ),
              ],
            ),
            const SizedBox(height: kSpaceTight),
            AnimatedBuilder(
              animation: _drain,
              builder: (BuildContext context, Widget? child) {
                final double leftMs = (1 - _drain.value) * _startMs;
                return KnockDrainBar(
                  fraction: (leftMs / kKnockWindowMs).clamp(0.0, 1.0),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A round target holding a shape (check or cross), never a colour alone,
/// named for TalkBack by its label. [kKnockTargetSize] square at any text
/// scale, because it holds no text that could grow.
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
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Material(
          key: targetKey,
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: kKnockTargetSize,
              child: Icon(icon, color: foreground, size: kSpace6),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin bar under a knock that shortens as the time runs out, anchored at
/// the reading start so it mirrors in Arabic. It says the same thing as the
/// ring in a second shape, for anyone who does not read the ring.
class KnockDrainBar extends StatelessWidget {
  const KnockDrainBar({super.key, required this.fraction});

  /// 1 with the whole window left, 0 with none.
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: kSpace1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: LudoColors.inkMuted.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(kSpace1),
          ),
          child: FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: LudoColors.action,
                borderRadius: BorderRadius.circular(kSpace1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
