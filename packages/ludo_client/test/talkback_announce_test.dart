// Conformance tests for work/ludo/orders/C-337-talkback-hears-the-game.md,
// written from that contract's own text alone. Order 337 (GameScreen) is
// built in parallel by a different hand, in a tree this file's author has
// not read; every expectation below is read off C-337's own text, never off
// 337's code. The three new arb getters (announceCapturedOther,
// announceCapturedMe, announceHome) do not exist on this tree, so this file
// matches those three cues by their literal en/ar text, straight out of the
// contract's own table, and never by a getter. lib/ is not touched by this
// file.
//
// Every announcement is observed the way the contract's own goal section
// says to: a mock handler on SystemChannels.accessibility, installed and
// removed inside each test body (flutter/test/material/switch_test.dart's
// own idiom for the same channel), collecting every decoded message whose
// top-level `type` is `announce`. SemanticsService.sendAnnouncement (the
// Flutter SDK, /workspace/toolchains/flutter/packages/flutter/lib/src/
// semantics/semantics_service.dart) builds an AnnounceSemanticsEvent
// (semantics_event.dart) whose `toMap()` is `{'type': 'announce', 'data':
// {'viewId': ..., 'message': ..., 'textDirection': textDirection.index}}`;
// `textDirection` is dart:ui's TextDirection, declared `{rtl, ltr}` in that
// order, so `.index` is 0 for rtl and 1 for ltr -- this file asserts against
// `TextDirection.rtl.index` / `TextDirection.ltr.index` rather than the bare
// numbers, so the reasoning survives if the SDK ever reorders the enum.
//
// GameScreen is mounted the same way test/landing_cues_test.dart and
// test/feedback_wiring_test.dart mount it: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only), under a
// FeedbackScope. The fake-transport idiom, the frame/room/seat/turn JSON
// builders, _connectTo, _mount, _locOf and the recording _FakeFeedbackService
// are copied by hand from those sibling files (and from
// test/play_surface_die_test.dart for the die's no-answer line and
// test/game_screen_connection_lost_test.dart for the connection-lost body),
// per this project's own standing instruction never to import across test
// files. One connect-and-mount per case; no pumpAndSettle while a live turn
// countdown, die pulse or no-answer timer could still be running -- every
// wait is a bounded tester.pump(Duration) or a short bounded sequence of
// them, the same lesson the sibling suites already carry.
//
// Several `moved` cases below drive `from == to` (a token already sitting
// where it lands, captured from the way test/feedback_wiring_test.dart's own
// rule-2 cases prove `cuesForFrame`'s capture/home branches without any
// travel at all): `_onFrame`'s own `isTravellingMove` check is `from != to`,
// so this frame type takes GameScreen's plain, synchronous play-the-cues
// path, never the landing hold C-268 added, which is exactly right for rule
// 1's "one case per row" claim -- the row's text must be announced the
// moment the cue is actually played, whatever that moment is for that cue.
// Rule 1's own timing claim (a capture whose landing is held) gets its own
// group below, driven with a real six-square travel, the way
// test/landing_cues_test.dart drives it.
//
// Ambiguity found and not invented around: C-337's table gives the
// `gameOver` cue's text as "existing gameOverPlayerWins(name) ... or
// gameOverEnded when there is no winner". Reading lib/src/feedback.dart's
// own cuesForFrame (read-only, for this reasoning only): a `game_over`
// frame's `gameOver` cue only ever fires when `winner` is a non-null int
// different from mySeat; `winner == null` returns `[]` -- no cue, hence
// nothing to announce. Reading test/end_card_test.dart's own
// `_endedNoWinnerGame` fixture and app_localizations.dart's doc comment on
// `gameOverPlayerWins` ("shown ... when the game has finished but no
// winning seat can be named, either because the server sent none or because
// it named a seat no longer present in the room"), the real "ended, no
// winner" case in this codebase arrives only through a `room` snapshot with
// `state: FINISHED` and no `game_over` frame ever sent at all -- a path that
// never reaches `cuesForFrame`, so no `gameOver` cue and no announcement of
// any kind is ever played for it under this contract's own rule 1 ("every
// time one of these cues is played"). The `gameOverEnded` half of that
// table row therefore looks unreachable through the one path this contract
// wires an announcement onto; this file tests only the reachable half
// (`gameOverPlayerWins(name)`, winner naming another seat) and does not
// invent a frame that would force the unreachable half to fire. This should
// be checked against whatever the implementer also concluded.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart' show kTokenStepDuration;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://talkback-announce-test.invalid/ws';

const Key _dieKey = Key('game-die');
const Key _noAnswerKey = Key('game-die-no-answer');
const Key _connectionLostKey = Key('game-screen-connection-lost');

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

// The three strings C-337 adds, which carry no getter on this tree yet --
// matched here by their literal text straight out of the contract's own
// table, never by a getter that does not exist.
const String _announceCapturedOtherEn = 'You captured a token';
const String _announceCapturedMeEn = 'Your token was captured';
const String _announceCapturedMeAr = 'ضُربت قطعتك';
const String _announceHomeEn = 'A token reached home';

// --- server-side id generation for pushed frames ----------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'talkback-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;

String _frame({
  required String type,
  String? re,
  Map<String, Object?> data = const <String, Object?>{},
  String? id,
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': id ?? _nextServerId(),
  're': ?re,
  'd': data,
});

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot ---------------

Map<String, Object?> _seatJson(
  int seat, {
  String name = '',
  bool connected = true,
  List<int> tokens = const <int>[-1, -1, -1, -1],
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': connected,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _turnJson({
  required int seat,
  required String phase,
  required int deadlineMs,
  required int k,
  int? value,
  List<int>? legal,
}) => <String, Object?>{
  'seat': seat,
  'phase': phase,
  'deadline_ms': deadlineMs,
  'k': k,
  'value': ?value,
  'legal': ?legal,
};

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  int players = 2,
  List<Map<String, Object?>>? seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': state,
  'host_seat': hostSeat,
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat, name: 'Sam')],
  'turn': turn,
  'winner': winner,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

final List<Map<String, Object?>> _twoSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam'),
  _seatJson(1, name: 'Bob'),
];

/// Seats whose starting tokens actually sit where a 3-to-9 (6-square) move
/// of mine is about to travel from, and where a captured token of the
/// opponent's actually sits -- seat 0 progress 9 and seat 1 progress 48 are
/// the same absolute track square, the identity
/// test/landing_cues_test.dart's own capture case already uses. Required:
/// pushing a `moved` frame whose `from` does not match the mover's actual
/// current token (e.g. the all-yard `_twoSeats` above) makes LudoBoard see
/// an old/new pair outside either of its own travel patterns (leaving the
/// yard needs new == 0; continuing a move needs old >= 0), so it snaps
/// instead of travelling -- and C-268 rule 4b flushes every pending landing
/// cue immediately on a snap, which would silently turn a held-cue test
/// into a trivially-passing immediate one.
final List<Map<String, Object?>> _travelSeats = <Map<String, Object?>>[
  _seatJson(0, name: 'Sam', tokens: const <int>[3, -1, -1, -1]),
  _seatJson(1, name: 'Bob', tokens: const <int>[-1, -1, 48, -1]),
];

/// Connects a fresh controller and lands it directly on the given [turn]
/// (or a null turn), mySeat always 0. Copied by hand from
/// test/feedback_wiring_test.dart's own `_connectTo`.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  String state = 'PLAYING',
  Map<String, Object?>? turn,
  int? winner,
  List<Map<String, Object?>>? seats,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        seats: seats ?? _twoSeats,
        turn: turn,
        winner: winner,
      ),
    ),
  );
  await future;
  return (controller, transport);
}

/// Drives a controller straight to RoomPhase.closed, holding a PLAYING
/// snapshot, the way test/game_screen_connection_lost_test.dart's own C2
/// does: the far end vanishes on its own, never a request failure.
Future<(RoomController, FakeTransport)> _connectAndCloseMidGame(
  WidgetTester tester,
) async {
  final (RoomController controller, FakeTransport transport) = await _connectTo(
    tester,
    seats: _twoSeats,
    turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 1000, k: 0),
  );
  transport.endFromFarSide();
  await tester.pump();
  await tester.pump();
  expect(
    controller.phase,
    RoomPhase.closed,
    reason: 'fixture is broken: the far side vanishing must close the phase',
  );
  expect(
    controller.room!.state,
    RoomState.playing,
    reason: 'fixture is broken: the last room snapshot must still say playing',
  );
  return (controller, transport);
}

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

/// Mounts [controller]'s GameScreen under a FeedbackScope carrying [service]
/// (a fresh NoopFeedbackService by default -- this file's own claims are
/// about the announcement channel, not about what a FeedbackService does
/// with a cue, except in the rule-4 group, which supplies a real
/// PlatformFeedbackService instead).
Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  FeedbackService service = const NoopFeedbackService(),
  FeedbackSettings? settings,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: settings ?? FeedbackSettings.forTest(),
        service: service,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

/// Records every cue GameScreen asks a FeedbackService to play, in call
/// order, with no throttle of its own. Copied by hand from
/// test/landing_cues_test.dart's own `_FakeFeedbackService` (library-private
/// there, so not importable).
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// One decoded `announce` event off SystemChannels.accessibility:
/// AnnounceSemanticsEvent.toMap()'s own `data` shape, kept to just the two
/// fields the order names (`data.message`, `data.textDirection`).
class _Announcement {
  const _Announcement(this.message, this.textDirectionIndex);

  final String message;
  final int textDirectionIndex;

  @override
  String toString() =>
      '_Announcement(message: "$message", '
      'textDirectionIndex: $textDirectionIndex)';
}

/// Installs a mock handler on SystemChannels.accessibility and records every
/// message whose top-level `type` is "announce" -- a `tooltip` or any other
/// accessibility event is not this contract's concern and is dropped.
/// [install] and [remove] are both called from inside each test body (never
/// from addTearDown alone for install), per this order's own instruction.
class _AnnouncementRecorder {
  final List<_Announcement> recorded = <_Announcement>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (dynamic message) async {
        final Map<Object?, Object?> event = message as Map<Object?, Object?>;
        if (event['type'] == 'announce') {
          final Map<Object?, Object?> data =
              event['data'] as Map<Object?, Object?>;
          recorded.add(
            _Announcement(
              data['message'] as String,
              data['textDirection'] as int,
            ),
          );
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

/// Pushes a `moved` frame and flushes it through the two-pump idiom the
/// sibling suites use. Copied from test/landing_cues_test.dart's own
/// `_pushMoved`.
Future<void> _pushMoved(
  WidgetTester tester,
  FakeTransport transport, {
  required int seat,
  required int token,
  required int from,
  required int to,
  List<Map<String, Object?>> captured = const <Map<String, Object?>>[],
  required int seq,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': from,
        'to': to,
        'captured': captured,
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pumps [squares] bounded ticks of exactly [kTokenStepDuration] each, never
/// one long pump. Copied from test/landing_cues_test.dart's own
/// `_pumpSquares`.
Future<void> _pumpSquares(WidgetTester tester, int squares) async {
  for (var i = 0; i < squares; i++) {
    await tester.pump(kTokenStepDuration);
  }
}

/// Answers a pending `roll` request with the `rolled` reply the server
/// would send, so the request's own 10s timer is cancelled before the test
/// body ends. Copied from test/play_surface_die_test.dart's own
/// `_settleRoll`.
void _settleRoll(
  FakeTransport transport,
  String rollId, {
  int seat = 0,
  int value = 5,
  int k = 1,
  List<int> legal = const <int>[0, 1],
  int deadlineMs = 45000,
  int seq = 2,
}) {
  transport.pushText(
    _frame(
      type: 'rolled',
      re: rollId,
      data: <String, Object?>{
        'seat': seat,
        'value': value,
        'legal': legal,
        'deadline_ms': deadlineMs,
        'k': k,
        'reveal': 'f' * 64,
        'seq': seq,
      },
    ),
  );
}

void main() {
  // ==========================================================================
  // Rule 1: one announcement per felt event, at the moment it is felt --
  // one case per row of C-337's own table, in English.
  // ==========================================================================
  group('rule 1 (English): one announcement per row of the table', () {
    // Catches: yourTurn never announced; announced more than once for one
    // turn frame; the wrong text.
    testWidgets(
      'yourTurn: a turn frame naming my seat announces loc.gameYourTurnStale '
      'exactly once',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final AppLocalizations loc = _locOf(tester);

        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{'seat': 0, 'deadline_ms': 45000, 'seq': 2},
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'a turn frame naming mySeat (0) must announce exactly once; '
              'recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          loc.gameYourTurnStale,
          reason:
              'yourTurn must announce loc.gameYourTurnStale '
              '("${loc.gameYourTurnStale}"); recorded ${recorder.recorded}',
        );
      },
    );

    // Catches: noMove never announced; the die's own "no move" visual mark
    // mistaken for the announcement and nothing actually sent.
    testWidgets('noMove: a rolled naming my seat with empty legal announces '
        'loc.gameNoMove exactly once', (tester) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (RoomController controller, FakeTransport transport) =
          await _connectTo(tester, turn: null);
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 6,
            'legal': <int>[],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'a rolled naming mySeat with empty legal must announce '
            'exactly once; recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.message,
        loc.gameNoMove,
        reason:
            'noMove must announce loc.gameNoMove ("${loc.gameNoMove}"); '
            'recorded ${recorder.recorded}',
      );
    });

    // Catches: capturedOther never announced; announced with the wrong
    // text (a getter this tree does not have yet would not compile, but a
    // stray literal copied wrong would still run and must be caught here).
    testWidgets(
      'capturedOther: my moved frame carrying a non-empty captured list '
      'announces "$_announceCapturedOtherEn" exactly once -- from == to so '
      'no travel and no landing hold stand between the frame and the cue',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 5,
          to: 5,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 0},
          ],
          seq: 2,
        );

        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'my moved frame capturing an opponent must announce exactly '
              'once; recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          _announceCapturedOtherEn,
          reason:
              'capturedOther must announce "$_announceCapturedOtherEn" '
              '(C-337\'s own table, no getter exists for it on this tree); '
              'recorded ${recorder.recorded}',
        );
      },
    );

    // Catches: capturedMe never announced; announced with the wrong text.
    testWidgets(
      'capturedMe: an opponent\'s moved frame naming my seat as captured '
      'announces "$_announceCapturedMeEn" exactly once',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        await _pushMoved(
          tester,
          transport,
          seat: 1,
          token: 0,
          from: 2,
          to: 2,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 0},
          ],
          seq: 2,
        );

        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'a moved frame for another seat naming my seat as captured '
              'must announce exactly once; recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          _announceCapturedMeEn,
          reason:
              'capturedMe must announce "$_announceCapturedMeEn"; recorded '
              '${recorder.recorded}',
        );
      },
    );

    // Catches: home never announced; announced with the wrong text.
    testWidgets('home: my moved frame landing a token on 57 announces '
        '"$_announceHomeEn" exactly once', (tester) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (RoomController controller, FakeTransport transport) =
          await _connectTo(tester, turn: null);
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      await _pushMoved(
        tester,
        transport,
        seat: 0,
        token: 0,
        from: 57,
        to: 57,
        seq: 2,
      );

      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'my moved frame landing a token on 57 must announce exactly '
            'once; recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.message,
        _announceHomeEn,
        reason:
            'home must announce "$_announceHomeEn"; recorded '
            '${recorder.recorded}',
      );
    });

    // Catches: win never announced; win announced from the wrong path (the
    // end card's own title text, not the one feedback-service seam rule 1
    // names).
    testWidgets(
      'win: a game_over naming me as winner announces loc.gameOverYouWin '
      'exactly once',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final AppLocalizations loc = _locOf(tester);

        transport.pushText(
          _frame(
            type: 'game_over',
            data: <String, Object?>{
              'winner': 0,
              'verify_url': 'https://talkback-announce-test.invalid/verify/1',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'a game_over naming me as winner must announce exactly once; '
              'recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          loc.gameOverYouWin,
          reason:
              'win must announce loc.gameOverYouWin '
              '("${loc.gameOverYouWin}"); recorded ${recorder.recorded}',
        );
      },
    );

    // Catches: gameOver never announced; the loser's own name used instead
    // of the winner's. See this file's header comment for why the
    // "gameOverEnded, no winner" half of this row is not exercised here.
    testWidgets('gameOver: a game_over naming another seat as winner announces '
        'loc.gameOverPlayerWins with that seat\'s name exactly once', (
      tester,
    ) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (RoomController controller, FakeTransport transport) =
          await _connectTo(tester, turn: null);
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      transport.pushText(
        _frame(
          type: 'game_over',
          data: <String, Object?>{
            'winner': 1,
            'verify_url': 'https://talkback-announce-test.invalid/verify/2',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'a game_over naming another seat as winner must announce '
            'exactly once; recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.message,
        loc.gameOverPlayerWins('Bob'),
        reason:
            'gameOver must announce loc.gameOverPlayerWins with the '
            'winning seat\'s own name ("Bob", from room.seats), got '
            '"${recorder.recorded.single.message}"',
      );
    });
  });

  // ==========================================================================
  // Rule 1 (Arabic): noMove, capturedMe and win, with RTL text direction.
  // ==========================================================================
  group('rule 1 (Arabic): RTL text direction', () {
    testWidgets('noMove in Arabic: announces loc.gameNoMove under ar with RTL '
        'textDirection', (tester) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (RoomController controller, FakeTransport transport) =
          await _connectTo(tester, turn: null);
      addTearDown(controller.dispose);
      await _mount(tester, controller, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 6,
            'legal': <int>[],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'noMove under Arabic must still announce exactly once; '
            'recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.message,
        loc.gameNoMove,
        reason:
            'noMove under Arabic must announce loc.gameNoMove '
            '("${loc.gameNoMove}"); recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.textDirectionIndex,
        TextDirection.rtl.index,
        reason:
            'an Arabic announcement must carry RTL textDirection '
            '(index ${TextDirection.rtl.index}); got '
            '${recorder.recorded.single.textDirectionIndex}',
      );
    });

    testWidgets(
      'capturedMe in Arabic: announces "$_announceCapturedMeAr" with RTL '
      'textDirection',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller, locale: const Locale('ar'));

        await _pushMoved(
          tester,
          transport,
          seat: 1,
          token: 0,
          from: 2,
          to: 2,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 0, 'token': 0},
          ],
          seq: 2,
        );

        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'capturedMe under Arabic must still announce exactly once; '
              'recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          _announceCapturedMeAr,
          reason:
              'capturedMe under Arabic must announce '
              '"$_announceCapturedMeAr" (C-337\'s own table); recorded '
              '${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.textDirectionIndex,
          TextDirection.rtl.index,
          reason:
              'an Arabic announcement must carry RTL textDirection '
              '(index ${TextDirection.rtl.index}); got '
              '${recorder.recorded.single.textDirectionIndex}',
        );
      },
    );

    testWidgets('win in Arabic: announces loc.gameOverYouWin under ar with RTL '
        'textDirection', (tester) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (RoomController controller, FakeTransport transport) =
          await _connectTo(tester, turn: null);
      addTearDown(controller.dispose);
      await _mount(tester, controller, locale: const Locale('ar'));
      final AppLocalizations loc = _locOf(tester);

      transport.pushText(
        _frame(
          type: 'game_over',
          data: <String, Object?>{
            'winner': 0,
            'verify_url': 'https://talkback-announce-test.invalid/verify/3',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'win under Arabic must still announce exactly once; recorded '
            '${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.message,
        loc.gameOverYouWin,
        reason:
            'win under Arabic must announce loc.gameOverYouWin '
            '("${loc.gameOverYouWin}"); recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.textDirectionIndex,
        TextDirection.rtl.index,
        reason:
            'an Arabic announcement must carry RTL textDirection '
            '(index ${TextDirection.rtl.index}); got '
            '${recorder.recorded.single.textDirectionIndex}',
      );
    });
  });

  // ==========================================================================
  // Rule 1's own timing claim: a capture whose landing cue is held until
  // the token lands is announced when it is released, not when the frame
  // arrives, and each event is announced once.
  // ==========================================================================
  group('rule 1 timing: a held landing cue is announced at landing, not at '
      'frame arrival', () {
    // Kills: announcing capturedOther the instant the moved frame lands,
    // ahead of the cue itself (which C-268 holds until the sixth step);
    // announcing it again when the fallback timer's own window elapses on
    // top of a landing that already played it.
    testWidgets(
      'a 6-square capture: no announceCapturedOther text right after the '
      'frame arrives, and exactly one right after the sixth step -- the cue '
      '(via the recording feedback fake) and the announcement land in the '
      'same pump',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final _FakeFeedbackService fake = _FakeFeedbackService();
        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, seats: _travelSeats, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller, service: fake);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 3,
          to: 9,
          captured: <Map<String, Object?>>[
            <String, Object?>{'seat': 1, 'token': 2},
          ],
          seq: 2,
        );
        expect(
          fake.recorded,
          isEmpty,
          reason:
              'fixture check (C-268 rule 3): capturedOther must still be '
              'held, not yet played',
        );
        expect(
          recorder.recorded,
          isEmpty,
          reason:
              'rule 1\'s own timing claim: no announceCapturedOther text '
              'right after the frame arrives, before the token has landed; '
              'recorded ${recorder.recorded}',
        );

        await _pumpSquares(tester, 5);
        expect(
          fake.recorded,
          equals(List<FeedbackCue>.filled(5, FeedbackCue.step)),
          reason:
              'fixture check: 5 of the 6 squares have arrived, so only step '
              'cues so far; recorded ${fake.recorded}',
        );
        expect(
          recorder.recorded,
          isEmpty,
          reason:
              'one step short of landing, capturedOther must still not be '
              'announced; recorded ${recorder.recorded}',
        );

        // The sixth and last step lands the move: the held cue plays here,
        // in the same pump as the step cue that lands it.
        await _pumpSquares(tester, 1);
        expect(
          fake.recorded,
          equals(<FeedbackCue>[
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.step,
            FeedbackCue.capturedOther,
          ]),
          reason:
              'fixture check (C-268): the sixth step must land the move and '
              'play capturedOther; recorded ${fake.recorded}',
        );
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'the cue and the announcement must land in the same pump: the '
              'pump that made fake.recorded carry capturedOther must be the '
              'one that also produced exactly one announcement; recorded '
              '${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          _announceCapturedOtherEn,
          reason:
              'the announcement that lands with the cue must carry '
              '"$_announceCapturedOtherEn"; recorded ${recorder.recorded}',
        );

        // kLandingCueFallback's own window, counted from the hold: a second
        // announcement here would mean the fallback timer fired on top of
        // the landing instead of being cancelled by it.
        await tester.pump(const Duration(seconds: 3));
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'nothing further must be announced once the landing has '
              'already played capturedOther; recorded ${recorder.recorded}',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 2: step, canMove and invalidTap send no announcement.
  // ==========================================================================
  group('rule 2: step, canMove and invalidTap send no announcement', () {
    // Catches: a step cue, played once per square as the token travels,
    // wrongly wired to an announcement too -- which would bury the player
    // under one word per square, the exact thing rule 2's own reasoning
    // warns against.
    testWidgets(
      'step: a 6-square plain move (no capture, not home) announces nothing '
      'at any square',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final _FakeFeedbackService fake = _FakeFeedbackService();
        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, seats: _travelSeats, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller, service: fake);

        await _pushMoved(
          tester,
          transport,
          seat: 0,
          token: 0,
          from: 3,
          to: 9,
          seq: 2,
        );
        await _pumpSquares(tester, 6);

        expect(
          fake.recorded,
          equals(List<FeedbackCue>.filled(6, FeedbackCue.step)),
          reason:
              'fixture check: a plain 6-square move must play 6 step cues '
              'and nothing else; recorded ${fake.recorded}',
        );
        expect(
          recorder.recorded,
          isEmpty,
          reason:
              'step cues must never be announced, at any square; recorded '
              '${recorder.recorded}',
        );
      },
    );

    // Catches: canMove wrongly added to the announced set (it is not in
    // C-337's table at all; the die and the legal tokens already carry
    // labels).
    testWidgets(
      'canMove: a rolled naming my seat with a non-empty legal announces '
      'nothing',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 0,
              'value': 4,
              'legal': <int>[0, 2],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'a' * 64,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          recorder.recorded,
          isEmpty,
          reason:
              'canMove must never be announced; recorded ${recorder.recorded}',
        );
      },
    );

    // Catches: invalidTap wrongly added to the announced set. The fixture's
    // `legal` carries two tokens (not one): a single-entry `legal` would
    // also arm GameScreen's existing, out-of-contract auto-move hold
    // (`_syncAutoMove`'s own unique-legal case), which calls the existing
    // `_announceAutoMove` with a token-button message of its own -- a real
    // announcement, but not the one this case is about, and one that would
    // wrongly inflate `recorder.recorded` past the invalid tap's own zero.
    // Two legal entries keeps that hold from ever arming, so every
    // announcement seen here, if any, is attributable to the illegal tap
    // alone.
    testWidgets(
      'invalidTap: a tap on an illegal token of mine announces nothing (the '
      'auto-move hold is kept from arming by a two-entry legal list -- see '
      'this test\'s own comment)',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final _FakeFeedbackService fake = _FakeFeedbackService();
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
          _seatJson(1, name: 'Bob'),
        ];
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          seats: seats,
          turn: _turnJson(
            seat: 0,
            phase: 'await_move',
            deadlineMs: 45000,
            k: 1,
            value: 4,
            legal: const <int>[1, 2],
          ),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller, service: fake);

        await tester.tap(find.byKey(_hitKey(0, 0)));
        await tester.pump();

        expect(
          fake.recorded,
          equals(<FeedbackCue>[FeedbackCue.invalidTap]),
          reason:
              'fixture check: the illegal tap must record exactly one '
              'invalidTap; recorded ${fake.recorded}',
        );
        expect(
          recorder.recorded,
          isEmpty,
          reason:
              'invalidTap must never be announced; recorded '
              '${recorder.recorded}',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 3: the die's no-answer line, and the connection-lost body.
  // ==========================================================================
  group('rule 3: the no-answer line and the connection-lost body', () {
    // Kills: the no-answer line never announced; announced again on every
    // further pump while it stays, instead of once when it first appears.
    testWidgets('gameRollNoAnswer: appears once at 4s and announces '
        'loc.gameRollNoAnswer exactly once, with no repeat while it stays', (
      tester,
    ) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      await tester.tap(find.byKey(_dieKey));
      await tester.pump();
      expect(
        recorder.recorded,
        isEmpty,
        reason:
            'fixture check: tapping the die must not itself announce '
            'anything before the 4s stop',
      );

      await tester.pump(const Duration(milliseconds: 3999));
      expect(
        find.byKey(_noAnswerKey),
        findsNothing,
        reason: 'fixture check: game-die-no-answer must not appear yet',
      );
      expect(
        recorder.recorded,
        isEmpty,
        reason:
            'before game-die-no-answer appears, nothing must be '
            'announced; recorded ${recorder.recorded}',
      );

      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.byKey(_noAnswerKey),
        findsOneWidget,
        reason: 'fixture check: game-die-no-answer must appear at 4s',
      );
      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'game-die-no-answer appearing must announce exactly once; '
            'recorded ${recorder.recorded}',
      );
      expect(
        recorder.recorded.single.message,
        loc.gameRollNoAnswer,
        reason:
            'the no-answer line must announce loc.gameRollNoAnswer '
            '("${loc.gameRollNoAnswer}"); recorded ${recorder.recorded}',
      );

      // The no-answer line stays on screen; further pumps while it stays
      // must add nothing further.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.byKey(_noAnswerKey),
        findsOneWidget,
        reason: 'fixture check: game-die-no-answer must still be showing',
      );
      expect(
        recorder.recorded,
        hasLength(1),
        reason:
            'while the no-answer line stays, further pumps must not '
            'announce it again; recorded ${recorder.recorded}',
      );

      // Settle the still-open roll request so no timer survives past
      // this test body.
      _settleRoll(
        transport,
        _idOf(
          transport.sentRaw.singleWhere((String s) => _typeOf(s) == 'roll'),
        ),
      );
      await tester.pump();
    });

    // Kills: the connection-lost body never announced; announced again on
    // a plain rebuild that changes nothing about the phase.
    testWidgets(
      'lobbyConnectionLost: entering the connection-lost body announces '
      'loc.lobbyConnectionLost exactly once, and a rebuild while it stays '
      'adds nothing',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, _) = await _connectAndCloseMidGame(
          tester,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);
        final AppLocalizations loc = _locOf(tester);

        expect(
          find.byKey(_connectionLostKey),
          findsOneWidget,
          reason:
              'fixture check: mounting while RoomPhase.closed must render '
              'game-screen-connection-lost',
        );
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'entering the connection-lost body must announce exactly '
              'once; recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          loc.lobbyConnectionLost,
          reason:
              'the connection-lost body must announce '
              'loc.lobbyConnectionLost ("${loc.lobbyConnectionLost}"); '
              'recorded ${recorder.recorded}',
        );

        // Force a rebuild of the still-mounted GameScreen with nothing
        // about the controller's phase or room having changed: re-pumping
        // the identical widget tree at the same Element location makes
        // StatefulElement.update() call rebuild(force: true)
        // (packages/flutter/lib/src/widgets/framework.dart), which runs
        // build() again regardless of whether any field actually changed.
        // A State whose build() announces unconditionally (rather than
        // guarding on "already announced this entry") would repeat it here.
        await _mount(tester, controller);

        expect(
          find.byKey(_connectionLostKey),
          findsOneWidget,
          reason:
              'fixture check: the connection-lost body must still be '
              'showing after the forced rebuild',
        );
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'a rebuild while the connection-lost body stays must not '
              'announce it again; recorded ${recorder.recorded}',
        );
      },
    );
    // Kills: the once-per-entry guard dropped, so every controller
    // notification while the body stays (a reconnect attempt moving the
    // phase from closed to connecting) announces it again.
    testWidgets(
      'lobbyConnectionLost: a reconnect attempt while the connection-lost '
      'body stays adds no second announcement',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final (RoomController controller, _) = await _connectAndCloseMidGame(
          tester,
        );
        addTearDown(controller.dispose);

        await _mount(tester, controller);
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'fixture check: entering the connection-lost body announces '
              'once; recorded ${recorder.recorded}',
        );

        await tester.tap(find.byKey(const Key('game-screen-reconnect-button')));
        await tester.pump();

        expect(
          controller.phase,
          isNot(RoomPhase.connected),
          reason:
              'fixture check: the reconnect attempt must not have connected '
              'yet, or the body has legitimately left',
        );
        expect(
          find.byKey(_connectionLostKey),
          findsOneWidget,
          reason:
              'fixture check: the connection-lost body must still be '
              'showing during the reconnect attempt',
        );
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'a controller notification while the connection-lost body '
              'stays must not announce it again; recorded '
              '${recorder.recorded}',
        );
      },
    );
  });

  // ==========================================================================
  // Rule 4: independent of the sound and vibration switches.
  // ==========================================================================
  group('rule 4: the announcement is independent of the sound and vibration '
      'switches', () {
    // Catches: the announcement gated behind FeedbackService.play actually
    // reaching the platform, so turning both switches off (which leaves
    // PlatformFeedbackService making zero platform calls, proven below)
    // would silently also turn off the announcement.
    testWidgets(
      'both switches off: a no-move roll still announces loc.gameNoMove, '
      'even though the real PlatformFeedbackService makes zero haptic or '
      'sound calls',
      (tester) async {
        final _AnnouncementRecorder recorder = _AnnouncementRecorder();
        recorder.install(tester);
        addTearDown(() => recorder.remove(tester));

        final List<MethodCall> calls = <MethodCall>[];
        const MethodChannel channel = MethodChannel('app.fayad.ludo/feedback');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              calls.add(call);
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );

        final FeedbackSettings settings = FeedbackSettings.forTest(
          haptics: false,
          sound: false,
        );
        final PlatformFeedbackService service = PlatformFeedbackService(
          settings,
          channel,
        );
        addTearDown(service.dispose);

        final (RoomController controller, FakeTransport transport) =
            await _connectTo(tester, turn: null);
        addTearDown(controller.dispose);
        await _mount(tester, controller, service: service, settings: settings);
        final AppLocalizations loc = _locOf(tester);

        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 0,
              'value': 6,
              'legal': <int>[],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'b' * 64,
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();

        expect(
          calls,
          isEmpty,
          reason:
              'fixture check: with both switches off, PlatformFeedbackService '
              'must make zero platform calls for this cue; got $calls',
        );
        expect(
          recorder.recorded,
          hasLength(1),
          reason:
              'the announcement must fire regardless of the haptics/sound '
              'switches; recorded ${recorder.recorded}',
        );
        expect(
          recorder.recorded.single.message,
          loc.gameNoMove,
          reason:
              'noMove must still announce loc.gameNoMove '
              '("${loc.gameNoMove}") with both switches off; recorded '
              '${recorder.recorded}',
        );
      },
    );
  });
}
