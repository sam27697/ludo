// Proof for order 714 (the join sheet is gone by the time the player comes
// back from a room), written from the order's design and docs/PROTOCOL.md,
// not from the sheet's code.
//
// The design under test: the join sheet stays up only while the outcome of a
// typed-code join is unknown, and afterwards only for a ban. Once the join is
// accepted and the room's route has finished its push, the sheet's route is
// gone from under it. Coming back from the room (system back, kicked, room
// closed, leaving a game) home shows at the first frame, with no sheet.
//
// Every row runs in English and Arabic at 320x640 and at 412x915 over a real
// HomeScreen on the project's fake transport (the C-701 rig). A failure names
// the variant, the row, the frames the fake server sent and the command that
// reruns just that row. There is no random input; the row name is the whole
// scenario.
//
// "Drawn" is checked on the painted tree, not on a settled finder: a
// `join-sheet` element counts as drawn when it sits in an onstage overlay
// entry (the finder's default skips offstage entries, which the overlay does
// not paint) and its render box intersects the screen. A sheet sliding away at
// partial height is still drawn. The ban row uses the same probe the other way
// round (the sheet must be drawn there), so the probe is proved to see a
// sheet when one is up.
//
// Readings this file takes where the order leaves a choice:
//   - "Once the lobby is on screen and its push has finished": the room
//     route's animation reports completed, then one more frame is pumped (the
//     removal may be applied on the frame after the push completes).
//   - "The FIRST frame after the pop begins": the room route stops being
//     active or its animation turns to reverse; the next frame pumped (no
//     clock advance) is the first frame, and +50, +250 and +300 ms are
//     measured from it on the fake clock.
//   - "When the pop ends": no LobbyScreen and no GameScreen is left in the
//     tree, offstage included.
//   - Room closed: the lobby's socket ends from the far side, Reconnect sends
//     `resume`, the server answers NO_SUCH_ROOM (the C-529 D3 path that ends
//     on home-room-closed-notice). Automatic reconnection is off in that row
//     so the resume is the one Reconnect sends.
//   - Leaving a game: a PLAYING room, the corner leave control, then Leave in
//     the confirm sheet (C-658).
//   - NO_SUCH_ROOM: "its notice" is read as the refusal the player is shown
//     for that join, the lobby error card reading lobbyErrorNoSuchRoom, after
//     which Back to home ends on home. The order gives no home-side key for a
//     refused typed join.
//   - Held-seat resume: a seat record with no saved time (so home does not
//     resume on its own at mount); typing that room's code sends `resume`,
//     answered `seat_assigned` + a PLAYING `room`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/home_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';

import 'net/fake_transport.dart';
import 'support/c701_harness.dart';
import 'support/home_flow.dart';

const String _file = 'c714_join_sheet_gone_test.dart';
const String _code = 'K7M2QP';
const String _token = 'tok-c714-seat';
const String _heldToken = 'tok-c714-held';

const Key _codeBanNoticeKey = Key('code-ban-notice');
const Key _lobbyErrorKey = Key('lobby-error');
const Key _lobbyLeaveKey = Key('lobby-leave-button');
const Key _lobbyReconnectKey = Key('lobby-reconnect-button');
const Key _roomClosedNoticeKey = Key('home-room-closed-notice');
const Key _gameLeaveCornerKey = Key('game-screen-appbar-leave');
const Key _gameLeaveConfirmKey = Key('game-leave-confirm');
const Key _gameLeaveConfirmLeaveKey = Key('game-leave-confirm-leave');

const Duration _frame = Duration(milliseconds: 16);

/// The instants after the first frame of the pop at which the sheet is
/// probed, as offsets from that frame.
const List<int> _instantsMs = <int>[0, 50, 250, 300];

void _row(
  String name,
  Future<void> Function(_Case c) body, {
  List<Duration>? reconnectDelays,
}) {
  for (final C701Variant v in kVariants) {
    final String full = '${v.id}: $name';
    testWidgets(full, (WidgetTester tester) async {
      final C701Rig rig = reconnectDelays == null
          ? C701Rig(tester, v, file: _file, row: full)
          : C701Rig(
              tester,
              v,
              file: _file,
              row: full,
              reconnectDelays: reconnectDelays,
            );
      await runRow(rig, () => body(_Case(rig)));
    });
  }
}

/// One row: the rig and the steps played so far, which every failure carries.
class _Case {
  _Case(this.r);

  final C701Rig r;
  final List<String> steps = <String>[];

  WidgetTester get t => r.tester;

  String get why => 'steps: ${steps.join(' > ')}. ${r.repro}';

  void step(String s) => steps.add(s);

  // ---- the sheet, as painted -------------------------------------------

  /// A description of every `join-sheet` element that is painted this
  /// frame, or null when none is.
  String? sheetDrawn() {
    final Rect screen = Offset.zero & r.variant.size;
    final List<String> seen = <String>[];
    for (final Element e in find.byKey(joinSheetKey).evaluate()) {
      final RenderObject? ro = e.renderObject;
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) {
        continue;
      }
      final Rect rect = ro.localToGlobal(Offset.zero) & ro.size;
      final Rect visible = rect.intersect(screen);
      if (visible.width > 0 && visible.height > 0) {
        seen.add('onstage at $rect, visible part $visible');
      }
    }
    return seen.isEmpty ? null : seen.join('; ');
  }

  /// Every `join-sheet` in the tree, offstage included, with its route.
  String sheetTree() {
    final List<Element> all = find
        .byKey(joinSheetKey, skipOffstage: false)
        .evaluate()
        .toList();
    if (all.isEmpty) {
      return 'no join-sheet in the tree';
    }
    final Set<Element> onstage = find.byKey(joinSheetKey).evaluate().toSet();
    return all
        .map((Element e) {
          final ModalRoute<Object?>? route = ModalRoute.of(e);
          return 'join-sheet ${onstage.contains(e) ? 'onstage' : 'offstage'}'
              ', route ${route.runtimeType} active=${route?.isActive} '
              'status=${route?.animation?.status}';
        })
        .join('; ');
  }

  void expectNoSheetInTree(String when) {
    expect(
      find.byKey(joinSheetKey, skipOffstage: false),
      findsNothing,
      reason:
          'expected no join-sheet anywhere in the tree $when; found '
          '${sheetTree()}. $why',
    );
  }

  void expectSheetNotDrawn(String when) {
    final String? drawn = sheetDrawn();
    expect(
      drawn,
      isNull,
      reason:
          'expected no join-sheet drawn $when; it was painted: $drawn '
          '(${sheetTree()}). $why',
    );
  }

  // ---- the room route ----------------------------------------------------

  Finder get _anyRoomScreen => find.byWidgetPredicate(
    (Widget w) => w is LobbyScreen || w is GameScreen,
    skipOffstage: false,
  );

  bool get roomInTree => _anyRoomScreen.evaluate().isNotEmpty;

  /// Waits for [screen] on screen, then for its route's push to finish, and
  /// pumps one more frame. Returns that route.
  Future<ModalRoute<Object?>> roomPushed(Type screen, String what) async {
    final Finder f = find.byType(screen);
    await r.waitUntil(
      () => f.evaluate().isNotEmpty,
      '$screen on screen ($what); ${steps.join(' > ')}',
    );
    final ModalRoute<Object?>? route = ModalRoute.of(t.element(f.first));
    expect(route, isNotNull, reason: '$screen has no route. $why');
    for (int i = 0; i < 120; i++) {
      if (route!.animation!.status == AnimationStatus.completed) {
        break;
      }
      await t.pump(_frame);
    }
    expect(
      route!.animation!.status,
      AnimationStatus.completed,
      reason:
          'expected the $screen route push to finish within 1920 ms; status '
          '${route.animation!.status}. $why',
    );
    await t.pump();
    return route;
  }

  static bool _popping(ModalRoute<Object?> route) =>
      !route.isActive ||
      route.animation!.status == AnimationStatus.reverse ||
      route.animation!.status == AnimationStatus.dismissed;

  /// After a trigger that pops [route]: waits frame by frame for the pop to
  /// begin, probes the sheet at the first frame after it and at +50, +250 and
  /// +300 ms, waits for the pop to end, then requires home with
  /// `join-game-button` hittable and no sheet in the tree.
  Future<void> probePop(ModalRoute<Object?> route, String trigger) async {
    int waited = 0;
    for (int i = 0; i < 200 && !_popping(route); i++) {
      // A few frames without a clock advance first, so a pop started by an
      // inbound frame is caught before its animation has moved.
      final Duration d = i < 4 ? Duration.zero : _frame;
      await t.pump(d);
      waited += d.inMilliseconds;
    }
    expect(
      _popping(route),
      isTrue,
      reason:
          'expected the room route to start popping after $trigger; after '
          '$waited ms it is active=${route.isActive} status '
          '${route.animation!.status}. $why',
    );
    step('pop began after $trigger (+$waited ms)');
    await t.pump();
    int at = 0;
    for (final int ms in _instantsMs) {
      if (ms > at) {
        await t.pump(Duration(milliseconds: ms - at));
        at = ms;
      }
      expectSheetNotDrawn(
        ms == 0
            ? 'at the first frame after the pop began ($trigger)'
            : 'at +$ms ms after the first frame of the pop ($trigger)',
      );
    }
    for (int i = 0; i < 120 && roomInTree; i++) {
      await t.pump(_frame);
    }
    expect(
      roomInTree,
      isFalse,
      reason:
          'expected the room route gone within 1920 ms of +300 ms after '
          '$trigger; still in the tree. $why',
    );
    step('pop ended');
    expect(
      find.byKey(joinGameButtonKey).hitTestable(),
      findsOneWidget,
      reason:
          'expected join-game-button hittable on home when the pop ends '
          '($trigger); a tap at its centre does not reach it '
          '(${sheetTree()}). $why',
    );
    expectNoSheetInTree('when the pop ends ($trigger)');
  }

  // ---- driving -----------------------------------------------------------

  /// Name, Join, code tile, the code, Join: up to the join_room on the wire.
  Future<void> typedJoin() async {
    await r.mount();
    await joinFromHome();
  }

  Future<void> joinFromHome() async {
    step('type name');
    await r.typeName();
    step('open code entry');
    await r.openCodeEntryCounted();
    step('type $_code');
    await t.enterText(find.byKey(roomCodeFieldKey), _code);
    await t.pump();
    step('tap join-room-button');
    await r.tap(find.byKey(joinRoomButtonKey), what: 'join-room-button');
  }

  Future<String> joinSent() async {
    await r.waitUntil(
      () => r.sent('join_room').isNotEmpty,
      'join_room after the typed code; ${steps.join(' > ')}',
    );
    expect(
      r.sent('join_room'),
      hasLength(1),
      reason: 'fixture: expected one join_room. $why',
    );
    return r.idOfLast('join_room');
  }

  /// A typed join answered `seat_assigned` + `room` (LOBBY, seat 1).
  /// Returns the lobby's route once its push has finished.
  Future<ModalRoute<Object?>> joinedLobby() async {
    await typedJoin();
    final String id = await joinSent();
    step('server: seat_assigned seat 1');
    await r.push('seat_assigned', <String, Object?>{
      'seat': 1,
      'seat_token': _token,
    });
    step('server: room LOBBY re join_room');
    await r.push(
      'room',
      r.roomJson(code: _code, players: 2, open: false),
      re: id,
    );
    return roomPushed(LobbyScreen, 'after the join was answered');
  }

  Map<String, Object?> playingRoom({required int mySeat, required int seq}) =>
      <String, Object?>{
        'code': _code,
        'state': 'PLAYING',
        'host_seat': 0,
        'players': 2,
        'open': false,
        'rules': const <String, Object?>{
          'blocks': true,
          'capture_bonus': true,
          'turn_seconds': 45,
        },
        'chain_commit': 'a' * 64,
        'chain_index': 0,
        'game_id': 'g-c714',
        'client_seeds': '0:host-seed|1:guest-seed',
        'seats': <Map<String, Object?>>[
          r.seatJson(0, mySeat == 0 ? r.defaultName : 'Host'),
          r.seatJson(1, mySeat == 1 ? r.defaultName : 'Guest'),
        ],
        'turn': <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
        'winner': null,
        'seq': seq,
      };
}

void main() {
  group('C-714 an accepted typed join leaves no sheet under the room', () {
    _row('join answered seat_assigned + room: no join-sheet once the lobby '
        'push has finished', (_Case c) async {
      await c.joinedLobby();
      c.expectNoSheetInTree(
        'once the lobby is on screen and its push has finished',
      );
    });
  });

  group('C-714 coming back from the room shows home at the first frame', () {
    _row('system back from the lobby: no join-sheet drawn at the first frame, '
        '+50, +250, +300 ms; join-game-button hittable at the end', (
      _Case c,
    ) async {
      final ModalRoute<Object?> lobby = await c.joinedLobby();
      c.step('system back');
      await c.t.binding.handlePopRoute();
      await c.probePop(lobby, 'the system back');
    });

    _row('kicked from the lobby: no join-sheet drawn at the first frame, '
        '+50, +250, +300 ms; join-game-button hittable at the end', (
      _Case c,
    ) async {
      final ModalRoute<Object?> lobby = await c.joinedLobby();
      c.step('server: kicked');
      c.r.transport.pushText(c.r.frame('kicked', <String, Object?>{}));
      await c.probePop(lobby, 'kicked');
      expect(
        find.text(c.r.loc.knockWasKicked),
        findsOneWidget,
        reason:
            'fixture: expected home to say "${c.r.loc.knockWasKicked}" after '
            'kicked. ${c.why}',
      );
    });

    _row('room closed while away (resume answered NO_SUCH_ROOM): no join-sheet '
        'drawn at the first frame, +50, +250, +300 ms; join-game-button '
        'hittable at the end', (_Case c) async {
      final ModalRoute<Object?> lobby = await c.joinedLobby();
      final FakeTransport first = c.r.transport;
      c.step('socket ends from the far side');
      first.endFromFarSide();
      await c.t.pump();
      await c.t.pump();
      await c.r.waitUntil(
        () => find.byKey(_lobbyReconnectKey).evaluate().isNotEmpty,
        'lobby-reconnect-button after the socket ended; '
        '${c.steps.join(' > ')}',
      );
      c.step('tap lobby-reconnect-button');
      final int before = c.r.transports.length;
      await c.t.ensureVisible(find.byKey(_lobbyReconnectKey));
      await c.t.pump();
      await c.t.tap(find.byKey(_lobbyReconnectKey));
      await c.t.pump();
      await c.r.waitUntil(
        () =>
            c.r.transports.length > before &&
            c.r.transports.last.sentRaw.any(
              (String s) => frameType(s) == 'resume',
            ),
        'a resume on a new transport after Reconnect; '
        '${c.steps.join(' > ')}',
      );
      final String resumeId = c.r.idOfLast('resume');
      c.step('server: error NO_SUCH_ROOM re resume');
      c.r.transport.pushText(
        c.r.frame('error', <String, Object?>{
          'code': 'NO_SUCH_ROOM',
          'message': 'NO_SUCH_ROOM',
        }, re: resumeId),
      );
      await c.probePop(lobby, 'the room closed');
      expect(
        find.byKey(_roomClosedNoticeKey),
        findsOneWidget,
        reason:
            'fixture: expected home-room-closed-notice on home after the '
            'resume was answered NO_SUCH_ROOM. ${c.why}',
      );
    }, reconnectDelays: const <Duration>[]);

    _row('leaving a game: no join-sheet drawn at the first frame, +50, +250, '
        '+300 ms; join-game-button hittable at the end', (_Case c) async {
      await c.joinedLobby();
      c.step('server: room PLAYING seq 2');
      await c.r.push('room', c.playingRoom(mySeat: 1, seq: 2));
      final ModalRoute<Object?> game = await c.roomPushed(
        GameScreen,
        'after the room went PLAYING',
      );
      c.step('tap game-screen-appbar-leave');
      await c.r.tap(
        find.byKey(_gameLeaveCornerKey),
        what: 'game-screen-appbar-leave',
      );
      // C-658: leaving a PLAYING game asks first; Leave in that sheet is
      // the tap that starts the pop.
      await pumpUntilFound(
        c.t,
        find.byKey(_gameLeaveConfirmKey),
        what: 'fixture: game-leave-confirm after the corner leave. ${c.why}',
      );
      await pumpUntilAtRest(
        c.t,
        find.byKey(_gameLeaveConfirmLeaveKey),
        what: 'game-leave-confirm-leave. ${c.why}',
      );
      c.step('tap game-leave-confirm-leave');
      await c.t.tap(find.byKey(_gameLeaveConfirmLeaveKey));
      await c.probePop(game, 'leaving the game');
    });
  });

  group('C-714 outcomes that keep today\'s behaviour', () {
    _row('CODE_BANNED with a usable ban keeps the sheet open with '
        'code-ban-notice', (_Case c) async {
      await c.typedJoin();
      final String id = await c.joinSent();
      c.step('server: error CODE_BANNED with ban');
      await c.r.push('error', <String, Object?>{
        'code': 'CODE_BANNED',
        'message': 'code joins are blocked',
        'ban': <String, Object?>{
          'scope': 'device',
          'until_ms': 4102444800000,
          'level': 1,
          'next_ms': 7 * 86400000,
        },
      }, re: id);
      await c.r.waitUntil(
        () => find.byKey(_codeBanNoticeKey).evaluate().isNotEmpty,
        'code-ban-notice after CODE_BANNED; ${c.steps.join(' > ')}',
      );
      for (int i = 0; i < 120 && c.roomInTree; i++) {
        await c.t.pump(_frame);
      }
      expect(
        c.roomInTree,
        isFalse,
        reason: 'expected no room route left up after a ban. ${c.why}',
      );
      await pumpUntilAtRest(
        c.t,
        find.byKey(joinSheetKey),
        what: 'join-sheet at rest after the ban. ${c.why}',
      );
      expect(
        c.sheetDrawn(),
        isNotNull,
        reason:
            'expected the join sheet drawn after a ban; it is not '
            '(${c.sheetTree()}). ${c.why}',
      );
      expect(
        find.descendant(
          of: find.byKey(joinSheetKey),
          matching: find.byKey(_codeBanNoticeKey),
        ),
        findsOneWidget,
        reason: 'expected code-ban-notice inside the join sheet. ${c.why}',
      );
      expect(
        find
            .descendant(
              of: find.byKey(joinSheetKey),
              matching: find.byKey(roomCodeFieldKey),
            )
            .hitTestable(),
        findsOneWidget,
        reason:
            'expected the code field in the sheet, reachable, after a ban. '
            '${c.why}',
      );
    });

    _row('NO_SUCH_ROOM shows the lobby error, then Back to home ends on home '
        'with no sheet', (_Case c) async {
      await c.typedJoin();
      final String id = await c.joinSent();
      c.step('server: error NO_SUCH_ROOM re join_room');
      await c.r.pushError('NO_SUCH_ROOM', re: id);
      await c.r.waitUntil(
        () => find.byKey(_lobbyErrorKey).evaluate().isNotEmpty,
        'lobby-error after NO_SUCH_ROOM; ${c.steps.join(' > ')}',
      );
      expect(
        find.descendant(
          of: find.byKey(_lobbyErrorKey),
          matching: find.text(c.r.loc.lobbyErrorNoSuchRoom),
        ),
        findsOneWidget,
        reason:
            'expected the lobby error to read "${c.r.loc.lobbyErrorNoSuchRoom}"'
            '. ${c.why}',
      );
      c.step('tap lobby-leave-button');
      await c.r.tap(find.byKey(_lobbyLeaveKey), what: 'lobby-leave-button');
      for (int i = 0; i < 120 && c.roomInTree; i++) {
        await c.t.pump(_frame);
      }
      expect(
        c.roomInTree,
        isFalse,
        reason: 'expected the lobby route gone after Back to home. ${c.why}',
      );
      // The sheet closes with its usual motion here (unchanged behaviour):
      // wait for it, bounded, then require home and no sheet.
      await pumpUntilGone(
        c.t,
        find.byKey(joinSheetKey, skipOffstage: false),
        what: 'join-sheet after Back to home. ${c.why}',
      );
      expect(
        find.byType(HomeScreen),
        findsOneWidget,
        reason: 'expected home after Back to home. ${c.why}',
      );
      expect(
        find.byKey(joinGameButtonKey).hitTestable(),
        findsOneWidget,
        reason: 'expected join-game-button hittable on home. ${c.why}',
      );
      c.expectNoSheetInTree('after Back to home from NO_SUCH_ROOM');
    });
  });

  group('C-714 a held seat resumed by typed code', () {
    _row('a typed code of the held seat resumes and leaves no sheet under the '
        'room', (_Case c) async {
      await c.r.mount(
        prefs: <String, Object>{
          'session.seat': <String>[_code, '0', _heldToken],
        },
      );
      await c.joinFromHome();
      await c.r.waitUntil(
        () => c.r.sent('resume').isNotEmpty,
        'a resume for the held seat; ${c.steps.join(' > ')}',
      );
      expect(
        c.r.sent('join_room'),
        isEmpty,
        reason: 'fixture: a held seat resumes, it sends no join_room. ${c.why}',
      );
      final Map<String, Object?> d =
          c.r.sent('resume').single['d']! as Map<String, Object?>;
      expect(
        d,
        <String, Object?>{'code': _code, 'seat_token': _heldToken},
        reason: 'fixture: resume must carry the held code and token. ${c.why}',
      );
      final String id = c.r.idOfLast('resume');
      c.step('server: seat_assigned seat 0');
      await c.r.push('seat_assigned', <String, Object?>{
        'seat': 0,
        'seat_token': _heldToken,
      });
      c.step('server: room PLAYING re resume');
      await c.r.push('room', c.playingRoom(mySeat: 0, seq: 10), re: id);
      await c.roomPushed(GameScreen, 'after the resume was answered');
      c.expectNoSheetInTree(
        'once the resumed game is on screen and its push has finished',
      );
    });
  });
}
