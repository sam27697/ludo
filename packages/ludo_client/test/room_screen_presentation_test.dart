// Blind tests for the room screen's presentation contract: the code line
// must outrank the status line, in size and in colour, and neither line may
// ever come from a hardcoded literal or disappear from either state.
//
// Written from work/ludo/orders/051-room-screen-shippable-tests.md against
// packages/ludo_client/lib/src/room_screen.dart's current constructor and
// key names, not from reading the presentation change itself: that change
// lands on a different branch and is invisible here. Properties 5 and 6
// (the code line outranking the status line in size, and again in colour)
// are expected to fail on this branch for exactly that reason. Properties
// 1, 2, 3, 4, 7 and 8 describe behaviour the screen already has and are
// expected to pass.
//
// The two Text widgets under test carry a null or partial style and take
// their real font size and colour from the ambient DefaultTextStyle, so
// reading widget.style directly would compare null against null and prove
// nothing. Instead this file reads the RichText that Text always builds
// internally: Text.build merges DefaultTextStyle.of(context).style with its
// own style before handing the result to a TextSpan, and that resolved
// TextSpan is what RichText actually paints with, selection container or
// not. Reading RichText.text.style is therefore the effective style, not
// the widget's own possibly-null style field.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/room_screen.dart';

const _code = 'K7M4PQ';

Widget _harness({String? code, Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: RoomScreen(code: code),
  );
}

/// The style actually painted for the Text widget keyed [key]: not
/// `widget.style`, which this screen frequently leaves null or partial, but
/// the resolved `TextSpan.style` of the `RichText` that `Text` builds after
/// merging its own style over the ambient `DefaultTextStyle`.
TextStyle _effectiveStyle(WidgetTester tester, Key key) {
  final richTextFinder = find.descendant(
    of: find.byKey(key),
    matching: find.byType(RichText),
  );
  expect(
    richTextFinder,
    findsOneWidget,
    reason:
        'expected exactly one RichText under the Text widget keyed $key; '
        'found none or more than one, so no effective style can be read',
  );
  final richText = tester.widget<RichText>(richTextFinder);
  final span = richText.text as TextSpan;
  expect(
    span.style,
    isNotNull,
    reason:
        'RichText under key $key resolved a null TextSpan.style; Text '
        'always merges its style over DefaultTextStyle before building '
        'the RichText, so a null result here means the merge itself '
        'produced nothing usable',
  );
  return span.style!;
}

void main() {
  group('property 1: the status line is never conditional', () {
    for (final code in <String?>[null, _code]) {
      final label = code ?? 'null';
      testWidgets('code: $label -- room-screen-code, room-screen-board and '
          'room-screen-not-implemented are all present', (tester) async {
        await tester.pumpWidget(_harness(code: code));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('room-screen-code')),
          findsOneWidget,
          reason: 'code: $label -- room-screen-code should be present',
        );
        expect(
          find.byKey(const Key('room-screen-board')),
          findsOneWidget,
          reason: 'code: $label -- room-screen-board should be present',
        );
        expect(
          find.byKey(const Key('room-screen-not-implemented')),
          findsOneWidget,
          reason:
              'code: $label -- room-screen-not-implemented should be '
              'present; this line must never be removed or made '
              'conditional in either state, because it is the only '
              'honest statement on screen that there is no server '
              'connection yet, and it must not be deletable in the '
              'name of a prettier screenshot',
        );
      });
    }
  });

  group('property 2: the status line reads the localised string, in both '
      'supported languages', () {
    for (final locale in appSupportedLocales) {
      testWidgets(
        'locale ${locale.languageCode} -- room-screen-not-implemented reads '
        "AppLocalizations' roomScreenNotImplemented for that locale",
        (tester) async {
          await tester.pumpWidget(_harness(locale: locale));
          await tester.pumpAndSettle();

          final context = tester.element(find.byType(RoomScreen));
          final loc = AppLocalizations.of(context);

          expect(
            find.descendant(
              of: find.byKey(const Key('room-screen-not-implemented')),
              matching: find.text(loc.roomScreenNotImplemented),
              matchRoot: true,
            ),
            findsOneWidget,
            reason:
                'locale ${locale.languageCode} -- expected '
                'room-screen-not-implemented to read '
                '"${loc.roomScreenNotImplemented}", read from '
                'AppLocalizations rather than hardcoded here, so this '
                'proves the widget shows the localised string and not '
                'merely today\'s wording of it',
          );
        },
      );
    }
  });

  group('property 3: with a code, the code line is the room code label', () {
    testWidgets('RoomScreen(code: "$_code") -- room-screen-code reads '
        'roomScreenCodeLabel("$_code") and contains the code literally', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(code: _code));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(RoomScreen));
      final loc = AppLocalizations.of(context);
      final expected = loc.roomScreenCodeLabel(_code);

      expect(
        expected.contains(_code),
        isTrue,
        reason:
            'roomScreenCodeLabel("$_code") returned "$expected", which '
            'does not contain the literal code "$_code"; either the '
            '{code} placeholder was dropped from the translation '
            'template or this test is reading the wrong key',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('room-screen-code')),
          matching: find.text(expected),
          matchRoot: true,
        ),
        findsOneWidget,
        reason:
            'expected room-screen-code to read "$expected" '
            '(roomScreenCodeLabel with code "$_code" substituted) when '
            'RoomScreen is constructed with that code',
      );
    });
  });

  group('property 4: without a code, the code line is the no-code '
      'sentence', () {
    testWidgets('RoomScreen() -- room-screen-code reads roomScreenNoCode', (
      tester,
    ) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(RoomScreen));
      final loc = AppLocalizations.of(context);

      expect(
        find.descendant(
          of: find.byKey(const Key('room-screen-code')),
          matching: find.text(loc.roomScreenNoCode),
          matchRoot: true,
        ),
        findsOneWidget,
        reason:
            'expected room-screen-code to read '
            '"${loc.roomScreenNoCode}" when RoomScreen is constructed '
            'with no code',
      );
    });
  });

  group('property 5: the code line outranks the status line, measurably', () {
    testWidgets(
      'with a code present, the effective fontSize of room-screen-code is '
      'strictly greater than that of room-screen-not-implemented, and '
      'both are non-null',
      (tester) async {
        await tester.pumpWidget(_harness(code: _code));
        await tester.pumpAndSettle();

        final codeStyle = _effectiveStyle(
          tester,
          const Key('room-screen-code'),
        );
        final statusStyle = _effectiveStyle(
          tester,
          const Key('room-screen-not-implemented'),
        );

        expect(
          codeStyle.fontSize,
          isNotNull,
          reason:
              'room-screen-code resolved a null effective fontSize; a '
              'Text with no fontSize anywhere in its style chain still '
              'inherits one from the theme, so a null here means the '
              'merge chain is broken',
        );
        expect(
          statusStyle.fontSize,
          isNotNull,
          reason:
              'room-screen-not-implemented resolved a null effective '
              'fontSize, same failure mode as room-screen-code above',
        );
        expect(
          codeStyle.fontSize,
          greaterThan(statusStyle.fontSize!),
          reason:
              'room-screen-code measured effective fontSize '
              '${codeStyle.fontSize}, room-screen-not-implemented '
              'measured ${statusStyle.fontSize}; the code is what a '
              'player glancing at the screen or a screenshot needs '
              'first and must be strictly larger than the disclaimer '
              'beneath it',
        );
      },
    );
  });

  group('property 6: the status line is visually subordinate in colour '
      'too', () {
    testWidgets('with a code present, the effective colour of '
        'room-screen-not-implemented differs from that of room-screen-code', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(code: _code));
      await tester.pumpAndSettle();

      final codeStyle = _effectiveStyle(tester, const Key('room-screen-code'));
      final statusStyle = _effectiveStyle(
        tester,
        const Key('room-screen-not-implemented'),
      );

      expect(
        statusStyle.color,
        isNot(equals(codeStyle.color)),
        reason:
            'room-screen-not-implemented resolved effective colour '
            '${statusStyle.color}, the same value as room-screen-code\'s '
            '${codeStyle.color}; the status line should read as '
            'visually subordinate, and a smaller size with an '
            'identical colour does not establish that on its own',
      );
    });
  });

  group('property 7: neither text is resolved from a hardcoded literal', () {
    testWidgets(
      'the status line text differs between Locale("en") and Locale("ar")',
      (tester) async {
        await tester.pumpWidget(_harness(locale: const Locale('en')));
        await tester.pumpAndSettle();
        final enContext = tester.element(find.byType(RoomScreen));
        final enText = AppLocalizations.of(enContext).roomScreenNotImplemented;

        await tester.pumpWidget(_harness(locale: const Locale('ar')));
        await tester.pumpAndSettle();
        final arContext = tester.element(find.byType(RoomScreen));
        final arText = AppLocalizations.of(arContext).roomScreenNotImplemented;

        expect(
          find.descendant(
            of: find.byKey(const Key('room-screen-not-implemented')),
            matching: find.text(arText),
            matchRoot: true,
          ),
          findsOneWidget,
          reason:
              'after pumping Locale("ar"), room-screen-not-implemented '
              'should read the Arabic roomScreenNotImplemented string '
              '"$arText"',
        );
        expect(
          arText,
          isNot(equals(enText)),
          reason:
              'the English and Arabic roomScreenNotImplemented strings '
              'rendered identically ("$enText"); either the Arabic '
              'translation is missing from the arb file or the widget is '
              'showing a hardcoded English literal instead of the '
              'localised value, and both are defects worth catching here',
        );
      },
    );
  });

  group('property 8: RTL at the room screen specifically', () {
    testWidgets(
      'Locale("ar") resolves ambient Directionality.rtl and Locale("en") '
      'resolves ambient Directionality.ltr at the room screen',
      (tester) async {
        await tester.pumpWidget(_harness(locale: const Locale('en')));
        await tester.pumpAndSettle();
        final enDirection = Directionality.of(
          tester.element(find.byType(RoomScreen)),
        );

        await tester.pumpWidget(_harness(locale: const Locale('ar')));
        await tester.pumpAndSettle();
        final arDirection = Directionality.of(
          tester.element(find.byType(RoomScreen)),
        );

        expect(
          enDirection,
          TextDirection.ltr,
          reason:
              'Locale("en") resolved ambient Directionality $enDirection '
              'at the room screen; expected ltr',
        );
        expect(
          arDirection,
          TextDirection.rtl,
          reason:
              'Locale("ar") resolved ambient Directionality $arDirection '
              'at the room screen; expected rtl',
        );
      },
    );
  });
}
