// The speech bubble a quick message is drawn in: on the board at the
// sender's seat, and as the chips of the quick messages sheet. GameScreen
// decides when a bubble exists and for how long; this file only paints it.
// Contract C-478 D5.2 and D5.4.

import 'package:flutter/material.dart';

import 'theme.dart';

/// How long a bubble stays on the board, reduced motion included.
const Duration kChatBubbleLife = Duration(milliseconds: 2500);

/// Pop-in. C-478 D5.4.
const Duration kChatBubblePop = Duration(milliseconds: 160);

/// The fade-out at the end of [kChatBubbleLife]. C-478 D5.4.
const Duration kChatBubbleFade = Duration(milliseconds: 250);

/// Height of the tail below (or above) a bubble body.
const double kChatTailHeight = 8;

const double _kChatTailWidth = 14;

/// One line on the board: the seat that said it, the resolved text and a
/// start serial. A new [serial] is a new message, including one that
/// replaces another from the same seat still showing. C-478 D5.4.
class BoardChatBubble {
  const BoardChatBubble({
    required this.seat,
    required this.text,
    required this.serial,
  });

  final int seat;
  final String text;
  final int serial;
}

/// Where the tail stands along the body's edge.
enum ChatTailAnchor {
  /// Centred on the body.
  center,

  /// A fixed distance in from the start corner (left in LTR, right in RTL).
  start,
}

/// A rounded body with a small triangular tail on one horizontal edge, as
/// one outline so the border never crosses the base of the tail.
class SpeechBubblePainter extends CustomPainter {
  const SpeechBubblePainter({
    required this.fill,
    required this.border,
    required this.borderWidth,
    required this.radius,
    required this.textDirection,
    this.tailOnTop = false,
    this.tailAnchor = ChatTailAnchor.center,
    this.shadow = false,
  });

  final Color fill;
  final Color border;
  final double borderWidth;
  final double radius;
  final TextDirection textDirection;

  /// True draws the tail above the body, pointing up.
  final bool tailOnTop;
  final ChatTailAnchor tailAnchor;

  /// The soft shadow the face picker carries.
  final bool shadow;

  Path _outline(Size size) {
    final double bodyTop = tailOnTop ? kChatTailHeight : 0;
    final double bodyBottom = size.height - (tailOnTop ? 0 : kChatTailHeight);
    final Rect body = Rect.fromLTRB(
      borderWidth / 2,
      bodyTop + borderWidth / 2,
      size.width - borderWidth / 2,
      bodyBottom - borderWidth / 2,
    );
    final Path path = Path()
      ..addRRect(RRect.fromRectAndRadius(body, Radius.circular(radius)));

    final double fromStart = switch (tailAnchor) {
      ChatTailAnchor.center => size.width / 2,
      ChatTailAnchor.start => radius + _kChatTailWidth / 2 + 2,
    };
    final double cx = textDirection == TextDirection.rtl
        ? size.width - fromStart
        : fromStart;
    final double half = _kChatTailWidth / 2;
    // The base overlaps the body by the border width so the union has no
    // seam where the two shapes meet.
    final double baseY = tailOnTop
        ? body.top + borderWidth
        : body.bottom - borderWidth;
    final double tipY = tailOnTop
        ? borderWidth / 2
        : size.height - borderWidth / 2;
    final Path tail = Path()
      ..moveTo(cx - half, baseY)
      ..lineTo(cx + half, baseY)
      ..lineTo(cx, tipY)
      ..close();
    return Path.combine(PathOperation.union, path, tail);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Path outline = _outline(size);
    if (shadow) {
      canvas.drawShadow(
        outline.shift(const Offset(0, 1)),
        LudoColors.ink.withValues(alpha: 0.45),
        4,
        false,
      );
    }
    canvas.drawPath(outline, Paint()..color = fill);
    canvas.drawPath(
      outline,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = borderWidth
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant SpeechBubblePainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.border != border ||
      oldDelegate.borderWidth != borderWidth ||
      oldDelegate.radius != radius ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.tailOnTop != tailOnTop ||
      oldDelegate.tailAnchor != tailAnchor ||
      oldDelegate.shadow != shadow;
}

/// The bubble the board places at a seat. The root key is
/// `chat-bubble-<seat>`. The board decides the place; this widget owns the
/// pop-in and the fade, and starts over when [serial] changes. C-478 D5.4.
class ChatBubble extends StatefulWidget {
  ChatBubble({
    required this.seat,
    required this.text,
    required this.label,
    required this.serial,
    required this.maxWidth,
    required this.tailOnTop,
  }) : super(key: Key('chat-bubble-$seat'));

  final int seat;
  final String text;

  /// The spoken form: who said it, then the line.
  final String label;
  final int serial;

  /// Five cells.
  final double maxWidth;

  /// True when the body sits below the tail tip (an upper yard).
  final bool tailOnTop;

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: kChatBubbleLife)
      ..forward();
  }

  @override
  void didUpdateWidget(covariant ChatBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same seat keeps this state (the key does not carry the serial). A
    // replacement has to start its life over. C-478 D5.4.
    if (oldWidget.serial != widget.serial) {
      _clock.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final TextDirection direction = Directionality.of(context);
    final Color seatColor =
        LudoColors.seats[widget.seat.clamp(0, LudoColors.seats.length - 1)];
    final TextStyle? style = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: LudoColors.ink, fontWeight: FontWeight.w700);
    return Semantics(
      container: true,
      liveRegion: true,
      label: widget.label,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _clock,
            builder: (BuildContext context, Widget? child) {
              final double ms = _clock.value * kChatBubbleLife.inMilliseconds;
              final double scale = reduced ? 1 : _scaleAt(ms);
              final double opacity = reduced ? 1 : _opacityAt(ms);
              return Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  alignment: widget.tailOnTop
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  child: child,
                ),
              );
            },
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: CustomPaint(
                painter: SpeechBubblePainter(
                  fill: LudoColors.paperElevated,
                  border: seatColor,
                  borderWidth: 2,
                  radius: 12,
                  textDirection: direction,
                  tailOnTop: widget.tailOnTop,
                  shadow: true,
                ),
                child: Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    8,
                    6 + (widget.tailOnTop ? kChatTailHeight : 0),
                    8,
                    6 + (widget.tailOnTop ? 0 : kChatTailHeight),
                  ),
                  child: Text(
                    widget.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: style,
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

/// 0.6 to 1.0 over [kChatBubblePop], easeOutBack. C-478 D5.4.
double _scaleAt(double ms) {
  final double t = (ms / kChatBubblePop.inMilliseconds).clamp(0.0, 1.0);
  return 0.6 + 0.4 * Curves.easeOutBack.transform(t);
}

/// Full until the last [kChatBubbleFade], then down to nothing. C-478 D5.4.
double _opacityAt(double ms) {
  final double fadeStart = (kChatBubbleLife - kChatBubbleFade).inMilliseconds
      .toDouble();
  if (ms <= fadeStart) {
    return 1;
  }
  final double u = ((ms - fadeStart) / kChatBubbleFade.inMilliseconds).clamp(
    0.0,
    1.0,
  );
  return 1 - u;
}
