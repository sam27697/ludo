// The speech bubble a quick message is drawn in: the one line GameScreen
// lays in the header band on every body, and the chips of the quick messages
// sheet and the end card's reply chips. GameScreen decides when a bubble
// exists and for how long; this file only paints it. Contract C-478 D5.2,
// C-485 D5, C-500 D1 and D5.

import 'package:flutter/material.dart';

import 'theme.dart';

/// How long a bubble stays up, reduced motion included.
const Duration kChatBubbleLife = Duration(milliseconds: 2500);

/// Pop-in. C-478 D5.4.
const Duration kChatBubblePop = Duration(milliseconds: 160);

/// The fade-out at the end of [kChatBubbleLife]. C-478 D5.4.
const Duration kChatBubbleFade = Duration(milliseconds: 250);

/// Height of the tail below (or above) a bubble body.
const double kChatTailHeight = 8;

const double _kChatTailWidth = 14;

/// The quick message line: the seat that said it, its display name
/// (resolved by the screen), the resolved text and a start serial. A new
/// [serial] is a new message, including one that replaces the one still
/// showing. C-485 D5.2, C-492 D2.
class EndCardChatLine {
  const EndCardChatLine({
    required this.seat,
    required this.name,
    required this.text,
    required this.serial,
  });

  final int seat;
  final String name;
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

/// One preset as a small speech bubble: paper, a quiet border, a short tail
/// at the bottom start corner. At least 48 dp tall, tail included. Not a
/// Material chip, so it reads as something said rather than a filter. Used
/// by the quick messages sheet and by the end card's reply chips. A button
/// for TalkBack, labelled with its line.
class SpeechChip extends StatelessWidget {
  const SpeechChip({super.key, required this.line, required this.onTap});

  final String line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: LudoColors.ink);
    return Semantics(
      button: true,
      container: true,
      label: line,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: CustomPaint(
            painter: SpeechBubblePainter(
              fill: LudoColors.paperElevated,
              border: LudoColors.inkMuted,
              borderWidth: 1.5,
              radius: 16,
              textDirection: Directionality.of(context),
              tailAnchor: ChatTailAnchor.start,
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                start: kSpace3,
                end: kSpace3,
                bottom: kChatTailHeight,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Align(
                  widthFactor: 1,
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: kSpace3),
                    child: Text(line, style: style),
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

/// The quick message line, drawn by the game screen in the header band on
/// every body: a rounded paper pill with the seat-colour border, one line, the
/// name in w700 then the line in w500. When name and line do not both fit
/// [maxWidth] the line is drawn alone (the border still says who), and when
/// the line alone does not fit it ends in an ellipsis; the label stays the
/// spoken form either way. The root key is `end-card-chat-<seat>`. Pops in and
/// fades out and starts over when [serial] changes. C-485 D5.2, C-492 D1,
/// C-500 D5.
class EndCardChatBubble extends StatefulWidget {
  EndCardChatBubble({
    required this.seat,
    required this.name,
    required this.text,
    required this.label,
    required this.serial,
    required this.maxWidth,
  }) : super(key: Key('end-card-chat-$seat'));

  final int seat;
  final String name;
  final String text;

  /// The spoken form: who said it, then the line.
  final String label;
  final int serial;
  final double maxWidth;

  @override
  State<EndCardChatBubble> createState() => _EndCardChatBubbleState();
}

class _EndCardChatBubbleState extends State<EndCardChatBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: kChatBubbleLife)
      ..forward();
  }

  @override
  void didUpdateWidget(covariant EndCardChatBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    final Color seatColor =
        LudoColors.seats[widget.seat.clamp(0, LudoColors.seats.length - 1)];
    final TextStyle? base = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: LudoColors.ink);
    final TextStyle? nameStyle = base?.copyWith(fontWeight: FontWeight.w700);
    final TextStyle? lineStyle = base?.copyWith(fontWeight: FontWeight.w500);
    final TextSpan withName = TextSpan(
      children: <InlineSpan>[
        TextSpan(text: '${widget.name}: ', style: nameStyle),
        TextSpan(text: widget.text, style: lineStyle),
      ],
    );
    // The name goes before the line is cut. Measured from the real text at
    // the real scale, never by counting characters. C-500 D5.
    final bool showName =
        widget.name.isNotEmpty &&
        _fitsOneLine(
          withName,
          widget.maxWidth - _kChatBubbleChrome,
          Directionality.of(context),
          MediaQuery.textScalerOf(context),
        );
    return Semantics(
      container: true,
      liveRegion: true,
      label: widget.label,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _clock,
          builder: (BuildContext context, Widget? child) {
            final double ms = _clock.value * kChatBubbleLife.inMilliseconds;
            return Opacity(
              opacity: reduced ? 1 : _opacityAt(ms),
              child: Transform.scale(
                scale: reduced ? 1 : _scaleAt(ms),
                child: child,
              ),
            );
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: LudoColors.paperElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: seatColor, width: 2),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: LudoColors.ink.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text.rich(
                  showName
                      ? withName
                      : TextSpan(text: widget.text, style: lineStyle),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The padding either side of the line (the border paints inside it).
const double _kChatBubbleChrome = 2 * 8;

/// True when [span] lays out on one line inside [width].
bool _fitsOneLine(
  TextSpan span,
  double width,
  TextDirection direction,
  TextScaler scaler,
) {
  if (width <= 0) {
    return false;
  }
  final TextPainter painter = TextPainter(
    text: span,
    textDirection: direction,
    textScaler: scaler,
    maxLines: 1,
  )..layout(maxWidth: width);
  final bool fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}
