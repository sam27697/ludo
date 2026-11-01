// Proof for contract C-523 (work/ludo/orders/C-523-home-plain-and-one-sound-
// switch.md), rule D6: the lobby stops explaining rules. A default room
// (capture bonus on) shows no rule chip and no house-rules line; a room an
// older client created with `capture_bonus: false` shows the chip with
// lobbyRuleCaptureBonusOff. Written from the contract text, against no
// implementation of it.
//
// The deleted strings (houseRulesLine, lobbyRuleCaptureBonusOn) are asserted
// as literals, in both locales, because their getters are gone once the
// contract lands; lobbyRuleCaptureBonusOff is kept and read from the
// localizations. The harness is copied by hand from
// lobby_seat_cards_test.dart (a real RoomController over a FakeTransport,
// test/net/fake_transport.dart, read-only here); nothing is imported across
// test files. "Painted" means the string of a RichText anywhere in the tree,
// Offstage subtrees included, with Icon skipped (its RichText holds a
// private-use glyph, not text).
//
// On origin/main 7501227 every default-room case here is red: the lobby
// always paints the house-rules line (lobby_screen.dart:799-801, key
// lobby-house-rules) and always builds the capture-bonus chip, with the "on"
// wording when the rule is on (lobby_screen.dart:788-794).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://lobby-rules-line-test.invalid/ws';

const Key _chipKey = Key('lobby-rule-capture-bonus-chip');
const Key _chipTextKey = Key('lobby-rule-capture-bonus');

/// The old values from the arb files on origin/main 7501227, per locale.
const Map<String, List<String>> _deletedStrings = <String, List<String>>{
  'en': <String>[
    'Two tokens on one square are safe from capture. A token reaching home '
        'earns another roll.',
    'Two tokens on one square are safe from capture',
    'earns another roll',
    'Capture bonus: on',
  ],
  'ar': <String>[
    'قطعتان على مربع واحد لا تُؤكلان. وصول قطعة إلى البيت يمنحك رمية أخرى.',
    'قطعتان على مربع واحد لا تُؤكلان',
    'يمنحك رمية أخرى',
    'مكافأة الأكل: مفعّلة',
  ],
};

/// Keys the contract removes or keeps only for a non-default room.
const List<String> _ruleKeysAbsentByDefault = <String>[
  'lobby-rule-capture-bonus-chip',
  'lobby-rule-capture-bonus',
  'lobby-house-rules',
  'lobby-rule-blocks',
  'lobby-rule-blocks-chip',
];

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'rules-line-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  required bool blocks,
  required bool captureBonus,
}) => <String, Object?>{
  'code': 'ABC234',
  'state': 'LOBBY',
  'host_seat': 0,
  'players': 4,
  'rules': <String, Object?>{
    'blocks': blocks,
    'capture_bonus': captureBonus,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    _seatJson(0, name: 'Host'),
    _seatJson(1, name: 'Guest'),
  ],
  'turn': null,
  'winner': null,
  'seq': 1,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

Widget _harness(Widget child, Locale locale) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mountLobby(
  WidgetTester tester, {
  required Locale locale,
  required bool host,
  required bool blocks,
  required bool captureBonus,
}) async {
  tester.view.physicalSize = const Size(390, 844);
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

  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: host ? LobbyAction.create : LobbyAction.join,
        code: host ? null : 'ABC234',
        playerName: host ? 'Host' : 'Guest',
        players: 4,
      ),
      locale,
    ),
  );
  await tester.pump();
  final String requestId = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': host ? 0 : 1,
        'seat_token': 'tok-${host ? 0 : 1}',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(blocks: blocks, captureBonus: captureBonus),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture is broken: the lobby must reach RoomPhase.connected; got '
        '${controller.phase}',
  );
  expect(
    controller.room!.rules.captureBonus,
    captureBonus,
    reason:
        'fixture is broken: the room must carry capture_bonus $captureBonus',
  );
}

List<String> _paintedStrings() {
  final List<String> out = <String>[];
  void visit(Element element) {
    final Widget widget = element.widget;
    if (widget is Icon) {
      return;
    }
    if (widget is RichText) {
      out.add(widget.text.toPlainText(includeSemanticsLabels: false));
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return out;
}

String _repro(String scenario, Locale locale, bool host) {
  return 'Reproduce: scenario "$scenario", locale ${locale.languageCode}, '
      '${host ? 'host' : 'guest'} seat, surface 390x844 at 1.0, flutter test '
      'test/lobby_rules_line_test.dart --plain-name "$scenario". No random '
      'input is involved.';
}

void _expectNoDeletedText(List<String> painted, Locale locale, String repro) {
  final List<String> found = <String>[];
  for (final String s in painted) {
    for (final String old in _deletedStrings[locale.languageCode]!) {
      if (s.contains(old)) {
        found.add('"$s" contains "$old"');
      }
    }
  }
  expect(
    found,
    isEmpty,
    reason:
        'expected the lobby to paint no house-rules line and no '
        '"Capture bonus: on" text (D6, D9); found $found. $repro',
  );
}

void main() {
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String lc = locale.languageCode;
    for (final bool host in const <bool>[true, false]) {
      final String who = host ? 'host' : 'guest';

      group('lobby rules, $lc, $who', () {
        for (final bool blocks in const <bool>[true, false]) {
          testWidgets('default room (capture bonus on, blocks '
              '${blocks ? 'on' : 'off on the wire'}): no rule chip, no '
              'house-rules line, no deleted text', (tester) async {
            final String name = 'default room blocks $blocks';
            final String repro = _repro(name, locale, host);
            await _mountLobby(
              tester,
              locale: locale,
              host: host,
              blocks: blocks,
              captureBonus: true,
            );

            for (final String key in _ruleKeysAbsentByDefault) {
              expect(
                find.byKey(Key(key), skipOffstage: false),
                findsNothing,
                reason:
                    'expected no widget keyed $key in a default room; found '
                    'one. $repro',
              );
            }
            final AppLocalizations loc = AppLocalizations.of(
              tester.element(find.byType(LobbyScreen)),
            );
            final List<String> painted = _paintedStrings();
            _expectNoDeletedText(painted, locale, repro);
            expect(
              painted.any(
                (String s) => s.contains(loc.lobbyRuleCaptureBonusOff),
              ),
              isFalse,
              reason:
                  'expected no "${loc.lobbyRuleCaptureBonusOff}" in a '
                  'default room; painted strings were $painted. $repro',
            );
          });
        }

        testWidgets('a room with capture_bonus false shows the off chip and '
            'only that', (tester) async {
          const String name = 'capture bonus off';
          final String repro = _repro(name, locale, host);
          await _mountLobby(
            tester,
            locale: locale,
            host: host,
            blocks: true,
            captureBonus: false,
          );
          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(LobbyScreen)),
          );

          final Finder chip = find.byKey(_chipKey);
          expect(
            chip,
            findsOneWidget,
            reason:
                'expected lobby-rule-capture-bonus-chip for a room whose '
                'rules differ from the defaults; found '
                '${chip.evaluate().length}. $repro',
          );
          final Finder text = find.descendant(
            of: chip,
            matching: find.byKey(_chipTextKey),
          );
          expect(
            text,
            findsOneWidget,
            reason: 'expected lobby-rule-capture-bonus inside the chip. $repro',
          );
          expect(
            find.descendant(
              of: chip,
              matching: find.text(loc.lobbyRuleCaptureBonusOff),
            ),
            findsOneWidget,
            reason:
                'expected the chip to read "${loc.lobbyRuleCaptureBonusOff}" '
                '(lobbyRuleCaptureBonusOff). $repro',
          );
          expect(
            find.byKey(const Key('lobby-house-rules'), skipOffstage: false),
            findsNothing,
            reason: 'expected no lobby-house-rules even with the chip. $repro',
          );
          expect(
            find.byKey(
              const Key('lobby-rule-blocks-chip'),
              skipOffstage: false,
            ),
            findsNothing,
            reason: 'expected no blocks chip. $repro',
          );
          _expectNoDeletedText(_paintedStrings(), locale, repro);
        });
      });
    }
  }

  // The arb literal for the kept string, so a reworded "off" cannot slip by
  // while the chip case above reads it back from the same source.
  testWidgets('lobbyRuleCaptureBonusOff keeps its wording in both locales', (
    tester,
  ) async {
    const Map<String, String> expected = <String, String>{
      'en': 'Capture bonus: off',
      'ar': 'مكافأة الأكل: معطّلة',
    };
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      final AppLocalizations loc = await AppLocalizations.delegate.load(locale);
      expect(
        loc.lobbyRuleCaptureBonusOff,
        expected[locale.languageCode],
        reason:
            'D9 keeps lobbyRuleCaptureBonusOff unchanged; locale '
            '${locale.languageCode} reads "${loc.lobbyRuleCaptureBonusOff}". '
            'Reproduce: flutter test test/lobby_rules_line_test.dart '
            '--plain-name "keeps its wording".',
      );
    }
  });
}
