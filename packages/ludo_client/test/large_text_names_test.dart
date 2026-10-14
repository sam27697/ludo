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

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://large-text-names-test.invalid/ws';

// Both 10 characters, both accepted by the server's 1-24 character limit
// (packages/ludo_server/lib/src/registry.dart:411-412), distinct from each
// other so a text-data finder is never ambiguous.
const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
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

Map<String, Object?> _lobbyRoomJson() => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'LOBBY',
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
  'seats': _twoSeats(),
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

/// Mounts a host `LobbyScreen` (seat 0) for a 2-player room, pushes
/// `seat_assigned` then a `room` snapshot with both seats taken, and
/// settles the two pumps test/lobby_seat_cards_test.dart's own
/// `_mountConnectedLobby` uses before trusting the connected body.
Future<void> _mountLobby(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
  required double textScale,
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
        players: 2,
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
  transport.pushText(_frame(type: 'room', re: id, data: _lobbyRoomJson()));
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
Future<void> _surface(
  WidgetTester tester,
  Size size,
  Future<void> Function(_Keep keep) body,
) async {
  tester.view.physicalSize = size;
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
}
