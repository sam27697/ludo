// C-722t: open-seat wording (X235), the remove sheet's "Keep" (X239) and the
// larger origin mark (X236). Written from work/ludo/orders/722-lobby-wording-
// robot-mark-client.md and work/ludo/orders/722t-tests-lobby-wording-robot-
// mark.md, before the implementation exists.
//
// Real screens over a real RoomController on FakeTransport, every state a
// decoded wire frame; nothing is mocked but the socket.
//   - the lobby: LobbyScreen as host (create), open seats, the remove sheet
//     over each kind of seat, the origin marks at two phone sizes;
//   - the table: GameScreen on a four-seat room, the remove sheet reached from
//     a seat's name plate or its away mark.
//
// The two new words are read through a dynamic lookup of AppLocalizations
// (`lobbyOpenSeatPlayer`, `kickSheetKeep`) so this file compiles and analyzes
// clean before the getters exist; the lookup throws at run time until they do,
// which is the red. Each row also pins the literal en and ar words the order
// names, so the getter cannot drift from the spec.
//
// Time is the test clock in explicit pumps; never pumpAndSettle. Every failure
// line names the row, the locale, the surface size, what was expected and what
// was observed. There is no random seed in this file: the scenario is the
// row's name. Rerun one row:
//   cd packages/ludo_client && flock /tmp/ludo-suite.lock flutter test \
//     test/c722_wording_and_mark_test.dart --plain-name '<row name>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/seat_mark.dart' show SeatMark;

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const String _file = 'test/c722_wording_and_mark_test.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

const Key _waitKey = Key('kick-sheet-wait');

const List<int> _yard = <int>[-1, -1, -1, -1];

/// The words the order pins, per language.
const Map<String, String> _openPlayerWords = <String, String>{
  'en': 'Waiting for a player',
  'ar': 'بانتظار لاعب',
};
const Map<String, String> _openFriendWords = <String, String>{
  'en': 'Waiting for a friend',
  'ar': 'بانتظار صديق',
};
const Map<String, String> _keepWords = <String, String>{
  'en': 'Keep',
  'ar': 'خليه',
};
const Map<String, String> _waitWords = <String, String>{
  'en': 'Wait',
  'ar': 'استنى',
};

// --- reading new getters before they exist -----------------------------------

String _dyn(AppLocalizations loc, String getter) {
  final dynamic d = loc;
  final Object? value = switch (getter) {
    'lobbyOpenSeatPlayer' => d.lobbyOpenSeatPlayer,
    'kickSheetKeep' => d.kickSheetKeep,
    _ => throw ArgumentError('unknown getter $getter'),
  };
  if (value is! String) {
    fail('expected loc.$getter to be a String, got $value');
  }
  return value;
}

// --- wire helpers --------------------------------------------------------------

int _idSeq = 0;

String _wire(String type, Map<String, Object?> data, {String? re}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c722t-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

String _typeOf(String raw) => _decode(raw)['t']! as String;

/// One seat as the wire writes it. [bot] makes it a computer seat.
class _Seat {
  const _Seat(
    this.seat,
    this.name, {
    this.via = 'link',
    this.connected = true,
    this.bot,
  });

  final int seat;
  final String name;
  final String via;
  final bool connected;
  final int? bot;

  Map<String, Object?> toJson() => <String, Object?>{
    'seat': seat,
    'name': name,
    'connected': connected,
    'tokens': _yard,
    'client_seed': null,
    'seed_origin': bot != null ? 'server' : null,
    'drought': 0,
    'via': bot != null ? 'bot' : via,
    'bot': ?bot,
  };

  @override
  String toString() =>
      '$seat:$name/${bot != null ? 'bot$bot' : via}${connected ? '' : '/down'}';
}

Map<String, Object?> _room({
  required List<_Seat> seats,
  required bool open,
  required int players,
  required bool playing,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': playing ? 'PLAYING' : 'LOBBY',
  'host_seat': 0,
  'players': players,
  'open': open,
  'fill_ms': ?(open && !playing ? 0 : null),
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
    'ruleset': '2026-11',
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[for (final _Seat s in seats) s.toJson()],
  'turn': playing
      ? <String, Object?>{
          'seat': 1,
          'phase': 'await_roll',
          'deadline_ms': rollTrayDeadlineMs,
          'k': 0,
          'queue': const <int>[],
        }
      : null,
  'winner': null,
  'seq': 1,
  'placings': const <int>[],
  'retired': const <int>[],
  'link_id': 't5k2q9a-x7m3pd',
  'guest_approval': false,
  'knocks': const <Object?>[],
};

// --- text and geometry helpers ---------------------------------------------------

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

String _fmt(Rect r) =>
    '(${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)} '
    '${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)})';

// --- the lobby rig ------------------------------------------------------------------

class _Rig {
  _Rig(this.tester, this.name, this.locale, this.size, this.setup);

  final WidgetTester tester;
  final String name;
  final Locale locale;
  final Size size;
  final String setup;
  late FakeTransport transport;
  late RoomController controller;

  AppLocalizations get loc => lookupAppLocalizations(locale);

  List<String> get sentTypes => <String>[
    for (final String raw in transport.sentRaw) _typeOf(raw),
  ];

  String why(String expected) =>
      'C-722t "$name" [${locale.languageCode}] surface '
      '${size.width.toInt()}x${size.height.toInt()}: expected $expected. '
      'Setup: $setup. Sent: $sentTypes. On screen: ${_screenTexts()}. '
      'No seed, the scenario is the row name; rerun: cd packages/ludo_client '
      "&& flock /tmp/ludo-suite.lock flutter test $_file --plain-name '$name'";

  Future<void> pump(int ms) async {
    int left = ms;
    while (left > 0) {
      final int d = left < 100 ? left : 100;
      await tester.pump(Duration(milliseconds: d));
      left -= d;
    }
  }
}

Future<_Rig> _lobby(
  WidgetTester tester, {
  required String name,
  required Locale locale,
  required List<_Seat> seats,
  required bool open,
  int players = 4,
  Size size = const Size(412, 915),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final FakeTransport transport = FakeTransport();
  bool first = true;
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c722t-lobby.invalid/ws'),
    connect: (Uri url) async {
      if (!first) {
        throw StateError('c722t lobby: a second connect was not expected');
      }
      first = false;
      return transport as WireTransport;
    },
    autoReconnectDelays: const <Duration>[],
  );
  addTearDown(controller.dispose);
  final _Rig rig = _Rig(
    tester,
    name,
    locale,
    size,
    'lobby, host Sam seat 0, open $open, players $players, seats $seats',
  );
  rig.transport = transport;
  rig.controller = controller;
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
          players: players,
          open: open,
        ),
      ),
    ),
  );
  for (int i = 0; i < 40 && !rig.sentTypes.contains('create_room'); i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    rig.sentTypes,
    contains('create_room'),
    reason: rig.why('fixture: the lobby sent create_room'),
  );
  final String id =
      _decode(
            transport.sentRaw.lastWhere(
              (String r) => _typeOf(r) == 'create_room',
            ),
          )['id']!
          as String;
  transport.pushText(
    _wire('seat_assigned', <String, Object?>{
      'seat': 0,
      'seat_token': 'tok-c722t-0',
    }),
  );
  transport.pushText(
    _wire(
      'room',
      _room(seats: seats, open: open, players: players, playing: false),
      re: id,
    ),
  );
  await tester.pump();
  await tester.pump();
  await rig.pump(900);
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: rig.why('fixture: the controller is connected'),
  );
  return rig;
}

/// A tap on [key], then 500 ms for a sheet to come up.
Future<void> _tapAndWait(_Rig rig, Key key) async {
  await rig.tester.tap(find.byKey(key), warnIfMissed: false);
  await rig.tester.pump();
  await rig.pump(500);
}

void _row(String row, Future<void> Function(WidgetTester, Locale, String) b) {
  for (final Locale l in _locales) {
    final String name = '$row [${l.languageCode}]';
    testWidgets(name, (WidgetTester tester) => b(tester, l, name));
  }
}

// --- the remove sheet: shared assertions ----------------------------------------------

/// With the sheet up, the second control reads [words]; tapping it closes the
/// sheet and sends no `kick`.
Future<void> _expectSecondControl(
  _Rig rig, {
  required int seat,
  required String words,
  required String wordsLabel,
  required String wordKind,
}) async {
  expect(
    find.byKey(Key('kick-sheet-$seat')),
    findsOneWidget,
    reason: rig.why('kick-sheet-$seat on screen after the tap'),
  );
  final Finder control = find.byKey(_waitKey);
  expect(
    control,
    findsOneWidget,
    reason: rig.why('one kick-sheet-wait control on the sheet'),
  );
  final List<String> shown = _textsUnder(control);
  expect(
    shown.any((String s) => s.trim() == words),
    isTrue,
    reason: rig.why(
      'kick-sheet-wait reads "$words" ($wordKind), it reads $shown',
    ),
  );
  if (wordKind == 'Keep') {
    expect(
      _dyn(rig.loc, 'kickSheetKeep'),
      words,
      reason: rig.why('loc.kickSheetKeep equals the pinned "$words"'),
    );
  } else {
    expect(
      rig.loc.kickSheetWait,
      words,
      reason: rig.why('loc.kickSheetWait equals the pinned "$words"'),
    );
  }
  expect(
    wordsLabel,
    words,
    reason: rig.why('fixture: the literal pin matches'),
  );
  await rig.tester.tap(control, warnIfMissed: false);
  await rig.tester.pump();
  await rig.pump(500);
  expect(
    find.byKey(Key('kick-sheet-$seat')),
    findsNothing,
    reason: rig.why('the sheet closed after a tap on "$words"'),
  );
  expect(
    rig.sentTypes.where((String t) => t == 'kick'),
    isEmpty,
    reason: rig.why('no kick frame after a tap on "$words"'),
  );
}

// --- the table rig (the game screen's caller) -------------------------------------------

Future<_Rig> _table(
  WidgetTester tester, {
  required String name,
  required Locale locale,
  required List<_Seat> seats,
}) async {
  const Size size = Size(412, 892);
  tester.view.physicalSize = Size(412 * 2.625, 892 * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final FakeTransport transport = FakeTransport();
  bool first = true;
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c722t-table.invalid/ws'),
    connect: (Uri url) async {
      if (!first) {
        throw StateError('c722t table: a second connect was not expected');
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
    _wire('seat_assigned', <String, Object?>{
      'seat': 0,
      'seat_token': 'tok-c722t-0',
    }),
  );
  transport.pushText(
    _wire(
      'room',
      _room(seats: seats, open: false, players: 4, playing: true),
      re: id,
    ),
  );
  await created;
  final RollTrayDrive drive = RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: (FakeTransport t) {},
  );
  await mountGame(tester, drive, locale: locale);
  addTearDown(() => releaseGame(tester, drive));
  final _Rig rig = _Rig(
    tester,
    name,
    locale,
    size,
    'game table, me Sam seat 0 host, seats $seats, turn seat 1',
  );
  rig.transport = transport;
  rig.controller = controller;
  await rig.pump(1000);
  return rig;
}

// =============================================================================
// Rows 1 and 2: the open seat card
// =============================================================================

void main() {
  group('open seat wording (X235)', () {
    const List<_Seat> two = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Ann'),
    ];

    _row('row 1: an open room shows "Waiting for a player" on every free '
        'seat', (tester, locale, name) async {
      final _Rig rig = await _lobby(
        tester,
        name: name,
        locale: locale,
        seats: two,
        open: true,
      );
      final String lang = locale.languageCode;
      for (final int i in <int>[0, 1]) {
        final Finder card = find.byKey(Key('lobby-seat-open-$i'));
        expect(
          card,
          findsOneWidget,
          reason: rig.why('lobby-seat-open-$i on screen (2 of 4 seated)'),
        );
        final List<String> shown = _textsUnder(card);
        expect(
          shown.any((String s) => s.trim() == _openPlayerWords[lang]),
          isTrue,
          reason: rig.why(
            'lobby-seat-open-$i reads "${_openPlayerWords[lang]}", it reads '
            '$shown',
          ),
        );
        expect(
          shown.any((String s) => s.contains(_openFriendWords[lang]!)),
          isFalse,
          reason: rig.why(
            'lobby-seat-open-$i never says "${_openFriendWords[lang]}" in an '
            'open room, it reads $shown',
          ),
        );
      }
      expect(
        _dyn(rig.loc, 'lobbyOpenSeatPlayer'),
        _openPlayerWords[lang],
        reason: rig.why('loc.lobbyOpenSeatPlayer is the pinned wording'),
      );
    });

    _row('row 2: a room that is not open keeps "Waiting for a friend"', (
      tester,
      locale,
      name,
    ) async {
      final _Rig rig = await _lobby(
        tester,
        name: name,
        locale: locale,
        seats: two,
        open: false,
      );
      final String lang = locale.languageCode;
      for (final int i in <int>[0, 1]) {
        final Finder card = find.byKey(Key('lobby-seat-open-$i'));
        expect(
          card,
          findsOneWidget,
          reason: rig.why('lobby-seat-open-$i on screen (2 of 4 seated)'),
        );
        final List<String> shown = _textsUnder(card);
        expect(
          shown.any((String s) => s.trim() == _openFriendWords[lang]),
          isTrue,
          reason: rig.why(
            'lobby-seat-open-$i reads "${_openFriendWords[lang]}", it reads '
            '$shown',
          ),
        );
        expect(
          shown.any((String s) => s.contains(_openPlayerWords[lang]!)),
          isFalse,
          reason: rig.why(
            'lobby-seat-open-$i never says "${_openPlayerWords[lang]}" when '
            'the room is not open, it reads $shown',
          ),
        );
      }
      expect(
        rig.loc.lobbyOpenSeat,
        _openFriendWords[lang],
        reason: rig.why('loc.lobbyOpenSeat is unchanged'),
      );
    });

    _row('row 1b: a full open room has no open seat card and no open-seat '
        'words', (tester, locale, name) async {
      final _Rig rig = await _lobby(
        tester,
        name: name,
        locale: locale,
        seats: two,
        open: true,
        players: 2,
      );
      final String lang = locale.languageCode;
      expect(
        find.byKey(const Key('lobby-seat-open-0')),
        findsNothing,
        reason: rig.why('no lobby-seat-open-0 in a full room'),
      );
      final String all = _screenTexts().join(' | ');
      expect(
        all.contains(_openPlayerWords[lang]!) ||
            all.contains(_openFriendWords[lang]!),
        isFalse,
        reason: rig.why('neither waiting line anywhere in a full room'),
      );
    });
  });

  // ===========================================================================
  // Rows 3, 4 and 5: the remove sheet's second control, both callers
  // ===========================================================================
  group('remove sheet, lobby caller (X239)', () {
    const List<_Seat> seats = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Bob'),
      _Seat(2, 'Nono', bot: 2),
      _Seat(3, 'Dan', via: 'code', connected: false),
    ];

    _row('row 3: over a connected person seat the second control is "Keep" '
        'and sends no kick', (tester, locale, name) async {
      final _Rig rig = await _lobby(
        tester,
        name: name,
        locale: locale,
        seats: seats,
        open: false,
      );
      await _tapAndWait(rig, const Key('lobby-kick-1'));
      final String lang = locale.languageCode;
      await _expectSecondControl(
        rig,
        seat: 1,
        words: _keepWords[lang]!,
        wordsLabel: _keepWords[lang]!,
        wordKind: 'Keep',
      );
    });

    _row('row 4: over a connected computer seat the second control is '
        '"Keep"', (tester, locale, name) async {
      final _Rig rig = await _lobby(
        tester,
        name: name,
        locale: locale,
        seats: seats,
        open: false,
      );
      await _tapAndWait(rig, const Key('lobby-kick-2'));
      final String lang = locale.languageCode;
      await _expectSecondControl(
        rig,
        seat: 2,
        words: _keepWords[lang]!,
        wordsLabel: _keepWords[lang]!,
        wordKind: 'Keep',
      );
    });

    _row('row 5: over an away seat the second control is "Wait"', (
      tester,
      locale,
      name,
    ) async {
      final _Rig rig = await _lobby(
        tester,
        name: name,
        locale: locale,
        seats: seats,
        open: false,
      );
      await _tapAndWait(rig, const Key('lobby-kick-3'));
      final String lang = locale.languageCode;
      await _expectSecondControl(
        rig,
        seat: 3,
        words: _waitWords[lang]!,
        wordsLabel: _waitWords[lang]!,
        wordKind: 'Wait',
      );
    });
  });

  group('remove sheet, game caller (X239)', () {
    const List<_Seat> seats = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Bob'),
      _Seat(2, 'Nono', bot: 2),
      _Seat(3, 'Dan', via: 'code', connected: false),
    ];

    _row('row 3 (game): over a connected person seat the second control is '
        '"Keep"', (tester, locale, name) async {
      final _Rig rig = await _table(
        tester,
        name: name,
        locale: locale,
        seats: seats,
      );
      await _tapAndWait(rig, const Key('board-seat-name-1'));
      final String lang = locale.languageCode;
      await _expectSecondControl(
        rig,
        seat: 1,
        words: _keepWords[lang]!,
        wordsLabel: _keepWords[lang]!,
        wordKind: 'Keep',
      );
    });

    _row('row 4 (game): over a connected computer seat the second control '
        'is "Keep"', (tester, locale, name) async {
      final _Rig rig = await _table(
        tester,
        name: name,
        locale: locale,
        seats: seats,
      );
      await _tapAndWait(rig, const Key('board-seat-name-2'));
      final String lang = locale.languageCode;
      await _expectSecondControl(
        rig,
        seat: 2,
        words: _keepWords[lang]!,
        wordsLabel: _keepWords[lang]!,
        wordKind: 'Keep',
      );
    });

    _row('row 5 (game): over an away seat the second control is "Wait"', (
      tester,
      locale,
      name,
    ) async {
      final _Rig rig = await _table(
        tester,
        name: name,
        locale: locale,
        seats: seats,
      );
      await _tapAndWait(rig, const Key('board-seat-away-3'));
      final String lang = locale.languageCode;
      await _expectSecondControl(
        rig,
        seat: 3,
        words: _waitWords[lang]!,
        wordsLabel: _waitWords[lang]!,
        wordKind: 'Wait',
      );
    });
  });

  // ===========================================================================
  // Row 6: the origin mark
  // ===========================================================================
  group('origin mark size and place (X236)', () {
    // Room A: link, code, approved (the last one away, so the offline icon is
    // on a card that carries a mark). Room B: public and a computer seat, with
    // me as seat 0 so the "You" pill exists.
    const List<_Seat> roomA = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Abdulrahman', via: 'link'),
      _Seat(2, 'Mohammed', via: 'code'),
      _Seat(3, 'Alexander', via: 'approved', connected: false),
    ];
    const List<_Seat> roomB = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Christopher', via: 'public'),
      _Seat(2, 'Nono', bot: 2),
      _Seat(3, 'Elizabeth', via: 'link'),
    ];
    const List<Size> sizes = <Size>[Size(360, 616), Size(320, 640)];

    for (final Size size in sizes) {
      final String dim = '${size.width.toInt()}x${size.height.toInt()}';
      for (final List<Object> scenario in <List<Object>>[
        <Object>['link, code, approved', roomA],
        <Object>['public, computer', roomB],
      ]) {
        final String label = scenario[0] as String;
        final List<_Seat> seats = scenario[1] as List<_Seat>;
        _row('row 6: marks for $label at $dim are at least 20x20 and clear of '
            'the name', (tester, locale, name) async {
          final _Rig rig = await _lobby(
            tester,
            name: name,
            locale: locale,
            seats: seats,
            open: false,
            size: size,
          );
          final List<String> problems = <String>[];
          double? botHeight;
          for (final _Seat s in seats) {
            if (s.via == 'host') {
              continue;
            }
            final Finder markF = find.byKey(Key('seat-origin-${s.seat}'));
            if (markF.evaluate().isEmpty) {
              problems.add('seat ${s.seat} ($s) has no seat-origin-${s.seat}');
              continue;
            }
            final Rect mark = rig.tester.getRect(markF);
            if (mark.width < 20 || mark.height < 20) {
              problems.add(
                'seat ${s.seat} mark is ${_fmt(mark)}, needs at least 20x20',
              );
            }
            if (s.bot != null) {
              botHeight = mark.height;
            }
            final Finder card = find.byKey(Key('lobby-seat-${s.seat}'));
            final Rect cardRect = rig.tester.getRect(card);
            final Finder pill = find.descendant(
              of: card,
              matching: find.byKey(Key('lobby-seat-${s.seat}-you')),
            );
            final Finder names = find.descendant(
              of: card,
              matching: find.byType(Text),
            );
            for (final Element e in names.evaluate()) {
              final RenderBox box = e.renderObject! as RenderBox;
              final Rect r = box.localToGlobal(Offset.zero) & box.size;
              if (pill.evaluate().isNotEmpty &&
                  find
                      .descendant(of: pill, matching: find.byWidget(e.widget))
                      .evaluate()
                      .isNotEmpty) {
                continue;
              }
              if (mark.overlaps(r)) {
                problems.add(
                  'seat ${s.seat} mark ${_fmt(mark)} overlaps the card text '
                  '"${(e.widget as Text).data}" ${_fmt(r)} '
                  'in card ${_fmt(cardRect)}',
                );
              }
            }
            final Finder wifi = find.descendant(
              of: card,
              matching: find.byIcon(Icons.wifi_off),
            );
            for (final Element e in wifi.evaluate()) {
              final RenderBox box = e.renderObject! as RenderBox;
              final Rect r = box.localToGlobal(Offset.zero) & box.size;
              if (mark.overlaps(r)) {
                problems.add(
                  'seat ${s.seat} mark ${_fmt(mark)} overlaps the offline '
                  'icon ${_fmt(r)}',
                );
              }
            }
          }
          if (botHeight != null) {
            final Finder pillF = find.byKey(const Key('lobby-seat-0-you'));
            if (pillF.evaluate().isEmpty) {
              problems.add('fixture: no lobby-seat-0-you pill on my seat');
            } else {
              final double pillH = rig.tester.getSize(pillF).height;
              if (botHeight < pillH) {
                problems.add(
                  'the computer mark is ${botHeight.toStringAsFixed(1)} tall, '
                  'shorter than the You pill (${pillH.toStringAsFixed(1)})',
                );
              }
            }
          }
          expect(
            problems,
            isEmpty,
            reason: rig.why(
              'every origin mark at least 20x20, not shorter than the You '
              'pill (computer), and clear of the name and the offline icon; '
              'problems: $problems',
            ),
          );
        });
      }
    }
  });

  // ===========================================================================
  // Row 7: the origin mark must not hide the seat's token shape
  // ===========================================================================
  group('origin mark leaves the token shape visible (X236, P9)', () {
    // The shape glyph is the `SeatMark` descendant of `lobby-seat-<n>-token`
    // (found by type; the origin mark draws Icons, never a SeatMark). Its rect
    // is the widget's own box.
    const List<_Seat> roomA = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Abdulrahman', via: 'link'),
      _Seat(2, 'Mohammed', via: 'code'),
      _Seat(3, 'Alexander', via: 'approved'),
    ];
    const List<_Seat> roomB = <_Seat>[
      _Seat(0, 'Sam', via: 'host'),
      _Seat(1, 'Christopher', via: 'public'),
      _Seat(2, 'Nono', bot: 2),
      _Seat(3, 'Elizabeth', via: 'link'),
    ];
    for (final Size size in const <Size>[Size(360, 616), Size(320, 640)]) {
      final String dim = '${size.width.toInt()}x${size.height.toInt()}';
      for (final List<Object> scenario in <List<Object>>[
        <Object>['link, code, approved', roomA],
        <Object>['public, computer', roomB],
      ]) {
        final String label = scenario[0] as String;
        final List<_Seat> seats = scenario[1] as List<_Seat>;
        _row('row 7: marks for $label at $dim cover at most 25% of the token '
            'shape and stay clear of the name', (tester, locale, name) async {
          final _Rig rig = await _lobby(
            tester,
            name: name,
            locale: locale,
            seats: seats,
            open: false,
            size: size,
          );
          final List<String> problems = <String>[];
          for (final _Seat s in seats) {
            if (s.via == 'host') {
              continue;
            }
            final Finder markF = find.byKey(Key('seat-origin-${s.seat}'));
            final Finder glyphF = find.descendant(
              of: find.byKey(Key('lobby-seat-${s.seat}-token')),
              matching: find.byType(SeatMark),
            );
            if (markF.evaluate().isEmpty || glyphF.evaluate().length != 1) {
              problems.add(
                'seat ${s.seat}: seat-origin found '
                '${markF.evaluate().length}, token SeatMark found '
                '${glyphF.evaluate().length}',
              );
              continue;
            }
            final Rect mark = rig.tester.getRect(markF);
            final Rect glyph = rig.tester.getRect(glyphF);
            final Rect hit = mark.intersect(glyph);
            final double covered = (hit.width <= 0 || hit.height <= 0)
                ? 0
                : hit.width * hit.height;
            final double area = glyph.width * glyph.height;
            if (covered > 0.25 * area) {
              problems.add(
                'seat ${s.seat} ($s): mark ${_fmt(mark)} covers '
                '${(100 * covered / area).toStringAsFixed(0)}% of the token '
                'shape ${_fmt(glyph)}, at most 25% allowed',
              );
            }
            final Finder card = find.byKey(Key('lobby-seat-${s.seat}'));
            for (final Element e
                in find
                    .descendant(of: card, matching: find.byType(Text))
                    .evaluate()) {
              final RenderBox box = e.renderObject! as RenderBox;
              final Rect r = box.localToGlobal(Offset.zero) & box.size;
              if (mark.overlaps(r)) {
                problems.add(
                  'seat ${s.seat} mark ${_fmt(mark)} overlaps the card text '
                  '"${(e.widget as Text).data}" ${_fmt(r)}',
                );
              }
            }
          }
          expect(
            problems,
            isEmpty,
            reason: rig.why(
              'marks cover at most 25% of the token shape and '
              'clear the name; problems: $problems',
            ),
          );
        });
      }
    }
  });
}
