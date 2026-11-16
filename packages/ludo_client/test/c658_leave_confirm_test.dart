// Proofs for contract C-658 (work/ludo/orders/658-leave-confirm-2026-11.md),
// items L1 to L4: what the leave confirm sheet tells a player leaving a game.
// Written from the contract and docs/PROTOCOL.md section 28 alone.
//
// A real GameScreen over a real RoomController on FakeTransport, every state a
// decoded wire frame shaped as section 28 sends it. Nothing is mocked but the
// socket and the feedback service.
//
// The new l10n keys do not exist when this file is written, so every string is
// asserted as the literal visible text of the contract (and, for the existing
// body, of lib/l10n/app_en.arb and app_ar.arb), never through an
// AppLocalizations getter. The file compiles on a tree without the new keys.
//
// Readings this file takes:
//   - The sheet is the widget at `game-leave-confirm`; its words are the
//     `data` of every Text under it, in tree order: title, body, Keep playing,
//     Leave. The body is the second one.
//   - GameScreen's Leave only pops its route; the owner (Home) awaits the push
//     and then calls `controller.leave()`, which is what puts `leave_room` on
//     the wire. The owner is modelled the same way here.
//   - Every wait is a pump of a stated length on the fake clock. There is no
//     seed: each case is a fixed list of frames and its failure line names the
//     case, the locale, the ruleset and every frame pushed so far, which
//     replays it.
//
// Reproduce one case with
//   flutter test test/c658_leave_confirm_test.dart --plain-name '<case>'

import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'support/roll_tray_harness.dart';

// --- the keys the sheet and the screen already carry -----------------------------

const Key _sheetKey = Key('game-leave-confirm');
const Key _stayKey = Key('game-leave-confirm-stay');
const Key _leaveKey = Key('game-leave-confirm-leave');
const Key _cornerKey = Key('game-screen-appbar-leave');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const String _ruleset = '2026-11';

// --- the strings, verbatim -------------------------------------------------------

/// lib/l10n/app_en.arb and app_ar.arb, the keys this contract leaves alone.
const Map<String, String> _title = <String, String>{
  'en': 'Leave the game?',
  'ar': 'مغادرة اللعبة؟',
};
const Map<String, String> _stay = <String, String>{
  'en': 'Keep playing',
  'ar': 'تابع اللعب',
};
const Map<String, String> _leave = <String, String>{
  'en': 'Leave',
  'ar': 'مغادرة',
};

/// gameLeaveConfirmBody as it is today (L2: byte-identical).
const Map<String, String> _bodyOld = <String, String>{
  'en': 'Your tokens stay on the board and the timer plays your turns.',
  'ar': 'تبقى قطعك على اللوحة ويلعب المؤقت أدوارك.',
};

/// gameLeaveConfirmBodyOut (L1).
const Map<String, String> _bodyOut = <String, String>{
  'en':
      'You will be out of this game for good, and your pieces still in play '
      'leave the board.',
  'ar': 'رح تطلع من هاللعبة نهائياً، وقطعك اللي ما وصلت بتنشال عن اللوحة.',
};

/// gameLeaveConfirmBodyWatching (L3).
const Map<String, String> _bodyWatching = <String, String>{
  'en': 'The game goes on without you.',
  'ar': 'اللعبة بتكمل بلاك.',
};

// --- wire frames, shaped as PROTOCOL 28 sends them -------------------------------

int _serverIdSeq = 0;

String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c658t-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};
const String _myName = 'Sam';

const List<int> _yard = <int>[-1, -1, -1, -1];
const List<int> _home = <int>[57, 57, 57, 57];

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  required List<int> tokens,
  required bool ruleset,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
  'drought': ?(ruleset ? 0 : null),
};

Map<String, Object?> _turnJson(int seat, String phase) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': rollTrayDeadlineMs,
  'k': 0,
};

Map<String, Object?> _movedHome(int seat, int token) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': 52,
  'to': 57,
  'face': 5,
  'captured': <Object?>[],
  'extra_roll': false,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

// --- one mounted table -----------------------------------------------------------

class _G {
  _G(this.tester, this.drive, this.scenario, this.locale, this.ruleset);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;
  final Locale locale;
  final String? ruleset;
  final List<String> frames = <String>[];
  int clockMs = 0;

  /// The owner's view of the route: set when the pushed GameScreen route
  /// returns, as Home awaits it.
  bool routeReturned = false;
  Object? routeResult;

  String get lang => locale.languageCode;

  String why(String expected, [String? observed]) =>
      'C-658t "$scenario" [$lang, ruleset ${ruleset ?? 'absent'}] '
      'at +${clockMs}ms: expected $expected; observed ${observed ?? _seen()}. '
      'Frames pushed in order: ${frames.isEmpty ? '<none>' : frames.join(' -> ')}. '
      'Fixed frames, no seed: replay them on a GameScreen over a RoomController '
      'on FakeTransport (flutter test test/c658_leave_confirm_test.dart '
      "--plain-name '$scenario').";

  String _seen() =>
      'sheet words ${_sheetWords(tester)}, cues ${drive.feedback.recorded}, '
      'sent $sentTypes';

  Future<void> push(String type, Map<String, Object?> data) async {
    final String body = jsonEncode(data);
    frames.add(
      '$type ${body.length > 160 ? '${body.substring(0, 160)}...' : body}',
    );
    await drive.push(tester, type, data);
  }

  Future<void> pump(int ms) async {
    int left = ms;
    while (left > 0) {
      final int step = left < 50 ? left : 50;
      await tester.pump(Duration(milliseconds: step));
      clockMs += step;
      left -= step;
    }
  }

  List<FeedbackCue> get cues => drive.feedback.recorded;

  List<String> get sentTypes => sentTypesSince(drive.transport, 0);

  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String text in drive.transport.sentRaw)
      if (frameType(text) == type) frameData(text),
  ];

  bool get screenMounted => find.byType(GameScreen).evaluate().isNotEmpty;
}

Future<void> _phone(
  WidgetTester tester, {
  double width = 412,
  double height = 892,
}) async {
  tester.view.physicalSize = Size(width * 2.625, height * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Mounts seat [me] of [seats] and pushes GameScreen as a route over a home
/// page, the way Home does: the owner awaits the route and then retires the
/// controller with `leave()`.
Future<_G> _open(
  WidgetTester tester, {
  required String scenario,
  Locale locale = _en,
  List<int> seats = const <int>[0, 1, 2],
  int me = 0,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  String? ruleset = _ruleset,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  Map<String, Object?>? turn,
  String state = 'PLAYING',
  int? winner,
  double width = 412,
  double height = 892,
  double textScale = 1.0,
}) async {
  await _phone(tester, width: width, height: height);
  final bool on = ruleset != null;
  final bool finished = state == 'FINISHED';
  final int firstPlaying = seats.firstWhere(
    (int s) => !placings.contains(s) && !retired.contains(s),
    orElse: () => seats.first,
  );
  final Map<String, Object?> room = <String, Object?>{
    'code': 'K7M2QP',
    'state': state,
    'host_seat': 0,
    'players': seats.length,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
      'ruleset': ?ruleset,
    },
    'chain_commit': 'a' * 64,
    'chain_index': 0,
    'game_id': finished ? 'aaaaaaaaaaaaaaaa' : null,
    'client_seeds': null,
    'seats': <Map<String, Object?>>[
      for (final int s in seats)
        _seatJson(
          s,
          name: s == me ? _myName : _names[s]!,
          tokens: tokens[s] ?? _yard,
          ruleset: on,
        ),
    ],
    'turn': finished ? null : (turn ?? _turnJson(firstPlaying, 'await_roll')),
    'winner': winner,
    'seq': 1,
    'placings': ?(on ? placings : null),
    'retired': ?(on ? retired : null),
    'verify_url': ?(finished ? 'https://c658t.invalid/verify/1' : null),
  };
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c658t.invalid/ws'),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> future = controller.createRoom(name: _myName, players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': me,
      'seat_token': 'tok-$me',
    }),
  );
  transport.pushText(_frame('room', room, re: id));
  await future;
  final RollTrayDrive drive = RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: connector.enqueue,
  );
  final _G g = _G(tester, drive, scenario, locale, ruleset);
  await tester.pumpWidget(_app(drive, locale, textScale));
  await tester.pump();
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        MaterialPageRoute<Object?>(
          builder: (BuildContext context) => GameScreen(controller: controller),
        ),
      )
      .then((Object? result) {
        g.routeReturned = true;
        g.routeResult = result;
        // Home retires the controller it owns once the route returns.
        controller.leave();
      });
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return g;
}

Widget _app(RollTrayDrive drive, Locale locale, double textScale) {
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
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: drive.feedback,
        child: child!,
      ),
    ),
    home: const Scaffold(body: Center(child: Text('c658t-home'))),
  );
}

Future<void> _close(_G g) => releaseGame(g.tester, g.drive);

typedef _Body = Future<void> Function(_G g);

/// One case per locale of [locales]: the table is opened, [body] runs, the
/// screen and the controller are released whatever [body] does.
void _cases(
  String name,
  _Body body, {
  List<Locale> locales = const <Locale>[_en, _ar],
  List<int> seats = const <int>[0, 1, 2],
  int me = 0,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  String? ruleset = _ruleset,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  Map<String, Object?>? turn,
  String state = 'PLAYING',
  int? winner,
  double width = 412,
  double height = 892,
  double textScale = 1.0,
}) {
  for (final Locale locale in locales) {
    testWidgets('C-658t $name [${locale.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: '$name [${locale.languageCode}]',
        locale: locale,
        seats: seats,
        me: me,
        tokens: tokens,
        ruleset: ruleset,
        placings: placings,
        retired: retired,
        turn: turn,
        state: state,
        winner: winner,
        width: width,
        height: height,
        textScale: textScale,
      );
      try {
        await body(g);
      } finally {
        await _close(g);
      }
    });
  }
}

// --- reading the sheet -----------------------------------------------------------

/// The `data` of every Text under the sheet, in tree order.
List<String> _sheetWords(WidgetTester tester) => <String>[
  for (final Element e
      in find
          .descendant(of: find.byKey(_sheetKey), matching: find.byType(Text))
          .evaluate())
    (e.widget as Text).data ?? '<rich>',
];

/// Taps the corner Leave and lets the sheet come in (250 ms), then asserts it
/// is up.
Future<void> _openSheet(_G g) async {
  expect(
    find.byKey(_cornerKey),
    findsOneWidget,
    reason: g.why('the corner leave control ($_cornerKey) on screen'),
  );
  await g.tester.tap(find.byKey(_cornerKey));
  await g.tester.pump();
  await g.pump(300);
  expect(
    find.byKey(_sheetKey),
    findsOneWidget,
    reason: g.why('the leave confirm ($_sheetKey) open after a corner tap'),
  );
}

/// Taps Keep playing and lets the sheet go.
Future<void> _tapStay(_G g) async {
  await g.tester.tap(find.byKey(_stayKey));
  await g.tester.pump();
  await g.pump(400);
  expect(
    find.byKey(_sheetKey),
    findsNothing,
    reason: g.why('the sheet closed after Keep playing'),
  );
}

/// The sheet reads exactly title, [body], Keep playing, Leave, and nothing
/// else, in this locale.
void _expectSheet(_G g, String body, {required String what}) {
  final List<String> expected = <String>[
    _title[g.lang]!,
    body,
    _stay[g.lang]!,
    _leave[g.lang]!,
  ];
  expect(
    _sheetWords(g.tester),
    expected,
    reason: g.why('$what: the sheet to read $expected'),
  );
}

/// Every one of the other two bodies is absent from the whole tree.
void _expectOnlyBody(_G g, String body) {
  for (final String other in <String>[
    _bodyOld[g.lang]!,
    _bodyOut[g.lang]!,
    _bodyWatching[g.lang]!,
  ]) {
    if (other == body) {
      continue;
    }
    expect(
      find.text(other),
      findsNothing,
      reason: g.why('"$other" not on screen while the body is "$body"'),
    );
  }
  expect(
    find.text(body),
    findsOneWidget,
    reason: g.why('exactly one "$body" on screen'),
  );
}

void _expectBody(_G g, String body, {required String what}) {
  _expectSheet(g, body, what: what);
  _expectOnlyBody(g, body);
}

Map<String, Object?> _seatFinished(int seat, int place) => <String, Object?>{
  'seat': seat,
  'place': place,
};

void main() {
  // ===========================================================================
  // The fixture is well formed: the frames this file pushes reach the
  // controller as section 28 describes. Green on any tree; they pin the
  // harness, not the sheet.
  // ===========================================================================

  testWidgets('C-658t frames: seat_finished and seat_retired reach the room '
      'without a resync', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'frames control',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      tokens: const <int, List<int>>{
        1: <int>[57, 57, 57, 52],
      },
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      final RoomController c = g.drive.controller;
      await g.push('moved', _movedHome(1, 3));
      await g.push('seat_finished', _seatFinished(1, 1));
      expect(c.room!.placings, <int>[1], reason: g.why('placings [1]'));
      await g.push('seat_retired', <String, Object?>{
        'seat': 3,
        'reason': 'absent',
        'host_seat': 0,
      });
      expect(c.room!.retired, <int>[3], reason: g.why('retired [3]'));
      expect(c.hasDesynced, isFalse, reason: g.why('no resync'));
      expect(
        c.room!.rules.ruleset,
        _ruleset,
        reason: g.why('rules.ruleset $_ruleset kept from the snapshot'),
      );
    } finally {
      await _close(g);
    }
  });

  // ===========================================================================
  // L1: 2026-11, PLAYING, my seat a playing seat: the "out for good" body.
  // ===========================================================================

  _cases('L1 three seats, nothing special: the out body', (g) async {
    await _openSheet(g);
    _expectBody(g, _bodyOut[g.lang]!, what: 'a playing seat under $_ruleset');
  });

  _cases(
    'L1 two seats, my turn to roll: the out body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'two seats, my turn');
    },
    seats: const <int>[0, 1],
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L1 two seats, the other seat to move: the out body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'two seats, their turn');
    },
    seats: const <int>[0, 1],
    me: 1,
    tokens: const <int, List<int>>{
      0: <int>[10, -1, -1, -1],
      1: <int>[20, 30, -1, -1],
    },
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L1 four seats, a pieces-on-board seat: the out body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'pieces in play');
    },
    seats: const <int>[0, 1, 2, 3],
    me: 2,
    tokens: const <int, List<int>>{
      2: <int>[5, 12, 57, -1],
    },
  );

  _cases(
    'L1 every piece still in the yard: still the out body (the body follows '
    'the seat, not the piece count)',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'an all-yard seat');
    },
    seats: const <int>[0, 1, 2],
    me: 1,
  );

  _cases(
    'L1 another seat already placed: I am still playing, the out body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'another seat finished');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    placings: const <int>[2],
    tokens: const <int, List<int>>{2: _home},
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L1 another seat retired: I am still playing, the out body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'another seat retired');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    retired: const <int>[1],
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L1 one placed and one retired, I am the last playing seat: the out body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'last playing seat');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    placings: const <int>[1],
    retired: const <int>[2],
    tokens: const <int, List<int>>{1: _home},
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L1 the body is the live state: another seat finishes while I play, the '
    'sheet opened afterwards still says out',
    (g) async {
      await g.push('moved', _movedHome(1, 3));
      await g.push('seat_finished', _seatFinished(1, 1));
      await g.push('turn', _turnJson(0, 'await_roll'));
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'after seat 1 finished');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    tokens: const <int, List<int>>{
      1: <int>[57, 57, 57, 52],
    },
    turn: _turnJson(1, 'await_roll'),
  );

  _cases('L1 closed and reopened: the body is the same each time', (g) async {
    await _openSheet(g);
    _expectBody(g, _bodyOut[g.lang]!, what: 'first open');
    await _tapStay(g);
    await _openSheet(g);
    _expectBody(g, _bodyOut[g.lang]!, what: 'second open');
  });

  // ===========================================================================
  // L2: 2026-10 or no ruleset: the existing body, byte for byte.
  // ===========================================================================

  _cases('L2 ruleset 2026-10: the existing body', (g) async {
    await _openSheet(g);
    _expectBody(g, _bodyOld[g.lang]!, what: 'a 2026-10 room');
  }, ruleset: '2026-10');

  _cases('L2 no ruleset in the snapshot: the existing body', (g) async {
    await _openSheet(g);
    _expectBody(g, _bodyOld[g.lang]!, what: 'a room with no rules.ruleset');
  }, ruleset: null);

  _cases(
    'L2 ruleset 2026-10, two seats, pieces on the board: the existing body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOld[g.lang]!, what: 'a 2026-10 room, pieces out');
    },
    ruleset: '2026-10',
    seats: const <int>[0, 1],
    tokens: const <int, List<int>>{
      0: <int>[3, 9, -1, -1],
    },
  );

  _cases(
    'L2 no ruleset, four seats, my seat is not first: the existing body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOld[g.lang]!, what: 'no ruleset, seat 3');
    },
    ruleset: null,
    seats: const <int>[0, 1, 2, 3],
    me: 3,
  );

  // ===========================================================================
  // L3: my seat finished or retired and the game goes on: it changes nothing.
  // ===========================================================================

  _cases(
    'L3 my seat finished (snapshot placings): the watching body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'a finished seat');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    placings: const <int>[0],
    tokens: const <int, List<int>>{0: _home},
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'L3 my seat finished 2nd of four: the watching body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'finished 2nd');
    },
    seats: const <int>[0, 1, 2, 3],
    me: 3,
    placings: const <int>[1, 3],
    tokens: const <int, List<int>>{1: _home, 3: _home},
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L3 my seat retired (snapshot retired): the watching body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'a retired seat');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    retired: const <int>[0],
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'L3 my seat retired among four, another seat also retired: the watching '
    'body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'retired, one more out');
    },
    seats: const <int>[0, 1, 2, 3],
    me: 2,
    retired: const <int>[2, 3],
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L3 my seat retired and another seat placed: the watching body',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'retired with a placing');
    },
    seats: const <int>[0, 1, 2, 3],
    me: 3,
    retired: const <int>[3],
    placings: const <int>[1],
    tokens: const <int, List<int>>{1: _home},
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L3 my seat finishes live: the sheet opened before says out, the sheet '
    'opened after says watching',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'before my last piece is home');
      await _tapStay(g);
      await g.push('moved', _movedHome(0, 3));
      await g.push('seat_finished', _seatFinished(0, 1));
      await g.push('turn', _turnJson(1, 'await_roll'));
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'after my seat_finished');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    tokens: const <int, List<int>>{
      0: <int>[57, 57, 57, 52],
    },
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L3 my seat is retired live (seat_retired naming me): the sheet opened '
    'after says watching',
    (g) async {
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'before seat_retired');
      await _tapStay(g);
      await g.push('seat_retired', <String, Object?>{
        'seat': 0,
        'reason': 'absent',
        'host_seat': 1,
      });
      await g.push('turn', _turnJson(1, 'await_roll'));
      await _openSheet(g);
      _expectBody(g, _bodyWatching[g.lang]!, what: 'after my seat_retired');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'L3 another seat retires live: my sheet stays on the out body',
    (g) async {
      await g.push('seat_retired', <String, Object?>{
        'seat': 2,
        'reason': 'left',
        'host_seat': 0,
      });
      await _openSheet(g);
      _expectBody(g, _bodyOut[g.lang]!, what: 'after seat 2 retired');
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    turn: _turnJson(0, 'await_roll'),
  );

  // ===========================================================================
  // L4: nothing else moves. The title, the two buttons, their keys, the
  // styling, the cues, and what Leave sends.
  // ===========================================================================

  for (final ({String name, String? ruleset, List<int> placings}) v
      in <({String name, String? ruleset, List<int> placings})>[
        (name: 'out body', ruleset: _ruleset, placings: const <int>[]),
        (name: 'old body', ruleset: '2026-10', placings: const <int>[]),
        (name: 'watching body', ruleset: _ruleset, placings: const <int>[0]),
      ]) {
    _cases(
      'L4 the title and both buttons are the same under the ${v.name}',
      (g) async {
        await _openSheet(g);
        final List<String> words = _sheetWords(g.tester);
        expect(
          words.length,
          4,
          reason: g.why('four texts on the sheet: title, body, two buttons'),
        );
        expect(
          words.first,
          _title[g.lang],
          reason: g.why('the title "${_title[g.lang]}"'),
        );
        expect(
          find.descendant(
            of: find.byKey(_stayKey),
            matching: find.text(_stay[g.lang]!),
          ),
          findsOneWidget,
          reason: g.why('"${_stay[g.lang]}" on $_stayKey'),
        );
        expect(
          find.descendant(
            of: find.byKey(_leaveKey),
            matching: find.text(_leave[g.lang]!),
          ),
          findsOneWidget,
          reason: g.why('"${_leave[g.lang]}" on $_leaveKey'),
        );
        expect(
          find.byType(FilledButton),
          findsOneWidget,
          reason: g.why('one filled button on the sheet (Keep playing)'),
        );
        expect(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.byType(FilledButton),
          ),
          findsOneWidget,
          reason: g.why('the filled button is on the sheet'),
        );
        expect(
          find.byKey(_stayKey).evaluate().single.widget,
          isA<FilledButton>(),
          reason: g.why('$_stayKey is the filled (primary) button'),
        );
        expect(
          find.byKey(_leaveKey).evaluate().single.widget,
          isA<TextButton>(),
          reason: g.why('$_leaveKey is the quiet text button'),
        );
        for (final Key k in <Key>[_stayKey, _leaveKey]) {
          expect(
            g.tester.getSize(find.byKey(k)).height,
            greaterThanOrEqualTo(48),
            reason: g.why('$k at least 48 dp tall'),
          );
        }
        final Text title = g.tester.widget<Text>(
          find.descendant(
            of: find.byKey(_sheetKey),
            matching: find.text(_title[g.lang]!),
          ),
        );
        expect(
          title.style,
          Theme.of(g.tester.element(find.byKey(_sheetKey)))
              .textTheme
              .titleMedium,
          reason: g.why('the title in the theme\'s titleMedium'),
        );
        final Text body = g.tester.widget<Text>(
          find
              .descendant(
                of: find.byKey(_sheetKey),
                matching: find.byType(Text),
              )
              .at(1),
        );
        expect(
          body.style,
          isNull,
          reason: g.why(
            'the body carries no style of its own, as before (default text)',
          ),
        );
      },
      ruleset: v.ruleset,
      placings: v.placings,
      tokens: v.placings.isEmpty
          ? const <int, List<int>>{}
          : const <int, List<int>>{0: _home},
      turn: _turnJson(1, 'await_roll'),
    );
  }

  _cases('L4 Keep playing closes the sheet, sends nothing and plays no cue', (
    g,
  ) async {
    final int cuesBefore = g.cues.length;
    final int sentBefore = g.drive.transport.sentRaw.length;
    await _openSheet(g);
    await _tapStay(g);
    expect(
      g.screenMounted,
      isTrue,
      reason: g.why('GameScreen still mounted after Keep playing'),
    );
    expect(
      g.routeReturned,
      isFalse,
      reason: g.why('the route did not return after Keep playing'),
    );
    expect(
      sentTypesSince(g.drive.transport, sentBefore),
      isEmpty,
      reason: g.why('nothing sent by opening and closing the sheet'),
    );
    expect(
      g.cues.skip(cuesBefore),
      isEmpty,
      reason: g.why('no feedback cue for opening and closing the sheet'),
    );
  });

  _cases('L4 a tap outside the sheet closes it and sends nothing', (g) async {
    final int sentBefore = g.drive.transport.sentRaw.length;
    await _openSheet(g);
    await g.tester.tapAt(const Offset(206, 60));
    await g.tester.pump();
    await g.pump(400);
    expect(
      find.byKey(_sheetKey),
      findsNothing,
      reason: g.why('the sheet dismissed by a tap on the barrier'),
    );
    expect(
      g.screenMounted && !g.routeReturned,
      isTrue,
      reason: g.why('GameScreen still up after a barrier tap'),
    );
    expect(
      sentTypesSince(g.drive.transport, sentBefore),
      isEmpty,
      reason: g.why('a barrier tap sends nothing'),
    );
  });

  for (final ({String name, String? ruleset, List<int> placings}) v
      in <({String name, String? ruleset, List<int> placings})>[
        (name: 'out body', ruleset: _ruleset, placings: const <int>[]),
        (name: 'old body', ruleset: '2026-10', placings: const <int>[]),
        (name: 'watching body', ruleset: _ruleset, placings: const <int>[0]),
      ]) {
    _cases(
      'L4 Leave under the ${v.name} pops the route with no result and the '
      'owner then sends exactly one leave_room',
      (g) async {
        await _openSheet(g);
        final int cuesBefore = g.cues.length;
        final int sentBefore = g.drive.transport.sentRaw.length;
        await g.tester.tap(find.byKey(_leaveKey));
        await g.tester.pump();
        await g.pump(600);
        expect(
          g.routeReturned,
          isTrue,
          reason: g.why('the GameScreen route returned after Leave'),
        );
        expect(
          g.routeResult,
          isNull,
          reason: g.why(
            'Leave pops with no result (the new-table result is another path)',
            'result ${g.routeResult}',
          ),
        );
        expect(
          g.screenMounted,
          isFalse,
          reason: g.why('GameScreen gone after Leave'),
        );
        final List<String> after = sentTypesSince(
          g.drive.transport,
          sentBefore,
        );
        expect(after, <String>[
          'leave_room',
        ], reason: g.why('exactly one frame sent after Leave: leave_room'));
        expect(
          g.sent('leave_room').single,
          isEmpty,
          reason: g.why('leave_room carries no data'),
        );
        expect(
          g.cues.skip(cuesBefore),
          isEmpty,
          reason: g.why('no feedback cue for Leave'),
        );
        // The server's answer, so the owner's leave() completes.
        g.drive.lastSeq += 1;
        g.drive.transport.pushText(
          _frame('player_left', <String, Object?>{
            'seat': 0,
            'host_seat': 1,
            'seq': g.drive.lastSeq,
          }, re: requestIdOf(g.drive.transport.sentRaw.last)),
        );
        await g.tester.pump();
        await g.pump(200);
      },
      ruleset: v.ruleset,
      placings: v.placings,
      tokens: v.placings.isEmpty
          ? const <int, List<int>>{}
          : const <int, List<int>>{0: _home},
      turn: _turnJson(1, 'await_roll'),
    );
  }

  _cases(
    'L4 a game that is FINISHED asks nothing: the corner Leave goes straight '
    'out with no sheet',
    (g) async {
      expect(
        find.byKey(_cornerKey),
        findsOneWidget,
        reason: g.why('the corner leave control on the finished board'),
      );
      await g.tester.tap(find.byKey(_cornerKey));
      await g.tester.pump();
      await g.pump(600);
      expect(
        find.byKey(_sheetKey),
        findsNothing,
        reason: g.why('no sheet over a finished game'),
      );
      expect(
        g.routeReturned,
        isTrue,
        reason: g.why('the route returned straight away'),
      );
      g.drive.lastSeq += 1;
      final List<String> leaves = <String>[
        for (final String t in g.drive.transport.sentRaw)
          if (frameType(t) == 'leave_room') t,
      ];
      if (leaves.isNotEmpty) {
        g.drive.transport.pushText(
          _frame('player_left', <String, Object?>{
            'seat': 0,
            'host_seat': 1,
            'seq': g.drive.lastSeq,
          }, re: requestIdOf(leaves.last)),
        );
        await g.tester.pump();
      }
      await g.pump(200);
    },
    state: 'FINISHED',
    winner: 1,
    placings: const <int>[1, 0],
    retired: const <int>[2],
    tokens: const <int, List<int>>{0: _home, 1: _home},
  );

  // ===========================================================================
  // Ugly layouts: the longer bodies must still fit the sheet and leave both
  // buttons reachable.
  // ===========================================================================

  for (final ({String name, String? ruleset, List<int> placings}) v
      in <({String name, String? ruleset, List<int> placings})>[
        (name: 'out body', ruleset: _ruleset, placings: const <int>[]),
        (name: 'old body', ruleset: '2026-10', placings: const <int>[]),
        (name: 'watching body', ruleset: _ruleset, placings: const <int>[0]),
      ]) {
    _cases(
      'L4 a narrow phone at large text: the ${v.name} sheet lays out without '
      'an overflow and both buttons are on screen',
      (g) async {
        await _openSheet(g);
        expect(
          g.tester.takeException(),
          isNull,
          reason: g.why('no layout exception on a 360 x 640 phone at 1.3x'),
        );
        final Size view =
            g.tester.view.physicalSize / g.tester.view.devicePixelRatio;
        for (final Key k in <Key>[_stayKey, _leaveKey]) {
          final Rect r = g.tester.getRect(find.byKey(k));
          expect(
            Offset.zero & view,
            predicate<Rect>(
              (Rect screen) =>
                  screen.contains(r.topLeft) && screen.contains(r.bottomRight),
              'contains $k',
            ),
            reason: g.why('$k inside the $view screen', 'rect $r'),
          );
        }
      },
      ruleset: v.ruleset,
      placings: v.placings,
      tokens: v.placings.isEmpty
          ? const <int, List<int>>{}
          : const <int, List<int>>{0: _home},
      turn: _turnJson(1, 'await_roll'),
      width: 360,
      height: 640,
      textScale: 1.3,
    );
  }
}
