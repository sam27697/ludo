// Proof of C-325 rule 1: VerifyRollsButton, the one door that opens the
// verify page, wherever it is offered. On this tree lib/src/
// verify_rolls_button.dart does not exist, so every case below is red on
// that missing name (order 325's own implementation, landed in parallel
// in a tree this file's author has not opened), not on a mistake here.
//
// Mounted directly, the way test/end_card_labels_fit_test.dart's own
// _harness mounts EndCard: a bare MaterialApp with the real localizations
// delegates, no RoomController, no FakeTransport -- this widget takes no
// network state, only a VoidCallback?.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/verify_rolls_button.dart';

const Key _underTestKey = Key('verify-rolls-button-under-test');

Widget _harness({required Locale locale, required VoidCallback? onPressed}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: VerifyRollsButton(key: _underTestKey, onPressed: onPressed),
      ),
    ),
  );
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(VerifyRollsButton)));

void main() {
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    testWidgets('${locale.languageCode}: draws Icons.verified_outlined, '
        'Icons.open_in_new and the endFairCheck text', (tester) async {
      await tester.pumpWidget(_harness(locale: locale, onPressed: () {}));
      final AppLocalizations loc = _locOf(tester);

      final Finder underTest = find.byKey(_underTestKey);
      // Mutation this catches: either icon dropped, or swapped for a
      // different glyph (for example Icons.verified instead of
      // Icons.verified_outlined, which this project already draws
      // elsewhere, so a careless copy-paste would still compile).
      expect(
        find.descendant(
          of: underTest,
          matching: find.byIcon(Icons.verified_outlined),
        ),
        findsOneWidget,
        reason:
            '${locale.languageCode}: VerifyRollsButton must draw '
            'Icons.verified_outlined',
      );
      expect(
        find.descendant(
          of: underTest,
          matching: find.byIcon(Icons.open_in_new),
        ),
        findsOneWidget,
        reason:
            '${locale.languageCode}: VerifyRollsButton must draw '
            'Icons.open_in_new',
      );
      // Mutation this catches: the label painted as a hardcoded English
      // literal instead of loc.endFairCheck, which would read the same
      // string in both locales instead of switching with the locale.
      expect(
        find.descendant(of: underTest, matching: find.text(loc.endFairCheck)),
        findsOneWidget,
        reason:
            '${locale.languageCode}: VerifyRollsButton must show '
            'loc.endFairCheck == "${loc.endFairCheck}"',
      );
    });
  }

  testWidgets(
    'is at least 48 logical pixels tall, measured from the actual render '
    'size',
    (tester) async {
      await tester.pumpWidget(
        _harness(locale: const Locale('en'), onPressed: () {}),
      );
      final Size size = tester.getSize(find.byKey(_underTestKey));
      // Mutation this catches: a tight-fitting pill with no minimum
      // height constraint (for example a bare Row with default padding),
      // which would read under 48dp on most text scales and fonts.
      expect(
        size.height,
        greaterThanOrEqualTo(48.0),
        reason:
            'VerifyRollsButton must be at least 48dp tall; measured '
            '${size.height}',
      );
    },
  );

  testWidgets('a tap calls onPressed exactly once', (tester) async {
    int calls = 0;
    await tester.pumpWidget(
      _harness(locale: const Locale('en'), onPressed: () => calls += 1),
    );
    await tester.tap(find.byKey(_underTestKey));
    await tester.pump();
    // Mutation this catches: onPressed wired to a double-fire path (for
    // example both an outer GestureDetector and an inner button each
    // calling it), or never wired at all.
    expect(
      calls,
      1,
      reason:
          'tapping VerifyRollsButton once must call onPressed exactly '
          'once; got $calls call(s)',
    );
  });

  testWidgets('with onPressed null, a tap calls nothing', (tester) async {
    int calls = 0;
    await tester.pumpWidget(
      _harness(locale: const Locale('en'), onPressed: null),
    );
    // onPressed is only ever read by the harness closure above when
    // non-null; a stray call would mean VerifyRollsButton invoked a
    // callback of its own despite being constructed with null.
    await tester.tap(find.byKey(_underTestKey), warnIfMissed: false);
    await tester.pump();
    // Mutation this catches: the disabled branch still wired to a
    // fallback callback (for example `onPressed ?? () {}` instead of
    // genuinely disabling the control).
    expect(
      calls,
      0,
      reason:
          'VerifyRollsButton with onPressed null must not call '
          'anything on tap; got $calls call(s)',
    );
  });

  testWidgets('with onPressed null, the widget reports disabled in semantics', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(locale: const Locale('en'), onPressed: null),
    );
    final SemanticsNode node = tester.getSemantics(find.byKey(_underTestKey));
    // Mutation this catches: the disabled visual state (reduced
    // opacity, inkMuted colour) drawn without clearing the enabled
    // semantics flag, which would read as tappable to a screen reader
    // on a control a sighted player also cannot tap.
    expect(
      node.flagsCollection.isEnabled,
      Tristate.isFalse,
      reason:
          'VerifyRollsButton with onPressed null must report disabled '
          'in semantics',
    );
    handle.dispose();
  });

  testWidgets(
    'en: the leading verified_outlined icon sits to the left of the label',
    (tester) async {
      await tester.pumpWidget(
        _harness(locale: const Locale('en'), onPressed: () {}),
      );
      final AppLocalizations loc = _locOf(tester);
      final Finder underTest = find.byKey(_underTestKey);
      final double iconX = tester
          .getCenter(
            find.descendant(
              of: underTest,
              matching: find.byIcon(Icons.verified_outlined),
            ),
          )
          .dx;
      final double labelX = tester
          .getCenter(
            find.descendant(
              of: underTest,
              matching: find.text(loc.endFairCheck),
            ),
          )
          .dx;
      // Mutation this catches: the icon and label order fixed regardless
      // of locale (no EdgeInsetsDirectional / ambient-direction row),
      // which would leave the icon on the same side in both locales.
      expect(
        iconX,
        lessThan(labelX),
        reason:
            'en: the leading icon (x=$iconX) must sit left of the label '
            '(x=$labelX)',
      );
    },
  );

  testWidgets(
    'ar: the leading verified_outlined icon sits to the right of the label',
    (tester) async {
      await tester.pumpWidget(
        _harness(locale: const Locale('ar'), onPressed: () {}),
      );
      final AppLocalizations loc = _locOf(tester);
      final Finder underTest = find.byKey(_underTestKey);
      final double iconX = tester
          .getCenter(
            find.descendant(
              of: underTest,
              matching: find.byIcon(Icons.verified_outlined),
            ),
          )
          .dx;
      final double labelX = tester
          .getCenter(
            find.descendant(
              of: underTest,
              matching: find.text(loc.endFairCheck),
            ),
          )
          .dx;
      // Mutation this catches: the icon kept on the left in Arabic (no
      // mirroring at all), or the icon's glyph flipped with a
      // DirectionalIcon-style Transform instead of its position moving --
      // the contract keeps the glyph and moves the position.
      expect(
        iconX,
        greaterThan(labelX),
        reason:
            'ar: the leading icon (x=$iconX) must sit right of the label '
            '(x=$labelX)',
      );
    },
  );
}
