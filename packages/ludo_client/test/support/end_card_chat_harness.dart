// Shared driver for the C-485 end card tests (order 488): the one-tap replies
// and the received lines on the end card. Built on c468_harness.dart and
// roll_tray_harness.dart: a real GameScreen over a real RoomController on
// FakeTransport, every state a decoded wire frame, fake time from the pump.
//
// Nothing here names an API C-485 adds, so this file compiles on a tree that
// has none of it: the game screen cases read the new widgets by key only.
// C-500 moves the board's own bubbles into the one header line, so the helper
// for the board's keys now asserts they are gone.
// The direct EndCard mounts that need the new quick-reply parameters live in
// end_card_quick_reply_test.dart, between its BEGIN direct and END direct
// markers.
//
// Every helper keeps the frames and pumps it ran, so a failure message
// replays the scenario.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../net/fake_transport.dart';
import 'c468_harness.dart';
import 'roll_tray_harness.dart';

const Key kQuickRepliesKey = Key('end-card-quick-replies');
const Key kChatLinesKey = Key('end-card-chat-lines');
const Key kChatButtonKey = Key('game-chat-button');
const Key kSheetKey = Key('quick-chat-sheet');
const Key kMuteKey = Key('quick-chat-mute');
const Key kRematchKey = Key('end-card-rematch');
const Key kNewTableKey = Key('game-screen-new-room-button');

Key replyKey(String id) => Key('end-card-reply-$id');

Key chatLineKey(int seat) => Key('end-card-chat-$seat');

Key sheetChipKey(String id) => Key('quick-chat-$id');

const String _replyPrefix = 'end-card-reply-';
const String _linePrefix = 'end-card-chat-';

/// The key names C-500 D6 takes off the board: the old per-seat bubble, the
/// layer that held them and its slots. The one line is `end-card-chat-<seat>`
/// in the header layer on every body, so none of these may be in the tree.
const List<String> kGoneBoardChatKeys = <String>[
  'chat-bubble-',
  'board-chat-layer',
  'board-chat-slot-',
];

/// The ids D5.1 hands each card variant, in order.
const List<String> kWinnerReplies = <String>['good_game', 'ha_ha'];
const List<String> kLoserReplies = <String>['good_game', 'revenge', 'lucky'];
const List<String> kEndedReplies = <String>['good_game'];

/// (id, en, ar) for the lines the end card uses, typed out from C-478 D3 on
/// purpose: a test that read its expectation from the ARB the product writes
/// would prove nothing about the text.
const List<(String, String, String)> kEndLines = <(String, String, String)>[
  ('hi', 'Hi all', 'مرحبا يا جماعة'),
  ('lucky', 'So lucky!', 'شو هالحظ!'),
  ('oops', 'Oops', 'أوبس'),
  ('ha_ha', 'Ha ha ha', 'هههههه'),
  ('revenge', 'I\'ll get you back', 'رح ردّلك ياها'),
  ('good_game', 'Good game', 'لعبة حلوة'),
];

String endLine(String id, {required bool ar}) {
  for (final (String, String, String) row in kEndLines) {
    if (row.$1 == id) {
      return ar ? row.$3 : row.$2;
    }
  }
  throw ArgumentError('no such preset: $id');
}

/// chatSaid(name, line), "{name}: {line}" in both languages (C-478 D3).
String said(String name, String line) => '$name: $line';

int _frameSeq = 0;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) {
  _frameSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c485-id-${_frameSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _finishedTurn() =>
    turnJson(seat: 0, phase: 'finished', k: 1);

/// A `room` snapshot body in wire shape with the two fields the shared
/// helper leaves out: `rematch` and `verify_url`.
Map<String, Object?> endRoomData({
  required String state,
  required List<Map<String, Object?>> seats,
  required int players,
  int? winner,
  String? gameId,
  Map<String, Object?>? turn,
  Map<String, Object?>? rematch,
  String? verifyUrl,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': 0,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': gameId,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'verify_url': ?verifyUrl,
  'rematch': rematch,
};

/// Seat i is called Sam when it is mine and kNames[i] otherwise.
/// [names] overrides that for the seats it names; every other seat is
/// unchanged. [tokens] places the pieces of the seats it names, the rest sit
/// in the yard.
List<Map<String, Object?>> namedSeats(
  int players,
  int me, {
  Map<int, String>? names,
  Map<int, List<int>>? tokens,
}) {
  return <Map<String, Object?>>[
    for (int seat = 0; seat < players; seat++)
      seatJson(
        seat,
        name: names != null && names.containsKey(seat)
            ? names[seat]!
            : (seat == me ? 'Sam' : kNames[seat]!),
        tokens: tokens?[seat] ?? kYard,
      ),
  ];
}

/// The ids of the `end-card-reply-<id>` chips in the tree, in tree order.
List<String> replyIds(WidgetTester tester) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> && key.value.startsWith(_replyPrefix);
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value.substring(_replyPrefix.length),
];

/// The seats whose `end-card-chat-<seat>` is on screen, ascending. The
/// container `end-card-chat-lines` shares the prefix and is not a line.
List<int> chatLineSeats(WidgetTester tester) => <int>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        key.value.startsWith(_linePrefix) &&
        int.tryParse(key.value.substring(_linePrefix.length)) != null;
  }).evaluate())
    int.parse(
      (e.widget.key! as ValueKey<String>).value.substring(_linePrefix.length),
    ),
]..sort();

/// The seats of the lines on screen from the top down.
List<int> chatLinesTopDown(WidgetTester tester) {
  final List<int> seats = chatLineSeats(tester);
  seats.sort(
    (int a, int b) => tester
        .getRect(find.byKey(chatLineKey(a)))
        .top
        .compareTo(tester.getRect(find.byKey(chatLineKey(b))).top),
  );
  return seats;
}

/// The keys in the tree that C-500 D6 removed from the board (see
/// [kGoneBoardChatKeys]), as their string values, in tree order.
List<String> boardChatKeys(WidgetTester tester) => <String>[
  for (final Element e in find.byWidgetPredicate((Widget w) {
    final Key? key = w.key;
    return key is ValueKey<String> &&
        kGoneBoardChatKeys.any(key.value.startsWith);
  }).evaluate())
    (e.widget.key! as ValueKey<String>).value,
];

/// Fails with the scenario when the board still draws any quick message of
/// its own: the line is the header's alone.
void expectNoBoardChat(EndGame g, String what) {
  expect(
    boardChatKeys(g.tester),
    isEmpty,
    reason: g.why(
      '$what: the board draws no chat of its own (chat-bubble-*, '
      'board-chat-layer, board-chat-slot-*), found '
      '${boardChatKeys(g.tester)}',
    ),
  );
}

/// All the text painted under [key], joined with nothing between spans.
String textUnder(WidgetTester tester, Finder root) {
  final Finder rich = find.descendant(
    of: root,
    matching: find.byType(RichText),
  );
  return <String>[
    for (final Element e in rich.evaluate())
      (e.widget as RichText).text.toPlainText(),
  ].join();
}

/// Every Opacity / FadeTransition above the first text under [root],
/// multiplied; with [withTextAlpha] the text's own colour alpha too, so a
/// fade done by colour reads the same as one done by an Opacity.
double alphaUnder(
  WidgetTester tester,
  Finder root, {
  bool withTextAlpha = false,
}) {
  final Finder rich = find.descendant(
    of: root,
    matching: find.byType(RichText),
  );
  double alpha = 1.0;
  final Element start = tester.element(rich.first);
  if (withTextAlpha) {
    alpha *= (start.widget as RichText).text.style?.color?.a ?? 1.0;
  }
  start.visitAncestorElements((Element e) {
    if (e is RenderObjectElement) {
      final RenderObject r = e.renderObject;
      if (r is RenderOpacity) {
        alpha *= r.opacity;
      } else if (r is RenderAnimatedOpacity) {
        alpha *= r.opacity.value;
      }
    }
    return true;
  });
  return alpha;
}

/// Width of the first text under [root] after every transform above it: the
/// scale of a pop-in shows up here.
double textWidthUnder(WidgetTester tester, Finder root) => tester
    .getRect(find.descendant(of: root, matching: find.byType(RichText)).first)
    .width;

/// How a card variant is reached.
enum EndKind { winner, loser, ended }

/// One game screen scenario: the fixture, a clock zero for the last emote,
/// and the frames to move the room along.
class EndGame {
  EndGame(this.s, this.me, this.players, this.seats);

  final Scn s;
  final int me;
  final int players;

  /// The seats the room holds now, in wire shape.
  List<Map<String, Object?>> seats;

  WidgetTester get tester => s.tester;

  RollTrayDrive get drive => s.drive;

  /// Clock reading of the last emote push, the zero of its life.
  int zero = 0;

  int _games = 1;

  String get gameId => 'c485-game-$_games';

  String why(String expected) => s.why(expected);

  Future<void> emote(Object? seat, Object? id, {String? re}) async {
    await s.pushEmote(seat, id, re: re);
    zero = s.clockMs;
  }

  /// Pumps up to [ms] after the last emote push.
  Future<void> at(int ms) async {
    final int target = zero + ms;
    if (target > s.clockMs) {
      await s.pump(Duration(milliseconds: target - s.clockMs));
    }
  }

  Future<void> gameOver(int winner) => s.push('game_over', <String, Object?>{
    'winner': winner,
    'verify_url': 'https://c485-test.invalid/verify/$gameId',
  });

  /// A rematch LOBBY: the finished room's seats, `rematch` set, no game id.
  Future<void> rematchLobby({int by = 1}) => s.push(
    'room',
    endRoomData(
      state: 'LOBBY',
      seats: seats,
      players: players,
      rematch: <String, Object?>{
        'by': by,
        'ready': <int>[by],
      },
    ),
  );

  /// The rematch starting: `game_started` then the first `turn`.
  Future<void> startRematchGame({int turnSeat = 1}) async {
    _games += 1;
    await s.push('game_started', <String, Object?>{
      'turn': turnSeat,
      'game_id': gameId,
      'client_seeds': 'a,b',
    });
    await s.push('turn', turnFrame(turnSeat));
  }

  Future<void> playerLeft(int seat) async {
    seats = <Map<String, Object?>>[
      for (final Map<String, Object?> row in seats)
        if (row['seat'] != seat) row,
    ];
    await s.push('player_left', <String, Object?>{'seat': seat});
  }

  /// The `emote` requests sent from index [from] on.
  List<Map<String, Object?>> emotesSent(int from) =>
      emotesSince(drive.transport, from);

  int get sentCount => drive.transport.sentRaw.length;

  /// The server's copy of the last emote this device sent after [from].
  Future<String> answerEmote(int from, {required String id}) async {
    final String request = requestIdOf(
      drive.transport.sentRaw
          .skip(from)
          .lastWhere((String t) => frameType(t) == 'emote'),
    );
    await emote(me, id, re: request);
    return request;
  }

  Future<void> done() => releaseGame(tester, drive);
}

Future<EndGame> _open(
  WidgetTester tester,
  String name, {
  required String state,
  required bool seated,
  required int me,
  required int players,
  required Locale locale,
  required double textScale,
  required bool reduced,
  required Size size,
  int? winner,
  Map<String, Object?>? turn,
  Map<int, String>? names,
  Map<int, List<int>>? tokens,
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = size;
  final List<Map<String, Object?>> seats = namedSeats(
    players,
    me,
    names: names,
    tokens: tokens,
  );
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: me,
    players: players,
    gameId: 'c485-game-1',
    state: state,
    winner: winner,
    sendSeatAssigned: seated,
  );
  await mountGame(
    tester,
    drive,
    locale: locale,
    textScale: textScale,
    disableAnimations: reduced,
  );
  return EndGame(Scn(name, tester, drive), me, players, seats);
}

/// A game in PLAYING, mounted, nobody has moved.
Future<EndGame> openPlaying(
  WidgetTester tester,
  String name, {
  int me = 0,
  int players = 2,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool reduced = false,
  Size size = const Size(360, 800),
  Map<int, String>? names,
  Map<int, List<int>>? tokens,
}) => _open(
  tester,
  name,
  state: 'PLAYING',
  seated: true,
  me: me,
  players: players,
  locale: locale,
  textScale: textScale,
  reduced: reduced,
  size: size,
  turn: awaitRollTurn(me == 0 ? 1 : 0),
  names: names,
  tokens: tokens,
);

/// A held end (C-270): the other seat's last piece walks 51 to 57 and
/// `game_over` names that seat, so the board stays up with no end card while
/// the piece is still walking. Fails with the scenario when the screen is not
/// holding. The winner is seat 1. The caller pushes its own emotes and reads
/// [EndGame.zero] from them. [beforeEnd] runs while the room is still
/// PLAYING, before the last move, for a line that is up when the game ends.
Future<EndGame> openHeldEnd(
  WidgetTester tester,
  String name, {
  Future<void> Function(EndGame g)? beforeEnd,
}) async {
  final EndGame g = await openPlaying(
    tester,
    name,
    tokens: <int, List<int>>{
      1: <int>[51, -1, -1, -1],
    },
  );
  if (beforeEnd != null) {
    await beforeEnd(g);
  }
  await g.s.push('moved', movedFrame(1, 0, 51, 57));
  await g.gameOver(1);
  await g.s.pump(const Duration(milliseconds: 20));
  expect(
    find.byKey(boardKey),
    findsOneWidget,
    reason: g.why('fixture: the board is still the body in the held end'),
  );
  expect(
    find.byKey(const Key('game-screen-winner')),
    findsNothing,
    reason: g.why('fixture: no end card while the last piece walks'),
  );
  return g;
}

/// A game that ended on screen: mounted in PLAYING, then `game_over`. The
/// winner is this seat for [EndKind.winner] and the next seat otherwise.
/// [EndKind.ended] is a FINISHED room with no winner named, which a
/// `game_over` frame cannot carry, so it is reached by a FINISHED reply.
Future<EndGame> openFinished(
  WidgetTester tester,
  String name, {
  EndKind kind = EndKind.loser,
  int me = 0,
  int players = 2,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  bool reduced = false,
  Size size = const Size(360, 800),
  Map<int, String>? names,
}) async {
  if (kind == EndKind.ended) {
    return _open(
      tester,
      name,
      state: 'FINISHED',
      seated: true,
      me: me,
      players: players,
      locale: locale,
      textScale: textScale,
      reduced: reduced,
      size: size,
      winner: null,
      turn: _finishedTurn(),
      names: names,
    );
  }
  final EndGame g = await openPlaying(
    tester,
    name,
    me: me,
    players: players,
    locale: locale,
    textScale: textScale,
    reduced: reduced,
    size: size,
    names: names,
  );
  final int winner = kind == EndKind.winner ? me : (me == 0 ? 1 : 0);
  await g.gameOver(winner);
  await g.s.pump(const Duration(milliseconds: 100));
  return g;
}

/// FINISHED with a winner, but this device holds no seat.
Future<EndGame> openSpectator(
  WidgetTester tester,
  String name, {
  Locale locale = const Locale('en'),
}) => _open(
  tester,
  name,
  state: 'FINISHED',
  seated: false,
  me: 0,
  players: 2,
  locale: locale,
  textScale: 1.0,
  reduced: false,
  size: const Size(360, 800),
  winner: 1,
  turn: _finishedTurn(),
);

/// A first-game LOBBY: the screen is mounted, no game has been played.
Future<EndGame> openFirstLobby(WidgetTester tester, String name) => _open(
  tester,
  name,
  state: 'LOBBY',
  seated: true,
  me: 0,
  players: 2,
  locale: const Locale('en'),
  textScale: 1.0,
  reduced: false,
  size: const Size(360, 800),
);

/// Opens the sheet from the header button, flips the mute switch and closes
/// the sheet by its barrier. Only possible while the room is PLAYING.
Future<void> toggleMute(EndGame g) async {
  g.s.steps.add('open sheet, flip mute, close');
  await g.tester.tap(find.byKey(kChatButtonKey));
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 400));
  expect(find.byKey(kSheetKey), findsOneWidget, reason: g.why('sheet opens'));
  final Finder keyed = find.byKey(kMuteKey);
  final Finder sw = g.tester.widget(keyed) is Switch
      ? keyed
      : find.descendant(of: keyed, matching: find.byType(Switch));
  await g.tester.tap(sw);
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 300));
  await g.tester.tapAt(const Offset(180, 20));
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 400));
  expect(find.byKey(kSheetKey), findsNothing, reason: g.why('sheet closes'));
}

/// Taps the chip [id] on the card and lets the send go out.
Future<void> tapReply(EndGame g, String id) async {
  g.s.steps.add('tap end-card-reply-$id');
  expect(
    find.byKey(replyKey(id)),
    findsOneWidget,
    reason: g.why('end-card-reply-$id is on screen to be tapped'),
  );
  await g.tester.ensureVisible(find.byKey(replyKey(id)));
  await g.tester.tap(find.byKey(replyKey(id)));
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 100));
}

/// The drawn opacity of the chip [id]: ancestors times its text colour.
double chipAlpha(WidgetTester tester, String id) =>
    alphaUnder(tester, find.byKey(replyKey(id)), withTextAlpha: true);

/// [chipAlpha] that fails with the scenario when the chip is not there.
double chipAlphaOf(EndGame g, String id) {
  expect(
    find.byKey(replyKey(id)),
    findsOneWidget,
    reason: g.why('end-card-reply-$id is on screen'),
  );
  return chipAlpha(g.tester, id);
}

/// The finder for `end-card-chat-<seat>`; fails with the scenario when the
/// line is not on screen.
Finder lineOf(EndGame g, int seat) {
  expect(
    find.byKey(chatLineKey(seat)),
    findsOneWidget,
    reason: g.why('end-card-chat-$seat is on screen'),
  );
  return find.byKey(chatLineKey(seat));
}

/// The rect of the widget keyed [key]; fails with the scenario when it is
/// not on screen.
Rect rectOf(EndGame g, Key key) {
  expect(find.byKey(key), findsOneWidget, reason: g.why('$key is on screen'));
  return g.tester.getRect(find.byKey(key));
}

/// The server's `room` reply to [re] for a finished game (a resume).
String finishedReply(EndGame g, {required String re, required int seq}) =>
    _frame(
      type: 'room',
      re: re,
      data: <String, Object?>{
        ...endRoomData(
          state: 'FINISHED',
          seats: g.seats,
          players: g.players,
          winner: g.me == 0 ? 1 : 0,
          gameId: g.gameId,
          turn: _finishedTurn(),
          verifyUrl: 'https://c485-test.invalid/verify/${g.gameId}',
        ),
        'seq': seq,
      },
    );

/// Drops the socket and resumes it on a fresh one; the reply is the finished
/// room again. Leaves the controller connected.
Future<void> dropAndResume(EndGame g) async {
  g.s.steps.add('far side closes');
  g.drive.transport.endFromFarSide();
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 100));
  final FakeTransport next = FakeTransport();
  g.drive.enqueueTransport(next);
  final Future<void> reconnect = g.drive.controller.reconnect();
  await g.tester.runAsync(() => pumpEventQueue());
  await g.tester.pump();
  final String id = requestIdOf(
    next.sentRaw.lastWhere((String t) => frameType(t) == 'resume'),
  );
  g.s.steps.add('resume answered with the finished room');
  next.pushText(finishedReply(g, re: id, seq: g.drive.lastSeq + 1));
  await reconnect;
  await g.tester.pump();
  await g.s.pump(const Duration(milliseconds: 100));
}

/// Pushes a frame whose seq jumps ahead, so the controller resyncs, and
/// answers the `resume` it sends with the finished room.
Future<void> gapAndResync(EndGame g) async {
  final int sent = g.sentCount;
  g.drive.lastSeq += 4;
  g.s.steps.add('seq gap');
  await g.s.push('turn', turnFrame(0));
  final List<String> types = sentTypesSince(g.drive.transport, sent);
  expect(
    types,
    contains('resume'),
    reason: g.why('fixture: a gap starts a resync, sent $types'),
  );
  final String id = requestIdOf(
    g.drive.transport.sentRaw
        .skip(sent)
        .firstWhere((String t) => frameType(t) == 'resume'),
  );
  await pushRaw(
    g.tester,
    g.drive,
    finishedReply(g, re: id, seq: g.drive.lastSeq + 1),
  );
  await g.s.pump(const Duration(milliseconds: 50));
}

/// Collects (text, resolved style) for the leaves of [span].
List<(String, TextStyle)> spanLeaves(InlineSpan span, [TextStyle? parent]) {
  if (span is! TextSpan) {
    return const <(String, TextStyle)>[];
  }
  final TextStyle style = (parent ?? const TextStyle()).merge(span.style);
  return <(String, TextStyle)>[
    if (span.text != null) (span.text!, style),
    for (final InlineSpan child in span.children ?? const <InlineSpan>[])
      ...spanLeaves(child, style),
  ];
}
