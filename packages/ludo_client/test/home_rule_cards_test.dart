// Home rule cards for C-276. HomeRuleToggle (home_screen.dart) and
// RuleOffStrikePainter (rule_off_strike.dart) are the types the contract
// names. Neither exists on the old home, so this file does not compile
// there.
//
// HomeScreen is mounted the way test/home_rule_toggles_test.dart mounts it
// when a case sends create_room (HomeScreen inside MaterialApp, a fresh
// FakeTransport per connect). Cases that never tap Create pass a factory
// whose connect throws, so they cannot open a socket. One mount per case.
//
// HomeRuleToggle fields, as the contract states them: value, onChanged,
// icon, title, hint.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/rule_off_strike.dart';
import 'package:ludo_client/src/server_config.dart';

import 'net/fake_transport.dart';

const Key _disclosureKey = Key('home-players-disclosure');
const Key _selectorKey = Key('home-players-selector');
const Key _blocksKey = Key('home-rule-blocks');
const Key _captureKey = Key('home-rule-capture-bonus');
const Key _createButtonKey = Key('create-room-button');

const Size _phone = Size(360, 800);

class _LiveControllerFactory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final RoomController created = RoomController(
      serverUrl: Uri.parse('wss://home-rule-cards-test.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
    controllers.add(created);
    return created;
  }
}

RoomController _throwingFactory() {
  return RoomController(
    serverUrl: Uri.parse('wss://home-rule-cards-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'home_rule_cards_test: this connector must not be asked to open '
        'a transport',
      );
    },
  );
}

Widget _homeScreenApp({
  RoomControllerFactory? controllerFactory,
  Locale? locale,
  double textScale = 1.0,
}) {
  final Widget home = HomeScreen(
    onToggleLocale: () {},
    controllerFactory: controllerFactory ?? _throwingFactory,
  );
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
    home: Builder(
      builder: (BuildContext context) {
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: home,
        );
      },
    ),
  );
}

void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

String _formatRect(Rect rect) =>
    'left=${rect.left.toStringAsFixed(1)} '
    'top=${rect.top.toStringAsFixed(1)} '
    'right=${rect.right.toStringAsFixed(1)} '
    'bottom=${rect.bottom.toStringAsFixed(1)}';

Future<void> _openPlayersDisclosure(WidgetTester tester) async {
  final Finder disclosure = find.byKey(_disclosureKey);
  expect(
    disclosure,
    findsOneWidget,
    reason:
        'home-players-disclosure must be on screen to open the '
        'rule cards under it',
  );
  await tester.ensureVisible(disclosure);
  await tester.tap(disclosure);
  await tester.pumpAndSettle();
  expect(
    find.byKey(_selectorKey),
    findsOneWidget,
    reason: 'tapping home-players-disclosure must reveal home-players-selector',
  );
}

Finder _strikeIn(Finder card) {
  return find.descendant(
    of: card,
    matching: find.byWidgetPredicate(
      (Widget widget) =>
          widget is CustomPaint && widget.painter is RuleOffStrikePainter,
    ),
  );
}

Finder _checkIn(Finder card) {
  return find.descendant(of: card, matching: find.byIcon(Icons.check_circle));
}

/// Blocks on the start side of capture bonus (left in ltr, right in rtl),
/// same top, same height.
void _expectSideBySide(WidgetTester tester, String localeName) {
  final Finder blocks = find.byKey(_blocksKey);
  final Finder capture = find.byKey(_captureKey);
  final HomeRuleToggle blocksCard = tester.widget<HomeRuleToggle>(blocks);
  final HomeRuleToggle captureCard = tester.widget<HomeRuleToggle>(capture);
  expect(blocksCard.value, isTrue, reason: '$localeName: blocks starts on');
  expect(
    captureCard.value,
    isTrue,
    reason: '$localeName: capture bonus starts on',
  );

  final Rect blocksRect = tester.getRect(blocks);
  final Rect captureRect = tester.getRect(capture);
  final bool ltr =
      Directionality.of(tester.element(blocks)) == TextDirection.ltr;
  expect(
    ltr
        ? blocksRect.center.dx < captureRect.center.dx
        : blocksRect.center.dx > captureRect.center.dx,
    isTrue,
    reason:
        '$localeName: blocks must sit on the start side of capture bonus '
        '(${ltr ? 'left' : 'right'}); blocks ${_formatRect(blocksRect)}, '
        'capture ${_formatRect(captureRect)}',
  );
  expect(
    blocksRect.top,
    captureRect.top,
    reason:
        '$localeName: the two cards must share a top; '
        'blocks ${_formatRect(blocksRect)}, '
        'capture ${_formatRect(captureRect)}',
  );
  expect(
    blocksRect.height,
    captureRect.height,
    reason:
        '$localeName: the two cards must share a height; '
        'blocks ${_formatRect(blocksRect)}, '
        'capture ${_formatRect(captureRect)}',
  );
}

Future<void> _tapAndAwaitPushedRoute(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

List<Map<String, Object?>> _decodeSent(FakeTransport transport) {
  return transport.sentRaw
      .map((String raw) => jsonDecode(raw) as Map<String, Object?>)
      .toList();
}

void main() {
  testWidgets(
    'en: rules open, both cards are HomeRuleToggle, no SwitchListTile '
    'and no Switch, blocks on the start side',
    (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(_homeScreenApp(locale: const Locale('en')));
      await tester.pumpAndSettle();

      await _openPlayersDisclosure(tester);

      expect(
        tester.widget<HomeRuleToggle>(find.byKey(_blocksKey)).icon,
        Icons.shield_outlined,
        reason: 'blocks must use Icons.shield_outlined',
      );
      expect(
        tester.widget<HomeRuleToggle>(find.byKey(_captureKey)).icon,
        Icons.replay_rounded,
        reason: 'capture bonus must use Icons.replay_rounded',
      );
      expect(
        find.byType(SwitchListTile),
        findsNothing,
        reason: 'rules open must not build a SwitchListTile',
      );
      expect(
        find.byType(Switch),
        findsNothing,
        reason: 'rules open must not build a Switch',
      );
      _expectSideBySide(tester, 'en');
    },
  );

  testWidgets('ar: rules open, blocks sits on the start side of capture bonus, '
      'same top and same height', (tester) async {
    _usePhone(tester);
    await tester.pumpWidget(_homeScreenApp(locale: const Locale('ar')));
    await tester.pumpAndSettle();

    await _openPlayersDisclosure(tester);

    expect(
      Directionality.of(tester.element(find.byKey(_blocksKey))),
      TextDirection.rtl,
      reason: 'ar fixture: the cards must lay out rtl',
    );
    _expectSideBySide(tester, 'ar');
  });

  testWidgets('blocks card on shows a check and no strike; a tap turns it off; '
      'a second tap turns it back on; semantics isToggled follows value', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    var semanticsDisposed = false;
    void disposeSemantics() {
      if (semanticsDisposed) {
        return;
      }
      semanticsDisposed = true;
      handle.dispose();
    }

    addTearDown(disposeSemantics);

    _usePhone(tester);
    await tester.pumpWidget(_homeScreenApp(locale: const Locale('en')));
    await tester.pumpAndSettle();
    await _openPlayersDisclosure(tester);

    final Finder blocks = find.byKey(_blocksKey);
    final AppLocalizations loc = AppLocalizations.of(tester.element(blocks));

    void expectSemantics(bool value) {
      final HomeRuleToggle card = tester.widget<HomeRuleToggle>(blocks);
      expect(card.value, value, reason: 'HomeRuleToggle.value must be $value');
      final SemanticsNode node = tester.getSemantics(blocks);
      expect(
        node.flagsCollection.isButton,
        isTrue,
        reason: 'the card must be one semantics button',
      );
      expect(
        node.flagsCollection.isToggled.toBoolOrNull(),
        value,
        reason:
            'semantics isToggled must follow HomeRuleToggle.value '
            '($value); flags were ${node.flagsCollection}',
      );
      expect(
        node.label,
        card.title,
        reason:
            'semantics label must be the card title "${card.title}"; '
            'got "${node.label}"',
      );
      expect(
        node.hint,
        card.hint,
        reason:
            'semantics hint must be the card hint "${card.hint}"; '
            'got "${node.hint}"',
      );
      expect(
        card.title,
        loc.homeRuleBlocks,
        reason: 'blocks title must be the homeRuleBlocks string',
      );
      expect(
        card.hint,
        loc.homeRuleBlocksHint,
        reason: 'blocks hint must be the homeRuleBlocksHint string',
      );
    }

    expect(_checkIn(blocks), findsOneWidget, reason: 'on: a check badge');
    expect(_strikeIn(blocks), findsNothing, reason: 'on: no strike');
    expectSemantics(true);

    await tester.ensureVisible(blocks);
    await tester.tap(blocks);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));

    expect(_checkIn(blocks), findsNothing, reason: 'off: no check badge');
    expect(
      _strikeIn(blocks),
      findsOneWidget,
      reason: 'off: a RuleOffStrikePainter over the icon',
    );
    expectSemantics(false);

    await tester.tap(blocks);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));

    expect(_checkIn(blocks), findsOneWidget, reason: 'on again: a check');
    expect(_strikeIn(blocks), findsNothing, reason: 'on again: no strike');
    expectSemantics(true);

    disposeSemantics();
  });

  testWidgets('turning blocks off then Create sends blocks false and '
      'capture_bonus true', (tester) async {
    final _LiveControllerFactory factory = _LiveControllerFactory();
    var disposed = false;
    void disposeControllers() {
      if (disposed) {
        return;
      }
      disposed = true;
      for (final RoomController controller in factory.controllers) {
        controller.dispose();
      }
    }

    addTearDown(disposeControllers);

    _usePhone(tester);
    await tester.pumpWidget(
      _homeScreenApp(
        controllerFactory: factory.call,
        locale: const Locale('en'),
      ),
    );
    await tester.pumpAndSettle();
    await _openPlayersDisclosure(tester);

    await tester.ensureVisible(find.byKey(_blocksKey));
    await tester.tap(find.byKey(_blocksKey));
    await tester.pump();
    expect(
      tester.widget<HomeRuleToggle>(find.byKey(_blocksKey)).value,
      isFalse,
      reason:
          'fixture: tapping home-rule-blocks must turn its value off '
          'before Create is tapped',
    );
    expect(
      tester.widget<HomeRuleToggle>(find.byKey(_captureKey)).value,
      isTrue,
      reason: 'fixture: capture bonus must still be on',
    );

    await _tapAndAwaitPushedRoute(tester, _createButtonKey);

    expect(
      factory.transports,
      hasLength(1),
      reason:
          'fixture: Create must have opened exactly one transport; '
          'got ${factory.transports.length}',
    );
    final List<Map<String, Object?>> sent = _decodeSent(
      factory.transports.single,
    );
    expect(
      sent,
      hasLength(1),
      reason:
          'fixture: exactly one frame must have been sent; got '
          '${sent.map((Map<String, Object?> frame) => frame['t']).toList()}',
    );
    expect(sent.single['t'], 'create_room');
    final Map<String, Object?> data = sent.single['d']! as Map<String, Object?>;
    final Map<String, Object?> rules = data['rules']! as Map<String, Object?>;
    expect(
      rules['blocks'],
      isFalse,
      reason:
          'create_room rules.blocks must be false after the blocks '
          'card was turned off; rules were $rules',
    );
    expect(
      rules['capture_bonus'],
      isTrue,
      reason:
          'create_room rules.capture_bonus must stay true; rules were '
          '$rules',
    );

    disposeControllers();
  });

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final double textScale in const <double>[1.0, 1.3]) {
      final String localeName = locale.languageCode;
      testWidgets(
        '$localeName text scale $textScale: rules open, no exception, '
        'both cards inside the view width',
        (tester) async {
          _usePhone(tester);
          await tester.pumpWidget(
            _homeScreenApp(locale: locale, textScale: textScale),
          );
          await tester.pumpAndSettle();
          await _openPlayersDisclosure(tester);

          expect(
            tester.takeException(),
            isNull,
            reason:
                '$localeName scale $textScale: rules open at $_phone must '
                'not throw',
          );

          final double viewWidth =
              tester.view.physicalSize.width / tester.view.devicePixelRatio;
          for (final Key key in <Key>[_blocksKey, _captureKey]) {
            final String name = (key as ValueKey<String>).value;
            final Rect rect = tester.getRect(find.byKey(key));
            expect(
              rect.left,
              greaterThanOrEqualTo(0),
              reason:
                  '$localeName scale $textScale: $name left must be inside '
                  'the view width $viewWidth; rect ${_formatRect(rect)}',
            );
            expect(
              rect.right,
              lessThanOrEqualTo(viewWidth),
              reason:
                  '$localeName scale $textScale: $name right must be inside '
                  'the view width $viewWidth; rect ${_formatRect(rect)}',
            );
          }
        },
      );
    }
  }

  // C-276 rule 3a: each card draws its own title and hint, in the player's
  // language. The hint is what tells a first-time player what the rule does.
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    testWidgets('${locale.languageCode}: each card draws its own title and '
        'hint', (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(_homeScreenApp(locale: locale));
      await tester.pumpAndSettle();
      await _openPlayersDisclosure(tester);

      final AppLocalizations loc = lookupAppLocalizations(locale);
      final List<(Key, String, String)> cards = <(Key, String, String)>[
        (_blocksKey, loc.homeRuleBlocks, loc.homeRuleBlocksHint),
        (_captureKey, loc.homeRuleCaptureBonus, loc.homeRuleCaptureBonusHint),
      ];
      for (final (Key key, String title, String hint) in cards) {
        for (final String text in <String>[title, hint]) {
          expect(
            find.descendant(of: find.byKey(key), matching: find.text(text)),
            findsOneWidget,
            reason: '${locale.languageCode}: "$text" must be drawn inside $key',
          );
        }
      }
    });
  }
}
