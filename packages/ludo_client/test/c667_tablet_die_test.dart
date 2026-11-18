// Tests for C-667t (order 667, run 155): on a large screen the die sits where
// the thumb is, not on the bottom edge. Written from the contract in
// work/ludo/orders/667-tablet-die-thumb-zone.md (D1 to D4) and nothing else.
//
// A real GameScreen over a real RoomController on FakeTransport, mounted the
// way test/board_floor_nav_inset_test.dart mounts it, under FeedbackScope,
// buildAppTheme and the real Poppins and Noto Sans Arabic fonts. The die, the
// board, the tray, the hint bulb, the header banner and the notice are found
// by the keys the existing tests use: game-die, game-screen-board,
// game-roll-tray, game-hint-button, game-screen-turn-banner and
// game-no-move-notice. Helpers are copied by hand; nothing is imported from
// another test file.
//
// Three play states are laid out at every size, all on my own turn: `roll`
// (await_roll, the die rolls on tap), `queue` (await_move after a six, a face
// showing and the roll tray beside the die) and `nomove` (the no-move hold,
// the refusal mark on the die and the notice under the band). A fourth,
// `wait`, is used only to prove a tap does not roll out of turn.
//
// Sizes, logical px (the contract's names): T1 924x1480 and T2 1480x924 at
// density 2.0, T3 672x1076 and T4 1076x672 at density 2.75, phones P1 360x780,
// P2 412x915, P3 320x568. The phones are also run with a status and a
// navigation inset (P1i, P2i), because the base keeps the board floor above
// a navigation bar and the contract says no widget moves on a phone.
//
// Base anchors. The tables further down were measured on the base tree
// (origin/main 4c71c0f) by mounting these same cases with zero insets for the
// tablets and the phones and the insets named in _sizes for P1i and P2i. They
// are regression anchors, not invented numbers. A case that has no anchor
// for its key fails by name instead of passing blind.
//
// No pumpAndSettle: a turn arms a one-second countdown and the no-move case
// arms a 1500 ms hold. Every case is a fixed list of frames; there is no
// seed, and the reason line of each failure names the size, locale, state and
// text scale, which is the whole reproduction. Re-run one case with
//   flutter test test/c667_tablet_die_test.dart --plain-name '<case id>'

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme, kSpace2;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c667-tablet-die-test.invalid/ws';

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const Key _boardKey = Key('game-screen-board');
const Key _dieKey = Key('game-die');
const Key _trayKey = Key('game-roll-tray');
const Key _hintKey = Key('game-hint-button');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _noticeKey = Key('game-no-move-notice');
const Key _markKey = Key('game-die-no-move-mark');
// C-667 r2: the widget that bounds exactly the visible band group.
const Key _groupKey = ValueKey<String>('c667-side-band');

const double _dieHitFloor = 48;
const double _boardFloor = 324;

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

class _Size {
  const _Size(
    this.id,
    this.width,
    this.height,
    this.dpr, {
    this.topInset = 0,
    this.bottomInset = 0,
  });

  final String id;
  final double width;
  final double height;
  final double dpr;
  final double topInset;
  final double bottomInset;

  bool get large => math.min(width, height) >= 600;
  bool get landscape => width > height;
  Size get logical => Size(width, height);
  Size get physical => Size(width * dpr, height * dpr);
  Rect get screen => Offset.zero & logical;
}

const _Size _t1 = _Size('T1', 924, 1480, 2.0);
const _Size _t2 = _Size('T2', 1480, 924, 2.0);
const _Size _t3 = _Size('T3', 672, 1076, 2.75);
const _Size _t4 = _Size('T4', 1076, 672, 2.75);
const _Size _p1 = _Size('P1', 360, 780, 3);
const _Size _p2 = _Size('P2', 412, 915, 2.625);
const _Size _p3 = _Size('P3', 320, 568, 2);
const _Size _p1i = _Size('P1i', 360, 780, 3, topInset: 32, bottomInset: 24);
const _Size _p2i = _Size('P2i', 412, 915, 2.625, topInset: 32, bottomInset: 48);

const List<_Size> _landscapeTablets = <_Size>[_t2, _t4];
const List<_Size> _portraitTablets = <_Size>[_t1, _t3];
const List<_Size> _phones = <_Size>[_p1, _p2, _p3, _p1i, _p2i];
const List<_Size> _everySize = <_Size>[
  _t1,
  _t2,
  _t3,
  _t4,
  _p1,
  _p2,
  _p3,
  _p1i,
  _p2i,
];

enum _St { roll, queue, nomove, wait }

const List<_St> _layoutStates = <_St>[_St.roll, _St.queue, _St.nomove];

String _caseId(_Size size, Locale locale, _St state, [double scale = 1.0]) =>
    '${size.id} ${locale.languageCode} ${state.name}'
    '${scale == 1.0 ? '' : ' scale ${scale.toStringAsFixed(1)}'}';

String _scenario(_Size size, Locale locale, _St state, double scale) =>
    'scenario: ${size.width.toStringAsFixed(0)}x'
    '${size.height.toStringAsFixed(0)} dp at density ${size.dpr}, '
    'insets top ${size.topInset} bottom ${size.bottomInset}, '
    'locale ${locale.languageCode}, state ${state.name}, text scale '
    '${scale.toStringAsFixed(1)}; rerun with --plain-name '
    "'${_caseId(size, locale, state, scale)}'";

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c667-tablet-die-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _faceLegal(int face, List<int> tokens) =>
    <String, Object?>{'face': face, 'tokens': tokens};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  int? value,
  List<int>? legal,
  int k = 0,
  List<int>? queue,
  List<Map<String, Object?>>? legalByFace,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': 45000,
  'k': k,
  'value': ?value,
  'legal': ?legal,
  'queue': ?queue,
  'legal_by_face': ?legalByFace,
};

Map<String, Object?> _roomJson({
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int seq = 1,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': null,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

List<Map<String, Object?>> _twoSeats({
  List<int> seat0Tokens = const <int>[-1, -1, -1, -1],
}) => <Map<String, Object?>>[
  _seatJson(0, name: _mySeatName, tokens: seat0Tokens),
  _seatJson(1, name: _otherSeatName),
];

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

class _FakeFeedbackService implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

typedef _Keep = void Function(RoomController controller);

Future<(RoomController, FakeTransport)> _connect(
  WidgetTester tester,
  _Keep keep, {
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  keep(controller);

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(seats: seats, turn: turn),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(Widget child, {required Locale locale}) {
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
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  required Locale locale,
}) async {
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: _FakeFeedbackService(),
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
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

/// What a case hands its body: the controller's transport, to read what the
/// screen sent.
class _Rig {
  _Rig(this.transport);

  final FakeTransport transport;

  List<String> sentOfType(String type) =>
      transport.sentRaw.where((String raw) => _typeOf(raw) == type).toList();
}

/// Sets the surface (physical pixels, logical times density, both system
/// insets), the text scale, mounts [state] on my own turn and runs [body].
/// Everything is reset before the test returns, and again from a tearDown if
/// the body never gets there.
Future<void> _withScreen(
  WidgetTester tester,
  _Size size,
  Locale locale,
  _St state,
  Future<void> Function(_Rig rig) body, {
  double scale = 1.0,
}) async {
  tester.view.physicalSize = size.physical;
  tester.view.devicePixelRatio = size.dpr;
  final FakeViewPadding inset = FakeViewPadding(
    top: size.topInset * size.dpr,
    bottom: size.bottomInset * size.dpr,
  );
  tester.view.padding = inset;
  tester.view.viewPadding = inset;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.reset);
  RoomController? controller;
  try {
    final (RoomController c, FakeTransport transport) = await _mountState(
      tester,
      (RoomController made) {
        controller = made;
      },
      locale: locale,
      state: state,
    );
    controller = c;
    await body(_Rig(transport));
  } finally {
    final RoomController? owned = controller;
    if (owned != null) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      owned.dispose();
    }
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

Future<(RoomController, FakeTransport)> _mountState(
  WidgetTester tester,
  _Keep keep, {
  required Locale locale,
  required _St state,
}) async {
  switch (state) {
    case _St.roll:
    case _St.wait:
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connect(
        tester,
        keep,
        seats: _twoSeats(),
        turn: _turnJson(seat: state == _St.roll ? 0 : 1, phase: 'await_roll'),
      );
      await _mount(tester, controller, locale: locale);
      return (controller, transport);
    case _St.queue:
      // My seat in await_move, token 0 already out, queue [6, 6, 3]: a face
      // on the die and the roll tray beside it.
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connect(
        tester,
        keep,
        seats: _twoSeats(seat0Tokens: const <int>[0, -1, -1, -1]),
        turn: _turnJson(
          seat: 0,
          phase: 'await_move',
          k: 3,
          value: 6,
          legal: const <int>[0, 1, 2, 3],
          queue: const <int>[6, 6, 3],
          legalByFace: <Map<String, Object?>>[
            _faceLegal(6, const <int>[0, 1, 2, 3]),
            _faceLegal(3, const <int>[0]),
          ],
        ),
      );
      await _mount(tester, controller, locale: locale);
      return (controller, transport);
    case _St.nomove:
      // My seat lands on await_roll, then a `rolled` with an empty `legal`
      // and, in the same pumps, the next seat's `turn`. That arms the 1500 ms
      // no-move hold; the pumps below do not advance that timer.
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connect(
        tester,
        keep,
        seats: _twoSeats(),
        turn: _turnJson(seat: 0, phase: 'await_roll', k: 0),
      );
      await _mount(tester, controller, locale: locale);
      final int seqAfterRolled = controller.room!.seq + 1;
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 3,
            'legal': <int>[],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'd' * 64,
            'seq': seqAfterRolled,
          },
        ),
      );
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 1,
            'deadline_ms': 45000,
            'seq': seqAfterRolled + 1,
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      return (controller, transport);
  }
}

// ---------------------------------------------------------------------------
// Measurement.
// ---------------------------------------------------------------------------

String _r(Rect? rect) {
  if (rect == null) {
    return 'absent';
  }
  return 'L${rect.left.toStringAsFixed(2)} T${rect.top.toStringAsFixed(2)} '
      'R${rect.right.toStringAsFixed(2)} B${rect.bottom.toStringAsFixed(2)} '
      '(${rect.width.toStringAsFixed(2)}x${rect.height.toStringAsFixed(2)})';
}

/// Every rect is in logical px, global coordinates; null when the key is not
/// in the tree exactly once.
class _Frame {
  const _Frame({
    required this.die,
    required this.board,
    required this.square,
    required this.banner,
    required this.tray,
    required this.hint,
    required this.notice,
  });

  final Rect die;
  final Rect board;

  /// The painted board: the largest square, centred in [board]. The board
  /// widget centres its square in the box it is given, and on a wide screen
  /// that box is as wide as the whole column.
  final Rect square;
  final Rect? banner;
  final Rect? tray;
  final Rect? hint;
  final Rect? notice;

  /// The die band as the contract defines it: the die, the tray beside it,
  /// the hint bulb. The no-move mark hangs off the die and is not measured
  /// here.
  Rect get band {
    Rect out = die;
    final Rect? t = tray;
    if (t != null) {
      out = out.expandToInclude(t);
    }
    final Rect? h = hint;
    if (h != null) {
      out = out.expandToInclude(h);
    }
    return out;
  }

  String describe() =>
      'die ${_r(die)}; board ${_r(board)}; square ${_r(square)}; banner ${_r(banner)}; '
      'tray ${_r(tray)}; hint ${_r(hint)}; notice ${_r(notice)}';
}

Rect? _rectOfOne(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  if (tester.widgetList(finder).length != 1) {
    return null;
  }
  return tester.getRect(finder);
}

Rect _squareIn(Rect box) => Rect.fromCenter(
  center: box.center,
  width: math.min(box.width, box.height),
  height: math.min(box.width, box.height),
);

_Frame _measure(WidgetTester tester, String where) {
  final Rect? die = _rectOfOne(tester, _dieKey);
  final Rect? board = _rectOfOne(tester, _boardKey);
  if (die == null || board == null) {
    fail(
      'C-667t: $where: the die (game-die) and the board (game-screen-board) '
      'must each be in the tree exactly once; die ${_r(die)}, board '
      '${_r(board)}.',
    );
  }
  return _Frame(
    die: die,
    board: board,
    square: _squareIn(board),
    banner: _rectOfOne(tester, _bannerKey),
    tray: _rectOfOne(tester, _trayKey),
    hint: _rectOfOne(tester, _hintKey),
    notice: _rectOfOne(tester, _noticeKey),
  );
}

/// The semantics nodes in traversal order, each with its rect in logical px.
List<(SemanticsNode, Rect)> _semanticsInOrder(WidgetTester tester) {
  final SemanticsNode root = tester
      .renderObject(find.byKey(_dieKey))
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final double dpr = tester.view.devicePixelRatio;
  final List<(SemanticsNode, Rect)> out = <(SemanticsNode, Rect)>[];
  void walk(SemanticsNode node, Matrix4 parent) {
    final Matrix4 own = node.transform == null
        ? parent
        : (parent.clone()..multiply(node.transform!));
    final Rect physical = MatrixUtils.transformRect(own, node.rect);
    out.add((
      node,
      Rect.fromLTRB(
        physical.left / dpr,
        physical.top / dpr,
        physical.right / dpr,
        physical.bottom / dpr,
      ),
    ));
    node.visitChildren((SemanticsNode child) {
      walk(child, own);
      return true;
    });
  }

  walk(root, Matrix4.identity());
  return out;
}

// ---------------------------------------------------------------------------
// Base anchors, measured on origin/main 4c71c0f (the tree this file was
// written in, before any change to lib/), logical px, zero insets except for
// the sizes that name insets. Keyed `size|locale|state`. Phones are compared
// to these exactly (D3). The tablets use them for the base board height (D1),
// the base die and board (D2) and the header top.
// ---------------------------------------------------------------------------

const String _baseSha = '4c71c0f';

class _Anchor {
  const _Anchor({
    required this.die,
    required this.board,
    required this.banner,
    required this.tray,
    required this.hint,
    required this.notice,
  });

  final Rect die;
  final Rect board;

  /// The painted board, the largest square centred in [board].
  Rect get square => _squareIn(board);
  final Rect? banner;
  final Rect? tray;
  final Rect? hint;
  final Rect? notice;
}

const Map<String, _Anchor> _baseAnchors = <String, _Anchor>{
  'T1|en|roll': _Anchor(
    die: Rect.fromLTRB(426.0, 1364.0, 498.0, 1436.0),
    board: Rect.fromLTRB(8.0, 112.0, 916.0, 1348.0),
    banner: Rect.fromLTRB(36.0, 72.0, 852.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 1376.0, 56.0, 1424.0),
    notice: null,
  ),
  'T1|en|queue': _Anchor(
    die: Rect.fromLTRB(342.0, 1364.0, 414.0, 1436.0),
    board: Rect.fromLTRB(8.0, 112.0, 916.0, 1348.0),
    banner: Rect.fromLTRB(36.0, 72.0, 852.0, 92.0),
    tray: Rect.fromLTRB(422.0, 1376.0, 582.0, 1424.0),
    hint: Rect.fromLTRB(8.0, 1376.0, 56.0, 1424.0),
    notice: null,
  ),
  'T1|en|nomove': _Anchor(
    die: Rect.fromLTRB(426.0, 1364.0, 498.0, 1436.0),
    board: Rect.fromLTRB(8.0, 112.0, 916.0, 1348.0),
    banner: Rect.fromLTRB(36.0, 72.0, 852.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 1376.0, 56.0, 1424.0),
    notice: Rect.fromLTRB(8.0, 1444.0, 916.0, 1464.0),
  ),
  'T1|ar|roll': _Anchor(
    die: Rect.fromLTRB(426.0, 1364.0, 498.0, 1436.0),
    board: Rect.fromLTRB(8.0, 112.0, 916.0, 1348.0),
    banner: Rect.fromLTRB(72.0, 72.0, 888.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(868.0, 1376.0, 916.0, 1424.0),
    notice: null,
  ),
  'T1|ar|queue': _Anchor(
    die: Rect.fromLTRB(510.0, 1364.0, 582.0, 1436.0),
    board: Rect.fromLTRB(8.0, 112.0, 916.0, 1348.0),
    banner: Rect.fromLTRB(72.0, 72.0, 888.0, 92.0),
    tray: Rect.fromLTRB(342.0, 1376.0, 502.0, 1424.0),
    hint: Rect.fromLTRB(868.0, 1376.0, 916.0, 1424.0),
    notice: null,
  ),
  'T1|ar|nomove': _Anchor(
    die: Rect.fromLTRB(426.0, 1364.0, 498.0, 1436.0),
    board: Rect.fromLTRB(8.0, 112.0, 916.0, 1348.0),
    banner: Rect.fromLTRB(72.0, 72.0, 888.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(868.0, 1376.0, 916.0, 1424.0),
    notice: Rect.fromLTRB(8.0, 1444.0, 916.0, 1464.0),
  ),
  'T2|en|roll': _Anchor(
    die: Rect.fromLTRB(704.0, 808.0, 776.0, 880.0),
    board: Rect.fromLTRB(8.0, 112.0, 1472.0, 792.0),
    banner: Rect.fromLTRB(36.0, 72.0, 1408.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 820.0, 56.0, 868.0),
    notice: null,
  ),
  'T2|en|queue': _Anchor(
    die: Rect.fromLTRB(620.0, 808.0, 692.0, 880.0),
    board: Rect.fromLTRB(8.0, 112.0, 1472.0, 792.0),
    banner: Rect.fromLTRB(36.0, 72.0, 1408.0, 92.0),
    tray: Rect.fromLTRB(700.0, 820.0, 860.0, 868.0),
    hint: Rect.fromLTRB(8.0, 820.0, 56.0, 868.0),
    notice: null,
  ),
  'T2|en|nomove': _Anchor(
    die: Rect.fromLTRB(704.0, 808.0, 776.0, 880.0),
    board: Rect.fromLTRB(8.0, 112.0, 1472.0, 792.0),
    banner: Rect.fromLTRB(36.0, 72.0, 1408.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 820.0, 56.0, 868.0),
    notice: Rect.fromLTRB(8.0, 888.0, 1472.0, 908.0),
  ),
  'T2|ar|roll': _Anchor(
    die: Rect.fromLTRB(704.0, 808.0, 776.0, 880.0),
    board: Rect.fromLTRB(8.0, 112.0, 1472.0, 792.0),
    banner: Rect.fromLTRB(72.0, 72.0, 1444.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(1424.0, 820.0, 1472.0, 868.0),
    notice: null,
  ),
  'T2|ar|queue': _Anchor(
    die: Rect.fromLTRB(788.0, 808.0, 860.0, 880.0),
    board: Rect.fromLTRB(8.0, 112.0, 1472.0, 792.0),
    banner: Rect.fromLTRB(72.0, 72.0, 1444.0, 92.0),
    tray: Rect.fromLTRB(620.0, 820.0, 780.0, 868.0),
    hint: Rect.fromLTRB(1424.0, 820.0, 1472.0, 868.0),
    notice: null,
  ),
  'T2|ar|nomove': _Anchor(
    die: Rect.fromLTRB(704.0, 808.0, 776.0, 880.0),
    board: Rect.fromLTRB(8.0, 112.0, 1472.0, 792.0),
    banner: Rect.fromLTRB(72.0, 72.0, 1444.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(1424.0, 820.0, 1472.0, 868.0),
    notice: Rect.fromLTRB(8.0, 888.0, 1472.0, 908.0),
  ),
  'T3|en|roll': _Anchor(
    die: Rect.fromLTRB(300.0, 960.0, 372.0, 1032.0),
    board: Rect.fromLTRB(8.0, 112.0, 664.0, 944.0),
    banner: Rect.fromLTRB(36.0, 72.0, 600.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 972.0, 56.0, 1020.0),
    notice: null,
  ),
  'T3|en|queue': _Anchor(
    die: Rect.fromLTRB(216.0, 960.0, 288.0, 1032.0),
    board: Rect.fromLTRB(8.0, 112.0, 664.0, 944.0),
    banner: Rect.fromLTRB(36.0, 72.0, 600.0, 92.0),
    tray: Rect.fromLTRB(296.0, 972.0, 456.0, 1020.0),
    hint: Rect.fromLTRB(8.0, 972.0, 56.0, 1020.0),
    notice: null,
  ),
  'T3|en|nomove': _Anchor(
    die: Rect.fromLTRB(300.0, 960.0, 372.0, 1032.0),
    board: Rect.fromLTRB(8.0, 112.0, 664.0, 944.0),
    banner: Rect.fromLTRB(36.0, 72.0, 600.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 972.0, 56.0, 1020.0),
    notice: Rect.fromLTRB(8.0, 1040.0, 664.0, 1060.0),
  ),
  'T3|ar|roll': _Anchor(
    die: Rect.fromLTRB(300.0, 960.0, 372.0, 1032.0),
    board: Rect.fromLTRB(8.0, 112.0, 664.0, 944.0),
    banner: Rect.fromLTRB(72.0, 72.0, 636.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(616.0, 972.0, 664.0, 1020.0),
    notice: null,
  ),
  'T3|ar|queue': _Anchor(
    die: Rect.fromLTRB(384.0, 960.0, 456.0, 1032.0),
    board: Rect.fromLTRB(8.0, 112.0, 664.0, 944.0),
    banner: Rect.fromLTRB(72.0, 72.0, 636.0, 92.0),
    tray: Rect.fromLTRB(216.0, 972.0, 376.0, 1020.0),
    hint: Rect.fromLTRB(616.0, 972.0, 664.0, 1020.0),
    notice: null,
  ),
  'T3|ar|nomove': _Anchor(
    die: Rect.fromLTRB(300.0, 960.0, 372.0, 1032.0),
    board: Rect.fromLTRB(8.0, 112.0, 664.0, 944.0),
    banner: Rect.fromLTRB(72.0, 72.0, 636.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(616.0, 972.0, 664.0, 1020.0),
    notice: Rect.fromLTRB(8.0, 1040.0, 664.0, 1060.0),
  ),
  'T4|en|roll': _Anchor(
    die: Rect.fromLTRB(502.0, 556.0, 574.0, 628.0),
    board: Rect.fromLTRB(8.0, 112.0, 1068.0, 540.0),
    banner: Rect.fromLTRB(36.0, 72.0, 1004.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 568.0, 56.0, 616.0),
    notice: null,
  ),
  'T4|en|queue': _Anchor(
    die: Rect.fromLTRB(418.0, 556.0, 490.0, 628.0),
    board: Rect.fromLTRB(8.0, 112.0, 1068.0, 540.0),
    banner: Rect.fromLTRB(36.0, 72.0, 1004.0, 92.0),
    tray: Rect.fromLTRB(498.0, 568.0, 658.0, 616.0),
    hint: Rect.fromLTRB(8.0, 568.0, 56.0, 616.0),
    notice: null,
  ),
  'T4|en|nomove': _Anchor(
    die: Rect.fromLTRB(502.0, 556.0, 574.0, 628.0),
    board: Rect.fromLTRB(8.0, 112.0, 1068.0, 540.0),
    banner: Rect.fromLTRB(36.0, 72.0, 1004.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 568.0, 56.0, 616.0),
    notice: Rect.fromLTRB(8.0, 636.0, 1068.0, 656.0),
  ),
  'T4|ar|roll': _Anchor(
    die: Rect.fromLTRB(502.0, 556.0, 574.0, 628.0),
    board: Rect.fromLTRB(8.0, 112.0, 1068.0, 540.0),
    banner: Rect.fromLTRB(72.0, 72.0, 1040.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(1020.0, 568.0, 1068.0, 616.0),
    notice: null,
  ),
  'T4|ar|queue': _Anchor(
    die: Rect.fromLTRB(586.0, 556.0, 658.0, 628.0),
    board: Rect.fromLTRB(8.0, 112.0, 1068.0, 540.0),
    banner: Rect.fromLTRB(72.0, 72.0, 1040.0, 92.0),
    tray: Rect.fromLTRB(418.0, 568.0, 578.0, 616.0),
    hint: Rect.fromLTRB(1020.0, 568.0, 1068.0, 616.0),
    notice: null,
  ),
  'T4|ar|nomove': _Anchor(
    die: Rect.fromLTRB(502.0, 556.0, 574.0, 628.0),
    board: Rect.fromLTRB(8.0, 112.0, 1068.0, 540.0),
    banner: Rect.fromLTRB(72.0, 72.0, 1040.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(1020.0, 568.0, 1068.0, 616.0),
    notice: Rect.fromLTRB(8.0, 636.0, 1068.0, 656.0),
  ),
  'P1|en|roll': _Anchor(
    die: Rect.fromLTRB(144.0, 664.0, 216.0, 736.0),
    board: Rect.fromLTRB(8.0, 112.0, 352.0, 648.0),
    banner: Rect.fromLTRB(36.0, 72.0, 288.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 676.0, 56.0, 724.0),
    notice: null,
  ),
  'P1|en|queue': _Anchor(
    die: Rect.fromLTRB(64.0, 664.0, 136.0, 736.0),
    board: Rect.fromLTRB(8.0, 112.0, 352.0, 648.0),
    banner: Rect.fromLTRB(36.0, 72.0, 288.0, 92.0),
    tray: Rect.fromLTRB(144.0, 676.0, 304.0, 724.0),
    hint: Rect.fromLTRB(8.0, 676.0, 56.0, 724.0),
    notice: null,
  ),
  'P1|en|nomove': _Anchor(
    die: Rect.fromLTRB(144.0, 664.0, 216.0, 736.0),
    board: Rect.fromLTRB(8.0, 112.0, 352.0, 648.0),
    banner: Rect.fromLTRB(36.0, 72.0, 288.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 676.0, 56.0, 724.0),
    notice: Rect.fromLTRB(8.0, 744.0, 352.0, 764.0),
  ),
  'P1|ar|roll': _Anchor(
    die: Rect.fromLTRB(144.0, 664.0, 216.0, 736.0),
    board: Rect.fromLTRB(8.0, 112.0, 352.0, 648.0),
    banner: Rect.fromLTRB(72.0, 72.0, 324.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(304.0, 676.0, 352.0, 724.0),
    notice: null,
  ),
  'P1|ar|queue': _Anchor(
    die: Rect.fromLTRB(224.0, 664.0, 296.0, 736.0),
    board: Rect.fromLTRB(8.0, 112.0, 352.0, 648.0),
    banner: Rect.fromLTRB(72.0, 72.0, 324.0, 92.0),
    tray: Rect.fromLTRB(56.0, 676.0, 216.0, 724.0),
    hint: Rect.fromLTRB(304.0, 676.0, 352.0, 724.0),
    notice: null,
  ),
  'P1|ar|nomove': _Anchor(
    die: Rect.fromLTRB(144.0, 664.0, 216.0, 736.0),
    board: Rect.fromLTRB(8.0, 112.0, 352.0, 648.0),
    banner: Rect.fromLTRB(72.0, 72.0, 324.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(304.0, 676.0, 352.0, 724.0),
    notice: Rect.fromLTRB(8.0, 744.0, 352.0, 764.0),
  ),
  'P2|en|roll': _Anchor(
    die: Rect.fromLTRB(170.0, 799.0, 242.0, 871.0),
    board: Rect.fromLTRB(8.0, 112.0, 404.0, 783.0),
    banner: Rect.fromLTRB(36.0, 72.0, 340.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 811.0, 56.0, 859.0),
    notice: null,
  ),
  'P2|en|queue': _Anchor(
    die: Rect.fromLTRB(86.0, 799.0, 158.0, 871.0),
    board: Rect.fromLTRB(8.0, 112.0, 404.0, 783.0),
    banner: Rect.fromLTRB(36.0, 72.0, 340.0, 92.0),
    tray: Rect.fromLTRB(166.0, 811.0, 326.0, 859.0),
    hint: Rect.fromLTRB(8.0, 811.0, 56.0, 859.0),
    notice: null,
  ),
  'P2|en|nomove': _Anchor(
    die: Rect.fromLTRB(170.0, 799.0, 242.0, 871.0),
    board: Rect.fromLTRB(8.0, 112.0, 404.0, 783.0),
    banner: Rect.fromLTRB(36.0, 72.0, 340.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 811.0, 56.0, 859.0),
    notice: Rect.fromLTRB(8.0, 879.0, 404.0, 899.0),
  ),
  'P2|ar|roll': _Anchor(
    die: Rect.fromLTRB(170.0, 799.0, 242.0, 871.0),
    board: Rect.fromLTRB(8.0, 112.0, 404.0, 783.0),
    banner: Rect.fromLTRB(72.0, 72.0, 376.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(356.0, 811.0, 404.0, 859.0),
    notice: null,
  ),
  'P2|ar|queue': _Anchor(
    die: Rect.fromLTRB(254.0, 799.0, 326.0, 871.0),
    board: Rect.fromLTRB(8.0, 112.0, 404.0, 783.0),
    banner: Rect.fromLTRB(72.0, 72.0, 376.0, 92.0),
    tray: Rect.fromLTRB(86.0, 811.0, 246.0, 859.0),
    hint: Rect.fromLTRB(356.0, 811.0, 404.0, 859.0),
    notice: null,
  ),
  'P2|ar|nomove': _Anchor(
    die: Rect.fromLTRB(170.0, 799.0, 242.0, 871.0),
    board: Rect.fromLTRB(8.0, 112.0, 404.0, 783.0),
    banner: Rect.fromLTRB(72.0, 72.0, 376.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(356.0, 811.0, 404.0, 859.0),
    notice: Rect.fromLTRB(8.0, 879.0, 404.0, 899.0),
  ),
  'P3|en|roll': _Anchor(
    die: Rect.fromLTRB(124.0, 452.0, 196.0, 524.0),
    board: Rect.fromLTRB(8.0, 112.0, 312.0, 436.0),
    banner: Rect.fromLTRB(36.0, 72.0, 248.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 464.0, 56.0, 512.0),
    notice: null,
  ),
  'P3|en|queue': _Anchor(
    die: Rect.fromLTRB(64.0, 452.0, 136.0, 524.0),
    board: Rect.fromLTRB(8.0, 112.0, 312.0, 436.0),
    banner: Rect.fromLTRB(36.0, 72.0, 248.0, 92.0),
    tray: Rect.fromLTRB(144.0, 464.0, 304.0, 512.0),
    hint: Rect.fromLTRB(8.0, 464.0, 56.0, 512.0),
    notice: null,
  ),
  'P3|en|nomove': _Anchor(
    die: Rect.fromLTRB(124.0, 452.0, 196.0, 524.0),
    board: Rect.fromLTRB(8.0, 112.0, 312.0, 436.0),
    banner: Rect.fromLTRB(36.0, 72.0, 248.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 464.0, 56.0, 512.0),
    notice: Rect.fromLTRB(8.0, 532.0, 312.0, 552.0),
  ),
  'P3|ar|roll': _Anchor(
    die: Rect.fromLTRB(124.0, 452.0, 196.0, 524.0),
    board: Rect.fromLTRB(8.0, 112.0, 312.0, 436.0),
    banner: Rect.fromLTRB(72.0, 72.0, 284.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(264.0, 464.0, 312.0, 512.0),
    notice: null,
  ),
  'P3|ar|queue': _Anchor(
    die: Rect.fromLTRB(184.0, 452.0, 256.0, 524.0),
    board: Rect.fromLTRB(8.0, 112.0, 312.0, 436.0),
    banner: Rect.fromLTRB(72.0, 72.0, 284.0, 92.0),
    tray: Rect.fromLTRB(16.0, 464.0, 176.0, 512.0),
    hint: Rect.fromLTRB(264.0, 464.0, 312.0, 512.0),
    notice: null,
  ),
  'P3|ar|nomove': _Anchor(
    die: Rect.fromLTRB(124.0, 452.0, 196.0, 524.0),
    board: Rect.fromLTRB(8.0, 112.0, 312.0, 436.0),
    banner: Rect.fromLTRB(72.0, 72.0, 284.0, 92.0),
    tray: null,
    hint: Rect.fromLTRB(264.0, 464.0, 312.0, 512.0),
    notice: Rect.fromLTRB(8.0, 532.0, 312.0, 552.0),
  ),
  'P1i|en|roll': _Anchor(
    die: Rect.fromLTRB(144.0, 640.0, 216.0, 712.0),
    board: Rect.fromLTRB(8.0, 144.0, 352.0, 624.0),
    banner: Rect.fromLTRB(36.0, 104.0, 288.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 652.0, 56.0, 700.0),
    notice: null,
  ),
  'P1i|en|queue': _Anchor(
    die: Rect.fromLTRB(64.0, 640.0, 136.0, 712.0),
    board: Rect.fromLTRB(8.0, 144.0, 352.0, 624.0),
    banner: Rect.fromLTRB(36.0, 104.0, 288.0, 124.0),
    tray: Rect.fromLTRB(144.0, 652.0, 304.0, 700.0),
    hint: Rect.fromLTRB(8.0, 652.0, 56.0, 700.0),
    notice: null,
  ),
  'P1i|en|nomove': _Anchor(
    die: Rect.fromLTRB(144.0, 640.0, 216.0, 712.0),
    board: Rect.fromLTRB(8.0, 144.0, 352.0, 624.0),
    banner: Rect.fromLTRB(36.0, 104.0, 288.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 652.0, 56.0, 700.0),
    notice: Rect.fromLTRB(8.0, 720.0, 352.0, 740.0),
  ),
  'P1i|ar|roll': _Anchor(
    die: Rect.fromLTRB(144.0, 640.0, 216.0, 712.0),
    board: Rect.fromLTRB(8.0, 144.0, 352.0, 624.0),
    banner: Rect.fromLTRB(72.0, 104.0, 324.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(304.0, 652.0, 352.0, 700.0),
    notice: null,
  ),
  'P1i|ar|queue': _Anchor(
    die: Rect.fromLTRB(224.0, 640.0, 296.0, 712.0),
    board: Rect.fromLTRB(8.0, 144.0, 352.0, 624.0),
    banner: Rect.fromLTRB(72.0, 104.0, 324.0, 124.0),
    tray: Rect.fromLTRB(56.0, 652.0, 216.0, 700.0),
    hint: Rect.fromLTRB(304.0, 652.0, 352.0, 700.0),
    notice: null,
  ),
  'P1i|ar|nomove': _Anchor(
    die: Rect.fromLTRB(144.0, 640.0, 216.0, 712.0),
    board: Rect.fromLTRB(8.0, 144.0, 352.0, 624.0),
    banner: Rect.fromLTRB(72.0, 104.0, 324.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(304.0, 652.0, 352.0, 700.0),
    notice: Rect.fromLTRB(8.0, 720.0, 352.0, 740.0),
  ),
  'P2i|en|roll': _Anchor(
    die: Rect.fromLTRB(170.0, 751.0, 242.0, 823.0),
    board: Rect.fromLTRB(8.0, 144.0, 404.0, 735.0),
    banner: Rect.fromLTRB(36.0, 104.0, 340.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 763.0, 56.0, 811.0),
    notice: null,
  ),
  'P2i|en|queue': _Anchor(
    die: Rect.fromLTRB(86.0, 751.0, 158.0, 823.0),
    board: Rect.fromLTRB(8.0, 144.0, 404.0, 735.0),
    banner: Rect.fromLTRB(36.0, 104.0, 340.0, 124.0),
    tray: Rect.fromLTRB(166.0, 763.0, 326.0, 811.0),
    hint: Rect.fromLTRB(8.0, 763.0, 56.0, 811.0),
    notice: null,
  ),
  'P2i|en|nomove': _Anchor(
    die: Rect.fromLTRB(170.0, 751.0, 242.0, 823.0),
    board: Rect.fromLTRB(8.0, 144.0, 404.0, 735.0),
    banner: Rect.fromLTRB(36.0, 104.0, 340.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(8.0, 763.0, 56.0, 811.0),
    notice: Rect.fromLTRB(8.0, 831.0, 404.0, 851.0),
  ),
  'P2i|ar|roll': _Anchor(
    die: Rect.fromLTRB(170.0, 751.0, 242.0, 823.0),
    board: Rect.fromLTRB(8.0, 144.0, 404.0, 735.0),
    banner: Rect.fromLTRB(72.0, 104.0, 376.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(356.0, 763.0, 404.0, 811.0),
    notice: null,
  ),
  'P2i|ar|queue': _Anchor(
    die: Rect.fromLTRB(254.0, 751.0, 326.0, 823.0),
    board: Rect.fromLTRB(8.0, 144.0, 404.0, 735.0),
    banner: Rect.fromLTRB(72.0, 104.0, 376.0, 124.0),
    tray: Rect.fromLTRB(86.0, 763.0, 246.0, 811.0),
    hint: Rect.fromLTRB(356.0, 763.0, 404.0, 811.0),
    notice: null,
  ),
  'P2i|ar|nomove': _Anchor(
    die: Rect.fromLTRB(170.0, 751.0, 242.0, 823.0),
    board: Rect.fromLTRB(8.0, 144.0, 404.0, 735.0),
    banner: Rect.fromLTRB(72.0, 104.0, 376.0, 124.0),
    tray: null,
    hint: Rect.fromLTRB(356.0, 763.0, 404.0, 811.0),
    notice: Rect.fromLTRB(8.0, 831.0, 404.0, 851.0),
  ),
};

// ---------------------------------------------------------------------------
// Checks.
// ---------------------------------------------------------------------------

void _require(
  bool ok, {
  required String rule,
  required String expected,
  required String got,
  required _Size size,
  required Locale locale,
  required _St state,
  double scale = 1.0,
}) {
  if (!ok) {
    fail(
      'C-667t $rule: expected $expected; got $got. '
      '${_scenario(size, locale, state, scale)}',
    );
  }
}

_Anchor _anchorFor(_Size size, Locale locale, _St state) {
  final _Anchor? anchor =
      _baseAnchors['${size.id}|${locale.languageCode}|${state.name}'];
  if (anchor == null) {
    fail(
      'C-667t: no base anchor recorded for ${_caseId(size, locale, state)}; '
      'the table in this file is incomplete.',
    );
  }
  return anchor;
}

bool _sameRect(Rect? a, Rect? b) => a == b;

/// True when [inner] lies inside [outer], to half a logical pixel.
bool _within(Rect inner, Rect outer) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

bool _isEnd(Locale locale) => locale.languageCode == 'ar';

/// The free space beside the painted board on the END side: right of it in
/// English, left of it in Arabic (the app mirrors, doctrine P9).
Rect _sideSpace(_Size size, Locale locale, Rect square) {
  if (_isEnd(locale)) {
    return Rect.fromLTRB(0, 0, square.left, size.height);
  }
  return Rect.fromLTRB(square.right, 0, size.width, size.height);
}

/// D3: a phone is byte-identical to the base. Every measured box is compared
/// exactly, not to a tolerance.
void _expectPhoneUnmoved(
  _Frame f,
  _Anchor base,
  _Size size,
  Locale locale,
  _St state,
) {
  final List<String> moved = <String>[];
  void cmp(String name, Rect? got, Rect? want) {
    if (!_sameRect(got, want)) {
      moved.add('$name base ${_r(want)} now ${_r(got)}');
    }
  }

  cmp('die', f.die, base.die);
  cmp('board', f.board, base.board);
  cmp('square', f.square, base.square);
  cmp('banner', f.banner, base.banner);
  cmp('tray', f.tray, base.tray);
  cmp('hint', f.hint, base.hint);
  cmp('notice', f.notice, base.notice);
  _require(
    moved.isEmpty,
    rule: 'D3 (phones are byte-identical to the base $_baseSha)',
    expected: 'every box equal to the base',
    got: moved.join('; '),
    size: size,
    locale: locale,
    state: state,
  );
}

/// D1: large landscape.
void _expectLandscapeLayout(
  _Frame f,
  _Anchor base,
  _Size size,
  Locale locale,
  _St state,
) {
  void need(bool ok, String rule, String expected, String got) => _require(
    ok,
    rule: rule,
    expected: expected,
    got: '$got; frame: ${f.describe()}',
    size: size,
    locale: locale,
    state: state,
  );

  final Rect side = _sideSpace(size, locale, f.square);
  final String sideName = _isEnd(locale) ? 'left' : 'right';

  need(
    _within(f.die, size.screen),
    'D1 (the die is fully on screen)',
    'die inside ${_r(size.screen)}',
    'die ${_r(f.die)}',
  );
  need(
    _isEnd(locale)
        ? f.die.right <= f.square.left + 0.01
        : f.die.left >= f.square.right - 0.01,
    'D1 (the die sits beside the board on the end side: $sideName in '
        '${locale.languageCode})',
    _isEnd(locale)
        ? 'die.right <= board.left ${f.square.left}'
        : 'die.left >= board.right ${f.square.right}',
    'die ${_r(f.die)}',
  );
  need(
    !f.die.overlaps(f.square),
    'D1 (the die leaves the column)',
    'die not overlapping the board ${_r(f.square)}',
    'die ${_r(f.die)}',
  );
  final double cy = f.die.center.dy;
  need(
    cy >= 0.55 * size.height && cy <= 0.75 * size.height,
    'D1 (the die centre is 55 to 75 percent of the screen height)',
    'die centre y in [${(0.55 * size.height).toStringAsFixed(1)}, '
        '${(0.75 * size.height).toStringAsFixed(1)}]',
    'die centre y ${cy.toStringAsFixed(1)} '
        '(${(100 * cy / size.height).toStringAsFixed(1)} percent)',
  );

  // The band moves as one unit: the tray and the hint bulb, when they are on
  // screen, sit in the same side space as the die and never on the die.
  for (final (String name, Rect? part) in <(String, Rect?)>[
    ('tray', f.tray),
    ('hint', f.hint),
  ]) {
    if (part == null) {
      continue;
    }
    need(
      _within(part, size.screen) &&
          (_isEnd(locale)
              ? part.right <= f.square.left + 0.01
              : part.left >= f.square.right - 0.01),
      'D1 (the $name moves with the die, inside the side space)',
      '$name inside the $sideName side space ${_r(side)}',
      '$name ${_r(part)}',
    );
    need(
      !part.overlaps(f.die),
      'D1 (the $name does not sit on the die)',
      '$name clear of the die',
      '$name ${_r(part)} overlaps die ${_r(f.die)}',
    );
  }

  // Centred in the side space horizontally. The tolerance is 8 percent of the
  // side space, never less than 12 dp: the contract fixes no number.
  final double bandCentre = f.band.center.dx;
  final double tol = math.max(12, 0.08 * side.width);
  need(
    (bandCentre - side.center.dx).abs() <= tol,
    'D1 (the band is centred in the side space horizontally)',
    'band centre x ${side.center.dx.toStringAsFixed(1)} +- '
        '${tol.toStringAsFixed(1)} (side space ${_r(side)})',
    'band centre x ${bandCentre.toStringAsFixed(1)} (band ${_r(f.band)})',
  );

  // The board takes the height the band used to take: it may grow, never
  // shrink.
  need(
    f.board.height >= base.board.height - 0.01 &&
        f.square.height >= base.square.height - 0.01,
    'D1 (the board is at least as tall as on the base $_baseSha)',
    'board height >= ${base.board.height} and painted board >= '
        '${base.square.height}',
    'board height ${f.board.height}, painted board ${f.square.height}',
  );

  // Header and notice stay where they are.
  final Rect? bannerBase = base.banner;
  final Rect? banner = f.banner;
  if (bannerBase != null) {
    need(
      banner != null && (banner.top - bannerBase.top).abs() < 0.01,
      'D1 (the header stays where it is)',
      'header top ${bannerBase.top}',
      'header ${_r(banner)}',
    );
  }
  if (state == _St.nomove) {
    final Rect? notice = f.notice;
    need(
      notice != null &&
          _within(notice, size.screen) &&
          notice.top >= f.square.bottom - 0.01,
      'D1 (the no-move notice stays under the board)',
      'notice on screen, below the board bottom ${f.square.bottom}',
      'notice ${_r(notice)}',
    );
  }
}

/// D1 (round 2): the visible band content is one compact group, the hint
/// beside the die at kSpace2, and that group is centred horizontally in the
/// side space to 1 dp. The group is measured by its own key; the die, the tray,
/// the hint and the no-move mark must all lie inside it and the group must not
/// be wider than they are, so a padded or lopsided box cannot pass.
void _expectGroupCentred(
  WidgetTester tester,
  _Frame f,
  _Size size,
  Locale locale,
  _St state,
) {
  void need(bool ok, String rule, String expected, String got) => _require(
    ok,
    rule: rule,
    expected: expected,
    got: '$got; frame: ${f.describe()}',
    size: size,
    locale: locale,
    state: state,
  );

  final int count = tester.widgetList(find.byKey(_groupKey)).length;
  need(
    count == 1,
    'D1 r2 (one c667-side-band group)',
    'exactly one widget keyed c667-side-band',
    '$count found',
  );
  final Rect group = tester.getRect(find.byKey(_groupKey));
  final Rect side = _sideSpace(size, locale, f.square);
  final double dx = group.center.dx - side.center.dx;
  need(
    dx.abs() <= 1.0,
    'D1 r2 (the group is centred in the side space)',
    'group centre x ${side.center.dx.toStringAsFixed(2)} +- 1.00 (side space '
        '${_r(side)})',
    'group ${_r(group)} centre x ${group.center.dx.toStringAsFixed(2)}, off '
        'by ${dx.toStringAsFixed(2)}',
  );
  need(
    group.left >= side.left - 0.5 && group.right <= side.right + 0.5,
    'D1 r2 (the group lies inside the side space)',
    'group inside ${_r(side)}',
    'group ${_r(group)}',
  );

  Rect content = f.band;
  final Rect? mark = _rectOfOne(tester, _markKey);
  if (mark != null) {
    content = content.expandToInclude(mark);
  }
  need(
    _within(content, group),
    'D1 r2 (the die, tray, hint and mark are inside the group)',
    'content ${_r(content)} inside group ${_r(group)}',
    'group ${_r(group)}',
  );
  need(
    (group.left - content.left).abs() <= 1.0 &&
        (group.right - content.right).abs() <= 1.0,
    'D1 r2 (the group bounds exactly the visible content horizontally)',
    'group left/right equal to the content ${_r(content)} to 1 dp',
    'group ${_r(group)}',
  );

  final Rect? hint = f.hint;
  need(
    hint != null,
    'D1 r2 (the hint bulb is visible)',
    'game-hint-button in the tree',
    'absent',
  );
  final Rect h = hint!;
  need(
    h.top < f.die.bottom && h.bottom > f.die.top,
    'D1 r2 (the hint sits beside the die, on its row)',
    'hint rows overlap the die rows ${f.die.top}..${f.die.bottom}',
    'hint ${_r(h)}',
  );
  // The contract puts the hint beside the die and does not name the side, so
  // the gap is the horizontal air between the two boxes on whichever side.
  final double gap = math.max(h.left - f.die.right, f.die.left - h.right);
  need(
    (gap - kSpace2).abs() <= 0.5,
    'D1 r2 (the hint is kSpace2 from the die, never parked at the board edge)',
    'gap between hint and die $kSpace2',
    'gap ${gap.toStringAsFixed(2)} (hint ${_r(h)}, die ${_r(f.die)})',
  );

  final Rect? tray = f.tray;
  if (tray != null) {
    final double need0 = h.width + kSpace2 + f.die.width + kSpace2 + tray.width;
    final bool wraps = need0 > side.width + 0.01;
    if (wraps) {
      need(
        tray.top >= f.die.bottom - 0.5,
        'D1 r2 (the side space is ${side.width.toStringAsFixed(1)} wide and '
            'the band needs ${need0.toStringAsFixed(1)}: the tray wraps under '
            'the die)',
        'tray.top >= die.bottom ${f.die.bottom}',
        'tray ${_r(tray)}',
      );
    } else {
      need(
        tray.top < f.die.bottom && tray.bottom > f.die.top,
        'D1 r2 (the band fits the side space, ${need0.toStringAsFixed(1)} of '
            '${side.width.toStringAsFixed(1)}: the tray stays on the die row)',
        'tray rows overlap the die rows ${f.die.top}..${f.die.bottom}',
        'tray ${_r(tray)}',
      );
    }
  }
}

/// D2: large portrait.
void _expectPortraitLayout(
  _Frame f,
  _Anchor base,
  _Size size,
  Locale locale,
  _St state,
) {
  void need(bool ok, String rule, String expected, String got) => _require(
    ok,
    rule: rule,
    expected: expected,
    got: '$got; frame: ${f.describe()}',
    size: size,
    locale: locale,
    state: state,
  );

  final double limit = 0.9 * size.height;
  need(
    _within(f.die, size.screen),
    'D2 (the die is fully on screen)',
    'die inside ${_r(size.screen)}',
    'die ${_r(f.die)}',
  );
  need(
    f.die.bottom <= limit + 0.01,
    'D2 (the die bottom is at least 10 percent of the height above the '
        'bottom edge)',
    'die.bottom <= ${limit.toStringAsFixed(2)} (0.9 x ${size.height})',
    'die.bottom ${f.die.bottom} (base $_baseSha had ${base.die.bottom})',
  );
  // The die is never lifted over the board: its centre stays at or below the
  // board's bottom edge plus the base board gap (the base's die top minus the
  // base's board bottom).
  final double gap = base.die.top - base.board.bottom;
  need(
    f.die.center.dy >= f.board.bottom + gap - 0.01,
    'D2 (the die centre is no higher than the board bottom plus the board '
        'gap)',
    'die centre y >= ${(f.board.bottom + gap).toStringAsFixed(2)} '
        '(board bottom ${f.board.bottom} + base gap $gap)',
    'die centre y ${f.die.center.dy}',
  );
  need(
    f.board.height >= _boardFloor - 0.01,
    'D2 (the board keeps its 324 floor, C-402)',
    'board height >= $_boardFloor',
    'board height ${f.board.height}',
  );
  if (base.die.bottom <= limit) {
    // Today's layout already meets D2 at this size: nothing moves.
    final List<String> moved = <String>[];
    if (f.die != base.die) {
      moved.add('die base ${_r(base.die)} now ${_r(f.die)}');
    }
    if (f.board != base.board) {
      moved.add('board base ${_r(base.board)} now ${_r(f.board)}');
    }
    need(
      moved.isEmpty,
      'D2 (nothing moves where the base already meets it)',
      'die and board equal to the base $_baseSha',
      moved.join('; '),
    );
  }
  if (state == _St.nomove) {
    final Rect? notice = f.notice;
    need(
      notice != null &&
          _within(notice, size.screen) &&
          notice.top >= f.die.bottom - 0.01,
      'D2 (the notice stays under the band)',
      'notice on screen, below the die bottom ${f.die.bottom}',
      'notice ${_r(notice)}',
    );
  }
  final Rect? bannerBase = base.banner;
  if (bannerBase != null) {
    need(
      f.banner != null && (f.banner!.top - bannerBase.top).abs() < 0.01,
      'D2 (the header stays where it is)',
      'header top ${bannerBase.top}',
      'header ${_r(f.banner)}',
    );
  }
}

// ---------------------------------------------------------------------------
// The tests. The ugly cases come first: the phones that must not move, the
// out-of-turn tap, the double scale; then the placements.
// ---------------------------------------------------------------------------

void main() {
  setUpAll(_loadAppFonts);

  group('D3 phones are byte-identical to the base', () {
    for (final _Size size in _phones) {
      for (final Locale locale in _locales) {
        for (final _St state in _layoutStates) {
          testWidgets('D3 ${_caseId(size, locale, state)}', (
            WidgetTester tester,
          ) async {
            await _withScreen(tester, size, locale, state, (_Rig rig) async {
              final _Frame f = _measure(tester, _caseId(size, locale, state));
              _expectPhoneUnmoved(
                f,
                _anchorFor(size, locale, state),
                size,
                locale,
                state,
              );
            });
          });
        }
      }
    }
  });

  group('D4 a tap out of turn rolls nothing', () {
    for (final _Size size in _everySize) {
      for (final Locale locale in _locales) {
        testWidgets('D4 out of turn ${_caseId(size, locale, _St.wait)}', (
          WidgetTester tester,
        ) async {
          await _withScreen(tester, size, locale, _St.wait, (_Rig rig) async {
            final _Frame f = _measure(tester, _caseId(size, locale, _St.wait));
            final int before = rig.sentOfType('roll').length;
            await tester.tapAt(f.die.center);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 50));
            final int sent = rig.sentOfType('roll').length - before;
            _require(
              sent == 0,
              rule: 'D4 (the die rolls only when rolling is allowed)',
              expected: 'no roll sent while the other seat is to roll',
              got: '$sent roll frame(s) sent; die ${_r(f.die)}',
              size: size,
              locale: locale,
              state: _St.wait,
            );
          });
        });
      }
    }
  });

  group('D4 the die rolls on a tap and keeps its hit box', () {
    for (final _Size size in _everySize) {
      for (final Locale locale in _locales) {
        testWidgets('D4 tap ${_caseId(size, locale, _St.roll)}', (
          WidgetTester tester,
        ) async {
          await _withScreen(tester, size, locale, _St.roll, (_Rig rig) async {
            final _Frame f = _measure(tester, _caseId(size, locale, _St.roll));
            _require(
              _within(f.die, size.screen),
              rule: 'D4 (the die can be tapped, so it is on screen)',
              expected: 'die inside ${_r(size.screen)}',
              got: 'die ${_r(f.die)}',
              size: size,
              locale: locale,
              state: _St.roll,
            );
            _require(
              f.die.width >= _dieHitFloor && f.die.height >= _dieHitFloor,
              rule: 'D4 (the die hit box is at least 48x48)',
              expected: 'die box >= ${_dieHitFloor}x$_dieHitFloor',
              got: 'die ${_r(f.die)}',
              size: size,
              locale: locale,
              state: _St.roll,
            );
            final int before = rig.sentOfType('roll').length;
            await tester.tapAt(f.die.center);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 50));
            final List<String> rolls = rig.sentOfType('roll');
            _require(
              rolls.length - before == 1,
              rule: 'D4 (tapping the die centre sends roll)',
              expected:
                  'exactly one roll frame after a tap at '
                  '${f.die.center}',
              got:
                  '${rolls.length - before} roll frame(s); '
                  'sent so far: ${rig.transport.sentRaw.map(_typeOf).toList()}',
              size: size,
              locale: locale,
              state: _St.roll,
            );
          });
        });
      }
    }

    for (final _Size size in _everySize) {
      for (final Locale locale in _locales) {
        for (final _St state in <_St>[_St.queue, _St.nomove]) {
          testWidgets('D4 hit box ${_caseId(size, locale, state)}', (
            WidgetTester tester,
          ) async {
            await _withScreen(tester, size, locale, state, (_Rig rig) async {
              final _Frame f = _measure(tester, _caseId(size, locale, state));
              _require(
                f.die.width >= _dieHitFloor &&
                    f.die.height >= _dieHitFloor &&
                    _within(f.die, size.screen),
                rule: 'D4 (the die hit box is at least 48x48 and on screen)',
                expected:
                    'die box >= ${_dieHitFloor}x$_dieHitFloor inside '
                    '${_r(size.screen)}',
                got: 'die ${_r(f.die)}',
                size: size,
                locale: locale,
                state: state,
              );
            });
          });
        }
      }
    }
  });

  group('D4 the die is still announced after the board', () {
    for (final _Size size in _everySize) {
      for (final Locale locale in _locales) {
        for (final _St state in <_St>[_St.roll, _St.queue]) {
          testWidgets('D4 order ${_caseId(size, locale, state)}', (
            WidgetTester tester,
          ) async {
            final SemanticsHandle handle = tester.ensureSemantics();
            await _withScreen(tester, size, locale, state, (_Rig rig) async {
              final _Frame f = _measure(tester, _caseId(size, locale, state));
              final int dieId = tester.getSemantics(find.byKey(_dieKey)).id;
              final List<(SemanticsNode, Rect)> nodes = _semanticsInOrder(
                tester,
              );
              final int dieAt = nodes.indexWhere(
                ((SemanticsNode, Rect) n) => n.$1.id == dieId,
              );
              int lastBoard = -1;
              for (int i = 0; i < nodes.length; i++) {
                final (SemanticsNode node, Rect rect) = nodes[i];
                if (node.id != dieId &&
                    rect.width > 0 &&
                    rect.height > 0 &&
                    _within(rect, f.square)) {
                  lastBoard = i;
                }
              }
              _require(
                dieAt >= 0 && lastBoard >= 0,
                rule: 'D4 (Semantics order: the die is in the tree)',
                expected: 'a die node and at least one node on the board',
                got:
                    'die index $dieAt, last board index $lastBoard of '
                    '${nodes.length} nodes',
                size: size,
                locale: locale,
                state: state,
              );
              _require(
                dieAt > lastBoard,
                rule: 'D4 (the die stays announced after the board)',
                expected:
                    'die semantics index after the last node inside '
                    'the board ${_r(f.square)}',
                got: 'die index $dieAt, last board node index $lastBoard',
                size: size,
                locale: locale,
                state: state,
              );
            });
            handle.dispose();
          });
        }
      }
    }
  });

  group('D1 large landscape: the die band sits beside the board', () {
    for (final _Size size in _landscapeTablets) {
      for (final Locale locale in _locales) {
        for (final _St state in _layoutStates) {
          testWidgets('D1 ${_caseId(size, locale, state)}', (
            WidgetTester tester,
          ) async {
            await _withScreen(tester, size, locale, state, (_Rig rig) async {
              final _Frame f = _measure(tester, _caseId(size, locale, state));
              _expectLandscapeLayout(
                f,
                _anchorFor(size, locale, state),
                size,
                locale,
                state,
              );
            });
          });
        }
      }
    }
  });

  group('D1 r2 the band is one group centred in the side space', () {
    for (final _Size size in _landscapeTablets) {
      for (final Locale locale in _locales) {
        for (final _St state in _layoutStates) {
          testWidgets('D1 centred ${_caseId(size, locale, state)}', (
            WidgetTester tester,
          ) async {
            await _withScreen(tester, size, locale, state, (_Rig rig) async {
              final _Frame f = _measure(tester, _caseId(size, locale, state));
              _expectGroupCentred(tester, f, size, locale, state);
            });
          });
        }
      }
    }
  });

  group('D2 large portrait: the die clears the bottom tenth', () {
    for (final _Size size in _portraitTablets) {
      for (final Locale locale in _locales) {
        for (final _St state in _layoutStates) {
          testWidgets('D2 ${_caseId(size, locale, state)}', (
            WidgetTester tester,
          ) async {
            await _withScreen(tester, size, locale, state, (_Rig rig) async {
              final _Frame f = _measure(tester, _caseId(size, locale, state));
              _expectPortraitLayout(
                f,
                _anchorFor(size, locale, state),
                size,
                locale,
                state,
              );
            });
          });
        }
      }
    }
  });

  group('T2 at text scale 2.0 raises no layout exception', () {
    for (final Locale locale in _locales) {
      for (final _St state in _layoutStates) {
        testWidgets('D1 ${_caseId(_t2, locale, state, 2.0)}', (
          WidgetTester tester,
        ) async {
          final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
          final FlutterExceptionHandler? previous = FlutterError.onError;
          FlutterError.onError = captured.add;
          try {
            await _withScreen(tester, _t2, locale, state, (_Rig rig) async {
              await tester.pump();
              final _Frame f = _measure(
                tester,
                _caseId(_t2, locale, state, 2.0),
              );
              _require(
                _within(f.die, _t2.screen),
                rule: 'D1 (the die stays on screen at text scale 2.0)',
                expected: 'die inside ${_r(_t2.screen)}',
                got: 'die ${_r(f.die)}',
                size: _t2,
                locale: locale,
                state: state,
                scale: 2.0,
              );
            }, scale: 2.0);
          } finally {
            FlutterError.onError = previous;
          }
          final Object? thrown = tester.takeException();
          _require(
            captured.isEmpty && thrown == null,
            rule: 'D1 (no layout exception at text scale 2.0)',
            expected: 'no FlutterError while laying out',
            got:
                '${captured.length} error(s), first: '
                '${captured.isEmpty ? thrown : captured.first.exceptionAsString().split('\n').first}',
            size: _t2,
            locale: locale,
            state: state,
            scale: 2.0,
          );
        });
      }
    }
  });
}
