// Conformance tests for work/ludo/orders/C-250-play-header.md, written from
// that contract's text alone. Order 250 (a parallel worktree this file's
// author has not read) implements the contract in lib/src/game_screen.dart;
// this file proves every bullet of C-250's own "What proves it" section and
// nothing else.
//
// On the base commit this file was written against (b2fddb9, order 250's own
// dispatch base), the playing header is the pre-C-250 shape 236r2 shipped:
// _turnBannerSlot caps the banner at `maxLines: 2` (contract rule 2 asks for
// 1), there is no chip, no dot, and no per-seat tint on the banner at all;
// _seatOfflineSlot sits between the banner and the dice-value slot, above
// `Expanded(LudoBoard)` (contract rule 4 moves it below the board, into the
// no-move notice's own slot); the countdown is a plain, uncoloured `Text`
// with no ring (contract rule 3); `game-screen-dice-value` is a visible
// `Text` (contract rule 5 moves the key onto a `Semantics` wrapping the die
// and removes the visible line). Per the work order, rule 1 and rule 6 are
// expected red here because of exactly this: the extra reserved slots above
// the board (seat-offline's own slot, the two-line banner slot) push the
// board down from 86% to 57% of the screen width, the defect C-250 itself
// records as its reason for existing.
//
// GameScreen is mounted exactly as test/no_move_beat_test.dart and
// test/game_screen_countdown_test.dart do: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only), with a
// FeedbackScope carrying a fake FeedbackService above it, since
// GameScreen._onFrame calls FeedbackScope.of(context) for every frame this
// screen's own subscription sees regardless of what cue (if any) that frame
// carries. The fake-transport idiom (_Connector, pushText, the JSON helpers)
// and the harness are copied by hand from those two files' own copies, per
// this order's instruction never to import across test files.
//
// Run 70 reported an ambiguity here: C-250 rule 2 (the chip, the dot) and
// rule 3 (the ring) describe visual properties but named no test key for any
// of the three, unlike rule 4's `game-screen-turn-seat-offline` and rule 5's
// `game-screen-dice-value`. In the absence of a key, that run's cases scoped
// a colour presence scan by exclusion: every colour-bearing widget anywhere
// under GameScreen that was NOT also a descendant of game-screen-board,
// game-seat-pip-strip or game-die counted as "the header's own colour".
//
// C-250's "Amendment run 71" answers that ambiguity directly: `rule 8` gives
// the chip the key `game-header-chip` (a `DecoratedBox`, `BoxDecoration
// .color` the turn seat's colour, compared by RGB since any alpha is
// allowed), the dot the key `game-header-chip-dot` (the turn seat's colour
// at full alpha), the ring the key `game-header-countdown-ring` (a widget
// exposing its own colour as a public `final Color color` field), and pins
// the my-turn second signal to `FontWeight.w700` on `game-screen-turn
// -banner` rather than leaving it a choice between bold text and an
// outline. Every colour and my-turn case below now reads these keys
// directly instead of scanning. The exclusion scan proved only "this colour
// appears somewhere in the header, outside the board, the pip strip and the
// die"; once a key exists for every node the contract actually asks a
// colour of, a direct read of that key proves strictly more (which node, and
// now, for the dot, at what alpha) with nothing the scan could show that the
// keyed read cannot, so the scan and the helpers it needed are removed
// rather than kept dead. Order 250 has not landed on this file's own base
// (`7a27548` carries none of `game-header-chip`, `game-header-chip-dot` or
// `game-header-countdown-ring` in lib/), so every case below is red here for
// a key-not-found reason rather than a wrong-colour one; the ring's own
// `color` field is read through `dynamic` for the same reason, so this file
// compiles whether or not that widget's type exists yet.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://play-header-test.invalid/ws';

// --- server-side id generation for pushed frames, copied from the sibling
// suites' own idiom ----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'play-header-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, copied from the sibling suites --------------------

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
  required List<Map<String, Object?>> seats,
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
  'seats': seats,
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

/// Connects a fresh controller straight to the given two-seat room, mySeat
/// always 0. Copied by hand from the sibling suites' own `_connectTo` /
/// `_connectPlaying`.
Future<(RoomController, FakeTransport)> _connectDirect(
  WidgetTester tester, {
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
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(disableAnimations: disableAnimations),
        child: child!,
      );
    },
    home: child,
  );
}

/// Records every cue GameScreen asks the service to play. Never asserted on
/// directly here; it exists only because mounting GameScreen needs a
/// FeedbackScope at all (GameScreen._onFrame calls FeedbackScope.of(context)
/// unconditionally for every frame its own subscription sees).
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
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

/// Sets the test surface and queues its own reset, the same pattern
/// test/no_move_beat_test.dart's own `_setSurface` uses.
void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Tears the mounted tree down (forcing GameScreen.dispose to run, which
/// cancels its own subscription and listener) and then disposes the
/// controller -- in that order, so the next connect-and-mount in the same
/// test body gets a genuinely fresh `_GameScreenState.initState`, per the
/// measured lesson test/game_screen_turn_seat_offline_test.dart's own
/// `_mountP2ScenarioAndGetOfflineText` header records: GameScreen has no
/// `didUpdateWidget`, so a second `tester.pumpWidget` at the same tree
/// position updates the existing element instead of creating a fresh one,
/// and the old controller's listener and frame subscription are never
/// reattached to the new one.
Future<void> _unmountAndDispose(
  WidgetTester tester,
  RoomController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

const Key _pipStripKey = Key('game-seat-pip-strip');
const Key _boardKey = Key('game-screen-board');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _offlineKey = Key('game-screen-turn-seat-offline');
const Key _noMoveNoticeKey = Key('game-no-move-notice');
const Key _diceValueKey = Key('game-screen-dice-value');

/// Amendment run 71, rule 8's own three keys.
const Key _chipKey = Key('game-header-chip');
const Key _chipDotKey = Key('game-header-chip-dot');
const Key _ringKey = Key('game-header-countdown-ring');

/// Amendment run 72, rule 9c's own key for the sentence-bearing wrapper.
const Key _countdownSemanticsKey = Key('game-header-countdown-semantics');

/// H2's own mapping, named by C-250 rule 2 itself ("the strings it shows
/// today (`_turnBannerText`)") -- not read off the implementation, but
/// specified by the contract text, and already the mapping
/// test/game_screen_countdown_test.dart's P4/P5/P10 and
/// test/no_move_beat_test.dart independently rely on for the same banner.
String _expectedBannerText(
  AppLocalizations loc,
  RoomSnapshot room,
  int? mySeat,
) {
  final TurnState? turn = room.turn;
  if (turn == null) {
    return loc.gameWaitingForTurn;
  }
  if (turn.seat == mySeat) {
    if (turn.phase == TurnPhase.awaitRoll) {
      return loc.gameYourTurnRoll;
    }
    if (turn.phase == TurnPhase.awaitMove) {
      return loc.gameYourTurnMove;
    }
  }
  for (final SeatState seatState in room.seats) {
    if (seatState.seat == turn.seat) {
      return loc.gameWaitingForPlayer(seatState.name);
    }
  }
  return loc.gameWaitingForTurn;
}

// --- rule 8's own keyed colour reads (see header comment) ------------------

/// Whether [a] and [b] are the same colour by RGB, ignoring alpha -- the
/// comparison rule 8 itself names for `game-header-chip` ("any alpha; the
/// test compares RGB"), reused below for the ring's own `color` field since
/// the amendment states no alpha constraint for it either.
bool _sameRgb(Color a, Color b) => a.r == b.r && a.g == b.g && a.b == b.b;

/// The `BoxDecoration.color` of the `DecoratedBox` keyed [key]. Rule 8 pins
/// both `game-header-chip` and `game-header-chip-dot` to exactly this
/// shape.
Color _decoratedBoxColor(WidgetTester tester, Key key) {
  final DecoratedBox box = tester.widget<DecoratedBox>(find.byKey(key));
  final Decoration decoration = box.decoration;
  if (decoration is! BoxDecoration) {
    fail(
      'rule 8: the DecoratedBox keyed $key must carry a BoxDecoration; got '
      'a ${decoration.runtimeType}',
    );
  }
  final Color? color = decoration.color;
  if (color == null) {
    fail('rule 8: the BoxDecoration keyed $key must set a color; got null');
  }
  return color;
}

/// The countdown ring's own colour, read through `dynamic` per the
/// amendment's own instruction: order 250's ring widget (a small
/// `StatelessWidget` or `CustomPaint`-holding widget of its own) has not
/// landed on this file's base, so its static type is unknown here; this
/// reads the public `color` field the amendment requires without naming
/// one, so the file compiles both before and after 250 lands.
Color _ringColor(WidgetTester tester) {
  final dynamic ring = tester.widget(find.byKey(_ringKey));
  return ring.color as Color;
}

/// Whether [inner] lies inside [outer], each edge compared with half a
/// logical pixel of slack for the same subpixel-rendering reason rule 6's
/// own rect comparisons above already allow it (`closeTo(..., 0.5)`).
bool _rectInside(Rect inner, Rect outer, {double tolerance = 0.5}) =>
    inner.left >= outer.left - tolerance &&
    inner.top >= outer.top - tolerance &&
    inner.right <= outer.right + tolerance &&
    inner.bottom <= outer.bottom + tolerance;

/// Reads whatever whole-second number [key]'s own widget (or its first Text
/// descendant, if it is not itself a Text) renders. Copied from
/// test/game_screen_countdown_test.dart's own `_wholeSecondsShown`, since
/// C-250 rule 3 explicitly keeps `game-screen-turn-countdown` "on the Text
/// that shows the seconds" -- this file does not assume the surrounding ring
/// widget is itself a Text.
int _wholeSecondsShown(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  final Widget widget = tester.widget(finder);
  final Text text;
  if (widget is Text) {
    text = widget;
  } else {
    final Finder descendant = find.descendant(
      of: finder,
      matching: find.byType(Text),
    );
    expect(
      descendant,
      findsAtLeastNWidgets(1),
      reason:
          'the widget keyed $key is a ${widget.runtimeType}, not a Text, '
          'and carries no Text descendant to read a rendered number from',
    );
    text = tester.widget<Text>(descendant.first);
  }
  final String rendered = text.data ?? '';
  final RegExpMatch? match = RegExp(r'-?\d+').firstMatch(rendered);
  if (match == null) {
    fail(
      'the widget keyed $key rendered "$rendered", which contains no whole '
      'number to read a countdown value from',
    );
  }
  return int.parse(match.group(0)!);
}

// ============================================================================
// The five playing states rule 1 and rule 6 both name.
// ============================================================================

enum _PlayState {
  myTurnAwaitRoll,
  myTurnAwaitMove,
  noMoveHold,
  anotherSeatsTurn,
  turnSeatOffline,
}

List<Map<String, Object?>> _seatsFor(_PlayState state) {
  final bool seat1Offline = state == _PlayState.turnSeatOffline;
  return <Map<String, Object?>>[
    _seatJson(0, name: 'Sam'),
    _seatJson(1, name: 'Bob', connected: !seat1Offline),
  ];
}

Map<String, Object?>? _initialTurnFor(_PlayState state) {
  switch (state) {
    case _PlayState.myTurnAwaitRoll:
    case _PlayState.noMoveHold:
      return _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0);
    case _PlayState.myTurnAwaitMove:
      return _turnJson(
        seat: 0,
        phase: 'await_move',
        deadlineMs: 45000,
        k: 1,
        value: 4,
        legal: const <int>[0],
      );
    case _PlayState.anotherSeatsTurn:
    case _PlayState.turnSeatOffline:
      return _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0);
  }
}

/// Connects and mounts [state], driving the no-move hold into existence by
/// hand for `_PlayState.noMoveHold` (my own rolled(3, []) then at once seat
/// 1's turn, exactly the realistic "no legal moves, server advances the turn
/// immediately" shape test/no_move_beat_test.dart's own `_landOnNoMove`
/// drives) -- every other state is reachable directly from the room's own
/// first snapshot, since none of the other four depend on screen-local state
/// a snapshot cannot carry.
Future<RoomController> _mountPlayState(
  WidgetTester tester, {
  required _PlayState state,
  required Size surface,
  required Locale locale,
}) async {
  _setSurface(tester, surface);
  final (
    RoomController controller,
    FakeTransport transport,
  ) = await _connectDirect(
    tester,
    seats: _seatsFor(state),
    turn: _initialTurnFor(state),
  );
  await _mount(tester, controller, locale: locale);

  if (state == _PlayState.noMoveHold) {
    final int seqAfterRolled = controller.room!.seq + 1;
    transport.pushText(
      _frame(
        type: 'rolled',
        data: <String, Object?>{
          'seat': 0,
          'value': 3,
          'legal': <int>[],
          'deadline_ms': 45000,
          'k': 1,
          'reveal': 'd' * 64,
          'seq': seqAfterRolled,
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
          'seq': seqAfterRolled + 1,
        },
      ),
    );
    // Bare pumps only, per standing lesson: these flush the microtasks
    // FakeTransport's StreamController and the setState they trigger
    // schedule, never advancing the fake clock the 1500ms hold's own Timer
    // runs on, so the hold is still active once this returns.
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  return controller;
}

String _stateLabel(_PlayState state) => switch (state) {
  _PlayState.myTurnAwaitRoll => 'my turn, awaiting roll',
  _PlayState.myTurnAwaitMove => 'my turn, awaiting move',
  _PlayState.noMoveHold => 'the no-move hold',
  _PlayState.anotherSeatsTurn => "another seat's turn",
  _PlayState.turnSeatOffline => 'the turn seat offline',
};

void main() {
  // ==========================================================================
  // Rule 1 and rule 6, measured together since both read the same two rects
  // (game-seat-pip-strip, game-screen-board) across the same five states.
  // Expected RED on the base per the work order: on b2fddb9 the seat-offline
  // slot and the two-line banner slot between them do not hold one fixed
  // height across all five states (seat-offline's own slot, present in every
  // state, differs in content-driven wrapping between "waiting for Bob" and
  // "Bob is offline"), and the board sits at 57% of the screen width, not
  // 92%.
  // ==========================================================================
  for (final Size surface in const <Size>[
    Size(360, 800),
    Size(390, 844),
    Size(411, 704),
  ]) {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets('rule 1 + rule 6 (${locale.languageCode}, '
          '${surface.width.toInt()}x${surface.height.toInt()}): the pip-strip-'
          'to-board gap and the board rect are identical across all five '
          'playing states, the gap is at most 64dp, and the board\'s side is '
          'at least 92% of the screen width. Kills: a header whose height '
          'changes with which conditional line is showing (the seat-offline '
          'slot, the no-move notice, the banner\'s own wrapping) moving the '
          'board, and a header tall enough to push the board below 92% of the '
          'screen width, which is exactly the regression (86% to 57%) C-250 '
          'exists to undo', (tester) async {
        final List<double> gaps = <double>[];
        final List<Rect> boardRects = <Rect>[];

        for (final _PlayState state in _PlayState.values) {
          final RoomController controller = await _mountPlayState(
            tester,
            state: state,
            surface: surface,
            locale: locale,
          );

          expect(
            find.byKey(_pipStripKey),
            findsOneWidget,
            reason:
                'fixture is broken (${_stateLabel(state)}, '
                '${locale.languageCode}, ${surface.width.toInt()}x'
                '${surface.height.toInt()}): game-seat-pip-strip must be '
                'present',
          );
          expect(
            find.byKey(_boardKey),
            findsOneWidget,
            reason:
                'fixture is broken (${_stateLabel(state)}, '
                '${locale.languageCode}, ${surface.width.toInt()}x'
                '${surface.height.toInt()}): game-screen-board must be '
                'present',
          );

          final Rect pipRect = tester.getRect(find.byKey(_pipStripKey));
          final Rect boardRect = tester.getRect(find.byKey(_boardKey));
          gaps.add(boardRect.top - pipRect.bottom);
          boardRects.add(boardRect);

          await _unmountAndDispose(tester, controller);
        }

        for (int i = 0; i < _PlayState.values.length; i++) {
          expect(
            gaps[i],
            lessThanOrEqualTo(64.0),
            reason:
                'rule 1: the pip-strip-to-board gap must be at most 64dp '
                'in every playing state; state '
                '${_stateLabel(_PlayState.values[i])} measured '
                '${gaps[i]} at ${locale.languageCode} '
                '${surface.width.toInt()}x${surface.height.toInt()}',
          );
          expect(
            gaps[i],
            closeTo(gaps.first, 0.5),
            reason:
                'rule 1: the pip-strip-to-board gap must be the same in '
                'every playing state; '
                '${_stateLabel(_PlayState.values.first)} measured '
                '${gaps.first} and ${_stateLabel(_PlayState.values[i])} '
                'measured ${gaps[i]} at ${locale.languageCode} '
                '${surface.width.toInt()}x${surface.height.toInt()}',
          );

          final double side = math.min(
            boardRects[i].width,
            boardRects[i].height,
          );
          expect(
            side,
            greaterThanOrEqualTo(0.92 * surface.width - 0.5),
            reason:
                'rule 6: the board\'s side must be at least 92% of the '
                'screen width (${(0.92 * surface.width).toStringAsFixed(1)}'
                'dp of ${surface.width}dp); state '
                '${_stateLabel(_PlayState.values[i])} measured a side of '
                '$side at ${locale.languageCode} '
                '${surface.width.toInt()}x${surface.height.toInt()}',
          );
          expect(
            boardRects[i].left,
            closeTo(boardRects.first.left, 0.5),
            reason:
                'rule 6: game-screen-board\'s rect must be identical '
                'across all five playing states (left differs): '
                '${_stateLabel(_PlayState.values.first)}='
                '${boardRects.first} vs '
                '${_stateLabel(_PlayState.values[i])}=${boardRects[i]} at '
                '${locale.languageCode} ${surface.width.toInt()}x'
                '${surface.height.toInt()}',
          );
          expect(
            boardRects[i].top,
            closeTo(boardRects.first.top, 0.5),
            reason:
                'rule 6: game-screen-board\'s rect must be identical '
                'across all five playing states (top differs): '
                '${_stateLabel(_PlayState.values.first)}='
                '${boardRects.first} vs '
                '${_stateLabel(_PlayState.values[i])}=${boardRects[i]} at '
                '${locale.languageCode} ${surface.width.toInt()}x'
                '${surface.height.toInt()}',
          );
          expect(
            boardRects[i].width,
            closeTo(boardRects.first.width, 0.5),
            reason:
                'rule 6: game-screen-board\'s rect must be identical '
                'across all five playing states (width differs): '
                '${_stateLabel(_PlayState.values.first)}='
                '${boardRects.first} vs '
                '${_stateLabel(_PlayState.values[i])}=${boardRects[i]} at '
                '${locale.languageCode} ${surface.width.toInt()}x'
                '${surface.height.toInt()}',
          );
          expect(
            boardRects[i].height,
            closeTo(boardRects.first.height, 0.5),
            reason:
                'rule 6: game-screen-board\'s rect must be identical '
                'across all five playing states (height differs): '
                '${_stateLabel(_PlayState.values.first)}='
                '${boardRects.first} vs '
                '${_stateLabel(_PlayState.values[i])}=${boardRects[i]} at '
                '${locale.languageCode} ${surface.width.toInt()}x'
                '${surface.height.toInt()}',
          );
        }
      });
    }
  }

  // ==========================================================================
  // Rule 2: the banner's own shape (maxLines 1, the string unchanged per
  // state) and the chip's colour, measured on the same five-state mounts
  // rule 1 and rule 6 already need, so no case above pays for a second round
  // of connects. Expected RED on the base: `_turnBannerSlot` sets
  // `maxLines: 2`, and this file's own base carries neither
  // `game-header-chip` nor `game-header-chip-dot` in lib/ at all, so both
  // key lookups fail to find anything (amendment run 71, rule 8).
  // ==========================================================================
  testWidgets(
    'rule 2 / rule 8: game-screen-turn-banner has maxLines 1, renders '
    'exactly the string H2 specifies for each of the five playing states, '
    'game-header-chip\'s BoxDecoration.color is the turn seat\'s colour, and '
    'game-header-chip-dot carries that same colour at full alpha. Kills: a '
    'banner still capped at two lines, a chip left untinted or tinted in a '
    'colour that does not track whichever seat is actually on turn, and a '
    'dot painted at partial alpha',
    (tester) async {
      const Size surface = Size(390, 844);
      for (final _PlayState state in _PlayState.values) {
        final RoomController controller = await _mountPlayState(
          tester,
          state: state,
          surface: surface,
          locale: const Locale('en'),
        );
        final AppLocalizations loc = _locOf(tester);

        expect(
          find.byKey(_bannerKey),
          findsOneWidget,
          reason:
              'fixture is broken (${_stateLabel(state)}): '
              'game-screen-turn-banner must be present',
        );
        final Text banner = tester.widget<Text>(find.byKey(_bannerKey));
        expect(
          banner.maxLines,
          1,
          reason:
              'rule 2: game-screen-turn-banner must cap at maxLines 1 in '
              'every playing state; state ${_stateLabel(state)} had '
              'maxLines ${banner.maxLines}',
        );

        final RoomSnapshot room = controller.room!;
        final String expectedText = _expectedBannerText(
          loc,
          room,
          controller.seat,
        );
        expect(
          banner.data,
          expectedText,
          reason:
              'rule 2: game-screen-turn-banner must keep exactly the string '
              'H2 specifies; state ${_stateLabel(state)} expected '
              '"$expectedText", got "${banner.data}"',
        );

        final int turnSeat = room.turn!.seat;
        final Color seatColor = LudoColors.seats[turnSeat.clamp(0, 3)];

        expect(
          find.byKey(_chipKey),
          findsOneWidget,
          reason:
              'fixture is broken (${_stateLabel(state)}): '
              'game-header-chip must be present',
        );
        final Color chipColor = _decoratedBoxColor(tester, _chipKey);
        expect(
          _sameRgb(chipColor, seatColor),
          isTrue,
          reason:
              'rule 8: game-header-chip\'s BoxDecoration.color must be the '
              'turn seat\'s colour (LudoColors.seats[$turnSeat]=$seatColor, '
              'compared by RGB); state ${_stateLabel(state)} measured '
              '$chipColor',
        );

        expect(
          find.byKey(_chipDotKey),
          findsOneWidget,
          reason:
              'fixture is broken (${_stateLabel(state)}): '
              'game-header-chip-dot must be present',
        );
        final Color dotColor = _decoratedBoxColor(tester, _chipDotKey);
        expect(
          _sameRgb(dotColor, seatColor),
          isTrue,
          reason:
              'rule 8: game-header-chip-dot\'s colour must be the turn '
              'seat\'s colour (LudoColors.seats[$turnSeat]=$seatColor, '
              'compared by RGB); state ${_stateLabel(state)} measured '
              '$dotColor',
        );
        expect(
          dotColor.a,
          1.0,
          reason:
              'rule 8: game-header-chip-dot must carry the turn seat\'s '
              'colour at full alpha; state ${_stateLabel(state)} measured '
              'alpha ${dotColor.a}',
        );

        await _unmountAndDispose(tester, controller);
      }
    },
  );

  // ==========================================================================
  // Rule 2's second half, re-pointed by amendment run 71 (rule 8): the
  // non-colour signal on my own turn is pinned to exactly FontWeight.w700 on
  // game-screen-turn-banner, not left a choice between bold text and an
  // outline. Expected RED on the base: the banner carries no explicit
  // fontWeight at all, on either turn, so neither read equals w700.
  // ==========================================================================
  testWidgets(
    'rule 8: on my own turn, game-screen-turn-banner carries FontWeight.w700, '
    'and it does not on another seat\'s turn. Kills: a chip whose only '
    'signal for "it is my turn" is the colour itself, which P9 (never '
    'colour alone) forbids, and a banner left at its ordinary weight on my '
    'own turn',
    (tester) async {
      const Size surface = Size(390, 844);

      final RoomController myTurn = await _mountPlayState(
        tester,
        state: _PlayState.myTurnAwaitRoll,
        surface: surface,
        locale: const Locale('en'),
      );
      final Text myBanner = tester.widget<Text>(find.byKey(_bannerKey));
      final FontWeight? myWeight = myBanner.style?.fontWeight;
      await _unmountAndDispose(tester, myTurn);

      final RoomController otherTurn = await _mountPlayState(
        tester,
        state: _PlayState.anotherSeatsTurn,
        surface: surface,
        locale: const Locale('en'),
      );
      final Text otherBanner = tester.widget<Text>(find.byKey(_bannerKey));
      final FontWeight? otherWeight = otherBanner.style?.fontWeight;
      await _unmountAndDispose(tester, otherTurn);

      expect(
        myWeight,
        FontWeight.w700,
        reason:
            'rule 8: on my own turn, game-screen-turn-banner must carry '
            'FontWeight.w700; measured $myWeight',
      );
      expect(
        otherWeight,
        isNot(FontWeight.w700),
        reason:
            'rule 8: on another seat\'s turn, game-screen-turn-banner must '
            'not carry FontWeight.w700, or it signals nothing; measured '
            '$otherWeight',
      );
    },
  );

  // ==========================================================================
  // Rule 3, re-pointed by amendment run 71 (rule 8): the countdown's text
  // still updates per second (same contract as the pre-existing countdown
  // proof), and game-header-countdown-ring's own `color` field is the turn
  // seat's at 30s left and the vocabulary red at 9s left. Expected RED on
  // the base: this file's own base carries no game-header-countdown-ring in
  // lib/ at all, so the key lookup fails to find anything.
  // ==========================================================================
  testWidgets(
    'rule 8: game-screen-turn-countdown\'s seconds text decreases every '
    'pumped second; game-header-countdown-ring\'s color field is the turn '
    'seat\'s colour at 30s left and switches to the vocabulary red '
    '(LudoColors.error) at 9s left. Kills: a ring painted with no colour at '
    'all, and a ring that never switches to red in the last 10 seconds',
    (tester) async {
      const Size surface = Size(390, 844);
      final (RoomController controller, _) = await _connectDirect(
        tester,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      _setSurface(tester, surface);
      await _mount(tester, controller);

      expect(
        find.byKey(_countdownKey),
        findsOneWidget,
        reason: 'fixture is broken: game-screen-turn-countdown must be present',
      );
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        45,
        reason: 'fixture is broken: deadline_ms 45000 must read 45 at mount',
      );

      // 45s -> 30s: still above the last-10s threshold, the turn seat's own
      // colour (seat 1, green) expected.
      await tester.pump(const Duration(seconds: 15));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        30,
        reason:
            'rule 3: 15 pumped seconds past a 45000ms deadline must read 30',
      );
      expect(
        find.byKey(_ringKey),
        findsOneWidget,
        reason: 'fixture is broken: game-header-countdown-ring must be present',
      );
      final Color ringColorAt30s = _ringColor(tester);
      expect(
        _sameRgb(ringColorAt30s, LudoColors.seats[1]),
        isTrue,
        reason:
            'rule 8: with 30 seconds left, game-header-countdown-ring\'s '
            'color field must be the turn seat\'s colour '
            '(LudoColors.seats[1]=${LudoColors.seats[1]}); measured '
            '$ringColorAt30s',
      );

      // 30s -> 9s: inside the last 10s, the vocabulary red expected instead.
      await tester.pump(const Duration(seconds: 21));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        9,
        reason: 'rule 3: 21 further pumped seconds must read 9',
      );
      final Color ringColorAt9s = _ringColor(tester);
      expect(
        _sameRgb(ringColorAt9s, LudoColors.error),
        isTrue,
        reason:
            'rule 8: with 9 seconds left, game-header-countdown-ring\'s '
            'color field must be the vocabulary red '
            '(LudoColors.error=${LudoColors.error}); measured '
            '$ringColorAt9s',
      );
    },
  );

  // ==========================================================================
  // Amendment run 72, rule 9 (a/b/c/d): the ring actually paints at the
  // countdown block's own size, the seconds Text inside it is the bare
  // whole number rather than the sentence, the sentence itself moves onto
  // game-header-countdown-semantics with the bare digits excluded from the
  // semantics tree, and the colour rule of rule 8 applies to the digits as
  // well as the ring. Measured at the three sizes of rule 6, en and ar, per
  // this order's own instruction, since rule 9b itself is pinned there too.
  // Expected RED on the base (frames of screenshots run 37268881483,
  // ac19bb3) for 9a, 9b and 9c: _CountdownRing is a childless CustomPaint
  // placed as a non-positioned Stack child, so it paints at Size.zero (9a
  // fails outright, and a non-zero Text rect can never lie inside a
  // zero-size rect, so 9b's containment half fails too); the Text keyed
  // game-screen-turn-countdown still renders loc.gameTurnCountdown(n), the
  // whole sentence, not the bare digits (9b's content half fails too); and
  // game-header-countdown-semantics does not exist anywhere in lib/ on this
  // base, so its key lookup fails to find anything (9c fails on a
  // key-not-found reason). 9d is not claimed red by the work order: the
  // Text's colour already reads the same ringColor local the ring itself
  // is given on this base, so that half of rule 9 may already hold before
  // the ring and the Text are otherwise fixed; this file measures it
  // regardless, since rule 9d is still part of the contract this run owes
  // a test for.
  // ==========================================================================
  for (final Size surface in const <Size>[
    Size(360, 800),
    Size(390, 844),
    Size(411, 704),
  ]) {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets('rule 9a/9b/9c/9d (${locale.languageCode}, '
          '${surface.width.toInt()}x${surface.height.toInt()}): '
          'game-header-countdown-ring renders at least 36x36dp; '
          'game-screen-turn-countdown shows only the bare whole seconds left '
          'on one line (maxLines 1, softWrap false), decreasing as seconds '
          'are pumped, with its rect inside the ring\'s; '
          'game-header-countdown-semantics is a Semantics whose label is '
          'loc.gameTurnCountdown(n) for that same n, with the bare digits '
          'excluded from the semantics tree; and the ring and the digits '
          'alike carry the turn seat\'s colour above 10s left and '
          'LudoColors.error at 10s and below. Kills: a ring laid out at zero '
          'size, a Text still carrying the whole sentence (which cannot fit '
          'inside a 36dp ring and wraps or clips instead), a sentence read '
          'twice by TalkBack (once off the wrapper, once off the bare '
          'digits), and digits left at the wrong colour once the ring\'s own '
          'colour switches to red', (tester) async {
        _setSurface(tester, surface);
        final (RoomController controller, _) = await _connectDirect(
          tester,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
          ],
          turn: _turnJson(
            seat: 1,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller, locale: locale);
        final AppLocalizations loc = _locOf(tester);
        final SemanticsHandle semanticsHandle = tester.ensureSemantics();

        void checkAt(int expectedSeconds, Color expectedColor) {
          final String at =
              '${locale.languageCode} ${surface.width.toInt()}x'
              '${surface.height.toInt()}, ${expectedSeconds}s left';

          expect(
            find.byKey(_ringKey),
            findsOneWidget,
            reason:
                'fixture is broken ($at): game-header-countdown-ring '
                'must be present',
          );
          final Rect ringRect = tester.getRect(find.byKey(_ringKey));
          expect(
            ringRect.width,
            greaterThanOrEqualTo(36.0 - 0.5),
            reason:
                'rule 9a: game-header-countdown-ring must render at '
                'least 36dp wide; measured ${ringRect.width} at $at',
          );
          expect(
            ringRect.height,
            greaterThanOrEqualTo(36.0 - 0.5),
            reason:
                'rule 9a: game-header-countdown-ring must render at '
                'least 36dp tall; measured ${ringRect.height} at $at',
          );

          expect(
            find.byKey(_countdownKey),
            findsOneWidget,
            reason:
                'fixture is broken ($at): game-screen-turn-countdown '
                'must be present',
          );
          final Text secondsText = tester.widget<Text>(
            find.byKey(_countdownKey),
          );
          expect(
            secondsText.data,
            '$expectedSeconds',
            reason:
                'rule 9b: game-screen-turn-countdown must show only the '
                'bare whole seconds left ("$expectedSeconds"), not the '
                'full sentence; got "${secondsText.data}" at $at',
          );
          expect(
            secondsText.maxLines,
            1,
            reason:
                'rule 9b: game-screen-turn-countdown must cap at '
                'maxLines 1; measured ${secondsText.maxLines} at $at',
          );
          expect(
            secondsText.softWrap,
            isFalse,
            reason:
                'rule 9b: game-screen-turn-countdown must set softWrap '
                'false; measured ${secondsText.softWrap} at $at',
          );

          final Rect textRect = tester.getRect(find.byKey(_countdownKey));
          expect(
            _rectInside(textRect, ringRect),
            isTrue,
            reason:
                'rule 9b: game-screen-turn-countdown\'s rendered rect '
                '($textRect) must lie inside '
                'game-header-countdown-ring\'s rect ($ringRect) at $at',
          );

          expect(
            find.byKey(_countdownSemanticsKey),
            findsOneWidget,
            reason:
                'fixture is broken ($at): '
                'game-header-countdown-semantics must be present',
          );
          final Widget semanticsWidget = tester.widget(
            find.byKey(_countdownSemanticsKey),
          );
          expect(
            semanticsWidget,
            isA<Semantics>(),
            reason:
                'rule 9c: game-header-countdown-semantics must be a '
                'Semantics widget; got a '
                '${semanticsWidget.runtimeType} at $at',
          );
          final String expectedSentence = loc.gameTurnCountdown(
            expectedSeconds,
          );
          final Semantics semantics = semanticsWidget as Semantics;
          expect(
            semantics.properties.label,
            expectedSentence,
            reason:
                'rule 9c: game-header-countdown-semantics\'s label must '
                'be loc.gameTurnCountdown($expectedSeconds) '
                '("$expectedSentence"); got '
                '"${semantics.properties.label}" at $at',
          );
          expect(
            find.bySemanticsLabel('$expectedSeconds'),
            findsNothing,
            reason:
                'rule 9c: the bare digits "$expectedSeconds" must not '
                'carry their own semantics label once the sentence lives '
                'on game-header-countdown-semantics, or TalkBack reads '
                'the turn twice; at $at',
          );

          final Color ringColor = _ringColor(tester);
          expect(
            _sameRgb(ringColor, expectedColor),
            isTrue,
            reason:
                'rule 9d: game-header-countdown-ring\'s color field must '
                'be $expectedColor; measured $ringColor at $at',
          );
          final Color? digitColor = secondsText.style?.color;
          expect(
            digitColor != null && _sameRgb(digitColor, expectedColor),
            isTrue,
            reason:
                'rule 9d: game-screen-turn-countdown\'s own colour must '
                'match the ring\'s ($expectedColor); measured '
                '$digitColor at $at',
          );
        }

        final Color seatColor = LudoColors.seats[1];
        checkAt(45, seatColor);

        // 45s -> 30s: still above the last-10s threshold.
        await tester.pump(const Duration(seconds: 15));
        checkAt(30, seatColor);

        // 30s -> 9s: inside the last 10s, the vocabulary red expected.
        await tester.pump(const Duration(seconds: 21));
        checkAt(9, LudoColors.error);

        semanticsHandle.dispose();
      });
    }
  }

  // ==========================================================================
  // Rule 4: the offline line's new position (below the board), and its
  // interplay with the no-move hold. Expected RED on the base: the offline
  // slot sits between the banner and the dice-value slot, above
  // Expanded(LudoBoard), so its top is well above the board's bottom, not
  // below it; and the no-move hold does not suppress it at all.
  // ==========================================================================
  testWidgets(
    'rule 4: with the turn on an offline seat, game-screen-turn-seat-offline '
    'sits below game-screen-board (its top is greater than the board\'s '
    'bottom). Kills: the offline line left in its pre-C-250 slot above the '
    'board',
    (tester) async {
      final RoomController controller = await _mountPlayState(
        tester,
        state: _PlayState.turnSeatOffline,
        surface: const Size(390, 844),
        locale: const Locale('en'),
      );

      expect(
        find.byKey(_offlineKey),
        findsOneWidget,
        reason:
            'fixture is broken: game-screen-turn-seat-offline must be present',
      );
      final Rect offlineRect = tester.getRect(find.byKey(_offlineKey));
      final Rect boardRect = tester.getRect(find.byKey(_boardKey));
      expect(
        offlineRect.top,
        greaterThan(boardRect.bottom),
        reason:
            'rule 4: game-screen-turn-seat-offline must sit below '
            'game-screen-board; offline.top=${offlineRect.top} must exceed '
            'board.bottom=${boardRect.bottom}',
      );

      await _unmountAndDispose(tester, controller);
    },
  );

  testWidgets(
    'rule 4: during a no-move hold whose turn has already moved to an '
    'offline seat, game-no-move-notice is found and game-screen-turn-seat-'
    'offline is not; once the hold ends, the offline line appears. Kills: '
    'the offline line and the no-move notice both showing at once, which '
    'the contract forbids in favour of the no-move notice alone',
    (tester) async {
      _setSurface(tester, const Size(390, 844));
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectDirect(
        tester,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob', connected: false),
        ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final int seqAfterRolled = controller.room!.seq + 1;
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 3,
            'legal': <int>[],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'd' * 64,
            'seq': seqAfterRolled,
          },
        ),
      );
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 1,
            'deadline_ms': 45000,
            'seq': seqAfterRolled + 1,
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        controller.room!.turn?.seat,
        1,
        reason:
            'fixture is broken: the turn must have moved to seat 1 (already '
            'offline) at once with the no-move rolled',
      );
      expect(
        controller.room!.seats[1].connected,
        isFalse,
        reason: 'fixture is broken: seat 1 must be offline from the start',
      );
      expect(
        find.byKey(_noMoveNoticeKey),
        findsOneWidget,
        reason: 'rule 4: during the hold, game-no-move-notice must be present',
      );
      expect(
        find.byKey(_offlineKey),
        findsNothing,
        reason:
            'rule 4: during the hold, game-screen-turn-seat-offline must '
            'wait for the hold to end even though the turn already sits on '
            'the offline seat; the no-move notice takes the slot instead',
      );

      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(_noMoveNoticeKey),
        findsNothing,
        reason: 'rule 4: by 1600ms the no-move notice must be gone',
      );
      expect(
        find.byKey(_offlineKey),
        findsOneWidget,
        reason:
            'rule 4: once the hold ends, game-screen-turn-seat-offline must '
            'appear for the still-offline seat 1',
      );
    },
  );

  // ==========================================================================
  // Rule 5: the dice-value key moves onto a Semantics wrapping the die, with
  // exactly the old line's presence condition, and the string is no longer
  // visible anywhere as a Text. Expected RED on the base: the key is still a
  // plain, visible Text, so `tester.widget<Semantics>` throws a type error.
  // ==========================================================================
  testWidgets(
    'rule 5: with turn.value non-null, game-screen-dice-value is a Semantics '
    'whose label is loc.gameDieValue(v), and no visible Text anywhere '
    'carries that string. Kills: the dice-value line left as a visible Text',
    (tester) async {
      final (RoomController controller, _) = await _connectDirect(
        tester,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 4,
          legal: const <int>[0],
        ),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      expect(
        find.byKey(_diceValueKey),
        findsOneWidget,
        reason:
            'rule 5: with turn.value non-null, game-screen-dice-value must '
            'be present',
      );
      final Widget widget = tester.widget(find.byKey(_diceValueKey));
      expect(
        widget,
        isA<Semantics>(),
        reason:
            'rule 5: game-screen-dice-value must be a Semantics wrapping '
            'the die, not a visible Text; got a ${widget.runtimeType}',
      );
      final Semantics semantics = widget as Semantics;
      expect(
        semantics.properties.label,
        loc.gameDieValue(4),
        reason:
            'rule 5: the Semantics label must be loc.gameDieValue(4) '
            '("${loc.gameDieValue(4)}"); got '
            '"${semantics.properties.label}"',
      );
      expect(
        find.text(loc.gameDieValue(4)),
        findsNothing,
        reason:
            'rule 5: no visible Text anywhere may carry '
            '"${loc.gameDieValue(4)}" once the key moves onto the Semantics '
            'wrapper; the die\'s own face is what a sighted player reads '
            'instead',
      );
    },
  );

  testWidgets(
    'rule 5 (control): with turn.value null, game-screen-dice-value is '
    'absent entirely, exactly as the pre-existing line was. Proves the '
    'Semantics wrapper\'s presence condition was not widened to "always '
    'present"',
    (tester) async {
      final (RoomController controller, _) = await _connectDirect(
        tester,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      expect(
        controller.room!.turn!.value,
        isNull,
        reason: 'fixture is broken: turn.value must be null in await_roll',
      );
      expect(
        find.byKey(_diceValueKey),
        findsNothing,
        reason:
            'rule 5: with turn.value null, game-screen-dice-value must be '
            'absent entirely, not present with an empty label',
      );
    },
  );
}
