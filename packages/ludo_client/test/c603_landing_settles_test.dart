// Acceptance tests for work/ludo/orders/603-landing-takes-shared-slot.md
// (C-603, run 139), written from its contract D1 to D3 and not from the code
// that draws the discs.
//
// A walk that lands on a main-track cell other seats already stand on must
// take its place once: the mover's disc, drawn at the shared diameter, is not
// drawn at the one-seat fan again, and no other token on the cell goes shared
// -> fan -> shared. The squares the walk only crosses keep today's rule (a
// token crossing a cell is not an occupant of it, C-408 decision 3): the
// mover keeps the fan there and a token standing there is not resized.
//
// Cases (a), (b), (c), (c2), (a-reduced) and (d), (d2) mount a real LudoBoard
// in a small host (the way test/token_travel_test.dart does), push a new
// truth in which one token moved, and then read the rendered
// `token-<seat>-<i>` disc (the DecoratedBox under that key) every 16 ms for
// 2500 ms of fake clock. Case (e) is the exact `four_seats_1` moment of order
// 602: the recorded game of test fixture real_games.json replayed through a
// real HomeScreen, RoomController and FakeTransport to the `moved` of seq 639
// in seat 2's view, and the same sampling on the board the game screen
// builds.
//
// The cell size is the board's width over 15 and every expected diameter is a
// fraction of it (0.7 for the fan, 0.5 for a shared slot, per C-386); no
// sampled number is written down here. "The frame the mover's drawn progress
// first equals its destination" is the first sample whose mover disc is
// centred inside the destination cell: the squares before it are other cells.
//
// Every failure names the scenario, the viewer, the before and after truth,
// and the sampled (time, diameter, centre) sequence around the offending
// frame, which is all that is needed to rerun it: the clock is the test
// binding's, there is no randomness.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/die_cube.dart' show BoardThrownDie;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:shared_preferences/shared_preferences.dart';

import '../integration_test/fixtures/real_games_fixture.dart'
    show realGamesJson;
import 'net/fake_transport.dart';

const double _boardSide = 360;
const double _tolerance = 0.6;
const Duration _period = Duration(milliseconds: 16);
const int _windowMs = 2500;

// C-386 fractions of one cell: the one-seat fan diameter, and the shared
// diameter and quad offset.
const double _fanDiameter = 0.7;
const double _sharedDiameter = 0.5;
const double _sharedOffset = 0.22;

enum _Form { fan, shared, other }

typedef _Id = (int seat, int token);

/// Absolute main-track square of [seat]'s token at [progress] (RULES.md
/// section 1.2: a seat enters at 13 * seat).
int _absolute(int seat, int progress) => (13 * seat + progress) % 52;

/// Progress of [seat]'s token on the absolute square [absolute].
int _progressOn(int seat, int absolute) => (absolute - 13 * seat) % 52;

Map<int, List<int>> _truth(List<int> seats, Map<_Id, int> at) {
  return <int, List<int>>{
    for (final int seat in seats)
      seat: <int>[for (int t = 0; t < 4; t++) at[(seat, t)] ?? -1],
  };
}

/// What a case moves and who stands where, whichever way it is mounted.
class _Move {
  const _Move({
    required this.label,
    required this.mySeat,
    required this.mover,
    required this.from,
    required this.to,
    required this.others,
  });

  final String label;
  final int mySeat;
  final _Id mover;
  final int from;
  final int to;

  /// Every token that stands still for the whole walk: id -> progress.
  final Map<_Id, int> others;

  /// Tokens on the destination cell, mover first.
  List<_Id> get onDestination {
    final int square = _absolute(mover.$1, to);
    return <_Id>[
      mover,
      for (final MapEntry<_Id, int> e in others.entries)
        if (e.value >= 0 &&
            e.value <= 51 &&
            _absolute(e.key.$1, e.value) == square)
          e.key,
    ];
  }

  /// Tokens standing on a square the walk only crosses.
  List<_Id> get onPath {
    final Set<int> squares = <int>{
      for (int p = from + 1; p < to; p++) _absolute(mover.$1, p),
    };
    return <_Id>[
      for (final MapEntry<_Id, int> e in others.entries)
        if (e.value >= 0 &&
            e.value <= 51 &&
            squares.contains(_absolute(e.key.$1, e.value)))
          e.key,
    ];
  }

  String describe() =>
      '$label (viewer seat $mySeat, mover $mover $from -> $to, others '
      '$others, sampled every ${_period.inMilliseconds} ms for $_windowMs ms)';
}

class _Scenario extends _Move {
  const _Scenario({
    required super.label,
    required this.seats,
    required super.mySeat,
    required super.mover,
    required super.from,
    required super.to,
    required super.others,
    this.reduced = false,
  });

  final List<int> seats;
  final bool reduced;

  Map<int, List<int>> get before =>
      _truth(seats, <_Id, int>{...others, mover: from});
  Map<int, List<int>> get after =>
      _truth(seats, <_Id, int>{...others, mover: to});

  @override
  String describe() =>
      '${super.describe()}, reduced motion $reduced, before $before, '
      'after $after';
}

class _Disc {
  const _Disc(this.diameter, this.centre);
  final double diameter;
  final Offset centre;
}

class _Sample {
  const _Sample(this.ms, this.steps, this.discs);
  final int ms;

  /// Steps of the walk fired so far, or -1 where the board is not the test's.
  final int steps;
  final Map<_Id, _Disc> discs;
}

class _Run {
  _Run(this.move, this.cell, this.samples, this.destination, this.tracked);

  final _Move move;
  final double cell;
  final List<_Sample> samples;
  final List<_Id> tracked;

  /// The destination cell, board coordinates.
  final Rect destination;

  Offset get restCell => destination.center;

  _Form formOf(double diameter) {
    if ((diameter - cell * _fanDiameter).abs() <= _tolerance) {
      return _Form.fan;
    }
    if ((diameter - cell * _sharedDiameter).abs() <= _tolerance) {
      return _Form.shared;
    }
    return _Form.other;
  }

  _Sample get last => samples.last;

  /// First sample whose mover disc is centred inside the destination cell.
  int get arrivalIndex => samples.indexWhere(
    (s) => destination.contains(s.discs[move.mover]!.centre),
  );

  /// The sampled (time, steps, diameter, centre) lines of [id] around [at].
  String trace(_Id id, int at, {int radius = 4}) {
    final StringBuffer out = StringBuffer();
    final int lo = (at - radius).clamp(0, samples.length - 1);
    final int hi = (at + radius).clamp(0, samples.length - 1);
    for (int i = lo; i <= hi; i++) {
      final _Disc d = samples[i].discs[id]!;
      out.writeln(
        '    ${i == at ? '>>' : '  '} token-${id.$1}-${id.$2} '
        't=${samples[i].ms} ms '
        'diameter=${d.diameter.toStringAsFixed(2)} '
        '(${formOf(d.diameter).name}) '
        'centre=(${d.centre.dx.toStringAsFixed(2)}, '
        '${d.centre.dy.toStringAsFixed(2)})',
      );
    }
    return out.toString();
  }
}

Widget _harness({
  required GlobalKey<_HostState> hostKey,
  required _Scenario scenario,
  required void Function() onMoverStep,
}) {
  final Widget host = _Host(
    key: hostKey,
    tokens: scenario.before,
    seats: scenario.seats,
    mySeat: scenario.mySeat,
    onTokenStep: (int seat, int token) {
      if ((seat, token) == scenario.mover) {
        onMoverStep();
      }
    },
  );
  return MaterialApp(
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _boardSide,
          height: _boardSide,
          child: scenario.reduced
              ? Builder(
                  builder: (BuildContext context) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: host,
                  ),
                )
              : host,
        ),
      ),
    ),
  );
}

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.tokens,
    required this.seats,
    required this.mySeat,
    required this.onTokenStep,
  });

  final Map<int, List<int>> tokens;
  final List<int> seats;
  final int mySeat;
  final void Function(int seat, int token) onTokenStep;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Map<int, List<int>> _tokens = widget.tokens;

  void setTokens(Map<int, List<int>> next) {
    setState(() {
      _tokens = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LudoBoard(
      tokens: _tokens,
      seatsInPlay: widget.seats,
      mySeat: widget.mySeat,
      legal: const <int>{},
      onTokenStep: widget.onTokenStep,
    );
  }
}

/// The painted square of the board: the board centres a square of the
/// smaller side inside whatever box it is given, and every disc is placed
/// relative to that square.
Rect _boardSquare(WidgetTester tester) {
  final Finder square = find
      .descendant(
        of: find.byKey(const Key('ludo-board')),
        matching: find.byType(SizedBox),
      )
      .first;
  return tester.getRect(square);
}

/// Reads the rendered disc of every id in [tracked] now, in board coordinates.
Map<_Id, _Disc> _readDiscs(
  WidgetTester tester,
  List<_Id> tracked,
  Offset origin,
) {
  return <_Id, _Disc>{
    for (final _Id id in tracked)
      id: () {
        final Finder disc = find.descendant(
          of: find.byKey(Key('token-${id.$1}-${id.$2}')),
          matching: find.byType(DecoratedBox),
        );
        return _Disc(
          tester.getSize(disc.first).width,
          tester.getCenter(disc.first) - origin,
        );
      }(),
  };
}

Rect _destinationRect(_Move move, double cell) {
  final BoardCell c = toView(
    cellFor(seat: move.mover.$1, progress: move.to, tokenIndex: move.mover.$2),
    viewQuarters(move.mySeat),
  );
  return Rect.fromLTWH(c.col * cell, c.row * cell, cell, cell);
}

/// Samples [tracked] on the board now and every 16 ms until 2500 ms later.
Future<List<_Sample>> _sample(
  WidgetTester tester,
  List<_Id> tracked,
  int Function() steps,
) async {
  final Offset origin = _boardSquare(tester).topLeft;
  final List<_Sample> samples = <_Sample>[];
  for (int ms = 0; ms <= _windowMs + _period.inMilliseconds; ms += 16) {
    samples.add(_Sample(ms, steps(), _readDiscs(tester, tracked, origin)));
    await tester.pump(_period);
  }
  return samples;
}

List<_Id> _trackedFor(_Move move) => <_Id>[
  ...move.onDestination,
  ...move.onPath,
];

/// Mounts [scenario], pushes the new truth, and samples every disc that
/// matters every 16 ms from the moved frame until 2500 ms later.
Future<_Run> _play(WidgetTester tester, _Scenario scenario) async {
  tester.view.physicalSize = const Size(_boardSide, _boardSide);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
  int steps = 0;
  await tester.pumpWidget(
    _harness(hostKey: hostKey, scenario: scenario, onMoverStep: () => steps++),
  );
  await tester.pump();

  hostKey.currentState!.setTokens(scenario.after);
  await tester.pump();

  final List<_Id> tracked = _trackedFor(scenario);
  final List<_Sample> samples = await _sample(tester, tracked, () => steps);
  final double cell = _boardSquare(tester).width / 15;
  return _Run(
    scenario,
    cell,
    samples,
    _destinationRect(scenario, cell),
    tracked,
  );
}

String _where(_Run run) => 'scenario: ${run.move.describe()}';

bool _near(Offset a, Offset b) => (a - b).distance <= _tolerance;

/// The resting layout, from the last sample, checked against the C-386
/// fractions: shared diameter, and a quad slot (cell centre +- 0.22 cell on
/// both axes), no two discs on one slot.
void _expectRestingLayoutIsSharedQuad(_Run run) {
  final Set<String> slots = <String>{};
  for (final _Id id in run.move.onDestination) {
    final _Disc rest = run.last.discs[id]!;
    expect(
      rest.diameter,
      closeTo(run.cell * _sharedDiameter, _tolerance),
      reason:
          'token-${id.$1}-${id.$2} at rest on the destination cell should be '
          '${run.cell * _sharedDiameter} dp (0.5 of the cell), is '
          '${rest.diameter}; ${_where(run)}',
    );
    final Offset d = rest.centre - run.restCell;
    expect(
      (d.dx.abs() - run.cell * _sharedOffset).abs() <= _tolerance &&
          (d.dy.abs() - run.cell * _sharedOffset).abs() <= _tolerance,
      isTrue,
      reason:
          'token-${id.$1}-${id.$2} at rest should sit on a quad slot '
          '(+-${run.cell * _sharedOffset} dp from the cell centre on each '
          'axis), is at offset $d; ${_where(run)}',
    );
    slots.add('${d.dx.sign}/${d.dy.sign}');
  }
  expect(
    slots.length,
    run.move.onDestination.length,
    reason:
        'the discs at rest on the destination cell should take distinct '
        'slots, got $slots; ${_where(run)}',
  );
}

/// D1 for the mover: once drawn in a shared slot of its destination, never
/// again at the fan diameter or the fan offset.
void _expectMoverSettlesOnce(_Run run) {
  final _Id mover = run.move.mover;
  _expectRestingLayoutIsSharedQuad(run);
  final Offset restCentre = run.last.discs[mover]!.centre;
  final int first = run.samples.indexWhere(
    (s) =>
        run.destination.contains(s.discs[mover]!.centre) &&
        run.formOf(s.discs[mover]!.diameter) == _Form.shared,
  );
  expect(
    first,
    isNot(-1),
    reason:
        'the mover token-${mover.$1}-${mover.$2} was never drawn in a shared '
        'slot of its destination cell; ${_where(run)}',
  );
  for (int i = first; i < run.samples.length; i++) {
    final _Disc d = run.samples[i].discs[mover]!;
    final _Form form = run.formOf(d.diameter);
    if (form != _Form.shared || !_near(d.centre, restCentre)) {
      fail(
        'D1: token-${mover.$1}-${mover.$2} was drawn in its shared slot at '
        't=${run.samples[first].ms} ms and must stay there while truth keeps '
        'it on the cell, but at t=${run.samples[i].ms} ms it is drawn at '
        'diameter ${d.diameter.toStringAsFixed(2)} (${form.name}; shared is '
        '${(run.cell * _sharedDiameter).toStringAsFixed(2)}, fan is '
        '${(run.cell * _fanDiameter).toStringAsFixed(2)}) centred '
        '${d.centre} instead of $restCentre.\n'
        '${run.trace(mover, i)}${_where(run)}',
      );
    }
  }
}

/// D1 for the other tokens on the destination cell: the diameter changes at
/// most once, fan to shared.
void _expectOthersChangeAtMostOnce(_Run run) {
  final _Id mover = run.move.mover;
  for (final _Id id in run.move.onDestination) {
    if (id == mover) {
      continue;
    }
    _Form? previous;
    int changes = 0;
    for (int i = 0; i < run.samples.length; i++) {
      final _Form form = run.formOf(run.samples[i].discs[id]!.diameter);
      if (form == _Form.other) {
        fail(
          'D1: token-${id.$1}-${id.$2} is drawn at a diameter that is '
          'neither the fan nor a shared slot at t=${run.samples[i].ms} ms.\n'
          '${run.trace(id, i)}${_where(run)}',
        );
      }
      if (previous != null && form != previous) {
        changes++;
        if (form == _Form.fan) {
          fail(
            'D1: token-${id.$1}-${id.$2} went shared -> fan at '
            't=${run.samples[i].ms} ms; its diameter may change at most '
            'once, fan to shared.\n${run.trace(id, i)}${_where(run)}',
          );
        }
        if (changes > 1) {
          fail(
            'D1: token-${id.$1}-${id.$2} changed diameter $changes times by '
            't=${run.samples[i].ms} ms; at most one change, fan to shared.\n'
            '${run.trace(id, i)}${_where(run)}',
          );
        }
      }
      previous = form;
    }
  }
}

/// D2: on the first frame the mover's disc is on its destination cell, it is
/// in the slot it ends in, and so is every other occupant.
void _expectArrivesInItsSlot(_Run run) {
  final int at = run.arrivalIndex;
  expect(
    at,
    isNot(-1),
    reason:
        'the mover never reached its destination cell within $_windowMs ms; '
        '${_where(run)}',
  );
  for (final _Id id in run.move.onDestination) {
    final _Disc now = run.samples[at].discs[id]!;
    final _Disc rest = run.last.discs[id]!;
    if ((now.diameter - rest.diameter).abs() > _tolerance ||
        !_near(now.centre, rest.centre)) {
      fail(
        'D2: on the frame the mover first reaches its destination '
        '(t=${run.samples[at].ms} ms) token-${id.$1}-${id.$2} should already '
        'be drawn as at rest (diameter '
        '${rest.diameter.toStringAsFixed(2)} centred ${rest.centre}), but '
        'is drawn at diameter ${now.diameter.toStringAsFixed(2)} centred '
        '${now.centre}.\n${run.trace(id, at)}${_where(run)}',
      );
    }
  }
}

/// Path squares keep today's rule (C-408 decision 3): until the mover's disc
/// is on its destination cell it is not an occupant of any cell, so it is
/// drawn at the fan on every square it crosses.
void _expectPathKeepsFan(_Run run) {
  final _Id mover = run.move.mover;
  for (int i = 0; i < run.samples.length; i++) {
    final _Disc d = run.samples[i].discs[mover]!;
    if (run.destination.contains(d.centre)) {
      continue;
    }
    if (run.formOf(d.diameter) != _Form.fan) {
      fail(
        'C-408 decision 3: until it is on its destination cell the mover '
        'token-${mover.$1}-${mover.$2} only crosses cells, so it keeps the '
        'fan diameter ${(run.cell * _fanDiameter).toStringAsFixed(2)}; at '
        't=${run.samples[i].ms} ms it is drawn at '
        '${d.diameter.toStringAsFixed(2)} '
        '(${run.formOf(d.diameter).name}) centred ${d.centre}, which is not '
        'the destination cell ${run.destination}.\n'
        '${run.trace(mover, i, radius: 6)}${_where(run)}',
      );
    }
  }
}

/// A token standing on a square the walk only crosses is not touched by it:
/// same diameter, same centre, at every sample.
void _expectCrossedStandersUntouched(_Run run) {
  expect(
    run.move.onPath,
    isNotEmpty,
    reason: 'the case must cross a populated square; ${_where(run)}',
  );
  for (final _Id id in run.move.onPath) {
    final _Disc first = run.samples.first.discs[id]!;
    for (int i = 1; i < run.samples.length; i++) {
      final _Disc d = run.samples[i].discs[id]!;
      if ((d.diameter - first.diameter).abs() > _tolerance ||
          !_near(d.centre, first.centre)) {
        fail(
          'token-${id.$1}-${id.$2} stands on a square the mover only '
          'crosses (C-408 decision 3) and must not change, but at '
          't=${run.samples[i].ms} ms it is '
          '${d.diameter.toStringAsFixed(2)} at ${d.centre}, was '
          '${first.diameter.toStringAsFixed(2)} at ${first.centre}.\n'
          '${run.trace(id, i)}${_where(run)}',
        );
      }
    }
  }
}

List<_Scenario> _landingScenarios() {
  const int safe = 34;
  final Map<_Id, int> twoBeside = <_Id, int>{
    (1, 3): _progressOn(1, safe),
    (3, 0): _progressOn(3, safe),
  };
  return <_Scenario>[
    _Scenario(
      label: '(a) seat 2 viewer walks 3 onto a cell holding seats 1 and 3',
      seats: const <int>[0, 1, 2, 3],
      mySeat: 2,
      mover: (2, 1),
      from: _progressOn(2, safe) - 3,
      to: _progressOn(2, safe),
      others: twoBeside,
    ),
    _Scenario(
      label:
          '(b) viewer seat 0, seat 2 walks 3 onto a cell holding seats 1 and 3',
      seats: const <int>[0, 1, 2, 3],
      mySeat: 0,
      mover: (2, 2),
      from: _progressOn(2, safe) - 3,
      to: _progressOn(2, safe),
      others: twoBeside,
    ),
    _Scenario(
      label: '(c) two seats, mover lands on a star holding one opponent',
      seats: const <int>[0, 2],
      mySeat: 0,
      mover: (0, 0),
      from: _progressOn(0, 8) - 3,
      to: _progressOn(0, 8),
      others: <_Id, int>{(2, 1): _progressOn(2, 8)},
    ),
    _Scenario(
      label: '(c2) two seats, opponent mover lands on a star holding my token',
      seats: const <int>[0, 2],
      mySeat: 2,
      mover: (0, 3),
      from: _progressOn(0, 8) - 3,
      to: _progressOn(0, 8),
      others: <_Id, int>{(2, 0): _progressOn(2, 8)},
    ),
    _Scenario(
      label: '(a-reduced) as (a) with disableAnimations',
      seats: const <int>[0, 1, 2, 3],
      mySeat: 2,
      mover: (2, 1),
      from: _progressOn(2, safe) - 3,
      to: _progressOn(2, safe),
      others: twoBeside,
      reduced: true,
    ),
  ];
}

List<_Scenario> _crossingScenarios() {
  const int crossed = 34;
  return <_Scenario>[
    _Scenario(
      label:
          '(d) seat 2 walks 4 across a cell holding seats 1 and 3 and lands '
          'on an empty cell',
      seats: const <int>[0, 1, 2, 3],
      mySeat: 2,
      mover: (2, 0),
      from: _progressOn(2, crossed) - 2,
      to: _progressOn(2, crossed) + 2,
      others: <_Id, int>{
        (1, 3): _progressOn(1, crossed),
        (3, 0): _progressOn(3, crossed),
      },
    ),
    _Scenario(
      label:
          '(d2) seat 1 walks 4 across a cell holding one token of seat 0 '
          'and lands on an empty cell, seen from seat 2',
      seats: const <int>[0, 1, 2, 3],
      mySeat: 2,
      mover: (1, 2),
      from: _progressOn(1, crossed) - 2,
      to: _progressOn(1, crossed) + 2,
      others: <_Id, int>{(0, 1): _progressOn(0, crossed)},
    ),
  ];
}

// --- case (e): the recorded game, through the real screens -----------------

/// The seat, game and `moved` of order 602's `four_seats_1` capture.
const String _recordedGame = 'four_seats_1';
const int _recordedViewer = 2;
const int _recordedMovedSeq = 639;

Map<String, Object?> _decodeJson(String text) =>
    jsonDecode(text) as Map<String, Object?>;

/// One recorded `moved`, located in the view by its own seq.
class _RecordedMoment {
  _RecordedMoment(this.index, this.move);
  final int index;
  final _Move move;
}

/// Folds the recorded `moved` frames of [view] up to the one whose seq is
/// [_recordedMovedSeq] into a [_Move]: the mover, its walk, and every other
/// token's progress at that moment.
_RecordedMoment _locateRecordedMoment(
  List<Map<String, Object?>> view,
  List<int> seats,
) {
  final Map<_Id, int> position = <_Id, int>{
    for (final int s in seats)
      for (int t = 0; t < 4; t++) (s, t): -1,
  };
  for (int i = 0; i < view.length; i++) {
    final Map<String, Object?> frame = view[i];
    if (frame['t'] != 'moved') {
      continue;
    }
    final Map<String, Object?> d = frame['d']! as Map<String, Object?>;
    final _Id id = (d['seat']! as int, d['token']! as int);
    if (d['seq'] == _recordedMovedSeq) {
      final Map<_Id, int> others = <_Id, int>{...position}..remove(id);
      return _RecordedMoment(
        i,
        _Move(
          label:
              'four_seats_1, view of seat $_recordedViewer, the moved of '
              'seq $_recordedMovedSeq (view index $i)',
          mySeat: _recordedViewer,
          mover: id,
          from: d['from']! as int,
          to: d['to']! as int,
          others: others,
        ),
      );
    }
    position[id] = d['to']! as int;
    for (final Object? c in d['captured']! as List<Object?>) {
      final Map<String, Object?> struck = c! as Map<String, Object?>;
      position[(struck['seat']! as int, struck['token']! as int)] = -1;
    }
  }
  throw TestFailure(
    'the recorded view of seat $_recordedViewer holds no moved with seq '
    '$_recordedMovedSeq; the fixture was re-recorded, update '
    '_recordedMovedSeq from order 602',
  );
}

/// Hands out a controller on a FakeTransport, in call order.
class _Factory {
  final List<RoomController> controllers = <RoomController>[];
  final List<FakeTransport> transports = <FakeTransport>[];

  RoomController call() {
    final FakeTransport transport = FakeTransport();
    transports.add(transport);
    final RoomController created = RoomController(
      serverUrl: Uri.parse('wss://c603.invalid/ws'),
      connect: (Uri url) async => transport,
    );
    controllers.add(created);
    return created;
  }
}

List<BoardThrownDie> _thrownDice(WidgetTester tester) => tester
    .widgetList<BoardThrownDie>(find.byType(BoardThrownDie))
    .toList(growable: false);

/// Pumps in 50 ms steps until no thrown die is on the board for two pumps in
/// a row (the next throw of the queue starts in the pump after one ends).
Future<void> _drainThrownDice(WidgetTester tester, String where) async {
  final Stopwatch wall = Stopwatch()..start();
  int absent = 0;
  while (absent < 2) {
    absent = _thrownDice(tester).isEmpty ? absent + 1 : 0;
    if (wall.elapsedMilliseconds > 300000) {
      fail('thrown dice still up after 300 s of wall time; $where');
    }
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder,
  String what,
) async {
  for (int i = 0; i < 200; i++) {
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(_period);
  }
  fail('timed out after 200 pumps waiting for $what');
}

/// Replays the recorded game to the instant before the moved of seq 639 is
/// pushed, then pushes that `moved` together with the turn behind it and
/// returns the sampled discs.
Future<_Run> _playRecorded(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final Map<String, Object?> fixture = _decodeJson(realGamesJson);
  final Map<String, Object?> game = <Object?>[
    ...fixture['games']! as List<Object?>,
  ].cast<Map<String, Object?>>().firstWhere((g) => g['name'] == _recordedGame);
  final List<Map<String, Object?>> view = <Map<String, Object?>>[
    for (final Object? f
        in (game['views']! as Map<String, Object?>)['$_recordedViewer']!
            as List<Object?>)
      f! as Map<String, Object?>,
  ];
  final List<int> seats = <int>[
    for (final Object? s in game['seats']! as List<Object?>) s! as int,
  ];
  final _RecordedMoment moment = _locateRecordedMoment(view, seats);
  final String where =
      'recorded game $_recordedGame, viewer seat $_recordedViewer, '
      '${moment.move.describe()}';

  final _Factory factory = _Factory();
  addTearDown(() {
    for (final RoomController c in factory.controllers) {
      c.dispose();
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(controllerFactory: factory.call, onToggleLocale: () {}),
    ),
  );
  await tester.pumpAndSettle();

  // The device's own entry: the recorded name and the recorded room code.
  final Map<String, Object?> roomData = view[1]['d']! as Map<String, Object?>;
  expect(
    roomData['host_seat'],
    isNot(_recordedViewer),
    reason: 'the recorded viewer must be a guest; $where',
  );
  await tester.enterText(
    find.byKey(const Key('home-name-field')),
    (game['names']! as Map<String, Object?>)['$_recordedViewer']! as String,
  );
  await tester.enterText(
    find.byKey(const Key('room-code-field')),
    roomData['code']! as String,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('join-room-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));

  final FakeTransport transport = factory.transports.single;
  final String joinId =
      <Map<String, Object?>>[
            for (final String raw in transport.sentRaw) _decodeJson(raw),
          ].singleWhere((f) => f['t'] == 'join_room')['id']!
          as String;

  // The one rewrite a replayed frame gets: the recorded join's `re` is the
  // id of the join this device sent; every other `re` answers a request this
  // device never sent and is dropped.
  final Map<String, String> deviceIds = <String, String>{
    view[1]['re']! as String: joinId,
  };
  String wire(Map<String, Object?> frame) {
    final Object? re = frame['re'];
    if (re == null) {
      return jsonEncode(frame);
    }
    final String? id = deviceIds[re];
    return jsonEncode(
      id != null
          ? <String, Object?>{...frame, 're': id}
          : (<String, Object?>{...frame}..remove('re')),
    );
  }

  int next = 0;
  void push() => transport.pushText(wire(view[next++]));

  push(); // seat_assigned
  push(); // room, answering the join
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(tester, find.byType(LobbyScreen), 'the lobby; $where');
  while (view[next]['t'] != 'game_started') {
    push();
  }
  push(); // game_started
  await tester.pump();
  await tester.pump();
  await _pumpUntilFound(tester, find.byType(GameScreen), 'the game; $where');
  final RoomController controller = factory.controllers.single;

  // The burst stops short of the roll that leads to the moved, the throws
  // queued land, then that roll goes in and lands.
  int rollAt = moment.index - 1;
  while (rollAt > next && view[rollAt]['t'] != 'rolled') {
    rollAt--;
  }
  while (next < rollAt) {
    push();
  }
  await tester.pump();
  await tester.pump();
  await _drainThrownDice(tester, 'before the roll; $where');
  while (next < moment.index) {
    push();
  }
  await tester.pump();
  await tester.pump();
  await _drainThrownDice(tester, 'the roll; $where');

  // The moved goes in with the turn behind it, as one burst.
  int turnAt = moment.index + 1;
  while (view[turnAt]['t'] != 'turn') {
    turnAt++;
  }
  while (next <= turnAt) {
    push();
  }
  expect(
    controller.hasDesynced,
    isFalse,
    reason: 'seq gap in the replayed frames; $where',
  );

  // Everything below is read off the board the game screen built.
  final Finder boardFinder = find.byKey(const Key('game-screen-board'));
  final LudoBoard before = tester.widget<LudoBoard>(boardFinder);
  expect(
    before.tokens[moment.move.mover.$1]![moment.move.mover.$2],
    moment.move.from,
    reason:
        'before the moved is absorbed the board must still hold the mover '
        'on its recorded from; $where',
  );
  await tester.pump();
  final LudoBoard after = tester.widget<LudoBoard>(boardFinder);
  expect(
    after.tokens[moment.move.mover.$1]![moment.move.mover.$2],
    moment.move.to,
    reason: 'the board must hold the mover on its recorded to; $where',
  );
  for (final MapEntry<_Id, int> e in moment.move.others.entries) {
    expect(
      after.tokens[e.key.$1]![e.key.$2],
      e.value,
      reason: 'the board must hold token ${e.key} on ${e.value}; $where',
    );
  }

  final List<_Id> tracked = _trackedFor(moment.move);
  final List<_Sample> samples = await _sample(tester, tracked, () => -1);
  final double cell = _boardSquare(tester).width / 15;
  // Bring the screen down so no timer outlives the test.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  return _Run(
    moment.move,
    cell,
    samples,
    _destinationRect(moment.move, cell),
    tracked,
  );
}

void main() {
  for (final _Scenario scenario in _landingScenarios()) {
    group('C-603 ${scenario.label}', () {
      testWidgets('D1 the mover, once in its shared slot, stays in it', (
        WidgetTester tester,
      ) async {
        _expectMoverSettlesOnce(await _play(tester, scenario));
      });

      testWidgets('D1 the other occupants change diameter at most once', (
        WidgetTester tester,
      ) async {
        _expectOthersChangeAtMostOnce(await _play(tester, scenario));
      });

      testWidgets('D2 the mover arrives in its final slot, others in theirs', (
        WidgetTester tester,
      ) async {
        _expectArrivesInItsSlot(await _play(tester, scenario));
      });

      testWidgets('D3 the squares it only crosses keep the fan', (
        WidgetTester tester,
      ) async {
        _expectPathKeepsFan(await _play(tester, scenario));
      });
    });
  }

  for (final _Scenario scenario in _crossingScenarios()) {
    group('C-603 ${scenario.label}', () {
      testWidgets('the mover keeps the fan on every square it crosses and '
          'on the empty one it lands on', (WidgetTester tester) async {
        final _Run run = await _play(tester, scenario);
        _expectPathKeepsFan(run);
        for (int i = 0; i < run.samples.length; i++) {
          final _Disc d = run.samples[i].discs[scenario.mover]!;
          expect(
            run.formOf(d.diameter),
            _Form.fan,
            reason:
                'the mover lands on an empty cell and stays at the fan; at '
                't=${run.samples[i].ms} ms it is '
                '${d.diameter.toStringAsFixed(2)}.\n'
                '${run.trace(scenario.mover, i)}${_where(run)}',
          );
        }
      });

      testWidgets('a token standing on a crossed square is not touched', (
        WidgetTester tester,
      ) async {
        _expectCrossedStandersUntouched(await _play(tester, scenario));
      });
    });
  }

  group('C-603 (e) the recorded four_seats_1 moment, seat 2 view', () {
    testWidgets('D1, D2 and the crossed squares on the moved of seq 639', (
      WidgetTester tester,
    ) async {
      final _Run run = await _playRecorded(tester);
      // One replay costs about 90 s of wall time, so every check runs on
      // it and the failures are reported together, none dropped.
      final Map<String, void Function(_Run)> checks =
          <String, void Function(_Run)>{
            'D1 the mover, once in its shared slot, stays in it':
                _expectMoverSettlesOnce,
            'D1 the other occupants change diameter at most once':
                _expectOthersChangeAtMostOnce,
            'D2 the mover arrives in its final slot, others in theirs':
                _expectArrivesInItsSlot,
            'D3 the squares it only crosses keep the fan': _expectPathKeepsFan,
            'a token standing on a crossed square is not touched':
                _expectCrossedStandersUntouched,
          };
      final List<String> failures = <String>[];
      checks.forEach((String name, void Function(_Run) check) {
        try {
          check(run);
        } on TestFailure catch (e) {
          failures.add('[$name]\n${e.message}');
        }
      });
      if (failures.isNotEmpty) {
        fail(
          '${failures.length} of ${checks.length} checks failed on the '
          'recorded moment:\n${failures.join('\n\n')}',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 8)));
  });
}
