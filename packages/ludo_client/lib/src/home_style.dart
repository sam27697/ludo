// C-678: the one look of the home buttons. A light-gold tint over the felt
// backdrop, a soft border that fades out toward the bottom edge and a fill
// that blends into the page instead of sitting on it as a white card. The
// language button, the sound button, create, join, the join field, the
// tagline and the last-game card all go through [HomeGoldFrame].

import 'package:flutter/material.dart';

import 'theme.dart';

/// Pill radius used for the round top buttons.
const double kHomeRadiusPill = 24;

/// Draws the gold-tinted fill and the fading border behind its child.
///
/// [strong] is the heavier tint for the primary action. The border keeps
/// its darkest stretch at the top edge and falls off to almost nothing at
/// the bottom, so the frame reads as light catching a rim, not as a ruled
/// box.
class HomeGoldFrame extends StatelessWidget {
  const HomeGoldFrame({
    super.key,
    required this.child,
    this.radius = kRadiusControl,
    this.strong = false,
  });

  final Widget child;
  final double radius;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: HomeGoldFramePainter(radius: radius, strong: strong),
      child: child,
    );
  }
}

class HomeGoldFramePainter extends CustomPainter {
  const HomeGoldFramePainter({required this.radius, required this.strong});

  final double radius;
  final bool strong;

  static const double stroke = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect body = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final double top = strong ? 0.42 : 0.26;
    final double bottom = strong ? 0.12 : 0.04;
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            LudoColors.gold.withValues(alpha: top),
            LudoColors.gold.withValues(alpha: bottom),
          ],
        ).createShader(rect),
    );
    canvas.drawRRect(
      body.deflate(stroke / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            LudoColors.gold.withValues(alpha: 0.95),
            LudoColors.gold.withValues(alpha: 0.5),
            LudoColors.gold.withValues(alpha: 0.08),
          ],
          stops: const <double>[0.0, 0.45, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(HomeGoldFramePainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.strong != strong;
}

/// Button style that lets [HomeGoldFrame] show through: no fill of its own,
/// no border, ink text. The frame supplies the look; this keeps the Material
/// ink splash and the 48 dp hit box.
ButtonStyle homeGoldButtonStyle({
  double radius = kRadiusControl,
  Size minimumSize = const Size(48, 48),
}) {
  return ButtonStyle(
    backgroundColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    elevation: const WidgetStatePropertyAll<double>(0),
    foregroundColor: const WidgetStatePropertyAll<Color>(LudoColors.ink),
    side: const WidgetStatePropertyAll<BorderSide>(BorderSide.none),
    minimumSize: WidgetStatePropertyAll<Size>(minimumSize),
    shape: WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
    ),
  );
}

/// The frame plus [homeGoldButtonStyle] for the round icon buttons at the top
/// of home.
ButtonStyle homeGoldIconStyle() {
  return homeGoldButtonStyle(radius: kHomeRadiusPill).copyWith(
    fixedSize: const WidgetStatePropertyAll<Size>(Size(48, 48)),
    padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
  );
}
