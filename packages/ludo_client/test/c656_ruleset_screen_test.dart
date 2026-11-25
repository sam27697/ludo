// Screen proofs for contract C-656 (work/ludo/orders/656-ruleset-screen.md),
// items S1 to S7: what a player sees of the 2026-11 ruleset. Written from the
// contract and docs/PROTOCOL.md section 28 alone; the screen is built in
// parallel in a tree this file's author has not read.
//
// A real GameScreen over a real RoomController on FakeTransport, every state a
// decoded wire frame shaped as section 28 sends it (release `rolled`,
// `seat_finished`, `seat_retired`, `game_over` with placings and retired, the
// `kick` request and its replies). Nothing is mocked but the socket and the
// feedback service, which is the recording one from the roll-tray harness.
//
// Readings this file takes, each one a place the contract names a thing but
// not how to look at it:
//   - A notice is read off its key. Its words are the plain text of the
//     RichText widgets at or under the key, joined with nothing or with a
//     space, with bidi control characters and runs of blanks removed.
//   - "Gold" is read off pixels: the notice's rectangle holds pixels near
//     LudoColors.gold or LudoColors.goldInk.
//   - A badge or a row label is read off Semantics: a Semantics widget at or
//     under the key with the label, or the merged semantics node of the key
//     carrying it as a line.
//   - A tap target is read off the semantics tree: the smallest node with a
//     tap action around the chip's centre.
//   - A seat's token opacity is the product of every Opacity and fade above
//     its `token-$seat-$i` key, compared with a token of a seat in play.
//   - Every wait is a pump of a stated length on the fake clock. There is no
//     seed: each case is a fixed list of frames and its failure line names
//     the case, the locale and every frame pushed so far, which replays it.
//
// Reproduce one case with
//   flutter test test/c656_ruleset_screen_test.dart --plain-name '<case>'

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show TurnPhase;
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors, buildAppTheme;

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

// --- the contract's keys, verbatim -----------------------------------------------

const Key _releaseNoticeKey = Key('game-release-notice');
const Key _finishedNoticeKey = Key('game-seat-finished-notice');
const Key _retiredNoticeKey = Key('game-seat-retired-notice');
const Key _kickRefusedNoticeKey = Key('game-kick-refused-notice');
const Key _kickRemoveKey = Key('kick-sheet-remove');
const Key _kickWaitKey = Key('kick-sheet-wait');
const Key _bannerKey = Key('game-screen-turn-banner');
const Key _noMoveNoticeKey = Key('game-no-move-notice');
const Key _timerOtherNoticeKey = Key('game-timer-played-other-notice');
const Key _timerMineNoticeKey = Key('game-timer-played-notice');
const Key _newTableKey = Key('game-screen-new-room-button');
const Key _shotKey = Key('c656t-shot');

Key _placeBadgeKey(int seat) => Key('board-seat-place-$seat');
Key _outMarkKey(int seat) => Key('board-seat-out-$seat');
Key _awayKey(int seat) => Key('board-seat-away-$seat');
Key _nameChipKey(int seat) => Key('board-seat-name-$seat');
Key _endPlaceKey(int seat) => Key('end-card-place-$seat');
Key _kickSheetKey(int seat) => Key('kick-sheet-$seat');
Key _tokenKey(int seat, int token) => Key('token-$seat-$token');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

/// Section 28 rule 1: the switch, as the snapshot's `rules.ruleset` says it.
const String _ruleset = '2026-11';

const int _noticeMs = 2500;

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};
const String _myName = 'Sam';

const List<int> _yard = <int>[-1, -1, -1, -1];
const List<int> _home = <int>[57, 57, 57, 57];

/// The contract's ordinals.
const Map<String, List<String>> _ordinals = <String, List<String>>{
  'en': <String>['1st', '2nd', '3rd', '4th'],
  'ar': <String>['الأول', 'الثاني', 'الثالث', 'الرابع'],
};

String _ord(Locale l, int place) => _ordinals[l.languageCode]![place - 1];

// --- wire frames, shaped as PROTOCOL 28 sends them -------------------------------

int _serverIdSeq = 0;

String _frame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c656t-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  required bool connected,
  required List<int> tokens,
  required bool ruleset,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
  'drought': ?(ruleset ? 0 : null),
};

Map<String, Object?> _turnJson(
  int seat,
  String phase, {
  List<int>? queue,
  List<int>? legal,
  bool release = false,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': rollTrayDeadlineMs,
  'k': 0,
  'legal': ?legal,
  'queue': ?queue,
  'release': ?(release ? true : null),
};

/// The `rolled` that grants a release (28.2): `release`, the releasable
/// `legal`, a `queue` holding the drawn face, no `legal_by_face`.
Map<String, Object?> _releaseRolled(
  int seat,
  int value,
  List<int> legal, {
  int k = 1,
  bool byTimer = false,
  List<int>? queue,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'reveal': rollTrayReveal,
  'queue': queue ?? <int>[value],
  'release': true,
  'by': ?(byTimer ? 'timer' : null),
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

Map<String, Object?> _gameOver(
  int winner,
  List<int> placings,
  List<int> retired,
) => <String, Object?>{
  'winner': winner,
  'verify_url': 'https://c656t.invalid/verify/1',
  'placings': placings,
  'retired': retired,
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

/// The controller, the screen, the fake clock and the log that makes a failure
/// reproducible.
class _G {
  _G(this.tester, this.drive, this.scenario, this.locale, this.ruleset);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;
  final Locale locale;
  final String? ruleset;
  final List<String> frames = <String>[];
  int clockMs = 0;

  String why(String expected, [String? observed]) =>
      'C-656t "$scenario" [${locale.languageCode}, ruleset ${ruleset ?? 'absent'}] '
      'at +${clockMs}ms: expected $expected; observed ${observed ?? _seen()}. '
      'Frames pushed in order: ${frames.isEmpty ? '<none>' : frames.join(' -> ')}. '
      'Fixed frames, no seed: replay them on a GameScreen over a RoomController '
      'on FakeTransport (flutter test test/c656_ruleset_screen_test.dart '
      "--plain-name '$scenario').";

  String _seen() {
    final List<String> keys = <String>[
      for (final Key k in <Key>[
        _releaseNoticeKey,
        _finishedNoticeKey,
        _retiredNoticeKey,
        _kickRefusedNoticeKey,
        _noMoveNoticeKey,
        _timerOtherNoticeKey,
        _timerMineNoticeKey,
      ])
        if (find.byKey(k).evaluate().isNotEmpty) (k as ValueKey<String>).value,
    ];
    return 'notices on screen $keys, cues ${drive.feedback.recorded}';
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    final String body = jsonEncode(data);
    frames.add(
      '$type ${body.length > 160 ? '${body.substring(0, 160)}...' : body}',
    );
    await drive.push(tester, type, data);
  }

  /// A server reply to the request [re], carrying the next `seq`.
  Future<void> pushReply(
    String type,
    String re,
    Map<String, Object?> data,
  ) async {
    drive.lastSeq += 1;
    frames.add('$type re=$re ${jsonEncode(data)}');
    drive.transport.pushText(
      _frame(type, <String, Object?>{...data, 'seq': drive.lastSeq}, re: re),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> pushError(String re, String code) async {
    frames.add('error re=$re $code');
    await pushRaw(tester, drive, errorReplyFrame(re: re, code: code));
  }

  /// Pumps [ms] of fake time, 50 ms at a time.
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

  int cueCountOf(FeedbackCue cue) => cueCount(drive.feedback, cue);

  List<String> get sentTypes => sentTypesSince(drive.transport, 0);

  /// The data of every request of [type] this client sent.
  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String text in drive.transport.sentRaw)
      if (frameType(text) == type) frameData(text),
  ];

  /// The id of the latest request of [type] this client sent.
  String lastRequestId(String type) {
    for (final String text in drive.transport.sentRaw.reversed) {
      if (frameType(text) == type) {
        return requestIdOf(text);
      }
    }
    fail(why('a $type request on the wire', 'none sent: $sentTypes'));
  }

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  bool get screenMounted => find.byType(GameScreen).evaluate().isNotEmpty;
}

Future<void> _phone(WidgetTester tester, {double height = 892}) async {
  tester.view.physicalSize = Size(412 * 2.625, height * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// Mounts seat [me] of [seats] on [turn] (default: the first seat in play, to
/// roll) and pushes GameScreen as a route over a home page, so a screen that
/// leaves its route is seen leaving.
Future<_G> _open(
  WidgetTester tester, {
  required String scenario,
  Locale locale = _en,
  List<int> seats = const <int>[0, 1, 2, 3],
  int me = 0,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  Set<int> offline = const <int>{},
  Map<String, Object?>? turn,
  String? ruleset = _ruleset,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  int hostSeat = 0,
  String state = 'PLAYING',
  int? winner,
  double height = 892,
}) async {
  await _phone(tester, height: height);
  final bool on = ruleset != null;
  final bool finished = state == 'FINISHED';
  final int firstPlaying = seats.firstWhere(
    (int s) => !placings.contains(s) && !retired.contains(s),
    orElse: () => seats.first,
  );
  final Map<String, Object?> room = <String, Object?>{
    'code': 'K7M2QP',
    'state': state,
    'host_seat': hostSeat,
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
          connected: !offline.contains(s),
          tokens: tokens[s] ?? _yard,
          ruleset: on,
        ),
    ],
    'turn': finished ? null : (turn ?? _turnJson(firstPlaying, 'await_roll')),
    'winner': winner,
    'seq': 1,
    'placings': ?(on ? placings : null),
    'retired': ?(on ? retired : null),
    'verify_url': ?(finished ? 'https://c656t.invalid/verify/1' : null),
  };
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c656t.invalid/ws'),
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
  await tester.pumpWidget(_app(drive, locale));
  await tester.pump();
  tester
      .state<NavigatorState>(find.byType(Navigator))
      .push(
        MaterialPageRoute<Object?>(
          builder: (BuildContext context) => GameScreen(controller: controller),
        ),
      );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return _G(tester, drive, scenario, locale, ruleset);
}

Widget _app(RollTrayDrive drive, Locale locale) {
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
    builder: (BuildContext context, Widget? child) => RepaintBoundary(
      key: _shotKey,
      child: FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: drive.feedback,
        child: child!,
      ),
    ),
    home: const Scaffold(body: Center(child: Text('c656t-home'))),
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
  List<int> seats = const <int>[0, 1, 2, 3],
  int me = 0,
  Map<int, List<int>> tokens = const <int, List<int>>{},
  Set<int> offline = const <int>{},
  Map<String, Object?>? turn,
  String? ruleset = _ruleset,
  List<int> placings = const <int>[],
  List<int> retired = const <int>[],
  int hostSeat = 0,
  String state = 'PLAYING',
  int? winner,
  double height = 892,
}) {
  for (final Locale locale in locales) {
    testWidgets('C-656t $name [${locale.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: '$name [${locale.languageCode}]',
        locale: locale,
        seats: seats,
        me: me,
        tokens: tokens,
        offline: offline,
        turn: turn,
        ruleset: ruleset,
        placings: placings,
        retired: retired,
        hostSeat: hostSeat,
        state: state,
        winner: winner,
        height: height,
      );
      try {
        await body(g);
      } finally {
        await _close(g);
      }
    });
  }
}

// --- reading the screen ----------------------------------------------------------

final RegExp _bidi = RegExp(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069]');

String _norm(String s) =>
    s.replaceAll(_bidi, '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Every way the plain text under [f] can be read: the RichText widgets at or
/// under it, each alone, joined with nothing and joined with a space.
Set<String> _words(WidgetTester tester, Finder f) {
  final List<String> parts = <String>[
    for (final Element e
        in find
            .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
            .evaluate())
      _norm((e.widget as RichText).text.toPlainText()),
  ];
  return <String>{...parts, _norm(parts.join('')), _norm(parts.join(' '))};
}

void _expectNotice(_G g, Key key, String expected, {required String what}) {
  final Finder f = find.byKey(key);
  expect(
    f,
    findsOneWidget,
    reason: g.why('$what: exactly one ${(key as ValueKey<String>).value}'),
  );
  final Set<String> words = _words(g.tester, f);
  expect(
    words,
    contains(_norm(expected)),
    reason: g.why('$what to read "${_norm(expected)}"', 'the key reads $words'),
  );
}

void _expectNoNotice(_G g, Key key, {required String what}) {
  expect(
    find.byKey(key),
    findsNothing,
    reason: g.why('$what: no ${(key as ValueKey<String>).value}'),
  );
}

String _bannerText(_G g) {
  final Finder f = find.byKey(_bannerKey);
  expect(
    f,
    findsOneWidget,
    reason: g.why('the turn banner (game-screen-turn-banner) on screen'),
  );
  final Set<String> w = _words(g.tester, f);
  return w.isEmpty ? '' : w.first;
}

void _expectBanner(_G g, String expected, {required String what}) {
  final Set<String> w = _words(g.tester, find.byKey(_bannerKey));
  expect(
    w,
    contains(_norm(expected)),
    reason: g.why(
      '$what: the turn banner to read "${_norm(expected)}"',
      'it reads $w',
    ),
  );
}

/// Pumps to just inside the notice's 2500 ms and checks it is up, then past it
/// and checks it is gone.
Future<void> _expectHoldsTwoAndAHalfSeconds(_G g, Key key) async {
  await g.pump(_noticeMs - 100);
  expect(
    find.byKey(key),
    findsOneWidget,
    reason: g.why(
      '${(key as ValueKey<String>).value} still up 100 ms before 2500 ms',
    ),
  );
  await g.pump(300);
  expect(
    find.byKey(key),
    findsNothing,
    reason: g.why('${key.value} gone 200 ms after 2500 ms'),
  );
}

/// Opaque pixels near [colour] inside [rect] (logical px, shot taken at ratio 1).
Future<int> _colourPixels(
  WidgetTester tester,
  Rect rect,
  List<Color> colours, {
  int tolerance = 24,
}) async {
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byKey(_shotKey),
  );
  late ByteData rgba;
  late int width;
  late int height;
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
    width = image.width;
    height = image.height;
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    image.dispose();
    rgba = bytes!;
  });
  int hits = 0;
  final int x0 = rect.left.floor().clamp(0, width);
  final int x1 = rect.right.ceil().clamp(0, width);
  final int y0 = rect.top.floor().clamp(0, height);
  final int y1 = rect.bottom.ceil().clamp(0, height);
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      final int i = (y * width + x) * 4;
      if (rgba.getUint8(i + 3) < 250) {
        continue;
      }
      for (final Color c in colours) {
        if ((rgba.getUint8(i) - (c.r * 255).round()).abs() <= tolerance &&
            (rgba.getUint8(i + 1) - (c.g * 255).round()).abs() <= tolerance &&
            (rgba.getUint8(i + 2) - (c.b * 255).round()).abs() <= tolerance) {
          hits++;
          break;
        }
      }
    }
  }
  return hits;
}

List<Color> get _golds => <Color>[LudoColors.gold, LudoColors.goldInk];

/// The label [label] is on the Semantics at or under [f], or among the lines of
/// its merged semantics node.
bool _hasSemanticsLabel(WidgetTester tester, Finder f, String label) {
  for (final Element e
      in find
          .descendant(of: f, matching: find.byType(Semantics), matchRoot: true)
          .evaluate()) {
    final String? l = (e.widget as Semantics).properties.label;
    if (l != null && _norm(l) == _norm(label)) {
      return true;
    }
  }
  try {
    final String merged = tester.getSemantics(f).label;
    return merged.split('\n').map(_norm).contains(_norm(label)) ||
        _norm(merged) == _norm(label);
  } on StateError {
    return false;
  }
}

double _opacityAbove(WidgetTester tester, Finder f) {
  double o = 1.0;
  RenderObject? r = tester.renderObject(f);
  while (r != null) {
    if (r is RenderOpacity) {
      o *= r.opacity;
    } else if (r is RenderAnimatedOpacity) {
      o *= r.opacity.value;
    }
    r = r.parent;
  }
  return o;
}

/// The size, in dp, of the smallest semantics node with a tap action that
/// contains the centre of [f].
Size? _tapTargetAround(WidgetTester tester, Finder f) {
  final double dpr = tester.view.devicePixelRatio;
  final Offset centre = tester.getCenter(f);
  final SemanticsNode? root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root == null) {
    return null;
  }
  Size? best;
  void walk(SemanticsNode n, Matrix4 parent) {
    final Matrix4 m = parent.clone();
    if (n.transform != null) {
      m.multiply(n.transform!);
    }
    final Rect r = MatrixUtils.transformRect(m, n.rect);
    final Rect logical = Rect.fromLTRB(
      r.left / dpr,
      r.top / dpr,
      r.right / dpr,
      r.bottom / dpr,
    );
    if (n.getSemanticsData().hasAction(SemanticsAction.tap) &&
        logical.contains(centre)) {
      if (best == null ||
          logical.width * logical.height < best!.width * best!.height) {
        best = logical.size;
      }
    }
    n.visitChildren((SemanticsNode c) {
      walk(c, m);
      return true;
    });
  }

  walk(root, Matrix4.identity());
  return best;
}

List<int> _keysWithPrefix(WidgetTester tester, String prefix) {
  final List<int> found = <int>[
    for (final Element e in find.byWidgetPredicate((Widget w) {
      final Key? k = w.key;
      return k is ValueKey<String> && k.value.startsWith(prefix);
    }).evaluate())
      int.parse(
        (e.widget.key! as ValueKey<String>).value.substring(prefix.length),
      ),
  ];
  found.sort();
  return found.toSet().toList();
}

List<int> _ringed(_G g, int seat) => <int>[
  for (int t = 0; t < 4; t++)
    if (g.tester.any(find.byKey(legalRingKey(seat, t)))) t,
];

/// The accessibility announcements, as c590's screen proofs read them.
class _Said {
  final List<String> recorded = <String>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          recorded.add(data['message'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          ),
    );
  }
}

// --- the scenes the cases share --------------------------------------------------

/// A seat's fourth token comes home and the game goes on (28.3): `moved`,
/// `seat_finished`, then `turn` for [next].
Future<void> _finishAndPass(_G g, int seat, int place, int next) async {
  await g.push('moved', _movedHome(seat, 3));
  await g.push('seat_finished', <String, Object?>{
    'seat': seat,
    'place': place,
  });
  await g.push('turn', _turnJson(next, 'await_roll'));
}

String _finishedOther(Locale l, String name, int place) => l == _ar
    ? '$name خلّص ${_ord(l, place)}'
    : '$name finished ${_ord(l, place)}';

String _finishedMine(Locale l, int place) =>
    l == _ar ? 'خلّصت ${_ord(l, place)}!' : 'You finished ${_ord(l, place)}!';

String _watchingBanner(Locale l, int place) => l == _ar
    ? 'خلّصت ${_ord(l, place)}. عم تتفرج عالباقي.'
    : 'You finished ${_ord(l, place)}. Watching the rest.';

String _releaseOther(Locale l, String name) => l == _ar
    ? '$name: ما طلع 6 بعشر رميات. بتطلع قطعة وحدة.'
    : '$name: no 6 in 10 rolls. One piece comes out.';

String _releaseMine(Locale l) => l == _ar
    ? 'ما طلع معك 6 بعشر رميات. طلّع قطعة وحدة.'
    : 'No 6 in 10 rolls. Bring one piece out.';

String _retiredLine(Locale l, String reason, String name) {
  if (l == _ar) {
    return switch (reason) {
      'left' => '$name ترك اللعبة',
      'absent' => '$name غاب دقيقتين وطلع',
      _ => 'المضيف شال $name',
    };
  }
  return switch (reason) {
    'left' => '$name left the game',
    'absent' => '$name was away 2 minutes and is out',
    _ => 'The host removed $name',
  };
}

String _outBanner(Locale l) => l == _ar
    ? 'طلعت من هالجولة. عم تتفرج.'
    : 'You are out of this game. Watching.';

String _outWord(Locale l) => l == _ar ? 'طلع' : 'out';

String _youCame(Locale l, int place) =>
    l == _ar ? 'طلعت ${_ord(l, place)}' : 'You came ${_ord(l, place)}';

String _endedLine(Locale l) =>
    l == _ar ? 'طلعت من هالجولة.' : 'You were out of this game.';

String _kickQuestion(Locale l, String name) =>
    l == _ar ? 'بدك تشيل $name من هاللعبة؟' : 'Remove $name from this game?';

String _removeWord(Locale l) => l == _ar ? 'شيل' : 'Remove';

String _waitWord(Locale l) => l == _ar ? 'استنى' : 'Wait';

String _backLine(Locale l, String name) =>
    l == _ar ? '$name رجع' : '$name is back';

String _couldNot(Locale l, String name) =>
    l == _ar ? 'ما قدرنا نشيل $name' : 'Could not remove $name';

/// A tap on the away chip of [seat], when the screen draws one.
Future<void> _tapAway(_G g, int seat) async {
  if (find.byKey(_awayKey(seat)).evaluate().isNotEmpty) {
    await g.tester.tap(find.byKey(_awayKey(seat)), warnIfMissed: false);
  }
  await g.tester.pump();
  await g.tester.pump(const Duration(milliseconds: 400));
  g.clockMs += 400;
}

/// A tap on the away chip of [seat] that must open its kick sheet.
Future<void> _openKickSheet(_G g, int seat) async {
  await _tapAway(g, seat);
  expect(
    find.byKey(_kickSheetKey(seat)),
    findsOneWidget,
    reason: g.why('kick-sheet-$seat after a tap on board-seat-away-$seat'),
  );
}

void main() {
  // ===========================================================================
  // The frames of this file are well formed: the controller takes each one into
  // the room without a resync. These cases are green on a tree with no screen
  // work; they pin the harness, not the screen.
  // ===========================================================================

  testWidgets('C-656t frames: the sequences this file pushes reach the '
      'controller as section 28 describes, with no resync', (tester) async {
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
      await _finishAndPass(g, 1, 1, 2);
      expect(c.room!.placings, <int>[1], reason: g.why('placings [1]'));
      expect(c.hasDesynced, isFalse, reason: g.why('no resync after a finish'));
      await g.push('seat_retired', <String, Object?>{
        'seat': 3,
        'reason': 'absent',
        'host_seat': 0,
      });
      expect(c.room!.retired, <int>[3], reason: g.why('retired [3]'));
      expect(c.lastRetirement, (seat: 3, reason: 'absent'));
      expect(c.hasDesynced, isFalse, reason: g.why('no resync after a retire'));
      await g.push('rolled', _releaseRolled(2, 4, const <int>[0, 2]));
      expect(
        c.room!.turn!.phase,
        TurnPhase.awaitMove,
        reason: g.why('a release rolled is an await_move turn'),
      );
      expect(c.room!.turn!.release, isTrue, reason: g.why('release true'));
      expect(c.room!.turn!.legal, <int>[0, 2], reason: g.why('legal [0, 2]'));
      await g.push(
        'game_over',
        _gameOver(1, const <int>[1, 2, 0], const <int>[3]),
      );
      expect(c.room!.placings, <int>[1, 2, 0], reason: g.why('placings kept'));
      expect(c.room!.retired, <int>[3], reason: g.why('retired kept'));
      expect(c.hasDesynced, isFalse, reason: g.why('no resync at the end'));
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t readers: the pixel, opacity and tap-target readers this '
      'file uses see what today\'s screen already draws', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _G g = await _open(
      tester,
      scenario: 'readers control',
      seats: const <int>[0, 1, 2],
      me: 0,
      ruleset: null,
      offline: const <int>{1},
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      final int seatBlue = await _colourPixels(
        g.tester,
        g.tester.getRect(find.byKey(_tokenKey(0, 0))),
        <Color>[LudoColors.seats[0]],
      );
      expect(
        seatBlue,
        greaterThan(30),
        reason: g.why('seat 0 colour pixels on its own yard token'),
      );
      final double away = _opacityAbove(g.tester, find.byKey(_nameChipKey(1)));
      final double here = _opacityAbove(g.tester, find.byKey(_nameChipKey(2)));
      expect(
        away / here,
        closeTo(0.6, 0.01),
        reason: g.why('the away chip drawn at 0.6 of a connected one'),
      );
      expect(
        _tapTargetAround(g.tester, find.byKey(bigDieKey)),
        isNotNull,
        reason: g.why('a tap node around my die on my turn to roll'),
      );
    } finally {
      await _close(g);
      handle.dispose();
    }
  });

  testWidgets('C-656t readers: gold pixels are read off the winner title of '
      'today\'s end card', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'gold reader control',
      seats: const <int>[0, 1],
      me: 0,
      ruleset: null,
      height: 1400,
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      await g.push('game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'https://c656t.invalid/verify/1',
      });
      await g.pump(1500);
      final int gold = await _colourPixels(
        g.tester,
        g.tester.getRect(find.byKey(const Key('game-screen-winner'))),
        _golds,
      );
      expect(
        gold,
        greaterThan(8),
        reason: g.why('gold pixels on the winner title', '$gold'),
      );
    } finally {
      await _close(g);
    }
  });

  // ===========================================================================
  // S1: the release
  // ===========================================================================

  // Seat 0 is me with every token in the yard; Bob (seat 1) is to roll.
  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S1 another seat release: notice text, 2500 ms, no cue '
        '[${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S1 other release [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 2,
        turn: _turnJson(1, 'await_roll'),
      );
      try {
        final int mark = g.cues.length;
        await g.push('rolled', _releaseRolled(1, 3, const <int>[0, 1, 2, 3]));
        _expectNotice(
          g,
          _releaseNoticeKey,
          _releaseOther(l, 'Bob'),
          what: 'seat 2 watching seat 1 get a release',
        );
        expect(
          g.cues
              .skip(mark)
              .where(
                (FeedbackCue c) =>
                    c == FeedbackCue.canMove ||
                    c == FeedbackCue.noMove ||
                    c == FeedbackCue.win ||
                    c == FeedbackCue.gameOver ||
                    c == FeedbackCue.invalidTap,
              ),
          isEmpty,
          reason: g.why(
            'no can_move, no_move, win, game_over or invalid_tap for another seat\'s release',
          ),
        );
        await _expectHoldsTwoAndAHalfSeconds(g, _releaseNoticeKey);
      } finally {
        await _close(g);
      }
    });
  }

  // The seat that did not roll still reads the notice with the roller's name,
  // and the roller's own view reads the first-person line.
  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S1 my release: first person text, can_move once, '
        'rings on the releasable yard tokens, die not tappable '
        '[${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S1 my release [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1],
        me: 0,
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        final int mark = g.cues.length;
        await g.push('rolled', _releaseRolled(0, 4, const <int>[1, 3]));
        _expectNotice(
          g,
          _releaseNoticeKey,
          _releaseMine(l),
          what: 'my own release',
        );
        expect(
          g.cues.skip(mark).where((FeedbackCue c) => c == FeedbackCue.canMove),
          hasLength(1),
          reason: g.why('exactly one can_move for my release'),
        );
        expect(
          g.cues
              .skip(mark)
              .where(
                (FeedbackCue c) =>
                    c == FeedbackCue.noMove ||
                    c == FeedbackCue.win ||
                    c == FeedbackCue.gameOver,
              ),
          isEmpty,
          reason: g.why('no no_move, win or game_over for my release'),
        );
        expect(
          _ringed(g, 0),
          <int>[1, 3],
          reason: g.why(
            'the legal ring on exactly my releasable tokens 1 and 3',
            'rings on ${_ringed(g, 0)}',
          ),
        );
        // The die is not tappable while the release is owed.
        final int rollsBefore = g.sent('roll').length;
        await g.tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
        await g.tester.pump();
        expect(
          g.sent('roll').length - rollsBefore,
          0,
          reason: g.why(
            'a tap on my die while the release is owed sends no roll',
          ),
        );
        await _expectHoldsTwoAndAHalfSeconds(g, _releaseNoticeKey);
        expect(
          g.cues.skip(mark).where((FeedbackCue c) => c == FeedbackCue.canMove),
          hasLength(1),
          reason: g.why(
            'still exactly one can_move after the notice has run out',
          ),
        );
      } finally {
        await _close(g);
      }
    });
  }

  testWidgets('C-656t S1 a tap on a ringed yard token sends move with no face; '
      'a tap on a token without a ring sends nothing', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S1 release move',
      seats: const <int>[0, 1],
      me: 0,
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      await g.push('rolled', _releaseRolled(0, 4, const <int>[1, 3]));
      await g.tester.tap(find.byKey(tokenHitKey(0, 0)), warnIfMissed: false);
      await g.tester.pump();
      expect(
        g.sent('move'),
        isEmpty,
        reason: g.why(
          'a tap on token 0, which is not releasable, sends no move',
        ),
      );
      await g.tester.tap(find.byKey(tokenHitKey(0, 3)), warnIfMissed: false);
      await g.tester.pump();
      await g.tester.pump(const Duration(milliseconds: 400));
      final List<Map<String, Object?>> moves = g.sent('move');
      expect(
        moves,
        hasLength(1),
        reason: g.why('exactly one move after a tap on token 3', 'sent $moves'),
      );
      expect(
        moves.single['token'],
        3,
        reason: g.why('the move names token 3', 'sent ${moves.single}'),
      );
      expect(
        moves.single.containsKey('face'),
        isFalse,
        reason: g.why(
          'a release move carries no face (28.2: face present is ILLEGAL_MOVE)',
          'sent ${moves.single}',
        ),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S1 a snapshot that owes a release rings the releasable '
      'tokens and leaves the die alone', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S1 release from snapshot',
      seats: const <int>[0, 1],
      me: 0,
      turn: _turnJson(
        0,
        'await_move',
        legal: const <int>[0, 2],
        queue: const <int>[5],
        release: true,
      ),
    );
    try {
      expect(
        _ringed(g, 0),
        <int>[0, 2],
        reason: g.why(
          'rings on tokens 0 and 2 from a snapshot turn that owes a release',
          'rings on ${_ringed(g, 0)}',
        ),
      );
      await g.tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
      await g.tester.pump();
      expect(
        g.sent('roll'),
        isEmpty,
        reason: g.why('my die does not roll while the release is owed'),
      );
    } finally {
      await _close(g);
    }
  });

  // The lapse goes through the existing no-move path, nothing new.
  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S1 the lapse (legal empty) shows the no-move notice, '
        'plays no_move once and no release notice [${l.languageCode}]', (
      tester,
    ) async {
      final _G g = await _open(
        tester,
        scenario: 'S1 lapse mine [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1],
        me: 0,
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        final int mark = g.cues.length;
        await g.push(
          'rolled',
          _releaseRolled(0, 4, const <int>[], queue: const <int>[]),
        );
        await g.push('turn_passed', <String, Object?>{
          'seat': 0,
          'reason': 'no_legal_move',
        });
        await g.push('turn', _turnJson(1, 'await_roll'));
        _expectNoNotice(g, _releaseNoticeKey, what: 'my lapse');
        expect(
          find.byKey(_noMoveNoticeKey),
          findsOneWidget,
          reason: g.why('the existing no-move notice for my lapse'),
        );
        expect(
          g.cues.skip(mark).where((FeedbackCue c) => c == FeedbackCue.noMove),
          hasLength(1),
          reason: g.why('exactly one no_move cue for my lapse'),
        );
        expect(
          g.cues.skip(mark).where((FeedbackCue c) => c == FeedbackCue.canMove),
          isEmpty,
          reason: g.why('no can_move for a lapse'),
        );
      } finally {
        await _close(g);
      }
    });

    testWidgets('C-656t S1 another seat\'s lapse shows no release notice '
        '[${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S1 lapse other [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 2,
        turn: _turnJson(1, 'await_roll'),
      );
      try {
        await g.push(
          'rolled',
          _releaseRolled(1, 2, const <int>[], queue: const <int>[]),
        );
        await g.push('turn_passed', <String, Object?>{
          'seat': 1,
          'reason': 'no_legal_move',
        });
        await g.push('turn', _turnJson(2, 'await_roll'));
        _expectNoNotice(g, _releaseNoticeKey, what: 'another seat\'s lapse');
      } finally {
        await _close(g);
      }
    });
  }

  // Priority of the below-die slot: above the timer notices, below no-move.
  testWidgets('C-656t S1 slot priority: the release notice beats the timer '
      'notice of another seat', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S1 priority over timer other',
      seats: const <int>[0, 1, 2],
      me: 2,
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await g.push(
        'rolled',
        _releaseRolled(1, 3, const <int>[0, 1, 2, 3], byTimer: true),
      );
      expect(
        find.byKey(_releaseNoticeKey),
        findsOneWidget,
        reason: g.why(
          'the release notice while another seat\'s timer notice is armed',
        ),
      );
      expect(
        find.byKey(_timerOtherNoticeKey),
        findsNothing,
        reason: g.why(
          'the timer-played-other notice yields to the release notice',
        ),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S1 slot priority: the release notice beats my own timer '
      'notice', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S1 priority over timer mine',
      seats: const <int>[0, 1],
      me: 0,
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      await g.push(
        'rolled',
        _releaseRolled(0, 3, const <int>[0, 1, 2, 3], byTimer: true),
      );
      expect(
        find.byKey(_releaseNoticeKey),
        findsOneWidget,
        reason: g.why('the release notice while my own timer notice is armed'),
      );
      expect(
        find.byKey(_timerMineNoticeKey),
        findsNothing,
        reason: g.why('my timer-played notice yields to the release notice'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S1 slot priority: my no-move notice beats a release '
      'notice that is still up', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S1 priority under no-move',
      seats: const <int>[0, 1],
      me: 0,
      turn: _turnJson(1, 'await_roll'),
      tokens: const <int, List<int>>{
        0: <int>[55, 57, 57, 57],
        1: _yard,
      },
    );
    try {
      // Bob's release, his release move and his move of the queued 3, all
      // inside the 2500 ms of the release notice, then my void roll.
      await g.push('rolled', _releaseRolled(1, 3, const <int>[0, 1, 2, 3]));
      expect(
        find.byKey(_releaseNoticeKey),
        findsOneWidget,
        reason: g.why('the release notice up before my roll'),
      );
      await g.push('moved', <String, Object?>{
        'seat': 1,
        'token': 0,
        'from': -1,
        'to': 0,
        'captured': <Object?>[],
        'extra_roll': false,
        'release': true,
      });
      await g.push('turn', <String, Object?>{
        'seat': 1,
        'phase': 'await_move',
        'deadline_ms': rollTrayDeadlineMs,
        'k': 1,
        'value': 3,
        'legal': <int>[0],
        'queue': <int>[3],
        'legal_by_face': <Object?>[
          faceLegal(3, const <int>[0]),
        ],
      });
      await g.push('moved', <String, Object?>{
        'seat': 1,
        'token': 0,
        'from': 0,
        'to': 3,
        'face': 3,
        'captured': <Object?>[],
        'extra_roll': false,
      });
      await g.push('turn', _turnJson(0, 'await_roll'));
      await pushMyNoMoveRoll(g.tester, g.drive, face: 6, k: 2);
      expect(
        find.byKey(_noMoveNoticeKey),
        findsOneWidget,
        reason: g.why('my no-move notice up after my void roll'),
      );
      expect(
        find.byKey(_releaseNoticeKey),
        findsNothing,
        reason: g.why(
          'the release notice sits below the no-move notice in the slot',
        ),
      );
    } finally {
      await _close(g);
    }
  });

  // ===========================================================================
  // S2: places
  // ===========================================================================

  for (final Locale l in <Locale>[_en, _ar]) {
    for (final int place in <int>[1, 2]) {
      testWidgets(
        'C-656t S2 another seat finishes ${_ordinals['en']![place - 1]}: '
        'gold notice, 2500 ms, no cue, badge on its chip '
        '[${l.languageCode}]',
        (tester) async {
          final _G g = await _open(
            tester,
            scenario: 'S2 other finishes $place [${l.languageCode}]',
            locale: l,
            seats: const <int>[0, 1, 2, 3],
            me: 0,
            placings: place == 2 ? const <int>[2] : const <int>[],
            tokens: <int, List<int>>{
              1: const <int>[57, 57, 57, 52],
              if (place == 2) 2: _home,
            },
            turn: _turnJson(1, 'await_roll'),
          );
          try {
            await g.push('moved', _movedHome(1, 3));
            final int mark = g.cues.length;
            await g.push('seat_finished', <String, Object?>{
              'seat': 1,
              'place': place,
            });
            _expectNotice(
              g,
              _finishedNoticeKey,
              _finishedOther(l, 'Bob', place),
              what: 'seat 1 finishing place $place',
            );
            expect(
              g.cues.skip(mark),
              isEmpty,
              reason: g.why(
                'no cue at all for another seat\'s place (the home of its last '
                'token already played)',
              ),
            );
            final Rect box = g.tester.getRect(find.byKey(_finishedNoticeKey));
            final int gold = await _colourPixels(g.tester, box, _golds);
            expect(
              gold,
              greaterThan(8),
              reason: g.why(
                'the finished notice drawn gold (LudoColors.gold or goldInk)',
                'only $gold gold pixels in $box',
              ),
            );
            final Finder badge = find.byKey(_placeBadgeKey(1));
            expect(
              badge,
              findsOneWidget,
              reason: g.why(
                'board-seat-place-1 on the chip of the finished seat',
              ),
            );
            expect(
              _hasSemanticsLabel(g.tester, badge, _ord(l, place)),
              isTrue,
              reason: g.why(
                'the badge says "${_ord(l, place)}" to Semantics',
                'label ${g.tester.getSemantics(badge).label}',
              ),
            );
            expect(
              find.descendant(
                of: badge,
                matching: find.text('$place'),
                matchRoot: true,
              ),
              findsOneWidget,
              reason: g.why('the number $place drawn in the badge disc'),
            );
            final int badgeGold = await _colourPixels(
              g.tester,
              g.tester.getRect(badge),
              _golds,
            );
            expect(
              badgeGold,
              greaterThan(8),
              reason: g.why('the badge disc is gold', '$badgeGold gold pixels'),
            );
            for (final int other in <int>[0, 3]) {
              expect(
                find.byKey(_placeBadgeKey(other)),
                findsNothing,
                reason: g.why(
                  'no place badge on seat $other, which has no place',
                ),
              );
            }
            await _expectHoldsTwoAndAHalfSeconds(g, _finishedNoticeKey);
            expect(
              find.byKey(_placeBadgeKey(1)),
              findsOneWidget,
              reason: g.why('the badge stays after the notice is gone'),
            );
          } finally {
            await _close(g);
          }
        },
      );
    }

    testWidgets('C-656t S2 my seat finishes 1st: "You finished 1st!", win '
        'cue once and nothing else [${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S2 me 1st [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 0,
        tokens: const <int, List<int>>{
          0: <int>[57, 57, 57, 52],
        },
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        await g.push('moved', _movedHome(0, 3));
        final int mark = g.cues.length;
        await g.push('seat_finished', <String, Object?>{'seat': 0, 'place': 1});
        _expectNotice(
          g,
          _finishedNoticeKey,
          _finishedMine(l, 1),
          what: 'my own 1st place',
        );
        expect(g.cues.skip(mark).toList(), <FeedbackCue>[
          FeedbackCue.win,
        ], reason: g.why('exactly [win] for my 1st place'));
        final int gold = await _colourPixels(
          g.tester,
          g.tester.getRect(find.byKey(_finishedNoticeKey)),
          _golds,
        );
        expect(
          gold,
          greaterThan(8),
          reason: g.why('my finished notice drawn gold', '$gold gold pixels'),
        );
        await g.push('turn', _turnJson(1, 'await_roll'));
        expect(
          g.cueCountOf(FeedbackCue.win),
          1,
          reason: g.why('win played once over the whole finish sequence'),
        );
        expect(
          g.cueCountOf(FeedbackCue.gameOver),
          0,
          reason: g.why('no game_over cue: the game goes on'),
        );
      } finally {
        await _close(g);
      }
    });

    testWidgets('C-656t S2 my seat finishes 2nd: "You finished 2nd!" and no '
        'cue [${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S2 me 2nd [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 0,
        placings: const <int>[2],
        tokens: const <int, List<int>>{
          0: <int>[57, 57, 57, 52],
          2: _home,
        },
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        await g.push('moved', _movedHome(0, 3));
        final int mark = g.cues.length;
        await g.push('seat_finished', <String, Object?>{'seat': 0, 'place': 2});
        _expectNotice(
          g,
          _finishedNoticeKey,
          _finishedMine(l, 2),
          what: 'my own 2nd place',
        );
        expect(
          g.cues.skip(mark),
          isEmpty,
          reason: g.why('no cue for a place other than 1st'),
        );
      } finally {
        await _close(g);
      }
    });

    testWidgets('C-656t S2 my seat finished and the game goes on: the banner '
        'says so and my die is not playable [${l.languageCode}]', (
      tester,
    ) async {
      final _G g = await _open(
        tester,
        scenario: 'S2 watching banner [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 0,
        tokens: const <int, List<int>>{
          0: <int>[57, 57, 57, 52],
        },
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        await _finishAndPass(g, 0, 1, 1);
        _expectBanner(g, _watchingBanner(l, 1), what: 'after my 1st place');
        expect(
          find.descendant(
            of: find.byKey(bigDieKey),
            matching: find.byKey(const Key('game-die-pulse')),
          ),
          findsNothing,
          reason: g.why('my die is not drawn as playable (no pulse)'),
        );
        await g.tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
        await g.tester.pump();
        expect(
          g.sent('roll'),
          isEmpty,
          reason: g.why('a tap on my die sends no roll'),
        );
        // The banner survives later turns of the others.
        await g.push('rolled', <String, Object?>{
          'seat': 1,
          'value': 2,
          'legal': <int>[0],
          'deadline_ms': rollTrayDeadlineMs,
          'k': 1,
          'reveal': rollTrayReveal,
          'queue': <int>[2],
          'legal_by_face': <Object?>[
            faceLegal(2, const <int>[0]),
          ],
        });
        _expectBanner(g, _watchingBanner(l, 1), what: 'while seat 1 moves');
      } finally {
        await _close(g);
      }
    });

    testWidgets('C-656t S2 the watching banner is also what a snapshot of a '
        'finished seat shows [${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S2 watching banner from snapshot [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 1,
        placings: const <int>[0, 1],
        tokens: const <int, List<int>>{0: _home, 1: _home},
        turn: _turnJson(2, 'await_roll'),
      );
      try {
        _expectBanner(g, _watchingBanner(l, 2), what: 'resumed as 2nd');
        expect(
          find.byKey(_placeBadgeKey(0)),
          findsOneWidget,
          reason: g.why('badge on seat 0 (1st) from the snapshot placings'),
        );
        expect(
          find.byKey(_placeBadgeKey(1)),
          findsOneWidget,
          reason: g.why('badge on seat 1 (me, 2nd) from the snapshot placings'),
        );
        expect(
          _hasSemanticsLabel(
            g.tester,
            find.byKey(_placeBadgeKey(0)),
            _ord(l, 1),
          ),
          isTrue,
          reason: g.why('seat 0 badge labelled ${_ord(l, 1)}'),
        );
        expect(
          _hasSemanticsLabel(
            g.tester,
            find.byKey(_placeBadgeKey(1)),
            _ord(l, 2),
          ),
          isTrue,
          reason: g.why('seat 1 badge labelled ${_ord(l, 2)}'),
        );
        expect(
          find.byKey(_placeBadgeKey(2)),
          findsNothing,
          reason: g.why('no badge on seat 2, still playing'),
        );
      } finally {
        await _close(g);
      }
    });
  }

  testWidgets('C-656t S2 the ordinals 3rd and 4th on the badges of a snapshot '
      'in both languages', (tester) async {
    for (final Locale l in <Locale>[_en, _ar]) {
      final _G g = await _open(
        tester,
        scenario: 'S2 badges 3 and 4 [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2, 3],
        me: 0,
        placings: const <int>[3, 1, 2],
        tokens: const <int, List<int>>{1: _home, 2: _home, 3: _home},
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        expect(
          _hasSemanticsLabel(
            g.tester,
            find.byKey(_placeBadgeKey(3)),
            _ord(l, 1),
          ),
          isTrue,
          reason: g.why('seat 3 (1st) badge labelled ${_ord(l, 1)}'),
        );
        expect(
          _hasSemanticsLabel(
            g.tester,
            find.byKey(_placeBadgeKey(1)),
            _ord(l, 2),
          ),
          isTrue,
          reason: g.why('seat 1 (2nd) badge labelled ${_ord(l, 2)}'),
        );
        expect(
          _hasSemanticsLabel(
            g.tester,
            find.byKey(_placeBadgeKey(2)),
            _ord(l, 3),
          ),
          isTrue,
          reason: g.why('seat 2 (3rd) badge labelled ${_ord(l, 3)}'),
        );
      } finally {
        await _close(g);
      }
    }
  }, semanticsEnabled: true);

  testWidgets('C-656t S2 place badges carry their semantics when the semantics '
      'tree is on, one per finished seat', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _G g = await _open(
      tester,
      scenario: 'S2 badge semantics tree',
      seats: const <int>[0, 1, 2],
      me: 0,
      placings: const <int>[2],
      tokens: const <int, List<int>>{2: _home},
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      expect(_keysWithPrefix(g.tester, 'board-seat-place-'), <int>[
        2,
      ], reason: g.why('exactly one badge, on seat 2'));
      expect(
        _hasSemanticsLabel(g.tester, find.byKey(_placeBadgeKey(2)), '1st'),
        isTrue,
        reason: g.why('the badge on seat 2 labelled 1st'),
      );
    } finally {
      await _close(g);
      handle.dispose();
    }
  });

  // ===========================================================================
  // S3: who is still playing
  // ===========================================================================

  String youAreNextAfter(Locale l, String name) =>
      l == _ar ? 'أنت التالي بعد $name' : "You're next, after $name";

  for (final Locale l in <Locale>[_en, _ar]) {
    _cases(
      'S3 a finished seat is skipped: seat 3 is next after seat 1 when seat 2 '
      'finished',
      (g) async {
        _expectBanner(
          g,
          youAreNextAfter(g.locale, 'Bob'),
          what: 'seat 2 finished, turn on seat 1, I am seat 3',
        );
      },
      locales: <Locale>[l],
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      placings: const <int>[2],
      tokens: const <int, List<int>>{2: _home},
      turn: _turnJson(1, 'await_roll'),
    );

    _cases(
      'S3 a retired seat is skipped: seat 3 is next after seat 1 when seat 2 '
      'is retired',
      (g) async {
        _expectBanner(
          g,
          youAreNextAfter(g.locale, 'Bob'),
          what: 'seat 2 retired, turn on seat 1, I am seat 3',
        );
      },
      locales: <Locale>[l],
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      retired: const <int>[2],
      turn: _turnJson(1, 'await_roll'),
    );

    _cases(
      'S3 the three-seat gate counts seats in play: one of three finished, '
      'no "You\'re next" banner',
      (g) async {
        final String banner = _bannerText(g);
        expect(
          banner.contains('أنت التالي') || banner.contains("You're next"),
          isFalse,
          reason: g.why(
            'no You\'re-next banner with two seats in play',
            'the banner reads "$banner"',
          ),
        );
        expect(
          banner.contains('Bob'),
          isTrue,
          reason: g.why(
            'the plain waiting line naming Bob',
            'the banner reads "$banner"',
          ),
        );
      },
      locales: <Locale>[l],
      seats: const <int>[0, 1, 2],
      me: 2,
      placings: const <int>[0],
      tokens: const <int, List<int>>{0: _home},
      turn: _turnJson(1, 'await_roll'),
    );

    _cases(
      'S3 seat dice: none for a finished or a retired seat, one for a seat in '
      'play',
      (g) async {
        expect(
          find.byKey(seatDieKey(2)),
          findsOneWidget,
          reason: g.why('board-seat-die-2 for seat 2, which is in play'),
        );
        expect(
          find.byKey(seatDieKey(1)),
          findsNothing,
          reason: g.why('no board-seat-die-1: seat 1 finished'),
        );
        expect(
          find.byKey(seatDieKey(3)),
          findsNothing,
          reason: g.why('no board-seat-die-3: seat 3 is retired'),
        );
      },
      locales: <Locale>[l],
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      placings: const <int>[1],
      retired: const <int>[3],
      tokens: const <int, List<int>>{1: _home},
      turn: _turnJson(2, 'await_roll'),
    );
  }

  Future<List<String>> youAreNextAnnouncements(
    WidgetTester tester, {
    required String scenario,
    required List<int> seats,
    required int me,
    required List<int> placings,
    required int from,
    required int to,
    List<String>? beforeOpening,
  }) async {
    final _Said said = _Said()..install(tester);
    final _G g = await _open(
      tester,
      scenario: scenario,
      seats: seats,
      me: me,
      placings: placings,
      tokens: <int, List<int>>{for (final int p in placings) p: _home},
      turn: _turnJson(from, 'await_roll'),
    );
    try {
      said.recorded.clear();
      await g.push('turn', _turnJson(to, 'await_roll'));
      if (beforeOpening != null) {
        // C-660 M5: a bare 2026-11 `turn` that passes the turn shuts the X192
        // gate with no `grace_ms` (C-657 G3a), so it opens 500 ms after the
        // board settles, which it already is. Read 400 ms in, still shut,
        // then 200 ms on, past the opening at +500 ms.
        await g.pump(400);
        beforeOpening.addAll(
          said.recorded.where((String m) => m == "You're next"),
        );
        await g.pump(200);
      }
      return said.recorded.where((String m) => m == "You're next").toList();
    } finally {
      await _close(g);
    }
  }

  testWidgets('C-656t S3 control: with nobody finished the seat after the '
      'mover hears You are next', (tester) async {
    final List<String> early = <String>[];
    final List<String> heard = await youAreNextAnnouncements(
      tester,
      scenario: 'S3 announce control',
      seats: const <int>[0, 1, 2, 3],
      me: 2,
      placings: const <int>[],
      from: 0,
      to: 1,
      beforeOpening: early,
    );
    expect(
      early,
      isEmpty,
      reason:
          'C-656t S3 announce control: turn 0 to 1, I am seat 2: expected no '
          "\"You're next\" 400 ms in, while the gate is shut, heard $early",
    );
    expect(
      heard,
      hasLength(1),
      reason:
          'C-656t S3 announce control: four seats, none finished, turn 0 to 1, '
          "I am seat 2: expected one \"You're next\", heard $heard",
    );
  });

  testWidgets('C-656t S3 the announcement skips a finished seat', (
    tester,
  ) async {
    final List<String> early = <String>[];
    final List<String> heard = await youAreNextAnnouncements(
      tester,
      scenario: 'S3 announce skips finished',
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      placings: const <int>[2],
      from: 0,
      to: 1,
      beforeOpening: early,
    );
    expect(
      early,
      isEmpty,
      reason:
          'C-656t S3 announce skips finished: turn 0 to 1, I am seat 3: '
          "expected no \"You're next\" 400 ms in, while the gate is shut, "
          'heard $early',
    );
    expect(
      heard,
      hasLength(1),
      reason:
          'C-656t S3 announce skips finished: seat 2 finished, turn 0 to 1, I '
          "am seat 3 and the next seat in play: expected one \"You're next\", "
          'heard $heard',
    );
  });

  testWidgets('C-656t S3 the announcement gate counts seats in play', (
    tester,
  ) async {
    final List<String> heard = await youAreNextAnnouncements(
      tester,
      scenario: 'S3 announce gate',
      seats: const <int>[0, 1, 2],
      me: 2,
      placings: const <int>[0],
      from: 2,
      to: 1,
    );
    expect(
      heard,
      isEmpty,
      reason:
          'C-656t S3 announce gate: seat 0 finished, two seats in play, turn '
          "2 to 1, I am seat 2: expected no \"You're next\", heard $heard",
    );
  });

  // ===========================================================================
  // S4: the end card
  // ===========================================================================

  /// A 2026-11 game that ends: [placings] and [retired] as the server sends
  /// them, me on seat [me]; the frames run from a PLAYING table.
  Future<_G> endedGame(
    WidgetTester tester, {
    required String scenario,
    required Locale locale,
    required List<int> seats,
    required int me,
    required List<int> placings,
    required List<int> retired,
    String? ruleset = _ruleset,
    double height = 1400,
  }) async {
    final _G g = await _open(
      tester,
      scenario: scenario,
      locale: locale,
      seats: seats,
      me: me,
      ruleset: ruleset,
      height: height,
      turn: _turnJson(
        seats.firstWhere(
          (int s) => !placings.contains(s) && !retired.contains(s),
          orElse: () => seats.first,
        ),
        'await_roll',
      ),
    );
    await g.push('game_over', _gameOver(placings.first, placings, retired));
    await g.pump(1500);
    return g;
  }

  List<int> rowOrder(WidgetTester tester) {
    final List<int> seats = _keysWithPrefix(tester, 'end-card-place-');
    seats.sort((int a, int b) {
      final Offset pa = tester.getTopLeft(find.byKey(_endPlaceKey(a)));
      final Offset pb = tester.getTopLeft(find.byKey(_endPlaceKey(b)));
      return pa.dy != pb.dy ? pa.dy.compareTo(pb.dy) : pa.dx.compareTo(pb.dx);
    });
    return seats;
  }

  List<Finder> rematchControls() => <Finder>[
    find.byKey(const Key('end-card-rematch')),
    find.byKey(const Key('end-card-rematch-ask')),
    find.byKey(const Key('end-card-rematch-waiting')),
    find.byKey(const Key('end-card-rematch-start')),
    find.byKey(const Key('end-card-rematch-may-start')),
  ];

  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S4 I am placings[0]: the win variant with a row per '
        'seat in order [${l.languageCode}]', (tester) async {
      final _G g = await endedGame(
        tester,
        scenario: 'S4 win [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2, 3],
        me: 1,
        placings: const <int>[1, 3, 0, 2],
        retired: const <int>[],
      );
      try {
        expect(
          find.byKey(const Key('end-card-win')),
          findsOneWidget,
          reason: g.why('the win variant (end-card-win) for placings[0] = me'),
        );
        expect(
          rowOrder(g.tester),
          <int>[1, 3, 0, 2],
          reason: g.why(
            'one end-card-place row per seat in placings order 1,3,0,2',
            'rows ${rowOrder(g.tester)}',
          ),
        );
        expect(
          find.descendant(
            of: find.byKey(_endPlaceKey(3)),
            matching: find.text('Dan'),
          ),
          findsOneWidget,
          reason: g.why('the row of seat 3 names Dan'),
        );
        for (final int s in <int>[0, 1, 2, 3]) {
          expect(
            find.descendant(
              of: find.byKey(_endPlaceKey(s)),
              matching: find.text(_outWord(l)),
            ),
            findsNothing,
            reason: g.why(
              'no "${_outWord(l)}" on the row of seat $s, nobody retired',
            ),
          );
        }
        expect(
          find.byKey(const Key('end-card-rematch')),
          findsOneWidget,
          reason: g.why(
            'the rematch action stays on the card for a seated player',
          ),
        );
      } finally {
        await _close(g);
      }
    });

    for (final (int place, List<int> placings) in <(int, List<int>)>[
      (2, <int>[3, 0, 1, 2]),
      (3, <int>[3, 1, 0, 2]),
      (4, <int>[3, 1, 2, 0]),
    ]) {
      testWidgets('C-656t S4 I am placed ${_ordinals['en']![place - 1]}: the '
          'lose variant titled with my place, the nudge line kept '
          '[${l.languageCode}]', (tester) async {
        final _G g = await endedGame(
          tester,
          scenario: 'S4 lose place $place [${l.languageCode}]',
          locale: l,
          seats: const <int>[0, 1, 2, 3],
          me: 0,
          placings: placings,
          retired: const <int>[],
        );
        try {
          expect(
            find.byKey(const Key('end-card-lose')),
            findsOneWidget,
            reason: g.why('the lose variant (end-card-lose) for place $place'),
          );
          expect(
            find.byKey(const Key('end-card-win')),
            findsNothing,
            reason: g.why('not the win variant for place $place'),
          );
          expect(
            find.text(_youCame(l, place), findRichText: true),
            findsOneWidget,
            reason: g.why('the title "${_youCame(l, place)}"'),
          );
          expect(
            find.byKey(const Key('end-card-lose-line')),
            findsOneWidget,
            reason: g.why('the near/nudge line (end-card-lose-line) as today'),
          );
          expect(
            rowOrder(g.tester),
            placings,
            reason: g.why(
              'rows in placings order $placings',
              'rows ${rowOrder(g.tester)}',
            ),
          );
          expect(
            find.byKey(const Key('end-card-rematch')),
            findsOneWidget,
            reason: g.why('rematch offered on the lose variant'),
          );
        } finally {
          await _close(g);
        }
      });
    }

    testWidgets('C-656t S4 I am retired: the ended variant, its line, rematch '
        'hidden, New table shown, retired rows say out '
        '[${l.languageCode}]', (tester) async {
      final _G g = await endedGame(
        tester,
        scenario: 'S4 retired me [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2, 3],
        me: 0,
        placings: const <int>[2, 1],
        retired: const <int>[0, 3],
      );
      try {
        expect(
          find.byKey(const Key('end-card-ended')),
          findsOneWidget,
          reason: g.why('the ended variant (end-card-ended) when I am retired'),
        );
        expect(
          find.text(_endedLine(l), findRichText: true),
          findsOneWidget,
          reason: g.why('the line "${_endedLine(l)}"'),
        );
        for (final Finder f in rematchControls()) {
          expect(
            f,
            findsNothing,
            reason: g.why('no rematch control for a retired seat'),
          );
        }
        expect(
          find.byKey(_newTableKey),
          findsOneWidget,
          reason: g.why('New table shown for a retired seat'),
        );
        expect(
          rowOrder(g.tester),
          <int>[2, 1, 0, 3],
          reason: g.why(
            'rows placings first (2,1) then retired order (0,3)',
            'rows ${rowOrder(g.tester)}',
          ),
        );
        for (final int s in <int>[0, 3]) {
          expect(
            find.descendant(
              of: find.byKey(_endPlaceKey(s)),
              matching: find.text(_outWord(l)),
            ),
            findsOneWidget,
            reason: g.why('"${_outWord(l)}" on the row of retired seat $s'),
          );
        }
        for (final int s in <int>[1, 2]) {
          expect(
            find.descendant(
              of: find.byKey(_endPlaceKey(s)),
              matching: find.text(_outWord(l)),
            ),
            findsNothing,
            reason: g.why('no "${_outWord(l)}" on the row of placed seat $s'),
          );
        }
      } finally {
        await _close(g);
      }
    });

    testWidgets(
      'C-656t S4 a seated player sees a retired seat as out and keeps '
      'Rematch [${l.languageCode}]',
      (tester) async {
        final _G g = await endedGame(
          tester,
          scenario: 'S4 retired other [${l.languageCode}]',
          locale: l,
          seats: const <int>[0, 1, 2],
          me: 1,
          placings: const <int>[1, 2],
          retired: const <int>[0],
        );
        try {
          expect(
            rowOrder(g.tester),
            <int>[1, 2, 0],
            reason: g.why(
              'rows 1,2 then retired 0',
              'rows ${rowOrder(g.tester)}',
            ),
          );
          expect(
            find.descendant(
              of: find.byKey(_endPlaceKey(0)),
              matching: find.text(_outWord(l)),
            ),
            findsOneWidget,
            reason: g.why('"${_outWord(l)}" on the retired seat\'s row'),
          );
          expect(
            find.byKey(const Key('end-card-rematch')),
            findsOneWidget,
            reason: g.why('Rematch for a seated winner'),
          );
          expect(
            find.byKey(const Key('end-card-win')),
            findsOneWidget,
            reason: g.why('the win variant for me, placings[0]'),
          );
        } finally {
          await _close(g);
        }
      },
    );
  }

  testWidgets('C-656t S4 medals: 1st is gold, 2nd and 3rd wear the seat colour '
      'and the number, not colour alone', (tester) async {
    final _G g = await endedGame(
      tester,
      scenario: 'S4 medals',
      locale: _en,
      seats: const <int>[0, 1, 2, 3],
      me: 3,
      placings: const <int>[1, 3, 0, 2],
      retired: const <int>[],
    );
    try {
      expect(_keysWithPrefix(g.tester, 'end-card-place-'), <int>[
        0,
        1,
        2,
        3,
      ], reason: g.why('one end-card-place row per seat'));
      final Rect first = g.tester.getRect(find.byKey(_endPlaceKey(1)));
      final Rect second = g.tester.getRect(find.byKey(_endPlaceKey(3)));
      final Rect third = g.tester.getRect(find.byKey(_endPlaceKey(0)));
      expect(
        await _colourPixels(g.tester, first, _golds, tolerance: 16),
        greaterThan(30),
        reason: g.why('a gold medal on the row of the 1st place (seat 1)'),
      );
      expect(
        await _colourPixels(g.tester, second, _golds, tolerance: 16),
        lessThanOrEqualTo(3),
        reason: g.why('no gold on the 2nd place row (seat 3)'),
      );
      expect(
        await _colourPixels(g.tester, second, <Color>[LudoColors.seats[3]]),
        greaterThan(30),
        reason: g.why('the 2nd place medal in seat 3\'s colour'),
      );
      expect(
        await _colourPixels(g.tester, third, <Color>[LudoColors.seats[0]]),
        greaterThan(30),
        reason: g.why('the 3rd place medal in seat 0\'s colour'),
      );
      expect(
        find.descendant(
          of: find.byKey(_endPlaceKey(3)),
          matching: find.text('2'),
        ),
        findsOneWidget,
        reason: g.why('the number 2 on the 2nd place medal'),
      );
      expect(
        find.descendant(
          of: find.byKey(_endPlaceKey(0)),
          matching: find.text('3'),
        ),
        findsOneWidget,
        reason: g.why('the number 3 on the 3rd place medal'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S4 the retired seat\'s own freeing player_left (28.4) '
      'leaves every row of the card in place for a seated player', (
    tester,
  ) async {
    final _G g = await endedGame(
      tester,
      scenario: 'S4 rows after the freeing player_left',
      locale: _en,
      seats: const <int>[0, 1, 2],
      me: 1,
      placings: const <int>[1, 2],
      retired: const <int>[0],
    );
    try {
      await g.push('player_left', <String, Object?>{'seat': 0, 'host_seat': 1});
      await g.pump(500);
      expect(
        rowOrder(g.tester),
        <int>[1, 2, 0],
        reason: g.why(
          'rows 1,2,0 still listed after seat 0 was freed (one row per seat in '
              'placings then retired, S4)',
          'rows ${rowOrder(g.tester)}',
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(_endPlaceKey(0)),
          matching: find.text('out'),
        ),
        findsOneWidget,
        reason: g.why('the freed seat\'s row still says out'),
      );
    } finally {
      await _close(g);
    }
  });

  // ===========================================================================
  // S5: a seat retired
  // ===========================================================================

  for (final Locale l in <Locale>[_en, _ar]) {
    for (final String reason in <String>['left', 'absent', 'kicked']) {
      testWidgets('C-656t S5 seat_retired $reason: notice for every player, '
          '2500 ms, no cue [${l.languageCode}]', (tester) async {
        final _G g = await _open(
          tester,
          scenario: 'S5 retired $reason [${l.languageCode}]',
          locale: l,
          seats: const <int>[0, 1, 2, 3],
          me: 0,
          offline: reason == 'left' ? const <int>{} : const <int>{3},
          turn: _turnJson(1, 'await_roll'),
        );
        try {
          final int mark = g.cues.length;
          await g.push('seat_retired', <String, Object?>{
            'seat': 3,
            'reason': reason,
            'host_seat': 0,
          });
          _expectNotice(
            g,
            _retiredNoticeKey,
            _retiredLine(l, reason, 'Dan'),
            what: 'seat 3 retired ($reason)',
          );
          expect(
            g.cues.skip(mark),
            isEmpty,
            reason: g.why('no cue for a retirement'),
          );
          await _expectHoldsTwoAndAHalfSeconds(g, _retiredNoticeKey);
        } finally {
          await _close(g);
        }
      });
    }
  }

  testWidgets('C-656t S5 a retirement is told to a non-host and to the host '
      'alike', (tester) async {
    for (final int me in <int>[0, 2]) {
      final _G g = await _open(
        tester,
        scenario: 'S5 retired told to seat $me',
        seats: const <int>[0, 1, 2],
        me: me,
        turn: _turnJson(me == 0 ? 2 : 0, 'await_roll'),
      );
      try {
        await g.push('seat_retired', <String, Object?>{
          'seat': 1,
          'reason': 'left',
          'host_seat': 0,
        });
        expect(
          find.byKey(_retiredNoticeKey),
          findsOneWidget,
          reason: g.why('the retirement notice on seat $me\'s screen'),
        );
      } finally {
        await _close(g);
      }
    }
  });

  testWidgets('C-656t S5 a retired seat\'s chip carries the out mark and no '
      'seat in play does', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S5 out mark',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await g.push('seat_retired', <String, Object?>{
        'seat': 3,
        'reason': 'left',
        'host_seat': 0,
      });
      await g.pump(600);
      expect(
        find.byKey(_outMarkKey(3)),
        findsOneWidget,
        reason: g.why('board-seat-out-3 beside the retired seat\'s name'),
      );
      for (final int s in <int>[0, 1, 2]) {
        expect(
          find.byKey(_outMarkKey(s)),
          findsNothing,
          reason: g.why('no out mark on seat $s, still in play'),
        );
      }
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S5 a retired seat\'s tokens draw at 0.35 of a token of '
      'a seat in play', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S5 dimmed tokens',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await g.push('seat_retired', <String, Object?>{
        'seat': 3,
        'reason': 'left',
        'host_seat': 0,
      });
      await g.pump(600);
      final double inPlay = _opacityAbove(
        g.tester,
        find.byKey(_tokenKey(1, 0)),
      );
      for (int t = 0; t < 4; t++) {
        final double o = _opacityAbove(g.tester, find.byKey(_tokenKey(3, t)));
        expect(
          o / inPlay,
          closeTo(0.35, 0.01),
          reason: g.why(
            'token 3-$t drawn at the yard-fade opacity 0.35 of a seat in play',
            'opacity $o against $inPlay',
          ),
        );
      }
      for (int t = 0; t < 4; t++) {
        expect(
          _opacityAbove(g.tester, find.byKey(_tokenKey(2, t))),
          closeTo(inPlay, 0.001),
          reason: g.why('token 2-$t of a seat in play at full opacity'),
        );
      }
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S5 a finished seat\'s tokens are not dimmed and its '
      'chip has no out mark', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S5 finished is not dimmed',
      seats: const <int>[0, 1, 2],
      me: 0,
      placings: const <int>[1],
      tokens: const <int, List<int>>{1: _home},
      turn: _turnJson(2, 'await_roll'),
    );
    try {
      expect(
        find.byKey(_outMarkKey(1)),
        findsNothing,
        reason: g.why('no out mark on a finished seat'),
      );
      expect(
        _opacityAbove(g.tester, find.byKey(_tokenKey(1, 0))),
        closeTo(_opacityAbove(g.tester, find.byKey(_tokenKey(2, 0))), 0.001),
        reason: g.why(
          'a finished seat\'s tokens at the opacity of a seat in play',
        ),
      );
    } finally {
      await _close(g);
    }
  });

  for (final Locale l in <Locale>[_en, _ar]) {
    _cases(
      'S5 my seat is retired and I resumed: the banner says I am out and '
      'watching',
      (g) async {
        _expectBanner(g, _outBanner(g.locale), what: 'I am in retired');
        expect(
          find.byKey(_outMarkKey(0)),
          findsOneWidget,
          reason: g.why('my own chip carries the out mark'),
        );
      },
      locales: <Locale>[l],
      seats: const <int>[0, 1, 2],
      me: 0,
      retired: const <int>[0],
      turn: _turnJson(1, 'await_roll'),
    );
  }

  testWidgets('C-656t S5 after game_over my own player_left does not leave the '
      'route while my seat is retired: the end card stays', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S5 retired me keeps the end card',
      seats: const <int>[0, 1, 2],
      me: 0,
      height: 1400,
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await g.push('seat_retired', <String, Object?>{
        'seat': 0,
        'reason': 'left',
        'host_seat': 1,
      });
      await g.push(
        'game_over',
        _gameOver(1, const <int>[1, 2], const <int>[0]),
      );
      await g.pump(1500);
      expect(
        find.byKey(const Key('end-card-ended')),
        findsOneWidget,
        reason: g.why('the ended variant before my own player_left'),
      );
      await g.push('player_left', <String, Object?>{'seat': 0, 'host_seat': 1});
      await g.pump(1500);
      expect(
        g.screenMounted,
        isTrue,
        reason: g.why('GameScreen still on the route after my own player_left'),
      );
      expect(
        find.byKey(const Key('end-card-ended')),
        findsOneWidget,
        reason: g.why('the end card still showing the ended variant'),
      );
      expect(
        find.byKey(_newTableKey),
        findsOneWidget,
        reason: g.why('New table still offered'),
      );
      expect(
        find.text('c656t-home'),
        findsNothing,
        reason: g.why('the home page is not what I am looking at'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S5 control: my own player_left with my seat not retired '
      'still leaves the route', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S5 control own player_left leaves',
      seats: const <int>[0, 1, 2],
      me: 0,
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await g.push('player_left', <String, Object?>{'seat': 0, 'host_seat': 1});
      await g.pump(1500);
      expect(
        g.screenMounted,
        isFalse,
        reason: g.why(
          'GameScreen left the route for a removed seat not in retired',
        ),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S5 after game_over a seated player whose own seat is not '
      'retired is unaffected by another retired seat\'s player_left', (
    tester,
  ) async {
    final _G g = await _open(
      tester,
      scenario: 'S5 other retired seat freed',
      seats: const <int>[0, 1, 2],
      me: 1,
      height: 1400,
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      await g.push(
        'game_over',
        _gameOver(1, const <int>[1, 2], const <int>[0]),
      );
      await g.pump(1500);
      await g.push('player_left', <String, Object?>{'seat': 0, 'host_seat': 1});
      await g.pump(1500);
      expect(
        g.screenMounted,
        isTrue,
        reason: g.why('still on the end card after another seat was freed'),
      );
      expect(
        find.byKey(const Key('end-card-win')),
        findsOneWidget,
        reason: g.why('the win variant is still showing'),
      );
    } finally {
      await _close(g);
    }
  });

  // ===========================================================================
  // S6: kick
  // ===========================================================================

  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S6 host, PLAYING, 2026-11, an away seat: the chip is a '
        'tap target of 48 dp and opens the game-styled sheet '
        '[${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S6 sheet opens [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 0,
        offline: const <int>{1},
        turn: _turnJson(2, 'await_roll'),
      );
      try {
        await _openKickSheet(g, 1);
        final Finder sheet = find.byKey(_kickSheetKey(1));
        expect(
          sheet,
          findsOneWidget,
          reason: g.why('kick-sheet-1 after a tap on the away chip'),
        );
        expect(
          _words(g.tester, sheet),
          contains(_norm(_kickQuestion(l, 'Bob'))),
          reason: g.why('the sheet asks "${_kickQuestion(l, 'Bob')}"'),
        );
        expect(
          _words(g.tester, find.byKey(_kickRemoveKey)),
          contains(_removeWord(l)),
          reason: g.why(
            'the button kick-sheet-remove reads "${_removeWord(l)}"',
          ),
        );
        expect(
          _words(g.tester, find.byKey(_kickWaitKey)),
          contains(_waitWord(l)),
          reason: g.why('the button kick-sheet-wait reads "${_waitWord(l)}"'),
        );
        expect(
          find.byType(AlertDialog),
          findsNothing,
          reason: g.why('not a Material AlertDialog'),
        );
        expect(
          find.byType(SimpleDialog),
          findsNothing,
          reason: g.why('not a Material SimpleDialog'),
        );
        expect(
          find.descendant(of: sheet, matching: find.byType(ElevatedButton)),
          findsNothing,
          reason: g.why('no ElevatedButtons in the sheet (P8)'),
        );
        expect(
          g.sent('kick'),
          isEmpty,
          reason: g.why('opening the sheet sends nothing'),
        );
      } finally {
        await _close(g);
      }
    });
  }

  testWidgets('C-656t S6 the away chip of an absent seat is a tap target of '
      'at least 48 dp for the host', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _G g = await _open(
      tester,
      scenario: 'S6 tap target size',
      seats: const <int>[0, 1, 2],
      me: 0,
      offline: const <int>{1},
      turn: _turnJson(2, 'await_roll'),
    );
    try {
      expect(
        find.byKey(_awayKey(1)),
        findsOneWidget,
        reason: g.why('the away chip of seat 1'),
      );
      final Size? target = _tapTargetAround(g.tester, find.byKey(_awayKey(1)));
      expect(
        target,
        isNotNull,
        reason: g.why(
          'a semantics node with a tap action around the away chip',
        ),
      );
      expect(
        target!.width >= 47.5 && target.height >= 47.5,
        isTrue,
        reason: g.why(
          'the away chip tap target at least 48 x 48 dp',
          'smallest tap node is ${target.width} x ${target.height} dp',
        ),
      );
    } finally {
      await _close(g);
      handle.dispose();
    }
  });

  testWidgets('C-656t S6 Wait closes the sheet and sends nothing', (
    tester,
  ) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 wait',
      seats: const <int>[0, 1, 2],
      me: 0,
      offline: const <int>{1},
      turn: _turnJson(2, 'await_roll'),
    );
    try {
      await _openKickSheet(g, 1);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsOneWidget,
        reason: g.why('sheet open'),
      );
      await g.tester.tap(find.byKey(_kickWaitKey));
      await g.tester.pump();
      await g.pump(500);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsNothing,
        reason: g.why('the sheet closed by Wait'),
      );
      expect(g.sent('kick'), isEmpty, reason: g.why('Wait sends no kick'));
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S6 Remove sends exactly one kick naming the seat, even '
      'on a double tap', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 remove once',
      seats: const <int>[0, 1, 2],
      me: 0,
      offline: const <int>{2},
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await _openKickSheet(g, 2);
      await g.tester.tap(find.byKey(_kickRemoveKey));
      await g.tester.tap(find.byKey(_kickRemoveKey), warnIfMissed: false);
      await g.tester.pump();
      await g.pump(500);
      expect(
        g.sent('kick'),
        <Map<String, Object?>>[
          <String, Object?>{'seat': 2},
        ],
        reason: g.why('exactly one kick {"seat": 2}', 'sent ${g.sent('kick')}'),
      );
    } finally {
      await _close(g);
    }
  });

  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S6 the server answers seat_retired kicked: the notice '
        'says the host removed the seat, the seat is dimmed '
        '[${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S6 kick accepted [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 0,
        offline: const <int>{2},
        turn: _turnJson(1, 'await_roll'),
      );
      try {
        await _openKickSheet(g, 2);
        await g.tester.tap(find.byKey(_kickRemoveKey));
        await g.tester.pump();
        await g.pushReply(
          'seat_retired',
          g.lastRequestId('kick'),
          <String, Object?>{'seat': 2, 'reason': 'kicked', 'host_seat': 0},
        );
        _expectNotice(
          g,
          _retiredNoticeKey,
          _retiredLine(l, 'kicked', 'Cara'),
          what: 'the host kicked seat 2',
        );
        expect(
          find.byKey(_outMarkKey(2)),
          findsOneWidget,
          reason: g.why('the out mark on the kicked seat'),
        );
        expect(
          find.byKey(_kickSheetKey(2)),
          findsNothing,
          reason: g.why('no sheet left over once the seat is out'),
        );
      } finally {
        await _close(g);
      }
    });

    testWidgets('C-656t S6 NOT_ABSENT shows "is back" for 2500 ms '
        '[${l.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: 'S6 NOT_ABSENT [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1, 2],
        me: 0,
        offline: const <int>{2},
        turn: _turnJson(1, 'await_roll'),
      );
      try {
        await _openKickSheet(g, 2);
        await g.tester.tap(find.byKey(_kickRemoveKey));
        await g.tester.pump();
        await g.pushError(g.lastRequestId('kick'), 'NOT_ABSENT');
        _expectNotice(
          g,
          _kickRefusedNoticeKey,
          _backLine(l, 'Cara'),
          what: 'NOT_ABSENT for seat 2',
        );
        await _expectHoldsTwoAndAHalfSeconds(g, _kickRefusedNoticeKey);
        expect(
          g.drive.controller.room,
          isNotNull,
          reason: g.why('the connection stays up after NOT_ABSENT'),
        );
      } finally {
        await _close(g);
      }
    });
  }

  for (final String code in <String>[
    'NOT_HOST',
    'WRONG_PHASE',
    'BAD_FIELD',
    'ILLEGAL_MOVE',
  ]) {
    for (final Locale l in <Locale>[_en, _ar]) {
      testWidgets('C-656t S6 refusal $code shows "could not remove" '
          '[${l.languageCode}]', (tester) async {
        final _G g = await _open(
          tester,
          scenario: 'S6 refused $code [${l.languageCode}]',
          locale: l,
          seats: const <int>[0, 1, 2],
          me: 0,
          offline: const <int>{2},
          turn: _turnJson(1, 'await_roll'),
        );
        try {
          await _openKickSheet(g, 2);
          await g.tester.tap(find.byKey(_kickRemoveKey));
          await g.tester.pump();
          await g.pushError(g.lastRequestId('kick'), code);
          _expectNotice(
            g,
            _kickRefusedNoticeKey,
            _couldNot(l, 'Cara'),
            what: 'a $code refusal for seat 2',
          );
        } finally {
          await _close(g);
        }
      });
    }
  }

  // C-708 (PROTOCOL 33 item 8): the host may remove a connected seat too, so
  // a seat coming back no longer takes its sheet away. The sheet goes when
  // its seat stops being in play.
  testWidgets('C-656t S6 the sheet stays when its seat reconnects and closes '
      'when that seat leaves the game', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 closes on reconnect',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      offline: const <int>{1, 2},
      turn: _turnJson(3, 'await_roll'),
    );
    try {
      await _openKickSheet(g, 1);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsOneWidget,
        reason: g.why('sheet open'),
      );
      await g.push('presence', <String, Object?>{'seat': 2, 'connected': true});
      await g.pump(400);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsOneWidget,
        reason: g.why('seat 2 coming back does not close the sheet of seat 1'),
      );
      await g.push('presence', <String, Object?>{'seat': 1, 'connected': true});
      await g.pump(400);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsOneWidget,
        reason: g.why(
          'seat 1 reconnecting keeps its sheet: a connected seat may be '
          'removed too',
        ),
      );
      expect(
        g.sent('kick'),
        isEmpty,
        reason: g.why('a seat coming back sends nothing'),
      );
      await g.push('seat_retired', <String, Object?>{
        'seat': 1,
        'reason': 'left',
        'host_seat': 0,
      });
      await g.pump(400);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsNothing,
        reason: g.why('seat 1 leaving the game closes its sheet'),
      );
      expect(
        g.sent('kick'),
        isEmpty,
        reason: g.why('closing the sheet sends nothing'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S6 the sheet stays on a snapshot that reconnects its '
      'seat and closes on one that retires it', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 closes on snapshot reconnect',
      seats: const <int>[0, 1, 2],
      me: 0,
      offline: const <int>{1},
      turn: _turnJson(2, 'await_roll'),
    );
    try {
      await _openKickSheet(g, 1);
      Map<String, Object?> snapshot({required List<int> retired}) =>
          <String, Object?>{
            'code': 'K7M2QP',
            'state': 'PLAYING',
            'host_seat': 0,
            'players': 3,
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
              for (final int s in <int>[0, 1, 2])
                _seatJson(
                  s,
                  name: s == 0 ? _myName : _names[s]!,
                  connected: true,
                  tokens: _yard,
                  ruleset: true,
                ),
            ],
            'turn': _turnJson(2, 'await_roll'),
            'winner': null,
            'placings': <int>[],
            'retired': retired,
          };
      await g.push('room', snapshot(retired: <int>[]));
      await g.pump(400);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsOneWidget,
        reason: g.why(
          'a snapshot that shows seat 1 connected keeps its sheet: a '
          'connected seat may be removed too',
        ),
      );
      await g.push('room', snapshot(retired: <int>[1]));
      await g.pump(400);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsNothing,
        reason: g.why('a snapshot that shows seat 1 retired closes its sheet'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S6 not offered to a non-host', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 non-host',
      seats: const <int>[0, 1, 2],
      me: 2,
      hostSeat: 0,
      offline: const <int>{1},
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      expect(
        find.byKey(_awayKey(1)),
        findsOneWidget,
        reason: g.why('the away chip is drawn for a non-host too'),
      );
      await _tapAway(g, 1);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsNothing,
        reason: g.why('no kick sheet for a non-host'),
      );
      // C-708: the name plates are the host's way to a connected seat; a
      // non-host gets nothing from them, away or connected.
      for (final int s in <int>[0, 1]) {
        await g.tester.tap(find.byKey(_nameChipKey(s)), warnIfMissed: false);
        await g.tester.pump();
        await g.pump(400);
        expect(
          find.byKey(_kickSheetKey(s)),
          findsNothing,
          reason: g.why(
            'no kick sheet for a non-host from the name plate of '
            'seat $s',
          ),
        );
      }
      expect(g.sent('kick'), isEmpty, reason: g.why('no kick request'));
    } finally {
      await _close(g);
    }
  });

  // C-708 (PROTOCOL 33 item 8): the host may remove a connected seat too,
  // and reaches it from the seat's name plate.
  testWidgets('C-656t S6 offered for a connected seat from its name plate', (
    tester,
  ) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 connected seat',
      seats: const <int>[0, 1, 2],
      me: 0,
      turn: _turnJson(2, 'await_roll'),
    );
    try {
      for (final int s in <int>[1, 2]) {
        await g.tester.tap(find.byKey(_nameChipKey(s)), warnIfMissed: false);
        await g.tester.pump();
        await g.pump(400);
        expect(
          find.byKey(_kickSheetKey(s)),
          findsOneWidget,
          reason: g.why(
            'kick-sheet-$s from the name plate of connected seat $s',
          ),
        );
        await g.tester.tap(find.byKey(const Key('kick-sheet-wait')));
        await g.tester.pump();
        await g.pump(400);
        expect(
          find.byKey(_kickSheetKey(s)),
          findsNothing,
          reason: g.why('Wait closes the sheet of seat $s'),
        );
      }
      expect(
        g.sent('kick'),
        isEmpty,
        reason: g.why('opening and closing the sheet sends no kick'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S6 not offered in a 2026-10 room', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 2026-10 room',
      seats: const <int>[0, 1, 2],
      me: 0,
      ruleset: null,
      offline: const <int>{1},
      turn: _turnJson(2, 'await_roll'),
    );
    try {
      expect(
        find.byKey(_awayKey(1)),
        findsOneWidget,
        reason: g.why('the away chip as today'),
      );
      await _tapAway(g, 1);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsNothing,
        reason: g.why('no kick sheet in a 2026-10 room'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S6 not offered for an away seat that is no longer in '
      'play (finished or retired)', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 away but out of play',
      seats: const <int>[0, 1, 2, 3],
      me: 0,
      offline: const <int>{1, 2},
      placings: const <int>[1],
      retired: const <int>[2],
      tokens: const <int, List<int>>{1: _home},
      turn: _turnJson(3, 'await_roll'),
    );
    try {
      for (final int s in <int>[1, 2]) {
        await _tapAway(g, s);
        expect(
          find.byKey(_kickSheetKey(s)),
          findsNothing,
          reason: g.why('no kick sheet for seat $s, which is not in play'),
        );
      }
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S6 not offered once the game is over', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S6 FINISHED',
      seats: const <int>[0, 1, 2],
      me: 0,
      offline: const <int>{1},
      state: 'FINISHED',
      winner: 0,
      placings: const <int>[0, 2, 1],
      height: 1400,
    );
    try {
      await _tapAway(g, 1);
      expect(
        find.byKey(_kickSheetKey(1)),
        findsNothing,
        reason: g.why('no kick sheet in FINISHED'),
      );
    } finally {
      await _close(g);
    }
  });

  // ===========================================================================
  // S7: a 2026-10 room is as it was
  // ===========================================================================

  testWidgets('C-656t S7 no new feedback id', (tester) async {
    expect(
      FeedbackCue.values.map((FeedbackCue c) => c.name).toSet(),
      <String>{
        'yourTurn',
        'canMove',
        'noMove',
        'step',
        'capturedOther',
        'capturedMe',
        'home',
        'win',
        'gameOver',
        'invalidTap',
        'tap',
        'dieLand',
        'gloat',
        'captureSeen',
        'friendJoined',
      },
      reason:
          'C-656t S7: the feedback cues are the fifteen of today; a new id '
          'means the screen added a cue the contract does not allow',
    );
  });

  testWidgets('C-656t S7 a 2026-10 room: an ordinary game shows none of the '
      'new keys and plays today\'s cues', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S7 2026-10 play',
      seats: const <int>[0, 1, 2],
      me: 0,
      ruleset: null,
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      await g.push('rolled', <String, Object?>{
        'seat': 0,
        'value': 4,
        'legal': <int>[],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 1,
        'reveal': rollTrayReveal,
        'queue': <int>[],
      });
      await g.push('turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      await g.push('turn', _turnJson(1, 'await_roll'));
      expect(
        find.byKey(_noMoveNoticeKey),
        findsOneWidget,
        reason: g.why('today\'s no-move notice, as today'),
      );
      await g.push('rolled', <String, Object?>{
        'seat': 1,
        'value': 6,
        'legal': <int>[0],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 2,
        'reveal': rollTrayReveal,
        'queue': <int>[6],
        'legal_by_face': <Object?>[
          faceLegal(6, const <int>[0]),
        ],
      });
      for (final Key k in <Key>[
        _releaseNoticeKey,
        _finishedNoticeKey,
        _retiredNoticeKey,
        _kickRefusedNoticeKey,
      ]) {
        expect(
          find.byKey(k),
          findsNothing,
          reason: g.why(
            'no ${(k as ValueKey<String>).value} in a 2026-10 room',
          ),
        );
      }
      expect(
        _keysWithPrefix(g.tester, 'board-seat-place-'),
        isEmpty,
        reason: g.why('no place badge in a 2026-10 room'),
      );
      expect(
        _keysWithPrefix(g.tester, 'board-seat-out-'),
        isEmpty,
        reason: g.why('no out mark in a 2026-10 room'),
      );
      expect(
        find.byKey(seatDieKey(2)),
        findsOneWidget,
        reason: g.why('seat die of seat 2 as today'),
      );
    } finally {
      await _close(g);
    }
  });

  for (final Locale l in <Locale>[_en, _ar]) {
    testWidgets('C-656t S7 a 2026-10 game_over (no placings): today\'s lose '
        'card, no places list, no You-came title [${l.languageCode}]', (
      tester,
    ) async {
      final _G g = await _open(
        tester,
        scenario: 'S7 2026-10 lose card [${l.languageCode}]',
        locale: l,
        seats: const <int>[0, 1],
        me: 0,
        ruleset: null,
        height: 1400,
        turn: _turnJson(1, 'await_roll'),
      );
      try {
        await g.push('game_over', <String, Object?>{
          'winner': 1,
          'verify_url': 'https://c656t.invalid/verify/1',
        });
        await g.pump(1500);
        expect(
          find.byKey(const Key('end-card-lose')),
          findsOneWidget,
          reason: g.why('the lose variant as today'),
        );
        expect(
          _keysWithPrefix(g.tester, 'end-card-place-'),
          isEmpty,
          reason: g.why('no places list when placings is empty'),
        );
        expect(
          find.text(_youCame(l, 2), findRichText: true),
          findsNothing,
          reason: g.why('not the You-came title'),
        );
        expect(
          find.byKey(const Key('end-card-lose-line')),
          findsOneWidget,
          reason: g.why('the nudge line as today'),
        );
        expect(
          find.byKey(const Key('end-card-rematch')),
          findsOneWidget,
          reason: g.why('Rematch as today'),
        );
      } finally {
        await _close(g);
      }
    });
  }

  testWidgets('C-656t S7 a 2026-10 win card has no places list', (
    tester,
  ) async {
    final _G g = await _open(
      tester,
      scenario: 'S7 2026-10 win card',
      seats: const <int>[0, 1],
      me: 0,
      ruleset: null,
      height: 1400,
      turn: _turnJson(0, 'await_roll'),
    );
    try {
      await g.push('game_over', <String, Object?>{
        'winner': 0,
        'verify_url': 'https://c656t.invalid/verify/1',
      });
      await g.pump(1500);
      expect(
        find.byKey(const Key('end-card-win')),
        findsOneWidget,
        reason: g.why('the win variant as today'),
      );
      expect(
        _keysWithPrefix(g.tester, 'end-card-place-'),
        isEmpty,
        reason: g.why('no places list when placings is empty'),
      );
    } finally {
      await _close(g);
    }
  });

  testWidgets('C-656t S7 a 2026-10 own player_left still leaves the route '
      'after game_over', (tester) async {
    final _G g = await _open(
      tester,
      scenario: 'S7 2026-10 player_left after game_over',
      seats: const <int>[0, 1],
      me: 0,
      ruleset: null,
      height: 1400,
      turn: _turnJson(1, 'await_roll'),
    );
    try {
      await g.push('game_over', <String, Object?>{
        'winner': 1,
        'verify_url': 'https://c656t.invalid/verify/1',
      });
      await g.pump(1500);
      await g.push('player_left', <String, Object?>{'seat': 0, 'host_seat': 1});
      await g.pump(1500);
      expect(
        g.screenMounted,
        isFalse,
        reason: g.why(
          'the screen leaves the route as today when I am not in retired',
        ),
      );
    } finally {
      await _close(g);
    }
  });
}
