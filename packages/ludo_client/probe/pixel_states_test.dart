// C-631 probe (order 631): the game's states rendered to PNG, so a layout
// change can be proved pixel-identical by comparing the files byte for byte.
//
// Not part of the normal suite: this file lives outside test/, so
// `flutter test` with no argument never runs it. Run it by name:
//
//   PIXEL_OUT=/tmp/pix631-x flock /tmp/ludo-suite.lock timeout 900 \
//     flutter test probe/pixel_states_test.dart
//
// It mounts the real GameScreen over a real RoomController on FakeTransport
// with scripted frames (the helpers in test/support, unchanged and reached
// by relative import), at 411 x 891 logical pixels, device pixel ratio 1.0,
// text scale 1.0, animations on, with the app's own fonts loaded (Poppins,
// Noto Sans Arabic) through loadAppFonts. For each state below and each
// locale (en, ar) it writes `<state>-<locale>.png` into the directory named
// by the environment variable PIXEL_OUT.
//
// Capture: the whole screen, taken from the root layer of the test binding's
// render view (tester.binding.renderViews.single, its layer cast to
// OffsetLayer, toImage over the full 411 x 891 rect at pixel ratio 1.0). No
// RepaintBoundary of the app is used for the capture, so a boundary added or removed in the
// widget tree changes nothing about how the picture is taken.
//
// Time: every state is reached by the same scripted frames, then pumped a
// fixed number of 16 ms steps, then captured. There is no pumpAndSettle and
// no wait on a condition for the capture moment; the number of 16 ms frames
// from mount is a constant per state (see [_Spec.frames]), so two trees are
// compared at identical animation time. Each state asserts, after those
// frames, that it was reached, by a named key; a state that could not be
// reached fails with its name, locale and what was found instead.
//
// States:
//   lobby          the room is in LOBBY with one of two seats filled
//   s1-watching    the other seat's turn, countdown running
//   s2-my-roll     my turn to roll, die waiting for my tap
//   s3-choosing    I rolled a 3 with two legal tokens, rings pulsing
//   s4-mid-walk    a token walks 5 squares, captured on frame 20 of the walk
//   no-move        my own roll with no legal token, the no-move notice up
//   reconnecting   the socket dropped, the connection-lost card with the
//                  reconnecting line while an automatic retry is pending
//   end-winner     the end card, I am the winner
//   end-loser      the end card, the other seat won
//
// There is no randomness. The seed of a run is the scenario name: a failure
// message names `<state>-<locale>` and the frames pushed, which replay it.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';

import '../test/support/c468_harness.dart';
import '../test/support/end_card_chat_harness.dart';
import '../test/support/roll_tray_harness.dart';

const Duration _frame = Duration(milliseconds: 16);
const Size _phone = Size(411, 891);
const String _outVar = 'PIXEL_OUT';

/// Frames of 16 ms from the last scripted push to the capture, by state.
const int _watchFrames = 40;
const int _rollFrames = 90;
const int _walkFrames = 20;
const int _noMoveFrames = 6;
const int _endFrames = 60;

const Map<int, List<int>> _board = <int, List<int>>{
  0: <int>[10, 20, -1, -1],
  1: <int>[30, -1, -1, -1],
};

/// Pumps exactly [count] frames of 16 ms.
Future<void> _frames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(_frame);
  }
}

/// The scenario name for failure messages and file names.
String _scenario(String state, Locale locale) =>
    '$state-${locale.languageCode}';

String _outDir() {
  final String? dir = Platform.environment[_outVar];
  if (dir == null || dir.isEmpty) {
    fail(
      'expected: the environment variable $_outVar names the directory the '
      'PNGs are written to | happened: it is not set | reproduce: '
      '$_outVar=/tmp/pix flutter test probe/pixel_states_test.dart',
    );
  }
  return dir;
}

/// Writes the whole screen to `<PIXEL_OUT>/<name>.png`.
Future<void> _capture(WidgetTester tester, String name) async {
  final String dir = _outDir();
  final RenderView view = tester.binding.renderViews.single;
  final ContainerLayer? root = view.debugLayer;
  expect(
    root,
    isA<OffsetLayer>(),
    reason:
        '$name | expected: the render view has an OffsetLayer root to '
        'capture | found: $root',
  );
  final OffsetLayer layer = root! as OffsetLayer;
  final Size size = view.size;
  expect(
    size,
    _phone,
    reason:
        '$name | expected: the captured view is $_phone at pixel ratio 1.0 '
        '| found: $size at ${tester.view.devicePixelRatio}',
  );
  final Uint8List? bytes = await tester.runAsync<Uint8List?>(() async {
    final ui.Image image = await layer.toImage(Offset.zero & size);
    try {
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  });
  expect(
    bytes,
    isNotNull,
    reason: '$name | expected: PNG bytes from the screen | found: none',
  );
  await tester.runAsync(() async {
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes!, flush: true);
  });
}

void _expectKey(WidgetTester tester, String name, Key key, String what) {
  expect(
    find.byKey(key),
    findsOneWidget,
    reason:
        '$name | expected: $what ($key) is on screen at capture | found: '
        'nothing under that key | reproduce: PIXEL_OUT=<dir> flutter test '
        'probe/pixel_states_test.dart --plain-name "$name"',
  );
}

/// Mounts a PLAYING game, two seats (0 is mine, 1 is Bob), tokens on the
/// board, [turn] as the snapshot turn. Mirrors the census probe's fixture.
Future<EndGame> _open(
  WidgetTester tester,
  String name,
  Locale locale,
  Map<String, Object?> turn, {
  int autoReconnectMs = 0,
}) async {
  phoneSurface(tester);
  tester.view.physicalSize = _phone;
  final List<Map<String, Object?>> seats = namedSeats(2, 0, tokens: _board);
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: turn,
    seats: seats,
    mySeat: 0,
    gameId: 'c631-game-1',
    autoReconnectDelays: autoReconnectMs == 0
        ? const <Duration>[]
        : <Duration>[Duration(milliseconds: autoReconnectMs)],
  );
  await mountGame(tester, drive, locale: locale);
  return EndGame(Scn(name, tester, drive), 0, 2, seats);
}

/// My roll of [value] lands with tokens 0 and 1 legal, then a fixed number of
/// frames pass so the die has settled and the rings pulse.
Future<void> _rollAndRing(EndGame g, int value) async {
  await g.s.push('rolled', rolledFrame(0, value, 1, legal: <int>[0, 1]));
  await _frames(g.tester, _rollFrames);
  expect(
    ringedTokens(g.tester),
    <int>[0, 1],
    reason: g.why(
      'fixture: board-legal-ring-0-0 and board-legal-ring-0-1 on screen '
      'after the roll of $value and $_rollFrames frames of 16 ms',
    ),
  );
}

/// One state: its file stem and how it is reached and captured.
typedef _Run = Future<void> Function(WidgetTester tester, Locale locale);

Future<void> _lobby(WidgetTester tester, Locale locale) async {
  final String name = _scenario('lobby', locale);
  phoneSurface(tester);
  tester.view.physicalSize = _phone;
  final List<Map<String, Object?>> seats = <Map<String, Object?>>[
    seatJson(0, name: 'Sam'),
  ];
  final RollTrayDrive drive = await connectPlaying(
    tester,
    turn: null,
    seats: seats,
    mySeat: 0,
    state: 'LOBBY',
  );
  await mountGame(tester, drive, locale: locale);
  await _frames(tester, _watchFrames);
  _expectKey(
    tester,
    name,
    const Key('game-screen-waiting'),
    'the waiting-for-players line',
  );
  await _capture(tester, name);
  await releaseGame(tester, drive);
}

Future<void> _watching(WidgetTester tester, Locale locale) async {
  final String name = _scenario('s1-watching', locale);
  final EndGame g = await _open(tester, name, locale, awaitRollTurn(1));
  await _frames(tester, _watchFrames);
  _expectKey(
    tester,
    name,
    const Key('game-header-countdown-ring'),
    'the countdown ring',
  );
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(Scaffold).first),
  );
  expect(
    find.text(loc.gameYourTurnRoll),
    findsNothing,
    reason: g.why('$name: it is not my turn, so no roll prompt'),
  );
  await _capture(tester, name);
  await g.done();
}

Future<void> _myRoll(WidgetTester tester, Locale locale) async {
  final String name = _scenario('s2-my-roll', locale);
  final EndGame g = await _open(tester, name, locale, awaitRollTurn(0));
  await _frames(tester, _watchFrames);
  _expectKey(tester, name, bigDieKey, 'the big die');
  final AppLocalizations loc = AppLocalizations.of(
    tester.element(find.byType(Scaffold).first),
  );
  expect(
    find.text(loc.gameYourTurnRoll),
    findsWidgets,
    reason: g.why('$name: the text "${loc.gameYourTurnRoll}" is on screen'),
  );
  await _capture(tester, name);
  await g.done();
}

Future<void> _choosing(WidgetTester tester, Locale locale) async {
  final String name = _scenario('s3-choosing', locale);
  final EndGame g = await _open(tester, name, locale, awaitRollTurn(0));
  await _rollAndRing(g, 3);
  _expectKey(tester, name, legalRingKey(0, 0), 'the ring on token 0');
  _expectKey(tester, name, legalRingKey(0, 1), 'the ring on token 1');
  await _capture(tester, name);
  await g.done();
}

Future<void> _midWalk(WidgetTester tester, Locale locale) async {
  final String name = _scenario('s4-mid-walk', locale);
  final EndGame g = await _open(tester, name, locale, awaitRollTurn(0));
  await _rollAndRing(g, 5);
  final Finder token = find.byKey(const Key('token-0-0'));
  final Offset before = tester.getCenter(token);
  await g.s.push('moved', movedFrame(0, 0, 10, 15));
  await _frames(tester, _walkFrames);
  final Offset after = tester.getCenter(token);
  expect(
    after,
    isNot(before),
    reason: g.why(
      '$name: token-0-0 moved between the move frame ($before) and frame '
      '$_walkFrames of the walk ($after), so the walk was under way',
    ),
  );
  await _capture(tester, name);
  await g.done();
}

Future<void> _noMove(WidgetTester tester, Locale locale) async {
  final String name = _scenario('no-move', locale);
  final EndGame g = await _open(tester, name, locale, awaitRollTurn(0));
  await _frames(tester, _watchFrames);
  g.s.steps.add('my no-move roll of 2');
  await pushMyNoMoveRoll(tester, g.drive, face: 2);
  await _frames(tester, _noMoveFrames);
  _expectKey(tester, name, noMoveNoticeKey, 'the no-move notice');
  await _capture(tester, name);
  await g.done();
}

Future<void> _reconnecting(WidgetTester tester, Locale locale) async {
  final String name = _scenario('reconnecting', locale);
  // One automatic retry, an hour out: it stays pending on the fake clock for
  // every frame pumped, so the line under the card is the retrying one.
  final EndGame g = await _open(
    tester,
    name,
    locale,
    awaitRollTurn(1),
    autoReconnectMs: 3600 * 1000,
  );
  await _frames(tester, _watchFrames);
  g.s.steps.add('far side closes');
  g.drive.transport.endFromFarSide();
  await tester.pump();
  await _frames(tester, _watchFrames);
  _expectKey(
    tester,
    name,
    const Key('game-screen-connection-lost'),
    'the connection-lost card',
  );
  _expectKey(
    tester,
    name,
    const Key('game-screen-reconnecting'),
    'the reconnecting line',
  );
  await _capture(tester, name);
  await g.done();
}

Future<void> _endCard(
  WidgetTester tester,
  Locale locale,
  String state,
  EndKind kind,
) async {
  final String name = _scenario(state, locale);
  final EndGame g = await openFinished(
    tester,
    name,
    kind: kind,
    size: _phone,
    locale: locale,
  );
  await _frames(tester, _endFrames);
  _expectKey(tester, name, const Key('game-screen-winner'), 'the end card');
  await _capture(tester, name);
  await g.done();
}

void main() {
  setUpAll(loadAppFonts);

  final Map<String, _Run> states = <String, _Run>{
    'lobby waiting for players': _lobby,
    'S1 watching': _watching,
    'S2 my turn to roll': _myRoll,
    'S3 choosing, two legal rings': _choosing,
    'S4 mid-walk, frame $_walkFrames': _midWalk,
    'no-move roll on my die': _noMove,
    'reconnecting banner': _reconnecting,
    'end card, winner': (WidgetTester t, Locale l) =>
        _endCard(t, l, 'end-winner', EndKind.winner),
    'end card, loser': (WidgetTester t, Locale l) =>
        _endCard(t, l, 'end-loser', EndKind.loser),
  };

  for (final Locale locale in const <Locale>[Locale('en'), Locale('ar')]) {
    states.forEach((String title, _Run run) {
      testWidgets('$title (${locale.languageCode})', (
        WidgetTester tester,
      ) async {
        await run(tester, locale);
      });
    });
  }
}
