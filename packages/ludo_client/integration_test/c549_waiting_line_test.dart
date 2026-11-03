// Proof for contract C-549 D1 under the integration binding: a game screen
// over a real RoomController on FakeTransport, the connection drops, and once
// the reconnecting row has been up for about 5 s the slow line is on screen
// with the contract's exact text, in English and in Arabic.
//
// Run: flutter test integration_test/c549_waiting_line_test.dart -d flutter-tester
//
// The integration binding is the live one: pump(Duration) waits that long on
// the real clock, so the case never sleeps on its own, and every pump and
// frame adds real elapsed time. That makes the exact 3.9 s / 4.1 s boundary
// unassertable here (it is proved under fake time in test/c549_test.dart);
// this file asserts a window: no slow line at about 3.0 s of pumped time, the
// exact slow line by about 5.0 s. The automatic attempt that fires
// at 1 s is held open at the connector, so the row stays up through the flip
// from "timer pending" to "attempt in flight", and the count is from the
// row's first mount, not from the flip. Nothing here uses pumpAndSettle: the
// turning mark repeats forever.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import '../test/net/fake_transport.dart';

const String _testUrl = 'wss://c549-integration.invalid/ws';

const Key _slowKey = Key('waiting-line-slow');
const Key _lostKey = Key('game-screen-connection-lost');
const Key _reconnectingKey = Key('game-screen-reconnecting');

const String _slowEn = 'Taking longer than usual. Check your internet.';
const String _slowAr =
    'يستغرق الأمر وقتاً أطول من المعتاد. تحقّق من اتصال الإنترنت.';

int _serverIdSeq = 0;

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c549-it-id-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _playingRoom() => <String, Object?>{
  'code': 'ABC234',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[_seatJson(0, 'Sam'), _seatJson(1, 'Bob')],
  'turn': <String, Object?>{
    'seat': 0,
    'phase': 'await_roll',
    'deadline_ms': 45000,
    'k': 0,
  },
  'winner': null,
  'seq': 1,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    final String tag = locale.languageCode;
    final String want = tag == 'ar' ? _slowAr : _slowEn;
    final String id =
        'C-549 D1 $tag: game screen, connection dropped, no slow line at '
        'about 3.0 s, the exact slow line by about 5.0 s';

    testWidgets(id, (tester) async {
      final String reproduce =
          'reproduce: cd packages/ludo_client && flutter test '
          'integration_test/c549_waiting_line_test.dart -d flutter-tester '
          '--plain-name "$id"';

      final FakeTransport first = FakeTransport();
      final List<Object> queue = <Object>[first];
      final List<Completer<WireTransport>> holds = <Completer<WireTransport>>[];
      Future<WireTransport> connect(Uri url) async {
        final Object next = queue.removeAt(0);
        if (next is Completer<WireTransport>) {
          return next.future;
        }
        return next as FakeTransport;
      }

      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connect,
        autoReconnectDelays: const <Duration>[
          Duration(seconds: 1),
          Duration(seconds: 2),
        ],
      );
      try {
        final Future<void> created = controller.createRoom(
          name: 'Sam',
          players: 2,
        );
        await tester.pump();
        await tester.pump();
        final String createId = _decode(first.sentRaw.last)['id']! as String;
        first.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        first.pushText(
          _frame(type: 'room', re: createId, data: _playingRoom()),
        );
        await created;

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
            home: GameScreen(controller: controller),
          ),
        );
        await tester.pump();
        expect(controller.phase, RoomPhase.connected);

        // The first automatic attempt will be held in flight.
        final Completer<WireTransport> hold = Completer<WireTransport>();
        holds.add(hold);
        queue.add(hold);
        first.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          controller.autoReconnectPending,
          isTrue,
          reason:
              'fixture is broken: the drop must leave an attempt pending. '
              '$reproduce',
        );
        expect(
          find.byKey(_reconnectingKey),
          findsOneWidget,
          reason:
              'expected the reconnecting row once the drop is seen. '
              '$reproduce',
        );
        expect(
          find.byKey(_slowKey),
          findsNothing,
          reason:
              'expected no slow line the moment the row first appears. '
              '$reproduce',
        );

        // 1 s: the timer fires and the attempt is in flight (the flip).
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(
          controller.phase,
          RoomPhase.connecting,
          reason:
              'fixture is broken: the attempt must be in flight. $reproduce',
        );
        expect(
          find.byKey(_reconnectingKey),
          findsOneWidget,
          reason: 'expected the row to survive the flip. $reproduce',
        );

        // Window, not a boundary: this binding is live, so every pump and
        // frame costs real time on top of the pumped duration and a 100 ms
        // window around 4 s cannot be asserted here. The exact 3.9 s / 4.1 s
        // boundary is proved under fake time in test/c549_test.dart. Here:
        // about 3.0 s of pumped time is well inside the first 4 s, and 5.0 s
        // is well past it.
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.byKey(_slowKey),
          findsNothing,
          reason:
              'expected no slow line at about 3.0 s of pumped time after the '
              'row first appeared (the live binding adds real time to every '
              'pump, so the window is 3.0 s against the 4 s rule, not the '
              'exact boundary); it is in the tree. $reproduce',
        );
        expect(find.text(_slowEn), findsNothing, reason: reproduce);
        expect(find.text(_slowAr), findsNothing, reason: reproduce);

        await tester.pump(const Duration(seconds: 2));
        expect(
          find.byKey(_slowKey),
          findsOneWidget,
          reason:
              'expected the slow line (Key waiting-line-slow) by about 5.0 s '
              'of pumped time after the row first appeared (4 s rule plus the '
              'real time the live binding adds); found none. $reproduce',
        );
        expect(
          find.text(want),
          findsOneWidget,
          reason:
              'expected the exact slow text "$want" by about 5.0 s. '
              '$reproduce',
        );
        expect(
          find.descendant(
            of: find.byKey(_lostKey),
            matching: find.byKey(_slowKey),
          ),
          findsOneWidget,
          reason:
              'the slow line must sit inside game-screen-connection-lost. '
              '$reproduce',
        );
      } finally {
        for (final Completer<WireTransport> hold in holds) {
          if (!hold.isCompleted) {
            hold.complete(FakeTransport());
          }
        }
        await tester.pump();
        controller.dispose();
      }
    });
  }
}
