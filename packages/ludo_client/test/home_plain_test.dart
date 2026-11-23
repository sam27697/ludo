// Proof for contract C-523 (work/ludo/orders/C-523-home-plain-and-one-sound-
// switch.md), rules D1, D2, D3, D4, D5 and D9: a home screen that says only
// what a player needs. Written from the contract text, against no
// implementation of it. Updated for C-666 (work/ludo/orders/666-no-player-
// count.md) D1: the players question, its control and its menu are gone, so
// the cases that drove them now assert the replacement for the same
// situation: no control and no question on home, Create always sends four
// seats, the last-table chip paints the name and no count icon. The cases
// that only exercised the menu (its options, its fill, its dismissal) and
// the PlayerCountIcon widget cases are gone with the things they exercised.
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
// The chip's spoken label is the table name alone (C-666 D1, as confirmed
// for the committed implementation).

import 'dart:async';
import 'dart:convert';

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
import 'package:ludo_client/src/room_code.dart';
import 'package:ludo_client/src/server_config.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _playersButtonKey = Key('home-players-button');
const Key _createKey = Key('create-room-button');
const Key _joinKey = Key('join-room-button');
const Key _codeKey = Key('room-code-field');
const Key _lastTableKey = Key('home-last-table-chip');
const Key _nameFieldKey = Key('home-name-field');

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
  'home-players-button',
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

/// Lets a link join run: the link waits for session memory to load (a few
/// real-async turns), then the join pushes its route.
Future<void> _settleLink(WidgetTester tester) async {
  for (int i = 0; i < 6; i += 1) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
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
      // Red on the base: home_screen.dart mounts home-players-button and
      // paints "How many players?" and the count words.
      testWidgets('nothing the contract removes is on screen: no removed key, '
          'no rule control, no players control, no "players" word, no '
          'deleted string', (tester) async {
        const String name = 'removed things absent';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);

        for (final String key in _removedKeys) {
          expect(
            find.byKey(Key(key), skipOffstage: false),
            findsNothing,
            reason: 'expected no widget keyed $key on home; found one. $repro',
          );
        }
        for (final int n in <int>[2, 3, 4]) {
          expect(
            find.byKey(Key('home-players-option-$n'), skipOffstage: false),
            findsNothing,
            reason: 'expected no home-players-option-$n on home. $repro',
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
        final String question = lc == 'ar' ? _questionAr : _questionEn;
        expect(
          painted.where((String s) => s.contains(question)),
          isEmpty,
          reason:
              'expected the question "$question" painted nowhere (C-666 D1); '
              'painted strings were $painted. $repro',
        );
        final List<String> hits = _playersHits(painted, locale);
        expect(
          hits,
          isEmpty,
          reason:
              'expected no painted text with the word for "players" on a '
              'home with no count to choose; found $hits. $repro',
        );
        _expectNoOldStrings(painted, locale, repro);
      });

      // Red on the base: the always-visible row of C-523 D2 is still
      // there, so the 48 dp control sits between the name and Create.
      testWidgets('home has no players row: nothing keyed home-players-* '
          'and no row-sized gap between the name field and Create', (
        tester,
      ) async {
        const String name = 'no players row';
        final String repro = _repro(name, locale);
        await _mount(tester, locale: locale);

        expect(
          find.byKey(_playersButtonKey, skipOffstage: false),
          findsNothing,
          reason: 'expected no home-players-button on home. $repro',
        );
        final Rect field = tester.getRect(find.byKey(_nameFieldKey));
        final Rect create = tester.getRect(find.byKey(_createKey));
        final double gap = create.top - field.bottom;
        expect(
          gap > 0 && gap < 48,
          isTrue,
          reason:
              'expected the space between the name field and Create to be '
              'smaller than the 48 dp the players row took (no empty '
              'slot); it is $gap dp (field $field, create $create). $repro',
        );
      });

      // Red on the base: Create sends the count the control shows; with
      // the control gone the count is fixed at four.
      testWidgets('Create sends players 4 and rules {capture_bonus: true}', (
        tester,
      ) async {
        const String name = 'create sends four';
        final String repro = _repro(name, locale);
        final _LiveControllerFactory factory = _LiveControllerFactory();
        await _mount(tester, locale: locale, controllerFactory: factory.call);

        await _tapCreate(tester);
        final Map<String, Object?> data = _createData(factory, repro);
        expect(
          data['players'],
          4,
          reason:
              'expected create_room players 4; the frame carried '
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

      // Red on the base: _LastTableChip paints a PlayerCountIcon and the
      // loaded count drives the Create count.
      for (final int seats in <int>[2, 3]) {
        _semTest('last table of $seats seats: chip paints the name and no '
            'count icon, Create sends 4', (tester) async {
          final String name = 'last table $seats seats';
          final String repro = _repro(name, locale);
          await SessionMemory.recordSuccessfulCreate(
            name: 'Zed Quartz',
            seats: seats,
          );
          final _LiveControllerFactory factory = _LiveControllerFactory();
          await _mount(tester, locale: locale, controllerFactory: factory.call);

          expect(
            find.byKey(_lastTableKey, skipOffstage: false),
            findsNothing,
            reason:
                'expected no home-last-table-chip even with a remembered '
                'table (C-678 removed it). $repro',
          );
          expect(
            find.byKey(_playersButtonKey, skipOffstage: false),
            findsNothing,
            reason:
                'expected loading a $seats-seat table not to bring the '
                'players control back. $repro',
          );

          await _tapCreate(tester);
          expect(
            _createData(factory, repro)['players'],
            4,
            reason:
                'expected Create to send players 4 even though the stored '
                'table held $seats. $repro',
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
      testWidgets('Join is absent (not hidden) for empty and whitespace-only, '
          'present from 1 to 6 symbols, 7 typed shows the first 6, absent '
          'after clearing', (tester) async {
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
        expect(
          _join(),
          findsOneWidget,
          reason:
              'section 32 item 1: 5 symbols are a code to join; expected '
              'join-room-button present. $repro',
        );

        await tester.enterText(field, '   ');
        await tester.pumpAndSettle();
        expectAbsent('with only whitespace');

        await tester.enterText(field, 'AB C23');
        await tester.pumpAndSettle();
        expect(
          _join(),
          findsOneWidget,
          reason:
              'section 32 item 1: "AB C23" is 5 symbols once spaces are '
              'stripped; expected join-room-button present. $repro',
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
        expect(
          _codeText(tester),
          'ABC234',
          reason:
              'section 32 item 1 and the order: the field caps at 6 '
              'symbols, so 7 typed shows the first 6. $repro',
        );
        expect(
          _join(),
          findsOneWidget,
          reason: 'expected Join for the capped 6 symbols. $repro',
        );

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
        expect(
          _join(),
          findsOneWidget,
          reason: 'expected Join after deleting back to 5 symbols. $repro',
        );
        await tester.enterText(field, '');
        await tester.pumpAndSettle();
        expectAbsent('after clearing the field');
      });

      // C-678: the recent-code chips are gone, so a remembered code neither
      // shows as a chip nor brings Join; only typing does.
      testWidgets('a remembered code shows no chip and no Join', (
        tester,
      ) async {
        const String name = 'remembered code, no chip';
        final String repro = _repro(name, locale);
        await SessionMemory.recordSuccessfulJoin('AB23CD');
        await _mount(tester, locale: locale);
        expect(
          find.byKey(const Key('home-recent-code-AB23CD'), skipOffstage: false),
          findsNothing,
          reason: 'expected no recent-code chip (C-678). $repro',
        );
        expect(
          _join(),
          findsNothing,
          reason: 'expected no Join while the code field is empty. $repro',
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
      // Order 681: a link carries a link id, never a code, so it fills no
      // field and brings no Join; it joins by itself under one pushed route.
      // Join still comes only from a typed full-length code.
      testWidgets('a cold-start room link and a warm-start room link each '
          'join by link id, fill no field and bring no Join', (tester) async {
        const String name = 'link brings join';
        final String repro = _repro(name, locale);
        final _FakeInitialLinkReader reader = _FakeInitialLinkReader();
        final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
        final _PushProbe observer = _PushProbe();
        await _mount(
          tester,
          locale: locale,
          initialLinkReader: reader.call,
          linkStream: opener.call,
          observer: observer,
        );
        expect(
          _join(),
          findsNothing,
          reason: 'expected no Join before any link arrives. $repro',
        );
        final int pushesBefore = observer.pushCount;

        reader.complete(Uri.parse('https://$kAppLinkHost/r/t5k2q9a-x7m3pd'));
        await _settleLink(tester);
        expect(
          observer.pushCount,
          pushesBefore + 1,
          reason: 'expected the cold link id to join under one route. $repro',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(_codeKey, skipOffstage: false))
              .controller!
              .text,
          isEmpty,
          reason: 'expected the cold link id to fill no field. $repro',
        );
        expect(
          _join(),
          findsNothing,
          reason: 'expected no Join after a cold-start link id. $repro',
        );
        Navigator.of(
          tester.element(find.byType(HomeScreen, skipOffstage: false)),
        ).pop();
        await _drainRequestTimeout(tester);
        await tester.pumpAndSettle();

        await tester.enterText(find.byKey(_codeKey), 'K7M2QP');
        await tester.pumpAndSettle();
        expect(
          find.byKey(_joinKey),
          findsOneWidget,
          reason: 'expected Join from the typed full-length code. $repro',
        );
        await tester.enterText(find.byKey(_codeKey), '');
        await tester.pumpAndSettle();
        expect(
          _join(),
          findsNothing,
          reason: 'expected Join gone once the typed code is cleared. $repro',
        );

        opener.add(Uri.parse('https://$kAppLinkHost/r/w8n4b6c2-q3z9rt'));
        await _settleLink(tester);
        expect(
          observer.pushCount,
          pushesBefore + 2,
          reason: 'expected the warm link id to join under one route. $repro',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(_codeKey, skipOffstage: false))
              .controller!
              .text,
          isEmpty,
          reason: 'expected the warm link id to fill no field. $repro',
        );
        expect(
          _join(),
          findsNothing,
          reason: 'expected no Join after a warm-start link id. $repro',
        );
        Navigator.of(
          tester.element(find.byType(HomeScreen, skipOffstage: false)),
        ).pop();
        await _drainRequestTimeout(tester);
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
        // Section 32 item 1: 0 is a symbol now; the symbol outside the
        // alphabet that stays invalid is a punctuation mark.
        const String invalid = 'AB#234';
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

        await tester.enterText(find.byKey(_codeKey), '');
        await tester.pumpAndSettle();
        expect(
          _join(),
          findsNothing,
          reason: 'expected Join gone after clearing the field. $repro',
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
}
