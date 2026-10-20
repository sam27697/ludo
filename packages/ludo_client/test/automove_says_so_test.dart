// Conformance tests for work/ludo/orders/C-417-automove-says-so.md
// decisions D1-D5 and D8, written from that contract's own text alone (run
// 100). Order 418 (lib/src/board.dart, lib/src/game_screen.dart) is built in
// parallel, in a tree this file's author has not read; every expectation
// below is read off C-417's own words, never off 418's code.
//
// This tree (base origin/main 17cd195) carries neither of the two public
// symbols C-417 D1/D2 add: `AutoMoveArcPainter` (board.dart's own public
// countdown-arc painter, whose `remaining` field every case below reads) and
// `kAutoMoveHold` (board.dart's own public 1500ms hold constant, replacing
// game_screen.dart's private `_autoMoveHold`). Both names are used in
// exactly one place in this file -- the helper section immediately below
// these imports -- so the only compile errors this file can produce on this
// tree are the undefined identifiers in that one section; nothing below it
// names either symbol again.
//
// GameScreen is driven the way test/hold_after_walk_test.dart and
// test/play_surface_automove_test.dart do: a real RoomController sits over a
// FakeTransport (test/net/fake_transport.dart, read-only), fed `turn` and
// `moved` frames by hand, `legal_by_face` never used here (every case needs
// only one face and one token; the roll queue is not this contract's
// concern). Every helper below is copied by hand from those two files'
// patterns, per this project's own standing instruction never to import
// across test files -- this file is free-standing. The 1500ms hold, every
// token walk, and the pulsing ring are all advanced on flutter_test's fake
// clock through bounded `tester.pump(duration)` steps; nothing here uses
// `pumpAndSettle` (the legal ring and the arc both animate forever once
// armed) and nothing here uses a real Timer or a real delay.
//
// Two of C-417's new strings (`gameAutoMoving`, `announceAutoMoveArmed`)
// carry no getter on this tree yet, exactly like test/header_fits_test.dart
// and test/talkback_announce_test.dart already handle strings their own
// contracts added ahead of the getter existing: matched here by their
// literal text straight out of C-417's own table, never by a getter that
// does not compile. `gameYourTurnMove` and `gameTokenButton` already exist
// (D4 keeps the former for every case this contract does not touch; D5
// keeps the latter at the commit announcement) and are read through the
// getter as usual.
//
// Ambiguity found and not invented around: D2's own timing window ("at
// kAutoMoveHold after the glow appears") is phrased as a single instant; the
// order's own case 2 widens that to "not before 1450ms, sent by 1550ms" to
// absorb ordinary frame-boundary slop, so this file uses that window rather
// than asserting the send at exactly 1500ms to the millisecond. D3's own
// three checkpoints (100/600/1100ms) sit 100ms after each discrete tick
// (0/500/1000ms) for the same reason -- checking exactly on a tick boundary
// would race the frame that actually commits the new discrete value.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

// ============================================================================
// The one helper section in this file that names `AutoMoveArcPainter` or
// `kAutoMoveHold`. On origin/main 17cd195 neither symbol exists on
// package:ludo_client/src/board.dart, so this import, and every helper
// below it in this section, is the sole source of this file's expected red
// on that tree: a compile error naming each identifier once. Nothing
// outside this section names either symbol again -- every case below reads
// an arc's `remaining` only through [arcRemainingAt] and every hold-timing
// expression below reads the 1500ms value only through [kHold].
// ============================================================================
import 'package:ludo_client/src/board.dart'
    show AutoMoveArcPainter, kAutoMoveHold;

/// C-417 D2's own hold constant, aliased once here so no expression below
/// this section has to name `kAutoMoveHold` directly.
const Duration kHold = kAutoMoveHold;

/// True when [w] is the `CustomPaint` C-417 D1 says paints the countdown
/// arc: a `CustomPaint` whose `painter` is an `AutoMoveArcPainter`.
bool _isArcCustomPaint(Widget w) =>
    w is CustomPaint && w.painter is AutoMoveArcPainter;

/// The `remaining` field of the `AutoMoveArcPainter` painting the arc at or
/// under [key] (`board-automove-arc-S-T`, D1's own key), or null if no such
/// painter is found there -- [key] not existing at all, or existing but
/// carrying no `AutoMoveArcPainter`-driven `CustomPaint` anywhere under it,
/// are both reported as null so a caller can give one `reason` that covers
/// either shape of absence. `matchRoot: true` so a `CustomPaint` that
/// itself carries [key] (no separate wrapper) is found too, not only a
/// `CustomPaint` nested under a wrapper that carries it.
double? arcRemainingAt(WidgetTester tester, Key key) {
  final Finder keyed = find.byKey(key);
  if (tester.widgetList(keyed).isEmpty) {
    return null;
  }
  final Finder painted = find.descendant(
    of: keyed,
    matching: find.byWidgetPredicate(_isArcCustomPaint),
    matchRoot: true,
  );
  final List<Widget> found = tester.widgetList(painted).toList();
  if (found.isEmpty) {
    return null;
  }
  final CustomPaint paint = found.single as CustomPaint;
  return (paint.painter! as AutoMoveArcPainter).remaining;
}

/// Every `AutoMoveArcPainter`-driven `CustomPaint` anywhere in the current
/// widget tree, under any key. Used by cases that must prove no arc exists
/// anywhere on screen, not only absent at one particular seat/token key --
/// a wrong seat or token index in the implementation would still show up
/// here even if the one key a narrower check named happened to be clear.
Finder anyArcFinder() => find.byWidgetPredicate(_isArcCustomPaint);

// ============================================================================
// Ordinary test scaffolding below this line: no further use of
// `AutoMoveArcPainter` or `kAutoMoveHold`, direct or aliased.
// ============================================================================

const String _testUrl = 'wss://automove-says-so-test.invalid/ws';

Key _glowKey(int seat, int index) => Key('board-automove-glow-$seat-$index');
Key _arcKey(int seat, int index) => Key('board-automove-arc-$seat-$index');
Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');
const Key _bannerKey = Key('game-screen-turn-banner');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'automove-says-so-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;
String _typeOf(String sentText) => _decode(sentText)['t']! as String;
Map<String, Object?> _dataOf(String sentText) =>
    _decode(sentText)['d']! as Map<String, Object?>;

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
  int players = 2,
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

/// A plain mutable counter for the room's `seq`, so every pushed frame below
/// can carry the next value without each test hand-tracking an int (a
/// mismatch here makes RoomController begin a resync instead of applying
/// the frame, which would silently break the scenario rather than fail
/// loudly). Copied from test/hold_after_walk_test.dart's own `_Seq`.
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

Widget _harness(
  Widget child, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
  double textScale = 1.0,
}) {
  return MaterialApp(
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
        data: data.copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: screen!,
      );
    },
    home: child,
  );
}

/// Mounts at a realistic phone size (test/hold_after_walk_test.dart's own
/// choice and its own reasoning: on the default, unrealistically small test
/// surface a `tester.tap` aimed at a token's hit rect can land on the roll
/// tray instead).
Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
  double textScale = 1.0,
  Size size = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: controller),
      locale: locale,
      disableAnimations: disableAnimations,
      textScale: textScale,
    ),
  );
  await tester.pump();
}

/// Connects seat 0 of a two-seat room straight into `await_roll` at k=0.
/// Copied from test/hold_after_walk_test.dart's own `_connectSeat0`.
Future<(RoomController, FakeTransport)> _connectSeat0(
  WidgetTester tester, {
  List<int> seat0Tokens = const <int>[2, -1, -1, -1],
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
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: seat0Tokens),
          _seatJson(1, name: 'Bob'),
        ],
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': 45000,
          'k': 0,
        },
        seq: 1,
      ),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

/// Arms the unique-legal hold directly from a `turn` frame naming [seat] as
/// the unique legal token among [legal] (no roll queue): the same shape
/// test/hold_after_walk_test.dart's own case 3 (guard) and
/// test/play_header_test.dart's `myTurnAwaitMove` fixture already push.
/// Every token named in [legal] must already be at rest (not travelling)
/// for the glow (and now the arc) to appear on the very next pump.
Future<void> _armLegal(
  WidgetTester tester,
  FakeTransport transport,
  _Seq seq, {
  int seat = 0,
  required List<int> legal,
  int k = 1,
  int value = 5,
}) async {
  transport.pushText(
    _frame(
      type: 'turn',
      data: <String, Object?>{
        'seat': seat,
        'phase': 'await_move',
        'deadline_ms': 45000,
        'k': k,
        'value': value,
        'legal': legal,
        'seq': seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Pushes the `moved` leg that starts a token's walk, then the `turn` frame
/// (same seat, await_move, same k) that makes it the unique legal token --
/// zero fake-clock time between the two pushes, C-408 D7's own "most
/// extreme, clearest case" of "the turn state arrives before the walk
/// lands" (test/hold_after_walk_test.dart's own `_startWalkAndArm`, copied
/// by hand and trimmed to the plain (no roll queue) shape this file needs).
Future<void> _startWalkAndArm(
  WidgetTester tester,
  FakeTransport transport,
  _Seq seq, {
  int seat = 0,
  required int token,
  required int fromProgress,
  required int toProgress,
  required int movedFace,
  int k = 1,
}) async {
  transport.pushText(
    _frame(
      type: 'moved',
      data: <String, Object?>{
        'seat': seat,
        'token': token,
        'from': fromProgress,
        'to': toProgress,
        'captured': const <Object?>[],
        'extra_roll': false,
        'face': movedFace,
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
        'seat': seat,
        'phase': 'await_move',
        'deadline_ms': 45000,
        'k': k,
        'value': movedFace,
        'legal': <int>[token],
        'seq': seq.next(),
      },
    ),
  );
  await tester.pump();
  await tester.pump();
}

List<String> _movesSince(FakeTransport transport, int sentBefore) {
  return transport.sentRaw
      .skip(sentBefore)
      .where((String s) => _typeOf(s) == 'move')
      .toList();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

void main() {
  // ==========================================================================
  // Case 1 (D1): the countdown arc, shape and sweep.
  // ==========================================================================
  group('case 1 (D1): the countdown arc exists for the unique legal token, '
      'nowhere for two', () {
    testWidgets(
      'board-automove-arc-0-0 exists inside board-automove-glow-0-0; its '
      'AutoMoveArcPainter.remaining is 1.0 on the first frame, about 0.5 at '
      '750ms, at most 0.1 at 1400ms',
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        await _armLegal(tester, transport, seq, legal: const <int>[0]);

        expect(
          find.descendant(
            of: find.byKey(_glowKey(0, 0)),
            matching: find.byKey(_arcKey(0, 0)),
          ),
          findsOneWidget,
          reason:
              'D1: board-automove-arc-0-0 must exist inside '
              'board-automove-glow-0-0 while the hold is pending and the '
              'glow is visible; scenario: seat 0 token 0 at rest '
              '(progress 2), armed unique-legal at k=1',
        );

        final double? first = arcRemainingAt(tester, _arcKey(0, 0));
        expect(
          first,
          isNotNull,
          reason:
              'D1: board-automove-arc-0-0 must carry an AutoMoveArcPainter '
              'on the first frame the glow is built; found none',
        );
        expect(
          (first! - 1.0).abs(),
          lessThanOrEqualTo(0.05),
          reason:
              'D1: remaining must be 1.0 (within 0.05) on the first frame '
              'the glow subtree is built; got $first',
        );

        await tester.pump(const Duration(milliseconds: 750));
        final double? at750 = arcRemainingAt(tester, _arcKey(0, 0));
        expect(
          at750,
          isNotNull,
          reason: 'D1: the arc must still exist at 750ms into the 1500ms hold',
        );
        expect(
          (at750! - 0.5).abs(),
          lessThanOrEqualTo(0.1),
          reason:
              'D1: remaining must be about 0.5 (within 0.1) at 750ms into '
              'the 1500ms hold; got $at750',
        );

        await tester.pump(const Duration(milliseconds: 650));
        final double? at1400 = arcRemainingAt(tester, _arcKey(0, 0));
        expect(
          at1400 == null || at1400 <= 0.1,
          isTrue,
          reason:
              'D1: remaining must be at most 0.1 at 1400ms into the '
              '1500ms hold (or the arc may already be gone, this close to '
              'the send); got $at1400',
        );

        // Drain the hold so the pending move request leaves no open timer
        // behind when the test body ends.
        await tester.pump(const Duration(milliseconds: 200));
      },
    );

    testWidgets(
      'two legal tokens: no AutoMoveArcPainter-driven CustomPaint anywhere, '
      'at arming or 1500ms later',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[2, 10, -1, -1],
        );
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        await _armLegal(tester, transport, seq, legal: const <int>[0, 1]);

        expect(
          anyArcFinder(),
          findsNothing,
          reason:
              'D1: with two legal tokens (seat 0: token 0 at progress 2, '
              'token 1 at progress 10) there is no unique-legal decision, '
              'so no AutoMoveArcPainter-driven CustomPaint must exist '
              'anywhere right after arming',
        );

        await tester.pump(const Duration(milliseconds: 1500));
        expect(
          anyArcFinder(),
          findsNothing,
          reason:
              'D1: still no arc anywhere 1500ms after a two-legal-token '
              'turn arrived -- there was never a unique-legal decision to '
              'hold',
        );
      },
    );
  });

  // ==========================================================================
  // Case 2 (D2): one clock; a rebuild during the hold does not restart it.
  // ==========================================================================
  group('case 2 (D2): the send lands at kAutoMoveHold after the glow '
      'appears; a rebuild mid-hold does not reset remaining to 1.0', () {
    testWidgets('the move is sent not before 1450ms and by 1550ms after the glow '
        'appears, with remaining at most 0.05 (or the arc gone) at the send; '
        'an identical turn frame at 500ms and a text-scale change at 700ms do '
        'not reset remaining to 1.0', (tester) async {
      final (RoomController controller, FakeTransport transport) =
          await _connectSeat0(tester);
      await _mount(tester, controller);
      final _Seq seq = _Seq(1);

      final int sentAtArm = transport.sentRaw.length;
      await _armLegal(tester, transport, seq, legal: const <int>[0], k: 1);

      expect(
        arcRemainingAt(tester, _arcKey(0, 0)),
        isNotNull,
        reason:
            'D1: the arc must exist right after arming, on the first frame '
            'the glow subtree is built',
      );

      // At 500ms: a second, identical turn frame for the same k and
      // (empty, no roll queue) queue -- D2's own "a new frame for the
      // same k and queue" -- must not be a restart.
      await tester.pump(const Duration(milliseconds: 500));
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

      // At 700ms (200ms after the identical turn frame): change the text
      // scale -- D2's own "a locale or text-scale change" -- also not a
      // restart. Re-pumping the same GameScreen/controller at the same
      // Element location preserves its State.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(
        _harness(GameScreen(controller: controller), textScale: 1.3),
      );
      await tester.pump();

      final double? at720 = arcRemainingAt(tester, _arcKey(0, 0));
      expect(
        at720,
        isNotNull,
        reason:
            'D2: the arc must still exist at 720ms, after the identical '
            'turn frame at 500ms and the text-scale change at 700ms',
      );
      expect(
        at720! < 0.95,
        isTrue,
        reason:
            'D2: the identical turn frame at 500ms and the text-scale '
            'change at 700ms must not restart the arc -- at 720ms into '
            'the 1500ms hold, remaining must not sit back near 1.0; got '
            '$at720',
      );

      // Not before 1450ms after the glow appeared (720ms already
      // elapsed): nothing sent yet.
      await tester.pump(const Duration(milliseconds: 1450 - 720));
      expect(
        _movesSince(transport, sentAtArm),
        isEmpty,
        reason:
            'D2: no move must be sent before kAutoMoveHold (${kHold.inMilliseconds}ms) '
            'after the glow appeared; checked at 1450ms',
      );

      // By 1550ms: exactly one move, and the arc is at most 0.05 or gone.
      await tester.pump(const Duration(milliseconds: 100));
      final List<String> moves = _movesSince(transport, sentAtArm);
      expect(
        moves,
        hasLength(1),
        reason:
            'D2: exactly one move must be sent by 1550ms after the glow '
            'appeared; sentRaw carries ${moves.length}',
      );
      expect(_dataOf(moves.single)['token'], 0);
      final double? atSend = arcRemainingAt(tester, _arcKey(0, 0));
      expect(
        atSend == null || atSend <= 0.05,
        isTrue,
        reason:
            'D2: at the moment the move is sent, remaining must be at '
            'most 0.05, or the arc must already be gone; got $atSend',
      );
    });
  });

  // ==========================================================================
  // Case 3 (D3): reduced motion keeps the meaning -- three discrete steps.
  // ==========================================================================
  group('case 3 (D3): reduced motion ticks the arc through 1.0, 2/3, 1/3', () {
    testWidgets(
      'remaining is exactly 1.0 at 100ms, 2/3 at 600ms, 1/3 at 1100ms, and '
      'never outside {1, 2/3, 1/3} while the arc is present',
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _connectSeat0(tester);
        await _mount(tester, controller, disableAnimations: true);
        final _Seq seq = _Seq(1);

        const double oneThird = 1 / 3;
        const double twoThirds = 2 / 3;
        const List<double> allowed = <double>[1.0, twoThirds, oneThird];

        bool isOneOf(double remaining) =>
            allowed.any((double v) => (remaining - v).abs() <= 0.02);

        void expectStep(
          double? remaining,
          double expected,
          int atMs, {
          double tolerance = 0.01,
        }) {
          expect(
            remaining,
            isNotNull,
            reason: 'D3: the arc must exist at ${atMs}ms under reduced motion',
          );
          expect(
            (remaining! - expected).abs(),
            lessThanOrEqualTo(tolerance),
            reason:
                'D3: remaining at ${atMs}ms must be $expected (within '
                '$tolerance); got $remaining',
          );
          expect(
            isOneOf(remaining),
            isTrue,
            reason:
                'D3: remaining must never take a value outside {1, 2/3, '
                '1/3} while the arc is present; at ${atMs}ms got $remaining',
          );
        }

        await _armLegal(tester, transport, seq, legal: const <int>[0], k: 1);

        await tester.pump(const Duration(milliseconds: 100));
        expectStep(arcRemainingAt(tester, _arcKey(0, 0)), 1.0, 100);

        await tester.pump(const Duration(milliseconds: 200));
        expectStep(arcRemainingAt(tester, _arcKey(0, 0)), 1.0, 300);

        await tester.pump(const Duration(milliseconds: 300));
        expectStep(arcRemainingAt(tester, _arcKey(0, 0)), twoThirds, 600);

        await tester.pump(const Duration(milliseconds: 200));
        expectStep(arcRemainingAt(tester, _arcKey(0, 0)), twoThirds, 800);

        await tester.pump(const Duration(milliseconds: 300));
        expectStep(arcRemainingAt(tester, _arcKey(0, 0)), oneThird, 1100);

        await tester.pump(const Duration(milliseconds: 200));
        expectStep(arcRemainingAt(tester, _arcKey(0, 0)), oneThird, 1300);

        // Drain the hold.
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  });

  // ==========================================================================
  // Case 4 (D3, the defect itself): X69's regression, fixed. Under reduced
  // motion the auto-move token's board subtree must differ from an ordinary
  // legal token's -- before C-417 both froze pixel-identical.
  // ==========================================================================
  group('case 4 (D3 defect, X69): under reduced motion the auto-move token no '
      'longer looks like an ordinary legal token', () {
    testWidgets(
      'X69 fixed: a unique-legal token under reduced motion carries the '
      'arc',
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _connectSeat0(tester);
        await _mount(tester, controller, disableAnimations: true);
        final _Seq seq = _Seq(1);

        await _armLegal(tester, transport, seq, legal: const <int>[0]);

        expect(
          anyArcFinder(),
          findsOneWidget,
          reason:
              "X69 (fixed by D3): under reduced motion, a unique-legal "
              'token at rest must carry exactly one '
              'AutoMoveArcPainter-driven CustomPaint -- the mark that '
              'tells it apart from an ordinary legal token, which the '
              'frozen _PulsingRing alone (pre-C-417) could not do',
        );
      },
    );

    testWidgets(
      'X69 fixed: two ordinary legal tokens under reduced motion carry no '
      'arc at all -- nothing to tell apart from an auto-move that never '
      'arms',
      (tester) async {
        final (
          RoomController controller,
          FakeTransport transport,
        ) = await _connectSeat0(
          tester,
          seat0Tokens: const <int>[2, 10, -1, -1],
        );
        await _mount(tester, controller, disableAnimations: true);
        final _Seq seq = _Seq(1);

        await _armLegal(tester, transport, seq, legal: const <int>[0, 1]);

        expect(
          anyArcFinder(),
          findsNothing,
          reason:
              'X69 (fixed by D3): two ordinary legal tokens under reduced '
              'motion must carry no AutoMoveArcPainter anywhere -- only '
              'the one unique-legal, held token ever gets the arc',
        );
      },
    );
  });

  // ==========================================================================
  // Case 5 (D4): words on screen.
  // ==========================================================================
  group('case 5 (D4): the banner says the token will move by itself', () {
    for (final (String code, String expected) in const <(String, String)>[
      ('en', 'Only one move. Playing it for you.'),
      ('ar', 'حركة وحيدة. سنلعبها عنك.'),
    ]) {
      testWidgets(
        '$code: during the visible hold the banner is exactly the new '
        'string',
        (tester) async {
          final (RoomController controller, FakeTransport transport) =
              await _connectSeat0(tester);
          await _mount(tester, controller, locale: Locale(code));
          final _Seq seq = _Seq(1);

          await _armLegal(tester, transport, seq, legal: const <int>[0]);

          expect(
            find.byKey(_glowKey(0, 0)),
            findsOneWidget,
            reason: 'fixture is broken: the glow must be visible once armed',
          );
          final String shown =
              tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
          expect(
            shown,
            expected,
            reason:
                'D4 ($code): while the hold is pending and the glow is '
                'visible, the banner must read exactly "$expected"; got '
                '"$shown"',
          );
        },
      );
    }

    for (final String code in const <String>['en', 'ar']) {
      testWidgets(
        '$code: with two legal tokens the banner is the ordinary move '
        'string',
        (tester) async {
          final (
            RoomController controller,
            FakeTransport transport,
          ) = await _connectSeat0(
            tester,
            seat0Tokens: const <int>[2, 10, -1, -1],
          );
          await _mount(tester, controller, locale: Locale(code));
          final _Seq seq = _Seq(1);

          await _armLegal(tester, transport, seq, legal: const <int>[0, 1]);

          final AppLocalizations loc = _locOf(tester);
          final String shown =
              tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
          expect(
            shown,
            loc.gameYourTurnMove,
            reason:
                'D4 ($code): with two legal tokens there is no auto-move '
                'hold, so the banner must stay loc.gameYourTurnMove '
                '("${loc.gameYourTurnMove}"); got "$shown"',
          );
        },
      );
    }

    testWidgets(
      'while the held token is still walking the banner is the ordinary '
      'move string; the new string appears once the walk lands',
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);
        final AppLocalizations loc = _locOf(tester);

        // Token 0 walks progress 2 -> 6 (landing at 4 * kTokenStepDuration
        // = 560ms); the turn frame naming it the unique legal token for
        // k=1 arrives with zero fake-clock time elapsed, C-408 D7's own
        // "most extreme" case -- the walk has not taken its first step
        // when the hold arms.
        await _startWalkAndArm(
          tester,
          transport,
          seq,
          token: 0,
          fromProgress: 2,
          toProgress: 6,
          movedFace: 4,
          k: 1,
        );

        await tester.pump(const Duration(milliseconds: 200));
        expect(
          find.byKey(_glowKey(0, 0)),
          findsNothing,
          reason:
              'fixture is broken: at 200ms into a 560ms walk the glow must '
              'still be hidden (C-408 D1)',
        );
        String shown = tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
        expect(
          shown,
          loc.gameYourTurnMove,
          reason:
              'D4: before the glow is visible (the held token is still '
              'walking, C-408 D1), the banner must be the ordinary move '
              'string loc.gameYourTurnMove ("${loc.gameYourTurnMove}"); got '
              '"$shown"',
        );

        // Past landing (560ms): the glow is up, and the new string must
        // have taken over.
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_glowKey(0, 0)),
          findsOneWidget,
          reason:
              'fixture is broken: at 600ms the walk (landing 560ms) must '
              'have landed and the glow must be visible',
        );
        shown = tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
        expect(
          shown,
          'Only one move. Playing it for you.',
          reason:
              'D4: once the walk lands and the glow becomes visible, the '
              'banner must switch to the new auto-move string; got "$shown"',
        );
      },
    );
  });

  // ==========================================================================
  // Case 6 (D4 fit): the new banner string fits one line at both device
  // sizes, both locales, text scale 1.0/1.3/2.0.
  // ==========================================================================
  group('case 6 (D4 fit): the new banner string is one line, not cut, at '
      'every size/locale/scale C-339 and C-391 already test the old '
      'strings at', () {
    const List<Size> sizes = <Size>[Size(360, 640), Size(411, 704)];
    const List<double> scales = <double>[1.0, 1.3, 2.0];
    const Map<String, String> expected = <String, String>{
      'en': 'Only one move. Playing it for you.',
      'ar': 'حركة وحيدة. سنلعبها عنك.',
    };

    for (final Size size in sizes) {
      for (final double scale in scales) {
        for (final String code in const <String>['en', 'ar']) {
          final String label =
              '${size.width.toInt()}x${size.height.toInt()} '
              'scale ${scale.toStringAsFixed(1)} $code';
          testWidgets('$label: fits one line, not cut', (tester) async {
            final (RoomController controller, FakeTransport transport) =
                await _connectSeat0(tester);
            await _mount(
              tester,
              controller,
              locale: Locale(code),
              textScale: scale,
              size: size,
            );
            final _Seq seq = _Seq(1);
            await _armLegal(tester, transport, seq, legal: const <int>[0]);

            expect(
              find.byKey(_bannerKey),
              findsOneWidget,
              reason: '$label: game-screen-turn-banner must be on screen',
            );
            final String shown =
                tester.widget<Text>(find.byKey(_bannerKey)).data ?? '';
            expect(
              shown,
              expected[code],
              reason:
                  '$label: banner text, expected "${expected[code]}", got '
                  '"$shown"',
            );
            final RenderParagraph paragraph = tester
                .renderObject<RenderParagraph>(
                  find.descendant(
                    of: find.byKey(_bannerKey),
                    matching: find.byType(RichText),
                  ),
                );
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason:
                  '$label: "$shown" exceeded one line '
                  '(RenderParagraph.didExceedMaxLines=true)',
            );
          });
        }
      }
    }
  });

  // ==========================================================================
  // Case 7 (D5): TalkBack hears the new arming announcement; the send
  // announcement is unchanged.
  // ==========================================================================
  group('case 7 (D5): arming announces the new string; the send still '
      'announces gameTokenButton', () {
    for (final (String code, String expectedArm) in const <(String, String)>[
      ('en', 'Only one move. Token 1 moves by itself.'),
      ('ar', 'حركة وحيدة. القطعة 1 ستتحرك وحدها.'),
    ]) {
      testWidgets(
        '$code: arming announces the new string once; the send announces '
        "gameTokenButton('1')",
        (tester) async {
          final List<Map<Object?, Object?>> recorded =
              <Map<Object?, Object?>>[];
          tester.binding.defaultBinaryMessenger
              .setMockDecodedMessageHandler<dynamic>(
                SystemChannels.accessibility,
                (dynamic message) async {
                  final Map<Object?, Object?> event =
                      message as Map<Object?, Object?>;
                  if (event['type'] == 'announce') {
                    recorded.add(event['data'] as Map<Object?, Object?>);
                  }
                  return null;
                },
              );
          addTearDown(() {
            tester.binding.defaultBinaryMessenger
                .setMockDecodedMessageHandler<dynamic>(
                  SystemChannels.accessibility,
                  null,
                );
          });

          final (RoomController controller, FakeTransport transport) =
              await _connectSeat0(tester);
          await _mount(tester, controller, locale: Locale(code));
          final _Seq seq = _Seq(1);
          final AppLocalizations loc = _locOf(tester);

          final int sentAtArm = transport.sentRaw.length;
          final int recordedBeforeArm = recorded.length;
          await _armLegal(tester, transport, seq, legal: const <int>[0]);

          // The `turn` frame `_armLegal` pushes names my own seat, which
          // also (C-225/C-337, unrelated to this contract) plays the
          // separate `yourTurn` cue every single `turn` frame naming my
          // seat does, regardless of phase -- so arming is allowed to
          // announce more than the one D5 string; what D5 requires is
          // that the new arming string is among them exactly once, not
          // that it is the only announcement in the batch.
          final List<Map<Object?, Object?>> afterArm = recorded.sublist(
            recordedBeforeArm,
          );
          expect(
            afterArm.where(
              (Map<Object?, Object?> m) => m['message'] == expectedArm,
            ),
            hasLength(1),
            reason:
                'D5 ($code): arming must announce "$expectedArm" exactly '
                'once; announcements from arming: $afterArm',
          );

          await tester.pump(const Duration(milliseconds: 1500));
          final List<String> moves = _movesSince(transport, sentAtArm);
          expect(
            moves,
            hasLength(1),
            reason:
                'fixture is broken: the hold must have sent exactly one '
                'move by 1500ms',
          );
          final List<Map<Object?, Object?>> afterSend = recorded.sublist(
            recordedBeforeArm + afterArm.length,
          );
          expect(
            afterSend.where(
              (Map<Object?, Object?> m) =>
                  m['message'] == loc.gameTokenButton(1),
            ),
            hasLength(1),
            reason:
                'D5 ($code): the send must still announce '
                'loc.gameTokenButton(1) ("${loc.gameTokenButton(1)}") '
                'exactly once; announcements from the send: $afterSend',
          );
        },
      );
    }
  });

  // ==========================================================================
  // Case 8 (D8): a tap sends at once and clears the arc; another seat's
  // unique legal turn shows no arc on this device.
  // ==========================================================================
  group('case 8 (D8): a tap during the hold sends once and clears the arc; '
      "another seat's unique legal turn shows no arc here", () {
    testWidgets(
      'a tap on the held token sends exactly one move at once; the arc is '
      'gone the next frame',
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        final int sentAtArm = transport.sentRaw.length;
        await _armLegal(tester, transport, seq, legal: const <int>[0]);

        expect(
          arcRemainingAt(tester, _arcKey(0, 0)),
          isNotNull,
          reason:
              'D1: the arc must exist right after arming, before the tap '
              'below cancels the hold',
        );

        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(_hitKey(0, 0)), warnIfMissed: false);
        await tester.pump();

        final List<String> moves = _movesSince(transport, sentAtArm);
        expect(
          moves,
          hasLength(1),
          reason:
              'D8: a tap on the held token during the hold must send '
              'exactly one move at once; sentRaw carries ${moves.length}',
        );
        expect(_dataOf(moves.single)['token'], 0);
        expect(
          anyArcFinder(),
          findsNothing,
          reason:
              'D8: the arc must be gone the very next frame after a tap '
              'sends the move',
        );
      },
    );

    testWidgets(
      "another seat's unique legal turn shows no arc on this device",
      (tester) async {
        final (RoomController controller, FakeTransport transport) =
            await _connectSeat0(tester);
        await _mount(tester, controller);
        final _Seq seq = _Seq(1);

        await _armLegal(tester, transport, seq, seat: 1, legal: const <int>[0]);

        expect(
          anyArcFinder(),
          findsNothing,
          reason:
              "D8 (unchanged, C-408): the hold never fires for another "
              "seat; seat 1's own unique-legal turn must show no "
              'AutoMoveArcPainter anywhere on this (seat 0) device',
        );
        expect(
          find.byKey(_glowKey(1, 0)),
          findsNothing,
          reason:
              "fixture check: seat 1's own token must not carry the glow "
              'either on this device',
        );
      },
    );
  });
}
