// The one screen a refused app shows (docs/PROTOCOL.md section 27 rule 6).
// The server closed this socket because this build is older than the table
// needs. The card says so in one line, offers one tap to the app's Google
// Play page, and keeps a quiet way back to the home screen. It is the same
// card the lobby draws for a seat that moved to another phone: an icon, a
// title, a line, a full-width primary action.
//
// The view decides nothing and plays no cue: section 3's vocabulary has no id
// for it. The screen that shows it speaks the title once through its own
// spoken-line region, since the title is the one thing a player who cannot
// see the card needs.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

/// Opens [url] outside the app and says whether anything handled it.
typedef UpdateLauncher = Future<bool> Function(Uri url);

/// The Play Store app's own scheme; tried first.
final Uri kUpdateMarketUri = Uri.parse('market://details?id=app.fayad.ludo');

/// The web page for the same listing, tried when nothing handles `market:`.
final Uri kUpdateWebUri = Uri.parse(
  'https://play.google.com/store/apps/details?id=app.fayad.ludo',
);

/// The card's title and button labels stop growing here, as the turn banner's
/// text does (C-339); the body keeps the system scale.
const double _kLabelMaxScale = 1.5;

/// Below this much room the whole card scrolls rather than squeezing the body
/// to nothing: its fixed parts (icon, title, two actions) need about this.
const double _kMinCardHeight = 380;

Future<bool> _launchExternal(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

class UpdateRequiredView extends StatefulWidget {
  const UpdateRequiredView({super.key, required this.onHome, this.launcher});

  /// The quiet action: the same navigation the hosting screen's corner close
  /// performs.
  final VoidCallback onHome;

  /// How a store address is opened. Null means `url_launcher`.
  final UpdateLauncher? launcher;

  @override
  State<UpdateRequiredView> createState() => _UpdateRequiredViewState();
}

class _UpdateRequiredViewState extends State<UpdateRequiredView> {
  /// True while an open is in flight, so a double tap opens the store once.
  bool _opening = false;

  UpdateLauncher get _launcher => widget.launcher ?? _launchExternal;

  Future<void> _openStore() async {
    if (_opening) {
      return;
    }
    _opening = true;
    try {
      bool opened;
      try {
        opened = await _launcher(kUpdateMarketUri);
      } catch (_) {
        // A phone with no handler for market: reports it as false or as a
        // platform error, and both mean the same thing here: use the web page.
        opened = false;
      }
      if (!opened) {
        try {
          await _launcher(kUpdateWebUri);
        } catch (_) {
          // Nothing opens a web page either, whatever the reason. The card
          // stays as it is, with its button, so the player can tap again.
        }
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final bool still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints outer) {
        // The card never grows past the space it is given, so the two
        // actions stay on screen at any text scale and the body, the one
        // part that can be long, scrolls inside the card. A space shorter
        // than the card's own fixed parts scrolls the whole card instead.
        final double budget = math.max(
          outer.maxHeight - 2 * kSpace4,
          _kMinCardHeight,
        );
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(kSpace4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: still ? 1 : 0, end: 1),
              duration: still
                  ? Duration.zero
                  : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              builder: (BuildContext context, double t, Widget? child) {
                return Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, (1 - t) * 12),
                    child: child,
                  ),
                );
              },
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 320, maxHeight: budget),
                child: Material(
                  key: const Key('update-required-view'),
                  color: LudoColors.paperElevated,
                  borderRadius: BorderRadius.circular(2 * kRadiusControl),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.all(kSpace5),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.system_update_rounded,
                          size: 32,
                          color: LudoColors.inkMuted,
                        ),
                        const SizedBox(height: kSpace2),
                        // The title and the two labels stop growing at 1.5,
                        // as the turn banner does, so the actions keep their
                        // place at the largest system text size.
                        MediaQuery.withClampedTextScaling(
                          maxScaleFactor: _kLabelMaxScale,
                          child: Semantics(
                            header: true,
                            child: Text(
                              loc.updateRequiredTitle,
                              textAlign: TextAlign.center,
                              style: text.titleMedium?.copyWith(
                                color: LudoColors.ink,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: kSpace2),
                        Flexible(
                          child: SingleChildScrollView(
                            child: Text(
                              loc.updateRequiredBody,
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(
                                color: LudoColors.inkMuted,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: kSpace4),
                        MediaQuery.withClampedTextScaling(
                          maxScaleFactor: _kLabelMaxScale,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  key: const Key(
                                    'update-required-store-button',
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                  ),
                                  onPressed: _openStore,
                                  child: Text(loc.updateRequiredStoreButton),
                                ),
                              ),
                              const SizedBox(height: kSpace2),
                              SizedBox(
                                width: double.infinity,
                                child: TextButton(
                                  key: const Key('update-required-home-button'),
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                  ),
                                  onPressed: widget.onHome,
                                  child: Text(loc.updateRequiredHomeButton),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
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
