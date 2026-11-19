// Tests for C-679t (order 679, run 158): on a large landscape screen the side
// die group keeps its width when the no-move mark appears and goes, and the
// mark stays clear of the hint control's 48 dp hit box. Written from
// work/ludo/orders/679-tablet-die-group.md and EXPERIENCE.md X208 only.
//
// A real GameScreen over a real RoomController on FakeTransport, mounted the
// way test/c667_tablet_die_test.dart mounts it. Helpers are copied by hand;
// nothing is imported from another test file.
//
// Frames, all on my own turn at T2 (1480x924) and T4 (1076x672), en and ar:
//   before  await_roll, the die waiting for a tap
//   during  a `rolled` with an empty `legal`: the no-move mark is up
//   after   the 1500 ms hold has run out, the mark is gone
// No sleeps: the hold is advanced by pumping fake time past its length, and
// the frame loop waits on the mark leaving the tree, not on a guess.
//
// Failure text names the size, the locale and the frame, which is the whole
// reproduction (there is no seed). Re-run one case with
//   flutter test test/c679_die_group_stable_test.dart --plain-name '<case id>'

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c679-die-group-test.invalid/ws';

const String _mySeatName = 'Karim12345';
const String _otherSeatName = 'Samantha12';

const Key _dieKey = Key('game-die');
const Key _hintKey = Key('game-hint-button');
const Key _markKey = Key('game-die-no-move-mark');
const Key _groupKey = ValueKey<String>('c667-side-band');

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

class _Size {
  const _Size(this.id, this.width, this.height, this.dpr);

  final String id;
  final double width;
  final double height;
  final double dpr;

  Size get logical => Size(width, height);
  Size get physical => Size(width * dpr, height * dpr);
}

const _Size _t2 = _Size('T2', 1480, 924, 2.0);
const _Size _t4 = _Size('T4', 1076, 672, 2.75);
const List<_Size> _sizes = <_Size>[_t2, _t4];

String _caseId(_Size size, Locale locale) =>
    '${size.id} ${locale.languageCode}';

String _scenario(_Size size, Locale locale, String frame) =>
    'scenario: ${size.width.toStringAsFixed(0)}x'
    '${size.height.toStringAsFixed(0)} dp at density ${size.dpr}, locale '
    '${locale.languageCode}, frame $frame; rerun with --plain-name '
    "'${_caseId(size, locale)}'";

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c679-die-group-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

// ---------------------------------------------------------------------------
// Measurement and flow.
// ---------------------------------------------------------------------------

String _r(Rect? rect) {
  if (rect == null) {
    return 'absent';
  }
  return 'L${rect.left.toStringAsFixed(2)} T${rect.top.toStringAsFixed(2)} '
      'R${rect.right.toStringAsFixed(2)} B${rect.bottom.toStringAsFixed(2)} '
      '(${rect.width.toStringAsFixed(2)}x${rect.height.toStringAsFixed(2)})';
}

Rect? _rectOfOne(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  if (tester.widgetList(finder).length != 1) {
    return null;
  }
  return tester.getRect(finder);
}

/// One frame of the side group, logical px, global coordinates.
class _Snap {
  const _Snap({
    required this.name,
    required this.die,
    required this.group,
    required this.hint,
    required this.mark,
  });

  final String name;
  final Rect? die;
  final Rect? group;
  final Rect? hint;
  final Rect? mark;

  String describe() =>
      '$name: die ${_r(die)}; group ${_r(group)}; hint ${_r(hint)}; '
      'mark ${_r(mark)}';
}

_Snap _snap(WidgetTester tester, String name) => _Snap(
  name: name,
  die: _rectOfOne(tester, _dieKey),
  group: _rectOfOne(tester, _groupKey),
  hint: _rectOfOne(tester, _hintKey),
  mark: _rectOfOne(tester, _markKey),
);

class _Frames {
  const _Frames(this.before, this.during, this.after);

  final _Snap before;
  final _Snap during;
  final _Snap after;

  String describe() =>
      '${before.describe()} | ${during.describe()} | ${after.describe()}';
}

/// Mounts my own turn awaiting a roll at [size], takes `before`, lets the
/// no-move `rolled` in and takes `during`, then pumps fake time until the
/// mark has left the tree and takes `after`. Nothing sleeps.
Future<_Frames> _threeFrames(
  WidgetTester tester,
  _Size size,
  Locale locale,
) async {
  tester.view.physicalSize = size.physical;
  tester.view.devicePixelRatio = size.dpr;
  addTearDown(tester.view.reset);
  RoomController? controller;
  try {
    final (RoomController c, FakeTransport transport) = await _connect(
      tester,
      (RoomController made) {
        controller = made;
      },
      seats: _twoSeats(),
      turn: _turnJson(seat: 0, phase: 'await_roll', k: 0),
    );
    controller = c;
    await _mount(tester, c, locale: locale);
    final _Snap before = _snap(tester, 'before');

    final int seq = c.room!.seq + 1;
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
          'seq': seq,
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'turn',
        data: <String, Object?>{
          'seat': 1,
          'deadline_ms': 45000,
          'seq': seq + 1,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final _Snap during = _snap(tester, 'during');

    int spent = 0;
    while (find.byKey(_markKey).evaluate().isNotEmpty && spent < 3000) {
      await tester.pump(const Duration(milliseconds: 100));
      spent += 100;
    }
    if (find.byKey(_markKey).evaluate().isNotEmpty) {
      fail(
        'C-679t: the no-move mark never left the tree in ${spent}ms of fake '
        'time (the hold is 1500 ms). ${_scenario(size, locale, 'after')}',
      );
    }
    await tester.pump();
    final _Snap after = _snap(tester, 'after');
    return _Frames(before, during, after);
  } finally {
    final RoomController? owned = controller;
    if (owned != null) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      owned.dispose();
    }
    tester.view.reset();
  }
}

void _need(
  bool ok,
  String rule,
  String expected,
  String got,
  _Size size,
  Locale locale,
  _Frames frames,
) {
  if (!ok) {
    fail(
      'C-679t $rule: expected $expected; got $got. '
      '${_scenario(size, locale, 'before/during/after')}. '
      'frames: ${frames.describe()}',
    );
  }
}

Rect _present(Rect? rect, String what, _Size size, Locale locale, _Frames f) {
  _need(
    rect != null,
    'precondition',
    '$what in the tree exactly once',
    'absent',
    size,
    locale,
    f,
  );
  return rect!;
}

void main() {
  setUpAll(_loadAppFonts);

  group('X208 the die does not step when the no-move mark comes and goes', () {
    for (final _Size size in _sizes) {
      for (final Locale locale in _locales) {
        testWidgets('die x before, during, after ${_caseId(size, locale)}', (
          WidgetTester tester,
        ) async {
          final _Frames f = await _threeFrames(tester, size, locale);
          final Rect b = _present(f.before.die, 'die before', size, locale, f);
          final Rect d = _present(f.during.die, 'die during', size, locale, f);
          final Rect a = _present(f.after.die, 'die after', size, locale, f);
          _need(
            f.during.mark != null,
            'precondition',
            'the no-move mark up in the during frame',
            'mark absent',
            size,
            locale,
            f,
          );
          final double appear = d.left - b.left;
          final double leave = a.left - d.left;
          _need(
            appear.abs() <= 0.01 && leave.abs() <= 0.01,
            'X208 (the die x is identical before, during and after the mark)',
            'die left ${b.left.toStringAsFixed(2)} in all three frames',
            'die left moved ${appear.toStringAsFixed(2)} dp when the mark '
                'appeared and ${leave.toStringAsFixed(2)} dp when it went '
                '(before ${b.left.toStringAsFixed(2)}, during '
                '${d.left.toStringAsFixed(2)}, after '
                '${a.left.toStringAsFixed(2)})',
            size,
            locale,
            f,
          );
        });

        testWidgets(
          'group width before, during, after ${_caseId(size, locale)}',
          (WidgetTester tester) async {
            final _Frames f = await _threeFrames(tester, size, locale);
            final Rect b = _present(
              f.before.group,
              'group before',
              size,
              locale,
              f,
            );
            final Rect d = _present(
              f.during.group,
              'group during',
              size,
              locale,
              f,
            );
            final Rect a = _present(
              f.after.group,
              'group after',
              size,
              locale,
              f,
            );
            _need(
              (d.width - b.width).abs() <= 0.01 &&
                  (a.width - d.width).abs() <= 0.01 &&
                  (d.left - b.left).abs() <= 0.01 &&
                  (a.left - d.left).abs() <= 0.01,
              'X208 (the c667-side-band group keeps its rect when the mark '
                  'comes and goes)',
              'group ${_r(b)} in all three frames',
              'before ${_r(b)}, during ${_r(d)}, after ${_r(a)}',
              size,
              locale,
              f,
            );
          },
        );

        testWidgets('mark inside the reserved group ${_caseId(size, locale)}', (
          WidgetTester tester,
        ) async {
          final _Frames f = await _threeFrames(tester, size, locale);
          final Rect mark = _present(f.during.mark, 'mark', size, locale, f);
          final Rect before = _present(
            f.before.group,
            'group before',
            size,
            locale,
            f,
          );
          _need(
            mark.left >= before.left - 0.5 && mark.right <= before.right + 0.5,
            'X208 (the mark reach is reserved: the group already holds it '
                'before the mark shows)',
            'mark ${_r(mark)} horizontally inside the before-group '
                '${_r(before)}',
            'mark sticks out of the group by '
                '${math.max(before.left - mark.left, mark.right - before.right).toStringAsFixed(2)} dp',
            size,
            locale,
            f,
          );
        });

        testWidgets('mark clear of hint box ${_caseId(size, locale)}', (
          WidgetTester tester,
        ) async {
          final _Frames f = await _threeFrames(tester, size, locale);
          final Rect mark = _present(f.during.mark, 'mark', size, locale, f);
          final Rect hint = _present(f.during.hint, 'hint', size, locale, f);
          _need(
            hint.width >= 48 && hint.height >= 48,
            'precondition',
            'the hint box at least 48x48',
            'hint ${_r(hint)}',
            size,
            locale,
            f,
          );
          final Rect overlap = mark.intersect(hint);
          final bool hit = overlap.width > 0 && overlap.height > 0;
          _need(
            !hit,
            'X208 (the mark stays clear of the hint 48 dp hit box)',
            'mark ${_r(mark)} and hint box ${_r(hint)} do not intersect',
            'they overlap by ${overlap.width.toStringAsFixed(2)}x'
                '${overlap.height.toStringAsFixed(2)} dp',
            size,
            locale,
            f,
          );
        });
      }
    }
  });
}
