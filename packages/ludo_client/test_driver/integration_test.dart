// The `flutter drive` side of the screenshot suite. integration_test's
// binding hands each screenshot back to this process as PNG bytes over the
// Flutter Driver connection (see the `takeScreenshot` doc comment in
// package:integration_test/common.dart: the bytes it hands the driver are
// already PNG-encoded); this file's only job is to write them to disk under
// the name the test gave them.
//
// Invoked as:
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart
//
// `flutter drive` runs this file on the host, with the host's working
// directory equal to wherever the `flutter drive` command itself was
// invoked from. The screenshots.yml workflow runs that command with
// packages/ludo_client as the working directory, so the paths below resolve
// to packages/ludo_client/screenshots/*.png.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() => integrationDriver(
  onScreenshot:
      (String name, List<int> bytes, [Map<String, Object?>? args]) async {
        final file = File('screenshots/$name.png');
        await file.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return true;
      },
);
