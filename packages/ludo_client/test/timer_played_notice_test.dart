// Conformance tests for work/ludo/orders/C-426-timer-played-says-so.md
// decisions D1-D9, C-cases C1-C10, written from that contract's own text
// and from docs/PROTOCOL.md section 22 alone. Order 428 (lib/src/
// game_screen.dart, the ARBs) is built in parallel by a different hand, on
// a branch this file's author has not read (order/428-timer-client is out
// of bounds by this order's own instruction); every expectation below is
// read off C-426's own words, never off 428's code.
//
// On this branch (HEAD 0552078, no client change landed for D3-D5) every
// case below that depends on the below-die notice actually existing
// (`game-timer-played-notice`, `game-timer-played-other-notice`) is red for
// the contract's reason: the key is simply absent from the tree, because
// `_belowDieNoticeSlot` (game_screen.dart, read-only, confirmed by grep
// before writing this file) carries only its two pre-existing branches
// (`game-no-move-notice`, `game-screen-turn-seat-offline`) and no `by`-aware
// branch at all. C3, C4, C4b and C7 are green already: nothing on this
// tree treats `by` specially, so no notice ever shows regardless of its
// value (C3/C4/C4b), and `cuesForFrame` (lib/src/feedback.dart, read-only)
// never reads `by` at all, so a timer-driven frame stream and a
// client-driven one already play identical cue sequences (C7, D6).
//
// C1's own job -- "shows the en and the ar text" -- needs
// `AppLocalizations.gameTimerPlayedMine` / `.gameTimerPlayedOther`, neither
// of which exists as a getter on this tree (grepped app_en.arb: no
// `gameTimerPlayed*` key at all). Referencing an undefined getter is a
// compile-time error for the whole library it sits in, which would take
// every other case in this file down with it before any of them could run.
// C1 is therefore split into its own file, test/timer_played_strings_test.
// dart, exactly as this order's own Goal section anticipates ("If a missing
// key would stop the whole file compiling, put the string-dependent cases
// in their own file"). Every other case below that touches "the name" or
// "the text" at all (C5, C8) is written to prove its own point without
// that getter -- C5 with `contains(name)`, C8 by counting announcements and
// checking `textDirection` rather than comparing against the pinned
// strings -- so this file keeps compiling and running on this tree today.
//
// GameScreen is mounted the way test/automove_says_so_test.dart and
// test/talkback_announce_test.dart mount it: a real RoomController over a
// FakeTransport (test/net/fake_transport.dart, read-only, imported directly
// the way every sibling suite imports it), fed real wire frames by hand.
// Every helper below is copied by hand from those two files' patterns (and
// from test/game_screen_turn_seat_offline_test.dart for the offline-seat
// shape and test/game_screen_resume_after_expiry_test.dart for the
// drop-reconnect-resume dance C10 needs), per this project's own standing
// instruction never to import across test files -- nothing here imports
// another test file, or test/support/roll_tray_harness.dart, even though
// C9 copies that file's own font-loading idiom by hand. One mount per
// case; no pumpAndSettle anywhere in this file (every wait is a bounded
// `tester.pump(Duration)` or a short, explicit sequence of them); every
// case that lets a tap actually send a `roll` or a `move` answers it before
// the case ends, the lesson test/automove_says_so_test.dart's own header
// records as "run 100's own defect 1".
//
// Ambiguities found while writing this file, reported rather than invented
// around (acceptance criterion 3's `reason:` on each case below also names
// the specific decision and defect; this is the higher-level list):
//
//   1. D4's "present (not departed)" has no test fixture in this codebase
//      that actually removes a seat mid-PLAYING: docs/PROTOCOL.md section 3
//      says a disconnected seat "stays in the game ... played by the timer
//      under rule 15", and section 18 ("Leaving a table") only ever frees a
//      seat in LOBBY or FINISHED, never PLAYING. A seat that has truly left
//      a live game is therefore not reachable through any real server
//      behaviour this file could drive. The closest existing vocabulary for
//      "departed" on the client side is `game_screen.dart`'s own
//      `_offlineTurnSeat` (read-only), whose doc comment already names the
//      case "the turn names a seat absent from `room.seats`" as a thing it
//      defends against. C5's departed sub-case follows that same reading:
//      a two-seat room (`players: 2`, seats 0 and 1 only) fed a raw
//      `moved`/`by: timer` frame naming seat 2, which is not in
//      `room.seats` at all. This is a defensive/robustness probe, the same
//      class of case as C4b's "an unknown `by` value", not a scenario a
//      conforming server would ever produce while the game is PLAYING.
//   2. D5's "at rest it is exactly what it is on main at every shape and
//      scale the board-floor tests pin (C-391, C-402)" asks for a
//      comparison against a number this file has no way to read out of
//      those other files (per this order's own rule, this file must not
//      import or run them). C9 instead reads the board rect twice in the
//      same mount: once right after mount, before any `by`-carrying frame
//      has ever been pushed (which, on this exact tree, is bit-for-bit
//      identical to what main renders, since nothing here differs from
//      main yet) and once again after a `by: timer` frame has been pushed
//      and pumped. The two must be equal. This proves the literal
//      "before/after" claim the Tests section states and stands as the
//      regression guard once 428's own notice actually renders; it is not,
//      by itself, a comparison against a number pinned anywhere else.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FontLoader, SystemChannels, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://timer-played-notice-test.invalid/ws';

const Key _mineKey = Key('game-timer-played-notice');
const Key _otherKey = Key('game-timer-played-other-notice');
const Key _noMoveKey = Key('game-no-move-notice');
const Key _offlineKey = Key('game-screen-turn-seat-offline');
const Key _dieKey = Key('game-die');
const Key _boardKey = Key('game-screen-board');
const Key _connectionLostKey = Key('game-screen-connection-lost');
const Key _reconnectButtonKey = Key('game-screen-reconnect-button');

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');

// --- server-side id generation for pushed frames, copied from the sibling
// suites' own idiom -----------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'timer-played-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, copied from the sibling suites -------------------

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

// --- a minimal valid docs/PROTOCOL.md section 6 room snapshot, copied from
// the sibling suites --------------------------------------------------------

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

Map<String, Object?> _roomJson({
  String code = 'K7M2QP',
  String state = 'PLAYING',
  int hostSeat = 0,
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
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
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

/// A plain mutable seq counter, copied from test/automove_says_so_test.
/// dart's own `_Seq`: every pushed frame below carries the next value so a
/// mismatch (which would silently start a resync instead of applying the
/// frame) is never this file's own bug.
class _Seq {
  _Seq(this.value);
  int value;
  int next() {
    value += 1;
    return value;
  }
}

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() has no transport queued for $url',
      );
    }
    return _queue.removeAt(0);
  }
}

/// Connects seat 0 (always "me" in this file) directly into the given
/// [turn], over [seats] (must already include seat 0). Copied by hand from
/// test/automove_says_so_test.dart's own `_connectSeat0`, generalised to
/// take the seat list and player count a given case needs.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required int players,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );

  final Future<void> future = controller.createRoom(
    name: 'Sam',
    players: players,
  );
  // Standing lesson, copied along with the rig: pumpEventQueue() alone
  // relies on real Timers via Future.delayed, which never fire under the
  // fake-async clock a testWidgets body runs in, and hangs forever with no
  // diagnostic. tester.runAsync() steps outside the fake zone for the
  // duration of the call so the real event loop actually advances, then
  // tester.pump() brings the widget tree's own state back in sync with
  // what that unblocked.
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
      data: _roomJson(players: players, seats: seats, turn: turn, seq: 1),
    ),
  );
  await future;
  return (controller, transport);
}

Widget _harness(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? screen) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(textScaler: TextScaler.linear(textScale)),
        child: screen!,
      );
    },
    home: child,
  );
}

/// Mounts at a realistic phone size (test/automove_says_so_test.dart's own
/// choice and its own reasoning: on the default, unrealistically small test
/// surface a `tester.tap` aimed at a token's hit rect can land on the roll
/// tray instead), under a [FeedbackScope] so cases that care about cues or
/// the announcement channel can supply their own [service]; cases that
/// don't are handed the default no-op, same as a bare `GameScreen` would
/// get with no scope at all (`FeedbackScope.of`'s own documented fallback).
Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
  FeedbackService service = const NoopFeedbackService(),
  Size size = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: service,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
      textScale: textScale,
    ),
  );
  await tester.pump();
}

/// Records every cue GameScreen asks a FeedbackService to play, in call
/// order. Copied by hand from test/talkback_announce_test.dart's own
/// `_FakeFeedbackService`.
class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) {
    recorded.add(cue);
  }
}

/// One decoded `announce` event off SystemChannels.accessibility. Copied by
/// hand from test/talkback_announce_test.dart's own `_Announcement` /
/// `_AnnouncementRecorder`.
class _Announcement {
  const _Announcement(this.message, this.textDirectionIndex);
  final String message;
  final int textDirectionIndex;

  @override
  String toString() =>
      '_Announcement(message: "$message", '
      'textDirectionIndex: $textDirectionIndex)';
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

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

/// Answers the pending `roll` request [rollId] sent on [transport], copied
/// by hand from test/play_surface_die_test.dart's own `_settleRoll` idiom,
/// so its own 10s request-timeout Timer never survives past the end of a
/// case (test/automove_says_so_test.dart's own "run 100's own defect 1").
void _settleRoll(
  FakeTransport transport,
  String rollId, {
  required int seat,
  required int value,
  required int k,
  required List<int> legal,
  int deadlineMs = 45000,
  required int seq,
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

/// Answers the pending `move` request [moveId] sent on [transport] with a
/// zero-travel `moved` reply, same reasoning as [_settleRoll].
void _settleMove(
  FakeTransport transport,
  String moveId, {
  required int seat,
  required int token,
  required int atProgress,
  required int seq,
}) {
  transport.pushText(
    _frame(
      type: 'moved',
      re: moveId,
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': atProgress,
        'to': atProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
        'seq': seq,
      },
    ),
  );
}

/// Loads the app's own Poppins and Noto Sans Arabic font files, copied by
/// hand from test/roll_tray_long_queue_test.dart's own `_loadAppFonts`
/// (that file's own header: loading the files is only half of what a
/// fonts-dependent measurement needs; `_harness` above also carries
/// `theme: buildAppTheme()`, the other half).
Future<void> _loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final FontLoader poppins = FontLoader('Poppins');
  for (final String asset in const <String>[
    'fonts/Poppins-Regular.ttf',
    'fonts/Poppins-Medium.ttf',
    'fonts/Poppins-SemiBold.ttf',
    'fonts/Poppins-Bold.ttf',
  ]) {
    poppins.addFont(rootBundle.load(asset));
  }
  await poppins.load();

  final FontLoader notoSansArabic = FontLoader('Noto Sans Arabic');
  for (final String asset in const <String>[
    'fonts/NotoSansArabic-Regular.ttf',
    'fonts/NotoSansArabic-Bold.ttf',
  ]) {
    notoSansArabic.addFont(rootBundle.load(asset));
  }
  await notoSansArabic.load();
}

/// True when every edge of [a] and [b] agree within [tolerance] dp. Used
/// instead of `Rect`'s own `==` so a sub-ulp layout difference from one
/// extra rebuild does not make C9 flaky for a reason D5 does not care
/// about.
bool _rectsClose(Rect a, Rect b, {double tolerance = 0.5}) {
  return (a.left - b.left).abs() <= tolerance &&
      (a.top - b.top).abs() <= tolerance &&
      (a.right - b.right).abs() <= tolerance &&
      (a.bottom - b.bottom).abs() <= tolerance;
}

void main() {
  // ==========================================================================
  // C2: the notice stays up across other seats' frames and my own next
  // turn beginning, and clears at the moment my own play tap is sent (D3).
  // ==========================================================================
  group('C2 (D3): the notice persists until my own play tap is sent', () {
    testWidgets(
      'armed by a timer rolled: still shown after 5s of another seat\'s '
      'frames and after my own next turn frame; gone the instant my die '
      'tap sends roll',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
            _seatJson(1, name: 'Bob'),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_move',
            'deadline_ms': 45000,
            'k': 1,
            'value': 5,
            'legal': const <int>[0, 1],
          },
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        // Arm: the timer takes my move (zero travel, no extra roll), ending
        // my turn.
        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 2,
              'to': 2,
              'captured': const <Object?>[],
              'extra_roll': false,
              'by': 'timer',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason:
              'D3: a moved for my own seat (seat 0) carrying by: timer must '
              'show game-timer-played-notice; on this tree (no D3 '
              'implementation) this is expected red -- the key is absent '
              'from _belowDieNoticeSlot entirely',
        );

        // Hand the turn to seat 1, then run seat 1 through an ordinary
        // turn over roughly 5 seconds of pumped time, then back to me.
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 1,
              'deadline_ms': 45000,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 1,
              'value': 4,
              'legal': const <int>[0],
              'deadline_ms': 45000,
              'k': 2,
              'reveal': 'b' * 64,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 1,
              'token': 0,
              'from': -1,
              'to': 3,
              'captured': const <Object?>[],
              'extra_roll': false,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'deadline_ms': 45000,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason:
              'D3: 5s of seat 1\'s own frames and my own next turn frame '
              '(bare turn, no phase -> await_roll) must not clear the '
              'notice -- D3\'s own words, "does NOT clear when my next '
              'turn begins". Red today for the same missing-key reason as '
              'above',
        );

        await tester.tap(find.byKey(_dieKey));
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason:
              'D3: the notice must be gone the instant my own die tap '
              'sends roll -- "until the first of: my own play tap that is '
              'sent". On this tree the key never existed in the first '
              'place, so this assertion is vacuously true today; it is '
              'the one in this group that only becomes a real proof once '
              '428 lands the notice',
        );

        final String rollId = _idOf(
          transport.sentRaw.firstWhere((String s) => _typeOf(s) == 'roll'),
        );
        _settleRoll(
          transport,
          rollId,
          seat: 0,
          value: 3,
          k: 3,
          legal: const <int>[0, 1],
          seq: seq.next(),
        );
        await tester.pump();
        await tester.pump();
      },
    );

    testWidgets(
      'in another mount, armed by a timer rolled: gone the instant my own '
      'token tap sends move',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
            _seatJson(1, name: 'Bob'),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 0,
              'value': 5,
              'legal': const <int>[0, 1],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'a' * 64,
              'by': 'timer',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason:
              'D3: a rolled for my own seat carrying by: timer must show '
              'game-timer-played-notice; red today for the missing-key '
              'reason this file\'s header explains',
        );

        await tester.tap(find.byKey(_hitKey(0, 0)));
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason:
              'D3: the notice must be gone the instant my own token tap '
              'sends move -- the other half of "my own play tap that is '
              'sent". Vacuously true today since the key never existed; '
              'becomes a real proof once 428 lands the notice',
        );

        final String moveId = _idOf(
          transport.sentRaw.firstWhere((String s) => _typeOf(s) == 'move'),
        );
        _settleMove(
          transport,
          moveId,
          seat: 0,
          token: 0,
          atProgress: 2,
          seq: seq.next(),
        );
        await tester.pump();
        await tester.pump();
      },
    );
  });

  // ==========================================================================
  // C3 (D7): my own ordinary roll / move, no `by` at all, shows nothing.
  // ==========================================================================
  group('C3 (D7): my own roll or move with no by shows no notice', () {
    testWidgets('a rolled for my own seat with no by key at all', (
      tester,
    ) async {
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[2, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 5,
            'legal': const <int>[0],
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
        find.byKey(_mineKey),
        findsNothing,
        reason:
            'D7: a rolled for my own seat with no by key at all is an '
            'ordinary client-driven roll; game-timer-played-notice must '
            'not show. Already green on this tree: nothing reads by at '
            'all, so this is the correct outcome for the wrong (vacuous) '
            'reason today and the contract\'s own reason once 428 lands',
      );
    });

    testWidgets('a moved for my own seat with no by key at all', (
      tester,
    ) async {
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': 45000,
          'k': 1,
          'value': 5,
          'legal': const <int>[0, 1],
        },
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 2,
            'to': 2,
            'captured': const <Object?>[],
            'extra_roll': false,
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason:
            'D7: a moved for my own seat with no by key at all must not '
            'show game-timer-played-notice. Same already-green-today '
            'reasoning as the rolled sibling case above',
      );
    });
  });

  // ==========================================================================
  // C4 (D7): the C-417 unique-legal hold sends a real move with no by; no
  // notice at any point in that flow.
  // ==========================================================================
  group('C4 (D7): the C-417 auto-move hold is not a timer step', () {
    testWidgets(
      'a unique-legal hold arms, fires its own move at kAutoMoveHold, and '
      'no notice shows at any point',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam', tokens: const <int>[2, -1, -1, -1]),
            _seatJson(1, name: 'Bob'),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'phase': 'await_move',
              'deadline_ms': 45000,
              'k': 1,
              'value': 5,
              'legal': const <int>[0],
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason:
              'D7: arming the unique-legal hold must not show the timer '
              'notice -- the hold is my own client deciding to play for '
              'me, not the server timer',
        );

        await tester.pump(const Duration(milliseconds: 1600));
        final List<String> moves = transport.sentRaw
            .where((String s) => _typeOf(s) == 'move')
            .toList();
        expect(
          moves,
          hasLength(1),
          reason:
              'fixture is broken: the C-417 hold must have sent exactly '
              'one move by 1600ms after arming',
        );
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason:
              'D7: the hold firing its own move must not show the timer '
              'notice either, right after it sends',
        );

        _settleMove(
          transport,
          _idOf(moves.single),
          seat: 0,
          token: 0,
          atProgress: 2,
          seq: seq.next(),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsNothing,
          reason:
              'D7: the server\'s moved answering the hold\'s own move '
              'carries no by at all; the notice must still not show',
        );
      },
    );
  });

  // ==========================================================================
  // C4b (D1/D7): an unknown by value is treated as absent.
  // ==========================================================================
  group('C4b (D1): an unknown by value shows no notice', () {
    testWidgets('a rolled for my own seat carrying by: "other"', (
      tester,
    ) async {
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[2, -1, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 5,
            'legal': const <int>[0],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'a' * 64,
            'by': 'other',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(_mineKey),
        findsNothing,
        reason:
            'D1/section 22.1: "a client treats any other value as absent" '
            '-- by: "other" must show no notice. Already green today: '
            'nothing on this tree reads by at all',
      );
    });
  });

  // ==========================================================================
  // C5 (D4): another present, online seat shows the other-seat line with
  // the name and it clears after 2500ms; a departed seat and an offline
  // seat show nothing.
  // ==========================================================================
  group('C5 (D4): another seat\'s timer step', () {
    testWidgets('present and online: shows the name and clears after 2500ms '
        '(bounded pumps)', (tester) async {
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob'),
        ],
        turn: <String, Object?>{
          'seat': 1,
          'phase': 'await_move',
          'deadline_ms': 45000,
          'k': 1,
          'value': 5,
          'legal': const <int>[0, 1],
        },
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 1,
            'token': 0,
            'from': 5,
            'to': 5,
            'captured': const <Object?>[],
            'extra_roll': false,
            'by': 'timer',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(_otherKey),
        findsOneWidget,
        reason:
            'D4: a moved for another present, online seat (Bob, seat 1) '
            'carrying by: timer must show '
            'game-timer-played-other-notice; red today, the key is '
            'absent from the tree entirely',
      );
      // The expect above already requires exactly one widget at this
      // key; reaching here means it exists, so its text is read
      // directly rather than re-guarded.
      final String otherText =
          tester.widget<Text>(find.byKey(_otherKey)).data ?? '';
      expect(
        otherText,
        contains('Bob'),
        reason: 'D4: the other-seat notice must name the seat (Bob)',
      );

      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        find.byKey(_otherKey),
        findsNothing,
        reason:
            'D4: the other-seat notice must be gone 2500ms after the '
            'frame that armed it (3000ms of bounded pumps elapsed here, '
            'safely past the window)',
      );
    });

    testWidgets('offline (connected: false): shows nothing', (tester) async {
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam'),
          _seatJson(1, name: 'Bob', connected: false),
        ],
        turn: <String, Object?>{
          'seat': 1,
          'phase': 'await_move',
          'deadline_ms': 45000,
          'k': 1,
          'value': 5,
          'legal': const <int>[0, 1],
        },
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 1,
            'token': 0,
            'from': 5,
            'to': 5,
            'captured': const <Object?>[],
            'extra_roll': false,
            'by': 'timer',
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(_otherKey),
        findsNothing,
        reason:
            'D4: an offline seat\'s own timer step must show no '
            'other-seat notice -- "the timer playing them is already '
            'explained by their own marks and by '
            'game-screen-turn-seat-offline"',
      );
    });

    testWidgets(
      'departed (seat not present in room.seats at all): shows nothing',
      (tester) async {
        // Ambiguity 1 (this file's header): docs/PROTOCOL.md section 3/18
        // never frees a seat mid-PLAYING, so a genuinely departed seat is
        // not reachable through any real server behaviour. This probes the
        // client's own defensive handling of a frame naming a seat that is
        // not in room.seats at all -- the same vocabulary
        // game_screen.dart's own _offlineTurnSeat (read-only) already uses
        // ("the turn names a seat absent from room.seats").
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          players: 2,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam'),
            _seatJson(1, name: 'Bob'),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 2,
              'token': 0,
              'from': 5,
              'to': 5,
              'captured': const <Object?>[],
              'extra_roll': false,
              'by': 'timer',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.byKey(_otherKey),
          findsNothing,
          reason:
              'D4: a timer step naming a seat absent from room.seats '
              '(seat 2, in a 2-seat room) must show no other-seat notice '
              '-- there is no SeatState to read a name or a connected '
              'flag off',
        );
      },
    );
  });

  // ==========================================================================
  // C6 (D5): fixed priority -- no-move over other-seat over offline over
  // mine; a lower line comes back once a higher one ends, if still due.
  // ==========================================================================
  group('C6 (D5): fixed priority in the one shared slot', () {
    testWidgets(
      'no-move > other-seat > offline > mine, and mine comes back after '
      'each higher one ends',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectTo(
          tester,
          players: 3,
          seats: <Map<String, Object?>>[
            _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
            _seatJson(1, name: 'Bob'),
            _seatJson(2, name: 'Cy', connected: false),
          ],
          turn: <String, Object?>{
            'seat': 0,
            'phase': 'await_roll',
            'deadline_ms': 45000,
            'k': 0,
          },
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        void expectShown(Key key, String label, String reason) {
          expect(find.byKey(key), findsOneWidget, reason: '$label: $reason');
        }

        void expectHidden(Key key, String label, String reason) {
          expect(find.byKey(key), findsNothing, reason: '$label: $reason');
        }

        // Step 1: arm mine via a timer rolled for seat 0, two legal tokens
        // (no auto-move hold, no no-move hold).
        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 0,
              'value': 5,
              'legal': const <int>[0, 1],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'a' * 64,
              'by': 'timer',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expectShown(
          _mineKey,
          'step 1',
          'nothing higher is active, so mine must show once armed; red '
              'today (missing key)',
        );

        // Step 2: the timer also plays my move, ending my turn to seat 1.
        // Re-arms mine (same text, D3), does not clear it.
        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 2,
              'to': 2,
              'captured': const <Object?>[],
              'extra_roll': false,
              'by': 'timer',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 1,
              'deadline_ms': 45000,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        // Step 3: seat 1's own timer step arms the other-seat line, which
        // must beat mine, then seat 1's empty-legal roll passes the turn
        // straight to seat 2 (offline).
        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 1,
              'value': 6,
              'legal': const <int>[],
              'deadline_ms': 45000,
              'k': 2,
              'reveal': 'b' * 64,
              'by': 'timer',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'turn_passed',
            data: <String, Object?>{
              'seat': 1,
              'reason': 'no_legal_move',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 2,
              'deadline_ms': 45000,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expectShown(
          _otherKey,
          'step 3',
          'seat 1\'s own timer step must beat mine while its own 2500ms '
              'window is still open; red today (missing key)',
        );
        expectHidden(
          _mineKey,
          'step 3',
          'mine must be hidden (not cleared) while other-seat is active',
        );
        expectHidden(
          _offlineKey,
          'step 3',
          'the offline line for seat 2 must also be hidden while '
              'other-seat (seat 1) is still within its own window, even '
              'though the turn has already moved to seat 2',
        );

        // Step 4: let other-seat's 2500ms window expire. Offline (seat 2,
        // on turn and disconnected) must now beat mine.
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expectHidden(
          _otherKey,
          'step 4',
          'other-seat must be gone once its own 2500ms window has passed',
        );
        expectShown(
          _offlineKey,
          'step 4',
          'offline (seat 2, Cy) must now show -- it beats mine and '
              'nothing higher is active any more; already green today, this '
              'line is C-250\'s existing feature',
        );
        expectHidden(
          _mineKey,
          'step 4',
          'mine must stay hidden while offline is active',
        );

        // Step 5: seat 2 reconnects. Offline clears; mine, still due,
        // comes back.
        transport.pushText(
          _frame(
            type: 'presence',
            data: <String, Object?>{
              'seat': 2,
              'connected': true,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expectHidden(
          _offlineKey,
          'step 5',
          'offline must clear once seat 2 reconnects',
        );
        expectShown(
          _mineKey,
          'step 5',
          'mine must come back once offline ends, since it is still due '
              '-- D5\'s own "lower ones come back when a higher one ends, if '
              'still due". Red today (missing key)',
        );

        // Step 6: seat 2 plays an empty-legal turn back to me, then a
        // fresh timer rolled for me (empty legal) arms the existing
        // no-move hold, which must beat mine.
        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 2,
              'value': 3,
              'legal': const <int>[],
              'deadline_ms': 45000,
              'k': 1,
              'reveal': 'c' * 64,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'turn_passed',
            data: <String, Object?>{
              'seat': 2,
              'reason': 'no_legal_move',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'turn',
            data: <String, Object?>{
              'seat': 0,
              'deadline_ms': 45000,
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        transport.pushText(
          _frame(
            type: 'rolled',
            data: <String, Object?>{
              'seat': 0,
              'value': 6,
              'legal': const <int>[],
              'deadline_ms': 45000,
              'k': 4,
              'reveal': 'd' * 64,
              'by': 'timer',
              'seq': seq.next(),
            },
          ),
        );
        await tester.pump();
        await tester.pump();

        expectShown(
          _noMoveKey,
          'step 6',
          'the existing no-move hold (C-250, unconditional on by) must '
              'beat everything; already green today, this is the existing '
              'feature',
        );
        expectHidden(
          _mineKey,
          'step 6',
          'mine must be hidden while no-move is active',
        );

        // Step 7: the no-move hold auto-clears after 1500ms (game_screen.
        // dart's own _noMoveHold, read-only). Mine, still due, comes back
        // one final time.
        await tester.pump(const Duration(milliseconds: 1600));
        expectHidden(
          _noMoveKey,
          'step 7',
          'no-move must have auto-cleared by 1600ms',
        );
        expectShown(
          _mineKey,
          'step 7',
          'mine must come back one final time once no-move clears, still '
              'due. Red today (missing key)',
        );
      },
    );
  });

  // ==========================================================================
  // C7 (D6): identical cue sequences for the same frame stream with and
  // without by. Meaningful today: cuesForFrame already ignores by.
  // ==========================================================================
  group('C7 (D6): the feedback cue sequence does not change with by', () {
    Future<List<FeedbackCue>> runStream(
      WidgetTester tester, {
      required bool withBy,
    }) async {
      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[5, -1, -1, -1]),
          _seatJson(1, name: 'Bob', tokens: const <int>[48, -1, -1, -1]),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
      );
      addTearDown(controller.dispose);
      final _FakeFeedbackService fake = _FakeFeedbackService();
      await _mount(tester, controller, service: fake);
      final _Seq seq = _Seq(1);

      Object? byOrAbsent() => withBy ? 'timer' : null;

      // 1. rolled, legal non-empty -> canMove.
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 4,
            'legal': const <int>[0],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'a' * 64,
            if (withBy) 'by': byOrAbsent(),
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // 2. moved, captures Bob, zero travel -> capturedOther.
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 5,
            'to': 5,
            'captured': <Map<String, Object?>>[
              <String, Object?>{'seat': 1, 'token': 0},
            ],
            'extra_roll': false,
            if (withBy) 'by': byOrAbsent(),
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // 3. rolled, legal empty -> noMove (also arms the existing no-move
      // hold; drained below so no Timer survives this case).
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 6,
            'legal': const <int>[],
            'deadline_ms': 45000,
            'k': 2,
            'reveal': 'b' * 64,
            if (withBy) 'by': byOrAbsent(),
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // 4. turn naming the other seat -> no cue for me.
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 1,
            'deadline_ms': 45000,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // Drain the no-move hold's own 1500ms Timer before this case ends.
      await tester.pump(const Duration(milliseconds: 1600));

      return fake.recorded;
    }

    testWidgets('without by: canMove, capturedOther, noMove, in that order', (
      tester,
    ) async {
      final List<FeedbackCue> recorded = await runStream(tester, withBy: false);
      expect(
        recorded,
        equals(const <FeedbackCue>[
          FeedbackCue.canMove,
          FeedbackCue.capturedOther,
          FeedbackCue.noMove,
        ]),
        reason:
            'fixture control: the plain (no by) frame stream must play '
            'exactly canMove, capturedOther, noMove in that order -- '
            'D6\'s own three named examples. If this is not green, C7\'s '
            'own comparison below proves nothing',
      );
    });

    testWidgets('with by: timer on every rolled/moved: the identical sequence '
        '(D6)', (tester) async {
      final List<FeedbackCue> recorded = await runStream(tester, withBy: true);
      expect(
        recorded,
        equals(const <FeedbackCue>[
          FeedbackCue.canMove,
          FeedbackCue.capturedOther,
          FeedbackCue.noMove,
        ]),
        reason:
            'D6: adding by: timer to every rolled/moved in the same '
            'frame stream must play the identical cue sequence -- '
            '"the sequence of cue ids for a given frame stream is '
            'identical with and without by". Already green today: '
            'cuesForFrame (lib/src/feedback.dart, read-only) never '
            'reads by at all',
      );
    });
  });

  // ==========================================================================
  // C8 (D3): the mine notice is announced to TalkBack once per arm from
  // hidden, in the active locale -- not on every re-arm while already
  // shown, and not on unrelated frames while it stays shown.
  // ==========================================================================
  group('C8 (D3): one TalkBack announcement per arm from hidden', () {
    Future<void> runCase(WidgetTester tester, {required Locale locale}) async {
      final _AnnouncementRecorder recorder = _AnnouncementRecorder();
      recorder.install(tester);
      addTearDown(() => recorder.remove(tester));

      final (
        RoomController controller,
        FakeTransport transport,
      ) = await _connectTo(
        tester,
        players: 2,
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller, locale: locale);
      final _Seq seq = _Seq(1);
      final int expectedDirection = locale.languageCode == 'ar'
          ? TextDirection.rtl.index
          : TextDirection.ltr.index;
      final AppLocalizations loc = _locOf(tester);

      // This scenario's own frame script pushes one bare `turn` naming my
      // own seat (below, "my own next turn frame") purely to prove D3's
      // "does NOT clear when my next turn begins" -- but C-337 rule 1
      // (already landed, unrelated to this contract) announces
      // loc.gameYourTurnStale on every `turn` frame naming my seat,
      // regardless of this contract's own by-driven announcement. Counting
      // raw announcements would make this case fail a correct future
      // implementation (it would see that unrelated announcement plus the
      // new arm) or pass today for the wrong reason (the unrelated
      // announcement alone, coincidentally matching the expected count).
      // noticeOnly() reads off only what is left once that one known,
      // already-proven announcement is excluded.
      List<_Announcement> noticeOnly() => recorder.recorded
          .where((_Announcement a) => a.message != loc.gameYourTurnStale)
          .toList();

      // Arm #1, from hidden.
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 0,
            'value': 5,
            'legal': const <int>[0, 1],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'a' * 64,
            'by': 'timer',
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        noticeOnly(),
        hasLength(1),
        reason:
            'D3 (${locale.languageCode}): arming the notice from hidden '
            'must announce exactly once; recorded ${recorder.recorded}. '
            'Red today: the notice does not exist, so nothing ever arms '
            'and nothing is ever announced',
      );
      if (noticeOnly().isNotEmpty) {
        expect(
          noticeOnly().single.textDirectionIndex,
          expectedDirection,
          reason:
              'D3 (${locale.languageCode}): the arm announcement must '
              'carry the active locale\'s text direction',
        );
      }

      // Re-arm while still shown (a later timer step for my seat, ending
      // my turn, D3\'s own "re-armed, same text") must not announce again.
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 2,
            'to': 2,
            'captured': const <Object?>[],
            'extra_roll': false,
            'by': 'timer',
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        noticeOnly(),
        hasLength(1),
        reason:
            'D3 (${locale.languageCode}): a re-arm while the notice is '
            'already shown must not announce a second time; recorded '
            '${recorder.recorded}',
      );

      // Unrelated frames (seat 1\'s own ordinary turn, back to me) must
      // not announce anything either, while mine stays shown throughout.
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 1,
            'deadline_ms': 45000,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      transport.pushText(
        _frame(
          type: 'rolled',
          data: <String, Object?>{
            'seat': 1,
            'value': 3,
            'legal': const <int>[],
            'deadline_ms': 45000,
            'k': 1,
            'reveal': 'b' * 64,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      transport.pushText(
        _frame(
          type: 'turn_passed',
          data: <String, Object?>{
            'seat': 1,
            'reason': 'no_legal_move',
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 0,
            'deadline_ms': 45000,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        noticeOnly(),
        hasLength(1),
        reason:
            'D3 (${locale.languageCode}): seat 1\'s own unrelated frames '
            'and my own next-turn frame must not announce the notice '
            'again while it stays shown (my own next-turn frame does '
            'announce the already-landed, unrelated loc.gameYourTurnStale '
            'via C-337 rule 1 -- excluded from this count by noticeOnly(), '
            'see this case\'s own comment); recorded ${recorder.recorded}',
      );

      // Clear it with a real tap (die, since the turn above landed me back
      // in await_roll).
      await tester.tap(find.byKey(_dieKey));
      await tester.pump();
      final String rollId = _idOf(
        transport.sentRaw.firstWhere((String s) => _typeOf(s) == 'roll'),
      );
      _settleRoll(
        transport,
        rollId,
        seat: 0,
        value: 4,
        k: 2,
        legal: const <int>[0, 1],
        seq: seq.next(),
      );
      await tester.pump();
      await tester.pump();

      // Re-arm from hidden: a fresh announcement must fire.
      transport.pushText(
        _frame(
          type: 'moved',
          data: <String, Object?>{
            'seat': 0,
            'token': 0,
            'from': 10,
            'to': 10,
            'captured': const <Object?>[],
            'extra_roll': false,
            'by': 'timer',
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      transport.pushText(
        _frame(
          type: 'turn',
          data: <String, Object?>{
            'seat': 1,
            'deadline_ms': 45000,
            'seq': seq.next(),
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        noticeOnly(),
        hasLength(2),
        reason:
            'D3 (${locale.languageCode}): re-arming from hidden (after '
            'the die tap cleared it) must announce exactly once more -- '
            '"announced once to TalkBack ... each time it is armed from '
            'hidden". Red today: never arms, never announces, so this '
            'count can never reach 2 without 428\'s own implementation; '
            'recorded ${recorder.recorded}',
      );
      if (noticeOnly().length == 2) {
        expect(
          noticeOnly()[1].textDirectionIndex,
          expectedDirection,
          reason:
              'D3 (${locale.languageCode}): the second arm announcement '
              'must also carry the active locale\'s text direction',
        );
      }
    }

    testWidgets('en', (tester) async {
      await runCase(tester, locale: const Locale('en'));
    });

    testWidgets('ar', (tester) async {
      await runCase(tester, locale: const Locale('ar'));
    });
  });

  // ==========================================================================
  // C9 (D5): the board rect does not move when the notice appears, at
  // 360x640, scale 1.0/2.0, en/ar.
  // ==========================================================================
  group('C9 (D5): the board rect is unaffected by the notice', () {
    setUpAll(_loadAppFonts);

    for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
      for (final double scale in const <double>[1.0, 2.0]) {
        testWidgets(
          '${locale.languageCode} scale ${scale.toStringAsFixed(1)}: the '
          'board rect before a notice appears equals the rect after',
          (tester) async {
            // Logical 360x640 through _mount's own setSurfaceSize, the
            // same mechanism every other case in this file already uses
            // (test/automove_says_so_test.dart's own idiom); devicePixelRatio
            // 1 is this binding's own default and nothing here changes it,
            // so there is nothing to reset.
            final (
              RoomController controller,
              FakeTransport transport,
            ) = await _connectTo(
              tester,
              players: 2,
              seats: <Map<String, Object?>>[
                _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
                _seatJson(1, name: 'Bob'),
              ],
              turn: <String, Object?>{
                'seat': 0,
                'phase': 'await_roll',
                'deadline_ms': 45000,
                'k': 0,
              },
            );
            addTearDown(controller.dispose);
            await _mount(
              tester,
              controller,
              locale: locale,
              textScale: scale,
              size: const Size(360, 640),
            );

            expect(
              find.byKey(_boardKey),
              findsOneWidget,
              reason:
                  'fixture is broken: game-screen-board must be on screen '
                  'before this case can measure its rect',
            );
            final Rect before = tester.getRect(find.byKey(_boardKey));

            transport.pushText(
              _frame(
                type: 'rolled',
                data: <String, Object?>{
                  'seat': 0,
                  'value': 5,
                  'legal': const <int>[0, 1],
                  'deadline_ms': 45000,
                  'k': 1,
                  'reveal': 'a' * 64,
                  'by': 'timer',
                  'seq': 2,
                },
              ),
            );
            await tester.pump();
            await tester.pump();

            final Rect after = tester.getRect(find.byKey(_boardKey));
            expect(
              _rectsClose(before, after),
              isTrue,
              reason:
                  'D5 (${locale.languageCode}, scale $scale): the board '
                  'rect must not move when game-timer-played-notice '
                  'appears; before=$before after=$after. On this tree '
                  '(no D3 implementation) the notice never actually '
                  'renders, so before and after are the same render and '
                  'this passes for the degenerate reason explained in '
                  'this file\'s header ambiguity 2 -- it becomes 428\'s '
                  'own regression guard once the notice is real',
            );
          },
        );
      }
    }
  });

  // ==========================================================================
  // C10 (D3, D8): a resume snapshot carries no by, so it arms nothing; and
  // a resume is none of D3's three clearing events, so a notice armed
  // before the drop is still there after it.
  // ==========================================================================
  group('C10 (D3, D8): a resume neither arms nor clears the notice', () {
    testWidgets(
      'armed, then the socket drops and a resume answers: the notice is '
      'still shown',
      (tester) async {
        final _Connector connector = _Connector();
        final FakeTransport transport = FakeTransport();
        connector.enqueue(transport);
        final RoomController controller = RoomController(
          serverUrl: Uri.parse(_testUrl),
          connect: connector.call,
        );
        addTearDown(controller.dispose);

        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[2, 10, -1, -1]),
          _seatJson(1, name: 'Bob'),
        ];
        final Map<String, Object?> turn = <String, Object?>{
          'seat': 0,
          'phase': 'await_move',
          'deadline_ms': 45000,
          'k': 1,
          'value': 5,
          'legal': const <int>[0, 1],
        };

        final Future<void> future = controller.createRoom(
          name: 'Sam',
          players: 2,
        );
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        final String createId = _idOf(transport.sentRaw.last);
        transport.pushText(
          _frame(
            type: 'seat_assigned',
            data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
          ),
        );
        transport.pushText(
          _frame(
            type: 'room',
            re: createId,
            data: _roomJson(players: 2, seats: seats, turn: turn, seq: 1),
          ),
        );
        await future;

        await _mount(tester, controller);

        transport.pushText(
          _frame(
            type: 'moved',
            data: <String, Object?>{
              'seat': 0,
              'token': 0,
              'from': 2,
              'to': 2,
              'captured': const <Object?>[],
              'extra_roll': false,
              'by': 'timer',
              'seq': 2,
            },
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason:
              'fixture setup: the notice must be armed before the drop, '
              'or this case measures nothing about the resume. Red today '
              '(missing key)',
        );

        transport.endFromFarSide();
        await tester.pump();
        await tester.pump();
        expect(
          controller.phase,
          RoomPhase.closed,
          reason: 'fixture is broken: the far side vanishing must close phase',
        );
        expect(
          find.byKey(_connectionLostKey),
          findsOneWidget,
          reason:
              'fixture is broken: the connection-lost body must be '
              'showing before the reconnect button can be tapped',
        );

        final FakeTransport resumeTransport = FakeTransport();
        connector.enqueue(resumeTransport);
        await tester.tap(find.byKey(_reconnectButtonKey));
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        expect(
          resumeTransport.sentRaw,
          isNotEmpty,
          reason:
              'fixture is broken: tapping game-screen-reconnect-button '
              'must have sent a resume request by now',
        );
        final String resumeId = _idOf(resumeTransport.sentRaw.last);
        expect(
          _typeOf(resumeTransport.sentRaw.last),
          'resume',
          reason: 'fixture is broken: the request sent must be resume',
        );

        // The resume reply: the same room and turn, carrying no by
        // anywhere (section 22.2: "Snapshots ... carry no by").
        resumeTransport.pushText(
          _frame(
            type: 'room',
            re: resumeId,
            data: _roomJson(players: 2, seats: seats, turn: turn, seq: 2),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          controller.phase,
          RoomPhase.connected,
          reason:
              'fixture is broken: the resume reply must land the '
              'controller back in RoomPhase.connected',
        );
        expect(
          find.byKey(_mineKey),
          findsOneWidget,
          reason:
              'D3: the notice clears only on my own sent play tap, game '
              'over, or the screen leaving the game. A resume is none of '
              'those, and the player who looked away and lost signal must '
              'still find it when they look back. Catches a resume path '
              'that rebuilds the screen state and drops the notice',
        );
      },
    );
  });
}
