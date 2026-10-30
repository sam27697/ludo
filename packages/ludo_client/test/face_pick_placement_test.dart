// Acceptance proof for C-508: the face picker's bubble does not cover my
// other movable tokens. Written from the contract (work/ludo/orders/
// C-508, amending C-462 D5), not from any implementation. GameScreen is
// driven through a real RoomController on FakeTransport; every room state
// arrives as a decoded wire frame, and the picker is opened by a real tap
// on the token.
//
// How the expected rect is computed (never read back from a run):
//   - the board square is measured off the mounted game, cellSize is its
//     width over 15, and the board is pinned to a 360 dp wide phone;
//   - the picked token's drawn centre is the centre of its
//     `board-token-hit-<seat>-<token>` widget (the same layout the disc is
//     painted at); every disc's size and fan offset comes from the layout
//     documented on `_tokenLayout` in lib/src/board.dart (single seat:
//     diameter cellSize * 0.7, fan offset cellSize * 0.12, x by even or odd
//     token index, y by index below 2). Each of my own discs is cross-checked
//     against its hit widget's centre, so a wrong derivation fails loudly
//     as a broken fixture instead of skewing a rect. Opponent discs have no
//     key and are derived from the documented layout only;
//   - the six candidates, their scores and the choice are the formulas of
//     C-508 D1 to D3, restated here in `_plan`.
//
// Positions are built from real progresses (cellFor + toView) so every state
// is one the server could send: a token is legal for a queued face when it
// is in the yard and the face is 6, or on the track or home column and
// progress + face <= 57 (RULES.md 17 to 19). Opponent tokens never share a
// cell with another seat, so the shared-cell slots never come into play.
//
// The view is the same for every seat (my yard bottom-left, my start square
// at view cell (6, 14)), so the "other seat orientation" is a four-player
// room seen from seat 2: different opponent yards in the corners, different
// board-space progresses for the same view cells.
//
// Each case says whether it must fail on origin/main 71599be. Reproduce any
// failure by its scene id, seat and locale in the test name: the scenes are
// fixed, there is no seed.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/board_geometry.dart';
import 'package:ludo_client/src/theme.dart' show kSpace2;
import 'package:ludo_client/src/token_face_picker.dart'
    show
        facePickerBubbleWidth,
        kFacePickerBubbleHeight,
        kFacePickerOpen,
        kFacePickerTipGap;

import 'support/roll_tray_harness.dart';

const double _eps = 1e-3;

/// The horizontal clamp keeps a bubble 1 dp inside the board edge, so a
/// clamped `left` may be 1 dp off the unclamped formula. `top` has no such
/// slack: C-508 D1 makes `top >= 0` valid and places above and below by the
/// exact gap, so it is compared within [_eps].
const double _leftTolerance = 1.01;

/// The pointer's half width (C-508 D1 `m` is this plus `kSpace2`).
const double _pointerHalf = 8;

const Size _phonePhysical = Size(1080, 2160);
const double _phoneRatio = 3.0;

/// Where a token stands: a view cell, or the yard, or home.
class _Pos {
  const _Pos(this.col, this.row) : fixed = null;
  const _Pos.fixed(int progress) : col = -1, row = -1, fixed = progress;

  final int col;
  final int row;
  final int? fixed;
}

const _Pos _yard = _Pos.fixed(-1);
const _Pos _home = _Pos.fixed(57);

/// The progress of [seat] whose cell, seen from [mySeat], is ([col], [row]).
int _progressAtView(int seat, int mySeat, int col, int row) {
  final int quarters = viewQuarters(mySeat);
  for (int progress = 0; progress <= 56; progress++) {
    final BoardCell view = toView(
      cellFor(seat: seat, progress: progress),
      quarters,
    );
    if (view.col == col && view.row == row) {
      return progress;
    }
  }
  throw StateError('seat $seat has no progress on view cell ($col, $row)');
}

class _Scene {
  _Scene._({
    required this.id,
    required this.mySeat,
    required this.queue,
    required this.picked,
    required this.tokens,
  });

  /// [mine] and [opp] are four positions each; [opp] belongs to the seat
  /// after mine (1 for seat 0, 3 for seat 2). Every other seat stays in the
  /// yard. Seat 0 is a two-player room, seat 2 a four-player one.
  factory _Scene.build(
    String id,
    int mySeat, {
    required List<int> queue,
    required int picked,
    required List<_Pos> mine,
    List<_Pos>? opp,
  }) {
    final int oppSeat = (mySeat + 1) % 4;
    final Map<int, List<int>> tokens = <int, List<int>>{};
    final List<int> seats = mySeat == 0 ? <int>[0, 1] : <int>[0, 1, 2, 3];
    for (final int seat in seats) {
      final List<_Pos>? spots = seat == mySeat
          ? mine
          : (seat == oppSeat ? opp : null);
      tokens[seat] = <int>[
        for (int t = 0; t < 4; t++)
          if (spots == null)
            -1
          else
            spots[t].fixed ??
                _progressAtView(seat, mySeat, spots[t].col, spots[t].row),
      ];
    }
    return _Scene._(
      id: id,
      mySeat: mySeat,
      queue: queue,
      picked: picked,
      tokens: tokens,
    );
  }

  final String id;
  final int mySeat;
  final List<int> queue;
  final int picked;
  final Map<int, List<int>> tokens;

  int get players => tokens.length;

  List<int> get mine => tokens[mySeat]!;

  /// RULES.md 17 to 19, the only legality this fixture needs.
  bool _legal(int face, int progress) {
    if (progress < 0) {
      return face == 6;
    }
    return progress < 57 && progress + face <= 57;
  }

  /// The tokens of mine each queued face can move, in queue order, faces
  /// with no legal token left out (a dead face is not alive).
  List<Map<String, Object?>> get legalByFace => <Map<String, Object?>>[
    for (final int face in queue)
      if (<int>[
        for (int t = 0; t < 4; t++)
          if (_legal(face, mine[t])) t,
      ].isNotEmpty)
        faceLegal(face, <int>[
          for (int t = 0; t < 4; t++)
            if (_legal(face, mine[t])) t,
        ]),
  ];

  /// The tokens any alive face can move: what the board rings.
  Set<int> get ringed => <int>{
    for (final Map<String, Object?> entry in legalByFace)
      ...(entry['tokens']! as List<Object?>).cast<int>(),
  };

  List<int> faces(int token) => <int>[
    for (final Map<String, Object?> entry in legalByFace)
      if ((entry['tokens']! as List<Object?>).contains(token))
        entry['face']! as int,
  ];

  Map<String, Object?> get turn {
    final List<Map<String, Object?>> byFace = legalByFace;
    final List<int> legalForValue = <int>[
      for (final Map<String, Object?> entry in byFace)
        if (entry['face'] == queue.first)
          ...(entry['tokens']! as List<Object?>).cast<int>(),
    ];
    return turnJson(
      seat: mySeat,
      phase: 'await_move',
      k: 2,
      value: queue.first,
      legal: legalForValue,
      queue: queue,
      legalByFace: byFace,
    );
  }

  List<Map<String, Object?>> get seatsJson => <Map<String, Object?>>[
    for (final MapEntry<int, List<int>> entry in tokens.entries)
      seatJson(
        entry.key,
        name: entry.key == mySeat ? 'Sam' : 'P${entry.key}',
        tokens: entry.value,
      ),
  ];

  /// One line that rebuilds the scene.
  String get text =>
      "scene '$id' mySeat $mySeat players $players queue $queue "
      'picked token $picked faces ${faces(picked)} ringed '
      '${(ringed.toList()..sort())} tokens $tokens';
}

/// One drawn disc of the contract's layout, in board-local pixels.
class _Disc {
  const _Disc(this.seat, this.token, this.center, this.size);

  final int seat;
  final int token;
  final Offset center;
  final double size;

  Rect get rect => Rect.fromCenter(center: center, width: size, height: size);

  String get label => 'seat $seat token $token';
}

/// Every disc the board paints for [scene] at [cell] pixels per cell: the
/// documented fan for a single seat on a cell (yard, home column, track).
/// Finished tokens are not discs on a cell (C-508 D2) and are left out.
List<_Disc> _discs(_Scene scene, double cell) {
  final int quarters = viewQuarters(scene.mySeat);
  final Map<BoardCell, Set<int>> seatsOn = <BoardCell, Set<int>>{};
  final List<_Disc> discs = <_Disc>[];
  for (final MapEntry<int, List<int>> entry in scene.tokens.entries) {
    for (int token = 0; token < 4; token++) {
      final int progress = entry.value[token];
      if (progress == 57) {
        continue;
      }
      final BoardCell view = toView(
        cellFor(seat: entry.key, progress: progress, tokenIndex: token),
        quarters,
      );
      seatsOn.putIfAbsent(view, () => <int>{}).add(entry.key);
      final double fan = cell * 0.12;
      discs.add(
        _Disc(
          entry.key,
          token,
          Offset(
            view.col * cell + cell / 2 + (token.isEven ? -fan : fan),
            view.row * cell + cell / 2 + (token < 2 ? -fan : fan),
          ),
          cell * 0.7,
        ),
      );
    }
  }
  for (final MapEntry<BoardCell, Set<int>> entry in seatsOn.entries) {
    if (entry.value.length > 1) {
      throw StateError(
        '${scene.text}: seats ${entry.value} share view cell ${entry.key}; '
        'only the single-seat fan is computed here',
      );
    }
  }
  return discs;
}

/// C-508 D1: one candidate rect and its D3 score.
class _Candidate {
  _Candidate({
    required this.order,
    required this.name,
    required this.below,
    required this.rawLeft,
    required this.left,
    required this.top,
    required this.width,
  });

  /// 1 to 6, the position in the fixed D1 order.
  final int order;
  final String name;
  final bool below;
  final double rawLeft;
  final double left;
  final double top;
  final double width;
  final List<_Disc> coveredMine = <_Disc>[];
  final List<_Disc> coveredOther = <_Disc>[];

  /// C-508 D3 `a`: covered ringed tokens of mine.
  int get a => coveredMine.length;

  /// C-508 D3 `b`: covered tokens of any other kind (mine not ringed, every
  /// opponent's).
  int get b => coveredOther.length;

  Rect get rect => Rect.fromLTWH(left, top, width, kFacePickerBubbleHeight);

  bool get clamped => (left - rawLeft).abs() > 1e-9;

  @override
  String toString() =>
      '$order $name rect ${_fmt(rect)} a=$a b=$b covers mine '
      '[${coveredMine.map((_Disc d) => d.label).join(', ')}] other '
      '[${coveredOther.map((_Disc d) => d.label).join(', ')}]';
}

String _fmt(Rect r) =>
    'L${r.left.toStringAsFixed(1)} T${r.top.toStringAsFixed(1)} '
    'R${r.right.toStringAsFixed(1)} B${r.bottom.toStringAsFixed(1)}';

class _Plan {
  _Plan(this.scene, this.cell, this.picked, this.candidates, this.chosen);

  final _Scene scene;
  final double cell;
  final _Disc picked;
  final List<_Candidate> candidates;
  final _Candidate chosen;

  double get side => cell * 15;

  String get table => candidates.map((_Candidate c) => '  $c').join('\n');

  _Candidate byOrder(int order) =>
      candidates.firstWhere((_Candidate c) => c.order == order);

  bool has(int order) => candidates.any((_Candidate c) => c.order == order);
}

double _clampOrigin(double origin, double extent, double board) {
  final double room = board - extent;
  if (room <= 0) {
    return 0;
  }
  final double inset = math.min(1.0, room / 2);
  return origin.clamp(inset, board - extent - inset).toDouble();
}

bool _overlaps(Rect a, Rect b) {
  final double w = math.min(a.right, b.right) - math.max(a.left, b.left);
  final double h = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  return w > 1e-9 && h > 1e-9;
}

/// C-508 D1 to D3 for the scene's picked token, on a board of [cell] pixels
/// per cell. [centre] is the picked token's measured drawn centre.
///
/// The two flags exist only to prove a scene discriminates: [swapSlides]
/// exchanges "toward" and "away" in the D1 order, and [countMates] drops the
/// D2 exclusion of tokens sharing the picked token's cell. The contract's
/// own answer uses neither.
_Plan _plan(
  _Scene scene,
  double cell,
  Offset centre, {
  bool swapSlides = false,
  bool countMates = false,
}) {
  final List<_Disc> discs = _discs(scene, cell);
  final _Disc picked = discs.firstWhere(
    (_Disc d) => d.seat == scene.mySeat && d.token == scene.picked,
  );
  final double r = picked.size / 2;
  final double side = cell * 15;
  final double w = facePickerBubbleWidth(scene.faces(scene.picked).length);
  final double h = kFacePickerBubbleHeight;
  final double m = kSpace2 + _pointerHalf;
  final bool towardRight = (centre.dx < side / 2) != swapSlides;

  final double aboveTop = centre.dy - r - kFacePickerTipGap - h;
  final double belowTop = centre.dy + r + kFacePickerTipGap;
  final List<(String, bool, double)> raw = <(String, bool, double)>[
    ('above centre', false, centre.dx - w / 2),
    (
      'above slid toward centre',
      false,
      towardRight ? centre.dx - m : centre.dx - (w - m),
    ),
    (
      'above slid away',
      false,
      towardRight ? centre.dx - (w - m) : centre.dx - m,
    ),
    ('below centre', true, centre.dx - w / 2),
    (
      'below slid toward centre',
      true,
      towardRight ? centre.dx - m : centre.dx - (w - m),
    ),
    (
      'below slid away',
      true,
      towardRight ? centre.dx - (w - m) : centre.dx - m,
    ),
  ];

  final List<_Candidate> candidates = <_Candidate>[];
  for (int i = 0; i < raw.length; i++) {
    final (String name, bool below, double rawLeft) = raw[i];
    final double top = below ? belowTop : aboveTop;
    final bool valid = below ? top + h <= side : top >= 0;
    if (!valid) {
      continue;
    }
    final double left = _clampOrigin(rawLeft, w, side);
    final bool duplicate = candidates.any(
      (_Candidate c) => c.below == below && (c.left - left).abs() < 1e-9,
    );
    if (duplicate) {
      continue;
    }
    candidates.add(
      _Candidate(
        order: i + 1,
        name: name,
        below: below,
        rawLeft: rawLeft,
        left: left,
        top: top,
        width: w,
      ),
    );
  }
  if (candidates.isEmpty) {
    throw StateError('${scene.text}: no valid candidate on a $side board');
  }

  for (final _Candidate c in candidates) {
    for (final _Disc d in discs) {
      if (identical(d, picked)) {
        continue;
      }
      if (!countMates && (d.center - centre).distance < cell / 2) {
        continue;
      }
      if (!_overlaps(c.rect, d.rect)) {
        continue;
      }
      if (d.seat == scene.mySeat && scene.ringed.contains(d.token)) {
        c.coveredMine.add(d);
      } else {
        c.coveredOther.add(d);
      }
    }
  }

  final List<_Candidate> ranked = List<_Candidate>.of(candidates)
    ..sort((_Candidate x, _Candidate y) {
      if (x.a != y.a) {
        return x.a.compareTo(y.a);
      }
      if (x.b != y.b) {
        return x.b.compareTo(y.b);
      }
      return x.order.compareTo(y.order);
    });
  return _Plan(scene, cell, picked, candidates, ranked.first);
}

/// A mounted scene with the picker open on the picked token.
class _Run {
  _Run(this.tester, this.drive, this.scene, this.locale);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final _Scene scene;
  final Locale locale;

  late final Rect board = boardSquare(tester);
  late final double cell = board.width / 15;
  late final Offset pickedCentre = tester.getCenter(
    find.byKey(tokenHitKey(scene.mySeat, scene.picked)),
  );
  late final _Plan plan = _plan(scene, cell, pickedCentre - board.topLeft);

  /// The same scene planned with the toward / away slides exchanged.
  late final _Plan swappedPlan = _plan(
    scene,
    cell,
    pickedCentre - board.topLeft,
    swapSlides: true,
  );

  /// The same scene planned without the D2 exclusion of the picked token's
  /// cell mates.
  late final _Plan matesCountedPlan = _plan(
    scene,
    cell,
    pickedCentre - board.topLeft,
    countMates: true,
  );

  String get tag => '${locale.languageCode} seat ${scene.mySeat}';

  Rect get picker => tester.getRect(find.byKey(facePickerKey));

  Rect get pickerLocal => picker.shift(-board.topLeft);

  /// The pointer has no key. It is the only 16 x 8 paint inside the bubble
  /// (the option art is 36 x 36).
  Rect get pointer {
    final Finder paints = find.descendant(
      of: find.byKey(facePickerKey),
      matching: find.byType(CustomPaint),
    );
    final List<Rect> found = <Rect>[
      for (int i = 0; i < paints.evaluate().length; i++)
        if ((tester.getSize(paints.at(i)).width - 2 * _pointerHalf).abs() <
                _eps &&
            (tester.getSize(paints.at(i)).height - 8).abs() < _eps)
          tester.getRect(paints.at(i)),
    ];
    expect(found, hasLength(1), reason: why('one 16 x 8 pointer'));
    return found.single;
  }

  bool get pointsUp => pointer.center.dy < picker.center.dy;

  String why(String expected) =>
      '$tag: expected $expected. ${scene.text}. board ${_fmt(board)} '
      'cell ${cell.toStringAsFixed(2)} picked centre '
      '${(pickedCentre - board.topLeft)} picker open '
      '${tester.any(find.byKey(facePickerKey))} picker rect '
      '${tester.any(find.byKey(facePickerKey)) ? _fmt(pickerLocal) : "none"}'
      '. Candidates by C-508 D1 to D3:\n${plan.table}\nthe contract picks '
      '${plan.chosen.order} ${plan.chosen.name}. Reproduce with this scene '
      'id, seat and locale (no seed).';

  Future<void> tapPicked() async {
    await tester.tapAt(pickedCentre);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  }

  List<Map<String, Object?>> get moves => movesSince(drive.transport, 0);

  void expectFixture() {
    final List<int> ringed = <int>[
      for (int t = 0; t < 4; t++)
        if (tester.any(find.byKey(legalRingKey(scene.mySeat, t)))) t,
    ];
    expect(
      ringed,
      (scene.ringed.toList()..sort()),
      reason: 'fixture is broken: ${why('the rings on the scene tokens')}',
    );
    // The computed disc centres of my own tokens against the painted board.
    for (final _Disc d in _discs(scene, cell)) {
      if (d.seat != scene.mySeat) {
        continue;
      }
      final Offset measured =
          tester.getCenter(find.byKey(tokenHitKey(scene.mySeat, d.token))) -
          board.topLeft;
      expect(
        (measured - d.center).distance,
        lessThan(0.6),
        reason:
            'fixture is broken: computed centre ${d.center} of ${d.label} is '
            'not the painted hit centre $measured. ${scene.text}',
      );
    }
  }

  /// Fixture checks that need no picker: the scene is the case it names.
  void expectChosen(int order, String why0) {
    expect(
      plan.chosen.order,
      order,
      reason: 'fixture is broken: $why0. ${why('contract choice $order')}',
    );
  }

  /// The picker is where the contract says: the chosen candidate's rect.
  void expectChosenRect(String what) {
    final Rect want = plan.chosen.rect;
    final Rect got = pickerLocal;
    final bool same =
        (got.left - want.left).abs() <= _leftTolerance &&
        (got.top - want.top).abs() <= _eps &&
        (got.width - want.width).abs() <= _eps &&
        (got.height - want.height).abs() <= _eps;
    expect(
      same,
      isTrue,
      reason: why(
        '$what: bubble at ${_fmt(want)} (candidate ${plan.chosen.order} '
        '${plan.chosen.name}), got ${_fmt(got)}',
      ),
    );
  }

  /// No disc named by [discs] is under the bubble.
  void expectUncovered(Iterable<_Disc> discs, String what) {
    for (final _Disc d in discs) {
      expect(
        _overlaps(pickerLocal, d.rect),
        isFalse,
        reason: why(
          '$what: ${d.label} disc ${_fmt(d.rect)} not covered by the '
          'bubble ${_fmt(pickerLocal)}',
        ),
      );
    }
  }

  /// C-508 case 8: inside the board, the pointer aims at the token (or at
  /// the end of its range nearest the token), and every option keeps a
  /// 48 x 48 hit rect.
  void expectSane() {
    final Rect p = picker;
    expect(
      p.left >= board.left - _eps &&
          p.right <= board.right + _eps &&
          p.top >= board.top - _eps &&
          p.bottom <= board.bottom + _eps,
      isTrue,
      reason: why('the bubble ${_fmt(pickerLocal)} inside the board square'),
    );
    final double tip = pointer.center.dx;
    // C-462 D5 / C-508 D4: the pointer is centred on the token while the
    // bubble's pointer range [m, w - m] allows it, and sits at the nearest
    // end of that range otherwise (a bubble the board clamp moved far from
    // the token, at the board edge). Where no clamp applies this is exactly
    // "within 1 dp of the token's drawn centre x".
    final double m = kSpace2 + _pointerHalf;
    final double offset = (pickedCentre.dx - p.left)
        .clamp(m, p.width - m)
        .toDouble();
    final double wantTip = p.left + offset;
    expect(
      (tip - wantTip).abs(),
      lessThanOrEqualTo(1.0),
      reason: why(
        'pointer tip x within 1 dp of ${wantTip.toStringAsFixed(1)} (token '
        'centre x ${pickedCentre.dx.toStringAsFixed(1)}, pointer range '
        '${(p.left + m).toStringAsFixed(1)}..'
        '${(p.right - m).toStringAsFixed(1)}), tip at '
        '${tip.toStringAsFixed(1)}',
      ),
    );
    expect(
      tip >= p.left && tip <= p.right,
      isTrue,
      reason: why(
        'the pointer tip x ${tip.toStringAsFixed(1)} inside the '
        'bubble ${p.left.toStringAsFixed(1)}..${p.right.toStringAsFixed(1)}',
      ),
    );
    for (final int face in scene.faces(scene.picked)) {
      final Rect hit = tester.getRect(find.byKey(facePickerOptionKey(face)));
      expect(
        hit.width >= 48 - _eps && hit.height >= 48 - _eps,
        isTrue,
        reason: why(
          'option $face hit rect at least 48 x 48, got '
          '${hit.width} x ${hit.height}',
        ),
      );
    }
  }
}

Future<_Run> _open(
  WidgetTester tester,
  _Scene scene,
  Locale locale, {
  bool animate = false,
}) async {
  tester.view.physicalSize = _phonePhysical;
  tester.view.devicePixelRatio = _phoneRatio;
  addTearDown(tester.view.reset);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: scene.turn,
    seats: scene.seatsJson,
    mySeat: scene.mySeat,
    players: scene.players,
  );
  await mountGame(tester, drive, locale: locale, disableAnimations: !animate);
  final _Run run = _Run(tester, drive, scene, locale);
  run.expectFixture();
  return run;
}

/// The viewer and locale matrix every case runs through: seat 0 in a
/// two-player room, and seat 2 in a four-player room.
const List<(Locale, int)> _matrix = <(Locale, int)>[
  (Locale('en'), 0),
  (Locale('ar'), 0),
  (Locale('en'), 2),
  (Locale('ar'), 2),
];

typedef _SceneBuilder = _Scene Function(int mySeat);

/// Runs [body] on a scene opened with the picker showing, for every entry of
/// [_matrix], inside one `testWidgets` each. [animate] mounts without
/// `disableAnimations`, so the open motion runs; [open] false leaves the
/// first tap to the body.
void _cases(
  String name,
  _SceneBuilder build,
  Future<void> Function(_Run run) body, {
  List<(Locale, int)> matrix = _matrix,
  bool open = true,
  bool animate = false,
}) {
  for (final (Locale locale, int mySeat) in matrix) {
    testWidgets('$name [${locale.languageCode} seat $mySeat]', (tester) async {
      final _Scene scene = build(mySeat);
      final _Run run = await _open(tester, scene, locale, animate: animate);
      try {
        if (open) {
          await run.tapPicked();
          expect(
            tester.any(find.byKey(facePickerKey)),
            isTrue,
            reason: run.why('board-face-picker open after the token tap'),
          );
        }
        await body(run);
      } finally {
        await releaseGame(tester, run.drive);
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Scenes. Cells are view cells (col, row); queue and positions are wire
// legal. Bubble for two faces: 108 dp wide, 64 dp tall, about five by three
// cells on a 360 dp phone.
// ---------------------------------------------------------------------------

/// Case 1: one token in the home column, the other three home, no opponent
/// disc near the five by three block above it.
_Scene _sceneClear(int mySeat) => _Scene.build(
  'case1-clear',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[_home, _home, const _Pos(7, 11), _home],
);

/// Case 2: a ringed token of mine two cells left of the picked one and three
/// rows up, inside the above-centre block. The slid-right candidate (the
/// board's centre is to the right of the picked token) clears it, and clears
/// the opponent yards too, so the four-player room does not tip the choice
/// to a candidate below.
_Scene _sceneSlidAbove(int mySeat) => _Scene.build(
  'case2-slid-above',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[_home, const _Pos(3, 6), const _Pos(5, 8), _home],
);

/// Case 3A: a ringed token of mine straight above the picked one, inside the
/// part all three above candidates share.
_Scene _sceneBlockedAbove(int mySeat) => _Scene.build(
  'case3a-blocked-above',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[const _Pos(3, 6), _home, const _Pos(3, 8), _home],
);

/// Case 3B: ringed tokens of mine one on each side above the picked one, so
/// the three above candidates are blocked by different tokens.
_Scene _sceneFlankedAbove(int mySeat) => _Scene.build(
  'case3b-flanked-above',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[const _Pos(1, 6), const _Pos(5, 6), const _Pos(3, 8), _home],
);

/// Case 4, frame 63: a token on my start square, queue [6, 4], and a ringed
/// yard token of mine in the yard cell beside the start square, under the
/// above-centre block.
_Scene _sceneFrame63(int mySeat) => _Scene.build(
  'case4-frame63',
  mySeat,
  queue: <int>[6, 4],
  picked: 0,
  mine: <_Pos>[const _Pos(6, 14), _home, _yard, _home],
);

/// Case 5: only an opponent disc is in the above-centre block, on the left;
/// the slid-right candidate clears it.
_Scene _sceneOpponentAbove(int mySeat) => _Scene.build(
  'case5-opponent-above',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[_home, _home, const _Pos(3, 8), _home],
  opp: <_Pos>[const _Pos(1, 6), _yard, _yard, _yard],
);

/// Case 6: every candidate covers exactly one ringed token of mine (token 0
/// above, the yard token 3 below, which the queued 6 rings), and an opponent
/// disc makes the above-centre candidate cost more than the slid-toward
/// candidate.
_Scene _sceneEveryCovers(int mySeat) => _Scene.build(
  'case6-every-covers',
  mySeat,
  queue: <int>[6, 4],
  picked: 2,
  mine: <_Pos>[const _Pos(3, 6), _home, const _Pos(3, 8), _yard],
  opp: <_Pos>[const _Pos(1, 6), _yard, _yard, _yard],
);

/// Case 7: a token on the top row, nothing near.
_Scene _sceneTopRow(int mySeat) => _Scene.build(
  'case7-top-row',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[_home, _home, const _Pos(7, 0), _home],
);

/// Case 7 extra: a top-row token with a ringed token of mine under the
/// below-centre block. A below slid candidate clears it; above stays out.
_Scene _sceneTopRowCrowded(int mySeat) => _Scene.build(
  'case7b-top-row-crowded',
  mySeat,
  queue: <int>[3, 2],
  picked: 0,
  mine: <_Pos>[const _Pos(6, 0), const _Pos(8, 2), _home, _home],
);

/// Right of the board centre, toward the centre is LEFT. The picked token is
/// at view (11, 8); a ringed token of mine two cells right and two rows up is
/// in the above-centre block and in the slid-right block, and clear of the
/// slid-left block, so candidate 2 (slid left) is the only above candidate
/// that clears it.
_Scene _sceneRightToward(int mySeat) => _Scene.build(
  'case2r-right-toward',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[const _Pos(13, 6), _home, const _Pos(11, 8), _home],
);

/// Right of the board centre, away from the centre is RIGHT. Same picked
/// token; a ringed token of mine two cells left and two rows up blocks the
/// centred and the slid-left (toward) candidates, so candidate 3 (slid right,
/// away) is the one that clears it.
_Scene _sceneRightAway(int mySeat) => _Scene.build(
  'case3r-right-away',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[const _Pos(9, 6), _home, const _Pos(11, 8), _home],
);

/// The picked token on view column 14, nothing else near: the board clamp
/// moves the bubble and the pointer's own range ends before the token.
_Scene _sceneEdgeRight(int mySeat) => _Scene.build(
  'edge-right-col14',
  mySeat,
  queue: <int>[3, 2],
  picked: 3,
  mine: <_Pos>[_home, _home, _home, const _Pos(14, 8)],
);

/// The picked token on view column 13: the board clamp moves the bubble but
/// the token is still inside the pointer's range.
_Scene _sceneEdgeNear(int mySeat) => _Scene.build(
  'edge-right-col13',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[_home, _home, const _Pos(13, 8), _home],
);

/// The picked token on view column 0, nothing else near.
_Scene _sceneEdgeLeft(int mySeat) => _Scene.build(
  'edge-left-col0',
  mySeat,
  queue: <int>[3, 2],
  picked: 2,
  mine: <_Pos>[_home, _home, const _Pos(0, 8), _home],
);

/// C-508 D2: tokens 0 and 2 of mine on one track cell, both ringed by the
/// queued 3 and 2, the picker on token 0 (a tap on a stacked cell resolves to
/// its lowest legal index, so the upper disc of the pair is the one picked).
/// Token 1, ringed, is straight above and blocks every above candidate, so
/// the choice falls to the candidates below, where the mate's lower disc
/// reaches up into the bubble's block.
_Scene _sceneMates(int mySeat) => _Scene.build(
  'd2-mates',
  mySeat,
  queue: <int>[3, 2],
  picked: 0,
  mine: <_Pos>[const _Pos(11, 8), const _Pos(11, 6), const _Pos(11, 8), _home],
);

void main() {
  group('case 1: nothing in the above block', () {
    // C-508 case 1: must PASS on origin/main (pins what stays: above centre,
    // exactly the C-462 D5 rect).
    _cases('rect is the C-462 D5 above-centre rect', _sceneClear, (
      _Run run,
    ) async {
      run.expectChosen(1, 'nothing may be under the above-centre block');
      expect(
        run.plan.chosen.a + run.plan.chosen.b,
        0,
        reason: 'fixture is broken: ${run.why('nothing under candidate 1')}',
      );
      final double w = facePickerBubbleWidth(2);
      final double r = run.plan.picked.size / 2;
      final Offset c = run.pickedCentre - run.board.topLeft;
      final Rect today = Rect.fromLTWH(
        _clampOrigin(c.dx - w / 2, w, run.board.width),
        c.dy - r - kFacePickerTipGap - kFacePickerBubbleHeight,
        w,
        kFacePickerBubbleHeight,
      );
      final Rect got = run.pickerLocal;
      expect(
        (got.left - today.left).abs() <= _leftTolerance &&
            (got.top - today.top).abs() <= _eps &&
            (got.width - today.width).abs() <= _eps &&
            (got.height - today.height).abs() <= _eps,
        isTrue,
        reason: run.why('today\'s rect ${_fmt(today)}, got ${_fmt(got)}'),
      );
      expect(run.pointsUp, isFalse, reason: run.why('pointer down (above)'));
    });
  });

  group('case 2: a ringed token of mine in the above-centre block', () {
    // C-508 case 2: must FAIL on origin/main (main puts the bubble above
    // centre over the ringed token and never slides).
    _cases('slid-above candidate that clears it', _sceneSlidAbove, (
      _Run run,
    ) async {
      expect(
        run.plan.byOrder(1).coveredMine,
        hasLength(1),
        reason:
            'fixture is broken: ${run.why('one ringed token under cand 1')}',
      );
      final _Disc ringed = run.plan.byOrder(1).coveredMine.single;
      run.expectChosen(2, 'the slid-toward-centre above candidate wins');
      run.expectUncovered(<_Disc>[ringed], 'the ringed token is clear');
      expect(
        run.plan.chosen.below,
        isFalse,
        reason: run.why('the bubble stays above'),
      );
      run.expectChosenRect('slid right above');
      expect(run.pointsUp, isFalse, reason: run.why('pointer down (above)'));
      expect(
        run.pickerLocal.left,
        greaterThan(run.plan.byOrder(1).left),
        reason: run.why('the bubble slid right of the centred position'),
      );
      // The uncovered ringed token can be played through the normal path:
      // face 3 and face 2 both move it, so its own picker opens, anchored on
      // it, and nothing is sent.
      final SemanticsHandle semantics = run.tester.ensureSemantics();
      try {
        await run.tester.pump();
        final int frames = run.drive.transport.sentRaw.length;
        await run.tester.tapAt(run.board.topLeft + ringed.center);
        await run.tester.pump();
        await run.tester.pump(const Duration(milliseconds: 16));
        expect(
          run.drive.transport.sentRaw.length,
          frames,
          reason: run.why(
            'nothing sent while token ${ringed.token} opens a picker',
          ),
        );
        expect(
          find.byKey(facePickerKey),
          findsOneWidget,
          reason: run.why(
            'exactly one picker, the one of token ${ringed.token}',
          ),
        );
        final String wantLabel = AppLocalizations.of(
          run.tester.element(find.byKey(facePickerKey)),
        ).facePickerLabel(ringed.token + 1);
        expect(
          run.tester.getSemantics(find.byKey(facePickerKey)).label,
          wantLabel,
          reason: run.why(
            'the open picker is token ${ringed.token}\'s (semantics label '
            '"$wantLabel"), not the picked token ${run.scene.picked}\'s '
            'left open by a swallowed tap',
          ),
        );
        expect(
          (run.pointer.center.dx - (run.board.left + ringed.center.dx)).abs(),
          lessThanOrEqualTo(1.0),
          reason: run.why(
            'the new bubble is anchored on token ${ringed.token} (pointer x '
            '${run.pointer.center.dx.toStringAsFixed(1)} on '
            '${(run.board.left + ringed.center.dx).toStringAsFixed(1)})',
          ),
        );
      } finally {
        semantics.dispose();
      }
    });
  });

  group('case 3: ringed tokens of mine block every above candidate', () {
    // C-508 case 3: must FAIL on origin/main (main stays above centre).
    for (final (String name, _SceneBuilder build) in <(String, _SceneBuilder)>[
      ('one token straight above', _sceneBlockedAbove),
      ('one token on each side above', _sceneFlankedAbove),
    ]) {
      _cases('below centre, pointer up: $name', build, (_Run run) async {
        for (final int order in <int>[1, 2, 3]) {
          expect(
            run.plan.byOrder(order).a,
            greaterThanOrEqualTo(1),
            reason:
                'fixture is broken: above candidate $order covers no ringed '
                'token of mine. ${run.why('all above candidates blocked')}',
          );
        }
        run.expectChosen(4, 'below centre covers nothing ringed');
        run.expectUncovered(<_Disc>{
          for (final int order in <int>[1, 2, 3])
            ...run.plan.byOrder(order).coveredMine,
        }, 'no ringed token of mine under the bubble');
        final Rect below = run.pickerLocal;
        final Rect disc = run.plan.picked.rect;
        expect(
          below.top,
          greaterThanOrEqualTo(disc.bottom - _eps),
          reason: run.why(
            'the bubble top ${below.top.toStringAsFixed(1)} is below the '
            'token bottom ${disc.bottom.toStringAsFixed(1)}',
          ),
        );
        run.expectChosenRect('below centre');
        expect(
          run.pointsUp,
          isTrue,
          reason: run.why('the pointer points up at the token above it'),
        );
      });
    }
  });

  group('case 4: frame 63, the ringed yard token beside the start square', () {
    // C-508 case 4: must FAIL on origin/main (main covers the yard token
    // with the above-centre bubble, and the bubble swallows the tap).
    _cases(
      'the yard token is not covered and its tap plays it',
      _sceneFrame63,
      (_Run run) async {
        final _Disc yardDisc = run.plan.byOrder(1).coveredMine.single;
        expect(
          yardDisc.token,
          2,
          reason: 'fixture is broken: ${run.why('yard token 2 under cand 1')}',
        );
        run.expectChosen(2, 'slid toward the centre clears the yard token');
        run.expectUncovered(<_Disc>[yardDisc], 'the yard token disc square');
        run.expectChosenRect('above, slid right');
        expect(run.pointsUp, isFalse, reason: run.why('pointer down (above)'));

        final int frames = run.drive.transport.sentRaw.length;
        await run.tester.tapAt(run.board.topLeft + yardDisc.center);
        await run.tester.pump();
        await run.tester.pump(const Duration(milliseconds: 16));
        // The yard token has one face (the 6), so its tap is a move at once:
        // exactly one frame, a move of token 2 with face 6, nothing else.
        final List<String> sent = run.drive.transport.sentRaw.sublist(frames);
        final List<Map<String, Object?>> moves = <Map<String, Object?>>[
          for (final String text in sent)
            if (frameType(text) == 'move') frameData(text),
        ];
        expect(
          sent.length == 1 &&
              moves.length == 1 &&
              moves.single['token'] == 2 &&
              moves.single['face'] == 6,
          isTrue,
          reason: run.why(
            'a tap on the yard token centre '
            '${yardDisc.center.dx.toStringAsFixed(1)},'
            '${yardDisc.center.dy.toStringAsFixed(1)} sends exactly one '
            'frame, move token 2 face 6; frames sent: '
            '${sent.map(frameType).toList()}, moves: $moves, picker open: '
            '${run.tester.any(find.byKey(facePickerKey))}',
          ),
        );
      },
    );
  });

  group('case 5: an opponent token alone in the above-centre block', () {
    // C-508 case 5: must FAIL on origin/main (main covers the opponent disc).
    _cases('slid candidate chosen by b', _sceneOpponentAbove, (_Run run) async {
      final _Candidate first = run.plan.byOrder(1);
      expect(
        first.a == 0 && first.b >= 1,
        isTrue,
        reason:
            'fixture is broken: above centre must cover only an opponent '
            'disc. ${run.why('a=0 and b>=1 for candidate 1')}',
      );
      run.expectChosen(2, 'the slid candidate with b=0');
      expect(run.plan.chosen.b, 0);
      run.expectUncovered(first.coveredOther, 'the opponent disc is clear');
      run.expectChosenRect('above, slid right');
      expect(run.pointsUp, isFalse, reason: run.why('pointer down (above)'));
    });
  });

  group('case 6: every candidate covers one ringed token of mine', () {
    // C-508 case 6: must FAIL on origin/main (main stays above centre, the
    // earliest, but the smallest b is on the slid-toward candidate).
    _cases('earliest candidate with the smallest b', _sceneEveryCovers, (
      _Run run,
    ) async {
      for (final _Candidate c in run.plan.candidates) {
        expect(
          c.a,
          1,
          reason:
              'fixture is broken: candidate ${c.order} covers ${c.a} ringed '
              'tokens of mine, wanted exactly 1. ${run.why('a=1 for all')}',
        );
      }
      expect(
        run.plan.candidates.length,
        6,
        reason: 'fixture is broken: ${run.why('six distinct candidates')}',
      );
      final int smallestB = run.plan.candidates
          .map((_Candidate c) => c.b)
          .reduce(math.min);
      final _Candidate earliest = run.plan.candidates.firstWhere(
        (_Candidate c) => c.b == smallestB,
      );
      expect(
        earliest.order,
        isNot(1),
        reason:
            'fixture is broken: above centre must not already be the '
            'cheapest. ${run.why('candidate 1 costs more than another')}',
      );
      run.expectChosen(earliest.order, 'earliest with the smallest b');
      run.expectChosenRect('${earliest.name}, the earliest with b=$smallestB');
    });
  });

  group('case 7: a top-row token never gets an above bubble', () {
    // C-508 case 7: must PASS on origin/main (pins what stays: below).
    _cases('below centre', _sceneTopRow, (_Run run) async {
      expect(
        run.plan.candidates.any((_Candidate c) => !c.below),
        isFalse,
        reason: 'fixture is broken: ${run.why('no valid above candidate')}',
      );
      run.expectChosen(4, 'nothing under below centre');
      final Rect disc = run.plan.picked.rect;
      expect(
        run.pickerLocal.top,
        greaterThanOrEqualTo(disc.bottom - _eps),
        reason: run.why('bubble top below the token bottom ${disc.bottom}'),
      );
      run.expectChosenRect('below centre');
      expect(run.pointsUp, isTrue, reason: run.why('pointer up (below)'));
    });

    // Extra to case 7: must FAIL on origin/main (main stays below centre
    // over the ringed token; the contract slides it clear, still below).
    _cases(
      'a crowded block below slides, it never goes above',
      _sceneTopRowCrowded,
      (_Run run) async {
        expect(
          run.plan.candidates.any((_Candidate c) => !c.below),
          isFalse,
          reason: 'fixture is broken: ${run.why('no valid above candidate')}',
        );
        expect(
          run.plan.byOrder(4).a,
          greaterThanOrEqualTo(1),
          reason:
              'fixture is broken: ${run.why('below centre covers a ringed')}',
        );
        run.expectChosen(6, 'below slid away clears the ringed token');
        final Rect disc = run.plan.picked.rect;
        expect(
          run.pickerLocal.top,
          greaterThanOrEqualTo(disc.bottom - _eps),
          reason: run.why('bubble top below the token bottom ${disc.bottom}'),
        );
        run.expectChosenRect('below, slid away');
        expect(run.pointsUp, isTrue, reason: run.why('pointer up (below)'));
      },
    );
  });

  group('cases 2 and 3 right of the centre: toward is left, away is right', () {
    // C-508 case 2, right half: must FAIL on origin/main (main stays above
    // centre over the ringed token).
    _cases('candidate 2, slid left toward the centre, wins', _sceneRightToward, (
      _Run run,
    ) async {
      final Offset c = run.pickedCentre - run.board.topLeft;
      expect(
        c.dx,
        greaterThan(run.board.width / 2),
        reason: 'fixture is broken: ${run.why('picked token right of centre')}',
      );
      expect(
        run.plan.byOrder(1).a,
        greaterThanOrEqualTo(1),
        reason: 'fixture is broken: ${run.why('candidate 1 covers a ringed')}',
      );
      expect(
        run.swappedPlan.chosen.order,
        isNot(2),
        reason:
            'fixture is broken: with toward and away swapped the contract '
            'would also choose candidate 2. ${run.why('a discriminating scene')}',
      );
      run.expectChosen(2, 'slid LEFT (toward the centre) is the first clear');
      run.expectChosenRect('candidate 2, above slid left');
      expect(
        run.pickerLocal.left,
        lessThan(run.plan.byOrder(1).left),
        reason: run.why('candidate 2 slid left of the centred position'),
      );
      expect(run.pointsUp, isFalse, reason: run.why('pointer down (above)'));
      run.expectSane();
    });

    // C-508 case 3 shape, right half: must FAIL on origin/main (main stays
    // above centre over the ringed token).
    _cases(
      'candidate 2 blocked, candidate 3 slid right away from the centre wins',
      _sceneRightAway,
      (_Run run) async {
        final Offset c = run.pickedCentre - run.board.topLeft;
        expect(
          c.dx,
          greaterThan(run.board.width / 2),
          reason:
              'fixture is broken: ${run.why('picked token right of centre')}',
        );
        expect(
          run.plan.byOrder(1).a >= 1 && run.plan.byOrder(2).a >= 1,
          isTrue,
          reason:
              'fixture is broken: ${run.why('candidates 1 and 2 are blocked')}',
        );
        expect(
          run.plan.byOrder(3).a,
          0,
          reason: 'fixture is broken: ${run.why('candidate 3 is clear')}',
        );
        expect(
          run.swappedPlan.chosen.order,
          isNot(3),
          reason:
              'fixture is broken: with toward and away swapped the contract '
              'would also choose candidate 3. '
              '${run.why('a discriminating scene')}',
        );
        run.expectChosen(
          3,
          'candidate 2 is blocked, slid RIGHT (away) is clear',
        );
        run.expectChosenRect('candidate 3, above slid right');
        expect(
          run.pickerLocal.left,
          greaterThan(run.plan.byOrder(1).left),
          reason: run.why('candidate 3 slid right of the centred position'),
        );
        expect(run.pointsUp, isFalse, reason: run.why('pointer down (above)'));
        run.expectSane();
      },
    );
  });

  group('C-508 D2: a ringed mate on the picked token\'s own cell', () {
    // Must FAIL on origin/main (main stays above centre over the ringed token
    // above). It also fails an implementation that counts the mate: the
    // mate's disc reaches into every below block, so all six candidates would
    // score a=1 and the earliest, above centre, would win.
    _cases('the mate is excluded, a candidate below wins', _sceneMates, (
      _Run run,
    ) async {
      for (final int order in <int>[1, 2, 3]) {
        expect(
          run.plan.byOrder(order).a,
          greaterThanOrEqualTo(1),
          reason:
              'fixture is broken: above candidate $order covers no ringed '
              'token. ${run.why('all above candidates blocked')}',
        );
      }
      expect(
        run.plan.chosen.below && run.plan.chosen.a == 0,
        isTrue,
        reason:
            'fixture is broken: a below candidate must clear every ringed '
            'token. ${run.why('a clear below candidate')}',
      );
      expect(
        run.matesCountedPlan
            .byOrder(run.plan.chosen.order)
            .coveredMine
            .map((_Disc d) => d.token),
        <int>[2],
        reason:
            'fixture is broken: the mate (token 2) must reach into the '
            'below-centre block. ${run.why('mate counted covers it')}',
      );
      expect(
        run.matesCountedPlan.chosen.order,
        isNot(run.plan.chosen.order),
        reason:
            'fixture is broken: counting the mate must change the choice. '
            '${run.why('a discriminating scene')}',
      );
      run.expectChosenRect('a below candidate with the mate excluded');
      expect(run.pointsUp, isTrue, reason: run.why('pointer up (below)'));
      run.expectSane();
    });
  });

  group('the board edge clamp and the pointer clamp (C-462 D5, C-508 D4)', () {
    // Must PASS on origin/main: the horizontal clamp and the pointer's own
    // range are C-462 D5 behaviour the new placement keeps.
    _cases(
      'column 14: bubble inside, pointer at the end of its range',
      (int mySeat) {
        return _sceneEdgeRight(mySeat);
      },
      (_Run run) async {
        final double w = run.pickerLocal.width;
        final double m = kSpace2 + _pointerHalf;
        final Offset c = run.pickedCentre - run.board.topLeft;
        expect(
          c.dx - run.plan.chosen.left,
          greaterThan(w - m + 1),
          reason:
              'fixture is broken: the pointer range must end more than 1 dp '
              'short of the token. ${run.why('pointer clamp engaged')}',
        );
        run.expectChosenRect('the clamped chosen candidate');
        run.expectSane();
        expect(
          (run.pointer.center.dx - (run.picker.left + w - m)).abs(),
          lessThanOrEqualTo(1.0),
          reason: run.why(
            'pointer tip at the far end of its range '
            '${(run.picker.left + w - m).toStringAsFixed(1)}, got '
            '${run.pointer.center.dx.toStringAsFixed(1)}',
          ),
        );
      },
    );

    _cases(
      'column 13: bubble moved by the board clamp, pointer still on '
      'the token',
      _sceneEdgeNear,
      (_Run run) async {
        expect(
          run.plan.chosen.clamped,
          isTrue,
          reason: 'fixture is broken: ${run.why('the board clamp moved it')}',
        );
        run.expectChosenRect('the clamped chosen candidate');
        run.expectSane();
        expect(
          (run.pointer.center.dx - run.pickedCentre.dx).abs(),
          lessThanOrEqualTo(1.0),
          reason: run.why(
            'pointer tip within 1 dp of the token centre x '
            '${run.pickedCentre.dx.toStringAsFixed(1)}, got '
            '${run.pointer.center.dx.toStringAsFixed(1)}',
          ),
        );
      },
    );

    _cases(
      'column 0: bubble inside, pointer at the near end of its range',
      (int mySeat) {
        return _sceneEdgeLeft(mySeat);
      },
      (_Run run) async {
        final double m = kSpace2 + _pointerHalf;
        final Offset c = run.pickedCentre - run.board.topLeft;
        expect(
          c.dx - run.plan.chosen.left,
          lessThan(m - 1),
          reason:
              'fixture is broken: the pointer range must start more than 1 dp '
              'past the token. ${run.why('pointer clamp engaged')}',
        );
        run.expectChosenRect('the clamped chosen candidate');
        run.expectSane();
        expect(
          (run.pointer.center.dx - (run.picker.left + m)).abs(),
          lessThanOrEqualTo(1.0),
          reason: run.why(
            'pointer tip at the near end of its range '
            '${(run.picker.left + m).toStringAsFixed(1)}, got '
            '${run.pointer.center.dx.toStringAsFixed(1)}',
          ),
        );
      },
    );
  });

  group('C-508 D4: the open scale grows out of the pointer tip', () {
    // C-508 D4: the slid scenes pass on origin/main only because main never
    // slides (its pointer is centred, so its bottom-centre origin is the
    // tip); the board-edge scene has an off-centre pointer on main too and
    // must FAIL there (main scales about the bubble's bottom centre, so the
    // tip drifts while it opens).
    const List<(Locale, int)> matrix = <(Locale, int)>[
      (Locale('en'), 0),
      (Locale('ar'), 2),
    ];
    for (final (String name, _SceneBuilder build) in <(String, _SceneBuilder)>[
      ('above, slid right (candidate 3)', _sceneRightAway),
      ('below, slid away (candidate 6)', _sceneTopRowCrowded),
      ('above, pointer off centre at the board edge', _sceneEdgeRight),
    ]) {
      _cases(
        'the pointer tip holds still half way through the open: $name',
        build,
        (_Run run) async {
          final bool below = run.plan.chosen.below;
          final double w = run.plan.chosen.width;
          final double centred = run.plan.chosen.rawLeft + w / 2;
          expect(
            (run.plan.picked.center.dx - run.plan.chosen.left - w / 2).abs(),
            greaterThan(10),
            reason:
                'fixture is broken: the pointer must be well off the '
                'bubble centre. ${run.why('a slid candidate')} (centred '
                '${centred.toStringAsFixed(1)})',
          );

          Offset tip() {
            final Rect pointer = run.pointer;
            final Finder box = find.descendant(
              of: find.byKey(facePickerKey),
              matching: find.byWidgetPredicate(
                (Widget widget) => widget is SizedBox && widget.width == w,
              ),
            );
            expect(box, findsOneWidget, reason: run.why('one bubble box'));
            final Rect bubble = run.tester.getRect(box);
            return Offset(
              pointer.center.dx,
              below ? bubble.top : bubble.bottom,
            );
          }

          Transform scaling() {
            final List<Transform> found = run.tester
                .widgetList<Transform>(
                  find.descendant(
                    of: find.byKey(facePickerKey),
                    matching: find.byType(Transform),
                  ),
                )
                .where((Transform t) => t.transform.entry(0, 0) < 0.999)
                .toList();
            expect(
              found,
              hasLength(1),
              reason: run.why('exactly one scaling Transform mid-open'),
            );
            return found.single;
          }

          await run.tester.tapAt(run.pickedCentre);
          await run.tester.pump();
          await run.tester.pump(kFacePickerOpen ~/ 2);
          expect(
            run.tester.any(find.byKey(facePickerKey)),
            isTrue,
            reason: run.why('picker open half way'),
          );
          final Transform mid = scaling();
          final double scale = mid.transform.entry(0, 0);
          expect(
            scale > 0.1 && scale < 0.9,
            isTrue,
            reason: run.why('a scale below 1 half way, got $scale'),
          );
          final Offset halfTip = tip();

          await run.tester.pump(kFacePickerOpen);
          await run.tester.pump(kFacePickerOpen);
          final Offset fullTip = tip();
          final Rect settled = run.picker;
          expect(
            (settled.width - w).abs() < _eps,
            isTrue,
            reason: run.why('settled bubble width $w, got ${settled.width}'),
          );
          expect(
            (halfTip - fullTip).distance,
            lessThanOrEqualTo(1.0),
            reason: run.why(
              'the pointer tip stays put while the bubble grows: tip at '
              'scale ${scale.toStringAsFixed(2)} is $halfTip, settled $fullTip',
            ),
          );
          // The origin is the tip: x is the pointer's place in the bubble
          // mapped to -1..1 across the width, y the bubble edge the pointer
          // is on (bottom when above, top when below).
          final double wantX =
              (run.pointer.center.dx - settled.left) / w * 2 - 1;
          final Alignment origin = mid.alignment! as Alignment;
          expect(
            (origin.x - wantX).abs() < 0.02 &&
                (origin.y - (below ? -1.0 : 1.0)).abs() < _eps,
            isTrue,
            reason: run.why(
              'Transform alignment (${wantX.toStringAsFixed(3)}, '
              '${below ? -1 : 1}), got (${origin.x.toStringAsFixed(3)}, '
              '${origin.y})',
            ),
          );
        },
        matrix: matrix,
        open: false,
        animate: true,
      );
    }
  });

  group('case 8: the bubble is inside the board, aimed, and tappable', () {
    // C-508 case 8: PASSES on origin/main for every scene (inside the board,
    // tip x on the token centre, 48 x 48 options hold for today's placement
    // too). It pins what the new placement must keep.
    final List<(String, _SceneBuilder)> scenes = <(String, _SceneBuilder)>[
      ('case 1', _sceneClear),
      ('case 2', _sceneSlidAbove),
      ('case 3a', _sceneBlockedAbove),
      ('case 3b', _sceneFlankedAbove),
      ('case 4', _sceneFrame63),
      ('case 5', _sceneOpponentAbove),
      ('case 6', _sceneEveryCovers),
      ('case 7', _sceneTopRow),
      ('case 7 extra', _sceneTopRowCrowded),
      ('case 2 right half', _sceneRightToward),
      ('case 3 right half', _sceneRightAway),
      ('mates', _sceneMates),
    ];
    for (final (String name, _SceneBuilder build) in scenes) {
      _cases(
        '$name invariants',
        build,
        (_Run run) async => run.expectSane(),
        matrix: const <(Locale, int)>[(Locale('en'), 0), (Locale('ar'), 2)],
      );
    }
  });
}
