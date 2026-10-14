// Measurement for X52 and X53, order 345, run 88. No implementation exists
// or is ordered yet; this file does not merge alone and is expected mostly
// RED.
//
// Based on test/large_text_fit_test.dart: real fonts (Poppins, Noto Sans
// Arabic), the ambient MediaQuery text scale overridden through
// MaterialApp.builder, one mount per case, surface size and
// devicePixelRatio 1 set and reset in the test body (tester.view, not
// tester.binding.setSurfaceSize). Helpers are copied from that file (and,
// for mounting a connected lobby, from test/lobby_seat_cards_test.dart's
// own `_mountConnectedLobby` idiom) rather than imported: neither file
// exports what this one needs, and neither is on this order's file list to
// modify.
//
// Both seats carry a 10-character name throughout (Karim12345 at seat 0,
// the player; Samantha12 at seat 1) so every chip this file reads is one
// that actually has ten characters to cut.
//
// X53's own-seat-chip reading matches the order's own wording literally:
// ellipsis is read off the live RenderParagraph's own didExceedMaxLines,
// not a fresh TextPainter rebuilt from it (large_text_fit_test.dart's own
// `_painterFor` precedent is for its banner/countdown text, which the
// ambient text scaler actually reaches; board.dart's name and "You" labels
// are painted with `TextScaler.noScaling` and an explicit `fontSize` set by
// the chip's own fitting math, so the live paragraph's resolved TextSpan
// style already carries the number this file reports). X52's seat-card
// name has no such override (lobby_screen.dart / seat_card.dart set no
// font size and no textScaler on it), so the ambient scale reaches it
// directly; the same live-paragraph reading applies to it too, for one
// rule in this file rather than two.
//
// No pumpAndSettle (a turn arms a one-second countdown). No bare
// pumpEventQueue() inside a testWidgets body. The controller is disposed in
// the test body.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart' show LudoBoard;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme, kSpace2;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://large-text-names-test.invalid/ws';

// Both 10 characters, both accepted by the server's 1-24 character limit
// (packages/ludo_server/lib/src/registry.dart:411-412), distinct from each
// other so a text-data finder is never ambiguous.
const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

// Group A's 4-seat cases need two more 10-character names, distinct from
// the two above and from each other.
const String _thirdSeatName = 'Oliver1234';
const String _fourthSeatName = 'Isabella12';

// Group A3's open-seat placeholders are never reached with 4 of 4 seated,
// so these three short names only need to be short, not any particular
// length.
const String _shortNameA = 'Ali';
const String _shortNameB = 'Bo';
const String _shortNameC = 'Cy';

/// Decision 4's case: a name four times `_mySeatName`'s ten characters, 40
/// in total, built from concatenation (Dart's `String` has no `*`
/// operator) rather than typed out by hand so its length is exactly right
/// by construction, not by counting.
final String _longName40 = List<String>.filled(4, _mySeatName).join();

const Key _boardKey = Key('game-screen-board');

// The order's own matrix: 360x640, 411x704 (the CI emulator); text scales
// 1.0, 1.3, 2.0; locales en and ar.
const List<Size> _surfaces = <Size>[Size(360, 640), Size(411, 704)];
const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

String _surfaceLabel(Size size) =>
    '${size.width.toInt()}x${size.height.toInt()}';

// ---------------------------------------------------------------------------
// Frame/JSON plumbing, copied from test/large_text_fit_test.dart.
// ---------------------------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'large-text-names-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
  required String name,
  bool connected = true,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

List<Map<String, Object?>> _twoSeats() => <Map<String, Object?>>[
  _seatJson(0, name: _mySeatName),
  _seatJson(1, name: _otherSeatName),
];

Map<String, Object?> _turnJson({required int seat, required String phase}) =>
    <String, Object?>{
      'seat': seat,
      'phase': phase,
      'deadline_ms': 45000,
      'k': 0,
    };

Map<String, Object?> _gameRoomJson({
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
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
  'seq': 1,
};

/// [seats] and [players] default to the two-seat room every existing case
/// in this file mounts; group A's 4-seat cases pass both explicitly.
Map<String, Object?> _lobbyRoomJson({
  List<Map<String, Object?>>? seats,
  int? players,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'LOBBY',
  'host_seat': 0,
  'players': players ?? 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats ?? _twoSeats(),
  'turn': null,
  'winner': null,
  'rematch': null,
  'seq': 1,
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

class _FakeFeedbackService implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

typedef _Keep = void Function(RoomController controller);

// ---------------------------------------------------------------------------
// Widget harness and connection plumbing, copied from
// test/large_text_fit_test.dart (`_harness`, `_connect`) and
// test/lobby_seat_cards_test.dart (`_mountConnectedLobby`'s own sequence of
// pumpWidget then seat_assigned/room).
// ---------------------------------------------------------------------------

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

/// Registers the controller before the first await that can throw, so the
/// caller's finally still disposes it. Copied from
/// test/large_text_fit_test.dart's own `_connect`.
Future<(RoomController, FakeTransport)> _connectGame(
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
      data: _gameRoomJson(seats: seats, turn: turn),
    ),
  );
  await future;
  return (controller, transport);
}

Future<void> _mountGame(
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

/// Mounts a host `LobbyScreen` (seat 0) for a [players]-seat room, pushes
/// `seat_assigned` then a `room` snapshot carrying [seats], and settles the
/// two pumps test/lobby_seat_cards_test.dart's own `_mountConnectedLobby`
/// uses before trusting the connected body. [players] and [seats] default
/// to the two-seat room every pre-existing case in this file mounts; group
/// A's 4-seat cases pass both explicitly.
Future<void> _mountLobby(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
  required double textScale,
  int players = 2,
  List<Map<String, Object?>>? seats,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  keep(controller);

  await tester.pumpWidget(
    _harness(
      LobbyScreen(
        controller: controller,
        action: LobbyAction.create,
        playerName: _mySeatName,
        players: players,
      ),
      locale: locale,
      textScale: textScale,
    ),
  );
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'fixture: expected LobbyScreen.initState to have sent createRoom '
        'by now; sentRaw is empty',
  );
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
      data: _lobbyRoomJson(seats: seats, players: players),
    ),
  );
  await tester.pump();
  await tester.pump();

  expect(
    controller.phase,
    RoomPhase.connected,
    reason:
        'fixture: expected RoomPhase.connected after seat_assigned/room, '
        'got ${controller.phase}',
  );
}

/// [size] set as the physical size at devicePixelRatio 1, reset before
/// returning. [body] calls [keep] with the controller it connects, so the
/// controller is disposed here even if [body] throws.
///
/// [insets], when given, is set on both `tester.view.padding` and
/// `tester.view.viewPadding` (group C: the system bars a real phone leaves
/// around the game screen), reset alongside the physical size.
Future<void> _surface(
  WidgetTester tester,
  Size size,
  Future<void> Function(_Keep keep) body, {
  FakeViewPadding? insets,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  if (insets != null) {
    tester.view.padding = insets;
    tester.view.viewPadding = insets;
  }
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
    if (insets != null) {
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
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
// Measurement plumbing: find a Text's live RenderParagraph and read its own
// didExceedMaxLines and resolved (painted) font size directly off it,
// following test/end_card_labels_fit_test.dart's own `_textFinder` /
// `_paragraphOf` precedent but stopping short of rebuilding a fresh
// TextPainter: the order asks for "didExceedMaxLines on the live
// RenderParagraph" and board.dart's own chip text is pinned to
// TextScaler.noScaling with an explicit fontSize, so the live paragraph's
// resolved TextSpan already carries the number painted.
// ---------------------------------------------------------------------------

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

Finder _textFinderByData(Finder scope, String value) => find.descendant(
  of: scope,
  matching: find.byWidgetPredicate(
    (Widget widget) => widget is Text && _textOf(widget) == value,
  ),
);

RenderParagraph _paragraphOf(WidgetTester tester, Finder textFinder) {
  final Finder rich = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  return tester.renderObject<RenderParagraph>(rich);
}

/// The resolved fontSize of [paragraph]'s own text span, or null when its
/// span is not a plain TextSpan (never the case for the Text widgets this
/// file reads, which all set an explicit style).
double? _paintedFontSize(RenderParagraph paragraph) {
  final InlineSpan span = paragraph.text;
  return span is TextSpan ? span.style?.fontSize : null;
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// Decision 4/5: captures every `FlutterError.onError` call during [body]
/// instead of letting it hit the zone's default handler (which would fail
/// the test on its own, before this file's own assertions get to speak),
/// and restores the previous handler before returning, success or not.
Future<List<FlutterErrorDetails>> _withCapturedFlutterErrors(
  Future<void> Function() body,
) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final void Function(FlutterErrorDetails details)? previous =
      FlutterError.onError;
  FlutterError.onError = captured.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return captured;
}

void main() {
  setUpAll(_loadAppFonts);

  // ===========================================================================
  // X53: own seat's turn on the game screen. The board's width, whether the
  // own-seat chip's name is ellipsized, and the painted font size of the
  // name and of board-seat-you.
  // ===========================================================================
  group('X53: own seat chip at large text', () {
    for (final Size surface in _surfaces) {
      final String surfaceLabel = _surfaceLabel(surface);

      for (final double scale in _scales) {
        final String scaleLabel = scale.toStringAsFixed(1);

        for (final Locale locale in _locales) {
          final String label =
              'X53 ${locale.languageCode} $surfaceLabel scale $scaleLabel';

          testWidgets(label, (tester) async {
            await _surface(tester, surface, (_Keep keep) async {
              final (RoomController controller, _) = await _connectGame(
                tester,
                keep,
                seats: _twoSeats(),
                turn: _turnJson(seat: 0, phase: 'await_roll'),
              );
              await _mountGame(
                tester,
                controller,
                locale: locale,
                textScale: scale,
              );

              final double boardWidth = tester
                  .getSize(find.byKey(_boardKey))
                  .width;

              final Finder nameChip = find.byKey(
                const Key('board-seat-name-0'),
              );
              expect(
                nameChip,
                findsOneWidget,
                reason:
                    'fixture ($label): board-seat-name-0 must be on the '
                    'board',
              );
              final Finder nameText = _textFinderByData(nameChip, _mySeatName);
              expect(
                nameText,
                findsOneWidget,
                reason:
                    'fixture ($label): seat 0 name text "$_mySeatName" '
                    'must be inside its chip',
              );
              final RenderParagraph nameParagraph = _paragraphOf(
                tester,
                nameText,
              );
              final bool nameEllipsized = nameParagraph.didExceedMaxLines;
              final double? nameFontSize = _paintedFontSize(nameParagraph);

              final Finder youText = find.byKey(const Key('board-seat-you'));
              expect(
                youText,
                findsOneWidget,
                reason:
                    'fixture ($label): board-seat-you must be in seat 0\'s '
                    'chip',
              );
              final RenderParagraph youParagraph = _paragraphOf(
                tester,
                youText,
              );
              final bool youEllipsized = youParagraph.didExceedMaxLines;
              final double? youFontSize = _paintedFontSize(youParagraph);

              _print(
                'CASE $label boardWidth=${boardWidth.toStringAsFixed(1)} '
                'nameEllipsized=$nameEllipsized '
                'nameFontSize=${nameFontSize?.toStringAsFixed(1)} '
                'youEllipsized=$youEllipsized '
                'youFontSize=${youFontSize?.toStringAsFixed(1)}',
              );

              expect(
                nameEllipsized,
                isFalse,
                reason:
                    '$label: own seat name "$_mySeatName" must not be '
                    'ellipsized (board width '
                    '${boardWidth.toStringAsFixed(1)})',
              );
              expect(
                youFontSize,
                isNotNull,
                reason:
                    '$label: board-seat-you must resolve a TextSpan with an '
                    'explicit fontSize',
              );
              expect(
                youFontSize!,
                greaterThanOrEqualTo(9.0),
                reason:
                    '$label: "You" painted font size '
                    '${youFontSize.toStringAsFixed(1)} must be at least 9 '
                    '(board width ${boardWidth.toStringAsFixed(1)})',
              );
            });
          });
        }
      }
    }
  });

  // ===========================================================================
  // X52: host lobby, both seats taken. Whether each seat card's name
  // paragraph is ellipsized.
  // ===========================================================================
  group('X52: lobby seat cards at large text', () {
    for (final Size surface in _surfaces) {
      final String surfaceLabel = _surfaceLabel(surface);

      for (final double scale in _scales) {
        final String scaleLabel = scale.toStringAsFixed(1);

        for (final Locale locale in _locales) {
          final String label =
              'X52 ${locale.languageCode} $surfaceLabel scale $scaleLabel';

          testWidgets(label, (tester) async {
            await _surface(tester, surface, (_Keep keep) async {
              await _mountLobby(tester, keep, locale: locale, textScale: scale);

              final Map<int, bool> ellipsizedBySeat = <int, bool>{};
              for (final (int seat, String name) in <(int, String)>[
                (0, _mySeatName),
                (1, _otherSeatName),
              ]) {
                final Finder card = find.byKey(Key('lobby-seat-$seat'));
                expect(
                  card,
                  findsOneWidget,
                  reason:
                      'fixture ($label): lobby-seat-$seat must be on '
                      'screen',
                );
                final Finder nameText = _textFinderByData(card, name);
                expect(
                  nameText,
                  findsOneWidget,
                  reason:
                      'fixture ($label): seat $seat name text "$name" '
                      'must be inside lobby-seat-$seat',
                );
                final RenderParagraph paragraph = _paragraphOf(
                  tester,
                  nameText,
                );
                ellipsizedBySeat[seat] = paragraph.didExceedMaxLines;
              }

              _print(
                'CASE $label seat0Ellipsized=${ellipsizedBySeat[0]} '
                'seat1Ellipsized=${ellipsizedBySeat[1]}',
              );

              expect(
                ellipsizedBySeat[0],
                isFalse,
                reason:
                    '$label: seat 0 name "$_mySeatName" must not be '
                    'ellipsized on its lobby seat card',
              );
              expect(
                ellipsizedBySeat[1],
                isFalse,
                reason:
                    '$label: seat 1 name "$_otherSeatName" must not be '
                    'ellipsized on its lobby seat card',
              );
            });
          });
        }
      }
    }
  });

  // ===========================================================================
  // Order 346, group A: C-347 (X52) acceptance, host lobby, mounted the way
  // this file already mounts it. No implementation of C-347 exists on this
  // base; per the order, A1 is expected to pass (decision 2's two-up case
  // is also today's only layout) and A2/A3 are expected to fail (today's
  // grid is always two-up, never one-up).
  // ===========================================================================
  group('A: C-347 (X52) decisions', () {
    // A1. Decision 2: two 10-character names stay two to a row at 1.3 on
    // 411x704 (the measurement in C-347 says this fits).
    for (final Locale locale in _locales) {
      final String label =
          'A1 (C-347 decision 2) ${locale.languageCode} 411x704 scale 1.3';

      testWidgets(label, (tester) async {
        await _surface(tester, const Size(411, 704), (_Keep keep) async {
          await _mountLobby(tester, keep, locale: locale, textScale: 1.3);

          final Offset top0 = tester.getTopLeft(
            find.byKey(const Key('lobby-seat-0')),
          );
          final Offset top1 = tester.getTopLeft(
            find.byKey(const Key('lobby-seat-1')),
          );
          final double topDelta = (top1.dy - top0.dy).abs();

          _print(
            'CASE $label top0=${top0.dy.toStringAsFixed(1)} '
            'top1=${top1.dy.toStringAsFixed(1)} '
            'topDelta=${topDelta.toStringAsFixed(1)}',
          );

          expect(
            topDelta,
            lessThanOrEqualTo(1.0),
            reason:
                '$label: C-347 decision 2 says these two cards share one '
                'row (top delta ${topDelta.toStringAsFixed(1)}dp)',
          );
        });
      });
    }

    // A2. Decision 1: the same two names no longer fit two-up at 2.0 on
    // 360x640, so each gets its own row, seat 0 above seat 1, both the
    // same width.
    for (final Locale locale in _locales) {
      final String label =
          'A2 (C-347 decision 1) ${locale.languageCode} 360x640 scale 2.0';

      testWidgets(label, (tester) async {
        await _surface(tester, const Size(360, 640), (_Keep keep) async {
          await _mountLobby(tester, keep, locale: locale, textScale: 2.0);

          final Offset top0 = tester.getTopLeft(
            find.byKey(const Key('lobby-seat-0')),
          );
          final Offset top1 = tester.getTopLeft(
            find.byKey(const Key('lobby-seat-1')),
          );
          final double width0 = tester
              .getSize(find.byKey(const Key('lobby-seat-0')))
              .width;
          final double width1 = tester
              .getSize(find.byKey(const Key('lobby-seat-1')))
              .width;
          final double topGap = top1.dy - top0.dy;
          final double widthDelta = (width0 - width1).abs();

          _print(
            'CASE $label top0=${top0.dy.toStringAsFixed(1)} '
            'top1=${top1.dy.toStringAsFixed(1)} '
            'topGap=${topGap.toStringAsFixed(1)} '
            'width0=${width0.toStringAsFixed(1)} '
            'width1=${width1.toStringAsFixed(1)}',
          );

          expect(
            topGap,
            greaterThan(1.0),
            reason:
                '$label: C-347 decision 1 says a name that no longer fits '
                'two-up puts seat 1 strictly below seat 0 (top0 '
                '${top0.dy.toStringAsFixed(1)}, top1 '
                '${top1.dy.toStringAsFixed(1)})',
          );
          expect(
            widthDelta,
            lessThanOrEqualTo(1.0),
            reason:
                '$label: one-card-per-row still means the same card width '
                '(width0 ${width0.toStringAsFixed(1)}, width1 '
                '${width1.toStringAsFixed(1)})',
          );
        });
      });
    }

    // A3. Decision 1, the whole grid at once: 4 seated, three short names
    // and one that fits a full-width card at 1.0 but not a half-width one.
    // The candidate name's width is measured against both, as fixture
    // sanity, with the seat card's own ambient text style and scaler
    // (read off a live name paragraph already on screen) rather than any
    // guessed font metric.
    testWidgets('A3 (C-347 decision 1, whole grid) en 360x640 scale 1.0', (
      tester,
    ) async {
      const String label =
          'A3 (C-347 decision 1, whole grid) en 360x640 scale 1.0';
      const String longName = 'AlexanderChristoph';

      await _surface(tester, const Size(360, 640), (_Keep keep) async {
        await _mountLobby(
          tester,
          keep,
          locale: const Locale('en'),
          textScale: 1.0,
          players: 4,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: _shortNameA),
            _seatJson(1, name: _shortNameB),
            _seatJson(2, name: _shortNameC),
            _seatJson(3, name: longName),
          ],
        );

        final Finder shortNameFinder = _textFinderByData(
          find.byKey(const Key('lobby-seat-0')),
          _shortNameA,
        );
        expect(
          shortNameFinder,
          findsOneWidget,
          reason:
              'fixture ($label): seat 0 name "$_shortNameA" must be '
              'inside lobby-seat-0',
        );
        final RenderParagraph shortParagraph = _paragraphOf(
          tester,
          shortNameFinder,
        );
        final TextStyle? ambientStyle = (shortParagraph.text as TextSpan).style;
        expect(
          ambientStyle,
          isNotNull,
          reason:
              'fixture ($label): seat 0 name must resolve a TextSpan '
              'with a style',
        );
        final TextScaler ambientScaler = shortParagraph.textScaler;

        double naturalWidth(String text) {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: text, style: ambientStyle),
            textDirection: TextDirection.ltr,
            textScaler: ambientScaler,
            maxLines: 1,
          )..layout();
          return painter.width;
        }

        final Finder longNameFinder = _textFinderByData(
          find.byKey(const Key('lobby-seat-3')),
          longName,
        );
        expect(
          longNameFinder,
          findsOneWidget,
          reason:
              'fixture ($label): seat 3 name "$longName" must be '
              'inside lobby-seat-3',
        );

        final double halfCardWidth = tester
            .getSize(find.byKey(const Key('lobby-seat-0')))
            .width;
        // The name sits under two nested `Expanded`s (seat_card.dart's own,
        // then lobby_screen.dart's row-level one): `.first` is the nearer
        // one, whose width is the half-width card's own text column.
        final double halfAvailable = tester
            .getSize(
              find
                  .ancestor(
                    of: shortNameFinder,
                    matching: find.byType(Expanded),
                  )
                  .first,
            )
            .width;
        // Today's grid is always two cards to a row: a row's own total
        // width is 2 * halfCardWidth + kSpace2 (the gap the Row puts
        // between the two Expanded cards). The furniture around the
        // name (token disc, paddings, gap) is fixed regardless of card
        // width, so it cancels out of the difference between the two
        // available widths.
        final double fullAvailable = halfAvailable + halfCardWidth + kSpace2;
        final double candidateWidth = naturalWidth(longName);

        _print(
          'CASE $label halfAvailable=${halfAvailable.toStringAsFixed(1)} '
          'fullAvailable=${fullAvailable.toStringAsFixed(1)} '
          'candidateWidth=${candidateWidth.toStringAsFixed(1)}',
        );

        expect(
          candidateWidth,
          greaterThan(halfAvailable),
          reason:
              'fixture ($label): candidate name "$longName" '
              '(${candidateWidth.toStringAsFixed(1)}dp) must not fit a '
              'half-width card (${halfAvailable.toStringAsFixed(1)}dp '
              'available) -- pick a longer name',
        );
        expect(
          candidateWidth,
          lessThanOrEqualTo(fullAvailable),
          reason:
              'fixture ($label): candidate name "$longName" '
              '(${candidateWidth.toStringAsFixed(1)}dp) must fit a '
              'full-width card (${fullAvailable.toStringAsFixed(1)}dp '
              'available) -- pick a shorter name',
        );

        final List<double> widths = <double>[
          for (int seat = 0; seat < 4; seat++)
            tester.getSize(find.byKey(Key('lobby-seat-$seat'))).width,
        ];
        final double maxWidth = widths.reduce(math.max);
        final double minWidth = widths.reduce(math.min);
        expect(
          maxWidth - minWidth,
          lessThanOrEqualTo(1.0),
          reason:
              '$label: every seat card must be the same width, got '
              '$widths',
        );

        final List<double> tops = <double>[
          for (int seat = 0; seat < 4; seat++)
            tester.getTopLeft(find.byKey(Key('lobby-seat-$seat'))).dy,
        ];
        for (int i = 1; i < tops.length; i++) {
          expect(
            tops[i] - tops[i - 1],
            greaterThan(1.0),
            reason:
                '$label: seat $i must be strictly below seat ${i - 1} '
                '(list order top to bottom, one card per row); tops='
                '$tops',
          );
        }

        final RenderParagraph longParagraph = _paragraphOf(
          tester,
          longNameFinder,
        );
        expect(
          longParagraph.didExceedMaxLines,
          isFalse,
          reason:
              '$label: the long name "$longName" must not be ellipsized '
              'once the grid switches to one card per row',
        );
      });
    });

    // A4. Decision 4: a 40-character name still ellipsizes, and mounting
    // it raises no FlutterError.
    testWidgets('A4 (C-347 decision 4) en 360x640 scale 2.0, 40-char name', (
      tester,
    ) async {
      const String label =
          'A4 (C-347 decision 4) en 360x640 scale 2.0, 40-char name';

      await _surface(tester, const Size(360, 640), (_Keep keep) async {
        final List<FlutterErrorDetails> errors =
            await _withCapturedFlutterErrors(() async {
              await _mountLobby(
                tester,
                keep,
                locale: const Locale('en'),
                textScale: 2.0,
                seats: <Map<String, Object?>>[
                  _seatJson(0, name: _longName40),
                  _seatJson(1, name: _otherSeatName),
                ],
              );
            });

        final Finder nameFinder = _textFinderByData(
          find.byKey(const Key('lobby-seat-0')),
          _longName40,
        );
        expect(
          nameFinder,
          findsOneWidget,
          reason:
              'fixture ($label): seat 0 name "$_longName40" must be '
              'inside lobby-seat-0',
        );
        final RenderParagraph paragraph = _paragraphOf(tester, nameFinder);

        _print(
          'CASE $label ellipsized=${paragraph.didExceedMaxLines} '
          'flutterErrors=${errors.length}',
        );

        expect(
          errors,
          isEmpty,
          reason:
              '$label: mounting a 40-character name must raise no '
              'FlutterError, got ${errors.length}: '
              '${errors.map((e) => e.exceptionAsString()).join('; ')}',
        );
        expect(
          paragraph.didExceedMaxLines,
          isTrue,
          reason:
              '$label: a 40-character name must still ellipsize on a '
              'full-width card (C-264 B4)',
        );
      });
    });

    // A5. Decision 5: four seated, 10-character names, en and ar: no
    // FlutterError, every name whole, host start control reachable and
    // then hit-testable.
    for (final Locale locale in _locales) {
      final String label =
          'A5 (C-347 decision 5) ${locale.languageCode} 360x640 scale 2.0';

      testWidgets(label, (tester) async {
        await _surface(tester, const Size(360, 640), (_Keep keep) async {
          final List<FlutterErrorDetails> errors =
              await _withCapturedFlutterErrors(() async {
                await _mountLobby(
                  tester,
                  keep,
                  locale: locale,
                  textScale: 2.0,
                  players: 4,
                  seats: <Map<String, Object?>>[
                    _seatJson(0, name: _mySeatName),
                    _seatJson(1, name: _otherSeatName),
                    _seatJson(2, name: _thirdSeatName),
                    _seatJson(3, name: _fourthSeatName),
                  ],
                );
              });

          final Map<int, bool> ellipsizedBySeat = <int, bool>{};
          for (final (int seat, String name) in <(int, String)>[
            (0, _mySeatName),
            (1, _otherSeatName),
            (2, _thirdSeatName),
            (3, _fourthSeatName),
          ]) {
            final Finder nameFinder = _textFinderByData(
              find.byKey(Key('lobby-seat-$seat')),
              name,
            );
            expect(
              nameFinder,
              findsOneWidget,
              reason:
                  'fixture ($label): seat $seat name "$name" must be '
                  'inside lobby-seat-$seat',
            );
            ellipsizedBySeat[seat] = _paragraphOf(
              tester,
              nameFinder,
            ).didExceedMaxLines;
          }

          _print(
            'CASE $label seat0Ellipsized=${ellipsizedBySeat[0]} '
            'seat1Ellipsized=${ellipsizedBySeat[1]} '
            'seat2Ellipsized=${ellipsizedBySeat[2]} '
            'seat3Ellipsized=${ellipsizedBySeat[3]} '
            'flutterErrors=${errors.length}',
          );

          expect(
            errors,
            isEmpty,
            reason:
                '$label: mounting a full 4-seat room at scale 2.0 must '
                'raise no FlutterError, got ${errors.length}: '
                '${errors.map((e) => e.exceptionAsString()).join('; ')}',
          );
          for (final int seat in <int>[0, 1, 2, 3]) {
            expect(
              ellipsizedBySeat[seat],
              isFalse,
              reason: '$label: seat $seat name must be whole',
            );
          }

          final Finder startButton = find.byKey(
            const Key('lobby-start-button'),
          );
          expect(
            startButton,
            findsOneWidget,
            reason: '$label: a 4-of-4 host room must show lobby-start-button',
          );
          await tester.ensureVisible(startButton);
          await tester.pump();
          expect(
            startButton.hitTestable(),
            findsOneWidget,
            reason:
                '$label: lobby-start-button must be hit-testable once '
                'scrolled into view',
          );
        });
      });
    }

    // A6. An offline seat (Icons.wifi_off, not colour alone) keeps its
    // name whole at 1.3 on 411x704.
    testWidgets('A6 (offline seat) en 411x704 scale 1.3', (tester) async {
      const String label = 'A6 (offline seat) en 411x704 scale 1.3';

      await _surface(tester, const Size(411, 704), (_Keep keep) async {
        await _mountLobby(
          tester,
          keep,
          locale: const Locale('en'),
          textScale: 1.3,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: _otherSeatName),
            _seatJson(1, name: _mySeatName, connected: false),
          ],
        );

        final Finder card = find.byKey(const Key('lobby-seat-1'));
        expect(
          find.descendant(of: card, matching: find.byIcon(Icons.wifi_off)),
          findsOneWidget,
          reason:
              'fixture ($label): lobby-seat-1 must show Icons.wifi_off '
              'when connected is false',
        );

        final Finder nameFinder = _textFinderByData(card, _mySeatName);
        expect(
          nameFinder,
          findsOneWidget,
          reason:
              'fixture ($label): seat 1 name "$_mySeatName" must be '
              'inside lobby-seat-1',
        );
        final bool ellipsized = _paragraphOf(
          tester,
          nameFinder,
        ).didExceedMaxLines;

        _print('CASE $label ellipsized=$ellipsized');

        expect(
          ellipsized,
          isFalse,
          reason:
              "$label: an offline seat's name \"$_mySeatName\" must "
              'still be whole at 1.3 on 411x704',
        );
      });
    });
  });

  // ===========================================================================
  // Order 346, group B: X53 measurement, the board alone. No implementation
  // of X53 exists or is ordered; this group measures and prints, asserting
  // only that the own-seat name is not ellipsized.
  // ===========================================================================
  group('B: X53 measurement, board alone at a range of widths', () {
    const List<double> boardWidths = <double>[300, 312, 325, 344, 395];
    const List<double> boardScales = <double>[1.0, 2.0];

    for (final double width in boardWidths) {
      for (final double scale in boardScales) {
        for (final Locale locale in _locales) {
          final String label =
              'B (X53 board alone) ${locale.languageCode} '
              'W=${width.toInt()} scale ${scale.toStringAsFixed(1)}';

          testWidgets(label, (tester) async {
            await tester.pumpWidget(
              _harness(
                Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      height: width,
                      child: Builder(
                        builder: (BuildContext context) {
                          final AppLocalizations loc = AppLocalizations.of(
                            context,
                          );
                          return LudoBoard(
                            tokens: const <int, List<int>>{
                              0: <int>[-1, -1, -1, -1],
                              1: <int>[-1, -1, -1, -1],
                            },
                            seatsInPlay: const <int>[0, 1],
                            mySeat: 0,
                            seatNames: const <int, String>{
                              0: _mySeatName,
                              1: _otherSeatName,
                            },
                            youLabel: loc.seatYou,
                          );
                        },
                      ),
                    ),
                  ),
                ),
                locale: locale,
                textScale: scale,
              ),
            );
            await tester.pump();

            final Finder nameChip = find.byKey(const Key('board-seat-name-0'));
            expect(
              nameChip,
              findsOneWidget,
              reason:
                  'fixture ($label): board-seat-name-0 must be on the board',
            );
            final Finder nameText = _textFinderByData(nameChip, _mySeatName);
            expect(
              nameText,
              findsOneWidget,
              reason:
                  'fixture ($label): seat 0 name text "$_mySeatName" must '
                  'be inside its chip',
            );
            final RenderParagraph nameParagraph = _paragraphOf(
              tester,
              nameText,
            );
            final bool nameEllipsized = nameParagraph.didExceedMaxLines;
            final double? nameFontSize = _paintedFontSize(nameParagraph);

            final Finder youText = find.byKey(const Key('board-seat-you'));
            expect(
              youText,
              findsOneWidget,
              reason:
                  "fixture ($label): board-seat-you must be in seat 0's "
                  'chip',
            );
            final RenderParagraph youParagraph = _paragraphOf(tester, youText);
            final double? youFontSize = _paintedFontSize(youParagraph);

            _print(
              'CASE $label nameEllipsized=$nameEllipsized '
              'nameFontSize=${nameFontSize?.toStringAsFixed(1)} '
              'youFontSize=${youFontSize?.toStringAsFixed(1)}',
            );

            expect(
              nameEllipsized,
              isFalse,
              reason:
                  '$label: own seat name "$_mySeatName" must not be '
                  'ellipsized (board width ${width.toStringAsFixed(1)})',
            );
          });
        }
      }
    }
  });

  // ===========================================================================
  // Order 346, group C: X53 measurement, the whole game screen with system
  // bars. Same mount as the file's own X53 game cases, with
  // tester.view.padding/viewPadding standing in for a phone's status and
  // navigation bars.
  // ===========================================================================
  group('C: X53 measurement, whole game screen with system bars', () {
    const FakeViewPadding systemBars = FakeViewPadding(top: 24, bottom: 48);

    for (final double scale in <double>[1.0, 2.0]) {
      for (final Locale locale in _locales) {
        final String label =
            'C (X53 game screen, system bars) ${locale.languageCode} '
            '411x704 scale ${scale.toStringAsFixed(1)}';

        testWidgets(label, (tester) async {
          await _surface(tester, const Size(411, 704), (_Keep keep) async {
            final (RoomController controller, _) = await _connectGame(
              tester,
              keep,
              seats: _twoSeats(),
              turn: _turnJson(seat: 0, phase: 'await_roll'),
            );
            await _mountGame(
              tester,
              controller,
              locale: locale,
              textScale: scale,
            );

            final double boardWidth = tester
                .getSize(find.byKey(_boardKey))
                .width;

            final Finder nameChip = find.byKey(const Key('board-seat-name-0'));
            expect(
              nameChip,
              findsOneWidget,
              reason:
                  'fixture ($label): board-seat-name-0 must be on the board',
            );
            final Finder nameText = _textFinderByData(nameChip, _mySeatName);
            expect(
              nameText,
              findsOneWidget,
              reason:
                  'fixture ($label): seat 0 name text "$_mySeatName" must '
                  'be inside its chip',
            );
            final RenderParagraph nameParagraph = _paragraphOf(
              tester,
              nameText,
            );
            final bool nameEllipsized = nameParagraph.didExceedMaxLines;

            _print(
              'CASE $label boardWidth=${boardWidth.toStringAsFixed(1)} '
              'nameEllipsized=$nameEllipsized',
            );

            expect(
              nameEllipsized,
              isFalse,
              reason:
                  '$label: own seat name "$_mySeatName" must not be '
                  'ellipsized under system-bar insets (board width '
                  '${boardWidth.toStringAsFixed(1)})',
            );
          }, insets: systemBars);
        });
      }
    }
  });
}
