// Shared driver for the C-468 screen tests (order 469): die landings, the
// capture gloat and the faded idle die. Built on roll_tray_harness.dart: a
// real GameScreen over a real RoomController on FakeTransport, every state
// a decoded wire frame. Each helper keeps the frames and pumps it ran, so a
// failure message replays the scenario.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';

import 'roll_tray_harness.dart';

const Duration kC468Frame = Duration(milliseconds: 16);

/// A finer step for timing checks: a moment is known to within this much.
const Duration kC468Fine = Duration(milliseconds: 5);

const List<int> kYard = <int>[-1, -1, -1, -1];

/// One scenario: its name, the frames pushed and the time pumped so far.
class Scn {
  Scn(this.name, this.tester, this.drive);

  final String name;
  final WidgetTester tester;
  final RollTrayDrive drive;
  final List<String> steps = <String>[];

  /// Total fake time pumped through [pump], in milliseconds.
  int clockMs = 0;

  String why(String expected) =>
      '$name | expected: $expected | at ${clockMs}ms | replay: '
      '${steps.join(' > ')}';

  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add('$type ${jsonEncode(data)}');
    await drive.push(tester, type, data);
  }

  /// A server `emote` push, no `seq`. [re] marks it as the sender's own copy.
  Future<void> pushEmote(Object? seat, Object? emote, {String? re}) async {
    steps.add('emote seat=$seat id=$emote${re == null ? '' : ' re=$re'}');
    await pushRaw(tester, drive, emoteFrame(seat: seat, emote: emote, re: re));
  }

  /// Pumps [duration] in steps of [step] (the last one may be shorter).
  Future<void> pump(Duration duration, {Duration step = kC468Frame}) async {
    steps.add('pump ${duration.inMilliseconds}ms');
    Duration elapsed = Duration.zero;
    while (elapsed < duration) {
      final Duration remaining = duration - elapsed;
      final Duration next = remaining < step ? remaining : step;
      await tester.pump(next);
      elapsed += next;
      clockMs += next.inMilliseconds;
    }
  }

  int count(FeedbackCue cue) => cueCount(drive.feedback, cue);
}

Map<String, Object?> awaitRollTurn(int seat, {int k = 0, List<int>? queue}) =>
    turnJson(seat: seat, phase: 'await_roll', k: k, queue: queue);

Map<String, Object?> rolledFrame(
  int seat,
  int value,
  int k, {
  List<int> legal = const <int>[0],
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> turnFrame(int seat, {List<int> queue = const <int>[]}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': queue,
    };

Map<String, Object?> movedFrame(
  int seat,
  int token,
  int from,
  int to, {
  List<Map<String, int>> captured = const <Map<String, int>>[],
  bool extraRoll = false,
}) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': from,
  'to': to,
  'captured': captured,
  'extra_roll': extraRoll,
};

Map<String, Object?> gameOverFrame(int winner) => <String, Object?>{
  'winner': winner,
  'verify_url': 'https://c468-test.invalid/verify/1',
};

const Map<int, String> kNames = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};

/// Seats 0 and 2 only; the opponent is called Bob in both views.
List<Map<String, Object?>> pairSeats({
  required int mySeat,
  List<int> mine = kYard,
  List<int> opponent = kYard,
}) {
  final int other = mySeat == 0 ? 2 : 0;
  final Map<int, Map<String, Object?>> bySeat = <int, Map<String, Object?>>{
    mySeat: seatJson(mySeat, name: 'Sam', tokens: mine),
    other: seatJson(other, name: 'Bob', tokens: opponent),
  };
  return <Map<String, Object?>>[bySeat[0]!, bySeat[2]!];
}

List<Map<String, Object?>> quadSeats({
  required int mySeat,
  Map<int, List<int>> tokens = const <int, List<int>>{},
}) => <Map<String, Object?>>[
  for (int seat = 0; seat < 4; seat++)
    seatJson(
      seat,
      name: seat == mySeat ? 'Sam' : kNames[seat]!,
      tokens: tokens[seat] ?? kYard,
    ),
];

Future<RollTrayDrive> mountScreen(
  WidgetTester tester, {
  required Map<String, Object?> turn,
  required List<Map<String, Object?>> seats,
  int mySeat = 0,
  int players = 2,
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: mySeat,
    players: players,
  );
  await mountGame(
    tester,
    drive,
    locale: locale,
    disableAnimations: disableAnimations,
  );
  return drive;
}

/// 360x800 at pixel ratio 1, so a logical pixel is a device pixel and the
/// root transform carries no scale of its own.
void phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

double cellSize(WidgetTester tester) => boardSquare(tester).width / 15;

/// How many cues of [cue] have been recorded.
int cues(Scn s, FeedbackCue cue) => s.count(cue);

/// `capture-gloat-<seat>`, the CaptureGloat root key (C-468 D5.2).
Key gloatKey(int seat) => Key('capture-gloat-$seat');

const String _gloatPrefix = 'capture-gloat-';

Finder anyGloat() => find.byWidgetPredicate((Widget widget) {
  final Key? key = widget.key;
  return key is ValueKey<String> && key.value.startsWith(_gloatPrefix);
});

/// The seats whose `capture-gloat-<seat>` is on screen, in tree order.
List<int> gloatSeats(WidgetTester tester) => <int>[
  for (final Element element in anyGloat().evaluate())
    int.parse(
      (element.widget.key! as ValueKey<String>).value.substring(
        _gloatPrefix.length,
      ),
    ),
];

/// Pumps [step] at a time until some `capture-gloat-*` is on screen, at
/// most [limit]; returns the clock reading (ms) of the first frame it was
/// seen on, or null when it never showed. The gloat started at most [step]
/// before that reading.
Future<int?> pumpUntilGloat(
  Scn s, {
  Duration limit = const Duration(seconds: 4),
  Duration step = kC468Fine,
}) async {
  final int stop = s.clockMs + limit.inMilliseconds;
  while (s.clockMs <= stop) {
    if (gloatSeats(s.tester).isNotEmpty) {
      return s.clockMs;
    }
    await s.pump(step, step: step);
  }
  return null;
}

/// Index of the board Stack child that holds [target].
int stackSlot(WidgetTester tester, Element boardStack, Finder target) {
  expect(target, findsOneWidget, reason: 'layer target is on the board');
  final Element start = tester.element(target);
  Element previous = start;
  int? found;
  start.visitAncestorElements((Element ancestor) {
    if (identical(ancestor, boardStack)) {
      int index = 0;
      ancestor.visitChildElements((Element child) {
        if (identical(child, previous)) {
          found = index;
        }
        index += 1;
      });
      return false;
    }
    previous = ancestor;
    return true;
  });
  expect(found, isNotNull, reason: '$target is not a layer of the board stack');
  return found!;
}

/// The Stack the board paints its layers in: the nearest Stack above a
/// yard token.
Element boardStackOf(WidgetTester tester) {
  final Element token = tester.element(find.byKey(const Key('token-2-0')));
  Element? stack;
  token.visitAncestorElements((Element ancestor) {
    if (ancestor.widget is Stack) {
      stack = ancestor;
      return false;
    }
    return true;
  });
  return stack!;
}

/// The render object that paints the face: the key's own, or the first
/// CustomPaint at or below the key, so a Transform placed either above the
/// key or between the key and the paint shows up in its transform.
RenderObject paintObjectOf(WidgetTester tester, Finder key) {
  final Element root = tester.element(key);
  if (root.widget is CustomPaint) {
    return root.renderObject!;
  }
  Element? paint;
  void walk(Element element) {
    if (paint != null) {
      return;
    }
    if (element.widget is CustomPaint) {
      paint = element;
      return;
    }
    element.visitChildren(walk);
  }

  root.visitChildren(walk);
  return (paint ?? root).renderObject!;
}

/// Scale and rotation (degrees) of what is painted under [key], read from
/// the full transform to the screen, so any Transform above the paint
/// counts however it was built.
({double scale, double degrees}) poseOf(WidgetTester tester, Finder key) {
  final RenderObject paint = paintObjectOf(tester, key);
  final Matrix4 m = paint.getTransformTo(null);
  final double a = m.storage[0];
  final double b = m.storage[1];
  return (
    scale: math.sqrt(a * a + b * b),
    degrees: math.atan2(b, a) * 180 / math.pi,
  );
}

/// Where the painted face sits on screen: its box centre run through the
/// full transform.
Offset paintCentreOf(WidgetTester tester, Finder key) {
  final RenderObject paint = paintObjectOf(tester, key);
  final Rect local = (paint as RenderBox).paintBounds;
  return MatrixUtils.transformPoint(paint.getTransformTo(null), local.center);
}

/// The nearest `Opacity` ancestor of [art] at any depth, as its opacity;
/// null when there is none (C-468 D7). The product may wrap the whole
/// `GameDie` (the `game-die` key) rather than only the art, so the search
/// does not stop at that key. It must still be the die's own fade: the
/// found `Opacity` may not also be an ancestor of `ludo-board`, so a
/// screen-wide fade cannot pass (order 469 RETURN 1).
double? nearestOpacityUnderBigDie(WidgetTester tester, Finder art) {
  final Element start = tester.element(art);
  Element? opacityElement;
  bool underDie = start.widget.key == bigDieKey;
  start.visitAncestorElements((Element ancestor) {
    if (ancestor.widget.key == bigDieKey) {
      underDie = true;
    }
    if (opacityElement == null && ancestor.widget is Opacity) {
      opacityElement = ancestor;
    }
    return true;
  });
  if (!underDie) {
    fail('the art is not under the game-die root key');
  }
  final Element? found = opacityElement;
  if (found == null) {
    return null;
  }
  final Finder board = find.byKey(const Key('ludo-board'));
  expect(
    board,
    findsOneWidget,
    reason: 'the ludo-board is on screen, to prove the fade is the die\'s own',
  );
  bool boardUnderIt = false;
  tester.element(board).visitAncestorElements((Element ancestor) {
    if (identical(ancestor, found)) {
      boardUnderIt = true;
      return false;
    }
    return true;
  });
  expect(
    boardUnderIt,
    isFalse,
    reason:
        'the Opacity found above the die art (${found.widget}) is also an '
        'ancestor of ludo-board: a screen-wide fade is not the D7 die fade',
  );
  return (found.widget as Opacity).opacity;
}
