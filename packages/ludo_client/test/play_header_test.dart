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
// Ambiguity found while writing this file, reported rather than invented
// around: C-250 rule 2 (the chip, the dot) and rule 3 (the ring) describe
// visual properties -- a tinted rounded chip, a filled dot, a ring that
// depletes and changes colour -- but name no test key for any of the three,
// unlike rule 4's `game-screen-turn-seat-offline` and rule 5's
// `game-screen-dice-value`, which are both pinned by name. The implementing
// worker is free to build the chip, the dot and the ring out of any widget
// shape (Container, DecoratedBox, Material, a custom CustomPainter ring, an
// Icon-drawn dot, and so on), and this file has not read what they in fact
// chose. What is used below instead is colour presence scoped by exclusion:
// every colour-bearing widget (Text, RichText, Icon, DecoratedBox, Container,
// Material, ColoredBox -- the same vocabulary test/end_card_test.dart's own
// `_colorsUnder` already reads colours from, copied by hand and extended
// here) anywhere under GameScreen that is NOT also a descendant of
// game-screen-board, game-seat-pip-strip or game-die is treated as "the
// header's own colour", since those three are the only other seat-coloured
// regions C-250 rule 7 leaves untouched. This proves the turn seat's colour
// (or the vocabulary red) appears somewhere in the header; it cannot prove
// which of the chip, the dot or the ring carries it, or distinguish a chip
// from a dot structurally beyond counting matching nodes. If the real
// implementation paints the ring purely on a Canvas with no colour-bearing
// widget property and no key of its own, this scoped scan cannot see it, and
// rule 3's colour assertions would need a key or an exposed `color` field
// added to prove against. This was not invented around; it is the
// exclusion-scan technique used throughout, with its limits stated here
// once rather than repeated at each call site.

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
const Key _dieKey = Key('game-die');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _offlineKey = Key('game-screen-turn-seat-offline');
const Key _noMoveNoticeKey = Key('game-no-move-notice');
const Key _diceValueKey = Key('game-screen-dice-value');

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

// --- colour scanning, scoped by exclusion (see header comment) -------------

void _collectSpanColors(InlineSpan span, Set<Color> out) {
  if (span is TextSpan) {
    final Color? color = span.style?.color;
    if (color != null) {
      out.add(color);
    }
    span.children?.forEach(
      (InlineSpan child) => _collectSpanColors(child, out),
    );
  }
}

/// Every colour a single widget carries directly (its own fill, its text
/// colour, its border), not its descendants'. Mirrors and extends
/// test/end_card_test.dart's own `_colorsUnder` vocabulary (Text, RichText,
/// Icon, DecoratedBox), copied by hand, plus Container, Material and
/// ColoredBox -- the other ordinary ways Flutter code tints a chip or a
/// dot.
Set<Color> _ownColors(Widget widget) {
  final Set<Color> colors = <Color>{};
  if (widget is Text) {
    final Color? color = widget.style?.color;
    if (color != null) {
      colors.add(color);
    }
    final InlineSpan? span = widget.textSpan;
    if (span != null) {
      _collectSpanColors(span, colors);
    }
  } else if (widget is RichText) {
    _collectSpanColors(widget.text, colors);
  } else if (widget is Icon) {
    final Color? color = widget.color;
    if (color != null) {
      colors.add(color);
    }
  } else if (widget is DecoratedBox) {
    final Decoration decoration = widget.decoration;
    if (decoration is BoxDecoration) {
      if (decoration.color != null) {
        colors.add(decoration.color!);
      }
      final Border? border = decoration.border as Border?;
      if (border != null) {
        colors.add(border.top.color);
      }
    }
  } else if (widget is Container) {
    if (widget.color != null) {
      colors.add(widget.color!);
    }
    final Decoration? decoration = widget.decoration;
    if (decoration is BoxDecoration) {
      if (decoration.color != null) {
        colors.add(decoration.color!);
      }
      final Border? border = decoration.border as Border?;
      if (border != null) {
        colors.add(border.top.color);
      }
    }
  } else if (widget is Material) {
    if (widget.color != null) {
      colors.add(widget.color!);
    }
  } else if (widget is ColoredBox) {
    colors.add(widget.color);
  }
  return colors;
}

/// Every [Element] under [root] (inclusive) that is also a descendant of (or
/// equal to) one of the roots found at [excludeKeys].
Set<Element> _excludedElements(
  WidgetTester tester,
  Finder root,
  List<Key> excludeKeys,
) {
  final Set<Element> excluded = <Element>{};
  for (final Key key in excludeKeys) {
    final Finder finder = find.byKey(key);
    if (finder.evaluate().isEmpty) {
      continue;
    }
    excluded.add(tester.element(finder));
    excluded.addAll(
      find
          .descendant(of: finder, matching: find.byWidgetPredicate((_) => true))
          .evaluate(),
    );
  }
  return excluded;
}

/// How many colour-bearing nodes under the mounted `GameScreen`, excluding
/// `game-screen-board`, `game-seat-pip-strip` and `game-die` (the header's
/// only siblings that are already, legitimately, seat-coloured), carry
/// [color] directly. Zero means "not found anywhere in the header"; one or
/// more is a count of distinct matching nodes, used below to tell "the
/// colour appears once" (a chip alone, say) from "it appears on at least two
/// separate nodes" (consistent with a chip and a separate dot both carrying
/// it, though this count alone cannot prove which node is which).
int _headerColorNodeCount(WidgetTester tester, Color color) {
  final Finder screen = find.byType(GameScreen);
  if (screen.evaluate().isEmpty) {
    return 0;
  }
  final Set<Element> excluded = _excludedElements(tester, screen, <Key>[
    _boardKey,
    _pipStripKey,
    _dieKey,
  ]);
  int count = 0;
  for (final Element element in <Element>[
    tester.element(screen),
    ...find
        .descendant(of: screen, matching: find.byWidgetPredicate((_) => true))
        .evaluate(),
  ]) {
    if (excluded.contains(element)) {
      continue;
    }
    if (_ownColors(element.widget).contains(color)) {
      count += 1;
    }
  }
  return count;
}

bool _headerHasColor(WidgetTester tester, Color color) =>
    _headerColorNodeCount(tester, color) > 0;

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
  // `maxLines: 2`, and there is no seat-tinted node outside the board, the
  // pip strip and the die at all.
  // ==========================================================================
  testWidgets(
    'rule 2: game-screen-turn-banner has maxLines 1, renders exactly the '
    'string H2 specifies for each of the five playing states, and the turn '
    'seat\'s own colour appears somewhere in the header outside the board, '
    'the pip strip and the die. Kills: a banner still capped at two lines, '
    'and a chip left untinted or tinted in a colour that does not track '
    'whichever seat is actually on turn',
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
          _headerHasColor(tester, seatColor),
          isTrue,
          reason:
              'rule 2: the turn seat\'s own colour '
              '(LudoColors.seats[$turnSeat]) must appear on the chip '
              'somewhere in the header, outside game-screen-board, '
              'game-seat-pip-strip and game-die; state '
              '${_stateLabel(state)} found none',
        );

        await _unmountAndDispose(tester, controller);
      }
    },
  );

  // ==========================================================================
  // Rule 2's second half: on my own turn, a non-colour signal (bold text or
  // an outline in my colour) is present that is not present when the turn
  // belongs to another seat. Expected RED on the base: the banner carries no
  // FontWeight.bold and no bordered chip at all, on either turn.
  // ==========================================================================
  testWidgets(
    'rule 2: on my own turn, game-screen-turn-banner is bold or the header '
    'carries a border in my own colour that is absent when the turn belongs '
    'to another seat. Kills: a chip whose only signal for "it is my turn" '
    'is the colour itself, which P9 (never colour alone) forbids',
    (tester) async {
      const Size surface = Size(390, 844);

      final RoomController myTurn = await _mountPlayState(
        tester,
        state: _PlayState.myTurnAwaitRoll,
        surface: surface,
        locale: const Locale('en'),
      );
      final Text myBanner = tester.widget<Text>(find.byKey(_bannerKey));
      final bool myBold = myBanner.style?.fontWeight == FontWeight.bold;
      final bool myOutline = _headerHasColor(
        tester,
        LudoColors.seats[0],
      ); // colour already proved above; re-read for the border-aware count
      final int myOutlineCount = _headerColorNodeCount(
        tester,
        LudoColors.seats[0],
      );
      await _unmountAndDispose(tester, myTurn);

      final RoomController otherTurn = await _mountPlayState(
        tester,
        state: _PlayState.anotherSeatsTurn,
        surface: surface,
        locale: const Locale('en'),
      );
      final Text otherBanner = tester.widget<Text>(find.byKey(_bannerKey));
      final bool otherBold = otherBanner.style?.fontWeight == FontWeight.bold;
      final int otherSeatColorOnMyTurnCount = _headerColorNodeCount(
        tester,
        LudoColors.seats[0],
      );
      await _unmountAndDispose(tester, otherTurn);

      expect(
        myOutline,
        isTrue,
        reason:
            'fixture is broken: my own seat\'s colour must appear in the '
            'header while the turn is mine',
      );

      final bool nonColourSignalPresent =
          (myBold && !otherBold) ||
          (myOutlineCount > otherSeatColorOnMyTurnCount);
      expect(
        nonColourSignalPresent,
        isTrue,
        reason:
            'rule 2: my own turn must carry a non-colour difference -- bold '
            'banner text, or an extra outline-coloured node in my own '
            'colour -- that another seat\'s turn does not; measured bold='
            '$myBold (mine) vs $otherBold (other), and my-colour node count='
            '$myOutlineCount (mine) vs $otherSeatColorOnMyTurnCount (other, '
            'where my colour should carry no special meaning at all)',
      );
    },
  );

  // ==========================================================================
  // Rule 3: the countdown's text still updates per second (same contract as
  // the pre-existing countdown proof), and its colour is the turn seat's at
  // 30s left and the vocabulary red at 9s left. Expected RED on the base:
  // the countdown Text carries no explicit colour, so neither LudoColors
  // .seats[1] nor LudoColors.error is ever found.
  // ==========================================================================
  testWidgets(
    'rule 3: game-screen-turn-countdown\'s seconds text decreases every '
    'pumped second; the header carries the turn seat\'s colour at 30s left '
    'and switches to the vocabulary red (LudoColors.error) at 9s left. '
    'Kills: a countdown with no colour at all, and a ring that never '
    'switches to red in the last 10 seconds',
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
        _headerHasColor(tester, LudoColors.seats[1]),
        isTrue,
        reason:
            'rule 3: with 30 seconds left, the turn seat\'s own colour '
            '(LudoColors.seats[1]) must appear in the header outside '
            'game-screen-board, game-seat-pip-strip and game-die',
      );

      // 30s -> 9s: inside the last 10s, the vocabulary red expected instead.
      await tester.pump(const Duration(seconds: 21));
      expect(
        _wholeSecondsShown(tester, _countdownKey),
        9,
        reason: 'rule 3: 21 further pumped seconds must read 9',
      );
      expect(
        _headerHasColor(tester, LudoColors.error),
        isTrue,
        reason:
            'rule 3: with 9 seconds left, the vocabulary red '
            '(LudoColors.error) must appear in the header outside '
            'game-screen-board, game-seat-pip-strip and game-die',
      );
    },
  );

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
