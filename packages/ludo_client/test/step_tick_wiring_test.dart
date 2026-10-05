// This file's one case was originally written against
// work/ludo/orders/C-257-seat-wiring.md's own rule 4 and its "What proves
// it" bullet for rule 4, from that contract's text alone. C-257's "RESPEC
// run 72" note withdraws rule 4 from that contract (the master's own error,
// recorded there): wiring LudoBoard.onTokenStep straight to
// FeedbackCue.step on top of lib/src/feedback.dart's existing per-square
// burst in _cuesForMoved would double-fire, so the real fix moves the step
// cue from that frame-level burst to onTokenStep instead, which changes
// C-225's own event map and needs its own contract -- C-259 (the X13
// follow-up), not written yet. This case is held here, unchanged, against
// that contract once it exists; it does not test C-257, which now stands
// at rules 1-3 and 5 only (see test/seat_wiring_test.dart).
//
// GameScreen is mounted the way test/feedback_wiring_test.dart and
// test/play_header_test.dart mount it: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only), under a
// FeedbackScope carrying a fake FeedbackService, since GameScreen._onFrame
// calls FeedbackScope.of(context) for every frame its own subscription sees
// regardless of what cue (if any) that frame carries. The fake-transport
// idiom (_Connector, pushText, the JSON helpers) and the harness are copied
// by hand from those two files' own copies (and from this case's own former
// home, test/seat_wiring_test.dart, before the split below), per their
// shared instruction never to import across test files -- only the helpers
// this one case actually needs came along.
//
// Ambiguity found and not invented around (unchanged from this case's
// original delivery note): the withdrawn rule 4's "What proves it" text
// describes proving the step tick by pushing a real `moved` frame and
// reading the fake feedback service's recorded list afterward. On base
// ac19bb3 (and still true here, since nothing about feedback.dart or
// game_screen.dart has changed), lib/src/feedback.dart's own _cuesForMoved
// already appends one FeedbackCue.step per square travelled for a `moved`
// frame naming my own seat, played synchronously by GameScreen._onFrame
// the instant the frame lands -- entirely independent of LudoBoard
// .onTokenStep, which game_screen.dart never gives a value on this base.
// A case that only reads the final recorded list after pushing such a
// frame would therefore already be green on ac19bb3, for a reason that has
// nothing to do with any onTokenStep wiring. To keep this case red for the
// reason it names, it instead reads LudoBoard.onTokenStep itself off the
// mounted widget (asserting it is non-null, which it is not on this base)
// and then calls that exact function the same way lib/src/board.dart's own
// _onStepElapsed does -- `widget.onTokenStep?.call(move.seat, move.token)`
// -- to prove what it does for my own seat's token and for another seat's,
// without needing the ambiguous _cuesForMoved path to run at all. Whatever
// C-259 turns out to ask, this rig (direct callback probe, not a real
// `moved` frame) is the one way found so far to prove onTokenStep's own
// wiring without that ambiguity; a future contract may describe the step
// tick differently, in which case this case's assertions -- not touched by
// this split -- will need their own, separate review against that text.

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

const String _testUrl = 'wss://step-tick-wiring-test.invalid/ws';

const Key _boardKey = Key('game-screen-board');

// --- server-side id generation for pushed frames, copied by hand from the
// sibling suites' own idiom ---------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'step-tick-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, copied by hand from the sibling suites -----------

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

/// Connects a fresh controller straight to the given room, mySeat always 0
/// (seat_assigned always names seat 0). Copied by hand from the sibling
/// suites' own `_connectTo` / `_connectDirect`.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
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
      data: _roomJson(state: state, seats: seats, turn: turn, winner: winner),
    ),
  );
  await future;
  return (controller, transport);
}

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

/// Records every cue GameScreen asks the service to play, in call order.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Connects a fresh controller and mounts GameScreen over a fresh fake
/// feedback service, and hands all three back -- the one mount this file's
/// case is built from.
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _connectAndMount(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
  Locale locale = const Locale('en'),
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: seats,
    state: state,
    turn: turn,
    winner: winner,
  );
  addTearDown(controller.dispose);
  final _FakeFeedbackService fake = _FakeFeedbackService();
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: fake,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  return (controller, transport, fake);
}

void main() {
  // ==========================================================================
  // The withdrawn C-257 rule 4, held for the C-259 contract (not written yet)
  // that replaces it.
  // ==========================================================================
  group('The step tick (withdrawn from C-257, held for C-259)', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[3, -1, -1, -1]),
      _seatJson(1, name: 'Bob', tokens: const <int>[10, -1, -1, -1]),
    ];

    // Kills: LudoBoard.onTokenStep never given a value at all (ac19bb3's own
    // state -- see this file's header for why a case that only reads the
    // fake service's recorded list after a real `moved` frame would not be
    // red on this base for the reason this rule names); a step of my own
    // token playing no cue, or any cue other than exactly one
    // FeedbackCue.step; and a step of another seat's token playing anything
    // at all.
    testWidgets(
      'LudoBoard.onTokenStep plays exactly one FeedbackCue.step for a step '
      'of my own token, and nothing for a step of another seat\'s',
      (tester) async {
        final (_, _, _FakeFeedbackService fake) = await _connectAndMount(
          tester,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );

        final LudoBoard board = tester.widget<LudoBoard>(find.byKey(_boardKey));
        expect(
          board.onTokenStep,
          isNotNull,
          reason:
              'the playing LudoBoard\'s onTokenStep must be wired so a step '
              'of my own token plays FeedbackCue.step; game_screen.dart '
              'currently passes none on this base (board.onTokenStep is '
              'null)',
        );

        fake.recorded.clear();
        board.onTokenStep!(0, 0);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.step]),
          reason:
              'a step of my own seat\'s (0) token must play exactly one '
              'FeedbackCue.step through FeedbackScope.of(context); recorded '
              '${fake.recorded}',
        );

        fake.recorded.clear();
        board.onTokenStep!(1, 0);
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'a step of another seat\'s (1) token must play nothing; '
              'recorded ${fake.recorded}',
        );
      },
    );
  });
}
