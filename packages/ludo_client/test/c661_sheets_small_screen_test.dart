// Proofs for contract C-661 (work/ludo/orders/661-sheets-small-screen.md),
// items S1 to S4: every sheet and card the client draws over a screen fits a
// small phone at large system text, and every action on it can be reached and
// tapped. Written from the contract; each surface is opened the way the
// existing test of that surface opens it.
//
// Surfaces (S1), each opened the way the file named after it opens it:
//   leave        the leave confirm sheet           test/c658_leave_confirm_test.dart
//   kick         the host's remove sheet           test/c656_ruleset_screen_test.dart
//   fair hint    the end card's fair-dice sheet    test/c656_ruleset_screen_test.dart (endedGame)
//   quick chat   the twelve lines and the mute row test/quick_chat_sheet_test.dart
//   end card     the finished card and its actions test/c656_ruleset_screen_test.dart (endedGame)
//   update       the update-required view          test/c635_update_required_test.dart (V5.b)
// and two surfaces the grep of lib/ added beyond the contract's list, both
// full-screen cards of GameScreen with actions:
//   conn lost    the "connection lost" card, Reconnect and Leave
//   seat moved   the "seat moved to another phone" card, Leave
//
// Sizes (S2): logical 320 x 568 at system text scale 1.6 and 2.0, 360 x 640 at
// 2.0; en and ar. The scale is the system value (the platform dispatcher's
// text scale factor), the app is not told anything. The real Poppins and Noto
// Sans Arabic faces are loaded, so a line breaks where it breaks on a phone.
//
// Fits (S3): every layout exception raised while a surface is up is collected
// (the framework's error hook is replaced for the length of a case and put
// back) and is named with its overflow in px. Then, per action, the control is
// brought into view with ensureVisible, must be hit-testable at its centre,
// is tapped, and its effect is asserted (the sent envelope, the route
// popped, the callback). Exceptions raised before a surface opens belong to
// the screen under it and get their own case per size and locale ("under").
//
// Unchanged (S3 second half, S4): one control per surface at 360 x 640 and
// text scale 1.0 compares the surface's rectangles with the ones measured on
// the base tree (origin/main f1808d9, before order 661). Those numbers are the
// base's own layout, taken once; a change at normal size shows up as a diff.
//
// Reproduce one case with
//   flutter test test/c661_sheets_small_screen_test.dart --plain-name '<case>'
// There is no seed: each case is a fixed list of frames and taps, and its
// failure names the case, the size, the scale, the locale and the steps taken.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/quick_chat.dart' show showQuickChatSheet;
import 'package:ludo_client/src/theme.dart' show buildAppTheme;
import 'package:ludo_client/src/update_required_view.dart';

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

// --- keys the surfaces already carry -----------------------------------------

const Key _cornerLeaveKey = Key('game-screen-appbar-leave');
const Key _leaveSheetKey = Key('game-leave-confirm');
const Key _leaveStayKey = Key('game-leave-confirm-stay');
const Key _leaveLeaveKey = Key('game-leave-confirm-leave');
const Key _kickWaitKey = Key('kick-sheet-wait');
const Key _kickRemoveKey = Key('kick-sheet-remove');
const Key _fairHintKey = Key('end-card-fair-hint');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _newTableKey = Key('game-screen-new-room-button');
const Key _chatSheetKey = Key('quick-chat-sheet');
const Key _chatMuteKey = Key('quick-chat-mute');
const Key _updateViewKey = Key('update-required-view');
const Key _updateStoreKey = Key('update-required-store-button');
const Key _updateHomeKey = Key('update-required-home-button');
const Key _lostCardKey = Key('game-screen-connection-lost');
const Key _lostReconnectKey = Key('game-screen-reconnect-button');
const Key _lostLeaveKey = Key('game-screen-leave-button');
const Key _openChatKey = Key('c661t-open-chat');

Key _kickSheetKey(int seat) => Key('kick-sheet-$seat');
Key _awayKey(int seat) => Key('board-seat-away-$seat');
Key _chipKey(String id) => Key('quick-chat-$id');

/// The twelve ids of PROTOCOL 25, in the sheet's order. Permanent.
const List<String> _chatIds = <String>[
  'hi',
  'good_luck',
  'your_move',
  'nice',
  'lucky',
  'oops',
  'ha_ha',
  'revenge',
  'coming',
  'back_home',
  'no_way',
  'good_game',
];

const String _marketUrl = 'market://details?id=app.fayad.ludo';
const String _verifyUrl = 'https://c661t.invalid/verify/1';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const String _ruleset = '2026-11';
const String _myName = 'Sam';

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};

// --- S2: the sizes -----------------------------------------------------------

typedef _Size = ({String label, Size size, double scale});

const List<_Size> _sizes = <_Size>[
  (label: '320x568 @1.6', size: Size(320, 568), scale: 1.6),
  (label: '320x568 @2.0', size: Size(320, 568), scale: 2.0),
  (label: '360x640 @2.0', size: Size(360, 640), scale: 2.0),
];

const _Size _normal = (label: '360x640 @1.0', size: Size(360, 640), scale: 1.0);

// --- the base tree's rectangles, for the control cases -----------------------
//
// Measured once on origin/main f1808d9 at 360 x 640, text scale 1.0, real
// fonts, per surface and locale: [the primary action, a second anchor], the
// anchor being the surface's own box, or for the end card its New table
// button, or for the fair-dice sheet its line against the sheet. A surface
// whose entry is missing fails its control and prints what it measured, which
// is how this table was filled.

const Map<String, List<Rect>> _baseline = <String, List<Rect>>{
  'leave sheet|en': <Rect>[
    Rect.fromLTRB(20.00, 516.00, 340.00, 564.00),
    Rect.fromLTRB(0.00, 408.00, 360.00, 640.00),
  ],
  'leave sheet|ar': <Rect>[
    Rect.fromLTRB(20.00, 516.00, 340.00, 564.00),
    Rect.fromLTRB(0.00, 407.00, 360.00, 640.00),
  ],
  'kick sheet|en': <Rect>[
    Rect.fromLTRB(186.00, 568.00, 340.00, 624.00),
    Rect.fromLTRB(0.00, 412.00, 360.00, 640.00),
  ],
  'kick sheet|ar': <Rect>[
    Rect.fromLTRB(20.00, 568.00, 174.00, 624.00),
    Rect.fromLTRB(0.00, 439.00, 360.00, 640.00),
  ],
  'fair hint sheet|en': <Rect>[
    Rect.fromLTRB(20.00, 560.00, 340.00, 620.00),
    Rect.fromLTRB(0.00, 540.00, 360.00, 640.00),
  ],
  'fair hint sheet|ar': <Rect>[
    Rect.fromLTRB(20.00, 580.00, 340.00, 620.00),
    Rect.fromLTRB(0.00, 560.00, 360.00, 640.00),
  ],
  'quick chat sheet|en': <Rect>[
    Rect.fromLTRB(20.00, 184.00, 79.14, 240.00),
    Rect.fromLTRB(0.00, 116.00, 360.00, 640.00),
  ],
  'quick chat sheet|ar': <Rect>[
    Rect.fromLTRB(229.76, 304.00, 340.00, 360.00),
    Rect.fromLTRB(0.00, 235.00, 360.00, 640.00),
  ],
  'end card|en': <Rect>[
    Rect.fromLTRB(16.00, 576.00, 344.00, 624.00),
    Rect.fromLTRB(16.00, 532.00, 344.00, 580.00),
  ],
  'end card|ar': <Rect>[
    Rect.fromLTRB(16.00, 566.00, 344.00, 624.00),
    Rect.fromLTRB(16.00, 533.00, 344.00, 581.00),
  ],
  'update view|en': <Rect>[
    Rect.fromLTRB(40.00, 342.00, 320.00, 390.00),
    Rect.fromLTRB(20.00, 174.00, 340.00, 466.00),
  ],
  'update view|ar': <Rect>[
    Rect.fromLTRB(40.00, 337.50, 320.00, 395.50),
    Rect.fromLTRB(20.00, 168.50, 340.00, 471.50),
  ],
  'connection lost card|en': <Rect>[
    Rect.fromLTRB(116.58, 334.00, 243.42, 382.00),
    Rect.fromLTRB(93.54, 234.00, 266.46, 458.00),
  ],
  'connection lost card|ar': <Rect>[
    Rect.fromLTRB(114.39, 329.50, 245.61, 387.50),
    Rect.fromLTRB(94.39, 228.50, 265.61, 463.50),
  ],
  'seat moved card|en': <Rect>[
    Rect.fromLTRB(136.24, 374.00, 223.76, 422.00),
    Rect.fromLTRB(20.00, 250.00, 340.00, 442.00),
  ],
  'seat moved card|ar': <Rect>[
    Rect.fromLTRB(137.53, 357.50, 222.47, 415.50),
    Rect.fromLTRB(71.54, 256.50, 288.46, 435.50),
  ],
};

// --- wire frames, shaped as PROTOCOL 28 sends them ---------------------------

int _serverIdSeq = 0;

String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c661t-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  required bool connected,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
  'drought': 0,
};

Map<String, Object?> _turnJson(int seat) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': rollTrayDeadlineMs,
  'k': 0,
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

// --- the fonts a phone has ----------------------------------------------------

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
  final FontLoader arabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    arabic.addFont(rootBundle.load(asset));
  }
  await arabic.load();
}

// --- one case ------------------------------------------------------------------

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// "A RenderFlex overflowed by 53 pixels on the bottom." plus the widget the
/// framework blames, or the first line of any other exception.
String _summary(FlutterErrorDetails d) {
  final String text = d.exceptionAsString();
  final RegExpMatch? over = RegExp(
    r'overflowed by ([0-9.]+) pixels on the (\w+)',
  ).firstMatch(text);
  if (over == null) {
    final String line = _oneLine(text.split('\n').first);
    return line.length > 180 ? '${line.substring(0, 180)}...' : line;
  }
  final RegExpMatch? widget = RegExp(r'error-causing widget was:\s*\n\s*(\S+)')
      .firstMatch(text);
  return 'RenderFlex overflow by ${over.group(1)} px on the ${over.group(2)}'
      '${widget == null ? '' : ' (${widget.group(1)})'}';
}

class _Rig {
  _Rig(this.tester, this.name, this.surface, this.locale, this.view) {
    _previous = FlutterError.onError;
    FlutterError.onError = _caught.add;
    tester.view.physicalSize = view.size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = view.scale;
  }

  final WidgetTester tester;
  final String name;
  final String surface;
  final Locale locale;
  final _Size view;
  final List<FlutterErrorDetails> _caught = <FlutterErrorDetails>[];
  final List<String> steps = <String>[];
  final List<String> problems = <String>[];
  late final void Function(FlutterErrorDetails)? _previous;
  int _seen = 0;

  // The game rig, when the surface sits on a GameScreen.
  RollTrayDrive? drive;
  _Connector? connector;
  bool routeReturned = false;
  Object? routeResult;

  // The standalone rigs.
  final List<String> picks = <String>[];
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);
  final List<String> asked = <String>[];
  int homes = 0;

  String get lang => locale.languageCode;

  List<String> sent(String type) => <String>[
    for (final String text in drive!.transport.sentRaw)
      if (frameType(text) == type) text,
  ];

  void step(String what) => steps.add(what);

  void problem(String what) => problems.add(what);

  /// Layout exceptions raised since the last call, set aside by [phase]:
  /// returned when the caller wants them kept apart, else added as problems.
  List<String> takeLayout() {
    final List<String> out = <String>[
      for (final FlutterErrorDetails d in _caught.skip(_seen)) _summary(d),
    ];
    _seen = _caught.length;
    return out;
  }

  final Set<String> _reported = <String>{};

  /// A relayout of the same box raises the same exception again; it is one
  /// problem, named by the first phase that saw it.
  void checkLayout(String phase) {
    for (final String line in takeLayout()) {
      if (_reported.add(line)) {
        problem('$phase: $line');
      }
    }
  }

  Future<void> pump(int ms) async {
    int left = ms;
    while (left > 0) {
      final int stepMs = left < 50 ? left : 50;
      await tester.pump(Duration(milliseconds: stepMs));
      left -= stepMs;
    }
  }

  Rect rectOf(Finder f) => tester.getRect(f.first);

  Rect get screen => Offset.zero & view.size;

  /// Brings [f] into view, requires it hit-testable at its centre, taps it and
  /// lets the route animation run. False when it could not be tapped; the
  /// reason is already recorded.
  Future<bool> tapAction(Finder f, String label, {bool tap = true}) async {
    step('reach $label');
    if (f.evaluate().isEmpty) {
      problem('$label is not on the surface');
      return false;
    }
    await tester.ensureVisible(f.first);
    await tester.pump();
    checkLayout('while reaching $label');
    if (f.hitTestable().evaluate().isEmpty) {
      problem(
        '$label cannot be tapped: its centre is not hit-testable after '
        'ensureVisible (rect ${rectOf(f)}, screen $screen)',
      );
      return false;
    }
    if (!tap) {
      return true;
    }
    step('tap $label');
    await tester.tap(f.first);
    await tester.pump();
    await pump(450);
    checkLayout('after tapping $label');
    return true;
  }

  void expectEffect(bool ok, String expected, String saw) {
    if (!ok) {
      problem('expected $expected; saw $saw');
    }
  }

  /// Pops whatever sheet is up, for a case that must go on after an action
  /// that could not be tapped.
  Future<void> forceClose() async {
    final Finder navigator = find.byType(Navigator);
    if (navigator.evaluate().isNotEmpty) {
      await tester.state<NavigatorState>(navigator.first).maybePop();
      await pump(450);
    }
  }

  String report() =>
      'C-661t "$name" [${view.label}, $lang]: ${problems.length} problem(s):\n'
      '  ${problems.join('\n  ')}\n'
      'Steps: ${steps.join(' > ')}.\n'
      'Fixed frames and taps, no seed: flutter test '
      "test/c661_sheets_small_screen_test.dart --plain-name '$name'";

  void finish() {
    if (problems.isNotEmpty) {
      fail(report());
    }
  }

  void restore() {
    FlutterError.onError = _previous;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

Widget _app(Locale locale, FeedbackService feedback, Widget home) {
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
    builder: (BuildContext context, Widget? child) => FeedbackScope(
      settings: FeedbackSettings.forTest(),
      service: feedback,
      child: child!,
    ),
    home: home,
  );
}

/// Seat 0 (me, the host) of [seats] on [turn], GameScreen pushed as a route
/// over a home page the way Home does, so a screen that leaves its route is
/// seen leaving: copied from test/c658_leave_confirm_test.dart `_open`.
Future<void> _mountGame(
  _Rig r, {
  List<int> seats = const <int>[0, 1, 2],
  Set<int> offline = const <int>{},
  int turnSeat = 1,
}) async {
  final Map<String, Object?> room = <String, Object?>{
    'code': 'K7M2QP',
    'state': 'PLAYING',
    'host_seat': 0,
    'players': seats.length,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
      'ruleset': _ruleset,
    },
    'chain_commit': 'a' * 64,
    'chain_index': 0,
    'game_id': null,
    'client_seeds': null,
    'seats': <Map<String, Object?>>[
      for (final int s in seats)
        _seatJson(
          s,
          name: s == 0 ? _myName : _names[s]!,
          connected: !offline.contains(s),
        ),
    ],
    'turn': _turnJson(turnSeat),
    'winner': null,
    'seq': 1,
    'placings': const <int>[],
    'retired': const <int>[],
  };
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c661t.invalid/ws'),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> future = controller.createRoom(name: _myName, players: 2);
  await r.tester.runAsync(() => pumpEventQueue());
  await r.tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': 0,
      'seat_token': 'tok-0',
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
  r.drive = drive;
  r.connector = connector;
  r.step('mount GameScreen PLAYING seats $seats offline $offline');
  await r.tester.pumpWidget(
    _app(
      r.locale,
      drive.feedback,
      const Scaffold(body: Center(child: Text('c661t-home'))),
    ),
  );
  await r.tester.pump();
  r.tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        MaterialPageRoute<Object?>(
          builder: (BuildContext context) => GameScreen(controller: controller),
        ),
      )
      .then((Object? result) {
        r.routeReturned = true;
        r.routeResult = result;
        // Home retires the controller it owns once the route returns.
        controller.leave();
      });
  await r.tester.pump();
  await r.tester.pump(const Duration(seconds: 1));
}

Future<void> _release(_Rig r) async {
  final RollTrayDrive? drive = r.drive;
  if (drive != null) {
    // A request no one answers (leave_room, emote, resume) holds a 10 s
    // timer: unmount, let it run out on the test clock, then dispose.
    await r.tester.pumpWidget(const SizedBox.shrink());
    await r.tester.pump(const Duration(seconds: 11));
    drive.controller.dispose();
  } else {
    await r.tester.pumpWidget(const SizedBox.shrink());
    await r.tester.pump();
  }
}

/// Mounts [home] alone under the app, with no game behind it.
Future<void> _mountStandalone(_Rig r, Widget home) async {
  r.step('mount ${home.runtimeType} alone');
  await r.tester.pumpWidget(_app(r.locale, RecordingFeedback(), home));
  await r.tester.pump();
  await r.pump(400);
}

// --- the control cases' comparison ---------------------------------------------

String _rects(List<Rect> rects) => <String>[
  for (final Rect r in rects)
    'Rect.fromLTRB(${r.left.toStringAsFixed(2)}, ${r.top.toStringAsFixed(2)}, '
        '${r.right.toStringAsFixed(2)}, ${r.bottom.toStringAsFixed(2)})',
].join(', ');

/// The control: no layout exception, and the surface's rectangles are the
/// base tree's, to 0.01 px.
void _control(_Rig r, List<Rect> measured) {
  r.checkLayout('at normal size');
  final String key = '${r.surface}|${r.lang}';
  final List<Rect>? base = _baseline[key];
  if (base == null) {
    r.problem('no base rectangles for "$key"; measured [${_rects(measured)}]');
    return;
  }
  bool same = base.length == measured.length;
  for (int i = 0; same && i < base.length; i++) {
    final Rect a = base[i];
    final Rect b = measured[i];
    same =
        (a.left - b.left).abs() < 0.01 &&
        (a.top - b.top).abs() < 0.01 &&
        (a.right - b.right).abs() < 0.01 &&
        (a.bottom - b.bottom).abs() < 0.01;
  }
  if (!same) {
    r.problem(
      'layout at 360x640 and scale 1.0 moved: expected [${_rects(base)}] '
      '(primary action, surface), saw [${_rects(measured)}]',
    );
  }
}

// --- the surfaces ----------------------------------------------------------------

typedef _Run = Future<void> Function(_Rig r, {required bool control});

/// The corner Leave, then the sheet.
Future<bool> _openLeave(_Rig r) async {
  r.step('tap the corner leave control');
  if (!await r.tapActionOpen(find.byKey(_cornerLeaveKey), 'corner leave')) {
    return false;
  }
  if (find.byKey(_leaveSheetKey).evaluate().isEmpty) {
    r.problem('the leave confirm did not open after a corner tap');
    return false;
  }
  return true;
}

extension on _Rig {
  /// A tap on the screen under a surface, to open it. A control that cannot
  /// be hit is a problem of the screen under, reported as such.
  Future<bool> tapActionOpen(Finder f, String label) async {
    if (f.evaluate().isEmpty) {
      problem('to open the surface: $label is not on the screen');
      return false;
    }
    await tester.ensureVisible(f.first);
    await tester.pump();
    if (f.hitTestable().evaluate().isEmpty) {
      problem(
        'to open the surface: $label is not hit-testable '
        '(rect ${rectOf(f)}, screen $screen)',
      );
      return false;
    }
    await tester.tap(f.first);
    await tester.pump();
    await pump(450);
    return true;
  }
}

Future<void> _runLeave(_Rig r, {required bool control}) async {
  await _mountGame(r);
  r.takeLayout();
  if (!await _openLeave(r)) {
    return;
  }
  r.checkLayout('opening the sheet');
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_leaveStayKey)),
      r.rectOf(find.byKey(_leaveSheetKey)),
    ]);
    return;
  }
  if (await r.tapAction(find.byKey(_leaveStayKey), 'Keep playing')) {
    r.expectEffect(
      find.byKey(_leaveSheetKey).evaluate().isEmpty &&
          !r.routeReturned &&
          r.sent('leave_room').isEmpty,
      'the sheet closed, the game still on screen, no leave_room',
      'sheet ${find.byKey(_leaveSheetKey).evaluate().isEmpty ? 'closed' : 'open'}'
          ', route returned ${r.routeReturned}, leave_room x${r.sent('leave_room').length}',
    );
  } else {
    await r.forceClose();
  }
  if (!await _openLeave(r)) {
    return;
  }
  if (await r.tapAction(find.byKey(_leaveLeaveKey), 'Leave')) {
    r.expectEffect(
      find.byKey(_leaveSheetKey).evaluate().isEmpty &&
          r.routeReturned &&
          r.sent('leave_room').isNotEmpty,
      'the sheet closed, the game route popped, one leave_room sent',
      'sheet ${find.byKey(_leaveSheetKey).evaluate().isEmpty ? 'closed' : 'open'}'
          ', route returned ${r.routeReturned}, leave_room x${r.sent('leave_room').length}',
    );
  }
}

Future<bool> _openKick(_Rig r) async {
  r.step('tap the away mark of seat 1');
  if (!await r.tapActionOpen(find.byKey(_awayKey(1)), 'away mark of seat 1')) {
    return false;
  }
  if (find.byKey(_kickSheetKey(1)).evaluate().isEmpty) {
    r.problem('the remove sheet did not open after a tap on the away mark');
    return false;
  }
  return true;
}

Future<void> _runKick(_Rig r, {required bool control}) async {
  await _mountGame(r, offline: const <int>{1}, turnSeat: 2);
  r.takeLayout();
  if (!await _openKick(r)) {
    return;
  }
  r.checkLayout('opening the sheet');
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_kickRemoveKey)),
      r.rectOf(find.byKey(_kickSheetKey(1))),
    ]);
    return;
  }
  if (await r.tapAction(find.byKey(_kickWaitKey), 'Wait')) {
    r.expectEffect(
      find.byKey(_kickSheetKey(1)).evaluate().isEmpty && r.sent('kick').isEmpty,
      'the sheet closed and no kick sent',
      'sheet ${find.byKey(_kickSheetKey(1)).evaluate().isEmpty ? 'closed' : 'open'}'
          ', kick x${r.sent('kick').length}',
    );
  } else {
    await r.forceClose();
  }
  if (!await _openKick(r)) {
    return;
  }
  if (await r.tapAction(find.byKey(_kickRemoveKey), 'Remove')) {
    final List<String> kicks = r.sent('kick');
    r.expectEffect(
      find.byKey(_kickSheetKey(1)).evaluate().isEmpty &&
          kicks.length == 1 &&
          frameData(kicks.single)['seat'] == 1,
      'the sheet closed and one kick {"seat": 1} sent',
      'sheet ${find.byKey(_kickSheetKey(1)).evaluate().isEmpty ? 'closed' : 'open'}'
          ', kicks ${kicks.map((String k) => frameData(k)).toList()}',
    );
  }
}

/// A PLAYING table that ends: me, seat 0, last of four. Copied from
/// test/c656_ruleset_screen_test.dart `endedGame`.
Future<void> _mountEnded(_Rig r) async {
  await _mountGame(r, seats: const <int>[0, 1, 2, 3]);
  r.step('game_over placings [1, 2, 3, 0]');
  await r.drive!.push(r.tester, 'game_over', <String, Object?>{
    'winner': 1,
    'verify_url': _verifyUrl,
    'placings': const <int>[1, 2, 3, 0],
    'retired': const <int>[],
  });
  await r.pump(1500);
}

Future<void> _runFairHint(_Rig r, {required bool control}) async {
  await _mountEnded(r);
  r.takeLayout();
  final Finder hint = find.byKey(_fairHintKey);
  if (!await r.tapActionOpen(hint, 'the fair-dice info button')) {
    return;
  }
  r.checkLayout('opening the sheet');
  final Finder sheet = find.byType(BottomSheet);
  if (sheet.evaluate().isEmpty) {
    r.problem(
      'the fair-dice sheet did not open after a tap on the info button',
    );
    return;
  }
  final Finder words = find.descendant(of: sheet, matching: find.byType(Text));
  if (words.evaluate().isEmpty) {
    r.problem('the fair-dice sheet carries no text');
    return;
  }
  if (control) {
    _control(r, <Rect>[r.rectOf(words), r.rectOf(sheet)]);
    return;
  }
  final Rect text = r.rectOf(words);
  final Rect box = r.rectOf(sheet);
  r.step('read the sheet text');
  r.expectEffect(
    r.screen.contains(text.topLeft) &&
        r.screen.contains(text.bottomRight) &&
        box.contains(text.topLeft) &&
        box.contains(text.bottomRight),
    'the whole line inside the sheet and the screen',
    'text $text, sheet $box, screen ${r.screen}',
  );
  // The way out of a sheet with no button is its barrier.
  r.step('tap the barrier');
  await r.tester.tapAt(Offset(r.screen.width / 2, 2));
  await r.tester.pump();
  await r.pump(450);
  r.checkLayout('closing the sheet');
  r.expectEffect(
    find.byType(BottomSheet).evaluate().isEmpty,
    'the sheet closed by a tap on the barrier',
    'still open',
  );
}

List<MethodCall> _listenUrlLaunches(WidgetTester tester) {
  final List<MethodCall> calls = <MethodCall>[];
  Future<Object?> handler(MethodCall call) async {
    calls.add(call);
    return true;
  }

  for (final String name in const <String>[
    'plugins.flutter.io/url_launcher',
    'plugins.flutter.io/url_launcher_linux',
    'plugins.flutter.io/url_launcher_android',
    'plugins.flutter.io/url_launcher_ios',
  ]) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel(name),
      handler,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      ),
    );
  }
  return calls;
}

bool _mentions(Object? value, String needle) {
  if (value is String) {
    return value.contains(needle);
  }
  if (value is Map) {
    return value.values.any((Object? v) => _mentions(v, needle)) ||
        value.keys.any((Object? k) => _mentions(k, needle));
  }
  if (value is Iterable) {
    return value.any((Object? v) => _mentions(v, needle));
  }
  return false;
}

Future<void> _runEndCard(_Rig r, {required bool control}) async {
  final List<MethodCall> launches = _listenUrlLaunches(r.tester);
  await _mountEnded(r);
  r.checkLayout('the finished card');
  if (find.byKey(_rematchKey).evaluate().isEmpty) {
    r.problem('the finished card shows no end-card-rematch');
    return;
  }
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_rematchKey)),
      r.rectOf(find.byKey(_newTableKey)),
    ]);
    return;
  }
  if (await r.tapAction(find.byKey(_verifyKey), 'the verify link')) {
    r.expectEffect(
      launches.any((MethodCall c) => _mentions(c.arguments, 'c661t.invalid')),
      'a launch of $_verifyUrl',
      'launcher calls ${launches.map((MethodCall c) => '${c.method} ${c.arguments}').toList()}',
    );
  }
  // Me last of four: the lose variant offers these three one-tap replies. The
  // first is sent, the others must be reachable (one send starts the cooldown).
  for (final String id in const <String>['good_game', 'revenge', 'lucky']) {
    final Finder chip = find.byKey(Key('end-card-reply-$id'));
    final bool first = id == 'good_game';
    if (await r.tapAction(chip, 'quick reply $id', tap: first) && first) {
      final List<String> emotes = r.sent('emote');
      r.expectEffect(
        emotes.length == 1 && frameData(emotes.single)['emote'] == id,
        'one emote {"emote": "$id"} sent',
        'emotes ${emotes.map(frameData).toList()}',
      );
    }
  }
  if (await r.tapAction(find.byKey(_rematchKey), 'Rematch')) {
    r.expectEffect(
      r.sent('rematch').length == 1,
      'one rematch request sent',
      'rematch x${r.sent('rematch').length}',
    );
  }
  if (await r.tapAction(find.byKey(_newTableKey), 'New table')) {
    r.expectEffect(
      r.routeReturned && r.routeResult == GameScreenResult.newTable,
      'the game route popped with GameScreenResult.newTable',
      'returned ${r.routeReturned}, result ${r.routeResult}',
    );
  }
}

Future<void> _openChat(_Rig r) async {
  r.step('open the quick chat sheet');
  await r.tester.tap(find.byKey(_openChatKey));
  await r.tester.pump();
  await r.pump(450);
}

Future<void> _runQuickChat(_Rig r, {required bool control}) async {
  await _mountStandalone(
    r,
    Scaffold(
      body: Builder(
        builder: (BuildContext context) => Center(
          child: TextButton(
            key: _openChatKey,
            onPressed: () => showQuickChatSheet(
              context,
              onPick: r.picks.add,
              muted: r.muted,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await _openChat(r);
  r.checkLayout('opening the sheet');
  if (find.byKey(_chatSheetKey).evaluate().isEmpty) {
    r.problem('showQuickChatSheet put no quick-chat-sheet on screen');
    return;
  }
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_chipKey('hi'))),
      r.rectOf(find.byKey(_chatSheetKey)),
    ]);
    return;
  }
  for (final String id in _chatIds) {
    if (find.byKey(_chatSheetKey).evaluate().isEmpty) {
      await _openChat(r);
    }
    final int before = r.picks.length;
    if (await r.tapAction(find.byKey(_chipKey(id)), 'chat line $id')) {
      r.expectEffect(
        r.picks.length == before + 1 &&
            r.picks.last == id &&
            find.byKey(_chatSheetKey).evaluate().isEmpty,
        'the sheet closed and onPick called once with "$id"',
        'picks ${r.picks.skip(before).toList()}, sheet '
            '${find.byKey(_chatSheetKey).evaluate().isEmpty ? 'closed' : 'open'}',
      );
    } else {
      await r.forceClose();
    }
  }
  if (find.byKey(_chatSheetKey).evaluate().isEmpty) {
    await _openChat(r);
  }
  if (await r.tapAction(find.byKey(_chatMuteKey), 'the mute switch')) {
    r.expectEffect(
      r.muted.value,
      'the mute switch on after a tap',
      'muted ${r.muted.value}',
    );
  }
}

Future<void> _runUpdate(_Rig r, {required bool control}) async {
  await _mountStandalone(
    r,
    Scaffold(
      body: UpdateRequiredView(
        onHome: () => r.homes += 1,
        launcher: (Uri url) async {
          r.asked.add(url.toString());
          return true;
        },
      ),
    ),
  );
  r.checkLayout('the view');
  if (find.byKey(_updateViewKey).evaluate().isEmpty) {
    r.problem('no update-required-view on screen');
    return;
  }
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_updateStoreKey)),
      r.rectOf(find.byKey(_updateViewKey)),
    ]);
    return;
  }
  if (await r.tapAction(find.byKey(_updateStoreKey), 'Update')) {
    r.expectEffect(
      r.asked.length == 1 && r.asked.single == _marketUrl,
      'one launch of $_marketUrl',
      'asked ${r.asked}',
    );
  }
  if (await r.tapAction(find.byKey(_updateHomeKey), 'Back to home')) {
    r.expectEffect(r.homes == 1, 'onHome called once', 'called ${r.homes}x');
  }
}

Future<void> _runConnLost(_Rig r, {required bool control}) async {
  await _mountGame(r);
  r.takeLayout();
  r.step('the far side closes the socket, no automatic retry');
  final FakeTransport next = FakeTransport();
  r.connector!.enqueue(next);
  r.drive!.transport.endFromFarSide();
  await r.tester.runAsync(() => pumpEventQueue());
  await r.tester.pump();
  await r.pump(450);
  if (find.byKey(_lostCardKey).evaluate().isEmpty) {
    r.problem('no game-screen-connection-lost after the socket closed');
    return;
  }
  r.checkLayout('the card');
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_lostReconnectKey)),
      r.rectOf(find.byKey(_lostCardKey)),
    ]);
    return;
  }
  if (await r.tapAction(find.byKey(_lostReconnectKey), 'Reconnect')) {
    r.expectEffect(
      r.drive!.controller.phase != RoomPhase.failed &&
          r.drive!.controller.phase != RoomPhase.closed,
      'a connection attempt after Reconnect',
      'phase ${r.drive!.controller.phase}',
    );
  }
  if (await r.tapAction(find.byKey(_lostLeaveKey), 'Leave')) {
    r.expectEffect(r.routeReturned, 'the game route popped', 'still mounted');
  }
}

Future<void> _runSeatMoved(_Rig r, {required bool control}) async {
  await _mountGame(r);
  r.takeLayout();
  r.step('error BAD_SEAT_TOKEN, no re');
  r.drive!.transport.pushText(
    _frame('error', <String, Object?>{
      'code': 'BAD_SEAT_TOKEN',
      'message': 'taken over',
    }),
  );
  await r.tester.pump();
  await r.pump(450);
  if (find.byKey(_lostCardKey).evaluate().isEmpty) {
    r.problem('no game-screen-connection-lost after BAD_SEAT_TOKEN');
    return;
  }
  r.checkLayout('the card');
  if (control) {
    _control(r, <Rect>[
      r.rectOf(find.byKey(_lostLeaveKey)),
      r.rectOf(find.byKey(_lostCardKey)),
    ]);
    return;
  }
  if (await r.tapAction(find.byKey(_lostLeaveKey), 'Leave')) {
    r.expectEffect(r.routeReturned, 'the game route popped', 'still mounted');
  }
}

const Map<String, _Run> _surfaces = <String, _Run>{
  'leave sheet': _runLeave,
  'kick sheet': _runKick,
  'fair hint sheet': _runFairHint,
  'quick chat sheet': _runQuickChat,
  'end card': _runEndCard,
  'update view': _runUpdate,
  'connection lost card': _runConnLost,
  'seat moved card': _runSeatMoved,
};

void main() {
  setUpAll(_loadAppFonts);

  for (final MapEntry<String, _Run> surface in _surfaces.entries) {
    for (final Locale locale in const <Locale>[_en, _ar]) {
      for (final _Size view in _sizes) {
        final String name =
            'C-661t S3 ${surface.key} ${view.label} [${locale.languageCode}]';
        testWidgets(name, (WidgetTester tester) async {
          final _Rig r = _Rig(tester, name, surface.key, locale, view);
          try {
            await surface.value(r, control: false);
          } finally {
            await _release(r);
            r.restore();
          }
          r.finish();
        });
      }

      final String control =
          'C-661t S3 control ${surface.key} ${_normal.label} '
          '[${locale.languageCode}]';
      testWidgets(control, (WidgetTester tester) async {
        final _Rig r = _Rig(tester, control, surface.key, locale, _normal);
        try {
          await surface.value(r, control: true);
        } finally {
          await _release(r);
          r.restore();
        }
        r.finish();
      });
    }
  }

  // The screen under the game surfaces: what a GameScreen draws before any
  // surface opens. Kept apart so a surface's red is the surface's own.
  for (final Locale locale in const <Locale>[_en, _ar]) {
    for (final _Size view in _sizes) {
      final String name =
          'C-661t under: GameScreen PLAYING ${view.label} [${locale.languageCode}]';
      testWidgets(name, (WidgetTester tester) async {
        final _Rig r = _Rig(tester, name, 'under', locale, view);
        try {
          await _mountGame(r);
          r.checkLayout('the screen with no surface open');
        } finally {
          await _release(r);
          r.restore();
        }
        r.finish();
      });
    }
  }
}
