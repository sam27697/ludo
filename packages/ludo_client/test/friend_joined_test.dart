// C-599 (order 599t): a friend sitting down is felt on every waiting phone.
// Written from work/ludo/orders/599-friend-joined-cue.md alone, never from
// the lobby screen's new code: the cue (D1, D3, D4), the sight (D5) and the
// spoken line (D5 c), on a real LobbyScreen over a real RoomController on a
// FakeTransport, with a recording FeedbackService behind a FeedbackScope.
//
// FeedbackCue.friendJoined does not exist on a tree without the
// implementation, so this file never names it: the cue is looked up by name
// inside a test body, and the expected lines come from the generated
// localizations (the strings are already in both arb files). That keeps the
// file compiling on the base, where the cases that encode today's behaviour
// stay green and the cases that encode the new rule fail on their own
// assertion.
//
// Observing the entrance without a key from the implementation (D5 a):
//   - Scale: the transform from the first Text under the seat card
//     (`lobby-seat-<n>`, a key that exists today) to the root, divided by the
//     same transform of the LobbyScreen itself. Whatever widget does the
//     scaling, if it sits above that Text the ratio shows it. 1.0 is no
//     entrance.
//   - Glow: the pixels around the card, read back from the outermost
//     repaint boundary at several times. The glow is whatever changes
//     between a frame inside its window and a frame after it; its colour is
//     read from the direction of that change against each seat colour.
//   - Fade (opacity 0.9..1.0 of the card) is NOT asserted: it can be drawn by
//     an Opacity, a FadeTransition, a saveLayer or an alpha on the paint, and
//     no assertion that does not guess at the widget can see all of them.
//
// Every case names its scenario and carries the frames and pumps that led
// to a failure (Scn.why), so a red case replays from its message.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/seat_card.dart' show OpenSeatCard;
import 'package:ludo_client/src/seat_mark.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _lineKey = Key('lobby-friend-joined-line');
const MethodChannel _feedbackChannel = MethodChannel('app.fayad.ludo/feedback');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'friend-joined-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _seatJson(int seat, String name) => <String, Object?>{
  'seat': seat,
  'name': name,
  'connected': true,
  'tokens': <int>[-1, -1, -1, -1],
  'client_seed': null,
  'seed_origin': null,
};

Map<String, Object?> _roomJson({
  required List<String> names,
  required int players,
  int seq = 1,
}) => <String, Object?>{
  'code': 'ABC234',
  'state': 'LOBBY',
  'host_seat': 0,
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
  'seats': <Map<String, Object?>>[
    for (int i = 0; i < names.length; i++) _seatJson(i, names[i]),
  ],
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    if (_queue.isEmpty) {
      throw StateError('_Connector: no transport queued');
    }
    return _queue.removeAt(0);
  }
}

/// The recording seam behind the FeedbackScope: every cue the lobby plays.
class _RecordingFeedback implements FeedbackService {
  final List<FeedbackCue> played = <FeedbackCue>[];

  @override
  void play(FeedbackCue cue) => played.add(cue);

  List<String> get ids => played.map((FeedbackCue c) => c.id).toList();
}

/// A scenario's replay log: every frame pushed and every pump made, so a
/// failure message carries what is needed to run it again by hand.
class Scn {
  Scn(this.name);

  final String name;
  final List<String> steps = <String>[];

  void log(String step) => steps.add(step);

  String get why => 'scenario "$name"; steps so far: ${steps.join(' | ')}';
}

class _Rig {
  _Rig({
    required this.tester,
    required this.scn,
    required this.controller,
    required this.transport,
    required this.feedback,
    required this.said,
    required this.dirs,
    required this.seq,
  });

  final WidgetTester tester;
  final Scn scn;
  final RoomController controller;
  final FakeTransport transport;
  final _RecordingFeedback feedback;
  final List<String> said;
  final List<int> dirs;

  /// The room seq the controller holds; the next state change carries +1.
  int seq;

  int elapsedMs = 0;

  Future<void> pump([int ms = 0]) async {
    elapsedMs += ms;
    scn.log('pump ${ms}ms (t=${elapsedMs}ms)');
    await tester.pump(Duration(milliseconds: ms));
  }

  /// One `player_joined` with the next seq, then enough pumps for the stream
  /// event and the frame it causes. Time does not advance.
  Future<void> join(int seat, String name) async {
    seq += 1;
    await push(<String, Object?>{'seat': seat, 'name': name, 'seq': seq});
  }

  Future<void> push(
    Map<String, Object?> data, {
    String type = 'player_joined',
  }) async {
    scn.log('push $type $data (t=${elapsedMs}ms)');
    transport.pushText(_frame(type: type, data: data));
    await tester.pump();
    await tester.pump();
  }

  AppLocalizations get loc =>
      AppLocalizations.of(tester.element(find.byType(LobbyScreen)));

  Finder get line => find.byKey(_lineKey);

  /// The Texts of the line (the line itself may be the Text).
  Finder get lineTexts =>
      find.descendant(of: line, matching: find.byType(Text), matchRoot: true);

  List<String> get lineStrings => lineTexts
      .evaluate()
      .map((Element e) => (e.widget as Text).data ?? '')
      .toList();
}

typedef _Body = Future<void> Function(_Rig rig);

/// Mounts a LobbyScreen in the lobby state with [names] seated and runs
/// [body]. [host] true creates the room as seat 0; false joins as seat 1.
Future<void> _scenario(
  WidgetTester tester,
  String name,
  _Body body, {
  bool host = true,
  List<String> names = const <String>['Sam'],
  int players = 4,
  Locale locale = const Locale('en'),
  bool reduceMotion = false,
  bool semantics = false,
  FeedbackSettings? settings,
  FeedbackService? service,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final SemanticsHandle? semanticsHandle = semantics
      ? tester.ensureSemantics()
      : null;
  final Scn scn = Scn(name);
  final List<String> said = <String>[];
  final List<int> dirs = <int>[];
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final Map<Object?, Object?> event = message as Map<Object?, Object?>;
      if (event['type'] == 'announce') {
        final Map<Object?, Object?> data =
            event['data'] as Map<Object?, Object?>;
        said.add(data['message'] as String);
        dirs.add(data['textDirection'] as int);
      }
      return null;
    },
  );
  addTearDown(
    () => messenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      null,
    ),
  );

  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
  );
  final _RecordingFeedback recorder = _RecordingFeedback();
  final FeedbackSettings feedbackSettings =
      settings ?? FeedbackSettings.forTest();
  try {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: buildAppTheme(),
        supportedLocales: appSupportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reduceMotion),
          child: child!,
        ),
        home: FeedbackScope(
          settings: feedbackSettings,
          service: service ?? recorder,
          child: LobbyScreen(
            controller: controller,
            action: host ? LobbyAction.create : LobbyAction.join,
            code: host ? null : 'ABC234',
            playerName: host ? names.first : names[1],
            players: players,
          ),
        ),
      ),
    );
    await tester.pump();
    final String requestId = _idOf(transport.sentRaw.last);
    transport.pushText(
      _frame(
        type: 'seat_assigned',
        data: <String, Object?>{
          'seat': host ? 0 : 1,
          'seat_token': 'tok-${host ? 0 : 1}',
        },
      ),
    );
    transport.pushText(
      _frame(
        type: 'room',
        re: requestId,
        data: _roomJson(names: names, players: players),
      ),
    );
    await tester.pump();
    await tester.pump();
    scn.log(
      'mounted ${host ? 'host' : 'guest'} names=$names players=$players '
      'locale=${locale.languageCode} reduceMotion=$reduceMotion',
    );
    expect(
      controller.room?.seats.length,
      names.length,
      reason: 'fixture: the room must hold ${names.length} seats; ${scn.why}',
    );
    await body(
      _Rig(
        tester: tester,
        scn: scn,
        controller: controller,
        transport: transport,
        feedback: recorder,
        said: said,
        dirs: dirs,
        seq: 1,
      ),
    );
  } finally {
    controller.dispose();
    semanticsHandle?.dispose();
  }
}

// --- observing the entrance ------------------------------------------------

double _scaleOfBox(RenderObject object) {
  final Matrix4 m = (object as RenderBox).getTransformTo(null);
  return m.storage[0];
}

/// The scale the seat card's first Text is drawn at, relative to the screen.
/// 1.0 is no entrance transform anywhere above the Text.
double _cardScale(WidgetTester tester, int seat) {
  final Finder text = find
      .descendant(
        of: find.byKey(Key('lobby-seat-$seat')),
        matching: find.byType(Text),
      )
      .first;
  return _scaleOfBox(tester.renderObject(text)) /
      _scaleOfBox(tester.renderObject(find.byType(LobbyScreen)));
}

class _Pixels {
  _Pixels(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;

  int channel(int x, int y, int c) => rgba[(y * width + x) * 4 + c];
}

/// The pixels around seat [seat]'s card (32 px of margin on the left, top and
/// right, none below, where the friend line sits), read from the outermost
/// repaint boundary above the card.
Future<_Pixels> _pixelsAround(WidgetTester tester, int seat) async {
  final RenderBox card =
      tester.renderObject(find.byKey(Key('lobby-seat-$seat'))) as RenderBox;
  RenderRepaintBoundary? top;
  RenderObject? walker = card;
  while (walker != null) {
    if (walker is RenderRepaintBoundary) {
      top = walker;
    }
    walker = walker.parent;
  }
  expect(top, isNotNull, reason: 'no repaint boundary above the seat card');
  final RenderRepaintBoundary boundary = top!;
  final Rect cardRect =
      card.localToGlobal(Offset.zero, ancestor: boundary) & card.size;
  final Rect want = Rect.fromLTRB(
    cardRect.left - 32,
    cardRect.top - 32,
    cardRect.right + 32,
    cardRect.bottom,
  ).intersect(Offset.zero & boundary.size);
  final ByteData? bytes = await tester.runAsync<ByteData?>(() async {
    final ui.Image image = await boundary.toImage();
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  expect(bytes, isNotNull, reason: 'could not read the screen back');
  final Uint8List all = bytes!.buffer.asUint8List();
  final int fullWidth = boundary.size.width.round();
  final int x0 = want.left.floor();
  final int y0 = want.top.floor();
  final int w = want.width.floor();
  final int h = want.height.floor();
  final Uint8List out = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      for (int c = 0; c < 4; c++) {
        out[(y * w + x) * 4 + c] =
            all[((y0 + y) * fullWidth + (x0 + x)) * 4 + c];
      }
    }
  }
  return _Pixels(w, h, out);
}

class _Change {
  _Change(this.pixels, this.magnitude, this.cosines);

  /// Pixels that differ by more than a rounding step.
  final int pixels;

  /// Sum of absolute channel differences over all pixels.
  final int magnitude;

  /// Per seat colour: the sum over changed pixels of the cosine between the
  /// change (shot minus settled) and (seat colour minus settled pixel).
  final List<double> cosines;

  int get bestSeat {
    int best = 0;
    for (int i = 1; i < cosines.length; i++) {
      if (cosines[i] > cosines[best]) {
        best = i;
      }
    }
    return best;
  }
}

_Change _change(_Pixels shot, _Pixels settled) {
  expect(
    <int>[shot.width, shot.height],
    <int>[settled.width, settled.height],
    reason: 'the card moved between two shots',
  );
  int pixels = 0;
  int magnitude = 0;
  final List<double> cosines = List<double>.filled(4, 0);
  for (int y = 0; y < shot.height; y++) {
    for (int x = 0; x < shot.width; x++) {
      int sum = 0;
      for (int c = 0; c < 3; c++) {
        sum += (shot.channel(x, y, c) - settled.channel(x, y, c)).abs();
      }
      magnitude += sum;
      if (sum <= 6) {
        continue;
      }
      pixels += 1;
      final List<double> d = <double>[
        for (int c = 0; c < 3; c++)
          (shot.channel(x, y, c) - settled.channel(x, y, c)).toDouble(),
      ];
      final double dn = d.fold<double>(0, (double a, double b) => a + b * b);
      for (int s = 0; s < 4; s++) {
        final Color seatColor = LudoColors.seats[s];
        final List<double> t = <double>[
          seatColor.r * 255 - settled.channel(x, y, 0),
          seatColor.g * 255 - settled.channel(x, y, 1),
          seatColor.b * 255 - settled.channel(x, y, 2),
        ];
        final double tn = t.fold<double>(0, (double a, double b) => a + b * b);
        if (dn == 0 || tn == 0) {
          continue;
        }
        double dot = 0;
        for (int c = 0; c < 3; c++) {
          dot += d[c] * t[c];
        }
        cosines[s] += dot / (math.sqrt(dn) * math.sqrt(tn));
      }
    }
  }
  return _Change(pixels, magnitude, cosines);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- D3, D4: the cue, once per frame, through the scope -------------------
  group('host, 4-seat lobby, one seat taken (C-599 D4, D5 b, D5 c)', () {
    testWidgets('before any join: no cue, no line, no announcement', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'host-quiet-before-join', (_Rig rig) async {
        expect(
          rig.feedback.ids,
          isEmpty,
          reason:
              'the room snapshot is not a friend sitting down; ${rig.scn.why}',
        );
        expect(rig.line, findsNothing, reason: rig.scn.why);
        expect(rig.said, isEmpty, reason: rig.scn.why);
      });
    });

    testWidgets('one player_joined plays exactly one friend_joined, through '
        'the FeedbackScope', (WidgetTester tester) async {
      await _scenario(tester, 'host-one-join-one-cue', (_Rig rig) async {
        await rig.join(1, 'Karim');
        expect(
          rig.feedback.ids,
          equals(<String>['friend_joined']),
          reason:
              'C-599 D4: one player_joined {seat: 1, name: Karim} plays one '
              'friend_joined and nothing else; got ${rig.feedback.ids}; '
              '${rig.scn.why}',
        );
        await rig.pump(100);
        await rig.pump(3000);
        expect(
          rig.feedback.ids,
          equals(<String>['friend_joined']),
          reason:
              'C-599 D4: once per frame, later frames and the clock add '
              'nothing; got ${rig.feedback.ids}; ${rig.scn.why}',
        );
        expect(rig.controller.room!.seats.length, 2, reason: rig.scn.why);
      });
    });

    testWidgets('the line reads lobbyFriendJoined("Karim") under the seat '
        'grid, with the seat mark at its start', (WidgetTester tester) async {
      await _scenario(tester, 'host-line-shape', (_Rig rig) async {
        await rig.join(1, 'Karim');
        const String expected = 'Karim joined';
        expect(
          rig.loc.lobbyFriendJoined('Karim'),
          expected,
          reason: 'fixture: the en string is "{name} joined"',
        );
        expect(
          rig.line,
          findsOneWidget,
          reason:
              'C-599 D5 b: lobby-friend-joined-line appears at the join; '
              '${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>[expected]),
          reason:
              'C-599 D5 b: the line carries one Text, "$expected"; got '
              '${rig.lineStrings}; ${rig.scn.why}',
        );

        final Finder marks = find.descendant(
          of: rig.line,
          matching: find.byType(SeatMark),
        );
        expect(
          marks,
          findsOneWidget,
          reason:
              'C-599 D5 b: the line holds the SeatMark of the joined seat so '
              'colour is not the only signal; ${rig.scn.why}',
        );
        expect(
          tester.widget<SeatMark>(marks).seat,
          1,
          reason: 'C-599 D5 b: the mark is seat 1\'s; ${rig.scn.why}',
        );
        expect(
          tester.getCenter(marks).dx,
          lessThan(tester.getCenter(rig.lineTexts).dx),
          reason:
              'C-599 D5 b: the mark sits at the line\'s start (left in en); '
              '${rig.scn.why}',
        );

        // Directly under the grid: below every seat card and every open
        // seat, and close to the last of them.
        double gridBottom = 0;
        for (final Finder cards in <Finder>[
          find.byKey(const Key('lobby-seat-0')),
          find.byKey(const Key('lobby-seat-1')),
          find.byType(OpenSeatCard),
        ]) {
          for (int i = 0; i < cards.evaluate().length; i++) {
            final double bottom = tester.getRect(cards.at(i)).bottom;
            if (bottom > gridBottom) {
              gridBottom = bottom;
            }
          }
        }
        final double lineTop = tester.getRect(rig.line).top;
        expect(
          lineTop,
          greaterThanOrEqualTo(gridBottom - 0.5),
          reason:
              'C-599 D5 b: the line is under the seat grid (grid bottom '
              '$gridBottom, line top $lineTop); ${rig.scn.why}',
        );
        expect(
          lineTop - gridBottom,
          lessThan(48),
          reason:
              'C-599 D5 b: directly under the grid, not further down the '
              'screen (grid bottom $gridBottom, line top $lineTop); '
              '${rig.scn.why}',
        );
      });
    });

    testWidgets('the line text is in ink', (WidgetTester tester) async {
      await _scenario(tester, 'host-line-ink', (_Rig rig) async {
        await rig.join(1, 'Karim');
        expect(rig.line, findsOneWidget, reason: rig.scn.why);
        final Finder rich = find
            .descendant(
              of: rig.lineTexts,
              matching: find.byType(RichText),
              matchRoot: true,
            )
            .first;
        final RichText text = tester.widget<RichText>(rich);
        expect(
          text.text.style?.color,
          LudoColors.ink,
          reason:
              'C-599 D5 b: the text is in ink (LudoColors.ink), the colour '
              'rides on the mark; got ${text.text.style?.color}; '
              '${rig.scn.why}',
        );
      });
    });

    testWidgets('the line is there at 2400 ms and gone after 2500 ms plus a '
        'frame', (WidgetTester tester) async {
      await _scenario(tester, 'host-line-lifetime', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.pump(2400);
        expect(
          rig.line,
          findsOneWidget,
          reason: 'C-599 D5 b: the line stays 2500 ms; ${rig.scn.why}',
        );
        await rig.pump(100);
        await rig.pump();
        expect(
          rig.line,
          findsNothing,
          reason: 'C-599 D5 b: gone after 2500 ms plus a frame; ${rig.scn.why}',
        );
        expect(
          find.byKey(const Key('lobby-seat-1')),
          findsOneWidget,
          reason: 'the card stays when the line goes; ${rig.scn.why}',
        );
      });
    });

    testWidgets('one announcement of the same text per join, with the '
        'ambient direction, and the line is out of semantics', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'host-announcement', semantics: true, (
        _Rig rig,
      ) async {
        await rig.join(1, 'Karim');
        await rig.pump(50);
        expect(
          rig.said.where((String s) => s == 'Karim joined').toList(),
          equals(<String>['Karim joined']),
          reason:
              'C-599 D5 c: exactly one announcement "Karim joined" per join; '
              'announced: ${rig.said}; ${rig.scn.why}',
        );
        expect(
          rig.dirs.last,
          TextDirection.ltr.index,
          reason:
              'C-599 D5 c: the ambient direction (ltr in en); ${rig.scn.why}',
        );
        expect(
          find.bySemanticsLabel('Karim joined'),
          findsNothing,
          reason:
              'C-599 D5 c: the line is excluded from semantics so the name '
              'is not read twice; ${rig.scn.why}',
        );
        expect(
          find.text('Karim joined'),
          findsOneWidget,
          reason: 'fixture: the line is drawn; ${rig.scn.why}',
        );
        await rig.pump(3000);
        expect(
          rig.said.where((String s) => s == 'Karim joined'),
          hasLength(1),
          reason:
              'C-599 D5 c: the line going away says nothing more; announced: '
              '${rig.said}; ${rig.scn.why}',
        );
      });
    });

    testWidgets('a second join 1000 ms later: two cues, the line names Lina '
        'and stays 2500 ms from her join', (WidgetTester tester) async {
      await _scenario(tester, 'host-two-joins', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.pump(1000);
        await rig.join(2, 'Lina');
        expect(
          rig.feedback.ids,
          equals(<String>['friend_joined', 'friend_joined']),
          reason:
              'C-599 D5 g: two joins, two cues; got ${rig.feedback.ids}; '
              '${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>['Lina joined']),
          reason:
              'C-599 D5 b: the newer name replaces the line; got '
              '${rig.lineStrings}; ${rig.scn.why}',
        );
        expect(
          rig.line,
          findsOneWidget,
          reason: 'one line, not two stacked; ${rig.scn.why}',
        );
        final Finder marks = find.descendant(
          of: rig.line,
          matching: find.byType(SeatMark),
        );
        expect(
          tester.widget<SeatMark>(marks).seat,
          2,
          reason: 'the mark follows the newer seat; ${rig.scn.why}',
        );
        // t = 1000 + 2400 after Karim: Karim's own 2500 ms ended at 2500.
        await rig.pump(2400);
        expect(
          rig.line,
          findsOneWidget,
          reason:
              'C-599 D5 b: the 2500 ms restarts at Lina\'s join (still shown '
              '2400 ms after it, 3400 ms after Karim\'s); ${rig.scn.why}',
        );
        expect(rig.lineStrings, equals(<String>['Lina joined']));
        await rig.pump(100);
        await rig.pump();
        expect(
          rig.line,
          findsNothing,
          reason: 'gone 2500 ms after Lina\'s join; ${rig.scn.why}',
        );
        expect(
          rig.said.where((String s) => s.endsWith(' joined')).toList(),
          equals(<String>['Karim joined', 'Lina joined']),
          reason:
              'C-599 D5 c: one announcement per join, in order; got '
              '${rig.said}; ${rig.scn.why}',
        );
        expect(
          rig.feedback.ids,
          hasLength(2),
          reason: 'the clock plays no further cue; ${rig.scn.why}',
        );
      });
    });

    testWidgets('two joins in the same instant: two cues, two '
        'announcements, the line names the newer', (WidgetTester tester) async {
      await _scenario(tester, 'host-simultaneous-joins', (_Rig rig) async {
        rig.seq += 1;
        rig.transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 1, 'name': 'Karim', 'seq': rig.seq},
          ),
        );
        rig.seq += 1;
        rig.transport.pushText(
          _frame(
            type: 'player_joined',
            data: <String, Object?>{'seat': 2, 'name': 'Lina', 'seq': rig.seq},
          ),
        );
        rig.scn.log('pushed seats 1 and 2 before any pump');
        await tester.pump();
        await tester.pump();
        expect(
          rig.feedback.ids,
          equals(<String>['friend_joined', 'friend_joined']),
          reason:
              'C-599 D4: once per frame, two frames in one instant are two '
              'cues; got ${rig.feedback.ids}; ${rig.scn.why}',
        );
        expect(
          rig.said.where((String s) => s.endsWith(' joined')).toList(),
          equals(<String>['Karim joined', 'Lina joined']),
          reason: 'one announcement per join; got ${rig.said}; ${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>['Lina joined']),
          reason: 'the newer name wins; ${rig.scn.why}',
        );
      });
    });

    testWidgets('a duplicate name is announced and drawn with its number, the '
        'label the seat card shows', (WidgetTester tester) async {
      await _scenario(tester, 'host-duplicate-name', (_Rig rig) async {
        await rig.join(1, 'Karim');
        final BuildContext context = tester.element(find.byType(LobbyScreen));
        final String label = seatLabelsFor(
          context,
          rig.controller.room!.seats,
        )[1]!;
        expect(
          label,
          isNot('Karim'),
          reason:
              'fixture: two seats named Karim, the second carries its '
              'number; got "$label"',
        );
        final String expected = rig.loc.lobbyFriendJoined(label);
        expect(
          find.descendant(
            of: find.byKey(const Key('lobby-seat-1')),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: 'fixture: the card draws "$label"; ${rig.scn.why}',
        );
        expect(
          rig.lineStrings,
          equals(<String>[expected]),
          reason:
              'C-599 D5 b: the line names the label the card shows '
              '("$label"); got ${rig.lineStrings}; ${rig.scn.why}',
        );
        expect(
          rig.said.where((String s) => s.contains('Karim')).toList(),
          equals(<String>[expected]),
          reason:
              'C-599 D5 c: the announcement names the same label; got '
              '${rig.said}; ${rig.scn.why}',
        );
      }, names: const <String>['Karim']);
    });

    testWidgets('a frame naming my own seat plays nothing and shows nothing', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'host-own-seat-frame', (_Rig rig) async {
        await rig.join(0, 'Sam');
        expect(
          rig.feedback.ids,
          isEmpty,
          reason:
              'C-599 D3: my own seat is not a friend; got '
              '${rig.feedback.ids}; ${rig.scn.why}',
        );
        expect(rig.line, findsNothing, reason: rig.scn.why);
        expect(rig.said, isEmpty, reason: rig.scn.why);
      });
    });

    testWidgets('a frame whose seat is a string or missing plays nothing, '
        'shows nothing and does not throw', (WidgetTester tester) async {
      await _scenario(tester, 'host-malformed-seat', (_Rig rig) async {
        await rig.push(<String, Object?>{
          'seat': '1',
          'name': 'Karim',
          'seq': rig.seq + 1,
        });
        await rig.push(<String, Object?>{'name': 'Karim', 'seq': rig.seq + 1});
        await rig.push(<String, Object?>{
          'seat': null,
          'name': 'Karim',
          'seq': rig.seq + 1,
        });
        expect(tester.takeException(), isNull, reason: rig.scn.why);
        expect(
          rig.feedback.ids,
          isEmpty,
          reason:
              'C-599 D3: a missing or mistyped seat is no friend; got '
              '${rig.feedback.ids}; ${rig.scn.why}',
        );
        expect(rig.line, findsNothing, reason: rig.scn.why);
        expect(rig.said, isEmpty, reason: rig.scn.why);
      });
    });

    testWidgets('player_left and presence play no cue and show no line '
        '(C-599 D6)', (WidgetTester tester) async {
      await _scenario(tester, 'host-left-and-presence', (_Rig rig) async {
        rig.seq += 1;
        await rig.push(<String, Object?>{
          'seat': 1,
          'connected': false,
          'seq': rig.seq,
        }, type: 'presence');
        rig.seq += 1;
        await rig.push(<String, Object?>{
          'seat': 1,
          'host_seat': 0,
          'seq': rig.seq,
        }, type: 'player_left');
        expect(
          rig.controller.room!.seats.length,
          1,
          reason: 'fixture: seat 1 left; ${rig.scn.why}',
        );
        expect(
          rig.feedback.ids,
          isEmpty,
          reason:
              'C-599 D6: no cue on player_left or presence; got '
              '${rig.feedback.ids}; ${rig.scn.why}',
        );
        expect(rig.line, findsNothing, reason: rig.scn.why);
        expect(rig.said, isEmpty, reason: rig.scn.why);
      }, names: const <String>['Sam', 'Karim']);
    });

    testWidgets('leaving the screen mid-line leaves no pending timer and no '
        'late announcement', (WidgetTester tester) async {
      await _scenario(tester, 'host-unmount-mid-line', (_Rig rig) async {
        await rig.join(1, 'Karim');
        await rig.pump(1000);
        expect(rig.line, findsOneWidget, reason: rig.scn.why);
        await tester.pumpWidget(const SizedBox.shrink());
        rig.scn.log('unmounted the screen');
        await rig.pump(5000);
        expect(tester.takeException(), isNull, reason: rig.scn.why);
        expect(
          rig.said.where((String s) => s == 'Karim joined'),
          hasLength(1),
          reason:
              'nothing is announced after the screen is gone; ${rig.scn.why}',
        );
        expect(
          rig.feedback.ids,
          hasLength(1),
          reason: 'nothing is played after the screen is gone; ${rig.scn.why}',
        );
      });
    });
  });

  // --- D4 with the real service: the switches rule it -----------------------
  group('the in-app switches (C-599 D1, D4)', () {
    Future<List<String>> run(
      WidgetTester tester,
      FeedbackSettings settings,
      String name,
    ) async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_feedbackChannel, (MethodCall call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_feedbackChannel, null),
      );
      final PlatformFeedbackService service = PlatformFeedbackService(
        settings,
        _feedbackChannel,
      );
      await _scenario(
        tester,
        name,
        (_Rig rig) async {
          await rig.join(1, 'Karim');
          await tester.pump(const Duration(milliseconds: 10));
        },
        settings: settings,
        service: service,
      );
      return calls
          .map((MethodCall c) => '${c.method}:${(c.arguments as Map)['id']}')
          .toList()
        ..sort();
    }

    testWidgets('both switches on: haptic and sound', (
      WidgetTester tester,
    ) async {
      expect(
        await run(tester, FeedbackSettings.forTest(), 'switches-both-on'),
        equals(<String>['haptic:friend_joined', 'sound:friend_joined']),
        reason: 'C-599 D1: the real service sends both channels',
      );
    });

    testWidgets('sound off: only the haptic', (WidgetTester tester) async {
      expect(
        await run(
          tester,
          FeedbackSettings.forTest(sound: false),
          'switches-sound-off',
        ),
        equals(<String>['haptic:friend_joined']),
        reason: 'C-599 D1: honours the sound switch',
      );
    });

    testWidgets('haptics off: only the sound', (WidgetTester tester) async {
      expect(
        await run(
          tester,
          FeedbackSettings.forTest(haptics: false),
          'switches-haptics-off',
        ),
        equals(<String>['sound:friend_joined']),
        reason: 'C-599 D1: honours the haptic switch',
      );
    });

    testWidgets('both off: nothing felt, the line still shows and is '
        'announced', (WidgetTester tester) async {
      final FeedbackSettings settings = FeedbackSettings.forTest(
        haptics: false,
        sound: false,
      );
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_feedbackChannel, (MethodCall call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_feedbackChannel, null),
      );
      await _scenario(
        tester,
        'switches-both-off',
        (_Rig rig) async {
          await rig.join(1, 'Karim');
          await rig.pump(10);
          expect(
            calls,
            isEmpty,
            reason: 'C-599 D1: both switches off, nothing; got $calls',
          );
          expect(
            rig.line,
            findsOneWidget,
            reason: 'the switches rule the cue, not the sight; ${rig.scn.why}',
          );
          expect(
            rig.said,
            contains('Karim joined'),
            reason: 'the switches rule the cue, not TalkBack; ${rig.scn.why}',
          );
        },
        settings: settings,
        service: PlatformFeedbackService(settings, _feedbackChannel),
      );
    });
  });

  // --- ar ------------------------------------------------------------------
  group('Arabic (C-599 D5 i)', () {
    testWidgets('the cue, the line and the announcement read «انضمّ Karim» '
        'and the mark sits at the right-hand start', (
      WidgetTester tester,
    ) async {
      await _scenario(
        tester,
        'ar-host-join',
        (_Rig rig) async {
          await rig.join(1, 'Karim');
          await rig.pump(50);
          const String expected = 'انضمّ Karim';
          expect(
            rig.loc.lobbyFriendJoined('Karim'),
            expected,
            reason: 'fixture: the ar string is "انضمّ {name}"',
          );
          expect(
            rig.feedback.ids,
            equals(<String>['friend_joined']),
            reason: 'one cue; ${rig.scn.why}',
          );
          expect(
            rig.lineStrings,
            equals(<String>[expected]),
            reason:
                'C-599 D5 i: the line reads "$expected"; got '
                '${rig.lineStrings}; ${rig.scn.why}',
          );
          expect(
            rig.said.where((String s) => s == expected).toList(),
            equals(<String>[expected]),
            reason:
                'C-599 D5 i: one announcement "$expected"; got ${rig.said}; '
                '${rig.scn.why}',
          );
          expect(
            rig.dirs.last,
            TextDirection.rtl.index,
            reason:
                'C-599 D5 c: the ambient direction (rtl in ar); ${rig.scn.why}',
          );
          final Finder marks = find.descendant(
            of: rig.line,
            matching: find.byType(SeatMark),
          );
          expect(marks, findsOneWidget, reason: rig.scn.why);
          expect(
            tester.getCenter(marks).dx,
            greaterThan(tester.getCenter(rig.lineTexts).dx),
            reason:
                'C-599 D5 b: the mark is at the line\'s start, the right in '
                'rtl; ${rig.scn.why}',
          );
          expect(
            find.bySemanticsLabel(expected),
            findsNothing,
            reason: 'the line is out of semantics; ${rig.scn.why}',
          );
          await rig.pump(2500);
          await rig.pump();
          expect(rig.line, findsNothing, reason: rig.scn.why);
        },
        locale: const Locale('ar'),
        semantics: true,
      );
    });
  });

  // --- (j) a guest's lobby --------------------------------------------------
  group('guest (C-599 D5 j)', () {
    testWidgets('a third player joining gives a guest the same cue, line and '
        'announcement; the guest\'s own arrival gave nothing', (
      WidgetTester tester,
    ) async {
      await _scenario(
        tester,
        'guest-third-joins',
        (_Rig rig) async {
          expect(rig.controller.isHost, isFalse, reason: 'fixture: a guest');
          expect(
            rig.feedback.ids,
            isEmpty,
            reason:
                'C-599 D6: the joining phone gets nothing new, and the room '
                'snapshot is not a friend; got ${rig.feedback.ids}',
          );
          expect(rig.line, findsNothing, reason: rig.scn.why);
          await rig.join(2, 'Lina');
          expect(
            rig.feedback.ids,
            equals(<String>['friend_joined']),
            reason:
                'C-599 D5 j: the guest feels the third player; got '
                '${rig.feedback.ids}; ${rig.scn.why}',
          );
          expect(
            rig.lineStrings,
            equals(<String>['Lina joined']),
            reason:
                'C-599 D5 j: the line; got ${rig.lineStrings}; ${rig.scn.why}',
          );
          expect(
            rig.said.where((String s) => s == 'Lina joined'),
            hasLength(1),
            reason:
                'C-599 D5 j: one announcement; got ${rig.said}; ${rig.scn.why}',
          );
          await rig.pump(2400);
          expect(rig.line, findsOneWidget, reason: rig.scn.why);
          await rig.pump(100);
          await rig.pump();
          expect(rig.line, findsNothing, reason: rig.scn.why);
        },
        host: false,
        names: const <String>['Sam', 'Amir'],
      );
    });

    testWidgets('a frame naming the guest\'s own seat gives the guest '
        'nothing', (WidgetTester tester) async {
      await _scenario(
        tester,
        'guest-own-seat-frame',
        (_Rig rig) async {
          await rig.join(1, 'Amir');
          expect(
            rig.feedback.ids,
            isEmpty,
            reason: 'C-599 D3: seat 1 is mine; ${rig.scn.why}',
          );
          expect(rig.line, findsNothing, reason: rig.scn.why);
          expect(rig.said, isEmpty, reason: rig.scn.why);
        },
        host: false,
        names: const <String>['Sam', 'Amir'],
      );
    });
  });

  // --- D5 a: the entrance ---------------------------------------------------
  group('the entrance (C-599 D5 a)', () {
    testWidgets('cards present at the first build carry no entrance: scale '
        '1.0 in the first frame and after', (WidgetTester tester) async {
      await _scenario(tester, 'entrance-first-build-cards', (_Rig rig) async {
        for (final int seat in <int>[0, 1, 2]) {
          expect(
            _cardScale(tester, seat),
            closeTo(1.0, 0.001),
            reason:
                'C-599 D5 a: seat $seat was there at the first build; no '
                'scale in the first frame; ${rig.scn.why}',
          );
        }
        await rig.pump(16);
        await rig.pump(100);
        for (final int seat in <int>[0, 1, 2]) {
          expect(
            _cardScale(tester, seat),
            closeTo(1.0, 0.001),
            reason:
                'C-599 D5 a: seat $seat still at rest 116 ms later; '
                '${rig.scn.why}',
          );
        }
      }, names: const <String>['Sam', 'Ana', 'Bo']);
    });

    testWidgets('cards present at the first build carry no glow', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'entrance-first-build-no-glow', (_Rig rig) async {
        await rig.pump(50);
        final _Pixels early = await _pixelsAround(tester, 1);
        await rig.pump(1500);
        final _Pixels late = await _pixelsAround(tester, 1);
        final _Change change = _change(early, late);
        expect(
          change.pixels,
          0,
          reason:
              'C-599 D5 a: a seat present at the first build has no glow; '
              '${change.pixels} pixels around seat 1 changed between 50 ms '
              'and 1550 ms; ${rig.scn.why}',
        );
      }, names: const <String>['Sam', 'Ana']);
    });

    testWidgets('the joined card scales from 0.9 and reaches 1.0 by 320 ms '
        'on an ease-out curve; the cards already there stay at 1.0', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'entrance-scale', (_Rig rig) async {
        await rig.join(1, 'Karim');
        final double first = _cardScale(tester, 1);
        expect(
          first,
          allOf(greaterThanOrEqualTo(0.899), lessThan(0.999)),
          reason:
              'C-599 D5 a: the first frame of the new card is below 1.0 and '
              'starts at 0.9; got $first; ${rig.scn.why}',
        );
        expect(
          _cardScale(tester, 0),
          closeTo(1.0, 0.001),
          reason: 'the host\'s card does not animate; ${rig.scn.why}',
        );
        await rig.pump(160);
        final double half = _cardScale(tester, 1);
        expect(
          half,
          allOf(greaterThan(0.955), lessThan(0.999)),
          reason:
              'C-599 D5 a: an ease-out curve is past the linear midpoint '
              '(0.95) at 160 ms of 320 and not there yet; got $half; '
              '${rig.scn.why}',
        );
        await rig.pump(160);
        expect(
          _cardScale(tester, 1),
          closeTo(1.0, 0.001),
          reason: 'C-599 D5 a: 1.0 by 320 ms; ${rig.scn.why}',
        );
        await rig.pump(16);
        expect(_cardScale(tester, 1), closeTo(1.0, 0.001));
        expect(_cardScale(tester, 0), closeTo(1.0, 0.001));
      });
    });

    testWidgets('under disableAnimations the card appears at once: no scale '
        'at any frame', (WidgetTester tester) async {
      await _scenario(tester, 'entrance-reduced-motion-scale', (
        _Rig rig,
      ) async {
        await rig.join(1, 'Karim');
        expect(
          _cardScale(tester, 1),
          closeTo(1.0, 0.001),
          reason:
              'C-599 D5 a: reduced motion has no scale, first frame; '
              '${rig.scn.why}',
        );
        await rig.pump(16);
        await rig.pump(100);
        expect(
          _cardScale(tester, 1),
          closeTo(1.0, 0.001),
          reason: 'reduced motion, 116 ms in; ${rig.scn.why}',
        );
        expect(rig.line, findsOneWidget, reason: 'the line still shows');
        expect(
          rig.feedback.ids,
          equals(<String>['friend_joined']),
          reason: 'reduced motion shortens the sight, the cue stays',
        );
      }, reduceMotion: true);
    });

    testWidgets('the glow is in the joined seat\'s colour, fades out and is '
        'gone 1200 ms from the entrance', (WidgetTester tester) async {
      await _scenario(tester, 'entrance-glow', (_Rig rig) async {
        await rig.join(3, 'Karim');
        await rig.pump(400);
        final _Pixels at400 = await _pixelsAround(tester, 3);
        await rig.pump(400);
        final _Pixels at800 = await _pixelsAround(tester, 3);
        await rig.pump(450);
        final _Pixels at1250 = await _pixelsAround(tester, 3);
        await rig.pump(1000);
        final _Pixels at2250 = await _pixelsAround(tester, 3);

        final _Change early = _change(at400, at2250);
        final _Change mid = _change(at800, at2250);
        final _Change gone = _change(at1250, at2250);
        expect(
          early.pixels,
          greaterThan(20),
          reason:
              'C-599 D5 a: a glow around the new card at 400 ms; only '
              '${early.pixels} pixels differ from the settled card; '
              '${rig.scn.why}',
        );
        expect(
          early.bestSeat,
          3,
          reason:
              'C-599 D5 a: the glow is in the colour of seat 3 '
              '(LudoColors.seats[3]); cosines per seat '
              '${early.cosines}; ${rig.scn.why}',
        );
        expect(
          mid.magnitude,
          allOf(greaterThan(0), lessThan(early.magnitude)),
          reason:
              'C-599 D5 a: the glow fades: strength at 800 ms '
              '(${mid.magnitude}) is under 400 ms (${early.magnitude}) and '
              'not yet zero; ${rig.scn.why}',
        );
        expect(
          gone.pixels,
          0,
          reason:
              'C-599 D5 a: gone by 1250 ms (1200 ms from the entrance); '
              '${gone.pixels} pixels still differ from the settled card; '
              '${rig.scn.why}',
        );
      });
    });

    testWidgets('under disableAnimations the glow is at full strength for '
        '1200 ms and then removed: shorter, never skipped', (
      WidgetTester tester,
    ) async {
      await _scenario(tester, 'entrance-reduced-motion-glow', (_Rig rig) async {
        await rig.join(3, 'Karim');
        await rig.pump(100);
        final _Pixels at100 = await _pixelsAround(tester, 3);
        await rig.pump(1000);
        final _Pixels at1100 = await _pixelsAround(tester, 3);
        await rig.pump(200);
        final _Pixels at1300 = await _pixelsAround(tester, 3);
        await rig.pump(1000);
        final _Pixels at2300 = await _pixelsAround(tester, 3);

        final _Change shown = _change(at100, at2300);
        expect(
          shown.pixels,
          greaterThan(20),
          reason:
              'C-599 D5 a: reduced motion keeps the glow (never skipped); '
              'only ${shown.pixels} pixels differ at 100 ms; ${rig.scn.why}',
        );
        expect(
          shown.bestSeat,
          3,
          reason:
              'the glow is seat 3\'s colour; cosines ${shown.cosines}; '
              '${rig.scn.why}',
        );
        final _Change flat = _change(at1100, at100);
        expect(
          flat.pixels,
          0,
          reason:
              'C-599 D5 a: full strength for the whole 1200 ms, no fade: '
              '${flat.pixels} pixels differ between 100 ms and 1100 ms; '
              '${rig.scn.why}',
        );
        final _Change removed = _change(at1300, at2300);
        expect(
          removed.pixels,
          0,
          reason:
              'C-599 D5 a: removed after 1200 ms: ${removed.pixels} '
              'pixels still differ from the settled card at 1300 ms; '
              '${rig.scn.why}',
        );
      }, reduceMotion: true);
    });
  });
}
