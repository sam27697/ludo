// Another seat's die, drawn in the middle of that seat's yard, and the
// roll record that sits in the same yard (C-465 D2, D4). The die under
// the board is never this: that one is only the viewer's own.

import 'package:flutter/widgets.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_cube.dart';
import 'roll_tray.dart';
import 'theme.dart';

/// One opponent's die on the board. C-465 D2.
class SeatDie {
  const SeatDie({required this.seat, required this.face, required this.active});

  /// Never the viewer's own seat.
  final int seat;

  /// Null is the idle pose.
  final int? face;

  /// True while [seat] holds the turn: the die is drawn at full opacity.
  final bool active;
}

/// The roll record of one seat, drawn in that seat's yard. C-465 D4.
/// [ownMove] is not a field: a record on the board is never the viewer's
/// own move, so every alive tile reads `trayDie`.
class SeatRollRecord {
  const SeatRollRecord({
    required this.seat,
    required this.faces,
    required this.states,
    required this.seatColor,
  });

  final int seat;
  final List<int> faces;
  final List<TrayDieState> states;
  final Color seatColor;
}

/// The cube for [die], [side] logical pixels. Not a button, and it does
/// not take taps: the board wraps it in [IgnorePointer]. C-465 D2.
class SeatDieView extends StatelessWidget {
  const SeatDieView({
    super.key,
    required this.die,
    required this.name,
    required this.side,
  });

  final SeatDie die;
  final String name;
  final double side;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final int? face = die.face;
    final bool idle = face == null;
    final String label = idle
        ? loc.seatDieIdle(name)
        : loc.seatDieFace(name, face);
    final Key poseKey = idle
        ? Key('board-seat-die-idle-${die.seat}')
        : Key('board-seat-die-face-${die.seat}-$face');
    return Opacity(
      opacity: die.active ? 1 : 0.45,
      child: Semantics(
        key: Key('board-seat-die-${die.seat}'),
        container: true,
        button: false,
        label: label,
        child: SizedBox(
          width: side,
          height: side,
          child: KeyedSubtree(
            key: poseKey,
            child: DieCube(
              size: side,
              rotation: idle ? kIdleDieRotation : restingRotationFor(face),
              edgeColor: LudoColors.seats[die.seat.clamp(0, 3)],
            ),
          ),
        ),
      ),
    );
  }
}

/// [record] scaled into the box the board gives it (one yard row).
/// [RollTray.fitWidth] is the width the tray would have if its 48dp slot
/// were scaled down to this box's height, so the C-420 fit check still
/// decides grouping, and [FittedBox] then does the scale. C-465 D4.
class SeatYardRecord extends StatelessWidget {
  const SeatYardRecord({super.key, required this.record});

  final SeatRollRecord record;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double slotW = constraints.maxWidth;
          final double slotH = constraints.maxHeight;
          final double budget = slotH <= 0
              ? slotW
              : slotW * kRollTraySlot / slotH;
          return FittedBox(
            fit: BoxFit.scaleDown,
            child: RollTray(
              faces: record.faces,
              states: record.states,
              seatColor: record.seatColor,
              fitWidth: budget,
            ),
          );
        },
      ),
    );
  }
}
