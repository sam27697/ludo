// Screen proof for C-478 D6 items 1, 2, 3 and the sheet half of 8 (order
// 481): the quick message lines, the sheet, and the game screen's chat
// button. Written from work/ludo/orders/C-478-quick-chat.md alone; the
// implementation (order 480) was being written in another tree and has not
// been read.
//
// The twelve lines and the four extra strings below are typed out from the
// contract's D3 tables, on purpose: a test that read its expectation from
// the same ARB the product writes would prove nothing about the text.
//
// This file does not compile on a tree without lib/src/quick_chat.dart, the
// ARB getters chat* or the game screen's chat button; that is the expected
// failing arm on the base.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - D5.2 puts the key `quick-chat-mute` on "a row with a Switch". The
//     helper below accepts the key on the Switch itself or on any widget
//     that contains exactly one Switch.
//   - D5.1 says the icon is "drawn at 38 % opacity" without saying how. The
//     measure multiplies every Opacity / FadeTransition above the icon with
//     the icon's own colour alpha, and compares cooling against ready, so a
//     theme colour that is not fully opaque does not matter.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/room_controller.dart' show RoomPhase;
import 'package:ludo_client/src/quick_chat.dart';
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart' show textUnder;
import 'support/roll_tray_harness.dart';

/// (id, en, ar) exactly as the contract's D3 table gives them.
const List<(String, String, String)> kLines = <(String, String, String)>[
  ('hi', 'Hi all', 'مرحبا يا جماعة'),
  ('good_luck', 'Good luck', 'بالتوفيق'),
  ('your_move', 'Come on, your move!', 'يلا، دورك!'),
  ('nice', 'Nice move', 'حلوة منك'),
  ('lucky', 'So lucky!', 'شو هالحظ!'),
  ('oops', 'Oops', 'أوبس'),
  ('ha_ha', 'Ha ha ha', 'هههههه'),
  ('revenge', 'I\'ll get you back', 'رح ردّلك ياها'),
  ('coming', 'Run, I\'m coming!', 'اهرب، جايّك!'),
  ('back_home', 'Back home you go', 'عالبيت يا حلو'),
  ('no_way', 'No way!', 'مستحيل!'),
  ('good_game', 'Good game', 'لعبة حلوة'),
];

const List<String> kIds = <String>[
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
  'no_way',
  'good_game',
];

const Key kSheetKey = Key('quick-chat-sheet');
const Key kMuteKey = Key('quick-chat-mute');
const Key kChatButtonKey = Key('game-chat-button');
const Key kSoundToggleKey = Key('game-sound-toggle');
const Key _openKey = Key('test-open-sheet');

Key chipKey(String id) => Key('quick-chat-$id');

String lineOf(String id, {required bool ar}) {
  for (final (String, String, String) row in kLines) {
    if (row.$1 == id) {
      return ar ? row.$3 : row.$2;
    }
  }
  throw ArgumentError('no such preset: $id');
}

const String _chipPrefix = 'quick-chat-';

/// The ids of the `quick-chat-<id>` chips in the tree, in tree order. The
/// sheet root and the mute switch share the prefix and are not chips.
List<String> chipIds(WidgetTester tester) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        key.value.startsWith(_chipPrefix) &&
        key.value != 'quick-chat-sheet' &&
        key.value != 'quick-chat-mute';
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value.substring(_chipPrefix.length),
];

class _SheetHost {
  _SheetHost(this.muted);

  final ValueNotifier<bool> muted;
  final List<String> picks = <String>[];

  /// `Navigator.canPop` at the moment each onPick ran: false means the
  /// sheet route had already been popped.
  final List<bool> canPopAtPick = <bool>[];
  final List<String> steps = <String>[];

  String why(String expected) =>
      'expected: $expected | picks so far: $picks | replay: '
      '${steps.join(' > ')}';
}

Future<_SheetHost> _openSheet(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  bool muted = false,
  double textScale = 1.0,
  double? width,
}) async {
  phoneSurface(tester);
  if (width != null) {
    tester.view.physicalSize = Size(width, 800);
  }
  final _SheetHost host = _SheetHost(ValueNotifier<bool>(muted));
  host.steps.add('mount ${locale.languageCode} muted=$muted scale=$textScale');
  await tester.pumpWidget(
    rollTrayHarness(
      Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              key: _openKey,
              onPressed: () => showQuickChatSheet(
                context,
                onPick: (String id) {
                  host.picks.add(id);
                  host.canPopAtPick.add(Navigator.of(context).canPop());
                },
                muted: host.muted,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      locale: locale,
      textScale: textScale,
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(_openKey));
  host.steps.add('open');
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  expect(
    find.byKey(kSheetKey),
    findsOneWidget,
    reason: host.why('showQuickChatSheet puts quick-chat-sheet on screen'),
  );
  return host;
}

Future<void> _tapChip(WidgetTester tester, _SheetHost host, String id) async {
  host.steps.add('tap $id');
  await tester.ensureVisible(find.byKey(chipKey(id)));
  await tester.tap(find.byKey(chipKey(id)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The Switch the mute key names: the key's own widget or the one Switch
/// under it.
Finder _muteSwitch(WidgetTester tester) {
  final Finder keyed = find.byKey(kMuteKey);
  expect(keyed, findsOneWidget, reason: 'quick-chat-mute is on the sheet');
  if (tester.widget(keyed) is Switch) {
    return keyed;
  }
  final Finder inner = find.descendant(
    of: keyed,
    matching: find.byType(Switch),
  );
  expect(
    inner,
    findsOneWidget,
    reason: 'quick-chat-mute holds exactly one Switch',
  );
  return inner;
}

bool _switchOn(WidgetTester tester) =>
    tester.widget<Switch>(_muteSwitch(tester)).value;

/// Surface width for the row-order case, see the comment there.
const double _kRowWidth = 800;

/// A rect-based reading of the layout row a chip sits on.
bool _sameRow(Rect a, Rect b) => (a.top - b.top).abs() < 1.0;

void main() {
  // -------------------------------------------------------------------
  // Item 1: the lines.
  // -------------------------------------------------------------------
  group('1. quickChatLine and the D3 strings', () {
    test('the public constants are the contract\'s', () {
      expect(
        kQuickChatIds,
        kIds,
        reason: 'kQuickChatIds is the twelve D3 ids in the sheet\'s order',
      );
      expect(kQuickChatCooldown, const Duration(milliseconds: 3000));
      expect(kChatBubbleLife, const Duration(milliseconds: 2500));
    });

    for (final (String, String) row in const <(String, String)>[
      ('en', 'en'),
      ('ar', 'ar'),
    ]) {
      final bool ar = row.$1 == 'ar';
      test(
        'quickChatLine gives the D3 text for all twelve ids in ${row.$1}',
        () async {
          final AppLocalizations loc = await AppLocalizations.delegate.load(
            Locale(row.$1),
          );
          for (final (String, String, String) line in kLines) {
            expect(
              quickChatLine(loc, line.$1),
              ar ? line.$3 : line.$2,
              reason:
                  'quickChatLine(${row.$1}, ${line.$1}) must be the D3 text '
                  '"${ar ? line.$3 : line.$2}"',
            );
          }
        },
      );

      test(
        'quickChatLine gives null for anything not in the twelve (${row.$1})',
        () async {
          final AppLocalizations loc = await AppLocalizations.delegate.load(
            Locale(row.$1),
          );
          for (final String bad in const <String>[
            'nope',
            '',
            ' ',
            'HI',
            'Hi',
            'hi ',
            ' hi',
            'good-luck',
            'goodluck',
            'Hi all',
            'chatHi',
            '0',
          ]) {
            expect(
              quickChatLine(loc, bad),
              isNull,
              reason:
                  'quickChatLine(${row.$1}, "$bad") must be null: "$bad" is '
                  'not one of kQuickChatIds',
            );
          }
        },
      );
    }

    for (final (String, String, String, String) row
        in const <(String, String, String, String)>[
          (
            'en',
            'Quick messages',
            'Quick messages',
            'Hide the others\' messages',
          ),
          ('ar', 'رسايل سريعة', 'رسايل سريعة', 'خبّي رسايل الباقين'),
        ]) {
      test('the four extra D3 strings in ${row.$1}', () async {
        final AppLocalizations loc = await AppLocalizations.delegate.load(
          Locale(row.$1),
        );
        expect(loc.chatButtonTooltip, row.$2);
        expect(loc.chatSheetTitle, row.$3);
        expect(loc.chatMuteOthers, row.$4);
        expect(loc.chatSaid('Bob', 'x'), 'Bob: x');
      });
    }

    test(
      'chatSaid puts name and line in, and does not re-read braces',
      () async {
        for (final String code in const <String>['en', 'ar']) {
          final AppLocalizations loc = await AppLocalizations.delegate.load(
            Locale(code),
          );
          expect(loc.chatSaid('Bob', 'Hi all'), 'Bob: Hi all');
          expect(loc.chatSaid('{line}', '{name}'), '{line}: {name}');
          expect(loc.chatSaid('', ''), ': ');
          expect(
            loc.chatSaid('سام', 'مرحبا يا جماعة'),
            'سام: مرحبا يا جماعة',
            reason: 'chatSaid ($code) is "{name}: {line}" in both languages',
          );
        }
      },
    );

    test('no emoji in the chat strings or in quick_chat.dart, and the ARB '
        'files carry all sixteen keys', () {
      final List<String> keys = <String>[
        'chatHi',
        'chatGoodLuck',
        'chatYourMove',
        'chatNice',
        'chatLucky',
        'chatOops',
        'chatHaHa',
        'chatRevenge',
        'chatComing',
        'chatBackHome',
        'chatNoWay',
        'chatGoodGame',
        'chatButtonTooltip',
        'chatSheetTitle',
        'chatMuteOthers',
        'chatSaid',
      ];
      bool emojiLike(int rune) =>
          rune >= 0x1F000 ||
          (rune >= 0x2600 && rune <= 0x27BF) ||
          rune == 0xFE0F ||
          rune == 0x200D ||
          (rune >= 0x2190 && rune <= 0x21FF) ||
          (rune >= 0x2B00 && rune <= 0x2BFF);
      for (final String code in const <String>['en', 'ar']) {
        final Map<String, Object?> arb = jsonDecode(
          File('lib/l10n/app_$code.arb').readAsStringSync(),
        ) as Map<String, Object?>;
        for (final String key in keys) {
          expect(
            arb[key],
            isA<String>(),
            reason: 'app_$code.arb must carry the key $key',
          );
          expect(
            (arb[key]! as String).runes.any(emojiLike),
            isFalse,
            reason: 'app_$code.arb $key must hold no emoji character',
          );
        }
      }
      final String source = File('lib/src/quick_chat.dart').readAsStringSync();
      expect(
        source.runes.any(emojiLike),
        isFalse,
        reason: 'lib/src/quick_chat.dart must hold no emoji character',
      );
    });

    test('chatSaid declares two String placeholders, name and line', () {
      final Map<String, Object?> arb = jsonDecode(
        File('lib/l10n/app_en.arb').readAsStringSync(),
      ) as Map<String, Object?>;
      final Map<String, Object?> meta =
          arb['@chatSaid']! as Map<String, Object?>;
      final Map<String, Object?> placeholders =
          meta['placeholders']! as Map<String, Object?>;
      expect(placeholders.keys.toSet(), <String>{'name', 'line'});
      for (final String name in <String>['name', 'line']) {
        expect(
          (placeholders[name]! as Map<String, Object?>)['type'],
          'String',
          reason: 'placeholder $name is a String',
        );
      }
    });
  });

  // -------------------------------------------------------------------
  // Item 2 and the sheet half of 8.
  // -------------------------------------------------------------------
  group('2. the sheet', () {
    testWidgets('shows the twelve chips in kQuickChatIds order with the D3 '
        'text, in one Wrap', (tester) async {
      final _SheetHost host = await _openSheet(tester);
      expect(chipIds(tester), kIds, reason: host.why('twelve chips in order'));
      final Finder wraps = find.descendant(
        of: find.byKey(kSheetKey),
        matching: find.byType(Wrap),
      );
      expect(wraps, findsOneWidget, reason: host.why('one Wrap of chips'));
      for (final String id in kIds) {
        expect(
          find.descendant(of: wraps, matching: find.byKey(chipKey(id))),
          findsOneWidget,
          reason: host.why('chip $id is inside the Wrap'),
        );
        expect(
          find.descendant(
            of: find.byKey(chipKey(id)),
            matching: find.text(lineOf(id, ar: false)),
          ),
          findsOneWidget,
          reason: host.why('chip $id reads "${lineOf(id, ar: false)}"'),
        );
      }
      expect(
        find.descendant(
          of: find.byKey(kSheetKey),
          matching: find.text('Quick messages'),
        ),
        findsOneWidget,
        reason: host.why('the sheet title is "Quick messages"'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('every chip is at least 48 dp tall and is not a Material '
        'ActionChip, ElevatedButton or ListTile', (tester) async {
      final _SheetHost host = await _openSheet(tester);
      for (final String id in kIds) {
        final Size size = tester.getSize(find.byKey(chipKey(id)));
        expect(
          size.height,
          greaterThanOrEqualTo(48.0),
          reason: host.why('chip $id is ${size.height} dp tall, needs 48'),
        );
      }
      for (final Type forbidden in <Type>[
        ActionChip,
        ElevatedButton,
        ListTile,
      ]) {
        expect(
          find.descendant(
            of: find.byKey(kSheetKey),
            matching: find.byType(forbidden),
          ),
          findsNothing,
          reason: host.why('the sheet holds no $forbidden'),
        );
      }
    });

    testWidgets('chip text is labelLarge in ink', (tester) async {
      final _SheetHost host = await _openSheet(tester);
      final Finder text = find.descendant(
        of: find.byKey(chipKey('hi')),
        matching: find.byType(Text),
      );
      expect(text, findsOneWidget, reason: host.why('one Text in the chip'));
      final Element element = tester.element(text);
      final TextStyle style = DefaultTextStyle.of(element).style
          .merge(tester.widget<Text>(text).style);
      final TextStyle label = Theme.of(element).textTheme.labelLarge!;
      expect(
        style.fontSize,
        label.fontSize,
        reason: host.why('labelLarge size'),
      );
      expect(style.color, LudoColors.ink, reason: host.why('ink colour'));
    });

    testWidgets('a chip tap pops the sheet, then calls onPick once with its '
        'id', (tester) async {
      for (final String id in <String>['hi', 'good_game', 'revenge']) {
        final _SheetHost host = await _openSheet(tester);
        expect(
          Navigator.of(tester.element(find.byKey(kSheetKey))).canPop(),
          isTrue,
          reason: host.why('fixture: the sheet is a route above the page'),
        );
        await _tapChip(tester, host, id);
        expect(
          find.byKey(kSheetKey),
          findsNothing,
          reason: host.why('the sheet is gone after a chip tap'),
        );
        expect(host.picks, <String>[id], reason: host.why('onPick($id) once'));
        expect(host.canPopAtPick, <bool>[
          false,
        ], reason: host.why('the sheet was already popped when onPick ran'));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('a second tap on the way out does not call onPick again', (
      tester,
    ) async {
      final _SheetHost host = await _openSheet(tester);
      host.steps.add('double tap oops');
      await tester.tap(find.byKey(chipKey('oops')));
      await tester.tap(find.byKey(chipKey('oops')), warnIfMissed: false);
      await tester.tap(find.byKey(chipKey('nice')), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(host.picks, <String>[
        'oops',
      ], reason: host.why('one pick for three taps in one gesture burst'));
      expect(
        find.byKey(_openKey),
        findsOneWidget,
        reason: host.why('the page under the sheet is still there (one pop)'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('dismissing the sheet without a tap never calls onPick', (
      tester,
    ) async {
      final _SheetHost host = await _openSheet(tester);
      host.steps.add('tap barrier');
      await tester.tapAt(const Offset(180, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(kSheetKey), findsNothing, reason: host.why('closed'));
      expect(host.picks, isEmpty, reason: host.why('no onPick'));
    });

    testWidgets('the mute switch is below the chips, labelled, and flips '
        'muted both ways', (tester) async {
      final _SheetHost host = await _openSheet(tester);
      expect(
        find.descendant(
          of: find.byKey(kSheetKey),
          matching: find.text('Hide the others\' messages'),
        ),
        findsOneWidget,
        reason: host.why('label chatMuteOthers'),
      );
      expect(_switchOn(tester), isFalse, reason: host.why('starts off'));
      final double lowestChip = kIds
          .map((String id) => tester.getRect(find.byKey(chipKey(id))).bottom)
          .reduce((double a, double b) => a > b ? a : b);
      expect(
        tester.getRect(_muteSwitch(tester)).top,
        greaterThanOrEqualTo(lowestChip - 0.5),
        reason: host.why('the switch row is below the chips'),
      );
      host.steps.add('tap switch');
      await tester.tap(_muteSwitch(tester));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(host.muted.value, isTrue, reason: host.why('tap turns muted on'));
      expect(
        find.byKey(kSheetKey),
        findsOneWidget,
        reason: host.why('stays open'),
      );
      expect(host.picks, isEmpty, reason: host.why('no pick from a switch'));
      host.steps.add('tap switch');
      await tester.tap(_muteSwitch(tester));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(host.muted.value, isFalse, reason: host.why('second tap: off'));
      host.steps.add('muted = true from outside');
      host.muted.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        _switchOn(tester),
        isTrue,
        reason: host.why('the switch follows muted when it changes outside'),
      );
    });

    testWidgets('opened with muted already true, the switch shows on', (
      tester,
    ) async {
      final _SheetHost host = await _openSheet(tester, muted: true);
      expect(_switchOn(tester), isTrue, reason: host.why('switch on'));
    });

    testWidgets('the sheet fits a 360 wide phone at large text with every '
        'chip still 48 dp', (tester) async {
      final _SheetHost host = await _openSheet(tester, textScale: 2.0);
      expect(tester.takeException(), isNull, reason: host.why('no overflow'));
      for (final String id in kIds) {
        expect(
          tester.getSize(find.byKey(chipKey(id))).height,
          greaterThanOrEqualTo(48.0),
          reason: host.why('chip $id at 2x text'),
        );
      }
    });
  });

  // -------------------------------------------------------------------
  // Item 8, sheet half.
  // -------------------------------------------------------------------
  group('8. Arabic sheet', () {
    testWidgets('chips, title and switch label are Arabic; Directionality is '
        'rtl', (tester) async {
      final _SheetHost host = await _openSheet(
        tester,
        locale: const Locale('ar'),
      );
      expect(chipIds(tester), kIds, reason: host.why('same order in ar'));
      for (final String id in kIds) {
        expect(
          find.descendant(
            of: find.byKey(chipKey(id)),
            matching: find.text(lineOf(id, ar: true)),
          ),
          findsOneWidget,
          reason: host.why('chip $id reads "${lineOf(id, ar: true)}"'),
        );
      }
      expect(
        find.descendant(
          of: find.byKey(kSheetKey),
          matching: find.text('رسايل سريعة'),
        ),
        findsOneWidget,
        reason: host.why('Arabic title'),
      );
      expect(
        find.descendant(
          of: find.byKey(kSheetKey),
          matching: find.text('خبّي رسايل الباقين'),
        ),
        findsOneWidget,
        reason: host.why('Arabic switch label'),
      );
      expect(
        Directionality.of(tester.element(find.byKey(kSheetKey))),
        TextDirection.rtl,
        reason: host.why('the sheet sits under an rtl Directionality'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English is ltr and the chip order runs the other way in '
        'Arabic on one row', (tester) async {
      // The Arabic pair ("مرحبا يا جماعة" and "بالتوفيق", 22 glyphs) is wider
      // than the 320 dp wrap of a 360 dp phone under the test font (Ahem, 1 em
      // per glyph), so both locales run on an 800 dp surface (_kRowWidth):
      // 22 glyphs at under 20 dp each plus two chips of padding is well
      // inside it, and the 800 dp is not tuned to any one chip padding.
      final _SheetHost en = await _openSheet(tester, width: _kRowWidth);
      expect(
        Directionality.of(tester.element(find.byKey(kSheetKey))),
        TextDirection.ltr,
        reason: en.why('en is ltr'),
      );
      final Rect enFirst = tester.getRect(find.byKey(chipKey('hi')));
      final Rect enSecond = tester.getRect(find.byKey(chipKey('good_luck')));
      expect(
        _sameRow(enFirst, enSecond),
        isTrue,
        reason: en.why(
          'fixture: the first two chips share a row at ${_kRowWidth.toInt()} wide',
        ),
      );
      expect(
        enFirst.left,
        lessThan(enSecond.left),
        reason: en.why('en: the first chip is left of the second'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      final _SheetHost ar = await _openSheet(
        tester,
        locale: const Locale('ar'),
        width: _kRowWidth,
      );
      final Rect arFirst = tester.getRect(find.byKey(chipKey('hi')));
      final Rect arSecond = tester.getRect(find.byKey(chipKey('good_luck')));
      expect(
        _sameRow(arFirst, arSecond),
        isTrue,
        reason: ar.why(
          'fixture: the first two chips share a row in ar at ${_kRowWidth.toInt()} wide',
        ),
      );
      expect(
        arFirst.right,
        greaterThan(arSecond.right),
        reason: ar.why('ar: the sheet is mirrored, first chip on the right'),
      );
    });

    testWidgets('a chip tap in Arabic calls onPick with the id, not the text', (
      tester,
    ) async {
      final _SheetHost host = await _openSheet(
        tester,
        locale: const Locale('ar'),
      );
      await _tapChip(tester, host, 'no_way');
      expect(host.picks, <String>[
        'no_way',
      ], reason: host.why('id on the wire'));
    });
  });

  // -------------------------------------------------------------------
  // Item 3: the game screen's chat button.
  // -------------------------------------------------------------------
  group('3. game screen button', () {
    Future<Scn> game(
      WidgetTester tester,
      String name, {
      String state = 'PLAYING',
      bool seated = true,
      int turnSeat = 0,
      Locale locale = const Locale('en'),
    }) async {
      phoneSurface(tester);
      final bool playing = state == 'PLAYING';
      final RollTrayDrive drive = await connectPlaying(
        tester,
        turn: playing ? awaitRollTurn(turnSeat) : null,
        seats: pairSeats(mySeat: 0),
        state: state,
        winner: state == 'FINISHED' ? 0 : null,
        sendSeatAssigned: seated,
      );
      await mountGame(tester, drive, locale: locale);
      return Scn(name, tester, drive);
    }

    Finder button() => find.byKey(kChatButtonKey);

    Future<void> openSheet(Scn s) async {
      s.steps.add('tap game-chat-button');
      await s.tester.tap(button());
      await s.tester.pump();
      await s.pump(const Duration(milliseconds: 400));
    }

    /// The Icon's drawn opacity: every Opacity / FadeTransition above it
    /// times its own colour alpha.
    double drawn(WidgetTester tester) {
      final Finder icon = find.descendant(
        of: button(),
        matching: find.byIcon(Icons.chat_bubble_outline_rounded),
      );
      expect(icon, findsOneWidget, reason: 'the chat icon is in the button');
      final Element element = tester.element(icon);
      final Icon widget = element.widget as Icon;
      final IconThemeData theme = IconTheme.of(element);
      double alpha = (widget.color ?? theme.color)?.a ?? 1.0;
      alpha *= theme.opacity ?? 1.0;
      element.visitAncestorElements((Element e) {
        if (e is RenderObjectElement) {
          final RenderObject r = e.renderObject;
          if (r is RenderOpacity) {
            alpha *= r.opacity;
          } else if (r is RenderAnimatedOpacity) {
            alpha *= r.opacity.value;
          }
        }
        return true;
      });
      return alpha;
    }

    for (final int turnSeat in const <int>[0, 2]) {
      testWidgets(
        'present while PLAYING and seated, whether or not it is my turn '
        '(turn seat $turnSeat)',
        (tester) async {
          final Scn s = await game(
            tester,
            'D5.1 present turn=$turnSeat',
            turnSeat: turnSeat,
          );
          try {
            expect(
              button(),
              findsOneWidget,
              reason: s.why('game-chat-button while PLAYING and seated'),
            );
            final Size size = tester.getSize(button());
            expect(
              size.width,
              greaterThanOrEqualTo(48.0),
              reason: s.why('48 wide'),
            );
            expect(
              size.height,
              greaterThanOrEqualTo(48.0),
              reason: s.why('48 tall'),
            );
            expect(
              find.descendant(
                of: button(),
                matching: find.byIcon(Icons.chat_bubble_outline_rounded),
              ),
              findsOneWidget,
              reason: s.why('icon chat_bubble_outline_rounded'),
            );
            expect(
              find.byTooltip('Quick messages'),
              findsOneWidget,
              reason: s.why('tooltip chatButtonTooltip'),
            );
          } finally {
            await releaseGame(tester, s.drive);
          }
        },
      );
    }

    testWidgets(
      'sits at the end of the header, one gap before the sound toggle '
      'button, mirrored in Arabic',
      (tester) async {
        for (final Locale locale in const <Locale>[
          Locale('en'),
          Locale('ar'),
        ]) {
          final Scn s = await game(
            tester,
            'D5.1 place ${locale.languageCode}',
            locale: locale,
          );
          try {
            final Rect chat = tester.getRect(button());
            final Rect sound = tester.getRect(find.byKey(kSoundToggleKey));
            expect(
              (chat.center.dy - sound.center.dy).abs(),
              lessThan(1.0),
              reason: s.why('same header row'),
            );
            if (locale.languageCode == 'en') {
              expect(
                chat.right,
                closeTo(sound.left - kSpace1, 1.0),
                reason: s.why(
                  'chat ends kSpace1 before the sound toggle: $chat $sound',
                ),
              );
            } else {
              expect(
                chat.left,
                closeTo(sound.right + kSpace1, 1.0),
                reason: s.why('mirrored: $chat $sound'),
              );
            }
          } finally {
            await releaseGame(tester, s.drive);
          }
        }
      },
    );

    testWidgets('Arabic tooltip', (tester) async {
      final Scn s = await game(
        tester,
        'D5.1 tooltip ar',
        locale: const Locale('ar'),
      );
      try {
        expect(
          find.byTooltip('رسايل سريعة'),
          findsOneWidget,
          reason: s.why('Arabic chatButtonTooltip'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('absent in the LOBBY', (tester) async {
      final Scn s = await game(tester, 'D5.1 lobby', state: 'LOBBY');
      try {
        expect(
          button(),
          findsNothing,
          reason: s.why('no chat button in LOBBY'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('absent in FINISHED', (tester) async {
      final Scn s = await game(tester, 'D5.1 finished', state: 'FINISHED');
      try {
        expect(
          button(),
          findsNothing,
          reason: s.why('no chat button in FINISHED'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('absent when this device holds no seat', (tester) async {
      final Scn s = await game(tester, 'D5.1 no seat', seated: false);
      try {
        expect(
          s.drive.controller.seat,
          isNull,
          reason: s.why('fixture: no seat_assigned was sent'),
        );
        expect(
          button(),
          findsNothing,
          reason: s.why('no chat button without a seat'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('goes when the game ends under it', (tester) async {
      final Scn s = await game(tester, 'D5.1 game_over');
      try {
        expect(button(), findsOneWidget, reason: s.why('fixture: present'));
        await s.push('game_over', gameOverFrame(2));
        await s.pump(const Duration(milliseconds: 500));
        expect(button(), findsNothing, reason: s.why('gone after game_over'));
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('absent while the stale table shows after the socket drops', (
      tester,
    ) async {
      final Scn s = await game(tester, 'D5.1 dropped');
      try {
        expect(button(), findsOneWidget, reason: s.why('fixture: present'));
        s.steps.add('far side closes');
        s.drive.transport.endFromFarSide();
        await tester.pump();
        await s.pump(const Duration(milliseconds: 200));
        expect(
          s.drive.controller.phase,
          isNot(RoomPhase.connected),
          reason: s.why('fixture: the controller noticed the drop'),
        );
        expect(
          button(),
          findsNothing,
          reason: s.why('no chat button while stale'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('a tap opens the sheet; a pick sends one emote frame with '
        '{"emote": id}', (tester) async {
      final Scn s = await game(tester, 'D5.3 send');
      try {
        final int before = s.drive.transport.sentRaw.length;
        await openSheet(s);
        expect(
          find.byKey(kSheetKey),
          findsOneWidget,
          reason: s.why('sheet opens'),
        );
        s.steps.add('tap chip oops');
        await tester.tap(find.byKey(chipKey('oops')));
        await tester.pump();
        await s.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(kSheetKey),
          findsNothing,
          reason: s.why('sheet closed'),
        );
        final List<Map<String, Object?>> sent = emotesSince(
          s.drive.transport,
          before,
        );
        expect(
          sent,
          hasLength(1),
          reason: s.why('exactly one emote frame sent'),
        );
        expect(sent.single['t'], 'emote');
        expect(sent.single['d'], <String, Object?>{
          'emote': 'oops',
        }, reason: s.why('d is {"emote": "oops"}'));
        expect(
          sent.single['id'],
          isA<String>(),
          reason: s.why('request carries an id'),
        );
        expect(sentTypesSince(s.drive.transport, before), <String>[
          'emote',
        ], reason: s.why('nothing else went out'));
        expect(
          find.byKey(const Key('end-card-chat-0')),
          findsNothing,
          reason: s.why(
            'no optimistic line (end-card-chat-0) before the server copy',
          ),
        );
        expect(
          find.byKey(const Key('end-card-chat-lines')),
          findsNothing,
          reason: s.why('and no header line layer at all before the copy'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('after the server copy the button cools for 3000 ms at 38 % '
        'and then opens the sheet again', (tester) async {
      final Scn s = await game(tester, 'D5.1 cooling');
      try {
        final double ready = drawn(tester);
        expect(ready, greaterThan(0.0), reason: s.why('fixture: icon visible'));
        final int before = s.drive.transport.sentRaw.length;
        await openSheet(s);
        await tester.tap(find.byKey(chipKey('lucky')));
        await tester.pump();
        await s.pump(const Duration(milliseconds: 400));
        final String id = requestIdOf(
          s.drive.transport.sentRaw
              .skip(before)
              .singleWhere((String t) => frameType(t) == 'emote'),
        );
        await s.pushEmote(0, 'lucky', re: id);
        final int cuesBefore = s.count(FeedbackCue.invalidTap);

        // The copy is the zero of the 3000 ms.
        await s.pump(const Duration(milliseconds: 600));
        expect(
          drawn(tester) / ready,
          closeTo(0.38, 0.03),
          reason: s.why('cooling icon is drawn at 38 %'),
        );
        s.steps.add('tap while cooling (600 ms)');
        await tester.tap(button());
        await tester.pump();
        await s.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(kSheetKey),
          findsNothing,
          reason: s.why('a cooling tap opens nothing'),
        );
        expect(
          s.count(FeedbackCue.invalidTap),
          cuesBefore + 1,
          reason: s.why('a cooling tap plays invalidTap once'),
        );

        // 1000 ms in. Pump up to 2900 ms.
        await s.pump(const Duration(milliseconds: 1900));
        expect(
          drawn(tester) / ready,
          closeTo(0.38, 0.03),
          reason: s.why('still cooling at 2900 ms'),
        );
        s.steps.add('tap while cooling (2900 ms)');
        await tester.tap(button());
        await tester.pump();
        expect(
          find.byKey(kSheetKey),
          findsNothing,
          reason: s.why('2900 ms: still cooling'),
        );
        expect(
          s.count(FeedbackCue.invalidTap),
          cuesBefore + 2,
          reason: s.why('second cooling tap, second invalidTap'),
        );

        await s.pump(const Duration(milliseconds: 200));
        expect(
          drawn(tester) / ready,
          closeTo(1.0, 0.03),
          reason: s.why('3100 ms: the icon is back to full'),
        );
        await openSheet(s);
        expect(
          find.byKey(kSheetKey),
          findsOneWidget,
          reason: s.why('after 3000 ms the button opens the sheet again'),
        );
        expect(
          s.count(FeedbackCue.invalidTap),
          cuesBefore + 2,
          reason: s.why('an open tap plays no invalidTap'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('a refused send (error reply) shows no line, plays '
        'invalidTap exactly once and rests the button 3000 ms', (tester) async {
      final Scn s = await game(tester, 'D5.3 refused');
      try {
        final double ready = drawn(tester);
        final int before = s.drive.transport.sentRaw.length;
        final int cues = s.drive.feedback.recorded.length;
        final int taps = s.count(FeedbackCue.invalidTap);
        await openSheet(s);
        await tester.tap(find.byKey(chipKey('revenge')));
        await tester.pump();
        await s.pump(const Duration(milliseconds: 400));
        final String id = requestIdOf(
          s.drive.transport.sentRaw
              .skip(before)
              .singleWhere((String t) => frameType(t) == 'emote'),
        );
        s.steps.add('error RATE_LIMITED re=$id');
        await pushRaw(
          tester,
          s.drive,
          errorReplyFrame(re: id, code: 'RATE_LIMITED'),
        );
        await s.pump(const Duration(milliseconds: 100));
        final int refusedAt = s.clockMs - 100;
        expect(
          s.count(FeedbackCue.invalidTap),
          taps + 1,
          reason: s.why('C-520 D1: the refusal plays invalidTap exactly once'),
        );
        expect(
          s.drive.feedback.recorded.length,
          cues + 1,
          reason: s.why('and nothing else is played for a refused send'),
        );
        expect(
          find.byWidgetPredicate((Widget w) {
            final Key? k = w.key;
            return k is ValueKey<String> &&
                k.value.startsWith('end-card-chat-');
          }),
          findsNothing,
          reason: s.why(
            'no line (end-card-chat-0, any seat, or the layer) for a '
            'refused send',
          ),
        );
        expect(
          s.drive.controller.phase,
          RoomPhase.connected,
          reason: s.why('a refused emote leaves the screen connected'),
        );
        expect(button(), findsOneWidget, reason: s.why('button still there'));
        expect(
          drawn(tester) / ready,
          closeTo(0.38, 0.03),
          reason: s.why(
            'C-520 D1: the refusal rests the button, drawn at 38 %',
          ),
        );
        await s.pump(Duration(milliseconds: refusedAt + 2900 - s.clockMs));
        expect(
          drawn(tester) / ready,
          closeTo(0.38, 0.03),
          reason: s.why('still resting 2900 ms after the refusal'),
        );
        await s.pump(Duration(milliseconds: refusedAt + 3100 - s.clockMs));
        expect(
          drawn(tester) / ready,
          closeTo(1.0, 0.03),
          reason: s.why('the icon is drawn at full opacity after 3000 ms'),
        );
        await openSheet(s);
        expect(
          find.byKey(kSheetKey),
          findsOneWidget,
          reason: s.why('the rest is 3000 ms and no longer: the sheet opens'),
        );
        expect(
          s.count(FeedbackCue.invalidTap),
          taps + 1,
          reason: s.why('and the open tap plays no further invalidTap'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('someone else\'s emote does not start my cooling', (
      tester,
    ) async {
      final Scn s = await game(tester, 'D5.1 others do not cool me');
      try {
        await s.pushEmote(2, 'hi');
        await s.pump(const Duration(milliseconds: 100));
        final int cues = s.count(FeedbackCue.invalidTap);
        await openSheet(s);
        expect(
          find.byKey(kSheetKey),
          findsOneWidget,
          reason: s.why('an emote from seat 2 leaves my button ready'),
        );
        expect(
          s.count(FeedbackCue.invalidTap),
          cues,
          reason: s.why('no invalidTap'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });

    testWidgets('my own line appears from the server copy and says the '
        'line', (tester) async {
      final Scn s = await game(tester, 'D5.3 own line');
      try {
        final int before = s.drive.transport.sentRaw.length;
        await openSheet(s);
        await tester.tap(find.byKey(chipKey('oops')));
        await tester.pump();
        await s.pump(const Duration(milliseconds: 400));
        final String id = requestIdOf(
          s.drive.transport.sentRaw
              .skip(before)
              .singleWhere((String t) => frameType(t) == 'emote'),
        );
        await s.pushEmote(0, 'oops', re: id);
        await s.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const Key('end-card-chat-0')),
          findsOneWidget,
          reason: s.why(
            'my line (end-card-chat-0) shows once the server copy lands',
          ),
        );
        expect(
          textUnder(tester, find.byKey(const Key('end-card-chat-0'))),
          contains('Oops'),
          reason: s.why('my line says "Oops" once the server copy lands'),
        );
      } finally {
        await releaseGame(tester, s.drive);
      }
    });
  });
}
