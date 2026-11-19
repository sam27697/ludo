// C-678: the wordmark panel at the top of home. Drawn in code from the die
// mark's palette: table felt behind, gold ink on top, the four seat colours
// as pips either side of the name.

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import 'theme.dart';

class HomeLogoPanel extends StatelessWidget {
  const HomeLogoPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations loc = AppLocalizations.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: loc.appTitle,
      child: ExcludeSemantics(
        child: DecoratedBox(
          key: const Key('home-logo-panel'),
          position: DecorationPosition.foreground,
          // Painted over the child so the border takes no layout space.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadiusControl + 4),
            border: Border.all(
              color: LudoColors.gold.withValues(alpha: 0.85),
              width: 1.5,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusControl + 4),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[LudoColors.feltMid, LudoColors.feltDeep],
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: LudoColors.feltDeep.withValues(alpha: 0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            // Content-sized: the panel hugs the wordmark so the gap to the
            // tagline below is the pinned token gap, not panel slack.
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                start: kSpace4,
                end: kSpace4,
                top: kSpace2,
                bottom: kSpace1,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  const _PipPair(first: 0, second: 1),
                  const SizedBox(width: kSpace3),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        loc.appTitle,
                        maxLines: 1,
                        softWrap: false,
                        style: textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: LudoColors.gold,
                          letterSpacing: 0.5,
                          height: 1.1,
                          shadows: <Shadow>[
                            Shadow(
                              color: LudoColors.feltDeep.withValues(alpha: 0.9),
                              blurRadius: 2,
                              offset: const Offset(0, 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: kSpace3),
                  const _PipPair(first: 2, second: 3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PipPair extends StatelessWidget {
  const _PipPair({required this.first, required this.second});

  final int first;
  final int second;

  @override
  Widget build(BuildContext context) {
    Widget pip(int seat) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: LudoColors.seats[seat],
        shape: BoxShape.circle,
        border: Border.all(color: LudoColors.dieFace, width: 1),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[pip(first), const SizedBox(height: 6), pip(second)],
    );
  }
}
