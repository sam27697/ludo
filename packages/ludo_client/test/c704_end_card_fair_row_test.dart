// C-704t: the fair game state in the end card's fairness row, driven through
// a real GameScreen over a real RoomController on a FakeTransport, with the
// check's source supplied through `debugFairSourceOverride` (the one seam
// for the tests; reset in tearDown).
//
// States are asserted by key and never by text: the row lays out
// endFairLine, endFairGame and endFairGameFailed invisibly under the live
// one, so find.text matches in every state. The keys are end-fair-checking,
// end-fair-unavailable, end-fair-ok and end-fair-failed.
//
// Transcripts are real: DiceChain.build for the chain, drawDie for each face,
// the chain's own commit. A tampered transcript changes one reveal or one
// value of that real one. The wire fixtures (connector, frames, room JSON)
// are copied from test/end_card_test.dart and test/rematch_client_test.dart,
// not imported, as this suite does.
//
// Waiting is on conditions: a bounded loop of short pumps until the wanted
// key is the only state key on screen. No sleeps, no pumpAndSettle.

import 'dart:async';
import 'dart:convert';

import 'package:fair_dice/fair_dice.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/code_ban_notice.dart' show RefusalNoticeMark;
import 'package:ludo_client/src/fair_check.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/frame.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart' show LudoColors;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c704-fair-row.invalid/ws';
const String _seeds = 'sam-seed,bob-seed';
const String _gameOne = 'c704-game-one';
const String _gameTwo = 'c704-game-two';

const Key _checking = Key('end-fair-checking');
const Key _unavailable = Key('end-fair-unavailable');
const Key _ok = Key('end-fair-ok');
const Key _failed = Key('end-fair-failed');
const List<Key> _stateKeys = <Key>[_checking, _unavailable, _ok, _failed];
const Key _hintKey = Key('end-card-fair-hint');
const Key _verifyKey = Key('game-screen-verify-button');
const Key _rematchKey = Key('end-card-rematch');
const Key _winKey = Key('end-card-win');
const Key _loseKey = Key('end-card-lose');

// --- wire fixtures -----------------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c704-srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

String _frameText({
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

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': const <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  String state = 'PLAYING',
  int chainIndex = 0,
  Map<String, Object?>? rematch,
  required int seq,
}) => <String, Object?>{
  'code': 'K7M2QP',
  'state': state,
  'host_seat': 0,
  'players': 2,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': (chainIndex.isEven ? 'a' : 'b') * 64,
  'chain_index': chainIndex,
  'game_id': null,
  'client_seeds': null,
  'seats': <Map<String, Object?>>[_seatJson(0, 'Sam'), _seatJson(1, 'Bob')],
  'turn': null,
  'winner': null,
  'rematch': rematch,
  'seq': seq,
};

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

class _FakeFeedbackService implements FeedbackService {
  final List<FeedbackCue> recorded = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) => recorded.add(cue);
}

/// A scripted game over the fake transport. Every push carries the next
/// contiguous seq, so the controller never opens a resync request.
class _Script {
  _Script(this.tester, this.transport);

  final WidgetTester tester;
  final FakeTransport transport;
  int seq = 1;

  Future<void> push(String type, Map<String, Object?> data) async {
    seq += 1;
    transport.pushText(
      _frameText(type: type, data: <String, Object?>{...data, 'seq': seq}),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> room(Map<String, Object?> Function(int seq) build) async {
    seq += 1;
    transport.pushText(_frameText(type: 'room', data: build(seq)));
    await tester.pump();
    await tester.pump();
  }

  /// One short game: started, one roll, one move, game_over. [winner] 0 is
  /// the viewing seat (win card), 1 is the other seat (lose card).
  Future<void> play({required String gameId, required int winner}) async {
    await push('game_started', <String, Object?>{
      'turn': winner,
      'game_id': gameId,
      'client_seeds': _seeds,
    });
    await push('turn', <String, Object?>{'seat': winner, 'deadline_ms': 45000});
    await push('rolled', <String, Object?>{
      'seat': winner,
      'value': 4,
      'legal': const <int>[0, 1, 2, 3],
      'deadline_ms': 45000,
      'k': 1,
      'reveal': 'a' * 64,
    });
    await push('moved', <String, Object?>{
      'seat': winner,
      'token': 0,
      'from': -1,
      'to': 4,
      'captured': const <Map<String, Object?>>[],
      'extra_roll': false,
    });
    await push('game_over', <String, Object?>{
      'winner': winner,
      'verify_url': 'https://c704-fair-row.invalid/verify/$gameId',
    });
    await _pumpPastHold(tester);
  }
}

Future<void> _pumpPastHold(WidgetTester tester) async {
  Duration remaining = kEndCardHoldLimit;
  const Duration chunk = Duration(milliseconds: 250);
  while (remaining > Duration.zero) {
    final Duration step = remaining > chunk ? chunk : remaining;
    await tester.pump(step);
    remaining -= step;
  }
}

// --- real transcripts --------------------------------------------------------

int _frameIdSeq = 0;
Frame _wire(String type, Map<String, Object?> data) {
  _frameIdSeq += 1;
  return Frame(
    type: type,
    id: 'c704-wire-${_frameIdSeq.toString().padLeft(6, '0')}',
    data: data,
  );
}

class _Real {
  _Real(this.gameId, {int tag = 1})
    : chain = DiceChain.build(
        List<int>.generate(32, (int i) => (i * 11 + tag * 17 + 5) & 0xff),
        chainLength: 32,
      );

  final String gameId;
  final int rolls = 6;
  final DiceChain chain;

  String get commit => chain.commit;

  /// [badValueAt] changes that roll's face; [badRevealAt] swaps that roll's
  /// reveal for another chain's link.
  List<Frame> frames({int? badValueAt, int? badRevealAt}) {
    final DiceChain other = DiceChain.build(
      List<int>.filled(32, 9),
      chainLength: 32,
    );
    final List<Frame> out = <Frame>[
      _wire('game_started', <String, Object?>{
        'turn': 0,
        'game_id': gameId,
        'client_seeds': _seeds,
      }),
    ];
    for (int k = 1; k <= rolls; k++) {
      final String reveal = chain.reveal(k);
      final int face = drawDie(reveal, gameId, _seeds, k, 0);
      out.add(
        _wire('rolled', <String, Object?>{
          'seat': 0,
          'value': k == badValueAt ? (face % 6) + 1 : face,
          'legal': const <int>[0, 1, 2, 3],
          'k': k,
          'reveal': k == badRevealAt ? other.reveal(k) : reveal,
        }),
      );
    }
    out.add(_wire('game_over', <String, Object?>{'winner': 0}));
    return out;
  }
}

/// The loader behind one game's source: every call is recorded and answered
/// by the test, so the check never finishes until the test says so.
class _Loader {
  final List<Completer<List<Frame>>> pending = <Completer<List<Frame>>>[];

  int get calls => pending.length;

  Future<List<Frame>> call() {
    final Completer<List<Frame>> c = Completer<List<Frame>>();
    pending.add(c);
    return c.future;
  }

  void answer(int index, List<Frame> frames) => pending[index].complete(frames);

  void fail(int index) =>
      pending[index].completeError(Exception('c704 test: offline'));
}

enum _Want { checking, unavailable, ok, failed }

Key _keyOf(_Want want) => switch (want) {
  _Want.checking => _checking,
  _Want.unavailable => _unavailable,
  _Want.ok => _ok,
  _Want.failed => _failed,
};

// --- the scenario ------------------------------------------------------------

class _Scene {
  _Scene({
    required this.tester,
    required this.controller,
    required this.transport,
    required this.script,
    required this.feedback,
    required this.loaders,
    required this.reals,
    required this.sources,
  });

  final WidgetTester tester;
  final RoomController controller;
  final FakeTransport transport;
  final _Script script;
  final _FakeFeedbackService feedback;
  final Map<String, _Loader> loaders;
  final Map<String, _Real> reals;

  /// Game ids the seam was asked about, in order.
  final List<String> sources;

  _Loader loader(String gameId) => loaders[gameId]!;
  _Real real(String gameId) => reals[gameId]!;
}

List<String> _printed = <String>[];

Future<_Scene> _scene(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  Size size = const Size(390, 844),
  double textScale = 1.0,
  bool withSeam = true,
  List<String> games = const <String>[_gameOne],
}) async {
  final Map<String, _Loader> loaders = <String, _Loader>{
    for (final String g in games) g: _Loader(),
  };
  final Map<String, _Real> reals = <String, _Real>{
    for (int i = 0; i < games.length; i++)
      games[i]: _Real(games[i], tag: i + 1),
  };
  final List<String> asked = <String>[];
  if (withSeam) {
    debugFairSourceOverride = (String gameId, String chainCommit) {
      asked.add(gameId);
      final _Real? real = reals[gameId];
      if (real == null) {
        return null;
      }
      return EndCardFairSource(
        gameId: gameId,
        chainCommit: real.commit,
        loadFrames: loaders[gameId]!.call,
      );
    };
  }

  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final Future<void> created = controller.createRoom(name: 'Sam', players: 2);
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String reqId =
      (jsonDecode(transport.sentRaw.last) as Map<String, Object?>)['id']!
          as String;
  transport.pushText(
    _frameText(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': 0, 'seat_token': 'tok-0'},
    ),
  );
  transport.pushText(
    _frameText(type: 'room', re: reqId, data: _roomJson(seq: 1)),
  );
  await created;
  addTearDown(controller.dispose);

  final _FakeFeedbackService feedback = _FakeFeedbackService();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<Object?>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        );
      },
      home: FeedbackScope(
        settings: FeedbackSettings.forTest(),
        service: feedback,
        child: GameScreen(controller: controller),
      ),
    ),
  );
  await tester.pump();
  return _Scene(
    tester: tester,
    controller: controller,
    transport: transport,
    script: _Script(tester, transport),
    feedback: feedback,
    loaders: loaders,
    reals: reals,
    sources: asked,
  );
}

/// Waits, in short pumps, until [want] is on screen and no other state key
/// is (the cross-fade has finished). Fails with the scenario when it never
/// gets there.
Future<void> _settleOn(
  WidgetTester tester,
  _Want want, {
  required String scenario,
}) async {
  final Key target = _keyOf(want);
  bool there() =>
      find.byKey(target).evaluate().isNotEmpty &&
      _stateKeys
          .where((Key k) => k != target)
          .every((Key k) => find.byKey(k).evaluate().isEmpty);
  for (int i = 0; i < 40 && !there(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final List<String> onScreen = <String>[
    for (final Key k in _stateKeys)
      if (find.byKey(k).evaluate().isNotEmpty) (k as ValueKey<String>).value,
  ];
  expect(
    there(),
    isTrue,
    reason:
        'scenario "$scenario": expected only ${(target as ValueKey<String>).value} '
        'among the fair row keys; found $onScreen',
  );
}

AppLocalizations _loc(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(GameScreen)));

double _rowHeight(WidgetTester tester) {
  final Finder row = find
      .ancestor(of: find.byKey(_hintKey), matching: find.byType(Row))
      .first;
  return tester.getSize(row).height;
}

void _expectControls(WidgetTester tester, String scenario) {
  expect(
    find.byKey(_hintKey),
    findsOneWidget,
    reason: 'scenario "$scenario": the info control end-card-fair-hint is gone',
  );
  expect(
    find.byKey(_verifyKey),
    findsOneWidget,
    reason: 'scenario "$scenario": the verify control is gone',
  );
}

List<String> _mismatchLines() =>
    _printed.where((String l) => l.startsWith('fair-check mismatch')).toList();

/// Drives the first game of [scene] to the state [want] on the card.
Future<void> _resolve(_Scene scene, _Want want, String scenario) async {
  final _Loader loader = scene.loader(_gameOne);
  final _Real real = scene.real(_gameOne);
  switch (want) {
    case _Want.checking:
      break;
    case _Want.unavailable:
      loader.fail(0);
    case _Want.ok:
      loader.answer(0, real.frames());
    case _Want.failed:
      loader.answer(0, real.frames(badValueAt: 2));
  }
  await _settleOn(scene.tester, want, scenario: scenario);
}

/// A widget test whose body sees every debugPrint line in [_printed].
/// debugPrint is put back before the body returns: the binding refuses to
/// finish a test that leaves it changed, and that check runs before
/// tearDown.
void _t(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (WidgetTester tester) async {
    _printed = <String>[];
    final DebugPrintCallback real = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        _printed.add(message);
      }
    };
    try {
      await body(tester);
    } finally {
      debugPrint = real;
    }
  });
}

void main() {
  tearDown(() {
    debugFairSourceOverride = null;
  });

  // ===========================================================================
  // The four states, en and ar, winner and loser.
  // ===========================================================================
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final int winner in <int>[0, 1]) {
      final String who = winner == 0 ? 'winner card' : 'loser card';
      final String tag = '${locale.languageCode} $who';

      group('fair row, $tag', () {
        _t('checking: the key is up, the check was started once, the '
            'controls stay', (WidgetTester tester) async {
          final _Scene s = await _scene(tester, locale: locale);
          await s.script.play(gameId: _gameOne, winner: winner);
          await _settleOn(tester, _Want.checking, scenario: '$tag checking');
          expect(
            find.byKey(winner == 0 ? _winKey : _loseKey),
            findsOneWidget,
            reason: '$tag: fixture is broken, wrong card',
          );
          expect(
            s.loader(_gameOne).calls,
            1,
            reason:
                '$tag: the check must start once when the card is first shown; '
                'loader calls ${s.loader(_gameOne).calls}',
          );
          _expectControls(tester, '$tag checking');
          expect(_mismatchLines(), isEmpty, reason: '$tag: no mismatch yet');
        });

        _t('ok: a drawn check icon in the success colour and no '
            'emoji character', (WidgetTester tester) async {
          final _Scene s = await _scene(tester, locale: locale);
          await s.script.play(gameId: _gameOne, winner: winner);
          await _settleOn(tester, _Want.checking, scenario: '$tag pre-ok');
          await _resolve(s, _Want.ok, '$tag ok');

          final Finder icons = find.descendant(
            of: find.byKey(_ok),
            matching: find.byType(Icon),
          );
          expect(
            icons,
            findsOneWidget,
            reason: '$tag ok: expected one Icon under end-fair-ok',
          );
          final Icon icon = tester.widget<Icon>(icons);
          expect(
            icon.color,
            LudoColors.success,
            reason: '$tag ok: the check icon colour is ${icon.color}',
          );
          expect(icon.icon, isNotNull);
          final AppLocalizations loc = _loc(tester);
          final Finder words = find.descendant(
            of: find.byKey(_ok),
            matching: find.text(loc.endFairGame),
          );
          expect(
            words,
            findsOneWidget,
            reason: '$tag ok: expected endFairGame "${loc.endFairGame}" text',
          );
          final String text = tester.widget<Text>(words).data!;
          expect(
            text.runes.any(
              (int r) =>
                  (r >= 0x2190 && r <= 0x2BFF) || r >= 0x1F000 || r == 0xFE0F,
            ),
            isFalse,
            reason:
                '$tag ok: the line must carry no symbol or emoji character, '
                'got "$text"',
          );
          expect(
            find.descendant(
              of: find.byKey(_ok),
              matching: find.byType(RefusalNoticeMark),
            ),
            findsNothing,
            reason: '$tag ok: no refusal mark on a fair game',
          );
          expect(
            _mismatchLines(),
            isEmpty,
            reason: '$tag ok: logged a mismatch',
          );
          _expectControls(tester, '$tag ok');
        });

        _t('failed: the refusal mark, endFairGameFailed in the '
            'error colour, one debugPrint line', (WidgetTester tester) async {
          final _Scene s = await _scene(tester, locale: locale);
          await s.script.play(gameId: _gameOne, winner: winner);
          await _settleOn(tester, _Want.checking, scenario: '$tag pre-failed');
          await _resolve(s, _Want.failed, '$tag failed');

          expect(
            find.descendant(
              of: find.byKey(_failed),
              matching: find.byType(RefusalNoticeMark),
            ),
            findsOneWidget,
            reason:
                '$tag failed: expected the refusal mark under end-fair-failed',
          );
          final Icon refusal = tester.widget<Icon>(
            find.descendant(
              of: find.byKey(_failed),
              matching: find.byType(Icon),
            ),
          );
          expect(
            refusal.color,
            LudoColors.error,
            reason: '$tag failed: the refusal mark colour is ${refusal.color}',
          );
          expect(
            refusal.icon,
            isNot(Icons.check_circle_rounded),
            reason: '$tag failed: a check mark on a failed game',
          );
          final AppLocalizations loc = _loc(tester);
          final Finder words = find.descendant(
            of: find.byKey(_failed),
            matching: find.text(loc.endFairGameFailed),
          );
          expect(
            words,
            findsOneWidget,
            reason:
                '$tag failed: expected endFairGameFailed '
                '"${loc.endFairGameFailed}"',
          );
          expect(
            tester.widget<Text>(words).style?.color,
            LudoColors.error,
            reason: '$tag failed: text colour is not the error colour',
          );
          expect(
            _mismatchLines(),
            <String>['fair-check mismatch k=2 reason=value'],
            reason:
                '$tag failed: expected exactly one line '
                '"fair-check mismatch k=2 reason=value" (value changed at '
                'k=2, secret tag 1, game $_gameOne); printed $_printed',
          );
          _expectControls(tester, '$tag failed');
        });

        _t('unavailable: the key is up, never shown as fair or '
            'failed, nothing logged as a mismatch', (
          WidgetTester tester,
        ) async {
          final _Scene s = await _scene(tester, locale: locale);
          await s.script.play(gameId: _gameOne, winner: winner);
          await _settleOn(tester, _Want.checking, scenario: '$tag pre-unavail');
          await _resolve(s, _Want.unavailable, '$tag unavailable');
          expect(find.byKey(_ok), findsNothing, reason: '$tag: shown as fair');
          expect(
            find.byKey(_failed),
            findsNothing,
            reason: '$tag: shown as failed',
          );
          expect(_mismatchLines(), isEmpty, reason: '$tag: logged a mismatch');
          _expectControls(tester, '$tag unavailable');
        });

        _t('no haptic or sound is fired by the check, whatever its '
            'verdict', (WidgetTester tester) async {
          for (final _Want want in <_Want>[
            _Want.ok,
            _Want.failed,
            _Want.unavailable,
          ]) {
            final _Scene s = await _scene(tester, locale: locale);
            await s.script.play(gameId: _gameOne, winner: winner);
            await _settleOn(tester, _Want.checking, scenario: '$tag cue base');
            final List<FeedbackCue> before = List<FeedbackCue>.of(
              s.feedback.recorded,
            );
            await _resolve(s, want, '$tag cues $want');
            expect(
              s.feedback.recorded,
              before,
              reason:
                  '$tag: resolving the check to ${want.name} played cues '
                  '${s.feedback.recorded.skip(before.length).toList()}; '
                  'expected none',
            );
            await tester.pumpWidget(const SizedBox());
            debugFairSourceOverride = null;
          }
        });
      });
    }
  }

  // ===========================================================================
  // Unavailable, tap, again.
  // ===========================================================================
  group('unavailable then tap', () {
    _t('a tap calls the loader again and a fair answer shows ok', (
      WidgetTester tester,
    ) async {
      final _Scene s = await _scene(tester);
      await s.script.play(gameId: _gameOne, winner: 0);
      await _settleOn(tester, _Want.checking, scenario: 'retry start');
      s.loader(_gameOne).fail(0);
      await _settleOn(tester, _Want.unavailable, scenario: 'retry unavailable');
      expect(s.loader(_gameOne).calls, 1);

      await tester.tap(find.byKey(_unavailable));
      await tester.pump();
      expect(
        s.loader(_gameOne).calls,
        2,
        reason:
            'a tap on end-fair-unavailable must call the source again; '
            'loader calls ${s.loader(_gameOne).calls}',
      );
      await _settleOn(tester, _Want.checking, scenario: 'retry in flight');
      s.loader(_gameOne).answer(1, s.real(_gameOne).frames());
      await _settleOn(tester, _Want.ok, scenario: 'retry then fair');
      _expectControls(tester, 'retry then fair');
    });

    _t('the tap target is at least 48 dp tall', (WidgetTester tester) async {
      final _Scene s = await _scene(tester, size: const Size(320, 640));
      await s.script.play(gameId: _gameOne, winner: 0);
      await _settleOn(tester, _Want.checking, scenario: 'target start');
      s.loader(_gameOne).fail(0);
      await _settleOn(tester, _Want.unavailable, scenario: 'target');
      final Finder target = find
          .ancestor(
            of: find.byKey(_unavailable),
            matching: find.byType(InkWell),
          )
          .first;
      final Size size = tester.getSize(target);
      expect(
        size.height,
        greaterThanOrEqualTo(48),
        reason:
            'tap target of end-fair-unavailable is $size, expected >= 48 tall',
      );
    });

    _t('a tap while checking, and a tap on a verdict, never calls '
        'the source again', (WidgetTester tester) async {
      final _Scene s = await _scene(tester);
      await s.script.play(gameId: _gameOne, winner: 0);
      await _settleOn(tester, _Want.checking, scenario: 'tap-checking');
      await tester.tap(find.byKey(_checking), warnIfMissed: false);
      await tester.pump();
      expect(
        s.loader(_gameOne).calls,
        1,
        reason: 'tap while checking re-ran it',
      );
      s.loader(_gameOne).answer(0, s.real(_gameOne).frames());
      await _settleOn(tester, _Want.ok, scenario: 'tap-ok');
      await tester.tap(find.byKey(_ok), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(s.loader(_gameOne).calls, 1, reason: 'tap on ok re-ran the check');
      expect(find.byKey(_ok), findsOneWidget);
    });

    _t('a retry that is fair is not shown before the answer', (
      WidgetTester tester,
    ) async {
      final _Scene s = await _scene(tester);
      await s.script.play(gameId: _gameOne, winner: 0);
      await _settleOn(tester, _Want.checking, scenario: 'gate start');
      s.loader(_gameOne).fail(0);
      await _settleOn(tester, _Want.unavailable, scenario: 'gate');
      await tester.tap(find.byKey(_unavailable));
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(_ok),
        findsNothing,
        reason: 'ok shown while the retry has no answer',
      );
      expect(find.byKey(_unavailable), findsNothing);
    });
  });

  // ===========================================================================
  // As today: no source, no check.
  // ===========================================================================
  group('no source (the seam answers null)', () {
    _t('the row is as today: no state key, endFairLine, controls', (
      WidgetTester tester,
    ) async {
      debugFairSourceOverride = (String gameId, String commit) => null;
      final _Scene s = await _scene(tester, withSeam: false);
      await s.script.play(gameId: _gameOne, winner: 0);
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      for (final Key k in _stateKeys) {
        expect(
          find.byKey(k),
          findsNothing,
          reason: 'a null source must leave the row as today; found $k',
        );
      }
      expect(
        find.text(_loc(tester).endFairLine),
        findsWidgets,
        reason: 'endFairLine must still be on the card',
      );
      _expectControls(tester, 'null source');
      expect(_mismatchLines(), isEmpty);
    });
  });

  // ===========================================================================
  // Same height in every state, on a small screen at a large text scale.
  // ===========================================================================
  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final (Size size, double scale) in const <(Size, double)>[
      (Size(390, 844), 1.0),
      (Size(320, 640), 1.3),
    ]) {
      final String tag =
          '${locale.languageCode} ${size.width.toInt()}x${size.height.toInt()} '
          'at $scale';
      _t('row height is identical in all four states, $tag', (
        WidgetTester tester,
      ) async {
        final Map<String, double> heights = <String, double>{};
        final Map<String, Rect> verify = <String, Rect>{};
        final Map<String, Rect> rematch = <String, Rect>{};
        for (final _Want want in _Want.values) {
          final _Scene s = await _scene(
            tester,
            locale: locale,
            size: size,
            textScale: scale,
          );
          await s.script.play(gameId: _gameOne, winner: 1);
          await _settleOn(tester, _Want.checking, scenario: '$tag base');
          await _resolve(s, want, '$tag ${want.name}');
          heights[want.name] = _rowHeight(tester);
          verify[want.name] = tester.getRect(find.byKey(_verifyKey));
          rematch[want.name] = tester.getRect(find.byKey(_rematchKey));
          expect(
            tester.takeException(),
            isNull,
            reason: '$tag ${want.name}: layout threw',
          );
          await tester.pumpWidget(const SizedBox());
          debugFairSourceOverride = null;
        }
        final Set<double> distinct = heights.values.toSet();
        expect(
          distinct.length,
          1,
          reason: 'row height differs by state ($tag): $heights',
        );
        expect(
          verify.values.toSet().length,
          1,
          reason: 'the verify control moved between states ($tag): $verify',
        );
        expect(
          rematch.values.toSet().length,
          1,
          reason: 'the rematch control moved between states ($tag): $rematch',
        );
      });
    }
  }

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    for (final int winner in <int>[0, 1]) {
      _t('at 320x640, text 1.3, ${locale.languageCode} '
          '${winner == 0 ? 'winner' : 'loser'}: the row, the rematch control '
          'and the verify link sit where they sit with no check, on screen', (
        WidgetTester tester,
      ) async {
        // As today: the seam answers null.
        final _Scene base = await _scene(
          tester,
          locale: locale,
          size: const Size(320, 640),
          textScale: 1.3,
          withSeam: false,
        );
        debugFairSourceOverride = (String id, String commit) => null;
        await base.script.play(gameId: _gameOne, winner: winner);
        final Rect baseVerify = tester.getRect(find.byKey(_verifyKey));
        final Rect baseRematch = tester.getRect(find.byKey(_rematchKey));
        final double baseHeight = _rowHeight(tester);
        await tester.pumpWidget(const SizedBox());
        debugFairSourceOverride = null;

        for (final _Want want in _Want.values) {
          final String scenario =
              '${locale.languageCode} ${winner == 0 ? 'winner' : 'loser'} '
              '320x640@1.3 ${want.name}';
          final _Scene s = await _scene(
            tester,
            locale: locale,
            size: const Size(320, 640),
            textScale: 1.3,
          );
          await s.script.play(gameId: _gameOne, winner: winner);
          await _settleOn(tester, _Want.checking, scenario: '$scenario base');
          await _resolve(s, want, scenario);
          final Rect verify = tester.getRect(find.byKey(_verifyKey));
          final Rect rematch = tester.getRect(find.byKey(_rematchKey));
          expect(
            verify,
            baseVerify,
            reason: '$scenario: verify link moved from $baseVerify to $verify',
          );
          expect(
            rematch,
            baseRematch,
            reason:
                '$scenario: rematch control moved from $baseRematch to $rematch',
          );
          expect(
            _rowHeight(tester),
            baseHeight,
            reason: '$scenario: row height changed from the no-check card',
          );
          expect(
            verify.bottom,
            lessThanOrEqualTo(640),
            reason: '$scenario: verify link off screen at $verify',
          );
          expect(
            rematch.bottom,
            lessThanOrEqualTo(640),
            reason: '$scenario: rematch control off screen at $rematch',
          );
          expect(tester.takeException(), isNull, reason: '$scenario: threw');
          await tester.pumpWidget(const SizedBox());
          debugFairSourceOverride = null;
        }
      });
    }
  }

  // ===========================================================================
  // Mirroring.
  // ===========================================================================
  group('RTL', () {
    _t('in Arabic the mark is on the right of its words, in English '
        'on the left', (WidgetTester tester) async {
      for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
        final _Scene s = await _scene(tester, locale: locale);
        await s.script.play(gameId: _gameOne, winner: 0);
        await _settleOn(tester, _Want.checking, scenario: 'rtl base');
        await _resolve(s, _Want.ok, 'rtl ok ${locale.languageCode}');
        final double iconX = tester
            .getCenter(
              find.descendant(of: find.byKey(_ok), matching: find.byType(Icon)),
            )
            .dx;
        final double textX = tester
            .getCenter(
              find.descendant(
                of: find.byKey(_ok),
                matching: find.text(_loc(tester).endFairGame),
              ),
            )
            .dx;
        if (locale.languageCode == 'ar') {
          expect(
            iconX,
            greaterThan(textX),
            reason: 'ar: the check icon must sit right of its words',
          );
        } else {
          expect(
            iconX,
            lessThan(textX),
            reason: 'en: the check icon must sit left of its words',
          );
        }
        await tester.pumpWidget(const SizedBox());
        debugFairSourceOverride = null;
      }
    });
  });

  // ===========================================================================
  // The check follows the game, not the card.
  // ===========================================================================
  group('rematch', () {
    _t('the next game starts again at checking, and game one is '
        'not checked a second time', (WidgetTester tester) async {
      final _Scene s = await _scene(
        tester,
        games: const <String>[_gameOne, _gameTwo],
      );
      await s.script.play(gameId: _gameOne, winner: 0);
      await _settleOn(tester, _Want.checking, scenario: 'rematch game one');
      s.loader(_gameOne).answer(0, s.real(_gameOne).frames());
      await _settleOn(tester, _Want.ok, scenario: 'rematch game one ok');

      await s.script.room(
        (int seq) => _roomJson(
          state: 'LOBBY',
          chainIndex: 1,
          rematch: <String, Object?>{
            'by': 0,
            'ready': const <int>[0],
          },
          seq: seq,
        ),
      );
      await s.script.room(
        (int seq) => _roomJson(
          state: 'LOBBY',
          chainIndex: 1,
          rematch: <String, Object?>{
            'by': 0,
            'ready': const <int>[0, 1],
          },
          seq: seq,
        ),
      );
      await s.script.play(gameId: _gameTwo, winner: 1);

      expect(
        s.controller.room!.gameId,
        _gameTwo,
        reason: 'fixture is broken: the second game must be the live one',
      );
      await _settleOn(tester, _Want.checking, scenario: 'rematch game two');
      expect(
        find.byKey(_ok),
        findsNothing,
        reason: 'game one\'s verdict leaked onto game two\'s card',
      );
      expect(
        s.loader(_gameOne).calls,
        1,
        reason: 'game one was checked ${s.loader(_gameOne).calls} times',
      );
      expect(
        s.loader(_gameTwo).calls,
        1,
        reason: 'game two must be checked once; ${s.loader(_gameTwo).calls}',
      );
      expect(s.sources.toSet(), <String>{
        _gameOne,
        _gameTwo,
      }, reason: 'the seam was asked about ${s.sources}');

      s.loader(_gameTwo).answer(0, s.real(_gameTwo).frames(badValueAt: 1));
      await _settleOn(
        tester,
        _Want.failed,
        scenario: 'rematch game two failed',
      );
      expect(_mismatchLines(), <String>[
        'fair-check mismatch k=1 reason=value',
      ], reason: 'game two only; printed $_printed');
      _expectControls(tester, 'rematch game two');
    });

    _t('a failed game one does not colour the next game', (
      WidgetTester tester,
    ) async {
      final _Scene s = await _scene(
        tester,
        games: const <String>[_gameOne, _gameTwo],
      );
      await s.script.play(gameId: _gameOne, winner: 1);
      await _settleOn(tester, _Want.checking, scenario: 'carry start');
      s.loader(_gameOne).answer(0, s.real(_gameOne).frames(badValueAt: 3));
      await _settleOn(tester, _Want.failed, scenario: 'carry failed');
      await s.script.room(
        (int seq) => _roomJson(
          state: 'LOBBY',
          chainIndex: 1,
          rematch: <String, Object?>{
            'by': 1,
            'ready': const <int>[1],
          },
          seq: seq,
        ),
      );
      await s.script.room(
        (int seq) => _roomJson(
          state: 'LOBBY',
          chainIndex: 1,
          rematch: <String, Object?>{
            'by': 1,
            'ready': const <int>[0, 1],
          },
          seq: seq,
        ),
      );
      await s.script.play(gameId: _gameTwo, winner: 0);
      await _settleOn(tester, _Want.checking, scenario: 'carry game two');
      expect(find.byKey(_failed), findsNothing);
    });
  });

  // Last in the file on purpose: when the row's switcher cannot take a retry
  // that fails within its own cross-fade, the framework exception it throws
  // leaves the binding unusable for the test declared after it.
  group('retry that fails fast', () {
    _t('a second failure stays unavailable and the next tap tries '
        'a third time', (WidgetTester tester) async {
      final _Scene s = await _scene(tester);
      await s.script.play(gameId: _gameOne, winner: 1);
      await _settleOn(tester, _Want.checking, scenario: 'twice start');
      s.loader(_gameOne).fail(0);
      await _settleOn(tester, _Want.unavailable, scenario: 'twice first');
      await tester.tap(find.byKey(_unavailable));
      await tester.pump();
      s.loader(_gameOne).fail(1);
      await _settleOn(tester, _Want.unavailable, scenario: 'twice second');
      await tester.tap(find.byKey(_unavailable));
      await tester.pump();
      expect(s.loader(_gameOne).calls, 3, reason: 'third tap, third call');
      s.loader(_gameOne).answer(2, s.real(_gameOne).frames(badRevealAt: 3));
      await _settleOn(tester, _Want.failed, scenario: 'twice then failed');
      expect(
        _mismatchLines(),
        <String>['fair-check mismatch k=3 reason=chain'],
        reason:
            'a swapped reveal at k=3 must log k=3 reason=chain; printed '
            '$_printed',
      );
    });
  });
}
