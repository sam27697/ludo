import 'package:flutter/material.dart';

/// C-254 / C-276: the diagonal strike an "off" rule chip or card draws over its
/// own icon, on top of the muted colour, so off is never colour alone
/// (doctrine P9).
class RuleOffStrikePainter extends CustomPainter {
  const RuleOffStrikePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.12, size.height * 0.12),
      Offset(size.width * 0.88, size.height * 0.88),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant RuleOffStrikePainter oldDelegate) =>
      oldDelegate.color != color;
}
