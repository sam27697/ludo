// Proof for contract C-523 (work/ludo/orders/C-523-home-plain-and-one-sound-
// switch.md), rules D1, D2, D3, D4, D5 and D9: a home screen that says only
// what a player needs. Written from the contract text, against no
// implementation of it. On origin/main 7501227 PlayerCountIcon does not
// exist, so this file does not compile until the implementation lands; that
// is expected, and every case below is red on that base for the reason named
// in its own header comment.
//
// HomeScreen is mounted directly inside a MaterialApp built the way
// app.dart builds one (same delegates, the app's own theme), with a
// controller factory over a FakeTransport (test/net/fake_transport.dart,
// read-only here) so Create can be read back off the wire the way
// home_rule_toggles_test.dart reads it. The link, session-memory and
// create idioms are copied by hand from home_link_scroll_test.dart,
// home_chip_craft_test.dart and home_rule_toggles_test.dart; nothing is
// imported across test files.
//
// "No painted text" is a walk of the element tree for every RichText (Text
// builds one, so Text and Text.rich are both covered), skipping Icon, whose
// RichText carries a private-use glyph, not a string. It runs after the
// home scroll view has been moved to its end, with Offstage subtrees
// included, so a label that moved or hid cannot dodge it.
//
// Ambiguities, reported rather than invented around:
//
//   1. D2 says the word "players" is not painted anywhere on home, and also
//      that the row's label reads "How many players?". Both cannot hold for
//      the English label. These cases read the first as: no painted string
//      contains "players" except the one row label, which must be painted
//      exactly once. Arabic has no such overlap (the label has "لاعب", the
//      banned words are "لاعبين" and "لاعبان").
//   2. D2 names "a check glyph" and "a small expand glyph" without naming
//      the IconData. The check is accepted as any of the Material check
//      icons listed in _checkIcons; the expand glyph is not asserted.
//   3. D2 says the control's semantics label is homePlayersQuestion "plus"
//      the count string, with no joiner. The case accepts any run of
//      whitespace and punctuation between and around them, question first.
//   4. D2 says the control shows the count "as a numeral". In Arabic that
//      may be a Western or an Arabic-Indic digit; both are accepted.
//   5. D2 gives the last-table chip "the table's name and the
//      PlayerCountIcon" and "no seat text". A separator dot between them is
//      tolerated; any other text is not.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart' show isTest;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/player_count_icon.dart';
import 'package:ludo_client/src/room_code.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _playersButtonKey = Key('home-players-button');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _lastTableKey = Key('home-last-table-chip');
Key _optionKey(int n) => Key('home-players-option-$n');

const Size _phone = Size(390, 844);

const String _taglineEn =
    'Every roll can be checked: independent random rolls, open source code.';
const String _taglineAr =
    'كل رمية يمكن التحقق منها: رميات عشوائية مستقلة وكود مفتوح المصدر.';
const String _questionEn = 'How many players?';
const String _questionAr = 'كم لاعب؟';

/// Keys the contract removes from home (and from the other two screens that
/// shared the settings sheet), D1, D2 and D7.
const List<String> _removedKeys = <String>[
  'home-players-disclosure',
  'home-players-selector',
  'home-rule-capture-bonus',
  'home-rule-blocks',
  'home-house-rules',
  'home-settings-button',
  'lobby-settings-button',
  'game-settings-button',
  'feedback-settings-sheet',
  'feedback-settings-haptics',
  'feedback-settings-sound',
];

/// Old values of the strings D9 deletes or D5 rewrites, per locale, taken
/// from the arb files on origin/main 7501227. A painted string that equals
/// one of [_oldExact] or contains one of [_oldContains] is a leftover.
/// "Sound and vibration" is not listed: it is also the new soundToggleLabel.
const Map<String, List<String>> _oldContains = <String, List<String>>{
  'en': <String>[
    'Number of players',
    '4 players, standard rules',
    'Capture bonus',
    'Capturing a token earns another roll',
    'Two tokens on one square are safe from capture',
    '6 characters, letters and numbers',
    'Private rooms',
  ],
  'ar': <String>[
    'عدد اللاعبين',
    '4 لاعبين، القواعد العادية',
    'مكافأة الأكل',
    'أكل قطعة خصم يمنحك رمية أخرى',
    'قطعتان على مربع واحد لا تُؤكلان',
    '6 رموز، حروف وأرقام',
    'غرف خاصة',
  ],
};
const Map<String, List<String>> _oldExact = <String, List<String>>{
  'en': <String>['Vibration', 'Sound'],
  'ar': <String>['الاهتزاز', 'الصوت'],
};

const List<IconData> _checkIcons = <IconData>[
  Icons.check,
  Icons.check_rounded,
  Icons.check_circle,
  Icons.check_circle_rounded,
  Icons.check_circle_outline,
  Icons.check_circle_outline_rounded,
  Icons.done,
  Icons.done_rounded,
];

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

// --- harness ----------------------------------------------------------------

class _LiveControllerFactory {
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    return RoomController(
      serverUrl: Uri.parse('wss://home-plain-test.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
  }
}

class _FakeInitialLinkReader {
  final Completer<Uri?> _completer = Completer<Uri?>();

  Future<Uri?> call() => _completer.future;

  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }
}

class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  Stream<Uri> call() => _controller.stream;

  void add(Uri uri) => _controller.add(uri);
}

class _PushProbe extends NavigatorObserver {
  int pushCount = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
  }
}

Widget _homeApp({
  required Locale locale,
  RoomControllerFactory? controllerFactory,
  InitialLinkReader initialLinkReader = noInitialLink,
  LinkStreamOpener linkStream = noLinkStream,
  NavigatorObserver? observer,
  bool disableAnimations = false,
}) {
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
    navigatorObservers: observer == null
        ? const <NavigatorObserver>[]
        : <NavigatorObserver>[observer],
    builder: (BuildContext context, Widget? child) {
      if (!disableAnimations) {
        return child!;
      }
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      );
    },
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory ?? _LiveControllerFactory().call,
      initialLinkReader: initialLinkReader,
      linkStream: linkStream,
    ),
  );
}

void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  RoomControllerFactory? controllerFactory,
  InitialLinkReader initialLinkReader = noInitialLink,
  LinkStreamOpener linkStream = noLinkStream,
  NavigatorObserver? observer,
  bool disableAnimations = false,
}) async {
  _usePhone(tester);
  await tester.pumpWidget(
    _homeApp(
      locale: locale,
      controllerFactory: controllerFactory,
      initialLinkReader: initialLinkReader,
      linkStream: linkStream,
      observer: observer,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

AppLocalizations _loc(WidgetTester tester) {
  return AppLocalizations.of(tester.element(find.byType(Scaffold).first));
}

/// What a failing case prints so it can be rerun: the cases are fully
/// deterministic (no random input, no wall clock), so the scenario name,
/// locale and surface are the whole seed.
String _repro(String scenario, Locale locale) {
  return 'Reproduce: scenario "$scenario", locale ${locale.languageCode}, '
      'surface ${_phone.width.toInt()}x${_phone.height.toInt()} at 1.0, '
      'flutter test test/home_plain_test.dart --plain-name "$scenario". '
      'No random input is involved.';
}

// --- painted text -----------------------------------------------------------

/// Every string any RichText on screen paints, Offstage subtrees included.
List<String> _paintedStrings() {
  final List<String> out = <String>[];
  void visit(Element element) {
    final Widget widget = element.widget;
    if (widget is Icon) {
      return;
    }
    if (widget is RichText) {
      out.add(widget.text.toPlainText(includeSemanticsLabels: false));
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return out;
}

/// Painted strings below [root] only.
List<String> _paintedStringsUnder(Element root) {
  final List<String> out = <String>[];
  void visit(Element element) {
    final Widget widget = element.widget;
    if (widget is Icon) {
      return;
    }
    if (widget is RichText) {
      out.add(widget.text.toPlainText(includeSemanticsLabels: false));
    }
    element.visitChildren(visit);
  }

  visit(root);
  return out;
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  final ScrollPosition position = Scrollable.of(
    tester.element(find.byKey(_codeKey)),
  ).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
}

/// The painted strings that hold the banned "players" word for [locale].
List<String> _playersHits(List<String> painted, Locale locale) {
  final List<String> needles = locale.languageCode == 'ar'
      ? const <String>['لاعبين', 'لاعبان']
      : const <String>['players'];
  return painted
      .where(
        (String s) => needles.any((String n) => s.toLowerCase().contains(n)),
      )
      .toList();
}

/// Fails with every leftover from the deleted strings, D9.
void _expectNoOldStrings(List<String> painted, Locale locale, String repro) {
  final List<String> leftovers = <String>[];
  for (final String s in painted) {
    for (final String old in _oldContains[locale.languageCode]!) {
      if (s.contains(old)) {
        leftovers.add('"$s" contains deleted string "$old"');
      }
    }
    for (final String old in _oldExact[locale.languageCode]!) {
      if (s.trim() == old) {
        leftovers.add('"$s" equals deleted string "$old"');
      }
    }
  }
  expect(
    leftovers,
    isEmpty,
    reason:
        'expected no painted text carrying the old value of a string D9 '
        'deletes (or the old tagline opening); found $leftovers. $repro',
  );
}

// --- the players control ----------------------------------------------------

Set<String> _numeralForms(int n) {
  const List<String> arabicIndic = <String>[
    '٠',
    '١',
    '٢',
    '٣',
    '٤',
    '٥',
    '٦',
    '٧',
    '٨',
    '٩',
  ];
  return <String>{
    '$n',
    n.toString().split('').map((c) => arabicIndic[int.parse(c)]).join(),
  };
}

String _stripSpace(String s) => s.replaceAll(RegExp('[\\s ‎‏]'), '');

/// The count the control currently shows, read off its PlayerCountIcon, and
/// checked against the numeral it paints.
int _shownCount(WidgetTester tester, String repro) {
  final Finder button = find.byKey(_playersButtonKey);
  expect(
    button,
    findsOneWidget,
    reason: 'expected one home-players-button on home; found none. $repro',
  );
  final Finder icon = find.descendant(
    of: button,
    matching: find.byType(PlayerCountIcon),
  );
  expect(
    icon,
    findsOneWidget,
    reason:
        'expected exactly one PlayerCountIcon inside home-players-button; '
        'found ${icon.evaluate().length}. $repro',
  );
  final int count = tester.widget<PlayerCountIcon>(icon).count;
  final List<String> painted = _paintedStringsUnder(tester.element(button))
      .map(_stripSpace)
      .where((String s) => s.isNotEmpty)
      .toList();
  expect(
    painted.any(_numeralForms(count).contains),
    isTrue,
    reason:
        'expected home-players-button to paint the numeral for its icon '
        'count $count (one of ${_numeralForms(count)}); it paints $painted. '
        '$repro',
  );
  return count;
}

Future<void> _openMenu(WidgetTester tester, String repro) async {
  await tester.ensureVisible(find.byKey(_playersButtonKey));
  await tester.tap(find.byKey(_playersButtonKey));
  await tester.pumpAndSettle();
  for (final int n in <int>[2, 3, 4]) {
    expect(
      find.byKey(_optionKey(n), skipOffstage: false),
      findsOneWidget,
      reason:
          'expected home-players-option-$n after tapping home-players-button; '
          'the menu did not show it. $repro',
    );
  }
}

Future<void> _pick(WidgetTester tester, int n, String repro) async {
  await tester.tap(find.byKey(_optionKey(n)));
  await tester.pumpAndSettle();
  for (final int m in <int>[2, 3, 4]) {
    expect(
      find.byKey(_optionKey(m), skipOffstage: false),
      findsNothing,
      reason:
          'expected the menu to close after picking option $n; '
          'home-players-option-$m is still in the tree. $repro',
    );
  }
}

bool _isCheckIcon(Widget w) =>
    w is Icon && w.icon != null && _checkIcons.contains(w.icon);

Finder _checksIn(Finder option) =>
    find.descendant(of: option, matching: find.byWidgetPredicate(_isCheckIcon));

// --- pixels -----------------------------------------------------------------

Future<ByteData> _rgba(WidgetTester tester) async {
  RenderObject root = tester.renderObject(find.byType(Scaffold).first);
  while (root.parent != null) {
    root = root.parent!;
  }
  final OffsetLayer layer = root.debugLayer! as OffsetLayer;
  final Size size = tester.view.physicalSize;
  final ui.Image image = (await tester.runAsync(
    () => layer.toImage(Offset.zero & size, pixelRatio: 1.0),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return data!;
}

Color _pixel(ByteData data, int width, Offset p) {
  final int i = (p.dy.round() * width + p.dx.round()) * 4;
  return Color.fromARGB(
    data.getUint8(i + 3),
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

// --- create frame -----------------------------------------------------------

Future<void> _tapCreate(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_createKey));
  await tester.tap(find.byKey(_createKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The one create_room frame the single transport saw, `d` decoded.
Map<String, Object?> _createData(_LiveControllerFactory factory, String repro) {
  expect(
    factory.transports,
    hasLength(1),
    reason: 'expected Create to open exactly one transport. $repro',
  );
  final List<Map<String, Object?>> sent = factory.transports.single.sentRaw
      .map((String raw) => jsonDecode(raw) as Map<String, Object?>)
      .toList();
  expect(sent.map((Map<String, Object?> f) => f['t']).toList(), <Object?>[
    'create_room',
  ], reason: 'expected exactly one create_room frame on the wire. $repro');
  return sent.single['d']! as Map<String, Object?>;
}

Future<void> _drainRequestTimeout(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
}

String _codeText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_codeKey)).controller!.text;

Finder _join() => find.byKey(_joinKey, skipOffstage: false);

/// [testWidgets] with a semantics handle held for the whole body and
/// released in a finally inside it: the framework checks for live handles
/// before any addTearDown callback runs, so a tear-down dispose would fail
/// every case that uses it.
@isTest
void _semTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final Locale locale in _locales) {
    final String lc = locale.languageCode;

    group('home, $lc', () {
      // Red on 7501227: home_screen.dart:1520 mounts home-players-disclosure,
      // :1567 home-players-selector, :1576 home-rule-capture-bonus, :1590
      // home-house-rules, :1243 home-settings-button; :1690 sets the
      // helperText; the selector paints "2 players / 3 players / 4 players".
      testWidgets('nothing the contract removes is on screen: no removed key, '
          'no rule control, no "players" but the one question, no deleted '
          'string', (tester) async {
        const String name = 'removed things absent';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        final AppLocalizations loc = _loc(tester);

        for (final String key in _removedKeys) {
          expect(
            find.byKey(Key(key), skipOffstage: false),
            findsNothing,
            reason: 'expected no widget keyed $key on home; found one. $repro',
          );
        }
        expect(
          find.byType(SegmentedButton<int>, skipOffstage: false),
          findsNothing,
          reason:
              'expected no SegmentedButton on home (the old selector); '
              'found one. $repro',
        );
        expect(
          find.byType(Switch, skipOffstage: false),
          findsNothing,
          reason:
              'expected no Switch on home (D1: no rule control); found one. '
              '$repro',
        );
        expect(
          find.byIcon(Icons.tune_rounded, skipOffstage: false),
          findsNothing,
          reason:
              'expected no tune_rounded settings glyph on home (D7); found '
              'one. $repro',
        );

        await _scrollToEnd(tester);
        final List<String> painted = _paintedStrings();
        final String question = loc.homePlayersQuestion;
        expect(
          question,
          lc == 'ar' ? _questionAr : _questionEn,
          reason: 'D9: homePlayersQuestion has the wrong wording. $repro',
        );
        expect(
          painted.where((String s) => s.trim() == question).length,
          1,
          reason:
              'expected the label "$question" painted exactly once; painted '
              'strings were $painted. $repro',
        );
        final List<String> hits = _playersHits(
          painted,
          locale,
        ).where((String s) => s.trim() != question).toList();
        expect(
          hits,
          isEmpty,
          reason:
              'expected no painted text with the word for "players" other '
              'than the row label; found $hits. $repro',
        );
        _expectNoOldStrings(painted, locale, repro);
      });

      // Red on 7501227: the selector sits behind home-players-disclosure
      // (home_screen.dart:1520), which paints homePlayersDisclosureClosed
      // ("4 players, standard rules"); there is no home-players-button.
      _semTest('one always-visible row: label at the start, a 48 dp '
          'control at the end showing 4 with its icon, semantics label '
          'question plus count', (tester) async {
        const String name = 'row and default control';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        final AppLocalizations loc = _loc(tester);

        final Finder button = find.byKey(_playersButtonKey);
        expect(
          button,
          findsOneWidget,
          reason:
              'expected home-players-button on home with no disclosure to '
              'open first; found none. $repro',
        );
        final Size size = tester.getSize(button);
        expect(
          size.width >= 48 && size.height >= 48,
          isTrue,
          reason:
              'expected home-players-button at least 48 x 48 dp; got '
              '${size.width} x ${size.height}. $repro',
        );
        expect(
          _shownCount(tester, repro),
          4,
          reason: 'expected the control to read 4 by default. $repro',
        );

        final Finder label = find.text(loc.homePlayersQuestion);
        expect(
          label,
          findsOneWidget,
          reason:
              'expected the label "${loc.homePlayersQuestion}" on the row. '
              '$repro',
        );
        final Rect labelRect = tester.getRect(label);
        final Rect buttonRect = tester.getRect(button);
        expect(
          labelRect.top < buttonRect.bottom &&
              buttonRect.top < labelRect.bottom,
          isTrue,
          reason:
              'expected label and control on one row (vertical overlap); '
              'label $labelRect, control $buttonRect. $repro',
        );
        final bool labelFirst = lc == 'ar'
            ? labelRect.center.dx > buttonRect.center.dx
            : labelRect.center.dx < buttonRect.center.dx;
        expect(
          labelFirst,
          isTrue,
          reason:
              'expected the label at the row start and the control at the '
              'row end (${lc == 'ar' ? 'right to left' : 'left to right'}); '
              'label $labelRect, control $buttonRect. $repro',
        );

        final String semantics = tester.getSemantics(button).label;
        final String remainder = semantics
            .replaceFirst(loc.homePlayersQuestion, '')
            .replaceFirst(loc.homePlayersFour, '');
        expect(
          semantics.contains(loc.homePlayersQuestion) &&
              semantics.contains(loc.homePlayersFour) &&
              semantics.indexOf(loc.homePlayersQuestion) <
                  semantics.indexOf(loc.homePlayersFour) &&
              RegExp(r'^[\s,.:;،؛\-0-9٠-٩]*$').hasMatch(remainder),
          isTrue,
          reason:
              'expected the control semantics label to be '
              '"${loc.homePlayersQuestion}" then "${loc.homePlayersFour}" '
              'and nothing else; got "$semantics". $repro',
        );
      });

      // Red on 7501227: no home-players-option-N exists; the choice is three
      // SegmentedButton segments (home_screen.dart:1567) painting "N players".
      _semTest('menu: three keyed options, numeral plus icon each, '
          'semantics label is its own count string, only the current one '
          'carries a check glyph', (tester) async {
        const String name = 'menu options';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        final AppLocalizations loc = _loc(tester);
        await _openMenu(tester, repro);

        final Map<int, String> labels = <int, String>{
          2: loc.homePlayersTwo,
          3: loc.homePlayersThree,
          4: loc.homePlayersFour,
        };
        for (final int n in <int>[2, 3, 4]) {
          final Finder option = find.byKey(_optionKey(n));
          final Finder icon = find.descendant(
            of: option,
            matching: find.byType(PlayerCountIcon),
          );
          expect(
            icon,
            findsOneWidget,
            reason:
                'expected one PlayerCountIcon inside home-players-option-$n; '
                'found ${icon.evaluate().length}. $repro',
          );
          expect(
            tester.widget<PlayerCountIcon>(icon).count,
            n,
            reason: 'expected the icon in option $n to show $n figures. $repro',
          );
          final List<String> painted = _paintedStringsUnder(
            tester.element(option),
          ).map(_stripSpace).where((String s) => s.isNotEmpty).toList();
          expect(
            painted.any(_numeralForms(n).contains),
            isTrue,
            reason:
                'expected option $n to paint its numeral (one of '
                '${_numeralForms(n)}); it paints $painted. $repro',
          );
          expect(
            painted.every((String s) => _numeralForms(n).contains(s)),
            isTrue,
            reason:
                'expected option $n to paint only its numeral, no words; it '
                'paints $painted. $repro',
          );
          final Size size = tester.getSize(option);
          expect(
            size.height >= 48,
            isTrue,
            reason:
                'expected option $n at least 48 dp tall; got ${size.height}. '
                '$repro',
          );
          expect(
            tester.getSemantics(option).label.split('\n').map((l) => l.trim()),
            contains(labels[n]),
            reason:
                'expected the semantics label of option $n to carry its '
                'homePlayers string "${labels[n]}" as a line of its own; got '
                '"${tester.getSemantics(option).label}". $repro',
          );
          expect(
            _checksIn(option),
            n == 4 ? findsOneWidget : findsNothing,
            reason:
                'expected a check glyph in option $n only if it is the '
                'current count (4); ${n == 4 ? 'none' : 'one'} was found. '
                '$repro',
          );
        }

        final List<String> painted = _paintedStrings();
        final List<String> hits = _playersHits(
          painted,
          locale,
        ).where((String s) => s.trim() != loc.homePlayersQuestion).toList();
        expect(
          hits,
          isEmpty,
          reason:
              'expected no painted "players" word with the menu open; found '
              '$hits. $repro',
        );
      });

      // Red on 7501227: the selection mark is SegmentedButton's own
      // (home_screen.dart:2189, _PlayersSelector); there is no menu and no
      // filled option.
      testWidgets('menu: the current option has a filled background the '
          'others lack, and it follows the pick', (tester) async {
        const String name = 'menu selected fill';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);

        Future<Map<int, Color>> sample() async {
          final ByteData data = await _rgba(tester);
          final int width = tester.view.physicalSize.width.toInt();
          final Map<int, Color> out = <int, Color>{};
          for (final int n in <int>[2, 3, 4]) {
            final Rect r = tester.getRect(find.byKey(_optionKey(n)));
            // Three dp in from the start edge, mid height: inside the item's
            // padding, clear of the numeral and the icon.
            final double x = lc == 'ar' ? r.right - 3 : r.left + 3;
            out[n] = _pixel(data, width, Offset(x, r.center.dy));
          }
          return out;
        }

        void expectOnlyFilled(Map<int, Color> colors, int current) {
          for (final int n in <int>[2, 3, 4]) {
            if (n == current) {
              continue;
            }
            expect(
              colors[current],
              isNot(colors[n]),
              reason:
                  'expected option $current (the current count) to have a '
                  'filled background unlike option $n; both sampled '
                  '${colors[current]}. $repro',
            );
          }
        }

        await _openMenu(tester, repro);
        expectOnlyFilled(await sample(), 4);
        await _pick(tester, 2, repro);
        await _openMenu(tester, repro);
        expectOnlyFilled(await sample(), 2);
        expect(
          _checksIn(find.byKey(_optionKey(2))),
          findsOneWidget,
          reason:
              'expected the check glyph to move to option 2 after picking '
              '2. $repro',
        );
        expect(
          _checksIn(find.byKey(_optionKey(4))),
          findsNothing,
          reason:
              'expected option 4 to lose its check glyph after picking 2. '
              '$repro',
        );
      });

      for (final int n in <int>[2, 3, 4]) {
        // Red on 7501227: home_screen.dart:1567 offers the choice only
        // through the disclosure and the selector; no home-players-button
        // to tap.
        testWidgets('pick $n: the control shows $n, Create sends players $n '
            'and rules {capture_bonus: true}', (tester) async {
          final String name = 'pick $n then create';
          final String repro = _repro(name, locale);
          final _LiveControllerFactory factory = _LiveControllerFactory();
          await _mount(tester, locale: locale, controllerFactory: factory.call);
          final AppLocalizations loc = _loc(tester);

          await _openMenu(tester, repro);
          await _pick(tester, n, repro);
          expect(
            _shownCount(tester, repro),
            n,
            reason: 'expected the control to show $n after picking $n. $repro',
          );
          final String semantics = tester
              .getSemantics(find.byKey(_playersButtonKey))
              .label;
          final String expected = switch (n) {
            2 => loc.homePlayersTwo,
            3 => loc.homePlayersThree,
            _ => loc.homePlayersFour,
          };
          expect(
            semantics.contains(expected),
            isTrue,
            reason:
                'expected the control semantics label to carry "$expected" '
                'after picking $n; got "$semantics". $repro',
          );

          await _tapCreate(tester);
          final Map<String, Object?> data = _createData(factory, repro);
          expect(
            data['players'],
            n,
            reason:
                'expected create_room players $n; the frame carried '
                '${data['players']}. $repro',
          );
          expect(
            data['rules'],
            <String, Object?>{'capture_bonus': true},
            reason:
                'expected create_room rules exactly {capture_bonus: true} '
                '(D1: fixed rules); the frame carried ${data['rules']}. '
                '$repro',
          );
          await _drainRequestTimeout(tester);
        });
      }

      // Red on 7501227: no menu exists to dismiss; home_screen.dart:1567.
      testWidgets('open and dismiss changes nothing; pick, then open and '
          'dismiss, keeps the pick', (tester) async {
        const String name = 'dismiss keeps value';
        final String repro = _repro(name, locale);
        final _LiveControllerFactory factory = _LiveControllerFactory();
        await _mount(tester, locale: locale, controllerFactory: factory.call);

        Future<void> dismissByTappingOutside() async {
          // The tagline is plain text on the hero; fixture-check that the
          // menu does not cover it, then tap it.
          final Finder tagline = find.text(
            lc == 'ar' ? _taglineAr : _taglineEn,
          );
          expect(
            tagline,
            findsOneWidget,
            reason: 'fixture: the tagline must be on screen to tap. $repro',
          );
          final Offset outside = tester.getCenter(tagline);
          Rect? menu;
          for (final int n in <int>[2, 3, 4]) {
            final Rect r = tester.getRect(find.byKey(_optionKey(n)));
            menu = menu == null ? r : menu.expandToInclude(r);
          }
          expect(
            menu!.inflate(8).contains(outside),
            isFalse,
            reason:
                'fixture: the tagline centre $outside lies inside the menu '
                '$menu, so tapping it would not be an outside tap. $repro',
          );
          await tester.tapAt(outside);
          await tester.pumpAndSettle();
          for (final int n in <int>[2, 3, 4]) {
            expect(
              find.byKey(_optionKey(n), skipOffstage: false),
              findsNothing,
              reason:
                  'expected an outside tap to close the menu; '
                  'home-players-option-$n is still in the tree. $repro',
            );
          }
        }

        await _openMenu(tester, repro);
        await dismissByTappingOutside();
        expect(
          _shownCount(tester, repro),
          4,
          reason: 'expected 4 after opening and dismissing. $repro',
        );

        await _openMenu(tester, repro);
        await _pick(tester, 3, repro);
        await _openMenu(tester, repro);
        await dismissByTappingOutside();
        expect(
          _shownCount(tester, repro),
          3,
          reason:
              'expected 3 to survive an open and dismiss after picking 3. '
              '$repro',
        );

        await _openMenu(tester, repro);
        await _pick(tester, 3, repro);
        expect(
          _shownCount(tester, repro),
          3,
          reason: 'expected re-picking the current option to keep 3. $repro',
        );

        await _tapCreate(tester);
        expect(
          _createData(factory, repro)['players'],
          3,
          reason:
              'expected Create to send players 3 after the sequence. $repro',
        );
        await _drainRequestTimeout(tester);
      });

      // Red on 7501227: _LastTableChip paints "$name · $seatsLabel"
      // (home_screen.dart:2007-2021), so the chip has seat text and no
      // PlayerCountIcon; there is no control to show the loaded count.
      for (final int seats in <int>[2, 3]) {
        _semTest('last table of $seats seats: chip paints the name and a '
            '$seats-figure icon, semantics label unchanged, the control '
            'shows $seats', (tester) async {
          final String name = 'last table $seats seats';
          final String repro = _repro(name, locale);
          await SessionMemory.recordSuccessfulCreate(
            name: 'Zed Quartz',
            seats: seats,
          );
          final _LiveControllerFactory factory = _LiveControllerFactory();
          await _mount(tester, locale: locale, controllerFactory: factory.call);
          final AppLocalizations loc = _loc(tester);

          final Finder chip = find.byKey(_lastTableKey);
          expect(
            chip,
            findsOneWidget,
            reason:
                'expected home-last-table-chip with a remembered table. '
                '$repro',
          );
          final Finder icon = find.descendant(
            of: chip,
            matching: find.byType(PlayerCountIcon),
          );
          expect(
            icon,
            findsOneWidget,
            reason:
                'expected one PlayerCountIcon in the last-table chip; found '
                '${icon.evaluate().length}. $repro',
          );
          expect(
            tester.widget<PlayerCountIcon>(icon).count,
            seats,
            reason: 'expected the chip icon to show $seats figures. $repro',
          );
          final String painted = _stripSpace(
            _paintedStringsUnder(tester.element(chip))
                .join()
                .replaceAll('·', ''),
          );
          expect(
            painted,
            _stripSpace('Zed Quartz'),
            reason:
                'expected the chip to paint the table name and nothing else '
                '(no seat text); it paints "$painted". $repro',
          );
          final String seatsLabel = seats == 2
              ? loc.homePlayersTwo
              : loc.homePlayersThree;
          expect(
            tester.getSemantics(chip).label.split('\n').first,
            'Zed Quartz · $seatsLabel',
            reason:
                'expected the chip semantics label unchanged '
                '("name · homePlayersN"). $repro',
          );
          expect(
            _shownCount(tester, repro),
            seats,
            reason:
                'expected loading the last table to set the control to '
                '$seats. $repro',
          );

          await _tapCreate(tester);
          expect(
            _createData(factory, repro)['players'],
            seats,
            reason:
                'expected Create to send the loaded count $seats without '
                'touching the menu. $repro',
          );
          await _drainRequestTimeout(tester);
        });
      }

      // Red on 7501227: home_screen.dart:1337 and :1359 paint homeTagline,
      // "Private rooms. Every roll can be checked.".
      testWidgets('the tagline is exactly the D5 sentence and nothing of '
          'the old one', (tester) async {
        const String name = 'tagline';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        final AppLocalizations loc = _loc(tester);
        final String expected = lc == 'ar' ? _taglineAr : _taglineEn;

        expect(
          loc.homeTagline,
          expected,
          reason: 'D9/D5: homeTagline has the wrong wording. $repro',
        );
        await _scrollToEnd(tester);
        final List<String> painted = _paintedStrings();
        expect(
          painted.where((String s) => s.trim() == expected),
          isNotEmpty,
          reason:
              'expected the tagline "$expected" painted as one string; '
              'painted strings were $painted. $repro',
        );
        final String all = painted.join(' ').toLowerCase();
        for (final String banned in <String>[
          'private rooms',
          'absolute randomness',
          'provably fair',
          'غرف خاصة',
        ]) {
          expect(
            all.contains(banned),
            isFalse,
            reason:
                'expected no "$banned" on home (D5 and doctrine P7 '
                'wording rule). $repro',
          );
        }
      });
    });

    group('join, $lc', () {
      // Red on 7501227: home_screen.dart:1754 builds join-room-button
      // unconditionally, so it is in the tree for an empty field.
      testWidgets('Join is absent (not hidden) for empty, 5, whitespace-only '
          'and 7 characters, present at exactly 6, absent after a '
          'deletion', (tester) async {
        const String name = 'join appears at six';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        final Finder field = find.byKey(_codeKey);

        void expectAbsent(String when) {
          expect(
            _join(),
            findsNothing,
            reason:
                'expected join-room-button absent from the tree (not '
                'disabled, not invisible, Offstage included) $when; it is '
                'there. $repro',
          );
        }

        expectAbsent('with an empty field');

        await tester.enterText(field, 'ABC23');
        await tester.pumpAndSettle();
        expectAbsent('with 5 characters');

        await tester.enterText(field, '   ');
        await tester.pumpAndSettle();
        expectAbsent('with only whitespace');

        await tester.enterText(field, 'AB C23');
        await tester.pumpAndSettle();
        expectAbsent(
          'with "AB C23" (5 characters once normalizeRoomCode strips the '
          'space)',
        );

        await tester.enterText(field, 'ABC234');
        await tester.pump();
        expect(
          _join(),
          findsOneWidget,
          reason:
              'expected join-room-button in the tree at once with 6 '
              'characters. $repro',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason: 'expected a visible join-room-button at 6 characters. $repro',
        );

        await tester.enterText(field, 'ABC2345');
        await tester.pumpAndSettle();
        expectAbsent('with 7 characters');

        await tester.enterText(field, 'abc-2 34');
        await tester.pumpAndSettle();
        expect(
          _codeText(tester),
          'ABC234',
          reason:
              'fixture: the field must show the normalised form "ABC234" '
              'for "abc-2 34". $repro',
        );
        expect(
          _join(),
          findsOneWidget,
          reason:
              'expected Join once the text normalises to 6 characters '
              '("abc-2 34"). $repro',
        );

        await tester.enterText(field, 'ABC23');
        await tester.pumpAndSettle();
        expectAbsent('after deleting back to 5 characters');
        await tester.enterText(field, '');
        await tester.pumpAndSettle();
        expectAbsent('after clearing the field');
      });

      // Red on 7501227: same unconditional join-room-button at
      // home_screen.dart:1754; the recent chip fills the field through
      // _fillCodeFromRecent (:1120) without anything toggling Join.
      testWidgets('a recent-code chip tap brings Join', (tester) async {
        const String name = 'recent chip brings join';
        final String repro = _repro(name, locale);
        await SessionMemory.recordSuccessfulJoin('AB23CD');
        await _mount(tester, locale: locale);
        expect(
          _join(),
          findsNothing,
          reason: 'expected no Join before the chip is tapped. $repro',
        );
        final Finder chip = find.byKey(const Key('home-recent-code-AB23CD'));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(
          _codeText(tester),
          'AB23CD',
          reason: 'fixture: the chip tap must fill the field. $repro',
        );
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason:
              'expected join-room-button after a recent-code chip filled '
              'the field with a full code. $repro',
        );
      });

      // Red on 7501227: same unconditional button (home_screen.dart:1754).
      testWidgets('a paste of a full code brings Join, normalised', (
        tester,
      ) async {
        const String name = 'paste brings join';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': 'k7m 2qp'};
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byKey(_codeKey));
        await tester.pump();
        final EditableTextState editable = tester.state<EditableTextState>(
          find.descendant(
            of: find.byKey(_codeKey),
            matching: find.byType(EditableText),
          ),
        );
        await editable.pasteText(SelectionChangedCause.keyboard);
        await tester.pumpAndSettle();
        expect(
          _codeText(tester),
          'K7M2QP',
          reason: 'fixture: the paste must land normalised. $repro',
        );
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason:
              'expected join-room-button after a paste of 6 characters. '
              '$repro',
        );
      });

      // Red on 7501227: same unconditional button (home_screen.dart:1754).
      testWidgets('a cold-start room link and a warm-start room link each '
          'bring Join', (tester) async {
        const String name = 'link brings join';
        final String repro = _repro(name, locale);
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        await _mount(
          tester,
          locale: locale,
          initialLinkReader: reader.call,
          linkStream: opener.call,
        );
        expect(
          _join(),
          findsNothing,
          reason: 'expected no Join before any link arrives. $repro',
        );

        reader.complete(Uri.parse('https://$kAppLinkHost/r/K7M2QP'));
        await tester.pumpAndSettle();
        expect(
          _codeText(tester),
          'K7M2QP',
          reason: 'fixture: the cold link must fill the field. $repro',
        );
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason: 'expected Join after a cold-start room link. $repro',
        );

        await tester.enterText(find.byKey(_codeKey), '');
        await tester.pumpAndSettle();
        expect(
          _join(),
          findsNothing,
          reason: 'expected Join gone once the linked code is cleared. $repro',
        );

        opener.add(Uri.parse('https://$kAppLinkHost/r/H4XR9T'));
        await tester.pumpAndSettle();
        expect(
          _codeText(tester),
          'H4XR9T',
          reason: 'fixture: the warm link must fill the field. $repro',
        );
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason: 'expected Join after a warm-start room link. $repro',
        );
      });

      // Red on 7501227: the Join button is unconditional, so a tap path
      // exists, but the gate the contract adds (D3) has no analogue;
      // the invalid-code branch itself is _joinRoom, home_screen.dart:983-988.
      testWidgets('a full-length code that fails isValidRoomCode still shows '
          'Join, and a tap shows homeRoomCodeInvalid without navigating', (
        tester,
      ) async {
        const String name = 'invalid full code';
        final String repro = _repro(name, locale);
        final _PushProbe observer = _PushProbe();
        await _mount(tester, locale: locale, observer: observer);
        final AppLocalizations loc = _loc(tester);
        const String invalid = 'AB0234';
        expect(
          isValidRoomCode(invalid),
          isFalse,
          reason: 'fixture: "$invalid" must be an invalid code. $repro',
        );
        expect(normalizeRoomCode(invalid).length, roomCodeLength);

        await tester.enterText(find.byKey(_codeKey), invalid);
        await tester.pumpAndSettle();
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason:
              'expected Join for a full-length code even though it is '
              'invalid. $repro',
        );
        final int pushesBefore = observer.pushCount;
        await tester.ensureVisible(find.byKey(_joinKey));
        await tester.tap(find.byKey(_joinKey));
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byKey(_codeKey)).decoration?.errorText,
          loc.homeRoomCodeInvalid,
          reason:
              'expected homeRoomCodeInvalid under the field after tapping '
              'Join with "$invalid". $repro',
        );
        expect(
          observer.pushCount,
          pushesBefore,
          reason: 'expected an invalid code to push no route. $repro',
        );

        await tester.enterText(find.byKey(_codeKey), 'AB023');
        await tester.pumpAndSettle();
        expect(
          _join(),
          findsNothing,
          reason: 'expected Join gone after deleting to 5 characters. $repro',
        );
      });

      // Red on 7501227: home_screen.dart:1690 sets
      // helperText: loc.homeRoomCodeFieldHint.
      testWidgets('no helper text under the field; the label "Room code" '
          'stays', (tester) async {
        const String name = 'no helper text';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        final AppLocalizations loc = _loc(tester);

        final InputDecoration decoration = tester
            .widget<TextField>(find.byKey(_codeKey))
            .decoration!;
        expect(
          decoration.helperText,
          isNull,
          reason:
              'expected no helperText on the room code field; it reads '
              '"${decoration.helperText}". $repro',
        );
        expect(
          decoration.helper,
          isNull,
          reason: 'expected no helper widget on the room code field. $repro',
        );
        final List<String> painted = _paintedStrings();
        expect(
          painted.any((String s) => s.contains(loc.homeRoomCodeFieldLabel)),
          isTrue,
          reason:
              'expected the label "${loc.homeRoomCodeFieldLabel}" painted '
              'on the empty field; painted strings were $painted. $repro',
        );
        _expectNoOldStrings(painted, locale, repro);
      });

      // Red on 7501227: nothing animates Join in; the button is always
      // there (home_screen.dart:1754).
      testWidgets('Join settles within 200 ms of the sixth character; with '
          'animations disabled it is final on the first frame', (tester) async {
        const String name = 'join entry timing';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);
        await tester.enterText(find.byKey(_codeKey), 'ABC234');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        final Rect after200 = tester.getRect(find.byKey(_joinKey));
        await tester.pumpAndSettle();
        final Rect settled = tester.getRect(find.byKey(_joinKey));
        expect(
          after200,
          settled,
          reason:
              'expected join-room-button at its final rect 200 ms after the '
              'sixth character; it was $after200 then and $settled once '
              'settled. $repro',
        );
      });

      testWidgets('with animations disabled Join is at its final rect on '
          'the first frame', (tester) async {
        const String name = 'join entry timing, animations off';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale, disableAnimations: true);
        await tester.enterText(find.byKey(_codeKey), 'ABC234');
        await tester.pump();
        final Rect first = tester.getRect(find.byKey(_joinKey));
        await tester.pumpAndSettle();
        final Rect settled = tester.getRect(find.byKey(_joinKey));
        expect(
          first,
          settled,
          reason:
              'expected Join at its final rect on the first frame under '
              'disableAnimations (Duration.zero); it was $first, then '
              '$settled. $repro',
        );
      });
    });
  }

  // D4: the icon on its own. Locale-free.
  group('PlayerCountIcon', () {
    Future<void> pumpIcon(
      WidgetTester tester,
      Widget icon, {
      TextDirection direction = TextDirection.ltr,
    }) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: direction,
          child: Center(child: icon),
        ),
      );
    }

    Color? effectiveColor(WidgetTester tester, Finder finder) {
      final Icon icon = tester.widget<Icon>(finder);
      return icon.color ?? IconTheme.of(tester.element(finder)).color;
    }

    for (final int n in <int>[1, 2, 3, 4]) {
      // Red on 7501227: lib/src/player_count_icon.dart does not exist.
      testWidgets('count $n draws $n person figures side by side, 18 dp, '
          'LudoColors.ink by default', (tester) async {
        final String repro =
            'Reproduce: scenario "icon count $n", flutter test '
            'test/home_plain_test.dart --plain-name "count $n draws". No '
            'random input is involved.';
        await pumpIcon(tester, PlayerCountIcon(count: n));
        final Finder figures = find.descendant(
          of: find.byType(PlayerCountIcon),
          matching: find.byIcon(Icons.person_rounded),
        );
        expect(
          figures,
          findsNWidgets(n),
          reason:
              'expected $n Icons.person_rounded in PlayerCountIcon(count: '
              '$n); found ${figures.evaluate().length}. $repro',
        );
        final List<Rect> rects = <Rect>[
          for (int i = 0; i < n; i++) tester.getRect(figures.at(i)),
        ];
        for (final Rect r in rects) {
          expect(
            r.size,
            const Size(18, 18),
            reason:
                'expected each figure 18 x 18 by default; got ${r.size}. '
                '$repro',
          );
          expect(
            r.top,
            rects.first.top,
            reason: 'expected the figures on one row; got $rects. $repro',
          );
        }
        for (int i = 1; i < n; i++) {
          expect(
            rects[i].left >= rects[i - 1].right - 0.01,
            isTrue,
            reason:
                'expected figure $i to the right of figure ${i - 1} without '
                'overlap in ltr; got $rects. $repro',
          );
        }
        expect(
          effectiveColor(tester, figures.first),
          LudoColors.ink,
          reason: 'expected the default colour LudoColors.ink. $repro',
        );
      });
    }

    testWidgets('size and colour come from the caller', (tester) async {
      const String repro =
          'Reproduce: scenario "icon size and colour", flutter test '
          'test/home_plain_test.dart --plain-name "size and colour come". No '
          'random input is involved.';
      await pumpIcon(
        tester,
        const PlayerCountIcon(count: 3, size: 30, color: Color(0xFF123456)),
      );
      final Finder figures = find.descendant(
        of: find.byType(PlayerCountIcon),
        matching: find.byIcon(Icons.person_rounded),
      );
      expect(figures, findsNWidgets(3), reason: repro);
      for (int i = 0; i < 3; i++) {
        expect(
          tester.getSize(figures.at(i)),
          const Size(30, 30),
          reason: 'expected figure $i at size 30. $repro',
        );
        expect(
          effectiveColor(tester, figures.at(i)),
          const Color(0xFF123456),
          reason: 'expected figure $i in the caller colour. $repro',
        );
      }
    });

    testWidgets('rtl mirrors the layout: the first figure sits at the '
        'right-hand end', (tester) async {
      const String repro =
          'Reproduce: scenario "icon rtl", flutter test '
          'test/home_plain_test.dart --plain-name "rtl mirrors". No random '
          'input is involved.';
      await pumpIcon(
        tester,
        const PlayerCountIcon(count: 3),
        direction: TextDirection.rtl,
      );
      final Finder figures = find.descendant(
        of: find.byType(PlayerCountIcon),
        matching: find.byIcon(Icons.person_rounded),
      );
      final Rect first = tester.getRect(figures.at(0));
      final Rect last = tester.getRect(figures.at(2));
      expect(
        first.left > last.left,
        isTrue,
        reason:
            'expected the first figure right of the last under rtl; first '
            '$first, last $last. $repro',
      );
    });

    testWidgets('the figures are excluded from semantics', (tester) async {
      const String repro =
          'Reproduce: scenario "icon semantics", flutter test '
          'test/home_plain_test.dart --plain-name "excluded from semantics". '
          'No random input is involved.';
      await pumpIcon(tester, const PlayerCountIcon(count: 2));
      final Finder excluding = find.descendant(
        of: find.byType(PlayerCountIcon),
        matching: find.byWidgetPredicate(
          (Widget w) => w is ExcludeSemantics && w.excluding,
        ),
      );
      final Finder around = find.ancestor(
        of: find.byType(PlayerCountIcon),
        matching: find.byWidgetPredicate(
          (Widget w) => w is ExcludeSemantics && w.excluding,
        ),
      );
      expect(
        excluding.evaluate().isNotEmpty || around.evaluate().isNotEmpty,
        isTrue,
        reason:
            'expected an ExcludeSemantics around the figures; found none '
            'inside or above PlayerCountIcon. $repro',
      );
    });
  });
}
