// Proof for C-518 D2: every hint glyph reads on what it sits on. Written from
// the contract (work/ludo/orders/C-518), not from any implementation.
//
// The rule, restated here so the expectations are computed and not read off
// a run:
//   - the filled disc (ready and waiting) carries contrastingInk(seatColor);
//   - the spent outline sits on LudoColors.paper and carries the seat colour
//     itself when contrastRatio(seatColor, paper) >= 3.0, otherwise
//     Color.lerp(seatColor, LudoColors.ink, t) for the smallest t in
//     {0.1, 0.2, ... 1.0} whose result reaches 3.0;
//   - contrast is measured at full opacity, so the glyph is opaque.
//
// Which seats qualify for each branch is computed with contrastRatio in the
// test, never listed. "Ties go to actionOn" in contrastingInk is not testable
// with the four real seat colours (none sits at the exact midpoint), so it
// has no case here.
//
// The widget cases pump the hint control the way test/hint_control_test.dart
// does: GameScreen over a real RoomController on FakeTransport, my seat set
// to the seat under test, the spent state read from the stored game id. Seat
// 0 (red) and seat 2 (yellow) are the two seats a two-player room can hold.
// A failure line names the seat, the state and both colours.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/hint_button.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/roll_tray_harness.dart';

const double _floor = 3.0;
const String _gameId = 'game-0001';

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

String _seatName(int seat) => 'seat $seat ${_hex(LudoColors.seats[seat])}';

/// The spent-state glyph D2 prescribes, computed from the rule's own text.
Color _expectedUsed(Color seat) {
  if (contrastRatio(seat, LudoColors.paper) >= _floor) {
    return seat;
  }
  for (int step = 1; step <= 10; step++) {
    final Color candidate = Color.lerp(seat, LudoColors.ink, step / 10)!;
    if (contrastRatio(candidate, LudoColors.paper) >= _floor) {
      return candidate;
    }
  }
  throw StateError('no t in 0.1..1.0 reaches $_floor for ${_hex(seat)}');
}

Matcher _sameColour(Color want) => predicate<Color>((Color got) {
  const double eps = 1e-4;
  return (got.a - want.a).abs() < eps &&
      (got.r - want.r).abs() < eps &&
      (got.g - want.g).abs() < eps &&
      (got.b - want.b).abs() < eps;
}, 'the colour ${_hex(want)}');

void main() {
  group('contrastRatio is the WCAG ratio', () {
    test('white on black is 21:1 and black on white is the same', () {
      expect(
        contrastRatio(const Color(0xFFFFFFFF), const Color(0xFF000000)),
        closeTo(21.0, 1e-6),
        reason: 'WCAG 2: (1.05) / (0.05) = 21 for white against black',
      );
      expect(
        contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
        closeTo(21.0, 1e-6),
        reason: 'the ratio is symmetric: lighter over darker either way round',
      );
    });

    test('a colour on itself is 1:1', () {
      for (final Color c in LudoColors.seats) {
        expect(
          contrastRatio(c, c),
          closeTo(1.0, 1e-9),
          reason: 'WCAG 2 gives 1:1 for equal colours, ${_hex(c)}',
        );
      }
    });
  });

  group('contrastingInk picks the stronger of actionOn and ink', () {
    for (int seat = 0; seat < 4; seat++) {
      test(_seatName(seat), () {
        final Color c = LudoColors.seats[seat];
        final Color ink = contrastingInk(c);
        expect(
          ink == LudoColors.actionOn || ink == LudoColors.ink,
          isTrue,
          reason:
              '${_seatName(seat)}: expected actionOn ${_hex(LudoColors.actionOn)} '
              'or ink ${_hex(LudoColors.ink)}, got ${_hex(ink)}',
        );
        final Color other = ink == LudoColors.ink
            ? LudoColors.actionOn
            : LudoColors.ink;
        expect(
          contrastRatio(ink, c),
          greaterThanOrEqualTo(contrastRatio(other, c)),
          reason:
              '${_seatName(seat)}: ${_hex(ink)} must contrast at least as '
              'much as ${_hex(other)}',
        );
      });
    }
  });

  group('D2 hintGlyphColor reaches 3:1 on what it sits on', () {
    for (int seat = 0; seat < 4; seat++) {
      final Color c = LudoColors.seats[seat];

      test('${_seatName(seat)}: the filled disc glyph reads on the seat '
          'colour', () {
        final Color glyph = hintGlyphColor(c, used: false);
        expect(
          glyph.a,
          1.0,
          reason: '${_seatName(seat)}: the glyph is opaque (full opacity)',
        );
        expect(
          contrastRatio(glyph, c),
          greaterThanOrEqualTo(_floor),
          reason:
              '${_seatName(seat)} ready glyph ${_hex(glyph)} on the disc '
              '${_hex(c)} must reach $_floor:1, got '
              '${contrastRatio(glyph, c).toStringAsFixed(2)}:1',
        );
      });

      test('${_seatName(seat)}: the spent glyph reads on the page', () {
        final Color glyph = hintGlyphColor(c, used: true);
        expect(
          glyph.a,
          1.0,
          reason: '${_seatName(seat)}: the glyph is opaque (full opacity)',
        );
        expect(
          contrastRatio(glyph, LudoColors.paper),
          greaterThanOrEqualTo(_floor),
          reason:
              '${_seatName(seat)} used glyph ${_hex(glyph)} on paper '
              '${_hex(LudoColors.paper)} must reach $_floor:1, got '
              '${contrastRatio(glyph, LudoColors.paper).toStringAsFixed(2)}:1',
        );
      });
    }
  });

  group('D2 the filled disc takes contrastingInk', () {
    test('seat 2 (yellow) gets LudoColors.ink', () {
      expect(
        hintGlyphColor(LudoColors.seats[2], used: false),
        LudoColors.ink,
        reason:
            'yellow ${_hex(LudoColors.seats[2])} is the seat the defect '
            'names: paper on it is about 1.5:1, ink must replace it; got '
            '${_hex(hintGlyphColor(LudoColors.seats[2], used: false))}',
      );
    });

    test('seat 0 (red) gets contrastingInk of red', () {
      expect(
        hintGlyphColor(LudoColors.seats[0], used: false),
        contrastingInk(LudoColors.seats[0]),
        reason:
            'red ${_hex(LudoColors.seats[0])}: the disc glyph is '
            'contrastingInk(red), got '
            '${_hex(hintGlyphColor(LudoColors.seats[0], used: false))}, '
            'wanted ${_hex(contrastingInk(LudoColors.seats[0]))}',
      );
    });

    for (int seat = 0; seat < 4; seat++) {
      test('${_seatName(seat)}: ready glyph equals contrastingInk', () {
        final Color c = LudoColors.seats[seat];
        expect(
          hintGlyphColor(c, used: false),
          contrastingInk(c),
          reason: '${_seatName(seat)}: D2 gives the disc contrastingInk',
        );
      });
    }
  });

  group('D2 the spent outline', () {
    test('at least one seat needs darkening and at least one does not', () {
      // Guards the two branches below: if every seat fell on one side, the
      // other branch's cases would pass by never running.
      final List<bool> reaches = <bool>[
        for (final Color c in LudoColors.seats)
          contrastRatio(c, LudoColors.paper) >= _floor,
      ];
      expect(
        reaches.contains(true),
        isTrue,
        reason: 'no seat colour reaches $_floor:1 on paper: $reaches',
      );
      expect(
        reaches.contains(false),
        isTrue,
        reason: 'every seat colour reaches $_floor:1 on paper: $reaches',
      );
    });

    for (int seat = 0; seat < 4; seat++) {
      final Color c = LudoColors.seats[seat];
      final bool qualifies = contrastRatio(c, LudoColors.paper) >= _floor;

      test(
        qualifies
            ? '${_seatName(seat)}: already reaches 3:1 on paper, so the '
                  'glyph is the seat colour unchanged'
            : '${_seatName(seat)}: falls short on paper, so the glyph is the '
                  'smallest lerp toward ink that reaches 3:1',
        () {
          final Color got = hintGlyphColor(c, used: true);
          if (qualifies) {
            expect(
              got,
              c,
              reason:
                  '${_seatName(seat)} reaches '
                  '${contrastRatio(c, LudoColors.paper).toStringAsFixed(2)}'
                  ':1 on paper, wanted it unchanged, got ${_hex(got)}',
            );
          } else {
            expect(
              got,
              _sameColour(_expectedUsed(c)),
              reason:
                  '${_seatName(seat)} reaches only '
                  '${contrastRatio(c, LudoColors.paper).toStringAsFixed(2)}'
                  ':1 on paper; wanted the smallest lerp toward ink '
                  '${_hex(_expectedUsed(c))}, got ${_hex(got)}',
            );
          }
        },
      );
    }
  });

  group('D2 the control draws the glyph colour', () {
    for (final int seat in const <int>[0, 2]) {
      for (final String state in const <String>['ready', 'waiting', 'used']) {
        testWidgets('seat $seat, $state: the bulb Icon colour is '
            'hintGlyphColor', (tester) async {
          SharedPreferences.setMockInitialValues(
            state == 'used'
                ? <String, Object>{hintUsedPrefsKey: _gameId}
                : <String, Object>{},
          );
          final int other = seat == 0 ? 2 : 0;
          final String fixture =
              'my seat $seat, state $state, game_id $_gameId, mine '
              '[16, 18, -1, -1], theirs [1, -1, -1, -1], '
              '${state == 'waiting' ? 'seat $other await_roll' : 'my await_move value 5 legal [0, 1]'}';
          final RollTrayDrive drive = await connectPlaying(
            tester,
            mySeat: seat,
            gameId: _gameId,
            seats: <Map<String, Object?>>[
              seatJson(
                0,
                name: seat == 0 ? 'Sam' : 'Bob',
                tokens: seat == 0
                    ? const <int>[16, 18, -1, -1]
                    : const <int>[1, -1, -1, -1],
              ),
              seatJson(
                2,
                name: seat == 2 ? 'Sam' : 'Bob',
                tokens: seat == 2
                    ? const <int>[16, 18, -1, -1]
                    : const <int>[1, -1, -1, -1],
              ),
            ],
            turn: state == 'waiting'
                ? turnJson(seat: other, phase: 'await_roll', k: 2)
                : turnJson(
                    seat: seat,
                    phase: 'await_move',
                    k: 2,
                    value: 5,
                    legal: const <int>[0, 1],
                  ),
          );
          try {
            await mountGame(tester, drive);
            // The screen reads the spent mark from storage; the legal rings
            // and the countdown animate for ever, so nothing here settles.
            for (int i = 0; i < 3; i++) {
              await tester.runAsync(() => pumpEventQueue());
              await tester.pump(const Duration(milliseconds: 16));
            }
            final Finder stateKey = find.descendant(
              of: find.byKey(hintButtonKey),
              matching: find.byKey(switch (state) {
                'ready' => hintReadyKey,
                'waiting' => hintWaitingKey,
                _ => hintUsedKey,
              }),
            );
            expect(
              stateKey,
              findsOneWidget,
              reason:
                  'fixture is broken: the control is not in the $state '
                  'state. Reproduce with $fixture',
            );
            final Finder icon = find.descendant(
              of: find.byKey(hintButtonKey),
              matching: find.byType(Icon),
            );
            expect(
              icon,
              findsOneWidget,
              reason:
                  'the control holds exactly one bulb Icon. Reproduce with '
                  '$fixture',
            );
            final Color seatColor = LudoColors.seats[seat];
            final Color want = hintGlyphColor(seatColor, used: state == 'used');
            final Color? got = tester.widget<Icon>(icon).color;
            expect(
              got,
              want,
              reason:
                  '${_seatName(seat)} $state: the bulb Icon colour must be '
                  'hintGlyphColor ${_hex(want)}, got '
                  '${got == null ? 'null' : _hex(got)}. Reproduce with '
                  '$fixture',
            );
          } finally {
            await releaseGame(tester, drive);
          }
        });
      }
    }
  });
}
