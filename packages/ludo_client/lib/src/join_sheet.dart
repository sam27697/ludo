// C-701: the sheet Join a game opens. Two tiles: Friend's code swaps the
// sheet's content, in place, to the room code entry home used to carry;
// Random players closes the sheet and home joins the waiting line. The code
// field, its formatter, its error line and Join are the ones home had; home
// keeps owning the code and the error, so a code typed here is still there
// the next time the sheet opens.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import 'directional_icon.dart';
import 'feedback.dart';
import 'home_style.dart';
import 'room_code.dart';
import 'theme.dart';

/// What the join sheet closed with.
enum JoinChoice {
  /// Join pressed on a code home accepted: home runs the typed-code join.
  code,

  /// Random players: home joins the waiting line.
  random,
}

/// Opens the join sheet over [codeController] and [errorText], both home's.
/// [onJoinCode] is home's check of the typed code: it sets [errorText] and
/// returns false for a code that cannot be sent, true when the join may go
/// ahead (the sheet then closes with [JoinChoice.code]). Null when the sheet
/// was closed without a choice.
Future<JoinChoice?> showJoinSheet(
  BuildContext context, {
  required TextEditingController codeController,
  required ValueListenable<String?> errorText,
  required bool Function() onJoinCode,
}) {
  return showHomeSheet<JoinChoice>(
    context,
    builder: (BuildContext sheetContext) => JoinSheet(
      codeController: codeController,
      errorText: errorText,
      onJoinCode: onJoinCode,
    ),
  );
}

class JoinSheet extends StatefulWidget {
  const JoinSheet({
    super.key,
    required this.codeController,
    required this.errorText,
    required this.onJoinCode,
  });

  final TextEditingController codeController;
  final ValueListenable<String?> errorText;
  final bool Function() onJoinCode;

  @override
  State<JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<JoinSheet> {
  bool _codeEntry = false;

  void _openCodeEntry() {
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _codeEntry = true;
    });
  }

  void _chooseRandom() {
    FeedbackScope.of(context).play(FeedbackCue.tap);
    Navigator.of(context).pop(JoinChoice.random);
  }

  void _join() {
    if (widget.onJoinCode()) {
      Navigator.of(context).pop(JoinChoice.code);
    } else {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    final Widget tiles = HomeSheetTilePair(
      key: const ValueKey<String>('join-tiles'),
      first: HomeSheetTile(
        key: const Key('join-code-tile'),
        picture: const Icon(Icons.dialpad_rounded),
        word: loc.joinCodeTile,
        semanticLabel: loc.joinCodeTile,
        emphasised: true,
        onTap: _openCodeEntry,
      ),
      second: HomeSheetTile(
        key: const Key('join-random-tile'),
        picture: const Icon(Icons.casino_rounded),
        word: loc.joinRandomTile,
        semanticLabel: loc.joinRandomTile,
        onTap: _chooseRandom,
      ),
    );
    final Widget content = _codeEntry
        ? _CodeEntry(
            key: const ValueKey<String>('join-code-entry'),
            controller: widget.codeController,
            errorText: widget.errorText,
            onJoin: _join,
          )
        : tiles;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const Key('join-sheet'),
        padding: const EdgeInsets.fromLTRB(kSpace5, kSpace3, kSpace5, kSpace6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            HomeSheetHeader(title: loc.joinSheetTitle),
            const SizedBox(height: kSpace5),
            AnimatedSize(
              duration: reduce ? Duration.zero : kMotionShort,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: reduce ? Duration.zero : kMotionShort,
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The room code entry: the field home carried, with its formatter and its
/// error line, and Join once the field holds anything.
class _CodeEntry extends StatelessWidget {
  const _CodeEntry({
    super.key,
    required this.controller,
    required this.errorText,
    required this.onJoin,
  });

  final TextEditingController controller;
  final ValueListenable<String?> errorText;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    OutlineInputBorder border(Color? color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(kRadiusControl),
      borderSide: color == null
          ? BorderSide.none
          : BorderSide(color: color, width: 2),
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, _) {
        final String code = normalizeRoomCode(value.text);
        final bool valid = isValidRoomCode(code);
        final bool joinShown = code.isNotEmpty;
        final Widget join = Padding(
          padding: const EdgeInsets.only(top: kSpace3),
          child: HomeGoldFrame(
            strong: valid,
            child: valid
                ? ElevatedButton.icon(
                    key: const Key('join-room-button'),
                    onPressed: onJoin,
                    style: homeGoldButtonStyle(),
                    icon: const DirectionalIcon(Icons.login_rounded),
                    label: Text(loc.homeJoinRoomButton),
                  )
                : OutlinedButton.icon(
                    key: const Key('join-room-button'),
                    onPressed: onJoin,
                    style: homeGoldButtonStyle(),
                    icon: const DirectionalIcon(Icons.login_rounded),
                    label: Text(loc.homeJoinRoomButton),
                  ),
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ValueListenableBuilder<String?>(
              valueListenable: errorText,
              builder: (BuildContext context, String? error, _) {
                return Semantics(
                  label: loc.homeRoomCodeFieldLabel,
                  child: HomeGoldFrame(
                    child: TextField(
                      key: const Key('room-code-field'),
                      controller: controller,
                      autofocus: true,
                      textAlign: TextAlign.center,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) {
                        if (valid) {
                          onJoin();
                        }
                      },
                      inputFormatters: const <TextInputFormatter>[
                        RoomCodeInputFormatter(),
                      ],
                      style: textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                      ),
                      decoration: InputDecoration(
                        hintText: loc.homeRoomCodeFieldLabel,
                        hintStyle: textTheme.bodyLarge?.copyWith(
                          color: LudoColors.inkMuted,
                        ),
                        errorText: error,
                        // Unset, InputDecoration truncates errorText to one
                        // line; homeRoomCodeInvalid needs up to four at this
                        // width in either locale.
                        errorMaxLines: 4,
                        filled: false,
                        prefixIcon: const Icon(
                          Icons.tag,
                          color: LudoColors.inkMuted,
                        ),
                        border: border(null),
                        enabledBorder: border(null),
                        focusedBorder: border(LudoColors.action),
                        errorBorder: border(LudoColors.error),
                        focusedErrorBorder: border(LudoColors.error),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (reduce)
              joinShown ? join : const SizedBox.shrink()
            else
              AnimatedSize(
                duration: kMotionShort,
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: joinShown
                    ? join
                    : const SizedBox(width: double.infinity),
              ),
          ],
        );
      },
    );
  }
}

/// Strips spaces and dashes and upper-cases as the player types or pastes, so
/// the field shows the same form [normalizeRoomCode] will send on Join.
/// Selection offsets are mapped through the stripped prefix so the caret does
/// not jump to the end.
class RoomCodeInputFormatter extends TextInputFormatter {
  const RoomCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String normalized = normalizeRoomCode(newValue.text);
    if (normalized.length > roomCodeLength) {
      normalized = normalized.substring(0, roomCodeLength);
    }
    if (normalized == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: normalized,
      selection: TextSelection(
        baseOffset: _offset(newValue.text, newValue.selection.baseOffset),
        extentOffset: _offset(newValue.text, newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
    );
  }

  /// Maps [offset] in [raw] onto the normalised string.
  static int _offset(String raw, int offset) {
    if (offset <= 0) {
      return offset;
    }
    final int end = offset < raw.length ? offset : raw.length;
    final int mapped = normalizeRoomCode(raw.substring(0, end)).length;
    return mapped > roomCodeLength ? roomCodeLength : mapped;
  }
}
