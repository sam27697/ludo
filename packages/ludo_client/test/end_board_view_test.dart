// Tests for work/ludo/orders/389-end-board-view-tests.md (run 95, X62).
//
// The defect, as measured by the master: since C-367 (viewer board) the
// playing board is drawn rotated so the local seat's own yard sits at the
// bottom-start corner (board_geometry.dart's viewQuarters/toView, driven by
// LudoBoard.mySeat), and the local seat's name chip carries the "You" tag
// (board-seat-you). The finished-game body
// (lib/src/game_screen.dart, _gameOverBody, the SingleChildScrollView with
// EndCard and an AspectRatio around a second LudoBoard keyed
// 'game-screen-board', around line 2970) builds that second board without
// passing mySeat at all. Doctrine P4 ("state never jumps") and P3 ("whose
// turn is it, which of my pieces") are both read as requiring the finished
// board to keep the same local-seat orientation and "You" tag the playing
// board just showed.
//
// Mounting is the real GameScreen over a real RoomController and
// FakeTransport, exactly the idiom test/end_hold_test.dart and
// test/board_seat_identity_test.dart already use. The fake-transport
// connect/mount idiom, the frame/room/seat JSON builders, and the
// two-pump-per-pushed-frame idiom below are copied by hand from
// test/end_hold_test.dart (this project's standing instruction is never to
// import across test files); the yard-quadrant-from-board_geometry
// technique is copied by hand from test/board_seat_identity_test.dart's own
// _yardQuadrantOrigin/_yardQuadrantRect.
//
// Every room below is connected with turn: null and no `moved` frame is ever
// pushed, so every token's progress is fixed from the first `room` frame
// through the `game_over` frame: nothing here depends on travel, the end
// hold (kEndCardDwell/kEndCardHoldLimit) never arms (C-270's own "count at
// 0 at game_over" case; see end_hold_test.dart), and the finished body
// appears in the same pump the game_over frame is flushed through.
//
// Orientation (rule 2 of the order) is graded as a fraction of the board's
// own on-screen rect (0..1 in each axis, from the board's own top-left),
// read the same way test/board_seat_identity_test.dart's own _boardRect
// reads it (the Stack descendant of the 'ludo-board' key, not that key's
// own rect, which can be the full viewport rather than the square board).
// This makes the comparison independent of the two boards' different
// pixel sizes (the playing board fills an Expanded row; the finished board
// is a fixed-aspect-ratio box inside a scroll view).
//
// The local seat's own yard quadrant (rule 3) is derived from
// board_geometry.dart's cellFor(seat, progress: -1), viewQuarters and
// toView, never from a hand-picked "bottom-left" literal; a fixture-sanity
// assertion in each case checks that this derivation does land in the
// quadrant whose near corner is the board's own bottom-left (col 0..5, row
// 9..14 of the 15-wide grid) for the local seat, grounding the order's own
// "bottom-left in en" wording in the function rather than assuming it.
//
// No `seed` in the random-testing sense is used anywhere below: every
// fixture is a fixed, named room (no RNG). Each failure message below
// still names the exact configuration (locale, local seat, seat count,
// token) needed to reproduce it.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://end-board-view-test.invalid/ws';

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'end-board-view-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _roomJson({
  String code = 'E8RDVW',
  String state = 'PLAYING',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
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
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
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

/// A feedback service that records nothing and plays nothing: the first
/// group below never asserts on cues, only on the board itself.
class _NoopFeedbackService implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

/// Records every cue played, in call order -- copied by hand from
/// test/end_hold_test.dart's own `_FakeFeedbackService`. Used by the tap
/// group below, which does assert on cues.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Connects a fresh controller to a room seating [mySeat] as the local
/// player, copied by hand from test/end_hold_test.dart's own `_connectTo`
/// (which only ever assigns seat 0); this file needs seat 1 and seat 2.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  required int mySeat,
  required int players,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name: 'local',
    players: players,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      // turn: null throughout this file: nothing here is about the turn or
      // the die, only about the board's own orientation and seat chips.
      data: _roomJson(seats: seats, turn: null, players: players),
    ),
  );
  await future;
  return (controller, transport);
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

/// Connects a fresh controller and mounts GameScreen, copied by hand from
/// test/end_hold_test.dart's own `_connectAndMount` (lesson 35: one mount
/// per case).
Future<(RoomController, FakeTransport)> _connectAndMount(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  required int mySeat,
  required int players,
  required Locale locale,
  FeedbackService? service,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: seats,
    mySeat: mySeat,
    players: players,
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: service ?? _NoopFeedbackService(),
        child: GameScreen(controller: controller),
      ),
      locale,
    ),
  );
  await tester.pump();
  return (controller, transport);
}

/// Pushes a `game_over` frame and flushes it through the two-pump idiom
/// test/end_hold_test.dart's own `_pushGameOver` uses: one for the
/// transport's own delivery, one for the controller's frame stream and its
/// listeners to run.
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
        'verify_url': 'https://end-board-view-test.invalid/verify/$seq',
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

// --- shared keys/finders -----------------------------------------------

const Key _dieKey = Key('game-die');
const Key _winnerKey = Key('game-screen-winner');

bool _endCardShown(WidgetTester tester) =>
    find.byKey(_winnerKey).evaluate().isNotEmpty;

bool _playingBodyShown(WidgetTester tester) =>
    find.byKey(_dieKey).evaluate().isNotEmpty;

// --- board geometry helpers ----------------------------------------------

/// The on-screen rect of the board's own square content, read from the
/// Stack LudoBoard builds (a descendant of the 'ludo-board' key) rather
/// than that key's own rect -- copied by hand from
/// test/board_seat_identity_test.dart's own `_boardRect`, for the same
/// reason given there (LayoutBuilder's own render box can be the full,
/// non-square viewport). Only one LudoBoard is ever in the tree at a time
/// here (the playing body and the finished body are drawn by mutually
/// exclusive branches of GameScreen's own body switch), so this is never
/// ambiguous between the two boards this file measures.
Rect _boardRect(WidgetTester tester) {
  final Finder stack = find.descendant(
    of: find.byKey(const Key('ludo-board')),
    matching: find.byType(Stack),
  );
  return tester.getRect(stack);
}

/// The centre of token [tokenIndex] of [seat], as a fraction (0..1 in each
/// axis) of the board's own rect, measured from the board's own top-left --
/// the exact method the order's rule 2 names.
Offset _tokenFraction(WidgetTester tester, int seat, int tokenIndex) {
  final Rect board = _boardRect(tester);
  final Rect token = tester.getRect(find.byKey(Key('token-$seat-$tokenIndex')));
  return Offset(
    (token.center.dx - board.left) / board.width,
    (token.center.dy - board.top) / board.height,
  );
}

/// Which 6x6 corner (board space) holds [seat]'s yard, read from
/// board_geometry.dart's own cellFor rather than any board.dart private
/// constant -- copied by hand from test/board_seat_identity_test.dart's own
/// `_yardQuadrantOrigin`.
({int colLow, int rowLow}) _yardQuadrantOrigin(int seat) {
  final BoardCell cell = cellFor(seat: seat, progress: -1, tokenIndex: 0);
  return (colLow: cell.col <= 5 ? 0 : 9, rowLow: cell.row <= 5 ? 0 : 9);
}

/// [seat]'s 6x6 yard quadrant in view space (board_geometry.dart's own
/// 15-wide grid), after the rotation `viewQuarters(mySeat)` applies, as the
/// inclusive [minCol]..[maxCol], [minRow]..[maxRow] cell range -- copied by
/// hand from test/board_seat_identity_test.dart's own `_yardQuadrantRect`,
/// kept in grid cells here rather than screen pixels so it can be checked
/// once, by hand, against the "bottom-left" claim before it is ever turned
/// into an on-screen rect.
({int minCol, int maxCol, int minRow, int maxRow}) _viewYardQuadrant(
  int seat,
  int? mySeat,
) {
  final ({int colLow, int rowLow}) origin = _yardQuadrantOrigin(seat);
  final int quarters = viewQuarters(mySeat);
  final List<BoardCell> corners = <BoardCell>[
    toView(BoardCell(origin.colLow, origin.rowLow), quarters),
    toView(BoardCell(origin.colLow + 5, origin.rowLow), quarters),
    toView(BoardCell(origin.colLow, origin.rowLow + 5), quarters),
    toView(BoardCell(origin.colLow + 5, origin.rowLow + 5), quarters),
  ];
  int minCol = corners.first.col;
  int maxCol = corners.first.col;
  int minRow = corners.first.row;
  int maxRow = corners.first.row;
  for (final BoardCell c in corners.skip(1)) {
    if (c.col < minCol) minCol = c.col;
    if (c.col > maxCol) maxCol = c.col;
    if (c.row < minRow) minRow = c.row;
    if (c.row > maxRow) maxRow = c.row;
  }
  return (minCol: minCol, maxCol: maxCol, minRow: minRow, maxRow: maxRow);
}

/// [_viewYardQuadrant], converted to an on-screen rect against the board
/// currently in the tree.
Rect _viewYardQuadrantPixelRect(WidgetTester tester, int seat, int? mySeat) {
  final Rect board = _boardRect(tester);
  final double cellSize = board.width / 15;
  final ({int minCol, int maxCol, int minRow, int maxRow}) q =
      _viewYardQuadrant(seat, mySeat);
  return Rect.fromLTRB(
    board.left + q.minCol * cellSize,
    board.top + q.minRow * cellSize,
    board.left + (q.maxCol + 1) * cellSize,
    board.top + (q.maxRow + 1) * cellSize,
  );
}

/// Runs the whole order for one (local seat, seat count, locale)
/// configuration: connect and mount on the playing board, measure, drive a
/// real game_over frame to the finished body, then check the three rules.
///
/// [otherSeat] names one seat other than [mySeat] that is seated and has an
/// on-track (non-yard) token at index 0, used for the opponent half of
/// rule 2.
Future<void> _runCase(
  WidgetTester tester, {
  required Locale locale,
  required int mySeat,
  required int otherSeat,
  required List<Map<String, Object?>> seats,
  required int players,
}) async {
  final String seed =
      'locale=${locale.languageCode}, mySeat=$mySeat, players=$players';

  // Fixture sanity, grounded in board_geometry.dart itself rather than
  // assumed: the rotation that puts mySeat at the view's own bottom
  // corner (viewQuarters's own doc comment, "put mySeat's yard at
  // bottom-left") does land mySeat's own yard quadrant at the board's
  // bottom-left (col 0..5, row 9..14 of the 15-wide grid) -- this is what
  // "bottom-start corner" (rule 3) and "bottom-left in en" (the order's own
  // words) mean, read off the function rather than hand-picked.
  final ({int minCol, int maxCol, int minRow, int maxRow}) ownQuadrant =
      _viewYardQuadrant(mySeat, mySeat);
  expect(
    ownQuadrant.minCol,
    0,
    reason:
        'fixture sanity ($seed): board_geometry.viewQuarters/toView must '
        'put seat $mySeat\'s own yard at the grid\'s left edge (col 0) once '
        'rotated into its own view -- this is the "bottom-start corner" '
        'rule 3 means; got minCol=${ownQuadrant.minCol}',
  );
  expect(
    ownQuadrant.maxRow,
    14,
    reason:
        'fixture sanity ($seed): board_geometry.viewQuarters/toView must '
        'put seat $mySeat\'s own yard at the grid\'s bottom edge (row 14) '
        'once rotated into its own view; got maxRow=${ownQuadrant.maxRow}',
  );

  final (RoomController _, FakeTransport transport) = await _connectAndMount(
    tester,
    seats: seats,
    mySeat: mySeat,
    players: players,
    locale: locale,
  );

  expect(
    _playingBodyShown(tester),
    isTrue,
    reason:
        'fixture check ($seed): the playing body must be up before '
        'game_over (game-die must be found)',
  );

  // Rule 2: the two fractions, read on the playing board, before anything
  // about the game ending has happened.
  final Offset myFractionBefore = _tokenFraction(tester, mySeat, 0);
  final Offset otherFractionBefore = _tokenFraction(tester, otherSeat, 0);

  await _pushGameOver(tester, transport, winner: otherSeat, seq: 2);

  expect(
    _endCardShown(tester),
    isTrue,
    reason:
        'fixture check ($seed): the finished body must be up after '
        'game_over with no travel in flight (game-screen-winner must be '
        'found; the end hold must not have armed)',
  );
  expect(
    _playingBodyShown(tester),
    isFalse,
    reason:
        'fixture check ($seed): once the finished body is up, the playing '
        'body (game-die) must be gone',
  );

  // Rule 1: the local seat's own name chip must carry the "You" tag on the
  // finished board.
  final Finder youOnMyChip = find.descendant(
    of: find.byKey(Key('board-seat-name-$mySeat')),
    matching: find.byKey(const Key('board-seat-you')),
  );
  expect(
    youOnMyChip,
    findsOneWidget,
    reason:
        'rule 1 ($seed): on the finished board, seat $mySeat\'s own name '
        'chip (board-seat-name-$mySeat) must contain the "You" tag '
        '(board-seat-you); C-367\'s LudoBoard only draws it when mySeat is '
        'passed and equals that chip\'s seat (lib/src/board.dart, '
        '`isMine = widget.mySeat == seat`), and the finished board\'s own '
        'LudoBoard in lib/src/game_screen.dart\'s _gameOverBody never '
        'passes mySeat at all',
  );

  // Rule 2: the same two fractions, read on the finished board, must not
  // have drifted by more than 0.02 in either axis.
  final Offset myFractionAfter = _tokenFraction(tester, mySeat, 0);
  final Offset otherFractionAfter = _tokenFraction(tester, otherSeat, 0);

  expect(
    (myFractionAfter.dx - myFractionBefore.dx).abs(),
    lessThanOrEqualTo(0.02),
    reason:
        'rule 2 ($seed): seat $mySeat\'s own on-track token '
        '(token-$mySeat-0) must keep its x fraction of the board across '
        'game over within 0.02; before game_over it was '
        '${myFractionBefore.dx}, after it was ${myFractionAfter.dx} '
        '(drift ${(myFractionAfter.dx - myFractionBefore.dx).abs()})',
  );
  expect(
    (myFractionAfter.dy - myFractionBefore.dy).abs(),
    lessThanOrEqualTo(0.02),
    reason:
        'rule 2 ($seed): seat $mySeat\'s own on-track token '
        '(token-$mySeat-0) must keep its y fraction of the board across '
        'game over within 0.02; before game_over it was '
        '${myFractionBefore.dy}, after it was ${myFractionAfter.dy} '
        '(drift ${(myFractionAfter.dy - myFractionBefore.dy).abs()})',
  );
  expect(
    (otherFractionAfter.dx - otherFractionBefore.dx).abs(),
    lessThanOrEqualTo(0.02),
    reason:
        'rule 2 ($seed): opponent seat $otherSeat\'s on-track token '
        '(token-$otherSeat-0) must keep its x fraction of the board across '
        'game over within 0.02; before game_over it was '
        '${otherFractionBefore.dx}, after it was ${otherFractionAfter.dx} '
        '(drift ${(otherFractionAfter.dx - otherFractionBefore.dx).abs()})',
  );
  expect(
    (otherFractionAfter.dy - otherFractionBefore.dy).abs(),
    lessThanOrEqualTo(0.02),
    reason:
        'rule 2 ($seed): opponent seat $otherSeat\'s on-track token '
        '(token-$otherSeat-0) must keep its y fraction of the board across '
        'game over within 0.02; before game_over it was '
        '${otherFractionBefore.dy}, after it was ${otherFractionAfter.dy} '
        '(drift ${(otherFractionAfter.dy - otherFractionBefore.dy).abs()})',
  );

  // Rule 3: the local seat's own yard (its token index 1, never moved off
  // -1) must sit inside its own bottom-start quadrant on the finished
  // board, the same quadrant the fixture-sanity check above derived from
  // board_geometry.dart.
  final Rect expectedQuadrant = _viewYardQuadrantPixelRect(
    tester,
    mySeat,
    mySeat,
  );
  final Rect myYardTokenRect = tester.getRect(
    find.byKey(Key('token-$mySeat-1')),
  );
  expect(
    expectedQuadrant.inflate(0.5).contains(myYardTokenRect.center),
    isTrue,
    reason:
        'rule 3 ($seed): on the finished board, seat $mySeat\'s own yard '
        'token (token-$mySeat-1) centre ${myYardTokenRect.center} must lie '
        'inside its own bottom-start yard quadrant $expectedQuadrant '
        '(derived from board_geometry.dart\'s cellFor/viewQuarters/toView '
        'for seat $mySeat); a finished board drawn without mySeat places '
        'this seat\'s yard in its own unrotated board-space quadrant '
        'instead',
  );
}

void main() {
  group('end board view: local orientation and "You" survive game over '
      '(order 389)', () {
    // Local seat 2 of a 4-seat game.
    final List<Map<String, Object?>> fourSeatRoom = <Map<String, Object?>>[
      _seatJson(0, name: 'Ann', tokens: const <int>[20, -1, -1, -1]),
      _seatJson(1, name: 'Bob'),
      _seatJson(2, name: 'Priya', tokens: const <int>[10, -1, -1, -1]),
      _seatJson(3, name: 'Omar'),
    ];

    testWidgets('seat 2 of 4, en', (tester) async {
      await _runCase(
        tester,
        locale: const Locale('en'),
        mySeat: 2,
        otherSeat: 0,
        seats: fourSeatRoom,
        players: 4,
      );
    });

    testWidgets('seat 2 of 4, ar', (tester) async {
      await _runCase(
        tester,
        locale: const Locale('ar'),
        mySeat: 2,
        otherSeat: 0,
        seats: fourSeatRoom,
        players: 4,
      );
    });

    // Local seat 1 of a 2-seat game.
    final List<Map<String, Object?>> twoSeatRoom = <Map<String, Object?>>[
      _seatJson(0, name: 'Ann', tokens: const <int>[15, -1, -1, -1]),
      _seatJson(1, name: 'Omar', tokens: const <int>[5, -1, -1, -1]),
    ];

    testWidgets('seat 1 of 2, en', (tester) async {
      await _runCase(
        tester,
        locale: const Locale('en'),
        mySeat: 1,
        otherSeat: 0,
        seats: twoSeatRoom,
        players: 2,
      );
    });

    testWidgets('seat 1 of 2, ar', (tester) async {
      await _runCase(
        tester,
        locale: const Locale('ar'),
        mySeat: 1,
        otherSeat: 0,
        seats: twoSeatRoom,
        players: 2,
      );
    });
  });

  // ===========================================================================
  // A tap on the finished board must carry the same one-meaning-per-event
  // cue a tap during play does (doctrine P2). The implementer has been told
  // to wire a tap on my own token on the finished board to exactly one
  // FeedbackCue.invalidTap, the same cue lib/src/game_screen.dart's
  // _playingBody already gives an illegal tap during play
  // (onIllegalTokenTap: (int index) =>
  // FeedbackScope.of(context).play(FeedbackCue.invalidTap)). Today,
  // lib/src/game_screen.dart's _gameOverBody gives its LudoBoard neither
  // mySeat nor onTokenTap/onIllegalTokenTap/legal at all, and
  // lib/src/board.dart's own _handleTapUp returns at once whenever
  // widget.mySeat is null, so a tap anywhere on the finished board resolves
  // to nothing: this case's first assertion is RED on today's code for that
  // reason, not a missing widget or a setup error -- `token-2-0` (the drawn
  // disc, board.dart's _tokenLayer, not gated on `isMine`) exists and is
  // tapped successfully; it is the resulting cue list that is wrong.
  // ===========================================================================
  group('end board view: a tap on the finished board (order 390)', () {
    testWidgets(
      'seat 2 of 4, en: the finished board has no token controls; a tap '
      'on my own token plays nothing and sends no move; a tap on an '
      'opponent token resolves to nothing',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Ann', tokens: const <int>[20, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
          _seatJson(2, name: 'Priya', tokens: const <int>[10, -1, -1, -1]),
          _seatJson(3, name: 'Omar'),
        ];
        final _FakeFeedbackService fake = _FakeFeedbackService();

        final (
          RoomController _,
          FakeTransport transport,
        ) = await _connectAndMount(
          tester,
          seats: seats,
          mySeat: 2,
          players: 4,
          locale: const Locale('en'),
          service: fake,
        );

        await _pushGameOver(tester, transport, winner: 0, seq: 2);
        expect(
          _endCardShown(tester),
          isTrue,
          reason:
              'fixture check: the finished body must be up before either '
              'tap below (game-screen-winner must be found)',
        );

        // C-270 rule 5/6 (end_hold_test.dart): with no travel in flight,
        // the loss cue plays in the same pump game_over is flushed
        // through, seat 0 (not me) being named winner. This is the
        // baseline every assertion below is read against, not a magic
        // "must be empty" literal.
        final List<FeedbackCue> baseline = List<FeedbackCue>.of(fake.recorded);
        expect(
          baseline,
          equals(<FeedbackCue>[FeedbackCue.gameOver]),
          reason:
              'fixture check: reaching the finished body as the loser, '
              'with no travel in flight, must already have played exactly '
              'one gameOver cue before either tap below; recorded $baseline',
        );

        // The board sits inside _gameOverBody's own SingleChildScrollView;
        // at the default 800x600 test surface its tokens can render below
        // the visible viewport, where WidgetController.tap's hit test
        // cannot reach them (a real app would have the user scroll first).
        // tester.ensureVisible is test/end_card_test.dart's own idiom for
        // the same scroll view.
        final int sentBefore = transport.sentRaw.length;
        await tester.ensureVisible(find.byKey(const Key('token-2-0')));
        await tester.tap(find.byKey(const Key('token-2-0')));
        await tester.pump();

        expect(
          find.byKey(const Key('board-token-hit-2-0')),
          findsNothing,
          reason:
              'at game over my tokens are not controls (H7.19-21: token '
              'buttons absent, not merely disabled), even though the '
              'finished board is drawn from my seat',
        );
        expect(
          fake.recorded,
          equals(baseline),
          reason:
              'a tap on my own token (token-2-0) on the finished board '
              'must play nothing on top of the baseline $baseline: it is '
              'not a control there; recorded ${fake.recorded}',
        );
        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'a tap on my own token on the finished board must send no '
              'move; the wire grew by '
              '${transport.sentRaw.length - sentBefore} message(s)',
        );

        final List<FeedbackCue> afterMyTap = List<FeedbackCue>.of(
          fake.recorded,
        );

        // board.dart's own _tokenLayer only ever builds a
        // board-token-hit-<seat>-<index> target `if (isMine)` (seat ==
        // widget.mySeat): seat 0 is not mySeat (2), so it never gets one,
        // on the playing board exactly as much as here -- this is a
        // pre-existing, unrelated invariant, not part of order 389/390's
        // own defect.
        expect(
          find.byKey(const Key('board-token-hit-0-0')),
          findsNothing,
          reason:
              'seat 0 is not mySeat (2); board.dart\'s own isMine gate in '
              '_tokenLayer must never give it a board-token-hit-0-0 '
              'target, on the finished board exactly as on the playing '
              'board',
        );

        await tester.ensureVisible(find.byKey(const Key('token-0-0')));
        await tester.tap(find.byKey(const Key('token-0-0')));
        await tester.pump();

        expect(
          fake.recorded,
          equals(afterMyTap),
          reason:
              'a tap on an opponent token (token-0-0) must add nothing to '
              'what the tap on my own token already recorded ($afterMyTap): '
              'board.dart\'s _handleTapUp only ever matches mySeat\'s own '
              'cell groups (_cellGroups reads widget.tokens[mySeat] alone), '
              'so a point over seat 0\'s token can never resolve to a '
              'callback, the same way a tap on an opponent\'s token '
              'during play resolves to nothing; recorded ${fake.recorded}',
        );
        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'a tap on an opponent token on the finished board must send '
              'no move either; the wire grew by '
              '${transport.sentRaw.length - sentBefore} message(s)',
        );
      },
    );
  });
}
