// The account sheet: opened from the small account mark beside the name
// field. It holds two things, signing out (this phone only) and deleting the
// account, and the delete asks once more in the same sheet, in red, saying
// what goes and that it cannot be undone. A failure never stays silent: a
// short line in the player's language shows in the sheet and the sheet stays
// where it was.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'account.dart';
import 'code_ban_notice.dart';
import 'directional_icon.dart';
import 'feedback.dart';
import 'home_style.dart';
import 'theme.dart';

/// What the account sheet closed with; null when it was only closed.
enum AccountSheetResult { signedOut, deleted }

/// Opens the account sheet over [service].
Future<AccountSheetResult?> showAccountSheet(
  BuildContext context, {
  required AccountService service,
}) {
  return showHomeSheet<AccountSheetResult>(
    context,
    builder: (BuildContext sheetContext) => AccountSheet(service: service),
  );
}

class AccountSheet extends StatefulWidget {
  const AccountSheet({super.key, required this.service});

  final AccountService service;

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

enum _Line { none, failed, unavailable }

class _AccountSheetState extends State<AccountSheet> {
  bool _confirming = false;
  bool _busy = false;
  _Line _line = _Line.none;

  void _signOut() {
    if (_busy) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    final NavigatorState navigator = Navigator.of(context);
    // The device is signed out before the pop; Google's own sign-out runs
    // after and its failure is shown on the sheet's way out by the caller.
    widget.service.signOut().then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'account sheet',
          ),
        );
      },
    );
    navigator.pop(AccountSheetResult.signedOut);
  }

  void _askDelete() {
    if (_busy) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _confirming = true;
      _line = _Line.none;
    });
  }

  void _keep() {
    if (_busy) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _confirming = false;
      _line = _Line.none;
    });
  }

  Future<void> _delete() async {
    if (_busy) {
      FeedbackScope.of(context).play(FeedbackCue.invalidTap);
      return;
    }
    FeedbackScope.of(context).play(FeedbackCue.tap);
    setState(() {
      _busy = true;
      _line = _Line.none;
    });
    final AccountOutcome outcome = await widget.service.deleteAccount();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case AccountOutcome.ok:
        Navigator.of(context).pop(AccountSheetResult.deleted);
        return;
      case AccountOutcome.cancelled:
        // The player backed out of Google's own screen: back to the confirm
        // step as it was, nothing to explain.
        setState(() {
          _busy = false;
        });
      case AccountOutcome.failed:
      case AccountOutcome.unavailable:
        FeedbackScope.of(context).play(FeedbackCue.invalidTap);
        setState(() {
          _busy = false;
          _line = outcome == AccountOutcome.failed
              ? _Line.failed
              : _Line.unavailable;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final String signedInLine = widget.service.name.isEmpty
        ? loc.accountSignedInNoName
        : loc.accountSignedInAs(widget.service.name);
    final Widget body = _confirming
        ? _confirmStep(loc, textTheme)
        : _mainStep(loc, textTheme, signedInLine);
    return PopScope<AccountSheetResult>(
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace6,
            kSpace3,
            kSpace6,
            kSpace6,
          ),
          child: Column(
            key: const Key('account-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              HomeSheetHeader(
                title: _confirming
                    ? loc.accountDeleteTitle
                    : loc.accountSheetTitle,
              ),
              const SizedBox(height: kSpace4),
              HomeSheetFadeIn(key: ValueKey<bool>(_confirming), child: body),
              _lineWidget(loc, textTheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lineWidget(AppLocalizations loc, TextTheme textTheme) {
    if (_line == _Line.none) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: kSpace3),
      child: Row(
        key: const Key('account-sheet-line'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const RefusalNoticeMark(size: 20),
          const SizedBox(width: kSpace2),
          Flexible(
            child: Semantics(
              liveRegion: true,
              child: Text(
                _line == _Line.failed
                    ? loc.accountFailed
                    : loc.accountUnavailable,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: LudoColors.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mainStep(AppLocalizations loc, TextTheme textTheme, String line) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          line,
          key: const Key('account-sheet-name'),
          textAlign: TextAlign.center,
          style: textTheme.bodyLarge?.copyWith(color: LudoColors.inkMuted),
        ),
        const SizedBox(height: kSpace5),
        HomeGoldFrame(
          strong: true,
          child: TextButton.icon(
            key: const Key('account-sheet-sign-out'),
            onPressed: _signOut,
            style: homeGoldButtonStyle(minimumSize: const Size(48, 56)),
            icon: const DirectionalIcon(Icons.logout_rounded),
            label: Text(loc.accountSignOut),
          ),
        ),
        const SizedBox(height: kSpace3),
        TextButton.icon(
          key: const Key('account-sheet-delete'),
          onPressed: _askDelete,
          style: TextButton.styleFrom(
            foregroundColor: LudoColors.error,
            minimumSize: const Size(48, 48),
          ),
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(loc.accountDelete),
        ),
      ],
    );
  }

  Widget _confirmStep(AppLocalizations loc, TextTheme textTheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          loc.accountDeleteBody,
          key: const Key('account-delete-body'),
          textAlign: TextAlign.center,
          style: textTheme.bodyLarge?.copyWith(
            color: LudoColors.ink,
            height: 1.35,
          ),
        ),
        const SizedBox(height: kSpace5),
        FilledButton.icon(
          key: const Key('account-delete-confirm'),
          onPressed: _busy ? null : _delete,
          style: FilledButton.styleFrom(
            backgroundColor: LudoColors.error,
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kRadiusControl),
            ),
          ),
          icon: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.delete_forever_rounded),
          label: Text(loc.accountDeleteConfirm),
        ),
        const SizedBox(height: kSpace3),
        HomeGoldFrame(
          child: TextButton(
            key: const Key('account-delete-cancel'),
            onPressed: _keep,
            style: homeGoldButtonStyle(minimumSize: const Size(48, 52)),
            child: Text(loc.accountDeleteCancel),
          ),
        ),
      ],
    );
  }
}
