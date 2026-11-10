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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'chat_bubble.dart';
import 'feedback.dart';
import 'game_stats.dart';
import 'net/snapshot.dart' show RematchState;
import 'quick_chat.dart';
import 'refusal_mark.dart';
import 'seat_entrance.dart';
import 'seat_mark.dart';
import 'theme.dart';
import 'verify_rolls_button.dart';

/// C-343 rule 1's floor: a name-carrying title never shrinks past this,
/// even at system text scale 2.0. Only ever a ceiling on how far a title
/// already at or above it may fall; a title that starts below it (a body
/// style) is never pushed up to it (rule 3: scale 1.0 does not move).
const double kEndCardTitleMinFontSize = 20;

/// Hosts [EndCard] in the finished body. The action area sits at the bottom
/// of the safe area, on the screen background, outside the scroll. The card
/// (title, stats, fairness line), [trailing] (the board and the roll
/// history) scroll above it.
class EndCardFrame extends StatelessWidget {
  const EndCardFrame({super.key, required this.card, required this.trailing});

  final EndCard card;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    return _EndCardFrameScope(trailing: trailing, child: card);
  }
}

class _EndCardFrameScope extends InheritedWidget {
  const _EndCardFrameScope({required this.trailing, required super.child});

  final Widget trailing;

  static _EndCardFrameScope? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_EndCardFrameScope>();
  }

  @override
  bool updateShouldNotify(_EndCardFrameScope oldWidget) => false;
}

/// C-605 D1: a seat that sat down at the rematch table, as the game screen
/// resolved it. [serial] counts joins, so a second join is a new line even
/// when it names the same seat.
class EndCardJoin {
  const EndCardJoin({
    required this.seat,
    required this.name,
    required this.serial,
  });

  /// 0..3, the seat whose colour disc and mark the line carries.
  final int seat;

  /// The label the room shows for that seat.
  final String name;

  final int serial;
}

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

  /// Total squares remaining for this seat to reach home when the game ended
  /// (C-307), summed across all four tokens. Yard tokens count 58 squares
  /// (one to enter and 57 home). Computed from final tokens rather than the
  /// transcript, so it is right even with a frame gap (C-232). Null when no
  /// seat matched (spectator view or unconfirmed seat).
  final int? stepsLeft;

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

  /// C-585: the display label for each seat, the same ones the board chips
  /// show (`seatDisplayNames`). A seat with no entry draws its mark and
  /// state only. Empty by default.
  final Map<int, String> seatNames;

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

  /// C-316 rule 2: names of departed seats, in seat order.
  final List<String> departedNames;

  /// C-316 rule 2: true when every other seat has departed.
  final bool everyoneLeft;

  /// C-316 rule 2: true when rematch.by was a departed seat.
  final bool rematchByDeparted;

  /// C-316 rule 4: true when offline on the end card (failed, closed, or connecting).
  final bool isOffline;

  /// C-485 D5.1: the ids of the one-tap reply chips under the panel, in
  /// order. Empty draws nothing. The caller picks them by variant and passes
  /// none when a reply has nowhere to go.
  final List<String> quickReplies;

  /// A chip tap, with its id. Null draws the chips disabled at 38 %.
  final void Function(String id)? onQuickReply;

  /// True while this device's quick message cooldown runs: the chips draw at
  /// 38 % and a tap plays the invalid-tap cue and sends nothing.
  final bool quickReplyCooling;

  /// C-591 D1: the seat that hosts the room, as the caller knows it. With
  /// it, a seat that has not tapped Play again is told when the host could
  /// start the next game without it. Null keeps the card exactly as it was.
  final int? hostSeat;

  /// C-540 D3: handed the fair-hint sheet's own route when it builds, so the
  /// game screen can close that sheet when a frame changes the screen under
  /// it. Null draws the sheet the same and tracks nothing.
  final void Function(Route<void> route)? onFairHintRoute;

  /// C-605 D1: the seat that has just sat down at the rematch table, shown as
  /// a line above the ready chips while the caller holds it. Null draws no
  /// line. The caller owns the line's lifetime.
  final EndCardJoin? friendJoined;

  const EndCard({
    super.key,
    required this.mySeat,
    required this.winnerSeat,
    required this.winnerName,
    required this.seatColors,
    required this.stats,
    this.stepsLeft,
    required this.verifyUrl,
    required this.onVerify,
    required this.onNewTable,
    this.rematch,
    this.rematchByName,
    this.occupiedSeats = const <int>[],
    this.seatNames = const <int, String>{},
    this.isHost = false,
    this.rematchGone = false,
    this.onRematch,
    this.onStartReady,
    this.departedNames = const <String>[],
    this.everyoneLeft = false,
    this.rematchByDeparted = false,
    this.isOffline = false,
    this.quickReplies = const <String>[],
    this.onQuickReply,
    this.quickReplyCooling = false,
    this.onFairHintRoute,
    this.hostSeat,
    this.friendJoined,
  });

  @override
  State<EndCard> createState() => _EndCardState();
}

class _EndCardState extends State<EndCard> with SingleTickerProviderStateMixin {
  /// C-555 D3: how long a New table that has just replaced Play again takes
  /// no tap, measured from the first frame it is drawn.
  static const Duration _kNewTableGuard = Duration(milliseconds: 600);

  /// C-555 D3: the fade-in at the start of that guard.
  static const Duration _kNewTableFade = Duration(milliseconds: 250);

  /// Runs for [_kNewTableGuard] when the primary New table replaces Play
  /// again on a card already on screen, and is otherwise at rest at 1. It is
  /// guarding exactly while it is animating. Started from `didUpdateWidget`,
  /// during the build, so its clock is the frame that first draws the button.
  late final AnimationController _newTableGuard = AnimationController(
    vsync: this,
    duration: _kNewTableGuard,
    value: 1,
  );

  /// C-555 D4: false for the card's first build, true for every build after.
  /// A line that comes into a card already on screen fades in; the lines a
  /// card is first drawn with do not.
  bool _onScreen = false;

  /// What `_onScreen` was when the current build began. A `LayoutBuilder`
  /// inside the card runs after the build has finished, so the lines read
  /// this field, never `_onScreen`.
  bool _arriving = false;

  /// C-605 D1: the seats occupied when the previous build ran, and the ones
  /// that were not: a ready chip for a seat in [_freshSeats] enters with a
  /// [SeatEntrance]. Both are read by the chips during the build that sets
  /// them.
  Set<int> _builtSeats = <int>{};
  Set<int> _freshSeats = <int>{};

  /// True while the finished scroll still has content below the viewport,
  /// so the dock can show a soft top shadow. False when the scroll is at
  /// its end or the column fits, which keeps a short card from growing a
  /// footer line (C-398).
  bool _contentUnderAction = false;

  void _noteContentUnderAction(ScrollMetrics metrics) {
    final bool under = metrics.maxScrollExtent > metrics.pixels + 0.5;
    if (under == _contentUnderAction) {
      return;
    }
    _contentUnderAction = under;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(EndCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_primaryNewTable(widget)) {
      _newTableGuard.value = 1;
    } else if (!_primaryNewTable(oldWidget) && _showsPlayAgain(oldWidget)) {
      _newTableGuard.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _newTableGuard.dispose();
    super.dispose();
  }

  /// Whether [w] draws New table as the one primary action (C-246 rules 3
  /// and 8): the table closed, or everyone else gone.
  static bool _primaryNewTable(EndCard w) => w.rematchGone || w.everyoneLeft;

  /// Whether [w] draws `end-card-rematch`, mirroring the branches of
  /// `_actionArea`: every branch but the closed table, everyone gone, and
  /// my own rematch already sent (the waiting line has no Play again).
  static bool _showsPlayAgain(EndCard w) {
    if (_primaryNewTable(w)) {
      return false;
    }
    if (w.isOffline) {
      return true;
    }
    final RematchState? rematch = w.rematch;
    final int? mySeat = w.mySeat;
    return !(rematch != null &&
        mySeat != null &&
        rematch.ready.contains(mySeat));
  }

  @override
  Widget build(BuildContext context) {
    _arriving = _onScreen;
    _onScreen = true;
    final Set<int> occupied = widget.occupiedSeats.toSet();
    _freshSeats = _arriving ? occupied.difference(_builtSeats) : <int>{};
    _builtSeats = occupied;
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool isWinner =
        widget.winnerSeat != null && widget.winnerSeat == widget.mySeat;
    final bool isLoser = widget.winnerSeat != null && !isWinner;
    final Key panelKey = isWinner
        ? const Key('end-card-win')
        : isLoser
        ? const Key('end-card-lose')
        : const Key('end-card-ended');
    final _EndCardFrameScope? frame = _EndCardFrameScope.maybeOf(context);
    final Widget upper = isWinner
        ? _winnerBody(context, loc, includeAction: frame == null)
        : isLoser
        ? _loserBody(context, loc, includeAction: frame == null)
        : _endedBody(context, loc, includeAction: frame == null);
    final Widget? replies = _quickReplyChips(loc);
    // Without a frame (a card mounted on its own, inside someone else's
    // scroll) the action stays in the panel, where those callers measured it.
    if (frame == null) {
      return replies == null
          ? _panel(key: panelKey, child: upper)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _panel(key: panelKey, child: upper),
                const SizedBox(height: kSpace3),
                replies,
              ],
            );
    }
    // C-398 defect 1's lever: the dock holds Play again (or whichever
    // control is the one next step -- the waiting line, the ask, the gone
    // state) and nothing else. New table, when it is only ever the
    // secondary control here, rides up into the scroll with the rest of
    // the card instead of adding its own row to the dock. That keeps the
    // dock down to one button's height, so on a short phone at 1.0 the
    // fairness line and its verify button are still inside the scroll
    // viewport rather than clipped off behind the dock (P7). When New
    // table is the only action left (rematchGone, everyoneLeft) it is
    // already the one next step and stays in the dock, primary, same as
    // before.
    final Widget? scrolledNewTable = widget.rematchGone || widget.everyoneLeft
        ? null
        : _newTableButton(loc, primary: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (ScrollMetricsNotification notification) {
              _noteContentUnderAction(notification.metrics);
              return false;
            },
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(kSpace4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _panel(key: panelKey, child: upper),
                  if (replies != null) ...<Widget>[
                    const SizedBox(height: kSpace3),
                    replies,
                  ],
                  if (scrolledNewTable != null) ...<Widget>[
                    const SizedBox(height: kSpace3),
                    scrolledNewTable,
                  ],
                  frame.trailing,
                ],
              ),
            ),
          ),
        ),
        _actionDock(_actionArea(context, loc, includeSecondaryNewTable: false)),
      ],
    );
  }

  /// C-485 D5.1: the reply chips, one centred Wrap, or null for none. C-498
  /// D3: normal chips when they fit one row, else compact chips when those
  /// do, else normal chips wrapping. Widths come from the real chip.
  Widget? _quickReplyChips(AppLocalizations loc) {
    if (widget.quickReplies.isEmpty) {
      return null;
    }
    final List<(String, String)> chips = <(String, String)>[
      for (final String id in widget.quickReplies)
        if (quickChatLine(loc, id) case final String line) (id, line),
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        double row(bool compact, double gap) {
          double sum = gap * (chips.length - 1);
          for (final (String, String) chip in chips) {
            sum += SpeechChip.naturalWidth(context, chip.$2, compact: compact);
          }
          return sum;
        }

        final double room = constraints.maxWidth;
        final bool normalFits = row(false, kSpace2) <= room;
        final bool compact = !normalFits && row(true, kSpace1) <= room;
        return Wrap(
          key: const Key('end-card-quick-replies'),
          alignment: WrapAlignment.center,
          spacing: compact ? kSpace1 : kSpace2,
          runSpacing: kSpace2,
          children: <Widget>[
            for (final (String, String) chip in chips)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: room),
                child: _ReplyChip(
                  id: chip.$1,
                  line: chip.$2,
                  compact: compact,
                  dimmed:
                      widget.quickReplyCooling || widget.onQuickReply == null,
                  resting: widget.quickReplyCooling,
                  onSend: widget.quickReplyCooling ? null : widget.onQuickReply,
                ),
              ),
          ],
        );
      },
    );
  }

  /// C-398: the action block on the screen's own background. A shadow only
  /// while scrolled content is still cut off at this edge; no divider.
  Widget _actionDock(Widget action) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: _contentUnderAction
            ? <BoxShadow>[
                BoxShadow(
                  color: LudoColors.ink.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kSpace4, kSpace3, kSpace4, kSpace4),
        child: action,
      ),
    );
  }

  /// Rule 10: a raised rounded panel with depth, not a flat Material form.
  Widget _panel({required Key key, required Widget child}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(kSpace4),
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

  Widget _winnerBody(
    BuildContext context,
    AppLocalizations loc, {
    required bool includeAction,
  }) {
    final Color seatColor = _seatColor(widget.mySeat ?? widget.winnerSeat!);
    final TextStyle? titleStyle = Theme.of(context).textTheme.headlineLarge
        ?.copyWith(color: LudoColors.gold);
    // C-609 D2: rim width is 0.12 of the font size as laid out, so it grows
    // with the text scaler like the glyphs do.
    final double titleSize = MediaQuery.textScalerOf(context).scale(
      titleStyle?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14,
    );
    final TextStyle? outlineStyle = titleStyle?.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = titleSize * 0.12
        ..color = LudoColors.goldInk,
    );
    final Widget? statRow = _statRow(loc, widget.stats);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // C-429 D1: the celebration no longer sets the Stack's layout size.
        // The title (plus kSpace4 above and below) is the only non-positioned
        // child, so the Stack is only as tall as the title needs. The burst
        // stays a full 196 x 196, painted unclipped (`Clip.none`) through a
        // `Positioned.fill` + `OverflowBox` that gives it room to overflow
        // the title's own box without being measured for it, centred on the
        // title by the same `Alignment.center` either way. It is still the
        // first child here, so it still paints behind the title text, same
        // as before; being earlier than the stats row and the fairness block
        // in this column, it paints behind those too.
        Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: OverflowBox(
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                alignment: Alignment.center,
                child: _Celebration(
                  key: const Key('end-card-celebration'),
                  goldColor: LudoColors.gold,
                  seatColor: seatColor,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: kSpace4),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  // C-609: gold alone is 2.02:1 on the card. The same text is
                  // drawn first as a goldInk rim, then the gold fill on top;
                  // both layers share every layout input so the glyphs
                  // coincide at any text scale. TalkBack hears the fill only.
                  ExcludeSemantics(
                    child: Text(
                      loc.endWinTitle,
                      key: const Key('game-screen-winner-outline'),
                      textAlign: TextAlign.center,
                      style: outlineStyle,
                    ),
                  ),
                  Text(
                    loc.endWinTitle,
                    key: const Key('game-screen-winner'),
                    textAlign: TextAlign.center,
                    style: titleStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (statRow != null) ...<Widget>[
          const SizedBox(height: kSpace3),
          statRow,
        ],
        const SizedBox(height: kSpace3),
        _fairness(context, loc),
        if (includeAction) ...<Widget>[
          const SizedBox(height: kSpace3),
          _actionArea(context, loc),
        ],
      ],
    );
  }

  Widget _loserBody(
    BuildContext context,
    AppLocalizations loc, {
    required bool includeAction,
  }) {
    final String name = widget.winnerName!;
    final Color seatColor = _seatColor(widget.winnerSeat!);
    final TextStyle? titleStyle = Theme.of(context).textTheme.headlineLarge;
    final int? stepsLeft = widget.stepsLeft;
    final String loseLine = stepsLeft != null && stepsLeft <= kNearFinishSquares
        ? loc.endLoseNear(stepsLeft)
        : loc.endLoseNudge;
    final String titleText = loc.endLoseTitle(name);
    final Widget? statRow = _statRow(loc, widget.stats);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final TextStyle? fitStyle = _fitTitleFontSize(
              text: titleText,
              base: titleStyle,
              maxWidth: constraints.maxWidth,
              scaler: MediaQuery.textScalerOf(context),
              direction: Directionality.of(context),
              locale: Localizations.maybeLocaleOf(context),
            );
            return Text.rich(
              TextSpan(
                children: _nameHighlightSpans(
                  titleText,
                  name,
                  seatColor,
                  fitStyle,
                ),
              ),
              key: const Key('game-screen-winner'),
              textAlign: TextAlign.center,
            );
          },
        ),
        const SizedBox(height: kSpace2),
        Text(
          loseLine,
          key: const Key('end-card-lose-line'),
          textAlign: TextAlign.center,
        ),
        if (statRow != null) ...<Widget>[
          const SizedBox(height: kSpace3),
          statRow,
        ],
        const SizedBox(height: kSpace3),
        _fairness(context, loc),
        if (includeAction) ...<Widget>[
          const SizedBox(height: kSpace3),
          _actionArea(context, loc),
        ],
      ],
    );
  }

  Widget _endedBody(
    BuildContext context,
    AppLocalizations loc, {
    required bool includeAction,
  }) {
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
        const SizedBox(height: kSpace3),
        _fairness(context, loc),
        if (includeAction) ...<Widget>[
          const SizedBox(height: kSpace3),
          _actionArea(context, loc),
        ],
      ],
    );
  }

  /// Rule 5: four tiles when [GameStats.complete] is true, only
  /// `end-card-stat-home` when it is false (C-232: a wrong number reads
  /// worse than none). C-533 D3: a tile is built only for a value above
  /// zero, so a loser never reads a row of zeros as a verdict; null when
  /// no tile is left, and the caller then builds neither the row nor its gap.
  Widget? _statRow(AppLocalizations loc, GameStats? stats) {
    if (stats == null) {
      return null;
    }
    final List<Widget> tiles = <Widget>[
      if (stats.complete && stats.rolls > 0)
        _statTile(
          key: const Key('end-card-stat-rolls'),
          icon: Icons.casino,
          value: stats.rolls,
          label: loc.endStatRolls(stats.rolls),
        ),
      if (stats.complete && stats.sixes > 0)
        _statTile(
          key: const Key('end-card-stat-sixes'),
          icon: Icons.star,
          value: stats.sixes,
          label: loc.endStatSixes(stats.sixes),
        ),
      if (stats.complete && stats.capturesMade > 0)
        _statTile(
          key: const Key('end-card-stat-captures'),
          icon: Icons.flash_on,
          value: stats.capturesMade,
          label: loc.endStatCaptures(stats.capturesMade),
        ),
      if (stats.tokensHome > 0)
        _statTile(
          key: const Key('end-card-stat-home'),
          icon: Icons.home,
          value: stats.tokensHome,
          label: loc.endStatHome(stats.tokensHome),
        ),
    ];
    if (tiles.isEmpty) {
      return null;
    }
    // Four tiles (or one, on the gap case) share the card's own width evenly
    // via `Expanded`. Each tile's text scales down on a single line under a
    // wide locale or a large text scale, never breaking inside a word or
    // pushing the row past the card's edge. Rule 2 (C-343): a fixed
    // `kSpace2` gutter between every pair, a real empty strip rather than
    // a gap hoped for from the label's own scale-down -- at a large scale
    // the scaled-down label fills its tile edge to edge, so without this
    // the gutter would be zero.
    final List<Widget> row = <Widget>[];
    for (int i = 0; i < tiles.length; i++) {
      if (i > 0) {
        row.add(const SizedBox(width: kSpace2));
      }
      row.add(Expanded(child: tiles[i]));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: row);
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
        // C-436 D1: the icon sits beside its value (icon first in reading
        // order, so it mirrors in Arabic); the label stays under both.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: LudoColors.feltMid),
            const SizedBox(width: kSpace1),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value.toString(),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            style: const TextStyle(
              fontSize: kTypeLabel,
              color: LudoColors.inkMuted,
            ),
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
        Center(
          child: VerifyRollsButton(
            key: const Key('game-screen-verify-button'),
            onPressed: canVerify ? widget.onVerify : null,
          ),
        ),
      ],
    );
  }

  void _showFairHint(BuildContext context, AppLocalizations loc) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final Route<void>? sheetRoute = ModalRoute.of<void>(sheetContext);
        if (sheetRoute != null) {
          widget.onFairHintRoute?.call(sheetRoute);
        }
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
  /// the first. [includeSecondaryNewTable] is C-398 defect 1's lever: the
  /// frame-hosted dock calls this with it false and renders New table in
  /// the scroll instead (see `build`); every other caller -- a bare card
  /// with no frame -- leaves it true and gets New table here, as before.
  Widget _actionArea(
    BuildContext context,
    AppLocalizations loc, {
    bool includeSecondaryNewTable = true,
  }) {
    if (widget.rematchGone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _arrivingLine(
            const ValueKey<String>('fade-gone'),
            Text(
              loc.endRematchGone,
              key: const Key('end-card-rematch-gone'),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: kSpace3),
          _newTableButton(loc, primary: true),
        ],
      );
    }

    if (widget.everyoneLeft) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _arrivingLine(
            const ValueKey<String>('fade-everyone-left'),
            Text(
              loc.endEveryoneLeft,
              key: const Key('end-card-left'),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: kSpace3),
          _newTableButton(loc, primary: true),
        ],
      );
    }

    final String separator =
        Localizations.localeOf(context).languageCode == 'ar' ? '، ' : ', ';
    final bool hasDeparted = widget.departedNames.isNotEmpty;
    final Widget? leftLine = hasDeparted
        ? _arrivingLine(
            const ValueKey<String>('fade-left'),
            Text(
              loc.endLeft(widget.departedNames.join(separator)),
              key: const Key('end-card-left'),
              textAlign: TextAlign.center,
            ),
          )
        : null;

    if (widget.isOffline) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (leftLine != null) ...<Widget>[
            leftLine,
            const SizedBox(height: kSpace2),
          ],
          Text(
            loc.endOffline,
            key: const Key('end-card-offline'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: kSpace3),
          _rematchButton(loc),
          if (includeSecondaryNewTable) ...<Widget>[
            const SizedBox(height: kSpace2),
            _newTableButton(loc, primary: false),
          ],
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
      // C-591 D3: who the host's Start leaves out, in seat order.
      final List<String> sitsOut = !offerStart
          ? const <String>[]
          : <String>[
              for (final int seat in (<int>[...widget.occupiedSeats]..sort()))
                if (!rematch.ready.contains(seat) &&
                    widget.seatNames[seat] != null)
                  widget.seatNames[seat]!,
            ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (leftLine != null) ...<Widget>[
            leftLine,
            const SizedBox(height: kSpace2),
          ],
          Text(
            loc.endRematchWaiting,
            key: const Key('end-card-rematch-waiting'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: kSpace2),
          _friendJoinedSlot(context, loc),
          _readyChipsRow(loc, rematch),
          if (offerStart) ...<Widget>[
            const SizedBox(height: kSpace3),
            if (sitsOut.isNotEmpty) ...<Widget>[
              _sitsOutLine(context, loc, sitsOut, separator),
              const SizedBox(height: kSpace2),
            ],
            _startReadyButton(loc, rematch.ready.length),
          ],
          if (includeSecondaryNewTable) ...<Widget>[
            const SizedBox(height: kSpace3),
            _newTableButton(loc, primary: false),
          ],
        ],
      );
    }

    if (rematch != null && !amReady) {
      // C-591 D2: the host is in and could start now, the same condition
      // under which the host's own card offers Start.
      final int? hostSeat = widget.hostSeat;
      final bool mayStart =
          hostSeat != null &&
          rematch.ready.contains(hostSeat) &&
          rematch.ready.length >= 2;
      final bool hideAsk =
          widget.rematchByDeparted || widget.rematchByName == null;
      if (hideAsk) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (leftLine != null) ...<Widget>[
              leftLine,
              const SizedBox(height: kSpace3),
            ],
            _friendJoinedSlot(context, loc),
            if (mayStart) ...<Widget>[
              _mayStartLine(context, loc),
              const SizedBox(height: kSpace2),
            ],
            _rematchButton(loc),
            if (includeSecondaryNewTable) ...<Widget>[
              const SizedBox(height: kSpace2),
              _newTableButton(loc, primary: false),
            ],
          ],
        );
      }
      final String byName = widget.rematchByName ?? '';
      final TextStyle? bodyStyle = Theme.of(context).textTheme.bodyLarge;
      final String askText = loc.endRematchAsk(byName);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (leftLine != null) ...<Widget>[
            leftLine,
            const SizedBox(height: kSpace2),
          ],
          _arrivingLine(
            const ValueKey<String>('fade-ask'),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final TextStyle? fitStyle = _fitTitleFontSize(
                  text: askText,
                  base: bodyStyle,
                  maxWidth: constraints.maxWidth,
                  scaler: MediaQuery.textScalerOf(context),
                  direction: Directionality.of(context),
                  locale: Localizations.maybeLocaleOf(context),
                );
                return Text.rich(
                  TextSpan(
                    children: _nameHighlightSpans(
                      askText,
                      byName,
                      _seatColor(rematch.by),
                      fitStyle,
                    ),
                  ),
                  key: const Key('end-card-rematch-ask'),
                  textAlign: TextAlign.center,
                );
              },
            ),
          ),
          if (widget.occupiedSeats.length >= 3) ...<Widget>[
            const SizedBox(height: kSpace3),
            _friendJoinedSlot(context, loc),
            _readyChipsRow(loc, rematch),
          ] else
            _friendJoinedSlot(context, loc),
          const SizedBox(height: kSpace3),
          if (mayStart) ...<Widget>[
            _mayStartLine(context, loc),
            const SizedBox(height: kSpace2),
          ],
          _rematchButton(loc),
          if (includeSecondaryNewTable) ...<Widget>[
            const SizedBox(height: kSpace2),
            _newTableButton(loc, primary: false),
          ],
        ],
      );
    }

    // Rule 4's first bullet: FINISHED, no rematch LOBBY open yet.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (leftLine != null) ...<Widget>[
          leftLine,
          const SizedBox(height: kSpace3),
        ],
        _rematchButton(loc),
        if (includeSecondaryNewTable) ...<Widget>[
          const SizedBox(height: kSpace2),
          _newTableButton(loc, primary: false),
        ],
      ],
    );
  }

  /// C-591 D2: the heads-up a seat that is not in yet gets above Play again.
  /// Body style at a heavier weight and the theme's colour: a warning given
  /// early and kindly, not a refusal. A live region, so a screen reader
  /// reads it when it appears.
  Widget _mayStartLine(BuildContext context, AppLocalizations loc) {
    return _arrivingLine(
      const ValueKey<String>('fade-may-start'),
      Semantics(
        liveRegion: true,
        child: Text(
          loc.endRematchMayStartWithout,
          key: const Key('end-card-rematch-may-start'),
          textAlign: TextAlign.center,
          style: _warnStyle(context),
        ),
      ),
    );
  }

  /// C-591 D3: the host's view of who Start leaves out.
  Widget _sitsOutLine(
    BuildContext context,
    AppLocalizations loc,
    List<String> names,
    String separator,
  ) {
    return _arrivingLine(
      const ValueKey<String>('fade-sits-out'),
      Semantics(
        liveRegion: true,
        child: Text(
          loc.endRematchSitsOut(names.join(separator)),
          key: const Key('end-card-rematch-sits-out'),
          textAlign: TextAlign.center,
          style: _warnStyle(context),
        ),
      ),
    );
  }

  TextStyle? _warnStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyLarge
          ?.copyWith(fontWeight: FontWeight.w600);

  /// C-555 D4: [line] fades in over 200 ms when it comes into a card that is
  /// already on screen, and does not on the card's first frame. [key] names
  /// the line, so a line that stays keeps its state when its neighbours come
  /// and go around it.
  Widget _arrivingLine(Key key, Widget line) {
    return _FadeInOnArrival(key: key, fade: _arriving, child: line);
  }

  /// C-585: one ready chip per occupied seat, in seat order. The seat's
  /// [SeatMark] on a disc of its colour, its name, and its state: a ready
  /// chip is filled with a light tint of the seat colour and carries a check
  /// mark, a chip still waiting is an outline with no check mark -- doctrine
  /// P9, the state reads without colour. Wrapped rather than a bare Row so a
  /// four-seat room never overflows a narrow card.
  Widget _readyChipsRow(AppLocalizations loc, RematchState rematch) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: kSpace2,
      runSpacing: kSpace2,
      children: <Widget>[
        for (final int seat in widget.occupiedSeats)
          _readyChip(loc, seat, rematch.ready.contains(seat)),
      ],
    );
  }

  Widget _readyChip(AppLocalizations loc, int seat, bool ready) {
    final Color seatColor = _seatColor(seat);
    final String? name = seat == widget.mySeat
        ? loc.seatYou
        : widget.seatNames[seat];
    final String label = ready
        ? loc.endRematchSeatReady(name ?? '')
        : loc.endRematchSeatWaiting(name ?? '');
    final Widget chip = Semantics(
      key: Key('end-card-ready-$seat'),
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: kSpace2,
            vertical: kSpace1,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: ready ? seatColor.withValues(alpha: 0.22) : null,
            border: Border.all(color: seatColor, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: seatColor,
                  shape: BoxShape.circle,
                ),
                child: SeatMark(seat: seat, size: 14),
              ),
              if (name != null) ...<Widget>[
                const SizedBox(width: kSpace1),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: LudoColors.ink),
                  ),
                ),
              ],
              if (ready) ...<Widget>[
                const SizedBox(width: kSpace1),
                const Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: LudoColors.ink,
                ),
              ],
            ],
          ),
        ),
      ),
    );
    // C-605 D1: the chip of a seat that sat down after the card first built
    // enters the way the lobby's seat card does. Chips the card was first
    // drawn with sit at their end state; the wrapper is always there, so a
    // later rebuild never changes the tree under a chip.
    return SeatEntrance(
      key: ValueKey<String>('end-card-ready-entrance-$seat'),
      seat: seat,
      entering:
          _arriving &&
          (_freshSeats.contains(seat) || widget.friendJoined?.seat == seat),
      child: chip,
    );
  }

  /// C-605 D1: "Karim joined" above the ready chips, the joined seat's disc
  /// with its mark at the start and the text in ink, the same line the first
  /// lobby shows. The slot is always in the column, so the line grows into
  /// place and collapses when the caller drops it, instead of the chips
  /// jumping. It is out of the semantics tree: a screen reader hears the same
  /// text once, as the announcement the game screen sends with the join.
  Widget _friendJoinedSlot(BuildContext context, AppLocalizations loc) {
    final EndCardJoin? join = widget.friendJoined;
    final bool still = MediaQuery.disableAnimationsOf(context);
    final Duration motion = still ? Duration.zero : kMotionShort;
    final Widget content = join == null
        ? const SizedBox(width: double.infinity)
        : KeyedSubtree(
            key: ValueKey<int>(join.serial),
            child: ExcludeSemantics(
              child: TweenAnimationBuilder<double>(
                key: const Key('end-card-friend-joined-line'),
                tween: Tween<double>(begin: 0, end: 1),
                duration: motion,
                curve: Curves.easeOut,
                builder: (BuildContext context, double t, Widget? line) =>
                    Opacity(opacity: t, child: line),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: kSpace2),
                  child: Center(child: _friendJoinedRow(context, loc, join)),
                ),
              ),
            ),
          );
    // AnimatedSize asserts on a zero duration, so under reduced motion the
    // line simply is or is not there.
    return still
        ? content
        : AnimatedSize(
            duration: motion,
            alignment: Alignment.topCenter,
            child: content,
          );
  }

  Widget _friendJoinedRow(
    BuildContext context,
    AppLocalizations loc,
    EndCardJoin join,
  ) {
    final String text = loc.lobbyFriendJoined(join.name);
    final TextStyle? base = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: LudoColors.ink, fontWeight: FontWeight.w600);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: _seatColor(join.seat),
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(
            dimension: kSpace5,
            child: Center(child: SeatMark(seat: join.seat, size: 10)),
          ),
        ),
        const SizedBox(width: kSpace2),
        Flexible(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: _fitTitleFontSize(
                  text: text,
                  base: base,
                  maxWidth: constraints.maxWidth,
                  scaler: MediaQuery.textScalerOf(context),
                  direction: Directionality.of(context),
                  locale: Localizations.maybeLocaleOf(context),
                ),
              );
            },
          ),
        ),
      ],
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
      // C-555 D3: one wrapper, always there, so the button is never rebuilt
      // under a finger when the guard ends. The guard is the controller
      // still running; a tap in it goes nowhere.
      return FadeTransition(
        opacity: MediaQuery.disableAnimationsOf(context)
            ? kAlwaysCompleteAnimation
            : _newTableGuard.drive(
                CurveTween(
                  curve: Interval(
                    0,
                    _kNewTableFade.inMilliseconds /
                        _kNewTableGuard.inMilliseconds,
                    curve: Curves.easeOut,
                  ),
                ),
              ),
        alwaysIncludeSemantics: true,
        child: ElevatedButton(
          key: const Key('game-screen-new-room-button'),
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () {
            if (_newTableGuard.isAnimating) {
              return;
            }
            widget.onNewTable();
          },
          child: Text(loc.gameNewRoomButton),
        ),
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

/// C-555 D4: shows [child] at once, or, when [fade] is true, fades it in from
/// nothing over 200 ms. [fade] is read once, when this widget is first
/// built: a line already showing is never re-faded by a later rebuild. With
/// the system's animations removed there is no fade (P9).
class _FadeInOnArrival extends StatefulWidget {
  const _FadeInOnArrival({super.key, required this.fade, required this.child});

  final bool fade;
  final Widget child;

  @override
  State<_FadeInOnArrival> createState() => _FadeInOnArrivalState();
}

class _FadeInOnArrivalState extends State<_FadeInOnArrival>
    with SingleTickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: widget.fade ? 0 : 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (widget.fade) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _opacity.value = 1;
      } else {
        _opacity.forward();
      }
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      alwaysIncludeSemantics: true,
      child: widget.child,
    );
  }
}

/// One reply chip on the end card (C-485 D5.1): the sheet's speech bubble at
/// full strength, or at 38 % while it cannot send. A tap that cannot send
/// shakes the chip a little and plays the invalid-tap cue; under reduced
/// motion the cue still plays, the chip stays still and wears a
/// [RefusalMark] for 300 ms (C-520 D3).
class _ReplyChip extends StatefulWidget {
  _ReplyChip({
    required this.id,
    required this.line,
    required this.compact,
    required this.dimmed,
    required this.onSend,
    this.resting = false,
  }) : super(key: Key('end-card-reply-$id'));

  final String id;
  final String line;

  /// The tighter chip of C-498 D2.
  final bool compact;
  final bool dimmed;

  /// C-520 D2: resting between sends, so TalkBack hears `chatResting` after
  /// the line. Dimmed for any other reason carries no hint.
  final bool resting;

  /// Null when a tap must be refused.
  final void Function(String id)? onSend;

  @override
  State<_ReplyChip> createState() => _ReplyChipState();
}

class _ReplyChipState extends State<_ReplyChip>
    with SingleTickerProviderStateMixin {
  static const Duration _shakeLife = Duration(milliseconds: 260);

  late final AnimationController _shake;
  Timer? _markTimer;
  bool _marked = false;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(vsync: this, duration: _shakeLife);
  }

  @override
  void dispose() {
    _markTimer?.cancel();
    _shake.dispose();
    super.dispose();
  }

  void _tap() {
    final void Function(String id)? send = widget.onSend;
    if (send != null) {
      send(widget.id);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.invalidTap);
    if (!MediaQuery.disableAnimationsOf(context)) {
      _shake.forward(from: 0);
      return;
    }
    // C-520 D3: motion off, the refusal is a mark for 300 ms; a second tap
    // inside it restarts the 300 ms.
    _markTimer?.cancel();
    setState(() {
      _marked = true;
    });
    _markTimer = Timer(kRefusalMarkLife, () {
      _markTimer = null;
      if (!mounted) {
        return;
      }
      setState(() {
        _marked = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // The node is made here, outside the shake, so the keyed widget's own
    // render object carries the button and its line; the chip's own node
    // underneath is excluded and the two never double up for TalkBack.
    return Semantics(
      container: true,
      button: true,
      label: widget.line,
      hint: widget.resting ? AppLocalizations.of(context).chatResting : null,
      onTap: _tap,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _shake,
          builder: (BuildContext context, Widget? child) {
            final double dx =
                6 * math.sin(_shake.value * math.pi * 4) * (1 - _shake.value);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: Stack(
            children: <Widget>[
              Opacity(
                opacity: widget.dimmed ? 0.38 : 1,
                child: SpeechChip(
                  line: widget.line,
                  onTap: _tap,
                  compact: widget.compact,
                ),
              ),
              // The bubble's body, not its tail, is the painted shape.
              if (_marked)
                const Positioned.fill(
                  bottom: kChatTailHeight,
                  child: RefusalMark(
                    shape: BoxShape.rectangle,
                    borderRadius: BorderRadius.all(Radius.circular(16)),
                  ),
                ),
            ],
          ),
        ),
      ),
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

/// C-343 rule 1: a name must never break inside itself, so the title's own
/// font shrinks just enough for [text]'s widest word to fit [maxWidth] at
/// [scaler] -- never the other way around. Starts from [base]'s own font
/// size (already a fit returns [base] unchanged, so scale 1.0 never moves,
/// rule 3) and only ever falls, down to the smaller of
/// [kEndCardTitleMinFontSize] and that starting size, so a style that began
/// under the floor (a body style, not a headline) is never pushed up to it.
TextStyle? _fitTitleFontSize({
  required String text,
  required TextStyle? base,
  required double maxWidth,
  required TextScaler scaler,
  required TextDirection direction,
  Locale? locale,
}) {
  if (base == null || !maxWidth.isFinite || maxWidth <= 0) {
    return base;
  }
  final List<String> words = text
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) {
    return base;
  }
  double widestWordWidth(TextStyle style) {
    double widest = 0;
    for (final String word in words) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: word, style: style),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return widest;
  }

  if (widestWordWidth(base) <= maxWidth) {
    return base;
  }
  final double startSize = base.fontSize ?? kEndCardTitleMinFontSize;
  final double floor = math.min(startSize, kEndCardTitleMinFontSize);
  double size = startSize;
  while (size > floor) {
    size -= 1;
    final TextStyle candidate = base.copyWith(fontSize: size);
    if (widestWordWidth(candidate) <= maxWidth) {
      return candidate;
    }
  }
  return base.copyWith(fontSize: floor);
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
  static const double _diameter = 196;

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
