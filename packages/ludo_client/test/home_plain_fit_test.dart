// Proof for contract C-523 (work/ludo/orders/C-523-home-plain-and-one-sound-
// switch.md), rules D2 and D3, last bullet of its Proof section: at 360 dp
// wide and a text scale of 2.0, in English and in Arabic, home lays out
// without an overflow exception, the players row and the sound toggle can
// be scrolled to and used, and the players question is not clipped.
// Written from the contract text, against no implementation of it; it does
// not compile on origin/main 7501227 (home-players-button,
// home-sound-toggle, homePlayersQuestion and soundToggleLabel do not exist).
//
// Real fonts, for the reason home_screen_players_fit_test.dart gives:
// flutter_test's Ahem substitute makes every glyph a full em square, which
// is far wider than Poppins or Noto Sans Arabic and would turn a layout
// that fits on a phone into an overflow here. The font loading, the theme
// and the "replay the live paragraph into a fresh TextPainter" measurement
// are copied from that file, not imported.
//
// "Not clipped" is read two ways: the label's RenderParagraph height equals
// the height a fresh TextPainter measures for the same text at the same
// width with no line limit (a maxLines or a fixed-height parent would make
// the box shorter than the text), and the paragraph reports no overflow of
// its own. The label must also keep clear of the control it shares a row
// with and stay inside the 360 dp of the screen.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _surface = Size(360, 780);
const double _textScale = 2.0;

const Key _playersButtonKey = Key('home-players-button');
const Key _soundToggleKey = Key('home-sound-toggle');
Key _optionKey(int n) => Key('home-players-option-$n');

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

RoomController _neverConnects() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-plain-fit-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_plain_fit_test.dart: nothing here taps Create or Join, so no '
        'transport may be asked for',
      );
    },
  );
}

Widget _app(Locale locale, FeedbackSettings settings) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(_textScale)),
        child: child!,
      );
    },
    home: FeedbackScope(
      settings: settings,
      service: const NoopFeedbackService(),
      child: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: _neverConnects,
      ),
    ),
  );
}

String _repro(String scenario, Locale locale) {
  return 'Reproduce: scenario "$scenario", locale ${locale.languageCode}, '
      'surface ${_surface.width.toInt()}x${_surface.height.toInt()} at '
      'device pixel ratio 1.0, text scale $_textScale, flutter test '
      'test/home_plain_fit_test.dart --plain-name "$scenario". No random '
      'input is involved.';
}

Future<void> _mount(
  WidgetTester tester,
  Locale locale,
  FeedbackSettings settings,
) async {
  tester.view.physicalSize = _surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(locale, settings));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1000));
  await tester.pumpAndSettle();
}

/// Returns the rect of [finder], asserting it lies inside the surface; the
/// caller has already scrolled it into view.
Rect _reach(WidgetTester tester, Finder finder, String what, String repro) {
  final Rect rect = tester.getRect(finder);
  const Rect screen = Rect.fromLTWH(0, 0, 360, 780);
  expect(
    rect.left >= screen.left - 0.01 &&
        rect.top >= screen.top - 0.01 &&
        rect.right <= screen.right + 0.01 &&
        rect.bottom <= screen.bottom + 0.01,
    isTrue,
    reason:
        'expected $what fully on screen ($screen) after scrolling to it; it '
        'is at $rect. $repro',
  );
  return rect;
}

void main() {
  setUpAll(_loadAppFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final Locale locale in _locales) {
    final String lc = locale.languageCode;

    // Red on 7501227: there is no home-players-button, no home-sound-toggle
    // and no homePlayersQuestion; home_screen.dart:1520 has the old
    // disclosure and :1243 the old settings button.
    testWidgets('360 dp at text scale 2.0, $lc: no exception, the players '
        'row and the sound toggle are reachable and work', (tester) async {
      const String name = 'fit reach';
      final String repro = _repro(name, locale);
      final FeedbackSettings settings = FeedbackSettings.forTest();
      await _mount(tester, locale, settings);
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no exception while laying home out. $repro',
      );

      final Finder button = find.byKey(_playersButtonKey);
      expect(
        button,
        findsOneWidget,
        reason: 'expected home-players-button on home. $repro',
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      final Rect buttonRect = _reach(
        tester,
        button,
        'home-players-button',
        repro,
      );
      expect(
        buttonRect.width >= 48 && buttonRect.height >= 48,
        isTrue,
        reason:
            'expected home-players-button at least 48 x 48 dp at scale '
            '2.0; got ${buttonRect.size}. $repro',
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no exception opening the menu at scale 2.0. $repro',
      );
      for (final int n in <int>[2, 3, 4]) {
        final Finder option = find.byKey(_optionKey(n));
        expect(
          option,
          findsOneWidget,
          reason:
              'expected home-players-option-$n after tapping the control at '
              'scale 2.0. $repro',
        );
        _reach(tester, option, 'home-players-option-$n', repro);
      }
      await tester.tap(find.byKey(_optionKey(2)));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no exception after picking 2 at scale 2.0. $repro',
      );

      final Finder toggle = find.byKey(_soundToggleKey);
      expect(
        toggle,
        findsOneWidget,
        reason: 'expected home-sound-toggle on home. $repro',
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      final Rect toggleRect = _reach(
        tester,
        toggle,
        'home-sound-toggle',
        repro,
      );
      expect(
        toggleRect.width >= 48 && toggleRect.height >= 48,
        isTrue,
        reason:
            'expected home-sound-toggle at least 48 x 48 dp at scale 2.0; '
            'got ${toggleRect.size}. $repro',
      );
      await tester.tap(toggle);
      await tester.pump();
      expect(
        settings.muted,
        isTrue,
        reason:
            'expected a tap on home-sound-toggle at scale 2.0 to mute; '
            'settings.muted is ${settings.muted}. $repro',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no exception after the toggle tap. $repro',
      );
    });

    // Red on 7501227: no homePlayersQuestion label exists to measure.
    testWidgets('360 dp at text scale 2.0, $lc: the players question is '
        'not clipped, clear of the control, inside the screen', (tester) async {
      const String name = 'fit label';
      final String repro = _repro(name, locale);
      await _mount(tester, locale, FeedbackSettings.forTest());
      final AppLocalizations loc = AppLocalizations.of(
        tester.element(find.byType(Scaffold).first),
      );
      final Finder text = find.text(loc.homePlayersQuestion);
      expect(
        text,
        findsOneWidget,
        reason:
            'expected the label "${loc.homePlayersQuestion}" on home. $repro',
      );
      await tester.ensureVisible(text);
      await tester.pumpAndSettle();

      final Finder rich = find.descendant(
        of: text,
        matching: find.byType(RichText),
      );
      expect(
        rich,
        findsOneWidget,
        reason: 'fixture: expected one RichText under the label. $repro',
      );
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        rich,
      );
      final TextPainter probe = TextPainter(
        text: paragraph.text,
        textAlign: paragraph.textAlign,
        textDirection: paragraph.textDirection,
        textScaler: paragraph.textScaler,
        locale: paragraph.locale,
        strutStyle: paragraph.strutStyle,
        textWidthBasis: paragraph.textWidthBasis,
        textHeightBehavior: paragraph.textHeightBehavior,
      )..layout(maxWidth: paragraph.size.width);
      final double intrinsicHeight = probe.height;
      final int lines = probe.computeLineMetrics().length;
      probe.dispose();

      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason:
            'expected the label not to be cut by a line limit; the '
            'paragraph reports it exceeded maxLines ${paragraph.maxLines}. '
            '$repro',
      );
      expect(
        paragraph.size.height,
        closeTo(intrinsicHeight, 0.5),
        reason:
            'expected the label painted at its intrinsic height for width '
            '${paragraph.size.width} ($lines line(s), $intrinsicHeight dp); '
            'its box is ${paragraph.size.height} dp tall, so the text is '
            'clipped. $repro',
      );

      final Rect labelRect = tester.getRect(text);
      expect(
        labelRect.left >= -0.01 && labelRect.right <= _surface.width + 0.01,
        isTrue,
        reason:
            'expected the label inside the 360 dp width; it spans '
            '${labelRect.left} to ${labelRect.right}. $repro',
      );
      final Rect buttonRect = tester.getRect(find.byKey(_playersButtonKey));
      expect(
        labelRect.overlaps(buttonRect),
        isFalse,
        reason:
            'expected the label clear of home-players-button; label '
            '$labelRect overlaps control $buttonRect. $repro',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no exception while measuring the label. $repro',
      );
    });
  }
}
