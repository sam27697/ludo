// Fit proof for the roll tray (order 366, K13, and K1's reading order).
// One mount per scale and locale. 360x740 logical, text scale 1.0, 1.3
// and 2.0, a queue of three. Real app fonts, so the measure is not the
// test font.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

import 'support/roll_tray_harness.dart';

const Size _phone = Size(360, 740);
const List<double> _scales = <double>[1.0, 1.3, 2.0];
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

void main() {
  setUpAll(_loadAppFonts);

  for (final double scale in _scales) {
    for (final Locale locale in _locales) {
      final String code = locale.languageCode;
      final String scaleLabel = scale.toStringAsFixed(1);
      testWidgets(
        'case 13: $code scale $scaleLabel, queue of three, fits on 360x740',
        (tester) async {
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = captured.add;
          tester.view.physicalSize = _phone;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          RollTrayDrive? drive;
          try {
            drive = await connectPlaying(
              tester,
              seats: twoSeats(mine: const <int>[0, -1, -1, -1]),
              turn: turnJson(
                seat: 0,
                phase: 'await_move',
                k: 3,
                value: 6,
                legal: const <int>[0, 1, 2, 3],
                queue: const <int>[6, 6, 3],
                legalByFace: <Map<String, Object?>>[
                  faceLegal(6, const <int>[0, 1, 2, 3]),
                  faceLegal(3, const <int>[0]),
                ],
              ),
            );
            await mountGame(tester, drive, locale: locale, textScale: scale);

            expect(
              find.byKey(rollTrayKey),
              findsOneWidget,
              reason:
                  'K1: game-roll-tray is in the tree for a queue of three '
                  'at $code scale $scaleLabel',
            );
            expect(find.byKey(trayFaceKey(0, 6)), findsOneWidget);
            expect(find.byKey(trayFaceKey(1, 6)), findsOneWidget);
            expect(find.byKey(trayFaceKey(2, 3)), findsOneWidget);

            final List<String> overflows = <String>[
              for (final FlutterErrorDetails details in captured)
                if (details.exceptionAsString().contains('overflow'))
                  details.exceptionAsString(),
            ];
            expect(
              overflows,
              isEmpty,
              reason:
                  'K13: no overflow at $code scale $scaleLabel; '
                  'got ${overflows.join(' | ')}',
            );

            final Rect tray = tester.getRect(find.byKey(rollTrayKey));
            final Rect screen = Offset.zero & _phone;
            final Rect slop = screen.inflate(0.5);
            expect(
              slop.contains(tray.topLeft) && slop.contains(tray.bottomRight),
              isTrue,
              reason:
                  'K13: the tray rect $tray stays inside 360x740 at '
                  '$code scale $scaleLabel',
            );

            final Rect die = tester.getRect(find.byKey(bigDieKey));
            expect(
              (tray.center.dy - die.center.dy).abs(),
              lessThan(36),
              reason: 'K1: the tray stays on the big die\'s row',
            );
            if (code == 'ar') {
              expect(
                tray.center.dx,
                lessThan(die.center.dx),
                reason: 'K1: in ar the tray sits before the big die',
              );
            } else {
              expect(
                tray.center.dx,
                greaterThan(die.center.dx),
                reason: 'K1: in en the tray sits after the big die',
              );
            }
          } finally {
            FlutterError.onError = previous;
            final RollTrayDrive? owned = drive;
            if (owned != null) {
              await releaseGame(tester, owned);
            }
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        },
      );
    }
  }
}
