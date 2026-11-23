// docs/PROTOCOL.md section 32 item 12: the `ban` object a `CODE_BANNED`
// error, a rejecting `knock_failed` or a `kicked` frame carries, and the home
// notice that tells the player in plain words what it means. The notice is
// built from the frame's own numbers and nothing else; a `ban` that cannot be
// read is not shown at all rather than guessed at.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// Which of the two blocks a [CodeBan] describes.
enum CodeBanScope { device, network }

const int _msPerDay = 24 * 60 * 60 * 1000;

/// The `ban` object, as the server sent it.
class CodeBan {
  const CodeBan({
    required this.scope,
    required this.untilMs,
    required this.level,
    required this.nextMs,
  });

  final CodeBanScope scope;

  /// When the block ends, epoch milliseconds.
  final int untilMs;

  final int level;

  /// Length of the block the device's next step would give, in milliseconds.
  /// 0 when the server names none (a network block).
  final int nextMs;

  /// Reads a `ban` value off a frame. Null when it is absent or any field the
  /// notice needs is missing or of the wrong type: the notice is never built
  /// from a guess.
  static CodeBan? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final CodeBanScope? scope = switch (raw['scope']) {
      'device' => CodeBanScope.device,
      'network' => CodeBanScope.network,
      _ => null,
    };
    final Object? until = raw['until_ms'];
    if (scope == null || until is! num || !until.isFinite) {
      return null;
    }
    final Object? level = raw['level'];
    final Object? next = raw['next_ms'];
    return CodeBan(
      scope: scope,
      untilMs: until.toInt(),
      level: level is num ? level.toInt() : 0,
      nextMs: next is num && next.isFinite ? next.toInt() : 0,
    );
  }

  /// [nextMs] as whole days, rounded up; 0 when there is no next block.
  int get nextDays => nextMs <= 0 ? 0 : (nextMs + _msPerDay - 1) ~/ _msPerDay;

  @override
  bool operator ==(Object other) =>
      other is CodeBan &&
      other.scope == scope &&
      other.untilMs == untilMs &&
      other.level == level &&
      other.nextMs == nextMs;

  @override
  int get hashCode => Object.hash(scope, untilMs, level, nextMs);
}

/// [text] with Arabic-Indic (U+0660..U+0669) and extended Arabic-Indic
/// (U+06F0..U+06F9) digits written as Latin digits. The app writes every
/// number in Latin digits (times, day counts, room codes), so a date line
/// must not switch digit system halfway through a sentence. Weekday and month
/// names stay in the language's own letters.
String _latinDigits(String text) {
  final StringBuffer out = StringBuffer();
  for (final int unit in text.runes) {
    if (unit >= 0x0660 && unit <= 0x0669) {
      out.writeCharCode(0x30 + unit - 0x0660);
    } else if (unit >= 0x06F0 && unit <= 0x06F9) {
      out.writeCharCode(0x30 + unit - 0x06F0);
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// The notice text for [ban], one line per fact, in the language [context]
/// is built in and with the end time in the phone's local zone and format.
String codeBanText(BuildContext context, CodeBan ban) {
  final AppLocalizations loc = AppLocalizations.of(context);
  final MaterialLocalizations material = MaterialLocalizations.of(context);
  final DateTime until = DateTime.fromMillisecondsSinceEpoch(ban.untilMs);
  final String when = loc.codeBanUntilFormat(
    _latinDigits(material.formatMediumDate(until)),
    material.formatTimeOfDay(
      TimeOfDay.fromDateTime(until),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    ),
  );
  final List<String> lines = <String>[
    switch (ban.scope) {
      CodeBanScope.device => loc.codeBanDevice(when),
      CodeBanScope.network => loc.codeBanNetwork(when),
    },
    if (ban.scope == CodeBanScope.device && ban.nextDays > 0)
      loc.codeBanDeviceNext(ban.nextDays),
    loc.codeBanLinkStillWorks,
  ];
  return lines.join('\n');
}

/// The red mark every refusal notice leads with: a red disc with an X, so the
/// refusal reads by shape as well as by colour (P9). The code-ban card, the
/// knock refusal and kicked lines on home and the kicked card in the lobby all
/// draw this one widget.
class RefusalNoticeMark extends StatelessWidget {
  const RefusalNoticeMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Icon(Icons.cancel_rounded, color: LudoColors.error, size: size),
    );
  }
}

/// The frame colour and width of a refusal notice card.
const Color kRefusalNoticeFrame = LudoColors.error;
const double kRefusalNoticeFrameWidth = 2;

/// The card on home that carries [codeBanText]. A red block mark leads it and
/// the words say the same thing, so colour is never the only signal. The mark
/// sits at the start edge and the close control at the end edge, so the card
/// mirrors in Arabic with no locale branch. The text wraps at any text scale.
class CodeBanNotice extends StatefulWidget {
  const CodeBanNotice({
    super.key,
    required this.ban,
    required this.dismissLabel,
    required this.onDismiss,
  });

  final CodeBan ban;
  final String dismissLabel;
  final VoidCallback onDismiss;

  @override
  State<CodeBanNotice> createState() => _CodeBanNoticeState();
}

class _CodeBanNoticeState extends State<CodeBanNotice> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  /// Scrolls by the least distance that brings the card fully into view; a
  /// card already in view leaves the offset alone.
  void _reveal() {
    if (!mounted || Scrollable.maybeOf(context) == null) {
      return;
    }
    final Duration duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 250);
    Scrollable.ensureVisible(
      context,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
    Scrollable.ensureVisible(
      context,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Widget card = DecoratedBox(
      key: const Key('code-ban-notice'),
      decoration: BoxDecoration(
        color: LudoColors.paperWashTop,
        borderRadius: BorderRadius.circular(kRadiusControl),
        border: Border.all(
          color: kRefusalNoticeFrame,
          width: kRefusalNoticeFrameWidth,
        ),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: kSpace3,
          top: kSpace1,
          bottom: kSpace1,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: kSpace3),
              child: RefusalNoticeMark(),
            ),
            const SizedBox(width: kSpace3),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: kSpace2),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    codeBanText(context, widget.ban),
                    key: const Key('home-code-ban-notice'),
                    textAlign: TextAlign.start,
                    style: textTheme.bodyMedium?.copyWith(
                      color: LudoColors.ink,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('code-ban-notice-dismiss'),
              onPressed: widget.onDismiss,
              tooltip: widget.dismissLabel,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              color: LudoColors.ink,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      return card;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: card,
    );
  }
}
