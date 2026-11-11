// The `flutter drive` side of the frame-cost probe. integration_test hands
// the report map back over the Flutter Driver connection; this file writes
// it to perf/perf-<locale>-seat<seat>.json and prints the summary.
//
// Invoked as:
//   flutter drive --profile \
//     --driver=test_driver/perf_probe_driver.dart \
//     --target=integration_test/perf_probe_test.dart
//
// The working directory is packages/ludo_client, so the file lands in
// packages/ludo_client/perf/.
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (Map<String, dynamic>? data) async {
    if (data == null) {
      throw StateError('the probe returned no report data');
    }
    final Object? locale = data['locale'];
    final Object? seat = data['seat'];
    final File file = File('perf/perf-$locale-seat$seat.json');
    await file.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    stdout.writeln(
      'perf ${data['mode']} locale=$locale seat=$seat frames=${data['frames']}',
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(data['summary']));
  },
);
