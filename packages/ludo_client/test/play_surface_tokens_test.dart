// Conformance tests for the tokens on GameScreen's new play surface, written
// from work/ludo/orders/C-223-play-surface.md (the master, run 65) alone.
// Order 223 (lib/src/game_screen.dart, lib/src/board.dart) is being built in
// parallel by a different worker; this file was written without opening
// either of those files' new content, so it is expected to fail to compile
// or run red against a branch that still carries the four
// `game-screen-token-N` buttons and no `board-token-hit-S-I`.
//
// GameScreen is driven the same way test/game_screen_test.dart drives
// RoomController: a real RoomController sits over a FakeTransport
// (test/net/fake_transport.dart, read-only, not edited here). Every claim
// about what the screen sent is checked by decoding FakeTransport.sentRaw,
// never assumed from a tap alone. board_geometry.dart's cellFor
// (lib/src/board_geometry.dart, unchanged by this order) is the ground truth
// used here for one fact: for progress 0..56, tokenIndex is ignored, so two
// tokens of one seat at the same progress share one cell -- that is how the
// stack case below is built, not invented.
//
// An ambiguity the contract's own wording does not resolve, reported rather
// than guessed: "tapping the hit target of any of them sends the lowest
// index among the legal tokens on that cell" does not say what happens when
// the lower-index token on a shared cell is itself not legal (only the
// higher one is). This file's stack case keeps both tokens on the shared
// cell legal, which is the one shape the contract text states outright, and
// does not test the mixed-legality case.

import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://play-surface-tokens-test.invalid/ws';

Key _hitKey(int seat, int index) => Key('board-token-hit-$seat-$index');
Key _ringKey(int seat, int index) => Key('board-legal-ring-$seat-$index');
Key _shakeKey(int seat, int index) => Key('board-token-shake-$seat-$index');

// --- server-side id generation for pushed frames ----------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'tok-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, mirroring the sibling suites -----------------------

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
  'winner': null,
  'seq': seq,
};

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

/// Connects a fresh controller with [seats] and lands it on [turn] with
/// mySeat always 0. A fresh connection per case (the idiom
/// test/game_screen_test.dart's own H4 group uses), so no wire state ever
/// bleeds between cases.
Future<(RoomController, FakeTransport)> _connectTo(
  WidgetTester tester, {
  required List<Map<String, Object?>> seats,
  required Map<String, Object?> turn,
  int players = 2,
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
      data: _roomJson(players: players, seats: seats, turn: turn),
    ),
  );
  await future;
  addTearDown(controller.dispose);
  return (controller, transport);
}

Widget _harness(
  Widget child, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData data = MediaQuery.of(context);
      return MediaQuery(
        data: data.copyWith(disableAnimations: disableAnimations),
        child: child!,
      );
    },
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    _harness(
      GameScreen(controller: controller),
      locale: locale,
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
}

AppLocalizations _locOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

Map<String, Object?> _awaitMoveTurn({
  required List<int> legal,
  int k = 1,
  int value = 4,
}) => _turnJson(
  seat: 0,
  phase: 'await_move',
  deadlineMs: 45000,
  k: k,
  value: value,
  legal: legal,
);

void main() {
  // ==========================================================================
  // Legal rings: on exactly the legal tokens.
  // ==========================================================================
  group('legal rings', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
      _seatJson(1, name: 'Bob'),
    ];

    Future<void> expectRings(WidgetTester tester, List<int> legal) async {
      final (controller, _) = await _connectTo(
        tester,
        seats: seats,
        turn: _awaitMoveTurn(legal: legal),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      for (int i = 0; i < 4; i++) {
        final bool shouldRing = legal.contains(i);
        expect(
          find.byKey(_ringKey(0, i)),
          shouldRing ? findsOneWidget : findsNothing,
          reason:
              'legal=$legal: board-legal-ring-0-$i must be '
              '${shouldRing ? "present" : "absent"}',
        );
      }
    }

    testWidgets('1 legal token: ring on exactly that token', (tester) async {
      await expectRings(tester, const <int>[2]);
    });

    testWidgets('2 legal tokens: rings on exactly those two', (tester) async {
      await expectRings(tester, const <int>[0, 3]);
    });

    testWidgets('4 legal tokens: rings on all four', (tester) async {
      await expectRings(tester, const <int>[0, 1, 2, 3]);
    });

    testWidgets('reduced motion still draws the legal ring', (tester) async {
      final (controller, _) = await _connectTo(
        tester,
        seats: seats,
        turn: _awaitMoveTurn(legal: const <int>[1]),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller, disableAnimations: true);

      expect(
        find.byKey(_ringKey(0, 1)),
        findsOneWidget,
        reason:
            'the legal ring must still be drawn (static) under reduced '
            'motion; meaning stays, only motion goes',
      );
    });
  });

  // ==========================================================================
  // Tapping a legal token.
  // ==========================================================================
  group('tapping a legal token', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
      _seatJson(1, name: 'Bob'),
    ];

    Future<void> checkToken(WidgetTester tester, int index) async {
      final (controller, transport) = await _connectTo(
        tester,
        seats: seats,
        turn: _awaitMoveTurn(legal: const <int>[1, 3]),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_hitKey(0, index)));
      await tester.pump();

      final List<String> newMessages = transport.sentRaw
          .skip(sentBefore)
          .toList();
      expect(
        newMessages,
        hasLength(1),
        reason:
            'tapping the legal hit target board-token-hit-0-$index must '
            'send exactly one move; got ${newMessages.length}',
      );
      expect(_typeOf(newMessages.single), 'move');
      expect(_dataOf(newMessages.single), <String, Object?>{'token': index});

      transport.pushText(
        _frame(
          type: 'moved',
          re: _idOf(newMessages.single),
          data: <String, Object?>{
            'seat': 0,
            'token': index,
            'from': 3,
            'to': 7,
            'captured': <Object?>[],
            'extra_roll': false,
            'seq': 2,
          },
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('token 1 (legal) sends move(1) exactly once', (tester) async {
      await checkToken(tester, 1);
    });

    testWidgets('token 3 (legal) sends move(3) exactly once', (tester) async {
      await checkToken(tester, 3);
    });
  });

  // ==========================================================================
  // Tapping a non-legal own token.
  // ==========================================================================
  group('tapping a non-legal own token', () {
    testWidgets(
      'sends nothing and shows board-token-shake-0-0, which clears after '
      'its shake',
      (tester) async {
        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
          _seatJson(1, name: 'Bob'),
        ];
        final (controller, transport) = await _connectTo(
          tester,
          seats: seats,
          turn: _awaitMoveTurn(legal: const <int>[1]),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        expect(find.byKey(_shakeKey(0, 0)), findsNothing);
        await tester.tap(find.byKey(_hitKey(0, 0)));
        await tester.pump();

        expect(
          transport.sentRaw.length,
          sentBefore,
          reason:
              'tapping a non-legal own token must send nothing; the wire '
              'grew by ${transport.sentRaw.length - sentBefore} message(s)',
        );
        expect(
          find.byKey(_shakeKey(0, 0)),
          findsOneWidget,
          reason:
              'tapping a non-legal own token must show '
              'board-token-shake-0-0',
        );

        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(_shakeKey(0, 0)),
          findsNothing,
          reason:
              'the shake (about 300ms) must have cleared by 400ms after '
              'the tap',
        );
      },
    );

    testWidgets('tapping any of my own tokens when it is not my awaitMove '
        'sends nothing and shakes', (tester) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (controller, transport) = await _connectTo(
        tester,
        seats: seats,
        turn: _turnJson(seat: 0, phase: 'await_roll', deadlineMs: 45000, k: 0),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_hitKey(0, 2)));
      await tester.pump();

      expect(
        transport.sentRaw.length,
        sentBefore,
        reason:
            'tapping my own token during awaitRoll (not awaitMove) must '
            'send nothing',
      );
    });
  });

  // ==========================================================================
  // Opponent tokens: no hit target at all.
  // ==========================================================================
  group('opponent tokens', () {
    testWidgets('no board-token-hit key exists for any other seat', (
      tester,
    ) async {
      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob', tokens: const <int>[5, 15, 25, 35]),
        _seatJson(2, name: 'Cara', tokens: const <int>[6, 16, 26, 36]),
        _seatJson(3, name: 'Dee', tokens: const <int>[7, 17, 27, 37]),
      ];
      final (controller, _) = await _connectTo(
        tester,
        seats: seats,
        players: 4,
        turn: _awaitMoveTurn(legal: const <int>[0, 1, 2, 3]),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);

      for (int i = 0; i < 4; i++) {
        expect(
          find.byKey(_hitKey(0, i)),
          findsOneWidget,
          reason: 'my own seat 0 must have a hit target for token $i',
        );
      }
      for (final int otherSeat in <int>[1, 2, 3]) {
        for (int i = 0; i < 4; i++) {
          expect(
            find.byKey(_hitKey(otherSeat, i)),
            findsNothing,
            reason:
                'seat $otherSeat is not mine; board-token-hit-$otherSeat-$i '
                'must not exist',
          );
        }
      }
    });
  });

  // ==========================================================================
  // Hit target size: >= 48x48 at a 360x800 phone size, both locales.
  // ==========================================================================
  group('hit target size', () {
    Future<void> expectAllAtLeast48(WidgetTester tester, Locale locale) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (controller, _) = await _connectTo(
        tester,
        seats: seats,
        turn: _awaitMoveTurn(legal: const <int>[0, 1, 2, 3]),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller, locale: locale);

      for (int i = 0; i < 4; i++) {
        final Size size = tester.getSize(find.byKey(_hitKey(0, i)));
        expect(
          size.width,
          greaterThanOrEqualTo(48.0),
          reason:
              'board-token-hit-0-$i width must be >= 48 at 360x800 under '
              '${locale.languageCode}; was ${size.width}',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(48.0),
          reason:
              'board-token-hit-0-$i height must be >= 48 at 360x800 under '
              '${locale.languageCode}; was ${size.height}',
        );
      }
    }

    testWidgets('en', (tester) async {
      await expectAllAtLeast48(tester, const Locale('en'));
    });

    testWidgets('ar', (tester) async {
      await expectAllAtLeast48(tester, const Locale('ar'));
    });
  });

  // ==========================================================================
  // Stacks: two own tokens sharing one cell are the same move.
  // ==========================================================================
  group('stacks', () {
    // board_geometry.dart's cellFor ignores tokenIndex for progress 0..56, so
    // tokens 0 and 2 both at progress 10 share exactly one cell.
    final List<Map<String, Object?>> stackedSeats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam', tokens: const <int>[10, 22, 10, 44]),
      _seatJson(1, name: 'Bob'),
    ];

    testWidgets(
      'tapping the higher index\'s own hit target on a shared cell still '
      'sends the lower legal index',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          seats: stackedSeats,
          turn: _awaitMoveTurn(legal: const <int>[0, 2]),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_hitKey(0, 2)));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(
          newMessages,
          hasLength(1),
          reason:
              'tapping board-token-hit-0-2 on a cell shared with legal '
              'token 0 must still send exactly one move',
        );
        expect(
          _dataOf(newMessages.single),
          <String, Object?>{'token': 0},
          reason:
              'the stack rule sends the lowest legal index on the shared '
              'cell (0), regardless of which of the two hit targets '
              '(0 or 2) was tapped; got ${_dataOf(newMessages.single)}',
        );
      },
    );

    testWidgets(
      'tapping the lower index\'s own hit target on the same shared cell '
      'sends the same lower index',
      (tester) async {
        final (controller, transport) = await _connectTo(
          tester,
          seats: stackedSeats,
          turn: _awaitMoveTurn(legal: const <int>[0, 2]),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        await tester.tap(find.byKey(_hitKey(0, 0)));
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(newMessages, hasLength(1));
        expect(_dataOf(newMessages.single), <String, Object?>{'token': 0});
      },
    );
  });

  // ==========================================================================
  // RTL: a tap lands on the token it was aimed at.
  // ==========================================================================
  group('RTL', () {
    final List<Map<String, Object?>> seats = <Map<String, Object?>>[
      _seatJson(0, name: 'سام', tokens: const <int>[3, 10, 20, 30]),
      _seatJson(1, name: 'بوب'),
    ];

    Future<void> expectTapHitsToken(WidgetTester tester, int index) async {
      final (controller, transport) = await _connectTo(
        tester,
        seats: seats,
        turn: _awaitMoveTurn(legal: const <int>[0, 1]),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller, locale: const Locale('ar'));

      final int sentBefore = transport.sentRaw.length;
      await tester.tap(find.byKey(_hitKey(0, index)));
      await tester.pump();

      final List<String> newMessages = transport.sentRaw
          .skip(sentBefore)
          .toList();
      expect(
        newMessages,
        hasLength(1),
        reason:
            'under Arabic (RTL), tapping board-token-hit-0-$index must '
            'still send exactly one move',
      );
      expect(
        _dataOf(newMessages.single),
        <String, Object?>{'token': index},
        reason:
            'under Arabic (RTL), tapping board-token-hit-0-$index must '
            'send token $index, not a mirrored other token; got '
            '${_dataOf(newMessages.single)}',
      );
    }

    testWidgets('a tap aimed at token 0 lands on token 0', (tester) async {
      await expectTapHitsToken(tester, 0);
    });

    testWidgets('a tap aimed at token 1 lands on token 1', (tester) async {
      await expectTapHitsToken(tester, 1);
    });
  });

  // ==========================================================================
  // Semantics.
  // ==========================================================================
  group('Semantics', () {
    testWidgets('each of my tokens is Semantics(button: true) labelled '
        'loc.gameTokenButton(index + 1), enabled true exactly when legal', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final List<Map<String, Object?>> seats = <Map<String, Object?>>[
        _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
        _seatJson(1, name: 'Bob'),
      ];
      final (controller, _) = await _connectTo(
        tester,
        seats: seats,
        turn: _awaitMoveTurn(legal: const <int>[1, 3]),
      );
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final AppLocalizations loc = _locOf(tester);

      for (int i = 0; i < 4; i++) {
        final SemanticsNode node = tester.getSemantics(
          find.byKey(_hitKey(0, i)),
        );
        expect(
          node.flagsCollection.isButton,
          isTrue,
          reason: 'board-token-hit-0-$i must carry SemanticsFlags.isButton',
        );
        expect(
          node.label,
          loc.gameTokenButton(i + 1),
          reason:
              'board-token-hit-0-$i label must be '
              'loc.gameTokenButton(${i + 1}) ("${loc.gameTokenButton(i + 1)}"); '
              'got "${node.label}"',
        );
        final bool shouldBeEnabled = i == 1 || i == 3;
        expect(
          node.flagsCollection.isEnabled,
          shouldBeEnabled ? Tristate.isTrue : Tristate.isFalse,
          reason:
              'board-token-hit-0-$i enabled must be $shouldBeEnabled '
              '(legal = [1, 3])',
        );
      }
    });

    testWidgets(
      'the Semantics tap action on a legal token moves exactly like a real '
      'tap',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        addTearDown(handle.dispose);

        final List<Map<String, Object?>> seats = <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: const <int>[3, 10, 20, 30]),
          _seatJson(1, name: 'Bob'),
        ];
        final (controller, transport) = await _connectTo(
          tester,
          seats: seats,
          turn: _awaitMoveTurn(legal: const <int>[2]),
        );
        addTearDown(controller.dispose);
        await _mount(tester, controller);

        final int sentBefore = transport.sentRaw.length;
        final SemanticsOwner owner =
            tester.binding.rootPipelineOwner.semanticsOwner!;
        final SemanticsNode node = tester.getSemantics(
          find.byKey(_hitKey(0, 2)),
        );
        owner.performAction(node.id, SemanticsAction.tap);
        await tester.pump();

        final List<String> newMessages = transport.sentRaw
            .skip(sentBefore)
            .toList();
        expect(newMessages, hasLength(1));
        expect(_typeOf(newMessages.single), 'move');
        expect(_dataOf(newMessages.single), <String, Object?>{'token': 2});
      },
    );
  });
}
