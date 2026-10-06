// Acceptance tests for work/ludo/orders/C-264-names-readable.md part B
// ("the lobby seat card"), written from that contract's text alone, against
// no implementation of it: order 266 (lib/src/seat_card.dart) is being built
// in parallel by a different worker on this same base, a9b3350
// (integrate/run73); this file never touches lib/.
//
// SeatCard is mounted directly, never through LobbyScreen: C-262's own
// test/lobby_leave_corner_test.dart already proves the full connected lobby
// stays inside 360 x 616 and 800 x 600 with a real RoomController and
// FakeTransport, and that suite is named in this order as the thing that
// must stay green, not something to re-drive here. What B1-B4 ask for is
// narrower -- the card's own name-vs-furniture geometry at the width one
// column of the real grid actually gets -- so the fixture below rebuilds
// just that pressure: lib/src/lobby_screen.dart's own `_seatGrid` lays its
// cards out as two `Expanded` children of one `Row`, `kSpace2` apart,
// inside a body padded `kSpace6` on each side (read from lib/src/
// lobby_screen.dart and lib/src/theme.dart, both production files outside
// this order's file list, so this is geometry read off them for a realistic
// fixture, the same way test/board_seat_identity_test.dart reads board_
// geometry.dart's cellFor for its own fixtures -- never a copy of seat_
// card.dart's own, not-yet-written internals, since there are none on this
// base to copy). At a 360 logical px viewport that works out to kSpace6 * 2
// = 48 of outer padding and kSpace2 = 8 between the two cards, so each card
// gets (360 - 48 - 8) / 2 = 152 logical px -- the real squeeze frames 03 and
// 14 (named in the contract's "Seen" section) show as "Pr..." and "...Hu".
//
// One mount per case (lesson 35); FlutterError.onError is captured and
// restored in the body of the one case that needs it (lesson 18).
//
// "The painted text equals the full name" is read via RenderParagraph.
// didExceedMaxLines, the method the contract's own "What proves it" section
// names first -- not the fallback intrinsic-width reading, since
// didExceedMaxLines answers the exact question B1/B4 ask ("is anything
// actually cut") without first having to decide what "fits its box" means
// for a Text wrapped in Expanded.
//
// Ambiguities found while writing this file, reported rather than invented
// around:
//
//   1. B1 says "a name of up to 8 characters is shown in full on every
//      card, en and ar". Read here as: the same literal Latin name on every
//      card regardless of locale (a player's own entered name is not
//      translated by the app), with only the ambient Directionality/locale
//      switched to ar -- the same reading test/board_seat_identity_test.dart
//      bullet 3's Geometry group gives an equivalent phrase, as distinct
//      from that file's own bullet 8 (which is specifically about an
//      Arabic-script name's own content and direction, a different
//      concern B1 does not raise).
//   2. B2's "an occupied card at 360 x 616 is no taller than 64" is read as
//      the whole device viewport being 360 x 616 (test/
//      lobby_leave_corner_test.dart's own fixture naming for this exact
//      pair of numbers), not a 360-wide, 616-tall box drawn around one card.
//      The card's own height does not depend on the viewport's height in
//      either reading (nothing in the grid stretches a card to fill the
//      screen vertically), so this choice only affects the comment, not the
//      measured numbers.
//   3. No seam in seat_card.dart (there is no code there yet to find one in)
//      or in this order's contract names a "the lobby's own 2-column grid"
//      widget to mount instead of rebuilding the Row/Expanded geometry by
//      hand; see the header paragraph above for why this was rebuilt
//      from lib/src/lobby_screen.dart's and lib/src/theme.dart's own
//      numbers rather than invented.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/net/snapshot.dart' show SeatState;
import 'package:ludo_client/src/seat_card.dart';
import 'package:ludo_client/src/theme.dart' show kSpace2, kSpace6;

const String _fortyCharName = 'ZxcvbnmqweZxcvbnmqweZxcvbnmqweZxcvbnmqwe';

const SeatState _hussein = SeatState(
  seat: 0,
  name: 'Hussein',
  connected: true,
  tokens: <int>[-1, -1, -1, -1],
  clientSeed: null,
  seedOrigin: null,
);

const SeatState _karim = SeatState(
  seat: 1,
  name: 'Karim',
  connected: true,
  tokens: <int>[-1, -1, -1, -1],
  clientSeed: null,
  seedOrigin: null,
);

/// Mounts [left] and [right] exactly as lib/src/lobby_screen.dart's
/// `_seatGrid` mounts one pair of cards: a `Row` of two `Expanded` children,
/// `kSpace2` apart, `crossAxisAlignment: stretch` inside an `IntrinsicHeight`
/// so a taller card (the host card's crown and You chip) still sets both
/// cards' height, under a body padded `kSpace6` each side -- see the file
/// header for why these numbers are read from lobby_screen.dart/theme.dart
/// rather than invented.
Widget _twoColumnHarness({
  required Widget left,
  required Widget right,
  Locale locale = const Locale('en'),
}) {
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
      body: Align(
        alignment: AlignmentDirectional.topStart,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSpace6),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: left),
                const SizedBox(width: kSpace2),
                Expanded(child: right),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void _pinPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 616);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

bool _isOverflowError(FlutterErrorDetails details) {
  final String text = '${details.exception}\n$details';
  return text.contains('overflowed') ||
      text.contains('A RenderFlex overflowed');
}

/// True when every corner of [inner] lies inside [outer], within [epsilon]
/// logical pixels of slack for subpixel layout rounding -- the same
/// reading test/board_seat_identity_test.dart's own `_rectInside` gives
/// (that helper is private to its own file, so this is a copy, not a
/// shared import, of the identical check).
bool _rectInside(Rect outer, Rect inner, [double epsilon = 0.5]) {
  return inner.left >= outer.left - epsilon &&
      inner.top >= outer.top - epsilon &&
      inner.right <= outer.right + epsilon &&
      inner.bottom <= outer.bottom + epsilon;
}

/// Area of the rectangular overlap of [a] and [b], zero when they do not
/// overlap at all.
double _overlapArea(Rect a, Rect b) {
  final double left = a.left > b.left ? a.left : b.left;
  final double top = a.top > b.top ? a.top : b.top;
  final double right = a.right < b.right ? a.right : b.right;
  final double bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
  if (right <= left || bottom <= top) {
    return 0;
  }
  return (right - left) * (bottom - top);
}

void main() {
  test('fixture sanity: the long-name fixture is exactly 40 characters', () {
    expect(
      _fortyCharName.length,
      40,
      reason:
          'the contract\'s "What proves it" section names a 40-character '
          'name explicitly; the fixture string must actually be 40 '
          'characters or the overflow case below is not testing what it '
          'claims to',
    );
  });

  // ===========================================================================
  // B1, B2 -- both the host-with-crown-and-You card and a guest card show
  // their full name, at the real two-column 360px squeeze, en and ar; and
  // neither card grows past 64dp.
  // ===========================================================================
  group('C-264 part B, rules B1-B2: full names at the real grid squeeze', () {
    Future<void> runFullNameCase(WidgetTester tester, Locale locale) async {
      _pinPhoneViewport(tester);

      await tester.pumpWidget(
        _twoColumnHarness(
          left: const SeatCard(
            seat: _hussein,
            isMine: true,
            isHost: true,
            youLabel: 'You',
          ),
          right: const SeatCard(
            seat: _karim,
            isMine: false,
            isHost: false,
            youLabel: 'You',
          ),
          locale: locale,
        ),
      );
      await tester.pump();

      // B3 fixture check: the crown and the You chip must both still be on
      // the host's own card before the name-truncation question below means
      // anything -- this is the exact "disc + crown + You at once" squeeze
      // B1 names.
      expect(
        find.byKey(const Key('lobby-seat-0-host')),
        findsOneWidget,
        reason:
            'fixture (locale ${locale.languageCode}): lobby-seat-0-host '
            '(the crown) must be present on Hussein\'s card -- B1 is '
            'specifically about the case where the crown and the You chip '
            'are both there at once',
      );
      expect(
        find.byKey(const Key('lobby-seat-0-you')),
        findsOneWidget,
        reason:
            'fixture (locale ${locale.languageCode}): lobby-seat-0-you '
            'must be present on Hussein\'s own card',
      );

      final Finder husseinName = find.descendant(
        of: find.byKey(const Key('lobby-seat-0')),
        matching: find.text('Hussein'),
      );
      expect(
        husseinName,
        findsOneWidget,
        reason:
            'fixture (locale ${locale.languageCode}): lobby-seat-0 must '
            'show the literal text "Hussein"',
      );
      expect(
        tester.renderObject<RenderParagraph>(husseinName).didExceedMaxLines,
        isFalse,
        reason:
            'B1: the host\'s own card ("Hussein", 7 characters, with disc + '
            'crown + You all present) must show the name in full -- '
            'didExceedMaxLines true here means it was cut, locale '
            '${locale.languageCode}',
      );

      final Finder karimName = find.descendant(
        of: find.byKey(const Key('lobby-seat-1')),
        matching: find.text('Karim'),
      );
      expect(
        karimName,
        findsOneWidget,
        reason:
            'fixture (locale ${locale.languageCode}): lobby-seat-1 must '
            'show the literal text "Karim"',
      );
      expect(
        tester.renderObject<RenderParagraph>(karimName).didExceedMaxLines,
        isFalse,
        reason:
            'B1: the guest card ("Karim", 5 characters) must show the name '
            'in full, locale ${locale.languageCode}',
      );

      // B2: the floor stays, and the card never grows past 64 even with the
      // crown and You chip both on it.
      final double husseinHeight = tester
          .getRect(find.byKey(const Key('lobby-seat-0')))
          .height;
      final double karimHeight = tester
          .getRect(find.byKey(const Key('lobby-seat-1')))
          .height;
      for (final MapEntry<String, double> entry in <String, double>{
        'Hussein (host, crown + You)': husseinHeight,
        'Karim (guest)': karimHeight,
      }.entries) {
        expect(
          entry.value,
          greaterThanOrEqualTo(kSeatCardMinHeight),
          reason:
              'B2: ${entry.key}\'s card height (${entry.value}) must not '
              'drop below kSeatCardMinHeight ($kSeatCardMinHeight), locale '
              '${locale.languageCode}',
        );
        expect(
          entry.value,
          lessThanOrEqualTo(64),
          reason:
              'B2: ${entry.key}\'s card height (${entry.value}) must not '
              'exceed 64 at 360 x 616, locale ${locale.languageCode}',
        );
      }
    }

    testWidgets(
      'en: Hussein (host, crown + You) and Karim (guest) both show their '
      'full name; both cards stay 56..64 tall',
      (tester) async {
        await runFullNameCase(tester, const Locale('en'));
      },
    );

    testWidgets(
      'ar: Hussein (host, crown + You) and Karim (guest) both show their '
      'full name; both cards stay 56..64 tall',
      (tester) async {
        await runFullNameCase(tester, const Locale('ar'));
      },
    );
  });

  // ===========================================================================
  // B4 -- a 40-character name ellipsizes rather than overflowing.
  // ===========================================================================
  group('C-264 part B, rule B4: a 40-character name', () {
    testWidgets(
      'ellipsizes without a RenderFlex overflow error, and the Text data '
      'stays the full 40-character string',
      (tester) async {
        _pinPhoneViewport(tester);

        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final void Function(FlutterErrorDetails)? previous =
            FlutterError.onError;
        FlutterError.onError = captured.add;
        try {
          const SeatState longName = SeatState(
            seat: 2,
            name: _fortyCharName,
            connected: true,
            tokens: <int>[-1, -1, -1, -1],
            clientSeed: null,
            seedOrigin: null,
          );
          await tester.pumpWidget(
            _twoColumnHarness(
              left: const SeatCard(
                seat: longName,
                isMine: true,
                isHost: true,
                youLabel: 'You',
              ),
              right: const SeatCard(
                seat: _karim,
                isMine: false,
                isHost: false,
                youLabel: 'You',
              ),
            ),
          );
          await tester.pump();
        } finally {
          FlutterError.onError = previous;
        }

        final List<FlutterErrorDetails> overflows = captured
            .where(_isOverflowError)
            .toList();
        expect(
          overflows,
          isEmpty,
          reason:
              'B4: a 40-character name (disc + crown + You all present, '
              'same squeeze as the B1/B2 case above) must not raise a '
              'RenderFlex overflow error; got $overflows',
        );

        final Finder longNameText = find.descendant(
          of: find.byKey(const Key('lobby-seat-2')),
          matching: find.text(_fortyCharName),
        );
        expect(
          longNameText,
          findsOneWidget,
          reason:
              'the full 40-character string must still be the Text data '
              '(ellipsis is rendering, not truncation of the data itself)',
        );
        final Text text = tester.widget<Text>(longNameText);
        expect(
          text.maxLines,
          1,
          reason: 'B4: "never wrap to a third line" -- maxLines must be 1',
        );
        expect(
          text.overflow,
          TextOverflow.ellipsis,
          reason: 'B4: "ellipsize" -- overflow must be TextOverflow.ellipsis',
        );
      },
    );
  });

  // ===========================================================================
  // Order 267r1 -- frames 03/14 of screenshots 37421165858 show the host
  // crown mostly hidden under the disc and touching the name (C-264 rule B3,
  // doctrine P9: colour is never the only signal, and a badge nobody can
  // actually see is no signal at all). The host's own card, at the real
  // 152px two-column cell, must keep the crown inside the card, clear of the
  // name, and mostly clear of the disc it rides on.
  // ===========================================================================
  group('C-264 rule B3 (order 267r1): the host crown at the 152px cell stays '
      'off the name and mostly off the disc', () {
    Future<void> runCrownPlacementCase(
      WidgetTester tester,
      Locale locale,
    ) async {
      _pinPhoneViewport(tester);

      await tester.pumpWidget(
        _twoColumnHarness(
          left: const SeatCard(
            seat: _hussein,
            isMine: true,
            isHost: true,
            youLabel: 'You',
          ),
          right: const SeatCard(
            seat: _karim,
            isMine: false,
            isHost: false,
            youLabel: 'You',
          ),
          locale: locale,
        ),
      );
      await tester.pump();

      final Rect cardRect = tester.getRect(
        find.byKey(const Key('lobby-seat-0')),
      );
      final Rect crownRect = tester.getRect(
        find.byKey(const Key('lobby-seat-0-host')),
      );
      final Rect tokenRect = tester.getRect(
        find.byKey(const Key('lobby-seat-0-token')),
      );
      final Finder husseinName = find.descendant(
        of: find.byKey(const Key('lobby-seat-0')),
        matching: find.text('Hussein'),
      );
      expect(
        husseinName,
        findsOneWidget,
        reason:
            'fixture (locale ${locale.languageCode}): lobby-seat-0 must '
            'show the literal text "Hussein"',
      );
      final Rect nameRect = tester.getRect(husseinName);

      expect(
        _rectInside(cardRect, crownRect),
        isTrue,
        reason:
            'C-264 B3: lobby-seat-0-host (the crown), rect $crownRect, '
            'must lie inside lobby-seat-0\'s own rect $cardRect -- a '
            'crown that spills past its own card\'s edge is not a '
            'visible badge, locale ${locale.languageCode}',
      );

      expect(
        crownRect.overlaps(nameRect),
        isFalse,
        reason:
            'C-264 B3: lobby-seat-0-host (the crown), rect $crownRect, '
            'must not overlap the name Text\'s rect $nameRect -- frames '
            '03/14 of screenshots 37421165858 show the crown touching '
            'the name, locale ${locale.languageCode}',
      );

      final double crownArea = crownRect.width * crownRect.height;
      final double overlapWithToken = _overlapArea(crownRect, tokenRect);
      final double fractionOutsideToken = 1 - (overlapWithToken / crownArea);
      expect(
        fractionOutsideToken,
        greaterThanOrEqualTo(0.6),
        reason:
            'C-264 B3: lobby-seat-0-host (the crown), rect $crownRect, '
            'area $crownArea, overlaps lobby-seat-0-token\'s disc rect '
            '$tokenRect by $overlapWithToken -- only '
            '${(fractionOutsideToken * 100).toStringAsFixed(1)}% of the '
            'crown\'s area lies outside the disc, short of the 60% '
            'floor; frames 03/14 of screenshots 37421165858 show the '
            'crown mostly hidden under the disc, locale '
            '${locale.languageCode}',
      );
    }

    testWidgets(
      'en: the host crown on Hussein\'s own card stays inside the card, '
      'off the name, and mostly off the disc',
      (tester) async {
        await runCrownPlacementCase(tester, const Locale('en'));
      },
    );

    testWidgets(
      'ar: the host crown on Hussein\'s own card stays inside the card, '
      'off the name, and mostly off the disc',
      (tester) async {
        await runCrownPlacementCase(tester, const Locale('ar'));
      },
    );
  });
}
