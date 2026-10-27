// Screen proof for work/ludo/orders/C-474-why-no-move.md, D2 and D3: the
// no-move notice and its TalkBack announcement say WHY there was no move.
// Written from the contract text alone; the implementation is built in
// parallel in a tree this file's author has not read.
//
// A real GameScreen over a real RoomController on FakeTransport, the way
// test/no_move_beat_test.dart drives it (through test/support/
// roll_tray_harness.dart): seat 0 is mine, a room snapshot puts my four
// tokens where a case needs them, then the server's own frames for a voided
// roll arrive (`rolled` with an empty `legal`, `turn_passed`, the next
// seat's `turn`, docs/PROTOCOL.md section 21.3 rule 4). The notice text is
// read off the `game-no-move-notice` Text; the announcement is read the way
// test/talkback_announce_test.dart reads it, off a mock handler on
// SystemChannels.accessibility.
//
// The strings below are the exact D2 table as amended by A1, written as literals: the new
// getters do not exist on today's main, and a literal also catches a
// wrong word in the ARB file that a getter-vs-getter comparison would pass.
//
// The three scenarios (hand-worked from D1; F = {face} because every voided
// roll on the wire carries an empty queue, section 21.3 rule 3):
//   NEED_SIX   tokens [-1,-1,-1,-1], a 3: U all in the yard, no 6 in F.
//   NEED_EXACT tokens [55,57,57,57], a 4: U = {55}, 55 + 4 = 59 > 57.
//   PLAIN      tokens [-1,55,57,57], a 4: U = {-1,55}, mixed.
//
// Every failure message carries the scenario label (locale, tokens, face,
// surface, scale). The cases are deterministic, so the label is the whole
// reproduction.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/roll_tray_harness.dart';

// --- C-474 D2 with the run 113 amendment A1 (English), verbatim --------------

const String _needSixEn = 'You need a 6 to come out';
const String _needExactEn = 'Home needs an exact roll';
const String _needSixAr = 'تحتاج 6 لإخراج قطعة';
const String _needExactAr = 'تحتاج الرقم بالضبط للبيت';

enum _Reason { needSix, needExact, plain }

class _Scenario {
  const _Scenario(this.reason, this.tokens, this.face);

  final _Reason reason;
  final List<int> tokens;
  final int face;
}

const _Scenario _needSix = _Scenario(_Reason.needSix, <int>[-1, -1, -1, -1], 3);
const _Scenario _needExact = _Scenario(_Reason.needExact, <int>[
  55,
  57,
  57,
  57,
], 4);
const _Scenario _plain = _Scenario(_Reason.plain, <int>[-1, 55, 57, 57], 4);

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

/// The exact line D2 gives for [reason] in [locale]; PLAIN is the unchanged
/// `gameNoMove`, read from [loc].
String _expectedLine(_Reason reason, Locale locale, AppLocalizations loc) {
  final bool ar = locale.languageCode == 'ar';
  switch (reason) {
    case _Reason.needSix:
      return ar ? _needSixAr : _needSixEn;
    case _Reason.needExact:
      return ar ? _needExactAr : _needExactEn;
    case _Reason.plain:
      return loc.gameNoMove;
  }
}

String _label(
  String contract,
  _Scenario s,
  Locale locale, {
  String extra = '',
  double textScale = 1.0,
}) =>
    '$contract | scenario: reason=${s.reason.name} tokens=${s.tokens} '
    'face=${s.face} locale=${locale.languageCode} scale=$textScale'
    '${extra.isEmpty ? '' : ' $extra'}';

// --- driving -----------------------------------------------------------------

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// Connects seat 0 on its own await_roll with [tokens] in the snapshot and
/// mounts GameScreen. Nothing is rolled yet.
Future<RollTrayDrive> _mountWith(
  WidgetTester tester,
  List<int> tokens, {
  required Locale locale,
  double textScale = 1.0,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    seats: twoSeats(mine: tokens),
    turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
  );
  await mountGame(tester, drive, locale: locale, textScale: textScale);
  return drive;
}

String _noticeText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(noMoveNoticeKey)).data!;

void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// One decoded `announce` event, as test/talkback_announce_test.dart reads it.
class _Announcement {
  const _Announcement(this.message);

  final String message;

  @override
  String toString() => '_Announcement("$message")';
}

class _AnnouncementRecorder {
  final List<_Announcement> recorded = <_Announcement>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          recorded.add(_Announcement(data['message'] as String));
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

/// Every no-move line the contract defines, in both languages, plus the
/// plain one, so an announcement of a wrong reason is recognised as a
/// no-move announcement and not silently ignored.
List<String> _allNoMoveLines(AppLocalizations loc) => <String>[
  _needSixEn,
  _needExactEn,
  _needSixAr,
  _needExactAr,
  loc.gameNoMove,
];

void main() {
  // ===========================================================================
  // D3.1: game-no-move-notice shows the line of the armed reason.
  // ===========================================================================
  group('D3.1 the notice text per reason', () {
    for (final Locale locale in _locales) {
      for (final _Scenario s in <_Scenario>[_needSix, _needExact, _plain]) {
        // Catches a notice that still shows `gameNoMove` for every reason
        // (the contract not wired), a reason mapped to the other reason's
        // line (needSix and needExact swapped), or a line missing in one
        // locale only.
        testWidgets('C-474 D3.1: ${s.reason.name} shows its own line in '
            '${locale.languageCode}', (tester) async {
          final RollTrayDrive drive = await _mountWith(
            tester,
            s.tokens,
            locale: locale,
          );
          try {
            await pushMyNoMoveRoll(tester, drive, face: s.face);
            final AppLocalizations loc = _locOf(tester);

            expect(
              find.byKey(noMoveNoticeKey),
              findsOneWidget,
              reason: _label('D3.1 notice not shown after the roll', s, locale),
            );
            final String expected = _expectedLine(s.reason, locale, loc);
            expect(
              _noticeText(tester),
              expected,
              reason: _label(
                'D3.1/D2 notice text',
                s,
                locale,
                extra: 'expected "$expected"',
              ),
            );
            // D3.4: the die's no-move mark is unchanged and still drawn.
            expect(
              find.byKey(noMoveMarkKey),
              findsOneWidget,
              reason: _label('D3.4 die no-move mark must remain', s, locale),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        });
      }
    }

    // Catches a NEED_SIX check that forgets to look for the 6 in F: a lone 6
    // with every token in the yard (an artificial board, but D1 says the
    // first rule that holds wins and rule 1 needs "no face in F is 6") must
    // fall through to the plain line, never "You need a 6".
    for (final Locale locale in _locales) {
      testWidgets(
        'C-474 D1.1/D3.1: a rolled 6 with all in the yard is the plain line '
        'in ${locale.languageCode}',
        (tester) async {
          const _Scenario s = _Scenario(_Reason.plain, <int>[
            -1,
            -1,
            -1,
            -1,
          ], 6);
          final RollTrayDrive drive = await _mountWith(
            tester,
            s.tokens,
            locale: locale,
          );
          try {
            await pushMyNoMoveRoll(tester, drive, face: s.face);
            final AppLocalizations loc = _locOf(tester);
            // F = {6}, U all in the yard: rule 1 needs no 6 in F, so it
            // fails; rule 2 needs no yard token, so it fails; rule 3 plain.
            expect(
              _noticeText(tester),
              loc.gameNoMove,
              reason: _label('D1.1 a 6 in F is never NEED_SIX', s, locale),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }

    // Catches a reason that is computed once at mount (or from the previous
    // roll) and never re-armed: a second no-move roll on the same screen
    // after the first hold ended must read the board and face of that roll.
    testWidgets(
      'C-474 D1/D3.1: a later no-move roll arms its own reason, not the '
      'previous one (en)',
      (tester) async {
        const Locale locale = Locale('en');
        final RollTrayDrive drive = await _mountWith(
          tester,
          _needSix.tokens,
          locale: locale,
        );
        try {
          await pushMyNoMoveRoll(tester, drive, face: _needSix.face);
          expect(
            _noticeText(tester),
            _needSixEn,
            reason: _label('first roll must be NEED_SIX', _needSix, locale),
          );
          await tester.pump(const Duration(milliseconds: 1400));
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            find.byKey(noMoveNoticeKey),
            findsNothing,
            reason: _label('first hold must have ended', _needSix, locale),
          );

          // The game moves on: a snapshot puts my tokens at [55,57,57,57]
          // and my turn comes round again.
          await drive.push(
            tester,
            'room',
            roomData(
              seats: twoSeats(mine: _needExact.tokens),
              turn: turnJson(
                seat: 0,
                phase: 'await_roll',
                k: 2,
                queue: const <int>[],
              ),
            ),
          );
          await pushMyNoMoveRoll(tester, drive, face: _needExact.face, k: 3);
          // U = {55}, F = {4}: 55 + 4 = 59 > 57, rule 2: NEED_EXACT.
          expect(
            _noticeText(tester),
            _needExactEn,
            reason: _label(
              'D1/D3.1 the second roll must re-arm and read NEED_EXACT',
              _needExact,
              locale,
            ),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );

    // Catches a new reason line with its own timing: the contract says
    // "same timing (C-426)", so the hold is still 1500 ms: up at 1400 ms,
    // gone by 1600 ms.
    for (final _Scenario s in <_Scenario>[_needSix, _needExact]) {
      testWidgets(
        'C-474 D3.1: the ${s.reason.name} line is up at 1400 ms and gone by '
        '1600 ms',
        (tester) async {
          const Locale locale = Locale('en');
          final RollTrayDrive drive = await _mountWith(
            tester,
            s.tokens,
            locale: locale,
          );
          try {
            await pushMyNoMoveRoll(tester, drive, face: s.face);
            await tester.pump(const Duration(milliseconds: 1400));
            expect(
              find.byKey(noMoveNoticeKey),
              findsOneWidget,
              reason: _label(
                'D3.1 notice must still be up at 1400ms',
                s,
                locale,
              ),
            );
            await tester.pump(const Duration(milliseconds: 200));
            expect(
              find.byKey(noMoveNoticeKey),
              findsNothing,
              reason: _label('D3.1 notice must be gone by 1600ms', s, locale),
            );
          } finally {
            await releaseGame(tester, drive);
          }
        },
      );
    }
  });

  // ===========================================================================
  // D3.3: the TalkBack announcement reads the same line as the notice.
  // ===========================================================================
  group('D3.3 the announcement equals the notice', () {
    for (final Locale locale in _locales) {
      for (final _Scenario s in <_Scenario>[_needSix, _needExact, _plain]) {
        // Catches an announcement still fed `gameNoMove` while the notice
        // shows the reason (the two diverge), an announcement of the wrong
        // reason, or one announced twice.
        testWidgets(
          'C-474 D3.3: ${s.reason.name} is announced as the notice reads, '
          'once, in ${locale.languageCode}',
          (tester) async {
            final _AnnouncementRecorder recorder = _AnnouncementRecorder();
            recorder.install(tester);
            addTearDown(() => recorder.remove(tester));

            final RollTrayDrive drive = await _mountWith(
              tester,
              s.tokens,
              locale: locale,
            );
            try {
              recorder.recorded.clear();
              await pushMyNoMoveRoll(tester, drive, face: s.face);
              final AppLocalizations loc = _locOf(tester);
              final String expected = _expectedLine(s.reason, locale, loc);

              final List<String> noMoveAnnouncements = <String>[
                for (final _Announcement a in recorder.recorded)
                  if (_allNoMoveLines(loc).contains(a.message)) a.message,
              ];
              expect(
                noMoveAnnouncements,
                <String>[expected],
                reason: _label(
                  'D3.3 exactly one no-move announcement, equal to the '
                  'D2 line',
                  s,
                  locale,
                  extra: 'recorded=${recorder.recorded}',
                ),
              );
              expect(
                noMoveAnnouncements.single,
                _noticeText(tester),
                reason: _label(
                  'D3.3 the announcement must equal the shown notice',
                  s,
                  locale,
                  extra: 'recorded=${recorder.recorded}',
                ),
              );
            } finally {
              await releaseGame(tester, drive);
            }
          },
        );
      }
    }
  });

  // ===========================================================================
  // D1: the reason is fixed when the notice arms.
  // ===========================================================================
  group('D1 the reason does not change while the notice is up', () {
    // Each case arms one reason, then a room snapshot lands UNDER the notice
    // that, if the reason were recomputed from it, would give a different
    // reason for the same face. Catches a build() that recomputes the reason
    // from the live snapshot instead of the one taken at arm time.
    final List<(_Scenario, List<int>, String)> snapshots =
        <(_Scenario, List<int>, String)>[
          // NEED_SIX armed (all in the yard, a 3). Snapshot: [55,57,57,57].
          // Recomputed: U = {55}, 55 + 3 = 58 > 57 -> NEED_EXACT.
          (_needSix, const <int>[55, 57, 57, 57], 'to NEED_EXACT'),
          // NEED_EXACT armed ([55,57,57,57], a 4). Snapshot: all in the
          // yard. Recomputed: U all in the yard, no 6 -> NEED_SIX.
          (_needExact, const <int>[-1, -1, -1, -1], 'to NEED_SIX'),
          // PLAIN armed ([-1,55,57,57], a 4). Snapshot: all in the yard.
          // Recomputed: NEED_SIX.
          (_plain, const <int>[-1, -1, -1, -1], 'to NEED_SIX'),
        ];
    for (final Locale locale in _locales) {
      for (final (_Scenario s, List<int> after, String flips) in snapshots) {
        testWidgets(
          'C-474 D1: ${s.reason.name} stays ${s.reason.name} when a snapshot '
          'that would flip it $flips arrives (${locale.languageCode})',
          (tester) async {
            final RollTrayDrive drive = await _mountWith(
              tester,
              s.tokens,
              locale: locale,
            );
            try {
              await pushMyNoMoveRoll(tester, drive, face: s.face);
              final AppLocalizations loc = _locOf(tester);
              final String expected = _expectedLine(s.reason, locale, loc);
              expect(
                _noticeText(tester),
                expected,
                reason: _label('D1 fixture: armed text', s, locale),
              );

              await tester.pump(const Duration(milliseconds: 300));
              await drive.push(
                tester,
                'room',
                roomData(
                  seats: twoSeats(mine: after),
                  turn: turnJson(
                    seat: 1,
                    phase: 'await_roll',
                    k: 1,
                    queue: const <int>[],
                  ),
                ),
              );
              final List<int> seen = drive.controller.room!.seats
                  .firstWhere((seat) => seat.seat == 0)
                  .tokens;
              expect(
                seen,
                after,
                reason: _label(
                  'D1 fixture: the snapshot must have landed on the '
                  'controller',
                  s,
                  locale,
                  extra: 'after=$after seen=$seen',
                ),
              );
              expect(
                find.byKey(noMoveNoticeKey),
                findsOneWidget,
                reason: _label(
                  'D1 fixture: the hold is not ended by a snapshot '
                  '(C-236 rule 4)',
                  s,
                  locale,
                  extra: 'after=$after',
                ),
              );
              expect(
                _noticeText(tester),
                expected,
                reason: _label(
                  'D1 the reason is fixed when the notice arms',
                  s,
                  locale,
                  extra: 'snapshot tokens=$after $flips',
                ),
              );
            } finally {
              await releaseGame(tester, drive);
            }
          },
        );
      }
    }

    // Catches an announcement recomputed when a snapshot lands (a second
    // announcement, or one for the other reason).
    testWidgets(
      'C-474 D1/D3.3: a snapshot under the notice announces nothing more (en)',
      (tester) async {
        const Locale locale = Locale('en');
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final RollTrayDrive drive = await _mountWith(
          tester,
          _needSix.tokens,
          locale: locale,
        );
        try {
          await pushMyNoMoveRoll(tester, drive, face: _needSix.face);
          final AppLocalizations loc = _locOf(tester);
          final int before = recorder.recorded
              .where((a) => _allNoMoveLines(loc).contains(a.message))
              .length;
          await drive.push(
            tester,
            'room',
            roomData(
              seats: twoSeats(mine: const <int>[55, 57, 57, 57]),
              turn: turnJson(
                seat: 1,
                phase: 'await_roll',
                k: 1,
                queue: const <int>[],
              ),
            ),
          );
          final List<String> after = <String>[
            for (final _Announcement a in recorder.recorded)
              if (_allNoMoveLines(loc).contains(a.message)) a.message,
          ];
          expect(
            after,
            <String>[_needSixEn],
            reason: _label(
              'D1/D3.3 only the arming announcement, none from the snapshot',
              _needSix,
              locale,
              extra: 'before=$before recorded=${recorder.recorded}',
            ),
          );
        } finally {
          await releaseGame(tester, drive);
        }
      },
    );
  });

  // ===========================================================================
  // D3.2 as replaced by A2/A3: the shown line is cut by nothing, takes no more
  // lines than the plain line, and the slot never grows.
  // ===========================================================================
  group('A2/A3 at 360 x 800 and text scale 2.0', () {
    const Size surface = Size(360, 800);
    const double scale = 2.0;

    /// The slot height while the notice for [s] is up, in [locale], on a
    /// fresh mount that is released before this returns.
    Future<double> slotHeightOf(
      WidgetTester tester,
      _Scenario s,
      Locale locale,
    ) async {
      final RollTrayDrive drive = await _mountWith(
        tester,
        s.tokens,
        locale: locale,
        textScale: scale,
      );
      try {
        await pushMyNoMoveRoll(tester, drive, face: s.face);
        expect(
          find.byKey(noMoveNoticeKey),
          findsOneWidget,
          reason: _label(
            'D3.2 fixture: notice must be up to measure the slot',
            s,
            locale,
            textScale: scale,
          ),
        );
        return noMoveNoticeSlotHeight(tester);
      } finally {
        await releaseGame(tester, drive);
      }
    }

    for (final Locale locale in _locales) {
      for (final _Scenario s in <_Scenario>[_needSix, _needExact]) {
        // Catches a reason line that is longer than the plain line at the
        // largest supported scale on a narrow phone (the English strings of
        // the first draft took three lines against two), or one that is cut
        // with maxLines or an ellipsis so the player reads half of the
        // reason. A2: the shown Text has no maxLines and no ellipsis. A3: a
        // TextPainter with the shown style and scaler at the notice's width
        // and no line limit gives at most as many lines as the PLAIN line
        // laid out the same way in the same locale, size and scale; the real
        // paragraph must agree that nothing was cut.
        testWidgets('C-474 A2/A3: the ${s.reason.name} line has no maxLines or '
            'ellipsis and takes no more lines than the plain line '
            '(${locale.languageCode})', (tester) async {
          _setSurface(tester, surface);
          final RollTrayDrive drive = await _mountWith(
            tester,
            s.tokens,
            locale: locale,
            textScale: scale,
          );
          try {
            await pushMyNoMoveRoll(tester, drive, face: s.face);
            final AppLocalizations loc = _locOf(tester);
            final String why = _label(
              'A2/A3 line count at 360x800',
              s,
              locale,
              textScale: scale,
            );

            final Finder notice = find.byKey(noMoveNoticeKey);
            expect(notice, findsOneWidget, reason: '$why: notice not shown');
            final Text text = tester.widget<Text>(notice);
            expect(
              text.data,
              _expectedLine(s.reason, locale, loc),
              reason: '$why: the shown text is not the D2/A1 line',
            );
            expect(
              text.maxLines,
              isNull,
              reason: '$why: A2 the shown notice has no maxLines',
            );
            expect(
              text.overflow,
              isNot(TextOverflow.ellipsis),
              reason: '$why: A2 the shown notice has no ellipsis',
            );

            final BuildContext context = tester.element(notice);
            final TextStyle style = DefaultTextStyle.of(context).style
                .merge(text.style);
            final TextScaler scaler =
                text.textScaler ?? MediaQuery.textScalerOf(context);
            final double width = tester.getSize(notice).width;
            int linesOf(String line) {
              final TextPainter painter = TextPainter(
                text: TextSpan(text: line, style: style),
                textAlign: TextAlign.center,
                textDirection: Directionality.of(context),
                textScaler: scaler,
              )..layout(maxWidth: width);
              final bool exceeded = painter.didExceedMaxLines;
              final int count = painter.computeLineMetrics().length;
              painter.dispose();
              expect(
                exceeded,
                isFalse,
                reason: '$why: "$line" was cut with no limit set',
              );
              return count;
            }

            final int shownLines = linesOf(text.data!);
            final int plainLines = linesOf(loc.gameNoMove);
            expect(
              shownLines,
              lessThanOrEqualTo(plainLines),
              reason:
                  '$why: "${text.data}" takes $shownLines lines at the '
                  'notice width $width, the plain line "${loc.gameNoMove}" '
                  'takes $plainLines',
            );

            final RenderParagraph paragraph = tester
                .renderObject<RenderParagraph>(
                  find.descendant(of: notice, matching: find.byType(RichText)),
                );
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: '$why: the painted paragraph was truncated',
            );
          } finally {
            await releaseGame(tester, drive);
          }
        });

        // Catches a slot sized only for the old line (or only for the new
        // lines in en): the slot's height with the new line must equal its
        // height with the PLAIN line in the same locale, size and scale, or
        // the notice would push the column and the board would jump. The
        // board must also not move when the notice arrives.
        //
        // The slot is measured as the height of the notice's nearest
        // ancestor Stack: the notice is a Positioned.fill child of the
        // below-die slot's Stack, which is sized by its invisible measuring
        // children, so that Stack's height is the slot's reserved height.
        testWidgets(
          'C-474 A2/A3: the ${s.reason.name} slot is as tall as the plain '
          'slot, and the board does not move (${locale.languageCode})',
          (tester) async {
            _setSurface(tester, surface);
            final double plainHeight = await slotHeightOf(
              tester,
              _plain,
              locale,
            );

            final RollTrayDrive drive = await _mountWith(
              tester,
              s.tokens,
              locale: locale,
              textScale: scale,
            );
            try {
              final Rect boardBefore = tester.getRect(find.byKey(boardKey));
              await pushMyNoMoveRoll(tester, drive, face: s.face);
              final String why = _label(
                'D3.2 slot height at 360x800',
                s,
                locale,
                textScale: scale,
              );
              expect(
                find.byKey(noMoveNoticeKey),
                findsOneWidget,
                reason: '$why: notice not shown',
              );
              final double height = noMoveNoticeSlotHeight(tester);
              expect(
                height,
                plainHeight,
                reason:
                    '$why: the slot is $height tall with this line and '
                    '$plainHeight with the plain line; it must never grow',
              );
              final Rect boardDuring = tester.getRect(find.byKey(boardKey));
              expect(
                boardDuring,
                boardBefore,
                reason:
                    '$why: game-screen-board moved when the notice '
                    'arrived: before=$boardBefore during=$boardDuring',
              );
            } finally {
              await releaseGame(tester, drive);
            }
          },
        );
      }
    }
  });
}
