// Widget tests for GameScreen roll juice: a Roll tap must fire haptic
// feedback without waiting for the rolled frame, pulse the Roll control
// for at most 200ms when animations are on (and skip that motion when
// they are off), and never paint a die face that did not come from
// turn.value after rolled.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real controller sits over FakeTransport. Claims about
// the wire use sentRaw. Claims about haptics use the platform channel.
// Claims about the pulse use the keyed Roll juice widget and its
// computed opacity/scale. The outstanding roll request is always
// completed so no reply timer survives the test body.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://game-juice-test.invalid/ws';
const Key _rollKey = Key('game-screen-roll-button');
const Key _pulseKey = Key('game-screen-roll-pulse');
const Key _dieKey = Key('game-screen-dice-value');
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

String? _dieText(WidgetTester tester) {
  final Finder die = find.byKey(_dieKey);
  if (die.evaluate().isEmpty) {
    return null;
  }
  final Text text = tester.widget<Text>(die);
  return text.data;
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

bool _rollPointerIgnored(WidgetTester tester) {
  final Finder ignored = find.ancestor(
    of: find.byKey(_rollKey),
    matching: find.byWidgetPredicate((Widget w) {
      if (w is IgnorePointer && w.ignoring) {
        return true;
      }
      if (w is AbsorbPointer && w.absorbing) {
        return true;
      }
      return false;
    }),
  );
  return ignored.evaluate().isNotEmpty;
}

double _opacityTowardRoot(RenderObject node) {
  double opacity = 1.0;
  RenderObject? current = node;
  while (current != null) {
    if (current is RenderOpacity) {
      opacity *= current.opacity;
    } else if (current is RenderAnimatedOpacity) {
      opacity *= current.opacity.value;
    }
    current = current.parent;
  }
  return opacity;
}

double _uniformScaleOnGame(WidgetTester tester, RenderObject node) {
  final RenderObject game = tester.renderObject(find.byType(GameScreen));
  final Matrix4 matrix = node.getTransformTo(game);
  final double sx = matrix.storage[0].abs();
  final double sy = matrix.storage[5].abs();
  return (sx + sy) / 2.0;
}

double? _widgetJuiceOpacity(WidgetTester tester) {
  final Finder pulse = find.byKey(_pulseKey);
  if (pulse.evaluate().isEmpty) {
    return null;
  }
  final Widget host = tester.widget(pulse);
  if (host is FadeTransition) {
    return host.opacity.value;
  }
  if (host is Opacity) {
    return host.opacity;
  }
  if (host is AnimatedOpacity) {
    return tester.renderObject<RenderAnimatedOpacity>(pulse).opacity.value;
  }
  final Finder fades = find.descendant(
    of: pulse,
    matching: find.byType(FadeTransition),
  );
  if (fades.evaluate().isNotEmpty) {
    return tester.widget<FadeTransition>(fades.first).opacity.value;
  }
  return null;
}

double? _widgetJuiceScale(WidgetTester tester) {
  final Finder pulse = find.byKey(_pulseKey);
  if (pulse.evaluate().isEmpty) {
    return null;
  }
  final Widget host = tester.widget(pulse);
  if (host is ScaleTransition) {
    return host.scale.value;
  }
  if (host is Transform) {
    return host.transform.storage[0].abs();
  }
  final Finder scales = find.descendant(
    of: pulse,
    matching: find.byType(ScaleTransition),
  );
  if (scales.evaluate().isNotEmpty) {
    return tester.widget<ScaleTransition>(scales.first).scale.value;
  }
  return null;
}

({double opacity, double scale}) _rollJuiceMetrics(WidgetTester tester) {
  final Finder host = find.byKey(_pulseKey).evaluate().isNotEmpty
      ? find.byKey(_pulseKey)
      : find.byKey(_rollKey);
  final RenderObject render = tester.renderObject(host);
  final double? widgetOpacity = _widgetJuiceOpacity(tester);
  final double? widgetScale = _widgetJuiceScale(tester);
  return (
    opacity: widgetOpacity ?? _opacityTowardRoot(render),
    scale: widgetScale ?? _uniformScaleOnGame(tester, render),
  );
}

bool _rollIsPulsing(WidgetTester tester) {
  if (find.byKey(_pulseKey).evaluate().isEmpty) {
    return false;
  }
  final metrics = _rollJuiceMetrics(tester);
  return (metrics.opacity - 1.0).abs() > 0.01 ||
      (metrics.scale - 1.0).abs() > 0.01;
}

Duration? _pulseDeclaredDuration(WidgetTester tester) {
  final Finder pulse = find.byKey(_pulseKey);
  if (pulse.evaluate().isEmpty) {
    return null;
  }

  Duration? fromAnimation(Animation<double> animation) {
    Animation<double>? current = animation;
    while (current != null && current is! AnimationController) {
      if (current is CurvedAnimation) {
        current = current.parent;
        continue;
      }
      if (current is ProxyAnimation) {
        current = current.parent;
        continue;
      }
      if (current is ReverseAnimation) {
        current = current.parent;
        continue;
      }
      break;
    }
    if (current is AnimationController) {
      return current.duration;
    }
    return null;
  }

  Duration? inspect(Widget widget) {
    if (widget is FadeTransition) {
      return fromAnimation(widget.opacity);
    }
    if (widget is ScaleTransition) {
      return fromAnimation(widget.scale);
    }
    if (widget is AnimatedOpacity) {
      return widget.duration;
    }
    if (widget is AnimatedScale) {
      return widget.duration;
    }
    return null;
  }

  final Duration? direct = inspect(tester.widget(pulse));
  if (direct != null) {
    return direct;
  }

  for (final Element element
      in find
          .descendant(of: pulse, matching: find.byType(FadeTransition))
          .evaluate()) {
    final Duration? duration = inspect(element.widget);
    if (duration != null) {
      return duration;
    }
  }
  for (final Element element
      in find
          .descendant(of: pulse, matching: find.byType(ScaleTransition))
          .evaluate()) {
    final Duration? duration = inspect(element.widget);
    if (duration != null) {
      return duration;
    }
  }
  for (final Element element
      in find
          .descendant(of: pulse, matching: find.byType(AnimatedOpacity))
          .evaluate()) {
    final Duration? duration = inspect(element.widget);
    if (duration != null) {
      return duration;
    }
  }
  for (final Element element
      in find
          .descendant(of: pulse, matching: find.byType(AnimatedScale))
          .evaluate()) {
    final Duration? duration = inspect(element.widget);
    if (duration != null) {
      return duration;
    }
  }
  return null;
}

void main() {
  testWidgets('Roll tap fires HapticFeedback.lightImpact before rolled', (
    WidgetTester tester,
  ) async {
    final List<MethodCall> platformCalls = _listenPlatform(tester);
    final (controller, transport) = await _connectAwaitingRoll(tester);
    await _mount(tester, controller);

    expect(
      controller.room!.turn!.value,
      isNull,
      reason: 'fixture is broken: await_roll must start with a null face',
    );
    expect(find.byKey(_rollKey), findsOneWidget);

    final int sentBefore = transport.sentRaw.length;
    await tester.tap(find.byKey(_rollKey));
    await tester.pump();

    final List<String> newMessages = transport.sentRaw
        .skip(sentBefore)
        .toList();
    expect(
      newMessages.where((String s) => _typeOf(s) == 'roll'),
      hasLength(1),
      reason:
          'Roll must still put exactly one roll on the wire; juice '
          'must not block or delay that send',
    );

    final List<MethodCall> haptic = _hapticCalls(platformCalls);
    expect(
      haptic,
      isNotEmpty,
      reason:
          'tapping the enabled Roll control must invoke '
          'HapticFeedback before any rolled frame arrives; got '
          '${haptic.length} haptic call(s) and platform methods '
          '${platformCalls.map((MethodCall c) => c.method).toList()}',
    );
    expect(
      haptic.first.arguments,
      'HapticFeedbackType.lightImpact',
      reason:
          'the haptic must be HapticFeedback.lightImpact, not a '
          'looped vibrate while waiting on rolled',
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
          'waiting on rolled must not fire further haptic calls; '
          'got ${_hapticCalls(platformCalls).length}',
    );

    await _completeRoll(tester, transport);
  });

  testWidgets(
    'Roll control pulses opacity or scale within 200ms when animations are on',
    (WidgetTester tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);

      final Size rollSizeBefore = tester.getSize(find.byKey(_rollKey));
      expect(rollSizeBefore.width, greaterThanOrEqualTo(48));
      expect(rollSizeBefore.height, greaterThanOrEqualTo(48));

      await tester.tap(find.byKey(_rollKey));
      await tester.pump();

      expect(
        find.byKey(_pulseKey),
        findsOneWidget,
        reason:
            'a Roll tap with animations enabled must put juice on a '
            'widget keyed game-screen-roll-pulse',
      );
      expect(
        _rollPointerIgnored(tester),
        isFalse,
        reason: 'the roll pulse must not swallow pointer hits',
      );

      final Duration? declared = _pulseDeclaredDuration(tester);
      if (declared != null) {
        expect(
          declared.inMilliseconds,
          lessThanOrEqualTo(200),
          reason:
              'declared roll pulse duration must be <= 200ms; got '
              '${declared.inMilliseconds}ms',
        );
        final BuildContext context = tester.element(find.byType(GameScreen));
        final LudoBrand? brand = Theme.of(context).extension<LudoBrand>();
        expect(brand, isNotNull);
        expect(
          declared.inMilliseconds,
          lessThanOrEqualTo(brand!.motionShort.inMilliseconds),
          reason:
              'roll pulse duration must not exceed LudoBrand.motionShort '
              '(${brand.motionShort.inMilliseconds}ms)',
        );
      }

      bool sawMotion = _rollIsPulsing(tester);
      int elapsedMs = 0;
      while (elapsedMs < 200) {
        final int step = math.min(16, 200 - elapsedMs);
        await tester.pump(Duration(milliseconds: step));
        elapsedMs += step;
        if (_rollIsPulsing(tester)) {
          sawMotion = true;
        }
        expect(
          _rollPointerIgnored(tester),
          isFalse,
          reason: 'pulse must not block input at ${elapsedMs}ms',
        );
        final Size rollSize = tester.getSize(find.byKey(_rollKey));
        expect(rollSize.width, greaterThanOrEqualTo(48));
        expect(rollSize.height, greaterThanOrEqualTo(48));
      }

      expect(
        sawMotion,
        isTrue,
        reason:
            'with animations enabled, Roll juice must change opacity or '
            'uniform scale within 200ms',
      );
      expect(
        _rollIsPulsing(tester),
        isFalse,
        reason:
            'the opacity/scale pulse must have finished by 200ms; still '
            'pulsing after the budget is too long',
      );

      await _completeRoll(tester, transport);
    },
  );

  testWidgets('reduced-motion Roll tap skips the opacity/scale pulse', (
    WidgetTester tester,
  ) async {
    final (controller, transport) = await _connectAwaitingRoll(tester);
    await _mount(tester, controller, disableAnimations: true);

    await tester.tap(find.byKey(_rollKey));
    await tester.pump();

    expect(
      find.byKey(_pulseKey),
      findsOneWidget,
      reason:
          'reduced-motion still needs game-screen-roll-pulse in the tree '
          'so the skip is observable, not a missing control',
    );

    expect(
      _rollIsPulsing(tester),
      isFalse,
      reason:
          'when MediaQuery.disableAnimations is true, Roll must not '
          'run an opacity/scale pulse',
    );

    await tester.pump(const Duration(milliseconds: 50));
    expect(
      _rollIsPulsing(tester),
      isFalse,
      reason:
          'reduced-motion Roll juice must stay at rest through 50ms, '
          'matching the home-enter skip',
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      _rollIsPulsing(tester),
      isFalse,
      reason: 'reduced-motion must not start a pulse later in the 200ms budget',
    );

    final metrics = _rollJuiceMetrics(tester);
    expect(metrics.opacity, closeTo(1.0, 0.01));
    expect(metrics.scale, closeTo(1.0, 0.01));

    await _completeRoll(tester, transport);
  });

  testWidgets(
    'game-screen-dice-value updates only from turn.value after rolled',
    (WidgetTester tester) async {
      final (controller, transport) = await _connectAwaitingRoll(tester);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      expect(find.byKey(_dieKey), findsNothing);
      expect(_dieFaceLabelsOnScreen(tester, loc), isEmpty);

      await tester.tap(find.byKey(_rollKey));
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
              'tapping Roll must not write a local face onto turn.value '
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
            'no loc.gameDieValue(1..6) text may appear after Roll and '
            'before rolled; a tumble on any widget would show those '
            'labels. samples: $labelsBeforeRolled',
      );

      expect(
        find.byKey(_pulseKey),
        findsOneWidget,
        reason:
            'hiding the die until turn.value arrives is not an '
            'interim-face guard by itself; the waiting cue must be '
            'game-screen-roll-pulse so juice cannot be a local face',
      );

      await _completeRoll(tester, transport, value: _wireFace);

      expect(
        controller.room!.turn!.value,
        _wireFace,
        reason: 'fixture is broken: rolled must land turn.value=$_wireFace',
      );
      expect(find.byKey(_dieKey), findsOneWidget);
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
