// Device flow for contract C-547
// (work/ludo/orders/C-547-seat-moved-to-another-phone.md): a phone that
// relaunches into its seat, plays, and then has the seat taken by another
// phone must say so on the game screen. One case per locale.
//
// The flow is the real one: HomeScreen resumes the stored seat on its own,
// RoomRoute pushes GameScreen over a real RoomController, and the server side
// is a FakeTransport (test/net/fake_transport.dart) that answers the resume
// with a PLAYING room, then sends the unsolicited `error` BAD_SEAT_TOKEN and
// closes, exactly what connection.dart does to the older socket. Nothing
// here talks to a real server.
//
// The line is compared as the exact text the contract gives; the getter that
// would name it does not exist on the tree this was written for. Every pump
// is bounded: the game countdown never settles.
//
// Run with
//   flutter test integration_test/c547_takeover_test.dart -d flutter-tester
// A failure names the locale and what the screen drew instead.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/net/fake_transport.dart';

const String _enMoved = 'Your seat moved to another phone.';
const String _arMoved = 'انتقل مقعدك إلى هاتف آخر.';

const String _testUrl = 'wss://c547-device.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c547-device';

const Key _cardKey = Key('game-screen-connection-lost');
const Key _reconnectKey = Key('game-screen-reconnect-button');
const Key _leaveKey = Key('game-screen-leave-button');

int _serverIdSeq = 0;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c547-device-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _seat(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _playingRoom() => <String, Object?>{
  'code': _code,
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
  'rules': const <String, Object?>{
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': '7f3a9c1e5b2d4068',
  'client_seeds': '0:sam-seed|1:bob-seed',
  'seats': <Map<String, Object?>>[_seat(0, 'Host'), _seat(1, 'Guest')],
  'turn': const <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': 45000,
    'k': 0,
  },
  'winner': null,
  'seq': 3,
};

Future<void> _pumpBounded(WidgetTester tester, {int frames = 6}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _takeoverOnGameScreen(
  WidgetTester tester, {
  required Locale locale,
  required String moved,
}) async {
  final String id = 'takeover ${locale.languageCode}';
  SharedPreferences.setMockInitialValues(<String, Object>{
    'session.seat': <String>[_code, '0', _token],
    'session.seatSavedAt': DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch,
  });
  final List<FakeTransport> transports = <FakeTransport>[];
  final List<RoomController> controllers = <RoomController>[];
  RoomController factory() {
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async {
        final FakeTransport transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
    );
    controllers.add(controller);
    return controller;
  }

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
      home: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: factory,
        initialLinkReader: noInitialLink,
        linkStream: noLinkStream,
      ),
    ),
  );
  await _pumpBounded(tester);
  try {
    expect(
      transports,
      hasLength(1),
      reason: '$id: fixture: a fresh stored seat resumes on its own',
    );
    final Map<String, Object?> resume =
        jsonDecode(transports.single.sentRaw.last) as Map<String, Object?>;
    expect(resume['t'], 'resume', reason: '$id: fixture: first frame');
    transports.single.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': _token},
      ),
    );
    transports.single.pushText(
      _frame(type: 'room', re: resume['id']! as String, data: _playingRoom()),
    );
    await _pumpBounded(tester, frames: 3);
    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: '$id: fixture: the resume must show GameScreen mid-game',
    );

    // The newer socket resumed the same seat: error with no `re`, then 4004.
    transports.single.pushText(
      _frame(
        type: 'error',
        data: <String, Object?>{
          'code': 'BAD_SEAT_TOKEN',
          'message': 'seat taken over',
        },
      ),
    );
    await tester.pump();
    transports.single.endFromFarSide();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(GameScreen)),
    );
    final String saw =
        'phase ${controllers.last.phase}, errorCode '
        '${controllers.last.errorCode}, card '
        '${find.byKey(_cardKey).evaluate().length}, text "$moved" '
        '${find.text(moved).evaluate().length}, "${loc.lobbyConnectionLost}" '
        '${find.text(loc.lobbyConnectionLost).evaluate().length}, Reconnect '
        '${find.byKey(_reconnectKey).evaluate().length}, transports '
        '${transports.length}';
    expect(
      find.descendant(of: find.byKey(_cardKey), matching: find.text(moved)),
      findsOneWidget,
      reason:
          '$id: expected the takeover card to read "$moved"; saw $saw. '
          'reproduce: flutter test integration_test/c547_takeover_test.dart '
          '-d flutter-tester --plain-name "$id"',
    );
    expect(
      find.byIcon(Icons.phonelink_rounded),
      findsOneWidget,
      reason: '$id: expected the phonelink icon; saw $saw',
    );
    expect(
      find.text(loc.lobbyConnectionLost),
      findsNothing,
      reason: '$id: expected no connection-lost line; saw $saw',
    );
    expect(
      find.byKey(_reconnectKey),
      findsNothing,
      reason: '$id: expected no Reconnect button; saw $saw',
    );
    expect(
      find.byKey(_leaveKey),
      findsOneWidget,
      reason: '$id: expected the Leave button; saw $saw',
    );
    expect(
      transports,
      hasLength(1),
      reason: '$id: expected no second connection; saw $saw',
    );
  } finally {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    for (final RoomController controller in controllers) {
      controller.dispose();
    }
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('takeover en: a game screen mid-game that loses its seat to '
      'another phone shows the takeover card', (tester) async {
    await _takeoverOnGameScreen(
      tester,
      locale: const Locale('en'),
      moved: _enMoved,
    );
  });

  testWidgets('takeover ar: a game screen mid-game that loses its seat to '
      'another phone shows the takeover card', (tester) async {
    await _takeoverOnGameScreen(
      tester,
      locale: const Locale('ar'),
      moved: _arMoved,
    );
  });
}
