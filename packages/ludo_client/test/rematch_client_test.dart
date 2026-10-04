// Conformance tests for work/ludo/orders/C-246-rematch-client.md's "What
// proves it" section (order 247), read line by line, against the GameScreen
// and LobbyScreen that order 246 (lib/src/end_card.dart, lib/src/
// game_screen.dart, lib/src/lobby_screen.dart, lib/src/net/*.dart) implements
// in parallel, in a tree this file's author has not opened. Base for both
// orders: order/240-state-captures merged into integrate/run69 at 6846914.
//
// On that base: RoomSnapshot has no `rematch` field, RoomController has no
// `rematch()` method, RoomConnection has no `rematch()` method, end_card.dart
// has no end-card-rematch* widgets, and AppLocalizations has none of
// `endRematch`, `endRematchWaiting`, `endRematchAsk`, `endRematchStartReady`
// or `endRematchGone`. This file references every one of those names because
// the contract itself names them, so on the base this file does not compile;
// the missing-member list the compiler reports is the expected red for this
// order, not a bug in this file.
//
// GameScreen and LobbyScreen are driven the same way test/end_card_test.dart
// and test/feedback_wiring_test.dart drive them: a real RoomController sits
// over a FakeTransport (test/net/fake_transport.dart, read-only). The
// fake-transport idiom (_Connector, _frame/_decode/_idOf, "one pushed frame
// needs two pumps") is copied from those files rather than imported, per
// this order's own instruction never to import across test files. Every
// claim about a sent frame is read off FakeTransport.sentRaw by decoding it
// and checking `t` and `d` exactly, never "contains". One mount per case.
//
// Every rematch-LOBBY scenario below is reached the way a real player
// reaches it: connect straight into a FINISHED room first (the state
// GameScreen is already proven against by C-243's own suite), then push the
// `room` frame(s) that move it into a LOBBY carrying a non-null `rematch`,
// exactly as docs/PROTOCOL.md section 16.2 describes the transition. A seat
// that has never seen a finished game and lands on a rematch LOBBY directly
// is the joiner's own case (section 16.9 rule 4, contract rule 7), which
// this file drives through LobbyScreen, not GameScreen, matching the
// contract's own text ("its route never saw a game").
//
// Ambiguities hit while writing this file, reported rather than invented
// around, per this order's own standing rule:
//
//   1. Contract rule 1 says a rematch failure "routes a failure through the
//      same in-room request failure path the other requests use"
//      (RoomController's own _failFromInRoomRequest/_fail, which lands the
//      controller in RoomPhase.failed and closes the connection for any
//      code that is not one of a per-request rejected-race set). Rule 8
//      then asks for two different *visible* outcomes: NO_SUCH_ROOM shows
//      end-card-rematch-gone with New table primary (still the end card, on
//      a screen whose top-level dispatch today shows a full-screen
//      connection-lost body the instant phase is failed), and "any other
//      error" shows "the existing in-room error line, the Rematch button
//      enabled again". The only reading of both rules together that this
//      file could find without contradicting either one is: every rematch
//      failure alike lands the controller in RoomPhase.failed (rule 1,
//      unconditionally); GameScreen's own build() then special-cases
//      errorCode == 'NO_SUCH_ROOM' to keep showing the end card in its gone
//      state instead of the ordinary connection-lost body (rule 8's first
//      sentence); every other code falls through to that ordinary
//      connection-lost body -- game-screen-connection-lost and
//      game-screen-error-message, the "existing in-room error line" every
//      other in-room request failure already produces on this screen
//      (lib/src/game_screen.dart's own _connectionLostBody, proved by
//      test/game_screen_connection_lost_test.dart) -- and "the Rematch
//      button enabled again" describes what the player sees after
//      reconnecting back into the same still-open rematch LOBBY, not
//      something visible on the same frame as the error. The "any other
//      error" case below tests exactly this reading and says so again at
//      the point it matters; the master should check it against 246's own
//      code rather than assume this file guessed right.
//
//   2. "New table becomes primary" (rule 8) and "New table stays, smaller,
//      secondary" (rule 3) are not given a key to measure "primary" by. This
//      file reads "primary" the same way test/game_leave_emphasis_test.dart
//      already does for Leave/Reconnect: ElevatedButton is primary,
//      OutlinedButton or TextButton is secondary. If 246 encodes
//      primary/secondary some other way (size alone, colour alone, position
//      alone) this file's two button-type assertions will read as a false
//      red and should be re-read against the contract's own words rather
//      than patched by weakening them.
//
//   3. end-card-ready-<seat> "filled when that seat is in ready" is not
//      given a concrete visual encoding either. This file does not assume
//      a specific opacity or a specific widget shape for "filled" versus
//      "not filled": it only asserts that a ready seat's dot and a
//      not-ready seat's dot render different colour sets, and that the
//      ready seat's dot carries that seat's own opaque LudoColors.seats
//      entry somewhere under it. A 246 that paints both dots identically
//      regardless of readiness is exactly the mutation this is written to
//      catch; a 246 that paints "filled" some other way than "opaque seat
//      colour present" still passes as long as filled and not-filled read
//      differently.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://rematch-client-test.invalid/ws';

// --- keys the contract names -------------------------------------------

const Key _rematchKey = Key('end-card-rematch');
const Key _rematchWaitingKey = Key('end-card-rematch-waiting');
const Key _rematchAskKey = Key('end-card-rematch-ask');
const Key _rematchStartKey = Key('end-card-rematch-start');
const Key _rematchGoneKey = Key('end-card-rematch-gone');
const Key _newRoomKey = Key('game-screen-new-room-button');
const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');
const Key _endedKey = Key('end-card-ended');
const Key _boardKey = Key('game-screen-board');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _statRollsKey = Key('end-card-stat-rolls');
const Key _statSixesKey = Key('end-card-stat-sixes');
const Key _statCapturesKey = Key('end-card-stat-captures');
const Key _statHomeKey = Key('end-card-stat-home');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _errorMessageKey = Key('game-screen-error-message');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');
const Key _lobbyRematchAcceptKey = Key('lobby-rematch-accept');

Key _readyDotKey(int seat) => Key('end-card-ready-$seat');

// --- server-side id generation for pushed frames ---------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'rematch-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot, with the
// --- section 16.6 `rematch` field always present (null by default) --------

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

Map<String, Object?> _rematchJson({
  required int by,
  required List<int> ready,
}) => <String, Object?>{'by': by, 'ready': ready};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  String? clientSeeds,
  int chainIndex = 0,
  Map<String, Object?>? rematch,
  required int seq,
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
  'chain_commit': (chainIndex.isEven ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': clientSeeds,
  'seats':
      seats ??
      <Map<String, Object?>>[
        _seatJson(0, name: 'Sam'),
        _seatJson(1, name: 'Bob'),
      ],
  'turn': turn,
  'winner': winner,
  'rematch': rematch,
  'seq': seq,
};

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

final List<Map<String, Object?>> _threeSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
  _seatJson(2, name: 'Ken'),
];

// --- connecting a controller, mirroring test/end_card_test.dart's own
// --- _connectTo, extended with mySeat (that file always uses seat 0) ------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];
  void enqueue(FakeTransport transport) => _queue.add(transport);
  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued for $url; the test fixture is broken, not the code under '
        'test',
      );
    }
    return _queue.removeAt(0);
  }
}

/// Connects a fresh controller and lands it on the given [state] (default
/// FINISHED, since every rematch scenario below starts from a just-finished
/// game, the way a real player reaches one). [mySeat] defaults to 0.
Future<(RoomController, FakeTransport, _Connector)> _connectTo(
  WidgetTester tester, {
  int mySeat = 0,
  String state = 'FINISHED',
  Map<String, Object?>? turn,
  int? winner,
  List<Map<String, Object?>>? seats,
  int players = 2,
  int hostSeat = 0,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name:
        (seats ?? _twoSeats).firstWhere(
              (Map<String, Object?> s) => s['seat'] == mySeat,
              orElse: () => <String, Object?>{'name': 'Sam'},
            )['name']!
            as String,
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
      data: _roomJson(
        state: state,
        seats: seats ?? _twoSeats,
        turn: turn,
        winner: winner,
        players: players,
        hostSeat: hostSeat,
        seq: 1,
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport, connector);
}

/// Pushes a `room` frame (reply when [re] is given, an unsolicited server
/// push otherwise) at [seq], and drains the two bare pumps FakeTransport's
/// StreamController needs, matching every sibling suite's own idiom.
Future<void> _pushRoom(
  WidgetTester tester,
  FakeTransport transport, {
  String? re,
  required int seq,
  String state = 'LOBBY',
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  String? gameId,
  String? clientSeeds,
  int chainIndex = 0,
  Map<String, Object?>? rematch,
  int players = 2,
  int hostSeat = 0,
}) async {
  transport.pushText(
    _frame(
      type: 'room',
      re: re,
      data: _roomJson(
        state: state,
        seats: seats ?? _twoSeats,
        turn: turn,
        winner: winner,
        gameId: gameId,
        clientSeeds: clientSeeds,
        chainIndex: chainIndex,
        rematch: rematch,
        players: players,
        hostSeat: hostSeat,
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushGameStarted(
  WidgetTester tester,
  FakeTransport transport, {
  required int turnSeat,
  required String gameId,
  required int seq,
  String clientSeeds = '0:seed',
}) async {
  transport.pushText(
    _frame(
      type: 'game_started',
      data: <String, Object?>{
        'turn': turnSeat,
        'game_id': gameId,
        'client_seeds': clientSeeds,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushTurn(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int deadlineMs,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'turn',
      data: <String, Object?>{
        'seat': seat,
        'deadline_ms': deadlineMs,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushRolled(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int value,
  required List<int> legal,
  required int deadlineMs,
  required int k,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'rolled',
      data: <String, Object?>{
        'seat': seat,
        'value': value,
        'legal': legal,
        'deadline_ms': deadlineMs,
        'k': k,
        'reveal': 'a' * 64,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushMoved(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  bool extraRoll = false,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': from,
        'to': to,
        'captured': captured,
        'extra_roll': extraRoll,
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
  required String verifyUrl,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'game_over',
      data: <String, Object?>{
        'winner': winner,
        'verify_url': verifyUrl,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pushPlayerLeft(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'player_left',
      data: <String, Object?>{'seat': seat, 'seq': seq},
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pushes an `error` reply to the request whose id is [re], the shape
/// RoomConnection.request decodes into a ProtocolErrorException
/// (lib/src/net/connection.dart's `_handleIncomingText`).
Future<void> _pushError(
  WidgetTester tester,
  FakeTransport transport, {
  required String re,
  required String code,
  String message = '',
}) async {
  transport.pushText(
    _frame(
      type: 'error',
      re: re,
      data: <String, Object?>{'code': code, 'message': message},
    ),
  );
  await tester.pump();
  await tester.pump();
}

// --- widget harness, mirroring test/end_card_test.dart's own --------------

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
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

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

/// Mounts GameScreen on a Navigator of its own, the way
/// test/game_leave_emphasis_test.dart's own second case does, so a pop is
/// externally observable as GameScreen leaving the tree even though this is
/// the Navigator's only route.
Future<void> _mountOnNavigator(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Navigator(
        onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
          builder: (_) => GameScreen(controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

// --- blob/colour scanning, copied from test/end_card_test.dart's own
// --- helpers rather than imported, per this order's own instruction -------

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
    } else if (widget is Container) {
      final Decoration? decoration = widget.decoration;
      if (decoration is BoxDecoration && decoration.color != null) {
        colors.add(decoration.color!);
      }
    } else if (widget is CircleAvatar) {
      final Color? color = widget.backgroundColor;
      if (color != null) {
        colors.add(color);
      }
    }
  }
  return colors;
}

/// Whole-number match at a word boundary, copied from test/end_card_test
/// .dart's own `_tileShowsNumber`.
bool _tileShowsNumber(WidgetTester tester, Key key, int expected) {
  final Finder tile = find.byKey(key);
  if (tile.evaluate().isEmpty) {
    return false;
  }
  final String blob = _blobUnder(tester, tile);
  return RegExp('(?<!\\d)$expected(?!\\d)').hasMatch(blob);
}

/// Reads the whole-second number game-screen-turn-countdown is showing,
/// copied from test/game_screen_countdown_test.dart's own
/// `_wholeSecondsShown` rather than imported.
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
    expect(descendant, findsAtLeastNWidgets(1));
    text = tester.widget<Text>(descendant.first);
  }
  final String rendered = text.data ?? '';
  final RegExpMatch? match = RegExp(r'-?\d+').firstMatch(rendered);
  if (match == null) {
    fail(
      'the widget keyed $key rendered "$rendered", which contains no '
      'whole number to read a countdown value from',
    );
  }
  return int.parse(match.group(0)!);
}

// =============================================================================

void main() {
  // ===========================================================================
  // Bullet 1: FINISHED -> tap end-card-rematch -> exactly one `rematch`
  // frame with `d` `{}`; a second tap while it is open sends nothing.
  // ===========================================================================
  group('bullet 1: tapping end-card-rematch on FINISHED', () {
    // Catches a rematch button that sends the wrong type, a non-empty `d`
    // (a stray seat or room field riding along), or that never sends at
    // all -- the exact frame shape rule 1 requires, read off the wire, not
    // "a rematch-ish frame went out".
    testWidgets('sends exactly one rematch frame with d == {}', (tester) async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
      await _mount(tester, controller);

      expect(
        controller.room!.state,
        RoomState.finished,
        reason: 'fixture is broken: this case needs a finished room',
      );
      expect(
        find.byKey(_rematchKey),
        findsOneWidget,
        reason: 'end-card-rematch must be on a finished end card',
      );

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_rematchKey));
      await tester.pump();

      final List<String> rematchFrames = transport.sentRaw
          .skip(sentBefore)
          .where((String raw) => _typeOf(raw) == 'rematch')
          .toList();
      expect(
        rematchFrames,
        hasLength(1),
        reason:
            'tapping end-card-rematch must send exactly one rematch '
            'frame; sent since the tap: '
            '${transport.sentRaw.skip(sentBefore).map(_typeOf).toList()}',
      );
      expect(
        _dataOf(rematchFrames.single),
        <String, Object?>{},
        reason:
            'docs/PROTOCOL.md section 16.1: rematch carries d == {}; '
            'got ${_dataOf(rematchFrames.single)}',
      );
    });

    // Catches a rematch button with no in-flight guard: the order's own
    // named failure mode is a double tap racing two rematch frames onto
    // the wire before either reply lands.
    testWidgets(
      'a second tap while the first request is still open sends nothing',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final int sentAfterFirstTap = transport.sentRaw.length;
        expect(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .length,
          1,
          reason: 'fixture is broken: the first tap must have sent one',
        );

        // No reply has been pushed yet, so the request is still open.
        await tester.tap(find.byKey(_rematchKey), warnIfMissed: false);
        await tester.pump();

        expect(
          transport.sentRaw.length,
          sentAfterFirstTap,
          reason:
              'a second tap while the first rematch request is still open '
              'must send nothing; the wire grew by '
              '${transport.sentRaw.length - sentAfterFirstTap} message(s), '
              'exactly the double-send this rule exists to forbid',
        );
      },
    );

    // Ruling 3: the Rematch button is in my seat colour. Catches a
    // generic-coloured primary button that reads the same for every seat.
    testWidgets('end-card-rematch is painted in my own seat colour', (
      tester,
    ) async {
      final (RoomController controller, _, _) = await _connectTo(
        tester,
        mySeat: 0,
        state: 'FINISHED',
        winner: 0,
      );
      await _mount(tester, controller);

      final Set<Color> colors = _colorsUnder(tester, find.byKey(_rematchKey));
      expect(
        colors.contains(LudoColors.seats[0]),
        isTrue,
        reason:
            'end-card-rematch must carry my own seat colour '
            '(LudoColors.seats[0]); colours found: $colors',
      );
    });
  });

  // ===========================================================================
  // Bullet 2: server answers room LOBBY rematch{by:0, ready:[0]} ->
  // end-card-rematch-waiting shown, ready-0 filled, ready-1 not, no
  // end-card-rematch button.
  // ===========================================================================
  group('bullet 2: my own rematch accepted, waiting for the other seat', () {
    testWidgets(
      'end-card-rematch-waiting is shown, ready-0 reads filled and ready-1 '
      'does not, and end-card-rematch is gone',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final String reqId = _idOf(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .last,
        );

        await _pushRoom(
          tester,
          transport,
          re: reqId,
          seq: 2,
          state: 'LOBBY',
          seats: _twoSeats,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );

        expect(
          controller.room!.state,
          RoomState.lobby,
          reason: 'fixture is broken: the reply must move the room to LOBBY',
        );
        expect(
          controller.room!.rematch?.by,
          0,
          reason:
              'RoomSnapshot.rematch must decode the section 16.6 field; '
              'got ${controller.room!.rematch}',
        );
        expect(controller.room!.rematch?.ready, <int>[0]);

        expect(
          find.byKey(_rematchWaitingKey),
          findsOneWidget,
          reason:
              'end-card-rematch-waiting must be shown once my own seat is '
              'in rematch.ready',
        );
        expect(
          find.byKey(_rematchKey),
          findsNothing,
          reason:
              'end-card-rematch must not render once my seat is ready; '
              'the waiting line replaces it, per rule 4',
        );

        final Finder readyDot0 = find.byKey(_readyDotKey(0));
        final Finder readyDot1 = find.byKey(_readyDotKey(1));
        expect(
          readyDot0,
          findsOneWidget,
          reason: 'end-card-ready-0 must exist for occupied seat 0',
        );
        expect(
          readyDot1,
          findsOneWidget,
          reason: 'end-card-ready-1 must exist for occupied seat 1',
        );

        final Set<Color> dot0Colors = _colorsUnder(tester, readyDot0);
        final Set<Color> dot1Colors = _colorsUnder(tester, readyDot1);
        expect(
          dot0Colors.contains(LudoColors.seats[0]),
          isTrue,
          reason:
              'end-card-ready-0 (seat 0, in ready) must carry its own '
              'opaque seat colour somewhere under it; colours found: '
              '$dot0Colors',
        );
        expect(
          dot0Colors,
          isNot(equals(dot1Colors)),
          reason:
              'end-card-ready-0 (ready) and end-card-ready-1 (not ready) '
              'must render differently; a dot that looks the same '
              'regardless of readiness is exactly the mutation this '
              'assertion exists to catch. dot0: $dot0Colors, dot1: '
              '$dot1Colors',
        );
      },
    );

    // Ruling 3/8: the secondary New table control stays present, and must
    // not read as primary here -- that is reserved for the gone state
    // (bullet 7a below).
    testWidgets(
      'game-screen-new-room-button stays present and is not the primary '
      '(ElevatedButton) control while waiting',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
        await _mount(tester, controller);
        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final String reqId = _idOf(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .last,
        );
        await _pushRoom(
          tester,
          transport,
          re: reqId,
          seq: 2,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );

        final Finder newRoom = find.byKey(_newRoomKey);
        expect(newRoom, findsOneWidget);
        final Widget newRoomWidget = tester.widget(newRoom);
        expect(
          newRoomWidget is OutlinedButton || newRoomWidget is TextButton,
          isTrue,
          reason:
              'rule 3: "New table stays, smaller, secondary" while a '
              'rematch is available; found ${newRoomWidget.runtimeType}',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet 3: the other side (me seat 1): room LOBBY rematch{by:0,
  // ready:[0]} arrives while my end card is up -> end-card-rematch-ask
  // names seat 0's player; one tap accepts; tap count to accepted == 1.
  // ===========================================================================
  group('bullet 3: being asked by the other seat', () {
    testWidgets(
      'end-card-rematch-ask names seat 0, end-card-rematch is the one tap '
      'that accepts, and exactly one rematch frame is ever sent',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 1, state: 'FINISHED', winner: 0);
        await _mount(tester, controller);
        final AppLocalizations loc = _locOf(tester);

        expect(
          find.byKey(_loseKey),
          findsOneWidget,
          reason: 'fixture is broken: seat 1 must see the loser card here',
        );

        // Seat 0 (Sam) asks: a server push, unprompted (re stays null).
        await _pushRoom(
          tester,
          transport,
          seq: 2,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );

        expect(controller.room!.rematch?.by, 0);
        expect(controller.room!.rematch?.ready, <int>[0]);

        final Finder askFinder = find.byKey(_rematchAskKey);
        expect(
          askFinder,
          findsOneWidget,
          reason:
              'end-card-rematch-ask must be shown: my seat (1) is not in '
              'rematch.ready {0}',
        );
        final String askBlob = _blobUnder(tester, askFinder);
        expect(
          askBlob.contains(loc.endRematchAsk('Sam')),
          isTrue,
          reason:
              'end-card-rematch-ask must read loc.endRematchAsk(\'Sam\') '
              '("${loc.endRematchAsk('Sam')}"); blob was "$askBlob"',
        );
        expect(
          find.byKey(_rematchWaitingKey),
          findsNothing,
          reason:
              'end-card-rematch-waiting must not show before my own seat '
              'has accepted',
        );
        expect(
          find.byKey(_rematchKey),
          findsOneWidget,
          reason:
              'end-card-rematch (same key) must be the accept control '
              'while I am being asked',
        );

        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();

        final List<String> rematchFramesAfterAccept = transport.sentRaw
            .where((String raw) => _typeOf(raw) == 'rematch')
            .toList();
        expect(
          rematchFramesAfterAccept,
          hasLength(1),
          reason:
              'accepting must send exactly one rematch frame; this is the '
              'one tap from end card to accepted the contract pins',
        );
        final String acceptId = _idOf(rematchFramesAfterAccept.single);

        // The server's reply: my own seat now in ready too.
        await _pushRoom(
          tester,
          transport,
          re: acceptId,
          seq: 3,
          rematch: _rematchJson(by: 0, ready: const <int>[0, 1]),
        );

        expect(
          find.byKey(_rematchWaitingKey),
          findsOneWidget,
          reason: 'end-card-rematch-waiting must show once I have accepted',
        );
        expect(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .length,
          1,
          reason:
              'tap count from end card to accepted must stay 1: the '
              'server\'s own accept reply must never provoke a second '
              'rematch send',
        );
      },
    );

    // Rule 4: "the your_turn cue is NOT played" when the ask arrives --
    // there is no rematch cue, and none must be invented.
    testWidgets('the rematch ask arriving plays no feedback cue at all', (
      tester,
    ) async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectTo(tester, mySeat: 1, state: 'FINISHED', winner: 0);
      final _FakeFeedbackService fake = _FakeFeedbackService();
      await tester.pumpWidget(
        _harness(
          FeedbackScope(
            settings: FeedbackSettings.forTest(),
            service: fake,
            child: GameScreen(controller: controller),
          ),
        ),
      );
      await tester.pump();

      await _pushRoom(
        tester,
        transport,
        seq: 2,
        rematch: _rematchJson(by: 0, ready: const <int>[0]),
      );

      expect(
        find.byKey(_rematchAskKey),
        findsOneWidget,
        reason: 'fixture is broken: the ask must be showing by this point',
      );
      expect(
        fake.recorded,
        isEmpty,
        reason:
            'rule 4: no cue, not even your_turn, must play when a '
            'rematch LOBBY snapshot lands; recorded ${fake.recorded}',
      );
    });
  });

  // ===========================================================================
  // Bullet 4: room ready [0,1], then game_started with a new game_id, then
  // turn: no end card; board shown; countdown running for the new turn;
  // stats of the next game_over count only the second game's frames.
  // ===========================================================================
  group('bullet 4: the second game after a rematch', () {
    Future<(RoomController, FakeTransport)> playThroughRematchIntoGameTwo(
      WidgetTester tester,
    ) async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectTo(tester, mySeat: 0, state: 'PLAYING', turn: null);
      await _mount(tester, controller);

      // Game one: deliberately different numbers from game two below, so a
      // leak between the two is visible rather than a coincidental match.
      await _pushGameStarted(
        tester,
        transport,
        turnSeat: 0,
        gameId: 'g1',
        seq: 2,
      );
      await _pushTurn(tester, transport, seat: 0, deadlineMs: 45000, seq: 3);
      await _pushRolled(
        tester,
        transport,
        seat: 0,
        value: 3,
        legal: const <int>[0, 1, 2, 3],
        deadlineMs: 45000,
        k: 1,
        seq: 4,
      );
      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: -1,
        to: 3,
        seq: 5,
      );
      await _pushRolled(
        tester,
        transport,
        seat: 0,
        value: 2,
        legal: const <int>[0, 1, 2, 3],
        deadlineMs: 45000,
        k: 2,
        seq: 6,
      );
      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: 3,
        to: 5,
        seq: 7,
      );
      await _pushGameOver(
        tester,
        transport,
        winner: 0,
        verifyUrl: 'https://rematch-client-test.invalid/verify/g1',
        seq: 8,
      );

      expect(
        controller.room!.state,
        RoomState.finished,
        reason: 'fixture is broken: game one must finish',
      );

      await tester.tap(find.byKey(_rematchKey));
      await tester.pump();
      final String reqId = _idOf(
        transport.sentRaw.where((String raw) => _typeOf(raw) == 'rematch').last,
      );
      await _pushRoom(
        tester,
        transport,
        re: reqId,
        seq: 9,
        rematch: _rematchJson(by: 0, ready: const <int>[0]),
        chainIndex: 1,
      );
      await _pushRoom(
        tester,
        transport,
        seq: 10,
        rematch: _rematchJson(by: 0, ready: const <int>[0, 1]),
        chainIndex: 1,
      );

      // Game two: same seat and turn_seconds as game one's own turns
      // (rule 5's own named edge: "the countdown memo is not simplified"),
      // but otherwise a different roll/capture/home script.
      await _pushGameStarted(
        tester,
        transport,
        turnSeat: 0,
        gameId: 'g2',
        seq: 11,
      );
      await _pushTurn(tester, transport, seat: 0, deadlineMs: 45000, seq: 12);

      return (controller, transport);
    }

    testWidgets(
      'no end card, the board is shown, and the countdown is running for '
      "the new game's turn",
      (tester) async {
        final (RoomController controller, _) =
            await playThroughRematchIntoGameTwo(tester);

        expect(
          controller.room!.state,
          RoomState.playing,
          reason: 'fixture is broken: game two must be playing by now',
        );
        expect(controller.room!.gameId, 'g2');

        expect(find.byKey(_winKey), findsNothing);
        expect(find.byKey(_loseKey), findsNothing);
        expect(find.byKey(_endedKey), findsNothing);
        expect(
          find.byKey(_boardKey),
          findsOneWidget,
          reason: 'the board must be shown once game two is playing',
        );

        expect(
          find.byKey(_countdownKey),
          findsOneWidget,
          reason:
              "game-screen-turn-countdown must be present for game two's "
              'first turn',
        );
        final int before = _wholeSecondsShown(tester, _countdownKey);
        await tester.pump(const Duration(seconds: 1));
        final int after = _wholeSecondsShown(tester, _countdownKey);
        expect(
          after,
          lessThan(before),
          reason:
              "rule 5: a new game's first turn must start its countdown "
              'exactly as the first game\'s did, even though this turn '
              'shares (seat, deadlineMs) with game one\'s own turns -- a '
              'countdown memo that failed to reset on the new game_id '
              'would leave this stuck rather than ticking down; was '
              '$before, now $after',
        );
      },
    );

    testWidgets("the next game_over's stats count only game two's own frames", (
      tester,
    ) async {
      final (RoomController controller, FakeTransport transport) =
          await playThroughRematchIntoGameTwo(tester);

      // Game two's own script: 3 rolls, 1 six, 1 capture made, 1 token
      // home -- every number distinct from game one's (2 rolls, 0 sixes,
      // 0 captures made, 0 tokens home) so a leak reads as a visibly
      // wrong number, not a coincidental match.
      await _pushRolled(
        tester,
        transport,
        seat: 0,
        value: 6,
        legal: const <int>[0, 1, 2, 3],
        deadlineMs: 45000,
        k: 1,
        seq: 13,
      );
      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: -1,
        to: 6,
        seq: 14,
      );
      await _pushRolled(
        tester,
        transport,
        seat: 0,
        value: 4,
        legal: const <int>[0, 1, 2, 3],
        deadlineMs: 45000,
        k: 2,
        seq: 15,
      );
      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 1,
        from: -1,
        to: 4,
        captured: const <Map<String, Object?>>[
          <String, Object?>{'seat': 1, 'token': 0},
        ],
        seq: 16,
      );
      await _pushRolled(
        tester,
        transport,
        seat: 0,
        value: 5,
        legal: const <int>[0, 1, 2, 3],
        deadlineMs: 45000,
        k: 3,
        seq: 17,
      );
      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: 6,
        to: 57,
        seq: 18,
      );
      await _pushGameOver(
        tester,
        transport,
        winner: 0,
        verifyUrl: 'https://rematch-client-test.invalid/verify/g2',
        seq: 19,
      );

      expect(controller.room!.state, RoomState.finished);
      expect(controller.room!.gameId, 'g2');

      expect(
        _tileShowsNumber(tester, _statRollsKey, 3),
        isTrue,
        reason:
            'end-card-stat-rolls must show 3 (game two only, not 2 + 3 = '
            '5 carried over from game one); blob was '
            '"${_blobUnder(tester, find.byKey(_statRollsKey))}"',
      );
      expect(
        _tileShowsNumber(tester, _statSixesKey, 1),
        isTrue,
        reason: 'end-card-stat-sixes must show 1, game two\'s own count',
      );
      expect(
        _tileShowsNumber(tester, _statCapturesKey, 1),
        isTrue,
        reason: 'end-card-stat-captures must show 1, game two\'s own count',
      );
      expect(
        _tileShowsNumber(tester, _statHomeKey, 1),
        isTrue,
        reason: 'end-card-stat-home must show 1, game two\'s own count',
      );
    });
  });

  // ===========================================================================
  // Bullet 5: host start, 3 seats, ready [0,1]: end-card-rematch-start
  // shown to the host (seat 0), absent for seat 1; tapping sends
  // start_game.
  // ===========================================================================
  group('bullet 5: host-forced start from a partially-ready rematch LOBBY', () {
    Future<(RoomController, FakeTransport)> reachThreeSeatPartialReady(
      WidgetTester tester, {
      required int mySeat,
    }) async {
      final (
        RoomController controller,
        FakeTransport transport,
        _,
      ) = await _connectTo(
        tester,
        mySeat: mySeat,
        state: 'FINISHED',
        winner: 0,
        seats: _threeSeats,
        players: 3,
      );
      await _mount(tester, controller);
      await _pushRoom(
        tester,
        transport,
        seq: 2,
        seats: _threeSeats,
        players: 3,
        rematch: _rematchJson(by: 0, ready: const <int>[0]),
      );
      await _pushRoom(
        tester,
        transport,
        seq: 3,
        seats: _threeSeats,
        players: 3,
        rematch: _rematchJson(by: 0, ready: const <int>[0, 1]),
      );
      expect(controller.room!.rematch?.ready, <int>[0, 1]);
      return (controller, transport);
    }

    testWidgets(
      'the host (seat 0) sees end-card-rematch-start naming the ready '
      'count',
      (tester) async {
        final (RoomController controller, _) = await reachThreeSeatPartialReady(
          tester,
          mySeat: 0,
        );
        final AppLocalizations loc = _locOf(tester);

        expect(controller.isHost, isTrue, reason: 'fixture is broken');
        final Finder startFinder = find.byKey(_rematchStartKey);
        expect(
          startFinder,
          findsOneWidget,
          reason:
              'end-card-rematch-start must be shown to the host: at '
              'least two ready (0, 1) and not every occupied seat ready '
              '(2 is not)',
        );
        final String blob = _blobUnder(tester, startFinder);
        expect(
          blob.contains(loc.endRematchStartReady(2)),
          isTrue,
          reason:
              'end-card-rematch-start must read '
              'loc.endRematchStartReady(2) '
              '("${loc.endRematchStartReady(2)}"); blob was "$blob"',
        );
      },
    );

    testWidgets('a non-host (seat 1) never sees end-card-rematch-start', (
      tester,
    ) async {
      final (RoomController controller, _) = await reachThreeSeatPartialReady(
        tester,
        mySeat: 1,
      );

      expect(controller.isHost, isFalse, reason: 'fixture is broken');
      expect(
        find.byKey(_rematchStartKey),
        findsNothing,
        reason: 'rule 4: end-card-rematch-start is "not shown to non-hosts"',
      );
    });

    testWidgets(
      "tapping end-card-rematch-start as the host sends start_game with d "
      '== {}',
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await reachThreeSeatPartialReady(tester, mySeat: 0);

        final int startsBefore = transport.sentRaw
            .where((String raw) => _typeOf(raw) == 'start_game')
            .length;
        expect(startsBefore, 0, reason: 'fixture is broken');

        await tester.tap(find.byKey(_rematchStartKey));
        await tester.pump();

        final List<String> startFrames = transport.sentRaw
            .where((String raw) => _typeOf(raw) == 'start_game')
            .toList();
        expect(
          startFrames,
          hasLength(1),
          reason:
              'tapping end-card-rematch-start must send exactly one '
              'start_game frame; sent '
              '${transport.sentRaw.map(_typeOf).toList()}',
        );
        expect(_dataOf(startFrames.single), <String, Object?>{});

        controller.dispose();
      },
    );
  });

  // ===========================================================================
  // Bullet 6: a seat removed by a host-forced start (player_left naming my
  // own seat, in a rematch LOBBY) leaves the game exactly as rule 6 says.
  // No pre-existing "removed from a lobby" path was found anywhere under
  // lib/ (grepped for player_left/kicked/removed-seat handling outside
  // room_controller.dart's own seat-list bookkeeping), so per the order's
  // own fallback this tests that the screen pops with no result, the same
  // way game-screen-appbar-leave already does
  // (lib/src/game_screen.dart's `_leave`).
  // ===========================================================================
  group('bullet 6: being the removed seat in a rematch LOBBY', () {
    testWidgets(
      'player_left naming my own seat pops GameScreen off the navigator',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
          _,
        ) = await _connectTo(
          tester,
          mySeat: 1,
          state: 'FINISHED',
          winner: 0,
          seats: _threeSeats,
          players: 3,
        );
        await _mountOnNavigator(tester, controller);
        await _pushRoom(
          tester,
          transport,
          seq: 2,
          seats: _threeSeats,
          players: 3,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );

        expect(
          find.byType(GameScreen),
          findsOneWidget,
          reason: 'fixture is broken: GameScreen must still be mounted',
        );

        await _pushPlayerLeft(tester, transport, seat: 1, seq: 3);

        expect(
          tester.takeException(),
          isNull,
          reason:
              'player_left naming my own seat must not throw while this '
              'screen is handling it',
        );

        // Bounded settle for the pop to land, the same 1-second budget
        // test/game_leave_emphasis_test.dart's own Leave case uses.
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          find.byType(GameScreen),
          findsNothing,
          reason:
              'rule 6: being named in a player_left for my own seat must '
              'leave the game exactly as the existing leave path does -- '
              'GameScreen must have popped off the navigator within 1s',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet 7a: NO_SUCH_ROOM answer to rematch -> end-card-rematch-gone,
  // New table primary.
  // ===========================================================================
  group('bullet 7a: NO_SUCH_ROOM on rematch', () {
    testWidgets(
      'end-card-rematch-gone is shown and game-screen-new-room-button '
      'reads as the primary control again',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
        await _mount(tester, controller);
        final AppLocalizations loc = _locOf(tester);

        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final String reqId = _idOf(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .last,
        );
        await _pushError(tester, transport, re: reqId, code: 'NO_SUCH_ROOM');

        final Finder goneFinder = find.byKey(_rematchGoneKey);
        expect(
          goneFinder,
          findsOneWidget,
          reason:
              'rule 8: a NO_SUCH_ROOM answer to rematch must show '
              'end-card-rematch-gone',
        );
        final String blob = _blobUnder(tester, goneFinder);
        expect(
          blob.contains(loc.endRematchGone),
          isTrue,
          reason:
              'end-card-rematch-gone must read loc.endRematchGone '
              '("${loc.endRematchGone}"); blob was "$blob"',
        );
        expect(
          find.byKey(_rematchKey),
          findsNothing,
          reason: 'there is nothing left to rematch once the room is gone',
        );

        final Finder newRoom = find.byKey(_newRoomKey);
        expect(newRoom, findsOneWidget);
        final Widget newRoomWidget = tester.widget(newRoom);
        expect(
          newRoomWidget is ElevatedButton,
          isTrue,
          reason:
              'rule 8: "New table becomes the primary action"; this '
              'suite reads primary as ElevatedButton, the same '
              'convention test/game_leave_emphasis_test.dart already '
              'uses for Leave/Reconnect. Found '
              '${newRoomWidget.runtimeType}',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet 7b: any other error on rematch -> the existing in-room error
  // line, the Rematch button enabled again. Per this file's header
  // ambiguity note 1: read here as the ordinary connection-lost body
  // (game-screen-connection-lost / game-screen-error-message, the same
  // body every other in-room request failure already produces on this
  // screen) rather than a NO_SUCH_ROOM-shaped end-card state, with "enabled
  // again" checked once the player reconnects back into the same lobby.
  // ===========================================================================
  group('bullet 7b (ambiguous, see file header note 1): any other rematch '
      'error', () {
    testWidgets('WRONG_PHASE shows the existing in-room error line, not '
        'end-card-rematch-gone', (tester) async {
      final (RoomController controller, FakeTransport transport, _) =
          await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
      await _mount(tester, controller);

      await tester.tap(find.byKey(_rematchKey));
      await tester.pump();
      final String reqId = _idOf(
        transport.sentRaw.where((String raw) => _typeOf(raw) == 'rematch').last,
      );
      await _pushError(
        tester,
        transport,
        re: reqId,
        code: 'WRONG_PHASE',
        message: 'room already playing',
      );

      expect(controller.phase, RoomPhase.failed);
      expect(controller.errorCode, 'WRONG_PHASE');
      expect(
        find.byKey(_connectionLostKey),
        findsOneWidget,
        reason:
            'ambiguity note 1\'s own reading: any rematch error other '
            'than NO_SUCH_ROOM falls through to the existing '
            'game-screen-connection-lost body',
      );
      expect(
        find.byKey(_errorMessageKey),
        findsOneWidget,
        reason:
            'game-screen-error-message must show controller.errorMessage, '
            'the same as every other in-room request failure',
      );
      expect(
        find.byKey(_rematchGoneKey),
        findsNothing,
        reason:
            'end-card-rematch-gone is NO_SUCH_ROOM\'s own special case, '
            'not every error\'s',
      );
    });

    testWidgets(
      'the Rematch button is enabled again once reconnected back into '
      'the same, still-unready rematch LOBBY',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
          _Connector connector,
        ) = await _connectTo(
          tester,
          mySeat: 1,
          state: 'FINISHED',
          winner: 0,
        );
        await _mount(tester, controller);

        await _pushRoom(
          tester,
          transport,
          seq: 2,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );
        expect(find.byKey(_rematchAskKey), findsOneWidget);

        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final String reqId = _idOf(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .last,
        );
        await _pushError(tester, transport, re: reqId, code: 'WRONG_PHASE');
        expect(controller.phase, RoomPhase.failed);

        final FakeTransport resumeTransport = FakeTransport();
        connector.enqueue(resumeTransport);
        await tester.tap(find.byKey(_reconnectButtonKey));
        await tester.pump();

        expect(
          resumeTransport.sentRaw,
          isNotEmpty,
          reason: 'fixture is broken: reconnect must send a resume request',
        );
        final String resumeId = _idOf(resumeTransport.sentRaw.last);
        resumeTransport.pushText(
          _frame(
            type: 'room',
            re: resumeId,
            data: _roomJson(
              state: 'LOBBY',
              seats: _twoSeats,
              rematch: _rematchJson(by: 0, ready: const <int>[0]),
              chainIndex: 1,
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(controller.phase, RoomPhase.connected);
        final Finder rematchFinder = find.byKey(_rematchKey);
        expect(
          rematchFinder,
          findsOneWidget,
          reason:
              'back on the same still-unready rematch LOBBY, '
              'end-card-rematch (the accept control) must be shown '
              'again',
        );

        final int sentBeforeRetap = resumeTransport.sentRaw.length;
        await tester.tap(rematchFinder);
        await tester.pump();
        expect(
          resumeTransport.sentRaw.length,
          greaterThan(sentBeforeRetap),
          reason:
              'the Rematch button must be enabled again after '
              'reconnecting, not left stuck disabled from the failed '
              'request; tapping it here must send a fresh rematch frame',
        );
      },
    );
  });

  // ===========================================================================
  // Bullet: a joiner of a rematch LOBBY lands on LobbyScreen (its route
  // never saw a game); lobby-rematch-accept is the primary action; tapping
  // sends one rematch.
  // ===========================================================================
  group('bullet: a joiner lands on LobbyScreen for a rematch LOBBY', () {
    testWidgets(
      'lobby-rematch-accept is shown and tapping it sends exactly one '
      'rematch frame with d == {}',
      (tester) async {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          _harness(
            LobbyScreen(
              controller: controller,
              action: LobbyAction.join,
              playerName: 'Lina',
              code: 'ABC234',
            ),
          ),
        );
        await tester.pump();

        final String joinId = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 1, 'seat_token': 'tok-1'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: joinId,
            data: _roomJson(
              code: 'ABC234',
              state: 'LOBBY',
              hostSeat: 0,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam'),
                _seatJson(1, name: 'Lina'),
              ],
              rematch: _rematchJson(by: 0, ready: const <int>[0]),
              seq: 1,
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(LobbyScreen),
          findsOneWidget,
          reason:
              'rule 7: a rematch LOBBY not listing me is shown on '
              'LobbyScreen, since this route never saw a game',
        );
        final AppLocalizations loc = AppLocalizations.of(
          tester.element(find.byType(LobbyScreen)),
        );
        final Finder acceptFinder = find.byKey(_lobbyRematchAcceptKey);
        expect(
          acceptFinder,
          findsOneWidget,
          reason:
              'lobby-rematch-accept must be shown: I (seat 1) am not in '
              'rematch.ready {0}',
        );
        final String blob = _blobUnder(tester, acceptFinder);
        expect(
          blob.contains(loc.endRematch),
          isTrue,
          reason:
              'rule 7: lobby-rematch-accept carries the same endRematch '
              'text ("${loc.endRematch}"); blob was "$blob"',
        );

        await tester.tap(acceptFinder);
        await tester.pump();

        final List<String> rematchFrames = transport.sentRaw
            .where((String raw) => _typeOf(raw) == 'rematch')
            .toList();
        expect(rematchFrames, hasLength(1));
        expect(_dataOf(rematchFrames.single), <String, Object?>{});
      },
    );
  });

  // ===========================================================================
  // Bullet: Arabic, the ask line and the waiting line, both RTL.
  // ===========================================================================
  group('bullet: Arabic ask and waiting lines, RTL', () {
    testWidgets(
      'the ask line matches the contract\'s own Arabic wording and the '
      'card reads RTL',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 1, state: 'FINISHED', winner: 0);
        await tester.pumpWidget(
          _harness(
            GameScreen(controller: controller),
            locale: const Locale('ar'),
          ),
        );
        await tester.pump();

        await _pushRoom(
          tester,
          transport,
          seq: 2,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );

        final AppLocalizations loc = _locOf(tester);
        expect(loc.localeName, 'ar', reason: 'fixture is broken');
        expect(
          loc.endRematchAsk('Sam'),
          'دعوة من Sam لجولة أخرى',
          reason:
              'endRematchAsk(name) under ar must be the contract\'s own '
              'wording; got "${loc.endRematchAsk('Sam')}"',
        );
        final String blob = _blobUnder(tester, find.byKey(_rematchAskKey));
        expect(blob.contains(loc.endRematchAsk('Sam')), isTrue);

        final TextDirection direction = Directionality.of(
          tester.element(find.byType(GameScreen)),
        );
        expect(direction, TextDirection.rtl);
      },
    );

    testWidgets(
      'the waiting line matches the contract\'s own Arabic wording and '
      'the card reads RTL',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _connectTo(tester, mySeat: 0, state: 'FINISHED', winner: 0);
        await tester.pumpWidget(
          _harness(
            GameScreen(controller: controller),
            locale: const Locale('ar'),
          ),
        );
        await tester.pump();

        await tester.tap(find.byKey(_rematchKey));
        await tester.pump();
        final String reqId = _idOf(
          transport.sentRaw
              .where((String raw) => _typeOf(raw) == 'rematch')
              .last,
        );
        await _pushRoom(
          tester,
          transport,
          re: reqId,
          seq: 2,
          rematch: _rematchJson(by: 0, ready: const <int>[0]),
        );

        final AppLocalizations loc = _locOf(tester);
        expect(
          loc.endRematchWaiting,
          'بانتظار الآخرين',
          reason:
              'endRematchWaiting under ar must be the contract\'s own '
              'wording; got "${loc.endRematchWaiting}"',
        );
        final String blob = _blobUnder(tester, find.byKey(_rematchWaitingKey));
        expect(blob.contains(loc.endRematchWaiting), isTrue);

        final TextDirection direction = Directionality.of(
          tester.element(find.byType(GameScreen)),
        );
        expect(direction, TextDirection.rtl);
      },
    );
  });
}

/// Records every cue GameScreen asks the service to play, copied from
/// test/feedback_wiring_test.dart's own `_FakeFeedbackService` rather than
/// imported, per this order's own instruction.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}
