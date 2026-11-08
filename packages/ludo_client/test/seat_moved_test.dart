// Proof for work/ludo/orders/592-seat-moved-host-wiring-x161.md, D1 to D3: a
// seat that the server moves is told its new colour at the next game, and
// the end card learns the host. Written from that contract alone, against a
// RoomController and a GameScreen over FakeTransport
// (test/support/roll_tray_harness.dart); every state arrives as a decoded
// wire frame, in the order docs/PROTOCOL.md section 16.4 gives: `player_left`
// for each seat that sits out, `seat_assigned` to each seat whose number
// changed, the `room`, then the start order (`game_started`, `turn`).
//
// RoomController.seatMovedFrom and clearSeatMoved are read through dynamic
// helpers, so that this file compiles on a tree that does not have them yet;
// on such a tree the controller cases fail with a message naming the missing
// member, and the screen cases run and fail on what they observe. The
// gameSeatMoved string exists in both arb files already, and the expected
// lines are written out here as literals from the arb text (a getter-vs-getter
// comparison would pass a wrong word in the arb file), with one case that
// checks the literals against the generated getter.
//
// Keys named by the contract:
//   game-seat-moved-notice   the row in the below-die notice slot (D2)
//   game-no-move-notice      my own dead end, which outranks it
//   end-card-rematch-may-start   the slow friend's warning (C-591), D3
//
// Ambiguities, reported and not invented around:
//   1. "seatMovedFrom is null" after the arrival is read right after the
//      arrival frames and again after the notice ends; the contract says the
//      arrival calls clearSeatMoved, not when relative to the first build.
//   2. A host seat outside 0..3 (D3's null) cannot be pushed: the snapshot
//      parser is not the unit under test and a frame like that is not a
//      valid room. That branch is not covered here.
//   3. The seats a move reaches on the real server are canonical, so no
//      server moves a seat to red (seat 0 is the host and never moves) or to
//      blue (the canonical sets for fewer than four players never hold seat
//      3). The red and blue cases push the frame a client could still be
//      sent, to pin the seat to word map; they are labelled so below.
//
// Every failure reason names the scenario and ends with the frames and pumps
// that led to it. The cases are deterministic, so the scenario is the whole
// reproduction; there is no seed.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const Key _noticeKey = Key('game-seat-moved-notice');
const Key _mayStartKey = Key('end-card-rematch-may-start');

/// D2: the notice is armed for 4000 ms.
const int _noticeMs = 4000;

const String _gameA = 'a1a1a1a1a1a1a1a1';
const String _gameB = 'b2b2b2b2b2b2b2b2';

const String _startedEn = 'The game has started';
const String _startedAr = 'بدأت اللعبة';

const Map<int, String> _names = <int, String>{
  0: 'Ann',
  1: 'Bob',
  2: 'Cara',
  3: 'Dan',
};

// --- the expected lines, from the arb text ---------------------------------

const Map<String, String> _wordsEn = <String, String>{
  'red': 'red',
  'green': 'green',
  'yellow': 'yellow',
  'blue': 'blue',
};

const Map<String, String> _wordsAr = <String, String>{
  'red': 'الأحمر',
  'green': 'الأخضر',
  'yellow': 'الأصفر',
  'blue': 'الأزرق',
};

String _movedLine(Locale locale, String colour) => locale.languageCode == 'ar'
    ? 'تغيّر مقعدك. لونك في هذه الجولة: ${_wordsAr[colour]}'
    : 'Your seat moved. Your pieces are now ${_wordsEn[colour]}';

String _startedLine(Locale locale) =>
    locale.languageCode == 'ar' ? _startedAr : _startedEn;

// --- the controller members under test, dynamic on purpose -----------------

int? _movedFrom(RoomController controller) {
  try {
    return (controller as dynamic).seatMovedFrom as int?;
  } on NoSuchMethodError {
    fail(
      'RoomController.seatMovedFrom does not exist (D1 expects an int? '
      'getter on RoomController)',
    );
  }
}

void _clearMoved(RoomController controller) {
  try {
    (controller as dynamic).clearSeatMoved();
  } on NoSuchMethodError {
    fail(
      'RoomController.clearSeatMoved() does not exist (D1 expects a void '
      'method on RoomController)',
    );
  }
}

// --- frames ------------------------------------------------------------------

int _serverIdSeq = 0;

String _rawFrame(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'seat-moved-srv-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

List<Map<String, Object?>> _seatsOf(Iterable<int> seats) =>
    <Map<String, Object?>>[
      for (final int seat in (seats.toList()..sort()))
        seatJson(seat, name: _names[seat]!),
    ];

Map<String, Object?> _rematchJson(int by, List<int> ready) => <String, Object?>{
  'by': by,
  'ready': ready,
};

/// A room snapshot body; RollTrayDrive.push stamps the sequence number.
Map<String, Object?> _roomBody({
  required String state,
  required int hostSeat,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? rematch,
  String? gameId,
  int chainIndex = 0,
  Map<String, Object?>? turn,
  int? winner,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': hostSeat,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': (chainIndex.isEven ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': gameId,
  'client_seeds': null,
  'seats': seats,
  'turn': turn,
  'winner': winner,
  'rematch': rematch,
};

// --- scenario bookkeeping ----------------------------------------------------

String _brief(String type, Map<String, Object?> data) {
  if (type != 'room') {
    return '$type ${jsonEncode(data)}';
  }
  final List<Object?> seats = data['seats']! as List<Object?>;
  return 'room state=${data['state']} host=${data['host_seat']} '
      'players=${data['players']} '
      'seats=${[for (final Object? s in seats) (s! as Map)['seat']]} '
      'rematch=${jsonEncode(data['rematch'])}';
}

class _Run {
  _Run(this.name, this.tester, this.drive);

  final String name;
  final WidgetTester tester;
  final RollTrayDrive drive;
  final List<String> steps = <String>[];
  final List<String> deferred = <String>[];

  String why(String expected) =>
      '$name | expected: $expected | replay: ${steps.join(' > ')}';

  /// A controller-member check that must not hide the screen checks after it
  /// on a tree without the member: recorded now, failed by [finish].
  void expectMovedFrom(RoomController controller, int? expected, String what) {
    Object? seen;
    try {
      seen = (controller as dynamic).seatMovedFrom;
    } on NoSuchMethodError {
      seen = 'RoomController.seatMovedFrom does not exist';
    }
    if (seen != expected) {
      deferred.add(
        'expected seatMovedFrom $expected ($what), got $seen | after: '
        '${steps.join(' > ')}',
      );
    }
  }

  void finish() {
    expect(
      deferred,
      isEmpty,
      reason: '$name | controller checks that failed: $deferred',
    );
  }

  Future<void> push(String type, Map<String, Object?> data) async {
    steps.add(_brief(type, data));
    await drive.push(tester, type, data);
  }

  Future<void> pushRawFrame(String type, Map<String, Object?> data) async {
    steps.add('${_brief(type, data)} (no seq)');
    await pushRaw(tester, drive, _rawFrame(type, data));
  }

  Future<void> pump(int ms) async {
    steps.add('pump ${ms}ms');
    await tester.pump(Duration(milliseconds: ms));
  }
}

class _Announcements {
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
  }

  void remove(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    );
  }
}

/// One re-seating: I am seat [me]; [remap] maps every surviving seat to its
/// number after the start; [gone] sit out; [colour] is the word for my new
/// seat.
class _Move {
  const _Move(
    this.label, {
    required this.me,
    required this.remap,
    required this.gone,
    required this.colour,
  });

  final String label;
  final int me;
  final Map<int, int> remap;
  final List<int> gone;
  final String colour;

  int get to => remap[me]!;
  List<int> get before => <int>[...remap.keys, ...gone]..sort();
  List<int> get survivors => remap.keys.toList()..sort();
  List<int> get after => remap.values.toList()..sort();

  /// The turn goes to a seat that is not mine, so no your-turn cue or
  /// dead-end line of my own competes with the notice.
  int get otherAfter => after.firstWhere((int s) => s != to);

  @override
  String toString() => label;
}

/// The realistic case, from the contract: four seats, I was blue (3), seat 2
/// sits out, the rest are re-seated onto [0, 1, 2] and I am yellow.
const _Move _yellow = _Move(
  'seat 3 to 2 (blue to yellow)',
  me: 3,
  remap: <int, int>{0: 0, 1: 1, 3: 2},
  gone: <int>[2],
  colour: 'yellow',
);

/// Also server-reachable: seat 1 sits out and seat 2 becomes seat 1.
const _Move _green = _Move(
  'seat 2 to 1 (yellow to green)',
  me: 2,
  remap: <int, int>{0: 0, 2: 1, 3: 2},
  gone: <int>[1],
  colour: 'green',
);

/// Not reachable on a real server (seat 0 is the host and never moves); the
/// frame a client could still be sent.
const _Move _red = _Move(
  'seat 1 to 0 (green to red, unreachable on a real server)',
  me: 1,
  remap: <int, int>{1: 0, 2: 1},
  gone: <int>[0, 3],
  colour: 'red',
);

/// Not reachable on a real server (canonical sets for fewer than four players
/// never hold seat 3).
const _Move _blue = _Move(
  'seat 1 to 3 (green to blue, unreachable on a real server)',
  me: 1,
  remap: <int, int>{0: 0, 1: 3},
  gone: <int>[2, 3],
  colour: 'blue',
);

/// My seat does not move: I am seat 1, seat 2 sits out, seat 3 becomes 2.
const _Move _stays = _Move(
  'seat 1 stays 1',
  me: 1,
  remap: <int, int>{0: 0, 1: 1, 3: 2},
  gone: <int>[2],
  colour: 'green',
);

Future<_Run> _finishedTable(
  WidgetTester tester,
  String name,
  _Move move, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) async {
  final RollTrayDrive drive = await connectPlaying(
    tester,
    mySeat: move.me,
    players: 4,
    turn: null,
    seats: _seatsOf(move.before),
    gameId: _gameA,
    state: 'FINISHED',
    winner: 0,
  );
  await mountGame(tester, drive, locale: locale, textScale: textScale);
  return _Run(name, tester, drive);
}

/// The rematch LOBBY with every survivor ready, then the host's start up to
/// and including the re-seating `room`: player_left per seat that sits out,
/// seat_assigned when my number changes, the room.
Future<void> _hostStartsRematch(_Run run, _Move move) async {
  final int hostAfter = move.after.first;
  await run.push(
    'room',
    _roomBody(
      state: 'LOBBY',
      hostSeat: 0,
      players: 4,
      seats: _seatsOf(move.before),
      rematch: _rematchJson(0, move.survivors),
      chainIndex: 1,
    ),
  );
  for (final int seat in move.gone) {
    await run.push('player_left', <String, Object?>{'seat': seat});
  }
  if (move.to != move.me) {
    await run.pushRawFrame('seat_assigned', <String, Object?>{
      'seat': move.to,
      'seat_token': 'tok-moved',
    });
  }
  await run.push(
    'room',
    _roomBody(
      state: 'LOBBY',
      hostSeat: hostAfter,
      players: move.after.length,
      seats: <Map<String, Object?>>[
        for (final int seat in move.survivors)
          seatJson(move.remap[seat]!, name: _names[seat]!),
      ]..sort((a, b) => (a['seat']! as int).compareTo(b['seat']! as int)),
      rematch: _rematchJson(hostAfter, move.after),
      chainIndex: 1,
    ),
  );
}

/// The start order: game_started (a new game id) and the first turn.
Future<void> _startOrder(_Run run, int turnSeat) async {
  await run.push('game_started', <String, Object?>{
    'turn': turnSeat,
    'game_id': _gameB,
    'client_seeds': '0:seed',
  });
  await run.push('turn', <String, Object?>{
    'seat': turnSeat,
    'phase': 'await_roll',
    'deadline_ms': rollTrayDeadlineMs,
    'queue': <int>[],
  });
}

// --- reading the screen ------------------------------------------------------

String? _noticeText(WidgetTester tester) {
  final Finder notice = find.byKey(_noticeKey);
  if (notice.evaluate().isEmpty) {
    return null;
  }
  final Widget root = tester.widget(notice);
  if (root is Text) {
    return root.data ?? root.textSpan?.toPlainText();
  }
  final StringBuffer out = StringBuffer();
  for (final Element e
      in find.descendant(of: notice, matching: find.byType(Text)).evaluate()) {
    final Text text = e.widget as Text;
    out.write(text.data ?? text.textSpan?.toPlainText() ?? '');
  }
  return out.toString();
}

bool _noticeUp(WidgetTester tester) => tester.any(find.byKey(_noticeKey));

/// The slot is the nearest Stack above the "No move" placeholder text, which
/// is always in the slot's Stack as an invisible measuring child.
Finder _slotFinder(WidgetTester tester) {
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byKey(boardKey)),
  );
  return find
      .ancestor(
        of: find.text(loc.gameNoMove).first,
        matching: find.byType(Stack),
      )
      .first;
}

Text _noticeTextWidget(WidgetTester tester) {
  final Finder notice = find.byKey(_noticeKey);
  final Widget root = tester.widget(notice);
  if (root is Text) {
    return root;
  }
  return tester.widget<Text>(
    find.descendant(of: notice, matching: find.byType(Text)).first,
  );
}

void main() {
  // ===========================================================================
  // D1: the controller remembers a move.
  // ===========================================================================
  group('D1 controller (needs RoomController.seatMovedFrom)', () {
    Future<RollTrayDrive> table(WidgetTester tester, {int mySeat = 3}) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        mySeat: mySeat,
        players: 4,
        turn: null,
        seats: _seatsOf(<int>[0, 1, 2, 3]),
        state: 'LOBBY',
      );
      addTearDown(drive.controller.dispose);
      return drive;
    }

    Future<void> assign(
      WidgetTester tester,
      RollTrayDrive drive,
      int seat,
    ) async {
      await pushRaw(
        tester,
        drive,
        _rawFrame('seat_assigned', <String, Object?>{
          'seat': seat,
          'seat_token': 'tok-$seat',
        }),
      );
    }

    testWidgets('(a) seat_assigned moving seat 3 to 2: seatMovedFrom is 3, '
        'seat is 2, clearSeatMoved gives null', (tester) async {
      final RollTrayDrive drive = await table(tester);
      expect(drive.controller.seat, 3, reason: 'fixture: I start as seat 3');
      await assign(tester, drive, 2);
      expect(
        drive.controller.seat,
        2,
        reason:
            'seat_assigned 2 after seat 3: the public seat getter keeps '
            'its meaning and reads 2; read ${drive.controller.seat}',
      );
      expect(
        _movedFrom(drive.controller),
        3,
        reason:
            'seat_assigned 2 after seat 3 records the old seat: '
            'seatMovedFrom should be 3',
      );
      _clearMoved(drive.controller);
      expect(
        _movedFrom(drive.controller),
        isNull,
        reason: 'clearSeatMoved() sets seatMovedFrom back to null',
      );
      expect(
        drive.controller.seat,
        2,
        reason: 'clearSeatMoved() leaves the seat itself alone',
      );
    });

    testWidgets('(b) seat_assigned to the same seat records nothing', (
      tester,
    ) async {
      final RollTrayDrive drive = await table(tester);
      await assign(tester, drive, 3);
      expect(drive.controller.seat, 3);
      expect(
        _movedFrom(drive.controller),
        isNull,
        reason: 'seat_assigned 3 while already seat 3 is not a move',
      );
    });

    testWidgets('the first seat a controller is given is not a move (null to '
        '3)', (tester) async {
      final RollTrayDrive drive = await table(tester);
      expect(
        _movedFrom(drive.controller),
        isNull,
        reason:
            'a controller that has only ever had seat 3 has not moved; the '
            'rule is from one non-null value to a different non-null one',
      );
    });

    testWidgets('a second move before the first is cleared records the seat '
        'it left last', (tester) async {
      final RollTrayDrive drive = await table(tester);
      await assign(tester, drive, 2);
      await assign(tester, drive, 1);
      expect(drive.controller.seat, 1);
      expect(
        _movedFrom(drive.controller),
        2,
        reason: '3 to 2 then 2 to 1 without a clear: the last departure, 2',
      );
    });

    testWidgets('the same seat again after a clear stays null', (tester) async {
      final RollTrayDrive drive = await table(tester);
      await assign(tester, drive, 2);
      _clearMoved(drive.controller);
      await assign(tester, drive, 2);
      expect(
        _movedFrom(drive.controller),
        isNull,
        reason: 'seat_assigned 2 while already seat 2 after a clear: no move',
      );
    });

    testWidgets('clearSeatMoved with nothing recorded is harmless', (
      tester,
    ) async {
      final RollTrayDrive drive = await table(tester);
      _clearMoved(drive.controller);
      _clearMoved(drive.controller);
      expect(_movedFrom(drive.controller), isNull);
      expect(drive.controller.seat, 3);
    });

    for (final bool moves in const <bool>[true, false]) {
      testWidgets('resume path: a reconnect whose seat_assigned '
          '${moves ? 'moves the seat (3 to 2)' : 'keeps the seat (3)'}', (
        tester,
      ) async {
        final RollTrayDrive drive = await table(tester);
        drive.transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          drive.controller.phase,
          RoomPhase.closed,
          reason: 'fixture: the dropped link leaves the controller closed',
        );
        final FakeTransport second = FakeTransport();
        drive.enqueueTransport(second);
        final Future<void> done = drive.controller.reconnect();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        final String resumeId = requestIdOf(second.sentRaw.last);
        second.pushText(
          _rawFrame('seat_assigned', <String, Object?>{
            'seat': moves ? 2 : 3,
            'seat_token': 'tok-${moves ? 2 : 3}',
          }),
        );
        second.pushText(
          _rawFrame('room', <String, Object?>{
            ..._roomBody(
              state: 'LOBBY',
              hostSeat: 0,
              players: 4,
              seats: _seatsOf(<int>[0, 1, 2, 3]),
            ),
            'seq': 50,
          }, re: resumeId),
        );
        await done;
        await tester.pump();
        expect(
          drive.controller.phase,
          RoomPhase.connected,
          reason: 'fixture: the resume reply lands connected',
        );
        expect(
          drive.controller.seat,
          moves ? 2 : 3,
          reason: 'the resume path writes the seat the server named',
        );
        expect(
          _movedFrom(drive.controller),
          moves ? 3 : isNull,
          reason: moves
              ? 'a resume that lands on seat 2 after seat 3 records 3'
              : 'a resume that lands on the same seat records nothing',
        );
      });
    }

    testWidgets('the generated gameSeatMoved getter reads the literals the '
        'screen cases expect (en and ar, four colours)', (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
        final AppLocalizations loc = await AppLocalizations.delegate.load(
          locale,
        );
        for (final String colour in _wordsEn.keys) {
          expect(
            loc.gameSeatMoved(colour),
            _movedLine(locale, colour),
            reason:
                'gameSeatMoved("$colour") in ${locale.languageCode} must '
                'equal the arb text of the contract',
          );
        }
      }
    });
  });

  // ===========================================================================
  // D2: the game says so at arrival.
  // ===========================================================================
  group('D2 screen, rematch path', () {
    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      final String lang = locale.languageCode;
      for (final _Move move in const <_Move>[_yellow, _green, _red, _blue]) {
        testWidgets(
          '(c/e) ($lang) $move: the notice reads the new colour, shows the '
          'new seat\'s mark, is announced once after the started line, and '
          'goes after 4000 ms',
          (tester) async {
            final _Announcements said = _Announcements()..install(tester);
            addTearDown(() => said.remove(tester));
            final _Run run = await _finishedTable(
              tester,
              '$lang, $move',
              move,
              locale: locale,
            );
            try {
              await _hostStartsRematch(run, move);
              expect(
                run.drive.controller.seat,
                move.to,
                reason: run.why('fixture: the controller seat is ${move.to}'),
              );
              run.expectMovedFrom(
                run.drive.controller,
                move.me,
                'once the move landed',
              );
              expect(
                _noticeUp(tester),
                isFalse,
                reason: run.why(
                  'no notice before a game arrives (the screen is still on '
                  'the rematch lobby)',
                ),
              );
              run.expectMovedFrom(
                run.drive.controller,
                move.me,
                'a move with no arrival keeps the value until the next '
                'arrival',
              );

              final int mark = said.recorded.length;
              await _startOrder(run, move.otherAfter);
              final String line = _movedLine(locale, move.colour);

              expect(
                _noticeText(tester),
                line,
                reason: run.why(
                  'game-seat-moved-notice reads "$line"; the screen showed '
                  '${_noticeText(tester)}',
                ),
              );
              final Finder marks = find.descendant(
                of: find.byKey(_noticeKey),
                matching: find.byType(SeatMark),
              );
              expect(
                marks,
                findsOneWidget,
                reason: run.why('the notice carries one SeatMark'),
              );
              expect(
                tester.widget<SeatMark>(marks).seat,
                move.to,
                reason: run.why('the SeatMark is for the new seat ${move.to}'),
              );
              final Finder disc = find.ancestor(
                of: marks,
                matching: find.byWidgetPredicate(
                  (Widget w) =>
                      w is DecoratedBox &&
                      w.decoration is BoxDecoration &&
                      (w.decoration as BoxDecoration).shape ==
                          BoxShape.circle &&
                      (w.decoration as BoxDecoration).color ==
                          LudoColors.seats[move.to],
                ),
              );
              expect(
                disc,
                findsWidgets,
                reason: run.why(
                  'the SeatMark sits on a circular disc of seat ${move.to}\'s '
                  'colour',
                ),
              );
              expect(
                tester.getSize(disc.first),
                const Size(16, 16),
                reason: run.why('the disc is 16 dp'),
              );
              final Text text = _noticeTextWidget(tester);
              expect(text.maxLines, 1, reason: run.why('maxLines: 1'));
              expect(
                text.overflow,
                TextOverflow.ellipsis,
                reason: run.why('overflow: ellipsis'),
              );

              final List<String> since = said.recorded.sublist(mark);
              expect(
                since.where((String m) => m == line).length,
                1,
                reason: run.why(
                  'exactly one announcement equal to "$line"; since the start '
                  'order: $since',
                ),
              );
              final int startedAt = since.indexOf(_startedLine(locale));
              expect(
                startedAt,
                isNot(-1),
                reason: run.why(
                  'gameStartedLine "${_startedLine(locale)}" announced; '
                  'since the start order: $since',
                ),
              );
              expect(
                since.indexOf(line),
                greaterThan(startedAt),
                reason: run.why(
                  'the seat-moved line comes after gameStartedLine; since '
                  'the start order: $since',
                ),
              );
              run.expectMovedFrom(
                run.drive.controller,
                null,
                'the arrival calls clearSeatMoved',
              );

              await run.pump(_noticeMs - 200);
              expect(
                _noticeUp(tester),
                isTrue,
                reason: run.why(
                  'the notice is still up ${_noticeMs - 200}ms after the '
                  'arrival',
                ),
              );
              await run.pump(400);
              expect(
                _noticeUp(tester),
                isFalse,
                reason: run.why(
                  'the notice is gone ${_noticeMs + 200}ms after the arrival',
                ),
              );
              expect(
                said.recorded.sublist(mark).where((String m) => m == line),
                hasLength(1),
                reason: run.why(
                  'the line is announced once, not again when the notice '
                  'ends or the screen rebuilds',
                ),
              );
              run.expectMovedFrom(
                run.drive.controller,
                null,
                'it stays null after the notice',
              );
              expect(tester.takeException(), isNull);
              run.finish();
            } finally {
              await releaseGame(tester, run.drive);
            }
          },
        );
      }
    }

    testWidgets('(d) my seat does not move: no notice, nothing announced '
        'beyond the started line', (tester) async {
      final _Announcements said = _Announcements()..install(tester);
      addTearDown(() => said.remove(tester));
      final _Run run = await _finishedTable(tester, 'en, $_stays', _stays);
      try {
        await _hostStartsRematch(run, _stays);
        expect(
          run.drive.controller.seat,
          1,
          reason: run.why('fixture: I stay seat 1'),
        );
        final int mark = said.recorded.length;
        // Seat 2 holds the turn, so seat 1 (me) is not the next seat and the
        // existing "You're next" line, which has nothing to do with a move,
        // stays out of the announcements this case reads.
        await _startOrder(run, 2);
        expect(
          _noticeUp(tester),
          isFalse,
          reason: run.why('no game-seat-moved-notice when my seat stayed'),
        );
        await run.pump(_noticeMs + 200);
        expect(_noticeUp(tester), isFalse);
        expect(
          said.recorded.sublist(mark),
          <String>[_startedEn],
          reason: run.why(
            'only gameStartedLine is announced from the start order on',
          ),
        );
      } finally {
        await releaseGame(tester, run.drive);
      }
    });

    testWidgets('a seat that moved but never gets an arrival shows nothing '
        'and keeps the value', (tester) async {
      final _Run run = await _finishedTable(tester, 'en, $_yellow', _yellow);
      try {
        await _hostStartsRematch(run, _yellow);
        await run.pump(_noticeMs + 1000);
        expect(
          _noticeUp(tester),
          isFalse,
          reason: run.why('no notice while the screen is not on a game'),
        );
        run.expectMovedFrom(
          run.drive.controller,
          3,
          'kept until the next arrival',
        );
        run.finish();
      } finally {
        await releaseGame(tester, run.drive);
      }
    });

    testWidgets('(f) no cue: the move adds nothing to what the feedback '
        'service is asked to play', (tester) async {
      Future<List<FeedbackCue>> cuesFor(_Move move, String name) async {
        final _Announcements said = _Announcements()..install(tester);
        final _Run run = await _finishedTable(tester, name, move);
        try {
          await _hostStartsRematch(run, move);
          await _startOrder(run, move.otherAfter);
          await run.pump(_noticeMs + 500);
          return List<FeedbackCue>.of(run.drive.feedback.recorded);
        } finally {
          await releaseGame(tester, run.drive);
          said.remove(tester);
        }
      }

      final List<FeedbackCue> stayed = await cuesFor(
        _stays,
        'cue baseline, $_stays',
      );
      final List<FeedbackCue> moved = await cuesFor(
        _yellow,
        'cue run, $_yellow',
      );
      expect(
        moved,
        stayed,
        reason:
            'the same frames with and without a move play the same cues: '
            'expected $stayed, the moved run played $moved (scenario: '
            '$_yellow against $_stays, then 4500 ms)',
      );
    });
  });

  // ===========================================================================
  // (g): priority and the slot.
  // ===========================================================================
  group('D2 priority and the slot', () {
    Future<void> myDeadRoll(_Run run, int mySeat) async {
      await run.push('rolled', <String, Object?>{
        'seat': mySeat,
        'value': 4,
        'legal': <int>[],
        'deadline_ms': rollTrayDeadlineMs,
        'k': 1,
        'reveal': rollTrayReveal,
        'queue': <int>[],
      });
      await run.push('turn_passed', <String, Object?>{
        'seat': mySeat,
        'reason': 'no_legal_move',
      });
      await run.push('turn', <String, Object?>{
        'seat': 0,
        'phase': 'await_roll',
        'deadline_ms': rollTrayDeadlineMs,
        'queue': <int>[],
      });
    }

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      testWidgets(
        '(g) (${locale.languageCode}) my own dead roll inside the 4000 ms '
        'shows game-no-move-notice, not the seat-moved line; the slot keeps '
        'its height with the moved line, the no-move line and neither',
        (tester) async {
          final _Run run = await _finishedTable(
            tester,
            '${locale.languageCode}, $_yellow, my dead roll',
            _yellow,
            locale: locale,
          );
          try {
            await _hostStartsRematch(run, _yellow);
            // The turn is mine, seat 2 after the move.
            await _startOrder(run, _yellow.to);
            if (!_noticeUp(tester)) {
              run.deferred.add(
                'game-seat-moved-notice is up on my own turn right after the '
                'arrival; it is absent',
              );
            }
            final double movedHeight = tester
                .getSize(_slotFinder(tester))
                .height;
            if (_noticeUp(tester)) {
              expect(
                tester.getSize(find.byKey(_noticeKey)).height,
                lessThanOrEqualTo(movedHeight),
                reason: run.why(
                  'the notice fits inside the slot (slot $movedHeight)',
                ),
              );
            }

            await myDeadRoll(run, _yellow.to);
            expect(
              find.byKey(noMoveNoticeKey),
              findsOneWidget,
              reason: run.why(
                'my own dead end shows game-no-move-notice inside the 4000 ms',
              ),
            );
            expect(
              _noticeUp(tester),
              isFalse,
              reason: run.why(
                'the seat-moved line yields to my own dead end while both '
                'are due',
              ),
            );
            final double noMoveHeight = tester
                .getSize(_slotFinder(tester))
                .height;

            // Both end: poll in 100 ms steps, bounded.
            int waited = 0;
            while ((_noticeUp(tester) ||
                    tester.any(find.byKey(noMoveNoticeKey))) &&
                waited < 8000) {
              await tester.pump(const Duration(milliseconds: 100));
              waited += 100;
            }
            run.steps.add('pumped ${waited}ms until neither line was up');
            expect(
              _noticeUp(tester) || tester.any(find.byKey(noMoveNoticeKey)),
              isFalse,
              reason: run.why('fixture: both lines end within 8 s'),
            );
            final double neitherHeight = tester
                .getSize(_slotFinder(tester))
                .height;

            expect(
              movedHeight,
              neitherHeight,
              reason: run.why(
                'the slot is as tall with the seat-moved line ($movedHeight) '
                'as with neither ($neitherHeight)',
              ),
            );
            expect(
              noMoveHeight,
              neitherHeight,
              reason: run.why(
                'the slot is as tall with the no-move line ($noMoveHeight) '
                'as with neither ($neitherHeight)',
              ),
            );
            run.finish();
          } finally {
            await releaseGame(tester, run.drive);
          }
        },
      );
    }

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final double scale in const <double>[2.0, 3.0]) {
        testWidgets(
          'narrow phone, text scale $scale (${locale.languageCode}): the '
          'notice stays one line inside the slot, uses the slot\'s text '
          'scaler, and nothing overflows',
          (tester) async {
            tester.view.physicalSize = const Size(360, 800);
            tester.view.devicePixelRatio = 1.0;
            addTearDown(() {
              tester.view.resetPhysicalSize();
              tester.view.resetDevicePixelRatio();
            });
            final _Run run = await _finishedTable(
              tester,
              '360x800 scale $scale ${locale.languageCode}, $_yellow',
              _yellow,
              locale: locale,
              textScale: scale,
            );
            try {
              await _hostStartsRematch(run, _yellow);
              await _startOrder(run, _yellow.otherAfter);
              expect(
                _noticeUp(tester),
                isTrue,
                reason: run.why('the notice is up'),
              );
              final Rect slot = tester.getRect(_slotFinder(tester));
              final Rect notice = tester.getRect(find.byKey(_noticeKey));
              expect(
                notice.height,
                lessThanOrEqualTo(slot.height + 0.01),
                reason: run.why(
                  'the notice (${notice.height}) is no taller than the slot '
                  '(${slot.height})',
                ),
              );
              expect(
                notice.left,
                greaterThanOrEqualTo(slot.left - 0.01),
                reason: run.why('the notice does not start left of the slot'),
              );
              expect(
                notice.right,
                lessThanOrEqualTo(slot.right + 0.01),
                reason: run.why('the notice does not end right of the slot'),
              );
              final AppLocalizations loc = AppLocalizations.of(
                tester.element(find.byKey(boardKey)),
              );
              final Text placeholder = tester.widget<Text>(
                find.text(loc.gameNoMove).first,
              );
              final Text text = _noticeTextWidget(tester);
              expect(
                text.textScaler?.scale(10),
                placeholder.textScaler?.scale(10),
                reason: run.why(
                  'the notice text uses the slot\'s clamped text scaler '
                  '(the one its placeholders use)',
                ),
              );
              expect(
                tester.takeException(),
                isNull,
                reason: run.why('no layout or overflow exception'),
              );
            } finally {
              await releaseGame(tester, run.drive);
            }
          },
        );
      }
    }
  });

  // ===========================================================================
  // D3 (h): the end card knows the host.
  // ===========================================================================
  group('D3 end card wiring', () {
    Future<_Run> threeSeatEnd(
      WidgetTester tester,
      String name, {
      required int me,
    }) async {
      final RollTrayDrive drive = await connectPlaying(
        tester,
        mySeat: me,
        players: 3,
        turn: null,
        seats: _seatsOf(<int>[0, 1, 2]),
        gameId: _gameA,
        state: 'FINISHED',
        winner: 1,
      );
      await mountGame(tester, drive);
      return _Run(name, tester, drive);
    }

    Future<void> lobby(
      _Run run, {
      required int by,
      required List<int> ready,
      int hostSeat = 0,
    }) => run.push(
      'room',
      _roomBody(
        state: 'LOBBY',
        hostSeat: hostSeat,
        players: 3,
        seats: _seatsOf(<int>[0, 1, 2]),
        rematch: _rematchJson(by, ready),
        chainIndex: 1,
      ),
    );

    testWidgets('(h) host in the ready list, a second seat in, I am not: the '
        'warning shows on the real screen', (tester) async {
      final _Run run = await threeSeatEnd(tester, 'three seats, me=2', me: 2);
      try {
        await lobby(run, by: 0, ready: const <int>[0]);
        expect(
          find.byKey(_mayStartKey),
          findsNothing,
          reason: run.why('one ready seat (the host) is not yet enough'),
        );
        await lobby(run, by: 0, ready: const <int>[0, 1]);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_mayStartKey),
          findsOneWidget,
          reason: run.why(
            'host seat 0 and seat 1 are ready, I am not: '
            'end-card-rematch-may-start is shown',
          ),
        );
      } finally {
        await releaseGame(tester, run.drive);
      }
    });

    testWidgets('(h) ready [1] only, the host is not in: no warning', (
      tester,
    ) async {
      final _Run run = await threeSeatEnd(tester, 'three seats, me=2', me: 2);
      try {
        await lobby(run, by: 1, ready: const <int>[1]);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_mayStartKey),
          findsNothing,
          reason: run.why('ready [1] without the host: no warning'),
        );
        await lobby(run, by: 1, ready: const <int>[1, 2]);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_mayStartKey),
          findsNothing,
          reason: run.why(
            'ready [1, 2] after I am in and the host is not: still no '
            'warning',
          ),
        );
      } finally {
        await releaseGame(tester, run.drive);
      }
    });

    testWidgets('the host is the room\'s host_seat, not seat 0 and not me: '
        'host 1 in the list shows it, host 0 outside the list does not', (
      tester,
    ) async {
      final _Run run = await threeSeatEnd(tester, 'three seats, me=0', me: 0);
      try {
        await lobby(run, by: 2, ready: const <int>[1, 2], hostSeat: 1);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_mayStartKey),
          findsOneWidget,
          reason: run.why(
            'host_seat 1 is in ready [1, 2] and I (seat 0) am not: warning',
          ),
        );
        await lobby(run, by: 2, ready: const <int>[1, 2], hostSeat: 2);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_mayStartKey),
          findsOneWidget,
          reason: run.why('host_seat 2 is in ready [1, 2]: warning'),
        );
        await lobby(run, by: 2, ready: const <int>[1, 2], hostSeat: 0);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_mayStartKey),
          findsNothing,
          reason: run.why(
            'host_seat 0 (me) is not in ready [1, 2]: no warning, the card '
            'reads the room\'s host and not some other seat',
          ),
        );
      } finally {
        await releaseGame(tester, run.drive);
      }
    });
  });
}
