// Unique-legal Undo copy must come from AppLocalizations: the arb files
// declare the label in both shipped locales, game_screen.dart has no
// quoted Undo / Arabic-undo literals, and the game-automove-undo chip
// paints that arb string. The hold itself is the same unique-legal
// GameScreen path unique_legal_automove_test.dart already drives.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:path/path.dart' as p;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://auto-move-undo-l10n-test.invalid/ws';
const Key _rollKey = Key('game-screen-roll-button');
const Key _undoKey = Key('game-automove-undo');
const int _uniqueToken = 2;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'undo-l10n-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

Directory _findPackageRoot() {
  bool isLudoClient(Directory dir) {
    final File pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec
            .readAsStringSync()
            .split('\n')
            .any((String line) => line.trim() == 'name: ludo_client');
  }

  final Directory cwd = Directory.current;
  if (isLudoClient(cwd)) {
    return cwd;
  }

  final Directory nested = Directory(
    p.join(cwd.path, 'packages', 'ludo_client'),
  );
  if (isLudoClient(nested)) {
    return nested;
  }

  Directory walker = cwd;
  for (int i = 0; i < 8; i++) {
    final Directory parent = walker.parent;
    if (parent.path == walker.path) {
      break;
    }
    if (isLudoClient(parent)) {
      return parent;
    }
    walker = parent;
  }

  fail('could not locate the ludo_client package root from cwd ${cwd.path}');
}

String _stripLineComments(String source) {
  return source
      .split('\n')
      .map((String line) {
        final int idx = line.indexOf('//');
        return idx == -1 ? line : line.substring(0, idx);
      })
      .join('\n');
}

Map<String, String> _arbMessages(File arbFile) {
  expect(arbFile.existsSync(), isTrue, reason: '${arbFile.path} must exist');
  final Object? decoded = jsonDecode(arbFile.readAsStringSync());
  expect(
    decoded,
    isA<Map<String, dynamic>>(),
    reason: '${arbFile.path} must be a JSON object',
  );
  final Map<String, dynamic> map = decoded! as Map<String, dynamic>;
  final Map<String, String> messages = <String, String>{};
  for (final MapEntry<String, dynamic> entry in map.entries) {
    if (entry.key.startsWith('@')) {
      continue;
    }
    expect(
      entry.value,
      isA<String>(),
      reason:
          '${arbFile.path}: expected key "${entry.key}" to hold a string '
          'message, found ${entry.value.runtimeType}',
    );
    messages[entry.key] = entry.value as String;
  }
  return messages;
}

bool _isUndoLabelKey(String key, String enValue, String arValue) {
  if (key.toLowerCase().contains('undo')) {
    return true;
  }
  return enValue == 'Undo' && arValue == 'تراجع';
}

List<String> _undoLabelKeys(
  Map<String, String> enMessages,
  Map<String, String> arMessages,
) {
  final List<String> keys = <String>[];
  for (final String key in enMessages.keys) {
    final String? arValue = arMessages[key];
    if (arValue == null) {
      continue;
    }
    if (_isUndoLabelKey(key, enMessages[key]!, arValue)) {
      keys.add(key);
    }
  }
  return keys;
}

({
  Map<String, String> en,
  Map<String, String> ar,
  List<String> keys,
  File gameScreen,
  String gameScreenStripped,
})
_undoL10nFixture() {
  final Directory packageRoot = _findPackageRoot();
  final Map<String, String> en = _arbMessages(
    File(p.join(packageRoot.path, 'lib', 'l10n', 'app_en.arb')),
  );
  final Map<String, String> ar = _arbMessages(
    File(p.join(packageRoot.path, 'lib', 'l10n', 'app_ar.arb')),
  );
  final File gameScreen = File(
    p.join(packageRoot.path, 'lib', 'src', 'game_screen.dart'),
  );
  expect(
    gameScreen.existsSync(),
    isTrue,
    reason: '${gameScreen.path} must exist',
  );
  return (
    en: en,
    ar: ar,
    keys: _undoLabelKeys(en, ar),
    gameScreen: gameScreen,
    gameScreenStripped: _stripLineComments(gameScreen.readAsStringSync()),
  );
}

final RegExp _undoQuotedLiteral = RegExp("['\"]Undo['\"]|['\"]تراجع['\"]");

Future<(RoomController, FakeTransport)> _connectAwaitingRoll(
  WidgetTester tester,
) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

Widget _harness(Widget child, {required Locale locale}) {
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

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  required Locale locale,
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

Future<void> _rollUniqueLegal(
  WidgetTester tester,
  FakeTransport transport,
) async {
  await tester.tap(find.byKey(_rollKey));
  await tester.pump();
  final List<String> rollMessages = transport.sentRaw
      .where((String s) => _typeOf(s) == 'roll')
      .toList();
  expect(
    rollMessages,
    isNotEmpty,
    reason: 'fixture is broken: tapping Roll must send a roll',
  );
  transport.pushText(
    _frame(
      type: 'rolled',
      re: _idOf(rollMessages.last),
      data: <String, Object?>{
        'seat': 0,
        'value': 6,
        'legal': <int>[_uniqueToken],
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'b' * 64,
        'seq': 2,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

String _undoChipText(WidgetTester tester) {
  final Finder undo = find.byKey(_undoKey);
  expect(
    undo,
    findsOneWidget,
    reason:
        'a unique-legal roll must show game-automove-undo during the '
        '3s hold',
  );
  final Finder label = find.descendant(of: undo, matching: find.byType(Text));
  expect(
    label,
    findsOneWidget,
    reason: 'game-automove-undo must have one Text descendant',
  );
  final String? data = tester.widget<Text>(label).data;
  expect(
    data,
    isNotNull,
    reason: 'game-automove-undo Text.data must be the visible label',
  );
  return data!;
}

void main() {
  test('app_en.arb and app_ar.arb declare the unique-legal Undo label', () {
    final fixture = _undoL10nFixture();
    expect(
      fixture.keys,
      isNotEmpty,
      reason:
          'app_en.arb and app_ar.arb must share an Undo label key '
          '(name contains "undo", or values Undo / تراجع); found none',
    );
  });

  test('game_screen.dart has no quoted Undo or Arabic-undo literals', () {
    final fixture = _undoL10nFixture();
    final List<String> hits = <String>[];
    for (final Match match in _undoQuotedLiteral.allMatches(
      fixture.gameScreenStripped,
    )) {
      hits.add(match.group(0)!);
    }
    expect(
      hits,
      isEmpty,
      reason:
          'game_screen.dart must not contain quoted \'Undo\' or '
          '\'تراجع\' literals; found $hits. Source the chip from '
          'AppLocalizations instead',
    );
  });

  test('game_screen.dart reads the Undo label from AppLocalizations', () {
    final fixture = _undoL10nFixture();
    expect(
      fixture.keys,
      isNotEmpty,
      reason:
          'cannot check AppLocalizations usage until app_en.arb and '
          'app_ar.arb declare an Undo label key',
    );
    final List<String> missing = <String>[];
    for (final String key in fixture.keys) {
      if (!fixture.gameScreenStripped.contains('.$key')) {
        missing.add(key);
      }
    }
    expect(
      missing,
      isEmpty,
      reason:
          'game_screen.dart must reference AppLocalizations getters for '
          'Undo keys ${fixture.keys}; missing .\$getter for $missing',
    );
  });

  testWidgets('game-automove-undo paints the English arb Undo label', (
    tester,
  ) async {
    await _expectUndoChipMatchesArb(tester, const Locale('en'));
  });

  testWidgets('game-automove-undo paints the Arabic arb Undo label', (
    tester,
  ) async {
    await _expectUndoChipMatchesArb(tester, const Locale('ar'));
  });
}

Future<void> _expectUndoChipMatchesArb(
  WidgetTester tester,
  Locale locale,
) async {
  final (controller, transport) = await _connectAwaitingRoll(tester);
  await _mount(tester, controller, locale: locale);
  await _rollUniqueLegal(tester, transport);
  final String painted = _undoChipText(tester);
  await tester.tap(find.byKey(_undoKey));
  await tester.pump();

  final fixture = _undoL10nFixture();
  expect(
    fixture.keys,
    isNotEmpty,
    reason:
        'app_en.arb and app_ar.arb must declare an Undo label key; '
        'game-automove-undo currently paints "${painted}" under '
        '${locale.languageCode} from a non-arb source',
  );
  final String key = fixture.keys.first;
  final String expected = locale.languageCode == 'ar'
      ? fixture.ar[key]!
      : fixture.en[key]!;
  expect(
    painted,
    expected,
    reason:
        'game-automove-undo under ${locale.languageCode} must show arb '
        'key "$key" ($expected)',
  );
}
