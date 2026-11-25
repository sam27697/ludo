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

/// The top corner radius of every sheet home opens, the same as the kick
/// sheet's.
const double kHomeSheetRadius = 28;

/// The least height of a sheet tile (C-701): a thumb-sized square, never a
/// row of text.
const double kHomeSheetTileMinHeight = 96;

/// Opens a home sheet in the app's own surface: paper, a rounded top, the ink
/// scrim. [dismissible] false keeps it up against back and outside taps (the
/// waiting window); the sheet itself then decides when it closes. The sheet
/// sizes to its content and rises with the keyboard.
Future<T?> showHomeSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    backgroundColor: LudoColors.paperElevated,
    barrierColor: LudoColors.ink.withValues(alpha: 0.45),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(kHomeSheetRadius),
      ),
    ),
    builder: (BuildContext sheetContext) {
      final Widget sheet = Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: builder(sheetContext),
      );
      if (dismissible) {
        return sheet;
      }
      return PopScope<T>(canPop: false, child: sheet);
    },
  );
}

/// Fades its child in once, when it first appears; give it a new key to fade
/// in new content. The child's size is final from the first frame, so a home
/// sheet takes the new height at once while the new content fades in, and a
/// control that fades in is already where it will rest. With reduced motion the child shows at once.
class HomeSheetFadeIn extends StatelessWidget {
  const HomeSheetFadeIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: kMotionShort,
      curve: Curves.easeOut,
      builder: (BuildContext context, double value, Widget? child) =>
          Opacity(opacity: value, child: child),
      child: child,
    );
  }
}

/// The grab mark and the title every home sheet opens with.
class HomeSheetHeader extends StatelessWidget {
  const HomeSheetHeader({super.key, required this.title, this.leading});

  final String title;

  /// A control at the start edge of the title (the computer choice's back
  /// arrow). The title stays centred either way.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: LudoColors.inkMuted.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: kSpace3),
        Row(
          children: <Widget>[
            SizedBox(width: 48, child: leading),
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: textTheme.titleLarge?.copyWith(
                    color: LudoColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
      ],
    );
  }
}

/// One large square tile of a home sheet: a picture above one word. The
/// [emphasised] tile is the default choice and wears the action fill; the
/// other is the quiet gold frame. A press sinks the tile a little, so the tap
/// is seen as well as felt; the caller plays the tick.
class HomeSheetTile extends StatefulWidget {
  const HomeSheetTile({
    super.key,
    required this.picture,
    required this.semanticLabel,
    required this.onTap,
    this.word,
    this.emphasised = false,
  });

  /// What the tile shows above its word: an icon, a numeral with pawns.
  final Widget picture;

  /// The one word under the picture, or none.
  final String? word;

  /// What TalkBack reads for the whole tile.
  final String semanticLabel;
  final VoidCallback onTap;
  final bool emphasised;

  @override
  State<HomeSheetTile> createState() => _HomeSheetTileState();
}

class _HomeSheetTileState extends State<HomeSheetTile> {
  bool _down = false;

  void _setDown(bool down) {
    if (_down != down) {
      setState(() {
        _down = down;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    final Color ink = widget.emphasised ? LudoColors.actionOn : LudoColors.ink;
    final String? word = widget.word;
    final Widget face = IconTheme.merge(
      data: IconThemeData(color: ink, size: 40),
      child: Padding(
        padding: const EdgeInsets.all(kSpace3),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Flexible(
              child: FittedBox(fit: BoxFit.scaleDown, child: widget.picture),
            ),
            if (word != null) ...<Widget>[
              const SizedBox(height: kSpace2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  word,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: textTheme.titleMedium?.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final BorderRadius radius = BorderRadius.circular(kRadiusControl * 1.5);
    final Widget surface = widget.emphasised
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[LudoColors.feltLight, LudoColors.action],
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: LudoColors.feltDeep.withValues(alpha: 0.35),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: face,
          )
        : HomeGoldFrame(radius: kRadiusControl * 1.5, child: face);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(kHomeSheetTileMinHeight, 148)
            : kHomeSheetTileMinHeight;
        return Semantics(
          button: true,
          label: widget.semanticLabel,
          excludeSemantics: true,
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _down ? 0.95 : 1,
            duration: reduce ? Duration.zero : kMotionShort,
            curve: Curves.easeOut,
            child: SizedBox(
              height: side,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: radius,
                  onTap: widget.onTap,
                  onTapDown: (_) => _setDown(true),
                  onTapUp: (_) => _setDown(false),
                  onTapCancel: () => _setDown(false),
                  child: surface,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Two [HomeSheetTile]s side by side, equal width, the gap between them
/// following the reading direction.
class HomeSheetTilePair extends StatelessWidget {
  const HomeSheetTilePair({
    super.key,
    required this.first,
    required this.second,
  });

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: first),
        const SizedBox(width: kSpace3),
        Expanded(child: second),
      ],
    );
  }
}
