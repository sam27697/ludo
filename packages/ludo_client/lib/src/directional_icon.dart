import 'package:flutter/material.dart';

/// Contract C-286 rule 3: draws an [Icon] mirrored on the x axis when the
/// ambient [Directionality] is RTL and plain when LTR.
class DirectionalIcon extends StatelessWidget {
  const DirectionalIcon(
    this.icon, {
    super.key,
    this.size,
    this.fill,
    this.weight,
    this.grade,
    this.opticalSize,
    this.color,
    this.shadows,
    this.semanticLabel,
    this.textDirection,
    this.applyTextScaling,
  });

  final IconData? icon;
  final double? size;
  final double? fill;
  final double? weight;
  final double? grade;
  final double? opticalSize;
  final Color? color;
  final List<Shadow>? shadows;
  final String? semanticLabel;
  final TextDirection? textDirection;
  final bool? applyTextScaling;

  @override
  Widget build(BuildContext context) {
    final Widget iconWidget = Icon(
      icon,
      size: size,
      fill: fill,
      weight: weight,
      grade: grade,
      opticalSize: opticalSize,
      color: color,
      shadows: shadows,
      semanticLabel: semanticLabel,
      textDirection: textDirection,
      applyTextScaling: applyTextScaling,
    );
    final TextDirection? direction =
        textDirection ?? Directionality.maybeOf(context);
    if (direction == TextDirection.rtl) {
      return Transform.flip(flipX: true, child: iconWidget);
    }
    return iconWidget;
  }
}
