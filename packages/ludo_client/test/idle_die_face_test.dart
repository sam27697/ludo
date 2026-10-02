// Conformance tests for the idle die's face, written from
// work/ludo/orders/C-238-idle-die-face.md (the master, run 68) alone. Order
// 238 (lib/src/game_die.dart) is being built in parallel by a different
// worker; this file was written without opening that file's new content,
// only the base at order/236-feedback-wiring (d28ab24) that the contract
// names, so most cases below are expected to run red on that base for
// exactly the defect the contract describes (a painter that returns before
// drawing anything for a null face).
//
// GameDie is mounted directly, never through GameScreen, per the order:
// this file holds the widget to its own contract alone, nothing about
// RoomController or the wire. Localizations are wired the same way
// test/play_surface_die_test.dart's own harness does it (copied by hand,
// not imported across test files, per the order).
//
// Standing lessons from this project's own suite, carried into this file:
//   8: no pumpEventQueue() in testWidgets; tester.runAsync() steps outside
//      the fake-async zone for real async work, here the image encoding in
//      the pixel group below.
//   10: no pumpAndSettle against a repeating animation; the tumbling group
//      below pumps a bounded handful of frames instead.
//   35: one mount per case (every testWidgets body calls tester.pumpWidget
//       exactly once), and anything created in the test body -- here the
//       captured ui.Image -- is disposed in the test body, not left to
//       addTearDown.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_die.dart';
import 'package:ludo_client/src/theme.dart';

const Key _dieKey = Key('game-die');
const Key _idleArtKey = Key('game-die-idle-art');
const Key _blankKey = Key('game-die-blank');
const Key _pulseKey = Key('game-die-pulse');
const Key _tumblingKey = Key('game-die-tumbling');
const Key _noMoveMarkKey = Key('game-die-no-move-mark');

Key _faceKey(int value) => Key('game-die-face-$value');

/// One fixed seat colour throughout: every case here is about the die's
/// own face, never about which seat is painting the border. Picked from
/// LudoColors.seats, not a literal, the same source C-238 rule 7 requires
/// of the production painter.
final Color _seatColor = LudoColors.seats[0];

/// Same localizations wiring as test/play_surface_die_test.dart's own
/// `_harness`, copied by hand rather than imported across test files.
Widget _harness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(disableAnimations: disableAnimations),
        child: child!,
      );
    },
    home: child,
  );
}

/// Mounts GameDie alone, optionally wrapped in a keyed RepaintBoundary for
/// the pixel group. One mount per case (lesson 35): every caller below is
/// its own testWidgets body and calls this exactly once.
Future<void> _mountDie(
  WidgetTester tester, {
  required int? face,
  required bool enabled,
  required bool tumbling,
  bool noMove = false,
  bool disableAnimations = false,
  Key? repaintKey,
}) async {
  Widget die = GameDie(
    face: face,
    seatColor: _seatColor,
    enabled: enabled,
    tumbling: tumbling,
    noAnswer: false,
    noMove: noMove,
  );
  if (repaintKey != null) {
    die = RepaintBoundary(key: repaintKey, child: die);
  }
  await tester.pumpWidget(
    _harness(Center(child: die), disableAnimations: disableAnimations),
  );
  await tester.pump();
}

void _expectNoFaceKeys(String reason) {
  for (int value = 1; value <= 6; value++) {
    expect(
      find.byKey(_faceKey(value)),
      findsNothing,
      reason: '$reason (found game-die-face-$value)',
    );
  }
}

/// C-238's "what proves it" and order item 8: the die's own footprint never
/// moves, whatever it paints inside it. Asserted exactly, not merely as a
/// lower bound, since lib/src/game_die.dart fixes `_kDieSize` to exactly 72.
void _expectDieSize72(WidgetTester tester) {
  final Size size = tester.getSize(find.byKey(_dieKey));
  expect(
    size,
    const Size(72, 72),
    reason:
        'game-die must stay exactly 72x72 regardless of what the die '
        'paints inside it; got $size',
  );
}

/// LudoColors.ink's channels as 0-255 ints, read off the modern 0-1 double
/// getters rather than the deprecated red/green/blue ones (dart analyze
/// must stay clean per the order).
final int _inkR = (LudoColors.ink.r * 255).round();
final int _inkG = (LudoColors.ink.g * 255).round();
final int _inkB = (LudoColors.ink.b * 255).round();

/// Counts opaque pixels within [tolerance] of LudoColors.ink in a raw RGBA
/// buffer (4 bytes per pixel: R, G, B, A). A painter that returns before
/// drawing any pips -- the base's defect -- leaves this at exactly 0; a
/// painted cube's pips leave it in the hundreds (see the pixel test below
/// for the floor and the arithmetic behind it).
int _countInkPixels(ByteData rgba, {int tolerance = 20}) {
  final Uint8List bytes = rgba.buffer.asUint8List(
    rgba.offsetInBytes,
    rgba.lengthInBytes,
  );
  int count = 0;
  for (int i = 0; i + 3 < bytes.length; i += 4) {
    final int a = bytes[i + 3];
    if (a < 250) {
      // Skip anti-aliased edge pixels and anything not solidly painted;
      // only a pip's own solid interior should be counted.
      continue;
    }
    final int r = bytes[i];
    final int g = bytes[i + 1];
    final int b = bytes[i + 2];
    if ((r - _inkR).abs() <= tolerance &&
        (g - _inkG).abs() <= tolerance &&
        (b - _inkB).abs() <= tolerance) {
      count++;
    }
  }
  return count;
}

void main() {
  group('idle, my own turn (face: null, enabled: true, tumbling: false)', () {
    testWidgets(
      'shows the idle art and the blank key, no resting face -- catches a '
      'painter that returns before drawing anything for a null face',
      (tester) async {
        await _mountDie(tester, face: null, enabled: true, tumbling: false);

        expect(
          find.byKey(_idleArtKey),
          findsOneWidget,
          reason:
              'game-die-idle-art must be present while face is null and '
              'the die is not tumbling (C-238 rule 3)',
        );
        expect(
          find.byKey(_blankKey),
          findsOneWidget,
          reason:
              'game-die-blank must still mark "no resting face" once the '
              'idle cube is added (C-238 rule 3)',
        );
        _expectNoFaceKeys(
          'no game-die-face-N may appear while no roll has landed',
        );
        _expectDieSize72(tester);
      },
    );
  });

  group('idle pixels: the cube must actually paint ink-coloured pips', () {
    testWidgets(
      'the rendered 72x72 box contains hundreds of ink pixels, not the '
      'empty box a painter that returns early on null leaves',
      (tester) async {
        const Key boundaryKey = Key('idle-die-pixel-boundary');
        await _mountDie(
          tester,
          face: null,
          enabled: true,
          tumbling: false,
          repaintKey: boundaryKey,
        );
        _expectDieSize72(tester);

        final RenderRepaintBoundary boundary = tester.renderObject(
          find.byKey(boundaryKey),
        );
        late ByteData rgba;
        await tester.runAsync(() async {
          final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
          final ByteData? bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          if (bytes == null) {
            fail('toByteData produced no pixel data for the idle die');
          }
          rgba = bytes;
        });

        final int inkPixels = _countInkPixels(rgba);
        // C-238 rule 1: six pips total (1 top + 2 left + 3 right), each
        // "about 6dp" in radius per the order. pi * 6^2 is roughly 113 px
        // at pixel ratio 1, so even one fully painted pip alone clears
        // this floor. 120 sits well below the hundreds a real cube leaves
        // and well above the 0 a painter that returns on `face == null`
        // leaves (lib/src/game_die.dart's `_GameDiePainter.paint` today).
        const int floor = 120;
        expect(
          inkPixels,
          greaterThan(floor),
          reason:
              'the idle die must paint ink-coloured pips on its cube; '
              'counted $inkPixels ink-ish pixels (floor $floor) -- a '
              'painter that returns early on a null face leaves 0',
        );
      },
    );
  });

  group("idle, another player's turn (enabled: false)", () {
    testWidgets(
      'still shows the idle art, with no pulse -- catches a cube that is '
      'only drawn while it is my own turn to roll',
      (tester) async {
        await _mountDie(tester, face: null, enabled: false, tumbling: false);

        expect(
          find.byKey(_idleArtKey),
          findsOneWidget,
          reason:
              "game-die-idle-art must show on another seat's turn too "
              '(C-238 rule 5: the cube is still drawn, just without a '
              'pulse)',
        );
        expect(
          find.byKey(_pulseKey),
          findsNothing,
          reason: 'game-die-pulse must stay absent when it is not my turn',
        );
        _expectDieSize72(tester);
      },
    );
  });

  group('resting face (face: 4)', () {
    testWidgets(
      'shows only the resting face -- catches the cube leaking into a '
      'face that has already landed',
      (tester) async {
        await _mountDie(tester, face: 4, enabled: true, tumbling: false);

        expect(
          find.byKey(_faceKey(4)),
          findsOneWidget,
          reason: 'game-die-face-4 must be present once the die rests on 4',
        );
        expect(
          find.byKey(_idleArtKey),
          findsNothing,
          reason:
              'game-die-idle-art must be absent once a face has landed; '
              'C-238 rule 3 reserves the cube for face == null',
        );
        expect(
          find.byKey(_blankKey),
          findsNothing,
          reason: 'game-die-blank must be absent once a face has landed',
        );
        _expectDieSize72(tester);
      },
    );
  });

  group('reduced motion, mid-tumble (tumbling: true, face: null)', () {
    testWidgets(
      'shows the cube too, not the empty blank box -- catches the cube '
      'being dropped whenever reduced motion is on',
      (tester) async {
        await _mountDie(
          tester,
          face: null,
          enabled: true,
          tumbling: true,
          disableAnimations: true,
        );

        expect(
          find.byKey(_blankKey),
          findsOneWidget,
          reason:
              'game-die-blank must still mark the reduced-motion tumble '
              '(C-238 rule 4)',
        );
        expect(
          find.byKey(_idleArtKey),
          findsOneWidget,
          reason:
              'game-die-idle-art must also be present under reduced '
              'motion; rule 4 says this path paints the same empty box '
              'today and must paint the cube instead',
        );
        _expectDieSize72(tester);
      },
    );
  });

  group('tumbling, motion allowed (tumbling: true)', () {
    testWidgets('never shows the idle art or a resting face while the cosmetic '
        'tumble is cycling -- catches a cycling face wrongly tagged as idle '
        'art or as a settled result', (tester) async {
      await _mountDie(tester, face: null, enabled: true, tumbling: true);

      expect(
        find.byKey(_tumblingKey),
        findsOneWidget,
        reason: 'fixture is broken: game-die-tumbling must be mounted',
      );
      expect(find.byKey(_idleArtKey), findsNothing);
      _expectNoFaceKeys(
        'no game-die-face-N may appear while the tumble is purely '
        'cosmetic',
      );
      _expectDieSize72(tester);

      // The tumble repeats forever (lesson 10 forbids pumpAndSettle
      // here); a bounded handful of pumps samples several cosmetic
      // faces along the way without ever letting one settle into a key.
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(_idleArtKey), findsNothing);
        _expectNoFaceKeys(
          'no game-die-face-N may appear while the tumble is purely '
          'cosmetic',
        );
      }
    });
  });

  group('no-move mark (noMove: true, face: null)', () {
    testWidgets(
      'the mark and the idle art both show -- catches the new key being '
      'moved onto whatever a resting face would have used instead of the '
      'cube',
      (tester) async {
        await _mountDie(
          tester,
          face: null,
          enabled: true,
          tumbling: false,
          noMove: true,
        );

        expect(
          find.byKey(_noMoveMarkKey),
          findsOneWidget,
          reason: 'game-die-no-move-mark must show while noMove is true',
        );
        expect(
          find.byKey(_idleArtKey),
          findsOneWidget,
          reason:
              'game-die-idle-art must still show underneath the no-move '
              'mark (C-238 rule 6: the mark paints over whatever the die '
              'shows, cube included)',
        );
        _expectDieSize72(tester);
      },
    );
  });
}
