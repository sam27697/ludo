// Widget tests for the room screen's use of the board.
//
// Written against the frozen screen spec for room_screen.dart after order
// 045 (work/ludo/orders/044-room-screen-board-tests.md), and against the
// token-key and Semantics-identifier contract board_test.dart already
// exercises for LudoBoard. Not written from room_screen.dart itself: on
// this branch that file is still main's placeholder, with no board and no
// kRoomScreenPreviewTokens constant, so every test below is expected to
// fail until order 045 lands. That failure is the point of this file, not
// a bug in it.
//
// board_test.dart's idiom for reading a token's cell is followed here
// rather than reinvented: call tester.ensureSemantics() before pumping,
// read identifiers with find.bySemanticsIdentifier or
// tester.getSemantics(...).identifier, and dispose the handle at the end
// of the test.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/room_screen.dart';

const _seats = [0, 1, 2, 3];

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

/// Every `token-seat-index` Semantics identifier currently on screen, as a
/// map so a per-token comparison is possible rather than only a set one.
/// Requires an active tester.ensureSemantics() handle.
Map<String, String> _tokenIdentifiers(WidgetTester tester) => {
  for (final seat in _seats)
    for (var index = 0; index <= 3; index++)
      'token-$seat-$index': tester
          .getSemantics(find.byKey(Key('token-$seat-$index')))
          .identifier,
};

void main() {
  group('property 1: the board is there', () {
    testWidgets(
      'exactly one LudoBoard is present, findable by room-screen-board',
      (tester) async {
        await tester.pumpWidget(_harness());
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('room-screen-board')),
          findsOneWidget,
          reason:
              'the room screen body should contain exactly one widget '
              'keyed room-screen-board; found none or more than one',
        );
        expect(
          find.byType(LudoBoard),
          findsOneWidget,
          reason:
              'the room screen body should contain exactly one LudoBoard, '
              'not two and not zero',
        );
      },
    );
  });

  group('property 2: the two texts survived', () {
    for (final code in <String?>[null, 'AB23CD']) {
      final label = code ?? 'null';
      testWidgets(
        'code: $label -- room-screen-code and room-screen-not-implemented '
        'are both present and carry the localized strings',
        (tester) async {
          await tester.pumpWidget(_harness(code: code));
          await tester.pumpAndSettle();

          final context = tester.element(find.byType(RoomScreen));
          final loc = AppLocalizations.of(context);
          final expectedCodeText = code == null
              ? loc.roomScreenNoCode
              : loc.roomScreenCodeLabel(code);

          expect(
            find.byKey(const Key('room-screen-code')),
            findsOneWidget,
            reason:
                'code: $label -- expected a widget keyed room-screen-code '
                'to still be present; wiring in the board must not have '
                'deleted it',
          );
          expect(
            find.text(expectedCodeText),
            findsOneWidget,
            reason:
                'code: $label -- expected the room-screen-code text to '
                'read "$expectedCodeText"',
          );
          expect(
            find.byKey(const Key('room-screen-not-implemented')),
            findsOneWidget,
            reason:
                'code: $label -- expected a widget keyed '
                'room-screen-not-implemented to still be present; wiring '
                'in the board must not have deleted the honesty line',
          );
          expect(
            find.text(loc.roomScreenNotImplemented),
            findsOneWidget,
            reason:
                'code: $label -- expected the room-screen-not-implemented '
                'text to read "${loc.roomScreenNotImplemented}"',
          );
        },
      );
    }
  });

  group('property 3: all sixteen tokens render', () {
    testWidgets('token-<seat>-<i> is present for every seat 0..3 and every '
        'i 0..3', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      for (final seat in _seats) {
        for (var index = 0; index <= 3; index++) {
          expect(
            find.descendant(
              of: find.byKey(const Key('room-screen-board')),
              matching: find.byKey(Key('token-$seat-$index')),
            ),
            findsOneWidget,
            reason:
                'expected exactly one token-$seat-$index inside the room '
                'screen board (seed: seat=$seat, index=$index)',
          );
        }
      }
    });
  });

  group('property 4: the layout that reached the board is '
      'kRoomScreenPreviewTokens, not a default', () {
    testWidgets("every token's Semantics identifier matches cellFor(seat, "
        'progress, tokenIndex) with progress taken from '
        'kRoomScreenPreviewTokens', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      for (final seat in _seats) {
        final progresses = kRoomScreenPreviewTokens[seat];
        expect(
          progresses,
          isNotNull,
          reason:
              'kRoomScreenPreviewTokens has no entry for seat $seat, '
              'but the spec requires all four seats 0..3',
        );
        expect(
          progresses!.length,
          4,
          reason:
              'kRoomScreenPreviewTokens[$seat] has '
              '${progresses.length} entries, expected exactly 4',
        );
        for (var index = 0; index <= 3; index++) {
          final progress = progresses[index];
          final expected = cellFor(
            seat: seat,
            progress: progress,
            tokenIndex: index,
          );
          final expectedId = 'cell-${expected.col}-${expected.row}';
          expect(
            find.descendant(
              of: find.byKey(Key('token-$seat-$index')),
              matching: find.bySemanticsIdentifier(expectedId),
              matchRoot: true,
            ),
            findsOneWidget,
            reason:
                'token-$seat-$index should carry Semantics(identifier: '
                '"$expectedId"), from kRoomScreenPreviewTokens[$seat]'
                '[$index] == $progress fed through cellFor; a board '
                'showing sixteen tokens all still in their yards would '
                'fail exactly this check (seed: seat=$seat, '
                'index=$index, progress=$progress)',
          );
        }
      }

      handle.dispose();
    });
  });

  group('property 5: the board has a real size', () {
    testWidgets(
      'the board renders as a nonzero square and is the tallest widget '
      'in the body',
      (tester) async {
        await tester.pumpWidget(_harness());
        await tester.pumpAndSettle();

        final boardSize = tester.getSize(
          find.byKey(const Key('room-screen-board')),
        );
        final codeSize = tester.getSize(
          find.byKey(const Key('room-screen-code')),
        );
        final notImplementedSize = tester.getSize(
          find.byKey(const Key('room-screen-not-implemented')),
        );

        expect(
          boardSize.width,
          greaterThan(0),
          reason:
              'the board rendered at width ${boardSize.width}; LudoBoard '
              'sizes itself from its constraints and renders nothing at '
              'all when both axes are unbounded, so a width of 0 means '
              'the room screen put it somewhere unconstrained',
        );
        expect(
          boardSize.height,
          greaterThan(0),
          reason:
              'the board rendered at height ${boardSize.height}; same '
              'failure mode as the width check above, on the other axis',
        );
        expect(
          boardSize.width,
          boardSize.height,
          reason:
              'the board rendered as ${boardSize.width} wide by '
              '${boardSize.height} tall; LudoBoard always sizes itself to '
              'a square',
        );
        expect(
          boardSize.height,
          greaterThan(codeSize.height),
          reason:
              'the board (height ${boardSize.height}) should be taller '
              'than the room code text (height ${codeSize.height}); it is '
              'meant to be the tallest thing in the body',
        );
        expect(
          boardSize.height,
          greaterThan(notImplementedSize.height),
          reason:
              'the board (height ${boardSize.height}) should be taller '
              'than the not-implemented text (height '
              '${notImplementedSize.height}); it is meant to be the '
              'tallest thing in the body',
        );
      },
    );
  });

  group('property 6: RTL does not mirror the board', () {
    testWidgets(
      'every token renders the same cell-<col>-<row> identifier in the '
      'Arabic locale as it does in English',
      (tester) async {
        final handle = tester.ensureSemantics();

        await tester.pumpWidget(_harness(locale: const Locale('en')));
        await tester.pumpAndSettle();
        final enIdentifiers = _tokenIdentifiers(tester);

        await tester.pumpWidget(_harness(locale: const Locale('ar')));
        await tester.pumpAndSettle();
        final arIdentifiers = _tokenIdentifiers(tester);

        // Compared as a map, token key to identifier, which is a strictly
        // stronger check than comparing the two identifier sets: it also
        // catches a board that mirrored by reshuffling which token carries
        // which identifier while leaving the set of identifiers unchanged.
        expect(
          arIdentifiers,
          enIdentifiers,
          reason:
              'Arabic-locale identifiers $arIdentifiers should equal '
              'English-locale identifiers $enIdentifiers token for token. '
              'The board maps a seat to an absolute (col, row) and each '
              "seat's yard is a fixed corner, so a mirrored board would "
              "put one seat's home in another seat's corner; RTL is text "
              'direction, not a board transform',
        );
        expect(
          arIdentifiers.values.toSet(),
          enIdentifiers.values.toSet(),
          reason:
              'Arabic-locale identifier set ${arIdentifiers.values.toSet()} '
              'should equal English-locale identifier set '
              '${enIdentifiers.values.toSet()}',
        );

        handle.dispose();
      },
    );
  });

  group('property 7: no overflow at a plausible phone size', () {
    testWidgets('rendering the screen at 360x800 logical pixels produces no '
        'RenderFlex overflow and no exception', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 800);

      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'rendering the room screen at a 360x800 logical-pixel '
            'surface threw or reported an exception (a RenderFlex '
            'overflow prints one of these). If the spec\'s layout '
            'genuinely overflows at this size that is a defect in the '
            'spec, not in this test, and this test must stay failing '
            'rather than shrinking the board or changing the spec to '
            'accommodate it',
      );
    });
  });
}
