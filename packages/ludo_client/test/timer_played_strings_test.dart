// C1 of work/ludo/orders/C-426-timer-played-says-so.md, split out of
// test/timer_played_notice_test.dart (see that file's own header) because
// C1's own job is exactly "shows the en and the ar text", which this
// order's Goal section asks to be proved "through AppLocalizations lookups
// once the keys exist" -- `loc.gameTimerPlayedMine`. Neither getter exists
// on this tree (grepped lib/l10n/app_en.arb: no `gameTimerPlayed*` key at
// all), so every reference to it below is a compile-time error for this
// whole file, and this whole file is red at compile today, for exactly
// that reason, per this order's own instruction: "until then the cases are
// red at compile or lookup". Nothing else in this file is red for a
// different reason, and nothing here is weakened to make it compile --
// the getter is used exactly as it will be once order 428 generates it.
//
// GameScreen is mounted the same way test/timer_played_notice_test.dart
// mounts it; every helper below is copied by hand from that file (which
// is itself copied by hand from test/automove_says_so_test.dart and
// test/talkback_announce_test.dart), per this project's own standing
// instruction never to import across test files.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://timer-played-strings-test.invalid/ws';

const Key _mineKey = Key('game-timer-played-notice');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'timer-played-strings-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
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
  'seats': seats,
  'turn': turn,
  'winner': null,
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

Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
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
      data: _roomJson(players: players, seats: seats, turn: turn, seq: 1),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

void main() {
  // ==========================================================================
  // C1 (D3, D9): my seat, rolled with by: timer, shows the en and the ar
  // text exactly.
  // ==========================================================================
  group('C1 (D3, D9): the mine notice shows the pinned en/ar text', () {
    for (final String code in const <String>['en', 'ar']) {
      testWidgets('$code: game-timer-played-notice reads exactly '
          'loc.gameTimerPlayedMine', (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam', tokens: const <int>[2, -1, -1, -1]),
            _seatJson(1, name: 'Bob'),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller, locale: Locale(code));

        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 0,
              'value': 5,
              'legal': const <int>[0],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'a' * 64,
              'by': 'timer',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        final AppLocalizations loc = _locOf(tester);

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason:
              'D3 ($code): a rolled for my own seat carrying by: timer '
              'must show game-timer-played-notice',
        );
        final String shown =
            tester.widget<Text>(find.byKey(_mineKey)).data ?? '';
        expect(
          shown,
          loc.gameTimerPlayedMine,
          reason:
              'D9 ($code): game-timer-played-notice must read exactly '
              'loc.gameTimerPlayedMine ("${loc.gameTimerPlayedMine}"); '
              'got "$shown"',
        );
      });
    }
  });
}
