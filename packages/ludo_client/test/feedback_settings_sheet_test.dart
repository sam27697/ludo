// Conformance tests for work/ludo/orders/C-329-sound-vibration-switches.md,
// rules 1 through 6: the new file lib/src/feedback_settings_sheet.dart
// (showFeedbackSettingsSheet) and FeedbackScope.settingsOf, built in
// parallel by order 329, in a tree this file's author has not read.
// lib/src/feedback_settings_sheet.dart does not exist on this branch and
// FeedbackScope.settingsOf does not exist on feedback.dart's FeedbackScope
// (lib/src/feedback.dart:386-401 as read on this branch); every expectation
// below is read off C-329's own text, never off 329's code. This file is
// not expected to compile until 329 lands.
//
// Home and Game screens are driven the same way the sibling suites do:
// HomeScreen and GameScreen are mounted directly inside a MaterialApp built
// the way app.dart assembles one, with an explicit FeedbackScope above them
// (the seam test/feedback_wiring_test.dart and test/feedback_service_test.dart
// already use), rather than through LudoApp, so a test can pin an exact
// FeedbackSettings instance (haptics/sound) without racing
// FeedbackSettings.load()'s SharedPreferences read. GameScreen sits over a
// real RoomController and a FakeTransport (test/net/fake_transport.dart,
// read-only), never a hand-built RoomSnapshot. The fake-transport idiom
// (_Connector, _frame, _seatJson, _turnJson, _roomJson, _connectPlaying) is
// copied from test/game_screen_appbar_leave_label_test.dart and
// test/feedback_wiring_test.dart rather than imported, per this project's
// standing instruction never to import across test files. HomeScreen's own
// controller-never-connects factory is the same safety idiom
// test/home_screen_test.dart uses: its connector throws before constructing
// any transport, real or fake, so nothing in this file can ever open a
// socket -- no test here taps Create Room or Join Room.
//
// No pumpAndSettle is used once a sheet is open or a game screen with a live
// turn is mounted (standing lesson, test/feedback_wiring_test.dart's own
// header): bottom-sheet enter/exit transitions are flushed with bounded
// pump(Duration) calls the same way
// test/game_screen_appbar_leave_label_test.dart flushes game-leave-confirm
// (250ms enter, 50ms margin). pumpAndSettle is only used on a bare HomeScreen
// before any sheet is opened, the same way test/home_screen_test.dart's own
// "home screen renders" case does, since HomeScreen's entrance animation is
// one-shot and settles.
//
// One inference this file had to make without opening 329's code: C-329
// rule 1 requires "tapping anywhere on a row (not only the switch) flips
// it", which means some tap-detecting ancestor must span each row, but
// C-329 names no widget type for it (unlike the Switch, which it pins
// explicitly). The "each row is at least 48 tall" cases below measure the
// size of the nearest InkWell or GestureDetector ancestor of that row's
// Switch, on the reasoning that a tap-anywhere affordance needs one of
// those two (a ListTile with onTap wraps an InkWell internally, so this
// also covers that implementation). If 329 lands with the tap-anywhere
// affordance built some third way that is neither, these two cases fail to
// find any such ancestor and say so by name, which is this inference proven
// wrong, not a behavioural defect.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/server_config.dart';

import 'net/fake_transport.dart';

// --- shared keys -------------------------------------------------------

const Key _homeSettingsButtonKey = Key('home-settings-button');
const Key _gameSettingsButtonKey = Key('game-settings-button');
const Key _localeToggleKey = Key('locale-toggle-button');
const Key _leaveKey = Key('game-screen-appbar-leave');
const Key _pipStripKey = Key('game-seat-pip-strip');
const Key _sheetKey = Key('feedback-settings-sheet');
const Key _hapticsSwitchKey = Key('feedback-settings-haptics');
const Key _soundSwitchKey = Key('feedback-settings-sound');

const String _tooltipEn = 'Sound and vibration';
const String _tooltipAr = 'الصوت والاهتزاز';
const String _hapticsLabelEn = 'Vibration';
const String _hapticsLabelAr = 'الاهتزاز';
const String _soundLabelEn = 'Sound';
const String _soundLabelAr = 'الصوت';

// --- wire helpers, copied from the sibling suites' own idiom -----------

const String _testUrl = 'wss://feedback-settings-sheet-test.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'fss-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
  List<Map<String, Object?>>? seats,
  int mySeat = 0,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        seats: seats ?? _twoSeats,
        turn: turn,
        winner: winner,
      ),
    ),
  );
  await future;
  return (controller, transport);
}

// --- Home harness --------------------------------------------------------

/// Never asked to open a real or fake transport: the connector throws
/// before constructing anything. Nothing in this file's Home cases ever
/// taps Create Room or Join Room, so this should never be called; it exists
/// only so HomeScreen has a safe, inert factory, the same safety idiom
/// test/home_screen_test.dart's own _neverConnectsControllerFactory uses.
RoomController _neverConnectsController() {
  return RoomController(
    serverUrl: Uri.parse('wss://feedback-settings-sheet-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'feedback_settings_sheet_test.dart: this connector must never be '
        'asked to open a real or fake transport; nothing in this file taps '
        'Create Room or Join Room',
      );
    },
  );
}

Widget _homeHarness({
  required FeedbackSettings settings,
  FeedbackService service = const NoopFeedbackService(),
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: FeedbackScope(
      settings: settings,
      service: service,
      child: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: _neverConnectsController,
      ),
    ),
  );
}

Future<void> _mountHome(
  WidgetTester tester, {
  required FeedbackSettings settings,
  FeedbackService service = const NoopFeedbackService(),
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _homeHarness(settings: settings, service: service, locale: locale),
  );
  await tester.pumpAndSettle();
}

// --- Game harness ----------------------------------------------------------

Widget _gameHarness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mountGame(
  WidgetTester tester,
  RoomController controller, {
  required FeedbackSettings settings,
  FeedbackService service = const NoopFeedbackService(),
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _gameHarness(
      FeedbackScope(
        settings: settings,
        service: service,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
}

// --- opening/closing the sheet, bounded pumps only --------------------

/// Taps [buttonKey] and pumps just long enough for the modal bottom sheet's
/// 250ms enter transition to finish. No pumpAndSettle: a game screen with a
/// live turn countdown or die pulse never settles (standing lesson, see
/// this file's header).
Future<void> _openSheet(WidgetTester tester, Key buttonKey) async {
  await tester.tap(find.byKey(buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 50));
}

/// Pops the sheet's own route (not the screen under it) and pumps just long
/// enough for its exit transition to finish.
Future<void> _closeSheet(WidgetTester tester) async {
  final BuildContext context = tester.element(find.byKey(_sheetKey));
  Navigator.of(context).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 50));
}

/// The nearest InkWell or GestureDetector ancestor of [of] -- see this
/// file's header for why this, specifically, stands in for "the row" when
/// measuring its tap target height.
Finder _tapAncestorOf(Finder of) {
  return find
      .ancestor(
        of: of,
        matching: find.byWidgetPredicate(
          (Widget widget) => widget is InkWell || widget is GestureDetector,
        ),
      )
      .first;
}

void main() {
  // ==========================================================================
  // Rule 3 (home entry) / goal item 1.
  // ==========================================================================
  group('home-settings-button', () {
    testWidgets(
      'exists, is at least 48x48, shows Icons.tune_rounded, and carries the '
      'English tooltip "Sound and vibration"',
      // Catches: the button missing entirely; a tap target smaller than
      // 48dp (P9); the wrong icon reused from elsewhere (e.g. the locale
      // toggle's own glyph); a tooltip string other than settingsTooltip.
      (tester) async {
        await _mountHome(tester, settings: FeedbackSettings.forTest());

        final Finder button = find.byKey(_homeSettingsButtonKey);
        expect(
          button,
          findsOneWidget,
          reason: 'home-settings-button must exist on HomeScreen',
        );
        final Size size = tester.getSize(button);
        expect(
          size.width,
          greaterThanOrEqualTo(48.0),
          reason: 'home-settings-button width must be >=48, was ${size.width}',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(48.0),
          reason:
              'home-settings-button height must be >=48, was ${size.height}',
        );
        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.tune_rounded),
          ),
          findsOneWidget,
          reason: 'home-settings-button must show Icons.tune_rounded',
        );
        expect(
          find.descendant(of: button, matching: find.byTooltip(_tooltipEn)),
          findsOneWidget,
          reason:
              'home-settings-button must carry the tooltip '
              '"$_tooltipEn" (settingsTooltip, en)',
        );
      },
    );

    testWidgets(
      'carries the Arabic tooltip "الصوت والاهتزاز" under Locale(ar)',
      // Catches: settingsTooltip's Arabic translation missing or wrong, or
      // the tooltip never re-reading AppLocalizations under ar.
      (tester) async {
        await _mountHome(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );

        final Finder button = find.byKey(_homeSettingsButtonKey);
        expect(button, findsOneWidget, reason: 'fixture is broken');
        expect(
          find.descendant(of: button, matching: find.byTooltip(_tooltipAr)),
          findsOneWidget,
          reason:
              'home-settings-button must carry the tooltip '
              '"$_tooltipAr" (settingsTooltip, ar) under Locale(ar)',
        );
      },
    );

    testWidgets(
      'en: centre x sits left of locale-toggle-button',
      // Catches: the button placed on the end (right) side instead of the
      // start (left) side of the toggle, or placed with a literal "left"
      // offset that happens to pass in en but will not mirror in ar.
      (tester) async {
        await _mountHome(tester, settings: FeedbackSettings.forTest());

        final Finder settingsButton = find.byKey(_homeSettingsButtonKey);
        final Finder toggle = find.byKey(_localeToggleKey);
        expect(settingsButton, findsOneWidget, reason: 'fixture is broken');
        expect(toggle, findsOneWidget, reason: 'fixture is broken');

        final double settingsX = tester.getCenter(settingsButton).dx;
        final double toggleX = tester.getCenter(toggle).dx;
        expect(
          settingsX,
          lessThan(toggleX),
          reason:
              'en: home-settings-button centre x ($settingsX) must sit left '
              'of locale-toggle-button centre x ($toggleX)',
        );
      },
    );

    testWidgets(
      'ar: centre x sits right of locale-toggle-button',
      // Catches: the button's side never mirroring under RTL (a layout
      // built with left/right rather than start/end).
      (tester) async {
        await _mountHome(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );

        final Finder settingsButton = find.byKey(_homeSettingsButtonKey);
        final Finder toggle = find.byKey(_localeToggleKey);
        expect(settingsButton, findsOneWidget, reason: 'fixture is broken');
        expect(toggle, findsOneWidget, reason: 'fixture is broken');

        final double settingsX = tester.getCenter(settingsButton).dx;
        final double toggleX = tester.getCenter(toggle).dx;
        expect(
          settingsX,
          greaterThan(toggleX),
          reason:
              'ar: home-settings-button centre x ($settingsX) must sit '
              'right of locale-toggle-button centre x ($toggleX)',
        );
      },
    );

    testWidgets(
      'tapping it shows feedback-settings-sheet',
      // Catches: the button present but wired to nothing (onPressed never
      // calls showFeedbackSettingsSheet).
      (tester) async {
        await _mountHome(tester, settings: FeedbackSettings.forTest());

        expect(
          find.byKey(_sheetKey),
          findsNothing,
          reason: 'fixture is broken',
        );
        await _openSheet(tester, _homeSettingsButtonKey);

        expect(
          find.byKey(_sheetKey),
          findsOneWidget,
          reason:
              'tapping home-settings-button must show feedback-settings-sheet',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 1 (the sheet) / goal item 2.
  // ==========================================================================
  group('the sheet', () {
    testWidgets(
      'both switches show the settings\' own values at open (haptics on, '
      'sound off)',
      // Catches: a switch bound to the wrong setting (e.g. the sound switch
      // reading settings.haptics), or an initial value hardcoded to true
      // regardless of what the settings object actually holds.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: false,
        );
        await _mountHome(tester, settings: settings);
        await _openSheet(tester, _homeSettingsButtonKey);

        final Switch hapticsSwitch = tester.widget<Switch>(
          find.byKey(_hapticsSwitchKey),
        );
        final Switch soundSwitch = tester.widget<Switch>(
          find.byKey(_soundSwitchKey),
        );
        expect(
          hapticsSwitch.value,
          isTrue,
          reason:
              'feedback-settings-haptics must show settings.haptics '
              '(true); showed ${hapticsSwitch.value}',
        );
        expect(
          soundSwitch.value,
          isFalse,
          reason:
              'feedback-settings-sound must show settings.sound '
              '(false); showed ${soundSwitch.value}',
        );
      },
    );

    testWidgets(
      'tapping feedback-settings-sound flips settings.sound and the '
      'switch\'s own displayed value',
      // Catches: the switch toggling its own visual state without ever
      // calling the settings.sound setter (a local bool instead of the
      // real setting), which would make this test's settings.sound read
      // unchanged even though the widget looks flipped.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        await _mountHome(tester, settings: settings);
        await _openSheet(tester, _homeSettingsButtonKey);

        await tester.tap(find.byKey(_soundSwitchKey));
        await tester.pump();

        expect(
          settings.sound,
          isFalse,
          reason:
              'tapping feedback-settings-sound must flip settings.sound to '
              'false through the existing setter; it is still '
              '${settings.sound}',
        );
        final Switch soundSwitch = tester.widget<Switch>(
          find.byKey(_soundSwitchKey),
        );
        expect(
          soundSwitch.value,
          isFalse,
          reason:
              'feedback-settings-sound must show the new value (false) at '
              'once; it still shows ${soundSwitch.value}',
        );
      },
    );

    testWidgets(
      'tapping feedback-settings-haptics flips settings.haptics and the '
      'switch\'s own displayed value',
      // Catches: the same wrong-wiring mutation as the sound switch's own
      // case, on the haptics switch.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        await _mountHome(tester, settings: settings);
        await _openSheet(tester, _homeSettingsButtonKey);

        await tester.tap(find.byKey(_hapticsSwitchKey));
        await tester.pump();

        expect(
          settings.haptics,
          isFalse,
          reason:
              'tapping feedback-settings-haptics must flip settings.haptics '
              'to false; it is still ${settings.haptics}',
        );
        final Switch hapticsSwitch = tester.widget<Switch>(
          find.byKey(_hapticsSwitchKey),
        );
        expect(
          hapticsSwitch.value,
          isFalse,
          reason:
              'feedback-settings-haptics must show the new value (false) at '
              'once; it still shows ${hapticsSwitch.value}',
        );
      },
    );

    testWidgets(
      'tapping the sound row\'s label text, not the switch, flips sound too',
      // Catches: only the Switch widget itself being tappable, with the
      // rest of the row ("tapping anywhere on a row... flips it") wired to
      // nothing.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        await _mountHome(tester, settings: settings);
        await _openSheet(tester, _homeSettingsButtonKey);

        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byKey(_sheetKey)),
        );
        final Finder label = find.descendant(
          of: find.byKey(_sheetKey),
          matching: find.text(loc.settingsSound),
        );
        expect(
          label,
          findsOneWidget,
          reason: 'fixture is broken: the sound row label must be present',
        );
        expect(
          find.byKey(_soundSwitchKey).evaluate().length,
          1,
          reason: 'fixture is broken: exactly one feedback-settings-sound',
        );

        await tester.tap(label);
        await tester.pump();

        expect(
          settings.sound,
          isFalse,
          reason:
              'tapping the sound row\'s label (not the switch) must flip '
              'settings.sound to false; it is still ${settings.sound}',
        );
      },
    );

    testWidgets(
      'tapping the vibration row\'s label text, not the switch, flips '
      'haptics too',
      // Catches: the same row-tap-wired-to-nothing mutation, on the
      // vibration row.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        await _mountHome(tester, settings: settings);
        await _openSheet(tester, _homeSettingsButtonKey);

        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byKey(_sheetKey)),
        );
        final Finder label = find.descendant(
          of: find.byKey(_sheetKey),
          matching: find.text(loc.settingsHaptics),
        );
        expect(
          label,
          findsOneWidget,
          reason: 'fixture is broken: the vibration row label must be present',
        );

        await tester.tap(label);
        await tester.pump();

        expect(
          settings.haptics,
          isFalse,
          reason:
              'tapping the vibration row\'s label (not the switch) must '
              'flip settings.haptics to false; it is still '
              '${settings.haptics}',
        );
      },
    );

    testWidgets(
      'each row\'s tap-anywhere ancestor is at least 48 logical pixels tall',
      // Catches: a row drawn visually tall enough but whose tappable area
      // (the InkWell/GestureDetector that makes the whole row flip the
      // switch) is squeezed under 48dp (P9's own floor, "even when the
      // piece is drawn smaller"). See this file's header for the inference
      // behind using that ancestor to stand in for "the row".
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest();
        await _mountHome(tester, settings: settings);
        await _openSheet(tester, _homeSettingsButtonKey);

        final Finder hapticsRow = _tapAncestorOf(find.byKey(_hapticsSwitchKey));
        final Finder soundRow = _tapAncestorOf(find.byKey(_soundSwitchKey));
        expect(
          hapticsRow,
          findsOneWidget,
          reason:
              'no InkWell or GestureDetector ancestor found for '
              'feedback-settings-haptics; see this file\'s header note on '
              'that inference',
        );
        expect(
          soundRow,
          findsOneWidget,
          reason:
              'no InkWell or GestureDetector ancestor found for '
              'feedback-settings-sound; see this file\'s header note on '
              'that inference',
        );

        final double hapticsHeight = tester.getSize(hapticsRow).height;
        final double soundHeight = tester.getSize(soundRow).height;
        expect(
          hapticsHeight,
          greaterThanOrEqualTo(48.0),
          reason:
              'the vibration row\'s tap target must be at least 48 tall, '
              'was $hapticsHeight',
        );
        expect(
          soundHeight,
          greaterThanOrEqualTo(48.0),
          reason:
              'the sound row\'s tap target must be at least 48 tall, was '
              '$soundHeight',
        );
      },
    );

    testWidgets(
      'the sound icon is Icons.volume_off_rounded when off and '
      'Icons.volume_up_rounded when on',
      // Catches: the sound row's leading icon fixed to one glyph regardless
      // of settings.sound, so colour (if any) is the only signal -- exactly
      // the P9 violation the sheet itself exists to avoid repeating.
      (tester) async {
        final FeedbackSettings offSettings = FeedbackSettings.forTest(
          sound: false,
        );
        await _mountHome(tester, settings: offSettings);
        await _openSheet(tester, _homeSettingsButtonKey);

        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.byIcon(Icons.volume_off_rounded),
          ),
          findsOneWidget,
          reason:
              'with settings.sound false, the sheet must show '
              'Icons.volume_off_rounded',
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsNothing,
          reason:
              'with settings.sound false, Icons.volume_up_rounded must not '
              'also be present',
        );

        await tester.tap(find.byKey(_soundSwitchKey));
        await tester.pump();

        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
          reason:
              'flipping settings.sound to true must swap the icon to '
              'Icons.volume_up_rounded at once',
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.byIcon(Icons.volume_off_rounded),
          ),
          findsNothing,
          reason:
              'once settings.sound is true, Icons.volume_off_rounded must '
              'no longer be present',
        );
      },
    );

    testWidgets(
      'labels and title: en "Vibration"/"Sound"/"Sound and vibration"',
      // Catches: settingsHaptics/settingsSound/settingsTitle hardcoded to
      // the wrong text, or the title re-using some other string instead of
      // settingsTitle ("same text" as settingsTooltip per rule 6).
      (tester) async {
        await _mountHome(tester, settings: FeedbackSettings.forTest());
        await _openSheet(tester, _homeSettingsButtonKey);

        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_hapticsLabelEn),
          ),
          findsOneWidget,
          reason: 'the sheet must show the label "$_hapticsLabelEn" (en)',
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_soundLabelEn),
          ),
          findsOneWidget,
          reason: 'the sheet must show the label "$_soundLabelEn" (en)',
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_tooltipEn),
          ),
          findsOneWidget,
          reason:
              'the sheet\'s title must show "$_tooltipEn" '
              '(settingsTitle, same text as settingsTooltip, en)',
        );
      },
    );

    testWidgets(
      'labels and title: ar "الاهتزاز"/"الصوت"/"الصوت والاهتزاز"',
      // Catches: the Arabic translations of settingsHaptics, settingsSound
      // or settingsTitle missing or wrong.
      (tester) async {
        await _mountHome(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );
        await _openSheet(tester, _homeSettingsButtonKey);

        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_hapticsLabelAr),
          ),
          findsOneWidget,
          reason: 'the sheet must show the label "$_hapticsLabelAr" (ar)',
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_soundLabelAr),
          ),
          findsOneWidget,
          reason: 'the sheet must show the label "$_soundLabelAr" (ar)',
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_tooltipAr),
          ),
          findsOneWidget,
          reason:
              'the sheet\'s title must show "$_tooltipAr" '
              '(settingsTitle, ar) under Locale(ar)',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 4 (game entry) / goal item 3.
  // ==========================================================================
  group('game-settings-button', () {
    testWidgets(
      'exists on the playing screen, at least 48x48, shows Icons.tune_rounded',
      // Catches: the button never added to the playing state's top strip,
      // or added undersized.
      (tester) async {
        final (RoomController controller, _) = await _connectPlaying(
          tester,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: FeedbackSettings.forTest(),
        );

        final Finder button = find.byKey(_gameSettingsButtonKey);
        expect(
          button,
          findsOneWidget,
          reason:
              'game-settings-button must exist in the top strip on the '
              'playing screen',
        );
        final Size size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48.0));
        expect(size.height, greaterThanOrEqualTo(48.0));
        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.tune_rounded),
          ),
          findsOneWidget,
          reason: 'game-settings-button must show Icons.tune_rounded',
        );
      },
    );

    testWidgets(
      'exists on the finished screen, at least 48x48',
      // Catches: the button only present while a turn is live, vanishing
      // once the room reaches FINISHED, which would strand a player who
      // wants to mute before a rematch.
      (tester) async {
        final (RoomController controller, _) = await _connectPlaying(
          tester,
          state: 'FINISHED',
          winner: 0,
          turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 5),
        );
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: FeedbackSettings.forTest(),
        );

        final Finder button = find.byKey(_gameSettingsButtonKey);
        expect(
          button,
          findsOneWidget,
          reason:
              'game-settings-button must exist in the top strip on the '
              'finished screen',
        );
        final Size size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48.0));
        expect(size.height, greaterThanOrEqualTo(48.0));
      },
    );

    testWidgets(
      'en: centre x sits right of game-screen-appbar-leave',
      // Catches: the button placed on the same (start) side as Leave
      // instead of mirroring it on the end side, or placed with a literal
      // offset that happens to pass in en but will not mirror in ar.
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _connectPlaying(
          tester,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: FeedbackSettings.forTest(),
        );

        final Finder settingsButton = find.byKey(_gameSettingsButtonKey);
        final Finder leave = find.byKey(_leaveKey);
        expect(settingsButton, findsOneWidget, reason: 'fixture is broken');
        expect(leave, findsOneWidget, reason: 'fixture is broken');

        final double settingsX = tester.getCenter(settingsButton).dx;
        final double leaveX = tester.getCenter(leave).dx;
        expect(
          settingsX,
          greaterThan(leaveX),
          reason:
              'en: game-settings-button centre x ($settingsX) must sit '
              'right of game-screen-appbar-leave centre x ($leaveX)',
        );
      },
    );

    testWidgets(
      'ar: centre x sits left of game-screen-appbar-leave',
      // Catches: the button's side never mirroring under RTL.
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _connectPlaying(
          tester,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'سام'),
            _seatJson(1, name: 'بوب'),
          ],
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );

        final Finder settingsButton = find.byKey(_gameSettingsButtonKey);
        final Finder leave = find.byKey(_leaveKey);
        expect(settingsButton, findsOneWidget, reason: 'fixture is broken');
        expect(leave, findsOneWidget, reason: 'fixture is broken');

        final double settingsX = tester.getCenter(settingsButton).dx;
        final double leaveX = tester.getCenter(leave).dx;
        expect(
          settingsX,
          lessThan(leaveX),
          reason:
              'ar: game-settings-button centre x ($settingsX) must sit left '
              'of game-screen-appbar-leave centre x ($leaveX)',
        );
      },
    );

    testWidgets(
      'adding it does not move game-seat-pip-strip off the screen centre',
      // Catches: the button consuming layout space in a way that shifts the
      // seat-pip strip's own centring (e.g. a Row with Expanded siblings)
      // instead of sitting in its own PositionedDirectional, mirroring how
      // game-screen-appbar-leave already sits beside the strip without
      // moving it.
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _connectPlaying(
          tester,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: FeedbackSettings.forTest(),
        );

        expect(
          find.byKey(_gameSettingsButtonKey),
          findsOneWidget,
          reason: 'fixture is broken: game-settings-button must be present',
        );
        final Finder pipStrip = find.byKey(_pipStripKey);
        expect(pipStrip, findsOneWidget, reason: 'fixture is broken');

        final double screenMid =
            tester.view.physicalSize.width / tester.view.devicePixelRatio / 2;
        final double pipCentre = tester.getCenter(pipStrip).dx;
        expect(
          (pipCentre - screenMid).abs(),
          lessThanOrEqualTo(1.0),
          reason:
              'game-seat-pip-strip centre x ($pipCentre) must still equal '
              'the screen centre x ($screenMid) within 1 logical pixel '
              'once game-settings-button is added',
        );
      },
    );

    testWidgets(
      'tapping it shows feedback-settings-sheet',
      // Catches: the button present but wired to nothing.
      (tester) async {
        final (RoomController controller, _) = await _connectPlaying(
          tester,
          turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
        );
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: FeedbackSettings.forTest(),
        );

        expect(
          find.byKey(_sheetKey),
          findsNothing,
          reason: 'fixture is broken',
        );
        await _openSheet(tester, _gameSettingsButtonKey);

        expect(
          find.byKey(_sheetKey),
          findsOneWidget,
          reason:
              'tapping game-settings-button must show feedback-settings-sheet',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 5 (the effect is immediate, never cached) / goal item 4.
  // ==========================================================================
  group('rule 5: the effect is immediate, not cached', () {
    testWidgets(
      'switching Sound off in the sheet, then closing it, makes the next '
      'cue call haptic only, never sound',
      // Catches: the service reading settings.sound once at construction
      // (caching it) instead of at play() time, so a switch flipped after
      // the service was built would have no effect until the app restarts.
      (tester) async {
        final List<MethodCall> calls = <MethodCall>[];
        const MethodChannel channel = MethodChannel('app.fayad.ludo/feedback');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              calls.add(call);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );

        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        final PlatformFeedbackService service = PlatformFeedbackService(
          settings,
          channel,
        );
        addTearDown(service.dispose);

        final (RoomController controller, FakeTransport transport) =
            await _connectPlaying(tester, turn: null);
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: settings,
          service: service,
        );

        await _openSheet(tester, _gameSettingsButtonKey);
        await tester.tap(find.byKey(_soundSwitchKey));
        await tester.pump();
        expect(
          settings.sound,
          isFalse,
          reason: 'fixture is broken: the sound switch must have flipped off',
        );
        await _closeSheet(tester);

        // A 'turn' frame naming my own seat plays exactly [yourTurn]
        // (C-236/cuesForFrame), which the real PlatformFeedbackService turns
        // into one haptic and one sound call when both switches are on.
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 2},
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();

        expect(
          calls.where((MethodCall c) => c.method == 'haptic').length,
          1,
          reason:
              'with sound switched off and haptics still on, the next cue '
              'must still make exactly one haptic call; got $calls',
        );
        expect(
          calls.where((MethodCall c) => c.method == 'sound').length,
          0,
          reason:
              'with sound switched off in the sheet, the next cue must make '
              'no sound call at all; got $calls',
        );
      },
    );

    testWidgets(
      'switching Vibration off in the sheet, then closing it, makes the '
      'next cue call sound only, never haptic',
      // Catches the same caching mutation as the Sound case, on the
      // haptics channel.
      (tester) async {
        final List<MethodCall> calls = <MethodCall>[];
        const MethodChannel channel = MethodChannel('app.fayad.ludo/feedback');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              calls.add(call);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );

        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        final PlatformFeedbackService service = PlatformFeedbackService(
          settings,
          channel,
        );
        addTearDown(service.dispose);

        final (RoomController controller, FakeTransport transport) =
            await _connectPlaying(tester, turn: null);
        addTearDown(controller.dispose);
        await _mountGame(
          tester,
          controller,
          settings: settings,
          service: service,
        );

        await _openSheet(tester, _gameSettingsButtonKey);
        await tester.tap(find.byKey(_hapticsSwitchKey));
        await tester.pump();
        expect(
          settings.haptics,
          isFalse,
          reason: 'fixture is broken: the haptics switch must have flipped off',
        );
        await _closeSheet(tester);

        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 2},
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();

        expect(
          calls.where((MethodCall c) => c.method == 'sound').length,
          1,
          reason:
              'with vibration switched off and sound still on, the next cue '
              'must still make exactly one sound call; got $calls',
        );
        expect(
          calls.where((MethodCall c) => c.method == 'haptic').length,
          0,
          reason:
              'with vibration switched off in the sheet, the next cue must '
              'make no haptic call at all; got $calls',
        );
      },
    );
  });
}
