// Screen proofs for C-590 (work/ludo/orders/590-turn-order-you-are-next.md,
// "Order 590t"), cases (f) to (q) plus the ugly cases named in the comments
// below. Written from the contract alone; the implementation is built in
// parallel in a tree this file's author has not read.
//
// A real GameScreen over a real RoomController on FakeTransport (the
// roll-tray and C-468 harnesses under test/support), every state a decoded
// wire frame. Nothing is mocked but the socket and the feedback service. The
// banner is read off `game-screen-turn-banner`, the pips off the
// `game-seat-pip-*` keys, announcements off a mock handler on
// SystemChannels.accessibility, cues off the recording feedback service.
//
// Expected lines are built from the generated AppLocalizations and pinned once
// against the literal in the contract, so a wrong word in an arb file fails
// even when the screen and the getter agree.
//
// Every case is a fixed list of frames, there is no seed. A failure line names
// the case, the table, what the screen showed, and every frame pushed so far in
// order, which is the whole reproduction. Time is fake; the only waits are
// pumps of a stated length.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/die_mark.dart' show NextSeatRingPainter;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';
import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

// --- the texts the contract fixes, verbatim ---------------------------------

const String _afterEn = "You're next, after Bob";
const String _afterAr = 'أنت التالي بعد Bob';
const String _goesAgainEn = "You're next. Bob goes again";
const String _announceEn = "You're next";
const String _announceAr = 'أنت التالي';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _stripKey = Key('game-seat-pip-strip');
const Key _nextKey = Key('game-seat-pip-next');
const Key _turnKey = Key('game-seat-pip-turn');
const Key _shotKey = Key('you-are-next-shot');

Key _pipKey(int seat) => Key('game-seat-pip-$seat');

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
/// spectator's view: nobody is called Sam. [offline] seats are in the room with
/// their socket down (a seat that left in PLAYING keeps its place).
List<Map<String, Object?>> _seatsOf(
  List<int> seats, {
  int? me,
  Set<int> offline = const <int>{},
}) => <Map<String, Object?>>[
  for (final int seat in seats)
    seatJson(
      seat,
      name: seat == me ? 'Sam' : kNames[seat]!,
      connected: !offline.contains(seat),
    ),
];

/// One mounted GameScreen, the log that makes a failure reproducible, and the
/// helpers every case reads the screen through.
class _T {
  _T(this.tester, this.drive, this.s, this.locale, this.said, this.setup);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final Scn s;
  final Locale locale;
  final _Said said;
  final String setup;

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  String get banner => tester.widget<Text>(find.byKey(_bannerKey)).data!;

  /// The seats whose pip sits inside `game-seat-pip-next`, or null when that
  /// key is not on screen.
  List<int>? get nextPipSeats {
    final Finder next = find.byKey(_nextKey);
    if (next.evaluate().isEmpty) {
      return null;
    }
    return <int>[
      for (int seat = 0; seat < 4; seat++)
        if (find
            .descendant(of: next, matching: find.byKey(_pipKey(seat)))
            .evaluate()
            .isNotEmpty)
          seat,
    ];
  }

  List<String> get nextAnnouncements => <String>[
    for (final String m in said.recorded)
      if (m == loc.gameYouAreNextAnnounce) m,
  ];

  String why(String expected) =>
      'C-590 [${locale.languageCode}] $setup | expected: $expected | banner '
      'reads "${_safeBanner()}", next pip holds $nextPipSeats, announcements '
      '${said.recorded}, cues ${drive.feedback.recorded} | ${s.why('replay')}';

  String _safeBanner() =>
      find.byKey(_bannerKey).evaluate().isEmpty ? '<no banner>' : banner;

  Future<void> push(String type, Map<String, Object?> data) =>
      s.push(type, data);

  Future<void> pump(Duration d) => s.pump(d);

  void expectBanner(String step, String expected) {
    expect(banner, expected, reason: why('$step: banner "$expected"'));
  }

  void expectNextPip(String step, int? seat) {
    final List<int>? got = nextPipSeats;
    if (seat == null) {
      expect(got, isNull, reason: why('$step: no game-seat-pip-next'));
    } else {
      expect(got, <int>[
        seat,
      ], reason: why('$step: game-seat-pip-next holds exactly pip $seat'));
    }
  }

  void expectAnnouncements(String step, int count) {
    expect(
      nextAnnouncements,
      hasLength(count),
      reason: why(
        '$step: $count announcement(s) of "${loc.gameYouAreNextAnnounce}"',
      ),
    );
  }

  /// A seat's roll that spends no extra roll, then the move, settled.
  Future<void> seatPlaysOut(int seat, int k) async {
    await push('rolled', rolledFrame(seat, 3, k, legal: const <int>[0]));
    await push('moved', movedFrame(seat, 0, 10, 13));
    await pump(const Duration(seconds: 2));
  }
}

/// Mounts seat [me] (null = spectator) of [seats] on a turn of [turnSeat].
Future<_T> _open(
  WidgetTester tester, {
  required String name,
  required List<int> seats,
  required int? me,
  required int turnSeat,
  String phase = 'await_roll',
  int k = 0,
  List<int> queue = const <int>[],
  Locale locale = _en,
  Set<int> offline = const <int>{},
  double textScale = 1.0,
  bool announcements = false,
  bool shot = false,
  String? stateName,
  Map<String, Object?>? turnOverride,
  bool noTurn = false,
}) async {
  final _Said said = _Said();
  if (announcements) {
    said.install(tester);
  }
  final Map<String, Object?>? turn = noTurn
      ? null
      : (turnOverride ??
            turnJson(
              seat: turnSeat,
              phase: phase,
              k: k,
              queue: phase == 'await_roll' ? queue : null,
            ));
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: _seatsOf(seats, me: me, offline: offline),
    mySeat: me ?? 0,
    players: seats.length,
    sendSeatAssigned: me != null,
    state: stateName ?? 'PLAYING',
    gameId: stateName == 'FINISHED' ? 'aaaaaaaaaaaaaaaa' : null,
    winner: stateName == 'FINISHED' ? seats.first : null,
  );
  if (shot) {
    await tester.pumpWidget(
      rollTrayHarness(
        RepaintBoundary(
          key: _shotKey,
          child: FeedbackScope(
            settings: FeedbackSettings.forTest(),
            service: drive.feedback,
            child: GameScreen(controller: drive.controller),
          ),
        ),
        locale: locale,
        textScale: textScale,
      ),
    );
    await tester.pump();
    await tester.pump();
  } else {
    await mountGame(tester, drive, locale: locale, textScale: textScale);
  }
  final String setup =
      'seats $seats me ${me ?? 'spectator'} turn seat $turnSeat $phase k $k '
      '${offline.isEmpty ? '' : 'offline $offline '}$name';
  return _T(tester, drive, Scn(name, tester, drive), locale, said, setup);
}

Future<void> _close(_T t) => releaseGame(t.tester, t.drive);

/// Reads pixels of the `_shotKey` boundary at 4 device pixels per logical one.
class _Shot {
  _Shot(this.origin, this.bytes, this.width, this.ratio);

  final Offset origin;
  final ByteData bytes;
  final int width;
  final double ratio;

  Color at(Offset global) {
    final int x = ((global.dx - origin.dx) * ratio).round();
    final int y = ((global.dy - origin.dy) * ratio).round();
    final int i = (y * width + x) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  }
}

Future<_Shot> _shoot(WidgetTester tester) async {
  const double ratio = 4;
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_shotKey),
  );
  final ui.Image image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: ratio),
  ))!;
  final ByteData bytes = (await tester.runAsync<ByteData?>(
    () => image.toByteData(),
  ))!;
  return _Shot(
    tester.getTopLeft(find.byKey(_shotKey)),
    bytes,
    image.width,
    ratio,
  );
}

bool _near(Color a, Color b, [int tolerance = 40]) =>
    (((a.r - b.r) * 255).abs() <= tolerance) &&
    (((a.g - b.g) * 255).abs() <= tolerance) &&
    (((a.b - b.b) * 255).abs() <= tolerance);

Offset _onCircle(Offset centre, double radius, double degrees) {
  final double rad = degrees * math.pi / 180;
  return centre + Offset(radius * math.cos(rad), radius * math.sin(rad));
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  // ===========================================================================
  // (f) four seats, I am 2, seat 1 on turn.
  // ===========================================================================
  testWidgets('C-590 (f) en: four seats, me 2, turn 1: the banner says I am '
      'next after Bob and the next pip is mine', (tester) async {
    final _T t = await _open(
      tester,
      name: 'f',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      expect(
        t.loc.gameYouAreNextAfter('Bob'),
        _afterEn,
        reason: 'the getter must be the contract text "$_afterEn"',
      );
      t.expectBanner('after mount', t.loc.gameYouAreNextAfter('Bob'));
      expect(t.banner, _afterEn, reason: t.why('the literal contract line'));
      t.expectNextPip('after mount', 2);
      expect(
        find.byKey(_turnKey),
        findsOneWidget,
        reason: t.why('the turn pip is still there, once'),
      );
      expect(
        find.descendant(
          of: find.byKey(_turnKey),
          matching: find.byKey(_pipKey(1)),
        ),
        findsOneWidget,
        reason: t.why('the turn pip holds pip 1'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (g) four seats, I am 3, seat 1 on turn: not next, today's line.
  // ===========================================================================
  testWidgets('C-590 (g) en: four seats, me 3, turn 1: today\'s waiting line '
      '(banner half)', (tester) async {
    final _T t = await _open(
      tester,
      name: 'g',
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      turnSeat: 1,
    );
    try {
      t.expectBanner('after mount', t.loc.gameWaitingForPlayer('Bob'));
      expect(
        t.banner,
        isNot(contains("You're next")),
        reason: t.why('a seat that is not next never reads a next line'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (g) en: four seats, me 3, turn 1: the next pip still '
      'marks seat 2 (pip half)', (tester) async {
    final _T t = await _open(
      tester,
      name: 'g pip',
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      turnSeat: 1,
    );
    try {
      t.expectNextPip('after mount', 2);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (h) wrap: three seats, I am 0, seat 2 on turn.
  // ===========================================================================
  testWidgets('C-590 (h) en: three seats [0,1,2], me 0, turn 2 wraps: I am '
      'next after Cara', (tester) async {
    final _T t = await _open(
      tester,
      name: 'h',
      seats: const <int>[0, 1, 2],
      me: 0,
      turnSeat: 2,
    );
    try {
      t.expectBanner('after mount', t.loc.gameYouAreNextAfter('Cara'));
      t.expectNextPip('after mount', 0);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (i) the extra roll of the seat on turn.
  // ===========================================================================
  testWidgets('C-590 (i) en: four seats, me 2, seat 1 rolls a six: the line '
      'is "You\'re next. Bob goes again", and falls back when the reason is '
      'spent', (tester) async {
    final _T t = await _open(
      tester,
      name: 'i',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      t.expectBanner('fixture: Bob to roll', t.loc.gameYouAreNextAfter('Bob'));
      await t.push(
        'rolled',
        rolledFrame(1, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(1, queue: const <int>[6]));
      t.expectBanner(
        "after Bob's six owing a roll",
        t.loc.gameYouAreNextGoesAgain('Bob'),
      );
      expect(
        t.loc.gameYouAreNextGoesAgain('Bob'),
        _goesAgainEn,
        reason: 'the getter must be the contract text "$_goesAgainEn"',
      );
      t.expectNextPip("after Bob's six", 2);

      // Bob's next roll is a 4: the reason is spent.
      await t.push(
        'rolled',
        rolledFrame(
          1,
          4,
          2,
          legal: const <int>[0],
          queue: const <int>[6, 4],
          legalByFace: <Map<String, Object?>>[
            faceLegal(6, const <int>[0]),
            faceLegal(4, const <int>[0]),
          ],
        ),
      );
      t.expectBanner("after Bob's next roll", t.loc.gameYouAreNextAfter('Bob'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (i) en: three seats, me 0, seat 2 captures and goes '
      'again across the wrap', (tester) async {
    final _T t = await _open(
      tester,
      name: 'i wrap',
      seats: const <int>[0, 1, 2],
      me: 0,
      turnSeat: 2,
    );
    try {
      await t.push(
        'rolled',
        rolledFrame(2, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(2, queue: const <int>[6]));
      t.expectBanner("after Cara's six", t.loc.gameYouAreNextGoesAgain('Cara'));
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (j) two seats: no next line, the pip still marks.
  // ===========================================================================
  testWidgets('C-590 (j) en: two seats [0,2], me 2, turn 0: today\'s waiting '
      'line (banner half)', (tester) async {
    final _T t = await _open(
      tester,
      name: 'j',
      seats: const <int>[0, 2],
      me: 2,
      turnSeat: 0,
    );
    try {
      t.expectBanner('after mount', t.loc.gameWaitingForPlayer('Ann'));
      await t.push(
        'rolled',
        rolledFrame(0, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(0, queue: const <int>[6]));
      t.expectBanner(
        "after Ann's six at a two seat table",
        t.loc.gameGoesAgain('Ann'),
      );
      expect(
        t.banner,
        isNot(contains("You're next")),
        reason: t.why('two seats never say it'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (j) en: two seats [0,2], me 2, turn 0: the next pip is '
      '2 (pip half)', (tester) async {
    final _T t = await _open(
      tester,
      name: 'j pip',
      seats: const <int>[0, 2],
      me: 2,
      turnSeat: 0,
    );
    try {
      t.expectNextPip('after mount', 2);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (k) my own turn.
  // ===========================================================================
  testWidgets('C-590 (k) en: four seats, my own turn: today\'s own-turn line '
      '(banner half)', (tester) async {
    final _T t = await _open(
      tester,
      name: 'k',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 2,
    );
    try {
      t.expectBanner('after mount', t.loc.gameYourTurnRoll);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (k) en: four seats, my own turn: the next pip is the '
      'seat after mine (pip half)', (tester) async {
    final _T t = await _open(
      tester,
      name: 'k pip',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 2,
    );
    try {
      t.expectNextPip('after mount', 3);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (k) en: three seats, my own turn at the top: the next '
      'pip wraps to seat 0 and the banner is still the own-turn line', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'k wrap',
      seats: const <int>[0, 1, 2],
      me: 2,
      turnSeat: 2,
    );
    try {
      t.expectBanner('after mount', t.loc.gameYourTurnRoll);
      t.expectNextPip('after mount', 0);
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (l) Arabic, case (f).
  // ===========================================================================
  testWidgets('C-590 (l) ar: four seats, me 2, turn 1: the Arabic next line', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'l',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      locale: _ar,
    );
    try {
      expect(t.loc.localeName, 'ar', reason: t.why('fixture: Arabic strings'));
      t.expectBanner('after mount', t.loc.gameYouAreNextAfter('Bob'));
      expect(t.banner, _afterAr, reason: t.why('the literal contract line'));
      t.expectNextPip('after mount', 2);
      await t.push(
        'rolled',
        rolledFrame(1, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(1, queue: const <int>[6]));
      t.expectBanner("after Bob's six", t.loc.gameYouAreNextGoesAgain('Bob'));
      expect(
        t.loc.gameYouAreNextGoesAgain('Bob'),
        'أنت التالي. دور Bob مجددًا',
        reason: t.why('the literal Arabic goes-again line'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (m) every pip draws its shape; the sizes order; the ring is a ring.
  // ===========================================================================
  testWidgets('C-590 (m): every pip is at least 12 x 12 and its SeatMark '
      'paints; next is larger than plain and smaller than turn', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'm',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      final Map<int, Size> sizes = <int, Size>{};
      for (int seat = 0; seat < 4; seat++) {
        final Finder pip = find.byKey(_pipKey(seat));
        expect(
          pip,
          findsOneWidget,
          reason: t.why('pip $seat is on screen once'),
        );
        final Size size = tester.getSize(pip);
        sizes[seat] = size;
        expect(
          size.width >= 12 && size.height >= 12,
          isTrue,
          reason: t.why('pip $seat laid out at least 12 x 12, got $size'),
        );
        final Finder mark = find.descendant(
          of: pip,
          matching: find.byType(SeatMark),
        );
        expect(
          mark,
          findsOneWidget,
          reason: t.why('pip $seat holds one SeatMark'),
        );
        final Size markSize = tester.getSize(mark);
        expect(
          markSize.width >= 6 && markSize.height >= 6,
          isTrue,
          reason: t.why(
            'the SeatMark of pip $seat is at least 6 x 6 (below 6 it paints nothing), got $markSize',
          ),
        );
        expect(
          find.descendant(of: mark, matching: find.byType(CustomPaint)),
          findsWidgets,
          reason: t.why('the SeatMark of pip $seat has a painter in the tree'),
        );
      }
      // Seat 1 is the turn pip, seat 2 the next pip, 0 and 3 plain.
      final double plain = sizes[0]!.width;
      final double next = sizes[2]!.width;
      final double turn = sizes[1]!.width;
      expect(sizes[3]!.width, plain, reason: t.why('the two plain pips agree'));
      expect(
        next,
        greaterThan(plain),
        reason: t.why('next ($next) larger than plain ($plain)'),
      );
      expect(
        next,
        lessThan(turn),
        reason: t.why('next ($next) smaller than turn ($turn)'),
      );
      expect(
        plain,
        closeTo(12, 0.01),
        reason: t.why('plain pip is pipSize 12'),
      );
      expect(next, closeTo(15, 0.01), reason: t.why('next pip is 12 x 1.25'));
      expect(turn, closeTo(18, 0.01), reason: t.why('turn pip is 12 x 1.5'));
      for (final int seat in <int>[0, 1, 2, 3]) {
        expect(
          sizes[seat]!.width,
          sizes[seat]!.height,
          reason: t.why('pip $seat is round'),
        );
      }
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (m): pixels. The next pip has a gap and a broken 1.5 dp '
      'ink ring, the turn pip has a 2 dp border and no ink ring, plain pips '
      'have neither, and every pip paints its shape', (tester) async {
    final _T t = await _open(
      tester,
      name: 'm pixels',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      shot: true,
    );
    try {
      await t.pump(const Duration(milliseconds: 100));
      final _Shot shot = await _shoot(tester);
      final Color ink = LudoColors.ink;
      final List<double> angles = <double>[0, 45, 90, 135, 180, 225, 270, 315];

      // Next pip: seat 2, diameter 15, radius 7.5; ring radius 7.5 + 2.5.
      // C-595 D1: the ring is 8 dashes of 22.5 degrees in 45 degree slots, the
      // first from the top, ink at alpha 0.7. The body and the gap between pip
      // and ring are read at the old eight angles; the ring itself is read in
      // the middle of each dash and in the middle of the gap after it.
      final Offset nextC = tester.getCenter(find.byKey(_pipKey(2)));
      final double nextR = tester.getSize(find.byKey(_pipKey(2))).width / 2;
      for (final double a in angles) {
        final Color body = shot.at(_onCircle(nextC, nextR - 1.0, a));
        expect(
          _near(body, LudoColors.seats[2]),
          isTrue,
          reason: t.why(
            'next pip body at ${a.toInt()} deg is the seat colour, got ${_hex(body)}',
          ),
        );
        final Color gap = shot.at(_onCircle(nextC, nextR + 1.2, a));
        expect(
          _near(gap, ink) || _near(gap, LudoColors.seats[2]),
          isFalse,
          reason: t.why(
            'the gap between pip and ring (radius ${nextR + 1.2}) at ${a.toInt()} deg is neither ink nor the seat colour, got ${_hex(gap)}',
          ),
        );
      }
      for (int i = 0; i < NextSeatRingPainter.dashes; i++) {
        final double slot = 360 / NextSeatRingPainter.dashes;
        final double dashMid = -90 + slot * i + slot / 4;
        final double gapMid = dashMid + slot / 2;
        final Color dash = shot.at(_onCircle(nextC, nextR + 2.5, dashMid));
        final Color gap = shot.at(_onCircle(nextC, nextR + 2.5, gapMid));
        // The dash is ink at the painter's alpha laid over what shows in the
        // gap beside it, so the felt under the ring is part of the colour.
        final Color expected = Color.alphaBlend(
          ink.withValues(alpha: NextSeatRingPainter.alpha),
          gap,
        );
        expect(
          _near(dash, expected),
          isTrue,
          reason: t.why(
            'next ring dash $i (radius ${nextR + 2.5}) at ${dashMid.toStringAsFixed(2)} deg is ink at alpha ${NextSeatRingPainter.alpha} over the gap colour ${_hex(gap)}, wanted ${_hex(expected)}, got ${_hex(dash)}',
          ),
        );
        expect(
          dash.computeLuminance() < gap.computeLuminance(),
          isTrue,
          reason: t.why(
            'next ring dash $i at ${dashMid.toStringAsFixed(2)} deg is darker than the felt in the gap beside it (${_hex(gap)}), got ${_hex(dash)}',
          ),
        );
        expect(
          _near(gap, ink),
          isFalse,
          reason: t.why(
            'next ring gap $i (radius ${nextR + 2.5}) at ${gapMid.toStringAsFixed(2)} deg is not ink, the felt shows, got ${_hex(gap)}',
          ),
        );
        expect(
          _near(gap, dash),
          isFalse,
          reason: t.why(
            'next ring gap $i at ${gapMid.toStringAsFixed(2)} deg differs from the dash before it (${_hex(dash)}), got ${_hex(gap)}',
          ),
        );
      }
      for (final double a in <double>[90, 270]) {
        final Color outside = shot.at(_onCircle(nextC, nextR + 4.5, a));
        expect(
          _near(outside, ink),
          isFalse,
          reason: t.why(
            'outside the ring (radius ${nextR + 4.5}) at ${a.toInt()} deg is not ink, got ${_hex(outside)}',
          ),
        );
      }

      // Turn pip: seat 1, diameter 18; C-595 D2 a 2 dp ink border inside the
      // pip, read in the middle of that band, and no ink ring outside it (the
      // glow there is the seat colour).
      final Offset turnC = tester.getCenter(find.byKey(_pipKey(1)));
      final double turnR = tester.getSize(find.byKey(_pipKey(1))).width / 2;
      for (final double a in angles) {
        final Color border = shot.at(_onCircle(turnC, turnR - 1.0, a));
        expect(
          _near(border, ink),
          isTrue,
          reason: t.why(
            'turn pip border (radius ${turnR - 1.0}, the middle of the 2 dp band) at ${a.toInt()} deg is ink, got ${_hex(border)}',
          ),
        );
        final Color inside = shot.at(_onCircle(turnC, turnR - 3.0, a));
        expect(
          _near(inside, ink),
          isFalse,
          reason: t.why(
            'turn pip at radius ${turnR - 3.0}, inside the 2 dp border, at ${a.toInt()} deg is not ink, got ${_hex(inside)}',
          ),
        );
      }
      for (final double a in <double>[90, 270]) {
        final Color outside = shot.at(_onCircle(turnC, turnR + 2.5, a));
        expect(
          _near(outside, ink),
          isFalse,
          reason: t.why(
            'the turn pip gets no ink ring: radius ${turnR + 2.5} at ${a.toInt()} deg is not ink (the glow is seat colour), got ${_hex(outside)}',
          ),
        );
      }

      // Plain pips: seats 0 and 3, diameter 12, no border and no ring.
      for (final int seat in <int>[0, 3]) {
        final Offset c = tester.getCenter(find.byKey(_pipKey(seat)));
        final double r = tester.getSize(find.byKey(_pipKey(seat))).width / 2;
        for (final double a in <double>[90, 270]) {
          for (final double extra in <double>[-0.5, 1.5, 3.5]) {
            final Color px = shot.at(_onCircle(c, r + extra, a));
            if (extra < 0) {
              expect(
                _near(px, LudoColors.seats[seat]),
                isTrue,
                reason: t.why(
                  'plain pip $seat edge is its seat colour with no border, got ${_hex(px)}',
                ),
              );
            } else {
              expect(
                _near(px, ink),
                isFalse,
                reason: t.why(
                  'plain pip $seat has no ring: radius ${r + extra} at ${a.toInt()} deg is not ink, got ${_hex(px)}',
                ),
              );
            }
          }
        }
      }

      // Every pip paints its shape: the centre pixel is the mark's colour.
      for (int seat = 0; seat < 4; seat++) {
        final Offset c = tester.getCenter(find.byKey(_pipKey(seat)));
        final Color want = seat == 2 ? ink : Colors.white;
        final Color px = shot.at(c);
        expect(
          _near(px, want),
          isTrue,
          reason: t.why(
            'the centre of pip $seat is its mark colour ${_hex(want)} (the shape paints, P9), got ${_hex(px)}',
          ),
        );
      }
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (n) the 48 dp row does not move.
  // ===========================================================================
  testWidgets('C-590 (n): the strip stays bottom-aligned in the same 48 dp '
      'row at every turn of a four seat game', (tester) async {
    // Measured against the row's own rect: the row is the SizedBox(height: 48)
    // that holds the strip, found as the strip's nearest 48 dp ancestor. Before
    // the change the strip's bottom edge is the row's bottom edge (the Stack
    // is bottom-aligned), the row is 48 high and the felt edge ends where the
    // row begins; all three are measured in a four seat game for each seat on
    // turn, so the ring on the next pip must move none of them.
    final List<String> seen = <String>[];
    double? firstBottomGap;
    for (int turnSeat = 0; turnSeat < 4; turnSeat++) {
      final _T t = await _open(
        tester,
        name: 'n turn $turnSeat',
        seats: const <int>[0, 1, 2, 3],
        me: 2,
        turnSeat: turnSeat,
      );
      try {
        final Finder strip = find.byKey(_stripKey);
        final Finder row = find
            .ancestor(
              of: strip,
              matching: find.byWidgetPredicate(
                (Widget w) => w is SizedBox && w.height == 48,
              ),
            )
            .first;
        final Rect rowRect = tester.getRect(row);
        final Rect stripRect = tester.getRect(strip);
        final Rect felt = tester.getRect(
          find.byKey(const Key('game-felt-edge')),
        );
        expect(
          rowRect.height,
          48,
          reason: t.why('the row is 48 dp high, got ${rowRect.height}'),
        );
        expect(
          stripRect.bottom,
          closeTo(rowRect.bottom, 0.01),
          reason: t.why(
            'the strip bottom (${stripRect.bottom}) is the row bottom (${rowRect.bottom})',
          ),
        );
        expect(
          stripRect.top >= rowRect.top - 0.01,
          isTrue,
          reason: t.why(
            'the strip (${stripRect.top}) does not poke out of the top of the row (${rowRect.top})',
          ),
        );
        expect(
          felt.bottom,
          closeTo(rowRect.top, 0.01),
          reason: t.why('the row starts where the felt edge ends'),
        );
        expect(
          tester.takeException(),
          isNull,
          reason: t.why('no layout or paint exception with the next ring'),
        );
        final double gap = rowRect.bottom - stripRect.bottom;
        firstBottomGap ??= gap;
        expect(
          gap,
          firstBottomGap,
          reason: t.why(
            'the strip bottom edge sits at the same place for every turn seat',
          ),
        );
        seen.add('turn $turnSeat: row $rowRect strip $stripRect');
      } finally {
        await _close(t);
      }
    }
    expect(seen, hasLength(4));
  });

  // ===========================================================================
  // (o) TalkBack hears it once.
  // ===========================================================================
  testWidgets('C-590 (o) en: four seats, me 2: the turn moving 0 -> 1 says '
      '"You\'re next" once; an extra roll of seat 1 and a resume replaying '
      'the turn say nothing more', (tester) async {
    final _T t = await _open(
      tester,
      name: 'o',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
      announcements: true,
    );
    try {
      expect(
        t.loc.gameYouAreNextAnnounce,
        _announceEn,
        reason: 'the contract text',
      );
      t.expectAnnouncements('fixture: seat 0 on turn, I am not next', 0);

      await t.seatPlaysOut(0, 1);
      t.expectAnnouncements('while seat 0 plays out its own roll', 0);
      final int beforeTurn = t.said.recorded.length;
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements('the turn moves 0 -> 1', 1);
      expect(
        t.said.recorded.skip(beforeTurn),
        <String>[_announceEn],
        reason: t.why(
          'the turn frame announced exactly "$_announceEn" and nothing else',
        ),
      );
      final int afterTurn = t.said.recorded.length;

      // An extra roll of seat 1: same seat, the turn is not a new one.
      await t.push(
        'rolled',
        rolledFrame(1, 6, 2, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(1, queue: const <int>[6]));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements('after seat 1 rolls a six and goes again', 1);
      expect(
        t.said.recorded.skip(afterTurn).where((String m) => m == _announceEn),
        isEmpty,
        reason: t.why('the extra roll announced nothing'),
      );

      // A resume replays the same turn (seat 1, k 2, queue [6]).
      t.s.steps.add('far side closes, reconnect, resume replays seat 1 k 2');
      t.drive.transport.endFromFarSide();
      await tester.pump();
      await t.pump(const Duration(milliseconds: 100));
      final FakeTransport next = FakeTransport();
      t.drive.enqueueTransport(next);
      final Future<void> reconnect = t.drive.controller.reconnect();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final String id = requestIdOf(
        next.sentRaw.lastWhere((String x) => frameType(x) == 'resume'),
      );
      next.pushText(
        roomReplyFrame(
          re: id,
          seats: _seatsOf(const <int>[0, 1, 2, 3], me: 2),
          turn: turnJson(
            seat: 1,
            phase: 'await_roll',
            k: 2,
            queue: const <int>[6],
          ),
          seq: t.drive.lastSeq + 1,
        ),
      );
      await reconnect;
      await tester.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(
        t.drive.controller.phase,
        RoomPhase.connected,
        reason: t.why('fixture: the resume landed'),
      );
      t.expectAnnouncements('after a resume replaying the same turn', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) en: a seq gap answered by a snapshot of the same '
      'turn says nothing more', (tester) async {
    final _T t = await _open(
      tester,
      name: 'o resync',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
      announcements: true,
    );
    try {
      await t.seatPlaysOut(0, 1);
      await t.push('turn', turnFrame(1));
      t.expectAnnouncements('the turn moves 0 -> 1', 1);
      final int sent = t.drive.transport.sentRaw.length;
      t.s.steps.add('seq jumps by 4, resync, snapshot of seat 1 k 1');
      t.drive.lastSeq += 4;
      await t.push('turn', turnFrame(1));
      final List<String> types = sentTypesSince(t.drive.transport, sent);
      expect(
        types,
        contains('resume'),
        reason: t.why('fixture: a gap starts a resync, sent $types'),
      );
      final String id = requestIdOf(
        t.drive.transport.sentRaw
            .skip(sent)
            .firstWhere((String x) => frameType(x) == 'resume'),
      );
      await pushRaw(
        tester,
        t.drive,
        roomReplyFrame(
          re: id,
          seats: _seatsOf(const <int>[0, 1, 2, 3], me: 2),
          turn: turnJson(
            seat: 1,
            phase: 'await_roll',
            k: 1,
            queue: const <int>[],
          ),
          seq: t.drive.lastSeq + 1,
        ),
      );
      await t.pump(const Duration(milliseconds: 200));
      t.expectBanner('after the snapshot', t.loc.gameYouAreNextAfter('Bob'));
      t.expectAnnouncements('after a snapshot replaying the same turn', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) ar: the Arabic announcement is the Arabic string', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'o ar',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
      locale: _ar,
      announcements: true,
    );
    try {
      await t.seatPlaysOut(0, 1);
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 100));
      expect(
        t.loc.gameYouAreNextAnnounce,
        _announceAr,
        reason: 'the contract text',
      );
      t.expectAnnouncements('the turn moves 0 -> 1', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) en: three seats, me 0, the turn wrapping 1 -> 2 '
      'says it once', (tester) async {
    final _T t = await _open(
      tester,
      name: 'o wrap',
      seats: const <int>[0, 1, 2],
      me: 0,
      turnSeat: 1,
      announcements: true,
    );
    try {
      t.expectAnnouncements(
        'fixture: seat 1 on turn, my turn is after seat 2',
        0,
      );
      await t.seatPlaysOut(1, 1);
      await t.push('turn', turnFrame(2));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements(
        'the turn moves 1 -> 2, I am next across the wrap',
        1,
      );
      t.expectBanner('after the turn', t.loc.gameYouAreNextAfter('Cara'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) en: a full lap with a roll in every turn says it '
      'once per turn I am next, not at my own turn', (tester) async {
    final _T t = await _open(
      tester,
      name: 'o lap rolls',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
      announcements: true,
    );
    try {
      int k = 0;
      Future<void> hand(int from, int to) async {
        k += 1;
        await t.seatPlaysOut(from, k);
        await t.push('turn', turnFrame(to));
        await t.pump(const Duration(milliseconds: 100));
      }

      await hand(0, 1);
      t.expectAnnouncements('turn 1 (I am next)', 1);
      await hand(1, 2);
      t.expectAnnouncements('turn 2 (mine)', 1);
      await hand(2, 3);
      t.expectAnnouncements('turn 3', 1);
      await hand(3, 0);
      t.expectAnnouncements('turn 0', 1);
      await hand(0, 1);
      t.expectAnnouncements('turn 1 again, a new turn, I am next again', 2);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) en: a full lap of turns with no roll in between '
      '(k never moves) still says it once per turn I am next', (tester) async {
    // k only advances with a roll (PROTOCOL section 11), so a lap of turns that
    // pass without one carries the same k into every turn. "Once for that
    // turn" is about the turn, not about k alone.
    final _T t = await _open(
      tester,
      name: 'o lap no rolls',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
      k: 5,
      announcements: true,
    );
    try {
      for (final int seat in <int>[1, 2, 3, 0]) {
        await t.push('turn', turnFrame(seat));
        await t.pump(const Duration(milliseconds: 100));
      }
      t.expectAnnouncements('after one turn 1 and a lap back to 0', 1);
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements('turn 1 a second time with the same k', 2);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) en: not next at a four seat table: no announcement '
      'for a turn change that is not 1 before mine', (tester) async {
    final _T t = await _open(
      tester,
      name: 'o not next',
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      turnSeat: 0,
      announcements: true,
    );
    try {
      await t.seatPlaysOut(0, 1);
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements('turn 0 -> 1 while seat 2 sits between us', 0);
      await t.seatPlaysOut(1, 2);
      await t.push('turn', turnFrame(2));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements('turn 1 -> 2, now I am next', 1);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (o) en: two seats say nothing when the turn comes '
      'round to the other seat', (tester) async {
    final _T t = await _open(
      tester,
      name: 'o two seats',
      seats: const <int>[0, 2],
      me: 2,
      turnSeat: 2,
      announcements: true,
    );
    try {
      await t.seatPlaysOut(2, 1);
      await t.push('turn', turnFrame(0));
      await t.pump(const Duration(milliseconds: 100));
      t.expectAnnouncements(
        'two seats, turn 2 -> 0, I am next but it is a pair',
        0,
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // (p) no haptic, no sound.
  // ===========================================================================
  testWidgets('C-590 (p): the turn change that makes me next records no cue '
      'at all, and no cue is named after it', (tester) async {
    final _T t = await _open(
      tester,
      name: 'p',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
      announcements: true,
    );
    try {
      await t.seatPlaysOut(0, 1);
      final List<FeedbackCue> before = List<FeedbackCue>.of(
        t.drive.feedback.recorded,
      );
      await t.push('turn', turnFrame(1));
      await t.pump(const Duration(milliseconds: 300));
      t.expectAnnouncements('fixture: the announcement fired', 1);
      expect(
        t.drive.feedback.recorded,
        before,
        reason: t.why(
          'the turn change 0 -> 1 recorded no cue; before: $before',
        ),
      );
      await t.push(
        'rolled',
        rolledFrame(1, 6, 2, legal: const <int>[], queue: const <int>[6]),
      );
      final List<FeedbackCue> beforeAgain = List<FeedbackCue>.of(
        t.drive.feedback.recorded,
      );
      await t.push('turn', turnFrame(1, queue: const <int>[6]));
      await t.pump(const Duration(milliseconds: 300));
      expect(
        t.drive.feedback.recorded,
        beforeAgain,
        reason: t.why('the extra roll turn recorded no cue'),
      );
      for (final FeedbackCue cue in FeedbackCue.values) {
        expect(
          cue.name.toLowerCase(),
          isNot(contains('next')),
          reason:
              'doctrine P2: no cue may be invented for "you are next"; found ${cue.name}',
        );
      }
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 (p): a lap of turns records only the cues the lap '
      'already recorded, plus nothing for being next', (tester) async {
    // Same lap with me at 2 and with me at 3: the cue lists must be equal up
    // to the seat whose turn is mine, so being next adds nothing. Compared
    // as the count of cues recorded by the turn frames alone.
    final List<int> counts = <int>[];
    for (final int me in <int>[2, 3]) {
      final _T t = await _open(
        tester,
        name: 'p lap me $me',
        seats: const <int>[0, 1, 2, 3],
        me: me,
        turnSeat: 0,
      );
      try {
        for (final int seat in <int>[1, 2, 3, 0, 1]) {
          await t.push('turn', turnFrame(seat));
          await t.pump(const Duration(milliseconds: 100));
        }
        counts.add(
          t.drive.feedback.recorded
              .where((FeedbackCue c) => c != FeedbackCue.yourTurn)
              .length,
        );
        expect(
          t.drive.feedback.recorded
              .where((FeedbackCue c) => c == FeedbackCue.yourTurn)
              .length,
          1,
          reason: t.why(
            'my own turn cues your_turn exactly once in the lap, got ${t.drive.feedback.recorded}',
          ),
        );
      } finally {
        await _close(t);
      }
    }
    expect(
      counts,
      <int>[counts.first, counts.first],
      reason:
          'C-590 (p): a lap with me at 2 and a lap with me at 3 record the same '
          'number of non-your_turn cues; got $counts',
    );
    expect(
      counts.first,
      0,
      reason:
          'C-590 (p): bare turn frames of other seats play no cue; got $counts',
    );
  });

  // ===========================================================================
  // (q) a spectator.
  // ===========================================================================
  testWidgets('C-590 (q) en: a spectator at a four seat table: no next line, '
      'no announcement across a lap, the strip still marks the next seat', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'q',
      seats: const <int>[0, 1, 2, 3],
      me: null,
      turnSeat: 1,
      announcements: true,
    );
    try {
      expect(
        t.drive.controller.seat,
        isNull,
        reason: t.why('fixture: no seat'),
      );
      t.expectBanner('after mount', t.loc.gameWaitingForPlayer('Bob'));
      t.expectNextPip('after mount', 2);
      for (final int seat in <int>[2, 3, 0, 1]) {
        await t.push('turn', turnFrame(seat));
        await t.pump(const Duration(milliseconds: 100));
        expect(
          t.banner,
          t.loc.gameWaitingForPlayer(kNames[seat]!),
          reason: t.why('the spectator reads the waiting line for seat $seat'),
        );
      }
      await t.push(
        'rolled',
        rolledFrame(1, 6, 1, legal: const <int>[], queue: const <int>[6]),
      );
      await t.push('turn', turnFrame(1, queue: const <int>[6]));
      t.expectBanner(
        'a spectator sees plain goes-again',
        t.loc.gameGoesAgain('Bob'),
      );
      expect(
        t.said.recorded.where((String m) => m == _announceEn),
        isEmpty,
        reason: t.why('a spectator is never told "$_announceEn"'),
      );
    } finally {
      await _close(t);
    }
  });

  // ===========================================================================
  // The ugly cases the contract implies.
  // ===========================================================================
  testWidgets('C-590 table with a hole: seats [0,2,3], the order skips the '
      'empty seat 1', (tester) async {
    final _T t = await _open(
      tester,
      name: 'hole',
      seats: const <int>[0, 2, 3],
      me: 2,
      turnSeat: 0,
      announcements: true,
    );
    try {
      t.expectBanner(
        'seat 0 on turn, seat 2 follows',
        t.loc.gameYouAreNextAfter('Ann'),
      );
      t.expectNextPip('seat 0 on turn', 2);
      expect(
        find.byKey(_pipKey(1)),
        findsNothing,
        reason: t.why('no pip for the empty seat 1'),
      );
      await t.seatPlaysOut(0, 1);
      await t.push('turn', turnFrame(2));
      await t.seatPlaysOut(2, 2);
      await t.push('turn', turnFrame(3));
      t.expectBanner(
        'seat 3 on turn, I am 2',
        t.loc.gameWaitingForPlayer('Dan'),
      );
      t.expectNextPip('seat 3 on turn wraps past the hole to 0', 0);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 table with a hole: seats [0,2,3], me 0, turn 3 wraps', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'hole wrap',
      seats: const <int>[0, 2, 3],
      me: 0,
      turnSeat: 3,
    );
    try {
      t.expectBanner('seat 3 on turn', t.loc.gameYouAreNextAfter('Dan'));
      t.expectNextPip('seat 3 on turn', 0);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 a seat that left in PLAYING keeps its place: the next '
      'pip is the offline seat', (tester) async {
    final _T t = await _open(
      tester,
      name: 'offline next',
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      turnSeat: 1,
      offline: const <int>{2},
    );
    try {
      t.expectNextPip('seat 2 is offline but still in the order', 2);
      t.expectBanner('not me', t.loc.gameWaitingForPlayer('Bob'));
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 the next line also reads while the seat on turn is '
      'choosing a move', (tester) async {
    final _T t = await _open(
      tester,
      name: 'await move',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
    );
    try {
      await t.push(
        'rolled',
        rolledFrame(
          1,
          3,
          1,
          legal: const <int>[0, 1],
          legalByFace: <Map<String, Object?>>[
            faceLegal(3, const <int>[0, 1]),
          ],
          queue: const <int>[3],
        ),
      );
      t.expectBanner(
        'Bob has rolled and must move',
        t.loc.gameYouAreNextAfter('Bob'),
      );
      t.expectNextPip('Bob choosing', 2);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 the banner walks with the table: me 2 at four seats, '
      'seats 0, 1, 2, 3 on turn in turn', (tester) async {
    final _T t = await _open(
      tester,
      name: 'walk',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 0,
    );
    try {
      t.expectBanner('seat 0', t.loc.gameWaitingForPlayer('Ann'));
      t.expectNextPip('seat 0', 1);
      await t.push('turn', turnFrame(1));
      t.expectBanner('seat 1', t.loc.gameYouAreNextAfter('Bob'));
      t.expectNextPip('seat 1', 2);
      await t.push('turn', turnFrame(2));
      t.expectBanner('seat 2 (me)', t.loc.gameYourTurnRoll);
      t.expectNextPip('seat 2', 3);
      await t.push('turn', turnFrame(3));
      t.expectBanner('seat 3', t.loc.gameWaitingForPlayer('Dan'));
      t.expectNextPip('seat 3 wraps', 0);
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 precedence: no turn reads the no-turn line and marks no '
      'next seat', (tester) async {
    final _T t = await _open(
      tester,
      name: 'no turn',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      noTurn: true,
    );
    try {
      t.expectBanner('PLAYING with no turn', t.loc.gameWaitingForTurn);
      t.expectNextPip('PLAYING with no turn', null);
      expect(
        find.byKey(_turnKey),
        findsNothing,
        reason: t.why('no turn pip either'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 no next mark outside PLAYING: a lobby room', (
    tester,
  ) async {
    final _T t = await _open(
      tester,
      name: 'lobby',
      seats: const <int>[0, 1, 2],
      me: 2,
      turnSeat: 0,
      noTurn: true,
      stateName: 'LOBBY',
    );
    try {
      t.expectNextPip('waiting room', null);
      expect(
        find.byKey(_turnKey),
        findsNothing,
        reason: t.why('no turn pip in a lobby'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 precedence: a finished game reads the finished line and '
      'marks no next seat', (tester) async {
    final _T t = await _open(
      tester,
      name: 'finished',
      seats: const <int>[0, 1, 2],
      me: 2,
      turnSeat: 0,
      noTurn: true,
      stateName: 'FINISHED',
    );
    try {
      t.expectNextPip('finished room', null);
      expect(
        find.byKey(_turnKey),
        findsNothing,
        reason: t.why('no turn pip when finished'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 banner discipline: a long name at 2x text still reads '
      'the whole next line, with no layout exception', (tester) async {
    final _T t = await _open(
      tester,
      name: 'long name',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      turnSeat: 1,
      textScale: 2.0,
    );
    try {
      t.expectBanner('at 2x text', t.loc.gameYouAreNextAfter('Bob'));
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no overflow at 2x text'),
      );
      final RenderParagraph p = tester.renderObject(find.byKey(_bannerKey));
      expect(
        p.maxLines,
        isNotNull,
        reason: t.why('the banner keeps its maxLines'),
      );
      expect(
        p.overflow,
        TextOverflow.ellipsis,
        reason: t.why('the banner keeps its ellipsis'),
      );
    } finally {
      await _close(t);
    }
  });

  testWidgets('C-590 ar: three seats, me 0, the wrap in Arabic and RTL: '
      'banner, next pip and no exception', (tester) async {
    final _T t = await _open(
      tester,
      name: 'ar wrap',
      seats: const <int>[0, 1, 2],
      me: 0,
      turnSeat: 2,
      locale: _ar,
    );
    try {
      t.expectBanner('after mount', t.loc.gameYouAreNextAfter('Cara'));
      t.expectNextPip('after mount', 0);
      expect(
        tester.takeException(),
        isNull,
        reason: t.why('no exception in RTL'),
      );
      expect(
        t.banner,
        contains('أنت'),
        reason: t.why('the line is the Arabic one'),
      );
    } finally {
      await _close(t);
    }
  });
}
