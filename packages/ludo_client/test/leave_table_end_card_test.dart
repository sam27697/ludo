// Tests for contract C-316, docs/PROTOCOL.md section 18, rules 2-5: the
// end card after a friend leaves, removal by a forced start, offline on the
// end card, and the game_log fetch gate. Cut from integrate/run83 at
// 8208945; the implementation (order 316) lands in lib/ in parallel, in a
// tree this file's author has not opened.
//
// AppLocalizations on this tree has none of `endLeft`, `endEveryoneLeft`,
// `endOffline` or `homeRemovedNotice` (grep confirms no match anywhere
// under lib/). Referencing any of those getters would not compile, so this
// file never does: every literal the contract's own string table gives --
// `{names} left the table` / `غادر الطاولة: {names}`, `Everyone else left
// the table` / `غادر الجميع الطاولة`, `No connection right now` / `لا يوجد
// اتصال الآن`, `The next game started without you` / `بدأت الجولة التالية
// بدونك` -- is copied in as a plain Dart string constant below and compared
// against whatever text the card (or HomeScreen) is actually showing. A
// file that compiles cleanly and is red on a missing key, rather than a
// file that does not compile at all, is this order's own later correction
// to its "how to run" section (reported in ORDER-317-REPORT.md).
//
// GameScreen, LobbyScreen and HomeScreen are driven the same way
// test/rematch_client_test.dart, test/finished_card_survives_rematch_test
// .dart, test/end_card_game_log_test.dart and
// test/game_screen_new_room_button_test.dart drive them: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only), with the small connector/frame/blob helpers copied from
// those files rather than imported, per this order's own instruction. One
// mount per case.
//
// Ambiguities found while writing this file, reported rather than invented
// around:
//
//   1. Rule 3 names GameScreenResult.removed as the new pop result, but
//      that enum member does not exist on this tree (GameScreenResult has
//      only `newTable`), so no test here names it. Every rule 3 case below
//      is written against the externally observable behaviour instead: the
//      route pops back to HomeScreen and HomeScreen shows
//      home-removed-notice. That is everything a player can see, and it is
//      everything the order's own case list asks this file to prove.
//   2. Rule 5's own text also describes the complementary half of the
//      gate -- "discarded only when a new game has started since" -- which
//      is not in this order's case list for rule 5 (only the race case is).
//      GameScreen._onFrame already clears _fetchedStats on a `game_started`
//      naming a new game_id (_resetForNewGame), a path this order does not
//      touch, so that half is not re-proved here.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://leave-table-end-card-test.invalid/ws';

// --- the contract's own string table (docs/ludo/orders/C-316), copied in
// --- as plain literals; see this file's header note 1 for why ------------

const String _enEndLeftTemplate = '{names} left the table';
const String _arEndLeftTemplate = 'غادر الطاولة: {names}';
const String _enEndEveryoneLeft = 'Everyone else left the table';
const String _arEndEveryoneLeft = 'غادر الجميع الطاولة';
const String _enEndOffline = 'No connection right now';
const String _enHomeRemovedNotice = 'The next game started without you';

String _expectedEndLeft(Locale locale, List<String> names) {
  final String sep = locale.languageCode == 'ar' ? '، ' : ', ';
  final String template = locale.languageCode == 'ar'
      ? _arEndLeftTemplate
      : _enEndLeftTemplate;
  return template.replaceFirst('{names}', names.join(sep));
}

String _expectedEveryoneLeft(Locale locale) =>
    locale.languageCode == 'ar' ? _arEndEveryoneLeft : _enEndEveryoneLeft;

// --- small JSON/frame helpers, copied from the sibling suites' idiom ------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'leave-end-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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
  required String name,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  String code = 'LV3END',
  required String state,
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  String? clientSeeds,
  String? verifyUrl,
  Map<String, Object?>? rematch,
  required int seq,
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
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'verify_url': ?verifyUrl,
  'rematch': ?rematch,
  'seq': seq,
};

Map<String, Object?> _finishedTurnJson() => <String, Object?>{
  'seat': 0,
  'phase': 'finished',
  'deadline_ms': 0,
  'k': 8,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued for $url; the test fixture is broken, not the code under '
        'test',
      );
    }
    return _queue.removeAt(0);
  }
}

/// Connects into a PLAYING room first and then pushes an unsolicited `room`
/// push into FINISHED, the way a real game actually ends (and the way
/// RoomController._recordLastFinished is reached: RoomController._openFresh,
/// behind createRoom/joinRoom, unconditionally clears lastFinished on its
/// own success, on the view that a freshly created or joined room cannot
/// already have a finished game behind it -- a FINISHED create_room/
/// join_room reply itself, tried first, left lastFinished null and every
/// rule 2 assertion below failing on that null check rather than on the
/// behaviour this file means to measure). Mirrors
/// test/game_screen_new_room_button_test.dart's own `_connectFinished`,
/// extended with the live push so lastFinished is populated realistically.
Future<(RoomController, FakeTransport, _Connector)> _connectFinished(
  WidgetTester tester, {
  required int mySeat,
  required List<Map<String, Object?>> seats,
  required int winner,
  String? verifyUrl,
  int players = 2,
  int hostSeat = 0,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final String myName =
      seats.firstWhere((Map<String, Object?> s) => s['seat'] == mySeat)['name']!
          as String;
  final Future<void> future = controller.createRoom(
    name: myName,
    players: players,
  );
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
        state: 'PLAYING',
        hostSeat: hostSeat,
        players: players,
        seats: seats,
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
        seq: 1,
      ),
    ),
  );
  await future;

  await _pushRoom(
    tester,
    transport,
    _roomJson(
      state: 'FINISHED',
      hostSeat: hostSeat,
      players: players,
      seats: seats,
      turn: _finishedTurnJson(),
      winner: winner,
      verifyUrl: verifyUrl,
      seq: 2,
    ),
  );
  return (controller, transport, connector);
}

/// Resumes straight into a FINISHED room with an empty local transcript
/// (the app-kill path), the way test/end_card_game_log_test.dart's own
/// `_mountResume` + `_answerResume` reach the fetch gate, so stats start
/// incomplete and the card asks for game_log once.
Future<(RoomController, FakeTransport, _Connector)> _resumeFinished(
  WidgetTester tester, {
  required int mySeat,
  required List<Map<String, Object?>> seats,
  required int winner,
  required String gameId,
  String? verifyUrl,
  int players = 2,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.resumeRoom(
    code: 'LV3END',
    seat: mySeat,
    seatToken: 'tok-resume-$mySeat',
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': mySeat,
        'seat_token': 'tok-resume-$mySeat',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: 'FINISHED',
        players: players,
        seats: seats,
        turn: _finishedTurnJson(),
        winner: winner,
        gameId: gameId,
        clientSeeds: '0:seed',
        verifyUrl: verifyUrl,
        seq: 6,
      ),
    ),
  );
  await future;
  return (controller, transport, connector);
}

Future<void> _pushRoom(
  WidgetTester tester,
  FakeTransport transport,
  Map<String, Object?> room, {
  String? re,
}) async {
  transport.pushText(_frame(type: 'room', re: re, data: room));
  await tester.pump();
  await tester.pump();
}

Future<void> _pushPlayerLeft(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int seq,
  int? hostSeat,
}) async {
  transport.pushText(
    _frame(
      type: 'player_left',
      data: <String, Object?>{'seat': seat, 'seq': seq, 'host_seat': ?hostSeat},
    ),
  );
  await tester.pump();
  await tester.pump();
}

// --- widget harness, copied from the sibling suites' own ------------------

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

// --- blob scanning, copied from test/rematch_client_test.dart's own -------

void _writeBlob(StringBuffer out, String? value) {
  if (value != null && value.trim().isNotEmpty) {
    out.writeln(value);
  }
}

String _blobUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  final Finder descendants = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget _) => true),
  );
  for (final Element element in <Element>[
    tester.element(root),
    ...descendants.evaluate(),
  ]) {
    final Widget widget = element.widget;
    if (widget is Text) {
      _writeBlob(out, widget.data);
      _writeBlob(out, widget.textSpan?.toPlainText());
    } else if (widget is RichText) {
      _writeBlob(out, widget.text.toPlainText());
    }
  }
  return out.toString();
}

bool _tileShowsNumber(WidgetTester tester, Key key, int expected) {
  final Finder tile = find.byKey(key);
  if (tile.evaluate().isEmpty) {
    return false;
  }
  final String blob = _blobUnder(tester, tile);
  return RegExp('(?<!\\d)$expected(?!\\d)').hasMatch(blob);
}

// --- url_launcher method channel spy, copied from
// --- test/finished_card_survives_rematch_test.dart's own ------------------

const List<String> _urlLauncherChannels = <String>[
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/url_launcher_macos',
  'plugins.flutter.io/url_launcher_linux',
  'plugins.flutter.io/url_launcher_windows',
  'plugins.flutter.io/url_launcher_web',
  'plugins.flutter.io/url_launcher_android',
  'plugins.flutter.io/url_launcher_ios',
];

List<MethodCall> _listenUrlLaunches(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> handler(MethodCall call) async {
    calls.add(call);
    return true;
  }

  for (final String name in _urlLauncherChannels) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return calls;
}

bool _containsUrl(Object? value, String url) {
  if (value is String) {
    return value.contains(url);
  }
  if (value is Map) {
    return value.values.any((Object? item) => _containsUrl(item, url));
  }
  if (value is Iterable) {
    return value.any((Object? item) => _containsUrl(item, url));
  }
  return false;
}

bool _launched(List<MethodCall> calls, String url) {
  return calls.any(
    (MethodCall call) =>
        _containsUrl(call.arguments, url) || call.method.contains(url),
  );
}

int _sentOfType(FakeTransport transport, String type) {
  var count = 0;
  for (final String raw in transport.sentRaw) {
    if (_typeOf(raw) == type) {
      count += 1;
    }
  }
  return count;
}

// --- rule 2 fixtures --------------------------------------------------

const Key _endLeftKey = Key('end-card-left');
const Key _rematchKey = Key('end-card-rematch');
const Key _rematchAskKey = Key('end-card-rematch-ask');
const Key _rematchWaitingKey = Key('end-card-rematch-waiting');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _staleTableKey = Key('game-screen-stale-table');
const Key _offlineKey = Key('end-card-offline');
const Key _rematchGoneKey = Key('end-card-rematch-gone');
const Key _winnerTitleKey = Key('game-screen-winner');

void main() {
  group('rule 2: departed seats on the end card', () {
    for (final Locale locale in <Locale>[
      const Locale('en'),
      const Locale('ar'),
    ]) {
      testWidgets(
        '${locale.languageCode}: FINISHED room of 3, one other seat leaves: '
        'end-card-left names them, Play again stays, winner unchanged',
        (WidgetTester tester) async {
          final List<Map<String, Object?>> seats = <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
            _seatJson(2, name: 'Ken'),
          ];
          final (
            RoomController controller,
            FakeTransport transport,
            _,
          ) = await _connectFinished(
            tester,
            mySeat: 1,
            seats: seats,
            winner: 0,
            players: 3,
          );
          addTearDown(controller.dispose);
          await _mount(tester, controller, locale: locale);
          final AppLocalizations loc = _locOf(tester);

          // Mutation this catches: an implementation that computes
          // departed seats from the live room alone (there is nothing to
          // compute once the seat is already gone) instead of diffing
          // lastFinished.seats against room.seats.
          await _pushPlayerLeft(tester, transport, seat: 2, seq: 3);

          expect(controller.room!.seats.map((s) => s.seat), <int>[
            0,
            1,
          ], reason: 'fixture: seat 2 must be gone from the live room');
          expect(controller.lastFinished!.seats.map((s) => s.seat), <int>[
            0,
            1,
            2,
          ], reason: 'fixture: lastFinished must still hold all 3 seats');

          final Finder left = find.byKey(_endLeftKey);
          expect(
            left,
            findsOneWidget,
            reason:
                'rule 2: a departed seat (Ken) with seat 1 (this device) '
                'still present must show end-card-left',
          );
          final String expected = _expectedEndLeft(locale, <String>['Ken']);
          final String blob = _blobUnder(tester, left);
          expect(
            blob.contains(expected),
            isTrue,
            reason:
                'rule 2: end-card-left must read endLeft("Ken") == '
                '"$expected"; blob was "$blob"',
          );

          final Finder rematch = find.byKey(_rematchKey);
          expect(
            rematch,
            findsOneWidget,
            reason: 'rule 2: Play again must stay when someone else left',
          );
          final Widget rematchWidget = tester.widget(rematch);
          final VoidCallback? onPressed = rematchWidget is ButtonStyleButton
              ? rematchWidget.onPressed
              : null;
          expect(
            onPressed,
            isNotNull,
            reason: 'rule 2: end-card-rematch must stay enabled',
          );

          _expectText(
            tester,
            find.byKey(_winnerTitleKey),
            loc.endLoseTitle('Sam'),
            what: 'winner title',
          );
        },
      );
    }

    testWidgets(
      'en+ar: 4-seat room, two of three others gone: end-card-left names '
      'both, joined by the locale separator',
      (WidgetTester tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
          _seatJson(2, name: 'Ken'),
          _seatJson(3, name: 'Mia'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectFinished(
          tester,
          mySeat: 0,
          seats: seats,
          winner: 0,
          players: 4,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await _pushPlayerLeft(tester, transport, seat: 1, seq: 3);
        await _pushPlayerLeft(tester, transport, seat: 2, seq: 4);

        expect(controller.room!.seats.map((s) => s.seat), <int>[
          0,
          3,
        ], reason: 'fixture: seats 1 and 2 must both be gone');

        for (final Locale locale in <Locale>[
          const Locale('en'),
          const Locale('ar'),
        ]) {
          await tester.pumpWidget(
            _harness(GameScreen(controller: controller), locale: locale),
          );
          await tester.pump();

          final Finder left = find.byKey(_endLeftKey);
          expect(
            left,
            findsOneWidget,
            reason:
                '${locale.languageCode}: end-card-left must show with two '
                'departed seats',
          );
          final String expected = _expectedEndLeft(locale, <String>[
            'Bob',
            'Ken',
          ]);
          final String blob = _blobUnder(tester, left);
          expect(
            blob.contains(expected),
            isTrue,
            reason:
                '${locale.languageCode}: end-card-left must join departed '
                'names in seat order with the locale separator, reading '
                '"$expected"; blob was "$blob"',
          );
        }
      },
    );

    testWidgets(
      'FINISHED room of 2, the only other seat leaves: end-card-left reads '
      'endEveryoneLeft, no Play again, no ask, New table is primary',
      (WidgetTester tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectFinished(
          tester,
          mySeat: 0,
          seats: seats,
          winner: 0,
          players: 2,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        // Mutation this catches: a fix that hides Play again/the ready
        // dots only when `rematch` is null, which was already true before
        // this order and proves nothing new -- the departed-seat gate
        // must hide them even though `rematch` is genuinely null here too.
        await _pushPlayerLeft(tester, transport, seat: 1, seq: 3);
        expect(controller.room!.seats.map((s) => s.seat), <int>[
          0,
        ], reason: 'fixture: seat 1 must be gone, leaving only this device');

        final Finder left = find.byKey(_endLeftKey);
        expect(
          left,
          findsOneWidget,
          reason: 'rule 2: no other seat present must still show end-card-left',
        );
        final String blob = _blobUnder(tester, left);
        final String expected = _expectedEveryoneLeft(const Locale('en'));
        expect(
          blob.contains(expected),
          isTrue,
          reason:
              'rule 2: with nobody else at the table, end-card-left must '
              'read endEveryoneLeft == "$expected"; blob was "$blob"',
        );
        expect(
          find.byKey(_rematchKey),
          findsNothing,
          reason: 'rule 2: no one left to rematch with',
        );
        expect(
          find.byKey(_rematchAskKey),
          findsNothing,
          reason: 'rule 2: no ask line with nobody else present',
        );
        expect(
          find.byKey(_rematchWaitingKey),
          findsNothing,
          reason: 'rule 2: no ready dots with nobody else present',
        );

        final Finder newRoom = find.byKey(_newRoomKey);
        expect(newRoom, findsOneWidget, reason: 'fixture');
        final Widget newRoomWidget = tester.widget(newRoom);
        expect(
          newRoomWidget is ElevatedButton,
          isTrue,
          reason:
              'rule 2: New table must be the primary action once everyone '
              'else has left; this suite reads primary as ElevatedButton, '
              'the convention test/rematch_client_test.dart already uses. '
              'Found ${newRoomWidget.runtimeType}',
        );
      },
    );

    testWidgets(
      'a rematch ask whose by seat then leaves: the ask line is gone',
      (WidgetTester tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
          _seatJson(2, name: 'Ken'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectFinished(
          tester,
          mySeat: 1,
          seats: seats,
          winner: 0,
          players: 3,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await _pushRoom(
          tester,
          transport,
          _roomJson(
            state: 'LOBBY',
            players: 3,
            seats: seats,
            gameId: null,
            rematch: <String, Object?>{
              'by': 0,
              'ready': <int>[0],
            },
            seq: 3,
          ),
        );
        expect(
          find.byKey(_rematchAskKey),
          findsOneWidget,
          reason: 'fixture: the ask from Sam (seat 0) must show first',
        );

        // Mutation this catches: resolving rematchByName by falling back
        // to lastFinished.seats whenever the asking seat has left live
        // room.seats, instead of hiding the ask line outright once the
        // asker is confirmed departed.
        await _pushPlayerLeft(tester, transport, seat: 0, seq: 4);

        expect(controller.room!.seats.map((s) => s.seat), <int>[
          1,
          2,
        ], reason: 'fixture: seat 0 (the asker) must be gone');
        expect(
          find.byKey(_rematchAskKey),
          findsNothing,
          reason:
              'rule 2: once rematch.by has departed, the ask line must be '
              'gone, not shown with a stale or empty name',
        );
      },
    );
  });

  group('rule 3: removed by a forced start', () {
    Future<_RecordingControllerFactory> tapCreateRoom(
      WidgetTester tester,
    ) async {
      final _RecordingControllerFactory factory = _RecordingControllerFactory();
      await tester.pumpWidget(_homeScreenApp(factory.call));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-room-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return factory;
    }

    testWidgets(
      'player_left naming this seat while GameScreen is up in a rematch '
      'LOBBY pops to HomeScreen, which shows home-removed-notice; it is '
      'gone after Create Room is tapped again',
      (WidgetTester tester) async {
        final _RecordingControllerFactory factory = await tapCreateRoom(tester);
        addTearDown(() {
          for (final RoomController c in factory.controllers) {
            try {
              c.dispose();
            } catch (_) {
              // already disposed
            }
          }
        });
        final FakeTransport transport = factory.transports.single;
        final String createId = _idOf(
          transport.sentRaw
              .where((String r) => _typeOf(r) == 'create_room')
              .single,
        );
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ];
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: createId,
            data: _roomJson(
              state: 'FINISHED',
              players: 2,
              seats: seats,
              turn: _finishedTurnJson(),
              winner: 0,
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: 'fixture is broken: a FINISHED reply must latch GameScreen',
        );

        await _pushRoom(
          tester,
          transport,
          _roomJson(
            state: 'LOBBY',
            players: 2,
            seats: seats,
            gameId: null,
            rematch: <String, Object?>{
              'by': 1,
              'ready': <int>[1],
            },
            seq: 2,
          ),
        );
        expect(find.byType(GameScreen), findsOneWidget, reason: 'fixture');

        // Mutation this catches: GameScreen._onFrame's player_left handler
        // staying a plain `Navigator.of(context).pop()` with no result and
        // no notice recorded anywhere HomeScreen reads.
        await _pushPlayerLeft(tester, transport, seat: 0, seq: 3);
        // The pop runs a page transition (about 300 ms); settle it with
        // bounded pumps, never pumpAndSettle.
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(
          find.byType(GameScreen),
          findsNothing,
          reason: 'fixture: a player_left naming this seat must pop the route',
        );
        final Finder notice = find.byKey(const Key('home-removed-notice'));
        expect(
          notice,
          findsOneWidget,
          reason:
              'rule 3: HomeScreen must show home-removed-notice once a '
              'player_left names this seat while GameScreen was up',
        );
        final String blob = _blobUnder(tester, notice);
        expect(
          blob.contains(_enHomeRemovedNotice),
          isTrue,
          reason:
              'rule 3: home-removed-notice must read homeRemovedNotice == '
              '"$_enHomeRemovedNotice"; blob was "$blob"',
        );

        await tester.tap(find.byKey(const Key('create-room-button')));
        await tester.pump();
        expect(
          find.byKey(const Key('home-removed-notice')),
          findsNothing,
          reason: 'rule 3: tapping Create Room must clear the notice',
        );
      },
    );

    testWidgets(
      'same from LobbyScreen: player_left naming this seat while the room '
      'has never left LOBBY pops to HomeScreen with home-removed-notice',
      (WidgetTester tester) async {
        final _RecordingControllerFactory factory = await tapCreateRoom(tester);
        addTearDown(() {
          for (final RoomController c in factory.controllers) {
            try {
              c.dispose();
            } catch (_) {
              // already disposed
            }
          }
        });
        final FakeTransport transport = factory.transports.single;
        final String createId = _idOf(
          transport.sentRaw
              .where((String r) => _typeOf(r) == 'create_room')
              .single,
        );
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 1, 'seat_token': 'tok-1'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: createId,
            data: _roomJson(
              state: 'LOBBY',
              players: 3,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Bob'),
              ],
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byType(LobbyScreen),
          findsOneWidget,
          reason: 'fixture is broken: a LOBBY reply must show LobbyScreen',
        );

        // Mutation this catches: LobbyScreen having no player_left
        // handling at all (confirmed by grep: there is none on this tree)
        // and simply re-rendering with the seat missing from the grid.
        await _pushPlayerLeft(tester, transport, seat: 1, seq: 2);
        // The pop runs a page transition (about 300 ms); settle it with
        // bounded pumps, never pumpAndSettle.
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(
          find.byType(LobbyScreen),
          findsNothing,
          reason:
              'rule 3: a player_left naming this seat must pop LobbyScreen '
              'too, the same as GameScreen',
        );
        expect(
          find.byKey(const Key('home-removed-notice')),
          findsOneWidget,
          reason: 'rule 3: HomeScreen must show home-removed-notice here too',
        );
      },
    );
  });

  group('rule 4: offline on the end card', () {
    testWidgets(
      'FINISHED, the transport drops: no game-screen-stale-table, the card '
      'is hit-testable (Check reaches the verify launcher), end-card-offline '
      'is shown',
      (WidgetTester tester) async {
        const String verifyUrl = 'https://leave-end-card.invalid/v/offline';
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectFinished(
          tester,
          mySeat: 0,
          seats: seats,
          winner: 0,
          players: 2,
          verifyUrl: verifyUrl,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          controller.phase,
          RoomPhase.closed,
          reason: 'fixture is broken: the drop must close phase',
        );

        // Mutation this catches: GameScreen.build's dispatch staying a
        // single `room != null && phase is failed/closed/connecting`
        // branch that does not read room.state at all, so FINISHED gets
        // the same dimmed stale table PLAYING keeps.
        expect(
          find.byKey(_staleTableKey),
          findsNothing,
          reason:
              'rule 4: FINISHED while offline must not show '
              'game-screen-stale-table (that is PLAYING\'s unchanged '
              'behaviour, not FINISHED\'s new one)',
        );

        final Finder offline = find.byKey(_offlineKey);
        expect(
          offline,
          findsOneWidget,
          reason:
              'rule 4: end-card-offline must take the rematch line\'s place',
        );
        final String blob = _blobUnder(tester, offline);
        expect(
          blob.contains(_enEndOffline),
          isTrue,
          reason:
              'rule 4: end-card-offline must read endOffline == '
              '"$_enEndOffline"; blob was "$blob"',
        );

        final List<MethodCall> launches = _listenUrlLaunches(tester);
        final Finder verify = find.byKey(_verifyKey);
        expect(verify, findsOneWidget, reason: 'fixture');
        await tester.ensureVisible(verify);
        await tester.tap(verify);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          _launched(launches, verifyUrl),
          isTrue,
          reason:
              'rule 4: Check the rolls must stay hit-testable offline and '
              'reach the verify launcher with $verifyUrl; calls were '
              '$launches',
        );
      },
    );

    testWidgets('FINISHED, offline, tapping Play again sends resume on a new '
        'connection and, once the resume\'s room lands, exactly one rematch', (
      WidgetTester tester,
    ) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ];
      final (
        RoomController controller,
        FakeTransport transport,
        _Connector connector,
      ) = await _connectFinished(
        tester,
        mySeat: 0,
        seats: seats,
        winner: 0,
        players: 2,
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      expect(controller.phase, RoomPhase.closed, reason: 'fixture');

      final FakeTransport resumeTransport = FakeTransport();
      connector.enqueue(resumeTransport);

      // Mutation this catches: Play again staying wired straight to
      // RoomController.rematch(), which is a silent no-op whenever
      // phase != connected (room_controller.dart's own rematch() body),
      // so neither a resume nor a rematch is ever sent.
      final Finder rematch = find.byKey(_rematchKey);
      expect(rematch, findsOneWidget, reason: 'fixture');
      await tester.ensureVisible(rematch);
      await tester.tap(rematch);
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();

      expect(
        resumeTransport.sentRaw,
        isNotEmpty,
        reason:
            'rule 4: tapping Play again offline must open a new '
            'connection and send resume on it, the same reconnect the '
            'connection-lost card\'s own Reconnect starts',
      );
      final List<String> resumes = resumeTransport.sentRaw
          .where((String r) => _typeOf(r) == 'resume')
          .toList();
      expect(resumes, hasLength(1));

      resumeTransport.pushText(
        _frame(
          type: 'room',
          re: _idOf(resumes.single),
          data: _roomJson(
            state: 'FINISHED',
            players: 2,
            seats: seats,
            turn: _finishedTurnJson(),
            winner: 0,
            seq: 1,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        controller.phase,
        RoomPhase.connected,
        reason: 'fixture: the resume reply must land the controller connected',
      );

      expect(
        _sentOfType(resumeTransport, 'rematch'),
        1,
        reason:
            'rule 4: once the resume lands, exactly one rematch must be '
            'sent on the new connection',
      );
    });

    testWidgets(
      'FINISHED, offline, Play again reconnects but the resume answers '
      'NO_SUCH_ROOM: end-card-rematch-gone is shown',
      (WidgetTester tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
          _Connector connector,
        ) = await _connectFinished(
          tester,
          mySeat: 0,
          seats: seats,
          winner: 0,
          players: 2,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();

        final FakeTransport resumeTransport = FakeTransport();
        connector.enqueue(resumeTransport);
        await tester.ensureVisible(find.byKey(_rematchKey));
        await tester.tap(find.byKey(_rematchKey));
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();

        final List<String> resumes = resumeTransport.sentRaw
            .where((String r) => _typeOf(r) == 'resume')
            .toList();
        expect(
          resumes,
          hasLength(1),
          reason:
              'fixture: Play again must have attempted a reconnect before '
              'this case can answer it with NO_SUCH_ROOM; sent '
              '${resumeTransport.sentRaw}',
        );

        resumeTransport.pushText(
          _frame(
            type: 'error',
            re: _idOf(resumes.single),
            data: <String, Object?>{'code': 'NO_SUCH_ROOM', 'message': ''},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(_rematchGoneKey),
          findsOneWidget,
          reason:
              'rule 4: a NO_SUCH_ROOM answer to the reconnect\'s resume must '
              'show end-card-rematch-gone, today\'s existing closed-table '
              'card',
        );
      },
    );
  });

  group('rule 5: the fetch gate survives a rematch race', () {
    testWidgets(
      'a rematch room (LOBBY, rematch set) arrives while game_log is in '
      'flight: once the answer lands, the four stat tiles show it',
      (WidgetTester tester) async {
        const String gameId = 'a1b2c3d4e5f6a1b2';
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[57, 57, 57, 57]),
          _seatJson(1, name: 'Bob', tokens: const <int>[57, 57, 57, 48]),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _resumeFinished(
          tester,
          mySeat: 1,
          seats: seats,
          winner: 0,
          gameId: gameId,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        expect(
          controller.gameTranscript,
          isEmpty,
          reason: 'fixture: a resume carries no local transcript',
        );

        await tester.pump(const Duration(milliseconds: 50));
        final List<String> gameLogs = transport.sentRaw
            .where((String r) => _typeOf(r) == 'game_log')
            .toList();
        expect(
          gameLogs,
          hasLength(1),
          reason:
              'fixture: an incomplete transcript must trigger exactly one '
              'game_log request; sent ${transport.sentRaw}',
        );
        final String requestId = _idOf(gameLogs.single);

        // Mutation this catches: none, if this push is ever skipped --
        // this is the race itself. The rematch room pushed here nulls
        // room.gameId before the game_log answer lands.
        await _pushRoom(
          tester,
          transport,
          _roomJson(
            state: 'LOBBY',
            players: 2,
            seats: seats,
            gameId: null,
            rematch: <String, Object?>{
              'by': 0,
              'ready': <int>[0],
            },
            seq: 7,
          ),
        );
        expect(
          controller.room!.gameId,
          isNull,
          reason: 'fixture: the rematch LOBBY must carry game_id null',
        );
        expect(
          controller.lastFinished!.gameId,
          gameId,
          reason: 'fixture: lastFinished must still hold the finished game_id',
        );

        // The script _fetchGameLog's completeness check needs: a
        // game_started/turn/rolled/moved chain with no seq gap, ending on
        // game_over at the finished tokens -- 2 rolls, 1 six, 1 capture,
        // 4 home, the same numbers test/end_card_game_log_test.dart's own
        // `_hostEntries` fixture documents.
        final List<Map<String, Object?>> entries = <Map<String, Object?>>[
          <String, Object?>{
            't': 'game_started',
            'd': <String, Object?>{
              'turn': 0,
              'game_id': gameId,
              'client_seeds': '0:seed',
              'seq': 1,
            },
          },
          <String, Object?>{
            't': 'turn',
            'd': <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 2},
          },
          <String, Object?>{
            't': 'rolled',
            'd': <String, Object?>{
              'seat': 0,
              'value': 6,
              'legal': <int>[0],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'a' * 64,
              'seq': 3,
            },
          },
          <String, Object?>{
            't': 'moved',
            'd': <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': -1,
              'to': 0,
              'captured': <Map<String, Object?>>[
                <String, Object?>{'seat': 1, 'token': 0},
              ],
              'extra_roll': false,
              'seq': 4,
            },
          },
          <String, Object?>{
            't': 'rolled',
            'd': <String, Object?>{
              'seat': 0,
              'value': 4,
              'legal': <int>[0],
              'deadline_ms': 45000,
              'k': 2,
              'reveal': 'a' * 64,
              'seq': 5,
            },
          },
          <String, Object?>{
            't': 'moved',
            'd': <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 0,
              'to': 57,
              'captured': const <Map<String, Object?>>[],
              'extra_roll': false,
              'seq': 6,
            },
          },
          <String, Object?>{
            't': 'moved',
            'd': <String, Object?>{
              'seat': 0,
              'token': 1,
              'from': -1,
              'to': 57,
              'captured': const <Map<String, Object?>>[],
              'extra_roll': false,
              'seq': 7,
            },
          },
          <String, Object?>{
            't': 'moved',
            'd': <String, Object?>{
              'seat': 0,
              'token': 2,
              'from': -1,
              'to': 57,
              'captured': const <Map<String, Object?>>[],
              'extra_roll': false,
              'seq': 8,
            },
          },
          <String, Object?>{
            't': 'moved',
            'd': <String, Object?>{
              'seat': 0,
              'token': 3,
              'from': -1,
              'to': 57,
              'captured': const <Map<String, Object?>>[],
              'extra_roll': false,
              'seq': 9,
            },
          },
          <String, Object?>{
            't': 'game_over',
            'd': <String, Object?>{
              'winner': 0,
              'verify_url': 'https://leave-end-card.invalid/v/$gameId',
              'seq': 10,
            },
          },
        ];
        transport.pushText(
          _frame(
            type: 'game_log',
            re: requestId,
            data: <String, Object?>{
              'game_id': gameId,
              'part': 1,
              'parts': 1,
              'frames': entries,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(const Key('end-card-stat-rolls')),
          findsOneWidget,
          reason:
              'rule 5: the game_log answer must be kept once it lands, '
              'because its game is lastFinished.gameId, even though the '
              'rematch LOBBY had already nulled room.gameId',
        );
        expect(
          _tileShowsNumber(tester, const Key('end-card-stat-rolls'), 2),
          isTrue,
          reason: 'rule 5: end-card-stat-rolls must read 2',
        );
        expect(
          _tileShowsNumber(tester, const Key('end-card-stat-sixes'), 1),
          isTrue,
          reason: 'rule 5: end-card-stat-sixes must read 1',
        );
        expect(
          _tileShowsNumber(tester, const Key('end-card-stat-captures'), 1),
          isTrue,
          reason: 'rule 5: end-card-stat-captures must read 1',
        );
        expect(
          _tileShowsNumber(tester, const Key('end-card-stat-home'), 4),
          isTrue,
          reason: 'rule 5: end-card-stat-home must read 4',
        );
      },
    );
  });
}

// --- rule 3's HomeScreen harness, copied from
// --- test/game_screen_new_room_button_test.dart's own idiom ---------------

class _RecordingControllerFactory {
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

Widget _homeScreenApp(RoomController Function() controllerFactory) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: controllerFactory,
    ),
  );
}

void _expectText(
  WidgetTester tester,
  Finder finder,
  String expected, {
  required String what,
}) {
  final String blob = _blobUnder(tester, finder);
  expect(
    blob.contains(expected),
    isTrue,
    reason: '$what must read "$expected"; blob was "$blob"',
  );
}
