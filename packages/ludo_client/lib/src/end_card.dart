// The end-of-game card (C-243). One widget for all three endings a finished
// room can show -- I won, someone else won, or the room ended with no
// winner to name -- built by `GameScreen._gameOverBody` from plain values.
// This widget never reads `RoomController` itself and never computes
// `GameStats` on its own: every number it shows is a field handed in,
// already computed on the device from frames the screen already held
// (doctrine P9, C-232). The only state this widget owns is the winner's
// one-shot celebration animation.
//
// Doctrine P6: the winner gets a real celebration; the loser gets warmth
// and their own numbers, never a verdict, and no red anywhere. Doctrine P7:
// the fairness line sells "every roll is verifiable" in plain words only;
// casino-style phrasing is forbidden here. Doctrine P8: a raised panel with
// depth and an iconic stat row, not a Material form -- every colour on
// this card is a named `LudoColors` token, never a raw literal.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'game_stats.dart';
import 'theme.dart';

/// Built by `GameScreen._gameOverBody`; never constructed from a
/// `RoomController` or a `RoomSnapshot` directly. [winnerSeat] and
/// [winnerName] are already resolved against `room.seats` by the caller: a
/// `room.winner` naming a seat absent from `room.seats` arrives here as
/// `winnerSeat: null`, the same ended variant as a `room.winner` that was
/// null to begin with (contract rule 4).
class EndCard extends StatefulWidget {
  const EndCard({
    super.key,
    required this.mySeat,
    required this.winnerSeat,
    required this.winnerName,
    required this.seatColors,
    required this.stats,
    required this.verifyUrl,
    required this.onVerify,
    required this.onNewTable,
  });

  /// The seat this device is sitting in, or null for a spectator view.
  final int? mySeat;

  /// The winning seat, already resolved against `room.seats`; null for the
  /// ended variant.
  final int? winnerSeat;

  /// The winning seat's name, present exactly when [winnerSeat] is.
  final String? winnerName;

  /// `LudoColors.seats`, in seat order.
  final List<Color> seatColors;

  /// This seat's numbers for the game just finished. Null when no seat (a
  /// spectator view, or a seat `room.seats` never confirmed) can honestly
  /// own a set of numbers -- C-232's "a wrong number reads worse than
  /// none" extended to "no number at all" rather than inventing a seat.
  final GameStats? stats;

  /// `room.verifyUrl`. Null or empty disables the Check button rather than
  /// hiding it, so the fairness line always has somewhere to point.
  final String? verifyUrl;

  /// Opens [verifyUrl] externally. Unchanged from the pre-card Verify
  /// button's own callback.
  final VoidCallback onVerify;

  /// Leaves this room and opens a fresh table. Unchanged from the pre-card
  /// New table button's own callback. Sits where Rematch (X6) will go.
  final VoidCallback onNewTable;

  @override
  State<EndCard> createState() => _EndCardState();
}

class _EndCardState extends State<EndCard> {
  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool isWinner =
        widget.winnerSeat != null && widget.winnerSeat == widget.mySeat;
    final bool isLoser = widget.winnerSeat != null && !isWinner;

    if (isWinner) {
      return _panel(
        key: const Key('end-card-win'),
        child: _winnerBody(context, loc),
      );
    }
    if (isLoser) {
      return _panel(
        key: const Key('end-card-lose'),
        child: _loserBody(context, loc),
      );
    }
    return _panel(
      key: const Key('end-card-ended'),
      child: _endedBody(context, loc),
    );
  }

  /// Rule 10: a raised rounded panel with depth, not a flat Material form.
  Widget _panel({required Key key, required Widget child}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(kSpace5),
      decoration: BoxDecoration(
        color: LudoColors.paperElevated,
        borderRadius: BorderRadius.circular(kRadiusControl * 1.5),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: LudoColors.ink.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }

  Color _seatColor(int seat) =>
      widget.seatColors[seat.clamp(0, widget.seatColors.length - 1)];

  Widget _winnerBody(BuildContext context, AppLocalizations loc) {
    final Color seatColor = _seatColor(widget.mySeat ?? widget.winnerSeat!);
    final TextStyle? titleStyle = Theme.of(context).textTheme.headlineLarge
        ?.copyWith(color: LudoColors.gold);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Stack(
          alignment: Alignment.center,
          children: <Widget>[
            _Celebration(
              key: const Key('end-card-celebration'),
              goldColor: LudoColors.gold,
              seatColor: seatColor,
            ),
            Text(
              loc.endWinTitle,
              key: const Key('game-screen-winner'),
              textAlign: TextAlign.center,
              style: titleStyle,
            ),
          ],
        ),
        if (widget.stats != null) ...<Widget>[
          const SizedBox(height: kSpace4),
          _statRow(loc, widget.stats!),
        ],
        const SizedBox(height: kSpace4),
        _fairness(context, loc),
        const SizedBox(height: kSpace3),
        _newTableButton(loc),
      ],
    );
  }

  Widget _loserBody(BuildContext context, AppLocalizations loc) {
    final String name = widget.winnerName!;
    final Color seatColor = _seatColor(widget.winnerSeat!);
    final TextStyle? titleStyle = Theme.of(context).textTheme.headlineLarge;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text.rich(
          TextSpan(
            children: _nameHighlightSpans(
              loc.endLoseTitle(name),
              name,
              seatColor,
              titleStyle,
            ),
          ),
          key: const Key('game-screen-winner'),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: kSpace2),
        Text(loc.endLoseNudge, textAlign: TextAlign.center),
        if (widget.stats != null) ...<Widget>[
          const SizedBox(height: kSpace4),
          _statRow(loc, widget.stats!),
        ],
        const SizedBox(height: kSpace4),
        _fairness(context, loc),
        const SizedBox(height: kSpace3),
        _newTableButton(loc),
      ],
    );
  }

  Widget _endedBody(BuildContext context, AppLocalizations loc) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          loc.gameOverEnded,
          key: const Key('game-screen-winner'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: kSpace4),
        _fairness(context, loc),
        const SizedBox(height: kSpace3),
        _newTableButton(loc),
      ],
    );
  }

  /// Rule 5: four tiles when [GameStats.complete] is true, only
  /// `end-card-stat-home` when it is false (C-232: a wrong number reads
  /// worse than none).
  Widget _statRow(AppLocalizations loc, GameStats stats) {
    final Widget homeTile = _statTile(
      key: const Key('end-card-stat-home'),
      icon: Icons.home,
      value: stats.tokensHome,
      label: loc.endStatHome,
    );
    final List<Widget> tiles = stats.complete
        ? <Widget>[
            _statTile(
              key: const Key('end-card-stat-rolls'),
              icon: Icons.casino,
              value: stats.rolls,
              label: loc.endStatRolls,
            ),
            _statTile(
              key: const Key('end-card-stat-sixes'),
              icon: Icons.star,
              value: stats.sixes,
              label: loc.endStatSixes,
            ),
            _statTile(
              key: const Key('end-card-stat-captures'),
              icon: Icons.flash_on,
              value: stats.capturesMade,
              label: loc.endStatCaptures,
            ),
            homeTile,
          ]
        : <Widget>[homeTile];
    // Four tiles (or one, on the gap case) share the card's own width evenly
    // -- `Expanded` rather than the bare spaceEvenly this replaced, so each
    // tile's own text wraps onto a second line under a wide locale or a big
    // text scale instead of pushing the row past the card's edge at an
    // ordinary phone width.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final Widget tile in tiles) Expanded(child: tile),
      ],
    );
  }

  Widget _statTile({
    required Key key,
    required IconData icon,
    required int value,
    required String label,
  }) {
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, color: LudoColors.feltMid),
        const SizedBox(height: kSpace1),
        Text(
          value.toString(),
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        Text(
          label,
          textAlign: TextAlign.center,
          softWrap: true,
          style: const TextStyle(
            fontSize: kTypeLabel,
            color: LudoColors.inkMuted,
          ),
        ),
      ],
    );
  }

  /// Rule 6, on every variant: the fairness line, the Check-the-rolls text
  /// button (key kept: `game-screen-verify-button`), and the info hint.
  Widget _fairness(BuildContext context, AppLocalizations loc) {
    final bool canVerify =
        widget.verifyUrl != null && widget.verifyUrl!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                loc.endFairLine,
                style: const TextStyle(
                  color: LudoColors.inkMuted,
                  fontSize: kTypeLabel,
                ),
              ),
            ),
            IconButton(
              key: const Key('end-card-fair-hint'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: loc.endFairHint,
              icon: const Icon(Icons.info_outline),
              onPressed: () => _showFairHint(context, loc),
            ),
          ],
        ),
        const SizedBox(height: kSpace1),
        TextButton(
          key: const Key('game-screen-verify-button'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: canVerify ? widget.onVerify : null,
          child: Text(loc.endFairCheck),
        ),
      ],
    );
  }

  void _showFairHint(BuildContext context, AppLocalizations loc) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return Padding(
          padding: const EdgeInsets.all(kSpace5),
          child: Text(loc.endFairHint, textAlign: TextAlign.center),
        );
      },
    );
  }

  Widget _newTableButton(AppLocalizations loc) {
    return ElevatedButton(
      key: const Key('game-screen-new-room-button'),
      style: ElevatedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: widget.onNewTable,
      child: Text(loc.gameNewRoomButton),
    );
  }
}

/// Splits [full] (a localised string already carrying [name] once, from
/// `loc.endLoseTitle(name)`) into spans so only [name] carries [nameColor];
/// the rest keeps [baseStyle]. A [name] not found verbatim (should not
/// happen: it is the very string just substituted in) falls back to the
/// whole line in [baseStyle], never a thrown error over cosmetic colour.
List<InlineSpan> _nameHighlightSpans(
  String full,
  String name,
  Color nameColor,
  TextStyle? baseStyle,
) {
  if (name.isEmpty) {
    return <InlineSpan>[TextSpan(text: full, style: baseStyle)];
  }
  final int index = full.indexOf(name);
  if (index < 0) {
    return <InlineSpan>[TextSpan(text: full, style: baseStyle)];
  }
  final String before = full.substring(0, index);
  final String after = full.substring(index + name.length);
  return <InlineSpan>[
    if (before.isNotEmpty) TextSpan(text: before, style: baseStyle),
    TextSpan(
      text: name,
      style: baseStyle?.copyWith(color: nameColor),
    ),
    if (after.isNotEmpty) TextSpan(text: after, style: baseStyle),
  ];
}

/// Rule 2: a burst of gold and seat-colour particles from behind the title,
/// about 1200ms, then still. Runs its one-shot [AnimationController]
/// exactly once per instance -- [_started] guards a later
/// `didChangeDependencies` (a locale toggle, a theme change) from replaying
/// it -- and the controller's own `Ticker` stops itself the moment
/// `forward()` reaches 1.0, so nothing here ever schedules another frame
/// once the burst is done. Doctrine P9: under reduced motion `forward()` is
/// never called at all, so no ticker is ever created for it; the widget
/// shows a static gold glow in that case instead, keeping the meaning
/// (something golden just happened) without the motion.
class _Celebration extends StatefulWidget {
  const _Celebration({
    required Key key,
    required this.goldColor,
    required this.seatColor,
  }) : super(key: key);

  final Color goldColor;
  final Color seatColor;

  @override
  State<_Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<_Celebration>
    with SingleTickerProviderStateMixin {
  static const Duration _burstDuration = Duration(milliseconds: 1200);
  static const double _diameter = 220;

  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _burstDuration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (!MediaQuery.disableAnimationsOf(context)) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return _staticGlow();
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return CustomPaint(
          size: const Size.square(_diameter),
          painter: _BurstPainter(
            progress: _controller.value,
            goldColor: widget.goldColor,
            seatColor: widget.seatColor,
          ),
        );
      },
    );
  }

  Widget _staticGlow() {
    return Container(
      width: _diameter,
      height: _diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[
            widget.goldColor.withValues(alpha: 0.35),
            widget.goldColor.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  const _BurstPainter({
    required this.progress,
    required this.goldColor,
    required this.seatColor,
  });

  final double progress;
  final Color goldColor;
  final Color seatColor;

  static const int _particleCount = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double maxRadius = size.shortestSide / 2;
    final double fade = (1 - progress).clamp(0.0, 1.0);
    final double travel = maxRadius * progress;

    for (int i = 0; i < _particleCount; i++) {
      final double angle = (2 * math.pi * i) / _particleCount;
      final Offset offset =
          center + Offset(math.cos(angle), math.sin(angle)) * travel;
      final Paint paint = Paint()
        ..color = (i.isEven ? goldColor : seatColor).withValues(alpha: fade);
      canvas.drawCircle(offset, 5 + 3 * fade, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.goldColor != goldColor ||
        oldDelegate.seatColor != seatColor;
  }
}
