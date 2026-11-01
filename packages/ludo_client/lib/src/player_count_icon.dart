// Contract C-523 D4: how many seats a table has, drawn as that many small
// person figures instead of the word "players". Decorative: the control that
// carries it owns the semantics label.

import 'package:flutter/material.dart';

import 'theme.dart';

/// [count] person figures side by side. Laid out in a directional [Row], so
/// it mirrors in Arabic without a branch.
class PlayerCountIcon extends StatelessWidget {
  const PlayerCountIcon({
    super.key,
    required this.count,
    this.size = 18,
    this.color,
  });

  final int count;
  final double size;

  /// Null reads as [LudoColors.ink].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? LudoColors.ink;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < count; i++)
            Icon(Icons.person_rounded, size: size, color: tint),
        ],
      ),
    );
  }
}
