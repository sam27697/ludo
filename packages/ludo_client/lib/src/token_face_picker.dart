// The face picker drawn on a token when two or more queued faces can move
// it (C-462 D5). LudoBoard anchors [TokenFacePickerBubble]; this file
// does not decide when the picker is open.

import 'package:flutter/widgets.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_cube.dart';
import 'theme.dart';

/// Open scale-and-fade. Closing is not animated (C-462 D5).
const Duration kFacePickerOpen = Duration(milliseconds: 140);

/// Option art. The hit target is [kFacePickerHit], which is what a tap
/// lands on (C-462 D5).
const double kFacePickerArt = 36;

/// Each option's hit target. At least 48 on both axes (C-462 D5).
const double kFacePickerHit = 48;

/// The pointer's box. The tip sits this far past the bubble body.
const double kFacePickerPointer = 8;

/// Gap between the pointer tip and the token's drawn edge (C-462 D5).
const double kFacePickerTipGap = 2;

const double _kPointerWidth = 16;

/// Body padding plus the option row plus the pointer. [LudoBoard] uses
/// this to decide above versus below before the bubble is laid out, so
/// the widget must stay this tall.
const double kFacePickerBubbleHeight =
    kFacePickerPointer + kSpace1 * 2 + kFacePickerHit;

/// Width of a bubble for [faceCount] options in one row. Same number the
/// anchor uses to aim the pointer after the horizontal clamp.
double facePickerBubbleWidth(int faceCount) {
  if (faceCount <= 0) {
    return 0;
  }
  return kSpace1 * 2 + faceCount * kFacePickerHit + (faceCount - 1) * kSpace1;
}

/// What [LudoBoard] is asked to anchor on one of my tokens (C-462 D5).
class TokenFacePick {
  const TokenFacePick({
    required this.token,
    required this.faces,
    required this.seatColor,
    required this.onPick,
  }) : assert(token >= 0 && token <= 3),
       assert(faces.length >= 2);

  /// Index 0..3 of my seat's token.
  final int token;

  /// The faces that can move [token], distinct, in `legalByFace` order.
  final List<int> faces;

  final Color seatColor;

  /// Called with the face. The board does not also deliver the tap.
  final ValueChanged<int> onPick;
}

/// The bubble. [placeBelow] is the anchor's decision (the top edge of the
/// board would have cut the bubble off). [pointerDx] is the token centre
/// measured from the bubble's left, after that same horizontal clamp.
class TokenFacePickerBubble extends StatefulWidget {
  const TokenFacePickerBubble({
    super.key,
    required this.pick,
    required this.placeBelow,
    required this.pointerDx,
    this.hintedFace,
  });

  final TokenFacePick pick;
  final bool placeBelow;
  final double pointerDx;

  /// C-471 D4: the face whose option is drawn with the green outline, or
  /// null when this picker is not on the hinted token. Null leaves every
  /// option as it was.
  final int? hintedFace;

  @override
  State<TokenFacePickerBubble> createState() => _TokenFacePickerBubbleState();
}

class _TokenFacePickerBubbleState extends State<TokenFacePickerBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: kFacePickerOpen);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // C-462 D5: reduced motion shows the bubble at once. It does not
    // skip the bubble.
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced) {
      _controller.value = 1;
      _opened = true;
      return;
    }
    if (!_opened) {
      _opened = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pick(int face) {
    widget.pick.onPick(face);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TokenFacePick pick = widget.pick;
    final double width = facePickerBubbleWidth(pick.faces.length);
    return Semantics(
      key: const Key('board-face-picker'),
      container: true,
      explicitChildNodes: true,
      label: loc.facePickerLabel(pick.token + 1),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final double t = _controller.value;
          return Opacity(
            opacity: t,
            alwaysIncludeSemantics: true,
            child: Transform.scale(
              scale: t,
              alignment: widget.placeBelow
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              child: child,
            ),
          );
        },
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            // C-462 D5: the bubble's own surface is not a face, and the
            // tap must not reach the token under it.
          },
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.placeBelow) _pointer(width, pointsDown: false),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: LudoColors.paperElevated,
                    borderRadius: BorderRadius.circular(kRadiusControl),
                    border: Border.all(color: pick.seatColor, width: 2),
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: LudoColors.ink.withValues(alpha: 0.18),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(kSpace1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (int i = 0; i < pick.faces.length; i++) ...<Widget>[
                          if (i > 0) const SizedBox(width: kSpace1),
                          _option(loc, pick.faces[i], pick.seatColor),
                        ],
                      ],
                    ),
                  ),
                ),
                if (!widget.placeBelow) _pointer(width, pointsDown: true),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Options run in [TokenFacePick.faces] order. A `Row` follows the
  /// ambient `Directionality`, so Arabic mirrors the row without a hand
  /// flip (C-462 D5).
  Widget _option(AppLocalizations loc, int face, Color seatColor) {
    final Widget option = Semantics(
      key: Key('board-face-picker-option-$face'),
      container: true,
      button: true,
      label: loc.facePickerOption(face),
      onTap: () => _pick(face),
      child: GestureDetector(
        excludeFromSemantics: true,
        behavior: HitTestBehavior.opaque,
        onTap: () => _pick(face),
        child: SizedBox(
          width: kFacePickerHit,
          height: kFacePickerHit,
          child: Center(
            child: CustomPaint(
              size: const Size.square(kFacePickerArt),
              painter: _FacePipPainter(face: face, edgeColor: seatColor),
            ),
          ),
        ),
      ),
    );
    // C-471 D4: the outline sits on the option and does not take the tap.
    // Absent unless this face is the hinted one, so every other option
    // keeps the tree it had.
    if (widget.hintedFace != face) {
      return option;
    }
    return Stack(
      key: Key('board-face-picker-hinted-$face'),
      children: <Widget>[
        option,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: LudoColors.success, width: 2.5),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pointer(double width, {required bool pointsDown}) {
    final double rawLeft = widget.pointerDx - _kPointerWidth / 2;
    final double maxLeft = width - _kPointerWidth - kSpace2;
    final double left = maxLeft <= kSpace2
        ? (width - _kPointerWidth) / 2
        : rawLeft.clamp(kSpace2, maxLeft).toDouble();
    // The base stroke would draw a line across the bubble, so the
    // triangle overlaps the edge by the border width. Layout height
    // stays [kFacePickerPointer] (C-462 D5).
    final double overlap = pointsDown ? -2 : 2;
    return SizedBox(
      height: kFacePickerPointer,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: left,
            top: 0,
            width: _kPointerWidth,
            height: kFacePickerPointer,
            child: Transform.translate(
              offset: Offset(0, overlap),
              child: CustomPaint(
                painter: _PointerPainter(
                  fill: LudoColors.paperElevated,
                  edge: widget.pick.seatColor,
                  pointsDown: pointsDown,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FacePipPainter extends CustomPainter {
  const _FacePipPainter({required this.face, required this.edgeColor});

  final int face;
  final Color edgeColor;

  @override
  void paint(Canvas canvas, Size size) {
    paintNumberedDieFace(canvas, size, edgeColor: edgeColor, face: face);
  }

  @override
  bool shouldRepaint(covariant _FacePipPainter oldDelegate) =>
      oldDelegate.face != face || oldDelegate.edgeColor != edgeColor;
}

class _PointerPainter extends CustomPainter {
  const _PointerPainter({
    required this.fill,
    required this.edge,
    required this.pointsDown,
  });

  final Color fill;
  final Color edge;
  final bool pointsDown;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Path path = Path();
    if (pointsDown) {
      path
        ..moveTo(0, 0)
        ..lineTo(w, 0)
        ..lineTo(w / 2, h)
        ..close();
    } else {
      path
        ..moveTo(w / 2, 0)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PointerPainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.edge != edge ||
      oldDelegate.pointsDown != pointsDown;
}
