// Proof for contract C-296: a valid room link joins for a known player.
//
// Mounts HomeScreen the way test/deep_link_test.dart does (fake initial
// link reader, fake link stream, recording navigator observer), with a
// controller factory over test/net/fake_transport.dart. Session memory is
// seeded through SharedPreferences.setMockInitialValues with the keys
// SessionMemory.load reads: session.lastName, session.lastSeats, and
// session.seat as [code, seat, seatToken].
//
// On the base this file was written against, a link only fills the code
// field. Cases that require a push are red there. The first-time player,
// a route already above home, and an invalid code stay green there.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const Key _nameKey = Key('home-name-field');
const Key _codeKey = Key('room-code-field');
const Key _chipKey = Key('home-last-table-chip');
const Key _aboveHomeKey = Key('above-home-probe');
const Key _connectingKey = Key('lobby-connecting');

const String _testUrl = 'wss://link-join-test.invalid/ws';

const String _knownName = 'Nour';
const int _knownSeats = 4;
const String _linkCode = 'AB23CD';
const String _otherCode = 'ZY98XW';
const int _seat = 2;
const String _seatToken = 'tok-link-join-001';

const String _namePrefsKey = 'session.lastName';
const String _seatsPrefsKey = 'session.lastSeats';
const String _seatPrefsKey = 'session.seat';

Uri _validLink(String code) => Uri.parse('https://ludo.provefair.app/r/$code');

Uri _invalidCodeLink() => Uri.parse('https://ludo.provefair.app/r/AB0234');

List<String> _storedSeat(String code) => <String>[
  code,
  _seat.toString(),
  _seatToken,
];

SeatRecord _seatRecord(String code) =>
    SeatRecord(code: code, seat: _seat, seatToken: _seatToken);

void _seedKnownPlayer({String? seatCode}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _namePrefsKey: _knownName,
    _seatsPrefsKey: _knownSeats,
    if (seatCode != null) _seatPrefsKey: _storedSeat(seatCode),
  });
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

/// An [InitialLinkReader] held open until [complete], unless [immediate]
/// is set, in which case [call] returns that uri already completed.
///
/// [immediate] is how case 7 delivers the cold link before session memory
/// has loaded. [SessionMemory.load] finishes inside the first
/// [WidgetTester.pumpWidget] flush, so a [Completer] completed from the
/// test body after that pump is already too late. Returning
/// [Future.value] from the reader schedules the link callback in that
/// same flush, ahead of the load's later continuations, which is before
/// the stored name is applied.
class _FakeInitialLinkReader {
  _FakeInitialLinkReader({this.immediate});

  final Uri? immediate;
  final Completer<Uri?> _completer = Completer<Uri?>();
  int callCount = 0;

  Future<Uri?> call() {
    callCount += 1;
    if (immediate != null) {
      return Future<Uri?>.value(immediate);
    }
    return _completer.future;
  }

  void complete(Uri? uri) {
    if (!_completer.isCompleted) {
      _completer.complete(uri);
    }
  }
}

/// A [LinkStreamOpener] backed by a broadcast controller, matching the
/// one in test/deep_link_test.dart. [add] delivers to the current
/// listener synchronously.
class _FakeLinkStreamOpener {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  int callCount = 0;

  Stream<Uri> call() {
    callCount += 1;
    return _controller.stream;
  }

  void add(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();
}

/// Records push, pop, replace and remove. [abovePushCount] counts pushes
/// whose previous route was non-null, so the initial home route is not
/// counted as a link push. [nameAtFirstAbovePush] is filled only when
/// [readNameOnAbovePush] is set, and only for the first such push.
class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushCount = 0;
  int popCount = 0;
  int replaceCount = 0;
  int removeCount = 0;
  int abovePushCount = 0;
  String? nameAtFirstAbovePush;
  String? Function()? readNameOnAbovePush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushCount += 1;
    if (previousRoute != null) {
      abovePushCount += 1;
      if (nameAtFirstAbovePush == null) {
        final String? Function()? read = readNameOnAbovePush;
        if (read != null) {
          nameAtFirstAbovePush = read();
        }
      }
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    replaceCount += 1;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removeCount += 1;
  }
}

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

  void disposeAll() {
    final List<RoomController> pending = List<RoomController>.of(controllers);
    controllers.clear();
    for (final RoomController controller in pending) {
      controller.dispose();
    }
  }
}

class _Mount {
  _Mount({
    required this.factory,
    required this.reader,
    required this.opener,
    required this.observer,
  });

  final _RecordingControllerFactory factory;
  final _FakeInitialLinkReader reader;
  final _FakeLinkStreamOpener opener;
  final _RecordingNavigatorObserver observer;
}

_Mount _prepare(WidgetTester tester, {Uri? immediateLink}) {
  final _RecordingControllerFactory factory = _RecordingControllerFactory();
  final _FakeInitialLinkReader reader = _FakeInitialLinkReader(
    immediate: immediateLink,
  );
  final _FakeLinkStreamOpener opener = _FakeLinkStreamOpener();
  final _RecordingNavigatorObserver observer = _RecordingNavigatorObserver();
  addTearDown(factory.disposeAll);
  addTearDown(opener.close);
  if (immediateLink == null) {
    addTearDown(() => reader.complete(null));
  }
  return _Mount(
    factory: factory,
    reader: reader,
    opener: opener,
    observer: observer,
  );
}

Widget _homeScreenApp(_Mount mount) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: <NavigatorObserver>[mount.observer],
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: mount.factory.call,
      initialLinkReader: mount.reader.call,
      linkStream: mount.opener.call,
    ),
  );
}

Future<void> _pumpHome(WidgetTester tester, _Mount mount) async {
  await tester.pumpWidget(_homeScreenApp(mount));
  await tester.pumpAndSettle();
}

/// The push lands one frame after the link's setState, and that route's
/// first frame is offstage. Pump through the first onstage frame. Bounded
/// on purpose: once LobbyScreen is up, its connecting indicator never
/// settles.
Future<void> _pumpAfterLink(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String? _optionalFieldText(WidgetTester tester, Key key) {
  final Iterable<Element> matches = find
      .byKey(key, skipOffstage: false)
      .evaluate();
  if (matches.length != 1) {
    return null;
  }
  final Widget widget = matches.single.widget;
  if (widget is! TextField) {
    return null;
  }
  return widget.controller?.text;
}

String _fieldText(WidgetTester tester, Key key, {bool skipOffstage = true}) {
  final TextField field = tester.widget<TextField>(
    find.byKey(key, skipOffstage: skipOffstage),
  );
  expect(
    field.controller,
    isNotNull,
    reason: 'fixture is broken: $key has no controller attached',
  );
  return field.controller!.text;
}

String? _codeFieldError(WidgetTester tester, {bool skipOffstage = true}) {
  return tester
      .widget<TextField>(find.byKey(_codeKey, skipOffstage: skipOffstage))
      .decoration
      ?.errorText;
}

void _expectKnownName(WidgetTester tester) {
  expect(
    _fieldText(tester, _nameKey),
    _knownName,
    reason:
        'fixture is broken: a seeded session.lastName must be restored '
        'into home-name-field before the link is delivered; got '
        '"${_fieldText(tester, _nameKey)}"',
  );
  expect(
    find.byKey(_chipKey),
    findsOneWidget,
    reason:
        'fixture is broken: a seeded name and seat count must show '
        'home-last-table-chip, which is how Home treats a known player',
  );
}

void _expectNavigation({
  required _RecordingNavigatorObserver observer,
  required int pushesBefore,
  required int popsBefore,
  required int replacesBefore,
  required int removesBefore,
  required int pushDelta,
  required String reason,
}) {
  expect(
    observer.pushCount,
    pushesBefore + pushDelta,
    reason:
        '$reason: expected $pushDelta push, got '
        '${observer.pushCount - pushesBefore} '
        '(pushCount ${observer.pushCount}, before $pushesBefore)',
  );
  expect(
    observer.popCount,
    popsBefore,
    reason: '$reason: expected no pop, got ${observer.popCount - popsBefore}',
  );
  expect(
    observer.replaceCount,
    replacesBefore,
    reason:
        '$reason: expected no replace, got '
        '${observer.replaceCount - replacesBefore}',
  );
  expect(
    observer.removeCount,
    removesBefore,
    reason:
        '$reason: expected no remove, got '
        '${observer.removeCount - removesBefore}',
  );
}

void _expectJoinFrame(FakeTransport transport) {
  expect(
    transport.sentRaw.map(_typeOf).toList(),
    <String>['join_room'],
    reason:
        'the link must send one join_room and nothing else; sent '
        '${transport.sentRaw.map(_typeOf).toList()}',
  );
  expect(
    _dataOf(transport.sentRaw.single),
    <String, Object?>{'code': _linkCode, 'name': _knownName},
    reason:
        'join_room must carry the link code "$_linkCode" and the stored '
        'name "$_knownName"; sent ${_dataOf(transport.sentRaw.single)}',
  );
}

void _expectResumeFrame(FakeTransport transport, {required String code}) {
  expect(
    transport.sentRaw.map(_typeOf).toList(),
    <String>['resume'],
    reason:
        'a seat record for the link code must send resume, not join_room; '
        'sent ${transport.sentRaw.map(_typeOf).toList()}',
  );
  expect(
    transport.sentRaw.any((String text) => _typeOf(text) == 'join_room'),
    isFalse,
    reason: 'resume for the link code must not also send join_room',
  );
  expect(
    _dataOf(transport.sentRaw.single),
    <String, Object?>{'code': code, 'seat_token': _seatToken},
    reason:
        'resume must carry the stored code "$code" and seat token '
        '"$_seatToken"; sent ${_dataOf(transport.sentRaw.single)}',
  );
}

LobbyScreen _lobby(WidgetTester tester) {
  final Finder finder = find.byType(LobbyScreen);
  expect(
    finder,
    findsOneWidget,
    reason:
        'the one pushed route must be a LobbyScreen (the connecting view '
        'of RoomRoute); found ${finder.evaluate().length}',
  );
  return tester.widget<LobbyScreen>(finder);
}

void _expectConnectingJoin(WidgetTester tester) {
  final LobbyScreen lobby = _lobby(tester);
  expect(lobby.action, LobbyAction.join);
  expect(
    lobby.code,
    _linkCode,
    reason:
        'LobbyScreen.code must be the link code while the connecting view '
        'is up; the connecting body does not paint the code itself',
  );
  expect(lobby.playerName, _knownName);
  expect(find.byKey(_connectingKey), findsOneWidget);
}

void _expectOneController(_RecordingControllerFactory factory) {
  expect(
    factory.controllers,
    hasLength(1),
    reason:
        'the link must build exactly one controller; built '
        '${factory.controllers.length}',
  );
  expect(factory.transports, hasLength(1));
}

/// Fires an unanswered join or resume timeout while the tree is still
/// mounted, unmounts so LobbyScreen can drop its listener, then disposes
/// the controller in the test body. [addTearDown] alone runs after the
/// pending-timer check.
Future<void> _disposeControllers(
  WidgetTester tester,
  _RecordingControllerFactory factory,
) async {
  if (factory.controllers.isEmpty) {
    return;
  }
  final bool connecting = factory.controllers.any(
    (RoomController controller) => controller.phase == RoomPhase.connecting,
  );
  if (connecting) {
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  factory.disposeAll();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('known player, valid cold link: one push and one join_room', (
    tester,
  ) async {
    _seedKnownPlayer();
    final _Mount mount = _prepare(tester);
    await _pumpHome(tester, mount);
    _expectKnownName(tester);

    final int pushesBefore = mount.observer.pushCount;
    final int popsBefore = mount.observer.popCount;
    final int replacesBefore = mount.observer.replaceCount;
    final int removesBefore = mount.observer.removeCount;

    mount.reader.complete(_validLink(_linkCode));
    await _pumpAfterLink(tester);

    expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
    expect(_codeFieldError(tester, skipOffstage: false), isNull);
    _expectNavigation(
      observer: mount.observer,
      pushesBefore: pushesBefore,
      popsBefore: popsBefore,
      replacesBefore: replacesBefore,
      removesBefore: removesBefore,
      pushDelta: 1,
      reason: 'known player, valid cold link',
    );
    _expectOneController(mount.factory);
    _expectConnectingJoin(tester);
    _expectJoinFrame(mount.factory.transports.single);
    await _disposeControllers(tester, mount.factory);
  });

  testWidgets('known player, valid warm link: one push and one join_room', (
    tester,
  ) async {
    _seedKnownPlayer();
    final _Mount mount = _prepare(tester);
    await _pumpHome(tester, mount);
    _expectKnownName(tester);

    mount.reader.complete(null);
    await tester.pump();

    final int pushesBefore = mount.observer.pushCount;
    final int popsBefore = mount.observer.popCount;
    final int replacesBefore = mount.observer.replaceCount;
    final int removesBefore = mount.observer.removeCount;

    mount.opener.add(_validLink(_linkCode));
    await _pumpAfterLink(tester);

    expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
    expect(_codeFieldError(tester, skipOffstage: false), isNull);
    _expectNavigation(
      observer: mount.observer,
      pushesBefore: pushesBefore,
      popsBefore: popsBefore,
      replacesBefore: replacesBefore,
      removesBefore: removesBefore,
      pushDelta: 1,
      reason: 'known player, valid warm link',
    );
    _expectOneController(mount.factory);
    _expectConnectingJoin(tester);
    _expectJoinFrame(mount.factory.transports.single);
    await _disposeControllers(tester, mount.factory);
  });

  testWidgets(
    'known player, seat record for the link code: resume, no join_room',
    (tester) async {
      _seedKnownPlayer(seatCode: _linkCode);
      final _Mount mount = _prepare(tester);
      await _pumpHome(tester, mount);
      _expectKnownName(tester);

      final int pushesBefore = mount.observer.pushCount;
      final int popsBefore = mount.observer.popCount;
      final int replacesBefore = mount.observer.replaceCount;
      final int removesBefore = mount.observer.removeCount;

      mount.reader.complete(_validLink(_linkCode));
      await _pumpAfterLink(tester);

      expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
      _expectNavigation(
        observer: mount.observer,
        pushesBefore: pushesBefore,
        popsBefore: popsBefore,
        replacesBefore: replacesBefore,
        removesBefore: removesBefore,
        pushDelta: 1,
        reason: 'known player, seat record for the link code',
      );
      _expectOneController(mount.factory);
      final LobbyScreen lobby = _lobby(tester);
      expect(lobby.action, LobbyAction.resume);
      expect(lobby.resume, _seatRecord(_linkCode));
      expect(find.byKey(_connectingKey), findsOneWidget);
      _expectResumeFrame(mount.factory.transports.single, code: _linkCode);
      await _disposeControllers(tester, mount.factory);
    },
  );

  testWidgets(
    'known player, seat record for a different code: join_room for the link',
    (tester) async {
      _seedKnownPlayer(seatCode: _otherCode);
      final _Mount mount = _prepare(tester);
      await _pumpHome(tester, mount);
      _expectKnownName(tester);

      final int pushesBefore = mount.observer.pushCount;
      final int popsBefore = mount.observer.popCount;
      final int replacesBefore = mount.observer.replaceCount;
      final int removesBefore = mount.observer.removeCount;

      mount.reader.complete(_validLink(_linkCode));
      await _pumpAfterLink(tester);

      expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
      _expectNavigation(
        observer: mount.observer,
        pushesBefore: pushesBefore,
        popsBefore: popsBefore,
        replacesBefore: replacesBefore,
        removesBefore: removesBefore,
        pushDelta: 1,
        reason: 'known player, seat record for a different code',
      );
      _expectOneController(mount.factory);
      _expectConnectingJoin(tester);
      _expectJoinFrame(mount.factory.transports.single);
      await _disposeControllers(tester, mount.factory);
    },
  );

  testWidgets(
    'first-time player: valid link fills the code and pushes nothing',
    (tester) async {
      final _Mount mount = _prepare(tester);
      await _pumpHome(tester, mount);

      expect(_fieldText(tester, _nameKey), isNot(_knownName));
      expect(find.byKey(_chipKey), findsNothing);

      final int pushesBefore = mount.observer.pushCount;
      final int popsBefore = mount.observer.popCount;
      final int replacesBefore = mount.observer.replaceCount;
      final int removesBefore = mount.observer.removeCount;

      mount.reader.complete(_validLink(_linkCode));
      await tester.pump();

      expect(_fieldText(tester, _codeKey), _linkCode);
      expect(_codeFieldError(tester), isNull);
      _expectNavigation(
        observer: mount.observer,
        pushesBefore: pushesBefore,
        popsBefore: popsBefore,
        replacesBefore: replacesBefore,
        removesBefore: removesBefore,
        pushDelta: 0,
        reason: 'first-time player, valid cold link',
      );
      expect(find.byType(LobbyScreen), findsNothing);
      expect(mount.factory.controllers, isEmpty);
    },
  );

  testWidgets(
    'known player, route already above home: warm link pushes and pops '
    'nothing',
    (tester) async {
      _seedKnownPlayer();
      final _Mount mount = _prepare(tester);
      await _pumpHome(tester, mount);
      _expectKnownName(tester);

      final BuildContext homeContext = tester.element(find.byType(HomeScreen));
      Navigator.of(homeContext).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(key: _aboveHomeKey),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(_aboveHomeKey), findsOneWidget);
      final int pushesBefore = mount.observer.pushCount;
      final int popsBefore = mount.observer.popCount;
      final int replacesBefore = mount.observer.replaceCount;
      final int removesBefore = mount.observer.removeCount;

      mount.opener.add(_validLink(_linkCode));
      await tester.pump();

      expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
      expect(find.byKey(_aboveHomeKey), findsOneWidget);
      _expectNavigation(
        observer: mount.observer,
        pushesBefore: pushesBefore,
        popsBefore: popsBefore,
        replacesBefore: replacesBefore,
        removesBefore: removesBefore,
        pushDelta: 0,
        reason: 'known player, route already above home',
      );
      expect(find.byType(LobbyScreen), findsNothing);
      expect(mount.factory.controllers, isEmpty);
    },
  );

  testWidgets(
    'known player, link before memory has loaded: one push after the load',
    (tester) async {
      _seedKnownPlayer();
      final _Mount mount = _prepare(
        tester,
        immediateLink: _validLink(_linkCode),
      );
      mount.observer.readNameOnAbovePush = () =>
          _optionalFieldText(tester, _nameKey);

      // No pumpAndSettle: the cold link is delivered inside this pump,
      // and a lobby ticker must not be chased if the push lands here.
      await tester.pumpWidget(_homeScreenApp(mount));

      final bool pushedInsideFirstPump = mount.observer.abovePushCount == 1;
      if (!pushedInsideFirstPump) {
        expect(
          mount.observer.abovePushCount,
          0,
          reason:
              'before the follow-up pumps, a held link must not have '
              'pushed more than once; got ${mount.observer.abovePushCount}',
        );
        expect(
          _optionalFieldText(tester, _nameKey),
          _knownName,
          reason:
              'the load must have applied the stored name before any '
              'later push; got "${_optionalFieldText(tester, _nameKey)}"',
        );
        expect(
          _optionalFieldText(tester, _codeKey),
          _linkCode,
          reason:
              'the link must already be applied to the code field while '
              'the push is still waiting on the load',
        );
      }

      await _pumpAfterLink(tester);

      expect(
        mount.observer.pushCount,
        2,
        reason:
            'known player, link before the load: exactly one push above '
            'the home route (pushCount 2) after the load; got '
            '${mount.observer.pushCount}',
      );
      expect(
        mount.observer.abovePushCount,
        1,
        reason:
            'known player, link before the load: exactly one push above '
            'home; got ${mount.observer.abovePushCount}',
      );
      expect(
        mount.observer.nameAtFirstAbovePush,
        _knownName,
        reason:
            'that push must be decided after the stored name is applied; '
            'name at push was "${mount.observer.nameAtFirstAbovePush}"',
      );
      expect(mount.observer.popCount, 0);
      expect(mount.observer.replaceCount, 0);
      expect(mount.observer.removeCount, 0);
      expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
      _expectOneController(mount.factory);
      _expectConnectingJoin(tester);
      _expectJoinFrame(mount.factory.transports.single);
      await _disposeControllers(tester, mount.factory);
    },
  );

  testWidgets(
    'known player, same link on the initial reader and the stream: one push',
    (tester) async {
      _seedKnownPlayer();
      final _Mount mount = _prepare(tester);
      await _pumpHome(tester, mount);
      _expectKnownName(tester);

      final int pushesBefore = mount.observer.pushCount;
      final int popsBefore = mount.observer.popCount;
      final int replacesBefore = mount.observer.replaceCount;
      final int removesBefore = mount.observer.removeCount;

      // Both sources in one turn, with no pump between them. The stream
      // listener runs inside add. The cold callback runs as the microtask
      // of this same turn, before the next frame.
      final Uri link = _validLink(_linkCode);
      mount.reader.complete(link);
      mount.opener.add(link);
      await _pumpAfterLink(tester);

      expect(_fieldText(tester, _codeKey, skipOffstage: false), _linkCode);
      _expectNavigation(
        observer: mount.observer,
        pushesBefore: pushesBefore,
        popsBefore: popsBefore,
        replacesBefore: replacesBefore,
        removesBefore: removesBefore,
        pushDelta: 1,
        reason: 'same valid link on the initial reader and the stream',
      );
      _expectOneController(mount.factory);
      _expectConnectingJoin(tester);
      _expectJoinFrame(mount.factory.transports.single);
      await _disposeControllers(tester, mount.factory);
    },
  );

  testWidgets('known player, invalid code link: error shown, nothing pushed', (
    tester,
  ) async {
    _seedKnownPlayer();
    final _Mount mount = _prepare(tester);
    await _pumpHome(tester, mount);
    _expectKnownName(tester);

    final int pushesBefore = mount.observer.pushCount;
    final int popsBefore = mount.observer.popCount;
    final int replacesBefore = mount.observer.replaceCount;
    final int removesBefore = mount.observer.removeCount;

    mount.reader.complete(_invalidCodeLink());
    // The entrance animation has already settled, so this pump only
    // flushes the link callback. The invalid-code error is state, not
    // controller text, and is painted by the frame that callback schedules.
    await tester.pump();
    await tester.pump();

    expect(_fieldText(tester, _codeKey), isEmpty);
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    expect(_codeFieldError(tester), loc.homeRoomCodeInvalid);
    _expectNavigation(
      observer: mount.observer,
      pushesBefore: pushesBefore,
      popsBefore: popsBefore,
      replacesBefore: replacesBefore,
      removesBefore: removesBefore,
      pushDelta: 0,
      reason: 'known player, invalid code link',
    );
    expect(find.byType(LobbyScreen), findsNothing);
    expect(mount.factory.controllers, isEmpty);
  });
}
