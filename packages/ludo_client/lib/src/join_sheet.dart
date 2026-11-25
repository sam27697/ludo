// C-701: the sheet Join a game opens. Two tiles: Friend's code swaps the
// sheet's content, in place, to the room code entry home used to carry;
// Random players closes the sheet and home joins the waiting line. The code
// field, its formatter, its error line and Join are the ones home had; home
// keeps owning the code and the error, so a code typed here is still there
// the next time the sheet opens.
//
// A typed-code join runs while the sheet stays up under the room's route,
// only for as long as the join's outcome is unknown. Once the join is
// accepted and the room's route covers the sheet, home takes the sheet's
// route out from under it without motion, so coming back from the room shows
// home and never this sheet. When the server refuses the code with a ban,
// the route comes back to this sheet and the ban notice shows here, where
// the code was typed; any other refusal closes the sheet once the route has
// come back.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import 'code_ban_notice.dart';
import 'directional_icon.dart';
import 'feedback.dart';
import 'home_style.dart';
import 'room_code.dart';
import 'theme.dart';

/// What the join sheet closed with.
enum JoinChoice {
  /// A typed-code join ran from the sheet: accepted, or ended without a ban
  /// to show.
  code,

  /// Random players: home joins the waiting line.
  random,
}

/// Opens the join sheet over [codeController], [errorText] and [codeBan], all
/// home's. [checkCode] is home's check of the typed code: it sets
/// [errorText] and returns false for a code that cannot be sent. [onJoinCode]
/// runs the typed-code join and completes once the room's route has come
/// back: true when the sheet stays up to show [codeBan], false when it
/// closes. [onDismissBan] is the notice's close control. [onRoute] hears the
/// sheet's route, so its owner can take it down if the owner goes first, or
/// from under an accepted join's room.
/// Null when the sheet was closed without a choice.
Future<JoinChoice?> showJoinSheet(
  BuildContext context, {
  required TextEditingController codeController,
  required ValueListenable<String?> errorText,
  required ValueListenable<CodeBan?> codeBan,
  required bool Function() checkCode,
  required Future<bool> Function() onJoinCode,
  required VoidCallback onDismissBan,
  ValueChanged<Route<Object?>>? onRoute,
}) {
  return showHomeSheet<JoinChoice>(
    context,
    builder: (BuildContext sheetContext) {
      final Route<Object?>? route = ModalRoute.of(sheetContext);
      if (route != null) {
        onRoute?.call(route);
      }
      return JoinSheet(
        codeController: codeController,
        errorText: errorText,
        codeBan: codeBan,
        checkCode: checkCode,
        onJoinCode: onJoinCode,
        onDismissBan: onDismissBan,
      );
    },
  );
}

class JoinSheet extends StatefulWidget {
  const JoinSheet({
    super.key,
    required this.codeController,
    required this.errorText,
    required this.codeBan,
    required this.checkCode,
    required this.onJoinCode,
    required this.onDismissBan,
  });

  final TextEditingController codeController;
  final ValueListenable<String?> errorText;
  final ValueListenable<CodeBan?> codeBan;
  final bool Function() checkCode;
  final Future<bool> Function() onJoinCode;
  final VoidCallback onDismissBan;

  @override
  State<JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends State<JoinSheet> {
  bool _codeEntry = false;
  bool _joining = false;

  void _openCodeEntry() {
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _codeEntry = true;
    });
  }

  void _chooseRandom() {
    if (_joining) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    Navigator.of(context).pop(JoinChoice.random);
  }

  Future<void> _join() async {
    if (_joining || !widget.checkCode()) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    _joining = true;
    final bool stay;
    try {
      stay = await widget.onJoinCode();
    } finally {
      _joining = false;
    }
    if (!mounted || stay) {
      return;
    }
    // Should anything still be above this sheet when the join's route has
    // come back, only the sheet's own route may go, without touching the
    // one above it.
    final NavigatorState navigator = Navigator.of(context);
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      navigator.pop(JoinChoice.code);
    } else if (route.isActive) {
      navigator.removeRoute(route, JoinChoice.code);
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
            codeBan: widget.codeBan,
            onDismissBan: widget.onDismissBan,
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
            // The sheet eases every change of height (the swap to the code
            // entry, Join arriving, the ban notice) and the content swaps in
            // place. There is no crossfade inside the size easing: the two
            // together took the Android 16 emulator offline on the Arabic
            // motion leg. With reduced motion the content swaps at once.
            if (reduce)
              content
            else
              AnimatedSize(
                duration: kMotionShort,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: content,
              ),
          ],
        ),
      ),
    );
  }
}

/// The room code entry: the field home carried, with its formatter and its
/// error line, the ban notice when the server refused the code, and Join
/// once the field holds anything. Nothing here animates its own size; the
/// sheet's one [AnimatedSize] eases every change of height.
class _CodeEntry extends StatelessWidget {
  const _CodeEntry({
    super.key,
    required this.controller,
    required this.errorText,
    required this.codeBan,
    required this.onDismissBan,
    required this.onJoin,
  });

  final TextEditingController controller;
  final ValueListenable<String?> errorText;
  final ValueListenable<CodeBan?> codeBan;
  final VoidCallback onDismissBan;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    OutlineInputBorder border(Color? color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(kRadiusControl),
      borderSide: color == null
          ? BorderSide.none
          : BorderSide(color: color, width: 2),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ValueListenableBuilder<CodeBan?>(
          valueListenable: codeBan,
          builder: (BuildContext context, CodeBan? ban, _) {
            if (ban == null) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: kSpace3),
              child: CodeBanNotice(
                ban: ban,
                dismissLabel: loc.homeNoticeDismiss,
                onDismiss: onDismissBan,
              ),
            );
          },
        ),
        ValueListenableBuilder<TextEditingValue>(
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
                            // Unset, InputDecoration truncates errorText to
                            // one line; homeRoomCodeInvalid needs up to four
                            // at this width in either locale.
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
                if (joinShown) HomeSheetFadeIn(child: join),
              ],
            );
          },
        ),
      ],
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
