// Proof for contract C-447 (work/ludo/orders/C-447-relaunch-back-to-game.md):
// a phone the OS killed comes back to its game, not to home.
//
// Written from the contract, docs/PROTOCOL.md sections 3, 8 and 16.9, and
// from the rigs in test/home_rejoin_test.dart, test/link_join_test.dart and
// test/session_memory_seat_record_test.dart. Nothing here was derived from
// the body of home_screen.dart or lobby_screen.dart.
//
// Case ids follow the contract's decisions:
//   R1..R7   D2/D3  a fresh record resumes on its own, an old one is dropped,
//                   a legacy one (no session.seatSavedAt) keeps the button
//   R8, R9   D4     a resume refused with NO_SUCH_ROOM or BAD_SEAT_TOKEN goes
//                   home with a true line instead of lobby-error
//   R10      D5     any other failure is unchanged
//   R11, R12 D4b    a room link to a reaped room gets its own line and no Retry
//   R13      D3     a Home that is not the current route does not resume
//
// Time: every saved time is seeded relative to DateTime.now() at the start of
// the case, so no clock seam is needed. Ages that sit near the 60 minute
// boundary use a margin of at least ten seconds, far above the time a case
// takes on the fake clock.
//
// Hygiene: one pumpWidget per case; every pump after a route can be pushed is
// bounded (the lobby's connecting indicator and the game's countdown tick
// forever, so pumpAndSettle would never return); every request a case leaves
// unanswered is flushed past RoomConnection's ten second timeout, and the
// tree is unmounted and the controllers disposed in the body, so no timer is
// pending when a case ends.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/deep_link.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/server_config.dart' show RoomControllerFactory;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _rejoinKey = Key('home-rejoin-button');
const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');
const Key _createKey = Key('create-room-button');
const Key _lobbyErrorKey = Key('lobby-error');
const Key _retryKey = Key('lobby-retry-button');
const Key _lobbyLeaveKey = Key('lobby-leave-button');
const Key _gameLeaveKey = Key('game-screen-appbar-leave');
const Key _goneNoticeKey = Key('home-game-gone-notice');
const Key _removedNoticeKey = Key('home-removed-notice');
const Key _coverKey = Key('relaunch-cover-probe');

const String _testUrl = 'wss://relaunch-test.invalid/ws';

const String _seatPrefsKey = 'session.seat';
const String _savedAtPrefsKey = 'session.seatSavedAt';
const String _namePrefsKey = 'session.lastName';
const String _seatsPrefsKey = 'session.lastSeats';

const String _kCode = 'K7M2QP';
const int _kSeat = 2;
const String _kToken = 'tok-relaunch-seed-001';
const String _otherCode = 'ZY98XW';
const String _knownName = 'Nour';

const Duration _kFresh = Duration(minutes: 5);
const Duration _kJustInside = Duration(minutes: 59, seconds: 50);
const Duration _kAtLimit = Duration(minutes: 60);
const Duration _kStale = Duration(minutes: 61);

// The strings D4 and D4b define, copied from the contract text. The ARB
// getters do not exist on main, so these literals are what keeps the file
// compiling there.
const String _enGone = 'That game has ended.';
const String _arGone = 'انتهت تلك اللعبة.';
const String _enLinkGone =
    'This game is no longer open. Ask your friend for a new link.';
const String _arLinkGone =
    'هذه اللعبة لم تعد مفتوحة. اطلب من صديقك رابطاً جديداً.';
const String _enNoSuchRoom =
    'That room does not exist. Check the code and try again.';
const String _arNoSuchRoom =
    'هذه الغرفة غير موجودة. تحقق من الرمز وحاول مرة أخرى.';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'relaunch-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _playingRoomJson({required String code}) =>
    <String, Object?>{
      'code': code,
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
      'game_id': 'g' * 16,
      'client_seeds': '0:seed',
      'seats': <Map<String, Object?>>[
        _seatJson(0, name: 'Host'),
        _seatJson(_kSeat, name: 'Rejoiner'),
      ],
      'turn': const <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': 45000,
        'k': 0,
      },
      'winner': null,
      'seq': 5,
    };

/// Seeds the mock store. [seat] is session.seat verbatim; [savedAt] is
/// session.seatSavedAt verbatim (an int for a real record). [known] adds the
/// stored name and table size a link needs to join without asking.
void _seed({Object? seat, Object? savedAt, bool known = false}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (known) _namePrefsKey: _knownName,
    if (known) _seatsPrefsKey: 4,
    _seatPrefsKey: ?seat,
    _savedAtPrefsKey: ?savedAt,
  });
}

List<String> _seatList([String code = _kCode]) => <String>[
  code,
  _kSeat.toString(),
  _kToken,
];

/// A record written by this build, [age] ago.
void _seedFresh({
  Duration age = _kFresh,
  String code = _kCode,
  bool known = false,
}) {
  final int savedAt = DateTime.now().subtract(age).millisecondsSinceEpoch;
  _seed(seat: _seatList(code), savedAt: savedAt, known: known);
}

/// A record written by v1.18.0 or older: session.seat alone.
void _seedLegacy({String code = _kCode, bool known = false}) {
  _seed(seat: _seatList(code), known: known);
}

Future<bool> _hasKey(String key) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.containsKey(key);
}

Future<List<String>?> _storedSeat() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  return prefs.getStringList(_seatPrefsKey);
}

/// Hands out a fresh controller over a fresh [FakeTransport] per call.
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

  /// Every frame of [type] sent on any transport, in transport order.
  List<String> sent(String type) => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (_typeOf(s) == type) s,
  ];

  List<String> get allTypes => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw) _typeOf(s),
  ];

  /// Disposes every controller. Home disposes the ones it retires itself, and
  /// a ChangeNotifier refuses a second dispose, so that refusal is the only
  /// thing swallowed here.
  void disposeAll() {
    final List<RoomController> pending = List<RoomController>.of(controllers);
    controllers.clear();
    for (final RoomController controller in pending) {
      try {
        controller.dispose();
      } on FlutterError {
        // Already disposed by Home's own retire flow.
      }
    }
  }
}

/// A connector whose first call rejects (the shape RoomConnection maps to
/// errorCode "transport") and whose later calls open a fresh transport.
class _FlakyFactory {
  final List<FakeTransport> transports = <FakeTransport>[];
  final List<RoomController> controllers = <RoomController>[];
  int connectCalls = 0;

  Future<FakeTransport> _connect(Uri url) async {
    connectCalls += 1;
    if (connectCalls == 1) {
      throw StateError('relaunch_back_to_game_test R10: first connect rejects');
    }
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    return transport;
  }

  RoomController call() {
    final RoomController created = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: _connect,
    );
    controllers.add(created);
    return created;
  }

  void disposeAll() {
    for (final RoomController controller in controllers) {
      try {
        controller.dispose();
      } on FlutterError {
        // Already disposed by Home's own retire flow.
      }
    }
  }
}

class _Observer extends NavigatorObserver {
  int pushes = 0;
  int abovePushes = 0;
  int pops = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes += 1;
    if (previousRoute != null) {
      abovePushes += 1;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops += 1;
  }
}

class _LinkRig {
  _LinkRig({this.cold});

  /// The cold-start link, delivered inside the first pump (before session
  /// memory has finished loading) when set.
  final Uri? cold;
  final Completer<Uri?> late = Completer<Uri?>();
  final StreamController<Uri> stream = StreamController<Uri>.broadcast();
  bool deferred = false;

  Future<Uri?> read() => deferred ? late.future : Future<Uri?>.value(cold);
  Stream<Uri> open() => stream.stream;
}

Uri _linkTo(String code) => Uri.parse('https://ludo.provefair.app/r/$code');

Widget _app(
  RoomControllerFactory factory, {
  Locale? locale,
  _Observer? observer,
  _LinkRig? links,
}) {
  final HomeScreen home = HomeScreen(
    onToggleLocale: () {},
    controllerFactory: factory,
    initialLinkReader: links?.read ?? noInitialLink,
    linkStream: links?.open ?? noLinkStream,
  );
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: <NavigatorObserver>[?observer],
    home: home,
  );
}

/// Bounded pumps only: long enough for the load, a pushed route's transition
/// and the first frames of whatever it shows, never pumpAndSettle.
Future<void> _pumpBounded(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _mount(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(app);
  await _pumpBounded(tester);
}

bool _homeIsCurrent(WidgetTester tester) {
  final Finder home = find.byType(HomeScreen, skipOffstage: false);
  if (home.evaluate().length != 1) {
    return false;
  }
  return ModalRoute.of(tester.element(home))?.isCurrent ?? false;
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// Flushes any request still waiting on RoomConnection's ten second timeout,
/// unmounts the tree so no listener outlives its controller, and disposes the
/// controllers, all inside the case body.
Future<void> _finish(
  WidgetTester tester,
  void Function() disposeAll, {
  bool flush = true,
}) async {
  if (flush) {
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  disposeAll();
  await tester.pump();
}

/// The `resume` frame of the single transport, asserted to be the only frame
/// and to carry the seeded code and token. Returns its request id.
String _expectOnlyResume(
  _Factory factory, {
  required String scenario,
  String code = _kCode,
}) {
  expect(
    factory.controllers,
    hasLength(1),
    reason:
        '$scenario: exactly one controller must be built; built '
        '${factory.controllers.length}',
  );
  final FakeTransport transport = factory.transports.single;
  expect(
    transport.sentRaw.map(_typeOf).toList(),
    <String>['resume'],
    reason:
        '$scenario: exactly one resume frame and nothing else must reach '
        'the transport; sent ${transport.sentRaw.map(_typeOf).toList()}',
  );
  expect(
    _dataOf(transport.sentRaw.single),
    <String, Object?>{'code': code, 'seat_token': _kToken},
    reason:
        '$scenario: resume must carry the stored code "$code" and token '
        '"$_kToken"; sent ${_dataOf(transport.sentRaw.single)}',
  );
  return _idOf(transport.sentRaw.single);
}

void _answerResumePlaying(FakeTransport transport, String resumeId) {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': _kSeat, 'seat_token': _kToken},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: resumeId,
      data: _playingRoomJson(code: _kCode),
    ),
  );
}

void _answerError(FakeTransport transport, String requestId, String code) {
  transport.pushText(
    _frame(
      type: 'error',
      re: requestId,
      data: <String, Object?>{'code': code, 'message': ''},
    ),
  );
}

/// Pumps frame by frame after an error answer and reports whether
/// lobby-error was on the tree at any frame, offstage included.
Future<List<int>> _pumpWatchingLobbyError(WidgetTester tester) async {
  final List<int> framesWithError = <int>[];
  for (int i = 0; i < 20; i += 1) {
    await tester.pump(
      i == 0 ? Duration.zero : const Duration(milliseconds: 50),
    );
    if (find.byKey(_lobbyErrorKey, skipOffstage: false).evaluate().isNotEmpty) {
      framesWithError.add(i);
    }
  }
  await tester.pump(const Duration(milliseconds: 400));
  if (find.byKey(_lobbyErrorKey, skipOffstage: false).evaluate().isNotEmpty) {
    framesWithError.add(20);
  }
  return framesWithError;
}

void _expectGoneNotice(
  WidgetTester tester, {
  required String expected,
  required String scenario,
}) {
  final Finder notice = find.byKey(_goneNoticeKey);
  expect(
    notice,
    findsOneWidget,
    reason:
        '$scenario: Home must show home-game-gone-notice; found '
        '${notice.evaluate().length}',
  );
  final Text text = tester.widget<Text>(notice);
  expect(
    text.data,
    expected,
    reason: '$scenario: the notice must read "$expected"; read "${text.data}"',
  );
  expect(
    find.byKey(_removedNoticeKey, skipOffstage: false),
    findsNothing,
    reason: '$scenario: the removed-player notice must not show with it',
  );
  final Finder create = find.byKey(_createKey);
  if (create.evaluate().length == 1) {
    expect(
      tester.getTopLeft(notice).dy,
      lessThan(tester.getTopLeft(create).dy),
      reason:
          '$scenario: the notice takes the slot above create-room-button '
          'that home-removed-notice uses',
    );
  }
}

Future<void> _expectStoreCleared(String scenario) async {
  expect(
    await _hasKey(_seatPrefsKey),
    isFalse,
    reason:
        '$scenario: session.seat must be gone; holds ${await _storedSeat()}',
  );
  expect(
    await _hasKey(_savedAtPrefsKey),
    isFalse,
    reason: '$scenario: session.seatSavedAt must be gone with it',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------------------- D3
  testWidgets(
    'R1 (D3): a record saved 5 minutes ago resumes on its own, once, with '
    'the stored code and token',
    (tester) async {
      _seedFresh();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      _expectOnlyResume(factory, scenario: 'R1 record age 5 min, no tap');

      await _finish(tester, factory.disposeAll);
    },
  );

  testWidgets(
    'R2 (D3, player view): the resume answered PLAYING puts the game on top, '
    'Home is not the visible route',
    (tester) async {
      _seedFresh();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      final String id = _expectOnlyResume(
        factory,
        scenario: 'R2 record age 5 min, no tap',
      );
      _answerResumePlaying(factory.transports.single, id);
      await _pumpBounded(tester, frames: 4);

      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason:
            'R2: seat_assigned + PLAYING room answering the automatic resume '
            'must leave GameScreen on screen; found '
            '${find.byType(GameScreen).evaluate().length}',
      );
      expect(
        find.byKey(_gameLeaveKey),
        findsOneWidget,
        reason: 'R2: the game screen always draws game-screen-appbar-leave',
      );
      expect(
        find.byKey(_nameKey),
        findsNothing,
        reason: 'R2: Home\'s name field must not be visible under the game',
      );
      expect(
        _homeIsCurrent(tester),
        isFalse,
        reason: 'R2: Home must not be the current route',
      );
      expect(
        factory.controllers,
        hasLength(1),
        reason: 'R2: still exactly one controller after the answer',
      );

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  // ---------------------------------------------------------------- D2
  testWidgets('R3 (D2): a record saved 61 minutes ago is treated as absent: no '
      'controller, no frame, no button, both keys cleared', (tester) async {
    _seedFresh(age: _kStale);
    final _Factory factory = _Factory();
    await _mount(tester, _app(factory.call));

    expect(
      factory.controllers,
      isEmpty,
      reason:
          'R3 record age 61 min: no controller may be built; built '
          '${factory.controllers.length}',
    );
    expect(
      factory.allTypes,
      isEmpty,
      reason: 'R3: no frame may be sent; sent ${factory.allTypes}',
    );
    expect(
      find.byKey(_rejoinKey, skipOffstage: false),
      findsNothing,
      reason:
          'R3: a record older than the reap window must not show the button',
    );
    await _expectStoreCleared('R3 record age 61 min');

    await _finish(tester, factory.disposeAll, flush: false);
  });

  testWidgets(
    'R3b (D2 boundary): a record exactly 60 minutes old is already stale',
    (tester) async {
      _seedFresh(age: _kAtLimit);
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      expect(
        factory.allTypes,
        isEmpty,
        reason:
            'R3b record age 60 min (at least kSeatRecordMaxAge is absent): '
            'no controller or frame; sent ${factory.allTypes}',
      );
      expect(
        find.byKey(_rejoinKey, skipOffstage: false),
        findsNothing,
        reason: 'R3b: no button for a record 60 minutes old',
      );
      await _expectStoreCleared('R3b record age 60 min');

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  testWidgets(
    'R3c (D2 boundary): a record 59 min 50 s old is still fresh and resumes',
    (tester) async {
      _seedFresh(age: _kJustInside);
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      _expectOnlyResume(factory, scenario: 'R3c record age 59 min 50 s');

      await _finish(tester, factory.disposeAll);
    },
  );

  testWidgets(
    'R4 (D2 legacy): a record with no session.seatSavedAt keeps the button '
    'and nothing happens on its own',
    (tester) async {
      _seedLegacy();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason: 'R4: a legacy record (session.seat alone) must show the button',
      );
      expect(
        factory.controllers,
        isEmpty,
        reason:
            'R4: no controller may be built for a record with no saved '
            'time; built ${factory.controllers.length}',
      );
      expect(
        await _storedSeat(),
        _seatList(),
        reason: 'R4: the legacy record must be kept untouched',
      );
      expect(_homeIsCurrent(tester), isTrue, reason: 'R4: Home stays current');

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  testWidgets(
    'R4b (D1/D2): a saved time stored as a String is not an int, so the '
    'record behaves as a legacy one',
    (tester) async {
      _seed(seat: _seatList(), savedAt: '1700000000000');
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      expect(
        find.byKey(_rejoinKey),
        findsOneWidget,
        reason: 'R4b: a String saved time must leave the button showing',
      );
      expect(
        factory.controllers,
        isEmpty,
        reason:
            'R4b: a String saved time is no saved time; no controller may '
            'be built, built ${factory.controllers.length}',
      );

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  testWidgets(
    'R4c (S5 with D3): an untrusted session.seat beside a fresh saved time '
    'resumes nothing and shows no button',
    (tester) async {
      _seed(
        seat: <String>['K7M2Q0', '2', 'tok'],
        savedAt: DateTime.now().millisecondsSinceEpoch,
      );
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      expect(
        factory.allTypes,
        isEmpty,
        reason:
            'R4c: an invalid room code in session.seat must never be sent; '
            'sent ${factory.allTypes}',
      );
      expect(
        find.byKey(_rejoinKey, skipOffstage: false),
        findsNothing,
        reason: 'R4c: no button for an untrusted record',
      );

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  // ---------------------------------------------------------------- D3 + link
  testWidgets(
    'R5 (D3, link for the same code): one route, one resume, no join_room',
    (tester) async {
      _seedFresh(known: true);
      final _Factory factory = _Factory();
      final _Observer observer = _Observer();
      final _LinkRig links = _LinkRig(cold: _linkTo(_kCode));
      addTearDown(links.stream.close);
      await _mount(
        tester,
        _app(factory.call, observer: observer, links: links),
      );

      expect(
        observer.abovePushes,
        1,
        reason:
            'R5 fresh record for $_kCode + cold link for $_kCode: Home must '
            'push exactly one route; pushed ${observer.abovePushes}',
      );
      _expectOnlyResume(factory, scenario: 'R5 cold link, same code');
      expect(
        factory.sent('join_room'),
        isEmpty,
        reason: 'R5: a link for the stored seat must resume, never join_room',
      );
      expect(
        tester.widget<LobbyScreen>(find.byType(LobbyScreen)).action,
        LobbyAction.resume,
        reason: 'R5: the one pushed route must be a resume',
      );

      await _finish(tester, factory.disposeAll);
    },
  );

  testWidgets(
    'R5b (D3, link arriving after the load, same code): still one controller '
    'and one resume',
    (tester) async {
      _seedFresh(known: true);
      final _Factory factory = _Factory();
      final _Observer observer = _Observer();
      final _LinkRig links = _LinkRig()..deferred = true;
      addTearDown(links.stream.close);
      await _mount(
        tester,
        _app(factory.call, observer: observer, links: links),
      );

      links.late.complete(_linkTo(_kCode));
      await _pumpBounded(tester, frames: 4);

      expect(
        observer.abovePushes,
        1,
        reason:
            'R5b fresh record for $_kCode, link for $_kCode after the '
            'load: one pushed route in all; pushed ${observer.abovePushes}',
      );
      _expectOnlyResume(factory, scenario: 'R5b late link, same code');
      expect(factory.sent('join_room'), isEmpty, reason: 'R5b: no join_room');

      await _finish(tester, factory.disposeAll);
    },
  );

  testWidgets('R6 (D3, link for another code): the link is handled as before, no '
      'resume for the old seat, its button stays on Home', (tester) async {
    _seedFresh(known: true);
    final _Factory factory = _Factory();
    final _Observer observer = _Observer();
    final _LinkRig links = _LinkRig(cold: _linkTo(_otherCode));
    addTearDown(links.stream.close);
    await _mount(tester, _app(factory.call, observer: observer, links: links));

    expect(
      factory.sent('resume'),
      isEmpty,
      reason:
          'R6 fresh record for $_kCode, link for $_otherCode: no resume '
          'for the old seat may be sent; sent ${factory.allTypes}',
    );
    expect(
      observer.abovePushes,
      1,
      reason:
          'R6: the link pushes exactly one route; pushed ${observer.abovePushes}',
    );
    expect(
      factory.controllers,
      hasLength(1),
      reason: 'R6: one controller, for the link only',
    );
    final List<String> joins = factory.sent('join_room');
    expect(
      joins,
      hasLength(1),
      reason: 'R6: the link joins once; sent ${factory.allTypes}',
    );
    expect(
      _dataOf(joins.single),
      <String, Object?>{'code': _otherCode, 'name': _knownName},
      reason:
          'R6: join_room carries the link code and the stored name; sent '
          '${_dataOf(joins.single)}',
    );
    expect(
      find.byKey(_rejoinKey, skipOffstage: false),
      findsOneWidget,
      reason:
          'R6: the button for $_kCode must still be on Home under the '
          'pushed route',
    );
    expect(
      await _storedSeat(),
      _seatList(),
      reason: 'R6: the record for $_kCode must be untouched',
    );

    await _finish(tester, factory.disposeAll);
  });

  testWidgets(
    'R7 (D3, once): after the resumed game is left, Home is current and '
    'starts no second resume',
    (tester) async {
      _seedFresh();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));

      final String id = _expectOnlyResume(
        factory,
        scenario: 'R7 before the pop',
      );
      _answerResumePlaying(factory.transports.single, id);
      await _pumpBounded(tester, frames: 4);
      expect(
        find.byType(GameScreen),
        findsOneWidget,
        reason: 'R7 fixture: the game must be on screen before the pop',
      );

      Navigator.of(tester.element(find.byType(GameScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // Leave completes (or times out) and Home retires the controller; give
      // any wrongly scheduled second resume every chance to appear.
      await tester.pump(const Duration(seconds: 11));
      await _pumpBounded(tester, frames: 4);

      expect(
        _homeIsCurrent(tester),
        isTrue,
        reason: 'R7: after the game route pops, Home must be current',
      );
      expect(
        factory.controllers,
        hasLength(1),
        reason:
            'R7: no second controller may be built after the pop; built '
            '${factory.controllers.length}',
      );
      expect(
        factory.sent('resume'),
        hasLength(1),
        reason:
            'R7: exactly one resume over the whole case; sent '
            '${factory.allTypes}',
      );
      expect(
        await _storedSeat(),
        isNull,
        reason: 'R7: leaving clears the record, as it does today (W-7)',
      );
      expect(
        find.byKey(_rejoinKey),
        findsNothing,
        reason: 'R7: with the record gone Home shows no button',
      );

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  // ---------------------------------------------------------------- D4
  for (final String code in <String>['NO_SUCH_ROOM', 'BAD_SEAT_TOKEN']) {
    testWidgets('R8 (D4): an automatic resume answered $code goes home with '
        'home-game-gone-notice, never lobby-error, and clears the record', (
      tester,
    ) async {
      _seedFresh();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));
      final String scenario = 'R8 auto resume answered $code, locale en';

      final String id = _expectOnlyResume(factory, scenario: scenario);
      _answerError(factory.transports.single, id, code);
      final List<int> withError = await _pumpWatchingLobbyError(tester);

      expect(
        withError,
        isEmpty,
        reason:
            '$scenario: lobby-error was on the tree at pump(s) '
            '$withError after the answer; it must never be',
      );
      expect(
        _homeIsCurrent(tester),
        isTrue,
        reason: '$scenario: Home must be the current route',
      );
      _expectGoneNotice(tester, expected: _enGone, scenario: scenario);
      await _expectStoreCleared(scenario);
      expect(
        factory.controllers,
        hasLength(1),
        reason: '$scenario: no second controller',
      );

      await _finish(tester, factory.disposeAll, flush: false);
    });
  }

  testWidgets(
    'R8c (D4): a tap on the button (legacy record) answered NO_SUCH_ROOM goes '
    'home with the notice, never lobby-error',
    (tester) async {
      _seedLegacy();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));
      const String scenario = 'R8c legacy record, tap, NO_SUCH_ROOM, locale en';

      await tester.ensureVisible(find.byKey(_rejoinKey));
      await tester.tap(find.byKey(_rejoinKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final String id = _expectOnlyResume(factory, scenario: scenario);
      _answerError(factory.transports.single, id, 'NO_SUCH_ROOM');
      final List<int> withError = await _pumpWatchingLobbyError(tester);

      expect(
        withError,
        isEmpty,
        reason: '$scenario: lobby-error showed at pump(s) $withError',
      );
      expect(_homeIsCurrent(tester), isTrue, reason: '$scenario: Home current');
      _expectGoneNotice(tester, expected: _enGone, scenario: scenario);
      await _expectStoreCleared(scenario);

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  testWidgets(
    'R8d (D4): a tap on the button answered BAD_SEAT_TOKEN goes home with the '
    'notice, never lobby-error',
    (tester) async {
      _seedLegacy();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));
      const String scenario =
          'R8d legacy record, tap, BAD_SEAT_TOKEN, locale en';

      await tester.ensureVisible(find.byKey(_rejoinKey));
      await tester.tap(find.byKey(_rejoinKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final String id = _expectOnlyResume(factory, scenario: scenario);
      _answerError(factory.transports.single, id, 'BAD_SEAT_TOKEN');
      final List<int> withError = await _pumpWatchingLobbyError(tester);

      expect(
        withError,
        isEmpty,
        reason: '$scenario: lobby-error showed at pump(s) $withError',
      );
      expect(_homeIsCurrent(tester), isTrue, reason: '$scenario: Home current');
      _expectGoneNotice(tester, expected: _enGone, scenario: scenario);
      await _expectStoreCleared(scenario);

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  testWidgets('R8e (D4): the notice goes away when Create is tapped, as '
      'home-removed-notice does', (tester) async {
    _seedFresh();
    final _Factory factory = _Factory();
    await _mount(tester, _app(factory.call));
    const String scenario = 'R8e auto resume NO_SUCH_ROOM then Create';

    final String id = _expectOnlyResume(factory, scenario: scenario);
    _answerError(factory.transports.first, id, 'NO_SUCH_ROOM');
    await _pumpWatchingLobbyError(tester);
    _expectGoneNotice(tester, expected: _enGone, scenario: scenario);

    await tester.ensureVisible(find.byKey(_createKey));
    await tester.tap(find.byKey(_createKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(_goneNoticeKey, skipOffstage: false),
      findsNothing,
      reason: '$scenario: tapping Create must hide home-game-gone-notice',
    );

    await _finish(tester, factory.disposeAll);
  });

  testWidgets(
    'R8f (D4): the notice goes away when Join is tapped with a valid code',
    (tester) async {
      _seedFresh();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call));
      const String scenario = 'R8f auto resume NO_SUCH_ROOM then Join';

      final String id = _expectOnlyResume(factory, scenario: scenario);
      _answerError(factory.transports.first, id, 'NO_SUCH_ROOM');
      await _pumpWatchingLobbyError(tester);
      _expectGoneNotice(tester, expected: _enGone, scenario: scenario);

      await tester.enterText(find.byKey(_codeKey), _otherCode);
      await tester.ensureVisible(find.byKey(_joinKey));
      await tester.tap(find.byKey(_joinKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(_goneNoticeKey, skipOffstage: false),
        findsNothing,
        reason: '$scenario: tapping Join must hide home-game-gone-notice',
      );

      await _finish(tester, factory.disposeAll);
    },
  );

  testWidgets(
    'R9 (D4, ar): the refusal notice reads the Arabic string exactly',
    (tester) async {
      _seedFresh();
      final _Factory factory = _Factory();
      await _mount(tester, _app(factory.call, locale: const Locale('ar')));
      const String scenario = 'R9 auto resume NO_SUCH_ROOM, locale ar';

      final String id = _expectOnlyResume(factory, scenario: scenario);
      expect(
        _loc(tester).localeName,
        'ar',
        reason: 'R9 fixture: the case must run in Arabic',
      );
      _answerError(factory.transports.single, id, 'NO_SUCH_ROOM');
      final List<int> withError = await _pumpWatchingLobbyError(tester);

      expect(
        withError,
        isEmpty,
        reason: '$scenario: lobby-error showed at pump(s) $withError',
      );
      _expectGoneNotice(tester, expected: _arGone, scenario: scenario);

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );

  // ---------------------------------------------------------------- D5
  testWidgets(
    'R10 (D5 control): an automatic resume that fails on the transport keeps '
    'lobby-error with Retry, the record survives, and Retry resends resume',
    (tester) async {
      _seedFresh();
      final _FlakyFactory factory = _FlakyFactory();
      await _mount(tester, _app(factory.call));
      const String scenario = 'R10 auto resume, first connect rejects';

      expect(
        factory.controllers,
        hasLength(1),
        reason:
            '$scenario: a fresh record must start one resume with no tap; '
            'built ${factory.controllers.length} controllers',
      );
      expect(
        factory.controllers.single.errorCode,
        'transport',
        reason:
            '$scenario: fixture: the rejected connect must land errorCode '
            'transport; got ${factory.controllers.single.errorCode}',
      );
      expect(
        find.byKey(_lobbyErrorKey),
        findsOneWidget,
        reason: '$scenario: lobby-error must show for a transport failure',
      );
      expect(
        find.byKey(_retryKey),
        findsOneWidget,
        reason: '$scenario: lobby-retry-button must show',
      );
      expect(
        find.byKey(_lobbyLeaveKey),
        findsOneWidget,
        reason: '$scenario: lobby-leave-button must show',
      );
      expect(
        find.byKey(_goneNoticeKey, skipOffstage: false),
        findsNothing,
        reason: '$scenario: a transport failure is not a gone game',
      );
      expect(
        await _storedSeat(),
        _seatList(),
        reason: '$scenario: the record must survive a transport failure',
      );
      expect(
        await _hasKey(_savedAtPrefsKey),
        isTrue,
        reason: '$scenario: the saved time must survive with it',
      );

      await tester.tap(find.byKey(_retryKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        factory.transports,
        hasLength(1),
        reason: '$scenario: Retry must open the second connection',
      );
      final List<String> sent = factory.transports.single.sentRaw;
      expect(sent.map(_typeOf).toList(), <String>[
        'resume',
      ], reason: '$scenario: Retry must send exactly one resume; sent $sent');
      expect(_dataOf(sent.single), <String, Object?>{
        'code': _kCode,
        'seat_token': _kToken,
      }, reason: '$scenario: Retry resends the stored code and token');

      await _finish(tester, factory.disposeAll);
    },
  );

  // ---------------------------------------------------------------- D4b
  Future<void> linkJoinRefused(
    WidgetTester tester, {
    required String id,
    required Locale? locale,
    required String expected,
    required bool warm,
  }) async {
    final String scenario =
        '$id link join answered NO_SUCH_ROOM, '
        '${warm ? 'warm' : 'cold'} link, locale ${locale ?? 'en'}';
    _seed(known: true);
    final _Factory factory = _Factory();
    final _LinkRig links = warm
        ? (_LinkRig()..deferred = true)
        : _LinkRig(cold: _linkTo(_kCode));
    addTearDown(links.stream.close);
    await _mount(tester, _app(factory.call, locale: locale, links: links));
    if (warm) {
      links.late.complete(null);
      await tester.pump();
      links.stream.add(_linkTo(_kCode));
      await _pumpBounded(tester, frames: 4);
    }

    final List<String> joins = factory.sent('join_room');
    expect(
      joins,
      hasLength(1),
      reason:
          '$scenario: the link must send one join_room; sent ${factory.allTypes}',
    );
    _answerError(
      factory.transports.single,
      _idOf(joins.single),
      'NO_SUCH_ROOM',
    );
    await _pumpBounded(tester, frames: 3);

    final Finder error = find.byKey(_lobbyErrorKey);
    expect(error, findsOneWidget, reason: '$scenario: lobby-error must show');
    expect(
      find.descendant(of: error, matching: find.text(expected)),
      findsOneWidget,
      reason:
          '$scenario: lobby-error must read "$expected"; its texts are '
          '${tester.widgetList<Text>(find.descendant(of: error, matching: find.byType(Text))).map((Text t) => t.data).toList()}',
    );
    expect(
      find.byKey(_retryKey),
      findsNothing,
      reason: '$scenario: no Retry for a reaped room',
    );
    expect(
      find.byKey(_lobbyLeaveKey),
      findsOneWidget,
      reason: '$scenario: lobby-leave-button must stay',
    );

    await _finish(tester, factory.disposeAll);
  }

  testWidgets(
    'R11 (D4b): a cold room link answered NO_SUCH_ROOM reads '
    'lobbyErrorLinkRoomGone, no Retry, Leave stays',
    (tester) => linkJoinRefused(
      tester,
      id: 'R11',
      locale: null,
      expected: _enLinkGone,
      warm: false,
    ),
  );

  testWidgets(
    'R11b (D4b, ar): the same in Arabic',
    (tester) => linkJoinRefused(
      tester,
      id: 'R11b',
      locale: const Locale('ar'),
      expected: _arLinkGone,
      warm: false,
    ),
  );

  testWidgets(
    'R11c (D4b): a warm room link answered NO_SUCH_ROOM reads the same line',
    (tester) => linkJoinRefused(
      tester,
      id: 'R11c',
      locale: null,
      expected: _enLinkGone,
      warm: true,
    ),
  );

  for (final ({String name, Locale? locale, String expected}) variant in [
    (name: 'en', locale: null, expected: _enNoSuchRoom),
    (name: 'ar', locale: const Locale('ar'), expected: _arNoSuchRoom),
  ]) {
    testWidgets(
      'R12 (D4b control, ${variant.name}): a join from a typed code answered '
      'NO_SUCH_ROOM keeps lobbyErrorNoSuchRoom and Retry',
      (tester) async {
        final String scenario =
            'R12 typed code $_otherCode answered NO_SUCH_ROOM, locale '
            '${variant.name}';
        _seed(known: true);
        final _Factory factory = _Factory();
        await _mount(tester, _app(factory.call, locale: variant.locale));

        await tester.enterText(find.byKey(_codeKey), _otherCode);
        await tester.ensureVisible(find.byKey(_joinKey));
        await tester.tap(find.byKey(_joinKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final List<String> joins = factory.sent('join_room');
        expect(
          joins,
          hasLength(1),
          reason: '$scenario: one join_room; sent ${factory.allTypes}',
        );
        _answerError(
          factory.transports.single,
          _idOf(joins.single),
          'NO_SUCH_ROOM',
        );
        await _pumpBounded(tester, frames: 3);

        final Finder error = find.byKey(_lobbyErrorKey);
        expect(error, findsOneWidget, reason: '$scenario: lobby-error shows');
        expect(
          find.descendant(of: error, matching: find.text(variant.expected)),
          findsOneWidget,
          reason: '$scenario: lobby-error must read "${variant.expected}"',
        );
        expect(
          find.byKey(_retryKey),
          findsOneWidget,
          reason: '$scenario: a typed code keeps Retry',
        );
        expect(
          find.byKey(_goneNoticeKey, skipOffstage: false),
          findsNothing,
          reason: '$scenario: a join never uses the gone-game notice',
        );

        await _finish(tester, factory.disposeAll);
      },
    );
  }

  // ---------------------------------------------------------------- D3 last
  testWidgets(
    'R13 (D3): a Home that is not the current route when the load completes '
    'does not resume',
    (tester) async {
      _seedFresh();
      final _Factory factory = _Factory();
      final HomeScreen home = HomeScreen(
        onToggleLocale: () {},
        controllerFactory: factory.call,
      );
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: appSupportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Navigator(
            onGenerateInitialRoutes: (NavigatorState navigator, String name) =>
                <Route<void>>[
                  MaterialPageRoute<void>(builder: (_) => home),
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(key: _coverKey),
                  ),
                ],
          ),
        ),
      );
      await _pumpBounded(tester);

      expect(
        find.byKey(_coverKey),
        findsOneWidget,
        reason: 'R13 fixture: the cover route must sit above Home',
      );
      expect(
        _homeIsCurrent(tester),
        isFalse,
        reason: 'R13 fixture: Home must not be current',
      );
      expect(
        factory.controllers,
        isEmpty,
        reason:
            'R13: a covered Home must not resume; built '
            '${factory.controllers.length} controllers, sent '
            '${factory.allTypes}',
      );

      await _finish(tester, factory.disposeAll, flush: false);
    },
  );
}
