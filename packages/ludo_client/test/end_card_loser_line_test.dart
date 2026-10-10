// C-307. EndCard.stepsLeft, the end-card-lose-line key and
// AppLocalizations.endLoseNear are not on this base (order 307 adds
// them). This file does not compile until they exist.
//
// GameScreen is driven the same way test/end_card_test.dart drives
// _minimalLoseGame. Those helpers are private, so the ones this file
// needs are copied here. One mount per case. Pumps stay bounded: two
// bare pumps per pushed frame, then kEndCardHoldLimit in 250ms chunks
// once the screen is up. No pumpAndSettle.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://loser-line-test.invalid/ws';
const String _loseVerifyUrl = 'https://loser-line-test.invalid/verify/lose';

const Key _loseKey = Key('end-card-lose');
const Key _loseLineKey = Key('end-card-lose-line');

const Size _phoneSize = Size(360, 640);

const String _enNudge = 'Good game. One more?';
const String _arNudge = 'لعبة جيدة. جولة أخرى؟';
const String _enNear1 = 'One square from home. One more?';
const String _enNear7 = 'Only 7 squares from home. One more?';
const String _enNear12 = 'Only 12 squares from home. One more?';
const String _arNear1 = 'على بُعد مربع واحد من البيت. جولة أخرى؟';
const String _arNear2 = 'على بُعد مربعين من البيت. جولة أخرى؟';
const String _arNear7 = 'على بُعد 7 مربعات فقط من البيت. جولة أخرى؟';
const String _arNear12 = 'على بُعد 12 مربعًا فقط من البيت. جولة أخرى؟';

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

Widget _cardHarness({
  required Locale locale,
  required int? stepsLeft,
  double textScale = 1.0,
}) {
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
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );
    },
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(kSpace4),
        child: EndCard(
          mySeat: 0,
          winnerSeat: 1,
          winnerName: 'Bob',
          seatColors: LudoColors.seats,
          stats: null,
          verifyUrl: _loseVerifyUrl,
          onVerify: () {},
          onNewTable: () {},
          onRematch: () {},
          stepsLeft: stepsLeft,
        ),
      ),
    ),
  );
}

Future<void> _mountCard(
  WidgetTester tester, {
  required Locale locale,
  required int? stepsLeft,
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    _cardHarness(locale: locale, stepsLeft: stepsLeft, textScale: textScale),
  );
  await tester.pump();
}

String _plain(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

void _expectLoserLine(
  WidgetTester tester, {
  required String literal,
  required bool near,
  required int? stepsLeft,
}) {
  expect(
    find.byKey(_loseKey),
    findsOneWidget,
    reason: 'the card under test is the loser card',
  );
  expect(find.byKey(_loseLineKey), findsOneWidget);
  final Text text = tester.widget<Text>(find.byKey(_loseLineKey));
  expect(text.textAlign, TextAlign.center);
  final String line = _plain(text);
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byKey(_loseLineKey)),
  );
  expect(line, literal);
  if (near) {
    expect(line, loc.endLoseNear(stepsLeft!));
  } else {
    expect(line, loc.endLoseNudge);
  }
}

/// 360x640, devicePixelRatio 1, reset before the test returns.
/// Copied from test/end_card_labels_fit_test.dart.
Future<void> _onPhone(WidgetTester tester, Future<void> Function() body) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  try {
    await body();
  } finally {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  }
}

bool _isOverflowError(FlutterErrorDetails details) {
  final String text = '${details.exception}\n$details';
  return text.contains('overflowed');
}

RenderParagraph _paragraphOf(WidgetTester tester) {
  final Finder rich = find.descendant(
    of: find.byKey(_loseLineKey),
    matching: find.byType(RichText),
  );
  expect(rich, findsOneWidget);
  return tester.renderObject<RenderParagraph>(rich);
}

// --- GameScreen fixture, copied from test/end_card_test.dart's
// --- _minimalLoseGame. The device seat's tokens are the initial
// --- snapshot: the script only moves the winner, so they stay. ---------

int _serverIdSeq = 0;

String _nextServerId() {
  _serverIdSeq += 1;
  return 'loser-line-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

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

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
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
  'turn': null,
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

Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
}) async {
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
      data: _roomJson(seats: seats),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

Future<void> _mountScreen(
  WidgetTester tester,
  RoomController controller,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: GameScreen(controller: controller),
    ),
  );
  await tester.pump();
}

class _GameScript {
  _GameScript(this.tester, this.transport, {int startSeq = 1})
    : _seq = startSeq;

  final WidgetTester tester;
  final FakeTransport transport;
  int _seq;

  Future<void> _push(String type, Map<String, Object?> data) async {
    _seq += 1;
    transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': _seq}),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> gameStarted({required int turnSeat}) =>
      _push('game_started', <String, Object?>{
        'turn': turnSeat,
        'game_id': 'loser-line-game',
        'client_seeds': 'sam-seed,bob-seed',
      });

  Future<void> turn({required int seat}) =>
      _push('turn', <String, Object?>{'seat': seat, 'deadline_ms': 45000});

  Future<void> rolled({
    required int seat,
    required int value,
    required int k,
  }) => _push('rolled', <String, Object?>{
    'seat': seat,
    'value': value,
    'legal': const <int>[0, 1, 2, 3],
    'deadline_ms': 45000,
    'k': k,
    'reveal': 'a' * 64,
  });

  Future<void> moved({
    required int seat,
    required int token,
    required int from,
    required int to,
  }) => _push('moved', <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': const <Map<String, Object?>>[],
    'extra_roll': false,
  });

  Future<void> gameOver({required int winner}) => _push(
    'game_over',
    <String, Object?>{'winner': winner, 'verify_url': _loseVerifyUrl},
  );
}

Future<void> _pumpPastEndCardHold(WidgetTester tester) async {
  Duration remaining = kEndCardHoldLimit;
  const Duration chunk = Duration(milliseconds: 250);
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
}

List<int> _tokensOf(RoomController controller, int seat) {
  for (final SeatState seatState in controller.room!.seats) {
    if (seatState.seat == seat) {
      return seatState.tokens;
    }
  }
  fail('seat $seat is not in the room');
}

/// Seat 0 loses to seat 1. [myTokens] are seat 0's tokens on the opening
/// snapshot and stay there: the only move is seat 1's.
Future<RoomController> _loseGame(
  WidgetTester tester, {
  required List<int> myTokens,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: myTokens),
      _seatJson(1, name: 'Bob'),
    ],
  );
  await _mountScreen(tester, controller);
  final _GameScript script = _GameScript(tester, transport);
  await script.gameStarted(turnSeat: 1);
  await script.turn(seat: 1);
  await script.rolled(seat: 1, value: 4, k: 1);
  await script.moved(seat: 1, token: 0, from: -1, to: 4);
  await script.gameOver(winner: 1);
  await _pumpPastEndCardHold(tester);
  expect(controller.seat, 0);
  expect(controller.room!.state, RoomState.finished);
  expect(controller.room!.winner, 1);
  expect(_tokensOf(controller, 0), myTokens);
  return controller;
}

void main() {
  setUpAll(_loadAppFonts);

  // stepsLeft 12 is the near boundary. The input is the literal 12, not
  // kNearFinishSquares, so a constant that moved and a widget that
  // followed it still fails. 13 and null are the nudge: the near branch
  // always taken fails there.
  group('EndCard loser line', () {
    const List<({String code, int? stepsLeft, String literal, bool near})>
    cases = <({String code, int? stepsLeft, String literal, bool near})>[
      (code: 'en', stepsLeft: 1, literal: _enNear1, near: true),
      (code: 'en', stepsLeft: 7, literal: _enNear7, near: true),
      (code: 'en', stepsLeft: 12, literal: _enNear12, near: true),
      (code: 'en', stepsLeft: 13, literal: _enNudge, near: false),
      (code: 'en', stepsLeft: null, literal: _enNudge, near: false),
      (code: 'ar', stepsLeft: 1, literal: _arNear1, near: true),
      (code: 'ar', stepsLeft: 2, literal: _arNear2, near: true),
      (code: 'ar', stepsLeft: 7, literal: _arNear7, near: true),
      (code: 'ar', stepsLeft: 12, literal: _arNear12, near: true),
      (code: 'ar', stepsLeft: 13, literal: _arNudge, near: false),
      (code: 'ar', stepsLeft: null, literal: _arNudge, near: false),
    ];

    for (final ({String code, int? stepsLeft, String literal, bool near}) c
        in cases) {
      final String steps = c.stepsLeft == null ? 'null' : '${c.stepsLeft}';
      testWidgets('${c.code} stepsLeft $steps', (WidgetTester tester) async {
        await _mountCard(
          tester,
          locale: Locale(c.code),
          stepsLeft: c.stepsLeft,
        );
        _expectLoserLine(
          tester,
          literal: c.literal,
          near: c.near,
          stepsLeft: c.stepsLeft,
        );
      });
    }
  });

  group('GameScreen passes stepsLeft from the seat tokens', () {
    testWidgets('tokens [57, 57, 57, 50] show the near line for 7', (
      WidgetTester tester,
    ) async {
      await _loseGame(tester, myTokens: const <int>[57, 57, 57, 50]);
      _expectLoserLine(tester, literal: _enNear7, near: true, stepsLeft: 7);
    });

    testWidgets('tokens [-1, -1, -1, -1] show the nudge', (
      WidgetTester tester,
    ) async {
      await _loseGame(tester, myTokens: const <int>[-1, -1, -1, -1]);
      _expectLoserLine(tester, literal: _enNudge, near: false, stepsLeft: null);
    });
  });

  // Count 12 is the longest near line: en other, ar other (12 is many,
  // and the message has no many, so the other form). May wrap. Must
  // not overflow and must not report exceeded lines.
  group('near line fits at 360dp', () {
    for (final (String code, String literal) in const <(String, String)>[
      ('en', _enNear12),
      ('ar', _arNear12),
    ]) {
      testWidgets('$code count 12 does not overflow or clip', (
        WidgetTester tester,
      ) async {
        await _onPhone(tester, () async {
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final void Function(FlutterErrorDetails)? previous =
              FlutterError.onError;
          FlutterError.onError = captured.add;
          try {
            await _mountCard(tester, locale: Locale(code), stepsLeft: 12);
          } finally {
            FlutterError.onError = previous;
          }

          final List<FlutterErrorDetails> overflows = captured
              .where(_isOverflowError)
              .toList();
          expect(
            overflows,
            isEmpty,
            reason:
                '$code count 12 at 360dp must not report a RenderFlex '
                'overflow; got $overflows',
          );
          final List<FlutterErrorDetails> others = captured
              .where(
                (FlutterErrorDetails details) => !_isOverflowError(details),
              )
              .toList();
          expect(others, isEmpty, reason: 'unexpected FlutterError: $others');

          _expectLoserLine(tester, literal: literal, near: true, stepsLeft: 12);
          final RenderParagraph paragraph = _paragraphOf(tester);
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason:
                '$code count 12 at 360dp must not clip; '
                'didExceedMaxLines was ${paragraph.didExceedMaxLines}',
          );
        });
      });
    }
  });
}
