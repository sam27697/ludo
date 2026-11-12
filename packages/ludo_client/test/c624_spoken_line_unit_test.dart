// Unit proof for work/ludo/orders/624-spoken-line-live-region.md, contract
// decisions D1, D2, D3 and D5 (C-624): SpokenLineController and
// SpokenLineRegion in lib/src/spoken_line.dart.
//
// Written from the contract text alone. The file uses only the surface D1
// lists (kSpokenLineHold, kSpokenLineRegionKey, SpokenLineController.speak
// and .current, SpokenLineRegion(controller:)); it does not compile on a
// tree that lacks lib/src/spoken_line.dart, which is expected.
//
// How the region is observed: a real widget tree under a MaterialApp, with
// semantics switched on, and the semantics tree walked from its root. A
// node "carries the live-region flag" when `flagsCollection.isLiveRegion`
// is true. "Carries text" means label, value, hint or tooltip is non-empty.
// Time is flutter_test's fake clock only: every wait is a bounded
// `tester.pump(duration)`, never a real delay and never pumpAndSettle.
//
// Frame accounting used by every timing case: `speak` is called at fake
// time T with no frame in between; the first frame after it is a pump of
// zero duration (the "next frame"). Frames while time runs are pumped in
// 10 ms steps so a recorded frame sequence resolves a one-frame clear.
//
// Every failure message carries the scenario name and the step log (each
// speak and pump with the fake time it happened at). The cases are
// deterministic, there is no seed, so the scenario name plus its step log is
// the whole reproduction.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/spoken_line.dart';

const Duration _frame = Duration(milliseconds: 10);

/// One mounted scenario: the controller, the fake-time bookkeeping and the
/// step log every failure message carries.
class _Rig {
  _Rig(this.tester, this.name, this.controller);

  final WidgetTester tester;
  final String name;
  final SpokenLineController controller;
  final List<String> steps = <String>[];
  int ms = 0;

  String get why => 'scenario "$name"; steps: ${steps.join(' | ')}';

  void speak(String line) {
    steps.add('speak("$line")@${ms}ms');
    controller.speak(line);
  }

  /// A frame after [dms] of fake time (0 = the next frame, no time passes).
  Future<void> pump([int dms = 0]) async {
    ms += dms;
    steps.add('pump(${dms}ms)->${ms}ms');
    await tester.pump(Duration(milliseconds: dms));
  }

  /// Pumps frame by frame in 10 ms steps up to the fake time [untilMs],
  /// calling [each] after every frame with the time reached.
  Future<void> run(int untilMs, [void Function(int atMs)? each]) async {
    while (ms < untilMs) {
      final int step = (untilMs - ms) < _frame.inMilliseconds
          ? untilMs - ms
          : _frame.inMilliseconds;
      await pump(step);
      each?.call(ms);
    }
  }

  List<SemanticsNode> _all() {
    final SemanticsNode? root = tester
        .binding
        .renderViews
        .first
        .owner
        ?.semanticsOwner
        ?.rootSemanticsNode;
    final List<SemanticsNode> out = <SemanticsNode>[];
    void walk(SemanticsNode node) {
      out.add(node);
      node.visitChildren((SemanticsNode child) {
        walk(child);
        return true;
      });
    }

    if (root != null) {
      walk(root);
    }
    return out;
  }

  static List<String> _texts(SemanticsNode n) => <String>[
    n.label,
    n.value,
    n.hint,
    n.tooltip,
  ].where((String s) => s.isNotEmpty).toList();

  List<SemanticsNode> live() => _all()
      .where((SemanticsNode n) => n.flagsCollection.isLiveRegion)
      .toList();

  /// Labels of every live-region node, in tree order.
  List<String> liveLabels() =>
      live().map((SemanticsNode n) => n.label).toList();

  /// Every node (live-region or not) whose text contains [word].
  List<SemanticsNode> carrying(String word) => _all()
      .where((SemanticsNode n) => _texts(n).any((String t) => t.contains(word)))
      .toList();

  /// Every node that carries any text at all.
  List<SemanticsNode> anyText() =>
      _all().where((SemanticsNode n) => _texts(n).isNotEmpty).toList();

  /// Expects exactly one live-region node, labelled exactly [line], and no
  /// other node carrying [line].
  void expectShowing(String line, String what, {bool checkCurrent = true}) {
    expect(
      liveLabels(),
      <String>[line],
      reason:
          '$what: expected exactly one live-region node labelled "$line"; '
          'got ${liveLabels()}; $why',
    );
    expect(
      carrying(line).length,
      1,
      reason:
          '$what: expected the live-region node to be the only node carrying '
          '"$line"; got ${carrying(line).length}; $why',
    );
    if (!checkCurrent) {
      return;
    }
    expect(
      controller.current,
      line,
      reason:
          '$what: expected controller.current "$line"; got '
          '"${controller.current}"; $why',
    );
  }

  /// Expects no live-region node and no node carrying any of [words].
  void expectNothing(String what, [List<String> words = const <String>[]]) {
    expect(
      live(),
      isEmpty,
      reason: '$what: expected no live-region node; got ${liveLabels()}; $why',
    );
    for (final String w in words) {
      expect(
        carrying(w),
        isEmpty,
        reason:
            '$what: expected no node carrying "$w"; got '
            '${carrying(w).map((SemanticsNode n) => n.label).toList()}; $why',
      );
    }
    expect(
      controller.current,
      '',
      reason:
          '$what: expected controller.current ""; got '
          '"${controller.current}"; $why',
    );
  }
}

Widget _app(Widget home, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

typedef _Wrap = Widget Function(Widget region);
typedef _Body = Future<void> Function(_Rig rig);

Widget _plain(Widget region) => Stack(children: <Widget>[region]);

/// Mounts a SpokenLineRegion for a fresh controller inside [wrap], runs
/// [body], then unmounts before disposing so no timer or listener outlives
/// the scenario.
Future<void> _scenario(
  WidgetTester tester,
  String name,
  _Body body, {
  _Wrap wrap = _plain,
  Locale locale = const Locale('en'),
}) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  final SpokenLineController controller = SpokenLineController();
  final _Rig rig = _Rig(tester, name, controller);
  try {
    await tester.pumpWidget(
      _app(wrap(SpokenLineRegion(controller: controller)), locale: locale),
    );
    rig.steps.add('mounted locale=${locale.languageCode}');
    await rig.pump();
    await body(rig);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    handle.dispose();
  }
}

void main() {
  const int hold = 1500;

  // =========================================================================
  // D1: the public surface.
  // =========================================================================
  group('D1 surface', () {
    // Kills a hold constant with any other value.
    test('kSpokenLineHold is 1500 ms', () {
      expect(
        kSpokenLineHold,
        const Duration(milliseconds: 1500),
        reason: 'D1: kSpokenLineHold is 1500 ms; got $kSpokenLineHold',
      );
    });

    // Kills a region that is not keyed kSpokenLineRegionKey, or a constant
    // with another value.
    testWidgets('the region root carries kSpokenLineRegionKey, once', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'D1-key', (_Rig r) async {
        expect(
          find.byKey(kSpokenLineRegionKey),
          findsOneWidget,
          reason: 'D1: one widget keyed kSpokenLineRegionKey; ${r.why}',
        );
        expect(
          find.byType(SpokenLineRegion),
          findsOneWidget,
          reason: 'D1: one SpokenLineRegion; ${r.why}',
        );
      });
    });

    // Kills a controller that starts out holding a line.
    testWidgets('a new controller holds nothing', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      expect(
        c.current,
        '',
        reason: 'D1: current is "" when nothing is held; got "${c.current}"',
      );
      c.dispose();
    });
  });

  // =========================================================================
  // (a) one line: shown on the next frame, gone after the hold.
  // =========================================================================
  group('(a) one line', () {
    // Kills a region that needs more than one frame, labels the wrong text,
    // sets the flag on more than one node, or never clears.
    testWidgets('speak alpha: one live node on the next frame, none after '
        'the hold plus a frame', (WidgetTester tester) async {
      await _scenario(tester, 'a-alpha', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        r.expectShowing('alpha', '(a) next frame');
        await r.pump(hold - 1);
        r.expectShowing('alpha', '(a) 1 ms before the hold ends');
        await r.pump(1);
        await r.pump();
        r.expectNothing('(a) hold plus a frame', <String>['alpha']);
      });
    });

    // Kills a hold that is wrong in the other direction (cleared at once, or
    // at 750 ms) with a mid-hold sample.
    testWidgets('alpha is still there at 750 ms and at 1400 ms', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'a-midhold', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.pump(750);
        r.expectShowing('alpha', '(a) 750 ms');
        await r.pump(650);
        r.expectShowing('alpha', '(a) 1400 ms');
      });
    });

    // Kills a region that leaves the line in place after the first hold
    // and so never lets a later line start from empty.
    testWidgets('a line spoken after the first one cleared shows at once '
        'and clears on its own hold', (WidgetTester tester) async {
      await _scenario(tester, 'a-again-after-clear', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.pump(hold);
        await r.pump();
        r.expectNothing('(a) first hold over', <String>['alpha']);
        r.speak('alpha');
        await r.pump();
        r.expectShowing('alpha', '(a) the same line after a clear');
        await r.pump(hold - 1);
        r.expectShowing('alpha', '(a) second hold, 1 ms before the end');
        await r.pump(1);
        await r.pump();
        r.expectNothing('(a) second hold over', <String>['alpha']);
      });
    });
  });

  // =========================================================================
  // (b) D2: nothing at all while empty.
  // =========================================================================
  group('(b) D2 empty means no node', () {
    // Kills a region that always builds a live node with an empty label.
    testWidgets('before any speak: no live node and no text', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'b-before-speak', (_Rig r) async {
        r.expectNothing('(b) before any speak');
        expect(
          r.anyText(),
          isEmpty,
          reason:
              '(b) D2: no node carries any text before a speak; got '
              '${r.anyText().map((SemanticsNode n) => n.label).toList()}; '
              '${r.why}',
        );
      });
    });

    // Kills a region that leaves a stale label or a flagged empty node
    // behind after the clear.
    testWidgets('after a clear: no live node and no text', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'b-after-clear', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.pump(hold);
        await r.pump();
        r.expectNothing('(b) after the clear', <String>['alpha']);
        expect(
          r.anyText(),
          isEmpty,
          reason:
              '(b) D2: no node carries any text after the clear; got '
              '${r.anyText().map((SemanticsNode n) => n.label).toList()}; '
              '${r.why}',
        );
        // Frames keep coming; the empty state is stable, not a blink.
        await r.run(r.ms + 200);
        r.expectNothing('(b) 200 ms after the clear', <String>['alpha']);
      });
    });

    // Kills a speak of a line that was swallowed by the empty-state guard
    // only on the first call.
    testWidgets('a line, a clear, another line: the empty state between '
        'them has no node', (WidgetTester tester) async {
      await _scenario(tester, 'b-between', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.pump(hold);
        await r.pump();
        r.expectNothing('(b) between lines', <String>['alpha', 'bravo']);
        r.speak('bravo');
        await r.pump();
        r.expectShowing('bravo', '(b) second line');
        await r.pump(hold);
        await r.pump();
        r.expectNothing('(b) after the second line', <String>['bravo']);
      });
    });
  });

  // =========================================================================
  // (c) D3: the same line again must be a change the screen reader can hear.
  // =========================================================================
  group('(c) D3 the same line again', () {
    // Kills a region that, for the same text, does nothing (the repeat is
    // lost), or one that swaps text without a frame in between.
    testWidgets('alpha, 500 ms, alpha: a frame with no alpha sits between '
        'two alpha runs, and the hold ends 1500 ms after the second speak', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'c-same-line', (_Rig r) async {
        final List<(int, String)> frames = <(int, String)>[];
        String shown() => r.liveLabels().join('|');

        r.speak('alpha');
        await r.pump();
        frames.add((r.ms, shown()));
        await r.run(500, (int at) => frames.add((at, shown())));
        final int startAfter = frames.length;
        r.speak('alpha');
        await r.pump();
        frames.add((r.ms, shown()));
        const int secondSpeakAt = 500;
        await r.run(
          secondSpeakAt + hold + 100,
          (int at) => frames.add((at, shown())),
        );

        // Collapse into runs of equal consecutive values.
        final List<String> runs = <String>[];
        for (final (int, String) f in frames) {
          if (runs.isEmpty || runs.last != f.$2) {
            runs.add(f.$2);
          }
        }
        expect(
          runs,
          <String>['alpha', '', 'alpha', ''],
          reason:
              '(c) D3: expected the region labels over the frames to run '
              'alpha, (a frame with none), alpha, then clear; got $runs; '
              'frames=$frames; ${r.why}',
        );

        // The empty run starts on the first or second frame after the
        // second speak and is at most three frames long; the second alpha
        // then runs to 1500 ms after the second speak.
        final List<(int, String)> after = frames.sublist(startAfter);
        final int emptyFrom = after.indexWhere(
          ((int, String) f) => f.$2.isEmpty,
        );
        expect(
          emptyFrom,
          inInclusiveRange(0, 1),
          reason:
              '(c) D3: expected the empty frame on the first or second frame '
              'after the second speak; first empty frame index $emptyFrom; '
              'frames after the speak=$after; ${r.why}',
        );
        final int endAt = secondSpeakAt + hold;
        int emptyRun = 0;
        for (int i = emptyFrom; i < after.length && after[i].$2.isEmpty; i++) {
          emptyRun += 1;
        }
        expect(
          emptyRun,
          lessThanOrEqualTo(3),
          reason:
              '(c) D3: the clear lasts a frame or two, not a pause; the '
              'empty run was $emptyRun frames; frames after the speak='
              '$after; ${r.why}',
        );
        for (int i = emptyFrom + emptyRun; i < after.length; i++) {
          final (int, String) f = after[i];
          if (f.$1 < endAt) {
            expect(
              f.$2,
              'alpha',
              reason:
                  '(c) D3: expected alpha up to ${endAt - 1} ms (the hold '
                  'ends $hold ms after the second speak at $secondSpeakAt '
                  'ms); frame at ${f.$1} ms showed "${f.$2}"; '
                  'frames=$frames; ${r.why}',
            );
          } else {
            expect(
              f.$2,
              '',
              reason:
                  '(c) D3: expected the region clear from $endAt ms on; '
                  'frame at ${f.$1} ms showed "${f.$2}"; frames=$frames; '
                  '${r.why}',
            );
          }
        }
      });
    });

    // Kills a first timer that survives the second speak and clears the
    // second alpha early (at 1500 ms from the first speak).
    testWidgets('the first speak\'s timer does not clear the repeated '
        'line', (WidgetTester tester) async {
      await _scenario(tester, 'c-first-timer', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.run(500);
        r.speak('alpha');
        await r.pump();
        await r.pump(10);
        r.expectShowing('alpha', '(c) just after the repeat');
        // 1500 ms after the FIRST speak is 1000 ms after the second.
        await r.run(hold + 10);
        r.expectShowing(
          'alpha',
          '(c) the first speak\'s deadline (${hold + 10} ms)',
        );
      });
    });

    // Kills a repeat that only works once: three identical lines in a row
    // are three audible changes.
    testWidgets('alpha three times, 300 ms apart: every repeat clears for a '
        'frame', (WidgetTester tester) async {
      await _scenario(tester, 'c-three', (_Rig r) async {
        final List<String> seen = <String>[];
        r.speak('alpha');
        await r.pump();
        seen.add(r.liveLabels().join('|'));
        for (int i = 0; i < 2; i++) {
          await r.run(
            r.ms + 300,
            (int _) => seen.add(r.liveLabels().join('|')),
          );
          r.speak('alpha');
          await r.run(r.ms + 40, (int _) => seen.add(r.liveLabels().join('|')));
        }
        final List<String> runs = <String>[];
        for (final String s in seen) {
          if (runs.isEmpty || runs.last != s) {
            runs.add(s);
          }
        }
        expect(
          runs,
          <String>['alpha', '', 'alpha', '', 'alpha'],
          reason:
              '(c) D3: three identical lines inside the hold must be three '
              'audible changes (alpha, empty, alpha, empty, alpha); got '
              '$runs; seen=$seen; ${r.why}',
        );
      });
    });
  });

  // =========================================================================
  // (d) D3: a different line replaces at once and restarts the hold.
  // =========================================================================
  group('(d) D3 a different line', () {
    // Kills a region that clears first (an empty frame between two
    // different lines), keeps the old line, or keeps the old deadline.
    testWidgets('alpha, 300 ms, bravo: bravo on the next frame, cleared '
        '1500 ms after bravo', (WidgetTester tester) async {
      await _scenario(tester, 'd-replace', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.run(300);
        r.expectShowing('alpha', '(d) before bravo');
        r.speak('bravo');
        await r.pump();
        r.expectShowing('bravo', '(d) the next frame after bravo');
        expect(
          r.carrying('alpha'),
          isEmpty,
          reason: '(d) no node still carries alpha; ${r.why}',
        );
        // alpha's own deadline (1200 ms from here) must not clear bravo.
        await r.pump(1190);
        r.expectShowing('bravo', '(d) at alpha\'s old deadline');
        await r.pump(309);
        r.expectShowing('bravo', '(d) 1 ms before bravo\'s deadline');
        await r.pump(1);
        await r.pump();
        r.expectNothing('(d) bravo\'s hold plus a frame', <String>[
          'alpha',
          'bravo',
        ]);
      });
    });

    // Kills a region that shows an empty frame between two different
    // lines: the swap is one frame, never a blink.
    testWidgets('alpha then bravo: no frame between them shows no line', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'd-no-blink', (_Rig r) async {
        final List<String> seen = <String>[];
        r.speak('alpha');
        await r.pump();
        seen.add(r.liveLabels().join('|'));
        await r.run(r.ms + 300, (int _) => seen.add(r.liveLabels().join('|')));
        r.speak('bravo');
        await r.pump();
        seen.add(r.liveLabels().join('|'));
        await r.run(r.ms + 100, (int _) => seen.add(r.liveLabels().join('|')));
        expect(
          seen.contains(''),
          isFalse,
          reason:
              '(d) D3: a different line replaces at once, so no frame '
              'between alpha and bravo may show no line; seen=$seen; '
              '${r.why}',
        );
        expect(
          seen.last,
          'bravo',
          reason: '(d) bravo is showing; seen=$seen; ${r.why}',
        );
      });
    });

    // Kills a "same as the last spoken" memory that treats alpha, bravo,
    // alpha as a repeat: alpha differs from what is held (bravo).
    testWidgets('alpha, bravo, alpha: the last alpha replaces bravo at once '
        'and is not a repeat', (WidgetTester tester) async {
      await _scenario(tester, 'd-abab', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.run(200);
        r.speak('bravo');
        await r.pump();
        await r.run(r.ms + 200);
        r.speak('alpha');
        await r.pump();
        r.expectShowing('alpha', '(d) alpha replaces bravo on the next frame');
        await r.pump(hold - 1);
        r.expectShowing('alpha', '(d) 1 ms before the hold ends');
        await r.pump(1);
        await r.pump();
        r.expectNothing('(d) hold over', <String>['alpha', 'bravo']);
      });
    });

    // C-629 D1: two different lines in one frame reach the region one per
    // frame, in the order spoken. Kills a region that drops the first line
    // or shows both on one frame.
    testWidgets('two different lines before any frame: the first is shown, '
        'then the second on the next frame, one node each', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'd-same-frame', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        await r.pump();
        // `current` already holds bravo: C-629 D1 sets it once this frame
        // has completed, and the region draws it on the next one.
        r.expectShowing(
          'alpha',
          '(d) two speaks in one frame, frame 1',
          checkCurrent: false,
        );
        expect(
          r.carrying('bravo'),
          isEmpty,
          reason: '(d) bravo is queued behind alpha; ${r.why}',
        );
        await r.pump();
        r.expectShowing('bravo', '(d) two speaks in one frame, frame 2');
        expect(
          r.carrying('alpha'),
          isEmpty,
          reason: '(d) alpha was replaced by bravo; ${r.why}',
        );
        await r.pump(hold);
        await r.pump();
        r.expectNothing('(d) hold over', <String>['alpha', 'bravo']);
      });
    });
  });

  // =========================================================================
  // (e) an empty line is ignored.
  // =========================================================================
  group('(e) the empty line', () {
    // Kills a speak('') that shows an empty live node, notifies, or starts
    // a timer.
    testWidgets('speak("") on an idle controller does nothing', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'e-idle', (_Rig r) async {
        int notified = 0;
        r.controller.addListener(() => notified += 1);
        r.speak('');
        await r.pump();
        r.expectNothing('(e) after speak("")');
        expect(
          notified,
          0,
          reason:
              '(e) D1: an empty line is ignored, so no listener is told; '
              'got $notified notifications; ${r.why}',
        );
        await r.pump(hold);
        r.expectNothing('(e) a hold later');
      });
    });

    // Kills a speak('') that clears a held line early, or restarts its
    // hold (the clear would then come later than 1500 ms from alpha).
    testWidgets('speak("") during a hold neither clears nor extends it', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'e-during-hold', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.run(1000);
        r.speak('');
        await r.pump();
        r.expectShowing('alpha', '(e) after speak("") mid-hold');
        await r.pump(499);
        r.expectShowing('alpha', '(e) 1 ms before the original deadline');
        await r.pump(1);
        await r.pump();
        r.expectNothing('(e) the original deadline, not a later one', <String>[
          'alpha',
        ]);
      });
    });
  });

  // =========================================================================
  // (f) D2: takes no space, paints nothing, takes no hit.
  // =========================================================================
  group('(f) D2 invisible and untouchable', () {
    // Proof of "takes no hit": the region is placed ABOVE a full-size tap
    // target in a StackFit.expand stack, so a region that did not ignore
    // pointers would sit over the whole target. A tap at the centre must
    // reach the target, empty, held, and held with a repeat in progress.
    testWidgets('a tap over the region reaches the widget below it', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      Widget wrap(Widget region) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps += 1,
            child: const SizedBox.expand(),
          ),
          region,
        ],
      );
      await _scenario(tester, 'f-hit', wrap: wrap, (_Rig r) async {
        final Offset centre = tester.getCenter(find.byType(GestureDetector));
        await tester.tapAt(centre);
        expect(
          taps,
          1,
          reason:
              '(f) tap while empty reached the target $taps times; ${r.why}',
        );
        r.speak('alpha');
        await r.pump();
        r.expectShowing('alpha', '(f) fixture: the line is held');
        for (final Offset p in <Offset>[
          centre,
          const Offset(3, 3),
          tester.getBottomRight(find.byType(GestureDetector)) -
              const Offset(3, 3),
        ]) {
          final int before = taps;
          await tester.tapAt(p);
          expect(
            taps,
            before + 1,
            reason:
                '(f) D2: a tap at $p while a line is held must reach the '
                'widget below the region; ${r.why}',
          );
        }
        // The hit-test path at the centre holds no render object that
        // belongs to the region's subtree.
        final HitTestResult result = tester.hitTestOnBinding(centre);
        final RenderObject regionRender = tester.renderObject(
          find.byKey(kSpokenLineRegionKey),
        );
        final List<RenderObject> inRegion = <RenderObject>[];
        for (final HitTestEntry<HitTestTarget> e in result.path) {
          final HitTestTarget t = e.target;
          if (t is RenderObject) {
            RenderObject? up = t;
            while (up != null) {
              if (identical(up, regionRender)) {
                inRegion.add(t);
                break;
              }
              up = up.parent;
            }
          }
        }
        expect(
          inRegion,
          isEmpty,
          reason:
              '(f) D2: the hit-test path at $centre must not contain a '
              'render object inside the region; got $inRegion; ${r.why}',
        );
      });
    });

    // Proof of "takes no space": under loose constraints (Align) the region
    // lays out no larger than one logical pixel on each axis, empty and
    // while a line is held. Not Size.zero: a node of exactly zero area is
    // dropped from the semantics tree by the framework, so a region that
    // must carry a live-region node cannot be exactly zero; one logical
    // pixel is the largest size no player can see or aim at.
    testWidgets('under loose constraints the region is at most 1 x 1 logical '
        'pixel, empty and held', (WidgetTester tester) async {
      Widget wrap(Widget region) => Align(child: region);
      await _scenario(tester, 'f-size', wrap: wrap, (_Rig r) async {
        final Finder region = find.byKey(kSpokenLineRegionKey);
        Size size = tester.getSize(region);
        expect(
          size.width <= 1 && size.height <= 1,
          isTrue,
          reason: '(f) D2: empty region size $size exceeds 1 x 1; ${r.why}',
        );
        r.speak('alpha');
        await r.pump();
        r.expectShowing('alpha', '(f) fixture: the line is held');
        size = tester.getSize(region);
        expect(
          size.width <= 1 && size.height <= 1,
          isTrue,
          reason: '(f) D2: held region size $size exceeds 1 x 1; ${r.why}',
        );
      });
    });

    // Proof of "paints nothing": the region is forced to fill a 100 x 100
    // box of one solid colour (StackFit.expand), a line is held, and every
    // pixel read back from the repaint boundary is still that colour.
    testWidgets('a held line paints nothing over a solid background', (
      WidgetTester tester,
    ) async {
      const Key boundaryKey = Key('c624-unit-boundary');
      const Color background = Color(0xFF336699);
      Widget wrap(Widget region) => Center(
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 100,
            height: 100,
            child: ColoredBox(
              color: background,
              child: Stack(fit: StackFit.expand, children: <Widget>[region]),
            ),
          ),
        ),
      );
      await _scenario(tester, 'f-paint', wrap: wrap, (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        r.expectShowing('alpha', '(f) fixture: the line is held');
        final RenderRepaintBoundary boundary = tester.renderObject(
          find.byKey(boundaryKey),
        );
        final ui.Image image = (await tester.runAsync(
          () => boundary.toImage(),
        ))!;
        final ByteData bytes = (await tester.runAsync<ByteData?>(
          () => image.toByteData(),
        ))!;
        final int expected = background.toARGB32();
        int off = 0;
        int firstOff = -1;
        for (int i = 0; i < bytes.lengthInBytes; i += 4) {
          final int argb =
              (bytes.getUint8(i + 3) << 24) |
              (bytes.getUint8(i) << 16) |
              (bytes.getUint8(i + 1) << 8) |
              bytes.getUint8(i + 2);
          if (argb != expected) {
            off += 1;
            if (firstOff < 0) {
              firstOff = i ~/ 4;
            }
          }
        }
        expect(
          off,
          0,
          reason:
              '(f) D2: the region paints nothing; $off of '
              '${image.width * image.height} pixels differ from '
              '0x${expected.toRadixString(16)} (first at pixel $firstOff); '
              '${r.why}',
        );
      });
    });
  });

  // =========================================================================
  // (g) the controller owns its timer.
  // =========================================================================
  group('(g) dispose cancels the hold', () {
    // Kills a controller whose hold timer outlives dispose: the framework
    // fails a test that ends with a pending timer, and a later pump would
    // notify a disposed notifier.
    testWidgets('dispose during a hold leaves no pending timer', (
      WidgetTester tester,
    ) async {
      final SpokenLineController c = SpokenLineController();
      await tester.pumpWidget(
        _app(Stack(children: <Widget>[SpokenLineRegion(controller: c)])),
      );
      c.speak('alpha');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      // Time past the old deadline: nothing may fire into the disposed
      // controller.
      await tester.pump(const Duration(milliseconds: 2000));
      expect(
        tester.takeException(),
        isNull,
        reason:
            'scenario "g-dispose-in-hold": speak(alpha), 500 ms, unmount, '
            'dispose, 2000 ms: expected no exception from a late timer',
      );
    });

    // Kills a controller that arms a second timer for the clear-then-show
    // of a repeated line and forgets to cancel it on dispose.
    testWidgets('dispose in the middle of a repeat (clear-then-show) leaves '
        'no pending timer', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      await tester.pumpWidget(
        _app(Stack(children: <Widget>[SpokenLineRegion(controller: c)])),
      );
      c.speak('alpha');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      c.speak('alpha');
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      await tester.pump(const Duration(milliseconds: 2000));
      expect(
        tester.takeException(),
        isNull,
        reason:
            'scenario "g-dispose-in-repeat": speak(alpha), 500 ms, '
            'speak(alpha), unmount, dispose, 2000 ms: expected no '
            'exception from a late timer',
      );
    });

    // Kills a controller whose first line (never rendered by a frame) still
    // owns a timer after dispose.
    testWidgets('dispose right after a speak, before any frame, leaves no '
        'pending timer', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      c.speak('alpha');
      c.dispose();
      await tester.pump(const Duration(milliseconds: 2000));
      expect(
        tester.takeException(),
        isNull,
        reason:
            'scenario "g-dispose-no-frame": speak(alpha), dispose, 2000 ms: '
            'expected no exception from a late timer',
      );
    });
  });

  // =========================================================================
  // D5: the region's semantics carry the screen's text direction.
  // =========================================================================
  group('D5 direction', () {
    // Kills a region that forces ltr, or drops the direction (the Arabic
    // line was spoken once only with RTL).
    for (final (String code, String line, TextDirection dir)
        in <(String, String, TextDirection)>[
          ('en', 'Karim joined', TextDirection.ltr),
          ('ar', 'انضمّ Karim', TextDirection.rtl),
        ]) {
      testWidgets('$code: the live node carries ${dir.name}', (
        WidgetTester tester,
      ) async {
        await _scenario(tester, 'D5-$code', locale: Locale(code), (
          _Rig r,
        ) async {
          r.speak(line);
          await r.pump();
          r.expectShowing(line, 'D5 $code');
          expect(
            r.live().single.textDirection,
            dir,
            reason:
                'D5: expected the live node text direction ${dir.name} '
                'under locale $code; got '
                '${r.live().single.textDirection}; ${r.why}',
          );
        });
      });
    }
  });
}
