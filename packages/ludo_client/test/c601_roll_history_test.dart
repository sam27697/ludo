// Order 601t (C-601): the last rolls on the finished board say whose they
// were. Written from the contract in work/ludo/orders/601-roll-history-
// names-seat.md (D1 keep the seat, D2 draw the seat, D3 nothing else
// changes), not from the implementation.
//
// Real controller over FakeTransport, real GameScreen, the same road
// test/game_verify_card_test.dart takes to a finished board with rolls
// (rolled frames before the mount, then game_over).
//
// Reading `recentRollSeats` goes through `dynamic` on purpose: on a tree
// without D1 the field does not exist, so a typed read would stop this whole
// file compiling and hide the cases that pin behaviour D3 says is unchanged.
// Through `dynamic` the file compiles everywhere; a case that needs the new
// field then fails at run time with NoSuchMethodError, which is the honest
// red. Cases that only need the new field carry "[needs D1]" in their name.
//
// Every failure reason names the scenario (fixture, locale, scale) that
// reproduces it; nothing here is random or timed.

import 'dart:convert';

import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart' show seatLabelsFor;
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors, buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c601-roll-history-test.invalid/ws';
const String _verifyUrl = 'https://provefair.app/v/c601-roll-history';
const Key _historyKey = Key('game-screen-roll-history');

/// One roll to script: the rolling seat, its `k`, and the face.
typedef _Roll = (int seat, int k, int face);

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c601-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  required List<(int seat, String name)> seats,
  String state = 'PLAYING',
  int seq = 1,
  int? winner,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': seats.first.$1,
  'players': seats.length,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': '7f3a9c1e5b2d4068',
  'client_seeds': '0:sam-seed|1:bob-seed',
  'seats': <Map<String, Object?>>[
    for (final (int seat, String name) in seats) _seatJson(seat, name),
  ],
  'turn': <String, Object?>{
    'seat': seats.first.$1,
    'phase': 'await_roll',
    'deadline_ms': 45000,
    'k': 0,
  },
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

/// A real controller whose `room` can be pinned to a hand-built snapshot, so
/// a screen can be mounted on a snapshot no frame sequence produces (a
/// `recentRolls` of three with `recentRollSeats` empty). Everything else is
/// the real controller on the real fake socket.
class _PinnableController extends RoomController {
  _PinnableController({required super.serverUrl, required super.connect});

  RoomSnapshot? pinned;

  @override
  RoomSnapshot? get room => pinned ?? super.room;
}

class _Game {
  _Game(this.controller, this.transport, this.tester, this.seq);

  final _PinnableController controller;
  final FakeTransport transport;
  final WidgetTester? tester;
  int seq;

  Future<void> _flush() async {
    final WidgetTester? t = tester;
    if (t != null) {
      await t.pump();
      await t.pump();
    } else {
      await pumpEventQueue();
    }
  }

  /// A `rolled` frame. [seqOverride] sends a stale or gapped seq without
  /// moving the script's own counter.
  Future<void> rolled(_Roll roll, {int? seqOverride, int? seatOverride}) async {
    final int sendSeq;
    if (seqOverride == null) {
      seq += 1;
      sendSeq = seq;
    } else {
      sendSeq = seqOverride;
    }
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': seatOverride ?? roll.$1,
          'value': roll.$3,
          'legal': const <int>[0],
          'deadline_ms': 45000,
          'k': roll.$2,
          'reveal': 'c' * 64,
          'seq': sendSeq,
        },
      ),
    );
    await _flush();
  }

  Future<void> gameOver(int winner) async {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'game_over',
        data: <String, Object?>{
          'winner': winner,
          'seq': seq,
          'verify_url': _verifyUrl,
        },
      ),
    );
    await _flush();
  }

  Future<void> gameStarted(int turnSeat) async {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'game_started',
        data: <String, Object?>{
          'turn': turnSeat,
          'game_id': 'ffffffffffffffff',
          'client_seeds': '0:a|1:b',
          'seq': seq,
        },
      ),
    );
    await _flush();
  }

  Future<void> playerLeft(int seat, int hostSeat) async {
    seq += 1;
    transport.pushText(
      _frame(
        type: 'player_left',
        data: <String, Object?>{
          'seat': seat,
          'host_seat': hostSeat,
          'seq': seq,
        },
      ),
    );
    await _flush();
  }
}

/// Connects a controller to a PLAYING room holding [seats], me at [mySeat].
Future<_Game> _connect({
  required List<(int seat, String name)> seats,
  int mySeat = 0,
  WidgetTester? tester,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final _PinnableController controller = _PinnableController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final Future<void> future = controller.createRoom(
    name: seats.firstWhere(((int, String) s) => s.$1 == mySeat).$2,
    players: seats.length,
  );
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
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
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
  return _Game(controller, transport, tester, 1);
}

/// The new field, read without naming it in source (see the file header).
List<int> _seatsOf(RoomSnapshot room) =>
    List<int>.from((room as dynamic).recentRollSeats as List<dynamic>);

List<int> _facesKOf(RoomSnapshot room) => <int>[
  for (final (int k, int _) in room.recentRolls) k,
];

String _lengths(RoomSnapshot room) {
  List<int>? seats;
  try {
    seats = _seatsOf(room);
  } on NoSuchMethodError {
    seats = null;
  }
  return 'recentRolls=${room.recentRolls} recentRollSeats=$seats';
}

// ---------------------------------------------------------------------------
// Widget plumbing
// ---------------------------------------------------------------------------

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
  final FontLoader arabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    arabic.addFont(rootBundle.load(asset));
  }
  await arabic.load();
}

Widget _harness(Widget child, {required Locale locale, double scale = 1.0}) {
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
        data: data.copyWith(textScaler: TextScaler.linear(scale)),
        child: screen!,
      );
    },
    home: child,
  );
}

/// Mounts the finished screen. A tall surface keeps every row inside the
/// built part of the scroll view; the width is the case's own.
Future<void> _mount(
  WidgetTester tester,
  _Game game, {
  Locale locale = const Locale('en'),
  double scale = 1.0,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: game.controller),
      locale: locale,
      scale: scale,
    ),
  );
  await tester.pump();
  // A finished room with no transcript asks for game_log; refuse it so the
  // card settles, as test/game_verify_card_test.dart does.
  for (final String raw in List<String>.of(game.transport.sentRaw)) {
    if (_typeOf(raw) == 'game_log') {
      game.transport.pushText(
        _frame(
          type: 'error',
          re: _idOf(raw),
          data: <String, Object?>{
            'code': 'RATE_LIMITED',
            'message': 'game_log',
          },
        ),
      );
    }
  }
  await tester.pump();
  await tester.pump();
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

Finder _textIn(Finder scope, String data) => find.descendant(
  of: scope,
  matching: find.byWidgetPredicate(
    (Widget w) => w is Text && _textOf(w) == data,
  ),
);

RenderParagraph _paragraphOf(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );

/// Height of [p]'s text laid out on a single unbounded line, with the same
/// style, scale and direction the live paragraph has.
double _oneLineHeight(RenderParagraph p) {
  final TextPainter painter = TextPainter(
    text: p.text,
    textDirection: p.textDirection,
    textScaler: p.textScaler,
  )..layout();
  return painter.height;
}

/// One drawn row, located by geometry (the contract keys no row): the entry
/// text, then the mark and the label sitting on the same line.
class _Row {
  _Row({
    required this.entry,
    required this.entryRect,
    required this.mark,
    required this.markRect,
    required this.markWidget,
    required this.discRect,
    required this.discColor,
    required this.label,
    required this.labelRect,
  });

  final Finder entry;
  final Rect entryRect;
  final Finder mark;
  final Rect markRect;
  final SeatMark markWidget;
  final Rect discRect;
  final Color? discColor;
  final Finder label;
  final Rect labelRect;
}

_Row _rowOf(
  WidgetTester tester, {
  required String scenario,
  required int index,
  required String entryData,
  required String labelData,
}) {
  final Finder history = find.byKey(_historyKey);
  final Finder entry = _textIn(history, entryData);
  expect(
    entry,
    findsOneWidget,
    reason:
        '$scenario: row $index must draw the text "$entryData" exactly '
        'once inside game-screen-roll-history',
  );
  final Rect entryRect = tester.getRect(entry);

  Finder nearest(Finder all, String what) {
    final int n = all.evaluate().length;
    expect(
      n,
      greaterThan(0),
      reason:
          '$scenario: row $index must draw $what on the same line as '
          '"$entryData"; found none inside game-screen-roll-history',
    );
    int best = 0;
    double bestDy = double.infinity;
    for (int i = 0; i < n; i++) {
      final double dy = (tester.getCenter(all.at(i)).dy - entryRect.center.dy)
          .abs();
      if (dy < bestDy) {
        bestDy = dy;
        best = i;
      }
    }
    expect(
      bestDy,
      lessThan(6.0),
      reason:
          '$scenario: row $index $what must sit on the same line as '
          '"$entryData" (vertical centres within 6 dp); nearest was '
          '$bestDy dp away',
    );
    return all.at(best);
  }

  final Finder mark = nearest(
    find.descendant(of: history, matching: find.byType(SeatMark)),
    'a SeatMark',
  );
  final Finder label = nearest(
    _textIn(history, labelData),
    'the label '
    '"$labelData"',
  );
  // The seat-colour disc the mark sits on: the smallest circular
  // DecoratedBox above the mark (master ruling on D2).
  final Iterable<Element> discs = find
      .ancestor(
        of: mark,
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      )
      .evaluate();
  expect(
    discs,
    isNotEmpty,
    reason:
        '$scenario: row $index the SeatMark must sit on a circular '
        'seat-colour disc',
  );
  Element disc = discs.first;
  double discArea = double.infinity;
  for (final Element e in discs) {
    final Size size = (e.renderObject! as RenderBox).size;
    if (size.width * size.height < discArea) {
      discArea = size.width * size.height;
      disc = e;
    }
  }
  final Finder discFinder = find.byElementPredicate(
    (Element e) => identical(e, disc),
  );
  return _Row(
    entry: entry,
    entryRect: entryRect,
    mark: mark,
    markRect: tester.getRect(mark),
    markWidget: tester.widget<SeatMark>(mark),
    discRect: tester.getRect(discFinder),
    discColor:
        ((disc.widget as DecoratedBox).decoration as BoxDecoration).color,
    label: label,
    labelRect: tester.getRect(label),
  );
}

/// The row geometry and content common to every drawing case.
void _expectRow(
  WidgetTester tester,
  _Row row, {
  required String scenario,
  required int index,
  required int seat,
  required TextDirection direction,
}) {
  expect(
    row.markWidget.seat,
    seat,
    reason:
        '$scenario: row $index must carry the SeatMark of seat $seat, '
        'got seat ${row.markWidget.seat}',
  );
  expect(
    row.markRect.size,
    const Size(14, 14),
    reason:
        '$scenario: row $index SeatMark must be 14 x 14 dp, got '
        '${row.markRect.size}',
  );
  expect(
    row.discRect.size,
    const Size(22, 22),
    reason:
        '$scenario: row $index the disc under the mark must be 22 x 22 dp '
        'and take layout space, got ${row.discRect.size}',
  );
  expect(
    row.discColor,
    LudoColors.seats[seat],
    reason:
        '$scenario: row $index the disc must be the colour of seat $seat '
        '(${LudoColors.seats[seat]}), got ${row.discColor}',
  );
  expect(
    (row.markRect.center - row.discRect.center).distance,
    lessThan(0.51),
    reason:
        '$scenario: row $index the mark must be centred in its disc '
        '(mark ${row.markRect}, disc ${row.discRect})',
  );
  if (direction == TextDirection.ltr) {
    expect(
      row.labelRect.left - row.discRect.right,
      closeTo(6.0, 0.51),
      reason:
          '$scenario: row $index the label must start 6 dp after the disc '
          'edge (disc right ${row.discRect.right}, label left '
          '${row.labelRect.left})',
    );
    expect(
      row.entryRect.left,
      greaterThanOrEqualTo(row.labelRect.right - 0.01),
      reason:
          '$scenario: row $index reading order is disc, label, then the '
          'k: face text; entry left ${row.entryRect.left} is before label '
          'right ${row.labelRect.right}',
    );
  } else {
    expect(
      row.discRect.left - row.labelRect.right,
      closeTo(6.0, 0.51),
      reason:
          '$scenario: row $index (right to left) the label must end 6 dp '
          'before the disc edge (disc left ${row.discRect.left}, label '
          'right ${row.labelRect.right})',
    );
    expect(
      row.entryRect.right,
      lessThanOrEqualTo(row.labelRect.left + 0.01),
      reason:
          '$scenario: row $index reading order right to left is disc, '
          'label, then the k: face text; entry right ${row.entryRect.right} '
          'is after label left ${row.labelRect.left}',
    );
    expect(
      row.markRect.left,
      greaterThanOrEqualTo(row.entryRect.right),
      reason:
          '$scenario: row $index the mark\'s left edge must be right of the '
          'k: face text\'s right edge under Arabic',
    );
  }

  final Finder history = find.byKey(_historyKey);
  final Rect h = tester.getRect(history);
  final double left = <double>[
    row.discRect.left,
    row.labelRect.left,
    row.entryRect.left,
  ].reduce((double a, double b) => a < b ? a : b);
  final double right = <double>[
    row.discRect.right,
    row.labelRect.right,
    row.entryRect.right,
  ].reduce((double a, double b) => a > b ? a : b);
  expect(
    (left + right) / 2,
    closeTo(h.center.dx, 1.0),
    reason:
        '$scenario: row $index must stay centred in the block (row spans '
        '$left..$right, block centre ${h.center.dx})',
  );
  expect(
    left,
    greaterThanOrEqualTo(h.left - 0.01),
    reason: '$scenario: row $index spills left of the block',
  );
  expect(
    right,
    lessThanOrEqualTo(h.right + 0.01),
    reason: '$scenario: row $index spills right of the block',
  );

  final RichText rich = tester.widget<RichText>(
    find.descendant(of: row.entry, matching: find.byType(RichText)),
  );
  final List<FontFeature>? features = rich.text.style?.fontFeatures;
  expect(
    features?.any((FontFeature f) => f.feature == 'tnum' && f.value == 1),
    isTrue,
    reason:
        '$scenario: row $index the k: face text must use tabular figures; '
        'its fontFeatures were $features',
  );
}

/// One semantics node per row, carrying the spoken line, children excluded.
void _expectSpoken(
  WidgetTester tester,
  _Row row, {
  required String scenario,
  required int index,
  required String spoken,
}) {
  final SemanticsNode entryNode = tester.getSemantics(row.entry);
  final SemanticsNode labelNode = tester.getSemantics(row.label);
  expect(
    entryNode.label,
    spoken,
    reason:
        '$scenario: row $index semantics label must be the spoken line '
        '"$spoken", got "${entryNode.label}"',
  );
  expect(
    labelNode.id,
    entryNode.id,
    reason:
        '$scenario: row $index must be one semantics node; the name text '
        'resolves to node ${labelNode.id} and the k: face text to '
        '${entryNode.id}',
  );
  expect(
    entryNode.childrenCount,
    0,
    reason:
        '$scenario: row $index semantics children must be excluded, the '
        'node has ${entryNode.childrenCount}',
  );
}

Future<List<FlutterErrorDetails>> _capturingErrors(
  Future<void> Function() body,
) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return captured;
}

const List<_Roll> _twoSeatRolls = <_Roll>[
  (0, 11, 1),
  (2, 12, 3),
  (0, 13, 6),
  (2, 14, 4),
];
const List<(int, String)> _twoSeats = <(int, String)>[(0, 'Sam'), (2, 'Karim')];

/// A finished game at [seats] after [rolls]; the winner is the first seat
/// that is not mine, so I am the loser reading the list.
Future<_Game> _finished(
  WidgetTester tester, {
  required List<(int seat, String name)> seats,
  required List<_Roll> rolls,
}) async {
  final _Game game = await _connect(seats: seats, tester: tester);
  for (final _Roll roll in rolls) {
    await game.rolled(roll);
  }
  await game.gameOver(seats.firstWhere(((int, String) s) => s.$1 != 0).$1);
  expect(
    game.controller.room!.state,
    RoomState.finished,
    reason: 'fixture is broken: game_over must finish the room',
  );
  return game;
}

/// testWidgets with the semantics tree on; the handle is released inside the
/// test body, ahead of the framework's own end-of-test check.
void _testSemantics(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });
}

void main() {
  setUpAll(_loadAppFonts);

  // =========================================================================
  // D1: the controller keeps the seat.
  // =========================================================================
  group('D1 controller: recentRolls itself is unchanged', () {
    test('four rolled frames from seats 0, 2, 0, 2 leave the last three '
        '(k, face)', () async {
      final _Game game = await _connect(seats: _twoSeats);
      const List<_Roll> rolls = <_Roll>[
        (0, 1, 5),
        (2, 2, 3),
        (0, 3, 6),
        (2, 4, 2),
      ];
      for (final _Roll roll in rolls) {
        await game.rolled(roll);
      }
      expect(
        game.controller.room!.recentRolls,
        <(int, int)>[(2, 3), (3, 6), (4, 2)],
        reason:
            'scenario d1-a: after four rolls the ring keeps the last three '
            '(k, face); got ${game.controller.room!.recentRolls}',
      );
    });

    test('a rolled frame from a seat not in the room, a seq gap and a '
        'replayed frame append nothing to recentRolls', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      final List<(int, int)> before = List<(int, int)>.of(
        game.controller.room!.recentRolls,
      );
      // Seat 1 is not seated.
      await game.rolled((1, 3, 4), seqOverride: game.seq + 1);
      expect(
        game.controller.room!.recentRolls,
        before,
        reason: 'd1-b unseated',
      );
      // Replay of the frame just applied: stale seq reads as a gap.
      await game.rolled((2, 2, 3), seqOverride: game.seq);
      expect(game.controller.room!.recentRolls, before, reason: 'd1-b replay');
      // A forward gap.
      await game.rolled((0, 9, 2), seqOverride: game.seq + 5);
      expect(game.controller.room!.recentRolls, before, reason: 'd1-b gap');
    });

    test('the new game empties recentRolls', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      await game.gameOver(2);
      await game.gameStarted(0);
      expect(
        game.controller.room!.recentRolls,
        isEmpty,
        reason:
            'scenario d1-c: game_started must reset recentRolls; got '
            '${game.controller.room!.recentRolls}',
      );
    });

    test('fromJson starts recentRolls empty', () {
      final RoomSnapshot room = RoomSnapshot.fromJson(
        _roomJson(seats: _twoSeats),
      );
      expect(room.recentRolls, isEmpty, reason: 'scenario d1-d');
    });
  });

  group('D1 controller: recentRollSeats follows recentRolls [needs D1]', () {
    test('four rolled frames from seats 0, 2, 0, 2 leave recentRollSeats '
        '[2, 0, 2], the same length as recentRolls', () async {
      final _Game game = await _connect(seats: _twoSeats);
      const List<_Roll> rolls = <_Roll>[
        (0, 1, 5),
        (2, 2, 3),
        (0, 3, 6),
        (2, 4, 2),
      ];
      for (final _Roll roll in rolls) {
        await game.rolled(roll);
      }
      final RoomSnapshot room = game.controller.room!;
      expect(
        _seatsOf(room),
        <int>[2, 0, 2],
        reason:
            'scenario d1-a: entry i of recentRollSeats is the seat that '
            'rolled recentRolls[i]; ${_lengths(room)}',
      );
      expect(_seatsOf(room).length, room.recentRolls.length);
    });

    test('the two lists have the same length after every frame, 1 up to the '
        'limit of 3', () async {
      final _Game game = await _connect(seats: _twoSeats);
      const List<_Roll> rolls = <_Roll>[
        (0, 1, 5),
        (2, 2, 3),
        (0, 3, 6),
        (2, 4, 2),
        (0, 5, 1),
      ];
      final List<int> lengths = <int>[];
      for (final _Roll roll in rolls) {
        await game.rolled(roll);
        final RoomSnapshot room = game.controller.room!;
        expect(
          _seatsOf(room).length,
          room.recentRolls.length,
          reason:
              'scenario d1-a2 after k=${roll.$2}: lengths must match; '
              '${_lengths(room)}',
        );
        lengths.add(_seatsOf(room).length);
      }
      expect(lengths, <int>[1, 2, 3, 3, 3], reason: 'three-entry limit');
    });

    test(
      'four seats: seat numbers are kept verbatim, seat 3 included',
      () async {
        final _Game game = await _connect(
          seats: const <(int, String)>[(0, 'A'), (1, 'B'), (2, 'C'), (3, 'D')],
        );
        for (final _Roll roll in const <_Roll>[
          (3, 1, 2),
          (1, 2, 4),
          (3, 3, 6),
        ]) {
          await game.rolled(roll);
        }
        expect(_seatsOf(game.controller.room!), <int>[
          3,
          1,
          3,
        ], reason: 'scenario d1-e: ${_lengths(game.controller.room!)}');
      },
    );

    test('a frame that appends nothing to recentRolls appends nothing to '
        'recentRollSeats (unseated seat, replay, gap)', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      final List<int> before = _seatsOf(game.controller.room!);
      expect(before, <int>[0, 2], reason: 'fixture');
      await game.rolled((1, 3, 4), seqOverride: game.seq + 1);
      await game.rolled((2, 2, 3), seqOverride: game.seq);
      await game.rolled((0, 9, 2), seqOverride: game.seq + 5);
      final RoomSnapshot room = game.controller.room!;
      expect(
        _seatsOf(room),
        before,
        reason:
            'scenario d1-b: ignored frames moved the seats; ${_lengths(room)}',
      );
      expect(_seatsOf(room).length, room.recentRolls.length);
    });

    test('fromJson gives both empty, and ignores wire keys that name the '
        'client-only lists', () {
      final Map<String, Object?> json = _roomJson(seats: _twoSeats)
        ..['recent_rolls'] = <Object?>[
          <int>[1, 2],
        ]
        ..['recent_roll_seats'] = <int>[1, 2]
        ..['recentRollSeats'] = <int>[1, 2];
      final RoomSnapshot room = RoomSnapshot.fromJson(json);
      expect(room.recentRolls, isEmpty, reason: 'scenario d1-d');
      expect(_seatsOf(room), isEmpty, reason: 'scenario d1-d');
    });

    test('the new game empties both together', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      await game.gameOver(2);
      expect(_seatsOf(game.controller.room!), <int>[0, 2], reason: 'fixture');
      await game.gameStarted(0);
      final RoomSnapshot room = game.controller.room!;
      expect(
        <Object>[room.recentRolls, _seatsOf(room)],
        <Object>[isEmpty, isEmpty],
        reason:
            'scenario d1-c: game_started must reset both; ${_lengths(room)}',
      );
      await game.rolled((2, 1, 6));
      expect(
        _seatsOf(game.controller.room!),
        <int>[2],
        reason:
            'scenario d1-c: first roll of the new game; '
            '${_lengths(game.controller.room!)}',
      );
    });

    test('a resync replaces both together, and the next roll appends to '
        'both in step', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      await game.rolled((0, 3, 6));
      expect(_seatsOf(game.controller.room!), <int>[0, 2, 0]);
      // A gapped frame starts a resume; the reply is a plain snapshot.
      await game.rolled((2, 4, 2), seqOverride: game.seq + 4);
      final String resumeId = _idOf(
        game.transport.sentRaw.lastWhere((String r) => _typeOf(r) == 'resume'),
      );
      final int resumedSeq = game.seq + 4;
      game.transport.pushText(
        _frame(
          type: 'room',
          re: resumeId,
          data: _roomJson(seats: _twoSeats, seq: resumedSeq),
        ),
      );
      await pumpEventQueue();
      RoomSnapshot room = game.controller.room!;
      expect(room.seq, resumedSeq, reason: 'fixture: the resume reply landed');
      expect(
        <Object>[room.recentRolls, _seatsOf(room)],
        <Object>[isEmpty, isEmpty],
        reason: 'scenario d1-f: a resync re-bases both; ${_lengths(room)}',
      );
      game.seq = resumedSeq;
      await game.rolled((2, 5, 4));
      room = game.controller.room!;
      expect(
        _seatsOf(room),
        <int>[2],
        reason: 'scenario d1-f: first roll after the resync; ${_lengths(room)}',
      );
      expect(room.recentRolls, <(int, int)>[(5, 4)]);
    });

    test('copyWith keeps recentRollSeats when it is not given, and sets it '
        'with recentRolls when it is', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      final RoomSnapshot room = game.controller.room!;
      expect(
        _seatsOf(room.copyWith(seq: room.seq + 1)),
        <int>[0, 2],
        reason: 'scenario d1-g: copyWith without the new argument must keep it',
      );
      final RoomSnapshot set = (room as dynamic).copyWith(
        recentRolls: <(int k, int face)>[(7, 6)],
        recentRollSeats: <int>[2],
      ) as RoomSnapshot;
      expect(set.recentRolls, <(int, int)>[(7, 6)]);
      expect(_seatsOf(set), <int>[
        2,
      ], reason: 'scenario d1-g: copyWith(recentRollSeats: [2])');
    });

    test('a seat leaving after the rolls does not touch the lists', () async {
      final _Game game = await _connect(seats: _twoSeats);
      await game.rolled((0, 1, 5));
      await game.rolled((2, 2, 3));
      await game.playerLeft(2, 0);
      final RoomSnapshot room = game.controller.room!;
      expect(room.seats.length, 1, reason: 'fixture: seat 2 left');
      expect(_seatsOf(room), <int>[
        0,
        2,
      ], reason: 'scenario d1-h: ${_lengths(room)}');
      expect(_facesKOf(room), <int>[1, 2]);
    });
  });

  // =========================================================================
  // D2: the screen draws the seat.
  // =========================================================================
  group('D2 finished screen: unchanged behaviour (D3)', () {
    testWidgets('three rolls still draw three k: face lines and nothing '
        'older, heading unchanged', (tester) async {
      final _Game game = await _finished(
        tester,
        seats: _twoSeats,
        rolls: _twoSeatRolls,
      );
      await _mount(tester, game);
      final AppLocalizations loc = _loc(tester);
      final Finder history = find.byKey(_historyKey);
      expect(history, findsOneWidget, reason: 'scenario d3-a');
      expect(
        _textIn(history, loc.gameRollHistoryHeading),
        findsOneWidget,
        reason: 'scenario d3-a: the heading stays',
      );
      for (final _Roll roll in _twoSeatRolls.sublist(1)) {
        expect(
          _textIn(history, loc.gameRollHistoryEntry(roll.$2, roll.$3)),
          findsOneWidget,
          reason:
              'scenario d3-a: the unchanged "${roll.$2}: ${roll.$3}" text '
              'must be drawn once',
        );
      }
      expect(
        _textIn(history, loc.gameRollHistoryEntry(11, 1)),
        findsNothing,
        reason: 'scenario d3-a: the fourth-oldest roll is outside the limit',
      );
    });

    testWidgets('a finished game with no rolls on this controller shows no '
        'block at all', (tester) async {
      final _Game game = await _finished(
        tester,
        seats: _twoSeats,
        rolls: const <_Roll>[],
      );
      await _mount(tester, game);
      expect(
        find.byKey(_historyKey),
        findsNothing,
        reason:
            'scenario d3-b: _showsRollHistory stays false for a finished '
            'room with no recent rolls',
      );
    });
  });

  group('D2 finished screen: rows name the seat [needs D1]', () {
    _testSemantics('b: two seats, I am Sam (seat 0), friend Karim (seat 2), '
        'rolls by seats 2, 0, 2 (en)', (tester) async {
      const String scenario = 'b-en: seats 0 Sam, 2 Karim; rolls 2,0,2; en';
      final _Game game = await _finished(
        tester,
        seats: _twoSeats,
        rolls: _twoSeatRolls,
      );
      await _mount(tester, game);
      final AppLocalizations loc = _loc(tester);

      expect(
        find.descendant(
          of: find.byKey(_historyKey),
          matching: find.byType(SeatMark),
        ),
        findsNWidgets(3),
        reason: '$scenario: exactly three rows, each with one SeatMark',
      );

      const List<(int seat, String name)> expected = <(int, String)>[
        (2, 'Karim'),
        (0, 'You'),
        (2, 'Karim'),
      ];
      final List<_Roll> shown = _twoSeatRolls.sublist(1);
      double lastY = -1;
      for (int i = 0; i < 3; i++) {
        final String name = expected[i].$2;
        expect(
          name == 'You' ? loc.seatYou : name,
          name,
          reason: 'fixture: seatYou reads "You" in en',
        );
        final _Row row = _rowOf(
          tester,
          scenario: scenario,
          index: i,
          entryData: loc.gameRollHistoryEntry(shown[i].$2, shown[i].$3),
          labelData: name,
        );
        expect(
          row.entryRect.center.dy,
          greaterThan(lastY),
          reason: '$scenario: rows run in roll order, oldest first',
        );
        lastY = row.entryRect.center.dy;
        _expectRow(
          tester,
          row,
          scenario: scenario,
          index: i,
          seat: expected[i].$1,
          direction: TextDirection.ltr,
        );
        _expectSpoken(
          tester,
          row,
          scenario: scenario,
          index: i,
          spoken: loc.gameRollHistoryEntrySpoken(
            shown[i].$2,
            name,
            shown[i].$3,
          ),
        );
      }
      // The contract's wording for the en strings, pinned beyond the loc call.
      expect(
        tester.getSemantics(_textIn(find.byKey(_historyKey), '13: 6')).label,
        'Roll 13: You rolled 6',
        reason: '$scenario: my own row speaks the seatYou text as the name',
      );
      expect(
        tester.getSemantics(_textIn(find.byKey(_historyKey), '12: 3')).label,
        'Roll 12: Karim rolled 3',
        reason: '$scenario: the friend row speaks the friend name',
      );
    });

    _testSemantics('c: three seats, rows name three different seats in roll '
        'order', (tester) async {
      const String scenario = 'c-3: seats 0 Sam, 1 Ayla, 2 Karim; rolls 1,2,0';
      final _Game game = await _finished(
        tester,
        seats: const <(int, String)>[(0, 'Sam'), (1, 'Ayla'), (2, 'Karim')],
        rolls: const <_Roll>[(1, 21, 2), (2, 22, 5), (0, 23, 3)],
      );
      await _mount(tester, game);
      final AppLocalizations loc = _loc(tester);
      const List<(int seat, String name, int k, int face)> expected =
          <(int, String, int, int)>[
            (1, 'Ayla', 21, 2),
            (2, 'Karim', 22, 5),
            (0, 'You', 23, 3),
          ];
      for (int i = 0; i < expected.length; i++) {
        final (int seat, String name, int k, int face) = expected[i];
        final _Row row = _rowOf(
          tester,
          scenario: scenario,
          index: i,
          entryData: loc.gameRollHistoryEntry(k, face),
          labelData: name,
        );
        _expectRow(
          tester,
          row,
          scenario: scenario,
          index: i,
          seat: seat,
          direction: TextDirection.ltr,
        );
        _expectSpoken(
          tester,
          row,
          scenario: scenario,
          index: i,
          spoken: loc.gameRollHistoryEntrySpoken(k, name, face),
        );
      }
    });

    _testSemantics('c4: four seats, two players who share a name, are told '
        'apart by the same labels the board uses', (tester) async {
      const String scenario =
          'c-4: seats 0 Sam, 1 Player, 2 Player, 3 Lee; rolls 1,2,3';
      final _Game game = await _finished(
        tester,
        seats: const <(int, String)>[
          (0, 'Sam'),
          (1, 'Player'),
          (2, 'Player'),
          (3, 'Lee'),
        ],
        rolls: const <_Roll>[(1, 31, 2), (2, 32, 5), (3, 33, 3)],
      );
      await _mount(tester, game);
      final AppLocalizations loc = _loc(tester);
      final Map<int, String> labels = seatLabelsFor(
        tester.element(find.byType(GameScreen)),
        game.controller.room!.seats,
      );
      expect(
        labels[1] == labels[2],
        isFalse,
        reason: 'fixture: seatLabelsFor must tell the two Players apart',
      );
      const List<(int seat, int k, int face)> rolls = <(int, int, int)>[
        (1, 31, 2),
        (2, 32, 5),
        (3, 33, 3),
      ];
      for (int i = 0; i < rolls.length; i++) {
        final (int seat, int k, int face) = rolls[i];
        final String name = labels[seat]!;
        final _Row row = _rowOf(
          tester,
          scenario: scenario,
          index: i,
          entryData: loc.gameRollHistoryEntry(k, face),
          labelData: name,
        );
        _expectRow(
          tester,
          row,
          scenario: scenario,
          index: i,
          seat: seat,
          direction: TextDirection.ltr,
        );
        _expectSpoken(
          tester,
          row,
          scenario: scenario,
          index: i,
          spoken: loc.gameRollHistoryEntrySpoken(k, name, face),
        );
      }
    });

    _testSemantics(
      'd: Arabic, the rows read right to left and speak the Arabic '
      'line',
      (tester) async {
        const String scenario = 'd-ar: seats 0 Sam, 2 Karim; rolls 2,0,2; ar';
        final _Game game = await _finished(
          tester,
          seats: _twoSeats,
          rolls: _twoSeatRolls,
        );
        await _mount(tester, game, locale: const Locale('ar'));
        final AppLocalizations loc = _loc(tester);
        expect(loc.localeName, 'ar', reason: 'fixture: the harness is Arabic');
        expect(
          Directionality.of(tester.element(find.byKey(_historyKey))),
          TextDirection.rtl,
          reason: 'fixture: the ambient direction is rtl',
        );
        const List<(int seat, String who)> expected = <(int, String)>[
          (2, 'Karim'),
          (0, ''),
          (2, 'Karim'),
        ];
        final List<_Roll> shown = _twoSeatRolls.sublist(1);
        for (int i = 0; i < 3; i++) {
          final String name = expected[i].$1 == 0
              ? loc.seatYou
              : expected[i].$2;
          final _Row row = _rowOf(
            tester,
            scenario: scenario,
            index: i,
            entryData: loc.gameRollHistoryEntry(shown[i].$2, shown[i].$3),
            labelData: name,
          );
          _expectRow(
            tester,
            row,
            scenario: scenario,
            index: i,
            seat: expected[i].$1,
            direction: TextDirection.rtl,
          );
          final String spoken = loc.gameRollHistoryEntrySpoken(
            shown[i].$2,
            name,
            shown[i].$3,
          );
          _expectSpoken(
            tester,
            row,
            scenario: scenario,
            index: i,
            spoken: spoken,
          );
          expect(
            spoken.contains('الرمية'),
            isTrue,
            reason: '$scenario: the spoken line is the Arabic string: $spoken',
          );
        }
      },
    );

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final double scale in const <double>[1.0, 2.0]) {
        final String scenario =
            'e: 40-char friend name, 360 dp wide, ${locale.languageCode}, '
            'text scale $scale';
        testWidgets(scenario, (tester) async {
          final String longName = 'Karim${'MW' * 17}M';
          expect(longName.length, 40, reason: 'fixture: 40 characters');
          final _Game game = await _finished(
            tester,
            seats: <(int, String)>[(0, 'Sam'), (2, longName)],
            rolls: _twoSeatRolls,
          );
          final List<FlutterErrorDetails> errors = await _capturingErrors(
            () =>
                _mount(tester, game, locale: locale, scale: scale, width: 360),
          );
          expect(
            errors,
            isEmpty,
            reason:
                '$scenario: mounting must raise no FlutterError (overflow '
                'included), got ${errors.map((e) => e.exceptionAsString())}',
          );
          final AppLocalizations loc = _loc(tester);
          final List<_Roll> shown = _twoSeatRolls.sublist(1);
          const List<int> seatsShown = <int>[2, 0, 2];
          for (int i = 0; i < 3; i++) {
            final String name = seatsShown[i] == 0 ? loc.seatYou : longName;
            final _Row row = _rowOf(
              tester,
              scenario: scenario,
              index: i,
              entryData: loc.gameRollHistoryEntry(shown[i].$2, shown[i].$3),
              labelData: name,
            );
            final RenderParagraph labelPara = _paragraphOf(tester, row.label);
            final RenderParagraph entryPara = _paragraphOf(tester, row.entry);
            expect(
              labelPara.size.height,
              lessThanOrEqualTo(_oneLineHeight(labelPara) + 0.5),
              reason:
                  '$scenario: row $i name must be one line (height '
                  '${labelPara.size.height}, one line '
                  '${_oneLineHeight(labelPara)})',
            );
            expect(
              entryPara.size.height,
              lessThanOrEqualTo(_oneLineHeight(entryPara) + 0.5),
              reason:
                  '$scenario: row $i k: face text must be one line (height '
                  '${entryPara.size.height}, one line '
                  '${_oneLineHeight(entryPara)})',
            );
            expect(
              entryPara.didExceedMaxLines,
              isFalse,
              reason: '$scenario: row $i k: face text must never truncate',
            );
            final double natural = entryPara.getMaxIntrinsicWidth(
              double.infinity,
            );
            expect(
              entryPara.size.width,
              greaterThanOrEqualTo(natural - 0.5),
              reason:
                  '$scenario: row $i k: face text is laid out ${entryPara.size.width} '
                  'wide, narrower than its natural width $natural',
            );
            expect(
              labelPara.didExceedMaxLines,
              seatsShown[i] == 2,
              reason:
                  '$scenario: row $i name "$name" must '
                  '${seatsShown[i] == 2 ? '' : 'not '}ellipsize',
            );
            expect(
              (row.markRect.center.dy - row.entryRect.center.dy).abs(),
              lessThan(6.0),
              reason: '$scenario: row $i mark and text share one line',
            );
            final Rect h = tester.getRect(find.byKey(_historyKey));
            final double left = <double>[
              row.discRect.left,
              row.labelRect.left,
              row.entryRect.left,
            ].reduce((double a, double b) => a < b ? a : b);
            final double right = <double>[
              row.discRect.right,
              row.labelRect.right,
              row.entryRect.right,
            ].reduce((double a, double b) => a > b ? a : b);
            expect(
              left,
              greaterThanOrEqualTo(h.left - 0.01),
              reason: '$scenario: row $i spills left of the block',
            );
            expect(
              right,
              lessThanOrEqualTo(h.right + 0.01),
              reason: '$scenario: row $i spills right of the block',
            );
          }
        });
      }
    }

    testWidgets('a friend who left after the game does not break the list '
        '(contract silent on what the row shows)', (tester) async {
      const String scenario = 'leaver: seat 2 left after game_over; en';
      final _Game game = await _finished(
        tester,
        seats: _twoSeats,
        rolls: _twoSeatRolls,
      );
      await game.playerLeft(2, 0);
      expect(game.controller.room!.seats.length, 1, reason: 'fixture');
      final List<FlutterErrorDetails> errors = await _capturingErrors(
        () => _mount(tester, game),
      );
      expect(
        errors,
        isEmpty,
        reason:
            '$scenario: the screen must draw without a FlutterError, got '
            '${errors.map((e) => e.exceptionAsString())}',
      );
      final AppLocalizations loc = _loc(tester);
      for (final _Roll roll in _twoSeatRolls.sublist(1)) {
        expect(
          _textIn(
            find.byKey(_historyKey),
            loc.gameRollHistoryEntry(roll.$2, roll.$3),
          ),
          findsOneWidget,
          reason: '$scenario: the k: face line of k=${roll.$2} stays',
        );
      }
    });
  });

  group('D2 finished screen: a row without a seat entry is drawn as today', () {
    _testSemantics('f: recentRolls of three, recentRollSeats empty: text only, '
        'no mark, no name, no crash', (tester) async {
      const String scenario = 'f: 3 rolls, empty recentRollSeats; en';
      final _Game game = await _finished(
        tester,
        seats: _twoSeats,
        rolls: _twoSeatRolls,
      );
      final RoomSnapshot done = game.controller.room!;
      game.controller.pinned = RoomSnapshot(
        code: done.code,
        state: done.state,
        hostSeat: done.hostSeat,
        players: done.players,
        rules: done.rules,
        chainCommit: done.chainCommit,
        chainIndex: done.chainIndex,
        gameId: done.gameId,
        clientSeeds: done.clientSeeds,
        seats: done.seats,
        turn: done.turn,
        winner: done.winner,
        verifyUrl: done.verifyUrl,
        recentRolls: const <(int k, int face)>[(12, 3), (13, 6), (14, 4)],
        seq: done.seq,
      );
      await _mount(tester, game);
      expect(
        tester.takeException(),
        isNull,
        reason: '$scenario: no crash when the seats list is short',
      );
      final AppLocalizations loc = _loc(tester);
      final Finder history = find.byKey(_historyKey);
      expect(
        find.descendant(of: history, matching: find.byType(SeatMark)),
        findsNothing,
        reason: '$scenario: no SeatMark without a seat entry',
      );
      for (final String name in <String>['Sam', 'Karim', loc.seatYou]) {
        expect(
          _textIn(history, name),
          findsNothing,
          reason: '$scenario: no name "$name" without a seat entry',
        );
      }
      for (final (int k, int face) in const <(int, int)>[
        (12, 3),
        (13, 6),
        (14, 4),
      ]) {
        final String text = loc.gameRollHistoryEntry(k, face);
        final Finder entry = _textIn(history, text);
        expect(
          entry,
          findsOneWidget,
          reason: '$scenario: "$text" is drawn as today',
        );
        expect(
          tester.getSemantics(entry).label,
          text,
          reason: '$scenario: with no name the row is not spoken with one',
        );
      }
    });

    testWidgets('f2: recentRollSeats shorter than recentRolls: the rows '
        'with an entry are named, the rest drawn as today [needs D1]', (
      tester,
    ) async {
      const String scenario = 'f2: 3 rolls, seats [2, 0]; en';
      final _Game game = await _finished(
        tester,
        seats: _twoSeats,
        rolls: _twoSeatRolls,
      );
      final RoomSnapshot done = game.controller.room!;
      game.controller.pinned = (done as dynamic).copyWith(
        recentRolls: <(int k, int face)>[(12, 3), (13, 6), (14, 4)],
        recentRollSeats: <int>[2, 0],
      ) as RoomSnapshot;
      await _mount(tester, game);
      expect(
        tester.takeException(),
        isNull,
        reason: '$scenario: no crash when the seats list is short',
      );
      final Finder history = find.byKey(_historyKey);
      expect(
        find.descendant(of: history, matching: find.byType(SeatMark)),
        findsNWidgets(2),
        reason:
            '$scenario: entry i names row i; the third row has no entry and '
            'draws no mark',
      );
      final AppLocalizations loc = _loc(tester);
      expect(
        _textIn(history, loc.gameRollHistoryEntry(14, 4)),
        findsOneWidget,
        reason: '$scenario: the unnamed third row still draws its text',
      );
    });
  });
}
