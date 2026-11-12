// Wiring proof for work/ludo/orders/624-spoken-line-live-region.md, contract
// decisions D4 and D5 (C-624): every line a screen sends through
// SemanticsService.sendAnnouncement also rides a polite live region.
//
// Written from the contract text alone, and written to COMPILE on a tree
// without lib/src/spoken_line.dart: the region is found by walking the
// semantics tree for the live-region flag and a label, never by
// SpokenLineRegion, SpokenLineController or kSpokenLineRegionKey.
//
// The announcement channel is observed as test/talkback_announce_test.dart
// observes it: a mock handler on SystemChannels.accessibility that records
// every `announce` event (message and text direction). GameScreen is driven
// through test/support/roll_tray_harness.dart (a real RoomController over a
// FakeTransport, fed wire frames), LobbyScreen the way
// test/friend_joined_test.dart does it. Semantics are switched on in every
// case. Every wait is a bounded `tester.pump(duration)` on the fake clock;
// nothing here uses pumpAndSettle or a real delay.
//
// Events covered (each in English and Arabic):
//   G1  GameScreen: my own roll with no legal move.
//   G2  GameScreen: a turn frame that arms the auto-move (two lines in the
//       same frame today), and then the auto-move's own send line 1500 ms
//       later.
//   L1  LobbyScreen: a friend sits down.
//
// What each event proves:
//   (h)/(i)/(j) the announcement is sent on the channel, AND on the next
//       frame exactly one live-region node is labelled with the same text,
//       in the screen's text direction, and it is gone 1500 ms after the
//       line plus a frame (still there 100 ms before).
//   (k) the number of announcements per event, and their order, is the one
//       the base tree sends today: the lines are pinned below with the
//       counts measured on the base commit 5409b33 (run 142), because the
//       contract says "no new line" and "no timing change".
//   (l) leaving the screen mid-hold leaves no pending timer (the framework
//       fails a test that ends with one).
//
// Failure messages carry the scenario (event, locale), every announcement
// recorded, and the step log with fake time. The cases are deterministic;
// there is no seed, the scenario plus its steps is the reproduction.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';
import 'support/roll_tray_harness.dart';

const int _holdMs = 1500;

// C-474 D2 (work/ludo/orders/C-474-why-no-move.md): a roll of 3 with all
// four tokens in the yard is NEED_SIX, announced as the notice reads.
const String _needSixEn = 'You need a 6 to come out';
const String _needSixAr = 'تحتاج 6 لإخراج قطعة';

const List<Locale> _locales = <Locale>[Locale('en'), Locale('ar')];

TextDirection _dirOf(Locale l) =>
    l.languageCode == 'ar' ? TextDirection.rtl : TextDirection.ltr;

/// One decoded `announce` event: message and dart:ui text direction index.
class _Say {
  const _Say(this.message, this.dirIndex);
  final String message;
  final int dirIndex;
  @override
  String toString() => '"$message"(dir=$dirIndex)';
}

/// The observer for one scenario: the channel recorder, the semantics
/// walker and the step log every failure message carries.
class _Obs {
  _Obs(this.tester, this.name);

  final WidgetTester tester;
  final String name;
  final List<_Say> said = <_Say>[];
  final List<String> steps = <String>[];
  int ms = 0;
  SemanticsHandle? _handle;

  String get why =>
      'scenario "$name"; announced so far: $said; steps: ${steps.join(' | ')}';

  void install() {
    _handle = tester.ensureSemantics();
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          said.add(
            _Say(data['message'] as String, data['textDirection'] as int),
          );
          steps.add('announce "${data['message']}"@${ms}ms');
        }
        return null;
      },
    );
  }

  void remove() {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    );
    _handle?.dispose();
    _handle = null;
  }

  Future<void> pump([int dms = 0]) async {
    ms += dms;
    steps.add('pump(${dms}ms)->${ms}ms');
    await tester.pump(Duration(milliseconds: dms));
  }

  List<SemanticsNode> _all() {
    final SemanticsNode? root = tester
        .binding
        .renderViews
        .first
        .owner
        ?.semanticsOwner
        ?.rootSemanticsNode;
    final List<SemanticsNode> out = <SemanticsNode>[];
    void walk(SemanticsNode n) {
      out.add(n);
      n.visitChildren((SemanticsNode c) {
        walk(c);
        return true;
      });
    }

    if (root != null) {
      walk(root);
    }
    return out;
  }

  List<SemanticsNode> live() => _all()
      .where((SemanticsNode n) => n.flagsCollection.isLiveRegion)
      .toList();

  List<String> liveLabels() =>
      live().map((SemanticsNode n) => n.label).toList();

  /// Live-region nodes whose label is exactly [line].
  List<SemanticsNode> liveWith(String line) =>
      live().where((SemanticsNode n) => n.label == line).toList();
}

/// After an event whose announcements start at index [from]: checks the
/// channel got at least one line, that the live region shows the LAST line
/// sent (C-629 D1: the lines of a batch arrive one per frame, in order) once
/// as many frames as the batch has lines have passed, in [dir], and that it is
/// gone 1500 ms after the speak plus a frame. Returns the line.
Future<String> _expectSpoken(
  _Obs o, {
  required int from,
  required TextDirection dir,
  required String what,
  Set<String> baseline = const <String>{},
}) async {
  final List<_Say> batch = o.said.sublist(from);
  expect(
    batch,
    isNotEmpty,
    reason:
        '$what: fixture: the event must send at least one announcement '
        'on the channel; ${o.why}',
  );
  final _Say last = batch.last;
  expect(
    last.dirIndex,
    dir.index,
    reason:
        '$what: the channel direction of "${last.message}" is '
        '${last.dirIndex}, expected ${dir.index} (${dir.name}); ${o.why}',
  );

  // C-629 D1: a batch of N lines reaches the region one per frame, so the
  // last of them is there after N frames (the first N - 1 are the earlier
  // lines of the batch, each on its own frame), then it is held 1500 ms.
  for (int i = 1; i < batch.length; i++) {
    await o.pump();
  }
  await o.pump(); // the frame that shows the last line of the batch
  final List<SemanticsNode> nodes = o.liveWith(last.message);
  expect(
    nodes.length,
    1,
    reason:
        '$what: D4 expected exactly one live-region node labelled '
        '"${last.message}" on the next frame after the announcement; found '
        '${nodes.length}; live labels now: ${o.liveLabels()}; ${o.why}',
  );
  expect(
    nodes.single.textDirection,
    dir,
    reason:
        '$what: D5 expected the live-region node of "${last.message}" to '
        'carry ${dir.name}; got ${nodes.single.textDirection}; ${o.why}',
  );

  final int spoken = o.said.length;
  await o.pump(_holdMs - 100);
  expect(
    o.said.length,
    spoken,
    reason:
        '$what: fixture: nothing else may be announced in the hold window; '
        'new: ${o.said.sublist(spoken)}; ${o.why}',
  );
  expect(
    o.liveWith(last.message).length,
    1,
    reason:
        '$what: D3 expected the line still held 100 ms before the hold ends '
        '(${_holdMs - 100} ms after it was spoken); live labels: '
        '${o.liveLabels()}; ${o.why}',
  );
  await o.pump(100);
  await o.pump();
  expect(
    o.liveWith(last.message),
    isEmpty,
    reason:
        '$what: D3 expected the live-region node of "${last.message}" gone '
        '$_holdMs ms after the line plus a frame; live labels: '
        '${o.liveLabels()}; ${o.why}',
  );
  expect(
    o.liveLabels().toSet().difference(baseline),
    isEmpty,
    reason:
        '$what: P3 expected no live-region node left over from the line '
        '(baseline before the event: $baseline); live labels: '
        '${o.liveLabels()}; ${o.why}',
  );
  return last.message;
}

// ---------------------------------------------------------------------------
// GameScreen scenarios (roll_tray_harness).
// ---------------------------------------------------------------------------

typedef _GameBody = Future<void> Function(_Obs o, RollTrayDrive drive);

Future<void> _gameScenario(
  WidgetTester tester,
  String name,
  Locale locale, {
  required List<int> tokens,
  required Map<String, Object?> turn,
  required _GameBody body,
}) async {
  final _Obs o = _Obs(tester, '$name/${locale.languageCode}');
  o.install();
  final RollTrayDrive drive = await connectPlaying(
    tester,
    seats: twoSeats(mine: tokens),
    turn: turn,
  );
  try {
    await mountGame(tester, drive, locale: locale);
    o.steps.add('mounted GameScreen tokens=$tokens');
    await body(o, drive);
  } finally {
    await releaseGame(tester, drive);
    o.remove();
  }
}

Future<void> _pushNoMoveRoll(_Obs o, RollTrayDrive drive) async {
  o.steps.add('push rolled(3, legal=[]), turn_passed, turn(seat 1)');
  await pushMyNoMoveRoll(o.tester, drive, face: 3);
}

Future<void> _pushArm(_Obs o, RollTrayDrive drive) async {
  o.steps.add('push turn(seat 0, await_move, value 5, legal [0])');
  await drive.push(o.tester, 'turn', <String, Object?>{
    'seat': 0,
    'phase': 'await_move',
    'deadline_ms': rollTrayDeadlineMs,
    'k': 1,
    'value': 5,
    'legal': <int>[0],
  });
}

const List<int> _yardTokens = <int>[-1, -1, -1, -1];
const List<int> _oneMoveTokens = <int>[2, -1, -1, -1];

Map<String, Object?> _awaitRoll() =>
    turnJson(seat: 0, phase: 'await_roll', k: 0, queue: const <int>[]);

Map<String, Object?> _awaitRollNoQueue() =>
    turnJson(seat: 0, phase: 'await_roll', k: 0);

// ---------------------------------------------------------------------------
// LobbyScreen scenario (the friend_joined_test.dart rig, trimmed).
// ---------------------------------------------------------------------------

const String _lobbyUrl = 'wss://c624-wiring-test.invalid/ws';

int _serverIdSeq = 0;
String _frameJson(String type, Map<String, Object?> data, {String? re}) {
  _serverIdSeq += 1;
  return jsonEncode(<String, Object?>{
    'v': 1,
    't': type,
    'id': 'c624-wiring-${_serverIdSeq.toString().padLeft(6, '0')}',
    're': ?re,
    'd': data,
  });
}

Map<String, Object?> _lobbySeat(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _lobbyRoom(List<String> names, int players) =>
    <String, Object?>{
      'code': 'ABC234',
      'state': 'LOBBY',
      'host_seat': 0,
      'players': players,
      'rules': <String, Object?>{
        'blocks': true,
        'capture_bonus': true,
        'turn_seconds': 45,
      },
      'chain_commit': 'a' * 64,
      'chain_index': 0,
      'game_id': null,
      'client_seeds': null,
      'seats': <Map<String, Object?>>[
        for (int i = 0; i < names.length; i++) _lobbySeat(i, names[i]),
      ],
      'turn': null,
      'winner': null,
      'seq': 1,
    };

class _OneShotConnector {
  _OneShotConnector(this.transport);
  final FakeTransport transport;
  bool used = false;

  Future<WireTransport> call(Uri url) async {
    if (used) {
      throw StateError('_OneShotConnector: second connect to $url');
    }
    used = true;
    return transport;
  }
}

class _LobbyRig {
  _LobbyRig(this.o, this.controller, this.transport);
  final _Obs o;
  final RoomController controller;
  final FakeTransport transport;
  int seq = 1;

  /// One `player_joined` frame with the next seq, then the two bare pumps
  /// the sibling lobby suites use; no fake time passes.
  Future<void> join(int seat, String name) async {
    seq += 1;
    o.steps.add('push player_joined seat=$seat name=$name');
    transport.pushText(
      _frameJson('player_joined', <String, Object?>{
        'seat': seat,
        'name': name,
        'seq': seq,
      }),
    );
    await o.tester.pump();
    await o.tester.pump();
  }
}

typedef _LobbyBody = Future<void> Function(_LobbyRig rig);

Future<void> _lobbyScenario(
  WidgetTester tester,
  String name,
  Locale locale,
  _LobbyBody body,
) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final _Obs o = _Obs(tester, '$name/${locale.languageCode}');
  o.install();
  final FakeTransport transport = FakeTransport();
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_lobbyUrl),
    connect: _OneShotConnector(transport).call,
  );
  try {
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
          service: const NoopFeedbackService(),
          child: LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 4,
          ),
        ),
      ),
    );
    await tester.pump();
    final String requestId =
        (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
            as String;
    transport.pushText(
      _frameJson('seat_assigned', <String, Object?>{
        'seat': 0,
        'seat_token': 'tok-0',
      }),
    );
    transport.pushText(
      _frameJson('room', _lobbyRoom(<String>['Sam'], 4), re: requestId),
    );
    await tester.pump();
    await tester.pump();
    o.steps.add('mounted LobbyScreen as host, one seat, 4 players');
    expect(
      controller.room?.seats.length,
      1,
      reason: 'fixture: the room must hold one seat; ${o.why}',
    );
    await body(_LobbyRig(o, controller, transport));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    o.remove();
  }
}

void main() {
  // =========================================================================
  // (h) / (j) GameScreen G1: my own roll with no legal move.
  // =========================================================================
  group('(h)/(j) GameScreen: my roll with no legal move', () {
    for (final Locale locale in _locales) {
      // Kills a screen that sends the announcement and no live region, a
      // region that shows another line than the one announced, a region
      // with the wrong direction, and a line that never leaves.
      testWidgets('${locale.languageCode}: the announced line rides a live '
          'region for 1500 ms', (WidgetTester tester) async {
        await _gameScenario(
          tester,
          'G1-no-move',
          locale,
          tokens: _yardTokens,
          turn: _awaitRoll(),
          body: (_Obs o, RollTrayDrive drive) async {
            final Set<String> baseline = o.liveLabels().toSet();
            final int from = o.said.length;
            await _pushNoMoveRoll(o, drive);
            final String line = await _expectSpoken(
              o,
              from: from,
              dir: _dirOf(locale),
              what: '(h)/(j) G1',
              baseline: baseline,
            );
            expect(
              line,
              locale.languageCode == 'ar' ? _needSixAr : _needSixEn,
              reason:
                  'fixture: the announced line is the C-474 NEED_SIX line; '
                  '${o.why}',
            );
          },
        );
      });
    }

    // Kills a screen that speaks lines nobody announced: before any event
    // nothing a region could have put there is on the tree.
    testWidgets('before any event the screen carries no live-region node '
        'with a spoken line', (WidgetTester tester) async {
      await _gameScenario(
        tester,
        'G1-quiet',
        const Locale('en'),
        tokens: _yardTokens,
        turn: _awaitRoll(),
        body: (_Obs o, RollTrayDrive drive) async {
          await o.pump(500);
          expect(
            o.said,
            isEmpty,
            reason: 'fixture: a quiet screen announces nothing; ${o.why}',
          );
          expect(
            o.liveLabels().where((String l) => l.isNotEmpty),
            isEmpty,
            reason:
                'P3: a quiet screen has no live-region node carrying text; '
                'got ${o.liveLabels()}; ${o.why}',
          );
        },
      );
    });
  });

  // =========================================================================
  // (h) / (j) GameScreen G2: the auto-move.
  // =========================================================================
  group('(h)/(j) GameScreen: the auto-move', () {
    for (final Locale locale in _locales) {
      // Kills a screen that wires only one of its two announce sites
      // (_announce, _announceAutoMove): the arm batch goes through both.
      testWidgets('${locale.languageCode}: the arming line batch rides a '
          'live region and clears', (WidgetTester tester) async {
        await _gameScenario(
          tester,
          'G2-arm',
          locale,
          tokens: _oneMoveTokens,
          turn: _awaitRollNoQueue(),
          body: (_Obs o, RollTrayDrive drive) async {
            // The hold window ends on the instant the auto-move sends its own
            // line, so that later line may legitimately be on the tree when
            // the arming batch's line has left.
            final AppLocalizations loc = AppLocalizations.of(
              o.tester.element(find.byType(GameScreen)),
            );
            final Set<String> baseline = <String>{
              ...o.liveLabels(),
              loc.gameTokenButton(1),
            };
            final int from = o.said.length;
            await _pushArm(o, drive);
            await _expectSpoken(
              o,
              from: from,
              dir: _dirOf(locale),
              what: '(h)/(j) G2 arm',
              baseline: baseline,
            );
          },
        );
      });

      // Kills a screen that wires `_announce` but not `_announceAutoMove`:
      // the send line is spoken through the second one. The pump to the
      // send also lands on the instant the arming line's hold ends, so a
      // hold timer that outlives its line would clear the send line here.
      testWidgets('${locale.languageCode}: the auto-move send line rides a '
          'live region and clears', (WidgetTester tester) async {
        await _gameScenario(
          tester,
          'G2-send',
          locale,
          tokens: _oneMoveTokens,
          turn: _awaitRollNoQueue(),
          body: (_Obs o, RollTrayDrive drive) async {
            await _pushArm(o, drive);
            final int from = o.said.length;
            await o.pump(1500);
            final AppLocalizations loc = AppLocalizations.of(
              o.tester.element(find.byType(GameScreen)),
            );
            expect(
              o.said.sublist(from).map((_Say s) => s.message).toList(),
              <String>[loc.gameTokenButton(1)],
              reason:
                  'fixture: the auto-move send announces the token line at '
                  '1500 ms; ${o.why}',
            );
            await _expectSpoken(
              o,
              from: from,
              dir: _dirOf(locale),
              what: '(h)/(j) G2 send',
            );
          },
        );
      });
    }
  });

  // =========================================================================
  // (i) / (j) LobbyScreen L1: a friend joins.
  // =========================================================================
  group('(i)/(j) LobbyScreen: a friend joins', () {
    for (final Locale locale in _locales) {
      // Kills a lobby that announces and has no live region, one that
      // wires the wrong text, or one with the wrong direction.
      testWidgets('${locale.languageCode}: the friend-joined line rides a '
          'live region for 1500 ms', (WidgetTester tester) async {
        await _lobbyScenario(tester, 'L1-friend-joined', locale, (
          _LobbyRig rig,
        ) async {
          final _Obs o = rig.o;
          final Set<String> baseline = o.liveLabels().toSet();
          final int from = o.said.length;
          await rig.join(1, 'Karim');
          final String line = await _expectSpoken(
            o,
            from: from,
            dir: _dirOf(locale),
            what: '(i)/(j) L1',
            baseline: baseline,
          );
          final AppLocalizations loc = AppLocalizations.of(
            tester.element(find.byType(LobbyScreen)),
          );
          expect(
            line,
            loc.lobbyFriendJoined('Karim'),
            reason:
                'fixture: the announced line is lobbyFriendJoined("Karim"); '
                '${o.why}',
          );
        });
      });
    }

    // Kills a lobby region that is only built after a first join, or whose
    // controller is torn down after the first line: a second friend, well
    // after the first line left, is spoken too.
    testWidgets('a second friend after the first line left is spoken too', (
      WidgetTester tester,
    ) async {
      await _lobbyScenario(tester, 'L1-two-friends', const Locale('en'), (
        _LobbyRig rig,
      ) async {
        final _Obs o = rig.o;
        int from = o.said.length;
        await rig.join(1, 'Karim');
        await _expectSpoken(
          o,
          from: from,
          dir: TextDirection.ltr,
          what: '(i) first friend',
        );
        from = o.said.length;
        await rig.join(2, 'Lina');
        await _expectSpoken(
          o,
          from: from,
          dir: TextDirection.ltr,
          what: '(i) second friend',
        );
      });
    });
  });

  // =========================================================================
  // (k) the announcement count per event is the base's.
  // =========================================================================
  group('(k) announcements per event, as on the base commit', () {
    for (final Locale locale in _locales) {
      // Kills a wiring that sends one more or one fewer channel
      // announcement (for instance by replacing sendAnnouncement with the
      // region, or by speaking twice), or reorders them.
      testWidgets('${locale.languageCode}: G1 sends exactly the one '
          'no-move line, once, and nothing in the 3 s after', (
        WidgetTester tester,
      ) async {
        await _gameScenario(
          tester,
          'k-G1',
          locale,
          tokens: _yardTokens,
          turn: _awaitRoll(),
          body: (_Obs o, RollTrayDrive drive) async {
            final int from = o.said.length;
            await _pushNoMoveRoll(o, drive);
            await o.pump();
            await o.pump(3000);
            expect(
              o.said.sublist(from).map((_Say s) => s.message).toList(),
              <String>[locale.languageCode == 'ar' ? _needSixAr : _needSixEn],
              reason:
                  '(k) base 5409b33 sends exactly one announcement for this '
                  'event; ${o.why}',
            );
          },
        );
      });

      testWidgets('${locale.languageCode}: G2 sends the arming line then '
          'the your-turn line in one frame, then one send line at 1500 ms, '
          'nothing after', (WidgetTester tester) async {
        await _gameScenario(
          tester,
          'k-G2',
          locale,
          tokens: _oneMoveTokens,
          turn: _awaitRollNoQueue(),
          body: (_Obs o, RollTrayDrive drive) async {
            final AppLocalizations loc = AppLocalizations.of(
              o.tester.element(find.byType(GameScreen)),
            );
            final int from = o.said.length;
            await _pushArm(o, drive);
            expect(
              o.said.sublist(from).map((_Say s) => s.message).toList(),
              <String>[loc.announceAutoMoveArmed(1), loc.gameYourTurnStale],
              reason:
                  '(k) base 5409b33 sends the arming line then the '
                  'your-turn line for this event; ${o.why}',
            );
            await o.pump(1500);
            await o.pump();
            await o.pump(3000);
            expect(
              o.said.sublist(from).map((_Say s) => s.message).toList(),
              <String>[
                loc.announceAutoMoveArmed(1),
                loc.gameYourTurnStale,
                loc.gameTokenButton(1),
              ],
              reason:
                  '(k) base 5409b33 sends exactly one more line (the token '
                  'line) when the auto-move fires and nothing after; '
                  '${o.why}',
            );
          },
        );
      });

      testWidgets('${locale.languageCode}: L1 sends exactly one friend-'
          'joined line per join and nothing in the 3 s after', (
        WidgetTester tester,
      ) async {
        await _lobbyScenario(tester, 'k-L1', locale, (_LobbyRig rig) async {
          final _Obs o = rig.o;
          final int from = o.said.length;
          await rig.join(1, 'Karim');
          await o.pump();
          await o.pump(3000);
          final AppLocalizations loc = AppLocalizations.of(
            o.tester.element(find.byType(LobbyScreen)),
          );
          expect(
            o.said.sublist(from).map((_Say s) => s.message).toList(),
            <String>[loc.lobbyFriendJoined('Karim')],
            reason:
                '(k) base 5409b33 sends exactly one announcement per join; '
                '${o.why}',
          );
        });
      });
    }
  });

  // =========================================================================
  // (l) leaving a screen mid-hold.
  // =========================================================================
  group('(l) leaving the screen mid-hold', () {
    // Kills a screen whose spoken-line controller outlives the screen: its
    // hold timer would still be pending when the test ends (the framework
    // fails a test that ends with a pending timer). The test ends 300 ms
    // into the hold plus one frame, so 1200 ms of it are still to run.
    testWidgets('GameScreen unmounted 300 ms into a hold: no pending timer', (
      WidgetTester tester,
    ) async {
      await _gameScenario(
        tester,
        'l-game',
        const Locale('en'),
        tokens: _yardTokens,
        turn: _awaitRoll(),
        body: (_Obs o, RollTrayDrive drive) async {
          await _pushNoMoveRoll(o, drive);
          await o.pump();
          await o.pump(300);
          expect(
            o.said,
            isNotEmpty,
            reason: 'fixture: the event announced; ${o.why}',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          o.steps.add('unmounted GameScreen');
          await o.pump(); // 1200 ms of the hold are still to run
          expect(
            tester.takeException(),
            isNull,
            reason: 'the unmounted screen raised an error; ${o.why}',
          );
          expect(
            o.liveLabels(),
            isEmpty,
            reason:
                'P3: no live-region node survives the screen; got '
                '${o.liveLabels()}; ${o.why}',
          );
        },
      );
    });

    testWidgets('LobbyScreen unmounted 300 ms into a hold: no pending timer', (
      WidgetTester tester,
    ) async {
      await _lobbyScenario(tester, 'l-lobby', const Locale('en'), (
        _LobbyRig rig,
      ) async {
        final _Obs o = rig.o;
        await rig.join(1, 'Karim');
        await o.pump();
        await o.pump(300);
        expect(
          o.said,
          isNotEmpty,
          reason: 'fixture: the join announced; ${o.why}',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        o.steps.add('unmounted LobbyScreen');
        await o.pump(); // 1200 ms of the hold are still to run
        expect(
          tester.takeException(),
          isNull,
          reason: 'the unmounted screen raised an error; ${o.why}',
        );
        expect(
          o.liveLabels(),
          isEmpty,
          reason:
              'P3: no live-region node survives the screen; got '
              '${o.liveLabels()}; ${o.why}',
        );
      });
    });
  });
}
