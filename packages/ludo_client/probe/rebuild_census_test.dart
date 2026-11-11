// C-628 probe (order 628): what rebuilds on every frame of a game.
//
// Not part of the normal suite: this file lives outside test/, so
// `flutter test` with no argument never runs it. Run it by name:
//
//   flock /tmp/ludo-suite.lock timeout 900 \
//     flutter test probe/rebuild_census_test.dart
//
// It mounts the real GameScreen over a real RoomController on FakeTransport
// with scripted frames (the helpers in test/support, unchanged), puts it into
// each steady state below, pumps 60 frames of 16 ms and counts, per frame:
//
//   - every widget rebuild, by widget runtime type, through
//     debugOnRebuildDirtyWidget (every Element.rebuild call: both elements
//     marked dirty by setState or a listenable, and elements rebuilt because
//     their parent handed them a new widget instance);
//   - every RenderObject paint entry, by render object runtime type, through
//     debugOnProfilePaint.
//
// What debugOnProfilePaint measures: the hook runs inside
// PaintingContext.paintChild, so it fires once for every child a painting
// parent paints, including a repaint boundary child that is only composited
// from its cached layer. A boundary child is marked "(boundary)" in the
// output. A boundary that repaints because its own markNeedsPaint ran, while
// its parent did not paint, has no paintChild entry of its own; its children
// do. So the paint table counts "paintChild entries by child type", which
// bounds the painted work from above but is not a count of pictures
// re-recorded.
//
// States (two seats, English, 411 x 891 logical, text scale 1.0, animations
// on): S1 watching, S2 my turn to roll, S3 choosing, S4 walking, S5 end card.
// S5b repeats S5 from the losing seat's view, because "the winner's end card"
// can be read either way.
//
// Each state asserts only that it was reached, by a named key or text. The
// printed census is the product. Every scenario is a fixed frame script with
// the test binding's clock: there is no randomness, and the scenario name and
// the frames pushed are in every failure message.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';

import '../test/support/c468_harness.dart';
import '../test/support/end_card_chat_harness.dart';
import '../test/support/roll_tray_harness.dart';

const int _frames = 60;
const Duration _frame = Duration(milliseconds: 16);
const Size _phone = Size(411, 891);
const int _topRows = 25;

/// Counts rebuilds and paint entries over a run of frames.
class _Census {
  _Census(this.name);

  final String name;

  /// Index of the frame being counted; -1 before the first.
  int frame = -1;

  /// Rebuilds by widget type, per frame.
  final List<Map<String, int>> rebuilds = <Map<String, int>>[];

  /// Elements rebuilt while marked dirty, by origin label, per frame.
  final List<Map<String, int>> dirtied = <Map<String, int>>[];

  /// Paint entries by child render object type, per frame.
  final List<Map<String, int>> paints = <Map<String, int>>[];

  /// The label of the first element rebuilt in each frame ('' when none).
  final List<String> firstDirty = <String>[];

  void beginFrame() {
    frame += 1;
    rebuilds.add(<String, int>{});
    dirtied.add(<String, int>{});
    paints.add(<String, int>{});
    firstDirty.add('');
  }

  static void _bump(Map<String, int> map, String key) {
    map[key] = (map[key] ?? 0) + 1;
  }

  static String _widgetType(Element e) => e.widget.runtimeType.toString();

  /// The widget type, plus the State class for a stateful element, then the
  /// three nearest ancestor widget types and the nearest string key above.
  static String _origin(Element e) {
    final String self = e is StatefulElement
        ? '${_widgetType(e)} [${e.state.runtimeType}]'
        : _widgetType(e);
    final List<String> chain = <String>[];
    String? key;
    e.visitAncestorElements((Element ancestor) {
      if (chain.length < 3) {
        chain.add(_widgetType(ancestor));
      }
      final Key? k = ancestor.widget.key;
      if (key == null && k is ValueKey<String>) {
        key = k.value;
      }
      return chain.length < 3 || key == null;
    });
    return '$self <- ${chain.join(' < ')}'
        '${key == null ? '' : ' (under key $key)'}';
  }

  void onRebuild(Element e, bool builtOnce) {
    if (frame < 0) {
      return;
    }
    _bump(rebuilds[frame], _widgetType(e));
    if (e.dirty) {
      _bump(dirtied[frame], _origin(e));
    }
    if (firstDirty[frame].isEmpty) {
      firstDirty[frame] = _origin(e);
    }
  }

  void onPaint(RenderObject ro) {
    if (frame < 0) {
      return;
    }
    _bump(
      paints[frame],
      '${ro.runtimeType}${ro.isRepaintBoundary ? ' (boundary)' : ''}',
    );
  }

  static int _sum(Map<String, int> m) =>
      m.values.fold(0, (int a, int b) => a + b);

  static String _stats(List<Map<String, int>> perFrame) {
    final List<int> totals = <int>[
      for (final Map<String, int> m in perFrame) _sum(m),
    ];
    final int total = totals.fold(0, (int a, int b) => a + b);
    final int max = totals.fold(0, math.max);
    final int min = totals.fold(1 << 30, math.min);
    return 'total $total, per frame mean '
        '${(total / totals.length).toStringAsFixed(2)} max $max min $min';
  }

  static void _table(
    StringBuffer out,
    String title,
    List<Map<String, int>> perFrame,
  ) {
    final Map<String, int> total = <String, int>{};
    final Map<String, int> present = <String, int>{};
    for (final Map<String, int> m in perFrame) {
      m.forEach((String k, int v) {
        total[k] = (total[k] ?? 0) + v;
        present[k] = (present[k] ?? 0) + 1;
      });
    }
    final int half = (perFrame.length + 1) ~/ 2;
    final List<String> keys =
        <String>[
          for (final String k in total.keys)
            if (present[k]! >= half) k,
        ]..sort((String a, String b) {
          final int byCount = total[b]!.compareTo(total[a]!);
          return byCount != 0 ? byCount : a.compareTo(b);
        });
    out.writeln(
      '  $title: ${keys.length} in at least $half of ${perFrame.length} '
      'frames (top $_topRows; per-frame count = mean per frame, in x/60 = '
      'frames present)',
    );
    for (final String k in keys.take(_topRows)) {
      out.writeln(
        '    ${(total[k]! / perFrame.length).toStringAsFixed(2).padLeft(6)}'
        '/frame  ${present[k].toString().padLeft(2)}/${perFrame.length}  $k',
      );
    }
    if (keys.isEmpty) {
      out.writeln('    (none)');
    }
  }

  /// Frames whose rebuild total is far above the typical frame: the types
  /// rebuilt in them, which the at-least-half tables cannot show.
  void _spikes(StringBuffer out) {
    final List<int> totals = <int>[for (final m in rebuilds) _sum(m)];
    final List<int> sorted = List<int>.of(totals)..sort();
    final int median = sorted[sorted.length ~/ 2];
    final int floor = math.max(10, median * 5);
    final List<int> spikes = <int>[
      for (int i = 0; i < totals.length; i++)
        if (totals[i] > floor) i,
    ];
    out.writeln(
      '  spike frames (total above max(10, 5 x median $median)): '
      '${spikes.length}',
    );
    for (final int i in spikes.take(8)) {
      final List<MapEntry<String, int>> types = rebuilds[i].entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      out.writeln(
        '    frame $i (at ${(i + 1) * 16} ms), ${totals[i]} rebuilds, '
        'first element: ${firstDirty[i]}',
      );
      out.writeln(
        '      ${types.take(12).map((e) => '${e.key} x${e.value}').join(', ')}',
      );
    }
  }

  String report() {
    final StringBuffer out = StringBuffer()
      ..writeln('=== $name ===')
      ..writeln('  frames counted: ${rebuilds.length}')
      ..writeln('  rebuilds: ${_stats(rebuilds)}')
      ..writeln(
        '  rebuilds marked dirty (setState, listenable, inherited): '
        '${_stats(dirtied)}',
      )
      ..writeln(
        '  per-frame rebuild totals: '
        '[${rebuilds.map(_sum).join(' ')}]',
      );
    _table(out, 'widget types rebuilt', rebuilds);
    _table(out, 'dirty-marked elements (origin)', dirtied);
    final Map<String, int> first = <String, int>{};
    for (final String f in firstDirty) {
      first[f.isEmpty ? '(no rebuild in frame)' : f] =
          (first[f.isEmpty ? '(no rebuild in frame)' : f] ?? 0) + 1;
    }
    final List<String> firstKeys = first.keys.toList()
      ..sort((String a, String b) => first[b]!.compareTo(first[a]!));
    out.writeln('  first rebuilt element per frame (frames: element):');
    for (final String k in firstKeys.take(_topRows)) {
      out.writeln('    ${first[k].toString().padLeft(2)}  $k');
    }
    _spikes(out);
    out.writeln('  paint entries: ${_stats(paints)}');
    _table(out, 'paint entry types', paints);
    return out.toString();
  }
}

/// Pumps [_frames] frames of [_frame] each with both hooks set, restoring
/// them in a finally. [onFrame] runs before each frame's pump.
Future<_Census> _count(
  Scn s,
  String name, {
  void Function(int index)? onFrame,
}) async {
  final _Census census = _Census(name);
  debugOnRebuildDirtyWidget = census.onRebuild;
  debugOnProfilePaint = census.onPaint;
  try {
    for (int i = 0; i < _frames; i++) {
      census.beginFrame();
      onFrame?.call(i);
      await s.pump(_frame);
    }
  } finally {
    debugOnRebuildDirtyWidget = null;
    debugOnProfilePaint = null;
  }
  expect(
    census.rebuilds.length,
    _frames,
    reason: s.why('exactly $_frames counted frames'),
  );
  return census;
}

const Map<int, List<int>> _board = <int, List<int>>{
  0: <int>[10, 20, -1, -1],
  1: <int>[30, -1, -1, -1],
};

/// Two seats (0 is mine, 1 is Bob), tokens on the board, the given turn.
Future<EndGame> _open(
  WidgetTester tester,
  String name,
  Map<String, Object?> turn,
) async {
  phoneSurface(tester);
  tester.view.physicalSize = _phone;
  final List<Map<String, Object?>> seats = namedSeats(2, 0, tokens: _board);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: 0,
    gameId: 'c628-game-1',
  );
  await mountGame(tester, drive);
  return EndGame(Scn(name, tester, drive), 0, 2, seats);
}

/// My roll of [value] lands with tokens 0 and 1 legal; pumps until both
/// legal rings are on screen.
Future<void> _rollAndRing(EndGame g, int value) async {
  await g.s.push('rolled', rolledFrame(0, value, 1, legal: <int>[0, 1]));
  int guard = 0;
  while (ringedTokens(g.tester).length < 2 && guard < 400) {
    await g.s.pump(_frame);
    guard += 1;
  }
  expect(
    ringedTokens(g.tester),
    <int>[0, 1],
    reason: g.why(
      'fixture: board-legal-ring-0-0 and board-legal-ring-0-1 on screen '
      'after the roll of $value landed (waited ${guard * 16} ms)',
    ),
  );
}

void main() {
  final List<String> reports = <String>[];

  tearDownAll(() {
    // ignore: avoid_print
    print(
      '\nC-628 REBUILD CENSUS (411x891 logical, text scale 1.0, '
      'animations on, $_frames frames of ${_frame.inMilliseconds} ms per '
      'state)\n\n${reports.join('\n')}',
    );
  });

  testWidgets('S1 watching: the other seat\'s turn, countdown running', (
    WidgetTester tester,
  ) async {
    final EndGame g = await _open(tester, 'S1 watching', awaitRollTurn(1));
    await g.s.pump(const Duration(milliseconds: 500));
    expect(
      find.byKey(const Key('game-header-countdown-ring')),
      findsOneWidget,
      reason: g.why('S1: game-header-countdown-ring is on screen'),
    );
    expect(
      find.byKey(const Key('game-screen-turn-countdown')),
      findsOneWidget,
      reason: g.why('S1: game-screen-turn-countdown text is on screen'),
    );
    expect(
      find.text(
        AppLocalizations.of(tester.element(find.byType(Scaffold).first))
            .gameYourTurnRoll,
      ),
      findsNothing,
      reason: g.why('S1: it is not my turn'),
    );
    reports.add((await _count(g.s, 'S1 watching')).report());
    await g.done();
  });

  testWidgets('S2 my turn to roll: die waiting for my tap', (
    WidgetTester tester,
  ) async {
    final EndGame g = await _open(tester, 'S2 my turn', awaitRollTurn(0));
    await g.s.pump(const Duration(milliseconds: 500));
    final AppLocalizations loc = AppLocalizations.of(
      tester.element(find.byType(Scaffold).first),
    );
    expect(
      find.byKey(bigDieKey),
      findsOneWidget,
      reason: g.why('S2: game-die is on screen'),
    );
    expect(
      find.text(loc.gameYourTurnRoll),
      findsWidgets,
      reason: g.why('S2: the text "${loc.gameYourTurnRoll}" is on screen'),
    );
    reports.add((await _count(g.s, 'S2 my turn to roll')).report());
    await g.done();
  });

  testWidgets('S3 choosing: two legal tokens, rings pulsing', (
    WidgetTester tester,
  ) async {
    final EndGame g = await _open(tester, 'S3 choosing', awaitRollTurn(0));
    await _rollAndRing(g, 3);
    expect(
      find.byKey(legalRingKey(0, 0)),
      findsOneWidget,
      reason: g.why('S3: board-legal-ring-0-0 present'),
    );
    expect(
      find.byKey(legalRingKey(0, 1)),
      findsOneWidget,
      reason: g.why('S3: board-legal-ring-0-1 present'),
    );
    reports.add((await _count(g.s, 'S3 choosing')).report());
    await g.done();
  });

  testWidgets('S4 walking: a token walks 5 squares', (
    WidgetTester tester,
  ) async {
    final EndGame g = await _open(tester, 'S4 walking', awaitRollTurn(0));
    await _rollAndRing(g, 5);
    await g.s.push('moved', movedFrame(0, 0, 10, 15));
    final Finder token = find.byKey(const Key('token-0-0'));
    final List<Offset> centres = <Offset>[];
    final _Census census = await _count(
      g.s,
      'S4 walking',
      onFrame: (int i) {
        if (i == 0 || i == 20 || i == _frames - 1) {
          centres.add(tester.getCenter(token));
        }
      },
    );
    expect(
      centres[1],
      isNot(centres[0]),
      reason: g.why(
        'S4: token-0-0 moved between the first counted frame '
        '(${centres[0]}) and frame 20 (${centres[1]}), so the walk was '
        'under way',
      ),
    );
    expect(
      centres[2],
      isNot(centres[0]),
      reason: g.why('S4: token-0-0 ended away from where the walk began'),
    );
    reports.add(census.report());
    await g.done();
  });

  Future<void> endCard(WidgetTester tester, String name, EndKind kind) async {
    final EndGame g = await openFinished(
      tester,
      name,
      kind: kind,
      size: _phone,
    );
    int guard = 0;
    while (find.byKey(const Key('game-screen-winner')).evaluate().isEmpty &&
        guard < 200) {
      await g.s.pump(_frame);
      guard += 1;
    }
    expect(
      find.byKey(const Key('game-screen-winner')),
      findsOneWidget,
      reason: g.why('$name: game-screen-winner (the end card) is on screen'),
    );
    await g.s.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const Key('game-screen-winner')),
      findsOneWidget,
      reason: g.why('$name: the end card is still up 2 s after it appeared'),
    );
    reports.add((await _count(g.s, name)).report());
    await g.done();
  }

  testWidgets('S5 end card: I am the winner, 2 s after it appears', (
    WidgetTester tester,
  ) async {
    await endCard(tester, 'S5 end card (viewer is the winner)', EndKind.winner);
  });

  testWidgets('S5x end card: I am the winner, the first 60 frames', (
    WidgetTester tester,
  ) async {
    final EndGame g = await openFinished(
      tester,
      'S5x end card, first frames',
      kind: EndKind.winner,
      size: _phone,
    );
    expect(
      find.byKey(const Key('game-screen-winner')),
      findsOneWidget,
      reason: g.why('S5x: game-screen-winner (the end card) is on screen'),
    );
    reports.add(
      (await _count(g.s, 'S5x end card, first 60 frames (extra)')).report(),
    );
    await g.done();
  });

  testWidgets('S5b end card: the other seat won, 2 s after it appears', (
    WidgetTester tester,
  ) async {
    await endCard(tester, 'S5b end card (viewer lost)', EndKind.loser);
  });
}
