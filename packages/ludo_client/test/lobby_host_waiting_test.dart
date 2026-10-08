// C-274: a host whose room is not full has no disabled lobby-start-button.
// The seated/total count is the host's lobby-waiting line, the same Text a
// guest already gets. A full room still shows the enabled Start button and
// no lobby-waiting. Guests are unchanged.
//
// LobbyScreen is mounted the way test/lobby_screen_test.dart mounts it: a
// real RoomController over a FakeTransport, one mount per case. The
// start-with-present tap follows the wire sequence that button already
// has (set_players, then start_game once the reply shows a full room),
// which test/lobby_start_with_present_test.dart pins and lobby_screen_test
// does not. A tap does not send start_game until that reply lands.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const Key _startKey = Key('lobby-start-button');
const Key _startWithKey = Key('lobby-start-with-present-button');
const Key _waitingKey = Key('lobby-waiting');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'host-wait-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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

Map<String, Object?> _seatJson(int seat, {String name = 'Sam'}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

List<Map<String, Object?>> _seats(int count) =>
    List<Map<String, Object?>>.generate(
      count,
      (int i) => _seatJson(i, name: 'p$i'),
    );

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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport queued',
      );
    }
    return _queue.removeAt(0);
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

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

Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_harness(screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'LobbyScreen.initState must have sent create_room or join_room; '
        'sentRaw is empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = 'ABC234',
  int players = 4,
  int hostSeat = 0,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) async {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': seatForThisClient,
        'seat_token': 'tok-$seatForThisClient',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        code: code,
        players: players,
        hostSeat: hostSeat,
        seats: seats,
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets(
    'host, 2 of 4, en: no lobby-start-button; lobby-waiting reads the '
    'count; lobby-start-with-present-button is enabled; the count is said '
    'once',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      try {
        final String id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 4,
          seats: _seats(2),
        );

        expect(controller.isHost, isTrue);
        expect(controller.room!.seats.length, 2);
        expect(controller.room!.players, 4);

        final Finder waiting = find.byKey(_waitingKey);
        expect(
          waiting,
          findsOneWidget,
          reason:
              'C-274: a host short of full shows lobby-waiting, the same '
              'Text a guest gets',
        );
        const String count = 'Waiting for players (2 of 4)';
        final BuildContext context = tester.element(find.byType(LobbyScreen));
        final AppLocalizations loc = AppLocalizations.of(context);
        expect(
          loc.lobbyWaitingForPlayers(2, 4),
          count,
          reason:
              'fixture: en lobbyWaitingForPlayers(2, 4) is the count '
              'sentence this case reads off the line',
        );
        final Text waitingText = tester.widget<Text>(waiting);
        expect(
          waitingText.data,
          count,
          reason:
              'C-274: lobby-waiting must read "$count"; got '
              '"${waitingText.data}"',
        );
        expect(
          find.byKey(_startKey),
          findsNothing,
          reason:
              'C-274: a host short of full has no lobby-start-button, '
              'disabled or otherwise',
        );

        final Finder startWith = find.byKey(_startWithKey);
        expect(
          startWith,
          findsOneWidget,
          reason:
              'C-274: lobby-start-with-present-button stays for a host in '
              'LOBBY with 2 or more seated and the room not full',
        );
        final ElevatedButton startWithButton = tester.widget<ElevatedButton>(
          startWith,
        );
        expect(
          startWithButton.onPressed,
          isNotNull,
          reason:
              'C-274: lobby-start-with-present-button is enabled before '
              'anyone taps it',
        );
        expect(
          find.text(count),
          findsOneWidget,
          reason:
              'C-274: "$count" is said once. A second Text with that '
              'sentence means the count is on the line and somewhere else',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('host, 1 of 4: no lobby-start-button, no '
      'lobby-start-with-present-button, lobby-waiting reads the count', (
    WidgetTester tester,
  ) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    try {
      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _seats(1),
      );

      expect(controller.isHost, isTrue);
      expect(controller.room!.seats.length, 1);
      expect(controller.room!.players, 4);

      expect(
        find.byKey(_startKey),
        findsNothing,
        reason: 'C-274: a host with 1 of 4 seated has no lobby-start-button',
      );
      expect(
        find.byKey(_startWithKey),
        findsNothing,
        reason:
            'lobby-start-with-present-button stays absent with only one '
            'seat filled',
      );
      final Finder waiting = find.byKey(_waitingKey);
      expect(
        waiting,
        findsOneWidget,
        reason: 'C-274: a host with 1 of 4 seated shows lobby-waiting',
      );
      const String count = 'Waiting for players (1 of 4)';
      final Text waitingText = tester.widget<Text>(waiting);
      expect(
        waitingText.data,
        count,
        reason:
            'C-274: lobby-waiting must read "$count"; got '
            '"${waitingText.data}"',
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets(
    'host, 2 of 2: lobby-start-button is enabled and reads Start game, '
    'and lobby-waiting is absent',
    (WidgetTester tester) async {
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = _newController(connector);
      try {
        final String id = await _mountAndCaptureRequest(
          tester,
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 2,
          ),
          transport,
        );
        await _resolveConnected(
          tester,
          transport,
          id,
          seatForThisClient: 0,
          hostSeat: 0,
          players: 2,
          seats: _seats(2),
        );

        expect(controller.isHost, isTrue);
        expect(
          controller.room!.seats.length,
          controller.room!.players,
          reason: 'fixture: 2 of 2 is a full room',
        );

        final Finder start = find.byKey(_startKey);
        expect(
          start,
          findsOneWidget,
          reason: 'a full room still shows lobby-start-button to the host',
        );
        final ElevatedButton button = tester.widget<ElevatedButton>(start);
        expect(
          button.onPressed,
          isNotNull,
          reason: 'a full room enables lobby-start-button',
        );
        final BuildContext context = tester.element(find.byType(LobbyScreen));
        final AppLocalizations loc = AppLocalizations.of(context);
        expect(loc.lobbyStartButton, 'Start game');
        final Text label = tester.widget<Text>(
          find.descendant(of: start, matching: find.byType(Text)),
        );
        expect(
          label.data,
          'Start game',
          reason:
              'a full room labels lobby-start-button "Start game", not the '
              'count; got "${label.data}"',
        );
        expect(
          find.byKey(_waitingKey),
          findsNothing,
          reason: 'a full room shows no lobby-waiting to the host',
        );
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('guest, 2 of 4: lobby-waiting reads the count, and neither start '
      'button is shown', (WidgetTester tester) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    try {
      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.join,
          code: 'ABC234',
          playerName: 'Amir',
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 1,
        hostSeat: 0,
        players: 4,
        seats: _seats(2),
      );

      expect(controller.isHost, isFalse);
      expect(controller.room!.seats.length, 2);
      expect(controller.room!.players, 4);

      final Finder waiting = find.byKey(_waitingKey);
      expect(waiting, findsOneWidget);
      final Text waitingText = tester.widget<Text>(waiting);
      expect(
        waitingText.data,
        'Waiting for players (2 of 4)',
        reason:
            'a guest short of full still reads the count on '
            'lobby-waiting; got "${waitingText.data}"',
      );
      expect(
        find.byKey(_startKey),
        findsNothing,
        reason: 'a guest has no lobby-start-button',
      );
      expect(
        find.byKey(_startWithKey),
        findsNothing,
        reason: 'a guest has no lobby-start-with-present-button',
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets('ar host, 2 of 4: lobby-waiting reads '
      'AppLocalizations.lobbyWaitingForPlayers, and lobby-start-button is '
      'absent', (WidgetTester tester) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    try {
      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'سام',
          players: 4,
        ),
        transport,
        locale: const Locale('ar'),
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'سام'),
          _seatJson(1, name: 'أمير'),
        ],
      );

      expect(controller.isHost, isTrue);
      expect(controller.room!.seats.length, 2);
      expect(controller.room!.players, 4);

      final Finder waiting = find.byKey(_waitingKey);
      expect(
        waiting,
        findsOneWidget,
        reason:
            'C-274: a host short of full shows lobby-waiting in '
            'Locale(ar) too',
      );
      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      final Text waitingText = tester.widget<Text>(waiting);
      expect(
        waitingText.data,
        loc.lobbyWaitingForPlayers(2, 4),
        reason:
            'C-274: lobby-waiting must read this tree\'s own '
            'AppLocalizations.lobbyWaitingForPlayers(2, 4); got '
            '"${waitingText.data}"',
      );
      expect(
        find.byKey(_startKey),
        findsNothing,
        reason:
            'C-274: a host short of full has no lobby-start-button in '
            'Locale(ar) either',
      );
    } finally {
      controller.dispose();
    }
  });

  testWidgets('host, 2 of 4: tapping lobby-start-with-present-button sends '
      'set_players then start_game, exactly one of each', (
    WidgetTester tester,
  ) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    try {
      final String id = await _mountAndCaptureRequest(
        tester,
        LobbyScreen(
          controller: controller,
          action: LobbyAction.create,
          playerName: 'Sam',
          players: 4,
        ),
        transport,
      );
      await _resolveConnected(
        tester,
        transport,
        id,
        seatForThisClient: 0,
        hostSeat: 0,
        players: 4,
        seats: _seats(2),
      );

      final Finder finder = find.byKey(_startWithKey);
      expect(
        finder,
        findsOneWidget,
        reason:
            'fixture: the 2 of 4 host must show '
            'lobby-start-with-present-button before it can be tapped',
      );

      final int beforeCount = transport.sentRaw.length;
      await tester.tap(finder);
      await tester.pump();

      final List<String> sentAfterTap = transport.sentRaw
          .skip(beforeCount)
          .toList();
      expect(
        sentAfterTap,
        hasLength(1),
        reason:
            'tapping must send exactly one frame before any reply '
            'arrives; got $sentAfterTap',
      );
      expect(_typeOf(sentAfterTap.single), 'set_players');
      expect(
        _dataOf(sentAfterTap.single),
        <String, Object?>{'players': 2},
        reason:
            'set_players must carry count == room.seats.length == 2; '
            'got ${_dataOf(sentAfterTap.single)}',
      );

      final String setPlayersId = _idOf(sentAfterTap.single);
      transport.pushText(
        _frame(
          type: 'room',
          re: setPlayersId,
          data: _roomJson(players: 2, hostSeat: 0, seats: _seats(2), seq: 2),
        ),
      );
      await tester.pump();
      await tester.pump();

      final List<String> sentAfterReply = transport.sentRaw
          .skip(beforeCount + 1)
          .toList();
      expect(
        sentAfterReply,
        hasLength(1),
        reason:
            'once set_players answers with a now-full room, exactly one '
            'further frame must be sent (start_game); got $sentAfterReply',
      );
      expect(_typeOf(sentAfterReply.single), 'start_game');
      expect(
        transport.sentRaw.where((String s) => _typeOf(s) == 'set_players'),
        hasLength(1),
      );
      expect(
        transport.sentRaw.where((String s) => _typeOf(s) == 'start_game'),
        hasLength(1),
        reason: 'exactly one start_game must be sent',
      );

      final String startId = _idOf(sentAfterReply.single);
      transport.pushText(
        _frame(
          type: 'game_started',
          re: startId,
          data: <String, Object?>{
            'turn': 0,
            'game_id': 'a' * 16,
            'client_seeds': '0:seed',
            'seq': 3,
          },
        ),
      );
      await tester.pump();
    } finally {
      controller.dispose();
    }
  });
}
