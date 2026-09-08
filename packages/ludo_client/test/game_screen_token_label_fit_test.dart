// A proof, independent of lib/src/game_screen.dart's own author, that the
// four token buttons on GameScreen (H4, work/ludo/orders/103-PROMPT.md) lay
// their label out on a single line at a real phone width, in both languages
// this app ships.
//
// The defect this guards against, recorded in
// work/ludo/orders/132b-token-button-overflow-proof.md: on emulator run
// 34191276162 (04-game-en.png, 1080x1848 physical), the four token buttons
// wrap their label across two lines ("Tok" / "en 1"), and the Arabic label
// wraps the same way. No existing suite in this package can see that,
// because every existing assertion on these buttons is on the *string* a
// Text holds, at flutter_test's default 800x600 logical canvas, where 200dp
// per button is enough for the label to fit on one line regardless of what
// it says. A label that satisfies a string match and not the button is
// invisible to that kind of test. This file pins the view to the geometry
// the defect was photographed at and measures how the real RenderParagraph
// behind each button's Text actually broke its lines, not what string it
// holds.
//
// Deliberately not asserted: the literal wording ("Token 1", "قطعة 1"). A
// fix for this defect is free to reword the label; a test that hardcodes the
// current string would fail the moment that happens, for a reason that has
// nothing to do with whether the label fits. Every text sample this file
// measures is read back off the mounted widget tree, never typed in here.
//
// Deliberately not asserted: a RenderFlex "overflowed" exception. The label
// wraps onto a second line; it does not spill past its box, so no such
// exception is ever thrown here, on fixed or unfixed code, and a test
// watching for one would pass on the broken build.
//
// RenderParagraph.computeLineMetrics() does not exist on the Flutter SDK
// installed in this workspace (3.47.1 stable, checked directly against
// packages/flutter/lib/src/rendering/paragraph.dart: only TextPainter
// declares that method; RenderParagraph keeps its TextPainter private and
// exposes no line-metrics accessor of its own). The equivalent this file
// uses instead: read every input that fed the real RenderParagraph's layout
// straight off that render object -- its resolved InlineSpan (so the actual
// on-screen string and style, whatever the label currently says), its
// TextDirection, TextScaler, maxLines, locale, strutStyle, textWidthBasis,
// and the exact maxWidth constraint it was laid out against -- feed all of
// that into a fresh TextPainter, and call *that* TextPainter's own
// computeLineMetrics().length. Because the inputs are copied byte-for-byte
// off the widget that is actually on screen, this reproduces the same line
// break dart:ui would already have computed for the button, rather than
// inferring it indirectly from a height comparison.
//
// The harness below (locales harness, _mount, _connectPlaying, the seat/turn
// JSON builders, the token key, the _Connector double) is copied from
// test/game_screen_test.dart:69-278 rather than imported from it, per this
// order: that file belongs to nobody this round and importing its private
// helpers would collide with it.
//
// ROUND 2 (work/ludo/orders/132b-token-button-overflow-proof.md, "ROUND 1
// VERDICT: RETURNED"): the line-count assertion above was measured to pass
// against order 132a's fix (FittedBox(fit: BoxFit.scaleDown) around the
// label) for every possible label string, including one three times longer
// than the original -- because FittedBox lays its child out under
// *unbounded* width, so the RenderParagraph behind the label always reports
// exactly one line no matter how long the string is or how far it has been
// shrunk to get there. A label scaled down to illegibility satisfies the
// line-count assertion just as well as a label that genuinely fits.
//
// The second loop each case below adds does not re-measure line count; it
// measures whether the label was shrunk at all. Under
// FittedBox(fit: BoxFit.scaleDown), the FittedBox's child (the label's own
// RenderParagraph) is laid out with no width limit, so its laid-out width is
// the label's natural, un-shrunk, single-line width; separately, the
// FittedBox render object itself carries the incoming BoxConstraints its own
// parent (the button, by way of Expanded/Padding) gave it -- the box it was
// actually allowed. If the natural width exceeds that allowed width, the
// only way the label is still rendering on one line is that FittedBox has
// scaled it down, and the button is too narrow for it regardless of what the
// line count says. This file measures both numbers straight off the live
// render tree (never a hardcoded width) and reports the implied scale factor
// (allowed / natural) in the failure message.
//
// If no FittedBox sits between a token button and its label -- true on this
// worktree's unfixed main, where the label wraps instead of shrinking, and
// true of any future fix that solves the overflow by a mechanism other than
// FittedBox -- there is nothing here for this measurement to read, and the
// loop below calls markTestSkipped(...) and stops rather than silently
// reporting a pass that measured nothing. On this worktree that code path is
// never actually reached: the first loop's line-count assertion already
// fails at token button 0 (unfixed main wraps every label), which aborts the
// test body before the second loop runs. That is expected and is recorded in
// this file's own report rather than claimed as an observation this
// worktree does not have the fixed code to make.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/snapshot.dart';
import 'package:ludo_client/src/net/transport.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';

// The phone geometry order 132b names as the one the defect was
// photographed at (emulator run 34191276162, 04-game-en.png / 05-game-ar.png).
const Size _devicePhysicalSize = Size(1080, 1848);
const double _devicePixelRatio = 2.75;

// --- server-side id generation for pushed frames, copied from
// test/game_screen_test.dart ------------------------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'game-scr-fit-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

// --- small JSON helpers, copied from test/game_screen_test.dart ------------

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

/// A server push or reply, encoded exactly as Frame.decode expects.
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
// test/game_screen_test.dart -------------------------------------------------

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
  int players = 4,
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

// --- a TransportConnector test double, copied from test/game_screen_test.dart

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport '
        'queued; the test scenario is broken, not the code under test',
      );
    }
    return _queue.removeAt(0);
  }
}

// --- driving a controller to a chosen room state, through real frames,
// copied from test/game_screen_test.dart -------------------------------------

Future<(RoomController, FakeTransport)> _connectPlaying(
  WidgetTester tester, {
  int mySeat = 0,
  bool sendSeatAssigned = true,
  String state = 'PLAYING',
  int players = 4,
  required List<Map<String, Object?>> seats,
  Map<String, Object?>? turn,
  int? winner,
  int seq = 1,
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
  // See test/game_screen_test.dart's "standing lesson 8": pumpEventQueue()
  // alone relies on real Timers via Future.delayed, which never fire under
  // the fake-async clock a testWidgets body runs in. tester.runAsync() steps
  // outside that zone for the duration of the call so the real event loop
  // actually advances, then tester.pump() resyncs the widget tree.
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  final String id = _idOf(transport.sentRaw.last);
  if (sendSeatAssigned) {
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
      ),
    );
  }
  transport.pushText(
    _frame(
      type: 'room',
      re: id,
      data: _roomJson(
        state: state,
        players: players,
        seats: seats,
        turn: turn,
        winner: winner,
        seq: seq,
      ),
    ),
  );
  await future;
  return (controller, transport);
}

// --- widget harness, copied from test/game_screen_test.dart ----------------

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: child,
  );
}

Future<void> _mount(
  WidgetTester tester,
  RoomController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    _harness(GameScreen(controller: controller), locale: locale),
  );
  await tester.pump();
}

Key _tokenKey(int i) => Key('game-screen-token-$i');

// --- the measurement itself --------------------------------------------

/// Finds the single `RichText` painting the label inside the token button
/// keyed [buttonKey], and returns how many lines dart:ui actually broke that
/// label into at the width the button laid it out at.
///
/// Reads the resolved `InlineSpan` (the real on-screen text and style,
/// whatever the label currently says), `TextDirection`, `TextScaler`,
/// `maxLines`, `locale`, `strutStyle`, `textWidthBasis`, and the exact
/// layout `maxWidth` straight off the live `RenderParagraph`, then asks a
/// fresh `TextPainter` built from exactly those inputs how many lines it
/// breaks into. `RenderParagraph` itself exposes no line-count accessor on
/// the Flutter SDK this suite runs on (see the file header), so the
/// measurement is taken one level down, on a `TextPainter` fed the same
/// inputs the real paragraph was laid out with.
RenderParagraph _paragraphOfButtonLabel(WidgetTester tester, Key buttonKey) {
  final Finder buttonFinder = find.byKey(buttonKey);
  expect(
    buttonFinder,
    findsOneWidget,
    reason: 'fixture is broken: no widget keyed $buttonKey is mounted',
  );
  final Finder textFinder = find.descendant(
    of: buttonFinder,
    matching: find.byType(RichText),
  );
  expect(
    textFinder,
    findsOneWidget,
    reason: 'fixture is broken: expected exactly one RichText under $buttonKey',
  );
  return tester.renderObject<RenderParagraph>(textFinder);
}

int _lineCountOfButtonLabel(WidgetTester tester, Key buttonKey) {
  final RenderParagraph paragraph = _paragraphOfButtonLabel(tester, buttonKey);
  final TextPainter probe = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  try {
    return probe.computeLineMetrics().length;
  } finally {
    probe.dispose();
  }
}

/// The width the label inside token button [buttonKey] would occupy laid out
/// on a single line with no width limit at all -- its natural, un-shrunk
/// width, independent of whatever constraint the real button happens to lay
/// it out under right now. Built the same way [_lineCountOfButtonLabel] is:
/// every input (text, style, direction, scaler, locale, strut, width basis)
/// is read back off the live `RenderParagraph`, so this measures the label
/// that is actually on screen, whatever it currently says, never a string
/// typed into this file. The only deliberate difference from
/// [_lineCountOfButtonLabel] is the layout width: always unbounded here,
/// because "natural width" is a property of the text and its style alone,
/// not of whatever box it happens to be squeezed into at the moment this is
/// called.
double _naturalSingleLineWidthOfButtonLabel(
  WidgetTester tester,
  Key buttonKey,
) {
  final RenderParagraph paragraph = _paragraphOfButtonLabel(tester, buttonKey);
  final TextPainter probe = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: paragraph.maxLines,
    locale: paragraph.locale,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textHeightBehavior: paragraph.textHeightBehavior,
  )..layout();
  try {
    return probe.width;
  } finally {
    probe.dispose();
  }
}

/// The live `RenderFittedBox` sitting between token button [buttonKey] and
/// its label, or `null` if there is none. `null` covers two real cases this
/// file cannot tell apart and does not need to: unfixed `main`, where the
/// label wraps instead of shrinking, and a hypothetical future fix that
/// solves the overflow by some means other than `FittedBox`. Either way,
/// there is no FittedBox for the natural-width-vs-allowed-width comparison
/// to read, and the caller must not treat that as "nothing was shrunk".
RenderFittedBox? _fittedBoxAroundButtonLabel(
  WidgetTester tester,
  Key buttonKey,
) {
  final Finder buttonFinder = find.byKey(buttonKey);
  final Finder textFinder = find.descendant(
    of: buttonFinder,
    matching: find.byType(RichText),
  );
  final Finder fittedBoxFinder = find.ancestor(
    of: textFinder,
    matching: find.byType(FittedBox),
  );
  final int found = fittedBoxFinder.evaluate().length;
  if (found == 0) {
    return null;
  }
  expect(
    found,
    1,
    reason:
        'fixture is broken: expected at most one FittedBox between '
        '$buttonKey and its label, found $found',
  );
  return tester.renderObject<RenderFittedBox>(fittedBoxFinder);
}

/// Pins `tester.view` to the phone geometry the defect was photographed at
/// (emulator run 34191276162: 1080x1848 physical, dpr 2.75), and returns the
/// logical width that geometry resolves to, so a failure message can state
/// it. `tester.view.reset` is scheduled via `addTearDown`, which is safe
/// here: it undoes a view-size stub, not a pending Timer, so it does not
/// trip flutter_test's post-body pending-timer check.
double _pinPhoneView(WidgetTester tester) {
  tester.view.physicalSize = _devicePhysicalSize;
  tester.view.devicePixelRatio = _devicePixelRatio;
  addTearDown(tester.view.reset);
  return _devicePhysicalSize.width / _devicePixelRatio;
}

void main() {
  group('H4: the four token buttons fit their label on one line, unshrunk, '
      'at phone width '
      '(work/ludo/orders/132b-token-button-overflow-proof.md)', () {
    final seats = <Map<String, Object?>>[
      _seatJson(0, name: 'Sam'),
      _seatJson(1, name: 'Bob'),
    ];

    testWidgets(
      'en: each of the four token buttons renders its label on exactly '
      'one line, without the label being shrunk to fit, at the '
      '1080x1848@2.75 phone geometry the overflow was photographed at',
      (tester) async {
        final double logicalWidth = _pinPhoneView(tester);

        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: null,
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.state,
          RoomState.playing,
          reason: 'fixture is broken',
        );

        await _mount(tester, controller, locale: const Locale('en'));

        for (int i = 0; i < 4; i++) {
          final int lines = _lineCountOfButtonLabel(tester, _tokenKey(i));
          expect(
            lines,
            1,
            reason:
                'H4/132b (en): token button $i wrapped its label onto '
                '$lines lines at a logical width of '
                '${logicalWidth.toStringAsFixed(2)}dp (physical '
                '${_devicePhysicalSize.width.toStringAsFixed(0)}x'
                '${_devicePhysicalSize.height.toStringAsFixed(0)}, dpr '
                '$_devicePixelRatio); a token button label must render on '
                'a single line at a real phone width',
          );
        }

        for (int i = 0; i < 4; i++) {
          final RenderFittedBox? fittedBox = _fittedBoxAroundButtonLabel(
            tester,
            _tokenKey(i),
          );
          if (fittedBox == null) {
            markTestSkipped(
              'H4/132b (en): no FittedBox sits between token button $i and '
              'its label, so this file has no way to measure whether a fix '
              'is scaling the label down instead of letting the button be '
              'wide enough for it; the line-count assertion above having '
              'passed does not by itself rule that out',
            );
            return;
          }
          final double naturalWidth = _naturalSingleLineWidthOfButtonLabel(
            tester,
            _tokenKey(i),
          );
          final double allowedWidth = fittedBox.constraints.maxWidth;
          final String impliedScale = allowedWidth.isFinite && allowedWidth > 0
              ? (naturalWidth / allowedWidth).toStringAsFixed(3)
              : 'undefined (FittedBox was given an unbounded width)';
          expect(
            naturalWidth <= allowedWidth,
            isTrue,
            reason:
                'H4/132b (en): token button $i\'s label has a natural '
                'single-line width of ${naturalWidth.toStringAsFixed(2)}dp '
                'but FittedBox only allowed it '
                '${allowedWidth.toStringAsFixed(2)}dp at a logical width of '
                '${logicalWidth.toStringAsFixed(2)}dp, an implied scale '
                'factor of $impliedScale; the label is rendering on one '
                'line only because it has been shrunk to fit, which is not '
                'the same as the button being wide enough for it',
          );
        }
      },
    );

    testWidgets(
      'ar: each of the four token buttons renders its label on exactly '
      'one line, without the label being shrunk to fit, at the '
      '1080x1848@2.75 phone geometry the overflow was photographed at',
      (tester) async {
        final double logicalWidth = _pinPhoneView(tester);

        final (controller, _) = await _connectPlaying(
          tester,
          mySeat: 0,
          players: 2,
          seats: seats,
          turn: null,
        );
        addTearDown(controller.dispose);
        expect(
          controller.room!.state,
          RoomState.playing,
          reason: 'fixture is broken',
        );

        await _mount(tester, controller, locale: const Locale('ar'));

        for (int i = 0; i < 4; i++) {
          final int lines = _lineCountOfButtonLabel(tester, _tokenKey(i));
          expect(
            lines,
            1,
            reason:
                'H4/132b (ar): token button $i wrapped its label onto '
                '$lines lines at a logical width of '
                '${logicalWidth.toStringAsFixed(2)}dp (physical '
                '${_devicePhysicalSize.width.toStringAsFixed(0)}x'
                '${_devicePhysicalSize.height.toStringAsFixed(0)}, dpr '
                '$_devicePixelRatio); a token button label must render on '
                'a single line at a real phone width',
          );
        }

        for (int i = 0; i < 4; i++) {
          final RenderFittedBox? fittedBox = _fittedBoxAroundButtonLabel(
            tester,
            _tokenKey(i),
          );
          if (fittedBox == null) {
            markTestSkipped(
              'H4/132b (ar): no FittedBox sits between token button $i and '
              'its label, so this file has no way to measure whether a fix '
              'is scaling the label down instead of letting the button be '
              'wide enough for it; the line-count assertion above having '
              'passed does not by itself rule that out',
            );
            return;
          }
          final double naturalWidth = _naturalSingleLineWidthOfButtonLabel(
            tester,
            _tokenKey(i),
          );
          final double allowedWidth = fittedBox.constraints.maxWidth;
          final String impliedScale = allowedWidth.isFinite && allowedWidth > 0
              ? (naturalWidth / allowedWidth).toStringAsFixed(3)
              : 'undefined (FittedBox was given an unbounded width)';
          expect(
            naturalWidth <= allowedWidth,
            isTrue,
            reason:
                'H4/132b (ar): token button $i\'s label has a natural '
                'single-line width of ${naturalWidth.toStringAsFixed(2)}dp '
                'but FittedBox only allowed it '
                '${allowedWidth.toStringAsFixed(2)}dp at a logical width of '
                '${logicalWidth.toStringAsFixed(2)}dp, an implied scale '
                'factor of $impliedScale; the label is rendering on one '
                'line only because it has been shrunk to fit, which is not '
                'the same as the button being wide enough for it',
          );
        }
      },
    );
  });
}
