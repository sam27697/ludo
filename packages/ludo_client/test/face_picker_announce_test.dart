// Screen proof for C-518 D3: opening the face picker is announced. Written
// from the contract (work/ludo/orders/C-518), not from any implementation.
//
// Announcements are read off SystemChannels.accessibility the way
// test/talkback_announce_test.dart reads them: a mock handler installed in
// the test body, collecting every decoded message whose top-level `type` is
// `announce`, with the text direction it carries. The picker is opened by a
// real tap on the token, on the fixture test/token_face_pick_test.dart uses:
//
//   seat 0's own turn, phase await_move, k 2, queue [6, 4], value 6,
//   legal_by_face {6: [0, 2], 4: [1, 2]}, seat 0 tokens [1, 3, 6, -1].
//   token 0: legal for 6 only      token 1: legal for 4 only
//   token 2: legal for 6 and for 4 token 3: in the yard, legal for neither
//
// A tap on token 2 opens the picker; a tap on token 0 or 1 sends its move at
// once and opens nothing. The expected text is facePickerLabel(token + 1)
// read from the localisations, and also written out as a literal from the
// contract (en "Which roll for piece N?", ar "أي رمية للقطعة N؟") so a
// changed string cannot make both sides move together. The marks are taken
// after the mount, so the mount's own your_turn announcement does not count.
// The scenes are fixed, there is no seed: a failure line names the case,
// the locale and the announcements heard.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/roll_tray_harness.dart';

const List<int> _mine = <int>[1, 3, 6, -1];

/// The literal label of piece [number] per the contract, by locale.
String _literalLabel(String lang, int number) =>
    lang == 'ar' ? 'أي رمية للقطعة $number؟' : 'Which roll for piece $number?';

Map<String, Object?> _pickTurn() {
  final List<Map<String, Object?>> byFace = <Map<String, Object?>>[
    faceLegal(6, const <int>[0, 2]),
    faceLegal(4, const <int>[1, 2]),
  ];
  return turnJson(
    seat: 0,
    phase: 'await_move',
    k: 2,
    value: 6,
    legal: const <int>[0, 2],
    queue: const <int>[6, 4],
    legalByFace: byFace,
  );
}

/// One announce event: the text and the direction index it carries
/// (dart:ui TextDirection is declared rtl, ltr, so 0 is rtl).
class _Heard {
  const _Heard(this.message, this.directionIndex);

  final String message;
  final int directionIndex;

  @override
  String toString() => '"$message" (direction index $directionIndex)';
}

class _Scene {
  _Scene(this.tester, this.drive, this.lang, this.name, this.heard);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String lang;
  final String name;
  final List<_Heard> heard;
  int _mark = 0;
  final List<String> steps = <String>[];

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  /// Announcements heard since the last [mark].
  List<_Heard> get since => heard.skip(_mark).toList();

  void mark() => _mark = heard.length;

  bool get pickerOpen => tester.any(find.byKey(facePickerKey));

  String why(String expected) =>
      '$name ($lang): expected $expected; heard since the mark: $since; '
      'picker open: $pickerOpen; steps: ${steps.join(' > ')}. Reproduce '
      'with seat 0 await_move k 2 queue [6, 4] legal_by_face '
      '{6: [0, 2], 4: [1, 2]} tokens $_mine';

  Future<void> tapToken(int token) async {
    steps.add('tap token $token');
    await tester.tap(find.byKey(tokenHitKey(0, token)), warnIfMissed: false);
    await tester.pump();
    // The picker's 140 ms open motion, in bounded frames: the legal rings
    // and the countdown animate for ever, so nothing here settles.
    for (int i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Exactly one announcement since the mark, with the text of piece
  /// [token]'s picker label, from the localisations and as the literal.
  void expectOneLabel(int token, String when) {
    final String fromArb = loc.facePickerLabel(token + 1);
    final String literal = _literalLabel(lang, token + 1);
    expect(
      fromArb,
      literal,
      reason: why('facePickerLabel(${token + 1}) to read "$literal"'),
    );
    expect(since.map((_Heard h) => h.message).toList(), <String>[
      literal,
    ], reason: why('exactly one announcement, "$literal", $when'));
    final int direction = lang == 'ar'
        ? TextDirection.rtl.index
        : TextDirection.ltr.index;
    expect(
      since.single.directionIndex,
      direction,
      reason: why('the announcement carries the $lang text direction'),
    );
  }

  void expectSilence(String when) {
    expect(since, isEmpty, reason: why('no announcement $when'));
  }
}

Future<_Scene> _start(
  WidgetTester tester,
  String name, {
  required String lang,
}) async {
  final List<_Heard> heard = <_Heard>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        heard.add(
          _Heard(data['message'] as String, data['textDirection'] as int),
        );
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
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: _pickTurn(),
    seats: twoSeats(mine: _mine),
  );
  await mountGame(tester, drive, locale: Locale(lang));
  final _Scene scene = _Scene(tester, drive, lang, name, heard);
  scene.mark();
  expect(
    scene.pickerOpen,
    isFalse,
    reason: scene.why('no picker before any tap (fixture)'),
  );
  return scene;
}

void main() {
  for (final String lang in const <String>['en', 'ar']) {
    group('D3 the picker is announced ($lang)', () {
      testWidgets('a tap on a two-face token announces its label once', (
        tester,
      ) async {
        final _Scene s = await _start(tester, 'open on token 2', lang: lang);
        try {
          await s.tapToken(2);
          expect(
            s.pickerOpen,
            isTrue,
            reason: s.why('the picker is open after the tap (fixture)'),
          );
          s.expectOneLabel(2, 'when the picker opens');
        } finally {
          await releaseGame(tester, s.drive);
        }
      });

      testWidgets('a second tap on the same token closes the picker and '
          'announces nothing new', (tester) async {
        final _Scene s = await _start(tester, 'close on token 2', lang: lang);
        try {
          await s.tapToken(2);
          expect(
            s.pickerOpen,
            isTrue,
            reason: s.why('the picker is open after the first tap (fixture)'),
          );
          s.expectOneLabel(2, 'when the picker opens');
          s.mark();

          await s.tapToken(2);
          expect(
            s.pickerOpen,
            isFalse,
            reason: s.why('the second tap closes the picker (fixture)'),
          );
          s.expectSilence('when the picker closes');
        } finally {
          await releaseGame(tester, s.drive);
        }
      });

      testWidgets('opening the picker again announces once more, once per '
          'open', (tester) async {
        final _Scene s = await _start(tester, 'reopen on token 2', lang: lang);
        try {
          await s.tapToken(2);
          await s.tapToken(2);
          expect(
            s.pickerOpen,
            isFalse,
            reason: s.why('closed between the opens (fixture)'),
          );
          s.mark();

          await s.tapToken(2);
          expect(
            s.pickerOpen,
            isTrue,
            reason: s.why('the picker is open again (fixture)'),
          );
          s.expectOneLabel(2, 'on the second open');
        } finally {
          await releaseGame(tester, s.drive);
        }
      });

      for (final int token in const <int>[0, 1]) {
        testWidgets('a tap on token $token, legal for one face, opens no '
            'picker and announces no picker label', (tester) async {
          final _Scene s = await _start(
            tester,
            'one-face token $token',
            lang: lang,
          );
          try {
            await s.tapToken(token);
            expect(
              s.pickerOpen,
              isFalse,
              reason: s.why('a one-face token sends at once (fixture)'),
            );
            final Set<String> labels = <String>{
              for (int n = 1; n <= 4; n++) _literalLabel(lang, n),
            };
            expect(
              s.since.where((_Heard h) => labels.contains(h.message)),
              isEmpty,
              reason: s.why('no picker label announced for a one-face tap'),
            );
          } finally {
            await releaseGame(tester, s.drive);
          }
        });
      }
    });
  }
}
