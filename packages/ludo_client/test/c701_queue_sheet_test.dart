// Proof for order 701's waiting window (`queue-sheet`) and the play-the-
// computer swap, written from the order and docs/PROTOCOL.md sections 33 and
// 34, not from the code.
//
// Every row runs in English and Arabic at 320x640 and at 412x915 over a real
// HomeScreen on the project's fake transport; the server's frames are pushed
// by hand in the wire format. A failure names the variant, the row and the
// command that reruns it. Social paths count their taps (doctrine P5).

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart'
    show kAutoReconnectDelays;

import 'net/fake_transport.dart';
import 'support/c701_harness.dart';
import 'support/home_flow.dart';

const String _file = 'c701_queue_sheet_test.dart';
const String _ticket = 'tkt0123456789abcdefghij';

void row(
  String name,
  Future<void> Function(C701Rig rig) body, {
  List<C701Variant> variants = kVariants,
  List<Duration>? reconnectDelays,
}) {
  for (final C701Variant v in variants) {
    final String full = '${v.id}: $name';
    testWidgets(full, (WidgetTester tester) async {
      final C701Rig rig = C701Rig(
        tester,
        v,
        file: _file,
        row: full,
        reconnectDelays: reconnectDelays ?? kAutoReconnectDelays,
      );
      await runRow(rig, () => body(rig));
    });
  }
}

/// Home to the waiting window, with the first `queued` answered.
Future<void> _queued(C701Rig r, int position) async {
  await r.mount();
  await r.typeName();
  await r.enterQueue();
  await r.pushQueued(position, re: r.idOfLast('find_game'));
}

String? _aheadText(C701Rig r) {
  final Finder f = find.byKey(queueAheadKey);
  return f.evaluate().isEmpty ? null : r.tester.widget<Text>(f).data;
}

Finder _inQueue(Finder what) =>
    find.descendant(of: find.byKey(queueSheetKey), matching: what);

void _expectWindowUp(C701Rig r, String when) {
  expect(
    find.byKey(queueSheetKey),
    findsOneWidget,
    reason: 'expected the waiting window to stay up $when. ${r.repro}',
  );
}

Future<void> _toComputerChoice(C701Rig r) async {
  await _queued(r, 1);
  await r.tap(find.byKey(queueVsComputerKey), what: 'queue-vs-computer');
  await pumpUntilAtRest(
    r.tester,
    find.byKey(vsComputerTwoKey),
    what: 'vs-computer-2. ${r.repro}',
  );
}

/// What the app renders a digit as: read off a plural that prints its count.
String _digits(C701Rig r, int n) {
  final String sample = r.loc.queueAhead(3);
  return sample.contains('٣')
      ? n.toString().replaceAllMapped(
          RegExp(r'\d'),
          (Match m) => String.fromCharCode(0x0660 + int.parse(m[0]!)),
        )
      : n.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the line', () {
    row('position 1 shows the window and no ahead line', (C701Rig r) async {
      await _queued(r, 1);
      _expectWindowUp(r, 'after queued 1');
      expect(
        _inQueue(find.text(r.loc.queueTitle)),
        findsOneWidget,
        reason: 'expected the title "${r.loc.queueTitle}". ${r.repro}',
      );
      expect(
        find.byKey(queueAheadKey),
        findsNothing,
        reason: 'position 1 must show no queue-ahead. ${r.repro}',
      );
      expect(
        _inQueue(find.byKey(queueVsComputerKey)),
        findsOneWidget,
        reason: 'expected the queue-vs-computer control. ${r.repro}',
      );
      expect(
        _inQueue(find.byKey(queueCancelKey)),
        findsOneWidget,
        reason: 'expected the queue-cancel control. ${r.repro}',
      );
      expect(
        find.descendant(
          of: find.byKey(queueVsComputerKey),
          matching: find.text(r.loc.queueVsComputer),
        ),
        findsOneWidget,
        reason:
            'queue-vs-computer must read "${r.loc.queueVsComputer}". ${r.repro}',
      );
      expect(
        find.descendant(
          of: find.byKey(queueVsComputerKey),
          matching: find.byIcon(Icons.smart_toy_rounded),
        ),
        findsOneWidget,
        reason: 'queue-vs-computer must carry smart_toy_rounded. ${r.repro}',
      );
      expect(
        find.descendant(
          of: find.byKey(queueCancelKey),
          matching: find.text(r.loc.queueCancel),
        ),
        findsOneWidget,
        reason: 'queue-cancel must read "${r.loc.queueCancel}". ${r.repro}',
      );
    });

    row('position 3 shows two players ahead', (C701Rig r) async {
      await _queued(r, 3);
      final String? shown = _aheadText(r);
      expect(
        shown,
        isNotNull,
        reason: 'position 3 must show queue-ahead. ${r.repro}',
      );
      expect(
        shown,
        r.loc.queueAhead(2),
        reason: 'expected "${r.loc.queueAhead(2)}", got "$shown". ${r.repro}',
      );
      if (r.variant.lang == 'en') {
        expect(
          shown,
          '2 players ahead of you',
          reason: 'English wording. ${r.repro}',
        );
      } else {
        expect(
          shown!.contains('قدّامك'),
          isTrue,
          reason: 'Arabic wording, got "$shown". ${r.repro}',
        );
        expect(
          shown.contains('2'),
          isFalse,
          reason: 'the Arabic dual has no digit, got "$shown". ${r.repro}',
        );
      }
    });

    row('position 2 shows one player ahead', (C701Rig r) async {
      await _queued(r, 2);
      expect(
        _aheadText(r),
        r.loc.queueAhead(1),
        reason:
            'position 2 must show "${r.loc.queueAhead(1)}", got '
            '"${_aheadText(r)}". ${r.repro}',
      );
      if (r.variant.lang == 'en') {
        expect(
          _aheadText(r),
          '1 player ahead of you',
          reason: 'English singular. ${r.repro}',
        );
      }
    });

    row('a second queued updates the line and drops it at the head', (
      C701Rig r,
    ) async {
      await _queued(r, 3);
      await r.pushQueued(2);
      expect(
        _aheadText(r),
        r.loc.queueAhead(1),
        reason:
            'after position 2 expected "${r.loc.queueAhead(1)}", got '
            '"${_aheadText(r)}". ${r.repro}',
      );
      await r.pushQueued(5);
      expect(
        _aheadText(r),
        r.loc.queueAhead(4),
        reason:
            'a line that grows must update too: expected '
            '"${r.loc.queueAhead(4)}", got "${_aheadText(r)}". ${r.repro}',
      );
      await r.pushQueued(1);
      expect(
        find.byKey(queueAheadKey),
        findsNothing,
        reason: 'position 1 must remove the line. ${r.repro}',
      );
      _expectWindowUp(r, 'at the head of the line');
    });

    row('back does not close the window', (C701Rig r) async {
      await _queued(r, 2);
      await r.tester.binding.handlePopRoute();
      await r.tester.pump();
      await r.tester.pump(const Duration(seconds: 1));
      _expectWindowUp(r, 'after the system back');
      expect(
        r.sent('cancel_find'),
        isEmpty,
        reason: 'back must not leave the line. ${r.repro}',
      );
    });

    row('a tap outside does not close the window', (C701Rig r) async {
      await _queued(r, 2);
      await r.tester.tapAt(const Offset(4, 4));
      await r.tester.pump();
      await r.tester.pump(const Duration(seconds: 1));
      _expectWindowUp(r, 'after a tap outside');
      expect(
        r.sent('cancel_find'),
        isEmpty,
        reason: 'a tap outside must not leave the line. ${r.repro}',
      );
    });

    row('cancel sends cancel_find and the window closes on find_cancelled', (
      C701Rig r,
    ) async {
      await _queued(r, 2);
      await r.tap(find.byKey(queueCancelKey), what: 'queue-cancel');
      await r.waitUntil(
        () => r.sent('cancel_find').isNotEmpty,
        'a cancel_find after queue-cancel',
      );
      expect(
        r.sent('cancel_find'),
        hasLength(1),
        reason: 'expected one cancel_find. ${r.repro}',
      );
      expect(
        r.sent('cancel_find').single['d'],
        isEmpty,
        reason: 'cancel_find carries no payload. ${r.repro}',
      );
      _expectWindowUp(r, 'until find_cancelled arrives');
      await r.push(
        'find_cancelled',
        const <String, Object?>{},
        re: r.idOfLast('cancel_find'),
      );
      await pumpUntilGone(
        r.tester,
        find.byKey(queueSheetKey),
        what: 'queue-sheet after find_cancelled',
      );
      expect(
        find.byKey(createRoomButtonKey),
        findsOneWidget,
        reason: 'expected home after cancel. ${r.repro}',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'cancel must not reach a lobby. ${r.repro}',
      );
      expect(
        r.taps,
        3,
        reason:
            'P5: Join, Random players, Cancel is 3 taps, took ${r.taps}. ${r.repro}',
      );
    });

    row('seat_assigned and room close the window and land in the lobby', (
      C701Rig r,
    ) async {
      await _queued(r, 2);
      await r.push('seat_assigned', <String, Object?>{
        'seat': 1,
        'seat_token': 'tok-c701-001',
      });
      await r.push('room', r.roomJson());
      await pumpUntilGone(
        r.tester,
        find.byKey(queueSheetKey),
        what: 'queue-sheet after seat_assigned and room',
      );
      await r.waitUntil(
        () => find.byType(LobbyScreen).evaluate().isNotEmpty,
        'the lobby',
      );
      expect(
        find.byType(LobbyScreen),
        findsOneWidget,
        reason: 'expected the lobby after being seated. ${r.repro}',
      );
      expect(
        r.taps,
        2,
        reason:
            'P5: Join then Random players, then no more taps, took ${r.taps}. ${r.repro}',
      );
    });

    row('a seat given at once, before any queued, closes the window too', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.enterQueue();
      final String id = r.idOfLast('find_game');
      await r.push('seat_assigned', <String, Object?>{
        'seat': 1,
        'seat_token': 'tok-c701-002',
      });
      await r.push('room', r.roomJson(), re: id);
      await pumpUntilGone(
        r.tester,
        find.byKey(queueSheetKey),
        what: 'queue-sheet after an immediate seat',
      );
      await r.waitUntil(
        () => find.byType(LobbyScreen).evaluate().isNotEmpty,
        'the lobby',
      );
    });

    row(
      'a dropped socket re-sends find_game with the ticket and the window stays',
      (C701Rig r) async {
        await _queued(r, 3);
        final FakeTransport first = r.transport;
        first.endFromFarSide();
        await r.tester.pump();
        _expectWindowUp(r, 'while the socket is down');
        await r.waitSeconds(
          () => r.transports.length >= 2,
          'a second connection after the drop',
        );
        await r.waitUntil(
          () => r.transports.last.sentRaw.any(
            (String s) => frameType(s) == 'find_game',
          ),
          'find_game on the new connection',
        );
        _expectWindowUp(r, 'after the reconnect');
        final Map<String, Object?> d = frameData(
          r.transports.last.sentRaw.firstWhere(
            (String s) => frameType(s) == 'find_game',
          ),
        );
        expect(
          d['ticket'],
          _ticket,
          reason:
              'the re-sent find_game must carry the held ticket, got $d. ${r.repro}',
        );
        expect(
          d['name'],
          r.defaultName,
          reason:
              'the re-sent find_game must carry the name, got $d. ${r.repro}',
        );
        expect(
          d['install'],
          isA<String>().having(
            (String s) => installShape.hasMatch(s),
            'install shape',
            isTrue,
          ),
          reason:
              'the re-sent find_game must carry install, got $d. ${r.repro}',
        );
        expect(
          r.sent('cancel_find'),
          isEmpty,
          reason: 'a drop is not a cancel. ${r.repro}',
        );
      },
    );

    row('the window shows the position the server sends after a reconnect', (
      C701Rig r,
    ) async {
      await _queued(r, 3);
      r.transport.endFromFarSide();
      await r.waitSeconds(
        () => r.transports.length >= 2,
        'a second connection',
      );
      await r.waitUntil(
        () => r.transports.last.sentRaw.any(
          (String s) => frameType(s) == 'find_game',
        ),
        'find_game',
      );
      await r.pushQueued(
        1,
        re: frameOfType(r.transports.last, 'find_game')['id']! as String,
      );
      expect(
        find.byKey(queueAheadKey),
        findsNothing,
        reason: 'position 1 after the reconnect must show no line. ${r.repro}',
      );
      _expectWindowUp(r, 'after the reconnect');
    });
  });

  group('play the computer', () {
    row('queue-vs-computer shows the two tiles with their numeral and pawns', (
      C701Rig r,
    ) async {
      await _toComputerChoice(r);
      expect(
        _inQueue(find.text(r.loc.vsComputerTitle)),
        findsOneWidget,
        reason:
            'expected the title "${r.loc.vsComputerTitle}" in the same window. ${r.repro}',
      );
      expect(
        find.byKey(queueSheetKey),
        findsOneWidget,
        reason: 'the swap must stay in the one window. ${r.repro}',
      );
      for (final (Key key, int n) in <(Key, int)>[
        (vsComputerTwoKey, 2),
        (vsComputerFourKey, 4),
      ]) {
        final Finder tile = find.byKey(key);
        expect(tile, findsOneWidget, reason: '$key missing. ${r.repro}');
        final Rect rect = r.tester.getRect(tile);
        expect(
          rect.height >= 96 && rect.width >= 48,
          isTrue,
          reason:
              '$key is ${rect.size}, need 96 dp tall and 48 dp wide. ${r.repro}',
        );
        expect(
          find.descendant(of: tile, matching: find.text(_digits(r, n))),
          findsOneWidget,
          reason: '$key must show the numeral "${_digits(r, n)}". ${r.repro}',
        );
        final Iterable<Element> pawns = find
            .descendant(of: tile, matching: find.byType(CustomPaint))
            .evaluate()
            .where((Element e) {
              final CustomPaint c = e.widget as CustomPaint;
              return c.painter != null && c.size.width > 0;
            });
        expect(
          pawns.length,
          n,
          reason:
              '$key must show $n pawn glyphs, found ${pawns.length}. ${r.repro}',
        );
      }
      expect(
        r.tester.getRect(find.byKey(vsComputerTwoKey)).top,
        closeTo(r.tester.getRect(find.byKey(vsComputerFourKey)).top, 0.5),
        reason: 'the tiles must sit side by side. ${r.repro}',
      );
      expect(
        find.byKey(vsComputerBackKey),
        findsOneWidget,
        reason: 'vs-computer-back missing. ${r.repro}',
      );
      expect(
        r.tester.getSize(find.byKey(vsComputerBackKey)).shortestSide >= 48,
        isTrue,
        reason:
            'vs-computer-back is ${r.tester.getSize(find.byKey(vsComputerBackKey))}, need 48 dp. ${r.repro}',
      );
    });

    row('the tiles carry their screen reader labels', (C701Rig r) async {
      final SemanticsHandle handle = r.tester.ensureSemantics();
      try {
        await _toComputerChoice(r);
        expect(
          find.bySemanticsLabel(r.loc.vsComputerTwoLabel),
          findsWidgets,
          reason: 'missing "${r.loc.vsComputerTwoLabel}". ${r.repro}',
        );
        expect(
          find.bySemanticsLabel(r.loc.vsComputerFourLabel),
          findsWidgets,
          reason: 'missing "${r.loc.vsComputerFourLabel}". ${r.repro}',
        );
      } finally {
        handle.dispose();
      }
    });

    row('vs-computer-back returns to the waiting content and sends nothing', (
      C701Rig r,
    ) async {
      await _toComputerChoice(r);
      final int framesBefore = r.sentTypes().length;
      await r.tap(find.byKey(vsComputerBackKey), what: 'vs-computer-back');
      await pumpUntilAtRest(
        r.tester,
        find.byKey(queueCancelKey),
        what: 'queue-cancel after back. ${r.repro}',
      );
      expect(
        _inQueue(find.text(r.loc.queueTitle)),
        findsOneWidget,
        reason: 'expected the waiting title back. ${r.repro}',
      );
      await pumpUntilGone(
        r.tester,
        find.byKey(vsComputerTwoKey),
        what: 'the computer tiles after vs-computer-back',
      );
      expect(
        r.sentTypes().length,
        framesBefore,
        reason:
            'back must send nothing, sent ${r.sentTypes().sublist(framesBefore)}. ${r.repro}',
      );
    });

    for (final int n in <int>[2, 4]) {
      row('vs-computer-$n sends play_computer with $n players and no cancel_find', (
        C701Rig r,
      ) async {
        await _toComputerChoice(r);
        await r.tap(
          find.byKey(n == 2 ? vsComputerTwoKey : vsComputerFourKey),
          what: 'vs-computer-$n',
        );
        await r.waitUntil(
          () => r.sent('play_computer').isNotEmpty,
          'a play_computer after vs-computer-$n',
        );
        final List<Map<String, Object?>> plays = r.sent('play_computer');
        expect(
          plays,
          hasLength(1),
          reason: 'expected one play_computer, got ${plays.length}. ${r.repro}',
        );
        final Map<String, Object?> d =
            plays.single['d']! as Map<String, Object?>;
        expect(
          d['players'],
          n,
          reason: 'players must be $n, got $d. ${r.repro}',
        );
        expect(
          d['name'],
          r.defaultName,
          reason: 'name must be the typed one, got $d. ${r.repro}',
        );
        expect(
          d['install'],
          isA<String>().having(
            (String s) => installShape.hasMatch(s),
            'install shape',
            isTrue,
          ),
          reason: 'install shape, got ${d['install']}. ${r.repro}',
        );
        expect(
          d['client_seed'],
          isA<String>().having(
            (String s) => clientSeedShape.hasMatch(s),
            'set_seed shape',
            isTrue,
          ),
          reason:
              'client_seed must be 1..64 of [A-Za-z0-9_-] like set_seed, got ${d['client_seed']}. ${r.repro}',
        );
        expect(
          r.sent('cancel_find'),
          isEmpty,
          reason:
              'the server leaves the line on play_computer; no cancel_find first. ${r.repro}',
        );
        expect(
          r.taps,
          4,
          reason:
              'P5: Join, Random, Play the computer, a tile is 4 taps, took ${r.taps}. ${r.repro}',
        );
        _expectWindowUp(r, 'until the room arrives');
        await r.push('seat_assigned', <String, Object?>{
          'seat': 0,
          'seat_token': 'tok-c701-003',
        });
        await r.push(
          'room',
          r.roomJson(players: n, open: false, mySeat: 0),
          re: r.idOfLast('play_computer'),
        );
        await pumpUntilGone(
          r.tester,
          find.byKey(queueSheetKey),
          what: 'queue-sheet after the room arrived',
        );
        await r.waitUntil(
          () => find.byType(LobbyScreen).evaluate().isNotEmpty,
          'the lobby after play_computer',
        );
      });
    }
  });

  group('errors', () {
    row('RATE_LIMITED on find_game closes the window and shows a notice', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.enterQueue();
      await r.pushError('RATE_LIMITED', re: r.idOfLast('find_game'));
      await pumpUntilGone(
        r.tester,
        find.byKey(queueSheetKey),
        what: 'queue-sheet after RATE_LIMITED',
      );
      await pumpUntilFound(
        r.tester,
        find.byKey(homeNoticeKey),
        what: 'a home notice after RATE_LIMITED. ${r.repro}',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'an error must not reach a lobby. ${r.repro}',
      );
    });

    row('ALREADY_SEATED on find_game closes the window and shows a notice', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      await r.enterQueue();
      await r.pushError('ALREADY_SEATED', re: r.idOfLast('find_game'));
      await pumpUntilGone(
        r.tester,
        find.byKey(queueSheetKey),
        what: 'queue-sheet after ALREADY_SEATED',
      );
      await pumpUntilFound(
        r.tester,
        find.byKey(homeNoticeKey),
        what: 'a home notice after ALREADY_SEATED. ${r.repro}',
      );
    });

    row('RATE_LIMITED on play_computer closes the window and shows a notice', (
      C701Rig r,
    ) async {
      await _toComputerChoice(r);
      await r.tap(find.byKey(vsComputerFourKey), what: 'vs-computer-4');
      await r.waitUntil(
        () => r.sent('play_computer').isNotEmpty,
        'play_computer',
      );
      await r.pushError('RATE_LIMITED', re: r.idOfLast('play_computer'));
      await pumpUntilGone(
        r.tester,
        find.byKey(queueSheetKey),
        what: 'queue-sheet after RATE_LIMITED on play_computer',
      );
      await pumpUntilFound(
        r.tester,
        find.byKey(homeNoticeKey),
        what: 'a home notice after RATE_LIMITED. ${r.repro}',
      );
    });

    row('a socket that cannot be opened closes the window with a notice', (
      C701Rig r,
    ) async {
      await r.mount();
      await r.typeName();
      r.failConnects = true;
      await r.openJoinSheet();
      await r.tap(find.byKey(joinRandomTileKey), what: 'join-random-tile');
      await r.waitSeconds(
        () => find.byKey(queueSheetKey).evaluate().isEmpty,
        'the window to close',
        limit: 60,
      );
      await pumpUntilFound(
        r.tester,
        find.byKey(homeNoticeKey),
        what: 'a home notice. ${r.repro}',
      );
    }, reconnectDelays: const <Duration>[]);

    row('a drop with no reconnect left closes the window with a notice', (
      C701Rig r,
    ) async {
      await _queued(r, 2);
      r.transport.endFromFarSide();
      await r.waitSeconds(
        () => find.byKey(queueSheetKey).evaluate().isEmpty,
        'the window to close',
        limit: 60,
      );
      await pumpUntilFound(
        r.tester,
        find.byKey(homeNoticeKey),
        what: 'a home notice. ${r.repro}',
      );
      expect(
        r.sent('find_game'),
        hasLength(1),
        reason: 'with no reconnect nothing more is sent. ${r.repro}',
      );
    }, reconnectDelays: const <Duration>[]);
  });

  group('motion', () {
    row('the die rolls slowly, and with reduced motion it is still', (
      C701Rig r,
    ) async {
      await _queued(r, 2);
      await r.tester.pump(const Duration(milliseconds: 500));
      expect(
        r.tester.binding.hasScheduledFrame,
        isTrue,
        reason: 'the waiting die should be rolling. ${r.repro}',
      );
    });

    row('reduced motion leaves the waiting window still', (C701Rig r) async {
      await r.mount(reduceMotion: true);
      await r.typeName();
      await r.enterQueue();
      await r.pushQueued(2, re: r.idOfLast('find_game'));
      FocusManager.instance.primaryFocus?.unfocus();
      await r.tester.pump(const Duration(seconds: 2));
      await r.tester.pump(const Duration(seconds: 2));
      expect(
        r.tester.binding.hasScheduledFrame,
        isFalse,
        reason:
            'with reduced motion nothing in the window may keep animating. ${r.repro}',
      );
    });
  });

  group('no overflow at text scale 1.3', () {
    row('waiting window at the head', (C701Rig r) async {
      await _queued(r, 1);
      r.expectNoOverflow(
        'waiting window',
        keys: <Key>[queueVsComputerKey, queueCancelKey],
      );
    }, variants: kLargeTextVariants);

    row('waiting window with a long line ahead', (C701Rig r) async {
      await _queued(r, 128);
      r.expectNoOverflow(
        'waiting window, 127 ahead',
        keys: <Key>[queueAheadKey, queueVsComputerKey, queueCancelKey],
      );
    }, variants: kLargeTextVariants);

    row('computer choice', (C701Rig r) async {
      await _toComputerChoice(r);
      r.expectNoOverflow(
        'computer choice',
        keys: <Key>[vsComputerTwoKey, vsComputerFourKey, vsComputerBackKey],
      );
    }, variants: kLargeTextVariants);
  });
}

Map<String, Object?> frameOfType(FakeTransport t, String type) =>
    decodeFrame(t.sentRaw.firstWhere((String s) => frameType(s) == type));
