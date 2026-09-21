// Widget tests for Home chip craft: recent-code chips stay compact next
// to Create, a long last-table name ellipsises on one line, and the
// last-table chrome is visually and hit-test distinct from a tappable
// recent-code chip.
//
// SessionMemory is the product store HomeScreen reads on launch. These
// tests seed it, pump Home at the named phone sizes, and assert painted
// sizes, text overflow, decoration, and tap behaviour.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Key _createKey = Key('create-room-button');
const Key _codeKey = Key('room-code-field');
const Key _lastTableKey = Key('home-last-table-chip');

const String _recentCode = 'AB23CD';
const Key _recentChipKey = Key('home-recent-code-$_recentCode');

/// 56 characters, the long-name case that must not grow the last-table chip.
const String _longRememberedName =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZABCD';

const Size _phone390 = Size(390, 844);
const Size _phone320 = Size(320, 640);

const double _lastTableMaxHeight = 48;

RoomController _unusedController() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-chip-craft-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_chip_craft_test: connector must not open a transport',
      );
    },
  );
}

class _NavProbe extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
  }
}

Widget _homeApp({NavigatorObserver? observer}) {
  return MaterialApp(
    theme: buildAppTheme(),
    builder: (BuildContext context, Widget? child) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      );
    },
    navigatorObservers: observer == null
        ? const <NavigatorObserver>[]
        : <NavigatorObserver>[observer],
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _unusedController,
    ),
  );
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required Size size,
  NavigatorObserver? observer,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_homeApp(observer: observer));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

String _codeFieldText(WidgetTester tester) {
  expect(find.byKey(_codeKey), findsOneWidget);
  return tester.widget<TextField>(find.byKey(_codeKey)).controller!.text;
}

Color? _boxBorderColor(BoxBorder? border) {
  if (border is Border) {
    return border.top.color;
  }
  if (border is BorderDirectional) {
    return border.top.color;
  }
  return null;
}

({Color? fill, Color? border})? _fillBorderOf(Widget widget) {
  if (widget is DecoratedBox && widget.decoration is BoxDecoration) {
    final BoxDecoration decoration = widget.decoration as BoxDecoration;
    return (fill: decoration.color, border: _boxBorderColor(decoration.border));
  }
  if (widget is Container && widget.decoration is BoxDecoration) {
    final BoxDecoration decoration = widget.decoration! as BoxDecoration;
    return (fill: decoration.color, border: _boxBorderColor(decoration.border));
  }
  if (widget is Material) {
    Color? border;
    final ShapeBorder? shape = widget.shape;
    if (shape is RoundedRectangleBorder) {
      border = shape.side.color;
    } else if (shape is StadiumBorder) {
      border = shape.side.color;
    } else if (shape is CircleBorder) {
      border = shape.side.color;
    }
    return (fill: widget.color, border: border);
  }
  return null;
}

bool _isChromeWidget(Widget widget) {
  return widget is DecoratedBox || widget is Container || widget is Material;
}

({Color? fill, Color? border}) _chromeNear(WidgetTester tester, Finder finder) {
  final List<({Color? fill, Color? border})> found =
      <({Color? fill, Color? border})>[];

  void consider(Widget widget) {
    final ({Color? fill, Color? border})? chrome = _fillBorderOf(widget);
    if (chrome != null && (chrome.fill != null || chrome.border != null)) {
      found.add(chrome);
    }
  }

  consider(tester.widget(finder));
  for (final Widget widget in tester.widgetList(
    find.descendant(
      of: finder,
      matching: find.byWidgetPredicate(_isChromeWidget),
    ),
  )) {
    consider(widget);
  }
  for (final Widget widget in tester.widgetList(
    find.ancestor(
      of: finder,
      matching: find.byWidgetPredicate(_isChromeWidget),
    ),
  )) {
    consider(widget);
  }

  expect(
    found,
    isNotEmpty,
    reason: 'the chip at $finder must paint a fill or border we can compare',
  );
  for (final ({Color? fill, Color? border}) chrome in found) {
    if (chrome.fill != null && chrome.border != null) {
      return chrome;
    }
  }
  return found.first;
}

bool _widgetHasTapHandler(Widget widget) {
  if (widget is InkWell) {
    return widget.onTap != null;
  }
  if (widget is InkResponse) {
    return widget.onTap != null;
  }
  if (widget is GestureDetector) {
    return widget.onTap != null || widget.onTapUp != null;
  }
  if (widget is Semantics) {
    return widget.properties.onTap != null;
  }
  return false;
}

bool _chipSubtreeHasTapHandler(WidgetTester tester, Finder finder) {
  bool found = false;
  void walk(Element element) {
    if (_widgetHasTapHandler(element.widget)) {
      found = true;
    }
    element.visitChildren(walk);
  }

  walk(tester.element(finder));
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'one recent code chip on a 390x844 phone is narrower than Create Room',
    (tester) async {
      await SessionMemory.recordSuccessfulJoin(_recentCode);
      await _pumpHome(tester, size: _phone390);

      expect(
        find.byKey(_recentChipKey),
        findsOneWidget,
        reason:
            'with one stored recent code, Home must show '
            'home-recent-code-$_recentCode',
      );
      expect(
        find.byKey(_createKey),
        findsOneWidget,
        reason: 'create-room-button must be on Home to compare widths',
      );

      final Size chip = tester.getSize(find.byKey(_recentChipKey));
      final Size create = tester.getSize(find.byKey(_createKey));
      expect(
        chip.width,
        lessThan(create.width),
        reason:
            'with one recent code on 390x844, home-recent-code-$_recentCode '
            'width (${chip.width}) must be strictly less than '
            'create-room-button width (${create.width}); a full-width bar '
            'is not a compact chip',
      );
    },
  );

  testWidgets(
    '56-character last-table name on 320x640 stays one ellipsis line at '
    'most 48 tall',
    (tester) async {
      expect(
        _longRememberedName.length,
        56,
        reason: 'fixture is broken: the remembered name must be 56 characters',
      );

      await SessionMemory.recordSuccessfulCreate(
        name: _longRememberedName,
        seats: 2,
      );
      await _pumpHome(tester, size: _phone320);

      expect(
        find.byKey(_lastTableKey),
        findsOneWidget,
        reason: 'with a remembered table, Home must show home-last-table-chip',
      );

      final Size chip = tester.getSize(find.byKey(_lastTableKey));
      expect(
        chip.height,
        lessThanOrEqualTo(_lastTableMaxHeight),
        reason:
            'with a 56-character remembered name on 320x640, '
            'home-last-table-chip height (${chip.height}) must be '
            '≤$_lastTableMaxHeight so the label cannot push Create/Join '
            'off a narrow phone',
      );

      final Finder labelFinder = find.descendant(
        of: find.byKey(_lastTableKey),
        matching: find.byType(Text),
      );
      expect(
        labelFinder,
        findsOneWidget,
        reason: 'home-last-table-chip must show a single Text label',
      );
      final Text label = tester.widget<Text>(labelFinder);
      expect(
        label.maxLines,
        1,
        reason:
            'the last-table label must be a single line (maxLines: 1); '
            'found maxLines=${label.maxLines}',
      );
      expect(
        label.overflow,
        TextOverflow.ellipsis,
        reason:
            'the last-table label must use TextOverflow.ellipsis; '
            'found overflow=${label.overflow}',
      );

      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(_lastTableKey),
          matching: find.byType(RichText),
        ),
      );
      expect(
        paragraph.maxLines,
        1,
        reason:
            'the laid-out last-table paragraph must be one line; '
            'found maxLines=${paragraph.maxLines}',
      );
      expect(
        paragraph.overflow,
        TextOverflow.ellipsis,
        reason:
            'the laid-out last-table paragraph must ellipsize; '
            'found overflow=${paragraph.overflow}',
      );
    },
  );

  testWidgets(
    'last-table chrome differs from recent-code chip and a tap does not '
    'fill the code field',
    (tester) async {
      await SessionMemory.recordSuccessfulCreate(name: 'Priya', seats: 2);
      await SessionMemory.recordSuccessfulJoin(_recentCode);

      final _NavProbe observer = _NavProbe();
      await _pumpHome(tester, size: _phone390, observer: observer);

      expect(
        find.byKey(_lastTableKey),
        findsOneWidget,
        reason: 'Home must show home-last-table-chip to compare chrome',
      );
      expect(
        find.byKey(_recentChipKey),
        findsOneWidget,
        reason:
            'Home must show home-recent-code-$_recentCode to compare chrome',
      );

      final ({Color? fill, Color? border}) lastChrome = _chromeNear(
        tester,
        find.byKey(_lastTableKey),
      );
      final ({Color? fill, Color? border}) recentChrome = _chromeNear(
        tester,
        find.byKey(_recentChipKey),
      );
      expect(
        lastChrome.fill != recentChrome.fill ||
            lastChrome.border != recentChrome.border,
        isTrue,
        reason:
            'last-table and recent-code chips must not share the same '
            'fill+border pair; last-table fill=${lastChrome.fill} '
            'border=${lastChrome.border}, recent fill=${recentChrome.fill} '
            'border=${recentChrome.border}',
      );

      expect(
        _chipSubtreeHasTapHandler(tester, find.byKey(_lastTableKey)),
        isFalse,
        reason:
            'home-last-table-chip must not wrap an InkWell, InkResponse, '
            'GestureDetector, or Semantics onTap that would make it look '
            'or act tappable',
      );

      await tester.enterText(find.byKey(_codeKey), _recentCode);
      await tester.pump();
      expect(
        _codeFieldText(tester),
        _recentCode,
        reason:
            'fixture is broken: room-code-field must hold $_recentCode '
            'before the last-table tap so a fill (or a clear) cannot hide',
      );

      final int pushesBeforeTap = observer.pushCount;
      final Finder lastTable = find.byKey(_lastTableKey);
      await tester.ensureVisible(lastTable);
      await tester.tap(lastTable);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        _codeFieldText(tester),
        _recentCode,
        reason:
            'tapping home-last-table-chip must not fill or clear '
            'room-code-field; the chip is informational only',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'tapping home-last-table-chip must not navigate',
      );
      expect(
        observer.pushCount,
        pushesBeforeTap,
        reason:
            'tapping home-last-table-chip must not push a route; pushes '
            'went from $pushesBeforeTap to ${observer.pushCount}',
      );
    },
  );
}
