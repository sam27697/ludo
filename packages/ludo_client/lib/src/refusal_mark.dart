// The outline a refused tap shows when the system asks for no animation
// (C-520 D3). The shakes carry the refusal with motion on; with motion off
// they hold still, so the object wears this for 300 ms instead. It is in the
// tree or it is not: no fade, no scale, no move. Doctrine P9.

import 'package:flutter/widgets.dart';

import 'theme.dart';

/// How long a [RefusalMark] stays up after the refused tap (C-520 D3).
const Duration kRefusalMarkLife = Duration(milliseconds: 300);

/// C-520 D3. The outline a refused tap shows when animations are off.
class RefusalMark extends StatelessWidget {
  const RefusalMark({super.key, required this.shape, this.borderRadius});

  /// BoxShape.circle or BoxShape.rectangle.
  final BoxShape shape;

  /// Used when [shape] is rectangle.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: shape,
            borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
            border: Border.all(color: LudoColors.error, width: 2.5),
          ),
        ),
      ),
    );
  }
}
