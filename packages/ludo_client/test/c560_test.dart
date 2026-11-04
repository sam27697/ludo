// Conformance tests for work/ludo/orders/C-560-time-up-stops-inviting-and-
// connecting-body.md, section "What the proofs measure" items 1-8, written from
// that spec alone. Order 560 implements in a tree this file's author has not
// read, so on a tree without it the cases that pin new behaviour are expected
// RED and the guards (stale beats time up, another seat's zero) GREEN.
//
// `gameYourTurnTimeUp` is the one symbol the spec adds that these cases name.
// Its text is read off AppLocalizations and pinned once per locale against the
// literal text from D1, so a wrong translation is caught. Everything else is
// asserted through Keys, the die's `enabled`, the board's `legal` set, frames
// read back off the fake transport and cues read back off an injected
// feedback service.
//
// "Zero" is not a sleep. Time is fake: a case pumps 100 ms at a time until the
// ring has swapped its digits for the hourglass (`game-screen-turn-timeup`),
// which is the screen's own statement that the countdown reads 0, and fails
// with the scenario if it never does. Nothing here uses pumpAndSettle: the
// hourglass, the lobby mark and the pulsing die turn for ever.
//
// Every reason line carries the scenario (seat, phase, deadline_ms, locale,
// frames sent) so a red case can be rebuilt by hand. The scenarios are plain
// frames, there is no random seed to record.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart' show LudoBoard;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_die.dart' show GameDie;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show buildAppTheme, kSpace6;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c560-test.invalid/ws';

const Key _bannerKey = Key('game-screen-turn-banner');
const Key _timeUpKey = Key('game-screen-turn-timeup');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _dieKey = Key('game-die');
const Key _facePickerKey = Key('board-face-picker');
const Key _lobbyConnectingKey = Key('lobby-connecting');
const Key _lobbyConnectingLineKey = Key('lobby-connecting-line');
const Key _lobbyCancelKey = Key('lobby-cancel-button');
const Key _markKey = Key('waiting-line-mark');
const Key _slowKey = Key('waiting-line-slow');

Key _hitKey(int token) => Key('board-token-hit-0-$token');
Key _ringKey(int token) => Key('board-legal-ring-0-$token');
Key _glowKey(int token) => Key('board-automove-glow-0-$token');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

// The two texts D1 fixes for gameYourTurnTimeUp.
const String _timeUpLineEn = 'Time is up. Playing for you.';
const String _timeUpLineAr = 'انتهى الوقت. نلعب عنك.';

String _timeUpLineFor(Locale l) =>
    l.languageCode == 'ar' ? _timeUpLineAr : _timeUpLineEn;

const List<int> _noTokens = <int>[-1, -1, -1, -1];

// --- frames and room snapshots, the sibling suites' idiom ---------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c560-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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
}) => jsonEncode(<String, Object?>{
  'v': 1,
  't': type,
  'id': _nextServerId(),
  're': ?re,
  'd': data,
});

Map<String, Object?> _seatJson(
  int seat, {
  required String name,
  List<int> tokens = _noTokens,
}) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': tokens,
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  required List<Map<String, Object?>> seats,
  required Map<String, Object?>? turn,
  String state = 'PLAYING',
  int seq = 1,
}) => <String, Object?>{
  'code': 'C560XX',
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': state == 'PLAYING' ? 'g1' : null,
  'client_seeds': state == 'PLAYING' ? '0:seed' : null,
  'seats': seats,
  'turn': turn,
  'winner': null,
  'seq': seq,
};

// --- turn fixtures -------------------------------------------------------------
// The wire shape of `turn` inside a room snapshot or a `turn` frame.

/// Seat [seat] to roll. Tokens on the table do not matter for a roll.
Map<String, Object?> _rollTurn({
  int seat = 0,
  required int deadlineMs,
  int k = 0,
}) => <String, Object?>{
  'seat': seat,
  'phase': 'await_roll',
  'deadline_ms': deadlineMs,
  'k': k,
};

/// Two legal tokens, 1 and 3, on one face (the seat is [_twoLegalTokens]).
Map<String, Object?> _twoLegalTurn({required int deadlineMs, int k = 1}) =>
    <String, Object?>{
      'seat': 0,
      'phase': 'await_move',
      'deadline_ms': deadlineMs,
      'k': k,
      'value': 4,
      'legal': const <int>[1, 3],
    };

const List<int> _twoLegalTokens = <int>[3, 10, 20, 30];

/// A roll queue [6, 4]: token 2 moves on either face, so a tap on it opens
/// the face picker (the seat is [_pickTokens]).
Map<String, Object?> _pickTurn({required int deadlineMs, int k = 2}) =>
    <String, Object?>{
      'seat': 0,
      'phase': 'await_move',
      'deadline_ms': deadlineMs,
      'k': k,
      'value': 6,
      'legal': const <int>[0, 2],
      'queue': const <int>[6, 4],
      'legal_by_face': const <Map<String, Object?>>[
        <String, Object?>{
          'face': 6,
          'tokens': <int>[0, 2],
        },
        <String, Object?>{
          'face': 4,
          'tokens': <int>[1, 2],
        },
      ],
    };

const List<int> _pickTokens = <int>[1, 3, 6, -1];

/// One legal token and one face: the C-417 hold arms on it (the seat is
/// [_soleTokens]).
Map<String, Object?> _soleTurn({required int deadlineMs, int k = 1}) =>
    <String, Object?>{
      'seat': 0,
      'phase': 'await_move',
      'deadline_ms': deadlineMs,
      'k': k,
      'value': 5,
      'legal': const <int>[0],
    };

const List<int> _soleTokens = <int>[3, -1, -1, -1];

// --- harness -------------------------------------------------------------------

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued for $url');
    }
    return _queue.removeAt(0);
  }
}

class _RecordingFeedback implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) => recorded.add(cue);
}

Widget _harness(
  Widget child, {
  Locale locale = _en,
  bool disableAnimations = false,
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
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: screen!,
      );
    },
    home: child,
  );
}

/// One mounted GameScreen over a real controller and a fake transport, with
/// everything a case reads off it.
class _Rig {
  _Rig({
    required this.tester,
    required this.controller,
    required this.transport,
    required this.feedback,
    required this.scenario,
    required this.locale,
  });

  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final _RecordingFeedback feedback;
  final String scenario;
  final Locale locale;
  int seq = 1;

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(GameScreen)));

  String get banner {
    final Finder f = find.byKey(_bannerKey);
    if (f.evaluate().isEmpty) {
      fail('game-screen-turn-banner is not on screen. Scenario: $scenario');
    }
    return tester.widget<Text>(f).data!;
  }

  GameDie get die => tester.widget<GameDie>(find.byType(GameDie));
  Set<int> get legal => tester.widget<LudoBoard>(find.byType(LudoBoard)).legal;

  bool get atTimeUp => find.byKey(_timeUpKey).evaluate().isNotEmpty;
  bool get pickerOpen => find.byKey(_facePickerKey).evaluate().isNotEmpty;

  List<Map<String, Object?>> sentOfType(String type) => <Map<String, Object?>>[
    for (final String raw in transport.sentRaw)
      if (_typeOf(raw) == type) _dataOf(raw),
  ];

  List<Map<String, Object?>> get moves => sentOfType('move');
  List<Map<String, Object?>> get rolls => sentOfType('roll');

  int cues(FeedbackCue cue) =>
      feedback.recorded.where((FeedbackCue c) => c == cue).length;

  /// What the screen shows now, for a failure line.
  String get seen {
    final bool bannerThere = find.byKey(_bannerKey).evaluate().isNotEmpty;
    final bool boardThere = find.byType(LudoBoard).evaluate().isNotEmpty;
    final bool dieThere = find.byType(GameDie).evaluate().isNotEmpty;
    return 'banner "${bannerThere ? banner : '<none>'}", '
        'die enabled ${dieThere ? die.enabled : '<none>'}, '
        'board legal ${boardThere ? legal : '<none>'}, '
        'hourglass $atTimeUp, picker open $pickerOpen, '
        'sent ${<String>[for (final String r in transport.sentRaw) _typeOf(r)]}, '
        'cues ${feedback.recorded}';
  }

  /// A reason line: the expectation, what is on screen, how to rebuild it.
  String why(String expected) => '$expected. Seen: $seen. Scenario: $scenario';

  /// A server push, stamped with the next sequence number and flushed with the
  /// two bare pumps one pump short of a frame needs.
  Future<void> push(String type, Map<String, Object?> data) async {
    seq += 1;
    transport.pushText(
      _frame(type: type, data: <String, Object?>{...data, 'seq': seq}),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Fake time in 100 ms steps, no settling.
  Future<void> pumpFor(int milliseconds) async {
    for (int t = 0; t < milliseconds; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pumps 100 ms at a time until the ring shows the hourglass: the
  /// countdown reads 0. Fails, with the scenario, if it never does.
  Future<void> pumpToTimeUp() async {
    for (int i = 0; i < 80 && !atTimeUp; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      atTimeUp,
      isTrue,
      reason: why(
        'fixture: the ring must reach the hourglass within 8 s of fake time',
      ),
    );
    expect(
      find.byKey(_countdownKey),
      findsNothing,
      reason: why('fixture: no digits once the hourglass is up'),
    );
  }

  Future<void> release() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  }
}

typedef _Body = Future<void> Function(_Rig rig);

/// Connects a controller (a create reply, or a resume reply with [resume]) onto
/// a two-seat PLAYING room, mounts GameScreen on a 390x844 phone and runs
/// [body]. The screen and the controller are released afterwards whatever
/// [body] did.
Future<void> _run(
  WidgetTester tester, {
  required String scenario,
  required Map<String, Object?> turn,
  List<int> mine = _noTokens,
  int mySeat = 0,
  Locale locale = _en,
  bool resume = false,
  required _Body body,
}) async {
  final String full =
      'seat $mySeat of 2, ${resume ? 'resume' : 'create'} reply, '
      'locale ${locale.languageCode}, $scenario, '
      'turn ${jsonEncode(turn)}, my tokens $mine';
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
  final Future<void> future = resume
      ? controller.resumeRoom(
          code: 'C560XX',
          seat: mySeat,
          seatToken: 'tok-$mySeat',
        )
      : controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        seats: <Map<String, Object?>>[
          _seatJson(0, name: 'Sam', tokens: mySeat == 0 ? mine : _noTokens),
          _seatJson(1, name: 'Bob', tokens: mySeat == 1 ? mine : _noTokens),
        ],
        turn: turn,
      ),
    ),
  );
  await future;

  final _RecordingFeedback feedback = _RecordingFeedback();
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _harness(
      FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: feedback,
        child: GameScreen(controller: controller),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump();

  final _Rig rig = _Rig(
    tester: tester,
    controller: controller,
    transport: transport,
    feedback: feedback,
    scenario: full,
    locale: locale,
  );
  try {
    await body(rig);
  } finally {
    await rig.release();
  }
}

/// The banner is the time-up line, read off AppLocalizations and against the
/// literal text D1 fixes.
void _expectTimeUpBanner(_Rig rig, String where) {
  final String fromLoc = rig.loc.gameYourTurnTimeUp;
  expect(
    rig.banner,
    fromLoc,
    reason: rig.why(
      'D1: $where, the turn banner must read gameYourTurnTimeUp "$fromLoc"',
    ),
  );
  expect(
    fromLoc,
    _timeUpLineFor(rig.locale),
    reason: rig.why(
      'D1: gameYourTurnTimeUp in ${rig.locale.languageCode} must be '
      '"${_timeUpLineFor(rig.locale)}"',
    ),
  );
}

void main() {
  // ===========================================================================
  // 1. awaitRoll at my zero: the banner, the die, a tap on the die.
  // ===========================================================================
  group('C-560 1: awaitRoll at my zero', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;
      const String shape = 'await_roll, deadline_ms 2000, pumped to zero';

      testWidgets(
        'C-560 1: $lang: the banner reads the time-up line, not the roll line',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario: shape,
            turn: _rollTurn(deadlineMs: 2000),
            locale: locale,
            body: (_Rig rig) async {
              expect(
                rig.banner,
                rig.loc.gameYourTurnRoll,
                reason: rig.why(
                  'fixture: above zero the banner is the roll line',
                ),
              );
              await rig.pumpToTimeUp();
              _expectTimeUpBanner(rig, 'awaitRoll at zero');
              expect(
                rig.banner,
                isNot(rig.loc.gameYourTurnRoll),
                reason: rig.why('D1: the roll line must be gone at zero'),
              );
            },
          );
        },
      );

      testWidgets('C-560 1: $lang: the die is not enabled at zero', (
        WidgetTester tester,
      ) async {
        await _run(
          tester,
          scenario: shape,
          turn: _rollTurn(deadlineMs: 2000),
          locale: locale,
          body: (_Rig rig) async {
            expect(
              rig.die.enabled,
              isTrue,
              reason: rig.why('fixture: above zero the die is enabled'),
            );
            await rig.pumpToTimeUp();
            expect(
              rig.die.enabled,
              isFalse,
              reason: rig.why('D2: GameDie.enabled must be false at my zero'),
            );
          },
        );
      });

      testWidgets(
        'C-560 1: $lang: a tap on the die at zero sends no roll and plays '
        'invalidTap once',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario: shape,
            turn: _rollTurn(deadlineMs: 2000),
            locale: locale,
            body: (_Rig rig) async {
              await rig.pumpToTimeUp();
              final int invalidBefore = rig.cues(FeedbackCue.invalidTap);
              final int rollsBefore = rig.rolls.length;
              await tester.tap(find.byKey(_dieKey));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(
                rig.rolls.length - rollsBefore,
                0,
                reason: rig.why(
                  'D2: a tap on the die at zero must send no roll',
                ),
              );
              expect(
                rig.cues(FeedbackCue.invalidTap) - invalidBefore,
                1,
                reason: rig.why(
                  'D2: a tap on the die at zero must play FeedbackCue.invalidTap '
                  'exactly once',
                ),
              );
            },
          );
        },
      );

      testWidgets(
        'C-560 1: $lang: awaitMove at zero reads the time-up line too',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario: 'await_move two legal tokens, deadline_ms 2000, to zero',
            turn: _twoLegalTurn(deadlineMs: 2000),
            mine: _twoLegalTokens,
            locale: locale,
            body: (_Rig rig) async {
              expect(
                rig.banner,
                rig.loc.gameYourTurnMove,
                reason: rig.why(
                  'fixture: above zero the banner is the move line',
                ),
              );
              await rig.pumpToTimeUp();
              _expectTimeUpBanner(rig, 'awaitMove at zero');
            },
          );
        },
      );
    }
  });

  // ===========================================================================
  // 2. awaitMove at my zero: the board's legal set and a token tap.
  // ===========================================================================
  group('C-560 2: awaitMove at my zero', () {
    const String shape = 'await_move, tokens 1 and 3 legal, deadline_ms 2000';

    testWidgets(
      'C-560 2: the board is handed an empty legal set and draws no ring',
      (WidgetTester tester) async {
        await _run(
          tester,
          scenario: shape,
          turn: _twoLegalTurn(deadlineMs: 2000),
          mine: _twoLegalTokens,
          body: (_Rig rig) async {
            expect(rig.legal, <int>{
              1,
              3,
            }, reason: rig.why('fixture: above zero the legal set is {1, 3}'));
            expect(
              find.byKey(_ringKey(1)),
              findsOneWidget,
              reason: rig.why('fixture: above zero token 1 wears a ring'),
            );
            await rig.pumpToTimeUp();
            expect(
              rig.legal,
              isEmpty,
              reason: rig.why('D3: LudoBoard.legal must be empty at my zero'),
            );
            expect(
              <bool>[
                find.byKey(_ringKey(1)).evaluate().isNotEmpty,
                find.byKey(_ringKey(3)).evaluate().isNotEmpty,
              ],
              <bool>[false, false],
              reason: rig.why('D3: no token may draw a ring at my zero'),
            );
          },
        );
      },
    );

    testWidgets(
      'C-560 2: a tap on a token that was legal sends no move and plays what '
      'a tap on an unmovable token plays',
      (WidgetTester tester) async {
        await _run(
          tester,
          scenario: shape,
          turn: _twoLegalTurn(deadlineMs: 2000),
          mine: _twoLegalTokens,
          body: (_Rig rig) async {
            await rig.pumpToTimeUp();
            // Token 2 was never legal: the control for "what a tap on an
            // unmovable token does today".
            final int before = rig.feedback.recorded.length;
            await tester.tap(find.byKey(_hitKey(2)), warnIfMissed: false);
            await tester.pump();
            final List<FeedbackCue> unmovable = rig.feedback.recorded
                .skip(before)
                .toList();
            for (final int token in <int>[1, 3]) {
              final int mark = rig.feedback.recorded.length;
              await tester.tap(find.byKey(_hitKey(token)), warnIfMissed: false);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(
                rig.moves,
                isEmpty,
                reason: rig.why(
                  'D3: a tap on token $token (legal before zero) must put no '
                  'move on the transport',
                ),
              );
              expect(
                rig.feedback.recorded.skip(mark).toList(),
                unmovable,
                reason: rig.why(
                  'D3: a tap on token $token at zero must do what a tap on '
                  'the unmovable token 2 does: cues $unmovable',
                ),
              );
            }
          },
        );
      },
    );
  });

  // ===========================================================================
  // 3. The face picker closes at zero and stays shut.
  // ===========================================================================
  group('C-560 3: the face picker', () {
    const String shape =
        'await_move, roll queue [6, 4], token 2 on both faces, '
        'deadline_ms 2000';

    Future<void> openPicker(_Rig rig) async {
      await rig.tester.tap(find.byKey(_hitKey(2)), warnIfMissed: false);
      await rig.tester.pump();
      for (int i = 0; i < 14; i++) {
        await rig.tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        rig.pickerOpen,
        isTrue,
        reason: rig.why(
          'fixture: a tap on token 2 above zero opens the picker',
        ),
      );
    }

    testWidgets('C-560 3: an open picker closes at zero', (
      WidgetTester tester,
    ) async {
      await _run(
        tester,
        scenario: shape,
        turn: _pickTurn(deadlineMs: 2000),
        mine: _pickTokens,
        body: (_Rig rig) async {
          await openPicker(rig);
          await rig.pumpToTimeUp();
          // Past the picker's own close motion.
          await rig.pumpFor(300);
          expect(
            rig.pickerOpen,
            isFalse,
            reason: rig.why('D3: the face picker must be closed at my zero'),
          );
          expect(
            rig.moves,
            isEmpty,
            reason: rig.why('D3: closing the picker must send no move'),
          );
        },
      );
    });

    Future<void> tapTokenTwoAndLook(_Rig rig) async {
      await rig.tester.tap(find.byKey(_hitKey(2)), warnIfMissed: false);
      await rig.tester.pump();
      for (int i = 0; i < 14; i++) {
        await rig.tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('C-560 3: a picker closed at zero is not reopened by a tap', (
      WidgetTester tester,
    ) async {
      await _run(
        tester,
        scenario: shape,
        turn: _pickTurn(deadlineMs: 2000),
        mine: _pickTokens,
        body: (_Rig rig) async {
          await openPicker(rig);
          await rig.pumpToTimeUp();
          await rig.pumpFor(300);
          expect(
            rig.pickerOpen,
            isFalse,
            reason: rig.why('D3: the picker must be closed at my zero'),
          );
          await tapTokenTwoAndLook(rig);
          expect(
            rig.pickerOpen,
            isFalse,
            reason: rig.why(
              'D3: a tap on token 2 after the picker closed at zero must not '
              'reopen it',
            ),
          );
          expect(
            rig.moves,
            isEmpty,
            reason: rig.why('D3: a tap on token 2 at zero must send no move'),
          );
        },
      );
    });

    testWidgets('C-560 3: at zero a tap on token 2 opens no picker', (
      WidgetTester tester,
    ) async {
      await _run(
        tester,
        scenario: shape,
        turn: _pickTurn(deadlineMs: 2000),
        mine: _pickTokens,
        body: (_Rig rig) async {
          expect(
            rig.pickerOpen,
            isFalse,
            reason: rig.why('fixture: no picker before the first tap'),
          );
          await rig.pumpToTimeUp();
          await tapTokenTwoAndLook(rig);
          expect(
            rig.pickerOpen,
            isFalse,
            reason: rig.why(
              'D3: a tap on token 2 at my zero must not open the picker',
            ),
          );
          expect(
            rig.moves,
            isEmpty,
            reason: rig.why('D3: a tap on token 2 at zero must send no move'),
          );
        },
      );
    });
  });

  // ===========================================================================
  // 4. A resume into an overdue awaitMove: the hold never sends.
  // ===========================================================================
  group('C-560 4: resume into an overdue awaitMove with one legal token', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;
      testWidgets(
        'C-560 4: $lang: no move in 3 s of fake time, no glow, the banner is '
        'the time-up line and never the auto-move line',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario: 'await_move one legal token, deadline_ms 0, 3 s pumped',
            turn: _soleTurn(deadlineMs: 0),
            mine: _soleTokens,
            locale: locale,
            resume: true,
            body: (_Rig rig) async {
              await tester.pump(const Duration(milliseconds: 50));
              expect(
                rig.atTimeUp,
                isTrue,
                reason: rig.why('fixture: deadline_ms 0 shows the hourglass'),
              );
              final String autoLine = rig.loc.gameAutoMoving;
              for (int elapsed = 50; elapsed <= 3050; elapsed += 100) {
                expect(
                  rig.moves,
                  isEmpty,
                  reason: rig.why(
                    'D3: no move may leave the client; one was sent by '
                    '+$elapsed ms',
                  ),
                );
                expect(
                  rig.banner,
                  isNot(autoLine),
                  reason: rig.why(
                    'D1: the banner must not be gameAutoMoving "$autoLine" at '
                    '+$elapsed ms',
                  ),
                );
                _expectTimeUpBanner(rig, 'resume at +$elapsed ms');
                expect(
                  find.byKey(_glowKey(0)),
                  findsNothing,
                  reason: rig.why(
                    'D3: the hold glow must be gone at +$elapsed ms',
                  ),
                );
                await tester.pump(const Duration(milliseconds: 100));
              }
              expect(
                rig.moves,
                isEmpty,
                reason: rig.why('D3: no move in the 3 s after the resume'),
              );
            },
          );
        },
      );
    }
  });

  // ===========================================================================
  // 5. Recovery: a fresh frame gives the table back.
  // ===========================================================================
  group('C-560 5: recovery after time up', () {
    testWidgets(
      'C-560 5: awaitRoll, then a turn frame for my seat with a fresh '
      'deadline: the roll banner and an enabled die',
      (WidgetTester tester) async {
        await _run(
          tester,
          scenario:
              'await_roll deadline_ms 2000 to zero, then turn seat 0 '
              'await_roll deadline_ms 45000',
          turn: _rollTurn(deadlineMs: 2000),
          body: (_Rig rig) async {
            await rig.pumpToTimeUp();
            _expectTimeUpBanner(rig, 'before the fresh frame');
            await rig.push('turn', _rollTurn(deadlineMs: 45000)..remove('k'));
            expect(
              rig.banner,
              rig.loc.gameYourTurnRoll,
              reason: rig.why(
                'D1: a fresh deadline ends my time up; the banner must read '
                'gameYourTurnRoll',
              ),
            );
            expect(
              rig.die.enabled,
              isTrue,
              reason: rig.why('D2: the die must be enabled again'),
            );
            expect(
              rig.atTimeUp,
              isFalse,
              reason: rig.why('the hourglass must give way to the digits'),
            );
          },
        );
      },
    );

    testWidgets(
      'C-560 5: awaitMove, then a turn frame for my seat with a fresh '
      'deadline: the move banner and the legal set back',
      (WidgetTester tester) async {
        await _run(
          tester,
          scenario:
              'await_move tokens 1 and 3 deadline_ms 2000 to zero, then '
              'turn seat 0 await_move deadline_ms 45000',
          turn: _twoLegalTurn(deadlineMs: 2000),
          mine: _twoLegalTokens,
          body: (_Rig rig) async {
            await rig.pumpToTimeUp();
            _expectTimeUpBanner(rig, 'before the fresh frame');
            expect(
              rig.legal,
              isEmpty,
              reason: rig.why('D3: the legal set is empty at zero'),
            );
            await rig.push(
              'turn',
              _twoLegalTurn(deadlineMs: 45000)..remove('k'),
            );
            expect(
              rig.banner,
              rig.loc.gameYourTurnMove,
              reason: rig.why(
                'D1: a fresh deadline ends my time up; the banner must read '
                'gameYourTurnMove',
              ),
            );
            expect(
              rig.legal,
              <int>{1, 3},
              reason: rig.why(
                'D3: the legal set must come back with the frame',
              ),
            );
            expect(
              find.byKey(_ringKey(1)),
              findsOneWidget,
              reason: rig.why('D3: token 1 wears its ring again'),
            );
          },
        );
      },
    );

    testWidgets(
      'C-560 5: a turn frame for the other seat gives the waiting line',
      (WidgetTester tester) async {
        await _run(
          tester,
          scenario:
              'await_roll deadline_ms 2000 to zero, then turn seat 1 '
              'await_roll deadline_ms 45000',
          turn: _rollTurn(deadlineMs: 2000),
          body: (_Rig rig) async {
            await rig.pumpToTimeUp();
            _expectTimeUpBanner(rig, 'before the fresh frame');
            await rig.push(
              'turn',
              _rollTurn(seat: 1, deadlineMs: 45000)..remove('k'),
            );
            expect(
              rig.banner,
              rig.loc.gameWaitingForPlayer('Bob'),
              reason: rig.why(
                'D1: once the turn is not mine the banner is the waiting line',
              ),
            );
            expect(
              rig.die.enabled,
              isFalse,
              reason: rig.why('the die is not enabled on another seat\'s turn'),
            );
          },
        );
      },
    );

    testWidgets(
      'C-560 5: a replayed turn frame (same seat, deadline_ms, k) does not end time up',
      (WidgetTester tester) async {
        await _run(
          tester,
          scenario:
              'await_roll deadline_ms 2000 to zero, then the same '
              'turn frame again (same seat, deadline_ms and k)',
          turn: _rollTurn(deadlineMs: 2000),
          body: (_Rig rig) async {
            await rig.pumpToTimeUp();
            await rig.push('turn', _rollTurn(deadlineMs: 2000)..remove('k'));
            _expectTimeUpBanner(rig, 'after a replay of the same turn');
            expect(
              rig.die.enabled,
              isFalse,
              reason: rig.why(
                'D2: a frame that leaves (seat, deadlineMs, k) unchanged must '
                'not re-arm the countdown nor enable the die',
              ),
            );
          },
        );
      },
    );
  });

  // ===========================================================================
  // 6. Stale beats time up.
  // ===========================================================================
  group('C-560 6: a dropped socket beats time up', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;

      testWidgets(
        'C-560 6: $lang: awaitRoll, the socket drops at zero: gameYourTurnStale',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario: 'await_roll deadline_ms 2000, socket ends at zero',
            turn: _rollTurn(deadlineMs: 2000),
            locale: locale,
            body: (_Rig rig) async {
              await rig.pumpToTimeUp();
              rig.transport.endFromFarSide();
              await tester.pump();
              await tester.pump();
              expect(
                rig.controller.phase,
                isNot(RoomPhase.connected),
                reason: rig.why(
                  'fixture: the far side vanishing ends the link',
                ),
              );
              expect(
                rig.banner,
                rig.loc.gameYourTurnStale,
                reason: rig.why(
                  'D1: a stale table beats time up; the banner must read '
                  'gameYourTurnStale',
                ),
              );
            },
          );
        },
      );

      testWidgets(
        'C-560 6: $lang: awaitMove, the socket drops first and the clock runs '
        'out under it: gameYourTurnStale at every step',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario:
                'await_move tokens 1 and 3 deadline_ms 2000, socket '
                'ends at +0, 2.5 s pumped',
            turn: _twoLegalTurn(deadlineMs: 2000),
            mine: _twoLegalTokens,
            locale: locale,
            body: (_Rig rig) async {
              rig.transport.endFromFarSide();
              await tester.pump();
              await tester.pump();
              expect(
                rig.controller.phase,
                isNot(RoomPhase.connected),
                reason: rig.why(
                  'fixture: the far side vanishing ends the link',
                ),
              );
              for (int elapsed = 0; elapsed <= 2500; elapsed += 100) {
                expect(
                  rig.banner,
                  rig.loc.gameYourTurnStale,
                  reason: rig.why(
                    'D1: the banner must stay gameYourTurnStale at '
                    '+$elapsed ms, before and after the clock reads 0',
                  ),
                );
                await tester.pump(const Duration(milliseconds: 100));
              }
            },
          );
        },
      );
    }
  });

  // ===========================================================================
  // 7. Another seat's zero changes nothing.
  // ===========================================================================
  group('C-560 7: another seat\'s zero', () {
    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;
      testWidgets(
        'C-560 7: $lang: the banner keeps the waiting line, the board and the '
        'die are unchanged',
        (WidgetTester tester) async {
          await _run(
            tester,
            scenario: 'seat 1 await_roll deadline_ms 2000, pumped to zero',
            turn: _rollTurn(seat: 1, deadlineMs: 2000),
            mine: _twoLegalTokens,
            locale: locale,
            body: (_Rig rig) async {
              final String waiting = rig.loc.gameWaitingForPlayer('Bob');
              final String bannerBefore = rig.banner;
              final bool enabledBefore = rig.die.enabled;
              final int? faceBefore = rig.die.face;
              final Set<int> legalBefore = rig.legal;
              expect(
                bannerBefore,
                waiting,
                reason: rig.why('fixture: seat 1 holds the turn, banner waits'),
              );
              await rig.pumpToTimeUp();
              expect(
                rig.banner,
                waiting,
                reason: rig.why(
                  'D1: another seat\'s zero keeps the waiting line',
                ),
              );
              expect(
                <Object?>[rig.die.enabled, rig.die.face, rig.legal],
                <Object?>[enabledBefore, faceBefore, legalBefore],
                reason: rig.why(
                  'the die (enabled, face) and the board legal set must be '
                  'what they were before the other seat\'s zero',
                ),
              );
              final int invalidBefore = rig.cues(FeedbackCue.invalidTap);
              await tester.tap(find.byKey(_dieKey));
              await tester.pump();
              expect(
                <Object?>[rig.rolls.length, rig.cues(FeedbackCue.invalidTap)],
                <Object?>[0, invalidBefore + 1],
                reason: rig.why(
                  'a tap on the die on another seat\'s turn sends no roll and '
                  'plays invalidTap once, as it did before their zero',
                ),
              );
            },
          );
        },
      );
    }
  });

  // ===========================================================================
  // 8. The lobby connecting body.
  // ===========================================================================
  group('C-560 8: the lobby connecting body', () {
    Future<RoomController> mount(
      WidgetTester tester, {
      required Locale locale,
      bool disableAnimations = false,
    }) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final _Connector connector = _Connector();
      connector.enqueue(FakeTransport());
      final RoomController controller = RoomController(
        serverUrl: Uri.parse(_testUrl),
        connect: connector.call,
        autoReconnectDelays: const <Duration>[],
      );
      await tester.pumpWidget(
        _harness(
          LobbyScreen(
            controller: controller,
            action: LobbyAction.create,
            playerName: 'Sam',
            players: 2,
          ),
          locale: locale,
          disableAnimations: disableAnimations,
          textScale: 2.0,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        tester.getSize(find.byType(Scaffold)),
        const Size(360, 640),
        reason: 'fixture: the lobby must lay out on a 360x640 surface',
      );
      expect(
        find.byKey(_lobbyConnectingKey),
        findsOneWidget,
        reason: 'fixture: an unanswered create must show lobby-connecting',
      );
      return controller;
    }

    Future<void> release(WidgetTester tester, RoomController controller) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.dispose();
    }

    AppLocalizations locOf(WidgetTester tester) =>
        AppLocalizations.of(tester.element(find.byType(LobbyScreen)));

    for (final Locale locale in <Locale>[_en, _ar]) {
      final String lang = locale.languageCode;
      final String scenario =
          'LobbyScreen create, unanswered, 360x640, text scale 2.0, '
          'locale $lang';

      testWidgets(
        'C-560 8: $lang: the line is at least kSpace6 from both screen edges',
        (WidgetTester tester) async {
          final RoomController controller = await mount(tester, locale: locale);
          try {
            final AppLocalizations loc = locOf(tester);
            final Finder text = find.descendant(
              of: find.byKey(_lobbyConnectingLineKey),
              matching: find.text(loc.lobbyConnecting),
            );
            expect(
              text,
              findsOneWidget,
              reason:
                  'D4: lobby-connecting-line must hold "${loc.lobbyConnecting}". '
                  'Scenario: $scenario',
            );
            final Rect rect = tester.getRect(text);
            expect(
              rect.left,
              greaterThanOrEqualTo(kSpace6),
              reason:
                  'D4: the line\'s Text must start at least $kSpace6 from the '
                  'left edge; it spans $rect. Scenario: $scenario',
            );
            expect(
              360 - rect.right,
              greaterThanOrEqualTo(kSpace6),
              reason:
                  'D4: the line\'s Text must end at least $kSpace6 from the '
                  'right edge; it spans $rect. Scenario: $scenario',
            );
          } finally {
            await release(tester, controller);
          }
        },
      );

      testWidgets('C-560 8: $lang: no CircularProgressIndicator, exactly one '
          'waiting-line-mark, Cancel and the slow line stay', (
        WidgetTester tester,
      ) async {
        final RoomController controller = await mount(tester, locale: locale);
        try {
          Finder under(Finder matching) => find.descendant(
            of: find.byKey(_lobbyConnectingKey),
            matching: matching,
          );
          expect(
            under(find.byType(CircularProgressIndicator)),
            findsNothing,
            reason:
                'D4: the spinner must be gone from lobby-connecting. '
                'Scenario: $scenario',
          );
          expect(
            under(find.byKey(_markKey)),
            findsOneWidget,
            reason:
                'D4: lobby-connecting-line must draw exactly one '
                'waiting-line-mark; found '
                '${under(find.byKey(_markKey)).evaluate().length}. '
                'Scenario: $scenario',
          );
          expect(
            find.descendant(
              of: find.byKey(_lobbyConnectingLineKey),
              matching: find.byKey(_markKey),
            ),
            findsOneWidget,
            reason:
                'D4: the mark must be the WaitingLine\'s own. '
                'Scenario: $scenario',
          );
          expect(
            find.byKey(_lobbyCancelKey),
            findsOneWidget,
            reason: 'D4: lobby-cancel-button stays. Scenario: $scenario',
          );
          expect(
            find.byKey(_slowKey),
            findsNothing,
            reason: 'fixture: no slow line before 4 s. Scenario: $scenario',
          );
          await tester.pump(const Duration(milliseconds: 4100));
          expect(
            find.byKey(_slowKey),
            findsOneWidget,
            reason:
                'D4: the slow second line must still appear after 4 s. '
                'Scenario: $scenario',
          );
          expect(
            under(find.byKey(_markKey)),
            findsOneWidget,
            reason:
                'D4: still exactly one mark after the slow line. '
                'Scenario: $scenario',
          );
        } finally {
          await release(tester, controller);
        }
      });

      testWidgets('C-560 8: $lang: with animations the mark turns', (
        WidgetTester tester,
      ) async {
        final RoomController controller = await mount(tester, locale: locale);
        try {
          final Finder mark = find.byKey(_markKey);
          expect(
            mark,
            findsOneWidget,
            reason: 'D4: one mark must be on screen. Scenario: $scenario',
          );
          final RotationTransition turning = tester.widget<RotationTransition>(
            mark,
          );
          final double a = turning.turns.value;
          await tester.pump(const Duration(milliseconds: 300));
          final double b = tester.widget<RotationTransition>(mark).turns.value;
          expect(
            a == b,
            isFalse,
            reason:
                'D4: the mark must turn with animations on; turns stayed '
                '$a after 300 ms. Scenario: $scenario',
          );
        } finally {
          await release(tester, controller);
        }
      });

      testWidgets(
        'C-560 8: $lang: with disableAnimations the mark is still, a full '
        '18 sync icon',
        (WidgetTester tester) async {
          final RoomController controller = await mount(
            tester,
            locale: locale,
            disableAnimations: true,
          );
          try {
            final Finder mark = find.byKey(_markKey);
            expect(
              mark,
              findsOneWidget,
              reason:
                  'D4: the mark must be drawn under removed animations too. '
                  'Scenario: $scenario',
            );
            expect(
              tester.widget<RotationTransition>(mark).turns.value,
              0,
              reason: 'D4: turns must be 0 at mount. Scenario: $scenario',
            );
            await tester.pump(const Duration(milliseconds: 600));
            expect(
              tester.widget<RotationTransition>(mark).turns.value,
              0,
              reason:
                  'D4: turns must stay 0 under disableAnimations. '
                  'Scenario: $scenario',
            );
            final Finder icon = find.descendant(
              of: mark,
              matching: find.byIcon(Icons.sync_rounded),
            );
            expect(
              icon,
              findsOneWidget,
              reason:
                  'D4: the mark is Icons.sync_rounded, the same mark every '
                  'other wait line uses. Scenario: $scenario',
            );
            expect(
              tester.widget<Icon>(icon).size,
              18,
              reason: 'D4: the Icon\'s size must be 18. Scenario: $scenario',
            );
            expect(
              tester.getSize(icon),
              const Size(18, 18),
              reason:
                  'D4: the mark must draw at 18 x 18, not a shrunken arc. '
                  'Scenario: $scenario',
            );
            expect(
              find.descendant(
                of: find.byKey(_lobbyConnectingKey),
                matching: find.byType(CircularProgressIndicator),
              ),
              findsNothing,
              reason:
                  'D4: no frozen spinner arc under removed animations. '
                  'Scenario: $scenario',
            );
          } finally {
            await release(tester, controller);
          }
        },
      );
    }
  });
}
