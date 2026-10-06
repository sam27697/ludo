// Conformance tests for work/ludo/orders/C-236-feedback-wiring.md: the game
// actually calling the feedback service the instrument in lib/src/feedback.dart
// (orders 225/226) already builds. Order 236 wires lib/src/app.dart,
// lib/src/game_screen.dart and lib/src/board.dart to this contract in
// parallel, in a tree this file's author has not read; every expectation
// below is read off C-236's own text, never off 236's code.
//
// Every claim about a cue is read off a fake FeedbackService recorded
// through a FeedbackScope -- doctrine 2.1's "a fake haptic/sound service
// that asserts the exact pattern id per game event" -- never off
// HapticFeedback, a platform channel or a sound file. GameScreen is driven
// the same way test/play_surface_die_test.dart drives it: a real
// RoomController sits over a FakeTransport (test/net/fake_transport.dart,
// read-only). The fake-transport idiom (_connectTo, pushText, _settleRoll)
// is copied from that file rather than imported, per this order's own
// instruction never to import across test files.
//
// On integrate/run67-play at 7cb5a7e (this file's base, before order 236):
// GameScreen never subscribes to controller.frames, never calls
// FeedbackScope.of, LudoBoard is never given onIllegalTokenTap, and
// LudoApp builds HomeScreen directly with no FeedbackScope above it. Every
// rule-1-to-4 group below is therefore expected to fail on that base for
// one of two reasons: the fake records nothing where a cue is expected, or
// a key (game-die-no-move-mark, game-no-move-notice, FeedbackScope above
// HomeScreen) is never found -- never a load error, a timeout or a pending
// timer.
//
// Standing lesson from this project's own suite, carried into this file: no
// pumpAndSettle while my seat sits in awaitRoll -- the die pulse repeats
// forever there, and the no-move hold's own timer never settles either.
// Every wait below is a bounded tester.pump(Duration) or a bounded sequence
// of plain tester.pump() calls, a SemanticsHandle (none used here) would be
// disposed in the test body and not only through addTearDown, and every
// roll this file sends is answered before the test body ends. One mount
// per case.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://feedback-wiring-test.invalid/ws';

const Key _dieKey = Key('game-die');
const Key _noMoveMarkKey = Key('game-die-no-move-mark');
const Key _noMoveNoticeKey = Key('game-no-move-notice');
const Key _turnBannerKey = Key('game-screen-turn-banner');

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

// --- server-side id generation for pushed frames ----------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'feedback-wiring-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

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

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

/// Connects a fresh controller and lands it directly on the given [turn]
/// (or a null turn), mySeat always 0. Copied from
/// test/play_surface_die_test.dart's own _connectTo, not imported, per this
/// order's instruction not to import across test files.
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

/// Mounts [controller]'s GameScreen under a FeedbackScope carrying [fake] --
/// the one seam C-236 rule 2 names ("FeedbackScope.of(context).play(cue)").
/// One mount per case, per this order's own acceptance note.
Future<void> _mount(
  WidgetTester tester,
  RoomController controller,
  _FakeFeedbackService fake, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: fake,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
}

/// Connects a fresh controller, mounts GameScreen over a fresh fake service,
/// and hands both plus the transport back -- the one mount this whole file's
/// cases are built from.
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _connectAndMount(
  WidgetTester tester, {
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
  List<Map<String, Object?>>? seats,
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    state: state,
    turn: turn,
    winner: winner,
    seats: seats,
  );
  addTearDown(controller.dispose);
  final _FakeFeedbackService fake = _FakeFeedbackService();
  await _mount(
    tester,
    controller,
    fake,
    locale: locale,
    disableAnimations: disableAnimations,
  );
  return (controller, transport, fake);
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// Records every cue GameScreen asks the service to play, in call order.
/// The vocabulary itself -- id per cue -- is already proven by
/// test/feedback_cues_test.dart and test/feedback_service_test.dart; this
/// fake exists only to prove GameScreen calls `play` at all, for the right
/// frame, in the right order, and never for anything else.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

void main() {
  // ==========================================================================
  // Rule 1: LudoApp puts one FeedbackScope above its first route.
  // ==========================================================================
  group('rule 1: LudoApp wires one FeedbackScope above its first route', () {
    // Catches a LudoApp that never wires a FeedbackScope at all: every
    // screen below it would then silently fall back to NoopFeedbackService
    // and no cue would ever reach a real channel.
    testWidgets(
      'a FeedbackScope sits above HomeScreen once FeedbackSettings.load() '
      'has resolved',
      (tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{});

        await tester.pumpWidget(const LudoApp());
        await tester.pumpAndSettle();

        expect(
          find.byType(HomeScreen),
          findsOneWidget,
          reason:
              'fixture is broken: LudoApp must still reach HomeScreen once '
              'settings have loaded',
        );
        expect(
          find.ancestor(
            of: find.byType(HomeScreen),
            matching: find.byType(FeedbackScope),
          ),
          findsOneWidget,
          reason:
              'C-236 rule 1: LudoApp must put exactly one FeedbackScope '
              'above its first route (HomeScreen) once '
              'FeedbackSettings.load() resolves',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 2: GameScreen plays cuesForFrame's own cues for every game event,
  // synchronously, in list order, and nothing else.
  // ==========================================================================
  group('rule 2: cuesForFrame dispatch, one case per cue', () {
    // Catches playing cues for every seat rather than filtering through
    // cuesForFrame(frame, mySeat: controller.seat): a screen that always
    // fires yourTurn on any `turn` frame, regardless of whose seat it
    // names, would still pass a test that only ever pushes frames for my
    // own seat.
    testWidgets('turn for me gives exactly [your_turn]', (tester) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, turn: null);

      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 2},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.yourTurn]),
        reason:
            'a turn frame naming my own seat must play exactly '
            '[yourTurn]; recorded ${fake.recorded}',
      );
    });

    testWidgets('my rolled with a non-empty legal gives exactly [can_move]', (
      tester,
    ) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, turn: null);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 4,
            'legal': <int>[0, 2],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'a' * 64,
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.canMove]),
        reason:
            'my rolled with a non-empty legal must play exactly '
            '[canMove]; recorded ${fake.recorded}',
      );
    });

    testWidgets('my rolled with an empty legal gives exactly [no_move]', (
      tester,
    ) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, turn: null);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 6,
            'legal': <int>[],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.noMove]),
        reason:
            'my rolled with an empty legal must play exactly [noMove]; the '
            'no-move beat itself (rule 4) is a separate claim; recorded '
            '${fake.recorded}',
      );
    });

    testWidgets(
      'a moved capturing an opponent gives exactly [captured_other] -- '
      'from == to so no step cue (out of scope) muddies the assertion',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, turn: null);

        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 5,
              'to': 5,
              'captured': <Map<String, Object?>>[
                <String, Object?>{'seat': 1, 'token': 0},
              ],
              'extra_roll': false,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.capturedOther]),
          reason:
              'my moved frame carrying a non-empty captured list must play '
              'exactly [capturedOther]; recorded ${fake.recorded}',
        );
      },
    );

    testWidgets(
      "an opponent's moved capturing me gives exactly [captured_me]",
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, turn: null);

        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 1,
              'token': 0,
              'from': 2,
              'to': 5,
              'captured': <Map<String, Object?>>[
                <String, Object?>{'seat': 0, 'token': 0},
              ],
              'extra_roll': false,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.capturedMe]),
          reason:
              'a moved frame for another seat whose captured list names my '
              'seat must play exactly [capturedMe]; recorded '
              '${fake.recorded}',
        );
      },
    );

    testWidgets(
      'my token reaching 57 gives exactly [home] -- from == to == 57 so no '
      'step cue (out of scope) muddies the assertion',
      (tester) async {
        final (_, FakeTransport transport, _FakeFeedbackService fake) =
            await _connectAndMount(tester, turn: null);

        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 57,
              'to': 57,
              'captured': <Object?>[],
              'extra_roll': false,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.home]),
          reason:
              'my moved frame landing a token on 57 must play exactly '
              '[home]; recorded ${fake.recorded}',
        );
      },
    );

    testWidgets('game_over I won gives exactly [win]', (tester) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, turn: null);

      transport.pushText(
        _frame(
          type: 'game_over',
          data: <String, Object?>{
            'winner': 0,
            'verify_url': 'https://feedback-wiring-test.invalid/verify/1',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.win]),
        reason:
            'a game_over naming me as winner must play exactly [win]; '
            'recorded ${fake.recorded}',
      );
    });

    testWidgets('game_over I lost gives exactly [game_over]', (tester) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, turn: null);

      transport.pushText(
        _frame(
          type: 'game_over',
          data: <String, Object?>{
            'winner': 1,
            'verify_url': 'https://feedback-wiring-test.invalid/verify/2',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.gameOver]),
        reason:
            'a game_over naming another seat as winner must play exactly '
            '[gameOver]; recorded ${fake.recorded}',
      );
    });

    // Catches playing cues for every seat: a screen that fires yourTurn,
    // canMove/noMove or capturedOther regardless of whose seat a frame
    // names would still pass every case above (all written for my own
    // seat); only pushing another seat's routine frames and asserting
    // nothing at all was recorded catches that mutation.
    testWidgets("an opponent's routine turn, rolled and moved record nothing", (
      tester,
    ) async {
      final (_, FakeTransport transport, _FakeFeedbackService fake) =
          await _connectAndMount(tester, turn: null);

      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{'seat': 1, 'deadline_ms': 45000, 'seq': 2},
        ),
      );
      await tester.pump();
      await tester.pump();

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 1,
            'value': 3,
            'legal': <int>[0, 1],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'c' * 64,
            'seq': 3,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 1,
            'token': 0,
            'from': -1,
            'to': 3,
            'captured': <Object?>[],
            'extra_roll': false,
            'seq': 4,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        fake.recorded,
        equals(<FeedbackCue>[]),
        reason:
            "another seat's routine turn, rolled and moved must play "
            'nothing at all; recorded ${fake.recorded}',
      );
    });
  });

  // ==========================================================================
  // Rule 3: a tap that cannot do anything still tells the player so.
  // ==========================================================================
  group('rule 3: invalid tap', () {
    // Catches calling HapticFeedback directly instead of the service: the
    // die's tap acknowledgement already calls HapticFeedback.lightImpact()
    // on a rolling tap (rule 5, unchanged, its own test in
    // game_juice_test.dart); a screen that reused that same raw call for an
    // invalid tap, instead of routing through FeedbackScope.of(context),
    // would send nothing to this fake and still "work" on a real device.
    testWidgets(
      'a tap on an illegal token of mine records exactly one invalid_tap '
      'and sends no move',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
          _seatJson(1, name: 'Bob'),
        ];
        final (
          _,
          FakeTransport transport,
          _FakeFeedbackService fake,
        ) = await _connectAndMount(
          tester,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 45000,
            k: 1,
            value: 4,
            legal: const <int>[1],
          ),
        );

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_hitKey(0, 0)));
        await tester.pump();

        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'a tap on an illegal token of mine must send no move; the '
              'wire grew by ${transport.sentRaw.length - sentBefore} '
              'message(s)',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.invalidTap]),
          reason:
              'a tap on an illegal token of mine must record exactly one '
              'invalidTap; recorded ${fake.recorded}',
        );
      },
    );

    testWidgets('a tap on the die when it is not my turn records exactly one '
        'invalid_tap and sends no roll', (tester) async {
      final (
        _,
        FakeTransport transport,
        _FakeFeedbackService fake,
      ) = await _connectAndMount(
        tester,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_dieKey));
      await tester.pump();

      expect(
        transport.sentRaw.length,
        sentBefore,
        reason:
            'a tap on game-die while the turn belongs to another seat '
            'must send no roll; the wire grew by '
            '${transport.sentRaw.length - sentBefore} message(s)',
      );
      expect(
        fake.recorded,
        equals(<FeedbackCue>[FeedbackCue.invalidTap]),
        reason:
            'a tap on game-die while it would not roll must record '
            'exactly one invalidTap; recorded ${fake.recorded}',
      );
    });
  });

  // ==========================================================================
  // Rule 4: the no-move beat -- a red X on the die and a notice, both for
  // the full 1500ms from the rolled that caused them, undisturbed by the
  // next seat's turn arriving in the meantime.
  // ==========================================================================
  group('rule 4: the no-move beat holds 1500ms regardless of what follows', () {
    /// Lands the controller on my own awaitRoll, then pushes my own
    /// empty-legal rolled immediately followed by the next seat's turn --
    /// "at once" per C-236 rule 4 -- and flushes both through the widget
    /// tree. Returns the transport so a case needing more frames still can.
    Future<(RoomController, FakeTransport, _FakeFeedbackService)> landOnNoMove(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
      bool disableAnimations = false,
    }) async {
      final (
        RoomController controller,
        FakeTransport transport,
        _FakeFeedbackService fake,
      ) = await _connectAndMount(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
        locale: locale,
        disableAnimations: disableAnimations,
      );

      final int seqAfterRolled = controller.room!.seq + 1;
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 6,
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
      // Bare, duration-less pumps only flush the microtasks FakeTransport's
      // StreamController schedules and the setState they trigger; none of
      // them advances the fake clock the 1500ms hold's own Timer runs on
      // (standing idiom: one pushed frame needs two pumps, test/
      // game_screen_countdown_test.dart's own comment on the same point).
      await tester.pump();
      await tester.pump();
      await tester.pump();

      return (controller, transport, fake);
    }

    // Catches the notice (and the mark) being cleared the instant the next
    // seat's turn frame lands, rather than held for the full 1500ms from
    // the rolled that caused them: a screen that keyed the hold off
    // "while it is still my turn" instead of its own 1500ms timer would
    // clear both the moment this test's second frame (the next seat's
    // turn) arrives, failing the checks right after the two pushes below,
    // before any pump(Duration) even runs.
    testWidgets(
      'both appear together as soon as the rolled lands, and the next '
      "seat's turn is shown at the same time, not delayed or hidden",
      (tester) async {
        final (RoomController controller, _, _FakeFeedbackService fake) =
            await landOnNoMove(tester);
        final AppLocalizations loc = _locOf(tester);

        expect(
          find.byKey(_noMoveMarkKey),
          findsOneWidget,
          reason:
              'game-die-no-move-mark must appear as soon as my rolled with '
              'an empty legal lands',
        );
        final Text notice = tester.widget<Text>(find.byKey(_noMoveNoticeKey));
        expect(
          notice.data,
          loc.gameNoMove,
          reason:
              'game-no-move-notice must show loc.gameNoMove '
              '("${loc.gameNoMove}"); got "${notice.data}"',
        );
        expect(
          controller.room!.turn!.seat,
          1,
          reason:
              "fixture is broken: the next seat's turn frame must have "
              'landed on RoomController',
        );
        final Text banner = tester.widget<Text>(find.byKey(_turnBannerKey));
        expect(
          banner.data,
          loc.gameWaitingForPlayer('Bob'),
          reason:
              "the next seat's turn must be shown at the same time as the "
              'no-move beat, not delayed or hidden behind it; turn banner '
              'read "${banner.data}"',
        );
        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.noMove]),
          reason:
              "rule 2's noMove cue, not this rule's mark or notice, is the "
              'only cue this scenario should have played; recorded '
              '${fake.recorded}',
        );
      },
    );

    testWidgets('both are still present at 1400ms', (tester) async {
      await landOnNoMove(tester);

      await tester.pump(const Duration(milliseconds: 1400));

      expect(
        find.byKey(_noMoveMarkKey),
        findsOneWidget,
        reason: 'game-die-no-move-mark must not clear before 1500ms',
      );
      expect(
        find.byKey(_noMoveNoticeKey),
        findsOneWidget,
        reason: 'game-no-move-notice must not clear before 1500ms',
      );
    });

    testWidgets('both are gone by 1600ms', (tester) async {
      await landOnNoMove(tester);

      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.byKey(_noMoveMarkKey),
        findsNothing,
        reason: 'game-die-no-move-mark must be gone by 1600ms',
      );
      expect(
        find.byKey(_noMoveNoticeKey),
        findsNothing,
        reason: 'game-no-move-notice must be gone by 1600ms',
      );
    });

    testWidgets('the notice shows the Arabic string under Locale(ar)', (
      tester,
    ) async {
      await landOnNoMove(tester, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      await tester.pump(const Duration(milliseconds: 1400));

      expect(
        find.byKey(_noMoveNoticeKey),
        findsOneWidget,
        reason:
            'game-no-move-notice must be present at 1400ms under Arabic too',
      );
      final Text notice = tester.widget<Text>(find.byKey(_noMoveNoticeKey));
      expect(
        notice.data,
        loc.gameNoMove,
        reason:
            'under Arabic, game-no-move-notice must show loc.gameNoMove '
            '("${loc.gameNoMove}"); got "${notice.data}"',
      );
    });

    // Catches a mark that is only a colour change on the die face rather
    // than a shape (P9): a version like that would have no reason to carry
    // a dedicated game-die-no-move-mark key at all, so this still finds it
    // -- but see this file's header for the limit of what a widget test
    // proves about "an X shape, not only a colour".
    testWidgets(
      'both are still present at 1400ms under reduced motion -- meaning is '
      'kept, only motion shortens',
      (tester) async {
        await landOnNoMove(tester, disableAnimations: true);

        await tester.pump(const Duration(milliseconds: 1400));

        expect(
          find.byKey(_noMoveMarkKey),
          findsOneWidget,
          reason:
              'MediaQuery.disableAnimations must not shorten the 1500ms '
              'hold itself, only the motion inside it',
        );
        expect(find.byKey(_noMoveNoticeKey), findsOneWidget);
      },
    );
  });
}
