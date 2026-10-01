// Conformance tests for the die on GameScreen's new play surface, written
// from work/ludo/orders/C-223-play-surface.md (the master, run 65) alone.
// Order 223 (lib/src/game_screen.dart, lib/src/board.dart) is being built in
// parallel by a different worker; this file was written without opening
// either of those files' new content, so it is expected to fail to compile
// or run red against a branch that still carries the old Roll button
// (`game-screen-roll-button`) and no `game-die`.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real RoomController sits over a FakeTransport
// (test/net/fake_transport.dart, read-only, not edited here). Every claim
// about the state the screen is rendering is reached by decoding a wire
// reply into a real RoomSnapshot through RoomController's own request path,
// never by constructing a RoomSnapshot by hand. Every claim about what the
// screen sent is checked by decoding FakeTransport.sentRaw.
//
// Standing lesson from this project's own suite (carried into this file):
// no pumpAndSettle while my seat sits in awaitRoll -- the contract states the
// die pulse repeats forever there, and a repeating pulse (or the tumble)
// never lets pumpAndSettle return. Every wait below is a bounded
// tester.pump(Duration) or a bounded sequence of them.
//
// Two readings the contract text does not pin down on its own, resolved
// here and reported to the master rather than guessed silently:
//
//   1. "At any other time a tap on the die sends nothing" is read to include
//      a finished room. The keys table marks `game-die` present only when
//      "playing body shown", so a finished room's game-over body is read as
//      never building `game-die` at all -- there is nothing there to tap.
//      This file asserts the key's absence in that state rather than tapping
//      a key that should not exist; a version of game_screen.dart that kept
//      `game-die` mounted, disabled, in the finished body would still pass
//      the keys-table letter of the contract only if a tap on it sent
//      nothing, which is not tested here because the key table says the
//      control should not be there at all.
//   2. After the 4-second no-answer stop, the contract says the die is
//      "tappable again only if it is still my turn in awaitRoll". Since
//      nothing in this scenario changed the turn (no `rolled` ever arrived),
//      awaitRoll is still current, so this file expects a second tap to send
//      a second `roll`.

import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://play-surface-die-test.invalid/ws';
const Key _dieKey = Key('game-die');
const Key _pulseKey = Key('game-die-pulse');
const Key _tumblingKey = Key('game-die-tumbling');
const Key _noAnswerKey = Key('game-die-no-answer');

Key _faceKey(int value) => Key('game-die-face-$value');
const Key _blankKey = Key('game-die-blank');

// --- server-side id generation for pushed frames ----------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'die-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
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
/// (or a null turn / finished room), mySeat always 0. A fresh connection
/// per case, the idiom test/game_screen_test.dart's own H3/H4 groups use, so
/// no state (a pending roll timer, an armed hold) ever bleeds between cases.
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

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: controller),
      locale: locale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

List<String> _sentTypesSince(FakeTransport transport, int sentBefore) =>
    transport.sentRaw.skip(sentBefore).map(_typeOf).toList();

void main() {
  // ==========================================================================
  // Roll intent: exactly one roll per tap, nothing out of turn.
  // ==========================================================================
  group('roll intent', () {
    testWidgets(
      'one tap in my awaitRoll sends exactly one roll, with an empty body',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_dieKey));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(
          newMessages,
          hasLength(1),
          reason:
              'one tap on game-die in awaitRoll must put exactly one '
              'message on the wire; got ${newMessages.length} '
              '(types: ${_sentTypesSince(transport, sentBefore)})',
        );
        expect(_typeOf(newMessages.single), 'roll');
        expect(
          _dataOf(newMessages.single),
          <String, Object?>{},
          reason: "docs/PROTOCOL.md 4: roll's body is {}",
        );
      },
    );

    testWidgets(
      'a second tap during the tumble, before a result arrives, sends '
      'nothing further',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        final int sentAfterFirstTap = transport.sentRaw.length;
        expect(
          transport.sentRaw.where((s) => _typeOf(s) == 'roll'),
          hasLength(1),
          reason: 'fixture is broken: the first tap must have sent one roll',
        );

        await tester.tap(find.byKey(_dieKey));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          transport.sentRaw.length,
          sentAfterFirstTap,
          reason:
              'tapping game-die again while the tumble is still running, '
              'before rolled or the 4s stop, must send nothing; the wire '
              'grew by '
              '${transport.sentRaw.length - sentAfterFirstTap} message(s)',
        );
      },
    );

    testWidgets('a tap when it is not my turn sends nothing', (tester) async {
      final (controller, transport) = await _connectTo(
        tester,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_dieKey));
      await tester.pump();

      expect(
        transport.sentRaw.length,
        sentBefore,
        reason:
            'a tap on game-die while the turn belongs to another seat must '
            'send nothing; the wire grew by '
            '${transport.sentRaw.length - sentBefore} message(s)',
      );
    });

    testWidgets('a tap while my own turn is awaitMove sends nothing', (
      tester,
    ) async {
      final (controller, transport) = await _connectTo(
        tester,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 4,
          legal: const <int>[0, 1],
        ),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_dieKey));
      await tester.pump();

      expect(
        transport.sentRaw.length,
        sentBefore,
        reason:
            'a tap on game-die during my own awaitMove must send nothing; '
            'the wire grew by '
            '${transport.sentRaw.length - sentBefore} message(s)',
      );
    });

    testWidgets(
      'a finished room builds no game-die at all -- see this file\'s header '
      'comment, ambiguity 1: nothing there for a tap to reach',
      (tester) async {
        final (controller, _) = await _connectTo(
          tester,
          state: 'FINISHED',
          turn: _turnJson(seat: 0, phase: 'finished', deadlineMs: 0, k: 5),
          winner: 0,
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        expect(
          find.byKey(_dieKey),
          findsNothing,
          reason:
              'a finished room must build no game-die; the keys table marks '
              'it present only when the playing body is shown',
        );
      },
    );
  });

  // ==========================================================================
  // game-die-pulse: my awaitRoll only.
  // ==========================================================================
  group('game-die-pulse', () {
    testWidgets('present in my awaitRoll', (tester) async {
      final (controller, _) = await _connectTo(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      expect(
        find.byKey(_pulseKey),
        findsOneWidget,
        reason: 'game-die-pulse must be present while it is my awaitRoll',
      );
    });

    testWidgets('absent during my own awaitMove', (tester) async {
      final (controller, _) = await _connectTo(
        tester,
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          deadlineMs: 45000,
          k: 1,
          value: 3,
          legal: const <int>[0],
        ),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      expect(find.byKey(_pulseKey), findsNothing);
    });

    testWidgets('absent when it is not my turn', (tester) async {
      final (controller, _) = await _connectTo(
        tester,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      expect(find.byKey(_pulseKey), findsNothing);
    });

    testWidgets('absent under reduced motion, even in my own awaitRoll', (
      tester,
    ) async {
      final (controller, _) = await _connectTo(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller, disableAnimations: true);

      expect(
        find.byKey(_pulseKey),
        findsNothing,
        reason:
            'MediaQuery.disableAnimations true must remove the pulse; '
            'the die itself must still be present',
      );
      expect(find.byKey(_dieKey), findsOneWidget);
    });
  });

  // ==========================================================================
  // The tumble: starts on tap, ends only on a fresh turn.value for my seat.
  // ==========================================================================
  group('the tumble', () {
    testWidgets(
      'before any tap, with no turn.value known yet, game-die-blank shows '
      'and no game-die-face-N is present',
      (tester) async {
        final (controller, _) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        expect(
          find.byKey(_blankKey),
          findsOneWidget,
          reason:
              'with no face known yet, game-die-blank must be shown before '
              'any tap',
        );
        for (int value = 1; value <= 6; value++) {
          expect(find.byKey(_faceKey(value)), findsNothing);
        }
      },
    );

    testWidgets(
      'starts right after the tap and is still there while no result has '
      'arrived',
      (tester) async {
        final (controller, _) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        expect(find.byKey(_tumblingKey), findsNothing);
        await tester.tap(find.byKey(_dieKey));
        await tester.pump();

        expect(
          find.byKey(_tumblingKey),
          findsOneWidget,
          reason: 'game-die-tumbling must appear right after the rolling tap',
        );

        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.byKey(_tumblingKey),
          findsOneWidget,
          reason:
              'with no rolled reply yet and under 4s elapsed, the tumble '
              'must still be running',
        );
      },
    );

    testWidgets(
      'ends and shows game-die-face-<value> once a rolled frame carries a '
      'new turn.value for my seat (a higher k)',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        final String rollId = _idOf(
          transport.sentRaw.singleWhere((s) => _typeOf(s) == 'roll'),
        );

        transport.pushText(
          _frame(
            type: 'rolled',
            re: rollId,
            data: <String, Object?>{
              'seat': 0,
              'value': 5,
              'legal': <int>[0, 1],
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
          find.byKey(_tumblingKey),
          findsNothing,
          reason:
              'game-die-tumbling must be gone once the rolled frame with a '
              'higher k landed',
        );
        expect(
          find.byKey(_faceKey(5)),
          findsOneWidget,
          reason:
              'the die must rest showing game-die-face-5, the exact wire '
              'value; got faces present: '
              '${[for (int v = 1; v <= 6; v++)
                if (find.byKey(_faceKey(v)).evaluate().isNotEmpty) v]}',
        );
      },
    );

    testWidgets(
      'no face is shown before a result arrives -- game-die-blank or no '
      'face key at all, never an invented face',
      (tester) async {
        final (controller, _) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        for (int value = 1; value <= 6; value++) {
          expect(
            find.byKey(_faceKey(value)),
            findsNothing,
            reason:
                'game-die-face-$value must not appear while the tumble is '
                'purely cosmetic and no result has landed',
          );
        }
      },
    );
  });

  // ==========================================================================
  // The 4s no-answer stop.
  // ==========================================================================
  group('the 4s no-answer stop', () {
    testWidgets(
      'with no rolled reply, game-die-no-answer appears at 4s carrying '
      'loc.gameRollNoAnswer, and the tumble is gone; not yet at 3999ms',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final AppLocalizations loc = _locOf(tester);

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        expect(
          transport.sentRaw.where((s) => _typeOf(s) == 'roll'),
          hasLength(1),
          reason: 'fixture is broken: the tap must have sent one roll',
        );

        await tester.pump(const Duration(milliseconds: 3999));
        expect(
          find.byKey(_noAnswerKey),
          findsNothing,
          reason: 'game-die-no-answer must not appear before 4s elapse',
        );
        expect(find.byKey(_tumblingKey), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 1));
        expect(
          find.byKey(_noAnswerKey),
          findsOneWidget,
          reason: 'game-die-no-answer must appear once 4s have elapsed',
        );
        expect(
          find.byKey(_tumblingKey),
          findsNothing,
          reason: 'the tumble must stop once the 4s no-answer line appears',
        );
        final Text noAnswerText = tester.widget<Text>(find.byKey(_noAnswerKey));
        expect(
          noAnswerText.data,
          loc.gameRollNoAnswer,
          reason:
              'game-die-no-answer must show loc.gameRollNoAnswer '
              '("${loc.gameRollNoAnswer}"); got "${noAnswerText.data}"',
        );
      },
    );

    testWidgets('shows loc.gameRollNoAnswer under Arabic too', (tester) async {
      final (controller, transport) = await _connectTo(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      await tester.tap(find.byKey(_dieKey));
      await tester.pump();
      expect(
        transport.sentRaw.where((s) => _typeOf(s) == 'roll'),
        hasLength(1),
      );

      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(_noAnswerKey), findsOneWidget);
      final Text noAnswerText = tester.widget<Text>(find.byKey(_noAnswerKey));
      expect(
        noAnswerText.data,
        loc.gameRollNoAnswer,
        reason:
            'game-die-no-answer under Arabic must show loc.gameRollNoAnswer '
            '("${loc.gameRollNoAnswer}"); got "${noAnswerText.data}"',
      );
    });

    testWidgets(
      'the die is tappable again after the 4s stop, since the turn is still '
      'my awaitRoll -- see this file\'s header comment, ambiguity 2',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        await tester.pump(const Duration(seconds: 4));
        expect(find.byKey(_noAnswerKey), findsOneWidget);

        final int sentBeforeSecondTap = transport.sentRaw.length;
        await tester.tap(find.byKey(_dieKey));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBeforeSecondTap)
            .toList();
        expect(
          newMessages,
          hasLength(1),
          reason:
              'a tap after the 4s no-answer stop, with the turn still in my '
              'awaitRoll, must send exactly one further roll; got '
              '${newMessages.length}',
        );
        expect(_typeOf(newMessages.single), 'roll');
        expect(
          find.byKey(_noAnswerKey),
          findsNothing,
          reason: 'game-die-no-answer must clear once the die is tapped again',
        );
      },
    );

    testWidgets(
      'no-answer never fires once a rolled reply has already landed before '
      '4s',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        final String rollId = _idOf(
          transport.sentRaw.singleWhere((s) => _typeOf(s) == 'roll'),
        );
        transport.pushText(
          _frame(
            type: 'rolled',
            re: rollId,
            data: <String, Object?>{
              'seat': 0,
              'value': 2,
              'legal': <int>[0],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'c' * 64,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.pump(const Duration(seconds: 4));
        expect(
          find.byKey(_noAnswerKey),
          findsNothing,
          reason:
              'a rolled reply that already landed must cancel the 4s '
              'no-answer timer; it must never fire afterwards',
        );
      },
    );
  });

  // ==========================================================================
  // Hit target.
  // ==========================================================================
  group('hit target', () {
    testWidgets('game-die is at least 72x72 logical pixels', (tester) async {
      final (controller, _) = await _connectTo(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final Size size = tester.getSize(find.byKey(_dieKey));
      expect(
        size.width,
        greaterThanOrEqualTo(72.0),
        reason: 'game-die width must be >= 72; was ${size.width}',
      );
      expect(
        size.height,
        greaterThanOrEqualTo(72.0),
        reason: 'game-die height must be >= 72; was ${size.height}',
      );
    });
  });

  // ==========================================================================
  // Semantics.
  // ==========================================================================
  group('Semantics', () {
    testWidgets(
      'the die is a Semantics(button: true) labelled loc.gameRollButton, '
      'enabled exactly when a tap would roll',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        addTearDown(handle.dispose);

        final (controllerRoll, _) = await _connectTo(
          tester,
          turn: _turnJson(
            seat: 0,
            phase: 'await_roll',
            deadlineMs: 45000,
            k: 0,
          ),
        );
        addTearDown(controllerRoll.dispose);
        await _mount(tester, controllerRoll);
        final AppLocalizations loc = _locOf(tester);

        final SemanticsNode rollNode = tester.getSemantics(find.byKey(_dieKey));
        expect(
          rollNode.flagsCollection.isButton,
          isTrue,
          reason: 'game-die must carry SemanticsFlags.isButton',
        );
        expect(
          rollNode.label,
          loc.gameRollButton,
          reason:
              'game-die\'s Semantics label must be loc.gameRollButton '
              '("${loc.gameRollButton}"); got "${rollNode.label}"',
        );
        expect(
          rollNode.flagsCollection.isEnabled,
          Tristate.isTrue,
          reason: 'in my own awaitRoll, game-die must be enabled',
        );
      },
    );

    testWidgets('disabled in my own awaitMove', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final (controller, _) = await _connectTo(
        tester,
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

      final SemanticsNode node = tester.getSemantics(find.byKey(_dieKey));
      expect(
        node.flagsCollection.isEnabled,
        Tristate.isFalse,
        reason: 'during my own awaitMove, game-die must be disabled',
      );
    });

    testWidgets('disabled when it is not my turn', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final (controller, _) = await _connectTo(
        tester,
        turn: _turnJson(seat: 1, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final SemanticsNode node = tester.getSemantics(find.byKey(_dieKey));
      expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    });

    testWidgets('the Semantics tap action rolls exactly like a real tap', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final (controller, transport) = await _connectTo(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final int sentBefore = transport.sentRaw.length;
      final SemanticsOwner owner =
          tester.binding.rootPipelineOwner.semanticsOwner!;
      final SemanticsNode node = tester.getSemantics(find.byKey(_dieKey));
      owner.performAction(node.id, SemanticsAction.tap);
      await tester.pump();

      final List<String> newMessages = transport.sentRaw
          .skip(sentBefore)
          .toList();
      expect(
        newMessages,
        hasLength(1),
        reason:
            'invoking SemanticsAction.tap on game-die in awaitRoll must '
            'send exactly one roll, the same as a real tap',
      );
      expect(_typeOf(newMessages.single), 'roll');
    });
  });
}
