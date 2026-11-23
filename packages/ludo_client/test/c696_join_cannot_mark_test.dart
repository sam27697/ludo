// C-696t: one mark for every "you cannot join" (X215, P2).
//
// Rulings of run 166. A card or notice that tells this player they cannot get
// into this room wears the red refusal mark: exactly one RefusalNoticeMark
// holding Icons.cancel_rounded, and never Icons.info_outline_rounded in the
// same card. A card about a network failure, a wait, or a game that simply
// ended keeps the neutral mark. Text, buttons and retry rules do not move.
//
//   Lobby error card (lobby-error-card)
//     red:     NO_SUCH_ROOM (typed code and link join), ROOM_FULL,
//              ROOM_STARTED, KICKED, KNOCK_REFUSED, CODE_BANNED,
//              TOO_MANY_KNOCKS
//     neutral: transport, timeout, closed, RATE_LIMITED, BAD_SEAT_TOKEN,
//              BAD_FIELD, an unknown code
//   Home notice (home-notice)
//     red:     knock not joined, full, switched off, kicked
//     neutral: room closed (host, guest), game gone, removed
//
// Every row runs in en and ar at 393x851. Text and the presence of
// lobby-retry-button are asserted as they are before the change.
//
// Replay one row:
//   flutter test test/c696_join_cannot_mark_test.dart --plain-name '<id>'

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/code_ban_notice.dart'
    show RefusalNoticeMark, kRefusalNoticeFrame;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c696-test.invalid/ws';
const String _code = 'K7M2QP';
const String _token = 'tok-c696-001';
const Key _createKey = Key('create-room-button');
const Key _codeFieldKey = Key('room-code-field');
const Key _joinKey = Key('join-room-button');
const Key _errorCardKey = Key('lobby-error-card');
const Key _retryKey = Key('lobby-retry-button');
const Key _noticeKey = Key('home-notice');

String _replay(String id) =>
    "flutter test test/c696_join_cannot_mark_test.dart --plain-name '$id'";

// ---------------------------------------------------------------- wire

int _serverIdSeq = 0;
String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c696-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;
String _typeOf(String raw) => _decode(raw)['t']! as String;
String _idOf(String raw) => _decode(raw)['id']! as String;

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
  'via': seat == 0 ? 'host' : 'code',
};

Map<String, Object?> _lobbyRoom() => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 2,
  'rules': const <String, Object?>{
    'blocks': false,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[_seatJson(0, 'Host'), _seatJson(1, 'Guest')],
  'turn': null,
  'winner': null,
  'seq': 3,
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

void _answerError(FakeTransport t, String requestId, String code) {
  t.pushText(
    _frame('error', <String, Object?>{
      'code': code,
      'message': '',
    }, re: requestId),
  );
}

void _answerRoom(FakeTransport t, String requestId, {required int seat}) {
  t.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': seat,
      'seat_token': _token,
    }),
  );
  t.pushText(_frame('room', _lobbyRoom(), re: requestId));
}

// ---------------------------------------------------------------- rig

class _TrackedController extends RoomController {
  _TrackedController({required super.serverUrl, required super.connect});

  bool wasDisposed = false;

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

class _Rig {
  final List<_TrackedController> controllers = <_TrackedController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  Future<WireTransport> _connect(Uri url) async {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    return transport;
  }

  RoomController call() {
    final _TrackedController c = _TrackedController(
      serverUrl: Uri.parse(_testUrl),
      connect: _connect,
    );
    controllers.add(c);
    return c;
  }

  FakeTransport get last => transports.last;

  List<String> sent(String type) => <String>[
    for (final FakeTransport t in transports)
      for (final String s in t.sentRaw)
        if (_typeOf(s) == type) s,
  ];

  String lastRequestId(String type) => _idOf(sent(type).last);

  void disposeAll() {
    for (final _TrackedController c in controllers) {
      if (!c.wasDisposed) {
        c.dispose();
      }
    }
  }
}

const List<LocalizationsDelegate<dynamic>> _delegates =
    <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(393, 851);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _pumpBounded(WidgetTester tester, {int frames = 6}) async {
  for (int i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 11));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester, Type screen) =>
    AppLocalizations.of(tester.element(find.byType(screen).first));

// ---------------------------------------------------------------- marks

String _found(WidgetTester tester, Finder card) {
  final bool mark = find
      .descendant(of: card, matching: find.byType(RefusalNoticeMark))
      .evaluate()
      .isNotEmpty;
  final int marks = find
      .descendant(of: card, matching: find.byType(RefusalNoticeMark))
      .evaluate()
      .length;
  final List<String> icons = <String>[
    for (final Element e
        in find.descendant(of: card, matching: find.byType(Icon)).evaluate())
      '${(e.widget as Icon).icon}',
  ];
  return 'RefusalNoticeMark present=$mark (count $marks), icons=$icons';
}

Finder _iconIn(Finder scope, IconData icon) => find.descendant(
  of: scope,
  matching: find.byWidgetPredicate((Widget w) => w is Icon && w.icon == icon),
);

/// Red: one RefusalNoticeMark, Icons.cancel_rounded inside it, no neutral info
/// icon anywhere in the card.
void _expectRed(
  WidgetTester tester,
  Finder card, {
  required String surface,
  required String code,
  required String locale,
  required String replay,
}) {
  final String what = '$surface, $code, $locale';
  expect(
    card,
    findsOneWidget,
    reason: 'expected exactly one card for "$what". reproduce: $replay',
  );
  final Finder mark = find.descendant(
    of: card,
    matching: find.byType(RefusalNoticeMark),
  );
  expect(
    mark,
    findsOneWidget,
    reason:
        'expected exactly one RefusalNoticeMark (red = you cannot) in the '
        'card for "$what"; found ${_found(tester, card)}. reproduce: $replay',
  );
  expect(
    _iconIn(mark, Icons.cancel_rounded),
    findsOneWidget,
    reason:
        'expected Icons.cancel_rounded inside the RefusalNoticeMark for '
        '"$what"; found ${_found(tester, card)}. reproduce: $replay',
  );
  expect(
    _iconIn(card, Icons.info_outline_rounded),
    findsNothing,
    reason:
        'expected no Icons.info_outline_rounded in the card for "$what"; '
        'found ${_found(tester, card)}. reproduce: $replay',
  );
}

/// Neutral: no RefusalNoticeMark, and exactly the neutral icon the card shows
/// today.
void _expectNeutral(
  WidgetTester tester,
  Finder card,
  IconData icon, {
  required String surface,
  required String code,
  required String locale,
  required String replay,
  bool onlyIcon = true,
}) {
  final String what = '$surface, $code, $locale';
  expect(
    card,
    findsOneWidget,
    reason: 'expected exactly one card for "$what". reproduce: $replay',
  );
  expect(
    find.descendant(of: card, matching: find.byType(RefusalNoticeMark)),
    findsNothing,
    reason:
        'expected no RefusalNoticeMark (nobody refused this player) in the '
        'card for "$what"; found ${_found(tester, card)}. reproduce: $replay',
  );
  expect(
    _iconIn(card, icon),
    findsOneWidget,
    reason:
        'expected the neutral $icon in the card for "$what"; found '
        '${_found(tester, card)}. reproduce: $replay',
  );
  // The home card also holds its dismiss control's icon.
  expect(
    find.descendant(of: card, matching: find.byType(Icon)),
    onlyIcon ? findsOneWidget : findsNWidgets(2),
    reason:
        'expected ${onlyIcon ? 'exactly one Icon' : 'the mark and the dismiss Icon'} in the neutral card for "$what"; found '
        '${_found(tester, card)}. reproduce: $replay',
  );
}

void _expectText(
  Finder card,
  String text, {
  required String surface,
  required String code,
  required String locale,
  required String replay,
}) {
  expect(
    find.descendant(of: card, matching: find.text(text)),
    findsOneWidget,
    reason:
        'expected the card text "$text" for "$surface, $code, $locale"; texts '
        'inside: ${find.descendant(of: card, matching: find.byType(Text)).evaluate().map((Element e) => (e.widget as Text).data).toList()}. '
        'reproduce: $replay',
  );
}

// ---------------------------------------------------------------- lobby

enum _Drive { answer, connectFails, timeout, farSideEnds }

class _LobbyRow {
  const _LobbyRow(
    this.label,
    this.code,
    this.red,
    this.retry, {
    this.link = false,
    this.drive = _Drive.answer,
  });

  /// The row name in test ids and messages.
  final String label;

  /// The frame code answered, or the controller code the drive produces.
  final String code;
  final bool red;

  /// Whether lobby-retry-button is offered today.
  final bool retry;
  final bool link;
  final _Drive drive;
}

const List<_LobbyRow> _lobbyRows = <_LobbyRow>[
  // Red.
  _LobbyRow('NO_SUCH_ROOM typed', 'NO_SUCH_ROOM', true, false),
  _LobbyRow('NO_SUCH_ROOM link', 'NO_SUCH_ROOM', true, false, link: true),
  _LobbyRow('ROOM_FULL', 'ROOM_FULL', true, true),
  _LobbyRow('ROOM_STARTED', 'ROOM_STARTED', true, false),
  _LobbyRow('KICKED', 'KICKED', true, false),
  _LobbyRow('KNOCK_REFUSED', 'KNOCK_REFUSED', true, false),
  _LobbyRow('CODE_BANNED', 'CODE_BANNED', true, false),
  _LobbyRow('TOO_MANY_KNOCKS', 'TOO_MANY_KNOCKS', true, true),
  // Neutral.
  _LobbyRow('transport', 'transport', false, true, drive: _Drive.connectFails),
  _LobbyRow('timeout', 'timeout', false, true, drive: _Drive.timeout),
  _LobbyRow('closed', 'closed', false, true, drive: _Drive.farSideEnds),
  _LobbyRow('RATE_LIMITED', 'RATE_LIMITED', false, true),
  _LobbyRow('BAD_SEAT_TOKEN', 'BAD_SEAT_TOKEN', false, true),
  _LobbyRow('BAD_FIELD', 'BAD_FIELD', false, false),
  _LobbyRow('unknown code', 'SOMETHING_ELSE', false, true),
];

String _lobbyText(AppLocalizations loc, _LobbyRow row) {
  if (row.link) {
    return loc.lobbyErrorLinkRoomGone;
  }
  switch (row.code) {
    case 'NO_SUCH_ROOM':
      return loc.lobbyErrorNoSuchRoom;
    case 'ROOM_FULL':
      return loc.lobbyErrorRoomFull;
    case 'ROOM_STARTED':
      return loc.lobbyErrorRoomStarted;
    case 'KICKED':
      return loc.knockWasKicked;
    case 'KNOCK_REFUSED':
      return loc.lobbyErrorKnockRefused;
    case 'CODE_BANNED':
      return loc.lobbyErrorCodeBanned;
    case 'TOO_MANY_KNOCKS':
      return loc.lobbyErrorTooManyKnocks;
    case 'RATE_LIMITED':
      return loc.lobbyErrorRateLimited;
    case 'transport':
      return loc.lobbyErrorTransport;
    default:
      return loc.lobbyErrorGeneric;
  }
}

Future<void> _lobbyCase(
  WidgetTester tester,
  _LobbyRow row,
  Locale locale,
) async {
  final String lc = locale.languageCode;
  final String id = 'lobby $lc ${row.label}';
  final String replay = _replay(id);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  _phone(tester);
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: (Uri url) async {
      if (row.drive == _Drive.connectFails) {
        throw StateError('c696: connect rejected');
      }
      return transport as WireTransport;
    },
    autoReconnectDelays: const <Duration>[],
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: _delegates,
      home: LobbyScreen(
        controller: controller,
        action: LobbyAction.join,
        code: _code,
        playerName: 'Sam',
        fromLink: row.link,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  switch (row.drive) {
    case _Drive.answer:
      expect(
        transport.sentRaw,
        isNotEmpty,
        reason: 'fixture: the join was not sent. reproduce: $replay',
      );
      _answerError(transport, _idOf(transport.sentRaw.last), row.code);
    case _Drive.connectFails:
      break;
    case _Drive.timeout:
      await tester.pump(const Duration(seconds: 11));
    case _Drive.farSideEnds:
      transport.endFromFarSide();
  }
  await tester.pump();
  await tester.pump();
  expect(
    controller.errorCode,
    row.code,
    reason:
        'fixture: expected controller.errorCode "${row.code}" for "$id", got '
        '"${controller.errorCode}". reproduce: $replay',
  );
  final Finder card = find.byKey(_errorCardKey);
  final AppLocalizations loc = _locOf(tester, LobbyScreen);
  if (row.red) {
    _expectRed(
      tester,
      card,
      surface: 'lobby error card',
      code: row.label,
      locale: lc,
      replay: replay,
    );
  } else {
    _expectNeutral(
      tester,
      card,
      row.code == 'transport'
          ? Icons.wifi_off_rounded
          : Icons.info_outline_rounded,
      surface: 'lobby error card',
      code: row.label,
      locale: lc,
      replay: replay,
    );
  }
  _expectText(
    card,
    _lobbyText(loc, row),
    surface: 'lobby error card',
    code: row.label,
    locale: lc,
    replay: replay,
  );
  expect(
    find.descendant(of: card, matching: find.byKey(_retryKey)),
    row.retry ? findsOneWidget : findsNothing,
    reason:
        'expected lobby-retry-button ${row.retry ? 'present' : 'absent'} for '
        '"lobby error card, ${row.label}, $lc"; found '
        '${find.byKey(_retryKey).evaluate().length}. reproduce: $replay',
  );
  await _unmount(tester);
}

// ---------------------------------------------------------------- home

enum _HomeRow {
  notJoined(true, 'knock not joined'),
  full(true, 'knock full'),
  switchedOff(true, 'knock switched off'),
  kicked(true, 'kicked'),
  roomClosedHost(false, 'room closed host'),
  roomClosedGuest(false, 'room closed guest'),
  gameGone(false, 'game gone'),
  removed(false, 'removed');

  const _HomeRow(this.red, this.label);
  final bool red;
  final String label;
}

String _homeText(AppLocalizations loc, _HomeRow row) => switch (row) {
  _HomeRow.notJoined => loc.knockOutcomeNotJoined,
  _HomeRow.full => loc.knockOutcomeFull,
  _HomeRow.switchedOff => loc.knockOutcomeSwitchedOff,
  _HomeRow.kicked => loc.knockWasKicked,
  _HomeRow.roomClosedHost => loc.homeRoomClosedHostNotice,
  _HomeRow.roomClosedGuest => loc.homeRoomClosedGuestNotice,
  _HomeRow.gameGone => loc.homeGameGoneNotice,
  _HomeRow.removed => loc.homeRemovedNotice,
};

Widget _homeApp(_Rig rig, Locale locale) => MaterialApp(
  locale: locale,
  supportedLocales: appSupportedLocales,
  localizationsDelegates: _delegates,
  home: HomeScreen(onToggleLocale: () {}, controllerFactory: rig.call),
);

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _typeAndJoin(WidgetTester tester, _Rig rig, String id) async {
  await tester.enterText(find.byKey(_codeFieldKey), _code);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _tap(tester, _joinKey);
  for (int i = 0; i < 30 && rig.sent('join_room').isEmpty; i += 1) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    rig.sent('join_room'),
    hasLength(1),
    reason:
        'fixture: expected one join_room for "$id". reproduce: ${_replay(id)}',
  );
}

Future<void> _hostLobby(WidgetTester tester, _Rig rig, String id) async {
  await _tap(tester, _createKey);
  expect(
    rig.sent('create_room'),
    hasLength(1),
    reason: 'fixture: Create must send one create_room for "$id"',
  );
  _answerRoom(rig.last, rig.lastRequestId('create_room'), seat: 0);
  await _pumpBounded(tester, frames: 3);
  expect(
    find.byType(LobbyScreen),
    findsOneWidget,
    reason: 'fixture: a room reply must show LobbyScreen for "$id"',
  );
}

/// Drives the real wire to the state where Home carries the notice.
Future<void> _driveHome(
  WidgetTester tester,
  _Rig rig,
  _HomeRow row,
  String id,
) async {
  switch (row) {
    case _HomeRow.notJoined:
    case _HomeRow.full:
    case _HomeRow.switchedOff:
      await _typeAndJoin(tester, rig, id);
      rig.last.pushText(
        _frame('knock_pending', <String, Object?>{
          'knock_id': 'kn-me',
          'expires_ms': 60000,
        }, re: rig.lastRequestId('join_room')),
      );
      await tester.pump();
      await tester.pump();
      rig.last.pushText(
        _frame('knock_failed', <String, Object?>{
          'knock_id': 'kn-me',
          'outcome': switch (row) {
            _HomeRow.notJoined => 'rejected',
            _HomeRow.full => 'full',
            _ => 'switched_off',
          },
        }),
      );
    case _HomeRow.kicked:
      await _typeAndJoin(tester, rig, id);
      _answerRoom(rig.last, rig.lastRequestId('join_room'), seat: 1);
      await _pumpBounded(tester, frames: 3);
      rig.last.pushText(_frame('kicked', <String, Object?>{}));
    case _HomeRow.roomClosedHost:
    case _HomeRow.roomClosedGuest:
      if (row == _HomeRow.roomClosedHost) {
        await _hostLobby(tester, rig, id);
      } else {
        await _typeAndJoin(tester, rig, id);
        _answerRoom(rig.last, rig.lastRequestId('join_room'), seat: 1);
        await _pumpBounded(tester, frames: 3);
      }
      final RoomController controller = rig.controllers.last;
      final int before = rig.transports.length;
      rig.last.endFromFarSide();
      await tester.pump();
      await tester.pump();
      unawaited(controller.reconnect());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        rig.transports.length,
        before + 1,
        reason: 'fixture: reconnect must open a transport for "$id"',
      );
      _answerError(rig.last, _idOf(rig.last.sentRaw.single), 'NO_SUCH_ROOM');
    case _HomeRow.gameGone:
      // Home resumes on its own from a fresh seat record; the resume is
      // answered NO_SUCH_ROOM.
      expect(
        rig.sent('resume'),
        hasLength(1),
        reason: 'fixture: a fresh seat record resumes on its own for "$id"',
      );
      _answerError(rig.last, rig.lastRequestId('resume'), 'NO_SUCH_ROOM');
    case _HomeRow.removed:
      await _hostLobby(tester, rig, id);
      rig.last.pushText(
        _frame('player_left', <String, Object?>{'seat': 0, 'seq': 4}),
      );
  }
  await _pumpBounded(tester, frames: 2);
  // Let the lobby route leave and Home settle, answering the leave it sends.
  for (int attempt = 0; attempt < 3; attempt += 1) {
    final List<String> leaves = rig.sent('leave_room');
    if (leaves.isNotEmpty && !rig.last.isClosed) {
      rig.last.pushText(
        _frame('player_left', <String, Object?>{
          'seat': 0,
          'host_seat': 0,
          'seq': 99,
        }, re: _idOf(leaves.last)),
      );
    }
    await _pumpBounded(tester, frames: 3);
  }
  for (int i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _homeCase(WidgetTester tester, _HomeRow row, Locale locale) async {
  final String lc = locale.languageCode;
  final String id = 'home $lc ${row.label}';
  final String replay = _replay(id);
  if (row == _HomeRow.gameGone) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'session.seat': <String>[_code, '0', _token],
      'session.seatSavedAt': DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch,
    });
  } else {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  }
  _phone(tester);
  final _Rig rig = _Rig();
  await tester.pumpWidget(_homeApp(rig, locale));
  await _pumpBounded(tester);
  try {
    await _driveHome(tester, rig, row, id);
    final Finder card = find.byKey(_noticeKey);
    expect(
      card,
      findsOneWidget,
      reason:
          'expected Home to show home-notice for "$id"; found '
          '${card.evaluate().length}. reproduce: $replay',
    );
    final AppLocalizations loc = _locOf(tester, HomeScreen);
    if (row.red) {
      _expectRed(
        tester,
        card,
        surface: 'home notice',
        code: row.label,
        locale: lc,
        replay: replay,
      );
      final DecoratedBox box = tester.widget<DecoratedBox>(card);
      final BoxBorder? border = (box.decoration as BoxDecoration).border;
      expect(
        border is Border ? border.top.color : null,
        kRefusalNoticeFrame,
        reason:
            'expected the red refusal frame on the card for "$id"; found '
            'border $border. reproduce: $replay',
      );
    } else {
      _expectNeutral(
        tester,
        card,
        Icons.info_outline_rounded,
        onlyIcon: false,
        surface: 'home notice',
        code: row.label,
        locale: lc,
        replay: replay,
      );
    }
    _expectText(
      card,
      _homeText(loc, row),
      surface: 'home notice',
      code: row.label,
      locale: lc,
      replay: replay,
    );
  } finally {
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpWidget(const SizedBox.shrink());
    rig.disposeAll();
    await tester.pump();
  }
}

void main() {
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String lc = locale.languageCode;
    group('lobby error card mark, $lc, 393x851', () {
      for (final _LobbyRow row in _lobbyRows) {
        testWidgets('lobby $lc ${row.label}', (tester) async {
          await _lobbyCase(tester, row, locale);
        });
      }
    });
    group('home notice mark, $lc, 393x851', () {
      for (final _HomeRow row in _HomeRow.values) {
        testWidgets('home $lc ${row.label}', (tester) async {
          await _homeCase(tester, row, locale);
        });
      }
    });
  }
}
