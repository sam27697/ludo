// Widget test for GameScreen's die value text: game-screen-dice-value must
// update only from turn.value after a rolled frame lands, never showing an
// interim face while a roll is in flight.
//
// Order 224 (work/ludo/orders/C-223-play-surface.md, run 65) removed the
// Roll button (`game-screen-roll-button`) and its own opacity/scale "juice"
// (`game-screen-roll-pulse`) this file used to prove, replacing that control
// with the die (`game-die`) and its tumble (`game-die-tumbling`). Two of
// this file's four original cases had no successor and are dropped, not
// migrated, with the reason each was dropped:
//
//   - "Roll control pulses opacity or scale within 200ms when animations
//     are on" (original line 561): this proved the old ElevatedButton's own
//     FadeTransition/ScaleTransition juice, a widget that no longer exists.
//     Its structural successor -- that a tap starts a cosmetic tumble at
//     once -- is covered by test/play_surface_die_test.dart's "the tumble"
//     group (`game-die-tumbling` present right after the tap); the specific
//     opacity/scale mechanics and the 200ms budget are motion timing beyond
//     what C-223 states, which the work order also places out of scope.
//   - "reduced-motion Roll tap skips the opacity/scale pulse" (original line
//     645): same reasoning as the previous case. Its successor --
//     `game-die-pulse` absent, and no tumble rotation, under
//     `MediaQuery.disableAnimations` -- is covered by
//     test/play_surface_die_test.dart's "game-die-pulse" group.
//
// "Roll tap fires HapticFeedback.lightImpact before rolled" (original line
// 488) is migrated below, driven by a tap on `game-die` instead of the
// retired button: order 223 kept HapticFeedback.lightImpact() on the
// rolling tap on purpose (master, run 66 verdict, defect 4), so the claim
// still has a live control to prove it against even though C-223's own text
// never names haptics.
//
// The fourth original case, also kept and migrated below, is not about the
// removed control's own look: it is about game-screen-dice-value, a key
// C-223 keeps unchanged ("the dice value text ... stay exactly as they
// are"), and the claim it proves (no interim face while waiting on the
// server) is exactly as meaningful against the die as it was against the
// old button.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real controller sits over FakeTransport. Claims about
// the wire use sentRaw. Claims about haptics use the platform channel. The
// outstanding roll request is always completed so no reply timer survives
// the test body.
//
// Order 251 (work/ludo/orders/C-250-play-header.md, run 70): rule 5 moves
// game-screen-dice-value from a visible Text onto a Semantics wrapping the
// die, carrying loc.gameDieValue(v) as its label rather than as Text.data.
// `_dieText`, the one helper here that read the key as a Text, is amended in
// place, old and new recorded at its own definition; every call site is
// unchanged since the helper's own return type and meaning (the rendered
// die-value string, or null when the key is absent) did not change.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart'
    show appSupportedLocales, buildAppTheme;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://game-juice-test.invalid/ws';
const Key _dieKey = Key('game-die');
const Key _tumblingKey = Key('game-die-tumbling');
const Key _dieValueKey = Key('game-screen-dice-value');
const int _wireFace = 5;

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'juice-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

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
  List<Map<String, Object?>>? seats,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
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

Future<(RoomController, FakeTransport)> _connectAwaitingRoll(
  WidgetTester tester,
) async {
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
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

Widget _harness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: const Locale('en'),
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
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: controller),
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

List<MethodCall> _listenPlatform(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      calls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

List<MethodCall> _hapticCalls(List<MethodCall> platformCalls) {
  return platformCalls
      .where((MethodCall call) => call.method == 'HapticFeedback.vibrate')
      .toList();
}

Future<void> _completeRoll(
  WidgetTester tester,
  FakeTransport transport, {
  int value = _wireFace,
  List<int> legal = const <int>[0, 1],
}) async {
  final List<String> rolls = transport.sentRaw
      .where((String s) => _typeOf(s) == 'roll')
      .toList();
  if (rolls.isEmpty) {
    return;
  }
  transport.pushText(
    _frame(
      type: 'rolled',
      re: _idOf(rolls.last),
      data: <String, Object?>{
        'seat': 0,
        'value': value,
        'legal': legal,
        'deadline_ms': 45000,
        'k': 1,
        'reveal': 'b' * 64,
        'seq': 2,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

// Amended for C-250 rule 5: game-screen-dice-value moved from a visible
// Text onto a Semantics wrapping the die, carrying loc.gameDieValue(v) as
// its label rather than as Text.data. Old:
//   final Text text = tester.widget<Text>(die);
//   return text.data;
// New:
String? _dieText(WidgetTester tester) {
  final Finder die = find.byKey(_dieValueKey);
  if (die.evaluate().isEmpty) {
    return null;
  }
  final Semantics semantics = tester.widget<Semantics>(die);
  return semantics.properties.label;
}

List<String> _dieFaceLabelsOnScreen(WidgetTester tester, AppLocalizations loc) {
  final List<String> hits = <String>[];
  for (int face = 1; face <= 6; face++) {
    final String label = loc.gameDieValue(face);
    if (find.text(label).evaluate().isNotEmpty) {
      hits.add(label);
    }
  }
  return hits;
}

void main() {
  testWidgets('a tap on game-die fires HapticFeedback.lightImpact before '
      'rolled', (WidgetTester tester) async {
    final List<MethodCall> platformCalls = _listenPlatform(tester);
    final (controller, transport) = await _connectAwaitingRoll(tester);
    await _mount(tester, controller);

    expect(
      controller.room!.turn!.value,
      isNull,
      reason: 'fixture is broken: await_roll must start with a null face',
    );
    expect(find.byKey(_dieKey), findsOneWidget);

    final int sentBefore = transport.sentRaw.length;
    await tester.tap(find.byKey(_dieKey));
    await tester.pump();

    final List<String> newMessages = transport.sentRaw
        .skip(sentBefore)
        .toList();
    expect(
      newMessages.where((String s) => _typeOf(s) == 'roll'),
      hasLength(1),
      reason:
          'tapping game-die must still put exactly one roll on the wire; '
          'juice must not block or delay that send',
    );

    final List<MethodCall> haptic = _hapticCalls(platformCalls);
    expect(
      haptic,
      isNotEmpty,
      reason:
          'tapping game-die in my awaitRoll must invoke HapticFeedback '
          'before any rolled frame arrives; got ${haptic.length} haptic '
          'call(s) and platform methods '
          '${platformCalls.map((MethodCall c) => c.method).toList()}',
    );
    expect(
      haptic.first.arguments,
      'HapticFeedbackType.lightImpact',
      reason:
          'the haptic must be HapticFeedback.lightImpact, not a looped '
          'vibrate while waiting on rolled',
    );

    expect(
      controller.room!.turn!.phase,
      TurnPhase.awaitRoll,
      reason:
          'haptic must fire locally; the turn must still be awaitRoll '
          'until rolled arrives',
    );
    expect(
      controller.room!.turn!.value,
      isNull,
      reason: 'haptic must not invent a die face on the controller',
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(
      _hapticCalls(platformCalls),
      hasLength(1),
      reason:
          'waiting on rolled must not fire further haptic calls; got '
          '${_hapticCalls(platformCalls).length}',
    );

    await _completeRoll(tester, transport);
  });

  testWidgets(
    'game-screen-dice-value updates only from turn.value after rolled',
    (WidgetTester tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      expect(find.byKey(_dieValueKey), findsNothing);
      expect(_dieFaceLabelsOnScreen(tester, loc), isEmpty);

      await tester.tap(find.byKey(_dieKey));
      await tester.pump();

      final List<String?> facesBeforeRolled = <String?>[_dieText(tester)];
      final List<List<String>> labelsBeforeRolled = <List<String>>[
        _dieFaceLabelsOnScreen(tester, loc),
      ];

      int elapsedMs = 0;
      while (elapsedMs < 200) {
        final int step = math.min(16, 200 - elapsedMs);
        await tester.pump(Duration(milliseconds: step));
        elapsedMs += step;
        facesBeforeRolled.add(_dieText(tester));
        labelsBeforeRolled.add(_dieFaceLabelsOnScreen(tester, loc));
        expect(
          controller.room!.turn!.value,
          isNull,
          reason:
              'tapping the die must not write a local face onto turn.value '
              'before rolled; got ${controller.room!.turn!.value}',
        );
      }

      expect(
        facesBeforeRolled,
        everyElement(isNull),
        reason:
            'game-screen-dice-value must stay absent until rolled; a '
            'random interim face would appear here. samples: '
            '$facesBeforeRolled',
      );
      expect(
        labelsBeforeRolled.expand((List<String> e) => e),
        isEmpty,
        reason:
            'no loc.gameDieValue(1..6) text may appear after the tap and '
            'before rolled; a tumble that painted a real face on any '
            'widget would show those labels. samples: $labelsBeforeRolled',
      );

      expect(
        find.byKey(_tumblingKey),
        findsOneWidget,
        reason:
            'hiding the die value until turn.value arrives is not an '
            'interim-face guard by itself; the waiting cue must be the '
            'cosmetic tumble (game-die-tumbling), which paints no real '
            'face of its own',
      );

      await _completeRoll(tester, transport, value: _wireFace);

      expect(
        controller.room!.turn!.value,
        _wireFace,
        reason: 'fixture is broken: rolled must land turn.value=$_wireFace',
      );
      expect(find.byKey(_dieValueKey), findsOneWidget);
      expect(
        _dieText(tester),
        loc.gameDieValue(_wireFace),
        reason:
            'after rolled, game-screen-dice-value must show '
            'loc.gameDieValue($_wireFace) ("${loc.gameDieValue(_wireFace)}"); '
            'got "${_dieText(tester)}"',
      );

      for (int face = 1; face <= 6; face++) {
        if (face == _wireFace) {
          continue;
        }
        expect(
          find.text(loc.gameDieValue(face)),
          findsNothing,
          reason:
              'after rolled $_wireFace, loc.gameDieValue($face) must not '
              'appear; an interpolating tumble would show other faces',
        );
      }

      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _dieText(tester),
        loc.gameDieValue(_wireFace),
        reason:
            'the painted face must stay the rolled value while any '
            'remaining juice runs; got "${_dieText(tester)}"',
      );
    },
  );
}
