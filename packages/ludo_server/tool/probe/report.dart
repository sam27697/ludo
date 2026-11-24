// Numbers for the bad-line probe: percentiles, frame sizes by type and
// direction, and the table the tool prints.

import 'dart:math';

/// Nearest-rank percentile of [sorted] (ascending), `p` in 0..100.
num percentile(List<num> sorted, num p) {
  if (sorted.isEmpty) {
    return double.nan;
  }
  final int rank = max(1, (p / 100 * sorted.length).ceil());
  return sorted[min(rank, sorted.length) - 1];
}

/// P50 / P95 / P99 / max of a list of millisecond samples.
class LatencySummary {
  LatencySummary(List<double> samples)
      : count = samples.length,
        _sorted = List<double>.of(samples)..sort();

  final int count;
  final List<double> _sorted;

  num get p50 => percentile(_sorted, 50);
  num get p95 => percentile(_sorted, 95);
  num get p99 => percentile(_sorted, 99);
  num get maxMs => _sorted.isEmpty ? double.nan : _sorted.last;
  num get minMs => _sorted.isEmpty ? double.nan : _sorted.first;

  Map<String, Object?> toJson() => <String, Object?>{
        'samples': count,
        'p50_ms': _round(p50),
        'p95_ms': _round(p95),
        'p99_ms': _round(p99),
        'max_ms': _round(maxMs),
        'min_ms': _round(minMs),
      };
}

num _round(num v) => v.isNaN ? v : (v * 10).round() / 10;

/// Sizes of the frames of one type in one direction.
class SizeStats {
  final List<int> sizes = <int>[];

  void add(int bytes) => sizes.add(bytes);

  Map<String, Object?> toJson() {
    final List<int> s = List<int>.of(sizes)..sort();
    return <String, Object?>{
      'count': s.length,
      'min': s.first,
      'median': percentile(s, 50),
      'max': s.last,
      'total': s.fold<int>(0, (int a, int b) => a + b),
    };
  }
}

String fmtMs(num v) => v.isNaN ? '-' : v.toStringAsFixed(0);

String padRight(String s, int w) =>
    s.length >= w ? s : s + ' ' * (w - s.length);
String padLeft(String s, int w) => s.length >= w ? s : ' ' * (w - s.length) + s;
