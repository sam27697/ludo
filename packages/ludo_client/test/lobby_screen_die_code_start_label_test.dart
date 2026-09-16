// Widget tests for LobbyScreen's connected gathering presentation: the
// room code on the brand die, felt atmosphere behind the lobby, a disabled
// host Start whose label says how many seats are filled, a cancel control
// while connecting, compact-height layout, and room-code contrast.
//
// A real RoomController is driven over FakeTransport the same way
// lobby_screen_test.dart does. No mock of RoomController, no real sockets.
// Connecting-phase cases dispose the controller in a finally block so the
// outstanding create_room timer is cancelled before flutter_test's pending-
// timer check.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ludo_client/l10n/gen/app_localizations.dart';
import 'package:ludo_client/src/app.dart' show appSupportedLocales;
import 'package:ludo_client/src/die_mark.dart';
import 'package:ludo_client/src/lobby_screen.dart';
import 'package:ludo_client/src/net/room_controller.dart';
import 'package:ludo_client/src/net/transport.dart';
import 'package:ludo_client/src/theme.dart';

import 'net/fake_transport.dart';

const String _testUrl = 'wss://example.test/ws';
const Key _roomCodeKey = Key('lobby-room-code');
const Key _startKey = Key('lobby-start-button');
const Key _cancelKey = Key('lobby-cancel-button');
const Key _connectingKey = Key('lobby-connecting');
const Key _openLobbyKey = Key('open-lobby');

int _serverIdSeq = 0;
String _nextServerId() {
  _serverIdSeq += 1;
  return 'srv-id-${_serverIdSeq.toString().padLeft(6, '0')}';
}

Map<String, Object?> _decode(String text) =>
    jsonDecode(text) as Map<String, Object?>;

String _idOf(String sentText) => _decode(sentText)['id']! as String;

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

Map<String, Object?> _seatJson(int seat, {String name = 'Sam'}) =>
    <String, Object?>{
      'seat': seat,
      'name': name,
      'connected': true,
      'tokens': <int>[-1, -1, -1, -1],
      'client_seed': null,
      'seed_origin': null,
    };

Map<String, Object?> _roomJson({
  String code = 'ABC234',
  int hostSeat = 0,
  int players = 4,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) => <String, Object?>{
  'code': code,
  'state': 'LOBBY',
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
  'seats': seats ?? <Map<String, Object?>>[_seatJson(hostSeat)],
  'turn': null,
  'winner': null,
  'seq': seq,
};

class _Connector {
  final List<FakeTransport> _queue = <FakeTransport>[];
  final List<Uri> calls = <Uri>[];

  void enqueue(FakeTransport transport) => _queue.add(transport);

  Future<WireTransport> call(Uri url) async {
    calls.add(url);
    if (_queue.isEmpty) {
      throw StateError(
        '_Connector: connect() call #${calls.length} has no transport queued',
      );
    }
    return _queue.removeAt(0);
  }
}

class _PopObserver extends NavigatorObserver {
  int popCount = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popCount += 1;
  }
}

RoomController _newController(_Connector connector) =>
    RoomController(serverUrl: Uri.parse(_testUrl), connect: connector.call);

Widget _localizations({
  required Widget home,
  Locale locale = const Locale('en'),
  List<NavigatorObserver> observers = const <NavigatorObserver>[],
}) {
  return MaterialApp(
    locale: locale,
    theme: buildAppTheme(),
    supportedLocales: appSupportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    navigatorObservers: observers,
    home: home,
  );
}

Future<String> _mountAndCaptureRequest(
  WidgetTester tester,
  Widget screen,
  FakeTransport transport, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(_localizations(home: screen, locale: locale));
  await tester.pump();
  expect(
    transport.sentRaw,
    isNotEmpty,
    reason:
        'LobbyScreen.initState must have sent create_room or join_room; '
        'sentRaw is empty',
  );
  return _idOf(transport.sentRaw.last);
}

Future<void> _resolveConnected(
  WidgetTester tester,
  FakeTransport transport,
  String requestId, {
  required int seatForThisClient,
  String code = 'ABC234',
  int players = 4,
  int hostSeat = 0,
  List<Map<String, Object?>>? seats,
  int seq = 1,
}) async {
  transport.pushText(
    _frame(
      type: 'seat_assigned',
      data: <String, Object?>{
        'seat': seatForThisClient,
        'seat_token': 'tok-$seatForThisClient',
      },
    ),
  );
  transport.pushText(
    _frame(
      type: 'room',
      re: requestId,
      data: _roomJson(
        code: code,
        players: players,
        hostSeat: hostSeat,
        seats: seats,
        seq: seq,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpConnectedHostLobby(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  int seated = 1,
  int players = 4,
}) async {
  final _Connector connector = _Connector();
  final FakeTransport transport = FakeTransport();
  connector.enqueue(transport);
  final RoomController controller = _newController(connector);
  addTearDown(controller.dispose);

  final String id = await _mountAndCaptureRequest(
    tester,
    LobbyScreen(
      controller: controller,
      action: LobbyAction.create,
      playerName: 'Sam',
      players: players,
    ),
    transport,
    locale: locale,
  );

  final List<Map<String, Object?>> seats = List<Map<String, Object?>>.generate(
    seated,
    (int i) => _seatJson(i, name: 'p$i'),
  );
  await _resolveConnected(
    tester,
    transport,
    id,
    seatForThisClient: 0,
    hostSeat: 0,
    players: players,
    seats: seats,
  );
  expect(controller.phase, RoomPhase.connected);
  expect(find.byKey(_roomCodeKey), findsOneWidget);
}

String _startButtonLabel(WidgetTester tester) {
  final Finder textFinder = find.descendant(
    of: find.byKey(_startKey),
    matching: find.byType(Text),
  );
  if (textFinder.evaluate().isNotEmpty) {
    final Text text = tester.widget<Text>(textFinder);
    return text.data ?? text.textSpan?.toPlainText() ?? '';
  }
  final Finder richFinder = find.descendant(
    of: find.byKey(_startKey),
    matching: find.byType(RichText),
  );
  expect(
    richFinder,
    findsOneWidget,
    reason: 'lobby-start-button has no Text or RichText label to read',
  );
  return tester.widget<RichText>(richFinder).text.toPlainText();
}

// WCAG 2.1 relative luminance and contrast, same method as
// locale_toggle_contrast_test.dart.
double _relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrastRatio(Color a, Color b) {
  final double lumA = _relativeLuminance(a);
  final double lumB = _relativeLuminance(b);
  final double lighter = lumA > lumB ? lumA : lumB;
  final double darker = lumA > lumB ? lumB : lumA;
  return (lighter + 0.05) / (darker + 0.05);
}

Color _roomCodeForeground(WidgetTester tester) {
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byKey(_roomCodeKey),
      matching: find.byType(RichText),
    ),
  );
  final Color? color = paragraph.text.style?.color;
  if (color == null) {
    fail('lobby-room-code paragraph resolved no text colour');
  }
  return color;
}

/// The fill a person sees behind the room code: the die face when the code
/// sits on DieMark, otherwise the lobby Scaffold's opaque background.
Color _paintedBackgroundBehindRoomCode(WidgetTester tester) {
  final Finder onDie = find.descendant(
    of: find.byType(DieMark),
    matching: find.byKey(_roomCodeKey),
  );
  if (onDie.evaluate().isNotEmpty) {
    return LudoColors.dieFace;
  }
  final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
  final Color? background = scaffold.backgroundColor;
  if (background != null && background.a == 1.0) {
    return background;
  }
  fail('no opaque painted background behind lobby-room-code');
}

bool _isOverflowError(FlutterErrorDetails details) {
  final String text = '${details.exception}\n$details';
  return text.contains('overflowed') ||
      text.contains('A RenderFlex overflowed');
}

void main() {
  testWidgets(
    'lobby-room-code is a descendant of DieMark on the connected lobby',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(tester);

      expect(
        find.descendant(
          of: find.byType(DieMark),
          matching: find.byKey(_roomCodeKey),
        ),
        findsOneWidget,
        reason:
            'connected lobby must show lobby-room-code as a descendant of '
            'DieMark (the code on the die face)',
      );
    },
  );

  testWidgets('connected lobby wraps FeltBackdrop', (
    WidgetTester tester,
  ) async {
    await _pumpConnectedHostLobby(tester);

    expect(
      find.descendant(
        of: find.byType(LobbyScreen),
        matching: find.byType(FeltBackdrop),
      ),
      findsOneWidget,
      reason: 'connected lobby must wrap FeltBackdrop',
    );
  });

  testWidgets(
    'disabled Start label includes seated and total counts or waiting copy',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(tester, seated: 3, players: 4);

      final Finder start = find.byKey(_startKey);
      expect(start, findsOneWidget);
      final ButtonStyleButton button = tester.widget<ButtonStyleButton>(start);
      expect(
        button.onPressed,
        isNull,
        reason: 'Start must be disabled with 3 of 4 seats filled',
      );

      final BuildContext context = tester.element(find.byType(LobbyScreen));
      final AppLocalizations loc = AppLocalizations.of(context);
      const int seated = 3;
      const int total = 4;
      final String waiting = loc.lobbyWaitingForPlayers(seated, total);
      final String label = _startButtonLabel(tester);
      final bool hasCounts =
          label.contains('$seated') && label.contains('$total');
      final bool hasWaiting = label.contains(waiting);

      expect(
        hasCounts || hasWaiting,
        isTrue,
        reason:
            'when Start is disabled, its label must include seated ($seated) '
            'and total ($total) or loc.lobbyWaitingForPlayers values '
            '("$waiting"); got "$label"',
      );
    },
  );

  testWidgets('connecting shows lobby-cancel-button that pops the route', (
    WidgetTester tester,
  ) async {
    final _Connector connector = _Connector();
    final FakeTransport transport = FakeTransport();
    connector.enqueue(transport);
    final RoomController controller = _newController(connector);
    final _PopObserver observer = _PopObserver();

    try {
      await tester.pumpWidget(
        _localizations(
          observers: <NavigatorObserver>[observer],
          home: Builder(
            builder: (BuildContext context) {
              return Scaffold(
                body: Center(
                  child: TextButton(
                    key: _openLobbyKey,
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => LobbyScreen(
                            controller: controller,
                            action: LobbyAction.create,
                            playerName: 'Sam',
                            players: 4,
                          ),
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.byKey(_openLobbyKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        transport.sentRaw,
        isNotEmpty,
        reason: 'pushed LobbyScreen must have issued create_room by now',
      );
      expect(find.byKey(_connectingKey), findsOneWidget);
      expect(find.byType(LobbyScreen), findsOneWidget);

      expect(
        find.descendant(
          of: find.byKey(_connectingKey),
          matching: find.byKey(_cancelKey),
        ),
        findsOneWidget,
        reason:
            'connecting body must include a control keyed lobby-cancel-button',
      );

      await tester.tap(find.byKey(_cancelKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        observer.popCount,
        1,
        reason:
            'tapping lobby-cancel-button must pop the lobby route; '
            'didPop count was ${observer.popCount}',
      );
      expect(
        find.byType(LobbyScreen),
        findsNothing,
        reason: 'after cancel, LobbyScreen must no longer be in the tree',
      );
      expect(find.byKey(_openLobbyKey), findsOneWidget);
    } finally {
      controller.dispose();
    }
  });

  for (final Locale locale in <Locale>[
    const Locale('en'),
    const Locale('ar'),
  ]) {
    testWidgets(
      'no RenderFlex overflow at 600px height in ${locale.languageCode}',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(390, 600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final List<FlutterErrorDetails> captured = <FlutterErrorDetails>[];
        final void Function(FlutterErrorDetails)? previous =
            FlutterError.onError;
        FlutterError.onError = captured.add;
        try {
          await _pumpConnectedHostLobby(
            tester,
            locale: locale,
            seated: 3,
            players: 4,
          );
          await tester.pump();
        } finally {
          FlutterError.onError = previous;
        }

        final List<FlutterErrorDetails> overflows = captured
            .where(_isOverflowError)
            .toList();
        expect(
          overflows,
          isEmpty,
          reason:
              'connected lobby at 600px height in ${locale.languageCode} '
              'must not report a RenderFlex overflow; got $overflows',
        );
      },
    );
  }

  testWidgets(
    'lobby-room-code contrast against painted background is at least 4.5:1',
    (WidgetTester tester) async {
      await _pumpConnectedHostLobby(tester);

      final Color foreground = _roomCodeForeground(tester);
      final Color background = _paintedBackgroundBehindRoomCode(tester);
      final double ratio = _contrastRatio(foreground, background);

      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            'lobby-room-code foreground $foreground on painted background '
            '$background measures $ratio:1, below the WCAG AA minimum of 4.5:1',
      );
    },
  );
}
