// Conformance tests for work/ludo/orders/C-577-landing-sight.md, rules 1 to 5,
// written from that contract's text alone. Nothing here reads or describes
// the order 577c implementation.
//
// The two sights under test:
//   - the home burst, key `board-home-burst-<seat>-<token>`, drawn when a
//     move the board accepted lands at progress 57 (rule 1);
//   - the captured flash, key `board-captured-flash-<seat>-<token>`, carried
//     by the flying token when it is MY token that was captured (rule 2).
//
// How time is driven. Every case mounts a bare LudoBoard (the harness shape
// of test/landing_cues_test.dart and test/token_travel_test.dart, copied by
// hand, never imported), rebuilds it with a new `tokens` map through a
// GlobalKey, pumps one zero-length frame, and calls that instant 0 ms. After
// that the clock only moves in bounded pumps of exactly [_kChunk] (10 ms),
// never one long pump, because a capture flight and the burst are driven by
// frames: one long pump would hand them a single frame at the end. Presence of
// a key is sampled after every chunk, so a failure can name the first sample
// that broke the expectation and print the whole presence timeline.
//
// Timeline of the capture fixture on the base the contract was cut from
// (derived from kTokenStepDuration / kCaptureFlightDuration, which are the
// contract's own constants, not from any drawing code):
//   seat 1 token 0 walks 3 to 5, two steps, so it lands at 2 * 140 = 280 ms;
//   the captured token flies for kCaptureFlightDuration, 280 to 640 ms.
// Reduced motion: 2 * 40 = 80 ms, flight 80 to 200 ms.
//
// Slack. The contract says "one frame of slack you name". The name is
// [_kFrameSlack]: 20 ms, one 60 Hz frame (16.7 ms) rounded up to two chunks.
// "Absent by T" is asserted for every sample at or after T + [_kFrameSlack];
// "present until T" is asserted for every sample up to T - [_kFrameSlack].
//
// Every failure message carries the scenario string (fixture, mySeat, motion
// mode, chunk) which is the whole recipe to reproduce it: the tests use no
// randomness, so there is no seed beyond the scenario.
//
// Ambiguities found and not invented around (also in the order report):
//   - Rule 1 says the burst is "centred on that token's drawn finished
//     position". These tests read that as: the centre of the widget carrying
//     the key equals the centre of `token-<seat>-<token>`. An implementation
//     that keys a board-sized painter and draws the burst at an offset inside
//     it would fail that test while satisfying the rule; the test says so in
//     its failure text.
//   - Rule 5's restart can only be reached for the flash, and only under
//     reduced motion (see the case). A token reaches 57 once, so a second
//     landing of the same home-burst key while one shows is not reachable by
//     any legal move sequence and is not tested.
//   - Rule 3 demands a tap "at the burst's centre, away from any token", but
//     the burst is centred on a token. The tap case uses another seat's
//     token (never tappable), and the hit-test case asserts structurally that
//     no hit-test entry falls inside the decoration's render subtree.
//   - Colour, expansion and fade are asserted loosely from pixels (changed
//     pixels near gold, the seat colour and the error red hue, and the
//     extent of the changed area growing). The exact rays or particles are
//     the implementation's to choose.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/board.dart';
import 'package:ludo_client/src/theme.dart';

// ---------------------------------------------------------------------------
// Constants and fixtures
// ---------------------------------------------------------------------------

const List<int> _seats = <int>[0, 1, 2, 3];

/// The only step the clock ever advances by.
const int _kChunk = 10;

/// The named slack of the contract's "one frame of slack": 20 ms.
const int _kFrameSlack = 20;

int get _stepMs => kTokenStepDuration.inMilliseconds;
int get _stepReducedMs => kTokenStepDurationReduced.inMilliseconds;
int get _flightMs => kCaptureFlightDuration.inMilliseconds;
int get _flightReducedMs => kCaptureFlightDurationReduced.inMilliseconds;

Map<int, List<int>> _tokens({
  List<int> s0 = const <int>[-1, -1, -1, -1],
  List<int> s1 = const <int>[-1, -1, -1, -1],
  List<int> s2 = const <int>[-1, -1, -1, -1],
  List<int> s3 = const <int>[-1, -1, -1, -1],
}) => <int, List<int>>{0: s0, 1: s1, 2: s2, 3: s3};

/// Seat 1 token 0 at progress 3 and seat 3 token 2 at progress 31. Absolute
/// track square of seat 1 progress p is (13 + p) % 52 and of seat 3 progress
/// q is (39 + q) % 52, so 5 (seat 1) and 31 (seat 3) are the same square, 18.
Map<int, List<int>> _captureBefore() =>
    _tokens(s1: const <int>[3, -1, -1, -1], s3: const <int>[-1, -1, 31, -1]);

/// Seat 1 token 0 has moved 3 to 5 and seat 3 token 2 is back in its yard.
Map<int, List<int>> _captureAfter() => _tokens(s1: const <int>[5, -1, -1, -1]);

/// The captured token of the capture fixture.
const int _capturedSeat = 3;
const int _capturedToken = 2;

String _flashKey(int seat, int token) => 'board-captured-flash-$seat-$token';
String _burstKey(int seat, int token) => 'board-home-burst-$seat-$token';

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.tokens,
    required this.boundaryKey,
    this.mySeat,
    this.interactive = true,
    this.legal = const <int>{},
    this.onTokenTap,
    this.onMoveLanded,
    this.side = 400,
  });

  final Map<int, List<int>> tokens;
  final GlobalKey boundaryKey;
  final int? mySeat;
  final bool interactive;
  final Set<int> legal;
  final void Function(int token)? onTokenTap;
  final void Function(int seat, int token)? onMoveLanded;
  final double side;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Map<int, List<int>> _tokens;

  @override
  void initState() {
    super.initState();
    _tokens = widget.tokens;
  }

  void setTokens(Map<int, List<int>> next) {
    setState(() {
      _tokens = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: widget.boundaryKey,
      child: SizedBox(
        width: widget.side,
        height: widget.side,
        child: LudoBoard(
          tokens: _tokens,
          seatsInPlay: _seats,
          mySeat: widget.mySeat,
          interactive: widget.interactive,
          legal: widget.legal,
          onTokenTap: widget.onTokenTap,
          onMoveLanded: widget.onMoveLanded,
        ),
      ),
    );
  }
}

/// A mounted board plus the test clock. [now] is the millisecond count since
/// the last rebuild this case marked as zero with [begin].
class _Rig {
  _Rig({
    required this.tester,
    required this.hostKey,
    required this.boundaryKey,
    required this.scenario,
  });

  final WidgetTester tester;
  final GlobalKey<_HostState> hostKey;
  final GlobalKey boundaryKey;
  final String scenario;
  int now = 0;

  /// Hands the board a new tokens map and pumps the one zero-length frame
  /// that starts whatever that diff starts. That instant is 0 ms.
  Future<void> begin(Map<int, List<int>> next) async {
    hostKey.currentState!.setTokens(next);
    now = 0;
    await tester.pump();
  }

  /// A rebuild that does not restart the clock (a queued move, a snap).
  Future<void> push(Map<int, List<int>> next) async {
    hostKey.currentState!.setTokens(next);
    await tester.pump();
  }

  /// Advances the clock to [target] ms in [_kChunk] pumps, calling [each]
  /// after every pump with the new time.
  Future<void> advanceTo(int target, {void Function(int ms)? each}) async {
    while (now < target) {
      now += _kChunk;
      await tester.pump(const Duration(milliseconds: _kChunk));
      each?.call(now);
    }
  }
}

Future<_Rig> _mount(
  WidgetTester tester, {
  required Map<int, List<int>> tokens,
  required String fixture,
  int? mySeat,
  bool reduced = false,
  bool interactive = true,
  Set<int> legal = const <int>{},
  void Function(int token)? onTokenTap,
  void Function(int seat, int token)? onMoveLanded,
  double side = 400,
}) async {
  final GlobalKey<_HostState> hostKey = GlobalKey<_HostState>();
  final GlobalKey boundaryKey = GlobalKey();
  final Widget host = _Host(
    key: hostKey,
    tokens: tokens,
    boundaryKey: boundaryKey,
    mySeat: mySeat,
    interactive: interactive,
    legal: legal,
    onTokenTap: onTokenTap,
    onMoveLanded: onMoveLanded,
    side: side,
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: appSupportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: Center(
          child: reduced
              ? Builder(
                  builder: (BuildContext context) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(disableAnimations: true),
                    child: host,
                  ),
                )
              : host,
        ),
      ),
    ),
  );
  await tester.pump();
  return _Rig(
    tester: tester,
    hostKey: hostKey,
    boundaryKey: boundaryKey,
    scenario:
        'scenario: $fixture, mySeat=$mySeat, '
        '${reduced ? 'reduced motion' : 'normal motion'}, '
        'chunk=${_kChunk}ms, slack=${_kFrameSlack}ms',
  );
}

// ---------------------------------------------------------------------------
// Presence traces
// ---------------------------------------------------------------------------

/// Presence of keyed widgets sampled after every chunk, millisecond -> found.
class _Trace {
  _Trace(this.rig, this.keys);

  final _Rig rig;
  final List<String> keys;
  final Map<String, Map<int, bool>> samples = <String, Map<int, bool>>{};

  void sample(int ms) {
    for (final String k in keys) {
      samples.putIfAbsent(k, () => <int, bool>{})[ms] = rig.tester.any(
        find.byKey(Key(k)),
      );
    }
  }

  /// Runs the clock to [target] ms, sampling at every chunk (and once now).
  Future<void> run(int target) async {
    sample(rig.now);
    await rig.advanceTo(target, each: sample);
  }

  /// Compact timeline: "present 290..630, absent otherwise".
  String describe(String k) {
    final Map<int, bool> s = samples[k] ?? <int, bool>{};
    final List<int> times = s.keys.toList()..sort();
    final List<String> spans = <String>[];
    int? from;
    int? last;
    for (final int t in times) {
      if (s[t]!) {
        from ??= t;
        last = t;
      } else if (from != null) {
        spans.add('$from..$last');
        from = null;
      }
    }
    if (from != null) {
      spans.add('$from..$last');
    }
    return spans.isEmpty
        ? 'never present'
        : 'present at ms ${spans.join(', ')}';
  }

  /// Asserts [k] has the given presence at every sample in [from]..[to].
  void expectRange(
    String k, {
    required int from,
    required int to,
    required bool present,
    required String why,
  }) {
    final Map<int, bool> s = samples[k] ?? <int, bool>{};
    final List<int> times =
        s.keys.where((int t) => t >= from && t <= to).toList()..sort();
    expect(
      times,
      isNotEmpty,
      reason: 'test bug: no samples of $k between $from and $to ms',
    );
    for (final int t in times) {
      if (s[t] != present) {
        fail(
          'Expected $k to be ${present ? 'present' : 'absent'} at every '
          'sample from $from ms to $to ms ($why), but at $t ms it was '
          '${s[t]! ? 'present' : 'absent'}. Timeline of $k: ${describe(k)}. '
          '${rig.scenario}',
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Pixels, hit tests, semantics
// ---------------------------------------------------------------------------

class _Shot {
  _Shot(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  Color at(int x, int y) {
    final int i = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }
}

Future<_Shot> _shot(_Rig rig) async {
  final RenderRepaintBoundary boundary =
      rig.boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  ui.Image? image;
  ByteData? bytes;
  await rig.tester.runAsync(() async {
    image = await boundary.toImage(pixelRatio: 1.0);
    bytes = await image!.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  });
  return _Shot(image!.width, image!.height, bytes!);
}

/// Centre of [finder] in board-local logical pixels.
Offset _localCentre(_Rig rig, Finder finder) {
  final Offset origin = rig.tester.getTopLeft(find.byType(LudoBoard));
  return rig.tester.getCenter(finder) - origin;
}

int _l1(Color a, Color b) =>
    ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255 ~/ 1;

class _Changed {
  _Changed(this.x, this.y, this.after, this.before);

  final int x;
  final int y;
  final Color after;
  final Color before;
}

/// Pixels inside the square of half-width [half] around [centre] whose colour
/// differs between [base] (the quiet frame) and [shot] (the frame under test)
/// by more than [minDiff] summed over the three channels (0 to 765).
List<_Changed> _changedAround(
  _Shot shot,
  _Shot base,
  Offset centre,
  double half, {
  int minDiff = 30,
}) {
  final List<_Changed> out = <_Changed>[];
  final int x0 = (centre.dx - half).floor().clamp(0, shot.width - 1);
  final int x1 = (centre.dx + half).ceil().clamp(0, shot.width - 1);
  final int y0 = (centre.dy - half).floor().clamp(0, shot.height - 1);
  final int y1 = (centre.dy + half).ceil().clamp(0, shot.height - 1);
  for (int y = y0; y <= y1; y++) {
    for (int x = x0; x <= x1; x++) {
      final Color a = shot.at(x, y);
      final Color b = base.at(x, y);
      if (_l1(a, b) > minDiff) {
        out.add(_Changed(x, y, a, b));
      }
    }
  }
  return out;
}

/// True when [c] has a hue within [tolerance] degrees of [target] and enough
/// saturation to have a hue at all.
bool _hueNear(Color c, Color target, {double tolerance = 25}) {
  final HSVColor h = HSVColor.fromColor(c);
  if (h.saturation < 0.2 || h.value < 0.25) {
    return false;
  }
  final double t = HSVColor.fromColor(target).hue;
  final double d = (h.hue - t).abs();
  return (d > 180 ? 360 - d : d) <= tolerance;
}

double _maxRadius(List<_Changed> pixels, Offset centre) {
  double r = 0;
  for (final _Changed p in pixels) {
    final double d = (Offset(p.x + 0.5, p.y + 0.5) - centre).distance;
    if (d > r) {
      r = d;
    }
  }
  return r;
}

bool _isUnder(RenderObject node, RenderObject root) {
  RenderObject? o = node;
  while (o != null) {
    if (identical(o, root)) {
      return true;
    }
    o = o.parent;
  }
  return false;
}

/// How many hit-test entries at [global] land inside the render subtree of
/// the widget keyed [key].
int _hitsInside(WidgetTester tester, Offset global, String key) {
  final RenderObject root = tester.renderObject(find.byKey(Key(key)));
  final HitTestResult result = tester.hitTestOnBinding(global);
  int n = 0;
  for (final HitTestEntry e in result.path) {
    final HitTestTarget t = e.target;
    if (t is RenderObject && _isUnder(t, root)) {
      n++;
    }
  }
  return n;
}

int _semanticsCount(WidgetTester tester) {
  final SemanticsNode root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  int n = 0;
  void visit(SemanticsNode node) {
    n++;
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return n;
}

List<String> _semanticsMentioning(WidgetTester tester, List<String> needles) {
  final SemanticsNode root = tester
      .binding
      .renderViews
      .first
      .owner!
      .semanticsOwner!
      .rootSemanticsNode!;
  final List<String> hits = <String>[];
  void visit(SemanticsNode node) {
    final String text = '${node.identifier} ${node.label} ${node.value}'
        .toLowerCase();
    for (final String n in needles) {
      if (text.contains(n)) {
        hits.add('node ${node.id}: "$text"');
      }
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return hits;
}

// ---------------------------------------------------------------------------
// Fixtures for the home burst
// ---------------------------------------------------------------------------

/// Token [token] of [seat] at progress [from] (five steps short of home by
/// default) and everything else in the yard.
Map<int, List<int>> _homeBefore(int seat, int token, {int from = 52}) {
  final List<int> row = <int>[-1, -1, -1, -1];
  row[token] = from;
  return _tokens(
    s0: seat == 0 ? row : const <int>[-1, -1, -1, -1],
    s1: seat == 1 ? row : const <int>[-1, -1, -1, -1],
    s2: seat == 2 ? row : const <int>[-1, -1, -1, -1],
    s3: seat == 3 ? row : const <int>[-1, -1, -1, -1],
  );
}

Map<int, List<int>> _homeAfter(int seat, int token) =>
    _homeBefore(seat, token, from: 57);

void main() {
  // =========================================================================
  // Rule 2: the captured flash
  // =========================================================================
  group('rule 2: captured flash, my token only', () {
    // Kills: no flash at all; a flash that starts before the mover's last
    // step has landed; a flash present for the whole flight but dropped the
    // instant the disc lands (no linger); a linger that never ends or lasts
    // longer than 300 ms plus slack.
    testWidgets(
      'my token captured: absent before the mover lands, present all flight, '
      'present 100 ms after landing, gone by landing + 300 ms + slack',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: _capturedSeat,
        );
        final String key = _flashKey(_capturedSeat, _capturedToken);
        final _Trace trace = _Trace(rig, <String>[key]);
        await rig.begin(_captureAfter());
        final int landed = 2 * _stepMs;
        final int flightEnd = landed + _flightMs;
        await trace.run(flightEnd + 300 + _kFrameSlack + 3 * _kChunk);

        trace.expectRange(
          key,
          from: 0,
          to: landed - _kChunk,
          present: false,
          why: 'the mover has not landed yet (last step ends at $landed ms)',
        );
        trace.expectRange(
          key,
          from: landed + _kFrameSlack,
          to: flightEnd - _kFrameSlack,
          present: true,
          why: 'the captured token is flying ($landed to $flightEnd ms)',
        );
        trace.expectRange(
          key,
          from: flightEnd + 100 - _kChunk,
          to: flightEnd + 100,
          present: true,
          why: 'the ring stays 300 ms after the disc lands at $flightEnd ms',
        );
        trace.expectRange(
          key,
          from: flightEnd + 250,
          to: flightEnd + 250,
          present: true,
          why: 'still fading, not yet gone, 250 ms after landing',
        );
        trace.expectRange(
          key,
          from: flightEnd + 300 + _kFrameSlack,
          to: flightEnd + 300 + _kFrameSlack + 3 * _kChunk,
          present: false,
          why: 'the key is gone 300 ms after landing, plus slack',
        );
      },
    );

    // Kills: a flash that is drawn for a token of any other seat, for the
    // mover's own seat, or for a spectator.
    for (final int? mySeat in <int?>[null, 0, 1, 2]) {
      testWidgets('a capture of seat 3 token 2 with mySeat=$mySeat: no '
          'board-captured-flash key at any sample of the whole flight', (
        WidgetTester tester,
      ) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: mySeat,
        );
        final List<String> keys = <String>[
          for (final int s in _seats)
            for (int t = 0; t < 4; t++) _flashKey(s, t),
        ];
        final _Trace trace = _Trace(rig, keys);
        await rig.begin(_captureAfter());
        await trace.run(2 * _stepMs + _flightMs + 400);
        for (final String k in keys) {
          trace.expectRange(
            k,
            from: 0,
            to: 2 * _stepMs + _flightMs + 400,
            present: false,
            why:
                'only the viewer\'s own captured token carries a flash, '
                'and mySeat is $mySeat while seat 3 was captured',
          );
        }
        // The flight itself still happens exactly as before: the captured
        // token ends in its yard slot.
        expect(
          tester.any(find.byKey(const Key('token-3-2'))),
          isTrue,
          reason: 'token-3-2 must still be drawn, flying as today',
        );
      });
    }

    // Kills: a flash that is dropped under reduced motion; a flash that
    // lingers the long default (300 ms) instead of 250 ms; one that never
    // ends under reduced motion.
    testWidgets(
      'reduced motion: the flash is drawn during the 120 ms flight and is '
      'gone by landing + 250 ms + slack',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: _capturedSeat,
          reduced: true,
        );
        final String key = _flashKey(_capturedSeat, _capturedToken);
        final _Trace trace = _Trace(rig, <String>[key]);
        await rig.begin(_captureAfter());
        final int landed = 2 * _stepReducedMs;
        final int flightEnd = landed + _flightReducedMs;
        await trace.run(flightEnd + 250 + _kFrameSlack + 3 * _kChunk);

        trace.expectRange(
          key,
          from: 0,
          to: landed - _kChunk,
          present: false,
          why: 'the mover has not landed yet (last step ends at $landed ms)',
        );
        final bool duringFlight = trace.samples[key]!.entries.any(
          (MapEntry<int, bool> e) =>
              e.value && e.key > landed && e.key <= flightEnd,
        );
        expect(
          duringFlight,
          isTrue,
          reason:
              'Expected the flash to be drawn at least once during the '
              '$_flightReducedMs ms reduced-motion flight '
              '($landed to $flightEnd ms); it never was. Timeline: '
              '${trace.describe(key)}. ${rig.scenario}',
        );
        trace.expectRange(
          key,
          from: flightEnd + 100 - _kChunk,
          to: flightEnd + 100,
          present: true,
          why: 'the reduced linger is 250 ms after landing at $flightEnd ms',
        );
        trace.expectRange(
          key,
          from: flightEnd + 250 + _kFrameSlack,
          to: flightEnd + 250 + _kFrameSlack + 3 * _kChunk,
          present: false,
          why: 'gone 250 ms after landing under reduced motion, plus slack',
        );
      },
    );

    // Kills: a flash drawn off the disc; a flash that does not follow the
    // flying token.
    testWidgets(
      'the flash is centred on the flying token, at two moments of the flight',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: _capturedSeat,
        );
        final String key = _flashKey(_capturedSeat, _capturedToken);
        await rig.begin(_captureAfter());
        for (final int at in <int>[2 * _stepMs + 100, 2 * _stepMs + 250]) {
          await rig.advanceTo(at);
          expect(
            find.byKey(Key(key)),
            findsOneWidget,
            reason: '$key must be in the tree at $at ms. ${rig.scenario}',
          );
          final Offset flash = tester.getCenter(find.byKey(Key(key)));
          final Offset token = tester.getCenter(
            find.byKey(const Key('token-3-2')),
          );
          expect(
            (flash - token).distance <= 1.5,
            isTrue,
            reason:
                'Expected $key to be centred on token-3-2 at $at ms '
                '(token centre $token), but its centre is $flash, '
                '${(flash - token).distance.toStringAsFixed(2)} px away. '
                'If the key sits on a board-sized layer that paints the ring '
                'at an offset, that is the ambiguity named at the top of '
                'this file. ${rig.scenario}',
          );
        }
      },
    );

    // Kills: a flash that is only a colour change (P9: colour is never the
    // only signal; the outward pulse is the motion half), and a ring whose
    // colour is not the error red.
    testWidgets(
      'pixels: mid-flight there are red-hue pixels that the same frame '
      'without the flash does not have, and the red area grows outward',
      (WidgetTester tester) async {
        // A: the capture seen by the captured seat. B: the same capture seen
        // by a spectator. mySeat 3 and mySeat null both use view rotation 0,
        // so the flying token is at the same place in both.
        final _Rig a = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: _capturedSeat,
          side: 500,
        );
        await a.begin(_captureAfter());
        final int landed = 2 * _stepMs;
        final List<_Shot> shotsA = <_Shot>[];
        final List<Offset> centresA = <Offset>[];
        for (final int dt in <int>[30, 150]) {
          await a.advanceTo(landed + dt);
          expect(
            find.byKey(Key(_flashKey(_capturedSeat, _capturedToken))),
            findsOneWidget,
            reason:
                'Expected the flash to be drawn $dt ms into the flight '
                'before its pixels are checked. ${a.scenario}',
          );
          shotsA.add(await _shot(a));
          centresA.add(_localCentre(a, find.byKey(const Key('token-3-2'))));
        }

        final _Rig b = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'spectator baseline of the same capture',
          mySeat: null,
          side: 500,
        );
        await b.begin(_captureAfter());
        final List<_Shot> shotsB = <_Shot>[];
        for (final int dt in <int>[30, 150]) {
          await b.advanceTo(landed + dt);
          shotsB.add(await _shot(b));
        }

        final double half = 500 / 15 * 1.6;
        final List<List<_Changed>> red = <List<_Changed>>[];
        for (int i = 0; i < 2; i++) {
          final List<_Changed> changed = _changedAround(
            shotsA[i],
            shotsB[i],
            centresA[i],
            half,
          );
          red.add(
            changed
                .where(
                  (_Changed p) =>
                      _hueNear(p.after, LudoColors.error, tolerance: 22),
                )
                .toList(),
          );
        }
        expect(
          red[1].length >= 8,
          isTrue,
          reason:
              'Expected at least 8 pixels of the error-red hue '
              '(${LudoColors.error}) around the flying token 150 ms into the '
              'flight that the spectator frame lacks; found '
              '${red[1].length}. ${a.scenario}',
        );
        final double early = _maxRadius(red[0], centresA[0]);
        final double late = _maxRadius(red[1], centresA[1]);
        expect(
          late >= early + 1.0,
          isTrue,
          reason:
              'Expected the red area to pulse outward: its reach from the '
              'token centre at 30 ms into the flight was '
              '${early.toStringAsFixed(1)} px and at 150 ms '
              '${late.toStringAsFixed(1)} px (needs to grow by 1 px). '
              'Only the outward half of the signal is motion (P9). '
              '${a.scenario}',
        );
      },
    );

    // Kills: a flash restarted never (two stacked), or a restart that does
    // not extend the life. Reachable only under reduced motion: the chain is
    // a capture (flight ends 180 ms, ring lingers to 430 ms), my token
    // leaves the yard, steps once more, and is captured again, the second
    // flight starting at 270 ms while the first ring still lingers. Under
    // normal motion the second flight cannot start before the first ring is
    // gone, so the case does not exist there.
    testWidgets(
      'rule 5: a second capture of the same token while its ring still '
      'lingers keeps exactly one flash and restarts its life',
      (WidgetTester tester) async {
        // Seat 3 progress 0 and 1 are absolute 39 and 40. Seat 1 progress 26
        // and 27 are the same squares (13 + 26 = 39). Square 39 is a safe
        // entry square, so the second capture is on 40.
        final Map<int, List<int>> s0 = _tokens(
          s1: const <int>[3, 26, -1, -1],
          s3: const <int>[-1, -1, 31, -1],
        );
        final _Rig rig = await _mount(
          tester,
          tokens: s0,
          fixture:
              'capture of seat 3 token 2, then it re-enters, steps to 1 and '
              'is captured by seat 1 token 1 moving 26 to 27',
          mySeat: 3,
          reduced: true,
        );
        final String key = _flashKey(3, 2);
        final List<int> counts = <int>[];
        final _Trace trace = _Trace(rig, <String>[key]);
        void both(int ms) {
          trace.sample(ms);
          counts.add(tester.widgetList(find.byKey(Key(key))).length);
        }

        await rig.begin(
          _tokens(
            s1: const <int>[5, 26, -1, -1],
            s3: const <int>[-1, -1, -1, -1],
          ),
        );
        // Queued behind the first capture, in order.
        await rig.push(
          _tokens(
            s1: const <int>[5, 26, -1, -1],
            s3: const <int>[-1, -1, 0, -1],
          ),
        );
        await rig.push(
          _tokens(
            s1: const <int>[5, 26, -1, -1],
            s3: const <int>[-1, -1, 1, -1],
          ),
        );
        await rig.push(
          _tokens(
            s1: const <int>[5, 27, -1, -1],
            s3: const <int>[-1, -1, -1, -1],
          ),
        );
        both(rig.now);
        await rig.advanceTo(1000, each: both);

        expect(
          counts.every((int c) => c <= 1),
          isTrue,
          reason:
              'Expected at most one $key in the tree at every sample (a '
              'second landing restarts, never stacks); saw counts '
              '${counts.toSet()}. Timeline: ${trace.describe(key)}. '
              '${rig.scenario}',
        );
        // Measured chain (C-252 rule 6 half-duration steps while moves wait):
        // the first capture lands at 60 ms, its flight ends at 180 ms, so
        // without a restart the first ring is gone at 180 + 250 = 430 ms. My
        // token re-enters (lands 210), steps (230), and is captured again by
        // a move landing at 270 ms, flying 270..390 ms, so a restarted ring
        // lasts to 390 + 250 = 640 ms.
        trace.expectRange(
          key,
          from: 470,
          to: 600,
          present: true,
          why:
              'the second capture restarted the ring, so it outlives the '
              'first ring\'s 430 ms end',
        );
        trace.expectRange(
          key,
          from: 390 + 250 + _kFrameSlack + 2 * _kChunk,
          to: 1000,
          present: false,
          why: 'the restarted ring ends 250 ms after the second landing',
        );
      },
    );
  });

  // =========================================================================
  // Rule 1: the home burst
  // =========================================================================
  group('rule 1: home burst', () {
    for (final (int seat, int token, int? mySeat, String who)
        in <(int, int, int?, String)>[
          (0, 0, 0, 'my seat'),
          (2, 1, 0, 'another seat'),
          (1, 3, null, 'a spectator watching'),
        ]) {
      // Kills: no burst; a burst drawn before the last step lands; a burst
      // that is never removed; a burst limited to my seat.
      testWidgets(
        'seat $seat token $token reaches 57 ($who): absent during the walk, '
        'present right after the last step, gone by landing + 700 ms + slack',
        (WidgetTester tester) async {
          final _Rig rig = await _mount(
            tester,
            tokens: _homeBefore(seat, token),
            fixture: 'seat $seat token $token walks 52 to 57',
            mySeat: mySeat,
          );
          final String key = _burstKey(seat, token);
          final _Trace trace = _Trace(rig, <String>[key]);
          await rig.begin(_homeAfter(seat, token));
          final int landed = 5 * _stepMs;
          await trace.run(landed + 700 + _kFrameSlack + 3 * _kChunk);

          trace.expectRange(
            key,
            from: 0,
            to: landed - _kChunk,
            present: false,
            why: 'the token is still walking (last step ends at $landed ms)',
          );
          trace.expectRange(
            key,
            from: landed + _kChunk,
            to: landed + 650,
            present: true,
            why: 'the burst lives 700 ms from the landing at $landed ms',
          );
          trace.expectRange(
            key,
            from: landed + 700 + _kFrameSlack,
            to: landed + 700 + _kFrameSlack + 3 * _kChunk,
            present: false,
            why: 'the key is gone 700 ms after the landing, plus slack',
          );
        },
      );
    }

    // Kills: a burst dropped under reduced motion; a reduced life of 700 ms.
    for (final int seat in <int>[0, 3]) {
      testWidgets(
        'reduced motion, seat $seat: the burst is still drawn and is gone by '
        'landing + 250 ms + slack',
        (WidgetTester tester) async {
          final _Rig rig = await _mount(
            tester,
            tokens: _homeBefore(seat, 0),
            fixture: 'seat $seat token 0 walks 52 to 57',
            mySeat: 0,
            reduced: true,
          );
          final String key = _burstKey(seat, 0);
          final _Trace trace = _Trace(rig, <String>[key]);
          await rig.begin(_homeAfter(seat, 0));
          final int landed = 5 * _stepReducedMs;
          await trace.run(landed + 250 + _kFrameSlack + 3 * _kChunk);

          trace.expectRange(
            key,
            from: 0,
            to: landed - _kChunk,
            present: false,
            why: 'the token is still walking (last step ends at $landed ms)',
          );
          trace.expectRange(
            key,
            from: landed + _kChunk,
            to: landed + 200,
            present: true,
            why: 'the reduced burst lives 250 ms from the landing',
          );
          trace.expectRange(
            key,
            from: landed + 250 + _kFrameSlack,
            to: landed + 250 + _kFrameSlack + 3 * _kChunk,
            present: false,
            why: 'gone 250 ms after the landing under reduced motion',
          );
        },
      );
    }

    // Kills: a burst for any other landing (progress 56, a yard exit, a
    // plain capture landing), or for a different token than the mover.
    testWidgets(
      'a move that lands on 56, a yard exit and a capture landing draw no '
      'home burst at any sample',
      (WidgetTester tester) async {
        final List<String> keys = <String>[
          for (final int s in _seats)
            for (int t = 0; t < 4; t++) _burstKey(s, t),
        ];
        final _Rig rig = await _mount(
          tester,
          tokens: _tokens(
            s0: const <int>[50, -1, -1, -1],
            s1: const <int>[3, -1, -1, -1],
            s3: const <int>[-1, -1, 31, -1],
          ),
          fixture: 'seat 0 token 0 50 to 56, seat 1 token 1 yard exit, capture',
          mySeat: 0,
        );
        final _Trace trace = _Trace(rig, keys);
        await rig.begin(
          _tokens(
            s0: const <int>[56, -1, -1, -1],
            s1: const <int>[3, -1, -1, -1],
            s3: const <int>[-1, -1, 31, -1],
          ),
        );
        await rig.push(
          _tokens(
            s0: const <int>[56, -1, -1, -1],
            s1: const <int>[3, 0, -1, -1],
            s3: const <int>[-1, -1, 31, -1],
          ),
        );
        await rig.push(
          _tokens(
            s0: const <int>[56, -1, -1, -1],
            s1: const <int>[5, 0, -1, -1],
            s3: const <int>[-1, -1, -1, -1],
          ),
        );
        await trace.run(2000);
        for (final String k in keys) {
          trace.expectRange(
            k,
            from: 0,
            to: 2000,
            present: false,
            why: 'no move in this scenario ends at progress 57',
          );
        }
      },
    );

    // Kills: a burst centred on the wrong place, e.g. the cell centre
    // ignoring the finished fan slot, or on the board centre.
    testWidgets(
      'the burst is centred on the drawn token, for four token indices of '
      'one seat',
      (WidgetTester tester) async {
        for (int token = 0; token < 4; token++) {
          final _Rig rig = await _mount(
            tester,
            tokens: _homeBefore(2, token),
            fixture: 'seat 2 token $token walks 52 to 57',
            mySeat: 0,
          );
          await rig.begin(_homeAfter(2, token));
          await rig.advanceTo(5 * _stepMs + 100);
          final Finder burst = find.byKey(Key(_burstKey(2, token)));
          expect(
            burst,
            findsOneWidget,
            reason:
                'Expected exactly one ${_burstKey(2, token)} 100 ms after '
                'the landing. ${rig.scenario}',
          );
          final Offset b = tester.getCenter(burst);
          final Offset t = tester.getCenter(find.byKey(Key('token-2-$token')));
          expect(
            (b - t).distance <= 1.5,
            isTrue,
            reason:
                'Expected ${_burstKey(2, token)} centred on token-2-$token '
                '(centre $t), but its centre is $b, '
                '${(b - t).distance.toStringAsFixed(2)} px away. If the key '
                'sits on a board-sized layer that paints the burst at an '
                'offset, that is the ambiguity named at the top of this '
                'file. ${rig.scenario}',
          );
        }
      },
    );

    // Kills: a burst sized in fixed pixels.
    testWidgets(
      'the burst scales with the board: the same moment on a 300 and a 500 '
      'logical pixel board differs in size by 500 / 300',
      (WidgetTester tester) async {
        final Map<double, Size> sizes = <double, Size>{};
        for (final double side in <double>[300, 500]) {
          final _Rig rig = await _mount(
            tester,
            tokens: _homeBefore(1, 0),
            fixture: 'seat 1 token 0 walks 52 to 57 on a ${side}px board',
            mySeat: 0,
            side: side,
          );
          await rig.begin(_homeAfter(1, 0));
          await rig.advanceTo(5 * _stepMs + 200);
          final Finder burst = find.byKey(Key(_burstKey(1, 0)));
          expect(
            burst,
            findsOneWidget,
            reason:
                'Expected ${_burstKey(1, 0)} on the ${side}px board 200 ms '
                'after the landing. ${rig.scenario}',
          );
          sizes[side] = tester.getSize(burst);
        }
        final double ratio = sizes[500]!.width / sizes[300]!.width;
        expect(
          (ratio - 500 / 300).abs() < 0.08,
          isTrue,
          reason:
              'Expected the burst width to scale by ${500 / 300} between a '
              '300 px and a 500 px board (no fixed pixels); got '
              '${sizes[300]} and ${sizes[500]}, ratio '
              '${ratio.toStringAsFixed(3)}. Scenario: seat 1 token 0 walks '
              '52 to 57, sampled 200 ms after the landing.',
        );
      },
    );

    // Kills: a burst that is one flat colour, one that does not use gold or
    // the seat colour, one that does not expand, one that does not fade.
    testWidgets(
      'pixels: gold and seat-colour pixels appear around the home token, '
      'the burst reaches further out later, and it fades toward its end',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _homeBefore(1, 0),
          fixture: 'seat 1 token 0 walks 52 to 57',
          mySeat: 3,
          side: 500,
        );
        await rig.begin(_homeAfter(1, 0));
        final int landed = 5 * _stepMs;
        final Map<int, _Shot> shots = <int, _Shot>{};
        for (final int dt in <int>[100, 350, 650]) {
          await rig.advanceTo(landed + dt);
          expect(
            find.byKey(Key(_burstKey(1, 0))),
            findsOneWidget,
            reason:
                'Expected the burst in the tree $dt ms after the landing '
                'before its pixels are checked. ${rig.scenario}',
          );
          shots[dt] = await _shot(rig);
        }
        await rig.advanceTo(landed + 700 + _kFrameSlack + 4 * _kChunk);
        expect(
          find.byKey(Key(_burstKey(1, 0))),
          findsNothing,
          reason:
              'Expected the burst gone before the quiet baseline frame is '
              'taken. ${rig.scenario}',
        );
        final _Shot quiet = await _shot(rig);
        final Offset centre = _localCentre(
          rig,
          find.byKey(const Key('token-1-0')),
        );
        final double half = 500 / 15 * 3.0;

        final List<_Changed> early = _changedAround(
          shots[100]!,
          quiet,
          centre,
          half,
        );
        expect(
          early.length >= 30,
          isTrue,
          reason:
              'Expected at least 30 pixels around the token to differ from '
              'the quiet frame 100 ms into the burst; found '
              '${early.length}. ${rig.scenario}',
        );
        final int gold = early
            .where((_Changed p) => _hueNear(p.after, LudoColors.gold))
            .length;
        expect(
          gold >= 3,
          isTrue,
          reason:
              'Expected at least 3 changed pixels of the gold hue '
              '(${LudoColors.gold}) 100 ms into the burst; found $gold. '
              '${rig.scenario}',
        );
        final int seatHue = early
            .where((_Changed p) => _hueNear(p.after, LudoColors.seats[1]))
            .length;
        expect(
          seatHue >= 3,
          isTrue,
          reason:
              'Expected at least 3 changed pixels of seat 1\'s colour hue '
              '(${LudoColors.seats[1]}) 100 ms into the burst; found '
              '$seatHue. ${rig.scenario}',
        );

        final List<_Changed> mid = _changedAround(
          shots[350]!,
          quiet,
          centre,
          half,
        );
        final double rEarly = _maxRadius(early, centre);
        final double rMid = _maxRadius(mid, centre);
        expect(
          rMid >= rEarly + 1.0,
          isTrue,
          reason:
              'Expected the burst to expand outward: changed area reach '
              '${rEarly.toStringAsFixed(1)} px at 100 ms, '
              '${rMid.toStringAsFixed(1)} px at 350 ms (needs +1 px). '
              '${rig.scenario}',
        );

        int peak(List<_Changed> px) {
          int m = 0;
          for (final _Changed p in px) {
            final int d = _l1(p.after, p.before);
            if (d > m) {
              m = d;
            }
          }
          return m;
        }

        final List<_Changed> late = _changedAround(
          shots[650]!,
          quiet,
          centre,
          half,
          minDiff: 1,
        );
        final int peakEarly = peak(early);
        final int peakLate = peak(late);
        expect(
          peakLate < peakEarly,
          isTrue,
          reason:
              'Expected the burst to fade: strongest pixel change against '
              'the quiet frame was $peakEarly at 100 ms and $peakLate at '
              '650 ms (needs to fall). ${rig.scenario}',
        );
      },
    );
  });

  // =========================================================================
  // Rule 4: only real landings
  // =========================================================================
  group('rule 4: snaps and first frames draw nothing', () {
    List<String> everyKey() => <String>[
      for (final int s in _seats)
        for (int t = 0; t < 4; t++) ...<String>[
          _burstKey(s, t),
          _flashKey(s, t),
        ],
    ];

    // Kills: a burst on an unrecognised diff (a token jumping -1 to 57).
    testWidgets('a token jumping from the yard straight to 57 is a snap: no '
        'burst and no flash', (WidgetTester tester) async {
      final _Rig rig = await _mount(
        tester,
        tokens: _tokens(),
        fixture: 'seat 0 token 0 from -1 straight to 57',
        mySeat: 0,
      );
      final _Trace trace = _Trace(rig, everyKey());
      await rig.begin(_homeAfter(0, 0));
      await trace.run(1500);
      for (final String k in everyKey()) {
        trace.expectRange(
          k,
          from: 0,
          to: 1500,
          present: false,
          why: 'a -1 to 57 diff is not a move the board animates (a snap)',
        );
      }
    });

    // Kills: a burst when a resume hands the board a whole new tokens map,
    // including tokens that sit at 57.
    testWidgets(
      'a whole new tokens map (a resume) with finished tokens and a vanished '
      'token draws no burst and no flash',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'resume: every seat changes at once, seat 2 has two at 57',
          mySeat: 3,
        );
        final _Trace trace = _Trace(rig, everyKey());
        await rig.begin(
          _tokens(
            s0: const <int>[20, 21, -1, 57],
            s1: const <int>[9, 57, -1, -1],
            s2: const <int>[57, 57, 4, -1],
            s3: const <int>[0, -1, -1, 12],
          ),
        );
        await trace.run(1500);
        for (final String k in everyKey()) {
          trace.expectRange(
            k,
            from: 0,
            to: 1500,
            present: false,
            why: 'a multi-seat diff is a snap, never a landing',
          );
        }
      },
    );

    // Kills: a flash when MY token alone vanishes with no mover (nothing the
    // board can fly home from a capture it cannot see).
    testWidgets(
      'my token returning to the yard with no mover is a snap: no flash',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 3 token 2 from 31 back to -1, nothing else changes',
          mySeat: 3,
        );
        final _Trace trace = _Trace(rig, everyKey());
        await rig.begin(_tokens(s1: const <int>[3, -1, -1, -1]));
        await trace.run(1500);
        for (final String k in everyKey()) {
          trace.expectRange(
            k,
            from: 0,
            to: 1500,
            present: false,
            why: 'no mover means there is no capture flight to decorate',
          );
        }
      },
    );

    // Kills: a burst on the first build or on the finished board's own first
    // frame.
    for (final bool interactive in <bool>[true, false]) {
      testWidgets(
        'first build with tokens already at 57 (interactive=$interactive): '
        'no burst and no flash on the first frame or later',
        (WidgetTester tester) async {
          final _Rig rig = await _mount(
            tester,
            tokens: _tokens(
              s0: const <int>[57, 57, 57, 57],
              s1: const <int>[57, 57, 57, 12],
              s2: const <int>[57, -1, -1, -1],
              s3: const <int>[3, 4, 5, 6],
            ),
            fixture: 'first build, finished tokens, interactive=$interactive',
            mySeat: 0,
            interactive: interactive,
          );
          final _Trace trace = _Trace(rig, everyKey());
          await trace.run(1500);
          for (final String k in everyKey()) {
            trace.expectRange(
              k,
              from: 0,
              to: 1500,
              present: false,
              why: 'a first build is not a landing',
            );
          }
        },
      );
    }

    // Kills: a burst re-drawn when the same tokens map is delivered again
    // after the first burst is gone (a replayed message).
    testWidgets(
      'the same tokens delivered again after a landing draws no second burst',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _homeBefore(1, 0),
          fixture: 'seat 1 token 0 walks 52 to 57, then the same map again',
          mySeat: 0,
        );
        final String key = _burstKey(1, 0);
        final _Trace trace = _Trace(rig, <String>[key]);
        await rig.begin(_homeAfter(1, 0));
        final int landed = 5 * _stepMs;
        await trace.run(landed + 700 + 100);
        await rig.push(_homeAfter(1, 0));
        await rig.push(_homeAfter(1, 0));
        await trace.run(landed + 700 + 1500);
        trace.expectRange(
          key,
          from: landed + 700 + _kFrameSlack,
          to: landed + 700 + 1500,
          present: false,
          why: 'an unchanged tokens map is not a move',
        );
      },
    );

    // Kills: a burst surviving a snap.
    testWidgets(
      'a snap while the home burst is showing removes it on the next frame',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _homeBefore(1, 0),
          fixture: 'seat 1 token 0 walks 52 to 57, snap 200 ms into the burst',
          mySeat: 0,
        );
        final String key = _burstKey(1, 0);
        final _Trace trace = _Trace(rig, <String>[key]);
        await rig.begin(_homeAfter(1, 0));
        final int landed = 5 * _stepMs;
        await trace.run(landed + 200);
        expect(
          find.byKey(Key(key)),
          findsOneWidget,
          reason:
              'test precondition: the burst must be showing 200 ms after '
              'the landing. ${rig.scenario}',
        );
        // Two seats change at once: not a single move, so a snap.
        await rig.push(
          _tokens(
            s0: const <int>[10, -1, -1, -1],
            s1: const <int>[57, -1, -1, -1],
            s2: const <int>[3, -1, -1, -1],
          ),
        );
        final int snapAt = rig.now;
        trace.sample(snapAt + 1);
        trace.expectRange(
          key,
          from: snapAt + 1,
          to: snapAt + 1,
          present: false,
          why: 'a snap removes a showing burst at once',
        );
        await trace.run(landed + 700 + 200);
        trace.expectRange(
          key,
          from: snapAt + 1,
          to: landed + 700 + 200,
          present: false,
          why: 'the burst stays gone after the snap',
        );
      },
    );

    // Kills: a flash surviving a snap mid-flight and mid-linger.
    for (final (String moment, int at) in <(String, int)>[
      ('mid-flight', 2 * 140 + 150),
      ('during the linger', 2 * 140 + 360 + 100),
    ]) {
      testWidgets('a snap $moment removes the flash on the next frame', (
        WidgetTester tester,
      ) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'capture of seat 3 token 2, snap $moment at $at ms',
          mySeat: 3,
        );
        final String key = _flashKey(3, 2);
        final _Trace trace = _Trace(rig, <String>[key]);
        await rig.begin(_captureAfter());
        await trace.run(at);
        expect(
          find.byKey(Key(key)),
          findsOneWidget,
          reason:
              'test precondition: the flash must be showing at $at ms '
              '($moment). ${rig.scenario}',
        );
        await rig.push(
          _tokens(
            s0: const <int>[10, -1, -1, -1],
            s1: const <int>[9, -1, -1, -1],
            s2: const <int>[3, -1, -1, -1],
          ),
        );
        final int snapAt = rig.now;
        trace.sample(snapAt + 1);
        await trace.run(snapAt + 1200);
        trace.expectRange(
          key,
          from: snapAt + 1,
          to: snapAt + 1200,
          present: false,
          why: 'a snap removes a showing flash at once',
        );
      });
    }

    // Kills: a Timer or ticker outliving the board (the test binding fails
    // the case at teardown for a pending timer), or a setState after
    // dispose (an exception).
    testWidgets(
      'removing the board while a burst and a flash are showing leaves no '
      'timer and throws nothing',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _tokens(
            s1: const <int>[3, 52, -1, -1],
            s3: const <int>[-1, -1, 31, -1],
          ),
          fixture: 'capture then home landing, board removed mid-life',
          mySeat: 3,
        );
        await rig.begin(
          _tokens(
            s1: const <int>[5, 52, -1, -1],
            s3: const <int>[-1, -1, -1, -1],
          ),
        );
        await rig.push(
          _tokens(
            s1: const <int>[5, 57, -1, -1],
            s3: const <int>[-1, -1, -1, -1],
          ),
        );
        // The capture flight is 280..640 ms; the board is removed inside it,
        // then a second mount is removed inside a burst.
        await rig.advanceTo(400);
        expect(
          find.byKey(Key(_flashKey(3, 2))),
          findsOneWidget,
          reason: 'precondition: flash showing at 400 ms. ${rig.scenario}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));

        final _Rig rig2 = await _mount(
          tester,
          tokens: _homeBefore(1, 0),
          fixture: 'home landing, board removed mid-burst',
          mySeat: 3,
        );
        await rig2.begin(_homeAfter(1, 0));
        await rig2.advanceTo(5 * _stepMs + 200);
        expect(
          find.byKey(Key(_burstKey(1, 0))),
          findsOneWidget,
          reason: 'precondition: burst showing. ${rig2.scenario}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      },
    );
  });

  // =========================================================================
  // Rule 3: the timeline is never held
  // =========================================================================
  group('rule 3: decorations never hold the timeline', () {
    // Kills: a flash linger or a burst life that delays the next queued move.
    for (final bool reduced in <bool>[false, true]) {
      testWidgets('a capture of my token followed by a queued step: the second '
          'onMoveLanded fires at first landing + flight + 1 step '
          '(reduced=$reduced), not later', (WidgetTester tester) async {
        final int step = reduced ? _stepReducedMs : _stepMs;
        final int flight = reduced ? _flightReducedMs : _flightMs;
        final List<(int, int, int)> landed = <(int, int, int)>[];
        late _Rig rig;
        rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'capture of seat 3 token 2 then seat 1 token 1 exits yard',
          mySeat: 3,
          reduced: reduced,
          onMoveLanded: (int seat, int token) =>
              landed.add((seat, token, rig.now)),
        );
        await rig.begin(_captureAfter());
        await rig.push(_tokens(s1: const <int>[5, 0, -1, -1]));
        await rig.advanceTo(step + step ~/ 2 + flight + step + 400);

        final Map<(int, int), int> at = <(int, int), int>{
          for (final (int s, int t, int ms) in landed) (s, t): ms,
        };
        // C-252 rules 6 and 6a: a move waiting behind the playing one makes
        // the playing move's steps that are not yet under way run at half
        // duration, so the capturing move's second step is step / 2. The
        // queued move then walks alone, one full step, after the full flight.
        final int firstWant = step + step ~/ 2;
        final int secondWant = firstWant + flight + step;
        expect(
          at[(1, 0)],
          isNotNull,
          reason:
              'onMoveLanded never fired for seat 1 token 0. Landed: '
              '$landed. ${rig.scenario}',
        );
        expect(
          (at[(1, 0)]! - firstWant).abs() <= _kChunk,
          isTrue,
          reason:
              'Expected the capturing move to land at $firstWant ms '
              '(a $step ms step then a ${step ~/ 2} ms step); it landed at ${at[(1, 0)]} ms. '
              '${rig.scenario}',
        );
        expect(
          at[(1, 1)],
          isNotNull,
          reason:
              'onMoveLanded never fired for the queued seat 1 token 1. '
              'Landed: $landed. ${rig.scenario}',
        );
        expect(
          (at[(1, 1)]! - secondWant).abs() <= _kChunk,
          isTrue,
          reason:
              'Expected the queued move to land at $secondWant ms '
              '(first landing + $flight ms flight + 1 step, no wait for the '
              'flash linger); it landed at ${at[(1, 1)]} ms. '
              '${rig.scenario}',
        );
      });
    }

    // Kills: a burst life that holds the next queued move's first step. This
    // case is about time only: the move queued behind a home landing walks
    // its single step at once and lands one step later.
    testWidgets(
      'a home landing followed by a queued move: the queued move lands one '
      'step after the home landing, without waiting for 700 ms',
      (WidgetTester tester) async {
        final List<(int, int, int)> landed = <(int, int, int)>[];
        late _Rig rig;
        rig = await _mount(
          tester,
          tokens: _tokens(
            s0: const <int>[56, -1, -1, -1],
            s2: const <int>[-1, 5, -1, -1],
          ),
          fixture: 'seat 0 token 0 56 to 57, then seat 2 token 1 5 to 6',
          mySeat: 1,
          onMoveLanded: (int seat, int token) =>
              landed.add((seat, token, rig.now)),
        );
        await rig.begin(
          _tokens(
            s0: const <int>[57, -1, -1, -1],
            s2: const <int>[-1, 5, -1, -1],
          ),
        );
        await rig.push(
          _tokens(
            s0: const <int>[57, -1, -1, -1],
            s2: const <int>[-1, 6, -1, -1],
          ),
        );
        await rig.advanceTo(3 * _stepMs);
        final Map<(int, int), int> at = <(int, int), int>{
          for (final (int s, int t, int ms) in landed) (s, t): ms,
        };
        expect(
          at[(0, 0)],
          isNotNull,
          reason: 'seat 0 token 0 never landed. ${rig.scenario}',
        );
        expect(
          (at[(0, 0)]! - _stepMs).abs() <= _kChunk,
          isTrue,
          reason:
              'Expected the home move to land at $_stepMs ms; it landed at '
              '${at[(0, 0)]} ms. ${rig.scenario}',
        );
        expect(
          at[(2, 1)],
          isNotNull,
          reason:
              'The queued seat 2 token 1 move never landed within '
              '${3 * _stepMs} ms; landed: $landed. It must start its first '
              'step when the home move lands, not after the burst. '
              '${rig.scenario}',
        );
        expect(
          (at[(2, 1)]! - 2 * _stepMs).abs() <= _kChunk,
          isTrue,
          reason:
              'Expected the queued move to land at ${2 * _stepMs} ms (one '
              'step after the home landing at $_stepMs ms); it landed at '
              '${at[(2, 1)]} ms, so it was held for something. '
              '${rig.scenario}',
        );
      },
    );

    // Kills: a burst that is not drawn while the next move plays (the case
    // above proves the move is not held; this one proves the burst is not
    // cut short by it either, so the two together mean "both at once").
    testWidgets(
      'the home burst is still showing when the move queued behind it has '
      'landed',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _tokens(
            s0: const <int>[56, -1, -1, -1],
            s2: const <int>[-1, 5, -1, -1],
          ),
          fixture: 'seat 0 token 0 56 to 57, then seat 2 token 1 5 to 6',
          mySeat: 1,
        );
        final String key = _burstKey(0, 0);
        final _Trace trace = _Trace(rig, <String>[key]);
        await rig.begin(
          _tokens(
            s0: const <int>[57, -1, -1, -1],
            s2: const <int>[-1, 5, -1, -1],
          ),
        );
        await rig.push(
          _tokens(
            s0: const <int>[57, -1, -1, -1],
            s2: const <int>[-1, 6, -1, -1],
          ),
        );
        await trace.run(3 * _stepMs);
        trace.expectRange(
          key,
          from: _stepMs + _kChunk,
          to: 2 * _stepMs + _kFrameSlack,
          present: true,
          why:
              'the burst lives 700 ms from the home landing at $_stepMs ms, '
              'through the queued move\'s whole step',
        );
      },
    );
  });

  // =========================================================================
  // Rule 3: pointer and semantics
  // =========================================================================
  group('rule 3: nothing to tap, nothing to read', () {
    // Kills: a burst built without IgnorePointer, or any painter that is
    // hit-testable (a CustomPaint with no hitTest override is hit-testable).
    testWidgets(
      'no hit-test entry at the burst centre or on a ray falls inside the '
      'burst, and a tap there sends no token callback',
      (WidgetTester tester) async {
        final List<int> taps = <int>[];
        final _Rig rig = await _mount(
          tester,
          tokens: _homeBefore(2, 1),
          fixture: 'seat 2 token 1 walks 52 to 57, mySeat 0 with all legal',
          mySeat: 0,
          legal: const <int>{0, 1, 2, 3},
          onTokenTap: taps.add,
        );
        await rig.begin(_homeAfter(2, 1));
        await rig.advanceTo(5 * _stepMs + 150);
        final Finder burst = find.byKey(Key(_burstKey(2, 1)));
        expect(
          burst,
          findsOneWidget,
          reason:
              'Expected the burst showing before it is probed. ${rig.scenario}',
        );
        final Offset centre = tester.getCenter(burst);
        final double cell = 400 / 15;
        for (final Offset p in <Offset>[
          centre,
          centre + Offset(cell * 0.6, 0),
          centre + Offset(0, -cell * 0.6),
        ]) {
          expect(
            _hitsInside(tester, p, _burstKey(2, 1)),
            0,
            reason:
                'Expected no hit-test entry at $p inside the burst subtree '
                '(it must sit under IgnorePointer); ${rig.scenario}',
          );
        }
        await tester.tapAt(centre);
        await tester.pump(const Duration(milliseconds: _kChunk));
        expect(
          taps,
          isEmpty,
          reason:
              'Expected a tap at the burst centre $centre (another seat\'s '
              'finished token) to send no token callback; got $taps. '
              '${rig.scenario}',
        );
      },
    );

    // Kills: a decoration that steals the tap of my real tokens, or moves
    // their hit target.
    testWidgets(
      'while a burst shows, my own legal yard token is still tappable at its '
      'unchanged hit rect',
      (WidgetTester tester) async {
        final List<int> taps = <int>[];
        final _Rig rig = await _mount(
          tester,
          tokens: _tokens(
            s0: const <int>[-1, -1, -1, -1],
            s2: const <int>[52, -1, -1, -1],
          ),
          fixture: 'seat 2 token 0 walks 52 to 57, mySeat 0 taps token 0',
          mySeat: 0,
          legal: const <int>{0},
          onTokenTap: taps.add,
        );
        final Rect before = tester.getRect(
          find.byKey(const Key('board-token-hit-0-0')),
        );
        await rig.begin(
          _tokens(
            s0: const <int>[-1, -1, -1, -1],
            s2: const <int>[57, -1, -1, -1],
          ),
        );
        await rig.advanceTo(5 * _stepMs + 150);
        expect(
          find.byKey(Key(_burstKey(2, 0))),
          findsOneWidget,
          reason: 'precondition: burst showing. ${rig.scenario}',
        );
        final Rect during = tester.getRect(
          find.byKey(const Key('board-token-hit-0-0')),
        );
        expect(
          during,
          before,
          reason:
              'Expected board-token-hit-0-0 unchanged while the burst shows '
              '($before before, $during during). ${rig.scenario}',
        );
        await tester.tapAt(during.center);
        await tester.pump(const Duration(milliseconds: _kChunk));
        expect(
          taps,
          <int>[0],
          reason:
              'Expected a tap on my legal token 0 to reach onTokenTap '
              'exactly once while a burst shows; got $taps. ${rig.scenario}',
        );
      },
    );

    // Kills: a flash built without IgnorePointer.
    testWidgets(
      'no hit-test entry at the flash centre falls inside the flash',
      (WidgetTester tester) async {
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: 3,
          legal: const <int>{0, 1, 2, 3},
          onTokenTap: (int _) {},
        );
        await rig.begin(_captureAfter());
        await rig.advanceTo(2 * _stepMs + 150);
        final String key = _flashKey(3, 2);
        expect(
          find.byKey(Key(key)),
          findsOneWidget,
          reason:
              'Expected the flash showing before it is probed. ${rig.scenario}',
        );
        final Offset centre = tester.getCenter(find.byKey(Key(key)));
        expect(
          _hitsInside(tester, centre, key),
          0,
          reason:
              'Expected no hit-test entry at $centre inside the flash '
              'subtree (it must sit under IgnorePointer). ${rig.scenario}',
        );
      },
    );

    // Kills: a Semantics node (or a label mentioning the decoration) added
    // for either decoration.
    testWidgets(
      'the semantics tree has the same node count while the burst shows as '
      'after it is gone, and no node mentions it',
      (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        addTearDown(handle.dispose);
        final _Rig rig = await _mount(
          tester,
          tokens: _homeBefore(2, 1),
          fixture: 'seat 2 token 1 walks 52 to 57',
          mySeat: 0,
        );
        await rig.begin(_homeAfter(2, 1));
        await rig.advanceTo(5 * _stepMs + 150);
        expect(
          find.byKey(Key(_burstKey(2, 1))),
          findsOneWidget,
          reason: 'precondition: burst showing. ${rig.scenario}',
        );
        final int during = _semanticsCount(tester);
        final List<String> mentions = _semanticsMentioning(tester, <String>[
          'burst',
          'flash',
          'captured-flash',
        ]);
        await rig.advanceTo(5 * _stepMs + 700 + _kFrameSlack + 4 * _kChunk);
        expect(
          find.byKey(Key(_burstKey(2, 1))),
          findsNothing,
          reason: 'precondition: burst gone. ${rig.scenario}',
        );
        final int after = _semanticsCount(tester);
        expect(
          during,
          after,
          reason:
              'Expected the same number of semantics nodes with and without '
              'the burst ($after after); $during while it showed. '
              '${rig.scenario}',
        );
        expect(
          mentions,
          isEmpty,
          reason: 'Expected no semantics node for the burst; $mentions',
        );
      },
    );

    testWidgets(
      'the semantics tree has the same node count while the flash shows as '
      'after it is gone, and no node mentions it',
      (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        addTearDown(handle.dispose);
        final _Rig rig = await _mount(
          tester,
          tokens: _captureBefore(),
          fixture: 'seat 1 token 0 walks 3 to 5 capturing seat 3 token 2',
          mySeat: 3,
        );
        await rig.begin(_captureAfter());
        await rig.advanceTo(2 * _stepMs + 200);
        expect(
          find.byKey(Key(_flashKey(3, 2))),
          findsOneWidget,
          reason: 'precondition: flash showing. ${rig.scenario}',
        );
        final List<String> mentions = _semanticsMentioning(tester, <String>[
          'burst',
          'flash',
        ]);
        // The flight is over after the landing; compare against the count
        // once the flash is gone and the board is at rest.
        final int during = _semanticsCount(tester);
        await rig.advanceTo(2 * _stepMs + _flightMs + 300 + _kFrameSlack + 40);
        expect(
          find.byKey(Key(_flashKey(3, 2))),
          findsNothing,
          reason: 'precondition: flash gone. ${rig.scenario}',
        );
        final int after = _semanticsCount(tester);
        expect(
          during,
          after,
          reason:
              'Expected the same number of semantics nodes with and without '
              'the flash ($after after); $during while it showed. '
              '${rig.scenario}',
        );
        expect(
          mentions,
          isEmpty,
          reason: 'Expected no semantics node for the flash; $mentions',
        );
      },
    );
  });
}
