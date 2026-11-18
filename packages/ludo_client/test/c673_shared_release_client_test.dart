// Proofs for order C-673 (work/ludo/orders/673-shared-release-client.md,
// docs/PROTOCOL.md section 30): the shared release of ruleset 2026-12 in the
// client. Written from the order's numbered items and section 30 alone.
//
//   W  wire: rolled.offer, sixes_granted, release_declined, turn_passed
//      "released", turn.banked, decline_release (item 1)
//   M  my offer: rings, tap to take, the decline pill, texts, feedback (item 2)
//   O  the others' view and the take and decline notices (item 3)
//   B  my banked six (item 4)
//   R  reconnect (item 5)
//   L  layout: the pill and the notice never overlap, 320 px, text scale 2.0
//   U  2026-11 and the ruleset-less room are what they were
//
// A real GameScreen over a real RoomController on FakeTransport; every state
// is a decoded wire frame. There is no seed: every case is a fixed list of
// frames, and a failure line names the case, the locale, the ruleset, the
// fake milliseconds elapsed, what was expected, what was seen and every frame
// pushed, which is the whole reproduction:
//
//   flock /tmp/ludo-suite.lock flutter test \
//     test/c673_shared_release_client_test.dart --plain-name '<case name>'

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart' show TurnPhase;
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

// --- the order's keys and texts, verbatim ------------------------------------

const Key _pillKey = Key('release-decline-button');
const Key _offerNoticeKey = Key('release-offer-notice');
const Key _oldNoticeKey = Key('game-release-notice');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const String _shared = '2026-12';
const String _old = '2026-11';

const int _noticeMs = 2500;

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

String _old11Mine(Locale l) => l == _ar
    ? 'ما طلع معك 6 بعشر رميات. طلّع قطعة وحدة.'
    : 'No 6 in 10 rolls. Bring one piece out.';

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
  'chain_index': 0,
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
Map<String, Object?> _offerRolled(int seat, int value, List<int> legal) =>
    <String, Object?>{
      'seat': seat,
      'value': value,
      'legal': legal,
      'deadline_ms': rollTrayDeadlineMs,
      'k': 10,
      'reveal': rollTrayReveal,
      'queue': <int>[value],
      'release': true,
      'offer': true,
    };

/// Section 28 rule 2: a 2026-11 release, no offer.
Map<String, Object?> _plainReleaseRolled(
  int seat,
  int value,
  List<int> legal,
) => <String, Object?>{
  'seat': seat,
  'value': value,
  'legal': legal,
  'deadline_ms': rollTrayDeadlineMs,
  'k': 10,
  'reveal': rollTrayReveal,
  'queue': <int>[value],
  'release': true,
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
      'C-673t "$scenario" [${locale.languageCode}, ruleset ${ruleset ?? 'absent'}] '
      'at +${clockMs}ms: expected $expected; observed ${observed ?? _seen()}. '
      'Frames pushed in order: ${frames.isEmpty ? '<none>' : frames.join(' -> ')}. '
      'Fixed frames, no seed: replay with flock /tmp/ludo-suite.lock flutter '
      "test test/c673_shared_release_client_test.dart --plain-name '$scenario'.";

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

Set<String> _words(Finder f) {
  final List<String> parts = <String>[
    for (final Element e
        in find
            .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
            .evaluate())
      _norm((e.widget as RichText).text.toPlainText()),
  ];
  return <String>{...parts, _norm(parts.join('')), _norm(parts.join(' '))};
}

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
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c673t.invalid/ws'),
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
  transport.pushText(
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
    transport: transport,
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
    testWidgets('C-673t $name [${locale.languageCode}]', (tester) async {
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

/// Smallest semantics node with a tap action around the centre of [f], in dp
/// (the view runs at ratio 1, so device pixels are dp).
Size? _tapTarget(WidgetTester tester, Finder f) {
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
    if (n.getSemanticsData().hasAction(SemanticsAction.tap) &&
        r.contains(centre)) {
      if (best == null || r.width * r.height < best!.width * best!.height) {
        best = r.size;
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

Map<String, Object?> _grant(List<int>? seats) => <String, Object?>{
  'seats': ?seats,
};

void main() {
  // ===========================================================================
  // W: the wire
  // ===========================================================================

  _cases(
    'W1 the offer frame parses: offer true, release true, awaitMove, legal '
    'and queue from the frame',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      final t = g.controller.room!.turn!;
      expect(t.offer, isTrue, reason: g.why('turn.offer true after the offer'));
      expect(t.release, isTrue, reason: g.why('turn.release true'));
      expect(t.phase, TurnPhase.awaitMove, reason: g.why('phase awaitMove'));
      expect(t.legal, <int>[1, 3], reason: g.why('legal from the frame'));
      expect(t.queue, <int>[4], reason: g.why('queue from the frame'));
      expect(
        g.sentTypes().where((String s) => s == 'resume'),
        isEmpty,
        reason: g.why('the new keys cause no resync'),
      );
    },
    locales: const <Locale>[_en],
  );

  _cases(
    'W2 a release rolled without offer (a lapse and a 2026-11 release) leaves '
    'offer false',
    (_G g) async {
      await g.push('rolled', _plainReleaseRolled(0, 4, const <int>[1, 3]));
      expect(
        g.controller.room!.turn!.offer,
        isFalse,
        reason: g.why('offer false when the frame carries none, never null'),
      );
      expect(g.pill, isFalse, reason: g.why('no pill without an offer'));
    },
    locales: const <Locale>[_en],
  );

  _cases(
    'W3 an ordinary roll has offer false and the offer is cleared by the next '
    'turn frame',
    (_G g) async {
      expect(
        g.controller.room!.turn!.offer,
        isFalse,
        reason: g.why('a snapshot turn with no offer key reads false'),
      );
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await g.push('moved', _moved(0, 1));
      await g.push('turn_passed', <String, Object?>{
        'seat': 0,
        'reason': 'released',
      });
      await g.push('turn', _turnJson(1, 'await_roll'));
      expect(
        g.controller.room!.turn!.offer,
        isFalse,
        reason: g.why('offer false after turn_passed released and a turn'),
      );
      expect(
        g.controller.room!.turn!.seat,
        1,
        reason: g.why('the turn is seat 1 after the released pass'),
      );
      expect(g.pill, isFalse, reason: g.why('no pill after the pass'));
      expect(g.ringed(), isEmpty, reason: g.why('no rings after the pass'));
      expect(
        g.sentTypes().where((String s) => s == 'resume'),
        isEmpty,
        reason: g.why('turn_passed "released" is a known reason, no resync'),
      );
    },
    seats: const <int>[0, 1],
    locales: const <Locale>[_en],
  );

  _cases(
    'W4 sixes_granted and release_declined are accepted in sequence and keep '
    'the seq chain whole',
    (_G g) async {
      await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
      await g.push('release_declined', <String, Object?>{'seat': 1});
      await g.push('turn_passed', <String, Object?>{
        'seat': 1,
        'reason': 'no_legal_move',
      });
      await g.push('turn', _turnJson(2, 'await_roll'));
      await g.push('rolled', _offerRolled(2, 5, const <int>[0]));
      await g.push('moved', _moved(2, 0));
      await g.push('sixes_granted', <String, Object?>{
        'seats': <int>[0, 1],
      });
      expect(
        g.controller.room!.seq,
        g.drive.lastSeq,
        reason: g.why('room.seq follows every pushed frame'),
      );
      expect(
        g.sentTypes().where((String s) => s == 'resume'),
        isEmpty,
        reason: g.why('no resync for the new frame types'),
      );
    },
    seats: const <int>[0, 1, 2],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
    locales: const <Locale>[_en],
  );

  _cases(
    'W5 a snapshot turn with offer true reads offer true; seat banked is read',
    (_G g) async {
      final t = g.controller.room!.turn!;
      expect(t.offer, isTrue, reason: g.why('snapshot turn.offer true'));
      expect(t.release, isTrue, reason: g.why('snapshot turn.release true'));
      expect(
        g.controller.room!.seats.firstWhere((s) => s.seat == 1).banked,
        2,
        reason: g.why('seat 1 banked 2 from the snapshot'),
      );
      expect(
        g.controller.room!.seats.firstWhere((s) => s.seat == 0).banked,
        0,
        reason: g.why('seat 0 banked 0 from the snapshot'),
      );
    },
    turn: _turnJson(
      0,
      'await_move',
      legal: const <int>[1, 3],
      queue: const <int>[4],
      release: true,
      offer: true,
    ),
    banked: const <int, int>{1: 2},
    locales: const <Locale>[_en],
  );

  // ===========================================================================
  // M: my offer
  // ===========================================================================

  _cases('M1 my offer: texts, pill, rings on the releasable yard pieces', (
    _G g,
  ) async {
    await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
    final Locale l = g.locale;
    expect(g.ringed(), <int>[
      1,
      3,
    ], reason: g.why('rings on exactly tokens 1 and 3, as a release rings'));
    expect(
      find.byKey(_offerNoticeKey),
      findsOneWidget,
      reason: g.why('exactly one release-offer-notice'),
    );
    expect(
      _words(find.byKey(_offerNoticeKey)),
      contains(_norm(_myOfferText(l))),
      reason: g.why('the notice reads "${_myOfferText(l)}"'),
    );
    expect(
      find.byKey(_pillKey),
      findsOneWidget,
      reason: g.why('exactly one release-decline-button'),
    );
    expect(
      _words(find.byKey(_pillKey)),
      contains(_norm(_pillText(l))),
      reason: g.why('the pill reads "${_pillText(l)}"'),
    );
    expect(
      find.byKey(_oldNoticeKey),
      findsNothing,
      reason: g.why('the 2026-11 release notice is not also shown'),
    );
    await g.pump(3000);
    expect(
      g.pill,
      isTrue,
      reason: g.why('the pill stays while the offer is pending (3000 ms)'),
    );
    expect(g.ringed(), <int>[
      1,
      3,
    ], reason: g.why('the rings stay while the offer is pending (3000 ms)'));
  });

  _cases('M2 a tap on a ringed yard piece sends move with no face; on an '
      'unringed one sends nothing', (_G g) async {
    await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
    await g.tester.tap(find.byKey(tokenHitKey(0, 0)), warnIfMissed: false);
    await g.tester.pump();
    expect(
      g.sent('move'),
      isEmpty,
      reason: g.why('a tap on unringed token 0 sends no move'),
    );
    await g.tester.tap(find.byKey(tokenHitKey(0, 3)), warnIfMissed: false);
    await g.tester.pump();
    await g.tester.pump(const Duration(milliseconds: 400));
    final List<Map<String, Object?>> moves = g.sent('move');
    expect(
      moves,
      hasLength(1),
      reason: g.why('exactly one move after a tap on token 3', '$moves'),
    );
    expect(moves.single['token'], 3, reason: g.why('the move names token 3'));
    expect(
      moves.single.containsKey('face'),
      isFalse,
      reason: g.why('a release move carries no face', '${moves.single}'),
    );
    expect(
      g.sent('decline_release'),
      isEmpty,
      reason: g.why('taking the release sends no decline_release'),
    );
  });

  _cases('M3 the decline pill sends exactly decline_release with an empty '
      'body, once', (_G g) async {
    await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
    await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
    await g.tester.pump();
    await g.tester.pump(const Duration(milliseconds: 100));
    final List<Map<String, Object?>> sent = g.sent('decline_release');
    expect(
      sent,
      hasLength(1),
      reason: g.why('exactly one decline_release after one tap', '$sent'),
    );
    expect(
      sent.single,
      <String, Object?>{},
      reason: g.why('the decline_release body is {}', '${sent.single}'),
    );
    expect(
      g.sent('move'),
      isEmpty,
      reason: g.why('declining sends no move', '${g.sent('move')}'),
    );
    expect(
      g.sent('roll'),
      isEmpty,
      reason: g.why('declining sends no roll', '${g.sent('roll')}'),
    );
  });

  _cases('M4 the pill is at least 48x48 dp and carries a Semantics label', (
    _G g,
  ) async {
    final SemanticsHandle handle = g.tester.ensureSemantics();
    try {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await g.tester.pump();
      final Size? target = _tapTarget(g.tester, find.byKey(_pillKey));
      expect(
        target,
        isNotNull,
        reason: g.why('a tappable semantics node around the pill'),
      );
      expect(
        target!.width >= 48 && target.height >= 48,
        isTrue,
        reason: g.why('the pill tap target is at least 48x48 dp', '$target'),
      );
      final String label = g.tester.getSemantics(find.byKey(_pillKey)).label;
      expect(
        _norm(label),
        isNotEmpty,
        reason: g.why('the pill has a non-empty Semantics label', '"$label"'),
      );
    } finally {
      handle.dispose();
    }
  });

  _cases('M5 feedback: the offer fires one can_move, as the 2026-11 release '
      'does, and the decline fires only the generic tap', (_G g) async {
    final int mark = g.cues.length;
    await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
    expect(
      g.cueIds().skip(mark).toList(),
      <String>[FeedbackCue.canMove.id],
      reason: g.why(
        'exactly [can_move], the pattern the 2026-11 release notice fires',
      ),
    );
    final int before = g.cues.length;
    await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
    await g.tester.pump();
    await g.push('release_declined', <String, Object?>{'seat': 0});
    expect(
      g.cueIds().skip(before).toList(),
      <String>[FeedbackCue.tap.id],
      reason: g.why(
        'the decline fires exactly the generic [tap] cue and nothing else, '
        'got ${g.cueIds().skip(before)}',
      ),
    );
  });

  _cases('M6 after release_declined and the pass the pill and rings are gone', (
    _G g,
  ) async {
    await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
    await g.push('release_declined', <String, Object?>{'seat': 0});
    await g.push('turn_passed', <String, Object?>{
      'seat': 0,
      'reason': 'no_legal_move',
    });
    await g.push('turn', _turnJson(1, 'await_roll'));
    expect(g.pill, isFalse, reason: g.why('no pill after the decline'));
    expect(g.ringed(), isEmpty, reason: g.why('no rings after the decline'));
    expect(
      find.byKey(_offerNoticeKey),
      findsNothing,
      reason: g.why('no offer notice after the decline'),
    );
    expect(
      g.controller.room!.turn!.offer,
      isFalse,
      reason: g.why('offer false after the decline'),
    );
  });

  _cases('M7 the take clears the pill and rings and ends in the next seat', (
    _G g,
  ) async {
    await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
    await g.push('moved', _moved(0, 3));
    await g.push('sixes_granted', <String, Object?>{
      'seats': <int>[1],
    });
    await g.push('turn_passed', <String, Object?>{
      'seat': 0,
      'reason': 'released',
    });
    await g.push('turn', _turnJson(1, 'await_roll'));
    expect(g.pill, isFalse, reason: g.why('no pill after the take'));
    expect(g.ringed(), isEmpty, reason: g.why('no rings after the take'));
    expect(
      g.sent('roll'),
      isEmpty,
      reason: g.why('the taking seat does not roll again'),
    );
  });

  _cases(
    'M8 after the offer was answered the pill is absent and no decline is sent',
    (_G g) async {
      await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
      await g.push('release_declined', <String, Object?>{'seat': 0});
      await g.push('turn', _turnJson(1, 'await_roll'));
      expect(
        find.byKey(_pillKey),
        findsNothing,
        reason: g.why('the pill is gone once the offer was answered'),
      );
      expect(
        g.sent('decline_release'),
        isEmpty,
        reason: g.why('no decline_release was sent by the answer'),
      );
    },
    locales: const <Locale>[_en],
  );

  // ===========================================================================
  // O: the others' view
  // ===========================================================================

  _cases(
    'O1 another seat holds an offer: "{name}: no 6 in 10 rolls. '
    'Choosing...", no pill, no rings, no cue',
    (_G g) async {
      final int mark = g.cues.length;
      await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
      g.expectShows(_theirOfferText(g.locale, 'Bob'), 'seat 2 watching seat 1');
      expect(g.pill, isFalse, reason: g.why('no pill for a seat not offered'));
      expect(
        find.byKey(_offerNoticeKey),
        findsNothing,
        reason: g.why('the first-person offer notice is not shown to others'),
      );
      expect(g.ringed(), isEmpty, reason: g.why('no rings on my pieces'));
      expect(
        g.cueIds().skip(mark).toList(),
        isEmpty,
        reason: g.why('no cue for another seat\'s offer'),
      );
      await g.pump(3000);
      g.expectShows(
        _theirOfferText(g.locale, 'Bob'),
        'the choosing line holds while the offer is pending',
      );
      await g.tester.tap(find.byKey(tokenHitKey(2, 0)), warnIfMissed: false);
      await g.tester.pump();
      expect(
        g.sent('move'),
        isEmpty,
        reason: g.why(
          'a tap on my yard piece during their offer sends nothing',
        ),
      );
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'O2 release_declined: "{name} kept their pieces home." for 2500 ms',
    (_G g) async {
      await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
      await g.push('release_declined', <String, Object?>{'seat': 1});
      g.expectShows(_declinedText(g.locale, 'Bob'), 'after the decline');
      g.expectNotShows(
        _theirOfferText(g.locale, 'Bob'),
        'the choosing line is replaced',
      );
      await g.pump(_noticeMs - 200);
      g.expectShows(_declinedText(g.locale, 'Bob'), '200 ms before 2500 ms');
      await g.pump(400);
      g.expectNotShows(_declinedText(g.locale, 'Bob'), '200 ms after 2500 ms');
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'O3 a take, me granted: "{name} took the release. You get a 6." '
    'for 2500 ms',
    (_G g) async {
      await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
      await g.push('moved', _moved(1, 0));
      await g.push('sixes_granted', <String, Object?>{
        'seats': <int>[0, 2],
      });
      g.expectShows(_tookGrantedText(g.locale, 'Bob'), 'me in seats');
      g.expectNotShows(_tookText(g.locale, 'Bob'), 'the everyone variant');
      await g.pump(_noticeMs - 200);
      g.expectShows(_tookGrantedText(g.locale, 'Bob'), '200 ms before 2500 ms');
      await g.pump(400);
      g.expectNotShows(
        _tookGrantedText(g.locale, 'Bob'),
        '200 ms after 2500 ms',
      );
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'O4 a take, me not granted: "{name} took the release. Everyone else '
    'gets a 6." for 2500 ms',
    (_G g) async {
      await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
      await g.push('moved', _moved(1, 0));
      await g.push('sixes_granted', <String, Object?>{
        'seats': <int>[0],
      });
      g.expectShows(_tookText(g.locale, 'Bob'), 'me not in seats');
      g.expectNotShows(
        _tookGrantedText(g.locale, 'Bob'),
        'the granted variant',
      );
      await g.pump(_noticeMs - 200);
      g.expectShows(_tookText(g.locale, 'Bob'), '200 ms before 2500 ms');
      await g.pump(400);
      g.expectNotShows(_tookText(g.locale, 'Bob'), '200 ms after 2500 ms');
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'O5 a take with no other playing seat (seats omitted) still names '
    'the taker and no seat is promised a six',
    (_G g) async {
      await g.push('rolled', _offerRolled(1, 4, const <int>[0, 2]));
      await g.push('moved', _moved(1, 0));
      await g.push('sixes_granted', _grant(null));
      g.expectNotShows(
        _tookGrantedText(g.locale, 'Bob'),
        'no six is promised when seats is omitted',
      );
      expect(
        g.sentTypes().where((String s) => s == 'resume'),
        isEmpty,
        reason: g.why('a sixes_granted without seats is no resync'),
      );
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'O6 the others view never shows the lapse as an offer',
    (_G g) async {
      await g.push('rolled', _plainReleaseRolled(1, 4, const <int>[]));
      g.expectNotShows(_theirOfferText(g.locale, 'Bob'), 'a lapse');
      expect(g.pill, isFalse, reason: g.why('no pill on a lapse'));
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  // ===========================================================================
  // B: my banked six
  // ===========================================================================

  _cases(
    'B1 turn.banked 1: notice "Bonus 6 from the release." for 2500 ms '
    'and the six in the roll tray',
    (_G g) async {
      await g.push('turn', <String, Object?>{
        ..._turnJson(0, 'await_roll', queue: const <int>[6]),
        'banked': 1,
      });
      g.expectShows(_bankedText(g.locale), 'my banked six');
      expect(
        find.byKey(trayFaceKey(0, 6)),
        findsOneWidget,
        reason: g.why('the queued six is drawn in the tray (tray face 0, 6)'),
      );
      await g.pump(_noticeMs - 200);
      g.expectShows(_bankedText(g.locale), '200 ms before 2500 ms');
      await g.pump(400);
      g.expectNotShows(_bankedText(g.locale), '200 ms after 2500 ms');
      expect(
        find.byKey(trayFaceKey(0, 6)),
        findsOneWidget,
        reason: g.why('the six stays in the tray after the notice is gone'),
      );
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'B2 two banked sixes show two sixes in the tray, one notice',
    (_G g) async {
      await g.push('turn', <String, Object?>{
        ..._turnJson(0, 'await_roll', queue: const <int>[6, 6]),
        'banked': 2,
      });
      g.expectShows(_bankedText(g.locale), 'two banked sixes');
      expect(
        find.byKey(trayFaceKey(0, 6)),
        findsOneWidget,
        reason: g.why('six 0'),
      );
      expect(
        find.byKey(trayFaceKey(1, 6)),
        findsOneWidget,
        reason: g.why('six 1'),
      );
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'B3 a turn with a queued six but no banked key shows no bonus notice',
    (_G g) async {
      await g.push('turn', _turnJson(0, 'await_roll', queue: const <int>[6]));
      g.expectNotShows(_bankedText(g.locale), 'no turn.banked');
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'B4 another seat banked turn shows me no bonus notice',
    (_G g) async {
      await g.push('turn', <String, Object?>{
        ..._turnJson(1, 'await_roll', queue: const <int>[6]),
        'banked': 1,
      });
      g.expectNotShows(_bankedText(g.locale), 'the banked six is not mine');
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'B5 a banked six is spent like any queued six: a roll first (move in '
    'await_roll is refused by the server), then a six tap',
    (_G g) async {
      await g.push('turn', <String, Object?>{
        ..._turnJson(0, 'await_roll', queue: const <int>[6]),
        'banked': 1,
      });
      // PROTOCOL 29 rule 5 (the turn gate) holds in 2026-12: a tap right after
      // a turn-passing frame sends nothing. Wait for the gate, then tap.
      await g.pump(1500);
      await g.tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
      await g.tester.pump();
      expect(
        g.sent('roll'),
        hasLength(1),
        reason: g.why('the die still rolls first with a banked six queued'),
      );
      expect(
        g.sent('move'),
        isEmpty,
        reason: g.why('no move is sent from await_roll'),
      );
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
  );

  // ===========================================================================
  // R: reconnect
  // ===========================================================================

  Future<void> resumeWith(_G g, Map<String, Object?> room) async {
    g.drive.transport.endFromFarSide();
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
      next.sentRaw,
      isNotEmpty,
      reason: g.why('a resume request on the new transport'),
    );
    expect(
      frameType(next.sentRaw.last),
      'resume',
      reason: g.why('the first request is a resume'),
    );
    final String id = requestIdOf(next.sentRaw.last);
    g.frames.add('room(resume) ${jsonEncode(room['turn'])}');
    next.pushText(_frame('room', room, re: id));
    await g.tester.pump();
    await g.tester.pump();
    await g.tester.pump(const Duration(seconds: 1));
  }

  _cases('R1 a resume snapshot with my offer pending restores rings and the '
      'pill', (_G g) async {
    expect(g.pill, isFalse, reason: g.why('fixture: no pill before the loss'));
    await resumeWith(
      g,
      _roomJson(
        ruleset: _shared,
        seats: g.seats,
        me: g.me,
        seq: g.drive.lastSeq + 1,
        turn: _turnJson(
          0,
          'await_move',
          legal: const <int>[1, 3],
          queue: const <int>[4],
          release: true,
          offer: true,
        ),
      ),
    );
    expect(g.ringed(), <int>[
      1,
      3,
    ], reason: g.why('rings on tokens 1 and 3 restored'));
    expect(g.pill, isTrue, reason: g.why('the decline pill is restored'));
    g.expectShows(_pillText(g.locale), 'the restored pill');
    expect(
      g.controller.room!.turn!.offer,
      isTrue,
      reason: g.why('turn.offer true after the resume'),
    );
    await g.tester.tap(find.byKey(_pillKey), warnIfMissed: false);
    await g.tester.pump();
    expect(
      g.sent('decline_release').length,
      1,
      reason: g.why('the restored pill declines'),
    );
  });

  _cases(
    'R2 a resume snapshot for another seat offering shows the choosing '
    'line and no pill',
    (_G g) async {
      await resumeWith(
        g,
        _roomJson(
          ruleset: _shared,
          seats: g.seats,
          me: g.me,
          seq: g.drive.lastSeq + 1,
          turn: _turnJson(
            1,
            'await_move',
            legal: const <int>[0, 2],
            queue: const <int>[4],
            release: true,
            offer: true,
          ),
        ),
      );
      expect(g.pill, isFalse, reason: g.why('no pill for another seat'));
      expect(g.ringed(), isEmpty, reason: g.why('no rings on my pieces'));
      g.expectShows(
        _theirOfferText(g.locale, 'Bob'),
        'the others view restored',
      );
    },
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'R3 a snapshot seat banked is sixes not yet queued: my banked 2 on '
    'another seat\'s turn puts nothing in my tray',
    (_G g) async {
      await resumeWith(
        g,
        _roomJson(
          ruleset: _shared,
          seats: g.seats,
          me: g.me,
          seq: g.drive.lastSeq + 1,
          banked: const <int, int>{0: 2},
          turn: _turnJson(1, 'await_roll'),
        ),
      );
      expect(
        g.controller.room!.seats.firstWhere((s) => s.seat == 0).banked,
        2,
        reason: g.why('seat 0 banked 2 after the resume'),
      );
      expect(
        trayDieCount(g.tester),
        0,
        reason: g.why(
          'the banked sixes are not in the tray before my turn begins '
          '(PROTOCOL 30 rule 5: not yet queued)',
        ),
      );
      g.expectNotShows(_bankedText(g.locale), 'no bonus notice off my turn');
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'R4 a snapshot with my turn in await_roll and a queued six shows the '
    'six in the tray and no replayed pill',
    (_G g) async {
      await resumeWith(
        g,
        _roomJson(
          ruleset: _shared,
          seats: g.seats,
          me: g.me,
          seq: g.drive.lastSeq + 1,
          turn: _turnJson(0, 'await_roll', queue: const <int>[6]),
        ),
      );
      expect(
        find.byKey(trayFaceKey(0, 6)),
        findsOneWidget,
        reason: g.why('the banked six is a queued six after a resume'),
      );
      expect(g.pill, isFalse, reason: g.why('no pill: no offer pending'));
    },
    seats: const <int>[0, 1],
    me: 0,
    turn: _turnJson(1, 'await_roll'),
  );

  // ===========================================================================
  // L: layout
  // ===========================================================================

  for (final Locale l in <Locale>[_ar, _en]) {
    testWidgets(
      'C-673t L1 the pill does not overlap the notice at text scale 2.0 on '
      '320 px wide [${l.languageCode}]',
      (tester) async {
        final _G g = await _open(
          tester,
          scenario: 'L1 320px scale 2.0 [${l.languageCode}]',
          locale: l,
          width: 320,
          height: 700,
          textScale: 2.0,
          turn: _turnJson(0, 'await_roll'),
        );
        try {
          await g.push('rolled', _offerRolled(0, 4, const <int>[1, 3]));
          expect(
            find.byKey(_pillKey),
            findsOneWidget,
            reason: g.why('the pill is on screen'),
          );
          expect(
            find.byKey(_offerNoticeKey),
            findsOneWidget,
            reason: g.why('the notice is on screen'),
          );
          final Rect pill = g.tester.getRect(find.byKey(_pillKey));
          final Rect note = g.tester.getRect(find.byKey(_offerNoticeKey));
          expect(
            pill.overlaps(note),
            isFalse,
            reason: g.why(
              'pill and notice do not overlap',
              'pill $pill, notice $note',
            ),
          );
          expect(
            pill.left >= 0 && pill.right <= 320,
            isTrue,
            reason: g.why('the pill fits the 320 px width', '$pill'),
          );
          expect(
            note.left >= 0 && note.right <= 320,
            isTrue,
            reason: g.why('the notice fits the 320 px width', '$note'),
          );
          expect(
            g.tester.takeException(),
            isNull,
            reason: g.why('no layout overflow at scale 2.0 on 320 px'),
          );
        } finally {
          await releaseGame(g.tester, g.drive);
        }
      },
    );
  }

  // ===========================================================================
  // U: older rulesets are what they were
  // ===========================================================================

  _cases(
    'U1 2026-11: a release shows the old notice, no pill, no offer '
    'notice, one can_move',
    (_G g) async {
      final int mark = g.cues.length;
      await g.push('rolled', _plainReleaseRolled(0, 4, const <int>[1, 3]));
      expect(g.pill, isFalse, reason: g.why('no decline pill under 2026-11'));
      expect(
        find.byKey(_offerNoticeKey),
        findsNothing,
        reason: g.why('no release-offer-notice under 2026-11'),
      );
      g.expectShows(_old11Mine(g.locale), 'the 2026-11 notice text');
      expect(g.cueIds().skip(mark).toList(), <String>[
        FeedbackCue.canMove.id,
      ], reason: g.why('one can_move, as before'));
      expect(g.ringed(), <int>[1, 3], reason: g.why('rings as before'));
      expect(
        g.controller.room!.turn!.offer,
        isFalse,
        reason: g.why('offer false under 2026-11'),
      );
    },
    ruleset: _old,
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'U2 2026-11: a snapshot owing a release shows rings and no pill',
    (_G g) async {
      expect(g.ringed(), <int>[0, 2], reason: g.why('rings from the snapshot'));
      expect(g.pill, isFalse, reason: g.why('no pill under 2026-11'));
      expect(
        g.controller.room!.turn!.offer,
        isFalse,
        reason: g.why('offer false from a 2026-11 snapshot'),
      );
    },
    ruleset: _old,
    locales: const <Locale>[_en],
    turn: _turnJson(
      0,
      'await_move',
      legal: const <int>[0, 2],
      queue: const <int>[5],
      release: true,
    ),
  );

  _cases(
    'U3 2026-11: another seat release shows the old line and no '
    'choosing line',
    (_G g) async {
      await g.push('rolled', _plainReleaseRolled(1, 4, const <int>[0, 2]));
      expect(g.pill, isFalse, reason: g.why('no pill'));
      g.expectNotShows(_theirOfferText(g.locale, 'Bob'), 'the choosing line');
    },
    ruleset: _old,
    seats: const <int>[0, 1, 2],
    me: 2,
    turn: _turnJson(1, 'await_roll'),
  );

  _cases(
    'U4 a room with no ruleset key: a plain roll shows nothing of the '
    'shared release',
    (_G g) async {
      await g.push('rolled', <String, Object?>{
        'seat': 0,
        'value': 3,
        'legal': <int>[],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 1,
        'reveal': rollTrayReveal,
        'queue': <int>[],
      });
      expect(g.pill, isFalse, reason: g.why('no pill'));
      expect(
        find.byKey(_offerNoticeKey),
        findsNothing,
        reason: g.why('no offer notice'),
      );
      expect(
        g.controller.room!.seats.first.banked,
        0,
        reason: g.why('seat banked reads 0 where the snapshot sends none'),
      );
    },
    ruleset: null,
    locales: const <Locale>[_en],
    turn: _turnJson(0, 'await_roll'),
  );

  _cases(
    'U5 a turn with banked under 2026-11 shows no bonus notice',
    (_G g) async {
      await g.push('turn', <String, Object?>{
        ..._turnJson(0, 'await_roll', queue: const <int>[6]),
        'banked': 1,
      });
      g.expectNotShows(_bankedText(g.locale), 'banked is a 2026-12 key');
    },
    ruleset: _old,
    locales: const <Locale>[_en],
    turn: _turnJson(1, 'await_roll'),
  );
}
