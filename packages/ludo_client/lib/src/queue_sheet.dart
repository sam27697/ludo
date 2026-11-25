// C-701: the waiting window. Up while this phone is in the server's waiting
// line (docs/PROTOCOL.md section 33): the app's die turning slowly, how many
// players are ahead, Play the computer and Cancel. Back and outside taps do
// not close it; the server's answer does. A seat (`seat_assigned` and `room`)
// closes it seated, `find_cancelled` closes it cancelled, a failure the line
// cannot recover from closes it failed and home says why.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'die_mark.dart';
import 'directional_icon.dart';
import 'feedback.dart';
import 'home_style.dart';
import 'net/room_controller.dart';
import 'theme.dart';

/// How the waiting window closed.
enum QueueOutcome {
  /// The controller holds a room: from the line, or a computer game.
  seated,

  /// The player left the line and the server said so.
  cancelled,

  /// The line ended without a seat: [RoomController.errorCode] says why.
  failed,
}

/// One full turn of the waiting die. Slow on purpose: it says "still
/// looking", not "rolling now".
const Duration kQueueDieTurn = Duration(seconds: 6);

/// Opens the waiting window over [controller], which has already been asked
/// to [RoomController.findGame]. [playerName] is the name a computer game is
/// started with.
Future<QueueOutcome?> showQueueSheet(
  BuildContext context, {
  required RoomController controller,
  required String playerName,
}) {
  return showHomeSheet<QueueOutcome>(
    context,
    dismissible: false,
    builder: (BuildContext sheetContext) =>
        QueueSheet(controller: controller, playerName: playerName),
  );
}

class QueueSheet extends StatefulWidget {
  const QueueSheet({
    super.key,
    required this.controller,
    required this.playerName,
  });

  final RoomController controller;
  final String playerName;

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn;
  bool _vsComputer = false;
  bool _cancelSent = false;
  bool _computerSent = false;
  bool _closed = false;
  bool _motionArmed = false;

  @override
  void initState() {
    super.initState();
    _turn = AnimationController(vsync: this, duration: kQueueDieTurn);
    widget.controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onControllerChanged());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce) {
      _turn.stop();
      _motionArmed = false;
    } else if (!_motionArmed) {
      _motionArmed = true;
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _turn.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted || _closed) {
      return;
    }
    final RoomController controller = widget.controller;
    if (controller.room != null) {
      _close(QueueOutcome.seated);
      return;
    }
    if (controller.phase == RoomPhase.failed ||
        controller.phase == RoomPhase.closed) {
      _close(QueueOutcome.failed);
      return;
    }
    if (_cancelSent &&
        !controller.inQueue &&
        controller.phase == RoomPhase.idle) {
      _close(QueueOutcome.cancelled);
      return;
    }
    setState(() {});
  }

  void _close(QueueOutcome outcome) {
    _closed = true;
    _turn.stop();
    Navigator.of(context).pop(outcome);
  }

  void _cancel() {
    if (_cancelSent || _computerSent) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _cancelSent = true;
    });
    widget.controller.cancelFind().then((_) => _onControllerChanged());
  }

  void _showComputerChoice(bool on) {
    if (_cancelSent || _computerSent) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _vsComputer = on;
    });
  }

  void _playComputer(int players) {
    if (_cancelSent || _computerSent) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _computerSent = true;
    });
    widget.controller.playComputer(name: widget.playerName, players: players);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    final Widget content = _vsComputer
        ? _computerChoice(context)
        : _waiting(context);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const Key('queue-sheet'),
        padding: const EdgeInsets.fromLTRB(kSpace5, kSpace3, kSpace5, kSpace6),
        // The window eases every change of height (the swap to the computer
        // choice, the ahead line coming or going) and the content swaps in
        // place. A crossfade inside the size easing, as in the join sheet,
        // took the Android 16 emulator offline on the Arabic motion leg. With
        // reduced motion the content swaps at once.
        child: reduce
            ? content
            : AnimatedSize(
                duration: kMotionShort,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: content,
              ),
      ),
    );
  }

  Widget _die() {
    return AnimatedBuilder(
      animation: _turn,
      builder: (BuildContext context, Widget? child) {
        final double v = _turn.value;
        // A slow turn with a small rise and fall, so the die reads as
        // tumbling in place rather than spinning on a pin.
        final double lift = 4 * math.sin(v * math.pi * 4);
        return Transform.translate(
          offset: Offset(0, -lift.abs()),
          child: DieMark(size: 72, rotation: -0.12 + v * 2 * math.pi),
        );
      },
    );
  }

  Widget _waiting(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final RoomController controller = widget.controller;
    final int? position = controller.queueState?.position;
    final bool ahead = position != null && position > 1;
    return Column(
      key: const ValueKey<String>('queue-waiting'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        HomeSheetHeader(title: loc.queueTitle),
        const SizedBox(height: kSpace4),
        Center(child: ExcludeSemantics(child: _die())),
        const SizedBox(height: kSpace3),
        // The count is the server's latest word: a new place replaces the
        // old count at once, and the line leaves the moment the server says
        // this phone is at the head, so a stale count is never on screen.
        // Its arrival fades in; the window takes its height on the next frame.
        if (ahead)
          HomeSheetFadeIn(
            child: Text(
              loc.queueAhead(position - 1),
              key: const Key('queue-ahead'),
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(color: LudoColors.ink),
            ),
          ),
        if (controller.queueReconnecting) ...<Widget>[
          const SizedBox(height: kSpace2),
          Row(
            key: const Key('queue-reconnecting'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(
                Icons.wifi_off_rounded,
                size: 18,
                color: LudoColors.inkMuted,
              ),
              const SizedBox(width: kSpace2),
              Flexible(
                child: Text(
                  loc.lobbyReconnecting,
                  style: textTheme.bodyMedium?.copyWith(
                    color: LudoColors.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: kSpace5),
        HomeGoldFrame(
          strong: true,
          child: ElevatedButton.icon(
            key: const Key('queue-vs-computer'),
            onPressed: () => _showComputerChoice(true),
            style: homeGoldButtonStyle(),
            icon: const Icon(Icons.smart_toy_rounded),
            label: Text(loc.queueVsComputer),
          ),
        ),
        const SizedBox(height: kSpace3),
        HomeGoldFrame(
          child: OutlinedButton(
            key: const Key('queue-cancel'),
            onPressed: _cancel,
            style: homeGoldButtonStyle(),
            child: Text(loc.queueCancel),
          ),
        ),
      ],
    );
  }

  Widget _computerChoice(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    return Column(
      key: const ValueKey<String>('queue-vs-computer-choice'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        HomeSheetHeader(
          title: loc.vsComputerTitle,
          leading: IconButton(
            key: const Key('vs-computer-back'),
            onPressed: () => _showComputerChoice(false),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            color: LudoColors.ink,
            icon: const DirectionalIcon(Icons.arrow_back_rounded),
          ),
        ),
        const SizedBox(height: kSpace5),
        HomeSheetTilePair(
          first: HomeSheetTile(
            key: const Key('vs-computer-2'),
            picture: const _PlayerCount(count: 2),
            semanticLabel: loc.vsComputerTwoLabel,
            emphasised: true,
            onTap: () => _playComputer(2),
          ),
          second: HomeSheetTile(
            key: const Key('vs-computer-4'),
            picture: const _PlayerCount(count: 4),
            semanticLabel: loc.vsComputerFourLabel,
            onTap: () => _playComputer(4),
          ),
        ),
      ],
    );
  }
}

/// A large numeral above a row of that many pawns, one per seat colour.
class _PlayerCount extends StatelessWidget {
  const _PlayerCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final Color ink = IconTheme.of(context).color ?? LudoColors.ink;
    final TextTheme textTheme = Theme.of(context).textTheme;
    // The numeral in the locale's digits, as the lobby numbers its seats.
    final String numeral = MaterialLocalizations.of(context)
        .formatDecimal(count);
    // Two players sit opposite each other on the board, as the game seats
    // them.
    final List<int> seats = count == 2
        ? const <int>[0, 2]
        : const <int>[0, 1, 2, 3];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          numeral,
          style: textTheme.displaySmall?.copyWith(
            color: ink,
            fontWeight: FontWeight.w800,
            height: 1.0,
          ),
        ),
        const SizedBox(height: kSpace2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final int seat in seats)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: CustomPaint(
                  size: const Size(14, 20),
                  painter: _PawnPainter(color: LudoColors.seats[seat]),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A plain pawn: a round head on a flared base, outlined so it reads on
/// either tile surface.
class _PawnPainter extends CustomPainter {
  const _PawnPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final Path body = Path()
      ..moveTo(w * 0.32, h * 0.45)
      ..lineTo(w * 0.68, h * 0.45)
      ..lineTo(w * 0.92, h * 0.92)
      ..quadraticBezierTo(w * 0.5, h * 1.02, w * 0.08, h * 0.92)
      ..close();
    final Offset head = Offset(w * 0.5, h * 0.3);
    final double r = w * 0.26;
    final Paint fill = Paint()..color = color;
    final Paint edge = Paint()
      ..color = LudoColors.paperElevated
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(body, fill);
    canvas.drawPath(body, edge);
    canvas.drawCircle(head, r, fill);
    canvas.drawCircle(head, r, edge);
  }

  @override
  bool shouldRepaint(_PawnPainter oldDelegate) => oldDelegate.color != color;
}
