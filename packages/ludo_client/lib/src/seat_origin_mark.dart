// How a lobby seat came in, drawn as a small glyph on the seat's token disc
// (docs/PROTOCOL.md section 31 item 1, section 33 item 5, section 34 item 1).
// The glyph is never the only signal: the same words are spoken through
// [seatOriginLabel]. It sits on the disc, like the host crown, so it claims
// no width from the name.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'net/snapshot.dart' show SeatState, SeatVia;
import 'theme.dart';

/// The diameter of the paper disc the glyph rides on.
const double kSeatOriginDisc = 14;

/// The route [seat] came by, for its mark. A seat the server plays is a
/// computer seat whatever else it carries, so a computer is never drawn as a
/// person who came by another route.
SeatVia seatOriginOf(SeatState seat) {
  return seat.bot != null ? SeatVia.bot : seat.via;
}

/// The spoken words for [via], or null when the seat shows no mark: the host
/// keeps the crown it already has and an unknown origin says nothing.
String? seatOriginLabel(AppLocalizations loc, SeatVia via) {
  switch (via) {
    case SeatVia.link:
      return loc.seatOriginLink;
    case SeatVia.code:
      return loc.seatOriginCode;
    case SeatVia.approved:
      return loc.seatOriginApproved;
    case SeatVia.public:
      return loc.seatOriginPublic;
    case SeatVia.bot:
      return loc.seatOriginBot;
    case SeatVia.host:
    case SeatVia.unknown:
      return null;
  }
}

/// The mark for [via] on seat [seat]; draws nothing for `host` and `unknown`.
class SeatOriginMark extends StatelessWidget {
  const SeatOriginMark({
    super.key,
    required this.seat,
    required this.via,
    required this.label,
  });

  final int seat;
  final SeatVia via;

  /// What is spoken for the glyph, from [seatOriginLabel].
  final String label;

  @override
  Widget build(BuildContext context) {
    final Color seatColor = LudoColors.seats[seat];
    final Widget glyph = switch (via) {
      SeatVia.link => Icon(Icons.link, size: 10, color: seatColor),
      SeatVia.code => Icon(Icons.dialpad, size: 9, color: seatColor),
      SeatVia.approved => Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: <Widget>[
          Icon(Icons.dialpad, size: 9, color: seatColor),
          PositionedDirectional(
            end: -3,
            bottom: -3,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: LudoColors.paperElevated,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check, size: 8, color: seatColor),
            ),
          ),
        ],
      ),
      SeatVia.public => Icon(Icons.public_rounded, size: 10, color: seatColor),
      SeatVia.bot => Icon(Icons.smart_toy_rounded, size: 10, color: seatColor),
      SeatVia.host || SeatVia.unknown => const SizedBox.shrink(),
    };
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Container(
          width: kSeatOriginDisc,
          height: kSeatOriginDisc,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: LudoColors.paperElevated,
            shape: BoxShape.circle,
          ),
          child: glyph,
        ),
      ),
    );
  }
}
