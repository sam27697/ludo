// C-290 rule 3. GameScreen is mounted the way test/play_header_test.dart
// mounts it: a real RoomController over FakeTransport, under FeedbackScope,
// one mount per case. The surface is 360x640 logical (physicalSize with
// devicePixelRatio 1) and both are reset in the test body, not from
// addTearDown. Text scale is the test binding's own default.
//
// The paragraph is the app's: buildAppTheme plus the Poppins and Noto Sans
// Arabic files that theme names, loaded the same way
// test/home_screen_players_fit_test.dart loads them. The test font's square
// glyphs are not the line the 360dp recording cut.
//
// The move line and the finished line are not what this tree's banner
// returns. Those two are matched by the literal rule 1 and rule 2 name,
// after the state is driven. The other strings are the localization
// getters that already exist.
//
// No pumpAndSettle (a turn arms a one-second countdown). No bare
// pumpEventQueue() inside a testWidgets body. The controller is disposed
// in the test body.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://header-fits-test.invalid/ws';

const String _moveEn = 'Your turn. Move a token.';
const String _moveAr = 'دورك. حرّك قطعة.';
const String _overEn = 'Game over';
const String _overAr = 'انتهت اللعبة';

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _dieKey = Key('game-die');
const Key _winnerKey = Key('game-screen-winner');

const Size _phoneSize = Size(360, 640);

const List<Duration> _oneDelay = <Duration>[Duration(seconds: 1)];

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'header-fits-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  int? value,
  List<int>? legal,
  int k = 0,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': 45000,
  'k': k,
  'value': ?value,
  'legal': ?legal,
};

Map<String, Object?> _roomJson({
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

List<Map<String, Object?>> _twoSeats({String seat1Name = 'Bob'}) =>
    <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: seat1Name),
    ];

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

class _FakeFeedbackService implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

typedef _Keep = void Function(RoomController controller);

/// Registers the controller before the first await that can throw, so the
/// caller's finally still disposes it.
Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester,
  _Keep keep, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  List<Duration> autoReconnectDelays = const <Duration>[],
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: autoReconnectDelays,
  );
  keep(controller);

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

Widget _harness(Widget child, {required Locale locale}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
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
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: _FakeFeedbackService(),
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// 360x640, reset before the test returns. [body] calls [keep] with the
/// controller it connects.
Future<void> _phone(
  WidgetTester tester,
  Future<void> Function(_Keep keep) body,
) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  RoomController? controller;
  try {
    await body((RoomController c) {
      controller = c;
    });
  } finally {
    final RoomController? owned = controller;
    if (owned != null) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      owned.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void _expectFits(
  WidgetTester tester, {
  required Locale locale,
  required String label,
  required String expected,
}) {
  final Finder banner = find.byKey(_bannerKey);
  expect(
    banner,
    findsOneWidget,
    reason:
        '$label: game-screen-turn-banner must be on screen '
        '(${locale.languageCode})',
  );
  final String shown = tester.widget<Text>(banner).data ?? '';
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: banner, matching: find.byType(RichText)),
  );
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '$label: "$shown" exceeded one line (${locale.languageCode})',
  );
  expect(
    shown,
    expected,
    reason:
        '$label: banner text (${locale.languageCode}), '
        'expected "$expected", got "$shown"',
  );
}

Future<void> _pushMoved(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int from,
  required int to,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': 0,
        'from': from,
        'to': to,
        'captured': <Map<String, Object?>>[],
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushGameOver(
  WidgetTester tester,
  FakeTransport transport, {
  required int winner,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'game_over',
      data: <String, Object?>{
        'winner': winner,
        'verify_url': 'https://header-fits-test.invalid/verify/$seq',
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

void main() {
  setUpAll(_loadAppFonts);

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String code = locale.languageCode;

    testWidgets('$code own turn awaitRoll fits on one line', (tester) async {
      await _phone(tester, (_Keep keep) async {
        final (RoomController controller, _) = await _connect(
          tester,
          keep,
          seats: _twoSeats(),
          turn: _turnJson(seat: 0, phase: 'await_roll'),
        );
        await _mount(tester, controller, locale: locale);
        _expectFits(
          tester,
          locale: locale,
          label: '$code awaitRoll',
          expected: _loc(tester).gameYourTurnRoll,
        );
      });
    });

    testWidgets('$code own turn awaitMove fits on one line', (tester) async {
      await _phone(tester, (_Keep keep) async {
        final (RoomController controller, _) = await _connect(
          tester,
          keep,
          seats: _twoSeats(),
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            k: 1,
            value: 4,
            legal: const <int>[0, 2],
          ),
        );
        await _mount(tester, controller, locale: locale);
        _expectFits(
          tester,
          locale: locale,
          label: '$code awaitMove',
          expected: code == 'ar' ? _moveAr : _moveEn,
        );
      });
    });

    testWidgets('$code stale own turn fits on one line', (tester) async {
      await _phone(tester, (_Keep keep) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connect(
          tester,
          keep,
          seats: _twoSeats(),
          turn: _turnJson(seat: 0, phase: 'await_roll'),
          autoReconnectDelays: _oneDelay,
        );
        await _mount(tester, controller, locale: locale);
        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        _expectFits(
          tester,
          locale: locale,
          label: '$code stale own turn',
          expected: _loc(tester).gameYourTurnStale,
        );
      });
    });

    testWidgets('$code waiting for Karim12345 fits on one line', (
      tester,
    ) async {
      const String name = 'Karim12345';
      expect(name.length, 10, reason: 'the waiting name must be 10 characters');
      await _phone(tester, (_Keep keep) async {
        final (RoomController controller, _) = await _connect(
          tester,
          keep,
          seats: _twoSeats(seat1Name: name),
          turn: _turnJson(seat: 1, phase: 'await_roll'),
        );
        await _mount(tester, controller, locale: locale);
        _expectFits(
          tester,
          locale: locale,
          label: '$code waiting for $name',
          expected: _loc(tester).gameWaitingForPlayer(name),
        );
      });
    });

    testWidgets('$code no turn fits on one line', (tester) async {
      await _phone(tester, (_Keep keep) async {
        final (RoomController controller, _) = await _connect(
          tester,
          keep,
          seats: _twoSeats(),
          turn: null,
        );
        await _mount(tester, controller, locale: locale);
        _expectFits(
          tester,
          locale: locale,
          label: '$code no turn',
          expected: _loc(tester).gameWaitingForTurn,
        );
      });
    });

    testWidgets('$code finished fits on one line', (tester) async {
      await _phone(tester, (_Keep keep) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[51, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connect(
          tester,
          keep,
          seats: seats,
          turn: _turnJson(seat: 0, phase: 'await_roll'),
        );
        await _mount(tester, controller, locale: locale);
        await _pushMoved(tester, transport, seat: 0, from: 51, to: 57, seq: 2);
        await _pushGameOver(tester, transport, winner: 0, seq: 3);
        expect(
          find.byKey(_dieKey),
          findsOneWidget,
          reason:
              '$code finished: the end hold must still show the board '
              '(${locale.languageCode})',
        );
        expect(
          find.byKey(_winnerKey),
          findsNothing,
          reason:
              '$code finished: the end card must not be up yet '
              '(${locale.languageCode})',
        );
        _expectFits(
          tester,
          locale: locale,
          label: '$code finished',
          expected: code == 'ar' ? _overAr : _overEn,
        );
      });
    });
  }
}
