// Screen proofs for C-612 (work/ludo/orders/612-first-turn-you-are-next.md,
// "Order 612t"): "You're next" is spoken for the first turn of a game
// however the game started. Written from the contract (D1 to D3) alone; the
// client change is built in parallel in a tree this file's author has not
// read.
//
// A real GameScreen over a real RoomController on FakeTransport (the
// roll-tray and C-468 harnesses under test/support), every state a decoded
// wire frame. Nothing is mocked but the socket and the feedback service.
// Spoken lines are captured off a mock handler on SystemChannels.accessibility,
// the way test/you_are_next_test.dart captures them.
//
// The two doors into a game:
//
//   lobby start  the controller sees LOBBY, then `game_started`, then the
//                standalone `turn` (PROTOCOL 13.1); GameScreen mounts onto
//                that first turn. The transcript holds the start and the
//                turn, no `rolled`.
//   rematch      GameScreen is already up on the finished game; the room goes
//                FINISHED, then the rematch LOBBY, then a new `game_started`
//                and `turn` under a new game id.
//
// Every case is a fixed list of frames, there is no seed. A failure line
// names the case, the table, what was expected, every line spoken and every
// frame pushed so far in order, which is the whole reproduction. Time is
// fake; the only waits are pumps of a stated length, never pumpAndSettle.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/frame.dart' show Frame;
import 'package:ludo_client/src/net/snapshot.dart' show RoomState;

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

// --- the texts the contract fixes, verbatim ---------------------------------

const String _announceEn = "You're next";
const String _announceAr = 'أنت التالي';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

/// The first second the order names: fixed pumps of this length after mount.
const Duration _firstSecond = Duration(seconds: 1);

/// Past the end-card hold (2500 ms in GameScreen) so a finished game has
/// settled before the rematch lobby arrives.
const Duration _pastEndHold = Duration(seconds: 3);

const String _gameOne = 'c612c612c612c612';
const String _gameTwo = 'd612d612d612d612';

// --- announcements -----------------------------------------------------------

class _Said {
  final List<String> recorded = <String>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          recorded.add(data['message'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          ),
    );
  }
}

// --- tables ------------------------------------------------------------------

/// Seats [seats] named after [kNames], with Sam on seat [me]. A null [me] is a
/// spectator's view: nobody is called Sam.
List<Map<String, Object?>> _seatsOf(List<int> seats, {int? me}) =>
    <Map<String, Object?>>[
      for (final int seat in seats)
        seatJson(seat, name: seat == me ? 'Sam' : kNames[seat]!),
    ];

Map<String, Object?> _gameStartedData(int turnSeat, String gameId) =>
    <String, Object?>{
      'turn': turnSeat,
      'game_id': gameId,
      'client_seeds': '0:sam-seed|1:bob-seed',
    };

/// One table in one scenario: the log that makes a failure reproducible and
/// the lines spoken so far.
class _T {
  _T({
    required this.tester,
    required this.drive,
    required this.s,
    required this.said,
    required this.locale,
    required this.setup,
  });

  final WidgetTester tester;
  final RollTrayDrive drive;
  final Scn s;
  final _Said said;
  final Locale locale;
  String setup;

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  /// The lines spoken that are the "You're next" line, in the screen's locale.
  List<String> get nextLines => <String>[
    for (final String m in said.recorded)
      if (m == loc.gameYouAreNextAnnounce) m,
  ];

  String why(String expected) =>
      'C-612 [${locale.languageCode}] $setup | expected: $expected | spoken '
      '${said.recorded} | cues ${drive.feedback.recorded} | '
      'at ${s.clockMs}ms | replay: ${s.steps.join(' > ')}';

  Future<void> push(String type, Map<String, Object?> data) =>
      s.push(type, data);

  Future<void> pump(Duration d) => s.pump(d);

  void expectSpoken(String step, int count) {
    expect(
      nextLines,
      hasLength(count),
      reason: why(
        '$step: "${loc.gameYouAreNextAnnounce}" spoken $count time(s)',
      ),
    );
  }

  /// A seat's roll and move, as a turn plays out before it passes.
  Future<void> seatPlaysOut(int seat, int k) async {
    await push('rolled', rolledFrame(seat, 3, k, legal: const <int>[0]));
    await push('moved', movedFrame(seat, 0, 10, 13));
    await pump(const Duration(seconds: 2));
  }
}

/// One name for a table, so every failure line names it the same way.
String _tableName(List<int> seats, int? me) =>
    'seats $seats me ${me ?? 'spectator'}';

/// Connects a controller to the LOBBY of [seats], then plays the start the
/// way the wire does: `game_started` naming [firstSeat], then the standalone
/// `turn`. With [history] the game has already moved on before the screen
/// mounts: seat 0 rolled and moved (so the transcript holds `rolled`
/// frames) and the turn then passed to [firstSeat]. Nothing is mounted yet.
Future<_T> _lobbyStart(
  WidgetTester tester, {
  required String name,
  required List<int> seats,
  required int? me,
  required int firstSeat,
  bool history = false,
  Locale locale = _en,
}) async {
  final _Said said = _Said()..install(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: null,
    seats: _seatsOf(seats, me: me),
    mySeat: me ?? 0,
    players: seats.length,
    sendSeatAssigned: me != null,
    state: 'LOBBY',
  );
  final _T t = _T(
    tester: tester,
    drive: drive,
    s: Scn(name, tester, drive),
    said: said,
    locale: locale,
    setup:
        '${_tableName(seats, me)} first turn seat $firstSeat '
        '${history ? 'resume (rolled frames in the transcript)' : 'fresh game'}'
        ' | $name',
  );
  final int openingSeat = history ? 0 : firstSeat;
  await t.push('game_started', _gameStartedData(openingSeat, _gameOne));
  await t.push('turn', turnFrame(openingSeat));
  if (history) {
    await t.push('rolled', rolledFrame(0, 3, 1, legal: const <int>[0]));
    await t.push('moved', movedFrame(0, 0, 10, 13));
    await t.push('turn', turnFrame(firstSeat));
  }
  final List<String> types = <String>[
    for (final Frame f in drive.controller.gameTranscript) f.type,
  ];
  expect(
    types.first,
    'game_started',
    reason: 'fixture: the transcript opens with game_started, got $types',
  );
  expect(
    types.contains('rolled'),
    history,
    reason:
        'fixture: the transcript ${history ? 'holds' : 'holds no'} `rolled`, '
        'got $types',
  );
  expect(
    drive.controller.room!.turn?.seat,
    firstSeat,
    reason: 'fixture: the room shows seat $firstSeat on turn',
  );
  return t;
}

Future<void> _mount(_T t) async {
  await mountGame(t.tester, t.drive, locale: t.locale);
  t.s.steps.add('mount GameScreen (${t.locale.languageCode})');
}

Future<void> _close(_T t) => releaseGame(t.tester, t.drive);

/// Lobby start, the screen mounted onto the first turn, one second of pumps.
/// Returns the table (still mounted) so a case can read more off it.
Future<_T> _freshAndMounted(
  WidgetTester tester, {
  required String name,
  required List<int> seats,
  required int? me,
  required int firstSeat,
  Locale locale = _en,
}) async {
  final _T t = await _lobbyStart(
    tester,
    name: name,
    seats: seats,
    me: me,
    firstSeat: firstSeat,
    locale: locale,
  );
  await _mount(t);
  await t.pump(_firstSecond);
  return t;
}

/// The rematch door: a screen up on game one (first turn [firstGameSeat]),
/// that game over, the rematch lobby, then game two starting on
/// [secondFirstSeat]. Returns the table still mounted, with the number of
/// lines spoken before game two began in [spokenBefore].
Future<(_T, int)> _rematchAndMounted(
  WidgetTester tester, {
  required String name,
  required List<int> seats,
  required int? me,
  required int firstGameSeat,
  required int secondFirstSeat,
  Locale locale = _en,
}) async {
  final _T t = await _lobbyStart(
    tester,
    name: name,
    seats: seats,
    me: me,
    firstSeat: firstGameSeat,
    locale: locale,
  );
  t.setup =
      '${_tableName(seats, me)} rematch (game one first turn seat '
      '$firstGameSeat, game two first turn seat $secondFirstSeat) | $name';
  await _mount(t);
  await t.pump(_firstSecond);
  await t.push('game_over', gameOverFrame(seats.first));
  await t.pump(_pastEndHold);
  expect(
    t.drive.controller.room!.state,
    RoomState.finished,
    reason: t.why('fixture: game one reached FINISHED'),
  );
  await t.push('room', <String, Object?>{
    ...roomData(
      seats: _seatsOf(seats, me: me),
      players: seats.length,
      state: 'LOBBY',
    ),
    'rematch': <String, Object?>{
      'by': seats.first,
      'ready': <int>[seats.first],
    },
  });
  expect(
    t.drive.controller.room!.state,
    RoomState.lobby,
    reason: t.why('fixture: the rematch lobby is the live room'),
  );
  final int before = t.said.recorded.length;
  await t.push('game_started', _gameStartedData(secondFirstSeat, _gameTwo));
  await t.push('turn', turnFrame(secondFirstSeat));
  await t.pump(_firstSecond);
  expect(
    t.drive.controller.room!.gameId,
    _gameTwo,
    reason: t.why('fixture: game two is the live game'),
  );
  return (t, before);
}

/// How many times the next-line was spoken after index [from] of the record.
int _spokenSince(_T t, int from) => <String>[
  for (final String m in t.said.recorded.skip(from))
    if (m == t.loc.gameYouAreNextAnnounce) m,
].length;

void main() {
  // ===========================================================================
  // (a) four seats, me 2, lobby start, seat 1 on the first turn.
  // ===========================================================================
  testWidgets('C-612 (a) en: four seats, me 2, fresh game, seat 1 to roll: '
      '"You\'re next" is spoken exactly once in the first second', (
    tester,
  ) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'a',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstSeat: 1,
    );
    try {
      expect(
        t.loc.gameYouAreNextAnnounce,
        _announceEn,
        reason: 'the string is the contract text "$_announceEn"',
      );
      t.expectSpoken('first second after mount onto the first turn', 1);
      expect(t.said.recorded, <String>[
        _announceEn,
      ], reason: t.why('the only thing spoken is "$_announceEn"'));
      await t.pump(const Duration(seconds: 2));
      t.expectSpoken('three seconds in, nothing repeated', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 (a) en: a later frame of the same first turn says '
      'nothing more (an extra roll of seat 1)', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'a extra roll',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstSeat: 1,
    );
    try {
      t.expectSpoken('first second after mount', 1);
      await t.push(
        'rolled',
        rolledFrame(1, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(1, queue: const <int>[6]));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('after seat 1 rolls a six and goes again', 1);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (b) same table, me 3: not next, silent.
  // ===========================================================================
  testWidgets('C-612 (b) en: four seats, me 3, fresh game, seat 1 to roll: '
      'nothing is spoken (seat 2 sits between us)', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'b',
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      firstSeat: 1,
    );
    try {
      t.expectSpoken('first second after mount, I am not next', 0);
      expect(
        t.said.recorded,
        isEmpty,
        reason: t.why('nothing at all is spoken'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (c) resume: the game has moved past its first turn on this device.
  // ===========================================================================
  testWidgets('C-612 (c) en: resume onto a game with rolled frames, seat 1 on '
      'turn, me 2: silent at mount; the next turn that makes me next speaks '
      'once', (tester) async {
    final _T t = await _lobbyStart(
      tester,
      name: 'c',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstSeat: 1,
      history: true,
    );
    try {
      await _mount(t);
      await t.pump(_firstSecond);
      t.expectSpoken('first second after mounting onto a game in progress', 0);

      await t.seatPlaysOut(1, 2);
      await t.push('turn', turnFrame(2));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('turn moves to seat 2 (mine)', 0);
      await t.seatPlaysOut(2, 3);
      await t.push('turn', turnFrame(3));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('turn moves on to seat 3', 0);
      await t.seatPlaysOut(3, 4);
      await t.push('turn', turnFrame(0));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('turn moves on to seat 0', 0);
      await t.seatPlaysOut(0, 5);
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('turn comes around to seat 1, I am next again', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 (c) en: resume onto seat 1, then a replay of seat 1\'s '
      'turn: the seat already weighed says nothing', (tester) async {
    // The mount lands on seat 1 (the seat before me). A turn of the same seat
    // again, delivered after mount, is the seat already weighed: silent.
    final _T t = await _lobbyStart(
      tester,
      name: 'c replay',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstSeat: 1,
      history: true,
    );
    try {
      await _mount(t);
      await t.pump(_firstSecond);
      t.expectSpoken('first second after mount', 0);
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('a replay of the same turn after mount', 0);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (d) rematch on the same screen.
  // ===========================================================================
  testWidgets('C-612 (d) en: rematch on the same screen, seat 1 to roll, me '
      '2: spoken once', (tester) async {
    final (_T t, int before) = await _rematchAndMounted(
      tester,
      name: 'd',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstGameSeat: 0,
      secondFirstSeat: 1,
    );
    try {
      expect(
        _spokenSince(t, before),
        1,
        reason: t.why(
          '"$_announceEn" spoken once for the rematch\'s first turn '
          '(spoken before game two: $before)',
        ),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 (d) en: the lobby start and the rematch speak the same '
      'number of times for the same first turn', (tester) async {
    const List<int> seats = <int>[0, 1, 2, 3];
    final _T fresh = await _freshAndMounted(
      tester,
      name: 'd parity fresh',
      seats: seats,
      me: 2,
      firstSeat: 1,
    );
    final int freshCount = fresh.nextLines.length;
    final String freshWhy = fresh.why('(lobby start run)');
    await _close(fresh);

    final (_T again, int before) = await _rematchAndMounted(
      tester,
      name: 'd parity rematch',
      seats: seats,
      me: 2,
      firstGameSeat: 0,
      secondFirstSeat: 1,
    );
    try {
      final int rematchCount = _spokenSince(again, before);
      expect(
        freshCount,
        rematchCount,
        reason:
            'C-612 D1/P10: the same first turn must say the same thing '
            'whichever door the table came in by. lobby start spoke '
            '$freshCount time(s) [$freshWhy]; rematch spoke $rematchCount '
            'time(s) [${again.why('(rematch run)')}]',
      );
    } finally {
      await _close(again);
    }
  });

  // ===========================================================================
  // (e) two seats: nothing, in either path.
  // ===========================================================================
  testWidgets('C-612 (e) en: two seats [0,2], me 2, fresh game, seat 0 to '
      'roll: nothing is spoken', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'e fresh',
      seats: const <int>[0, 2],
      me: 2,
      firstSeat: 0,
    );
    try {
      t.expectSpoken('two seats, lobby start, first second', 0);
      expect(t.said.recorded, isEmpty, reason: t.why('nothing spoken at all'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 (e) en: two seats [0,2], me 2, rematch, seat 0 to roll: '
      'nothing is spoken', (tester) async {
    final (_T t, int before) = await _rematchAndMounted(
      tester,
      name: 'e rematch',
      seats: const <int>[0, 2],
      me: 2,
      firstGameSeat: 2,
      secondFirstSeat: 0,
    );
    try {
      expect(
        _spokenSince(t, before),
        0,
        reason: t.why('two seats, rematch: "$_announceEn" never spoken'),
      );
      expect(
        t.nextLines,
        isEmpty,
        reason: t.why('two seats: no next line in either game'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (f) Arabic for (a).
  // ===========================================================================
  testWidgets('C-612 (f) ar: four seats, me 2, fresh game, seat 1 to roll: '
      'the Arabic line is spoken exactly once', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'f',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstSeat: 1,
      locale: _ar,
    );
    try {
      expect(t.loc.localeName, 'ar', reason: t.why('fixture: Arabic strings'));
      expect(
        t.loc.gameYouAreNextAnnounce,
        _announceAr,
        reason: 'the string is the contract text "$_announceAr"',
      );
      t.expectSpoken('first second after mount, Arabic', 1);
      expect(t.said.recorded, <String>[
        _announceAr,
      ], reason: t.why('the only thing spoken is "$_announceAr"'));
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // Boundaries around the contract.
  // ===========================================================================
  testWidgets('C-612 boundary en: three seats [0,1,2], me 2, fresh game, seat '
      '1 to roll: three is the smallest table that speaks', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'three seats',
      seats: const <int>[0, 1, 2],
      me: 2,
      firstSeat: 1,
    );
    try {
      t.expectSpoken('three seats, first second', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 boundary en: four seats, me 0, fresh game, seat 3 to '
      'roll: the wrap speaks', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'wrap',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      firstSeat: 3,
    );
    try {
      t.expectSpoken('seat 3 on turn, my seat follows across the wrap', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 boundary en: four seats, fresh game, my own seat rolls '
      'first: nothing is spoken', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'own turn',
      seats: const <int>[0, 1, 2, 3],
      me: 1,
      firstSeat: 1,
    );
    try {
      t.expectSpoken('my own first turn', 0);
      await t.seatPlaysOut(1, 1);
      await t.push('turn', turnFrame(2));
      await t.pump(const Duration(milliseconds: 200));
      t.expectSpoken('the turn moves to seat 2, I am not next', 0);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 boundary en: a spectator at a four seat table, fresh '
      'game: nothing is spoken', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'spectator',
      seats: const <int>[0, 1, 2, 3],
      me: null,
      firstSeat: 1,
    );
    try {
      t.expectSpoken('no seat of mine, first second', 0);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-612 boundary en: fresh game, then the lap: the first turn '
      'spoke, so the lap round to seat 1 speaks again once', (tester) async {
    final _T t = await _freshAndMounted(
      tester,
      name: 'fresh then lap',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      firstSeat: 1,
    );
    try {
      t.expectSpoken('first turn', 1);
      int k = 0;
      for (final int seat in <int>[1, 2, 3, 0]) {
        k += 1;
        await t.seatPlaysOut(seat, k);
        await t.push('turn', turnFrame((seat + 1) % 4));
        await t.pump(const Duration(milliseconds: 100));
      }
      t.expectSpoken('a full lap back to seat 1', 2);
    } finally {
      await _close(t);
    }
  });
}
