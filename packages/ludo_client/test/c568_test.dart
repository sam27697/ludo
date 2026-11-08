// Screen proofs for work/ludo/orders/C-568-extra-roll-and-third-six-said.md,
// "What the proofs measure" items 1 to 10. Written from the spec alone; the
// implementation is built in parallel in a tree this file's author has not
// read.
//
// A real GameScreen over a real RoomController on FakeTransport, driven
// through test/support/roll_tray_harness.dart with the server's own frames
// (`rolled`, `moved`, `turn`, `turn_passed`, `room`). Nothing is mocked but
// the socket and the feedback service. The banner is read off
// `game-screen-turn-banner`, the notice off `game-no-move-notice`, cues off
// the recording feedback service and announcements off a mock handler on
// SystemChannels.accessibility.
//
// Each new text is read from AppLocalizations and pinned once per locale
// against the literal in the spec, so a wrong word in an ARB file fails even
// when the screen and the getter agree.
//
// Every case is a fixed list of frames, there is no seed. A failure line
// names the item, the locale, the step, what the banner (or notice) read, the
// room setup and every frame pushed so far, in order, which is the whole
// reproduction. Time is fake and never settled: the only time-driven cases
// pump 100 ms at a time until the hourglass is up.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/roll_tray_harness.dart';

// --- the texts the spec fixes, verbatim (Arabic copied from the spec file) -----

const String _gameRollAgainSixEn = 'Six! Roll again.';
const String _gameRollAgainSixAr = 'ستّة! ارمِ مرة أخرى.';
const String _gameRollAgainCaptureEn = 'You captured. Roll again.';
const String _gameRollAgainCaptureAr = 'ضربت قطعة. ارمِ مرة أخرى.';
const String _gameRollAgainHomeEn = 'Token home. Roll again.';
const String _gameRollAgainHomeAr = 'قطعة في البيت. ارمِ مرة أخرى.';
const String _gameGoesAgainEn = '{name} goes again';
const String _gameGoesAgainAr = 'دور {name} مجددًا';
const String _gameNoMoveThreeSixesEn = 'Three sixes in a row. Turn over.';
const String _gameNoMoveThreeSixesAr = 'ثلاث ستّات متتالية. انتهى الدور.';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _timeUpKey = Key('game-screen-turn-timeup');

bool _isAr(Locale l) => l.languageCode == 'ar';

String _sixLine(Locale l) =>
    _isAr(l) ? _gameRollAgainSixAr : _gameRollAgainSixEn;

String _captureLine(Locale l) =>
    _isAr(l) ? _gameRollAgainCaptureAr : _gameRollAgainCaptureEn;

String _homeLine(Locale l) =>
    _isAr(l) ? _gameRollAgainHomeAr : _gameRollAgainHomeEn;

String _threeSixesLine(Locale l) =>
    _isAr(l) ? _gameNoMoveThreeSixesAr : _gameNoMoveThreeSixesEn;

String _goesAgainLine(Locale l, String name) =>
    (_isAr(l) ? _gameGoesAgainAr : _gameGoesAgainEn).replaceAll('{name}', name);

// --- tokens ----------------------------------------------------------------------

// One token on the track, three in the yard: a 6 is playable for any of them.
const List<int> _openTokens = <int>[10, -1, -1, -1];

// Seat 0 near home: no 6 is playable, today's reason would be need-exact.
const List<int> _nearHomeTokens = <int>[55, 57, 57, 57];

// --- frames ----------------------------------------------------------------------

Map<String, Object?> _rolledData(
  int seat,
  int value, {
  required List<int> queue,
  List<int> legal = const <int>[],
  List<Map<String, Object?>>? legalByFace,
  required int k,
  int deadlineMs = rollTrayDeadlineMs,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': deadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _turnData(
  int seat,
  String phase, {
  List<int> queue = const <int>[],
  int? value,
  List<int>? legal,
  List<Map<String, Object?>>? legalByFace,
  int deadlineMs = rollTrayDeadlineMs,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'queue': queue,
  'value': ?value,
  'legal': ?legal,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _movedData(
  int seat,
  int token,
  int from,
  int to, {
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  required bool extraRoll,
  required int face,
}) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': from,
  'to': to,
  'captured': captured,
  'extra_roll': extraRoll,
  'face': face,
};

Map<String, Object?> _victim(int seat, int token) => <String, Object?>{
  'seat': seat,
  'token': token,
};

/// Seat 0 (mine) to move a 4 with two legal tokens, so no auto-move hold arms
/// and the move frames below land on a plain `await_move`.
Map<String, Object?> _myMoveTurn() => turnJson(
  seat: 0,
  phase: 'await_move',
  k: 1,
  value: 4,
  legal: const <int>[0, 1],
  queue: const <int>[4],
  legalByFace: <Map<String, Object?>>[
    faceLegal(4, const <int>[0, 1]),
  ],
);

Map<String, Object?> _rollTurnOf(int seat, {int k = 0}) =>
    turnJson(seat: seat, phase: 'await_roll', k: k, queue: const <int>[]);

List<Map<String, Object?>> _threeSeats({
  List<int> mine = const <int>[-1, -1, -1, -1],
  List<int> bob = const <int>[-1, -1, -1, -1],
  List<int> cy = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  seatJson(0, name: 'Sam', tokens: mine),
  seatJson(1, name: 'Bob', tokens: bob),
  seatJson(2, name: 'Cy', tokens: cy),
];

// --- announcements ---------------------------------------------------------------

class _Announcements {
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

// --- the play ----------------------------------------------------------------------

/// One mounted GameScreen and the log that makes a failure reproducible.
class _Play {
  _Play(this.tester, this.drive, this.item, this.locale, this.setup);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String item;
  final Locale locale;
  final String setup;
  final List<String> frames = <String>[];

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  String get banner => tester.widget<Text>(find.byKey(_bannerKey)).data!;

  bool get noticeUp => find.byKey(noMoveNoticeKey).evaluate().isNotEmpty;

  String get notice => noticeUp
      ? tester.widget<Text>(find.byKey(noMoveNoticeKey)).data!
      : '<no notice>';

  int cues(FeedbackCue cue) => cueCount(drive.feedback, cue);

  Future<void> push(String type, Map<String, Object?> data) async {
    frames.add('$type ${jsonEncode(data)}');
    await drive.push(tester, type, data);
  }

  /// A reason line: what was expected at [step], what is on screen, and the
  /// whole scenario.
  String why(String step, String expected) =>
      'C-568 $item [${locale.languageCode}] at "$step": expected "$expected", '
      'banner reads "$banner", notice reads "$notice", cues '
      '${drive.feedback.recorded}. Setup: $setup. Frames pushed in order: '
      '${frames.isEmpty ? '<none>' : frames.join(' -> ')}. Fixed frames, no '
      'seed: replay them on a GameScreen over a RoomController on '
      'FakeTransport.';

  void expectBanner(String step, String expected) {
    expect(banner, expected, reason: why(step, expected));
  }

  void expectBannerIsNot(String step, String unwanted) {
    expect(
      banner,
      isNot(unwanted),
      reason: why(step, 'anything but "$unwanted"'),
    );
  }

  void expectNotice(String step, String expected) {
    expect(noticeUp, isTrue, reason: why(step, 'a notice reading $expected'));
    expect(notice, expected, reason: why(step, expected));
  }

  void expectNoticeNotThreeSixes() {
    expect(
      notice,
      isNot(_threeSixesLine(locale)),
      reason: why('never the three-sixes line', 'a plain no-move line'),
    );
  }

  /// The getter and the literal from the spec must agree.
  void pin(String what, String fromLoc, String literal) {
    expect(
      fromLoc,
      literal,
      reason:
          'C-568 $item [${locale.languageCode}]: $what must be exactly '
          '"$literal" (the spec text); AppLocalizations gives "$fromLoc"',
    );
  }

  /// Fake time in 100 ms steps, never settled.
  Future<void> pumpFor(int milliseconds) async {
    for (int t = 0; t < milliseconds; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpToTimeUp() async {
    for (
      int i = 0;
      i < 80 && !find.byKey(_timeUpKey).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(_timeUpKey).evaluate().isNotEmpty,
      isTrue,
      reason: why(
        'fixture: the hourglass within 8 s of fake time',
        'hourglass',
      ),
    );
  }
}

typedef _Body = Future<void> Function(_Play p);

/// Connects seat 0 on [turn] over [seats], mounts GameScreen and runs [body];
/// the screen and the controller are released whatever [body] does.
Future<void> _run(
  WidgetTester tester, {
  required String item,
  required Locale locale,
  required String setup,
  required Map<String, Object?> turn,
  List<Map<String, Object?>>? seats,
  int players = 2,
  required _Body body,
  _Announcements? announcements,
}) async {
  announcements?.install(tester);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    players: players,
  );
  await mountGame(tester, drive, locale: locale);
  final _Play p = _Play(tester, drive, item, locale, setup);
  try {
    await body(p);
  } finally {
    await releaseGame(tester, drive);
  }
}

/// My six that owes a roll: `rolled` 6 with queue [6], then my own `turn`.
Future<void> _mySixOwesRoll(_Play p, {int k = 1}) async {
  await p.push('rolled', _rolledData(0, 6, queue: const <int>[6], k: k));
  await p.push('turn', _turnData(0, 'await_roll', queue: const <int>[6]));
}

/// The move and the `turn` that follows, for [extraRoll] and [captured].
Future<void> _myMove(
  _Play p, {
  required int token,
  required int from,
  required int to,
  required List<Map<String, Object?>> captured,
  required bool extraRoll,
  String? bannerStep,
  String? bannerWant,
}) async {
  await p.push(
    'moved',
    _movedData(
      0,
      token,
      from,
      to,
      captured: captured,
      extraRoll: extraRoll,
      face: 4,
    ),
  );
  if (bannerStep != null) {
    p.expectBanner('$bannerStep (after moved)', bannerWant!);
  }
  await p.push('turn', _turnData(0, 'await_roll'));
}

void main() {
  // ===========================================================================
  // 1. My six owing a roll.
  // ===========================================================================
  group('C-568 1: my six owing a roll', () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 1: $lang: banner reads the six line, then not after '
          'my next roll', (tester) async {
        await _run(
          tester,
          item: '1',
          locale: locale,
          setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
          turn: _rollTurnOf(0),
          seats: twoSeats(mine: _openTokens),
          body: (_Play p) async {
            p.expectBanner('fixture: before any roll', p.loc.gameYourTurnRoll);
            p.pin('gameRollAgainSix', p.loc.gameRollAgainSix, _sixLine(locale));

            await p.push(
              'rolled',
              _rolledData(0, 6, queue: const <int>[6], k: 1),
            );
            p.expectBanner('after rolled 6 queue [6]', _sixLine(locale));
            await p.push(
              'turn',
              _turnData(0, 'await_roll', queue: const <int>[6]),
            );
            p.expectBanner(
              'after turn, same seat, await_roll',
              _sixLine(locale),
            );
            p.expectBannerIsNot(
              'the six line replaces the fresh-turn line',
              p.loc.gameYourTurnRoll,
            );

            // The next roll is a 3: the reason is spent, the phase is a move.
            await p.push(
              'rolled',
              _rolledData(
                0,
                3,
                queue: const <int>[6, 3],
                legal: const <int>[0, 1, 2, 3],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(6, const <int>[0, 1, 2, 3]),
                  faceLegal(3, const <int>[0]),
                ],
                k: 2,
              ),
            );
            p.expectBannerIsNot('after my next rolled', p.loc.gameRollAgainSix);
            p.expectBanner('after my next rolled', p.loc.gameYourTurnMove);
          },
        );
      });
    }

    // Catches a reason that is dropped by any same-seat frame: a repeated
    // `turn` for the same seat and phase (a replay, or the server saying it
    // again) is not one of the clearing events in the definition.
    testWidgets('C-568 1: en: a repeated same-seat turn frame keeps the six '
        'line', (tester) async {
      await _run(
        tester,
        item: '1 repeat',
        locale: _en,
        setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
        turn: _rollTurnOf(0),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          await _mySixOwesRoll(p);
          p.expectBanner('after the six and its turn', _sixLine(_en));
          await p.push(
            'turn',
            _turnData(0, 'await_roll', queue: const <int>[6]),
          );
          p.expectBanner('after the same turn frame again', _sixLine(_en));
        },
      );
    });

    // Catches a six line shown to a seat that is not on turn.
    testWidgets('C-568 1: en: the six line never shows while it is the '
        "other seat's turn", (tester) async {
      await _run(
        tester,
        item: '1 other seat',
        locale: _en,
        setup: 'seat 0 of 2, seat 1 await_roll k 0',
        turn: _rollTurnOf(1),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          await p.push(
            'rolled',
            _rolledData(1, 6, queue: const <int>[6], k: 1),
          );
          await p.push(
            'turn',
            _turnData(1, 'await_roll', queue: const <int>[6]),
          );
          p.expectBannerIsNot(
            "seat 1's six is not my six line",
            p.loc.gameRollAgainSix,
          );
        },
      );
    });
  });

  // ===========================================================================
  // 2. My capture with the bonus.
  // ===========================================================================
  group('C-568 2: my capture with extra_roll', () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 2: $lang: banner reads the capture line', (
        tester,
      ) async {
        await _run(
          tester,
          item: '2',
          locale: locale,
          setup:
              'seat 0 of 2, my tokens [10,20,-1,-1], seat 1 tokens '
              '[14,-1,-1,-1], await_move value 4 legal [0,1]',
          turn: _myMoveTurn(),
          seats: twoSeats(
            mine: const <int>[10, 20, -1, -1],
            other: const <int>[14, -1, -1, -1],
          ),
          body: (_Play p) async {
            p.expectBanner('fixture: before the move', p.loc.gameYourTurnMove);
            p.pin(
              'gameRollAgainCapture',
              p.loc.gameRollAgainCapture,
              _captureLine(locale),
            );
            await _myMove(
              p,
              token: 0,
              from: 10,
              to: 14,
              captured: <Map<String, Object?>>[_victim(1, 0)],
              extraRoll: true,
              bannerStep: 'capture with the bonus',
              bannerWant: _captureLine(locale),
            );
            p.expectBanner(
              'after turn, same seat, await_roll',
              _captureLine(locale),
            );
            p.expectBannerIsNot(
              'the capture line replaces the fresh-turn line',
              p.loc.gameYourTurnRoll,
            );
          },
        );
      });
    }

    // Catches a capture line keyed on `captured` alone: with the bonus rule
    // off the server sends extra_roll false and the seat gets no reason.
    testWidgets('C-568 2: en: a capture without extra_roll sets no reason', (
      tester,
    ) async {
      await _run(
        tester,
        item: '2 no bonus',
        locale: _en,
        setup:
            'seat 0 of 2, my tokens [10,20,-1,-1], seat 1 tokens '
            '[14,-1,-1,-1], await_move value 4 legal [0,1]',
        turn: _myMoveTurn(),
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[14, -1, -1, -1],
        ),
        body: (_Play p) async {
          await _myMove(
            p,
            token: 0,
            from: 10,
            to: 14,
            captured: <Map<String, Object?>>[_victim(1, 0)],
            extraRoll: false,
          );
          p.expectBanner(
            'after a capture with extra_roll false',
            p.loc.gameYourTurnRoll,
          );
        },
      );
    });
  });

  // ===========================================================================
  // 3. My token home with the bonus.
  // ===========================================================================
  group('C-568 3: my token home with extra_roll', () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 3: $lang: banner reads the home line', (tester) async {
        await _run(
          tester,
          item: '3',
          locale: locale,
          setup:
              'seat 0 of 2, my tokens [53,20,-1,-1], await_move value 4 '
              'legal [0,1]',
          turn: _myMoveTurn(),
          seats: twoSeats(mine: const <int>[53, 20, -1, -1]),
          body: (_Play p) async {
            p.pin(
              'gameRollAgainHome',
              p.loc.gameRollAgainHome,
              _homeLine(locale),
            );
            await _myMove(
              p,
              token: 0,
              from: 53,
              to: 57,
              captured: const <Map<String, Object?>>[],
              extraRoll: true,
              bannerStep: 'home with the bonus',
              bannerWant: _homeLine(locale),
            );
            p.expectBanner(
              'after turn, same seat, await_roll',
              _homeLine(locale),
            );
          },
        );
      });
    }

    // Catches a home line keyed on `to == 57` alone.
    testWidgets('C-568 3: en: home without extra_roll sets no reason', (
      tester,
    ) async {
      await _run(
        tester,
        item: '3 no bonus',
        locale: _en,
        setup:
            'seat 0 of 2, my tokens [53,20,-1,-1], await_move value 4 '
            'legal [0,1]',
        turn: _myMoveTurn(),
        seats: twoSeats(mine: const <int>[53, 20, -1, -1]),
        body: (_Play p) async {
          await _myMove(
            p,
            token: 0,
            from: 53,
            to: 57,
            captured: const <Map<String, Object?>>[],
            extraRoll: false,
          );
          p.expectBanner(
            'after home with extra_roll false',
            p.loc.gameYourTurnRoll,
          );
        },
      );
    });
  });

  // ===========================================================================
  // 4. Capture and home in one move.
  // ===========================================================================
  testWidgets('C-568 4: en: a move that captures and reaches home reads the '
      'capture line', (tester) async {
    await _run(
      tester,
      item: '4',
      locale: _en,
      setup:
          'seat 0 of 2, my tokens [51,20,-1,-1], seat 1 tokens '
          '[10,-1,-1,-1], await_move value 4 legal [0,1]',
      turn: _myMoveTurn(),
      seats: twoSeats(
        mine: const <int>[51, 20, -1, -1],
        other: const <int>[10, -1, -1, -1],
      ),
      body: (_Play p) async {
        await _myMove(
          p,
          token: 0,
          from: 51,
          to: 57,
          captured: <Map<String, Object?>>[_victim(1, 0)],
          extraRoll: true,
          bannerStep: 'capture and home together',
          bannerWant: _captureLine(_en),
        );
        p.expectBanner('after turn, same seat, await_roll', _captureLine(_en));
        p.expectBannerIsNot('capture wins over home', _homeLine(_en));
      },
    );
  });

  // ===========================================================================
  // 5. A fresh turn.
  // ===========================================================================
  group('C-568 5: a fresh turn', () {
    testWidgets('C-568 5: en: a turn naming my seat after the other seat reads '
        'the fresh-turn line', (tester) async {
      await _run(
        tester,
        item: '5',
        locale: _en,
        setup: 'seat 0 of 2, snapshot: seat 1 await_roll k 0',
        turn: _rollTurnOf(1),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          p.expectBanner('fixture: waiting', p.loc.gameWaitingForPlayer('Bob'));
          await p.push('turn', _turnData(0, 'await_roll'));
          p.expectBanner('after turn naming my seat', p.loc.gameYourTurnRoll);
        },
      );
    });

    // Catches a reason that survives the turn passing away and coming back:
    // a `turn` naming the other seat clears it.
    for (final Locale locale in _locales) {
      testWidgets('C-568 5: ${locale.languageCode}: the turn goes away and '
          'comes back, the reason does not', (tester) async {
        await _run(
          tester,
          item: '5 round trip',
          locale: locale,
          setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
          turn: _rollTurnOf(0),
          seats: twoSeats(mine: _openTokens),
          body: (_Play p) async {
            await _mySixOwesRoll(p);
            p.expectBanner('fixture: the six line', _sixLine(locale));
            await p.push('turn', _turnData(1, 'await_roll'));
            p.expectBanner(
              'turn naming the other seat',
              p.loc.gameWaitingForPlayer('Bob'),
            );
            await p.push('turn', _turnData(0, 'await_roll'));
            p.expectBanner('turn naming my seat again', p.loc.gameYourTurnRoll);
          },
        );
      });
    }
  });

  // ===========================================================================
  // 6. A snapshot clears the reason.
  // ===========================================================================
  group('C-568 6: a snapshot clears the reason', () {
    testWidgets('C-568 6: en: a room frame while the six line is up', (
      tester,
    ) async {
      await _run(
        tester,
        item: '6 six',
        locale: _en,
        setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
        turn: _rollTurnOf(0),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          await _mySixOwesRoll(p);
          p.expectBanner('fixture: the six line', _sixLine(_en));
          await p.push(
            'room',
            roomData(
              seats: twoSeats(mine: _openTokens),
              turn: turnJson(
                seat: 0,
                phase: 'await_roll',
                k: 1,
                queue: const <int>[6],
              ),
            ),
          );
          p.expectBanner('after a room snapshot', p.loc.gameYourTurnRoll);
        },
      );
    });

    testWidgets('C-568 6: ar: a room frame while the capture line is up', (
      tester,
    ) async {
      await _run(
        tester,
        item: '6 capture',
        locale: _ar,
        setup:
            'seat 0 of 2, my tokens [10,20,-1,-1], seat 1 tokens '
            '[14,-1,-1,-1], await_move value 4 legal [0,1]',
        turn: _myMoveTurn(),
        seats: twoSeats(
          mine: const <int>[10, 20, -1, -1],
          other: const <int>[14, -1, -1, -1],
        ),
        body: (_Play p) async {
          await _myMove(
            p,
            token: 0,
            from: 10,
            to: 14,
            captured: <Map<String, Object?>>[_victim(1, 0)],
            extraRoll: true,
          );
          p.expectBanner('fixture: the capture line', _captureLine(_ar));
          await p.push(
            'room',
            roomData(
              seats: twoSeats(
                mine: const <int>[14, 20, -1, -1],
                other: const <int>[-1, -1, -1, -1],
              ),
              turn: _rollTurnOf(0, k: 1),
            ),
          );
          p.expectBanner('after a room snapshot', p.loc.gameYourTurnRoll);
        },
      );
    });
  });

  // ===========================================================================
  // 7. The watchers' banner.
  // ===========================================================================
  group("C-568 7: a watcher reads another seat's extra roll", () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 7: $lang: six, then capture, then the third seat', (
        tester,
      ) async {
        await _run(
          tester,
          item: '7',
          locale: locale,
          setup:
              'seat 0 of 3 watching, seat 1 Bob tokens [10,-1,-1,-1], seat 2 '
              'Cy tokens [14,-1,-1,-1], seat 1 await_roll k 0',
          turn: _rollTurnOf(1),
          players: 3,
          seats: _threeSeats(
            bob: const <int>[10, -1, -1, -1],
            cy: const <int>[14, -1, -1, -1],
          ),
          body: (_Play p) async {
            p.pin(
              'gameGoesAgain("Bob")',
              p.loc.gameGoesAgain('Bob'),
              _goesAgainLine(locale, 'Bob'),
            );
            p.expectBanner(
              'fixture: Bob to roll',
              p.loc.gameWaitingForPlayer('Bob'),
            );

            // Bob's six owes a roll.
            await p.push(
              'rolled',
              _rolledData(1, 6, queue: const <int>[6], k: 1),
            );
            await p.push(
              'turn',
              _turnData(1, 'await_roll', queue: const <int>[6]),
            );
            p.expectBanner(
              "after Bob's six owing a roll",
              _goesAgainLine(locale, 'Bob'),
            );

            // Bob's next roll spends the reason: back to waiting.
            await p.push(
              'rolled',
              _rolledData(
                1,
                4,
                queue: const <int>[6, 4],
                legal: const <int>[0],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(6, const <int>[0]),
                  faceLegal(4, const <int>[0]),
                ],
                k: 2,
              ),
            );
            p.expectBanner(
              "after Bob's next roll",
              p.loc.gameWaitingForPlayer('Bob'),
            );

            // Bob captures Cy's token with the bonus.
            await p.push(
              'moved',
              _movedData(
                1,
                0,
                10,
                14,
                captured: <Map<String, Object?>>[_victim(2, 0)],
                extraRoll: true,
                face: 4,
              ),
            );
            await p.push('turn', _turnData(1, 'await_roll'));
            p.expectBanner(
              "after Bob's capture with the bonus",
              _goesAgainLine(locale, 'Bob'),
            );

            // The turn moves to the third seat; the watcher (seat 0) is the
            // seat after it by the wrap, so C-590 D3 tells the watcher so.
            await p.push('turn', _turnData(2, 'await_roll'));
            p.expectBanner(
              'after a turn naming a third seat (the watcher is next, C-590 D3)',
              p.loc.gameYouAreNextAfter('Cy'),
            );
          },
        );
      });
    }

    // Catches a watcher line for a move that earned nothing.
    testWidgets("C-568 7: en: Bob's capture without extra_roll stays on "
        'the waiting line', (tester) async {
      await _run(
        tester,
        item: '7 no bonus',
        locale: _en,
        setup:
            'seat 0 of 3 watching, seat 1 Bob tokens [10,-1,-1,-1], seat 2 '
            'Cy tokens [14,-1,-1,-1], seat 1 await_roll k 0',
        turn: _rollTurnOf(1),
        players: 3,
        seats: _threeSeats(
          bob: const <int>[10, -1, -1, -1],
          cy: const <int>[14, -1, -1, -1],
        ),
        body: (_Play p) async {
          await p.push(
            'moved',
            _movedData(
              1,
              0,
              10,
              14,
              captured: <Map<String, Object?>>[_victim(2, 0)],
              extraRoll: false,
              face: 4,
            ),
          );
          await p.push('turn', _turnData(1, 'await_roll'));
          p.expectBanner(
            'after a capture with extra_roll false',
            p.loc.gameWaitingForPlayer('Bob'),
          );
        },
      );
    });

    // Catches a snapshot that leaves a watcher line standing.
    testWidgets('C-568 7: en: a room frame clears the watcher line', (
      tester,
    ) async {
      await _run(
        tester,
        item: '7 snapshot',
        locale: _en,
        setup: 'seat 0 of 3 watching, seat 1 await_roll k 0',
        turn: _rollTurnOf(1),
        players: 3,
        seats: _threeSeats(),
        body: (_Play p) async {
          await p.push(
            'rolled',
            _rolledData(1, 6, queue: const <int>[6], k: 1),
          );
          await p.push(
            'turn',
            _turnData(1, 'await_roll', queue: const <int>[6]),
          );
          p.expectBanner('fixture: Bob goes again', _goesAgainLine(_en, 'Bob'));
          await p.push(
            'room',
            roomData(
              seats: _threeSeats(),
              players: 3,
              turn: turnJson(
                seat: 1,
                phase: 'await_roll',
                k: 1,
                queue: const <int>[6],
              ),
            ),
          );
          p.expectBanner(
            'after a room snapshot',
            p.loc.gameWaitingForPlayer('Bob'),
          );
        },
      );
    });
  });

  // ===========================================================================
  // 8. The third six, said.
  // ===========================================================================
  group('C-568 8: the third six', () {
    /// 6, 6, then the voiding 6, as the server frames them. Returns after the
    /// third `rolled` so a case can look before `turn_passed`.
    Future<void> thirdSix(_Play p) async {
      await _mySixOwesRoll(p, k: 1);
      await p.push('rolled', _rolledData(0, 6, queue: const <int>[6, 6], k: 2));
      await p.push(
        'turn',
        _turnData(0, 'await_roll', queue: const <int>[6, 6]),
      );
      await p.push('rolled', _rolledData(0, 6, queue: const <int>[], k: 3));
    }

    Future<void> endOfTurn(_Play p) async {
      await p.push('turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'three_sixes',
      });
      await p.push('turn', _turnData(1, 'await_roll'));
    }

    List<String> noMoveLines(_Play p) => <String>[
      p.loc.gameNoMove,
      p.loc.gameNoMoveNeedSix,
      p.loc.gameNoMoveNeedExact,
      _gameNoMoveThreeSixesEn,
      _gameNoMoveThreeSixesAr,
      p.loc.gameNoMoveThreeSixes,
    ];

    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 8: $lang: the notice says three sixes, one cue, one '
          'announcement, the red X is up', (tester) async {
        final _Announcements said = _Announcements();
        await _run(
          tester,
          item: '8',
          locale: locale,
          setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
          turn: _rollTurnOf(0),
          seats: twoSeats(mine: _openTokens),
          announcements: said,
          body: (_Play p) async {
            p.pin(
              'gameNoMoveThreeSixes',
              p.loc.gameNoMoveThreeSixes,
              _threeSixesLine(locale),
            );
            await thirdSix(p);
            p.expectNotice(
              'decided at the voiding rolled frame',
              _threeSixesLine(locale),
            );
            expect(
              p.notice,
              p.loc.gameNoMoveThreeSixes,
              reason: p.why(
                'the notice is the getter text',
                p.loc.gameNoMoveThreeSixes,
              ),
            );
            await endOfTurn(p);
            p.expectNotice(
              'after turn_passed three_sixes and the next seat turn',
              _threeSixesLine(locale),
            );
            expect(
              find.byKey(noMoveMarkKey),
              findsOneWidget,
              reason: p.why('the die red X is up', noMoveMarkKey.toString()),
            );
            expect(
              p.cues(FeedbackCue.noMove),
              1,
              reason: p.why('exactly one noMove cue', '1'),
            );
            final List<String> lines = <String>[
              for (final String m in said.recorded)
                if (noMoveLines(p).contains(m)) m,
            ];
            expect(
              lines,
              <String>[_threeSixesLine(locale)],
              reason: p.why(
                'exactly one no-move announcement, the three-sixes line '
                '(announced: ${said.recorded})',
                _threeSixesLine(locale),
              ),
            );
            expect(
              find.byKey(trayDeadKey(0)),
              findsOneWidget,
              reason: p.why(
                'the tray still shows the first dead six',
                'dead 0',
              ),
            );
            expect(
              find.byKey(trayDeadKey(1)),
              findsOneWidget,
              reason: p.why(
                'the tray still shows the second dead six',
                'dead 1',
              ),
            );
          },
        );
      });
    }

    // Catches the three-sixes line losing to need-exact: near home today's
    // reason would be gameNoMoveNeedExact, and the spec says this line wins
    // over any other reason.
    testWidgets('C-568 8: en: the three-sixes line beats need-exact', (
      tester,
    ) async {
      await _run(
        tester,
        item: '8 near home',
        locale: _en,
        setup: 'seat 0 of 2, my tokens $_nearHomeTokens, await_roll k 0',
        turn: _rollTurnOf(0),
        seats: twoSeats(mine: _nearHomeTokens),
        body: (_Play p) async {
          await thirdSix(p);
          p.expectNotice('near home', _threeSixesLine(_en));
          expect(
            p.notice,
            isNot(p.loc.gameNoMoveNeedExact),
            reason: p.why('not the need-exact line', _threeSixesLine(_en)),
          );
          await endOfTurn(p);
          p.expectNotice('after the turn is over', _threeSixesLine(_en));
        },
      );
    });

    // Catches a hold that changed with the new line: up at 1400 ms, gone at
    // 1600 ms, like every no-move notice.
    testWidgets('C-568 8: en: the hold is still 1500 ms', (tester) async {
      await _run(
        tester,
        item: '8 hold',
        locale: _en,
        setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
        turn: _rollTurnOf(0),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          await thirdSix(p);
          await endOfTurn(p);
          await tester.pump(const Duration(milliseconds: 1400));
          p.expectNotice('up at 1400 ms', _threeSixesLine(_en));
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            p.noticeUp,
            isFalse,
            reason: p.why('gone by 1600 ms', '<no notice>'),
          );
        },
      );
    });

    // The screen did not know the queue (a snapshot carried none): the
    // voiding six reads like a plain no-move, then `turn_passed` says why. The
    // notice switches; no second cue, no second announcement.
    for (final Locale locale in _locales) {
      testWidgets('C-568 8: ${locale.languageCode}: queue unknown, turn_passed '
          'switches the notice with no second cue or announcement', (
        tester,
      ) async {
        final _Announcements said = _Announcements();
        await _run(
          tester,
          item: '8 switch',
          locale: locale,
          setup:
              'seat 0 of 2, my tokens $_openTokens, snapshot await_roll k 0 '
              'with queue []',
          turn: _rollTurnOf(0),
          seats: twoSeats(mine: _openTokens),
          announcements: said,
          body: (_Play p) async {
            await p.push(
              'rolled',
              _rolledData(0, 6, queue: const <int>[], k: 3),
            );
            p.expectNotice(
              'before turn_passed the screen cannot know',
              p.loc.gameNoMove,
            );
            await endOfTurn(p);
            p.expectNotice(
              'turn_passed three_sixes switches the notice',
              _threeSixesLine(locale),
            );
            expect(
              p.cues(FeedbackCue.noMove),
              1,
              reason: p.why('still exactly one noMove cue', '1'),
            );
            final List<String> lines = <String>[
              for (final String m in said.recorded)
                if (noMoveLines(p).contains(m)) m,
            ];
            expect(
              lines,
              hasLength(1),
              reason: p.why(
                'no second announcement (announced: ${said.recorded})',
                'one no-move announcement',
              ),
            );
            expect(
              find.byKey(noMoveMarkKey),
              findsOneWidget,
              reason: p.why('the die red X stays up', noMoveMarkKey.toString()),
            );
          },
        );
      });
    }
  });

  // ===========================================================================
  // 9. A plain no move is unchanged.
  // ===========================================================================
  group('C-568 9: a plain no move keeps today\'s line', () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 9: $lang: no legal move on a 3 reads gameNoMove', (
        tester,
      ) async {
        await _run(
          tester,
          item: '9 plain',
          locale: locale,
          setup: 'seat 0 of 2, my tokens [-1,55,57,57], queue before []',
          turn: _rollTurnOf(0),
          seats: twoSeats(mine: const <int>[-1, 55, 57, 57]),
          body: (_Play p) async {
            await pushMyNoMoveRoll(tester, p.drive, face: 4);
            p.frames.add('pushMyNoMoveRoll face 4');
            p.expectNotice('plain no move', p.loc.gameNoMove);
            p.expectNoticeNotThreeSixes();
          },
        );
      });

      testWidgets('C-568 9: $lang: all in the yard on a 3 reads '
          'gameNoMoveNeedSix', (tester) async {
        await _run(
          tester,
          item: '9 need six',
          locale: locale,
          setup: 'seat 0 of 2, my tokens [-1,-1,-1,-1], queue before []',
          turn: _rollTurnOf(0),
          seats: twoSeats(),
          body: (_Play p) async {
            await pushMyNoMoveRoll(tester, p.drive, face: 3);
            p.frames.add('pushMyNoMoveRoll face 3');
            p.expectNotice('need a six', p.loc.gameNoMoveNeedSix);
            p.expectNoticeNotThreeSixes();
          },
        );
      });
    }

    // Catches a third-six test that looks only at the queue it knew: with
    // [6, 6] known, a voided roll of 3 is not a third six (the value is not 6).
    testWidgets('C-568 9: en: a voided 3 after [6, 6] is not a third six', (
      tester,
    ) async {
      await _run(
        tester,
        item: '9 value 3',
        locale: _en,
        setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
        turn: _rollTurnOf(0),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          await _mySixOwesRoll(p, k: 1);
          await p.push(
            'rolled',
            _rolledData(0, 6, queue: const <int>[6, 6], k: 2),
          );
          await p.push(
            'turn',
            _turnData(0, 'await_roll', queue: const <int>[6, 6]),
          );
          await p.push('rolled', _rolledData(0, 3, queue: const <int>[], k: 3));
          p.expectNotice('a 3 with no legal move', p.loc.gameNoMove);
          p.expectNoticeNotThreeSixes();
          await p.push('turn_passed', <String, Object?>{
            'seat': 0,
            'reason': 'no_legal_move',
          });
          await p.push('turn', _turnData(1, 'await_roll'));
          p.expectNotice('after turn_passed no_legal_move', p.loc.gameNoMove);
          p.expectNoticeNotThreeSixes();
        },
      );
    });

    // Catches a three-sixes flag that outlives its turn: the next plain no
    // move, after the hold ended, reads the plain line.
    testWidgets('C-568 9: en: a plain no move after a third six reads the '
        'plain line', (tester) async {
      await _run(
        tester,
        item: '9 after three sixes',
        locale: _en,
        setup: 'seat 0 of 2, my tokens $_openTokens, await_roll k 0',
        turn: _rollTurnOf(0),
        seats: twoSeats(mine: _openTokens),
        body: (_Play p) async {
          await _mySixOwesRoll(p, k: 1);
          await p.push(
            'rolled',
            _rolledData(0, 6, queue: const <int>[6, 6], k: 2),
          );
          await p.push(
            'turn',
            _turnData(0, 'await_roll', queue: const <int>[6, 6]),
          );
          await p.push('rolled', _rolledData(0, 6, queue: const <int>[], k: 3));
          await p.push('turn_passed', <String, Object?>{
            'seat': 0,
            'reason': 'three_sixes',
          });
          await p.push('turn', _turnData(1, 'await_roll'));
          p.expectNotice('fixture: the third six', _threeSixesLine(_en));
          await p.pumpFor(1600);
          await p.push('turn', _turnData(0, 'await_roll'));
          await p.push('rolled', _rolledData(0, 4, queue: const <int>[], k: 4));
          await p.push('turn_passed', <String, Object?>{
            'seat': 0,
            'reason': 'no_legal_move',
          });
          await p.push('turn', _turnData(1, 'await_roll'));
          p.expectNotice('the next plain no move', p.loc.gameNoMove);
          p.expectNoticeNotThreeSixes();
        },
      );
    });
  });

  // ===========================================================================
  // 10. Precedence.
  // ===========================================================================
  group('C-568 10: precedence', () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;

      testWidgets('C-568 10: $lang: my time up beats the six line', (
        tester,
      ) async {
        await _run(
          tester,
          item: '10 time up',
          locale: locale,
          setup:
              'seat 0 of 2, my tokens $_openTokens, six with deadline_ms '
              '2000, pumped to the hourglass',
          turn: _rollTurnOf(0),
          seats: twoSeats(mine: _openTokens),
          body: (_Play p) async {
            await p.push(
              'rolled',
              _rolledData(0, 6, queue: const <int>[6], k: 1, deadlineMs: 2000),
            );
            await p.push(
              'turn',
              _turnData(
                0,
                'await_roll',
                queue: const <int>[6],
                deadlineMs: 2000,
              ),
            );
            p.expectBanner('fixture: above zero', _sixLine(locale));
            await p.pumpToTimeUp();
            p.expectBanner('at my zero', p.loc.gameYourTurnTimeUp);
          },
        );
      });

      testWidgets('C-568 10: $lang: a stale link beats the capture line', (
        tester,
      ) async {
        await _run(
          tester,
          item: '10 stale',
          locale: locale,
          setup:
              'seat 0 of 2, my tokens [10,20,-1,-1], seat 1 tokens '
              '[14,-1,-1,-1], await_move value 4 legal [0,1], the far side '
              'ends the socket after the capture',
          turn: _myMoveTurn(),
          seats: twoSeats(
            mine: const <int>[10, 20, -1, -1],
            other: const <int>[14, -1, -1, -1],
          ),
          body: (_Play p) async {
            await _myMove(
              p,
              token: 0,
              from: 10,
              to: 14,
              captured: <Map<String, Object?>>[_victim(1, 0)],
              extraRoll: true,
            );
            p.expectBanner('fixture: the capture line', _captureLine(locale));
            p.drive.transport.endFromFarSide();
            p.frames.add('far side ends the socket');
            await tester.pump();
            await tester.pump();
            p.expectBanner('socket gone', p.loc.gameYourTurnStale);
          },
        );
      });
    }
  });
}
