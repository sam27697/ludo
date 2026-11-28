// The lobby's warning strip and the guest's two lobby actions (docs/PROTOCOL.md
// section 38). Everything here reads the controller: the deadline and the
// cooldown are the server's, counted on the controller's own clock, and a
// frame that arrives is what is drawn next.

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'net/room_controller.dart';
import 'net/snapshot.dart' show RoomSnapshot, RoomState;
import 'theme.dart';

/// Whole seconds left until [at] on [now], never negative, rounded up so the
/// strip never shows zero while time remains.
int secondsUntil(DateTime at, DateTime now) {
  final int ms = at.difference(now).inMilliseconds;
  return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
}

/// mm:ss with the locale's digits, the same digit rule the other counts use
/// (`MaterialLocalizations.formatDecimal`).
String formatCountdown(BuildContext context, int seconds) {
  final MaterialLocalizations material = MaterialLocalizations.of(context);
  final int minutes = seconds ~/ 60;
  final int rest = seconds % 60;
  final String tail = rest < 10
      ? '${material.formatDecimal(0)}${material.formatDecimal(rest)}'
      : material.formatDecimal(rest);
  return '${material.formatDecimal(minutes)}:$tail';
}

/// Rebuilds [builder] once a second while mounted.
class _SecondTicker extends StatefulWidget {
  const _SecondTicker({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_SecondTicker> createState() => _SecondTickerState();
}

class _SecondTickerState extends State<_SecondTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer _) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// The persistent strip shown once `lobby_closing` arrived: a live countdown
/// and the way out. The host's strip carries [onMakeNewRoom]; a guest's
/// carries [onJoinAnother]. The strip is a calm band in the lobby's own paper,
/// not a dialog, and it grows in rather than appearing.
class LobbyClosingBanner extends StatelessWidget {
  const LobbyClosingBanner({
    super.key,
    required this.controller,
    this.onMakeNewRoom,
    this.onJoinAnother,
  });

  final RoomController controller;
  final VoidCallback? onMakeNewRoom;
  final VoidCallback? onJoinAnother;

  @override
  Widget build(BuildContext context) {
    final DateTime? closesAt = controller.lobbyClosesAt;
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedSize(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: AlignmentDirectional.topCenter,
      child: closesAt == null
          ? const SizedBox(width: double.infinity)
          : _SecondTicker(
              builder: (BuildContext context) =>
                  _strip(context, secondsUntil(closesAt, controller.clockNow)),
            ),
    );
  }

  Widget _strip(BuildContext context, int seconds) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String time = formatCountdown(context, seconds);
    final String line = loc.lobbyClosingBanner(time);
    final bool host = onMakeNewRoom != null;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        kSpace4,
        kSpace1,
        kSpace4,
        kSpace2,
      ),
      child: Material(
        key: const Key('lobby-closing-banner'),
        color: LudoColors.paperElevated,
        elevation: 2,
        borderRadius: BorderRadius.circular(kRadiusControl),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadiusControl),
            border: BorderDirectional(
              start: BorderSide(color: LudoColors.action, width: 4),
            ),
          ),
          padding: const EdgeInsetsDirectional.fromSTEB(
            kSpace3,
            kSpace2,
            kSpace2,
            kSpace2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Semantics(
                container: true,
                label: line,
                child: ExcludeSemantics(
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.hourglass_top_rounded,
                        size: 22,
                        color: LudoColors.action,
                      ),
                      const SizedBox(width: kSpace2),
                      Expanded(
                        child: Text(
                          line,
                          key: const Key('lobby-closing-text'),
                          style: textTheme.bodyMedium?.copyWith(
                            color: LudoColors.ink,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (host)
                _action(
                  const Key('lobby-closing-new-room'),
                  Icons.add_rounded,
                  loc.lobbyMakeNewRoom,
                  onMakeNewRoom,
                )
              else if (onJoinAnother != null)
                _action(
                  const Key('lobby-closing-join-another'),
                  Icons.travel_explore_rounded,
                  loc.lobbyJoinAnotherRoom,
                  onJoinAnother,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(Key key, IconData icon, String label, VoidCallback? onTap) {
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton.icon(
        key: key,
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        label: Text(label),
      ),
    );
  }
}

/// The guest's "Ask the host to start". Present only while the controller
/// says a guest may ask or is inside its cooldown with two seats taken; the
/// disabled state names the seconds left, so the guest is never left to guess.
/// The line under it says how the last ask ended.
class AskStartControl extends StatefulWidget {
  const AskStartControl({super.key, required this.controller});

  final RoomController controller;

  @override
  State<AskStartControl> createState() => _AskStartControlState();
}

enum _AskResult { none, sent, away, failed }

class _AskStartControlState extends State<AskStartControl> {
  bool _inFlight = false;
  _AskResult _result = _AskResult.none;
  Timer? _resultTimer;

  @override
  void dispose() {
    _resultTimer?.cancel();
    super.dispose();
  }

  Future<void> _ask() async {
    if (_inFlight) {
      return;
    }
    setState(() {
      _inFlight = true;
      _result = _AskResult.none;
    });
    final AskStartOutcome outcome = await widget.controller.askStart();
    if (!mounted) {
      return;
    }
    setState(() {
      _inFlight = false;
      _result = outcome.accepted
          ? (outcome.delivered ? _AskResult.sent : _AskResult.away)
          : (outcome.errorCode == 'RATE_LIMITED'
                ? _AskResult.none
                : _AskResult.failed);
    });
    _resultTimer?.cancel();
    _resultTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _result = _AskResult.none);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final RoomSnapshot? room = widget.controller.room;
        if (room == null ||
            widget.controller.isHost ||
            room.state != RoomState.lobby ||
            room.seats.length < 2) {
          return const SizedBox.shrink();
        }
        final DateTime? until = widget.controller.askStartAvailableAt;
        if (until == null) {
          return _body(context, null);
        }
        return _SecondTicker(
          builder: (BuildContext context) {
            final DateTime? still = widget.controller.askStartAvailableAt;
            return _body(
              context,
              still == null
                  ? null
                  : secondsUntil(still, widget.controller.clockNow),
            );
          },
        );
      },
    );
  }

  Widget _body(BuildContext context, int? waitSeconds) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final MaterialLocalizations material = MaterialLocalizations.of(context);
    final bool waiting = waitSeconds != null && waitSeconds > 0;
    final String label = waiting
        ? loc.lobbyAskStartWait(material.formatDecimal(waitSeconds))
        : loc.lobbyAskStart;
    final String? line = switch (_result) {
      _AskResult.sent => loc.lobbyAskStartSent,
      _AskResult.away => loc.lobbyAskStartAway,
      _AskResult.failed => loc.lobbyAskStartFailed,
      _AskResult.none => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        OutlinedButton.icon(
          key: const Key('lobby-ask-start-button'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: waiting || _inFlight ? null : _ask,
          icon: Icon(
            waiting ? Icons.schedule_rounded : Icons.notifications_active,
            size: 20,
          ),
          label: Text(label, textAlign: TextAlign.center),
        ),
        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
          alignment: AlignmentDirectional.topCenter,
          child: line == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: kSpace1),
                  child: Text(
                    line,
                    key: const Key('lobby-ask-start-result'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _result == _AskResult.failed
                          ? LudoColors.error
                          : LudoColors.inkMuted,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The host's transient notice that a guest asked for the game to start.
/// Named for the asker; colour is not the only signal, the bell leads it.
class StartAskedNotice extends StatelessWidget {
  const StartAskedNotice({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        kSpace4,
        kSpace1,
        kSpace4,
        kSpace2,
      ),
      child: Material(
        key: const Key('lobby-start-asked-notice'),
        color: LudoColors.action,
        elevation: 3,
        borderRadius: BorderRadius.circular(kRadiusControl),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace3,
            vertical: kSpace3,
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.notifications_active,
                size: 22,
                color: LudoColors.actionOn,
              ),
              const SizedBox(width: kSpace2),
              Expanded(
                child: Text(
                  loc.lobbyStartAskedNotice(name),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: LudoColors.actionOn,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
