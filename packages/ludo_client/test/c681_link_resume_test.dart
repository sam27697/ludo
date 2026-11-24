// C-681t round 3: a dropped player who taps the link of the room they still
// hold a seat in resumes that seat (order 681, "round 3: RETURN 2", ruling R1;
// C-669 / X207).
//
// Written from the ruling alone. `SeatRecord` gains `final String linkId`
// (named, optional, default ''), part of ==/hashCode, persisted beside code,
// seat and token, filled from `snapshot.linkId` whenever a seat is recorded,
// and an old stored record reads back with linkId ''. A tapped link id equal
// to a stored record's NON-EMPTY linkId resumes that seat with a `resume`
// frame, no name needed, no `join_room`. Any other link joins by link. This
// file does not compile on a tree without `SeatRecord.linkId`, by design.
//
// What is pinned:
//   - matching link: one `resume` {code, seat_token}, no `join_room` frame of
//     any kind; with or without a stored name; upper-case URL folds; a link
//     delivered twice resumes once
//   - a different link id joins by link; a record with an empty linkId joins
//     by link; a record past kSeatRecordMaxAge is gone, so the link joins
//   - the record is filled from the room snapshot when the app stores a seat
//     (create here), and from an old server (no link_id) it stores ''
//   - persistence round trip of linkId, an old three-field record reads back
//     '', equality and clearSeatIf see the linkId
//   - a `kicked` frame leaves no record, linkId or not
//
// Replay: flutter test test/c681_link_resume_test.dart --plain-name '<id>'
// Nothing is random; every reason names the scenario and the frames sent.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:flutter_test/flutter_test.dart' as ft show testWidgets;
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/home_flow.dart';

const String _testUrl = 'wss://c681-link-resume.invalid/ws';
const String _code = 'AB23CD';
const String _otherCode = 'ZY98XW';
const String _linkId = 't5k2q9a-x7m3pd';
const String _otherLinkId = 'q8w4e2r-z9x5cv';
const int _seat = 2;
const String _token = 'tok-c681-lr-001';
const String _knownName = 'Nour';

const Key _createKey = Key('create-room-button');

const String _namePrefsKey = 'session.lastName';
const String _seatsPrefsKey = 'session.lastSeats';
const String _seatPrefsKey = 'session.seat';

Uri _linkFor(String id) => Uri.parse('https://ludo.provefair.app/r/$id');

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String sent) => _decode(sent)['t']! as String;
String _idOf(String sent) => _decode(sent)['id']! as String;
Map<String, Object?> _dataOf(String sent) =>
    _decode(sent)['d']! as Map<String, Object?>;

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
    'id': 'c681-lr-id-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _roomJson({String? linkId = _linkId, String? code}) =>
    <String, Object?>{
      'code': code ?? _code,
      'state': 'LOBBY',
      'host_seat': 0,
      'players': 4,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': 'a' * 64,
      'chain_index': 0,
      'game_id': null,
      'client_seeds': null,
      'seats': <Map<String, Object?>>[
        <String, Object?>{
          'seat': 0,
          'name': 'Nour',
          'connected': true,
          'tokens': const <int>[-1, -1, -1, -1],
          'client_seed': null,
          'seed_origin': null,
        },
      ],
      'turn': null,
      'winner': null,
      'seq': 1,
      'link_id': ?linkId,
    };

SeatRecord _record({String linkId = '', String code = _code}) =>
    SeatRecord(code: code, seat: _seat, seatToken: _token, linkId: linkId);

/// Stores [record] the way the app does, then optionally drops the saved time
/// so Home does not resume on its own at mount (it offers Rejoin instead).
Future<void> _store(
  WidgetTester tester,
  SeatRecord record, {
  String? name = _knownName,
  DateTime Function()? clock,
  bool dropSavedAt = false,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    _namePrefsKey: ?name,
    if (name != null) _seatsPrefsKey: 4,
  });
  await tester.runAsync(() async {
    await SessionMemory.recordSeat(record, clock: clock);
    if (dropSavedAt) {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('session.seatSavedAt');
    }
  });
}

// ---------------------------------------------------------------- harness

class _Reader {
  _Reader(this.immediate);
  final Uri? immediate;
  final Completer<Uri?> _c = Completer<Uri?>();
  Future<Uri?> call() =>
      immediate != null ? Future<Uri?>.value(immediate) : _c.future;
  void complete(Uri? uri) {
    if (!_c.isCompleted) {
      _c.complete(uri);
    }
  }
}

class _Opener {
  final StreamController<Uri> _c = StreamController<Uri>.broadcast();
  Stream<Uri> call() => _c.stream;
  void add(Uri uri) => _c.add(uri);
  Future<void> close() => _c.close();
}

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

  List<String> get allSent => <String>[
    for (final FakeTransport t in transports) ...t.sentRaw,
  ];

  void disposeAll() {
    final List<RoomController> pending = List<RoomController>.of(controllers);
    controllers.clear();
    for (final RoomController controller in pending) {
      controller.dispose();
    }
  }
}

class _Mount {
  _Mount(this.id, this.factory, this.reader, this.opener);
  final String id;
  final _Factory factory;
  final _Reader reader;
  final _Opener opener;

  String get why =>
      '$id: sent ${factory.allSent.map(_typeOf).toList()}. reproduce: '
      "flutter test test/c681_link_resume_test.dart --plain-name '$id'";
}

_Mount _prepare(WidgetTester tester, String id, {Uri? immediateLink}) {
  final _Mount mount = _Mount(
    id,
    _Factory(),
    _Reader(immediateLink),
    _Opener(),
  );
  addTearDown(mount.factory.disposeAll);
  addTearDown(mount.opener.close);
  if (immediateLink == null) {
    addTearDown(() => mount.reader.complete(null));
  }
  return mount;
}

Future<void> _pumpHome(WidgetTester tester, _Mount mount) async {
  await tester.pumpWidget(
    MaterialApp(
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(
        onToggleLocale: () {},
        controllerFactory: mount.factory.call,
        initialLinkReader: mount.reader.call,
        linkStream: mount.opener.call,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpAfterLink(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Retires every controller inside the test body, as the app does, so the
/// request timer of a frame nobody answered is not pending at the invariant
/// check.
Future<void> _retire(WidgetTester tester, _Mount mount) async {
  if (mount.factory.controllers.isEmpty) {
    return;
  }
  await tester.pump(const Duration(seconds: 11));
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  mount.factory.disposeAll();
  await tester.pump();
}

void _expectResumeOnly(_Mount mount, {required String code}) {
  final List<String> types = mount.factory.allSent.map(_typeOf).toList();
  expect(
    types,
    isNot(contains('join_room')),
    reason:
        'expected the tapped link to resume the held seat and send no '
        'join_room; sent $types. ${mount.why}',
  );
  expect(types, <String>[
    'resume',
  ], reason: 'expected exactly one resume frame; sent $types. ${mount.why}');
  expect(
    _dataOf(mount.factory.allSent.single),
    <String, Object?>{'code': code, 'seat_token': _token},
    reason:
        'expected resume to carry the stored (code, seat_token) verbatim. '
        '${mount.why}',
  );
}

void _expectJoinByLinkOnly(_Mount mount, String linkId) {
  final List<String> types = mount.factory.allSent.map(_typeOf).toList();
  expect(
    types,
    <String>['join_room'],
    reason:
        'expected one join_room by link and no resume; sent $types. '
        '${mount.why}',
  );
  final Map<String, Object?> body = <String, Object?>{
    ..._dataOf(mount.factory.allSent.single),
  };
  expect(
    body['link'],
    linkId,
    reason:
        'expected the join to carry link "$linkId"; sent $body. '
        '${mount.why}',
  );
  expect(
    body.containsKey('code'),
    isFalse,
    reason: 'expected no code beside link; sent $body. ${mount.why}',
  );
}

LobbyScreen _lobby(WidgetTester tester) =>
    tester.widget<LobbyScreen>(find.byType(LobbyScreen));

// ------------------------------------------------------- controller harness

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  void enqueue(FakeTransport t) => _queue.add(t);
  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: nothing queued');
    }
    return _queue.removeAt(0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // ---------------------------------------------------- resume by link id

  group('a link equal to the held seat\'s link id resumes', () {
    ft.testWidgets('cold link, known player: one resume, no join_room', (
      tester,
    ) async {
      await _store(tester, _record(linkId: _linkId), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'resume.cold_known');
      await _pumpHome(tester, mount);
      final int pushes = mount.factory.controllers.length;
      mount.reader.complete(_linkFor(_linkId));
      await _pumpAfterLink(tester);

      expect(
        mount.factory.controllers.length,
        pushes + 1,
        reason: 'expected one controller for the resume. ${mount.why}',
      );
      final LobbyScreen lobby = _lobby(tester);
      expect(
        lobby.action,
        LobbyAction.resume,
        reason: 'expected the lobby route to be a resume. ${mount.why}',
      );
      expect(
        lobby.resume,
        _record(linkId: _linkId),
        reason: 'expected the stored record to be resumed. ${mount.why}',
      );
      _expectResumeOnly(mount, code: _code);
      await _retire(tester, mount);
    });

    ft.testWidgets('warm link through the stream resumes too', (tester) async {
      await _store(tester, _record(linkId: _linkId), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'resume.warm_known');
      await _pumpHome(tester, mount);
      mount.opener.add(_linkFor(_linkId));
      await _pumpAfterLink(tester);
      _expectResumeOnly(mount, code: _code);
      await _retire(tester, mount);
    });

    ft.testWidgets('no stored name: resume needs no name', (tester) async {
      await _store(
        tester,
        _record(linkId: _linkId),
        name: null,
        dropSavedAt: true,
      );
      final _Mount mount = _prepare(tester, 'resume.no_name');
      await _pumpHome(tester, mount);
      mount.reader.complete(_linkFor(_linkId));
      await _pumpAfterLink(tester);
      _expectResumeOnly(mount, code: _code);
      await _retire(tester, mount);
    });

    ft.testWidgets('an upper-case URL folds to the stored lower-case id', (
      tester,
    ) async {
      await _store(tester, _record(linkId: _linkId), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'resume.upper_case');
      await _pumpHome(tester, mount);
      mount.opener.add(_linkFor(_linkId.toUpperCase()));
      await _pumpAfterLink(tester);
      _expectResumeOnly(mount, code: _code);
      await _retire(tester, mount);
    });

    ft.testWidgets('trailing slash still matches', (tester) async {
      await _store(tester, _record(linkId: _linkId), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'resume.trailing_slash');
      await _pumpHome(tester, mount);
      mount.opener.add(Uri.parse('https://ludo.provefair.app/r/$_linkId/'));
      await _pumpAfterLink(tester);
      _expectResumeOnly(mount, code: _code);
      await _retire(tester, mount);
    });

    ft.testWidgets('the same link delivered twice resumes once', (
      tester,
    ) async {
      await _store(tester, _record(linkId: _linkId), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'resume.replayed');
      await _pumpHome(tester, mount);
      mount.opener.add(_linkFor(_linkId));
      mount.opener.add(_linkFor(_linkId));
      await _pumpAfterLink(tester);
      expect(
        mount.factory.controllers,
        hasLength(1),
        reason:
            'a replayed link must not build a second controller; built '
            '${mount.factory.controllers.length}. ${mount.why}',
      );
      _expectResumeOnly(mount, code: _code);
      await _retire(tester, mount);
    });
  });

  // ------------------------------------------------------ join by link id

  group('every other link joins by link', () {
    ft.testWidgets('a different link id joins by link, no resume', (
      tester,
    ) async {
      await _store(tester, _record(linkId: _linkId), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'join.other_link');
      await _pumpHome(tester, mount);
      mount.reader.complete(_linkFor(_otherLinkId));
      await _pumpAfterLink(tester);
      _expectJoinByLinkOnly(mount, _otherLinkId);
      final LobbyScreen lobby = _lobby(tester);
      expect(
        lobby.action,
        LobbyAction.join,
        reason: 'expected a join route for a foreign link. ${mount.why}',
      );
      expect(
        lobby.resume,
        isNull,
        reason: 'expected no resume record on a join. ${mount.why}',
      );
      await _retire(tester, mount);
    });

    ft.testWidgets('a record with an empty linkId joins by link', (
      tester,
    ) async {
      await _store(tester, _record(), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'join.empty_record_link');
      await _pumpHome(tester, mount);
      mount.reader.complete(_linkFor(_linkId));
      await _pumpAfterLink(tester);
      _expectJoinByLinkOnly(mount, _linkId);
      await _retire(tester, mount);
    });

    ft.testWidgets('an old three-field stored record joins by link', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: _knownName,
        _seatsPrefsKey: 4,
        _seatPrefsKey: <String>[_code, '$_seat', _token],
      });
      final _Mount mount = _prepare(tester, 'join.old_stored_record');
      await _pumpHome(tester, mount);
      mount.opener.add(_linkFor(_linkId));
      await _pumpAfterLink(tester);
      _expectJoinByLinkOnly(mount, _linkId);
      await _retire(tester, mount);
    });

    ft.testWidgets('an empty record linkId never matches an empty-looking '
        'link: a bad link id sends nothing', (tester) async {
      await _store(tester, _record(), dropSavedAt: true);
      final _Mount mount = _prepare(tester, 'join.bad_link_empty_record');
      await _pumpHome(tester, mount);
      mount.opener.add(Uri.parse('https://ludo.provefair.app/r/'));
      await _pumpAfterLink(tester);
      expect(
        mount.factory.allSent,
        isEmpty,
        reason:
            'a link with no id must not resume or join; sent '
            '${mount.factory.allSent.map(_typeOf).toList()}. ${mount.why}',
      );
      await _retire(tester, mount);
    });

    ft.testWidgets('a record older than kSeatRecordMaxAge is gone: the link '
        'joins', (tester) async {
      await _store(
        tester,
        _record(linkId: _linkId),
        clock: () => DateTime.now().subtract(
          kSeatRecordMaxAge + const Duration(minutes: 5),
        ),
      );
      final _Mount mount = _prepare(tester, 'join.stale_record');
      await _pumpHome(tester, mount);
      mount.opener.add(_linkFor(_linkId));
      await _pumpAfterLink(tester);
      _expectJoinByLinkOnly(mount, _linkId);
      await _retire(tester, mount);
    });
  });

  // -------------------------------------- the record is filled when stored

  group('the record carries the room\'s link id', () {
    Future<SeatRecord?> createAndRead(
      WidgetTester tester,
      String id,
      String? linkId,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _namePrefsKey: _knownName,
        _seatsPrefsKey: 4,
      });
      final _Mount mount = _prepare(tester, id);
      await _pumpHome(tester, mount);
      await tester.ensureVisible(find.byKey(_createKey));
      await tapCreateRoom(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final FakeTransport transport = mount.factory.transports.single;
      final String create = transport.sentRaw.firstWhere(
        (String s) => _typeOf(s) == 'create_room',
      );
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': 0, 'seat_token': _token},
        ),
      );
      transport.pushText(
        _frame(
          type: 'room',
          re: _idOf(create),
          data: _roomJson(linkId: linkId),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final SessionMemory memory = (await tester.runAsync(SessionMemory.load))!;
      await _retire(tester, mount);
      return memory.seatRecord;
    }

    ft.testWidgets('create: the stored seat has snapshot.linkId', (
      tester,
    ) async {
      final SeatRecord? stored = await createAndRead(
        tester,
        'fill.create_with_link',
        _linkId,
      );
      expect(
        stored,
        isNotNull,
        reason: 'expected a stored seat record after a create. fill.create',
      );
      expect(
        stored!.linkId,
        _linkId,
        reason:
            'expected the stored record to carry the room link id '
            '"$_linkId"; got "${stored.linkId}". fill.create_with_link',
      );
    });

    ft.testWidgets('an old server (no link_id) stores an empty linkId', (
      tester,
    ) async {
      final SeatRecord? stored = await createAndRead(
        tester,
        'fill.create_old_server',
        null,
      );
      expect(
        stored,
        isNotNull,
        reason: 'expected a stored seat record. fill.create_old_server',
      );
      expect(
        stored!.linkId,
        '',
        reason:
            'expected an empty linkId from a server without link_id; got '
            '"${stored.linkId}". fill.create_old_server',
      );
    });
  });

  // ------------------------------------------------------------ persistence

  group('SeatRecord.linkId in session memory', () {
    test('the default is empty and it takes part in ==/hashCode', () {
      const SeatRecord plain = SeatRecord(
        code: _code,
        seat: _seat,
        seatToken: _token,
      );
      expect(plain.linkId, '', reason: 'expected the default linkId to be ""');
      expect(plain, _record());
      expect(plain.hashCode, _record().hashCode);
      final SeatRecord linked = _record(linkId: _linkId);
      expect(
        linked == plain,
        isFalse,
        reason: 'expected records differing only in linkId to be unequal',
      );
      expect(
        linked,
        _record(linkId: _linkId),
        reason: 'expected equal linkIds to be equal',
      );
      expect(linked.hashCode, _record(linkId: _linkId).hashCode);
      expect(
        linked == _record(linkId: _otherLinkId),
        isFalse,
        reason: 'expected different linkIds to be unequal',
      );
    });

    ft.testWidgets('round trip: record, load, equal with linkId', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SessionMemory? loaded = await tester.runAsync(() async {
        await SessionMemory.recordSeat(_record(linkId: _linkId));
        return SessionMemory.load();
      });
      expect(
        loaded!.seatRecord,
        _record(linkId: _linkId),
        reason: 'expected the linkId to survive a store and load',
      );
      expect(loaded.seatRecord!.linkId, _linkId);
    });

    ft.testWidgets('round trip survives a second load (new prefs read)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SessionMemory? loaded = await tester.runAsync(() async {
        await SessionMemory.recordSeat(_record(linkId: _linkId));
        await SessionMemory.load();
        return SessionMemory.load();
      });
      expect(
        loaded!.seatRecord?.linkId,
        _linkId,
        reason: 'expected the linkId to survive two loads',
      );
    });

    ft.testWidgets('an empty linkId round trips as empty', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SessionMemory? loaded = await tester.runAsync(() async {
        await SessionMemory.recordSeat(_record());
        return SessionMemory.load();
      });
      expect(loaded!.seatRecord, _record());
      expect(loaded.seatRecord!.linkId, '');
    });

    ft.testWidgets('an old stored record (code, seat, token) reads back ""', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _seatPrefsKey: <String>[_code, '$_seat', _token],
      });
      final SessionMemory? loaded = await tester.runAsync(SessionMemory.load);
      expect(
        loaded!.seatRecord,
        isNotNull,
        reason: 'expected an old three-field record to stay readable',
      );
      expect(loaded.seatRecord!.linkId, '');
      expect(loaded.seatRecord!.code, _code);
      expect(loaded.seatRecord!.seat, _seat);
      expect(loaded.seatRecord!.seatToken, _token);
    });

    ft.testWidgets('a new record written over an old one replaces its linkId', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SessionMemory? loaded = await tester.runAsync(() async {
        await SessionMemory.recordSeat(_record(linkId: _linkId));
        await SessionMemory.recordSeat(
          _record(linkId: _otherLinkId, code: _otherCode),
        );
        return SessionMemory.load();
      });
      expect(
        loaded!.seatRecord,
        _record(linkId: _otherLinkId, code: _otherCode),
        reason: 'expected the newest record to win, linkId included',
      );
    });

    ft.testWidgets('clearSeatIf compares the linkId too', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SessionMemory? after = await tester.runAsync(() async {
        await SessionMemory.recordSeat(_record(linkId: _linkId));
        await SessionMemory.clearSeatIf(_record());
        return SessionMemory.load();
      });
      expect(
        after!.seatRecord,
        _record(linkId: _linkId),
        reason:
            'expected clearSeatIf with a record that differs only in linkId '
            'to leave the stored record alone',
      );
      final SessionMemory? cleared = await tester.runAsync(() async {
        await SessionMemory.clearSeatIf(_record(linkId: _linkId));
        return SessionMemory.load();
      });
      expect(
        cleared!.seatRecord,
        isNull,
        reason: 'expected clearSeatIf with an equal record to clear it',
      );
    });

    ft.testWidgets('clearSeat removes a record that has a linkId', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SessionMemory? after = await tester.runAsync(() async {
        await SessionMemory.recordSeat(_record(linkId: _linkId));
        await SessionMemory.clearSeat();
        return SessionMemory.load();
      });
      expect(after!.seatRecord, isNull);
    });

    test('toString never prints the token', () {
      expect(
        _record(linkId: _linkId).toString(),
        isNot(contains(_token)),
        reason: 'expected the seat token to stay out of toString',
      );
    });
  });

  // ----------------------------------------------------------------- kicked

  group('a kicked frame leaves no record', () {
    Future<void> kickedLeavesNothing(
      WidgetTester tester,
      String id,
      SeatRecord record,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _Connector connector = _Connector();
      final FakeTransport transport = FakeTransport();
      connector.enqueue(transport);
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
        autoReconnectDelays: const <Duration>[],
      );
      await tester.runAsync(() => SessionMemory.recordSeat(record));
      final Future<void> pending = controller.joinByLink(
        link: _linkId,
        name: 'Bob',
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      transport.pushText(
        _frame(
          type: 'seat_assigned',
          data: <String, Object?>{'seat': _seat, 'seat_token': _token},
        ),
      );
      transport.pushText(
        _frame(
          type: 'room',
          re: _idOf(transport.sentRaw.last),
          data: _roomJson(),
        ),
      );
      await pending;
      transport.pushText(_frame(type: 'kicked'));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final String why =
          '$id: sent ${transport.sentRaw.map(_typeOf).toList()}. reproduce: '
          "flutter test test/c681_link_resume_test.dart --plain-name '$id'";
      expect(
        controller.wasKicked,
        isTrue,
        reason: 'expected wasKicked after the frame. $why',
      );
      final SessionMemory? after = await tester.runAsync(SessionMemory.load);
      expect(
        after!.seatRecord,
        isNull,
        reason:
            'expected no stored seat record after kicked (a link tap must '
            'then join, never resume); saw ${after.seatRecord}. $why',
      );
      controller.dispose();
      await tester.pump(const Duration(seconds: 11));
    }

    ft.testWidgets('a record with a linkId is cleared', (tester) async {
      await kickedLeavesNothing(
        tester,
        'kicked.record_with_link',
        _record(linkId: _linkId),
      );
    });

    ft.testWidgets('a record with an empty linkId is cleared', (tester) async {
      await kickedLeavesNothing(
        tester,
        'kicked.record_without_link',
        _record(),
      );
    });
  });
}
