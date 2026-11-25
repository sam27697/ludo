// C-717t: the defects the review of C-708 found (work/ludo/orders/
// 717t-tests-for-708-review-defects.md; docs/PROTOCOL.md section 35 items 5
// and 7, section 33 item 8). Written from the order, not from the fix.
//
// One rig: GameScreen over a real RoomController on FakeTransport, a
// four-seat 2026-11 room, me seat 0 the host, seat 2 a computer (`bot` 2).
// Every state is a decoded wire frame; only the socket and the feedback
// service are fakes. Time is the test clock in explicit pumps, never
// pumpAndSettle. Every failure line names the row, the locale, what was
// expected and every frame pushed and sent. Rerun one row:
//   cd packages/ludo_client && flock /tmp/ludo-suite.lock flutter test \
//     test/c708_review_test.dart --plain-name '<row name>'

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/die_cube.dart' show kThrowTumble;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const String _file = 'test/c708_review_test.dart';

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');
const List<Locale> _locales = <Locale>[_en, _ar];

const String _ruleset = '2026-11';
const List<int> _yard = <int>[-1, -1, -1, -1];
const int _me = 0;

Key _placeBotKey(int seat) => Key('end-card-place-bot-$seat');
Key _placeKey(int seat) => Key('end-card-place-$seat');
Key _readyKey(int seat) => Key('end-card-ready-$seat');
Key _readyBotKey(int seat) => Key('end-card-ready-bot-$seat');

int _wireIdSeq = 0;

String _wire(String type, Map<String, Object?> data, {String? re}) {
  _wireIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c717t-${_wireIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

String _typeOf(String raw) =>
    (jsonDecode(raw) as Map<String, Object?>)['t']! as String;

// =============================================================================
// The table rig
// =============================================================================

class _Seat {
  const _Seat(this.seat, this.name, {this.via = 'link', this.tokens = _yard})
    : bot = null;

  const _Seat.bot(this.seat, int this.bot, this.name)
    : via = 'bot',
      tokens = _yard;

  final int seat;
  final String name;
  final String via;
  final int? bot;
  final List<int> tokens;

  Map<String, Object?> toJson() => <String, Object?>{
    'seat': seat,
    'name': name,
    'connected': true,
    'tokens': tokens,
    'client_seed': null,
    'seed_origin': bot != null ? 'server' : null,
    'drought': 0,
    'via': via,
    'bot': ?bot,
  };

  @override
  String toString() => '$seat:$name/$via${bot == null ? '' : '/bot$bot'}';
}

/// The finished game's table: seat 1 a person, seat 2 a computer.
List<_Seat> _table({List<int> myTokens = _yard}) => <_Seat>[
  _Seat(0, 'Sam', via: 'host', tokens: myTokens),
  const _Seat(1, 'Bob'),
  const _Seat.bot(2, 2, 'Nono'),
  const _Seat(3, 'Dan', via: 'code'),
];

Map<String, Object?> _rollTurn(int seat, {Map<String, Object?>? pre}) =>
    <String, Object?>{
      'seat': seat,
      'phase': 'await_roll',
      'deadline_ms': rollTrayDeadlineMs,
      'k': 0,
      'queue': const <int>[],
      'pre': ?pre,
    };

/// A 4 with my tokens 0 and 1 legal (section 21.1 shape), `k` 1.
Map<String, Object?> _preCanMove() => <String, Object?>{
  'seat': _me,
  'value': 4,
  'legal': const <int>[0, 1],
  'k': 1,
  'queue': const <int>[4],
  'legal_by_face': <Map<String, Object?>>[
    faceLegal(4, const <int>[0, 1]),
  ],
};

/// A 3 with every token in the yard: the roll voids the turn.
Map<String, Object?> _preNoMove() => <String, Object?>{
  'seat': _me,
  'value': 3,
  'legal': const <int>[],
  'k': 1,
  'queue': const <int>[],
};

/// A six with my tokens 0 and 1 legal, `k` 1.
Map<String, Object?> _preSix() => <String, Object?>{
  'seat': _me,
  'value': 6,
  'legal': const <int>[0, 1],
  'k': 1,
  'queue': const <int>[6],
  'legal_by_face': <Map<String, Object?>>[
    faceLegal(6, const <int>[0, 1]),
  ],
};

/// The second roll after the six: a 2, tokens 0 and 1 legal, `k` 2.
Map<String, Object?> _preSecond() => <String, Object?>{
  'seat': _me,
  'value': 2,
  'legal': const <int>[0, 1],
  'k': 2,
  'queue': const <int>[2],
  'legal_by_face': <Map<String, Object?>>[
    faceLegal(2, const <int>[0, 1]),
  ],
};

/// The `rolled` broadcast for [pre] (section 35 item 2: field for field the
/// `pre`).
Map<String, Object?> _rolledOf(Map<String, Object?> pre) => <String, Object?>{
  ...pre,
  'deadline_ms': rollTrayDeadlineMs,
  'reveal': rollTrayReveal,
};

int get _tumbleMs => kThrowTumble.inMilliseconds;

/// The faces my die shows.
List<int> _faces() => <int>[
  for (int v = 1; v <= 6; v++)
    if (find
        .descendant(
          of: find.byKey(bigDieKey),
          matching: find.byKey(bigFaceKey(v)),
        )
        .evaluate()
        .isNotEmpty)
      v,
];

Map<String, Object?> _tableRoom({
  required List<_Seat> seats,
  required Map<String, Object?>? turn,
  int seq = 1,
  List<int> retired = const <int>[],
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': 'PLAYING',
  'host_seat': 0,
  'players': 4,
  'open': false,
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
  'seats': <Map<String, Object?>>[for (final _Seat s in seats) s.toJson()],
  'turn': turn,
  'winner': null,
  'seq': seq,
  'placings': const <int>[],
  'retired': retired,
};

class _Table {
  _Table(this.tester, this.drive, this.name, this.locale, this.setup);

  final WidgetTester tester;
  final RollTrayDrive drive;
  final String name;
  final Locale locale;
  final String setup;
  final List<String> steps = <String>[];
  int clockMs = 0;

  AppLocalizations get loc => lookupAppLocalizations(locale);

  RoomController get controller => drive.controller;

  List<String> get sent => sentTypesSince(drive.transport, 0);

  int sentCount(String type) => sent.where((String s) => s == type).length;

  String why(String expected) =>
      'C-717t "$name" [${locale.languageCode}] at ${clockMs}ms: expected '
      '$expected. Table: $setup. Steps: '
      '${steps.isEmpty ? '<none>' : steps.join(' -> ')}. Sent: $sent. Cues: '
      '${drive.feedback.recorded.map((FeedbackCue c) => c.id).toList()}. '
      'No seed; rerun: cd packages/ludo_client && flock /tmp/ludo-suite.lock '
      "flutter test $_file --plain-name '$name'";

  Future<void> pump(int ms, {int step = 50}) async {
    int left = ms;
    while (left > 0) {
      final int d = left < step ? left : step;
      await tester.pump(Duration(milliseconds: d));
      clockMs += d;
      left -= d;
    }
  }

  /// A frame in `seq` order (the harness numbers it).
  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add('push $type ${jsonEncode(data)} seq ${drive.lastSeq + 1}');
    await drive.push(tester, type, data);
  }

  /// A frame [gap] past the last `seq` this client was sent.
  Future<void> pushGap(String type, Map<String, Object?> data, int gap) async {
    drive.lastSeq += gap - 1;
    await push(type, data);
  }

  /// A frame without `seq`, optionally a reply to [re].
  Future<void> pushPlain(
    String type,
    Map<String, Object?> data, {
    String? re,
  }) async {
    steps.add('push $type ${jsonEncode(data)}${re == null ? '' : ' re'}');
    drive.transport.pushText(_wire(type, data, re: re));
    await tester.pump();
    await tester.pump();
  }

  /// A tap on my die; returns the `roll` frames it sent before any time
  /// passed.
  Future<int> tapDie() async {
    final int before = sentCount('roll');
    steps.add('tap game-die @${clockMs}ms');
    await tester.tap(find.byKey(bigDieKey), warnIfMissed: false);
    await tester.pump();
    return sentCount('roll') - before;
  }

  String lastSentId(String type) => requestIdOf(
    drive.transport.sentRaw.lastWhere((String r) => _typeOf(r) == type),
  );
}

Future<RollTrayDrive> _connectTable(
  WidgetTester tester,
  Map<String, Object?> room,
) async {
  final FakeTransport transport = FakeTransport();
  bool first = true;
  final RoomController controller = RoomController(
    serverUrl: Uri.parse('wss://c717t.invalid/ws'),
    connect: (Uri url) async {
      if (!first) {
        throw StateError('c717t table: a second connect was not expected');
      }
      first = false;
      return transport as WireTransport;
    },
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> created = controller.createRoom(name: 'Sam', players: 4);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = requestIdOf(transport.sentRaw.last);
  transport.pushText(
    _wire('seat_assigned', <String, Object?>{'seat': 0, 'seat_token': 'tok-0'}),
  );
  transport.pushText(_wire('room', room, re: id));
  await created;
  return RollTrayDrive(
    controller: controller,
    transport: transport,
    feedback: RecordingFeedback(),
    lastSeq: controller.room!.seq,
    enqueueTransport: (FakeTransport t) {},
  );
}

Future<void> _table4(
  WidgetTester tester, {
  required String name,
  required Locale locale,
  List<_Seat>? seats,
  Map<String, Object?>? turn,
  double height = 892,
  required Future<void> Function(_Table t) body,
}) async {
  tester.view.physicalSize = Size(412 * 2.625, height * 2.625);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final List<_Seat> s = seats ?? _table();
  final Map<String, Object?> room = _tableRoom(
    seats: s,
    turn: turn ?? _rollTurn(1),
  );
  final RollTrayDrive drive = await _connectTable(tester, room);
  await mountGame(tester, drive, locale: locale);
  final _Table t = _Table(
    tester,
    drive,
    name,
    locale,
    'seats $s, turn ${jsonEncode(room['turn'])}, host seat 0, me seat 0, '
    'ruleset $_ruleset',
  );
  await t.pump(1000);
  try {
    await body(t);
  } finally {
    await releaseGame(tester, drive);
  }
}

void _row(String row, Future<void> Function(WidgetTester, Locale, String) b) {
  for (final Locale l in _locales) {
    final String name = '$row [${l.languageCode}]';
    testWidgets(name, (WidgetTester tester) => b(tester, l, name));
  }
}

void _test(String row, Future<void> Function(WidgetTester, String) b) {
  testWidgets(row, (WidgetTester tester) => b(tester, row));
}

/// Ends the game on [t] and puts the rematch room up, whose seats are
/// [rematchSeats]; game_log requests are refused so the card does not wait
/// on them.
Future<void> _endAndRematch(_Table t, List<_Seat> rematchSeats) async {
  await t.push('game_over', <String, Object?>{
    'winner': 3,
    'verify_url': 'https://c717t.invalid/verify/1',
    'placings': const <int>[3, 0, 1, 2],
    'retired': const <int>[],
  });
  await t.pump(kEndCardHoldLimit.inMilliseconds + 300);
  for (final String raw in List<String>.of(t.drive.transport.sentRaw)) {
    if (_typeOf(raw) == 'game_log') {
      t.drive.transport.pushText(
        _wire('error', <String, Object?>{
          'code': 'RATE_LIMITED',
          'message': 'game_log',
        }, re: requestIdOf(raw)),
      );
    }
  }
  await t.pump(100);
  await t.push('room', <String, Object?>{
    ..._tableRoom(seats: rematchSeats, turn: null),
    'state': 'LOBBY',
    'chain_commit': 'b' * 64,
    'chain_index': 1,
    'rematch': <String, Object?>{
      'by': 0,
      'ready': const <int>[0],
    },
  });
  await t.pump(1500);
}

void main() {
  // ===========================================================================
  // Row 1: the end card marks the finished game and the room apart
  // ===========================================================================
  group('row 1: end card marks', () {
    _row('a computer in the finished game keeps its place mark; a person '
        'who takes the seat gets no ready mark, and the other way round', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        height: 1400,
        body: (t) async {
          // Seat 1 was Bob, a person; a computer holds it now. Seat 2 was a
          // computer; Eve, a person, holds it now.
          await _endAndRematch(t, const <_Seat>[
            _Seat(0, 'Sam', via: 'host'),
            _Seat.bot(1, 1, 'Zuzu'),
            _Seat(2, 'Eve', via: 'code'),
            _Seat(3, 'Dan', via: 'code'),
          ]);
          for (final int seat in <int>[1, 2]) {
            expect(
              find.byKey(_placeKey(seat)),
              findsOneWidget,
              reason: t.why('fixture: end-card-place-$seat on the end card'),
            );
            expect(
              find.byKey(_readyKey(seat)),
              findsOneWidget,
              reason: t.why('fixture: the ready chip end-card-ready-$seat'),
            );
          }
          expect(
            find.byKey(_placeBotKey(2)),
            findsOneWidget,
            reason: t.why(
              'end-card-place-bot-2: seat 2 was a computer in the finished '
              'game',
            ),
          );
          expect(
            find.byKey(_readyBotKey(2)),
            findsNothing,
            reason: t.why(
              'no end-card-ready-bot-2: a person holds seat 2 in the room now',
            ),
          );
          expect(
            find.byKey(_placeBotKey(1)),
            findsNothing,
            reason: t.why(
              'no end-card-place-bot-1: seat 1 was a person in the finished '
              'game',
            ),
          );
          expect(
            find.byKey(_readyBotKey(1)),
            findsOneWidget,
            reason: t.why(
              'end-card-ready-bot-1: a computer holds seat 1 in the room now',
            ),
          );
        },
      );
    });
  });

  // ===========================================================================
  // Row 4: my own `absent` retire is not terminal; `kicked` is
  // ===========================================================================
  group('row 4: own retire and resync', () {
    _test('absent retire of my seat in order, then a seq gap: the resync '
        'goes out and its snapshot brings the room up to date', (
      tester,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: _en,
        body: (t) async {
          await t.push('seat_retired', <String, Object?>{
            'seat': _me,
            'reason': 'absent',
            'host_seat': 0,
          });
          await t.pump(300);
          expect(
            find.byType(GameScreen),
            findsOneWidget,
            reason: t.why('the watching view stays after an absent retire'),
          );
          final int resumesBefore = t.sentCount('resume');
          await t.pushGap('turn', _rollTurn(1), 4);
          await t.pump(100);
          expect(
            t.sentCount('resume') - resumesBefore,
            1,
            reason: t.why(
              'one `resume` (the resync request) on the wire after a frame '
              '4 past my last one, my seat retired `absent`',
            ),
          );
          if (t.sentCount('resume') == resumesBefore) {
            return;
          }
          final int snapshotSeq = t.drive.lastSeq + 1;
          await t.pushPlain(
            'room',
            _tableRoom(
              seats: _table(),
              turn: _rollTurn(1),
              seq: snapshotSeq,
              retired: const <int>[_me],
            ),
            re: t.lastSentId('resume'),
          );
          await t.pump(300);
          expect(
            t.controller.room?.seq,
            snapshotSeq,
            reason: t.why('room.seq $snapshotSeq from the resync snapshot'),
          );
          expect(
            t.controller.hasDesynced,
            isFalse,
            reason: t.why('hasDesynced false once the snapshot landed'),
          );
        },
      );
    });

    _test('kicked retire of my seat 4 past my last frame starts no resync '
        'and sends no resume', (tester, name) async {
      await _table4(
        tester,
        name: name,
        locale: _en,
        body: (t) async {
          await t.pushGap('seat_retired', <String, Object?>{
            'seat': _me,
            'reason': 'kicked',
            'host_seat': 0,
          }, 4);
          await t.pump(300);
          expect(
            t.sentCount('resume'),
            0,
            reason: t.why('no `resume` after my own kicked retire with a gap'),
          );
          expect(
            t.controller.isResyncing,
            isFalse,
            reason: t.why('no resync in flight after my own kicked retire'),
          );
        },
      );
    });
  });

  // ===========================================================================
  // Row 3: a retired seat cannot roll from its `pre`
  // ===========================================================================
  group('row 3: retired seat cannot roll', () {
    _row('kicked retire of my seat 4 past my last frame clears pre and a tap '
        'within 500 ms sends no roll', (tester, locale, name) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        seats: _table(myTokens: const <int>[10, 20, -1, -1]),
        turn: _rollTurn(_me, pre: _preCanMove()),
        body: (t) async {
          expect(
            t.controller.pre,
            isNotNull,
            reason: t.why('fixture: my turn carries a pre'),
          );
          await t.pushGap('seat_retired', <String, Object?>{
            'seat': _me,
            'reason': 'kicked',
            'host_seat': 0,
          }, 4);
          expect(
            t.controller.pre,
            isNull,
            reason: t.why(
              'RoomController.pre null at once after my own seat_retired '
              '(kicked), no `kicked` yet',
            ),
          );
          final int atTap = await t.tapDie();
          await t.pump(500);
          expect(
            t.sentCount('roll'),
            0,
            reason: t.why(
              'no `roll` sent within 500 ms of a tap after my retire ($atTap '
              'at the tap itself)',
            ),
          );
          expect(
            atTap,
            0,
            reason: t.why(
              'no `roll` sent for a tap within 500 ms of my retire',
            ),
          );
        },
      );
    });
  });

  // ===========================================================================
  // Row 2: the echo of my landed pre during a resync
  // ===========================================================================
  group('row 2: echo during a resync', () {
    for (final bool canMove in <bool>[true, false]) {
      final FeedbackCue cue = canMove
          ? FeedbackCue.canMove
          : FeedbackCue.noMove;
      _row('${cue.id}: tap, land from pre, a seq gap starts a resync, then my '
          'rolled: ${cue.id} played once and the rolled is the pre echo', (
        tester,
        locale,
        name,
      ) async {
        final Map<String, Object?> pre = canMove ? _preCanMove() : _preNoMove();
        await _table4(
          tester,
          name: name,
          locale: locale,
          seats: _table(
            myTokens: canMove ? const <int>[10, 20, -1, -1] : _yard,
          ),
          turn: _rollTurn(_me, pre: pre),
          body: (t) async {
            final List<Frame> frames = <Frame>[];
            final sub = t.controller.frames.listen(frames.add);
            addTearDown(sub.cancel);
            final int before = cueCount(t.drive.feedback, cue);
            expect(
              await t.tapDie(),
              1,
              reason: t.why('fixture: one `roll` at the tap'),
            );
            await t.pump(_tumbleMs + 100, step: 5);
            expect(
              cueCount(t.drive.feedback, cue) - before,
              1,
              reason: t.why('fixture: ${cue.id} once when the die lands'),
            );
            await t.pushGap('seat_retired', <String, Object?>{
              'seat': 3,
              'reason': 'absent',
              'host_seat': 0,
            }, 4);
            await t.pump(50);
            expect(
              t.sentCount('resume'),
              1,
              reason: t.why(
                'fixture: a `resume` on the wire after the seq gap, unanswered',
              ),
            );
            await t.push('rolled', _rolledOf(pre));
            await t.pump(1500);
            expect(
              cueCount(t.drive.feedback, cue) - before,
              1,
              reason: t.why(
                '${cue.id} still played exactly once after my server `rolled` '
                'for k ${pre['k']} arrived during the resync',
              ),
            );
            final List<Frame> rolled = <Frame>[
              for (final Frame f in frames)
                if (f.type == 'rolled') f,
            ];
            expect(
              rolled,
              hasLength(1),
              reason: t.why('fixture: the rolled reached controller.frames'),
            );
            expect(
              t.controller.isPreEcho(rolled.single),
              isTrue,
              reason: t.why(
                'RoomController.isPreEcho true for the `rolled` of the landed '
                'pre, delivered while the resync is in flight',
              ),
            );
          },
        );
      });
    }
  });

  // ===========================================================================
  // Row 6: the second roll after a six lands from the new pre
  // ===========================================================================
  group('row 6: second roll after a six', () {
    _row('six from pre, move, then the next pre: the tap lands on it at the '
        'tumble minimum with no rolled delivered', (
      tester,
      locale,
      name,
    ) async {
      await _table4(
        tester,
        name: name,
        locale: locale,
        seats: _table(myTokens: const <int>[10, 20, -1, -1]),
        turn: _rollTurn(_me, pre: _preSix()),
        body: (t) async {
          expect(
            await t.tapDie(),
            1,
            reason: t.why('fixture: one `roll` at the first tap'),
          );
          await t.pump(_tumbleMs + 100, step: 5);
          expect(_faces(), <int>[
            6,
          ], reason: t.why('fixture: the die landed on the six'));
          t.steps.add('tap board-token-hit-0-0 @${t.clockMs}ms');
          await tester.tap(
            find.byKey(tokenHitKey(_me, 0)),
            warnIfMissed: false,
          );
          await tester.pump();
          expect(
            t.sentCount('move'),
            1,
            reason: t.why('fixture: one `move` for token 0'),
          );
          await t.push('rolled', _rolledOf(_preSix()));
          await t.push('moved', <String, Object?>{
            'seat': _me,
            'token': 0,
            'from': 10,
            'to': 16,
            'face': 6,
            'captured': const <Object?>[],
            'extra_roll': true,
          });
          await t.push('turn', <String, Object?>{
            'seat': _me,
            'phase': 'await_roll',
            'deadline_ms': rollTrayDeadlineMs,
            'queue': const <int>[],
            'pre': _preSecond(),
          });
          await t.pump(1500);
          final int rolledBefore = t.steps
              .where((String s) => s.startsWith('push rolled'))
              .length;
          expect(
            await t.tapDie(),
            1,
            reason: t.why('one `roll` at the second tap'),
          );
          await t.pump(_tumbleMs, step: 5);
          expect(
            _faces(),
            <int>[2],
            reason: t.why(
              'the die landed on the second pre (2) at the tumble minimum '
              '${_tumbleMs}ms, it shows ${_faces()}',
            ),
          );
          expect(
            t.steps.where((String s) => s.startsWith('push rolled')).length,
            rolledBefore,
            reason: t.why('no `rolled` delivered for the second roll'),
          );
        },
      );
    });
  });
}
