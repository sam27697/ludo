// Conformance tests for work/ludo/orders/C-335-lobby-settings-entry.md,
// carried over to C-523 D7 (this file was lobby_settings_button_test.dart):
// `lobby-sound-toggle` in the lobby's chrome row (lib/src/lobby_screen.dart,
// the SizedBox(height: 48) Stack that already holds game-seat-pip-strip and
// lobby-leave-button) replaced the settings button and its sheet. Rule 1
// (size, tooltip, mirrored placement, pip strip centred, present in the
// stale state) now measures the toggle. The cases that opened the sheet are
// gone with the sheet; the same-instance and not-cached cases are driven by
// the toggle instead.
//
// LobbyScreen is driven the way test/lobby_leave_corner_test.dart and
// test/lobby_signature_chrome_test.dart drive it: a real RoomController
// over a FakeTransport (test/net/fake_transport.dart, read-only here) and a
// small connector double copied by hand from that shared idiom, per this
// project's standing instruction never to import across test files. The
// FeedbackScope harness (settings + service passed down to a screen built
// directly, without LudoApp) lets a case pin an exact FeedbackSettings
// instance without racing FeedbackSettings.load()'s SharedPreferences read,
// and so rule 2 ("same object") is something this file can actually hold a
// reference to and inspect.
//
// One LobbyScreen mount per case. No pumpAndSettle once a LobbyScreen is
// mounted (it may run a live countdown); every pump after that point is a
// bounded one. Every controller is disposed in the test body itself (a
// try/finally), never only through addTearDown, per this order's own
// instruction.
//
// Ambiguities, reported rather than invented around:
//
//   1. The contract names no key for the stale state's own fixture beyond
//      "the state lobby_stale_room_test.dart drives". That file reaches it
//      with autoReconnectDelays left at the controller's own default
//      (empty, so no automatic reconnect timer is ever scheduled) and a
//      plain `transport.endFromFarSide()`: the controller lands in
//      RoomPhase.closed with `room` still set and stays there, which is
//      lobby_screen.dart's own `stale` condition (room != null && phase ==
//      closed, read off this branch's lobby_screen.dart lines ~292-298).
//      This file reproduces that exact recipe rather than inventing a new
//      one.
//
//   2. Item 4 ("play one cue") names no specific cue and no frame. Nothing
//      in cuesForFrame (lib/src/feedback.dart) derives a cue from a lobby
//      frame; that derivation is wired into game_screen.dart only, and
//      C-335 does not touch cuesForFrame or game_screen.dart. This file
//      therefore calls `service.play(FeedbackCue.yourTurn)` directly, the
//      same seam C-329's own rule-5 test exercises once a frame would have
//      produced a cue, rather than inventing a frame that cuesForFrame was
//      never asked to recognise from a lobby.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

// --- shared keys -------------------------------------------------------

const Key _settingsButtonKey = Key('lobby-sound-toggle');
const Key _leaveKey = Key('lobby-leave-button');
const Key _pipStripKey = Key('game-seat-pip-strip');
const Key _staleRoomKey = Key('lobby-stale-room');
const String _tooltipEn = 'Sound and vibration';
const String _tooltipAr = 'الصوت والاهتزاز';

const String _testUrl = 'wss://lobby-sound-toggle-test.invalid/ws';

// --- wire helpers, copied by hand from the sibling lobby suites' own
// --- idiom, per this project's standing instruction never to import
// --- across test files. ----------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'lsb-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Host')],
  'turn': null,
  'winner': null,
  'seq': seq,
};

List<Map<String, Object?>> _twoSeats() => <Map<String, Object?>>[
  _seatJson(0, name: 'Host'),
  _seatJson(1, name: 'Guest'),
];

// --- a TransportConnector test double, copied from the sibling lobby
// --- suites' own idiom rather than imported: it is not exported by any
// --- of them. ------------------------------------------------------------

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

// --- harness: LobbyScreen under an explicit FeedbackScope, never through
// --- LudoApp, so a case can pin and later inspect the exact
// --- FeedbackSettings instance (rule 2). --------------------------------

Widget _harness({
  required Widget lobby,
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
    home: FeedbackScope(settings: settings, service: service, child: lobby),
  );
}

/// Mounts a fresh host (create) lobby, resolves it to RoomPhase.connected
/// with a 2-of-[players] room, and returns the controller and transport.
/// One LobbyScreen mount; the caller disposes [controller] itself.
Future<(RoomController, FakeTransport)> _mountHostLobby(
  WidgetTester tester, {
  required FeedbackSettings settings,
  FeedbackService service = const NoopFeedbackService(),
  Locale locale = const Locale('en'),
  int players = 4,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  await tester.pumpWidget(
    _harness(
      lobby: LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Host',
        players: players,
      ),
      settings: settings,
      service: service,
      locale: locale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture is broken: LobbyScreen.initState must have sent '
        'create_room by now',
  );
  final String id = _idOf(transport.sentRaw.last);

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
      data: _roomJson(hostSeat: 0, players: players, seats: _twoSeats()),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture is broken: the host rig must reach RoomPhase.connected '
        'before any rule 1 or rule 2 case can be asserted; got '
        '${controller.phase}',
  );
  return (controller, transport);
}

/// Mounts a fresh guest (join) lobby seated at seat 1, resolves it to
/// RoomPhase.connected with a 2-of-[players] room, and returns the
/// controller and transport. One LobbyScreen mount; the caller disposes
/// [controller] itself.
Future<(RoomController, FakeTransport)> _mountGuestLobby(
  WidgetTester tester, {
  required FeedbackSettings settings,
  FeedbackService service = const NoopFeedbackService(),
  Locale locale = const Locale('en'),
  int players = 4,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  await tester.pumpWidget(
    _harness(
      lobby: LobbyScreen(
        controller: controller,
        action: LobbyAction.join,
        code: 'ABC234',
        playerName: 'Guest',
      ),
      settings: settings,
      service: service,
      locale: locale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture is broken: LobbyScreen.initState must have sent '
        'join_room by now',
  );
  final String id = _idOf(transport.sentRaw.last);

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 1, 'seat_token': 'tok-1'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(hostSeat: 0, players: players, seats: _twoSeats()),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture is broken: the guest rig must reach RoomPhase.connected '
        'before any rule 1 or rule 2 case can be asserted; got '
        '${controller.phase}',
  );
  return (controller, transport);
}

void main() {
  // ==========================================================================
  // Rule 1: the connected lobby entry, host and guest, en and ar.
  // ==========================================================================
  group('rule 1: lobby-sound-toggle, connected lobby', () {
    testWidgets(
      'host, en: exists, >=48x48, tooltip "Sound and vibration", sits '
      'right of lobby-leave-button, same centre y, pip strip stays centred',
      // Catches: the button missing entirely; a tap target under 48dp
      // (P9); the wrong tooltip; the button placed with a literal "left"
      // offset rather than PositionedDirectional(end:), which would happen
      // to read "right of leave" in en too but is caught instead by the ar
      // case below; the button pushing game-seat-pip-strip off centre
      // (e.g. a Row with Expanded siblings instead of its own
      // PositionedDirectional).
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _mountHostLobby(
          tester,
          settings: FeedbackSettings.forTest(),
        );
        try {
          final Finder button = find.byKey(_settingsButtonKey);
          expect(
            button,
            findsOneWidget,
            reason:
                'lobby-sound-toggle must exist in the connected host '
                'lobby',
          );
          final Size size = tester.getSize(button);
          expect(
            size.width,
            greaterThanOrEqualTo(48.0),
            reason: 'lobby-sound-toggle width must be >=48, was ${size.width}',
          );
          expect(
            size.height,
            greaterThanOrEqualTo(48.0),
            reason:
                'lobby-sound-toggle height must be >=48, was '
                '${size.height}',
          );
          expect(
            find.descendant(of: button, matching: find.byTooltip(_tooltipEn)),
            findsOneWidget,
            reason:
                'lobby-sound-toggle must carry the tooltip "$_tooltipEn" '
                '(settingsTooltip, en)',
          );

          final Finder leave = find.byKey(_leaveKey);
          expect(leave, findsOneWidget, reason: 'fixture is broken');
          final Offset settingsCentre = tester.getCenter(button);
          final Offset leaveCentre = tester.getCenter(leave);
          expect(
            settingsCentre.dx,
            greaterThan(leaveCentre.dx),
            reason:
                'en: lobby-sound-toggle centre x (${settingsCentre.dx}) '
                'must sit right of lobby-leave-button centre x '
                '(${leaveCentre.dx})',
          );
          expect(
            (settingsCentre.dy - leaveCentre.dy).abs(),
            lessThanOrEqualTo(1.0),
            reason:
                'lobby-sound-toggle centre y (${settingsCentre.dy}) must '
                'equal lobby-leave-button centre y (${leaveCentre.dy}) '
                'within 1 logical pixel',
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
                'once lobby-sound-toggle is added',
          );
        } finally {
          controller.dispose();
        }
      },
    );

    testWidgets(
      'host, ar: tooltip "الصوت والاهتزاز", sits left of lobby-leave-button',
      // Catches: the button's side never mirroring under RTL (a layout
      // built with left/right rather than start/end, or a literal
      // PositionedDirectional(start:) on the settings button instead of
      // end:); the Arabic translation of settingsTooltip missing or wrong.
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _mountHostLobby(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );
        try {
          final Finder button = find.byKey(_settingsButtonKey);
          expect(button, findsOneWidget, reason: 'fixture is broken');
          expect(
            find.descendant(of: button, matching: find.byTooltip(_tooltipAr)),
            findsOneWidget,
            reason:
                'lobby-sound-toggle must carry the tooltip "$_tooltipAr" '
                '(settingsTooltip, ar) under Locale(ar)',
          );

          final Finder leave = find.byKey(_leaveKey);
          expect(leave, findsOneWidget, reason: 'fixture is broken');
          final double settingsX = tester.getCenter(button).dx;
          final double leaveX = tester.getCenter(leave).dx;
          expect(
            settingsX,
            lessThan(leaveX),
            reason:
                'ar: lobby-sound-toggle centre x ($settingsX) must sit '
                'left of lobby-leave-button centre x ($leaveX)',
          );
        } finally {
          controller.dispose();
        }
      },
    );

    testWidgets(
      'guest, en: exists, >=48x48, sits right of lobby-leave-button',
      // Catches: the button only built for the host branch of the chrome
      // row, leaving a guest unable to mute while waiting (the contract's
      // own words: "for host and guest alike").
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _mountGuestLobby(
          tester,
          settings: FeedbackSettings.forTest(),
        );
        try {
          final Finder button = find.byKey(_settingsButtonKey);
          expect(
            button,
            findsOneWidget,
            reason:
                'lobby-sound-toggle must exist in the connected guest '
                'lobby, not only the host\'s',
          );
          final Size size = tester.getSize(button);
          expect(size.width, greaterThanOrEqualTo(48.0));
          expect(size.height, greaterThanOrEqualTo(48.0));

          final Finder leave = find.byKey(_leaveKey);
          expect(leave, findsOneWidget, reason: 'fixture is broken');
          final double settingsX = tester.getCenter(button).dx;
          final double leaveX = tester.getCenter(leave).dx;
          expect(
            settingsX,
            greaterThan(leaveX),
            reason:
                'en: guest lobby-sound-toggle centre x ($settingsX) '
                'must sit right of lobby-leave-button centre x ($leaveX)',
          );
        } finally {
          controller.dispose();
        }
      },
    );

    testWidgets(
      'guest, ar: sits left of lobby-leave-button',
      // Catches the same host-only or non-mirroring mutations as the host
      // ar case, on the guest branch.
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final (RoomController controller, _) = await _mountGuestLobby(
          tester,
          settings: FeedbackSettings.forTest(),
          locale: const Locale('ar'),
        );
        try {
          final Finder button = find.byKey(_settingsButtonKey);
          expect(button, findsOneWidget, reason: 'fixture is broken');
          final Finder leave = find.byKey(_leaveKey);
          expect(leave, findsOneWidget, reason: 'fixture is broken');
          final double settingsX = tester.getCenter(button).dx;
          final double leaveX = tester.getCenter(leave).dx;
          expect(
            settingsX,
            lessThan(leaveX),
            reason:
                'ar: guest lobby-sound-toggle centre x ($settingsX) '
                'must sit left of lobby-leave-button centre x ($leaveX)',
          );
        } finally {
          controller.dispose();
        }
      },
    );
  });

  // ==========================================================================
  // Rule 1, item 2: the stale lobby (room held, socket down) keeps the
  // button too.
  // ==========================================================================
  group('rule 1: lobby-sound-toggle, stale lobby', () {
    testWidgets(
      'a dropped socket with a room held (lobby_stale_room_test.dart\'s own '
      'recipe) still shows lobby-sound-toggle, outside the dimmed '
      'wrapper',
      // Catches: the button built only inside the `connected` branch of
      // `if (connected || stale)` rather than both, which would strand a
      // player who drops connection mid-wait exactly the way C-284 already
      // fixed for lobby-leave-button.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest();
        final (RoomController controller, FakeTransport transport) =
            await _mountHostLobby(tester, settings: settings);
        try {
          transport.endFromFarSide();
          await tester.pump();
          await tester.pump();

          expect(
            controller.phase,
            RoomPhase.closed,
            reason:
                'fixture is broken: endFromFarSide with no '
                'autoReconnectDelays scheduled must leave the controller '
                'at RoomPhase.closed',
          );
          expect(
            controller.room,
            isNotNull,
            reason: 'fixture is broken: the stale condition needs room != null',
          );

          final Finder button = find.byKey(_settingsButtonKey);
          expect(
            button,
            findsOneWidget,
            reason:
                'lobby-sound-toggle must still be present once the '
                'lobby goes stale',
          );
          expect(
            find.descendant(of: find.byKey(_staleRoomKey), matching: button),
            findsNothing,
            reason:
                'lobby-sound-toggle must sit outside the dimmed '
                'lobby-stale-room wrapper, so it stays tappable while '
                'stale, exactly as lobby-leave-button already does',
          );
        } finally {
          controller.dispose();
        }
      },
    );
  });

  // ==========================================================================
  // The toggle writes the FeedbackSettings the FeedbackScope above the lobby
  // holds, and the effect is immediate, never cached, from the lobby entry.
  // ==========================================================================
  group('rule 2: same settings, from the lobby', () {
    testWidgets(
      'tapping lobby-sound-toggle flips the same FeedbackSettings instance '
      'the FeedbackScope above the lobby holds',
      // Catches: the control (or the lobby's own call site) building a fresh
      // FeedbackSettings instead of reading FeedbackScope.settingsOf(context)
      // -- if it did, the icon would still flip visually but this test's
      // own `settings` reference, the one object the FeedbackScope above
      // this LobbyScreen actually holds, would stay unchanged.
      (tester) async {
        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: true,
          sound: true,
        );
        final (RoomController controller, _) = await _mountHostLobby(
          tester,
          settings: settings,
        );
        try {
          await tester.tap(find.byKey(_settingsButtonKey));
          await tester.pump();

          expect(
            settings.sound,
            isFalse,
            reason:
                'tapping lobby-sound-toggle must flip the FeedbackScope\'s '
                'own settings.sound to false; it is still ${settings.sound}',
          );
          expect(
            settings.haptics,
            isFalse,
            reason:
                'tapping lobby-sound-toggle must flip the FeedbackScope\'s '
                'own settings.haptics to false; it is still '
                '${settings.haptics}',
          );
          expect(
            find.descendant(
              of: find.byKey(_settingsButtonKey),
              matching: find.byIcon(Icons.volume_off_rounded),
            ),
            findsOneWidget,
            reason: 'lobby-sound-toggle must show the muted icon at once',
          );
        } finally {
          controller.dispose();
        }
      },
    );
  });

  // ==========================================================================
  // The effect is immediate, never cached, from the lobby entry too.
  // ==========================================================================
  group('rule 2: the effect is immediate, not cached, from the lobby', () {
    testWidgets(
      'muting with lobby-sound-toggle makes the next cue call neither '
      'haptic nor sound',
      // Catches: the service reading the flags once at construction
      // instead of at play() time, so a switch flipped from the lobby's
      // own entry would have no effect until the app restarts -- the same
      // caching mutation C-329's rule-5 test catches from the game screen,
      // proven here from the lobby's own entry point instead. C-523 D7: the
      // one toggle mutes both channels, so the old haptic-only call is gone.
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

        final (RoomController controller, _) = await _mountHostLobby(
          tester,
          settings: settings,
          service: service,
        );
        try {
          await tester.tap(find.byKey(_settingsButtonKey));
          await tester.pump();
          expect(
            settings.muted,
            isTrue,
            reason: 'fixture is broken: one tap on the toggle must mute',
          );

          service.play(FeedbackCue.yourTurn);
          await tester.runAsync(() => pumpEventQueue());
          await tester.pump();

          expect(
            calls.where((MethodCall c) => c.method == 'haptic').length,
            0,
            reason:
                'with the toggle muted from the lobby entry, the next cue '
                'must make no haptic call; got $calls',
          );
          expect(
            calls.where((MethodCall c) => c.method == 'sound').length,
            0,
            reason:
                'with the toggle muted from the lobby entry, the next cue '
                'must make no sound call; got $calls',
          );
        } finally {
          controller.dispose();
        }
      },
    );
  });
}
