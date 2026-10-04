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

const String _testUrl = 'wss://scratch.invalid/ws';
int _idSeq = 0;
String _nextId() { _idSeq += 1; return 'scratch-id-${_idSeq.toString().padLeft(8, '0')}'; }
Map<String, Object?> _decode(String t) => jsonDecode(t) as Map<String, Object?>;
String _idOf(String t) => _decode(t)['id']! as String;

String _frame({required String type, String? re, Map<String, Object?> data = const {}, String? id}) =>
  jsonEncode({'v': 1, 't': type, 'id': id ?? _nextId(), 're': ?re, 'd': data});

Map<String, Object?> _seatJson(int seat, {String name = ''}) => {
  'seat': seat, 'name': name, 'connected': true, 'tokens': [-1,-1,-1,-1], 'client_seed': null, 'seed_origin': null,
};

Map<String, Object?> _roomJson({String state = 'FINISHED', int? winner}) => {
  'code': 'K7M2QP', 'state': state, 'host_seat': 0, 'players': 2,
  'rules': {'blocks': true, 'capture_bonus': true, 'turn_seconds': 45},
  'chain_commit': 'a' * 64, 'chain_index': 0, 'game_id': null, 'client_seeds': null,
  'seats': [_seatJson(0, name: 'Sam'), _seatJson(1, name: 'Bob')],
  'turn': null, 'winner': winner, 'rematch': null, 'seq': 1,
};

class _Connector {
  final List<FakeTransport> _q = [];
  void enqueue(FakeTransport t) => _q.add(t);
  Future<WireTransport> call(Uri url) async => _q.removeAt(0);
}

Widget _harness(Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: appSupportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void main() {
  testWidgets('repro: tap rematch, no reply, teardown dispose', (tester) async {
    print('STEP 1');
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

    final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
    print('STEP 2');
    await tester.runAsync(() => pumpEventQueue());
    print('STEP 3');
    await tester.pump();
    print('STEP 4');
    final String id = _idOf(transport.sentRaw.last);
    transport.pushText(_frame(type: 'seat_assigned', data: {'seat': 0, 'seat_token': 'tok-0'}));
    transport.pushText(_frame(type: 'room', re: id, data: _roomJson(state: 'FINISHED', winner: 0)));
    print('STEP 5');
    await future;
    print('STEP 6');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(GameScreen(controller: controller)));
    print('STEP 7');
    await tester.pump();
    print('STEP 8');

    expect(find.byKey(const Key('end-card-rematch')), findsOneWidget);
    print('STEP 9');
    await tester.tap(find.byKey(const Key('end-card-rematch')));
    print('STEP 10');
    await tester.pump();
    print('STEP 11');

    expect(
      transport.sentRaw.where((r) => _decode(r)['t'] == 'rematch').length,
      1,
    );
    print('STEP 12 DONE');
  });
}
