// Proof of C-620 (order 620t): when a game's record was not saved, the end
// card says so in place of the fairness claim, instead of a dead Check button.
//
// The contract, read as written (work/ludo/orders/620-end-card-record-not-kept
// .md):
//   D1. verifyUrl null or empty: the card draws neither the fairness line
//       (endFairLine), nor the info hint (end-card-fair-hint), nor the Check
//       button (game-screen-verify-button). In their place one line of text
//       with key end-card-record-not-kept, string endRecordNotKept:
//         en "This game's record could not be saved, so its rolls cannot be
//             checked."
//         ar «تعذّر حفظ سجل هذه اللعبة، لذلك لا يمكن التحقق من رمياتها.»
//       Style of the fairness line (LudoColors.inkMuted, kTypeLabel), wraps,
//       no icon, no button, plain text to a screen reader.
//   D2. verifyUrl non-empty: today's behaviour byte for byte.
//   D3. Winner, loser and ended variants all follow D1 and D2.
//   D4. endRecordNotKept is in app_en.arb (with an @endRecordNotKept
//       description) and in app_ar.arb.
//
// This file never references the new AppLocalizations getter, so it compiles
// on a tree that does not have it yet. The D1 strings are spelled out below
// from the contract, and the arb files are read as plain JSON. Existing
// strings (endFairLine, endFairCheck, endFairHint) are read through the
// localizations the app itself uses.
//
// Surfaces:
//   - EndCard mounted directly, the way test/end_card_large_text_test.dart
//     does it (a bare MaterialApp with the real delegates), for the matrix
//     of locale x variant x url shape.
//   - GameScreen over a real RoomController and a FakeTransport, the way
//     test/c614_verify_link_lang_test.dart does it, with the room snapshot
//     carrying verify_url "" or no verify_url at all, so the empty string the
//     server really sends reaches the card through the real wire path.
//
// Reproduce one case: run this file with --plain-name "<case name>"; every
// case name below carries the locale, the variant and the url shape, and
// every failure message repeats them as `scenario`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4, kTypeLabel;
import 'package:ludo_client/src/verify_rolls_button.dart';

import 'net/fake_transport.dart';

const Key _notKeptKey = Key('end-card-record-not-kept');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _fairHintKey = Key('end-card-fair-hint');

const String _enNotKept =
    "This game's record could not be saved, so its rolls cannot be checked.";
const String _arNotKept =
    'تعذّر حفظ سجل هذه اللعبة، لذلك لا يمكن التحقق من رمياتها.';

const String _realUrl = 'https://c620-record-not-kept.invalid/v/real-game';

const String _wsUrl = 'wss://c620-record-not-kept.invalid/ws';

String _notKeptFor(Locale locale) =>
    locale.languageCode == 'ar' ? _arNotKept : _enNotKept;

enum _Variant { winner, loser, ended }

enum _Url { empty, absent, real }

extension on _Url {
  String? get value => switch (this) {
    _Url.empty => '',
    _Url.absent => null,
    _Url.real => _realUrl,
  };
  String get label => switch (this) {
    _Url.empty => "verifyUrl ''",
    _Url.absent => 'verifyUrl null',
    _Url.real => 'verifyUrl https',
  };
}

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

// --- direct EndCard harness -------------------------------------------------

Widget _app(Locale locale, Widget home, {double textScale = 1.0}) {
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
        child: child!,
      );
    },
    home: home,
  );
}

EndCard _card({
  required _Variant variant,
  required String? verifyUrl,
  required VoidCallback onVerify,
}) {
  final int? winnerSeat = switch (variant) {
    _Variant.winner => 0,
    _Variant.loser => 1,
    _Variant.ended => null,
  };
  final String? winnerName = switch (variant) {
    _Variant.winner => 'Sam',
    _Variant.loser => 'Bob',
    _Variant.ended => null,
  };
  return EndCard(
    mySeat: 0,
    winnerSeat: winnerSeat,
    winnerName: winnerName,
    seatColors: LudoColors.seats,
    stats: null,
    verifyUrl: verifyUrl,
    onVerify: onVerify,
    onNewTable: () {},
    onRematch: () {},
  );
}

Widget _cardApp(
  Locale locale, {
  required _Variant variant,
  required String? verifyUrl,
  required VoidCallback onVerify,
  double textScale = 1.0,
}) {
  return _app(
    locale,
    Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace4),
        child: _card(
          variant: variant,
          verifyUrl: verifyUrl,
          onVerify: onVerify,
        ),
      ),
    ),
    textScale: textScale,
  );
}

/// One bounded pump past the celebration burst (1200 ms); never a settle.
Future<void> _pumpCard(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1200));
}

Future<void> _onSurface(
  WidgetTester tester,
  Size size,
  Future<void> Function() body,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await body();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// Every string drawn by a Text or RichText under the screen, joined.
String _screenText(WidgetTester tester) {
  final StringBuffer out = StringBuffer();
  for (final Element e in find.byType(Text).evaluate()) {
    final Text t = e.widget as Text;
    out.writeln(t.data ?? t.textSpan?.toPlainText() ?? '');
  }
  return out.toString();
}

/// The Text widget that is the D1 line: the keyed widget itself, or a Text
/// below the keyed widget.
Finder _notKeptText() => find.descendant(
  of: find.byKey(_notKeptKey),
  matching: find.byType(Text),
  matchRoot: true,
);

/// D1 for an empty or absent url: the line, and none of the three things it
/// replaces.
void _expectRecordNotKept(
  WidgetTester tester, {
  required String scenario,
  required Locale locale,
}) {
  final AppLocalizations loc = _locOf(tester);
  final String expected = _notKeptFor(locale);
  final String blob = _screenText(tester);
  expect(
    find.byKey(_notKeptKey),
    findsOneWidget,
    reason:
        'scenario "$scenario": expected exactly one widget with key '
        'end-card-record-not-kept carrying "$expected"; none or several '
        'found. Screen text was: $blob',
  );
  final Finder line = _notKeptText();
  expect(
    line,
    findsOneWidget,
    reason:
        'scenario "$scenario": expected the keyed widget to be (or hold) '
        'exactly one Text',
  );
  final Text text = tester.widget<Text>(line);
  expect(
    text.data ?? text.textSpan?.toPlainText(),
    expected,
    reason:
        'scenario "$scenario": the end-card-record-not-kept text must be '
        'exactly the D1 wording',
  );
  expect(
    find.text(expected),
    findsOneWidget,
    reason:
        'scenario "$scenario": the D1 wording must be drawn exactly once; '
        'screen text was: $blob',
  );
  expect(
    find.byKey(_verifyKey),
    findsNothing,
    reason:
        'scenario "$scenario": expected no game-screen-verify-button (a '
        'dead button under a claim); one is drawn',
  );
  expect(
    find.byType(VerifyRollsButton),
    findsNothing,
    reason: 'scenario "$scenario": expected no VerifyRollsButton at all',
  );
  expect(
    find.byKey(_fairHintKey),
    findsNothing,
    reason: 'scenario "$scenario": expected no end-card-fair-hint',
  );
  expect(
    find.byIcon(Icons.info_outline),
    findsNothing,
    reason: 'scenario "$scenario": expected no info icon on the card',
  );
  expect(
    find.text(loc.endFairLine),
    findsNothing,
    reason:
        'scenario "$scenario": expected the fairness line '
        '"${loc.endFairLine}" to be absent when the record was not kept',
  );
  expect(
    find.text(loc.endFairCheck),
    findsNothing,
    reason:
        'scenario "$scenario": expected the Check text '
        '"${loc.endFairCheck}" to be absent when the record was not kept',
  );
}

/// D2: today's behaviour with a real url.
Future<void> _expectVerifiable(
  WidgetTester tester, {
  required String scenario,
}) async {
  final AppLocalizations loc = _locOf(tester);
  expect(
    find.byKey(_notKeptKey),
    findsNothing,
    reason:
        'scenario "$scenario": expected no end-card-record-not-kept with a '
        'real verify url; it is drawn',
  );
  expect(
    find.text(_enNotKept),
    findsNothing,
    reason: 'scenario "$scenario": the en D1 wording must not be drawn',
  );
  expect(
    find.text(_arNotKept),
    findsNothing,
    reason: 'scenario "$scenario": the ar D1 wording must not be drawn',
  );
  expect(
    find.text(loc.endFairLine),
    findsOneWidget,
    reason:
        'scenario "$scenario": expected the fairness line '
        '"${loc.endFairLine}" with a real url; screen text was: '
        '${_screenText(tester)}',
  );
  expect(
    find.byKey(_fairHintKey),
    findsOneWidget,
    reason: 'scenario "$scenario": expected end-card-fair-hint with a real url',
  );
  final Finder button = find.byKey(_verifyKey);
  expect(
    button,
    findsOneWidget,
    reason:
        'scenario "$scenario": expected game-screen-verify-button with a '
        'real url',
  );
  expect(
    tester.widget<VerifyRollsButton>(button).onPressed,
    isNotNull,
    reason:
        'scenario "$scenario": expected the Check button enabled with a real '
        'url; it is disabled',
  );
}

String _describe(Locale locale, _Variant variant, _Url url) =>
    '${locale.languageCode} ${variant.name} ${url.label}';

// --- wire harness: a real RoomController over a FakeTransport ---------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c620-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _finishedRoomJson({
  required int? winner,
  required _Url url,
}) => <String, Object?>{
  'code': 'C620XX',
  'state': 'FINISHED',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': 'c620-game',
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ],
  'turn': <String, Object?>{
    'seat': 0,
    'phase': 'finished',
    'deadline_ms': 0,
    'k': 1,
  },
  'winner': winner,
  'verify_url': ?url.value,
  'seq': 1,
};

Future<void> _mountFinishedGameScreen(
  WidgetTester tester, {
  required Locale locale,
  required int? winner,
  required _Url url,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_wsUrl),
    connect: (Uri u) async => transport,
  );
  addTearDown(controller.dispose);

  final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _finishedRoomJson(winner: winner, url: url),
    ),
  );
  await created;

  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(locale, GameScreen(controller: controller)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1200));
  // Landing on FINISHED fires the game_log fetch; this transport never
  // answers it, so its request timeout is flushed rather than left pending.
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

// --- fonts for the layout case ----------------------------------------------

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

void main() {
  setUpAll(_loadAppFonts);

  // ===========================================================================
  // D4: the arb entries. Plain JSON, no generated code.
  // ===========================================================================
  group('D4 arb entries', () {
    Map<String, Object?> arb(String name) {
      final File file = File('lib/l10n/$name');
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'expected ${file.absolute.path} to exist (run from the package)',
      );
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }

    test('app_en.arb has endRecordNotKept with the D1 wording', () {
      final Map<String, Object?> en = arb('app_en.arb');
      expect(
        en['endRecordNotKept'],
        _enNotKept,
        reason:
            'scenario "arb en": expected lib/l10n/app_en.arb key '
            'endRecordNotKept to be exactly "$_enNotKept"; got '
            '${en['endRecordNotKept']}',
      );
    });

    test('app_en.arb has an @endRecordNotKept description', () {
      final Map<String, Object?> en = arb('app_en.arb');
      final Object? meta = en['@endRecordNotKept'];
      expect(
        meta,
        isA<Map<String, Object?>>(),
        reason:
            'scenario "arb en meta": expected an @endRecordNotKept object '
            'in lib/l10n/app_en.arb, like @endFairLine; got $meta',
      );
      final Object? description = (meta as Map<String, Object?>)['description'];
      expect(
        description,
        isA<String>().having((String s) => s.trim(), 'trimmed', isNotEmpty),
        reason:
            'scenario "arb en meta": expected @endRecordNotKept to carry a '
            'non-empty description; got $description',
      );
    });

    test('app_ar.arb has endRecordNotKept with the D1 wording', () {
      final Map<String, Object?> ar = arb('app_ar.arb');
      expect(
        ar['endRecordNotKept'],
        _arNotKept,
        reason:
            'scenario "arb ar": expected lib/l10n/app_ar.arb key '
            'endRecordNotKept to be exactly "$_arNotKept"; got '
            '${ar['endRecordNotKept']}',
      );
    });
  });

  // ===========================================================================
  // (a) and (b): the three variants with an empty and with a null verifyUrl.
  // ===========================================================================
  for (final Locale locale in _locales) {
    for (final _Url url in const <_Url>[_Url.empty, _Url.absent]) {
      for (final _Variant variant in _Variant.values) {
        final String scenario = _describe(locale, variant, url);
        testWidgets('(${url == _Url.empty ? 'a' : 'b'}) $scenario: the card '
            'says the record was not kept and draws no fairness claim', (
          WidgetTester tester,
        ) async {
          int verifies = 0;
          await _onSurface(tester, const Size(390, 844), () async {
            await _pumpCard(
              tester,
              _cardApp(
                locale,
                variant: variant,
                verifyUrl: url.value,
                onVerify: () => verifies += 1,
              ),
            );
            _expectRecordNotKept(tester, scenario: scenario, locale: locale);
            expect(
              verifies,
              0,
              reason: 'scenario "$scenario": onVerify must never be called',
            );
            expect(
              tester.takeException(),
              isNull,
              reason: 'scenario "$scenario": the card threw while building',
            );
          });
        });
      }
    }
  }

  // ===========================================================================
  // (c): a real url keeps today's behaviour in all three variants.
  // ===========================================================================
  for (final Locale locale in _locales) {
    for (final _Variant variant in _Variant.values) {
      final String scenario = _describe(locale, variant, _Url.real);
      testWidgets('(c) $scenario: fairness line, hint and an enabled button; '
          'a tap calls onVerify once', (WidgetTester tester) async {
        int verifies = 0;
        await _onSurface(tester, const Size(390, 844), () async {
          await _pumpCard(
            tester,
            _cardApp(
              locale,
              variant: variant,
              verifyUrl: _realUrl,
              onVerify: () => verifies += 1,
            ),
          );
          await _expectVerifiable(tester, scenario: scenario);

          final Finder button = find.byKey(_verifyKey);
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pump();
          expect(
            verifies,
            1,
            reason:
                'scenario "$scenario": expected one tap on '
                'game-screen-verify-button to call onVerify exactly once; '
                'it was called $verifies times',
          );
          expect(tester.takeException(), isNull);
        });
      });
    }
  }

  // ===========================================================================
  // The rule follows the url as it changes under a mounted card.
  // ===========================================================================
  for (final Locale locale in _locales) {
    testWidgets('${locale.languageCode} loser: the card follows verifyUrl '
        'from real to empty and back', (WidgetTester tester) async {
      final String scenario =
          '${locale.languageCode} loser real -> empty -> real';
      await _onSurface(tester, const Size(390, 844), () async {
        Widget at(String? url) => _cardApp(
          locale,
          variant: _Variant.loser,
          verifyUrl: url,
          onVerify: () {},
        );
        await _pumpCard(tester, at(_realUrl));
        await _expectVerifiable(tester, scenario: '$scenario: first real');

        await tester.pumpWidget(at(''));
        await tester.pump();
        _expectRecordNotKept(
          tester,
          scenario: '$scenario: then empty',
          locale: locale,
        );

        await tester.pumpWidget(at(_realUrl));
        await tester.pump();
        await _expectVerifiable(tester, scenario: '$scenario: real again');
      });
    });
  }

  // ===========================================================================
  // (d): to a screen reader the D1 line is plain text.
  // ===========================================================================
  for (final Locale locale in _locales) {
    for (final _Variant variant in _Variant.values) {
      final String scenario = _describe(locale, variant, _Url.empty);
      testWidgets('(d) $scenario: the D1 line is a text node, not a button, '
          'not tappable', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        try {
          await _onSurface(tester, const Size(390, 844), () async {
            await _pumpCard(
              tester,
              _cardApp(
                locale,
                variant: variant,
                verifyUrl: '',
                onVerify: () {},
              ),
            );
            final Finder keyed = find.byKey(_notKeptKey);
            expect(
              keyed,
              findsOneWidget,
              reason:
                  'scenario "$scenario": expected a widget with key '
                  'end-card-record-not-kept',
            );
            final SemanticsNode node = tester.getSemantics(keyed);
            final SemanticsData data = node.getSemanticsData();
            final String expected = _notKeptFor(locale);
            expect(
              data.label,
              expected,
              reason:
                  'scenario "$scenario": expected the semantics label to be '
                  'the D1 wording; got "${data.label}"',
            );
            expect(
              data.flagsCollection.isButton,
              isFalse,
              reason: 'scenario "$scenario": the D1 line must not be a button',
            );
            expect(
              data.hasAction(SemanticsAction.tap),
              isFalse,
              reason:
                  'scenario "$scenario": the D1 line must have no tap action',
            );
            expect(
              data.hasAction(SemanticsAction.longPress),
              isFalse,
              reason:
                  'scenario "$scenario": the D1 line must have no long-press '
                  'action',
            );
            expect(
              find.ancestor(
                of: _notKeptText(),
                matching: find.byWidgetPredicate(
                  (Widget w) =>
                      w is ButtonStyleButton ||
                      w is InkResponse ||
                      w is GestureDetector && w.onTap != null,
                ),
              ),
              findsNothing,
              reason:
                  'scenario "$scenario": the D1 line must not sit inside a '
                  'tappable widget',
            );
          });
        } finally {
          handle.dispose();
        }
      });
    }
  }

  // The D1 line is drawn in the fairness line's style.
  for (final Locale locale in _locales) {
    testWidgets('${locale.languageCode} loser verifyUrl \'\': the D1 line is '
        'inkMuted at kTypeLabel with no icon', (WidgetTester tester) async {
      final String scenario = _describe(locale, _Variant.loser, _Url.empty);
      await _onSurface(tester, const Size(390, 844), () async {
        await _pumpCard(
          tester,
          _cardApp(
            locale,
            variant: _Variant.loser,
            verifyUrl: '',
            onVerify: () {},
          ),
        );
        final Finder line = _notKeptText();
        expect(
          line,
          findsOneWidget,
          reason: 'scenario "$scenario": expected the D1 text',
        );
        final Text text = tester.widget<Text>(line);
        expect(
          text.style?.color,
          LudoColors.inkMuted,
          reason:
              'scenario "$scenario": expected the D1 line colour to be '
              'LudoColors.inkMuted; got ${text.style?.color}',
        );
        expect(
          text.style?.fontSize,
          kTypeLabel,
          reason:
              'scenario "$scenario": expected the D1 line size to be '
              'kTypeLabel ($kTypeLabel); got ${text.style?.fontSize}',
        );
        expect(
          text.softWrap,
          isNot(false),
          reason: 'scenario "$scenario": the D1 line must wrap',
        );
        expect(
          text.maxLines,
          isNull,
          reason: 'scenario "$scenario": the D1 line must not cap its lines',
        );
        expect(
          find.descendant(
            of: find.byKey(_notKeptKey),
            matching: find.byType(Icon),
            matchRoot: true,
          ),
          findsNothing,
          reason: 'scenario "$scenario": the D1 line must carry no icon',
        );
      });
    });
  }

  // ===========================================================================
  // (e): text scale 2.0 on 360 x 640, loser card, ar: the line is whole.
  // ===========================================================================
  for (final Locale locale in _locales) {
    testWidgets('(e) ${locale.languageCode} loser verifyUrl \'\' at text scale '
        '2.0 on 360x640: the D1 line is fully visible', (
      WidgetTester tester,
    ) async {
      final String scenario =
          '${locale.languageCode} loser verifyUrl \'\' scale 2.0 360x640';
      await _onSurface(tester, const Size(360, 640), () async {
        await _pumpCard(
          tester,
          _cardApp(
            locale,
            variant: _Variant.loser,
            verifyUrl: '',
            onVerify: () {},
            textScale: 2.0,
          ),
        );
        final Finder line = _notKeptText();
        expect(
          line,
          findsOneWidget,
          reason: 'scenario "$scenario": expected the D1 text on the card',
        );
        await tester.ensureVisible(line);
        await tester.pump();

        final Finder rich = find.descendant(
          of: line,
          matching: find.byType(RichText),
        );
        expect(rich, findsOneWidget);
        final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
          rich,
        );
        expect(
          paragraph.textScaler.scale(10),
          20,
          reason:
              'scenario "$scenario": fixture is broken, the paragraph is not '
              'at text scale 2.0',
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: 'scenario "$scenario": the D1 line is cut by a line cap',
        );
        expect(
          paragraph.text.toPlainText(),
          _notKeptFor(locale),
          reason: 'scenario "$scenario": expected the full D1 wording drawn',
        );

        // Every line of text sits inside the paragraph's own box.
        final List<TextBox> boxes = paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: 0,
            extentOffset: paragraph.text.toPlainText().length,
          ),
        );
        expect(boxes, isNotEmpty);
        double left = double.infinity;
        double right = 0;
        for (final TextBox b in boxes) {
          left = left < b.left ? left : b.left;
          right = right > b.right ? right : b.right;
        }
        final double naturalHeight = paragraph.getMinIntrinsicHeight(
          paragraph.size.width,
        );
        expect(
          paragraph.size.height,
          greaterThanOrEqualTo(naturalHeight - 0.5),
          reason:
              'scenario "$scenario": the D1 line is given '
              '${paragraph.size.height} of height but its text needs '
              '$naturalHeight at this width (clipped)',
        );
        expect(
          left,
          greaterThanOrEqualTo(-0.5),
          reason: 'scenario "$scenario": text starts left of its box ($left)',
        );
        expect(
          right,
          lessThanOrEqualTo(paragraph.size.width + 0.5),
          reason:
              'scenario "$scenario": text runs to x=$right past its box '
              '(${paragraph.size.width} wide)',
        );
        expect(
          boxes.map((TextBox b) => b.top.round()).toSet().length,
          greaterThan(1),
          reason:
              'scenario "$scenario": at scale 2.0 on 360 wide the sentence '
              'must wrap onto several lines, not shrink or clip to one',
        );

        // The box itself is on the screen.
        final Rect rect = MatrixUtils.transformRect(
          paragraph.getTransformTo(null),
          Offset.zero & paragraph.size,
        );
        const Rect screen = Rect.fromLTWH(0, 0, 360, 640);
        expect(
          screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
          isTrue,
          reason:
              'scenario "$scenario": the D1 line is at $rect, outside the '
              '360x640 screen after scrolling it into view',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'scenario "$scenario": a layout or paint error was thrown',
        );
      });
    });
  }

  // ===========================================================================
  // Through the real wire path: the server's empty verify_url, or none.
  // ===========================================================================
  for (final Locale locale in _locales) {
    for (final _Url url in const <_Url>[_Url.empty, _Url.absent]) {
      for (final _Variant variant in _Variant.values) {
        final int? winner = switch (variant) {
          _Variant.winner => 0,
          _Variant.loser => 1,
          _Variant.ended => null,
        };
        final String scenario = 'wire ${_describe(locale, variant, url)}';
        testWidgets('$scenario: GameScreen shows the record-not-kept line', (
          WidgetTester tester,
        ) async {
          await _mountFinishedGameScreen(
            tester,
            locale: locale,
            winner: winner,
            url: url,
          );
          _expectRecordNotKept(tester, scenario: scenario, locale: locale);
          expect(find.byType(EndCard), findsOneWidget);
        });
      }
    }
    testWidgets('wire ${locale.languageCode} loser verifyUrl https: GameScreen '
        'keeps the fairness line and an enabled button', (
      WidgetTester tester,
    ) async {
      final String scenario =
          'wire ${_describe(locale, _Variant.loser, _Url.real)}';
      await _mountFinishedGameScreen(
        tester,
        locale: locale,
        winner: 1,
        url: _Url.real,
      );
      await _expectVerifiable(tester, scenario: scenario);
    });
  }
}
