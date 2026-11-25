// Proof for C-678 (work/ludo/orders/678-home-polish.md, EXPERIENCE.md X210):
// the home screen polish. Written from the order text, not from the lib.
//
// Six items, each with its own group:
//   1. home-logo-panel: a drawn wordmark, semantics label appTitle, no image.
//   2. locale-toggle-button: translate glyph plus a two-letter code, the same
//      size as home-sound-toggle, hit box >= 48 dp, full name in semantics.
//   3. One button style on all five home buttons: a gradient fill and no
//      white fill or border, read from the widget tree; the join field still
//      shows a different border when focused (read from painted pixels).
//   4. home-tagline: one line, FittedBox scaleDown, sentence unchanged, no
//      white card behind it.
//   5. No name chip and no recent-code chips, while session memory keeps the
//      data.
//   6. At 393x780, scale 1.0, en and ar, name field, create and join are in
//      the viewport without scrolling.
//
// Real fonts are loaded: the test font makes every glyph a full em square,
// which would fail a fit that holds on a phone.
//
// Every failure message carries a scenario string (size, locale, text scale,
// seeded memory) which is the whole recipe to reproduce it: the tests are
// deterministic, there is no seed.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/account.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/home_style.dart' show HomeGoldFramePainter;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/home_flow.dart';

const Key _logoKey = Key('home-logo-panel');
const Key _localeKey = Key('locale-toggle-button');
const Key _soundKey = Key('home-sound-toggle');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _nameKey = Key('home-name-field');
const Key _taglineKey = Key('home-tagline');
const Key _lastGameKey = Key('home-last-game');
const Key _shotKey = Key('home-polish-shot');

const String _taglineEn =
    'Every roll can be checked: independent random rolls, open source code.';
const String _taglineAr =
    'كل رمية يمكن التحقق منها: رميات عشوائية مستقلة وكود مفتوح المصدر.';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

RoomController _unusedController() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-polish-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError('home_polish_test: no transport may be opened');
    },
  );
}

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
  final FontLoader arabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    arabic.addFont(rootBundle.load(asset));
  }
  await arabic.load();
}

Widget _harness({required Locale locale, required double textScale}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(key: _shotKey, child: child!),
      );
    },
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _unusedController,
    ),
  );
}

/// Mounts Home. The surface stays at [size] until the test ends (the caller
/// registers the reset), because later pumps and captures need it.
Future<void> _mount(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(_harness(locale: locale, textScale: textScale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

String _repro(Size size, Locale locale, double scale, [String extra = '']) =>
    'scenario: HomeScreen ${size.width.toInt()}x${size.height.toInt()} '
    '${locale.languageCode} text scale $scale$extra '
    '(test/home_polish_test.dart, deterministic)';

String _lang(Locale locale) => locale.languageCode;

bool _isWhiteish(Color c) =>
    c.a >= 0.5 && c.r >= 0.94 && c.g >= 0.94 && c.b >= 0.94;

Rect _rectOf(Element e) {
  final RenderBox box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Same box as [key] give or take [slack]: the frame drawn around a control.
bool _sameFrame(Rect frame, Rect target, double slack) =>
    (frame.width - target.width).abs() <= slack * 2 &&
    (frame.height - target.height).abs() <= slack * 2 &&
    (frame.center - target.center).distance <= slack;

class _Frame {
  _Frame(this.gradients, this.colors, this.painters);
  final List<Gradient> gradients;
  final List<Color> colors;

  /// Gold frame painters found at the control's size, with that size.
  final List<(HomeGoldFramePainter, Size)> painters;
}

/// Global rects of every semantics node [matches] finds. A node's own
/// transform is relative to its parent, so the chain up to the root is
/// composed.
List<Rect> _semanticsRects(WidgetTester tester, Finder matches) {
  final List<Rect> out = <Rect>[];
  final int n = matches.evaluate().length;
  for (int i = 0; i < n; i++) {
    final SemanticsNode node = tester.getSemantics(matches.at(i));
    final Matrix4 toGlobal = Matrix4.identity();
    SemanticsNode? up = node;
    while (up != null) {
      final Matrix4? t = up.transform;
      if (t != null) toGlobal.multiply(t);
      up = up.parent;
    }
    out.add(MatrixUtils.transformRect(toGlobal, node.rect));
  }
  return out;
}

Color? _shapeSideColor(ShapeBorder? shape) {
  if (shape is OutlinedBorder && shape.side != BorderSide.none) {
    return shape.side.color;
  }
  return null;
}

/// Everything painted as a fill or an outline in the frame around [key]:
/// decorated boxes and Material layers that wrap it or sit inside it at its
/// own size, plus the resolved ButtonStyle of the keyed button. [colors] holds
/// each solid fill or border colour found, [gradients] each gradient.
_Frame _frameOf(WidgetTester tester, Finder key) {
  final Element keyed = key.evaluate().single;
  final Rect target = _rectOf(keyed);
  final List<Gradient> gradients = <Gradient>[];
  final List<Color> colors = <Color>[];
  final List<(HomeGoldFramePainter, Size)> painters =
      <(HomeGoldFramePainter, Size)>[];

  void takeDecoration(Decoration? d) {
    if (d is BoxDecoration) {
      if (d.color != null) colors.add(d.color!);
      if (d.gradient != null) gradients.add(d.gradient!);
      final BoxBorder? border = d.border;
      if (border is Border) {
        for (final BorderSide s in <BorderSide>[
          border.top,
          border.bottom,
          border.left,
          border.right,
        ]) {
          if (s != BorderSide.none) colors.add(s.color);
        }
      }
    } else if (d is ShapeDecoration) {
      if (d.color != null) colors.add(d.color!);
      if (d.gradient != null) gradients.add(d.gradient!);
      final Color? side = _shapeSideColor(d.shape);
      if (side != null) colors.add(side);
    }
  }

  final List<Element> around = <Element>[
    ...find.ancestor(of: key, matching: find.byType(DecoratedBox)).evaluate(),
    ...find.descendant(of: key, matching: find.byType(DecoratedBox)).evaluate(),
    ...key.evaluate().where((Element e) => e.widget is DecoratedBox),
  ];
  for (final Element e in around) {
    if (_sameFrame(_rectOf(e), target, 14)) {
      takeDecoration((e.widget as DecoratedBox).decoration);
    }
  }
  final List<Element> painted = <Element>[
    ...find.ancestor(of: key, matching: find.byType(CustomPaint)).evaluate(),
    ...find.descendant(of: key, matching: find.byType(CustomPaint)).evaluate(),
    ...key.evaluate().where((Element e) => e.widget is CustomPaint),
  ];
  for (final Element e in painted) {
    final CustomPainter? p = (e.widget as CustomPaint).painter;
    if (p is HomeGoldFramePainter && _sameFrame(_rectOf(e), target, 14)) {
      painters.add((p, _rectOf(e).size));
    }
  }
  final List<Element> materials = <Element>[
    ...find.ancestor(of: key, matching: find.byType(Material)).evaluate(),
    ...find.descendant(of: key, matching: find.byType(Material)).evaluate(),
  ];
  for (final Element e in materials) {
    if (!_sameFrame(_rectOf(e), target, 14)) continue;
    final Material m = e.widget as Material;
    if (m.type != MaterialType.transparency && m.color != null) {
      colors.add(m.color!);
    }
    takeDecoration(m.shape == null ? null : ShapeDecoration(shape: m.shape!));
  }
  final Widget w = keyed.widget;
  if (w is ButtonStyleButton && w.style != null) {
    final Color? bg = w.style!.backgroundColor?.resolve(<WidgetState>{});
    if (bg != null) colors.add(bg);
    final BorderSide? side = w.style!.side?.resolve(<WidgetState>{});
    if (side != null && side != BorderSide.none) colors.add(side.color);
  }
  return _Frame(gradients, colors, painters);
}

/// Rasterises [painter] alone on a transparent canvas: the colours the shared
/// frame helper really paints, independent of what sits behind it.
Future<ByteData> _paintFrame(
  WidgetTester tester,
  HomeGoldFramePainter painter,
  Size size,
) async {
  final ByteData? data = await tester.runAsync<ByteData?>(() async {
    final ui.PictureRecorder rec = ui.PictureRecorder();
    painter.paint(ui.Canvas(rec), size);
    final ui.Image img = await rec.endRecording().toImage(
      size.width.ceil(),
      size.height.ceil(),
    );
    return img.toByteData();
  });
  return data!;
}

Future<void> _expectGoldStyle(
  WidgetTester tester,
  Finder key,
  String what,
  String r,
) async {
  expect(key, findsOneWidget, reason: '$what must be on Home. $r');
  final _Frame f = _frameOf(tester, key);
  expect(
    f.gradients.isNotEmpty || f.painters.isNotEmpty,
    isTrue,
    reason:
        'expected $what to sit in the shared gold frame (a DecoratedBox with '
        'a gradient or a HomeGoldFramePainter at its own size); found none. '
        '$r',
  );
  for (final Gradient g in f.gradients) {
    expect(
      g.colors.toSet().length,
      greaterThan(1),
      reason:
          'expected the gradient of $what to change along its length (fade); '
          'got one colour ${g.colors.first}. $r',
    );
  }
  final List<Color> white = f.colors.where(_isWhiteish).toList();
  expect(
    white,
    isEmpty,
    reason:
        'expected no white fill or border on $what (light-gold tint instead); '
        'found $white. $r',
  );
  for (final (HomeGoldFramePainter, Size) p in f.painters) {
    final Size size = p.$2;
    final ByteData px = await _paintFrame(tester, p.$1, size);
    final int w = size.width.ceil();
    int opaque = 0;
    int whitePixels = 0;
    for (int i = 0; i < px.lengthInBytes; i += 4) {
      final int a = px.getUint8(i + 3);
      if (a < 8) continue;
      opaque++;
      // Unpremultiplied channels: a white fill would stay near 255.
      final double scale = 255 / a;
      if (px.getUint8(i) * scale >= 240 &&
          px.getUint8(i + 1) * scale >= 240 &&
          px.getUint8(i + 2) * scale >= 240) {
        whitePixels++;
      }
    }
    expect(
      opaque,
      greaterThan(0),
      reason: 'expected the frame painter of $what to paint something. $r',
    );
    expect(
      whitePixels,
      0,
      reason:
          'expected no white pixel in the frame painted for $what; '
          '$whitePixels of $opaque are near white. $r',
    );
    // Fade: the fill is stronger at the top edge than at the bottom edge.
    final int midX = w ~/ 2;
    final int top = size.height.ceil() ~/ 3;
    final int bottom = size.height.ceil() - 1 - size.height.ceil() ~/ 3;
    int alphaAt(int y) => px.getUint8((y * w + midX) * 4 + 3);
    expect(
      alphaAt(top),
      greaterThan(alphaAt(bottom)),
      reason:
          'expected the frame fill of $what to fade out downward, alpha '
          '${alphaAt(top)} at y=$top vs ${alphaAt(bottom)} at y=$bottom. $r',
    );
  }
}

/// The nearest ancestors of [key] that are smaller than the screen: the card
/// or frame the control sits in, never the page background.
List<Element> _cardAncestors(Finder key, Size screen) {
  final List<Element> out = <Element>[];
  for (final Type t in <Type>[DecoratedBox, Material, Card, PhysicalModel]) {
    for (final Element e
        in find.ancestor(of: key, matching: find.byType(t)).evaluate()) {
      final Rect r = _rectOf(e);
      if (r.width < screen.width - 8 && r.height < screen.height * 0.5) {
        out.add(e);
      }
    }
  }
  return out;
}

Color? _fillOf(Widget w) {
  if (w is DecoratedBox) {
    final Decoration d = w.decoration;
    if (d is BoxDecoration) return d.color;
    if (d is ShapeDecoration) return d.color;
  }
  if (w is Material) {
    return w.type == MaterialType.transparency ? null : w.color;
  }
  if (w is Card) return w.color;
  if (w is PhysicalModel) return w.color;
  return null;
}

Future<void> _seedMemoryFully() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await SessionMemory.recordSuccessfulCreate(name: 'Karim', seats: 4);
  await SessionMemory.recordSuccessfulJoin('AB23CD', name: 'Karim');
  await SessionMemory.recordSuccessfulJoin('EF45GH', name: 'Karim');
  await SessionMemory.recordSuccessfulJoin('JK67MN', name: 'Karim');
}

void main() {
  setUpAll(_loadAppFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- item 1
  group('item 1: logo panel', () {
    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: home-logo-panel is a drawn wordmark with '
          'the appTitle label and no image', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0);
        final SemanticsHandle handle = tester.ensureSemantics();
        await _mount(tester, size: size, locale: locale);

        final Finder panel = find.byKey(_logoKey);
        expect(
          panel,
          findsOneWidget,
          reason: 'expected one widget keyed home-logo-panel, found none. $r',
        );
        final Rect panelRect = tester.getRect(panel);
        expect(
          panelRect.width,
          greaterThan(100),
          reason: 'expected a panel wider than a text line, got $panelRect. $r',
        );

        final Finder label = find.bySemanticsLabel('Ludo RNG');
        expect(
          label,
          findsWidgets,
          reason:
              'expected a semantics node labelled "Ludo RNG" '
              '(loc.appTitle). $r',
        );
        final bool labelInPanel = _semanticsRects(
          tester,
          label,
        ).any((Rect nr) => panelRect.inflate(2).overlaps(nr));
        expect(
          labelInPanel,
          isTrue,
          reason:
              'expected the appTitle semantics node inside '
              'home-logo-panel $panelRect. $r',
        );

        for (final Type t in <Type>[Image, RawImage, ImageIcon]) {
          expect(
            find.descendant(of: panel, matching: find.byType(t)),
            findsNothing,
            reason:
                'expected home-logo-panel drawn in code, found a $t '
                'inside it. $r',
          );
        }
        expect(
          panel.evaluate().single.widget,
          isNot(isA<Image>()),
          reason: 'expected home-logo-panel not to be an Image. $r',
        );
        final bool drawn =
            find
                .descendant(of: panel, matching: find.byType(CustomPaint))
                .evaluate()
                .isNotEmpty ||
            find
                .descendant(of: panel, matching: find.byType(DecoratedBox))
                .evaluate()
                .isNotEmpty ||
            panel.evaluate().single.widget is DecoratedBox ||
            panel.evaluate().single.widget is CustomPaint;
        expect(
          drawn,
          isTrue,
          reason:
              'expected a CustomPaint or DecoratedBox in the panel '
              '(drawn in code). $r',
        );
        handle.dispose();
      });
    }
  });

  // ---------------------------------------------------------------- item 2
  group('item 2: language button', () {
    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: two-letter code, no full name, sound '
          'button size, 48 dp, full name in semantics', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0);
        final SemanticsHandle handle = tester.ensureSemantics();
        await _mount(tester, size: size, locale: locale);

        final Finder button = find.byKey(_localeKey);
        expect(button, findsOneWidget, reason: 'locale button missing. $r');
        final String code = locale == _en ? 'AR' : 'EN';
        final String fullName = locale == _en ? 'العربية' : 'English';

        final Finder codeText = find.descendant(
          of: button,
          matching: find.text(code),
        );
        expect(
          codeText,
          findsOneWidget,
          reason:
              'expected the button to show the two-letter code "$code" '
              '(the language it switches to). $r',
        );
        final Iterable<String> texts = tester
            .widgetList<Text>(
              find.descendant(of: button, matching: find.byType(Text)),
            )
            .map((Text t) => t.data ?? t.textSpan?.toPlainText() ?? '');
        for (final String t in texts) {
          expect(
            t.trim().length,
            2,
            reason:
                'expected every visible text on the button to be a '
                'two-letter code, got "$t". $r',
          );
        }
        expect(
          find.descendant(of: button, matching: find.textContaining(fullName)),
          findsNothing,
          reason:
              'expected no full language name "$fullName" on the '
              'button face. $r',
        );
        final bool glyph = find
            .descendant(of: button, matching: find.byType(Icon))
            .evaluate()
            .any((Element e) {
              final IconData? d = (e.widget as Icon).icon;
              return d == Icons.translate || d == Icons.translate_rounded;
            });
        expect(
          glyph,
          isTrue,
          reason:
              'expected a translate glyph (Icons.translate) on the '
              'button. $r',
        );

        final Size localeSize = tester.getSize(button);
        final Size soundSize = tester.getSize(find.byKey(_soundKey));
        expect(
          localeSize,
          soundSize,
          reason:
              'expected locale-toggle-button to be the size of '
              'home-sound-toggle ($soundSize), got $localeSize. $r',
        );
        expect(
          localeSize.width >= 48 && localeSize.height >= 48,
          isTrue,
          reason: 'expected a hit box of at least 48x48, got $localeSize. $r',
        );

        final Rect rect = tester.getRect(button);
        final bool named = _semanticsRects(
          tester,
          find.bySemanticsLabel(RegExp(fullName)),
        ).any((Rect nr) => rect.inflate(2).overlaps(nr));
        expect(
          named,
          isTrue,
          reason:
              'expected the button semantics label to carry the full '
              'name "$fullName". $r',
        );
        handle.dispose();
      });
    }
  });

  // ---------------------------------------------------------------- item 3
  group('item 3: one gold button style', () {
    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: language, sound, create, join share the '
          'gradient frame and none is white', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0, ', code typed');
        await _mount(tester, size: size, locale: locale);

        await _expectGoldStyle(
          tester,
          find.byKey(_localeKey),
          'locale button',
          r,
        );
        await _expectGoldStyle(
          tester,
          find.byKey(_soundKey),
          'sound button',
          r,
        );
        await _expectGoldStyle(
          tester,
          find.byKey(_createKey),
          'create button',
          r,
        );
        // Order 701: the second home button is the quiet one; the gold join
        // is the code entry's Join, behind the join sheet's code tile.
        await enterOldDefaultName(tester);
        await openCodeEntry(tester);
        await tester.enterText(find.byKey(_codeKey), 'AB23CD');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _expectGoldStyle(tester, find.byKey(_joinKey), 'join button', r);
      });

      testWidgets('${_lang(locale)}: verify-rolls card takes the same '
          'style', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0, ', last game seeded');
        // Order 701: the card is shown only to a player signed in with Google.
        debugGoogleSignedInOverride = true;
        addTearDown(() => debugGoogleSignedInOverride = null);
        SharedPreferences.setMockInitialValues(<String, Object>{});
        await SessionMemory.recordLastGame(
          LastGame(
            gameId: 'game-polish-1',
            verifyUrl: 'https://example.invalid/verify/game-polish-1',
            finishedAt: DateTime.now(),
            won: true,
          ),
        );
        await _mount(tester, size: size, locale: locale);
        await _expectGoldStyle(
          tester,
          find.byKey(_lastGameKey),
          'verify card',
          r,
        );
      });

      testWidgets('${_lang(locale)}: join field focus still changes its '
          'painted border', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0, ', code field focus');
        await _mount(tester, size: size, locale: locale);
        // Order 701: the field is in the join sheet and takes focus on its
        // own; take focus away so the tap below is what gives it back.
        await enterOldDefaultName(tester);
        await openCodeEntry(tester);

        // The border cross-fades on a focus change. Its duration is private
        // to InputDecorator, so the wait is on the condition it stands for:
        // the frame that starts the fade, then frames until no ticker is
        // left running. Each picture below is of a border at rest.
        Future<void> settleBorder(String after) async {
          await tester.pump();
          for (int i = 0; i < 60; i++) {
            if (tester.binding.transientCallbackCount == 0) return;
            await tester.pump(const Duration(milliseconds: 50));
          }
          fail(
            'expected the code field border to come to rest within 3 s of '
            'fake time after $after; '
            '${tester.binding.transientCallbackCount} tickers still run. $r',
          );
        }

        bool codeFocused() => tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(_codeKey),
                matching: find.byType(EditableText),
              ),
            )
            .focusNode
            .hasFocus;

        FocusManager.instance.primaryFocus?.unfocus();
        await settleBorder('unfocus');
        expect(
          codeFocused(),
          isFalse,
          reason:
              'expected room-code-field unfocused for the first '
              'picture. $r',
        );

        Future<ByteData> shot() async {
          final RenderRepaintBoundary b = tester.renderObject(
            find.byKey(_shotKey),
          );
          final ByteData? data = await tester.runAsync<ByteData?>(() async {
            final ui.Image img = await b.toImage();
            return img.toByteData();
          });
          return data!;
        }

        final Rect field = tester.getRect(find.byKey(_codeKey));
        final ByteData before = await shot();
        await tester.tap(find.byKey(_codeKey));
        await settleBorder('the tap on room-code-field');
        expect(
          codeFocused(),
          isTrue,
          reason:
              'expected the tap to focus room-code-field for the second '
              'picture. $r',
        );
        final ByteData after = await shot();

        final int w = size.width.toInt();
        // The colour on the top edge of the field, midway, in each picture:
        // named in the failure message.
        String edge(ByteData img) {
          final int o =
              ((field.top + 1).floor() * w + field.center.dx.floor()) * 4;
          final String hex = <int>[
            img.getUint8(o),
            img.getUint8(o + 1),
            img.getUint8(o + 2),
            img.getUint8(o + 3),
          ].map((int c) => c.toRadixString(16).padLeft(2, '0')).join();
          return 'rgba #$hex';
        }

        final Rect outer = field.inflate(2);
        final Rect inner = field.deflate(4);
        int differing = 0;
        for (int y = outer.top.floor(); y < outer.bottom.ceil(); y++) {
          for (int x = outer.left.floor(); x < outer.right.ceil(); x++) {
            if (inner.contains(Offset(x.toDouble(), y.toDouble()))) continue;
            final int o = (y * w + x) * 4;
            for (int c = 0; c < 4; c++) {
              if (before.getUint8(o + c) != after.getUint8(o + c)) {
                differing++;
                break;
              }
            }
          }
        }
        expect(
          differing,
          greaterThan(0),
          reason:
              'expected focusing room-code-field to repaint its border '
              'band ($outer minus $inner); 0 pixels differ (top edge '
              'unfocused ${edge(before)}, focused ${edge(after)}). $r',
        );
      });
    }
  });

  // ---------------------------------------------------------------- item 4
  group('item 4: one-line tagline', () {
    const List<Size> sizes = <Size>[Size(320, 640), Size(393, 780)];
    for (final Locale locale in _locales) {
      final String sentence = locale == _en ? _taglineEn : _taglineAr;
      for (final Size size in sizes) {
        for (final double scale in <double>[1.0, 2.0]) {
          testWidgets('${_lang(locale)} ${size.width.toInt()} wide, scale '
              '$scale', (tester) async {
            final String r = _repro(size, locale, scale);
            await _mount(tester, size: size, locale: locale, textScale: scale);

            final Finder tag = find.byKey(_taglineKey);
            expect(
              tag,
              findsOneWidget,
              reason: 'expected one widget keyed home-tagline. $r',
            );
            final Finder text = find.descendant(
              of: tag,
              matching: find.byType(Text),
            );
            expect(text, findsOneWidget, reason: 'one Text expected. $r');
            final Text t = tester.widget<Text>(text);
            expect(
              t.data ?? t.textSpan?.toPlainText(),
              sentence,
              reason: 'expected the full sentence unchanged. $r',
            );

            final Finder fitted = find.descendant(
              of: tag,
              matching: find.byType(FittedBox),
            );
            expect(
              fitted,
              findsWidgets,
              reason: 'expected a FittedBox inside home-tagline. $r',
            );
            expect(
              tester
                  .widgetList<FittedBox>(fitted)
                  .any((FittedBox f) => f.fit == BoxFit.scaleDown),
              isTrue,
              reason: 'expected FittedBox with BoxFit.scaleDown. $r',
            );

            final RenderParagraph paragraph = tester.renderObject(
              find.descendant(of: tag, matching: find.byType(RichText)),
            );
            final TextPainter oneLine = TextPainter(
              text: paragraph.text,
              textDirection: paragraph.textDirection,
              textScaler: paragraph.textScaler,
              locale: paragraph.locale,
              strutStyle: paragraph.strutStyle,
              textWidthBasis: paragraph.textWidthBasis,
              textHeightBehavior: paragraph.textHeightBehavior,
            )..layout();
            final double oneLineHeight = oneLine.height;
            final int lines = oneLine.computeLineMetrics().length;
            oneLine.dispose();
            expect(lines, 1, reason: 'sentence must be one line. $r');
            expect(
              paragraph.size.height,
              closeTo(oneLineHeight, 1.5),
              reason:
                  'expected the laid-out paragraph to be one line high '
                  '($oneLineHeight), got ${paragraph.size.height}: the text '
                  'wrapped. $r',
            );
            final Rect shown = tester.getRect(
              find.descendant(of: tag, matching: find.byType(RichText)),
            );
            expect(
              shown.left >= -0.5 && shown.right <= size.width + 0.5,
              isTrue,
              reason:
                  'expected the tagline inside the ${size.width} dp '
                  'screen, painted at $shown. $r',
            );
            expect(
              shown.width,
              lessThanOrEqualTo(paragraph.size.width + 0.5),
              reason: 'scaleDown must never enlarge the text. $r',
            );

            for (final Element e in <Element>[
              ...tag.evaluate(),
              ..._cardAncestors(tag, size),
            ]) {
              final Color? fill = _fillOf(e.widget);
              expect(
                fill != null && _isWhiteish(fill),
                isFalse,
                reason:
                    'expected no solid white card at or above the '
                    'tagline, found ${e.widget.runtimeType} filled $fill. $r',
              );
            }
            await _expectGoldStyle(tester, tag, 'the tagline', r);
          });
        }
      }
    }
  });

  // ---------------------------------------------------------------- item 5
  group('item 5: chips removed, data kept', () {
    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: no name chip, no recent-code chips with '
          'a name and three codes remembered', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(
          size,
          locale,
          1.0,
          ', memory: name Karim, codes AB23CD EF45GH JK67MN',
        );
        await _seedMemoryFully();
        await _mount(tester, size: size, locale: locale);

        expect(
          find.byKey(const Key('home-last-table-chip'), skipOffstage: false),
          findsNothing,
          reason: 'expected no home-last-table-chip. $r',
        );
        expect(
          find.byKey(const Key('home-recent-codes'), skipOffstage: false),
          findsNothing,
          reason: 'expected no home-recent-codes. $r',
        );
        for (final String code in <String>['AB23CD', 'EF45GH', 'JK67MN']) {
          expect(
            find.byKey(Key('home-recent-code-$code'), skipOffstage: false),
            findsNothing,
            reason: 'expected no home-recent-code-$code. $r',
          );
        }
        final List<Widget> stray = find
            .byWidgetPredicate((Widget w) {
              final Key? k = w.key;
              return k is ValueKey<String> &&
                  (k.value.startsWith('home-recent-code') ||
                      k.value.startsWith('home-last-table'));
            }, skipOffstage: false)
            .evaluate()
            .map((Element e) => e.widget)
            .toList();
        expect(
          stray,
          isEmpty,
          reason:
              'expected no widget keyed home-recent-code* or '
              'home-last-table*, found ${stray.map((Widget w) => w.key)}. $r',
        );
        for (final String code in <String>['AB23CD', 'EF45GH', 'JK67MN']) {
          expect(
            find.text(code, skipOffstage: false),
            findsNothing,
            reason:
                'expected the remembered code $code not to be shown as '
                'text on Home. $r',
          );
        }
      });
    }

    test('session memory still returns the name and the three codes', () async {
      await _seedMemoryFully();
      final SessionMemory memory = await SessionMemory.load();
      expect(
        memory.lastName,
        'Karim',
        reason:
            'expected lastName Karim kept in session memory after '
            'recordSuccessfulCreate/Join with name Karim',
      );
      expect(
        memory.recentCodes,
        <String>['JK67MN', 'EF45GH', 'AB23CD'],
        reason:
            'expected three recent codes, newest first, kept in session '
            'memory; got ${memory.recentCodes}',
      );
    });
  });

  // ---------------------------------------------------------------- item 6
  group('item 6: fits without scrolling at 393x780', () {
    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: the die mark is shorter than the 148 dp '
          'it had before C-678', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0);
        await _mount(tester, size: size, locale: locale);
        final Finder dice = find.byType(DieMark);
        expect(
          dice,
          findsWidgets,
          reason: 'expected the die mark to stay on Home. $r',
        );
        for (final Element e in dice.evaluate()) {
          expect(
            _rectOf(e).height,
            lessThan(148),
            reason:
                'expected the die mark lower than the 148 dp measured on '
                'origin/main 9a2758e at this size, got ${_rectOf(e).height}. $r',
          );
        }
      });
    }

    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: name field, create, join and the '
          'verify-rolls card all in view at scroll offset zero', (
        tester,
      ) async {
        const Size size = Size(393, 780);
        final String r = _repro(size, locale, 1.0, ', last game seeded');
        await _seedMemoryFully();
        await SessionMemory.recordLastGame(
          LastGame(
            gameId: 'game-polish-2',
            verifyUrl: 'https://example.invalid/verify/game-polish-2',
            finishedAt: DateTime.now(),
            won: true,
          ),
        );
        debugGoogleSignedInOverride = true;
        addTearDown(() => debugGoogleSignedInOverride = null);
        await _mount(tester, size: size, locale: locale);

        final Rect screen = Offset.zero & size;
        for (final MapEntry<String, Key> e in <String, Key>{
          'home-name-field': _nameKey,
          'create-room-button': _createKey,
          'join-game-button': joinGameButtonKey,
          'home-last-game': _lastGameKey,
        }.entries) {
          final Finder f = find.byKey(e.value);
          expect(f, findsOneWidget, reason: '${e.key} missing. $r');
          final Rect rect = tester.getRect(f);
          expect(
            screen.contains(rect.topLeft) &&
                screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
            isTrue,
            reason:
                'expected ${e.key} fully inside the $size viewport '
                'without scrolling, laid out at $rect. $r',
          );
        }
        for (final Element s in find.byType(Scrollable).evaluate()) {
          final ScrollableState state =
              (s as StatefulElement).state as ScrollableState;
          if (state.axisDirection == AxisDirection.down ||
              state.axisDirection == AxisDirection.up) {
            expect(
              state.position.maxScrollExtent,
              lessThanOrEqualTo(0.5),
              reason:
                  'expected no vertical scrolling at all (max extent '
                  '${state.position.maxScrollExtent}). $r',
            );
          }
        }
      });
    }

    for (final Locale locale in _locales) {
      testWidgets('${_lang(locale)}: name field, create and join in the '
          'viewport at scroll offset zero', (tester) async {
        const Size size = Size(393, 780);
        final String r = _repro(
          size,
          locale,
          1.0,
          ', memory: name Karim, codes AB23CD EF45GH JK67MN',
        );
        await _seedMemoryFully();
        await _mount(tester, size: size, locale: locale);

        final Rect screen = Offset.zero & size;
        for (final MapEntry<String, Key> e in <String, Key>{
          'home-name-field': _nameKey,
          'create-room-button': _createKey,
          'join-game-button': joinGameButtonKey,
        }.entries) {
          final Finder f = find.byKey(e.value);
          expect(f, findsOneWidget, reason: '${e.key} missing. $r');
          final Rect rect = tester.getRect(f);
          expect(
            screen.contains(rect.topLeft) &&
                screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
            isTrue,
            reason:
                'expected ${e.key} fully inside the $size viewport '
                'without scrolling, laid out at $rect. $r',
          );
        }
        for (final Element s in find.byType(Scrollable).evaluate()) {
          final ScrollableState state =
              (s as StatefulElement).state as ScrollableState;
          if (state.axisDirection == AxisDirection.down ||
              state.axisDirection == AxisDirection.up) {
            expect(
              state.position.maxScrollExtent,
              lessThanOrEqualTo(0.5),
              reason:
                  'expected no vertical scrolling at all (max extent '
                  '${state.position.maxScrollExtent}). $r',
            );
          }
        }
      });
    }
  });
}
