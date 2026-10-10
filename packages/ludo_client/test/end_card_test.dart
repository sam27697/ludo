// Conformance tests for work/ludo/orders/C-243-end-card.md's "What proves
// it" section, read line by line, against the GameScreen that section's own
// companion order (243, lib/src/end_card.dart and the _gameOverBody that
// builds it) is implementing in parallel, in a tree this file's author has
// not opened. Base for both orders: order/238-idle-die-face at f02f805,
// which carries PR #87's feedback wiring (win/game_over cues already fire on
// game_over; this file never asserts on those cues, that is C-236's own
// file).
//
// On the base, before 243: lib/src/end_card.dart does not exist and none of
// AppLocalizations' end* getters exist, so this file does not compile.
// Every symbol below that the contract itself names, for the master to
// check against 243's actual code:
//   Widgets/keys: end-card-win, end-card-celebration, end-card-lose,
//     end-card-ended, end-card-stat-rolls, end-card-stat-sixes,
//     end-card-stat-captures, end-card-stat-home, end-card-fair-hint
//     (plus the kept keys game-screen-winner, game-screen-roll-history,
//     game-screen-board, game-screen-verify-button,
//     game-screen-new-room-button, game-screen-appbar-leave, already on
//     base).
//   AppLocalizations getters: endWinTitle, endLoseTitle(name), endLoseNudge,
//     endStatRolls, endStatSixes, endStatCaptures, endStatHome, endFairLine,
//     endFairCheck, endFairHint (gameOverEnded is already on base, kept).
//   theme.dart: LudoColors.gold (new constant this file reads directly,
//     never through Theme.of, matching how LudoColors.seats and
//     LudoColors.error are already read elsewhere in lib/).
//
// GameScreen is driven the same way test/feedback_wiring_test.dart and
// test/play_surface_die_test.dart do: a real RoomController sits over a
// FakeTransport (test/net/fake_transport.dart, read-only). The fake-transport
// idiom (_Connector, _connectTo, the frame/room/turn JSON builders, the
// "one pushed frame needs two pumps" rule) is copied from those files rather
// than imported, per this order's own instruction never to import across
// test files. Every claim about the numbers is reached by decoding real
// `rolled`/`moved`/`game_over` frames through RoomController's own path and
// letting GameScreen's own frame list feed computeGameStats; this file never
// calls computeGameStats itself to get an expected value, per the order.
//
// Standing lessons from this project's own suite, carried into this file:
// no pumpEventQueue() in a testWidgets body (runAsync only, inside
// _connectTo); no pumpAndSettle anywhere (the celebration is bounded but
// this file proves that bound itself, so it never leans on pumpAndSettle to
// do it); one mount per test case, a fresh connection every time; every
// controller is disposed through addTearDown, matching every other file in
// this suite; every FakeTransport frame this file pushes is one this
// RoomController's own reducers accept (seq = room.seq + 1 for every
// state-changing type), so no accidental resync ever opens a wire request
// this file would then owe an answer to; every `rolled` here carries a
// four-token `legal` list, never a single-token one, so the unique-legal
// auto-move hold (a different order's feature) never arms and never queues
// a `move` this file would also owe an answer to.
//
// One deliberate, reported choice: C-232's `complete: false` (a hole in the
// frames a reconnect leaves) is produced here without ever triggering
// RoomController's own resync. A `pong` frame -- docs/PROTOCOL.md section 5
// lists it outside the "carrying seq" set RoomController reduces, so pushing
// one with a seq that breaks the chain changes nothing in room state and
// opens no resync request, while still reaching computeGameStats's own
// contiguity scan over every frame in the window regardless of type. This
// reads the two contracts (C-243 and C-232) as consistent: the gap this file
// manufactures is exactly the shape C-232's own suite (test/game_stats_test
// .dart, "a room snapshot whose own seq breaks the chain") already proves
// breaks completeness, just produced without touching the controller's own
// state machine.
//
// A second thing worth flagging rather than guessing past: test/
// game_screen_test.dart's own H7.19 ("winner is my seat shows
// loc.gameOverYouWin") reads the game-screen-winner title text literally
// against the pre-243 wording. C-243 rule 2 renames that same title, on the
// same kept key, to `endWinTitle`. This file follows the contract's own
// words ("title text is endWinTitle") rather than the older file's
// assertion; whether game_screen_test.dart's H7.19/H7.20 groups get updated
// alongside 243 is outside this order's file list and is reported here for
// the master rather than patched.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;
import 'package:path/path.dart' as p;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://end-card-test.invalid/ws';

const Key _winKey = Key('end-card-win');
const Key _celebrationKey = Key('end-card-celebration');
const Key _loseKey = Key('end-card-lose');
const Key _endedKey = Key('end-card-ended');
const Key _statRollsKey = Key('end-card-stat-rolls');
const Key _statSixesKey = Key('end-card-stat-sixes');
const Key _statCapturesKey = Key('end-card-stat-captures');
const Key _statHomeKey = Key('end-card-stat-home');
const Key _fairHintKey = Key('end-card-fair-hint');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _winnerTitleKey = Key('game-screen-winner');
const Key _rollHistoryKey = Key('game-screen-roll-history');
const Key _boardKey = Key('game-screen-board');

const List<String> _urlLauncherChannels = <String>[
  'plugins.flutter.io/url_launcher',
  'plugins.flutter.io/url_launcher_macos',
  'plugins.flutter.io/url_launcher_linux',
  'plugins.flutter.io/url_launcher_windows',
  'plugins.flutter.io/url_launcher_web',
  'plugins.flutter.io/url_launcher_android',
  'plugins.flutter.io/url_launcher_ios',
];

// --- server-side id generation, mirroring the sibling suites ----------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'end-card-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot ---------------

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
  List<Map<String, Object?>>? seats,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
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

/// Connects a fresh controller and lands it directly on the given [turn] (or
/// a null turn), mySeat always 0. Copied from test/feedback_wiring_test.dart
/// and test/play_surface_die_test.dart's own _connectTo, not imported, per
/// this order's instruction never to import across test files.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
  List<Map<String, Object?>>? seats,
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
      data: _roomJson(
        state: state,
        seats: seats ?? _twoSeats,
        turn: turn,
        winner: winner,
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

Widget _harness(
  Widget child, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
  double textScale = 1.0,
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
        data: data.copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      );
    },
    home: child,
  );
}

/// Mounts GameScreen at a realistic phone size -- test/game_verify_card_test
/// .dart's own choice for this exact finished body, copied here because the
/// end card adds a celebration and four stat tiles on top of what that file
/// already measured at 390x844, so an unrealistically large test surface
/// would hide a real overflow 243's own layout might have.
Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: controller),
      locale: locale,
      disableAnimations: disableAnimations,
      textScale: textScale,
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// A tiny DSL over FakeTransport.pushText for a scripted game: every call
/// stamps the next contiguous `seq` RoomController's own reducers require
/// (docs/PROTOCOL.md section 6) and flushes with the two bare pumps this
/// suite's own standing idiom needs to drain a StreamController's
/// microtasks (test/feedback_wiring_test.dart's own comment on the same
/// point) -- never a pump(Duration), so nothing here ever advances a live
/// countdown or the celebration's own clock by accident.
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

  Future<void> gameStarted({
    required int turnSeat,
    String gameId = 'end-card-game',
    String clientSeeds = 'sam-seed,bob-seed',
  }) => _push('game_started', <String, Object?>{
    'turn': turnSeat,
    'game_id': gameId,
    'client_seeds': clientSeeds,
  });

  Future<void> turn({required int seat, int deadlineMs = 45000}) =>
      _push('turn', <String, Object?>{'seat': seat, 'deadline_ms': deadlineMs});

  Future<void> rolled({
    required int seat,
    required int value,
    required int k,
    int deadlineMs = 45000,
  }) => _push('rolled', <String, Object?>{
    'seat': seat,
    'value': value,
    'legal': const <int>[0, 1, 2, 3],
    'deadline_ms': deadlineMs,
    'k': k,
    'reveal': 'a' * 64,
  });

  Future<void> moved({
    required int seat,
    required int token,
    required int from,
    required int to,
    List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
    bool extraRoll = false,
  }) => _push('moved', <String, Object?>{
    'seat': seat,
    'token': token,
    'from': from,
    'to': to,
    'captured': captured,
    'extra_roll': extraRoll,
  });

  Future<void> gameOver({required int winner, required String verifyUrl}) =>
      _push('game_over', <String, Object?>{
        'winner': winner,
        'verify_url': verifyUrl,
      });

  /// A `pong` -- docs/PROTOCOL.md section 5's "carrying seq" list does not
  /// include it, so RoomController never reduces it and never resyncs over
  /// it, but computeGameStats's own contiguity scan (test/game_stats_test
  /// .dart, definition 7) walks every frame in the window regardless of
  /// type. Pushing one with [seqValue] off the running chain manufactures
  /// exactly the hole C-232 calls `complete: false`, without ever touching
  /// RoomController's state machine. Does not advance the internal seq
  /// counter real frames use.
  Future<void> pong({required int seqValue}) async {
    transport.pushText(
      _frame(type: 'pong', data: <String, Object?>{'seq': seqValue}),
    );
    await tester.pump();
    await tester.pump();
  }
}

/// C-270 amendment (order 271): every scripted game below pushes at least
/// one `moved` frame with `from != to` immediately before its own
/// `gameOver()` call. Contract C-270 rule 1 counts that frame whether or
/// not lib/src/board.dart's own travel-pattern match ever actually starts
/// an animation for it (several of the frames below jump straight to a
/// final progress a real single roll could never reach, e.g. -1 to 57, so
/// the board snaps rather than travels) -- either way the count is above 0
/// when `gameOver()`'s own game_over frame lands, so C-270's end hold takes
/// every one of these scripts, same as a real travelling move would. This
/// helper pumps kEndCardHoldLimit, in bounded chunks (lesson 36), which
/// bounds the hold at its outer edge regardless of which of rule 4's three
/// release paths actually applies to a given script, so every downstream
/// case built from these helpers keeps seeing the end card it always
/// asserted on, with no assertion removed, loosened, or changed at its end.
Future<void> _pumpPastEndCardHold(WidgetTester tester) async {
  Duration remaining = kEndCardHoldLimit;
  const Duration chunk = Duration(milliseconds: 250);
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
}

// --- scripted games, one per scenario ---------------------------------------

const String _winVerifyUrl = 'https://end-card-test.invalid/verify/win';
const String _loseVerifyUrl = 'https://end-card-test.invalid/verify/lose';
const String _numbersVerifyUrl = 'https://end-card-test.invalid/verify/numbers';
const String _gapVerifyUrl = 'https://end-card-test.invalid/verify/gap';

/// Minimal win: mySeat (0) is the winner. Used by every group that only
/// needs a well-formed win, not exact numbers (celebration, fairness,
/// Arabic, kept-keys).
Future<(RoomController, FakeTransport)> _minimalWinGame(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    turn: null,
  );
  await _mount(
    tester,
    controller,
    locale: locale,
    disableAnimations: disableAnimations,
    size: size,
    textScale: textScale,
  );
  final _GameScript script = _GameScript(tester, transport);
  await script.gameStarted(turnSeat: 0);
  await script.turn(seat: 0);
  await script.rolled(seat: 0, value: 4, k: 1);
  await script.moved(seat: 0, token: 0, from: -1, to: 57);
  await script.gameOver(winner: 0, verifyUrl: _winVerifyUrl);
  await _pumpPastEndCardHold(tester);
  return (controller, transport);
}

/// Minimal loss: mySeat (0) loses to seat 1 ("Bob").
Future<(RoomController, FakeTransport)> _minimalLoseGame(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    turn: null,
  );
  await _mount(
    tester,
    controller,
    locale: locale,
    size: size,
    textScale: textScale,
  );
  final _GameScript script = _GameScript(tester, transport);
  await script.gameStarted(turnSeat: 1);
  await script.turn(seat: 1);
  await script.rolled(seat: 1, value: 4, k: 1);
  await script.moved(seat: 1, token: 0, from: -1, to: 4);
  await script.gameOver(winner: 1, verifyUrl: _loseVerifyUrl);
  await _pumpPastEndCardHold(tester);
  return (controller, transport);
}

/// The full numbers transcript: mySeat (0) wins. Every count below is
/// hand-derived from this exact script against lib/src/game_stats.dart's own
/// rules (read in full, never called here to produce an expected value):
///
///   rolls(seat0): one `rolled` per entry in {value 3, value 6, value 6,
///     value 4, value 2} naming seat 0 -> 5.
///   sixes(seat0): of those, the two value-6 rolls -> 2.
///   capturesMade(seat0): `moved` frames naming seat 0 whose `captured` is
///     non-empty, summed by length -- one frame with one entry (seat 0
///     captures seat 1's token 0) plus one frame with two entries (seat 0
///     captures seat 1's tokens 1 and 2 in the same move) -> 1 + 2 = 3.
///   timesCaptured(seat0): `captured` entries naming seat 0, across every
///     mover -- none; seat 0 is never captured in this script -> 0.
///   tokensHome(seat0): count of 57 in seat 0's final tokens. Seat 0's
///     token 0 is walked -1 -> 3 -> 7 -> 57 (home); tokens 1 and 2 stop at
///     8 and 6; token 3 never leaves base (-1) -> exactly one 57 -> 1.
///
/// Deliberately not tied: sixes and tokensHome are both forced to be at
/// least 1 by the order's own script requirements, so they are pushed apart
/// (sixes 2, tokensHome 1) and capturesMade/timesCaptured are pushed to 3
/// and 0, so a tile bound to the wrong field reads a visibly wrong number
/// rather than an accidental match -- the "`captures` counting captures
/// suffered" mutation the order names is caught exactly because 3 and 0
/// cannot be confused for one another at the keyed tile.
const int _numbersRolls = 5;
const int _numbersSixes = 2;
const int _numbersCapturesMade = 3;
const int _numbersTimesCaptured = 0;
const int _numbersTokensHome = 1;

Future<(RoomController, FakeTransport)> _numbersWinGame(
  WidgetTester tester,
) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    turn: null,
  );
  await _mount(tester, controller);
  final _GameScript s = _GameScript(tester, transport);

  await s.gameStarted(turnSeat: 0);
  await s.turn(seat: 0);
  await s.rolled(seat: 0, value: 3, k: 1); // rolls(seat0): 0 -> 1
  await s.moved(seat: 0, token: 0, from: -1, to: 3); // no capture

  await s.turn(seat: 1);
  await s.rolled(seat: 1, value: 4, k: 1); // opponent roll; must not count
  await s.moved(seat: 1, token: 0, from: -1, to: 4); // no capture

  await s.turn(seat: 0);
  await s.rolled(seat: 0, value: 6, k: 2); // rolls: 1->2, sixes: 0->1
  await s.moved(
    seat: 0,
    token: 1,
    from: -1,
    to: 6,
    extraRoll: true,
  ); // no capture

  await s.turn(seat: 0); // extra roll, same seat
  await s.rolled(seat: 0, value: 6, k: 3); // rolls: 2->3, sixes: 1->2
  await s.moved(
    seat: 0,
    token: 2,
    from: -1,
    to: 6,
    extraRoll: true,
  ); // no capture

  await s.turn(seat: 0); // extra roll, same seat
  await s.rolled(seat: 0, value: 4, k: 4); // rolls: 3->4
  await s.moved(
    seat: 0,
    token: 0,
    from: 3,
    to: 7,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': 1, 'token': 0},
    ],
  ); // capturesMade(seat0): 0 -> 1

  await s.turn(seat: 1);
  await s.rolled(seat: 1, value: 5, k: 2); // opponent roll; must not count
  await s.moved(seat: 1, token: 1, from: -1, to: 5); // no capture

  await s.turn(seat: 0);
  await s.rolled(seat: 0, value: 2, k: 5); // rolls: 4->5
  await s.moved(
    seat: 0,
    token: 1,
    from: 6,
    to: 8,
    captured: const <Map<String, Object?>>[
      <String, Object?>{'seat': 1, 'token': 1},
      <String, Object?>{'seat': 1, 'token': 2},
    ],
  ); // double capture: capturesMade(seat0): 1 -> 3

  await s.turn(seat: 1);
  await s.rolled(seat: 1, value: 3, k: 3); // opponent roll; must not count
  await s.moved(seat: 1, token: 3, from: -1, to: 3); // no capture

  await s.turn(seat: 0);
  await s.moved(
    seat: 0,
    token: 0,
    from: 7,
    to: 57,
  ); // tokensHome(seat0): 0 -> 1

  await s.gameOver(winner: 0, verifyUrl: _numbersVerifyUrl);
  await _pumpPastEndCardHold(tester);
  return (controller, transport);
}

/// Same shape as the win script above but with a deliberate hole: a `pong`
/// carrying a seq far off the running chain lands between the first and
/// second `rolled`/`moved` pair. computeGameStats (read, never called) marks
/// `complete: false` the moment any frame's seq in the window breaks
/// contiguity with the one before it, regardless of that frame's type.
/// tokensHome alone is still exactly right -- it is read from finalTokens,
/// never from the frames.
const int _gapTokensHome = 1;

Future<(RoomController, FakeTransport)> _gapWinGame(WidgetTester tester) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    turn: null,
  );
  await _mount(tester, controller);
  final _GameScript s = _GameScript(tester, transport);

  await s.gameStarted(turnSeat: 0);
  await s.rolled(seat: 0, value: 4, k: 1);
  await s.moved(seat: 0, token: 0, from: -1, to: 4);
  await s.pong(seqValue: 999); // the hole: breaks contiguity on both sides
  await s.rolled(seat: 0, value: 6, k: 2);
  await s.moved(seat: 0, token: 0, from: 4, to: 57); // tokensHome: 0 -> 1
  await s.gameOver(winner: 0, verifyUrl: _gapVerifyUrl);
  await _pumpPastEndCardHold(tester);
  // The gap leaves the transcript incomplete, so the end card asks for
  // game_log once. A real server answers. RATE_LIMITED is the honest
  // fallback C-304 keeps: home alone, and the request's timer is done.
  await _refuseGameLog(tester, transport);
  return (controller, transport);
}

/// Answers every `game_log` already on [transport.sentRaw] with an `error`
/// frame, `re` set to that request's id. No request means nothing is sent:
/// a client that never asks sees the same fixture it always did.
Future<void> _refuseGameLog(
  WidgetTester tester,
  FakeTransport transport,
) async {
  final List<String> requestIds = <String>[];
  for (final String raw in transport.sentRaw) {
    if (_typeOf(raw) == 'game_log') {
      requestIds.add(_idOf(raw));
    }
  }
  if (requestIds.isEmpty) {
    return;
  }
  for (final String requestId in requestIds) {
    transport.pushText(
      _frame(
        type: 'error',
        re: requestId,
        data: <String, Object?>{'code': 'RATE_LIMITED', 'message': 'game_log'},
      ),
    );
  }
  await tester.pump();
  await tester.pump();
}

/// A room that ended with no winner named and no `game_over` ever sent --
/// connected directly into RoomState.finished the way test/
/// game_screen_test.dart's own H7.21b and test/play_surface_die_test.dart's
/// own "finished room" case do, since a real `game_over` frame cannot carry
/// a null winner (RoomController's own reducer drops one that tries).
/// verify_url is therefore also absent here, on purpose: this doubles as the
/// "no URL" fairness case.
Future<(RoomController, FakeTransport)> _endedNoWinnerGame(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Size size = const Size(390, 844),
  double textScale = 1.0,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    state: 'FINISHED',
    winner: null,
    turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 1),
  );
  await _mount(
    tester,
    controller,
    locale: locale,
    size: size,
    textScale: textScale,
  );
  return (controller, transport);
}

// --- shared assertion helpers ------------------------------------------------

/// Every Text/RichText/Semantics/Tooltip string reachable under [root],
/// scanning descendants plus the semantics tree -- mirrors test/
/// game_verify_card_test.dart's own `_blobUnder`, not imported, per this
/// order's rule against importing across test files.
void _writeBlob(StringBuffer out, String? value) {
  if (value != null && value.trim().isNotEmpty) {
    out.writeln(value);
  }
}

void _walkSemantics(SemanticsNode node, StringBuffer out) {
  _writeBlob(out, node.label);
  _writeBlob(out, node.value);
  _writeBlob(out, node.hint);
  _writeBlob(out, node.tooltip);
  node.visitChildren((SemanticsNode child) {
    _walkSemantics(child, out);
    return true;
  });
}

String _blobUnder(WidgetTester tester, Finder root) {
  if (root.evaluate().isEmpty) {
    return '';
  }
  final StringBuffer out = StringBuffer();
  final Finder descendants = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget _) => true),
  );
  for (final Element element in <Element>[
    tester.element(root),
    ...descendants.evaluate(),
  ]) {
    final Widget widget = element.widget;
    if (widget is Text) {
      _writeBlob(out, widget.data);
      _writeBlob(out, widget.textSpan?.toPlainText());
    } else if (widget is RichText) {
      _writeBlob(out, widget.text.toPlainText());
    } else if (widget is Semantics) {
      _writeBlob(out, widget.properties.label);
      _writeBlob(out, widget.properties.value);
      _writeBlob(out, widget.properties.hint);
      _writeBlob(out, widget.properties.tooltip);
    } else if (widget is Tooltip) {
      _writeBlob(out, widget.message);
    }
  }
  try {
    _walkSemantics(tester.getSemantics(root), out);
  } catch (_) {
    // No semantics node under root; text/tooltip descendants already
    // counted above still stand.
  }
  return out.toString();
}

/// The title key (`game-screen-winner`) is a plain `Text` on a win or the
/// ended card but `Text.rich` on a loss (the winner's name in the winner's
/// seat colour, contract rule 3), so `Text.data` alone is null on that
/// branch. Reads whichever form is actually mounted, falling back to the
/// span's own plain text.
String _titleText(WidgetTester tester, Key key) {
  final Text title = tester.widget<Text>(find.byKey(key));
  return title.data ?? title.textSpan?.toPlainText() ?? '';
}

/// Scans the *entire* mounted tree, not scoped to GameScreen's own subtree:
/// end-card-fair-hint may show endFairHint through a modal bottom sheet,
/// which Flutter attaches to the root Overlay, a sibling of GameScreen
/// rather than a descendant of it.
String _wholeTreeBlob(WidgetTester tester) =>
    _blobUnder(tester, find.byType(MaterialApp));

/// Every explicit colour reachable on Text/RichText/Icon/DecoratedBox under
/// [root]. Used only to catch a loser card painted in LudoColors.error (the
/// "cold or red loser card" the order names) or missing the winner's own
/// seat colour on the loser's title -- never used to pin an exact shade on
/// the winner's card, which "What proves it" does not ask for.
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

Set<Color> _colorsUnder(WidgetTester tester, Finder root) {
  final Set<Color> colors = <Color>{};
  if (root.evaluate().isEmpty) {
    return colors;
  }
  final Finder descendants = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((Widget _) => true),
  );
  for (final Element element in <Element>[
    tester.element(root),
    ...descendants.evaluate(),
  ]) {
    final Widget widget = element.widget;
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
      if (decoration is BoxDecoration && decoration.color != null) {
        colors.add(decoration.color!);
      }
    }
  }
  return colors;
}

/// Whole-number match at a word boundary: "1" must not accidentally match
/// inside "10" or "21".
bool _tileShowsNumber(WidgetTester tester, Key key, int expected) {
  final Finder tile = find.byKey(key);
  if (tile.evaluate().isEmpty) {
    return false;
  }
  final String blob = _blobUnder(tester, tile);
  return RegExp('(?<!\\d)$expected(?!\\d)').hasMatch(blob);
}

List<MethodCall> _listenUrlLaunches(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> handler(MethodCall call) async {
    calls.add(call);
    return true;
  }

  for (final String name in _urlLauncherChannels) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return calls;
}

bool _containsUrl(Object? value, String url) {
  if (value is String) {
    return value.contains(url);
  }
  if (value is Map) {
    return value.values.any((Object? item) => _containsUrl(item, url));
  }
  if (value is Iterable) {
    return value.any((Object? item) => _containsUrl(item, url));
  }
  return false;
}

bool _launched(List<MethodCall> calls, String url) {
  return calls.any(
    (MethodCall call) =>
        _containsUrl(call.arguments, url) || call.method.contains(url),
  );
}

// --- ARB forbidden-phrase scan -----------------------------------------------

Directory _findPackageRoot() {
  bool isLudoClient(Directory dir) {
    final File pubspec = File(p.join(dir.path, 'pubspec.yaml'));
    return pubspec.existsSync() &&
        pubspec
            .readAsStringSync()
            .split('\n')
            .any((String line) => line.trim() == 'name: ludo_client');
  }

  final Directory cwd = Directory.current;
  if (isLudoClient(cwd)) {
    return cwd;
  }
  final Directory nested = Directory(
    p.join(cwd.path, 'packages', 'ludo_client'),
  );
  if (isLudoClient(nested)) {
    return nested;
  }
  Directory walker = cwd;
  for (int i = 0; i < 8; i++) {
    final Directory parent = walker.parent;
    if (parent.path == walker.path) {
      break;
    }
    if (isLudoClient(parent)) {
      return parent;
    }
    walker = parent;
  }
  fail('could not locate the ludo_client package root from cwd ${cwd.path}');
}

Iterable<String> _arbMessageValues(File file) {
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('${file.path} must decode as a JSON object');
  }
  final List<String> values = <String>[];
  for (final MapEntry<String, Object?> entry in decoded.entries) {
    if (entry.key.startsWith('@')) {
      continue;
    }
    if (entry.value is String) {
      values.add(entry.value! as String);
    }
  }
  return values;
}

/// C-243 rule 6's own forbidden list: two multi-word phrases checked as
/// plain substrings, and five single words checked at a word boundary so
/// "bet" does not fire on "between" and "stakes" matches both the singular
/// and the plural.
const List<String> _forbiddenPhraseSubstrings = <String>[
  'provably fair',
  'absolute randomness',
  'win money',
];
final List<RegExp> _forbiddenWordPatterns = <RegExp>[
  RegExp(r'\bodds\b', caseSensitive: false),
  RegExp(r'\bstakes?\b', caseSensitive: false),
  RegExp(r'\bbet\b', caseSensitive: false),
  RegExp(r'\bwager\w*\b', caseSensitive: false),
];

/// Mirrors test/lobby_screen_die_code_start_label_test.dart's own
/// `_isOverflowError`, not imported, per this order's rule against
/// importing across test files: checks both the raised exception's own
/// message and the full details dump, since a RenderFlex overflow surfaces
/// its "overflowed" wording on the exception itself.
bool _isOverflowError(FlutterErrorDetails details) {
  final String text = '${details.exception}\n$details';
  return text.contains('overflowed');
}

void _assertNoForbiddenLanguage(String text, {required String where}) {
  final String lower = text.toLowerCase();
  for (final String phrase in _forbiddenPhraseSubstrings) {
    expect(
      lower.contains(phrase),
      isFalse,
      reason: '$where must not contain "$phrase"; got: $text',
    );
  }
  for (final RegExp pattern in _forbiddenWordPatterns) {
    expect(
      pattern.hasMatch(text),
      isFalse,
      reason: '$where must not match ${pattern.pattern}; got: $text',
    );
  }
}

// =============================================================================

void main() {
  // ===========================================================================
  // Winner.
  // ===========================================================================
  group('winner card (C-243 rule 2)', () {
    // Catches a winner card that never celebrates, or a win rendered with
    // the ended screen's generic title instead of endWinTitle -- a win that
    // reads like a shrug, not a win.
    testWidgets('end-card-win and end-card-celebration are shown, title is '
        'endWinTitle, and the lose card never also renders', (tester) async {
      final (RoomController controller, _) = await _minimalWinGame(tester);
      final AppLocalizations loc = _locOf(tester);

      expect(
        controller.room!.state,
        RoomState.finished,
        reason:
            'fixture is broken: the scripted game_over must finish the room',
      );
      expect(
        find.byKey(_winKey),
        findsOneWidget,
        reason: 'end-card-win must be shown when my seat is the winner',
      );
      expect(
        find.byKey(_celebrationKey),
        findsOneWidget,
        reason:
            'end-card-celebration must be shown on a win; a missing '
            'celebration is exactly the mutation this case exists to '
            'catch',
      );
      final String titleText = _titleText(tester, _winnerTitleKey);
      expect(
        titleText,
        loc.endWinTitle,
        reason:
            'game-screen-winner must show loc.endWinTitle '
            '("${loc.endWinTitle}") on a win; got "$titleText"',
      );
      expect(
        find.byKey(_loseKey),
        findsNothing,
        reason: 'end-card-lose must not render alongside a win',
      );
      expect(find.byKey(_endedKey), findsNothing);
    });
  });

  // ===========================================================================
  // Loser.
  // ===========================================================================
  group('loser card (C-243 rule 3)', () {
    // Catches the lose card reusing the win title (the order's own named
    // mutation): endLoseTitle must carry the winner's name and read
    // differently from endWinTitle, and no celebration must fire for a
    // loss.
    testWidgets(
      'end-card-lose is shown, title is endLoseTitle(Bob), endLoseNudge is '
      'shown, and no win/celebration ever renders',
      (tester) async {
        final (RoomController controller, _) = await _minimalLoseGame(tester);
        final AppLocalizations loc = _locOf(tester);

        expect(controller.room!.state, RoomState.finished);
        expect(
          find.byKey(_loseKey),
          findsOneWidget,
          reason: 'end-card-lose must be shown when another seat won',
        );
        final String titleText = _titleText(tester, _winnerTitleKey);
        expect(
          titleText,
          loc.endLoseTitle('Bob'),
          reason:
              'game-screen-winner must show loc.endLoseTitle(\'Bob\') '
              '("${loc.endLoseTitle('Bob')}") on a loss; got "$titleText"',
        );
        expect(
          titleText,
          isNot(loc.endWinTitle),
          reason:
              'the lose card reusing the win title is exactly the mutation '
              'this assertion exists to catch',
        );
        final String screenBlob = _blobUnder(tester, find.byType(GameScreen));
        expect(
          screenBlob.contains(loc.endLoseNudge),
          isTrue,
          reason:
              'endLoseNudge ("${loc.endLoseNudge}") must be shown on a '
              'loss; screen text was "$screenBlob"',
        );
        expect(
          find.byKey(_winKey),
          findsNothing,
          reason: 'end-card-win must not render on a loss',
        );
        expect(
          find.byKey(_celebrationKey),
          findsNothing,
          reason: 'end-card-celebration must not fire for the losing seat',
        );
      },
    );

    // Catches a cold (uncoloured, generic grey/black) or outright red loser
    // card: the winner's name must carry the winner's own seat colour
    // (LudoColors.seats[1], green) and LudoColors.error must never appear
    // anywhere on this card.
    testWidgets(
      'the winner\'s name on the lose card carries the winner\'s seat '
      'colour, never LudoColors.error',
      (tester) async {
        await _minimalLoseGame(tester);

        final Set<Color> colors = _colorsUnder(tester, find.byKey(_loseKey));
        expect(
          colors.contains(LudoColors.error),
          isFalse,
          reason:
              'a red loser card is exactly the mutation this assertion '
              'exists to catch; colours found under end-card-lose: $colors',
        );
        expect(
          colors.contains(LudoColors.seats[1]),
          isTrue,
          reason:
              'the winning seat (1, Bob) is green (LudoColors.seats[1]); '
              'the lose card must colour the winner\'s name with it '
              '(C-243 rule 3: "the name in the winner\'s seat colour"); '
              'colours found under end-card-lose: $colors',
        );
      },
    );
  });

  // ===========================================================================
  // Ended with no winner.
  // ===========================================================================
  group('ended card, no winner named (C-243 rule 4)', () {
    // Catches an ended room (no winner, no game_over ever sent) wrongly
    // showing a win celebration or a lose nudge, either of which would name
    // a player who never actually won.
    testWidgets(
      'end-card-ended is shown with loc.gameOverEnded, never a win or a '
      'lose card',
      (tester) async {
        final (RoomController controller, _) = await _endedNoWinnerGame(tester);
        final AppLocalizations loc = _locOf(tester);

        expect(controller.room!.state, RoomState.finished);
        expect(controller.room!.winner, isNull, reason: 'fixture is broken');
        expect(
          find.byKey(_endedKey),
          findsOneWidget,
          reason: 'end-card-ended must be shown when no winner is named',
        );
        final Text title = tester.widget<Text>(find.byKey(_winnerTitleKey));
        expect(title.data, loc.gameOverEnded);
        expect(find.byKey(_winKey), findsNothing);
        expect(find.byKey(_loseKey), findsNothing);
        expect(find.byKey(_celebrationKey), findsNothing);
      },
    );
  });

  // ===========================================================================
  // Numbers.
  // ===========================================================================
  group('numbers (C-243 rule 5)', () {
    // Each tile's value is read from its own keyed widget, so a card that
    // bound the wrong GameStats field to a tile (the order's own named
    // "`captures` counting captures suffered" mutation) shows a visibly
    // wrong number at that specific key rather than a coincidentally
    // matching one -- capturesMade (3) and timesCaptured (0) never tie.
    testWidgets(
      'all four tiles show the hand-derived numbers from the scripted game',
      (tester) async {
        await _numbersWinGame(tester);

        expect(
          _tileShowsNumber(tester, _statRollsKey, _numbersRolls),
          isTrue,
          reason:
              'end-card-stat-rolls must show $_numbersRolls; blob was '
              '"${_blobUnder(tester, find.byKey(_statRollsKey))}"',
        );
        expect(
          _tileShowsNumber(tester, _statSixesKey, _numbersSixes),
          isTrue,
          reason:
              'end-card-stat-sixes must show $_numbersSixes; blob was '
              '"${_blobUnder(tester, find.byKey(_statSixesKey))}"',
        );
        expect(
          _tileShowsNumber(tester, _statCapturesKey, _numbersCapturesMade),
          isTrue,
          reason:
              'end-card-stat-captures must show capturesMade '
              '($_numbersCapturesMade), not timesCaptured '
              '($_numbersTimesCaptured); blob was '
              '"${_blobUnder(tester, find.byKey(_statCapturesKey))}"',
        );
        expect(
          _tileShowsNumber(tester, _statHomeKey, _numbersTokensHome),
          isTrue,
          reason:
              'end-card-stat-home must show $_numbersTokensHome; blob was '
              '"${_blobUnder(tester, find.byKey(_statHomeKey))}"',
        );
      },
    );

    // Catches tiles still being shown from an incomplete transcript (the
    // order's own named mutation): once a frame gap makes
    // GameStats.complete false, C-232's own ruling ("a wrong number reads
    // worse than none") says only tokens-home may be trusted, so the other
    // three must be gone, not merely wrong.
    testWidgets(
      'with a frame gap, only end-card-stat-home is shown, and it is still '
      'correct',
      (tester) async {
        final (_, FakeTransport transport) = await _gapWinGame(tester);

        expect(
          transport.sentRaw.where((String raw) => _typeOf(raw) == 'game_log'),
          hasLength(1),
          reason:
              'gap, ask, refused, home alone: the incomplete transcript '
              'sends one game_log, the fixture answers RATE_LIMITED, and '
              'only end-card-stat-home is shown',
        );
        expect(
          find.byKey(_statRollsKey),
          findsNothing,
          reason:
              'end-card-stat-rolls must not be shown once a frame gap makes '
              'the transcript incomplete',
        );
        expect(find.byKey(_statSixesKey), findsNothing);
        expect(find.byKey(_statCapturesKey), findsNothing);
        expect(
          find.byKey(_statHomeKey),
          findsOneWidget,
          reason:
              'end-card-stat-home must still be shown; it is read from '
              'finalTokens, never from the gappy frame window',
        );
        expect(
          _tileShowsNumber(tester, _statHomeKey, _gapTokensHome),
          isTrue,
          reason:
              'end-card-stat-home must still show the correct count '
              '($_gapTokensHome) even though the rest of the transcript is '
              'incomplete',
        );
      },
    );
  });

  // ===========================================================================
  // Fairness (C-243 rule 6, every ending).
  // ===========================================================================
  group('fairness line and check (C-243 rule 6)', () {
    // The loss and ended-with-no-winner cases sit right after this one: C-243
    // rule 6 says the fairness line belongs on every ending alike, so each
    // of the three is its own case rather than one that could pass by only
    // proving the win.
    testWidgets('endFairLine is shown on a win', (tester) async {
      final (RoomController controller, _) = await _minimalWinGame(tester);
      final AppLocalizations loc = _locOf(tester);
      expect(controller.room!.state, RoomState.finished);
      final String blob = _blobUnder(tester, find.byType(GameScreen));
      expect(
        blob.contains(loc.endFairLine),
        isTrue,
        reason:
            'endFairLine ("${loc.endFairLine}") must be shown on a win; '
            'screen text was "$blob"',
      );
    });

    testWidgets('endFairLine is shown on a loss', (tester) async {
      await _minimalLoseGame(tester);
      final AppLocalizations loc = _locOf(tester);
      final String blob = _blobUnder(tester, find.byType(GameScreen));
      expect(
        blob.contains(loc.endFairLine),
        isTrue,
        reason:
            'endFairLine ("${loc.endFairLine}") must be shown on a loss -- '
            'the order\'s own named mutation is a fairness line shown only '
            'on a loss, so this and the win/ended cases around it must all '
            'carry it independently; screen text was "$blob"',
      );
    });

    testWidgets('endFairLine is shown on the ended-with-no-winner card too', (
      tester,
    ) async {
      await _endedNoWinnerGame(tester);
      final AppLocalizations loc = _locOf(tester);
      final String blob = _blobUnder(tester, find.byType(GameScreen));
      expect(
        blob.contains(loc.endFairLine),
        isTrue,
        reason:
            'endFairLine ("${loc.endFairLine}") must be shown even when no '
            'winner is named; screen text was "$blob"',
      );
    });

    testWidgets('game-screen-verify-button is at least 48dp and opens verify_url from '
        'game_over', (tester) async {
      await _minimalWinGame(tester);

      final Finder verify = find.byKey(_verifyKey);
      expect(verify, findsOneWidget);
      final Size size = tester.getSize(verify);
      expect(
        size.width,
        greaterThanOrEqualTo(48.0),
        reason:
            'game-screen-verify-button width must be >= 48; was ${size.width}',
      );
      expect(
        size.height,
        greaterThanOrEqualTo(48.0),
        reason:
            'game-screen-verify-button height must be >= 48; was ${size.height}',
      );

      final List<MethodCall> launches = _listenUrlLaunches(tester);
      await tester.ensureVisible(verify);
      await tester.tap(verify);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        _launched(launches, _winVerifyUrl),
        isTrue,
        reason:
            'tapping game-screen-verify-button on the end card must open '
            '$_winVerifyUrl externally; calls were $launches',
      );
    });

    testWidgets(
      'game-screen-verify-button is disabled when game_over carried no URL',
      (tester) async {
        await _endedNoWinnerGame(tester);

        final Finder verify = find.byKey(_verifyKey);
        expect(verify, findsOneWidget);
        final List<MethodCall> launches = _listenUrlLaunches(tester);
        await tester.ensureVisible(verify);
        await tester.tap(verify, warnIfMissed: false);
        await tester.pump();

        expect(
          launches,
          isEmpty,
          reason:
              'with no verify_url, game-screen-verify-button must be '
              'disabled and tapping it must open nothing; calls were '
              '$launches',
        );
      },
    );

    testWidgets('end-card-fair-hint is at least 48dp and shows endFairHint', (
      tester,
    ) async {
      await _minimalWinGame(tester);
      final AppLocalizations loc = _locOf(tester);

      final Finder hint = find.byKey(_fairHintKey);
      expect(
        hint,
        findsOneWidget,
        reason: 'end-card-fair-hint must be present on the end card',
      );
      final Size size = tester.getSize(hint);
      expect(
        size.width,
        greaterThanOrEqualTo(48.0),
        reason: 'end-card-fair-hint width must be >= 48; was ${size.width}',
      );
      expect(
        size.height,
        greaterThanOrEqualTo(48.0),
        reason: 'end-card-fair-hint height must be >= 48; was ${size.height}',
      );

      await tester.ensureVisible(hint);
      await tester.tap(hint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final String blob = _wholeTreeBlob(tester);
      expect(
        blob.contains(loc.endFairHint),
        isTrue,
        reason:
            'end-card-fair-hint must show endFairHint ("${loc.endFairHint}") '
            'in a sheet or tooltip once opened; tree text was "$blob"',
      );
    });

    test('neither app_en.arb nor app_ar.arb contains forbidden language', () {
      final Directory root = _findPackageRoot();
      for (final String name in <String>['app_en.arb', 'app_ar.arb']) {
        final File file = File(p.join(root.path, 'lib', 'l10n', name));
        expect(file.existsSync(), isTrue, reason: '${file.path} must exist');
        for (final String value in _arbMessageValues(file)) {
          _assertNoForbiddenLanguage(
            value,
            where: '${file.path} message "$value"',
          );
        }
      }
    });
  });

  // ===========================================================================
  // Celebration stops; reduced motion keeps the meaning, not the motion.
  // ===========================================================================
  group('celebration motion (C-243 rule 2 and doctrine P9)', () {
    // Catches a celebration ticker that never stops: about 1200ms in, the
    // contract says it goes still. This file never calls pumpAndSettle (it
    // would hang forever against exactly this mutation); instead it pumps a
    // bounded amount past 1200ms and then reads
    // SchedulerBinding.transientCallbackCount directly, the same idiom test/
    // board_test.dart already uses for "no pending timers or tickers".
    testWidgets(
      'end-card-celebration is still present but has stopped ticking by '
      '1500ms',
      (tester) async {
        await _minimalWinGame(tester);

        expect(find.byKey(_celebrationKey), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          find.byKey(_celebrationKey),
          findsOneWidget,
          reason:
              'end-card-celebration must still be present at 1500ms -- '
              '"then still", not gone',
        );
        expect(
          SchedulerBinding.instance.transientCallbackCount,
          0,
          reason:
              'a celebration ticker that never stops is exactly the '
              'mutation this assertion exists to catch; '
              '${SchedulerBinding.instance.transientCallbackCount} '
              'transient callback(s) still scheduled at 1500ms',
        );
      },
    );

    // Catches a celebration that keeps its particle ticker under reduced
    // motion instead of showing the static glow doctrine P9 asks for: no
    // ticker should ever be armed in the first place here, not merely
    // stopped later.
    testWidgets(
      'under MediaQuery.disableAnimations, end-card-celebration is shown '
      'immediately with no ticker ever running',
      (tester) async {
        await _minimalWinGame(tester, disableAnimations: true);

        expect(
          find.byKey(_celebrationKey),
          findsOneWidget,
          reason:
              'end-card-celebration must still be found under reduced '
              'motion -- meaning kept, only motion removed (doctrine P9)',
        );
        expect(
          SchedulerBinding.instance.transientCallbackCount,
          0,
          reason:
              'under disableAnimations no particle ticker should ever be '
              'armed; '
              '${SchedulerBinding.instance.transientCallbackCount} '
              'transient callback(s) scheduled',
        );
      },
    );
  });

  // ===========================================================================
  // Arabic.
  // ===========================================================================
  group('Arabic (C-243 rule 9)', () {
    testWidgets(
      'win: every new string matches the contract\'s own Arabic wording, '
      'and the card reads RTL',
      (tester) async {
        await _minimalWinGame(tester, locale: const Locale('ar'));
        final AppLocalizations loc = _locOf(tester);

        expect(
          loc.endWinTitle,
          'فزت!',
          reason:
              'endWinTitle under ar must be the contract\'s own wording; '
              'got "${loc.endWinTitle}"',
        );
        final Text title = tester.widget<Text>(find.byKey(_winnerTitleKey));
        expect(title.data, loc.endWinTitle);

        expect(loc.endFairLine, 'كل رمية في هذه اللعبة قابلة للتحقق.');
        expect(loc.endFairCheck, 'تحقق من الرميات');

        final TextDirection direction = Directionality.of(
          tester.element(find.byType(GameScreen)),
        );
        expect(
          direction,
          TextDirection.rtl,
          reason: 'the end card must read RTL under Locale(ar)',
        );
      },
    );

    testWidgets('loss: endLoseTitle and endLoseNudge match the contract\'s own '
        'Arabic wording', (tester) async {
      await _minimalLoseGame(tester, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      expect(
        loc.endLoseTitle('Bob'),
        'فاز Bob هذه المرة',
        reason:
            'endLoseTitle(name) under ar must be the contract\'s own '
            'wording; got "${loc.endLoseTitle('Bob')}"',
      );
      expect(loc.endLoseNudge, 'لعبة جيدة. جولة أخرى؟');

      expect(_titleText(tester, _winnerTitleKey), loc.endLoseTitle('Bob'));
      final String blob = _blobUnder(tester, find.byType(GameScreen));
      expect(blob.contains(loc.endLoseNudge), isTrue);
    });

    testWidgets('numbers: the four stat labels match the contract\'s own '
        'Arabic wording', (tester) async {
      await _minimalWinGame(tester, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      expect(loc.endStatRolls, 'رميات');
      expect(loc.endStatSixes, 'ستّات');
      expect(loc.endStatCaptures, 'ضربات');
      expect(loc.endStatHome, 'في البيت');

      final String blob = _blobUnder(tester, find.byType(GameScreen));
      for (final String label in <String>[
        loc.endStatRolls,
        loc.endStatSixes,
        loc.endStatCaptures,
        loc.endStatHome,
      ]) {
        expect(
          blob.contains(label),
          isTrue,
          reason: 'label "$label" must appear somewhere on the ar end card',
        );
      }
    });

    testWidgets('fairness hint matches the contract\'s own Arabic wording', (
      tester,
    ) async {
      await _minimalWinGame(tester, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      expect(
        loc.endFairHint,
        'كل رمية جاءت من سلسلة مختومة قبل بدء اللعبة. '
        'يمكن لأي شخص فتح هذه الصفحة والتحقق من كل رمية.',
      );

      final Finder hint = find.byKey(_fairHintKey);
      await tester.ensureVisible(hint);
      await tester.tap(hint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final String blob = _wholeTreeBlob(tester);
      expect(
        blob.contains(loc.endFairHint),
        isTrue,
        reason:
            'endFairHint must appear under ar once opened; tree was "$blob"',
      );
    });
  });

  // ===========================================================================
  // Kept keys (C-243 rule 8): untouched by this order, still present.
  // ===========================================================================
  group('kept keys stay present on the end card', () {
    testWidgets(
      'game-screen-board, game-screen-roll-history, game-screen-winner and '
      'game-screen-new-room-button are all still present on a win',
      (tester) async {
        await _minimalWinGame(tester);

        expect(find.byKey(_boardKey), findsOneWidget);
        expect(find.byKey(_rollHistoryKey), findsOneWidget);
        expect(find.byKey(_winnerTitleKey), findsOneWidget);
        expect(
          find.byKey(_newRoomKey),
          findsOneWidget,
          reason:
              'gameNewRoomButton (New table) must still be present; it '
              'sits where Rematch (a later order) will go',
        );
      },
    );
  });

  // ===========================================================================
  // Width coverage (order 244r1, item 3): the card must not overflow at an
  // ordinary phone width in either locale, on any of the three endings, at
  // either the default text scale or a large one. Kills the mutation 243r1
  // exists to fix and the master's own run 68 verdict measured by hand: the
  // stat row and the fairness row failing to wrap or scale down at 360-390
  // logical pixels wide, which 243's own default 800x600 test surface never
  // meets. On the pre-243r1 base this group is expected to fail with
  // "overflowed" at 390x844 (and, being narrower still, at 360x800 too) --
  // that failure is the product defect 243r1 fixes in parallel, not a defect
  // in this file.
  // ===========================================================================
  group('width coverage (order 244r1 item 3, the overflow 243r1 fixes)', () {
    const List<Size> phoneSizes = <Size>[Size(360, 800), Size(390, 844)];
    const List<Locale> phoneLocales = <Locale>[Locale('en'), Locale('ar')];
    const List<double> phoneTextScales = <double>[1.0, 1.3];
    const List<String> phoneScenarios = <String>['win', 'lose', 'ended'];

    Future<void> mountScenario(
      WidgetTester tester, {
      required String scenario,
      required Locale locale,
      required Size size,
      required double textScale,
    }) async {
      switch (scenario) {
        case 'win':
          await _minimalWinGame(
            tester,
            locale: locale,
            size: size,
            textScale: textScale,
          );
          return;
        case 'lose':
          await _minimalLoseGame(
            tester,
            locale: locale,
            size: size,
            textScale: textScale,
          );
          return;
        case 'ended':
          await _endedNoWinnerGame(
            tester,
            locale: locale,
            size: size,
            textScale: textScale,
          );
          return;
        default:
          fail('width coverage: unknown scenario "$scenario"');
      }
    }

    for (final Size size in phoneSizes) {
      for (final Locale locale in phoneLocales) {
        for (final String scenario in phoneScenarios) {
          for (final double textScale in phoneTextScales) {
            testWidgets('no RenderFlex overflow at ${size.width.toInt()}x'
                '${size.height.toInt()}, ${locale.languageCode}, $scenario, '
                'text scale ${textScale}x', (tester) async {
              final List<FlutterErrorDetails> captured =
                  <FlutterErrorDetails>[];
              final void Function(FlutterErrorDetails)? previous =
                  FlutterError.onError;
              FlutterError.onError = captured.add;
              try {
                await mountScenario(
                  tester,
                  scenario: scenario,
                  locale: locale,
                  size: size,
                  textScale: textScale,
                );
                await tester.pump();
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
                    'end card at ${size.width.toInt()}x'
                    '${size.height.toInt()}, ${locale.languageCode}, '
                    '$scenario, text scale ${textScale}x must not report '
                    'a RenderFlex overflow; got $overflows',
              );
            });
          }
        }
      }
    }
  });
}
