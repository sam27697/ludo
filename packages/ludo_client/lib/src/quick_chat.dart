// Quick messages: twelve preset lines, sent as ids, never as text. The
// sheet that offers them lives here; the bubble that shows one in the header
// band is in chat_bubble.dart and GameScreen decides when it exists. Contract
// C-478 D3 to D5, docs/PROTOCOL.md section 25.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'chat_bubble.dart';
import 'theme.dart';

export 'chat_bubble.dart' show kChatBubbleLife;

/// The ids the server knows, in the sheet's order. They are permanent.
const List<String> kQuickChatIds = <String>[
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
  'no_way',
  'good_game',
];

/// How long this device's own button rests after a send that came back.
const Duration kQuickChatCooldown = Duration(milliseconds: 3000);

/// Section 25 rule 3's second bound: at most this many in [kQuickChatWindow].
const int kQuickChatPerWindow = 10;
const Duration kQuickChatWindow = Duration(milliseconds: 60000);

/// C-520 D1. The instant until which a send after [admitted] would be
/// refused by PROTOCOL.md section 25 rule 3, or null when a send at [now]
/// would be admitted. [admitted] is this seat's acknowledged sends,
/// oldest first, on the device clock.
DateTime? quickChatRestsUntil(List<DateTime> admitted, DateTime now) {
  if (admitted.isEmpty) {
    return null;
  }
  DateTime until = admitted.last.add(kQuickChatCooldown);
  if (admitted.length >= kQuickChatPerWindow) {
    final DateTime tenth = admitted[admitted.length - kQuickChatPerWindow];
    final DateTime windowEnd = tenth.add(kQuickChatWindow);
    if (windowEnd.isAfter(until)) {
      until = windowEnd;
    }
  }
  return until.isAfter(now) ? until : null;
}

/// The line for [id] in [loc]'s language, or null for an id not in
/// [kQuickChatIds].
String? quickChatLine(AppLocalizations loc, String id) {
  return switch (id) {
    'hi' => loc.chatHi,
    'good_luck' => loc.chatGoodLuck,
    'your_move' => loc.chatYourMove,
    'nice' => loc.chatNice,
    'lucky' => loc.chatLucky,
    'oops' => loc.chatOops,
    'ha_ha' => loc.chatHaHa,
    'revenge' => loc.chatRevenge,
    'coming' => loc.chatComing,
    'back_home' => loc.chatBackHome,
    'no_way' => loc.chatNoWay,
    'good_game' => loc.chatGoodGame,
    _ => null,
  };
}

/// Opens the sheet over [context]. A chip tap pops the sheet, then calls
/// [onPick] once with the id. The switch is bound to [muted] both ways: the
/// screen reads it to hide the others' bubbles, the sheet writes it.
///
/// C-518 D1: [onRoute], when given, is handed the sheet's own route so the
/// caller can close that route and no other.
Future<void> showQuickChatSheet(
  BuildContext context, {
  required void Function(String id) onPick,
  required ValueNotifier<bool> muted,
  void Function(Route<void> route)? onRoute,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      final Route<void>? route = ModalRoute.of<void>(sheetContext);
      if (route != null) {
        onRoute?.call(route);
      }
      return _QuickChatSheet(
        muted: muted,
        onPick: (String id) {
          Navigator.of(sheetContext).pop();
          onPick(id);
        },
      );
    },
  );
}

class _QuickChatSheet extends StatelessWidget {
  const _QuickChatSheet({required this.muted, required this.onPick});

  final ValueNotifier<bool> muted;
  final void Function(String id) onPick;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: Material(
        key: const Key('quick-chat-sheet'),
        color: LudoColors.paper,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(kRadiusControl * 2),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            kSpace5,
            kSpace3,
            kSpace5,
            kSpace6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: kSpace7,
                  height: kSpace1,
                  margin: const EdgeInsets.only(bottom: kSpace4),
                  decoration: BoxDecoration(
                    color: LudoColors.inkMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(kSpace1),
                  ),
                ),
              ),
              Text(
                loc.chatSheetTitle,
                textAlign: TextAlign.start,
                style: textTheme.titleMedium?.copyWith(
                  color: LudoColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: kSpace3),
              Wrap(
                spacing: kSpace2,
                runSpacing: kSpace1,
                children: [
                  for (final String id in kQuickChatIds)
                    _QuickChatChip(
                      id: id,
                      line: quickChatLine(loc, id) ?? '',
                      onTap: () => onPick(id),
                    ),
                ],
              ),
              const SizedBox(height: kSpace3),
              _MuteRow(muted: muted, label: loc.chatMuteOthers),
            ],
          ),
        ),
      ),
    );
  }
}

/// One preset as a [SpeechChip], keyed `quick-chat-<id>`.
class _QuickChatChip extends StatelessWidget {
  _QuickChatChip({required this.id, required this.line, required this.onTap})
    : super(key: Key('quick-chat-$id'));

  final String id;
  final String line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SpeechChip(line: line, onTap: onTap);
}

/// The switch row, laid out like the settings sheet's rows: the whole row at
/// least 48 dp tall and tappable anywhere.
class _MuteRow extends StatelessWidget {
  const _MuteRow({required this.muted, required this.label});

  final ValueNotifier<bool> muted;
  final String label;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return ValueListenableBuilder<bool>(
      valueListenable: muted,
      builder: (BuildContext context, bool value, Widget? _) {
        return MergeSemantics(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(kRadiusControl),
              onTap: () => muted.value = !value,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    vertical: kSpace2,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.visibility_off_outlined,
                        color: LudoColors.ink,
                      ),
                      const SizedBox(width: kSpace4),
                      Expanded(
                        child: Text(
                          label,
                          style: textTheme.bodyLarge?.copyWith(
                            color: LudoColors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: kSpace3),
                      Switch(
                        key: const Key('quick-chat-mute'),
                        value: value,
                        onChanged: (bool next) => muted.value = next,
                        activeThumbColor: LudoColors.action,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
