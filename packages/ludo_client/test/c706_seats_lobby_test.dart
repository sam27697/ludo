// C-706t: who sits here, in the lobby (order 706, docs/PROTOCOL.md section 33
// item 5 and section 34 items 1 and 3).
//
//   - a seat with `via: "public"` carries the origin mark with the glyph
//     `public_rounded` and the spoken words `seatOriginPublic`; a `link` seat
//     beside it keeps its own;
//   - a computer seat (`bot` 1..6, `via: "bot"`) shows `botName<n>` in the
//     app's language, never the wire name, with the glyph `smart_toy_rounded`
//     and the words `seatOriginBot`; six ids give six names in each language;
//   - a computer seat never shows the away treatment the lobby gives a dropped
//     seat today (the wifi-off icon, the muted name, the muted tile);
//   - `lobby-fill-computer`: host, open room, a free seat, once the snapshot's
//     `fill_ms` has run out on the test clock; never for a guest, a
//     friends-only room, a full room or a snapshot without `fill_ms`; one tap
//     sends one `fill_computer`, the control is disabled until the answer, an
//     error answer shows the lobby's error words and re-enables it; a new
//     snapshot restarts the count; 48 dp or more, above the start control;
//   - no overflow at text scale 1.3 with four seats, two of them computers.
//
// Written from the order's design and the protocol. A real RoomController over
// FakeTransport and a real LobbyScreen; frames pushed one by one. Nothing the
// new lib adds is imported: the control is found by its key, glyphs by their
// Icons constant, and the new words are read from lib/l10n/app_<lang>.arb at
// run time so that a key missing from the arb is a red row with a message, not
// a file that does not compile.
//
// Time: every wait is `tester.pump(Duration)` on the test clock. No real
// sleeps, no pumpAndSettle while the fill count is ticking.
//
// Every row runs in en and ar at 320x640 and 412x915. Its name ends with the
// variant, e.g. 'fill.arrival [ar 320x640]'. Rerun one row with:
//   cd packages/ludo_client && flutter test test/c706_seats_lobby_test.dart \
//     --plain-name '<row name with variant>'

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/install_id.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _file = 'c706_seats_lobby_test.dart';
const String _testUrl = 'wss://c706-lobby.invalid/ws';
const String _code = 'K7M2QP';
const String _linkId = 't5k2q9a-x7m3pd';
const Key _fillKey = Key('lobby-fill-computer');
const Key _startWithPresentKey = Key('lobby-start-with-present-button');

/// Section 34 item 1: the wire name of each character.
const Map<int, String> _wireBotNames = <int, String>{
  1: 'Zuzu',
  2: 'Nono',
  3: 'Kiko',
  4: 'Bobo',
  5: 'Tutu',
  6: 'Mimi',
};

// --- the matrix --------------------------------------------------------------

class _Variant {
  const _Variant(this.lang, this.size, {this.scale = 1.0});

  final String lang;
  final Size size;
  final double scale;

  Locale get locale => Locale(lang);

  String get id =>
      '$lang ${size.width.toInt()}x${size.height.toInt()}'
      '${scale == 1.0 ? '' : ' scale $scale'}';
}

const Size _small = Size(320, 640);
const Size _large = Size(412, 915);

const List<_Variant> _variants = <_Variant>[
  _Variant('en', _small),
  _Variant('ar', _small),
  _Variant('en', _large),
  _Variant('ar', _large),
];

/// Declares [row] once per variant. The body gets the variant and the full
/// test name, which is what --plain-name takes.
void _row(
  String row,
  Future<void> Function(WidgetTester tester, _Variant v, String name) body, {
  List<_Variant> variants = _variants,
}) {
  for (final _Variant v in variants) {
    final String name = '$row [${v.id}]';
    testWidgets(name, (WidgetTester tester) => body(tester, v, name));
  }
}

// --- strings from the arb files ----------------------------------------------

final Map<String, Map<String, Object?>> _arbs =
    <String, Map<String, Object?>>{};

Map<String, Object?> _arbOf(String lang) => _arbs.putIfAbsent(lang, () {
  final File f = File('lib/l10n/app_$lang.arb');
  return jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
});

/// The arb value of [key] in [lang], or a failure naming the missing key.
String _s(String lang, String key, String why) {
  final Object? value = _arbOf(lang)[key];
  if (value is! String) {
    fail(
      'expected lib/l10n/app_$lang.arb to hold the string "$key" (order 706 '
      'names it as on the base), found ${value == null ? 'no such key' : value.runtimeType}. '
      '$why',
    );
  }
  return value;
}

// --- frames ------------------------------------------------------------------

int _serverIdSeq = 0;

String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c706-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

/// One seat of a snapshot. [bot] makes it a computer seat as section 34 item 1
/// writes one: `bot`, `via: "bot"`, `connected` true unless the row says not.
class _Seat {
  const _Seat(this.seat, this.name, {this.via = 'link', this.connected = true})
    : bot = null;

  const _Seat.host(this.name)
    : seat = 0,
      via = 'host',
      bot = null,
      connected = true;

  const _Seat.bot(this.seat, int this.bot, {String? wireName, bool? connected})
    : name = wireName ?? '',
      via = 'bot',
      connected = connected ?? true;

  final int seat;
  final String name;
  final String via;
  final int? bot;
  final bool connected;

  String get wireName =>
      bot != null && name.isEmpty ? _wireBotNames[bot]! : name;

  Map<String, Object?> toJson() => <String, Object?>{
    'seat': seat,
    'name': wireName,
    'connected': connected,
    'tokens': const <int>[-1, -1, -1, -1],
    'client_seed': null,
    'seed_origin': bot != null ? 'server' : null,
    'via': via,
    'bot': ?bot,
  };

  @override
  String toString() =>
      '$seat:$wireName/$via${bot == null ? '' : '/bot$bot'}'
      '${connected ? '' : '/down'}';
}

/// A LOBBY snapshot. [fillMs] null leaves the `fill_ms` key out.
Map<String, Object?> _roomJson({
  required int seq,
  required List<_Seat> seats,
  required bool open,
  int? fillMs,
  int players = 4,
}) => <String, Object?>{
  'code': _code,
  'state': 'LOBBY',
  'host_seat': 0,
  'players': players,
  'open': open,
  'fill_ms': ?fillMs,
  'rules': const <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[for (final _Seat s in seats) s.toJson()],
  'turn': null,
  'winner': null,
  'seq': seq,
  'link_id': _linkId,
  'guest_approval': false,
  'knocks': const <Object?>[],
};

class _Recording implements FeedbackService {
  final List<FeedbackCue> played = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) => played.add(cue);
}

// --- the rig -----------------------------------------------------------------

class _Lobby {
  _Lobby._(
    this.tester,
    this.v,
    this.name,
    this.controller,
    this.transport,
    this.feedback,
    this.seq,
  );

  final WidgetTester tester;
  final _Variant v;
  final String name;
  final RoomController controller;
  final FakeTransport transport;
  final _Recording feedback;
  final List<String> pushed = <String>[];
  int seq;

  /// Test clock elapsed since the last snapshot arrived, as the rows count it.
  int msSinceSnapshot = 0;

  String get lang => v.lang;

  AppLocalizations get loc => lookupAppLocalizations(v.locale);

  String get why =>
      'variant ${v.id}; pushed ${pushed.join(' | ')}; sent '
      '${transport.sentRaw.map((String r) => _decode(r)['t']).toList()}; '
      '$msSinceSnapshot ms of test clock since the last snapshot. rerun: '
      "cd packages/ludo_client && flutter test test/$_file --plain-name '$name'";

  /// Mounts the lobby, answers its create (host) or join (guest) with
  /// `seat_assigned` and the first `room`, and returns once it is connected.
  static Future<_Lobby> open(
    WidgetTester tester,
    _Variant v,
    String name, {
    required List<_Seat> seats,
    bool host = true,
    bool open = true,
    int? fillMs,
    int players = 4,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = v.size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final FakeTransport transport = FakeTransport();
    bool connected = false;
    final RoomController controller = RoomController(
      serverUrl: Uri.parse(_testUrl),
      connect: (Uri url) async {
        if (connected) {
          throw StateError('c706 rig: a second connect was not expected');
        }
        connected = true;
        return transport as WireTransport;
      },
      autoReconnectDelays: const <Duration>[],
    );
    final _Recording feedback = _Recording();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(),
        locale: v.locale,
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(v.scale)),
          child: child!,
        ),
        home: FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: feedback,
          child: LobbyScreen(
            controller: controller,
            action: host ? LobbyAction.create : LobbyAction.join,
            code: host ? null : _code,
            playerName: host ? 'Sam' : 'Bob',
            players: players,
            open: host && open,
          ),
        ),
      ),
    );
    final _Lobby l = _Lobby._(
      tester,
      v,
      name,
      controller,
      transport,
      feedback,
      10,
    );
    addTearDown(() async {
      controller.dispose();
    });
    final String request = host ? 'create_room' : 'join_room';
    for (int i = 0; i < 40 && l.sent(request).isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      l.sent(request),
      hasLength(1),
      reason: 'fixture: expected the lobby to send one $request. ${l.why}',
    );
    final String reqId = l.idOfLast(request);
    final int mine = host ? 0 : 1;
    transport.pushText(
      _frame('seat_assigned', <String, Object?>{
        'seat': mine,
        'seat_token': 'tok-c706-$mine',
      }),
    );
    final Map<String, Object?> room = _roomJson(
      seq: l.seq,
      seats: seats,
      open: open,
      fillMs: fillMs,
      players: players,
    );
    l.pushed.add('seat_assigned{seat:$mine}');
    l.pushed.add(
      'room{seats:$seats, open:$open, fill_ms:${fillMs ?? 'absent'}, '
      'players:$players}',
    );
    transport.pushText(_frame('room', room, re: reqId));
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.connected,
      reason: 'fixture: expected the controller connected. ${l.why}',
    );
    feedback.played.clear();
    return l;
  }

  /// Every client frame of [type], whole (`t`, `id`, `d`).
  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String raw in transport.sentRaw)
      if (_decode(raw)['t'] == type) _decode(raw),
  ];

  String idOfLast(String type) => sent(type).last['id']! as String;

  Future<void> push(
    String type,
    Map<String, Object?> data, {
    String? re,
    String? note,
  }) async {
    pushed.add(note ?? '$type${jsonEncode(data)}${re == null ? '' : ' re'}');
    transport.pushText(_frame(type, data, re: re));
    await tester.pump();
    await tester.pump();
  }

  /// An unsolicited `room` push, the next seq.
  Future<void> pushRoom({
    required List<_Seat> seats,
    required bool open,
    int? fillMs,
    int players = 4,
  }) async {
    seq += 1;
    await push(
      'room',
      _roomJson(
        seq: seq,
        seats: seats,
        open: open,
        fillMs: fillMs,
        players: players,
      ),
      note:
          'room{seq:$seq, seats:$seats, open:$open, '
          'fill_ms:${fillMs ?? 'absent'}}',
    );
    msSinceSnapshot = 0;
  }

  /// Moves the test clock by [ms] in steps of at most 100 ms, so a countdown
  /// that ticks on its own timer is driven frame by frame.
  Future<void> advance(int ms) async {
    int left = ms;
    while (left > 0) {
      final int step = left < 100 ? left : 100;
      await tester.pump(Duration(milliseconds: step));
      left -= step;
      msSinceSnapshot += step;
    }
  }

  Finder seatCard(int seat) => find.byKey(Key('lobby-seat-$seat'));

  /// Every Text drawn inside the card of [seat].
  List<String> texts(int seat) => <String>[
    for (final Element e
        in find
            .descendant(of: seatCard(seat), matching: find.byType(Text))
            .evaluate())
      (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText(),
  ];

  /// Every icon drawn inside [of].
  List<IconData?> icons(Finder of) => <IconData?>[
    for (final Element e
        in find.descendant(of: of, matching: find.byType(Icon)).evaluate())
      (e.widget as Icon).icon,
  ];

  String label(Finder f) {
    final SemanticsHandle h = tester.ensureSemantics();
    try {
      return tester.getSemantics(f).label;
    } finally {
      h.dispose();
    }
  }

  /// The semantics enabled state of the node at [f]: true, false, or null
  /// when the node does not say.
  bool? enabled(Finder f) {
    final SemanticsHandle h = tester.ensureSemantics();
    try {
      final Tristate t = tester.getSemantics(f).flagsCollection.isEnabled;
      return switch (t) {
        Tristate.isTrue => true,
        Tristate.isFalse => false,
        Tristate.none => null,
      };
    } finally {
      h.dispose();
    }
  }

  /// All text on screen, for failure messages.
  String screenTexts() => <String>[
    for (final Element e in find.byType(Text).evaluate())
      (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText(),
  ].join(' / ');

  void expectFillAbsent(String when) {
    expect(
      find.byKey(_fillKey),
      findsNothing,
      reason:
          'expected no lobby-fill-computer $when, found '
          '${find.byKey(_fillKey).evaluate().length}. $why',
    );
  }

  void expectFillPresent(String when) {
    expect(
      find.byKey(_fillKey),
      findsOneWidget,
      reason:
          'expected exactly one lobby-fill-computer $when, found '
          '${find.byKey(_fillKey).evaluate().length}. $why',
    );
  }

  Future<void> tapFill() async {
    pushed.add('<tap lobby-fill-computer>');
    await tester.tap(find.byKey(_fillKey), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
  }

  /// The away treatment the lobby gives a dropped seat today
  /// (lib/src/seat_card.dart on the base): the wifi-off icon, the name drawn
  /// in [LudoColors.inkMuted], the tile tinted with the muted ink. Returns the
  /// signals found on the card of [seat].
  List<String> awaySignals(int seat) {
    final List<String> found = <String>[];
    if (icons(seatCard(seat)).contains(Icons.wifi_off)) {
      found.add('wifi_off icon');
    }
    for (final RenderParagraph p in tester.renderObjectList<RenderParagraph>(
      find.descendant(of: seatCard(seat), matching: find.byType(RichText)),
    )) {
      if (p.text.style?.color == LudoColors.inkMuted) {
        found.add('text "${p.text.toPlainText()}" in inkMuted');
      }
    }
    final Widget card = tester.widget(seatCard(seat));
    if (card is Container && card.decoration is BoxDecoration) {
      final Color? tile = (card.decoration! as BoxDecoration).color;
      if (tile == LudoColors.inkMuted.withValues(alpha: 0.08)) {
        found.add('muted tile');
      }
    }
    return found;
  }
}

// --- rows --------------------------------------------------------------------

/// Host seat 0, two humans, seat 3 free: the one-empty-seat lobby.
const List<_Seat> _threeSeated = <_Seat>[
  _Seat.host('Sam'),
  _Seat(1, 'Ann'),
  _Seat(2, 'Pia', via: 'public'),
];

const List<_Seat> _fourSeated = <_Seat>[
  _Seat.host('Sam'),
  _Seat(1, 'Ann'),
  _Seat(2, 'Pia', via: 'public'),
  _Seat(3, 'Rex', via: 'public'),
];

void main() {
  late String install;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    install = await installId();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kInstallIdKey: install,
    });
  });

  // ===========================================================================
  // The random-players mark
  // ===========================================================================
  group('public mark', () {
    _row('public.mark: a public seat shows public_rounded and its label; a '
        'link seat keeps its own', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(tester, v, name, seats: _threeSeated);
      final List<IconData?> publicIcons = l.icons(l.seatCard(2));
      expect(
        publicIcons.contains(Icons.public_rounded),
        isTrue,
        reason:
            'expected the public seat (2) to draw Icons.public_rounded, its '
            'card draws $publicIcons. ${l.why}',
      );
      final List<IconData?> linkIcons = l.icons(l.seatCard(1));
      expect(
        linkIcons.contains(Icons.link) &&
            !linkIcons.contains(Icons.public_rounded),
        isTrue,
        reason:
            'expected the link seat (1) to keep Icons.link and not draw '
            'public_rounded, its card draws $linkIcons. ${l.why}',
      );
      expect(
        find.byKey(const Key('seat-origin-2')),
        findsOneWidget,
        reason:
            'expected the public seat to carry the origin mark the link and '
            'code seats carry (seat-origin-2). ${l.why}',
      );
      final String linkWords = l.loc.seatOriginLink;
      final String publicWords = _s(v.lang, 'seatOriginPublic', l.why);
      final String publicLabel = l.label(l.seatCard(2));
      expect(
        publicLabel.contains(publicWords),
        isTrue,
        reason:
            'expected the public seat card to say "$publicWords", it says '
            '"$publicLabel". ${l.why}',
      );
      expect(
        publicLabel.contains(linkWords),
        isFalse,
        reason:
            'expected the public seat card not to say "$linkWords", it says '
            '"$publicLabel". ${l.why}',
      );
      final String linkLabel = l.label(l.seatCard(1));
      expect(
        linkLabel.contains(linkWords) && !linkLabel.contains(publicWords),
        isTrue,
        reason:
            'expected the link seat card to say "$linkWords" and not '
            '"$publicWords", it says "$linkLabel". ${l.why}',
      );
      expect(tester.takeException(), isNull, reason: l.why);
    });
  });

  // ===========================================================================
  // Computer seats
  // ===========================================================================
  group('computer seat', () {
    _row('bot.name: bot 1 shows botName1 in the locale, the robot mark and '
        'its label', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        open: false,
        seats: const <_Seat>[_Seat.host('Sam'), _Seat.bot(1, 1)],
      );
      final List<IconData?> icons = l.icons(l.seatCard(1));
      expect(
        icons.contains(Icons.smart_toy_rounded),
        isTrue,
        reason:
            'expected Icons.smart_toy_rounded on the computer seat card, it '
            'draws $icons. ${l.why}',
      );
      final String shown = _s(v.lang, 'botName1', l.why);
      final String botWords = _s(v.lang, 'seatOriginBot', l.why);
      if (v.lang == 'ar') {
        expect(
          shown,
          'زوزو',
          reason:
              'expected app_ar.arb botName1 to be the order\'s "زوزو", found '
              '"$shown". ${l.why}',
        );
      }
      final List<String> texts = l.texts(1);
      expect(
        texts.contains(shown),
        isTrue,
        reason:
            'expected the computer seat card to show "$shown" (botName1, '
            '${v.lang}), it shows $texts. ${l.why}',
      );
      if (shown != 'Zuzu') {
        expect(
          find.text('Zuzu').evaluate().isEmpty &&
              find.textContaining('Zuzu').evaluate().isEmpty,
          isTrue,
          reason:
              'expected the wire name "Zuzu" nowhere on screen in ${v.lang}, '
              'screen shows: ${l.screenTexts()}. ${l.why}',
        );
      }
      final String label = l.label(l.seatCard(1));
      expect(
        label.contains(botWords),
        isTrue,
        reason:
            'expected the computer seat card to say "$botWords", it says '
            '"$label". ${l.why}',
      );
      expect(
        label.contains(l.loc.seatOriginLink),
        isFalse,
        reason:
            'a computer seat did not come by link; label "$label". ${l.why}',
      );
      expect(tester.takeException(), isNull, reason: l.why);
    });

    // Unreachable on a correct server (the name is always bot's own), kept
    // to prove the shown name follows `bot` and not `name`.
    _row('bot.name_follows_id: bot 3 sent with the wire name Zuzu shows '
        'botName3', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        open: false,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat.bot(2, 3, wireName: 'Zuzu'),
        ],
      );
      final String shown = _s(v.lang, 'botName3', l.why);
      expect(
        l.texts(2).contains(shown),
        isTrue,
        reason:
            'expected "$shown" (botName3) on seat 2, it shows ${l.texts(2)}. '
            '${l.why}',
      );
      expect(
        find.textContaining('Zuzu').evaluate().isEmpty,
        isTrue,
        reason:
            'expected the wire name "Zuzu" nowhere, the shown name follows '
            '`bot`; screen shows: ${l.screenTexts()}. ${l.why}',
      );
    });

    _row('bot.six_names: ids 1..6 show six distinct botName<n>', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        open: false,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat.bot(1, 1),
          _Seat.bot(2, 2),
          _Seat.bot(3, 3),
        ],
      );
      final Map<int, String> shownById = <int, String>{};
      for (final int id in <int>[1, 2, 3]) {
        final String want = _s(v.lang, 'botName$id', l.why);
        expect(
          l.texts(id).contains(want),
          isTrue,
          reason:
              'expected seat $id (bot $id) to show "$want", it shows '
              '${l.texts(id)}. ${l.why}',
        );
        shownById[id] = want;
      }
      await l.pushRoom(
        open: false,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat.bot(1, 4),
          _Seat.bot(2, 5),
          _Seat.bot(3, 6),
        ],
      );
      await l.advance(500);
      for (final int id in <int>[4, 5, 6]) {
        final String want = _s(v.lang, 'botName$id', l.why);
        expect(
          l.texts(id - 3).contains(want),
          isTrue,
          reason:
              'expected seat ${id - 3} (bot $id) to show "$want", it shows '
              '${l.texts(id - 3)}. ${l.why}',
        );
        shownById[id] = want;
      }
      expect(
        shownById.values.toSet().length,
        6,
        reason:
            'expected six distinct names for bot ids 1..6 in ${v.lang}, '
            'found $shownById. ${l.why}',
      );
    });

    for (final bool up in <bool>[false, true]) {
      _row('bot.no_away: a computer seat with connected $up shows no away '
          'treatment', (tester, v, name) async {
        final _Lobby l = await _Lobby.open(
          tester,
          v,
          name,
          open: false,
          seats: <_Seat>[
            const _Seat.host('Sam'),
            const _Seat(1, 'Ann', connected: false),
            _Seat.bot(2, 1, connected: up),
          ],
        );
        // The detector itself: a dropped human seat must show the treatment,
        // or this row measures nothing.
        final List<String> human = l.awaySignals(1);
        expect(
          human,
          containsAll(<String>['wifi_off icon', 'text "Ann" in inkMuted']),
          reason:
              'fixture: expected the dropped human seat 1 to show the away '
              'treatment the bot is checked against, found $human; the '
              'detector in awaySignals is stale. ${l.why}',
        );
        final List<String> bot = l.awaySignals(2);
        expect(
          bot,
          isEmpty,
          reason:
              'expected no away treatment on the computer seat (connected '
              '$up on the wire), found $bot. ${l.why}',
        );
        final String shown = _s(v.lang, 'botName1', l.why);
        expect(
          l.texts(2).contains(shown),
          isTrue,
          reason:
              'expected the computer seat to show "$shown", it shows '
              '${l.texts(2)}. ${l.why}',
        );
      });
    }
  });

  // ===========================================================================
  // Fill with computer: when it shows
  // ===========================================================================
  group('fill shows', () {
    _row('fill.arrival: absent at arrival and at 4900 ms of fill_ms 5000, '
        'present from 5000 ms', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _threeSeated,
        fillMs: 5000,
      );
      l.expectFillAbsent('at arrival with fill_ms 5000');
      await l.advance(4900);
      l.expectFillAbsent('at 4900 ms of a 5000 ms fill_ms');
      await l.advance(100);
      await tester.pump();
      l.expectFillPresent('once 5000 ms of fill_ms 5000 have passed');
      await l.advance(600);
      final String words = _s(v.lang, 'lobbyFillComputer', l.why);
      final Finder control = find.byKey(_fillKey);
      expect(
        find
            .descendant(of: control, matching: find.text(words))
            .evaluate()
            .isNotEmpty,
        isTrue,
        reason:
            'expected the control to read "$words" (lobbyFillComputer), '
            'screen shows ${l.screenTexts()}. ${l.why}',
      );
      expect(
        l.icons(control).contains(Icons.smart_toy_rounded),
        isTrue,
        reason:
            'expected Icons.smart_toy_rounded on the control, it draws '
            '${l.icons(control)}. ${l.why}',
      );
      expect(tester.takeException(), isNull, reason: l.why);
    });

    _row('fill.zero: fill_ms 0 at arrival shows the control at once', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _threeSeated,
        fillMs: 0,
      );
      await tester.pump();
      l.expectFillPresent('with fill_ms 0 at arrival');
    });

    _row('fill.size_place: at least 48 dp tall, inside the screen, above the '
        'start control', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _threeSeated,
        fillMs: 0,
      );
      await l.advance(800);
      l.expectFillPresent('with fill_ms 0 after the enter motion');
      final Rect fill = tester.getRect(find.byKey(_fillKey));
      expect(
        fill.height >= 48,
        isTrue,
        reason:
            'expected the control 48 dp or taller, it is ${fill.height}. '
            '${l.why}',
      );
      expect(
        fill.left >= -0.5 &&
            fill.right <= v.size.width + 0.5 &&
            fill.top >= -0.5 &&
            fill.bottom <= v.size.height + 0.5,
        isTrue,
        reason:
            'expected the control inside the ${v.size} screen, it spans '
            '$fill. ${l.why}',
      );
      expect(
        find.byKey(_startWithPresentKey),
        findsOneWidget,
        reason:
            'fixture: expected the host start control '
            '(lobby-start-with-present-button) with three of four seated. '
            '${l.why}',
      );
      final Rect start = tester.getRect(find.byKey(_startWithPresentKey));
      expect(
        fill.bottom <= start.top + 0.5,
        isTrue,
        reason:
            'expected the control above the start control: control $fill, '
            'start $start. ${l.why}',
      );
    });

    _row('fill.guest: absent for a guest, with no fill_ms and with fill_ms 0', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        host: false,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat(1, 'Bob'),
          _Seat(2, 'Pia', via: 'public'),
        ],
      );
      await l.advance(6000);
      l.expectFillAbsent(
        'for a guest 6000 ms after a snapshot without '
        'fill_ms',
      );
      // The server omits fill_ms for a guest; a stray one must not turn the
      // control on either.
      await l.pushRoom(
        open: true,
        fillMs: 0,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat(1, 'Bob'),
          _Seat(2, 'Pia', via: 'public'),
        ],
      );
      await l.advance(6000);
      l.expectFillAbsent('for a guest, even with fill_ms 0 in its snapshot');
    });

    _row('fill.friends_only: absent with open false', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        open: false,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat(1, 'Ann'),
          _Seat(2, 'Cat', via: 'code'),
        ],
        fillMs: 0,
      );
      await l.advance(6000);
      l.expectFillAbsent(
        'in a friends-only room (open false; fill_ms 0 sent '
        'defensively)',
      );
    });

    _row('fill.full: absent in a full room', (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _fourSeated,
        fillMs: 0,
      );
      await l.advance(6000);
      l.expectFillAbsent('in a full open room (fill_ms 0 sent defensively)');
    });

    _row('fill.no_key: absent when fill_ms is missing', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await _Lobby.open(tester, v, name, seats: _threeSeated);
      await l.advance(6000);
      l.expectFillAbsent('6000 ms after a host snapshot without fill_ms');
      await l.advance(60000);
      l.expectFillAbsent('66000 ms after a host snapshot without fill_ms');
    });

    _row('fill.restart: a new fill_ms restarts the count from its value', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _threeSeated,
        fillMs: 5000,
      );
      await l.advance(3000);
      l.expectFillAbsent('3000 ms into fill_ms 5000');
      await l.pushRoom(open: true, seats: _threeSeated, fillMs: 4000);
      await l.advance(2500);
      l.expectFillAbsent(
        '2500 ms after a new fill_ms 4000 (5500 ms after the first '
        'snapshot; the old count would have run out)',
      );
      await l.advance(1500);
      await tester.pump();
      l.expectFillPresent('4000 ms after the new fill_ms 4000');
      await l.advance(600);

      await l.pushRoom(open: true, seats: _threeSeated, fillMs: 3000);
      await l.advance(600);
      l.expectFillAbsent('600 ms after a new snapshot with fill_ms 3000');
      await l.advance(2300);
      l.expectFillAbsent('2900 ms after a new snapshot with fill_ms 3000');
      await l.advance(100);
      await tester.pump();
      l.expectFillPresent('3000 ms after a new snapshot with fill_ms 3000');

      await l.pushRoom(open: true, seats: _threeSeated, fillMs: 0);
      await tester.pump();
      l.expectFillPresent('after a further snapshot with fill_ms 0');
    });

    _row('fill.room_fills: a seat taken while the control shows removes it', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _threeSeated,
        fillMs: 0,
      );
      await l.advance(600);
      l.expectFillPresent('with fill_ms 0');
      await l.pushRoom(open: true, seats: _fourSeated);
      await l.advance(600);
      l.expectFillAbsent('once the room is full');
    });
  });

  // ===========================================================================
  // Fill with computer: the tap and its answer
  // ===========================================================================
  group('fill tap', () {
    Future<_Lobby> ready(WidgetTester tester, _Variant v, String name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        seats: _threeSeated,
        fillMs: 0,
      );
      await l.advance(800);
      l.expectFillPresent('with fill_ms 0 after the enter motion');
      l.feedback.played.clear();
      return l;
    }

    _row('tap.one_frame: one tap sends exactly one fill_computer with an '
        'empty payload, and the tap tick', (tester, v, name) async {
      final _Lobby l = await ready(tester, v, name);
      await l.tapFill();
      final List<Map<String, Object?>> frames = l.sent('fill_computer');
      expect(
        frames,
        hasLength(1),
        reason:
            'expected one fill_computer after one tap, found '
            '${frames.length}. ${l.why}',
      );
      final Object? d = frames.single['d'];
      expect(
        d is Map && d.isEmpty,
        isTrue,
        reason:
            'expected fill_computer d {} (section 34 item 3: any key is '
            'BAD_FIELD), found $d. ${l.why}',
      );
      expect(
        l.feedback.played.contains(FeedbackCue.tap),
        isTrue,
        reason:
            'expected the valid-tap tick (FeedbackCue.tap) on the tap, '
            'played ${l.feedback.played}. ${l.why}',
      );
    });

    _row('tap.disabled: disabled while the request is out; a second tap '
        'sends nothing', (tester, v, name) async {
      final _Lobby l = await ready(tester, v, name);
      expect(
        l.enabled(find.byKey(_fillKey)),
        isTrue,
        reason: 'expected the control enabled before the tap. ${l.why}',
      );
      await l.tapFill();
      await l.advance(300);
      expect(
        l.enabled(find.byKey(_fillKey)),
        isFalse,
        reason:
            'expected the control disabled while fill_computer is '
            'unanswered. ${l.why}',
      );
      await l.tapFill();
      await l.advance(300);
      expect(
        l.sent('fill_computer'),
        hasLength(1),
        reason:
            'expected the second tap to send nothing, found '
            '${l.sent('fill_computer').length} fill_computer frames. '
            '${l.why}',
      );
      // A room push while the request is out does not re-arm it.
      await l.pushRoom(open: true, seats: _threeSeated, fillMs: 0);
      await l.advance(300);
      await l.tapFill();
      expect(
        l.sent('fill_computer'),
        hasLength(1),
        reason:
            'expected a tap after an unrelated room push, the request '
            'still out, to send nothing; found '
            '${l.sent('fill_computer').length} fill_computer frames. '
            '${l.why}',
      );
    });

    _row('tap.error: an error answer shows the lobby error words and '
        're-enables the control', (tester, v, name) async {
      final _Lobby l = await ready(tester, v, name);
      await l.tapFill();
      final String id = l.idOfLast('fill_computer');
      await l.push('error', <String, Object?>{
        'code': 'WRONG_PHASE',
        'message': 'not yet',
      }, re: id);
      await l.advance(300);
      final String words = lobbyErrorMessage(l.loc, 'WRONG_PHASE');
      expect(
        find.text(words),
        findsOneWidget,
        reason:
            'expected the lobby error words "$words" on screen after '
            'WRONG_PHASE, screen shows: ${l.screenTexts()}. ${l.why}',
      );
      l.expectFillPresent('after the error answer');
      expect(
        l.enabled(find.byKey(_fillKey)),
        isTrue,
        reason:
            'expected the control enabled again after the error answer. '
            '${l.why}',
      );
      await l.tapFill();
      expect(
        l.sent('fill_computer'),
        hasLength(2),
        reason:
            'expected a tap after the error to send a second '
            'fill_computer, found ${l.sent('fill_computer').length}. '
            '${l.why}',
      );
      // The same answer replayed changes nothing and breaks nothing.
      await l.push('error', <String, Object?>{
        'code': 'WRONG_PHASE',
        'message': 'not yet',
      }, re: id);
      expect(tester.takeException(), isNull, reason: l.why);
    });

    _row('tap.accepted: the answer seats a computer and the control leaves', (
      tester,
      v,
      name,
    ) async {
      final _Lobby l = await ready(tester, v, name);
      await l.tapFill();
      final String id = l.idOfLast('fill_computer');
      l.seq += 1;
      await l.push('player_joined', <String, Object?>{
        'seat': 3,
        'name': 'Zuzu',
        'bot': 1,
        'seq': l.seq,
      }, re: id);
      await l.advance(600);
      l.expectFillAbsent('once the fill seated a computer in the last seat');
      final String shown = _s(v.lang, 'botName1', l.why);
      expect(
        l.texts(3).contains(shown),
        isTrue,
        reason:
            'expected the new computer seat 3 to show "$shown", it shows '
            '${l.texts(3)}. ${l.why}',
      );
      expect(
        l.icons(l.seatCard(3)).contains(Icons.smart_toy_rounded),
        isTrue,
        reason:
            'expected the robot mark on the new computer seat 3, it '
            'draws ${l.icons(l.seatCard(3))}. ${l.why}',
      );
    });
  });

  // ===========================================================================
  // Large text
  // ===========================================================================
  _row(
    'large_text: no overflow at scale 1.3, four seats, two computers',
    (tester, v, name) async {
      final _Lobby l = await _Lobby.open(
        tester,
        v,
        name,
        open: false,
        seats: const <_Seat>[
          _Seat.host('Sam'),
          _Seat(1, 'Ann'),
          _Seat.bot(2, 4),
          _Seat.bot(3, 6),
        ],
      );
      await l.advance(800);
      expect(
        tester.takeException(),
        isNull,
        reason: 'expected no overflow or layout error. ${l.why}',
      );
      for (final int s in <int>[0, 1, 2, 3]) {
        final Rect r = tester.getRect(l.seatCard(s));
        expect(
          r.left >= -0.5 && r.right <= v.size.width + 0.5,
          isTrue,
          reason:
              'expected seat card $s inside the ${v.size.width} dp '
              'width, it spans ${r.left}..${r.right}. ${l.why}',
        );
      }
      for (final (int seat, int bot) in <(int, int)>[(2, 4), (3, 6)]) {
        final String shown = _s(v.lang, 'botName$bot', l.why);
        expect(
          l.texts(seat).contains(shown),
          isTrue,
          reason:
              'expected seat $seat to show "$shown", it shows '
              '${l.texts(seat)}. ${l.why}',
        );
      }
    },
    variants: const <_Variant>[
      _Variant('en', _small, scale: 1.3),
      _Variant('ar', _small, scale: 1.3),
    ],
  );
}
