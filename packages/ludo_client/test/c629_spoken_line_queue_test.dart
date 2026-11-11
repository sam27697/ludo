// Queue proof for work/ludo/orders/629-spoken-lines-a-frame-apart.md, contract
// decisions D1 to D4 (C-629): SpokenLineController.speak queues a line spoken
// in the same frame as another line, and the region shows one line per frame,
// in the order they were spoken, never dropping and never reordering.
//
// Written from the contract text alone. Only the surface the contract names
// is used: kSpokenLineHold, SpokenLineController.speak / .current / .dispose,
// SpokenLineRegion(controller:).
//
// How the region is observed: a real widget tree under a MaterialApp with
// semantics switched on, the semantics tree walked from its root, and the
// live-region node's label read after each frame. A frame is a
// `tester.pump()` of zero duration; time moves only through a bounded
// `tester.pump(duration)` on the fake clock. No pumpAndSettle, no real delay.
//
// Frame accounting: "the same frame" means no frame has completed between two
// `speak` calls. The first frame after a speak is the next zero-duration pump.
//
// Round 2 adds D6 (cases (i) and (j)): a queued line whose speak call is more
// than kSpokenLineHold old when its turn comes is dropped. The age is read
// from the controller's injectable clock, `SpokenLineController(clock: () =>
// DateTime)`, with `clock` of type `DateTime Function()`. The constructor is
// reached through Function.apply so the rest of this file still compiles and
// runs against a controller that has no such parameter.
//
// Every failure message names the scenario and carries the step log (each
// speak and pump with the fake time it happened at). The cases are
// deterministic, so there is no seed: the scenario name plus its step log is
// the whole reproduction.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/spoken_line.dart';

import 'support/roll_tray_harness.dart';

const int _hold = 1500;

/// The fake wall clock handed to the controller. It moves with every timed
/// pump of a rig that owns it, and by itself through [_Rig.advanceClock]
/// (time passing while no frame runs, as with the app in the background).
class _Clock {
  final DateTime base = DateTime.utc(2026, 11, 11, 12);
  int ms = 0;

  DateTime now() => base.add(Duration(milliseconds: ms));
}

/// A controller built with the clock parameter, through Function.apply so a
/// constructor without it still lets this file compile.
SpokenLineController _controllerWith(_Clock clock) {
  final DateTime Function() read = clock.now;
  try {
    return Function.apply(
      SpokenLineController.new,
      const <Object?>[],
      <Symbol, Object?>{#clock: read},
    ) as SpokenLineController;
  } on NoSuchMethodError catch (e) {
    fail(
      'D6: expected SpokenLineController(clock: () => DateTime) to be '
      'accepted; the constructor refused the named argument: $e',
    );
  }
}

/// One mounted scenario: the controller, the fake-time bookkeeping and the
/// step log every failure message carries.
class _Rig {
  _Rig(this.tester, this.name, this.controller, [this.clock]);

  final WidgetTester tester;
  final String name;
  final SpokenLineController controller;
  final _Clock? clock;
  final List<String> steps = <String>[];
  int ms = 0;

  String get why =>
      'scenario "$name" (deterministic, no seed); steps: '
      '${steps.join(' | ')}';

  void speak(String line) {
    steps.add('speak("$line")@${ms}ms');
    controller.speak(line);
  }

  /// Wall-clock time passes with no frame pumped and no fake timer firing.
  void advanceClock(int dms) {
    clock!.ms += dms;
    steps.add('clock+${dms}ms (no frame)->${clock!.ms}ms');
  }

  /// One frame after [dms] of fake time (0 = the next frame, no time passes).
  Future<void> pump([int dms = 0]) async {
    ms += dms;
    clock?.ms += dms;
    steps.add('pump(${dms}ms)->${ms}ms');
    await tester.pump(Duration(milliseconds: dms));
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

  /// The labels of every live-region node, joined; '' when there is none.
  String shown() => _all()
      .where((SemanticsNode n) => n.flagsCollection.isLiveRegion)
      .map((SemanticsNode n) => n.label)
      .join('|');

  /// Pumps [n] zero-duration frames, returning what the region showed after
  /// each of them.
  Future<List<String>> frames(int n) async {
    final List<String> out = <String>[];
    for (int i = 0; i < n; i++) {
      await pump();
      out.add(shown());
    }
    return out;
  }

  /// Consecutive equal values collapsed into one.
  static List<String> runs(List<String> frames) {
    final List<String> out = <String>[];
    for (final String f in frames) {
      if (out.isEmpty || out.last != f) {
        out.add(f);
      }
    }
    return out;
  }

  void expectShown(String line, String what) {
    expect(
      shown(),
      line,
      reason:
          '$what: expected the region to show "$line"; got "${shown()}"; '
          '$why',
    );
    // What the region drew on this frame is the contract. `current` may
    // already hold the next queued line: D1 sets it once the frame that drew
    // this one has completed, which is inside the same pump.
  }
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('en'),
    supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: home,
  );
}

Future<void> _scenario(
  WidgetTester tester,
  String name,
  Future<void> Function(_Rig rig) body, {
  Widget Function(Widget region)? wrap,
  _Clock? clock,
}) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  final SpokenLineController controller = clock == null
      ? SpokenLineController()
      : _controllerWith(clock);
  final _Rig rig = _Rig(tester, name, controller, clock);
  try {
    final Widget region = SpokenLineRegion(controller: controller);
    await tester.pumpWidget(
      _app(wrap == null ? Stack(children: <Widget>[region]) : wrap(region)),
    );
    rig.steps.add('mounted');
    await rig.pump();
    await body(rig);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    handle.dispose();
  }
}

void main() {
  // =========================================================================
  // (a) two different lines in one frame.
  // =========================================================================
  group('(a) two different lines in one frame', () {
    testWidgets('frame 1 shows line 1, frame 2 shows line 2', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'a-two', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        await r.pump();
        r.expectShown('alpha', '(a) frame 1');
        await r.pump();
        r.expectShown('bravo', '(a) frame 2');
        await r.pump();
        r.expectShown('bravo', '(a) frame 3 is still bravo, nothing extra');
      });
    });

    testWidgets('every frame shows exactly one line and none shows the '
        'two together', (WidgetTester tester) async {
      await _scenario(tester, 'a-one-at-a-time', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        final List<String> seen = await r.frames(4);
        expect(
          seen,
          <String>['alpha', 'bravo', 'bravo', 'bravo'],
          reason:
              '(a) expected alpha then bravo and then bravo held; got '
              '$seen; ${r.why}',
        );
      });
    });

    testWidgets('each line is set once: controller.current follows the '
        'frames', (WidgetTester tester) async {
      await _scenario(tester, 'a-current', (_Rig r) async {
        final List<String> currents = <String>[];
        r.controller.addListener(() => currents.add(r.controller.current));
        r.speak('alpha');
        r.speak('bravo');
        expect(
          r.controller.current,
          'alpha',
          reason:
              '(a) D1: the second line of a frame is queued, not set; '
              'expected current "alpha" straight after both speaks; got '
              '"${r.controller.current}"; ${r.why}',
        );
        await r.frames(4);
        expect(
          currents.where((String c) => c.isNotEmpty).toList(),
          <String>['alpha', 'bravo'],
          reason:
              '(a) D1: expected the controller to set alpha then bravo, '
              'once each and nothing else; got $currents; ${r.why}',
        );
      });
    });
  });

  // =========================================================================
  // (b) three lines in one frame, and the hold from the LAST set.
  // =========================================================================
  group('(b) three lines in one frame', () {
    testWidgets('one per frame, in order', (WidgetTester tester) async {
      await _scenario(tester, 'b-order', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('charlie');
        final List<String> seen = await r.frames(4);
        expect(
          seen,
          <String>['alpha', 'bravo', 'charlie', 'charlie'],
          reason:
              '(b) D1: expected alpha, bravo, charlie on three frames '
              'and then charlie held; got $seen; ${r.why}',
        );
      });
    });

    // The hold must run from the moment charlie was set (after the second
    // frame), not from the first speak. Frame 2 sits 400 ms after frame 1, so
    // charlie is set at 400 ms and its hold ends at 1900 ms. A hold counted
    // from the first speak ends at 1500 ms and is caught by the 1800 ms read.
    testWidgets('empty 1.5 s after line 3 was set, not after the first '
        'speak: still line 3 at 1.4 s after it, empty at 1.6 s', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'b-hold-from-last', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('charlie');
        await r.pump();
        r.expectShown('alpha', '(b) frame 1');
        await r.pump(400);
        r.expectShown('bravo', '(b) frame 2 at 400 ms');
        await r.pump();
        r.expectShown('charlie', '(b) frame 3, set at 400 ms');
        await r.pump(1400);
        r.expectShown('charlie', '(b) 1.4 s after charlie was set (1800 ms)');
        await r.pump(200);
        await r.pump();
        expect(
          r.shown(),
          '',
          reason:
              '(b) D2: expected the region empty 1.6 s after charlie was '
              'set (2000 ms); got "${r.shown()}"; ${r.why}',
        );
        expect(
          r.controller.current,
          '',
          reason:
              '(b) D2: expected controller.current "" at 2000 ms; got '
              '"${r.controller.current}"; ${r.why}',
        );
      });
    });

    testWidgets('boundary: charlie holds to 1499 ms after it was set and '
        'is gone at 1500 ms plus a frame', (WidgetTester tester) async {
      await _scenario(tester, 'b-hold-boundary', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('charlie');
        await r.pump();
        await r.pump(400);
        await r.pump();
        r.expectShown('charlie', '(b) charlie set at 400 ms');
        await r.pump(_hold - 1);
        r.expectShown('charlie', '(b) 1 ms before charlie\'s deadline');
        await r.pump(1);
        await r.pump();
        expect(
          r.shown(),
          '',
          reason:
              '(b) D2: expected the region empty exactly $_hold ms after '
              'charlie was set; got "${r.shown()}"; ${r.why}',
        );
      });
    });

    // Kills a queue that leaves the first line's timer armed: it would clear
    // the region at 1500 ms from the first speak, in the middle of charlie.
    testWidgets('the first line\'s hold does not clear a later line of the '
        'run', (WidgetTester tester) async {
      await _scenario(tester, 'b-stale-timer', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('charlie');
        await r.pump();
        await r.pump(900);
        await r.pump();
        r.expectShown('charlie', '(b) charlie set at 900 ms');
        final List<String> seen = <String>[];
        for (int i = 0; i < 6; i++) {
          await r.pump(100);
          seen.add(r.shown());
        }
        expect(
          seen,
          everyElement('charlie'),
          reason:
              '(b) D2: charlie was set at 900 ms, so it is held until '
              '2400 ms; read at 1000..1500 ms after the first speak: $seen; '
              '${r.why}',
        );
      });
    });
  });

  // =========================================================================
  // (c) a speak from inside the persistent-callbacks phase or a post-frame
  //     callback, then another in the same frame.
  // =========================================================================
  group('(c) speak while a frame is being produced', () {
    testWidgets('two speaks from one post-frame callback: both shown, in '
        'order', (WidgetTester tester) async {
      await _scenario(tester, 'c-post-frame', (_Rig r) async {
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          r.speak('alpha');
          r.speak('bravo');
        });
        WidgetsBinding.instance.scheduleFrame();
        await r.pump(); // the frame whose post-frame phase speaks
        final List<String> seen = await r.frames(4);
        expect(
          _Rig.runs(seen),
          <String>['alpha', 'bravo'],
          reason:
              '(c) D1: two speaks from a post-frame callback must reach '
              'the region as alpha then bravo; frames after it: $seen; '
              '${r.why}',
        );
        expect(
          seen.first,
          'alpha',
          reason:
              '(c) D1: alpha is on the first frame after the callback; '
              'frames: $seen; ${r.why}',
        );
        expect(
          seen[1],
          'bravo',
          reason:
              '(c) D1: bravo is on the very next frame; frames: $seen; '
              '${r.why}',
        );
      });
    });

    testWidgets('two speaks from a persistent frame callback: both shown, '
        'in order', (WidgetTester tester) async {
      await _scenario(tester, 'c-persistent', (_Rig r) async {
        bool armed = true;
        SchedulerBinding.instance.addPersistentFrameCallback((Duration _) {
          if (!armed) {
            return;
          }
          armed = false;
          r.speak('alpha');
          r.speak('bravo');
        });
        try {
          SchedulerBinding.instance.scheduleFrame();
          await r.pump(); // the frame whose persistent phase speaks
          expect(
            armed,
            isFalse,
            reason:
                '(c) fixture: the persistent callback must have run; '
                '${r.why}',
          );
          final List<String> seen = await r.frames(4);
          expect(
            seen.take(2).toList(),
            <String>['alpha', 'bravo'],
            reason:
                '(c) D1: two speaks from the persistent-callbacks phase '
                'must reach the region as alpha then bravo on consecutive '
                'frames; frames after it: $seen; ${r.why}',
          );
        } finally {
          armed = false;
        }
      });
    });

    testWidgets('three speaks from a post-frame callback, one at a time: '
        'in order, one per frame', (WidgetTester tester) async {
      await _scenario(tester, 'c-post-frame-three', (_Rig r) async {
        WidgetsBinding.instance.addPostFrameCallback((Duration _) {
          r.speak('alpha');
          r.speak('bravo');
          r.speak('charlie');
        });
        WidgetsBinding.instance.scheduleFrame();
        await r.pump();
        final List<String> seen = await r.frames(4);
        expect(
          seen,
          <String>['alpha', 'bravo', 'charlie', 'charlie'],
          reason:
              '(c) D1: alpha, bravo, charlie one per frame; got $seen; '
              '${r.why}',
        );
      });
    });

    // The build form. A speak made while a build is running must not throw and
    // must still deliver the lines in order, one per frame.
    testWidgets('two speaks from inside a build: no error, both shown, in '
        'order', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<String> steps = <String>[];
      bool spoken = false;
      String shown() {
        final SemanticsNode? root = tester
            .binding
            .renderViews
            .first
            .owner
            ?.semanticsOwner
            ?.rootSemanticsNode;
        final List<String> labels = <String>[];
        void walk(SemanticsNode n) {
          if (n.flagsCollection.isLiveRegion) {
            labels.add(n.label);
          }
          n.visitChildren((SemanticsNode k) {
            walk(k);
            return true;
          });
        }

        if (root != null) {
          walk(root);
        }
        return labels.join('|');
      }

      Widget app({required bool speakNow}) => _app(
        Stack(
          children: <Widget>[
            SpokenLineRegion(controller: c),
            Builder(
              builder: (BuildContext context) {
                if (speakNow && !spoken) {
                  spoken = true;
                  steps.add('speak alpha, bravo inside build');
                  c.speak('alpha');
                  c.speak('bravo');
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      );
      try {
        await tester.pumpWidget(app(speakNow: false));
        steps.add('mounted');
        await tester.pumpWidget(app(speakNow: true));
        steps.add('rebuilt with the speaking builder');
        expect(
          tester.takeException(),
          isNull,
          reason:
              '(c) D1: a speak from inside a build must not raise; '
              'scenario "c-build"; steps: ${steps.join(' | ')}',
        );
        final List<String> seen = <String>[shown()];
        for (int i = 0; i < 4; i++) {
          await tester.pump();
          seen.add(shown());
        }
        expect(
          _Rig.runs(seen.where((String s) => s.isNotEmpty).toList()),
          <String>['alpha', 'bravo'],
          reason:
              '(c) D1: expected alpha then bravo, each on its own frame; '
              'frames: $seen; scenario "c-build"; steps: ${steps.join(' | ')}',
        );
        expect(
          seen.contains('alpha'),
          isTrue,
          reason:
              '(c) D1: alpha was never shown; frames: $seen; scenario '
              '"c-build"; steps: ${steps.join(' | ')}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        handle.dispose();
      }
    });
  });

  // =========================================================================
  // (d) the repeat rule, unchanged (C-624), and its queued form (D3).
  // =========================================================================
  group('(d) a repeated line', () {
    testWidgets('alpha, then alpha again in a later frame: the region '
        'clears for a frame and shows alpha again', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'd-later-frame', (_Rig r) async {
        final List<String> seen = <String>[];
        r.speak('alpha');
        await r.pump();
        seen.add(r.shown());
        await r.pump(500);
        seen.add(r.shown());
        r.speak('alpha');
        for (int i = 0; i < 4; i++) {
          await r.pump(10);
          seen.add(r.shown());
        }
        expect(
          _Rig.runs(seen),
          <String>['alpha', '', 'alpha'],
          reason:
              '(d) C-624 D3: expected alpha, a frame with none, alpha; '
              'got ${_Rig.runs(seen)}; frames: $seen; ${r.why}',
        );
        expect(
          seen.where((String s) => s.isEmpty).length,
          lessThanOrEqualTo(2),
          reason:
              '(d) the clear lasts a frame or two, not a pause; frames: '
              '$seen; ${r.why}',
        );
        // The hold restarts at the repeat (500 ms), ending at 2000 ms.
        await r.pump(1400);
        r.expectShown('alpha', '(d) 1.4 s after the repeat');
        await r.pump(200);
        await r.pump();
        expect(
          r.shown(),
          '',
          reason:
              '(d) expected the region empty 1.6 s after the repeat; '
              'got "${r.shown()}"; ${r.why}',
        );
      });
    });

    testWidgets('alpha, alpha in one frame: alpha, a clear, alpha, once '
        'each', (WidgetTester tester) async {
      await _scenario(tester, 'd-queued-repeat', (_Rig r) async {
        r.speak('alpha');
        r.speak('alpha');
        final List<String> seen = await r.frames(6);
        expect(
          _Rig.runs(seen),
          <String>['alpha', '', 'alpha'],
          reason:
              '(d) D3: a queued line equal to the line before it clears '
              'the region for a frame and is set again; got '
              '${_Rig.runs(seen)}; frames: $seen; ${r.why}',
        );
        expect(
          seen.first,
          'alpha',
          reason: '(d) D1: alpha on the first frame; frames: $seen; ${r.why}',
        );
        expect(
          seen.where((String s) => s.isEmpty).length,
          lessThanOrEqualTo(2),
          reason:
              '(d) the clear lasts a frame or two; frames: $seen; '
              '${r.why}',
        );
      });
    });

    testWidgets('alpha, bravo, bravo in one frame: alpha, bravo, a clear, '
        'bravo', (WidgetTester tester) async {
      await _scenario(tester, 'd-queued-repeat-tail', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('bravo');
        final List<String> seen = await r.frames(7);
        expect(
          _Rig.runs(seen),
          <String>['alpha', 'bravo', '', 'bravo'],
          reason:
              '(d) D3: the repeat of the queued bravo clears for a frame '
              'and is set again; got ${_Rig.runs(seen)}; frames: $seen; '
              '${r.why}',
        );
        expect(
          seen.take(2).toList(),
          <String>['alpha', 'bravo'],
          reason:
              '(d) D1: alpha then bravo on the first two frames; frames: '
              '$seen; ${r.why}',
        );
      });
    });

    testWidgets('alpha, alpha, bravo in one frame: nothing lost, order '
        'kept', (WidgetTester tester) async {
      await _scenario(tester, 'd-queued-repeat-mid', (_Rig r) async {
        r.speak('alpha');
        r.speak('alpha');
        r.speak('bravo');
        final List<String> seen = await r.frames(8);
        expect(
          _Rig.runs(seen),
          <String>['alpha', '', 'alpha', 'bravo'],
          reason:
              '(d) D1 and D3: alpha, the repeat of alpha, bravo; got '
              '${_Rig.runs(seen)}; frames: $seen; ${r.why}',
        );
      });
    });

    testWidgets('alpha three times in one frame: three audible alphas', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'd-triple', (_Rig r) async {
        r.speak('alpha');
        r.speak('alpha');
        r.speak('alpha');
        final List<String> seen = await r.frames(10);
        expect(
          _Rig.runs(seen),
          <String>['alpha', '', 'alpha', '', 'alpha'],
          reason:
              '(d) D3: three identical lines are three audible changes; '
              'got ${_Rig.runs(seen)}; frames: $seen; ${r.why}',
        );
      });
    });
  });

  // =========================================================================
  // (e) A, B, A in one frame.
  // =========================================================================
  group('(e) alpha, bravo, alpha in one frame', () {
    testWidgets('alpha, bravo, alpha over three frames, no clear between '
        'them', (WidgetTester tester) async {
      await _scenario(tester, 'e-aba', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('alpha');
        await r.pump();
        r.expectShown('alpha', '(e) frame 1');
        await r.pump();
        r.expectShown('bravo', '(e) frame 2');
        await r.pump();
        r.expectShown('alpha', '(e) frame 3');
        await r.pump();
        r.expectShown('alpha', '(e) frame 4 holds the last alpha');
      });
    });

    testWidgets('the last alpha is held 1.5 s from when it was set', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'e-aba-hold', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('alpha');
        await r.pump();
        await r.pump(300);
        await r.pump();
        r.expectShown('alpha', '(e) last alpha, set at 300 ms');
        await r.pump(_hold - 1);
        r.expectShown('alpha', '(e) 1 ms before the deadline');
        await r.pump(1);
        await r.pump();
        expect(
          r.shown(),
          '',
          reason:
              '(e) D2: expected empty $_hold ms after the last line was '
              'set; got "${r.shown()}"; ${r.why}',
        );
      });
    });
  });

  // =========================================================================
  // (f) one line alone: unchanged.
  // =========================================================================
  group('(f) one line alone', () {
    testWidgets('shown on the very next frame, held 1.5 s, then gone', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'f-alone', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        r.expectShown('alpha', '(f) next frame, no added delay');
        await r.pump(_hold - 1);
        r.expectShown('alpha', '(f) 1 ms before the hold ends');
        await r.pump(1);
        await r.pump();
        expect(
          r.shown(),
          '',
          reason:
              '(f) expected empty after the hold; got "${r.shown()}"; '
              '${r.why}',
        );
      });
    });

    testWidgets('a line in a later frame than another is set at once, not '
        'queued', (WidgetTester tester) async {
      await _scenario(tester, 'f-later-frame', (_Rig r) async {
        r.speak('alpha');
        await r.pump();
        await r.pump(300);
        r.expectShown('alpha', '(f) alpha before bravo');
        r.speak('bravo');
        await r.pump();
        r.expectShown('bravo', '(f) bravo on the very next frame');
        await r.pump(_hold - 1);
        r.expectShown('bravo', '(f) 1 ms before bravo\'s deadline');
        await r.pump(1);
        await r.pump();
        expect(r.shown(), '', reason: '(f) bravo gone; ${r.why}');
      });
    });

    testWidgets('a new line after a whole run has cleared is shown on the '
        'next frame', (WidgetTester tester) async {
      await _scenario(tester, 'f-after-run', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        await r.frames(2);
        await r.pump(_hold);
        await r.pump();
        expect(r.shown(), '', reason: '(f) fixture: the run cleared; ${r.why}');
        r.speak('charlie');
        await r.pump();
        r.expectShown('charlie', '(f) the first line of a fresh run');
      });
    });
  });

  // =========================================================================
  // Ugly cases around the queue: nothing dropped, nothing reordered.
  // =========================================================================
  group('queue edges', () {
    testWidgets('ten lines in one frame: all ten, in order, one per frame', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'q-ten', (_Rig r) async {
        final List<String> lines = <String>[
          for (int i = 0; i < 10; i++) 'line $i',
        ];
        for (final String l in lines) {
          r.speak(l);
        }
        final List<String> seen = await r.frames(12);
        expect(
          seen.take(10).toList(),
          lines,
          reason:
              '(D1) a line is never dropped and never reordered; got '
              '$seen; ${r.why}',
        );
        expect(
          seen.skip(10),
          everyElement('line 9'),
          reason:
              '(D1) after the run the last line is held; got $seen; '
              '${r.why}',
        );
      });
    });

    testWidgets('an empty line inside a batch is ignored and does not take '
        'a frame', (WidgetTester tester) async {
      await _scenario(tester, 'q-empty-inside', (_Rig r) async {
        r.speak('alpha');
        r.speak('');
        r.speak('bravo');
        final List<String> seen = await r.frames(3);
        expect(
          seen,
          <String>['alpha', 'bravo', 'bravo'],
          reason:
              '(D1) an empty line is ignored: expected alpha then bravo '
              'on consecutive frames; got $seen; ${r.why}',
        );
      });
    });

    testWidgets('a line spoken while the queue drains goes behind the '
        'queued ones', (WidgetTester tester) async {
      await _scenario(tester, 'q-speak-while-draining', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        await r.pump();
        r.expectShown('alpha', '(q) frame 1');
        r.speak('charlie');
        await r.pump();
        r.expectShown('bravo', '(q) frame 2 is bravo, not charlie');
        await r.pump();
        r.expectShown('charlie', '(q) frame 3');
        await r.pump();
        r.expectShown('charlie', '(q) frame 4');
      });
    });

    testWidgets('a run, a hold, and a second run: each run in order and '
        'each held from its own last line', (WidgetTester tester) async {
      await _scenario(tester, 'q-two-runs', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        expect(await r.frames(2), <String>['alpha', 'bravo'], reason: r.why);
        await r.pump(_hold);
        await r.pump();
        expect(r.shown(), '', reason: '(q) first run cleared; ${r.why}');
        r.speak('charlie');
        r.speak('delta');
        expect(await r.frames(2), <String>[
          'charlie',
          'delta',
        ], reason: '(q) second run in order; ${r.why}');
        await r.pump(_hold - 1);
        r.expectShown('delta', '(q) second run held to its own deadline');
        await r.pump(1);
        await r.pump();
        expect(r.shown(), '', reason: '(q) second run cleared; ${r.why}');
      });
    });

    testWidgets('a line spoken while another run is mid-hold and the queue '
        'is empty replaces it at once', (WidgetTester tester) async {
      await _scenario(tester, 'q-replace-after-run', (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        await r.frames(2);
        await r.pump(500);
        r.speak('charlie');
        await r.pump();
        r.expectShown(
          'charlie',
          '(q) charlie replaces bravo on the next frame',
        );
        await r.pump(_hold - 1);
        r.expectShown('charlie', '(q) held from charlie, not from bravo');
        await r.pump(1);
        await r.pump();
        expect(r.shown(), '', reason: '(q) charlie cleared; ${r.why}');
      });
    });
  });

  // =========================================================================
  // (g) dispose with lines still queued.
  // =========================================================================
  group('(g) dispose with lines queued', () {
    testWidgets('two lines queued, no frame yet: dispose, then time and '
        'frames pass; no exception, nothing set', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      int notified = 0;
      c.addListener(() => notified += 1);
      await tester.pumpWidget(
        _app(Stack(children: <Widget>[SpokenLineRegion(controller: c)])),
      );
      c.speak('alpha');
      c.speak('bravo');
      final int atDispose = notified;
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      final int afterUnmount = notified;
      await tester.pump(const Duration(milliseconds: 2000));
      await tester.pump();
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason:
            '(g) D4: scenario "g-before-frame": speak(alpha), '
            'speak(bravo), unmount, dispose, 2000 ms: expected no exception',
      );
      expect(
        notified,
        afterUnmount,
        reason:
            '(g) D4: scenario "g-before-frame": expected nothing set '
            'after dispose; listener calls rose from $afterUnmount to '
            '$notified (at speak time: $atDispose)',
      );
    });

    testWidgets('dispose while the region still shows line 1 and line 2 is '
        'queued: no exception, no later set', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      int notified = 0;
      c.addListener(() => notified += 1);
      await tester.pumpWidget(
        _app(Stack(children: <Widget>[SpokenLineRegion(controller: c)])),
      );
      c.speak('alpha');
      c.speak('bravo');
      c.speak('charlie');
      // Dispose before the frame in which the queue would advance.
      c.dispose();
      final int atDispose = notified;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 2000));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason:
            '(g) D4: scenario "g-dispose-then-frame": speak x3, dispose, '
            'unmount, 2000 ms: expected no exception',
      );
      expect(
        notified,
        atDispose,
        reason:
            '(g) D4: scenario "g-dispose-then-frame": expected nothing '
            'set after dispose; listener calls rose from $atDispose to '
            '$notified',
      );
    });

    testWidgets('dispose after frame 1 with the rest queued, mid-hold: no '
        'exception, no pending timer, nothing set after', (
      WidgetTester tester,
    ) async {
      final SpokenLineController c = SpokenLineController();
      int notified = 0;
      c.addListener(() => notified += 1);
      await tester.pumpWidget(
        _app(Stack(children: <Widget>[SpokenLineRegion(controller: c)])),
      );
      c.speak('alpha');
      c.speak('bravo');
      c.speak('charlie');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      c.speak('delta');
      c.speak('echo');
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      final int atDispose = notified;
      await tester.pump(const Duration(milliseconds: 5000));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason:
            '(g) D4: scenario "g-mid-run": speak x3, frame, 300 ms, '
            'speak x2, unmount, dispose, 5000 ms: expected no exception',
      );
      expect(
        notified,
        atDispose,
        reason:
            '(g) D4: scenario "g-mid-run": expected nothing set after '
            'dispose; listener calls rose from $atDispose to $notified',
      );
    });

    testWidgets('dispose right after two speaks with no region mounted at '
        'all', (WidgetTester tester) async {
      final SpokenLineController c = SpokenLineController();
      c.speak('alpha');
      c.speak('bravo');
      c.dispose();
      await tester.pump(const Duration(milliseconds: 2000));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason:
            '(g) D4: scenario "g-no-region": speak x2, dispose, 2000 ms: '
            'expected no exception',
      );
    });
  });

  // =========================================================================
  // (h) the game screen: the auto-move line and "Your turn" in one frame.
  // =========================================================================
  group('(h) GameScreen: the auto-move line then your-turn', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets('${locale.languageCode}: both reach the region on '
          'consecutive frames, in that order', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final List<String> steps = <String>[];
        final RollTrayDrive drive = await connectPlaying(
          tester,
          seats: twoSeats(mine: const <int>[2, -1, -1, -1]),
          turn: turnJson(seat: 0, phase: 'await_roll', k: 0),
        );
        try {
          await mountGame(tester, drive, locale: locale);
          steps.add('mounted GameScreen');
          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(Scaffold).first),
          );
          final String armed = loc.announceAutoMoveArmed(1);
          final String yourTurn = loc.gameYourTurnStale;
          expect(
            armed,
            isNot(yourTurn),
            reason: 'fixture: the two lines differ',
          );

          String shown() {
            final SemanticsNode? root = tester
                .binding
                .renderViews
                .first
                .owner
                ?.semanticsOwner
                ?.rootSemanticsNode;
            final List<String> labels = <String>[];
            void walk(SemanticsNode n) {
              if (n.flagsCollection.isLiveRegion && n.label.isNotEmpty) {
                labels.add(n.label);
              }
              n.visitChildren((SemanticsNode k) {
                walk(k);
                return true;
              });
            }

            if (root != null) {
              walk(root);
            }
            return labels.join('|');
          }

          // One wire frame, delivered without the harness's own two pumps so
          // that every frame can be read on its own.
          drive.lastSeq += 1;
          drive.transport.pushText(
            jsonEncode(<String, Object?>{
              'v': 1,
              't': 'turn',
              'id': 'c629-h-${locale.languageCode}',
              'd': <String, Object?>{
                'seat': 0,
                'phase': 'await_move',
                'deadline_ms': rollTrayDeadlineMs,
                'k': 1,
                'value': 5,
                'legal': <int>[0],
                'seq': drive.lastSeq,
              },
            }),
          );
          steps.add('pushed turn(seat 0, await_move, value 5, legal [0])');
          final List<String> seen = <String>[];
          for (int i = 0; i < 6; i++) {
            await tester.pump();
            seen.add(shown());
            steps.add('frame ${i + 1}: "${seen.last}"');
          }
          final String why =
              'scenario "h-game/${locale.languageCode}" (deterministic, no '
              'seed); expected the arming line "$armed" then "$yourTurn"; '
              'region per frame: $seen; steps: ${steps.join(' | ')}';
          final int firstArmed = seen.indexOf(armed);
          final int firstTurn = seen.indexOf(yourTurn);
          expect(
            firstArmed,
            isNot(-1),
            reason:
                '(h) D1: the auto-move line never reached the region; '
                '$why',
          );
          expect(
            firstTurn,
            isNot(-1),
            reason:
                '(h) D1: the your-turn line never reached the region; '
                '$why',
          );
          expect(
            firstTurn,
            firstArmed + 1,
            reason:
                '(h) D1: your-turn must be on the frame right after the '
                'auto-move line; $why',
          );
          expect(
            seen.where((String s) => s == armed).length,
            1,
            reason:
                '(h) D1: the auto-move line shows for exactly one frame '
                'before the next line replaces it; $why',
          );
        } finally {
          await releaseGame(tester, drive);
          handle.dispose();
        }
      });
    }
  });

  // =========================================================================
  // (i) and (j): D6, a queued line older than the hold is dropped.
  // =========================================================================
  group('(i) D6: the app was away longer than the hold', () {
    testWidgets('alpha, bravo, charlie in one frame, clock +2 s with no '
        'frame: bravo and charlie never reach the region', (
      WidgetTester tester,
    ) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-away-2s', clock: clock, (_Rig r) async {
        final List<String> setValues = <String>[];
        r.controller.addListener(() => setValues.add(r.controller.current));
        r.speak('alpha');
        r.speak('bravo');
        r.speak('charlie');
        r.advanceClock(2000);
        final List<String> seen = await r.frames(6);
        expect(
          seen,
          everyElement('alpha'),
          reason:
              '(i) D6: expected only alpha (already set when the app left) '
              'on every frame and no bravo or charlie, both are 2000 ms old; '
              'got $seen; ${r.why}',
        );
        expect(
          setValues.where((String v) => v == 'bravo' || v == 'charlie'),
          isEmpty,
          reason:
              '(i) D6: expected the controller never to set a dropped line; '
              'values set: $setValues; ${r.why}',
        );
        await r.pump(_hold);
        await r.pump();
        expect(
          r.shown(),
          '',
          reason:
              '(i) D6: expected alpha to clear and nothing after it; got '
              '"${r.shown()}"; ${r.why}',
        );
        final List<String> after = await r.frames(4);
        expect(
          after,
          everyElement(''),
          reason:
              '(i) D6: expected the region to stay empty after the run; got '
              '$after; ${r.why}',
        );
        expect(
          r.controller.current,
          '',
          reason:
              '(i) D6: expected controller.current "" at the end; got '
              '"${r.controller.current}"; ${r.why}',
        );
      });
    });

    testWidgets('a long absence drops every queued line, ten of them, and '
        'keeps only the one already set', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-away-ten', clock: clock, (_Rig r) async {
        for (int i = 0; i < 10; i++) {
          r.speak('line $i');
        }
        r.advanceClock(60000);
        final List<String> seen = await r.frames(14);
        expect(
          _Rig.runs(seen),
          <String>['line 0'],
          reason:
              '(i) D6: expected line 0 alone, lines 1 to 9 are a minute '
              'old; got $seen; ${r.why}',
        );
      });
    });

    testWidgets('a line spoken alone is never dropped, however long the '
        'clock ran before its frame', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-alone', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.advanceClock(600000);
        await r.pump();
        r.expectShown('alpha', '(i) a lone line, ten minutes of clock');
        await r.pump(_hold - 1);
        r.expectShown('alpha', '(i) held to its own deadline');
      });
    });

    testWidgets('dropping skips to the next line that is still fresh: '
        'alpha, bravo, charlie, bravo is 2 s old and charlie 1 s', (
      WidgetTester tester,
    ) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-skip-to-fresh', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.advanceClock(1000);
        r.speak('charlie'); // still the same frame, spoken 1 s later
        r.advanceClock(1000);
        final List<String> seen = await r.frames(5);
        expect(
          seen,
          <String>['alpha', 'charlie', 'charlie', 'charlie', 'charlie'],
          reason:
              '(i) D6: bravo (2000 ms old) is dropped and charlie '
              '(1000 ms old) is shown on the next frame; got $seen; '
              '${r.why}',
        );
      });
    });

    testWidgets('a dropped repeat does not clear the region: alpha, alpha '
        'then a long absence', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-dropped-repeat', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.speak('alpha');
        r.advanceClock(2000);
        final List<String> seen = await r.frames(5);
        expect(
          _Rig.runs(seen),
          <String>['alpha'],
          reason:
              '(i) D6 and D3: the second alpha is dropped, so it is never '
              'shown and never clears the first; got $seen; ${r.why}',
        );
      });
    });

    testWidgets('after a drop the controller is back to normal: a new line '
        'is shown on the next frame', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-then-normal', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.advanceClock(2000);
        await r.frames(3);
        await r.pump(_hold);
        await r.pump();
        r.expectShown('', '(i) fixture: the run has cleared');
        r.speak('charlie');
        r.speak('delta');
        final List<String> seen = await r.frames(3);
        expect(
          seen,
          <String>['charlie', 'delta', 'delta'],
          reason:
              '(i) D6: expected a fresh run after the drop to behave as '
              'before, charlie then delta; got $seen; ${r.why}',
        );
      });
    });

    testWidgets('the hold runs from the line that was last set, the dropped '
        'lines do not extend it', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-hold-after-drop', clock: clock, (
        _Rig r,
      ) async {
        r.speak('alpha');
        r.speak('bravo');
        r.advanceClock(2000);
        await r.pump();
        r.expectShown('alpha', '(i) frame 1');
        await r.pump(_hold - 1);
        r.expectShown('alpha', '(i) 1 ms before the hold of alpha ends');
        await r.pump(1);
        await r.pump();
        r.expectShown('', '(i) alpha cleared at its own deadline');
      });
    });

    testWidgets('boundary: a line one millisecond past the hold is dropped', (
      WidgetTester tester,
    ) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'i-hold-plus-1', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.advanceClock(_hold + 1);
        final List<String> seen = await r.frames(3);
        expect(
          seen,
          everyElement('alpha'),
          reason:
              '(i) D6: bravo is ${_hold + 1} ms old, more than the hold, so '
              'it is dropped; got $seen; ${r.why}',
        );
      });
    });
  });

  group('(j) D6: the app was away less than the hold', () {
    testWidgets('alpha, bravo, charlie in one frame, clock +1 s with no '
        'frame: bravo and charlie are shown in order', (
      WidgetTester tester,
    ) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'j-away-1s', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.speak('charlie');
        r.advanceClock(1000);
        final List<String> seen = await r.frames(4);
        expect(
          seen,
          <String>['alpha', 'bravo', 'charlie', 'charlie'],
          reason:
              '(j) D6: expected nothing dropped, the lines are 1000 ms '
              'old and the hold is $_hold ms; got $seen; ${r.why}',
        );
      });
    });

    testWidgets('boundary: a line exactly one hold old is shown (the rule '
        'says more than the hold)', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'j-exactly-hold', clock: clock, (_Rig r) async {
        r.speak('alpha');
        r.speak('bravo');
        r.advanceClock(_hold);
        final List<String> seen = await r.frames(3);
        expect(
          seen,
          <String>['alpha', 'bravo', 'bravo'],
          reason:
              '(j) D6: bravo is exactly $_hold ms old, not more, so it is '
              'shown; got $seen; ${r.why}',
        );
      });
    });

    testWidgets('lines are judged by their own age when their turn comes: '
        'frames 400 ms apart drop the line that would be set past the hold', (
      WidgetTester tester,
    ) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'j-slow-frames', clock: clock, (_Rig r) async {
        for (final String l in <String>[
          'alpha',
          'bravo',
          'charlie',
          'delta',
          'echo',
        ]) {
          r.speak(l);
        }
        final List<String> seen = <String>[];
        for (int i = 0; i < 7; i++) {
          await r.pump(400);
          seen.add(r.shown());
        }
        expect(
          seen,
          <String>[
            'alpha', // t=400
            'bravo', // t=800
            'charlie', // t=1200
            'delta', // t=1600, delta was set at 1200 (1200 ms old)
            'delta', // t=2000, echo was 1600 ms old at 1600 and is dropped
            'delta', // t=2400, held until 1200 + 1500 = 2700
            '', // t=2800
          ],
          reason:
              '(j) D6 and D2: echo is older than the hold when its turn '
              'comes and is dropped; delta is held from when it was set; '
              'got $seen; ${r.why}',
        );
      });
    });

    testWidgets('normal play: lines one frame apart are never dropped with '
        'the clock moving 16 ms a frame', (WidgetTester tester) async {
      final _Clock clock = _Clock();
      await _scenario(tester, 'j-normal-play', clock: clock, (_Rig r) async {
        final List<String> lines = <String>[
          for (int i = 0; i < 10; i++) 'line $i',
        ];
        for (final String l in lines) {
          r.speak(l);
        }
        final List<String> seen = <String>[];
        for (int i = 0; i < 10; i++) {
          await r.pump(16);
          seen.add(r.shown());
        }
        expect(
          seen,
          lines,
          reason:
              '(j) D6: expected all ten lines in order, they are at most '
              '160 ms old; got $seen; ${r.why}',
        );
      });
    });
  });
}
