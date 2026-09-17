// SizedBox gaps on die_mark, lobby, game, and home must use named kSpace*
// tokens (kSpace1=4 .. kSpace7=32) instead of bare width/height literals
// in {4, 8, 10, 12, 14, 16, 20, 24, 32}. Off-scale 10 maps to kSpace2 or
// kSpace3; off-scale 14 maps to kSpace3 or kSpace4.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';
import 'package:path/path.dart' as p;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

const List<String> _screenFiles = <String>[
  'die_mark.dart',
  'lobby_screen.dart',
  'game_screen.dart',
  'home_screen.dart',
];

const Set<int> _forbiddenBare = <int>{4, 8, 10, 12, 14, 16, 20, 24, 32};

final RegExp _bareGapLiteral = RegExp(
  r'(?<![A-Za-z0-9_])(4|8|10|12|14|16|20|24|32)(?:\.0+)?(?![A-Za-z0-9_.])',
);

final RegExp _kSpaceToken = RegExp(r'\bkSpace\d+\b');

final RegExp _sizedBoxCtor = RegExp(r'(?<![\w.])SizedBox\s*\(');

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

String _readLibSrc(String fileName) {
  final File file = File(
    p.join(_findPackageRoot().path, 'lib', 'src', fileName),
  );
  expect(file.existsSync(), isTrue, reason: '$fileName must exist');
  return file.readAsStringSync();
}

int _lineOf(String src, int offset) =>
    '\n'.allMatches(src.substring(0, offset)).length + 1;

String? _balancedArgs(String src, int openParen) {
  int depth = 0;
  for (int i = openParen; i < src.length; i++) {
    final String ch = src[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) {
        return src.substring(openParen + 1, i);
      }
    }
  }
  return null;
}

class _SizedBoxCall {
  const _SizedBoxCall({
    required this.fileLabel,
    required this.args,
    required this.line,
  });

  final String fileLabel;
  final String args;
  final int line;

  String get preview {
    final String compact = args.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String clipped = compact.length > 100
        ? '${compact.substring(0, 100)}…'
        : compact;
    return '$fileLabel:$line SizedBox($clipped)';
  }
}

List<_SizedBoxCall> _sizedBoxCalls(String src, String fileLabel) {
  final List<_SizedBoxCall> calls = <_SizedBoxCall>[];
  for (final Match match in _sizedBoxCtor.allMatches(src)) {
    final int open = src.indexOf('(', match.start);
    if (open < 0) {
      continue;
    }
    final String? args = _balancedArgs(src, open);
    if (args == null) {
      continue;
    }
    calls.add(
      _SizedBoxCall(
        fileLabel: fileLabel,
        args: args,
        line: _lineOf(src, match.start),
      ),
    );
  }
  return calls;
}

List<String> _topLevelArgs(String args) {
  final List<String> out = <String>[];
  final StringBuffer buf = StringBuffer();
  int depth = 0;
  for (int i = 0; i < args.length; i++) {
    final String ch = args[i];
    if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
    }
    if (ch == ',' && depth == 0) {
      final String piece = buf.toString().trim();
      if (piece.isNotEmpty) {
        out.add(piece);
      }
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  final String last = buf.toString().trim();
  if (last.isNotEmpty) {
    out.add(last);
  }
  return out;
}

Map<String, String> _namedArgs(String args) {
  final Map<String, String> named = <String, String>{};
  for (final String piece in _topLevelArgs(args)) {
    final int colon = piece.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    named[piece.substring(0, colon).trim()] = piece.substring(colon + 1).trim();
  }
  return named;
}

bool _isGapExpression(String expr) {
  return _kSpaceToken.hasMatch(expr) || _bareGapLiteral.hasMatch(expr);
}

Widget _homeApp() {
  return MaterialApp(
    theme: buildAppTheme(),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (BuildContext context) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: HomeScreen(
            onToggleLocale: () {},
            controllerFactory: () {
              return RoomController(
                serverUrl: Uri.parse('wss://sizedbox-spacing-test.invalid/ws'),
                connect: (Uri url) async {
                  throw StateError(
                    'sizedbox_spacing_tokens_test: connector must not open '
                    'a transport',
                  );
                },
              );
            },
          ),
        );
      },
    ),
  );
}

Future<void> _pumpHome(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_homeApp());
  await tester.pump();
}

void _expectGapIn(double gap, Set<double> allowed, String label) {
  expect(
    allowed.contains(gap),
    isTrue,
    reason: '$label must be one of ${allowed.join(' | ')}, found $gap',
  );
}

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'sz-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': null,
  'legal': null,
  'sixes': null,
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

Widget _localizations({required Widget home}) {
  return MaterialApp(
    locale: const Locale('en'),
    theme: buildAppTheme(),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

Future<RoomController> _pumpConnectingLobby(WidgetTester tester) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  await tester.pumpWidget(
    _localizations(
      home: LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: 'Sam',
        players: 4,
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester,
) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final List<Map<String, Object?>> seats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob'),
  ];
  final Map<String, Object?> turn = _turnJson(
    seat: 0,
    phase: 'await_roll',
    deadlineMs: 1000,
    k: 0,
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
      data: _roomJson(seats: seats, turn: turn),
    ),
  );
  await future;
  return (controller, transport);
}

void main() {
  test('die_mark/lobby/game/home SizedBox width/height use kSpace* with no '
      'bare 4/8/10/12/14/16/20/24/32', () {
    expect(kSpace1, 4);
    expect(kSpace2, 8);
    expect(kSpace3, 12);
    expect(kSpace4, 16);
    expect(kSpace5, 20);
    expect(kSpace6, 24);
    expect(kSpace7, 32);

    final List<String> bare = <String>[];
    final List<String> missingToken = <String>[];
    var totalCalls = 0;

    for (final String fileName in _screenFiles) {
      final List<_SizedBoxCall> calls = _sizedBoxCalls(
        _readLibSrc(fileName),
        fileName,
      );
      totalCalls += calls.length;
      for (final _SizedBoxCall call in calls) {
        final Map<String, String> named = _namedArgs(call.args);
        for (final String axis in <String>['width', 'height']) {
          final String? expr = named[axis];
          if (expr == null) {
            continue;
          }
          for (final Match match in _bareGapLiteral.allMatches(expr)) {
            bare.add('${match.group(0)} ($axis) in ${call.preview}');
          }
          if (_isGapExpression(expr) && !_kSpaceToken.hasMatch(expr)) {
            missingToken.add('$axis: $expr in ${call.preview}');
          }
        }
      }
    }

    expect(
      totalCalls,
      greaterThan(0),
      reason:
          'die_mark/lobby/game/home must still declare SizedBox gaps to '
          'scan',
    );
    expect(
      bare,
      isEmpty,
      reason:
          'SizedBox width/height in die_mark.dart, lobby_screen.dart, '
          'game_screen.dart, and home_screen.dart must not use bare '
          '${_forbiddenBare.join('/')}; found ${bare.length}: '
          '${bare.join('; ')}',
    );
    expect(
      missingToken,
      isEmpty,
      reason:
          'SizedBox width/height gaps on those screens must reference '
          'kSpace* (map 10→kSpace2 or kSpace3, 14→kSpace3 or kSpace4); '
          'arguments without a token: ${missingToken.join('; ')}',
    );
  });

  testWidgets('SeatPipStrip pip gap is kSpace2', (WidgetTester tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(alignment: Alignment.topCenter, child: SeatPipStrip()),
      ),
    );

    final Rect pip0 = tester.getRect(find.byKey(const Key('game-seat-pip-0')));
    final Rect pip1 = tester.getRect(find.byKey(const Key('game-seat-pip-1')));
    expect(
      pip1.left - pip0.right,
      kSpace2,
      reason:
          'SeatPipStrip gap between pip 0 and pip 1 must be kSpace2 '
          '($kSpace2), found ${pip1.left - pip0.right}',
    );
  });

  testWidgets('home tall title-to-tagline gap is kSpace2 or kSpace3', (
    WidgetTester tester,
  ) async {
    await _pumpHome(tester, size: const Size(390, 844));

    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(HomeScreen)),
    );
    final Rect title = tester.getRect(find.text(loc.appTitle));
    final Rect tagline = tester.getRect(find.text(loc.homeTagline));
    _expectGapIn(tagline.top - title.bottom, <double>{
      kSpace2,
      kSpace3,
    }, 'tall HomeScreen title-to-tagline gap');
  });

  testWidgets(
    'home compact players-disclosure-to-create gap is kSpace3 or kSpace4',
    (WidgetTester tester) async {
      await _pumpHome(tester, size: const Size(390, 600));

      final Rect disclosure = tester.getRect(
        find.byKey(const Key('home-players-disclosure')),
      );
      final Rect create = tester.getRect(
        find.byKey(const Key('create-room-button')),
      );
      _expectGapIn(create.top - disclosure.bottom, <double>{
        kSpace3,
        kSpace4,
      }, 'compact HomeScreen players-disclosure-to-create gap');
    },
  );

  testWidgets(
    'lobby connecting spinner-to-label and label-to-cancel gaps are kSpace4',
    (WidgetTester tester) async {
      final RoomController controller = await _pumpConnectingLobby(tester);
      try {
        final Finder connecting = find.byKey(const Key('lobby-connecting'));
        expect(connecting, findsOneWidget);

        final Rect spinner = tester.getRect(
          find.descendant(
            of: connecting,
            matching: find.byType(CircularProgressIndicator),
          ),
        );
        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byType(LobbyScreen)),
        );
        final Rect label = tester.getRect(
          find.descendant(
            of: connecting,
            matching: find.text(loc.lobbyConnecting),
          ),
        );
        final Rect cancel = tester.getRect(
          find.byKey(const Key('lobby-cancel-button')),
        );

        expect(
          label.top - spinner.bottom,
          kSpace4,
          reason:
              'lobby connecting spinner-to-label gap must be kSpace4 '
              '($kSpace4), found ${label.top - spinner.bottom}',
        );
        expect(
          cancel.top - label.bottom,
          kSpace4,
          reason:
              'lobby connecting label-to-cancel gap must be kSpace4 '
              '($kSpace4), found ${cancel.top - label.bottom}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  testWidgets('game connection-lost reconnect-to-leave gap is kSpace2', (
    WidgetTester tester,
  ) async {
    final (RoomController controller, FakeTransport transport) =
        await _connectPlaying(tester);
    addTearDown(controller.dispose);

    transport.endFromFarSide();
    await tester.pump();
    await tester.pump();
    expect(
      controller.phase,
      RoomPhase.closed,
      reason: 'far-side close must set RoomPhase.closed',
    );

    await tester.pumpWidget(
      _localizations(home: GameScreen(controller: controller)),
    );
    await tester.pump();

    final Rect reconnect = tester.getRect(
      find.byKey(const Key('game-screen-reconnect-button')),
    );
    final Rect leave = tester.getRect(
      find.byKey(const Key('game-screen-leave-button')),
    );
    expect(
      leave.top - reconnect.bottom,
      kSpace2,
      reason:
          'game connection-lost reconnect-to-leave gap must be kSpace2 '
          '($kSpace2), found ${leave.top - reconnect.bottom}',
    );
  });
}
