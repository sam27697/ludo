// Guards for order C-676, written from the coordinator's text only: four
// behaviours of the shared release (ruleset 2026-12) that a client has to keep.
//
//   G1  a decline that never reached the server is offered again after the
//       reconnect snapshot (same k), and a rematch offer at an old k is live
//   G2  a pill tap and a ringed-piece tap before the answer send one message
//   G3  the five new notice kinds at text scale 1.5 on 360 px are not cut, and
//       an offer notice does not move the board
//   G4  with my turn clock up the pill is absent or disabled and sends nothing
//
// Same harness as test/c673_shared_release_client_test.dart (a real GameScreen
// over a real RoomController on FakeTransport). Fixed frames, no seed: a
// failure line names the case, the locale, the frames and the replay command:
//
//   flock /tmp/ludo-suite.lock flutter test \
//     test/c676_shared_release_guards_test.dart --plain-name '<case name>'

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

// --- the order's keys and texts, verbatim ------------------------------------

const Key _pillKey = Key('release-decline-button');
const Key _offerNoticeKey = Key('release-offer-notice');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const String _shared = '2026-12';

String _pillText(Locale l) => l == _ar ? 'خليهم بالبيت' : 'Keep them home';

String _myOfferText(Locale l) => l == _ar
    ? 'ما طلع 6 بعشر رميات. بتطلع قطعة؟ وكل واحد تاني بياخد 6.'
    : 'No 6 in 10 rolls. Bring one piece out? Everyone else gets a 6.';

String _theirOfferText(Locale l, String n) => l == _ar
    ? '$n: ما طلع 6 بعشر رميات. عم يقرر...'
    : '$n: no 6 in 10 rolls. Choosing...';

String _declinedText(Locale l, String n) =>
    l == _ar ? '$n خلّى قطعه بالبيت.' : '$n kept their pieces home.';

String _tookText(Locale l, String n) => l == _ar
    ? '$n طلّع قطعة. وكل واحد تاني بياخد 6.'
    : '$n took the release. Everyone else gets a 6.';

String _tookGrantedText(Locale l, String n) => l == _ar
    ? '$n طلّع قطعة. إنت بتاخد 6.'
    : '$n took the release. You get a 6.';

String _bankedText(Locale l) =>
    l == _ar ? 'معك 6 زيادة من الإفراج.' : 'Bonus 6 from the release.';

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};
const String _myName = 'Sam';
const List<int> _yard = <int>[-1, -1, -1, -1];

// --- wire frames -------------------------------------------------------------

int _idSeq = 0;

String _frame(String type, Map<String, Object?> data, {String? re}) {
  _idSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c673t-srv-${_idSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  required List<int> tokens,
  required String? ruleset,
  int? banked,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
  'drought': ?(ruleset != null ? 0 : null),
  'banked': ?banked,
};

Map<String, Object?> _roomJson({
  required String? ruleset,
  required List<int> seats,
  required int me,
  required Map<String, Object?>? turn,
  Map<int, int> banked = const <int, int>{},
  Map<int, List<int>> tokens = const <int, List<int>>{},
  int seq = 1,
  int chainIndex = 0,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': seats.first,
  'players': seats.length,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
    'ruleset': ?ruleset,
  },
  'chain_commit': 'a' * 64,
  'chain_index': chainIndex,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[
    for (final int s in seats)
      _seatJson(
        s,
        name: s == me ? _myName : _names[s]!,
        tokens: tokens[s] ?? _yard,
        ruleset: ruleset,
        banked: ruleset == _shared ? (banked[s] ?? 0) : null,
      ),
  ],
  'turn': turn,
  'winner': null,
  'seq': seq,
  'placings': ?(ruleset != null ? <int>[] : null),
  'retired': ?(ruleset != null ? <int>[] : null),
};

Map<String, Object?> _turnJson(
  int seat,
  String phase, {
  List<int>? legal,
  List<int>? queue,
  bool release = false,
  bool offer = false,
  int k = 10,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': rollTrayDeadlineMs,
  'k': k,
  'legal': ?legal,
  'queue': ?queue,
  'release': ?(release ? true : null),
  'offer': ?(offer ? true : null),
};

/// Section 30 rule 2: the `rolled` that raises the offer.
Map<String, Object?> _offerRolled(
  int seat,
  int value,
  List<int> legal, {
  int deadline = rollTrayDeadlineMs,
}) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': deadline,
  'k': 10,
  'reveal': rollTrayReveal,
  'queue': <int>[value],
  'release': true,
  'offer': true,
};

Map<String, Object?> _moved(int seat, int token) => <String, Object?>{
  'seat': seat,
  'token': token,
  'from': -1,
  'to': 0,
  'captured': <Object?>[],
  'extra_roll': false,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport t) => _queue.add(t);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

// --- one mounted table -------------------------------------------------------

class _G {
  _G(
    this.tester,
    this.drive,
    this.scenario,
    this.locale,
    this.ruleset,
    this.seats,
    this.me,
  );

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String scenario;
  final Locale locale;
  final String? ruleset;
  final List<int> seats;
  final int me;
  final List<String> frames = <String>[];
  int clockMs = 0;

  /// The transport the controller holds after a resume; null before one.
  FakeTransport? resumed;

  FakeTransport get wire => resumed ?? drive.transport;

  String why(String expected, [String? observed]) =>
      'C-676t "$scenario" [${locale.languageCode}, ruleset ${ruleset ?? 'absent'}] '
      'at +${clockMs}ms: expected $expected; observed ${observed ?? _seen()}. '
      'Frames pushed in order: ${frames.isEmpty ? '<none>' : frames.join(' -> ')}. '
      'Fixed frames, no seed: replay with flock /tmp/ludo-suite.lock flutter '
      "test test/c676_shared_release_guards_test.dart --plain-name '$scenario'.";

  String _seen() =>
      'pill ${find.byKey(_pillKey).evaluate().isNotEmpty}, offer notice '
      '${find.byKey(_offerNoticeKey).evaluate().isNotEmpty}, rings '
      '${ringed()}, texts $_allTexts, cues ${cueIds()}, sent ${sentTypes()}';

  Set<String> get _allTexts => <String>{
    for (final Element e in find.byType(RichText).evaluate())
      if (_norm((e.widget as RichText).text.toPlainText()).length > 12)
        _norm((e.widget as RichText).text.toPlainText()),
  };

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

  List<String> cueIds() => <String>[for (final FeedbackCue c in cues) c.id];

  List<Map<String, Object?>> sent(String type) => <Map<String, Object?>>[
    for (final String s in wire.sentRaw)
      if (frameType(s) == type) frameData(s),
  ];

  List<String> sentTypes() => sentTypesSince(wire, 0);

  List<int> ringed() => <int>[
    for (int t = 0; t < 4; t++)
      if (tester.any(find.byKey(legalRingKey(me, t)))) t,
  ];

  bool get pill => find.byKey(_pillKey).evaluate().isNotEmpty;

  /// True when some text on screen reads exactly [text].
  bool shows(String text) {
    final String want = _norm(text);
    for (final Element e in find.byType(RichText).evaluate()) {
      if (_norm((e.widget as RichText).text.toPlainText()) == want) {
        return true;
      }
    }
    return false;
  }

  void expectShows(String text, String what) => expect(
    shows(text),
    isTrue,
    reason: why('$what: the screen reads "${_norm(text)}"'),
  );

  void expectNotShows(String text, String what) => expect(
    shows(text),
    isFalse,
    reason: why('$what: the screen does not read "${_norm(text)}"'),
  );

  RoomController get controller => drive.controller;
}

final RegExp _bidi = RegExp(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069]');

String _norm(String s) =>
    s.replaceAll(_bidi, '').replaceAll(RegExp(r'\s+'), ' ').trim();

Future<_G> _open(
  WidgetTester tester, {
  required String scenario,
  Locale locale = _en,
  String? ruleset = _shared,
  List<int> seats = const <int>[0, 1],
  int me = 0,
  Map<String, Object?>? turn,
  Map<int, int> banked = const <int, int>{},
  double width = 412,
  double height = 892,
  double textScale = 1.0,
  FakeTransport? transport,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final _Connector connector = _Connector();
  final FakeTransport wire = transport ?? FakeTransport();
  connector.enqueue(wire);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c673t.invalid/ws'),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> future = controller.createRoom(name: _myName, players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(wire.sentRaw.last);
  wire.pushText(
    _frame('seat_assigned', <String, Object?>{
      'seat': me,
      'seat_token': 'tok-$me',
    }),
  );
  wire.pushText(
    _frame(
      'room',
      _roomJson(
        ruleset: ruleset,
        seats: seats,
        me: me,
        turn: turn ?? _turnJson(seats.first, 'await_roll'),
        banked: banked,
      ),
      re: id,
    ),
  );
  await future;
  final RollTrayDrive drive = RollTrayDrive(
    controller: controller,
    transport: wire,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: connector.enqueue,
  );
  await tester.pumpWidget(
    MaterialApp(
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
      home: GameScreen(controller: controller),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return _G(tester, drive, scenario, locale, ruleset, seats, me);
}

typedef _Body = Future<void> Function(_G g);

void _cases(
  String name,
  _Body body, {
  List<Locale> locales = const <Locale>[_en, _ar],
  String? ruleset = _shared,
  List<int> seats = const <int>[0, 1],
  int me = 0,
  Map<String, Object?>? turn,
  Map<int, int> banked = const <int, int>{},
  double width = 412,
  double height = 892,
  double textScale = 1.0,
}) {
  for (final Locale locale in locales) {
    testWidgets('C-676t $name [${locale.languageCode}]', (tester) async {
      final _G g = await _open(
        tester,
        scenario: '$name [${locale.languageCode}]',
        locale: locale,
        ruleset: ruleset,
        seats: seats,
        me: me,
        turn: turn,
        banked: banked,
        width: width,
        height: height,
        textScale: textScale,
      );
      try {
        await body(g);
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });
  }
}

const double _w = 360;
const double _h = 800;

int _count(FakeTransport t, String type) =>
    t.sentRaw.where((String s) => frameType(s) == type).length;

Map<String, Object?> _offerTurn({int k = 10}) => _turnJson(
  0,
  'await_move',
  legal: const <int>[1, 3],
  queue: const <int>[4],
  release: true,
  offer: true,
  k: k,
);

/// The transport dies, a new one resumes with [room] as the answer.
Future<void> _resume(_G g, Map<String, Object?> room) async {
  g.wire.endFromFarSide();
  await g.tester.pump();
  await g.tester.pump();
  await g.pump(200);
  final FakeTransport next = FakeTransport();
  g.drive.enqueueTransport(next);
  g.resumed = next;
  unawaited(g.controller.reconnect());
  await g.tester.runAsync(() => pumpEventQueue());
  await g.tester.pump();
  expect(
    next.sentRaw.isNotEmpty && frameType(next.sentRaw.last) == 'resume',
    isTrue,
    reason: g.why('a resume request on the new transport'),
  );
  final String id = requestIdOf(next.sentRaw.last);
  g.frames.add('room(resume) ${jsonEncode(room['turn'])}');
  next.pushText(_frame('room', room, re: id));
  await g.tester.pump();
  await g.tester.pump();
  await g.tester.pump(const Duration(seconds: 1));
}

Map<String, Object?> _resumeRoom(_G g, {int k = 10}) => _roomJson(
  ruleset: _shared,
  seats: g.seats,
  me: g.me,
  seq: g.drive.lastSeq + 1,
  turn: _offerTurn(k: k),
);

class _ThrowingTransport extends FakeTransport {
  bool boom = false;
  int attempts = 0;

  @override
  void send(String text) {
    if (boom) {
      attempts += 1;
      throw StateError('c676 socket write failed');
    }
    super.send(text);
  }
}

Future<void> _tapPill(_G g) async {
  expect(
    find.byKey(_pillKey),
    findsOneWidget,
    reason: g.why('the decline pill is on screen to be tapped'),
  );
  await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
  await g.tester.pump();
  await g.tester.pump(const Duration(milliseconds: 100));
}

/// The RenderParagraph of the on-screen text reading exactly [text], or a
/// failure naming what is there instead.
RenderParagraph _paragraph(_G g, String text, String what) {
  final String want = _norm(text);
  final Finder f = find.byWidgetPredicate(
    (Widget w) => w is RichText && _norm(w.text.toPlainText()) == want,
  );
  expect(
    f,
    findsAtLeastNWidgets(1),
    reason: g.why('$what: the full sentence "$want" findable as one text'),
  );
  return g.tester.renderObject<RenderParagraph>(f.first);
}

void _expectNotCut(_G g, String text, String what) {
  final RenderParagraph p = _paragraph(g, text, what);
  expect(
    p.didExceedMaxLines,
    isFalse,
    reason: g.why('$what: "$text" is not cut by a line limit or ellipsis'),
  );
  expect(
    p.size.height > 0 && p.size.width <= _w,
    isTrue,
    reason: g.why('$what: the text fits the 360 px width', '${p.size}'),
  );
}

void main() {
  // ===========================================================================
  // G1: a decline that did not arrive
  // ===========================================================================

  _cases(
    'G1a a decline written to a dead socket is dropped; the reconnect '
    'snapshot restores the same offer and the pill declines once',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      final FakeTransport dead = g.wire;
      dead.endFromFarSide();
      await g.tester.pump();
      await g.tester.pump();
      if (g.pill) {
        await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
        await g.tester.pump();
      }
      expect(
        _count(dead, 'decline_release'),
        0,
        reason: g.why('nothing reaches the dead socket'),
      );
      await _resume(g, _resumeRoom(g));
      expect(
        g.pill,
        isTrue,
        reason: g.why('the pill is live after the resume'),
      );
      expect(
        g.controller.room!.turn!.offer,
        isTrue,
        reason: g.why('the same offer is restored (k 10)'),
      );
      await _tapPill(g);
      expect(
        _count(g.wire, 'decline_release'),
        1,
        reason: g.why('exactly one decline_release on the new socket'),
      );
    },
    locales: const <Locale>[_en],
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'G1b a decline sent but never answered, the socket drops: the same offer '
    'comes back with the same k and the pill declines once more',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await _tapPill(g);
      final FakeTransport first = g.wire;
      expect(
        _count(first, 'decline_release'),
        1,
        reason: g.why('fixture: the first decline was written'),
      );
      await _resume(g, _resumeRoom(g));
      expect(
        g.pill,
        isTrue,
        reason: g.why('the pill is live after the resume'),
      );
      await _tapPill(g);
      expect(
        _count(g.wire, 'decline_release'),
        1,
        reason: g.why('exactly one decline_release on the new socket'),
      );
    },
    locales: const <Locale>[_en, _ar],
    turn: _turnJson(0, 'await_roll'),
  );

  testWidgets('C-676t G1c a transport that throws on send: the pill stays '
      'live after the reconnect snapshot and declines once', (tester) async {
    final _ThrowingTransport bad = _ThrowingTransport();
    final _G g = await _open(
      tester,
      scenario: 'G1c throwing transport',
      turn: _turnJson(0, 'await_roll'),
      transport: bad,
    );
    try {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      bad.boom = true;
      await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
      await g.tester.pump();
      await g.tester.pump(const Duration(milliseconds: 100));
      expect(
        bad.attempts,
        greaterThan(0),
        reason: g.why('fixture: the screen did try to write the decline'),
      );
      bad.boom = false;
      await _resume(g, _resumeRoom(g));
      expect(
        g.pill,
        isTrue,
        reason: g.why('the pill is live after the resume'),
      );
      await _tapPill(g);
      expect(
        _count(g.wire, 'decline_release'),
        1,
        reason: g.why('exactly one decline_release on the new socket'),
      );
    } finally {
      await releaseGame(g.tester, g.drive);
    }
  });

  _cases(
    'G1d a rematch game whose offer arrives at the same k as an earlier '
    'declined offer shows a live pill',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await _tapPill(g);
      await g.push('release_declined', <String, Object?>{'seat': 0});
      await g.push('turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'no_legal_move',
      });
      await g.push('turn', _turnJson(1, 'await_roll'));
      expect(g.pill, isFalse, reason: g.why('fixture: the pill is gone'));
      await g.push(
        'room',
        _roomJson(
          ruleset: _shared,
          seats: g.seats,
          me: g.me,
          chainIndex: 1,
          turn: _turnJson(0, 'await_roll'),
        ),
      );
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      expect(g.pill, isTrue, reason: g.why('a live pill in the rematch game'));
      await _tapPill(g);
      expect(
        _count(g.wire, 'decline_release'),
        2,
        reason: g.why('the rematch pill declines: two in all, one per game'),
      );
    },
    locales: const <Locale>[_en],
    turn: _turnJson(0, 'await_roll'),
  );

  // ===========================================================================
  // G2: one answer only
  // ===========================================================================

  int answers(_G g) => g.sent('decline_release').length + g.sent('move').length;

  _cases(
    'G2a the pill, then a ringed piece before the answer: one message, the '
    'decline',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await _tapPill(g);
      await g.tester.tap(find.byKey(tokenHitKey(0, 3)), warnIfMissed: false);
      await g.tester.pump();
      await g.tester.pump(const Duration(milliseconds: 400));
      expect(
        <int>[g.sent('decline_release').length, g.sent('move').length],
        <int>[1, 0],
        reason: g.why('exactly one decline_release and no move'),
      );
    },
    locales: const <Locale>[_en, _ar],
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'G2b a ringed piece, then the pill before the answer: one message, the '
    'move',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await g.tester.tap(find.byKey(tokenHitKey(0, 3)), warnIfMissed: false);
      await g.tester.pump();
      await g.tester.pump(const Duration(milliseconds: 400));
      if (g.pill) {
        await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
        await g.tester.pump();
        await g.tester.pump(const Duration(milliseconds: 400));
      }
      expect(
        <int>[g.sent('move').length, g.sent('decline_release').length],
        <int>[1, 0],
        reason: g.why(
          'exactly one move and no decline_release, got ${answers(g)} in all',
        ),
      );
      expect(
        g.sent('move').single.containsKey('face'),
        isFalse,
        reason: g.why('the move is a release move, no face'),
      );
    },
    locales: const <Locale>[_en, _ar],
    turn: _turnJson(0, 'await_roll'),
  );

  // ===========================================================================
  // G3: the notices are whole
  // ===========================================================================

  for (final Locale l in <Locale>[_en, _ar]) {
    Future<_G> table(
      WidgetTester tester,
      String name, {
      List<int> seats = const <int>[0, 1, 2],
      int me = 2,
      Map<String, Object?>? turn,
    }) => _open(
      tester,
      scenario: '$name [${l.languageCode}]',
      locale: l,
      seats: seats,
      me: me,
      turn: turn ?? _turnJson(1, 'await_roll'),
      width: _w,
      height: _h,
      textScale: 1.5,
    );

    testWidgets('C-676t G3a my offer notice at 1.5 x 360 px is whole and the '
        'board stays put [${l.languageCode}]', (tester) async {
      final _G g = await table(
        tester,
        'G3a my offer',
        seats: const <int>[0, 1],
        me: 0,
        turn: _turnJson(0, 'await_roll'),
      );
      try {
        final Rect before = g.tester.getRect(find.byKey(boardKey));
        await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
        _expectNotCut(g, _myOfferText(l), 'my offer notice');
        _expectNotCut(g, _pillText(l), 'the pill');
        expect(
          g.tester.getRect(find.byKey(boardKey)),
          before,
          reason: g.why('the board rect does not move when my offer arrives'),
        );
        expect(g.tester.takeException(), isNull, reason: g.why('no overflow'));
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });

    testWidgets('C-676t G3b the choosing line at 1.5 x 360 px is whole and '
        'the board stays put [${l.languageCode}]', (tester) async {
      final _G g = await table(tester, 'G3b choosing');
      try {
        final Rect before = g.tester.getRect(find.byKey(boardKey));
        await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
        _expectNotCut(g, _theirOfferText(l, 'Bob'), 'the choosing line');
        expect(
          g.tester.getRect(find.byKey(boardKey)),
          before,
          reason: g.why(
            'the board rect does not move when their offer arrives',
          ),
        );
        expect(g.tester.takeException(), isNull, reason: g.why('no overflow'));
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });

    testWidgets('C-676t G3c the declined line at 1.5 x 360 px is whole '
        '[${l.languageCode}]', (tester) async {
      final _G g = await table(tester, 'G3c declined');
      try {
        await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
        await g.push('release_declined', <String, Object?>{'seat': 1});
        _expectNotCut(g, _declinedText(l, 'Bob'), 'the declined line');
        expect(g.tester.takeException(), isNull, reason: g.why('no overflow'));
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });

    testWidgets('C-676t G3d the take line (everyone else) at 1.5 x 360 px is '
        'whole [${l.languageCode}]', (tester) async {
      final _G g = await table(tester, 'G3d took');
      try {
        await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
        await g.push('moved', _moved(1, 0));
        await g.push('sixes_granted', <String, Object?>{
          'seats': <int>[0],
        });
        _expectNotCut(g, _tookText(l, 'Bob'), 'the take line');
        expect(g.tester.takeException(), isNull, reason: g.why('no overflow'));
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });

    testWidgets('C-676t G3e the take line (you get a 6) at 1.5 x 360 px is '
        'whole [${l.languageCode}]', (tester) async {
      final _G g = await table(tester, 'G3e took granted');
      try {
        await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
        await g.push('moved', _moved(1, 0));
        await g.push('sixes_granted', <String, Object?>{
          'seats': <int>[0, 2],
        });
        _expectNotCut(g, _tookGrantedText(l, 'Bob'), 'the granted take line');
        expect(g.tester.takeException(), isNull, reason: g.why('no overflow'));
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });

    testWidgets('C-676t G3f the bonus line at 1.5 x 360 px is whole '
        '[${l.languageCode}]', (tester) async {
      final _G g = await table(
        tester,
        'G3f bonus',
        seats: const <int>[0, 1],
        me: 0,
        turn: _turnJson(1, 'await_roll'),
      );
      try {
        await g.push('turn', <String, Object?>{
          ..._turnJson(0, 'await_roll', queue: const <int>[6]),
          'banked': 1,
        });
        _expectNotCut(g, _bankedText(l), 'the bonus line');
        expect(g.tester.takeException(), isNull, reason: g.why('no overflow'));
      } finally {
        await releaseGame(g.tester, g.drive);
      }
    });
  }

  // ===========================================================================
  // G4: my clock is up
  // ===========================================================================

  _cases(
    'G4 with my turn clock up the pill is absent or not tappable and a tap '
    'sends nothing',
    (_G g) async {
      final SemanticsHandle handle = g.tester.ensureSemantics();
      try {
        await g.push(
          'rolled',
          _offerRolled(0, 4, const <int>[1, 3], deadline: 3000),
        );
        await g.pump(1000);
        expect(
          g.pill,
          isTrue,
          reason: g.why('fixture: the pill is live with time left (1000 ms)'),
        );
        await g.pump(2500);
        if (g.pill) {
          final SemanticsData d = g.tester
              .getSemantics(find.byKey(_pillKey))
              .getSemanticsData();
          final bool disabled =
              !d.hasAction(SemanticsAction.tap) ||
              d.flagsCollection.isEnabled == Tristate.isFalse;
          expect(
            disabled,
            isTrue,
            reason: g.why(
              'a drawn pill is not tappable in semantics once the clock is up',
            ),
          );
          await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
          await g.tester.pump();
        }
        expect(
          g.sent('decline_release'),
          isEmpty,
          reason: g.why('a tap after the clock is up sends nothing'),
        );
      } finally {
        handle.dispose();
      }
    },
    locales: const <Locale>[_en, _ar],
    turn: _turnJson(0, 'await_roll'),
  );
}
