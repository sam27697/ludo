// Screen proof for C-536 (work/ludo/orders/C-536-same-name-seats.md): two
// seats that share a name are told apart on every screen, the same way on
// every phone. Written from the contract text alone, before the
// implementation: it reads no new library file and no new ARB getter, so it
// compiles on a tree that has none of C-536 and every case that has two equal
// names is red there.
//
// What is asserted is the visible text, typed out from the contract, not
// read from the product. English: "Player" for the first holder and
// "Player 2" for the second. Arabic: the default name and the same name,
// a space, then MaterialLocalizations.formatDecimal(n) read in the test from
// the mounted tree (the way home_screen.dart formats its counts), so the
// digits are whatever the framework draws for that locale.
//
// Lobby cases mount LobbyScreen on a real RoomController over FakeTransport
// (the mount is copied from test/lobby_seat_cards_test.dart, private there).
// Game cases use the shared driver in test/support/end_card_chat_harness.dart:
// a real GameScreen, every state a decoded wire frame. The distinct-names
// cases are the control arm: they pass on a tree without C-536 and must keep
// passing with it.
//
// Every failure reason names the scenario (locale, viewer seat, names, what
// was pushed) so a red case replays from its message. There is no seed: the
// frames are fixed.
//
// Ambiguities, reported and not invented around:
//   - "Chat bubble" is read as the one header line (end-card-chat-<seat>,
//     C-500): the board draws no bubble of its own.
//   - "Game seat labels" is read as the name chip on the board
//     (board-seat-name-<seat>) and the opponent die's spoken label
//     (board-seat-die-<seat>).
//   - The contract names no wording for the numbered spoken lines, so the
//     announcement case asserts the existing gameOverPlayerWins wording with
//     the display name in place of the raw one.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';
import 'support/end_card_chat_harness.dart';

/// One locale under test: the default name a first-timer is given, and the
/// "You" chip text.
class _Lang {
  const _Lang(this.tag, this.player, this.you);

  final String tag;
  final String player;
  final String you;

  Locale get locale => Locale(tag);
}

const List<_Lang> _langs = <_Lang>[
  _Lang('en', 'Player', 'You'),
  _Lang('ar', 'لاعب', 'أنت'),
];

/// [base] for the first holder, "[base] [n]" with n drawn by the framework's
/// own formatter for the second and later ones.
String _label(WidgetTester tester, String base, int n) {
  if (n == 1) {
    return base;
  }
  final Finder scaffold = find.byType(Scaffold);
  expect(
    scaffold,
    findsWidgets,
    reason: 'fixture: a Scaffold is mounted to read MaterialLocalizations from',
  );
  final MaterialLocalizations material = MaterialLocalizations.of(
    tester.element(scaffold.first),
  );
  return '$base ${material.formatDecimal(n)}';
}

/// The strings of every Text under [root], in tree order.
List<String> _textsUnder(WidgetTester tester, Finder root) => <String>[
  for (final Text t in tester.widgetList<Text>(
    find.descendant(of: root, matching: find.byType(Text)),
  ))
    t.data ?? t.textSpan?.toPlainText() ?? '',
];

// --- lobby -------------------------------------------------------------

const String _testUrl = 'wss://example.test/ws';

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
    'id': 'c536-id-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url; the test '
        'scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

Widget _lobbyHarness(Widget child, Locale locale) {
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

Map<String, Object?> _lobbySeat(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

class _Lobby {
  _Lobby(this.tester, this.transport, this.controller, this.scenario);

  final WidgetTester tester;
  final FakeTransport transport;
  final RoomController controller;
  final String scenario;

  int _seq = 1;

  String why(String expected) => '$scenario | expected: $expected';

  /// A seat leaves: the server's `player_left` push, next in sequence.
  Future<void> seatLeaves(int seat) async {
    _seq += 1;
    transport.pushText(
      _frame(
        type: 'player_left',
        data: <String, Object?>{'seat': seat, 'seq': _seq},
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

/// Mounts the lobby as [mySeat] in a room whose seated players are [names]
/// (seat -> name), [players] chairs in all.
Future<_Lobby> _mountLobby(
  WidgetTester tester, {
  required _Lang lang,
  required int mySeat,
  required int players,
  required Map<int, String> names,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);

  final String scenario =
      'lobby ${lang.tag}, I am seat $mySeat of $players, seated $names';
  final bool amHost = mySeat == 0;
  await tester.pumpWidget(
    _lobbyHarness(
      LobbyScreen(
        controller: controller,
        action: amHost ? LobbyAction.create : LobbyAction.join,
        code: amHost ? null : 'ABC234',
        playerName: 'Me',
        players: players,
      ),
      lang.locale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason: '$scenario | fixture: LobbyScreen sent its create/join request',
  );
  final String requestId =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;

  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  final List<int> order = names.keys.toList()..sort();
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: <String, Object?>{
        'code': 'ABC234',
        'state': 'LOBBY',
        'host_seat': 0,
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
        'seats': <Map<String, Object?>>[
          for (final int seat in order) _lobbySeat(seat, names[seat]!),
        ],
        'turn': null,
        'winner': null,
        'rematch': null,
        'seq': 1,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason: '$scenario | fixture: the controller reached connected',
  );
  return _Lobby(tester, transport, controller, scenario);
}

/// The names the card of [seat] shows, or fails with the scenario.
List<String> _lobbyCard(_Lobby l, int seat) {
  final Finder card = find.byKey(Key('lobby-seat-$seat'));
  expect(
    card,
    findsOneWidget,
    reason: l.why('seat card lobby-seat-$seat is on screen'),
  );
  return _textsUnder(l.tester, card);
}

void _expectCard(_Lobby l, int seat, String label) {
  final List<String> texts = _lobbyCard(l, seat);
  expect(
    texts,
    contains(label),
    reason: l.why('lobby-seat-$seat reads "$label"; it shows $texts'),
  );
}

// --- game --------------------------------------------------------------

/// Announcements sent through SystemChannels.accessibility, recorded the way
/// test/talkback_announce_test.dart does.
class _Announcements {
  final List<String> messages = <String>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          messages.add(data['message'] as String);
        }
        return null;
      },
    );
  }

  void remove(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    );
  }
}

Finder _chip(int seat) => find.byKey(Key('board-seat-name-$seat'));

void _expectChip(EndGame g, int seat, String label) {
  expect(
    _chip(seat),
    findsOneWidget,
    reason: g.why('board-seat-name-$seat is on the board'),
  );
  final List<String> texts = _textsUnder(g.tester, _chip(seat));
  expect(
    texts,
    contains(label),
    reason: g.why('board-seat-name-$seat reads "$label"; it shows $texts'),
  );
}

/// The words an end card title wears: "{name} took this one" / "فاز {name}
/// هذه المرة", typed from the existing strings.
String _tookThisOne(_Lang lang, String name) =>
    lang.tag == 'ar' ? 'فاز $name هذه المرة' : '$name took this one';

String _wantsAgain(_Lang lang, String name) =>
    lang.tag == 'ar' ? 'دعوة من $name لجولة أخرى' : '$name wants to play again';

String _wins(_Lang lang, String name) =>
    lang.tag == 'ar' ? 'فاز $name' : '$name wins';

void main() {
  setUpAll(loadAppFonts);

  // -------------------------------------------------------------------
  // The lobby seat cards.
  // -------------------------------------------------------------------
  group('lobby seat cards', () {
    for (final _Lang lang in _langs) {
      testWidgets('two ${lang.player} seats: the second is numbered 2 '
          '(${lang.tag})', (tester) async {
        final _Lobby l = await _mountLobby(
          tester,
          lang: lang,
          mySeat: 0,
          players: 2,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        final String second = _label(tester, lang.player, 2);
        _expectCard(l, 0, lang.player);
        _expectCard(l, 1, second);
        expect(
          _lobbyCard(l, 0),
          isNot(contains(second)),
          reason: l.why('seat 0 is never "$second"'),
        );
        expect(
          _lobbyCard(l, 1),
          isNot(contains(lang.player)),
          reason: l.why(
            'seat 1 does not also show the bare "${lang.player}"; '
            'it shows ${_lobbyCard(l, 1)}',
          ),
        );
      });

      testWidgets('viewer is the second ${lang.player}: same labels, You on '
          'seat 1 (${lang.tag})', (tester) async {
        final _Lobby l = await _mountLobby(
          tester,
          lang: lang,
          mySeat: 1,
          players: 2,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        final String second = _label(tester, lang.player, 2);
        _expectCard(l, 0, lang.player);
        _expectCard(l, 1, second);
        expect(
          _lobbyCard(l, 1),
          contains(lang.you),
          reason: l.why('seat 1 carries the You chip "${lang.you}"'),
        );
        expect(
          _lobbyCard(l, 0),
          isNot(contains(lang.you)),
          reason: l.why('seat 0 carries no You chip'),
        );
      });

      testWidgets('four ${lang.player} seats: 1st plain, then 2, 3, 4 '
          '(${lang.tag})', (tester) async {
        final _Lobby l = await _mountLobby(
          tester,
          lang: lang,
          mySeat: 0,
          players: 4,
          names: <int, String>{for (int i = 0; i < 4; i++) i: lang.player},
        );
        _expectCard(l, 0, lang.player);
        for (int seat = 1; seat < 4; seat++) {
          _expectCard(l, seat, _label(tester, lang.player, seat + 1));
        }
      });

      testWidgets('seats 0 and 2 share a name, seat 1 differs: seat 2 is '
          'numbered 2 (${lang.tag})', (tester) async {
        final _Lobby l = await _mountLobby(
          tester,
          lang: lang,
          mySeat: 1,
          players: 3,
          names: <int, String>{0: lang.player, 1: 'Ann', 2: lang.player},
        );
        _expectCard(l, 0, lang.player);
        _expectCard(l, 1, 'Ann');
        _expectCard(l, 2, _label(tester, lang.player, 2));
      });

      testWidgets('a seat leaving frees its name: three ${lang.player}s, '
          'seat 1 leaves (${lang.tag})', (tester) async {
        final _Lobby l = await _mountLobby(
          tester,
          lang: lang,
          mySeat: 0,
          players: 3,
          names: <int, String>{for (int i = 0; i < 3; i++) i: lang.player},
        );
        _expectCard(l, 2, _label(tester, lang.player, 3));
        await l.seatLeaves(1);
        expect(
          find.byKey(const Key('lobby-seat-1')),
          findsNothing,
          reason: l.why('seat 1 left, its card is gone'),
        );
        _expectCard(l, 0, lang.player);
        _expectCard(l, 2, _label(tester, lang.player, 2));
        expect(
          _lobbyCard(l, 2),
          isNot(contains(_label(tester, lang.player, 3))),
          reason: l.why('seat 2 no longer reads the number 3'),
        );
      });
    }

    testWidgets('two different duplicated names count separately: '
        'Ann, Bob, Ann, Bob (en)', (tester) async {
      final _Lobby l = await _mountLobby(
        tester,
        lang: _langs[0],
        mySeat: 0,
        players: 4,
        names: <int, String>{0: 'Ann', 1: 'Bob', 2: 'Ann', 3: 'Bob'},
      );
      _expectCard(l, 0, 'Ann');
      _expectCard(l, 1, 'Bob');
      _expectCard(l, 2, 'Ann 2');
      _expectCard(l, 3, 'Bob 2');
    });

    testWidgets('control: distinct names are shown as sent (en)', (
      tester,
    ) async {
      final _Lobby l = await _mountLobby(
        tester,
        lang: _langs[0],
        mySeat: 0,
        players: 3,
        names: <int, String>{0: 'Ann', 1: 'Bob', 2: 'Cara'},
      );
      _expectCard(l, 0, 'Ann');
      _expectCard(l, 1, 'Bob');
      _expectCard(l, 2, 'Cara');
    });

    testWidgets('control: a seat leaving changes no distinct name (en)', (
      tester,
    ) async {
      final _Lobby l = await _mountLobby(
        tester,
        lang: _langs[0],
        mySeat: 0,
        players: 3,
        names: <int, String>{0: 'Ann', 1: 'Bob', 2: 'Cara'},
      );
      await l.seatLeaves(1);
      expect(
        find.byKey(const Key('lobby-seat-1')),
        findsNothing,
        reason: l.why('seat 1 left, its card is gone'),
      );
      _expectCard(l, 0, 'Ann');
      _expectCard(l, 2, 'Cara');
    });

    testWidgets('control: names that differ only by case are different '
        'names (en)', (tester) async {
      final _Lobby l = await _mountLobby(
        tester,
        lang: _langs[0],
        mySeat: 0,
        players: 2,
        names: <int, String>{0: 'player', 1: 'Player'},
      );
      _expectCard(l, 0, 'player');
      _expectCard(l, 1, 'Player');
    });
  });

  // -------------------------------------------------------------------
  // The game: seat labels, the die's spoken label, the header line.
  // -------------------------------------------------------------------
  group('game seat labels', () {
    for (final _Lang lang in _langs) {
      testWidgets('board name chips: two ${lang.player}s (${lang.tag})', (
        tester,
      ) async {
        final EndGame g = await openPlaying(
          tester,
          'game chips ${lang.tag}, me seat 0, seats 0 and 1 both '
          '"${lang.player}"',
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          final String second = _label(tester, lang.player, 2);
          _expectChip(g, 0, lang.player);
          _expectChip(g, 1, second);
          expect(
            _textsUnder(tester, _chip(1)),
            isNot(contains(lang.player)),
            reason: g.why('chip 1 does not also show the bare name'),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('board name chips: viewer is the second ${lang.player} '
          '(${lang.tag})', (tester) async {
        final EndGame g = await openPlaying(
          tester,
          'game chips ${lang.tag}, me seat 1, seats 0 and 1 both '
          '"${lang.player}"',
          me: 1,
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          _expectChip(g, 0, lang.player);
          _expectChip(g, 1, _label(tester, lang.player, 2));
          expect(
            _textsUnder(tester, _chip(1)),
            contains(lang.you),
            reason: g.why('my own chip keeps its You badge'),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('the opponent die is spoken with the display name '
          '(${lang.tag})', (tester) async {
        final EndGame g = await openPlaying(
          tester,
          'game die label ${lang.tag}, me seat 0, seats 0 and 1 both '
          '"${lang.player}"',
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          final Finder die = find.byKey(const Key('board-seat-die-1'));
          expect(
            die,
            findsOneWidget,
            reason: g.why('board-seat-die-1 is on the board'),
          );
          final String label =
              tester.widget<Semantics>(die).properties.label ?? '';
          final String second = _label(tester, lang.player, 2);
          expect(
            label,
            contains(second),
            reason: g.why(
              'the die of seat 1 is spoken as "$second", '
              'it says "$label"',
            ),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('three ${lang.player}s, seat 1 leaves: seat 2 becomes the '
          'second (${lang.tag})', (tester) async {
        final EndGame g = await openPlaying(
          tester,
          'game leave ${lang.tag}, me seat 0, seats 0, 1, 2 all '
          '"${lang.player}", seat 1 leaves',
          players: 3,
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player, 2: lang.player},
        );
        try {
          _expectChip(g, 0, lang.player);
          _expectChip(g, 1, _label(tester, lang.player, 2));
          _expectChip(g, 2, _label(tester, lang.player, 3));
          await g.playerLeft(1);
          await g.s.pump(const Duration(milliseconds: 100));
          expect(
            _chip(1),
            findsNothing,
            reason: g.why('seat 1 left, its chip is gone'),
          );
          _expectChip(g, 0, lang.player);
          _expectChip(g, 2, _label(tester, lang.player, 2));
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('four seats, two duplicated names: Ann, Bob, Ann, Bob (en)', (
      tester,
    ) async {
      final EndGame g = await openPlaying(
        tester,
        'game chips en, me seat 0, Ann Bob Ann Bob',
        players: 4,
        names: <int, String>{0: 'Ann', 1: 'Bob', 2: 'Ann', 3: 'Bob'},
      );
      try {
        _expectChip(g, 0, 'Ann');
        _expectChip(g, 1, 'Bob');
        _expectChip(g, 2, 'Ann 2');
        _expectChip(g, 3, 'Bob 2');
      } finally {
        await g.done();
      }
    });

    testWidgets('control: a seat leaving changes no distinct chip (en)', (
      tester,
    ) async {
      final EndGame g = await openPlaying(
        tester,
        'game leave control en, me seat 0, Ann Bob Cara, seat 1 leaves',
        players: 3,
        names: <int, String>{0: 'Ann', 1: 'Bob', 2: 'Cara'},
      );
      try {
        await g.playerLeft(1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          _chip(1),
          findsNothing,
          reason: g.why('seat 1 left, its chip is gone'),
        );
        _expectChip(g, 0, 'Ann');
        _expectChip(g, 2, 'Cara');
      } finally {
        await g.done();
      }
    });

    testWidgets('control: distinct names on chips and the die are as sent '
        '(en)', (tester) async {
      final EndGame g = await openPlaying(
        tester,
        'game control en, me seat 0, Ann and Bob',
        names: <int, String>{0: 'Ann', 1: 'Bob'},
      );
      try {
        _expectChip(g, 0, 'Ann');
        _expectChip(g, 1, 'Bob');
        final String label =
            tester
                .widget<Semantics>(find.byKey(const Key('board-seat-die-1')))
                .properties
                .label ??
            '';
        expect(
          label,
          contains('Bob'),
          reason: g.why('the die of seat 1 is spoken as "Bob", says "$label"'),
        );
      } finally {
        await g.done();
      }
    });
  });

  group('chat line', () {
    for (final _Lang lang in _langs) {
      testWidgets('a line from the second ${lang.player} is signed with its '
          'display name (${lang.tag})', (tester) async {
        final EndGame g = await openPlaying(
          tester,
          'chat ${lang.tag}, me seat 0, seats 0 and 1 both "${lang.player}", '
          'seat 1 says good_game',
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          await g.emote(1, 'good_game');
          final String text = textUnder(tester, lineOf(g, 1));
          final String expected = said(
            _label(tester, lang.player, 2),
            endLine('good_game', ar: lang.tag == 'ar'),
          );
          expect(
            text,
            expected,
            reason: g.why(
              'end-card-chat-1 reads "$expected", it reads '
              '"$text"',
            ),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('control: a line from the first ${lang.player} keeps the '
          'plain name (${lang.tag})', (tester) async {
        final EndGame g = await openPlaying(
          tester,
          'chat ${lang.tag}, me seat 1, seats 0 and 1 both "${lang.player}", '
          'seat 0 says good_game',
          me: 1,
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          await g.emote(0, 'good_game');
          final String text = textUnder(tester, lineOf(g, 0));
          final String expected = said(
            lang.player,
            endLine('good_game', ar: lang.tag == 'ar'),
          );
          expect(
            text,
            expected,
            reason: g.why(
              'end-card-chat-0 reads "$expected", it reads '
              '"$text"',
            ),
          );
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('control: a line from a distinct name is signed as sent (en)', (
      tester,
    ) async {
      final EndGame g = await openPlaying(
        tester,
        'chat control en, me seat 0, Ann and Bob, seat 1 says good_game',
        names: <int, String>{0: 'Ann', 1: 'Bob'},
      );
      try {
        await g.emote(1, 'good_game');
        final String text = textUnder(tester, lineOf(g, 1));
        expect(
          text,
          said('Bob', 'Good game'),
          reason: g.why(
            'end-card-chat-1 reads "Bob: Good game", reads "$text"',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });

  // -------------------------------------------------------------------
  // The end card and what is said aloud when a game ends.
  // -------------------------------------------------------------------
  group('end card', () {
    for (final _Lang lang in _langs) {
      testWidgets('the second ${lang.player} wins: the title names it as '
          'the second (${lang.tag})', (tester) async {
        final EndGame g = await openFinished(
          tester,
          'end ${lang.tag}, me seat 0, seats 0 and 1 both "${lang.player}", '
          'seat 1 wins',
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          final String expected = _tookThisOne(
            lang,
            _label(tester, lang.player, 2),
          );
          final String title = textUnder(
            tester,
            find.byKey(const Key('game-screen-winner')),
          );
          expect(
            title,
            expected,
            reason: g.why('the title reads "$expected", it reads "$title"'),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('control: the first ${lang.player} wins, the title keeps the '
          'plain name (${lang.tag})', (tester) async {
        final EndGame g = await openFinished(
          tester,
          'end ${lang.tag}, me seat 1, seats 0 and 1 both "${lang.player}", '
          'seat 0 wins',
          me: 1,
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          final String expected = _tookThisOne(lang, lang.player);
          final String title = textUnder(
            tester,
            find.byKey(const Key('game-screen-winner')),
          );
          expect(
            title,
            expected,
            reason: g.why('the title reads "$expected", it reads "$title"'),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('viewer has another name: seat 2 of two ${lang.player}s '
          'wins and is named 2 (${lang.tag})', (tester) async {
        final EndGame g = await openPlaying(
          tester,
          'end ${lang.tag}, me seat 0 "Ann", seats 1 and 2 both '
          '"${lang.player}", seat 2 wins',
          players: 3,
          locale: lang.locale,
          names: <int, String>{0: 'Ann', 1: lang.player, 2: lang.player},
        );
        try {
          await g.gameOver(2);
          await g.s.pump(const Duration(milliseconds: 100));
          final String expected = _tookThisOne(
            lang,
            _label(tester, lang.player, 2),
          );
          final String title = textUnder(
            tester,
            find.byKey(const Key('game-screen-winner')),
          );
          expect(
            title,
            expected,
            reason: g.why('the title reads "$expected", it reads "$title"'),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('the second ${lang.player} asks for a rematch: the ask '
          'names it as the second (${lang.tag})', (tester) async {
        final EndGame g = await openFinished(
          tester,
          'rematch ${lang.tag}, me seat 0, seats 0 and 1 both '
          '"${lang.player}", seat 1 asks',
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          await g.rematchLobby(by: 1);
          await g.s.pump(const Duration(milliseconds: 100));
          final Finder ask = find.byKey(const Key('end-card-rematch-ask'));
          expect(
            ask,
            findsOneWidget,
            reason: g.why('end-card-rematch-ask is on screen'),
          );
          final String expected = _wantsAgain(
            lang,
            _label(tester, lang.player, 2),
          );
          final String text = textUnder(tester, ask);
          expect(
            text,
            expected,
            reason: g.why('the ask reads "$expected", it reads "$text"'),
          );
        } finally {
          await g.done();
        }
      });

      testWidgets('the game-over announcement names the second '
          '${lang.player} as the second (${lang.tag})', (tester) async {
        final _Announcements heard = _Announcements()..install(tester);
        addTearDown(() => heard.remove(tester));
        final EndGame g = await openPlaying(
          tester,
          'announce ${lang.tag}, me seat 0, seats 0 and 1 both '
          '"${lang.player}", seat 1 wins',
          locale: lang.locale,
          names: <int, String>{0: lang.player, 1: lang.player},
        );
        try {
          await g.gameOver(1);
          await g.s.pump(const Duration(milliseconds: 100));
          final String expected = _wins(lang, _label(tester, lang.player, 2));
          expect(
            heard.messages,
            contains(expected),
            reason: g.why(
              'an announcement reads "$expected", heard '
              '${heard.messages}',
            ),
          );
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('control: distinct names on the title and the ask are as '
        'sent (en)', (tester) async {
      final EndGame g = await openFinished(
        tester,
        'end control en, me seat 0 Ann, seat 1 Bob wins and asks',
        names: <int, String>{0: 'Ann', 1: 'Bob'},
      );
      try {
        final String title = textUnder(
          tester,
          find.byKey(const Key('game-screen-winner')),
        );
        expect(
          title,
          'Bob took this one',
          reason: g.why('the title reads "Bob took this one", reads "$title"'),
        );
        await g.rematchLobby(by: 1);
        await g.s.pump(const Duration(milliseconds: 100));
        final String ask = textUnder(
          tester,
          find.byKey(const Key('end-card-rematch-ask')),
        );
        expect(
          ask,
          'Bob wants to play again',
          reason: g.why(
            'the ask reads "Bob wants to play again", reads '
            '"$ask"',
          ),
        );
      } finally {
        await g.done();
      }
    });
  });
}
