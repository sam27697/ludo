// C-606 (order 606t): the rematch table names the people sitting at it. Written
// from work/ludo/orders/606-rematch-chips-live-names.md (D1, D2) alone, never
// from the implementation.
//
// Real GameScreen over a real RoomController on a FakeTransport, played to
// game_over and then to a rematch lobby (a `room` push with a `rematch` block,
// PROTOCOL 16.2), the road test/c605_rematch_join_test.dart takes. A friend
// who sits down after the game ended arrives as a `player_joined` frame, is
// readied by a `room` push whose `rematch.ready` lists him (PROTOCOL 16.3),
// and leaves by `player_left` (PROTOCOL 16.9).
//
// What the cases pin, by the order's letters:
//   a  Karim joins seat 1 at the rematch lobby: chip 1 reads "Karim" and its
//      semantics label is endRematchSeatWaiting('Karim'), then
//      endRematchSeatReady('Karim') after he readies; mine still reads "You"
//   b  host view, Lina ready and Karim not: the sits-out line names Karim
//   c  a finished game of three, Omar leaves, Karim takes seat 1: chip 1 says
//      Karim and never Omar, while the rest of the end card still names Omar
//   d  ar: the chip reads Karim inside the Arabic label, laid out right to left
//   e  unchanged: a plain two-seat rematch with no join, chip 2 "Lina", mine
//      "You" (green on a tree without the work)
// plus the ugly neighbours: a seat that changes hands twice in one lobby, two
// joiners named together in the host's line in seat order, the line gone once
// everyone is in, and no blank-named label anywhere (TalkBack reads a name).
//
// Time is the test clock: every wait is a pump of a stated length. Every
// failure reason names the scenario and carries the frames pushed and the
// pumps made so far (Scn.why), which is the whole recipe to replay it. Nothing
// here is random.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c606-rematch-live-names-test.invalid/ws';
const String _roomCode = 'K7M2QP';
const String _verifyUrl = 'https://provefair.app/v/c606-rematch-live-names';
const Key _sitsOutKey = Key('end-card-rematch-sits-out');
const Key _startKey = Key('end-card-rematch-start');
const Key _joinLineKey = Key('end-card-friend-joined-line');

Key _chipKey(int seat) => Key('end-card-ready-$seat');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c606-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

typedef _Seats = List<(int seat, String name)>;

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

/// A PLAYING room, or (with [rematchBy]) the section 16.2 rematch LOBBY that
/// follows its end: new chain, no game, no turn, `rematch {by, ready}`.
Map<String, Object?> _roomJson({
  required _Seats seats,
  required int seq,
  int? rematchBy,
  List<int>? ready,
}) {
  final bool lobby = rematchBy != null;
  return <String, Object?>{
    'code': _roomCode,
    'state': lobby ? 'LOBBY' : 'PLAYING',
    'host_seat': 0,
    'players': 4,
    'rules': <String, Object?>{
      'blocks': true,
      'capture_bonus': true,
      'turn_seconds': 45,
    },
    'chain_commit': (lobby ? 'b' : 'a') * 64,
    'chain_index': lobby ? 1 : 0,
    'game_id': lobby ? null : '7f3a9c1e5b2d4068',
    'client_seeds': lobby ? null : '0:sam-seed|2:friend-seed',
    'seats': <Map<String, Object?>>[
      for (final (int seat, String name) in seats) _seatJson(seat, name),
    ],
    'turn': lobby
        ? null
        : <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
    'winner': null,
    'seq': seq,
    if (lobby)
      'rematch': <String, Object?>{
        'by': rematchBy,
        'ready': ready ?? <int>[rematchBy],
      },
  };
}

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

class _QuietFeedback implements FeedbackService {
  @override
  void play(FeedbackCue cue) {}
}

/// A scenario's replay log: every frame pushed and every pump made.
class Scn {
  Scn(this.name);

  final String name;
  final List<String> steps = <String>[];

  void log(String step) => steps.add(step);

  String get why => 'scenario "$name"; steps so far: ${steps.join(' | ')}';
}

class _Rig {
  _Rig({
    required this.tester,
    required this.scn,
    required this.controller,
    required this.transport,
    required this.seq,
    required this.seats,
  });

  final WidgetTester tester;
  final Scn scn;
  final RoomController controller;
  final FakeTransport transport;

  /// The room seq the controller holds; the next state change carries +1.
  int seq;

  /// The seats of the live room as this rig last told the controller.
  _Seats seats;

  int elapsedMs = 0;
  final Set<String> _answered = <String>{};

  Future<void> pump([int ms = 0]) async {
    elapsedMs += ms;
    scn.log('pump ${ms}ms (t=${elapsedMs}ms)');
    await tester.pump(Duration(milliseconds: ms));
  }

  /// Bounded pumps of 250 ms chunks, so animations and timers run.
  Future<void> settle(int ms) async {
    int left = ms;
    while (left > 0) {
      final int step = left > 250 ? 250 : left;
      await pump(step);
      left -= step;
    }
    await pump();
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    seq += 1;
    final Map<String, Object?> full = <String, Object?>{...data, 'seq': seq};
    scn.log('push $type $full (t=${elapsedMs}ms)');
    transport.pushText(_frame(type: type, data: full));
    await tester.pump();
    await tester.pump();
  }

  /// One `player_joined` with the next seq, then time for the join to settle.
  Future<void> join(int seat, String name) async {
    seats = <(int, String)>[...seats, (seat, name)]
      ..sort(((int, String) a, (int, String) b) => a.$1.compareTo(b.$1));
    await push('player_joined', <String, Object?>{'seat': seat, 'name': name});
    await settle(1500);
  }

  /// One `player_left` (PROTOCOL 16.9 item 4 and section 18) for [seat].
  Future<void> left(int seat) async {
    seats = <(int, String)>[
      for (final (int s, String n) in seats)
        if (s != seat) (s, n),
    ];
    await push('player_left', <String, Object?>{'seat': seat, 'host_seat': 0});
    await settle(500);
  }

  /// A rematch-lobby `room` snapshot for the seats the rig holds, with
  /// [ready] in `rematch.ready` (asked by me, seat 0).
  Future<void> lobbyRoom(List<int> ready) async {
    seq += 1;
    scn.log('push room (rematch lobby, ready $ready, seats $seats)');
    transport.pushText(
      _frame(
        type: 'room',
        data: _roomJson(seats: seats, seq: seq, rematchBy: 0, ready: ready),
      ),
    );
    await tester.pump();
    await tester.pump();
    await settle(500);
  }

  Future<void> rolled(int seat, int k, int face) =>
      push('rolled', <String, Object?>{
        'seat': seat,
        'value': face,
        'legal': const <int>[0],
        'deadline_ms': 45000,
        'k': k,
        'reveal': 'c' * 64,
      });

  Future<void> gameOver(int winner) => push('game_over', <String, Object?>{
    'winner': winner,
    'verify_url': _verifyUrl,
  });

  /// A finished room with no transcript asks for game_log; refuse it so the
  /// card settles (the way test/c601_roll_history_test.dart does).
  Future<void> refuseGameLogs() async {
    for (final String raw in List<String>.of(transport.sentRaw)) {
      if (_typeOf(raw) == 'game_log' && _answered.add(_idOf(raw))) {
        scn.log('refuse game_log ${_idOf(raw)}');
        transport.pushText(
          _frame(
            type: 'error',
            re: _idOf(raw),
            data: <String, Object?>{
              'code': 'RATE_LIMITED',
              'message': 'game_log',
            },
          ),
        );
      }
    }
    await tester.pump();
    await tester.pump();
  }

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  /// What chip [seat] shows as text: every Text under it.
  List<String> chipTexts(int seat) => find
      .descendant(
        of: find.byKey(_chipKey(seat)),
        matching: find.byType(Text),
        matchRoot: true,
      )
      .evaluate()
      .map((Element e) => _textOf(e.widget as Text))
      .toList();

  /// Every semantics label whose box sits inside chip [seat]'s box.
  List<String> chipLabels(int seat) {
    final Rect chip = tester.getRect(find.byKey(_chipKey(seat))).inflate(0.5);
    return _semanticsIn(tester, chip);
  }

  /// The sits-out line's text, or null when the line is not there.
  String? get sitsOut {
    final Finder f = find.descendant(
      of: find.byKey(_sitsOutKey),
      matching: find.byType(Text),
      matchRoot: true,
    );
    if (f.evaluate().isEmpty) {
      return null;
    }
    return _textOf(f.evaluate().first.widget as Text);
  }
}

String _textOf(Text text) => text.data ?? text.textSpan?.toPlainText() ?? '';

/// Every non-empty semantics label whose centre lies inside [area].
List<String> _semanticsIn(WidgetTester tester, Rect area) {
  final SemanticsNode root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final List<String> out = <String>[];
  void walk(SemanticsNode node, Matrix4 parent) {
    final Matrix4 global = parent.clone();
    if (node.transform != null) {
      global.multiply(node.transform!);
    }
    if (node.label.isNotEmpty) {
      final Rect box = MatrixUtils.transformRect(global, node.rect);
      if (area.contains(box.center)) {
        out.add(node.label);
      }
    }
    node.visitChildren((SemanticsNode child) {
      walk(child, global);
      return true;
    });
  }

  walk(root, Matrix4.identity());
  return out;
}

/// Every semantics label in the whole tree.
List<String> _allLabels(WidgetTester tester) =>
    _semanticsIn(tester, const Rect.fromLTRB(-1e9, -1e9, 1e9, 1e9));

/// The strings of every Text under the EndCard that is not inside a ready chip,
/// the sits-out line or the join line: the card's names for the finished game.
List<String> _cardTextsOutsideChips(WidgetTester tester) {
  final Set<Key> skip = <Key>{
    for (int s = 0; s < 4; s++) _chipKey(s),
    _sitsOutKey,
    _joinLineKey,
  };
  final List<String> out = <String>[];
  for (final Element e
      in find
          .descendant(of: find.byType(EndCard), matching: find.byType(Text))
          .evaluate()) {
    bool skipped = false;
    e.visitAncestorElements((Element a) {
      if (a.widget.key != null && skip.contains(a.widget.key)) {
        skipped = true;
        return false;
      }
      return a.widget is! EndCard;
    });
    if (!skipped) {
      out.add(_textOf(e.widget as Text));
    }
  }
  return out;
}

typedef _Body = Future<void> Function(_Rig rig);

/// Mounts a GameScreen on a 4-seat room whose first game is played by [seats]
/// (me seat 0 "Sam"), ends it with [winner], pumps past the end hold and,
/// when [rematchBy] is given, opens a rematch lobby asked by that seat for
/// the seats still present after [leaveBeforeRematch] left. Then runs [body].
Future<void> _scenario(
  WidgetTester tester,
  String name,
  _Body body, {
  int? rematchBy = 0,
  Locale locale = const Locale('en'),
  _Seats seats = const <(int, String)>[(0, 'Sam'), (2, 'Lina')],
  int winner = 2,
  int? leaveBeforeRematch,
}) async {
  tester.view.physicalSize = const Size(390, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final SemanticsHandle semantics = tester.ensureSemantics();
  final Scn scn = Scn(name);
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  try {
    final Future<void> created = controller.createRoom(name: 'Sam', players: 4);
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    final String requestId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: requestId,
        data: _roomJson(seats: seats, seq: 1),
      ),
    );
    await created;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: buildAppTheme(),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: FeedbackScope(
          settings: FeedbackSettings.forTest(),
          service: _QuietFeedback(),
          child: GameScreen(controller: controller),
        ),
      ),
    );
    await tester.pump();
    final _Rig rig = _Rig(
      tester: tester,
      scn: scn,
      controller: controller,
      transport: transport,
      seq: 1,
      seats: seats,
    );
    scn.log(
      'mounted seats=$seats winner=$winner locale=${locale.languageCode}',
    );
    await rig.gameOver(winner);
    expect(
      controller.room?.state,
      RoomState.finished,
      reason: 'fixture: game_over must finish the room; ${scn.why}',
    );
    await rig.settle(kEndCardHoldLimit.inMilliseconds + 300);
    await rig.refuseGameLogs();
    if (leaveBeforeRematch != null) {
      await rig.left(leaveBeforeRematch);
    }
    if (rematchBy != null) {
      await rig.lobbyRoom(<int>[rematchBy]);
      await rig.settle(1000);
      expect(
        controller.room?.state,
        RoomState.lobby,
        reason: 'fixture: the rematch lobby is the live room; ${scn.why}',
      );
      expect(
        find.byKey(_chipKey(0)),
        findsOneWidget,
        reason:
            'fixture: the end card shows my ready chip in the rematch '
            'lobby; ${scn.why}',
      );
    }
    await body(rig);
  } finally {
    // Unmount first so no screen timer outlives the test, then release.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    controller.dispose();
    semantics.dispose();
  }
}

/// The chip of [seat] carries [name] as text and as its spoken label, and no
/// other chip text names a different person.
void _expectChip(
  _Rig rig,
  int seat, {
  required String shown,
  required String spoken,
  required String why,
}) {
  expect(
    find.byKey(_chipKey(seat)),
    findsOneWidget,
    reason: 'expected a ready chip end-card-ready-$seat; none found; $why',
  );
  expect(
    find.descendant(of: find.byKey(_chipKey(seat)), matching: find.text(shown)),
    findsOneWidget,
    reason:
        'C-606 D1: chip $seat must show "$shown"; its texts are '
        '${rig.chipTexts(seat)}; $why',
  );
  final List<String> labels = rig.chipLabels(seat);
  expect(
    labels,
    contains(spoken),
    reason:
        'C-606 D1: chip $seat must be spoken as "$spoken"; semantics labels '
        'inside it are $labels; $why',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- a: Karim joins at the rematch lobby -----------------------------------
  group('(a) Karim sits down at seat 1 of the rematch lobby, en', () {
    testWidgets('chip 1 shows Karim and is spoken "Karim: not yet"; mine still '
        'reads You, Lina stays Lina', (WidgetTester tester) async {
      await _scenario(tester, 'a-join-waiting', (_Rig rig) async {
        await rig.join(1, 'Karim');
        final AppLocalizations loc = rig.loc;
        expect(
          loc.endRematchSeatWaiting('Karim'),
          'Karim: not yet',
          reason: 'fixture: the en string is "{name}: not yet"',
        );
        _expectChip(
          rig,
          1,
          shown: 'Karim',
          spoken: loc.endRematchSeatWaiting('Karim'),
          why: rig.scn.why,
        );
        _expectChip(
          rig,
          0,
          shown: loc.seatYou,
          spoken: loc.endRematchSeatReady(loc.seatYou),
          why: rig.scn.why,
        );
        _expectChip(
          rig,
          2,
          shown: 'Lina',
          spoken: loc.endRematchSeatWaiting('Lina'),
          why: rig.scn.why,
        );
      });
    });

    testWidgets('once Karim readies, the chip is spoken "Karim: in"', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'a-join-then-ready', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.lobbyRoom(<int>[0, 1]);
        final AppLocalizations loc = rig.loc;
        _expectChip(
          rig,
          1,
          shown: 'Karim',
          spoken: loc.endRematchSeatReady('Karim'),
          why: rig.scn.why,
        );
        expect(
          rig.chipLabels(1),
          isNot(contains(loc.endRematchSeatWaiting('Karim'))),
          reason:
              'C-606 D1: a ready Karim is no longer spoken as not yet; '
              'labels ${rig.chipLabels(1)}; ${rig.scn.why}',
        );
      });
    });

    testWidgets('no label anywhere is a blank name: TalkBack reads a name, not '
        '": not yet"', (WidgetTester tester) async {
      await _scenario(tester, 'a-no-blank-label', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.lobbyRoom(<int>[0, 1]);
        final AppLocalizations loc = rig.loc;
        final List<String> labels = _allLabels(tester);
        for (final String blank in <String>[
          loc.endRematchSeatWaiting(''),
          loc.endRematchSeatReady(''),
        ]) {
          expect(
            labels.where((String l) => l.trim() == blank.trim()),
            isEmpty,
            reason:
                'C-606 D1 (P9): a chip is spoken with its name, never as '
                '"$blank"; semantics labels: $labels; ${rig.scn.why}',
          );
        }
      });
    });

    testWidgets('a seat that changes hands twice in one lobby shows the '
        'current sitter and never the earlier one', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'a-seat-changes-hands', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.lobbyRoom(<int>[0, 1]);
        await rig.left(1);
        await rig.join(1, 'Maya');
        final AppLocalizations loc = rig.loc;
        _expectChip(
          rig,
          1,
          shown: 'Maya',
          spoken: loc.endRematchSeatWaiting('Maya'),
          why: rig.scn.why,
        );
        expect(
          rig.chipTexts(1).where((String t) => t.contains('Karim')),
          isEmpty,
          reason:
              'C-606 D1: Karim left seat 1 and Maya sits there; chip 1 texts '
              '${rig.chipTexts(1)}; ${rig.scn.why}',
        );
        expect(
          rig.chipLabels(1).where((String l) => l.contains('Karim')),
          isEmpty,
          reason:
              'C-606 D1: nothing spoken on chip 1 names Karim any more; '
              'labels ${rig.chipLabels(1)}; ${rig.scn.why}',
        );
      });
    });
  });

  // --- b: the host's sits-out line --------------------------------------------
  group('(b) the host is told who the Start leaves out', () {
    testWidgets('me host, Lina ready, Karim not: the line names Karim', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'b-sits-out-karim', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.lobbyRoom(<int>[0, 2]);
        final AppLocalizations loc = rig.loc;
        expect(
          find.byKey(_startKey),
          findsOneWidget,
          reason: 'fixture: the host card offers Start; ${rig.scn.why}',
        );
        expect(
          find.byKey(_sitsOutKey),
          findsOneWidget,
          reason:
              'C-606 D1 (P5): expected end-card-rematch-sits-out naming '
              'Karim (seat 1 is not ready), found none; ${rig.scn.why}',
        );
        expect(
          rig.sitsOut,
          loc.endRematchSitsOut('Karim'),
          reason:
              'C-606 D1 (P5): the line must read '
              '"${loc.endRematchSitsOut('Karim')}"; got "${rig.sitsOut}"; '
              '${rig.scn.why}',
        );
      });
    });

    testWidgets('two joiners out together are named in seat order', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'b-sits-out-two', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.join(3, 'Maya');
        await rig.lobbyRoom(<int>[0, 2]);
        final AppLocalizations loc = rig.loc;
        expect(
          rig.sitsOut,
          loc.endRematchSitsOut('Karim, Maya'),
          reason:
              'C-606 D1 (P5): seats 1 and 3 are out, named ascending as '
              '"${loc.endRematchSitsOut('Karim, Maya')}"; got '
              '"${rig.sitsOut}"; ${rig.scn.why}',
        );
      });
    });

    testWidgets('Karim readies: the line no longer names him', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'b-sits-out-after-ready', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.join(3, 'Maya');
        await rig.lobbyRoom(<int>[0, 1, 2]);
        final AppLocalizations loc = rig.loc;
        expect(
          rig.sitsOut,
          loc.endRematchSitsOut('Maya'),
          reason:
              'C-606 D1 (P5): with Karim in, only Maya is left out; got '
              '"${rig.sitsOut}"; ${rig.scn.why}',
        );
      });
    });
  });

  // --- c: a seat that changed hands -------------------------------------------
  group('(c) Omar leaves, Karim takes seat 1', () {
    const _Seats three = <(int, String)>[(0, 'Sam'), (1, 'Omar'), (2, 'Lina')];

    // The "Omar left the table" line follows the live room and goes once the
    // seat is taken again; every other line is the finished game's.
    void expectCardKeepsOmar(_Rig rig, List<String> beforeAll, String phase) {
      final String gone = rig.loc.endLeft('Omar');
      final List<String> before = beforeAll
          .where((String t) => t != gone)
          .toList();
      final List<String> after = _cardTextsOutsideChips(rig.tester)
          .where((String t) => t != gone)
          .toList();
      expect(
        after.where((String t) => t.contains('Omar')),
        isNotEmpty,
        reason:
            'C-606 D1: $phase, the end card still names Omar (the winner) '
            'from the finished game; texts outside the chips: $after; '
            '${rig.scn.why}',
      );
      expect(
        after.where((String t) => t.contains('Omar')).toList(),
        before.where((String t) => t.contains('Omar')).toList(),
        reason:
            'C-606 D1: $phase, the end card reads the finished game\'s names '
            'exactly as before the swap; before $before, after $after; '
            '${rig.scn.why}',
      );
      expect(
        after.where((String t) => t.contains('Karim')).toList(),
        before.where((String t) => t.contains('Karim')).toList(),
        reason:
            'C-606 D1: $phase, the live name Karim must not leak into the '
            'finished game\'s title, winner or tiles; before $before, after '
            '$after; ${rig.scn.why}',
      );
    }

    testWidgets('Omar leaves in the rematch lobby: chip 1 says Karim, never '
        'Omar; the card still names Omar', (WidgetTester tester) async {
      await _scenario(tester, 'c-leave-in-lobby', seats: three, winner: 1, (
        _Rig rig,
      ) async {
        final List<String> before = _cardTextsOutsideChips(tester);
        expect(
          before.where((String t) => t.contains('Omar')),
          isNotEmpty,
          reason:
              'fixture: Omar won, so the end card names him; texts outside '
              'the chips: $before; ${rig.scn.why}',
        );
        expect(
          rig.chipTexts(1),
          contains('Omar'),
          reason:
              'fixture: before he leaves chip 1 is Omar\'s; texts '
              '${rig.chipTexts(1)}; ${rig.scn.why}',
        );
        await rig.left(1);
        await rig.join(1, 'Karim');
        final AppLocalizations loc = rig.loc;
        expectCardKeepsOmar(rig, before, 'after Karim sat down');
        _expectChip(
          rig,
          1,
          shown: 'Karim',
          spoken: loc.endRematchSeatWaiting('Karim'),
          why: rig.scn.why,
        );
        expect(
          rig.chipTexts(1).where((String t) => t.contains('Omar')),
          isEmpty,
          reason:
              'C-606 D1: Karim holds seat 1 now, chip 1 must not read '
              'Omar; texts ${rig.chipTexts(1)}; ${rig.scn.why}',
        );
        expect(
          rig.chipLabels(1).where((String l) => l.contains('Omar')),
          isEmpty,
          reason:
              'C-606 D1: chip 1 is not spoken as Omar; labels '
              '${rig.chipLabels(1)}; ${rig.scn.why}',
        );
      });
    });

    testWidgets('Omar leaves before the rematch is asked: the same', (
      WidgetTester tester,
    ) async {
      await _scenario(
        tester,
        'c-leave-before-rematch',
        seats: three,
        winner: 1,
        leaveBeforeRematch: 1,
        (_Rig rig) async {
          final List<String> before = _cardTextsOutsideChips(tester);
          await rig.join(1, 'Karim');
          final AppLocalizations loc = rig.loc;
          expectCardKeepsOmar(rig, before, 'after Karim sat down');
          _expectChip(
            rig,
            1,
            shown: 'Karim',
            spoken: loc.endRematchSeatWaiting('Karim'),
            why: rig.scn.why,
          );
          expect(
            rig.chipTexts(1).where((String t) => t.contains('Omar')),
            isEmpty,
            reason:
                'C-606 D1: chip 1 must not read the departed Omar; texts '
                '${rig.chipTexts(1)}; ${rig.scn.why}',
          );
        },
      );
    });

    testWidgets('the host line after the swap names Karim, never Omar', (
      WidgetTester tester,
    ) async {
      await _scenario(
        tester,
        'c-sits-out-after-swap',
        seats: three,
        winner: 1,
        (_Rig rig) async {
          await rig.left(1);
          await rig.join(1, 'Karim');
          await rig.lobbyRoom(<int>[0, 2]);
          expect(
            rig.sitsOut,
            rig.loc.endRematchSitsOut('Karim'),
            reason:
                'C-606 D1 (P5): the Start leaves Karim out, not Omar; got '
                '"${rig.sitsOut}"; ${rig.scn.why}',
          );
        },
      );
    });
  });

  // --- d: Arabic --------------------------------------------------------------
  group('(d) the same join in Arabic, laid out right to left', () {
    testWidgets('chip 1 reads Karim inside the Arabic label; the row runs '
        'right to left', (WidgetTester tester) async {
      await _scenario(tester, 'd-ar-join', locale: const Locale('ar'), (
        _Rig rig,
      ) async {
        await rig.join(1, 'Karim');
        final AppLocalizations loc = rig.loc;
        expect(loc.localeName, 'ar', reason: 'fixture: the harness is ar');
        expect(
          loc.endRematchSeatWaiting('Karim'),
          'Karim: ليس بعد',
          reason: 'fixture: the ar string is "{name}: ليس بعد"',
        );
        _expectChip(
          rig,
          1,
          shown: 'Karim',
          spoken: loc.endRematchSeatWaiting('Karim'),
          why: rig.scn.why,
        );
        expect(
          Directionality.of(tester.element(find.byKey(_chipKey(1)))),
          TextDirection.rtl,
          reason: 'the chip is laid out right to left; ${rig.scn.why}',
        );
        final double dx0 = tester.getCenter(find.byKey(_chipKey(0))).dx;
        final double dx1 = tester.getCenter(find.byKey(_chipKey(1))).dx;
        final double dx2 = tester.getCenter(find.byKey(_chipKey(2))).dx;
        final double dy0 = tester.getCenter(find.byKey(_chipKey(0))).dy;
        final double dy1 = tester.getCenter(find.byKey(_chipKey(1))).dy;
        final double dy2 = tester.getCenter(find.byKey(_chipKey(2))).dy;
        final bool sameRow = (dy0 - dy1).abs() < 2 && (dy1 - dy2).abs() < 2;
        if (sameRow) {
          expect(
            <bool>[dx0 > dx1, dx1 > dx2],
            <bool>[true, true],
            reason:
                'C-606 D2: chip order is unchanged, seat 0 first at the '
                'right; centres x0=$dx0 x1=$dx1 x2=$dx2; ${rig.scn.why}',
          );
        }
        expect(
          rig.chipLabels(1).where((String l) => l.startsWith(': ')),
          isEmpty,
          reason:
              'C-606 D1 (P9): no chip is spoken without its name; labels '
              '${rig.chipLabels(1)}; ${rig.scn.why}',
        );
      });
    });

    testWidgets('ar: the host line names Karim', (WidgetTester tester) async {
      await _scenario(tester, 'd-ar-sits-out', locale: const Locale('ar'), (
        _Rig rig,
      ) async {
        await rig.join(1, 'Karim');
        await rig.lobbyRoom(<int>[0, 2]);
        expect(
          rig.sitsOut,
          rig.loc.endRematchSitsOut('Karim'),
          reason:
              'C-606 D1 (P5): the ar line names Karim; got '
              '"${rig.sitsOut}"; ${rig.scn.why}',
        );
      });
    });
  });

  // --- e: unchanged -----------------------------------------------------------
  group('(e) a plain two-seat rematch with no join is unchanged', () {
    testWidgets('chip 2 says Lina and is spoken "Lina: not yet"; chip 0 says '
        'You and is spoken "You: in"', (WidgetTester tester) async {
      await _scenario(tester, 'e-plain-two-seats', (_Rig rig) async {
        final AppLocalizations loc = rig.loc;
        _expectChip(
          rig,
          2,
          shown: 'Lina',
          spoken: loc.endRematchSeatWaiting('Lina'),
          why: rig.scn.why,
        );
        _expectChip(
          rig,
          0,
          shown: loc.seatYou,
          spoken: loc.endRematchSeatReady(loc.seatYou),
          why: rig.scn.why,
        );
        expect(
          find.byKey(_chipKey(1)),
          findsNothing,
          reason: 'no one sits at seat 1, so no chip; ${rig.scn.why}',
        );
      });
    });

    testWidgets('Lina readies: her chip is spoken "Lina: in"', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'e-lina-readies', (_Rig rig) async {
        await rig.lobbyRoom(<int>[0, 2]);
        final AppLocalizations loc = rig.loc;
        _expectChip(
          rig,
          2,
          shown: 'Lina',
          spoken: loc.endRematchSeatReady('Lina'),
          why: rig.scn.why,
        );
      });
    });

    testWidgets('the host line names Lina when she is the one not ready', (
      WidgetTester tester,
    ) async {
      await _scenario(
        tester,
        'e-sits-out-lina',
        seats: const <(int, String)>[(0, 'Sam'), (1, 'Omar'), (2, 'Lina')],
        winner: 1,
        (_Rig rig) async {
          await rig.lobbyRoom(<int>[0, 1]);
          expect(
            rig.sitsOut,
            rig.loc.endRematchSitsOut('Lina'),
            reason:
                'C-606 D2: with no change of hands the line names Lina as '
                'before; got "${rig.sitsOut}"; ${rig.scn.why}',
          );
        },
      );
    });
  });
}
