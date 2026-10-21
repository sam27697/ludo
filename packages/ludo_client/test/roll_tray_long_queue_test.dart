// Probe for order 419 (ludo-tester run 101), amended by order 420 for
// C-420-tray-long-queue.md: does the roll tray hold a long queue of
// unspent faces on a small phone. Sweep 25 (run 100) only measured a
// queue of three (roll_tray_fit_test.dart); this file mounts the same
// real GameScreen, on my own turn in the spend phase
// (TurnPhase.awaitMove), with longer queues that rule 10q-12q
// (docs/RULES.md:125-148) make reachable in a real game.
//
// 419 asked whether every queued face had its own tile. The contract
// (D1/D2) now allows equal faces to collapse into one tile carrying a
// count; D5 is what must hold instead: no layout error, every tile
// inside the screen, no overlap with the board die, every hit box at
// least 48x48, and the per-tile counts (read off each tile's own
// semantics label, since D3 is the only place a count is a contract,
// not an implementation detail) sum to the queue length.
//
// This is a measurement, not a fix. A red case here is the finding: it
// stays red, nothing here is weakened to turn it green.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsHandle, SemanticsNode;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'support/roll_tray_harness.dart';

const List<Size> _sizes = <Size>[
  Size(320, 568),
  Size(360, 640),
  Size(360, 740),
  Size(411, 704),
];
const List<double> _scales = <double>[1.0, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader noto = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    noto.addFont(rootBundle.load(asset));
  }
  await noto.load();
}

void _print(String line) {
  // ignore: avoid_print
  print(line);
}

/// A real queue state the roll queue rules allow, on the same board shape
/// roll_tray_fit_test uses: seat 0 has one token out at track position 0
/// and three still home, so a 6 can bring a token out or move the one
/// already out, and a non-6 can only move the one already out.
class _QueueCase {
  const _QueueCase({
    required this.n,
    required this.queue,
    required this.derivation,
  });

  final int n;
  final List<int> queue;

  /// How this queue is reached under 10q-12q, for the report.
  final String derivation;

  List<Map<String, Object?>> get legalByFace {
    final List<int> distinct = <int>[];
    for (final int face in queue) {
      if (!distinct.contains(face)) {
        distinct.add(face);
      }
    }
    return <Map<String, Object?>>[
      for (final int face in distinct)
        faceLegal(face, face == 6 ? const <int>[0, 1, 2, 3] : const <int>[0]),
    ];
  }
}

// roll_tray_fit_test's own queue of three, reused here as the control:
// the method must call this green before a longer queue is trusted red.
const _QueueCase _n3 = _QueueCase(
  n: 3,
  queue: <int>[6, 6, 3],
  derivation: 'rolled 6, 6, 3 (roll_tray_fit_test\'s own queue)',
);

// Order 419's own N = 4 example: rolled 6, 6, 3; one 6 spent; the 3 spent
// with a capture bonus roll of 6, 6, 2; remaining 6 plus the bonus's
// 6, 6, 2.
const _QueueCase _n4 = _QueueCase(
  n: 4,
  queue: <int>[6, 6, 6, 2],
  derivation:
      'rolled 6, 6, 3; one 6 spent; the 3 spent with a capture bonus '
      'roll of 6, 6, 2; queue [6] + [6, 6, 2]',
);

// Order 419's own N = 5 example: the same initial roll, the 3 spent
// first so both 6s are still queued when the bonus roll joins them.
const _QueueCase _n5 = _QueueCase(
  n: 5,
  queue: <int>[6, 6, 6, 6, 2],
  derivation:
      'rolled 6, 6, 3; the 3 spent first with a capture bonus roll of '
      '6, 6, 2; queue [6, 6] + [6, 6, 2]',
);

// Order 419's own N = 7 example (two capture bonuses). Verified path:
// rolled 6, 6, 4; the 4 spent at once with a capture bonus roll of
// 6, 6, 4; the new 4 spent at once too, with a second capture bonus roll
// of 6, 6, 4; the third 4 stays queued. sixes resets to 0 on every 4, so
// no roll in this chain ever sees a third consecutive 6.
const _QueueCase _n7 = _QueueCase(
  n: 7,
  queue: <int>[6, 6, 6, 6, 6, 6, 4],
  derivation:
      'rolled 6, 6, 4; the 4 spent with a capture bonus roll of 6, 6, 4; '
      'the new 4 spent with a second capture bonus roll of 6, 6, 4; '
      'queue [6, 6] + [6, 6] + [6, 6, 4]',
);

// Order 420's own N = 6 example: the same two capture bonuses as N = 5's
// own path, but the second owed roll stops after a single six (the next
// die was not a six), so it contributes one six, not two, before the
// queue-ending 3 that stays: rolled 6, 6, 4; the 4 spent with a capture
// bonus roll of 6, 6, 2; the 2 spent with a second capture bonus roll of
// 6, 3 (one six, then the roll ended on a non-six); queue
// [6, 6] + [6, 6] + [6, 3].
const _QueueCase _n6 = _QueueCase(
  n: 6,
  queue: <int>[6, 6, 6, 6, 6, 3],
  derivation:
      'rolled 6, 6, 4; the 4 spent with a capture bonus roll of 6, 6, 2; '
      'the 2 spent with a second capture bonus roll of 6, 3 (one six, '
      'then the roll ended on a non-six); queue [6, 6] + [6, 6] + [6, 3]',
);

const List<_QueueCase> _longQueues = <_QueueCase>[_n4, _n5, _n6, _n7];

String _sizeLabel(Size size) => '${size.width.toInt()}x${size.height.toInt()}';

String _rectLabel(Rect? rect) => rect == null ? 'MISSING' : rect.toString();

/// D5's "count marks add up to the queue length" is read off the tile's
/// own semantics label (D3), never off the pill's internal widget shape:
/// the pill's rendering is the implementer's choice, the label's suffix
/// is the contract. A tile with no matching suffix is a count of one
/// (D3: "a tile with count 1 reads exactly its old label").
int _tileCount(WidgetTester tester, int index, Locale locale) {
  final SemanticsNode node = tester.getSemantics(find.byKey(trayDieKey(index)));
  final String label = node.label;
  final RegExp suffix = locale.languageCode == 'ar'
      ? RegExp(r'، العدد (\d+)$')
      : RegExp(r', (\d+) of them$');
  final RegExpMatch? match = suffix.firstMatch(label);
  return match == null ? 1 : int.parse(match.group(1)!);
}

/// Mounts the real GameScreen on seat 0's own turn, in await_move, with
/// [queueCase]'s queue, at [size]/[scale]/[locale], and runs every check
/// order 419 asks for. The TRAY line always prints before any assertion
/// can throw, so a red case still reports its numbers.
Future<void> _runCase(
  WidgetTester tester, {
  required _QueueCase queueCase,
  required Size size,
  required double scale,
  required Locale locale,
}) async {
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // D5's count-sum check reads each tile's semantics label (D3).
  final SemanticsHandle semantics = tester.ensureSemantics();
  RollTrayDrive? drive;
  try {
    drive = await connectPlaying(
      tester,
      seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
      turn: turnJson(
        seat: 0,
        phase: 'await_move',
        k: queueCase.n,
        value: queueCase.queue.first,
        legal: const <int>[0, 1, 2, 3],
        queue: queueCase.queue,
        legalByFace: queueCase.legalByFace,
      ),
    );
    await mountGame(tester, drive, locale: locale, textScale: scale);

    final bool dieVisible = tester.any(find.byKey(bigDieKey));
    final Rect? boardDieRect = dieVisible
        ? tester.getRect(find.byKey(bigDieKey))
        : null;
    final bool trayVisible = tester.any(find.byKey(rollTrayKey));
    final Rect? trayRect = trayVisible
        ? tester.getRect(find.byKey(rollTrayKey))
        : null;

    // D5 is proved over whichever tiles the tray actually drew, not over
    // one tile per queue entry (419's own rule, which D2 replaces): a
    // tile index with no `game-roll-tray-die-<i>` in the tree may be a
    // collapsed group member, not a defect by itself.
    final List<int> liveIndices = <int>[
      for (int i = 0; i < queueCase.queue.length; i++)
        if (tester.any(find.byKey(trayDieKey(i)))) i,
    ];
    final List<int> counts = <int>[
      for (final int i in liveIndices) _tileCount(tester, i, locale),
    ];
    final int countSum = counts.fold(0, (int a, int b) => a + b);

    _print(
      'TRAY N=${queueCase.n} ${_sizeLabel(size)} scale '
      '${scale.toStringAsFixed(1)} ${locale.languageCode} '
      'trayLeft=${trayRect?.left.toStringAsFixed(1) ?? 'MISSING'} '
      'trayRight=${trayRect?.right.toStringAsFixed(1) ?? 'MISSING'} '
      'screenW=${size.width.toStringAsFixed(1)} '
      'dieRect=${_rectLabel(boardDieRect)} '
      'tiles=${liveIndices.length} counts=$counts '
      'errors=${captured.length}',
    );

    final List<String> problems = <String>[];
    if (captured.isNotEmpty) {
      problems.add(
        'flutter reported ${captured.length} error(s) during layout: '
        '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' || ')}',
      );
    }
    if (boardDieRect == null) {
      problems.add('game-die is missing from the tree');
    }
    if (!trayVisible) {
      problems.add('game-roll-tray is missing from the tree');
    }
    for (final int i in liveIndices) {
      final Rect rect = tester.getRect(find.byKey(trayDieKey(i)));
      if (!(rect.left >= 0 && rect.right <= size.width)) {
        problems.add(
          'game-roll-tray-die-$i rect $rect is outside the screen width '
          '0..${size.width} by ${rect.right > size.width ? rect.right - size.width : -rect.left}',
        );
      }
      if (rect.width < 48 || rect.height < 48) {
        problems.add(
          'game-roll-tray-die-$i hit size ${rect.width}x${rect.height} '
          'is under the 48x48 minimum',
        );
      }
      if (boardDieRect != null && rect.overlaps(boardDieRect)) {
        problems.add(
          'game-roll-tray-die-$i rect $rect overlaps the board die rect '
          '$boardDieRect',
        );
      }
    }
    if (countSum != queueCase.n) {
      problems.add(
        'tray tile counts $counts (tiles $liveIndices) sum to $countSum, '
        'not the queue length ${queueCase.n}',
      );
    }

    expect(
      problems,
      isEmpty,
      reason:
          'TRAY N=${queueCase.n} ${_sizeLabel(size)} scale '
          '${scale.toStringAsFixed(1)} ${locale.languageCode}: '
          '${problems.join(' ; ')}',
    );
  } finally {
    FlutterError.onError = previous;
    semantics.dispose();
    final RollTrayDrive? owned = drive;
    if (owned != null) {
      await releaseGame(tester, owned);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void main() {
  setUpAll(_loadAppFonts);

  testWidgets(
    'control: N = 3 (roll_tray_fit_test\'s own queue) fits on 360x640',
    (tester) => _runCase(
      tester,
      queueCase: _n3,
      size: const Size(360, 640),
      scale: 1.0,
      locale: const Locale('en'),
    ),
  );

  for (final _QueueCase queueCase in _longQueues) {
    for (final Size size in _sizes) {
      for (final double scale in _scales) {
        for (final Locale locale in _locales) {
          final String code = locale.languageCode;
          final String scaleLabel = scale.toStringAsFixed(1);
          testWidgets(
            'N = ${queueCase.n} (${queueCase.derivation}) at '
            '${_sizeLabel(size)} scale $scaleLabel $code',
            (tester) => _runCase(
              tester,
              queueCase: queueCase,
              size: size,
              scale: scale,
              locale: locale,
            ),
          );
        }
      }
    }
  }
}
