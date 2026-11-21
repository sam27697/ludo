// What a person sees after typing the code of a room whose host approves each
// newcomer (docs/PROTOCOL.md section 31 item 3): one full-screen card, a ring
// that drains with the time the server gave, and a way out. The ring is only a
// clock. The server alone ends a knock, and the next frame is what is drawn.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'knock_bar.dart' show KnockDrainBar, kKnockWindowMs;
import 'theme.dart';

/// The diameter of the waiting ring.
const double kKnockWaitingRing = 120;

class KnockWaitingView extends StatefulWidget {
  const KnockWaitingView({
    super.key,
    required this.expiresAtMs,
    required this.onCancel,
    this.now = DateTime.now,
  });

  /// The device clock, in epoch milliseconds, at which the knock runs out:
  /// `KnockState.expiresAtMs`. Null draws a full, still ring.
  final int? expiresAtMs;

  /// Leaves the room route; the controller's own leave sends the withdrawal.
  final VoidCallback onCancel;

  /// The device clock. Tests hand in their own.
  final DateTime Function() now;

  @override
  State<KnockWaitingView> createState() => _KnockWaitingViewState();
}

class _KnockWaitingViewState extends State<KnockWaitingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drain;
  int _leftMs = 1;
  bool get _noClock => widget.expiresAtMs == null;

  @override
  void initState() {
    super.initState();
    final int? expiresAt = widget.expiresAtMs;
    final int leftMs = expiresAt == null
        ? 0
        : math.max(0, expiresAt - widget.now().millisecondsSinceEpoch);
    _leftMs = math.max(1, leftMs);
    _drain = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: math.max(1, leftMs)),
    );
    if (leftMs > 0) {
      _drain.forward();
    } else if (expiresAt != null) {
      _drain.value = 1;
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
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Center(
      key: const Key('knock-waiting'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
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
                  Center(
                    child: AnimatedBuilder(
                      animation: _drain,
                      builder: (BuildContext context, Widget? child) {
                        final double fraction =
                            ((1 - _drain.value) * _leftMs / kKnockWindowMs)
                                .clamp(0.0, 1.0);
                        return SizedBox.square(
                          dimension: kKnockWaitingRing,
                          child: Stack(
                            alignment: Alignment.center,
                            children: <Widget>[
                              SizedBox.square(
                                dimension: kKnockWaitingRing,
                                child: CircularProgressIndicator(
                                  key: const Key('knock-waiting-ring'),
                                  value: _noClock ? 1 : fraction,
                                  strokeWidth: 8,
                                  strokeCap: StrokeCap.round,
                                  color: LudoColors.action,
                                  backgroundColor: LudoColors.inkMuted
                                      .withValues(alpha: 0.2),
                                ),
                              ),
                              child!,
                            ],
                          ),
                        );
                      },
                      child: const SizedBox.square(
                        dimension: kKnockWaitingRing,
                        child: ExcludeSemantics(
                          child: Icon(
                            Icons.hourglass_top_rounded,
                            size: 44,
                            color: LudoColors.inkMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: kSpace4),
                  AnimatedBuilder(
                    animation: _drain,
                    builder: (BuildContext context, Widget? child) {
                      return KnockDrainBar(
                        fraction: _noClock
                            ? 1
                            : (1 - _drain.value) * _leftMs / kKnockWindowMs,
                      );
                    },
                  ),
                  const SizedBox(height: kSpace4),
                  Text(
                    loc.knockWaitingTitle,
                    textAlign: TextAlign.center,
                    style: textTheme.titleLarge?.copyWith(
                      color: LudoColors.ink,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: kSpace5),
                  OutlinedButton(
                    key: const Key('knock-waiting-cancel'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      foregroundColor: LudoColors.ink,
                      side: const BorderSide(color: LudoColors.ink, width: 2),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: widget.onCancel,
                    child: Text(loc.knockWaitingCancel),
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
