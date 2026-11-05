// Conformance tests for work/ludo/orders/C-565-wait-marks-scale-and-arabic-
// counts.md, section "What the proofs measure" items 1-8, written from that
// spec alone. Order 565 implements in a tree this file's author has not read.
//
// `waitingMarkSize` and the Key `lobby-docked-waiting-mark` are the symbols
// the spec adds that these cases name. A mark is measured against the text it
// sits beside: the expected size is `waitingMarkSize` applied to the style the
// line's RenderParagraph actually rendered with, never a hardcoded 14, so a
// theme change moves both sides together. The Arabic texts are pinned as
// literals copied from D4; AppLocalizations is read through the generated
// lookup for the locale, so a wrong plural branch is caught per count.
//
// Nothing here uses pumpAndSettle: the wait mark turns for ever. Time is
// fake, a frame is two bare pumps after a push, and the countdown moves with
// `pump(Duration(seconds: 1))`.
//
// Every reason line carries the scenario (widget, locale, text scale,
// surface, state) so a red case can be rebuilt by hand. The scenarios are
// plain frames, there is no random seed to record.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/end_card.dart';
import 'package:ludo_client/src/feedback.dart';
import 'package:ludo_client/src/game_screen.dart';
import 'package:ludo_client/src/game_stats.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart'
    show LudoColors, buildAppTheme, kSpace4, kSpace6;
import 'package:ludo_client/src/waiting_line.dart'
    show WaitingLine, waitingMarkSize;

import 'net/fake_transport.dart';

const String _testUrl = 'wss://c565-test.invalid/ws';

const Key _markKey = Key('waiting-line-mark');
const Key _lineTextKey = Key('c565-line-text');
const Key _lobbyConnectingKey = Key('lobby-connecting');
const Key _lobbyConnectingLineKey = Key('lobby-connecting-line');
const Key _dockedTextKey = Key('lobby-waiting');
const Key _dockedMarkKey = Key('lobby-docked-waiting-mark');
const Key _countdownKey = Key('game-screen-turn-countdown');
const Key _countdownSemanticsKey = Key('game-header-countdown-semantics');

const Locale _en = Locale('en');
const Locale _ar = Locale('ar');

const List<Locale> _locales = <Locale>[_en, _ar];
const List<double> _scales = <double>[1.0, 2.0];

// --- harness -------------------------------------------------------------------

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

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// A 360x640 phone, reset by the harness teardown.
Future<void> _phone(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(360, 640));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// The style the Text under [textFinder] actually rendered with, read off its
/// RenderParagraph (the merge of the caller's style and the ambient default).
TextStyle _renderedStyle(
  WidgetTester tester,
  Finder textFinder,
  String scenario,
) {
  final Finder rich = find.descendant(
    of: textFinder,
    matching: find.byType(RichText),
  );
  expect(
    rich,
    findsOneWidget,
    reason: 'fixture: the line text must hold one RichText. $scenario',
  );
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(rich);
  final TextStyle? style = paragraph.text.style;
  expect(
    style?.fontSize,
    isNotNull,
    reason: 'fixture: the rendered paragraph must carry a font size. $scenario',
  );
  return style!;
}

Finder _iconUnder(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(Icon));

/// `waitingMarkSize` for [style], evaluated under the context of [at]. The
/// scale it reads is the one the screen under test was mounted with.
double _expectedMark(WidgetTester tester, Finder at, TextStyle style) {
  return waitingMarkSize(tester.element(at), style);
}

void _expectNoException(WidgetTester tester, String scenario) {
  final Object? thrown = tester.takeException();
  expect(
    thrown,
    isNull,
    reason: 'no overflow or layout error was expected, got $thrown. $scenario',
  );
}

// --- frames and rooms, the sibling suites' idiom ---------------------------------

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'c565-srv-${_serverIdSeq.toString().padLeft(6, '0')}';
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

Map<String, Object?> _seatJson(int seat, {required String name}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': const <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  required String state,
  required int players,
  required int seated,
  Map<String, Object?>? turn,
}) => <String, Object?>{
  'code': 'C565XX',
  'state': state,
  'host_seat': 0,
  'players': players,
  'rules': <String, Object?>{
    'blocks': true,
    'capture_bonus': true,
    'turn_seconds': 45,
  },
  'chain_commit': 'a' * 64,
  'chain_index': 0,
  'game_id': state == 'PLAYING' ? 'g1' : null,
  'client_seeds': state == 'PLAYING' ? '0:seed' : null,
  'seats': <Map<String, Object?>>[
    for (int i = 0; i < seated; i++) _seatJson(i, name: 'p$i'),
  ],
  'turn': turn,
  'winner': null,
  'seq': 1,
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

RoomController _controllerOver(FakeTransport transport) {
  final _Connector connector = _Connector();
  connector.enqueue(transport);
  return RoomController(
    serverUrl: Uri.parse(_testUrl),
    connect: connector.call,
    autoReconnectDelays: const <Duration>[],
  );
}

/// Answers the request the lobby just sent with a seat and a room.
Future<void> _answerLobby(
  WidgetTester tester,
  FakeTransport transport, {
  required int mySeat,
  required Map<String, Object?> room,
}) async {
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason: 'fixture: the lobby must have sent its create or join request',
  );
  final String id = _idOf(transport.sentRaw.last);
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{'seat': mySeat, 'seat_token': 'tok-$mySeat'},
    ),
  );
  transport.pushText(_frame(type: 'room', re: id, data: room));
  // One pump after a push does not deliver a frame.
  await tester.pump();
  await tester.pump();
}

/// A controller landed on a PLAYING two-seat room whose turn is seat 0's, by
/// a createRoom reply, ready for a GameScreen.
Future<RoomController> _playingController(
  WidgetTester tester, {
  required int deadlineMs,
}) async {
  final FakeTransport transport = FakeTransport();
  final RoomController controller = _controllerOver(transport);
  final Future<void> future = controller.createRoom(name: 'p0', players: 2);
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
        state: 'PLAYING',
        players: 2,
        seated: 2,
        turn: <String, Object?>{
          'seat': 0,
          'phase': 'await_roll',
          'deadline_ms': deadlineMs,
          'k': 0,
        },
      ),
    ),
  );
  await future;
  return controller;
}

// --- the Arabic texts, copied from D4 of the spec ------------------------------------

AppLocalizations _locFor(Locale l) => lookupAppLocalizations(l);

const String _arHome = 'في البيت';

// gameTurnCountdown, per count: the "=0", "=1", "=2", few (3-10) and other
// (11+, including 100) branches.
const Map<int, String> _arCountdown = <int, String>{
  0: 'انتهى الوقت',
  1: 'بقيت ثانية واحدة',
  2: 'بقيت ثانيتان',
  3: 'بقيت 3 ثوانٍ',
  10: 'بقيت 10 ثوانٍ',
  11: 'بقيت 11 ثانية',
  45: 'بقيت 45 ثانية',
  100: 'بقيت 100 ثانية',
};

const Map<int, String> _arRolls = <int, String>{
  0: 'رميات',
  1: 'رمية',
  2: 'رميتان',
  3: 'رميات',
  10: 'رميات',
  11: 'رمية',
  99: 'رمية',
  100: 'رمية',
};

const Map<int, String> _arSixes = <int, String>{
  0: 'ستّات',
  1: 'ستّة',
  2: 'ستّتان',
  3: 'ستّات',
  10: 'ستّات',
  11: 'ستّة',
  99: 'ستّة',
  100: 'ستّة',
};

const Map<int, String> _arCaptures = <int, String>{
  0: 'ضربات',
  1: 'ضربة',
  2: 'ضربتان',
  3: 'ضربات',
  10: 'ضربات',
  11: 'ضربة',
  99: 'ضربة',
  100: 'ضربة',
};

void main() {
  // ===========================================================================
  // 1. waitingMarkSize, the one size rule.
  // ===========================================================================
  group('C-565 1: waitingMarkSize', () {
    /// Evaluates the rule under a real MediaQuery at [scale].
    Future<double> sizeAt(
      WidgetTester tester, {
      required double scale,
      required TextStyle style,
    }) async {
      double? got;
      await tester.pumpWidget(
        _harness(
          Builder(
            builder: (BuildContext context) {
              got = waitingMarkSize(context, style);
              return const SizedBox.shrink();
            },
          ),
          textScale: scale,
        ),
      );
      return got!;
    }

    final List<(String, double, TextStyle, double)>
    cases = <(String, double, TextStyle, double)>[
      ('14 sp at 1.0 is today\'s 18', 1.0, const TextStyle(fontSize: 14), 18),
      ('14 sp at 2.0 is 36', 2.0, const TextStyle(fontSize: 14), 36),
      ('14 sp at 3.0 clamps to 40', 3.0, const TextStyle(fontSize: 14), 40),
      (
        '14 sp at 0.8 holds the 18 floor',
        0.8,
        const TextStyle(fontSize: 14),
        18,
      ),
      (
        'a null font size counts as 14: 1.0 gives 18',
        1.0,
        const TextStyle(),
        18,
      ),
      (
        'a null font size counts as 14: 2.0 gives 36',
        2.0,
        const TextStyle(),
        36,
      ),
      (
        'a null font size counts as 14: 3.0 clamps to 40',
        3.0,
        const TextStyle(),
        40,
      ),
      (
        'a 16 sp style at 1.0 gives 16 * 18 / 14',
        1.0,
        const TextStyle(fontSize: 16),
        16 * 18 / 14,
      ),
      (
        'a 16 sp style at 2.0 gives 32 * 18 / 14 clamped to 40',
        2.0,
        const TextStyle(fontSize: 16),
        40,
      ),
      (
        'a 10 sp style at 1.0 is below the floor and gives 18',
        1.0,
        const TextStyle(fontSize: 10),
        18,
      ),
      ('a 14 sp style at 1.5 gives 27', 1.5, const TextStyle(fontSize: 14), 27),
      (
        'a 40 sp style at 1.0 clamps to 40',
        1.0,
        const TextStyle(fontSize: 40),
        40,
      ),
    ];
    for (final (String name, double scale, TextStyle style, double want)
        in cases) {
      testWidgets('C-565 1: $name', (WidgetTester tester) async {
        final double got = await sizeAt(tester, scale: scale, style: style);
        expect(
          got,
          closeTo(want, 1e-6),
          reason:
              'D1: waitingMarkSize at text scale $scale for fontSize '
              '${style.fontSize} must be $want, got $got. Rule: '
              '(scale(fs) * 18 / 14).clamp(18, 40), fs null = 14.',
        );
      });
    }
  });

  // ===========================================================================
  // 2. WaitingLine draws its mark at waitingMarkSize of its own text.
  // ===========================================================================
  group('C-565 2: WaitingLine mark follows its text', () {
    Future<void> mount(
      WidgetTester tester, {
      required Locale locale,
      required double scale,
      TextStyle? style,
      bool still = false,
    }) async {
      await _phone(tester);
      await tester.pumpWidget(
        _harness(
          Scaffold(
            body: Center(
              child: WaitingLine(
                text: 'Connecting to the table',
                textKey: _lineTextKey,
                style: style,
              ),
            ),
          ),
          locale: locale,
          textScale: scale,
          disableAnimations: still,
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    for (final Locale locale in _locales) {
      for (final double scale in _scales) {
        final String lang = locale.languageCode;
        final String scenario =
            'WaitingLine default style, 360x640, text scale $scale, '
            'locale $lang';

        testWidgets(
          'C-565 2: $lang, scale $scale: the mark equals waitingMarkSize of '
          'the rendered text style',
          (WidgetTester tester) async {
            await mount(tester, locale: locale, scale: scale);
            try {
              final TextStyle rendered = _renderedStyle(
                tester,
                find.byKey(_lineTextKey),
                scenario,
              );
              final double want = _expectedMark(
                tester,
                find.byKey(_lineTextKey),
                rendered,
              );
              final Size got = tester.getSize(find.byKey(_markKey));
              expect(
                got.width,
                closeTo(want, 0.5),
                reason:
                    'D2: the mark must be ${want.toStringAsFixed(2)} dp '
                    '(waitingMarkSize of the rendered ${rendered.fontSize} sp '
                    'style), it is ${got.width}. Scenario: $scenario',
              );
              expect(
                got.height,
                closeTo(want, 0.5),
                reason:
                    'D2: the mark must be square, ${want.toStringAsFixed(2)} '
                    'dp high; it is ${got.height}. Scenario: $scenario',
              );
              final double iconSize = tester
                  .widget<Icon>(_iconUnder(_markKey))
                  .size!;
              expect(
                iconSize,
                closeTo(want, 0.5),
                reason:
                    'D2: the Icon under waiting-line-mark must carry '
                    'size ${want.toStringAsFixed(2)}, it carries $iconSize. '
                    'Scenario: $scenario',
              );
              if (scale == 1.0) {
                expect(
                  got.width,
                  closeTo(18, 0.5),
                  reason:
                      'D1: at the default scale nothing changes, the mark '
                      'stays 18 dp; it is ${got.width}. Scenario: $scenario',
                );
              } else {
                expect(
                  got.width,
                  greaterThanOrEqualTo(30),
                  reason:
                      'D2: at text scale $scale the mark must be at least '
                      '30 dp; it is ${got.width}. Scenario: $scenario',
                );
              }
              _expectNoException(tester, scenario);
            } finally {
              await _unmount(tester);
            }
          },
        );

        testWidgets(
          'C-565 2: $lang, scale $scale: under disableAnimations the mark has '
          'the same size and does not turn',
          (WidgetTester tester) async {
            await mount(tester, locale: locale, scale: scale, still: true);
            try {
              final TextStyle rendered = _renderedStyle(
                tester,
                find.byKey(_lineTextKey),
                scenario,
              );
              final double want = _expectedMark(
                tester,
                find.byKey(_lineTextKey),
                rendered,
              );
              final Size got = tester.getSize(find.byKey(_markKey));
              expect(
                got.width,
                closeTo(want, 0.5),
                reason:
                    'D2: removed animations keep the mark at '
                    '${want.toStringAsFixed(2)} dp; it is ${got.width}. '
                    'Scenario: $scenario, disableAnimations true',
              );
              expect(
                tester
                    .widget<RotationTransition>(find.byKey(_markKey))
                    .turns
                    .value,
                0,
                reason:
                    'D2: turns must be 0 at mount under disableAnimations. '
                    'Scenario: $scenario',
              );
              await tester.pump(const Duration(milliseconds: 600));
              expect(
                tester
                    .widget<RotationTransition>(find.byKey(_markKey))
                    .turns
                    .value,
                0,
                reason:
                    'D2: turns must stay 0 after 600 ms under '
                    'disableAnimations. Scenario: $scenario',
              );
              expect(
                tester.getSize(find.byKey(_markKey)).width,
                closeTo(want, 0.5),
                reason:
                    'D2: the size must not change while the mark is still. '
                    'Scenario: $scenario',
              );
            } finally {
              await _unmount(tester);
            }
          },
        );
      }
    }

    testWidgets('C-565 2: with animations the mark turns and keeps its size', (
      WidgetTester tester,
    ) async {
      const String scenario =
          'WaitingLine default style, 360x640, text scale 2.0, locale en';
      await mount(tester, locale: _en, scale: 2.0);
      try {
        final double a = tester
            .widget<RotationTransition>(find.byKey(_markKey))
            .turns
            .value;
        await tester.pump(const Duration(milliseconds: 300));
        final double b = tester
            .widget<RotationTransition>(find.byKey(_markKey))
            .turns
            .value;
        expect(
          a == b,
          isFalse,
          reason:
              'D2: the mark keeps turning; turns stayed $a after 300 ms. '
              'Scenario: $scenario',
        );
        expect(
          tester.getSize(find.byKey(_markKey)).width,
          greaterThanOrEqualTo(30),
          reason: 'D2: size holds while turning. Scenario: $scenario',
        );
      } finally {
        await _unmount(tester);
      }
    });

    // The effective style is the one the Text renders with: a caller style
    // without a font size still measures the real text, and a caller style
    // with one is measured as given.
    final List<(String, TextStyle?)> styled = <(String, TextStyle?)>[
      ('a caller style with no font size', const TextStyle(color: Colors.red)),
      (
        'a 16 sp caller style',
        const TextStyle(fontSize: 16, color: LudoColors.inkMuted),
      ),
      (
        'a 30 sp caller style',
        const TextStyle(fontSize: 30, color: LudoColors.inkMuted),
      ),
    ];
    for (final (String name, TextStyle? style) in styled) {
      for (final double scale in _scales) {
        testWidgets(
          'C-565 2: $name at scale $scale: the mark equals waitingMarkSize '
          'of the rendered style',
          (WidgetTester tester) async {
            final String scenario =
                'WaitingLine with $name, 360x640, text scale $scale, '
                'locale en';
            await mount(tester, locale: _en, scale: scale, style: style);
            try {
              final TextStyle rendered = _renderedStyle(
                tester,
                find.byKey(_lineTextKey),
                scenario,
              );
              final double want = _expectedMark(
                tester,
                find.byKey(_lineTextKey),
                rendered,
              );
              final double got = tester.getSize(find.byKey(_markKey)).width;
              expect(
                got,
                closeTo(want, 0.5),
                reason:
                    'D2: the mark must be ${want.toStringAsFixed(2)} dp for '
                    'the rendered ${rendered.fontSize} sp text; it is $got. '
                    'Scenario: $scenario',
              );
              if (style?.fontSize != null) {
                final double byHand = waitingMarkSize(
                  tester.element(find.byKey(_lineTextKey)),
                  TextStyle(fontSize: style!.fontSize),
                );
                expect(
                  got,
                  closeTo(byHand, 0.5),
                  reason:
                      'D2: a caller font size ${style.fontSize} must be '
                      'measured as given, expected '
                      '${byHand.toStringAsFixed(2)}, got $got. '
                      'Scenario: $scenario',
                );
              }
              _expectNoException(tester, scenario);
            } finally {
              await _unmount(tester);
            }
          },
        );
      }
    }
  });

  // ===========================================================================
  // 3. The lobby connecting body at text scale 2.0.
  // ===========================================================================
  group('C-565 3: the lobby connecting body', () {
    for (final Locale locale in _locales) {
      final String lang = locale.languageCode;
      final String scenario =
          'LobbyScreen create, unanswered, 360x640, text scale 2.0, '
          'locale $lang';

      testWidgets(
        'C-565 3: $lang: the mark is at least 30 dp, inside the body and '
        'inside the side margins, with no overflow',
        (WidgetTester tester) async {
          await _phone(tester);
          final FakeTransport transport = FakeTransport();
          final RoomController controller = _controllerOver(transport);
          await tester.pumpWidget(
            _harness(
              LobbyScreen(
                controller: controller,
                action: LobbyAction.create,
                playerName: 'Sam',
                players: 2,
              ),
              locale: locale,
              textScale: 2.0,
            ),
          );
          await tester.pump();
          await tester.pump();
          try {
            expect(
              find.byKey(_lobbyConnectingKey),
              findsOneWidget,
              reason:
                  'fixture: an unanswered create must show lobby-connecting. '
                  'Scenario: $scenario',
            );
            final Finder mark = find.descendant(
              of: find.byKey(_lobbyConnectingLineKey),
              matching: find.byKey(_markKey),
            );
            expect(
              mark,
              findsOneWidget,
              reason:
                  'fixture: lobby-connecting-line must draw one mark. '
                  'Scenario: $scenario',
            );
            final Rect rect = tester.getRect(mark);
            expect(
              rect.width,
              greaterThanOrEqualTo(30),
              reason:
                  'D2: at text scale 2.0 the connecting mark must be at '
                  'least 30 dp, it is ${rect.width}. Scenario: $scenario',
            );
            expect(
              rect.height,
              greaterThanOrEqualTo(30),
              reason:
                  'D2: the mark must be at least 30 dp high, it is '
                  '${rect.height}. Scenario: $scenario',
            );
            final Rect body = tester.getRect(find.byKey(_lobbyConnectingKey));
            expect(
              body.contains(rect.topLeft) && body.contains(rect.bottomRight),
              isTrue,
              reason:
                  'D2: the mark $rect must sit inside the connecting body '
                  '$body. Scenario: $scenario',
            );
            expect(
              rect.left,
              greaterThanOrEqualTo(kSpace6),
              reason:
                  'D2: the mark must keep the $kSpace6 dp side margin on the '
                  'left; it spans $rect. Scenario: $scenario',
            );
            expect(
              360 - rect.right,
              greaterThanOrEqualTo(kSpace6),
              reason:
                  'D2: the mark must keep the $kSpace6 dp side margin on the '
                  'right; it spans $rect. Scenario: $scenario',
            );
            final Finder text = find.descendant(
              of: find.byKey(_lobbyConnectingLineKey),
              matching: find.byType(Text),
            );
            final TextStyle rendered = _renderedStyle(
              tester,
              text.first,
              scenario,
            );
            expect(
              rect.width,
              closeTo(_expectedMark(tester, text.first, rendered), 0.5),
              reason:
                  'D2: the connecting mark must equal waitingMarkSize of the '
                  'line text. Scenario: $scenario',
            );
            _expectNoException(tester, scenario);
          } finally {
            await _unmount(tester);
            controller.dispose();
          }
        },
      );
    }
  });

  // ===========================================================================
  // 4. The docked waiting line in the lobby.
  // ===========================================================================
  // _dockedWaiting is reached from the lobby action area by: a guest in a room
  // that is not full, a guest in a full room (waiting for the host's start),
  // and the host of a room short of players. A full room for the host shows the
  // start button instead.
  group('C-565 4: the docked waiting line', () {
    final List<(String, bool, int, int)> states = <(String, bool, int, int)>[
      // name, host, seated, players
      ('host short of players, 1 of 4 seated', true, 1, 4),
      ('host short of players, 2 of 3 seated', true, 2, 3),
      ('guest in a room short of players, 2 of 4 seated', false, 2, 4),
      (
        'guest in a full room waiting for the start, 4 of 4 seated',
        false,
        4,
        4,
      ),
    ];
    for (final (String name, bool host, int seated, int players) in states) {
      for (final Locale locale in _locales) {
        for (final double scale in _scales) {
          final String lang = locale.languageCode;
          final String scenario =
              'LobbyScreen ${host ? 'create' : 'join'} landed on LOBBY, $name, '
              '360x640, text scale $scale, locale $lang';

          testWidgets(
            'C-565 4: $name, $lang, scale $scale: the docked mark follows '
            'its text',
            (WidgetTester tester) async {
              await _phone(tester);
              final FakeTransport transport = FakeTransport();
              final RoomController controller = _controllerOver(transport);
              await tester.pumpWidget(
                _harness(
                  LobbyScreen(
                    controller: controller,
                    action: host ? LobbyAction.create : LobbyAction.join,
                    code: host ? null : 'C565XX',
                    playerName: host ? 'p0' : 'p1',
                    players: players,
                  ),
                  locale: locale,
                  textScale: scale,
                ),
              );
              await tester.pump();
              try {
                await _answerLobby(
                  tester,
                  transport,
                  mySeat: host ? 0 : 1,
                  room: _roomJson(
                    state: 'LOBBY',
                    players: players,
                    seated: seated,
                  ),
                );
                expect(
                  controller.isHost,
                  host,
                  reason: 'fixture: the client must be host=$host. $scenario',
                );
                expect(
                  find.byKey(_dockedTextKey),
                  findsOneWidget,
                  reason:
                      'fixture: this state must show the docked waiting '
                      'line lobby-waiting. $scenario',
                );
                expect(
                  find.byKey(_dockedMarkKey),
                  findsOneWidget,
                  reason:
                      'D3: the docked hourglass must carry the Key '
                      'lobby-docked-waiting-mark. $scenario',
                );
                final TextStyle rendered = _renderedStyle(
                  tester,
                  find.byKey(_dockedTextKey),
                  scenario,
                );
                final double want = _expectedMark(
                  tester,
                  find.byKey(_dockedTextKey),
                  rendered,
                );
                final Size got = tester.getSize(find.byKey(_dockedMarkKey));
                expect(
                  got.width,
                  closeTo(want, 0.5),
                  reason:
                      'D3: the docked mark must be '
                      '${want.toStringAsFixed(2)} dp (waitingMarkSize of the '
                      'rendered ${rendered.fontSize} sp text), it is '
                      '${got.width}. $scenario',
                );
                if (scale == 1.0) {
                  expect(
                    got.width,
                    closeTo(18, 0.5),
                    reason:
                        'D1: at the default scale the docked mark stays '
                        '18 dp, it is ${got.width}. $scenario',
                  );
                } else {
                  expect(
                    got.width,
                    greaterThanOrEqualTo(30),
                    reason:
                        'D3: at text scale $scale the docked mark must be at '
                        'least 30 dp, it is ${got.width}. $scenario',
                  );
                }
                final Rect rect = tester.getRect(find.byKey(_dockedMarkKey));
                expect(
                  rect.left >= 0 && rect.right <= 360,
                  isTrue,
                  reason:
                      'D3: the docked mark $rect must lie inside the 360 dp '
                      'screen. $scenario',
                );
                expect(
                  tester.widget<Icon>(find.byKey(_dockedMarkKey)).icon,
                  Icons.hourglass_top_rounded,
                  reason:
                      'D3: the docked mark stays the still hourglass. '
                      '$scenario',
                );
                _expectNoException(tester, scenario);
              } finally {
                await _unmount(tester);
                controller.dispose();
              }
            },
          );
        }
      }
    }
  });

  // ===========================================================================
  // 5. The Arabic countdown label.
  // ===========================================================================
  group('C-565 5: gameTurnCountdown', () {
    for (final MapEntry<int, String> e in _arCountdown.entries) {
      test('C-565 5: ar: gameTurnCountdown(${e.key}) is "${e.value}"', () {
        final String got = _locFor(_ar).gameTurnCountdown(e.key);
        expect(
          got,
          e.value,
          reason:
              'D4: the Arabic countdown label for ${e.key} must read '
              '"${e.value}", it reads "$got". Scenario: AppLocalizations(ar)'
              '.gameTurnCountdown(${e.key})',
        );
      });
    }

    test('C-565 5: en: gameTurnCountdown(5) is still "5s left"', () {
      expect(
        _locFor(_en).gameTurnCountdown(5),
        '5s left',
        reason:
            'D4: the English text does not change. Scenario: '
            'AppLocalizations(en).gameTurnCountdown(5)',
      );
    });
  });

  // ===========================================================================
  // 6. The Arabic end card stat labels.
  // ===========================================================================
  group('C-565 6: stat labels', () {
    void pinned(
      String name,
      Map<int, String> table,
      String Function(AppLocalizations, int) read,
    ) {
      for (final MapEntry<int, String> e in table.entries) {
        test('C-565 6: ar: $name(${e.key}) is "${e.value}"', () {
          final String got = read(_locFor(_ar), e.key);
          expect(
            got,
            e.value,
            reason:
                'D4: Arabic $name for ${e.key} must read "${e.value}", it '
                'reads "$got". Scenario: AppLocalizations(ar).$name(${e.key})',
          );
        });
      }
    }

    pinned(
      'endStatRolls',
      _arRolls,
      (AppLocalizations l, int n) => l.endStatRolls(n),
    );
    pinned(
      'endStatSixes',
      _arSixes,
      (AppLocalizations l, int n) => l.endStatSixes(n),
    );
    pinned(
      'endStatCaptures',
      _arCaptures,
      (AppLocalizations l, int n) => l.endStatCaptures(n),
    );

    for (final int n in <int>[0, 1, 2, 4]) {
      test('C-565 6: ar: endStatHome($n) is unchanged', () {
        final String got = _locFor(_ar).endStatHome(n);
        expect(
          got,
          _arHome,
          reason:
              'D4: Arabic endStatHome reads right under any count and does '
              'not change; for $n it reads "$got". Scenario: '
              'AppLocalizations(ar).endStatHome($n)',
        );
      });
    }

    test('C-565 6: en: the English forms are unchanged for 1 and 2', () {
      final AppLocalizations en = _locFor(_en);
      expect(
        <String>[
          en.endStatRolls(1),
          en.endStatRolls(2),
          en.endStatSixes(1),
          en.endStatSixes(2),
          en.endStatCaptures(1),
          en.endStatCaptures(2),
        ],
        <String>['roll', 'rolls', 'six', 'sixes', 'capture', 'captures'],
        reason:
            'D4: the English texts do not change. Scenario: '
            'AppLocalizations(en) endStatRolls/Sixes/Captures at 1 and 2',
      );
    });
  });

  // ===========================================================================
  // 7. The Arabic end card with stats.
  // ===========================================================================
  group('C-565 7: the Arabic end card', () {
    setUpAll(() async {
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
      final FontLoader noto = FontLoader('Noto Sans Arabic');
      for (final String asset in const <String>[
        'fonts/NotoSansArabic-Regular.ttf',
        'fonts/NotoSansArabic-Bold.ttf',
      ]) {
        noto.addFont(rootBundle.load(asset));
      }
      await noto.load();
    });

    Future<void> mountCard(
      WidgetTester tester, {
      required GameStats stats,
      required double scale,
    }) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _harness(
          Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(kSpace4),
              child: EndCard(
                mySeat: 0,
                winnerSeat: 0,
                winnerName: 'p0',
                seatColors: LudoColors.seats,
                stats: stats,
                verifyUrl: 'https://c565-test.invalid/verify',
                onVerify: () {},
                onNewTable: () {},
                onRematch: () {},
              ),
            ),
          ),
          locale: _ar,
          textScale: scale,
        ),
      );
      await tester.pump();
      // The celebration burst is 1200 ms; one bounded pump runs it out.
      await tester.pump(const Duration(milliseconds: 1200));
    }

    Finder labelIn(String tileKey, String label) => find.descendant(
      of: find.byKey(Key(tileKey)),
      matching: find.text(label),
    );

    const GameStats spec = GameStats(
      rolls: 2,
      sixes: 1,
      capturesMade: 0,
      timesCaptured: 0,
      tokensHome: 4,
      complete: true,
    );
    const GameStats withCaptures = GameStats(
      rolls: 2,
      sixes: 1,
      capturesMade: 3,
      timesCaptured: 0,
      tokensHome: 4,
      complete: true,
    );

    for (final double scale in _scales) {
      final String scenario =
          'EndCard ar winner, 360x640, text scale $scale, stats rolls 2, '
          'sixes 1, captures 0, home 4, complete';

      testWidgets(
        'C-565 7: scale $scale: the tiles read ${_arRolls[2]}, ${_arSixes[1]} '
        'and $_arHome with no overflow',
        (WidgetTester tester) async {
          await mountCard(tester, stats: spec, scale: scale);
          try {
            final Map<String, String> want = <String, String>{
              'end-card-stat-rolls': _arRolls[2]!,
              'end-card-stat-sixes': _arSixes[1]!,
              'end-card-stat-home': _arHome,
            };
            for (final MapEntry<String, String> e in want.entries) {
              expect(
                labelIn(e.key, e.value),
                findsOneWidget,
                reason:
                    'D4: tile ${e.key} must read "${e.value}". '
                    'Scenario: $scenario',
              );
            }
            _expectNoException(tester, scenario);
          } finally {
            await _unmount(tester);
          }
        },
      );

      // The spec's stats object has captures 0, and the end card builds a
      // tile only for a value above zero (C-533 D3), so the captures label
      // is read here on a card whose captures are 3.
      final String withScenario =
          'EndCard ar winner, 360x640, text scale $scale, stats rolls 2, '
          'sixes 1, captures 3, home 4, complete';
      testWidgets('C-565 7: scale $scale: with captures 3 the four tiles read '
          '${_arRolls[2]}, ${_arSixes[1]}, ${_arCaptures[3]}, $_arHome', (
        WidgetTester tester,
      ) async {
        await mountCard(tester, stats: withCaptures, scale: scale);
        try {
          final Map<String, String> want = <String, String>{
            'end-card-stat-rolls': _arRolls[2]!,
            'end-card-stat-sixes': _arSixes[1]!,
            'end-card-stat-captures': _arCaptures[3]!,
            'end-card-stat-home': _arHome,
          };
          for (final MapEntry<String, String> e in want.entries) {
            expect(
              labelIn(e.key, e.value),
              findsOneWidget,
              reason:
                  'D4: tile ${e.key} must read "${e.value}". '
                  'Scenario: $withScenario',
            );
          }
          _expectNoException(tester, withScenario);
        } finally {
          await _unmount(tester);
        }
      });
    }
  });

  // ===========================================================================
  // 8. The Arabic countdown semantics on the game screen.
  // ===========================================================================
  group('C-565 8: the Arabic countdown semantics', () {
    testWidgets(
      'C-565 8: ar: from 10 s down, 3-10 s say ثوانٍ and 2 s says ثانيتان',
      (WidgetTester tester) async {
        const String scenario =
            'createRoom seat 0 of 2, PLAYING, await_roll, deadline_ms 10000, '
            'locale ar, 390x844, fake time 1 s steps';
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final RoomController controller = await _playingController(
          tester,
          deadlineMs: 10000,
        );
        try {
          await tester.pumpWidget(
            _harness(
              FeedbackScope(
                settings: FeedbackSettings.forTest(),
                service: const NoopFeedbackService(),
                child: GameScreen(controller: controller),
              ),
              locale: _ar,
            ),
          );
          await tester.pump();

          String? label() {
            final Finder f = find.byKey(_countdownSemanticsKey);
            if (f.evaluate().isEmpty) {
              return null;
            }
            return (tester.widget(f) as Semantics).properties.label;
          }

          String? digits() {
            final Finder f = find.byKey(_countdownKey);
            return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
          }

          for (int left = 10; left >= 2; left--) {
            expect(
              digits(),
              '$left',
              reason:
                  'fixture: the ring must read $left here. Seen: '
                  'digits ${digits()}, label ${label()}. Scenario: $scenario',
            );
            final String? got = label();
            expect(
              got,
              left >= 3 ? 'بقيت $left ثوانٍ' : _arCountdown[left],
              reason:
                  'D4: the countdown label at $left s must be the D4 text. '
                  'Seen "$got". Scenario: $scenario',
            );
            if (left >= 3) {
              expect(
                got,
                contains('ثوانٍ'),
                reason:
                    'D4: at $left s (3-10) the label must contain ثوانٍ. '
                    'Seen "$got". Scenario: $scenario',
              );
            } else {
              expect(
                got,
                contains('ثانيتان'),
                reason:
                    'D4: at 2 s the label must contain ثانيتان. Seen '
                    '"$got". Scenario: $scenario',
              );
            }
            await tester.pump(const Duration(seconds: 1));
          }
        } finally {
          await _unmount(tester);
          controller.dispose();
        }
      },
    );

    testWidgets(
      'C-565 8: ar: at 11 s and above the label keeps ثانية, at 1 s it says '
      'a single second',
      (WidgetTester tester) async {
        const String scenario =
            'createRoom seat 0 of 2, PLAYING, await_roll, deadline_ms 12000, '
            'locale ar, 390x844, fake time 1 s steps';
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final RoomController controller = await _playingController(
          tester,
          deadlineMs: 12000,
        );
        try {
          await tester.pumpWidget(
            _harness(
              FeedbackScope(
                settings: FeedbackSettings.forTest(),
                service: const NoopFeedbackService(),
                child: GameScreen(controller: controller),
              ),
              locale: _ar,
            ),
          );
          await tester.pump();
          String? label() => (tester.widget(
            find.byKey(_countdownSemanticsKey),
          ) as Semantics).properties.label;

          expect(
            label(),
            isNotNull,
            reason: 'fixture: the label must exist at 12 s. $scenario',
          );
          expect(
            label(),
            _locFor(_ar).gameTurnCountdown(12),
            reason: 'D4: the label at 12 s is the "other" form. $scenario',
          );
          expect(
            label(),
            isNot(contains('ثوانٍ')),
            reason:
                'D4: 12 s takes the "other" noun, not ثوانٍ. Seen '
                '"${label()}". $scenario',
          );
          await tester.pump(const Duration(seconds: 1));
          expect(
            label(),
            _arCountdown[11],
            reason:
                'D4: the label at 11 s must be "${_arCountdown[11]}". Seen '
                '"${label()}". $scenario',
          );
          for (int i = 0; i < 10; i++) {
            await tester.pump(const Duration(seconds: 1));
          }
          expect(
            label(),
            _arCountdown[1],
            reason:
                'D4: the label at 1 s must be "${_arCountdown[1]}". Seen '
                '"${label()}". $scenario',
          );
        } finally {
          await _unmount(tester);
          controller.dispose();
        }
      },
    );
  });
}
