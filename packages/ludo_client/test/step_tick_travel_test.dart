// Conformance tests for work/ludo/orders/C-259-step-tick.md rule 2 and its
// own "What proves it" bullet 3: a real `moved` frame landing over a
// mounted GameScreen, read off a recording fake FeedbackService with no
// throttle of its own, proves the step tick now follows the drawn token
// square by square instead of firing as one burst the instant the frame
// lands. Written from C-259's own text and its "Measured on caf4142"
// section (which names and quotes lib/src/board.dart's _onStepElapsed and
// onTokenStep, and lib/src/feedback.dart's old per-square burst in
// _cuesForMoved) -- not by reading lib/ beyond what that section already
// states, and lib/ is not touched by this file or by order 260.
//
// GameScreen is mounted exactly the way test/step_tick_wiring_test.dart
// mounts it: a real RoomController over a FakeTransport
// (test/net/fake_transport.dart, read-only), under a FeedbackScope carrying
// a fake FeedbackService that records every play call with no throttle of
// its own (PlatformFeedbackService's own 60ms step gate, rule 3's "one
// throttle", is a different class and plays no part here). The
// fake-transport idiom and the harness are copied by hand from that file,
// per this project's standing instruction never to import across test
// files.
//
// Lesson 35: one mount per case, four separate testWidgets blocks below.
// Lesson 36, and the standing rule against pumpAndSettle while a live
// countdown runs: every wait is either the two-pump idiom the sibling
// suites use to flush a pushed frame (test/feedback_wiring_test.dart's own
// pattern) or a bounded loop of tester.pump(kTokenStepDuration), one call
// per square, never one long pump and never pumpAndSettle. Every room below
// is connected with turn: null -- _reduceMoved does not require a current
// turn, nothing here exercises the countdown, and turn: null means
// GameScreen arms no countdown Timer at all, so there is nothing of that
// kind for a bounded pump to race against.
//
// Ambiguity found and not invented around: C-259's own "what proves it"
// text for the capture case names only the final counts ("a capture by me
// records capturedOther exactly once" alongside "exactly 6 step"), without
// restating case (a)'s full "no step before travel" timing check for it.
// Rule 4 keeps capturedOther firing the instant the frame lands, unchanged
// by this contract (moving it to the landing is X20, out of scope here), so
// this file's capture case also checks that capturedOther arrives
// immediately and that no step cue arrives before the board's own steps
// start ticking -- the same timing shape case (a) uses -- so the capture
// case is red on caf4142 for the burst C-259 names, not only for a count
// that would happen to match again once the whole travel is finished.

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

const String _testUrl = 'wss://step-tick-travel-test.invalid/ws';

// --- server-side id generation for pushed frames, copied by hand from the
// sibling suites' own idiom ---------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'step-tick-travel-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
      // turn: null throughout this file -- see the header note on why.
      data: _roomJson(seats: seats, turn: null),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child) {
  return MaterialApp(
    locale: const Locale('en'),
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

/// Records every cue GameScreen asks the service to play, in call order,
/// with no throttle of its own -- PlatformFeedbackService's own 60ms step
/// gate (C-259 rule 3's "one throttle") plays no part in this file.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Connects a fresh controller and mounts GameScreen over a fresh fake
/// feedback service, and hands all three back -- the one mount each case
/// below is built from (lesson 35).
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _connectAndMount(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: seats,
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
    ),
  );
  await tester.pump();
  return (controller, transport, fake);
}

/// Pushes a `moved` frame and flushes it through the two-pump idiom the
/// sibling suites use (test/feedback_wiring_test.dart's own pattern): one
/// for the transport's own delivery, one for the controller's frame stream
/// and its listeners to run. Never a pump(Duration) here -- that is
/// reserved for driving the board's own step timers afterward, one square
/// at a time.
Future<void> _pushMovedAndSettle(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  int seq = 2,
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
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pumps [squares] bounded ticks of exactly [kTokenStepDuration] each,
/// never one long pump (lesson 36) -- one call per square the board's own
/// step timer is expected to cross.
Future<void> _pumpSquares(WidgetTester tester, int squares) async {
  for (var i = 0; i < squares; i++) {
    await tester.pump(kTokenStepDuration);
  }
}

void main() {
  final List<Map<String, Object?>> seats = <Map<String, Object?>>[
    _seatJson(0, name: 'Sam', tokens: const <int>[3, -1, -1, -1]),
    _seatJson(1, name: 'Bob', tokens: const <int>[3, -1, -1, -1]),
  ];

  group('C-259 rule 2: the step tick follows the token', () {
    testWidgets('(a) my own moved frame, 3 to 9: no step after the first pump, '
        'fewer than 6 mid-travel, exactly 6 once travel is done', (
      tester,
    ) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, seats: seats);

      await _pushMovedAndSettle(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: 3,
        to: 9,
      );

      expect(
        fake.recorded,
        isEmpty,
        reason:
            'C-259 rule 1: the moved frame itself must play no step cue '
            'the instant it lands; on caf4142, lib/src/feedback.dart\'s '
            'old _cuesForMoved still fires all 6 as one burst right here, '
            'before the drawn token has moved at all; recorded '
            '${fake.recorded}',
      );

      await _pumpSquares(tester, 3);
      expect(
        fake.recorded,
        equals(List<FeedbackCue>.filled(3, FeedbackCue.step)),
        reason:
            'after 3 of the 6 squares\' worth of travel time, exactly 3 '
            'step cues must be recorded, no earlier than their own '
            'square\'s arrival (C-259 rule 2); got ${fake.recorded}. Fewer '
            'than the eventual 6 here is what proves the ticks follow the '
            'token rather than arriving as one burst at the start.',
      );

      await _pumpSquares(tester, 3);
      expect(
        fake.recorded,
        equals(List<FeedbackCue>.filled(6, FeedbackCue.step)),
        reason:
            'once all 6 squares of the travel (3 to 9) have arrived, '
            'exactly 6 step cues must be recorded in total, one per '
            'square; got ${fake.recorded}',
      );
    });

    testWidgets(
      "(b) the opponent's moved frame, 3 to 9: no step at all, before or "
      'after travel -- the control, green on both caf4142 and the fixed '
      'branch',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMovedAndSettle(
          tester,
          transport,
          seat: 1,
          token: 0,
          from: 3,
          to: 9,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'another seat\'s routine move must play nothing the instant '
              'the frame lands, doctrine section 3\'s "never fire haptics '
              'for other players\' routine moves"; recorded '
              '${fake.recorded}',
        );

        await _pumpSquares(tester, 6);
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'by the time the opponent\'s token has finished travelling '
              'from 3 to 9, nothing must have been recorded at all -- not '
              'one step cue, from this seat\'s own token or the board\'s '
              'own stepping; recorded ${fake.recorded}',
        );
      },
    );

    testWidgets(
      '(c) my moved frame with a capture: capturedOther is not recorded in '
      'the first pump, and is recorded exactly once after the sixth step '
      '(C-268 rule 4a)',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMovedAndSettle(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 3,
          to: 9,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
        );

        expect(
          fake.recorded,
          isEmpty,
          reason:
              'C-268 rule 3 holds capturedOther behind the mover\'s own '
              'landing instead of playing it the instant the frame lands; '
              'rule 1 already keeps no step cue firing here either. On '
              'caf4142 and on 30c77ba alike, the old _cuesForMoved fires '
              'capturedOther (and, pre-259, six step cues) all at this same '
              'instant; recorded ${fake.recorded}',
        );

        await _pumpSquares(tester, 6);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.capturedOther,
          ]),
          reason:
              'once the whole 6-square travel has played out, exactly 6 '
              'step cues (fired one per square as the board\'s own '
              'onTokenStep arrives) and capturedOther (held until the '
              'board\'s onMoveLanded fires after the sixth step, C-268 '
              'rule 4a) must both be recorded, capturedOther exactly once '
              'and last; got ${fake.recorded}',
        );
      },
    );

    testWidgets(
      '(d) my moved frame leaving the yard, -1 to 0: no step after the '
      'first pump, exactly one step once the single-square travel is done',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, seats: seats);

        await _pushMovedAndSettle(
          tester,
          transport,
          seat: 0,
          token: 1,
          from: -1,
          to: 0,
        );

        expect(
          fake.recorded,
          isEmpty,
          reason:
              'yard exit is still a moved frame of my own seat: C-259 rule '
              '1 means it plays no step cue the instant it lands either. On '
              'caf4142, the old _cuesForMoved\'s "1 when from == -1" '
              'special case fires that one step cue right here instead; '
              'recorded ${fake.recorded}',
        );

        await _pumpSquares(tester, 1);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.step]),
          reason:
              'once the single square of a yard exit has arrived, exactly '
              'one step cue must be recorded; got ${fake.recorded}',
        );
      },
    );
  });
}
