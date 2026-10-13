// Measurement for X48. Reds here are open defects paired with their fix
// order; this file does not merge alone.
//
// Order 333, run 87. GameScreen is mounted exactly the way
// test/header_fits_test.dart mounts it: a real RoomController over
// FakeTransport, under FeedbackScope, buildAppTheme, the real Poppins and
// Noto Sans Arabic fonts, 360x640 logical at devicePixelRatio 1, both reset
// in the test body. One mount per case.
//
// The ambient MediaQuery's textScaler is overridden with
// TextScaler.linear(s) through MaterialApp.builder, the way
// test/end_card_test.dart's own `_harness` does it (and the way
// test/end_card_labels_fit_test.dart's `_harness` does it too).
//
// didExceedMaxLines and painted size are read off a fresh TextPainter built
// from the live RenderParagraph's own resolved span, direction, scaler and
// maxLines, laid out at the width that RenderParagraph itself was given
// (test/end_card_labels_fit_test.dart's `_painterFor` / `_layoutMaxWidth`
// precedent) -- not off the live RenderParagraph's own didExceedMaxLines,
// so the number this file prints (painter.size) is reproducible from the
// resolved style alone, independent of whatever clipping the live tree
// happened to apply.
//
// Both seats carry a 10-character name throughout (Karim12345, Samantha12)
// so the board always draws two name chips and one You label, in every
// state, not only the "another seat's turn" one.
//
// Name length: this tree carries no client-side cap on the name field (no
// maxLength, no LengthLimitingTextInputFormatter, in
// packages/ludo_client/lib -- checked by grep). The one length limit found
// anywhere under a package's lib/ is server-side, in
// packages/ludo_server/lib/src/registry.dart lines 411-412
// (`_minName = 1; _maxName = 24;`), read in `_validName` at line 1641. That
// is 24 characters, not 10. This file uses a 10-character name because the
// order's own wording asks for "a 10-character name", matching
// test/header_fits_test.dart's own "Karim12345" case; the order's
// parenthetical calling that "the longest name the app accepts" does not
// match the 24-character limit this tree actually enforces. Flagged, not
// invented around; see the final report.
//
// No pumpAndSettle (a turn arms a one-second countdown). No bare
// pumpEventQueue() inside a testWidgets body. The controller is disposed in
// the test body.

import 'dart:convert';

import 'package:flutter/foundation.dart';
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

const String _testUrl = 'wss://large-text-fit-test.invalid/ws';

const String _moveEn = 'Your turn. Move a token.';
const String _moveAr = 'دورك. حرّك قطعة.';
const String _overEn = 'Game over';
const String _overAr = 'انتهت اللعبة';

// Both 10 characters, both accepted by the server's 1-24 character limit
// (packages/ludo_server/lib/src/registry.dart:411-412), distinct from each
// other so find.text() below is never ambiguous.
const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _headerChipKey = Key('game-header-chip');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _countdownRingBoxKey = Key('game-header-countdown-semantics');
const Key _boardKey = Key('game-screen-board');
const Key _dieKey = Key('game-die');
const Key _winnerKey = Key('game-screen-winner');

const Size _phoneSize = Size(360, 640);

const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'large-text-fit-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

// Both 10 characters, in every state -- not only the "another seat's turn"
// one -- so the board always draws two name chips and one You label.
List<Map<String, Object?>> _twoSeats({
  List<int> seat0Tokens = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  _seatJson(0, name: _mySeatName, tokens: seat0Tokens),
  _seatJson(1, name: _otherSeatName),
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
/// caller's finally still disposes it. Copied from
/// test/header_fits_test.dart's own `_connect`.
Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester,
  _Keep keep, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
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

Widget _harness(
  Widget child, {
  required Locale locale,
  required double textScale,
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
    builder: (BuildContext context, Widget? screen) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
        child: screen!,
      );
    },
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  required Locale locale,
  required double textScale,
}) async {
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: _FakeFeedbackService(),
        child: GameScreen(controller: controller),
      ),
      locale: locale,
      textScale: textScale,
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
        'verify_url': 'https://large-text-fit-test.invalid/verify/$seq',
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

// ---------------------------------------------------------------------------
// Measurement plumbing, following test/end_card_labels_fit_test.dart's own
// `_textFinder` / `_paragraphOf` / `_layoutMaxWidth` / `_painterFor`.
// ---------------------------------------------------------------------------

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

Finder _textFinderByData(Finder scope, String value) {
  return find.descendant(
    of: scope,
    matching: find.byWidgetPredicate(
      (Widget widget) => widget is Text && _textOf(widget) == value,
    ),
  );
}

RenderParagraph _paragraphOf(WidgetTester tester, Finder textFinder) {
  final Finder rich = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  return tester.renderObject<RenderParagraph>(rich);
}

/// RenderParagraph's own rule: unbounded unless it wraps or ellipsizes.
double _layoutMaxWidth(RenderParagraph paragraph) {
  final bool wraps =
      paragraph.softWrap || paragraph.overflow == TextOverflow.ellipsis;
  return wraps ? paragraph.constraints.maxWidth : double.infinity;
}

/// A fresh TextPainter from [paragraph]'s own resolved span, direction,
/// scaler and maxLines, laid out at [paragraph]'s own rendered width
/// (`_layoutMaxWidth`). Disposed by the caller.
TextPainter _painterFor(RenderParagraph paragraph) {
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '…' : null,
  );
  painter.layout(
    minWidth: paragraph.constraints.minWidth,
    maxWidth: _layoutMaxWidth(paragraph),
  );
  return painter;
}

bool _fits(double measured, double bound) => measured <= bound + 0.5;

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

void main() {
  setUpAll(_loadAppFonts);

  for (final double scale in _scales) {
    final String scaleLabel = scale.toStringAsFixed(1);

    for (final Locale locale in _locales) {
      final String code = locale.languageCode;

      // ---------------------------------------------------------------
      // Case: own turn, awaiting a roll.
      // ---------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: own turn awaitRoll', (
        tester,
      ) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final List<String> reds = <String>[];
        final String label = '$code scale $scaleLabel own turn awaitRoll';
        try {
          await _phone(tester, (_Keep keep) async {
            final (RoomController controller, _) = await _connect(
              tester,
              keep,
              seats: _twoSeats(),
              turn: _turnJson(seat: 0, phase: 'await_roll'),
            );
            await _mount(tester, controller, locale: locale, textScale: scale);
            reds.addAll(
              _checkCase(
                tester,
                label: label,
                expectedBanner: _loc(tester).gameYourTurnRoll,
                myName: _mySeatName,
                otherName: _otherSeatName,
                expectCountdown: true,
              ),
            );
          });
        } finally {
          FlutterError.onError = previous;
        }
        if (captured.isNotEmpty) {
          reds.insert(
            0,
            '$label: expected no FlutterError during mount/pump, got '
            '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' | ')}',
          );
        }
        expect(reds, isEmpty, reason: reds.join('\n'));
      });

      // ---------------------------------------------------------------
      // Case: own turn, awaiting a move. H2's literal "Your turn. Move a
      // token." line, matched the way test/header_fits_test.dart matches
      // it, not via the localization getter.
      // ---------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: own turn awaitMove', (
        tester,
      ) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final List<String> reds = <String>[];
        final String label = '$code scale $scaleLabel own turn awaitMove';
        try {
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
            await _mount(tester, controller, locale: locale, textScale: scale);
            reds.addAll(
              _checkCase(
                tester,
                label: label,
                expectedBanner: code == 'ar' ? _moveAr : _moveEn,
                myName: _mySeatName,
                otherName: _otherSeatName,
                expectCountdown: true,
              ),
            );
          });
        } finally {
          FlutterError.onError = previous;
        }
        if (captured.isNotEmpty) {
          reds.insert(
            0,
            '$label: expected no FlutterError during mount/pump, got '
            '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' | ')}',
          );
        }
        expect(reds, isEmpty, reason: reds.join('\n'));
      });

      // ---------------------------------------------------------------
      // Case: another seat's turn, waiting on a 10-character name.
      // ---------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: another seat turn, 10-char name', (
        tester,
      ) async {
        expect(
          _otherSeatName.length,
          10,
          reason: 'the waiting name must be 10 characters',
        );
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final List<String> reds = <String>[];
        final String label =
            '$code scale $scaleLabel another seat turn 10-char name';
        try {
          await _phone(tester, (_Keep keep) async {
            final (RoomController controller, _) = await _connect(
              tester,
              keep,
              seats: _twoSeats(),
              turn: _turnJson(seat: 1, phase: 'await_roll'),
            );
            await _mount(tester, controller, locale: locale, textScale: scale);
            reds.addAll(
              _checkCase(
                tester,
                label: label,
                expectedBanner: _loc(tester)
                    .gameWaitingForPlayer(_otherSeatName),
                myName: _mySeatName,
                otherName: _otherSeatName,
                expectCountdown: true,
              ),
            );
          });
        } finally {
          FlutterError.onError = previous;
        }
        if (captured.isNotEmpty) {
          reds.insert(
            0,
            '$label: expected no FlutterError during mount/pump, got '
            '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' | ')}',
          );
        }
        expect(reds, isEmpty, reason: reds.join('\n'));
      });

      // ---------------------------------------------------------------
      // Case: finished. Reached the way
      // test/header_fits_test.dart's "finished" case reaches it: a moved
      // frame (so travel > 0 and the end hold keeps the board up) then a
      // game_over frame, not by constructing a FINISHED room snapshot
      // directly.
      // ---------------------------------------------------------------
      testWidgets('$code scale $scaleLabel: finished', (tester) async {
        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final FlutterExceptionHandler? previous = FlutterError.onError;
        FlutterError.onError = captured.add;
        final List<String> reds = <String>[];
        final String label = '$code scale $scaleLabel finished';
        try {
          await _phone(tester, (_Keep keep) async {
            final (
              RoomController controller,
              FakeTransport transport,
            ) = await _connect(
              tester,
              keep,
              seats: _twoSeats(seat0Tokens: const <int>[51, -1, -1, -1]),
              turn: _turnJson(seat: 0, phase: 'await_roll'),
            );
            await _mount(tester, controller, locale: locale, textScale: scale);
            await _pushMoved(
              tester,
              transport,
              seat: 0,
              from: 51,
              to: 57,
              seq: 2,
            );
            await _pushGameOver(tester, transport, winner: 0, seq: 3);
            if (!tester.any(find.byKey(_dieKey))) {
              reds.add(
                '$label: the end hold must still show the board (game-die missing)',
              );
            }
            if (tester.any(find.byKey(_winnerKey))) {
              reds.add(
                '$label: the end card must not be up yet (game-screen-winner present)',
              );
            }
            reds.addAll(
              _checkCase(
                tester,
                label: label,
                expectedBanner: code == 'ar' ? _overAr : _overEn,
                myName: _mySeatName,
                otherName: _otherSeatName,
                // room.state is no longer RoomState.playing once finished,
                // so _playHeaderRow's own `turn != null && room.state ==
                // RoomState.playing` guard drops the countdown block.
                expectCountdown: false,
              ),
            );
          });
        } finally {
          FlutterError.onError = previous;
        }
        if (captured.isNotEmpty) {
          reds.insert(
            0,
            '$label: expected no FlutterError during mount/pump, got '
            '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' | ')}',
          );
        }
        expect(reds, isEmpty, reason: reds.join('\n'));
      });
    }
  }
}

/// Runs assertions 2-4 against the mounted tree and prints assertion 5's
/// report line. [label] already carries locale, scale and state. Never
/// throws: every red this finds is appended to the returned list instead,
/// so a caller can still run its own FlutterError.onError check even when
/// this finds something wrong (lesson 18's capture would otherwise be
/// skipped by the first failed `expect`).
List<String> _checkCase(
  WidgetTester tester, {
  required String label,
  required String expectedBanner,
  required String myName,
  required String otherName,
  required bool expectCountdown,
}) {
  final List<String> reds = <String>[];

  // ---- assertion 2: the banner is whole. ----------------------------
  if (!tester.any(find.byKey(_bannerKey))) {
    reds.add('$label: game-screen-turn-banner must be on screen, found none');
    return reds;
  }
  final String shownBanner =
      tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
  if (shownBanner != expectedBanner) {
    reds.add(
      '$label: banner text, expected "$expectedBanner", got "$shownBanner"',
    );
  }
  final RenderParagraph bannerParagraph = _paragraphOf(
    tester,
    find.byKey(_bannerKey),
  );
  final TextPainter bannerPainter = _painterFor(bannerParagraph);
  final double chipHeight = tester.getSize(find.byKey(_headerChipKey)).height;
  try {
    _print(
      'CASE $label banner="$shownBanner" '
      'width=${bannerParagraph.constraints.maxWidth.toStringAsFixed(1)} '
      'painterSize=${bannerPainter.size.width.toStringAsFixed(1)}x'
      '${bannerPainter.size.height.toStringAsFixed(1)} '
      'didExceedMaxLines=${bannerPainter.didExceedMaxLines} '
      'chipHeight=${chipHeight.toStringAsFixed(1)}',
    );
    if (bannerPainter.didExceedMaxLines) {
      reds.add(
        '$label: banner "$shownBanner" exceeded its one line at width '
        '${bannerParagraph.constraints.maxWidth.toStringAsFixed(1)} '
        '(TextPainter.didExceedMaxLines=true)',
      );
    }
    if (!_fits(bannerPainter.size.height, chipHeight)) {
      reds.add(
        '$label: banner rendered height '
        '${bannerPainter.size.height.toStringAsFixed(1)} is greater than '
        'game-header-chip height ${chipHeight.toStringAsFixed(1)} '
        '(tolerance 0.5px)',
      );
    }
  } finally {
    bannerPainter.dispose();
  }

  // ---- assertion 3: the countdown seconds fit their ring. -----------
  final Finder countdownFinder = find.byKey(_countdownKey);
  final bool countdownPresent = tester.any(countdownFinder);
  if (expectCountdown && !countdownPresent) {
    reds.add(
      '$label: game-screen-turn-countdown must be on screen, found none',
    );
  }
  if (countdownPresent) {
    final RenderParagraph countdownParagraph = _paragraphOf(
      tester,
      countdownFinder,
    );
    final TextPainter countdownPainter = _painterFor(countdownParagraph);
    final Size ringBox = tester.getSize(find.byKey(_countdownRingBoxKey));
    try {
      _print(
        'CASE $label countdownPainterSize='
        '${countdownPainter.size.width.toStringAsFixed(1)}x'
        '${countdownPainter.size.height.toStringAsFixed(1)} '
        'ringBox=${ringBox.width.toStringAsFixed(1)}x'
        '${ringBox.height.toStringAsFixed(1)}',
      );
      if (!_fits(countdownPainter.size.width, ringBox.width)) {
        reds.add(
          '$label: countdown painted width '
          '${countdownPainter.size.width.toStringAsFixed(1)} is greater '
          'than ring box width ${ringBox.width.toStringAsFixed(1)} '
          '(tolerance 0.5px)',
        );
      }
      if (!_fits(countdownPainter.size.height, ringBox.height)) {
        reds.add(
          '$label: countdown painted height '
          '${countdownPainter.size.height.toStringAsFixed(1)} is greater '
          'than ring box height ${ringBox.height.toStringAsFixed(1)} '
          '(tolerance 0.5px)',
        );
      }
    } finally {
      countdownPainter.dispose();
    }
  }

  // ---- assertion 4: the name chip holds its text. --------------------
  for (final (int seat, String name) in <(int, String)>[
    (0, myName),
    (1, otherName),
  ]) {
    final Key chipKey = Key('board-seat-name-$seat');
    final Finder chipFinder = find.byKey(chipKey);
    if (!tester.any(chipFinder)) {
      reds.add(
        '$label: board-seat-name-$seat must be on the board, found none',
      );
      continue;
    }
    final Finder nameTextFinder = _textFinderByData(chipFinder, name);
    if (!tester.any(nameTextFinder)) {
      reds.add(
        '$label: seat $seat name text "$name" must be inside its chip, '
        'found none',
      );
      continue;
    }
    final RenderParagraph nameParagraph = _paragraphOf(tester, nameTextFinder);
    final TextPainter namePainter = _painterFor(nameParagraph);
    final double nameChipHeight = tester.getSize(chipFinder).height;
    try {
      _print(
        'CASE $label seat=$seat name="$name" '
        'width=${nameParagraph.constraints.maxWidth.toStringAsFixed(1)} '
        'painterSize=${namePainter.size.width.toStringAsFixed(1)}x'
        '${namePainter.size.height.toStringAsFixed(1)} '
        'didExceedMaxLines=${namePainter.didExceedMaxLines} '
        'liveDidExceedMaxLines=${nameParagraph.didExceedMaxLines} '
        'liveSize=${nameParagraph.size.width.toStringAsFixed(1)}x'
        '${nameParagraph.size.height.toStringAsFixed(1)} '
        'chipHeight=${nameChipHeight.toStringAsFixed(1)}',
      );
      if (namePainter.didExceedMaxLines) {
        reds.add(
          '$label: board-seat-name-$seat "$name" is cut (ellipsized) at '
          'its chip\'s inner width '
          '${nameParagraph.constraints.maxWidth.toStringAsFixed(1)} '
          '(TextPainter.didExceedMaxLines=true)',
        );
      }
      if (!_fits(namePainter.size.height, nameChipHeight)) {
        reds.add(
          '$label: board-seat-name-$seat "$name" line height '
          '${namePainter.size.height.toStringAsFixed(1)} is greater than '
          'chip height ${nameChipHeight.toStringAsFixed(1)} (tolerance '
          '0.5px)',
        );
      }
    } finally {
      namePainter.dispose();
    }

    if (seat == 0) {
      final Finder youFinder = find.byKey(const Key('board-seat-you'));
      if (!tester.any(youFinder)) {
        reds.add(
          '$label: board-seat-you must be in seat 0\'s chip, found none',
        );
        continue;
      }
      final RenderParagraph youParagraph = _paragraphOf(tester, youFinder);
      final TextPainter youPainter = _painterFor(youParagraph);
      try {
        final String youText = tester.widget<Text>(youFinder).data ?? '';
        _print(
          'CASE $label you="$youText" '
          'width=${youParagraph.constraints.maxWidth.toStringAsFixed(1)} '
          'painterSize=${youPainter.size.width.toStringAsFixed(1)}x'
          '${youPainter.size.height.toStringAsFixed(1)} '
          'didExceedMaxLines=${youPainter.didExceedMaxLines} '
          'chipHeight=${nameChipHeight.toStringAsFixed(1)}',
        );
        if (youPainter.didExceedMaxLines) {
          reds.add(
            '$label: board-seat-you "$youText" is cut (ellipsized) at its '
            'chip\'s inner width '
            '${youParagraph.constraints.maxWidth.toStringAsFixed(1)} '
            '(TextPainter.didExceedMaxLines=true)',
          );
        }
        if (!_fits(youPainter.size.height, nameChipHeight)) {
          reds.add(
            '$label: board-seat-you "$youText" line height '
            '${youPainter.size.height.toStringAsFixed(1)} is greater than '
            'chip height ${nameChipHeight.toStringAsFixed(1)} (tolerance '
            '0.5px)',
          );
        }
      } finally {
        youPainter.dispose();
      }
    }
  }

  // ---- assertion 5: report, do not assert. ---------------------------
  final Size boardSize = tester.getSize(find.byKey(_boardKey));
  final double headerRowHeight = tester
      .getSize(
        find
            .ancestor(
              of: find.byKey(_headerChipKey),
              matching: find.byType(SizedBox),
            )
            .first,
      )
      .height;
  _print(
    'REPORT $label boardWidth=${boardSize.width.toStringAsFixed(1)} '
    'boardHeight=${boardSize.height.toStringAsFixed(1)} '
    'headerRowHeight=${headerRowHeight.toStringAsFixed(1)} '
    'headerChipHeight=${chipHeight.toStringAsFixed(1)}',
  );

  return reds;
}
