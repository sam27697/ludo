// Conformance tests for work/ludo/orders/C-329-sound-vibration-switches.md,
// carried over to C-523 D7. This file used to be feedback_settings_sheet_test
// .dart and covered the settings button on home and game, the sheet it
// opened, and rule 5 (the effect of a switch is immediate, never cached).
// C-523 removed the sheet and its two switches, so the cases that pinned the
// sheet are gone (listed in the order 525 report). What still holds is kept:
//
//   - the control's size, icon, tooltip and mirrored placement on home and
//     game, now measured on home-sound-toggle and game-sound-toggle;
//   - the sound icon follows the state (volume_up on, volume_off muted);
//   - rule 5: the real PlatformFeedbackService reads FeedbackSettings at
//     play() time, so a flag flipped after the service was built changes the
//     very next cue. The two per-channel cases flip the public setters
//     FeedbackSettings keeps (D8), and a third drives the same property
//     through the toggle.
//
// HomeScreen and GameScreen are mounted directly inside a MaterialApp built
// the way app.dart assembles one, with an explicit FeedbackScope above them
// (the seam test/feedback_wiring_test.dart and test/feedback_service_test.dart
// already use). GameScreen sits over a real RoomController and a
// FakeTransport (test/net/fake_transport.dart, read-only). The fake-transport
// idiom (_Connector, _frame, _seatJson, _turnJson, _roomJson, _connectPlaying)
// is copied from test/game_screen_appbar_leave_label_test.dart rather than
// imported, per this project's standing instruction never to import across
// test files. HomeScreen's controller factory throws before building any
// transport, so nothing here can open a socket. No pumpAndSettle once a game
// screen with a live turn is mounted (standing lesson,
// test/feedback_wiring_test.dart's own header).

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

import 'net/fake_transport.dart';

const Key _homeSoundToggleKey = Key('home-sound-toggle');
const Key _gameSoundToggleKey = Key('game-sound-toggle');
const Key _localeToggleKey = Key('locale-toggle-button');
const Key _leaveKey = Key('game-screen-appbar-leave');
const Key _pipStripKey = Key('game-seat-pip-strip');

const String _tooltipEn = 'Sound and vibration';
const String _tooltipAr = 'الصوت والاهتزاز';

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
/// taps Create Room or Join Room.
RoomController _neverConnectsController() {
  return RoomController(
    serverUrl: Uri.parse('wss://feedback-sound-toggle-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'feedback_sound_toggle_test.dart: this connector must never be '
        'asked to open a real or fake transport; nothing in this file taps '
        'Create Room or Join Room',
      );
    },
  );
}

Future<void> _mountHome(
  WidgetTester tester, {
  required FeedbackSettings settings,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
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
        service: const NoopFeedbackService(),
        child: HomeScreen(
          onToggleLocale: () {},
          controllerFactory: _neverConnectsController,
        ),
      ),
    ),
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

void main() {
  group('home-sound-toggle', () {
    testWidgets(
      'exists, is at least 48x48, shows Icons.volume_up_rounded, and carries '
      'the English tooltip "Sound and vibration"',
      // Catches: the control missing entirely; a tap target smaller than
      // 48dp (P9); the wrong icon reused from elsewhere (e.g. the locale
      // toggle's own glyph); a tooltip string other than soundToggleLabel.
      (tester) async {
        await _mountHome(tester, settings: FeedbackSettings.forTest());

        final Finder button = find.byKey(_homeSoundToggleKey);
        expect(
          button,
          findsOneWidget,
          reason: 'home-sound-toggle must exist on HomeScreen',
        );
        final Size size = tester.getSize(button);
        expect(
          size.width,
          greaterThanOrEqualTo(48.0),
          reason: 'home-sound-toggle width must be >=48, was ${size.width}',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(48.0),
          reason: 'home-sound-toggle height must be >=48, was ${size.height}',
        );
        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
          reason: 'home-sound-toggle must show Icons.volume_up_rounded',
        );
        expect(
          find.descendant(of: button, matching: find.byTooltip(_tooltipEn)),
          findsOneWidget,
          reason:
              'home-sound-toggle must carry the tooltip '
              '"$_tooltipEn" (soundToggleLabel, en)',
        );
      },
    );

    testWidgets(
      'carries the Arabic tooltip "الصوت والاهتزاز" under Locale(ar)',
      // Catches: soundToggleLabel's Arabic translation missing or wrong, or
      // the tooltip never re-reading AppLocalizations under ar.
      (tester) async {
        await _mountHome(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );

        final Finder button = find.byKey(_homeSoundToggleKey);
        expect(button, findsOneWidget, reason: 'fixture is broken');
        expect(
          find.descendant(of: button, matching: find.byTooltip(_tooltipAr)),
          findsOneWidget,
          reason:
              'home-sound-toggle must carry the tooltip '
              '"$_tooltipAr" (soundToggleLabel, ar) under Locale(ar)',
        );
      },
    );

    testWidgets(
      'en: centre x sits left of locale-toggle-button',
      // Catches: the control placed on the end (right) side instead of the
      // start (left) side of the toggle, or placed with a literal "left"
      // offset that happens to pass in en but will not mirror in ar.
      (tester) async {
        await _mountHome(tester, settings: FeedbackSettings.forTest());

        final Finder soundToggle = find.byKey(_homeSoundToggleKey);
        final Finder toggle = find.byKey(_localeToggleKey);
        expect(soundToggle, findsOneWidget, reason: 'fixture is broken');
        expect(toggle, findsOneWidget, reason: 'fixture is broken');

        final double soundX = tester.getCenter(soundToggle).dx;
        final double toggleX = tester.getCenter(toggle).dx;
        expect(
          soundX,
          lessThan(toggleX),
          reason:
              'en: home-sound-toggle centre x ($soundX) must sit left '
              'of locale-toggle-button centre x ($toggleX)',
        );
      },
    );

    testWidgets(
      'ar: centre x sits right of locale-toggle-button',
      // Catches: the control's side never mirroring under RTL (a layout
      // built with left/right rather than start/end).
      (tester) async {
        await _mountHome(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );

        final Finder soundToggle = find.byKey(_homeSoundToggleKey);
        final Finder toggle = find.byKey(_localeToggleKey);
        expect(soundToggle, findsOneWidget, reason: 'fixture is broken');
        expect(toggle, findsOneWidget, reason: 'fixture is broken');

        final double soundX = tester.getCenter(soundToggle).dx;
        final double toggleX = tester.getCenter(toggle).dx;
        expect(
          soundX,
          greaterThan(toggleX),
          reason:
              'ar: home-sound-toggle centre x ($soundX) must sit '
              'right of locale-toggle-button centre x ($toggleX)',
        );
      },
    );

    testWidgets(
      'the icon is Icons.volume_off_rounded when muted and '
      'Icons.volume_up_rounded when on',
      // Catches: the icon fixed to one glyph regardless of settings, so
      // colour (if any) is the only signal -- the P9 violation the control
      // exists to avoid repeating.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: false,
          sound: false,
        );
        await _mountHome(tester, settings: settings);
        final Finder button = find.byKey(_homeSoundToggleKey);

        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.volume_off_rounded),
          ),
          findsOneWidget,
          reason: 'with both channels off, the control must show volume_off',
        );
        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsNothing,
          reason:
              'with both channels off, Icons.volume_up_rounded must not '
              'also be present',
        );

        await tester.tap(button);
        await tester.pump();

        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
          reason: 'unmuting must swap the icon to volume_up at once',
        );
        expect(
          find.descendant(
            of: button,
            matching: find.byIcon(Icons.volume_off_rounded),
          ),
          findsNothing,
          reason: 'once unmuted, Icons.volume_off_rounded must be gone',
        );
      },
    );
  });

  group('game-sound-toggle', () {
    testWidgets('exists on the playing screen, at least 48x48, shows '
        'Icons.volume_up_rounded', (tester) async {
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

      final Finder button = find.byKey(_gameSoundToggleKey);
      expect(
        button,
        findsOneWidget,
        reason:
            'game-sound-toggle must exist in the top strip on the '
            'playing screen',
      );
      final Size size = tester.getSize(button);
      expect(
        size.width,
        greaterThanOrEqualTo(48.0),
        reason: 'game-sound-toggle width must be >=48, was ${size.width}',
      );
      expect(
        size.height,
        greaterThanOrEqualTo(48.0),
        reason: 'game-sound-toggle height must be >=48, was ${size.height}',
      );
      expect(
        find.descendant(
          of: button,
          matching: find.byIcon(Icons.volume_up_rounded),
        ),
        findsOneWidget,
        reason: 'game-sound-toggle must show Icons.volume_up_rounded',
      );
    });

    testWidgets('exists on the finished screen, at least 48x48', (
      tester,
    ) async {
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

      final Finder button = find.byKey(_gameSoundToggleKey);
      expect(
        button,
        findsOneWidget,
        reason:
            'game-sound-toggle must exist in the top strip on the '
            'finished screen',
      );
      final Size size = tester.getSize(button);
      expect(size.width, greaterThanOrEqualTo(48.0));
      expect(size.height, greaterThanOrEqualTo(48.0));
    });

    testWidgets('en: centre x sits right of game-screen-appbar-leave', (
      tester,
    ) async {
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

      final Finder soundToggle = find.byKey(_gameSoundToggleKey);
      final Finder leave = find.byKey(_leaveKey);
      expect(soundToggle, findsOneWidget, reason: 'fixture is broken');
      expect(leave, findsOneWidget, reason: 'fixture is broken');

      final double soundX = tester.getCenter(soundToggle).dx;
      final double leaveX = tester.getCenter(leave).dx;
      expect(
        soundX,
        greaterThan(leaveX),
        reason:
            'en: game-sound-toggle centre x ($soundX) must sit '
            'right of game-screen-appbar-leave centre x ($leaveX)',
      );
    });

    testWidgets('ar: centre x sits left of game-screen-appbar-leave', (
      tester,
    ) async {
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

      final Finder soundToggle = find.byKey(_gameSoundToggleKey);
      final Finder leave = find.byKey(_leaveKey);
      expect(soundToggle, findsOneWidget, reason: 'fixture is broken');
      expect(leave, findsOneWidget, reason: 'fixture is broken');

      final double soundX = tester.getCenter(soundToggle).dx;
      final double leaveX = tester.getCenter(leave).dx;
      expect(
        soundX,
        lessThan(leaveX),
        reason:
            'ar: game-sound-toggle centre x ($soundX) must sit left '
            'of game-screen-appbar-leave centre x ($leaveX)',
      );
    });

    testWidgets('it does not move game-seat-pip-strip off the screen centre', (
      tester,
    ) async {
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
        find.byKey(_gameSoundToggleKey),
        findsOneWidget,
        reason: 'fixture is broken: game-sound-toggle must be present',
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
            'once game-sound-toggle is present',
      );
    });
  });

  group('rule 5: the effect is immediate, not cached', () {
    testWidgets(
      'switching Sound off after the service was built makes the next cue '
      'call haptic only, never sound',
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

        settings.sound = false;
        await tester.pump();
        expect(
          settings.sound,
          isFalse,
          reason: 'fixture is broken: the sound flag must have flipped off',
        );

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
              'with sound switched off, the next cue must make '
              'no sound call at all; got $calls',
        );
      },
    );

    testWidgets(
      'switching Vibration off after the service was built makes the next '
      'cue call sound only, never haptic',
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

        settings.haptics = false;
        await tester.pump();
        expect(
          settings.haptics,
          isFalse,
          reason: 'fixture is broken: the haptics flag must have flipped off',
        );

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
              'with vibration switched off, the next cue must '
              'make no haptic call at all; got $calls',
        );
      },
    );

    testWidgets(
      'muting with game-sound-toggle makes the next cue call nothing, and '
      'unmuting makes the next cue call haptic and sound again',
      // Catches: the toggle flipping a copy of the flags, or the service
      // caching what it read at construction, so the single switch would
      // stop working until the app restarts.
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

        await tester.tap(find.byKey(_gameSoundToggleKey));
        await tester.pump();
        expect(
          settings.muted,
          isTrue,
          reason: 'fixture is broken: one tap on the toggle must mute',
        );

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
          calls,
          isEmpty,
          reason:
              'with the toggle muted, a cue for my own turn must make no '
              'platform call at all; got $calls',
        );

        await tester.tap(find.byKey(_gameSoundToggleKey));
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        expect(
          settings.muted,
          isFalse,
          reason: 'fixture is broken: a second tap must unmute',
        );
        calls.clear();

        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 3},
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
              'after unmuting, the next cue must make exactly one haptic '
              'call; got $calls',
        );
        expect(
          calls.where((MethodCall c) => c.method == 'sound').length,
          1,
          reason:
              'after unmuting, the next cue must make exactly one sound '
              'call; got $calls',
        );
      },
    );
  });
}
