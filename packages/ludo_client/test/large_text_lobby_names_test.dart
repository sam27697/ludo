// Order 350, run 89. Proves C-347's acceptance: lobby seat-card names at
// large text (group X52) and the five decisions C-347 made about that grid
// (group A). Split from test/large_text_names_test.dart, which also held
// the X53 own-seat-chip measurement (groups X53, B, C) -- nine cases red on
// a finding with no fix yet, which would turn main red if merged with
// C-347's half tonight. That half is unchanged, including this file's own
// provenance comments and helpers, on the pushed branch `measure/x53-chip`
// at 1c842bc; X53's work continues there.
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
// X52's seat-card name reading matches the order's own wording literally:
// ellipsis is read off the live RenderParagraph's own didExceedMaxLines,
// not a fresh TextPainter rebuilt from it. lobby_screen.dart / seat_card.dart
// set no font size and no textScaler on the name, so the ambient scale
// reaches it directly and this live-paragraph reading is sufficient.
//
// No pumpAndSettle inside a testWidgets body. No bare pumpEventQueue(). The
// controller is disposed in the test body.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart'
    show buildAppTheme, kSpace1, kSpace2, kSpace6;

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
/// `tester.view.viewPadding` (a real phone's system bars; no case in this
/// file sets it, the parameter stays with the shared helper), reset
/// alongside the physical size.
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
// didExceedMaxLines directly off it, following
// test/end_card_labels_fit_test.dart's own `_textFinder` / `_paragraphOf`
// precedent but stopping short of rebuilding a fresh TextPainter.
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
  // Group A: C-347's five decisions about the lobby seat-card grid, host
  // lobby, mounted the same way group X52 mounts it. C-347's code is
  // present on this branch; every case below runs against it and is green.
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
      const double surfaceWidth = 360;

      await _surface(tester, const Size(surfaceWidth, 640), (_Keep keep) async {
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

        // Fixture sanity: the half-width and full-width name boxes,
        // computed from the surface and the lobby's own geometry alone,
        // never read off the grid under test. (RETURN 1, run 89: today's
        // grid already lays out one card per row on the base this file
        // also runs against, so a live card picked up the full-width box
        // for both halfAvailable and fullAvailable, and the sanity check
        // below failed before any product assertion was reached.)
        //
        // lobby_screen.dart's `_connectedBody` pads its scroll body
        // `kSpace6` on each side (`EdgeInsets.fromLTRB(kSpace6, ...,
        // kSpace6, ...)`), so the grid itself gets `surfaceWidth - 2 *
        // kSpace6` (360 - 48 = 312 at this surface). `_seatGrid`'s two-up
        // row splits that width around one `kSpace2` gap between its two
        // `Expanded` cards; its one-up row hands a single `Expanded` the
        // whole grid width, no gap.
        //
        // Inside either card, seat_card.dart's `SeatCard.build` pads
        // `kSpace2` on each side, then reserves `kSpace6` for the token
        // disc's own slot and `kSpace1` for the gap after it before the
        // name's own `Expanded` starts. C-347 (c412e6d) renamed these three
        // literals to exported constants but did not change their values,
        // so the arithmetic below holds on both the base this file also
        // runs against and the tree under test.
        const double gridWidth = surfaceWidth - 2 * kSpace6;
        const double halfCardWidth = (gridWidth - kSpace2) / 2;
        const double fullCardWidth = gridWidth;
        double nameAvailable(double cardWidth) =>
            cardWidth - (2 * kSpace2) - kSpace6 - kSpace1;
        final double halfAvailable = nameAvailable(halfCardWidth);
        final double fullAvailable = nameAvailable(fullCardWidth);
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
}
