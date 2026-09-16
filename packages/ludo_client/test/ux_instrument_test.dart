// Headless walk of the screens a player actually reaches. Captures PNGs,
// measures tap targets, and evaluates Flutter accessibility guidelines.
// Failures of a guideline are printed as measurements; the test still
// passes if the widgets are present, so a first-run baseline can exist
// before those numbers move.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show LudoApp, appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://ux-instrument.invalid/ws';
const Size _phone = Size(390, 844);
const double _androidMin = 48;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'ux-id-${_serverIdSeq.toString().padLeft(4, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _seatJson(int seat, {String name = ''}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  required String code,
  required int players,
  required List<Map<String, Object?>> seats,
  required int seq,
  String state = 'LOBBY',
  Map<String, Object?>? turn,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': 0,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': state == 'PLAYING' ? 'g' * 16 : null,
  'client_seeds': state == 'PLAYING' ? '0:seed' : null,
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

class _Factory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }
}

Directory _shotDir() {
  final String fromEnv = Platform.environment['UX_SHOT_DIR'] ?? '';
  if (fromEnv.isNotEmpty) {
    return Directory(fromEnv);
  }
  return Directory('${Directory.current.path}/../../.uxprogram/shots/baseline');
}

Future<void> _saveShot(WidgetTester tester, String name) async {
  final Directory dir = _shotDir()..createSync(recursive: true);
  final Finder boundary = find.byType(RepaintBoundary).first;
  final RenderRepaintBoundary render = tester.renderObject(boundary);
  await tester.runAsync(() async {
    final ui.Image image = await render.toImage(pixelRatio: 2.0);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (bytes == null) {
      fail('screenshot $name produced no PNG bytes');
    }
    File('${dir.path}/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    print('SHOT ${dir.path}/$name.png ${bytes.lengthInBytes} bytes');
  });
}

void _printSize(WidgetTester tester, Key key, String label) {
  final Finder finder = find.byKey(key);
  if (finder.evaluate().isEmpty) {
    print('SIZE $label MISSING');
    return;
  }
  final Size size = tester.getSize(finder);
  final bool ok =
      size.width + 0.01 >= _androidMin && size.height + 0.01 >= _androidMin;
  print(
    'SIZE $label ${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)} '
    'min=$_androidMin pass=$ok',
  );
}

Future<void> _printGuideline(
  WidgetTester tester,
  AccessibilityGuideline guideline,
  String name,
) async {
  final Evaluation result = await guideline.evaluate(tester);
  print(
    'GUIDELINE $name passed=${result.passed} reason=${result.reason ?? "none"}',
  );
}

void _phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _homeApp(RoomControllerFactory factory) {
  return RepaintBoundary(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(onToggleLocale: () {}, controllerFactory: factory),
    ),
  );
}

void main() {
  testWidgets('home screen launches, measures, and captures both locales', (
    tester,
  ) async {
    _phoneSurface(tester);
    await tester.pumpWidget(const RepaintBoundary(child: LudoApp()));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('create-room-button')), findsOneWidget);
    expect(find.byKey(const Key('join-room-button')), findsOneWidget);

    _printSize(tester, const Key('create-room-button'), 'create-room');
    _printSize(tester, const Key('join-room-button'), 'join-room');
    _printSize(tester, const Key('locale-toggle-button'), 'locale-toggle');
    _printSize(tester, const Key('home-name-field'), 'name-field');
    _printSize(tester, const Key('room-code-field'), 'code-field');
    _printSize(tester, const Key('home-players-selector'), 'players-selector');

    await _printGuideline(
      tester,
      androidTapTargetGuideline,
      'androidTapTarget',
    );
    await _printGuideline(tester, iOSTapTargetGuideline, 'iOSTapTarget');
    await _printGuideline(
      tester,
      labeledTapTargetGuideline,
      'labeledTapTarget',
    );
    await _printGuideline(tester, textContrastGuideline, 'textContrast');

    await _saveShot(tester, '01-home-en');

    await tester.tap(find.byKey(const Key('locale-toggle-button')));
    await tester.pumpAndSettle();
    expect(
      Directionality.of(tester.element(find.byType(HomeScreen))),
      TextDirection.rtl,
    );
    await _saveShot(tester, '02-home-ar');

    print('PROBE: PASS home');
  });

  testWidgets('create-room walk reaches lobby then game', (tester) async {
    _phoneSurface(tester);
    final _Factory factory = _Factory();
    await tester.pumpWidget(_homeApp(factory.call));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('home-name-field')), 'Priya');
    await tester.tap(find.byKey(const Key('create-room-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(factory.controllers, hasLength(1));
    final RoomController controller = factory.controllers.single;
    final FakeTransport transport = factory.transports.single;
    addTearDown(controller.dispose);

    final String createId = _idOf(
      transport.sentRaw.singleWhere((s) => _typeOf(s) == 'create_room'),
    );
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-host'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: createId,
        data: _roomJson(
          code: 'PLAY42',
          players: 2,
          seats: <Map<String, Object?>>[_seatJson(0, name: 'Priya')],
          seq: 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    transport.pushText(
      _frame(
        type: 'player_joined',
        data: <String, Object?>{'seat': 1, 'name': 'Karim', 'seq': 2},
      ),
    );
    await tester.pump();

    expect(find.byType(LobbyScreen), findsOneWidget);
    expect(find.byKey(const Key('lobby-room-code')), findsOneWidget);
    _printSize(tester, const Key('lobby-copy-link-button'), 'copy-link');
    _printSize(tester, const Key('lobby-copy-code-button'), 'copy-code');
    _printSize(tester, const Key('lobby-start-button'), 'start-game');
    await _saveShot(tester, '03-lobby-en');

    await tester.tap(find.byKey(const Key('lobby-start-button')));
    await tester.pump();
    final String startId = _idOf(
      transport.sentRaw.singleWhere((s) => _typeOf(s) == 'start_game'),
    );
    transport.pushText(
      _frame(
        type: 'game_started',
        re: startId,
        data: <String, Object?>{
          'turn': 0,
          'game_id': 'e' * 16,
          'client_seeds': '0:seed',
          'seq': 3,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(GameScreen), findsOneWidget);
    _printSize(tester, const Key('game-screen-roll-button'), 'roll');
    _printSize(tester, const Key('game-screen-appbar-leave'), 'leave');
    await _saveShot(tester, '04-game-en');

    print('PROBE: PASS create-room walk');
  });
}
