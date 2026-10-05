// C-254: the two card shapes the lobby's seat grid is built from. One
// widget per occupied seat (rule 1), one per seat nobody has taken yet
// (rule 2). Neither touches the network or a controller; both render
// exactly what they are handed.

import 'package:flutter/material.dart';

import 'net/snapshot.dart' show SeatState;
import 'theme.dart';

/// Every card in the lobby grid is at least this tall (C-254 rule 3).
const double kSeatCardMinHeight = 56;

/// C-254 rule 1: one occupied seat. A rounded tile tinted in the seat's
/// colour with a filled token disc at its start, the player's name with
/// ellipsis, a "You" chip on the local seat, a crown on the host's seat,
/// and a dimmed, wifi-off-marked card when that seat's player has dropped.
class SeatCard extends StatelessWidget {
  const SeatCard({
    super.key,
    required this.seat,
    required this.isMine,
    required this.isHost,
    required this.youLabel,
  });

  final SeatState seat;
  final bool isMine;
  final bool isHost;
  final String youLabel;

  @override
  Widget build(BuildContext context) {
    final Color seatColor = LudoColors.seats[seat.seat];
    final bool offline = !seat.connected;
    final Color tileColor = offline
        ? LudoColors.inkMuted.withValues(alpha: 0.08)
        : seatColor.withValues(alpha: 0.16);
    final Color nameColor = offline ? LudoColors.inkMuted : LudoColors.ink;

    return Container(
      key: Key('lobby-seat-${seat.seat}'),
      constraints: const BoxConstraints(minHeight: kSeatCardMinHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace3,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        color: tileColor,
        borderRadius: BorderRadius.circular(kRadiusControl),
        // Rule 1's second signal on my own seat: an outline in my own
        // colour on top of the tint, never colour alone (doctrine P9).
        border: isMine ? Border.all(color: seatColor, width: 2) : null,
      ),
      child: Row(
        children: [
          DecoratedBox(
            key: Key('lobby-seat-${seat.seat}-token'),
            decoration: BoxDecoration(color: seatColor, shape: BoxShape.circle),
            child: const SizedBox(width: kSpace6, height: kSpace6),
          ),
          const SizedBox(width: kSpace2),
          Expanded(
            child: Text(
              seat.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: nameColor),
            ),
          ),
          if (isHost) ...[
            const SizedBox(width: kSpace1),
            Icon(
              Icons.emoji_events_outlined,
              key: Key('lobby-seat-${seat.seat}-host'),
              size: kSpace5,
              color: seatColor,
            ),
          ],
          if (isMine) ...[
            const SizedBox(width: kSpace1),
            DecoratedBox(
              key: Key('lobby-seat-${seat.seat}-you'),
              decoration: BoxDecoration(
                color: seatColor,
                borderRadius: BorderRadius.circular(kRadiusControl),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kSpace2,
                  vertical: kSpaceTight,
                ),
                child: Text(
                  youLabel,
                  style:
                      Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: LudoColors.actionOn,
                        fontWeight: FontWeight.w700,
                      ) ??
                      const TextStyle(
                        color: LudoColors.actionOn,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ),
          ],
          // Rule 1's last line: a disconnected seat carries its own icon,
          // not only the muted tile and text (doctrine P9).
          if (offline) ...[
            const SizedBox(width: kSpace1),
            const Icon(
              Icons.wifi_off,
              size: kSpace5,
              color: LudoColors.inkMuted,
            ),
          ],
        ],
      ),
    );
  }
}

/// C-254 rule 2: a seat nobody has taken yet. Thin outline, neutral
/// colour, an empty disc outline, the shared "waiting for a friend"
/// string. Never tappable: no gesture handler anywhere in this tree.
class OpenSeatCard extends StatelessWidget {
  const OpenSeatCard({super.key, required this.index, required this.label});

  final int index;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('lobby-seat-open-$index'),
      constraints: const BoxConstraints(minHeight: kSeatCardMinHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace3,
        vertical: kSpace2,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadiusControl),
        border: Border.all(
          color: LudoColors.inkMuted.withValues(alpha: 0.45),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: LudoColors.inkMuted.withValues(alpha: 0.6),
                width: 1.4,
              ),
            ),
            child: const SizedBox(width: kSpace6, height: kSpace6),
          ),
          const SizedBox(width: kSpace2),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: LudoColors.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}
