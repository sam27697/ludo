// Screen proof for C-485 D6 items 1, 2, 3 and 4 (order 488): the one-tap
// reply chips on the end card. Written from work/ludo/orders/C-485 and
// C-478 alone; the implementation (order 485) was being written in another
// tree and has not been read.
//
// Two halves. The game screen cases drive a real GameScreen over a real
// RoomController on FakeTransport (test/support/end_card_chat_harness.dart),
// every state a decoded wire frame, fake time from the pump, and reach the
// new widgets by key only, so they compile on a tree without C-485 and fail
// there on the missing key. The direct cases mount an EndCard with the new
// quickReplies / onQuickReply / quickReplyCooling parameters; they sit
// between the BEGIN direct and END direct markers and do not compile until
// the implementation lands.
//
// Every failure reason starts with the scenario name and ends with the
// frames and pumps that led to it, so a red case replays from its message.
//
// Ambiguities in the contract, reported and not invented around:
//   - D5.1 says the chips are drawn "at 38 % opacity" without saying how.
//     The measure multiplies every Opacity / FadeTransition above the chip's
//     text with the text's own colour alpha, and compares cooling against
//     ready, so a theme colour that is not fully opaque does not matter. A
//     fade done only in the bubble painter would read as 1.0 and fail.
//   - D5.1 says "paper fill" and cites C-478 D5.2, whose amendment A1 makes
//     the chip fill paperElevated. The anatomy case follows A1.
//   - D5.1 does not say what a tap does while a send is in flight and the
//     copy has not come back. Nothing here asserts it.
//   - The distance between the panel and the chips is not given: the
//     placement cases only require the chips below the panel, above New
//     table, with nothing else keyed between, and the dock and the panel
//     unmoved.
//   - D5.1 does not say what a tap on a chip does when onQuickReply is null
//     (disabled): only that it draws at 38 %. The case asserts the look and
//     that nothing is called, not a cue.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/chat_bubble.dart';
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/net/room_controller.dart' show RoomPhase;
import 'package:ludo_client/src/theme.dart';

import 'support/c468_harness.dart';
import 'support/end_card_chat_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');
const Key _endedKey = Key('end-card-ended');
const Key _offlineKey = Key('end-card-offline');
const Key _goneKey = Key('end-card-rematch-gone');
const Key _leftKey = Key('end-card-left');
const Key _askKey = Key('end-card-rematch-ask');

/// The card variant keys that must be on screen, one of them.
void _expectCard(EndGame g, EndKind kind) {
  final Key key = switch (kind) {
    EndKind.winner => _winKey,
    EndKind.loser => _loseKey,
    EndKind.ended => _endedKey,
  };
  expect(
    find.byKey(key),
    findsOneWidget,
    reason: g.why('fixture: the ${kind.name} card is on screen'),
  );
}

List<String> _idsFor(EndKind kind) => switch (kind) {
  EndKind.winner => kWinnerReplies,
  EndKind.loser => kLoserReplies,
  EndKind.ended => kEndedReplies,
};

/// A seated, connected loser card must show its chips, or the cases that
/// say "no chips" would pass on a tree that never draws any.
Future<void> _control(WidgetTester tester, String name) async {
  final EndGame c = await openFinished(tester, '$name (control)');
  try {
    expect(
      replyIds(tester),
      kLoserReplies,
      reason: c.why('control: a seated, connected loser card has its chips'),
    );
  } finally {
    await c.done();
  }
}

void _expectNoReplies(EndGame g, String what) {
  expect(
    find.byKey(kQuickRepliesKey),
    findsNothing,
    reason: g.why('$what: no end-card-quick-replies'),
  );
  expect(
    replyIds(g.tester),
    isEmpty,
    reason: g.why('$what: no end-card-reply-<id> chip'),
  );
}

// BEGIN direct
/// An EndCard in an EndCardFrame, the way the finished body mounts it, with
/// the new reply parameters. [onReply] is required on purpose: null is the
/// disabled state and a case must ask for it.
Widget _cardTree({
  required void Function(String id)? onReply,
  EndKind kind = EndKind.loser,
  List<String> replies = const <String>[],
  bool cooling = false,
  RecordingFeedback? feedback,
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  double trailing = 300,
}) => rollTrayHarness(
  FeedbackScope(
    settings: FeedbackSettings.forTest(),
    service: feedback ?? RecordingFeedback(),
    child: Scaffold(
      body: EndCardFrame(
        card: EndCard(
          mySeat: 0,
          winnerSeat: switch (kind) {
            EndKind.winner => 0,
            EndKind.loser => 1,
            EndKind.ended => null,
          },
          winnerName: switch (kind) {
            EndKind.winner => 'Sam',
            EndKind.loser => 'Bob',
            EndKind.ended => null,
          },
          seatColors: LudoColors.seats,
          stats: null,
          verifyUrl: null,
          onVerify: () {},
          onNewTable: () {},
          onRematch: () {},
          quickReplies: replies,
          onQuickReply: onReply,
          quickReplyCooling: cooling,
        ),
        trailing: SizedBox(height: trailing),
      ),
    ),
  ),
  locale: locale,
  textScale: textScale,
);

Future<void> _mountCard(
  WidgetTester tester,
  Widget tree, {
  Size size = const Size(360, 800),
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = size;
  await tester.pumpWidget(tree);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// END direct

void main() {
  // -------------------------------------------------------------------
  // Item 1: the defaults change nothing.
  // -------------------------------------------------------------------
  group('1. an EndCard with no replies and no lines', () {
    for (final EndKind kind in EndKind.values) {
      testWidgets('${kind.name}: neither end-card-quick-replies nor '
          'end-card-chat-lines', (tester) async {
        phoneSurface(tester);
        await tester.pumpWidget(
          rollTrayHarness(
            Scaffold(
              body: EndCardFrame(
                card: EndCard(
                  mySeat: 0,
                  winnerSeat: switch (kind) {
                    EndKind.winner => 0,
                    EndKind.loser => 1,
                    EndKind.ended => null,
                  },
                  winnerName: switch (kind) {
                    EndKind.winner => 'Sam',
                    EndKind.loser => 'Bob',
                    EndKind.ended => null,
                  },
                  seatColors: LudoColors.seats,
                  stats: null,
                  verifyUrl: null,
                  onVerify: () {},
                  onNewTable: () {},
                  onRematch: () {},
                ),
                trailing: const SizedBox(height: 100),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(kQuickRepliesKey),
          findsNothing,
          reason:
              '1. ${kind.name}: a card built without quickReplies draws '
              'no end-card-quick-replies',
        );
        expect(
          find.byKey(kChatLinesKey),
          findsNothing,
          reason:
              '1. ${kind.name}: a card built without chatLines draws no '
              'end-card-chat-lines',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  // -------------------------------------------------------------------
  // Item 2: which chips, for whom.
  // -------------------------------------------------------------------
  group('2. the chips a game screen hands each variant', () {
    for (final EndKind kind in EndKind.values) {
      for (final bool ar in const <bool>[false, true]) {
        testWidgets('${kind.name} card, ${ar ? 'ar' : 'en'}: exactly '
            '${_idsFor(kind)} in order with the C-478 D3 text', (tester) async {
          final EndGame g = await openFinished(
            tester,
            '2 ${kind.name} ${ar ? 'ar' : 'en'}',
            kind: kind,
            locale: Locale(ar ? 'ar' : 'en'),
          );
          try {
            _expectCard(g, kind);
            expect(
              find.byKey(kQuickRepliesKey),
              findsOneWidget,
              reason: g.why('one end-card-quick-replies on the ${kind.name}'),
            );
            expect(
              replyIds(tester),
              _idsFor(kind),
              reason: g.why('the ${kind.name} chips, in order'),
            );
            for (final String id in _idsFor(kind)) {
              expect(
                find.descendant(
                  of: find.byKey(kQuickRepliesKey),
                  matching: find.byKey(replyKey(id)),
                ),
                findsOneWidget,
                reason: g.why('chip $id sits inside end-card-quick-replies'),
              );
              expect(
                textUnder(tester, find.byKey(replyKey(id))),
                endLine(id, ar: ar),
                reason: g.why('chip $id reads "${endLine(id, ar: ar)}"'),
              );
            }
            expect(tester.takeException(), isNull);
          } finally {
            await g.done();
          }
        });
      }
    }

    testWidgets('the same chips stay in a rematch LOBBY, by the finished '
        'game\'s variant', (tester) async {
      for (final EndKind kind in const <EndKind>[
        EndKind.winner,
        EndKind.loser,
      ]) {
        final EndGame g = await openFinished(
          tester,
          '2 rematch lobby ${kind.name}',
          kind: kind,
        );
        try {
          await g.rematchLobby(by: 1);
          expect(
            find.byKey(_askKey),
            findsOneWidget,
            reason: g.why('fixture: the rematch LOBBY card shows the ask'),
          );
          expect(
            replyIds(tester),
            _idsFor(kind),
            reason: g.why('${kind.name}: chips on the rematch LOBBY card'),
          );
        } finally {
          await g.done();
        }
      }
    });

    testWidgets('a spectator (no seat) gets no chips', (tester) async {
      await _control(tester, '2 spectator');
      final EndGame g = await openSpectator(tester, '2 spectator');
      try {
        expect(
          g.drive.controller.seat,
          isNull,
          reason: g.why('fixture: no seat_assigned was sent'),
        );
        expect(
          find.byKey(const Key('game-screen-winner')),
          findsOneWidget,
          reason: g.why('fixture: the end card is on screen'),
        );
        _expectNoReplies(g, 'spectator');
      } finally {
        await g.done();
      }
    });

    for (final EndKind kind in const <EndKind>[EndKind.winner, EndKind.loser]) {
      testWidgets('an offline ${kind.name} card gets no chips', (tester) async {
        final EndGame g = await openFinished(
          tester,
          '2 offline ${kind.name}',
          kind: kind,
        );
        try {
          expect(
            replyIds(tester),
            _idsFor(kind),
            reason: g.why('fixture: connected, the chips are there'),
          );
          g.s.steps.add('far side closes');
          g.drive.transport.endFromFarSide();
          await tester.pump();
          await g.s.pump(const Duration(milliseconds: 200));
          expect(
            find.byKey(_offlineKey),
            findsOneWidget,
            reason: g.why('fixture: the offline end card'),
          );
          _expectNoReplies(g, 'offline');
        } finally {
          await g.done();
        }
      });
    }

    testWidgets('a gone rematch (NO_SUCH_ROOM) gets no chips', (tester) async {
      final EndGame g = await openFinished(tester, '2 rematch gone');
      try {
        expect(
          replyIds(tester),
          kLoserReplies,
          reason: g.why('control: connected, the chips are there'),
        );
        final int before = g.sentCount;
        await tester.ensureVisible(find.byKey(kRematchKey));
        await tester.tap(find.byKey(kRematchKey));
        await tester.pump();
        await g.s.pump(const Duration(milliseconds: 100));
        final String id = requestIdOf(
          g.drive.transport.sentRaw
              .skip(before)
              .firstWhere((String t) => frameType(t) == 'rematch'),
        );
        g.s.steps.add('error NO_SUCH_ROOM re=$id');
        await pushRaw(
          tester,
          g.drive,
          errorReplyFrame(re: id, code: 'NO_SUCH_ROOM'),
        );
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(_goneKey),
          findsOneWidget,
          reason: g.why('fixture: end-card-rematch-gone is shown'),
        );
        _expectNoReplies(g, 'rematch gone');
      } finally {
        await g.done();
      }
    });

    testWidgets('everyone else left: no chips', (tester) async {
      final EndGame g = await openFinished(tester, '2 everyone left');
      try {
        expect(
          replyIds(tester),
          kLoserReplies,
          reason: g.why(
            'control: with the other seat there, the chips are '
            'there',
          ),
        );
        await g.playerLeft(1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(_leftKey),
          findsOneWidget,
          reason: g.why('fixture: end-card-left is shown'),
        );
        _expectNoReplies(g, 'everyone left');
      } finally {
        await g.done();
      }
    });

    testWidgets('no chips while the game is PLAYING or in a first-game '
        'LOBBY', (tester) async {
      await _control(tester, '2 playing and lobby');
      final EndGame playing = await openPlaying(tester, '2 playing');
      try {
        _expectNoReplies(playing, 'PLAYING');
      } finally {
        await playing.done();
      }
      final EndGame lobby = await openFirstLobby(tester, '2 first lobby');
      try {
        _expectNoReplies(lobby, 'first-game LOBBY');
      } finally {
        await lobby.done();
      }
    });

    testWidgets('the chips sit between the panel and New table, below one '
        'and above the other', (tester) async {
      final EndGame g = await openFinished(tester, '2 placement');
      try {
        final Rect panel = rectOf(g, _loseKey);
        final Rect chips = rectOf(g, kQuickRepliesKey);
        final Rect newTable = rectOf(g, kNewTableKey);
        expect(
          chips.top,
          greaterThanOrEqualTo(panel.bottom - 0.5),
          reason: g.why('chips $chips start below the panel $panel'),
        );
        expect(
          newTable.top,
          greaterThanOrEqualTo(chips.bottom - 0.5),
          reason: g.why('New table $newTable starts below the chips $chips'),
        );
        expect(
          chips.center.dx,
          closeTo(panel.center.dx, 1.5),
          reason: g.why('the chips are centred under the panel'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('Arabic mirrors the chip order by Directionality alone, '
        'English runs left to right, one row at 800 dp', (tester) async {
      final EndGame en = await openFinished(
        tester,
        '2 row order en',
        size: const Size(800, 800),
      );
      try {
        final Rect first = rectOf(en, replyKey('good_game'));
        final Rect second = rectOf(en, replyKey('revenge'));
        expect(
          (first.top - second.top).abs(),
          lessThan(1.0),
          reason: en.why('fixture: the first two chips share a row'),
        );
        expect(
          first.left,
          lessThan(second.left),
          reason: en.why('en: good_game is left of revenge'),
        );
        final Rect panel = rectOf(en, _loseKey);
        final Rect chips = rectOf(en, kQuickRepliesKey);
        final Rect all = first.expandToInclude(rectOf(en, replyKey('lucky')));
        expect(
          all.center.dx,
          closeTo(panel.center.dx, 1.5),
          reason: en.why('one row of chips is centred, wrap is $chips'),
        );
      } finally {
        await en.done();
      }
      final EndGame ar = await openFinished(
        tester,
        '2 row order ar',
        locale: const Locale('ar'),
        size: const Size(800, 800),
      );
      try {
        final Rect first = rectOf(ar, replyKey('good_game'));
        final Rect second = rectOf(ar, replyKey('revenge'));
        expect(
          (first.top - second.top).abs(),
          lessThan(1.0),
          reason: ar.why('fixture: the first two chips share a row in ar'),
        );
        expect(
          first.right,
          greaterThan(second.right),
          reason: ar.why('ar: good_game is on the right of revenge'),
        );
      } finally {
        await ar.done();
      }
    });
  });

  // -------------------------------------------------------------------
  // Item 3: sending and cooling.
  // -------------------------------------------------------------------
  group('3. a chip tap sends one emote and starts the one cooldown', () {
    testWidgets('one tap, one emote frame with {"emote": id} and nothing '
        'else; no optimistic line', (tester) async {
      for (final String id in kLoserReplies) {
        final EndGame g = await openFinished(tester, '3 send $id');
        try {
          final int before = g.sentCount;
          await tapReply(g, id);
          final List<Map<String, Object?>> sent = g.emotesSent(before);
          expect(sent, hasLength(1), reason: g.why('exactly one emote sent'));
          expect(sent.single['t'], 'emote');
          expect(sent.single['d'], <String, Object?>{
            'emote': id,
          }, reason: g.why('d is {"emote": "$id"}'));
          expect(sentTypesSince(g.drive.transport, before), <String>[
            'emote',
          ], reason: g.why('nothing else went out'));
          expect(
            chatLineSeats(tester),
            isEmpty,
            reason: g.why('no line before the server copy (no optimism)'),
          );
        } finally {
          await g.done();
        }
      }
    });

    testWidgets('the winner\'s chips send their ids too', (tester) async {
      for (final String id in kWinnerReplies) {
        final EndGame g = await openFinished(
          tester,
          '3 send winner $id',
          kind: EndKind.winner,
        );
        try {
          final int before = g.sentCount;
          await tapReply(g, id);
          expect(
            g.emotesSent(before).map((Map<String, Object?> f) => f['d']),
            <Object?>[
              <String, Object?>{'emote': id},
            ],
            reason: g.why('winner chip $id sends {"emote": "$id"}'),
          );
        } finally {
          await g.done();
        }
      }
    });

    testWidgets('after the server copy the chips draw at 38 % for 3000 ms: '
        'a tap sends nothing and plays invalidTap; then they are live', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '3 cooling');
      try {
        for (final String id in kLoserReplies) {
          expect(
            chipAlphaOf(g, id),
            closeTo(1.0, 0.01),
            reason: g.why('fixture: chip $id is drawn live before the send'),
          );
        }
        final int before = g.sentCount;
        await tapReply(g, 'revenge');
        await g.answerEmote(before, id: 'revenge');
        expect(chatLineSeats(tester), <int>[
          0,
        ], reason: g.why('my own line shows from the server copy'));
        final int cues = g.s.count(FeedbackCue.invalidTap);

        await g.at(600);
        for (final String id in kLoserReplies) {
          expect(
            chipAlphaOf(g, id),
            closeTo(0.38, 0.03),
            reason: g.why('600 ms after the copy chip $id is drawn at 38 %'),
          );
        }
        await tapReply(g, 'lucky');
        expect(
          g.emotesSent(before),
          hasLength(1),
          reason: g.why('a cooling tap sends nothing'),
        );
        expect(
          g.s.count(FeedbackCue.invalidTap),
          cues + 1,
          reason: g.why('a cooling tap plays invalidTap once'),
        );

        await g.at(2900);
        expect(
          chipAlphaOf(g, 'good_game'),
          closeTo(0.38, 0.03),
          reason: g.why('2900 ms after the copy: still cooling'),
        );
        await g.tester.tap(find.byKey(replyKey('good_game')));
        await tester.pump();
        expect(
          g.emotesSent(before),
          hasLength(1),
          reason: g.why('2900 ms: a tap still sends nothing'),
        );
        expect(
          g.s.count(FeedbackCue.invalidTap),
          cues + 2,
          reason: g.why('2900 ms: a second invalidTap'),
        );

        await g.at(3100);
        for (final String id in kLoserReplies) {
          expect(
            chipAlphaOf(g, id),
            closeTo(1.0, 0.03),
            reason: g.why('3100 ms after the copy chip $id is live again'),
          );
        }
        await tapReply(g, 'lucky');
        final List<Map<String, Object?>> sent = g.emotesSent(before);
        expect(sent.map((Map<String, Object?> f) => f['d']), <Object?>[
          <String, Object?>{'emote': 'revenge'},
          <String, Object?>{'emote': 'lucky'},
        ], reason: g.why('after 3000 ms the next tap sends'));
        expect(
          g.s.count(FeedbackCue.invalidTap),
          cues + 2,
          reason: g.why('a live tap plays no invalidTap'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('a refused send (RATE_LIMITED) rests the chips 3000 ms, '
        'plays invalidTap once, shows no line', (tester) async {
      final EndGame g = await openFinished(tester, '3 refused');
      try {
        final int before = g.sentCount;
        final int cues = g.s.drive.feedback.recorded.length;
        final int taps = g.s.count(FeedbackCue.invalidTap);
        await tapReply(g, 'revenge');
        final String id = requestIdOf(
          g.drive.transport.sentRaw
              .skip(before)
              .singleWhere((String t) => frameType(t) == 'emote'),
        );
        g.s.steps.add('error RATE_LIMITED re=$id');
        await pushRaw(
          tester,
          g.drive,
          errorReplyFrame(re: id, code: 'RATE_LIMITED'),
        );
        await g.s.pump(const Duration(milliseconds: 100));
        final int refusedAt = g.s.clockMs - 100;
        for (final String chip in kLoserReplies) {
          expect(
            chipAlphaOf(g, chip),
            closeTo(0.38, 0.03),
            reason: g.why('C-520 D1: a refused send rests chip $chip'),
          );
        }
        expect(
          g.s.count(FeedbackCue.invalidTap),
          taps + 1,
          reason: g.why('C-520 D1: the refusal plays invalidTap exactly once'),
        );
        expect(
          g.s.drive.feedback.recorded.length,
          cues + 1,
          reason: g.why('and nothing else is played for a refused send'),
        );
        expect(chatLineSeats(tester), isEmpty, reason: g.why('no line'));
        expect(
          g.drive.controller.phase,
          RoomPhase.connected,
          reason: g.why('a refused emote leaves the screen connected'),
        );
        await g.s.pump(Duration(milliseconds: refusedAt + 2900 - g.s.clockMs));
        for (final String chip in kLoserReplies) {
          expect(
            chipAlphaOf(g, chip),
            closeTo(0.38, 0.03),
            reason: g.why('chip $chip still resting 2900 ms after the refusal'),
          );
        }
        await g.s.pump(Duration(milliseconds: refusedAt + 3100 - g.s.clockMs));
        for (final String chip in kLoserReplies) {
          expect(
            chipAlphaOf(g, chip),
            closeTo(1.0, 0.03),
            reason: g.why('chip $chip is live 3100 ms after the refusal'),
          );
        }
        await tapReply(g, 'lucky');
        expect(
          g.emotesSent(before).map((Map<String, Object?> f) => f['d']),
          <Object?>[
            <String, Object?>{'emote': 'revenge'},
            <String, Object?>{'emote': 'lucky'},
          ],
          reason: g.why('after the 3000 ms rest the next tap sends'),
        );
        expect(
          g.s.count(FeedbackCue.invalidTap),
          taps + 1,
          reason: g.why('and plays no further invalidTap'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('someone else\'s line does not start my cooling', (
      tester,
    ) async {
      final EndGame g = await openFinished(tester, '3 others do not cool');
      try {
        await g.emote(1, 'good_game');
        await g.s.pump(const Duration(milliseconds: 100));
        for (final String id in kLoserReplies) {
          expect(
            chipAlphaOf(g, id),
            closeTo(1.0, 0.03),
            reason: g.why('a line from seat 1 leaves chip $id live'),
          );
        }
        final int before = g.sentCount;
        await tapReply(g, 'good_game');
        expect(g.emotesSent(before), hasLength(1), reason: g.why('sends'));
      } finally {
        await g.done();
      }
    });

    testWidgets('the cooldown is shared: a send from the header button in '
        'PLAYING cools the card\'s chips', (tester) async {
      final EndGame g = await openPlaying(tester, '3 shared board to card');
      try {
        final int before = g.sentCount;
        g.s.steps.add('tap game-chat-button, pick hi');
        await tester.tap(find.byKey(kChatButtonKey));
        await tester.pump();
        await g.s.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(sheetChipKey('hi')));
        await tester.pump();
        await g.s.pump(const Duration(milliseconds: 400));
        await g.answerEmote(before, id: 'hi');
        await g.s.pump(const Duration(milliseconds: 200));
        await g.gameOver(1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          replyIds(tester),
          kLoserReplies,
          reason: g.why('fixture: the loser card has its chips'),
        );
        final int cues = g.s.count(FeedbackCue.invalidTap);
        expect(
          chipAlphaOf(g, 'good_game'),
          closeTo(0.38, 0.03),
          reason: g.why('the board send still cools the card 300 ms on'),
        );
        final int sent = g.sentCount;
        await tapReply(g, 'good_game');
        expect(
          g.emotesSent(sent),
          isEmpty,
          reason: g.why(
            'a card tap during the board send\'s cooling sends '
            'nothing',
          ),
        );
        expect(
          g.s.count(FeedbackCue.invalidTap),
          cues + 1,
          reason: g.why('and plays invalidTap'),
        );
        await g.at(3100);
        expect(
          chipAlphaOf(g, 'good_game'),
          closeTo(1.0, 0.03),
          reason: g.why('3100 ms after the copy the chips are live'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('the cooldown is shared: a send from a chip cools the '
        'header button of the next game', (tester) async {
      final EndGame g = await openFinished(tester, '3 shared card to board');
      try {
        final int before = g.sentCount;
        await tapReply(g, 'good_game');
        await g.answerEmote(before, id: 'good_game');
        await g.rematchLobby(by: 1);
        await g.startRematchGame(turnSeat: 1);
        await g.s.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(kChatButtonKey),
          findsOneWidget,
          reason: g.why('fixture: the next game is PLAYING with its button'),
        );
        final int cues = g.s.count(FeedbackCue.invalidTap);
        g.s.steps.add('tap game-chat-button while cooling');
        await tester.tap(find.byKey(kChatButtonKey));
        await tester.pump();
        await g.s.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(kSheetKey),
          findsNothing,
          reason: g.why(
            'a header tap opens nothing while the card\'s send '
            'cools',
          ),
        );
        expect(
          g.s.count(FeedbackCue.invalidTap),
          cues + 1,
          reason: g.why('and plays invalidTap'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('Arabic: the tap sends the id, not the text', (tester) async {
      final EndGame g = await openFinished(
        tester,
        '3 ar send',
        locale: const Locale('ar'),
      );
      try {
        final int before = g.sentCount;
        await tapReply(g, 'revenge');
        expect(
          g.emotesSent(before).map((Map<String, Object?> f) => f['d']),
          <Object?>[
            <String, Object?>{'emote': 'revenge'},
          ],
          reason: g.why('the id travels, never the text'),
        );
      } finally {
        await g.done();
      }
    });

    testWidgets('360 x 640 at 2x text: every chip is 48 dp tall, the dock '
        'stays on screen, a tap still sends', (tester) async {
      final EndGame g = await openFinished(
        tester,
        '3 small phone big text',
        textScale: 2.0,
        size: const Size(360, 640),
      );
      try {
        expect(tester.takeException(), isNull, reason: g.why('no overflow'));
        expect(replyIds(tester), kLoserReplies, reason: g.why('chips'));
        for (final String id in kLoserReplies) {
          expect(
            tester.getSize(find.byKey(replyKey(id))).height,
            greaterThanOrEqualTo(48.0),
            reason: g.why('chip $id is 48 dp tall at 2x'),
          );
        }
        expect(
          rectOf(g, kRematchKey).bottom,
          lessThanOrEqualTo(640.0),
          reason: g.why('the dock stays on screen'),
        );
        final int before = g.sentCount;
        await tapReply(g, 'lucky');
        expect(g.emotesSent(before), hasLength(1), reason: g.why('sends'));
      } finally {
        await g.done();
      }
    });
  });

  // BEGIN direct
  // -------------------------------------------------------------------
  // Items 2, 3 and 4 on the widget alone.
  // -------------------------------------------------------------------
  group('direct EndCard: the reply chips', () {
    testWidgets('one Wrap keyed end-card-quick-replies holds the chips in the '
        'order handed in, spacing and run spacing kSpace2, centred', (
      tester,
    ) async {
      await _mountCard(
        tester,
        _cardTree(
          onReply: (String id) {},
          replies: const <String>['revenge', 'good_game', 'lucky'],
        ),
      );
      expect(find.byKey(kQuickRepliesKey), findsOneWidget);
      final Widget wrap = tester.widget(find.byKey(kQuickRepliesKey));
      expect(
        wrap,
        isA<Wrap>(),
        reason:
            'end-card-quick-replies is the Wrap itself, found '
            '${wrap.runtimeType}',
      );
      final Wrap w = wrap as Wrap;
      expect(w.spacing, kSpace2, reason: 'spacing kSpace2');
      expect(w.runSpacing, kSpace2, reason: 'run spacing kSpace2');
      expect(w.alignment, WrapAlignment.center, reason: 'centred');
      expect(replyIds(tester), <String>['revenge', 'good_game', 'lucky']);
      expect(
        textUnder(tester, find.byKey(replyKey('revenge'))),
        'I\'ll get you back',
      );
    });

    testWidgets('an explicit empty list draws no wrap', (tester) async {
      await _mountCard(tester, _cardTree(onReply: (String id) {}));
      expect(find.byKey(kQuickRepliesKey), findsNothing);
      expect(replyIds(tester), isEmpty);
    });

    testWidgets('Arabic text, Directionality rtl, first chip on the right', (
      tester,
    ) async {
      await _mountCard(
        tester,
        _cardTree(
          onReply: (String id) {},
          replies: kLoserReplies,
          locale: const Locale('ar'),
        ),
        size: const Size(800, 800),
      );
      for (final String id in kLoserReplies) {
        expect(
          textUnder(tester, find.byKey(replyKey(id))),
          endLine(id, ar: true),
          reason: 'chip $id reads Arabic',
        );
      }
      expect(
        Directionality.of(tester.element(find.byKey(kQuickRepliesKey))),
        TextDirection.rtl,
      );
      expect(
        tester.getRect(find.byKey(replyKey('good_game'))).right,
        greaterThan(tester.getRect(find.byKey(replyKey('revenge'))).right),
        reason: 'mirrored by Directionality: the first chip is on the right',
      );
    });

    testWidgets('a tap calls onQuickReply once with the chip\'s id', (
      tester,
    ) async {
      final List<String> calls = <String>[];
      await _mountCard(
        tester,
        _cardTree(onReply: calls.add, replies: kLoserReplies),
      );
      for (final String id in kLoserReplies) {
        calls.clear();
        await tester.ensureVisible(find.byKey(replyKey(id)));
        await tester.tap(find.byKey(replyKey(id)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(calls, <String>[id], reason: 'tap on $id calls once with $id');
      }
    });

    testWidgets('onQuickReply null: the chips stay, drawn at 38 %, and a tap '
        'calls nothing', (tester) async {
      final List<String> calls = <String>[];
      await _mountCard(
        tester,
        _cardTree(onReply: calls.add, replies: kLoserReplies),
      );
      final double ready = chipAlpha(tester, 'good_game');
      await tester.pumpWidget(_cardTree(onReply: null, replies: kLoserReplies));
      await tester.pump(const Duration(milliseconds: 400));
      expect(replyIds(tester), kLoserReplies, reason: 'still drawn');
      for (final String id in kLoserReplies) {
        expect(
          chipAlpha(tester, id) / ready,
          closeTo(0.38, 0.03),
          reason: 'disabled chip $id at 38 %',
        );
        await tester.tap(find.byKey(replyKey(id)), warnIfMissed: false);
        await tester.pump();
      }
      expect(calls, isEmpty, reason: 'a disabled chip calls nothing');
    });

    testWidgets('quickReplyCooling: 38 %, a tap plays invalidTap once and '
        'calls nothing; when it clears the chips are live', (tester) async {
      final List<String> calls = <String>[];
      final RecordingFeedback feedback = RecordingFeedback();
      await _mountCard(
        tester,
        _cardTree(
          onReply: calls.add,
          replies: kLoserReplies,
          feedback: feedback,
        ),
      );
      final double ready = chipAlpha(tester, 'good_game');
      await tester.pumpWidget(
        _cardTree(
          onReply: calls.add,
          replies: kLoserReplies,
          cooling: true,
          feedback: feedback,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      for (final String id in kLoserReplies) {
        expect(
          chipAlpha(tester, id) / ready,
          closeTo(0.38, 0.03),
          reason: 'cooling chip $id at 38 %',
        );
      }
      await tester.tap(find.byKey(replyKey('revenge')));
      await tester.pump();
      expect(calls, isEmpty, reason: 'a cooling tap calls nothing');
      expect(
        feedback.recorded.where((FeedbackCue c) => c == FeedbackCue.invalidTap),
        hasLength(1),
        reason: 'a cooling tap plays invalidTap once',
      );
      await tester.pumpWidget(
        _cardTree(
          onReply: calls.add,
          replies: kLoserReplies,
          feedback: feedback,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(chipAlpha(tester, 'good_game') / ready, closeTo(1.0, 0.03));
      await tester.tap(find.byKey(replyKey('lucky')));
      await tester.pump();
      expect(calls, <String>['lucky'], reason: 'live again after cooling');
      expect(
        feedback.recorded.where((FeedbackCue c) => c == FeedbackCue.invalidTap),
        hasLength(1),
        reason: 'a live tap plays no invalidTap',
      );
    });

    testWidgets('a chip is the sheet\'s speech bubble: 48 dp tall, ink-muted '
        '1.5 dp border, radius 16, tail at the bottom start, labelLarge ink, '
        'not a Material control', (tester) async {
      await _mountCard(
        tester,
        _cardTree(onReply: (String id) {}, replies: kLoserReplies),
      );
      for (final String id in kLoserReplies) {
        final Finder chip = find.byKey(replyKey(id));
        expect(
          tester.getSize(chip).height,
          greaterThanOrEqualTo(48.0),
          reason: 'chip $id is at least 48 dp tall',
        );
        final Finder painted = find.descendant(
          of: chip,
          matching: find.byWidgetPredicate(
            (Widget w) => w is CustomPaint && w.painter is SpeechBubblePainter,
          ),
        );
        expect(
          painted,
          findsOneWidget,
          reason: 'chip $id is drawn with the SpeechBubblePainter',
        );
        final SpeechBubblePainter p =
            (tester.widget(painted) as CustomPaint).painter!
                as SpeechBubblePainter;
        expect(p.fill, LudoColors.paperElevated, reason: 'fill (C-478 A1)');
        expect(p.border, LudoColors.inkMuted, reason: 'ink-muted border');
        expect(p.borderWidth, 1.5);
        expect(p.radius, 16);
        expect(p.tailOnTop, isFalse, reason: 'tail at the bottom');
        expect(
          p.tailAnchor,
          ChatTailAnchor.start,
          reason: 'tail at the start corner',
        );
        final RichText text = tester.widget<RichText>(
          find.descendant(of: chip, matching: find.byType(RichText)).first,
        );
        final TextStyle? style = text.text.style;
        expect(
          style?.fontSize,
          Theme.of(tester.element(chip)).textTheme.labelLarge!.fontSize,
          reason: 'labelLarge size',
        );
        expect(style?.color, LudoColors.ink, reason: 'ink');
      }
      for (final Type forbidden in <Type>[
        ActionChip,
        InputChip,
        ChoiceChip,
        FilterChip,
        Chip,
        ElevatedButton,
        TextButton,
        OutlinedButton,
        FilledButton,
        IconButton,
        ListTile,
      ]) {
        expect(
          find.descendant(
            of: find.byKey(kQuickRepliesKey),
            matching: find.byType(forbidden),
          ),
          findsNothing,
          reason: 'the chips hold no $forbidden',
        );
      }
    });

    testWidgets('each chip is a button whose label is its line', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      try {
        for (final bool ar in const <bool>[false, true]) {
          await _mountCard(
            tester,
            _cardTree(
              onReply: (String id) {},
              replies: kLoserReplies,
              locale: Locale(ar ? 'ar' : 'en'),
            ),
          );
          for (final String id in kLoserReplies) {
            final SemanticsNode node = tester.getSemantics(
              find.byKey(replyKey(id)),
            );
            expect(
              node.label,
              endLine(id, ar: ar),
              reason: 'chip $id label (${ar ? 'ar' : 'en'})',
            );
            expect(
              node.flagsCollection.isButton,
              isTrue,
              reason: 'chip $id is a button',
            );
          }
        }
      } finally {
        handle.dispose();
      }
    });
  });

  group('4. placement: under the panel, above New table, the dock still', () {
    for (final EndKind kind in EndKind.values) {
      for (final double scale in const <double>[1.0, 2.0]) {
        testWidgets('${kind.name} at ${scale}x text: the panel and the dock '
            'sit where they sat without chips', (tester) async {
          const Size size = Size(360, 640);
          await _mountCard(
            tester,
            _cardTree(
              onReply: (String id) {},
              kind: kind,
              textScale: scale,
              trailing: 600,
            ),
            size: size,
          );
          final Finder panelFinder = find.byKey(switch (kind) {
            EndKind.winner => _winKey,
            EndKind.loser => _loseKey,
            EndKind.ended => _endedKey,
          });
          final Rect panelBare = tester.getRect(panelFinder);
          final Rect dockBare = tester.getRect(find.byKey(kRematchKey));
          final Rect tableBare = tester.getRect(find.byKey(kNewTableKey));

          await tester.pumpWidget(
            _cardTree(
              onReply: (String id) {},
              kind: kind,
              replies: _idsFor(kind),
              textScale: scale,
              trailing: 600,
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          final Rect panel = tester.getRect(panelFinder);
          final Rect dock = tester.getRect(find.byKey(kRematchKey));
          final Rect chips = tester.getRect(find.byKey(kQuickRepliesKey));
          final Rect table = tester.getRect(find.byKey(kNewTableKey));
          final String where =
              '${kind.name} ${scale}x: panel $panel dock $dock chips $chips '
              'table $table (bare: $panelBare $dockBare $tableBare)';
          expect(panel, panelBare, reason: 'the panel did not move: $where');
          expect(dock, dockBare, reason: 'the dock did not move: $where');
          expect(
            chips.top,
            greaterThanOrEqualTo(panel.bottom - 0.5),
            reason: 'chips below the panel: $where',
          );
          expect(
            table.top,
            greaterThanOrEqualTo(chips.bottom - 0.5),
            reason: 'New table below the chips: $where',
          );
          expect(
            table.top,
            greaterThan(tableBare.top),
            reason: 'New table was pushed down by the chips: $where',
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
  // END direct
}
