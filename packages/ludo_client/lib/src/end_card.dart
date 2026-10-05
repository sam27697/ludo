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
import 'net/snapshot.dart' show RematchState;
import 'theme.dart';

/// Built by `GameScreen._gameOverBody`; never constructed from a
/// `RoomController` or a `RoomSnapshot` directly. [winnerSeat] and
/// [winnerName] are already resolved against `room.seats` by the caller: a
/// `room.winner` naming a seat absent from `room.seats` arrives here as
/// `winnerSeat: null`, the same ended variant as a `room.winner` that was
/// null to begin with (contract rule 4).
class EndCard extends StatefulWidget {
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
  /// New table button's own callback. C-246: secondary now that Rematch has
  /// taken the primary spot, except in the [rematchGone] state, where this
  /// is the only action left and becomes primary again.
  final VoidCallback onNewTable;

  /// C-246. `room.rematch`, handed in as-is: null outside a rematch LOBBY,
  /// otherwise the requester and the seats that have accepted so far.
  final RematchState? rematch;

  /// C-246 rule 4's ask line names [rematch]'s own `by` seat; resolved by
  /// the caller against `room.seats` the same way [winnerName] is, rather
  /// than this widget looking seats up itself. Null whenever [rematch] is
  /// null, or when `by` has since left the room.
  final String? rematchByName;

  /// Every occupied seat, in seat order -- `room.seats.map((s) => s.seat)`.
  /// Backs the one ready dot per occupied seat C-246 rule 4 asks for.
  /// Empty when the caller has nothing to show (every other EndCard
  /// constructor site that predates C-246).
  final List<int> occupiedSeats;

  /// `controller.isHost`. Gates [onStartReady]: C-246 rule 4's start
  /// button is never shown to a non-host.
  final bool isHost;

  /// C-246 rule 8: the last `rematch` this device sent answered
  /// `NO_SUCH_ROOM`, the room having been reaped. Overrides every other
  /// rematch state: the action area shows only the "table has closed" line
  /// and New table becomes primary again.
  final bool rematchGone;

  /// Sends `rematch`: the one tap that opens a fresh LOBBY from FINISHED,
  /// or accepts one already open. Null disables the control -- while the
  /// caller's own request is already open (C-246 rule 3's no-double-send),
  /// or when the caller has nothing to send to (every call site that
  /// predates C-246).
  final VoidCallback? onRematch;

  /// Host-only: forces the start of a partially-ready rematch LOBBY
  /// (`start_game`, C-246 rule 4). Null hides the control entirely, not
  /// merely disables it: a non-host, or a caller that predates C-246,
  /// never sees this button at all.
  final VoidCallback? onStartReady;

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
    this.rematch,
    this.rematchByName,
    this.occupiedSeats = const <int>[],
    this.isHost = false,
    this.rematchGone = false,
    this.onRematch,
    this.onStartReady,
  });

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
        _actionArea(context, loc),
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
        _actionArea(context, loc),
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
        _actionArea(context, loc),
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

  /// C-246's own action area, replacing the single New table button every
  /// variant used to end on. Decided from the room snapshot alone (rule 4),
  /// read here off plain fields the caller already resolved against it:
  ///
  ///  - [rematchGone] (rule 8) overrides everything else: the table has
  ///    closed, there is nothing left to rematch, and New table is the one
  ///    primary action left.
  ///  - Otherwise, with [rematch] non-null and my own seat already in
  ///    `ready`: the waiting line and the ready dots, plus -- host only,
  ///    at least two ready and not every occupied seat -- the secondary
  ///    Start-with-N button (rule 4's third bullet).
  ///  - With [rematch] non-null and my own seat not in `ready`: the ask
  ///    line naming `by`, and the Rematch key doubling as the one-tap
  ///    accept (rule 4's second bullet).
  ///  - With [rematch] null: the ordinary FINISHED resting state, Rematch
  ///    offered fresh (rule 4's first bullet).
  ///
  /// New table (rule 3) stays present, secondary, in every branch except
  /// the first.
  Widget _actionArea(BuildContext context, AppLocalizations loc) {
    if (widget.rematchGone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            loc.endRematchGone,
            key: const Key('end-card-rematch-gone'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: kSpace3),
          _newTableButton(loc, primary: true),
        ],
      );
    }

    final RematchState? rematch = widget.rematch;
    final int? mySeat = widget.mySeat;
    final bool amReady =
        rematch != null && mySeat != null && rematch.ready.contains(mySeat);

    if (rematch != null && amReady) {
      final bool offerStart =
          widget.isHost &&
          rematch.ready.length >= 2 &&
          rematch.ready.length < widget.occupiedSeats.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            loc.endRematchWaiting,
            key: const Key('end-card-rematch-waiting'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: kSpace2),
          _readyDotsRow(rematch),
          if (offerStart) ...<Widget>[
            const SizedBox(height: kSpace3),
            _startReadyButton(loc, rematch.ready.length),
          ],
          const SizedBox(height: kSpace3),
          _newTableButton(loc, primary: false),
        ],
      );
    }

    if (rematch != null && !amReady) {
      final String byName = widget.rematchByName ?? '';
      final TextStyle? bodyStyle = Theme.of(context).textTheme.bodyLarge;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text.rich(
            TextSpan(
              children: _nameHighlightSpans(
                loc.endRematchAsk(byName),
                byName,
                _seatColor(rematch.by),
                bodyStyle,
              ),
            ),
            key: const Key('end-card-rematch-ask'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: kSpace3),
          _rematchButton(loc),
          const SizedBox(height: kSpace2),
          _newTableButton(loc, primary: false),
        ],
      );
    }

    // Rule 4's first bullet: FINISHED, no rematch LOBBY open yet.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _rematchButton(loc),
        const SizedBox(height: kSpace2),
        _newTableButton(loc, primary: false),
      ],
    );
  }

  /// One ready dot per occupied seat (rule 4's second bullet), seat-coloured
  /// and filled when that seat is in `rematch.ready`, an outline of the
  /// same colour when it is not -- doctrine P9, colour is never the only
  /// signal, so the two states differ in fill, not only in hue. Wrapped
  /// rather than a bare Row so a four-seat room never overflows a narrow
  /// card.
  Widget _readyDotsRow(RematchState rematch) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: kSpace2,
      runSpacing: kSpace2,
      children: <Widget>[
        for (final int seat in widget.occupiedSeats)
          _readyDot(seat, rematch.ready.contains(seat)),
      ],
    );
  }

  Widget _readyDot(int seat, bool ready) {
    final Color seatColor = _seatColor(seat);
    return Container(
      key: Key('end-card-ready-$seat'),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ready ? seatColor : null,
        border: Border.all(color: seatColor, width: 2),
      ),
    );
  }

  /// Rule 3: large, primary, my own seat colour -- a small coloured dot on
  /// the label stands in for a filled background, since the colour has to
  /// land on the painted tree under this key for doctrine P9's
  /// colour-blind-safe check to see it, not only in the button's own
  /// `ButtonStyle`. Doubles as the one-tap rematch accept (rule 4's second
  /// bullet): the key and the callback are the same whichever text is
  /// showing above it.
  Widget _rematchButton(AppLocalizations loc) {
    final Color seatColor = _seatColor(widget.mySeat ?? 0);
    return ElevatedButton.icon(
      key: const Key('end-card-rematch'),
      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      onPressed: widget.onRematch,
      icon: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: seatColor, shape: BoxShape.circle),
      ),
      label: Text(loc.endRematch),
    );
  }

  /// Rule 4's third bullet: host-only, under the waiting line, secondary to
  /// the Rematch/waiting state above it.
  Widget _startReadyButton(AppLocalizations loc, int readyCount) {
    return OutlinedButton(
      key: const Key('end-card-rematch-start'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      onPressed: widget.onStartReady,
      child: Text(loc.endRematchStartReady(readyCount)),
    );
  }

  /// Rule 3 and rule 8: primary (filled) only in the [EndCard.rematchGone]
  /// state, where New table is the one action left; secondary (outlined)
  /// in every other branch, since Rematch now sits where New table's own
  /// primary spot used to be.
  Widget _newTableButton(AppLocalizations loc, {required bool primary}) {
    if (primary) {
      return ElevatedButton(
        key: const Key('game-screen-new-room-button'),
        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: widget.onNewTable,
        child: Text(loc.gameNewRoomButton),
      );
    }
    return OutlinedButton(
      key: const Key('game-screen-new-room-button'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
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
