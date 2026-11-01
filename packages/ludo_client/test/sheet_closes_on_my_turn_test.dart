// Screen proof for C-518 D1: my turn is never hidden under a sheet. Written
// from the contract (work/ludo/orders/C-518), not from any implementation.
//
// GameScreen is pushed over a host route, so a pop that took the screen
// itself, or a route under the sheet, would show as GameScreen gone. It sits
// on a real RoomController over FakeTransport; every state arrives as a
// decoded wire frame. The harness is the one the roll-tray and quick-chat
// suites share (support/roll_tray_harness.dart, support/c468_harness.dart).
//
// Shared fixture: a two-player room, I am seat 0, Bob is seat 1 and holds the
// turn (await_roll). Each case opens a sheet from the game screen's own
// buttons, then pushes the frame under test.
//
//   positive arms: a `turn` frame naming seat 0 closes the quick-message
//     sheet, and the die is hit-testable. (The in-game settings sheet arms
//     went with the sheet, C-523 D7.)
//   negative arms: a `turn` frame naming seat 1, a `rolled` frame, an `emote`
//     from seat 1, and the leave confirm all leave what is open in place.
//
// Announcements are read off SystemChannels.accessibility the way
// test/talkback_announce_test.dart reads them. Every wait is a bounded
// pump, never a settle: the turn countdown animates for ever. A failure
// line carries the scenario name, the frames pushed and the time pumped, so
// it replays by hand; the scenes are fixed, there is no seed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';

import 'support/c468_harness.dart';
import 'support/roll_tray_harness.dart';

const Key _chatButtonKey = Key('game-chat-button');
const Key _chatSheetKey = Key('quick-chat-sheet');
const Key _leaveButtonKey = Key('game-screen-appbar-leave');
const Key _leaveConfirmKey = Key('game-leave-confirm');
const Key _leaveStayKey = Key('game-leave-confirm-stay');
const Key _hostOpenKey = Key('test-open-game');
const Key _hostPageKey = Key('test-host-page');

const Duration _sheetMotion = Duration(milliseconds: 400);

/// One mounted scenario: the shared [Scn] (name, frames, clock), the settings
/// object the screen reads and the announcements heard so far.
class _Case {
  _Case(this.s, this.settings, this.heard);

  final Scn s;
  final FeedbackSettings settings;
  final List<String> heard;

  WidgetTester get tester => s.tester;

  Finder get chatSheet => find.byKey(_chatSheetKey);
  Finder get leaveConfirm => find.byKey(_leaveConfirmKey);
  Finder get die => find.byKey(bigDieKey);

  String why(String expected) =>
      '${s.why(expected)} | announcements: $heard | '
      'cues: ${s.drive.feedback.recorded} | sheets open: ${_open()}';

  String _open() => <String>[
    if (tester.any(chatSheet)) 'quick-chat-sheet',
    if (tester.any(leaveConfirm)) 'game-leave-confirm',
  ].join(', ');

  Future<void> tapAndOpen(Key button, Finder sheet) async {
    s.steps.add('tap ${(button as ValueKey<String>).value}');
    await tester.tap(find.byKey(button));
    await tester.pump();
    await s.pump(_sheetMotion);
    expect(
      sheet,
      findsOneWidget,
      reason: why('the sheet is on screen after the tap (fixture)'),
    );
  }

  Future<void> openChat() => tapAndOpen(_chatButtonKey, chatSheet);

  Future<void> openLeaveConfirm() => tapAndOpen(_leaveButtonKey, leaveConfirm);

  /// Pushes [type] and lets any close motion finish, in bounded pumps.
  Future<void> pushAndSettle(String type, Map<String, Object?> data) async {
    await s.push(type, data);
    await s.pump(_sheetMotion);
  }

  Future<void> myTurn() => pushAndSettle('turn', turnFrame(0));

  Future<void> bobsTurn() => pushAndSettle('turn', turnFrame(1));

  Future<void> bobRolls() =>
      pushAndSettle('rolled', rolledFrame(1, 4, 1, legal: const <int>[0, 1]));

  Future<void> bobSays(String emote) async {
    await s.pushEmote(1, emote);
    await s.pump(_sheetMotion);
  }

  void expectGameMounted(String when) {
    expect(
      find.byType(GameScreen),
      findsOneWidget,
      reason: why('GameScreen is still mounted $when (it was not popped)'),
    );
  }

  void expectDieReachable(String when) {
    expect(
      die.hitTestable(),
      findsOneWidget,
      reason: why('game-die is hit-testable $when'),
    );
  }
}

/// Mounts the game over a host page and returns once Bob holds the turn.
Future<_Case> _start(
  WidgetTester tester,
  String name, {
  Locale locale = const Locale('en'),
}) async {
  phoneSurface(tester);
  final List<String> heard = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        heard.add(data['message'] as String);
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
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: awaitRollTurn(1),
    seats: twoSeats(),
  );
  final FeedbackSettings settings = FeedbackSettings.forTest();
  await tester.pumpWidget(
    FeedbackScope(
      settings: settings,
      service: drive.feedback,
      child: rollTrayHarness(
        Scaffold(
          key: _hostPageKey,
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                key: _hostOpenKey,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => GameScreen(controller: drive.controller),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        locale: locale,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(_hostOpenKey));
  await tester.pump();
  final Scn s = Scn(name, tester, drive);
  s.steps.add('mount ${locale.languageCode}, Bob to roll');
  await s.pump(_sheetMotion);
  expect(
    find.byType(GameScreen),
    findsOneWidget,
    reason: 'fixture is broken: $name: GameScreen was not pushed',
  );
  final _Case c = _Case(s, settings, heard);
  c.expectDieReachable('before any sheet opens (fixture)');
  return c;
}

Future<void> _release(WidgetTester tester, _Case c) =>
    releaseGame(tester, c.s.drive);

void main() {
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    final String lang = locale.languageCode;

    group('D1 my turn closes the sheets I opened ($lang)', () {
      testWidgets(
        'quick-chat-sheet open on Bob\'s turn is gone when my turn frame '
        'arrives, the die is reachable and the screen is still mounted',
        (tester) async {
          final _Case c = await _start(
            tester,
            'chat-then-my-turn $lang',
            locale: locale,
          );
          try {
            await c.openChat();
            expect(
              c.die.hitTestable(),
              findsNothing,
              reason: c.why(
                'the open sheet hides game-die (fixture: the hit test is '
                'meaningful)',
              ),
            );
            final int cuesBefore = c.s.drive.feedback.recorded.length;
            final int heardBefore = c.heard.length;

            await c.myTurn();

            expect(
              c.chatSheet,
              findsNothing,
              reason: c.why(
                'quick-chat-sheet closed by the turn frame naming seat 0',
              ),
            );
            c.expectDieReachable('once the sheet is closed');
            c.expectGameMounted('after the sheet closes');
            expect(
              c.s.drive.feedback.recorded.skip(cuesBefore).toList(),
              <FeedbackCue>[FeedbackCue.yourTurn],
              reason: c.why(
                'closing is silent: the only cue is the your_turn one',
              ),
            );
            expect(
              c.heard.skip(heardBefore).length,
              1,
              reason: c.why(
                'closing is silent: the only announcement is the your_turn '
                'one',
              ),
            );
          } finally {
            await _release(tester, c);
          }
        },
      );
    });
  }

  group('D1 nothing else closes a sheet', () {
    testWidgets('a turn frame for Bob leaves the quick-chat-sheet open', (
      tester,
    ) async {
      final _Case c = await _start(tester, 'chat-then-bobs-turn');
      try {
        await c.openChat();
        await c.bobsTurn();
        expect(
          c.chatSheet,
          findsOneWidget,
          reason: c.why('quick-chat-sheet stays open on a turn frame for 1'),
        );
        c.expectGameMounted('with the sheet open');
      } finally {
        await _release(tester, c);
      }
    });

    testWidgets('a rolled frame leaves the quick-chat-sheet open', (
      tester,
    ) async {
      final _Case c = await _start(tester, 'chat-then-rolled');
      try {
        await c.openChat();
        await c.bobRolls();
        expect(
          c.chatSheet,
          findsOneWidget,
          reason: c.why('quick-chat-sheet stays open on a rolled frame'),
        );
        c.expectGameMounted('with the sheet open');
      } finally {
        await _release(tester, c);
      }
    });

    testWidgets('a quick message from Bob leaves the quick-chat-sheet open', (
      tester,
    ) async {
      final _Case c = await _start(tester, 'chat-then-emote');
      try {
        await c.openChat();
        await c.bobSays('hi');
        expect(
          c.chatSheet,
          findsOneWidget,
          reason: c.why('quick-chat-sheet stays open when an emote arrives'),
        );
        c.expectGameMounted('with the sheet open');
      } finally {
        await _release(tester, c);
      }
    });

    testWidgets(
      'the leave confirm stays open when my turn frame arrives, and Stay '
      'then closes only the confirm',
      (tester) async {
        final _Case c = await _start(tester, 'leave-confirm-then-my-turn');
        try {
          await c.openLeaveConfirm();
          await c.myTurn();
          expect(
            c.leaveConfirm,
            findsOneWidget,
            reason: c.why(
              'game-leave-confirm is a decision in progress, my turn frame '
              'does not close it',
            ),
          );
          c.expectGameMounted('with the confirm open');

          c.s.steps.add('tap game-leave-confirm-stay');
          await tester.tap(find.byKey(_leaveStayKey));
          await tester.pump();
          await c.s.pump(_sheetMotion);
          expect(
            c.leaveConfirm,
            findsNothing,
            reason: c.why('Stay closes the confirm'),
          );
          c.expectGameMounted('after Stay');
          c.expectDieReachable('after Stay, on my turn');
        } finally {
          await _release(tester, c);
        }
      },
    );

    testWidgets('my turn frame with no sheet open changes nothing on screen', (
      tester,
    ) async {
      final _Case c = await _start(tester, 'no-sheet-then-my-turn');
      try {
        await c.myTurn();
        expect(c.chatSheet, findsNothing, reason: c.why('no chat sheet'));
        expect(c.leaveConfirm, findsNothing, reason: c.why('no confirm'));
        c.expectGameMounted('on a turn frame with nothing open');
        c.expectDieReachable('on my turn');
      } finally {
        await _release(tester, c);
      }
    });
  });
}
