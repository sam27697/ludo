// Tests for C-667t round 2 (order 667, run 156), defect 3 of the RETURN 1
// verdict: a tablet player who turns the device between large portrait (T1,
// 924x1480) and large landscape (T2, 1480x924) mid-move must not lose a walk,
// the die's pop, the gloat or the countdown memo. The contract says the board
// and the die keep their State across the rotation, so the cases below find
// them with tester.state(find.byType(LudoBoard)) and
// tester.state(find.byType(GameDie)) before and after a change of
// tester.view.physicalSize and assert `identical`.
//
// A real GameScreen over a real RoomController on FakeTransport, mounted by
// test/support/roll_tray_harness.dart. My seat 0 has token 0 on progress 1 and
// token 1 on progress 20; it rolls a 5, then the server sends `moved` 1 to 6
// for token 0, so the board walks the token one square per 140 ms
// (kTokenStepDuration). The walk is observed on the painted discs: the
// disc of the mover is looked up by the cell it stands on, expressed in cell
// units of the painted square, so the lookup is the same at both sizes.
//
// No pumpAndSettle: a turn arms a one-second countdown. Every case is a fixed
// list of frames with no seed; the failure text names the direction, locale and
// what was found, which is the whole reproduction. Re-run one case with
//   flutter test test/c667_rotation_state_test.dart --plain-name '<case id>'

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/game_die.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/roll_tray_harness.dart';

class _Surface {
  const _Surface(this.id, this.width, this.height, this.dpr);

  final String id;
  final double width;
  final double height;
  final double dpr;

  Size get physical => Size(width * dpr, height * dpr);
}

const _Surface _t1 = _Surface('T1', 924, 1480, 2.0);
const _Surface _t2 = _Surface('T2', 1480, 924, 2.0);

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

const int _walkFrom = 1;
const int _walkTo = 6;
const int _tokenSteps = _walkTo - _walkFrom;
const Duration _step = kTokenStepDuration;

void _setSurface(WidgetTester tester, _Surface surface) {
  tester.view.physicalSize = surface.physical;
  tester.view.devicePixelRatio = surface.dpr;
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

/// Advances [duration] in 20 ms frames of the test clock.
Future<void> _advance(WidgetTester tester, Duration duration) async {
  const Duration frame = Duration(milliseconds: 20);
  Duration elapsed = Duration.zero;
  while (elapsed < duration) {
    final Duration remaining = duration - elapsed;
    await tester.pump(remaining < frame ? remaining : frame);
    elapsed += remaining < frame ? remaining : frame;
  }
}

/// The painted token discs: one CustomPaint per drawn token, found by the name
/// of its painter so no private symbol is imported.
Finder _discs() => find.byWidgetPredicate(
  (Widget w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString() == '_TokenBodyPainter',
);

/// The progress (1..6) whose track cell has a drawn disc on it, or null. The
/// other tokens are a yard disc and token 1 on progress 20, so a disc on one
/// of these six cells is the walking token.
int? _moverProgress(WidgetTester tester) {
  final Rect square = boardSquare(tester);
  final double cell = square.width / 15;
  final Finder discs = _discs();
  final int n = discs.evaluate().length;
  int? found;
  for (int p = _walkFrom; p <= _walkTo; p++) {
    final BoardCell c = toView(cellFor(seat: 0, progress: p), viewQuarters(0));
    final Offset centre = Offset(
      square.left + (c.col + 0.5) * cell,
      square.top + (c.row + 0.5) * cell,
    );
    for (int i = 0; i < n; i++) {
      final Offset at = tester.getCenter(discs.at(i));
      if ((at - centre).distance <= 0.3 * cell) {
        found = p;
      }
    }
  }
  return found;
}

class _Rig {
  _Rig(this.drive);

  final RollTrayDrive drive;
}

/// Mounts a GameScreen on [start] in [locale], plays my roll of 5 and sends
/// the server's `moved` for token 0 (1 to 6) and the next seat's turn, then
/// lets the first two steps of the walk play. Hands the body a state where the
/// mover stands on progress 3, two steps from its start.
Future<void> _midWalk(
  WidgetTester tester,
  _Surface start,
  Locale locale,
  Future<void> Function(_Rig rig) body,
) async {
  _setSurface(tester, start);
  addTearDown(tester.view.reset);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]),
    seats: twoSeats(mine: const <int>[_walkFrom, 20, -1, -1]),
  );
  try {
    await mountGame(tester, drive, locale: locale);
    await drive.push(tester, 'rolled', <String, Object?>{
      'seat': 0,
      'value': _tokenSteps,
      'legal': <int>[0, 1],
      'deadline_ms': rollTrayDeadlineMs,
      'k': 1,
      'reveal': rollTrayReveal,
    });
    await drive.push(tester, 'moved', <String, Object?>{
      'seat': 0,
      'token': 0,
      'from': _walkFrom,
      'to': _walkTo,
      'captured': <Object?>[],
      'extra_roll': false,
    });
    await drive.push(tester, 'turn', <String, Object?>{
      'seat': 1,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'queue': <int>[],
    });
    await _advance(tester, _step * 2 + const Duration(milliseconds: 20));
    await body(_Rig(drive));
  } finally {
    await releaseGame(tester, drive);
    tester.view.reset();
  }
}

String _scenario(String id, _Surface from, _Surface to, Locale locale) =>
    'scenario: $id, ${from.id} ${from.width.toStringAsFixed(0)}x'
    '${from.height.toStringAsFixed(0)} to ${to.id}, locale '
    '${locale.languageCode}, mover walks progress $_walkFrom to $_walkTo; '
    "rerun with --plain-name '$id ${from.id} to ${to.id} "
    "${locale.languageCode}'";

void _expectSame(Object before, Object after, String what, String scenario) {
  if (!identical(before, after)) {
    fail(
      'C-667t r2 defect 3: expected the $what to keep its State across the '
      'rotation (identical object); got a new one: before '
      '${before.hashCode} (${before.runtimeType}), after ${after.hashCode} '
      '(${after.runtimeType}). $scenario',
    );
  }
}

/// Every State of every StatefulWidget under GameScreen, grouped by the type
/// of the State object.
Map<String, List<State<StatefulWidget>>> _statesByType(WidgetTester tester) {
  final Map<String, List<State<StatefulWidget>>> out =
      <String, List<State<StatefulWidget>>>{};
  final Finder all = find.descendant(
    of: find.byType(GameScreen),
    matching: find.byWidgetPredicate((Widget w) => w is StatefulWidget),
  );
  for (final Element e in all.evaluate()) {
    if (e is StatefulElement) {
      out.putIfAbsent(e.state.runtimeType.toString(), () => []).add(e.state);
    }
  }
  return out;
}

void main() {
  setUpAll(_loadAppFonts);

  for (final (_Surface from, _Surface to) in <(_Surface, _Surface)>[
    (_t1, _t2),
    (_t2, _t1),
  ]) {
    for (final Locale locale in _locales) {
      final String scenario = _scenario('R1', from, to, locale);

      testWidgets('R1 ${from.id} to ${to.id} ${locale.languageCode} '
          'board and die keep their State, the walk lands', (
        WidgetTester tester,
      ) async {
        await _midWalk(tester, from, locale, (_Rig rig) async {
          expect(
            find.byType(LudoBoard),
            findsOneWidget,
            reason: 'fixture is broken: one LudoBoard. $scenario',
          );
          expect(
            find.byType(GameDie),
            findsOneWidget,
            reason: 'fixture is broken: one GameDie. $scenario',
          );
          final State<StatefulWidget> board = tester.state(
            find.byType(LudoBoard),
          );
          final State<StatefulWidget> die = tester.state(find.byType(GameDie));
          final int? before = _moverProgress(tester);
          expect(
            before != null && before > _walkFrom && before < _walkTo,
            isTrue,
            reason:
                'fixture is broken: expected the mover on a square after '
                '$_walkFrom and before $_walkTo, found $before. $scenario',
          );

          _setSurface(tester, to);
          await tester.pump();

          _expectSame(
            board,
            tester.state(find.byType(LudoBoard)),
            'LudoBoard',
            scenario,
          );
          _expectSame(
            die,
            tester.state(find.byType(GameDie)),
            'GameDie',
            scenario,
          );
          expect(
            _moverProgress(tester),
            before,
            reason:
                'defect 3: the mover stood on progress $before before the '
                'rotation and must stand on the same square, not restart or '
                'snap to its destination. $scenario',
          );

          await _advance(tester, _step * (_tokenSteps + 2));
          expect(
            _moverProgress(tester),
            _walkTo,
            reason:
                'defect 3: the walk finishes and the token lands on '
                'progress $_walkTo. $scenario',
          );
          _expectSame(
            board,
            tester.state(find.byType(LudoBoard)),
            'LudoBoard (after the walk)',
            scenario,
          );
        });
      });
    }
  }

  for (final (_Surface a, _Surface b) in <(_Surface, _Surface)>[
    (_t1, _t2),
    (_t2, _t1),
  ]) {
    for (final Locale locale in _locales) {
      final String scenario = _scenario('R2', a, b, locale);

      testWidgets('R2 ${a.id} to ${b.id} ${locale.languageCode} '
          'there and back mid-walk keeps both States', (
        WidgetTester tester,
      ) async {
        await _midWalk(tester, a, locale, (_Rig rig) async {
          final State<StatefulWidget> board = tester.state(
            find.byType(LudoBoard),
          );
          final State<StatefulWidget> die = tester.state(find.byType(GameDie));

          _setSurface(tester, b);
          await tester.pump();
          await tester.pump(_step);
          _setSurface(tester, a);
          await tester.pump();

          _expectSame(
            board,
            tester.state(find.byType(LudoBoard)),
            'LudoBoard (there and back)',
            scenario,
          );
          _expectSame(
            die,
            tester.state(find.byType(GameDie)),
            'GameDie (there and back)',
            scenario,
          );
          await _advance(tester, _step * (_tokenSteps + 2));
          expect(
            _moverProgress(tester),
            _walkTo,
            reason:
                'defect 3: after two rotations the walk still lands on '
                'progress $_walkTo. $scenario',
          );
        });
      });
    }
  }

  for (final (_Surface a, _Surface b) in <(_Surface, _Surface)>[
    (_t1, _t2),
    (_t2, _t1),
  ]) {
    for (final Locale locale in _locales) {
      final String scenario = _scenario('R3', a, b, locale);

      testWidgets('R3 ${a.id} to ${b.id} ${locale.languageCode} '
          'no State that exists on both layouts is replaced', (
        WidgetTester tester,
      ) async {
        await _midWalk(tester, a, locale, (_Rig rig) async {
          final Map<String, List<State<StatefulWidget>>> before = _statesByType(
            tester,
          );
          _setSurface(tester, b);
          await tester.pump();
          final Map<String, List<State<StatefulWidget>>> after = _statesByType(
            tester,
          );

          final List<String> replaced = <String>[];
          for (final MapEntry<String, List<State<StatefulWidget>>> e
              in before.entries) {
            final List<State<StatefulWidget>>? kept = after[e.key];
            if (kept == null) {
              continue;
            }
            final int lost = e.value
                .where((State<StatefulWidget> s) => !kept.contains(s))
                .length;
            if (lost > 0) {
              replaced.add(
                '${e.key}: $lost of ${e.value.length} State objects replaced '
                '(${kept.length} now mounted)',
              );
            }
          }
          expect(
            replaced,
            isEmpty,
            reason:
                'defect 3: the header countdown, chat and gloat overlay keep '
                'the State they hold today, and so does everything else that '
                'is built in both layouts. ${replaced.join('; ')}. '
                '$scenario',
          );
        });
      });
    }
  }
}
