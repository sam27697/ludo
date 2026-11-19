// Large-text coverage of HomeScreen with a remembered table (X54, run 89;
// C-678). The last-table chip this file once measured is gone, so the cases
// now assert that Home with a remembered name mounts and lays out without a
// FlutterError at each size, text scale and locale, and shows no chip.
//
// Font loading and the ambient MediaQuery textScaler override through
// MaterialApp.builder are the technique of test/large_text_fit_test.dart.
//
// One mount per case: a fresh HomeScreen, freshly seeded session memory,
// real fonts, one surface size, one text scale, one locale.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/session_memory.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

const Key _chipKey = Key('home-last-table-chip');

// The order's own name. Matches test/large_text_fit_test.dart's and
// test/header_fits_test.dart's "Karim12345" case, a 10-character name.
const String _lastTableName = 'Karim12345';

// test/home_chip_craft_test.dart's own seat count for this same chip.
const int _lastTableSeats = 2;

const List<Size> _sizes = <Size>[Size(360, 640), Size(411, 704)];
const List<double> _scales = <double>[1.0, 1.3, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

RoomController _unusedController() {
  return RoomController(
    serverUrl: Uri.parse('wss://large-text-home-test.invalid/ws'),
    connect: (Uri url) async {
      throw StateError(
        'large_text_home_test: connector must not open a transport',
      );
    },
  );
}

Future<void> _seedLastTable() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await SessionMemory.recordSuccessfulCreate(
    name: _lastTableName,
    seats: _lastTableSeats,
  );
}

Widget _harness({required Locale locale, required double textScale}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      );
    },
    home: HomeScreen(
      onToggleLocale: () {},
      controllerFactory: _unusedController,
    ),
  );
}

/// Mounts Home at [size], locale and scale, reset before the test returns
/// (test/large_text_fit_test.dart's own `_phone` precedent). No
/// RoomController is kept here (unlike that file's GameScreen mounts):
/// HomeScreen never owns a socket until Create or Join is tapped, which
/// this file never does.
Future<void> _mountHome(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
  required double textScale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  try {
    await tester.pumpWidget(_harness(locale: locale, textScale: textScale));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  } finally {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

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

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

void main() {
  setUpAll(_loadAppFonts);

  for (final Size size in _sizes) {
    final String sizeLabel = '${size.width.toInt()}x${size.height.toInt()}';

    for (final double scale in _scales) {
      final String scaleLabel = scale.toStringAsFixed(1);

      for (final Locale locale in _locales) {
        final String code = locale.languageCode;
        final String label = '$sizeLabel $code scale $scaleLabel';

        testWidgets('$label: home with a remembered table lays out, no chip', (
          tester,
        ) async {
          await _seedLastTable();
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = captured.add;
          final List<String> reds = <String>[];
          try {
            await _mountHome(
              tester,
              size: size,
              locale: locale,
              textScale: scale,
            );
            if (tester.any(find.byKey(_chipKey, skipOffstage: false))) {
              reds.add(
                '$label: expected no home-last-table-chip (C-678 removed '
                'it), found one',
              );
            }
          } finally {
            FlutterError.onError = previous;
          }
          if (captured.isNotEmpty) {
            reds.insert(
              0,
              '$label: expected no FlutterError during mount/pump, got '
              '${captured.map((FlutterErrorDetails d) => d.exceptionAsString()).join(' | ')}',
            );
          }
          expect(reds, isEmpty, reason: reds.join('\n'));
        });
      }
    }
  }
}
