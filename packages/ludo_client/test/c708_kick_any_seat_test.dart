// C-708t: the host removes any player in play, being removed in play lands on
// home, and a computer seat is never mistaken for a person in the game screen
// (docs/PROTOCOL.md section 33 item 8, section 34 items 1, 3 and 6, section 35
// item 7 (f); work/ludo/orders/708-pre-roll-and-kick-client.md "The design"
// and the run 169 additions). Written from the order and the contract before
// the implementation exists.
//
// Three rigs, each a real screen over a real RoomController on FakeTransport,
// every state a decoded wire frame; nothing is mocked but the socket and the
// feedback service:
//   - the table: GameScreen on a four-seat 2026-11 room, me (seat 0) the host,
//     seat 1 a person, seat 2 a computer (`bot` 2, wire name "Nono"), seat 3 a
//     person whose state the row sets (finished, retired, away);
//   - home: HomeScreen, a typed code joined, the game started from the lobby,
//     then the frames of a kick in play;
//   - the lobby: LobbyScreen as host of an open room for the fill refusal.
//
// The kick sheet is reached by a tap on a seat's name plate
// (`board-seat-name-<seat>`); an away seat is also reached by its away mark
// (`board-seat-away-<seat>`), as today. The sheet is `kick-sheet-<seat>`.
//
// Words are read from AppLocalizations in the row's locale, never from a
// literal. Time is the test clock only, in explicit pumps; never
// pumpAndSettle. Every failure line names the row, the locale, what was
// expected, what was observed and every frame pushed and sent. Rerun one row:
//   cd packages/ludo_client && flock /tmp/ludo-suite.lock flutter test \
//     test/c708_kick_any_seat_test.dart --plain-name '<row name>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';
import 'support/home_flow.dart';
import 'support/roll_tray_harness.dart';

const String _file = 'test/c708_kick_any_seat_test.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

const String _ruleset = '2026-11';
const List<int> _yard = <int>[-1, -1, -1, -1];
const List<int> _home = <int>[57, 57, 57, 57];

const Key _kickRemoveKey = Key('kick-sheet-remove');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _friendJoinedLineKey = Key('end-card-friend-joined-line');
const Key _homeKnockNoticeKey = Key('home-knock-notice');
const Key _homeNoticeKey = Key('home-notice');
const Key _banNoticeKey = Key('code-ban-notice');
const Key _fillKey = Key('lobby-fill-computer');
const Key _fillErrorKey = Key('lobby-fill-computer-error');

Key _nameKey(int seat) => Key('board-seat-name-$seat');
Key _awayKey(int seat) => Key('board-seat-away-$seat');
Key _sheetKey(int seat) => Key('kick-sheet-$seat');
Key _placeKey(int seat) => Key('end-card-place-$seat');

/// The haptic ids of the doctrine's vocabulary (bin/game-doctrine.md section
/// 3); `dieLand`, `gloat` and `captureSeen` are sound only.
const Set<FeedbackCue> _hapticCues = <FeedbackCue>{
  FeedbackCue.yourTurn,
  FeedbackCue.canMove,
  FeedbackCue.noMove,
  FeedbackCue.step,
  FeedbackCue.capturedOther,
  FeedbackCue.capturedMe,
  FeedbackCue.home,
  FeedbackCue.win,
  FeedbackCue.gameOver,
};

int _wireIdSeq = 0;

String _wire(String type, Map<String, Object?> data, {String? re}) {
  _wireIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c708t-kick-${_wireIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

String _typeOf(String raw) => _decode(raw)['t']! as String;

// --- texts, icons and labels under a widget ----------------------------------

List<String> _textsUnder(Finder of) => <String>[
  for (final Element e
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate())
    (e.widget as RichText).text.toPlainText(),
];

List<String> _screenTexts() => <String>[
  for (final Element e in find.byType(RichText).evaluate())
    (e.widget as RichText).text.toPlainText(),
];

List<IconData?> _iconsUnder(Finder of) => <IconData?>[
  for (final Element e
      in find
          .descendant(of: of, matching: find.byType(Icon), matchRoot: true)
          .evaluate())
    (e.widget as Icon).icon,
];

/// Every label a Semantics or Tooltip widget under [of] carries.
List<String> _labelsUnder(Finder of) => <String>[
  for (final Element e
      in find
          .descendant(
            of: of,
            matching: find.byWidgetPredicate(
              (Widget w) => w is Semantics || w is Tooltip,
            ),
            matchRoot: true,
          )
          .evaluate())
    if (e.widget is Semantics)
      (e.widget as Semantics).properties.label ?? ''
    else
      (e.widget as Tooltip).message ?? '',
];

// =============================================================================
// The table rig
// =============================================================================

/// One seat of the table. [bot] makes it a computer seat as section 34 item 1
/// writes one.
class _Seat {
  const _Seat(
    this.seat,
    this.name, {
    this.via = 'link',
    this.connected = true,
    this.tokens = _yard,
  }) : bot = null;

  const _Seat.bot(
    this.seat,
    int this.bot,
    this.name, {
    this.connected = true,
    this.tokens = _yard,
  }) : via = 'bot';

  final int seat;
  final String name;
  final String via;
  final int? bot;
  final bool connected;
  final List<int> tokens;

  Map<String, Object?> toJson() => <String, Object?>{
    'seat': seat,
    'name': name,
    'connected': connected,
    'tokens': tokens,
    'client_seed': null,
    'seed_origin': bot != null ? 'server' : null,
    'drought': 0,
    'via': via,
    'bot': ?bot,
  };

  @override
  String toString() =>
      '$seat:$name/$via${bot == null ? '' : '/bot$bot'}'
      '${connected ? '' : '/down'}';
}

/// Seat 2's character: `bot` 2, wire name "Nono" (section 34 item 1).
const int _botSeat = 2;
const int _botId = 2;
const String _botWireName = 'Nono';

List<_Seat> _table({
  bool seat3Connected = true,
  List<int> seat3Tokens = _yard,
  bool botConnected = true,
  List<int> botTokens = _yard,
}) => <_Seat>[
  const _Seat(0, 'Sam', via: 'host'),
  const _Seat(1, 'Bob'),
  _Seat.bot(
    _botSeat,
    _botId,
    _botWireName,
    connected: botConnected,
    tokens: botTokens,
  ),
  _Seat(3, 'Dan', via: 'code', connected: seat3Connected, tokens: seat3Tokens),
];

Map<String, Object?> _rollTurn(int seat) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': rollTrayDeadlineMs,
  'k': 0,
  'queue': const <int>[],
};

Map<String, Object?> _tableRoom({
  required List<_Seat> seats,
  required Map<String, Object?>? turn,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 4,
  'open': false,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
    'ruleset': _ruleset,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[for (final _Seat s in seats) s.toJson()],
  'turn': turn,
  'winner': null,
  'seq': 1,
  'placings': placings,
  'retired': retired,
};

class _Table {
  _Table(this.tester, this.drive, this.name, this.locale, this.setup);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String name;
  final Locale locale;
  final String setup;
  final List<String> steps = <String>[];
  int clockMs = 0;

  AppLocalizations get loc => lookupAppLocalizations(locale);

  List<String> get sent => sentTypesSince(drive.transport, 0);

  String why(String expected) =>
      'C-708t "$name" [${locale.languageCode}] at ${clockMs}ms: expected '
      '$expected. Table: $setup. Steps: '
      '${steps.isEmpty ? '<none>' : steps.join(' -> ')}. Sent: $sent. Cues: '
      '${drive.feedback.recorded.map((FeedbackCue c) => c.id).toList()}. '
      'No seed; rerun: cd packages/ludo_client && flock /tmp/ludo-suite.lock '
      "flutter test $_file --plain-name '$name'";

  Future<void> pump(int ms, {int step = 50}) async {
    int left = ms;
    while (left > 0) {
      final int d = left < step ? left : step;
      await tester.pump(Duration(milliseconds: d));
      clockMs += d;
      left -= d;
    }
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add('push $type ${jsonEncode(data)} @${clockMs}ms');
    await drive.push(tester, type, data);
  }

  /// A tap on [key], then 400 ms for a sheet to come up.
  Future<void> tap(Key key) async {
    steps.add('tap $key @${clockMs}ms');
    await tester.tap(find.byKey(key), warnIfMissed: false);
    await tester.pump();
    await pump(400);
  }

  /// A tap on [key] when the screen draws it; a mark that is not drawn
  /// cannot be tapped, and the step log says so.
  Future<void> tapIfDrawn(Key key) async {
    if (find.byKey(key).evaluate().isEmpty) {
      steps.add('$key not drawn, no tap @${clockMs}ms');
      return;
    }
    await tap(key);
  }

  void expectSheet(int seat, bool open, String how) {
    expect(
      find.byKey(_sheetKey(seat)),
      open ? findsOneWidget : findsNothing,
      reason: why(
        open ? 'kick-sheet-$seat after $how' : 'no kick-sheet-$seat after $how',
      ),
    );
  }
}

Future<RollTrayDrive> _connectTable(
  WidgetTester tester,
  Map<String, Object?> room,
) async {
  final FakeTransport transport = FakeTransport();
  bool first = true;
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c708t-kick.invalid/ws'),
    connect: (Uri url) async {
      if (!first) {
        throw StateError('c708t table: a second connect was not expected');
      }
      first = false;
      return transport as WireTransport;
    },
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> created = controller.createRoom(name: 'Sam', players: 4);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _wire('seat_assigned', <String, Object?>{'seat': 0, 'seat_token': 'tok-0'}),
  );
  transport.pushText(_wire('room', room, re: id));
  await created;
  return RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: (FakeTransport t) {},
  );
}

/// Mounts the table, runs [body], releases the screen and the controller.
Future<void> _table4(
  WidgetTester tester, {
  required String name,
  required Locale locale,
  List<_Seat>? seats,
  Map<String, Object?>? turn,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  double height = 892,
  required Future<void> Function(_Table t) body,
}) async {
  tester.view.physicalSize = Size(412 * 2.625, height * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final List<_Seat> s = seats ?? _table();
  final Map<String, Object?> room = _tableRoom(
    seats: s,
    turn: turn ?? _rollTurn(1),
    placings: placings,
    retired: retired,
  );
  final RollTrayDrive drive = await _connectTable(tester, room);
  await mountGame(tester, drive, locale: locale);
  final _Table t = _Table(
    tester,
    drive,
    name,
    locale,
    'seats $s, turn ${jsonEncode(room['turn'])}, placings $placings, retired '
    '$retired, host seat 0, me seat 0, ruleset $_ruleset',
  );
  await t.pump(1000);
  try {
    await body(t);
  } finally {
    await releaseGame(tester, drive);
  }
}

void _row(String row, Future<void> Function(WidgetTester, Locale, String) b) {
  for (final Locale l in _locales) {
    final String name = '$row [${l.languageCode}]';
    testWidgets(name, (WidgetTester tester) => b(tester, l, name));
  }
}

// =============================================================================
// The home rig: join a typed code, start the game, then the kick in play
// =============================================================================

const String _code = 'K7M2QP';
const String _install = 'Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Aa0_-Zz';

Map<String, Object?> _ban() => <String, Object?>{
  'scope': 'device',
  'until_ms': DateTime(2028, 1, 15, 10, 42).millisecondsSinceEpoch,
  'level': 1,
  'next_ms': 7 * 24 * 60 * 60 * 1000,
};

Map<String, Object?> _lobbyRoom(int seq, String myName) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 2,
  'open': false,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
    'ruleset': _ruleset,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    for (int i = 0; i < 2; i += 1)
      <String, Object?>{
        'seat': i,
        'name': i == 0 ? 'Sam' : myName,
        'connected': true,
        'tokens': _yard,
        'client_seed': null,
        'seed_origin': null,
        'drought': 0,
        'via': i == 0 ? 'host' : 'code',
      },
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'placings': const <int>[],
  'retired': const <int>[],
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

class _Home {
  _Home(this.tester, this.name, this.locale);

  final WidgetTester tester;
  final String name;
  final Locale locale;
  final List<FakeTransport> transports = <FakeTransport>[];
  final List<String> pushed = <String>[];
  int connects = 0;

  /// The last seq this client was sent.
  int seq = 0;

  FakeTransport get transport => transports.last;

  AppLocalizations get loc => lookupAppLocalizations(locale);

  List<List<String>> get sent => <List<String>>[
    for (final FakeTransport t in transports) t.sentRaw.map(_typeOf).toList(),
  ];

  int sentCount(String type) => transports
      .expand((FakeTransport t) => t.sentRaw)
      .where((String r) => _typeOf(r) == type)
      .length;

  bool get onHome =>
      find.byKey(joinGameButtonKey).evaluate().isNotEmpty &&
      find.byType(GameScreen, skipOffstage: false).evaluate().isEmpty &&
      find.byType(LobbyScreen, skipOffstage: false).evaluate().isEmpty;

  String why(String expected) =>
      'C-708t "$name" [${locale.languageCode}]: expected $expected. Pushed in '
      'order: ${pushed.join(' | ')}. Sent per socket: $sent. Connects: '
      '$connects. On screen: ${_screenTexts()}. No seed; rerun: cd '
      'packages/ludo_client && flock /tmp/ludo-suite.lock flutter test '
      "$_file --plain-name '$name'";

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    String? re,
  }) async {
    pushed.add('$type${jsonEncode(data)}${re == null ? '' : ' re'}');
    transport.pushText(_wire(type, data, re: re));
    await tester.pump();
    await tester.pump();
  }

  Future<bool> waitFor(bool Function() cond, {int limitMs = 12000}) async {
    int spent = 0;
    while (!cond() && spent < limitMs) {
      await tester.pump(const Duration(milliseconds: 250));
      spent += 250;
    }
    return cond();
  }

  /// HomeScreen, a typed code joined as seat 1, the lobby, `game_started`
  /// and the first `turn`; returns with GameScreen up and `seq` at the last
  /// frame sent.
  static Future<_Home> intoGame(
    WidgetTester tester,
    String name,
    Locale locale,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'install_id': _install,
    });
    tester.view.physicalSize = const Size(400 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final _Home h = _Home(tester, name, locale);
    final List<FakeTransport> queue = <FakeTransport>[
      for (int i = 0; i < 3; i += 1) FakeTransport(),
    ];
    RoomController factory() => RoomController(
      serverUrl: Uri.parse('wss://c708t-home.invalid/ws'),
      connect: (Uri url) async {
        final FakeTransport t = queue[h.connects];
        h.connects += 1;
        h.transports.add(t);
        return t as WireTransport;
      },
      autoReconnectDelays: const <Duration>[],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: HomeScreen(
          key: ValueKey<String>(name),
          onToggleLocale: () {},
          controllerFactory: factory,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final String myName = oldDefaultName(locale.languageCode);
    await enterName(tester, myName);
    await openCodeEntry(tester);
    await tester.enterText(find.byKey(roomCodeFieldKey), _code);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.byKey(joinRoomButtonKey));
    await tester.pump();
    await tester.tap(find.byKey(joinRoomButtonKey));
    await tester.pump();
    for (int i = 0; i < 30 && h.sentCount('join_room') == 0; i += 1) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      h.sentCount('join_room'),
      1,
      reason: h.why('fixture: one join_room sent'),
    );
    final String joinId =
        _decode(
              h.transport.sentRaw.lastWhere(
                (String r) => _typeOf(r) == 'join_room',
              ),
            )['id']!
            as String;
    await h.push('seat_assigned', <String, Object?>{
      'seat': 1,
      'seat_token': 'tok-c708t-1',
    });
    h.seq = 5;
    await h.push('room', _lobbyRoom(h.seq, myName), re: joinId);
    await tester.pump(const Duration(seconds: 1));
    h.seq += 1;
    await h.push('game_started', <String, Object?>{
      'turn': 0,
      'game_id': 'c708t00000000001',
      'client_seeds': '0:sam-seed|1:my-seed',
      'seq': h.seq,
    });
    expect(
      await h.waitFor(
        () => find.byType(GameScreen).evaluate().isNotEmpty,
        limitMs: 3000,
      ),
      isTrue,
      reason: h.why('fixture: game_started puts GameScreen up'),
    );
    h.seq += 1;
    await h.push('turn', <String, Object?>{
      'seat': 0,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': const <int>[],
      'seq': h.seq,
    });
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: h.why('fixture: the game is on screen before the kick'),
    );
    return h;
  }

  void expectHomeWithKickNotice(String when) {
    expect(onHome, isTrue, reason: why('home after $when'));
    final Finder notice = find.byKey(_homeKnockNoticeKey);
    expect(
      notice,
      findsOneWidget,
      reason: why('home-knock-notice on home after $when'),
    );
    expect(
      _textsUnder(notice).join(' '),
      contains(loc.knockWasKicked),
      reason: why('the notice reads "${loc.knockWasKicked}" after $when'),
    );
  }

  void expectNoResume(String when) {
    expect(
      sentCount('resume'),
      0,
      reason: why('no `resume` frame on any socket after $when'),
    );
    expect(connects, 1, reason: why('no second socket opened after $when'));
  }

  Future<void> finish() => tester.pump(const Duration(seconds: 12));
}

// =============================================================================
// The lobby rig for the fill refusal
// =============================================================================

class _Lobby {
  _Lobby(this.tester, this.name, this.locale, this.controller, this.transport);

  final WidgetTester tester;
  final String name;
  final Locale locale;
  final RoomController controller;
  final FakeTransport transport;
  final List<String> pushed = <String>[];
  int seq = 10;

  AppLocalizations get loc => lookupAppLocalizations(locale);

  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String raw in transport.sentRaw)
      if (_typeOf(raw) == type) _decode(raw),
  ];

  String lastId(String type) => sent(type).last['id']! as String;

  String why(String expected) =>
      'C-708t "$name" [${locale.languageCode}]: expected $expected. Pushed: '
      '${pushed.join(' | ')}. Sent: '
      '${transport.sentRaw.map(_typeOf).toList()}. On screen: '
      '${_screenTexts()}. rerun: cd packages/ludo_client && flock '
      "/tmp/ludo-suite.lock flutter test $_file --plain-name '$name'";

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    String? re,
  }) async {
    pushed.add('$type${jsonEncode(data)}${re == null ? '' : ' re'}');
    transport.pushText(_wire(type, data, re: re));
    await tester.pump();
    await tester.pump();
  }

  Future<void> advance(int ms) async {
    int left = ms;
    while (left > 0) {
      final int d = left < 100 ? left : 100;
      await tester.pump(Duration(milliseconds: d));
      left -= d;
    }
  }

  Future<void> tapFill() async {
    pushed.add('<tap lobby-fill-computer>');
    await tester.tap(find.byKey(_fillKey), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
  }
}

Map<String, Object?> _openLobby(int seq) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 4,
  'open': true,
  'fill_ms': 0,
  'rules': const <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    const _Seat(0, 'Sam', via: 'host').toJson()..remove('drought'),
    const _Seat(1, 'Ann').toJson()..remove('drought'),
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

/// The host's LobbyScreen on an open room with two free seats and `fill_ms`
/// 0, connected, the fill control up.
Future<_Lobby> _hostLobby(
  WidgetTester tester,
  String name,
  Locale locale, {
  bool mount = true,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(412, 915);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeTransport transport = FakeTransport();
  bool first = true;
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c708t-lobby.invalid/ws'),
    connect: (Uri url) async {
      if (!first) {
        throw StateError('c708t lobby: a second connect was not expected');
      }
      first = false;
      return transport as WireTransport;
    },
    autoReconnectDelays: const <Duration>[],
  );
  addTearDown(controller.dispose);
  final _Lobby l = _Lobby(tester, name, locale, controller, transport);
  if (mount) {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: RecordingFeedback(),
          child: LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
            open: true,
          ),
        ),
      ),
    );
    for (int i = 0; i < 40 && l.sent('create_room').isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  } else {
    final Future<void> created = controller.createRoom(name: 'Sam', players: 4);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    l.transport.pushText(
      _wire('seat_assigned', <String, Object?>{
        'seat': 0,
        'seat_token': 'tok-c708t-0',
      }),
    );
    l.transport.pushText(
      _wire('room', _openLobby(l.seq), re: l.lastId('create_room')),
    );
    await created;
    return l;
  }
  expect(
    l.sent('create_room'),
    hasLength(1),
    reason: l.why('fixture: the lobby sent one create_room'),
  );
  await l.push('seat_assigned', <String, Object?>{
    'seat': 0,
    'seat_token': 'tok-c708t-0',
  });
  await l.push('room', _openLobby(l.seq), re: l.lastId('create_room'));
  await l.advance(800);
  expect(
    find.byKey(_fillKey),
    findsOneWidget,
    reason: l.why('fixture: lobby-fill-computer up with fill_ms 0'),
  );
  return l;
}

void main() {
  // ===========================================================================
  // The kick sheet in play
  // ===========================================================================
  group('kick sheet', () {
    _row('opens for a connected playing seat from its name plate; Remove '
        'sends one kick naming it', (tester, locale, name) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        body: (t) async {
          await t.tap(_nameKey(1));
          t.expectSheet(1, true, 'a tap on the name plate of connected seat 1');
          await t.tap(_kickRemoveKey);
          final List<Map<String, Object?>> kicks = _sentData(t, 'kick');
          expect(kicks, <Map<String, Object?>>[
            <String, Object?>{'seat': 1},
          ], reason: t.why('exactly one kick {"seat": 1} after Remove'));
        },
      );
    });

    _row('opens for a computer seat from its name plate', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        body: (t) async {
          await t.tap(_nameKey(_botSeat));
          t.expectSheet(
            _botSeat,
            true,
            'a tap on the name plate of computer seat $_botSeat',
          );
          await t.tap(_kickRemoveKey);
          expect(
            _sentData(t, 'kick'),
            <Map<String, Object?>>[
              <String, Object?>{'seat': _botSeat},
            ],
            reason: t.why('exactly one kick {"seat": $_botSeat} after Remove'),
          );
        },
      );
    });

    _row('opens for an away seat from its away mark, as today', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        seats: _table(seat3Connected: false),
        body: (t) async {
          await t.tap(_awayKey(3));
          t.expectSheet(3, true, 'a tap on the away mark of seat 3');
        },
      );
    });

    _row('never for my own seat', (tester, locale, name) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        body: (t) async {
          await t.tap(_nameKey(0));
          t.expectSheet(0, false, 'a tap on my own name plate');
          expect(
            find.byKey(_kickRemoveKey),
            findsNothing,
            reason: t.why('no kick sheet of any seat'),
          );
        },
      );
    });

    for (final bool connected in <bool>[true, false]) {
      final String state = connected ? 'connected' : 'away';
      _row('never for a finished seat ($state)', (tester, locale, name) async {
        await _table4(
          tester,
          name: name,
          locale: locale,
          seats: _table(seat3Connected: connected, seat3Tokens: _home),
          placings: const <int>[3],
          body: (t) async {
            await t.tap(_nameKey(3));
            if (!connected) {
              await t.tapIfDrawn(_awayKey(3));
            }
            t.expectSheet(3, false, 'taps on finished seat 3 ($state)');
            expect(_sentData(t, 'kick'), isEmpty, reason: t.why('no kick'));
          },
        );
      });

      _row('never for a retired seat ($state)', (tester, locale, name) async {
        await _table4(
          tester,
          name: name,
          locale: locale,
          seats: _table(seat3Connected: connected),
          retired: const <int>[3],
          body: (t) async {
            await t.tap(_nameKey(3));
            if (!connected) {
              await t.tapIfDrawn(_awayKey(3));
            }
            t.expectSheet(3, false, 'taps on retired seat 3 ($state)');
            expect(_sentData(t, 'kick'), isEmpty, reason: t.why('no kick'));
          },
        );
      });
    }
  });

  // ===========================================================================
  // A computer seat in the game screen
  // ===========================================================================
  group('computer seat in play', () {
    _row('never gets the away treatment, whatever connected says', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        seats: _table(botConnected: false),
        body: (t) async {
          expect(
            find.byKey(_awayKey(_botSeat)),
            findsNothing,
            reason: t.why(
              'no board-seat-away-$_botSeat on a computer seat the snapshot '
              'calls not connected',
            ),
          );
          final String shown = t.loc.botName2;
          final String offline = t.loc.gameSeatOffline(shown);
          final String offlineWire = t.loc.gameSeatOffline(_botWireName);
          final List<String> texts = _screenTexts();
          expect(
            texts.any(
              (String s) => s.contains(offline) || s.contains(offlineWire),
            ),
            isFalse,
            reason: t.why(
              'no "$offline" line anywhere, the screen shows $texts',
            ),
          );
        },
      );
    });

    _row('its name plate shows seatShownName, never the wire name', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        body: (t) async {
          final String shown = t.loc.botName2;
          final List<String> texts = _textsUnder(
            find.byKey(_nameKey(_botSeat)),
          );
          expect(
            texts.any((String s) => s.contains(shown)),
            isTrue,
            reason: t.why(
              '"$shown" on board-seat-name-$_botSeat, shows $texts',
            ),
          );
          if (shown != _botWireName) {
            expect(
              _screenTexts().any((String s) => s.contains(_botWireName)),
              isFalse,
              reason: t.why('the wire name "$_botWireName" nowhere on screen'),
            );
          }
        },
      );
    });

    _row('the robot mark with the seatOriginBot label on its name plate', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        body: (t) async {
          final Finder plate = find.byKey(_nameKey(_botSeat));
          expect(
            _iconsUnder(plate),
            contains(Icons.smart_toy_rounded),
            reason: t.why(
              'Icons.smart_toy_rounded on board-seat-name-$_botSeat, it '
              'draws ${_iconsUnder(plate)}',
            ),
          );
          expect(
            _labelsUnder(plate)
                .any((String s) => s.contains(t.loc.seatOriginBot)),
            isTrue,
            reason: t.why(
              'the words "${t.loc.seatOriginBot}" (seatOriginBot) on the '
              'mark, labels found ${_labelsUnder(plate)}',
            ),
          );
          for (final int person in <int>[1, 3]) {
            expect(
              _iconsUnder(find.byKey(_nameKey(person))),
              isNot(contains(Icons.smart_toy_rounded)),
              reason: t.why('no robot mark on person seat $person'),
            );
          }
        },
      );
    });

    _row('the robot mark in the turn line on the computer\'s turn', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        turn: _rollTurn(_botSeat),
        body: (t) async {
          final Finder banner = find.byKey(_bannerKey);
          expect(
            banner,
            findsOneWidget,
            reason: t.why('fixture: game-screen-turn-banner on screen'),
          );
          expect(
            _iconsUnder(banner),
            contains(Icons.smart_toy_rounded),
            reason: t.why(
              'Icons.smart_toy_rounded in the turn line on the computer\'s '
              'turn, it draws ${_iconsUnder(banner)}',
            ),
          );
        },
      );
    });

    _row('the robot mark with the seatOriginBot label in its end card row', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        height: 1400,
        body: (t) async {
          await t.push('game_over', <String, Object?>{
            'winner': _botSeat,
            'verify_url': 'https://c708t.invalid/verify/1',
            'placings': const <int>[_botSeat, 0, 1, 3],
            'retired': const <int>[],
          });
          await t.pump(1500);
          final Finder row = find.byKey(_placeKey(_botSeat));
          expect(
            row,
            findsOneWidget,
            reason: t.why('fixture: end-card-place-$_botSeat on the end card'),
          );
          expect(
            _iconsUnder(row),
            contains(Icons.smart_toy_rounded),
            reason: t.why(
              'Icons.smart_toy_rounded in end-card-place-$_botSeat, it draws '
              '${_iconsUnder(row)}',
            ),
          );
          expect(
            _labelsUnder(row)
                .any((String s) => s.contains(t.loc.seatOriginBot)),
            isTrue,
            reason: t.why(
              'the words "${t.loc.seatOriginBot}" on the mark, labels found '
              '${_labelsUnder(row)}',
            ),
          );
          expect(
            _iconsUnder(find.byKey(_placeKey(1))),
            isNot(contains(Icons.smart_toy_rounded)),
            reason: t.why('no robot mark in the row of person seat 1'),
          );
        },
      );
    });

    _row('no haptic id for the computer\'s routine roll and move', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        seats: _table(botTokens: const <int>[10, -1, -1, -1]),
        turn: _rollTurn(_botSeat),
        body: (t) async {
          final int mark = t.drive.feedback.recorded.length;
          await t.push('rolled', <String, Object?>{
            'seat': _botSeat,
            'value': 4,
            'legal': const <int>[0],
            'deadline_ms': rollTrayDeadlineMs,
            'k': 1,
            'reveal': rollTrayReveal,
            'queue': const <int>[4],
            'legal_by_face': <Map<String, Object?>>[
              faceLegal(4, const <int>[0]),
            ],
          });
          await t.pump(1200);
          await t.push('moved', <String, Object?>{
            'seat': _botSeat,
            'token': 0,
            'from': 10,
            'to': 14,
            'face': 4,
            'captured': const <Object?>[],
            'extra_roll': false,
          });
          await t.push('turn', <String, Object?>{
            'seat': 3,
            'phase': 'await_roll',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': const <int>[],
          });
          await t.pump(2500);
          expect(
            t.drive.controller.room!.seats
                .firstWhere((s) => s.seat == _botSeat)
                .tokens
                .first,
            14,
            reason: t.why('fixture: the computer\'s token moved to 14'),
          );
          final List<String> haptic = <String>[
            for (final FeedbackCue c in t.drive.feedback.recorded.skip(mark))
              if (_hapticCues.contains(c)) c.id,
          ];
          expect(
            haptic,
            isEmpty,
            reason: t.why('no haptic id for a computer\'s routine move'),
          );
        },
      );
    });

    _row('a player_joined for a computer seat at the end card shows '
        'seatShownName, never the wire name', (tester, locale, name) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        height: 1400,
        seats: const <_Seat>[
          _Seat(0, 'Sam', via: 'host'),
          _Seat(1, 'Bob'),
        ],
        turn: _rollTurn(0),
        body: (t) async {
          await t.push('game_over', <String, Object?>{
            'winner': 1,
            'verify_url': 'https://c708t.invalid/verify/2',
            'placings': const <int>[1, 0],
            'retired': const <int>[],
          });
          await t.pump(kEndCardHoldLimit.inMilliseconds + 300);
          for (final String raw in List<String>.of(t.drive.transport.sentRaw)) {
            if (_typeOf(raw) == 'game_log') {
              t.drive.transport.pushText(
                _wire('error', <String, Object?>{
                  'code': 'RATE_LIMITED',
                  'message': 'game_log',
                }, re: requestIdOf(raw)),
              );
            }
          }
          await t.pump(100);
          t.drive.lastSeq += 1;
          t.steps.add('push room (rematch lobby by seat 0)');
          t.drive.transport.pushText(
            _wire('room', <String, Object?>{
              ..._tableRoom(
                seats: const <_Seat>[
                  _Seat(0, 'Sam', via: 'host'),
                  _Seat(1, 'Bob'),
                ],
                turn: null,
              ),
              'state': 'LOBBY',
              'chain_commit': 'b' * 64,
              'chain_index': 1,
              'seq': t.drive.lastSeq,
              'rematch': <String, Object?>{
                'by': 0,
                'ready': const <int>[0],
              },
            }),
          );
          await t.pump(1500);
          await t.push('player_joined', <String, Object?>{
            'seat': 3,
            'name': 'Kiko',
            'bot': 3,
          });
          await t.pump(300);
          final String shown = t.loc.botName3;
          final Finder line = find.byKey(_friendJoinedLineKey);
          expect(
            line,
            findsOneWidget,
            reason: t.why('fixture: end-card-friend-joined-line for the join'),
          );
          final String text = _textsUnder(line).join(' ');
          expect(
            text,
            contains(t.loc.lobbyFriendJoined(shown)),
            reason: t.why(
              'the line reads "${t.loc.lobbyFriendJoined(shown)}", it reads '
              '"$text"',
            ),
          );
          if (shown != 'Kiko') {
            expect(
              text.contains('Kiko'),
              isFalse,
              reason: t.why('never the wire name "Kiko" in the line "$text"'),
            );
          }
        },
      );
    });
  });

  // ===========================================================================
  // Removed in play
  // ===========================================================================
  group('kicked in play', () {
    _row('kicked lands on home with the knockWasKicked notice and no ban '
        'card', (tester, locale, name) async {
      final _Home h = await _Home.intoGame(tester, name, locale);
      h.seq += 1;
      await h.push('seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'kicked',
        'host_seat': 0,
        'seq': h.seq,
      });
      await h.push('kicked', <String, Object?>{});
      await h.waitFor(() => h.onHome);
      await tester.pump(const Duration(milliseconds: 600));
      h.expectHomeWithKickNotice('kicked in play');
      expect(
        find.byKey(_banNoticeKey),
        findsNothing,
        reason: h.why('no ban card when kicked carries no ban'),
      );
      h.expectNoResume('kicked in play');
      await h.finish();
    });

    _row('kicked with ban lands on home with the notice and the ban card', (
      tester,
      locale,
      name,
    ) async {
      final _Home h = await _Home.intoGame(tester, name, locale);
      h.seq += 1;
      await h.push('seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'kicked',
        'host_seat': 0,
        'seq': h.seq,
      });
      await h.push('kicked', <String, Object?>{'ban': _ban()});
      await h.waitFor(() => h.onHome);
      await tester.pump(const Duration(milliseconds: 600));
      h.expectHomeWithKickNotice('kicked with ban in play');
      expect(
        find.byKey(_banNoticeKey),
        findsOneWidget,
        reason: h.why('exactly one code-ban-notice on home'),
      );
      await h.finish();
    });

    _row('seat_retired 4 past my last frame then kicked: home with the '
        'notice, no resume', (tester, locale, name) async {
      final _Home h = await _Home.intoGame(tester, name, locale);
      h.seq += 4;
      await h.push('seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'kicked',
        'host_seat': 0,
        'seq': h.seq,
      });
      h.expectNoResume('seat_retired for my seat with a seq gap of 4');
      await h.push('kicked', <String, Object?>{});
      await h.waitFor(() => h.onHome);
      await tester.pump(const Duration(milliseconds: 600));
      h.expectHomeWithKickNotice('kicked with a seq gap of 4');
      h.expectNoResume('kicked with a seq gap of 4');
      await h.finish();
    });

    _row('seat_retired for my own seat 4 past my last frame, alone: home, '
        'no resume', (tester, locale, name) async {
      final _Home h = await _Home.intoGame(tester, name, locale);
      h.seq += 4;
      await h.push('seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'kicked',
        'host_seat': 0,
        'seq': h.seq,
      });
      await h.waitFor(() => h.onHome);
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        h.onHome,
        isTrue,
        reason: h.why('home after seat_retired for my own seat'),
      );
      expect(
        find.byKey(_homeNoticeKey),
        findsOneWidget,
        reason: h.why('a notice on home saying why the game closed'),
      );
      h.expectNoResume('seat_retired for my own seat with a seq gap of 4');
      await h.finish();
    });
  });

  // ===========================================================================
  // fillComputer's outcome
  // ===========================================================================
  group('fill refusal', () {
    _row('the lobby shows the refusal of each fill tap and clears it on an '
        'accepted one', (tester, locale, name) async {
      final _Lobby l = await _hostLobby(tester, name, locale);
      final String words = lobbyErrorMessage(l.loc, 'WRONG_PHASE');
      await l.tapFill();
      await l.push('error', <String, Object?>{
        'code': 'WRONG_PHASE',
        'message': 'not yet',
      }, re: l.lastId('fill_computer'));
      await l.advance(300);
      expect(
        find.descendant(
          of: find.byKey(_fillErrorKey),
          matching: find.text(words),
        ),
        findsOneWidget,
        reason: l.why(
          '"$words" in lobby-fill-computer-error after WRONG_PHASE',
        ),
      );
      await l.tapFill();
      expect(
        find.byKey(_fillErrorKey),
        findsNothing,
        reason: l.why('the old refusal cleared at the new tap'),
      );
      await l.push('error', <String, Object?>{
        'code': 'WRONG_PHASE',
        'message': 'not yet',
      }, re: l.lastId('fill_computer'));
      await l.advance(300);
      expect(
        find.descendant(
          of: find.byKey(_fillErrorKey),
          matching: find.text(words),
        ),
        findsOneWidget,
        reason: l.why(
          'the second WRONG_PHASE refusal shown again, though its code '
          'equals the one before it',
        ),
      );
      await l.tapFill();
      l.seq += 1;
      await l.push('player_joined', <String, Object?>{
        'seat': 2,
        'name': 'Zuzu',
        'bot': 1,
        'seq': l.seq,
      }, re: l.lastId('fill_computer'));
      await l.advance(300);
      expect(
        find.byKey(_fillErrorKey),
        findsNothing,
        reason: l.why('no refusal line after the accepted fill'),
      );
    });

    testWidgets('fillComputer() returns the refusal code', (tester) async {
      final _Lobby l = await _hostLobby(
        tester,
        'fillComputer() returns the refusal code',
        _en,
        mount: false,
      );
      final Future<dynamic> outcome =
          (l.controller as dynamic).fillComputer() as Future<dynamic>;
      await tester.pump();
      await l.push('error', <String, Object?>{
        'code': 'WRONG_PHASE',
        'message': 'not yet',
      }, re: l.lastId('fill_computer'));
      final Object? code = await outcome;
      expect(
        code,
        'WRONG_PHASE',
        reason: l.why(
          'RoomController.fillComputer() completing with the refusal code '
          '"WRONG_PHASE" (order 708, run 169), it completed with $code',
        ),
      );
    });

    testWidgets('fillComputer() returns null when accepted', (tester) async {
      final _Lobby l = await _hostLobby(
        tester,
        'fillComputer() returns null when accepted',
        _en,
        mount: false,
      );
      final Future<dynamic> outcome =
          (l.controller as dynamic).fillComputer() as Future<dynamic>;
      await tester.pump();
      l.seq += 1;
      await l.push('player_joined', <String, Object?>{
        'seat': 2,
        'name': 'Zuzu',
        'bot': 1,
        'seq': l.seq,
      }, re: l.lastId('fill_computer'));
      final Object? code = await outcome;
      expect(
        code,
        isNull,
        reason: l.why('fillComputer() completing with null on acceptance'),
      );
    });

    testWidgets('fillComputer() returns null when the connection is lost', (
      tester,
    ) async {
      final _Lobby l = await _hostLobby(
        tester,
        'fillComputer() returns null when the connection is lost',
        _en,
        mount: false,
      );
      final Future<dynamic> outcome =
          (l.controller as dynamic).fillComputer() as Future<dynamic>;
      await tester.pump();
      l.pushed.add('<socket closed by the far side>');
      l.transport.endFromFarSide();
      await tester.pump();
      await tester.pump();
      final Object? code = await outcome;
      expect(
        code,
        isNull,
        reason: l.why('fillComputer() completing with null on a lost link'),
      );
    });
  });
}

/// The `d` of every frame of [type] the table's client sent, in order.
List<Map<String, Object?>> _sentData(_Table t, String type) =>
    <Map<String, Object?>>[
      for (final String raw in t.drive.transport.sentRaw)
        if (_typeOf(raw) == type) frameData(raw),
    ];
