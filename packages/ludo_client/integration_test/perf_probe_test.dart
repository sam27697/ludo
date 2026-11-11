// Frame-cost probe. Plays the motion scenario (motion_test.dart, the same
// scripted two-seat game the motion recordings show) and records the
// FrameTiming of every frame the app rendered. The numbers go back to the
// driver through binding.reportData; test_driver/perf_probe_driver.dart
// writes them to perf/. Run it with `flutter drive --profile`, through
// tool/perf_probe.sh.

import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'motion_test.dart' as motion;

const String _locale = String.fromEnvironment(
  'MOTION_LOCALE',
  defaultValue: 'en',
);

const String _seat = String.fromEnvironment('MOTION_SEAT', defaultValue: '0');

// The engine hands timings over in batches, up to about a second late. The
// last frames of the game arrive after the test body has returned.
const Duration _batchFlush = Duration(seconds: 2);

double _ms(Duration d) => d.inMicroseconds / 1000;

double _round1(double v) => double.parse(v.toStringAsFixed(1));

// Nearest rank: the value at 1-based rank ceil(p / 100 * n) of the sorted list.
double _percentile(List<double> sorted, int p) {
  final int rank = math.max(1, (p / 100 * sorted.length).ceil());
  return sorted[rank - 1];
}

Map<String, Object?> _stats(List<double> values) {
  final List<double> sorted = List<double>.of(values)..sort();
  return <String, Object?>{
    'p50': _round1(_percentile(sorted, 50)),
    'p90': _round1(_percentile(sorted, 90)),
    'p99': _round1(_percentile(sorted, 99)),
    'max': _round1(sorted.last),
  };
}

int _countOver(List<double> values, double limitMs) =>
    values.where((double v) => v > limitMs).length;

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final List<FrameTiming> recorded = <FrameTiming>[];
  SchedulerBinding.instance.addTimingsCallback(recorded.addAll);

  tearDownAll(() async {
    await Future<void>.delayed(_batchFlush);

    final String mode = kProfileMode
        ? 'profile'
        : (kDebugMode ? 'debug' : 'release');
    final int firstStartUs = recorded.isEmpty
        ? 0
        : recorded.first.timestampInMicroseconds(FramePhase.buildStart);

    final List<double> build = <double>[];
    final List<double> raster = <double>[];
    final List<double> total = <double>[];
    final List<List<double>> timings = <List<double>>[];
    for (final FrameTiming t in recorded) {
      final double start =
          (t.timestampInMicroseconds(FramePhase.buildStart) - firstStartUs) /
          1000;
      build.add(_ms(t.buildDuration));
      raster.add(_ms(t.rasterDuration));
      total.add(_ms(t.totalSpan));
      timings.add(<double>[
        _round1(start),
        _round1(build.last),
        _round1(raster.last),
        _round1(total.last),
      ]);
    }

    binding.reportData = <String, dynamic>{
      'mode': mode,
      'locale': _locale,
      'seat': _seat,
      'frames': recorded.length,
      'timings': timings,
      'summary': recorded.isEmpty
          ? <String, Object?>{}
          : <String, Object?>{
              'build': _stats(build),
              'raster': _stats(raster),
              'buildOver8ms': _countOver(build, 8),
              'buildOver16_7ms': _countOver(build, 16.7),
              'rasterOver16_7ms': _countOver(raster, 16.7),
              'totalSpanOver16_7ms': _countOver(total, 16.7),
            },
    };
  });

  motion.main();
}
