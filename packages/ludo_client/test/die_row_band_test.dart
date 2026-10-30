// Acceptance corpus for C-511 (order 512): the die row keeps clear of the
// hint control and holds every queue the rules reach. Written from the
// contract's D5 (work/ludo/orders/C-511-die-row-band.md), not from the
// implementation. A real GameScreen is mounted on my own seat's await_move
// (roll_tray_harness.dart), and every rect below is measured off the tree.
//
// What each case holds, from D1 to D5:
//   - no Flutter layout error on any frame it pumps;
//   - the die, the no-move mark (when shown) and every tray tile sit inside
//     the screen and do not intersect `game-hint-button`;
//   - the per-tile counts, read off the TalkBack labels as C-420 D5 reads
//     them, sum to the number of faces in the tray;
//   - where the content (die, mark, tray) centred on the board's centre
//     would be clear of the reserved extent (the hint rect widened by kSpace2
//     on its end side), the union of die and tray is centred on the board
//     within 1 dp (C-471 A2's measure); where it would not, the content's
//     start edge is within 1 dp of the reserved extent's end.
//
// Boards. Seat 0 is mine, seat 1 is Bob. Mine [16, 30, yard, yard], Bob
// [1, yard x3]: a 6 can move any of my four tokens and any other face only
// the two on the track, so every queued face has a legal token, and the
// hint offers more than one choice (it is `ready`). `used` is the same
// board with the game id stored in the hint's preference key.
//
// The beat case is a no-move end: my last live face is spent and the four
// that remain are dead for the one token left, three steps from home.
//
// "Hint absent" is not a case here. On my own turn with a tray under the
// board the room is PLAYING and I hold a seat, which is exactly when the
// hint control is on screen (waiting, ready or used), so no reachable state
// shows the tray on my turn without it.
//
// Every case is named queue, size, scale, locale and hint state, and its
// failure line carries those plus the measured rects; rerun one with
// `flutter test test/die_row_band_test.dart --plain-name '<case name>'`.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsHandle, SemanticsNode;
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/theme.dart' show kSpace2;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/roll_tray_harness.dart';

const List<List<int>> _queues = <List<int>>[
  <int>[6, 6, 3],
  <int>[6, 6, 6, 2],
  <int>[6, 3, 6, 2],
  <int>[6, 6, 6, 6, 2],
  <int>[3, 6, 6, 2, 6, 6, 4],
];
const List<Size> _sizes = <Size>[
  Size(320, 568),
  Size(360, 640),
  Size(411, 704),
];
const List<double> _scales = <double>[1.0, 2.0];
const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

const Size _usedSize = Size(360, 640);
const String _gameId = 'game-0511';

// One dp of slack is what D5 allows on the placement measures; the
// intersection tests only forgive float noise.
const double _placeTolerance = 1.0;
const double _touchTolerance = 1e-3;

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

String _sizeLabel(Size size) => '${size.width.toInt()}x${size.height.toInt()}';

String _rectLabel(Rect? rect) => rect == null
    ? 'MISSING'
    : 'L${rect.left.toStringAsFixed(1)} T${rect.top.toStringAsFixed(1)} '
          'R${rect.right.toStringAsFixed(1)} B${rect.bottom.toStringAsFixed(1)}';

/// Every face of [queue] needs at least one legal token: a 6 moves any of my
/// four, any other face the two tokens on the track.
List<Map<String, Object?>> _legalByFace(List<int> queue) {
  final List<int> distinct = <int>[];
  for (final int face in queue) {
    if (!distinct.contains(face)) {
      distinct.add(face);
    }
  }
  return <Map<String, Object?>>[
    for (final int face in distinct)
      faceLegal(face, face == 6 ? const <int>[0, 1, 2, 3] : const <int>[0, 1]),
  ];
}

String _hintStateOf(WidgetTester tester) {
  if (!tester.any(find.byKey(hintButtonKey))) {
    return 'absent';
  }
  final Map<String, Key> keys = <String, Key>{
    'ready': hintReadyKey,
    'waiting': hintWaitingKey,
    'used': hintUsedKey,
  };
  final List<String> inside = <String>[
    for (final MapEntry<String, Key> e in keys.entries)
      if (tester.any(
        find.descendant(
          of: find.byKey(hintButtonKey),
          matching: find.byKey(e.value),
        ),
      ))
        e.key,
  ];
  return inside.length == 1 ? inside.single : 'broken: $inside';
}

/// The tile's own TalkBack label carries its count (C-420 D5); a label with
/// no count suffix is a count of one.
int _tileCount(WidgetTester tester, int index, Locale locale) {
  final SemanticsNode node = tester.getSemantics(find.byKey(trayDieKey(index)));
  final RegExp suffix = locale.languageCode == 'ar'
      ? RegExp(r'، العدد (\d+)$')
      : RegExp(r', (\d+) of them$');
  final RegExpMatch? match = suffix.firstMatch(node.label);
  return match == null ? 1 : int.parse(match.group(1)!);
}

Future<void> _flush(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Short frames so a tray entrance finishes, with the countdown and the
/// legal rings still animating (nothing settles on this screen).
Future<void> _frames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

bool _intersects(Rect a, Rect b) => a.deflate(_touchTolerance).overlaps(b);

/// What one case measured, with the line that names the scenario.
class _Band {
  _Band({
    required this.scenario,
    required this.size,
    required this.locale,
    required this.facesInTray,
  });

  final String scenario;
  final Size size;
  final Locale locale;
  final int facesInTray;

  final List<String> problems = <String>[];

  void measure(WidgetTester tester, List<FlutterErrorDetails> captured) {
    final bool rtl = locale.languageCode == 'ar';
    final Rect screen = Offset.zero & size;
    final String hintState = _hintStateOf(tester);
    final Rect? hint = tester.any(find.byKey(hintButtonKey))
        ? tester.getRect(find.byKey(hintButtonKey))
        : null;
    final Rect? die = tester.any(find.byKey(bigDieKey))
        ? tester.getRect(find.byKey(bigDieKey))
        : null;
    final Rect? mark = tester.any(find.byKey(noMoveMarkKey))
        ? tester.getRect(find.byKey(noMoveMarkKey))
        : null;
    final Rect? tray = tester.any(find.byKey(rollTrayKey))
        ? tester.getRect(find.byKey(rollTrayKey))
        : null;
    final Rect board = boardSquare(tester);

    final Map<int, Rect> tiles = <int, Rect>{};
    final List<int> counts = <int>[];
    for (int i = 0; i < facesInTray; i++) {
      if (tester.any(find.byKey(trayDieKey(i)))) {
        tiles[i] = tester.getRect(find.byKey(trayDieKey(i)));
        counts.add(_tileCount(tester, i, locale));
      }
    }
    final int countSum = counts.fold(0, (int a, int b) => a + b);

    final String numbers =
        'hint=$hintState hintRect=${_rectLabel(hint)} '
        'die=${_rectLabel(die)} mark=${_rectLabel(mark)} '
        'tray=${_rectLabel(tray)} '
        'tiles={${tiles.entries.map((MapEntry<int, Rect> e) => '${e.key}: ${_rectLabel(e.value)}').join(', ')}} '
        'counts=$counts board=${_rectLabel(board)}';
    _print('BAND $scenario $numbers errors=${captured.length}');

    if (captured.isNotEmpty) {
      problems.add(
        'flutter reported ${captured.length} error(s): '
        '${captured.map((FlutterErrorDetails d) => d.exceptionAsString().split('\n').first).toSet().join(' || ')}',
      );
    }
    if (die == null) {
      problems.add('game-die is missing from the tree');
    }
    if (tray == null) {
      problems.add('game-roll-tray is missing from the tree');
    }
    if (countSum != facesInTray) {
      problems.add(
        'tray tile counts $counts (tiles ${tiles.keys.toList()}) sum to '
        '$countSum, not the $facesInTray faces in the tray',
      );
    }

    final Map<String, Rect> parts = <String, Rect>{
      'game-die': ?die,
      'game-die-no-move-mark': ?mark,
      for (final MapEntry<int, Rect> e in tiles.entries)
        'game-roll-tray-die-${e.key}': e.value,
    };
    for (final MapEntry<String, Rect> part in parts.entries) {
      final Rect rect = part.value;
      if (rect.left < screen.left - _touchTolerance ||
          rect.right > screen.right + _touchTolerance ||
          rect.top < screen.top - _touchTolerance ||
          rect.bottom > screen.bottom + _touchTolerance) {
        problems.add(
          '${part.key} ${_rectLabel(rect)} is outside the screen '
          '${_rectLabel(screen)}',
        );
      }
      if (hint != null && _intersects(rect, hint)) {
        problems.add(
          '${part.key} ${_rectLabel(rect)} intersects game-hint-button '
          '${_rectLabel(hint)}',
        );
      }
    }

    if (hint == null || die == null || tray == null) {
      return;
    }

    // The reserved extent: the hint's own rect, widened by kSpace2 on its
    // end side (right in en, left in ar). Horizontal measures only; the hint
    // and the row share their vertical band.
    final double reservedStart = hint.left - (rtl ? kSpace2 : 0);
    final double reservedEnd = hint.right + (rtl ? 0 : kSpace2);

    double left = die.left < tray.left ? die.left : tray.left;
    double right = die.right > tray.right ? die.right : tray.right;
    final double centred = (left + right) / 2;
    if (mark != null) {
      left = left < mark.left ? left : mark.left;
      right = right > mark.right ? right : mark.right;
    }
    final double contentWidth = right - left;
    final double boardCentre = board.center.dx;

    final double boxLeft = boardCentre - contentWidth / 2;
    final double boxRight = boardCentre + contentWidth / 2;
    final bool clearWhenCentred =
        boxRight <= reservedStart + _touchTolerance ||
        boxLeft >= reservedEnd - _touchTolerance;
    final String why =
        'reserved extent ${reservedStart.toStringAsFixed(1)}..'
        '${reservedEnd.toStringAsFixed(1)}, content '
        '${left.toStringAsFixed(1)}..${right.toStringAsFixed(1)} '
        '(width ${contentWidth.toStringAsFixed(1)}), board centre '
        '${boardCentre.toStringAsFixed(1)}, centred box '
        '${boxLeft.toStringAsFixed(1)}..${boxRight.toStringAsFixed(1)}';

    if (clearWhenCentred) {
      if ((centred - boardCentre).abs() > _placeTolerance) {
        problems.add(
          'centred box is clear of the reserved extent, so die plus tray '
          'should be centred on the board: their centre is '
          '${centred.toStringAsFixed(1)}, off by '
          '${(centred - boardCentre).abs().toStringAsFixed(1)} dp; $why',
        );
      }
    } else {
      final double startEdge = rtl ? right : left;
      final double wanted = rtl ? reservedStart : reservedEnd;
      if ((startEdge - wanted).abs() > _placeTolerance) {
        problems.add(
          'centred box would meet the reserved extent, so the content start '
          'edge should sit at ${wanted.toStringAsFixed(1)}: it is at '
          '${startEdge.toStringAsFixed(1)}, off by '
          '${(startEdge - wanted).abs().toStringAsFixed(1)} dp; $why',
        );
      }
    }
  }
}

Future<void> _withScreen(
  WidgetTester tester, {
  required Size size,
  required Map<String, Object> stored,
  required Future<void> Function(List<FlutterErrorDetails> captured) body,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{...stored});
  final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = captured.add;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final SemanticsHandle semantics = tester.ensureSemantics();
  try {
    await body(captured);
  } finally {
    FlutterError.onError = previous;
    semantics.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

Future<void> _runQueue(
  WidgetTester tester, {
  required List<int> queue,
  required Size size,
  required double scale,
  required Locale locale,
  required String hint,
  required String name,
}) {
  final String scenario =
      'queue $queue ${_sizeLabel(size)} scale ${scale.toStringAsFixed(1)} '
      '${locale.languageCode} hint $hint';
  return _withScreen(
    tester,
    size: size,
    stored: hint == 'used'
        ? <String, Object>{hintUsedPrefsKey: _gameId}
        : const <String, Object>{},
    body: (List<FlutterErrorDetails> captured) async {
      RollTrayDrive? drive;
      try {
        drive = await connectPlaying(
          tester,
          seats: twoSeats(
            mine: const <int>[16, 30, -1, -1],
            other: const <int>[1, -1, -1, -1],
          ),
          gameId: _gameId,
          turn: turnJson(
            seat: 0,
            phase: 'await_move',
            k: queue.length,
            value: queue.first,
            legal: const <int>[0, 1, 2, 3],
            queue: queue,
            legalByFace: _legalByFace(queue),
          ),
        );
        await mountGame(tester, drive, locale: locale, textScale: scale);
        await _flush(tester);
        await _frames(tester, 12);

        final _Band band = _Band(
          scenario: scenario,
          size: size,
          locale: locale,
          facesInTray: queue.length,
        );
        final String state = _hintStateOf(tester);
        if (state != hint) {
          band.problems.add(
            'fixture is broken: expected hint state $hint, got $state',
          );
        }
        band.measure(tester, captured);
        expect(
          band.problems,
          isEmpty,
          reason:
              '$scenario: ${band.problems.join(' ; ')}. Reproduce with: '
              "flutter test test/die_row_band_test.dart --plain-name '$name'",
        );
      } finally {
        final RollTrayDrive? owned = drive;
        if (owned != null) {
          await releaseGame(tester, owned);
        }
      }
    },
  );
}

/// The no-move beat: my token three steps from home spends its one live
/// face, which leaves four dead faces and the big die's no-move mark.
Future<void> _runBeat(
  WidgetTester tester, {
  required Size size,
  required double scale,
  required Locale locale,
  required String name,
}) {
  const List<int> before = <int>[1, 6, 6, 5, 4];
  const List<int> dead = <int>[6, 6, 5, 4];
  final String scenario =
      'beat dead faces $dead ${_sizeLabel(size)} scale '
      '${scale.toStringAsFixed(1)} ${locale.languageCode}';
  return _withScreen(
    tester,
    size: size,
    stored: const <String, Object>{},
    body: (List<FlutterErrorDetails> captured) async {
      RollTrayDrive? drive;
      try {
        drive = await connectPlaying(
          tester,
          seats: twoSeats(
            mine: const <int>[54, 57, 57, 57],
            other: const <int>[1, -1, -1, -1],
          ),
          gameId: _gameId,
          turn: turnJson(
            seat: 0,
            phase: 'await_move',
            k: before.length,
            value: before.first,
            legal: const <int>[0],
            queue: before,
            legalByFace: <Map<String, Object?>>[
              faceLegal(1, const <int>[0]),
            ],
          ),
        );
        await mountGame(tester, drive, locale: locale, textScale: scale);
        await _flush(tester);
        await drive.push(tester, 'moved', <String, Object?>{
          'seat': 0,
          'token': 0,
          'from': 54,
          'to': 55,
          'captured': <Object?>[],
          'extra_roll': false,
          'face': 1,
        });
        await drive.push(tester, 'turn_passed', <String, Object?>{
          'seat': 0,
          'reason': 'no_legal_move',
        });
        await drive.push(tester, 'turn', <String, Object?>{
          'seat': 1,
          'phase': 'await_roll',
          'deadline_ms': rollTrayDeadlineMs,
          'queue': <int>[],
        });
        await _flush(tester);
        await _frames(tester, 6);

        final _Band band = _Band(
          scenario: scenario,
          size: size,
          locale: locale,
          facesInTray: dead.length,
        );
        if (!tester.any(find.byKey(noMoveMarkKey))) {
          band.problems.add(
            'fixture is broken: game-die-no-move-mark is not shown',
          );
        }
        for (int i = 0; i < dead.length; i++) {
          if (tester.any(find.byKey(trayDieKey(i))) &&
              !tester.any(
                find.descendant(
                  of: find.byKey(trayDieKey(i)),
                  matching: find.byKey(trayDeadKey(i)),
                ),
              )) {
            band.problems.add(
              'fixture is broken: tile $i is shown but is not dead',
            );
          }
        }
        if (!tester.any(find.byKey(hintButtonKey))) {
          band.problems.add('fixture is broken: no hint control on screen');
        }
        band.measure(tester, captured);
        expect(
          band.problems,
          isEmpty,
          reason:
              '$scenario: ${band.problems.join(' ; ')}. Reproduce with: '
              "flutter test test/die_row_band_test.dart --plain-name '$name'",
        );
      } finally {
        final RollTrayDrive? owned = drive;
        if (owned != null) {
          await releaseGame(tester, owned);
        }
      }
    },
  );
}

void main() {
  setUpAll(_loadAppFonts);

  for (final List<int> queue in _queues) {
    for (final Size size in _sizes) {
      for (final double scale in _scales) {
        for (final Locale locale in _locales) {
          final String name =
              'queue $queue ${_sizeLabel(size)} scale '
              '${scale.toStringAsFixed(1)} ${locale.languageCode} hint ready';
          testWidgets(
            name,
            (tester) => _runQueue(
              tester,
              queue: queue,
              size: size,
              scale: scale,
              locale: locale,
              hint: 'ready',
              name: name,
            ),
          );
        }
      }
    }
  }

  for (final List<int> queue in _queues) {
    for (final double scale in _scales) {
      for (final Locale locale in _locales) {
        final String name =
            'queue $queue ${_sizeLabel(_usedSize)} scale '
            '${scale.toStringAsFixed(1)} ${locale.languageCode} hint used';
        testWidgets(
          name,
          (tester) => _runQueue(
            tester,
            queue: queue,
            size: _usedSize,
            scale: scale,
            locale: locale,
            hint: 'used',
            name: name,
          ),
        );
      }
    }
  }

  const Locale ar = Locale('ar');
  final String beatName =
      'beat dead faces [6, 6, 5, 4] ${_sizeLabel(_usedSize)} scale 1.0 ar';
  testWidgets(
    beatName,
    (tester) => _runBeat(
      tester,
      size: _usedSize,
      scale: 1.0,
      locale: ar,
      name: beatName,
    ),
  );
}
