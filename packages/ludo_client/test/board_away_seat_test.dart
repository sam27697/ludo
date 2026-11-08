// Screen and widget proofs for C-597 (work/ludo/orders/597-away-seat-on-board.md,
// "Tests (595t, second file)"), cases (a) to (j) plus the ugly cases named in
// the comments below. Written from the contract alone; the implementation is
// built in parallel in a tree this file's author has not read.
//
// The screen cases are a real GameScreen over a real RoomController on
// FakeTransport (the roll-tray and C-468 harnesses under test/support), every
// state a decoded wire frame. Nothing is mocked but the socket and the
// feedback service. The mark is read off the `board-seat-away-<seat>` keys, the
// chips off `board-seat-name-<seat>`, the spoken lines off the semantics tree,
// all with the expected line built from the generated AppLocalizations and
// pinned once against the literal in the arb files.
//
// The widget cases mount a bare LudoBoard (the harness of
// test/board_seat_identity_test.dart, copied) and pass `awaySeats`, a named
// parameter this contract adds, so this file does not compile on a tree that
// lacks it. Case (j)'s omitted-parameter test does not name it.
//
// Every case is a fixed list of frames, there is no seed. A failure line names
// the case, the table, which away marks the screen drew, and every frame pushed
// so far in order, which is the whole reproduction. Time is fake; the only
// waits are pumps of a stated length.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const String _awayPrefix = 'board-seat-away-';

Key _awayKey(int seat) => Key('$_awayPrefix$seat');
Key _chipKey(int seat) => Key('board-seat-name-$seat');
Key _discKey(int seat) => Key('board-seat-name-$seat-mark');

/// The contract's wording, pinned once so a wrong word in an arb file fails
/// even when the screen and the getter agree.
const String _offlineCaraEn = 'Cara is offline';
const String _offlineCaraAr = 'انقطع اتصال Cara';

// --- tables ------------------------------------------------------------------

/// Seats [seats] named after [kNames] (or [names]), Sam on seat [me], the seats
/// in [offline] with their socket down.
List<Map<String, Object?>> _seatsOf(
  List<int> seats, {
  required int me,
  Set<int> offline = const <int>{},
  Map<int, String> names = const <int, String>{},
}) => <Map<String, Object?>>[
  for (final int seat in seats)
    seatJson(
      seat,
      name: seat == me ? 'Sam' : (names[seat] ?? kNames[seat]!),
      connected: !offline.contains(seat),
    ),
];

/// One mounted GameScreen, the log that makes a failure reproducible, and the
/// helpers every case reads the board through.
class _T {
  _T(this.tester, this.drive, this.s, this.locale, this.setup, this.seats);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final Scn s;
  final Locale locale;
  final String setup;
  final List<int> seats;

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  /// The `board-seat-away-*` keys on screen, sorted, as written.
  List<String> get awayKeys => _awayKeysOf(tester);

  /// The label of seat [seat]'s chip as the game screen handed it to the board.
  String label(int seat) =>
      tester.widget<LudoBoard>(find.byType(LudoBoard)).seatNames![seat]!;

  String why(String expected) =>
      'C-597 [${locale.languageCode}] $setup | expected: $expected | away marks '
      'on screen: $awayKeys, header offline icon: '
      '${find.byIcon(Icons.wifi_off).evaluate().length}, cues '
      '${drive.feedback.recorded} | ${s.why('replay')}';

  Future<void> push(String type, Map<String, Object?> data) =>
      s.push(type, data);

  Future<void> presence(int seat, {required bool connected}) =>
      push('presence', <String, Object?>{'seat': seat, 'connected': connected});

  Future<void> pump(Duration d) => s.pump(d);
}

List<String> _awayKeysOf(WidgetTester tester) {
  final List<String> found = <String>[];
  for (final Element element in find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> && key.value.startsWith(_awayPrefix);
  }).evaluate()) {
    found.add((element.widget.key! as ValueKey<String>).value);
  }
  found.sort();
  return found;
}

/// Mounts seat [me] of [seats] on a turn of [turnSeat].
Future<_T> _open(
  WidgetTester tester, {
  required String name,
  List<int> seats = const <int>[0, 1, 2],
  int me = 0,
  int turnSeat = 1,
  Set<int> offline = const <int>{},
  Map<int, String> names = const <int, String>{},
  Locale locale = _en,
  String stateName = 'PLAYING',
  Size? surface,
  double textScale = 1.0,
}) async {
  if (surface != null) {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  } else {
    phoneSurface(tester);
  }
  final bool finished = stateName == 'FINISHED';
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: finished ? null : turnJson(seat: turnSeat, phase: 'await_roll', k: 0),
    seats: _seatsOf(seats, me: me, offline: offline, names: names),
    mySeat: me,
    players: seats.length,
    state: stateName,
    gameId: finished ? 'aaaaaaaaaaaaaaaa' : null,
    winner: finished ? seats.first : null,
  );
  await mountGame(tester, drive, locale: locale, textScale: textScale);
  final String setup =
      'seats $seats me $me turn seat $turnSeat $stateName '
      '${offline.isEmpty ? 'all connected' : 'offline $offline'} '
      '${names.isEmpty ? '' : 'names $names '}$name';
  return _T(tester, drive, Scn(name, tester, drive), locale, setup, seats);
}

Future<void> _close(_T t) => releaseGame(t.tester, t.drive);

// --- reading the chips -------------------------------------------------------

/// The `Text` data inside seat [seat]'s chip, in tree order.
List<String> _chipTexts(WidgetTester tester, int seat) => <String>[
  for (final Element e
      in find
          .descendant(
            of: find.byKey(_chipKey(seat)),
            matching: find.byType(Text),
          )
          .evaluate())
    (e.widget as Text).data ?? '',
];

/// The mark widget of [seat]: the Icon inside (or at) the keyed widget.
Finder _awayIcon(int seat) => find.descendant(
  of: find.byKey(_awayKey(seat)),
  matching: find.byType(Icon),
  matchRoot: true,
);

/// The `Opacity` ancestors of seat [seat]'s chip whose value is 0.6.
Finder _fadedAbove(int seat) => find.ancestor(
  of: find.byKey(_chipKey(seat)),
  matching: find.byWidgetPredicate(
    (Widget w) => w is Opacity && (w.opacity - 0.6).abs() < 1e-6,
  ),
);

/// Seat [seat]'s name `Text` (the chip's text whose data is [name]).
Finder _nameText(int seat, String name) =>
    find.descendant(of: find.byKey(_chipKey(seat)), matching: find.text(name));

/// [inner] lies within [outer], edges included.
bool _inside(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.01 &&
    inner.top >= outer.top - 0.01 &&
    inner.right <= outer.right + 0.01 &&
    inner.bottom <= outer.bottom + 0.01;

double _cell(WidgetTester tester) => boardSquare(tester).width / 15;

/// The rect of the board drawn by the screen, as the square the board uses.
Rect _board(WidgetTester tester) => boardSquare(tester);

void main() {
  // ===========================================================================
  // (a) three seats, seat 2 away: only seat 2 is marked.
  // ===========================================================================
  testWidgets('C-597 (a) en: seats [0,1,2], me 0, turn 1, seat 2 offline: '
      'board-seat-away-2 exists, 1 and 0 do not', (tester) async {
    final _T t = await _open(tester, name: 'a', offline: const <int>{2});
    try {
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('exactly board-seat-away-2'));
      expect(
        find.byKey(_awayKey(2)),
        findsOneWidget,
        reason: t.why('board-seat-away-2 once'),
      );
      expect(
        find.byKey(_awayKey(1)),
        findsNothing,
        reason: t.why('no mark on the connected turn seat 1'),
      );
      expect(
        find.byKey(_awayKey(0)),
        findsNothing,
        reason: t.why('no mark on my own seat 0'),
      );
      expect(
        find.descendant(
          of: find.byKey(_chipKey(2)),
          matching: find.byKey(_awayKey(2)),
        ),
        findsOneWidget,
        reason: t.why('the mark is inside seat 2\'s name chip'),
      );
      expect(
        _awayIcon(2),
        findsOneWidget,
        reason: t.why('the mark holds one Icon'),
      );
      expect(
        tester.widget<Icon>(_awayIcon(2)).icon,
        Icons.wifi_off_rounded,
        reason: t.why('the icon is wifi_off_rounded'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (a) ar: the Arabic table marks seat 2 the same way', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'a ar',
      offline: const <int>{2},
      locale: _ar,
    );
    try {
      expect(t.loc.localeName, 'ar', reason: t.why('fixture: Arabic strings'));
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('exactly board-seat-away-2'));
      expect(
        tester.widget<Icon>(_awayIcon(2)).icon,
        Icons.wifi_off_rounded,
        reason: t.why('the icon is wifi_off_rounded'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 en: nobody away, no mark anywhere (today\'s board)', (
    tester,
  ) async {
    final _T t = await _open(tester, name: 'none away');
    try {
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('no board-seat-away-* with every seat connected'),
      );
      expect(
        find.byIcon(Icons.wifi_off_rounded),
        findsNothing,
        reason: t.why('no away icon with every seat connected'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (b) the same seat reconnects: the mark goes.
  // ===========================================================================
  testWidgets('C-597 (b) en: a presence frame with connected true takes the '
      'mark off, a later drop puts it back', (tester) async {
    final _T t = await _open(
      tester,
      name: 'b presence',
      offline: const <int>{2},
    );
    try {
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('fixture: seat 2 is marked'));
      await t.presence(2, connected: true);
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('after seat 2 reconnects, no mark'),
      );
      await t.presence(2, connected: false);
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('after seat 2 drops again, marked again'));
      await t.presence(2, connected: false);
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('a replayed drop leaves one mark'));
      await t.presence(2, connected: true);
      await t.presence(2, connected: true);
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('a replayed reconnect leaves no mark'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (b) en: a room snapshot with connected true takes the '
      'mark off, and a snapshot with it false puts it on', (tester) async {
    final _T t = await _open(
      tester,
      name: 'b snapshot',
      offline: const <int>{2},
    );
    try {
      await t.push(
        'room',
        roomData(
          seats: _seatsOf(const <int>[0, 1, 2], me: 0),
          turn: turnJson(seat: 1, phase: 'await_roll', k: 0),
          players: 3,
        ),
      );
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('after a snapshot with seat 2 connected, no mark'),
      );
      await t.push(
        'room',
        roomData(
          seats: _seatsOf(const <int>[0, 1, 2], me: 0, offline: {1}),
          turn: turnJson(seat: 0, phase: 'await_roll', k: 0),
          players: 3,
        ),
      );
      expect(t.awayKeys, <String>[
        '${_awayPrefix}1',
      ], reason: t.why('a snapshot with seat 1 down marks seat 1 only'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 en: two seats drop one after the other and come back in '
      'the other order; the marks follow each of them', (tester) async {
    final _T t = await _open(tester, name: 'two drops');
    try {
      await t.presence(1, connected: false);
      expect(t.awayKeys, <String>[
        '${_awayPrefix}1',
      ], reason: t.why('seat 1 down'));
      await t.presence(2, connected: false);
      expect(t.awayKeys, <String>[
        '${_awayPrefix}1',
        '${_awayPrefix}2',
      ], reason: t.why('seats 1 and 2 down'));
      await t.presence(1, connected: true);
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('seat 1 back, seat 2 still down'));
      await t.presence(2, connected: true);
      expect(t.awayKeys, isEmpty, reason: t.why('both back'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 en: four seats, every other seat dropped: seats 1, 2 and '
      '3 are marked and my seat 0 is not', (tester) async {
    final _T t = await _open(
      tester,
      name: 'all others down',
      seats: const <int>[0, 1, 2, 3],
      offline: const <int>{1, 2, 3},
    );
    try {
      expect(t.awayKeys, <String>[
        '${_awayPrefix}1',
        '${_awayPrefix}2',
        '${_awayPrefix}3',
      ], reason: t.why('marks on 1, 2 and 3 only'));
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no exception with three marks'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 en: a mark stays through the turn walking past it: seat '
      '2 is away on turn 1, on turn 2 and on turn 0', (tester) async {
    final _T t = await _open(
      tester,
      name: 'turn walks',
      offline: const <int>{2},
    );
    try {
      for (final int seat in <int>[2, 0, 1]) {
        await t.push('turn', turnFrame(seat));
        await t.pump(const Duration(milliseconds: 100));
        expect(t.awayKeys, <String>[
          '${_awayPrefix}2',
        ], reason: t.why('the mark of seat 2 with seat $seat on turn'));
      }
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (c) the turn seat away: the board mark and the header icon.
  // ===========================================================================
  testWidgets('C-597 (c) en: the turn seat away: board-seat-away-1 exists and '
      'the header still shows its offline icon and notice', (tester) async {
    final _T t = await _open(tester, name: 'c', offline: const <int>{1});
    try {
      expect(
        find.byKey(_awayKey(1)),
        findsOneWidget,
        reason: t.why('board-seat-away-1 on the turn seat'),
      );
      expect(t.awayKeys, <String>[
        '${_awayPrefix}1',
      ], reason: t.why('no other mark'));
      expect(
        find.descendant(
          of: find.byKey(const Key('game-header-chip')),
          matching: find.byIcon(Icons.wifi_off),
        ),
        findsOneWidget,
        reason: t.why('the header chip still carries the offline icon'),
      );
      expect(
        find.byKey(const Key('game-screen-turn-seat-offline')),
        findsOneWidget,
        reason: t.why('the offline notice under the banner is still there'),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('game-screen-turn-seat-offline')),
            )
            .data,
        t.loc.gameSeatOffline(t.label(1)),
        reason: t.why('the notice reads the offline line for ${t.label(1)}'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (c) en: the turn seat comes back: the mark, the header '
      'icon and the notice all go', (tester) async {
    final _T t = await _open(tester, name: 'c back', offline: const <int>{1});
    try {
      await t.presence(1, connected: true);
      expect(t.awayKeys, isEmpty, reason: t.why('no mark after it is back'));
      expect(
        find.byIcon(Icons.wifi_off),
        findsNothing,
        reason: t.why('no header icon after it is back'),
      );
      expect(
        find.byKey(const Key('game-screen-turn-seat-offline')),
        findsNothing,
        reason: t.why('no notice after it is back'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (c) en: a seat that is not on turn has the board mark '
      'and no header icon', (tester) async {
    final _T t = await _open(
      tester,
      name: 'c not turn',
      offline: const <int>{2},
    );
    try {
      expect(
        find.byIcon(Icons.wifi_off),
        findsNothing,
        reason: t.why('the header icon is for the turn seat only'),
      );
      expect(
        find.byKey(const Key('game-screen-turn-seat-offline')),
        findsNothing,
        reason: t.why('the notice is for the turn seat only'),
      );
      expect(
        find.byKey(_awayKey(2)),
        findsOneWidget,
        reason: t.why('the board marks the away seat anyway'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (d) my own seat is never marked.
  // ===========================================================================
  testWidgets('C-597 (d) en: my own seat connected false in the snapshot '
      'never gets a mark; the other away seat does', (tester) async {
    final _T t = await _open(tester, name: 'd', offline: const <int>{0, 2});
    try {
      expect(
        find.byKey(_awayKey(0)),
        findsNothing,
        reason: t.why('no board-seat-away-0 on my own seat'),
      );
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('only seat 2 is marked'));
      expect(_chipTexts(tester, 0), <String>[
        'Sam',
        t.loc.seatYou,
      ], reason: t.why('my chip still reads my name and "You"'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (d) en: only my own seat down: no mark anywhere, and my '
      'chip is neither faded nor spoken as offline', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _T t = await _open(
      tester,
      name: 'd mine only',
      offline: const <int>{0},
    );
    try {
      await tester.pump();
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('no board-seat-away-* with only my own seat down'),
      );
      expect(
        _fadedAbove(0),
        findsNothing,
        reason: t.why('my chip is not faded'),
      );
      expect(
        find.bySemanticsLabel(t.loc.gameSeatOffline('Sam')),
        findsNothing,
        reason: t.why('my chip is not spoken as offline'),
      );
      expect(_chipTexts(tester, 0), <String>[
        'Sam',
        t.loc.seatYou,
      ], reason: t.why('my chip still reads my name and "You"'));
    } finally {
      await _close(t);
      handle.dispose();
    }
  });

  testWidgets('C-597 (d) en: my own seat dropping by a presence frame never '
      'gets a mark either, at any seat number', (tester) async {
    final _T t = await _open(
      tester,
      name: 'd presence',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 3,
    );
    try {
      await t.presence(2, connected: false);
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('my own seat 2 dropping marks nothing'),
      );
      await t.presence(1, connected: false);
      expect(t.awayKeys, <String>[
        '${_awayPrefix}1',
      ], reason: t.why('seat 1 dropping marks seat 1 only'));
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (e) FINISHED: no mark anywhere.
  // ===========================================================================
  testWidgets('C-597 (e) en: a FINISHED room with a dropped seat has no '
      'board-seat-away-* anywhere, and its chips are there', (tester) async {
    final _T t = await _open(
      tester,
      name: 'e',
      stateName: 'FINISHED',
      offline: const <int>{2},
    );
    try {
      expect(
        find.byKey(_chipKey(2)),
        findsOneWidget,
        reason: t.why('fixture: the finished board draws seat 2\'s name chip'),
      );
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('no away mark on the finished board'),
      );
      expect(
        find.byIcon(Icons.wifi_off_rounded),
        findsNothing,
        reason: t.why('no away icon on the finished board'),
      );
      expect(
        _fadedAbove(2),
        findsNothing,
        reason: t.why('the finished board does not fade a dropped seat'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (e) en: the game ending while seat 2 is marked clears '
      'the mark', (tester) async {
    final _T t = await _open(tester, name: 'e ends', offline: const <int>{2});
    try {
      expect(t.awayKeys, <String>[
        '${_awayPrefix}2',
      ], reason: t.why('fixture: seat 2 marked while playing'));
      await t.push(
        'room',
        roomData(
          seats: _seatsOf(const <int>[0, 1, 2], me: 0, offline: {2}),
          players: 3,
          state: 'FINISHED',
          gameId: 'aaaaaaaaaaaaaaaa',
          winner: 0,
        ),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(
        t.drive.controller.room?.state.name,
        'finished',
        reason: t.why('fixture: the room is FINISHED'),
      );
      expect(
        t.awayKeys,
        isEmpty,
        reason: t.why('no mark once the game is over'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (f) semantics: the chip is spoken as the away line, drawn as the name.
  // ===========================================================================
  testWidgets('C-597 (f) en: the away chip is spoken "Cara is offline" and '
      'drawn "Cara"', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _T t = await _open(tester, name: 'f', offline: const <int>{2});
    try {
      await tester.pump();
      expect(
        t.loc.gameSeatOffline('Cara'),
        _offlineCaraEn,
        reason: 'the arb line must be "$_offlineCaraEn"',
      );
      expect(t.label(2), 'Cara', reason: t.why('fixture: seat 2 is Cara'));
      expect(
        find.bySemanticsLabel(t.loc.gameSeatOffline(t.label(2))),
        findsOneWidget,
        reason: t.why('one semantics node reads "$_offlineCaraEn"'),
      );
      expect(
        find.bySemanticsLabel(t.loc.gameSeatOffline(t.label(1))),
        findsNothing,
        reason: t.why('the connected seat 1 is not spoken as offline'),
      );
      expect(_chipTexts(tester, 2), <String>[
        'Cara',
      ], reason: t.why('the visible chip text is the bare name'));
      expect(
        find.text(t.loc.gameSeatOffline(t.label(2))),
        findsNothing,
        reason: t.why('the offline line is spoken, never drawn, on the chip'),
      );
    } finally {
      await _close(t);
      handle.dispose();
    }
  });

  testWidgets('C-597 (f) ar: the away chip is spoken in Arabic and drawn as '
      'the bare name', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _T t = await _open(
      tester,
      name: 'f ar',
      offline: const <int>{2},
      locale: _ar,
    );
    try {
      await tester.pump();
      expect(
        t.loc.gameSeatOffline('Cara'),
        _offlineCaraAr,
        reason: 'the arb line must be "$_offlineCaraAr"',
      );
      expect(
        find.bySemanticsLabel(t.loc.gameSeatOffline(t.label(2))),
        findsOneWidget,
        reason: t.why('one semantics node reads "$_offlineCaraAr"'),
      );
      expect(_chipTexts(tester, 2), <String>[
        'Cara',
      ], reason: t.why('the visible chip text is the bare name'));
    } finally {
      await _close(t);
      handle.dispose();
    }
  });

  testWidgets('C-597 (f) en: the turn seat away is spoken once on the board; '
      'the header notice is a second, separate node', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _T t = await _open(
      tester,
      name: 'f turn seat',
      offline: const <int>{1},
    );
    try {
      await tester.pump();
      final String line = t.loc.gameSeatOffline(t.label(1));
      expect(
        find.bySemanticsLabel(line),
        findsNWidgets(2),
        reason: t.why(
          'two nodes read "$line": the existing notice and the board chip',
        ),
      );
      expect(_chipTexts(tester, 1), <String>[
        'Bob',
      ], reason: t.why('the chip still draws the bare name'));
    } finally {
      await _close(t);
      handle.dispose();
    }
  });

  testWidgets('C-597 (f) en: a seat that comes back is spoken as its name '
      'again', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _T t = await _open(tester, name: 'f back', offline: const <int>{2});
    try {
      await tester.pump();
      final String line = t.loc.gameSeatOffline(t.label(2));
      expect(
        find.bySemanticsLabel(line),
        findsOneWidget,
        reason: t.why('fixture: spoken as offline'),
      );
      await t.presence(2, connected: true);
      await tester.pump();
      expect(
        find.bySemanticsLabel(line),
        findsNothing,
        reason: t.why('no node reads "$line" once seat 2 is back'),
      );
    } finally {
      await _close(t);
      handle.dispose();
    }
  });

  // ===========================================================================
  // (g) the fade.
  // ===========================================================================
  testWidgets('C-597 (g) en: the away seat\'s chip sits under an Opacity of '
      '0.6 and an online seat\'s chip does not', (tester) async {
    final _T t = await _open(
      tester,
      name: 'g',
      seats: const <int>[0, 1, 2, 3],
      offline: const <int>{2},
    );
    try {
      expect(
        _fadedAbove(2),
        findsOneWidget,
        reason: t.why('the away chip is under one Opacity of 0.6'),
      );
      for (final int seat in <int>[0, 1, 3]) {
        expect(
          _fadedAbove(seat),
          findsNothing,
          reason: t.why('seat $seat is online, its chip is not faded'),
        );
      }
      await t.presence(2, connected: true);
      expect(
        _fadedAbove(2),
        findsNothing,
        reason: t.why('seat 2 is back, its chip is not faded'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // D2 geometry: size, colour, order and gap of the mark.
  // ===========================================================================
  testWidgets('C-597 D2 en: the icon is the size of the chip\'s mark disc, in '
      'the chip\'s ink, after the name, one 0.15 cell gap from it', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'D2 geometry',
      offline: const <int>{2},
    );
    try {
      final Icon icon = tester.widget<Icon>(_awayIcon(2));
      final IconThemeData ambient = IconTheme.of(tester.element(_awayIcon(2)));
      final double? drawnSize = icon.size ?? ambient.size;
      final Color? drawnColor = icon.color ?? ambient.color;
      final Rect disc = tester.getRect(find.byKey(_discKey(2)));
      final Rect iconRect = tester.getRect(_awayIcon(2));
      final Rect nameRect = tester.getRect(_nameText(2, 'Cara'));
      final Rect chip = tester.getRect(find.byKey(_chipKey(2)));
      expect(
        disc.width,
        greaterThan(0),
        reason: t.why('fixture: the mark disc has a size, got $disc'),
      );
      expect(
        drawnSize,
        closeTo(disc.width, 0.01),
        reason: t.why(
          'the icon size equals the mark disc (${disc.width}), got $drawnSize',
        ),
      );
      expect(
        iconRect.width,
        closeTo(disc.width, 0.01),
        reason: t.why('the icon is laid out ${disc.width} wide, got $iconRect'),
      );
      expect(
        drawnColor,
        contrastingInk(LudoColors.seats[2]),
        reason: t.why('the icon is drawn in the chip\'s contrasting ink'),
      );
      expect(
        iconRect.left - nameRect.right,
        closeTo(_cell(tester) * 0.15, 0.01),
        reason: t.why(
          'the icon sits ${_cell(tester) * 0.15} dp after the name (icon '
          '$iconRect, name $nameRect)',
        ),
      );
      expect(
        iconRect.center.dy,
        closeTo(disc.center.dy, 0.5),
        reason: t.why('the icon is centred on the same line as the disc'),
      );
      expect(
        _inside(chip, iconRect),
        isTrue,
        reason: t.why('the icon $iconRect is inside the chip $chip'),
      );
      expect(
        tester.getSize(find.byKey(_discKey(2))).width,
        closeTo(disc.width, 0.01),
        reason: t.why('the mark disc itself is unchanged'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 D2 ar: in the Arabic table the mark follows the name in '
      'reading order, on its left, one 0.15 cell gap from it', (tester) async {
    final _T t = await _open(
      tester,
      name: 'D2 ar order',
      offline: const <int>{2},
      locale: _ar,
    );
    try {
      final Rect iconRect = tester.getRect(_awayIcon(2));
      final Rect nameRect = tester.getRect(_nameText(2, 'Cara'));
      expect(
        nameRect.left - iconRect.right,
        closeTo(_cell(tester) * 0.15, 0.01),
        reason: t.why(
          'RTL: the icon ends ${_cell(tester) * 0.15} dp before the name '
          'starts (icon $iconRect, name $nameRect)',
        ),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 D2 en: an away chip is no wider than its yard quadrant '
      'and its name keeps the base size when there is room', (tester) async {
    final _T t = await _open(tester, name: 'D2 room', offline: const <int>{2});
    try {
      final Rect chip = tester.getRect(find.byKey(_chipKey(2)));
      final Rect quadrant = yardQuadrantViewRect(_board(tester), 2, 0);
      expect(
        _inside(quadrant, chip),
        isTrue,
        reason: t.why('chip $chip inside seat 2\'s yard quadrant $quadrant'),
      );
      expect(tester.takeException(), isNull, reason: t.why('no exception'));
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // D4: no cue, no announcement on the change itself.
  // ===========================================================================
  testWidgets('C-597 D4 en: a seat dropping and coming back plays no cue and '
      'announces nothing', (tester) async {
    final List<String> said = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          said.add(data['message'] as String);
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
    final _T t = await _open(tester, name: 'D4');
    try {
      final int cuesBefore = t.drive.feedback.recorded.length;
      final int saidBefore = said.length;
      await t.presence(2, connected: false);
      await t.pump(const Duration(milliseconds: 300));
      await t.presence(2, connected: true);
      await t.pump(const Duration(milliseconds: 300));
      expect(t.awayKeys, isEmpty, reason: t.why('fixture: back to no mark'));
      expect(
        t.drive.feedback.recorded.length,
        cuesBefore,
        reason: t.why(
          'no cue for a drop or a return, recorded ${t.drive.feedback.recorded}',
        ),
      );
      expect(
        said.length,
        saidBefore,
        reason: t.why('no announcement for a drop or a return, said $said'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (h) fit: a long name ellipsizes, never overflows.
  // ===========================================================================
  const Size phone640 = Size(360, 640);

  testWidgets('C-597 (h) control: at 360 x 640 the same table with seat 2 '
      'ONLINE and named Abdulrahman throws nothing and fits its chip', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'h control',
      names: const <int, String>{2: 'Abdulrahman'},
      surface: phone640,
    );
    try {
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no exception at 360 x 640 with the seat online'),
      );
      final Rect chip = tester.getRect(find.byKey(_chipKey(2)));
      final Rect text = tester.getRect(_nameText(2, 'Abdulrahman'));
      expect(
        _inside(chip, text),
        isTrue,
        reason: t.why('control: name $text inside chip $chip'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (h) en: at 360 x 640 an away seat named Abdulrahman '
      'throws no overflow and its name is laid out inside the chip', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'h',
      names: const <int, String>{2: 'Abdulrahman'},
      offline: const <int>{2},
      surface: phone640,
    );
    try {
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no overflow error at 360 x 640'),
      );
      expect(
        find.byKey(_awayKey(2)),
        findsOneWidget,
        reason: t.why('fixture: the mark is drawn'),
      );
      final Rect chip = tester.getRect(find.byKey(_chipKey(2)));
      final Rect text = tester.getRect(_nameText(2, 'Abdulrahman'));
      final Rect icon = tester.getRect(_awayIcon(2));
      expect(
        _inside(chip, text),
        isTrue,
        reason: t.why('the name $text is inside the chip $chip'),
      );
      expect(
        _inside(chip, icon),
        isTrue,
        reason: t.why('the icon $icon is inside the chip $chip'),
      );
      expect(
        text.right <= icon.left + 0.01,
        isTrue,
        reason: t.why('the name $text ends before the icon $icon begins'),
      );
      final Rect quadrant = yardQuadrantViewRect(_board(tester), 2, 0);
      expect(
        _inside(quadrant, chip),
        isTrue,
        reason: t.why('the chip $chip stays inside the yard $quadrant'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (h) ar: at 360 x 640 the same away seat in the Arabic '
      'table throws nothing and the name is inside the chip', (tester) async {
    final _T t = await _open(
      tester,
      name: 'h ar',
      names: const <int, String>{2: 'Abdulrahman'},
      offline: const <int>{2},
      surface: phone640,
      locale: _ar,
    );
    try {
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no overflow error at 360 x 640 in RTL'),
      );
      final Rect chip = tester.getRect(find.byKey(_chipKey(2)));
      final Rect text = tester.getRect(_nameText(2, 'Abdulrahman'));
      final Rect icon = tester.getRect(_awayIcon(2));
      expect(
        _inside(chip, text),
        isTrue,
        reason: t.why('the name $text is inside the chip $chip'),
      );
      expect(
        icon.right <= text.left + 0.01,
        isTrue,
        reason: t.why('RTL: the icon $icon ends before the name $text'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-597 (h) en: at 2x system text the away chip is still board '
      'art, throws nothing and keeps its mark', (tester) async {
    final _T t = await _open(
      tester,
      name: 'h text scale',
      names: const <int, String>{2: 'Abdulrahman'},
      offline: const <int>{2},
      surface: phone640,
      textScale: 2.0,
    );
    try {
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no overflow error at 2x text'),
      );
      expect(
        find.byKey(_awayKey(2)),
        findsOneWidget,
        reason: t.why('the mark is still drawn'),
      );
    } finally {
      await _close(t);
    }
  });

  // The C-339 fit rules with the icon's share taken out of the width: the name
  // shrinks first, never below its 10 px floor, and only ellipsizes once it is
  // at the floor. Run for names of 4 to 13 letters, so that whatever font the
  // test binding draws with, some length sits between "fits online" and "fits
  // away", plus the 11 letter name of the contract and a name far past any chip.
  for (final String longName in <String>[
    for (int n = 4; n <= 13; n++) 'Abcdefghijklm'.substring(0, n),
    'Abdulrahman',
    'Abcdefghij Abcdefghij Abcdefghij 1234',
  ]) {
    testWidgets('C-597 (h) en: away seat named "$longName" at 360 x 640: no '
        'exception, the font is never larger than online, and the name '
        'ellipsizes only at the 10 px floor', (tester) async {
      double? onlineSize;
      {
        final _T online = await _open(
          tester,
          name: 'h fit online $longName',
          names: <int, String>{2: longName},
          surface: phone640,
        );
        try {
          onlineSize = tester
              .widget<Text>(_nameText(2, longName))
              .style
              ?.fontSize;
        } finally {
          await _close(online);
        }
      }
      final _T t = await _open(
        tester,
        name: 'h fit away $longName',
        names: <int, String>{2: longName},
        offline: const <int>{2},
        surface: phone640,
      );
      try {
        expect(
          tester.takeException(),
          isNull,
          reason: t.why('no overflow error for "$longName"'),
        );
        expect(
          find.byKey(_awayKey(2)),
          findsOneWidget,
          reason: t.why('fixture: the mark is drawn for "$longName"'),
        );
        final Finder nameFinder = _nameText(2, longName);
        expect(
          nameFinder,
          findsOneWidget,
          reason: t.why('the whole string is still the Text data'),
        );
        final Text text = tester.widget<Text>(nameFinder);
        final double? awaySize = text.style?.fontSize;
        expect(awaySize, isNotNull, reason: t.why('the name has a font size'));
        expect(
          awaySize! <= onlineSize! + 0.01,
          isTrue,
          reason: t.why(
            'the away chip\'s font ($awaySize) is not larger than the online '
            'chip\'s ($onlineSize)',
          ),
        );
        expect(
          awaySize >= 10.0 - 0.01,
          isTrue,
          reason: t.why('the font ($awaySize) never goes under the 10 floor'),
        );
        expect(text.maxLines, 1, reason: t.why('one line'));
        expect(
          text.overflow,
          TextOverflow.ellipsis,
          reason: t.why('ellipsis, not clipping'),
        );
        final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
          nameFinder,
        );
        if (paragraph.didExceedMaxLines) {
          expect(
            awaySize,
            closeTo(10.0, 0.01),
            reason: t.why(
              '"$longName" ellipsizes at font $awaySize; it may only do so at '
              'the 10 px floor, so the fit was given the icon\'s width too',
            ),
          );
        }
        final Rect chip = tester.getRect(find.byKey(_chipKey(2)));
        final Rect icon = tester.getRect(_awayIcon(2));
        final Rect textRect = tester.getRect(nameFinder);
        expect(
          _inside(chip, textRect) && _inside(chip, icon),
          isTrue,
          reason: t.why('name $textRect and icon $icon inside chip $chip'),
        );
        expect(
          textRect.right <= icon.left + 0.01,
          isTrue,
          reason: t.why('the name $textRect ends before the icon $icon'),
        );
      } finally {
        await _close(t);
      }
    });
  }

  // ===========================================================================
  // (j) widget level.
  // ===========================================================================
  testWidgets(
    'C-597 (j) a LudoBoard with awaySeats omitted builds the same '
    'chips as today: no away key, no icon, no fade, a plain name and a "You"',
    (tester) async {
      await tester.pumpWidget(_boardHarness());
      await tester.pump();
      final String why =
          'C-597 (j) three seats, me 0, names Sam/Bob/Cara, awaySeats omitted';
      expect(
        _awayKeysOf(tester),
        isEmpty,
        reason: '$why | no board-seat-away-* key',
      );
      expect(
        find.byIcon(Icons.wifi_off_rounded),
        findsNothing,
        reason: '$why | no away icon',
      );
      for (final int seat in <int>[0, 1, 2]) {
        expect(
          find.byKey(_chipKey(seat)),
          findsOneWidget,
          reason: '$why | seat $seat has its chip',
        );
        expect(
          _fadedAbove(seat),
          findsNothing,
          reason: '$why | seat $seat chip is not faded',
        );
        expect(
          find.descendant(
            of: find.byKey(_chipKey(seat)),
            matching: find.byType(Icon),
          ),
          findsNothing,
          reason: '$why | seat $seat chip holds no Icon',
        );
      }
      expect(_chipTexts(tester, 0), <String>['Sam', 'You'], reason: why);
      expect(_chipTexts(tester, 1), <String>['Bob'], reason: why);
      expect(_chipTexts(tester, 2), <String>['Cara'], reason: why);
      expect(tester.takeException(), isNull, reason: '$why | no exception');
    },
  );

  testWidgets('C-597 (j) a LudoBoard with awaySeats omitted keeps the '
      'semantics of a chip: the bare name', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_boardHarness());
      await tester.pump();
      expect(
        find.bySemanticsLabel('Cara is offline'),
        findsNothing,
        reason: 'C-597 (j) omitted awaySeats: no chip is spoken as offline',
      );
      expect(
        find.bySemanticsLabel(RegExp('offline')),
        findsNothing,
        reason:
            'C-597 (j) omitted awaySeats: nothing on the board says offline',
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('C-597 D1 an empty awaySeats draws exactly what omitting it '
      'draws: same chip rects, same name sizes, no mark', (tester) async {
    await tester.pumpWidget(_boardHarness());
    await tester.pump();
    final Map<int, Rect> before = <int, Rect>{
      for (final int s in <int>[0, 1, 2])
        s: tester.getRect(find.byKey(_chipKey(s))),
    };
    final Map<int, double?> beforeSize = <int, double?>{
      for (final int s in <int>[0, 1, 2]) s: _fontOfFirstText(tester, s),
    };
    await tester.pumpWidget(_boardHarness(awaySeats: const <int, String>{}));
    await tester.pump();
    final String why =
        'C-597 D1 awaySeats const {} against omitted, three seats';
    for (final int s in <int>[0, 1, 2]) {
      expect(
        tester.getRect(find.byKey(_chipKey(s))),
        before[s],
        reason: '$why | chip $s rect',
      );
      expect(
        _fontOfFirstText(tester, s),
        beforeSize[s],
        reason: '$why | chip $s name font size',
      );
    }
    expect(_awayKeysOf(tester), isEmpty, reason: '$why | no mark');
  });

  testWidgets('C-597 D1/D2 an awaySeats entry for a seat with a chip marks '
      'it; a later rebuild with the map emptied takes it off and puts the '
      'chip back where it was', (tester) async {
    await tester.pumpWidget(_boardHarness());
    await tester.pump();
    final Rect plain = tester.getRect(find.byKey(_chipKey(2)));
    await tester.pumpWidget(
      _boardHarness(awaySeats: const <int, String>{2: 'Cara is offline'}),
    );
    await tester.pump();
    final String why = 'C-597 D1/D2 awaySeats {2: "Cara is offline"}';
    expect(_awayKeysOf(tester), <String>[
      '${_awayPrefix}2',
    ], reason: '$why | one mark on seat 2');
    expect(_fadedAbove(2), findsOneWidget, reason: '$why | faded once');
    expect(_fadedAbove(1), findsNothing, reason: '$why | seat 1 not faded');
    await tester.pumpWidget(_boardHarness(awaySeats: const <int, String>{}));
    await tester.pump();
    expect(_awayKeysOf(tester), isEmpty, reason: '$why | emptied: no mark');
    expect(
      tester.getRect(find.byKey(_chipKey(2))),
      plain,
      reason: '$why | emptied: the chip is back at its old rect',
    );
    expect(_fadedAbove(2), findsNothing, reason: '$why | emptied: not faded');
  });

  testWidgets('C-597 D2 the chip\'s spoken label is the map\'s value for the '
      'seat, whatever it says, and the other chips are untouched', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        _boardHarness(awaySeats: const <int, String>{1: 'Bob has gone quiet'}),
      );
      await tester.pump();
      final String why = 'C-597 D2 awaySeats {1: "Bob has gone quiet"}';
      expect(
        find.bySemanticsLabel('Bob has gone quiet'),
        findsOneWidget,
        reason: '$why | one node speaks the map value',
      );
      expect(_chipTexts(tester, 1), <String>[
        'Bob',
      ], reason: '$why | the chip still draws Bob');
      expect(
        find.bySemanticsLabel('Cara is offline'),
        findsNothing,
        reason: '$why | seat 2 is not spoken as offline',
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('C-597 D2 an awaySeats entry for a seat with no name chip '
      '(no name given, or not in play) draws nothing and throws nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _boardHarness(
        names: const <int, String>{0: 'Sam', 1: 'Bob'},
        awaySeats: const <int, String>{
          2: 'Cara is offline',
          3: 'Dan is offline',
        },
      ),
    );
    await tester.pump();
    final String why =
        'C-597 D2 seats [0,1,2], names for 0 and 1 only, awaySeats for 2 and '
        '3';
    expect(
      find.byKey(_chipKey(2)),
      findsNothing,
      reason: '$why | fixture: seat 2 has no chip',
    );
    expect(
      _awayKeysOf(tester),
      isEmpty,
      reason: '$why | no mark for a seat without a chip or a seat not in play',
    );
    expect(tester.takeException(), isNull, reason: '$why | no exception');
  });

  testWidgets('C-597 D2 an awaySeats entry for a seat not in play at a '
      'three seat board marks nothing', (tester) async {
    await tester.pumpWidget(
      _boardHarness(awaySeats: const <int, String>{3: 'Dan is offline'}),
    );
    await tester.pump();
    expect(
      _awayKeysOf(tester),
      isEmpty,
      reason: 'C-597 D2 seats [0,1,2], awaySeats {3: ...}: nothing to mark',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'C-597 D2 seats [0,1,2], awaySeats {3: ...}: no exception',
    );
  });

  testWidgets('C-597 D2 every other seat away at a four seat board: three '
      'marks, three fades, and my own chip unfaded', (tester) async {
    await tester.pumpWidget(
      _boardHarness(
        seatsInPlay: const <int>[0, 1, 2, 3],
        names: const <int, String>{0: 'Sam', 1: 'Bob', 2: 'Cara', 3: 'Dan'},
        awaySeats: const <int, String>{
          1: 'Bob is offline',
          2: 'Cara is offline',
          3: 'Dan is offline',
        },
      ),
    );
    await tester.pump();
    const String why = 'C-597 D2 four seats, me 0, awaySeats 1, 2 and 3';
    expect(_awayKeysOf(tester), <String>[
      '${_awayPrefix}1',
      '${_awayPrefix}2',
      '${_awayPrefix}3',
    ], reason: '$why | three marks');
    for (final int s in <int>[1, 2, 3]) {
      expect(_fadedAbove(s), findsOneWidget, reason: '$why | chip $s faded');
    }
    expect(_fadedAbove(0), findsNothing, reason: '$why | chip 0 not faded');
    expect(tester.takeException(), isNull, reason: '$why | no exception');
  });
}

// --- the widget harness ------------------------------------------------------

/// The rendered size of the first Text in seat [seat]'s chip.
double? _fontOfFirstText(WidgetTester tester, int seat) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(_chipKey(seat)),
            matching: find.byType(Text),
          )
          .first,
    )
    .style
    ?.fontSize;

/// A bare LudoBoard (test/board_seat_identity_test.dart's harness, copied) at
/// 400 x 400, three seats by default, me on seat 0 with the "You" label. When
/// [awaySeats] is null the parameter is not passed at all.
Widget _boardHarness({
  List<int> seatsInPlay = const <int>[0, 1, 2],
  Map<int, String> names = const <int, String>{0: 'Sam', 1: 'Bob', 2: 'Cara'},
  Map<int, String>? awaySeats,
}) {
  final Map<int, List<int>> tokens = <int, List<int>>{
    for (final int seat in <int>[0, 1, 2, 3]) seat: const <int>[-1, -1, -1, -1],
  };
  final Widget board = awaySeats == null
      ? LudoBoard(
          tokens: tokens,
          seatsInPlay: seatsInPlay,
          mySeat: 0,
          seatNames: names,
          youLabel: 'You',
          turnSeat: 1,
        )
      : LudoBoard(
          tokens: tokens,
          seatsInPlay: seatsInPlay,
          mySeat: 0,
          seatNames: names,
          youLabel: 'You',
          turnSeat: 1,
          awaySeats: awaySeats,
        );
  return MaterialApp(
    locale: _en,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(child: SizedBox(width: 400, height: 400, child: board)),
    ),
  );
}
