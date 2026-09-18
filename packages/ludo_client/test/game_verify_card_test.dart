// Finished-game verify card: after game_over the controller must keep
// verify_url, the finished board must offer a 48dp control that opens that
// URL, and it must show up to the last three roll faces with their k. Copy
// is verifiable wording, never casino phrasing. New table and Leave stay on
// the finished board; a game_over frame without verify_url is still rejected.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real controller over FakeTransport. History is filled
// from rolled frames before the screen is mounted, so a ring buffer has to
// live on the snapshot or the controller, not in ephemeral widget state.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:path/path.dart' as p;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://game-verify-card-test.invalid/ws';
const String _verifyUrl = 'https://provefair.app/v/d1t02-verify-card';
const Key _verifyKey = Key('game-screen-verify-button');
const Key _historyKey = Key('game-screen-roll-history');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _leaveKey = Key('game-screen-appbar-leave');

const List<(int k, int face)> _fourRolls = <(int, int)>[
  (101, 6),
  (108, 2),
  (109, 4),
  (110, 5),
];

const List<String> _urlLauncherChannels = <String>[
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/url_launcher_macos',
  'plugins.flutter.io/url_launcher_linux',
  'plugins.flutter.io/url_launcher_windows',
  'plugins.flutter.io/url_launcher_web',
  'plugins.flutter.io/url_launcher_android',
  'plugins.flutter.io/url_launcher_ios',
];

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'verify-card-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  int? winner,
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
  'game_id': '7f3a9c1e5b2d4068',
  'client_seeds': '0:sam-seed|1:bob-seed',
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ],
  'turn': turn,
  'winner': winner,
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

Future<void> _flush(WidgetTester? tester) async {
  if (tester != null) {
    await tester.pump();
    await tester.pump();
  } else {
    await pumpEventQueue();
  }
}

Future<(RoomController, FakeTransport)> _connectPlaying([
  WidgetTester? tester,
]) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  if (tester != null) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  } else {
    await pumpEventQueue();
  }
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
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

class _Script {
  _Script(this.transport, this.tester, {this.seq = 1});

  final FakeTransport transport;
  final WidgetTester? tester;
  int seq;

  Future<void> rolled({required int k, required int value}) async {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': value,
          'legal': <int>[0],
          'deadline_ms': 45000,
          'k': k,
          'reveal': 'c' * 64,
          'seq': seq,
        },
      ),
    );
    await _flush(tester);
  }

  Future<void> gameOver({
    required String verifyUrl,
    int winner = 0,
    bool includeVerifyUrl = true,
    Object? verifyUrlOverride,
  }) async {
    seq += 1;
    final Map<String, Object?> data = <String, Object?>{
      'winner': winner,
      'seq': seq,
    };
    if (includeVerifyUrl) {
      data['verify_url'] = verifyUrlOverride ?? verifyUrl;
    }
    transport.pushText(_frame(type: 'game_over', data: data));
    await _flush(tester);
  }
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
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

Future<void> _mount(WidgetTester tester, RoomController controller) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();
}

Object? _readDynamic(Object target, String getter) {
  try {
    switch (getter) {
      case 'verifyUrl':
        // ignore: avoid_dynamic_calls
        return (target as dynamic).verifyUrl;
      case 'verify_url':
        // ignore: avoid_dynamic_calls
        return (target as dynamic).verify_url;
      default:
        return null;
    }
  } on NoSuchMethodError {
    return null;
  } catch (_) {
    return null;
  }
}

String? _urlString(Object? value) {
  if (value is String && value.trim().isNotEmpty) {
    return value;
  }
  if (value is Uri) {
    return value.toString();
  }
  return null;
}

String? _retainedVerifyUrl(RoomController controller) {
  final RoomSnapshot? room = controller.room;
  for (final Object? host in <Object?>[room, controller]) {
    if (host == null) {
      continue;
    }
    for (final String getter in <String>['verifyUrl', 'verify_url']) {
      final String? url = _urlString(_readDynamic(host, getter));
      if (url != null) {
        return url;
      }
    }
  }
  return null;
}

void _writeBlob(StringBuffer out, String? value) {
  if (value != null && value.trim().isNotEmpty) {
    out.writeln(value);
  }
}

void _walkSemantics(SemanticsNode node, StringBuffer out) {
  _writeBlob(out, node.label);
  _writeBlob(out, node.value);
  _writeBlob(out, node.hint);
  _writeBlob(out, node.tooltip);
  node.visitChildren((SemanticsNode child) {
    _walkSemantics(child, out);
    return true;
  });
}

String _blobUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  final Finder descendants = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget _) => true),
  );
  for (final Element element in <Element>[
    tester.element(root),
    ...descendants.evaluate(),
  ]) {
    final Widget widget = element.widget;
    if (widget is Text) {
      _writeBlob(out, widget.data);
      _writeBlob(out, widget.textSpan?.toPlainText());
    } else if (widget is RichText) {
      _writeBlob(out, widget.text.toPlainText());
    } else if (widget is Semantics) {
      _writeBlob(out, widget.properties.label);
      _writeBlob(out, widget.properties.value);
      _writeBlob(out, widget.properties.hint);
      _writeBlob(out, widget.properties.tooltip);
    } else if (widget is Tooltip) {
      _writeBlob(out, widget.message);
    }
  }
  try {
    _walkSemantics(tester.getSemantics(root), out);
  } catch (_) {
    // No semantics node; text descendants above still count.
  }
  return out.toString();
}

bool _containsUrl(Object? value, String url) {
  if (value is String) {
    return value.contains(url);
  }
  if (value is Map) {
    return value.values.any((Object? item) => _containsUrl(item, url));
  }
  if (value is Iterable) {
    return value.any((Object? item) => _containsUrl(item, url));
  }
  return false;
}

List<MethodCall> _listenUrlLaunches(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> handler(MethodCall call) async {
    calls.add(call);
    final String method = call.method.toLowerCase();
    if (method.contains('canlaunch')) {
      return true;
    }
    return true;
  }

  for (final String name in _urlLauncherChannels) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return calls;
}

bool _launched(List<MethodCall> calls, String url) {
  return calls.any(
    (MethodCall call) =>
        _containsUrl(call.arguments, url) || call.method.contains(url),
  );
}

bool _pairNearby(String blob, int k, int face) {
  final String kText = RegExp.escape('$k');
  final String faceText = RegExp.escape('$face');
  final RegExp either = RegExp(
    '(?:$kText\\D{0,48}$faceText)|(?:$faceText\\D{0,48}$kText)',
  );
  return either.hasMatch(blob);
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

Iterable<String> _arbMessageValues(File file) {
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('${file.path} must decode as a JSON object');
  }
  final List<String> values = <String>[];
  for (final MapEntry<String, Object?> entry in decoded.entries) {
    if (entry.key.startsWith('@')) {
      continue;
    }
    if (entry.value is String) {
      values.add(entry.value! as String);
    }
  }
  return values;
}

const List<String> _forbiddenPhrases = <String>[
  'provably fair',
  'absolute randomness',
  'absolutely random',
];

void _assertNoForbiddenPhrases(String text, {required String where}) {
  final String lower = text.toLowerCase();
  for (final String phrase in _forbiddenPhrases) {
    expect(
      lower.contains(phrase),
      isFalse,
      reason: '$where must not contain "$phrase"; got: $text',
    );
  }
}

void _assertArbHasNoForbiddenPhrases() {
  final Directory root = _findPackageRoot();
  for (final String name in <String>['app_en.arb', 'app_ar.arb']) {
    final File file = File(p.join(root.path, 'lib', 'l10n', name));
    expect(file.existsSync(), isTrue, reason: '${file.path} must exist');
    for (final String value in _arbMessageValues(file)) {
      _assertNoForbiddenPhrases(value, where: '${file.path} message "$value"');
    }
  }
}

void main() {
  test('after game_over the controller retains verify_url', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connectPlaying();
    final _Script script = _Script(transport, null);
    await script.gameOver(verifyUrl: _verifyUrl);

    expect(
      controller.room!.state,
      RoomState.finished,
      reason: 'fixture is broken: a well-formed game_over must finish the room',
    );
    expect(
      _retainedVerifyUrl(controller),
      _verifyUrl,
      reason:
          'game_over carried verify_url $_verifyUrl; RoomSnapshot or '
          'RoomController must still expose that URL after the frame is '
          'reduced, not drop it',
    );
  });

  testWidgets(
    'game-screen-verify-button is at least 48dp and opens verify_url',
    (tester) async {
      final (RoomController controller, FakeTransport transport) =
          await _connectPlaying(tester);
      final _Script script = _Script(transport, tester);
      await script.gameOver(verifyUrl: _verifyUrl);
      expect(controller.room!.state, RoomState.finished);

      await _mount(tester, controller);

      final Finder verify = find.byKey(_verifyKey);
      expect(
        verify,
        findsOneWidget,
        reason:
            'a finished game must show key game-screen-verify-button so '
            'the player can open verify_url',
      );
      final Size size = tester.getSize(verify);
      expect(
        size.width,
        greaterThanOrEqualTo(48.0),
        reason:
            'game-screen-verify-button width must be at least 48, was '
            '${size.width}',
      );
      expect(
        size.height,
        greaterThanOrEqualTo(48.0),
        reason:
            'game-screen-verify-button height must be at least 48, was '
            '${size.height}',
      );

      final List<MethodCall> launches = _listenUrlLaunches(tester);
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        _launched(launches, _verifyUrl),
        isTrue,
        reason:
            'tapping game-screen-verify-button must open $_verifyUrl '
            'externally (url_launcher channel call carrying that URL); '
            'calls were $launches',
      );
    },
  );

  testWidgets(
    'finished game shows last 3 roll faces with k in game-screen-roll-history',
    (tester) async {
      final (RoomController controller, FakeTransport transport) =
          await _connectPlaying(tester);
      final _Script script = _Script(transport, tester);
      for (final (int k, int face) in _fourRolls) {
        await script.rolled(k: k, value: face);
      }
      await script.gameOver(verifyUrl: _verifyUrl);
      expect(controller.room!.state, RoomState.finished);

      await _mount(tester, controller);

      final Finder history = find.byKey(_historyKey);
      expect(
        history,
        findsOneWidget,
        reason:
            'a finished game must show key game-screen-roll-history with '
            'up to the last three roll faces and their k',
      );

      final String blob = _blobUnder(tester, history);
      expect(
        blob.trim().isNotEmpty,
        isTrue,
        reason:
            'game-screen-roll-history must expose the last faces and k as '
            'text or semantics, not paint-only; blob was "$blob"',
      );

      final int droppedK = _fourRolls.first.$1;
      final List<(int k, int face)> kept = _fourRolls.sublist(1);
      expect(
        blob.contains('$droppedK'),
        isFalse,
        reason:
            'history must keep at most the last three rolls, so k='
            '$droppedK (the oldest of four) must not appear; blob was '
            '"$blob"',
      );
      for (final (int k, int face) in kept) {
        expect(
          blob.contains('$k'),
          isTrue,
          reason:
              'history must show k=$k from the last three rolls; blob was '
              '"$blob"',
        );
        expect(
          _pairNearby(blob, k, face),
          isTrue,
          reason:
              'history must show face $face with k=$k (within 48 characters); '
              'blob was "$blob"',
        );
      }
    },
  );

  testWidgets(
    'finished game verify copy is verifiable wording, not casino phrasing',
    (tester) async {
      final (RoomController controller, FakeTransport transport) =
          await _connectPlaying(tester);
      final _Script script = _Script(transport, tester);
      await script.gameOver(verifyUrl: _verifyUrl);
      await _mount(tester, controller);

      expect(
        find.byKey(_verifyKey),
        findsOneWidget,
        reason:
            'verify copy cannot be checked until game-screen-verify-button '
            'is on the finished board',
      );

      final String buttonBlob = _blobUnder(tester, find.byKey(_verifyKey));
      final String screenBlob = _blobUnder(tester, find.byType(GameScreen));
      expect(
        buttonBlob.toLowerCase().contains('verif') ||
            screenBlob.toLowerCase().contains('verif'),
        isTrue,
        reason:
            'finished-game copy must use verifiable wording (a visible or '
            'semantic substring "verif", e.g. Verify / verifiable); button '
            'blob "$buttonBlob"; screen blob "$screenBlob"',
      );
      _assertNoForbiddenPhrases(
        buttonBlob,
        where: 'game-screen-verify-button copy',
      );
      _assertNoForbiddenPhrases(screenBlob, where: 'finished GameScreen copy');
      _assertArbHasNoForbiddenPhrases();
    },
  );

  testWidgets('finished board still shows New table and Leave', (tester) async {
    final (RoomController controller, FakeTransport transport) =
        await _connectPlaying(tester);
    final _Script script = _Script(transport, tester);
    await script.gameOver(verifyUrl: _verifyUrl);
    await _mount(tester, controller);

    expect(
      controller.room!.state,
      RoomState.finished,
      reason: 'fixture is broken',
    );
    expect(
      find.byKey(_newRoomKey),
      findsOneWidget,
      reason:
          'game-screen-new-room-button (New table) must still be present '
          'on the finished board',
    );
    expect(
      find.byKey(_leaveKey),
      findsOneWidget,
      reason:
          'game-screen-appbar-leave (Leave) must still be present on the '
          'finished board',
    );
    expect(
      tester.widget(find.byKey(_newRoomKey)),
      isNot(same(tester.widget(find.byKey(_leaveKey)))),
      reason:
          'New table and Leave must be different widgets, not one control '
          'with two keys',
    );
  });

  test('game_over still requires verify_url on the wire', () async {
    final (RoomController controller, FakeTransport transport) =
        await _connectPlaying();
    final RoomSnapshot playing = controller.room!;
    expect(playing.state, RoomState.playing, reason: 'fixture is broken');
    final int seqBefore = playing.seq;

    final _Script missing = _Script(transport, null, seq: seqBefore);
    await missing.gameOver(verifyUrl: _verifyUrl, includeVerifyUrl: false);
    expect(
      identical(controller.room, playing),
      isTrue,
      reason:
          'game_over missing verify_url must be malformed: room object '
          'unchanged, seq still $seqBefore',
    );
    expect(controller.room!.state, RoomState.playing);
    expect(controller.room!.seq, seqBefore);

    final _Script wrongType = _Script(transport, null, seq: seqBefore);
    await wrongType.gameOver(verifyUrl: _verifyUrl, verifyUrlOverride: 7);
    expect(
      identical(controller.room, playing),
      isTrue,
      reason:
          'game_over with verify_url of the wrong runtime type must be '
          'malformed: room object unchanged',
    );
    expect(controller.room!.state, RoomState.playing);
    expect(controller.room!.seq, seqBefore);

    final _Script valid = _Script(transport, null, seq: seqBefore);
    await valid.gameOver(verifyUrl: _verifyUrl);
    expect(controller.room!.state, RoomState.finished);
    expect(controller.room!.seq, seqBefore + 1);
    expect(
      identical(controller.room, playing),
      isFalse,
      reason: 'a well-formed game_over must replace the playing snapshot',
    );
  });
}
