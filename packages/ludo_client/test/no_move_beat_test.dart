// Conformance tests for work/ludo/orders/C-236-feedback-wiring.md's run 69
// amendment, rules 4a and 4b -- the RETURN of PR #87. Order 236r1 implements
// the amendment in lib/src/game_screen.dart in a parallel tree this file's
// author has not seen; every expectation below is read off the contract
// text alone, never off that tree's code.
//
// GameScreen is mounted exactly as test/feedback_wiring_test.dart mounts it:
// a real RoomController over a FakeTransport (test/net/fake_transport.dart,
// read-only), a FeedbackScope carrying a fake FeedbackService above it. The
// fake-transport idiom (_connectTo, pushText) and the harness are copied by
// hand from that file, per this order's own instruction never to import
// across test files.
//
// On the base `241afae` (before order 236r1), GameScreen's die face is
// `turn?.value`: the next seat's `turn` frame carries no `value`, so once
// it lands the die's face key disappears even though the no-move mark and
// notice are still held by their own 1500ms timer (rule 4a's defect). The
// board sits in a Column with the no-move notice as a sibling `Text` next
// to an `Expanded(LudoBoard)`: the notice appearing or disappearing changes
// how much height is left for the board, so `game-screen-board`'s rect
// moves whenever `_noMoveVisible` flips (rule 4b's defect). Every case
// below is therefore expected to fail on `241afae` for one of those two
// reasons, never a load error, a timeout, or a pending timer.
//
// Standing lesson carried into this file from feedback_wiring_test.dart's
// own header: no pumpAndSettle while my seat sits in awaitRoll or while the
// no-move hold's timer is running -- every wait below is a bounded
// tester.pump(Duration) or a bounded sequence of plain tester.pump() calls.
// One connect-and-mount per case.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://no-move-beat-test.invalid/ws';

const Key _noMoveMarkKey = Key('game-die-no-move-mark');
const Key _noMoveNoticeKey = Key('game-no-move-notice');
const Key _turnBannerKey = Key('game-screen-turn-banner');
const Key _boardKey = Key('game-screen-board');

Key _faceKey(int value) => Key('game-die-face-$value');

// --- server-side id generation for pushed frames ----------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'no-move-beat-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
/// (or a null turn), mySeat always 0. Copied by hand from
/// test/feedback_wiring_test.dart's own `_connectTo`, which itself says it
/// was copied by hand from test/play_surface_die_test.dart, per this
/// order's instruction never to import across test files.
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

/// Records every cue GameScreen asks the service to play. This file never
/// asserts on it directly (test/feedback_wiring_test.dart already proves
/// rule 2's cue vocabulary); it exists only because mounting GameScreen
/// needs a FeedbackScope at all, per the same seam that file mounts through.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// Mounts [controller]'s GameScreen under a FeedbackScope carrying [fake].
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
/// and hands both plus the transport back -- the one connect-and-mount this
/// whole file's cases are built from.
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

/// Sets the test surface and queues its own reset, the same pattern
/// test/game_screen_signature_chrome_test.dart uses for its 360x600 case.
void _setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Lands the controller on my own (seat 0) awaitRoll, then pushes my own
/// empty-legal rolled (face [faceValue]) immediately followed by the next
/// seat's turn -- "at once", same pump, per C-236 rule 4 and its run 69
/// amendment 4a. Mirrors test/feedback_wiring_test.dart's own
/// `landOnNoMove`, copied by hand rather than imported, with the face value
/// parameterised since rule 4a is specifically about which face the die
/// keeps showing.
Future<(RoomController, FakeTransport, _FakeFeedbackService)> _landOnNoMove(
  WidgetTester tester, {
  int faceValue = 3,
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
  // One literal `rolled` frame, as the order's acceptance item 3 asks for:
  // {"v":1,"t":"rolled","id":"...","d":{"seat":0,"value":3,"legal":[],
  //  "deadline_ms":45000,"k":1,"reveal":"d...d","seq":N}}
  transport.pushText(
    _frame(
      type: 'rolled',
      data: <String, Object?>{
        'seat': 0,
        'value': faceValue,
        'legal': <int>[],
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'd' * 64,
        'seq': seqAfterRolled,
      },
    ),
  );
  // One literal `turn` frame, as the order's acceptance item 3 asks for:
  // {"v":1,"t":"turn","id":"...","d":{"seat":1,"deadline_ms":45000,"seq":N}}
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
  // StreamController schedules and the setState they trigger; none of them
  // advances the fake clock the 1500ms hold's own Timer runs on (standing
  // idiom: one pushed frame needs two pumps, test/game_screen_countdown_
  // test.dart's own comment on the same point).
  await tester.pump();
  await tester.pump();
  await tester.pump();

  return (controller, transport, fake);
}

void main() {
  // ==========================================================================
  // Rule 4a: the die keeps showing the face that armed the hold, in my seat
  // colour, with the red X over it, for the whole 1500ms, even though the
  // next seat's turn has already cleared turn.value; the banner and
  // countdown still show the next seat's turn at the same time.
  // ==========================================================================
  group('rule 4a: the face that produced no move is held', () {
    // Kills: the die's face is read as `turn?.value` rather than the frozen
    // face the hold itself armed with; the next seat's `turn` frame carries
    // no `value`, so on the base the face key is gone the instant that
    // frame lands even though the mark and notice are still up.
    testWidgets(
      'my rolled(3, []) then at once seat 1\'s turn: face-3, the no-move '
      'mark and the notice all show together, and the banner already '
      'names seat 1\'s turn; by 1600ms the mark and notice are gone',
      (tester) async {
        final (RoomController controller, _, _) = await _landOnNoMove(
          tester,
          faceValue: 3,
        );
        final AppLocalizations loc = _locOf(tester);

        expect(
          controller.room!.turn!.seat,
          1,
          reason:
              'fixture is broken: the next seat\'s turn frame must have '
              'landed on RoomController before this check runs',
        );
        expect(
          find.byKey(_faceKey(3)),
          findsOneWidget,
          reason:
              'rule 4a: game-die-face-3 must still show during the hold '
              'even though seat 1\'s turn has already cleared turn.value',
        );
        expect(
          find.byKey(_noMoveMarkKey),
          findsOneWidget,
          reason:
              'game-die-no-move-mark must show together with the held '
              'face',
        );
        expect(
          find.byKey(_noMoveNoticeKey),
          findsOneWidget,
          reason:
              'game-no-move-notice must show together with the held '
              'face and mark',
        );
        final Text banner = tester.widget<Text>(find.byKey(_turnBannerKey));
        expect(
          banner.data,
          loc.gameWaitingForPlayer('Bob'),
          reason:
              'the banner must already name seat 1\'s turn -- exactly what '
              'it would show for that same turn frame with no no-move '
              'before it (feedback_wiring_test.dart\'s own rule-4 case '
              'proves that string for an undisturbed seat-1 turn); banner '
              'read "${banner.data}"',
        );

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
      },
    );

    // Kills: the hold watches only my own seat's next `rolled` to end
    // early, not any seat's, so a newer roll for another seat would leave
    // the stale mark on a die that must, per 4a, now show that other
    // seat's real roll instead.
    testWidgets(
      'a rolled(5, ...) for seat 1 landing within the hold clears the '
      'no-move mark and notice at once and shows face-5',
      (tester) async {
        final (RoomController controller, FakeTransport transport, _) =
            await _landOnNoMove(tester, faceValue: 3);

        expect(
          find.byKey(_noMoveMarkKey),
          findsOneWidget,
          reason:
              'fixture is broken: the hold must still be up before the '
              'seat-1 rolled lands',
        );

        final int seqAfterSeat1Roll = controller.room!.seq + 1;
        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 1,
              'value': 5,
              'legal': <int>[0],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'e' * 64,
              'seq': seqAfterSeat1Roll,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(_noMoveMarkKey),
          findsNothing,
          reason:
              'rule 4a: a newer rolled for any seat, not only mine, must '
              'end the hold at once; game-die-no-move-mark is still shown',
        );
        expect(
          find.byKey(_noMoveNoticeKey),
          findsNothing,
          reason:
              'rule 4a: the hold ending early clears the notice together '
              'with the mark; game-no-move-notice is still shown',
        );
        expect(
          find.byKey(_faceKey(5)),
          findsOneWidget,
          reason:
              'the die is shared and must show seat 1\'s real roll (face '
              '5) once it lands, not the stale held face 3',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 4b: the board's rect never moves for the notice, before, during or
  // after the hold, in either locale, at either surface size.
  // ==========================================================================
  group('rule 4b: game-screen-board never moves for the no-move notice', () {
    // Kills: the no-move notice sits as a plain sibling Text inside the
    // same Column as Expanded(LudoBoard) instead of reserving its space (or
    // overlaying without taking any); appearing and disappearing then
    // changes how much height Expanded hands the board, moving
    // game-screen-board's rect during and after the hold.
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final Size surface in const <Size>[Size(390, 844), Size(360, 800)]) {
        testWidgets(
          'game-screen-board rect is identical before, during and after '
          'the hold (${locale.languageCode}, '
          '${surface.width.toInt()}x${surface.height.toInt()})',
          (tester) async {
            _setSurface(tester, surface);

            final (
              RoomController controller,
              FakeTransport transport,
              _,
            ) = await _connectAndMount(
              tester,
              turn: _turnJson(
                seat: 0,
                phase: 'await_roll',
                deadlineMs: 45000,
                k: 0,
              ),
              locale: locale,
            );

            final Rect before = tester.getRect(find.byKey(_boardKey));

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
            await tester.pump();
            await tester.pump();

            expect(
              find.byKey(_noMoveNoticeKey),
              findsOneWidget,
              reason:
                  'fixture is broken: the notice must be up before the '
                  'during-the-hold rect is read '
                  '(${locale.languageCode}, ${surface.width.toInt()}x'
                  '${surface.height.toInt()})',
            );
            final Rect during = tester.getRect(find.byKey(_boardKey));

            await tester.pump(const Duration(milliseconds: 1400));
            await tester.pump(const Duration(milliseconds: 200));

            expect(
              find.byKey(_noMoveNoticeKey),
              findsNothing,
              reason:
                  'fixture is broken: the notice must be gone before the '
                  'after-the-hold rect is read '
                  '(${locale.languageCode}, ${surface.width.toInt()}x'
                  '${surface.height.toInt()})',
            );
            final Rect after = tester.getRect(find.byKey(_boardKey));

            expect(
              during,
              before,
              reason:
                  'rule 4b: game-screen-board must not move once the '
                  'no-move notice appears; before=$before during=$during '
                  '(${locale.languageCode}, ${surface.width.toInt()}x'
                  '${surface.height.toInt()})',
            );
            expect(
              after,
              before,
              reason:
                  'rule 4b: game-screen-board must return to exactly its '
                  'earlier rect once the no-move notice is gone; '
                  'before=$before after=$after '
                  '(${locale.languageCode}, ${surface.width.toInt()}x'
                  '${surface.height.toInt()})',
            );
          },
        );
      }
    }
  });

  // ==========================================================================
  // Reduced motion: the hold still lasts the full 1500ms, the amendment's
  // held face included, under MediaQuery(disableAnimations: true).
  // ==========================================================================
  group('reduced motion: 4a\'s held face still lasts the full 1500ms', () {
    // Kills: the hold's own 1500ms Duration is itself shortened or skipped
    // under MediaQuery.disableAnimations instead of only the motion inside
    // it shortening (P9); this would clear the held face, mark and notice
    // before 1400ms under reduced motion even though they must still be up
    // at that point.
    testWidgets(
      'face-3, the no-move mark and the notice are all still present at '
      '1400ms under MediaQuery(disableAnimations: true)',
      (tester) async {
        await _landOnNoMove(tester, faceValue: 3, disableAnimations: true);

        expect(
          find.byKey(_faceKey(3)),
          findsOneWidget,
          reason:
              'game-die-face-3 must show at once under reduced motion, '
              'same as without it',
        );
        expect(find.byKey(_noMoveMarkKey), findsOneWidget);
        expect(find.byKey(_noMoveNoticeKey), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 1400));

        expect(
          find.byKey(_faceKey(3)),
          findsOneWidget,
          reason:
              'MediaQuery.disableAnimations must not shorten the 1500ms '
              'hold itself (P9: meaning is kept, only motion shortens); '
              'game-die-face-3 was gone before 1400ms',
        );
        expect(
          find.byKey(_noMoveMarkKey),
          findsOneWidget,
          reason:
              'MediaQuery.disableAnimations must not shorten the 1500ms '
              'hold itself; game-die-no-move-mark was gone before 1400ms',
        );
        expect(
          find.byKey(_noMoveNoticeKey),
          findsOneWidget,
          reason:
              'MediaQuery.disableAnimations must not shorten the 1500ms '
              'hold itself; game-no-move-notice was gone before 1400ms',
        );
      },
    );
  });
}
