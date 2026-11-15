// Order C-649t: the client must offer Play again on every end card of a room
// that plays game 1, rematch, game 2, rematch, game 3, rematch, game 4 with
// the same two seats, and every tap must send a `rematch` envelope
// (docs/PROTOCOL.md sections 16.1 to 16.4 and 16.7, doctrine P5 and P6).
//
// Written from the protocol, not from the client's code. The frames are the
// ones a real server sends for a two seat room (seats 0 and 2, the canonical
// set for two players), in the order and with the seq steps of section 16:
//
//   a rematch asked by seat A, accepted by seat B:
//     room  (state LOBBY, rematch {by A, ready [A]}, chain_index + 1,
//            a new chain_commit, seq + 1; A's copy carries re)
//     room  (rematch ready [A, B], seq + 1; B's copy carries re)
//     seat_seed x2 (origin "server": no seat sent a seed, 11.2)
//     game_started, then the standalone turn (13.1)
//
// Real GameScreen over a real RoomController on a FakeTransport, the road
// test/rematch_client_test.dart takes. Four games are played in one mount.
// The device asks first on some rematches and accepts the other seat's ask on
// the others (16.7), and the whole thing runs once from each seat. The device
// seat wins some games and loses others, so both end cards (win and lose) are
// the one the rematch control must be on.
//
// Every failure reason carries the scenario, the device seat, the game
// number and the step, which with the fixed frames below is the whole recipe
// to replay it. Nothing here is random and nothing waits on a wall clock:
// every wait is a pump of a stated length.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c649-rematch-chain-test.invalid/ws';
const String _code = 'K7M2QP';

/// The canonical seats of a two player room (docs/PROTOCOL.md section 3).
const int _hostSeat = 0;
const int _otherSeat = 2;
const Map<int, String> _names = <int, String>{
  _hostSeat: 'Sam',
  _otherSeat: 'Bob',
};

const Key _rematchKey = Key('end-card-rematch');
const Key _rematchWaitingKey = Key('end-card-rematch-waiting');
const Key _rematchAskKey = Key('end-card-rematch-ask');
const Key _rematchGoneKey = Key('end-card-rematch-gone');
const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');
const Key _endedKey = Key('end-card-ended');
const Key _boardKey = Key('game-screen-board');
const Key _statRollsKey = Key('end-card-stat-rolls');

const int _rematches = 3;

int _serverIdSeq = 0;

String _nextServerId() {
  _serverIdSeq += 1;
  return 'c649-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sent) => _decode(sent)['id']! as String;

String _typeOf(String sent) => _decode(sent)['t']! as String;

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

/// A chain commitment that differs for every chain index, 64 hex characters.
String _chainCommit(int index) => index.toRadixString(16).padLeft(2, '0') * 32;

String _gameId(int game) => game.toRadixString(16).padLeft(16, '0');

Map<String, Object?> _seatJson(int seat) => <String, Object?>{
  'seat': seat,
  'name': _names[seat],
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  required String state,
  required int seq,
  int chainIndex = 0,
  String? gameId,
  Map<String, Object?>? turn,
  Map<String, Object?>? rematch,
}) => <String, Object?>{
  'code': _code,
  'state': state,
  'host_seat': _hostSeat,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': _chainCommit(chainIndex),
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': gameId == null ? null : '0:s0|2:s2',
  'seats': <Map<String, Object?>>[_seatJson(_hostSeat), _seatJson(_otherSeat)],
  'turn': turn,
  'winner': null,
  'seq': seq,
  'rematch': ?rematch,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  const Duration chunk = Duration(milliseconds: 250);
  Duration remaining = total;
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
  await tester.pump();
}

/// The device, the transport and the room's seq, with the helpers that push
/// the frames of one scenario. [why] names where a failure happened.
class _Table {
  _Table({
    required this.tester,
    required this.controller,
    required this.transport,
    required this.scenario,
    required this.me,
  });

  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final String scenario;
  final int me;

  int seq = 1;
  int game = 1;
  int chainIndex = 0;
  int rollK = 0;

  int get other => me == _hostSeat ? _otherSeat : _hostSeat;

  String why(String step) =>
      'scenario=$scenario device_seat=$me game=$game chain_index=$chainIndex '
      'step="$step" seq=$seq (fixed frames, nothing random: these four '
      'values replay it)';

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  int sent(String type) =>
      transport.sentRaw.where((String raw) => _typeOf(raw) == type).length;

  Future<void> _settle() async {
    await tester.pump();
    await tester.pump();
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    seq += 1;
    transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': seq}),
    );
    await _settle();
  }

  Future<void> pushRoom(Map<String, Object?> room, {String? re}) async {
    transport.pushText(_frame(type: 'room', re: re, data: room));
    seq = room['seq']! as int;
    await _settle();
  }

  Future<void> turn(int seat) =>
      push('turn', <String, Object?>{'seat': seat, 'deadline_ms': 45000});

  Future<void> rolled(int seat, int value) {
    rollK += 1;
    return push('rolled', <String, Object?>{
      'seat': seat,
      'value': value,
      'legal': const <int>[0],
      'deadline_ms': 45000,
      'k': rollK,
      'reveal': 'a' * 64,
    });
  }

  Future<void> moved(int seat, int from, int to) =>
      push('moved', <String, Object?>{
        'seat': seat,
        'token': 0,
        'from': from,
        'to': to,
        'captured': const <Map<String, Object?>>[],
        'extra_roll': false,
      });

  /// Plays the running game: the device rolls [myRolls] times, [winner] wins.
  /// The turn passes between the two seats after every move, as the server
  /// sends it, and the winning move is followed by `game_over` and no `turn`.
  Future<void> playGame({required int myRolls, required int winner}) async {
    rollK = 0;
    for (int round = 1; round <= myRolls; round++) {
      final bool last = round == myRolls;
      await rolled(me, 6);
      await moved(me, round == 1 ? -1 : round, round + 1);
      if (last && winner == me) {
        break;
      }
      await turn(other);
      await rolled(other, 6);
      await moved(other, -1, 0);
      if (last) {
        break;
      }
      await turn(me);
    }
    await push('game_over', <String, Object?>{
      'winner': winner,
      'verify_url': 'https://c649.invalid/v/${_gameId(game)}',
    });
    await _pumpFor(tester, kEndCardHoldLimit);
  }

  /// The end card of game [game] is up, is the right one for [winner], and
  /// offers Play again, enabled.
  void expectEndCardOffersRematch({required int winner, required String at}) {
    final String ctx = why(at);
    expect(
      controller.room!.state,
      RoomState.finished,
      reason:
          'expected the room FINISHED after game_over; got '
          '${controller.room!.state} [$ctx]',
    );
    expect(
      find.byKey(winner == me ? _winKey : _loseKey),
      findsOneWidget,
      reason:
          'expected the ${winner == me ? 'win' : 'lose'} end card of '
          'game $game [$ctx]',
    );
    expect(
      find.byKey(_endedKey),
      findsNothing,
      reason: 'the ended placeholder must not replace the end card [$ctx]',
    );
    expect(
      find.byKey(_rematchGoneKey),
      findsNothing,
      reason:
          'the table-closed state must not show; the room is open '
          '[$ctx]',
    );
    expectRematchEnabled(ctx);
  }

  void expectRematchEnabled(String ctx) {
    final Finder button = find.byKey(_rematchKey);
    final RoomSnapshot? held = controller.room;
    expect(
      button,
      findsOneWidget,
      reason:
          'expected the Play again control (end-card-rematch) on this '
          'end card and found ${button.evaluate().length}. On screen '
          'instead: waiting line '
          '${find.byKey(_rematchWaitingKey).evaluate().length}, ask line '
          '${find.byKey(_rematchAskKey).evaluate().length}. The client holds '
          'state=${held?.state} winner=${held?.winner} '
          'game_id=${held?.gameId} rematch.by=${held?.rematch?.by} '
          'rematch.ready=${held?.rematch?.ready} [$ctx]',
    );
    final Widget widget = tester.widget(button);
    final VoidCallback? onPressed = widget is ButtonStyleButton
        ? widget.onPressed
        : tester
              .widget<ButtonStyleButton>(
                find.descendant(
                  of: button,
                  matching: find.byWidgetPredicate(
                    (Widget w) => w is ButtonStyleButton,
                  ),
                ),
              )
              .onPressed;
    expect(
      onPressed,
      isNotNull,
      reason: 'the Play again control is on screen but disabled [$ctx]',
    );
  }

  /// Taps Play again and returns the id of the `rematch` frame it sent,
  /// failing unless exactly one new `rematch` envelope with `d == {}` left.
  Future<String> tapRematch(String at) async {
    final String ctx = why(at);
    final int before = sent('rematch');
    final int sentBefore = transport.sentRaw.length;
    await tester.tap(find.byKey(_rematchKey));
    await tester.pump();
    final List<String> frames = transport.sentRaw
        .skip(sentBefore)
        .where((String raw) => _typeOf(raw) == 'rematch')
        .toList();
    expect(
      frames,
      hasLength(1),
      reason:
          'tapping Play again must send exactly one rematch envelope; '
          'sent since the tap: '
          '${transport.sentRaw.skip(sentBefore).map(_typeOf).toList()} '
          '[$ctx]',
    );
    expect(
      sent('rematch'),
      before + 1,
      reason: 'one more rematch envelope in total [$ctx]',
    );
    expect(
      (_decode(frames.single)['d']! as Map<String, Object?>),
      isEmpty,
      reason: 'rematch carries d == {} (16.1) [$ctx]',
    );
    return _idOf(frames.single);
  }

  Map<String, Object?> _lobby({required int by, required List<int> ready}) =>
      _roomJson(
        state: 'LOBBY',
        seq: seq + 1,
        chainIndex: chainIndex,
        rematch: <String, Object?>{'by': by, 'ready': ready},
      );

  /// The device asks first, the other seat accepts, the server starts the
  /// game itself (16.4). Frames in the server's order.
  Future<void> rematchDeviceAsksFirst() async {
    final String ctx = why('device asks first');
    chainIndex += 1;
    final String id = await tapRematch('tap Play again');
    await pushRoom(
      _lobby(by: me, ready: <int>[me]),
      re: id,
    );
    expect(
      controller.room!.state,
      RoomState.lobby,
      reason: 'a rematch LOBBY after my own rematch was answered [$ctx]',
    );
    expect(
      find.byKey(_rematchWaitingKey),
      findsOneWidget,
      reason: 'after my ask the end card shows the waiting line [$ctx]',
    );
    await pushRoom(_lobby(by: me, ready: <int>[0, 2]));
    await _startBurst();
  }

  /// The other seat asks first; the device sees the ask on the end card
  /// (16.7), taps once, and the server starts the game.
  Future<void> rematchOtherAsksFirst() async {
    final String ctx = why('other seat asks first');
    chainIndex += 1;
    await pushRoom(_lobby(by: other, ready: <int>[other]));
    expect(
      find.byKey(_rematchAskKey),
      findsOneWidget,
      reason:
          'the end card must show "${_names[other]} wants to play again" '
          'when the other seat asks (16.7) [$ctx]',
    );
    expect(
      controller.room!.rematch?.by,
      other,
      reason: 'the controller holds the other seat\'s rematch [$ctx]',
    );
    expectRematchEnabled(ctx);
    final String id = await tapRematch('accept the ask');
    await pushRoom(
      _lobby(by: other, ready: <int>[0, 2]),
      re: id,
    );
    await _startBurst();
  }

  /// seat_seed for each seat (server drawn), game_started, then turn.
  Future<void> _startBurst() async {
    final String ctx = why('start burst');
    game += 1;
    for (final int seat in <int>[_hostSeat, _otherSeat]) {
      await push('seat_seed', <String, Object?>{
        'seat': seat,
        'client_seed': 'srv-seat$seat-game$game',
        'origin': 'server',
      });
    }
    await push('game_started', <String, Object?>{
      'turn': _hostSeat,
      'game_id': _gameId(game),
      'client_seeds': '0:s0|2:s2',
    });
    await turn(_hostSeat);
    final RoomSnapshot room = controller.room!;
    expect(
      room.state,
      RoomState.playing,
      reason:
          'game_started after an accepted rematch must make the room '
          'PLAYING; it is ${room.state} [$ctx]',
    );
    expect(room.gameId, _gameId(game), reason: 'the new game id [$ctx]');
    expect(
      room.chainIndex,
      chainIndex,
      reason: 'the client holds the chain of the new game [$ctx]',
    );
    expect(
      find.byKey(_boardKey),
      findsOneWidget,
      reason: 'the board is shown for the new game [$ctx]',
    );
    for (final Key key in <Key>[_winKey, _loseKey, _endedKey, _rematchKey]) {
      expect(
        find.byKey(key),
        findsNothing,
        reason:
            'no end card control ($key) may survive into the new game '
            '[$ctx]',
      );
    }
  }
}

/// Mounts GameScreen over a room that is already PLAYING game 1.
Future<_Table> _openTable(
  WidgetTester tester, {
  required String scenario,
  required int me,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  addTearDown(controller.dispose);
  final Future<void> future = controller.createRoom(
    name: _names[me]!,
    players: 2,
  );
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': me, 'seat_token': 'tok-$me'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(state: 'PLAYING', seq: 1),
    ),
  );
  await future;
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_harness(GameScreen(controller: controller)));
  await tester.pump();

  final _Table table = _Table(
    tester: tester,
    controller: controller,
    transport: transport,
    scenario: scenario,
    me: me,
  );
  await table.push('game_started', <String, Object?>{
    'turn': _hostSeat,
    'game_id': _gameId(1),
    'client_seeds': '0:s0|2:s2',
  });
  await table.turn(_hostSeat);
  return table;
}

/// Four games with three rematches. [deviceAsks] says, per rematch number
/// (zero based), whether the device asks first or accepts the other seat's
/// ask. [deviceWins] says, per game number (zero based), whether the device
/// wins it.
Future<void> _chain(
  WidgetTester tester, {
  required String scenario,
  required int me,
  required bool Function(int rematch) deviceAsks,
  required bool Function(int game) deviceWins,
}) async {
  final _Table table = await _openTable(tester, scenario: scenario, me: me);
  for (int r = 0; r <= _rematches; r++) {
    final int winner = deviceWins(r) ? me : table.other;
    final int rolls = r + 1;
    await table.playGame(myRolls: rolls, winner: winner);
    table.expectEndCardOffersRematch(winner: winner, at: 'game_over');
    expect(
      find.descendant(
        of: find.byKey(_statRollsKey),
        matching: find.text('$rolls'),
      ),
      findsWidgets,
      reason:
          'the end card counts only this game\'s ($rolls) rolls of the '
          'device seat; frames of earlier games must not leak in '
          '[${table.why('rolls tile')}]',
    );
    if (r == _rematches) {
      break;
    }
    if (deviceAsks(r)) {
      await table.rematchDeviceAsksFirst();
    } else {
      await table.rematchOtherAsksFirst();
    }
    expect(
      table.sent('rematch'),
      r + 1,
      reason: 'one rematch envelope per rematch, no more [${table.why('end')}]',
    );
  }
  expect(
    table.game,
    _rematches + 1,
    reason: 'four games were played [${table.why('end')}]',
  );
  expect(
    table.sent('rematch'),
    _rematches,
    reason:
        'exactly three rematch envelopes went out, one per tap '
        '[${table.why('end')}]',
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'K5 the first rematch starts game 2: the room the client holds is an '
    'ordinary PLAYING room with rematch null (16.4, 16.6)',
    (WidgetTester tester) async {
      final _Table table = await _openTable(
        tester,
        scenario: 'rematch-null-after-start',
        me: _hostSeat,
      );
      await table.playGame(myRolls: 1, winner: _hostSeat);
      await table.rematchDeviceAsksFirst();
      expect(
        table.controller.room!.rematch,
        isNull,
        reason:
            'section 16.4: "`rematch` becomes null again ... from '
            '`game_started` on the room is an ordinary PLAYING room"; '
            'section 16.6: non-null only in a rematch LOBBY. The client '
            'holds state=${table.controller.room!.state} with rematch '
            '${table.controller.room!.rematch?.ready} '
            '[${table.why('after game_started')}]',
      );
    },
  );

  testWidgets(
    'K1 host seat: the device asks first on every rematch, wins and loses '
    'in turn',
    (WidgetTester tester) async {
      await _chain(
        tester,
        scenario: 'device-asks-first-host',
        me: _hostSeat,
        deviceAsks: (int r) => true,
        deviceWins: (int g) => g.isEven,
      );
    },
  );

  testWidgets(
    'K2 host seat: the other seat asks first on every rematch, the device '
    'accepts',
    (WidgetTester tester) async {
      await _chain(
        tester,
        scenario: 'other-asks-first-host',
        me: _hostSeat,
        deviceAsks: (int r) => false,
        deviceWins: (int g) => g.isOdd,
      );
    },
  );

  testWidgets(
    'K3 guest seat: the askers alternate, the device wins and loses in turn',
    (WidgetTester tester) async {
      await _chain(
        tester,
        scenario: 'alternating-guest',
        me: _otherSeat,
        deviceAsks: (int r) => r.isEven,
        deviceWins: (int g) => g.isEven,
      );
    },
  );

  testWidgets('K4 guest seat: the other seat asks first on every rematch', (
    WidgetTester tester,
  ) async {
    await _chain(
      tester,
      scenario: 'other-asks-first-guest',
      me: _otherSeat,
      deviceAsks: (int r) => false,
      deviceWins: (int g) => g.isOdd,
    );
  });
}
